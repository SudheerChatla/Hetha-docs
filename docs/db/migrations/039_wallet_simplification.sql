-- Migration 039: wallet simplification and manual low-balance notices
--
-- Run in: Supabase SQL Editor (the whole file; it is wrapped in one transaction)
--
-- ─── Problem ────────────────────────────────────────────────────────────────
--   1. RESERVE. Wallet purchases, new subscriptions and day edits had to leave
--      THREE days of every subscription in the wallet. The multiplier was
--      written in four functions and three screens, and could not be
--      explained to a customer with subscriptions in areas on different
--      schedules.
--   2. "HOW LONG WILL MY WALLET LAST" was calculated five different ways
--      (app wallet page, checkout, create-subscription, admin profile,
--      low-balance push); none knew about area schedules, pauses or day edits.
--   3. LOW BALANCE. After Finalize a push went out automatically when the
--      balance was below 3 × that day's debit, whether or not the next
--      delivery was covered. Staff had no say in it.
--
-- ─── Fix ─────────────────────────────────────────────────────────────────────
--   internal.wallet_reserve(user)       ONE upcoming delivery of each active
--                                       subscription (owner decision D-1). The
--                                       only place the reserve is defined.
--   create_subscription / place_order / modify_daily_order(s) use it; the
--                                       messages say "the next delivery".
--   public.get_wallet_reserve(user)     the same number for the app and admin.
--   internal.wallet_forecast(user, days[, today])
--   public.get_wallet_forecast(user, days)
--                                       per day: what will be charged (existing
--                                       orders and day edits respected; schedule,
--                                       pauses and overrides via
--                                       internal.subscription_delivers_on from
--                                       038), how far the balance reaches.
--   Low-balance notices are MANUAL ONLY (owner decision 2026-11-16):
--   public.get_low_balance_customers(date)
--                                       Daily Ops list: customers whose wallet
--                                       cannot cover their orders on that date,
--                                       with balance, required, shortfall and
--                                       whether they were already notified.
--   public.claim_manual_low_balance_notices(date, users)
--                                       Staff pressed Send: claims the chosen
--                                       customers who are still short and not
--                                       already notified; returns them.
--   public.mark_wallet_notice_result    records sent / failed.
--   wallet_notice_log                   one row per customer and delivery date:
--                                       never two notices for one delivery.
--   No scheduler, no cron job, no notice sent by Finalize.
--
-- ─── Rollout order ──────────────────────────────────────────────────────────
--   1. Apply THIS migration. Old app builds keep working: they still ask for
--      3 days, which is stricter than the database now is, so they only
--      refuse more often than needed, never allow too little.
--   2. Deploy the admin panel (forecast on the customer profile, the Daily
--      Ops low-balance list; Finalize no longer sends a low-balance push).
--   3. Release the app (wallet page forecast; checkout and
--      create-subscription use get_wallet_reserve).

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. The wallet reserve (D-1) — the only place it is defined
-- ---------------------------------------------------------------------------
-- The wallet reserve: one upcoming delivery of each active subscription
-- (owner decision D-1). get_user_daily_commitment is the sum of the
-- per-delivery cost of the customer's live subscriptions. This is the only
-- place the reserve is defined.
CREATE OR REPLACE FUNCTION internal.wallet_reserve(p_user_id uuid)
  RETURNS numeric
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
  SELECT round(COALESCE(public.get_user_daily_commitment(p_user_id), 0), 2);
$function$;

-- The reserve plus a subscription being created now (its own first delivery).
CREATE OR REPLACE FUNCTION internal.wallet_reserve_with(p_user_id uuid, p_extra_per_delivery numeric)
  RETURNS numeric
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
  SELECT round(internal.wallet_reserve(p_user_id) + GREATEST(COALESCE(p_extra_per_delivery, 0), 0), 2);
$function$;

REVOKE ALL ON FUNCTION internal.wallet_reserve(uuid)               FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION internal.wallet_reserve_with(uuid, numeric) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_wallet_reserve(p_user_id uuid)
  RETURNS numeric
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
BEGIN
  IF NOT (auth.uid() = p_user_id OR internal.is_admin_actor('customers:view')) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  RETURN internal.wallet_reserve(p_user_id);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2. The four wallet checks use the reserve
-- ---------------------------------------------------------------------------
-- Latest bodies copied UNCHANGED except the reserve line and its message:
--   internal.create_subscription_core       ← migration 036
--   internal.place_order_core               ← migration 024
--   internal.modify_daily_order_core        ← migration 025
--   internal.modify_daily_orders_bulk_core  ← migration 027
-- An admin caller is not bound by the reserve (unchanged in each body).

CREATE OR REPLACE FUNCTION internal.create_subscription_core(p_user_id uuid, p_start_date timestamp with time zone, p_end_date timestamp with time zone, p_status text, p_address jsonb, p_items jsonb, p_label text, p_cancel_existing boolean DEFAULT false, p_is_admin boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_sub_id             uuid;
  v_pincode            text;
  v_area_id            uuid;
  v_delivery_area      text;
  v_delivery_frequency bigint;
  v_active_count       integer;
  v_max_subscriptions  integer := 5;
  v_new_daily          numeric := 0;
  v_existing_daily     numeric := 0;
  v_wallet_balance     numeric := 0;
  v_required           numeric := 0;
  v_address_id         uuid;
  v_address_id_text    text;
  v_start              date := p_start_date::date;
  v_earliest           date;
BEGIN
  IF p_status IS NULL OR p_status NOT IN ('active', 'paused') THEN
    RAISE EXCEPTION 'Invalid subscription status: %', p_status;
  END IF;

  IF p_cancel_existing THEN
    UPDATE public.subscriptions
    SET status = 'cancelled', cancelled_at = now(), end_date = now(),
        cancellation_type = 'replaced',
        cancellation_reason = 'Replaced by new subscription',
        is_custom_cancel_date = false
    WHERE user_id = p_user_id AND status = 'active';
  END IF;

  SELECT COUNT(*) INTO v_active_count
  FROM public.subscriptions
  WHERE user_id = p_user_id AND status IN ('active', 'pending_cancellation');

  IF v_active_count >= v_max_subscriptions THEN
    RAISE EXCEPTION 'Maximum subscription limit (%) reached', v_max_subscriptions;
  END IF;

  -- Canonical daily cost from the catalog (client "price" fields ignored).
  SELECT COALESCE(SUM(round(c.unit_price * c.quantity, 2)), 0)
  INTO v_new_daily
  FROM internal.normalize_cart(p_items) c;

  IF v_new_daily <= 0 THEN
    RAISE EXCEPTION 'Subscription daily value must be greater than zero';
  END IF;

  -- Wallet reserve: the next delivery of ALL subscriptions, including this one (039, D-1).
  IF NOT p_is_admin THEN
    SELECT COALESCE(wallet_balance, 0) INTO v_wallet_balance
    FROM public.users WHERE id = p_user_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'User not found';
    END IF;

    v_required := internal.wallet_reserve_with(p_user_id, v_new_daily);

    IF v_wallet_balance < v_required THEN
      RAISE EXCEPTION
        'Insufficient wallet balance (%). You need at least % to cover the next delivery of all your subscriptions.',
        v_wallet_balance, v_required;
    END IF;
  END IF;

  v_pincode := p_address->>'pincode';
  IF v_pincode IS NOT NULL THEN
    SELECT area_id INTO v_area_id FROM public.pincodes WHERE pincode = v_pincode LIMIT 1;
    IF v_area_id IS NOT NULL THEN
      SELECT display_name, delivary_frequency
      INTO v_delivery_area, v_delivery_frequency
      FROM public.delivery_areas WHERE id = v_area_id LIMIT 1;
    END IF;
  END IF;

  -- Cut-off rule (migration 036): a customer's subscription cannot start
  -- before the earliest day ops can still plan for. An earlier (or missing)
  -- start date is moved forward, not rejected, so older app builds keep
  -- working. Admin callers choose the start date freely.
  IF NOT p_is_admin THEN
    v_earliest := internal.earliest_change_date(v_area_id);
    v_start    := GREATEST(COALESCE(v_start, v_earliest), v_earliest);
  END IF;

  -- Extract address_id from the payload if it's a valid uuid belonging to p_user_id
  v_address_id_text := p_address->>'id';
  IF v_address_id_text IS NOT NULL AND v_address_id_text ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    SELECT id INTO v_address_id
    FROM public.addresses
    WHERE id = v_address_id_text::uuid
      AND user_id = p_user_id
      AND is_deleted = false;
  END IF;

  INSERT INTO public.subscriptions (
    user_id, address_id, start_date, end_date, status, label,
    snapshot_name, snapshot_phone, snapshot_address_line1, snapshot_address_line2,
    snapshot_landmark, snapshot_city, snapshot_state, snapshot_pincode,
    snapshot_address_type, delivary_area, delivary_frequency, created_at
  ) VALUES (
    p_user_id, v_address_id, v_start, p_end_date, p_status,
    COALESCE(p_label, 'Subscription ' || (v_active_count + 1)::text),
    p_address->>'name', p_address->>'phoneNumber', p_address->>'addressLine1',
    p_address->>'addressLine2', p_address->>'landmark', p_address->>'city',
    p_address->>'state', p_address->>'pincode', p_address->>'addressType',
    v_delivery_area, v_delivery_frequency, now()
  ) RETURNING id INTO v_sub_id;

  -- An item never starts before its subscription (GREATEST ignores a NULL
  -- v_start, which only an admin caller can produce).
  INSERT INTO public.subscription_items (
    subscription_id, variant_id, product_name_snapshot, variant_label_snapshot,
    unit_price, quantity, item_start_date
  )
  SELECT
    v_sub_id, c.variant_id, c.product_name, c.variant_label,
    c.unit_price, c.quantity,
    GREATEST(
      COALESCE(
        (SELECT MIN(NULLIF(it->>'startDate', ''))::date
         FROM jsonb_array_elements(p_items) it
         WHERE COALESCE(it->>'variant_id', it->>'variantId') = c.variant_id::text),
        v_start,
        internal.today_ist()
      ),
      v_start
    )
  FROM internal.normalize_cart(p_items) c;

  RETURN v_sub_id;
END;
$function$;

CREATE OR REPLACE FUNCTION internal.place_order_core(p_user_id uuid, p_address_id uuid, p_payment_method text, p_delivery_charge numeric, p_cart_items jsonb, p_is_admin boolean DEFAULT false, p_paid_externally boolean DEFAULT false, p_razorpay_order_id text DEFAULT NULL::text, p_razorpay_payment_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_order_id       uuid;
  v_order_number   text;
  v_subtotal       numeric := 0;
  v_delivery       numeric := 0;
  v_total          numeric := 0;
  v_address        RECORD;
  v_wallet_balance numeric;
  v_commitment     numeric := 0;
  v_reserve        numeric := 0;
  v_status         text;
  v_payment_status text;
  v_wallet_used    numeric := 0;
BEGIN
  IF p_payment_method NOT IN ('wallet', 'razorpay', 'cod') THEN
    RAISE EXCEPTION 'Unsupported payment method: %', p_payment_method;
  END IF;

  SELECT * INTO v_address
  FROM public.addresses
  WHERE id = p_address_id AND user_id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Address not found or does not belong to user';
  END IF;

  -- Delivery scope enforcement (migration 016): local-only products cannot
  -- be ordered from a non-serviceable pincode. Admin callers bypass.
  IF internal.serviceable_area_id(v_address.pincode) IS NULL
     AND NOT COALESCE(p_is_admin, false)
     AND EXISTS (
       SELECT 1
       FROM internal.normalize_cart(p_cart_items) c
       JOIN public.product_variants pv ON pv.id = c.variant_id
       JOIN public.products pr ON pr.id = pv.product_id
       WHERE pr.delivery_scope = 'local'
     )
  THEN
    RAISE EXCEPTION
      'Some items in your cart are only available for local delivery. Pincode % is not in our delivery area.',
      v_address.pincode;
  END IF;

  -- Prices always come from the catalog, never from the payload.
  SELECT COALESCE(SUM(round(c.unit_price * c.quantity, 2)), 0)
  INTO v_subtotal
  FROM internal.normalize_cart(p_cart_items) c;

  IF v_subtotal <= 0 THEN
    RAISE EXCEPTION 'Order subtotal must be greater than zero';
  END IF;

  -- Delivery charge: server-computed for customers — ₹0 for a serviceable
  -- pincode (migration 024), weight tiers elsewhere. Admins may override it
  -- (fee waivers / manual corrections) but never below zero.
  IF p_is_admin AND p_delivery_charge IS NOT NULL THEN
    v_delivery := round(GREATEST(p_delivery_charge, 0), 2);
  ELSE
    v_delivery := internal.compute_delivery_charge(p_cart_items, v_address.pincode);
  END IF;

  v_total := round(v_subtotal + v_delivery, 2);

  v_order_number := 'ORD-' || to_char(CURRENT_TIMESTAMP, 'YYYYMMDDHH24MISS')
                    || '-' || lpad((floor(random() * 10000))::int::text, 4, '0');

  IF p_payment_method = 'wallet' THEN
    SELECT wallet_balance INTO v_wallet_balance
    FROM public.users WHERE id = p_user_id FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'User not found';
    END IF;

    -- Wallet reserve: the next delivery of every subscription (039, D-1). Skipped for admin
    -- placed orders so ops can still fulfil edge cases deliberately.
    IF NOT p_is_admin THEN
      v_reserve    := internal.wallet_reserve(p_user_id);
    END IF;

    IF COALESCE(v_wallet_balance, 0) < v_total + v_reserve THEN
      IF v_reserve > 0 THEN
        RAISE EXCEPTION
          'Insufficient wallet balance. Required: % (order %) plus % kept for the next delivery of your subscriptions, available: %',
          v_total + v_reserve, v_total, v_reserve, v_wallet_balance;
      ELSE
        RAISE EXCEPTION 'Insufficient Wallet Balance! Required: %, Available: %',
          v_total, v_wallet_balance;
      END IF;
    END IF;

    v_status         := 'placed';
    v_payment_status := 'paid';
    v_wallet_used    := v_total;

  ELSIF p_payment_method = 'cod' THEN
    v_status         := 'placed';
    v_payment_status := 'pending';

  ELSE  -- razorpay
    IF p_paid_externally THEN
      v_status         := 'placed';
      v_payment_status := 'paid';
    ELSE
      -- Nobody may create a "placed" online-payment order without a verified
      -- payment. Such rows stay in payment_pending and never reach the run
      -- sheet / packing list.
      v_status         := 'payment_pending';
      v_payment_status := 'pending';
    END IF;
  END IF;

  INSERT INTO public.orders (
    order_number, user_id, address_snapshot_id, status, payment_method,
    payment_status, subtotal, delivery_charge, total, wallet_amount_used,
    razorpay_amount, razorpay_order_id, razorpay_payment_id,
    payment_pending_expires_at, pincode,
    snapshot_name, snapshot_phone, snapshot_address_line1, snapshot_address_line2,
    snapshot_landmark, snapshot_city, snapshot_state, snapshot_pincode,
    snapshot_address_type
  ) VALUES (
    v_order_number, p_user_id, p_address_id, v_status, p_payment_method,
    v_payment_status, v_subtotal, v_delivery, v_total, v_wallet_used,
    CASE WHEN p_payment_method = 'razorpay' AND p_paid_externally THEN v_total ELSE 0 END,
    p_razorpay_order_id, p_razorpay_payment_id,
    CASE WHEN v_status = 'payment_pending' THEN now() + interval '30 minutes' ELSE NULL END,
    v_address.pincode,
    v_address.name, v_address.phone_number, v_address.address_line1, v_address.address_line2,
    v_address.landmark, v_address.city, v_address.state, v_address.pincode,
    v_address.address_type
  ) RETURNING id INTO v_order_id;

  INSERT INTO public.order_items (
    order_id, variant_id, product_name_snapshot, variant_label_snapshot,
    unit_price, quantity, total_price
  )
  SELECT
    v_order_id, c.variant_id, c.product_name, c.variant_label,
    c.unit_price, c.quantity, round(c.unit_price * c.quantity, 2)
  FROM internal.normalize_cart(p_cart_items) c;

  IF p_payment_method = 'wallet' THEN
    PERFORM internal.apply_wallet_delta(
      p_user_id, v_total, 'debit',
      'Order ' || v_order_number || ' checkout',
      CASE WHEN p_is_admin THEN 'admin' ELSE 'user' END,
      'order', v_order_id::text
    );
  END IF;

  INSERT INTO public.order_tracking (order_id, status) VALUES (v_order_id, v_status);

  RETURN jsonb_build_object(
    'order_id',        v_order_id,
    'order_number',    v_order_number,
    'subtotal',        v_subtotal,
    'delivery_charge', v_delivery,
    'total',           v_total,
    'status',          v_status,
    'payment_status',  v_payment_status
  );
END;
$function$;

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

  IF p_delivery_date < CURRENT_DATE THEN
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

-- ---------------------------------------------------------------------------
-- 3. The wallet forecast — one answer for every screen
-- ---------------------------------------------------------------------------
-- For each day from p_today + 1 to p_today + p_days, what the customer's live
-- subscriptions will be charged:
--   an order already exists for (subscription, day):
--     skipped / cancelled / on payment hold → 0
--     otherwise → total_value − paid_amount (a day edit or an order already
--                 paid is respected)
--   no order yet → Σ items of internal.subscription_items_on when
--                  internal.subscription_delivers_on (schedule, alternate-day
--                  areas, pauses, move/swap overrides)
-- Then walks the days with a running total against the live balance.
-- p_today lets tests (and future callers) evaluate from a given India day.
CREATE OR REPLACE FUNCTION internal.wallet_forecast(
  p_user_id uuid,
  p_days    integer,
  p_today   date DEFAULT NULL
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_today     date := COALESCE(p_today, internal.today_ist());
  v_days      integer := LEAST(GREATEST(COALESCE(p_days, 14), 1), 60);
  v_balance   numeric;
  v_reserve   numeric;
  v_day       date;
  v_sub       record;
  v_order     record;
  v_amount    numeric;
  v_day_total numeric;
  v_subs      jsonb;
  v_list      jsonb := '[]'::jsonb;
  v_running   numeric := 0;
  v_covered_until date;
  v_first_uncovered date;
  v_covered_count integer := 0;
  v_item      jsonb;
BEGIN
  SELECT COALESCE(wallet_balance, 0) INTO v_balance FROM public.users WHERE id = p_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'User not found';
  END IF;
  v_reserve := internal.wallet_reserve(p_user_id);

  FOR i IN 1..v_days LOOP
    v_day := v_today + i;
    v_day_total := 0;
    v_subs := '[]'::jsonb;

    FOR v_sub IN
      SELECT s.id, s.label, s.delivary_area
      FROM public.subscriptions s
      WHERE s.user_id = p_user_id AND s.status IN ('active', 'pending_cancellation')
      ORDER BY s.created_at, s.id
    LOOP
      SELECT status, total_value, paid_amount, settlement_hold_reason INTO v_order
      FROM public.subscription_daily_orders
      WHERE subscription_id = v_sub.id AND delivery_date = v_day
      ORDER BY created_at, id
      LIMIT 1;

      IF FOUND THEN
        IF v_order.status IN ('skipped', 'cancelled') OR v_order.settlement_hold_reason IS NOT NULL THEN
          v_amount := 0;
        ELSE
          v_amount := GREATEST(COALESCE(v_order.total_value, 0) - COALESCE(v_order.paid_amount, 0), 0);
        END IF;
      ELSIF internal.subscription_delivers_on(v_sub.id, v_day) THEN
        SELECT COALESCE(SUM(round(i2.unit_price * i2.quantity, 2)), 0) INTO v_amount
        FROM internal.subscription_items_on(v_sub.id, v_day) i2;
      ELSE
        v_amount := 0;
      END IF;

      IF v_amount > 0 THEN
        v_day_total := v_day_total + v_amount;
        v_subs := v_subs || jsonb_build_object(
          'subscription_id', v_sub.id, 'label', v_sub.label,
          'area', v_sub.delivary_area, 'amount', round(v_amount, 2));
      END IF;
    END LOOP;

    IF v_day_total > 0 THEN
      v_list := v_list || jsonb_build_object(
        'date', to_char(v_day, 'YYYY-MM-DD'), 'amount', round(v_day_total, 2), 'subscriptions', v_subs);
    END IF;
  END LOOP;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_list) LOOP
    v_running := v_running + (v_item->>'amount')::numeric;
    IF v_running <= v_balance THEN
      v_covered_until := (v_item->>'date')::date;
      v_covered_count := v_covered_count + 1;
    ELSIF v_first_uncovered IS NULL THEN
      v_first_uncovered := (v_item->>'date')::date;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'balance',              round(v_balance, 2),
    'reserve',              v_reserve,
    'available',            round(GREATEST(v_balance - v_reserve, 0), 2),
    'per_delivery_total',   round(COALESCE(public.get_user_daily_commitment(p_user_id), 0), 2),
    'next_delivery_date',   v_list->0->>'date',
    'next_delivery_amount', COALESCE((v_list->0->>'amount')::numeric, 0),
    'next_delivery_covered', CASE WHEN jsonb_array_length(v_list) = 0 THEN true
                                  ELSE (v_list->0->>'amount')::numeric <= v_balance END,
    'covered_until',        to_char(v_covered_until, 'YYYY-MM-DD'),
    'first_uncovered_date', to_char(v_first_uncovered, 'YYYY-MM-DD'),
    'covered_deliveries',   v_covered_count,
    'horizon_days',         v_days,
    'days',                 v_list);
END;
$function$;

REVOKE ALL ON FUNCTION internal.wallet_forecast(uuid, integer, date) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_wallet_forecast(p_user_id uuid, p_days integer DEFAULT 14)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
BEGIN
  IF NOT (auth.uid() = p_user_id OR internal.is_admin_actor('customers:view')) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  RETURN internal.wallet_forecast(p_user_id, p_days);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4. Manual low-balance notices (sent by staff from Daily Ops)
-- ---------------------------------------------------------------------------
-- Nothing here sends anything on its own: there is no scheduler and no notice
-- after Finalize. Staff open the list for a delivery date, choose customers
-- and press Send. The log keeps one row per customer and delivery date, so a
-- customer is told at most once about a given delivery.
CREATE TABLE IF NOT EXISTS public.wallet_notice_log (
  user_id       uuid NOT NULL REFERENCES public.users(id) ON UPDATE CASCADE ON DELETE CASCADE,
  delivery_date date NOT NULL,
  source        text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual')),
  balance       numeric NOT NULL,
  amount        numeric NOT NULL,
  status        text NOT NULL DEFAULT 'claimed' CHECK (status IN ('claimed', 'sent', 'failed')),
  attempts      integer NOT NULL DEFAULT 1,
  claimed_at    timestamptz NOT NULL DEFAULT now(),
  claimed_by    uuid,
  sent_at       timestamptz,
  error         text,
  CONSTRAINT wallet_notice_log_pkey PRIMARY KEY (user_id, delivery_date)
);
ALTER TABLE public.wallet_notice_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.wallet_notice_log FROM anon, authenticated;

-- Per customer: what their wallet orders on p_delivery_date still need to be
-- charged (Σ total_value − paid_amount of pending orders that are not on
-- payment hold), against the live balance. Cash-on-delivery subscriptions are
-- left out. Skipped, cancelled and delivered orders need nothing.
CREATE OR REPLACE FUNCTION internal.low_balance_customers(p_delivery_date date)
  RETURNS TABLE (user_id uuid, name text, phone text, balance numeric,
                 required numeric, shortfall numeric, notice_status text)
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
  WITH owed AS (
    SELECT o.user_id, round(SUM(GREATEST(o.total_value - o.paid_amount, 0)), 2) AS required
    FROM public.subscription_daily_orders o
    JOIN public.subscriptions s ON s.id = o.subscription_id
    WHERE o.delivery_date = p_delivery_date
      AND o.status = 'pending'
      AND o.settlement_hold_reason IS NULL
      AND COALESCE(s.payment_method, 'wallet') = 'wallet'
    GROUP BY o.user_id
  )
  SELECT u.id,
         NULLIF(trim(concat_ws(' ', u.first_name, u.last_name)), ''),
         u.phone,
         round(COALESCE(u.wallet_balance, 0), 2),
         w.required,
         round(w.required - COALESCE(u.wallet_balance, 0), 2),
         l.status
  FROM owed w
  JOIN public.users u ON u.id = w.user_id
  LEFT JOIN public.wallet_notice_log l ON l.user_id = u.id AND l.delivery_date = p_delivery_date
  WHERE w.required > COALESCE(u.wallet_balance, 0)
  ORDER BY (w.required - COALESCE(u.wallet_balance, 0)) DESC, u.id;
$function$;
REVOKE ALL ON FUNCTION internal.low_balance_customers(date) FROM PUBLIC, anon, authenticated;

-- The list for Daily Ops. notice_status: NULL (not told yet), 'sent'
-- (already notified), 'failed' (last push failed; may be sent again) or
-- 'claimed' (a send is in progress).
CREATE OR REPLACE FUNCTION public.get_low_balance_customers(p_delivery_date date)
  RETURNS TABLE (user_id uuid, name text, phone text, balance numeric,
                 required numeric, shortfall numeric, notice_status text)
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
BEGIN
  IF NOT internal.is_admin_actor('daily_ops:view') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF p_delivery_date IS NULL THEN
    RAISE EXCEPTION 'A delivery date is required';
  END IF;
  RETURN QUERY SELECT * FROM internal.low_balance_customers(p_delivery_date);
END;
$function$;

-- Staff pressed Send for these customers. Claims a log row for each one that
-- is STILL short now and not already notified (or whose last push failed),
-- and returns exactly those. Anyone already sent, or who has recharged since
-- the list was shown, is not returned, so cannot be sent twice.
CREATE OR REPLACE FUNCTION public.claim_manual_low_balance_notices(p_delivery_date date, p_user_ids uuid[])
  RETURNS TABLE (user_id uuid, balance numeric, required numeric)
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
BEGIN
  IF NOT internal.is_admin_actor('daily_ops:edit') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF p_delivery_date IS NULL THEN
    RAISE EXCEPTION 'A delivery date is required';
  END IF;

  RETURN QUERY
  WITH chosen AS (
    SELECT c.user_id, c.balance, c.required
    FROM internal.low_balance_customers(p_delivery_date) c
    WHERE c.user_id = ANY (COALESCE(p_user_ids, '{}'))
  ), ins AS (
    INSERT INTO public.wallet_notice_log AS l
      (user_id, delivery_date, source, balance, amount, status, attempts, claimed_at, claimed_by)
    SELECT c.user_id, p_delivery_date, 'manual', c.balance, c.required, 'claimed', 1, now(), auth.uid()
    FROM chosen c
    ON CONFLICT ON CONSTRAINT wallet_notice_log_pkey DO UPDATE
      SET status = 'claimed', attempts = l.attempts + 1, claimed_at = now(), claimed_by = EXCLUDED.claimed_by,
          balance = EXCLUDED.balance, amount = EXCLUDED.amount, error = NULL
      WHERE l.status = 'failed'
         OR (l.status = 'claimed' AND l.claimed_at < now() - interval '15 minutes')
    RETURNING l.user_id, l.balance, l.amount
  )
  SELECT * FROM ins;
END;
$function$;

CREATE OR REPLACE FUNCTION public.mark_wallet_notice_result(
  p_user_id uuid, p_delivery_date date, p_ok boolean, p_error text DEFAULT NULL)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
BEGIN
  IF NOT internal.is_admin_actor('daily_ops:edit') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  UPDATE public.wallet_notice_log
  SET status  = CASE WHEN p_ok THEN 'sent' ELSE 'failed' END,
      sent_at = CASE WHEN p_ok THEN now() ELSE sent_at END,
      error   = CASE WHEN p_ok THEN NULL ELSE left(p_error, 500) END
  WHERE user_id = p_user_id AND delivery_date = p_delivery_date;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5. Grants
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.get_wallet_reserve(uuid)                              FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_wallet_forecast(uuid, integer)                    FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_low_balance_customers(date)                       FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.claim_manual_low_balance_notices(date, uuid[])        FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.mark_wallet_notice_result(uuid, date, boolean, text)  FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.get_wallet_reserve(uuid)                             TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_wallet_forecast(uuid, integer)                   TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_low_balance_customers(date)                      TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.claim_manual_low_balance_notices(date, uuid[])       TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.mark_wallet_notice_result(uuid, date, boolean, text) TO authenticated, service_role;

COMMIT;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- 1. The old 3-day rule is gone from the four functions (expect 0 rows):
--      SELECT p.oid::regprocedure FROM pg_proc p
--      WHERE p.proname IN ('create_subscription_core', 'place_order_core',
--                          'modify_daily_order_core', 'modify_daily_orders_bulk_core')
--        AND (p.prosrc LIKE '%* 3%' OR p.prosrc LIKE '%3 days%');
--
-- 2. A customer's reserve and forecast (replace the id):
--      SELECT internal.wallet_reserve('<user id>'),
--             internal.wallet_forecast('<user id>', 14);
--
-- 3. The Daily Ops list for a date (replace the date):
--      SELECT * FROM internal.low_balance_customers(DATE '<YYYY-MM-DD>');
--
-- 4. Grants — expect t, t, t, f, f:
--      SELECT
--        has_function_privilege('authenticated', 'public.get_wallet_forecast(uuid, integer)', 'EXECUTE'),
--        has_function_privilege('authenticated', 'public.get_low_balance_customers(date)', 'EXECUTE'),
--        has_function_privilege('authenticated', 'public.claim_manual_low_balance_notices(date, uuid[])', 'EXECUTE'),
--        has_function_privilege('anon', 'public.get_wallet_forecast(uuid, integer)', 'EXECUTE'),
--        has_function_privilege('authenticated', 'internal.wallet_forecast(uuid, integer, date)', 'EXECUTE');
