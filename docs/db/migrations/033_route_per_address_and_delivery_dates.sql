-- Migration 033: Route per address + automatic one-time order delivery dates
--
-- Run in: Supabase SQL Editor (the whole file; it is wrapped in one transaction)
--
-- ─── Problem ────────────────────────────────────────────────────────────────
-- 1. Delivery routes are assigned per subscription, but the operating model is
--    that a route lives on the customer's ADDRESS (all deliveries to that
--    address go via one route, regardless of whether they are subscriptions or
--    one-time orders). Staff assign a route to an address; it must belong to
--    the delivery area that serves that address's pincode.
--
-- 2. One-time orders have expected_delivery_date but nothing writes it. The
--    new Deliveries screen needs to know WHEN each order should be delivered,
--    following the area's delivery frequency (1 = daily, 2 = alternate days).
--    If the order is placed after the area's cutoff time, the earliest date
--    shifts forward by one day.
--
-- 3. Short deliveries on prepaid one-time orders must refund the difference
--    to the customer's wallet without altering the order totals (migration 012
--    enforces subtotal = Σ items, so we only credit the wallet).
--
-- 4. The app's create_subscription never sets address_id (only the admin panel
--    patches it afterwards) — we need to store it at creation time so the new
--    per-route Deliveries screen can show which address a subscription uses.
--
-- ─── Fix ─────────────────────────────────────────────────────────────────────
-- 1. Add addresses.route_id (uuid FK → delivery_routes). Index it.
-- 2. Backfill from subscriptions: take the most recent subscription's route_id
--    where that route's area matches the address pincode's area.
-- 3. Trigger guard_address_route: non-admin callers cannot change route_id;
--    route must serve the address pincode (or we unassign when the customer
--    moves their address to another area).
-- 4. set_address_route RPC: admin-only, validates route serves the pincode.
-- 5. internal.next_delivery_date: computes the next delivery day for an area.
-- 6. Trigger set_order_delivery_date: auto-populates expected_delivery_date on
--    INSERT when NULL, using the area's schedule and cutoff time.
-- 7. Add order_items.delivered_qty, orders.delivered_at, orders.tracking_info.
-- 8. record_order_delivery RPC: records actual quantities delivered, refunds
--    short deliveries on paid orders.
-- 9. reschedule_order RPC: admin can move an order to a different date.
-- 10. Update create_subscription_core to store address_id from the payload.
-- 11. Backfill subscriptions.address_id and orders.expected_delivery_date.

BEGIN;

-- ---------------------------------------------------------------------------
-- 0. internal.today_ist() — today's calendar day in India
-- ---------------------------------------------------------------------------
-- Supabase runs Postgres in UTC, so CURRENT_DATE is still "yesterday" between
-- 00:00 and 05:30 IST. Every date the business cares about (delivery days,
-- cut-offs, "not in the past") is an India calendar day, so new code uses this
-- helper instead of CURRENT_DATE.
CREATE OR REPLACE FUNCTION internal.today_ist()
  RETURNS date
  LANGUAGE sql
  STABLE
AS $function$
  SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date;
$function$;

-- ---------------------------------------------------------------------------
-- 1. addresses.route_id
-- ---------------------------------------------------------------------------
ALTER TABLE public.addresses
  ADD COLUMN IF NOT EXISTS route_id uuid;

-- Named explicitly (fk_address_route) so the snapshot, the live database and
-- the admin panel's PostgREST embed hints all agree.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'fk_address_route'
       AND conrelid = 'public.addresses'::regclass
  ) THEN
    ALTER TABLE public.addresses
      ADD CONSTRAINT fk_address_route
      FOREIGN KEY (route_id) REFERENCES public.delivery_routes(id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_addresses_route_id ON public.addresses (route_id);

-- ---------------------------------------------------------------------------
-- 2. Backfill addresses.route_id from subscriptions
--    Only where the route's area matches the address pincode's area.
-- ---------------------------------------------------------------------------
UPDATE public.addresses a
SET route_id = sub.route_id
FROM (
  SELECT DISTINCT ON (s.address_id)
    s.address_id,
    s.route_id
  FROM public.subscriptions s
  JOIN public.delivery_routes dr ON dr.id = s.route_id
  WHERE s.address_id IS NOT NULL
    AND s.route_id IS NOT NULL
  ORDER BY s.address_id, s.created_at DESC
) sub
JOIN public.addresses addr ON addr.id = sub.address_id
JOIN public.pincodes p ON p.pincode = addr.pincode
JOIN public.delivery_routes dr ON dr.id = sub.route_id
WHERE a.id = sub.address_id
  AND dr.area_id = p.area_id;

-- ---------------------------------------------------------------------------
-- 3. Trigger: guard_address_route
--    - Non-admin callers cannot change route_id
--    - Route must serve the address pincode (or gets unassigned on area change)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION internal.guard_address_route()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_pincode_area_id uuid;
  v_route_area_id   uuid;
  v_route_name      text;
BEGIN
  -- Check if route_id is being changed
  IF TG_OP = 'INSERT' THEN
    -- On INSERT, if route_id is non-null, only admin/service can set it
    IF NEW.route_id IS NOT NULL THEN
      IF NOT internal.is_admin_actor('customers:edit') AND NOT internal.is_service_actor() THEN
        RAISE EXCEPTION 'The delivery route is set by staff';
      END IF;
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    -- On UPDATE, check if route_id is changing
    IF NEW.route_id IS DISTINCT FROM OLD.route_id THEN
      IF NOT internal.is_admin_actor('customers:edit') AND NOT internal.is_service_actor() THEN
        RAISE EXCEPTION 'The delivery route is set by staff';
      END IF;
    END IF;
  END IF;

  -- If route_id is being set (non-null), validate it serves the pincode
  IF NEW.route_id IS NOT NULL THEN
    -- Get the area for this pincode
    SELECT area_id INTO v_pincode_area_id
    FROM public.pincodes
    WHERE pincode = NEW.pincode;

    -- Get the route's area and name
    SELECT area_id, route_name INTO v_route_area_id, v_route_name
    FROM public.delivery_routes
    WHERE id = NEW.route_id;

    IF v_route_area_id IS NULL THEN
      RAISE EXCEPTION 'Route not found';
    END IF;

    -- Check if the route's area matches the pincode's area
    IF v_pincode_area_id IS NULL OR v_route_area_id <> v_pincode_area_id THEN
      -- On UPDATE where the customer changed their pincode to a different area,
      -- silently unassign the route (so the app keeps working)
      IF TG_OP = 'UPDATE' AND NEW.pincode IS DISTINCT FROM OLD.pincode THEN
        NEW.route_id := NULL;
      ELSE
        -- Otherwise raise an error
        RAISE EXCEPTION 'Route % does not serve pincode %', v_route_name, NEW.pincode;
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_guard_address_route
  BEFORE INSERT OR UPDATE ON public.addresses
  FOR EACH ROW
  EXECUTE FUNCTION internal.guard_address_route();

-- ---------------------------------------------------------------------------
-- 4. set_address_route RPC
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_address_route(p_address_id uuid, p_route_id uuid)
  RETURNS public.addresses
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_address        public.addresses;
  v_route          public.delivery_routes;
  v_pincode_area   uuid;
  v_area_name      text;
  v_route_area_name text;
BEGIN
  -- Admin-only check
  IF NOT internal.is_admin_actor('customers:edit') AND NOT internal.is_service_actor() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  -- Get the address
  SELECT * INTO v_address FROM public.addresses WHERE id = p_address_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Address not found';
  END IF;

  -- If unassigning (NULL), just do it
  IF p_route_id IS NULL THEN
    UPDATE public.addresses
    SET route_id = NULL
    WHERE id = p_address_id
    RETURNING * INTO v_address;
    RETURN v_address;
  END IF;

  -- Validate the route exists and is active
  SELECT * INTO v_route FROM public.delivery_routes WHERE id = p_route_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Route not found';
  END IF;
  IF NOT v_route.is_active THEN
    RAISE EXCEPTION 'Route % is not active', v_route.route_name;
  END IF;

  -- Get the pincode's area
  SELECT p.area_id, da.display_name INTO v_pincode_area, v_area_name
  FROM public.pincodes p
  JOIN public.delivery_areas da ON da.id = p.area_id
  WHERE p.pincode = v_address.pincode;

  -- Get the route's area name
  SELECT da.display_name INTO v_route_area_name
  FROM public.delivery_areas da
  WHERE da.id = v_route.area_id;

  -- Validate the route serves this pincode's area
  IF v_pincode_area IS NULL THEN
    RAISE EXCEPTION 'Pincode % is not in any delivery area; route % serves area %',
      v_address.pincode, v_route.route_name, v_route_area_name;
  END IF;

  IF v_route.area_id <> v_pincode_area THEN
    RAISE EXCEPTION 'Route % serves area % but pincode % is in area %',
      v_route.route_name, v_route_area_name, v_address.pincode, v_area_name;
  END IF;

  -- Update the address
  UPDATE public.addresses
  SET route_id = p_route_id
  WHERE id = p_address_id
  RETURNING * INTO v_address;

  RETURN v_address;
END;
$function$;

REVOKE ALL ON FUNCTION public.set_address_route(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_address_route(uuid, uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. internal.next_delivery_date
--    Mirrors Hetha_admin/lib/deliverySchedule.ts isAreaDeliveryDay exactly:
--    - frequency <= 1 → p_from (every day)
--    - frequency > 1 with reference_date → first date >= p_from where
--      (date - reference_date) >= 0 and divisible by frequency
--    - frequency > 1 without reference_date → NULL
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION internal.next_delivery_date(p_area_id uuid, p_from date)
  RETURNS date
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_frequency      bigint;
  v_reference_date date;
  v_diff           integer;
  v_check_date     date;
  v_max_days       integer := 366;
BEGIN
  IF p_area_id IS NULL OR p_from IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT delivary_frequency, reference_date
  INTO v_frequency, v_reference_date
  FROM public.delivery_areas
  WHERE id = p_area_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- frequency <= 1 means daily
  IF v_frequency IS NULL OR v_frequency <= 1 THEN
    RETURN p_from;
  END IF;

  -- frequency > 1 requires a reference_date
  IF v_reference_date IS NULL THEN
    RETURN NULL;
  END IF;

  -- Find the first date >= p_from where (date - reference_date) >= 0
  -- and divisible by frequency
  v_check_date := p_from;
  FOR i IN 0..v_max_days LOOP
    v_diff := v_check_date - v_reference_date;
    IF v_diff >= 0 AND v_diff % v_frequency = 0 THEN
      RETURN v_check_date;
    END IF;
    v_check_date := v_check_date + 1;
  END LOOP;

  -- Shouldn't happen with reasonable frequencies
  RETURN NULL;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 6. Trigger: set_order_delivery_date
--    Sets expected_delivery_date on INSERT when NULL.
--    Uses IST cutoff time to determine if we need to skip to the day after.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION internal.set_order_delivery_date()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_area_id       uuid;
  v_cutoff_time   time;
  v_current_ist   time;
  v_base_date     date;
BEGIN
  -- Only set if not already provided
  IF NEW.expected_delivery_date IS NOT NULL THEN
    RETURN NEW;
  END IF;

  -- Try to find the area from snapshot_pincode, fall back to pincode
  SELECT p.area_id INTO v_area_id
  FROM public.pincodes p
  JOIN public.delivery_areas da ON da.id = p.area_id AND da.is_active = true
  WHERE p.pincode = COALESCE(NEW.snapshot_pincode, NEW.pincode);

  -- No serviceable area → leave NULL (all-India orders)
  IF v_area_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Get cutoff time for this area
  SELECT order_cutoff_time INTO v_cutoff_time
  FROM public.delivery_areas
  WHERE id = v_area_id;

  -- Get current IST time
  v_current_ist := (now() AT TIME ZONE 'Asia/Kolkata')::time;

  -- Base date: tomorrow, or the day after if past cutoff
  v_base_date := internal.today_ist() + 1;
  IF v_cutoff_time IS NOT NULL AND v_current_ist > v_cutoff_time THEN
    v_base_date := internal.today_ist() + 2;
  END IF;

  -- Set the delivery date using area's schedule
  NEW.expected_delivery_date := internal.next_delivery_date(v_area_id, v_base_date);

  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_set_order_delivery_date
  BEFORE INSERT ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION internal.set_order_delivery_date();

-- Backfill existing pending orders without expected_delivery_date
UPDATE public.orders o
SET expected_delivery_date = internal.next_delivery_date(
  (SELECT p.area_id
   FROM public.pincodes p
   JOIN public.delivery_areas da ON da.id = p.area_id AND da.is_active = true
   WHERE p.pincode = COALESCE(o.snapshot_pincode, o.pincode)),
  internal.today_ist()
)
WHERE o.status NOT IN ('delivered', 'cancelled')
  AND o.expected_delivery_date IS NULL
  AND EXISTS (
    SELECT 1 FROM public.pincodes p
    JOIN public.delivery_areas da ON da.id = p.area_id AND da.is_active = true
    WHERE p.pincode = COALESCE(o.snapshot_pincode, o.pincode)
  );

-- ---------------------------------------------------------------------------
-- 7. Add delivered_qty to order_items, delivered_at and tracking_info to orders
-- ---------------------------------------------------------------------------
ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS delivered_qty integer CHECK (delivered_qty >= 0);

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS delivered_at timestamptz,
  ADD COLUMN IF NOT EXISTS tracking_info text;

-- ---------------------------------------------------------------------------
-- 8. record_order_delivery RPC
--    Records actual delivery quantities, sets status, and refunds shorts.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_order_delivery(
  p_order_id uuid,
  p_items jsonb,
  p_note text DEFAULT NULL
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_order          public.orders;
  v_item           jsonb;
  v_item_id        uuid;
  v_delivered_qty  integer;
  v_order_item     public.order_items;
  v_all_zero       boolean := true;
  v_short          numeric := 0;
  v_result_status  text;
  v_refunded       numeric := 0;
BEGIN
  -- Admin-only check
  IF NOT internal.is_admin_actor('orders:edit') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  -- Get the order (with lock)
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found';
  END IF;

  -- Check status allows delivery recording
  IF v_order.status NOT IN ('placed', 'processing', 'shipped', 'out_for_delivery') THEN
    RAISE EXCEPTION 'Cannot record delivery: order status is %', v_order.status;
  END IF;

  -- Validate p_items is an array
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'p_items must be a JSON array';
  END IF;

  -- Process each item
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_item_id := (v_item->>'item_id')::uuid;
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

    -- Get the order item
    SELECT * INTO v_order_item
    FROM public.order_items
    WHERE id = v_item_id AND order_id = p_order_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Item % does not belong to order %', v_item_id, p_order_id;
    END IF;

    IF v_delivered_qty > v_order_item.quantity THEN
      RAISE EXCEPTION 'delivered_qty (%) exceeds ordered quantity (%) for item %',
        v_delivered_qty, v_order_item.quantity, v_item_id;
    END IF;

    -- Update the item
    UPDATE public.order_items
    SET delivered_qty = v_delivered_qty
    WHERE id = v_item_id;

    -- Track if any items were delivered
    IF v_delivered_qty > 0 THEN
      v_all_zero := false;
    END IF;

    -- Calculate short amount
    v_short := v_short + ((v_order_item.quantity - v_delivered_qty) * v_order_item.unit_price);
  END LOOP;

  -- Every line of the order must be accounted for, otherwise the order would be
  -- marked delivered with some lines never checked and their shortfall never
  -- refunded.
  PERFORM 1 FROM public.order_items
   WHERE order_id = p_order_id AND delivered_qty IS NULL
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Record a delivered quantity for every item in the order';
  END IF;

  -- Determine final status
  IF v_all_zero THEN
    -- Everything undelivered → cancelled
    v_result_status := 'cancelled';
    UPDATE public.orders
    SET status = 'cancelled',
        cancelled_by = 'admin',
        cancelled_at = now(),
        cancellation_reason = COALESCE(p_note, 'Not delivered'),
        delivered_at = now(),
        tracking_info = COALESCE(p_note, tracking_info)
    WHERE id = p_order_id;
  ELSE
    -- Some delivered → delivered status
    v_result_status := 'delivered';
    UPDATE public.orders
    SET status = 'delivered',
        delivered_at = now(),
        tracking_info = COALESCE(p_note, tracking_info)
    WHERE id = p_order_id;
  END IF;

  -- Refund short amount if the order was paid
  IF v_short > 0 AND v_order.payment_status = 'paid' THEN
    v_short := round(v_short, 2);
    PERFORM internal.apply_wallet_delta(
      v_order.user_id,
      v_short,
      'credit',
      'Refund for undelivered items in order ' || v_order.order_number,
      'admin',
      'order_refund',
      p_order_id::text
    );
    v_refunded := v_short;
  END IF;

  RETURN jsonb_build_object(
    'status', v_result_status,
    'refunded', v_refunded,
    'short', round(v_short, 2)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.record_order_delivery(uuid, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_order_delivery(uuid, jsonb, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 9. reschedule_order RPC
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reschedule_order(p_order_id uuid, p_date date)
  RETURNS public.orders
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_order public.orders;
BEGIN
  -- Admin-only check
  IF NOT internal.is_admin_actor('orders:edit') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  -- Get the order
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found';
  END IF;

  -- Check status allows rescheduling
  IF v_order.status IN ('delivered', 'cancelled') THEN
    RAISE EXCEPTION 'Cannot reschedule: order status is %', v_order.status;
  END IF;

  -- Validate date is not in the past
  IF p_date < internal.today_ist() THEN
    RAISE EXCEPTION 'Cannot reschedule to a past date';
  END IF;

  -- Update the order
  UPDATE public.orders
  SET expected_delivery_date = p_date, updated_at = now()
  WHERE id = p_order_id
  RETURNING * INTO v_order;

  RETURN v_order;
END;
$function$;

REVOKE ALL ON FUNCTION public.reschedule_order(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reschedule_order(uuid, date) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 10. Update create_subscription_core to store address_id from the payload
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION internal.create_subscription_core(p_user_id uuid, p_start_date timestamp with time zone, p_end_date timestamp with time zone, p_status text, p_address jsonb, p_items jsonb, p_label text, p_cancel_existing boolean DEFAULT false, p_is_admin boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_sub_id             uuid;
  v_pincode            text;
  v_area_id            uuid;
  v_delivery_area      text;
  v_delivery_frequency bigint;
  v_active_count       integer;
  v_max_subscriptions  integer := 5;
  v_new_daily          numeric := 0;
  v_existing_daily     numeric := 0;
  v_wallet_balance     numeric := 0;
  v_required           numeric := 0;
  v_address_id         uuid;
  v_address_id_text    text;
BEGIN
  IF p_status IS NULL OR p_status NOT IN ('active', 'paused') THEN
    RAISE EXCEPTION 'Invalid subscription status: %', p_status;
  END IF;

  IF p_cancel_existing THEN
    UPDATE public.subscriptions
    SET status = 'cancelled', cancelled_at = now(), end_date = now(),
        cancellation_type = 'replaced',
        cancellation_reason = 'Replaced by new subscription',
        is_custom_cancel_date = false
    WHERE user_id = p_user_id AND status = 'active';
  END IF;

  SELECT COUNT(*) INTO v_active_count
  FROM public.subscriptions
  WHERE user_id = p_user_id AND status IN ('active', 'pending_cancellation');

  IF v_active_count >= v_max_subscriptions THEN
    RAISE EXCEPTION 'Maximum subscription limit (%) reached', v_max_subscriptions;
  END IF;

  -- Canonical daily cost from the catalog (client "price" fields ignored).
  SELECT COALESCE(SUM(round(c.unit_price * c.quantity, 2)), 0)
  INTO v_new_daily
  FROM internal.normalize_cart(p_items) c;

  IF v_new_daily <= 0 THEN
    RAISE EXCEPTION 'Subscription daily value must be greater than zero';
  END IF;

  -- 3-day wallet buffer across ALL subscriptions (previously client-only).
  IF NOT p_is_admin THEN
    SELECT COALESCE(wallet_balance, 0) INTO v_wallet_balance
    FROM public.users WHERE id = p_user_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'User not found';
    END IF;

    v_existing_daily := COALESCE(public.get_user_daily_commitment(p_user_id), 0);
    v_required := round((v_existing_daily + v_new_daily) * 3, 2);

    IF v_wallet_balance < v_required THEN
      RAISE EXCEPTION
        'Insufficient wallet balance (%). You need at least % (3 days x %/day for all subscriptions).',
        v_wallet_balance, v_required, round(v_existing_daily + v_new_daily, 2);
    END IF;
  END IF;

  v_pincode := p_address->>'pincode';
  IF v_pincode IS NOT NULL THEN
    SELECT area_id INTO v_area_id FROM public.pincodes WHERE pincode = v_pincode LIMIT 1;
    IF v_area_id IS NOT NULL THEN
      SELECT display_name, delivary_frequency
      INTO v_delivery_area, v_delivery_frequency
      FROM public.delivery_areas WHERE id = v_area_id LIMIT 1;
    END IF;
  END IF;

  -- Extract address_id from the payload if it's a valid uuid belonging to p_user_id
  v_address_id_text := p_address->>'id';
  IF v_address_id_text IS NOT NULL AND v_address_id_text ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    SELECT id INTO v_address_id
    FROM public.addresses
    WHERE id = v_address_id_text::uuid
      AND user_id = p_user_id
      AND is_deleted = false;
  END IF;

  INSERT INTO public.subscriptions (
    user_id, address_id, start_date, end_date, status, label,
    snapshot_name, snapshot_phone, snapshot_address_line1, snapshot_address_line2,
    snapshot_landmark, snapshot_city, snapshot_state, snapshot_pincode,
    snapshot_address_type, delivary_area, delivary_frequency, created_at
  ) VALUES (
    p_user_id, v_address_id, p_start_date, p_end_date, p_status,
    COALESCE(p_label, 'Subscription ' || (v_active_count + 1)::text),
    p_address->>'name', p_address->>'phoneNumber', p_address->>'addressLine1',
    p_address->>'addressLine2', p_address->>'landmark', p_address->>'city',
    p_address->>'state', p_address->>'pincode', p_address->>'addressType',
    v_delivery_area, v_delivery_frequency, now()
  ) RETURNING id INTO v_sub_id;

  INSERT INTO public.subscription_items (
    subscription_id, variant_id, product_name_snapshot, variant_label_snapshot,
    unit_price, quantity, item_start_date
  )
  SELECT
    v_sub_id, c.variant_id, c.product_name, c.variant_label,
    c.unit_price, c.quantity,
    COALESCE(
      (SELECT MIN(NULLIF(it->>'startDate', ''))::date
       FROM jsonb_array_elements(p_items) it
       WHERE COALESCE(it->>'variant_id', it->>'variantId') = c.variant_id::text),
      p_start_date::date,
      internal.today_ist()
    )
  FROM internal.normalize_cart(p_items) c;

  RETURN v_sub_id;
END;
$function$;

-- Backfill subscriptions.address_id where NULL
-- Match to user's non-deleted address with same snapshot_address_line1 and snapshot_pincode
-- Only when exactly one matches
UPDATE public.subscriptions s
SET address_id = matched.addr_id
FROM (
  SELECT sub.id AS sub_id, addr.id AS addr_id
  FROM public.subscriptions sub
  JOIN public.addresses addr ON addr.user_id = sub.user_id
    AND addr.address_line1 = sub.snapshot_address_line1
    AND addr.pincode = sub.snapshot_pincode
    AND addr.is_deleted = false
  WHERE sub.address_id IS NULL
  GROUP BY sub.id, addr.id
) matched
JOIN (
  -- Only include subscriptions that have exactly one matching address
  SELECT sub.id AS sub_id, COUNT(*) AS addr_count
  FROM public.subscriptions sub
  JOIN public.addresses addr ON addr.user_id = sub.user_id
    AND addr.address_line1 = sub.snapshot_address_line1
    AND addr.pincode = sub.snapshot_pincode
    AND addr.is_deleted = false
  WHERE sub.address_id IS NULL
  GROUP BY sub.id
  HAVING COUNT(*) = 1
) single_match ON single_match.sub_id = matched.sub_id
WHERE s.id = matched.sub_id;

-- ---------------------------------------------------------------------------
-- 12. Foreign key on subscriptions.address_id
-- ---------------------------------------------------------------------------
-- The column existed without a constraint, so PostgREST could not embed
-- addresses through it (the Deliveries screen needs
-- subscription_daily_orders → subscriptions → addresses to find the route).
-- Clear any id that no longer points at an address first, so the constraint
-- can be added and validated in one go.
UPDATE public.subscriptions s
SET address_id = NULL
WHERE s.address_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.addresses a WHERE a.id = s.address_id);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'fk_subscription_address'
       AND conrelid = 'public.subscriptions'::regclass
  ) THEN
    ALTER TABLE public.subscriptions
      ADD CONSTRAINT fk_subscription_address
      FOREIGN KEY (address_id) REFERENCES public.addresses(id);
  END IF;
END $$;

COMMIT;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- 1. Check addresses.route_id column exists:
--      SELECT column_name, data_type FROM information_schema.columns
--      WHERE table_schema = 'public' AND table_name = 'addresses' AND column_name = 'route_id';
--
-- 2. Check the trigger exists:
--      SELECT tgname FROM pg_trigger WHERE tgname = 'trg_guard_address_route';
--      SELECT tgname FROM pg_trigger WHERE tgname = 'trg_set_order_delivery_date';
--
-- 3. Check new RPCs exist:
--      SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--      WHERE n.nspname = 'public' AND proname IN ('set_address_route', 'record_order_delivery', 'reschedule_order');
--
-- 4. Check internal.next_delivery_date exists:
--      SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--      WHERE n.nspname = 'internal' AND proname = 'next_delivery_date';
--
-- 5. Test next_delivery_date for daily area (frequency=1):
--      SELECT internal.next_delivery_date(
--        (SELECT id FROM delivery_areas WHERE delivary_frequency = 1 LIMIT 1),
--        '2026-10-01'
--      );  -- should return '2026-10-01'
--
-- 6. Test next_delivery_date for alternate day area (frequency=2):
--      -- Setup: ensure there's an area with frequency=2 and reference_date
--      -- SELECT internal.next_delivery_date(area_id, '2026-10-01');
--      -- Should return the first date on cadence >= '2026-10-01'
--
-- 7. Verify grant surface:
--      SELECT has_function_privilege('anon', 'public.set_address_route(uuid,uuid)', 'EXECUTE');  -- f
--      SELECT has_function_privilege('authenticated', 'public.set_address_route(uuid,uuid)', 'EXECUTE');  -- t
--      SELECT has_function_privilege('anon', 'public.record_order_delivery(uuid,jsonb,text)', 'EXECUTE');  -- f
--      SELECT has_function_privilege('anon', 'public.reschedule_order(uuid,date)', 'EXECUTE');  -- f
--
-- 8. Check order_items.delivered_qty column:
--      SELECT column_name FROM information_schema.columns
--      WHERE table_schema = 'public' AND table_name = 'order_items' AND column_name = 'delivered_qty';
--
-- 9. Check orders new columns:
--      SELECT column_name FROM information_schema.columns
--      WHERE table_schema = 'public' AND table_name = 'orders' AND column_name IN ('delivered_at', 'tracking_info');
