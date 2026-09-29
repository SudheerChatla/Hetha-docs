-- Migration 025: Fix the day-edit wallet rule and scope day edits per subscription
--
-- Run in: Supabase SQL Editor (the whole file; it is wrapped in one transaction)
--
-- Replaces internal.modify_daily_order_core (migration 022). The public
-- modify_daily_order / revert_daily_order wrappers are unchanged.
--
-- ─── Fix 1: wallet rule for a more expensive day ────────────────────────────
-- 022 required, for an edit that raises a day's cost:
--
--     wallet >= 3 × (the whole edited day)
--
-- e.g. a ₹11,650 day needed ₹34,950 in the wallet, although the extra spend
-- happens once. It also compared the edited day (ONE subscription) against the
-- customer's commitment across ALL subscriptions, so a customer with several
-- subscriptions could raise one subscription's day without any check.
--
-- New rule — the normal 3-day buffer must stay intact after paying the one-off
-- extra for this day:
--
--     extra    = edited day cost − this subscription's normal daily cost
--     required = 3 × (normal daily commitment, all subscriptions) + extra
--
-- Checked only when extra > 0, so trimming a day is always allowed. Admins
-- still bypass. Same numbers as the 3-day rule in place_order and
-- create_subscription (get_user_daily_commitment).
--
-- ─── Fix 2: day edits touch only this subscription's order ──────────────────
-- 022 looked up and DELETED existing orders by (user_id, delivery_date). A
-- customer may have up to 5 subscriptions, so saving an edit for one
-- subscription's day silently deleted every other subscription's order for
-- that date. The lookup and the delete are now scoped to
-- (subscription_id, delivery_date).

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

  -- Wallet rule (migration 025): the normal 3-day buffer must survive paying
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

      v_committed := COALESCE(public.get_user_daily_commitment(p_user_id), 0);
      v_required  := round(v_committed * 3 + v_extra, 2);

      IF v_wallet_balance < v_required THEN
        RAISE EXCEPTION
          'Insufficient wallet balance (%). You need at least % (3 days of your subscriptions, %/day, plus % extra for this day).',
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

REVOKE ALL ON FUNCTION internal.modify_daily_order_core(uuid, uuid, date, jsonb, boolean) FROM PUBLIC, anon;

COMMIT;
