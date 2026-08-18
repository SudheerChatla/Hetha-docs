// =============================================================================
// Verification harness for migration 018 — drop users.area / pincode /
// dark_mode / language.
//
// Runs a real PostgreSQL (PGlite = Postgres compiled to WASM) in-process:
//   1. stubs the Supabase environment (roles + auth.uid())
//   2. loads the canonical schema + functions + policies
//   3. applies migrations 001-017, then 018
//   4. asserts the columns are gone, 018 is idempotent, the column-level UPDATE
//      grants still hold (wallet_balance closed, first_name open), both
//      claim_adhoc_user branches still work, and the dependent-view guard fires
//
// Usage (nothing is written to the real project — everything is in-memory):
//   cd docs/db/tests && npm install && npm run verify:018
// =============================================================================
import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..').replace(/\\/g, '/');
const read = (p) => readFileSync(p, 'utf8');
const db = new PGlite();
let failures = 0;
const ok = (m) => console.log(`  PASS  ${m}`);
const bad = (m) => { failures++; console.log(`  FAIL  ${m}`); };

await db.exec(`
  CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
  GRANT anon, authenticated, service_role TO CURRENT_USER;
  CREATE SCHEMA IF NOT EXISTS auth;
  CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
    SELECT NULLIF(COALESCE(NULLIF(current_setting('request.jwt.claims', true), ''), '{}')::jsonb ->> 'sub', '')::uuid; $$;
  CREATE OR REPLACE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$
    SELECT COALESCE(NULLIF(current_setting('request.jwt.claims', true), ''), '{}')::jsonb ->> 'role'; $$;
`);

await db.exec(
  read(`${ROOT}/schema.sql`)
    .replace(/^\s*CONSTRAINT\s+\S+\s+FOREIGN KEY[^\n]*\n/gm, '')
    .replace(/,(\s*)\)/g, '$1)')
);
await db.exec(`
  CREATE TABLE IF NOT EXISTS public.daily_ops_runs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    delivery_date date UNIQUE NOT NULL, status text NOT NULL DEFAULT 'draft',
    generated_by uuid, generated_at timestamptz, finalized_by uuid,
    finalized_at timestamptz, reconciled_at timestamptz, total_orders integer,
    total_value numeric, wallet_deduction_completed_at timestamptz,
    updated_at timestamptz DEFAULT now());
  GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
  GRANT ALL ON ALL TABLES IN SCHEMA public TO anon, authenticated, service_role;
`);
await db.exec(read(`${ROOT}/functions.sql`));
try { await db.exec(read(`${ROOT}/policies.sql`)); } catch { /* partial */ }

// The snapshots are now post-018, so the four columns are absent here. Re-add
// them BEFORE the migration loop, so migration 009's column-level GRANT (which
// names area/pincode/dark_mode/language) applies exactly as it did live, and so
// 018 performs a real drop rather than a no-op.
await db.exec(`ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS area text,
  ADD COLUMN IF NOT EXISTS pincode text,
  ADD COLUMN IF NOT EXISTS dark_mode boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS language text DEFAULT 'en'`);

for (const f of readdirSync(`${ROOT}/migrations`).filter((f) => /^0(0|1[0-7])/.test(f) && f.endsWith('.sql')).sort()) {
  try { await db.exec(read(`${ROOT}/migrations/${f}`)); } catch { /* already-applied bits */ }
}
console.log('baseline loaded (schema + functions + migrations 001-017)\n');

const before = await db.query(
  `SELECT count(*)::int AS n FROM information_schema.columns
    WHERE table_schema='public' AND table_name='users'
      AND column_name IN ('area','pincode','dark_mode','language')`
);
before.rows[0].n === 4 ? ok('all four columns present before 018') : bad(`expected 4 columns, got ${before.rows[0].n}`);

// Migration 009 must have taken effect, otherwise the grant assertions below
// would pass or fail for the wrong reason.
const pre = await db.query(
  `SELECT has_column_privilege('authenticated','public.users','wallet_balance','UPDATE') AS wallet`
);
pre.rows[0].wallet === false
  ? ok('migration 009 applied: wallet_balance not writable before 018')
  : bad('migration 009 did not apply — grant assertions below are meaningless');

// --- run 018 -----------------------------------------------------------------
try {
  await db.exec(read(`${ROOT}/migrations/018_drop_legacy_user_columns.sql`));
  ok('018 applied without error');
} catch (e) {
  bad(`018 failed: ${e.message}`);
}

const after = await db.query(
  `SELECT string_agg(column_name, ', ' ORDER BY ordinal_position) AS cols
     FROM information_schema.columns
    WHERE table_schema='public' AND table_name='users'`
);
console.log(`  users columns now: ${after.rows[0].cols}`);
/(area|pincode|dark_mode|language)/.test(after.rows[0].cols)
  ? bad('a dropped column is still present')
  : ok('none of the four remain');

// --- idempotency -------------------------------------------------------------
try {
  await db.exec(read(`${ROOT}/migrations/018_drop_legacy_user_columns.sql`));
  ok('018 is idempotent (second run clean)');
} catch (e) {
  bad(`second run failed: ${e.message}`);
}

// --- grant surface -----------------------------------------------------------
const g = await db.query(
  `SELECT has_column_privilege('authenticated','public.users','wallet_balance','UPDATE') AS wallet,
          has_column_privilege('authenticated','public.users','first_name','UPDATE')     AS name,
          has_column_privilege('authenticated','public.users','notifications_enabled','UPDATE') AS notif`
);
const { wallet, name, notif } = g.rows[0];
wallet === false ? ok('wallet_balance still NOT writable by authenticated') : bad('wallet_balance became writable');
name === true && notif === true ? ok('first_name + notifications_enabled still writable') : bad('lost a needed column grant');

// --- claim_adhoc_user: the function that named the dropped columns -----------
const ADHOC = '99999999-9999-4999-8999-999999999999';
const AUTH  = '88888888-8888-4888-8888-888888888888';
const NEW   = '77777777-7777-4777-8777-777777777777';

await db.exec(`INSERT INTO public.users (id, email, phone, first_name, wallet_balance, is_adhoc)
               VALUES ('${ADHOC}', 'walkin@example.com', '9111111111', 'Walk', 250, true)`);
await db.exec(`SELECT set_config('request.jwt.claims',
               '{"sub":"${AUTH}","role":"authenticated","email":"walkin@example.com"}', false)`);
try {
  const r = await db.query(`SELECT (public.claim_adhoc_user($1, 'walkin@example.com', NULL, 'Walk', 'In')).*`, [AUTH]);
  const row = r.rows[0];
  row.id === AUTH && row.is_adhoc === false && Number(row.wallet_balance) === 250
    ? ok('claim branch works: row re-keyed, is_adhoc cleared, wallet preserved')
    : bad(`claim branch returned ${JSON.stringify(row)}`);
} catch (e) {
  bad(`claim branch: ${e.message}`);
}

await db.exec(`SELECT set_config('request.jwt.claims',
               '{"sub":"${NEW}","role":"authenticated","email":"fresh@example.com"}', false)`);
try {
  const r = await db.query(`SELECT (public.claim_adhoc_user($1, 'fresh@example.com', NULL, 'Fresh', 'User')).*`, [NEW]);
  const row = r.rows[0];
  row.id === NEW && row.notifications_enabled === true && row.is_adhoc === false
    ? ok('insert branch works: new row with notifications_enabled=true, is_adhoc=false')
    : bad(`insert branch returned ${JSON.stringify(row)}`);
} catch (e) {
  bad(`insert branch: ${e.message}`);
}

// --- the pre-flight guard actually fires ------------------------------------
await db.exec(`ALTER TABLE public.users ADD COLUMN area text`);
await db.exec(`CREATE VIEW public.v_probe_dep AS SELECT id, area FROM public.users`);
try {
  await db.exec(read(`${ROOT}/migrations/018_drop_legacy_user_columns.sql`));
  bad('guard did NOT fire for a dependent view');
} catch (e) {
  /v_probe_dep/.test(e.message)
    ? ok(`guard fired and named the view: ${e.message.split('\n')[0].slice(0, 110)}...`)
    : bad(`aborted, but message did not name the view: ${e.message}`);
}
await db.exec(`ROLLBACK`).catch(() => {});
await db.exec(`DROP VIEW IF EXISTS public.v_probe_dep`);

console.log(`\n${failures === 0 ? 'ALL CHECKS PASSED' : `${failures} CHECK(S) FAILED`}`);
process.exit(failures === 0 ? 0 : 1);
