-- Migration 041: dashboard numbers from one database function (task A-13)
--
-- Run in: Supabase SQL Editor (the whole file; it is wrapped in one transaction)
--
-- ─── Problem ────────────────────────────────────────────────────────────────
-- The admin dashboard API made four requests, loaded every wallet credit of
-- the day to sum it in JavaScript, treated a failed request as 0, and took
-- "today" as midnight UTC (05:30 India time), so orders and credits placed
-- between midnight and 05:30 IST counted for the previous day.
--
-- ─── Fix ─────────────────────────────────────────────────────────────────────
-- public.get_dashboard_stats(): the four numbers in one call, summed in SQL,
-- with "today" = the India calendar day (internal.today_ist()).
--   today_orders          one-time orders placed today (India), any status
--   active_subscriptions  subscriptions with status 'active'
--   today_wallet_credits  Σ wallet credits created today (India)
--   total_customers       app users (is_adhoc = false)
-- Permission: dashboard:view (or super admin / service role).
--
-- ─── Rollout order ──────────────────────────────────────────────────────────
-- Apply THIS migration, then deploy the admin panel that calls it. Before it
-- is applied the new dashboard shows the error instead of numbers.

BEGIN;

CREATE OR REPLACE FUNCTION public.get_dashboard_stats()
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_start timestamptz := (internal.today_ist()::timestamp AT TIME ZONE 'Asia/Kolkata');
BEGIN
  IF NOT internal.is_admin_actor('dashboard:view') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  RETURN jsonb_build_object(
    'today_orders',
      (SELECT count(*) FROM public.orders WHERE placed_at >= v_start),
    'active_subscriptions',
      (SELECT count(*) FROM public.subscriptions WHERE status = 'active'),
    'today_wallet_credits',
      (SELECT COALESCE(round(SUM(amount), 2), 0) FROM public.wallet_transactions
       WHERE type = 'credit' AND created_at >= v_start),
    'total_customers',
      (SELECT count(*) FROM public.users WHERE is_adhoc = false));
END;
$function$;

REVOKE ALL ON FUNCTION public.get_dashboard_stats() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_dashboard_stats() TO authenticated, service_role;

COMMIT;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- 1. Runs in the SQL Editor (service role path):
--      SELECT public.get_dashboard_stats();
-- 2. Grants — expect t, f:
--      SELECT has_function_privilege('authenticated', 'public.get_dashboard_stats()', 'EXECUTE'),
--             has_function_privilege('anon', 'public.get_dashboard_stats()', 'EXECUTE');
