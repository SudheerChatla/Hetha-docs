-- =============================================================================
-- CANONICAL FUNCTIONS / RPCs SNAPSHOT — public schema
-- =============================================================================
-- Source : pg_get_functiondef() over the public schema (live database)
--          → query (C) in docs/db/REFRESH.md
-- Synced : 2026-07-28  (post money-integrity migrations 007–012)
-- Scope  : Every function in the `public` schema, exactly as deployed.
--
-- ℹ The `internal` schema is NOT in this file. It holds the privileged money
--   primitives and is deliberately NOT exposed through PostgREST, so nothing in
--   it is reachable over the API. Its full source is in
--   docs/db/functions_internal.sql (also a live export). Contents:
--
--     internal.jwt_role / is_service_actor / is_admin_actor      → 007
--     internal.apply_wallet_delta                                → 007
--     internal.normalize_cart / compute_delivery_charge          → 007
--     internal.place_order_core / create_subscription_core       → 007
--     internal.guard_subscription_update                         → 009
--     internal.assert_subscription_access                        → 009
--     internal.money_checks_disabled                             → 012
--     internal.assert_order_totals / assert_daily_order_total     → 012
--     internal.snap_order_item / snap_subscription_item           → 012
--
-- ⚠ KNOWN ISSUES — verified still present in this export:
--
--   1. cancel_subscription (non-immediate / scheduled branch) writes
--      `scheduled_end_date` and `cancellation_requested_at`, which are NOT
--      columns on `subscriptions`. Scheduled cancellations still fail at
--      runtime. OPEN.
--   2. get_user_role selects `admin_users.role` via `auth_user_id`; neither
--      exists (the columns are `role_id` and `user_id`). The function errors if
--      called. It is unused — has_permission() / is_super_admin() are the live
--      RBAC helpers — and EXECUTE was revoked from anon/authenticated in
--      migration 011. Safe to DROP once you have confirmed nothing calls it.
--
--   (The previous third issue — update_address_as_default writing
--   `addresses.phone` / `.updated_at` — was FIXED in migration 011, together
--   with the missing ownership check. See its definition below.)
--
-- ℹ Money-path summary (see ../ARCHITECTURE.md#money-integrity):
--   • Clients send variant ids and quantities. Prices come from
--     product_variants, the delivery charge from delivery_charge_tiers, and the
--     payable amount from a server-created payment_intents row.
--   • place_order honours p_delivery_charge ONLY for admin callers (fee
--     waivers); for customers it is ignored and recomputed.
--   • Order numbers are 'ORD-<YYYYMMDDHH24MISS>-<nnnn>'; place_order RETURNS
--     the order UUID as text.
--   • Wallet money moves only through internal.apply_wallet_delta, which writes
--     the wallet_transactions ledger row in the same transaction.
--   • Deferred constraint triggers keep order / daily-order totals equal to the
--     sum of their items — see DATA_MODEL.md §12.
--
-- ⚠ create_subscription has TWO overloads. The 6-arg legacy version CANCELS the
--   user's active subscription (used by the admin ad-hoc flow); the 7-arg
--   version takes a label and does not cancel. Prefer the 7-arg one in the app.
-- =============================================================================


-- attach_razorpay_order -------------------------------------------------------
-- Links the Razorpay order id to a payment intent. Service role only.
CREATE OR REPLACE FUNCTION public.attach_razorpay_order(p_intent_id uuid, p_razorpay_order_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
BEGIN
  IF NOT internal.is_service_actor() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  UPDATE public.payment_intents
  SET razorpay_order_id = p_razorpay_order_id
  WHERE id = p_intent_id AND status = 'created';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payment intent % not found or already consumed', p_intent_id;
  END IF;
END;
$function$;


-- cancel_subscription --------------------------------------------------------
-- ⚠ The ELSE branch references columns that do not exist (see known issue 1).
CREATE OR REPLACE FUNCTION public.cancel_subscription(p_subscription_id uuid, p_user_id uuid, p_end_date timestamp with time zone, p_is_immediate boolean, p_cancellation_type text, p_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
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
    UPDATE public.subscriptions
    SET status = 'pending_cancellation',
        scheduled_end_date = p_end_date,                 -- ⚠ column does not exist
        cancellation_requested_at = NOW(),               -- ⚠ column does not exist
        cancellation_type = p_cancellation_type,
        cancellation_reason = p_reason,
        is_custom_cancel_date = (p_cancellation_type = 'custom')
    WHERE id = p_subscription_id AND user_id = p_user_id;
  END IF;
END;
$function$;


-- claim_adhoc_user -----------------------------------------------------------
-- Merges an is_adhoc row onto a real auth account. Matching identity comes from
-- the JWT, not the request body (migration 009), so a caller cannot claim
-- someone else's ad-hoc account — and its wallet.
CREATE OR REPLACE FUNCTION public.claim_adhoc_user(p_auth_uid uuid, p_email text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_first_name text DEFAULT NULL::text, p_last_name text DEFAULT NULL::text)
 RETURNS users
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_user        public.users;
  v_adhoc_match public.users;
  v_collision   uuid;
  v_claims      jsonb;
  v_jwt_email   text;
  v_jwt_phone   text;
  v_email       text;
  v_phone       text;
  v_first_name  text := NULLIF(p_first_name, '');
  v_last_name   text := NULLIF(p_last_name, '');
BEGIN
  IF p_auth_uid IS NULL THEN
    RAISE EXCEPTION 'p_auth_uid is required';
  END IF;

  -- A caller may only claim/create their own row.
  IF NOT internal.is_service_actor() THEN
    IF auth.uid() IS NULL OR auth.uid() <> p_auth_uid THEN
      RAISE EXCEPTION 'Not authorized';
    END IF;
  END IF;

  v_claims    := COALESCE(NULLIF(current_setting('request.jwt.claims', true), ''), '{}')::jsonb;
  v_jwt_email := NULLIF(v_claims->>'email', '');
  v_jwt_phone := NULLIF(v_claims->>'phone', '');

  -- Identity used for matching comes from the token, not the request body.
  -- (Service-role callers may pass values explicitly.)
  IF internal.is_service_actor() THEN
    v_email := NULLIF(p_email, '');
    v_phone := NULLIF(p_phone, '');
  ELSE
    v_email := COALESCE(v_jwt_email, NULLIF(p_email, ''));
    v_phone := COALESCE(v_jwt_phone, NULLIF(p_phone, ''));

    IF v_jwt_email IS NOT NULL AND NULLIF(p_email, '') IS NOT NULL
       AND lower(p_email) <> lower(v_jwt_email) THEN
      RAISE EXCEPTION 'Email does not match the signed-in identity';
    END IF;
    IF v_jwt_phone IS NOT NULL AND NULLIF(p_phone, '') IS NOT NULL
       AND p_phone <> v_jwt_phone THEN
      RAISE EXCEPTION 'Phone does not match the signed-in identity';
    END IF;
  END IF;

  SELECT * INTO v_user FROM public.users WHERE id = p_auth_uid LIMIT 1;
  IF FOUND THEN
    RETURN v_user;
  END IF;

  IF v_email IS NOT NULL OR v_phone IS NOT NULL THEN
    SELECT * INTO v_adhoc_match
    FROM public.users
    WHERE is_adhoc = TRUE
      AND (
        (v_email IS NOT NULL AND lower(email) = lower(v_email)) OR
        (v_phone IS NOT NULL AND phone = v_phone)
      )
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
      UPDATE public.users
      SET id         = p_auth_uid,
          is_adhoc   = FALSE,
          email      = COALESCE(v_email, email),
          phone      = COALESCE(v_phone, phone),
          first_name = COALESCE(v_first_name, first_name),
          last_name  = COALESCE(v_last_name, last_name),
          updated_at = now()
      WHERE id = v_adhoc_match.id
      RETURNING * INTO v_user;

      RETURN v_user;
    END IF;

    SELECT id INTO v_collision
    FROM public.users
    WHERE is_adhoc = FALSE
      AND id <> p_auth_uid
      AND (
        (v_email IS NOT NULL AND lower(email) = lower(v_email)) OR
        (v_phone IS NOT NULL AND phone = v_phone)
      )
    LIMIT 1;

    IF v_collision IS NOT NULL THEN
      RAISE EXCEPTION 'Another account already exists with this email or phone'
        USING ERRCODE = 'unique_violation';
    END IF;
  END IF;

  INSERT INTO public.users (
    id, email, phone, first_name, last_name,
    wallet_balance, notifications_enabled, dark_mode, language, is_adhoc
  ) VALUES (
    p_auth_uid, v_email, v_phone, v_first_name, v_last_name,
    0, TRUE, FALSE, 'en', FALSE
  )
  RETURNING * INTO v_user;

  RETURN v_user;
END;
$function$;


-- create_payment_intent ------------------------------------------------------
-- Records "this user must pay exactly this much" BEFORE Razorpay checkout opens.
-- For orders the amount is derived from the catalog; for top-ups the requested
-- amount is range-checked. Service role only (the razorpay edge function).
CREATE OR REPLACE FUNCTION public.create_payment_intent(p_user_id uuid, p_purpose text, p_amount_paise bigint DEFAULT NULL::bigint, p_address_id uuid DEFAULT NULL::uuid, p_cart_items jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_quote        jsonb;
  v_amount_paise bigint;
  v_intent_id    uuid;
  v_min_topup    bigint := 100;         -- ₹1
  v_max_topup    bigint := 5000000;     -- ₹50,000
BEGIN
  IF NOT internal.is_service_actor() THEN
    RAISE EXCEPTION 'Payment intents may only be created server-side';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'user id is required';
  END IF;

  IF p_purpose = 'order' THEN
    IF p_address_id IS NULL THEN
      RAISE EXCEPTION 'address id is required for an order payment';
    END IF;
    PERFORM 1 FROM public.addresses
      WHERE id = p_address_id AND user_id = p_user_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Address not found or does not belong to user';
    END IF;

    -- Authoritative amount: catalog prices + server-computed delivery charge.
    v_quote := public.quote_cart(p_cart_items);
    v_amount_paise := round((v_quote->>'total')::numeric * 100)::bigint;

    IF v_amount_paise <= 0 THEN
      RAISE EXCEPTION 'Order total must be greater than zero';
    END IF;

  ELSIF p_purpose = 'wallet_topup' THEN
    IF p_amount_paise IS NULL THEN
      RAISE EXCEPTION 'amount is required for a wallet top-up';
    END IF;
    IF p_amount_paise < v_min_topup OR p_amount_paise > v_max_topup THEN
      RAISE EXCEPTION 'Top-up amount must be between % and % paise', v_min_topup, v_max_topup;
    END IF;
    v_amount_paise := p_amount_paise;
    v_quote := jsonb_build_object('total', round(v_amount_paise::numeric / 100, 2));

  ELSE
    RAISE EXCEPTION 'Unknown payment purpose: %', p_purpose;
  END IF;

  INSERT INTO public.payment_intents (
    user_id, purpose, amount_paise, address_id, cart_items
  ) VALUES (
    p_user_id, p_purpose, v_amount_paise, p_address_id,
    CASE WHEN p_purpose = 'order' THEN p_cart_items ELSE NULL END
  ) RETURNING id INTO v_intent_id;

  RETURN jsonb_build_object(
    'intent_id',     v_intent_id,
    'amount_paise',  v_amount_paise,
    'quote',         v_quote
  );
END;
$function$;


-- create_subscription (7-arg, CURRENT — label, max 5, no auto-cancel) --------
-- Authorization wrapper; the work happens in internal.create_subscription_core,
-- which reads unit_price from product_variants (the payload's `price` is
-- ignored) and enforces the 3-day wallet buffer for customer callers.
CREATE OR REPLACE FUNCTION public.create_subscription(p_user_id uuid, p_start_date timestamp with time zone, p_end_date timestamp with time zone, p_status text, p_address jsonb, p_items jsonb, p_label text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
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
$function$;


-- create_subscription (6-arg, LEGACY — cancels the active subscription) ------
-- Used by Hetha_admin/services/subscriptionService.ts (ad-hoc subscriptions),
-- which relies on the replace-existing behaviour. Same server-side pricing.
CREATE OR REPLACE FUNCTION public.create_subscription(p_user_id uuid, p_start_date timestamp with time zone, p_end_date timestamp with time zone, p_status text, p_address jsonb, p_items jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
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
$function$;


-- finalize_daily_run ---------------------------------------------------------
-- Locks the day's subscription orders and debits wallets. Requires
-- `daily_ops:edit` (migration 009) — it was PUBLIC-executable before, so any
-- logged-in customer could trigger every customer's deduction.
CREATE OR REPLACE FUNCTION public.finalize_daily_run(p_delivery_date date, p_admin_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_run_id uuid;
  v_run_status text;
  v_order record;
  v_total_deducted numeric := 0;
  v_deduction_errors jsonb := '[]'::jsonb;
  v_orders_finalized integer := 0;
  v_total_value numeric := 0;
BEGIN
  IF NOT internal.is_admin_actor('daily_ops:edit') THEN
    RAISE EXCEPTION 'Not authorized to finalize a delivery run';
  END IF;

  INSERT INTO public.daily_ops_runs (delivery_date, status, generated_by, generated_at)
  VALUES (p_delivery_date, 'draft', p_admin_id, now())
  ON CONFLICT (delivery_date) DO NOTHING;

  SELECT id, status INTO v_run_id, v_run_status
  FROM public.daily_ops_runs
  WHERE delivery_date = p_delivery_date
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Run record not found for %', p_delivery_date;
  END IF;

  IF v_run_status != 'draft' THEN
    RAISE EXCEPTION 'Cannot finalize: date is already %', v_run_status;
  END IF;

  UPDATE public.subscription_daily_orders
  SET is_finalized = true,
      finalized_at = now(),
      finalized_by = p_admin_id
  WHERE delivery_date = p_delivery_date
    AND status = 'pending'
    AND is_finalized = false;

  GET DIAGNOSTICS v_orders_finalized = ROW_COUNT;

  FOR v_order IN
    SELECT sdo.id, sdo.user_id, sdo.total_value, s.payment_method
    FROM public.subscription_daily_orders sdo
    JOIN public.subscriptions s ON s.id = sdo.subscription_id
    WHERE sdo.delivery_date = p_delivery_date
      AND sdo.is_finalized = true
      AND sdo.payment_status = 'pending'
      AND s.payment_method = 'wallet'
  LOOP
    BEGIN
      PERFORM internal.apply_wallet_delta(
        v_order.user_id,
        v_order.total_value,
        'debit',
        'Subscription delivery ' || p_delivery_date::text,
        'admin',
        'subscription',
        v_order.id::text
      );

      UPDATE public.subscription_daily_orders
      SET payment_status = 'paid',
          wallet_deducted_at = now()
      WHERE id = v_order.id;

      v_total_deducted := v_total_deducted + v_order.total_value;

    EXCEPTION WHEN OTHERS THEN
      v_deduction_errors := v_deduction_errors || jsonb_build_object(
        'order_id', v_order.id,
        'user_id', v_order.user_id,
        'amount', v_order.total_value,
        'error', SQLERRM
      );

      UPDATE public.subscription_daily_orders
      SET payment_status = 'failed'
      WHERE id = v_order.id;
    END;
  END LOOP;

  SELECT COALESCE(SUM(total_value), 0) INTO v_total_value
  FROM public.subscription_daily_orders
  WHERE delivery_date = p_delivery_date AND is_finalized = true;

  UPDATE public.daily_ops_runs
  SET status = 'finalized',
      finalized_at = now(),
      finalized_by = p_admin_id,
      total_orders = v_orders_finalized,
      total_value = v_total_value,
      wallet_deduction_completed_at = now(),
      updated_at = now()
  WHERE id = v_run_id;

  RETURN jsonb_build_object(
    'finalized', v_orders_finalized,
    'total_deducted', v_total_deducted,
    'total_value', v_total_value,
    'deduction_errors', v_deduction_errors
  );
END;
$function$;


-- finalize_order_payment -----------------------------------------------------
-- Settles a verified Razorpay payment into an order. Idempotent per
-- razorpay_payment_id and refuses underpayment. p_amount_paid_paise MUST come
-- from a server-side razorpay.payments.fetch, never from the client.
CREATE OR REPLACE FUNCTION public.finalize_order_payment(p_intent_id uuid, p_razorpay_order_id text, p_razorpay_payment_id text, p_amount_paid_paise bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_intent public.payment_intents;
  v_result jsonb;
BEGIN
  IF NOT internal.is_service_actor() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT * INTO v_intent
  FROM public.payment_intents
  WHERE id = p_intent_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payment intent not found';
  END IF;

  IF v_intent.purpose <> 'order' THEN
    RAISE EXCEPTION 'Payment intent is not an order payment';
  END IF;

  IF v_intent.status = 'paid' THEN
    IF v_intent.razorpay_payment_id = p_razorpay_payment_id THEN
      RETURN jsonb_build_object('already_processed', true, 'order_id', v_intent.order_id);
    END IF;
    RAISE EXCEPTION 'Payment intent already settled with a different payment';
  END IF;

  IF v_intent.razorpay_order_id IS DISTINCT FROM p_razorpay_order_id THEN
    RAISE EXCEPTION 'Razorpay order does not match this payment intent';
  END IF;

  -- Underpayment check: the captured amount must cover the amount this intent
  -- was created for (which was computed from the catalog, not the client).
  IF p_amount_paid_paise IS NULL OR p_amount_paid_paise < v_intent.amount_paise THEN
    RAISE EXCEPTION 'Captured amount % is less than the order amount %',
      COALESCE(p_amount_paid_paise, 0), v_intent.amount_paise;
  END IF;

  v_result := internal.place_order_core(
    p_user_id             => v_intent.user_id,
    p_address_id          => v_intent.address_id,
    p_payment_method      => 'razorpay',
    p_delivery_charge     => NULL,
    p_cart_items          => v_intent.cart_items,
    p_is_admin            => false,
    p_paid_externally     => true,
    p_razorpay_order_id   => p_razorpay_order_id,
    p_razorpay_payment_id => p_razorpay_payment_id
  );

  UPDATE public.payment_intents
  SET status = 'paid',
      razorpay_payment_id = p_razorpay_payment_id,
      amount_paid_paise = p_amount_paid_paise,
      order_id = (v_result->>'order_id')::uuid,
      consumed_at = now()
  WHERE id = p_intent_id;

  RETURN v_result || jsonb_build_object('already_processed', false);
END;
$function$;


-- finalize_wallet_topup ------------------------------------------------------
-- Credits the wallet with what Razorpay actually captured, capped at the intent
-- amount, exactly once. p_amount_paid_paise MUST come from a server-side
-- razorpay.payments.fetch — the old flow trusted a client `amount` field.
CREATE OR REPLACE FUNCTION public.finalize_wallet_topup(p_intent_id uuid, p_razorpay_order_id text, p_razorpay_payment_id text, p_amount_paid_paise bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_intent   public.payment_intents;
  v_credit   numeric;
  v_balance  numeric;
BEGIN
  IF NOT internal.is_service_actor() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT * INTO v_intent
  FROM public.payment_intents
  WHERE id = p_intent_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payment intent not found';
  END IF;

  IF v_intent.purpose <> 'wallet_topup' THEN
    RAISE EXCEPTION 'Payment intent is not a wallet top-up';
  END IF;

  -- Replay protection: the same payment can only ever be credited once.
  IF v_intent.status = 'paid' THEN
    IF v_intent.razorpay_payment_id = p_razorpay_payment_id THEN
      SELECT wallet_balance INTO v_balance FROM public.users WHERE id = v_intent.user_id;
      RETURN jsonb_build_object(
        'already_processed', true,
        'credited',          round(COALESCE(v_intent.amount_paid_paise, 0)::numeric / 100, 2),
        'new_balance',       v_balance
      );
    END IF;
    RAISE EXCEPTION 'Payment intent already settled with a different payment';
  END IF;

  IF v_intent.razorpay_order_id IS DISTINCT FROM p_razorpay_order_id THEN
    RAISE EXCEPTION 'Razorpay order does not match this payment intent';
  END IF;

  IF p_amount_paid_paise IS NULL OR p_amount_paid_paise <= 0 THEN
    RAISE EXCEPTION 'Captured amount is missing';
  END IF;

  -- Credit exactly what was captured, never more than the intent asked for.
  v_credit := round(LEAST(p_amount_paid_paise, v_intent.amount_paise)::numeric / 100, 2);

  UPDATE public.payment_intents
  SET status = 'paid',
      razorpay_payment_id = p_razorpay_payment_id,
      amount_paid_paise = p_amount_paid_paise,
      consumed_at = now()
  WHERE id = p_intent_id;

  v_balance := internal.apply_wallet_delta(
    v_intent.user_id, v_credit, 'credit',
    'Razorpay Wallet Top-up (' || p_razorpay_payment_id || ')',
    'system', 'wallet_topup', p_intent_id::text
  );

  RETURN jsonb_build_object(
    'already_processed', false,
    'credited',          v_credit,
    'new_balance',       v_balance
  );
END;
$function$;


-- get_user_daily_commitment --------------------------------------------------
-- Σ daily cost across a user's active/pending subscriptions. Drives the 3-day
-- buffer rule in place_order and internal.create_subscription_core.
CREATE OR REPLACE FUNCTION public.get_user_daily_commitment(p_user_id uuid)
 RETURNS numeric
 LANGUAGE sql
AS $function$
  SELECT COALESCE(SUM(si.unit_price * si.quantity), 0)
  FROM public.subscription_items si
  JOIN public.subscriptions s ON s.id = si.subscription_id
  WHERE s.user_id = p_user_id
    AND s.status IN ('active', 'pending_cancellation')
    AND si.is_active = true;
$function$;


-- get_user_role (⚠ BROKEN + UNUSED — see known issue 2) ----------------------
-- `admin_users` has no `role` column and no `auth_user_id` column. EXECUTE was
-- revoked from anon/authenticated in migration 011. Candidate for DROP.
CREATE OR REPLACE FUNCTION public.get_user_role(uid uuid)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT role
  FROM admin_users
  WHERE auth_user_id = uid
  LIMIT 1;
$function$;


-- has_permission (RBAC helper used by RLS policies) --------------------------
-- Keeps its anon/authenticated EXECUTE grants on purpose: RLS policy
-- expressions are evaluated as the calling role, including anon on the
-- world-readable catalog tables.
CREATE OR REPLACE FUNCTION public.has_permission(p text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM admin_role_permissions arp
    JOIN admin_users au ON au.role_id = arp.role_id
    WHERE au.user_id = auth.uid()
      AND au.is_active = true
      AND arp.permission = p
  );
$function$;


-- is_super_admin (RBAC helper used by RLS policies) -------------------------
CREATE OR REPLACE FUNCTION public.is_super_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM admin_users au
    JOIN roles r ON r.id = au.role_id
    WHERE au.user_id = auth.uid()
      AND au.is_active = true
      AND r.role = 'super_admin'
  );
$function$;


-- mark_payment_intent_failed -------------------------------------------------
-- Housekeeping for abandoned checkouts. Service role only.
CREATE OR REPLACE FUNCTION public.mark_payment_intent_failed(p_intent_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
BEGIN
  IF NOT internal.is_service_actor() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  UPDATE public.payment_intents
  SET status = 'failed'
  WHERE id = p_intent_id AND status = 'created';
END;
$function$;


-- place_order ----------------------------------------------------------------
-- Authorization wrapper. internal.place_order_core does the work: prices from
-- product_variants, delivery charge from internal.compute_delivery_charge
-- (p_delivery_charge honoured for admins only), quantity validation, the 3-day
-- wallet buffer, and payment_pending for customer-initiated online orders.
-- RETURNS the order UUID as text (unchanged contract).
CREATE OR REPLACE FUNCTION public.place_order(p_user_id uuid, p_address_id uuid, p_payment_method text, p_delivery_charge numeric, p_cart_items jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
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
$function$;


-- quote_cart -----------------------------------------------------------------
-- Read-only quote for display: {subtotal, delivery_charge, total} from the
-- catalog. Safe to expose to anon/authenticated — it writes nothing and is the
-- same maths place_order uses, so the UI matches the charge.
CREATE OR REPLACE FUNCTION public.quote_cart(p_cart_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
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
$function$;


-- remove_paused_dates --------------------------------------------------------
-- Splits/removes pause ranges around specific dates. Ownership-checked since
-- migration 009 (it previously accepted any subscription id).
CREATE OR REPLACE FUNCTION public.remove_paused_dates(p_subscription_id uuid, p_dates jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  date_val DATE;
  row_rec RECORD;
BEGIN
  PERFORM internal.assert_subscription_access(p_subscription_id);

  FOR date_val IN SELECT (jsonb_array_elements_text(p_dates))::DATE
  LOOP
    FOR row_rec IN
      SELECT id, pause_start_date, pause_end_date
      FROM public.subscription_pauses
      WHERE subscription_id = p_subscription_id
        AND pause_start_date <= date_val
        AND pause_end_date >= date_val
    LOOP
      DELETE FROM public.subscription_pauses WHERE id = row_rec.id;

      IF row_rec.pause_start_date < date_val THEN
        INSERT INTO public.subscription_pauses (subscription_id, pause_start_date, pause_end_date, created_by)
        VALUES (p_subscription_id, row_rec.pause_start_date, date_val - 1, 'user');
      END IF;

      IF row_rec.pause_end_date > date_val THEN
        INSERT INTO public.subscription_pauses (subscription_id, pause_start_date, pause_end_date, created_by)
        VALUES (p_subscription_id, date_val + 1, row_rec.pause_end_date, 'user');
      END IF;
    END LOOP;
  END LOOP;
END;
$function$;


-- rls_auto_enable (EVENT trigger function) -----------------------------------
-- Runs ALTER TABLE ... ENABLE ROW LEVEL SECURITY on every new public table.
-- This is why all public tables have RLS on. Not callable over the API.
CREATE OR REPLACE FUNCTION public.rls_auto_enable()
 RETURNS event_trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$function$;


-- set_reviews_updated_at (TABLE trigger function) ---------------------------
-- Touches reviews.updated_at. EXECUTE revoked from anon/authenticated in
-- migration 011 — trigger execution checks the table's TRIGGER privilege, not
-- EXECUTE on the function.
CREATE OR REPLACE FUNCTION public.set_reviews_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$function$;


-- update_address_as_default --------------------------------------------------
-- FIXED in migration 011: writes `phone_number` (accepting either `phone` or
-- `phone_number` in the payload), no longer writes a non-existent `updated_at`,
-- raises when the address doesn't belong to the user, and — since it is
-- SECURITY DEFINER and takes p_user_id — now checks the caller's identity.
CREATE OR REPLACE FUNCTION public.update_address_as_default(p_user_id uuid, p_address_id uuid, p_address_data jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
BEGIN
  IF NOT internal.is_admin_actor('customers:edit') THEN
    IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
      RAISE EXCEPTION 'Not authorized to modify addresses for this user';
    END IF;
  END IF;

  UPDATE public.addresses
  SET is_default = false
  WHERE user_id = p_user_id AND is_default = true;

  UPDATE public.addresses
  SET
    address_line1 = COALESCE(p_address_data->>'address_line1', address_line1),
    address_line2 = COALESCE(p_address_data->>'address_line2', address_line2),
    city          = COALESCE(p_address_data->>'city', city),
    state         = COALESCE(p_address_data->>'state', state),
    pincode       = COALESCE(p_address_data->>'pincode', pincode),
    landmark      = COALESCE(p_address_data->>'landmark', landmark),
    -- was `phone` (no such column); the column is phone_number. Accept either
    -- key from the caller so existing client payloads keep working.
    phone_number  = COALESCE(p_address_data->>'phone_number',
                             p_address_data->>'phone', phone_number),
    name          = COALESCE(p_address_data->>'name', name),
    address_type  = COALESCE(p_address_data->>'address_type', address_type),
    is_default    = true
    -- `updated_at` removed: public.addresses has no such column.
  WHERE id = p_address_id AND user_id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Address not found or does not belong to user';
  END IF;
END;
$function$;


-- update_wallet_balance ------------------------------------------------------
-- Authorization wrapper only (service role / super admin / customers:edit); the
-- row-locked balance change + ledger write live in
-- internal.apply_wallet_delta. The legacy 5-arg overload was DROPPED in
-- migration 007 — with both present, 5-argument calls were ambiguous
-- ("function ... is not unique"). Confirmed: only this overload exists.
CREATE OR REPLACE FUNCTION public.update_wallet_balance(p_user_id uuid, p_amount numeric, p_type text, p_description text, p_initiated_by text, p_reference_type text DEFAULT NULL::text, p_reference_id text DEFAULT NULL::text)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
BEGIN
  IF NOT internal.is_admin_actor('customers:edit') THEN
    RAISE EXCEPTION 'Not authorized to adjust wallet balances';
  END IF;

  RETURN internal.apply_wallet_delta(
    p_user_id, p_amount, p_type, p_description, p_initiated_by,
    p_reference_type, p_reference_id
  );
END;
$function$;


-- upsert_pauses --------------------------------------------------------------
-- Merges overlapping/adjacent pause ranges. Ownership-checked since migration
-- 009 (it previously accepted any subscription id).
CREATE OR REPLACE FUNCTION public.upsert_pauses(p_subscription_id uuid, p_ranges jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  r JSONB;
  new_start DATE;
  new_end DATE;
  merged_start DATE;
  merged_end DATE;
  overlap_ids UUID[];
BEGIN
  PERFORM internal.assert_subscription_access(p_subscription_id);

  FOR r IN SELECT * FROM jsonb_array_elements(p_ranges)
  LOOP
    new_start := (r->>'start')::DATE;
    new_end := (r->>'end')::DATE;

    SELECT array_agg(id),
           LEAST(MIN(pause_start_date), new_start),
           GREATEST(MAX(pause_end_date), new_end)
    INTO overlap_ids, merged_start, merged_end
    FROM public.subscription_pauses
    WHERE subscription_id = p_subscription_id
      AND pause_start_date <= (new_end + INTERVAL '1 day')::DATE
      AND pause_end_date >= (new_start - INTERVAL '1 day')::DATE;

    IF overlap_ids IS NOT NULL THEN
      DELETE FROM public.subscription_pauses WHERE id = ANY(overlap_ids);
    ELSE
      merged_start := new_start;
      merged_end := new_end;
    END IF;

    INSERT INTO public.subscription_pauses (subscription_id, pause_start_date, pause_end_date, created_by)
    VALUES (p_subscription_id, merged_start, merged_end, 'user');
  END LOOP;
END;
$function$;
