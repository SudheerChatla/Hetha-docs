-- Migration 016: Product Delivery Scope
-- Adds delivery_scope column to products, replacing the unused is_local boolean.
-- Values: 'local' (available only in serviceable pincodes) or 'all_india' (ships anywhere).
-- Also adds a helper function and enforcement in place_order.

-- 1. Add delivery_scope column with CHECK constraint
ALTER TABLE public.products
  ADD COLUMN delivery_scope text NOT NULL DEFAULT 'local'
    CHECK (delivery_scope IN ('local', 'all_india'));

-- 2. Backfill from existing is_local values
UPDATE public.products
  SET delivery_scope = CASE WHEN is_local THEN 'local' ELSE 'all_india' END;

-- 3. Index for filtering
CREATE INDEX idx_products_delivery_scope ON public.products USING btree (delivery_scope);

-- 4. Helper: check if a pincode is in a serviceable delivery area
CREATE OR REPLACE FUNCTION internal.serviceable_area_id(p_pincode text)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, internal
AS $$
  SELECT p.area_id
  FROM public.pincodes p
  JOIN public.delivery_areas a ON a.id = p.area_id
  WHERE p.pincode = p_pincode AND a.is_active
  LIMIT 1;
$$;

-- 5. Patch internal.place_order_core to reject local-only products from
--    non-serviceable pincodes. The check is inserted after the address lookup.
--    public.place_order is a thin wrapper that delegates to this function,
--    so the enforcement applies to all callers (app, admin, edge fn).
--
--    The block added (right after "IF NOT FOUND THEN RAISE 'Address not found'"):
--
--    ┌─────────────────────────────────────────────────────────────────────┐
--    │  IF internal.serviceable_area_id(v_address.pincode) IS NULL         │
--    │     AND NOT COALESCE(p_is_admin, false)                             │
--    │     AND EXISTS (                                                    │
--    │       SELECT 1                                                      │
--    │       FROM internal.normalize_cart(p_cart_items) c                   │
--    │       JOIN public.product_variants pv ON pv.id = c.variant_id       │
--    │       JOIN public.products pr ON pr.id = pv.product_id              │
--    │       WHERE pr.delivery_scope = 'local'                             │
--    │     )                                                               │
--    │  THEN                                                               │
--    │    RAISE EXCEPTION                                                  │
--    │      'Some items in your cart are only available for local delivery. │
--    │       Pincode % is not in our delivery area.',                       │
--    │      v_address.pincode;                                             │
--    │  END IF;                                                            │
--    └─────────────────────────────────────────────────────────────────────┘
--
--    Full CREATE OR REPLACE below (required because we're modifying the body).

CREATE OR REPLACE FUNCTION internal.place_order_core(
  p_user_id           uuid,
  p_address_id        uuid,
  p_payment_method    text,
  p_delivery_charge   numeric,
  p_cart_items        jsonb,
  p_is_admin          boolean DEFAULT false,
  p_paid_externally   boolean DEFAULT false,
  p_razorpay_order_id text    DEFAULT NULL,
  p_razorpay_payment_id text  DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, internal
AS $$
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

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Delivery scope enforcement (migration 016)
  -- Local-only products cannot be ordered from a non-serviceable pincode.
  -- Admin-placed orders bypass this (same pattern as 3-day buffer bypass).
  -- ═══════════════════════════════════════════════════════════════════════════
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

  -- Delivery charge: server-computed for customers. Admins may override it
  -- (fee waivers / manual corrections) but never below zero.
  IF p_is_admin AND p_delivery_charge IS NOT NULL THEN
    v_delivery := round(GREATEST(p_delivery_charge, 0), 2);
  ELSE
    v_delivery := internal.compute_delivery_charge(p_cart_items);
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

    -- 3-day subscription buffer. Skipped for admin placed orders.
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
    'total',           v_total,
    'status',          v_status,
    'payment_status',  v_payment_status
  );
END;
$$;

-- Re-grant (internal functions are only callable by the owning role, but
-- explicitly confirm service_role can reach it for edge function paths).
GRANT EXECUTE ON FUNCTION internal.place_order_core(uuid, uuid, text, numeric, jsonb, boolean, boolean, text, text)
  TO service_role;
