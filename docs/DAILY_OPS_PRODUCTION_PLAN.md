# Daily Operations — Production-Grade System Plan

## Executive Summary

**Problem:** The client currently manages daily subscription deliveries using
Excel sheets because the existing admin panel's daily-ops module lacks trust —
no clear finalization workflow, no proper rider-specific printable sheets, and no
guarantee that the data won't shift after it's been acted upon.

**Goal:** Build a production-grade daily operations system where:
1. An admin clicks "Generate" for a date → all eligible subscriptions become concrete orders
2. The list is reviewable, editable, and filterable
3. At a defined point, the list is **finalized** (locked) — no more changes
4. Per-rider printable delivery sheets are generated (replacing the Excel handoff)
5. Post-delivery reconciliation (delivered qty, notes) is captured
6. Wallet deduction happens atomically at finalization
7. The entire flow is auditable and never loses data

---

## Current State Assessment

What **already exists** and works:
- ✅ `generateRunSheet()` — applies all filter layers (active, cutoff, pauses, frequency, end-date, item dates)
- ✅ Smart sync — re-generation deletes only "clean" unmodified orders
- ✅ Order viewing with area/route/search/status filters
- ✅ Add/remove items, delivered qty tracking, tracking notes
- ✅ Custom route override per order
- ✅ Basic print (opens a new window with all visible orders in one table)
- ✅ Live status with area/route product aggregation

What's **missing or broken** (why client doesn't trust it):
- ❌ **No finalization workflow** — `is_finalized` column exists but there's no "Finalize All" action, no lock enforcement, no cutoff deadline
- ❌ **No wallet deduction on finalize** — the pg_cron job was never deployed; wallet charges aren't happening
- ❌ **No per-rider sheets** — current print dumps everything into one big table
- ❌ **No delivery-date locking** — after generation, admins can accidentally regenerate and lose modifications
- ❌ **No status transitions enforcement** — any order can jump to any status
- ❌ **No Excel/CSV export** — client wants familiar spreadsheet format too
- ❌ **No audit trail for daily ops** — who generated, who finalized, when
- ❌ **No bulk status update** — marking 50 orders as "delivered" one by one is painful

---

## System Design

### Phase 1: Finalization & Locking (The Core Trust Layer)

This is what makes the client stop using Excel — once finalized, the data is **frozen**.

#### 1.1 State Machine for a Day's Run Sheet

```
         ┌──────────┐     Generate      ┌──────────┐      Finalize      ┌───────────┐
         │  EMPTY   │ ─────────────────► │  DRAFT   │ ──────────────────► │ FINALIZED │
         └──────────┘                    └──────────┘                     └───────────┘
                                              │                                 │
                                              │ Re-generate                     │ (no going back
                                              │ (only clean orders              │  unless super_admin
                                              │  are replaced)                  │  unlocks)
                                              ▼                                 │
                                         ┌──────────┐                           │
                                         │  DRAFT   │                           │
                                         └──────────┘                           │
                                                                                ▼
                                                                          ┌───────────┐
                                                                          │ DELIVERED │
                                                                          └───────────┘
                                                                          (end-of-day
                                                                           reconciliation
                                                                           complete)
```

#### 1.2 New Table: `daily_ops_runs`

Track the overall state of a day's operations (not per-order, but per-date):

```sql
CREATE TABLE daily_ops_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_date date UNIQUE NOT NULL,
  status text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'finalized', 'reconciled')),
  generated_at timestamp,
  generated_by uuid REFERENCES admin_users(user_id),
  finalized_at timestamp,
  finalized_by uuid REFERENCES admin_users(user_id),
  reconciled_at timestamp,
  reconciled_by uuid REFERENCES admin_users(user_id),
  total_orders integer DEFAULT 0,
  total_value numeric DEFAULT 0,
  wallet_deduction_completed_at timestamp,
  notes text,
  created_at timestamp DEFAULT now(),
  updated_at timestamp DEFAULT now()
);

-- RLS
ALTER TABLE daily_ops_runs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "daily_ops_runs_admin_policy" ON daily_ops_runs
  FOR ALL USING (is_super_admin() OR has_permission('daily_ops:view'))
  WITH CHECK (is_super_admin() OR has_permission('daily_ops:edit'));
```

#### 1.3 Finalization Logic (New RPC)

```sql
CREATE OR REPLACE FUNCTION finalize_daily_run(
  p_delivery_date date,
  p_admin_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_run_id uuid;
  v_order record;
  v_total_deducted numeric := 0;
  v_deduction_errors jsonb := '[]'::jsonb;
  v_orders_finalized integer := 0;
BEGIN
  -- 1. Get or create the run record
  INSERT INTO daily_ops_runs (delivery_date, status, generated_by)
  VALUES (p_delivery_date, 'draft', p_admin_id)
  ON CONFLICT (delivery_date) DO NOTHING;

  SELECT id, status INTO v_run_id
  FROM daily_ops_runs WHERE delivery_date = p_delivery_date;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Run record not found for %', p_delivery_date;
  END IF;

  -- 2. Cannot finalize if already finalized
  IF (SELECT status FROM daily_ops_runs WHERE id = v_run_id) = 'finalized' THEN
    RAISE EXCEPTION 'This date is already finalized';
  END IF;

  -- 3. Lock all pending orders for this date
  UPDATE subscription_daily_orders
  SET is_finalized = true,
      finalized_at = now(),
      finalized_by = p_admin_id::text
  WHERE delivery_date = p_delivery_date
    AND status = 'pending'
    AND is_finalized = false;

  GET DIAGNOSTICS v_orders_finalized = ROW_COUNT;

  -- 4. Deduct wallet for each finalized order (wallet payment_method subs)
  FOR v_order IN
    SELECT sdo.id, sdo.user_id, sdo.total_value, s.payment_method
    FROM subscription_daily_orders sdo
    JOIN subscriptions s ON s.id = sdo.subscription_id
    WHERE sdo.delivery_date = p_delivery_date
      AND sdo.is_finalized = true
      AND sdo.payment_status = 'pending'
      AND s.payment_method = 'wallet'
  LOOP
    BEGIN
      -- Use the existing wallet RPC for atomic deduction
      PERFORM update_wallet_balance(
        v_order.user_id,
        v_order.total_value,
        'debit',
        'Subscription delivery ' || p_delivery_date::text,
        p_admin_id::text
      );
      
      UPDATE subscription_daily_orders
      SET payment_status = 'paid',
          wallet_deducted_at = now()
      WHERE id = v_order.id;

      v_total_deducted := v_total_deducted + v_order.total_value;

    EXCEPTION WHEN OTHERS THEN
      -- Wallet insufficient or other error — mark but don't fail the whole batch
      v_deduction_errors := v_deduction_errors || jsonb_build_object(
        'order_id', v_order.id,
        'user_id', v_order.user_id,
        'amount', v_order.total_value,
        'error', SQLERRM
      );

      UPDATE subscription_daily_orders
      SET payment_status = 'failed'
      WHERE id = v_order.id;
    END;
  END LOOP;

  -- 5. Update the run record
  UPDATE daily_ops_runs
  SET status = 'finalized',
      finalized_at = now(),
      finalized_by = p_admin_id,
      total_orders = v_orders_finalized,
      total_value = v_total_deducted,
      wallet_deduction_completed_at = now(),
      updated_at = now()
  WHERE id = v_run_id;

  RETURN jsonb_build_object(
    'finalized', v_orders_finalized,
    'total_deducted', v_total_deducted,
    'deduction_errors', v_deduction_errors
  );
END;
$$;
```

#### 1.4 Lock Enforcement

After finalization, **no edits** to that date's orders (except super_admin unlock):

**In the API route (PATCH handler):**
```typescript
// Before any edit operation, check if the date is finalized
const { data: run } = await supabase
  .from('daily_ops_runs')
  .select('status')
  .eq('delivery_date', body.date || body.deliveryDate)
  .single();

if (run?.status === 'finalized') {
  return NextResponse.json(
    { error: 'This date is finalized. No edits allowed.' },
    { status: 403 }
  );
}
```

---

### Phase 2: Per-Rider Delivery Sheets (Replacing Excel)

This is what the riders carry in their hands.

#### 2.1 Route-Based Sheet Generation

Each rider is assigned a **route**. The system generates one sheet per route.

**Sheet layout (A4, landscape, optimized for clipboard):**

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  HETHA ORGANICS — Delivery Sheet                                            │
│  Date: 28 Jun 2026  |  Route: Noida Sector 62-63  |  Rider: ___________    │
│  Total Deliveries: 23  |  Total Value: ₹4,580                              │
├────┬──────────────────┬────────────┬─────────────────────────┬──────────────┤
│ #  │ Customer         │ Phone      │ Address                 │ Items        │
│    │                  │            │                         │              │
├────┼──────────────────┼────────────┼─────────────────────────┼──────────────┤
│ 1  │ Rajesh Kumar     │ 9876543210 │ B-42, Sector 62, Noida  │ Cow Milk 1L  │
│    │                  │            │                         │ ×2           │
│    │                  │            │                         │ Curd 500g ×1 │
├────┼──────────────────┼────────────┼─────────────────────────┼──────────────┤
│ 2  │ ...              │            │                         │              │
├────┴──────────────────┴────────────┴─────────────────────────┴──────────────┤
│ □ Delivered  □ Not available  □ Returned       Signature: _________________ │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### 2.2 Implementation: Server-Side PDF Generation

Use **`@react-pdf/renderer`** (or `pdfmake`) on the server to generate
print-ready PDFs per route:

**New API endpoint:** `POST /api/admin/daily-ops/sheets`

```typescript
// Request
{ date: "2026-06-28", routes: ["route-uuid-1", "route-uuid-2"] }
// or
{ date: "2026-06-28", area: "Noida" } // all routes in area

// Response: PDF blob (Content-Type: application/pdf)
// or ZIP of multiple PDFs (one per route)
```

**Key design decisions:**
- Generate from **finalized** data only (sheets should never be printed from draft state)
- Include a QR code on each sheet linking back to that route's day view in the admin panel
- Sort orders by address proximity (or predefined sequence in `delivery_routes`)
- Checkbox column for manual tick-off during delivery
- Summary section at bottom: total items by product (so rider knows total load)

#### 2.3 Excel/CSV Export (Parallel Option)

For clients who still want a spreadsheet:

**New API endpoint:** `GET /api/admin/daily-ops/export?date=2026-06-28&format=csv&route=...`

Returns a CSV with columns: `#, Customer, Phone, Address, Route, Items, Qty, Amount, Status`

Use `xlsx` (SheetJS) for proper `.xlsx` if needed — lightweight, no native deps.

---

### Phase 3: Complete Operational Workflow

#### 3.1 The Day-in-the-Life Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  PREVIOUS EVENING (after cutoff, e.g., 4:30 PM)                            │
│                                                                              │
│  1. Admin opens Daily Ops → selects TOMORROW's date                         │
│  2. Clicks "Generate Run Sheet"                                             │
│     → System applies all filters, creates subscription_daily_orders          │
│     → Status: DRAFT                                                          │
│  3. Admin reviews orders, makes last-minute changes                         │
│     (add/remove items, skip a customer, change route)                       │
│  4. Views "Live Status" tab for procurement planning                        │
│     (total milk needed, area breakdown)                                      │
│                                                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│  EARLY MORNING (before riders leave, e.g., 5:00 AM)                         │
│                                                                              │
│  5. Admin clicks "FINALIZE" → system locks all orders + deducts wallets     │
│     → Status: FINALIZED                                                      │
│     → Deduction errors (insufficient balance) are flagged                    │
│  6. Admin clicks "Print Route Sheets"                                        │
│     → Downloads/prints per-rider PDF sheets                                  │
│  7. Sheets are handed to riders                                              │
│                                                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│  DURING DELIVERY (morning)                                                   │
│                                                                              │
│  8. Riders deliver using physical sheets                                     │
│  9. (Optional) Admin can view real-time status on the panel                  │
│                                                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│  POST-DELIVERY (afternoon)                                                   │
│                                                                              │
│  10. Riders return sheets. Admin enters reconciliation:                       │
│      - Bulk mark "delivered" (select all → mark delivered)                   │
│      - Mark exceptions: "not available", "returned", partial delivery         │
│      - Enter delivered_qty where different from requested                     │
│      - Add tracking notes                                                    │
│  11. Admin clicks "Complete Reconciliation"                                   │
│      → Status: RECONCILED                                                    │
│      → Partial deliveries trigger wallet credit (refund difference)           │
│      → Audit log entry                                                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### 3.2 Bulk Operations (Critical for Efficiency)

```typescript
// New API actions for PATCH /api/admin/daily-ops
{ action: 'bulk-update-status', orderIds: [...], status: 'delivered' }
{ action: 'finalize-date', date: '2026-06-28' }
{ action: 'reconcile-date', date: '2026-06-28' }
{ action: 'unlock-date', date: '2026-06-28' }  // super_admin only
```

#### 3.3 UI Changes to Daily Ops Page

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Daily Operations                                   [28 Jun 2026 ▼]         │
│                                                                              │
│  Status: ● DRAFT (not yet finalized)                                        │
│  ┌──────────────────────────────────────────────────────────────────┐       │
│  │ [Generate] [Finalize ⚠] [Print Sheets ▼] [Export CSV] [Refresh] │       │
│  └──────────────────────────────────────────────────────────────────┘       │
│                                                                              │
│  [Run Sheet] [Live Status] [Reconciliation]     ← 3 tabs now                │
│                                                                              │
│  Filters: [Area ▼] [Route ▼] [Status ▼] [Search___________]                │
│                                                                              │
│  ┌─ Summary Bar ──────────────────────────────────────────────────┐         │
│  │ 45 orders | ₹12,340 total | 38 pending | 5 delivered | 2 skip │         │
│  └────────────────────────────────────────────────────────────────┘         │
│                                                                              │
│  ☐ Select All                                [Bulk: Mark Delivered ▼]       │
│  ┌──────────────────────────────────────────────────────────────────┐       │
│  │ ☐ Rajesh Kumar | 9876... | Sector 62 | Cow Milk 1L ×2 | ₹120  │       │
│  │ ☐ Priya Singh  | 8765... | Sector 63 | Toned Milk 500ml ×1    │       │
│  │ ...                                                              │       │
│  └──────────────────────────────────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### Phase 4: Wallet Deduction & Financial Integrity

#### 4.1 Deduction Strategy

**Decision: Deduct at finalization time (not via pg_cron).**

Reasons:
- Gives the admin full control and visibility
- Errors (insufficient balance) are surfaced immediately in the UI
- No mystery "overnight deduction" the client can't trace
- Admin sees a clear report: "45 wallets charged, 3 failed (insufficient funds)"

#### 4.2 Handling Insufficient Balance

When a wallet deduction fails:
1. The order is still marked as finalized (it will still be delivered)
2. `payment_status` = `'failed'`
3. A badge appears on the order: "⚠ Payment failed"
4. The customer's account accumulates a debt (negative commitment)
5. Next wallet recharge triggers a sweep of unpaid orders (future enhancement)

For now: flag it, deliver anyway (client's business decision — milk can't be undelivered), collect payment later.

#### 4.3 Partial Delivery Refunds

During reconciliation, if `delivered_qty < quantity`:
```
refund_amount = (quantity - delivered_qty) × unit_price
```
Automatically credit the difference back to the wallet with description:
`"Partial delivery refund — {date}"`

---

### Phase 5: Data Integrity & Safety

#### 5.1 Idempotent Generation

The current "smart sync" approach is good but needs hardening:

```typescript
// RULE: Never delete an order that has been:
// - finalized (is_finalized = true)
// - modified by admin (has adhoc items, custom route, tracking, delivered_qty)
// - status !== 'pending'
//
// Only regeneration of CLEAN, UNMODIFIED, PENDING orders is allowed.
// This is already implemented ✓ — just needs a unit test.
```

#### 5.2 Unique Constraint Protection

Already exists: `uq_sdo_subscription_date` on `(subscription_id, delivery_date)`
— prevents duplicate orders for the same subscription on the same day. ✓

#### 5.3 Audit Logging

Every significant action writes to `audit_logs`:

| Action | Data |
|--------|------|
| `daily_ops:generate` | `{ date, generated: N, skipped: N }` |
| `daily_ops:finalize` | `{ date, finalized: N, deducted: ₹X, errors: [...] }` |
| `daily_ops:reconcile` | `{ date, delivered: N, partial: N, skipped: N }` |
| `daily_ops:unlock` | `{ date, reason: "..." }` |
| `daily_ops:edit_item` | `{ order_id, item_id, change: "..." }` |

#### 5.4 Concurrency Protection

- Finalization uses `SELECT ... FOR UPDATE` (via the RPC) to prevent double-finalize
- The `daily_ops_runs` unique date constraint prevents race conditions
- Client-side: disable the Finalize button immediately on click, show progress

---

### Phase 6: Delivery Schedule Exceptions

Handle holidays, off-days, and special schedules:

```
delivery_schedule_exceptions table already exists:
  area_id, reference_date, exception_type, note
```

During generation, add a check:
```typescript
// If target_date has an exception for this area → skip all subs in that area
const { data: exceptions } = await supabase
  .from('delivery_schedule_exceptions')
  .select('area_id, exception_type')
  .eq('reference_date', targetDate);

const blockedAreaIds = new Set(
  exceptions?.filter(e => e.exception_type === 'no_delivery').map(e => e.area_id) || []
);
```

---

## Implementation Roadmap

### Sprint 1 (Week 1-2): Foundation — Finalization & Locking

| # | Task | Type |
|---|------|------|
| 1 | Create `daily_ops_runs` table + RLS | Migration |
| 2 | Create `finalize_daily_run` RPC | Migration |
| 3 | Add `POST { action: 'finalize' }` to daily-ops API route | Backend |
| 4 | Add lock check to all PATCH operations | Backend |
| 5 | Add "Finalize" button + confirmation modal to UI | Frontend |
| 6 | Show day status badge (Draft/Finalized/Reconciled) | Frontend |
| 7 | Add audit log writes to generate + finalize | Backend |
| 8 | Add `delivery_schedule_exceptions` check to generation | Backend |

### Sprint 2 (Week 2-3): Rider Sheets & Export

| # | Task | Type |
|---|------|------|
| 9 | Install `pdfmake` (lightweight, no native deps) | Dep |
| 10 | Create `POST /api/admin/daily-ops/sheets` — per-route PDF | Backend |
| 11 | Design print-optimized sheet layout (A4 landscape) | Design |
| 12 | Add "Print Route Sheets" dropdown (per-route or all) | Frontend |
| 13 | Add CSV export endpoint | Backend |
| 14 | Add "Export CSV" button | Frontend |
| 15 | Product summary section on each sheet (loading manifest) | Backend |

### Sprint 3 (Week 3-4): Reconciliation & Bulk Ops

| # | Task | Type |
|---|------|------|
| 16 | Add "Reconciliation" tab to UI | Frontend |
| 17 | Bulk select + mark delivered | Frontend + Backend |
| 18 | Partial delivery → auto wallet credit | Backend (RPC) |
| 19 | `POST { action: 'reconcile' }` — marks day complete | Backend |
| 20 | Failed payment badge + report view | Frontend |
| 21 | Super-admin "Unlock" flow | Backend + Frontend |

### Sprint 4 (Week 4-5): Polish & Safety

| # | Task | Type |
|---|------|------|
| 22 | Unit tests for generation logic edge cases | Test |
| 23 | Integration test: generate → edit → finalize → reconcile | Test |
| 24 | Loading states, error boundaries, optimistic UI | Frontend |
| 25 | Mobile-responsive reconciliation view | Frontend |
| 26 | Notification to customers on wallet deduction failure | Future |
| 27 | Historical view: browse past days' run sheets (read-only) | Frontend |

---

## API Design (Complete)

### Existing (keep as-is)
```
GET  /api/admin/daily-ops?action=orders&date=...&area=...&route=...&search=...&status=...
GET  /api/admin/daily-ops?action=live-status&date=...
GET  /api/admin/daily-ops?action=meta
POST /api/admin/daily-ops  { action: 'generate', date }
PATCH /api/admin/daily-ops { action: 'update-order'|'remove-item'|'add-item'|... }
```

### New Endpoints
```
POST  /api/admin/daily-ops         { action: 'finalize', date }
POST  /api/admin/daily-ops         { action: 'reconcile', date }
POST  /api/admin/daily-ops         { action: 'unlock', date }  (super_admin)
PATCH /api/admin/daily-ops         { action: 'bulk-update-status', orderIds: [...], status }

GET   /api/admin/daily-ops/run?date=...           → day run status
POST  /api/admin/daily-ops/sheets  { date, routes?, area? }  → PDF
GET   /api/admin/daily-ops/export?date=...&format=csv|xlsx&route=...  → file
```

---

## Permission Model

| Action | Permission Key | Who |
|--------|---------------|-----|
| View run sheet | `daily_ops:view` | All staff |
| Generate | `daily_ops:edit` | Ops manager |
| Edit orders | `daily_ops:edit` | Ops manager |
| Finalize | `daily_ops:finalize` | Senior ops / super_admin |
| Unlock finalized day | `daily_ops:admin` | super_admin only |
| Print/Export | `daily_ops:view` | All staff |
| Reconcile | `daily_ops:edit` | Ops manager |

Add to `lib/constants.ts`:
```typescript
'daily_ops:finalize',
'daily_ops:admin',
```

---

## Edge Cases & Failure Modes

| Scenario | Handling |
|----------|----------|
| Admin generates twice for same date | Idempotent: only creates new orders for subs not already present |
| Subscription created after generation but before finalization | Next "Generate" click picks it up (smart sync preserves edits) |
| Customer adds pause after generation but before finalization | ⚠ Not auto-detected. Admin should re-generate or manually skip. Consider adding a "Refresh from subs" action. |
| Wallet balance = 0 at finalization | Order still finalized + delivered. Payment marked `failed`. Debt tracked. |
| Rider returns undelivered items | Admin marks order as `skipped` or `cancelled` → wallet refund triggered |
| Two admins finalize simultaneously | DB unique constraint on `daily_ops_runs.delivery_date` + `SELECT FOR UPDATE` in RPC prevents double-finalize |
| Network failure mid-finalization | RPC is transactional — either all locks + deductions succeed or none do (per-order TXN with error capture) |
| Customer cancels subscription after finalization | Already snapshotted — delivery happens. Cancellation takes effect next day. |
| Holiday/exception day | Generation skips areas with `no_delivery` exception for that date |

---

## Migration Checklist

Before deploying:

- [ ] Run `daily_ops_runs` table migration
- [ ] Deploy `finalize_daily_run` RPC
- [ ] Add new permission keys to `admin_role_permissions` for existing roles
- [ ] Test wallet deduction with real subscription data (staging)
- [ ] Verify `update_wallet_balance` RPC handles the `CHECK (>= 0)` constraint gracefully (it should raise an exception that we catch)
- [ ] Update `Hetha_admin/docs/schema.sql` mirror
- [ ] Update this document's status after each sprint

---

## Success Criteria (How the Client Knows It Works)

1. **No more Excel.** The printed rider sheet has everything the Excel had + more.
2. **Trust.** Once finalized, data cannot change. What was printed = what the system shows.
3. **Speed.** Generate → Review → Finalize → Print takes < 5 minutes for 100 orders.
4. **Money is right.** Wallet deductions happen exactly once, at a predictable time, with a clear audit trail.
5. **Exceptions are visible.** Failed payments, partial deliveries, and skipped orders are surfaced prominently — not hidden.
6. **History.** Any past day's run sheet can be viewed exactly as it was finalized.
