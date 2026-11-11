-- Migration 036: one cut-off rule for subscriptions, decided by the database
--
-- Run in: Supabase SQL Editor (the whole file; it is wrapped in one transaction)
--
-- ─── Problem ────────────────────────────────────────────────────────────────
-- To deliver on a given morning, ops must know the order by the evening before
-- (delivery_areas.order_cutoff_time). One-time orders already follow that rule
-- in the database (internal.set_order_delivery_date, migration 033).
-- Subscriptions did not:
--
--   1. NEW SUBSCRIPTION. create_subscription stored whatever start date the
--      client sent. The app always offers "tomorrow" as the earliest start,
--      at any hour, and nothing checked the cut-off. A customer subscribing at
--      11 pm was told "Starting tomorrow" even when tomorrow's run sheet was
--      already planned.
--   2. RUN SHEET. The only cut-off check lived in the admin run-sheet generator
--      (Hetha_admin services/dailyOps/generateRunSheet.ts). It compared the
--      subscription's created_at with a cut-off built in the SERVER's timezone
--      (UTC on Vercel), so a 16:30 cut-off was applied as 22:00 IST two days
--      before delivery, and it never told the customer the start had moved.
--   3. DAY EDITS. modify_daily_order / modify_daily_orders_bulk /
--      revert_daily_order only refused dates before CURRENT_DATE (the UTC
--      date). "No changes to tomorrow after the cut-off" was enforced by the
--      app alone, using the phone's clock.
--   4. PAUSES. upsert_pauses / remove_paused_dates (what the app calls to
--      pause or resume days) checked ownership only. A customer could pause
--      tomorrow at 11 pm, after the stock was planned, or un-pause tomorrow
--      and expect a delivery nobody packed. The table's INSERT policy also
--      lets a customer insert a pause row directly, with no date check.
--
-- ─── Fix ─────────────────────────────────────────────────────────────────────
-- One rule, in one place:
--
--   internal.earliest_change_date(area)  =  tomorrow (IST)
--                                           or the day after, once the area's
--                                           order_cutoff_time has passed today
--
-- An area with no cut-off time always gives "tomorrow". The comparison is the
-- same one internal.set_order_delivery_date uses for one-time orders.
--
--   • create_subscription_core (customers): the start date is moved forward to
--     the earliest change date when the client sent an earlier one or none.
--     Item start dates can never be before the subscription start. Admin
--     callers are not restricted (ops can still backfill deliberately).
--   • public.get_earliest_subscription_start(pincode): what the app's date
--     picker should offer as the first day, so the screen and the database
--     agree.
--   • modify_daily_order / modify_daily_orders_bulk / revert_daily_order
--     (customers): a day before the earliest change date is refused. Admins
--     with subscriptions:edit bypass, as before.
--   • upsert_pauses / remove_paused_dates (customers): a day before the
--     earliest change date can be neither newly paused nor un-paused. Days in
--     a requested range that are ALREADY paused are ignored, so extending an
--     existing pause still works. Admins bypass.
--   • subscription_pauses BEFORE INSERT trigger: a customer's direct insert
--     (not through the functions above) cannot start before the earliest
--     change date. The app does not use this path; it closes the hole a
--     hand-made request could use. Customers have no UPDATE or DELETE policy
--     on the table, so INSERT is the only direct write to guard.
--
-- The run-sheet generator drops its own created_at check in the same release:
-- the start date now carries the cut-off decision.
--
-- No table, column, grant on existing objects, or money logic changes (one new
-- trigger on subscription_pauses). The wallet rules inside the *_core
-- functions are untouched; the day-edit checks are added in the public
-- wrappers so those bodies did not have to be copied.
--
-- ─── Rollout order ──────────────────────────────────────────────────────────
-- Apply THIS migration first, then deploy the admin panel, then release the
-- app. Old app builds keep working: a start date that is too early is moved
-- forward by the database instead of being rejected (their "Starting <date>"
-- message can then be one day early, only when a cut-off time is set and has
-- passed). Today no area has a cut-off time, so nothing changes for anyone
-- until one is set in Delivery Areas.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. internal.earliest_change_date — the rule
-- ---------------------------------------------------------------------------
-- p_now exists so the rule can be tested at a fixed moment; callers leave it
-- at the default.
CREATE OR REPLACE FUNCTION internal.earliest_change_date(
  p_area_id uuid,
  p_now     timestamptz DEFAULT now()
)
  RETURNS date
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_today  date := (p_now AT TIME ZONE 'Asia/Kolkata')::date;
  v_time   time := (p_now AT TIME ZONE 'Asia/Kolkata')::time;
  v_cutoff time;
BEGIN
  IF p_area_id IS NOT NULL THEN
    SELECT order_cutoff_time INTO v_cutoff
    FROM public.delivery_areas WHERE id = p_area_id;
  END IF;

  IF v_cutoff IS NOT NULL AND v_time > v_cutoff THEN
    RETURN v_today + 2;
  END IF;
  RETURN v_today + 1;
END;
$function$;

REVOKE ALL ON FUNCTION internal.earliest_change_date(uuid, timestamptz) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Per-subscription lookup and the day-edit guard for customers
-- ---------------------------------------------------------------------------
-- The subscription's area comes from its snapshot pincode, the same lookup
-- create_subscription_core used when it was created.
CREATE OR REPLACE FUNCTION internal.subscription_earliest_change_date(p_subscription_id uuid)
  RETURNS date
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_area_id uuid;
BEGIN
  SELECT p.area_id INTO v_area_id
  FROM public.subscriptions s
  JOIN public.pincodes p ON p.pincode = s.snapshot_pincode
  WHERE s.id = p_subscription_id
  LIMIT 1;

  RETURN internal.earliest_change_date(v_area_id);
END;
$function$;

REVOKE ALL ON FUNCTION internal.subscription_earliest_change_date(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION internal.assert_day_changeable(
  p_subscription_id uuid,
  p_delivery_date   date
)
  RETURNS void
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_earliest date;
BEGIN
  IF p_delivery_date IS NULL THEN
    RETURN;                                  -- the core function reports this
  END IF;

  IF p_delivery_date < internal.today_ist() THEN
    RAISE EXCEPTION 'Cannot modify a delivery date in the past (%)', p_delivery_date;
  END IF;

  v_earliest := internal.subscription_earliest_change_date(p_subscription_id);

  IF p_delivery_date < v_earliest THEN
    RAISE EXCEPTION
      'The order for % can no longer be changed. The earliest day you can change now is %.',
      to_char(p_delivery_date, 'DD Mon YYYY'), to_char(v_earliest, 'DD Mon YYYY');
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION internal.assert_day_changeable(uuid, date) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. public.get_earliest_subscription_start — for the app's date picker
-- ---------------------------------------------------------------------------
-- Read-only. Returns only a date derived from the area's cut-off time, which
-- the app can already read from delivery_areas.
CREATE OR REPLACE FUNCTION public.get_earliest_subscription_start(p_pincode text)
  RETURNS date
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_area_id uuid;
BEGIN
  IF p_pincode IS NOT NULL THEN
    SELECT area_id INTO v_area_id
    FROM public.pincodes WHERE pincode = p_pincode LIMIT 1;
  END IF;
  RETURN internal.earliest_change_date(v_area_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.get_earliest_subscription_start(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_earliest_subscription_start(text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. create_subscription_core — start date can't be before the earliest date
-- ---------------------------------------------------------------------------
-- Body is migration 033's, with: v_start / v_earliest, the clamp for customer
-- callers, and item start dates never before the subscription start.
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
  v_start              date := p_start_date::date;
  v_earliest           date;
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

  -- Cut-off rule (migration 036): a customer's subscription cannot start
  -- before the earliest day ops can still plan for. An earlier (or missing)
  -- start date is moved forward, not rejected, so older app builds keep
  -- working. Admin callers choose the start date freely.
  IF NOT p_is_admin THEN
    v_earliest := internal.earliest_change_date(v_area_id);
    v_start    := GREATEST(COALESCE(v_start, v_earliest), v_earliest);
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
    p_user_id, v_address_id, v_start, p_end_date, p_status,
    COALESCE(p_label, 'Subscription ' || (v_active_count + 1)::text),
    p_address->>'name', p_address->>'phoneNumber', p_address->>'addressLine1',
    p_address->>'addressLine2', p_address->>'landmark', p_address->>'city',
    p_address->>'state', p_address->>'pincode', p_address->>'addressType',
    v_delivery_area, v_delivery_frequency, now()
  ) RETURNING id INTO v_sub_id;

  -- An item never starts before its subscription (GREATEST ignores a NULL
  -- v_start, which only an admin caller can produce).
  INSERT INTO public.subscription_items (
    subscription_id, variant_id, product_name_snapshot, variant_label_snapshot,
    unit_price, quantity, item_start_date
  )
  SELECT
    v_sub_id, c.variant_id, c.product_name, c.variant_label,
    c.unit_price, c.quantity,
    GREATEST(
      COALESCE(
        (SELECT MIN(NULLIF(it->>'startDate', ''))::date
         FROM jsonb_array_elements(p_items) it
         WHERE COALESCE(it->>'variant_id', it->>'variantId') = c.variant_id::text),
        v_start,
        internal.today_ist()
      ),
      v_start
    )
  FROM internal.normalize_cart(p_items) c;

  RETURN v_sub_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5. Day edits: enforce the cut-off in the public wrappers (customers only)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.modify_daily_order(p_user_id uuid, p_subscription_id uuid, p_delivery_date date, p_items jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_is_admin boolean := internal.is_admin_actor('subscriptions:edit');
BEGIN
  IF NOT v_is_admin THEN
    IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
      RAISE EXCEPTION 'Not authorized to modify orders for this user';
    END IF;
    PERFORM internal.assert_day_changeable(p_subscription_id, p_delivery_date);
  END IF;

  RETURN internal.modify_daily_order_core(
    p_user_id, p_subscription_id, p_delivery_date, p_items, v_is_admin
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.modify_daily_orders_bulk(p_user_id uuid, p_subscription_id uuid, p_days jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_is_admin boolean := internal.is_admin_actor('subscriptions:edit');
  v_day      jsonb;
BEGIN
  IF NOT v_is_admin THEN
    IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
      RAISE EXCEPTION 'Not authorized to modify orders for this user';
    END IF;

    -- Every day in the batch must still be changeable. A malformed payload is
    -- left for the core function to report.
    IF p_days IS NOT NULL AND jsonb_typeof(p_days) = 'array' THEN
      FOR v_day IN SELECT * FROM jsonb_array_elements(p_days)
      LOOP
        IF jsonb_typeof(v_day) = 'object' THEN
          PERFORM internal.assert_day_changeable(
            p_subscription_id, NULLIF(v_day->>'delivery_date', '')::date
          );
        END IF;
      END LOOP;
    END IF;
  END IF;

  RETURN internal.modify_daily_orders_bulk_core(
    p_user_id, p_subscription_id, p_days, v_is_admin
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.revert_daily_order(p_user_id uuid, p_delivery_date date, p_subscription_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_is_admin boolean := internal.is_admin_actor('subscriptions:edit');
  v_owner    uuid;
BEGIN
  IF NOT v_is_admin THEN
    IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
      RAISE EXCEPTION 'Not authorized to modify orders for this user';
    END IF;
  END IF;

  SELECT user_id INTO v_owner FROM public.subscriptions WHERE id = p_subscription_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Subscription not found';
  END IF;
  IF v_owner IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'Subscription does not belong to this user';
  END IF;

  -- Resetting a day changes what is delivered, so it follows the same cut-off.
  IF NOT v_is_admin THEN
    PERFORM internal.assert_day_changeable(p_subscription_id, p_delivery_date);
  END IF;

  DELETE FROM public.subscription_daily_order_items
  WHERE daily_order_id IN (
    SELECT id FROM public.subscription_daily_orders
    WHERE subscription_id = p_subscription_id
      AND delivery_date = p_delivery_date
      AND status = 'pending'
      AND is_finalized = false
      AND payment_status <> 'paid'
  );

  DELETE FROM public.subscription_daily_orders
  WHERE subscription_id = p_subscription_id
    AND delivery_date = p_delivery_date
    AND status = 'pending'
    AND is_finalized = false
    AND payment_status <> 'paid';
END;
$function$;

-- ---------------------------------------------------------------------------
-- 6. Pauses follow the same cut-off (customers only)
-- ---------------------------------------------------------------------------
-- Bodies are migration 009's, plus the cut-off checks. Both functions run in
-- one transaction, so a refused range or date leaves every pause unchanged.
CREATE OR REPLACE FUNCTION public.upsert_pauses(p_subscription_id uuid, p_ranges jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  r JSONB;
  new_start DATE;
  new_end DATE;
  merged_start DATE;
  merged_end DATE;
  overlap_ids UUID[];
  v_is_admin boolean := internal.is_admin_actor('subscriptions:edit');
  v_earliest date;
  v_locked   date;
BEGIN
  PERFORM internal.assert_subscription_access(p_subscription_id);

  -- Tells trg_guard_direct_pause_insert these rows come from this function
  -- (transaction-local; a merged or split range may start before the
  -- earliest change date, which is fine because its days were already paused).
  PERFORM set_config('hetha.pause_rpc', 'on', true);

  IF NOT v_is_admin THEN
    v_earliest := internal.subscription_earliest_change_date(p_subscription_id);
  END IF;

  FOR r IN SELECT * FROM jsonb_array_elements(p_ranges)
  LOOP
    new_start := (r->>'start')::DATE;
    new_end := (r->>'end')::DATE;

    IF new_start IS NULL OR new_end IS NULL OR new_end < new_start THEN
      RAISE EXCEPTION 'Each pause needs a start date and an end date on or after it';
    END IF;

    -- Cut-off: no day before the earliest change date may become paused.
    -- Days that are already paused are not a change, so they are skipped.
    IF NOT v_is_admin AND new_start < v_earliest THEN
      SELECT MIN(d::date) INTO v_locked
      FROM generate_series(new_start, LEAST(new_end, v_earliest - 1), INTERVAL '1 day') d
      WHERE NOT EXISTS (
        SELECT 1 FROM public.subscription_pauses sp
        WHERE sp.subscription_id = p_subscription_id
          AND sp.pause_start_date <= d::date
          AND sp.pause_end_date   >= d::date
      );

      IF v_locked IS NOT NULL THEN
        RAISE EXCEPTION
          'The delivery on % can no longer be paused. The earliest day you can pause now is %.',
          to_char(v_locked, 'DD Mon YYYY'), to_char(v_earliest, 'DD Mon YYYY');
      END IF;
    END IF;

    SELECT array_agg(id),
           LEAST(MIN(pause_start_date), new_start),
           GREATEST(MAX(pause_end_date), new_end)
    INTO overlap_ids, merged_start, merged_end
    FROM public.subscription_pauses
    WHERE subscription_id = p_subscription_id
      AND pause_start_date <= (new_end + INTERVAL '1 day')::DATE
      AND pause_end_date >= (new_start - INTERVAL '1 day')::DATE;

    IF overlap_ids IS NOT NULL THEN
      DELETE FROM public.subscription_pauses WHERE id = ANY(overlap_ids);
    ELSE
      merged_start := new_start;
      merged_end := new_end;
    END IF;

    INSERT INTO public.subscription_pauses (subscription_id, pause_start_date, pause_end_date, created_by)
    VALUES (p_subscription_id, merged_start, merged_end, 'user');
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.remove_paused_dates(p_subscription_id uuid, p_dates jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  date_val DATE;
  row_rec RECORD;
  v_is_admin boolean := internal.is_admin_actor('subscriptions:edit');
  v_earliest date;
BEGIN
  PERFORM internal.assert_subscription_access(p_subscription_id);

  -- Tells trg_guard_direct_pause_insert these rows come from this function
  -- (transaction-local; a merged or split range may start before the
  -- earliest change date, which is fine because its days were already paused).
  PERFORM set_config('hetha.pause_rpc', 'on', true);

  IF NOT v_is_admin THEN
    v_earliest := internal.subscription_earliest_change_date(p_subscription_id);
  END IF;

  FOR date_val IN SELECT (jsonb_array_elements_text(p_dates))::DATE
  LOOP
    -- Cut-off: a paused day before the earliest change date stays paused
    -- (nothing was packed for it). A date that is not paused is a no-op and
    -- is left alone.
    IF NOT v_is_admin AND date_val < v_earliest AND EXISTS (
      SELECT 1 FROM public.subscription_pauses sp
      WHERE sp.subscription_id = p_subscription_id
        AND sp.pause_start_date <= date_val
        AND sp.pause_end_date   >= date_val
    ) THEN
      RAISE EXCEPTION
        'The pause on % can no longer be removed. The earliest day you can change now is %.',
        to_char(date_val, 'DD Mon YYYY'), to_char(v_earliest, 'DD Mon YYYY');
    END IF;

    FOR row_rec IN
      SELECT id, pause_start_date, pause_end_date
      FROM public.subscription_pauses
      WHERE subscription_id = p_subscription_id
        AND pause_start_date <= date_val
        AND pause_end_date >= date_val
    LOOP
      DELETE FROM public.subscription_pauses WHERE id = row_rec.id;

      IF row_rec.pause_start_date < date_val THEN
        INSERT INTO public.subscription_pauses (subscription_id, pause_start_date, pause_end_date, created_by)
        VALUES (p_subscription_id, row_rec.pause_start_date, date_val - 1, 'user');
      END IF;

      IF row_rec.pause_end_date > date_val THEN
        INSERT INTO public.subscription_pauses (subscription_id, pause_start_date, pause_end_date, created_by)
        VALUES (p_subscription_id, date_val + 1, row_rec.pause_end_date, 'user');
      END IF;
    END LOOP;
  END LOOP;
END;
$function$;

-- Direct inserts. The RLS INSERT policy lets a customer insert a pause row for
-- their own subscription without going through upsert_pauses. This trigger
-- applies the same cut-off to such a row. It steps aside for rows written by
-- the two functions above (they set hetha.pause_rpc for the transaction; a
-- client cannot set it through the API), for staff with subscriptions:edit,
-- and for the service role / SQL editor.
CREATE OR REPLACE FUNCTION internal.guard_direct_pause_insert()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_earliest date;
BEGIN
  IF current_setting('hetha.pause_rpc', true) = 'on' THEN
    RETURN NEW;
  END IF;
  IF internal.is_admin_actor('subscriptions:edit') THEN
    RETURN NEW;
  END IF;

  v_earliest := internal.subscription_earliest_change_date(NEW.subscription_id);
  IF NEW.pause_start_date < v_earliest THEN
    RAISE EXCEPTION
      'The delivery on % can no longer be paused. The earliest day you can pause now is %.',
      to_char(NEW.pause_start_date, 'DD Mon YYYY'), to_char(v_earliest, 'DD Mon YYYY');
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION internal.guard_direct_pause_insert() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_guard_direct_pause_insert ON public.subscription_pauses;
CREATE TRIGGER trg_guard_direct_pause_insert
  BEFORE INSERT ON public.subscription_pauses
  FOR EACH ROW EXECUTE FUNCTION internal.guard_direct_pause_insert();

COMMIT;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- 1. The rule at fixed moments, for an area with a 16:30 cut-off (replace the
--    uuid with a real delivery_areas.id that has order_cutoff_time set):
--      SELECT internal.earliest_change_date('<area id>', '2026-11-10 10:00+05:30');  -- 2026-11-11
--      SELECT internal.earliest_change_date('<area id>', '2026-11-10 17:00+05:30');  -- 2026-11-12
--    With no cut-off time on the area both return 2026-11-11.
--
-- 2. The app's helper (any serviceable pincode) returns tomorrow or the day
--    after, in India time:
--      SELECT public.get_earliest_subscription_start('<pincode>');
--
-- 3. Grants — expect f, f, t, f, f:
--      SELECT
--        has_function_privilege('anon',          'public.get_earliest_subscription_start(text)', 'EXECUTE'),
--        has_function_privilege('authenticated', 'internal.earliest_change_date(uuid, timestamptz)', 'EXECUTE'),
--        has_function_privilege('authenticated', 'public.get_earliest_subscription_start(text)', 'EXECUTE'),
--        has_function_privilege('anon',          'internal.assert_day_changeable(uuid, date)', 'EXECUTE'),
--        has_function_privilege('authenticated', 'internal.assert_day_changeable(uuid, date)', 'EXECUTE');
--
-- 4. The day-edit and pause functions kept their grants (expect t, t, t, t, t):
--      SELECT
--        has_function_privilege('authenticated', 'public.modify_daily_order(uuid, uuid, date, jsonb)', 'EXECUTE'),
--        has_function_privilege('authenticated', 'public.modify_daily_orders_bulk(uuid, uuid, jsonb)', 'EXECUTE'),
--        has_function_privilege('authenticated', 'public.revert_daily_order(uuid, date, uuid)', 'EXECUTE'),
--        has_function_privilege('authenticated', 'public.upsert_pauses(uuid, jsonb)', 'EXECUTE'),
--        has_function_privilege('authenticated', 'public.remove_paused_dates(uuid, jsonb)', 'EXECUTE');
--
-- 5. The pause trigger exists (1 row):
--      SELECT tgname FROM pg_trigger WHERE tgname = 'trg_guard_direct_pause_insert';
