-- Migration: Create delivery_partners table
-- Purpose: Configurable list of courier partners with tracking URL templates
-- Run in: Supabase SQL Editor
--
-- The tracking_url_template column supports a placeholder {tracking_id}
-- which gets replaced with the actual AWB/tracking number at runtime.
-- Example: https://www.dtdc.in/tracking/tracking_results.asp?Ession_Id=0&Consession_Id=0&ref_no={tracking_id}

CREATE TABLE public.delivery_partners (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  name text NOT NULL,
  tracking_url_template text,
  is_active boolean DEFAULT true,
  created_at timestamp without time zone DEFAULT now(),
  updated_at timestamp without time zone DEFAULT now(),
  CONSTRAINT delivery_partners_pkey PRIMARY KEY (id),
  CONSTRAINT delivery_partners_name_key UNIQUE (name)
);

ALTER TABLE public.delivery_partners ENABLE ROW LEVEL SECURITY;

CREATE POLICY "delivery_partners_select_policy" ON public.delivery_partners
  FOR SELECT USING (true);

CREATE POLICY "delivery_partners_write_policy" ON public.delivery_partners
  FOR ALL USING (is_super_admin() OR has_permission('orders:edit'))
  WITH CHECK (is_super_admin() OR has_permission('orders:edit'));

-- Seed common partners
INSERT INTO public.delivery_partners (name, tracking_url_template) VALUES
  ('DTDC', 'https://www.dtdc.in/tracking/tracking_results.asp?ref_no={tracking_id}'),
  ('Delhivery', 'https://www.delhivery.com/track/package/{tracking_id}'),
  ('BlueDart', 'https://www.bluedart.com/tracking/{tracking_id}'),
  ('Trackon', 'https://trackon.in/courier-tracking?ref_no={tracking_id}');
