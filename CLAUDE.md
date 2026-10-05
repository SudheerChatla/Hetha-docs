# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Layout: three git repos, one backend

Hetha Organics is an organic grocery/dairy delivery business on a prepaid-wallet, daily-subscription model.

- **This repo (`Hetha/`)** holds only shared docs, the canonical database SQL, and the dated change logs. `Hetha_app/` and `Hetha_admin/` are listed in `.gitignore`. Each is its **own git repo** with its own history, commits, and pushes.
  - `Hetha_app/`: customer app (Flutter, Riverpod, `supabase_flutter`, Razorpay).
  - `Hetha_admin/`: staff operations panel (Next.js 16 App Router, React 19, TS, Tailwind 4, TanStack Query). Pushing to `main` auto-deploys it (Vercel).
- Both clients talk to **one Supabase project**. The app uses the anon key under RLS. The admin panel also uses a server-only service-role client and an internal RBAC layer (`has_permission`, permissions like `orders:edit`).
- `Hetha_admin/CLAUDE.md` points to its `AGENTS.md`, which says this Next.js version has breaking changes. Read the guide in `Hetha_admin/node_modules/next/dist/docs/` before writing admin code.
- `*_new_design/` and `stitch_product_detail_interface/` are static design references (HTML + screenshots), not running code.

## Commands

```bash
# Money-path DB regression suite (PGlite, in-memory Postgres; never touches live DB)
cd docs/db/tests && npm install && npm run verify
npm run verify:018          # separate check for migration 018

# Customer app (in Hetha_app/)
flutter pub get && flutter run      # -d chrome for web
flutter analyze
flutter test                        # single file: flutter test test/<path>_test.dart

# Admin panel (in Hetha_admin/)
npm run dev                         # localhost:3000
npx tsc --noEmit && npm run lint && npm run build
```

Before calling work done, run the gates for whatever you touched: the DB suite, `flutter analyze` and `flutter test`, and the admin `tsc`, lint, and build.

Env files: `Hetha_app/.env` holds `PROJECT_URL` and `PUBLISHABLE_KEY`. `Hetha_admin/.env.local` holds `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY`. The Razorpay secret lives only in the Supabase Edge Function env.

## Database workflow

- `docs/db/migrations/NNN_*.sql` are numbered and authoritative. Each one is a single `BEGIN…COMMIT` file. Someone pastes it into the **Supabase SQL Editor** by hand; there is no migration runner or CLI deploy. A header comment explains the problem and the fix.
- `docs/db/{schema,functions,functions_internal,policies,indexes}.sql` are snapshots. Some are partly hand-edited and can lag behind the migrations; `docs/db/REFRESH.md` tracks how current each one is. When a snapshot and a migration disagree, the migration wins.
- **When you add a migration:**
  1. Append its filename to the hard-coded list in `docs/db/tests/verify_money_integrity.mjs` (about line 200). The suite applies every migration in order.
  2. Add tests there if the migration touches money.
  3. Update `docs/DATA_MODEL.md`.
  4. Update the mirrors (`Hetha_app/doc-schema/`, `Hetha_admin/docs/schema.sql`).
  5. If a shape changed, update the types (`Hetha_admin/lib/types.ts`, `Hetha_app/lib/models/`).
- Snapshot re-sync procedure, plus post-change grant and trigger checks: `docs/db/REFRESH.md`.

## Money integrity (the core invariant)

**Clients send variant ids and quantities; the database decides money.** See `docs/ARCHITECTURE.md` §5b.

- Privileged money primitives live in the `internal` schema, which PostgREST does not expose: `internal.place_order_core`, `internal.apply_wallet_delta`, `internal.compute_delivery_charge`, `internal.next_delivery_date`. Public `SECURITY DEFINER` RPCs (`place_order`, `create_subscription`, `reschedule_order`, …) wrap them, check `auth.uid()` or admin permission, and pin `search_path`.
- Customers cannot write `orders`, `order_items`, or `subscription_items` directly. `authenticated` has no UPDATE grant on `users.wallet_balance`.
- Deferred constraint triggers enforce totals (`subtotal = Σ items`, `total = subtotal + delivery_charge`). The deliberate escape hatch is `SET LOCAL hetha.skip_money_checks = 'on'`.
- Delivery charge is ₹0 for pincodes in an active delivery area. Otherwise it comes from `delivery_charge_tiers` by weight. A client-supplied charge is honoured only for admin callers.
- **3-day buffer rule:** wallet purchases and new subscriptions must leave 3 days of daily subscription commitment in the wallet. The DB enforces it; both UIs mirror it for friendlier messages.
- Orders and subscriptions copy customer, address, and product data into `snapshot_*` columns, so history stays fixed.
- Run-sheet generation rules (cutoffs, pauses, frequency, route per address): `Hetha_admin/docs/daily_ops.md`.

## Change logs

Each work session gets a dated `CHANGES_YYYY-MM-DD.md` at the root. It covers what changed across all three repos, the migrations and whether they are applied/verified on live, a table of commit hashes per repo, and a ✅/⏳/⚠️ status. Follow that format when logging work. `REMAINING_FIXES.md` lists the open pre-launch items.

## Further docs

`docs/ARCHITECTURE.md` (system), `docs/DATA_MODEL.md` (schema/RPCs/RLS), and each sub-repo's `README.md`, `docs/ARCHITECTURE.md`, and `CONTRIBUTING.md`. The admin repo also has `docs/UI_GUIDELINES.md`.
