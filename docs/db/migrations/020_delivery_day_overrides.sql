-- Migration 020: Delivery Day Overrides
-- Purpose: Support the rare operational case where a whole area, a specific
--          route, or a hand-picked set of individual subscriptions cannot be
--          delivered on their normal cycle day (road closures, weather, etc.)
--          and need to be delivered on a *different* area's scheduled day —
--          for exactly one date, auto-reverting the next day.
--
-- Run in: Supabase SQL Editor
--
-- How it's used by the run-sheet generator (services/dailyOps/generateRunSheet.ts):
--   1. Before computing a subscription's normal area-cadence eligibility for
--      the target date, check delivery_day_override_subscriptions for a row
--      matching (subscription_id) whose parent override's override_date =
--      target date.
--   2. If found, evaluate cadence against the override's swapped_with_area_id
--      cadence (delivery_areas.delivary_frequency / reference_date) instead
--      of the subscription's own area.
--   3. If no override row exists for that date, behavior is completely
--      unchanged — this is why the swap "auto-reverts": there's nothing to
--      clean up, the override only exists for the one date it was created for.

-- ─── delivery_day_overrides ────────────────────────────────────────────────
-- One row per override event: "on this date, the selected subscriptions
-- should follow this other area's delivery cadence instead of their own."
CREATE TABLE public.delivery_day_overrides (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  override_date date NOT NULL,
  swapped_with_area_id uuid NOT NULL,
  selection_type text NOT NULL CHECK (selection_type IN ('area', 'route', 'customer')),
  source_area_id uuid,              -- area filter used to build the selection (nullable — informational)
  source_route_id uuid,             -- route filter used to build the selection (nullable — informational)
  reason text,
  created_by uuid,
  created_at timestamp without time zone DEFAULT now(),
  CONSTRAINT delivery_day_overrides_pkey PRIMARY KEY (id),
  CONSTRAINT fk_override_swapped_area FOREIGN KEY (swapped_with_area_id) REFERENCES public.delivery_areas(id),
  CONSTRAINT fk_override_source_area FOREIGN KEY (source_area_id) REFERENCES public.delivery_areas(id),
  CONSTRAINT fk_override_source_route FOREIGN KEY (source_route_id) REFERENCES public.delivery_routes(id),
  CONSTRAINT fk_override_created_by FOREIGN KEY (created_by) REFERENCES public.admin_users(user_id)
);

CREATE INDEX idx_delivery_day_overrides_date ON public.delivery_day_overrides (override_date);

-- ─── delivery_day_override_subscriptions ──────────────────────────────────
-- The resolved list of affected subscriptions for one override event.
-- Whether the admin picked "whole area", "a route", or hand-picked customers,
-- it always resolves down to explicit subscription rows here — this is the
-- only thing the run-sheet generator needs to check.
CREATE TABLE public.delivery_day_override_subscriptions (
  override_id uuid NOT NULL,
  subscription_id uuid NOT NULL,
  CONSTRAINT delivery_day_override_subscriptions_pkey PRIMARY KEY (override_id, subscription_id),
  CONSTRAINT fk_ods_override FOREIGN KEY (override_id) REFERENCES public.delivery_day_overrides(id) ON DELETE CASCADE,
  CONSTRAINT fk_ods_subscription FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id) ON DELETE CASCADE
);

-- A given subscription can only be in ONE override per date. Enforced via a
-- partial unique index joined through the parent — since override_date lives
-- on the parent table, we enforce this with a trigger rather than a plain
-- unique constraint (Postgres can't express a cross-table uniqueness directly).
CREATE OR REPLACE FUNCTION internal.check_single_override_per_date()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'internal'
AS $$
DECLARE
  v_date date;
  v_conflict_count integer;
BEGIN
  SELECT override_date INTO v_date
  FROM public.delivery_day_overrides
  WHERE id = NEW.override_id;

  SELECT count(*) INTO v_conflict_count
  FROM public.delivery_day_override_subscriptions dos
  JOIN public.delivery_day_overrides d ON d.id = dos.override_id
  WHERE dos.subscription_id = NEW.subscription_id
    AND d.override_date = v_date
    AND dos.override_id <> NEW.override_id;

  IF v_conflict_count > 0 THEN
    RAISE EXCEPTION 'Subscription % already has an active override for %', NEW.subscription_id, v_date;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_single_override_per_date
  BEFORE INSERT OR UPDATE ON public.delivery_day_override_subscriptions
  FOR EACH ROW EXECUTE FUNCTION internal.check_single_override_per_date();

-- ─── RLS ───────────────────────────────────────────────────────────────────
ALTER TABLE public.delivery_day_overrides ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.delivery_day_override_subscriptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "delivery_day_overrides_select_policy" ON public.delivery_day_overrides
  FOR SELECT USING (is_super_admin() OR has_permission('daily_ops:view'));

CREATE POLICY "delivery_day_overrides_write_policy" ON public.delivery_day_overrides
  FOR ALL USING (is_super_admin() OR has_permission('daily_ops:edit'))
  WITH CHECK (is_super_admin() OR has_permission('daily_ops:edit'));

CREATE POLICY "delivery_day_override_subscriptions_select_policy" ON public.delivery_day_override_subscriptions
  FOR SELECT USING (is_super_admin() OR has_permission('daily_ops:view'));

CREATE POLICY "delivery_day_override_subscriptions_write_policy" ON public.delivery_day_override_subscriptions
  FOR ALL USING (is_super_admin() OR has_permission('daily_ops:edit'))
  WITH CHECK (is_super_admin() OR has_permission('daily_ops:edit'));
