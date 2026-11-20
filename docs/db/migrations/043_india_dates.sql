-- Migration 043: India dates in the last four functions that used the server date
--
-- Run in: Supabase SQL Editor (the whole file; it is wrapped in one transaction)
--
-- ─── Problem ────────────────────────────────────────────────────────────────
-- Supabase runs Postgres in UTC, so CURRENT_DATE is still "yesterday" in
-- India between 00:00 and 05:30 IST. Four functions still used it:
--   internal.modify_daily_order_core       "date has passed" check on day edits
--   internal.modify_daily_orders_bulk_core  same check for bulk edits
--   public.cancel_subscription              last delivered day of an immediate
--                                           cancel (and the end date's day)
--   public.set_product_archived             which subscription items still run
-- Example: an admin cancels a subscription at 01:00 IST. CURRENT_DATE is
-- yesterday, so today's pending delivery is removed as if it were after the
-- end date.
--
-- ─── Fix ─────────────────────────────────────────────────────────────────────
-- Use internal.today_ist() (migration 033), like every other function.
-- cancel_subscription reads the end date's day in India time
-- ((p_end_date AT TIME ZONE 'Asia/Kolkata')::date); a plain "YYYY-MM-DD" from
-- the app gives the same day as before. The bodies are otherwise copied
-- unchanged from 039 / 030 / 028 (the 038 trusted-flag line is kept).
-- Grants are kept by CREATE OR REPLACE.
--
-- ─── Rollout order ──────────────────────────────────────────────────────────
-- Independent of the admin and app code. Apply any time.

BEGIN;

CREATE OR REPLACE FUNCTION internal.modify_daily_order_core(
  p_user_id         uuid,
  p_subscription_id uuid,
  p_delivery_date   date,
  p_items           jsonb,
  p_is_admin        boolean DEFAULT false
)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_owner            uuid;
  v_order_id         uuid;
  v_new_daily        numeric := 0;
  v_sub_base         numeric := 0;
  v_extra            numeric := 0;
  v_committed        numeric := 0;
  v_wallet_balance   numeric := 0;
  v_required         numeric := 0;
  v_existing_status  text;
  v_existing_final   boolean;
  v_existing_pay     text;
BEGIN
  -- Ownership: the subscription must exist and belong to the acting user
  -- (assert_subscription_access raises otherwise).
  PERFORM internal.assert_subscription_access(p_subscription_id);

  SELECT user_id INTO v_owner FROM public.subscriptions WHERE id = p_subscription_id;
  IF v_owner IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'Subscription does not belong to this user';
  END IF;

  IF p_delivery_date < internal.today_ist() THEN
    RAISE EXCEPTION 'Cannot modify a delivery date in the past';
  END IF;

  -- Refuse to touch a day that is already locked / billed / delivered —
  -- THIS subscription's order for that day only (migration 025).
  SELECT status, is_finalized, payment_status
  INTO v_existing_status, v_existing_final, v_existing_pay
  FROM public.subscription_daily_orders
  WHERE subscription_id = p_subscription_id AND delivery_date = p_delivery_date
  ORDER BY created_at DESC
  LIMIT 1;

  IF FOUND THEN
    IF v_existing_final THEN
      RAISE EXCEPTION 'This day''s order is finalized and can no longer be modified';
    END IF;
    IF v_existing_status <> 'pending' THEN
      RAISE EXCEPTION 'This day''s order is % and can no longer be modified', v_existing_status;
    END IF;
    IF v_existing_pay = 'paid' THEN
      RAISE EXCEPTION 'This day''s order is already paid and can no longer be modified';
    END IF;
  END IF;

  -- Canonical daily cost from the catalog (client "price" fields ignored).
  -- normalize_cart validates ids/quantities and confirms every variant exists.
  SELECT COALESCE(SUM(round(c.unit_price * c.quantity, 2)), 0)
  INTO v_new_daily
  FROM internal.normalize_cart(p_items) c;

  IF v_new_daily <= 0 THEN
    RAISE EXCEPTION 'Modified daily value must be greater than zero';
  END IF;

  -- Wallet rule (025, reserve from 039): the next-delivery reserve must survive paying
  -- this day's one-off extra. Only checked when the edit raises this
  -- subscription's cost for the day. Admins bypass.
  IF NOT p_is_admin THEN
    -- This subscription's normal daily cost — same terms as
    -- get_user_daily_commitment, restricted to this subscription.
    SELECT COALESCE(SUM(si.unit_price * si.quantity), 0)
    INTO v_sub_base
    FROM public.subscription_items si
    WHERE si.subscription_id = p_subscription_id
      AND si.is_active = true;

    v_extra := round(v_new_daily - v_sub_base, 2);

    IF v_extra > 0 THEN
      SELECT COALESCE(wallet_balance, 0) INTO v_wallet_balance
      FROM public.users WHERE id = p_user_id;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found';
      END IF;

      v_committed := internal.wallet_reserve(p_user_id);
      v_required  := round(v_committed + v_extra, 2);

      IF v_wallet_balance < v_required THEN
        RAISE EXCEPTION
          'Insufficient wallet balance (%). You need at least % (% for the next delivery of your subscriptions plus % extra for this day).',
          v_wallet_balance, v_required, round(v_committed, 2), v_extra;
      END IF;
    END IF;
  END IF;

  -- Replace THIS subscription's pending order for the date (migration 025:
  -- previously every order the user had on that date). Items first — the FK
  -- has no ON DELETE CASCADE.
  DELETE FROM public.subscription_daily_order_items
  WHERE daily_order_id IN (
    SELECT id FROM public.subscription_daily_orders
    WHERE subscription_id = p_subscription_id AND delivery_date = p_delivery_date
  );

  DELETE FROM public.subscription_daily_orders
  WHERE subscription_id = p_subscription_id AND delivery_date = p_delivery_date;

  -- Insert the fresh, customer-modified order.
  INSERT INTO public.subscription_daily_orders (
    delivery_date, subscription_id, user_id, status, total_value,
    payment_status, is_finalized, is_customer_modified, created_at
  ) VALUES (
    p_delivery_date, p_subscription_id, p_user_id, 'pending', v_new_daily,
    'pending', false, true, now()
  ) RETURNING id INTO v_order_id;

  INSERT INTO public.subscription_daily_order_items (
    daily_order_id, variant_id, product_name_snapshot, variant_label_snapshot,
    unit_price, quantity, total_price, is_adhoc_addition
  )
  SELECT
    v_order_id, c.variant_id, c.product_name, c.variant_label,
    c.unit_price, c.quantity, round(c.unit_price * c.quantity, 2), false
  FROM internal.normalize_cart(p_items) c;

  RETURN v_order_id;
END;
$function$;

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

    IF v_delivery_date < internal.today_ist() THEN
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

    v_committed := internal.wallet_reserve(p_user_id);
    v_required  := round(v_committed + v_total_extra, 2);

    IF v_wallet_balance < v_required THEN
      RAISE EXCEPTION
        'Insufficient wallet balance (%). You need at least % (% for the next delivery of your subscriptions plus % extra across % day(s) in this batch).',
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

CREATE OR REPLACE FUNCTION public.cancel_subscription(
  p_subscription_id uuid,
  p_user_id uuid,
  p_end_date timestamp with time zone,
  p_is_immediate boolean,
  p_cancellation_type text,
  p_reason text DEFAULT NULL::text
) RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_cutoff date;
BEGIN
  IF NOT internal.is_admin_actor('subscriptions:edit') THEN
    IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
      RAISE EXCEPTION 'Not authorized to cancel this subscription';
    END IF;
  END IF;

  IF p_is_immediate THEN
    UPDATE public.subscriptions
    SET status = 'cancelled',
        end_date = p_end_date,
        cancelled_at = NOW(),
        cancellation_type = p_cancellation_type,
        cancellation_reason = p_reason,
        is_custom_cancel_date = (p_cancellation_type = 'custom')
    WHERE id = p_subscription_id AND user_id = p_user_id;
  ELSE
    -- Scheduled: park in pending_cancellation with the cutoff in end_date.
    -- processScheduledCancellations() flips it to 'cancelled' once end_date
    -- passes.
    UPDATE public.subscriptions
    SET status = 'pending_cancellation',
        end_date = p_end_date,
        cancellation_type = p_cancellation_type,
        cancellation_reason = p_reason,
        is_custom_cancel_date = (p_cancellation_type = 'custom')
    WHERE id = p_subscription_id AND user_id = p_user_id;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Subscription not found or does not belong to user';
  END IF;

  -- Last date that is still delivered. Nothing after it may stay billable.
  -- India calendar days (migration 043): the server runs in UTC.
  v_cutoff := CASE WHEN p_is_immediate THEN internal.today_ist()
                   ELSE COALESCE((p_end_date AT TIME ZONE 'Asia/Kolkata')::date, internal.today_ist()) END;

  DELETE FROM public.subscription_daily_order_items
  WHERE daily_order_id IN (
    SELECT id FROM public.subscription_daily_orders
    WHERE subscription_id = p_subscription_id
      AND delivery_date > v_cutoff
      AND status = 'pending'
      AND is_finalized = false
      AND payment_status <> 'paid'
  );

  DELETE FROM public.subscription_daily_orders
  WHERE subscription_id = p_subscription_id
    AND delivery_date > v_cutoff
    AND status = 'pending'
    AND is_finalized = false
    AND payment_status <> 'paid';
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_product_archived(p_product_id uuid, p_archived boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_active_subs integer;
BEGIN
  IF NOT internal.is_admin_actor('products:edit') THEN
    RAISE EXCEPTION 'Not authorized to archive products';
  END IF;

  IF p_archived IS NULL THEN
    RAISE EXCEPTION 'p_archived is required';
  END IF;

  PERFORM 1 FROM public.products WHERE id = p_product_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found';
  END IF;

  IF p_archived THEN
    -- Subscriptions still delivering this product as a live item.
    SELECT COUNT(DISTINCT s.id) INTO v_active_subs
    FROM public.subscription_items si
    JOIN public.subscriptions s     ON s.id  = si.subscription_id
    JOIN public.product_variants pv ON pv.id = si.variant_id
    WHERE pv.product_id = p_product_id
      AND si.is_active = true
      AND (si.item_end_date IS NULL OR si.item_end_date >= internal.today_ist())
      AND s.status IN ('active', 'pending_cancellation');

    IF v_active_subs > 0 THEN
      RAISE EXCEPTION
        '% active subscription(s) still include this product. Remove it from those subscriptions first, or switch "In Stock" off instead.',
        v_active_subs;
    END IF;

    -- Nobody can check out an archived product (normalize_cart refuses it),
    -- so take it out of carts rather than leave a line that fails at payment.
    DELETE FROM public.cart_items
    WHERE variant_id IN (SELECT id FROM public.product_variants WHERE product_id = p_product_id);
  END IF;

  UPDATE public.products
  SET is_archived = p_archived, updated_at = now()
  WHERE id = p_product_id;
END;
$function$;

COMMIT;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- 1. No function left on the server date — expect 0 rows:
--      SELECT n.nspname, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--      WHERE n.nspname IN ('public', 'internal') AND prosrc ILIKE '%current_date%';
