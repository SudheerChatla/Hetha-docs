-- Migration 023: register_device_token RPC (fixes cross-account push leakage)
--
-- Run in: Supabase SQL Editor
--
-- ─── Problem ────────────────────────────────────────────────────────────────
-- On a shared/reused device, logging out of account A and into account B could
-- leave B still receiving A's push notifications (wallet debits, order status,
-- promotional pushes, etc.) — a real cross-account information leak.
--
-- Root cause: device_tokens' uniqueness is on (user_id, fcm_token), not on
-- fcm_token alone. The customer app never called unregisterToken() on logout
-- (Hetha_app/lib/screens/profile/profile_page.dart calls
-- supabase.auth.signOut() directly, bypassing NotificationService), and never
-- re-registered the token on a fresh login (NotificationService.initialize()
-- — the only thing that calls registerToken() — runs once at process start).
-- So account A's device_tokens row for this token just sits there forever,
-- and FCM delivers by token, not by "whoever is currently logged in" — so A's
-- pushes keep landing on the phone regardless of who is signed in.
--
-- The client-side fix (delete any OTHER user's row for this token before
-- upserting the caller's own) cannot work as a plain client call: the
-- device_tokens RLS policy is `USING (auth.uid() = user_id)` — a signed-in
-- user has no permission to see or delete a different user's row, even for
-- the token physically sitting in their own hands. The cleanup has to run
-- with elevated privilege.
--
-- ─── Fix ──────────────────────────────────────────────────────────────────
-- public.register_device_token(p_token, p_platform), SECURITY DEFINER:
--   1. Deletes every device_tokens row for this exact fcm_token that belongs
--      to a DIFFERENT user (releasing the token from whoever had it before).
--   2. Upserts the caller's own row for (auth.uid(), p_token).
-- Called on every app start / token refresh / successful sign-in, so the
-- moment a new account signs in on a device, that device's token stops being
-- reachable under the old account — self-healing regardless of how the
-- previous session ended (explicit logout, app kill, crash, token expiry).
--
-- The customer app change (registerToken() calling this RPC instead of a raw
-- upsert, and being called again right after sign-in, not just at process
-- start) ships alongside this migration.

CREATE OR REPLACE FUNCTION public.register_device_token(p_token text, p_platform text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF p_token IS NULL OR length(trim(p_token)) = 0 THEN
    RAISE EXCEPTION 'Device token is required';
  END IF;

  IF p_platform NOT IN ('android', 'ios') THEN
    RAISE EXCEPTION 'Invalid platform: %', p_platform;
  END IF;

  -- Release this token from any other account before claiming it. Without
  -- this, a token can end up rows deep under several old accounts on a
  -- shared device, and FCM will happily deliver to all of them.
  DELETE FROM public.device_tokens
  WHERE fcm_token = p_token
    AND user_id <> auth.uid();

  INSERT INTO public.device_tokens (user_id, fcm_token, platform, updated_at)
  VALUES (auth.uid(), p_token, p_platform, now())
  ON CONFLICT (user_id, fcm_token)
  DO UPDATE SET platform = EXCLUDED.platform, updated_at = EXCLUDED.updated_at;
END;
$function$;

REVOKE ALL ON FUNCTION public.register_device_token(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_device_token(text, text) TO authenticated, service_role;

-- ─── Backfill note ──────────────────────────────────────────────────────────
-- This migration does not retroactively delete existing stale rows (it has no
-- way to know which token is still physically on which device). They will be
-- cleaned up the next time each device registers/refreshes its token, which
-- happens automatically on every app start. If you want to force it sooner,
-- the safest broad cleanup is to drop rows unrefreshed for a long time:
--
--   DELETE FROM public.device_tokens WHERE updated_at < now() - interval '90 days';
--
-- Run that manually only if you're comfortable with the tradeoff (a device
-- that hasn't opened the app in 90+ days stops receiving push until it does).
