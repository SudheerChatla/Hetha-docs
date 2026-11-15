-- Migration 038: Daily Ops structure (Phase 2)
--
-- Run in: Supabase SQL Editor (the whole file; it is wrapped in one transaction)
--
-- ─── Problem ────────────────────────────────────────────────────────────────
-- After migration 037 every money event on a daily order is one database
-- function, but the rest of Daily Ops was still built from separate API writes:
--
--   1. GENERATION. The admin panel deleted "clean" orders, read every
--      subscription, filtered them in TypeScript and inserted orders and items
--      in separate requests. A failure half-way left a half-generated day, and
--      the subscription read was capped by the 1000-row Data API limit.
--   2. THE DELIVERY-DAY RULE ("does this subscription deliver on date X") was
--      written three times: generateRunSheet.ts, lib/deliverySchedule.ts and
--      internal.next_delivery_date. The wallet forecast and the low-balance
--      reminder (migration 039) need it a fourth time.
--   3. ADD / REMOVE ITEM on the run sheet were several writes, and adding an
--      item sent the price from the browser.
--   4. NOTHING IN THE DATABASE STOPPED A DIRECT WRITE to a finalized order.
--      Any admin with daily_ops:edit could change a finalized order's status,
--      paid_amount or payment_status, or add an item to it, without going
--      through the settlement functions.
--   5. The app decided "can this day still be changed" from the phone clock.
--
-- ─── Fix ─────────────────────────────────────────────────────────────────────
--   internal.subscription_delivers_on(sub, date)  the delivery-day rule, once
--   internal.subscription_items_on(sub, date)     the items that go out that day
--   public.generate_daily_run(date, admin)        generation, all-or-nothing
--   public.add_daily_order_item(order, variant, qty)   priced from the catalog
--   public.remove_daily_order_item(item)               refunds an emptied paid order
--   public.set_daily_order_item_quantity(item, qty)
--   public.get_earliest_change_date(sub)          the cut-off, for the app (M-01)
--
--   Finalized-day lock: two triggers refuse direct writes that the Daily Ops
--   functions did not make.
--     • Payment and finalize fields (paid_amount, payment_status, is_finalized,
--       finalized_at/by, skip_reason, settled_at, settlement_hold_reason,
--       wallet_deducted_at) change only inside those functions.
--     • A finalized order: only tracking_info and custom_route may change
--       directly; its items: only delivered_qty (0 … quantity). Nothing at
--       all on a reconciled day. A finalized order cannot be deleted.
--     • A new order is inserted unpaid and unfinalized, and not onto a day
--       that is already finalized or reconciled.
--
--   HOW THE TRIGGERS KNOW THE CALLER IS TRUSTED. Each trusted function is
--   declared with   SET hetha.daily_ops_rpc = 'on'.   Postgres applies that
--   setting only while the function runs and restores it when it returns, so
--   nothing outside the function can use it. The 037 functions get it with
--   ALTER FUNCTION (their bodies are unchanged). Also trusted: the SQL Editor
--   (jwt role 'internal', for the owner's manual hold review, D-9) and the
--   documented escape hatch SET LOCAL hetha.skip_money_checks = 'on'.
--
--   !! Any later migration that re-declares one of these functions with
--   !! CREATE OR REPLACE must keep the line   SET hetha.daily_ops_rpc TO 'on'
--   !! or the function will be refused by the triggers.
--
--   A user_id change on a finalized order is allowed only when the old user
--   no longer exists: that is the ON UPDATE CASCADE from claim_adhoc_user
--   re-keying a walk-in customer, never a hand edit.
--
--   Customer functions (modify_daily_order, modify_daily_orders_bulk,
--   revert_daily_order, cancel_subscription, pauses) only touch orders that are
--   not finalized and insert them unpaid, so they pass the triggers unchanged.
--
-- ─── Rollout order ──────────────────────────────────────────────────────────
--   1. The admin panel with the Phase 1 code (Hetha_admin 9864f09 or later)
--      must already be deployed. The pre-037 panel wrote order status and
--      payment fields directly; those writes are refused from now on.
--   2. Apply THIS migration.
--   3. Deploy the admin panel with P2-06 / P2-07 (Generate and item edits call
--      the functions above). Until then the old TypeScript generator still
--      works (it only deletes unfinalized orders and inserts unpaid ones), and
--      adding/removing items on a draft day still works.
--   4. Release the app with M-01 (uses get_earliest_change_date). Older app
--      builds keep working; the database already enforces the cut-off.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. The delivery-day rule
-- ---------------------------------------------------------------------------
-- Same rule as the TypeScript generator it replaces, in this order:
--   moved away from this date (move override from_date) → no
--   paused (first and last day of a pause included)      → no
--   moved to this date (move override to_date)           → skips the start,
--                                                          end and cadence checks
--   before start_date / after end_date                   → no
--   cadence: the area's (or the area borrowed by a swap override) when its
--            frequency > 1 and it has a reference date; else the
--            subscription's own frequency counted from start_date
--   at least one active item on that date                → else no
CREATE OR REPLACE FUNCTION internal.subscription_delivers_on(p_subscription_id uuid, p_date date)
  RETURNS boolean
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_sub        record;
  v_area       record;
  v_swap_area  uuid;
  v_force      boolean := false;
  v_d          integer;
BEGIN
  IF p_subscription_id IS NULL OR p_date IS NULL THEN
    RETURN false;
  END IF;

  SELECT status, start_date, end_date, delivary_area, delivary_frequency
  INTO v_sub
  FROM public.subscriptions WHERE id = p_subscription_id;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF v_sub.status NOT IN ('active', 'pending_cancellation') THEN
    RETURN false;
  END IF;

  -- Moved away from this date.
  IF EXISTS (
    SELECT 1 FROM public.delivery_day_overrides o
    JOIN public.delivery_day_override_subscriptions s ON s.override_id = o.id
    WHERE o.override_kind = 'move' AND o.from_date = p_date
      AND s.subscription_id = p_subscription_id
  ) THEN
    RETURN false;
  END IF;

  -- Paused. Applies even to a delivery moved onto this date.
  IF EXISTS (
    SELECT 1 FROM public.subscription_pauses p
    WHERE p.subscription_id = p_subscription_id
      AND p.pause_start_date <= p_date AND p.pause_end_date >= p_date
  ) THEN
    RETURN false;
  END IF;

  -- Moved onto this date.
  v_force := EXISTS (
    SELECT 1 FROM public.delivery_day_overrides o
    JOIN public.delivery_day_override_subscriptions s ON s.override_id = o.id
    WHERE o.override_kind = 'move' AND o.to_date = p_date
      AND s.subscription_id = p_subscription_id
  );

  IF NOT v_force THEN
    IF v_sub.end_date IS NOT NULL AND v_sub.end_date < p_date THEN
      RETURN false;
    END IF;
    IF v_sub.start_date IS NOT NULL AND v_sub.start_date > p_date THEN
      RETURN false;
    END IF;

    -- Effective area: the one borrowed by a swap override for this date, if
    -- any (newest override wins), else the subscription's own area.
    SELECT o.swapped_with_area_id INTO v_swap_area
    FROM public.delivery_day_overrides o
    JOIN public.delivery_day_override_subscriptions s ON s.override_id = o.id
    WHERE o.override_kind = 'swap' AND o.override_date = p_date
      AND s.subscription_id = p_subscription_id
    ORDER BY o.created_at DESC NULLS LAST, o.id
    LIMIT 1;

    IF v_swap_area IS NOT NULL THEN
      SELECT delivary_frequency, reference_date INTO v_area
      FROM public.delivery_areas WHERE id = v_swap_area;
    ELSE
      SELECT delivary_frequency, reference_date INTO v_area
      FROM public.delivery_areas WHERE display_name = v_sub.delivary_area
      LIMIT 1;
    END IF;

    IF FOUND AND COALESCE(v_area.delivary_frequency, 1) > 1 AND v_area.reference_date IS NOT NULL THEN
      v_d := p_date - v_area.reference_date;
      IF v_d < 0 OR v_d % v_area.delivary_frequency <> 0 THEN
        RETURN false;
      END IF;
    ELSIF COALESCE(v_sub.delivary_frequency, 1) > 1 AND v_sub.start_date IS NOT NULL THEN
      v_d := p_date - v_sub.start_date;
      IF v_d < 0 OR v_d % v_sub.delivary_frequency <> 0 THEN
        RETURN false;
      END IF;
    END IF;
  END IF;

  RETURN EXISTS (
    SELECT 1 FROM public.subscription_items i
    WHERE i.subscription_id = p_subscription_id
      AND i.is_active = true
      AND i.item_start_date <= p_date
      AND (i.item_end_date IS NULL OR i.item_end_date >= p_date)
  );
END;
$function$;

-- The items that go out on that date (the item filter of the rule above).
CREATE OR REPLACE FUNCTION internal.subscription_items_on(p_subscription_id uuid, p_date date)
  RETURNS SETOF public.subscription_items
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
  SELECT i.*
  FROM public.subscription_items i
  WHERE i.subscription_id = p_subscription_id
    AND i.is_active = true
    AND i.item_start_date <= p_date
    AND (i.item_end_date IS NULL OR i.item_end_date >= p_date)
  ORDER BY i.item_start_date, i.id;
$function$;

REVOKE ALL ON FUNCTION internal.subscription_delivers_on(uuid, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION internal.subscription_items_on(uuid, date)    FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. generate_daily_run — run-sheet generation in one transaction
-- ---------------------------------------------------------------------------
-- Deletes the day's "clean" orders (nothing staff, the customer or the wallet
-- has touched) so they are rebuilt from the current subscription, then
-- creates an order for every subscription that delivers on the date and has
-- none yet. Refused on a finalized or reconciled date.
-- The order cut-off is NOT checked here: migration 036 applies it when a
-- subscription is created, edited or paused.
CREATE OR REPLACE FUNCTION public.generate_daily_run(p_delivery_date date, p_admin_id uuid)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
  SET hetha.daily_ops_rpc TO 'on'
AS $function$
DECLARE
  v_run_id     uuid;
  v_run_status text;
  v_deleted    integer := 0;
  v_generated  integer := 0;
  v_existing   integer := 0;
  v_live       integer := 0;
  v_total      numeric;
  v_order_id   uuid;
  v_sub        record;
  v_clean      uuid[];
BEGIN
  IF NOT internal.is_admin_actor('daily_ops:edit') THEN
    RAISE EXCEPTION 'Not authorized to generate a delivery run';
  END IF;
  IF p_delivery_date IS NULL THEN
    RAISE EXCEPTION 'A delivery date is required';
  END IF;

  INSERT INTO public.daily_ops_runs (delivery_date, status, generated_by, generated_at)
  VALUES (p_delivery_date, 'draft', p_admin_id, now())
  ON CONFLICT (delivery_date) DO NOTHING;

  SELECT id, status INTO v_run_id, v_run_status
  FROM public.daily_ops_runs WHERE delivery_date = p_delivery_date
  FOR UPDATE;

  IF v_run_status <> 'draft' THEN
    RAISE EXCEPTION 'This date is %. Unlock it before regenerating.', v_run_status;
  END IF;

  -- Clean orders: rebuilt from the subscription.
  SELECT COALESCE(array_agg(o.id), '{}') INTO v_clean
  FROM public.subscription_daily_orders o
  WHERE o.delivery_date = p_delivery_date
    AND o.status = 'pending'
    AND COALESCE(o.is_finalized, false) = false
    AND o.payment_status = 'pending'
    AND o.paid_amount = 0
    AND o.settlement_hold_reason IS NULL
    AND o.is_customer_modified = false
    AND COALESCE(o.custom_route, '') = ''
    AND COALESCE(o.tracking_info, '') = ''
    AND NOT EXISTS (
      SELECT 1 FROM public.subscription_daily_order_items i
      WHERE i.daily_order_id = o.id
        AND (i.is_adhoc_addition = true OR i.delivered_qty IS NOT NULL)
    );

  DELETE FROM public.subscription_daily_order_items WHERE daily_order_id = ANY (v_clean);
  DELETE FROM public.subscription_daily_orders      WHERE id = ANY (v_clean);
  v_deleted := cardinality(v_clean);

  SELECT count(*) INTO v_existing
  FROM public.subscription_daily_orders WHERE delivery_date = p_delivery_date;

  SELECT count(*) INTO v_live
  FROM public.subscriptions WHERE status IN ('active', 'pending_cancellation');

  FOR v_sub IN
    SELECT s.id, s.user_id
    FROM public.subscriptions s
    WHERE s.status IN ('active', 'pending_cancellation')
      AND NOT EXISTS (SELECT 1 FROM public.subscription_daily_orders o
                      WHERE o.subscription_id = s.id AND o.delivery_date = p_delivery_date)
      AND internal.subscription_delivers_on(s.id, p_delivery_date)
    ORDER BY s.created_at, s.id
  LOOP
    SELECT COALESCE(SUM(round(i.unit_price * i.quantity, 2)), 0) INTO v_total
    FROM internal.subscription_items_on(v_sub.id, p_delivery_date) i;

    CONTINUE WHEN v_total <= 0;

    INSERT INTO public.subscription_daily_orders
      (delivery_date, subscription_id, user_id, status, total_value, payment_status, is_finalized)
    VALUES (p_delivery_date, v_sub.id, v_sub.user_id, 'pending', v_total, 'pending', false)
    RETURNING id INTO v_order_id;

    INSERT INTO public.subscription_daily_order_items
      (daily_order_id, variant_id, product_name_snapshot, variant_label_snapshot,
       unit_price, quantity, total_price, is_adhoc_addition)
    SELECT v_order_id, i.variant_id, i.product_name_snapshot, i.variant_label_snapshot,
           i.unit_price, i.quantity, round(i.unit_price * i.quantity, 2), false
    FROM internal.subscription_items_on(v_sub.id, p_delivery_date) i;

    v_generated := v_generated + 1;
  END LOOP;

  UPDATE public.daily_ops_runs
  SET generated_at = now(), generated_by = p_admin_id, updated_at = now()
  WHERE id = v_run_id;

  RETURN jsonb_build_object(
    'generated', v_generated,
    'deleted',   v_deleted,
    'skipped',   GREATEST(v_live - v_generated - v_existing, 0),
    'date',      p_delivery_date);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. Item edits on a day's order (staff only; never exposed to the app, D-4)
-- ---------------------------------------------------------------------------
-- Shared checks: the order exists, is not finalized, is pending, not on hold.
CREATE OR REPLACE FUNCTION internal.lock_editable_daily_order(p_order_id uuid)
  RETURNS public.subscription_daily_orders
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_order public.subscription_daily_orders;
BEGIN
  SELECT * INTO v_order FROM public.subscription_daily_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Daily order not found';
  END IF;
  IF COALESCE(v_order.is_finalized, false) THEN
    RAISE EXCEPTION 'This day is finalized. Unlock it to change its orders.';
  END IF;
  IF v_order.status <> 'pending' THEN
    RAISE EXCEPTION 'Only a pending order can be changed (this one is %)', v_order.status;
  END IF;
  IF v_order.settlement_hold_reason IS NOT NULL THEN
    RAISE EXCEPTION 'This order is on payment hold and cannot be changed';
  END IF;
  RETURN v_order;
END;
$function$;

REVOKE ALL ON FUNCTION internal.lock_editable_daily_order(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.add_daily_order_item(p_order_id uuid, p_variant_id uuid, p_quantity integer)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
  SET hetha.daily_ops_rpc TO 'on'
AS $function$
DECLARE
  v_order   public.subscription_daily_orders;
  v_price   numeric;
  v_label   text;
  v_name    text;
  v_item_id uuid;
  v_total   numeric;
BEGIN
  IF NOT internal.is_admin_actor('daily_ops:edit') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF p_quantity IS NULL OR p_quantity < 1 OR p_quantity > 99 THEN
    RAISE EXCEPTION 'Quantity must be a whole number from 1 to 99';
  END IF;

  v_order := internal.lock_editable_daily_order(p_order_id);

  SELECT v.price, v.label, p.name INTO v_price, v_label, v_name
  FROM public.product_variants v
  JOIN public.products p ON p.id = v.product_id
  WHERE v.id = p_variant_id AND v.is_active = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'This product variant is not available';
  END IF;
  IF v_price IS NULL OR v_price <= 0 THEN
    RAISE EXCEPTION 'This product variant has no price';
  END IF;

  SELECT id INTO v_item_id
  FROM public.subscription_daily_order_items
  WHERE daily_order_id = p_order_id AND variant_id = p_variant_id
  ORDER BY id LIMIT 1;

  IF v_item_id IS NOT NULL THEN
    -- Same variant already on the order: raise its quantity, keep its price snapshot.
    UPDATE public.subscription_daily_order_items
    SET quantity = quantity + p_quantity,
        total_price = round(unit_price * (quantity + p_quantity), 2)
    WHERE id = v_item_id;
  ELSE
    INSERT INTO public.subscription_daily_order_items
      (daily_order_id, variant_id, product_name_snapshot, variant_label_snapshot,
       unit_price, quantity, total_price, is_adhoc_addition)
    VALUES (p_order_id, p_variant_id, v_name, v_label,
            v_price, p_quantity, round(v_price * p_quantity, 2), true);
  END IF;

  SELECT COALESCE(SUM(total_price), 0) INTO v_total
  FROM public.subscription_daily_order_items WHERE daily_order_id = p_order_id;
  UPDATE public.subscription_daily_orders SET total_value = v_total WHERE id = p_order_id;

  RETURN jsonb_build_object('order_id', p_order_id, 'total_value', v_total);
END;
$function$;

CREATE OR REPLACE FUNCTION public.remove_daily_order_item(p_item_id uuid)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
  SET hetha.daily_ops_rpc TO 'on'
AS $function$
DECLARE
  v_order_id  uuid;
  v_order     public.subscription_daily_orders;
  v_remaining integer;
  v_total     numeric;
  v_res       jsonb;
BEGIN
  IF NOT internal.is_admin_actor('daily_ops:edit') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT daily_order_id INTO v_order_id
  FROM public.subscription_daily_order_items WHERE id = p_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Item not found';
  END IF;

  v_order := internal.lock_editable_daily_order(v_order_id);

  DELETE FROM public.subscription_daily_order_items WHERE id = p_item_id;

  SELECT count(*), COALESCE(SUM(total_price), 0) INTO v_remaining, v_total
  FROM public.subscription_daily_order_items WHERE daily_order_id = v_order_id;

  IF v_remaining > 0 THEN
    UPDATE public.subscription_daily_orders SET total_value = v_total WHERE id = v_order_id;
    RETURN jsonb_build_object('deleted_order', false, 'cancelled', false, 'refunded', 0, 'total_value', v_total);
  END IF;

  IF v_order.paid_amount > 0 THEN
    -- Charged before an unlock: keep the row and its wallet history (D-8),
    -- cancel it and refund what was taken.
    UPDATE public.subscription_daily_orders
    SET status = 'cancelled', total_value = 0
    WHERE id = v_order_id;
    v_res := internal.settle_daily_order(v_order_id, 'raise', 'delivery cancelled');
    RETURN jsonb_build_object('deleted_order', false, 'cancelled', true,
                              'refunded', COALESCE((v_res->>'refunded')::numeric, 0), 'total_value', 0);
  END IF;

  DELETE FROM public.subscription_daily_orders WHERE id = v_order_id;
  RETURN jsonb_build_object('deleted_order', true, 'cancelled', false, 'refunded', 0, 'total_value', 0);
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_daily_order_item_quantity(p_item_id uuid, p_quantity integer)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
  SET hetha.daily_ops_rpc TO 'on'
AS $function$
DECLARE
  v_order_id uuid;
  v_total    numeric;
BEGIN
  IF NOT internal.is_admin_actor('daily_ops:edit') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF p_quantity IS NULL OR p_quantity < 1 OR p_quantity > 99 THEN
    RAISE EXCEPTION 'Quantity must be a whole number from 1 to 99 (to remove an item, use remove)';
  END IF;

  SELECT daily_order_id INTO v_order_id
  FROM public.subscription_daily_order_items WHERE id = p_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Item not found';
  END IF;

  PERFORM internal.lock_editable_daily_order(v_order_id);

  UPDATE public.subscription_daily_order_items
  SET quantity = p_quantity,
      total_price = round(unit_price * p_quantity, 2),
      delivered_qty = NULL
  WHERE id = p_item_id;

  SELECT COALESCE(SUM(total_price), 0) INTO v_total
  FROM public.subscription_daily_order_items WHERE daily_order_id = v_order_id;
  UPDATE public.subscription_daily_orders SET total_value = v_total WHERE id = v_order_id;

  RETURN jsonb_build_object('order_id', v_order_id, 'total_value', v_total);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4. Mark the migration 037 functions as trusted (bodies unchanged)
-- ---------------------------------------------------------------------------
ALTER FUNCTION internal.settle_daily_order(uuid, text, text)          SET hetha.daily_ops_rpc TO 'on';
ALTER FUNCTION public.finalize_daily_run(date, uuid)                  SET hetha.daily_ops_rpc TO 'on';
ALTER FUNCTION public.unlock_daily_run(date)                          SET hetha.daily_ops_rpc TO 'on';
ALTER FUNCTION public.record_subscription_delivery(uuid, jsonb, text) SET hetha.daily_ops_rpc TO 'on';
ALTER FUNCTION public.set_daily_order_status(uuid[], text)            SET hetha.daily_ops_rpc TO 'on';
ALTER FUNCTION public.retry_daily_order_payment(uuid)                 SET hetha.daily_ops_rpc TO 'on';
ALTER FUNCTION public.reconcile_daily_run(date, uuid)                 SET hetha.daily_ops_rpc TO 'on';

-- ---------------------------------------------------------------------------
-- 5. Finalized-day lock
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION internal.daily_ops_write_allowed()
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SET search_path TO 'internal', 'public'
AS $function$
  SELECT COALESCE(current_setting('hetha.daily_ops_rpc', true), '') = 'on'
      OR internal.money_checks_disabled()
      OR internal.jwt_role() = 'internal';
$function$;

CREATE OR REPLACE FUNCTION internal.guard_daily_order_write()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_run_status text;
BEGIN
  IF internal.daily_ops_write_allowed() THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.paid_amount <> 0
       OR NEW.payment_status IS DISTINCT FROM 'pending'
       OR COALESCE(NEW.is_finalized, false)
       OR NEW.finalized_at IS NOT NULL OR NEW.finalized_by IS NOT NULL
       OR NEW.skip_reason IS NOT NULL OR NEW.settled_at IS NOT NULL
       OR NEW.settlement_hold_reason IS NOT NULL OR NEW.wallet_deducted_at IS NOT NULL THEN
      RAISE EXCEPTION 'Payment and finalize fields can only be changed by the Daily Ops functions';
    END IF;
    SELECT status INTO v_run_status FROM public.daily_ops_runs WHERE delivery_date = NEW.delivery_date;
    IF v_run_status IN ('finalized', 'reconciled') THEN
      RAISE EXCEPTION 'This day is %. Unlock it to add orders.', v_run_status;
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    IF COALESCE(OLD.is_finalized, false) THEN
      RAISE EXCEPTION 'This order is finalized and cannot be deleted';
    END IF;
    RETURN OLD;   -- the paid-amount delete guard from 037 still applies
  END IF;

  -- UPDATE
  IF NEW.paid_amount            IS DISTINCT FROM OLD.paid_amount
     OR NEW.payment_status         IS DISTINCT FROM OLD.payment_status
     OR NEW.is_finalized           IS DISTINCT FROM OLD.is_finalized
     OR NEW.finalized_at           IS DISTINCT FROM OLD.finalized_at
     OR NEW.finalized_by           IS DISTINCT FROM OLD.finalized_by
     OR NEW.skip_reason            IS DISTINCT FROM OLD.skip_reason
     OR NEW.settled_at             IS DISTINCT FROM OLD.settled_at
     OR NEW.settlement_hold_reason IS DISTINCT FROM OLD.settlement_hold_reason
     OR NEW.wallet_deducted_at     IS DISTINCT FROM OLD.wallet_deducted_at THEN
    RAISE EXCEPTION 'Payment and finalize fields can only be changed by the Daily Ops functions';
  END IF;

  IF COALESCE(OLD.is_finalized, false) THEN
    SELECT status INTO v_run_status FROM public.daily_ops_runs WHERE delivery_date = OLD.delivery_date;
    IF v_run_status = 'reconciled' THEN
      RAISE EXCEPTION 'This day is reconciled and can no longer be changed';
    END IF;

    -- user_id may follow a re-keyed user (ON UPDATE CASCADE from
    -- claim_adhoc_user): allowed only when the old user row is gone.
    IF NEW.user_id IS DISTINCT FROM OLD.user_id
       AND EXISTS (SELECT 1 FROM public.users WHERE id = OLD.user_id) THEN
      RAISE EXCEPTION 'This order is finalized. Use the Daily Ops actions to change it.';
    END IF;

    IF (to_jsonb(NEW) - 'tracking_info' - 'custom_route' - 'user_id')
       IS DISTINCT FROM (to_jsonb(OLD) - 'tracking_info' - 'custom_route' - 'user_id') THEN
      RAISE EXCEPTION 'This order is finalized. Use the Daily Ops actions to change it.';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION internal.guard_daily_order_item_write()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_finalized  boolean;
  v_date       date;
  v_run_status text;
BEGIN
  IF internal.daily_ops_write_allowed() THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;

  SELECT COALESCE(is_finalized, false), delivery_date INTO v_finalized, v_date
  FROM public.subscription_daily_orders
  WHERE id = CASE WHEN TG_OP = 'DELETE' THEN OLD.daily_order_id ELSE NEW.daily_order_id END;

  IF NOT FOUND OR NOT v_finalized THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;

  IF TG_OP IN ('INSERT', 'DELETE') THEN
    RAISE EXCEPTION 'This order is finalized. Unlock the day to change its items.';
  END IF;

  -- UPDATE on a finalized order's item: only the delivered quantity, 0 … ordered.
  SELECT status INTO v_run_status FROM public.daily_ops_runs WHERE delivery_date = v_date;
  IF v_run_status = 'reconciled' THEN
    RAISE EXCEPTION 'This day is reconciled and can no longer be changed';
  END IF;
  IF (to_jsonb(NEW) - 'delivered_qty') IS DISTINCT FROM (to_jsonb(OLD) - 'delivered_qty') THEN
    RAISE EXCEPTION 'This order is finalized. Only the delivered quantity can be changed.';
  END IF;
  IF NEW.delivered_qty IS NOT NULL AND (NEW.delivered_qty < 0 OR NEW.delivered_qty > NEW.quantity) THEN
    RAISE EXCEPTION 'Delivered quantity must be between 0 and %', NEW.quantity;
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION internal.daily_ops_write_allowed()      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION internal.guard_daily_order_write()      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION internal.guard_daily_order_item_write() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_guard_daily_order_write ON public.subscription_daily_orders;
CREATE TRIGGER trg_guard_daily_order_write
  BEFORE INSERT OR UPDATE OR DELETE ON public.subscription_daily_orders
  FOR EACH ROW EXECUTE FUNCTION internal.guard_daily_order_write();

DROP TRIGGER IF EXISTS trg_guard_daily_order_item_write ON public.subscription_daily_order_items;
CREATE TRIGGER trg_guard_daily_order_item_write
  BEFORE INSERT OR UPDATE OR DELETE ON public.subscription_daily_order_items
  FOR EACH ROW EXECUTE FUNCTION internal.guard_daily_order_item_write();

-- ---------------------------------------------------------------------------
-- 6. get_earliest_change_date — the cut-off, for the app (M-01)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_earliest_change_date(p_subscription_id uuid)
  RETURNS date
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
BEGIN
  PERFORM internal.assert_subscription_access(p_subscription_id);
  RETURN internal.subscription_earliest_change_date(p_subscription_id);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 7. Grants
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.generate_daily_run(date, uuid)                FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.add_daily_order_item(uuid, uuid, integer)     FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.remove_daily_order_item(uuid)                 FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_daily_order_item_quantity(uuid, integer)  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_earliest_change_date(uuid)                FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.generate_daily_run(date, uuid)               TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.add_daily_order_item(uuid, uuid, integer)    TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.remove_daily_order_item(uuid)                TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_daily_order_item_quantity(uuid, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_earliest_change_date(uuid)               TO authenticated, service_role;

COMMIT;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- 1. The trusted functions carry the setting (expect 11 rows):
--      SELECT p.oid::regprocedure
--      FROM pg_proc p
--      WHERE 'hetha.daily_ops_rpc=on' = ANY (p.proconfig)
--      ORDER BY 1;
--
-- 2. Both lock triggers exist (2 rows):
--      SELECT tgname FROM pg_trigger
--      WHERE tgname IN ('trg_guard_daily_order_write', 'trg_guard_daily_order_item_write');
--
-- 3. The delivery-day rule agrees with today's run sheet. For a date that was
--    generated by the OLD panel and not edited since, expect 0 rows:
--      SELECT s.id
--      FROM public.subscriptions s
--      WHERE s.status IN ('active', 'pending_cancellation')
--        AND internal.subscription_delivers_on(s.id, DATE '<YYYY-MM-DD>')
--        <> EXISTS (SELECT 1 FROM public.subscription_daily_orders o
--                   WHERE o.subscription_id = s.id AND o.delivery_date = DATE '<YYYY-MM-DD>');
--
-- 4. Grants — expect t, t, t, t, t, f, f:
--      SELECT
--        has_function_privilege('authenticated', 'public.generate_daily_run(date, uuid)', 'EXECUTE'),
--        has_function_privilege('authenticated', 'public.add_daily_order_item(uuid, uuid, integer)', 'EXECUTE'),
--        has_function_privilege('authenticated', 'public.remove_daily_order_item(uuid)', 'EXECUTE'),
--        has_function_privilege('authenticated', 'public.set_daily_order_item_quantity(uuid, integer)', 'EXECUTE'),
--        has_function_privilege('authenticated', 'public.get_earliest_change_date(uuid)', 'EXECUTE'),
--        has_function_privilege('anon',          'public.generate_daily_run(date, uuid)', 'EXECUTE'),
--        has_function_privilege('authenticated', 'internal.subscription_delivers_on(uuid, date)', 'EXECUTE');
--
-- Rollback of the lock only (keeps the functions):
--      DROP TRIGGER IF EXISTS trg_guard_daily_order_write ON public.subscription_daily_orders;
--      DROP TRIGGER IF EXISTS trg_guard_daily_order_item_write ON public.subscription_daily_order_items;
