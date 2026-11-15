-- Migration 037: one settlement function for subscription daily orders
--
-- Run in: Supabase SQL Editor (the whole file; it is wrapped in one transaction)
--
-- ─── Problem ────────────────────────────────────────────────────────────────
-- finalize_daily_run debited each daily order once and stored only a flag
-- (payment_status = 'paid'). Nothing remembered HOW MUCH was taken, so every
-- later event that changes what the customer should pay had no way to correct
-- the charge:
--
--   1. WALLET SHORT. A failed debit left the order finalized, on the run sheet
--      and delivered, marked 'failed', with no way to collect or retry.
--   2. SHORT / MISSED DELIVERY. Recording delivered quantities for a
--      subscription order only stored the numbers. One-time orders refund the
--      shortfall (record_order_delivery, migration 033); subscriptions did not.
--   3. SKIPPED / CANCELLED AFTER FINALIZE. A plain status update, no refund.
--   4. UNLOCK → EDIT → FINALIZE AGAIN. Finalize only charges orders that are
--      still 'pending', so an item added after an unlock was free and a
--      removed item was never refunded. (Hetha_admin d4bafd0 stopped the
--      double charge on regenerate; this closes the rest.)
--   5. RECONCILE and UNLOCK were several separate API writes from the admin
--      panel, so a failure half-way left the run and its orders disagreeing.
--
-- ─── Fix ─────────────────────────────────────────────────────────────────────
-- Each daily order now records paid_amount: the net amount taken from the
-- wallet for it. internal.settle_daily_order compares that with what the
-- customer owes RIGHT NOW and moves only the difference:
--
--   owed = 0                                   when status is skipped/cancelled
--        = Σ unit_price × delivered_qty        for items with a recorded qty
--          + Σ unit_price × quantity           for items without one
--
--   owed > paid_amount  → debit the difference
--   owed < paid_amount  → refund the difference
--   owed = paid_amount  → nothing (calling settle twice is a no-op)
--
-- Every money event goes through it, each as ONE all-or-nothing function:
--
--   finalize_daily_run          charge each order; a wallet that cannot cover
--                               an order → the order is SKIPPED
--                               (skip_reason 'insufficient_balance'), nothing is
--                               taken, and it is reported so the customer can
--                               be told. No unpaid deliveries.
--   record_subscription_delivery  store delivered quantities, refund any
--                               shortfall. Safe to repeat or correct.
--   set_daily_order_status      delivered / skipped / cancelled / pending,
--                               with the matching charge or refund.
--   retry_daily_order_payment   put a payment-skipped order back and charge
--                               it, once the customer has recharged.
--   unlock_daily_run            reopen a finalized day; paid amounts stay, so
--                               the next finalize settles only the difference.
--   reconcile_daily_run         refuses while any pending order has an item
--                               with no delivered quantity. Once every
--                               quantity is entered: mark the rest delivered,
--                               settle, close the day.
--
-- Two guards keep money from being stranded on an order:
--   • a daily order with paid_amount > 0 cannot be DELETED (cancel it instead,
--     which refunds it);
--   • finalize also refunds any skipped / cancelled order of the day that
--     still holds money (for example one cancelled while the day was unlocked).
--
-- CHARGING ORDER. When one customer has several orders on a day and the wallet
-- cannot cover all of them, finalize charges them oldest subscription first
-- (subscriptions.created_at, then subscription id). The older subscription is
-- delivered; the newer one is skipped.
--
-- ─── Backfill ───────────────────────────────────────────────────────────────
-- paid_amount for existing orders comes from the wallet ledger, not from the
-- order total: the net of wallet_transactions with reference_type
-- 'subscription' and reference_id = the order id (finalize has written those
-- since migration 004). Where the ledger and the order's payment_status
-- disagree, the order is NOT guessed at: settlement_hold_reason is filled in
-- and every settlement function refuses to move money for that order until
-- someone has looked at it. The verification section lists them.
--
-- Orders that went out under the old system with a FAILED debit (finalized,
-- payment_status 'failed', still pending or delivered) are held too. Otherwise
-- the first reconcile after this migration would quietly debit them.
--
-- The backfill only touches orders this migration's functions have never
-- settled (settled_at IS NULL), so re-running the file is safe.
--
-- ─── Not in this migration (phase 2) ────────────────────────────────────────
-- Run-sheet generation and admin item edits are still separate API writes, and
-- staff with daily_ops:edit can still update these tables directly. Cash on
-- delivery subscriptions are untouched: settle moves nothing for them.
--
-- ─── Rollout order ──────────────────────────────────────────────────────────
-- Apply THIS migration, then deploy the admin panel. Until the panel is
-- deployed the old code keeps working: finalize_daily_run keeps its signature
-- and its result keeps the fields the old panel reads.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------
ALTER TABLE public.subscription_daily_orders
  ADD COLUMN IF NOT EXISTS paid_amount            numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS skip_reason            text,
  ADD COLUMN IF NOT EXISTS settled_at             timestamp without time zone,
  ADD COLUMN IF NOT EXISTS settlement_hold_reason text;

COMMENT ON COLUMN public.subscription_daily_orders.paid_amount IS
  'Net amount taken from the wallet for this order (debits minus refunds). Written only by internal.settle_daily_order and the migration 037 backfill.';
COMMENT ON COLUMN public.subscription_daily_orders.skip_reason IS
  'Why the system skipped this order: insufficient_balance | payment_error. NULL when staff or the customer skipped it, or it is not skipped.';
COMMENT ON COLUMN public.subscription_daily_orders.settled_at IS
  'Last time internal.settle_daily_order ran for this order. NULL = never settled by the migration 037 functions.';
COMMENT ON COLUMN public.subscription_daily_orders.settlement_hold_reason IS
  'Set by the migration 037 backfill when the wallet ledger and payment_status disagree. While set, no settlement function moves money for this order.';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sdo_paid_amount_not_negative') THEN
    ALTER TABLE public.subscription_daily_orders
      ADD CONSTRAINT sdo_paid_amount_not_negative CHECK (paid_amount >= 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sdo_skip_reason_check') THEN
    ALTER TABLE public.subscription_daily_orders
      ADD CONSTRAINT sdo_skip_reason_check
      CHECK (skip_reason IS NULL OR skip_reason IN ('insufficient_balance', 'payment_error'));
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Backfill paid_amount from the wallet ledger
-- ---------------------------------------------------------------------------
WITH ledger AS (
  SELECT wt.reference_id AS order_id,
         round(SUM(CASE WHEN wt.type = 'debit' THEN wt.amount ELSE -wt.amount END), 2) AS net,
         COUNT(*) AS entries
  FROM public.wallet_transactions wt
  WHERE wt.reference_type = 'subscription'
    AND wt.reference_id IS NOT NULL
  GROUP BY wt.reference_id
),
checked AS (
  SELECT o.id,
         COALESCE(l.net, 0)     AS net,
         COALESCE(l.entries, 0) AS entries
  FROM public.subscription_daily_orders o
  LEFT JOIN ledger l ON l.order_id = o.id
  WHERE o.settled_at IS NULL
)
UPDATE public.subscription_daily_orders o
SET paid_amount = GREATEST(c.net, 0),
    settlement_hold_reason = CASE
      WHEN c.net < 0 THEN
        format('Wallet history shows %s more refunded than charged for this order', -c.net)
      WHEN o.payment_status = 'paid' AND c.entries = 0 THEN
        'Marked paid, but no wallet transaction is linked to this order'
      WHEN o.payment_status = 'paid' AND c.net <> round(o.total_value, 2) THEN
        format('Marked paid, but wallet history shows %s charged against an order total of %s',
               c.net, round(o.total_value, 2))
      WHEN o.payment_status IN ('pending', 'failed', 'refunded') AND c.net <> 0 THEN
        format('Marked %s, but wallet history shows %s still charged for this order',
               o.payment_status, c.net)
      WHEN o.payment_status = 'failed' AND COALESCE(o.is_finalized, false)
           AND o.status IN ('pending', 'delivered') THEN
        'Went out under the old system with a failed wallet debit; it is not charged automatically'
      ELSE NULL
    END
FROM checked c
WHERE c.id = o.id;

-- ---------------------------------------------------------------------------
-- 3. What an order owes right now
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION internal.daily_order_amount_owed(p_order_id uuid)
  RETURNS numeric
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_status text;
  v_owed   numeric;
BEGIN
  SELECT status INTO v_status
  FROM public.subscription_daily_orders WHERE id = p_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Daily order not found';
  END IF;

  IF v_status IN ('skipped', 'cancelled') THEN
    RETURN 0;
  END IF;

  -- A recorded delivered quantity replaces the ordered one. LEAST guards
  -- against a delivered quantity above the ordered one ever being charged.
  SELECT COALESCE(SUM(round(i.unit_price * LEAST(COALESCE(i.delivered_qty, i.quantity), i.quantity), 2)), 0)
  INTO v_owed
  FROM public.subscription_daily_order_items i
  WHERE i.daily_order_id = p_order_id;

  RETURN round(v_owed, 2);
END;
$function$;

REVOKE ALL ON FUNCTION internal.daily_order_amount_owed(uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. internal.settle_daily_order — the only place daily-order money moves
-- ---------------------------------------------------------------------------
-- p_on_short: what to do when a debit is needed and the wallet cannot cover it
--   'skip'  → mark the order skipped (insufficient_balance), refund anything
--             already taken, report it. Used by finalize.
--   'raise' → raise, so the caller's whole action rolls back. Used everywhere
--             else (a delivered order cannot be un-delivered by a low balance).
-- p_refund_reason: text for the wallet history line when money goes back.
--
-- Returns { charged, refunded, skipped, owed, paid_amount, user_id, wallet }.
CREATE OR REPLACE FUNCTION internal.settle_daily_order(
  p_order_id      uuid,
  p_on_short      text DEFAULT 'raise',
  p_refund_reason text DEFAULT NULL
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_order    public.subscription_daily_orders;
  v_method   text;
  v_owed     numeric;
  v_diff     numeric;
  v_balance  numeric;
  v_charged  numeric := 0;
  v_refunded numeric := 0;
  v_refund_text text;
BEGIN
  IF p_on_short NOT IN ('skip', 'raise') THEN
    RAISE EXCEPTION 'settle_daily_order: p_on_short must be skip or raise';
  END IF;

  SELECT * INTO v_order
  FROM public.subscription_daily_orders WHERE id = p_order_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Daily order not found';
  END IF;

  IF v_order.settlement_hold_reason IS NOT NULL THEN
    RAISE EXCEPTION 'This order''s payment history needs review before money can move: %',
      v_order.settlement_hold_reason;
  END IF;

  SELECT payment_method INTO v_method
  FROM public.subscriptions WHERE id = v_order.subscription_id;

  -- Cash on delivery: nothing moves through the wallet.
  IF COALESCE(v_method, 'wallet') <> 'wallet' THEN
    RETURN jsonb_build_object(
      'charged', 0, 'refunded', 0, 'skipped', false, 'wallet', false,
      'owed', internal.daily_order_amount_owed(p_order_id),
      'paid_amount', v_order.paid_amount, 'user_id', v_order.user_id);
  END IF;

  v_owed := internal.daily_order_amount_owed(p_order_id);
  v_diff := round(v_owed - v_order.paid_amount, 2);
  v_refund_text := 'Refund: ' || COALESCE(p_refund_reason, 'subscription delivery')
                   || ' ' || v_order.delivery_date::text;

  IF v_diff > 0 THEN
    SELECT COALESCE(wallet_balance, 0) INTO v_balance
    FROM public.users WHERE id = v_order.user_id FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'User not found';
    END IF;

    IF v_balance < v_diff THEN
      IF p_on_short = 'raise' THEN
        RAISE EXCEPTION
          'Wallet balance (%) is too low to charge % for this order. Ask the customer to recharge.',
          v_balance, v_diff;
      END IF;

      -- Skip the order for the day and give back anything already taken
      -- (only possible when the order was paid, then unlocked and enlarged).
      IF v_order.paid_amount > 0 THEN
        PERFORM internal.apply_wallet_delta(
          v_order.user_id, v_order.paid_amount, 'credit',
          'Refund: delivery skipped (low wallet balance) ' || v_order.delivery_date::text,
          'admin', 'subscription', v_order.id::text);
        v_refunded := v_order.paid_amount;
      END IF;

      UPDATE public.subscription_daily_orders
      SET status         = 'skipped',
          skip_reason    = 'insufficient_balance',
          paid_amount    = 0,
          payment_status = 'failed',
          settled_at     = now()
      WHERE id = p_order_id;

      RETURN jsonb_build_object(
        'charged', 0, 'refunded', v_refunded, 'skipped', true, 'wallet', true,
        'owed', v_owed, 'paid_amount', 0, 'user_id', v_order.user_id,
        'shortfall', round(v_diff - v_balance, 2));
    END IF;

    PERFORM internal.apply_wallet_delta(
      v_order.user_id, v_diff, 'debit',
      'Subscription delivery ' || v_order.delivery_date::text,
      'admin', 'subscription', v_order.id::text);
    v_charged := v_diff;

  ELSIF v_diff < 0 THEN
    PERFORM internal.apply_wallet_delta(
      v_order.user_id, -v_diff, 'credit', v_refund_text,
      'admin', 'subscription', v_order.id::text);
    v_refunded := -v_diff;
  END IF;

  UPDATE public.subscription_daily_orders
  SET paid_amount    = v_owed,
      payment_status = CASE
                         WHEN v_owed > 0 THEN 'paid'
                         WHEN v_order.paid_amount > 0 THEN 'refunded'
                         ELSE payment_status
                       END,
      wallet_deducted_at = CASE WHEN v_charged > 0 THEN now() ELSE wallet_deducted_at END,
      settled_at     = now()
  WHERE id = p_order_id;

  RETURN jsonb_build_object(
    'charged', v_charged, 'refunded', v_refunded, 'skipped', false, 'wallet', true,
    'owed', v_owed, 'paid_amount', v_owed, 'user_id', v_order.user_id);
END;
$function$;

REVOKE ALL ON FUNCTION internal.settle_daily_order(uuid, text, text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. finalize_daily_run — charge the day, skip what the wallet cannot cover
-- ---------------------------------------------------------------------------
-- Same signature as before. The result keeps finalized / total_deducted /
-- total_value / deduction_errors (the deployed admin panel reads them) and
-- adds total_refunded, charged[] and skipped[].
CREATE OR REPLACE FUNCTION public.finalize_daily_run(p_delivery_date date, p_admin_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_run_id      uuid;
  v_run_status  text;
  v_order       record;
  v_res         jsonb;
  v_charged     jsonb := '[]'::jsonb;
  v_skipped     jsonb := '[]'::jsonb;
  v_errors      jsonb := '[]'::jsonb;
  v_total_deducted numeric := 0;
  v_total_refunded numeric := 0;
  v_total_value    numeric := 0;
  v_total_orders   integer := 0;
BEGIN
  IF NOT internal.is_admin_actor('daily_ops:edit') THEN
    RAISE EXCEPTION 'Not authorized to finalize a delivery run';
  END IF;

  INSERT INTO public.daily_ops_runs (delivery_date, status, generated_by, generated_at)
  VALUES (p_delivery_date, 'draft', p_admin_id, now())
  ON CONFLICT (delivery_date) DO NOTHING;

  -- The row lock makes a second, simultaneous finalize wait here and then
  -- fail the status check below, so a day can never be charged twice.
  SELECT id, status INTO v_run_id, v_run_status
  FROM public.daily_ops_runs
  WHERE delivery_date = p_delivery_date
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Run record not found for %', p_delivery_date;
  END IF;

  IF v_run_status <> 'draft' THEN
    RAISE EXCEPTION 'Cannot finalize: date is already %', v_run_status;
  END IF;

  UPDATE public.subscription_daily_orders
  SET is_finalized = true,
      finalized_at = now(),
      finalized_by = p_admin_id
  WHERE delivery_date = p_delivery_date
    AND status = 'pending'
    AND is_finalized = false;

  -- Charging order: per customer, oldest subscription first. When a wallet
  -- cannot cover every order, the older subscription is the one delivered.
  FOR v_order IN
    SELECT sdo.id, sdo.user_id, sdo.total_value
    FROM public.subscription_daily_orders sdo
    JOIN public.subscriptions s ON s.id = sdo.subscription_id
    WHERE sdo.delivery_date = p_delivery_date
      AND sdo.is_finalized = true
      AND sdo.status = 'pending'
      AND s.payment_method = 'wallet'
    ORDER BY sdo.user_id, s.created_at, s.id, sdo.id
  LOOP
    BEGIN
      v_res := internal.settle_daily_order(v_order.id, 'skip', 'order changed');

      IF (v_res->>'skipped')::boolean THEN
        v_skipped := v_skipped || jsonb_build_object(
          'order_id', v_order.id, 'user_id', v_order.user_id,
          'amount', (v_res->>'owed')::numeric, 'reason', 'insufficient_balance');
      ELSIF (v_res->>'charged')::numeric > 0 THEN
        v_charged := v_charged || jsonb_build_object(
          'order_id', v_order.id, 'user_id', v_order.user_id,
          'amount', (v_res->>'charged')::numeric);
      END IF;

      v_total_deducted := v_total_deducted + (v_res->>'charged')::numeric;
      v_total_refunded := v_total_refunded + (v_res->>'refunded')::numeric;

    EXCEPTION WHEN OTHERS THEN
      -- Anything unexpected (for example an order on payment hold): the order
      -- must not go out unpaid, so it is skipped and reported, not delivered.
      v_errors := v_errors || jsonb_build_object(
        'order_id', v_order.id, 'user_id', v_order.user_id,
        'amount', v_order.total_value, 'error', SQLERRM);

      UPDATE public.subscription_daily_orders
      SET status = 'skipped', skip_reason = 'payment_error', payment_status = 'failed'
      WHERE id = v_order.id;
    END;
  END LOOP;

  -- Refund sweep: a skipped or cancelled order of this day that still holds
  -- money (cancelled while the day was unlocked, or by a direct table update)
  -- owes nothing, so settle gives the money back.
  FOR v_order IN
    SELECT id, user_id, total_value
    FROM public.subscription_daily_orders
    WHERE delivery_date = p_delivery_date
      AND status IN ('skipped', 'cancelled')
      AND paid_amount > 0
      AND settlement_hold_reason IS NULL
    ORDER BY user_id, id
  LOOP
    v_res := internal.settle_daily_order(
      v_order.id, 'raise', 'delivery skipped');
    v_total_refunded := v_total_refunded + (v_res->>'refunded')::numeric;
  END LOOP;

  SELECT COUNT(*), COALESCE(SUM(total_value), 0)
  INTO v_total_orders, v_total_value
  FROM public.subscription_daily_orders
  WHERE delivery_date = p_delivery_date
    AND is_finalized = true
    AND status NOT IN ('skipped', 'cancelled');

  UPDATE public.daily_ops_runs
  SET status = 'finalized',
      finalized_at = now(),
      finalized_by = p_admin_id,
      total_orders = v_total_orders,
      total_value = v_total_value,
      wallet_deduction_completed_at = now(),
      updated_at = now()
  WHERE id = v_run_id;

  RETURN jsonb_build_object(
    'finalized',        v_total_orders,
    'total_deducted',   v_total_deducted,
    'total_refunded',   v_total_refunded,
    'total_value',      v_total_value,
    'charged',          v_charged,
    'skipped',          v_skipped,
    'deduction_errors', v_errors
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 6. unlock_daily_run — reopen a finalized day (super admin)
-- ---------------------------------------------------------------------------
-- Only orders still 'pending' become editable again; delivered, skipped and
-- cancelled orders keep their state. Paid amounts stay as they are: the next
-- finalize settles only the difference.
CREATE OR REPLACE FUNCTION public.unlock_daily_run(p_delivery_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_run_id     uuid;
  v_run_status text;
  v_reopened   integer := 0;
BEGIN
  IF NOT (internal.is_service_actor() OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Only a super admin can unlock a finalized day';
  END IF;

  SELECT id, status INTO v_run_id, v_run_status
  FROM public.daily_ops_runs
  WHERE delivery_date = p_delivery_date
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No run exists for %', p_delivery_date;
  END IF;
  IF v_run_status = 'reconciled' THEN
    RAISE EXCEPTION 'This day is reconciled and cannot be unlocked';
  END IF;
  IF v_run_status <> 'finalized' THEN
    RAISE EXCEPTION 'This day is not finalized';
  END IF;

  UPDATE public.daily_ops_runs
  SET status = 'draft', finalized_at = NULL, finalized_by = NULL, updated_at = now()
  WHERE id = v_run_id;

  UPDATE public.subscription_daily_orders
  SET is_finalized = false, finalized_at = NULL, finalized_by = NULL
  WHERE delivery_date = p_delivery_date
    AND is_finalized = true
    AND status = 'pending';
  GET DIAGNOSTICS v_reopened = ROW_COUNT;

  RETURN jsonb_build_object('reopened', v_reopened);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 7. record_subscription_delivery — delivered quantities + shortfall refund
-- ---------------------------------------------------------------------------
-- The subscription twin of record_order_delivery (migration 033). Every item
-- of the order must end up with a delivered quantity. Nothing delivered →
-- the order is cancelled and fully refunded. Calling it again with corrected
-- quantities settles only the difference.
CREATE OR REPLACE FUNCTION public.record_subscription_delivery(
  p_daily_order_id uuid,
  p_items          jsonb,
  p_note           text DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_order         public.subscription_daily_orders;
  v_run_status    text;
  v_item          jsonb;
  v_item_id       uuid;
  v_delivered_qty integer;
  v_quantity      integer;
  v_all_zero      boolean;
  v_new_status    text;
  v_res           jsonb;
BEGIN
  IF NOT internal.is_admin_actor('daily_ops:edit') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT * INTO v_order
  FROM public.subscription_daily_orders WHERE id = p_daily_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Daily order not found';
  END IF;

  SELECT status INTO v_run_status
  FROM public.daily_ops_runs WHERE delivery_date = v_order.delivery_date;

  IF v_run_status = 'reconciled' THEN
    RAISE EXCEPTION 'This day is reconciled; deliveries can no longer be changed';
  END IF;
  IF NOT COALESCE(v_order.is_finalized, false) THEN
    RAISE EXCEPTION 'Finalize the day before recording deliveries';
  END IF;
  IF v_order.status = 'skipped' THEN
    IF v_order.skip_reason IS NOT NULL THEN
      RAISE EXCEPTION 'This order was skipped because the payment failed. Use Retry payment first.';
    END IF;
    RAISE EXCEPTION 'This order is skipped. Set it back to pending before recording a delivery.';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'p_items must be a JSON array';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_item_id       := (v_item->>'item_id')::uuid;
    v_delivered_qty := (v_item->>'delivered_qty')::integer;

    IF v_item_id IS NULL THEN
      RAISE EXCEPTION 'Each item must have an item_id';
    END IF;
    IF v_delivered_qty IS NULL THEN
      RAISE EXCEPTION 'Each item must have a delivered_qty';
    END IF;
    IF v_delivered_qty < 0 THEN
      RAISE EXCEPTION 'delivered_qty cannot be negative';
    END IF;

    SELECT quantity INTO v_quantity
    FROM public.subscription_daily_order_items
    WHERE id = v_item_id AND daily_order_id = p_daily_order_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Item % does not belong to this order', v_item_id;
    END IF;
    IF v_delivered_qty > v_quantity THEN
      RAISE EXCEPTION 'delivered_qty (%) exceeds the ordered quantity (%)', v_delivered_qty, v_quantity;
    END IF;

    UPDATE public.subscription_daily_order_items
    SET delivered_qty = v_delivered_qty
    WHERE id = v_item_id;
  END LOOP;

  -- Every line must be accounted for, otherwise the order would be marked
  -- delivered with some lines never checked and their shortfall never refunded.
  PERFORM 1 FROM public.subscription_daily_order_items
  WHERE daily_order_id = p_daily_order_id AND delivered_qty IS NULL
  LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Record a delivered quantity for every item in the order';
  END IF;

  SELECT COALESCE(bool_and(delivered_qty = 0), true) INTO v_all_zero
  FROM public.subscription_daily_order_items
  WHERE daily_order_id = p_daily_order_id;

  v_new_status := CASE WHEN v_all_zero THEN 'cancelled' ELSE 'delivered' END;

  UPDATE public.subscription_daily_orders
  SET status        = v_new_status,
      skip_reason   = NULL,
      tracking_info = COALESCE(p_note, tracking_info)
  WHERE id = p_daily_order_id;

  v_res := internal.settle_daily_order(
    p_daily_order_id, 'raise',
    CASE WHEN v_all_zero THEN 'not delivered' ELSE 'short delivery' END);

  RETURN jsonb_build_object(
    'status',   v_new_status,
    'refunded', (v_res->>'refunded')::numeric,
    'charged',  (v_res->>'charged')::numeric,
    'short',    (v_res->>'owed')::numeric < round(v_order.total_value, 2),
    'user_id',  v_order.user_id
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 8. set_daily_order_status — status change with the matching money movement
-- ---------------------------------------------------------------------------
-- On a finalized day:
--   delivered          → items without a delivered quantity are recorded as
--                        fully delivered, then settle
--   skipped/cancelled  → settle refunds everything taken
--   pending (undo)     → recorded quantities are cleared (the order is "not
--                        delivered yet" again) and settle charges what was
--                        refunded; raises if the wallet cannot cover it
-- On a day that is not finalized nothing is charged (finalize does that), but
-- skipping or cancelling an order that already holds money (it was paid, then
-- the day was unlocked) refunds it straight away.
CREATE OR REPLACE FUNCTION public.set_daily_order_status(p_order_ids uuid[], p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_order      public.subscription_daily_orders;
  v_run_status text;
  v_res        jsonb;
  v_results    jsonb := '[]'::jsonb;
  v_updated    integer := 0;
  v_refunded   numeric := 0;
  v_charged    numeric := 0;
  v_id         uuid;
BEGIN
  IF NOT internal.is_admin_actor('daily_ops:edit') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF p_status IS NULL OR p_status NOT IN ('pending', 'delivered', 'skipped', 'cancelled') THEN
    RAISE EXCEPTION 'Invalid status: %', p_status;
  END IF;
  IF p_order_ids IS NULL OR array_length(p_order_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'At least one order is required';
  END IF;

  -- Fixed lock order (by id) so two staff changing overlapping selections
  -- cannot deadlock.
  FOR v_id IN SELECT DISTINCT x FROM unnest(p_order_ids) x ORDER BY x
  LOOP
    SELECT * INTO v_order
    FROM public.subscription_daily_orders WHERE id = v_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Daily order % not found', v_id;
    END IF;

    IF v_order.status = p_status THEN
      CONTINUE;
    END IF;

    SELECT status INTO v_run_status
    FROM public.daily_ops_runs WHERE delivery_date = v_order.delivery_date;
    IF v_run_status = 'reconciled' THEN
      RAISE EXCEPTION 'The day % is reconciled; its orders can no longer be changed', v_order.delivery_date;
    END IF;

    IF v_order.status = 'skipped' AND v_order.skip_reason IS NOT NULL
       AND p_status IN ('pending', 'delivered') THEN
      RAISE EXCEPTION 'An order was skipped because its payment failed. Use Retry payment for it.';
    END IF;

    IF p_status = 'delivered' THEN
      IF NOT COALESCE(v_order.is_finalized, false) THEN
        RAISE EXCEPTION 'Finalize the day before marking deliveries';
      END IF;
      UPDATE public.subscription_daily_order_items
      SET delivered_qty = quantity
      WHERE daily_order_id = v_id AND delivered_qty IS NULL;
    END IF;

    IF p_status = 'pending' THEN
      UPDATE public.subscription_daily_order_items
      SET delivered_qty = NULL
      WHERE daily_order_id = v_id AND delivered_qty IS NOT NULL;
    END IF;

    UPDATE public.subscription_daily_orders
    SET status = p_status, skip_reason = NULL
    WHERE id = v_id;
    v_updated := v_updated + 1;

    v_res := NULL;
    IF COALESCE(v_order.is_finalized, false)
       OR (p_status IN ('skipped', 'cancelled') AND v_order.paid_amount > 0) THEN
      v_res := internal.settle_daily_order(
        v_id, 'raise',
        CASE p_status WHEN 'skipped' THEN 'delivery skipped'
                      WHEN 'cancelled' THEN 'delivery cancelled'
                      ELSE 'short delivery' END);
      v_refunded := v_refunded + (v_res->>'refunded')::numeric;
      v_charged  := v_charged  + (v_res->>'charged')::numeric;
    END IF;

    v_results := v_results || jsonb_build_object(
      'order_id', v_id, 'user_id', v_order.user_id, 'status', p_status,
      'refunded', COALESCE((v_res->>'refunded')::numeric, 0),
      'charged',  COALESCE((v_res->>'charged')::numeric, 0));
  END LOOP;

  RETURN jsonb_build_object(
    'updated', v_updated, 'refunded', v_refunded, 'charged', v_charged, 'orders', v_results);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 9. retry_daily_order_payment — charge an order that finalize had to skip
-- ---------------------------------------------------------------------------
-- For an order skipped by the system (low balance or a payment error), on a
-- day that is finalized and not yet reconciled. If the wallet still cannot
-- cover it the function raises and the order stays skipped.
CREATE OR REPLACE FUNCTION public.retry_daily_order_payment(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_order      public.subscription_daily_orders;
  v_run_status text;
  v_res        jsonb;
BEGIN
  IF NOT internal.is_admin_actor('daily_ops:edit') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT * INTO v_order
  FROM public.subscription_daily_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Daily order not found';
  END IF;

  IF v_order.status <> 'skipped' OR v_order.skip_reason IS NULL THEN
    RAISE EXCEPTION 'Only an order skipped for a failed payment can be retried';
  END IF;

  SELECT status INTO v_run_status
  FROM public.daily_ops_runs WHERE delivery_date = v_order.delivery_date;
  IF v_run_status IS DISTINCT FROM 'finalized' THEN
    RAISE EXCEPTION 'Payment can only be retried while the day is finalized (it is %)',
      COALESCE(v_run_status, 'not started');
  END IF;

  UPDATE public.subscription_daily_orders
  SET status = 'pending', skip_reason = NULL, payment_status = 'pending',
      is_finalized = true, finalized_at = COALESCE(finalized_at, now())
  WHERE id = p_order_id;

  -- Raises (and rolls the order back to skipped) if the wallet is still short.
  v_res := internal.settle_daily_order(p_order_id, 'raise', NULL);

  UPDATE public.daily_ops_runs r
  SET total_orders = t.n, total_value = t.v, updated_at = now()
  FROM (
    SELECT COUNT(*) AS n, COALESCE(SUM(total_value), 0) AS v
    FROM public.subscription_daily_orders
    WHERE delivery_date = v_order.delivery_date
      AND is_finalized = true
      AND status NOT IN ('skipped', 'cancelled')
  ) t
  WHERE r.delivery_date = v_order.delivery_date;

  RETURN jsonb_build_object(
    'charged', (v_res->>'charged')::numeric, 'user_id', v_order.user_id, 'status', 'pending');
END;
$function$;

-- ---------------------------------------------------------------------------
-- 10. reconcile_daily_run — check quantities, settle, close the day
-- ---------------------------------------------------------------------------
-- Reconcile never assumes a delivery. If any finalized order still 'pending'
-- has an item with no delivered quantity, it raises and changes nothing:
-- staff must first record what was delivered (Deliveries page or the run
-- sheet), or mark the order delivered / skipped / cancelled themselves.
--
-- Once every pending order has a quantity for every item, each becomes
-- 'delivered' ('cancelled' when every quantity is 0). Then EVERY finalized
-- order of the day is settled against its recorded quantities, so anything
-- entered but not yet settled is refunded before the day closes.
CREATE OR REPLACE FUNCTION public.reconcile_daily_run(p_delivery_date date, p_admin_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_run_id     uuid;
  v_run_status text;
  v_order      record;
  v_all_zero   boolean;
  v_missing    integer;
  v_res        jsonb;
  v_reconciled integer := 0;
  v_delivered_users jsonb := '[]'::jsonb;
  v_refunds    jsonb := '[]'::jsonb;
  v_errors     jsonb := '[]'::jsonb;
  v_total_refunded numeric := 0;
  v_total_charged  numeric := 0;
BEGIN
  IF NOT internal.is_admin_actor('daily_ops:edit') THEN
    RAISE EXCEPTION 'Not authorized to reconcile a delivery run';
  END IF;

  SELECT id, status INTO v_run_id, v_run_status
  FROM public.daily_ops_runs
  WHERE delivery_date = p_delivery_date
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No run exists for %', p_delivery_date;
  END IF;
  IF v_run_status <> 'finalized' THEN
    RAISE EXCEPTION 'Cannot reconcile: date is %', v_run_status;
  END IF;

  -- Step 0: every pending order must have a delivered quantity for every
  -- item. Nothing is assumed delivered.
  SELECT COUNT(DISTINCT o.id) INTO v_missing
  FROM public.subscription_daily_orders o
  JOIN public.subscription_daily_order_items i ON i.daily_order_id = o.id
  WHERE o.delivery_date = p_delivery_date
    AND o.is_finalized = true
    AND o.status = 'pending'
    AND i.delivered_qty IS NULL;

  IF v_missing > 0 THEN
    RAISE EXCEPTION
      'Cannot reconcile: % pending order(s) still have items with no delivered quantity. Record the delivered quantities (or mark those orders delivered, skipped or cancelled) and try again.',
      v_missing;
  END IF;

  -- Step 1: close out every order still pending, using the recorded quantities.
  FOR v_order IN
    SELECT id, user_id
    FROM public.subscription_daily_orders
    WHERE delivery_date = p_delivery_date
      AND is_finalized = true
      AND status = 'pending'
    ORDER BY user_id, id
    FOR UPDATE
  LOOP
    SELECT COALESCE(bool_and(delivered_qty = 0), true) INTO v_all_zero
    FROM public.subscription_daily_order_items
    WHERE daily_order_id = v_order.id;

    UPDATE public.subscription_daily_orders
    SET status = CASE WHEN v_all_zero THEN 'cancelled' ELSE 'delivered' END
    WHERE id = v_order.id;

    v_reconciled := v_reconciled + 1;
    IF NOT v_all_zero THEN
      v_delivered_users := v_delivered_users || to_jsonb(v_order.user_id);
    END IF;
  END LOOP;

  -- Step 2: settle every finalized order of the day against what is recorded.
  FOR v_order IN
    SELECT id, user_id, total_value
    FROM public.subscription_daily_orders
    WHERE delivery_date = p_delivery_date
      AND is_finalized = true
    ORDER BY user_id, id
  LOOP
    BEGIN
      v_res := internal.settle_daily_order(v_order.id, 'raise', 'short delivery');
      v_total_refunded := v_total_refunded + (v_res->>'refunded')::numeric;
      v_total_charged  := v_total_charged  + (v_res->>'charged')::numeric;
      IF (v_res->>'refunded')::numeric > 0 THEN
        v_refunds := v_refunds || jsonb_build_object(
          'order_id', v_order.id, 'user_id', v_order.user_id,
          'amount', (v_res->>'refunded')::numeric);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      -- The day still closes; the order is reported for manual follow-up.
      v_errors := v_errors || jsonb_build_object(
        'order_id', v_order.id, 'user_id', v_order.user_id,
        'amount', v_order.total_value, 'error', SQLERRM);
    END;
  END LOOP;

  UPDATE public.daily_ops_runs
  SET status = 'reconciled',
      reconciled_at = now(),
      reconciled_by = p_admin_id,
      updated_at = now()
  WHERE id = v_run_id;

  RETURN jsonb_build_object(
    'reconciled',        v_reconciled,
    'delivered_user_ids', v_delivered_users,
    'total_refunded',    v_total_refunded,
    'total_charged',     v_total_charged,
    'refunds',           v_refunds,
    'settlement_errors', v_errors
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 11. A charged order cannot be deleted
-- ---------------------------------------------------------------------------
-- Deleting a daily order that still holds the customer's money would strand
-- it: the wallet was debited and nothing is left to refund against. Cancel the
-- order instead (set_daily_order_status), which refunds it. The customer RPCs
-- and the run-sheet generator already skip paid orders; this covers every
-- other path. SET LOCAL hetha.skip_money_checks = 'on' is the deliberate
-- escape hatch, as for the other money triggers.
CREATE OR REPLACE FUNCTION internal.guard_paid_daily_order_delete()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
BEGIN
  IF internal.money_checks_disabled() THEN
    RETURN OLD;
  END IF;
  IF OLD.paid_amount > 0 THEN
    RAISE EXCEPTION
      'This order has % charged to the customer''s wallet and cannot be deleted. Cancel it instead; that refunds it.',
      OLD.paid_amount;
  END IF;
  RETURN OLD;
END;
$function$;

REVOKE ALL ON FUNCTION internal.guard_paid_daily_order_delete() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_guard_paid_daily_order_delete ON public.subscription_daily_orders;
CREATE TRIGGER trg_guard_paid_daily_order_delete
  BEFORE DELETE ON public.subscription_daily_orders
  FOR EACH ROW EXECUTE FUNCTION internal.guard_paid_daily_order_delete();

-- ---------------------------------------------------------------------------
-- 12. Grants
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.finalize_daily_run(date, uuid)                    FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.unlock_daily_run(date)                            FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.record_subscription_delivery(uuid, jsonb, text)   FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_daily_order_status(uuid[], text)              FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.retry_daily_order_payment(uuid)                   FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.reconcile_daily_run(date, uuid)                   FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.finalize_daily_run(date, uuid)                  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.unlock_daily_run(date)                          TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_subscription_delivery(uuid, jsonb, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_daily_order_status(uuid[], text)            TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.retry_daily_order_payment(uuid)                 TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reconcile_daily_run(date, uuid)                 TO authenticated, service_role;

COMMIT;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- 1. Orders the backfill put on payment hold (ledger and payment_status
--    disagree). Expect 0 rows; any row needs a human look before money can
--    move for that order again:
--      SELECT id, delivery_date, user_id, payment_status, total_value,
--             paid_amount, settlement_hold_reason
--      FROM public.subscription_daily_orders
--      WHERE settlement_hold_reason IS NOT NULL
--      ORDER BY delivery_date DESC;
--
--    To release one after checking it (set paid_amount to the amount the
--    customer has really paid for it):
--      UPDATE public.subscription_daily_orders
--      SET paid_amount = <amount>, settlement_hold_reason = NULL
--      WHERE id = '<order id>';
--
-- 2. Backfill summary — paid orders should all have paid_amount = total_value:
--      SELECT payment_status, COUNT(*) AS orders,
--             SUM(total_value) AS total_value, SUM(paid_amount) AS paid_amount,
--             COUNT(*) FILTER (WHERE settlement_hold_reason IS NOT NULL) AS on_hold
--      FROM public.subscription_daily_orders
--      GROUP BY payment_status ORDER BY payment_status;
--
-- 3. Ledger agrees with paid_amount for every order not on hold (expect 0):
--      SELECT COUNT(*) FROM public.subscription_daily_orders o
--      LEFT JOIN (
--        SELECT reference_id,
--               SUM(CASE WHEN type = 'debit' THEN amount ELSE -amount END) AS net
--        FROM public.wallet_transactions
--        WHERE reference_type = 'subscription' GROUP BY reference_id
--      ) l ON l.reference_id = o.id
--      WHERE o.settlement_hold_reason IS NULL
--        AND round(COALESCE(l.net, 0), 2) <> round(o.paid_amount, 2);
--
-- 4. The delete guard exists (1 row):
--      SELECT tgname FROM pg_trigger WHERE tgname = 'trg_guard_paid_daily_order_delete';
--
-- 5. Grants — expect t, t, t, t, t, t, f, f:
--      SELECT
--        has_function_privilege('authenticated', 'public.finalize_daily_run(date, uuid)', 'EXECUTE'),
--        has_function_privilege('authenticated', 'public.unlock_daily_run(date)', 'EXECUTE'),
--        has_function_privilege('authenticated', 'public.record_subscription_delivery(uuid, jsonb, text)', 'EXECUTE'),
--        has_function_privilege('authenticated', 'public.set_daily_order_status(uuid[], text)', 'EXECUTE'),
--        has_function_privilege('authenticated', 'public.retry_daily_order_payment(uuid)', 'EXECUTE'),
--        has_function_privilege('authenticated', 'public.reconcile_daily_run(date, uuid)', 'EXECUTE'),
--        has_function_privilege('anon',          'public.finalize_daily_run(date, uuid)', 'EXECUTE'),
--        has_function_privilege('authenticated', 'internal.settle_daily_order(uuid, text, text)', 'EXECUTE');
