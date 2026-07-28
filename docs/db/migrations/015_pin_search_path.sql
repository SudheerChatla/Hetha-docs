-- =============================================================================
-- Migration 015 — pin function search_path; drop anon EXECUTE on quote_cart
-- =============================================================================
-- Run in: Supabase SQL Editor. Clears the `function_search_path_mutable` linter
-- warnings and reduces the anon surface. No function bodies change.
--
-- WHY (search_path):
--   A function without an explicit `search_path` uses the caller's session
--   search_path. For SECURITY DEFINER functions that is a hardening risk
--   (search-path injection: a caller could shadow an unqualified table/operator
--   name). Migrations 007–012 already pinned search_path on the functions they
--   created; these 9 pre-existing / rewritten helpers were never pinned. Setting
--   it is behaviour-neutral here — every one either fully-qualifies its object
--   references or only touches objects in the schema we pin to.
--
-- WHY (quote_cart):
--   quote_cart is read-only catalog pricing. Checkout requires a signed-in user,
--   so `anon` never needs it. Keep it for `authenticated` / `service_role`.
--   (If you later add guest cart pricing, re-grant EXECUTE to anon.)
-- =============================================================================

-- public helpers: unqualified refs (if any) live in public
ALTER FUNCTION public.has_permission(text)                                            SET search_path = public;
ALTER FUNCTION public.is_super_admin()                                                SET search_path = public;
ALTER FUNCTION public.get_user_daily_commitment(uuid)                                 SET search_path = public;
ALTER FUNCTION public.cancel_subscription(uuid, uuid, timestamptz, boolean, text, text) SET search_path = public;
ALTER FUNCTION public.set_reviews_updated_at()                                        SET search_path = public;

-- internal helpers: fully-qualify everything, but pin anyway for the linter
ALTER FUNCTION internal.jwt_role()                SET search_path = internal, public;
ALTER FUNCTION internal.is_service_actor()        SET search_path = internal, public;
ALTER FUNCTION internal.is_admin_actor(text)      SET search_path = internal, public;
ALTER FUNCTION internal.money_checks_disabled()   SET search_path = internal, public;

-- Least privilege: anon does not check out, so it does not need quote_cart.
REVOKE ALL ON FUNCTION public.quote_cart(jsonb) FROM anon;

-- Verification — expect a non-empty proconfig (search_path=...) on each:
--   SELECT n.nspname, p.proname, p.proconfig
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--   WHERE (n.nspname, p.proname) IN (
--     ('public','has_permission'),('public','is_super_admin'),
--     ('public','get_user_daily_commitment'),('public','cancel_subscription'),
--     ('public','set_reviews_updated_at'),('internal','jwt_role'),
--     ('internal','is_service_actor'),('internal','is_admin_actor'),
--     ('internal','money_checks_disabled'))
--   ORDER BY 1,2;
--
--   -- anon can no longer call quote_cart → false
--   SELECT has_function_privilege('anon','public.quote_cart(jsonb)','EXECUTE');
