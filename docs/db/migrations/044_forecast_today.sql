-- Migration 044: wallet forecast counts today until it is paid; "more than N days"
--
-- Run in: Supabase SQL Editor (the whole file; it is wrapped in one transaction)
--
-- ─── Problem ────────────────────────────────────────────────────────────────
-- internal.wallet_forecast (migration 039) always started tomorrow. When a
-- day's run is generated and finalized during that day, today's delivery is
-- still owed but was left out, so "wallet covers until" was one delivery day
-- too late. And a wallet lasting past the window showed the window's last
-- day as if the money ran out there.
--
-- ─── Fix ─────────────────────────────────────────────────────────────────────
-- 1. Today is counted like any other day, by what is still owed:
--      run not generated yet      → the expected delivery amount
--      generated, not paid yet    → total minus paid
--      already paid (finalized)   → 0
--      skipped / cancelled        → 0
--    Correct whether runs are finalized the evening before (today is paid,
--    adds 0, same as before) or during the day. A day with no run at all
--    shows one day less until midnight: the safe side.
-- 2. New field covers_beyond_horizon: true when every delivery in the window
--    is covered.
-- Unchanged: orders on settlement hold (D-9) still count 0; they are never
-- charged automatically. Nothing about how money moves changes; this is
-- read only. The body is otherwise copied unchanged from 039.
--
-- ─── Rollout order ──────────────────────────────────────────────────────────
-- Apply, then deploy the admin panel and release the app that show
-- covers_beyond_horizon. Older clients ignore the new field.

BEGIN;

CREATE OR REPLACE FUNCTION internal.wallet_forecast(
  p_user_id uuid,
  p_days    integer,
  p_today   date DEFAULT NULL
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_today     date := COALESCE(p_today, internal.today_ist());
  v_days      integer := LEAST(GREATEST(COALESCE(p_days, 14), 1), 60);
  v_balance   numeric;
  v_reserve   numeric;
  v_day       date;
  v_sub       record;
  v_order     record;
  v_amount    numeric;
  v_day_total numeric;
  v_subs      jsonb;
  v_list      jsonb := '[]'::jsonb;
  v_running   numeric := 0;
  v_covered_until date;
  v_first_uncovered date;
  v_covered_count integer := 0;
  v_item      jsonb;
BEGIN
  SELECT COALESCE(wallet_balance, 0) INTO v_balance FROM public.users WHERE id = p_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'User not found';
  END IF;
  v_reserve := internal.wallet_reserve(p_user_id);

  -- Today first (migration 044): today's delivery counts until it is paid.
  -- A run finalized the evening before is already paid and adds 0; a run
  -- finalized during the day is still owed and counts. Then the next v_days days.
  FOR i IN 0..v_days LOOP
    v_day := v_today + i;
    v_day_total := 0;
    v_subs := '[]'::jsonb;

    FOR v_sub IN
      SELECT s.id, s.label, s.delivary_area
      FROM public.subscriptions s
      WHERE s.user_id = p_user_id AND s.status IN ('active', 'pending_cancellation')
      ORDER BY s.created_at, s.id
    LOOP
      SELECT status, total_value, paid_amount, settlement_hold_reason INTO v_order
      FROM public.subscription_daily_orders
      WHERE subscription_id = v_sub.id AND delivery_date = v_day
      ORDER BY created_at, id
      LIMIT 1;

      IF FOUND THEN
        -- Held orders (D-9) are never charged automatically, so they are not
        -- part of what the wallet has to cover.
        IF v_order.status IN ('skipped', 'cancelled') OR v_order.settlement_hold_reason IS NOT NULL THEN
          v_amount := 0;
        ELSE
          v_amount := GREATEST(COALESCE(v_order.total_value, 0) - COALESCE(v_order.paid_amount, 0), 0);
        END IF;
      ELSIF internal.subscription_delivers_on(v_sub.id, v_day) THEN
        SELECT COALESCE(SUM(round(i2.unit_price * i2.quantity, 2)), 0) INTO v_amount
        FROM internal.subscription_items_on(v_sub.id, v_day) i2;
      ELSE
        v_amount := 0;
      END IF;

      IF v_amount > 0 THEN
        v_day_total := v_day_total + v_amount;
        v_subs := v_subs || jsonb_build_object(
          'subscription_id', v_sub.id, 'label', v_sub.label,
          'area', v_sub.delivary_area, 'amount', round(v_amount, 2));
      END IF;
    END LOOP;

    IF v_day_total > 0 THEN
      v_list := v_list || jsonb_build_object(
        'date', to_char(v_day, 'YYYY-MM-DD'), 'amount', round(v_day_total, 2), 'subscriptions', v_subs);
    END IF;
  END LOOP;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_list) LOOP
    v_running := v_running + (v_item->>'amount')::numeric;
    IF v_running <= v_balance THEN
      v_covered_until := (v_item->>'date')::date;
      v_covered_count := v_covered_count + 1;
    ELSIF v_first_uncovered IS NULL THEN
      v_first_uncovered := (v_item->>'date')::date;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'balance',              round(v_balance, 2),
    'reserve',              v_reserve,
    'available',            round(GREATEST(v_balance - v_reserve, 0), 2),
    'per_delivery_total',   round(COALESCE(public.get_user_daily_commitment(p_user_id), 0), 2),
    'next_delivery_date',   v_list->0->>'date',
    'next_delivery_amount', COALESCE((v_list->0->>'amount')::numeric, 0),
    'next_delivery_covered', CASE WHEN jsonb_array_length(v_list) = 0 THEN true
                                  ELSE (v_list->0->>'amount')::numeric <= v_balance END,
    'covered_until',        to_char(v_covered_until, 'YYYY-MM-DD'),
    'first_uncovered_date', to_char(v_first_uncovered, 'YYYY-MM-DD'),
    'covered_deliveries',   v_covered_count,
    'horizon_days',         v_days,
    -- true when every delivery in the window is covered: the wallet lasts
    -- beyond the last day looked at (show "more than N days", not a date).
    'covers_beyond_horizon', jsonb_array_length(v_list) > 0 AND v_first_uncovered IS NULL,
    'days',                 v_list);
END;
$function$;

COMMIT;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- 1. Today is in the window and the new field is there (any customer id):
--      SELECT r->'days'->0->>'date' AS first_day, r->>'covers_beyond_horizon' AS beyond,
--             internal.today_ist() AS today
--      FROM (SELECT internal.wallet_forecast('<user id>', 30) AS r) x;
--    first_day is today when today's delivery is not yet paid, else a later day.
