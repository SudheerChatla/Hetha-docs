-- Migration 024: Free delivery for serviceable pincodes
--
-- Run in: Supabase SQL Editor (the whole file; it is wrapped in one transaction)
--
-- ─── Rule ───────────────────────────────────────────────────────────────────
-- Pincodes saved under Delivery Areas / Pincodes in the admin panel are where
-- Hetha's own riders deliver (no third-party courier), and the client does not
-- charge a delivery fee there. So:
--
--   delivery charge = 0      when the delivery address pincode is in
--                            public.pincodes AND its delivery area is active
--   delivery charge = tiers  otherwise (unchanged weight-tier logic; variants
--                            flagged free_delivery still contribute no weight)
--
-- "Serviceable" is exactly internal.serviceable_area_id() from migration 016 —
-- the same check that gates local-only products and that the customer app
-- uses to decide which products to show. An area switched off in the admin
-- panel (is_active = false) is NOT serviceable, so its pincodes pay the tier
-- charge, same as before.
--
-- ─── What changes ───────────────────────────────────────────────────────────
-- Before this migration the fee never looked at the address:
-- internal.compute_delivery_charge(p_items) only knew the cart, quote_cart had
-- no address parameter, and place_order_core / create_payment_intent both
-- charged weight tiers everywhere.
--
--   1. internal.serviceable_area_id(text)          restated verbatim (016) so
--                                                  this migration is
--                                                  self-contained
--   2. internal.compute_delivery_charge(jsonb, text) NEW overload: 0 for a
--                                                  serviceable pincode, else
--                                                  the existing 1-arg tiers
--   3. public.quote_cart(jsonb, uuid DEFAULT NULL)  replaces quote_cart(jsonb).
--                                                  With an address id the
--                                                  quote uses that address's
--                                                  pincode; without one it is
--                                                  the old weight-only quote,
--                                                  so app builds that don't
--                                                  send an address keep
--                                                  working unchanged.
--   4. internal.place_order_core(...)              fee now uses the order's
--                                                  delivery address pincode
--                                                  (wallet, COD, admin ad-hoc,
--                                                  and Razorpay settlement all
--                                                  go through here)
--   5. public.create_payment_intent(...)           Razorpay amount now quoted
--                                                  with the order's address,
--                                                  so the amount the customer
--                                                  pays matches the order that
--                                                  finalize_order_payment
--                                                  creates
--
-- Unchanged: the admin fee override in place_order_core (an admin caller who
-- passes a non-NULL p_delivery_charge still sets the fee, never below 0), the
-- local-only product check from 016, and every other money invariant.
--
-- quote_cart has to be dropped and recreated rather than overloaded: keeping
-- both quote_cart(jsonb) and quote_cart(jsonb, uuid DEFAULT NULL) would make a
-- call with only p_cart_items ambiguous for PostgREST.
--
-- In-flight Razorpay intents created before this migration keep the amount
-- they were quoted; if one settles afterwards for a serviceable pincode, the
-- order records a ₹0 fee and the captured amount covers it (the settlement
-- check only refuses UNDER-payment).

BEGIN;

-- ─── 1. internal.serviceable_area_id (unchanged from migration 016) ─────────
CREATE OR REPLACE FUNCTION internal.serviceable_area_id(p_pincode text)
 RETURNS uuid
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
  SELECT p.area_id
  FROM public.pincodes p
  JOIN public.delivery_areas a ON a.id = p.area_id
  WHERE p.pincode = p_pincode AND a.is_active
  LIMIT 1;
$function$;


-- ─── 2. internal.compute_delivery_charge(jsonb, text) ───────────────────────
-- Pincode-aware delivery charge. A serviceable pincode is delivered by
-- Hetha's own riders and pays nothing; anywhere else falls through to the
-- existing weight-tier calculation, internal.compute_delivery_charge(jsonb).
CREATE OR REPLACE FUNCTION internal.compute_delivery_charge(p_items jsonb, p_pincode text)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
BEGIN
  IF p_pincode IS NOT NULL AND internal.serviceable_area_id(p_pincode) IS NOT NULL THEN
    RETURN 0;
  END IF;

  RETURN internal.compute_delivery_charge(p_items);
END;
$function$;


-- ─── 3. public.quote_cart(jsonb, uuid DEFAULT NULL) ─────────────────────────
DROP FUNCTION IF EXISTS public.quote_cart(jsonb);

-- Read-only quote for display: {subtotal, delivery_charge, total} from the
-- catalog — the same maths place_order uses, so the UI matches the charge.
-- p_address_id: the delivery address the customer is shopping for. When given,
-- the fee follows that address's pincode (₹0 in a serviceable area). The
-- address must belong to the caller unless the caller is staff/service role.
-- When omitted, the quote is the weight-tier charge (pre-024 behaviour).
CREATE OR REPLACE FUNCTION public.quote_cart(p_cart_items jsonb, p_address_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_subtotal numeric := 0;
  v_delivery numeric := 0;
  v_pincode  text;
BEGIN
  SELECT COALESCE(SUM(round(c.unit_price * c.quantity, 2)), 0)
  INTO v_subtotal
  FROM internal.normalize_cart(p_cart_items) c;

  IF p_address_id IS NULL THEN
    v_delivery := internal.compute_delivery_charge(p_cart_items);
  ELSE
    SELECT a.pincode INTO v_pincode
    FROM public.addresses a
    WHERE a.id = p_address_id
      AND (a.user_id = auth.uid() OR internal.is_admin_actor('orders:view'));

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Address not found or does not belong to user';
    END IF;

    v_delivery := internal.compute_delivery_charge(p_cart_items, v_pincode);
  END IF;

  RETURN jsonb_build_object(
    'subtotal',        round(v_subtotal, 2),
    'delivery_charge', round(v_delivery, 2),
    'total',           round(v_subtotal + v_delivery, 2)
  );
END;
$function$;


-- ─── 4. internal.place_order_core ───────────────────────────────────────────
-- Body identical to the current version (007 + 016) except the delivery
-- charge line, which now passes the delivery address pincode.
CREATE OR REPLACE FUNCTION internal.place_order_core(p_user_id uuid, p_address_id uuid, p_payment_method text, p_delivery_charge numeric, p_cart_items jsonb, p_is_admin boolean DEFAULT false, p_paid_externally boolean DEFAULT false, p_razorpay_order_id text DEFAULT NULL::text, p_razorpay_payment_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_order_id       uuid;
  v_order_number   text;
  v_subtotal       numeric := 0;
  v_delivery       numeric := 0;
  v_total          numeric := 0;
  v_address        RECORD;
  v_wallet_balance numeric;
  v_commitment     numeric := 0;
  v_reserve        numeric := 0;
  v_status         text;
  v_payment_status text;
  v_wallet_used    numeric := 0;
BEGIN
  IF p_payment_method NOT IN ('wallet', 'razorpay', 'cod') THEN
    RAISE EXCEPTION 'Unsupported payment method: %', p_payment_method;
  END IF;

  SELECT * INTO v_address
  FROM public.addresses
  WHERE id = p_address_id AND user_id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Address not found or does not belong to user';
  END IF;

  -- Delivery scope enforcement (migration 016): local-only products cannot
  -- be ordered from a non-serviceable pincode. Admin callers bypass.
  IF internal.serviceable_area_id(v_address.pincode) IS NULL
     AND NOT COALESCE(p_is_admin, false)
     AND EXISTS (
       SELECT 1
       FROM internal.normalize_cart(p_cart_items) c
       JOIN public.product_variants pv ON pv.id = c.variant_id
       JOIN public.products pr ON pr.id = pv.product_id
       WHERE pr.delivery_scope = 'local'
     )
  THEN
    RAISE EXCEPTION
      'Some items in your cart are only available for local delivery. Pincode % is not in our delivery area.',
      v_address.pincode;
  END IF;

  -- Prices always come from the catalog, never from the payload.
  SELECT COALESCE(SUM(round(c.unit_price * c.quantity, 2)), 0)
  INTO v_subtotal
  FROM internal.normalize_cart(p_cart_items) c;

  IF v_subtotal <= 0 THEN
    RAISE EXCEPTION 'Order subtotal must be greater than zero';
  END IF;

  -- Delivery charge: server-computed for customers — ₹0 for a serviceable
  -- pincode (migration 024), weight tiers elsewhere. Admins may override it
  -- (fee waivers / manual corrections) but never below zero.
  IF p_is_admin AND p_delivery_charge IS NOT NULL THEN
    v_delivery := round(GREATEST(p_delivery_charge, 0), 2);
  ELSE
    v_delivery := internal.compute_delivery_charge(p_cart_items, v_address.pincode);
  END IF;

  v_total := round(v_subtotal + v_delivery, 2);

  v_order_number := 'ORD-' || to_char(CURRENT_TIMESTAMP, 'YYYYMMDDHH24MISS')
                    || '-' || lpad((floor(random() * 10000))::int::text, 4, '0');

  IF p_payment_method = 'wallet' THEN
    SELECT wallet_balance INTO v_wallet_balance
    FROM public.users WHERE id = p_user_id FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'User not found';
    END IF;

    -- 3-day subscription buffer (previously client-only). Skipped for admin
    -- placed orders so ops can still fulfil edge cases deliberately.
    IF NOT p_is_admin THEN
      v_commitment := COALESCE(public.get_user_daily_commitment(p_user_id), 0);
      v_reserve    := round(v_commitment * 3, 2);
    END IF;

    IF COALESCE(v_wallet_balance, 0) < v_total + v_reserve THEN
      IF v_reserve > 0 THEN
        RAISE EXCEPTION
          'Insufficient wallet balance. Required: % (order %) plus % reserved for 3 days of subscriptions, available: %',
          v_total + v_reserve, v_total, v_reserve, v_wallet_balance;
      ELSE
        RAISE EXCEPTION 'Insufficient Wallet Balance! Required: %, Available: %',
          v_total, v_wallet_balance;
      END IF;
    END IF;

    v_status         := 'placed';
    v_payment_status := 'paid';
    v_wallet_used    := v_total;

  ELSIF p_payment_method = 'cod' THEN
    v_status         := 'placed';
    v_payment_status := 'pending';

  ELSE  -- razorpay
    IF p_paid_externally THEN
      v_status         := 'placed';
      v_payment_status := 'paid';
    ELSE
      -- Nobody may create a "placed" online-payment order without a verified
      -- payment. Such rows stay in payment_pending and never reach the run
      -- sheet / packing list.
      v_status         := 'payment_pending';
      v_payment_status := 'pending';
    END IF;
  END IF;

  INSERT INTO public.orders (
    order_number, user_id, address_snapshot_id, status, payment_method,
    payment_status, subtotal, delivery_charge, total, wallet_amount_used,
    razorpay_amount, razorpay_order_id, razorpay_payment_id,
    payment_pending_expires_at, pincode,
    snapshot_name, snapshot_phone, snapshot_address_line1, snapshot_address_line2,
    snapshot_landmark, snapshot_city, snapshot_state, snapshot_pincode,
    snapshot_address_type
  ) VALUES (
    v_order_number, p_user_id, p_address_id, v_status, p_payment_method,
    v_payment_status, v_subtotal, v_delivery, v_total, v_wallet_used,
    CASE WHEN p_payment_method = 'razorpay' AND p_paid_externally THEN v_total ELSE 0 END,
    p_razorpay_order_id, p_razorpay_payment_id,
    CASE WHEN v_status = 'payment_pending' THEN now() + interval '30 minutes' ELSE NULL END,
    v_address.pincode,
    v_address.name, v_address.phone_number, v_address.address_line1, v_address.address_line2,
    v_address.landmark, v_address.city, v_address.state, v_address.pincode,
    v_address.address_type
  ) RETURNING id INTO v_order_id;

  INSERT INTO public.order_items (
    order_id, variant_id, product_name_snapshot, variant_label_snapshot,
    unit_price, quantity, total_price
  )
  SELECT
    v_order_id, c.variant_id, c.product_name, c.variant_label,
    c.unit_price, c.quantity, round(c.unit_price * c.quantity, 2)
  FROM internal.normalize_cart(p_cart_items) c;

  IF p_payment_method = 'wallet' THEN
    PERFORM internal.apply_wallet_delta(
      p_user_id, v_total, 'debit',
      'Order ' || v_order_number || ' checkout',
      CASE WHEN p_is_admin THEN 'admin' ELSE 'user' END,
      'order', v_order_id::text
    );
  END IF;

  INSERT INTO public.order_tracking (order_id, status) VALUES (v_order_id, v_status);

  RETURN jsonb_build_object(
    'order_id',        v_order_id,
    'order_number',    v_order_number,
    'subtotal',        v_subtotal,
    'delivery_charge', v_delivery,
    'total',           v_total,
    'status',          v_status,
    'payment_status',  v_payment_status
  );
END;
$function$;


-- ─── 5. public.create_payment_intent ────────────────────────────────────────
-- Body identical to migration 008 except the order quote, which now passes the
-- (ownership-checked) delivery address so the Razorpay amount follows the
-- pincode rule.
CREATE OR REPLACE FUNCTION public.create_payment_intent(p_user_id uuid, p_purpose text, p_amount_paise bigint DEFAULT NULL::bigint, p_address_id uuid DEFAULT NULL::uuid, p_cart_items jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
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

    -- Authoritative amount: catalog prices + server-computed delivery charge
    -- for this delivery address (₹0 in a serviceable area — migration 024).
    v_quote := public.quote_cart(p_cart_items, p_address_id);
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
$function$;


-- ─── 6. Grants ──────────────────────────────────────────────────────────────
-- quote_cart keeps the post-015 surface: signed-in customers and service role,
-- never anon. Supabase's default privileges grant EXECUTE on new public
-- functions to anon, so the REVOKE is required, not cosmetic.
REVOKE ALL ON FUNCTION public.quote_cart(jsonb, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.quote_cart(jsonb, uuid) TO authenticated, service_role;

-- The new internal overload is only ever called from SECURITY DEFINER
-- functions above.
REVOKE ALL ON FUNCTION internal.compute_delivery_charge(jsonb, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION internal.place_order_core(uuid, uuid, text, numeric, jsonb, boolean, boolean, text, text)
  TO service_role;

COMMIT;

-- ─── Verification (run after the migration) ─────────────────────────────────
--   -- 1. Only the new quote_cart signature exists; anon cannot call it.
--   SELECT p.oid::regprocedure,
--          has_function_privilege('anon', p.oid, 'EXECUTE')          AS anon,
--          has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--   WHERE n.nspname = 'public' AND p.proname = 'quote_cart';
--   -- expect one row: quote_cart(jsonb,uuid) | false | true
--
--   -- 2. Which pincodes now get free delivery (active areas only).
--   SELECT p.pincode, a.display_name
--   FROM public.pincodes p JOIN public.delivery_areas a ON a.id = p.area_id
--   WHERE a.is_active ORDER BY a.display_name, p.pincode;
