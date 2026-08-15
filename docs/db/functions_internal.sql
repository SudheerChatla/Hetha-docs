-- =============================================================================
-- CANONICAL FUNCTIONS SNAPSHOT — internal schema
-- =============================================================================
-- Source : pg_get_functiondef() over the `internal` schema (live database)
--          → query (C) in docs/db/REFRESH.md with n.nspname = 'internal'
-- Synced : 2026-07-28  (money-integrity migrations 007–012)
--
-- ⚠ THIS SCHEMA IS PRIVILEGED AND MUST STAY UNREACHABLE FROM THE API.
--   `internal` is NOT in the project's PostgREST "Exposed schemas" (Dashboard →
--   Settings → API), and every function here has had EXECUTE revoked from
--   PUBLIC / anon / authenticated (migrations 007 and 010). The only callers are:
--     • the public wrapper RPCs (place_order, create_subscription,
--       update_wallet_balance, quote_cart, finalize_*, upsert_pauses, …), which
--       are SECURITY DEFINER and owned by the same role, and
--       reach in via `SET search_path = public, internal`;
--     • the triggers in migration 012.
--   Do NOT add `internal` to the exposed schemas, and do NOT grant EXECUTE on
--   anything here to anon/authenticated.
--
-- Contents (16 functions):
--   Caller identity        jwt_role, is_service_actor, is_admin_actor
--   Wallet                 apply_wallet_delta            (the ONLY writer of
--                                                          users.wallet_balance)
--   Cart / pricing         normalize_cart, compute_delivery_charge
--   Order / subscription   place_order_core, create_subscription_core
--   Serviceability         serviceable_area_id
--   Access guards          assert_subscription_access, guard_subscription_update
--   Money invariants       money_checks_disabled, assert_order_totals,
--                          assert_daily_order_total, snap_order_item,
--                          snap_subscription_item
--
-- Migration provenance: 007 created jwt_role, is_service_actor, is_admin_actor,
-- apply_wallet_delta, normalize_cart, compute_delivery_charge, place_order_core,
-- create_subscription_core. 009 added assert_subscription_access,
-- guard_subscription_update. 012 added money_checks_disabled,
-- assert_order_totals, assert_daily_order_total, snap_order_item,
-- snap_subscription_item. 016 added serviceable_area_id.
--
-- ℹ `SET search_path TO 'public', 'internal'` (as pg_get_functiondef renders it)
--   is `SET search_path = public, internal` — the qualified form the migrations
--   were written with.
-- =============================================================================


-- apply_wallet_delta ---------------------------------------------------------
-- The single privileged primitive that moves users.wallet_balance. Row-locked
-- (FOR UPDATE), NaN-safe, and writes the matching wallet_transactions ledger row
-- in the same transaction. The public update_wallet_balance RPC is only an
-- authorization wrapper around this.
CREATE OR REPLACE FUNCTION internal.apply_wallet_delta(p_user_id uuid, p_amount numeric, p_type text, p_description text, p_initiated_by text, p_reference_type text DEFAULT NULL::text, p_reference_id text DEFAULT NULL::text)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
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
$function$;


-- assert_daily_order_total (TRIGGER, deferred) -------------------------------
-- subscription_daily_orders.total_value must equal Σ its items. Guards both the
-- parent table and its items. See migration 012.
CREATE OR REPLACE FUNCTION internal.assert_daily_order_total()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
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
$function$;


-- assert_order_totals (TRIGGER, deferred) ------------------------------------
-- orders.subtotal = Σ order_items.total_price and total = subtotal +
-- delivery_charge, delivery_charge >= 0, and ≥ 1 line item. Guards both the
-- parent table and its items. See migration 012.
CREATE OR REPLACE FUNCTION internal.assert_order_totals()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
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
$function$;


-- assert_subscription_access -------------------------------------------------
-- Ownership guard used by upsert_pauses / remove_paused_dates. Service actors
-- and admins with subscriptions:edit pass; otherwise the caller must own the
-- subscription. See migration 009.
CREATE OR REPLACE FUNCTION internal.assert_subscription_access(p_subscription_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_owner uuid;
BEGIN
  SELECT user_id INTO v_owner FROM public.subscriptions WHERE id = p_subscription_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Subscription not found';
  END IF;

  IF internal.is_admin_actor('subscriptions:edit') THEN
    RETURN;
  END IF;

  IF auth.uid() IS NULL OR auth.uid() <> v_owner THEN
    RAISE EXCEPTION 'Not authorized for this subscription';
  END IF;
END;
$function$;


-- compute_delivery_charge ----------------------------------------------------
-- Authoritative delivery charge from delivery_charge_tiers + variant weights.
-- Mirrors DeliveryChargeService in the app: free_delivery variants contribute
-- no weight; 0 weight → ₹0; inside a tier → that tier; above every tier → the
-- heaviest tier; no tiers → ₹50.
CREATE OR REPLACE FUNCTION internal.compute_delivery_charge(p_items jsonb)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
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
$function$;


-- create_subscription_core ---------------------------------------------------
-- The body behind both public.create_subscription overloads. Reads unit_price
-- from product_variants (client `price` ignored), enforces max-5 and the 3-day
-- wallet buffer for customer callers, optionally replaces the active
-- subscription (legacy 6-arg path), derives delivery area from the pincode.
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
$function$;


-- guard_subscription_update (TRIGGER) ----------------------------------------
-- Non-admins may not change subscriptions.user_id or payment_method. See
-- migration 009.
CREATE OR REPLACE FUNCTION internal.guard_subscription_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
BEGIN
  IF internal.is_admin_actor('subscriptions:edit') THEN
    RETURN NEW;
  END IF;

  IF NEW.user_id IS DISTINCT FROM OLD.user_id THEN
    RAISE EXCEPTION 'Subscription owner cannot be changed';
  END IF;

  IF NEW.payment_method IS DISTINCT FROM OLD.payment_method THEN
    RAISE EXCEPTION 'Subscription payment method can only be changed by staff';
  END IF;

  RETURN NEW;
END;
$function$;


-- is_admin_actor -------------------------------------------------------------
-- True for service actors, and for signed-in admins holding p_permission (or
-- super admin). The gate the public money RPCs use to decide admin vs customer.
CREATE OR REPLACE FUNCTION internal.is_admin_actor(p_permission text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
  IF internal.is_service_actor() THEN
    RETURN true;
  END IF;
  IF auth.uid() IS NULL THEN
    RETURN false;
  END IF;
  RETURN public.is_super_admin() OR public.has_permission(p_permission);
END;
$function$;


-- is_service_actor -----------------------------------------------------------
-- True for the service-role key (edge functions / admin API routes) and for
-- direct SQL sessions (jwt_role() = 'internal'). Never true for the Flutter app
-- or the admin browser session.
CREATE OR REPLACE FUNCTION internal.is_service_actor()
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  SELECT internal.jwt_role() IN ('service_role', 'internal');
$function$;


-- jwt_role -------------------------------------------------------------------
-- The role on the current PostgREST request ('anon' | 'authenticated' |
-- 'service_role'); 'internal' when there are no request claims (direct SQL).
CREATE OR REPLACE FUNCTION internal.jwt_role()
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role',
    'internal'
  );
$function$;


-- money_checks_disabled ------------------------------------------------------
-- Escape hatch for deliberate data repair: SET LOCAL hetha.skip_money_checks =
-- 'on'. A session GUC, so it cannot be set through PostgREST by a client.
CREATE OR REPLACE FUNCTION internal.money_checks_disabled()
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  SELECT COALESCE(NULLIF(current_setting('hetha.skip_money_checks', true), ''), 'off') = 'on';
$function$;


-- normalize_cart -------------------------------------------------------------
-- The single parser/validator for cart payloads (accepts variant_id or
-- variantId). UUID-format + whole-number-quantity (1–99) validation, duplicate
-- merge, and a join that rejects unknown / inactive / out-of-stock variants.
-- Everything monetary (price, name, label, weight) comes from the catalog.
CREATE OR REPLACE FUNCTION internal.normalize_cart(p_items jsonb)
 RETURNS TABLE(variant_id uuid, quantity integer, unit_price numeric, product_name text, variant_label text, weight_grams numeric, free_delivery boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
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
$function$;


-- place_order_core -----------------------------------------------------------
-- The body behind public.place_order and finalize_order_payment. Prices the
-- cart from the catalog, computes the delivery charge (p_delivery_charge only
-- honoured for admins), enforces the 3-day buffer for wallet payments, parks
-- unverified online orders in payment_pending, inserts order + items +
-- tracking, and debits the wallet via apply_wallet_delta.
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
$function$;


-- snap_order_item (TRIGGER, before insert/update) ----------------------------
-- order_items.unit_price is snapped to the catalog on INSERT; total_price is
-- always derived. Historical rows keep their snapshot on UPDATE. Migration 012.
CREATE OR REPLACE FUNCTION internal.snap_order_item()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
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
$function$;


-- snap_subscription_item (TRIGGER, before insert/update) ---------------------
-- subscription_items.unit_price is snapped to the catalog on INSERT and is
-- IMMUTABLE afterwards — this is the column the daily run sheet bills against.
-- Migration 012.
CREATE OR REPLACE FUNCTION internal.snap_subscription_item()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
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
$function$;



-- serviceable_area_id --------------------------------------------------------
-- Returns the area_id for a pincode if it belongs to an active delivery area,
-- NULL otherwise. Used by place_order for delivery scope enforcement and can
-- replace the inline area-derivation in create_subscription_core.
-- Added: migration 016_delivery_scope.
CREATE OR REPLACE FUNCTION internal.serviceable_area_id(p_pincode text)
 RETURNS uuid
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $$
  SELECT p.area_id
  FROM public.pincodes p
  JOIN public.delivery_areas a ON a.id = p.area_id
  WHERE p.pincode = p_pincode AND a.is_active
  LIMIT 1;
$$;
