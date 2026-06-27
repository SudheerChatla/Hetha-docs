-- Migration: Create daily_ops_runs table
-- Purpose: Track per-date run state (draft/finalized/reconciled) for Daily Operations
-- Run in: Supabase SQL Editor

CREATE TABLE public.daily_ops_runs (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  delivery_date date NOT NULL,
  status text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'finalized', 'reconciled')),
  generated_at timestamp without time zone,
  generated_by uuid,
  finalized_at timestamp without time zone,
  finalized_by uuid,
  reconciled_at timestamp without time zone,
  reconciled_by uuid,
  total_orders integer DEFAULT 0,
  total_value numeric DEFAULT 0,
  wallet_deduction_completed_at timestamp without time zone,
  notes text,
  created_at timestamp without time zone DEFAULT now(),
  updated_at timestamp without time zone DEFAULT now(),
  CONSTRAINT daily_ops_runs_pkey PRIMARY KEY (id),
  CONSTRAINT daily_ops_runs_delivery_date_key UNIQUE (delivery_date)
);

-- RLS
ALTER TABLE public.daily_ops_runs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "daily_ops_runs_select_policy" ON public.daily_ops_runs
  FOR SELECT USING (is_super_admin() OR has_permission('daily_ops:view'));

CREATE POLICY "daily_ops_runs_write_policy" ON public.daily_ops_runs
  FOR ALL USING (is_super_admin() OR has_permission('daily_ops:edit'))
  WITH CHECK (is_super_admin() OR has_permission('daily_ops:edit'));
