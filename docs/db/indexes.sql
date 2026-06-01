-- =============================================================================
-- CANONICAL INDEXES SNAPSHOT — public schema
-- Source : pg_indexes (live database)   Synced : 2026-06-01
-- =============================================================================

-- addresses
CREATE UNIQUE INDEX addresses_pkey ON public.addresses USING btree (id);
CREATE INDEX idx_addresses_pincode ON public.addresses USING btree (pincode);
CREATE INDEX idx_addresses_user_id ON public.addresses USING btree (user_id);

-- admin_permissions
CREATE UNIQUE INDEX admin_permissions_pkey ON public.admin_permissions USING btree (id);
CREATE INDEX idx_perm_admin_user ON public.admin_permissions USING btree (admin_user_id);
CREATE UNIQUE INDEX uq_admin_permission ON public.admin_permissions USING btree (admin_user_id, permission_key);

-- admin_role_permissions
CREATE UNIQUE INDEX admin_role_permissions_pkey ON public.admin_role_permissions USING btree (id);

-- admin_users
CREATE UNIQUE INDEX admin_users_pkey ON public.admin_users USING btree (id);
CREATE UNIQUE INDEX admin_users_user_id_key ON public.admin_users USING btree (user_id);

-- audit_logs
CREATE UNIQUE INDEX audit_logs_pkey ON public.audit_logs USING btree (id);
CREATE INDEX idx_audit_admin ON public.audit_logs USING btree (admin_user_id);
CREATE INDEX idx_audit_created ON public.audit_logs USING btree (created_at DESC);
CREATE INDEX idx_audit_table ON public.audit_logs USING btree (table_name, record_id);

-- cart_items
CREATE UNIQUE INDEX cart_items_pkey ON public.cart_items USING btree (id);
CREATE INDEX idx_cart_user_id ON public.cart_items USING btree (user_id);
CREATE UNIQUE INDEX uq_cart_user_variant ON public.cart_items USING btree (user_id, variant_id);

-- categories
CREATE UNIQUE INDEX categories_pkey ON public.categories USING btree (id);

-- delivery_areas
CREATE UNIQUE INDEX delivery_areas_display_name_key ON public.delivery_areas USING btree (display_name);
CREATE UNIQUE INDEX delivery_areas_pkey ON public.delivery_areas USING btree (id);

-- delivery_charge_tiers
CREATE UNIQUE INDEX delivery_charge_tiers_pkey ON public.delivery_charge_tiers USING btree (id);

-- delivery_routes
CREATE UNIQUE INDEX delivery_routes_pkey ON public.delivery_routes USING btree (id);
CREATE UNIQUE INDEX delivery_routes_route_name_key ON public.delivery_routes USING btree (route_name);
CREATE INDEX idx_routes_area_id ON public.delivery_routes USING btree (area_id);

-- delivery_schedule_exceptions
CREATE UNIQUE INDEX delivery_schedule_exceptions_pkey ON public.delivery_schedule_exceptions USING btree (id);

-- notifications
CREATE INDEX idx_notif_status ON public.notifications USING btree (status) WHERE (status = 'pending'::text);
CREATE INDEX idx_notif_user_id ON public.notifications USING btree (user_id);
CREATE UNIQUE INDEX notifications_pkey ON public.notifications USING btree (id);

-- order_items
CREATE INDEX idx_order_items_order ON public.order_items USING btree (order_id);
CREATE UNIQUE INDEX order_items_pkey ON public.order_items USING btree (id);

-- order_tracking
CREATE INDEX idx_tracking_order ON public.order_tracking USING btree (order_id);
CREATE UNIQUE INDEX order_tracking_pkey ON public.order_tracking USING btree (id);

-- orders
CREATE INDEX idx_orders_payment_status ON public.orders USING btree (payment_status);
CREATE INDEX idx_orders_pending_expires ON public.orders USING btree (payment_pending_expires_at) WHERE (payment_status = 'pending'::text);
CREATE INDEX idx_orders_pincode ON public.orders USING btree (pincode);
CREATE INDEX idx_orders_placed_at ON public.orders USING btree (placed_at DESC);
CREATE INDEX idx_orders_status ON public.orders USING btree (status);
CREATE INDEX idx_orders_user_id ON public.orders USING btree (user_id);
CREATE UNIQUE INDEX orders_order_number_key ON public.orders USING btree (order_number);
CREATE UNIQUE INDEX orders_pkey ON public.orders USING btree (id);

-- payment_attempts
CREATE INDEX idx_payment_order_id ON public.payment_attempts USING btree (order_id);
CREATE INDEX idx_payment_rzp_order ON public.payment_attempts USING btree (razorpay_order_id);
CREATE UNIQUE INDEX payment_attempts_pkey ON public.payment_attempts USING btree (id);

-- pincodes
CREATE INDEX idx_pincodes_area_id ON public.pincodes USING btree (area_id);
CREATE UNIQUE INDEX pincodes_pincode_key ON public.pincodes USING btree (pincode);
CREATE UNIQUE INDEX pincodes_pkey ON public.pincodes USING btree (id);

-- product_images
CREATE UNIQUE INDEX product_images_pkey ON public.product_images USING btree (id);

-- product_variants
CREATE INDEX idx_variants_product ON public.product_variants USING btree (product_id);
CREATE UNIQUE INDEX product_variants_pkey ON public.product_variants USING btree (id);

-- products
CREATE INDEX idx_products_category ON public.products USING btree (category_id);
CREATE INDEX idx_products_in_stock ON public.products USING btree (in_stock) WHERE (in_stock = true);
CREATE UNIQUE INDEX products_pkey ON public.products USING btree (id);

-- reviews
CREATE UNIQUE INDEX reviews_pkey ON public.reviews USING btree (id);
CREATE UNIQUE INDEX uq_review_user_order_product ON public.reviews USING btree (user_id, order_id, product_id);

-- roles
CREATE UNIQUE INDEX roles_pkey ON public.roles USING btree (id);
CREATE UNIQUE INDEX roles_role_key ON public.roles USING btree (role);

-- subscription_daily_order_items
CREATE INDEX idx_sdoi_daily_order ON public.subscription_daily_order_items USING btree (daily_order_id);
CREATE UNIQUE INDEX subscription_daily_order_items_pkey ON public.subscription_daily_order_items USING btree (id);

-- subscription_daily_orders
CREATE INDEX idx_sdo_delivery_date ON public.subscription_daily_orders USING btree (delivery_date);
CREATE INDEX idx_sdo_payment_status ON public.subscription_daily_orders USING btree (payment_status);
CREATE INDEX idx_sdo_status ON public.subscription_daily_orders USING btree (status);
CREATE INDEX idx_sdo_sub_id ON public.subscription_daily_orders USING btree (subscription_id);
CREATE INDEX idx_sdo_user_id ON public.subscription_daily_orders USING btree (user_id);
CREATE UNIQUE INDEX subscription_daily_orders_pkey ON public.subscription_daily_orders USING btree (id);
CREATE UNIQUE INDEX uq_sdo_subscription_date ON public.subscription_daily_orders USING btree (subscription_id, delivery_date);

-- subscription_items
CREATE INDEX idx_sub_items_active ON public.subscription_items USING btree (subscription_id) WHERE (is_active = true);
CREATE INDEX idx_sub_items_sub_id ON public.subscription_items USING btree (subscription_id);
CREATE UNIQUE INDEX subscription_items_pkey ON public.subscription_items USING btree (id);

-- subscription_pauses
CREATE INDEX idx_pauses_dates ON public.subscription_pauses USING btree (pause_start_date, pause_end_date);
CREATE INDEX idx_pauses_sub_id ON public.subscription_pauses USING btree (subscription_id);
CREATE UNIQUE INDEX subscription_pauses_pkey ON public.subscription_pauses USING btree (id);

-- subscriptions
CREATE INDEX idx_sub_pincode ON public.subscriptions USING btree (snapshot_pincode);
CREATE INDEX idx_sub_route_id ON public.subscriptions USING btree (route_id);
CREATE INDEX idx_sub_status ON public.subscriptions USING btree (status);
CREATE INDEX idx_sub_user_id ON public.subscriptions USING btree (user_id);
CREATE UNIQUE INDEX subscriptions_pkey ON public.subscriptions USING btree (id);

-- users
CREATE INDEX idx_users_email ON public.users USING btree (email);
CREATE INDEX idx_users_is_adhoc ON public.users USING btree (is_adhoc) WHERE (is_adhoc = true);
CREATE INDEX idx_users_phone ON public.users USING btree (phone);
CREATE UNIQUE INDEX users_email_key ON public.users USING btree (email);
CREATE UNIQUE INDEX users_phone_unique ON public.users USING btree (phone);
CREATE UNIQUE INDEX users_pkey ON public.users USING btree (id);

-- wallet_transactions
CREATE INDEX idx_wallet_created_at ON public.wallet_transactions USING btree (created_at DESC);
CREATE INDEX idx_wallet_reference ON public.wallet_transactions USING btree (reference_type, reference_id);
CREATE INDEX idx_wallet_user_id ON public.wallet_transactions USING btree (user_id);
CREATE UNIQUE INDEX wallet_transactions_pkey ON public.wallet_transactions USING btree (id);
