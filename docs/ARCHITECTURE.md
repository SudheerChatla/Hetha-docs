# System Architecture

This document describes the Hetha Organics platform as a whole: the two client
applications, the shared Supabase backend, and the cross-cutting flows (auth,
payments, the subscription/wallet model) that span both clients.

For client-specific internals, see each repo's own architecture doc:

- [`Hetha_app/docs/ARCHITECTURE.md`](../Hetha_app/docs/ARCHITECTURE.md) — Flutter app
- [`Hetha_admin/docs/ARCHITECTURE.md`](../Hetha_admin/docs/ARCHITECTURE.md) — Next.js admin panel

For the database schema, see [DATA_MODEL.md](./DATA_MODEL.md).

---

## 1. Topology

```
   Customers                                   Internal staff
       │                                              │
       ▼                                              ▼
┌──────────────────┐                       ┌─────────────────────────┐
│  Hetha_app       │                       │  Hetha_admin            │
│  Flutter client  │                       │  Next.js (server+client)│
│                  │                       │                         │
│  supabase_flutter│                       │  @supabase/ssr          │
│  (anon key)      │                       │  (anon key, cookies)    │
└────────┬─────────┘                       │  @supabase/supabase-js  │
         │                                 │  (service role, server) │
         │                                 └───────────┬─────────────┘
         │                                             │
         │           anon key → RLS enforced           │  service role → bypasses RLS
         │                                             │  (privileged ops only)
         ▼                                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│                          Supabase project                             │
│                                                                       │
│  • Auth (email/password)                                              │
│  • Postgres: 25+ tables (see DATA_MODEL.md)                           │
│  • Row-Level Security policies                                        │
│  • Database functions / RPCs (place_order, create_subscription, …)    │
│  • Edge Functions (Deno): razorpay { create-order, verify-payment,    │
│    verify-order-payment }                                             │
└──────────────────────────────────────┬────────────────────────────────┘
                                        │  HMAC-SHA256 verified, server-side
                                        ▼
                                 ┌──────────────┐
                                 │   Razorpay   │
                                 └──────────────┘
```

Both clients are **thin** relative to the backend: business rules that must be
trusted (placing orders, deducting the wallet, verifying payments, generating
daily orders) live in Postgres RPCs and edge functions, not in the clients.

---

## 2. Two clients, one backend — why and how

| | Hetha_app | Hetha_admin |
|---|-----------|-------------|
| **Who** | Paying customers | Internal operations / management |
| **Platform** | Mobile + web + desktop (Flutter) | Web (Next.js, mostly desktop) |
| **Supabase key** | anon (publishable) only | anon (cookie session) + service role (server only) |
| **Trust boundary** | Fully untrusted; RLS-constrained | Authenticated staff; RBAC-gated; some service-role escape hatches |
| **Auth identity** | Supabase Auth user → `users` row | Supabase Auth user → `admin_users` row + role/permissions |

The clients never talk to each other. They coordinate **only through shared
database state** — a subscription created in the app appears in the admin panel
because both read the same `subscriptions` table.

### Consequences of the shared backend

- **Schema changes are a contract change for both clients.** A column rename or
  RPC signature change can break the app, the panel, or both. Treat
  [DATA_MODEL.md](./DATA_MODEL.md) as the shared interface and update it with the
  migration.
- **Known quirk:** the `subscriptions` table columns are spelled
  `delivary_area` / `delivary_frequency` (sic). Both clients use the
  misspelling because that is the real column name. Don't "fix" it in one client
  without migrating the column and the other client together.

---

## 3. Authentication & authorization

### Customer auth (Hetha_app)

- Supabase Auth email/password (`SupabaseAuthService`).
- `authStateChangesProvider` (Riverpod) streams `onAuthStateChange`; the
  `AuthWrapper` routes to the app shell or the sign-in page.
- Every query runs as the signed-in user; **RLS** restricts rows to that user
  (their cart, orders, subscriptions, wallet, addresses).

### Admin auth (Hetha_admin)

Defense in depth, because the panel can see and mutate everyone's data:

1. **Page gate** — `middleware.ts` matches `/admin/:path*`; if there is no
   Supabase session it redirects to `/` (login).
2. **Server layout gate** — `app/admin/layout.tsx` re-checks the session
   server-side before rendering the shell.
3. **API gate** — every `/api/admin/*` route calls
   `requireAdmin(permission)`. This verifies the session, loads the caller's
   permissions from the RBAC tables, and returns `401` (no session) / `403`
   (not an admin, or missing the required permission). `super_admin` bypasses
   specific permission checks.
4. **RBAC data** — `roles`, `admin_users`, `admin_role_permissions`,
   `admin_permissions`. Permission keys follow `resource:action`
   (`orders:view`, `subscriptions:edit`, …); the catalog is in
   `lib/constants.ts` (`PAGE_PERMISSIONS`).

> The page middleware is a UX gate, not the security boundary. The real
> boundary is `requireAdmin` on the API routes plus RLS in Postgres. Never rely
> on the middleware alone to protect data.

### The service-role client

`lib/admin-client.ts` creates a **service-role** Supabase client that **bypasses
RLS**. It exists for privileged operations the cookie client can't perform (e.g.
`auth.admin.createUser` for the "convert to app user" flow). Rules:

- Server-only. Never imported into a client component.
- Only used inside routes already gated by `requireAdmin`.
- Its key (`SUPABASE_SERVICE_ROLE_KEY`) is treated like a database root password
  and is never exposed to the browser (no `NEXT_PUBLIC_` prefix).

---

## 4. The subscription + wallet model (the heart of the system)

This is the most important cross-cutting flow. Both clients and several RPCs
participate.

### Prepaid wallet

- `users.wallet_balance` holds prepaid funds (DB `CHECK (>= 0)`).
- All balance changes go through **`internal.apply_wallet_delta()`**, which locks
  the row (`SELECT … FOR UPDATE`) and writes a matching `wallet_transactions` row
  with a `balance_after` snapshot in the same transaction.
- The public `update_wallet_balance` RPC is a thin authorization wrapper around it
  (service role, super admin, or `customers:edit`). Customer JWTs are rejected.
- `authenticated` has **no UPDATE grant on the `wallet_balance` column**, so the
  balance cannot be written from a client even though RLS allows own-row updates.

### Subscriptions

- Created via the `create_subscription` RPC. Limits a user to **5 active
  subscriptions** and accepts an optional `label`.
- Each subscription has `subscription_items` (variant, quantity, unit price,
  per-item start/end dates) and copies `snapshot_*` customer/address fields.
- `unit_price` is always read from `product_variants` — the `price` field in the
  client payload is ignored — and is immutable once written. This is the column
  the daily run sheet bills against.
- A subscription's daily cost = Σ(`unit_price × quantity`) over active items.
  `get_user_daily_commitment(user_id)` returns the total daily cost across **all**
  of a user's active subscriptions.

### The 3-day buffer rule

To stop a one-time purchase from starving upcoming daily deliveries, three days
of total daily commitment are reserved. **Enforced in the database** (and mirrored
in the UI for a friendlier message):

- **Creating a subscription:** require
  `wallet_balance ≥ (existing_daily_commitment + new_sub_daily_cost) × 3`.
- **Paying for a one-time order from the wallet:** require
  `wallet_balance ≥ (daily_commitment × 3) + order_total`.

Admin-placed orders skip the reserve deliberately, so ops can still fulfil edge
cases.

### Daily order generation (run sheet)

Each operational day, the admin panel's daily-ops module turns active
subscriptions into concrete deliveries by filtering through, in order:

1. **Active filter** — only `active` / `pending_cancellation` subscriptions.
2. **Cutoff rule** — subscriptions created after the area's cutoff time are
   skipped for the next day.
3. **Pauses** — dates in `subscription_pauses` produce no order.
4. **Modifications** — a one-time daily order (`subscription_daily_orders`)
   overrides the base subscription for that date.
5. **End date** — past `end_date` stops generation.
6. **Snapshot** — surviving orders are snapshotted (customer, address, products,
   prices) so history is immutable.

The full business logic, route grouping, and PDF export are documented in
[`Hetha_admin/docs/daily_ops.md`](../Hetha_admin/docs/daily_ops.md).

---

## 5. Payments (Razorpay) {#payments}

Payments are **verified server-side**, and — since 2026-07-28 — the **server also
decides the amount**. The Razorpay secret (`key_secret`) lives only in the
Supabase Edge Function environment, never in either client.

> **Why the amount matters.** The HMAC signature only proves that a given
> `<order_id>|<payment_id>` pair really came from Razorpay. It says nothing about
> how much was paid. The old flow trusted the client's `amount` field, so paying
> ₹1 and posting `amount: 100000` credited ₹1,00,000 — and the same signed triple
> could be replayed. See `CHANGES_2026-07-28.md`.

The single `razorpay` edge function exposes four actions:

| Action | Used by | Purpose |
|--------|---------|---------|
| `create-order` | App checkout & wallet recharge | Creates a **payment intent** with the server-computed amount, then a Razorpay order for exactly that amount. Requires `purpose` (`order` \| `wallet_topup`) |
| `verify-payment` | App wallet recharge | Signature + Razorpay `payments.fetch` + intent ownership → `finalize_wallet_topup` |
| `verify-order-payment` | App checkout | Same checks → `finalize_order_payment`, which places the order server-side |
| `payment-failed` | App | Marks an abandoned intent `failed` (housekeeping) |

**Checkout flow (Pay Online):**

```
App → create-order { purpose:'order', address_id, cart_items:[{variant_id,quantity}] }
       └─ server prices the cart (quote_cart) → payment_intents row + Razorpay order
App opens Razorpay sheet with the amount the SERVER returned
On success → App → verify-order-payment { intent_id, order_id, payment_id, signature }
                    ├─ HMAC-SHA256 signature check (length-safe compare)
                    ├─ razorpay.payments.fetch → real captured amount + status
                    ├─ intent belongs to the caller, matches this Razorpay order
                    └─ finalize_order_payment (idempotent per payment id)
                         ├─ refuses if captured < intent amount
                         └─ place_order_core → order row, payment_status 'paid'
```

Wallet recharge is the same shape via `verify-payment` → `finalize_wallet_topup`,
which credits **only what Razorpay says was captured**, capped at the intent
amount, once per `razorpay_payment_id`.

Nothing about pricing is taken from the request body: for orders the amount comes
from the catalog, and for top-ups the requested amount is range-checked
(₹1–₹50,000). `payment_intents` is service-role only (RLS on, no policies).

**Not yet covered:** there is no Razorpay **webhook**. If the app dies between
capture and verification, the money is captured with no order and the intent
stays `created`. The `finalize_*` RPCs are idempotent, so a `payment.captured`
webhook can call them directly — recommended before production.

> The project is on the Razorpay **test key** (`rzp_test_…`). Switch the edge
> function env to the live key before production. In test mode, use card
> `4111 1111 1111 1111` or UPI `success@razorpay` / `failure@razorpay`.

---

## 5b. Money integrity (what is trusted, and where) {#money-integrity}

Added 2026-07-28. The rule is: **clients send ids and quantities; the database
decides money.**

| Decision | Where it is made |
|----------|------------------|
| Item price | `product_variants.price`, re-read inside every RPC |
| Delivery charge | `internal.compute_delivery_charge()` from `delivery_charge_tiers` + variant weights. The client's `p_delivery_charge` is honoured **only** for admin callers (fee waivers) |
| Order total | `internal.place_order_core()`; enforced afterwards by deferred constraint triggers |
| Amount payable online | `payment_intents.amount_paise`, set server-side |
| Amount credited | Razorpay's `payments.fetch` response |
| Wallet balance | `internal.apply_wallet_delta()` only; `authenticated` has no UPDATE grant on the column |
| 3-day buffer | Enforced in `place_order` and `create_subscription` (was UI-only) |

Enforcement layers, outermost first:

1. **Privileged logic in a hidden schema.** `internal` is not in the project's
   exposed schemas, so nothing in it is reachable over PostgREST.
2. **In-function authorization.** Every money RPC checks `auth.uid()` against the
   target user, or requires an admin permission / the service role.
3. **Grants.** `anon` can execute only `quote_cart`, `has_permission`,
   `is_super_admin`. Payment-intent functions are service-role only.
4. **RLS.** Customers cannot write `orders`, `order_items` or
   `subscription_items` at all — those go through `SECURITY DEFINER` RPCs.
5. **Database invariants.** Deferred constraint triggers require
   `orders.subtotal = Σ order_items.total_price`,
   `orders.total = subtotal + delivery_charge`, and
   `subscription_daily_orders.total_value = Σ` its items — so even staff with
   `orders:edit` cannot hand-write a cheap order. `subscription_items.unit_price`
   is snapped to the catalog on insert and immutable after.
   Escape hatch for deliberate repair: `SET LOCAL hetha.skip_money_checks = 'on'`.

Deployed by `docs/db/migrations/007`–`012`; regression-tested by
[`docs/db/tests/verify_money_integrity.mjs`](./db/tests/verify_money_integrity.mjs),
which applies those migrations to an in-process Postgres (PGlite) and asserts 37
attack and happy-path cases. Run it after any change to a money path.

---

## 6. Order lifecycle

```
payment_pending → placed → processing → shipped → out_for_delivery → delivered
        │
        └────────────────────────── cancelled
```

- `payment_method`: `wallet` | `razorpay` | `wallet_razorpay` | `cod`.
- `payment_status`: `pending` | `paid` | `failed` | `refunded`.
- **Wallet / COD** orders are created `placed` (wallet also `paid`).
- **Online (razorpay)** orders created by a customer start as `payment_pending`
  and only become `placed` + `paid` once the edge function has verified the
  payment — so an unverified order never reaches the run sheet or packing list.
- The app drives placement (via RPC / edge function) and lets customers view
  orders, download PDF invoices, and review delivered items.
- The admin panel drives fulfillment: status transitions, tracking info
  (`order_tracking`), and daily-ops delivery confirmation.

---

## 7. Cross-cutting concerns

- **Scheduled automation (pg_cron).** Some state changes happen in the database
  on a timer, not from either client: `cancel-expired-subscriptions` runs daily
  at midnight IST (expires subscriptions past their `end_date`), and a daily
  wallet-deduction job charges the day's subscription deliveries. See
  [DATA_MODEL.md §11](./DATA_MODEL.md#11-scheduled-jobs-pg_cron). Keep these in
  mind before treating "a subscription cancelled overnight" as a client bug.
- **Ad-hoc customers.** Staff can create `is_adhoc` customers; the `claim_adhoc_user`
  RPC later merges them onto a real auth account (auto on sign-in, or via the
  admin "Convert to App User" flow). See
  [DATA_MODEL.md §12](./DATA_MODEL.md#12-ad-hoc-customers--account-claiming).
- **Timezone (IST).** Postgres stores timestamps without a tz marker but the
  values are UTC. Both clients must mark them UTC before converting to local
  (the Flutter app appends `Z`; the daily-ops service applies a `+05:30`
  offset). Getting this wrong shifts delivery dates by a day — see
  `CHANGES_2026-05-31.md` §16 and §9.5.
- **Snapshots over joins for history.** Orders/subscriptions copy display data
  into `snapshot_*` columns so a later price or address change never rewrites
  history.
- **Pagination & limits.** Supabase caps result sets at 1000 rows by default.
  Operational queries that can exceed it raise the limit explicitly (daily-ops
  uses `.limit(10000)`); list views use cursor pagination.
- **Input sanitization.** Admin search terms are sanitized
  (`lib/sanitize.ts`) before interpolation into PostgREST `.or()` filters to
  prevent filter injection.

---

## 8. Environments & secrets

| Secret | Where it lives | Notes |
|--------|----------------|-------|
| Supabase URL | both clients' env | Public |
| Supabase anon/publishable key | both clients' env | Public; RLS does the protecting |
| Supabase service role key | `Hetha_admin` server env only | Bypasses RLS — guard like a root password |
| Razorpay key id | edge function env (and client for the checkout SDK) | Public-ish |
| Razorpay key secret | **edge function env only** | Never in any client or the DB |

See each repo's README for the exact variable names and setup steps.
