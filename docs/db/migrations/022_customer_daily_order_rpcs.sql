-- Migration 022: Customer daily-order modification RPCs
--
-- Run in: Supabase SQL Editor
--
-- ─── Problem ────────────────────────────────────────────────────────────────
-- The customer app let a subscriber edit a single day's delivery ("Order for
-- Saturday …") by writing subscription_daily_orders / _items DIRECTLY from the
-- client (SubscriptionService.saveDailyOrder). Migration 009 locked those
-- tables down to admins only (is_super_admin / daily_ops:edit / subscriptions:
-- edit), so every customer edit now fails with:
--     new row violates row-level security policy for table
--     "subscription_daily_orders" (SQLSTATE 42501)
-- The lockdown is correct: unit_price / total_value are the columns the daily
-- run sheet bills against — a client must never write them. The fix is the same
-- pattern used by place_order / create_subscription: a SECURITY DEFINER RPC that
-- verifies ownership, prices server-side from the catalog, and writes the rows.
--
-- ─── What this migration adds ────────────────────────────────────────────────
--   1. subscription_daily_orders.is_customer_modified  (new boolean column)
--        Marks a day's order as "the customer hand-edited this day". The run-
--        sheet generator (services/dailyOps/generateRunSheet.ts) must PRESERVE
--        these rows during its smart-sync instead of deleting+regenerating them
--        from the subscription template. See the companion generator change.
--   2. internal.modify_daily_order_core(...)   the shared body
--   3. public.modify_daily_order(...)          customer/admin entry point
--   4. public.revert_daily_order(...)          "Reset to Default" entry point
--   5. grants                                   authenticated + service_role only
--
-- ─── Design notes ────────────────────────────────────────────────────────────
--   • Server-side pricing: the client sends only {variant_id, quantity} pairs.
--     unit_price / product_name / variant_label come from product_variants via
--     internal.normalize_cart — any client "price" is ignored (money integrity).
--   • Ownership: internal.assert_subscription_access(subscription_id) allows the
--     subscription owner OR a subscriptions:edit admin; everyone else is refused.
--   • Buffer rule: modifying a day cannot spend below the 3-day wallet buffer.
--     We reuse get_user_daily_commitment for the baseline and only guard when
--     the modified day costs MORE than the current committed daily amount.
--   • Atomicity: the whole replace runs in the RPC's implicit transaction, so
--     the deferred trg_daily_order_total invariant (total_value = Σ items) is
--     checked once at COMMIT with a consistent parent+items set.
--   • We refuse to touch a finalized / delivered / already-billed day.

-- ─── 1. Schema: preservation marker ──────────────────────────────────────────
ALTER TABLE public.subscription_daily_orders
  ADD COLUMN IF NOT EXISTS is_customer_modified boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.subscription_daily_orders.is_customer_modified IS
  'True when a subscriber hand-edited this day via public.modify_daily_order. '
  'The run-sheet generator preserves these rows instead of regenerating them '
  'from the subscription template.';

-- ─── 2. internal.modify_daily_order_core ─────────────────────────────────────
-- Replace-in-place: delete any existing PENDING order for (user, date) and write
-- a fresh one with the supplied lines, priced from the catalog. Returns the new
-- daily_order id.
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
  v_existing_daily   numeric := 0;
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

  -- Refuse to touch a day that is already locked / billed / delivered.
  SELECT status, is_finalized, payment_status
  INTO v_existing_status, v_existing_final, v_existing_pay
  FROM public.subscription_daily_orders
  WHERE user_id = p_user_id AND delivery_date = p_delivery_date
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

  -- 3-day wallet buffer. Only guard when the edit INCREASES the day's cost
  -- beyond the customer's current committed daily amount, so trimming a day is
  -- always allowed. Admins bypass the buffer.
  IF NOT p_is_admin THEN
    v_committed := COALESCE(public.get_user_daily_commitment(p_user_id), 0);

    IF v_new_daily > v_committed THEN
      SELECT COALESCE(wallet_balance, 0) INTO v_wallet_balance
      FROM public.users WHERE id = p_user_id;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found';
      END IF;

      -- Extra spend over baseline must still leave a 3-day buffer.
      v_existing_daily := v_committed;
      v_required := round((v_existing_daily + (v_new_daily - v_committed)) * 3, 2);

      IF v_wallet_balance < v_required THEN
        RAISE EXCEPTION
          'Insufficient wallet balance (%). You need at least % (3-day buffer for a %/day delivery).',
          v_wallet_balance, v_required, round(v_new_daily, 2);
      END IF;
    END IF;
  END IF;

  -- Replace any existing pending order for this (user, date). Items cascade via
  -- the explicit delete below (schema has no ON DELETE CASCADE on the FK).
  DELETE FROM public.subscription_daily_order_items
  WHERE daily_order_id IN (
    SELECT id FROM public.subscription_daily_orders
    WHERE user_id = p_user_id AND delivery_date = p_delivery_date
  );

  DELETE FROM public.subscription_daily_orders
  WHERE user_id = p_user_id AND delivery_date = p_delivery_date;

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

-- ─── 3. public.modify_daily_order ────────────────────────────────────────────
-- Customer/admin entry point. Client sends variant_id + quantity pairs only.
CREATE OR REPLACE FUNCTION public.modify_daily_order(
  p_user_id         uuid,
  p_subscription_id uuid,
  p_delivery_date   date,
  p_items           jsonb
)
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
      RAISE EXCEPTION 'Not authorized to modify orders for this user';
    END IF;
  END IF;

  RETURN internal.modify_daily_order_core(
    p_user_id, p_subscription_id, p_delivery_date, p_items, v_is_admin
  );
END;
$function$;

-- ─── 4. public.revert_daily_order ────────────────────────────────────────────
-- "Reset to Default": drop the customer-modified pending order for a date so the
-- run-sheet generator regenerates it from the subscription template. No-op if
-- there is nothing to revert. Never touches a finalized / non-pending / paid day.
CREATE OR REPLACE FUNCTION public.revert_daily_order(
  p_user_id       uuid,
  p_delivery_date date
)
 RETURNS void
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

  DELETE FROM public.subscription_daily_order_items
  WHERE daily_order_id IN (
    SELECT id FROM public.subscription_daily_orders
    WHERE user_id = p_user_id
      AND delivery_date = p_delivery_date
      AND status = 'pending'
      AND is_finalized = false
      AND payment_status <> 'paid'
  );

  DELETE FROM public.subscription_daily_orders
  WHERE user_id = p_user_id
    AND delivery_date = p_delivery_date
    AND status = 'pending'
    AND is_finalized = false
    AND payment_status <> 'paid';
END;
$function$;

-- ─── 5. Grants ───────────────────────────────────────────────────────────────
-- Signed-in callers only. The internal core is never exposed over the API.
REVOKE ALL ON FUNCTION internal.modify_daily_order_core(uuid, uuid, date, jsonb, boolean) FROM PUBLIC, anon;

REVOKE ALL ON FUNCTION public.modify_daily_order(uuid, uuid, date, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.revert_daily_order(uuid, date)              FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.modify_daily_order(uuid, uuid, date, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.revert_daily_order(uuid, date)              TO authenticated, service_role;
