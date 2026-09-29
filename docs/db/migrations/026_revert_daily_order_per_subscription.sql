-- Migration 026: "Reset to Default" per subscription
--
-- Run in: Supabase SQL Editor (the whole file; it is wrapped in one transaction)
--
-- public.revert_daily_order(p_user_id, p_delivery_date) (migration 022) drops
-- EVERY pending, unfinalized, unpaid daily order the customer has on that date.
-- A customer may have up to 5 subscriptions, so "Reset to Default" on one
-- subscription's day also reset the others' edits for that date.
--
-- Adds a 3-argument overload that takes the subscription and resets only that
-- subscription's order for the date. The 2-argument version is kept unchanged
-- so app builds released before this migration keep working; the current app
-- always calls the 3-argument version. (The two overloads have different
-- argument sets and no defaults, so PostgREST resolves them unambiguously by
-- the parameter names sent.)
--
-- Ownership: the subscription must belong to p_user_id, and a non-staff caller
-- must be that user — same authorization as modify_daily_order.

BEGIN;

CREATE OR REPLACE FUNCTION public.revert_daily_order(
  p_user_id         uuid,
  p_delivery_date   date,
  p_subscription_id uuid
)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_is_admin boolean := internal.is_admin_actor('subscriptions:edit');
  v_owner    uuid;
BEGIN
  IF NOT v_is_admin THEN
    IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
      RAISE EXCEPTION 'Not authorized to modify orders for this user';
    END IF;
  END IF;

  SELECT user_id INTO v_owner FROM public.subscriptions WHERE id = p_subscription_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Subscription not found';
  END IF;
  IF v_owner IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'Subscription does not belong to this user';
  END IF;

  DELETE FROM public.subscription_daily_order_items
  WHERE daily_order_id IN (
    SELECT id FROM public.subscription_daily_orders
    WHERE subscription_id = p_subscription_id
      AND delivery_date = p_delivery_date
      AND status = 'pending'
      AND is_finalized = false
      AND payment_status <> 'paid'
  );

  DELETE FROM public.subscription_daily_orders
  WHERE subscription_id = p_subscription_id
    AND delivery_date = p_delivery_date
    AND status = 'pending'
    AND is_finalized = false
    AND payment_status <> 'paid';
END;
$function$;

REVOKE ALL ON FUNCTION public.revert_daily_order(uuid, date, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.revert_daily_order(uuid, date, uuid) TO authenticated, service_role;

COMMIT;
