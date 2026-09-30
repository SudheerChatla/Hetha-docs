-- Migration 029: Trim stray whitespace from product and variant names
--
-- Run in: Supabase SQL Editor (the whole file; it is wrapped in one transaction)
--
-- The honey product's name was saved as " Honey" (leading space). It showed
-- with an odd gap in the app, sorted first alphabetically, and could miss
-- exact-match searches. The admin API now trims names on create/update
-- (Hetha_admin app/api/admin/products/route.ts); this cleans existing rows.
--
-- Only the live catalog is touched. Snapshot columns on past orders
-- (product_name_snapshot) are history and are deliberately left as they were.

BEGIN;

UPDATE public.products
SET name = btrim(name), updated_at = now()
WHERE name <> btrim(name);

UPDATE public.product_variants
SET label = btrim(label)
WHERE label <> btrim(label);

COMMIT;

-- Verification (both should return 0):
--   SELECT COUNT(*) FROM public.products         WHERE name  <> btrim(name);
--   SELECT COUNT(*) FROM public.product_variants WHERE label <> btrim(label);
