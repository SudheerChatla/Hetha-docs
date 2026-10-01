-- Migration 034: reschedule_order snaps to the area's next delivery day
--
-- Run in: Supabase SQL Editor (the whole file; it is wrapped in one transaction)
--
-- ─── Problem ────────────────────────────────────────────────────────────────
-- reschedule_order (migration 033) wrote whatever date the admin passed. But a
-- one-time order can only actually be delivered on one of the area's delivery
-- days (frequency 1 = daily, 2 = alternate from the reference date). Picking
-- 3 Oct for a Noida order — which delivers on 2 and 4 Oct — left the order
-- stranded on a day with no run.
--
-- ─── Fix ─────────────────────────────────────────────────────────────────────
-- Snap the requested date forward to the area's next delivery day with
-- internal.next_delivery_date (the same rule the order's initial date and the
-- run sheet use). If the order's pincode is in no active area (e.g. an
-- all-India order), keep the requested date as-is. Still refuse past dates and
-- delivered/cancelled orders.

BEGIN;

CREATE OR REPLACE FUNCTION public.reschedule_order(p_order_id uuid, p_date date)
  RETURNS public.orders
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_order    public.orders;
  v_area_id  uuid;
  v_snapped  date;
BEGIN
  IF NOT internal.is_admin_actor('orders:edit') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found';
  END IF;

  IF v_order.status IN ('delivered', 'cancelled') THEN
    RAISE EXCEPTION 'Cannot reschedule: order status is %', v_order.status;
  END IF;

  IF p_date < internal.today_ist() THEN
    RAISE EXCEPTION 'Cannot reschedule to a past date';
  END IF;

  -- Resolve the serviceable area from the order's pincode.
  SELECT p.area_id INTO v_area_id
  FROM public.pincodes p
  JOIN public.delivery_areas da ON da.id = p.area_id AND da.is_active = true
  WHERE p.pincode = COALESCE(v_order.snapshot_pincode, v_order.pincode);

  IF v_area_id IS NOT NULL THEN
    -- Snap forward to the area's next delivery day on or after p_date.
    v_snapped := internal.next_delivery_date(v_area_id, p_date);
    IF v_snapped IS NULL THEN
      -- Alternate-day area with no reference_date configured — leave as asked.
      v_snapped := p_date;
    END IF;
  ELSE
    -- No serviceable area (e.g. all-India order): honour the exact date.
    v_snapped := p_date;
  END IF;

  UPDATE public.orders
  SET expected_delivery_date = v_snapped, updated_at = now()
  WHERE id = p_order_id
  RETURNING * INTO v_order;

  RETURN v_order;
END;
$function$;

REVOKE ALL ON FUNCTION public.reschedule_order(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reschedule_order(uuid, date) TO authenticated, service_role;

COMMIT;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- Reschedule a Noida order to a Wednesday it doesn't deliver on; expect the
-- stored date to jump to the next Noida delivery day:
--   SELECT expected_delivery_date
--   FROM public.reschedule_order('<noida order id>', '2026-10-03');  -- → 2026-10-04
