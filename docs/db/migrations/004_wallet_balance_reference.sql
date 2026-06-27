-- Migration: Add reference_type and reference_id support to update_wallet_balance
-- Purpose: Allow callers to link wallet transactions to specific records (e.g., daily orders)
-- Run in: Supabase SQL Editor

-- Create a new overload with 7 params (keeps old 5-param version working for existing callers)
CREATE OR REPLACE FUNCTION public.update_wallet_balance(
  p_user_id uuid,
  p_amount numeric,
  p_type text,
  p_description text,
  p_initiated_by text,
  p_reference_type text DEFAULT NULL,
  p_reference_id text DEFAULT NULL
) RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_current_balance NUMERIC;
  v_new_balance NUMERIC;
BEGIN
  SELECT wallet_balance INTO v_current_balance
  FROM public.users WHERE id = p_user_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'User not found';
  END IF;

  IF p_type = 'credit' THEN
    v_new_balance := v_current_balance + p_amount;
  ELSIF p_type = 'debit' THEN
    IF v_current_balance < p_amount THEN
      RAISE EXCEPTION 'Insufficient balance. Current balance is %', v_current_balance;
    END IF;
    v_new_balance := v_current_balance - p_amount;
  ELSE
    RAISE EXCEPTION 'Invalid transaction type. Must be "credit" or "debit"';
  END IF;

  UPDATE public.users
  SET wallet_balance = v_new_balance, updated_at = now()
  WHERE id = p_user_id;

  INSERT INTO public.wallet_transactions (
    user_id, type, amount, balance_after, description, initiated_by, reference_type, reference_id
  ) VALUES (
    p_user_id, p_type, p_amount, v_new_balance, p_description, p_initiated_by, p_reference_type, p_reference_id::uuid
  );

  RETURN v_new_balance;
END;
$function$;

-- Update finalize_daily_run to pass reference_type and reference_id
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

  UPDATE public.subscription_daily_orders
  SET is_finalized = true,
      finalized_at = now(),
      finalized_by = p_admin_id
  WHERE delivery_date = p_delivery_date
    AND status = 'pending'
    AND is_finalized = false;

  GET DIAGNOSTICS v_orders_finalized = ROW_COUNT;

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
        p_admin_id::text,
        'subscription',
        v_order.id::text
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

  SELECT COALESCE(SUM(total_value), 0) INTO v_total_value
  FROM public.subscription_daily_orders
  WHERE delivery_date = p_delivery_date AND is_finalized = true;

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
