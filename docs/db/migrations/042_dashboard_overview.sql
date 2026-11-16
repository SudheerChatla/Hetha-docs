-- Migration 042: dashboard overview (recent orders, week, top products, today's ops)
--
-- Run in: Supabase SQL Editor (the whole file; it is wrapped in one transaction)
--
-- ─── Problem ────────────────────────────────────────────────────────────────
-- The dashboard used to show hardcoded charts, sample orders and sample
-- products. They were removed (A-13); the owner wants the useful ones back,
-- built on real data, plus the day's operations at a glance.
--
-- ─── Fix ─────────────────────────────────────────────────────────────────────
-- public.get_dashboard_overview(): one call, everything counted in SQL,
-- days are India calendar days (internal.today_ist()).
--   recent_orders  the 5 newest one-time orders (number, customer, placed at,
--                  status, total); unpaid online orders (payment_pending) left out
--   week           the last 7 days: one-time orders placed, and subscription
--                  deliveries delivered, per day
--   top_products   last 30 days, top 5 products by quantity delivered:
--                  delivered subscription items (delivered quantity, or the
--                  ordered quantity when none was recorded) + items of
--                  delivered one-time orders
--   today_run      today's run sheet: status ('not_generated' when none),
--                  orders going out (not skipped / cancelled), still pending
--   low_balance_tomorrow  customers whose wallet cannot cover their orders
--                  tomorrow, and how many of them are not yet notified
--                  (internal.low_balance_customers, migration 039)
--   held_orders    orders on payment hold (D-9)
-- Permission: dashboard:view (or super admin / service role). Read only.
--
-- ─── Rollout order ──────────────────────────────────────────────────────────
-- Needs migration 039 (low_balance_customers). Apply THIS migration, then
-- deploy the admin panel that calls it. Until then the new dashboard shows
-- the four numbers and an error for the rest.

BEGIN;

CREATE OR REPLACE FUNCTION public.get_dashboard_overview()
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_today date := internal.today_ist();
  v_recent jsonb;
  v_week jsonb;
  v_top jsonb;
  v_run jsonb;
  v_low jsonb;
  v_held integer;
BEGIN
  IF NOT internal.is_admin_actor('dashboard:view') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  -- placed_at is a timestamp stored in UTC; convert it to India time.
  SELECT COALESCE(jsonb_agg(r ORDER BY r.placed_at DESC), '[]'::jsonb) INTO v_recent
  FROM (
    SELECT o.id, o.order_number,
           COALESCE(NULLIF(o.snapshot_name, ''), NULLIF(trim(concat_ws(' ', u.first_name, u.last_name)), ''), 'Customer') AS customer,
           (o.placed_at AT TIME ZONE 'UTC') AS placed_at,
           o.status, round(o.total, 2) AS total
    FROM public.orders o
    LEFT JOIN public.users u ON u.id = o.user_id
    WHERE o.status <> 'payment_pending'
    ORDER BY o.placed_at DESC
    LIMIT 5
  ) r;

  SELECT jsonb_agg(jsonb_build_object(
           'date', to_char(d, 'YYYY-MM-DD'),
           'one_time_orders', (SELECT count(*) FROM public.orders o
                               WHERE o.status <> 'payment_pending'
                                 AND ((o.placed_at AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Kolkata')::date = d),
           'subscription_deliveries', (SELECT count(*) FROM public.subscription_daily_orders s
                                       WHERE s.delivery_date = d AND s.status = 'delivered'))
         ORDER BY d)
  INTO v_week
  FROM generate_series(v_today - 6, v_today, interval '1 day') AS g(day), LATERAL (SELECT g.day::date AS d) x;

  SELECT COALESCE(jsonb_agg(t ORDER BY t.quantity DESC, t.name), '[]'::jsonb) INTO v_top
  FROM (
    SELECT name, SUM(qty)::integer AS quantity
    FROM (
      SELECT i.product_name_snapshot AS name, COALESCE(i.delivered_qty, i.quantity) AS qty
      FROM public.subscription_daily_order_items i
      JOIN public.subscription_daily_orders s ON s.id = i.daily_order_id
      WHERE s.status = 'delivered' AND s.delivery_date > v_today - 30 AND s.delivery_date <= v_today
      UNION ALL
      SELECT oi.product_name_snapshot, COALESCE(oi.delivered_qty, oi.quantity)
      FROM public.order_items oi
      JOIN public.orders o ON o.id = oi.order_id
      WHERE o.status = 'delivered'
        AND (o.delivered_at AT TIME ZONE 'Asia/Kolkata')::date > v_today - 30
    ) q
    WHERE qty > 0
    GROUP BY name
    ORDER BY SUM(qty) DESC, name
    LIMIT 5
  ) t;

  SELECT jsonb_build_object(
           'date', to_char(v_today, 'YYYY-MM-DD'),
           'status', COALESCE((SELECT status FROM public.daily_ops_runs WHERE delivery_date = v_today), 'not_generated'),
           'orders', (SELECT count(*) FROM public.subscription_daily_orders
                      WHERE delivery_date = v_today AND status NOT IN ('skipped', 'cancelled')),
           'pending', (SELECT count(*) FROM public.subscription_daily_orders
                       WHERE delivery_date = v_today AND status = 'pending'))
  INTO v_run;

  SELECT jsonb_build_object(
           'date', to_char(v_today + 1, 'YYYY-MM-DD'),
           'customers', count(*),
           'not_notified', count(*) FILTER (WHERE c.notice_status IS DISTINCT FROM 'sent'))
  INTO v_low
  FROM internal.low_balance_customers(v_today + 1) c;

  SELECT count(*) INTO v_held
  FROM public.subscription_daily_orders WHERE settlement_hold_reason IS NOT NULL;

  RETURN jsonb_build_object(
    'recent_orders', v_recent,
    'week', COALESCE(v_week, '[]'::jsonb),
    'top_products', v_top,
    'today_run', v_run,
    'low_balance_tomorrow', v_low,
    'held_orders', v_held);
END;
$function$;

REVOKE ALL ON FUNCTION public.get_dashboard_overview() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_dashboard_overview() TO authenticated, service_role;

COMMIT;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- 1. Runs in the SQL Editor:
--      SELECT jsonb_pretty(public.get_dashboard_overview());
-- 2. Grants — expect t, f:
--      SELECT has_function_privilege('authenticated', 'public.get_dashboard_overview()', 'EXECUTE'),
--             has_function_privilege('anon', 'public.get_dashboard_overview()', 'EXECUTE');
