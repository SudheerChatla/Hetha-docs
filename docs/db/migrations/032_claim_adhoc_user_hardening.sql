-- Migration 032: Harden claim_adhoc_user against phone spoofing
--
-- Run in: Supabase SQL Editor (the whole file; it is wrapped in one transaction)
--
-- ─── Problem ────────────────────────────────────────────────────────────────
-- claim_adhoc_user merges an is_adhoc row onto a real auth account after
-- sign-in. For non-service callers it does:
--     v_email := COALESCE(v_jwt_email, p_email);
--     v_phone := COALESCE(v_jwt_phone, p_phone);
--
-- Email sign-ups have no phone in the JWT, so v_phone falls back to p_phone
-- from the request body — a value the attacker controls. An attacker who
-- knows (or guesses) a victim ad-hoc customer's phone can pass it in p_phone
-- and claim that row, inheriting the victim's wallet, addresses, and orders.
--
-- Additionally, the matching query is:
--     WHERE is_adhoc = TRUE AND (email OR phone) ... LIMIT 1
-- If the email matched one ad-hoc row and the phone another, whichever row
-- Postgres returned first won.
--
-- ─── Fix ─────────────────────────────────────────────────────────────────────
-- 1. Non-service callers: identity for ad-hoc matching comes ONLY from the
--    JWT claims (email and phone). The body's p_email/p_phone are never used
--    for matching — only for the mismatch exceptions (when given AND different
--    from the JWT, compare after normalising both). Phones are normalised to
--    10-digit national format for matching (strip non-digits; if 12 digits
--    starting with 91, take last 10).
--
-- 2. Non-service callers cannot use p_adhoc_id (raises "Not authorized").
--
-- 3. Matching order: the ad-hoc row with the same email first (the identity
--    the customer verified), otherwise the one with the same phone. email and
--    phone are UNIQUE columns, so each matches at most one row; a true tie
--    (spelling variants) is refused instead of guessed.
--
-- 4. Service-role callers: if p_adhoc_id is given, lock exactly that row
--    (raises if not found or already is_adhoc=false); before claiming, check
--    for email/phone collision with any OTHER users row. Without p_adhoc_id,
--    same matching order on the passed p_email/p_phone; a tie → RAISE
--    'More than one ad-hoc customer matches …; pass p_adhoc_id'.
--
-- 5. Collision check and fresh INSERT unchanged.
--
-- Signature adds p_adhoc_id uuid DEFAULT NULL as a 6th parameter. Named-arg
-- calls with 5 parameters from the app continue working unchanged.

BEGIN;

-- Helper to normalise a phone to 10-digit national format.
-- Strip all non-digits; if 12 digits starting with "91", take last 10.
CREATE OR REPLACE FUNCTION internal.normalize_phone_10(p_raw text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
  v_digits text;
BEGIN
  IF p_raw IS NULL THEN
    RETURN NULL;
  END IF;
  v_digits := regexp_replace(p_raw, '[^0-9]', '', 'g');
  IF length(v_digits) = 12 AND v_digits LIKE '91%' THEN
    v_digits := right(v_digits, 10);
  END IF;
  IF length(v_digits) = 10 THEN
    RETURN v_digits;
  END IF;
  RETURN NULL;  -- invalid / unknown format
END;
$function$;

-- Drop old 5-arg version, create 6-arg version.
DROP FUNCTION IF EXISTS public.claim_adhoc_user(uuid, text, text, text, text);

CREATE OR REPLACE FUNCTION public.claim_adhoc_user(
  p_auth_uid   uuid,
  p_email      text DEFAULT NULL,
  p_phone      text DEFAULT NULL,
  p_first_name text DEFAULT NULL,
  p_last_name  text DEFAULT NULL,
  p_adhoc_id   uuid DEFAULT NULL
)
 RETURNS public.users
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_user           public.users;
  v_adhoc_match    public.users;
  v_collision      uuid;
  v_claims         jsonb;
  v_jwt_email      text;
  v_jwt_phone      text;
  v_jwt_phone_norm text;
  v_p_email_clean  text;
  v_p_phone_norm   text;
  v_match_email    text;   -- email used for matching
  v_match_phone    text;   -- phone used for matching (10-digit)
  v_write_email    text;   -- email written to the row
  v_write_phone    text;   -- phone written to the row
  v_first_name     text := NULLIF(p_first_name, '');
  v_last_name      text := NULLIF(p_last_name, '');
  v_match_count    integer;
  v_is_service     boolean;
BEGIN
  IF p_auth_uid IS NULL THEN
    RAISE EXCEPTION 'p_auth_uid is required';
  END IF;

  v_is_service := internal.is_service_actor();

  -- A caller may only claim/create their own row (non-service).
  IF NOT v_is_service THEN
    IF auth.uid() IS NULL OR auth.uid() <> p_auth_uid THEN
      RAISE EXCEPTION 'Not authorized';
    END IF;

    -- p_adhoc_id is service-only.
    IF p_adhoc_id IS NOT NULL THEN
      RAISE EXCEPTION 'Not authorized';
    END IF;
  END IF;

  -- Extract JWT claims.
  v_claims         := COALESCE(NULLIF(current_setting('request.jwt.claims', true), ''), '{}')::jsonb;
  v_jwt_email      := NULLIF(v_claims->>'email', '');
  v_jwt_phone      := NULLIF(v_claims->>'phone', '');
  v_jwt_phone_norm := internal.normalize_phone_10(v_jwt_phone);

  -- Normalise body params for comparison / service use.
  v_p_email_clean  := NULLIF(p_email, '');
  v_p_phone_norm   := internal.normalize_phone_10(p_phone);

  -- Mismatch checks: if both JWT and body have a value, they must match.
  -- (Email: case-insensitive; Phone: after normalisation.)
  IF NOT v_is_service THEN
    IF v_jwt_email IS NOT NULL AND v_p_email_clean IS NOT NULL
       AND lower(v_p_email_clean) <> lower(v_jwt_email) THEN
      RAISE EXCEPTION 'Email does not match the signed-in identity';
    END IF;
    IF v_jwt_phone_norm IS NOT NULL AND v_p_phone_norm IS NOT NULL
       AND v_p_phone_norm <> v_jwt_phone_norm THEN
      RAISE EXCEPTION 'Phone does not match the signed-in identity';
    END IF;
  END IF;

  -- Determine matching / writing identity.
  IF v_is_service THEN
    -- Service callers use body params directly.
    v_match_email := lower(v_p_email_clean);
    v_match_phone := v_p_phone_norm;
    v_write_email := v_p_email_clean;
    v_write_phone := NULLIF(p_phone, '');  -- preserve original format
  ELSE
    -- Non-service: match ONLY on JWT claims; body is ignored for matching.
    v_match_email := lower(v_jwt_email);
    v_match_phone := v_jwt_phone_norm;
    v_write_email := v_jwt_email;
    v_write_phone := v_jwt_phone;  -- preserve original format
  END IF;

  ---------------------------------------------------------------------------
  -- Fast path: user row already exists for this auth id → return it.
  ---------------------------------------------------------------------------
  SELECT * INTO v_user FROM public.users WHERE id = p_auth_uid LIMIT 1;
  IF FOUND THEN
    RETURN v_user;
  END IF;

  ---------------------------------------------------------------------------
  -- SERVICE ROLE with p_adhoc_id: target that exact row.
  ---------------------------------------------------------------------------
  IF v_is_service AND p_adhoc_id IS NOT NULL THEN
    SELECT * INTO v_adhoc_match
    FROM public.users
    WHERE id = p_adhoc_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Ad-hoc customer not found';
    END IF;

    IF v_adhoc_match.is_adhoc = FALSE THEN
      RAISE EXCEPTION 'Customer is already an app user';
    END IF;

    -- Check for email/phone collision with OTHER rows.
    -- Values to write: COALESCE(body param, existing row value).
    DECLARE
      v_final_email text := COALESCE(v_write_email, v_adhoc_match.email);
      v_final_phone text := COALESCE(NULLIF(p_phone, ''), v_adhoc_match.phone);
      v_final_phone_norm text := internal.normalize_phone_10(v_final_phone);
    BEGIN
      SELECT id INTO v_collision
      FROM public.users
      WHERE id <> p_adhoc_id
        AND (
          (v_final_email IS NOT NULL AND lower(email) = lower(v_final_email)) OR
          (v_final_phone_norm IS NOT NULL AND internal.normalize_phone_10(phone) = v_final_phone_norm)
        )
      LIMIT 1;

      IF v_collision IS NOT NULL THEN
        RAISE EXCEPTION 'Another account already exists with this email or phone'
          USING ERRCODE = 'unique_violation';
      END IF;

      UPDATE public.users
      SET id         = p_auth_uid,
          is_adhoc   = FALSE,
          email      = COALESCE(v_write_email, email),
          phone      = COALESCE(NULLIF(p_phone, ''), phone),
          first_name = COALESCE(v_first_name, first_name),
          last_name  = COALESCE(v_last_name, last_name),
          updated_at = now()
      WHERE id = p_adhoc_id
      RETURNING * INTO v_user;

      RETURN v_user;
    END;
  END IF;

  ---------------------------------------------------------------------------
  -- Ad-hoc matching (both service without p_adhoc_id, and non-service).
  ---------------------------------------------------------------------------
  -- users.email and users.phone are both UNIQUE, so the email and the phone
  -- can each match at most one row (barring case / format variants). If they
  -- point at DIFFERENT rows, the email match wins: it is the identity the
  -- customer verified at sign-up. A true tie (two rows for the same email or
  -- the same phone in different spellings) is refused rather than guessed.
  IF v_match_email IS NOT NULL OR v_match_phone IS NOT NULL THEN
    v_match_count := 0;
    IF v_match_email IS NOT NULL THEN
      SELECT COUNT(*) INTO v_match_count
      FROM public.users
      WHERE is_adhoc = TRUE AND lower(email) = v_match_email;
      IF v_match_count = 1 THEN
        SELECT * INTO v_adhoc_match FROM public.users
        WHERE is_adhoc = TRUE AND lower(email) = v_match_email
        FOR UPDATE;
      END IF;
    END IF;
    IF v_match_count = 0 AND v_match_phone IS NOT NULL THEN
      SELECT COUNT(*) INTO v_match_count
      FROM public.users
      WHERE is_adhoc = TRUE AND internal.normalize_phone_10(phone) = v_match_phone;
      IF v_match_count = 1 THEN
        SELECT * INTO v_adhoc_match FROM public.users
        WHERE is_adhoc = TRUE AND internal.normalize_phone_10(phone) = v_match_phone
        FOR UPDATE;
      END IF;
    END IF;

    IF v_match_count > 1 THEN
      IF v_is_service THEN
        RAISE EXCEPTION 'More than one ad-hoc customer matches this email or phone; pass p_adhoc_id';
      END IF;
      RAISE EXCEPTION 'More than one staff-created customer record matches this account; please contact support';
    ELSIF v_match_count = 1 THEN
      UPDATE public.users
      SET id         = p_auth_uid,
          is_adhoc   = FALSE,
          email      = COALESCE(v_write_email, email),
          phone      = COALESCE(v_write_phone, phone),
          first_name = COALESCE(v_first_name, first_name),
          last_name  = COALESCE(v_last_name, last_name),
          updated_at = now()
      WHERE id = v_adhoc_match.id
      RETURNING * INTO v_user;

      RETURN v_user;
    END IF;
    -- v_match_count = 0 → fall through.
  END IF;

  ---------------------------------------------------------------------------
  -- Collision check: non-adhoc row with same email/phone.
  ---------------------------------------------------------------------------
  IF v_match_email IS NOT NULL OR v_match_phone IS NOT NULL THEN
    SELECT id INTO v_collision
    FROM public.users
    WHERE is_adhoc = FALSE
      AND id <> p_auth_uid
      AND (
        (v_match_email IS NOT NULL AND lower(email) = v_match_email) OR
        (v_match_phone IS NOT NULL AND internal.normalize_phone_10(phone) = v_match_phone)
      )
    LIMIT 1;

    IF v_collision IS NOT NULL THEN
      RAISE EXCEPTION 'Another account already exists with this email or phone'
        USING ERRCODE = 'unique_violation';
    END IF;
  END IF;

  ---------------------------------------------------------------------------
  -- Fresh insert.
  ---------------------------------------------------------------------------
  INSERT INTO public.users (
    id, email, phone, first_name, last_name,
    wallet_balance, notifications_enabled, is_adhoc
  ) VALUES (
    p_auth_uid, v_write_email, v_write_phone, v_first_name, v_last_name,
    0, TRUE, FALSE
  )
  RETURNING * INTO v_user;

  RETURN v_user;
END;
$function$;

-- Grants: authenticated + service_role. Revoke from anon and PUBLIC.
REVOKE ALL ON FUNCTION public.claim_adhoc_user(uuid, text, text, text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_adhoc_user(uuid, text, text, text, text, uuid) TO authenticated, service_role;

COMMIT;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- 1. Signature changed (expect 6 args):
--      SELECT pg_get_function_arguments(oid) FROM pg_proc WHERE proname = 'claim_adhoc_user';
--
-- 2. anon cannot execute (expect f):
--      SELECT has_function_privilege('anon',
--        'public.claim_adhoc_user(uuid,text,text,text,text,uuid)', 'EXECUTE');
--
-- 3. authenticated can execute (expect t):
--      SELECT has_function_privilege('authenticated',
--        'public.claim_adhoc_user(uuid,text,text,text,text,uuid)', 'EXECUTE');
--
-- 4. Phone normalisation (expect '9876543210'):
--      SELECT internal.normalize_phone_10('+91-98765-43210');
--      SELECT internal.normalize_phone_10('919876543210');
--
-- 5. Attacker spoofing blocked (ad-hoc row should NOT be claimed):
--    -- setup:
--    INSERT INTO public.users (id, email, phone, wallet_balance, is_adhoc)
--    VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', NULL, '9876500001', 500, true);
--    -- attacker with email-only JWT tries to claim via phone spoofing:
--    SET request.jwt.claims = '{"sub":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","role":"authenticated","email":"attacker@x.com"}';
--    SELECT public.claim_adhoc_user('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', NULL, '9876500001', 'Attacker', NULL);
--    -- attacker gets a fresh row; victim row still is_adhoc:
--    SELECT id, email, phone, is_adhoc FROM public.users ORDER BY created_at;
--    -- cleanup:
--    DELETE FROM public.users WHERE id IN ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
