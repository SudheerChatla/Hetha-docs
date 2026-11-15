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
--   HOW THE TRIGGERS KNOW THE CALLER IS TRUSTED. The first statement of each
--   trusted function is
--       PERFORM set_config('hetha.daily_ops_rpc', 'on', true);
--   (transaction-local). The seven 037 functions are re-declared below with
--   their bodies copied unchanged plus that one line. A PostgREST request is
--   one transaction that runs one function, so the flag never reaches a
--   caller's own statements. Also trusted: the SQL Editor (jwt role
--   'internal', for the owner's manual hold review, D-9) and the documented
--   escape hatch SET LOCAL hetha.skip_money_checks = 'on'.
--   (A function-level  SET hetha.daily_ops_rpc = 'on'  would be tidier, but
--   the Supabase postgres role is not allowed to attach a custom setting to a
--   function: "permission denied to set parameter".)
--
--   !! Any later migration that re-declares one of these functions with
--   !! CREATE OR REPLACE must keep the PERFORM set_config(...) line, or the
--   !! function will be refused by the triggers.
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
  PERFORM set_config('hetha.daily_ops_rpc', 'on', true);  -- trusted by the finalized-day lock
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
AS $function$
DECLARE
  v_order   public.subscription_daily_orders;
  v_price   numeric;
  v_label   text;
  v_name    text;
  v_item_id uuid;
  v_total   numeric;
BEGIN
  PERFORM set_config('hetha.daily_ops_rpc', 'on', true);  -- trusted by the finalized-day lock
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
AS $function$
DECLARE
  v_order_id  uuid;
  v_order     public.subscription_daily_orders;
  v_remaining integer;
  v_total     numeric;
  v_res       jsonb;
BEGIN
  PERFORM set_config('hetha.daily_ops_rpc', 'on', true);  -- trusted by the finalized-day lock
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
AS $function$
DECLARE
  v_order_id uuid;
  v_total    numeric;
BEGIN
  PERFORM set_config('hetha.daily_ops_rpc', 'on', true);  -- trusted by the finalized-day lock
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
-- 4. Mark the migration 037 functions as trusted
-- ---------------------------------------------------------------------------
-- Bodies copied UNCHANGED from migration 037; the only added line is the
-- PERFORM set_config(...) flag at the top. Grants are unchanged (CREATE OR
-- REPLACE keeps them).

CREATE OR REPLACE FUNCTION internal.settle_daily_order(
  p_order_id      uuid,
  p_on_short      text DEFAULT 'raise',
  p_refund_reason text DEFAULT NULL
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_order    public.subscription_daily_orders;
  v_method   text;
  v_owed     numeric;
  v_diff     numeric;
  v_balance  numeric;
  v_charged  numeric := 0;
  v_refunded numeric := 0;
  v_refund_text text;
BEGIN
  PERFORM set_config('hetha.daily_ops_rpc', 'on', true);  -- trusted by the finalized-day lock
  IF p_on_short NOT IN ('skip', 'raise') THEN
    RAISE EXCEPTION 'settle_daily_order: p_on_short must be skip or raise';
  END IF;

  SELECT * INTO v_order
  FROM public.subscription_daily_orders WHERE id = p_order_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Daily order not found';
  END IF;

  IF v_order.settlement_hold_reason IS NOT NULL THEN
    RAISE EXCEPTION 'This order''s payment history needs review before money can move: %',
      v_order.settlement_hold_reason;
  END IF;

  SELECT payment_method INTO v_method
  FROM public.subscriptions WHERE id = v_order.subscription_id;

  -- Cash on delivery: nothing moves through the wallet.
  IF COALESCE(v_method, 'wallet') <> 'wallet' THEN
    RETURN jsonb_build_object(
      'charged', 0, 'refunded', 0, 'skipped', false, 'wallet', false,
      'owed', internal.daily_order_amount_owed(p_order_id),
      'paid_amount', v_order.paid_amount, 'user_id', v_order.user_id);
  END IF;

  v_owed := internal.daily_order_amount_owed(p_order_id);
  v_diff := round(v_owed - v_order.paid_amount, 2);
  v_refund_text := 'Refund: ' || COALESCE(p_refund_reason, 'subscription delivery')
                   || ' ' || v_order.delivery_date::text;

  IF v_diff > 0 THEN
    SELECT COALESCE(wallet_balance, 0) INTO v_balance
    FROM public.users WHERE id = v_order.user_id FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'User not found';
    END IF;

    IF v_balance < v_diff THEN
      IF p_on_short = 'raise' THEN
        RAISE EXCEPTION
          'Wallet balance (%) is too low to charge % for this order. Ask the customer to recharge.',
          v_balance, v_diff;
      END IF;

      -- Skip the order for the day and give back anything already taken
      -- (only possible when the order was paid, then unlocked and enlarged).
      IF v_order.paid_amount > 0 THEN
        PERFORM internal.apply_wallet_delta(
          v_order.user_id, v_order.paid_amount, 'credit',
          'Refund: delivery skipped (low wallet balance) ' || v_order.delivery_date::text,
          'admin', 'subscription', v_order.id::text);
        v_refunded := v_order.paid_amount;
      END IF;

      UPDATE public.subscription_daily_orders
      SET status         = 'skipped',
          skip_reason    = 'insufficient_balance',
          paid_amount    = 0,
          payment_status = 'failed',
          settled_at     = now()
      WHERE id = p_order_id;

      RETURN jsonb_build_object(
        'charged', 0, 'refunded', v_refunded, 'skipped', true, 'wallet', true,
        'owed', v_owed, 'paid_amount', 0, 'user_id', v_order.user_id,
        'shortfall', round(v_diff - v_balance, 2));
    END IF;

    PERFORM internal.apply_wallet_delta(
      v_order.user_id, v_diff, 'debit',
      'Subscription delivery ' || v_order.delivery_date::text,
      'admin', 'subscription', v_order.id::text);
    v_charged := v_diff;

  ELSIF v_diff < 0 THEN
    PERFORM internal.apply_wallet_delta(
      v_order.user_id, -v_diff, 'credit', v_refund_text,
      'admin', 'subscription', v_order.id::text);
    v_refunded := -v_diff;
  END IF;

  UPDATE public.subscription_daily_orders
  SET paid_amount    = v_owed,
      payment_status = CASE
                         WHEN v_owed > 0 THEN 'paid'
                         WHEN v_order.paid_amount > 0 THEN 'refunded'
                         ELSE payment_status
                       END,
      wallet_deducted_at = CASE WHEN v_charged > 0 THEN now() ELSE wallet_deducted_at END,
      settled_at     = now()
  WHERE id = p_order_id;

  RETURN jsonb_build_object(
    'charged', v_charged, 'refunded', v_refunded, 'skipped', false, 'wallet', true,
    'owed', v_owed, 'paid_amount', v_owed, 'user_id', v_order.user_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.finalize_daily_run(p_delivery_date date, p_admin_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_run_id      uuid;
  v_run_status  text;
  v_order       record;
  v_res         jsonb;
  v_charged     jsonb := '[]'::jsonb;
  v_skipped     jsonb := '[]'::jsonb;
  v_errors      jsonb := '[]'::jsonb;
  v_total_deducted numeric := 0;
  v_total_refunded numeric := 0;
  v_total_value    numeric := 0;
  v_total_orders   integer := 0;
BEGIN
  PERFORM set_config('hetha.daily_ops_rpc', 'on', true);  -- trusted by the finalized-day lock
  IF NOT internal.is_admin_actor('daily_ops:edit') THEN
    RAISE EXCEPTION 'Not authorized to finalize a delivery run';
  END IF;

  INSERT INTO public.daily_ops_runs (delivery_date, status, generated_by, generated_at)
  VALUES (p_delivery_date, 'draft', p_admin_id, now())
  ON CONFLICT (delivery_date) DO NOTHING;

  -- The row lock makes a second, simultaneous finalize wait here and then
  -- fail the status check below, so a day can never be charged twice.
  SELECT id, status INTO v_run_id, v_run_status
  FROM public.daily_ops_runs
  WHERE delivery_date = p_delivery_date
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Run record not found for %', p_delivery_date;
  END IF;

  IF v_run_status <> 'draft' THEN
    RAISE EXCEPTION 'Cannot finalize: date is already %', v_run_status;
  END IF;

  UPDATE public.subscription_daily_orders
  SET is_finalized = true,
      finalized_at = now(),
      finalized_by = p_admin_id
  WHERE delivery_date = p_delivery_date
    AND status = 'pending'
    AND is_finalized = false;

  -- Charging order: per customer, oldest subscription first. When a wallet
  -- cannot cover every order, the older subscription is the one delivered.
  FOR v_order IN
    SELECT sdo.id, sdo.user_id, sdo.total_value
    FROM public.subscription_daily_orders sdo
    JOIN public.subscriptions s ON s.id = sdo.subscription_id
    WHERE sdo.delivery_date = p_delivery_date
      AND sdo.is_finalized = true
      AND sdo.status = 'pending'
      AND s.payment_method = 'wallet'
    ORDER BY sdo.user_id, s.created_at, s.id, sdo.id
  LOOP
    BEGIN
      v_res := internal.settle_daily_order(v_order.id, 'skip', 'order changed');

      IF (v_res->>'skipped')::boolean THEN
        v_skipped := v_skipped || jsonb_build_object(
          'order_id', v_order.id, 'user_id', v_order.user_id,
          'amount', (v_res->>'owed')::numeric, 'reason', 'insufficient_balance');
      ELSIF (v_res->>'charged')::numeric > 0 THEN
        v_charged := v_charged || jsonb_build_object(
          'order_id', v_order.id, 'user_id', v_order.user_id,
          'amount', (v_res->>'charged')::numeric);
      END IF;

      v_total_deducted := v_total_deducted + (v_res->>'charged')::numeric;
      v_total_refunded := v_total_refunded + (v_res->>'refunded')::numeric;

    EXCEPTION WHEN OTHERS THEN
      -- Anything unexpected (for example an order on payment hold): the order
      -- must not go out unpaid, so it is skipped and reported, not delivered.
      v_errors := v_errors || jsonb_build_object(
        'order_id', v_order.id, 'user_id', v_order.user_id,
        'amount', v_order.total_value, 'error', SQLERRM);

      UPDATE public.subscription_daily_orders
      SET status = 'skipped', skip_reason = 'payment_error', payment_status = 'failed'
      WHERE id = v_order.id;
    END;
  END LOOP;

  -- Refund sweep: a skipped or cancelled order of this day that still holds
  -- money (cancelled while the day was unlocked, or by a direct table update)
  -- owes nothing, so settle gives the money back.
  FOR v_order IN
    SELECT id, user_id, total_value
    FROM public.subscription_daily_orders
    WHERE delivery_date = p_delivery_date
      AND status IN ('skipped', 'cancelled')
      AND paid_amount > 0
      AND settlement_hold_reason IS NULL
    ORDER BY user_id, id
  LOOP
    v_res := internal.settle_daily_order(
      v_order.id, 'raise', 'delivery skipped');
    v_total_refunded := v_total_refunded + (v_res->>'refunded')::numeric;
  END LOOP;

  SELECT COUNT(*), COALESCE(SUM(total_value), 0)
  INTO v_total_orders, v_total_value
  FROM public.subscription_daily_orders
  WHERE delivery_date = p_delivery_date
    AND is_finalized = true
    AND status NOT IN ('skipped', 'cancelled');

  UPDATE public.daily_ops_runs
  SET status = 'finalized',
      finalized_at = now(),
      finalized_by = p_admin_id,
      total_orders = v_total_orders,
      total_value = v_total_value,
      wallet_deduction_completed_at = now(),
      updated_at = now()
  WHERE id = v_run_id;

  RETURN jsonb_build_object(
    'finalized',        v_total_orders,
    'total_deducted',   v_total_deducted,
    'total_refunded',   v_total_refunded,
    'total_value',      v_total_value,
    'charged',          v_charged,
    'skipped',          v_skipped,
    'deduction_errors', v_errors
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.unlock_daily_run(p_delivery_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_run_id     uuid;
  v_run_status text;
  v_reopened   integer := 0;
BEGIN
  PERFORM set_config('hetha.daily_ops_rpc', 'on', true);  -- trusted by the finalized-day lock
  IF NOT (internal.is_service_actor() OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Only a super admin can unlock a finalized day';
  END IF;

  SELECT id, status INTO v_run_id, v_run_status
  FROM public.daily_ops_runs
  WHERE delivery_date = p_delivery_date
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No run exists for %', p_delivery_date;
  END IF;
  IF v_run_status = 'reconciled' THEN
    RAISE EXCEPTION 'This day is reconciled and cannot be unlocked';
  END IF;
  IF v_run_status <> 'finalized' THEN
    RAISE EXCEPTION 'This day is not finalized';
  END IF;

  UPDATE public.daily_ops_runs
  SET status = 'draft', finalized_at = NULL, finalized_by = NULL, updated_at = now()
  WHERE id = v_run_id;

  UPDATE public.subscription_daily_orders
  SET is_finalized = false, finalized_at = NULL, finalized_by = NULL
  WHERE delivery_date = p_delivery_date
    AND is_finalized = true
    AND status = 'pending';
  GET DIAGNOSTICS v_reopened = ROW_COUNT;

  RETURN jsonb_build_object('reopened', v_reopened);
END;
$function$;

CREATE OR REPLACE FUNCTION public.record_subscription_delivery(
  p_daily_order_id uuid,
  p_items          jsonb,
  p_note           text DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_order         public.subscription_daily_orders;
  v_run_status    text;
  v_item          jsonb;
  v_item_id       uuid;
  v_delivered_qty integer;
  v_quantity      integer;
  v_all_zero      boolean;
  v_new_status    text;
  v_res           jsonb;
BEGIN
  PERFORM set_config('hetha.daily_ops_rpc', 'on', true);  -- trusted by the finalized-day lock
  IF NOT internal.is_admin_actor('daily_ops:edit') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT * INTO v_order
  FROM public.subscription_daily_orders WHERE id = p_daily_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Daily order not found';
  END IF;

  SELECT status INTO v_run_status
  FROM public.daily_ops_runs WHERE delivery_date = v_order.delivery_date;

  IF v_run_status = 'reconciled' THEN
    RAISE EXCEPTION 'This day is reconciled; deliveries can no longer be changed';
  END IF;
  IF NOT COALESCE(v_order.is_finalized, false) THEN
    RAISE EXCEPTION 'Finalize the day before recording deliveries';
  END IF;
  IF v_order.status = 'skipped' THEN
    IF v_order.skip_reason IS NOT NULL THEN
      RAISE EXCEPTION 'This order was skipped because the payment failed. Use Retry payment first.';
    END IF;
    RAISE EXCEPTION 'This order is skipped. Set it back to pending before recording a delivery.';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'p_items must be a JSON array';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_item_id       := (v_item->>'item_id')::uuid;
    v_delivered_qty := (v_item->>'delivered_qty')::integer;

    IF v_item_id IS NULL THEN
      RAISE EXCEPTION 'Each item must have an item_id';
    END IF;
    IF v_delivered_qty IS NULL THEN
      RAISE EXCEPTION 'Each item must have a delivered_qty';
    END IF;
    IF v_delivered_qty < 0 THEN
      RAISE EXCEPTION 'delivered_qty cannot be negative';
    END IF;

    SELECT quantity INTO v_quantity
    FROM public.subscription_daily_order_items
    WHERE id = v_item_id AND daily_order_id = p_daily_order_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Item % does not belong to this order', v_item_id;
    END IF;
    IF v_delivered_qty > v_quantity THEN
      RAISE EXCEPTION 'delivered_qty (%) exceeds the ordered quantity (%)', v_delivered_qty, v_quantity;
    END IF;

    UPDATE public.subscription_daily_order_items
    SET delivered_qty = v_delivered_qty
    WHERE id = v_item_id;
  END LOOP;

  -- Every line must be accounted for, otherwise the order would be marked
  -- delivered with some lines never checked and their shortfall never refunded.
  PERFORM 1 FROM public.subscription_daily_order_items
  WHERE daily_order_id = p_daily_order_id AND delivered_qty IS NULL
  LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Record a delivered quantity for every item in the order';
  END IF;

  SELECT COALESCE(bool_and(delivered_qty = 0), true) INTO v_all_zero
  FROM public.subscription_daily_order_items
  WHERE daily_order_id = p_daily_order_id;

  v_new_status := CASE WHEN v_all_zero THEN 'cancelled' ELSE 'delivered' END;

  UPDATE public.subscription_daily_orders
  SET status        = v_new_status,
      skip_reason   = NULL,
      tracking_info = COALESCE(p_note, tracking_info)
  WHERE id = p_daily_order_id;

  v_res := internal.settle_daily_order(
    p_daily_order_id, 'raise',
    CASE WHEN v_all_zero THEN 'not delivered' ELSE 'short delivery' END);

  RETURN jsonb_build_object(
    'status',   v_new_status,
    'refunded', (v_res->>'refunded')::numeric,
    'charged',  (v_res->>'charged')::numeric,
    'short',    (v_res->>'owed')::numeric < round(v_order.total_value, 2),
    'user_id',  v_order.user_id
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_daily_order_status(p_order_ids uuid[], p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_order      public.subscription_daily_orders;
  v_run_status text;
  v_res        jsonb;
  v_results    jsonb := '[]'::jsonb;
  v_updated    integer := 0;
  v_refunded   numeric := 0;
  v_charged    numeric := 0;
  v_id         uuid;
BEGIN
  PERFORM set_config('hetha.daily_ops_rpc', 'on', true);  -- trusted by the finalized-day lock
  IF NOT internal.is_admin_actor('daily_ops:edit') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF p_status IS NULL OR p_status NOT IN ('pending', 'delivered', 'skipped', 'cancelled') THEN
    RAISE EXCEPTION 'Invalid status: %', p_status;
  END IF;
  IF p_order_ids IS NULL OR array_length(p_order_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'At least one order is required';
  END IF;

  -- Fixed lock order (by id) so two staff changing overlapping selections
  -- cannot deadlock.
  FOR v_id IN SELECT DISTINCT x FROM unnest(p_order_ids) x ORDER BY x
  LOOP
    SELECT * INTO v_order
    FROM public.subscription_daily_orders WHERE id = v_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Daily order % not found', v_id;
    END IF;

    IF v_order.status = p_status THEN
      CONTINUE;
    END IF;

    SELECT status INTO v_run_status
    FROM public.daily_ops_runs WHERE delivery_date = v_order.delivery_date;
    IF v_run_status = 'reconciled' THEN
      RAISE EXCEPTION 'The day % is reconciled; its orders can no longer be changed', v_order.delivery_date;
    END IF;

    IF v_order.status = 'skipped' AND v_order.skip_reason IS NOT NULL
       AND p_status IN ('pending', 'delivered') THEN
      RAISE EXCEPTION 'An order was skipped because its payment failed. Use Retry payment for it.';
    END IF;

    IF p_status = 'delivered' THEN
      IF NOT COALESCE(v_order.is_finalized, false) THEN
        RAISE EXCEPTION 'Finalize the day before marking deliveries';
      END IF;
      UPDATE public.subscription_daily_order_items
      SET delivered_qty = quantity
      WHERE daily_order_id = v_id AND delivered_qty IS NULL;
    END IF;

    IF p_status = 'pending' THEN
      UPDATE public.subscription_daily_order_items
      SET delivered_qty = NULL
      WHERE daily_order_id = v_id AND delivered_qty IS NOT NULL;
    END IF;

    UPDATE public.subscription_daily_orders
    SET status = p_status, skip_reason = NULL
    WHERE id = v_id;
    v_updated := v_updated + 1;

    v_res := NULL;
    IF COALESCE(v_order.is_finalized, false)
       OR (p_status IN ('skipped', 'cancelled') AND v_order.paid_amount > 0) THEN
      v_res := internal.settle_daily_order(
        v_id, 'raise',
        CASE p_status WHEN 'skipped' THEN 'delivery skipped'
                      WHEN 'cancelled' THEN 'delivery cancelled'
                      ELSE 'short delivery' END);
      v_refunded := v_refunded + (v_res->>'refunded')::numeric;
      v_charged  := v_charged  + (v_res->>'charged')::numeric;
    END IF;

    v_results := v_results || jsonb_build_object(
      'order_id', v_id, 'user_id', v_order.user_id, 'status', p_status,
      'refunded', COALESCE((v_res->>'refunded')::numeric, 0),
      'charged',  COALESCE((v_res->>'charged')::numeric, 0));
  END LOOP;

  RETURN jsonb_build_object(
    'updated', v_updated, 'refunded', v_refunded, 'charged', v_charged, 'orders', v_results);
END;
$function$;

CREATE OR REPLACE FUNCTION public.retry_daily_order_payment(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_order      public.subscription_daily_orders;
  v_run_status text;
  v_res        jsonb;
BEGIN
  PERFORM set_config('hetha.daily_ops_rpc', 'on', true);  -- trusted by the finalized-day lock
  IF NOT internal.is_admin_actor('daily_ops:edit') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT * INTO v_order
  FROM public.subscription_daily_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Daily order not found';
  END IF;

  IF v_order.status <> 'skipped' OR v_order.skip_reason IS NULL THEN
    RAISE EXCEPTION 'Only an order skipped for a failed payment can be retried';
  END IF;

  SELECT status INTO v_run_status
  FROM public.daily_ops_runs WHERE delivery_date = v_order.delivery_date;
  IF v_run_status IS DISTINCT FROM 'finalized' THEN
    RAISE EXCEPTION 'Payment can only be retried while the day is finalized (it is %)',
      COALESCE(v_run_status, 'not started');
  END IF;

  UPDATE public.subscription_daily_orders
  SET status = 'pending', skip_reason = NULL, payment_status = 'pending',
      is_finalized = true, finalized_at = COALESCE(finalized_at, now())
  WHERE id = p_order_id;

  -- Raises (and rolls the order back to skipped) if the wallet is still short.
  v_res := internal.settle_daily_order(p_order_id, 'raise', NULL);

  UPDATE public.daily_ops_runs r
  SET total_orders = t.n, total_value = t.v, updated_at = now()
  FROM (
    SELECT COUNT(*) AS n, COALESCE(SUM(total_value), 0) AS v
    FROM public.subscription_daily_orders
    WHERE delivery_date = v_order.delivery_date
      AND is_finalized = true
      AND status NOT IN ('skipped', 'cancelled')
  ) t
  WHERE r.delivery_date = v_order.delivery_date;

  RETURN jsonb_build_object(
    'charged', (v_res->>'charged')::numeric, 'user_id', v_order.user_id, 'status', 'pending');
END;
$function$;

CREATE OR REPLACE FUNCTION public.reconcile_daily_run(p_delivery_date date, p_admin_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_run_id     uuid;
  v_run_status text;
  v_order      record;
  v_all_zero   boolean;
  v_missing    integer;
  v_res        jsonb;
  v_reconciled integer := 0;
  v_delivered_users jsonb := '[]'::jsonb;
  v_refunds    jsonb := '[]'::jsonb;
  v_errors     jsonb := '[]'::jsonb;
  v_total_refunded numeric := 0;
  v_total_charged  numeric := 0;
BEGIN
  PERFORM set_config('hetha.daily_ops_rpc', 'on', true);  -- trusted by the finalized-day lock
  IF NOT internal.is_admin_actor('daily_ops:edit') THEN
    RAISE EXCEPTION 'Not authorized to reconcile a delivery run';
  END IF;

  SELECT id, status INTO v_run_id, v_run_status
  FROM public.daily_ops_runs
  WHERE delivery_date = p_delivery_date
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No run exists for %', p_delivery_date;
  END IF;
  IF v_run_status <> 'finalized' THEN
    RAISE EXCEPTION 'Cannot reconcile: date is %', v_run_status;
  END IF;

  -- Step 0: every pending order must have a delivered quantity for every
  -- item. Nothing is assumed delivered.
  SELECT COUNT(DISTINCT o.id) INTO v_missing
  FROM public.subscription_daily_orders o
  JOIN public.subscription_daily_order_items i ON i.daily_order_id = o.id
  WHERE o.delivery_date = p_delivery_date
    AND o.is_finalized = true
    AND o.status = 'pending'
    AND i.delivered_qty IS NULL;

  IF v_missing > 0 THEN
    RAISE EXCEPTION
      'Cannot reconcile: % pending order(s) still have items with no delivered quantity. Record the delivered quantities (or mark those orders delivered, skipped or cancelled) and try again.',
      v_missing;
  END IF;

  -- Step 1: close out every order still pending, using the recorded quantities.
  FOR v_order IN
    SELECT id, user_id
    FROM public.subscription_daily_orders
    WHERE delivery_date = p_delivery_date
      AND is_finalized = true
      AND status = 'pending'
    ORDER BY user_id, id
    FOR UPDATE
  LOOP
    SELECT COALESCE(bool_and(delivered_qty = 0), true) INTO v_all_zero
    FROM public.subscription_daily_order_items
    WHERE daily_order_id = v_order.id;

    UPDATE public.subscription_daily_orders
    SET status = CASE WHEN v_all_zero THEN 'cancelled' ELSE 'delivered' END
    WHERE id = v_order.id;

    v_reconciled := v_reconciled + 1;
    IF NOT v_all_zero THEN
      v_delivered_users := v_delivered_users || to_jsonb(v_order.user_id);
    END IF;
  END LOOP;

  -- Step 2: settle every finalized order of the day against what is recorded.
  FOR v_order IN
    SELECT id, user_id, total_value
    FROM public.subscription_daily_orders
    WHERE delivery_date = p_delivery_date
      AND is_finalized = true
    ORDER BY user_id, id
  LOOP
    BEGIN
      v_res := internal.settle_daily_order(v_order.id, 'raise', 'short delivery');
      v_total_refunded := v_total_refunded + (v_res->>'refunded')::numeric;
      v_total_charged  := v_total_charged  + (v_res->>'charged')::numeric;
      IF (v_res->>'refunded')::numeric > 0 THEN
        v_refunds := v_refunds || jsonb_build_object(
          'order_id', v_order.id, 'user_id', v_order.user_id,
          'amount', (v_res->>'refunded')::numeric);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      -- The day still closes; the order is reported for manual follow-up.
      v_errors := v_errors || jsonb_build_object(
        'order_id', v_order.id, 'user_id', v_order.user_id,
        'amount', v_order.total_value, 'error', SQLERRM);
    END;
  END LOOP;

  UPDATE public.daily_ops_runs
  SET status = 'reconciled',
      reconciled_at = now(),
      reconciled_by = p_admin_id,
      updated_at = now()
  WHERE id = v_run_id;

  RETURN jsonb_build_object(
    'reconciled',        v_reconciled,
    'delivered_user_ids', v_delivered_users,
    'total_refunded',    v_total_refunded,
    'total_charged',     v_total_charged,
    'refunds',           v_refunds,
    'settlement_errors', v_errors
  );
END;
$function$;

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
-- 1. The trusted functions set the flag (expect 11 rows):
--      SELECT p.oid::regprocedure
--      FROM pg_proc p
--      WHERE p.prosrc LIKE '%set_config(''hetha.daily_ops_rpc'', ''on'', true)%'
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
