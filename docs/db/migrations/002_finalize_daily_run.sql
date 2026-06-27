-- Migration: Create finalize_daily_run RPC
-- Purpose: Atomically lock orders + deduct wallets for a delivery date
-- Run in: Supabase SQL Editor (after 001_daily_ops_runs.sql)

CREATE OR REPLACE FUNCTION public.finalize_daily_run(
  p_delivery_date date,
  p_admin_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
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
  -- 1. Upsert the run record
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

  -- 2. Lock all pending orders
  UPDATE public.subscription_daily_orders
  SET is_finalized = true,
      finalized_at = now(),
      finalized_by = p_admin_id
  WHERE delivery_date = p_delivery_date
    AND status = 'pending'
    AND is_finalized = false;

  GET DIAGNOSTICS v_orders_finalized = ROW_COUNT;

  -- 3. Deduct wallet for wallet-payment subscriptions
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
      PERFORM public.update_wallet_balance(
        v_order.user_id,
        v_order.total_value,
        'debit',
        'Subscription delivery ' || p_delivery_date::text,
        p_admin_id::text
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

  -- 4. Compute total value of all finalized orders
  SELECT COALESCE(SUM(total_value), 0) INTO v_total_value
  FROM public.subscription_daily_orders
  WHERE delivery_date = p_delivery_date AND is_finalized = true;

  -- 5. Update run record
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
