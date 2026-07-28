-- =============================================================================
-- Migration 014 — make the subscription views run as the caller (RLS-safe)
-- =============================================================================
-- Run in: Supabase SQL Editor. (Already applied live on 2026-07-28; this file
-- records it so the repo stays the source of truth.)
--
-- WHY
--   The Supabase database linter flagged v_active_subscriptions and
--   v_subscription_demand as `security_definer_view` (ERROR). A SECURITY DEFINER
--   view runs with its CREATOR's privileges and BYPASSES row-level security on
--   the underlying tables — so subscriptions.RLS (which scopes a customer to
--   their own rows) would not apply when reading through the view. If `anon` or
--   `authenticated` could SELECT the view, that is a cross-customer data leak.
--
--   Postgres 15+ (Supabase) supports `security_invoker` on views: the view then
--   runs with the QUERYING user's privileges and enforces their RLS. This can
--   only tighten access, never loosen it, so it is safe to apply blind.
--
--   These views are not referenced anywhere in Hetha_app or Hetha_admin — they
--   appear to be dashboard/ops-report leftovers created directly in Studio. If
--   an external report relied on the old RLS-bypassing behaviour, point it at
--   the service_role key instead of reverting this.
--
-- Idempotent: SET (security_invoker = on) is a no-op if already set.
-- =============================================================================

DO $$
BEGIN
  IF to_regclass('public.v_active_subscriptions') IS NOT NULL THEN
    EXECUTE 'ALTER VIEW public.v_active_subscriptions SET (security_invoker = on)';
  END IF;

  IF to_regclass('public.v_subscription_demand') IS NOT NULL THEN
    EXECUTE 'ALTER VIEW public.v_subscription_demand SET (security_invoker = on)';
  END IF;
END $$;

-- Verification (both should be 'on'):
--   SELECT c.relname,
--          (SELECT option_value FROM pg_options_to_table(c.reloptions)
--           WHERE option_name = 'security_invoker') AS security_invoker
--   FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
--   WHERE n.nspname = 'public'
--     AND c.relname IN ('v_active_subscriptions', 'v_subscription_demand');
