// =============================================================================
// Local verification harness for the Hetha money-integrity migrations.
//
// Runs a real PostgreSQL (PGlite = Postgres compiled to WASM) in-process:
//   1. stubs the Supabase environment (roles + auth.uid()/request.jwt.claims)
//   2. loads the canonical schema
//   3. applies migrations 007 / 008 / 009
//   4. runs attack tests that should now FAIL and happy paths that should PASS
//
// Usage (nothing is written to the real project — everything is in-memory):
//   npm init -y && npm install @electric-sql/pglite
//   node verify_money_integrity.mjs
//
// Adjust ROOT below if you run it from a different directory.
// =============================================================================
import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..').replace(/\\/g, '/');
const read = (p) => readFileSync(p, 'utf8');

const db = new PGlite();

let pass = 0, fail = 0;
const ok = (name) => { pass++; console.log(`  PASS  ${name}`); };
const bad = (name, detail) => { fail++; console.log(`  FAIL  ${name}\n        ${detail}`); };

async function expectError(name, fn, matcher) {
  try {
    await fn();
    bad(name, 'expected an error, but the statement succeeded');
  } catch (e) {
    if (matcher && !new RegExp(matcher, 'i').test(e.message)) {
      bad(name, `error did not match /${matcher}/: ${e.message}`);
    } else {
      ok(`${name}  →  rejected: ${e.message.split('\n')[0]}`);
    }
  }
}

async function expectOk(name, fn) {
  try {
    const r = await fn();
    ok(name);
    return r;
  } catch (e) {
    bad(name, e.message);
    return null;
  }
}

// ---------------------------------------------------------------------------
// 1. Supabase-ish environment
// ---------------------------------------------------------------------------
await db.exec(`
  CREATE ROLE anon;
  CREATE ROLE authenticated;
  CREATE ROLE service_role;
  GRANT anon, authenticated, service_role TO CURRENT_USER;

  CREATE SCHEMA IF NOT EXISTS auth;

  -- Mirrors Supabase's auth.uid()/auth.role() helpers.
  CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
    SELECT NULLIF(COALESCE(NULLIF(current_setting('request.jwt.claims', true), ''), '{}')::jsonb ->> 'sub', '')::uuid;
  $$;
  CREATE OR REPLACE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$
    SELECT COALESCE(NULLIF(current_setting('request.jwt.claims', true), ''), '{}')::jsonb ->> 'role';
  $$;
`);

// Act as a given caller for one statement. The claims are cleared afterwards,
// so plain db.query / db.exec setup writes run as the SQL Editor (no claims,
// jwt role 'internal'), never as whoever was called last. Migration 038's
// finalized-day lock refuses direct writes from any other caller.
async function as(claims, sql) {
  const json = claims === null ? '' : JSON.stringify(claims);
  await db.exec(`SELECT set_config('request.jwt.claims', '${json.replace(/'/g, "''")}', false);`);
  try { return await db.exec(sql); }
  finally { await db.exec(`SELECT set_config('request.jwt.claims', '', false);`); }
}
async function asQuery(claims, sql, params) {
  const json = claims === null ? '' : JSON.stringify(claims);
  await db.query(`SELECT set_config('request.jwt.claims', $1, false)`, [json]);
  try { return await db.query(sql, params); }
  finally { await db.query(`SELECT set_config('request.jwt.claims', '', false)`); }
}

// ---------------------------------------------------------------------------
// 2. Canonical schema
//    schema.sql is an alphabetically ordered dump, so inline FOREIGN KEYs point
//    at tables that don't exist yet. They're irrelevant to the money logic under
//    test, so strip them for the harness.
// ---------------------------------------------------------------------------
const schema = read(`${ROOT}/schema.sql`)
  .replace(/^\s*CONSTRAINT\s+\S+\s+FOREIGN KEY[^\n]*\n/gm, '')
  .replace(/,(\s*)\)/g, '$1)');
await db.exec(schema);
console.log('schema.sql loaded');

// Baseline objects the migrations touch that live in earlier migrations.
await db.exec(`
  CREATE TABLE IF NOT EXISTS public.daily_ops_runs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    delivery_date date UNIQUE NOT NULL,
    status text NOT NULL DEFAULT 'draft',
    generated_by uuid, generated_at timestamptz,
    finalized_by uuid, finalized_at timestamptz,
    reconciled_at timestamptz, reconciled_by uuid,
    total_orders integer, total_value numeric,
    wallet_deduction_completed_at timestamptz,
    updated_at timestamptz DEFAULT now()
  );
`);

// RBAC helpers + the pre-existing functions the migrations replace.
// `get_user_role` was LANGUAGE sql referencing columns that don't exist, so
// Postgres validates its body at CREATE time and it would fail to load. It has
// been removed from functions.sql (dropped by migration 013), so normally there
// is nothing to strip — but strip it defensively in case an older snapshot is
// used. `\r?\n` because the working tree may have CRLF endings on Windows.
const functions = read(`${ROOT}/functions.sql`);
const functionsWithoutBroken = functions.replace(
  /CREATE OR REPLACE FUNCTION public\.get_user_role[\s\S]*?\$function\$;\r?\n/m, '');
await db.exec(functionsWithoutBroken);
console.log('functions.sql loaded (pre-migration baseline)');

// Supabase's default table/function grants. Crucially this mirrors the real
// project's ALTER DEFAULT PRIVILEGES, so functions created by the migrations
// below inherit an EXPLICIT grant to anon/authenticated — which is exactly what
// migration 010 has to revoke.
await db.exec(`
  GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
  GRANT ALL ON ALL TABLES IN SCHEMA public TO anon, authenticated, service_role;
  GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO anon, authenticated, service_role;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;
`);

// ---------------------------------------------------------------------------
// 3. Seed data
// ---------------------------------------------------------------------------
const CUSTOMER = '11111111-1111-4111-8111-111111111111';
const OTHER    = '22222222-2222-4222-8222-222222222222';
const CAT      = '33333333-3333-4333-8333-333333333333';
const PROD     = '44444444-4444-4444-8444-444444444444';
const VAR      = '55555555-5555-4555-8555-555555555555';
const ADDR     = '66666666-6666-4666-8666-666666666666';

await db.exec(`
  INSERT INTO public.users (id, email, phone, first_name, wallet_balance)
  VALUES ('${CUSTOMER}', 'cust@example.com', '9000000001', 'Cust', 5000),
         ('${OTHER}',    'other@example.com','9000000002', 'Other', 5000);

  INSERT INTO public.categories (id, name) VALUES ('${CAT}', 'Dairy');
  -- all_india: migration 024 brings the 016 local-only check into
  -- place_order_core here, and ADDR (600001) is deliberately NOT a serviceable
  -- pincode so the tier-charge assertions below keep their ₹40 fee.
  INSERT INTO public.products (id, category_id, name, in_stock, delivery_scope)
  VALUES ('${PROD}', '${CAT}', 'Cow Milk', true, 'all_india');
  INSERT INTO public.product_variants (id, product_id, label, price, weight_grams, is_active, free_delivery)
  VALUES ('${VAR}', '${PROD}', '1 L', 100, 1000, true, false);

  INSERT INTO public.addresses (id, user_id, name, phone_number, address_line1, city, state, pincode, address_type)
  VALUES ('${ADDR}', '${CUSTOMER}', 'Cust', '9000000001', '1 Main St', 'Chennai', 'TN', '600001', 'home');

  INSERT INTO public.delivery_charge_tiers (min_weight_grams, max_weight_grams, charge)
  VALUES (1, 1000, 40), (1001, 5000, 60);
`);

// ---------------------------------------------------------------------------
// 4. Pre-migration exploit demonstration
//    Only meaningful while functions.sql still holds the PRE-migration bodies.
//    Once that snapshot is re-exported from the live (hardened) database, these
//    calls either behave correctly or fail because the `internal` schema does
//    not exist yet — so treat the whole block as best-effort.
// ---------------------------------------------------------------------------
console.log('\n--- BEFORE the migrations (documenting the vulnerabilities) ---');

try {
  const before = await asQuery({ sub: CUSTOMER, role: 'authenticated' },
    `SELECT public.place_order($1,$2,'wallet',0,$3::jsonb) AS id`,
    [CUSTOMER, ADDR, JSON.stringify([{ variant_id: VAR, quantity: 1 }])]);
  const beforeOrder = await db.query(
    `SELECT subtotal, delivery_charge, total FROM public.orders WHERE id = $1`,
    [before.rows[0].id]);
  console.log('  delivery_charge = 0 accepted by old place_order →', JSON.stringify(beforeOrder.rows[0]));

  const beforeSub = await asQuery({ sub: CUSTOMER, role: 'authenticated' },
    `SELECT public.create_subscription($1, now(), NULL, 'active', $2::jsonb, $3::jsonb, 'Home') AS id`,
    [CUSTOMER, JSON.stringify({ pincode: '600001', name: 'Cust' }),
     JSON.stringify([{ variantId: VAR, name: 'Cow Milk', variant: '1 L', price: 0.01, quantity: 1, startDate: '2026-07-28' }])]);
  const beforeItems = await db.query(
    `SELECT unit_price FROM public.subscription_items WHERE subscription_id = $1`,
    [beforeSub.rows[0].id]);
  console.log('  client price 0.01 accepted by old create_subscription →', JSON.stringify(beforeItems.rows[0]));
} catch (e) {
  console.log('  (skipped: functions.sql is a POST-migration export — ' +
              `${e.message.split('\n')[0]})`);
}

// Clean the demo rows so the post-migration assertions start from a known state.
await db.exec(`
  DELETE FROM public.order_tracking; DELETE FROM public.order_items; DELETE FROM public.orders;
  DELETE FROM public.wallet_transactions; DELETE FROM public.subscription_items; DELETE FROM public.subscriptions;
  UPDATE public.users SET wallet_balance = 5000;
`);

// ---------------------------------------------------------------------------
// 5. Apply the migrations
// ---------------------------------------------------------------------------
for (const f of ['007_money_integrity.sql', '008_payment_intents.sql', '009_privilege_lockdown.sql',
                 '010_grant_hardening.sql', '011_legacy_function_grants.sql',
                 '012_money_invariants.sql',
                 '013_fix_cancel_subscription_and_drop_get_user_role.sql',
                 '015_pin_search_path.sql',
                 '022_customer_daily_order_rpcs.sql',
                 '023_register_device_token_rpc.sql',
                 '024_free_delivery_serviceable_pincodes.sql',
                 '025_day_edit_wallet_rule_and_subscription_scope.sql',
                 '026_revert_daily_order_per_subscription.sql',
                 '027_bulk_modify_daily_orders.sql',
                 '028_product_archive_and_safe_delete.sql',
                 '029_trim_product_names.sql',
                 '030_cancel_subscription_cleanup.sql',
                 '031_drop_2arg_revert_daily_order.sql',
                 '032_claim_adhoc_user_hardening.sql',
                 '033_route_per_address_and_delivery_dates.sql',
                 '034_reschedule_order_snaps_to_delivery_day.sql',
                 '035_order_tracking_user_id.sql',
                 '036_subscription_cutoff_rule.sql',
                 '037_daily_order_settlement.sql',
                 '038_daily_ops_structure.sql',
                 '039_wallet_simplification.sql',
                 '040_indexes.sql',
                 '041_dashboard_stats.sql']) {
  try {
    await db.exec(read(`${ROOT}/migrations/${f}`));
    console.log(`\napplied ${f}`);
  } catch (e) {
    console.log(`\nFAILED to apply ${f}: ${e.message}`);
    process.exit(1);
  }
}

// ---------------------------------------------------------------------------
// 6. Post-migration assertions
// ---------------------------------------------------------------------------
console.log('\n--- AFTER the migrations ---');

const CART = JSON.stringify([{ variant_id: VAR, quantity: 1 }]);

// 6a. quote_cart is authoritative: 100 goods + 40 tier charge.
const q = await asQuery({ sub: CUSTOMER, role: 'authenticated' },
  `SELECT public.quote_cart($1::jsonb) AS q`, [CART]);
if (q.rows[0].q.subtotal === 100 && q.rows[0].q.delivery_charge === 40 && q.rows[0].q.total === 140) {
  ok(`quote_cart returns server-computed totals ${JSON.stringify(q.rows[0].q)}`);
} else {
  bad('quote_cart totals', JSON.stringify(q.rows[0].q));
}

// 6b. Delivery-charge tampering is ignored.
const tampered = await asQuery({ sub: CUSTOMER, role: 'authenticated' },
  `SELECT public.place_order($1,$2,'wallet',0,$3::jsonb) AS id`, [CUSTOMER, ADDR, CART]);
const row = await db.query(
  `SELECT subtotal, delivery_charge, total, payment_status FROM public.orders WHERE id = $1`,
  [tampered.rows[0].id]);
if (Number(row.rows[0].delivery_charge) === 40 && Number(row.rows[0].total) === 140) {
  ok(`p_delivery_charge = 0 ignored; server charged ${JSON.stringify(row.rows[0])}`);
} else {
  bad('delivery charge tampering', JSON.stringify(row.rows[0]));
}

// 6c. Negative delivery charge cannot mint wallet money.
const balAfter = await db.query(`SELECT wallet_balance FROM public.users WHERE id = $1`, [CUSTOMER]);
await asQuery({ sub: CUSTOMER, role: 'authenticated' },
  `SELECT public.place_order($1,$2,'wallet',-100000,$3::jsonb) AS id`, [CUSTOMER, ADDR, CART]);
const balAfter2 = await db.query(`SELECT wallet_balance FROM public.users WHERE id = $1`, [CUSTOMER]);
if (Number(balAfter2.rows[0].wallet_balance) === Number(balAfter.rows[0].wallet_balance) - 140) {
  ok(`negative p_delivery_charge ignored (balance ${balAfter.rows[0].wallet_balance} → ${balAfter2.rows[0].wallet_balance})`);
} else {
  bad('negative delivery charge', `balance went ${balAfter.rows[0].wallet_balance} → ${balAfter2.rows[0].wallet_balance}`);
}

// 6d. Negative / fractional quantities rejected.
await expectError('negative quantity rejected', () => asQuery({ sub: CUSTOMER, role: 'authenticated' },
  `SELECT public.place_order($1,$2,'wallet',40,$3::jsonb)`,
  [CUSTOMER, ADDR, JSON.stringify([{ variant_id: VAR, quantity: -5 }])]), 'whole number');

// 6e. Placing an order for someone else rejected.
await expectError('cross-user place_order rejected', () => asQuery({ sub: OTHER, role: 'authenticated' },
  `SELECT public.place_order($1,$2,'wallet',40,$3::jsonb)`, [CUSTOMER, ADDR, CART]), 'not authorized');

// 6f. Direct wallet credit RPC rejected for customers.
await expectError('update_wallet_balance blocked for customer', () => asQuery({ sub: CUSTOMER, role: 'authenticated' },
  `SELECT public.update_wallet_balance($1::uuid, 100000::numeric, 'credit'::text, 'hack'::text, 'user'::text)`,
  [CUSTOMER]), 'not authorized');

// …and allowed for an admin with customers:edit (proves the admin panel path
// still works through the same wrapper).
await db.exec(`
  INSERT INTO public.roles (id, role) VALUES (gen_random_uuid(), 'ops')
  ON CONFLICT DO NOTHING;
`);
const roleId = (await db.query(`SELECT id FROM public.roles WHERE role = 'ops'`)).rows[0].id;
const ADMIN = '88888888-8888-4888-8888-888888888888';
await db.query(
  `INSERT INTO public.admin_users (id, user_id, role_id, admin_name, is_active) VALUES (gen_random_uuid(), $1, $2, 'Ops Admin', true)`,
  [ADMIN, roleId]);
await db.query(
  `INSERT INTO public.admin_role_permissions (role_id, permission) VALUES ($1, 'customers:edit')`,
  [roleId]);
await expectOk('admin with customers:edit can still adjust a wallet', () => asQuery(
  { sub: ADMIN, role: 'authenticated' },
  `SELECT public.update_wallet_balance($1::uuid, 10::numeric, 'credit'::text, 'goodwill'::text, 'admin'::text)`,
  [CUSTOMER]));

// 6g. wallet_balance column is not writable by `authenticated`.
const canWrite = await db.query(
  `SELECT has_column_privilege('authenticated', 'public.users', 'wallet_balance', 'UPDATE') AS w,
          has_column_privilege('authenticated', 'public.users', 'first_name',     'UPDATE') AS n`);
if (canWrite.rows[0].w === false && canWrite.rows[0].n === true) {
  ok('authenticated cannot UPDATE users.wallet_balance (but can still edit first_name)');
} else {
  bad('users column grants', JSON.stringify(canWrite.rows[0]));
}

// 6h. Subscription price tampering ignored.
const sub = await asQuery({ sub: CUSTOMER, role: 'authenticated' },
  `SELECT public.create_subscription($1, now(), NULL, 'active', $2::jsonb, $3::jsonb, 'Home') AS id`,
  [CUSTOMER, JSON.stringify({ pincode: '600001', name: 'Cust', phoneNumber: '9000000001' }),
   JSON.stringify([{ variantId: VAR, name: 'x', variant: 'y', price: 0.01, quantity: 1, startDate: '2026-07-28' }])]);
const subItems = await db.query(
  `SELECT unit_price, product_name_snapshot FROM public.subscription_items WHERE subscription_id = $1`,
  [sub.rows[0].id]);
if (Number(subItems.rows[0].unit_price) === 100) {
  ok(`create_subscription used catalog price ${subItems.rows[0].unit_price} (client sent 0.01)`);
} else {
  bad('subscription price tampering', JSON.stringify(subItems.rows[0]));
}

// 6i. Wallet reserve enforced server-side (migration 039: the next delivery of
//     each subscription; commitment 100/day → 100 kept; order 140 + 100 = 240
//     needed, balance 200 → refused).
await db.exec(`UPDATE public.users SET wallet_balance = 200 WHERE id = '${CUSTOMER}'`);
await expectError('next-delivery subscription reserve enforced', () => asQuery({ sub: CUSTOMER, role: 'authenticated' },
  `SELECT public.place_order($1,$2,'wallet',40,$3::jsonb)`, [CUSTOMER, ADDR, CART]), 'next delivery');
await db.exec(`UPDATE public.users SET wallet_balance = 5000 WHERE id = '${CUSTOMER}'`);

// 6j. Online-payment orders cannot be self-declared as placed.
const rzp = await asQuery({ sub: CUSTOMER, role: 'authenticated' },
  `SELECT public.place_order($1,$2,'razorpay',40,$3::jsonb) AS id`, [CUSTOMER, ADDR, CART]);
const rzpRow = await db.query(`SELECT status, payment_status FROM public.orders WHERE id = $1`, [rzp.rows[0].id]);
if (rzpRow.rows[0].status === 'payment_pending' && rzpRow.rows[0].payment_status === 'pending') {
  ok('customer-created razorpay order parked in payment_pending');
} else {
  bad('razorpay order status', JSON.stringify(rzpRow.rows[0]));
}

// 6k. Payment intents: amount comes from the catalog, replay is idempotent.
await expectError('create_payment_intent blocked for customer', () => asQuery({ sub: CUSTOMER, role: 'authenticated' },
  `SELECT public.create_payment_intent($1, 'order', NULL, $2, $3::jsonb)`, [CUSTOMER, ADDR, CART]), 'server-side');

const intent = await asQuery({ role: 'service_role' },
  `SELECT public.create_payment_intent($1, 'order', NULL, $2, $3::jsonb) AS i`, [CUSTOMER, ADDR, CART]);
const intentId = intent.rows[0].i.intent_id;
if (Number(intent.rows[0].i.amount_paise) === 14000) {
  ok('order intent priced server-side at 14000 paise (₹140)');
} else {
  bad('intent amount', JSON.stringify(intent.rows[0].i));
}

await asQuery({ role: 'service_role' },
  `SELECT public.attach_razorpay_order($1, 'order_TEST1')`, [intentId]);

// Underpayment (the "pay ₹1 for a ₹140 order" attack) must be refused.
await expectError('underpaid order settlement refused', () => asQuery({ role: 'service_role' },
  `SELECT public.finalize_order_payment($1, 'order_TEST1', 'pay_TEST1', 100)`, [intentId]), 'less than the order amount');

const settled = await asQuery({ role: 'service_role' },
  `SELECT public.finalize_order_payment($1, 'order_TEST1', 'pay_TEST1', 14000) AS r`, [intentId]);
const settledOrder = await db.query(
  `SELECT status, payment_status, total, razorpay_payment_id FROM public.orders WHERE id = $1`,
  [settled.rows[0].r.order_id]);
if (settledOrder.rows[0].payment_status === 'paid' && Number(settledOrder.rows[0].total) === 140) {
  ok(`fully paid order placed: ${JSON.stringify(settledOrder.rows[0])}`);
} else {
  bad('settled order', JSON.stringify(settledOrder.rows[0]));
}

const replay = await asQuery({ role: 'service_role' },
  `SELECT public.finalize_order_payment($1, 'order_TEST1', 'pay_TEST1', 14000) AS r`, [intentId]);
const orderCount = await db.query(`SELECT COUNT(*)::int AS c FROM public.orders WHERE razorpay_payment_id = 'pay_TEST1'`);
if (replay.rows[0].r.already_processed === true && orderCount.rows[0].c === 1) {
  ok('replayed order payment is idempotent (still 1 order)');
} else {
  bad('order replay', `${JSON.stringify(replay.rows[0].r)} / orders=${orderCount.rows[0].c}`);
}

// 6l. Wallet top-up credits only what Razorpay captured, once.
const topup = await asQuery({ role: 'service_role' },
  `SELECT public.create_payment_intent($1, 'wallet_topup', 50000, NULL, NULL) AS i`, [CUSTOMER]);
const topupId = topup.rows[0].i.intent_id;
await asQuery({ role: 'service_role' }, `SELECT public.attach_razorpay_order($1, 'order_TOP1')`, [topupId]);

const balBefore = (await db.query(`SELECT wallet_balance FROM public.users WHERE id = $1`, [CUSTOMER])).rows[0].wallet_balance;
// Razorpay says ₹500 was captured even though the intent asked for ₹500 —
// a client claiming ₹1,00,000 can no longer influence this number at all.
const credit1 = await asQuery({ role: 'service_role' },
  `SELECT public.finalize_wallet_topup($1, 'order_TOP1', 'pay_TOP1', 50000) AS r`, [topupId]);
const credit2 = await asQuery({ role: 'service_role' },
  `SELECT public.finalize_wallet_topup($1, 'order_TOP1', 'pay_TOP1', 50000) AS r`, [topupId]);
const balNow = (await db.query(`SELECT wallet_balance FROM public.users WHERE id = $1`, [CUSTOMER])).rows[0].wallet_balance;
if (Number(credit1.rows[0].r.credited) === 500 && credit2.rows[0].r.already_processed === true
    && Number(balNow) === Number(balBefore) + 500) {
  ok(`top-up credited ₹500 once; replay ignored (balance ${balBefore} → ${balNow})`);
} else {
  bad('wallet top-up', `${JSON.stringify(credit1.rows[0].r)} / ${JSON.stringify(credit2.rows[0].r)} / ${balBefore}→${balNow}`);
}

// Over-capping: crediting more than the intent asked for is impossible.
const topup2 = await asQuery({ role: 'service_role' },
  `SELECT public.create_payment_intent($1, 'wallet_topup', 10000, NULL, NULL) AS i`, [CUSTOMER]);
const topup2Id = topup2.rows[0].i.intent_id;
await asQuery({ role: 'service_role' }, `SELECT public.attach_razorpay_order($1, 'order_TOP2')`, [topup2Id]);
const over = await asQuery({ role: 'service_role' },
  `SELECT public.finalize_wallet_topup($1, 'order_TOP2', 'pay_TOP2', 9999999) AS r`, [topup2Id]);
if (Number(over.rows[0].r.credited) === 100) {
  ok('credit is capped at the intent amount (₹100)');
} else {
  bad('credit cap', JSON.stringify(over.rows[0].r));
}

// 6m. finalize_daily_run is permission-gated.
await expectError('finalize_daily_run blocked for customer', () => asQuery({ sub: CUSTOMER, role: 'authenticated' },
  `SELECT public.finalize_daily_run(CURRENT_DATE, $1)`, [CUSTOMER]), 'not authorized');

// 6n. Ad-hoc account claiming cannot target another identity.
await db.exec(`INSERT INTO public.users (id, email, phone, first_name, wallet_balance, is_adhoc)
               VALUES (gen_random_uuid(), 'victim@example.com', '9999999999', 'Victim', 7777, true)`);
await expectError('claim_adhoc_user identity spoofing blocked', () => asQuery(
  { sub: '77777777-7777-4777-8777-777777777777', role: 'authenticated', email: 'attacker@example.com' },
  `SELECT public.claim_adhoc_user($1, 'victim@example.com', NULL, NULL, NULL)`,
  ['77777777-7777-4777-8777-777777777777']), 'does not match');

// 6o. Unavailable products cannot be ordered.
await db.exec(`UPDATE public.products SET in_stock = false WHERE id = '${PROD}'`);
await expectError('out-of-stock item rejected', () => asQuery({ sub: CUSTOMER, role: 'authenticated' },
  `SELECT public.place_order($1,$2,'wallet',40,$3::jsonb)`, [CUSTOMER, ADDR, CART]), 'out of stock');
await db.exec(`UPDATE public.products SET in_stock = true WHERE id = '${PROD}'`);

// 6p. Every wallet movement has a matching ledger row (the harness resets
//     balances directly in places, so compare per-order instead of globally).
const ledger = await db.query(`
  SELECT o.id, o.total, wt.amount, wt.type, wt.reference_type
  FROM public.orders o
  LEFT JOIN public.wallet_transactions wt
    ON wt.reference_id = o.id AND wt.reference_type = 'order'
  WHERE o.payment_method = 'wallet'`);
const unledgered = ledger.rows.filter(
  (r) => r.amount === null || Number(r.amount) !== Number(r.total) || r.type !== 'debit');
if (ledger.rows.length > 0 && unledgered.length === 0) {
  ok(`all ${ledger.rows.length} wallet orders have a matching debit ledger row`);
} else {
  bad('ledger reconciliation', JSON.stringify(ledger.rows));
}

// 6q. An intent cannot be settled by (or on behalf of) the wrong user, and a
//     Razorpay order id can only ever back one intent.
const foreign = await asQuery({ role: 'service_role' },
  `SELECT public.create_payment_intent($1, 'wallet_topup', 20000, NULL, NULL) AS i`, [OTHER]);
const foreignId = foreign.rows[0].i.intent_id;
await asQuery({ role: 'service_role' }, `SELECT public.attach_razorpay_order($1, 'order_OTHER')`, [foreignId]);
await expectError('settling with a mismatched razorpay order refused', () => asQuery({ role: 'service_role' },
  `SELECT public.finalize_wallet_topup($1, 'order_TOP1', 'pay_X', 20000)`, [foreignId]),
  'does not match');
await expectError('duplicate razorpay order id refused', () => asQuery({ role: 'service_role' },
  `SELECT public.attach_razorpay_order($1, 'order_OTHER')`, [topup2Id]), 'duplicate|unique|not found');

// 6r. Privilege surface: no anonymous access to money RPCs, no customer access
//     to the payment-intent machinery, internal schema unreachable.
const grants = await db.query(`
  SELECT
    has_function_privilege('anon','public.place_order(uuid,uuid,text,numeric,jsonb)','EXECUTE')                    AS anon_place_order,
    has_function_privilege('anon','public.update_wallet_balance(uuid,numeric,text,text,text,text,text)','EXECUTE') AS anon_wallet,
    has_function_privilege('authenticated','public.create_payment_intent(uuid,text,bigint,uuid,jsonb)','EXECUTE')  AS cust_intent,
    has_function_privilege('authenticated','public.finalize_order_payment(uuid,text,text,bigint)','EXECUTE')       AS cust_settle,
    has_schema_privilege('authenticated','internal','USAGE')                                                      AS cust_internal,
    has_table_privilege('authenticated','public.payment_intents','SELECT')                                        AS cust_intents_table,
    has_function_privilege('authenticated','public.place_order(uuid,uuid,text,numeric,jsonb)','EXECUTE')           AS cust_place_order,
    has_function_privilege('anon','public.quote_cart(jsonb,uuid)','EXECUTE')                                      AS anon_quote`);
const g = grants.rows[0];
const mustBeFalse = ['anon_place_order','anon_wallet','cust_intent','cust_settle','cust_internal','cust_intents_table','anon_quote'];
const leaks = mustBeFalse.filter((k) => g[k] !== false);
if (leaks.length === 0 && g.cust_place_order === true) {
  ok('privilege surface is tight (no anon money RPCs incl. quote_cart, no customer payment-intent access, internal sealed)');
} else {
  bad('privilege surface', `unexpected: ${JSON.stringify(g)}`);
}

// 6s. Legacy functions: no anonymous reach, and update_address_as_default now
//     refuses to touch another user's address (it is SECURITY DEFINER).
const legacyGrants = await db.query(`
  SELECT p.proname, r.rolname
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  CROSS JOIN (VALUES ('anon')) AS r(rolname)
  WHERE n.nspname = 'public'
    AND has_function_privilege(r.rolname, p.oid, 'EXECUTE')
  ORDER BY 1`);
const anonAllowed = legacyGrants.rows.map((r) => r.proname).sort();
const anonExpected = ['has_permission', 'is_super_admin'];  // quote_cart revoked from anon in migration 015
if (JSON.stringify(anonAllowed) === JSON.stringify(anonExpected)) {
  ok(`anon can only execute ${anonExpected.join(', ')}`);
} else {
  bad('anon-executable functions', JSON.stringify(anonAllowed));
}

await expectError('update_address_as_default cross-user rejected', () => asQuery(
  { sub: OTHER, role: 'authenticated' },
  `SELECT public.update_address_as_default($1, $2, '{"city":"Hacked"}'::jsonb)`,
  [CUSTOMER, ADDR]), 'not authorized');

await expectOk('update_address_as_default works for the owner (fixed columns)', () => asQuery(
  { sub: CUSTOMER, role: 'authenticated' },
  `SELECT public.update_address_as_default($1, $2, '{"city":"Coimbatore","phone":"9000000009"}'::jsonb)`,
  [CUSTOMER, ADDR]));
const addrRow = await db.query(
  `SELECT city, phone_number, is_default FROM public.addresses WHERE id = $1`, [ADDR]);
if (addrRow.rows[0].city === 'Coimbatore' && addrRow.rows[0].phone_number === '9000000009'
    && addrRow.rows[0].is_default === true) {
  ok('address update wrote city + phone_number and set is_default');
} else {
  bad('address update result', JSON.stringify(addrRow.rows[0]));
}

// 6t. Database-level money invariants (migration 012). These bind regardless of
//     who writes the rows, so a staff member with orders:edit / subscriptions:edit
//     cannot hand-write a cheap order or a cheap subscription item.
await expectError('staff direct INSERT of an underpriced order aborts at commit', async () => {
  await db.exec(`
    BEGIN;
    INSERT INTO public.orders (order_number, user_id, address_snapshot_id, status,
                               payment_method, payment_status, subtotal, delivery_charge, total)
    VALUES ('ORD-BYPASS-1', '${CUSTOMER}', '${ADDR}', 'placed', 'cod', 'pending', 1, 0, 1);
    INSERT INTO public.order_items (order_id, variant_id, product_name_snapshot,
                                    variant_label_snapshot, unit_price, quantity, total_price)
    SELECT id, '${VAR}', 'Cow Milk', '1 L', 1, 1, 1
    FROM public.orders WHERE order_number = 'ORD-BYPASS-1';
    COMMIT;`);
}, 'does not match its items|no line items');
await db.exec('ROLLBACK').catch(() => {});

// The catalog price is forced onto order_items, so the "cheap item" above became
// a ₹100 item and the ₹1 subtotal no longer reconciled. A truthful insert works:
await expectOk('staff direct INSERT with correct totals is accepted', async () => {
  await db.exec(`
    BEGIN;
    INSERT INTO public.orders (order_number, user_id, address_snapshot_id, status,
                               payment_method, payment_status, subtotal, delivery_charge, total)
    VALUES ('ORD-STAFF-OK', '${CUSTOMER}', '${ADDR}', 'placed', 'cod', 'pending', 100, 40, 140);
    INSERT INTO public.order_items (order_id, variant_id, product_name_snapshot,
                                    variant_label_snapshot, unit_price, quantity, total_price)
    SELECT id, '${VAR}', 'Cow Milk', '1 L', 100, 1, 100
    FROM public.orders WHERE order_number = 'ORD-STAFF-OK';
    COMMIT;`);
});

// order_items price is snapped to the catalog on insert.
const snapped = await db.query(`
  SELECT oi.unit_price, oi.total_price
  FROM public.order_items oi JOIN public.orders o ON o.id = oi.order_id
  WHERE o.order_number = 'ORD-STAFF-OK'`);
if (Number(snapped.rows[0].unit_price) === 100 && Number(snapped.rows[0].total_price) === 100) {
  ok('order_items price/total derived from the catalog');
} else {
  bad('order item snapping', JSON.stringify(snapped.rows[0]));
}

// A staff-written subscription item gets the catalog price, not the one supplied.
const subId = (await db.query(
  `SELECT id FROM public.subscriptions WHERE user_id = $1 ORDER BY created_at LIMIT 1`,
  [CUSTOMER])).rows[0].id;
await db.query(
  `INSERT INTO public.subscription_items (subscription_id, variant_id, product_name_snapshot,
                                          variant_label_snapshot, unit_price, quantity, item_start_date)
   VALUES ($1, $2, 'Cow Milk', '1 L', 0.5, 1, CURRENT_DATE)`, [subId, VAR]);
const snappedSub = await db.query(
  `SELECT unit_price FROM public.subscription_items
   WHERE subscription_id = $1 ORDER BY unit_price LIMIT 1`, [subId]);
if (Number(snappedSub.rows[0].unit_price) === 100) {
  ok('staff-inserted subscription_items price snapped to catalog (sent 0.5)');
} else {
  bad('subscription item snapping', JSON.stringify(snappedSub.rows[0]));
}

// …and it cannot be edited downwards afterwards.
await expectError('subscription_items.unit_price is immutable', () => db.query(
  `UPDATE public.subscription_items SET unit_price = 1 WHERE subscription_id = $1`, [subId]),
  'immutable');

// Deliberate repair is still possible in a DB session.
await expectOk('SET LOCAL hetha.skip_money_checks allows a deliberate correction', async () => {
  await db.exec(`
    BEGIN;
    SET LOCAL hetha.skip_money_checks = 'on';
    UPDATE public.subscription_items SET unit_price = 90 WHERE subscription_id = '${subId}';
    COMMIT;`);
});

// Daily-order totals must match their items (the drift bug in
// Hetha_admin/services/dailyOps/orders.ts:updateDailyOrderItem).
const dailyId = (await db.query(`
  INSERT INTO public.subscription_daily_orders
    (subscription_id, user_id, delivery_date, status, total_value, payment_status, is_finalized)
  VALUES ($1, $2, CURRENT_DATE, 'pending', 100, 'pending', false) RETURNING id`,
  [subId, CUSTOMER])).rows[0].id;
await db.query(`
  INSERT INTO public.subscription_daily_order_items
    (daily_order_id, variant_id, product_name_snapshot, variant_label_snapshot,
     unit_price, quantity, total_price)
  VALUES ($1, $2, 'Cow Milk', '1 L', 100, 1, 100)`, [dailyId, VAR]);

await expectError('daily order total drifting from its items is rejected', async () => {
  await db.exec(`
    BEGIN;
    UPDATE public.subscription_daily_order_items SET quantity = 2, total_price = 200
    WHERE daily_order_id = '${dailyId}';
    COMMIT;`);
}, 'does not match its items');
await db.exec('ROLLBACK').catch(() => {});

await expectOk('daily order edit that re-sums the parent is accepted', async () => {
  await db.exec(`
    BEGIN;
    UPDATE public.subscription_daily_order_items SET quantity = 2, total_price = 200
    WHERE daily_order_id = '${dailyId}';
    UPDATE public.subscription_daily_orders SET total_value = 200 WHERE id = '${dailyId}';
    COMMIT;`);
});

// 6u. Migration 013: scheduled cancellation writes end_date (not the phantom
//     scheduled_end_date), and get_user_role is dropped.
const cancelSub = (await db.query(
  `INSERT INTO public.subscriptions (user_id, status, start_date)
   VALUES ($1, 'active', CURRENT_DATE) RETURNING id`, [CUSTOMER])).rows[0].id;

await expectOk('scheduled cancel_subscription no longer errors', () => asQuery(
  { sub: CUSTOMER, role: 'authenticated' },
  `SELECT public.cancel_subscription($1, $2, (now() + interval '7 days'), false, 'scheduled', 'test')`,
  [cancelSub, CUSTOMER]));

const cancelRow = (await db.query(
  `SELECT status, end_date, cancelled_at FROM public.subscriptions WHERE id = $1`,
  [cancelSub])).rows[0];
if (cancelRow.status === 'pending_cancellation' && cancelRow.end_date !== null
    && cancelRow.cancelled_at === null) {
  ok(`scheduled cancel parked in pending_cancellation with end_date set, cancelled_at NULL`);
} else {
  bad('scheduled cancel result', JSON.stringify(cancelRow));
}

// Immediate cancel still fully cancels.
const cancelSub2 = (await db.query(
  `INSERT INTO public.subscriptions (user_id, status, start_date)
   VALUES ($1, 'active', CURRENT_DATE) RETURNING id`, [CUSTOMER])).rows[0].id;
await asQuery({ sub: CUSTOMER, role: 'authenticated' },
  `SELECT public.cancel_subscription($1, $2, now(), true, 'immediate', NULL)`, [cancelSub2, CUSTOMER]);
const cancelRow2 = (await db.query(
  `SELECT status, cancelled_at FROM public.subscriptions WHERE id = $1`, [cancelSub2])).rows[0];
if (cancelRow2.status === 'cancelled' && cancelRow2.cancelled_at !== null) {
  ok('immediate cancel still sets cancelled + cancelled_at');
} else {
  bad('immediate cancel result', JSON.stringify(cancelRow2));
}

const roleGone = (await db.query(
  `SELECT to_regprocedure('public.get_user_role(uuid)') IS NULL AS dropped`)).rows[0].dropped;
if (roleGone === true) {
  ok('get_user_role dropped');
} else {
  bad('get_user_role', 'still present');
}

// ---------------------------------------------------------------------------
// 6u. Customer daily-order modification RPCs (migration 022).
//     Reproduces the RLS 42501 the app hit, then proves the RPC path is the
//     controlled way in: owner-only, server-priced, run-sheet-safe.
// ---------------------------------------------------------------------------
await db.exec(`UPDATE public.users SET wallet_balance = 5000 WHERE id = '${CUSTOMER}'`);

// Enable RLS on the daily-order tables so the direct-write test is meaningful
// (the schema dump does not carry ALTER TABLE ... ENABLE RLS, and policies.sql
// is not loaded by this harness). Mirror the admin-only policy from
// docs/db/policies.sql so a customer INSERT is refused exactly as in prod.
await db.exec(`
  ALTER TABLE public.subscription_daily_orders ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.subscription_daily_orders FORCE ROW LEVEL SECURITY;
  CREATE POLICY sdo_admin_insert ON public.subscription_daily_orders
    FOR INSERT TO public WITH CHECK (is_super_admin() OR has_permission('daily_ops:edit') OR has_permission('subscriptions:edit'));
  CREATE POLICY sdo_owner_select ON public.subscription_daily_orders
    FOR SELECT TO public USING (user_id = auth.uid() OR is_super_admin() OR has_permission('daily_ops:view'));
`);

// A subscription to modify (100/day from the catalog).
const modSub = (await asQuery({ sub: CUSTOMER, role: 'authenticated' },
  `SELECT public.create_subscription($1, now(), NULL, 'active', $2::jsonb, $3::jsonb, 'DailyEdit') AS id`,
  [CUSTOMER, JSON.stringify({ pincode: '600001', name: 'Cust', phoneNumber: '9000000001' }),
   JSON.stringify([{ variantId: VAR, name: 'x', variant: 'y', price: 0.01, quantity: 1, startDate: '2026-07-28' }])])).rows[0].id;

const MOD_DATE = '2099-01-01';  // safely in the future

// (a) The bug's root cause: the only INSERT policy on subscription_daily_orders
//     is admin-only (no `user_id = auth.uid()` branch), so a customer's direct
//     client INSERT is refused with 42501 in production. We assert the policy
//     SHAPE here rather than a live RLS block — PGlite runs as the table owner,
//     for whom RLS is bypassed, so the other tests (like the whole suite) model
//     authorization at the RPC layer instead. This mirrors docs/db/policies.sql.
const sdoInsertPol = (await db.query(`
  SELECT with_check FROM pg_policies
  WHERE schemaname = 'public' AND tablename = 'subscription_daily_orders' AND cmd = 'INSERT'`)).rows;
const hasAdminOnlyInsert = sdoInsertPol.length > 0
  && sdoInsertPol.every((p) => /has_permission|is_super_admin/.test(p.with_check)
                            && !/auth\.uid\(\)/.test(p.with_check));
if (hasAdminOnlyInsert) {
  ok('subscription_daily_orders INSERT is admin-only (no customer branch) — the 42501 the app hit');
} else {
  bad('subscription_daily_orders INSERT policy shape', JSON.stringify(sdoInsertPol));
}

// (b) The fix: modify_daily_order succeeds for the owner and prices from the
//     catalog. The client only sends variant_id + quantity — no price field.
const modId = (await asQuery({ sub: CUSTOMER, role: 'authenticated' },
  `SELECT public.modify_daily_order($1, $2, $3::date, $4::jsonb) AS id`,
  [CUSTOMER, modSub, MOD_DATE, JSON.stringify([{ variant_id: VAR, quantity: 3 }])])).rows[0].id;
const modOrder = (await db.query(
  `SELECT o.total_value, o.is_customer_modified, o.status,
          (SELECT SUM(i.total_price) FROM public.subscription_daily_order_items i WHERE i.daily_order_id = o.id) AS items_sum,
          (SELECT i.unit_price FROM public.subscription_daily_order_items i WHERE i.daily_order_id = o.id LIMIT 1) AS unit_price
   FROM public.subscription_daily_orders o WHERE o.id = $1`, [modId])).rows[0];
if (Number(modOrder.unit_price) === 100 && Number(modOrder.total_value) === 300
    && Number(modOrder.items_sum) === 300 && modOrder.is_customer_modified === true
    && modOrder.status === 'pending') {
  ok(`modify_daily_order priced 3×₹100 server-side = ₹300, flagged is_customer_modified (${JSON.stringify(modOrder)})`);
} else {
  bad('modify_daily_order result', JSON.stringify(modOrder));
}

// (c) Re-modifying the same day replaces (not duplicates) the order.
await asQuery({ sub: CUSTOMER, role: 'authenticated' },
  `SELECT public.modify_daily_order($1, $2, $3::date, $4::jsonb)`,
  [CUSTOMER, modSub, MOD_DATE, JSON.stringify([{ variant_id: VAR, quantity: 1 }])]);
const dayCount = (await db.query(
  `SELECT COUNT(*)::int AS c, SUM(total_value)::numeric AS v FROM public.subscription_daily_orders
   WHERE user_id = $1 AND delivery_date = $2`, [CUSTOMER, MOD_DATE])).rows[0];
if (dayCount.c === 1 && Number(dayCount.v) === 100) {
  ok('re-modifying a day replaces in place (1 order, ₹100)');
} else {
  bad('modify replace', JSON.stringify(dayCount));
}

// (d) A different user cannot modify this subscription's day.
await expectError('cross-user modify_daily_order rejected', () => asQuery({ sub: OTHER, role: 'authenticated' },
  `SELECT public.modify_daily_order($1, $2, $3::date, $4::jsonb)`,
  [CUSTOMER, modSub, MOD_DATE, JSON.stringify([{ variant_id: VAR, quantity: 1 }])]),
  'not authorized|does not belong|Not authorized for this subscription');

// (e) Past dates are refused.
await expectError('modify_daily_order for a past date rejected', () => asQuery({ sub: CUSTOMER, role: 'authenticated' },
  `SELECT public.modify_daily_order($1, $2, '2000-01-01'::date, $3::jsonb)`,
  [CUSTOMER, modSub, JSON.stringify([{ variant_id: VAR, quantity: 1 }])]), 'past');

// (f) revert_daily_order clears the pending edit (owner only). 3-arg form —
//     the 2-arg version was dropped in migration 031.
await expectError('cross-user revert_daily_order rejected', () => asQuery({ sub: OTHER, role: 'authenticated' },
  `SELECT public.revert_daily_order($1, $2::date, $3::uuid)`, [CUSTOMER, MOD_DATE, modSub]), 'not authorized');
await asQuery({ sub: CUSTOMER, role: 'authenticated' },
  `SELECT public.revert_daily_order($1, $2::date, $3::uuid)`, [CUSTOMER, MOD_DATE, modSub]);
const afterRevert = (await db.query(
  `SELECT COUNT(*)::int AS c FROM public.subscription_daily_orders WHERE user_id = $1 AND delivery_date = $2`,
  [CUSTOMER, MOD_DATE])).rows[0].c;
if (afterRevert === 0) {
  ok('revert_daily_order removed the pending customer edit');
} else {
  bad('revert_daily_order', `${afterRevert} orders remain`);
}

// (g) Privilege surface for the new RPCs.
const modGrants = (await db.query(`
  SELECT
    has_function_privilege('anon','public.modify_daily_order(uuid,uuid,date,jsonb)','EXECUTE')          AS anon_modify,
    has_function_privilege('anon','public.revert_daily_order(uuid,date,uuid)','EXECUTE')                AS anon_revert,
    has_function_privilege('authenticated','public.modify_daily_order(uuid,uuid,date,jsonb)','EXECUTE') AS auth_modify,
    has_function_privilege('authenticated','public.revert_daily_order(uuid,date,uuid)','EXECUTE')       AS auth_revert`)).rows[0];
if (modGrants.anon_modify === false && modGrants.anon_revert === false
    && modGrants.auth_modify === true && modGrants.auth_revert === true) {
  ok('daily-order RPCs: anon blocked, authenticated allowed');
} else {
  bad('daily-order RPC grants', JSON.stringify(modGrants));
}

// ---------------------------------------------------------------------------
// 6v. register_device_token: fixes the cross-account push leak (migration 023).
//     device_tokens RLS is "own rows only" — a plain client upsert can never
//     release a token a PREVIOUS account left on a shared device, so this RPC
//     is the only correct place to do it.
// ---------------------------------------------------------------------------
await db.exec(`
  ALTER TABLE public.device_tokens ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.device_tokens FORCE ROW LEVEL SECURITY;
  CREATE POLICY device_tokens_own_rows ON public.device_tokens
    FOR ALL TO public USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
`);

const SHARED_TOKEN = 'fcm-shared-device-token-001';

// Account A registers first (simulates the first person to use this phone).
await asQuery({ sub: CUSTOMER, role: 'authenticated' },
  `SELECT public.register_device_token($1, 'android')`, [SHARED_TOKEN]);
const afterA = (await db.query(
  `SELECT user_id FROM public.device_tokens WHERE fcm_token = $1`, [SHARED_TOKEN])).rows;
if (afterA.length === 1 && afterA[0].user_id === CUSTOMER) {
  ok('register_device_token: first account claims the token');
} else {
  bad('register_device_token (first claim)', JSON.stringify(afterA));
}

// (a) The bug this replaces: device_tokens' only policy is "own rows only" —
//     no branch lets one user's session see or delete another user's row, so
//     a plain client upsert/delete as account B could never reach account A's
//     row for the same token. (We assert the policy SHAPE rather than a live
//     cross-account DELETE — PGlite runs as the table owner, for whom RLS is
//     bypassed, same reason the migration-022 tests above do the same.)
const dtPolicies = (await db.query(`
  SELECT qual, with_check FROM pg_policies
  WHERE schemaname = 'public' AND tablename = 'device_tokens'`)).rows;
const ownRowsOnly = dtPolicies.length === 1
  && /auth\.uid\(\)\s*=\s*user_id/.test(dtPolicies[0].qual || '')
  && !/is_super_admin|has_permission/.test(dtPolicies[0].qual || '');
if (ownRowsOnly) {
  ok('device_tokens RLS is own-rows-only — no path for account B to reach account A\'s row directly');
} else {
  bad('device_tokens policy shape', JSON.stringify(dtPolicies));
}

// (b) The fix: account B registering the SAME physical token (the real-world
//     "logged out of A, into B on the same phone" scenario) releases it from A.
await asQuery({ sub: OTHER, role: 'authenticated' },
  `SELECT public.register_device_token($1, 'android')`, [SHARED_TOKEN]);
const afterB = (await db.query(
  `SELECT user_id FROM public.device_tokens WHERE fcm_token = $1`, [SHARED_TOKEN])).rows;
if (afterB.length === 1 && afterB[0].user_id === OTHER) {
  ok('register_device_token: second account on the same device takes over the token, first account\'s row is gone (leak fixed)');
} else {
  bad('register_device_token (takeover)', JSON.stringify(afterB));
}

// (c) Re-registering (app restart / token refresh) for the same account is a
//     stable no-op, not a duplicate.
await asQuery({ sub: OTHER, role: 'authenticated' },
  `SELECT public.register_device_token($1, 'android')`, [SHARED_TOKEN]);
const stable = (await db.query(
  `SELECT COUNT(*)::int AS c FROM public.device_tokens WHERE fcm_token = $1`, [SHARED_TOKEN])).rows[0].c;
if (stable === 1) {
  ok('re-registering the same token for the same account stays at 1 row');
} else {
  bad('register_device_token idempotency', `${stable} rows`);
}

// (d) Anonymous cannot call it; authenticated can.
const tokenGrants = (await db.query(`
  SELECT
    has_function_privilege('anon','public.register_device_token(text,text)','EXECUTE')          AS anon_ok,
    has_function_privilege('authenticated','public.register_device_token(text,text)','EXECUTE') AS auth_ok`)).rows[0];
if (tokenGrants.anon_ok === false && tokenGrants.auth_ok === true) {
  ok('register_device_token: anon blocked, authenticated allowed');
} else {
  bad('register_device_token grants', JSON.stringify(tokenGrants));
}

// ---------------------------------------------------------------------------
// 6w. Free delivery for serviceable pincodes (migration 024).
//     Pincode in an ACTIVE delivery area → ₹0 fee; not in any area, or in an
//     area switched off in the admin panel → the weight-tier fee (₹40 here).
// ---------------------------------------------------------------------------
const AREA_ON   = '88888888-8888-4888-8888-888888888801';
const AREA_OFF  = '88888888-8888-4888-8888-888888888802';
const ADDR_FREE = '99999999-9999-4999-8999-999999999901';  // pincode in active area
const ADDR_OFF  = '99999999-9999-4999-8999-999999999902';  // pincode in inactive area

await db.exec(`
  UPDATE public.users SET wallet_balance = 5000 WHERE id = '${CUSTOMER}';

  INSERT INTO public.delivery_areas (id, display_name, is_active)
  VALUES ('${AREA_ON}', 'Rider Area', true), ('${AREA_OFF}', 'Closed Area', false);
  INSERT INTO public.pincodes (area_id, pincode)
  VALUES ('${AREA_ON}', '600002'), ('${AREA_OFF}', '600003');

  INSERT INTO public.addresses (id, user_id, name, phone_number, address_line1, city, state, pincode, address_type)
  VALUES ('${ADDR_FREE}', '${CUSTOMER}', 'Cust', '9000000001', '2 Rider St', 'Chennai', 'TN', '600002', 'home'),
         ('${ADDR_OFF}',  '${CUSTOMER}', 'Cust', '9000000001', '3 Closed St', 'Chennai', 'TN', '600003', 'home');
`);

const quoteFor = async (claims, addressId) => (await asQuery(claims,
  `SELECT public.quote_cart($1::jsonb, $2::uuid) AS q`, [CART, addressId])).rows[0].q;
const CUST_CLAIMS = { sub: CUSTOMER, role: 'authenticated' };

// (a) Quotes follow the address pincode.
const qFree = await quoteFor(CUST_CLAIMS, ADDR_FREE);
if (Number(qFree.delivery_charge) === 0 && Number(qFree.total) === 100) {
  ok(`quote_cart: serviceable pincode 600002 → free delivery ${JSON.stringify(qFree)}`);
} else {
  bad('quote_cart serviceable pincode', JSON.stringify(qFree));
}

const qOutside = await quoteFor(CUST_CLAIMS, ADDR);
if (Number(qOutside.delivery_charge) === 40 && Number(qOutside.total) === 140) {
  ok(`quote_cart: pincode 600001 not in any area → tier charge ${JSON.stringify(qOutside)}`);
} else {
  bad('quote_cart non-serviceable pincode', JSON.stringify(qOutside));
}

const qInactive = await quoteFor(CUST_CLAIMS, ADDR_OFF);
if (Number(qInactive.delivery_charge) === 40) {
  ok('quote_cart: pincode in an INACTIVE area → tier charge (not free)');
} else {
  bad('quote_cart inactive area', JSON.stringify(qInactive));
}

// (b) Someone else's address id cannot be used to probe/quote.
await expectError('quote_cart with another user\'s address rejected',
  () => quoteFor({ sub: OTHER, role: 'authenticated' }, ADDR_FREE), 'does not belong');

// (c) The order itself is charged by pincode — and a customer-sent fee is
//     still ignored (₹40 sent, ₹0 charged).
const freeOrder = await asQuery(CUST_CLAIMS,
  `SELECT public.place_order($1,$2,'wallet',40,$3::jsonb) AS id`, [CUSTOMER, ADDR_FREE, CART]);
const freeRow = (await db.query(
  `SELECT subtotal, delivery_charge, total FROM public.orders WHERE id = $1`,
  [freeOrder.rows[0].id])).rows[0];
if (Number(freeRow.delivery_charge) === 0 && Number(freeRow.total) === 100) {
  ok(`place_order to serviceable pincode charged no delivery ${JSON.stringify(freeRow)}`);
} else {
  bad('place_order serviceable pincode', JSON.stringify(freeRow));
}

const offOrder = await asQuery(CUST_CLAIMS,
  `SELECT public.place_order($1,$2,'wallet',0,$3::jsonb) AS id`, [CUSTOMER, ADDR_OFF, CART]);
const offRow = (await db.query(
  `SELECT delivery_charge, total FROM public.orders WHERE id = $1`, [offOrder.rows[0].id])).rows[0];
if (Number(offRow.delivery_charge) === 40 && Number(offRow.total) === 140) {
  ok('place_order to an inactive-area pincode still pays the tier charge');
} else {
  bad('place_order inactive area', JSON.stringify(offRow));
}

// (d) Razorpay: the payment intent amount follows the same rule.
const freeIntent = (await asQuery({ role: 'service_role' },
  `SELECT public.create_payment_intent($1, 'order', NULL, $2, $3::jsonb) AS i`,
  [CUSTOMER, ADDR_FREE, CART])).rows[0].i;
if (Number(freeIntent.amount_paise) === 10000) {
  ok('create_payment_intent for a serviceable pincode = 10000 paise (₹100, no delivery fee)');
} else {
  bad('payment intent serviceable pincode', JSON.stringify(freeIntent));
}

// (e) Admin fee override still works (explicit waiver/charge by staff).
const adminOrder = await asQuery({ role: 'service_role' },
  `SELECT public.place_order($1,$2,'cod',25,$3::jsonb) AS id`, [CUSTOMER, ADDR_FREE, CART]);
const adminRow = (await db.query(
  `SELECT delivery_charge FROM public.orders WHERE id = $1`, [adminOrder.rows[0].id])).rows[0];
if (Number(adminRow.delivery_charge) === 25) {
  ok('admin/service caller p_delivery_charge override still honoured');
} else {
  bad('admin delivery override', JSON.stringify(adminRow));
}

// (f) Only the new quote_cart signature exists.
const quoteSigs = (await db.query(`
  SELECT p.oid::regprocedure::text AS sig
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'quote_cart'`)).rows.map((r) => r.sig);
if (quoteSigs.length === 1 && quoteSigs[0] === 'quote_cart(jsonb,uuid)') {
  ok('quote_cart(jsonb) replaced by quote_cart(jsonb,uuid) — no ambiguous overloads');
} else {
  bad('quote_cart signatures', JSON.stringify(quoteSigs));
}

// ---------------------------------------------------------------------------
// 6x. Day-edit wallet rule + per-subscription scope (migration 025).
//     required = next-delivery reserve (all subs, migration 039) + this day's one-off extra,
//     checked only when the edit raises THIS subscription's cost; and saving
//     one subscription's day never deletes another subscription's order.
// ---------------------------------------------------------------------------
const EDIT_DATE = '2099-02-01';
const commitment = Number((await db.query(
  `SELECT public.get_user_daily_commitment($1) AS c`, [CUSTOMER])).rows[0].c);
// modSub (6u) is 1 × VAR = ₹100/day; editing to 5 × VAR = ₹500 → extra ₹400.
const EDIT_ITEMS = JSON.stringify([{ variant_id: VAR, quantity: 5 }]);
const editRequired = Math.round((commitment + 400) * 100) / 100;

await db.exec(`UPDATE public.users SET wallet_balance = ${editRequired - 1} WHERE id = '${CUSTOMER}'`);
await expectError('day edit refused when wallet < next-delivery reserve + one-off extra',
  () => asQuery(CUST_CLAIMS, `SELECT public.modify_daily_order($1, $2, $3::date, $4::jsonb)`,
    [CUSTOMER, modSub, EDIT_DATE, EDIT_ITEMS]), 'Insufficient wallet balance');

await db.exec(`UPDATE public.users SET wallet_balance = ${editRequired} WHERE id = '${CUSTOMER}'`);
await expectOk(`day edit allowed at exactly the next-delivery reserve (${commitment}) + extra 400 = ${editRequired}`,
  () => asQuery(CUST_CLAIMS, `SELECT public.modify_daily_order($1, $2, $3::date, $4::jsonb)`,
    [CUSTOMER, modSub, EDIT_DATE, EDIT_ITEMS]));

// Trimming a day back to (or below) normal needs no wallet at all.
await db.exec(`UPDATE public.users SET wallet_balance = 0 WHERE id = '${CUSTOMER}'`);
await expectOk('day edit that does not raise the cost is allowed with an empty wallet',
  () => asQuery(CUST_CLAIMS, `SELECT public.modify_daily_order($1, $2, $3::date, $4::jsonb)`,
    [CUSTOMER, modSub, EDIT_DATE, JSON.stringify([{ variant_id: VAR, quantity: 1 }])]));

// Another subscription's order on the same date must survive the edit.
const otherSubId = sub.rows[0].id;
await db.exec(`
  BEGIN;
  WITH o AS (
    INSERT INTO public.subscription_daily_orders (delivery_date, subscription_id, user_id, status, total_value)
    VALUES ('${EDIT_DATE}', '${otherSubId}', '${CUSTOMER}', 'pending', 100)
    RETURNING id
  )
  INSERT INTO public.subscription_daily_order_items
    (daily_order_id, variant_id, product_name_snapshot, variant_label_snapshot, unit_price, quantity, total_price)
  SELECT id, '${VAR}', 'Cow Milk', '1 L', 100, 1, 100 FROM o;
  COMMIT;
`);
await asQuery(CUST_CLAIMS, `SELECT public.modify_daily_order($1, $2, $3::date, $4::jsonb)`,
  [CUSTOMER, modSub, EDIT_DATE, JSON.stringify([{ variant_id: VAR, quantity: 1 }])]);
const perSub = (await db.query(`
  SELECT subscription_id::text AS s, COUNT(*)::int AS c FROM public.subscription_daily_orders
  WHERE user_id = $1 AND delivery_date = $2 GROUP BY subscription_id`, [CUSTOMER, EDIT_DATE])).rows;
const otherKept = perSub.some((r) => r.s === otherSubId && r.c === 1);
const editedOne = perSub.some((r) => r.s === modSub && r.c === 1);
if (otherKept && editedOne) {
  ok('editing one subscription\'s day keeps the other subscription\'s order for that date');
} else {
  bad('per-subscription day scope', JSON.stringify(perSub));
}
await db.exec(`UPDATE public.users SET wallet_balance = 5000 WHERE id = '${CUSTOMER}'`);

// ---------------------------------------------------------------------------
// 6y. "Reset to Default" per subscription (migration 026).
//     State from 6x: on EDIT_DATE, modSub has a customer edit and otherSubId
//     has its own pending order.
// ---------------------------------------------------------------------------
await expectError('3-arg revert_daily_order refuses another user\'s subscription',
  () => asQuery({ sub: OTHER, role: 'authenticated' },
    `SELECT public.revert_daily_order($1, $2::date, $3::uuid)`, [OTHER, EDIT_DATE, modSub]),
  'does not belong');

await asQuery(CUST_CLAIMS, `SELECT public.revert_daily_order($1, $2::date, $3::uuid)`,
  [CUSTOMER, EDIT_DATE, modSub]);
const afterScopedRevert = (await db.query(`
  SELECT subscription_id::text AS s FROM public.subscription_daily_orders
  WHERE user_id = $1 AND delivery_date = $2`, [CUSTOMER, EDIT_DATE])).rows.map((r) => r.s);
if (afterScopedRevert.length === 1 && afterScopedRevert[0] === otherSubId) {
  ok('3-arg revert_daily_order resets only that subscription\'s day; the other subscription\'s order stays');
} else {
  bad('scoped revert', JSON.stringify(afterScopedRevert));
}

const revertGrants = (await db.query(`
  SELECT
    has_function_privilege('anon','public.revert_daily_order(uuid,date,uuid)','EXECUTE')          AS anon_ok,
    has_function_privilege('authenticated','public.revert_daily_order(uuid,date,uuid)','EXECUTE') AS auth_ok`)).rows[0];
if (revertGrants.anon_ok === false && revertGrants.auth_ok === true) {
  ok('3-arg revert_daily_order: anon blocked, authenticated allowed');
} else {
  bad('3-arg revert grants', JSON.stringify(revertGrants));
}

// ---------------------------------------------------------------------------
// 6z. Atomic bulk day-edit RPC (migration 027).
//     modify_daily_orders_bulk must (a) check the wallet ONCE against the SUM
//     of every day's one-off extra in the batch, not per day against the same
//     stored balance, and (b) apply every day or none — a bad day anywhere in
//     the batch must leave every other day exactly as it was.
// ---------------------------------------------------------------------------
const bulkGrants = (await db.query(`
  SELECT
    has_function_privilege('anon','public.modify_daily_orders_bulk(uuid,uuid,jsonb)','EXECUTE')          AS anon_ok,
    has_function_privilege('authenticated','public.modify_daily_orders_bulk(uuid,uuid,jsonb)','EXECUTE') AS auth_ok`)).rows[0];
if (bulkGrants.anon_ok === false && bulkGrants.auth_ok === true) {
  ok('modify_daily_orders_bulk: anon blocked, authenticated allowed');
} else {
  bad('modify_daily_orders_bulk grants', JSON.stringify(bulkGrants));
}

// Clean slate on modSub for these dates (each 1 × VAR = ₹100/day normal cost).
const BULK_DATES = ['2099-03-01', '2099-03-02', '2099-03-03'];
await db.query(`DELETE FROM public.subscription_daily_order_items WHERE daily_order_id IN
  (SELECT id FROM public.subscription_daily_orders WHERE subscription_id = $1 AND delivery_date = ANY($2::date[]))`,
  [modSub, BULK_DATES]);
await db.query(`DELETE FROM public.subscription_daily_orders WHERE subscription_id = $1 AND delivery_date = ANY($2::date[])`,
  [modSub, BULK_DATES]);

const bulkCommitment = Number((await db.query(
  `SELECT public.get_user_daily_commitment($1) AS c`, [CUSTOMER])).rows[0].c);

// Each day raised to 5 × VAR = ₹500 → extra ₹400/day. Across 3 days: ₹1200 total.
const bulkDaysPayload = (extraDays) => JSON.stringify(
  BULK_DATES.slice(0, extraDays).map((d) => ({ delivery_date: d, items: [{ variant_id: VAR, quantity: 5 }] })));

const totalExtraFor3 = 400 * 3;
const bulkRequired3 = Math.round((bulkCommitment + totalExtraFor3) * 100) / 100;
// A per-day-only check (022/025's OLD behaviour re-applied 3 times) would have
// passed at (reserve + 400) for each call; this must refuse below the
// AGGREGATE requirement even though it's above any single day's requirement.
// (Reserve = next delivery of all subscriptions, migration 039.)
const perDayOnlyRequired = Math.round((bulkCommitment + 400) * 100) / 100;

await db.exec(`UPDATE public.users SET wallet_balance = ${perDayOnlyRequired} WHERE id = '${CUSTOMER}'`);
await expectError(
  `bulk edit refused when wallet (${perDayOnlyRequired}) covers only ONE day's extra but the batch has 3 (needs ${bulkRequired3})`,
  () => asQuery(CUST_CLAIMS, `SELECT public.modify_daily_orders_bulk($1, $2, $3::jsonb)`,
    [CUSTOMER, modSub, bulkDaysPayload(3)]),
  'Insufficient wallet balance');

// Nothing should have been written for ANY of the 3 days after the refusal.
const afterRefusal = (await db.query(
  `SELECT COUNT(*)::int AS c FROM public.subscription_daily_orders
   WHERE subscription_id = $1 AND delivery_date = ANY($2::date[])`,
  [modSub, BULK_DATES])).rows[0].c;
if (afterRefusal === 0) {
  ok('bulk edit refusal is atomic: zero days written when the aggregate wallet check fails');
} else {
  bad('bulk edit atomicity on wallet refusal', `expected 0 rows, found ${afterRefusal}`);
}

// Fund exactly the aggregate requirement — must now succeed for all 3 days.
await db.exec(`UPDATE public.users SET wallet_balance = ${bulkRequired3} WHERE id = '${CUSTOMER}'`);
const bulkResult = (await asQuery(CUST_CLAIMS,
  `SELECT public.modify_daily_orders_bulk($1, $2, $3::jsonb) AS r`,
  [CUSTOMER, modSub, bulkDaysPayload(3)])).rows[0].r;
const writtenDates = (await db.query(
  `SELECT delivery_date::text AS d, total_value FROM public.subscription_daily_orders
   WHERE subscription_id = $1 AND delivery_date = ANY($2::date[]) ORDER BY delivery_date`,
  [modSub, BULK_DATES])).rows;
const allThreeWritten = writtenDates.length === 3 && writtenDates.every((r) => Number(r.total_value) === 500);
const reportedExtra = Number(bulkResult.total_extra) === totalExtraFor3;
if (allThreeWritten && reportedExtra) {
  ok(`bulk edit funded at the AGGREGATE requirement (${bulkRequired3}) applies all 3 days, total_extra=${totalExtraFor3} reported`);
} else {
  bad('bulk edit aggregate success', JSON.stringify({ writtenDates, bulkResult }));
}

// Non-atomicity check: a batch with one invalid day (past date) must leave
// every valid day in the SAME batch untouched too.
await db.query(`DELETE FROM public.subscription_daily_order_items WHERE daily_order_id IN
  (SELECT id FROM public.subscription_daily_orders WHERE subscription_id = $1 AND delivery_date = ANY($2::date[]))`,
  [modSub, BULK_DATES]);
await db.query(`DELETE FROM public.subscription_daily_orders WHERE subscription_id = $1 AND delivery_date = ANY($2::date[])`,
  [modSub, BULK_DATES]);
await db.query(`UPDATE public.users SET wallet_balance = 100000 WHERE id = $1`, [CUSTOMER]);

const mixedBatch = JSON.stringify([
  { delivery_date: BULK_DATES[0], items: [{ variant_id: VAR, quantity: 2 }] },
  { delivery_date: '2020-01-01', items: [{ variant_id: VAR, quantity: 2 }] },  // invalid: in the past
  { delivery_date: BULK_DATES[1], items: [{ variant_id: VAR, quantity: 2 }] },
]);
await expectError('bulk edit refuses a batch containing a past date',
  () => asQuery(CUST_CLAIMS, `SELECT public.modify_daily_orders_bulk($1, $2, $3::jsonb)`,
    [CUSTOMER, modSub, mixedBatch]),
  'past');

const afterMixedFailure = (await db.query(
  `SELECT COUNT(*)::int AS c FROM public.subscription_daily_orders
   WHERE subscription_id = $1 AND delivery_date = ANY($2::date[])`,
  [modSub, [BULK_DATES[0], BULK_DATES[1]]])).rows[0].c;
if (afterMixedFailure === 0) {
  ok('one invalid day in a bulk batch rolls back the OTHER valid days too (no partial apply)');
} else {
  bad('bulk edit atomicity with a mixed valid/invalid batch', `expected 0 rows for the valid dates, found ${afterMixedFailure}`);
}

await db.exec(`UPDATE public.users SET wallet_balance = 5000 WHERE id = '${CUSTOMER}'`);

// ---------------------------------------------------------------------------
// 7a. Product archive + atomic delete (migration 028).
// ---------------------------------------------------------------------------
await db.query(
  `INSERT INTO public.admin_role_permissions (role_id, permission) VALUES ($1, 'products:edit')`, [roleId]);
const ADMIN_CLAIMS = { sub: ADMIN, role: 'authenticated' };

const prodGrants = (await db.query(`
  SELECT
    has_function_privilege('anon','public.delete_product(uuid)','EXECUTE')                          AS anon_del,
    has_function_privilege('anon','public.set_product_archived(uuid,boolean)','EXECUTE')            AS anon_arch,
    has_function_privilege('authenticated','public.delete_product(uuid)','EXECUTE')                 AS auth_del,
    has_function_privilege('authenticated','public.set_product_archived(uuid,boolean)','EXECUTE')   AS auth_arch`)).rows[0];
if (!prodGrants.anon_del && !prodGrants.anon_arch && prodGrants.auth_del && prodGrants.auth_arch) {
  ok('delete_product / set_product_archived: anon blocked, authenticated allowed');
} else {
  bad('product RPC grants', JSON.stringify(prodGrants));
}

await expectError('customer cannot delete a product',
  () => asQuery(CUST_CLAIMS, `SELECT public.delete_product($1)`, [PROD]), 'Not authorized');
await expectError('customer cannot archive a product',
  () => asQuery(CUST_CLAIMS, `SELECT public.set_product_archived($1, true)`, [PROD]), 'Not authorized');

// PROD (Cow Milk) has order lines from earlier tests. Deleting it must be
// refused WITHOUT touching its images — the old route lost them first.
await db.query(`INSERT INTO public.product_images (product_id, image_url) VALUES ($1, 'milk.png')`, [PROD]);
await expectError('product with order history cannot be deleted',
  () => asQuery(ADMIN_CLAIMS, `SELECT public.delete_product($1)`, [PROD]), 'has history');
const milkLeft = (await db.query(`
  SELECT (SELECT COUNT(*)::int FROM public.products WHERE id = $1)            AS p,
         (SELECT COUNT(*)::int FROM public.product_variants WHERE product_id = $1) AS v,
         (SELECT COUNT(*)::int FROM public.product_images WHERE product_id = $1)   AS i`, [PROD])).rows[0];
if (milkLeft.p === 1 && milkLeft.v === 1 && milkLeft.i === 1) {
  ok('refused delete changed nothing: product, variant and image all still there');
} else {
  bad('refused delete left partial state', JSON.stringify(milkLeft));
}

// PROD is in active subscriptions → archiving it is refused.
await expectError('archiving a product that active subscriptions deliver is refused',
  () => asQuery(ADMIN_CLAIMS, `SELECT public.set_product_archived($1, true)`, [PROD]), 'active subscription');

// A product nobody ever ordered: delete removes cart rows, images, variants
// and the product together.
const P2 = 'a2a2a2a2-0000-4000-8000-000000000002', V2 = 'b2b2b2b2-0000-4000-8000-000000000002';
await db.exec(`
  INSERT INTO public.products (id, category_id, name, in_stock, delivery_scope) VALUES ('${P2}', '${CAT}', 'Test Curd', true, 'all_india');
  INSERT INTO public.product_variants (id, product_id, label, price, weight_grams, is_active) VALUES ('${V2}', '${P2}', '500 g', 60, 500, true);
  INSERT INTO public.product_images (product_id, image_url) VALUES ('${P2}', 'curd.png');
  INSERT INTO public.cart_items (user_id, variant_id, quantity) VALUES ('${CUSTOMER}', '${V2}', 1);
`);
await expectOk('product with no history is deleted', () =>
  asQuery(ADMIN_CLAIMS, `SELECT public.delete_product($1)`, [P2]));
const curdLeft = (await db.query(`
  SELECT (SELECT COUNT(*)::int FROM public.products WHERE id = $1)
       + (SELECT COUNT(*)::int FROM public.product_variants WHERE product_id = $1)
       + (SELECT COUNT(*)::int FROM public.product_images WHERE product_id = $1)
       + (SELECT COUNT(*)::int FROM public.cart_items WHERE variant_id = $2) AS n`, [P2, V2])).rows[0].n;
if (curdLeft === 0) {
  ok('delete removed the product with its variants, images and cart rows');
} else {
  bad('delete_product cleanup', `${curdLeft} rows remain`);
}

// Archive: hidden from checkout, cleared from carts, restorable.
const P3 = 'a3a3a3a3-0000-4000-8000-000000000003', V3 = 'b3b3b3b3-0000-4000-8000-000000000003';
await db.exec(`
  INSERT INTO public.products (id, category_id, name, in_stock, delivery_scope) VALUES ('${P3}', '${CAT}', 'Test Paneer', true, 'all_india');
  INSERT INTO public.product_variants (id, product_id, label, price, weight_grams, is_active) VALUES ('${V3}', '${P3}', '200 g', 90, 200, true);
  INSERT INTO public.cart_items (user_id, variant_id, quantity) VALUES ('${CUSTOMER}', '${V3}', 2);
`);
const PANEER_CART = JSON.stringify([{ variant_id: V3, quantity: 1 }]);
await expectOk('archive a product with no active subscriptions', () =>
  asQuery(ADMIN_CLAIMS, `SELECT public.set_product_archived($1, true)`, [P3]));
await expectError('archived product is refused at checkout (normalize_cart)',
  () => asQuery(CUST_CLAIMS, `SELECT public.quote_cart($1::jsonb)`, [PANEER_CART]), 'unavailable');
const paneerCart = (await db.query(
  `SELECT COUNT(*)::int AS c FROM public.cart_items WHERE variant_id = $1`, [V3])).rows[0].c;
if (paneerCart === 0) {
  ok('archiving removed the product from customer carts');
} else {
  bad('archive cart cleanup', `${paneerCart} cart rows remain`);
}
await asQuery(ADMIN_CLAIMS, `SELECT public.set_product_archived($1, false)`, [P3]);
await expectOk('restored product can be quoted again', () =>
  asQuery(CUST_CLAIMS, `SELECT public.quote_cart($1::jsonb)`, [PANEER_CART]));

// ---------------------------------------------------------------------------
// 7b. Name trim (migration 029) — re-run the migration over a dirty row.
// ---------------------------------------------------------------------------
await db.query(`UPDATE public.products SET name = '  Honey ' WHERE id = $1`, [P3]);
await db.exec(read(`${ROOT}/migrations/029_trim_product_names.sql`));
const trimmed = (await db.query(`SELECT name FROM public.products WHERE id = $1`, [P3])).rows[0].name;
if (trimmed === 'Honey') {
  ok('migration 029 trims product names ("  Honey " → "Honey")');
} else {
  bad('name trim', JSON.stringify(trimmed));
}

// ---------------------------------------------------------------------------
// 7c. cancel_subscription removes the cancelled subscription's leftover
//     orders after its end date — and nothing else (migration 030).
// ---------------------------------------------------------------------------
const cSub = (await asQuery(CUST_CLAIMS,
  `SELECT public.create_subscription($1, now(), NULL, 'active', $2::jsonb, $3::jsonb, 'CancelTest') AS id`,
  [CUSTOMER, JSON.stringify({ pincode: '600001', name: 'Cust', phoneNumber: '9000000001' }),
   JSON.stringify([{ variantId: VAR, name: 'x', variant: 'y', price: 1, quantity: 1, startDate: '2026-07-28' }])])).rows[0].id;
const ONE_ITEM = JSON.stringify([{ variant_id: VAR, quantity: 1 }]);
for (const d of ['2099-05-01', '2099-05-10']) {
  await asQuery(CUST_CLAIMS, `SELECT public.modify_daily_order($1, $2, $3::date, $4::jsonb)`, [CUSTOMER, cSub, d, ONE_ITEM]);
}
// Another subscription's order on 2099-05-10 must survive.
await db.exec(`
  BEGIN;
  WITH o AS (
    INSERT INTO public.subscription_daily_orders (delivery_date, subscription_id, user_id, status, total_value)
    VALUES ('2099-05-10', '${modSub}', '${CUSTOMER}', 'pending', 100) RETURNING id
  )
  INSERT INTO public.subscription_daily_order_items
    (daily_order_id, variant_id, product_name_snapshot, variant_label_snapshot, unit_price, quantity, total_price)
  SELECT id, '${VAR}', 'Cow Milk', '1 L', 100, 1, 100 FROM o;
  COMMIT;
`);

await expectError('another user cannot cancel this subscription',
  () => asQuery({ sub: OTHER, role: 'authenticated' },
    `SELECT public.cancel_subscription($1, $2, '2099-05-05'::timestamptz, false, 'scheduled', NULL)`, [cSub, CUSTOMER]),
  'Not authorized');

await asQuery(CUST_CLAIMS,
  `SELECT public.cancel_subscription($1, $2, '2099-05-05'::timestamptz, false, 'scheduled', NULL)`, [cSub, CUSTOMER]);
const cancelDays = (await db.query(`
  SELECT subscription_id::text AS s, delivery_date::text AS d FROM public.subscription_daily_orders
  WHERE user_id = $1 AND delivery_date IN ('2099-05-01', '2099-05-10') ORDER BY d, s`, [CUSTOMER])).rows;
const keptBeforeEnd = cancelDays.some((r) => r.s === cSub && r.d === '2099-05-01');
const droppedAfterEnd = !cancelDays.some((r) => r.s === cSub && r.d === '2099-05-10');
const otherSubKept = cancelDays.some((r) => r.s === modSub && r.d === '2099-05-10');
if (keptBeforeEnd && droppedAfterEnd && otherSubKept) {
  ok('scheduled cancel drops this subscription\'s edited day after end_date, keeps the day before it and other subscriptions\' orders');
} else {
  bad('cancel cleanup', JSON.stringify(cancelDays));
}

await asQuery(CUST_CLAIMS,
  `SELECT public.cancel_subscription($1, $2, now(), true, 'immediate', NULL)`, [cSub, CUSTOMER]);
const afterImmediate = (await db.query(
  `SELECT COUNT(*)::int AS c FROM public.subscription_daily_orders WHERE subscription_id = $1 AND delivery_date > CURRENT_DATE`,
  [cSub])).rows[0].c;
if (afterImmediate === 0) {
  ok('immediate cancel drops every future pending order of that subscription');
} else {
  bad('immediate cancel cleanup', `${afterImmediate} future orders remain`);
}

// ---------------------------------------------------------------------------
// 7d. Only the per-subscription revert_daily_order remains (migration 031).
// ---------------------------------------------------------------------------
const revertSigs = (await db.query(`
  SELECT p.oid::regprocedure::text AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'revert_daily_order'`)).rows.map((r) => r.sig);
if (revertSigs.length === 1 && revertSigs[0] === 'revert_daily_order(uuid,date,uuid)') {
  ok('2-arg revert_daily_order dropped; only revert_daily_order(uuid,date,uuid) remains');
} else {
  bad('revert_daily_order signatures', JSON.stringify(revertSigs));
}

// ---------------------------------------------------------------------------
// 7e. claim_adhoc_user hardening (migration 032).
//     Fixes phone spoofing: email-only JWTs can no longer claim a victim's
//     ad-hoc row by passing the victim's phone in p_phone.
// ---------------------------------------------------------------------------

// Setup: create a victim ad-hoc customer with a phone and wallet.
const VICTIM_ADHOC     = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const VICTIM_PHONE     = '9876500001';
const VICTIM_WALLET    = 777;
const ATTACKER_AUTH_ID = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

await db.exec(`
  DELETE FROM public.users WHERE id IN ('${VICTIM_ADHOC}', '${ATTACKER_AUTH_ID}');
  INSERT INTO public.users (id, email, phone, wallet_balance, is_adhoc, first_name)
  VALUES ('${VICTIM_ADHOC}', NULL, '${VICTIM_PHONE}', ${VICTIM_WALLET}, true, 'Victim');
`);

// (a) Attacker with email-only JWT passes victim's phone in p_phone → no claim.
//     Attacker gets a fresh row; victim row still is_adhoc with its wallet.
await asQuery(
  { sub: ATTACKER_AUTH_ID, role: 'authenticated', email: 'attacker@evil.com' },
  `SELECT public.claim_adhoc_user($1, NULL, $2, 'Attacker', NULL)`,
  [ATTACKER_AUTH_ID, VICTIM_PHONE]);
const attackerRow = (await db.query(
  `SELECT id, is_adhoc, wallet_balance FROM public.users WHERE id = $1`, [ATTACKER_AUTH_ID])).rows[0];
const victimAfterAttack = (await db.query(
  `SELECT id, phone, wallet_balance, is_adhoc FROM public.users WHERE id = $1`, [VICTIM_ADHOC])).rows[0];

if (attackerRow && attackerRow.is_adhoc === false && Number(attackerRow.wallet_balance) === 0
    && victimAfterAttack && victimAfterAttack.is_adhoc === true
    && Number(victimAfterAttack.wallet_balance) === VICTIM_WALLET
    && victimAfterAttack.phone === VICTIM_PHONE) {
  ok('attacker with email-only JWT passing victim phone → gets fresh row; victim ad-hoc row untouched');
} else {
  bad('phone spoofing protection', JSON.stringify({ attackerRow, victimAfterAttack }));
}

// (b) Customer whose JWT email matches an ad-hoc row → claimed, wallet carried over.
const EMAIL_ADHOC = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
const EMAIL_CLAIM = 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff';
const ADHOC_EMAIL = 'adhoc@example.com';
const ADHOC_WALLET = 555;
await db.exec(`
  DELETE FROM public.users WHERE id IN ('${EMAIL_ADHOC}', '${EMAIL_CLAIM}');
  INSERT INTO public.users (id, email, phone, wallet_balance, is_adhoc, first_name)
  VALUES ('${EMAIL_ADHOC}', '${ADHOC_EMAIL}', NULL, ${ADHOC_WALLET}, true, 'AdHocEmail');
`);

await asQuery(
  { sub: EMAIL_CLAIM, role: 'authenticated', email: ADHOC_EMAIL },
  `SELECT public.claim_adhoc_user($1, $2, NULL, 'Claimed', 'User')`,
  [EMAIL_CLAIM, ADHOC_EMAIL]);
const emailClaimedRow = (await db.query(
  `SELECT id, email, is_adhoc, wallet_balance FROM public.users WHERE id = $1`, [EMAIL_CLAIM])).rows[0];
const emailOldRow = (await db.query(
  `SELECT id FROM public.users WHERE id = $1`, [EMAIL_ADHOC])).rows[0];

if (emailClaimedRow && emailClaimedRow.is_adhoc === false
    && emailClaimedRow.email.toLowerCase() === ADHOC_EMAIL.toLowerCase()
    && Number(emailClaimedRow.wallet_balance) === ADHOC_WALLET
    && !emailOldRow) {
  ok('JWT email matches ad-hoc row → claimed, wallet carried over');
} else {
  bad('email claim', JSON.stringify({ emailClaimedRow, emailOldRow }));
}

// (c) JWT phone '919876500001' matches ad-hoc phone '9876500001' → claimed.
const PHONE_ADHOC = 'cccccccc-dddd-4eee-8fff-aaaaaaaaaaaa';
const PHONE_CLAIM = 'dddddddd-eeee-4fff-8aaa-bbbbbbbbbbbb';
const ADHOC_PHONE_10 = '9876500002';
const ADHOC_PHONE_WALLET = 333;
await db.exec(`
  DELETE FROM public.users WHERE id IN ('${PHONE_ADHOC}', '${PHONE_CLAIM}');
  INSERT INTO public.users (id, email, phone, wallet_balance, is_adhoc, first_name)
  VALUES ('${PHONE_ADHOC}', NULL, '${ADHOC_PHONE_10}', ${ADHOC_PHONE_WALLET}, true, 'PhoneAdhoc');
`);

await asQuery(
  { sub: PHONE_CLAIM, role: 'authenticated', phone: '91' + ADHOC_PHONE_10 },
  `SELECT public.claim_adhoc_user($1, NULL, '91${ADHOC_PHONE_10}', NULL, NULL)`,
  [PHONE_CLAIM]);
const phoneClaimedRow = (await db.query(
  `SELECT id, is_adhoc, wallet_balance FROM public.users WHERE id = $1`, [PHONE_CLAIM])).rows[0];
const phoneOldRow = (await db.query(
  `SELECT id FROM public.users WHERE id = $1`, [PHONE_ADHOC])).rows[0];

if (phoneClaimedRow && phoneClaimedRow.is_adhoc === false
    && Number(phoneClaimedRow.wallet_balance) === ADHOC_PHONE_WALLET
    && !phoneOldRow) {
  ok('JWT phone 91XXXXXXXXXX matches ad-hoc phone XXXXXXXXXX → claimed');
} else {
  bad('phone normalisation claim', JSON.stringify({ phoneClaimedRow, phoneOldRow }));
}

// (d) Two ad-hoc rows: one matches by email, one by phone (different identities)
//     → JWT with email only finds exactly one match → claimed.
//     This test confirms that when only ONE row matches, it is claimed.
const DUP_ADHOC_EMAIL = 'eeeeeeee-ffff-4aaa-8bbb-cccccccccccc';
const DUP_CLAIM_EMAIL = 'aaaabbbb-cccc-4ddd-8eee-ffffffffffff';
const DUP_EMAIL_VAL = 'dupclaim@example.com';
await db.exec(`
  DELETE FROM public.users WHERE id IN ('${DUP_ADHOC_EMAIL}', '${DUP_CLAIM_EMAIL}');
  DELETE FROM public.users WHERE email = '${DUP_EMAIL_VAL}';
  INSERT INTO public.users (id, email, phone, wallet_balance, is_adhoc, first_name)
  VALUES ('${DUP_ADHOC_EMAIL}', '${DUP_EMAIL_VAL}', NULL, 100, true, 'AdhocEmail');
`);

await asQuery(
  { sub: DUP_CLAIM_EMAIL, role: 'authenticated', email: DUP_EMAIL_VAL },
  `SELECT public.claim_adhoc_user($1, $2, NULL, 'Claimed', NULL)`,
  [DUP_CLAIM_EMAIL, DUP_EMAIL_VAL]);
const dupClaimedRow = (await db.query(
  `SELECT id, is_adhoc, wallet_balance FROM public.users WHERE id = $1`, [DUP_CLAIM_EMAIL])).rows[0];
const dupOldRow = (await db.query(
  `SELECT id FROM public.users WHERE id = $1`, [DUP_ADHOC_EMAIL])).rows[0];

if (dupClaimedRow && dupClaimedRow.is_adhoc === false
    && Number(dupClaimedRow.wallet_balance) === 100
    && !dupOldRow) {
  ok('exactly one ad-hoc matches JWT email → claimed (old row gone, wallet transferred)');
} else {
  bad('single email match claim', JSON.stringify({ dupClaimedRow, dupOldRow }));
}

// (e) Service role with p_adhoc_id claims exactly that row even when there's ambiguity.
//     Two ad-hoc rows with same email (not possible in real schema, but let's use different phones).
const SVC_ADHOC_1 = 'bbbbcccc-dddd-4eee-8fff-aaaaaaaaaaaa';
const SVC_ADHOC_2 = 'ccccdddd-eeee-4fff-8aaa-bbbbbbbbbbbb';
const SVC_AUTH = 'ddddeeee-ffff-4aaa-8bbb-cccccccccccc';
const SVC_PHONE_1 = '9876500004';
const SVC_PHONE_2 = '9876500007';
await db.exec(`
  DELETE FROM public.users WHERE id IN ('${SVC_ADHOC_1}', '${SVC_ADHOC_2}', '${SVC_AUTH}');
  DELETE FROM public.users WHERE phone IN ('${SVC_PHONE_1}', '${SVC_PHONE_2}');
  INSERT INTO public.users (id, email, phone, wallet_balance, is_adhoc, first_name)
  VALUES ('${SVC_ADHOC_1}', 'svc1@example.com', '${SVC_PHONE_1}', 111, true, 'Svc1'),
         ('${SVC_ADHOC_2}', 'svc2@example.com', '${SVC_PHONE_2}', 222, true, 'Svc2');
`);

await asQuery({ role: 'service_role' },
  `SELECT public.claim_adhoc_user($1, 'svc1@example.com', $2, 'Converted', NULL, $3)`,
  [SVC_AUTH, SVC_PHONE_1, SVC_ADHOC_1]);
const svcClaimedRow = (await db.query(
  `SELECT id, is_adhoc, wallet_balance FROM public.users WHERE id = $1`, [SVC_AUTH])).rows[0];
const svcOtherRow = (await db.query(
  `SELECT id, is_adhoc FROM public.users WHERE id = $1`, [SVC_ADHOC_2])).rows[0];

if (svcClaimedRow && svcClaimedRow.is_adhoc === false
    && Number(svcClaimedRow.wallet_balance) === 111
    && svcOtherRow && svcOtherRow.is_adhoc === true) {
  ok('service role with p_adhoc_id claims exactly that row; other ad-hoc rows untouched');
} else {
  bad('service p_adhoc_id claim', JSON.stringify({ svcClaimedRow, svcOtherRow }));
}

// (f) Service role p_adhoc_id on a non-adhoc row → error.
await expectError('service p_adhoc_id on non-adhoc row → error',
  () => asQuery({ role: 'service_role' },
    `SELECT public.claim_adhoc_user($1, 'x@example.com', NULL, NULL, NULL, $2)`,
    ['eeeeffff-aaaa-4bbb-8ccc-dddddddddddd', SVC_AUTH]),  // SVC_AUTH is now non-adhoc
  'already an app user');

// (g) Service role without p_adhoc_id when matching returns more than one row.
//     We simulate this by having two adhoc rows match on the same email (one by email, one by email).
//     But that's not possible with unique email. Instead test: service provides an email that matches
//     one ad-hoc, it claims it.
const SVC_AMB_1 = 'ffffaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
const SVC_AMB_EMAIL = 'amb@x.com';
await db.exec(`
  DELETE FROM public.users WHERE id = '${SVC_AMB_1}';
  DELETE FROM public.users WHERE email = '${SVC_AMB_EMAIL}';
  INSERT INTO public.users (id, email, phone, wallet_balance, is_adhoc)
  VALUES ('${SVC_AMB_1}', '${SVC_AMB_EMAIL}', NULL, 10, true);
`);

// Service with exactly one match (no p_adhoc_id) should claim it
const svcAmbAuth = 'bbbbcccc-dddd-4eee-8fff-111111111111';
await asQuery({ role: 'service_role' },
  `SELECT public.claim_adhoc_user($1, $2, NULL, NULL, NULL, NULL)`,
  [svcAmbAuth, SVC_AMB_EMAIL]);
const svcAmbClaimed = (await db.query(
  `SELECT id, is_adhoc, wallet_balance FROM public.users WHERE id = $1`, [svcAmbAuth])).rows[0];
if (svcAmbClaimed && svcAmbClaimed.is_adhoc === false && Number(svcAmbClaimed.wallet_balance) === 10) {
  ok('service role without p_adhoc_id + exactly one match → claims the row');
} else {
  bad('service single match claim', JSON.stringify(svcAmbClaimed));
}

// (h) p_adhoc_id from an authenticated (non-service) caller → Not authorized.
await expectError('p_adhoc_id from authenticated caller → Not authorized',
  () => asQuery({ sub: CUSTOMER, role: 'authenticated', email: 'cust@example.com' },
    `SELECT public.claim_adhoc_user($1, 'cust@example.com', NULL, NULL, NULL, $2)`,
    [CUSTOMER, VICTIM_ADHOC]),
  'Not authorized');

// (i) anon cannot execute.
const anonClaimGrant = (await db.query(
  `SELECT has_function_privilege('anon', 'public.claim_adhoc_user(uuid,text,text,text,text,uuid)', 'EXECUTE') AS ok`)).rows[0].ok;
if (anonClaimGrant === false) {
  ok('anon cannot execute claim_adhoc_user');
} else {
  bad('anon claim_adhoc_user grant', `expected false, got ${anonClaimGrant}`);
}

// (j) service claim where email collides with an existing app user → unique_violation.
const EXISTING_APP_USER = 'ccccdddd-eeee-4fff-8111-222222222222';
const COLLISION_ADHOC = 'ddddeeee-ffff-4aaa-8222-333333333333';
const COLLISION_AUTH = 'eeeeffff-aaaa-4bbb-8333-444444444444';
const COLLISION_EMAIL = 'collision@example.com';
await db.exec(`
  DELETE FROM public.users WHERE id IN ('${EXISTING_APP_USER}', '${COLLISION_ADHOC}', '${COLLISION_AUTH}');
  DELETE FROM public.users WHERE email = '${COLLISION_EMAIL}';
  INSERT INTO public.users (id, email, phone, wallet_balance, is_adhoc)
  VALUES ('${EXISTING_APP_USER}', '${COLLISION_EMAIL}', NULL, 0, false),
         ('${COLLISION_ADHOC}', 'otheremail@example.com', '9876500006', 50, true);
`);

await expectError('service claim where email collides with existing app user → unique_violation',
  () => asQuery({ role: 'service_role' },
    `SELECT public.claim_adhoc_user($1, $2, '9876500006', NULL, NULL, $3)`,
    [COLLISION_AUTH, COLLISION_EMAIL, COLLISION_ADHOC]),
  'Another account already exists');

// (k) Email and phone point at DIFFERENT ad-hoc rows → the email row (the
//     verified identity) is claimed; the phone row stays ad-hoc.
const AMB_A = 'abababab-abab-4bab-8bab-abababababab';
const AMB_B = 'bcbcbcbc-bcbc-4cbc-8cbc-bcbcbcbcbcbc';
const AMB_AUTH = 'cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd';
await db.exec(`
  DELETE FROM public.users WHERE id IN ('${AMB_A}', '${AMB_B}', '${AMB_AUTH}');
  INSERT INTO public.users (id, email, phone, wallet_balance, is_adhoc, first_name)
  VALUES ('${AMB_A}', 'both@example.com', NULL, 40, true, 'ByEmail'),
         ('${AMB_B}', NULL, '9876500099', 60, true, 'ByPhone');
`);
await asQuery({ sub: AMB_AUTH, role: 'authenticated', email: 'both@example.com', phone: '919876500099' },
  `SELECT public.claim_adhoc_user($1, NULL, NULL, NULL, NULL)`, [AMB_AUTH]);
const ambClaimed = (await db.query(`SELECT wallet_balance, is_adhoc FROM public.users WHERE id = $1`, [AMB_AUTH])).rows[0];
const ambPhoneRow = (await db.query(`SELECT is_adhoc FROM public.users WHERE id = $1`, [AMB_B])).rows[0];
if (ambClaimed && Number(ambClaimed.wallet_balance) === 40 && ambClaimed.is_adhoc === false
    && ambPhoneRow && ambPhoneRow.is_adhoc === true) {
  ok('email and phone match different ad-hoc rows → the email row is claimed, the phone row untouched');
} else {
  bad('email-over-phone precedence', JSON.stringify({ ambClaimed, ambPhoneRow }));
}

// (l) Same phone stored in two spellings ('9876500098' and '+91 98765 00098')
//     → service role without p_adhoc_id refuses to guess.
await db.exec(`
  INSERT INTO public.users (id, email, phone, wallet_balance, is_adhoc)
  VALUES ('dededede-dede-4ede-8ede-000000000001', NULL, '9876500098', 0, true),
         ('dededede-dede-4ede-8ede-000000000002', NULL, '+91 98765 00098', 0, true);
`);
await expectError('service role without p_adhoc_id + two spellings of one phone → ambiguous error',
  () => asQuery({ role: 'service_role' },
    `SELECT public.claim_adhoc_user($1, NULL, '9876500098', NULL, NULL)`,
    ['dededede-dede-4ede-8ede-000000000003']),
  'More than one ad-hoc customer');

// (m) Same tie from a customer's own sign-in → refused, nothing merged.
await expectError('customer sign-in with a phone tie → refused, nothing merged',
  () => asQuery({ sub: 'dededede-dede-4ede-8ede-000000000004', role: 'authenticated', phone: '919876500098' },
    `SELECT public.claim_adhoc_user($1, NULL, NULL, NULL, NULL)`,
    ['dededede-dede-4ede-8ede-000000000004']),
  'More than one staff-created customer record');

// ---------------------------------------------------------------------------
// 8. Migration 033: Route per address, automatic delivery dates, delivery recording
// ---------------------------------------------------------------------------
console.log('\n--- Migration 033: Routes, delivery dates, delivery recording ---');

// Grant orders:edit to the admin for these tests
await db.query(
  `INSERT INTO public.admin_role_permissions (role_id, permission) VALUES ($1, 'orders:edit') ON CONFLICT DO NOTHING`, [roleId]);

// Setup: create a delivery area with routes and pincodes for testing
const AREA_DAILY = 'aaaaaaaa-0033-4000-8000-000000000001';
const AREA_ALTERNATE = 'aaaaaaaa-0033-4000-8000-000000000002';
const ROUTE_A = 'bbbbbbbb-0033-4000-8000-000000000001';
const ROUTE_B = 'bbbbbbbb-0033-4000-8000-000000000002';
const ROUTE_C = 'bbbbbbbb-0033-4000-8000-000000000003';
const ADDR_TEST = 'cccccccc-0033-4000-8000-000000000001';
const ADDR_TEST2 = 'cccccccc-0033-4000-8000-000000000002';

await db.exec(`
  -- Clean up any existing test data
  DELETE FROM public.addresses WHERE pincode IN ('700001', '700002', '700003');
  DELETE FROM public.pincodes WHERE pincode IN ('700001', '700002', '700003');
  DELETE FROM public.delivery_routes WHERE id IN ('${ROUTE_A}', '${ROUTE_B}', '${ROUTE_C}');
  DELETE FROM public.delivery_areas WHERE id IN ('${AREA_DAILY}', '${AREA_ALTERNATE}');

  -- Create test areas
  INSERT INTO public.delivery_areas (id, display_name, is_active, delivary_frequency, reference_date, order_cutoff_time)
  VALUES
    ('${AREA_DAILY}', 'Daily Area 033', true, 1, NULL, '16:00:00'),
    ('${AREA_ALTERNATE}', 'Alternate Area 033', true, 2, '2026-10-01', '18:00:00');

  -- Create test pincodes
  INSERT INTO public.pincodes (area_id, pincode) VALUES
    ('${AREA_DAILY}', '700001'),
    ('${AREA_ALTERNATE}', '700002');

  -- Create test routes
  INSERT INTO public.delivery_routes (id, area_id, route_name, is_active) VALUES
    ('${ROUTE_A}', '${AREA_DAILY}', 'Route A 033', true),
    ('${ROUTE_B}', '${AREA_ALTERNATE}', 'Route B 033', true),
    ('${ROUTE_C}', '${AREA_DAILY}', 'Route C Inactive 033', false);

  -- Create test addresses
  INSERT INTO public.addresses (id, user_id, name, phone_number, address_line1, city, state, pincode, address_type)
  VALUES
    ('${ADDR_TEST}', '${CUSTOMER}', 'Test Customer', '9000000001', '1 Test St', 'Test City', 'TS', '700001', 'home'),
    ('${ADDR_TEST2}', '${CUSTOMER}', 'Test Customer 2', '9000000001', '2 Test St', 'Test City', 'TS', '700002', 'home');
`);

// 8a. Address route: admin can set a route that serves the pincode
const setRouteResult = await asQuery(ADMIN_CLAIMS,
  `SELECT public.set_address_route($1, $2) AS addr`, [ADDR_TEST, ROUTE_A]);
const setRouteAddr = (await db.query(`SELECT route_id FROM public.addresses WHERE id = $1`, [ADDR_TEST])).rows[0];
if (setRouteAddr.route_id === ROUTE_A) {
  ok('set_address_route: admin can assign a route that serves the pincode');
} else {
  bad('set_address_route valid', JSON.stringify(setRouteAddr));
}

// 8b. Address route: refused when route doesn't serve the pincode
await expectError('set_address_route: refused when route does not serve pincode',
  () => asQuery(ADMIN_CLAIMS,
    `SELECT public.set_address_route($1, $2)`, [ADDR_TEST, ROUTE_B]),
  'serves area .* but pincode .* is in area');

// 8c. Address route: customer cannot directly set route_id
await expectError('customer cannot directly set route_id on address',
  () => asQuery(CUST_CLAIMS,
    `UPDATE public.addresses SET route_id = $1 WHERE id = $2`, [ROUTE_A, ADDR_TEST2]),
  'delivery route is set by staff');

// 8d. set_address_route: NULL unassigns
await asQuery(ADMIN_CLAIMS,
  `SELECT public.set_address_route($1, NULL) AS addr`, [ADDR_TEST]);
const unassignResult = (await db.query(`SELECT route_id FROM public.addresses WHERE id = $1`, [ADDR_TEST])).rows[0];
if (unassignResult.route_id === null) {
  ok('set_address_route: NULL unassigns the route');
} else {
  bad('set_address_route unassign', JSON.stringify(unassignResult));
}

// 8e. set_address_route: refused for inactive route
await expectError('set_address_route: refused for inactive route',
  () => asQuery(ADMIN_CLAIMS,
    `SELECT public.set_address_route($1, $2)`, [ADDR_TEST, ROUTE_C]),
  'not active');

// 8f. anon cannot execute the new RPCs
const rpc033Grants = (await db.query(`
  SELECT
    has_function_privilege('anon', 'public.set_address_route(uuid,uuid)', 'EXECUTE') AS anon_set_route,
    has_function_privilege('anon', 'public.record_order_delivery(uuid,jsonb,text)', 'EXECUTE') AS anon_record,
    has_function_privilege('anon', 'public.reschedule_order(uuid,date)', 'EXECUTE') AS anon_reschedule,
    has_function_privilege('authenticated', 'public.set_address_route(uuid,uuid)', 'EXECUTE') AS auth_set_route,
    has_function_privilege('authenticated', 'public.record_order_delivery(uuid,jsonb,text)', 'EXECUTE') AS auth_record,
    has_function_privilege('authenticated', 'public.reschedule_order(uuid,date)', 'EXECUTE') AS auth_reschedule`)).rows[0];
if (!rpc033Grants.anon_set_route && !rpc033Grants.anon_record && !rpc033Grants.anon_reschedule
    && rpc033Grants.auth_set_route && rpc033Grants.auth_record && rpc033Grants.auth_reschedule) {
  ok('new RPCs: anon blocked, authenticated allowed');
} else {
  bad('new RPC grants', JSON.stringify(rpc033Grants));
}

// 8g. next_delivery_date for frequency 1 (daily)
const nddDaily = (await db.query(
  `SELECT internal.next_delivery_date($1, '2026-10-05'::date)::text AS d`, [AREA_DAILY])).rows[0].d;
if (nddDaily === '2026-10-05') {
  ok('next_delivery_date: frequency 1 → same day');
} else {
  bad('next_delivery_date daily', nddDaily);
}

// 8h. next_delivery_date for frequency 2 ON cadence (reference_date = 2026-10-01, testing 2026-10-03)
// 2026-10-03 - 2026-10-01 = 2 days, 2 % 2 = 0 → on cadence
const nddOnCadence = (await db.query(
  `SELECT internal.next_delivery_date($1, '2026-10-03'::date)::text AS d`, [AREA_ALTERNATE])).rows[0].d;
if (nddOnCadence === '2026-10-03') {
  ok('next_delivery_date: frequency 2, on cadence day → same day');
} else {
  bad('next_delivery_date on cadence', nddOnCadence);
}

// 8i. next_delivery_date for frequency 2 OFF cadence (reference_date = 2026-10-01, testing 2026-10-02)
// 2026-10-02 - 2026-10-01 = 1 day, 1 % 2 = 1 → off cadence, should return 2026-10-03
const nddOffCadence = (await db.query(
  `SELECT internal.next_delivery_date($1, '2026-10-02'::date)::text AS d`, [AREA_ALTERNATE])).rows[0].d;
if (nddOffCadence === '2026-10-03') {
  ok('next_delivery_date: frequency 2, off cadence day → next delivery day');
} else {
  bad('next_delivery_date off cadence', nddOffCadence);
}

// 8j. next_delivery_date for frequency > 1 with no reference_date → NULL
await db.exec(`UPDATE public.delivery_areas SET reference_date = NULL WHERE id = '${AREA_ALTERNATE}'`);
const nddNoRef = (await db.query(
  `SELECT internal.next_delivery_date($1, '2026-10-02'::date) AS d`, [AREA_ALTERNATE])).rows[0].d;
if (nddNoRef === null) {
  ok('next_delivery_date: frequency > 1 with no reference_date → NULL');
} else {
  bad('next_delivery_date no reference', nddNoRef);
}
await db.exec(`UPDATE public.delivery_areas SET reference_date = '2026-10-01' WHERE id = '${AREA_ALTERNATE}'`);

// 8k. New order gets expected_delivery_date from the area
await db.exec(`UPDATE public.users SET wallet_balance = 5000 WHERE id = '${CUSTOMER}'`);
const orderWithDateResult = await asQuery(CUST_CLAIMS,
  `SELECT public.place_order($1, $2, 'wallet', 40, $3::jsonb) AS id`,
  [CUSTOMER, ADDR_TEST, CART]);
const orderWithDate = (await db.query(
  `SELECT expected_delivery_date FROM public.orders WHERE id = $1`,
  [orderWithDateResult.rows[0].id])).rows[0];
if (orderWithDate.expected_delivery_date !== null) {
  ok(`new order gets expected_delivery_date: ${orderWithDate.expected_delivery_date}`);
} else {
  bad('order delivery date', JSON.stringify(orderWithDate));
}

// 8l. record_order_delivery: full delivery → status delivered, no refund
const orderForDelivery = (await asQuery(CUST_CLAIMS,
  `SELECT public.place_order($1, $2, 'wallet', 40, $3::jsonb) AS id`,
  [CUSTOMER, ADDR_TEST, CART])).rows[0].id;
const orderItemsForDelivery = (await db.query(
  `SELECT id, quantity FROM public.order_items WHERE order_id = $1`, [orderForDelivery])).rows;
const fullDeliveryPayload = JSON.stringify(orderItemsForDelivery.map(i => ({
  item_id: i.id,
  delivered_qty: i.quantity
})));
const balBeforeFullDelivery = Number((await db.query(
  `SELECT wallet_balance FROM public.users WHERE id = $1`, [CUSTOMER])).rows[0].wallet_balance);

const fullDeliveryResult = await asQuery(ADMIN_CLAIMS,
  `SELECT public.record_order_delivery($1, $2::jsonb, NULL) AS r`,
  [orderForDelivery, fullDeliveryPayload]);
const fullDeliveryOrder = (await db.query(
  `SELECT status, delivered_at FROM public.orders WHERE id = $1`, [orderForDelivery])).rows[0];
const balAfterFullDelivery = Number((await db.query(
  `SELECT wallet_balance FROM public.users WHERE id = $1`, [CUSTOMER])).rows[0].wallet_balance);

if (fullDeliveryResult.rows[0].r.status === 'delivered'
    && Number(fullDeliveryResult.rows[0].r.refunded) === 0
    && fullDeliveryOrder.status === 'delivered'
    && fullDeliveryOrder.delivered_at !== null
    && balAfterFullDelivery === balBeforeFullDelivery) {
  ok('record_order_delivery: full delivery → delivered, no refund');
} else {
  bad('full delivery', JSON.stringify({ result: fullDeliveryResult.rows[0].r, order: fullDeliveryOrder, balBefore: balBeforeFullDelivery, balAfter: balAfterFullDelivery }));
}

// 8m. record_order_delivery: short delivery on paid order → wallet credited
const orderForShort = (await asQuery(CUST_CLAIMS,
  `SELECT public.place_order($1, $2, 'wallet', 40, $3::jsonb) AS id`,
  [CUSTOMER, ADDR_TEST, CART])).rows[0].id;
const shortItems = (await db.query(
  `SELECT id, quantity, unit_price FROM public.order_items WHERE order_id = $1`, [orderForShort])).rows;
const shortDeliveryPayload = JSON.stringify(shortItems.map(i => ({
  item_id: i.id,
  delivered_qty: 0  // nothing delivered
})));
const expectedRefund = shortItems.reduce((sum, i) => sum + (i.quantity * Number(i.unit_price)), 0);
const balBeforeShort = Number((await db.query(
  `SELECT wallet_balance FROM public.users WHERE id = $1`, [CUSTOMER])).rows[0].wallet_balance);
const orderTotalBefore = Number((await db.query(
  `SELECT total FROM public.orders WHERE id = $1`, [orderForShort])).rows[0].total);

const shortResult = await asQuery(ADMIN_CLAIMS,
  `SELECT public.record_order_delivery($1, $2::jsonb, 'Customer unavailable') AS r`,
  [orderForShort, shortDeliveryPayload]);
const shortOrder = (await db.query(
  `SELECT status, total, cancellation_reason FROM public.orders WHERE id = $1`, [orderForShort])).rows[0];
const balAfterShort = Number((await db.query(
  `SELECT wallet_balance FROM public.users WHERE id = $1`, [CUSTOMER])).rows[0].wallet_balance);

// Zero delivered should result in cancelled status
if (shortResult.rows[0].r.status === 'cancelled'
    && Number(shortResult.rows[0].r.refunded) === expectedRefund
    && shortOrder.status === 'cancelled'
    && Number(shortOrder.total) === orderTotalBefore  // total unchanged
    && balAfterShort === balBeforeShort + expectedRefund) {
  ok(`record_order_delivery: zero delivery → cancelled, wallet refunded by ${expectedRefund}, order total unchanged`);
} else {
  bad('short delivery refund', JSON.stringify({
    result: shortResult.rows[0].r,
    order: shortOrder,
    expectedRefund,
    balBefore: balBeforeShort,
    balAfter: balAfterShort,
    orderTotalBefore
  }));
}

// 8n. record_order_delivery on already delivered order → error
await expectError('record_order_delivery on delivered order → error',
  () => asQuery(ADMIN_CLAIMS,
    `SELECT public.record_order_delivery($1, '[]'::jsonb, NULL)`, [orderForDelivery]),
  'status is delivered');

// 8o. Non-admin calling record_order_delivery → error
await expectError('non-admin cannot call record_order_delivery',
  () => asQuery(CUST_CLAIMS,
    `SELECT public.record_order_delivery($1, '[]'::jsonb, NULL)`, [orderForDelivery]),
  'Not authorized');

// 8p. Non-admin calling reschedule_order → error
await expectError('non-admin cannot call reschedule_order',
  () => asQuery(CUST_CLAIMS,
    `SELECT public.reschedule_order($1, '2026-12-01'::date)`, [orderForDelivery]),
  'Not authorized');

// 8q. reschedule_order into the past → error
const orderForReschedule = (await asQuery(CUST_CLAIMS,
  `SELECT public.place_order($1, $2, 'wallet', 40, $3::jsonb) AS id`,
  [CUSTOMER, ADDR_TEST, CART])).rows[0].id;
await expectError('reschedule_order into the past → error',
  () => asQuery(ADMIN_CLAIMS,
    `SELECT public.reschedule_order($1, '2020-01-01'::date)`, [orderForReschedule]),
  'past date');

// 8r. reschedule_order works for admin
//     Dates in 8r–8r3 are relative to today: reschedule_order refuses past
//     dates, so fixed calendar dates stop working once they pass.
const futureDate = (await db.query(
  `SELECT (internal.today_ist() + 30)::text AS d`)).rows[0].d;
await asQuery(ADMIN_CLAIMS,
  `SELECT public.reschedule_order($1, $2::date) AS o`, [orderForReschedule, futureDate]);
const rescheduleResult = (await db.query(
  `SELECT expected_delivery_date::text AS d FROM public.orders WHERE id = $1`, [orderForReschedule])).rows[0];
if (rescheduleResult.d === futureDate) {
  ok('reschedule_order: admin can reschedule to a future date');
} else {
  bad('reschedule_order', JSON.stringify(rescheduleResult));
}

// 8r2. reschedule_order snaps to the area's delivery day (migration 034).
//      Alternate Area 033: frequency 2, reference_date 2026-10-01, so it
//      delivers on every even day-offset from 1 Oct. Pick a future delivery
//      day D: a request for D+1 (not a delivery day) must snap to D+2, and a
//      request for D+4 (a delivery day) is kept.
const cadence034 = (await db.query(`
  WITH b AS (SELECT internal.today_ist() + 10 AS base),
       d AS (SELECT base + ((base - DATE '2026-10-01') % 2) AS on_day FROM b)
  SELECT (on_day + 1)::text AS off_day, (on_day + 2)::text AS snapped, (on_day + 4)::text AS kept
  FROM d`)).rows[0];
const orderAltArea = (await asQuery(CUST_CLAIMS,
  `SELECT public.place_order($1, $2, 'cod', 0, $3::jsonb) AS id`,
  [CUSTOMER, ADDR_TEST2, CART])).rows[0].id;
await asQuery(ADMIN_CLAIMS,
  `SELECT public.reschedule_order($1, $2::date)`, [orderAltArea, cadence034.off_day]);
const snapped034 = (await db.query(
  `SELECT expected_delivery_date::text AS d FROM public.orders WHERE id = $1`, [orderAltArea])).rows[0];
if (snapped034.d === cadence034.snapped) {
  ok(`reschedule_order snaps a non-delivery day forward to the area cadence (${cadence034.off_day} → ${cadence034.snapped})`);
} else {
  bad('reschedule_order snap', JSON.stringify(snapped034));
}

// 8r3. A request that is already a delivery day is kept.
await asQuery(ADMIN_CLAIMS,
  `SELECT public.reschedule_order($1, $2::date)`, [orderAltArea, cadence034.kept]);
const kept034 = (await db.query(
  `SELECT expected_delivery_date::text AS d FROM public.orders WHERE id = $1`, [orderAltArea])).rows[0];
if (kept034.d === cadence034.kept) {
  ok(`reschedule_order keeps a date that is already a delivery day (${cadence034.kept})`);
} else {
  bad('reschedule_order keep', JSON.stringify(kept034));
}

// 8s. create_subscription via app path now stores address_id
await db.exec(`UPDATE public.users SET wallet_balance = 5000 WHERE id = '${CUSTOMER}'`);
const subWithAddrPayload = JSON.stringify({
  id: ADDR_TEST,
  pincode: '700001',
  name: 'Test Customer',
  phoneNumber: '9000000001',
  addressLine1: '1 Test St',
  city: 'Test City',
  state: 'TS',
  addressType: 'home'
});
const subWithAddr = (await asQuery(CUST_CLAIMS,
  `SELECT public.create_subscription($1, now(), NULL, 'active', $2::jsonb, $3::jsonb, 'AddrTest') AS id`,
  [CUSTOMER, subWithAddrPayload, JSON.stringify([{ variantId: VAR, name: 'Cow Milk', variant: '1 L', price: 100, quantity: 1, startDate: '2026-10-01' }])])).rows[0].id;
const subAddrIdResult = (await db.query(
  `SELECT address_id FROM public.subscriptions WHERE id = $1`, [subWithAddr])).rows[0];
if (subAddrIdResult.address_id === ADDR_TEST) {
  ok('create_subscription via app path now stores address_id');
} else {
  bad('subscription address_id', JSON.stringify(subAddrIdResult));
}

// 8t. Partial delivery with some items delivered → status delivered, partial refund
const orderForPartial = (await asQuery(CUST_CLAIMS,
  `SELECT public.place_order($1, $2, 'wallet', 40, '[{"variant_id":"${VAR}","quantity":3}]'::jsonb) AS id`,
  [CUSTOMER, ADDR_TEST])).rows[0].id;
const partialItems = (await db.query(
  `SELECT id, quantity, unit_price FROM public.order_items WHERE order_id = $1`, [orderForPartial])).rows;
// Deliver 1 out of 3
const partialPayload = JSON.stringify(partialItems.map(i => ({
  item_id: i.id,
  delivered_qty: 1
})));
const expectedPartialRefund = partialItems.reduce((sum, i) => sum + ((i.quantity - 1) * Number(i.unit_price)), 0);
const balBeforePartial = Number((await db.query(
  `SELECT wallet_balance FROM public.users WHERE id = $1`, [CUSTOMER])).rows[0].wallet_balance);

const partialResult = await asQuery(ADMIN_CLAIMS,
  `SELECT public.record_order_delivery($1, $2::jsonb, NULL) AS r`,
  [orderForPartial, partialPayload]);
const balAfterPartial = Number((await db.query(
  `SELECT wallet_balance FROM public.users WHERE id = $1`, [CUSTOMER])).rows[0].wallet_balance);
const partialOrder = (await db.query(
  `SELECT status FROM public.orders WHERE id = $1`, [orderForPartial])).rows[0];

if (partialResult.rows[0].r.status === 'delivered'
    && Number(partialResult.rows[0].r.refunded) === expectedPartialRefund
    && partialOrder.status === 'delivered'
    && balAfterPartial === balBeforePartial + expectedPartialRefund) {
  ok(`partial delivery: delivered 1 of 3, refunded ${expectedPartialRefund}`);
} else {
  bad('partial delivery', JSON.stringify({
    result: partialResult.rows[0].r,
    expectedPartialRefund,
    balBefore: balBeforePartial,
    balAfter: balAfterPartial
  }));
}

// 8u. Customer changing address pincode to a different area unassigns the route
await asQuery(ADMIN_CLAIMS, `SELECT public.set_address_route($1, $2)`, [ADDR_TEST, ROUTE_A]);
// Now change pincode to one not served by ROUTE_A (which serves AREA_DAILY/700001)
// This requires a pincode in a different area or no area
await db.exec(`INSERT INTO public.pincodes (area_id, pincode) VALUES ('${AREA_ALTERNATE}', '700003') ON CONFLICT DO NOTHING`);
await asQuery(CUST_CLAIMS,
  `UPDATE public.addresses SET pincode = '700003' WHERE id = $1`, [ADDR_TEST]);
const addrAfterPincodeChange = (await db.query(
  `SELECT route_id FROM public.addresses WHERE id = $1`, [ADDR_TEST])).rows[0];
if (addrAfterPincodeChange.route_id === null) {
  ok('customer changing pincode to different area unassigns the route (app keeps working)');
} else {
  bad('pincode change route unassign', JSON.stringify(addrAfterPincodeChange));
}

// ---------------------------------------------------------------------------
// 9. Migration 035: order_tracking.user_id
//    The app filters its order_tracking Realtime listener on user_id, so the
//    column must always equal the parent order's user_id — whoever writes the
//    row, and after the order changes owner (ad-hoc → app user conversion).
// ---------------------------------------------------------------------------
console.log('\n--- Migration 035: order_tracking.user_id ---');

const trackingUsers = async (orderId) => (await db.query(
  `SELECT user_id FROM public.order_tracking WHERE order_id = $1`, [orderId])).rows.map((r) => r.user_id);

// 9a. place_order's own tracking row carries the customer's id.
await db.exec(`UPDATE public.users SET wallet_balance = 100000 WHERE id = '${CUSTOMER}'`);
const ord035 = (await asQuery(CUST_CLAIMS,
  `SELECT public.place_order($1, $2, 'wallet', 40, '[{"variant_id":"${VAR}","quantity":1}]'::jsonb) AS id`,
  [CUSTOMER, ADDR])).rows[0].id;
const placedTracking = await trackingUsers(ord035);
if (placedTracking.length === 1 && placedTracking[0] === CUSTOMER) {
  ok('place_order: tracking row gets user_id from the order');
} else {
  bad('place_order tracking user_id', JSON.stringify(placedTracking));
}

// 9b. Staff insert (admin panel path) — user_id derived; a supplied value is ignored.
await asQuery(ADMIN_CLAIMS,
  `INSERT INTO public.order_tracking (order_id, status, courier_service, user_id)
   VALUES ($1, 'shipped', 'DTDC', $2)`, [ord035, OTHER]);
const afterStaffInsert = await trackingUsers(ord035);
if (afterStaffInsert.length === 2 && afterStaffInsert.every((u) => u === CUSTOMER)) {
  ok('staff tracking insert: user_id derived from order; spoofed value overwritten');
} else {
  bad('staff tracking insert user_id', JSON.stringify(afterStaffInsert));
}

// 9c. Tracking-only update (courier / message, no order change) keeps user_id;
//     an attempt to repoint user_id is overwritten.
await asQuery(ADMIN_CLAIMS,
  `UPDATE public.order_tracking SET customer_message = 'Arriving by 8 AM', user_id = $2
   WHERE order_id = $1`, [ord035, OTHER]);
const afterUpdate = (await db.query(
  `SELECT user_id, customer_message FROM public.order_tracking WHERE order_id = $1`, [ord035])).rows;
if (afterUpdate.length === 2
    && afterUpdate.every((r) => r.user_id === CUSTOMER && r.customer_message === 'Arriving by 8 AM')) {
  ok('tracking update: message saved, user_id cannot be repointed');
} else {
  bad('tracking update user_id', JSON.stringify(afterUpdate));
}

// 9d. Order changes owner → its tracking rows follow (and follow back).
await db.query(`UPDATE public.orders SET user_id = $2 WHERE id = $1`, [ord035, OTHER]);
const followed = await trackingUsers(ord035);
await db.query(`UPDATE public.orders SET user_id = $2 WHERE id = $1`, [ord035, CUSTOMER]);
const followedBack = await trackingUsers(ord035);
if (followed.every((u) => u === OTHER) && followedBack.every((u) => u === CUSTOMER)) {
  ok('orders.user_id change carries to its tracking rows');
} else {
  bad('owner change sync', JSON.stringify({ followed, followedBack }));
}

// 9e. Ad-hoc → app user conversion. claim_adhoc_user rewrites users.id and the
//     live FKs carry it to orders.user_id with ON UPDATE CASCADE. The harness
//     strips FKs, so add that one cascade FK (NOT VALID: existing fixture rows
//     are not checked) to reproduce the production path end to end.
const ADHOC_035   = 'eeeeeeee-0035-4000-8000-000000000001';
const AUTH_035    = 'eeeeeeee-0035-4000-8000-000000000002';
const ORD_ADHOC   = 'eeeeeeee-0035-4000-8000-000000000003';
const PHONE_035   = '9876503501';
await db.exec(`
  DELETE FROM public.users WHERE id IN ('${ADHOC_035}', '${AUTH_035}') OR phone = '${PHONE_035}';
  INSERT INTO public.users (id, email, phone, wallet_balance, is_adhoc, first_name)
  VALUES ('${ADHOC_035}', 'adhoc035@example.com', '${PHONE_035}', 0, true, 'AdHoc035');

  ALTER TABLE public.orders ADD CONSTRAINT fk_order_user_035
    FOREIGN KEY (user_id) REFERENCES public.users(id) ON UPDATE CASCADE NOT VALID;

  BEGIN;
  SET LOCAL hetha.skip_money_checks = 'on';
  INSERT INTO public.orders (id, order_number, user_id, address_snapshot_id, status,
                             payment_method, payment_status, subtotal, delivery_charge, total)
  VALUES ('${ORD_ADHOC}', 'ORD-035-ADHOC', '${ADHOC_035}', '${ADDR}', 'placed', 'cod', 'pending', 0, 0, 0);
  INSERT INTO public.order_tracking (order_id, status) VALUES ('${ORD_ADHOC}', 'placed');
  COMMIT;
`);
const adhocBefore = await trackingUsers(ORD_ADHOC);
await asQuery({ role: 'service_role' },
  `SELECT public.claim_adhoc_user($1, 'adhoc035@example.com', $2, 'Converted', NULL, $3)`,
  [AUTH_035, PHONE_035, ADHOC_035]);
const adhocOrderOwner = (await db.query(
  `SELECT user_id FROM public.orders WHERE id = $1`, [ORD_ADHOC])).rows[0].user_id;
const adhocAfter = await trackingUsers(ORD_ADHOC);
await db.exec(`ALTER TABLE public.orders DROP CONSTRAINT fk_order_user_035`);
if (adhocBefore.length === 1 && adhocBefore[0] === ADHOC_035
    && adhocOrderOwner === AUTH_035
    && adhocAfter.length === 1 && adhocAfter[0] === AUTH_035) {
  ok('ad-hoc conversion: tracking user_id follows the new app user id (via cascade)');
} else {
  bad('ad-hoc conversion tracking sync', JSON.stringify({ adhocBefore, adhocOrderOwner, adhocAfter }));
}

// 9f. Backfill + idempotency: blank user_id with the trigger off (a row written
//     before the migration), then re-run the whole migration file.
await db.exec(`
  ALTER TABLE public.order_tracking DISABLE TRIGGER trg_set_order_tracking_user_id;
  UPDATE public.order_tracking SET user_id = NULL;
  ALTER TABLE public.order_tracking ENABLE TRIGGER trg_set_order_tracking_user_id;
`);
await expectOk('migration 035 re-runs cleanly (idempotent)',
  () => db.exec(read(`${ROOT}/migrations/035_order_tracking_user_id.sql`)));
const mismatches = Number((await db.query(`
  SELECT count(*) AS n FROM public.order_tracking t
  JOIN public.orders o ON o.id = t.order_id
  WHERE t.user_id IS DISTINCT FROM o.user_id`)).rows[0].n);
const trackingTotal = Number((await db.query(`SELECT count(*) AS n FROM public.order_tracking`)).rows[0].n);
if (mismatches === 0 && trackingTotal > 0) {
  ok(`backfill: all ${trackingTotal} tracking rows match their order's user_id`);
} else {
  bad('backfill', JSON.stringify({ mismatches, trackingTotal }));
}

// 9g. Trigger functions are not callable by clients.
const grants035 = (await db.query(`
  SELECT
    has_function_privilege('anon',          'internal.set_order_tracking_user_id()',  'EXECUTE') AS anon_set,
    has_function_privilege('authenticated', 'internal.set_order_tracking_user_id()',  'EXECUTE') AS auth_set,
    has_function_privilege('anon',          'internal.sync_order_tracking_user_id()', 'EXECUTE') AS anon_sync,
    has_function_privilege('authenticated', 'internal.sync_order_tracking_user_id()', 'EXECUTE') AS auth_sync`)).rows[0];
if (!grants035.anon_set && !grants035.auth_set && !grants035.anon_sync && !grants035.auth_sync) {
  ok('035 trigger functions: no EXECUTE for anon / authenticated');
} else {
  bad('035 grants', JSON.stringify(grants035));
}

// ---------------------------------------------------------------------------
// 10. Migration 036: one cut-off rule for subscriptions
// ---------------------------------------------------------------------------
console.log('\n--- 10. Migration 036: subscription cut-off rule ---');

// AREA_DAILY (pincode 700001) has order_cutoff_time 16:00 from section 9.
const scalar = async (sql, params) => Object.values((await db.query(sql, params)).rows[0])[0];
const asDate = (v) => (v instanceof Date ? v.toISOString().slice(0, 10) : String(v).slice(0, 10));

// 10a. The rule at fixed moments (p_now), in India time.
const ruleCases = [
  ['before the cut-off → tomorrow',              AREA_DAILY, '2026-11-10 10:00+05:30', '2026-11-11'],
  ['exactly at the cut-off → tomorrow',          AREA_DAILY, '2026-11-10 16:00+05:30', '2026-11-11'],
  ['after the cut-off → the day after',          AREA_DAILY, '2026-11-10 17:00+05:30', '2026-11-12'],
  ['00:30 IST (still yesterday in UTC) → uses the India date', AREA_DAILY, '2026-11-10 00:30+05:30', '2026-11-11'],
  ['month end after the cut-off',                AREA_DAILY, '2026-11-30 20:00+05:30', '2026-12-02'],
  ['no area → tomorrow',                         null,       '2026-11-10 23:00+05:30', '2026-11-11'],
];
for (const [name, area, now, want] of ruleCases) {
  const got = asDate(await scalar(
    `SELECT internal.earliest_change_date($1::uuid, $2::timestamptz)::text`, [area, now]));
  if (got === want) ok(`earliest_change_date: ${name} (${want})`);
  else bad(`earliest_change_date: ${name}`, `expected ${want}, got ${got}`);
}
await db.exec(`UPDATE public.delivery_areas SET order_cutoff_time = NULL WHERE id = '${AREA_DAILY}'`);
{
  const got = asDate(await scalar(
    `SELECT internal.earliest_change_date($1::uuid, $2::timestamptz)::text`, [AREA_DAILY, '2026-11-10 23:00+05:30']));
  if (got === '2026-11-11') ok('earliest_change_date: area with no cut-off time → always tomorrow');
  else bad('earliest_change_date: no cut-off time', `got ${got}`);
}

// Dates relative to the real clock, read from the database so the test and the
// functions agree on "today in India".
const D0 = asDate(await scalar(`SELECT internal.today_ist()::text`));
const D1 = asDate(await scalar(`SELECT (internal.today_ist() + 1)::text`));
const D2 = asDate(await scalar(`SELECT (internal.today_ist() + 2)::text`));
const D10 = asDate(await scalar(`SELECT (internal.today_ist() + 10)::text`));
const CUTOFF_PASSED = `UPDATE public.delivery_areas SET order_cutoff_time = '00:00:00' WHERE id = '${AREA_DAILY}'`;
const CUTOFF_NONE   = `UPDATE public.delivery_areas SET order_cutoff_time = NULL WHERE id = '${AREA_DAILY}'`;

// Room under the 5-subscription limit, and a wallet that passes the buffer.
await db.exec(`
  UPDATE public.subscriptions SET status = 'cancelled' WHERE user_id = '${CUSTOMER}';
  UPDATE public.users SET wallet_balance = 100000 WHERE id = '${CUSTOMER}';
`);
await db.query(
  `INSERT INTO public.admin_role_permissions (role_id, permission) VALUES ($1, 'subscriptions:edit') ON CONFLICT DO NOTHING`, [roleId]);

const ADDR_036 = JSON.stringify({ pincode: '700001', name: 'Cust', phoneNumber: '9000000001' });
const ITEMS_036 = JSON.stringify([{ variantId: VAR, quantity: 1, startDate: '2026-07-28' }]);
const newSub = async (claims, startExpr, params = []) => (await asQuery(claims,
  `SELECT public.create_subscription($1, ${startExpr}, NULL, 'active', $2::jsonb, $3::jsonb, 'Cutoff036') AS id`,
  [CUSTOMER, ADDR_036, ITEMS_036, ...params])).rows[0].id;
const subDates = async (id) => {
  const r = (await db.query(`
    SELECT s.start_date::text AS start_date, MIN(si.item_start_date)::text AS item_start
    FROM public.subscriptions s JOIN public.subscription_items si ON si.subscription_id = s.id
    WHERE s.id = $1 GROUP BY s.start_date`, [id])).rows[0];
  return { start: asDate(r.start_date), item: asDate(r.item_start) };
};

// 10b. No cut-off time: a customer's "start now" becomes tomorrow, and the
//      item's (past) start date follows the subscription.
await db.exec(CUTOFF_NONE);
const subTomorrow = await newSub(CUST_CLAIMS, 'now()');
{
  const d = await subDates(subTomorrow);
  if (d.start === D1 && d.item === D1) ok(`customer subscription with an early start is moved to tomorrow (${D1}); item start follows`);
  else bad('create_subscription clamp, no cut-off', JSON.stringify({ d, D1 }));
}

// 10c. Cut-off passed: the same request starts the day after tomorrow.
await db.exec(CUTOFF_PASSED);
const subAfterCutoff = await newSub(CUST_CLAIMS, 'now()');
{
  const d = await subDates(subAfterCutoff);
  if (d.start === D2 && d.item === D2) ok(`after the cut-off the subscription starts the day after tomorrow (${D2})`);
  else bad('create_subscription clamp, cut-off passed', JSON.stringify({ d, D2 }));
}

// 10d. A later start date chosen by the customer is kept.
const subLater = await newSub(CUST_CLAIMS, '$4::timestamptz', [`${D10}T00:00:00.000`]);
{
  const d = await subDates(subLater);
  if (d.start === D10 && d.item === D10) ok(`a later start date is kept (${D10})`);
  else bad('create_subscription keeps a later start', JSON.stringify({ d, D10 }));
}

// 10e. Admin callers choose the start date freely (ops backfill).
const subAdmin = await newSub(ADMIN_CLAIMS, '$4::timestamptz', [`${D0}T00:00:00.000`]);
{
  const d = await subDates(subAdmin);
  if (d.start === D0) ok(`admin-created subscription keeps today as its start (${D0})`);
  else bad('admin create_subscription not clamped', JSON.stringify({ d, D0 }));
}

// 10f. Day edits by the customer, cut-off passed → earliest changeable day is D2.
const ONE = JSON.stringify([{ variant_id: VAR, quantity: 1 }]);
const modify = (claims, date) => asQuery(claims,
  `SELECT public.modify_daily_order($1, $2, $3::date, $4::jsonb)`, [CUSTOMER, subTomorrow, date, ONE]);
const revert = (claims, date) => asQuery(claims,
  `SELECT public.revert_daily_order($1, $2::date, $3::uuid)`, [CUSTOMER, date, subTomorrow]);
const bulk = (claims, dates) => asQuery(claims,
  `SELECT public.modify_daily_orders_bulk($1, $2, $3::jsonb)`,
  [CUSTOMER, subTomorrow, JSON.stringify(dates.map((d) => ({ delivery_date: d, items: [{ variant_id: VAR, quantity: 1 }] })))]);
const ordersOn = async (date) => Number(await scalar(
  `SELECT count(*) FROM public.subscription_daily_orders WHERE subscription_id = $1 AND delivery_date = $2::date`,
  [subTomorrow, date]));

await expectError("customer cannot change today's order", () => modify(CUST_CLAIMS, D0), 'no longer be changed');
await expectError('customer cannot change tomorrow after the cut-off', () => modify(CUST_CLAIMS, D1), 'no longer be changed');
await expectError('past date still reports "past"', () => modify(CUST_CLAIMS, '2000-01-01'), 'past');
await expectOk('customer can change the day after tomorrow', () => modify(CUST_CLAIMS, D2));
await expectError('bulk edit is refused when one day is past the cut-off', () => bulk(CUST_CLAIMS, [D10, D1]), 'no longer be changed');
if (await ordersOn(D10) === 0) ok('refused bulk edit wrote nothing');
else bad('refused bulk edit wrote nothing', 'an order exists for the allowed day of the refused batch');
await expectOk('bulk edit of changeable days is allowed', () => bulk(CUST_CLAIMS, [D10]));
await expectError('customer cannot reset tomorrow after the cut-off', () => revert(CUST_CLAIMS, D1), 'no longer be changed');
await expectOk('customer can reset the day after tomorrow', () => revert(CUST_CLAIMS, D2));
if (await ordersOn(D2) === 0) ok('reset removed the customer edit');
else bad('reset removed the customer edit', 'order still present');

// Admins with subscriptions:edit are not bound by the cut-off.
await expectOk('admin can still change tomorrow after the cut-off', () => modify(ADMIN_CLAIMS, D1));
await expectOk('admin can still reset tomorrow after the cut-off', () => revert(ADMIN_CLAIMS, D1));

// No cut-off time → tomorrow is changeable, today is not.
await db.exec(CUTOFF_NONE);
await expectOk('with no cut-off time the customer can change tomorrow', () => modify(CUST_CLAIMS, D1));
await expectError('with no cut-off time today is still closed', () => modify(CUST_CLAIMS, D0), 'no longer be changed');

// 10g. The app helper, and grants.
await db.exec(CUTOFF_PASSED);
{
  const serviceable = asDate(await scalar(`SELECT public.get_earliest_subscription_start('700001')::text`));
  const unknown = asDate(await scalar(`SELECT public.get_earliest_subscription_start('999999')::text`));
  if (serviceable === D2 && unknown === D1) ok(`get_earliest_subscription_start: area past cut-off → ${D2}, unknown pincode → ${D1}`);
  else bad('get_earliest_subscription_start', JSON.stringify({ serviceable, unknown, D1, D2 }));
}
const grants036 = (await db.query(`
  SELECT
    has_function_privilege('anon',          'public.get_earliest_subscription_start(text)',         'EXECUTE') AS anon_pub,
    has_function_privilege('authenticated', 'public.get_earliest_subscription_start(text)',         'EXECUTE') AS auth_pub,
    has_function_privilege('authenticated', 'internal.earliest_change_date(uuid, timestamptz)',     'EXECUTE') AS auth_rule,
    has_function_privilege('anon',          'internal.assert_day_changeable(uuid, date)',           'EXECUTE') AS anon_assert,
    has_function_privilege('authenticated', 'internal.assert_day_changeable(uuid, date)',           'EXECUTE') AS auth_assert,
    has_function_privilege('authenticated', 'public.modify_daily_order(uuid, uuid, date, jsonb)',   'EXECUTE') AS auth_modify,
    has_function_privilege('authenticated', 'public.modify_daily_orders_bulk(uuid, uuid, jsonb)',   'EXECUTE') AS auth_bulk,
    has_function_privilege('authenticated', 'public.revert_daily_order(uuid, date, uuid)',          'EXECUTE') AS auth_revert,
    has_function_privilege('anon',          'public.modify_daily_order(uuid, uuid, date, jsonb)',   'EXECUTE') AS anon_modify`)).rows[0];
if (!grants036.anon_pub && grants036.auth_pub && !grants036.auth_rule && !grants036.anon_assert
    && !grants036.auth_assert && grants036.auth_modify && grants036.auth_bulk && grants036.auth_revert
    && !grants036.anon_modify) {
  ok('036 grants: helper for authenticated only; internal functions closed; day-edit RPC grants unchanged');
} else {
  bad('036 grants', JSON.stringify(grants036));
}

// 10i. Pauses follow the same cut-off. subTomorrow is in AREA_DAILY.
const D3 = asDate(await scalar(`SELECT (internal.today_ist() + 3)::text`));
const D4 = asDate(await scalar(`SELECT (internal.today_ist() + 4)::text`));
const DM1 = asDate(await scalar(`SELECT (internal.today_ist() - 1)::text`));
const pause = (claims, start, end) => asQuery(claims,
  `SELECT public.upsert_pauses($1, $2::jsonb)`, [subTomorrow, JSON.stringify([{ start, end }])]);
const resume = (claims, dates) => asQuery(claims,
  `SELECT public.remove_paused_dates($1, $2::jsonb)`, [subTomorrow, JSON.stringify(dates)]);
const pauseRanges = async () => (await db.query(`
  SELECT pause_start_date::text AS s, pause_end_date::text AS e
  FROM public.subscription_pauses WHERE subscription_id = $1 ORDER BY pause_start_date`, [subTomorrow]))
  .rows.map((r) => `${asDate(r.s)}..${asDate(r.e)}`).join(', ');
const expectRanges = async (name, want) => {
  const got = await pauseRanges();
  if (got === want) ok(`${name} (${want || 'no pauses'})`);
  else bad(name, `expected "${want}", got "${got}"`);
};
await db.query(`DELETE FROM public.subscription_pauses WHERE subscription_id = $1`, [subTomorrow]);

// Cut-off passed → earliest changeable day is D2.
await db.exec(CUTOFF_PASSED);
await expectError('customer cannot pause today', () => pause(CUST_CLAIMS, D0, D0), 'no longer be paused');
await expectError('customer cannot pause tomorrow after the cut-off', () => pause(CUST_CLAIMS, D1, D1), 'no longer be paused');
await expectError('a range that starts before the cut-off day is refused whole', () => pause(CUST_CLAIMS, D1, D3), 'no longer be paused');
await expectError('customer cannot pause a past day', () => pause(CUST_CLAIMS, DM1, DM1), 'no longer be paused');
await expectError('pause with end before start is refused', () => pause(CUST_CLAIMS, D3, D2), 'start date and an end date');
await expectRanges('refused pauses wrote nothing', '');
await expectOk('customer can pause from the day after tomorrow', () => pause(CUST_CLAIMS, D2, D3));
await expectRanges('pause stored', `${D2}..${D3}`);

// Staff pause tomorrow for the customer; the customer may then extend that
// pause (tomorrow is already paused, so it is not a change) but not undo it.
await expectOk('admin can pause tomorrow after the cut-off', () => pause(ADMIN_CLAIMS, D1, D1));
await expectRanges('admin pause merged with the adjacent range', `${D1}..${D3}`);
await expectOk('customer can extend a pause that already covers tomorrow', () => pause(CUST_CLAIMS, D1, D4));
await expectRanges('extended pause', `${D1}..${D4}`);
await expectError('customer cannot un-pause tomorrow after the cut-off', () => resume(CUST_CLAIMS, [D1]), 'no longer be removed');
await expectError('a resume batch with one locked day is refused whole', () => resume(CUST_CLAIMS, [D3, D1]), 'no longer be removed');
await expectRanges('refused resume changed nothing', `${D1}..${D4}`);
await expectOk('customer can un-pause a later day (range splits around it)', () => resume(CUST_CLAIMS, [D3]));
await expectRanges('split keeps the locked first day paused', `${D1}..${D2}, ${D4}..${D4}`);
await expectOk('resuming a day that is not paused is a no-op, even before the cut-off day', () => resume(CUST_CLAIMS, [D0]));
await expectOk('admin can un-pause tomorrow after the cut-off', () => resume(ADMIN_CLAIMS, [D1]));
await expectRanges('admin resume applied', `${D2}..${D2}, ${D4}..${D4}`);
await expectError('another customer cannot pause this subscription', () => pause({ sub: OTHER, role: 'authenticated' }, D4, D4), 'Not authorized');

// Direct insert into the table (what a hand-made request could do).
const directPause = (claims, start, end) => asQuery(claims,
  `INSERT INTO public.subscription_pauses (subscription_id, pause_start_date, pause_end_date, created_by)
   VALUES ($1, $2::date, $3::date, 'user')`, [subTomorrow, start, end]);
await expectError('direct insert of a pause for tomorrow is refused after the cut-off',
  () => directPause(CUST_CLAIMS, D1, D1), 'no longer be paused');
await expectOk('direct insert of a later pause is allowed', () => directPause(CUST_CLAIMS, D10, D10));
await expectOk('service role can insert any pause directly', () => directPause({ role: 'service_role' }, D0, D0));

// No cut-off time → tomorrow can be paused and resumed, today cannot.
await db.exec(CUTOFF_NONE);
await db.query(`DELETE FROM public.subscription_pauses WHERE subscription_id = $1`, [subTomorrow]);
await expectOk('with no cut-off time the customer can pause tomorrow', () => pause(CUST_CLAIMS, D1, D1));
await expectOk('with no cut-off time the customer can resume tomorrow', () => resume(CUST_CLAIMS, [D1]));
await expectError('with no cut-off time today still cannot be paused', () => pause(CUST_CLAIMS, D0, D0), 'no longer be paused');
await expectRanges('pauses clean at the end', '');

const grants036p = (await db.query(`
  SELECT
    has_function_privilege('authenticated', 'public.upsert_pauses(uuid, jsonb)',                 'EXECUTE') AS auth_upsert,
    has_function_privilege('authenticated', 'public.remove_paused_dates(uuid, jsonb)',           'EXECUTE') AS auth_remove,
    has_function_privilege('anon',          'public.upsert_pauses(uuid, jsonb)',                 'EXECUTE') AS anon_upsert,
    has_function_privilege('authenticated', 'internal.subscription_earliest_change_date(uuid)',  'EXECUTE') AS auth_lookup,
    has_function_privilege('authenticated', 'internal.guard_direct_pause_insert()',              'EXECUTE') AS auth_guard,
    (SELECT count(*) FROM pg_trigger WHERE tgname = 'trg_guard_direct_pause_insert')::int                  AS triggers`)).rows[0];
if (grants036p.auth_upsert && grants036p.auth_remove && !grants036p.anon_upsert
    && !grants036p.auth_lookup && !grants036p.auth_guard && grants036p.triggers === 1) {
  ok('036 pause grants unchanged; internal helpers closed; one insert trigger');
} else {
  bad('036 pause grants', JSON.stringify(grants036p));
}

// 10h. Idempotent.
await expectOk('migration 036 re-runs cleanly (idempotent)',
  () => db.exec(read(`${ROOT}/migrations/036_subscription_cutoff_rule.sql`)));
// 036 re-declares create_subscription_core with its 3-day wallet rule; 039
// replaced that rule. Re-apply 039 as the owner would after re-running 036.
await db.exec(read(`${ROOT}/migrations/039_wallet_simplification.sql`));

// ---------------------------------------------------------------------------
// 11. Migration 037: one settlement function for subscription daily orders
// ---------------------------------------------------------------------------
console.log('\n--- 11. Migration 037: daily order settlement ---');
{
  const { randomUUID } = await import('node:crypto');
  const U1 = 'a0370000-0000-4000-8000-000000000001';
  const U2 = 'a0370000-0000-4000-8000-000000000002';
  const SERVICE = { role: 'service_role' };
  const num = (v) => Number(v);
  const eq = (name, got, want) => {
    const g = JSON.stringify(got), w = JSON.stringify(want);
    if (g === w) ok(`${name} (${w})`); else bad(name, `expected ${w}, got ${g}`);
  };
  const rpc = async (claims, call, params) => {
    const r = (await asQuery(claims, `SELECT ${call} AS r`, params)).rows[0].r;
    return typeof r === 'string' ? JSON.parse(r) : r;
  };

  await db.exec(`
    INSERT INTO public.users (id, email, phone, first_name, wallet_balance)
    VALUES ('${U1}', 'u1-037@example.com', '9037000001', 'U1', 0),
           ('${U2}', 'u2-037@example.com', '9037000002', 'U2', 0);
  `);
  await db.query(
    `INSERT INTO public.admin_role_permissions (role_id, permission) VALUES ($1, 'daily_ops:edit') ON CONFLICT DO NOTHING`, [roleId]);

  const setBalance = (user, amount) =>
    db.query(`UPDATE public.users SET wallet_balance = $2 WHERE id = $1`, [user, amount]);
  const balance = async (user) =>
    num((await db.query(`SELECT wallet_balance FROM public.users WHERE id = $1`, [user])).rows[0].wallet_balance);

  // A subscription row (only what the settlement functions read).
  const mkSub = async (user, createdAt, method = 'wallet') => {
    const id = randomUUID();
    await db.query(
      `INSERT INTO public.subscriptions (id, user_id, status, payment_method, created_at, snapshot_pincode)
       VALUES ($1, $2, 'active', $3, $4::timestamp, '700001')`, [id, user, method, createdAt]);
    return id;
  };
  // A daily order with its items, written in one transaction (deferred total check).
  const mkOrder = async (sub, user, date, lines, extra = {}) => {
    const id = randomUUID();
    const items = lines.map((l) => ({ id: randomUUID(), qty: l.qty, price: l.price ?? 100 }));
    const total = items.reduce((s, i) => s + i.qty * i.price, 0);
    const itemRows = items.map((i) =>
      `('${i.id}', '${id}', '${VAR}', 'Cow Milk', '1 L', ${i.price}, ${i.qty}, ${i.qty * i.price})`).join(', ');
    await db.exec(`
      BEGIN;
      INSERT INTO public.subscription_daily_orders
        (id, delivery_date, subscription_id, user_id, status, total_value, payment_status, is_finalized)
      VALUES ('${id}', '${date}', '${sub}', '${user}', '${extra.status ?? 'pending'}', ${total},
              '${extra.payment_status ?? 'pending'}', ${extra.is_finalized ?? false});
      INSERT INTO public.subscription_daily_order_items
        (id, daily_order_id, variant_id, product_name_snapshot, variant_label_snapshot, unit_price, quantity, total_price)
      VALUES ${itemRows};
      COMMIT;`);
    return { id, items: items.map((i) => i.id), total };
  };
  const order = async (id) => {
    const r = (await db.query(`
      SELECT status, payment_status, paid_amount, skip_reason, is_finalized,
             settlement_hold_reason IS NOT NULL AS on_hold
      FROM public.subscription_daily_orders WHERE id = $1`, [id])).rows[0];
    return { status: r.status, payment: r.payment_status, paid: num(r.paid_amount),
             skip: r.skip_reason, finalized: r.is_finalized, hold: r.on_hold };
  };
  const ledgerNet = async (id) => num((await db.query(`
    SELECT COALESCE(SUM(CASE WHEN type = 'debit' THEN amount ELSE -amount END), 0) AS n
    FROM public.wallet_transactions WHERE reference_type = 'subscription' AND reference_id = $1`, [id])).rows[0].n);
  const run = async (date) => {
    const r = (await db.query(
      `SELECT status, total_orders, total_value FROM public.daily_ops_runs WHERE delivery_date = $1`, [date])).rows[0];
    return r ? { status: r.status, orders: num(r.total_orders), value: num(r.total_value) } : null;
  };
  const deliveredQty = async (orderId) => (await db.query(`
    SELECT delivered_qty FROM public.subscription_daily_order_items
    WHERE daily_order_id = $1 ORDER BY quantity DESC, id`, [orderId])).rows.map((r) => r.delivered_qty);

  const finalize  = (claims, date) => rpc(claims, `public.finalize_daily_run($1::date, $2)`, [date, ADMIN]);
  const unlock    = (claims, date) => rpc(claims, `public.unlock_daily_run($1::date)`, [date]);
  const reconcile = (claims, date) => rpc(claims, `public.reconcile_daily_run($1::date, $2)`, [date, ADMIN]);
  const retry     = (claims, id)   => rpc(claims, `public.retry_daily_order_payment($1)`, [id]);
  const setStatus = (claims, ids, status) =>
    rpc(claims, `public.set_daily_order_status($1::uuid[], $2)`, [`{${ids.join(',')}}`, status]);
  const deliver = (claims, o, qtys, note = null) => rpc(claims,
    `public.record_subscription_delivery($1, $2::jsonb, $3)`,
    [o.id, JSON.stringify(qtys.map((q, i) => ({ item_id: o.items[i], delivered_qty: q })).filter((x) => x.delivered_qty !== null)), note]);

  const allOrders = [];   // every order this section creates, for the ledger check at the end
  const track = (o) => { allOrders.push(o.id); return o; };

  // ── 11a. Backfill from the wallet ledger ──────────────────────────────────
  // Legacy rows (settled_at NULL), then the migration is run again.
  const subL = [];
  for (let i = 0; i < 7; i++) subL.push(await mkSub(U1, `2019-01-0${i + 1}`));
  const BF = '2097-01-01';
  const L1 = await mkOrder(subL[0], U1, BF, [{ qty: 2 }], { payment_status: 'paid', is_finalized: true });
  const L2 = await mkOrder(subL[1], U1, BF, [{ qty: 2 }], { payment_status: 'paid', is_finalized: true });
  const L3 = await mkOrder(subL[2], U1, BF, [{ qty: 2 }], { payment_status: 'paid', is_finalized: true });
  const L4 = await mkOrder(subL[3], U1, BF, [{ qty: 2 }]);
  const L5 = await mkOrder(subL[4], U1, BF, [{ qty: 2 }], { payment_status: 'failed', is_finalized: true });
  const L6 = await mkOrder(subL[5], U1, BF, [{ qty: 2 }], { payment_status: 'paid', is_finalized: true });
  const L7 = await mkOrder(subL[6], U1, BF, [{ qty: 2 }], { payment_status: 'failed', is_finalized: true });
  const legacyTxn = (orderId, type, amount) => db.query(`
    INSERT INTO public.wallet_transactions (user_id, type, amount, balance_after, description, reference_type, reference_id)
    VALUES ($1, $2, $3, 0, 'legacy', 'subscription', $4)`, [U1, type, amount, orderId]);
  await legacyTxn(L1.id, 'debit', 200);
  await legacyTxn(L3.id, 'debit', 150);
  await legacyTxn(L5.id, 'debit', 100);
  await legacyTxn(L6.id, 'debit', 200);
  await legacyTxn(L6.id, 'credit', 200);

  await expectOk('migration 037 re-runs cleanly and backfills legacy rows',
    () => db.exec(read(`${ROOT}/migrations/037_daily_order_settlement.sql`)));
  // 037 re-declares its functions, which drops the trusted flag 038 attaches
  // to them; re-apply 038 as the owner would after re-running 037.
  await db.exec(read(`${ROOT}/migrations/038_daily_ops_structure.sql`));
  const bf = async (o) => { const r = await order(o.id); return { paid: r.paid, hold: r.hold }; };
  eq('backfill: paid + matching debit → paid_amount from the ledger, no hold', await bf(L1), { paid: 200, hold: false });
  eq('backfill: paid but no wallet transaction → 0 and on hold (not guessed from the total)', await bf(L2), { paid: 0, hold: true });
  eq('backfill: paid but ledger (150) ≠ total (200) → ledger amount, on hold', await bf(L3), { paid: 150, hold: true });
  eq('backfill: pending with no ledger → 0, no hold', await bf(L4), { paid: 0, hold: false });
  eq('backfill: failed but ledger shows a debit → on hold', await bf(L5), { paid: 100, hold: true });
  eq('backfill: paid but already refunded by hand (net 0) → on hold', await bf(L6), { paid: 0, hold: true });
  eq('backfill: went out with a failed debit under the old system → on hold, not charged later', await bf(L7), { paid: 0, hold: true });
  await expectError('an order on payment hold cannot be settled',
    () => setStatus(ADMIN_CLAIMS, [L2.id], 'cancelled'), 'needs review');
  eq('refused change left the held order untouched', (await order(L2.id)).status, 'pending');

  // ── 11b. Finalize, and a second finalize ──────────────────────────────────
  const D1 = '2097-02-01';
  const sub1a = await mkSub(U1, '2020-01-01');
  await setBalance(U1, 1000);
  const O1 = track(await mkOrder(sub1a, U1, D1, [{ qty: 2 }, { qty: 1 }]));   // 300
  await expectError('a customer cannot finalize', () => finalize({ sub: U1, role: 'authenticated' }, D1), 'not authorized');
  const f1 = await finalize(ADMIN_CLAIMS, D1);
  eq('finalize result', { finalized: f1.finalized, deducted: f1.total_deducted, charged: f1.charged.length, skipped: f1.skipped.length, errors: f1.deduction_errors.length },
    { finalized: 1, deducted: 300, charged: 1, skipped: 0, errors: 0 });
  eq('finalize: order paid in full', await order(O1.id),
    { status: 'pending', payment: 'paid', paid: 300, skip: null, finalized: true, hold: false });
  eq('finalize: wallet debited once', await balance(U1), 700);
  await expectError('second finalize of the same day is refused', () => finalize(ADMIN_CLAIMS, D1), 'already finalized');
  eq('second finalize took nothing', { balance: await balance(U1), ledger: await ledgerNet(O1.id) }, { balance: 700, ledger: 300 });

  // ── 11c. Partial delivery, repeats and corrections ────────────────────────
  await expectError('a customer cannot record a delivery', () => deliver({ sub: U1, role: 'authenticated' }, O1, [2, 1]), 'Not authorized');
  await expectError('every item needs a delivered quantity', () => deliver(ADMIN_CLAIMS, O1, [1, null]), 'every item');
  await expectError('delivered quantity above the ordered one is refused', () => deliver(ADMIN_CLAIMS, O1, [3, 1]), 'exceeds');
  eq('refused recordings moved no money', { balance: await balance(U1), qty: await deliveredQty(O1.id) }, { balance: 700, qty: [null, null] });

  const d1 = await deliver(ADMIN_CLAIMS, O1, [1, 1]);
  eq('partial delivery: 1 of 2 short → refund ₹100', { status: d1.status, refunded: d1.refunded, charged: d1.charged, short: d1.short },
    { status: 'delivered', refunded: 100, charged: 0, short: true });
  eq('partial delivery: wallet and order', { balance: await balance(U1), ...(await order(O1.id)) },
    { balance: 800, status: 'delivered', payment: 'paid', paid: 200, skip: null, finalized: true, hold: false });

  const d2 = await deliver(ADMIN_CLAIMS, O1, [1, 1]);
  eq('recording the same delivery again moves nothing', { refunded: d2.refunded, charged: d2.charged, balance: await balance(U1) },
    { refunded: 0, charged: 0, balance: 800 });

  const d3 = await deliver(ADMIN_CLAIMS, O1, [2, 1]);
  eq('correcting the quantity upward charges only the difference', { charged: d3.charged, refunded: d3.refunded, short: d3.short, balance: await balance(U1) },
    { charged: 100, refunded: 0, short: false, balance: 700 });

  const d4 = await deliver(ADMIN_CLAIMS, O1, [0, 0]);
  eq('nothing delivered → cancelled and fully refunded', { status: d4.status, refunded: d4.refunded, balance: await balance(U1), ...(await order(O1.id)) },
    { status: 'cancelled', refunded: 300, balance: 1000, payment: 'refunded', paid: 0, skip: null, finalized: true, hold: false });

  await setBalance(U1, 50);
  await expectError('a correction the wallet cannot cover is refused', () => deliver(ADMIN_CLAIMS, O1, [2, 1]), 'too low');
  eq('refused correction changed nothing', { balance: await balance(U1), qty: await deliveredQty(O1.id), status: (await order(O1.id)).status },
    { balance: 50, qty: [0, 0], status: 'cancelled' });
  await setBalance(U1, 1000);
  const d5 = await deliver(ADMIN_CLAIMS, O1, [2, 1]);
  eq('after a recharge the correction goes through', { status: d5.status, charged: d5.charged, balance: await balance(U1), paid: (await order(O1.id)).paid },
    { status: 'delivered', charged: 300, balance: 700, paid: 300 });

  // ── 11d. Insufficient balance: deterministic priority, skip, retry ────────
  const D2 = '2097-02-02';
  const subNew = await mkSub(U2, '2021-06-01');   // newer subscription, order inserted FIRST
  const subOld = await mkSub(U2, '2020-06-01');   // older subscription
  const sub1b = await mkSub(U1, '2020-01-02');
  const ONew = track(await mkOrder(subNew, U2, D2, [{ qty: 2 }]));   // 200
  const OOld = track(await mkOrder(subOld, U2, D2, [{ qty: 2 }]));   // 200
  const OU1  = track(await mkOrder(sub1b, U1, D2, [{ qty: 1 }]));    // 100
  await setBalance(U2, 250);                                          // covers one, not both
  const u1Before = await balance(U1);
  const f2 = await finalize(ADMIN_CLAIMS, D2);
  eq('wallet short: older subscription charged, newer one skipped',
    { old: (await order(OOld.id)).payment, oldPaid: (await order(OOld.id)).paid, ...(await order(ONew.id)) },
    { old: 'paid', oldPaid: 200, status: 'skipped', payment: 'failed', paid: 0, skip: 'insufficient_balance', finalized: true, hold: false });
  eq('wallet short: finalize reports who was skipped',
    { skipped: f2.skipped.map((s) => [s.order_id, s.user_id, s.amount, s.reason]), charged: f2.charged.length, deducted: f2.total_deducted },
    { skipped: [[ONew.id, U2, 200, 'insufficient_balance']], charged: 2, deducted: 300 });
  eq('wallet short: nothing taken for the skipped order', { u2: await balance(U2), ledger: await ledgerNet(ONew.id) }, { u2: 50, ledger: 0 });
  eq('another customer on the same day is charged normally', { u1: u1Before - (await balance(U1)), paid: (await order(OU1.id)).paid }, { u1: 100, paid: 100 });
  eq('run totals leave the skipped order out', await run(D2), { status: 'finalized', orders: 2, value: 300 });

  await expectError('a skipped-for-payment order cannot be delivered', () => deliver(ADMIN_CLAIMS, ONew, [2]), 'Retry payment');
  await expectError('a skipped-for-payment order cannot be set back by a status change', () => setStatus(ADMIN_CLAIMS, [ONew.id], 'pending'), 'Retry payment');
  await expectError('retry while the wallet is still short is refused', () => retry(ADMIN_CLAIMS, ONew.id), 'too low');
  eq('refused retry left the order skipped', { ...(await order(ONew.id)), u2: await balance(U2) },
    { status: 'skipped', payment: 'failed', paid: 0, skip: 'insufficient_balance', finalized: true, hold: false, u2: 50 });
  await expectError('a customer cannot retry a payment', () => retry({ sub: U2, role: 'authenticated' }, ONew.id), 'Not authorized');

  await setBalance(U2, 300);
  const r1 = await retry(ADMIN_CLAIMS, ONew.id);
  eq('retry after a recharge charges the order and puts it back', { charged: r1.charged, u2: await balance(U2), ...(await order(ONew.id)) },
    { charged: 200, u2: 100, status: 'pending', payment: 'paid', paid: 200, skip: null, finalized: true, hold: false });
  eq('run totals include the retried order', await run(D2), { status: 'finalized', orders: 3, value: 500 });
  await expectError('retrying an order that is no longer skipped is refused', () => retry(ADMIN_CLAIMS, ONew.id), 'Only an order skipped');
  eq('second retry took nothing', await balance(U2), 100);

  // ── 11e. Status changes on a finalized day ────────────────────────────────
  await expectError('invalid status is refused', () => setStatus(ADMIN_CLAIMS, [OU1.id], 'lost'), 'Invalid status');
  await expectError('a customer cannot change order status', () => setStatus({ sub: U1, role: 'authenticated' }, [OU1.id], 'skipped'), 'Not authorized');
  let u1 = await balance(U1);
  const s1 = await setStatus(ADMIN_CLAIMS, [OU1.id], 'skipped');
  eq('staff skip after finalize → full refund', { refunded: s1.refunded, updated: s1.updated, gain: (await balance(U1)) - u1, ...(await order(OU1.id)) },
    { refunded: 100, updated: 1, gain: 100, status: 'skipped', payment: 'refunded', paid: 0, skip: null, finalized: true, hold: false });
  const s1b = await setStatus(ADMIN_CLAIMS, [OU1.id], 'skipped');
  eq('same status again is a no-op', { updated: s1b.updated, refunded: s1b.refunded, balance: (await balance(U1)) - u1 }, { updated: 0, refunded: 0, balance: 100 });
  const s2 = await setStatus(ADMIN_CLAIMS, [OU1.id], 'pending');
  eq('undo the skip → charged again', { charged: s2.charged, balance: (await balance(U1)) - u1, paid: (await order(OU1.id)).paid }, { charged: 100, balance: 0, paid: 100 });
  const s3 = await setStatus(ADMIN_CLAIMS, [OU1.id, OOld.id], 'delivered');
  eq('bulk mark delivered records full quantities and moves no money',
    { updated: s3.updated, refunded: s3.refunded, charged: s3.charged, q1: await deliveredQty(OU1.id), q2: await deliveredQty(OOld.id) },
    { updated: 2, refunded: 0, charged: 0, q1: [1], q2: [2] });
  const s4 = await setStatus(ADMIN_CLAIMS, [OOld.id], 'cancelled');
  eq('cancel a delivered order → full refund', { refunded: s4.refunded, u2: await balance(U2), payment: (await order(OOld.id)).payment }, { refunded: 200, u2: 300, payment: 'refunded' });

  const s5 = await setStatus(ADMIN_CLAIMS, [OOld.id], 'pending');
  eq('undo a cancel → quantities cleared and charged in full again',
    { charged: s5.charged, u2: await balance(U2), qty: await deliveredQty(OOld.id), paid: (await order(OOld.id)).paid },
    { charged: 200, u2: 100, qty: [null], paid: 200 });

  const D2b = '2097-02-03';
  const sub1c = await mkSub(U1, '2020-01-03');
  const ODraft = track(await mkOrder(sub1c, U1, D2b, [{ qty: 1 }]));
  u1 = await balance(U1);
  await setStatus(ADMIN_CLAIMS, [ODraft.id], 'skipped');
  eq('status change before finalize moves no money', { balance: await balance(U1), ...(await order(ODraft.id)) },
    { balance: u1, status: 'skipped', payment: 'pending', paid: 0, skip: null, finalized: false, hold: false });
  await expectError('an order cannot be marked delivered before the day is finalized', () => setStatus(ADMIN_CLAIMS, [ODraft.id], 'delivered'), 'Finalize the day');
  await setStatus(ADMIN_CLAIMS, [ODraft.id], 'pending');
  await expectError('a delivery cannot be recorded before the day is finalized', () => deliver(ADMIN_CLAIMS, ODraft, [1]), 'Finalize the day');

  // ── 11f. Unlock → edit → finalize again ───────────────────────────────────
  const D3 = '2097-02-04';
  const sub1d = await mkSub(U1, '2020-01-04');
  await setBalance(U1, 1000);
  const OE = track(await mkOrder(sub1d, U1, D3, [{ qty: 2 }]));   // 200
  await finalize(ADMIN_CLAIMS, D3);
  eq('before unlock', { balance: await balance(U1), paid: (await order(OE.id)).paid }, { balance: 800, paid: 200 });

  await expectError('an ordinary admin cannot unlock', () => unlock(ADMIN_CLAIMS, D3), 'super admin');
  await expectError('a customer cannot unlock', () => unlock({ sub: U1, role: 'authenticated' }, D3), 'super admin');
  const ul = await unlock(SERVICE, D3);
  eq('unlock reopens the order and keeps what was paid', { reopened: ul.reopened, run: (await run(D3)).status, balance: await balance(U1), ...(await order(OE.id)) },
    { reopened: 1, run: 'draft', balance: 800, status: 'pending', payment: 'paid', paid: 200, skip: null, finalized: false, hold: false });
  await expectError('a day that is not finalized cannot be unlocked', () => unlock(SERVICE, D3), 'not finalized');

  const extraItem = randomUUID();
  await db.exec(`
    BEGIN;
    INSERT INTO public.subscription_daily_order_items
      (id, daily_order_id, variant_id, product_name_snapshot, variant_label_snapshot, unit_price, quantity, total_price, is_adhoc_addition)
    VALUES ('${extraItem}', '${OE.id}', '${VAR}', 'Cow Milk', '1 L', 100, 1, 100, true);
    UPDATE public.subscription_daily_orders SET total_value = 300 WHERE id = '${OE.id}';
    COMMIT;`);
  const f3 = await finalize(ADMIN_CLAIMS, D3);
  eq('re-finalize after adding an item charges only the ₹100 difference',
    { deducted: f3.total_deducted, refunded: f3.total_refunded, balance: await balance(U1), paid: (await order(OE.id)).paid, ledger: await ledgerNet(OE.id) },
    { deducted: 100, refunded: 0, balance: 700, paid: 300, ledger: 300 });

  await unlock(SERVICE, D3);
  await db.exec(`
    BEGIN;
    DELETE FROM public.subscription_daily_order_items WHERE id = '${extraItem}';
    UPDATE public.subscription_daily_orders SET total_value = 200 WHERE id = '${OE.id}';
    COMMIT;`);
  const f4 = await finalize(ADMIN_CLAIMS, D3);
  eq('re-finalize after removing an item refunds the ₹100 difference',
    { deducted: f4.total_deducted, refunded: f4.total_refunded, balance: await balance(U1), paid: (await order(OE.id)).paid },
    { deducted: 0, refunded: 100, balance: 800, paid: 200 });

  await unlock(SERVICE, D3);
  const f5 = await finalize(ADMIN_CLAIMS, D3);
  eq('re-finalize with no edit moves nothing', { deducted: f5.total_deducted, refunded: f5.total_refunded, balance: await balance(U1) },
    { deducted: 0, refunded: 0, balance: 800 });

  await unlock(SERVICE, D3);
  await db.exec(`
    BEGIN;
    UPDATE public.subscription_daily_order_items SET quantity = 60, total_price = 6000 WHERE daily_order_id = '${OE.id}';
    UPDATE public.subscription_daily_orders SET total_value = 6000 WHERE id = '${OE.id}';
    COMMIT;`);
  const f6 = await finalize(ADMIN_CLAIMS, D3);
  eq('re-finalize the wallet cannot cover → skipped, and the earlier ₹200 is given back',
    { skipped: f6.skipped.length, refunded: f6.total_refunded, balance: await balance(U1), ...(await order(OE.id)) },
    { skipped: 1, refunded: 200, balance: 1000, status: 'skipped', payment: 'failed', paid: 0, skip: 'insufficient_balance', finalized: true, hold: false });

  // Cancelled while the day is unlocked: the money goes back at once, and a
  // charged order can never simply be deleted.
  const D3b = '2097-02-08';
  const sub1f = await mkSub(U1, '2020-01-07');
  const sub1g = await mkSub(U1, '2020-01-08');
  const OC = track(await mkOrder(sub1f, U1, D3b, [{ qty: 2 }]));   // 200
  const OK2 = track(await mkOrder(sub1g, U1, D3b, [{ qty: 1 }]));  // 100
  await finalize(ADMIN_CLAIMS, D3b);
  await unlock(SERVICE, D3b);
  u1 = await balance(U1);
  await expectError('a charged order cannot be deleted',
    () => db.query(`DELETE FROM public.subscription_daily_orders WHERE id = $1`, [OC.id]), 'cannot be deleted');
  const sc = await setStatus(ADMIN_CLAIMS, [OC.id], 'cancelled');
  eq('cancel on an unlocked day refunds the paid order immediately',
    { refunded: sc.refunded, gain: (await balance(U1)) - u1, ...(await order(OC.id)) },
    { refunded: 200, gain: 200, status: 'cancelled', payment: 'refunded', paid: 0, skip: null, finalized: false, hold: false });
  // The other order is skipped by a direct table update (the old panel's way):
  // finalize's refund sweep still gives the money back.
  await db.query(`UPDATE public.subscription_daily_orders SET status = 'skipped' WHERE id = $1`, [OK2.id]);
  const fs = await finalize(ADMIN_CLAIMS, D3b);
  eq('finalize refunds a skipped order that still held money',
    { refunded: fs.total_refunded, deducted: fs.total_deducted, gain: (await balance(U1)) - u1, paid: (await order(OK2.id)).paid, run: await run(D3b) },
    { refunded: 100, deducted: 0, gain: 300, paid: 0, run: { status: 'finalized', orders: 0, value: 0 } });
  await db.exec(`BEGIN;
    DELETE FROM public.subscription_daily_order_items WHERE daily_order_id = '${OC.id}';
    DELETE FROM public.subscription_daily_orders WHERE id = '${OC.id}';
    COMMIT;`);
  allOrders.splice(allOrders.indexOf(OC.id), 1);
  ok('an order with nothing charged can be deleted');

  // ── 11g. An unexpected settlement error does not let the order go out unpaid
  const D5 = '2097-02-05';
  const sub1e = await mkSub(U1, '2020-01-05');
  const OErr = await mkOrder(sub1e, U1, D5, [{ qty: 1 }]);
  await db.query(`UPDATE public.subscription_daily_orders SET settlement_hold_reason = 'test hold' WHERE id = $1`, [OErr.id]);
  u1 = await balance(U1);
  const f7 = await finalize(ADMIN_CLAIMS, D5);
  eq('held order at finalize → reported, skipped (payment_error), nothing taken',
    { errors: f7.deduction_errors.length, balance: await balance(U1), status: (await order(OErr.id)).status, skip: (await order(OErr.id)).skip },
    { errors: 1, balance: u1, status: 'skipped', skip: 'payment_error' });
  await expectError('retrying a held order is refused until it is reviewed', () => retry(ADMIN_CLAIMS, OErr.id), 'needs review');

  // ── 11h. Cash on delivery: the wallet is never touched ────────────────────
  const subCod = await mkSub(U1, '2020-01-06', 'cod');
  const D6 = '2097-02-06';
  const OCod = await mkOrder(subCod, U1, D6, [{ qty: 2 }]);
  u1 = await balance(U1);
  await finalize(ADMIN_CLAIMS, D6);
  const dc = await deliver(ADMIN_CLAIMS, OCod, [1]);
  eq('cash-on-delivery order: finalized and delivered with no wallet movement',
    { balance: await balance(U1), refunded: dc.refunded, ...(await order(OCod.id)) },
    { balance: u1, refunded: 0, status: 'delivered', payment: 'pending', paid: 0, skip: null, finalized: true, hold: false });

  // ── 11i. Reconcile needs every quantity, then settles and closes the day ──
  const D4 = '2097-02-07';
  const subs4 = [];
  for (let i = 0; i < 5; i++) subs4.push(await mkSub(U1, `2020-02-0${i + 1}`));
  await setBalance(U1, 1000);
  const R1 = track(await mkOrder(subs4[0], U1, D4, [{ qty: 2 }, { qty: 1 }]));  // 300: staff entered 1 of 2, other blank at first
  const R2 = track(await mkOrder(subs4[1], U1, D4, [{ qty: 1 }]));              // 100: nothing entered at first
  const R3 = track(await mkOrder(subs4[2], U1, D4, [{ qty: 1 }]));              // 100: staff entered 0
  const R4 = track(await mkOrder(subs4[3], U1, D4, [{ qty: 1 }]));              // 100: already marked delivered
  const R5 = track(await mkOrder(subs4[4], U1, D4, [{ qty: 3 }]));              // 300: skipped for low balance
  await setBalance(U1, 600);                                                     // covers R1..R4, not R5
  const f8 = await finalize(ADMIN_CLAIMS, D4);
  eq('reconcile setup: four charged, the fifth skipped', { deducted: f8.total_deducted, skipped: f8.skipped.map((s) => s.order_id), balance: await balance(U1) },
    { deducted: 600, skipped: [R5.id], balance: 0 });
  await expectError('reconcile needs daily_ops:edit', () => reconcile({ sub: U1, role: 'authenticated' }, D4), 'Not authorized');
  await expectError('a draft day cannot be reconciled', () => reconcile(ADMIN_CLAIMS, D2b), 'No run exists|Cannot reconcile');

  // Quantities typed in by staff but not settled yet (the autosave path).
  await db.query(`UPDATE public.subscription_daily_order_items SET delivered_qty = 1 WHERE id = $1`, [R1.items[0]]);
  await db.query(`UPDATE public.subscription_daily_order_items SET delivered_qty = 0 WHERE id = $1`, [R3.items[0]]);
  await setStatus(ADMIN_CLAIMS, [R4.id], 'delivered');

  // Two pending orders (R1, R2) still have an item with no delivered quantity.
  const beforeRefuse = { balance: await balance(U1), r1: await deliveredQty(R1.id), r2: await deliveredQty(R2.id) };
  await expectError('reconcile is refused while a pending order has an item with no delivered quantity',
    () => reconcile(ADMIN_CLAIMS, D4), '2 pending order\\(s\\) still have items with no delivered quantity');
  eq('refused reconcile assumed nothing and changed nothing',
    { balance: await balance(U1), r1: await deliveredQty(R1.id), r2: await deliveredQty(R2.id),
      run: (await run(D4)).status, r1status: (await order(R1.id)).status, r2status: (await order(R2.id)).status },
    { ...beforeRefuse, run: 'finalized', r1status: 'pending', r2status: 'pending' });

  // Staff enter the missing quantities; one order still incomplete → still refused.
  await db.query(`UPDATE public.subscription_daily_order_items SET delivered_qty = 1 WHERE id = $1`, [R1.items[1]]);
  await expectError('reconcile is still refused with one order incomplete',
    () => reconcile(ADMIN_CLAIMS, D4), '1 pending order\\(s\\) still have items with no delivered quantity');
  await db.query(`UPDATE public.subscription_daily_order_items SET delivered_qty = 1 WHERE id = $1`, [R2.items[0]]);

  const rec = await reconcile(ADMIN_CLAIMS, D4);
  eq('reconcile result once every quantity is entered',
    { reconciled: rec.reconciled, refunded: rec.total_refunded, charged: rec.total_charged,
      refunds: rec.refunds.map((r) => [r.order_id, r.amount]).sort(), errors: rec.settlement_errors.length,
      notify: rec.delivered_user_ids.length, noDefaulting: !('defaulted_orders' in rec) },
    { reconciled: 3, refunded: 200, charged: 0,
      refunds: [[R1.id, 100], [R3.id, 100]].sort(), errors: 0, notify: 2, noDefaulting: true });
  eq('reconcile: quantities are exactly what staff entered', await deliveredQty(R1.id), [1, 1]);
  eq('reconcile: short order delivered and refunded the shortfall', await order(R1.id),
    { status: 'delivered', payment: 'paid', paid: 200, skip: null, finalized: true, hold: false });
  eq('reconcile: order entered as fully delivered, no refund', { qty: await deliveredQty(R2.id), ...(await order(R2.id)) },
    { qty: [1], status: 'delivered', payment: 'paid', paid: 100, skip: null, finalized: true, hold: false });
  eq('reconcile: nothing delivered → cancelled and refunded', await order(R3.id),
    { status: 'cancelled', payment: 'refunded', paid: 0, skip: null, finalized: true, hold: false });
  eq('reconcile: skipped order stays skipped and unpaid', await order(R5.id),
    { status: 'skipped', payment: 'failed', paid: 0, skip: 'insufficient_balance', finalized: true, hold: false });
  eq('reconcile: wallet got the two refunds', await balance(U1), 200);
  const blank = num((await db.query(`
    SELECT count(*) AS n FROM public.subscription_daily_order_items i
    JOIN public.subscription_daily_orders o ON o.id = i.daily_order_id
    WHERE o.delivery_date = $1 AND o.status IN ('delivered', 'cancelled') AND i.delivered_qty IS NULL`, [D4])).rows[0].n);
  eq('reconcile: every delivered or cancelled order has a quantity for every item', blank, 0);
  eq('reconcile: run closed', (await run(D4)).status, 'reconciled');

  // A reconciled day is closed for every money action.
  await expectError('second reconcile is refused', () => reconcile(ADMIN_CLAIMS, D4), 'Cannot reconcile');
  await expectError('finalize of a reconciled day is refused', () => finalize(ADMIN_CLAIMS, D4), 'already reconciled');
  await expectError('unlock of a reconciled day is refused', () => unlock(SERVICE, D4), 'reconciled');
  await expectError('delivery on a reconciled day is refused', () => deliver(ADMIN_CLAIMS, R1, [2, 1]), 'reconciled');
  await expectError('status change on a reconciled day is refused', () => setStatus(ADMIN_CLAIMS, [R2.id], 'cancelled'), 'reconciled');
  await expectError('payment retry on a reconciled day is refused', () => retry(ADMIN_CLAIMS, R5.id), 'finalized');
  eq('nothing moved on the closed day', await balance(U1), 200);

  // ── 11j. The ledger and paid_amount agree for every order ─────────────────
  let mismatches = 0;
  for (const id of allOrders) {
    const o = await order(id);
    const net = await ledgerNet(id);
    if (Math.round(net * 100) !== Math.round(o.paid * 100)) {
      mismatches++;
      console.log(`        ledger ${net} ≠ paid_amount ${o.paid} for ${id}`);
    }
  }
  eq(`wallet ledger net equals paid_amount for all ${allOrders.length} settled orders`, mismatches, 0);
  const negative = num((await db.query(
    `SELECT count(*) AS n FROM public.users WHERE id IN ($1, $2) AND wallet_balance < 0`, [U1, U2])).rows[0].n);
  eq('no wallet went negative', negative, 0);

  // ── 11k. Re-running the migration leaves settled orders alone ─────────────
  await expectOk('migration 037 re-runs cleanly after orders were settled',
    () => db.exec(read(`${ROOT}/migrations/037_daily_order_settlement.sql`)));
  // 037 re-declares its functions, which drops the trusted flag 038 attaches
  // to them; re-apply 038 as the owner would after re-running 037.
  await db.exec(read(`${ROOT}/migrations/038_daily_ops_structure.sql`));
  eq('re-run did not put a partly refunded (settled) order on hold', await order(R1.id),
    { status: 'delivered', payment: 'paid', paid: 200, skip: null, finalized: true, hold: false });
  eq('re-run kept the legacy holds', { l2: (await order(L2.id)).hold, l7: (await order(L7.id)).hold, l1: (await order(L1.id)).hold }, { l2: true, l7: true, l1: false });
  eq('delete guard trigger installed once', num((await db.query(
    `SELECT count(*) AS n FROM pg_trigger WHERE tgname = 'trg_guard_paid_daily_order_delete'`)).rows[0].n), 1);

  // ── 11m. A held order: no Daily Ops function moves money for it (D-9, P1-03)
  // HA: not finalized yet (finalize meets it). HB: went out under the old
  // system with a failed debit (finalized, pending). After each call the
  // wallet, paid_amount, hold reason and wallet transactions are unchanged,
  // whether the call refused or carried on without it.
  {
    const DH = '2097-03-01';
    const subHA = await mkSub(U2, '2021-01-01');
    const subHB = await mkSub(U2, '2021-01-02');
    await setBalance(U2, 500);
    const HA = await mkOrder(subHA, U2, DH, [{ qty: 1 }]);
    const HB = await mkOrder(subHB, U2, DH, [{ qty: 2 }], { payment_status: 'failed', is_finalized: true });
    await db.query(`UPDATE public.subscription_daily_orders SET settlement_hold_reason = 'test hold A' WHERE id = $1`, [HA.id]);
    await db.query(`UPDATE public.subscription_daily_orders SET settlement_hold_reason = 'test hold B' WHERE id = $1`, [HB.id]);

    const snapshot = async () => {
      const rows = (await db.query(`
        SELECT id, paid_amount, settlement_hold_reason FROM public.subscription_daily_orders
        WHERE id IN ($1, $2) ORDER BY id`, [HA.id, HB.id])).rows;
      const txns = num((await db.query(`
        SELECT count(*) AS n FROM public.wallet_transactions WHERE reference_id IN ($1, $2)`, [HA.id, HB.id])).rows[0].n);
      return { balance: await balance(U2), txns,
               orders: rows.map((r) => ({ paid: num(r.paid_amount), hold: r.settlement_hold_reason })) };
    };
    const before = await snapshot();
    const attempt = async (fn) => { try { await fn(); } catch { /* a refusal is fine; money must not move */ } };
    const held = async (name, fn) => { await attempt(fn); eq(`held orders untouched by ${name}`, await snapshot(), before); };

    await held('finalize_daily_run', () => finalize(ADMIN_CLAIMS, DH));
    await held('record_subscription_delivery', () => deliver(ADMIN_CLAIMS, HB, [1]));
    await held('set_daily_order_status (delivered)', () => setStatus(ADMIN_CLAIMS, [HB.id], 'delivered'));
    await held('set_daily_order_status (cancelled)', () => setStatus(ADMIN_CLAIMS, [HB.id], 'cancelled'));
    await held('retry_daily_order_payment', () => retry(ADMIN_CLAIMS, HA.id));
    await held('retry_daily_order_payment (legacy order)', () => retry(ADMIN_CLAIMS, HB.id));
    // Give every item a quantity so reconcile reaches settlement instead of
    // stopping at the missing-quantity check.
    await db.query(`UPDATE public.subscription_daily_order_items SET delivered_qty = quantity WHERE daily_order_id IN ($1, $2)`, [HA.id, HB.id]);
    await held('reconcile_daily_run', () => reconcile(ADMIN_CLAIMS, DH));
  }

  // ── 11l. Grants ───────────────────────────────────────────────────────────
  const g = (await db.query(`
    SELECT
      has_function_privilege('authenticated', 'public.finalize_daily_run(date, uuid)', 'EXECUTE')                  AS a1,
      has_function_privilege('authenticated', 'public.unlock_daily_run(date)', 'EXECUTE')                          AS a2,
      has_function_privilege('authenticated', 'public.record_subscription_delivery(uuid, jsonb, text)', 'EXECUTE') AS a3,
      has_function_privilege('authenticated', 'public.set_daily_order_status(uuid[], text)', 'EXECUTE')            AS a4,
      has_function_privilege('authenticated', 'public.retry_daily_order_payment(uuid)', 'EXECUTE')                 AS a5,
      has_function_privilege('authenticated', 'public.reconcile_daily_run(date, uuid)', 'EXECUTE')                 AS a6,
      has_function_privilege('anon', 'public.finalize_daily_run(date, uuid)', 'EXECUTE')                           AS n1,
      has_function_privilege('anon', 'public.record_subscription_delivery(uuid, jsonb, text)', 'EXECUTE')          AS n2,
      has_function_privilege('anon', 'public.set_daily_order_status(uuid[], text)', 'EXECUTE')                     AS n3,
      has_function_privilege('anon', 'public.retry_daily_order_payment(uuid)', 'EXECUTE')                          AS n4,
      has_function_privilege('anon', 'public.reconcile_daily_run(date, uuid)', 'EXECUTE')                          AS n5,
      has_function_privilege('anon', 'public.unlock_daily_run(date)', 'EXECUTE')                                   AS n6,
      has_function_privilege('authenticated', 'internal.settle_daily_order(uuid, text, text)', 'EXECUTE')          AS i1,
      has_function_privilege('authenticated', 'internal.daily_order_amount_owed(uuid)', 'EXECUTE')                 AS i2`)).rows[0];
  if (g.a1 && g.a2 && g.a3 && g.a4 && g.a5 && g.a6 && !g.n1 && !g.n2 && !g.n3 && !g.n4 && !g.n5 && !g.n6 && !g.i1 && !g.i2) {
    ok('037 grants: staff functions for authenticated/service_role only; settle internals closed');
  } else {
    bad('037 grants', JSON.stringify(g));
  }
}

// ---------------------------------------------------------------------------
// 12. Migration 038: Daily Ops structure
// ---------------------------------------------------------------------------
console.log('\n--- 12. Migration 038: Daily Ops structure ---');
{
  const { randomUUID } = await import('node:crypto');
  const num = (v) => Number(v);
  const eq = (name, got, want) => {
    const g = JSON.stringify(got), w = JSON.stringify(want);
    if (g === w) ok(`${name} (${w})`); else bad(name, `expected ${w}, got ${g}`);
  };
  const rpc = async (claims, call, params) => {
    const r = (await asQuery(claims, `SELECT ${call} AS r`, params)).rows[0].r;
    return typeof r === 'string' ? JSON.parse(r) : r;
  };
  const CUST = { sub: CUSTOMER, role: 'authenticated' };
  const SERVICE = { role: 'service_role' };
  const addDays = (ymd, n) => {
    const d = new Date(`${ymd}T00:00:00Z`); d.setUTCDate(d.getUTCDate() + n);
    return d.toISOString().slice(0, 10);
  };
  await db.query(
    `INSERT INTO public.admin_role_permissions (role_id, permission) VALUES ($1, 'daily_ops:edit') ON CONFLICT DO NOTHING`, [roleId]);

  const U = 'a0380000-0000-4000-8000-000000000001';
  await db.exec(`INSERT INTO public.users (id, email, phone, first_name, wallet_balance)
                 VALUES ('${U}', 'u-038@example.com', '9038000001', 'U38', 0)`);
  const setBalance = (amount) => db.query(`UPDATE public.users SET wallet_balance = $2 WHERE id = $1`, [U, amount]);
  const balance = async () => num((await db.query(`SELECT wallet_balance FROM public.users WHERE id = $1`, [U])).rows[0].wallet_balance);

  const AREA_D = 'a0380000-0000-4000-8000-0000000000a1';
  const AREA_2 = 'a0380000-0000-4000-8000-0000000000a2';
  const D0 = '2098-01-10';
  await db.exec(`INSERT INTO public.delivery_areas (id, display_name, is_active, delivary_frequency, reference_date)
                 VALUES ('${AREA_D}', 'Daily 038', true, 1, NULL), ('${AREA_2}', 'Alternate 038', true, 2, '${D0}')`);

  // A subscription with items. items: [{ qty, price, start, end, active }]
  let created = 0;
  const mkSub = async ({ area = 'Daily 038', start = D0, end = null, status = 'active', freq = null,
                         items = [{ qty: 1 }] } = {}) => {
    const id = randomUUID();
    created++;
    await db.query(
      `INSERT INTO public.subscriptions (id, user_id, status, payment_method, start_date, end_date,
                                         delivary_area, delivary_frequency, created_at, snapshot_pincode)
       VALUES ($1, $2, $3, 'wallet', $4, $5, $6, $7, $8::timestamp, '700001')`,
      [id, U, status, start, end, area, freq, `2030-01-01 00:${String(Math.floor(created / 60) % 60).padStart(2, '0')}:${String(created % 60).padStart(2, '0')}`]);
    for (const it of items) {
      await db.query(
        `INSERT INTO public.subscription_items (subscription_id, variant_id, product_name_snapshot, variant_label_snapshot,
                                                unit_price, quantity, item_start_date, item_end_date, is_active)
         VALUES ($1, $2, 'Cow Milk', '1 L', $3, $4, $5, $6, $7)`,
        [id, VAR, it.price ?? 100, it.qty, it.start ?? start ?? D0, it.end ?? null, it.active ?? true]);
    }
    return id;
  };
  const delivers = async (sub, date) =>
    (await db.query(`SELECT internal.subscription_delivers_on($1, $2::date) AS r`, [sub, date])).rows[0].r;
  const override = async (kind, subId, { date = null, from = null, to = null, area = AREA_D } = {}) => {
    const id = randomUUID();
    await db.query(
      `INSERT INTO public.delivery_day_overrides (id, override_date, swapped_with_area_id, selection_type, override_kind, from_date, to_date)
       VALUES ($1, $2, $3, 'customer', $4, $5, $6)`, [id, date ?? to ?? from, area, kind, from, to]);
    await db.query(`INSERT INTO public.delivery_day_override_subscriptions (override_id, subscription_id) VALUES ($1, $2)`, [id, subId]);
  };

  // ── 12a. The delivery-day rule ────────────────────────────────────────────
  const S = await mkSub({ start: D0, end: addDays(D0, 10) });
  await db.query(`INSERT INTO public.subscription_pauses (subscription_id, pause_start_date, pause_end_date, created_by)
                  VALUES ($1, $2, $3, 'admin')`, [S, addDays(D0, 3), addDays(D0, 5)]);
  eq('delivers on its start date', await delivers(S, D0), true);
  eq('not the day before the start date', await delivers(S, addDays(D0, -1)), false);
  eq('delivers on its end date', await delivers(S, addDays(D0, 10)), true);
  eq('not the day after the end date', await delivers(S, addDays(D0, 11)), false);
  eq('pause: first, middle and last day are paused',
    [await delivers(S, addDays(D0, 3)), await delivers(S, addDays(D0, 4)), await delivers(S, addDays(D0, 5))], [false, false, false]);
  eq('delivers the day after a pause', await delivers(S, addDays(D0, 6)), true);

  const S2 = await mkSub({ area: 'Alternate 038', start: D0 });
  eq('every-2-days area: on day, off day, on day',
    [await delivers(S2, D0), await delivers(S2, addDays(D0, 1)), await delivers(S2, addDays(D0, 2))], [true, false, true]);
  await override('swap', S2, { date: addDays(D0, 1), area: AREA_D });
  eq('swap override: borrowed daily area delivers on its off day', await delivers(S2, addDays(D0, 1)), true);
  await override('move', S2, { from: addDays(D0, 4), to: addDays(D0, 5) });
  eq('move: not on the from-date', await delivers(S2, addDays(D0, 4)), false);
  eq('move: delivers on the to-date even off-cadence', await delivers(S2, addDays(D0, 5)), true);
  await override('move', S, { from: addDays(D0, 7), to: addDays(D0, 4) });
  eq('move onto a paused day: no delivery', await delivers(S, addDays(D0, 4)), false);
  const S3 = await mkSub({ items: [{ qty: 1, active: false }] });
  eq('only an inactive item: no delivery', await delivers(S3, D0), false);
  const S4 = await mkSub({ items: [{ qty: 1, start: addDays(D0, 1) }] });
  eq('item starting tomorrow: not today, yes tomorrow', [await delivers(S4, D0), await delivers(S4, addDays(D0, 1))], [false, true]);
  const S5 = await mkSub({ status: 'cancelled' });
  eq('cancelled subscription: no delivery', await delivers(S5, D0), false);
  const S6 = await mkSub({ area: 'No such area', start: D0, freq: 3 });
  eq('own every-3-days frequency from the start date',
    [await delivers(S6, D0), await delivers(S6, addDays(D0, 1)), await delivers(S6, addDays(D0, 3))], [true, false, true]);

  // ── 12b. generate_daily_run ───────────────────────────────────────────────
  // Subscription item prices come from the catalog (migration 012 trigger):
  // VAR costs 100. VAR_30 (30) is used for ad-hoc additions.
  const VAR_OFF = 'a0380000-0000-4000-8000-0000000000b1';
  const VAR_30  = 'a0380000-0000-4000-8000-0000000000b2';
  await db.exec(`INSERT INTO public.product_variants (id, product_id, label, price, weight_grams, is_active, free_delivery)
                 VALUES ('${VAR_OFF}', '${PROD}', '2 L', 180, 2000, false, false),
                        ('${VAR_30}',  '${PROD}', '250 ml', 30, 250, true, false)`);
  const G1 = '2098-03-01';
  const generate = (claims, date) => rpc(claims, `public.generate_daily_run($1::date, $2)`, [date, ADMIN]);
  const orderOf = async (sub, date) => (await db.query(`
    SELECT o.id, o.total_value, o.paid_amount, o.status,
           (SELECT json_agg(json_build_object('qty', i.quantity, 'adhoc', i.is_adhoc_addition) ORDER BY i.quantity)
            FROM public.subscription_daily_order_items i WHERE i.daily_order_id = o.id) AS items
    FROM public.subscription_daily_orders o WHERE o.subscription_id = $1 AND o.delivery_date = $2`, [sub, date])).rows[0] ?? null;

  await expectError('a customer cannot generate a run', () => generate(CUST, G1), 'not authorized');
  const GA = await mkSub({ start: G1, items: [{ qty: 2, price: 100 }, { qty: 1, price: 50 }] });
  const GB = await mkSub({ start: G1 });  // clean: regenerated from the subscription
  const GM = await mkSub({ start: G1 });  // customer-modified
  const GC = await mkSub({ start: G1 });  // paid, then unlocked
  const GD = await mkSub({ start: G1 });  // on payment hold
  const GE = await mkSub({ start: G1 });  // staff route
  const GF = await mkSub({ start: G1 });  // ad-hoc item
  const GG = await mkSub({ start: G1 });  // delivered quantity entered
  const GP = await mkSub({ start: G1 });  // paused on G1
  await db.query(`INSERT INTO public.subscription_pauses (subscription_id, pause_start_date, pause_end_date, created_by)
                  VALUES ($1, $2, $2, 'admin')`, [GP, G1]);
  const GS = await mkSub({ start: addDays(G1, 1) });  // starts tomorrow
  const g1 = await generate(ADMIN_CLAIMS, G1);
  const oa = await orderOf(GA, G1);
  eq('generated order total = Σ items', { total: num(oa.total_value), items: oa.items.length }, { total: 300, items: 2 });
  eq('paused and not-yet-started subscriptions get no order', [await orderOf(GP, G1), await orderOf(GS, G1)], [null, null]);
  eq('first run created the orders', g1.generated >= 8, true);
  // Clean orders are deleted and rebuilt on every run (that is how a changed
  // subscription reaches the run sheet), so a second run reports them again.
  // What must hold: never two orders for one subscription and date.
  await generate(ADMIN_CLAIMS, G1);
  eq('second run: no duplicate orders', num((await db.query(`
    SELECT count(*) AS n FROM (SELECT subscription_id FROM public.subscription_daily_orders
      WHERE delivery_date = $1 GROUP BY subscription_id HAVING count(*) > 1) d`, [G1])).rows[0].n), 0);

  const before = {};
  for (const [k, s] of Object.entries({ GM, GC, GD, GE, GF, GG })) before[k] = (await orderOf(s, G1)).id;
  await db.query(`UPDATE public.subscription_daily_orders SET is_customer_modified = true WHERE id = $1`, [before.GM]);
  await db.query(`UPDATE public.subscription_daily_orders SET paid_amount = 100, payment_status = 'paid' WHERE id = $1`, [before.GC]);
  await db.query(`UPDATE public.subscription_daily_orders SET settlement_hold_reason = 'test hold 038' WHERE id = $1`, [before.GD]);
  await db.query(`UPDATE public.subscription_daily_orders SET custom_route = 'Van 9' WHERE id = $1`, [before.GE]);
  await rpc(ADMIN_CLAIMS, `public.add_daily_order_item($1, $2, 1)`, [before.GF, VAR_30]);
  await db.query(`UPDATE public.subscription_daily_order_items SET delivered_qty = 1 WHERE daily_order_id = $1`, [before.GG]);
  // Every subscription's quantity changes; only the clean order should follow.
  await db.query(`UPDATE public.subscription_items SET quantity = 3 WHERE subscription_id = ANY ($1::uuid[])`,
    [`{${[GB, GM, GC, GD, GE, GF, GG].join(',')}}`]);
  const g3 = await generate(ADMIN_CLAIMS, G1);
  const after = {};
  for (const [k, s] of Object.entries({ GM, GC, GD, GE, GF, GG })) after[k] = (await orderOf(s, G1)).id;
  eq('customer-modified, paid, held, routed, ad-hoc and delivered-qty orders survive regeneration', after, before);
  eq('a paid order keeps its paid_amount', num((await orderOf(GC, G1)).paid_amount), 100);
  eq('a clean order is rebuilt with the new quantity', (await orderOf(GB, G1)).items, [{ qty: 3, adhoc: false }]);
  eq('regeneration reports the rebuilt order', { deleted: g3.deleted >= 1, generated: g3.generated >= 1 }, { deleted: true, generated: true });

  // ── 12c. 1,200 subscriptions (no 1000-row cap) ────────────────────────────
  const G2 = '2098-04-01';
  await db.exec(`
    INSERT INTO public.subscriptions (id, user_id, status, payment_method, start_date, delivary_area, created_at, label)
    SELECT gen_random_uuid(), '${U}', 'active', 'wallet', '${G2}', 'Daily 038', '2031-01-01', 'bulk038'
    FROM generate_series(1, 1200);
    INSERT INTO public.subscription_items (subscription_id, variant_id, product_name_snapshot, variant_label_snapshot,
                                           unit_price, quantity, item_start_date, is_active)
    SELECT id, '${VAR}', 'Cow Milk', '1 L', 100, 1, '${G2}', true FROM public.subscriptions WHERE label = 'bulk038';`);
  await generate(ADMIN_CLAIMS, G2);
  eq('1,200 subscriptions → 1,200 orders', num((await db.query(`
    SELECT count(*) AS n FROM public.subscription_daily_orders o JOIN public.subscriptions s ON s.id = o.subscription_id
    WHERE s.label = 'bulk038' AND o.delivery_date = $1`, [G2])).rows[0].n), 1200);
  await db.exec(`UPDATE public.subscriptions SET status = 'cancelled' WHERE label = 'bulk038'`);

  // ── 12d. Item edits ───────────────────────────────────────────────────────
  const G3 = '2098-05-01';
  const I1 = await mkSub({ start: G3, items: [{ qty: 2, price: 100 }, { qty: 1, price: 50 }] });
  await generate(ADMIN_CLAIMS, G3);
  const o3 = (await orderOf(I1, G3)).id;
  const add = (claims, order, variant, qty) => rpc(claims, `public.add_daily_order_item($1, $2, $3)`, [order, variant, qty]);
  const items = async (order) => (await db.query(`
    SELECT id, variant_id, quantity, unit_price, total_price, is_adhoc_addition FROM public.subscription_daily_order_items
    WHERE daily_order_id = $1 ORDER BY quantity DESC, unit_price DESC`, [order])).rows;
  const total = async (order) => num((await db.query(`SELECT total_value FROM public.subscription_daily_orders WHERE id = $1`, [order])).rows[0]?.total_value);

  await expectError('a customer cannot add an item', () => add(CUST, o3, VAR_30, 1), 'not authorized');
  await expectError('quantity 0 is refused', () => add(ADMIN_CLAIMS, o3, VAR_30, 0), '1 to 99');
  await expectError('quantity 100 is refused', () => add(ADMIN_CLAIMS, o3, VAR_30, 100), '1 to 99');
  await expectError('an inactive variant is refused', () => add(ADMIN_CLAIMS, o3, VAR_OFF, 1), 'not available');
  await add(ADMIN_CLAIMS, o3, VAR_30, 1);
  const adhoc = (await items(o3)).find((i) => i.variant_id === VAR_30);
  eq('new variant → ad-hoc item at the catalog price; order total = Σ items',
    { price: num(adhoc.unit_price), adhoc: adhoc.is_adhoc_addition, total: await total(o3) }, { price: 30, adhoc: true, total: 330 });
  await add(ADMIN_CLAIMS, o3, VAR_30, 2);
  const same = (await items(o3)).filter((i) => i.variant_id === VAR_30);
  eq('same variant again → quantity raised on one row', { rows: same.length, qty: same[0].quantity, total: await total(o3) }, { rows: 1, qty: 3, total: 390 });

  const setQty = (claims, item, q) => rpc(claims, `public.set_daily_order_item_quantity($1, $2)`, [item, q]);
  const remove = (claims, item) => rpc(claims, `public.remove_daily_order_item($1)`, [item]);
  const its = await items(o3);
  await setQty(ADMIN_CLAIMS, its[0].id, 4);
  eq('quantity change updates item and order totals',
    { item: num((await items(o3)).find((i) => i.id === its[0].id).total_price), total: await total(o3) }, { item: 120, total: 420 });
  await expectError('quantity change to 0 is refused', () => setQty(ADMIN_CLAIMS, its[0].id, 0), '1 to 99');

  const I2 = await mkSub({ start: G3, items: [{ qty: 2, price: 100 }, { qty: 1, price: 50 }] });
  await generate(ADMIN_CLAIMS, G3);
  const o4 = (await orderOf(I2, G3)).id;
  const i4 = await items(o4);
  const r1 = await remove(ADMIN_CLAIMS, i4[1].id);
  eq('removing one of two items: total = remaining item', { r: r1.deleted_order, total: await total(o4) }, { r: false, total: 200 });
  const r2 = await remove(ADMIN_CLAIMS, i4[0].id);
  eq('removing the last item of an unpaid order deletes the order',
    { deleted: r2.deleted_order, exists: (await orderOf(I2, G3)) !== null }, { deleted: true, exists: false });

  // Paid, then unlocked: removing the last item cancels and refunds exactly paid_amount.
  const G4 = '2098-05-02';
  const I3 = await mkSub({ start: G4, items: [{ qty: 1, price: 100 }, { qty: 1, price: 50 }] });
  await generate(ADMIN_CLAIMS, G4);
  await setBalance(100000);
  await rpc(ADMIN_CLAIMS, `public.finalize_daily_run($1::date, $2)`, [G4, ADMIN]);
  const o5 = await orderOf(I3, G4);
  eq('finalized order charged', num(o5.paid_amount), 200);
  await expectError('item edits are refused on a finalized order', () => add(ADMIN_CLAIMS, o5.id, VAR_30, 1), 'finalized');
  await rpc(SERVICE, `public.unlock_daily_run($1::date)`, [G4]);
  const i5 = await items(o5.id);
  const balBefore = await balance();
  await remove(ADMIN_CLAIMS, i5[0].id);
  const r3 = await remove(ADMIN_CLAIMS, i5[1].id);
  const o5b = await orderOf(I3, G4);
  eq('removing the last item of a paid order: cancelled, row kept, refunds paid_amount',
    { cancelled: r3.cancelled, refunded: num(r3.refunded), status: o5b.status, paid: num(o5b.paid_amount), gain: (await balance()) - balBefore },
    { cancelled: true, refunded: 200, status: 'cancelled', paid: 0, gain: 200 });

  const I4 = await mkSub({ start: G3 });
  await generate(ADMIN_CLAIMS, G3);
  const o6 = (await orderOf(I4, G3)).id;
  await db.query(`UPDATE public.subscription_daily_orders SET settlement_hold_reason = 'test hold 038' WHERE id = $1`, [o6]);
  await expectError('item edits are refused on a held order', () => add(ADMIN_CLAIMS, o6, VAR_30, 1), 'payment hold');
  await expectError('removing an item of a held order is refused', async () => remove(ADMIN_CLAIMS, (await items(o6))[0].id), 'payment hold');
  await expectError('a customer cannot remove an item', async () => remove(CUST, (await items(o3))[0].id), 'not authorized');

  // ── 12e. The finalized-day lock ───────────────────────────────────────────
  const G5 = '2098-06-01';
  const L1 = await mkSub({ start: G5, items: [{ qty: 2, price: 100 }] });
  const L2 = await mkSub({ start: G5, items: [{ qty: 1, price: 100 }] });
  await generate(ADMIN_CLAIMS, G5);
  const ol1 = (await orderOf(L1, G5)).id;
  const ol2 = (await orderOf(L2, G5)).id;
  const asAdmin = (sql, params) => asQuery(ADMIN_CLAIMS, sql, params);
  await expectError('draft order: direct payment_status = paid is refused',
    () => asAdmin(`UPDATE public.subscription_daily_orders SET payment_status = 'paid' WHERE id = $1`, [ol1]), 'Daily Ops functions');
  await expectError('direct insert of an already-paid order is refused',
    () => asAdmin(`INSERT INTO public.subscription_daily_orders (delivery_date, subscription_id, user_id, status, total_value, payment_status, paid_amount)
                   VALUES ($1, $2, $3, 'pending', 0, 'paid', 100)`, [addDays(G5, 9), L1, U]), 'Daily Ops functions');
  await setBalance(100000);
  await rpc(ADMIN_CLAIMS, `public.finalize_daily_run($1::date, $2)`, [G5, ADMIN]);
  await expectError('direct is_finalized = false is refused',
    () => asAdmin(`UPDATE public.subscription_daily_orders SET is_finalized = false WHERE id = $1`, [ol1]), 'Daily Ops functions');
  await expectError('direct paid_amount = 0 is refused',
    () => asAdmin(`UPDATE public.subscription_daily_orders SET paid_amount = 0 WHERE id = $1`, [ol1]), 'Daily Ops functions');
  await expectError('direct status change on a finalized order is refused',
    () => asAdmin(`UPDATE public.subscription_daily_orders SET status = 'cancelled' WHERE id = $1`, [ol1]), 'finalized');
  await expectError('direct user change on a finalized order is refused while the user exists',
    () => asAdmin(`UPDATE public.subscription_daily_orders SET user_id = $2 WHERE id = $1`, [ol1, CUSTOMER]), 'finalized');
  await expectError('deleting a finalized order is refused',
    () => asAdmin(`DELETE FROM public.subscription_daily_orders WHERE id = $1`, [ol2]), 'finalized');
  await expectError('a new order on a finalized day is refused',
    () => asAdmin(`INSERT INTO public.subscription_daily_orders (delivery_date, subscription_id, user_id, status, total_value)
                   VALUES ($1, $2, $3, 'pending', 0)`, [G5, S, U]), 'finalized');
  await expectOk('direct tracking_info / custom_route change on a finalized order is allowed',
    () => asAdmin(`UPDATE public.subscription_daily_orders SET tracking_info = 'gate 2', custom_route = 'Van 1' WHERE id = $1`, [ol1]));
  const li = (await items(ol1))[0].id;
  await expectOk('direct delivered_qty = 0 on a finalized order is allowed',
    () => asAdmin(`UPDATE public.subscription_daily_order_items SET delivered_qty = 0 WHERE id = $1`, [li]));
  await expectOk('direct delivered_qty = ordered quantity is allowed',
    () => asAdmin(`UPDATE public.subscription_daily_order_items SET delivered_qty = 2 WHERE id = $1`, [li]));
  await expectError('delivered_qty above the ordered quantity is refused',
    () => asAdmin(`UPDATE public.subscription_daily_order_items SET delivered_qty = 3 WHERE id = $1`, [li]), 'between 0 and');
  await expectError('changing an item price on a finalized order is refused',
    () => asAdmin(`UPDATE public.subscription_daily_order_items SET unit_price = 1 WHERE id = $1`, [li]), 'finalized');
  await expectError('adding an item to a finalized order is refused',
    () => asAdmin(`INSERT INTO public.subscription_daily_order_items (daily_order_id, variant_id, product_name_snapshot, variant_label_snapshot, unit_price, quantity, total_price)
                   VALUES ($1, $2, 'x', 'y', 1, 1, 1)`, [ol1, VAR]), 'finalized');
  await expectError('deleting an item of a finalized order is refused',
    () => asAdmin(`DELETE FROM public.subscription_daily_order_items WHERE id = $1`, [li]), 'finalized');
  await expectError('a customer cannot change a finalized order either',
    () => asQuery(CUST, `UPDATE public.subscription_daily_orders SET paid_amount = 0 WHERE id = $1`, [ol1]), 'Daily Ops functions');
  await expectOk('bulk Mark Delivered through set_daily_order_status still works (D-2)',
    () => rpc(ADMIN_CLAIMS, `public.set_daily_order_status($1::uuid[], 'delivered')`, [`{${ol2}}`]));
  // The test user's other daily subscriptions also have orders this day.
  const restG5 = (await db.query(`SELECT id FROM public.subscription_daily_orders
    WHERE delivery_date = $1 AND status = 'pending'`, [G5])).rows.map((r) => r.id);
  await rpc(ADMIN_CLAIMS, `public.set_daily_order_status($1::uuid[], 'delivered')`, [`{${restG5.join(',')}}`]);
  await expectOk('reconcile still works', () => rpc(ADMIN_CLAIMS, `public.reconcile_daily_run($1::date, $2)`, [G5, ADMIN]));
  await expectError('reconciled day: even a note change is refused',
    () => asAdmin(`UPDATE public.subscription_daily_orders SET tracking_info = 'late' WHERE id = $1`, [ol1]), 'reconciled');
  await expectError('reconciled day: delivered_qty change is refused',
    () => asAdmin(`UPDATE public.subscription_daily_order_items SET delivered_qty = 1 WHERE id = $1`, [li]), 'reconciled');
  await expectError('regenerating a reconciled date is refused', () => generate(ADMIN_CLAIMS, G5), 'Unlock it before regenerating');

  // A held order: the hold cannot be cleared by a direct write (D-9) but can
  // from the SQL Editor (no claims), which is the owner's release step.
  await expectError('direct settlement_hold_reason = NULL is refused',
    () => asAdmin(`UPDATE public.subscription_daily_orders SET settlement_hold_reason = NULL WHERE id = $1`, [o6]), 'Daily Ops functions');
  await expectOk('the SQL Editor (owner) can release a hold',
    () => db.query(`UPDATE public.subscription_daily_orders SET settlement_hold_reason = NULL WHERE id = $1`, [o6]));

  // ── 12f. get_earliest_change_date (M-01) ──────────────────────────────────
  const ymd = (d) => (d instanceof Date ? d.toISOString().slice(0, 10) : String(d).slice(0, 10));
  const today = ymd((await db.query(`SELECT internal.today_ist()::text AS d`)).rows[0].d);
  const custSub = randomUUID();
  await db.query(`INSERT INTO public.subscriptions (id, user_id, status, payment_method, start_date, snapshot_pincode)
                  VALUES ($1, $2, 'active', 'wallet', $3, '700001')`, [custSub, CUSTOMER, today]);
  const earliest = async (claims) =>
    ymd((await asQuery(claims, `SELECT public.get_earliest_change_date($1)::text AS d`, [custSub])).rows[0].d);
  await db.exec(`UPDATE public.delivery_areas SET order_cutoff_time = NULL WHERE id = '${AREA_DAILY}'`);
  eq('earliest change date with no cut-off = tomorrow', await earliest(CUST), addDays(today, 1));
  await db.exec(`UPDATE public.delivery_areas SET order_cutoff_time = '00:00:00' WHERE id = '${AREA_DAILY}'`);
  eq('earliest change date after the cut-off = the day after tomorrow', await earliest(CUST), addDays(today, 2));
  await db.exec(`UPDATE public.delivery_areas SET order_cutoff_time = NULL WHERE id = '${AREA_DAILY}'`);
  await expectError('another customer cannot read it', () => earliest({ sub: OTHER, role: 'authenticated' }), 'not authorized');

  // ── 12g. Re-run, flags and grants ─────────────────────────────────────────
  await expectOk('migration 038 re-runs cleanly', () => db.exec(read(`${ROOT}/migrations/038_daily_ops_structure.sql`)));
  eq('11 trusted functions set the flag', num((await db.query(
    `SELECT count(*) AS n FROM pg_proc
     WHERE prosrc LIKE '%set_config(''hetha.daily_ops_rpc'', ''on'', true)%'`)).rows[0].n), 11);
  // This harness runs as a superuser. On Supabase the SQL Editor's postgres
  // role may not attach a custom setting to a function
  // ("permission denied to set parameter"), so a function-level
  // SET hetha.* / ALTER FUNCTION ... SET hetha.* must never appear.
  {
    const { readdirSync } = await import('node:fs');
    const offenders = readdirSync(`${ROOT}/migrations`)
      .filter((f) => /^\d{3}_.*\.sql$/.test(f) && Number(f.slice(0, 3)) >= 38)
      .filter((f) => read(`${ROOT}/migrations/${f}`).split('\n')
        .some((line) => !line.trim().startsWith('--') && /^\s*SET\s+hetha\./i.test(line)
                     || /ALTER\s+FUNCTION[^;]*SET\s+hetha\./i.test(line)));
    eq('no migration attaches a hetha.* setting to a function (not allowed on Supabase)', offenders, []);
  }
  eq('each lock trigger installed once', num((await db.query(`SELECT count(*) AS n FROM pg_trigger
     WHERE tgname IN ('trg_guard_daily_order_write', 'trg_guard_daily_order_item_write')`)).rows[0].n), 2);
  eq('the flag does not outlive a function call',
    (await db.query(`SELECT COALESCE(current_setting('hetha.daily_ops_rpc', true), '') AS v`)).rows[0].v, '');
  const g = (await db.query(`
    SELECT
      has_function_privilege('authenticated', 'public.generate_daily_run(date, uuid)', 'EXECUTE')               AS a1,
      has_function_privilege('authenticated', 'public.add_daily_order_item(uuid, uuid, integer)', 'EXECUTE')    AS a2,
      has_function_privilege('authenticated', 'public.remove_daily_order_item(uuid)', 'EXECUTE')                AS a3,
      has_function_privilege('authenticated', 'public.set_daily_order_item_quantity(uuid, integer)', 'EXECUTE') AS a4,
      has_function_privilege('authenticated', 'public.get_earliest_change_date(uuid)', 'EXECUTE')               AS a5,
      has_function_privilege('anon', 'public.generate_daily_run(date, uuid)', 'EXECUTE')                        AS n1,
      has_function_privilege('anon', 'public.add_daily_order_item(uuid, uuid, integer)', 'EXECUTE')             AS n2,
      has_function_privilege('anon', 'public.get_earliest_change_date(uuid)', 'EXECUTE')                        AS n3,
      has_function_privilege('authenticated', 'internal.subscription_delivers_on(uuid, date)', 'EXECUTE')       AS i1,
      has_function_privilege('authenticated', 'internal.subscription_items_on(uuid, date)', 'EXECUTE')          AS i2,
      has_function_privilege('authenticated', 'internal.lock_editable_daily_order(uuid)', 'EXECUTE')            AS i3`)).rows[0];
  if (g.a1 && g.a2 && g.a3 && g.a4 && g.a5 && !g.n1 && !g.n2 && !g.n3 && !g.i1 && !g.i2 && !g.i3) {
    ok('038 grants: staff functions for authenticated/service_role only; internals closed');
  } else {
    bad('038 grants', JSON.stringify(g));
  }
}

// ---------------------------------------------------------------------------
// 13. Migration 039: wallet reserve, forecast, low-balance notices, reminder
// ---------------------------------------------------------------------------
console.log('\n--- 13. Migration 039: wallet simplification and reminder ---');
{
  const { randomUUID } = await import('node:crypto');
  const num = (v) => Number(v);
  const eq = (name, got, want) => {
    const g = JSON.stringify(got), w = JSON.stringify(want);
    if (g === w) ok(`${name} (${w})`); else bad(name, `expected ${w}, got ${g}`);
  };
  const val = async (claims, sql, params) => (await asQuery(claims, sql, params)).rows[0].r;
  const json = async (claims, sql, params) => { const r = await val(claims, sql, params); return typeof r === 'string' ? JSON.parse(r) : r; };
  const CUST = { sub: CUSTOMER, role: 'authenticated' };
  const SERVICE = { role: 'service_role' };
  const addDays = (ymd, n) => { const d = new Date(`${ymd}T00:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
  const today = (await db.query(`SELECT internal.today_ist()::text AS d`)).rows[0].d;

  await db.query(`INSERT INTO public.admin_role_permissions (role_id, permission) VALUES ($1, 'customers:view'), ($1, 'daily_ops:edit') ON CONFLICT DO NOTHING`, [roleId]);

  // Variants at the prices the plan's example uses.
  const V50 = 'a0390000-0000-4000-8000-0000000000c1';
  const V60 = 'a0390000-0000-4000-8000-0000000000c2';
  await db.exec(`INSERT INTO public.product_variants (id, product_id, label, price, weight_grams, is_active, free_delivery)
                 VALUES ('${V50}', '${PROD}', '500 ml', 50, 500, true, false), ('${V60}', '${PROD}', '600 ml', 60, 600, true, false)`);

  let n = 0;
  const mkUser = async (balance) => {
    const id = randomUUID(); n++;
    await db.query(`INSERT INTO public.users (id, email, phone, first_name, wallet_balance) VALUES ($1, $2, $3, 'W', $4)`,
      [id, `w${n}-039@example.com`, `9039${String(n).padStart(6, '0')}`, balance]);
    return id;
  };
  const setBalance = (u, b) => db.query(`UPDATE public.users SET wallet_balance = $2 WHERE id = $1`, [u, b]);
  const mkArea = async (name, freq, ref) => {
    const id = randomUUID();
    await db.query(`INSERT INTO public.delivery_areas (id, display_name, is_active, delivary_frequency, reference_date) VALUES ($1, $2, true, $3, $4)`, [id, name, freq, ref]);
    return id;
  };
  const mkSub = async (user, { area = 'Daily 039', start, variant = VAR, qty = 1, label = null } = {}) => {
    const id = randomUUID();
    await db.query(`INSERT INTO public.subscriptions (id, user_id, status, payment_method, start_date, delivary_area, created_at, label, snapshot_pincode)
                    VALUES ($1, $2, 'active', 'wallet', $3, $4, now(), $5, '700001')`, [id, user, start, area, label]);
    await db.query(`INSERT INTO public.subscription_items (subscription_id, variant_id, product_name_snapshot, variant_label_snapshot, unit_price, quantity, item_start_date, is_active)
                    VALUES ($1, $2, 'Milk', 'x', 1, $3, $4, true)`, [id, variant, qty, start]);
    return id;
  };
  const pause = (sub, from, to) => db.query(`INSERT INTO public.subscription_pauses (subscription_id, pause_start_date, pause_end_date, created_by) VALUES ($1, $2, $3, 'admin')`, [sub, from, to ?? from]);
  const move = async (sub, from, to, areaId) => {
    const id = randomUUID();
    await db.query(`INSERT INTO public.delivery_day_overrides (id, override_date, swapped_with_area_id, selection_type, override_kind, from_date, to_date)
                    VALUES ($1, $2, $3, 'customer', 'move', $4, $2)`, [id, to, areaId, from]);
    await db.query(`INSERT INTO public.delivery_day_override_subscriptions (override_id, subscription_id) VALUES ($1, $2)`, [id, sub]);
  };
  const forecast = async (u, days, from) => {
    const r = (await db.query(`SELECT internal.wallet_forecast($1, $2, $3::date) AS f`, [u, days, from])).rows[0].f;
    return typeof r === 'string' ? JSON.parse(r) : r;
  };
  const AREA_DAILY_039 = await mkArea('Daily 039', 1, null);

  // ── 13a. The reserve (W-01, D-1) ──────────────────────────────────────────
  const R = await mkUser(0);
  eq('no subscriptions → reserve 0', num(await val(null, `SELECT internal.wallet_reserve($1) AS r`, [R])), 0);
  await mkSub(R, { start: '2099-01-01' });
  eq('one ₹100 subscription → reserve 100 (one delivery, not three)', num(await val(null, `SELECT internal.wallet_reserve($1) AS r`, [R])), 100);
  eq('get_wallet_reserve: own id', num(await val({ sub: R, role: 'authenticated' }, `SELECT public.get_wallet_reserve($1) AS r`, [R])), 100);
  await expectError('get_wallet_reserve: another customer is refused',
    () => val(CUST, `SELECT public.get_wallet_reserve($1) AS r`, [R]), 'not authorized');
  eq('get_wallet_reserve: admin with customers:view', num(await val(ADMIN_CLAIMS, `SELECT public.get_wallet_reserve($1) AS r`, [R])), 100);

  // create_subscription: wallet must cover the next delivery of existing + new.
  const createSub = (user, label) => asQuery({ sub: user, role: 'authenticated' },
    `SELECT public.create_subscription($1, $2::timestamptz, NULL, 'active', $3::jsonb, $4::jsonb, $5) AS id`,
    [user, '2099-02-01T00:00:00Z', JSON.stringify({ pincode: '700001', name: 'W' }),
     JSON.stringify([{ variantId: VAR, name: 'Cow Milk', variant: '1 L', price: 100, quantity: 1, startDate: '2099-02-01' }]), label]);
  await setBalance(R, 199);
  await expectError('create subscription: one rupee short of existing (100) + new (100) is refused',
    () => createSub(R, 'Second'), 'next delivery of all your subscriptions');
  await setBalance(R, 200);
  await expectOk('create subscription: exactly existing (100) + new (100) is enough', () => createSub(R, 'Second'));

  // place_order: order + reserve.
  const reserveC = num(await val(null, `SELECT internal.wallet_reserve($1) AS r`, [CUSTOMER]));
  const ORDER_TOTAL = 140;  // 1 × VAR + ₹40 delivery (see 6i)
  await setBalance(CUSTOMER, ORDER_TOTAL + reserveC - 1);
  await expectError(`wallet order: one rupee short of order (${ORDER_TOTAL}) + reserve (${reserveC}) is refused`,
    () => asQuery(CUST, `SELECT public.place_order($1,$2,'wallet',40,$3::jsonb)`, [CUSTOMER, ADDR, CART]), 'next delivery');
  await setBalance(CUSTOMER, ORDER_TOTAL + reserveC);
  await expectOk('wallet order: exactly order + reserve succeeds',
    () => asQuery(CUST, `SELECT public.place_order($1,$2,'wallet',40,$3::jsonb)`, [CUSTOMER, ADDR, CART]));
  eq('…and leaves exactly the reserve', num((await db.query(`SELECT wallet_balance FROM public.users WHERE id = $1`, [CUSTOMER])).rows[0].wallet_balance), reserveC);
  await setBalance(CUSTOMER, ORDER_TOTAL);
  await expectOk('an admin placing the order is not bound by the reserve',
    () => asQuery(ADMIN_CLAIMS, `SELECT public.place_order($1,$2,'wallet',40,$3::jsonb)`, [CUSTOMER, ADDR, CART]));
  await setBalance(CUSTOMER, 5000);

  // ── 13b. The forecast (W-02) ──────────────────────────────────────────────
  const T = '2098-08-01';
  const NOSUB = await mkUser(500);
  const f0 = await forecast(NOSUB, 14, T);
  eq('no subscriptions: no days, nothing covered-until, next delivery covered',
    { days: f0.days.length, until: f0.covered_until, covered: f0.next_delivery_covered }, { days: 0, until: null, covered: true });

  await mkArea('Alt odd 039', 2, addDays(T, 1));
  await mkArea('Alt even 039', 2, addDays(T, 2));
  const M = await mkUser(300);
  await mkSub(M, { start: T, variant: V50 });
  await mkSub(M, { area: 'Alt odd 039', start: T, variant: VAR });
  await mkSub(M, { area: 'Alt even 039', start: T, variant: V60 });
  const fm = await forecast(M, 3, T);
  eq('mixed customer: day amounts 150, 110, 150', fm.days.map((d) => d.amount), [150, 110, 150]);
  eq('mixed customer: covered until day 2, first uncovered day 3, 2 deliveries',
    { until: fm.covered_until, first: fm.first_uncovered_date, n: fm.covered_deliveries }, { until: addDays(T, 2), first: addDays(T, 3), n: 2 });
  eq('mixed customer: reserve 210 (one delivery of each), available 90',
    { reserve: num(fm.reserve), available: num(fm.available) }, { reserve: 210, available: 90 });
  eq('alternate-day subscription only on its days', fm.days.map((d) => d.subscriptions.length), [2, 2, 2]);
  eq('today is never included', fm.days.some((d) => d.date === T), false);

  const P = await mkUser(1000);
  const ps = await mkSub(P, { start: T });
  await pause(ps, addDays(T, 2));
  eq('a paused day is absent', (await forecast(P, 3, T)).days.map((d) => d.date), [addDays(T, 1), addDays(T, 3)]);

  const MV = await mkUser(1000);
  const mvs = await mkSub(MV, { area: 'Alt even 039', start: T });
  await move(mvs, addDays(T, 2), addDays(T, 3), AREA_DAILY_039);
  eq('moved delivery: on its new date, not the old one', (await forecast(MV, 4, T)).days.map((d) => d.date), [addDays(T, 3), addDays(T, 4)]);

  const E = await mkUser(1000);
  const es = await mkSub(E, { start: T });
  const editOrder = async (sub, user, date, qty, extra = '') => {
    const id = randomUUID();
    await db.exec(`BEGIN;
      INSERT INTO public.subscription_daily_orders (id, delivery_date, subscription_id, user_id, status, total_value, payment_status, paid_amount, is_customer_modified)
      VALUES ('${id}', '${date}', '${sub}', '${user}', 'pending', ${qty * 100}, ${extra ? `'paid', ${qty * 100}` : `'pending', 0`}, true);
      INSERT INTO public.subscription_daily_order_items (daily_order_id, variant_id, product_name_snapshot, variant_label_snapshot, unit_price, quantity, total_price)
      VALUES ('${id}', '${VAR}', 'Milk', '1 L', 100, ${qty}, ${qty * 100});
      COMMIT;`);
  };
  await editOrder(es, E, addDays(T, 1), 3);
  await editOrder(es, E, addDays(T, 2), 1, 'paid');
  const fe = await forecast(E, 3, T);
  eq('customer-edited day shows the edited total; an already-paid day contributes 0',
    fe.days.map((d) => [d.date, d.amount]), [[addDays(T, 1), 300], [addDays(T, 3), 100]]);

  const L8 = await mkUser(1000);
  await mkSub(L8, { start: addDays(T, 4) });
  eq('a subscription starting later first appears on its start date', (await forecast(L8, 6, T)).days[0].date, addDays(T, 4));

  await expectError('get_wallet_forecast: another customer is refused',
    () => json(CUST, `SELECT public.get_wallet_forecast($1, 14) AS r`, [M]), 'not authorized');
  await expectOk('get_wallet_forecast: admin with customers:view', () => json(ADMIN_CLAIMS, `SELECT public.get_wallet_forecast($1, 14) AS r`, [M]));
  await expectOk('get_wallet_forecast: own id', () => json({ sub: M, role: 'authenticated' }, `SELECT public.get_wallet_forecast($1, 14) AS r`, [M]));

  // ── 13c. Notice after finalize (W-07) — real "today" ─────────────────────
  const claimLow = async (claims, ids) => (await asQuery(claims,
    `SELECT user_id, delivery_date::text AS d, balance, amount FROM public.claim_low_balance_notices($1::uuid[])`, [`{${ids.join(',')}}`])).rows;
  const COV = await mkUser(500);  await mkSub(COV, { start: today });
  const SHORT = await mkUser(99); await mkSub(SHORT, { start: today });
  const r1 = await claimLow(ADMIN_CLAIMS, [COV, SHORT]);
  eq('covered customer not returned; ₹1 short returned with tomorrow and ₹100',
    r1.map((x) => [x.user_id === SHORT, x.d, num(x.amount)]), [[true, addDays(today, 1), 100]]);
  eq('second call: nothing for that customer and date', (await claimLow(ADMIN_CLAIMS, [SHORT])).length, 0);
  await mkArea('Alt 039 notice', 2, addDays(today, 2));
  const ALT = await mkUser(0); await mkSub(ALT, { area: 'Alt 039 notice', start: today });
  eq('alternate-day customer: evaluated on the real next delivery', (await claimLow(ADMIN_CLAIMS, [ALT])).map((x) => x.d), [addDays(today, 2)]);
  const PZ = await mkUser(0); const pzs = await mkSub(PZ, { start: today }); await pause(pzs, addDays(today, 1));
  eq('paused next day: the following delivery is used', (await claimLow(ADMIN_CLAIMS, [PZ])).map((x) => x.d), [addDays(today, 2)]);
  await expectError('a customer cannot claim notices', () => claimLow(CUST, [SHORT]), 'not authorized');
  await asQuery(SERVICE, `SELECT public.mark_wallet_notice_result($1, $2::date, true)`, [SHORT, addDays(today, 1)]);
  eq('mark_wallet_notice_result marks it sent', (await db.query(`SELECT status FROM public.wallet_notice_log WHERE user_id = $1`, [SHORT])).rows[0].status, 'sent');
  await expectError('a customer cannot mark a notice', () => asQuery(CUST, `SELECT public.mark_wallet_notice_result($1, $2::date, true)`, [SHORT, addDays(today, 1)]), 'not authorized');

  // ── 13d. Reminder settings (W-08a) ────────────────────────────────────────
  const settings = (claims) => json(claims, `SELECT public.get_wallet_reminder_settings() AS r`);
  const setSettings = (claims, enabled, time) => json(claims, `SELECT public.set_wallet_reminder_settings($1, $2::time) AS r`, [enabled, time]);
  const s0 = await settings(SERVICE);
  eq('fresh: enabled, 18:00, Asia/Kolkata, 120-minute window',
    [s0.enabled, s0.reminder_time, s0.timezone, s0.send_window_minutes], [true, '18:00', 'Asia/Kolkata', 120]);
  await expectError('a customer cannot read the settings', () => settings(CUST), 'not authorized');
  await db.query(`DELETE FROM public.admin_role_permissions WHERE role_id = $1 AND permission = 'notifications:send'`, [roleId]);
  await expectError('an admin without notifications:send cannot read them', () => settings(ADMIN_CLAIMS), 'not authorized');
  await expectError('…or change them', () => setSettings(ADMIN_CLAIMS, true, '19:00'), 'not authorized');
  await db.query(`INSERT INTO public.admin_role_permissions (role_id, permission) VALUES ($1, 'notifications:send') ON CONFLICT DO NOTHING`, [roleId]);
  eq('an admin with notifications:send can change the time', (await setSettings(ADMIN_CLAIMS, true, '19:30')).reminder_time, '19:30');
  await expectError('time is required', () => setSettings(ADMIN_CLAIMS, true, null), 'Choose a reminder time');
  await expectOk('migration 039 re-runs cleanly', () => db.exec(read(`${ROOT}/migrations/039_wallet_simplification.sql`)));
  eq('re-running the migration keeps the admin\'s 19:30', (await settings(SERVICE)).reminder_time, '19:30');
  await setSettings(SERVICE, true, '18:00');

  // ── 13e. claim_wallet_reminders (W-08a) ───────────────────────────────────
  const claimAt = async (date, time, claims = SERVICE) => (await asQuery(claims,
    `SELECT user_id, delivery_date::text AS d, amount FROM public.claim_wallet_reminders($1::timestamptz)`,
    [`${date}T${time}:00+05:30`])).rows;
  const has = (rows, u) => rows.some((x) => x.user_id === u);
  const reminderUser = async (balance, start) => { const u = await mkUser(balance); const s = await mkSub(u, { start }); return [u, s]; };

  const F1 = '2098-10-01';
  const [A1] = await reminderUser(0, F1);
  eq('17:59 India time: nothing', has(await claimAt(F1, '17:59'), A1), false);
  const at18 = await claimAt(F1, '18:00');
  eq('18:00: the uncovered customer, for tomorrow, ₹100', at18.filter((x) => x.user_id === A1).map((x) => [x.d, num(x.amount)]), [[addDays(F1, 1), 100]]);
  eq('a call a minute later: no duplicate', has(await claimAt(F1, '18:01'), A1), false);
  const F2 = '2098-10-03'; const [A2] = await reminderUser(0, F2);
  eq('19:59: still inside the window', has(await claimAt(F2, '19:59'), A2), true);
  const F3 = '2098-10-05'; const [A3] = await reminderUser(0, F3);
  eq('20:00: window passed', has(await claimAt(F3, '20:00'), A3), false);

  await setSettings(SERVICE, true, '20:30');
  const F4 = '2098-10-07'; const [A4] = await reminderUser(0, F4);
  eq('time changed to 20:30: nothing at 18:10', has(await claimAt(F4, '18:10'), A4), false);
  eq('…sent at 20:35', has(await claimAt(F4, '20:35'), A4), true);
  await setSettings(SERVICE, false, '18:00');
  const F5 = '2098-10-09'; const [A5] = await reminderUser(0, F5);
  eq('turned off: nothing at 18:30', has(await claimAt(F5, '18:30'), A5), false);
  await setSettings(SERVICE, true, '18:00');

  const F6 = '2098-10-11'; const [B6] = await reminderUser(0, F6);
  await setBalance(B6, 500);  // recharged before the reminder time
  eq('recharged before the reminder: not reminded', has(await claimAt(F6, '18:00'), B6), false);

  const F7 = '2098-10-13';
  await mkArea('Alt 039 reminder', 2, addDays(F7, 2));
  const C7 = await mkUser(0); await mkSub(C7, { area: 'Alt 039 reminder', start: F7 });
  eq('alternate day: no delivery tomorrow → not reminded today', has(await claimAt(F7, '18:00'), C7), false);
  eq('…reminded the next evening', has(await claimAt(addDays(F7, 1), '18:00'), C7), true);

  const F8 = '2098-10-17'; const [D8, d8s] = await reminderUser(0, F8);
  await pause(d8s, addDays(F8, 1));
  eq('paused tomorrow: not reminded', has(await claimAt(F8, '18:00'), D8), false);

  const F9 = '2098-10-19'; const [E9, e9s] = await reminderUser(0, F9);
  await move(e9s, addDays(F9, 1), addDays(F9, 5), AREA_DAILY_039);
  eq('delivery moved away from tomorrow: not reminded', has(await claimAt(F9, '18:00'), E9), false);

  const F10 = '2098-10-21'; const [N10] = await reminderUser(0, F10);
  await db.query(`INSERT INTO public.wallet_notice_log (user_id, delivery_date, source, balance, amount, status, sent_at)
                  VALUES ($1, $2, 'finalize', 0, 100, 'sent', now())`, [N10, addDays(F10, 1)]);
  eq('already told by the finalize notice: not reminded', has(await claimAt(F10, '18:00'), N10), false);

  const F11 = '2098-10-23'; const [G11] = await reminderUser(0, F11);
  const markG = (ok) => asQuery(SERVICE, `SELECT public.mark_wallet_notice_result($1, $2::date, $3, 'push failed')`, [G11, addDays(F11, 1), ok]);
  eq('failed retry: attempt 1', has(await claimAt(F11, '18:00'), G11), true);
  await markG(false);
  eq('failed retry: attempt 2', has(await claimAt(F11, '18:10'), G11), true);
  await markG(false);
  eq('failed retry: attempt 3', has(await claimAt(F11, '18:20'), G11), true);
  await markG(false);
  eq('failed retry: no 4th attempt', has(await claimAt(F11, '18:30'), G11), false);
  const F12 = '2098-10-25'; const [S12] = await reminderUser(0, F12);
  await claimAt(F12, '18:00');
  await asQuery(SERVICE, `SELECT public.mark_wallet_notice_result($1, $2::date, true)`, [S12, addDays(F12, 1)]);
  eq('a sent reminder is never returned again', has(await claimAt(F12, '19:00'), S12), false);

  await expectError('a customer cannot claim reminders', () => claimAt(F12, '18:00', CUST), 'not authorized');
  await expectError('an admin cannot claim reminders (service role only)', () => claimAt(F12, '18:00', ADMIN_CLAIMS), 'not authorized');

  // ── 13f. Grants ───────────────────────────────────────────────────────────
  const g = (await db.query(`
    SELECT
      has_function_privilege('authenticated', 'public.get_wallet_forecast(uuid, integer)', 'EXECUTE')          AS a1,
      has_function_privilege('authenticated', 'public.get_wallet_reserve(uuid)', 'EXECUTE')                   AS a2,
      has_function_privilege('authenticated', 'public.get_wallet_reminder_settings()', 'EXECUTE')              AS a3,
      has_function_privilege('anon', 'public.get_wallet_forecast(uuid, integer)', 'EXECUTE')                   AS n1,
      has_function_privilege('anon', 'public.claim_wallet_reminders(timestamptz)', 'EXECUTE')                  AS n2,
      has_function_privilege('anon', 'public.set_wallet_reminder_settings(boolean, time)', 'EXECUTE')          AS n3,
      has_function_privilege('authenticated', 'internal.wallet_forecast(uuid, integer, date)', 'EXECUTE')      AS i1,
      has_function_privilege('authenticated', 'internal.wallet_reserve(uuid)', 'EXECUTE')                      AS i2,
      has_table_privilege('authenticated', 'public.wallet_notice_log', 'SELECT')                               AS t1,
      has_table_privilege('authenticated', 'public.wallet_reminder_settings', 'UPDATE')                        AS t2`)).rows[0];
  if (g.a1 && g.a2 && g.a3 && !g.n1 && !g.n2 && !g.n3 && !g.i1 && !g.i2 && !g.t1 && !g.t2) {
    ok('039 grants: RPCs for authenticated/service_role only; internals and the two tables closed');
  } else {
    bad('039 grants', JSON.stringify(g));
  }
}

// ---------------------------------------------------------------------------
// 14. Migration 040: indexes only
// ---------------------------------------------------------------------------
console.log('\n--- 14. Migration 040: indexes ---');
await expectOk('migration 040 re-runs cleanly', () => db.exec(read(`${ROOT}/migrations/040_indexes.sql`)));
{
  const n = Number((await db.query(`SELECT count(*) AS n FROM pg_indexes WHERE schemaname = 'public' AND indexname IN (
    'idx_orders_expected_delivery_open', 'idx_orders_expected_delivery_delivered',
    'idx_subscriptions_address_id', 'idx_subscriptions_created_at', 'idx_subscriptions_user_status',
    'idx_users_created_at', 'idx_addresses_created_at', 'idx_reviews_created_at',
    'idx_sdo_user_date', 'idx_wallet_tx_user_created')`)).rows[0].n);
  if (n === 10) ok('all 10 indexes from 040 exist'); else bad('040 indexes', `found ${n} of 10`);
}

// ---------------------------------------------------------------------------
// 15. Migration 041: dashboard numbers
// ---------------------------------------------------------------------------
console.log('\n--- 15. Migration 041: dashboard stats ---');
{
  await expectOk('migration 041 re-runs cleanly', () => db.exec(read(`${ROOT}/migrations/041_dashboard_stats.sql`)));
  const stats = async (claims) => {
    const r = (await asQuery(claims, `SELECT public.get_dashboard_stats() AS r`)).rows[0].r;
    return typeof r === 'string' ? JSON.parse(r) : r;
  };
  const expected = (await db.query(`
    SELECT
      (SELECT count(*) FROM public.subscriptions WHERE status = 'active')::int AS subs,
      (SELECT count(*) FROM public.users WHERE is_adhoc = false)::int AS customers,
      (SELECT COALESCE(round(SUM(amount), 2), 0) FROM public.wallet_transactions
        WHERE type = 'credit' AND created_at >= (internal.today_ist()::timestamp AT TIME ZONE 'Asia/Kolkata'))::numeric AS credits`)).rows[0];
  const s = await stats({ role: 'service_role' });
  const got = { subs: Number(s.active_subscriptions), customers: Number(s.total_customers), credits: Number(s.today_wallet_credits) };
  const want = { subs: Number(expected.subs), customers: Number(expected.customers), credits: Number(expected.credits) };
  if (JSON.stringify(got) === JSON.stringify(want)) ok(`dashboard numbers match direct counts (${JSON.stringify(want)})`);
  else bad('dashboard numbers', `expected ${JSON.stringify(want)}, got ${JSON.stringify(got)}`);
  // A credit created just before India midnight belongs to yesterday.
  const U = '0a410000-0000-4000-8000-000000000001';
  await db.query(`INSERT INTO public.users (id, email, phone, first_name, wallet_balance) VALUES ($1, 'd041@example.com', '9041000001', 'D', 0)`, [U]);
  await db.query(`INSERT INTO public.wallet_transactions (user_id, type, amount, balance_after, description, created_at)
                  VALUES ($1, 'credit', 777, 0, 'before IST midnight', (internal.today_ist()::timestamp AT TIME ZONE 'Asia/Kolkata') - interval '1 minute'),
                         ($1, 'credit', 23, 0, 'after IST midnight',  (internal.today_ist()::timestamp AT TIME ZONE 'Asia/Kolkata') + interval '1 minute')`, [U]);
  const s2 = await stats({ role: 'service_role' });
  if (Number(s2.today_wallet_credits) === Number(expected.credits) + 23) ok('wallet credits count from midnight India time (777 before it excluded, 23 after it included)');
  else bad('IST day boundary', `credits ${s2.today_wallet_credits}, base ${expected.credits}`);
  await expectError('a customer cannot read the dashboard', () => stats({ sub: CUSTOMER, role: 'authenticated' }), 'not authorized');
}

console.log(`\n=== ${pass} passed, ${fail} failed ===`);
process.exit(fail ? 1 : 0);
