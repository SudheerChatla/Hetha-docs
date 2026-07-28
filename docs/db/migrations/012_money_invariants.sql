-- =============================================================================
-- Migration 012 — MONEY INVARIANTS (close the direct-insert bypass)
-- =============================================================================
-- Run in: Supabase SQL Editor, AFTER 011_legacy_function_grants.sql.
--
-- WHY
--   007–011 made the RPCs authoritative, but staff holding `orders:edit` /
--   `subscriptions:edit` can still write the tables directly (the admin panel
--   needs that for status changes and run-sheet edits). A direct INSERT could
--   therefore create an order whose `total` bears no relation to its items, and
--   a direct `subscription_items` INSERT could still carry an arbitrary
--   `unit_price` — which is what the daily run sheet bills against.
--
--   Rather than trusting every current and future admin code path to go through
--   the RPCs, the arithmetic is now enforced by the database itself:
--
--     orders                     : subtotal = Σ order_items.total_price
--                                  total    = subtotal + delivery_charge
--                                  at least one line item
--     subscription_daily_orders  : total_value = Σ item total_price
--     order_items                : unit_price snapped to the catalog on INSERT,
--                                  total_price always = unit_price × quantity
--     subscription_items         : unit_price snapped to the catalog on INSERT,
--                                  cannot be edited afterwards
--
--   The order/daily-order checks are DEFERRED constraint triggers, so they run
--   at COMMIT — after the parent row and its items have both been written. That
--   makes them agnostic about who did the writing: place_order, the edge
--   function, the admin panel or a hand-written INSERT all face the same rule.
--
--   Escape hatch for deliberate data repair in the SQL editor:
--     SET LOCAL hetha.skip_money_checks = 'on';
--   It is a session GUC, so it cannot be set through PostgREST by a client.
-- =============================================================================

CREATE OR REPLACE FUNCTION internal.money_checks_disabled()
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(NULLIF(current_setting('hetha.skip_money_checks', true), ''), 'off') = 'on';
$$;


-- ---------------------------------------------------------------------------
-- 1. orders: totals must equal the sum of their items
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION internal.assert_order_totals()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, internal
AS $$
DECLARE
  v_order_id   uuid;
  v_order      public.orders;
  v_item_sum   numeric;
  v_item_count integer;
BEGIN
  IF internal.money_checks_disabled() THEN
    RETURN NULL;
  END IF;

  -- The same function guards both the parent table and its items. Branch with
  -- IF/ELSE (not CASE): plpgsql resolves record field types for every branch of
  -- a CASE expression, and `orders` has no `order_id` column.
  IF TG_TABLE_NAME = 'orders' THEN
    IF TG_OP = 'DELETE' THEN v_order_id := OLD.id; ELSE v_order_id := NEW.id; END IF;
  ELSE
    IF TG_OP = 'DELETE' THEN v_order_id := OLD.order_id; ELSE v_order_id := NEW.order_id; END IF;
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = v_order_id;
  IF NOT FOUND THEN
    RETURN NULL;                             -- order was deleted in this tx
  END IF;

  SELECT COALESCE(SUM(total_price), 0), COUNT(*)
  INTO v_item_sum, v_item_count
  FROM public.order_items WHERE order_id = v_order_id;

  IF v_item_count = 0 THEN
    RAISE EXCEPTION 'Order % has no line items', v_order.order_number;
  END IF;

  IF round(v_order.subtotal, 2) <> round(v_item_sum, 2) THEN
    RAISE EXCEPTION 'Order % subtotal (%) does not match its items (%)',
      v_order.order_number, v_order.subtotal, v_item_sum;
  END IF;

  IF round(v_order.total, 2)
     <> round(v_order.subtotal + COALESCE(v_order.delivery_charge, 0), 2) THEN
    RAISE EXCEPTION 'Order % total (%) <> subtotal (%) + delivery charge (%)',
      v_order.order_number, v_order.total, v_order.subtotal, v_order.delivery_charge;
  END IF;

  IF COALESCE(v_order.delivery_charge, 0) < 0 THEN
    RAISE EXCEPTION 'Order % has a negative delivery charge', v_order.order_number;
  END IF;

  RETURN NULL;
END;
$$;

-- Fires on insert, and on updates that touch the money columns. Existing rows
-- are left alone unless someone edits their amounts.
DROP TRIGGER IF EXISTS trg_orders_totals ON public.orders;
CREATE CONSTRAINT TRIGGER trg_orders_totals
  AFTER INSERT OR UPDATE OF subtotal, delivery_charge, total ON public.orders
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION internal.assert_order_totals();

DROP TRIGGER IF EXISTS trg_order_items_totals ON public.order_items;
CREATE CONSTRAINT TRIGGER trg_order_items_totals
  AFTER INSERT OR UPDATE OR DELETE ON public.order_items
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION internal.assert_order_totals();


-- ---------------------------------------------------------------------------
-- 2. order_items: price from the catalog, total always derived
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION internal.snap_order_item()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, internal
AS $$
DECLARE
  v_price numeric;
BEGIN
  IF internal.money_checks_disabled() THEN
    RETURN NEW;
  END IF;

  IF NEW.quantity IS NULL OR NEW.quantity < 1 THEN
    RAISE EXCEPTION 'Order item quantity must be at least 1';
  END IF;

  IF TG_OP = 'INSERT' THEN
    SELECT round(price, 2) INTO v_price
    FROM public.product_variants WHERE id = NEW.variant_id;

    IF v_price IS NULL THEN
      RAISE EXCEPTION 'Unknown variant % on order item', NEW.variant_id;
    END IF;

    NEW.unit_price := v_price;               -- catalog wins, always
  ELSE
    -- Historical rows keep their snapshotted price; only the derived
    -- total is recomputed.
    NEW.unit_price := OLD.unit_price;
  END IF;

  NEW.total_price := round(NEW.unit_price * NEW.quantity, 2);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_order_items_price ON public.order_items;
CREATE TRIGGER trg_order_items_price
  BEFORE INSERT OR UPDATE ON public.order_items
  FOR EACH ROW EXECUTE FUNCTION internal.snap_order_item();


-- ---------------------------------------------------------------------------
-- 3. subscription_items: price from the catalog, immutable afterwards
-- ---------------------------------------------------------------------------
-- This is the column the daily run sheet bills against
-- (Hetha_admin/services/dailyOps/generateRunSheet.ts), so it is the highest
-- value target in the schema.
CREATE OR REPLACE FUNCTION internal.snap_subscription_item()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, internal
AS $$
DECLARE
  v_price numeric;
  v_label text;
  v_name  text;
BEGIN
  IF internal.money_checks_disabled() THEN
    RETURN NEW;
  END IF;

  IF NEW.quantity IS NULL OR NEW.quantity < 1 THEN
    RAISE EXCEPTION 'Subscription item quantity must be at least 1';
  END IF;

  IF TG_OP = 'INSERT' THEN
    SELECT round(pv.price, 2), pv.label, p.name
    INTO v_price, v_label, v_name
    FROM public.product_variants pv
    JOIN public.products p ON p.id = pv.product_id
    WHERE pv.id = NEW.variant_id
      AND COALESCE(pv.is_active, true) = true;

    IF v_price IS NULL THEN
      RAISE EXCEPTION 'Unknown or inactive variant % on subscription item', NEW.variant_id;
    END IF;

    NEW.unit_price             := v_price;
    NEW.product_name_snapshot  := COALESCE(NULLIF(NEW.product_name_snapshot, ''), v_name);
    NEW.variant_label_snapshot := COALESCE(NULLIF(NEW.variant_label_snapshot, ''), v_label);

  ELSIF NEW.unit_price IS DISTINCT FROM OLD.unit_price THEN
    RAISE EXCEPTION
      'subscription_items.unit_price is immutable (attempted % → %). Remove the item and add it again, or SET LOCAL hetha.skip_money_checks = ''on'' for a deliberate correction.',
      OLD.unit_price, NEW.unit_price;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_subscription_items_price ON public.subscription_items;
CREATE TRIGGER trg_subscription_items_price
  BEFORE INSERT OR UPDATE ON public.subscription_items
  FOR EACH ROW EXECUTE FUNCTION internal.snap_subscription_item();


-- ---------------------------------------------------------------------------
-- 4. subscription_daily_orders: total_value must equal its items
-- ---------------------------------------------------------------------------
-- Also catches the drift bug in Hetha_admin/services/dailyOps/orders.ts
-- (`updateDailyOrderItem` used to change an item's total_price without
-- recalculating the parent, so finalize_daily_run debited a stale amount).
CREATE OR REPLACE FUNCTION internal.assert_daily_order_total()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, internal
AS $$
DECLARE
  v_id    uuid;
  v_total numeric;
  v_sum   numeric;
  v_count integer;
BEGIN
  IF internal.money_checks_disabled() THEN
    RETURN NULL;
  END IF;

  IF TG_TABLE_NAME = 'subscription_daily_orders' THEN
    IF TG_OP = 'DELETE' THEN v_id := OLD.id; ELSE v_id := NEW.id; END IF;
  ELSE
    IF TG_OP = 'DELETE' THEN v_id := OLD.daily_order_id; ELSE v_id := NEW.daily_order_id; END IF;
  END IF;

  SELECT total_value INTO v_total
  FROM public.subscription_daily_orders WHERE id = v_id;

  IF NOT FOUND THEN
    RETURN NULL;                             -- parent removed in this tx
  END IF;

  SELECT COALESCE(SUM(total_price), 0), COUNT(*)
  INTO v_sum, v_count
  FROM public.subscription_daily_order_items WHERE daily_order_id = v_id;

  -- A parent with no items yet is normal mid-generation; only compare when the
  -- items exist.
  IF v_count > 0 AND round(v_total, 2) <> round(v_sum, 2) THEN
    RAISE EXCEPTION
      'Daily order % total_value (%) does not match its items (%)', v_id, v_total, v_sum;
  END IF;

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_daily_order_total ON public.subscription_daily_orders;
CREATE CONSTRAINT TRIGGER trg_daily_order_total
  AFTER INSERT OR UPDATE OF total_value ON public.subscription_daily_orders
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION internal.assert_daily_order_total();

DROP TRIGGER IF EXISTS trg_daily_order_items_total ON public.subscription_daily_order_items;
CREATE CONSTRAINT TRIGGER trg_daily_order_items_total
  AFTER INSERT OR UPDATE OR DELETE ON public.subscription_daily_order_items
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION internal.assert_daily_order_total();


-- ---------------------------------------------------------------------------
-- 5. Pre-existing rows that already violate the invariants
-- ---------------------------------------------------------------------------
-- The triggers only fire on new/changed rows, so nothing breaks retroactively —
-- but list the offenders so you can decide what to do with them. (A legacy
-- `AH-…` ad-hoc order from the old direct-INSERT admin code is the likely hit.)
--
-- SELECT o.order_number, o.subtotal, o.delivery_charge, o.total,
--        COALESCE(SUM(oi.total_price), 0) AS item_sum, COUNT(oi.id) AS items
-- FROM public.orders o
-- LEFT JOIN public.order_items oi ON oi.order_id = o.id
-- GROUP BY o.id, o.order_number, o.subtotal, o.delivery_charge, o.total
-- HAVING COUNT(oi.id) = 0
--     OR round(o.subtotal, 2) <> round(COALESCE(SUM(oi.total_price), 0), 2)
--     OR round(o.total, 2) <> round(o.subtotal + COALESCE(o.delivery_charge, 0), 2);
--
-- SELECT d.id, d.delivery_date, d.total_value, COALESCE(SUM(i.total_price), 0) AS item_sum
-- FROM public.subscription_daily_orders d
-- LEFT JOIN public.subscription_daily_order_items i ON i.daily_order_id = d.id
-- GROUP BY d.id, d.delivery_date, d.total_value
-- HAVING COUNT(i.id) > 0
--    AND round(d.total_value, 2) <> round(COALESCE(SUM(i.total_price), 0), 2);
