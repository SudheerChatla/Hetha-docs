-- Migration: Add free_delivery flag to product_variants
-- Purpose: Allow marking specific variants as free delivery so they are
--          excluded from the weight-based delivery charge calculation.
-- Run in: Supabase SQL Editor

ALTER TABLE public.product_variants
ADD COLUMN free_delivery boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.product_variants.free_delivery IS
  'When true, this variant does not contribute weight to delivery charge calculation.';
