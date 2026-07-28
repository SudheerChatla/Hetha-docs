# Database Refresh Runbook

How to re-sync the documentation to the **live Supabase backend**. Run this
whenever the schema, functions, policies, triggers, or cron jobs change. The
output of each step is the source of truth; `DATA_MODEL.md` is the
human-readable view of it.

Canonical generated artifacts live in this folder (`Hetha/docs/db/`). The
per-repo copies (`Hetha_app/doc-schema/*.sql`, `Hetha_admin/docs/*.sql`) are
mirrors that should match.

> **Hand-edited since the last full export (2026-07-28, money-integrity work).**
> `schema.sql`, `policies.sql`, `indexes.sql` and `functions.sql` carry manual
> notes for migrations `007`–`012`; `functions.sql` still contains the
> **pre-migration** bodies of the replaced functions, marked `[SUPERSEDED]`. Do a
> full re-export (below) when you next get the chance — the migrations in
> `docs/db/migrations/` are the authoritative source until then.

---

## Sync status

| Artifact | File | Last synced | How |
|----------|------|-------------|-----|
| Tables / columns / constraints | `schema.sql` | 2026-06-01 (+ `payment_intents` by hand 2026-07-28) | Table Editor → Copy as SQL |
| Functions / RPCs | `functions.sql` | 2026-06-01 — **stale**: 8 functions replaced + 6 new public and 15 new `internal` functions since | query (C) below |
| RLS enabled per table | (in `DATA_MODEL.md` §11) | 2026-07-28 | `pg_class.relrowsecurity` |
| RLS policy definitions | `policies.sql` | 2026-06-01 (money-path policies by hand 2026-07-28) | query (D) — `pg_policies` |
| Triggers | (in `DATA_MODEL.md` §12) | 2026-07-28 — **7 triggers now exist** (were 0) | query (E) |
| pg_cron jobs | (in `DATA_MODEL.md` §13) | 2026-06-01 | query (F) — 1 job |
| Indexes | `indexes.sql` | 2026-06-01 (+ `payment_intents`, `uq_orders_razorpay_payment_id` by hand) | query (G) |
| Grants (EXECUTE / column) | (in `DATA_MODEL.md` §11) | 2026-07-28 | query (H) below |
| Edge function | `Hetha_app/supabase/functions/razorpay/` | 2026-07-28 | in sync with repo; Razorpay keys = **test** |
| Money-path regression tests | `docs/db/tests/` | 2026-07-28 | `cd docs/db/tests && npm i && npm run verify` |

> **Important:** Supabase Table Editor → "Copy as SQL" exports **tables only**.
> It does NOT include functions, policies, triggers, indexes, or cron jobs —
> those must be pulled with the queries below.

---

## Fastest full sync (preferred)

```bash
# Complete public schema DDL: tables, constraints, indexes, functions,
# triggers, RLS policies, grants — all in one runnable file.
supabase db dump --schema public -f docs/db/schema.full.sql
# (or) pg_dump --schema-only --schema=public "postgresql://..." > docs/db/schema.full.sql
```

This single file covers everything except the items in "Not in the dump" below.

---

## Per-artifact queries (SQL Editor)

Run each, save the result into the matching file in this folder.

```sql
-- (C) functions / RPCs — full source → functions.sql
select p.proname, pg_get_function_identity_arguments(p.oid) as args,
       pg_get_functiondef(p.oid) as definition
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' order by p.proname;

-- (D) RLS policies → policies.sql
select tablename, policyname, cmd, roles, qual, with_check
from pg_policies where schemaname='public' order by tablename, policyname;

-- (E) triggers → triggers.sql
select event_object_table as table_name, trigger_name, action_timing,
       event_manipulation, action_statement
from information_schema.triggers where trigger_schema='public'
order by event_object_table, trigger_name;

-- (G) indexes → indexes.sql
select tablename, indexname, indexdef from pg_indexes
where schemaname='public' order by tablename, indexname;

-- (H) grant surface → paste the result into DATA_MODEL.md §11.
--     Expected: anon may execute ONLY quote_cart, has_permission, is_super_admin.
--     Anything else appearing for anon is a regression (see migrations 010/011 —
--     Supabase's default privileges grant EXECUTE on new public functions to
--     anon/authenticated, so every new function needs an explicit REVOKE).
select p.proname, r.rolname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
cross join (values ('anon'),('authenticated')) as r(rolname)
where n.nspname = 'public' and has_function_privilege(r.rolname, p.oid, 'EXECUTE')
order by 1, 2;

-- (H2) column grants — wallet_balance must NOT be writable by authenticated.
select has_column_privilege('authenticated','public.users','wallet_balance','UPDATE') as wallet_writable,
       has_column_privilege('authenticated','public.users','first_name','UPDATE')     as name_writable;
```

## Money paths: what to check after ANY change

The pricing, wallet and payment logic has DB-level protections that are easy to
undo by accident. After touching them:

1. Run the regression suite — it applies migrations `007`–`012` to an in-process
   Postgres and asserts 37 attack/happy-path cases:
   ```bash
   cd docs/db/tests && npm install && npm run verify
   ```
2. Run queries (H) and (H2) above against the live database.
3. Confirm the seven triggers are still attached:
   ```sql
   select c.relname, t.tgname, t.tgdeferrable from pg_trigger t
   join pg_class c on c.oid = t.tgrelid where not t.tgisinternal
   order by 1, 2;
   ```
4. Re-read `ARCHITECTURE.md#money-integrity` before adding a new write path —
   clients send ids and quantities; the database decides money.

## Not in the dump — grab separately

```sql
-- (F) pg_cron jobs → cron.sql   (these are DATA in the cron schema, not DDL)
select jobid, jobname, schedule, command, active from cron.job order by jobid;

-- extensions / storage buckets (sanity)
select extname, extversion from pg_extension order by extname;
select id, name, public from storage.buckets order by name;
```

From the **dashboard** (not SQL):

- **Edge function source:** `supabase functions download razorpay` (or copy
  `index.ts` from Dashboard → Edge Functions). Commit to
  `Hetha_app/supabase/functions/razorpay/`.
- **Edge secret names:** Dashboard → Edge Functions → Secrets. Record **names
  only** (e.g. `key_id`, `key_secret`) — never values.
- **Auth providers:** Dashboard → Authentication → Providers.

---

## After syncing

1. Update the per-repo mirrors to match the canonical files here.
2. Update `../DATA_MODEL.md` for any table/RPC/enum change.
3. Update `Hetha_admin/lib/types.ts` and `Hetha_app/lib/models/` if a shape
   changed.
4. Bump the **Last synced** dates in the table above.
5. Note the change in the dated `CHANGES_*.md` log.
