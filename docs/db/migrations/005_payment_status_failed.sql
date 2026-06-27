-- Migration: Add 'failed' to subscription_daily_orders payment_status constraint
-- Purpose: Allow finalization to mark orders as 'failed' when wallet balance is insufficient
-- Run in: Supabase SQL Editor

ALTER TABLE public.subscription_daily_orders
DROP CONSTRAINT subscription_daily_orders_payment_status_check;

ALTER TABLE public.subscription_daily_orders
ADD CONSTRAINT subscription_daily_orders_payment_status_check
CHECK (payment_status IN ('pending', 'paid', 'failed', 'refunded'));
