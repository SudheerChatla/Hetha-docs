-- Migration 028: Product archive flag + atomic, history-aware product delete
--
-- Run in: Supabase SQL Editor (the whole file; it is wrapped in one transaction)
--
-- ─── Problems ───────────────────────────────────────────────────────────────
-- 1. DELETE /api/admin/products deleted product_images, then product_variants,
--    then the product — three separate calls, only the last one error-checked.
--    A product with order history has variants referenced by order_items /
--    subscription_items / subscription_daily_order_items / reviews, so the
--    variant delete is refused by the foreign keys — but the images were
--    already gone. Result: "delete failed", product still live, images lost.
-- 2. There was no way to retire a product. Only `in_stock` existed, and the
--    customer app does not filter out-of-stock products, so a discontinued
--    product stayed visible forever (just unorderable).
--
-- ─── What this migration adds ────────────────────────────────────────────────
--   1. products.is_archived (boolean, default false).
--   2. internal.normalize_cart refuses archived products — same treatment as
--      out-of-stock — so no cart, order, subscription or day edit can include
--      one, even from an old app build that still lists it.
--   3. public.delete_product(p_product_id) — refuses (with the counts) if the
--      product has ANY history; otherwise removes cart rows, images, variants
--      and the product in one transaction. All-or-nothing.
--   4. public.set_product_archived(p_product_id, p_archived) — archive /
--      restore. Archiving is refused while an active subscription still has
--      the product as a live item (it would keep being delivered and billed,
--      and the customer's day edits would start failing). Archiving also
--      clears the product from every customer's cart.
--   Both RPCs require products:edit (or super admin / service role).

BEGIN;

-- ─── 1. Schema ───────────────────────────────────────────────────────────────
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS is_archived boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.products.is_archived IS
  'Retired product: hidden from customer listings and refused by '
  'internal.normalize_cart. Kept (not deleted) so order history stays intact. '
  'Set via public.set_product_archived.';

-- ─── 2. normalize_cart: refuse archived products ─────────────────────────────
-- Identical to the migration 007 body except the extra is_archived condition.
CREATE OR REPLACE FUNCTION internal.normalize_cart(p_items jsonb)
 RETURNS TABLE(variant_id uuid, quantity integer, unit_price numeric, product_name text, variant_label text, weight_grams numeric, free_delivery boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_count     integer;
  v_item      jsonb;
  v_raw_id    text;
  v_raw_qty   text;
  v_pairs     jsonb := '[]'::jsonb;
  v_expected  integer;
  v_matched   integer;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'Cart payload must be a JSON array';
  END IF;

  v_count := jsonb_array_length(p_items);
  IF v_count = 0 THEN
    RAISE EXCEPTION 'Cart is empty';
  END IF;
  IF v_count > 50 THEN
    RAISE EXCEPTION 'Too many line items (%). Maximum is 50', v_count;
  END IF;

  -- Parse + validate every line before touching the catalog.
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_raw_id  := NULLIF(COALESCE(v_item->>'variant_id', v_item->>'variantId'), '');
    v_raw_qty := COALESCE(v_item->>'quantity', '');

    IF v_raw_id IS NULL
       OR v_raw_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RAISE EXCEPTION 'Cart line has a missing or malformed variant id';
    END IF;

    -- Whole numbers only: blocks negative and fractional quantities, which
    -- previously flowed straight into subtotal arithmetic.
    IF v_raw_qty !~ '^[0-9]{1,2}$' OR v_raw_qty::integer < 1 THEN
      RAISE EXCEPTION 'Cart quantity must be a whole number between 1 and 99 (got "%")', v_raw_qty;
    END IF;

    v_pairs := v_pairs || jsonb_build_object('v', v_raw_id, 'q', v_raw_qty::integer);
  END LOOP;

  SELECT COUNT(DISTINCT e->>'v') INTO v_expected
  FROM jsonb_array_elements(v_pairs) e;

  SELECT COUNT(*) INTO v_matched
  FROM (
    SELECT DISTINCT (e->>'v')::uuid AS v_id
    FROM jsonb_array_elements(v_pairs) e
  ) req
  JOIN public.product_variants pv ON pv.id = req.v_id
  JOIN public.products p          ON p.id  = pv.product_id
  WHERE COALESCE(pv.is_active, true) = true
    AND COALESCE(p.in_stock, true)   = true
    AND COALESCE(p.is_archived, false) = false;   -- migration 028

  IF v_matched <> v_expected THEN
    RAISE EXCEPTION 'One or more items are unavailable, inactive, or out of stock';
  END IF;

  RETURN QUERY
  WITH merged AS (
    SELECT (e->>'v')::uuid AS v_id, SUM((e->>'q')::int)::integer AS qty
    FROM jsonb_array_elements(v_pairs) e
    GROUP BY (e->>'v')::uuid
  )
  SELECT
    m.v_id,
    LEAST(m.qty, 99)::integer,
    round(pv.price::numeric, 2),
    p.name,
    pv.label,
    COALESCE(pv.weight_grams, 0)::numeric,
    COALESCE(pv.free_delivery, false)
  FROM merged m
  JOIN public.product_variants pv ON pv.id = m.v_id
  JOIN public.products p          ON p.id  = pv.product_id;
END;
$function$;

-- ─── 3. public.delete_product ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.delete_product(p_product_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_order_lines  integer;
  v_sub_lines    integer;
  v_day_lines    integer;
  v_reviews      integer;
BEGIN
  IF NOT internal.is_admin_actor('products:edit') THEN
    RAISE EXCEPTION 'Not authorized to delete products';
  END IF;

  -- Lock the product row so nothing can reference it mid-check.
  PERFORM 1 FROM public.products WHERE id = p_product_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found';
  END IF;

  SELECT COUNT(*) INTO v_order_lines
  FROM public.order_items oi
  JOIN public.product_variants pv ON pv.id = oi.variant_id
  WHERE pv.product_id = p_product_id;

  SELECT COUNT(*) INTO v_sub_lines
  FROM public.subscription_items si
  JOIN public.product_variants pv ON pv.id = si.variant_id
  WHERE pv.product_id = p_product_id;

  SELECT COUNT(*) INTO v_day_lines
  FROM public.subscription_daily_order_items di
  JOIN public.product_variants pv ON pv.id = di.variant_id
  WHERE pv.product_id = p_product_id;

  SELECT COUNT(*) INTO v_reviews
  FROM public.reviews r
  WHERE r.product_id = p_product_id
     OR r.variant_id IN (SELECT id FROM public.product_variants WHERE product_id = p_product_id);

  IF v_order_lines + v_sub_lines + v_day_lines + v_reviews > 0 THEN
    RAISE EXCEPTION
      'This product has history (% order line(s), % subscription line(s), % daily-delivery line(s), % review(s)) and cannot be deleted. Archive it instead.',
      v_order_lines, v_sub_lines, v_day_lines, v_reviews;
  END IF;

  -- No history: carts are the only remaining references. Delete everything in
  -- dependency order; this function body is one transaction, so either all of
  -- it happens or none of it does.
  DELETE FROM public.cart_items
  WHERE variant_id IN (SELECT id FROM public.product_variants WHERE product_id = p_product_id);

  DELETE FROM public.product_images   WHERE product_id = p_product_id;
  DELETE FROM public.product_variants WHERE product_id = p_product_id;
  DELETE FROM public.products         WHERE id = p_product_id;
END;
$function$;

-- ─── 4. public.set_product_archived ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_product_archived(p_product_id uuid, p_archived boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'internal'
AS $function$
DECLARE
  v_active_subs integer;
BEGIN
  IF NOT internal.is_admin_actor('products:edit') THEN
    RAISE EXCEPTION 'Not authorized to archive products';
  END IF;

  IF p_archived IS NULL THEN
    RAISE EXCEPTION 'p_archived is required';
  END IF;

  PERFORM 1 FROM public.products WHERE id = p_product_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found';
  END IF;

  IF p_archived THEN
    -- Subscriptions still delivering this product as a live item.
    SELECT COUNT(DISTINCT s.id) INTO v_active_subs
    FROM public.subscription_items si
    JOIN public.subscriptions s     ON s.id  = si.subscription_id
    JOIN public.product_variants pv ON pv.id = si.variant_id
    WHERE pv.product_id = p_product_id
      AND si.is_active = true
      AND (si.item_end_date IS NULL OR si.item_end_date >= CURRENT_DATE)
      AND s.status IN ('active', 'pending_cancellation');

    IF v_active_subs > 0 THEN
      RAISE EXCEPTION
        '% active subscription(s) still include this product. Remove it from those subscriptions first, or switch "In Stock" off instead.',
        v_active_subs;
    END IF;

    -- Nobody can check out an archived product (normalize_cart refuses it),
    -- so take it out of carts rather than leave a line that fails at payment.
    DELETE FROM public.cart_items
    WHERE variant_id IN (SELECT id FROM public.product_variants WHERE product_id = p_product_id);
  END IF;

  UPDATE public.products
  SET is_archived = p_archived, updated_at = now()
  WHERE id = p_product_id;
END;
$function$;

-- ─── 5. Grants ───────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.delete_product(uuid)                FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_product_archived(uuid, boolean) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.delete_product(uuid)                TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_product_archived(uuid, boolean) TO authenticated, service_role;

COMMIT;

-- Verification:
--   SELECT column_name FROM information_schema.columns
--   WHERE table_schema = 'public' AND table_name = 'products' AND column_name = 'is_archived';
--   -- a product with order history cannot be deleted:
--   -- SELECT public.delete_product('<ghee product id>');  → "This product has history (...)"
