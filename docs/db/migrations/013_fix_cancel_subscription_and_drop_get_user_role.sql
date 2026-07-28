-- =============================================================================
-- Migration 013 — fix scheduled cancel_subscription; drop dead get_user_role
-- =============================================================================
-- Run in: Supabase SQL Editor, AFTER 012_money_invariants.sql.
--
-- Two pre-existing bugs, unrelated to the money work, confirmed by the
-- 2026-07-28 function export.
--
-- ---------------------------------------------------------------------------
-- 1. cancel_subscription — scheduled branch wrote non-existent columns
-- ---------------------------------------------------------------------------
--   The ELSE (non-immediate) branch set `scheduled_end_date` and
--   `cancellation_requested_at`, neither of which is a column on
--   public.subscriptions. Every scheduled cancellation therefore threw
--   `column "scheduled_end_date" does not exist` and rolled back — the
--   subscription was never moved to pending_cancellation.
--
--   The rest of the system already treats `end_date` as the scheduled cutoff:
--     • SubscriptionStatusManager.processScheduledCancellations() (Hetha_app)
--       finds rows WHERE status = 'pending_cancellation' AND end_date <= today
--       and transitions them to 'cancelled'.
--     • The daily run-sheet generator stops generating past `end_date`.
--   So the fix is to write `end_date` (not `scheduled_end_date`) and to drop the
--   `cancellation_requested_at` write, which has no column to land in.
--   `cancelled_at` stays NULL until the row is actually cancelled — the same
--   contract the immediate branch and the status manager already use.
--
--   (No schema change. If you ever want an audit trail of WHEN a cancellation
--   was requested, add a real `cancellation_requested_at timestamptz` column in
--   a separate migration and set it here — but that is not required to fix the
--   bug.)

CREATE OR REPLACE FUNCTION public.cancel_subscription(
  p_subscription_id uuid,
  p_user_id uuid,
  p_end_date timestamp with time zone,
  p_is_immediate boolean,
  p_cancellation_type text,
  p_reason text DEFAULT NULL::text
) RETURNS void
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
    -- Scheduled: park in pending_cancellation with the cutoff in end_date.
    -- processScheduledCancellations() flips it to 'cancelled' once end_date
    -- passes.
    UPDATE public.subscriptions
    SET status = 'pending_cancellation',
        end_date = p_end_date,                           -- was scheduled_end_date (no such column)
        cancellation_type = p_cancellation_type,
        cancellation_reason = p_reason,
        is_custom_cancel_date = (p_cancellation_type = 'custom')
        -- cancellation_requested_at removed (no such column); cancelled_at stays
        -- NULL until the row is actually cancelled.
    WHERE id = p_subscription_id AND user_id = p_user_id;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Subscription not found or does not belong to user';
  END IF;
END;
$function$;


-- ---------------------------------------------------------------------------
-- 2. get_user_role — broken and unused, drop it
-- ---------------------------------------------------------------------------
--   Body: `SELECT role FROM admin_users WHERE auth_user_id = uid`. Neither
--   `role` nor `auth_user_id` exists on admin_users (the columns are `role_id`
--   and `user_id`), so the function errors if ever called. It has no callers in
--   Hetha_app or Hetha_admin — the live RBAC helpers are has_permission() and
--   is_super_admin(), which use the correct columns — and migration 011 already
--   revoked its EXECUTE grants. Remove it so it can't mislead.
DROP FUNCTION IF EXISTS public.get_user_role(uuid);


-- Verification:
--   -- scheduled cancel now works (replace the ids with a real active sub):
--   -- SELECT public.cancel_subscription('<sub>','<user>', now() + interval '7 days',
--   --                                    false, 'scheduled', 'test');
--   -- SELECT status, end_date, cancelled_at FROM subscriptions WHERE id = '<sub>';
--   --   → status = 'pending_cancellation', end_date set, cancelled_at NULL
--
--   -- get_user_role is gone:
--   SELECT to_regprocedure('public.get_user_role(uuid)') IS NULL AS dropped;  -- true
