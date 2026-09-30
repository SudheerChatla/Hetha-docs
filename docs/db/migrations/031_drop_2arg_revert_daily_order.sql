-- Migration 031: Drop the 2-argument revert_daily_order
--
-- Run in: Supabase SQL Editor (the whole file; it is wrapped in one transaction)
--
-- revert_daily_order(p_user_id, p_delivery_date) (migration 022) resets EVERY
-- subscription's pending order the customer has on that date. Migration 026
-- added the per-subscription revert_daily_order(p_user_id, p_delivery_date,
-- p_subscription_id) and kept the 2-arg version only for app builds released
-- before it.
--
-- The current app (Hetha_app SubscriptionService.saveDailyOrder /
-- deleteDailyOrder) always sends p_subscription_id, and the admin panel never
-- calls this RPC. Dropping the 2-arg version removes the last way to reset
-- another subscription's day by accident.
--
-- ⚠ Apply only once every customer is on an app build that includes migration
--   026's change (commit 9b42419 or later). An older build's "Reset to
--   Default" would fail with "function ... does not exist" after this runs.

BEGIN;

DROP FUNCTION IF EXISTS public.revert_daily_order(uuid, date);

COMMIT;

-- Verification (only the 3-arg signature remains):
--   SELECT p.oid::regprocedure FROM pg_proc p
--   JOIN pg_namespace n ON n.oid = p.pronamespace
--   WHERE n.nspname = 'public' AND p.proname = 'revert_daily_order';
