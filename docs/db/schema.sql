-- =============================================================================
-- CANONICAL SCHEMA SNAPSHOT — public schema (tables only)
-- =============================================================================
-- Source : Supabase → Table Editor → "Copy as SQL" (live database)
-- Synced : 2026-06-01 (payment_intents added by hand 2026-07-28, migration 008)
-- Scope  : Tables, columns, constraints (PK/FK/UNIQUE/CHECK) ONLY.
--          Does NOT include: functions/RPCs, RLS policies, triggers, indexes,
--          pg_cron jobs, or edge functions. Pull those separately — see
--          docs/db/REFRESH.md.
--
-- This file is the source of truth for table structure. The per-repo mirrors
-- (Hetha_app/doc-schema/schema.sql, Hetha_admin/docs/schema.sql) should match
-- this. DATA_MODEL.md is the human-readable view of this snapshot.
--
-- WARNING: This schema is for context only and is not meant to be run as-is.
-- Table order and constraints may not be valid for execution.
-- =============================================================================

CREATE TABLE public.addresses (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  name text NOT NULL,
  phone_number text NOT NULL,
  address_line1 text NOT NULL,
  address_line2 text,
  address_type text,
  landmark text,
  city text NOT NULL,
  state text NOT NULL,
  pincode text NOT NULL,
  is_default boolean DEFAULT false,
  created_at timestamp without time zone DEFAULT now(),
  is_deleted boolean DEFAULT false,
  CONSTRAINT addresses_pkey PRIMARY KEY (id),
  CONSTRAINT fk_address_user FOREIGN KEY (user_id) REFERENCES public.users(id)
);
CREATE TABLE public.admin_permissions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  admin_user_id uuid NOT NULL,
  permission_key text NOT NULL,
  granted_by uuid,
  granted_at timestamp without time zone DEFAULT now(),
  CONSTRAINT admin_permissions_pkey PRIMARY KEY (id)
);
CREATE TABLE public.admin_role_permissions (
  id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  role_id uuid DEFAULT gen_random_uuid(),
  permission text,
  CONSTRAINT admin_role_permissions_pkey PRIMARY KEY (id),
  CONSTRAINT admin_role_permissions_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(id)
);
CREATE TABLE public.admin_users (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL UNIQUE,
  role_id uuid NOT NULL,
  admin_name text NOT NULL,
  email text,
  is_active boolean DEFAULT true,
  created_at timestamp without time zone DEFAULT now(),
  CONSTRAINT admin_users_pkey PRIMARY KEY (id),
  CONSTRAINT fk_admin_user FOREIGN KEY (user_id) REFERENCES auth.users(id),
  CONSTRAINT fk_admin_role FOREIGN KEY (role_id) REFERENCES public.roles(id)
);
CREATE TABLE public.audit_logs (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  admin_user_id uuid,
  action text NOT NULL,
  table_name text NOT NULL,
  record_id uuid,
  old_values jsonb,
  new_values jsonb,
  ip_address text,
  created_at timestamp without time zone DEFAULT now(),
  CONSTRAINT audit_logs_pkey PRIMARY KEY (id)
);
CREATE TABLE public.banners (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  image_url text NOT NULL,
  link_url text,
  display_order integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamp without time zone DEFAULT now(),
  CONSTRAINT banners_pkey PRIMARY KEY (id)
);
CREATE TABLE public.cart_items (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  variant_id uuid NOT NULL,
  quantity integer NOT NULL CHECK (quantity > 0),
  added_at timestamp without time zone DEFAULT now(),
  CONSTRAINT cart_items_pkey PRIMARY KEY (id),
  CONSTRAINT fk_cart_variant FOREIGN KEY (variant_id) REFERENCES public.product_variants(id),
  CONSTRAINT fk_cart_user FOREIGN KEY (user_id) REFERENCES public.users(id)
);
CREATE TABLE public.categories (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  name text NOT NULL,
  image_url text,
  display_order integer DEFAULT 0,
  is_active boolean DEFAULT true,
  created_at timestamp without time zone DEFAULT now(),
  CONSTRAINT categories_pkey PRIMARY KEY (id)
);
CREATE TABLE public.delivery_areas (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  display_name text NOT NULL UNIQUE,
  is_active boolean DEFAULT true,
  support_email text,
  support_phone text,
  support_hours text,
  advance_order_days integer DEFAULT 0,
  max_order_days integer DEFAULT 7,
  order_cutoff_time time without time zone,
  cancellation_cutoff_time time without time zone,
  version integer DEFAULT 1,
  created_at timestamp without time zone DEFAULT now(),
  updated_at timestamp without time zone DEFAULT now(),
  delivary_frequency bigint,
  reference_date date,
  CONSTRAINT delivery_areas_pkey PRIMARY KEY (id)
);
CREATE TABLE public.delivery_charge_tiers (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  min_weight_grams numeric NOT NULL,
  max_weight_grams numeric NOT NULL,
  charge numeric NOT NULL CHECK (charge >= 0::numeric),
  created_at timestamp without time zone DEFAULT now(),
  CONSTRAINT delivery_charge_tiers_pkey PRIMARY KEY (id)
);
CREATE TABLE public.delivery_routes (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  area_id uuid NOT NULL,
  route_name text NOT NULL UNIQUE,
  is_active boolean DEFAULT true,
  CONSTRAINT delivery_routes_pkey PRIMARY KEY (id),
  CONSTRAINT fk_delivery_routes_area FOREIGN KEY (area_id) REFERENCES public.delivery_areas(id)
);
CREATE TABLE public.delivery_schedule_exceptions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  area_id uuid NOT NULL,
  reference_date date NOT NULL,
  exception_type text NOT NULL,
  note text,
  CONSTRAINT delivery_schedule_exceptions_pkey PRIMARY KEY (id),
  CONSTRAINT fk_schedule_exceptions_area FOREIGN KEY (area_id) REFERENCES public.delivery_areas(id)
);
CREATE TABLE public.notifications (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  type text NOT NULL CHECK (type = ANY (ARRAY['push'::text, 'sms'::text, 'whatsapp'::text])),
  template_key text,
  title text,
  body text,
  data jsonb DEFAULT '{}'::jsonb,
  reference_type text,
  reference_id uuid,
  status text NOT NULL DEFAULT 'pending'::text CHECK (status = ANY (ARRAY['pending'::text, 'sent'::text, 'failed'::text])),
  read_at timestamp with time zone DEFAULT NULL,
  sent_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT notifications_pkey PRIMARY KEY (id),
  CONSTRAINT fk_notif_user FOREIGN KEY (user_id) REFERENCES public.users(id)
);
CREATE TABLE public.device_tokens (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  fcm_token text NOT NULL,
  platform text NOT NULL CHECK (platform IN ('android', 'ios')),
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now(),
  CONSTRAINT device_tokens_pkey PRIMARY KEY (id),
  CONSTRAINT device_tokens_user_id_fcm_token_key UNIQUE (user_id, fcm_token),
  CONSTRAINT fk_device_tokens_user FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
);
CREATE TABLE public.order_items (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL,
  variant_id uuid NOT NULL,
  product_name_snapshot text NOT NULL,
  variant_label_snapshot text NOT NULL,
  unit_price numeric NOT NULL,
  quantity integer NOT NULL CHECK (quantity > 0),
  total_price numeric NOT NULL,
  CONSTRAINT order_items_pkey PRIMARY KEY (id),
  CONSTRAINT fk_order_items_order FOREIGN KEY (order_id) REFERENCES public.orders(id),
  CONSTRAINT fk_order_items_variant FOREIGN KEY (variant_id) REFERENCES public.product_variants(id)
);
CREATE TABLE public.order_tracking (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL,
  status text NOT NULL,
  courier_service text,
  awb_number text,
  lr_number text,
  tracking_url text,
  customer_message text,
  updated_by text,
  updated_at timestamp without time zone DEFAULT now(),
  CONSTRAINT order_tracking_pkey PRIMARY KEY (id),
  CONSTRAINT fk_tracking_order FOREIGN KEY (order_id) REFERENCES public.orders(id)
);
CREATE TABLE public.payment_intents (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  purpose text NOT NULL CHECK (purpose = ANY (ARRAY['wallet_topup'::text, 'order'::text])),
  status text NOT NULL DEFAULT 'created'::text CHECK (status = ANY (ARRAY['created'::text, 'paid'::text, 'failed'::text, 'expired'::text])),
  amount_paise bigint NOT NULL CHECK (amount_paise > 0),
  razorpay_order_id text UNIQUE,
  razorpay_payment_id text UNIQUE,
  address_id uuid,
  cart_items jsonb,
  order_id uuid,
  amount_paid_paise bigint,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  expires_at timestamp with time zone NOT NULL DEFAULT (now() + '00:30:00'::interval),
  consumed_at timestamp with time zone,
  CONSTRAINT payment_intents_pkey PRIMARY KEY (id),
  CONSTRAINT payment_intents_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id),
  CONSTRAINT payment_intents_address_id_fkey FOREIGN KEY (address_id) REFERENCES public.addresses(id),
  CONSTRAINT payment_intents_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id)
);
-- ^ Added 2026-07-28 (migration 008). `amount_paise` is decided by the SERVER
--   (catalog price + tier delivery charge for orders; range-checked request for
--   top-ups) and is what the payment is verified against. RLS is enabled with NO
--   policies and all grants revoked from anon/authenticated — service role only.
CREATE TABLE public.orders (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  order_number text NOT NULL UNIQUE,
  user_id uuid NOT NULL,
  address_snapshot_id uuid NOT NULL,
  status text NOT NULL CHECK (status = ANY (ARRAY['payment_pending'::text, 'placed'::text, 'processing'::text, 'shipped'::text, 'out_for_delivery'::text, 'delivered'::text, 'cancelled'::text])),
  payment_method text NOT NULL CHECK (payment_method = ANY (ARRAY['wallet'::text, 'razorpay'::text, 'wallet_razorpay'::text, 'cod'::text])),
  payment_status text NOT NULL CHECK (payment_status = ANY (ARRAY['pending'::text, 'paid'::text, 'failed'::text, 'refunded'::text])),
  subtotal numeric NOT NULL,
  delivery_charge numeric DEFAULT 0,
  total numeric NOT NULL,
  delivery_time_slot text,
  expected_delivery_date date,
  pincode text,
  placed_at timestamp without time zone DEFAULT now(),
  updated_at timestamp without time zone DEFAULT now(),
  snapshot_name text,
  snapshot_phone text,
  snapshot_address_line1 text,
  snapshot_address_line2 text,
  snapshot_landmark text,
  snapshot_city text,
  snapshot_state text,
  snapshot_pincode text,
  snapshot_address_type text,
  wallet_amount_used numeric DEFAULT 0,
  razorpay_amount numeric DEFAULT 0,
  razorpay_order_id text,
  razorpay_payment_id text,
  payment_pending_expires_at timestamp without time zone,
  cancellation_reason text,
  cancelled_by text,
  cancelled_at timestamp without time zone,
  CONSTRAINT orders_pkey PRIMARY KEY (id),
  CONSTRAINT fk_order_address FOREIGN KEY (address_snapshot_id) REFERENCES public.addresses(id),
  CONSTRAINT fk_order_user FOREIGN KEY (user_id) REFERENCES public.users(id)
);
CREATE TABLE public.payment_attempts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL,
  attempt_number integer NOT NULL DEFAULT 1,
  razorpay_order_id text,
  razorpay_payment_id text,
  total_amount numeric NOT NULL,
  wallet_amount numeric DEFAULT 0,
  razorpay_amount numeric DEFAULT 0,
  status text NOT NULL CHECK (status = ANY (ARRAY['initiated'::text, 'success'::text, 'failed'::text, 'expired'::text])),
  failure_reason text,
  created_at timestamp without time zone DEFAULT now(),
  CONSTRAINT payment_attempts_pkey PRIMARY KEY (id),
  CONSTRAINT fk_payment_attempt_order FOREIGN KEY (order_id) REFERENCES public.orders(id)
);
CREATE TABLE public.pincodes (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  area_id uuid NOT NULL,
  pincode text NOT NULL UNIQUE,
  cod_eligible boolean DEFAULT false,
  CONSTRAINT pincodes_pkey PRIMARY KEY (id),
  CONSTRAINT fk_pincodes_area FOREIGN KEY (area_id) REFERENCES public.delivery_areas(id)
);
CREATE TABLE public.product_images (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL,
  image_url text NOT NULL,
  display_order integer DEFAULT 0,
  CONSTRAINT product_images_pkey PRIMARY KEY (id),
  CONSTRAINT fk_image_product FOREIGN KEY (product_id) REFERENCES public.products(id)
);
CREATE TABLE public.product_variants (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL,
  label text NOT NULL,
  price numeric NOT NULL,
  weight_grams numeric,
  is_preferred boolean DEFAULT false,
  is_active boolean DEFAULT true,
  free_delivery boolean NOT NULL DEFAULT false,
  CONSTRAINT product_variants_pkey PRIMARY KEY (id),
  CONSTRAINT fk_variant_product FOREIGN KEY (product_id) REFERENCES public.products(id)
);
CREATE TABLE public.products (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  category_id uuid NOT NULL,
  name text NOT NULL,
  description text,
  hsn_code text,
  in_stock boolean DEFAULT true,
  is_bestseller boolean DEFAULT false,
  is_local boolean DEFAULT false,
  delivery_scope text NOT NULL DEFAULT 'local' CHECK (delivery_scope IN ('local', 'all_india')),
  is_default_sub boolean DEFAULT false,
  is_additional_sub boolean DEFAULT false,
  created_at timestamp without time zone DEFAULT now(),
  updated_at timestamp without time zone DEFAULT now(),
  CONSTRAINT products_pkey PRIMARY KEY (id),
  CONSTRAINT fk_product_category FOREIGN KEY (category_id) REFERENCES public.categories(id)
);
CREATE TABLE public.reviews (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  product_id uuid NOT NULL,
  variant_id uuid,
  order_id uuid NOT NULL,
  rating integer NOT NULL CHECK (rating >= 1 AND rating <= 5),
  description text,
  created_at timestamp without time zone DEFAULT now(),
  CONSTRAINT reviews_pkey PRIMARY KEY (id),
  CONSTRAINT fk_review_product FOREIGN KEY (product_id) REFERENCES public.products(id),
  CONSTRAINT fk_review_variant FOREIGN KEY (variant_id) REFERENCES public.product_variants(id),
  CONSTRAINT fk_review_order FOREIGN KEY (order_id) REFERENCES public.orders(id),
  CONSTRAINT fk_review_user FOREIGN KEY (user_id) REFERENCES public.users(id)
);
CREATE TABLE public.roles (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  role text NOT NULL UNIQUE,
  CONSTRAINT roles_pkey PRIMARY KEY (id)
);
CREATE TABLE public.subscription_daily_order_items (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  daily_order_id uuid NOT NULL,
  variant_id uuid NOT NULL,
  product_name_snapshot text NOT NULL,
  variant_label_snapshot text NOT NULL,
  unit_price numeric NOT NULL,
  quantity integer NOT NULL CHECK (quantity > 0),
  total_price numeric NOT NULL,
  is_adhoc_addition boolean DEFAULT false,
  delivered_qty integer,
  CONSTRAINT subscription_daily_order_items_pkey PRIMARY KEY (id),
  CONSTRAINT fk_sdoi_daily_order FOREIGN KEY (daily_order_id) REFERENCES public.subscription_daily_orders(id),
  CONSTRAINT fk_sdoi_variant FOREIGN KEY (variant_id) REFERENCES public.product_variants(id)
);
CREATE TABLE public.subscription_daily_orders (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  delivery_date date NOT NULL,
  subscription_id uuid NOT NULL,
  user_id uuid NOT NULL,
  status text NOT NULL CHECK (status = ANY (ARRAY['pending'::text, 'skipped'::text, 'delivered'::text, 'cancelled'::text])),
  total_value numeric NOT NULL,
  created_at timestamp without time zone DEFAULT now(),
  payment_status text NOT NULL DEFAULT 'pending'::text CHECK (payment_status = ANY (ARRAY['pending'::text, 'paid'::text, 'refunded'::text])),
  wallet_deducted_at timestamp without time zone,
  is_finalized boolean DEFAULT false,
  finalized_at timestamp without time zone,
  finalized_by uuid,
  tracking_info text,
  custom_route text,
  CONSTRAINT subscription_daily_orders_pkey PRIMARY KEY (id),
  CONSTRAINT fk_sdo_subscription FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id),
  CONSTRAINT fk_sdo_user FOREIGN KEY (user_id) REFERENCES public.users(id)
);
CREATE TABLE public.subscription_items (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  subscription_id uuid NOT NULL,
  variant_id uuid NOT NULL,
  product_name_snapshot text NOT NULL,
  variant_label_snapshot text NOT NULL,
  unit_price numeric NOT NULL,
  quantity integer NOT NULL CHECK (quantity > 0),
  item_start_date date NOT NULL,
  item_end_date date,
  is_active boolean DEFAULT true,
  CONSTRAINT subscription_items_pkey PRIMARY KEY (id),
  CONSTRAINT fk_sub_item_subscription FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id),
  CONSTRAINT fk_sub_item_variant FOREIGN KEY (variant_id) REFERENCES public.product_variants(id)
);
CREATE TABLE public.subscription_pauses (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  subscription_id uuid NOT NULL,
  pause_start_date date NOT NULL,
  pause_end_date date NOT NULL,
  reason text,
  created_by text DEFAULT 'user'::text CHECK (created_by = ANY (ARRAY['user'::text, 'admin'::text])),
  created_at timestamp without time zone DEFAULT now(),
  CONSTRAINT subscription_pauses_pkey PRIMARY KEY (id),
  CONSTRAINT fk_pause_subscription FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id)
);
CREATE TABLE public.subscriptions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  address_id uuid,
  route_id uuid,
  status text NOT NULL CHECK (status = ANY (ARRAY['active'::text, 'paused'::text, 'cancelled'::text, 'pending_cancellation'::text])),
  start_date date,
  end_date date,
  is_custom_cancel_date boolean DEFAULT false,
  cancellation_type text,
  cancelled_at timestamp without time zone,
  created_at timestamp without time zone DEFAULT now(),
  last_modified_at timestamp without time zone DEFAULT now(),
  version integer DEFAULT 1,
  snapshot_name text,
  snapshot_phone text,
  snapshot_address_line1 text,
  snapshot_address_line2 text,
  snapshot_landmark text,
  snapshot_city text,
  snapshot_state text,
  snapshot_pincode text,
  snapshot_address_type text,
  payment_method text DEFAULT 'wallet'::text CHECK (payment_method = ANY (ARRAY['wallet'::text, 'cod'::text])),
  cancellation_reason text,
  delivary_frequency bigint,
  delivary_area text,
  label text,
  CONSTRAINT subscriptions_pkey PRIMARY KEY (id),
  CONSTRAINT fk_route FOREIGN KEY (route_id) REFERENCES public.delivery_routes(id),
  CONSTRAINT fk_user FOREIGN KEY (user_id) REFERENCES public.users(id)
);
CREATE TABLE public.users (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  email text UNIQUE,
  phone text UNIQUE,
  first_name text,
  last_name text,
  -- area, pincode, dark_mode and language dropped by migration 018.
  wallet_balance numeric DEFAULT 0 CHECK (wallet_balance >= 0::numeric),
  notifications_enabled boolean DEFAULT true,
  created_at timestamp without time zone DEFAULT now(),
  updated_at timestamp without time zone DEFAULT now(),
  is_adhoc boolean DEFAULT false,
  CONSTRAINT users_pkey PRIMARY KEY (id)
);
CREATE TABLE public.wallet_transactions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  type text NOT NULL CHECK (type = ANY (ARRAY['credit'::text, 'debit'::text])),
  amount numeric NOT NULL CHECK (amount > 0::numeric),
  balance_after numeric NOT NULL,
  description text,
  reference_type text,
  reference_id uuid,
  initiated_by text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT wallet_transactions_pkey PRIMARY KEY (id),
  CONSTRAINT fk_wallet_user FOREIGN KEY (user_id) REFERENCES public.users(id)
);
