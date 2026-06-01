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
- All balance changes go through the `update_wallet_balance` RPC, which locks the
  row (`SELECT … FOR UPDATE`) to prevent race conditions, and every change is
  recorded in `wallet_transactions` with a `balance_after` snapshot.

### Subscriptions

- Created via the `create_subscription` RPC. Limits a user to **5 active
  subscriptions** and accepts an optional `label`.
- Each subscription has `subscription_items` (variant, quantity, unit price,
  per-item start/end dates) and copies `snapshot_*` customer/address fields.
- A subscription's daily cost = Σ(`unit_price × quantity`) over active items.
  `get_user_daily_commitment(user_id)` returns the total daily cost across **all**
  of a user's active subscriptions.

### The 3-day buffer rule

To stop a one-time purchase from starving upcoming daily deliveries, the app
reserves three days of total daily commitment:

- **Creating a subscription:** require
  `wallet_balance ≥ (existing_daily_commitment + new_sub_daily_cost) × 3`.
- **Paying for a one-time order from the wallet:** the wallet is only selectable
  if `wallet_balance ≥ (daily_commitment × 3) + order_total`.

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

Payments are **verified server-side** so a tampered client cannot fake success.
The Razorpay secret (`key_secret`) lives only in the Supabase Edge Function
environment — never in either client.

The single `razorpay` edge function exposes three actions:

| Action | Used by | Purpose |
|--------|---------|---------|
| `create-order` | App checkout & wallet recharge | Creates a Razorpay order for a given amount |
| `verify-payment` | App wallet recharge | Verifies HMAC-SHA256 signature, then credits the wallet atomically via `update_wallet_balance` |
| `verify-order-payment` | App checkout | Verifies the signature, then calls `place_order` **server-side** with `payment_method: 'razorpay'` |

**Checkout flow (Pay Online):**

```
App → create-order → Razorpay order id
App opens Razorpay sheet (UPI/card/netbanking)
On success → App → verify-order-payment
                    ├─ verify signature (HMAC-SHA256, secret from edge env)
                    └─ if valid → place_order RPC (server-side) → order row
```

Wallet recharge follows the same shape with `verify-payment`. Both credit/charge
through row-locked RPCs, so the wallet stays consistent under concurrency.

> The project is on the Razorpay **test key** (`rzp_test_…`). Switch the edge
> function env to the live key before production. In test mode, use card
> `4111 1111 1111 1111` or UPI `success@razorpay` / `failure@razorpay`.

---

## 6. Order lifecycle

```
payment_pending → placed → processing → shipped → out_for_delivery → delivered
        │
        └────────────────────────── cancelled
```

- `payment_method`: `wallet` | `razorpay` | `wallet_razorpay` | `cod`.
- `payment_status`: `pending` | `paid` | `failed` | `refunded`.
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
