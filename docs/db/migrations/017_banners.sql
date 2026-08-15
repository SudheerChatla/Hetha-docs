-- Migration 017: Homepage Banners
-- Admin-managed carousel banners for the customer app home page.
-- Images stored in Supabase Storage (bucket: banners), URLs saved here.

CREATE TABLE public.banners (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  image_url text NOT NULL,
  link_url text,                -- optional: deep link or external URL on tap
  display_order integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamp without time zone DEFAULT now(),
  CONSTRAINT banners_pkey PRIMARY KEY (id)
);

-- Index for the common query: active banners sorted by display_order
CREATE INDEX idx_banners_active_order ON public.banners (is_active, display_order)
  WHERE is_active = true;

-- RLS: anyone can read active banners (public content), only admins can write
ALTER TABLE public.banners ENABLE ROW LEVEL SECURITY;

-- Public read for active banners (anon + authenticated)
CREATE POLICY banners_select_active ON public.banners
  FOR SELECT
  USING (is_active = true);

-- Admin write (uses existing has_permission helper)
CREATE POLICY banners_admin_all ON public.banners
  FOR ALL
  USING (public.has_permission('banners:edit') OR public.is_super_admin())
  WITH CHECK (public.has_permission('banners:edit') OR public.is_super_admin());

-- Grant access
GRANT SELECT ON public.banners TO anon, authenticated;
GRANT ALL ON public.banners TO service_role;
