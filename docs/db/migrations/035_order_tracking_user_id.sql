-- Migration 035: order_tracking.user_id, so the app's Realtime listener can be
--                filtered to the customer's own rows
--
-- Run in: Supabase SQL Editor (the whole file; it is wrapped in one transaction)
--
-- ─── Problem ────────────────────────────────────────────────────────────────
-- The app's Orders screen (Hetha_app/lib/screens/orders/order_page.dart)
-- listens to postgres_changes on order_tracking with NO filter, because the
-- table has no user_id column. For every order_tracking change, Supabase
-- Realtime evaluates the table's RLS SELECT policy once per connected
-- subscriber — an EXISTS lookup into orders each time — just to discover that
-- only one of them (the order's owner) may see it.
--
-- Example: 300 customers on the Orders screen, staff update tracking on 400
-- orders → 120,000 RLS checks instead of 400, processed serially by Realtime.
-- Cost grows with (customers online × tracking changes).
--
-- The listener cannot simply be removed: staff can save courier / AWB /
-- customer message on their own (Hetha_admin app/api/admin/orders/[id]) and
-- that changes only order_tracking, not orders.
--
-- ─── Fix ─────────────────────────────────────────────────────────────────────
-- 1. Add order_tracking.user_id (nullable, like orders.user_id) and backfill it
--    from the parent order.
-- 2. BEFORE INSERT OR UPDATE trigger on order_tracking: always derive user_id
--    from orders. Nobody — admin panel, place_order_core, or a hand-written
--    UPDATE — sets it; any value supplied is overwritten.
-- 3. AFTER UPDATE trigger on orders: when an order's user_id changes, carry it
--    to that order's tracking rows. This covers claim_adhoc_user, which
--    rewrites users.id and reaches orders.user_id through ON UPDATE CASCADE.
--
-- The app then filters its order_tracking listener on user_id = <own id>, so
-- Realtime runs the RLS check only for the one matching subscriber.
--
-- RLS is unchanged: the SELECT policies still authorise through orders, so a
-- wrong user_id could at worst stop a live update, never leak a row.
--
-- ─── Rollout order ──────────────────────────────────────────────────────────
-- Apply THIS migration first, then release the app. Old app builds are
-- unaffected (they don't filter, and an extra column is harmless). A new build
-- against a database without the column would fail to subscribe.
--
-- The backfill UPDATE emits one Realtime event per existing tracking row to
-- old app builds already on the Orders screen; each is debounced into a single
-- refetch. Prefer a quiet hour.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Column + backfill
-- ---------------------------------------------------------------------------
ALTER TABLE public.order_tracking
  ADD COLUMN IF NOT EXISTS user_id uuid;

UPDATE public.order_tracking t
SET    user_id = o.user_id
FROM   public.orders o
WHERE  o.id = t.order_id
  AND  t.user_id IS DISTINCT FROM o.user_id;

-- ---------------------------------------------------------------------------
-- 2. order_tracking.user_id is always derived from the order
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION internal.set_order_tracking_user_id()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
BEGIN
  SELECT o.user_id INTO NEW.user_id
  FROM public.orders o
  WHERE o.id = NEW.order_id;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION internal.set_order_tracking_user_id() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_set_order_tracking_user_id ON public.order_tracking;
CREATE TRIGGER trg_set_order_tracking_user_id
  BEFORE INSERT OR UPDATE ON public.order_tracking
  FOR EACH ROW
  EXECUTE FUNCTION internal.set_order_tracking_user_id();

-- ---------------------------------------------------------------------------
-- 3. Follow the order when its owner changes (claim_adhoc_user via cascade)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION internal.sync_order_tracking_user_id()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
BEGIN
  -- The value written here is re-derived by trg_set_order_tracking_user_id,
  -- which reads the already-updated orders row — so both agree.
  UPDATE public.order_tracking
  SET    user_id = NEW.user_id
  WHERE  order_id = NEW.id;

  RETURN NULL;
END;
$function$;

REVOKE ALL ON FUNCTION internal.sync_order_tracking_user_id() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_sync_order_tracking_user_id ON public.orders;
CREATE TRIGGER trg_sync_order_tracking_user_id
  AFTER UPDATE ON public.orders
  FOR EACH ROW
  WHEN (OLD.user_id IS DISTINCT FROM NEW.user_id)
  EXECUTE FUNCTION internal.sync_order_tracking_user_id();

COMMIT;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- 1. Column exists:
--      SELECT column_name, data_type FROM information_schema.columns
--      WHERE table_schema = 'public' AND table_name = 'order_tracking' AND column_name = 'user_id';
--
-- 2. Both triggers exist:
--      SELECT tgname FROM pg_trigger
--      WHERE tgname IN ('trg_set_order_tracking_user_id', 'trg_sync_order_tracking_user_id');  -- 2 rows
--
-- 3. Backfill complete — every tracking row matches its order (expect 0):
--      SELECT count(*) FROM public.order_tracking t
--      JOIN public.orders o ON o.id = t.order_id
--      WHERE t.user_id IS DISTINCT FROM o.user_id;
--
-- 4. order_tracking is still in the Realtime publication with all columns:
--      SELECT tablename, attnames FROM pg_publication_tables
--      WHERE pubname = 'supabase_realtime' AND tablename IN ('orders', 'order_tracking');
--      -- attnames for order_tracking must include user_id
