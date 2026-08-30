-- Migration 019: Make user-facing timestamps timezone-aware
--
-- Problem
-- -------
-- `notifications.created_at`, `notifications.sent_at` and
-- `wallet_transactions.created_at` were declared `timestamp without time zone`.
-- PostgREST serialises such a column with no `Z`/offset suffix
-- (e.g. "2026-08-27T16:15:00" instead of "2026-08-27T16:15:00Z"), so
-- `DateTime.parse()` in the Flutter client treats an already-UTC value as if it
-- were local wall-clock time. In IST that renders every notification 5h30m off,
-- which is what the notification inbox was showing.
--
-- The wallet page had already hit this and carried a client-side workaround
-- (appending "Z" when no offset is present). This migration removes the need
-- for that workaround by fixing the column types at the source, so every client
-- gets an unambiguous instant.
--
-- Safety
-- ------
-- These columns are populated by `now()` under a database session whose
-- TimeZone is UTC (Supabase default), so the stored wall-clock values are
-- already UTC. `AT TIME ZONE 'UTC'` therefore reinterprets them without
-- shifting any instant — existing rows keep the moment they always meant.
-- The conversion is a metadata + rewrite operation on the table; it takes an
-- ACCESS EXCLUSIVE lock for the duration, so run it off-peak. No data is lost
-- and no values are re-pointed.
--
-- `read_at` on notifications and `created_at`/`updated_at` on device_tokens are
-- already `timestamptz` and are deliberately left alone.

BEGIN;

-- 1. notifications.created_at — drives the "2h ago" label in the inbox.
ALTER TABLE public.notifications
  ALTER COLUMN created_at TYPE timestamptz
    USING created_at AT TIME ZONE 'UTC';

ALTER TABLE public.notifications
  ALTER COLUMN created_at SET DEFAULT now();

-- 2. notifications.sent_at — same table, same class of bug; kept consistent so
--    a future feature reading it can't reintroduce the offset.
ALTER TABLE public.notifications
  ALTER COLUMN sent_at TYPE timestamptz
    USING sent_at AT TIME ZONE 'UTC';

-- 3. wallet_transactions.created_at — drives the wallet history timestamps.
ALTER TABLE public.wallet_transactions
  ALTER COLUMN created_at TYPE timestamptz
    USING created_at AT TIME ZONE 'UTC';

ALTER TABLE public.wallet_transactions
  ALTER COLUMN created_at SET DEFAULT now();

COMMIT;

-- Note: idx_notifications_user_created (user_id, created_at DESC) is rebuilt
-- automatically by the type change; no separate reindex is required.
