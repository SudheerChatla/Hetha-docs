-- =============================================================================
-- Migration 007 — MONEY INTEGRITY (server-authoritative pricing)
-- =============================================================================
-- Run in: Supabase SQL Editor (as the postgres/owner role), BEFORE 008 and 009.
--
-- WHAT THIS FIXES
--   1. place_order trusted `p_delivery_charge` from the client → a tampered
--      client could set 0 (free delivery) or a negative value (which, with a
--      non-wallet payment method, produced an order whose total was below the
--      goods value). Delivery charge is now computed server-side from
--      delivery_charge_tiers + product_variants.weight_grams/free_delivery.
--      The parameter is now only honoured for *admin* callers (fee waivers).
--   2. place_order did not validate quantities, variant availability, payment
--      method, or the caller's identity (it is SECURITY DEFINER, so it ran with
--      full privileges for whatever p_user_id was passed).
--   3. create_subscription took `unit_price` straight from the client payload.
--      That price is what the daily run sheet bills against, so a tampered
--      subscription meant permanently discounted daily deliveries. Prices are
--      now always re-read from product_variants.
--   4. The "3 days of daily commitment" wallet buffer existed only in Flutter
--      (checkout.dart / create_subscription_page.dart). It is now enforced in
--      the database for customer-initiated wallet spends.
--   5. update_wallet_balance was a SECURITY DEFINER function with EXECUTE
--      granted to PUBLIC by default: any logged-in user could credit their own
--      wallet by calling it directly. The privileged logic now lives in
--      internal.apply_wallet_delta(); the public wrapper is authorization-gated.
--
-- DESIGN
--   • schema `internal` is NOT exposed through PostgREST (it is not in the
--     project's exposed schemas), so nothing in it is reachable over the API.
--   • Every public money RPC re-derives prices from the catalog and only trusts
--     ids + quantities from the client.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS internal;

REVOKE ALL ON SCHEMA internal FROM PUBLIC;
REVOKE USAGE ON SCHEMA internal FROM anon, authenticated;


-- ---------------------------------------------------------------------------
-- Caller identification helpers
-- ---------------------------------------------------------------------------

-- Role carried by the current PostgREST request. Values seen in practice:
--   'anon' | 'authenticated' | 'service_role'
-- Direct SQL (psql, SQL editor, pg_cron) has no request claims → 'internal'.
CREATE OR REPLACE FUNCTION internal.jwt_role()
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role',
    'internal'
  );
$$;

-- True for edge functions / server routes using the service-role key and for
-- direct SQL sessions. Never true for the Flutter app or the admin browser.
CREATE OR REPLACE FUNCTION internal.is_service_actor()
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT internal.jwt_role() IN ('service_role', 'internal');
$$;

-- True for service actors and for signed-in admins holding `p_permission`.
CREATE OR REPLACE FUNCTION internal.is_admin_actor(p_permission text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF internal.is_service_actor() THEN
    RETURN true;
  END IF;
  IF auth.uid() IS NULL THEN
    RETURN false;
  END IF;
  RETURN public.is_super_admin() OR public.has_permission(p_permission);
END;
$$;


-- ---------------------------------------------------------------------------
-- internal.apply_wallet_delta — the ONLY place that moves wallet money
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION internal.apply_wallet_delta(
  p_user_id        uuid,
  p_amount         numeric,
  p_type           text,
  p_description    text,
  p_initiated_by   text,
  p_reference_type text DEFAULT NULL,
  p_reference_id   text DEFAULT NULL
) RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, internal
AS $$
DECLARE
  v_amount          numeric;
  v_current_balance numeric;
  v_new_balance     numeric;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'user id is required';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 OR p_amount <> p_amount THEN   -- NaN-safe
    RAISE EXCEPTION 'Wallet amount must be a positive number (got %)', p_amount;
  END IF;

  v_amount := round(p_amount::numeric, 2);

  IF p_type NOT IN ('credit', 'debit') THEN
    RAISE EXCEPTION 'Invalid transaction type. Must be "credit" or "debit"';
  END IF;

  SELECT wallet_balance INTO v_current_balance
  FROM public.users WHERE id = p_user_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'User not found';
  END IF;

  IF p_type = 'credit' THEN
    v_new_balance := round(COALESCE(v_current_balance, 0) + v_amount, 2);
  ELSE
    IF COALESCE(v_current_balance, 0) < v_amount THEN
      RAISE EXCEPTION 'Insufficient balance. Current balance is %', v_current_balance;
    END IF;
    v_new_balance := round(COALESCE(v_current_balance, 0) - v_amount, 2);
  END IF;

  UPDATE public.users
  SET wallet_balance = v_new_balance, updated_at = now()
  WHERE id = p_user_id;

  INSERT INTO public.wallet_transactions (
    user_id, type, amount, balance_after, description, initiated_by,
    reference_type, reference_id
  ) VALUES (
    p_user_id, p_type, v_amount, v_new_balance, p_description, p_initiated_by,
    p_reference_type,
    CASE WHEN p_reference_id IS NULL THEN NULL ELSE p_reference_id::uuid END
  );

  RETURN v_new_balance;
END;
$$;


-- ---------------------------------------------------------------------------
-- public.update_wallet_balance — authorization-gated wrapper
-- ---------------------------------------------------------------------------
-- Callable only by service-role callers (edge functions, admin API routes that
-- use the service key) and by admins with `customers:edit`. Customer JWTs are
-- rejected, which closes the "credit my own wallet" RPC.
--
-- The legacy 5-argument overload is dropped: having both overloads made calls
-- that pass exactly five arguments ambiguous ("function ... is not unique").
-- The 7-argument version's defaults cover those callers
-- (e.g. Hetha_admin/services/customerService.ts).
DROP FUNCTION IF EXISTS public.update_wallet_balance(uuid, numeric, text, text, text);

CREATE OR REPLACE FUNCTION public.update_wallet_balance(
  p_user_id        uuid,
  p_amount         numeric,
  p_type           text,
  p_description    text,
  p_initiated_by   text,
  p_reference_type text DEFAULT NULL,
  p_reference_id   text DEFAULT NULL
) RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, internal
AS $$
BEGIN
  IF NOT internal.is_admin_actor('customers:edit') THEN
    RAISE EXCEPTION 'Not authorized to adjust wallet balances';
  END IF;

  RETURN internal.apply_wallet_delta(
    p_user_id, p_amount, p_type, p_description, p_initiated_by,
    p_reference_type, p_reference_id
  );
END;
$$;


-- ---------------------------------------------------------------------------
-- internal.normalize_cart — single parser/validator for cart payloads
-- ---------------------------------------------------------------------------
-- Accepts both shapes used by the codebase:
--   place_order         : [{ "variant_id": uuid, "quantity": int }]
--   create_subscription : [{ "variantId":  uuid, "quantity": int, ... }]
-- Duplicate variants are collapsed. Everything monetary comes from the catalog.
CREATE OR REPLACE FUNCTION internal.normalize_cart(p_items jsonb)
RETURNS TABLE (
  variant_id     uuid,
  quantity       integer,
  unit_price     numeric,
  product_name   text,
  variant_label  text,
  weight_grams   numeric,
  free_delivery  boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, internal
AS $$
DECLARE
  v_count     integer;
  v_item      jsonb;
  v_raw_id    text;
  v_raw_qty   text;
  v_pairs     jsonb := '[]'::jsonb;
  v_expected  integer;
  v_matched   integer;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'Cart payload must be a JSON array';
  END IF;

  v_count := jsonb_array_length(p_items);
  IF v_count = 0 THEN
    RAISE EXCEPTION 'Cart is empty';
  END IF;
  IF v_count > 50 THEN
    RAISE EXCEPTION 'Too many line items (%). Maximum is 50', v_count;
  END IF;

  -- Parse + validate every line before touching the catalog.
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_raw_id  := NULLIF(COALESCE(v_item->>'variant_id', v_item->>'variantId'), '');
    v_raw_qty := COALESCE(v_item->>'quantity', '');

    IF v_raw_id IS NULL
       OR v_raw_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RAISE EXCEPTION 'Cart line has a missing or malformed variant id';
    END IF;

    -- Whole numbers only: blocks negative and fractional quantities, which
    -- previously flowed straight into subtotal arithmetic.
    IF v_raw_qty !~ '^[0-9]{1,2}$' OR v_raw_qty::integer < 1 THEN
      RAISE EXCEPTION 'Cart quantity must be a whole number between 1 and 99 (got "%")', v_raw_qty;
    END IF;

    v_pairs := v_pairs || jsonb_build_object('v', v_raw_id, 'q', v_raw_qty::integer);
  END LOOP;

  SELECT COUNT(DISTINCT e->>'v') INTO v_expected
  FROM jsonb_array_elements(v_pairs) e;

  SELECT COUNT(*) INTO v_matched
  FROM (
    SELECT DISTINCT (e->>'v')::uuid AS v_id
    FROM jsonb_array_elements(v_pairs) e
  ) req
  JOIN public.product_variants pv ON pv.id = req.v_id
  JOIN public.products p          ON p.id  = pv.product_id
  WHERE COALESCE(pv.is_active, true) = true
    AND COALESCE(p.in_stock, true)   = true;

  IF v_matched <> v_expected THEN
    RAISE EXCEPTION 'One or more items are unavailable, inactive, or out of stock';
  END IF;

  RETURN QUERY
  WITH merged AS (
    SELECT (e->>'v')::uuid AS v_id, SUM((e->>'q')::int)::integer AS qty
    FROM jsonb_array_elements(v_pairs) e
    GROUP BY (e->>'v')::uuid
  )
  SELECT
    m.v_id,
    LEAST(m.qty, 99)::integer,
    round(pv.price::numeric, 2),
    p.name,
    pv.label,
    COALESCE(pv.weight_grams, 0)::numeric,
    COALESCE(pv.free_delivery, false)
  FROM merged m
  JOIN public.product_variants pv ON pv.id = m.v_id
  JOIN public.products p          ON p.id  = pv.product_id;
END;
$$;


-- ---------------------------------------------------------------------------
-- Delivery charge — authoritative server-side calculation
-- ---------------------------------------------------------------------------
-- Mirrors lib/services/delivery_charge_service.dart:
--   • variants flagged free_delivery contribute no weight
--   • total billable weight 0            → ₹0
--   • weight inside a tier               → that tier's charge
--   • weight above every tier            → heaviest tier's charge
--   • no tiers configured                → ₹50 fallback
CREATE OR REPLACE FUNCTION internal.compute_delivery_charge(p_items jsonb)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, internal
AS $$
DECLARE
  v_weight  numeric := 0;
  v_charge  numeric;
  v_default numeric := 50;
BEGIN
  SELECT COALESCE(SUM(c.weight_grams * c.quantity), 0)
  INTO v_weight
  FROM internal.normalize_cart(p_items) c
  WHERE c.free_delivery = false;

  IF v_weight IS NULL OR v_weight <= 0 THEN
    RETURN 0;
  END IF;

  SELECT t.charge INTO v_charge
  FROM public.delivery_charge_tiers t
  WHERE v_weight >= t.min_weight_grams
    AND v_weight <= t.max_weight_grams
  ORDER BY t.min_weight_grams
  LIMIT 1;

  IF v_charge IS NOT NULL THEN
    RETURN round(v_charge, 2);
  END IF;

  -- Heavier than every configured tier → charge the heaviest tier.
  SELECT t.charge INTO v_charge
  FROM public.delivery_charge_tiers t
  ORDER BY t.max_weight_grams DESC
  LIMIT 1;

  RETURN round(COALESCE(v_charge, v_default), 2);
END;
$$;

-- Read-only quote used by the client for display. Safe to expose: it only
-- returns catalog-derived numbers and writes nothing.
CREATE OR REPLACE FUNCTION public.quote_cart(p_cart_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, internal
AS $$
DECLARE
  v_subtotal numeric := 0;
  v_delivery numeric := 0;
BEGIN
  SELECT COALESCE(SUM(round(c.unit_price * c.quantity, 2)), 0)
  INTO v_subtotal
  FROM internal.normalize_cart(p_cart_items) c;

  v_delivery := internal.compute_delivery_charge(p_cart_items);

  RETURN jsonb_build_object(
    'subtotal',        round(v_subtotal, 2),
    'delivery_charge', round(v_delivery, 2),
    'total',           round(v_subtotal + v_delivery, 2)
  );
END;
$$;


-- ---------------------------------------------------------------------------
-- internal.place_order_core — hardened order placement
-- ---------------------------------------------------------------------------
-- p_paid_externally: true when a verified Razorpay payment already covers the
-- order (see migration 008). Only reachable from service-role code paths.
CREATE OR REPLACE FUNCTION internal.place_order_core(
  p_user_id           uuid,
  p_address_id        uuid,
  p_payment_method    text,
  p_delivery_charge   numeric,
  p_cart_items        jsonb,
  p_is_admin          boolean DEFAULT false,
  p_paid_externally   boolean DEFAULT false,
  p_razorpay_order_id text    DEFAULT NULL,
  p_razorpay_payment_id text  DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, internal
AS $$
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

  -- Prices always come from the catalog, never from the payload.
  SELECT COALESCE(SUM(round(c.unit_price * c.quantity, 2)), 0)
  INTO v_subtotal
  FROM internal.normalize_cart(p_cart_items) c;

  IF v_subtotal <= 0 THEN
    RAISE EXCEPTION 'Order subtotal must be greater than zero';
  END IF;

  -- Delivery charge: server-computed for customers. Admins may override it
  -- (fee waivers / manual corrections) but never below zero.
  IF p_is_admin AND p_delivery_charge IS NOT NULL THEN
    v_delivery := round(GREATEST(p_delivery_charge, 0), 2);
  ELSE
    v_delivery := internal.compute_delivery_charge(p_cart_items);
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

    -- 3-day subscription buffer (previously client-only). Skipped for admin
    -- placed orders so ops can still fulfil edge cases deliberately.
    IF NOT p_is_admin THEN
      v_commitment := COALESCE(public.get_user_daily_commitment(p_user_id), 0);
      v_reserve    := round(v_commitment * 3, 2);
    END IF;

    IF COALESCE(v_wallet_balance, 0) < v_total + v_reserve THEN
      IF v_reserve > 0 THEN
        RAISE EXCEPTION
          'Insufficient wallet balance. Required: % (order %) plus % reserved for 3 days of subscriptions, available: %',
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
$$;


-- ---------------------------------------------------------------------------
-- public.place_order — same signature/return contract as before
-- ---------------------------------------------------------------------------
-- Returns the order UUID as text (unchanged), so Hetha_app's
-- order_service.dart and Hetha_admin's orderService.ts keep working.
CREATE OR REPLACE FUNCTION public.place_order(
  p_user_id         uuid,
  p_address_id      uuid,
  p_payment_method  text,
  p_delivery_charge numeric,
  p_cart_items      jsonb
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, internal
AS $$
DECLARE
  v_is_admin boolean := internal.is_admin_actor('orders:edit');
  v_result   jsonb;
BEGIN
  IF NOT v_is_admin THEN
    IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
      RAISE EXCEPTION 'Not authorized to place an order for this user';
    END IF;
  END IF;

  v_result := internal.place_order_core(
    p_user_id        => p_user_id,
    p_address_id     => p_address_id,
    p_payment_method => p_payment_method,
    p_delivery_charge=> p_delivery_charge,
    p_cart_items     => p_cart_items,
    p_is_admin       => v_is_admin,
    p_paid_externally=> false
  );

  RETURN (v_result->>'order_id');
END;
$$;


-- ---------------------------------------------------------------------------
-- internal.create_subscription_core — hardened subscription creation
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION internal.create_subscription_core(
  p_user_id         uuid,
  p_start_date      timestamptz,
  p_end_date        timestamptz,
  p_status          text,
  p_address         jsonb,
  p_items           jsonb,
  p_label           text,
  p_cancel_existing boolean DEFAULT false,
  p_is_admin        boolean DEFAULT false
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, internal
AS $$
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

  -- 3-day wallet buffer across ALL subscriptions (previously client-only).
  IF NOT p_is_admin THEN
    SELECT COALESCE(wallet_balance, 0) INTO v_wallet_balance
    FROM public.users WHERE id = p_user_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'User not found';
    END IF;

    v_existing_daily := COALESCE(public.get_user_daily_commitment(p_user_id), 0);
    v_required := round((v_existing_daily + v_new_daily) * 3, 2);

    IF v_wallet_balance < v_required THEN
      RAISE EXCEPTION
        'Insufficient wallet balance (%). You need at least % (3 days x %/day for all subscriptions).',
        v_wallet_balance, v_required, round(v_existing_daily + v_new_daily, 2);
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

  INSERT INTO public.subscriptions (
    user_id, start_date, end_date, status, label,
    snapshot_name, snapshot_phone, snapshot_address_line1, snapshot_address_line2,
    snapshot_landmark, snapshot_city, snapshot_state, snapshot_pincode,
    snapshot_address_type, delivary_area, delivary_frequency, created_at
  ) VALUES (
    p_user_id, p_start_date, p_end_date, p_status,
    COALESCE(p_label, 'Subscription ' || (v_active_count + 1)::text),
    p_address->>'name', p_address->>'phoneNumber', p_address->>'addressLine1',
    p_address->>'addressLine2', p_address->>'landmark', p_address->>'city',
    p_address->>'state', p_address->>'pincode', p_address->>'addressType',
    v_delivery_area, v_delivery_frequency, now()
  ) RETURNING id INTO v_sub_id;

  INSERT INTO public.subscription_items (
    subscription_id, variant_id, product_name_snapshot, variant_label_snapshot,
    unit_price, quantity, item_start_date
  )
  SELECT
    v_sub_id, c.variant_id, c.product_name, c.variant_label,
    c.unit_price, c.quantity,
    COALESCE(
      (SELECT MIN(NULLIF(it->>'startDate', ''))::date
       FROM jsonb_array_elements(p_items) it
       WHERE COALESCE(it->>'variant_id', it->>'variantId') = c.variant_id::text),
      p_start_date::date,
      CURRENT_DATE
    )
  FROM internal.normalize_cart(p_items) c;

  RETURN v_sub_id;
END;
$$;


-- public.create_subscription (7-arg, current) --------------------------------
CREATE OR REPLACE FUNCTION public.create_subscription(
  p_user_id    uuid,
  p_start_date timestamptz,
  p_end_date   timestamptz,
  p_status     text,
  p_address    jsonb,
  p_items      jsonb,
  p_label      text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, internal
AS $$
DECLARE
  v_is_admin boolean := internal.is_admin_actor('subscriptions:edit');
BEGIN
  IF NOT v_is_admin THEN
    IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
      RAISE EXCEPTION 'Not authorized to create a subscription for this user';
    END IF;
  END IF;

  RETURN internal.create_subscription_core(
    p_user_id, p_start_date, p_end_date, p_status, p_address, p_items, p_label,
    false, v_is_admin
  );
END;
$$;


-- public.create_subscription (6-arg legacy) ----------------------------------
-- Kept for Hetha_admin/services/subscriptionService.ts (ad-hoc subscriptions),
-- which relies on the legacy "replace the active subscription" behaviour.
CREATE OR REPLACE FUNCTION public.create_subscription(
  p_user_id    uuid,
  p_start_date timestamptz,
  p_end_date   timestamptz,
  p_status     text,
  p_address    jsonb,
  p_items      jsonb
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, internal
AS $$
DECLARE
  v_is_admin boolean := internal.is_admin_actor('subscriptions:edit');
BEGIN
  IF NOT v_is_admin THEN
    IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
      RAISE EXCEPTION 'Not authorized to create a subscription for this user';
    END IF;
  END IF;

  RETURN internal.create_subscription_core(
    p_user_id, p_start_date, p_end_date, p_status, p_address, p_items, NULL,
    true, v_is_admin
  );
END;
$$;


-- ---------------------------------------------------------------------------
-- Execution grants
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION internal.apply_wallet_delta(uuid, numeric, text, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION internal.place_order_core(uuid, uuid, text, numeric, jsonb, boolean, boolean, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION internal.create_subscription_core(uuid, timestamptz, timestamptz, text, jsonb, jsonb, text, boolean, boolean) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.quote_cart(jsonb) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.place_order(uuid, uuid, text, numeric, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_subscription(uuid, timestamptz, timestamptz, text, jsonb, jsonb, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_subscription(uuid, timestamptz, timestamptz, text, jsonb, jsonb) TO authenticated, service_role;
