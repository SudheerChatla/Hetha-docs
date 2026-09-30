-- Migration 027: Atomic bulk day-edit RPC
--
-- Run in: Supabase SQL Editor (the whole file; it is wrapped in one transaction)
--
-- ─── Problem ────────────────────────────────────────────────────────────────
-- The "Edit multiple days" flow (Hetha_app, bulk_modify_subscription.dart) has
-- no bulk RPC. It loops client-side, calling public.modify_daily_order (022)
-- once per selected day:
--
--   1. NOT ATOMIC. Each call is its own transaction. If day 6 of 10 raises
--      (already finalized by admin, ownership lost, etc.), the loop stops —
--      days 1-5 are already committed, days 7-10 are never attempted, and the
--      customer sees one generic error with no idea which days actually saved.
--   2. NO AGGREGATE WALLET CHECK. modify_daily_order_core's 3-day-buffer rule
--      (025) reads the CURRENT stored wallet_balance on every call. Nothing a
--      day-edit does updates wallet_balance (debiting only happens later at
--      finalize_daily_run), so raising 10 different days by the same "extra"
--      amount in one sitting passes the check 10 times against the same
--      balance — the buffer never accounts for extras the customer already
--      queued up earlier in the same batch.
--
-- ─── Fix ─────────────────────────────────────────────────────────────────────
-- New public.modify_daily_orders_bulk(user, subscription, days) — days is a
-- jsonb array of {delivery_date, items:[{variant_id, quantity}]}:
--
--   1. Validates EVERY day first (ownership once, then per day: not in the
--      past, not finalized/non-pending/paid, priced from the catalog).
--   2. Sums every day's positive "extra" (new day cost above this
--      subscription's normal daily cost) into ONE total across the whole
--      batch, and checks the wallet ONCE:
--          wallet >= 3 x (all-subscription daily commitment) + total_extra
--      This is the same per-day formula from migration 025, aggregated across
--      the batch instead of re-checked in isolation per day.
--   3. Only after every day passes does it apply all deletes/inserts, in the
--      RPC's own implicit transaction — so the batch is all-or-nothing. A
--      failure on any day leaves every day exactly as it was before the call.
--
-- An empty items array for a day means "revert that day to the default",
-- mirroring saveDailyOrder's existing empty-items behaviour for a single day.
--
-- internal.modify_daily_order_core (022/025) and public.modify_daily_order /
-- revert_daily_order are UNCHANGED — single-day edits still go through them.

BEGIN;

CREATE OR REPLACE FUNCTION internal.modify_daily_orders_bulk_core(
  p_user_id         uuid,
  p_subscription_id uuid,
  p_days            jsonb,
  p_is_admin        boolean DEFAULT false
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_owner            uuid;
  v_day              jsonb;
  v_delivery_date    date;
  v_items            jsonb;
  v_day_count        integer;
  v_seen_dates       date[] := ARRAY[]::date[];
  v_new_daily        numeric;
  v_sub_base         numeric := 0;
  v_extra            numeric;
  v_total_extra      numeric := 0;
  v_committed        numeric := 0;
  v_wallet_balance   numeric := 0;
  v_required         numeric := 0;
  v_existing_status  text;
  v_existing_final   boolean;
  v_existing_pay     text;
  -- per-day plan, built during validation, applied during the write phase
  v_plan             jsonb := '[]'::jsonb;
  v_order_id         uuid;
  v_result_ids       jsonb := '[]'::jsonb;
BEGIN
  PERFORM internal.assert_subscription_access(p_subscription_id);

  SELECT user_id INTO v_owner FROM public.subscriptions WHERE id = p_subscription_id;
  IF v_owner IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'Subscription does not belong to this user';
  END IF;

  IF p_days IS NULL OR jsonb_typeof(p_days) <> 'array' THEN
    RAISE EXCEPTION 'Days payload must be a JSON array';
  END IF;

  v_day_count := jsonb_array_length(p_days);
  IF v_day_count = 0 THEN
    RAISE EXCEPTION 'At least one day is required';
  END IF;
  IF v_day_count > 60 THEN
    RAISE EXCEPTION 'Too many days in one batch (%). Maximum is 60', v_day_count;
  END IF;

  -- This subscription's normal daily cost — same as modify_daily_order_core,
  -- computed once and reused for every day's "extra".
  SELECT COALESCE(SUM(si.unit_price * si.quantity), 0)
  INTO v_sub_base
  FROM public.subscription_items si
  WHERE si.subscription_id = p_subscription_id
    AND si.is_active = true;

  -- ─── Pass 1: validate every day, compute the aggregate extra ─────────────
  -- No writes happen in this pass. Any RAISE here aborts the whole call with
  -- nothing changed.
  FOR v_day IN SELECT * FROM jsonb_array_elements(p_days)
  LOOP
    v_delivery_date := NULLIF(v_day->>'delivery_date', '')::date;
    v_items         := v_day->'items';

    IF v_delivery_date IS NULL THEN
      RAISE EXCEPTION 'Every day entry needs a delivery_date';
    END IF;

    IF v_delivery_date = ANY(v_seen_dates) THEN
      RAISE EXCEPTION 'Duplicate delivery_date % in the same batch', v_delivery_date;
    END IF;
    v_seen_dates := v_seen_dates || v_delivery_date;

    IF v_delivery_date < CURRENT_DATE THEN
      RAISE EXCEPTION 'Cannot modify a delivery date in the past (%)', v_delivery_date;
    END IF;

    -- Lock check — this subscription's order for that day only (as 025).
    SELECT status, is_finalized, payment_status
    INTO v_existing_status, v_existing_final, v_existing_pay
    FROM public.subscription_daily_orders
    WHERE subscription_id = p_subscription_id AND delivery_date = v_delivery_date
    ORDER BY created_at DESC
    LIMIT 1;

    IF FOUND THEN
      IF v_existing_final THEN
        RAISE EXCEPTION 'The order for % is finalized and can no longer be modified', v_delivery_date;
      END IF;
      IF v_existing_status <> 'pending' THEN
        RAISE EXCEPTION 'The order for % is % and can no longer be modified', v_delivery_date, v_existing_status;
      END IF;
      IF v_existing_pay = 'paid' THEN
        RAISE EXCEPTION 'The order for % is already paid and can no longer be modified', v_delivery_date;
      END IF;
    END IF;

    IF v_items IS NULL OR jsonb_typeof(v_items) <> 'array' OR jsonb_array_length(v_items) = 0 THEN
      -- Empty items = revert this day to the default (same as saveDailyOrder's
      -- empty-items branch for a single day). No pricing/wallet impact.
      v_plan := v_plan || jsonb_build_object(
        'delivery_date', v_delivery_date,
        'revert', true
      );
      CONTINUE;
    END IF;

    -- Canonical daily cost from the catalog (client "price" ignored).
    SELECT COALESCE(SUM(round(c.unit_price * c.quantity, 2)), 0)
    INTO v_new_daily
    FROM internal.normalize_cart(v_items) c;

    IF v_new_daily <= 0 THEN
      RAISE EXCEPTION 'Modified daily value for % must be greater than zero', v_delivery_date;
    END IF;

    v_extra := round(v_new_daily - v_sub_base, 2);
    IF v_extra > 0 THEN
      v_total_extra := v_total_extra + v_extra;
    END IF;

    v_plan := v_plan || jsonb_build_object(
      'delivery_date', v_delivery_date,
      'revert', false,
      'items', v_items,
      'new_daily', v_new_daily
    );
  END LOOP;

  -- ─── Aggregate wallet check (once, across the whole batch) ───────────────
  -- Same formula as migration 025's per-day rule, but total_extra is now the
  -- SUM of every day's positive extra in this batch, not just one day's.
  IF NOT p_is_admin AND v_total_extra > 0 THEN
    SELECT COALESCE(wallet_balance, 0) INTO v_wallet_balance
    FROM public.users WHERE id = p_user_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'User not found';
    END IF;

    v_committed := COALESCE(public.get_user_daily_commitment(p_user_id), 0);
    v_required  := round(v_committed * 3 + v_total_extra, 2);

    IF v_wallet_balance < v_required THEN
      RAISE EXCEPTION
        'Insufficient wallet balance (%). You need at least % (3 days of your subscriptions, %/day, plus % extra across % day(s) in this batch).',
        v_wallet_balance, v_required, round(v_committed, 2), v_total_extra, v_day_count;
    END IF;
  END IF;

  -- ─── Pass 2: apply every day's change ─────────────────────────────────────
  -- Every day already passed validation above; this pass only writes. If
  -- anything unexpected still fails here, the whole call rolls back (implicit
  -- transaction), so no day is left half-applied.
  FOR v_day IN SELECT * FROM jsonb_array_elements(v_plan)
  LOOP
    v_delivery_date := (v_day->>'delivery_date')::date;

    IF (v_day->>'revert')::boolean THEN
      DELETE FROM public.subscription_daily_order_items
      WHERE daily_order_id IN (
        SELECT id FROM public.subscription_daily_orders
        WHERE subscription_id = p_subscription_id
          AND delivery_date = v_delivery_date
          AND status = 'pending'
          AND is_finalized = false
          AND payment_status <> 'paid'
      );

      DELETE FROM public.subscription_daily_orders
      WHERE subscription_id = p_subscription_id
        AND delivery_date = v_delivery_date
        AND status = 'pending'
        AND is_finalized = false
        AND payment_status <> 'paid';

      v_result_ids := v_result_ids || jsonb_build_object('delivery_date', v_delivery_date, 'reverted', true);
      CONTINUE;
    END IF;

    DELETE FROM public.subscription_daily_order_items
    WHERE daily_order_id IN (
      SELECT id FROM public.subscription_daily_orders
      WHERE subscription_id = p_subscription_id AND delivery_date = v_delivery_date
    );

    DELETE FROM public.subscription_daily_orders
    WHERE subscription_id = p_subscription_id AND delivery_date = v_delivery_date;

    INSERT INTO public.subscription_daily_orders (
      delivery_date, subscription_id, user_id, status, total_value,
      payment_status, is_finalized, is_customer_modified, created_at
    ) VALUES (
      v_delivery_date, p_subscription_id, p_user_id, 'pending',
      (v_day->>'new_daily')::numeric, 'pending', false, true, now()
    ) RETURNING id INTO v_order_id;

    INSERT INTO public.subscription_daily_order_items (
      daily_order_id, variant_id, product_name_snapshot, variant_label_snapshot,
      unit_price, quantity, total_price, is_adhoc_addition
    )
    SELECT
      v_order_id, c.variant_id, c.product_name, c.variant_label,
      c.unit_price, c.quantity, round(c.unit_price * c.quantity, 2), false
    FROM internal.normalize_cart(v_day->'items') c;

    v_result_ids := v_result_ids || jsonb_build_object('delivery_date', v_delivery_date, 'order_id', v_order_id);
  END LOOP;

  RETURN jsonb_build_object('days', v_result_ids, 'total_extra', v_total_extra);
END;
$function$;

-- public.modify_daily_orders_bulk ─────────────────────────────────────────────
-- Customer/admin entry point. Same authorization shape as modify_daily_order.
CREATE OR REPLACE FUNCTION public.modify_daily_orders_bulk(
  p_user_id         uuid,
  p_subscription_id uuid,
  p_days            jsonb
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_is_admin boolean := internal.is_admin_actor('subscriptions:edit');
BEGIN
  IF NOT v_is_admin THEN
    IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
      RAISE EXCEPTION 'Not authorized to modify orders for this user';
    END IF;
  END IF;

  RETURN internal.modify_daily_orders_bulk_core(
    p_user_id, p_subscription_id, p_days, v_is_admin
  );
END;
$function$;

-- Grants ──────────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION internal.modify_daily_orders_bulk_core(uuid, uuid, jsonb, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.modify_daily_orders_bulk(uuid, uuid, jsonb) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.modify_daily_orders_bulk(uuid, uuid, jsonb) TO authenticated, service_role;

COMMIT;

-- Verification:
--   -- anon blocked:
--   SET ROLE anon;
--   SELECT public.modify_daily_orders_bulk('00000000-0000-0000-0000-000000000000'::uuid,
--     '00000000-0000-0000-0000-000000000000'::uuid, '[]'::jsonb); -- permission denied
--   RESET ROLE;
--
--   -- one bad day rolls back the whole batch (replace ids with real ones):
--   -- SELECT public.modify_daily_orders_bulk('<user>', '<sub>', '[
--   --   {"delivery_date":"2026-10-01","items":[{"variant_id":"<var>","quantity":1}]},
--   --   {"delivery_date":"2020-01-01","items":[{"variant_id":"<var>","quantity":1}]}
--   -- ]'::jsonb);  -- raises "past" error; 2026-10-01 must NOT be written either
