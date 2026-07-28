-- =============================================================================
-- Migration 008 — PAYMENT INTENTS (kills amount tampering + payment replay)
-- =============================================================================
-- Run in: Supabase SQL Editor, AFTER 007_money_integrity.sql.
--
-- WHAT THIS FIXES
--   Before: the Razorpay edge function trusted the client for the amount.
--     • wallet top-up  : `verify-payment` credited `body.amount`. The HMAC only
--       proves that <order_id|payment_id> is a real Razorpay pair — it says
--       nothing about how much was paid. Pay ₹1, post amount = 100000, get
--       ₹1,00,000 of wallet credit. The same (order_id, payment_id, signature)
--       triple could also be replayed indefinitely for repeat credits.
--     • order payment  : `verify-order-payment` never compared the amount paid
--       to the order value, and re-posting one successful payment placed
--       unlimited "paid" orders.
--
--   After: the server creates a *payment intent* holding the authoritative
--   amount (computed from the catalog for orders), Razorpay is asked how much
--   was actually captured, and each Razorpay payment id can be consumed once.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- payment_intents
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.payment_intents (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             uuid NOT NULL REFERENCES public.users(id),
  purpose             text NOT NULL CHECK (purpose IN ('wallet_topup', 'order')),
  status              text NOT NULL DEFAULT 'created'
                        CHECK (status IN ('created', 'paid', 'failed', 'expired')),
  amount_paise        bigint NOT NULL CHECK (amount_paise > 0),
  razorpay_order_id   text UNIQUE,
  razorpay_payment_id text UNIQUE,
  address_id          uuid REFERENCES public.addresses(id),
  cart_items          jsonb,
  order_id            uuid REFERENCES public.orders(id),
  amount_paid_paise   bigint,
  created_at          timestamptz NOT NULL DEFAULT now(),
  expires_at          timestamptz NOT NULL DEFAULT now() + interval '30 minutes',
  consumed_at         timestamptz
);

CREATE INDEX IF NOT EXISTS idx_payment_intents_user       ON public.payment_intents(user_id);
CREATE INDEX IF NOT EXISTS idx_payment_intents_rzp_order  ON public.payment_intents(razorpay_order_id);

-- Only the service role (edge functions) touches this table. RLS is on with no
-- policies, so anon/authenticated see nothing even if grants were added later.
ALTER TABLE public.payment_intents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payment_intents FROM anon, authenticated;
GRANT ALL ON public.payment_intents TO service_role;

-- One Razorpay payment can back at most one order.
CREATE UNIQUE INDEX IF NOT EXISTS uq_orders_razorpay_payment_id
  ON public.orders (razorpay_payment_id)
  WHERE razorpay_payment_id IS NOT NULL;


-- ---------------------------------------------------------------------------
-- create_payment_intent — server computes the amount that must be paid
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_payment_intent(
  p_user_id      uuid,
  p_purpose      text,
  p_amount_paise bigint DEFAULT NULL,
  p_address_id   uuid   DEFAULT NULL,
  p_cart_items   jsonb  DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, internal
AS $$
DECLARE
  v_quote        jsonb;
  v_amount_paise bigint;
  v_intent_id    uuid;
  v_min_topup    bigint := 100;         -- ₹1
  v_max_topup    bigint := 5000000;     -- ₹50,000
BEGIN
  IF NOT internal.is_service_actor() THEN
    RAISE EXCEPTION 'Payment intents may only be created server-side';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'user id is required';
  END IF;

  IF p_purpose = 'order' THEN
    IF p_address_id IS NULL THEN
      RAISE EXCEPTION 'address id is required for an order payment';
    END IF;
    PERFORM 1 FROM public.addresses
      WHERE id = p_address_id AND user_id = p_user_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Address not found or does not belong to user';
    END IF;

    -- Authoritative amount: catalog prices + server-computed delivery charge.
    v_quote := public.quote_cart(p_cart_items);
    v_amount_paise := round((v_quote->>'total')::numeric * 100)::bigint;

    IF v_amount_paise <= 0 THEN
      RAISE EXCEPTION 'Order total must be greater than zero';
    END IF;

  ELSIF p_purpose = 'wallet_topup' THEN
    IF p_amount_paise IS NULL THEN
      RAISE EXCEPTION 'amount is required for a wallet top-up';
    END IF;
    IF p_amount_paise < v_min_topup OR p_amount_paise > v_max_topup THEN
      RAISE EXCEPTION 'Top-up amount must be between % and % paise', v_min_topup, v_max_topup;
    END IF;
    v_amount_paise := p_amount_paise;
    v_quote := jsonb_build_object('total', round(v_amount_paise::numeric / 100, 2));

  ELSE
    RAISE EXCEPTION 'Unknown payment purpose: %', p_purpose;
  END IF;

  INSERT INTO public.payment_intents (
    user_id, purpose, amount_paise, address_id, cart_items
  ) VALUES (
    p_user_id, p_purpose, v_amount_paise, p_address_id,
    CASE WHEN p_purpose = 'order' THEN p_cart_items ELSE NULL END
  ) RETURNING id INTO v_intent_id;

  RETURN jsonb_build_object(
    'intent_id',     v_intent_id,
    'amount_paise',  v_amount_paise,
    'quote',         v_quote
  );
END;
$$;


-- ---------------------------------------------------------------------------
-- attach_razorpay_order — links the created Razorpay order to the intent
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.attach_razorpay_order(
  p_intent_id         uuid,
  p_razorpay_order_id text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, internal
AS $$
BEGIN
  IF NOT internal.is_service_actor() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  UPDATE public.payment_intents
  SET razorpay_order_id = p_razorpay_order_id
  WHERE id = p_intent_id AND status = 'created';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payment intent % not found or already consumed', p_intent_id;
  END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- finalize_wallet_topup — idempotent, credits only what Razorpay captured
-- ---------------------------------------------------------------------------
-- p_amount_paid_paise MUST come from a server-side Razorpay API fetch of the
-- payment, never from the client.
CREATE OR REPLACE FUNCTION public.finalize_wallet_topup(
  p_intent_id           uuid,
  p_razorpay_order_id   text,
  p_razorpay_payment_id text,
  p_amount_paid_paise   bigint
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, internal
AS $$
DECLARE
  v_intent   public.payment_intents;
  v_credit   numeric;
  v_balance  numeric;
BEGIN
  IF NOT internal.is_service_actor() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT * INTO v_intent
  FROM public.payment_intents
  WHERE id = p_intent_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payment intent not found';
  END IF;

  IF v_intent.purpose <> 'wallet_topup' THEN
    RAISE EXCEPTION 'Payment intent is not a wallet top-up';
  END IF;

  -- Replay protection: the same payment can only ever be credited once.
  IF v_intent.status = 'paid' THEN
    IF v_intent.razorpay_payment_id = p_razorpay_payment_id THEN
      SELECT wallet_balance INTO v_balance FROM public.users WHERE id = v_intent.user_id;
      RETURN jsonb_build_object(
        'already_processed', true,
        'credited',          round(COALESCE(v_intent.amount_paid_paise, 0)::numeric / 100, 2),
        'new_balance',       v_balance
      );
    END IF;
    RAISE EXCEPTION 'Payment intent already settled with a different payment';
  END IF;

  IF v_intent.razorpay_order_id IS DISTINCT FROM p_razorpay_order_id THEN
    RAISE EXCEPTION 'Razorpay order does not match this payment intent';
  END IF;

  IF p_amount_paid_paise IS NULL OR p_amount_paid_paise <= 0 THEN
    RAISE EXCEPTION 'Captured amount is missing';
  END IF;

  -- Credit exactly what was captured, never more than the intent asked for.
  v_credit := round(LEAST(p_amount_paid_paise, v_intent.amount_paise)::numeric / 100, 2);

  UPDATE public.payment_intents
  SET status = 'paid',
      razorpay_payment_id = p_razorpay_payment_id,
      amount_paid_paise = p_amount_paid_paise,
      consumed_at = now()
  WHERE id = p_intent_id;

  v_balance := internal.apply_wallet_delta(
    v_intent.user_id, v_credit, 'credit',
    'Razorpay Wallet Top-up (' || p_razorpay_payment_id || ')',
    'system', 'wallet_topup', p_intent_id::text
  );

  RETURN jsonb_build_object(
    'already_processed', false,
    'credited',          v_credit,
    'new_balance',       v_balance
  );
END;
$$;


-- ---------------------------------------------------------------------------
-- finalize_order_payment — idempotent order placement after a real payment
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.finalize_order_payment(
  p_intent_id           uuid,
  p_razorpay_order_id   text,
  p_razorpay_payment_id text,
  p_amount_paid_paise   bigint
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, internal
AS $$
DECLARE
  v_intent public.payment_intents;
  v_result jsonb;
BEGIN
  IF NOT internal.is_service_actor() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT * INTO v_intent
  FROM public.payment_intents
  WHERE id = p_intent_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payment intent not found';
  END IF;

  IF v_intent.purpose <> 'order' THEN
    RAISE EXCEPTION 'Payment intent is not an order payment';
  END IF;

  IF v_intent.status = 'paid' THEN
    IF v_intent.razorpay_payment_id = p_razorpay_payment_id THEN
      RETURN jsonb_build_object('already_processed', true, 'order_id', v_intent.order_id);
    END IF;
    RAISE EXCEPTION 'Payment intent already settled with a different payment';
  END IF;

  IF v_intent.razorpay_order_id IS DISTINCT FROM p_razorpay_order_id THEN
    RAISE EXCEPTION 'Razorpay order does not match this payment intent';
  END IF;

  -- Underpayment check: the captured amount must cover the amount this intent
  -- was created for (which was computed from the catalog, not the client).
  IF p_amount_paid_paise IS NULL OR p_amount_paid_paise < v_intent.amount_paise THEN
    RAISE EXCEPTION 'Captured amount % is less than the order amount %',
      COALESCE(p_amount_paid_paise, 0), v_intent.amount_paise;
  END IF;

  v_result := internal.place_order_core(
    p_user_id             => v_intent.user_id,
    p_address_id          => v_intent.address_id,
    p_payment_method      => 'razorpay',
    p_delivery_charge     => NULL,
    p_cart_items          => v_intent.cart_items,
    p_is_admin            => false,
    p_paid_externally     => true,
    p_razorpay_order_id   => p_razorpay_order_id,
    p_razorpay_payment_id => p_razorpay_payment_id
  );

  UPDATE public.payment_intents
  SET status = 'paid',
      razorpay_payment_id = p_razorpay_payment_id,
      amount_paid_paise = p_amount_paid_paise,
      order_id = (v_result->>'order_id')::uuid,
      consumed_at = now()
  WHERE id = p_intent_id;

  RETURN v_result || jsonb_build_object('already_processed', false);
END;
$$;


-- ---------------------------------------------------------------------------
-- mark_payment_intent_failed — housekeeping for abandoned/failed checkouts
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mark_payment_intent_failed(p_intent_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, internal
AS $$
BEGIN
  IF NOT internal.is_service_actor() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  UPDATE public.payment_intents
  SET status = 'failed'
  WHERE id = p_intent_id AND status = 'created';
END;
$$;


-- ---------------------------------------------------------------------------
-- Execution grants — service role only (edge functions)
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.create_payment_intent(uuid, text, bigint, uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.attach_razorpay_order(uuid, text)                      FROM PUBLIC;
REVOKE ALL ON FUNCTION public.finalize_wallet_topup(uuid, text, text, bigint)        FROM PUBLIC;
REVOKE ALL ON FUNCTION public.finalize_order_payment(uuid, text, text, bigint)       FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mark_payment_intent_failed(uuid)                       FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.create_payment_intent(uuid, text, bigint, uuid, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.attach_razorpay_order(uuid, text)                      TO service_role;
GRANT EXECUTE ON FUNCTION public.finalize_wallet_topup(uuid, text, text, bigint)        TO service_role;
GRANT EXECUTE ON FUNCTION public.finalize_order_payment(uuid, text, text, bigint)       TO service_role;
GRANT EXECUTE ON FUNCTION public.mark_payment_intent_failed(uuid)                       TO service_role;
