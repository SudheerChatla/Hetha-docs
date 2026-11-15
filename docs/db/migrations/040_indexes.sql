-- Migration 040: indexes for the hot filters (task A-06)
--
-- Run in: Supabase SQL Editor (the whole file; it is wrapped in one transaction)
--
-- ─── Problem ────────────────────────────────────────────────────────────────
-- The 2026-11-10 audit found list and day screens filtering or sorting on
-- columns with no index: the Deliveries page (orders by expected delivery
-- date), the paged admin lists (newest first), the subscription address
-- lookup, the wallet forecast (a customer's live subscriptions and their
-- daily orders) and the customer page's wallet history.
--
-- ─── Fix ─────────────────────────────────────────────────────────────────────
-- Indexes only. No function, table or data changes. Each is
-- CREATE INDEX IF NOT EXISTS, so the file is safe to run twice.
-- On a small table each one builds in well under a second; CREATE INDEX
-- briefly blocks writes to that table while it builds.
--
-- ─── Rollout order ──────────────────────────────────────────────────────────
-- Any time after migration 037. Independent of 038 / 039.

BEGIN;

-- Deliveries page: one-time orders still open, due on or before a date.
CREATE INDEX IF NOT EXISTS idx_orders_expected_delivery_open
  ON public.orders (expected_delivery_date)
  WHERE status NOT IN ('cancelled', 'payment_pending', 'delivered');
-- Deliveries page with "include done": delivered on exactly that date.
CREATE INDEX IF NOT EXISTS idx_orders_expected_delivery_delivered
  ON public.orders (expected_delivery_date) WHERE status = 'delivered';

CREATE INDEX IF NOT EXISTS idx_subscriptions_address_id  ON public.subscriptions (address_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_created_at  ON public.subscriptions (created_at DESC);
-- Wallet reserve / forecast: a customer's live subscriptions.
CREATE INDEX IF NOT EXISTS idx_subscriptions_user_status ON public.subscriptions (user_id, status);
CREATE INDEX IF NOT EXISTS idx_users_created_at          ON public.users (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_addresses_created_at      ON public.addresses (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reviews_created_at        ON public.reviews (created_at DESC);
-- Wallet forecast / customer history: a customer's daily orders by date.
CREATE INDEX IF NOT EXISTS idx_sdo_user_date             ON public.subscription_daily_orders (user_id, delivery_date);
-- Customer page wallet history, newest first, paged (A-10). Not in the plan's
-- list; added for the "Load more" query.
CREATE INDEX IF NOT EXISTS idx_wallet_tx_user_created    ON public.wallet_transactions (user_id, created_at DESC);

COMMIT;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- 1. All ten exist (expect 10 rows):
--      SELECT indexname FROM pg_indexes
--      WHERE schemaname = 'public' AND indexname IN (
--        'idx_orders_expected_delivery_open', 'idx_orders_expected_delivery_delivered',
--        'idx_subscriptions_address_id', 'idx_subscriptions_created_at',
--        'idx_subscriptions_user_status', 'idx_users_created_at',
--        'idx_addresses_created_at', 'idx_reviews_created_at',
--        'idx_sdo_user_date', 'idx_wallet_tx_user_created')
--      ORDER BY 1;
