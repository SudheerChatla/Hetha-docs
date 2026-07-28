-- =============================================================================
-- Migration 011 — LEGACY FUNCTION GRANTS + update_address_as_default fix
-- =============================================================================
-- Run in: Supabase SQL Editor, AFTER 010_grant_hardening.sql.
--
-- WHY
--   Functions that 007–010 never re-created still carry the implicit
--   `GRANT EXECUTE TO PUBLIC` that PostgreSQL adds at CREATE FUNCTION time.
--   `has_function_privilege('anon', …)` is true whenever PUBLIC holds the
--   privilege, so revoking from `anon` alone (010) had no effect on them.
--   Confirmed on the live database after deploying 010:
--     cancel_subscription        → anon: true
--     get_user_daily_commitment  → anon: true
--     update_address_as_default  → anon: true
--     get_user_role              → anon: true
--     rls_auto_enable            → anon: true
--     set_reviews_updated_at     → anon: true
--
--   `update_address_as_default` is the one that mattered: it is SECURITY DEFINER
--   and trusts `p_user_id`, so any caller holding a victim's user id + address id
--   could rewrite that address. It is also broken as deployed (writes
--   `addresses.phone` and `addresses.updated_at`, which do not exist — see the
--   known-issues header in docs/db/functions.sql), which is why the Flutter
--   fallback path in address_service.dart has been masking it. Fixed here.
--
--   `has_permission()` / `is_super_admin()` intentionally KEEP their grants:
--   RLS policies reference them and policy expressions are evaluated as the
--   calling role, including `anon` for the public catalog tables.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. update_address_as_default — correct columns + ownership check
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_address_as_default(
  p_user_id      uuid,
  p_address_id   uuid,
  p_address_data jsonb
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, internal
AS $$
BEGIN
  IF NOT internal.is_admin_actor('customers:edit') THEN
    IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
      RAISE EXCEPTION 'Not authorized to modify addresses for this user';
    END IF;
  END IF;

  UPDATE public.addresses
  SET is_default = false
  WHERE user_id = p_user_id AND is_default = true;

  UPDATE public.addresses
  SET
    address_line1 = COALESCE(p_address_data->>'address_line1', address_line1),
    address_line2 = COALESCE(p_address_data->>'address_line2', address_line2),
    city          = COALESCE(p_address_data->>'city', city),
    state         = COALESCE(p_address_data->>'state', state),
    pincode       = COALESCE(p_address_data->>'pincode', pincode),
    landmark      = COALESCE(p_address_data->>'landmark', landmark),
    -- was `phone` (no such column); the column is phone_number. Accept either
    -- key from the caller so existing client payloads keep working.
    phone_number  = COALESCE(p_address_data->>'phone_number',
                             p_address_data->>'phone', phone_number),
    name          = COALESCE(p_address_data->>'name', name),
    address_type  = COALESCE(p_address_data->>'address_type', address_type),
    is_default    = true
    -- `updated_at` removed: public.addresses has no such column.
  WHERE id = p_address_id AND user_id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Address not found or does not belong to user';
  END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- 2. Drop the implicit PUBLIC grants on the remaining legacy functions
-- ---------------------------------------------------------------------------
-- Customer-callable, but signed-in only.
REVOKE ALL ON FUNCTION public.cancel_subscription(uuid, uuid, timestamptz, boolean, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_user_daily_commitment(uuid)                                   FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_address_as_default(uuid, uuid, jsonb)                      FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.cancel_subscription(uuid, uuid, timestamptz, boolean, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_user_daily_commitment(uuid)                                   TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.update_address_as_default(uuid, uuid, jsonb)                      TO authenticated, service_role;

-- Trigger functions and dead code: never called directly over the API. For
-- triggers Postgres checks the table's TRIGGER privilege, not EXECUTE on the
-- function, so revoking is safe. Looped so the migration doesn't fail on a
-- project where one of them is absent (`set_reviews_updated_at` is not in the
-- docs/db/functions.sql snapshot, for example).
--
-- `get_user_role` is unused and broken (selects admin_users.auth_user_id; the
-- column is user_id). Left in place but unreachable; drop it once you have
-- confirmed nothing calls it.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('rls_auto_enable', 'set_reviews_updated_at', 'get_user_role')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', r.sig);
  END LOOP;
END $$;


-- ---------------------------------------------------------------------------
-- Verification — re-run the audit query; `anon` should now appear only for
-- quote_cart, has_permission and is_super_admin.
-- ---------------------------------------------------------------------------
-- SELECT p.proname, r.rolname
-- FROM pg_proc p
-- JOIN pg_namespace n ON n.oid = p.pronamespace
-- CROSS JOIN (VALUES ('anon'), ('authenticated')) AS r(rolname)
-- WHERE n.nspname = 'public'
--   AND has_function_privilege(r.rolname, p.oid, 'EXECUTE')
-- ORDER BY 1, 2;
