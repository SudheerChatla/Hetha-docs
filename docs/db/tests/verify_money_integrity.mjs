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

// Act as a given caller for the duration of `fn`.
async function as(claims, sql) {
  const json = claims === null ? '' : JSON.stringify(claims);
  await db.exec(`SELECT set_config('request.jwt.claims', '${json.replace(/'/g, "''")}', false);`);
  return db.exec(sql);
}
async function asQuery(claims, sql, params) {
  const json = claims === null ? '' : JSON.stringify(claims);
  await db.query(`SELECT set_config('request.jwt.claims', $1, false)`, [json]);
  return db.query(sql, params);
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
    reconciled_at timestamptz,
    total_orders integer, total_value numeric,
    wallet_deduction_completed_at timestamptz,
    updated_at timestamptz DEFAULT now()
  );
`);

// RBAC helpers + the pre-existing functions the migrations replace.
// `get_user_role` is stripped: it is LANGUAGE sql, so Postgres validates its body
// at CREATE time and it references a column that does not exist
// (admin_users.role / .auth_user_id). `\r?\n` because the working tree may have
// CRLF endings on Windows.
const functions = read(`${ROOT}/functions.sql`);
const functionsWithoutBroken = functions.replace(
  /^-- get_user_role[\s\S]*?\$function\$;\r?\n/m, '');
if (functionsWithoutBroken === functions) {
  console.log('WARNING: get_user_role was not stripped — the CREATE will fail');
}
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
  INSERT INTO public.products (id, category_id, name, in_stock)
  VALUES ('${PROD}', '${CAT}', 'Cow Milk', true);
  INSERT INTO public.product_variants (id, product_id, label, price, weight_grams, is_active, free_delivery)
  VALUES ('${VAR}', '${PROD}', '1 L', 100, 1000, true, false);

  INSERT INTO public.addresses (id, user_id, name, phone_number, address_line1, city, state, pincode, address_type)
  VALUES ('${ADDR}', '${CUSTOMER}', 'Cust', '9000000001', '1 Main St', 'Chennai', 'TN', '600001', 'home');

  INSERT INTO public.delivery_charge_tiers (min_weight_grams, max_weight_grams, charge)
  VALUES (1, 1000, 40), (1001, 5000, 60);
`);

// ---------------------------------------------------------------------------
// 4. Pre-migration exploit demonstration
// ---------------------------------------------------------------------------
console.log('\n--- BEFORE the migrations (documenting the vulnerabilities) ---');

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
                 '012_money_invariants.sql']) {
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

// 6i. 3-day wallet buffer enforced server-side (daily commitment is now 100/day
//     → 300 reserved; drop the balance below order+reserve and expect refusal).
await db.exec(`UPDATE public.users SET wallet_balance = 200 WHERE id = '${CUSTOMER}'`);
await expectError('3-day subscription buffer enforced', () => asQuery({ sub: CUSTOMER, role: 'authenticated' },
  `SELECT public.place_order($1,$2,'wallet',40,$3::jsonb)`, [CUSTOMER, ADDR, CART]), 'reserved for 3 days');
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
    has_function_privilege('anon','public.quote_cart(jsonb)','EXECUTE')                                           AS anon_quote`);
const g = grants.rows[0];
const mustBeFalse = ['anon_place_order','anon_wallet','cust_intent','cust_settle','cust_internal','cust_intents_table'];
const leaks = mustBeFalse.filter((k) => g[k] !== false);
if (leaks.length === 0 && g.cust_place_order === true && g.anon_quote === true) {
  ok('privilege surface is tight (no anon money RPCs, no customer payment-intent access, internal sealed)');
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
const anonExpected = ['has_permission', 'is_super_admin', 'quote_cart'];
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

console.log(`\n=== ${pass} passed, ${fail} failed ===`);
process.exit(fail ? 1 : 0);
