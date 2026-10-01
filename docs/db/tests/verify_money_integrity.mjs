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
                 '034_reschedule_order_snaps_to_delivery_day.sql']) {
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
//     required = 3 × normal commitment (all subs) + this day's one-off extra,
//     checked only when the edit raises THIS subscription's cost; and saving
//     one subscription's day never deletes another subscription's order.
// ---------------------------------------------------------------------------
const EDIT_DATE = '2099-02-01';
const commitment = Number((await db.query(
  `SELECT public.get_user_daily_commitment($1) AS c`, [CUSTOMER])).rows[0].c);
// modSub (6u) is 1 × VAR = ₹100/day; editing to 5 × VAR = ₹500 → extra ₹400.
const EDIT_ITEMS = JSON.stringify([{ variant_id: VAR, quantity: 5 }]);
const editRequired = Math.round((commitment * 3 + 400) * 100) / 100;

await db.exec(`UPDATE public.users SET wallet_balance = ${editRequired - 1} WHERE id = '${CUSTOMER}'`);
await expectError('day edit refused when wallet < 3-day commitment + one-off extra',
  () => asQuery(CUST_CLAIMS, `SELECT public.modify_daily_order($1, $2, $3::date, $4::jsonb)`,
    [CUSTOMER, modSub, EDIT_DATE, EDIT_ITEMS]), 'Insufficient wallet balance');

await db.exec(`UPDATE public.users SET wallet_balance = ${editRequired} WHERE id = '${CUSTOMER}'`);
await expectOk(`day edit allowed at exactly 3 × commitment (${commitment}) + extra 400 = ${editRequired} (022 would have needed ${Math.round((commitment + 400) * 3)})`,
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
const bulkRequired3 = Math.round((bulkCommitment * 3 + totalExtraFor3) * 100) / 100;
// A per-day-only check (022/025's OLD behaviour re-applied 3 times) would have
// passed at (commitment*3 + 400) for each call; this must refuse below the
// AGGREGATE requirement even though it's above any single day's requirement.
const perDayOnlyRequired = Math.round((bulkCommitment * 3 + 400) * 100) / 100;

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
await asQuery(ADMIN_CLAIMS,
  `SELECT public.reschedule_order($1, '2026-12-25'::date) AS o`, [orderForReschedule]);
const rescheduleResult = (await db.query(
  `SELECT expected_delivery_date::text AS d FROM public.orders WHERE id = $1`, [orderForReschedule])).rows[0];
if (rescheduleResult.d === '2026-12-25') {
  ok('reschedule_order: admin can reschedule to a future date');
} else {
  bad('reschedule_order', JSON.stringify(rescheduleResult));
}

// 8r2. reschedule_order snaps to the area's delivery day (migration 034).
//      Alternate Area 033: frequency 2, reference_date 2026-10-01, so it
//      delivers on 1, 3, 5 Oct… A request for 2026-10-02 (not a delivery day)
//      must snap forward to 2026-10-03.
const orderAltArea = (await asQuery(CUST_CLAIMS,
  `SELECT public.place_order($1, $2, 'cod', 0, $3::jsonb) AS id`,
  [CUSTOMER, ADDR_TEST2, CART])).rows[0].id;
await asQuery(ADMIN_CLAIMS,
  `SELECT public.reschedule_order($1, '2026-10-02'::date)`, [orderAltArea]);
const snapped034 = (await db.query(
  `SELECT expected_delivery_date::text AS d FROM public.orders WHERE id = $1`, [orderAltArea])).rows[0];
if (snapped034.d === '2026-10-03') {
  ok('reschedule_order snaps a non-delivery day forward to the area cadence (2 Oct → 3 Oct)');
} else {
  bad('reschedule_order snap', JSON.stringify(snapped034));
}

// 8r3. A request that is already a delivery day is kept.
await asQuery(ADMIN_CLAIMS,
  `SELECT public.reschedule_order($1, '2026-10-05'::date)`, [orderAltArea]);
const kept034 = (await db.query(
  `SELECT expected_delivery_date::text AS d FROM public.orders WHERE id = $1`, [orderAltArea])).rows[0];
if (kept034.d === '2026-10-05') {
  ok('reschedule_order keeps a date that is already a delivery day (5 Oct)');
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

console.log(`\n=== ${pass} passed, ${fail} failed ===`);
process.exit(fail ? 1 : 0);
