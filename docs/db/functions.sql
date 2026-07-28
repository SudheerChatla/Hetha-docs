-- =============================================================================
-- CANONICAL FUNCTIONS / RPCs SNAPSHOT — public schema
-- =============================================================================
-- Source : pg_get_functiondef() over public schema (live database)
-- Synced : 2026-06-01
-- Scope  : All public database functions / RPCs as deployed.
--
-- #############################################################################
-- ## ⚠ PARTIALLY SUPERSEDED — 2026-07-28 (money-integrity work)              ##
-- #############################################################################
-- The functions below marked [SUPERSEDED] were REPLACED by migrations 007–012.
-- What is in this file for them is the PRE-migration version, kept as history.
-- For the deployed source read the migration, or re-export this file with
-- query (C) in REFRESH.md.
--
--   place_order               → 007 (server-computed delivery charge and prices,
--                                    caller check, quantity validation, 3-day
--                                    buffer, payment_pending for online orders)
--   create_subscription (6+7) → 007 (unit_price read from product_variants)
--   update_wallet_balance     → 007 (authorization wrapper around
--                                    internal.apply_wallet_delta; the 5-arg
--                                    overload was DROPPED because it made
--                                    5-argument calls ambiguous)
--   finalize_daily_run        → 009 (requires daily_ops:edit) [in 002/004]
--   upsert_pauses             → 009 (subscription ownership check)
--   remove_paused_dates       → 009 (subscription ownership check)
--   claim_adhoc_user          → 009 (matches on the JWT's verified identity)
--   update_address_as_default → 011 (ownership check + correct columns)
--
-- NEW functions, not in this file at all:
--   public   : quote_cart, create_payment_intent, attach_razorpay_order,
--              finalize_wallet_topup, finalize_order_payment,
--              mark_payment_intent_failed
--   internal : (schema NOT exposed to PostgREST) jwt_role, is_service_actor,
--              is_admin_actor, apply_wallet_delta, normalize_cart,
--              compute_delivery_charge, place_order_core,
--              create_subscription_core, assert_subscription_access,
--              guard_subscription_update, money_checks_disabled,
--              assert_order_totals, assert_daily_order_total, snap_order_item,
--              snap_subscription_item
--
-- ⚠ KNOWN ISSUES found at sync time (2026-06-01) — current status:
--
--   1. cancel_subscription (non-immediate / scheduled branch) writes
--      `scheduled_end_date` and `cancellation_requested_at`, which are NOT
--      columns on `subscriptions`. Scheduled cancellations will fail.
--      → STILL OPEN.
--   2. get_user_role selects `admin_users.auth_user_id`; the column is
--      `user_id`. Function will error (appears unused — has_permission /
--      is_super_admin are the live RBAC helpers and use `user_id` correctly).
--      → STILL BROKEN, but EXECUTE was revoked from anon/authenticated in 011.
--   3. update_address_as_default writes `addresses.phone` (column is
--      `phone_number`) and `addresses.updated_at` (no such column). The Flutter
--      app's non-atomic fallback may be masking this failure.
--      → FIXED in migration 011, which also added the missing ownership check.
--
-- ⚠ create_subscription has TWO overloads (6-arg legacy + 7-arg current).
--   The legacy 6-arg version still CANCELS existing active subscriptions and
--   has no label / no 5-sub limit. The 7-arg version (p_label) enforces the
--   max-5 rule and does not cancel. Prefer the 7-arg version everywhere.
--   Since 007 both read prices from the catalog.
--
-- ℹ Order numbers are 'ORD-<YYYYMMDDHH24MISS>-<nnnn>' since migration 007 (the
--   random suffix prevents same-second collisions); place_order RETURNS the
--   order UUID (as text). (Not 'HET-' as some older comments/logs state.)
-- =============================================================================


-- cancel_subscription -------------------------------------------------------
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


-- claim_adhoc_user  [SUPERSEDED → migration 009: matches on the JWT's verified
--                    email/phone; the version below trusted the request body,
--                    so a caller could claim another person's ad-hoc account]
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.claim_adhoc_user(p_auth_uid uuid, p_email text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_first_name text DEFAULT NULL::text, p_last_name text DEFAULT NULL::text)
 RETURNS users
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_user        public.users;
  v_adhoc_match public.users;
  v_collision   UUID;
  v_email       TEXT := NULLIF(p_email, '');
  v_phone       TEXT := NULLIF(p_phone, '');
  v_first_name  TEXT := NULLIF(p_first_name, '');
  v_last_name   TEXT := NULLIF(p_last_name, '');
BEGIN
  IF p_auth_uid IS NULL THEN
    RAISE EXCEPTION 'p_auth_uid is required';
  END IF;

  -- 1. Returning user — already linked to this auth identity.
  SELECT * INTO v_user FROM public.users WHERE id = p_auth_uid LIMIT 1;
  IF FOUND THEN
    RETURN v_user;
  END IF;

  -- 2. Try to claim an ad-hoc row by email or phone.
  IF v_email IS NOT NULL OR v_phone IS NOT NULL THEN
    SELECT * INTO v_adhoc_match
    FROM public.users
    WHERE is_adhoc = TRUE
      AND (
        (v_email IS NOT NULL AND email = v_email) OR
        (v_phone IS NOT NULL AND phone = v_phone)
      )
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
      UPDATE public.users
      SET
        id         = p_auth_uid,
        is_adhoc   = FALSE,
        email      = COALESCE(v_email, email),
        phone      = COALESCE(v_phone, phone),
        first_name = COALESCE(v_first_name, first_name),
        last_name  = COALESCE(v_last_name, last_name),
        updated_at = NOW()
      WHERE id = v_adhoc_match.id
      RETURNING * INTO v_user;

      RETURN v_user;
    END IF;

    -- 3. Detect a collision against an already-registered (non-ad-hoc) row.
    SELECT id INTO v_collision
    FROM public.users
    WHERE is_adhoc = FALSE
      AND id <> p_auth_uid
      AND (
        (v_email IS NOT NULL AND email = v_email) OR
        (v_phone IS NOT NULL AND phone = v_phone)
      )
    LIMIT 1;

    IF v_collision IS NOT NULL THEN
      RAISE EXCEPTION 'Another account already exists with this email or phone'
        USING ERRCODE = 'unique_violation';
    END IF;
  END IF;

  -- 4. No row with this auth id, no claimable ad-hoc → insert fresh.
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


-- create_subscription — BOTH OVERLOADS BELOW ARE [SUPERSEDED → migration 007]:
-- they take `unit_price` from the CLIENT payload, which the daily run sheet then
-- bills against. The current versions read product_variants and enforce the
-- 3-day wallet buffer.
-- ---------------------------------------------------------------------------

-- create_subscription (6-arg, LEGACY — cancels active subs, no label/limit) -
CREATE OR REPLACE FUNCTION public.create_subscription(p_user_id uuid, p_start_date timestamp with time zone, p_end_date timestamp with time zone, p_status text, p_address jsonb, p_items jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_sub_id UUID;
  item JSONB;
  v_pincode TEXT;
  v_area_id UUID;
  v_delivery_area TEXT;
  v_delivery_frequency BIGINT;
BEGIN
  v_pincode := p_address->>'pincode';

  IF v_pincode IS NOT NULL THEN
    SELECT area_id INTO v_area_id FROM public.pincodes WHERE pincode = v_pincode LIMIT 1;
    IF v_area_id IS NOT NULL THEN
      SELECT display_name, delivary_frequency
      INTO v_delivery_area, v_delivery_frequency
      FROM public.delivery_areas WHERE id = v_area_id LIMIT 1;
    END IF;
  END IF;

  -- LEGACY behaviour: cancel any currently active subscription first.
  UPDATE public.subscriptions
  SET status = 'cancelled', cancelled_at = NOW(), end_date = NOW(),
      cancellation_type = 'replaced',
      cancellation_reason = 'Replaced by new subscription',
      is_custom_cancel_date = false
  WHERE user_id = p_user_id AND status = 'active';

  INSERT INTO public.subscriptions (
    user_id, start_date, end_date, status,
    snapshot_name, snapshot_phone, snapshot_address_line1, snapshot_address_line2,
    snapshot_landmark, snapshot_city, snapshot_state, snapshot_pincode,
    snapshot_address_type, delivary_area, delivary_frequency, created_at
  ) VALUES (
    p_user_id, p_start_date, p_end_date, p_status,
    p_address->>'name', p_address->>'phoneNumber', p_address->>'addressLine1', p_address->>'addressLine2',
    p_address->>'landmark', p_address->>'city', p_address->>'state', p_address->>'pincode',
    p_address->>'addressType', v_delivery_area, v_delivery_frequency, NOW()
  ) RETURNING id INTO v_sub_id;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    INSERT INTO public.subscription_items (
      subscription_id, variant_id, product_name_snapshot, variant_label_snapshot,
      unit_price, quantity, item_start_date
    ) VALUES (
      v_sub_id, (item->>'variantId')::UUID, item->>'name', item->>'variant',
      (item->>'price')::NUMERIC, (item->>'quantity')::INTEGER,
      (item->>'startDate')::TIMESTAMP WITH TIME ZONE
    );
  END LOOP;

  RETURN v_sub_id;
END;
$function$;


-- create_subscription (7-arg, CURRENT — max 5 active, label, no auto-cancel) -
CREATE OR REPLACE FUNCTION public.create_subscription(p_user_id uuid, p_start_date timestamp with time zone, p_end_date timestamp with time zone, p_status text, p_address jsonb, p_items jsonb, p_label text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_sub_id UUID;
  item JSONB;
  v_pincode TEXT;
  v_area_id UUID;
  v_delivery_area TEXT;
  v_delivery_frequency BIGINT;
  v_active_count INTEGER;
  v_max_subscriptions INTEGER := 5;
BEGIN
  SELECT COUNT(*) INTO v_active_count
  FROM public.subscriptions
  WHERE user_id = p_user_id AND status IN ('active', 'pending_cancellation');

  IF v_active_count >= v_max_subscriptions THEN
    RAISE EXCEPTION 'Maximum subscription limit (%) reached', v_max_subscriptions;
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
    COALESCE(p_label, 'Subscription ' || (v_active_count + 1)::TEXT),
    p_address->>'name', p_address->>'phoneNumber', p_address->>'addressLine1', p_address->>'addressLine2',
    p_address->>'landmark', p_address->>'city', p_address->>'state', p_address->>'pincode',
    p_address->>'addressType', v_delivery_area, v_delivery_frequency, NOW()
  ) RETURNING id INTO v_sub_id;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    INSERT INTO public.subscription_items (
      subscription_id, variant_id, product_name_snapshot, variant_label_snapshot,
      unit_price, quantity, item_start_date
    ) VALUES (
      v_sub_id, (item->>'variantId')::UUID, item->>'name', item->>'variant',
      (item->>'price')::NUMERIC, (item->>'quantity')::INTEGER,
      (item->>'startDate')::TIMESTAMP WITH TIME ZONE
    );
  END LOOP;

  RETURN v_sub_id;
END;
$function$;


-- get_user_daily_commitment -------------------------------------------------
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


-- get_user_role (⚠ references admin_users.auth_user_id — column is user_id) --
CREATE OR REPLACE FUNCTION public.get_user_role(uid uuid)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT role
  FROM admin_users
  WHERE auth_user_id = uid                              -- ⚠ column is user_id
  LIMIT 1;
$function$;


-- has_permission (RBAC helper used by RLS policies) -------------------------
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


-- place_order  [SUPERSEDED → migration 007: the version below TRUSTS
--               p_delivery_charge from the client (0 or negative accepted) and
--               validates neither the caller, the quantities, nor variant
--               availability]
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.place_order(p_user_id uuid, p_address_id uuid, p_payment_method text, p_delivery_charge numeric, p_cart_items jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_order_id UUID;
    v_order_number TEXT;
    v_subtotal NUMERIC := 0;
    v_total NUMERIC := 0;
    v_item JSONB;
    v_variant RECORD;
    v_address RECORD;
    v_wallet_balance NUMERIC;
BEGIN
    v_order_number := 'ORD-' || to_char(CURRENT_TIMESTAMP, 'YYYYMMDDHH24MISS');

    SELECT * INTO v_address FROM addresses WHERE id = p_address_id AND user_id = p_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Address not found or doesn''t belong to user';
    END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_cart_items)
    LOOP
        SELECT * INTO v_variant FROM product_variants WHERE id = (v_item->>'variant_id')::UUID FOR UPDATE;
        IF NOT FOUND THEN
             RAISE EXCEPTION 'Variant % not found', (v_item->>'variant_id');
        END IF;
        v_subtotal := v_subtotal + (v_variant.price * (v_item->>'quantity')::INT);
    END LOOP;

    v_total := v_subtotal + p_delivery_charge;

    IF p_payment_method = 'wallet' THEN
       SELECT wallet_balance INTO v_wallet_balance FROM users WHERE id = p_user_id FOR UPDATE;
       IF v_wallet_balance < v_total THEN
          RAISE EXCEPTION 'Insufficient Wallet Balance! Required: %, Available: %', v_total, v_wallet_balance;
       END IF;
       UPDATE users SET wallet_balance = wallet_balance - v_total WHERE id = p_user_id;
       INSERT INTO wallet_transactions (user_id, type, amount, balance_after, description, reference_type)
       VALUES (p_user_id, 'debit', v_total, v_wallet_balance - v_total, 'Order ' || v_order_number || ' checkout', 'order');
    END IF;

    INSERT INTO orders (
        order_number, user_id, address_snapshot_id, status, payment_method, payment_status,
        subtotal, delivery_charge, total,
        snapshot_name, snapshot_phone, snapshot_address_line1, snapshot_city, snapshot_state, snapshot_pincode, snapshot_address_type
    ) VALUES (
        v_order_number, p_user_id, p_address_id, 'placed', p_payment_method,
        CASE WHEN p_payment_method = 'wallet' THEN 'paid' ELSE 'pending' END,
        v_subtotal, p_delivery_charge, v_total,
        v_address.name, v_address.phone_number, v_address.address_line1, v_address.city, v_address.state, v_address.pincode, v_address.address_type
    ) RETURNING id INTO v_order_id;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_cart_items)
    LOOP
        SELECT pv.price, pv.label as variant_label, p.name as product_name, p.id as product_id
        INTO v_variant
        FROM product_variants pv
        JOIN products p ON p.id = pv.product_id
        WHERE pv.id = (v_item->>'variant_id')::UUID;

        INSERT INTO order_items (
            order_id, variant_id, product_name_snapshot, variant_label_snapshot, unit_price, quantity, total_price
        ) VALUES (
            v_order_id, (v_item->>'variant_id')::UUID, v_variant.product_name, v_variant.variant_label, v_variant.price, (v_item->>'quantity')::INT, v_variant.price * (v_item->>'quantity')::INT
        );
    END LOOP;

    INSERT INTO order_tracking (order_id, status) VALUES (v_order_id, 'placed');

    RETURN v_order_id::TEXT;
END;
$function$;


-- remove_paused_dates  [SUPERSEDED → migration 009: ownership check added; the
--                       version below accepts any subscription id]
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.remove_paused_dates(p_subscription_id uuid, p_dates jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  date_val DATE;
  row_rec RECORD;
BEGIN
  FOR date_val IN SELECT (jsonb_array_elements_text(p_dates))::DATE
  LOOP
    FOR row_rec IN
      SELECT id, pause_start_date, pause_end_date
      FROM subscription_pauses
      WHERE subscription_id = p_subscription_id
        AND pause_start_date <= date_val
        AND pause_end_date >= date_val
    LOOP
      DELETE FROM subscription_pauses WHERE id = row_rec.id;

      IF row_rec.pause_start_date < date_val THEN
        INSERT INTO subscription_pauses (subscription_id, pause_start_date, pause_end_date, created_by)
        VALUES (p_subscription_id, row_rec.pause_start_date, date_val - 1, 'user');
      END IF;

      IF row_rec.pause_end_date > date_val THEN
        INSERT INTO subscription_pauses (subscription_id, pause_start_date, pause_end_date, created_by)
        VALUES (p_subscription_id, date_val + 1, row_rec.pause_end_date, 'user');
      END IF;
    END LOOP;
  END LOOP;
END;
$function$;


-- rls_auto_enable (event trigger fn: auto-enables RLS on new public tables) -
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


-- update_address_as_default  [SUPERSEDED → migration 011: correct columns
--                             (phone_number, no updated_at) plus the missing
--                             ownership check — it is SECURITY DEFINER and
--                             trusted p_user_id]
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_address_as_default(p_user_id uuid, p_address_id uuid, p_address_data jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  UPDATE addresses
  SET is_default = false
  WHERE user_id = p_user_id AND is_default = true;

  UPDATE addresses
  SET
    address_line1 = COALESCE(p_address_data->>'address_line1', address_line1),
    address_line2 = COALESCE(p_address_data->>'address_line2', address_line2),
    city = COALESCE(p_address_data->>'city', city),
    state = COALESCE(p_address_data->>'state', state),
    pincode = COALESCE(p_address_data->>'pincode', pincode),
    landmark = COALESCE(p_address_data->>'landmark', landmark),
    phone = COALESCE(p_address_data->>'phone', phone),  -- ⚠ column is phone_number
    address_type = COALESCE(p_address_data->>'address_type', address_type),
    is_default = true,
    updated_at = NOW()                                  -- ⚠ column does not exist
  WHERE id = p_address_id AND user_id = p_user_id;
END;
$function$;


-- update_wallet_balance  [SUPERSEDED → migration 007: now an authorization
--                         wrapper (service role / super admin / customers:edit)
--                         around internal.apply_wallet_delta. THIS 5-ARG
--                         OVERLOAD WAS DROPPED — with the 7-arg version present
--                         it made 5-argument calls ambiguous. Before the fix,
--                         EXECUTE was granted to PUBLIC, so any logged-in user
--                         could credit their own wallet]
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_wallet_balance(p_user_id uuid, p_amount numeric, p_type text, p_description text, p_initiated_by text)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_current_balance NUMERIC;
  v_new_balance NUMERIC;
BEGIN
  SELECT wallet_balance INTO v_current_balance
  FROM public.users WHERE id = p_user_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'User not found';
  END IF;

  IF p_type = 'credit' THEN
    v_new_balance := v_current_balance + p_amount;
  ELSIF p_type = 'debit' THEN
    IF v_current_balance < p_amount THEN
      RAISE EXCEPTION 'Insufficient balance. Current balance is %', v_current_balance;
    END IF;
    v_new_balance := v_current_balance - p_amount;
  ELSE
    RAISE EXCEPTION 'Invalid transaction type. Must be "credit" or "debit"';
  END IF;

  UPDATE public.users
  SET wallet_balance = v_new_balance, updated_at = now()
  WHERE id = p_user_id;

  INSERT INTO public.wallet_transactions (
    user_id, type, amount, balance_after, description, initiated_by
  ) VALUES (
    p_user_id, p_type, p_amount, v_new_balance, p_description, p_initiated_by
  );

  RETURN v_new_balance;
END;
$function$;


-- upsert_pauses  [SUPERSEDED → migration 009: ownership check added; the version
--                 below accepts any subscription id]
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.upsert_pauses(p_subscription_id uuid, p_ranges jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  r JSONB;
  new_start DATE;
  new_end DATE;
  merged_start DATE;
  merged_end DATE;
  overlap_ids UUID[];
  row_rec RECORD;
BEGIN
  FOR r IN SELECT * FROM jsonb_array_elements(p_ranges)
  LOOP
    new_start := (r->>'start')::DATE;
    new_end := (r->>'end')::DATE;

    SELECT array_agg(id),
           LEAST(MIN(pause_start_date), new_start),
           GREATEST(MAX(pause_end_date), new_end)
    INTO overlap_ids, merged_start, merged_end
    FROM subscription_pauses
    WHERE subscription_id = p_subscription_id
      AND pause_start_date <= (new_end + INTERVAL '1 day')::DATE
      AND pause_end_date >= (new_start - INTERVAL '1 day')::DATE;

    IF overlap_ids IS NOT NULL THEN
      DELETE FROM subscription_pauses WHERE id = ANY(overlap_ids);
    ELSE
      merged_start := new_start;
      merged_end := new_end;
    END IF;

    INSERT INTO subscription_pauses (subscription_id, pause_start_date, pause_end_date, created_by)
    VALUES (p_subscription_id, merged_start, merged_end, 'user');
  END LOOP;
END;
$function$;
