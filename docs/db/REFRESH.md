# Database Refresh Runbook

How to re-sync the documentation to the **live Supabase backend**. Run this
whenever the schema, functions, policies, triggers, or cron jobs change. The
output of each step is the source of truth; `DATA_MODEL.md` is the
human-readable view of it.

Canonical generated artifacts live in this folder (`Hetha/docs/db/`). The
per-repo copies (`Hetha_app/doc-schema/*.sql`, `Hetha_admin/docs/*.sql`) are
mirrors that should match.

---

## Sync status

| Artifact | File | Last synced | How |
|----------|------|-------------|-----|
| Tables / columns / constraints | `schema.sql` | 2026-06-01 | Table Editor → Copy as SQL |
| Functions / RPCs | `functions.sql` | 2026-06-01 | query (C) below |
| RLS enabled per table | (in `DATA_MODEL.md` §11) | 2026-06-01 | `pg_class.relrowsecurity` |
| RLS policy definitions | `policies.sql` | 2026-06-01 | query (D) — `pg_policies` |
| Triggers | (none — `DATA_MODEL.md` §12) | 2026-06-01 | query (E) — returned 0 rows |
| pg_cron jobs | (in `DATA_MODEL.md` §13) | 2026-06-01 | query (F) — 1 job |
| Indexes | `indexes.sql` | 2026-06-01 | query (G) |
| Edge function | `Hetha_app/supabase/functions/razorpay/` | 2026-06-01 | in sync with repo; Razorpay keys = **test** |

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
```

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
