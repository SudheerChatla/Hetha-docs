-- Migration 030: cancel_subscription removes that subscription's leftover orders
--
-- Run in: Supabase SQL Editor (the whole file; it is wrapped in one transaction)
--
-- ─── Problem ────────────────────────────────────────────────────────────────
-- After cancel_subscription, the customer app ran
-- SubscriptionService._cleanupFutureDataOnCancellation, which deleted
-- subscription_daily_orders / subscription_pauses directly from the client.
-- Both tables are admin-delete-only under RLS (migration 009), so it always
-- failed silently. (Had it worked it would have been wrong too: it deleted by
-- user_id, wiping every one of the customer's subscriptions, not just the
-- cancelled one.)
--
-- The gap it was meant to close is real: a day the customer edited has
-- is_customer_modified = true, and the run-sheet generator keeps those rows
-- regardless of the subscription's state; finalize_daily_run then bills every
-- pending order on the date. So an edited day AFTER the cancellation would
-- still have been delivered and debited from the wallet.
--
-- ─── Fix ─────────────────────────────────────────────────────────────────────
-- cancel_subscription becomes SECURITY DEFINER (it was SECURITY INVOKER and
-- relied on RLS for ownership) with an explicit check: the caller must be
-- p_user_id, or an admin with subscriptions:edit, or the service role. After
-- updating the subscription it deletes THIS subscription's pending,
-- unfinalized, unpaid daily orders that will no longer be delivered:
--   • immediate cancel  → every such order after today
--   • scheduled cancel  → every such order after end_date (deliveries up to
--                         and including end_date still happen, matching the
--                         run-sheet generator's end-date check)
-- Finalized / delivered / paid days are never touched. Pauses are left alone:
-- after the end date they have no effect, and keeping them means "Revert
-- Cancellation" restores the customer's schedule as it was.
-- Signature and grants are unchanged, so current app builds need no change.

BEGIN;

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
  v_cutoff := CASE WHEN p_is_immediate THEN CURRENT_DATE
                   ELSE COALESCE(p_end_date::date, CURRENT_DATE) END;

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

REVOKE ALL ON FUNCTION public.cancel_subscription(uuid, uuid, timestamptz, boolean, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_subscription(uuid, uuid, timestamptz, boolean, text, text) TO authenticated, service_role;

COMMIT;
