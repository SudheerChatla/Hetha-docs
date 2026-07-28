# Data Model — Shared Supabase Backend

Both `Hetha_app` and `Hetha_admin` read and write the **same Supabase Postgres
database**. This document is the canonical, human-readable reference for that
schema. It is the contract between the two clients — change it whenever you run
a migration.

**Source of truth.** The canonical, machine-generated snapshot lives at
[`docs/db/schema.sql`](./db/schema.sql). This document is the human-readable view
of it. To re-sync after a backend change, follow
[`docs/db/REFRESH.md`](./db/REFRESH.md).

- **Tables / columns / constraints — last synced 2026-06-01** against the live
  database (Supabase → Copy as SQL). Verified accurate, including the
  `subscriptions.label` column and the misspelled `delivary_*` columns.
- **Functions/RPCs, RLS policies, triggers, and pg_cron jobs are NOT yet
  verified** against the live DB — the sections below reflect the repo SQL and
  the change logs. Pull and confirm them via `REFRESH.md` (the table export
  used for the sync above does not include them).

**Repo SQL mirrors** (should match `docs/db/`):

- `Hetha_app/doc-schema/schema.sql` — table definitions (mirror)
- `Hetha_app/doc-schema/migrations/` — applied migration scripts (audit trail)
- `Hetha_admin/docs/schema.sql` — admin-side table mirror

> **Conventions used below:** PK = primary key, FK = foreign key. All `id`
> columns are `uuid DEFAULT gen_random_uuid()` unless noted. Timestamps are
> `timestamp without time zone` storing UTC (see the timezone note in
> [ARCHITECTURE.md](./ARCHITECTURE.md#7-cross-cutting-concerns)).

---

## 1. Domain map

```
                         ┌────────────┐
                         │   users    │  (mirrors auth.users; wallet_balance)
                         └─────┬──────┘
        ┌──────────────┬───────┼───────────────┬──────────────────┐
        ▼              ▼       ▼               ▼                  ▼
  ┌──────────┐  ┌───────────┐ ┌────────────┐ ┌───────────────┐ ┌──────────────────┐
  │addresses │  │cart_items │ │   orders   │ │ subscriptions │ │wallet_transactions│
  └──────────┘  └─────┬─────┘ └─────┬──────┘ └───────┬───────┘ └──────────────────┘
                      │             │                │
                      ▼             ▼                ▼
              ┌──────────────┐ ┌───────────┐ ┌──────────────────┐
              │product_      │ │order_items│ │subscription_items│
              │  variants    │ └───────────┘ └──────────────────┘
              └──────┬───────┘                       │
                     ▼                                ▼
              ┌──────────┐                  ┌──────────────────────────┐
              │ products │                  │ subscription_daily_orders │
              └────┬─────┘                  │  + _daily_order_items     │
                   ▼                        │  + subscription_pauses    │
              ┌──────────┐                  └──────────────────────────┘
              │categories│
              └──────────┘

  Delivery geography:  delivery_areas → delivery_routes, pincodes,
                       delivery_schedule_exceptions, delivery_charge_tiers
  Admin/RBAC:          roles → admin_users → admin_role_permissions,
                       admin_permissions, audit_logs
```

---

## 2. Identity & customers

### `users`
The application-level customer profile (the Supabase `auth.users` row is the
authentication identity; this is the business profile).

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid PK | matches the auth user id |
| `email` / `phone` | text UNIQUE | |
| `first_name`, `last_name` | text | |
| `area`, `pincode` | text | last-known location hint |
| `wallet_balance` | numeric | `CHECK (>= 0)` — prepaid funds |
| `notifications_enabled`, `dark_mode` | boolean | preferences |
| `language` | text | default `'en'` |
| `is_adhoc` | boolean | true for staff-created ad-hoc customers |
| `created_at`, `updated_at` | timestamp | |

### `addresses`
| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid PK | |
| `user_id` | uuid FK → users | |
| `name`, `phone_number` | text | recipient |
| `address_line1` … `pincode` | text | `address_type` ∈ Home/Work/Family/Other |
| `is_default` | boolean | |
| `is_deleted` | boolean | soft delete |

---

## 3. Catalog

### `categories`
`id`, `name`, `image_url`, `display_order`, `is_active`.

### `products`
| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid PK | |
| `category_id` | uuid FK → categories | |
| `name`, `description`, `hsn_code` | text | `hsn_code` for tax/invoice |
| `in_stock`, `is_bestseller`, `is_local` | boolean | merchandising flags |
| `is_default_sub`, `is_additional_sub` | boolean | subscription eligibility |

### `product_variants`
The sellable unit (a product has one or more variants).

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid PK | |
| `product_id` | uuid FK → products | |
| `label` | text | e.g. "500 ml", "1 kg" |
| `price` | numeric | |
| `weight_grams` | numeric | drives weight-based delivery charge |
| `is_preferred` | boolean | default-selected variant |
| `is_active` | boolean | |
| `free_delivery` | boolean NOT NULL | when true, variant is excluded from weight-based delivery charge calculation |

### `product_images`
`id`, `product_id` FK, `image_url`, `display_order`. Images live here, **not** on
`products` — join and sort by `display_order` to get the primary image.

---

## 4. Cart & orders

### `cart_items`
`id`, `user_id` FK, `variant_id` FK, `quantity` (`CHECK > 0`), `added_at`.

### `orders`
One-time purchases (distinct from subscription daily orders).

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid PK | |
| `order_number` | text UNIQUE | human-facing |
| `user_id` | uuid FK → users | |
| `address_snapshot_id` | uuid FK → addresses | |
| `status` | text | `payment_pending`, `placed`, `processing`, `shipped`, `out_for_delivery`, `delivered`, `cancelled` |
| `payment_method` | text | `wallet`, `razorpay`, `wallet_razorpay`, `cod` |
| `payment_status` | text | `pending`, `paid`, `failed`, `refunded` |
| `subtotal`, `delivery_charge`, `total` | numeric | |
| `wallet_amount_used`, `razorpay_amount` | numeric | split-payment breakdown |
| `razorpay_order_id`, `razorpay_payment_id` | text | |
| `payment_pending_expires_at` | timestamp | hold expiry |
| `snapshot_*` | text | name/phone/address copied at order time |
| `cancellation_reason`, `cancelled_by`, `cancelled_at` | | |
| `placed_at`, `updated_at`, `expected_delivery_date`, `delivery_time_slot` | | |

### `order_items`
`order_id` FK, `variant_id` FK, `product_name_snapshot`,
`variant_label_snapshot`, `unit_price`, `quantity` (`CHECK > 0`), `total_price`.

### `order_tracking`
Per-order shipping/tracking trail: `status`, `courier_service`, `awb_number`,
`lr_number`, `tracking_url`, `customer_message`, `updated_by`, `updated_at`.

### `payment_attempts`
Audit of payment tries per order: `attempt_number`, `razorpay_order_id`,
`razorpay_payment_id`, `total_amount`, `wallet_amount`, `razorpay_amount`,
`status` (`initiated`/`success`/`failed`/`expired`), `failure_reason`.

---

## 5. Subscriptions (the core domain)

### `subscriptions`
| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid PK | |
| `user_id` | uuid FK → users | |
| `address_id` | uuid | |
| `route_id` | uuid FK → delivery_routes | |
| `status` | text | `active`, `paused`, `cancelled`, `pending_cancellation` |
| `label` | text | user-given name ("Home", "Parents") |
| `start_date`, `end_date` | date | |
| `is_custom_cancel_date`, `cancellation_type`, `cancellation_reason`, `cancelled_at` | | |
| `payment_method` | text | `wallet` (default) or `cod` |
| `snapshot_*` | text | name/phone/address copied at creation |
| `delivary_frequency` | bigint | **(sic)** every N days |
| `delivary_area` | text | **(sic)** — preserved misspelling; both clients depend on it |
| `version`, `created_at`, `last_modified_at` | | optimistic-concurrency / audit |

### `subscription_items`
The recurring line items.

`subscription_id` FK, `variant_id` FK, `product_name_snapshot`,
`variant_label_snapshot`, `unit_price`, `quantity` (`CHECK > 0`),
`item_start_date`, `item_end_date`, `is_active`.

> Daily cost of a subscription = Σ(`unit_price × quantity`) over active items.

### `subscription_pauses`
`subscription_id` FK, `pause_start_date`, `pause_end_date`, `reason`,
`created_by` (`user`/`admin`). Dates in a pause window produce no daily order.

### `subscription_daily_orders`
A concrete delivery generated for one subscription on one date (the run-sheet
output, and the override mechanism for one-time modifications).

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid PK | |
| `delivery_date` | date | |
| `subscription_id`, `user_id` | uuid FK | |
| `status` | text | `pending`, `skipped`, `delivered`, `cancelled` |
| `total_value` | numeric | |
| `payment_status` | text | `pending`, `paid`, `refunded` |
| `wallet_deducted_at` | timestamp | when the daily wallet charge ran |
| `is_finalized`, `finalized_at`, `finalized_by` | | locks the day's order |
| `tracking_info`, `custom_route` | text | day-specific overrides |

### `subscription_daily_order_items`
Line items for a daily order, including `is_adhoc_addition` (one-time extras) and
`delivered_qty` (requested vs actually delivered).

---

## 6. Delivery geography & pricing

### `delivery_areas`
Serviceable areas and their operating rules.

| Column | Type | Notes |
|--------|------|-------|
| `display_name` | text UNIQUE | |
| `is_active` | boolean | |
| `support_email`, `support_phone`, `support_hours` | | |
| `advance_order_days`, `max_order_days` | integer | ordering window |
| `order_cutoff_time`, `cancellation_cutoff_time` | time | drives run-sheet cutoff |
| `delivary_frequency` | bigint | **(sic)** delivery cadence |
| `reference_date` | date | anchor for frequency math |
| `version`, `created_at`, `updated_at` | | |

### `delivery_routes`
`area_id` FK, `route_name` (UNIQUE), `is_active`.

### `pincodes`
`area_id` FK, `pincode` (UNIQUE), `cod_eligible`. Maps a customer pincode to an
area and whether COD is allowed there.

### `delivery_schedule_exceptions`
`area_id` FK, `reference_date`, `exception_type`, `note` — holidays / off-days
that perturb the normal cadence.

### `delivery_charge_tiers`
Weight-based shipping price: `min_weight_grams`, `max_weight_grams`, `charge`
(`CHECK >= 0`). Order weight (Σ variant `weight_grams` for non-`free_delivery`
items) selects a tier. Variants with `free_delivery = true` are excluded from
the weight sum; if all cart items are free-delivery, the charge is ₹0.

---

## 7. Wallet & reviews & notifications

### `wallet_transactions`
Append-only ledger. `type` (`credit`/`debit`), `amount` (`CHECK > 0`),
`balance_after`, `description`, `reference_type`, `reference_id`, `initiated_by`.
Always written alongside a wallet change — `users.wallet_balance` is only
writable by `internal.apply_wallet_delta()`, which writes both in one
transaction. `authenticated` has **no** UPDATE grant on that column.

### `payment_intents`
Server-side record of "this user must pay this much" — created before Razorpay
checkout opens and consumed once, atomically, after the payment is verified.

`user_id` FK, `purpose` (`wallet_topup`/`order`), `status`
(`created`/`paid`/`failed`/`expired`), `amount_paise` (**computed by the
server**), `razorpay_order_id` UNIQUE, `razorpay_payment_id` UNIQUE,
`address_id`, `cart_items` jsonb, `order_id`, `amount_paid_paise`,
`expires_at`, `consumed_at`.

RLS is enabled with **no policies** and all grants are revoked from
`anon`/`authenticated`: only the razorpay edge function (service role) touches
it. `orders.razorpay_payment_id` also carries a partial UNIQUE index, so one
Razorpay payment can back at most one order.

### `reviews`
`user_id`, `product_id`, `variant_id`, `order_id` FKs; `rating`
(`CHECK 1..5`), `description`. Tied to a delivered order.

### `notifications`
`user_id` FK, `type` (`push`/`sms`/`whatsapp`), `template_key`, `title`, `body`,
`data` (jsonb, optional route/payload for in-app navigation),
`reference_type`, `reference_id`, `status` (`pending`/`sent`/`failed`),
`read_at` (timestamptz, null = unread — used for in-app notification inbox),
`sent_at`.

The Flutter app displays these as an in-app notification inbox (bell icon on
home page). `read_at` is bulk-set when the user opens the notifications screen.
The `send-notification` Edge Function + admin `notificationService.ts` write to
this table alongside sending the FCM push.

### `device_tokens`

`user_id` FK, `fcm_token` (text, the Firebase Cloud Messaging device token),
`platform` (`android`/`ios`), `created_at`, `updated_at`.
UNIQUE on `(user_id, fcm_token)` — one user can have multiple devices.

The Flutter app registers the token on every app start (upsert). Token is
deleted on sign-out. The `send-notification` Edge Function looks up tokens
here and auto-cleans stale/unregistered ones when FCM returns errors.

---

## 8. Admin & RBAC

| Table | Purpose |
|-------|---------|
| `roles` | named roles (`role` UNIQUE) |
| `admin_users` | links an `auth.users` id to a role; `admin_name`, `email`, `is_active` |
| `admin_role_permissions` | permission strings granted to a role |
| `admin_permissions` | per-admin permission grants (`permission_key`, `granted_by`) |
| `audit_logs` | `action`, `table_name`, `record_id`, `old_values`/`new_values` jsonb, `ip_address` |

Permission keys are `resource:action` (`orders:view`, `subscriptions:edit`, …);
the page-level catalog lives in `Hetha_admin/lib/constants.ts`. `super_admin`
implies all permissions. See
[`Hetha_admin/docs/ARCHITECTURE.md`](../Hetha_admin/docs/ARCHITECTURE.md) for how
this is enforced.

---

## 9. Database functions (RPCs)

Trusted business logic runs in Postgres, not the clients. **Verified against the
live database 2026-06-01** — full source in [`docs/db/functions.sql`](./db/functions.sql).

| RPC | Called by | What it does |
|-----|-----------|--------------|
| `quote_cart(p_cart_items)` | App (display) | `SECURITY DEFINER STABLE`. Returns `{subtotal, delivery_charge, total}` computed from `product_variants` + `delivery_charge_tiers`. The client shows this; it never supplies pricing. |
| `place_order(p_user_id, p_address_id, p_payment_method, p_delivery_charge, p_cart_items)` | App (wallet/cod), admin (ad-hoc), edge fn (razorpay) | `SECURITY DEFINER`. Only ids + quantities are trusted: prices come from `product_variants`, the **delivery charge is recomputed server-side** (`p_delivery_charge` is honoured only for admin callers, as a fee waiver), quantities must be whole numbers 1–99, and inactive/out-of-stock variants are rejected. Requires `p_user_id = auth.uid()` unless the caller is an admin with `orders:edit`/service role. Wallet payments additionally reserve **3 × daily subscription commitment**. Customer-initiated `razorpay` orders are created as `status='payment_pending'` until a verified payment arrives. **Order number = `ORD-<YYYYMMDDHH24MISS>-<nnnn>`**, **RETURNS the order UUID** (as text). |
| `create_subscription(…, p_label)` **(7-arg, current)** | App, admin | Enforces **max 5 active/pending per user**, sets `label` (defaults to `Subscription N`), derives `delivary_area`/`delivary_frequency` from the address pincode, and takes `unit_price` from `product_variants` — the `price` field in the payload is ignored. Enforces the **3-day wallet buffer** for customer callers. Does **not** cancel existing subs. |
| `create_subscription(…)` **(6-arg, legacy)** | Admin ad-hoc only | Older overload still deployed: **cancels the user's active subscription** (`cancellation_type='replaced'`), no label. Same server-side pricing as the 7-arg version. Prefer the 7-arg version in the app. |
| `get_user_daily_commitment(p_user_id)` | App, `place_order`, `create_subscription` | Σ daily cost across active/pending subs (drives the 3-day buffer rule, now enforced in the DB as well as the UI). |
| `update_wallet_balance(p_user_id, p_amount, p_type, p_description, p_initiated_by, [p_reference_type, p_reference_id])` | Admin, edge fns | `SECURITY DEFINER`. Thin authorization wrapper (`service_role`, `super_admin`, or `customers:edit`) around `internal.apply_wallet_delta`. Customer JWTs are rejected. The 5-arg overload was dropped — the defaults cover those callers. |
| `create_payment_intent` / `attach_razorpay_order` / `finalize_wallet_topup` / `finalize_order_payment` / `mark_payment_intent_failed` | razorpay edge fn (service role only) | Payment lifecycle. The intent stores the amount the server decided; settlement compares it against the amount Razorpay says was captured and is idempotent per `razorpay_payment_id`. |
| `finalize_daily_run(p_delivery_date, p_admin_id)` | Admin (daily ops) | `SECURITY DEFINER`. Locks the day's orders and debits wallets. Requires `daily_ops:edit` (or super admin / service role). |
| `update_address_as_default(p_user_id, p_address_id, p_address_data)` | App | Clears other defaults, updates + sets the target default. Fixed in migration 011: writes `phone_number` (accepts `phone` or `phone_number` in the payload), no longer writes a non-existent `updated_at`, and raises unless the address belongs to the caller. |
| `upsert_pauses(p_subscription_id, p_ranges)` / `remove_paused_dates(p_subscription_id, p_dates)` | App | Atomically merge/split subscription pause ranges. |
| `claim_adhoc_user(p_auth_uid, …)` | App (sign-in), admin (convert) | `SECURITY DEFINER`. Merges an `is_adhoc` row onto a real auth account (returning/claim/collision/insert branches); child rows follow via `ON UPDATE CASCADE`. |
| `cancel_subscription(p_subscription_id, p_user_id, p_end_date, p_is_immediate, p_cancellation_type, p_reason)` | App | Immediate → `status='cancelled'`; scheduled → `status='pending_cancellation'`. **⚠ see known issues.** |
| `has_permission(p text)` | **RLS policies** | `SECURITY DEFINER STABLE`. True if the current `auth.uid()` admin has permission `p` (via `admin_role_permissions`). |
| `is_super_admin()` | **RLS policies** | `SECURITY DEFINER STABLE`. True if the current admin's role is `super_admin`. |
| `get_user_role(uid)` | — (appears unused) | Returns an admin's role. **⚠ see known issues.** |
| `rls_auto_enable()` | event trigger | Auto-runs `ENABLE ROW LEVEL SECURITY` on every new `public` table created (why all tables have RLS on). |

> Historical note: an older 4-param `place_order` and a
> `verify_razorpay_recharge` RPC (which had the Razorpay secret hard-coded) were
> **dropped** — confirmed absent from the live DB. All payment verification
> happens in the edge function. Don't reintroduce secrets into the database.

### ⚠ Known latent issues (functions vs current schema, found 2026-06-01)

These deployed functions reference columns that **do not exist** in the current
schema, so the affected path errors at runtime. Decide whether to fix the
function or add the column:

1. **`cancel_subscription`** (scheduled / non-immediate branch) writes
   `scheduled_end_date` and `cancellation_requested_at` — not columns on
   `subscriptions`. Immediate cancellation works; scheduled cancellation fails.
2. **`update_address_as_default`** writes `addresses.phone` (the column is
   `phone_number`) and `addresses.updated_at` (no such column). The Flutter
   app's non-atomic fallback may be hiding this failure.
3. **`get_user_role`** selects `admin_users.auth_user_id` (the column is
   `user_id`); the function errors. It appears unused — `has_permission` /
   `is_super_admin` are the live RBAC helpers and use `user_id` correctly.

### A note on order numbers

Some code comments and older change logs say order numbers are `HET-…`. **The
deployed `place_order` produces `ORD-…`.** Treat `ORD-` as authoritative; the
`HET-` references (e.g. in `orderService.ts` comments) are stale.

---

## 10. Edge functions

`supabase/functions/razorpay` (Deno) — single function, three actions:

| Action | Purpose |
|--------|---------|
| `create-order` | Create a Razorpay order for an amount |
| `verify-payment` | Verify HMAC-SHA256 signature → credit wallet via `update_wallet_balance` |
| `verify-order-payment` | Verify signature → call `place_order` server-side (`payment_method: 'razorpay'`) |

The secret `key_secret` is read from the edge environment only.
*(Not yet re-verified against the deployed function — see `docs/db/REFRESH.md`.)*

---

## 11. Row-Level Security

**Verified 2026-06-01.** RLS is **enabled on all 29 public tables**; new tables
get it automatically via the `rls_auto_enable` event trigger. Full policy DDL is
in [`docs/db/policies.sql`](./db/policies.sql).

**Access model (the pattern almost every table follows):**

- **Customers** reach their own rows via an ownership check — `auth.uid() = user_id`,
  or an `EXISTS` join to a parent row they own (e.g. `order_items` → `orders`).
- **Admins** are gated by `is_super_admin() OR has_permission('<resource>:<action>')`.
- **Catalog tables** (`categories`, `products`, `product_variants`,
  `product_images`, `delivery_areas`, `delivery_charge_tiers`, `delivery_routes`,
  `pincodes`) and **`reviews`** are **world-readable** via a `SELECT USING (true)`
  policy — fine for a storefront.
- Policies are **permissive** (they combine with `OR`); many tables carry both a
  legacy `"Users can …"` owner policy and a newer `"<table>_*_policy"` RBAC
  policy.

### ⚠ RLS findings (worth fixing)

1. **Permission-key drift on `delivery_areas`.** Its write/extra-view policies
   check `has_permission('pincode:edit'/'pincode:view')` — **singular** — while
   `lib/constants.ts` and the `pincodes` table use **`pincodes:*`** (plural).
   Non-super-admins are likely never granted the singular key, so in practice
   **only `super_admin` can modify delivery areas**.
2. **Orphan `audit_logs` permissions.** Policies reference
   `audit_logs:create` / `audit_logs:view`, which aren't in the
   `PAGE_PERMISSIONS` catalog — so only `super_admin` can read/write audit logs.
3. **Redundant dual policies** (legacy owner + new RBAC) on many tables are
   harmless but candidates for cleanup.
4. **`notifications`** has only a `SELECT` (own) policy — no `INSERT` policy, so
   rows are written only via `service_role` / `SECURITY DEFINER` paths.

---

## 12. Triggers & indexes

- **Triggers:** **none** on any `public` table (verified 2026-06-01). Order
  numbers (`ORD-…`) and `updated_at` are set **inline by functions/inserts**, not
  by triggers — so a table's `updated_at` only changes when a function explicitly
  writes it (e.g. `update_wallet_balance` sets `users.updated_at`). The
  `rls_auto_enable` **event trigger** exists at the database level (it isn't a
  table trigger, so it doesn't appear in `information_schema.triggers`).
- **Indexes:** captured in [`docs/db/indexes.sql`](./db/indexes.sql) — FKs,
  status/date filter columns, and several partial indexes
  (`idx_orders_pending_expires`, `idx_products_in_stock`, `idx_users_is_adhoc`,
  `idx_sub_items_active`, `idx_notif_status`). Unique business keys:
  `uq_cart_user_variant`, `uq_sdo_subscription_date`,
  `uq_review_user_order_product`, `uq_admin_permission`.

---

## 13. Scheduled jobs (pg_cron)

Verified 2026-06-01 — **exactly one** job is deployed:

| Job | Schedule | What it does |
|-----|----------|--------------|
| `cancel-expired-subscriptions` | `30 18 * * *` (18:30 UTC = 00:00 IST), active | `UPDATE subscriptions SET status='cancelled', cancellation_type='expired' WHERE status='active' AND end_date IS NOT NULL AND end_date < CURRENT_DATE` |

> ⚠ The **wallet daily-deduction job is NOT scheduled.** A `wallet_deduction_cron.sql`
> file existed in the repo but has been deleted as the job was never deployed to pg_cron.
> Today, the daily wallet charge for subscription deliveries must therefore be happening through
> the admin daily-ops finalize path (which stamps
> `subscription_daily_orders.wallet_deducted_at`) or is simply not running yet —
> confirm before relying on it.

---

## 14. Ad-hoc customers & account claiming

Staff can create **ad-hoc** customers (`users.is_adhoc = true`) for walk-in or
phone orders before the customer installs the app. Later the records are merged
onto a real account:

- **Auto-claim:** when a customer signs in, the app calls `claim_adhoc_user`,
  which matches an ad-hoc row by email/phone and reassigns its id to the auth
  user. All child rows (addresses, orders, subscriptions, wallet, …) follow via
  `ON UPDATE CASCADE` FKs to `users(id)`.
- **Admin convert:** the admin panel's "Convert to App User" flow uses the
  **service-role** client to `auth.admin.createUser`, then runs
  `claim_adhoc_user` (rolling back the auth user if the claim fails).

---

## 15. Changing the schema

Because two clients depend on this schema:

1. Write the migration SQL and keep `doc-schema/` (app) and `docs/` (admin)
   mirrors in sync.
2. Update this document and the relevant TypeScript types
   (`Hetha_admin/lib/types.ts`) and Dart models (`Hetha_app/lib/models/`).
3. Check both clients for the changed table/column **before** deploying — a
   column rename can silently break one client.
4. Record the change in the dated `CHANGES_*.md` log.
