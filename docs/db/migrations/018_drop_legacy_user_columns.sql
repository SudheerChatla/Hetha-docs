-- =============================================================================
-- Migration 018 — drop the legacy users.area / pincode / dark_mode / language
-- =============================================================================
-- Run in: Supabase SQL Editor. Apply AFTER the matching app/admin release, or
-- together with it — both clients stopped reading and writing these columns in
-- the same change set, and neither breaks while the columns still exist.
--
-- WHY
--   users.area / users.pincode
--     Denormalised leftovers. They were free text typed once into the admin
--     "Add Customer" form and never kept in sync with the customer's real
--     addresses — the test row that motivated this had area='Noida' with
--     pincode='110003', a Delhi PIN. Nothing validated the pair. Serviceability,
--     cutoffs and delivery frequency all resolve from the *address* pincode via
--     `pincodes` -> `delivery_areas`, which is the only source of record.
--
--     They were also actively harmful: the app's home-page location chip fell
--     back to them whenever the browsing address hadn't resolved yet, so every
--     arrival at the home tab flashed a stale city for one round-trip.
--
--   users.dark_mode / users.language
--     Write-only preferences. The settings screen stored them; nothing ever
--     read them back. Hetha_app ships no dark theme (no ThemeMode anywhere) and
--     no localisation (no localizationsDelegates / supportedLocales), so both
--     were permanently inert. Re-add them next to a real implementation.
--
-- WHAT DEPENDS ON THEM (verified before writing this migration)
--   * No index, constraint, default, generated column or RLS policy references
--     any of the four (checked via pg_depend against the canonical snapshots
--     loaded into an in-process Postgres).
--   * No trigger exists on public.users at all.
--   * Of the functions whose bodies mention these words, only
--     claim_adhoc_user actually touches users.dark_mode / users.language — it
--     names them in its INSERT column list, so it is recreated below.
--     (internal.place_order_core, internal.create_subscription_core and
--     update_address_as_default all refer to addresses.pincode /
--     subscriptions.snapshot_pincode / public.pincodes instead.)
--   * Migration 009's column-level GRANT UPDATE list names area and pincode.
--     Dropping a column drops its own column ACL and leaves the others intact,
--     so no grant is strictly required here — the list is reissued anyway so
--     that this file, not 009, is the current statement of what `authenticated`
--     may write.
--
--   Step 1 below is a pre-flight guard for the one thing that could not be
--   verified offline: two views (v_active_subscriptions, v_subscription_demand)
--   exist in the live database but were created in Studio, so their definitions
--   are not in this repo. v_active_subscriptions demonstrably joins users (it
--   exposes customer_name / customer_phone). If either view references one of
--   these columns, the guard names it and aborts before anything is dropped.
--
-- Idempotent: safe to re-run. Column drops use IF EXISTS; the function is
-- CREATE OR REPLACE; the grant is additive.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Pre-flight — abort with a useful message if a view (or any rewrite rule)
--    depends on the columns, instead of failing halfway with Postgres' terse
--    "cannot drop column ... because other objects depend on it".
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_blockers text;
BEGIN
  SELECT string_agg(DISTINCT dependent.relname || ' (' || a.attname || ')', ', ')
    INTO v_blockers
    FROM pg_depend d
    JOIN pg_rewrite r      ON r.oid = d.objid
    JOIN pg_class dependent ON dependent.oid = r.ev_class
    JOIN pg_attribute a    ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
   WHERE d.refobjid = 'public.users'::regclass
     AND d.classid  = 'pg_rewrite'::regclass
     AND a.attname IN ('area', 'pincode', 'dark_mode', 'language')
     AND dependent.relname <> 'users';

  IF v_blockers IS NOT NULL THEN
    RAISE EXCEPTION
      'Aborting: these views depend on the columns being dropped: %. '
      'Inspect with SELECT pg_get_viewdef(''public.<view>'', true), then either '
      'redefine the view without the column or drop it, and re-run.', v_blockers;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Recreate claim_adhoc_user without dark_mode / language.
--    Done BEFORE the drop so there is no window in which the live function
--    references columns that no longer exist. While the columns still exist,
--    omitting them from the INSERT just lets their defaults apply.
--    Body is otherwise byte-for-byte the 2026-07-28 export.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.claim_adhoc_user(p_auth_uid uuid, p_email text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_first_name text DEFAULT NULL::text, p_last_name text DEFAULT NULL::text)
 RETURNS users
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_user        public.users;
  v_adhoc_match public.users;
  v_collision   uuid;
  v_claims      jsonb;
  v_jwt_email   text;
  v_jwt_phone   text;
  v_email       text;
  v_phone       text;
  v_first_name  text := NULLIF(p_first_name, '');
  v_last_name   text := NULLIF(p_last_name, '');
BEGIN
  IF p_auth_uid IS NULL THEN
    RAISE EXCEPTION 'p_auth_uid is required';
  END IF;

  -- A caller may only claim/create their own row.
  IF NOT internal.is_service_actor() THEN
    IF auth.uid() IS NULL OR auth.uid() <> p_auth_uid THEN
      RAISE EXCEPTION 'Not authorized';
    END IF;
  END IF;

  v_claims    := COALESCE(NULLIF(current_setting('request.jwt.claims', true), ''), '{}')::jsonb;
  v_jwt_email := NULLIF(v_claims->>'email', '');
  v_jwt_phone := NULLIF(v_claims->>'phone', '');

  -- Identity used for matching comes from the token, not the request body.
  -- (Service-role callers may pass values explicitly.)
  IF internal.is_service_actor() THEN
    v_email := NULLIF(p_email, '');
    v_phone := NULLIF(p_phone, '');
  ELSE
    v_email := COALESCE(v_jwt_email, NULLIF(p_email, ''));
    v_phone := COALESCE(v_jwt_phone, NULLIF(p_phone, ''));

    IF v_jwt_email IS NOT NULL AND NULLIF(p_email, '') IS NOT NULL
       AND lower(p_email) <> lower(v_jwt_email) THEN
      RAISE EXCEPTION 'Email does not match the signed-in identity';
    END IF;
    IF v_jwt_phone IS NOT NULL AND NULLIF(p_phone, '') IS NOT NULL
       AND p_phone <> v_jwt_phone THEN
      RAISE EXCEPTION 'Phone does not match the signed-in identity';
    END IF;
  END IF;

  SELECT * INTO v_user FROM public.users WHERE id = p_auth_uid LIMIT 1;
  IF FOUND THEN
    RETURN v_user;
  END IF;

  IF v_email IS NOT NULL OR v_phone IS NOT NULL THEN
    SELECT * INTO v_adhoc_match
    FROM public.users
    WHERE is_adhoc = TRUE
      AND (
        (v_email IS NOT NULL AND lower(email) = lower(v_email)) OR
        (v_phone IS NOT NULL AND phone = v_phone)
      )
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
      UPDATE public.users
      SET id         = p_auth_uid,
          is_adhoc   = FALSE,
          email      = COALESCE(v_email, email),
          phone      = COALESCE(v_phone, phone),
          first_name = COALESCE(v_first_name, first_name),
          last_name  = COALESCE(v_last_name, last_name),
          updated_at = now()
      WHERE id = v_adhoc_match.id
      RETURNING * INTO v_user;

      RETURN v_user;
    END IF;

    SELECT id INTO v_collision
    FROM public.users
    WHERE is_adhoc = FALSE
      AND id <> p_auth_uid
      AND (
        (v_email IS NOT NULL AND lower(email) = lower(v_email)) OR
        (v_phone IS NOT NULL AND phone = v_phone)
      )
    LIMIT 1;

    IF v_collision IS NOT NULL THEN
      RAISE EXCEPTION 'Another account already exists with this email or phone'
        USING ERRCODE = 'unique_violation';
    END IF;
  END IF;

  -- dark_mode / language removed (migration 018).
  INSERT INTO public.users (
    id, email, phone, first_name, last_name,
    wallet_balance, notifications_enabled, is_adhoc
  ) VALUES (
    p_auth_uid, v_email, v_phone, v_first_name, v_last_name,
    0, TRUE, FALSE
  )
  RETURNING * INTO v_user;

  RETURN v_user;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. Drop the columns.
--    No CASCADE, deliberately: if some object not covered by the step-1 guard
--    depends on them, this must fail loudly rather than silently deleting it.
-- ---------------------------------------------------------------------------
ALTER TABLE public.users
  DROP COLUMN IF EXISTS area,
  DROP COLUMN IF EXISTS pincode,
  DROP COLUMN IF EXISTS dark_mode,
  DROP COLUMN IF EXISTS language;

-- ---------------------------------------------------------------------------
-- 4. Restate the column-level UPDATE grant (supersedes migration 009 §1).
--    wallet_balance stays absent — it changes only through
--    internal.apply_wallet_delta() inside SECURITY DEFINER functions, which
--    also writes the wallet_transactions ledger row.
-- ---------------------------------------------------------------------------
GRANT UPDATE (
  email,
  phone,
  first_name,
  last_name,
  notifications_enabled,
  updated_at,
  is_adhoc
) ON public.users TO authenticated;

COMMIT;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- 1. Columns are gone (expect 10 rows, none of them the four):
--      SELECT column_name FROM information_schema.columns
--       WHERE table_schema = 'public' AND table_name = 'users'
--       ORDER BY ordinal_position;
--
-- 2. wallet_balance still not writable, first_name still writable
--    (expect f, t):
--      SELECT has_column_privilege('authenticated','public.users','wallet_balance','UPDATE'),
--             has_column_privilege('authenticated','public.users','first_name','UPDATE');
--
-- 3. Ad-hoc claiming still works — the path that named the dropped columns:
--      SELECT public.claim_adhoc_user(
--               '00000000-0000-4000-8000-000000000001'::uuid,
--               'probe@example.com', NULL, 'Probe', 'User');
--      -- then clean up:
--      DELETE FROM public.users WHERE email = 'probe@example.com';
