-- =============================================================================
-- Migration 009 — PRIVILEGE LOCKDOWN
-- =============================================================================
-- Run in: Supabase SQL Editor, AFTER 007 and 008.
--
-- WHAT THIS FIXES (all of these were reachable with nothing but the app's anon
-- key plus a normal customer login — no admin credentials needed):
--
--   1. users.wallet_balance was directly writable by the row owner:
--        supabase.from('users').update({ wallet_balance: 999999 }).eq('id', myId)
--      RLS ("user info update" / users_update_policy) permits own-row UPDATE and
--      there were no column-level grants, so the wallet was client-writable.
--   2. subscription_items INSERT/UPDATE was allowed for the subscription owner,
--      so a customer could set unit_price = 0.01 on their own subscription. The
--      daily run sheet bills off that column.
--   3. orders INSERT was allowed for user_id = auth.uid(), so a customer could
--      hand-write an order row with total = 0 and payment_status = 'paid'.
--   4. finalize_daily_run is SECURITY DEFINER and was executable by PUBLIC —
--      any logged-in customer could finalize the whole day's run and trigger
--      every customer's wallet deduction.
--   5. upsert_pauses / remove_paused_dates are SECURITY DEFINER and took only a
--      subscription id, with no ownership check.
--   6. claim_adhoc_user matched ad-hoc accounts on client-supplied email/phone,
--      so a caller could claim someone else's ad-hoc row (and its wallet).
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. users.wallet_balance — no longer writable over the API
-- ---------------------------------------------------------------------------
-- NOTE: in PostgreSQL a table-level UPDATE grant covers every column, and a
-- column-level REVOKE cannot carve a hole in it. The table-level grant must be
-- dropped first, then re-granted per column.
REVOKE UPDATE ON public.users FROM anon, authenticated;

GRANT UPDATE (
  email,
  phone,
  first_name,
  last_name,
  area,
  pincode,
  notifications_enabled,
  dark_mode,
  language,
  updated_at,
  is_adhoc
) ON public.users TO authenticated;

-- wallet_balance now changes only through internal.apply_wallet_delta(), which
-- runs as the table owner inside SECURITY DEFINER functions and always writes a
-- matching wallet_transactions ledger row.


-- ---------------------------------------------------------------------------
-- 2. subscription_items — customers may read, never write
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "subscription_items_insert_policy" ON public.subscription_items;
DROP POLICY IF EXISTS "subscription_items_update_policy" ON public.subscription_items;
DROP POLICY IF EXISTS "subscription_items_delete_policy" ON public.subscription_items;

CREATE POLICY "subscription_items_insert_policy"
  ON public.subscription_items FOR INSERT TO public
  WITH CHECK (is_super_admin() OR has_permission('subscriptions:edit'));

CREATE POLICY "subscription_items_update_policy"
  ON public.subscription_items FOR UPDATE TO public
  USING (is_super_admin() OR has_permission('subscriptions:edit'))
  WITH CHECK (is_super_admin() OR has_permission('subscriptions:edit'));

CREATE POLICY "subscription_items_delete_policy"
  ON public.subscription_items FOR DELETE TO public
  USING (is_super_admin() OR has_permission('subscriptions:edit'));

-- create_subscription() is SECURITY DEFINER and owned by the table owner, so it
-- still inserts items; it just no longer accepts a client price.


-- ---------------------------------------------------------------------------
-- 3. orders — customers may read, never insert
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "orders_create_policy" ON public.orders;

CREATE POLICY "orders_create_policy"
  ON public.orders FOR INSERT TO public
  WITH CHECK (is_super_admin() OR has_permission('orders:edit'));

-- All customer orders now go through place_order() / finalize_order_payment().


-- ---------------------------------------------------------------------------
-- 4. subscriptions — customers may not change billing-relevant columns
-- ---------------------------------------------------------------------------
-- RLS still lets a customer update their own subscription (pause/cancel flows
-- in Hetha_app do that), but they must not be able to move it to another user
-- or flip payment_method to avoid wallet deductions.
CREATE OR REPLACE FUNCTION internal.guard_subscription_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, internal
AS $$
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
$$;

DROP TRIGGER IF EXISTS trg_guard_subscription_update ON public.subscriptions;
CREATE TRIGGER trg_guard_subscription_update
  BEFORE UPDATE ON public.subscriptions
  FOR EACH ROW EXECUTE FUNCTION internal.guard_subscription_update();


-- ---------------------------------------------------------------------------
-- 5. finalize_daily_run — permission-gated, uses the internal wallet primitive
-- ---------------------------------------------------------------------------
-- Body is migration 004's, with (a) an authorization guard and (b) the wallet
-- call switched to internal.apply_wallet_delta so that a `daily_ops:edit` admin
-- does not additionally need `customers:edit` (which the public
-- update_wallet_balance wrapper now requires).
CREATE OR REPLACE FUNCTION public.finalize_daily_run(
  p_delivery_date date,
  p_admin_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, internal
AS $$
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
$$;


-- ---------------------------------------------------------------------------
-- 6. Pause RPCs — ownership checks
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION internal.assert_subscription_access(p_subscription_id uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, internal
AS $$
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
$$;

CREATE OR REPLACE FUNCTION public.upsert_pauses(p_subscription_id uuid, p_ranges jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, internal
AS $$
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
$$;

CREATE OR REPLACE FUNCTION public.remove_paused_dates(p_subscription_id uuid, p_dates jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, internal
AS $$
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
$$;


-- ---------------------------------------------------------------------------
-- 7. claim_adhoc_user — match on VERIFIED identity from the JWT
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.claim_adhoc_user(
  p_auth_uid   uuid,
  p_email      text DEFAULT NULL,
  p_phone      text DEFAULT NULL,
  p_first_name text DEFAULT NULL,
  p_last_name  text DEFAULT NULL
) RETURNS public.users
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, internal
AS $$
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
$$;


-- ---------------------------------------------------------------------------
-- 8. EXECUTE grants — drop the implicit PUBLIC grants Postgres adds
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.update_wallet_balance(uuid, numeric, text, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.finalize_daily_run(date, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.place_order(uuid, uuid, text, numeric, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_subscription(uuid, timestamptz, timestamptz, text, jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_subscription(uuid, timestamptz, timestamptz, text, jsonb, jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quote_cart(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.upsert_pauses(uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.remove_paused_dates(uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.claim_adhoc_user(uuid, text, text, text, text) FROM PUBLIC;

-- The admin panel calls these with the signed-in admin's session (role
-- `authenticated`); the in-function guards decide what that admin may do.
GRANT EXECUTE ON FUNCTION public.update_wallet_balance(uuid, numeric, text, text, text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.finalize_daily_run(date, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.place_order(uuid, uuid, text, numeric, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_subscription(uuid, timestamptz, timestamptz, text, jsonb, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_subscription(uuid, timestamptz, timestamptz, text, jsonb, jsonb, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.quote_cart(jsonb) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.upsert_pauses(uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.remove_paused_dates(uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.claim_adhoc_user(uuid, text, text, text, text) TO authenticated, service_role;

-- Sanity checks (run manually, expect 0 rows / expected values):
--   SELECT has_column_privilege('authenticated', 'public.users', 'wallet_balance', 'UPDATE');  -- false
--   SELECT has_function_privilege('anon', 'public.place_order(uuid,uuid,text,numeric,jsonb)', 'EXECUTE'); -- false
