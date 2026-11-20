# Hetha — Master Implementation Plan

Written 2026-11-13, revised 2026-11-13 with the owner's confirmed decisions
(D-1 … D-9). This file is the single source of truth for all remaining Hetha
development work across the customer app (`Hetha_app`), the admin panel
(`Hetha_admin`) and the database (`Hetha/docs/db`).

It is written so that a small coding model can execute one task at a time
without making architectural decisions. Every product decision is already
made in [§2](#2-confirmed-product-decisions); do not reopen them.

**Read first:** `CLAUDE.md` (repo layout, commands, database workflow, money
integrity), `CHANGES_2026-11-11.md`, `CHANGES_2026-11-13.md`.

---

## 0. Starting state

Three kinds of work are distinguished throughout this file:

- **DONE** — committed and (where it applies) live.
- **WRITTEN, AWAITING APPROVAL** — exists on the owner's machine, uncommitted,
  not applied on live. Not to be treated as live.
- **PENDING** — every numbered task in Parts A0–E. None is started.
- **OWNER-ONLY** — manual steps in Part F.

| Item | State on 2026-11-13 |
|---|---|
| Migration 036 (subscription cut-off rule) | **DONE.** Applied and verified on live. Admin `d4bafd0` deployed. |
| App changes for 036 (`24dc71d`) | Committed and pushed. **Not released to phones.** |
| Migration 037 (daily-order settlement, "Phase 1") | **DONE.** Approved, committed, applied on live (2026-11-15). |
| Admin code for 037 | Committed (`Hetha_admin` `9864f09`), pushed 2026-11-15. |
| Migration 038 + Part A0/A admin code | **DONE.** 038 applied on live 2026-11-15; admin pushed. |
| Migrations 038, 039, 040 and every task in this plan | **PENDING.** |

**Dependency:** every task below assumes migration 037 is applied. Do not
start Part A0 or Part A until the owner has approved and committed Phase 1.

---

## 1. Rules for every task

These are not optional. A task is not done until all of them hold.

1. **One task per commit.** Do not mix tasks. Do not refactor code a task does
   not name.
2. **Never push, deploy, or apply a migration.** The owner pastes migrations
   into the Supabase SQL Editor by hand. Pushing `Hetha_admin` `main` deploys
   it to production. Stop after committing locally unless told to push.
3. **Staging first (D-6).** Once the staging project exists (O-04), every
   migration and every admin/app change is applied and tried in staging
   before production. Until it exists, say so in the change log.
   **Owner decision 2026-11-15:** staging is deferred to a later phase; build
   now and apply migrations to production after the DB suite passes. O-04
   must still be done before real customers are onboarded.
4. **Three git repos.** `Hetha/` (docs + SQL), `Hetha_admin/`, `Hetha_app/`
   are separate repositories. Run git commands inside the right one.
5. **Database changes:**
   - One file `docs/db/migrations/NNN_name.sql`, wrapped in `BEGIN; … COMMIT;`,
     with a header comment (Problem, Fix, Rollout order) and a Verification
     section of commented queries after `COMMIT;`. Copy the layout of
     `037_daily_order_settlement.sql`.
   - Must be safe to run twice (`CREATE OR REPLACE`, `IF NOT EXISTS`,
     `DROP TRIGGER IF EXISTS`, `ON CONFLICT DO NOTHING` for seed rows).
   - Every new function: `SECURITY DEFINER`, `SET search_path TO 'public', 'internal'`.
     Public functions: `REVOKE ALL … FROM PUBLIC, anon;` then
     `GRANT EXECUTE … TO authenticated, service_role;`. Internal functions:
     `REVOKE ALL … FROM PUBLIC, anon, authenticated;`.
   - Every new table: `ALTER TABLE … ENABLE ROW LEVEL SECURITY;` and no policy
     unless the task gives one (access goes through functions).
   - Add the filename to the migration list in
     `docs/db/tests/verify_money_integrity.mjs` (search for
     `'037_daily_order_settlement.sql']`) and add a numbered test section at
     the end of that file, before the final `console.log` summary line.
   - Update `docs/DATA_MODEL.md`. If a table shape changed, also update
     `docs/db/schema.sql`, `Hetha_admin/docs/schema.sql`,
     `Hetha_app/doc-schema/schema.sql`, `Hetha_admin/lib/types.ts` and
     `Hetha_app/lib/models/`.
6. **Money rule.** Clients send variant ids and quantities; the database
   decides money. Never trust a price, total, wallet amount or payment status
   sent by a client. Wallet balance changes only through
   `internal.apply_wallet_delta`. Daily-order money moves only through
   `internal.settle_daily_order`. The wallet reserve comes only from
   `internal.wallet_reserve` (W-01). Never write a reserve multiplier in
   application code or in any other SQL function.
7. **Dates.** Business dates are India calendar days.
   - SQL: use `internal.today_ist()`, never `CURRENT_DATE`.
   - TypeScript: use `todayInIndia()` from `Hetha_admin/lib/deliverySchedule.ts`,
     never `new Date().toISOString().split('T')[0]`. Compare `date` columns as
     `YYYY-MM-DD` strings (`toYmd`, `isWithinDays` in the same file). Never
     wrap a `date` column in `new Date(...)` to compare it.
8. **Gates before calling a task done:**
   - DB: `cd docs/db/tests && npm run verify` → `0 failed`.
     (`npm run verify:018` has 2 known failures until task B-01.)
   - Admin: `cd Hetha_admin && npx tsc --noEmit && npm run lint && npm run build`.
     If `tsc` fails inside `.next/dev/types/`, delete
     `.next/dev/types/routes.d.ts` and `validator.ts` (generated files) and re-run.
   - App: `cd Hetha_app && flutter analyze` (one known hint at
     `product_details_page.dart:620`) and `flutter test` (all pass).
9. **Admin panel is Next.js 16** with breaking changes. Before using a
   framework API (caching, route handlers, `after`, `dynamic`, `maxDuration`),
   read the matching guide in `Hetha_admin/node_modules/next/dist/docs/`.
10. **Line numbers in this plan are approximate.** Locate code by the quoted
    text or function name. If the quoted text is not found, stop and report;
    do not guess.
11. **Log the work** in a dated `CHANGES_YYYY-MM-DD.md` at the root of
    `Hetha/`, in the format of `CHANGES_2026-11-13.md`.
12. **Shell note (Windows / Git Bash).** Multi-line scripts that contain
    backticks or `\n` inside heredocs get mangled. Write the script to a file
    and run the file.

---

## 2. Confirmed product decisions

All nine are **CONFIRMED by the owner on 2026-11-13**. They are requirements,
not questions. If a task elsewhere in this file appears to conflict with one,
the decision here wins; report the conflict.

| ID | Decision | Status | Implemented by |
|---|---|---|---|
| D-1 | **Wallet reserve = 1 upcoming delivery per active subscription.** When a customer creates a subscription, buys with the wallet, or increases a day's order, the wallet check considers one upcoming delivery of each active subscription and nothing more. One central database function produces the reserve. The earlier multi-delivery requirement is removed everywhere. | CONFIRMED | W-01, W-04, W-05, A-18 |
| D-2 | **Bulk "Mark Delivered" stays.** When staff use it, the selected orders are treated as fully delivered; no quantities need to be typed. Recording an individual delivery still takes the actual delivered quantity per item. | CONFIRMED | Phase 1 (`set_daily_order_status`); protected by P2-05; restated in P1-01 |
| D-3 | **Low-balance notices are MANUAL ONLY** (revised by the owner on 2026-11-16; the earlier automatic evening reminder is withdrawn). Nothing sends a low-balance push automatically: no scheduler, no cron job, no `CRON_SECRET`, no notice after Finalize. After Generate, Daily Ops lists every customer whose wallet cannot cover their orders on the selected date (wallet, required, shortfall); all not-yet-notified customers are selected; staff can deselect; Send pushes only to the selected ones and shows sent / failed counts. A customer is notified at most once per delivery date ("Already notified"). The wallet forecast stays. Automatic reminders may be requested later as a separate task. | CONFIRMED (revised) | W-07M |
| D-4 | **Customers cannot add items to an existing subscription from the app.** Out of scope for this plan. | CONFIRMED | No task. Do not build it. |
| D-5 | **Do not raise the Supabase Data API "Max rows" (1000).** Page every read that needs all rows. | CONFIRMED | P2-09; O-05 note |
| D-6 | **Separate staging Supabase project plus a Vercel preview pointing at it.** Migrations and app changes are tested there before production. Must be complete before onboarding real customers. | CONFIRMED | O-04; rule §1.3 |
| D-7 | **Reconciliation requires actual delivered quantities.** A blank delivered quantity is never treated as delivered. Reconcile is blocked until staff enter a quantity for every item of every pending order, with a clear message naming what is missing. Zero is a valid quantity. Only then does reconcile settle the wallet. | CONFIRMED | Phase 1 (`reconcile_daily_run`); P1-01 |
| D-8 | **Cancelled orders are hidden on the Deliveries page** but stay in Reconciliation and in history. Their financial and audit records are never deleted. Totals and reports never count a cancelled order as delivered. | CONFIRMED | Phase 1 (`getDeliveries`, `isGoingOut`); P1-02; A-08 |
| D-9 | **Historical unpaid deliveries stay on settlement hold.** Deliveries that went out under the old system with a failed wallet debit are never charged or retried automatically. They remain visible for manual review by an authorized person. A hold is released, and any amount collected, only by a deliberate manual step. The hold reason and the wallet audit trail are preserved. | CONFIRMED | Phase 1 (037 backfill, `settle_daily_order`); P1-03; A-17; O-08 |

### 2.1 Assumptions made while applying the decisions

These follow from the decisions and the existing system. They are not open
questions; they are recorded so the owner can overrule one if wanted.

| ID | Assumption | Why |
|---|---|---|
| S-5 | The manual list counts only wallet subscriptions' pending orders on the selected date that are not on payment hold (cash on delivery, skipped, cancelled, delivered and already-paid orders need nothing). A push that failed may be sent again. | These are exactly the orders Finalize will try to charge. |

---

## 3. Order of work and migration dependencies

```
Phase 1  migration 037 — settlement integrity          ← WRITTEN, AWAITING APPROVAL (owner: O-01)
   │
   ▼
Part A0  P1-01 → P1-02 → P1-03                         Phase 1 follow-ups (admin only, no migration)
   │
   ▼
Part A   P2-01 → P2-02 → P2-03 → P2-04 → P2-05 → P2-06 → P2-07 → P2-08 → P2-09 → P2-10
   │        migration 038 — Daily Ops structure (also holds get_earliest_change_date for M-01)
   ▼
Part B   W-01 → W-02 → W-03 → W-04 → W-05 → W-06 → W-07M (manual low-balance notices)
   │        migration 039 — wallet simplification + configurable reminder
   ▼
Part C   A-01 … A-18      independent of each other unless stated; A-06 is migration 040 (indexes)
Part D   M-01 … M-06      M-01 needs 038; M-04 needs 039
Part E   B-01 … B-03
Part F   O-01 … O-08      owner-only
```

| Migration | Content | Depends on |
|---|---|---|
| 037 | Phase 1: `paid_amount`, `settle_daily_order`, finalize / record delivery / status / retry / unlock / reconcile, settlement holds | 036 |
| 038 | Phase 2: `subscription_delivers_on`, `generate_daily_run`, item functions, finalized-day lock, `get_earliest_change_date` | 037 |
| 039 | Wallet: `wallet_reserve`, `wallet_forecast`, manual low-balance list and send, notice log | 038 (uses `subscription_delivers_on`) |
| 040 | Indexes only | none (can be applied any time after 037) |

Each of Part A and Part B ships as **one migration**. Build the SQL tasks of
a part into the same migration file, in task order.

Staging (O-04, D-6) should exist before migration 038 is applied anywhere,
and must exist before real customers are onboarded.

---

# PART A0 — PHASE 1 CONFIRMED BEHAVIOUR AND FOLLOW-UPS

## A0.1 What Phase 1 already does (reference; WRITTEN, AWAITING APPROVAL)

Do not re-implement. These are stated so later tasks stay consistent with them.

| Decision | Behaviour in migration 037 and its admin code |
|---|---|
| D-2 | `set_daily_order_status(ids, 'delivered')` on a finalized day records every item that has no delivered quantity as delivered in full, then settles. This is the bulk "Mark Delivered" and the per-row status dropdown. |
| D-7 | `reconcile_daily_run` raises, changing nothing, while any finalized order still `pending` has an item with `delivered_qty IS NULL`. The message gives the number of such orders. `0` is accepted. The delivered-quantity boxes on the run sheet work on a finalized day and are blocked once the day is reconciled. |
| D-8 | `getDeliveries` skips subscription daily orders whose status is `skipped` or `cancelled`. `isGoingOut` excludes them from Live Status, route sheets, CSV export, and the run-sheet count and value. They remain in the Daily Ops run sheet and Reconciliation tab. Nothing deletes a charged order (trigger `trg_guard_paid_daily_order_delete`). |
| D-9 | The 037 backfill sets `settlement_hold_reason` on any finalized order with `payment_status = 'failed'` and status `pending` or `delivered`, and on any order whose wallet ledger and `payment_status` disagree. `internal.settle_daily_order` raises for a held order, so finalize, delivery recording, status change, retry and reconcile never move money for it. |

Tests for all four exist in section 11 of `verify_money_integrity.mjs`.

---

### P1-01 — Reconciliation shows exactly which quantities are missing (D-7)

**Target Area:** Admin Panel

**Objective:** When reconcile is blocked, show staff the customers and items that still need a delivered quantity, not only a count.

**Exact Implementation Steps:**

1. `Hetha_admin/app/admin/daily-ops/hooks/useDailyOps.ts`: add
   `const [missingQty, setMissingQty] = useState<MissingQtyRow[] | null>(null);`
   where `MissingQtyRow = { orderId: string; customer: string; phone: string; route: string; items: string[] }`
   (define the type in `app/admin/daily-ops/types.ts`).
2. Add `loadMissingQuantities()` to the hook:
   1. Fetch `/api/admin/daily-ops?action=orders&date=${date}` with **no**
      area / route / status / search parameters (the run-sheet filters must
      not hide an order).
   2. Keep orders where `status === 'pending'` and at least one item has
      `delivered_qty == null` (null or undefined; `0` is a recorded quantity
      and must NOT be listed).
   3. Map each to a `MissingQtyRow`: `customer` = `subscriptions.snapshot_name ?? '-'`,
      `phone` = `subscriptions.snapshot_phone ?? ''`,
      `route` = `custom_route || subscriptions.delivery_routes?.route_name || '-'`,
      `items` = for each item with `delivered_qty == null`:
      `` `${product_name_snapshot} (${variant_label_snapshot}) × ${quantity}` ``.
   4. `setMissingQty(rows)` and return `rows`.
3. `handleReconcile`: before showing the confirm dialog, `await loadMissingQuantities()`.
   If the result is not empty, do not call the API; open the missing-quantities
   modal (step 5) and return. If the API is still refused with a message that
   starts with `Cannot reconcile:` (another admin changed something), call
   `loadMissingQuantities()` again and open the modal.
4. `components/ReconciliationTab.tsx`: the amber banner added in Phase 1
   ("N pending order(s) still need delivered quantities") gets a button
   `View list` that calls `loadMissingQuantities()` and opens the modal.
5. New component `components/MissingQuantitiesModal.tsx`:
   - Title: `Delivered quantities still needed`.
   - Intro: `Reconcile is blocked until every item below has a delivered quantity. Enter 0 for an item that was not delivered.`
   - Table columns: Customer, Phone, Route, Items without a quantity (one per line).
   - Footer text: `Enter them on the Deliveries page or on the Run Sheet (expand the order). To record whole orders as delivered in full, select them and use Mark Delivered.`
   - A `Close` button. No action buttons that change data.
6. Do not change `reconcile_daily_run` or any SQL.

**Acceptance Criteria:**
- With two pending orders missing quantities, clicking Reconcile opens the modal listing both customers and the exact items; no reconcile request is sent.
- An item with delivered quantity `0` is not listed.
- With an area filter active that hides one of those orders, the modal still lists both.
- After the quantities are entered, Reconcile proceeds to the confirm dialog.
- Bulk Mark Delivered on the listed orders clears them from the list (D-2).
- `tsc`, lint, build pass.

---

### P1-02 — Cancelled orders: hidden on Deliveries, kept everywhere else (D-8)

**Target Area:** Admin Panel

**Objective:** Verify, and fix where needed, that a cancelled order never appears on the Deliveries page or in a "delivered" total, and is never lost from reconciliation or history.

**Exact Implementation Steps:**

1. `services/deliveriesService.ts` `getDeliveries`: confirm the loop over
   subscription daily orders starts with
   `if (so.status === 'skipped' || so.status === 'cancelled') continue;`
   and that the one-time orders query excludes `cancelled`. Do not change it.
2. `app/admin/deliveries/page.tsx`: confirm no code path re-adds a cancelled
   order (for example an optimistic update). After A-08, a response with
   `status: 'cancelled'` removes the order from its stop.
3. `app/admin/daily-ops/components/ReconciliationTab.tsx`: confirm cancelled
   orders are rendered (the table maps over all `orders`) and their status
   dropdown is enabled while the day is finalized, so staff can set one back
   to Pending. Do not filter them out.
4. Run
   `grep -rn "subscription_daily_orders" Hetha_admin/app/api Hetha_admin/services --include=*.ts`
   and read every query that produces a count, a sum or a "delivered" figure
   (dashboard route, customer detail, payments, exports). For each:
   - a **delivered** count or value must filter `status = 'delivered'`;
   - a **revenue** value must use `paid_amount`, not `total_value`, once 037
     is live (a cancelled order has `paid_amount = 0`);
   - a query that lists history must NOT filter cancelled orders out.
   Fix any that does not follow these three rules; list each change in the
   change log.
5. `app/admin/customers/[id]/_components/`: confirm the customer's
   subscription-delivery history (if shown) includes cancelled orders with a
   "Cancelled" label and their refund in the wallet tab.
6. Do not add any delete of `subscription_daily_orders` or
   `wallet_transactions` rows anywhere.

**Acceptance Criteria:**
- A subscription order recorded as "nothing delivered" disappears from the Deliveries page, is listed as Cancelled in the Reconciliation tab, and its refund is in the customer's wallet history.
- `grep -rn "\.delete()" Hetha_admin/services Hetha_admin/app/api --include=*.ts` shows no new delete on `subscription_daily_orders` or `wallet_transactions` compared with the Phase 1 code.
- Every delivered total found in step 4 counts only `status = 'delivered'`.

---

### P1-03 — Historical unpaid deliveries stay on hold (D-9)

**Target Area:** Admin Panel + Database tests

**Objective:** Guarantee no code path charges, retries or releases a held order automatically, and make that guarantee a permanent test.

**Exact Implementation Steps:**

1. Search for anything that clears or bypasses a hold:
   `grep -rn "settlement_hold_reason" Hetha_admin Hetha_app docs/db/migrations`.
   Allowed writers: the migration 037 backfill only. Allowed readers: the
   settlement functions, `getDailyOrders` (to show a badge) and A-17.
   Any other write is a defect; remove it and report it.
2. Admin UI: in `components/RunSheetTab.tsx` and `ReconciliationTab.tsx`, for
   an order with a non-null `settlement_hold_reason` show a badge
   `ON HOLD: PAYMENT REVIEW`, disable its status dropdown and do not render a
   Retry payment button. Add `settlement_hold_reason` to the `select` in
   `services/dailyOps/orders.ts` `getDailyOrders` and to the `DailyOrder` /
   `DailyOrderWithItems` types.
3. Tests (extend section 11 of `verify_money_integrity.mjs`; these need no
   migration change): for a held legacy order assert that each of
   `finalize_daily_run`, `record_subscription_delivery`,
   `set_daily_order_status`, `retry_daily_order_payment` and
   `reconcile_daily_run` leaves the customer's wallet balance, the order's
   `paid_amount`, its `settlement_hold_reason` and its wallet transactions
   unchanged. (Some of these already exist; add the missing ones.)
4. Add a test that re-running migration 037 does not clear an existing hold.
5. Document in `Hetha_admin/docs/daily_ops.md` §7: "An order on payment hold
   is never charged, retried or released by the system. Review it (Daily Ops
   → payment hold list, task A-17). Releasing one is a deliberate SQL step by
   the owner, described in migration 037's verification section."

**Acceptance Criteria:**
- `npm run verify` → 0 failed, with at least one assertion per function named in step 3.
- A held order in the admin shows the badge and has no way to retry or change status.
- The grep in step 1 finds no writer other than migration 037.

---

# PART A — PHASE 2: structure of Daily Ops (Priority 1)

Goal: every Daily Ops write becomes one all-or-nothing database function, a
finalized day cannot be edited by going around those functions, and nothing
depends on loading "the whole day" through the 1000-row API cap (D-5).

Migration file for all SQL tasks in this part:
`docs/db/migrations/038_daily_ops_structure.sql`.

---

### P2-01 — Delivery-day rule as one SQL function

**Target Area:** Database

**Objective:** Put "does this subscription deliver on this date" in one SQL function so generation, the wallet forecast, the reminder and tests all use the same rule (today it is duplicated in `generateRunSheet.ts`, `lib/deliverySchedule.ts` and `internal.next_delivery_date`).

**Exact Implementation Steps:**

1. In migration 038 create
   `internal.subscription_delivers_on(p_subscription_id uuid, p_date date) RETURNS boolean`,
   `LANGUAGE plpgsql STABLE SECURITY DEFINER`.
2. Load the subscription row (`status, start_date, end_date, delivary_area, delivary_frequency`). If not found → return `false`.
3. Return `false` if `status NOT IN ('active', 'pending_cancellation')`.
4. **Move override, remove:** return `false` if a row exists in
   `delivery_day_overrides o JOIN delivery_day_override_subscriptions s ON s.override_id = o.id`
   with `o.override_kind = 'move' AND o.from_date = p_date AND s.subscription_id = p_subscription_id`.
5. **Pause:** return `false` if a row exists in `subscription_pauses` with
   `subscription_id = p_subscription_id AND pause_start_date <= p_date AND pause_end_date >= p_date`.
   (Applies even to a force-added move; matches the current generator.)
6. **Move override, force add:** set `v_force := true` if a row exists as in
   step 4 but with `o.to_date = p_date`.
7. If `NOT v_force`:
   1. Return `false` if `end_date IS NOT NULL AND end_date < p_date`.
   2. Return `false` if `start_date IS NOT NULL AND start_date > p_date`.
   3. **Effective area:** if a row exists in `delivery_day_overrides` with
      `override_kind = 'swap' AND override_date = p_date` linked to this
      subscription, the area is `delivery_areas.id = o.swapped_with_area_id`.
      Otherwise the area is `delivery_areas.display_name = subscription.delivary_area`
      (may be none).
   4. **Cadence:**
      - If an area was found AND `COALESCE(area.delivary_frequency, 1) > 1`
        AND `area.reference_date IS NOT NULL`: let
        `d := p_date - area.reference_date`. Return `false` unless
        `d >= 0 AND d % area.delivary_frequency = 0`.
      - Else if `COALESCE(subscription.delivary_frequency, 1) > 1` AND
        `subscription.start_date IS NOT NULL`: let
        `d := p_date - subscription.start_date`. Return `false` unless
        `d >= 0 AND d % subscription.delivary_frequency = 0`.
      - Else: no cadence restriction.
8. **Items:** return `false` unless at least one row exists in
   `subscription_items` with `subscription_id = p_subscription_id AND is_active = true AND item_start_date <= p_date AND (item_end_date IS NULL OR item_end_date >= p_date)`.
9. Return `true`.
10. Also create
    `internal.subscription_items_on(p_subscription_id uuid, p_date date) RETURNS SETOF public.subscription_items`
    (`LANGUAGE sql STABLE SECURITY DEFINER`) returning exactly the rows that
    satisfy the filter in step 8. Generation and the wallet forecast both use it.
11. Revoke both from `PUBLIC, anon, authenticated`.

**Edge cases that must hold:**
- A subscription delivers **on** its `start_date` and **on** its `end_date`.
- Both the first and the last day of a pause are paused.
- An area with frequency > 1 but no `reference_date` falls through to the
  subscription-frequency branch (same as the current TypeScript).
- A move override to date X delivers on X even if X is before `start_date`,
  after `end_date`, or off-cadence; but not if X is paused or no item is active.

**Acceptance Criteria:**
- Tests in the new section 12 of `verify_money_integrity.mjs`, one assertion
  each: start day true; day before start false; end day true; day after end
  false; pause first/middle/last day false; day after pause true; area
  every-2-days on/off day; area swap override uses the borrowed area's
  cadence; move from-date false; move to-date true off-cadence; move to-date
  that is paused false; inactive item only → false; item starting tomorrow →
  false today; cancelled subscription false.
- `npm run verify` → 0 failed.

---

### P2-02 — Run-sheet generation as one database function

**Target Area:** Database

**Objective:** Replace the six separate API writes in `Hetha_admin/services/dailyOps/generateRunSheet.ts` with one transaction, which removes the half-finished generate and the 1000-row cap on generation.

**Exact Implementation Steps:**

1. In migration 038 create
   `public.generate_daily_run(p_delivery_date date, p_admin_id uuid) RETURNS jsonb`.
2. First statement: `PERFORM set_config('hetha.daily_ops_rpc', 'on', true);`
   (needed by the lock trigger in P2-05).
3. Raise `'Not authorized to generate a delivery run'` unless
   `internal.is_admin_actor('daily_ops:edit')`.
4. Raise `'A delivery date is required'` if `p_delivery_date IS NULL`.
5. **Lock the run row:**
   ```sql
   INSERT INTO public.daily_ops_runs (delivery_date, status, generated_by, generated_at)
   VALUES (p_delivery_date, 'draft', p_admin_id, now())
   ON CONFLICT (delivery_date) DO NOTHING;
   SELECT id, status INTO v_run_id, v_run_status
   FROM public.daily_ops_runs WHERE delivery_date = p_delivery_date FOR UPDATE;
   ```
   If `v_run_status <> 'draft'` raise
   `'This date is % . Unlock it before regenerating.'` with the status.
6. **Delete "clean" orders** so they can be regenerated from the current
   subscription. An order is clean only when ALL are true:
   `delivery_date = p_delivery_date`, `status = 'pending'`,
   `COALESCE(is_finalized, false) = false`, `payment_status = 'pending'`,
   `paid_amount = 0`, `settlement_hold_reason IS NULL`,
   `is_customer_modified = false`,
   `COALESCE(custom_route, '') = ''`, `COALESCE(tracking_info, '') = ''`,
   and it has **no** item with `is_adhoc_addition = true` and **no** item with
   `delivered_qty IS NOT NULL`.
   Delete the items of those orders first, then the orders. Count the deleted
   orders into `v_deleted`.
7. **Insert missing orders.** Loop over
   ```sql
   SELECT s.id, s.user_id
   FROM public.subscriptions s
   WHERE s.status IN ('active', 'pending_cancellation')
     AND internal.subscription_delivers_on(s.id, p_delivery_date)
     AND NOT EXISTS (SELECT 1 FROM public.subscription_daily_orders o
                     WHERE o.subscription_id = s.id AND o.delivery_date = p_delivery_date)
   ORDER BY s.created_at, s.id
   ```
   For each: compute
   `v_total := (SELECT COALESCE(SUM(round(unit_price * quantity, 2)), 0) FROM internal.subscription_items_on(s.id, p_delivery_date))`.
   Skip the subscription if `v_total <= 0`. Otherwise:
   ```sql
   INSERT INTO public.subscription_daily_orders
     (delivery_date, subscription_id, user_id, status, total_value, payment_status, is_finalized)
   VALUES (p_delivery_date, s.id, s.user_id, 'pending', v_total, 'pending', false)
   RETURNING id INTO v_order_id;
   INSERT INTO public.subscription_daily_order_items
     (daily_order_id, variant_id, product_name_snapshot, variant_label_snapshot,
      unit_price, quantity, total_price, is_adhoc_addition)
   SELECT v_order_id, i.variant_id, i.product_name_snapshot, i.variant_label_snapshot,
          i.unit_price, i.quantity, round(i.unit_price * i.quantity, 2), false
   FROM internal.subscription_items_on(s.id, p_delivery_date) i;
   ```
   Increment `v_generated`.
8. Update the run row: `generated_at = now(), generated_by = p_admin_id, updated_at = now()`.
9. Return
   `jsonb_build_object('generated', v_generated, 'deleted', v_deleted, 'skipped', v_live - v_generated - v_existing, 'date', p_delivery_date)`
   where `v_live` = count of subscriptions with status active/pending_cancellation
   and `v_existing` = count of orders for the date that existed before step 7
   (count after step 6, before step 7).
10. Grants per §1 rule 5.

**Do not** copy the old cut-off check (`created_at` vs cut-off time). It was
removed on purpose; migration 036 applies the cut-off at subscription creation.

**Acceptance Criteria (tests, section 12):**
- A customer cannot call it (`'Not authorized'`).
- Generates one order per delivering subscription with `total_value = Σ items`.
- Running it twice creates no duplicates and returns `generated: 0` the second time.
- A customer-modified order (`is_customer_modified = true`) survives regeneration unchanged.
- An order with `paid_amount > 0` (paid, then unlocked) survives regeneration; its `paid_amount` is unchanged.
- An order on settlement hold survives regeneration untouched (D-9).
- An order with a staff-entered `custom_route`, `tracking_info`, an ad-hoc item, or a delivered quantity survives.
- A clean order whose subscription was changed since (quantity edited) is regenerated with the new quantity.
- On a finalized or reconciled date it raises and changes nothing.
- With 1,200 subscriptions inserted by the test, it generates 1,200 orders (proves no 1000-row cap).
- A paused subscription and a subscription starting tomorrow get no order.

---

### P2-03 — Add an item to a daily order (database function)

**Target Area:** Database

**Objective:** Replace `addDailyOrderItem` (three separate writes that the total-check trigger rejects, and a client-supplied price) with one function that prices from the catalog.

**Scope note (D-4):** this is a **staff** action on one day's order in the admin panel. It does not let a customer add an item to a subscription and must not be exposed to the app.

**Exact Implementation Steps:**

1. In migration 038 create
   `public.add_daily_order_item(p_order_id uuid, p_variant_id uuid, p_quantity integer) RETURNS jsonb`.
2. `PERFORM set_config('hetha.daily_ops_rpc', 'on', true);`
3. Raise `'Not authorized'` unless `internal.is_admin_actor('daily_ops:edit')`.
4. Raise `'Quantity must be a whole number from 1 to 99'` unless
   `p_quantity BETWEEN 1 AND 99`.
5. `SELECT * INTO v_order FROM public.subscription_daily_orders WHERE id = p_order_id FOR UPDATE;`
   Not found → `'Daily order not found'`.
6. Raise `'This day is finalized. Unlock it to change its orders.'` if
   `COALESCE(v_order.is_finalized, false)`.
7. Raise `'Only a pending order can be changed (this one is %)'` if
   `v_order.status <> 'pending'`.
8. Raise `'This order is on payment hold and cannot be changed'` if
   `v_order.settlement_hold_reason IS NOT NULL` (D-9).
9. Load the variant and product:
   `SELECT v.price, v.label, p.name INTO … FROM public.product_variants v JOIN public.products p ON p.id = v.product_id WHERE v.id = p_variant_id AND v.is_active = true`.
   Not found → `'This product variant is not available'`. Price `<= 0` or NULL →
   `'This product variant has no price'`.
10. If the order already has an item with the same `variant_id`, increase that
    item's `quantity` by `p_quantity` and set
    `total_price = round(unit_price * quantity, 2)` (keep its existing
    `unit_price` snapshot). Otherwise insert a new item with
    `unit_price = v.price`, `quantity = p_quantity`,
    `total_price = round(v.price * p_quantity, 2)`, `is_adhoc_addition = true`,
    `product_name_snapshot = p.name`, `variant_label_snapshot = v.label`.
11. `UPDATE public.subscription_daily_orders SET total_value = (SELECT COALESCE(SUM(total_price), 0) FROM public.subscription_daily_order_items WHERE daily_order_id = p_order_id) WHERE id = p_order_id;`
12. Return `jsonb_build_object('order_id', p_order_id, 'total_value', <new total>)`.

**Acceptance Criteria (tests):** customer caller refused; quantity 0 and 100 refused; inactive variant refused; finalized order refused; held order refused; adding a new variant creates an ad-hoc item at the catalog price and the order total equals Σ items; adding the same variant again increases the quantity instead of creating a second row; a `price` field cannot be passed (the function has no such parameter).

---

### P2-04 — Remove an item / change an item quantity (database functions)

**Target Area:** Database

**Objective:** Replace `removeDailyOrderItem` and the dead `updateDailyOrderItem` with atomic functions that keep the order total correct and refund a charged order that becomes empty.

**Exact Implementation Steps:**

1. In migration 038 create
   `public.remove_daily_order_item(p_item_id uuid) RETURNS jsonb`.
   1. `set_config('hetha.daily_ops_rpc', 'on', true)`; auth `daily_ops:edit`.
   2. Load the item (`daily_order_id`); not found → `'Item not found'`.
      Lock the parent order `FOR UPDATE`.
   3. Same finalized / status / hold checks as P2-03 steps 6–8.
   4. Delete the item.
   5. Count remaining items.
      - **> 0:** update `total_value = Σ total_price`. Return
        `{ "deleted_order": false, "cancelled": false, "refunded": 0, "total_value": <n> }`.
      - **= 0 and `v_order.paid_amount > 0`:** set `status = 'cancelled'`,
        `total_value = 0`; call
        `internal.settle_daily_order(v_order.id, 'raise', 'delivery cancelled')`;
        return `{ "deleted_order": false, "cancelled": true, "refunded": <refunded>, "total_value": 0 }`.
        The order row and its wallet transactions are kept (D-8).
      - **= 0 and `paid_amount = 0`:** delete the order. Return
        `{ "deleted_order": true, "cancelled": false, "refunded": 0, "total_value": 0 }`.
2. Create
   `public.set_daily_order_item_quantity(p_item_id uuid, p_quantity integer) RETURNS jsonb`.
   1. Same flag, auth, load, lock and finalized/status/hold checks.
   2. `p_quantity` must be `BETWEEN 1 AND 99`, else raise (to remove an item use
      `remove_daily_order_item`).
   3. `UPDATE … SET quantity = p_quantity, total_price = round(unit_price * p_quantity, 2), delivered_qty = NULL WHERE id = p_item_id;`
   4. Update the parent `total_value = Σ total_price`.
   5. Return `{ "order_id": …, "total_value": … }`.

**Acceptance Criteria (tests):** removing one of two items leaves total = remaining item; removing the last item of an unpaid order deletes the order; removing the last item of a paid-then-unlocked order cancels it, keeps the row, and refunds exactly `paid_amount` (wallet and ledger checked); quantity change updates item and order totals; both refused on a finalized order, on a held order, and for a customer caller.

---

### P2-05 — Database-level lock on finalized days

**Target Area:** Database

**Objective:** Stop any direct table write (admin panel bug, hand-made request) from changing a finalized order or its payment fields; only the settlement functions may.

**Exact Implementation Steps:**

1. **Mark every trusted function.** Add
   `PERFORM set_config('hetha.daily_ops_rpc', 'on', true);` as the first
   statement of the body of each of these, re-declaring them with
   `CREATE OR REPLACE` in migration 038 (copy the current body from migration
   037 unchanged, add only this line):
   `internal.settle_daily_order`, `public.finalize_daily_run`,
   `public.unlock_daily_run`, `public.record_subscription_delivery`,
   `public.set_daily_order_status`, `public.retry_daily_order_payment`,
   `public.reconcile_daily_run`.
   (The functions from P2-02…P2-04 already set it.)
   Copy the bodies exactly: the strict reconcile rule (D-7), the bulk
   delivered rule (D-2) and the hold check (D-9) must be unchanged.
2. Create `internal.daily_ops_write_allowed() RETURNS boolean` (`STABLE`):
   returns `true` when `current_setting('hetha.daily_ops_rpc', true) = 'on'`
   OR `internal.money_checks_disabled()` OR `internal.jwt_role() = 'internal'`
   (the SQL Editor; needed for the owner's manual hold review, D-9).
3. Create trigger function `internal.guard_daily_order_write()` and
   `CREATE TRIGGER trg_guard_daily_order_write BEFORE UPDATE OR DELETE ON public.subscription_daily_orders FOR EACH ROW`.
   Logic:
   - If `internal.daily_ops_write_allowed()` → return (`OLD` for DELETE, `NEW` for UPDATE).
   - **DELETE:** if `COALESCE(OLD.is_finalized, false)` raise
     `'This order is finalized and cannot be deleted'`. Otherwise allow
     (the paid-amount delete guard from 037 still applies).
   - **UPDATE, protected columns:** if any of `paid_amount`, `payment_status`,
     `is_finalized`, `finalized_at`, `finalized_by`, `skip_reason`,
     `settled_at`, `settlement_hold_reason`, `wallet_deducted_at` differs
     between `OLD` and `NEW` (use `IS DISTINCT FROM`) raise
     `'Payment and finalize fields can only be changed by the Daily Ops functions'`.
   - **UPDATE on a finalized order** (`COALESCE(OLD.is_finalized, false)`):
     allowed only if every column except `tracking_info` and `custom_route` is
     unchanged; otherwise raise
     `'This order is finalized. Use the Daily Ops actions to change it.'`.
     Additionally, if the run for `OLD.delivery_date` has status `reconciled`
     raise `'This day is reconciled and can no longer be changed'`.
     Compare columns with
     `to_jsonb(NEW) - 'tracking_info' - 'custom_route' IS DISTINCT FROM to_jsonb(OLD) - 'tracking_info' - 'custom_route'`.
   - Otherwise allow.
4. Create trigger function `internal.guard_daily_order_item_write()` and
   `CREATE TRIGGER trg_guard_daily_order_item_write BEFORE INSERT OR UPDATE OR DELETE ON public.subscription_daily_order_items FOR EACH ROW`.
   Logic:
   - If `internal.daily_ops_write_allowed()` → return.
   - Load the parent order's `is_finalized` and `delivery_date`
     (`COALESCE(NEW.daily_order_id, OLD.daily_order_id)`). Parent not found →
     allow (it is being created or deleted in this transaction).
   - Parent **not finalized** → allow.
   - Parent finalized, **INSERT or DELETE** → raise
     `'This order is finalized. Unlock the day to change its items.'`.
   - Parent finalized, **UPDATE** → allowed only if the only changed column is
     `delivered_qty`
     (`to_jsonb(NEW) - 'delivered_qty' IS NOT DISTINCT FROM to_jsonb(OLD) - 'delivered_qty'`),
     AND `NEW.delivered_qty IS NULL OR NEW.delivered_qty BETWEEN 0 AND NEW.quantity`
     (zero is valid, D-7), AND the run is not `reconciled`. Otherwise raise.
5. Revoke the three functions from `PUBLIC, anon, authenticated`.

**Important:** customer functions (`modify_daily_order`, `modify_daily_orders_bulk`,
`revert_daily_order`, `cancel_subscription`) only touch orders that are **not**
finalized, so they pass the triggers without the flag. Do not add the flag to them.

**Acceptance Criteria (tests):** with customer or admin claims and no RPC:
direct `UPDATE … SET is_finalized = true` refused; direct
`UPDATE … SET payment_status = 'paid'` refused; direct `SET paid_amount = 0`
refused; direct `SET settlement_hold_reason = NULL` refused (D-9); direct
status change on a finalized order refused; direct `tracking_info` /
`custom_route` change on a finalized order allowed; direct `delivered_qty`
change on a finalized order's item allowed, including `0`, but `delivered_qty`
above `quantity` refused; item insert/delete on a finalized order refused;
everything refused on a reconciled day; bulk Mark Delivered through
`set_daily_order_status` still works (D-2); **all section-11 tests from
migration 037 still pass** (they call the trusted functions).

---

### P2-06 — Admin: generation calls the database function

**Target Area:** Admin Panel

**Objective:** Make the Generate button use `generate_daily_run` and delete the TypeScript generator.

**Exact Implementation Steps:**

1. In `Hetha_admin/services/dailyOps/generateRunSheet.ts` replace the whole
   body of `generateRunSheet` with:
   ```ts
   const { data, error } = await supabase.rpc('generate_daily_run', {
     p_delivery_date: targetDate,
     p_admin_id: adminId,
   });
   if (error) throw error;
   return data as GenerateRunSheetResult;
   ```
   Change the signature to
   `generateRunSheet(supabase, targetDate: string, adminId: string)`.
   Remove every other import and helper in the file that is now unused.
2. In `services/dailyOps/types.ts` change `GenerateRunSheetResult` to
   `{ generated: number; deleted: number; skipped: number; date: string }`.
3. In `app/api/admin/daily-ops/route.ts`, POST handler, `action === 'generate'`:
   remove the `isDateLocked` check added on 2026-11-11 (the database now
   refuses) and call
   `dailyOpsService.generateRunSheet(supabase, date, userId)`.
4. In `services/dailyOps/overrides.ts`, delete `getOverrideMapForDate` and
   `getMoveMapsForDate` **only if** a project-wide search shows no remaining
   caller. Remove them from `services/dailyOps/index.ts` and
   `services/dailyOpsService.ts` too.
5. In `app/admin/daily-ops/hooks/useDailyOps.ts`, `handleGenerate`: change the
   success toast to
   `` `Run sheet synced: ${data.generated} order(s) created` `` .

**Acceptance Criteria:** `tsc`, lint, build pass. `grep -rn "subscription_pauses\|delivary_frequency" Hetha_admin/services/dailyOps/generateRunSheet.ts` returns nothing. In the browser (after 038 is applied to staging): Generate on a draft day creates orders; Generate on a finalized day shows the database's "Unlock it before regenerating" message.

---

### P2-07 — Admin: item edits call the database functions

**Target Area:** Admin Panel

**Objective:** Make add / remove item on the run sheet use the functions from P2-03 and P2-04, and stop sending prices from the browser.

**Exact Implementation Steps:**

1. In `services/dailyOps/orders.ts`:
   - Replace `addDailyOrderItem` with
     `addDailyOrderItem(supabase, dailyOrderId: string, variantId: string, quantity: number)`
     calling `supabase.rpc('add_daily_order_item', { p_order_id, p_variant_id, p_quantity })`;
     throw on `error`; return the data.
   - Replace `removeDailyOrderItem` with
     `removeDailyOrderItem(supabase, itemId: string)` calling
     `supabase.rpc('remove_daily_order_item', { p_item_id })`. Return type
     `{ deleted_order: boolean; cancelled: boolean; refunded: number; total_value: number }`.
   - Delete `updateDailyOrderItem`. Add
     `setDailyOrderItemQuantity(supabase, itemId, quantity)` calling
     `set_daily_order_item_quantity`.
   - Update `services/dailyOps/index.ts` and `services/dailyOpsService.ts` exports.
2. In `app/api/admin/daily-ops/route.ts`, PATCH handler:
   - `add-item`: read `{ dailyOrderId, variant_id, quantity }` from the body.
     Ignore `unit_price`, `product_name_snapshot`, `variant_label_snapshot` if
     present. Require `dailyOrderId` and `variant_id`; default `quantity` to 1.
   - `remove-item`: require `itemId` only.
   - Remove the finalized-day lock check for these two actions (the database
     refuses with its own message). The remaining route-level lock block is
     removed in A-16.
3. In `app/admin/daily-ops/hooks/useDailyOps.ts`:
   - `handleAddItem`: send only
     `{ action: 'add-item', dailyOrderId: orderId, variant_id: variant.id, quantity: 1, date }`.
     On `!res.ok` read `data.error` and show it (today it shows a fixed string).
   - `handleRemoveItem`: toast
     `data.cancelled` → ``Order cancelled (no items left), ₹${refunded} refunded``;
     `data.deleted_order` → `'Order deleted (no items left)'`; else `'Item removed'`.

**Acceptance Criteria:** `tsc`, lint, build pass. `grep -n "unit_price" Hetha_admin/app/admin/daily-ops/hooks/useDailyOps.ts` shows no line inside `handleAddItem`. In the browser on a draft day: add an item → row total increases by the catalog price; remove it → total returns; both show the database error on a finalized day.

---

### P2-08 — Admin: quantity editing on the run sheet (optional UI)

**Target Area:** Admin Panel

**Objective:** Let staff change an item's ordered quantity on a draft day using `set_daily_order_item_quantity` (today the only way is remove and re-add).

**Exact Implementation Steps:**

1. Route: add PATCH action `set-item-quantity` with body `{ itemId, quantity }`;
   validate `Number.isInteger(quantity) && quantity >= 1 && quantity <= 99`
   (400 otherwise); call `dailyOpsService.setDailyOrderItemQuantity`.
2. `RunSheetTab.tsx`, expanded order table: when `!isLocked`, render the
   ordered quantity as a number input (`min=1 max=99`) that calls a new hook
   function `handleItemQuantitySave(itemId, orderId, value)` on blur and Enter.
   When locked, keep plain text. This is the **ordered** quantity; the
   **delivered** quantity box (D-7) is separate and stays as it is.
3. Hook: `handleItemQuantitySave` posts the action, on success calls
   `fetchOrders()`, on failure shows `data.error` and restores the old value.

**Acceptance Criteria:** changing a quantity on a draft day updates the row's value and the order total after refetch; the input is not shown on a finalized day.

---

### P2-09 — Admin: page every "whole day" read (1000-row cap, D-5)

**Target Area:** Admin Panel

**Objective:** Stop the run sheet, sheets, export, live status and Deliveries page from silently truncating at 1000 rows, without raising the Data API limit.

**Exact Implementation Steps:**

1. Create `Hetha_admin/lib/fetchAll.ts`:
   ```ts
   /** Reads every row of a PostgREST query, 1000 at a time. `build` must
    *  return a fresh query with a stable, unique ORDER BY each call. */
   export async function fetchAll<T>(
     build: () => { range: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: { message: string } | null }> },
     pageSize = 1000,
   ): Promise<T[]> {
     const rows: T[] = [];
     for (let from = 0; ; from += pageSize) {
       const { data, error } = await build().range(from, from + pageSize - 1);
       if (error) throw new Error(error.message);
       rows.push(...(data ?? []));
       if (!data || data.length < pageSize) return rows;
     }
   }
   ```
2. `services/dailyOps/orders.ts` `getDailyOrders`: wrap the query in
   `fetchAll`, and change the ordering to
   `.order('created_at', { ascending: true }).order('id', { ascending: true })`
   (the second key makes paging stable).
3. `services/deliveriesService.ts` `getDeliveries`: same for the
   `subscription_daily_orders` query (order by `created_at`, `id`) and the
   `orders` query (order by `expected_delivery_date`, `placed_at`, `id`).
4. `app/api/admin/daily-ops/route.ts`: no change needed after Phase 1 (finalize
   and reconcile no longer re-read the day).
5. `app/api/admin/notifications/route.ts` "send to all": page the
   `device_tokens` read with `fetchAll` ordered by `id`.
6. Do **not** change the Supabase "Max rows" setting, and do not rely on a
   client `.limit()` larger than 1000 anywhere.

**Acceptance Criteria:** `tsc`, lint, build pass. Unit check with a stub: a
`build` that returns 1000, 1000, 300 rows yields 2300 rows and is called 3
times; one that returns 1000 then 0 is called twice.
`grep -rn "limit(10000)" Hetha_admin/services Hetha_admin/app` returns nothing.

---

### P2-10 — Phase 2 documentation and change log

**Target Area:** Backend

**Objective:** Record Phase 2 the way earlier migrations were recorded.

**Exact Implementation Steps:**

1. `docs/DATA_MODEL.md`: add rows for `generate_daily_run`,
   `add_daily_order_item`, `remove_daily_order_item`,
   `set_daily_order_item_quantity`, `get_earliest_change_date`,
   `internal.subscription_delivers_on`, `internal.subscription_items_on`, the
   two new triggers, and `internal.daily_ops_write_allowed`.
2. `Hetha_admin/docs/daily_ops.md` section 1: replace the description of the
   TypeScript filter chain with "generation is the database function
   `generate_daily_run`; the rule is `internal.subscription_delivers_on`".
3. New `CHANGES_<date>.md` in the format of `CHANGES_2026-11-13.md`.

**Acceptance Criteria:** every function and trigger created in migration 038 appears in `docs/DATA_MODEL.md` (grep each name).

---

# PART B — SIMPLIFIED WALLET

## B.0 What "simplified" means

How other subscription delivery apps handle a prepaid wallet (from the
2026-11-10 review; their policies are not published, this is the common
pattern):

1. The wallet is checked **at the cut-off for the next delivery**. If it
   cannot cover the order, the order is skipped and the customer is told to
   recharge.
2. There is **no multi-delivery reserve** as a hard gate.
3. Wallets are kept full by **reminders**, not by locking money.

Hetha's model after this part (D-1, D-3 as revised):

| Area | Before (historical; being removed) | After Part B |
|---|---|---|
| Reserve | A multi-delivery reserve written as a literal multiplier in four SQL functions and three screens (the exact strings are listed in Appendix H). It could not be explained to customers with subscriptions in areas on different schedules. | **1 upcoming delivery of each active subscription**, from one function, `internal.wallet_reserve`. |
| "How long will my wallet last" | Five separate calculations (wallet page simulation, checkout, create-subscription, admin "Wallet covers", low-balance push) that disagreed and ignored area schedules, pauses and day edits. | One function, `wallet_forecast`, used by all of them. |
| Low balance | An automatic push after Finalize when the balance was below a multiple of that day's debit. | **Manual only.** Staff open the list for a delivery date in Daily Ops and send the push to the customers they choose. |
| Wallet short at delivery | (Already changed by migration 037.) | The order is skipped at finalize, nothing is taken, the customer is notified, and staff can retry after a recharge. |

**Schema changes in this part:** one small table, `wallet_notice_log`
(manual low-balance notices sent, one per customer and delivery date). No change to `users`,
`wallet_transactions`, `subscriptions` or `subscription_daily_orders`.

**What "1 upcoming delivery per active subscription" means exactly:** the
reserve is the sum, over the customer's subscriptions with status `active` or
`pending_cancellation`, of that subscription's normal per-delivery cost
(`Σ unit_price × quantity` of its active items). It does not depend on the
calendar, so it is the same on every day and for every area schedule.

## B.1 State rules (reference; implemented by migration 037, do not change)

**Wallet:**
- `users.wallet_balance >= 0` always (CHECK constraint).
- Credits: Razorpay top-up (`finalize_wallet_topup`), admin adjustment,
  refunds from `settle_daily_order` and `record_order_delivery`.
- Debits: one-time wallet orders (`place_order`), `settle_daily_order`, admin
  adjustment.
- Every change writes one `wallet_transactions` row in the same transaction.

**Subscription daily order (`subscription_daily_orders`):**

| `status` | `payment_status` | `paid_amount` | Meaning |
|---|---|---|---|
| `pending`, not finalized | `pending` | 0 | Generated, editable, not charged |
| `pending`, finalized | `paid` | = owed | Charged, going out |
| `skipped` + `skip_reason` | `failed` | 0 | Wallet could not cover it at finalize; not delivered; can be retried |
| `skipped`, no `skip_reason` | `pending` or `refunded` | 0 | Staff or customer skipped it |
| `delivered` | `paid` | Σ price × delivered qty | Delivered; shortfall refunded |
| `cancelled` | `pending` or `refunded` | 0 | Not delivered; anything taken was refunded. Row and wallet history kept (D-8). |
| any, `settlement_hold_reason` set | unchanged | unchanged | On payment hold; no function moves money for it (D-9) |

Allowed transitions and the money each moves are defined by
`set_daily_order_status`, `record_subscription_delivery`,
`retry_daily_order_payment`, `finalize_daily_run`, `reconcile_daily_run` in
migration 037. Client code must never set `status`, `payment_status` or
`paid_amount` directly.

## B.2 API surface added by this part

| Kind | Name | Caller |
|---|---|---|
| RPC | `get_wallet_reserve(p_user_id)` | App (checkout, create subscription), admin |
| RPC | `get_wallet_forecast(p_user_id, p_days)` | App (wallet page), admin (customer profile) |
| RPC | `get_low_balance_customers(p_delivery_date)` | Admin API (Daily Ops list) |
| RPC | `claim_manual_low_balance_notices(p_delivery_date, p_user_ids)` / `mark_wallet_notice_result(...)` | Admin API (Daily Ops Send) |
| HTTP | `GET /api/admin/daily-ops?action=low-balance&date=` / `POST action=send-low-balance` | Daily Ops screen |

Migration file for all SQL tasks in this part:
`docs/db/migrations/039_wallet_simplification.sql`. It requires migration 038.

---

### W-01 — One function for the wallet reserve (D-1)

**Target Area:** Database

**Objective:** Make the wallet reserve one upcoming delivery per active subscription, defined in exactly one database function, and remove every other copy of the rule.

**Exact Implementation Steps:**

1. Create
   `internal.wallet_reserve(p_user_id uuid) RETURNS numeric` (`STABLE`,
   `SECURITY DEFINER`):
   ```sql
   SELECT round(COALESCE(public.get_user_daily_commitment(p_user_id), 0), 2);
   ```
   Comment above it: "The wallet reserve: one upcoming delivery of each active
   subscription (owner decision D-1). `get_user_daily_commitment` is the sum of
   the per-delivery cost of the customer's live subscriptions. This is the only
   place the reserve is defined."
   There is **no** multiplier parameter and no multiplier function.
2. Create
   `internal.wallet_reserve_with(p_user_id uuid, p_extra_per_delivery numeric) RETURNS numeric`:
   `SELECT round(internal.wallet_reserve(p_user_id) + GREATEST(COALESCE(p_extra_per_delivery, 0), 0), 2);`
   Used when a new subscription is being created, so its own first delivery is
   included in the reserve.
3. Re-declare these four functions with `CREATE OR REPLACE`, copying the
   **latest** body and changing only the lines listed. Latest bodies:
   `internal.create_subscription_core` → migration 036;
   `internal.place_order_core` → find the newest definition with
   `grep -n "FUNCTION internal.place_order_core" docs/db/migrations/*.sql`;
   `internal.modify_daily_order_core` → migration 025;
   `internal.modify_daily_orders_bulk_core` → migration 027.

   | Function | Line to find (old rule; Appendix H) | Replace with |
   |---|---|---|
   | `create_subscription_core` | H-1 | `v_required := internal.wallet_reserve_with(p_user_id, v_new_daily);` |
   | `place_order_core` | H-2 | `v_reserve    := internal.wallet_reserve(p_user_id);` |
   | `modify_daily_order_core` | H-3 | `v_required  := round(internal.wallet_reserve(p_user_id) + v_extra, 2);` |
   | `modify_daily_orders_bulk_core` | H-4 | `v_required  := round(internal.wallet_reserve(p_user_id) + v_total_extra, 2);` |

   In each function, a local variable that only fed the old line
   (`v_existing_daily`, `v_commitment`, `v_committed`) may now be unused in
   the calculation; keep it only if the error message still prints it.
4. Replace the four error messages (old texts: Appendix H-5 … H-8) with:
   - create: `'Insufficient wallet balance (%). You need at least % to cover the next delivery of all your subscriptions.'` (args: balance, required)
   - place order: `'Insufficient wallet balance. Required: % (order %) plus % kept for the next delivery of your subscriptions, available: %'`
   - day edit: `'Insufficient wallet balance (%). You need at least % (% for the next delivery of your subscriptions plus % extra for this day).'`
   - bulk: `'Insufficient wallet balance (%). You need at least % (% for the next delivery of your subscriptions plus % extra across % day(s) in this batch).'`
   Keep the words `Insufficient wallet balance` at the start of each; existing
   tests match on that.
5. Create
   `public.get_wallet_reserve(p_user_id uuid) RETURNS numeric`: raise
   `'Not authorized'` unless `auth.uid() = p_user_id` or
   `internal.is_admin_actor('customers:view')`; return
   `internal.wallet_reserve(p_user_id)`. Grant to `authenticated, service_role`.
6. **Existing tests.** In `verify_money_integrity.mjs`, tests written for the
   old rule compute the required amount in JavaScript with the old multiplier
   (the pattern is Appendix H-9). For each: remove the multiplier so the
   expected required amount is the commitment itself (plus the one-off extra
   where the test adds one). Update the test names to say "next delivery"
   instead of the old wording. Do not delete a test; change its expected number.
7. **New tests:**
   - A customer whose wallet equals exactly one delivery of all subscriptions
     (existing + the new one) can create a subscription; one rupee less is refused.
   - A wallet order whose total leaves exactly the reserve succeeds; one rupee
     more is refused, and the message contains `next delivery`.
   - A day edit that raises the day's cost needs reserve + extra; exactly that
     succeeds, one rupee less is refused.
   - A bulk edit needs reserve + the sum of extras.
   - An admin caller is not bound by the reserve.
   - A customer with no subscriptions has reserve 0 and can spend the whole wallet.
   - `get_wallet_reserve`: own id returns the reserve; another customer's id is refused; an admin with `customers:view` is allowed.

**Acceptance Criteria:**
- None of the Appendix H strings H-1 … H-8 occurs in
  `docs/db/migrations/039_wallet_simplification.sql`.
- `grep -n "wallet_reserve" docs/db/migrations/039_wallet_simplification.sql`
  shows the four functions calling it and no other reserve arithmetic.
- `npm run verify` → 0 failed.

---

### W-02 — One function for the wallet forecast

**Target Area:** Database

**Objective:** Give every screen and every notification the same answer to "what will be charged on which day, and how far does the wallet reach", using the real delivery schedule, pauses, day edits and existing daily orders.

**Exact Implementation Steps:**

1. Requires `internal.subscription_delivers_on` and
   `internal.subscription_items_on` from P2-01.
2. Create
   `internal.wallet_forecast(p_user_id uuid, p_days integer) RETURNS jsonb`
   (`STABLE SECURITY DEFINER`, no authorization check; internal callers only).
3. Clamp `p_days` to `1..60`.
4. `v_balance := COALESCE(users.wallet_balance, 0)`; user not found → raise
   `'User not found'`.
5. For each date `d` from `internal.today_ist() + 1` to
   `internal.today_ist() + p_days`, and each subscription `s` of the user with
   `status IN ('active', 'pending_cancellation')`, compute `amount(s, d)`:
   1. If a row exists in `subscription_daily_orders` for `(s.id, d)`:
      - status `skipped` or `cancelled` → 0;
      - `settlement_hold_reason IS NOT NULL` → 0 (never charged, D-9);
      - otherwise → `GREATEST(total_value - paid_amount, 0)` (a customer day
        edit or an already-charged order is respected).
   2. Else if `internal.subscription_delivers_on(s.id, d)` →
      `Σ round(unit_price * quantity, 2)` over
      `internal.subscription_items_on(s.id, d)`.
   3. Else 0.
6. Build `days`: an array of
   `{ "date": "YYYY-MM-DD", "amount": <sum over subscriptions>, "subscriptions": [ { "subscription_id", "label", "area", "amount" } … only those with amount > 0 ] }`,
   including **only** dates whose `amount > 0`, in date order.
7. Walk `days` in order with a running total. `covered_until` = the last date
   whose running total `<= v_balance` (JSON `null` if the first day is not
   covered or there are no days). `first_uncovered_date` = the first date
   whose running total `> v_balance` (`null` if all are covered).
   `covered_deliveries` = number of days covered.
8. Return:
   ```json
   {
     "balance": 250.00,
     "reserve": 300.00,
     "available": 0.00,
     "per_delivery_total": 300.00,
     "next_delivery_date": "2026-11-14",
     "next_delivery_amount": 150.00,
     "next_delivery_covered": true,
     "covered_until": "2026-11-14",
     "first_uncovered_date": "2026-11-15",
     "covered_deliveries": 1,
     "horizon_days": 14,
     "days": [ … ]
   }
   ```
   where `reserve = internal.wallet_reserve(p_user_id)` (W-01; one upcoming
   delivery per active subscription),
   `available = GREATEST(balance - reserve, 0)`,
   `per_delivery_total = get_user_daily_commitment(p_user_id)`,
   `next_delivery_*` come from `days[0]` (`null`, `0`, `true` when `days` is empty).
9. Create the public wrapper
   `public.get_wallet_forecast(p_user_id uuid, p_days integer DEFAULT 14) RETURNS jsonb`:
   raise `'Not authorized'` unless `auth.uid() = p_user_id` or
   `internal.is_admin_actor('customers:view')`; return
   `internal.wallet_forecast(p_user_id, p_days)`.
10. Grant the public function to `authenticated, service_role`; revoke from
    `PUBLIC, anon`. Revoke the internal one from `PUBLIC, anon, authenticated`.

**Edge cases that must hold:** a customer with no subscriptions gets
`days: []`, `covered_until: null`, `next_delivery_covered: true`; an
alternate-day area appears only on its delivery days; a paused day is absent;
a delivery moved by a move override appears on its new date and not the old
one; a customer-edited day shows the edited total; an order already paid for
tomorrow contributes 0; a subscription that starts in several days first
appears on its start date; today is never included (revised by migration 044, 2026-11-20: today counts until it is paid, so a run finalized during the day is still in the forecast; a run finalized the evening before is paid and adds 0. New field `covers_beyond_horizon`).

**Acceptance Criteria (tests):** one assertion per edge case above, plus: a mixed customer (daily area ₹50, alternate area ₹100 on odd days, alternate area ₹60 on even days) with balance ₹300 gets day amounts 150, 110, 150 …, `covered_until` = day 2, `first_uncovered_date` = day 3, and `reserve` = 210 (one delivery of each subscription); another user's id is refused for a customer caller and allowed for an admin with `customers:view`.

---

### W-03 — App wallet page uses the forecast

**Target Area:** App

**Objective:** Replace the client-side simulation in the wallet page (which ignores area schedules, pauses and day edits) with `get_wallet_forecast`, so the app shows the same numbers the database enforces.

**Exact Implementation Steps:**

1. File `Hetha_app/lib/screens/wallet/walletpage.dart`, method
   `_fetchWalletData` (≈ lines 274–375).
2. Delete the `subscriptions` query (the one selecting
   `delivary_frequency, start_date, subscription_items(...)`), the `subs`
   mapping, and the whole `for (int i = 0; i < 90; i++)` simulation loop.
3. After reading `userData`, call
   `final forecast = await Supabase.instance.client.rpc('get_wallet_forecast', params: {'p_user_id': userId, 'p_days': 30});`
   inside its own `try/catch`. On failure set `forecast = null` and continue
   (the balance must still show).
4. Replace the state fields `dailyCommitment` and `daysLeft` with:
   `double? nextDeliveryAmount;`, `DateTime? nextDeliveryDate;`,
   `DateTime? coveredUntil;`, `bool nextDeliveryCovered = true;`,
   `int coveredDeliveries = 0;`, `double reserve = 0;`,
   `bool hasForecast = false;`. Parse dates with `DateTime.tryParse`.
5. Replace the chip that shows the old per-day average (search for
   `/day avg`) with, when `hasForecast && nextDeliveryDate != null`:
   - `nextDeliveryCovered == false` → red chip:
     `'Not enough for your delivery on ${DateFormat('EEE d MMM').format(nextDeliveryDate)} (₹${nextDeliveryAmount.toStringAsFixed(0)}). Recharge to avoid a skipped delivery.'`
   - else `coveredUntil != null` → normal chip:
     `'Covers your deliveries until ${DateFormat('EEE d MMM').format(coveredUntil)}'`
   - Show nothing when there is no forecast or no upcoming delivery.
6. Under the balance, when `reserve > 0`, add one line of small text:
   `'₹${reserve.toStringAsFixed(0)} is kept for the next delivery of your subscriptions.'`
7. Remove any other use of `daysLeft` / `dailyCommitment` in the file; if one
   feeds a widget, replace it with `coveredDeliveries` /
   `nextDeliveryAmount ?? 0`.
8. The page must contain no reserve or runway arithmetic of its own: every
   number shown comes from the RPC result or `users.wallet_balance`.

**Acceptance Criteria:** `flutter analyze` (only the known hint) and `flutter test` pass. `grep -n "delivary_frequency\|i < 90\|/day avg" lib/screens/wallet/walletpage.dart` returns nothing. On a phone: a customer with an alternate-day subscription sees a "Covers your deliveries until …" date that matches the admin run sheet days; a customer whose next delivery is not covered sees the red chip with that delivery's date and amount.

---

### W-04 — App checkout uses the reserve function (D-1)

**Target Area:** App

**Objective:** Make the checkout wallet check use the database's reserve (one upcoming delivery per active subscription) instead of its own calculation.

**Exact Implementation Steps:**

1. File `Hetha_app/lib/providers/address_provider.dart`: next to
   `userDailyCommitmentProvider` add
   `userWalletReserveProvider` (`FutureProvider.autoDispose<double>`) that
   calls `rpc('get_wallet_reserve', params: {'p_user_id': authId})` and
   returns `(res as num?)?.toDouble() ?? 0.0`; returns `0.0` when not signed in.
2. File `Hetha_app/lib/screens/checkout/checkout.dart` (≈ lines 416–452):
   delete the line that reads `userDailyCommitmentProvider` into
   `dailyCommitment` and the line that computes `subscriptionReserve` from it
   (Appendix H-10). Replace both with
   `final subscriptionReserve = ref.watch(userWalletReserveProvider).value ?? 0.0;`.
3. Replace the breakdown label (Appendix H-11) with
   `'Kept for the next delivery of your subscriptions'`.
4. Replace the comment above `walletRequired` (Appendix H-12) with
   `// Wallet usable only if it covers the order AND the subscription reserve (one upcoming delivery per active subscription, decided by the database).`
5. Where the screen explains why the wallet cannot be used, the text must say
   the wallet needs to keep enough for the **next delivery** of the customer's
   subscriptions. Remove any wording about several days.
6. If `userDailyCommitmentProvider` has no other user after this, leave it in
   place.

**Acceptance Criteria:** none of Appendix H-10 … H-12 occurs in `lib/screens/checkout/checkout.dart`. Analyzer and tests pass. With one subscription costing ₹100 per delivery and a wallet of ₹250, a ₹150 wallet order is allowed and a ₹151 one is not.

---

### W-05 — App create-subscription screen uses the reserve rule (D-1)

**Target Area:** App

**Objective:** Make the Review step and the pre-submit check show and apply the database's rule: the wallet must cover one upcoming delivery of every active subscription, including the new one.

**Exact Implementation Steps:**

1. File `Hetha_app/lib/screens/subscription/create_subscription_page.dart`.
2. Add state `double? _existingReserve;`. In `_loadWalletInfo`, replace the
   `get_user_daily_commitment` call with
   `rpc('get_wallet_reserve', params: {'p_user_id': userId})` and store the
   result in `_existingReserve` (`(res as num?)?.toDouble() ?? 0.0`). Remove
   `_existingCommitment` if nothing else uses it.
3. In `_buildCostAndWallet` replace the two lines that compute `totalDaily`
   and `required` (Appendix H-13) with:
   `final required = (_existingReserve ?? 0) + perDelivery;`
4. Replace the row label (Appendix H-14) with
   `'Needed to start (next delivery of all your subscriptions)'`.
5. In `_handleCreateSubscription`: replace the `get_user_daily_commitment`
   call with `get_wallet_reserve`; replace the lines computing
   `totalDailyCommitment` and `requiredBalance` (Appendix H-15) with
   `final requiredBalance = existingReserve + newSubDailyCost;`; and replace
   the error text (Appendix H-16) with
   `'Insufficient wallet balance (₹${walletBalance.toStringAsFixed(0)}). You need at least ₹${requiredBalance.toStringAsFixed(0)} to cover the next delivery of all your subscriptions. Please recharge your wallet.'`
6. Update the doc comment at the top of the file and the comment above
   `_loadWalletInfo` (Appendix H-17) to say "the next-delivery wallet requirement".
7. The screen adds the new subscription's cost to the reserve; it does not
   multiply anything.

**Acceptance Criteria:** none of Appendix H-13 … H-17 occurs in the file. With an existing subscription of ₹100 per delivery, a new one of ₹60 and a wallet of ₹160, the screen shows "enough to start" and the database accepts it; with ₹159 both refuse.

---

### W-06 — Admin customer profile uses the forecast

**Target Area:** Admin Panel

**Objective:** Replace "Wallet covers N deliveries" (balance ÷ flat sum) with the forecast, so staff see the same dates the customer sees.

**Exact Implementation Steps:**

1. `Hetha_admin/services/customerService.ts`: add
   `getWalletForecast(supabase, userId)` calling
   `supabase.rpc('get_wallet_forecast', { p_user_id: userId, p_days: 30 })`;
   on error return `null` (do not throw; the profile must still load).
2. Add it to the customer detail fetch (the function that runs four parallel
   queries, ≈ lines 172–198) as a fifth parallel call and include `forecast`
   in the returned object and its type in `lib/types.ts`.
3. `app/admin/customers/[id]/_components/ProfileTab.tsx`: replace the
   `walletCovers(balance, commitment)` stat with:
   - label: `'Wallet covers until'`
   - value: `forecast?.covered_until ? formatDate(forecast.covered_until) : (forecast?.next_delivery_date ? 'Not covered' : '—')`
   - hint + danger tone when `forecast && forecast.next_delivery_covered === false`:
     `` `Next delivery ${formatDate(forecast.next_delivery_date)} (${formatINR(forecast.next_delivery_amount)}) will be skipped unless the customer recharges` ``
   Remove the old hint text (Appendix H-18).
4. Add a second stat `'Kept for next delivery'` = `formatINR(forecast?.reserve ?? 0)`.
5. In `lib/customerSummary.ts` delete `walletCovers` if nothing else imports
   it, and update the comment on `LIVE_SUBSCRIPTION_STATUSES` (Appendix H-19)
   to "same set as the DB's get_user_daily_commitment (the wallet reserve)".
6. `app/admin/customers/[id]/_components/CreateSubscriptionDialog.tsx`:
   replace the wallet note (Appendix H-20) with
   `Wallet subscriptions need the customer's wallet to cover the next delivery of all their subscriptions.`

**Acceptance Criteria:** `tsc`, lint, build pass; `grep -rn "walletCovers" Hetha_admin/app Hetha_admin/lib Hetha_admin/services` returns nothing; none of Appendix H-18 … H-20 occurs in `Hetha_admin/app` or `Hetha_admin/lib`.

---

### W-07M — Manual low-balance notices from Daily Ops (D-3, revised 2026-11-16)

**Target Area:** Database + Admin Panel

**Objective:** Let staff, after Generate, see every customer whose wallet cannot cover their orders on the selected delivery date and send them a low-balance push, choosing exactly who receives it. Nothing is sent automatically.

**Replaces** the earlier W-07 (automatic notice after Finalize) and W-08a–W-08f (configurable evening reminder, scheduler endpoint, `CRON_SECRET`, settings screen, Supabase Cron job). None of those exist in the code; do not build them unless the owner asks for automatic reminders again.

**Exact Implementation Steps (as built):**

1. Migration 039:
   - `public.wallet_notice_log` — one row per `(user_id, delivery_date)`;
     `source` is always `'manual'`; `status` `claimed` → `sent` / `failed`;
     `attempts`, `claimed_by`, `sent_at`, `error`. RLS on, no policies, no grants.
   - `internal.low_balance_customers(p_delivery_date)` — per customer, Σ
     (`total_value − paid_amount`) of their pending, not-held orders on that
     date from wallet subscriptions, against `users.wallet_balance`; only
     customers with required > balance; with `notice_status` from the log.
   - `public.get_low_balance_customers(p_delivery_date)` — `daily_ops:view`.
   - `public.claim_manual_low_balance_notices(p_delivery_date, p_user_ids)` —
     `daily_ops:edit`; claims a log row only for chosen customers who are still
     short now and not already notified (a `failed` row may be claimed again;
     a `claimed` row older than 15 minutes too); returns those rows.
   - `public.mark_wallet_notice_result(...)` — `daily_ops:edit`; `sent` / `failed`.
2. Admin API (`app/api/admin/daily-ops/route.ts`): GET `action=low-balance`;
   POST `action=send-low-balance` `{ date, userIds }` → claim → send
   `notifyLowBalance(user, balance, date, required)` in batches of 20 inside
   the request → mark each → `{ selected, sent, failed, skipped }`.
3. Daily Ops: **Low wallet balance** button (when the day has orders) →
   `LowBalanceModal`: customer, phone, wallet, needed, short by, notified;
   all not-yet-notified rows selected; "Already notified" rows greyed and not
   selectable; **Send to N customers**; result line with sent / failed counts.
4. Finalize sends no low-balance push (the "Delivery skipped: low balance"
   push for orders it skipped is unchanged).

**Acceptance Criteria (tests, section 13 of `verify_money_integrity.mjs`):** a
short customer is listed with balance, required and shortfall; two orders on
the day are added up; covered, cash-on-delivery, skipped, held and
already-charged customers are not listed; a customer cannot read the list or
send; Send claims only chosen customers who are still short; a second Send
claims nothing; a sent customer is never claimed again for that date; a failed
push can be sent again; a customer who recharged after the list was shown is
not sent; no reminder objects exist (`claim_wallet_reminders`,
`wallet_reminder_settings`, …).

---

# PART C — ADMIN PANEL

Each task is independent unless it says otherwise. Findings marked
*(audit)* come from the 2026-11-10 read-only audit; confirm the quoted code
exists before editing.

---

### A-01 — Debounce the Daily Ops realtime refetch

**Target Area:** Admin Panel

**Objective:** Stop one Generate click from triggering a full run-sheet reload per inserted order.

**Exact Implementation Steps:**

1. `app/admin/daily-ops/hooks/useDailyOps.ts`, the realtime `useEffect`
   (search for `event: 'INSERT'`).
2. Add `const refetchTimer = useRef<ReturnType<typeof setTimeout> | null>(null);`
   and `const generatingRef = useRef(false);` near the other refs. Keep
   `generatingRef.current` in sync: set it `true` at the start of
   `handleGenerate` and `false` in its `finally`.
3. Replace the INSERT handler body `fetchOrders();` with:
   ```ts
   if (generatingRef.current) return;          // handleGenerate refetches once itself
   if (refetchTimer.current) clearTimeout(refetchTimer.current);
   refetchTimer.current = setTimeout(() => { fetchOrders(); }, 800);
   ```
4. In the effect cleanup, `if (refetchTimer.current) clearTimeout(refetchTimer.current);`.

**Acceptance Criteria:** with the browser network tab open, Generate on a day with N subscriptions produces at most 2 `action=orders` requests, not N.

---

### A-02 — Fix the render-time state updates in Daily Ops and Deliveries

**Target Area:** Admin Panel

**Objective:** Remove the React error "Cannot update a component while rendering a different component" (`useDailyOps.ts` ≈ line 449) and the per-keystroke re-render of every row.

**Exact Implementation Steps:**

1. `useDailyOps.ts`: delete `initItemDraft` and `initOrderDraft` and their
   entries in the returned object and in `UseDailyOpsReturn`
   (`app/admin/daily-ops/types.ts`).
2. In `fetchOrders`, after `setOrders(data.orders || [])`, seed the drafts once
   from the fetched data:
   ```ts
   const qty: Record<string, string> = {};
   const notes: Record<string, string> = {};
   for (const o of data.orders || []) {
     notes[o.id] = o.tracking_info ?? '';
     for (const it of o.subscription_daily_order_items) {
       qty[it.id] = it.delivered_qty != null ? String(it.delivered_qty) : '';
     }
   }
   setDeliveredQtyDrafts(qty);
   setTrackingInfoDrafts(notes);
   ```
   A stored `0` must seed the box with `'0'`, and a missing quantity with
   `''` (D-7: blank and zero are different).
3. `components/RunSheetTab.tsx`: remove the `initItemDraft(...)` and
   `initOrderDraft(...)` calls made during render and the two props.
   Remove them from `page.tsx` where they are passed.
4. `app/admin/deliveries/page.tsx`: same pattern for `initDeliveryDraft`
   (called during render at ≈ lines 555 and 669). Move the seeding into a
   `useEffect` keyed on `data`:
   seed `deliveryDrafts` for every order of every stop that has no entry yet.
5. Same file ≈ line 547: change `{(isExpanded || true) && (` to
   `{isExpanded && (` and, for printing, add a separate block
   `<div className="hidden print:block">…same body…</div>` rendered only when
   `!isExpanded`. If extracting the body into a small component is needed to
   avoid duplicating JSX, do that and nothing else.

**Acceptance Criteria:** the dev console shows no "Cannot update a component" error when opening Daily Ops and Deliveries; typing in a delivered-quantity box still saves; a saved `0` shows as `0` after reload; printing the Deliveries page still shows every stop.

---

### A-03 — Finalize notifications: batch and bound

**Target Area:** Admin Panel

**Objective:** Avoid thousands of concurrent push calls after finalize that are dropped when the function times out. *(audit)*

**Exact Implementation Steps:**

1. `services/notificationService.ts`: add
   `sendNotificationsInBatches(jobs: Array<() => Promise<unknown>>, size = 20)`
   that runs `jobs` in sequential groups of `size` with
   `await Promise.allSettled(group.map((j) => j()))`.
2. `app/api/admin/daily-ops/route.ts`, `finalize`, `reconcile` and
   `bulk-update-status`: instead of one `after()` per customer, collect the
   push closures into an array and call
   `after(() => sendNotificationsInBatches(jobs));` once. This includes the
   low-balance notices from W-07.
3. Add `export const maxDuration = 60;` to that route file. Check
   `node_modules/next/dist/docs/` for the current name and limits of this
   option before adding it.

**Acceptance Criteria:** `grep -c "after(" app/api/admin/daily-ops/route.ts` is lower than before and each of finalize / reconcile / bulk status calls `after` once. Build passes.

---

### A-04 — Lost notification on admin-created subscription

**Target Area:** Admin Panel

**Objective:** Stop the "subscription created" push from being cut off on Vercel. *(audit)*

**Exact Implementation Steps:**

1. `app/api/admin/subscriptions/route.ts` ≈ line 166: the call
   `sendNotification({ … })` is neither awaited nor wrapped.
2. Import `after` from `next/server` and change it to
   `after(() => sendNotification({ … }));` keeping the arguments unchanged.

**Acceptance Criteria:** the only un-awaited `sendNotification(` in `app/api` is inside an `after(` callback (`grep -rn "sendNotification(" app/api`).

---

### A-05 — One query for the admin permission check

**Target Area:** Admin Panel

**Objective:** Remove two sequential database round trips from every admin API call. *(audit)*

**Exact Implementation Steps:**

1. Read `services/accessControlService.ts` `getCurrentUserPermissions`
   (≈ lines 49–71). It selects `admin_users` then `admin_role_permissions`.
2. Replace the two queries with one embedded select:
   `supabase.from('admin_users').select('is_active, roles ( role, admin_role_permissions ( permission ) )').eq('user_id', userId).maybeSingle()`.
   Confirm the foreign-key names allow this embed; if PostgREST returns an
   ambiguity error, name the relationship explicitly
   (`roles!<fk_name>`); find the name in `docs/db/schema.sql`.
3. Return the same shape as before: `{ permissions: string[] }`, with
   `'super_admin'` included when `roles.role === 'super_admin'`, and `[]` when
   the row is missing or `is_active` is false.
4. `app/api/admin/daily-ops/route.ts`, `unlock`: do not call `requireAdmin`
   a second time; use `auth.permissions.includes('super_admin')` from the
   first call and return the same 403 body when false.

**Acceptance Criteria:** signing in as a super admin and as a role-limited admin still reaches the same pages as before; an inactive admin gets 403. Build passes.

---

### A-06 — Indexes for the hot filters (migration 040)

**Target Area:** Database

**Objective:** Add the indexes the Deliveries page, the paged lists and the wallet forecast need. *(audit)*

**Exact Implementation Steps:**

1. New migration `040_indexes.sql` (functions unchanged):
   ```sql
   CREATE INDEX IF NOT EXISTS idx_orders_expected_delivery_open
     ON public.orders (expected_delivery_date)
     WHERE status NOT IN ('cancelled', 'payment_pending', 'delivered');
   CREATE INDEX IF NOT EXISTS idx_orders_expected_delivery_delivered
     ON public.orders (expected_delivery_date) WHERE status = 'delivered';
   CREATE INDEX IF NOT EXISTS idx_subscriptions_address_id ON public.subscriptions (address_id);
   CREATE INDEX IF NOT EXISTS idx_subscriptions_created_at ON public.subscriptions (created_at DESC);
   CREATE INDEX IF NOT EXISTS idx_subscriptions_user_status ON public.subscriptions (user_id, status);
   CREATE INDEX IF NOT EXISTS idx_users_created_at         ON public.users (created_at DESC);
   CREATE INDEX IF NOT EXISTS idx_addresses_created_at     ON public.addresses (created_at DESC);
   CREATE INDEX IF NOT EXISTS idx_reviews_created_at       ON public.reviews (created_at DESC);
   CREATE INDEX IF NOT EXISTS idx_sdo_user_date ON public.subscription_daily_orders (user_id, delivery_date);
   ```
2. Before adding each, confirm it does not already exist in
   `docs/db/indexes.sql` or a later migration.
3. Add them to `docs/db/indexes.sql`. Add the file to the test list (it only
   needs to apply cleanly, twice).

**Acceptance Criteria:** `npm run verify` → 0 failed, including an `expectOk` re-run of the migration.

---

### A-07 — Address Book: filter in SQL

**Target Area:** Admin Panel

**Objective:** Make search, route and "Unassigned" filters search all addresses, not only the newest 150. *(audit)*

**Exact Implementation Steps:**

1. `services/addressBookService.ts` ≈ lines 110–244. Today it fetches
   `Math.min(limit * 3, 500)` rows (the multiplier here is a page-size
   factor, unrelated to the wallet) and filters in JavaScript.
2. Apply the filters in the query instead:
   - route = `unassigned` → `.is('route_id', null)`;
   - route = a uuid → `.eq('route_id', route)`;
   - area → filter through the route's area with an `!inner` embed on
     `delivery_routes` and `.eq('delivery_routes.area_id', areaId)`;
   - search → sanitize with `sanitizeSearchTerm`, then
     `.or('name.ilike.%term%,phone_number.ilike.%term%,address_line1.ilike.%term%,pincode.ilike.%term%')`.
3. Fetch exactly `limit + 1` rows; `hasMore = rows.length > limit`; return the
   first `limit`.
4. Counts: two separate `select('id', { count: 'exact', head: true })` queries,
   one with `.is('route_id', null)`, one with `.not('route_id', 'is', null)`,
   both with `is_deleted = false`. Run them in `Promise.all` with the page query.
5. Delete the JavaScript filter block.

**Acceptance Criteria:** with more than 150 addresses in a test database, searching for a customer whose address is older than the newest 150 finds them; the Unassigned count equals `SELECT count(*) FROM addresses WHERE route_id IS NULL AND is_deleted = false`.

---

### A-08 — Deliveries page: patch the cache instead of reloading the day

**Target Area:** Admin Panel

**Objective:** Recording one delivery should not refetch every stop. *(audit)*

**Exact Implementation Steps:**

1. `app/admin/deliveries/page.tsx`, `recordMutation.onSuccess` (search for
   `queryClient.invalidateQueries({ queryKey: ['deliveries'] })`).
2. Use `queryClient.setQueryData(['deliveries', date, routeFilter, search, includeDone], (old) => …)`
   to update the one order in place: find it by id in
   `stop.subscription_orders` / `stop.one_time_orders`; set `status` from the
   response and each item's `delivered_qty` from the submitted payload
   (`variables` is the second argument of `onSuccess`).
3. Cancelled orders are hidden on this page (D-8): when the response `status`
   is `cancelled`, remove that order from its stop, and remove the stop if it
   has no orders left. Recompute the summary counts from the remaining stops
   so a cancelled order is not counted as delivered. The order itself is not
   deleted; it stays in the Reconciliation tab and in history.
4. Then call
   `queryClient.invalidateQueries({ queryKey: ['deliveries'], refetchType: 'none' })`
   so other cached filters are marked stale without refetching now.
5. Follow the existing pattern in `app/admin/orders/page.tsx` (search for
   `setQueryData`).

**Acceptance Criteria:** recording a delivery produces one POST and no GET `/api/admin/deliveries` in the network tab; the stop shows as done immediately; recording "nothing delivered" removes the order from the page and it appears as Cancelled in the Reconciliation tab; a page reload shows the same state.

---

### A-09 — Shared reference-data hooks

**Target Area:** Admin Panel

**Objective:** Load routes, areas, products and categories once and share them between screens. *(audit)*

**Exact Implementation Steps:**

1. Create `Hetha_admin/hooks/useDeliveryMeta.ts` exporting
   `useDeliveryMeta()` = `useQuery({ queryKey: ['delivery-meta'], queryFn: () => fetch('/api/admin/daily-ops?action=meta').then(r => { if (!r.ok) throw new Error('Failed to load routes and areas'); return r.json(); }), staleTime: 5 * 60_000 })`.
2. Replace the three separate loaders with it:
   `app/admin/subscriptions/page.tsx` (query key `['routes-and-areas']`),
   `app/admin/addresses/page.tsx` (`['addresses-meta']`),
   `app/admin/daily-ops/hooks/useDailyOps.ts` (the raw
   `fetch('/api/admin/daily-ops?action=meta')` in a `useEffect`).
   Keep each screen's existing variable names (`areas`, `routes`).
3. Wherever a route or area is created, edited or deleted, add
   `queryClient.invalidateQueries({ queryKey: ['delivery-meta'] })`.
4. `CreateOrderDialog.tsx` and `CreateSubscriptionDialog.tsx`
   (`app/admin/customers/[id]/_components/`): move their three `fetch` calls
   into `useQuery` hooks with `staleTime: 5 * 60_000` and keys
   `['products', 'picker']`, `['delivery-areas']`, `['delivery-charges']`;
   show an inline error when a query fails.

**Acceptance Criteria:** opening Subscriptions, then Addresses, then Daily Ops within 5 minutes makes one `action=meta` request; creating a route on one screen shows it on the others without a manual refresh.

---

### A-10 — Customer detail: limit history

**Target Area:** Admin Panel

**Objective:** Stop the customer page loading the customer's entire wallet and order history. *(audit)*

**Exact Implementation Steps:**

1. `services/customerService.ts` ≈ lines 172–198: add `.limit(50)` and an
   explicit `.order(…, { ascending: false })` on `created_at` /
   `placed_at` to the `wallet_transactions` and `orders` queries. Select only
   the columns the tabs render (read `WalletTab.tsx` and `OrdersTab.tsx` to
   list them) instead of `*`.
2. Add two API routes (or query parameters on the existing customer route)
   `?tab=wallet&before=<created_at>` and `?tab=orders&before=<placed_at>`
   returning the next 50.
3. In `WalletTab.tsx` and `OrdersTab.tsx` add a "Load more" button, hidden
   when the last page returned fewer than 50 rows.
4. History is paged, never trimmed: every wallet transaction and every order,
   including cancelled ones and refunds, remains reachable with "Load more"
   (D-8, D-9).

**Acceptance Criteria:** for a customer with more than 50 wallet transactions the first load returns 50 and "Load more" appends the next 50 in the right order with no duplicates, down to the oldest transaction.

---

### A-11 — Search fixes

**Target Area:** Admin Panel

**Objective:** Fix three searches that fail or build oversized requests. *(audit)*

**Exact Implementation Steps:**

1. `services/reviewService.ts` ≈ line 36: remove `id.ilike.%…%` from the
   `.or(...)` filter (a uuid column cannot be matched with `ilike`; the
   comment at `services/orderService.ts` ≈ lines 36–38 explains the same
   problem). If the term is a full uuid (regex
   `/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i`), add
   `id.eq.<term>` instead.
2. `services/dailyOps/overrides.ts` ≈ line 90: pass `search` through
   `sanitizeSearchTerm` (from `@/lib/sanitize`) before interpolating it into
   `.or()`. Return `[]` when the sanitized term is empty.
3. `services/paymentService.ts` ≈ lines 47–58: add `.limit(200)` to the user
   lookup, handle its `error` (throw), and if 200 users matched, return a
   `400` with `'Search is too broad; type more of the name, phone or email'`.
   Same cap and message for `app/api/admin/notifications/devices/route.ts`
   ≈ lines 384–396.
4. In every admin list route that does `parseInt(searchParams.get('limit'))`
   (orders, customers, subscriptions, payments, reviews, addresses, products):
   replace with
   `Math.min(Math.max(Number.parseInt(raw ?? '', 10) || 20, 1), 100)`.
   Put this in `lib/pagination.ts` as `parseLimit(raw: string | null)` and
   use it everywhere.

**Acceptance Criteria:** review search returns results instead of a 500; a search containing `,` or `)` in the override picker returns normally; `?limit=abc` and `?limit=100000` both return at most 100 rows.

---

### A-12 — India date everywhere in the admin

**Target Area:** Admin Panel

**Objective:** Stop "today" rolling over at 05:30 IST.

**Exact Implementation Steps:**

1. Run `grep -rn "toISOString().split('T')\[0\]" Hetha_admin/app Hetha_admin/services Hetha_admin/components Hetha_admin/lib`.
2. For every hit that means "today's business date", replace with
   `todayInIndia()` from `@/lib/deliverySchedule`. Known hits:
   `app/api/admin/daily-ops/route.ts` (GET default `date`),
   `app/api/admin/dashboard/route.ts`,
   `services/subscriptionService.ts` (`removeSubscriptionItem` `today`),
   `app/admin/subscriptions/page.tsx` (two `item_start_date` defaults).
3. Leave untouched any hit that formats an existing timestamp for display or
   storage as a timestamp.

**Acceptance Criteria:** the grep in step 1 returns only lines that are not "today" computations; each remaining hit has a one-line comment saying why.

---

### A-13 — Dashboard: real numbers or none

**Target Area:** Admin Panel

**Objective:** Remove hardcoded charts and trends from the landing page. *(audit)*

**Exact Implementation Steps:**

1. `app/admin/page.tsx` ≈ lines 23–41 and 120–129: delete `weeklyData`,
   `monthlySubscriptions`, the literal trend strings (`'+12.4%'`, `'+8.2%'`)
   and the two chart components that render them. Remove the `recharts`
   imports if nothing else in the file uses them.
2. `app/api/admin/dashboard/route.ts`: check each Supabase result's `error`
   and return 500 with the message when any is set (today failures show as 0).
   Sum wallet credits in SQL: add a `SECURITY DEFINER` function in a small
   migration or use a `select('amount.sum()')` aggregate if the installed
   PostgREST supports it; do not load rows to sum in JavaScript.
3. Any subscription-delivery figure on the dashboard follows P1-02 step 4
   (delivered = `status = 'delivered'`; revenue = `paid_amount`; cancelled
   orders never counted as delivered, D-8).
4. Do not add new charts in this task.

**Acceptance Criteria:** the dashboard shows only numbers that come from the API; `grep -n "12.4\|8.2\|weeklyData" app/admin/page.tsx` returns nothing.

---

### A-14 — Subscriptions page: errors and stale data

**Target Area:** Admin Panel

**Objective:** Show failures and stop slow responses overwriting newer ones. *(audit)*

**Exact Implementation Steps:**

1. `app/admin/subscriptions/page.tsx`: convert `fetchSubscriptions` to
   `useQuery({ queryKey: ['subscriptions', filters…], queryFn })`; in
   `queryFn` throw when `!res.ok` (read `error` from the JSON body).
   Render the query's `error.message` in the existing empty-state area.
2. `handleUpdateSubscription`: on `!res.ok`, `toast.error(data.error || 'Update failed')`.
3. `handleCreateRoute`: after success, `await queryClient.invalidateQueries({ queryKey: ['delivery-meta'] })` (after A-09) or `['routes-and-areas']` (before it).
4. `handleProductSearch`: debounce 300 ms using the existing `useDebounce` hook.

**Acceptance Criteria:** with the API returning 500 (temporarily throw in the route), the page shows the error text instead of the old list.

---

### A-15 — Delivery area screen: cut-off text

**Target Area:** Admin Panel

**Objective:** Keep the cut-off hints accurate after migrations 036–039.

**Exact Implementation Steps:**

1. `app/admin/delivery-areas/DeliveryAreaForm.tsx`, "Cut-off times" section.
   The order cut-off hint was updated on 2026-11-11; verify it still reads
   "After <time> customers can't change, pause or resume tomorrow's delivery…".
2. Add a sentence to the order cut-off hint when set:
   `' Finalize the run sheet after this time.'`
3. Under the section, add one line of help text:
   *(Withdrawn with the automatic reminder, 2026-11-16: no reminder-time help text.)*
4. No logic change.

**Acceptance Criteria:** the hint renders both sentences when a time is set and the "Not set" text otherwise; the help line links or points to Settings.

---

### A-16 — Remove the route-level lock once the database lock exists

**Target Area:** Admin Panel

**Objective:** Have one lock (the database) instead of two that can disagree. Requires P2-05 applied.

**Exact Implementation Steps:**

1. `app/api/admin/daily-ops/route.ts`, PATCH handler: delete the block that
   computes `isStatusAction`, `isDeliveryEntry`, `dateForLock` and returns 403.
2. Keep every action's own input validation, including the delivered-quantity
   validation in `updateDeliveredQty` (whole number from 0 to the ordered
   quantity; zero allowed, D-7).
3. `services/dailyOps/runManagement.ts`: delete `isDateLocked` if no caller
   remains; remove it from the two barrel files.
4. The client stops needing to send `date` in PATCH bodies; leave the field in
   place (harmless) to avoid touching every handler.

**Acceptance Criteria:** on a finalized day, editing a route note still works, entering a delivered quantity (including 0) still works, adding an item shows the database's "This order is finalized…" message, and on a reconciled day a delivered-quantity edit shows "This day is reconciled…".

---

### A-17 — Payment-hold review screen (D-9)

**Target Area:** Admin Panel

**Objective:** Let an authorized person see every order on settlement hold and why, without the SQL Editor, and without any way to charge, retry or release it from the screen.

**Exact Implementation Steps:**

1. `services/dailyOps/orders.ts`: add `getHeldOrders(supabase)` selecting
   `id, delivery_date, user_id, status, payment_status, total_value, paid_amount, settlement_hold_reason, subscriptions ( snapshot_name, snapshot_phone )`
   where `settlement_hold_reason` is not null, ordered by `delivery_date` desc.
   Page it with `fetchAll` (P2-09) ordered by `delivery_date desc, id`.
2. Route: GET `action=held-orders` (permission `daily_ops:view`).
3. `app/admin/daily-ops/page.tsx`: when the count is > 0, show a banner
   `N order(s) are on payment hold and need manual review` that opens a modal
   table with: delivery date, customer, phone, order total, amount charged
   (`paid_amount`), status, payment status, and the hold reason in full.
4. The modal is **read-only**. It must not contain a button that retries a
   payment, changes a status, edits an amount or clears the hold. Add this
   text at the top:
   `These orders are never charged or retried automatically. Review each one against the customer's wallet history. Releasing a hold or collecting an amount is a deliberate manual step by the owner.`
5. Each row links to the customer's page (`/admin/customers/<user_id>`), where
   the wallet history shows the audit trail.
6. Do not write to `settlement_hold_reason` or `paid_amount` from any admin
   code. The release procedure stays the commented SQL in migration 037's
   verification section, run by the owner (O-08).

**Acceptance Criteria:** with a held order in the test database the banner shows its count and the modal lists the reason text; the modal has no control that changes data; `grep -rn "settlement_hold_reason" Hetha_admin --include=*.ts --include=*.tsx` shows only reads (selects, types, rendering).

---

### A-18 — README / CONTRIBUTING / architecture refresh

**Target Area:** Admin Panel + docs

**Objective:** Make the documentation match the confirmed rules: a wallet reserve of one upcoming delivery per active subscription (D-1), strict reconciliation (D-7), manual low-balance notices (D-3), and paging instead of a raised row limit (D-5).

**Exact Implementation Steps:**

1. `Hetha_admin/docs/ARCHITECTURE.md`: replace any description of
   `generateRunSheet` filtering in TypeScript and of reconcile/unlock as API
   writes with pointers to `docs/daily_ops.md` §7 and the SQL functions.
   Replace any description of the old wallet reserve (Appendix H-22) with:
   "The wallet must keep enough for one upcoming delivery of each active
   subscription. The amount comes from `internal.wallet_reserve`; no screen
   or route computes it."
2. `Hetha/docs/ARCHITECTURE.md`:
   - The section headed with the old reserve name (Appendix H-23) and the row
     in the enforcement table (Appendix H-24): retitle to
     "The wallet reserve" and rewrite to the sentence in step 1, adding that
     staff can warn the customer with a manual low-balance notice from Daily Ops
     and that an uncovered order is skipped at finalize.
   - The lines saying the 1000-row cap is handled by a large client limit
     (≈ lines 345–347): replace with "the Data API caps responses at 1000
     rows and that setting is not raised; reads that need every row use
     `lib/fetchAll.ts`, and generation runs in SQL".
3. `Hetha/CLAUDE.md`, "Money integrity" section: replace the reserve bullet
   (Appendix H-25) with
   "**Wallet reserve:** wallet purchases, new subscriptions and day edits must
   leave enough in the wallet for one upcoming delivery of each active
   subscription. `internal.wallet_reserve` is the only definition; the DB
   enforces it and both UIs read it from the DB."
   Add two bullets: one for `internal.settle_daily_order` (the only place
   daily-order money moves), one for reconciliation (blocked until every
   pending item has a delivered quantity).
4. `docs/DATA_MODEL.md`: update the rows for `get_user_daily_commitment`,
   `create_subscription`, `place_order`, `modify_daily_order`,
   `modify_daily_orders_bulk` so they describe the one-delivery reserve and
   name `internal.wallet_reserve`; add rows for the new functions and the two
   new tables from migration 039.
5. `Hetha_admin/docs/daily_ops.md` §7: confirm it states that reconcile is
   blocked until quantities are entered (D-7), that Mark Delivered records
   orders as delivered in full (D-2), that cancelled orders are hidden on
   Deliveries but kept in Reconciliation (D-8), and that held orders are never
   charged automatically (D-9). Describe the manual low-balance notices (W-07M).
6. Do not edit `CHANGES_*.md` files or migration headers: they are the
   historical record and correctly describe the rule as it was at the time.

**Acceptance Criteria:**
- None of the Appendix H strings occurs in `Hetha/docs/ARCHITECTURE.md`,
  `Hetha/docs/DATA_MODEL.md`, `Hetha/CLAUDE.md`, `Hetha_admin/docs/*.md`
  or `Hetha_admin/README.md`.
- `grep -rn "limit(10000)" Hetha/docs Hetha/CLAUDE.md Hetha_admin/docs`
  returns nothing outside `CHANGES_*.md`.
- Each of D-1, D-2, D-3, D-7, D-8, D-9 is stated once in
  `Hetha_admin/docs/daily_ops.md` or `Hetha/docs/ARCHITECTURE.md`.

---

# PART D — CUSTOMER APP

Scope reminder (D-4): the app does not let customers add items to an existing
subscription. No task in this part adds that, and none may.

---

### M-01 — Day edits and pauses follow the database cut-off

**Target Area:** App + Database

**Objective:** Stop the app deciding "can this day still be changed" from the phone's clock; ask the database, which enforces it anyway (migration 036).

**Exact Implementation Steps:**

1. Migration **038** (it is the open migration when this task starts): create
   `public.get_earliest_change_date(p_subscription_id uuid) RETURNS date`:
   `PERFORM internal.assert_subscription_access(p_subscription_id);`
   then `RETURN internal.subscription_earliest_change_date(p_subscription_id);`.
   Grant to `authenticated, service_role`. Test: owner gets tomorrow (no
   cut-off) / day after (cut-off passed); another customer is refused.
2. `Hetha_app/lib/screens/subscription/subscription_page.dart`:
   - Add state `DateTime? _earliestChangeDate;` and a method
     `_loadEarliestChangeDate()` that calls the RPC for the currently shown
     subscription id and stores the parsed date (date only). Call it when the
     page loads, when the selected subscription changes, and on app resume.
     On failure leave it `null`.
   - In `_canChangeOrder` (≈ line 437) replace everything between
     `if (day.isAtSameMomentAs(today)) return false;` and
     `if (!_isDeliveryAvailable(day)) return false;` with:
     ```dart
     final earliest = _earliestChangeDate ?? tomorrow;
     if (day.isBefore(earliest)) return false;
     ```
   - Use `_canChangeOrder(day)` for the pause and resume actions too
     (`_pauseSingleDay`, `_resumeSingleDay`, `_pauseDateRange` start date): if
     it returns false, show a snack bar
     `'Changes for ${DateFormat('MMM d').format(day)} are closed.'` and return
     without calling the service.
3. `subscription_day.dart` ≈ line 694: replace the text
   `'• Before ${_formatCutoffTime(widget.orderCutoffTime)} for the next day\'s order'`
   with `'• Until the order cut-off for that day'`. Remove the
   `orderCutoffTime` constructor parameter and `_formatCutoffTime` if they
   become unused, and remove the argument where the widget is created.
4. Delete `_getOrderCutoffTime` in `subscription_page.dart` if unused.

**Acceptance Criteria:** `flutter analyze` and `flutter test` pass. With a cut-off time set on a test area and passed, tomorrow's day cannot be edited, paused or resumed in the app even if the phone clock is set back; with no cut-off, tomorrow can and today cannot.

---

### M-02 — Readable errors for day edits

**Target Area:** App

**Objective:** Show the database's sentence when a day edit is refused, as already done for pauses, including the new next-delivery wallet message from W-01.

**Exact Implementation Steps:**

1. In `subscription_day.dart` and `bulk_modify_subscription.dart`, find every
   `catch (e)` that shows `e.toString()` or `'… $e'` after calling
   `saveDailyOrder`, `saveDailyOrdersBulk` or `revertDailyOrder` (names in
   `lib/services/subscription_service.dart`).
2. Add to each file:
   ```dart
   String _errorText(String prefix, Object e) =>
       e is PostgrestException ? e.message : '$prefix: $e';
   ```
   and use it for the snack bar / dialog text. Import
   `package:supabase_flutter/supabase_flutter.dart` if not already imported.
3. If `subscription_service.dart` wraps the exception in a new `Exception`
   before rethrowing, change it to `rethrow` so the `PostgrestException`
   reaches the screen.
4. In `subscription_service.dart` and `bulk_modify_subscription.dart`, update
   the comments that describe the old wallet rule (Appendix H-26) to
   "the next-delivery wallet reserve".

**Acceptance Criteria:** forcing a refusal (edit today) shows "The order for 14 Nov 2026 can no longer be changed. The earliest day you can change now is 15 Nov 2026." with no "PostgrestException(" text; raising a day's order beyond the wallet shows the database's "… for the next delivery of your subscriptions plus … extra for this day" message.

---

### M-03 — Show why a delivery was skipped

**Target Area:** App

**Objective:** When finalize skips a delivery for low balance, show that on the calendar and day screen with a Recharge button.

**Exact Implementation Steps:**

1. `lib/models/daily_order.dart`: add `final String? skipReason;` parsed from
   `map['skip_reason']`; add getter
   `bool get skippedForPayment => status == 'skipped' && skipReason != null;`.
2. Add `skip_reason` to the `select(...)` of the two
   `subscription_daily_orders` queries: `subscription_page.dart` ≈ line 367
   and `subscription_day.dart` ≈ line 127.
3. `lib/screens/subscription/widgets/subscription_calendar.dart` ≈ line 223
   (`orderStatus == 'skipped' || orderStatus == 'cancelled'`): pass the skip
   reason into the widget's day data and, when it is non-null, use a red dot /
   marker instead of the grey skipped style. Do not change other statuses.
4. `subscription_day.dart`: when the day's order is `skippedForPayment`, show
   a banner at the top:
   `'This delivery was skipped because your wallet balance was too low. Nothing was charged.'`
   with a button `Recharge wallet` → `Navigator.of(context).pushNamed('/wallet')`.
5. A cancelled day keeps its existing "cancelled" appearance and stays in the
   customer's history (D-8).
6. No write to the order from the app.

**Acceptance Criteria:** with an order skipped by finalize (see `CHANGES_2026-11-13.md` test 2), the app calendar marks that day red and the day screen shows the banner; a staff-skipped order (no `skip_reason`) and a cancelled order look as before.

---

### M-04 — Wallet page forecast

**Target Area:** App

See **W-03**. Listed here so the app task list is complete.

---

### M-05 — Wallet refreshes after a wallet push

**Target Area:** App

**Objective:** Make the wallet balance and forecast update when a wallet push arrives while the app is open (debit, refund, low-balance notice, skipped delivery).

**Exact Implementation Steps:**

1. Read `lib/services/notification_service.dart` foreground handler
   (`FirebaseMessaging.onMessage`).
2. When `message.data['route'] == 'wallet'`, invalidate the wallet balance
   provider (`userWalletBalanceProvider` in `lib/providers/address_provider.dart`)
   and `userWalletReserveProvider` (after W-04). Use the app's existing global
   `ProviderContainer` / ref access pattern in that file; if there is none,
   expose a `ValueNotifier<int> walletRefreshTick` in the service and have
   `walletpage.dart` listen to it and call `_fetchWalletData()`.
3. Do not navigate on a foreground message. Tapping any of these pushes opens
   the Wallet tab through the existing `route: 'wallet'` handling; confirm the
   low-balance push (W-07M) and the skipped-delivery push open it.

**Acceptance Criteria:** with the wallet page open, recording a short delivery in the admin updates the balance within a few seconds without pull-to-refresh; tapping a low-balance push with the app closed opens the Wallet tab.

---

### M-06 — Release build and device tests

**Target Area:** App

**Objective:** Ship the app changes from 2026-11-10 onward and close the open device test.

**Exact Implementation Steps:**

1. Build against **staging** first (D-6): `flutter clean && flutter pub get`,
   then a release APK using the staging env file (O-04). Repeat for
   production only after the staging tests pass.
2. Device test 5 from `CHANGES_2026-11-10.md` §5 (Wi-Fi drop): Orders screen
   open, Wi-Fi off, change an order in the admin, Wi-Fi on → the list updates
   within about 10 s with no pull-to-refresh. Repeat with mobile data on.
3. Cut-off tests from `CHANGES_2026-11-11.md` §5: with a cut-off time set on a
   test area, create a subscription before and after the cut-off (start date
   picker's first day changes), pause tomorrow before and after.
4. Wallet tests (after 039): the create-subscription and checkout screens
   require one upcoming delivery of each subscription (W-04, W-05 acceptance
   numbers); the wallet page shows the forecast (W-03); a low-balance push sent from
   Daily Ops arrives once (W-07M).
5. Record results in the day's `CHANGES_*.md`.

**Acceptance Criteria:** all listed tests recorded as pass, or each failure written down with what was seen.

---

# PART E — BACKEND / REPO HYGIENE

---

### B-01 — Fix `npm run verify:018`

**Target Area:** Backend

**Objective:** Make the migration-018 check pass again (2 failures: `function public.claim_adhoc_user(unknown, unknown, unknown, unknown, unknown) is not unique`).

**Exact Implementation Steps:**

1. Run `grep -n "FUNCTION public.claim_adhoc_user" docs/db/functions.sql docs/db/migrations/*.sql`.
   Expect two overloads in `functions.sql` (one from before migration 032,
   one from it).
2. Read `docs/db/tests/verify_018_drop_legacy_user_columns.mjs` where it calls
   `claim_adhoc_user` with five untyped arguments.
3. Determine from migration 032 which signature is current on live. If 032
   dropped the old overload, remove the stale definition from the
   `functions.sql` snapshot. If both exist on live on purpose, add explicit
   casts to the test's call so it selects the intended one
   (for example `$1::uuid, $2::text, …` matching that signature).
4. Do not change any migration file.

**Acceptance Criteria:** `npm run verify:018` prints no `FAIL`; `npm run verify` still → 0 failed.

---

### B-02 — Re-export the function snapshots

**Target Area:** Backend

**Objective:** Bring `docs/db/functions.sql` and `functions_internal.sql` in line with live after migrations 036–039.

**Exact Implementation Steps:**

1. Follow `docs/db/REFRESH.md` exactly (it gives the export queries).
   The owner runs the export in the SQL Editor and pastes the result; a coding
   agent cannot reach the live database.
2. Replace the two files with the export, keep their header comments, update
   the "current as of migration NNN" note in `REFRESH.md`.
3. Run `npm run verify` and `npm run verify:018` (the suite loads `functions.sql`).

**Acceptance Criteria:** both suites pass; `grep -c "settle_daily_order" docs/db/functions_internal.sql` ≥ 1; `grep -c "wallet_reserve" docs/db/functions_internal.sql` ≥ 1 (after 039).

---

### B-03 — Test runner for the admin panel

**Target Area:** Admin Panel

**Objective:** Give the admin repo a way to keep pure-logic tests (date helpers, `fetchAll`, `parseLimit`), which today have none.

**Exact Implementation Steps:**

1. Add `vitest` as a dev dependency and a script `"test": "vitest run"`.
2. Create `Hetha_admin/lib/__tests__/deliverySchedule.test.ts` with the 12
   cases listed in `CHANGES_2026-11-11.md` §1 (pause first/middle/last day,
   day before/after, start day, end day, month boundary, timestamp value) for
   `toYmd` and `isWithinDays`, plus 4 cases for `isAreaDeliveryDay`
   (frequency 1; frequency 2 on and off day; frequency 2 with no reference date).
3. Add tests for `fetchAll` (P2-09) and `parseLimit` (A-11) when those exist.
4. Add a test for the missing-quantity filter from P1-01 step 2 (extract it as
   a pure function `ordersMissingDeliveredQty(orders)` in
   `app/admin/daily-ops/lib/missingQuantities.ts`): a pending order with a
   blank item is listed; one whose items are all `0` is not; a delivered order
   is not.
5. Add `npm test` to the admin gate list in `Hetha/CLAUDE.md` and
   `Hetha_admin/CONTRIBUTING.md`.

**Acceptance Criteria:** `npm test` passes; `npx tsc --noEmit`, lint and build still pass (exclude test files from the Next build if needed via the vitest config, not by loosening `tsconfig`).

---

# PART F — OWNER STEPS (no code)

Only the owner can do these. Coding agents must not attempt them.

| ID | Step | When |
|---|---|---|
| O-01 | Review and approve Phase 1. Reconcile any day still `finalized` on the deployed panel. Commit. Apply migration 037. Run its verification queries (query 1 lists held orders). Deploy the admin panel. | Now (in progress) |
| O-04 | **Staging (D-6).** (1) Create a second Supabase project. (2) Load the production schema into it (schema-only dump; no customer data) and apply every migration not included in the dump. (3) Deploy the Edge Functions and set their secrets with **test** Razorpay keys. (4) Create a Vercel preview environment for `Hetha_admin` whose `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` point at staging. (5) Add a staging `.env` for the app and build a staging APK. (6) Create test customers, areas, routes. From then on rule §1.3 applies: staging first. | Before applying 038 anywhere; mandatory before onboarding real customers |
| O-02 | Apply migration 038 in staging, test, then production; run its verification queries; deploy the admin panel. | After Parts A0 and A |
| O-03 | Apply migration 039 in staging, test, then production; deploy admin; release the app (W-03 … W-05 need both). | After Part B |
| O-07 | *(Withdrawn 2026-11-16: no reminder scheduler, no `CRON_SECRET`.)* | — |
| O-05 | Supabase → Data API: turn **off** "Automatically expose new tables" after confirming every table the apps use is on the exposed list. Leave "Max rows" at 1000 (D-5). | Any time |
| O-06 | Set an order cut-off time on one delivery area and test before/after it. | After O-02 / O-07 |
| O-08 | **Held orders (D-9).** Review each order on payment hold (verification query 1 of migration 037, or the hold list from A-17) against the customer's wallet history. Decide per order whether to leave it, write it off, or collect by agreement with the customer. Releasing a hold is the commented SQL in migration 037; run it only after that review. Nothing is collected automatically. | After O-01, at the owner's pace |

---

## Appendix H — Old-rule text to find and remove (historical)

**Everything in this appendix is the OLD wallet rule.** It is listed only so
an implementer can find the exact text to delete or replace. None of it is an
instruction to implement. After the tasks that reference an entry are done,
that text must no longer exist in the named file.

| ID | File | Old text to find |
|---|---|---|
| H-1 | migration 036 body of `internal.create_subscription_core` | `v_required := round((v_existing_daily + v_new_daily) * 3, 2);` |
| H-2 | newest body of `internal.place_order_core` | `v_reserve    := round(v_commitment * 3, 2);` |
| H-3 | migration 025 body of `internal.modify_daily_order_core` | `v_required  := round(v_committed * 3 + v_extra, 2);` |
| H-4 | migration 027 body of `internal.modify_daily_orders_bulk_core` | `v_required  := round(v_committed * 3 + v_total_extra, 2);` |
| H-5 | `create_subscription_core` error message | `'Insufficient wallet balance (%). You need at least % (3 days x %/day for all subscriptions).'` |
| H-6 | `place_order_core` error message | `'Insufficient wallet balance. Required: % (order %) plus % reserved for 3 days of subscriptions, available: %'` |
| H-7 | `modify_daily_order_core` error message | `'… You need at least % (3 days of your subscriptions, %/day, plus % extra for this day).'` |
| H-8 | `modify_daily_orders_bulk_core` error message | `'… (3 days of your subscriptions, %/day, plus % extra across % day(s) in this batch).'` |
| H-9 | `docs/db/tests/verify_money_integrity.mjs` | JavaScript expressions of the form `commitment * 3`, `(commitment + 400) * 3`, and test names containing `3-day` or `3 ×` |
| H-10 | `Hetha_app/lib/screens/checkout/checkout.dart` | `final subscriptionReserve = dailyCommitment * 3; // 3-day buffer for subscriptions` |
| H-11 | same file | `'Subscription reserve (3 days)'` |
| H-12 | same file | `// Wallet usable only if it covers the order AND preserves 3-day subscription reserve` |
| H-13 | `Hetha_app/lib/screens/subscription/create_subscription_page.dart` | `final required = totalDaily * 3;` |
| H-14 | same file | `'Needed to start (3 days of all subscriptions)'` |
| H-15 | same file | `final requiredBalance = totalDailyCommitment * 3;` |
| H-16 | same file | `'(3 days × ₹${totalDailyCommitment.toStringAsFixed(0)}/day for all subscriptions). '` |
| H-17 | same file | comments containing `3-day wallet requirement`, `"3 days of all subscriptions"`, `require 3 days of TOTAL daily commitment` |
| H-18 | `Hetha_admin/app/admin/customers/[id]/_components/ProfileTab.tsx` | `'Below the 3-day reserve — needs a top-up'` and the `covers < 3` comparisons |
| H-19 | `Hetha_admin/lib/customerSummary.ts` | comment `get_user_daily_commitment (the 3-day wallet rule)` |
| H-20 | `Hetha_admin/app/admin/customers/[id]/_components/CreateSubscriptionDialog.tsx` | `3 days of total daily commitment` |
| H-21 | `Hetha_admin/app/api/admin/daily-ops/route.ts` | `user.wallet_balance < dailyCost * 3` and the comment `fewer than 3 more days like today` |
| H-22 | `Hetha_admin/docs/ARCHITECTURE.md` | any sentence describing a `3-day` wallet rule or buffer |
| H-23 | `Hetha/docs/ARCHITECTURE.md` | heading `### The 3-day buffer rule` and its paragraph |
| H-24 | same file | table row `| 3-day buffer | Enforced in place_order and create_subscription (was UI-only) |` |
| H-25 | `Hetha/CLAUDE.md` | bullet beginning `**3-day buffer rule:**` |
| H-26 | `Hetha_app/lib/services/subscription_service.dart`, `lib/screens/subscription/bulk_modify_subscription.dart` | comments containing `3-day wallet buffer` / `wallet's 3-day buffer` |

To check that the old rule is gone from the code and living documentation
(change logs and migration headers are historical and exempt):

```
grep -rnE "\* 3\b|3 days|3-day|three deliveries" \
  Hetha_admin/app Hetha_admin/services Hetha_admin/lib Hetha_admin/docs \
  Hetha_app/lib \
  Hetha/docs/ARCHITECTURE.md Hetha/docs/DATA_MODEL.md Hetha/CLAUDE.md \
  Hetha/docs/db/migrations/039_wallet_simplification.sql
```

Expected: no wallet-related hit. (Unrelated uses such as a page-size factor in
`addressBookService.ts` or "Every 3 Days" delivery frequency wording are not
the wallet rule; each remaining hit must be one of those and be explainable.)

---

## Appendix — where things are

| Thing | Location |
|---|---|
| Money primitives | `docs/db/functions_internal.sql`, migrations 007, 012, 037 |
| Daily Ops services | `Hetha_admin/services/dailyOps/*.ts`, barrel `services/dailyOpsService.ts` |
| Daily Ops API | `Hetha_admin/app/api/admin/daily-ops/route.ts` (+ `export/`, `sheets/`) |
| Daily Ops UI | `Hetha_admin/app/admin/daily-ops/` (`hooks/useDailyOps.ts`, `components/*.tsx`) |
| Deliveries | `Hetha_admin/services/deliveriesService.ts`, `app/api/admin/deliveries/route.ts`, `app/admin/deliveries/page.tsx` |
| Settings screen | `Hetha_admin/app/admin/settings/page.tsx` (password only) |
| Notifications | `Hetha_admin/services/notificationService.ts`; service-role client `Hetha_admin/lib/admin-client.ts` |
| Date helpers | `Hetha_admin/lib/deliverySchedule.ts` |
| App wallet | `Hetha_app/lib/screens/wallet/walletpage.dart`, `lib/providers/address_provider.dart` |
| App subscriptions | `Hetha_app/lib/screens/subscription/*.dart`, `lib/services/subscription_service.dart`, `lib/services/pause_service.dart` |
| DB tests | `Hetha/docs/db/tests/verify_money_integrity.mjs` (sections 1–11 exist; 12 = Phase 2, 13 = wallet and reminder) |
| Change logs | `Hetha/CHANGES_YYYY-MM-DD.md` |
