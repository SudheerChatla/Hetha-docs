-- =============================================================================
-- CANONICAL RLS POLICIES SNAPSHOT — public schema
-- Source : pg_policies (live database)   Synced : 2026-06-01
-- =============================================================================
-- RLS is ENABLED on all 29 public tables (new tables get it via the
-- rls_auto_enable event trigger). Policies are PERMISSIVE, so multiple policies
-- on the same (table, cmd) combine with OR.
--
-- Standard pattern:
--   • Customers: row-ownership check (auth.uid() = user_id, or via a join to a
--     parent row they own).
--   • Admins: is_super_admin() OR has_permission('<resource>:<action>').
--   • Catalog tables (categories, products, product_variants, product_images,
--     delivery_areas, delivery_charge_tiers, delivery_routes, pincodes, reviews)
--     are world-readable via a SELECT USING (true) policy.
--
-- ⚠ FINDINGS at sync time:
--   1. PERMISSION-KEY DRIFT: delivery_areas policies use has_permission('pincode:*')
--      (SINGULAR), but lib/constants.ts and the pincodes table use 'pincodes:*'
--      (PLURAL). Non-super-admins are likely never granted 'pincode:*', so only
--      super_admin can write delivery_areas via RLS.
--   2. ORPHAN PERMISSIONS: audit_logs policies use 'audit_logs:create' /
--      'audit_logs:view', which are NOT in the PAGE_PERMISSIONS catalog
--      (lib/constants.ts) — so only super_admin can access audit_logs.
--   3. DUAL / LEGACY POLICIES: many tables carry both old "Users can ..." owner
--      policies and newer "<table>_*_policy" RBAC policies. They OR together
--      (harmless but redundant — candidates for cleanup).
--   4. Most policies target role {public} (includes anon), but are gated by
--      auth.uid() checks; the users table owner-policies target {authenticated}.
--   5. notifications has only a SELECT (own) policy — no INSERT policy, so rows
--      are written only by service_role / SECURITY DEFINER paths.
-- =============================================================================

-- addresses ------------------------------------------------------------------
CREATE POLICY "Users can insert own addresses" ON public.addresses FOR INSERT TO public WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can read own addresses" ON public.addresses FOR SELECT TO public USING (auth.uid() = user_id);
CREATE POLICY "Users can soft delete own addresses" ON public.addresses FOR UPDATE TO public USING (auth.uid() = user_id);
CREATE POLICY "Users can update own addresses" ON public.addresses FOR UPDATE TO public USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "addresses_delete_policy" ON public.addresses FOR DELETE TO public USING ((user_id = auth.uid()) OR is_super_admin() OR has_permission('customers:edit'));
CREATE POLICY "addresses_insert_policy" ON public.addresses FOR INSERT TO public WITH CHECK ((user_id = auth.uid()) OR is_super_admin() OR has_permission('customers:edit'));
CREATE POLICY "addresses_update_policy" ON public.addresses FOR UPDATE TO public USING ((user_id = auth.uid()) OR is_super_admin() OR has_permission('customers:edit')) WITH CHECK ((user_id = auth.uid()) OR is_super_admin() OR has_permission('customers:edit'));
CREATE POLICY "addresses_view_policy" ON public.addresses FOR SELECT TO public USING ((user_id = auth.uid()) OR is_super_admin() OR has_permission('customers:view') OR has_permission('customers:edit'));

-- admin_role_permissions -----------------------------------------------------
CREATE POLICY "Only super_admin manage permissions" ON public.admin_role_permissions FOR ALL TO public USING (is_super_admin());
CREATE POLICY "admin_role_permissions_view_assigned" ON public.admin_role_permissions FOR SELECT TO public USING (EXISTS (SELECT 1 FROM admin_users WHERE admin_users.user_id = auth.uid() AND admin_users.role_id = admin_role_permissions.role_id));

-- admin_users ----------------------------------------------------------------
CREATE POLICY "admin_users_delete_policy" ON public.admin_users FOR DELETE TO public USING (is_super_admin());
CREATE POLICY "admin_users_insert_policy" ON public.admin_users FOR INSERT TO public WITH CHECK (is_super_admin());
CREATE POLICY "admin_users_update_policy" ON public.admin_users FOR UPDATE TO public USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "admin_users_view_own" ON public.admin_users FOR SELECT TO public USING (user_id = auth.uid());
CREATE POLICY "admin_users_view_policy" ON public.admin_users FOR SELECT TO public USING (is_super_admin() OR (user_id = auth.uid()));

-- audit_logs -----------------------------------------------------------------
CREATE POLICY "audit_logs_insert_policy" ON public.audit_logs FOR INSERT TO public WITH CHECK (is_super_admin() OR has_permission('audit_logs:create'));
CREATE POLICY "audit_logs_view_policy" ON public.audit_logs FOR SELECT TO public USING (is_super_admin() OR has_permission('audit_logs:view'));

-- cart_items -----------------------------------------------------------------
CREATE POLICY "Users can delete own cart items" ON public.cart_items FOR DELETE TO public USING (auth.uid() = user_id);
CREATE POLICY "Users can insert into own cart" ON public.cart_items FOR INSERT TO public WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can read own cart" ON public.cart_items FOR SELECT TO public USING (auth.uid() = user_id);
CREATE POLICY "Users can update own cart items" ON public.cart_items FOR UPDATE TO public USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "cart_items_view_policy" ON public.cart_items FOR SELECT TO public USING ((user_id = auth.uid()) OR is_super_admin() OR has_permission('customers:view') OR has_permission('customers:edit'));

-- categories -----------------------------------------------------------------
CREATE POLICY "Public can read categories" ON public.categories FOR SELECT TO public USING (true);
CREATE POLICY "categories_delete_policy" ON public.categories FOR DELETE TO public USING (is_super_admin() OR has_permission('categories:edit') OR has_permission('products:edit'));
CREATE POLICY "categories_insert_policy" ON public.categories FOR INSERT TO public WITH CHECK (is_super_admin() OR has_permission('categories:edit') OR has_permission('products:edit'));
CREATE POLICY "categories_update_policy" ON public.categories FOR UPDATE TO public USING (is_super_admin() OR has_permission('categories:edit') OR has_permission('products:edit')) WITH CHECK (is_super_admin() OR has_permission('categories:edit') OR has_permission('products:edit'));
CREATE POLICY "categories_view_policy" ON public.categories FOR SELECT TO public USING (is_super_admin() OR has_permission('categories:view') OR has_permission('categories:edit') OR has_permission('products:view') OR has_permission('products:edit'));

-- delivery_areas  (⚠ uses singular 'pincode:*' — see findings) ---------------
CREATE POLICY "Public can read delivery areas" ON public.delivery_areas FOR SELECT TO public USING (true);
CREATE POLICY "delivery_areas_delete_policy" ON public.delivery_areas FOR DELETE TO public USING (is_super_admin() OR has_permission('subscriptions:edit') OR has_permission('pincode:edit'));
CREATE POLICY "delivery_areas_insert_policy" ON public.delivery_areas FOR INSERT TO public WITH CHECK (is_super_admin() OR has_permission('subscriptions:edit') OR has_permission('pincode:edit'));
CREATE POLICY "delivery_areas_update_policy" ON public.delivery_areas FOR UPDATE TO public USING (is_super_admin() OR has_permission('subscriptions:edit') OR has_permission('pincode:edit')) WITH CHECK (is_super_admin() OR has_permission('subscriptions:edit') OR has_permission('pincode:edit'));
CREATE POLICY "delivery_areas_view_policy" ON public.delivery_areas FOR SELECT TO public USING ((is_active = true) OR is_super_admin() OR has_permission('subscriptions:view') OR has_permission('subscriptions:edit') OR has_permission('pincode:view') OR has_permission('pincode:edit'));

-- delivery_charge_tiers ------------------------------------------------------
CREATE POLICY "Public can read delivery charge tiers" ON public.delivery_charge_tiers FOR SELECT TO public USING (true);
CREATE POLICY "delivery_charge_tiers_delete_policy" ON public.delivery_charge_tiers FOR DELETE TO public USING (is_super_admin() OR has_permission('delivery_charges:edit'));
CREATE POLICY "delivery_charge_tiers_insert_policy" ON public.delivery_charge_tiers FOR INSERT TO public WITH CHECK (is_super_admin() OR has_permission('delivery_charges:edit'));
CREATE POLICY "delivery_charge_tiers_update_policy" ON public.delivery_charge_tiers FOR UPDATE TO public USING (is_super_admin() OR has_permission('delivery_charges:edit')) WITH CHECK (is_super_admin() OR has_permission('delivery_charges:edit'));
CREATE POLICY "delivery_charge_tiers_view_policy" ON public.delivery_charge_tiers FOR SELECT TO public USING (is_super_admin() OR has_permission('delivery_charges:view') OR has_permission('delivery_charges:edit'));

-- delivery_routes ------------------------------------------------------------
CREATE POLICY "Public can read delivery routes" ON public.delivery_routes FOR SELECT TO public USING (true);
CREATE POLICY "delivery_routes_delete_policy" ON public.delivery_routes FOR DELETE TO public USING (is_super_admin() OR has_permission('subscriptions:edit'));
CREATE POLICY "delivery_routes_insert_policy" ON public.delivery_routes FOR INSERT TO public WITH CHECK (is_super_admin() OR has_permission('subscriptions:edit'));
CREATE POLICY "delivery_routes_update_policy" ON public.delivery_routes FOR UPDATE TO public USING (is_super_admin() OR has_permission('subscriptions:edit')) WITH CHECK (is_super_admin() OR has_permission('subscriptions:edit'));
CREATE POLICY "delivery_routes_view_policy" ON public.delivery_routes FOR SELECT TO public USING (is_super_admin() OR has_permission('subscriptions:view') OR has_permission('subscriptions:edit'));

-- delivery_schedule_exceptions -----------------------------------------------
CREATE POLICY "delivery_schedule_exceptions_insert_policy" ON public.delivery_schedule_exceptions FOR INSERT TO public WITH CHECK (is_super_admin() OR has_permission('subscriptions:edit'));
CREATE POLICY "delivery_schedule_exceptions_update_policy" ON public.delivery_schedule_exceptions FOR UPDATE TO public USING (is_super_admin() OR has_permission('subscriptions:edit')) WITH CHECK (is_super_admin() OR has_permission('subscriptions:edit'));
CREATE POLICY "delivery_schedule_exceptions_view_policy" ON public.delivery_schedule_exceptions FOR SELECT TO public USING (is_super_admin() OR has_permission('subscriptions:view') OR has_permission('subscriptions:edit'));

-- notifications --------------------------------------------------------------
CREATE POLICY "Users can read own notifications" ON public.notifications FOR SELECT TO public USING (auth.uid() = user_id);

-- order_items ----------------------------------------------------------------
CREATE POLICY "Users can read own order items" ON public.order_items FOR SELECT TO public USING (EXISTS (SELECT 1 FROM orders WHERE orders.id = order_items.order_id AND orders.user_id = auth.uid()));
CREATE POLICY "order_items_insert_policy" ON public.order_items FOR INSERT TO public WITH CHECK (is_super_admin() OR has_permission('orders:edit'));
CREATE POLICY "order_items_update_policy" ON public.order_items FOR UPDATE TO public USING (is_super_admin() OR has_permission('orders:edit')) WITH CHECK (is_super_admin() OR has_permission('orders:edit'));
CREATE POLICY "order_items_view_policy" ON public.order_items FOR SELECT TO public USING (EXISTS (SELECT 1 FROM orders o WHERE o.id = order_items.order_id AND ((o.user_id = auth.uid()) OR is_super_admin() OR has_permission('orders:view') OR has_permission('orders:edit'))));

-- order_tracking -------------------------------------------------------------
CREATE POLICY "Users can read own order tracking" ON public.order_tracking FOR SELECT TO public USING (EXISTS (SELECT 1 FROM orders WHERE orders.id = order_tracking.order_id AND orders.user_id = auth.uid()));
CREATE POLICY "order_tracking_insert_policy" ON public.order_tracking FOR INSERT TO public WITH CHECK (is_super_admin() OR has_permission('orders:edit'));
CREATE POLICY "order_tracking_update_policy" ON public.order_tracking FOR UPDATE TO public USING (is_super_admin() OR has_permission('orders:edit')) WITH CHECK (is_super_admin() OR has_permission('orders:edit'));
CREATE POLICY "order_tracking_view_policy" ON public.order_tracking FOR SELECT TO public USING (EXISTS (SELECT 1 FROM orders o WHERE o.id = order_tracking.order_id AND ((o.user_id = auth.uid()) OR is_super_admin() OR has_permission('orders:view') OR has_permission('orders:edit'))));

-- orders ---------------------------------------------------------------------
CREATE POLICY "Users can read own orders" ON public.orders FOR SELECT TO public USING (auth.uid() = user_id);
CREATE POLICY "orders_create_policy" ON public.orders FOR INSERT TO public WITH CHECK ((user_id = auth.uid()) OR is_super_admin() OR has_permission('orders:edit'));
CREATE POLICY "orders_delete_policy" ON public.orders FOR DELETE TO public USING (is_super_admin() OR has_permission('orders:edit'));
CREATE POLICY "orders_update_policy" ON public.orders FOR UPDATE TO public USING (is_super_admin() OR has_permission('orders:edit')) WITH CHECK (is_super_admin() OR has_permission('orders:edit'));
CREATE POLICY "orders_view_user_policy" ON public.orders FOR SELECT TO public USING ((user_id = auth.uid()) OR is_super_admin() OR has_permission('orders:view') OR has_permission('orders:edit'));

-- payment_attempts -----------------------------------------------------------
CREATE POLICY "Users can read own payment attempts" ON public.payment_attempts FOR SELECT TO public USING (EXISTS (SELECT 1 FROM orders WHERE orders.id = payment_attempts.order_id AND orders.user_id = auth.uid()));
CREATE POLICY "payment_attempts_insert_policy" ON public.payment_attempts FOR INSERT TO public WITH CHECK (is_super_admin() OR has_permission('orders:edit') OR has_permission('payments:edit'));
CREATE POLICY "payment_attempts_update_policy" ON public.payment_attempts FOR UPDATE TO public USING (is_super_admin() OR has_permission('orders:edit') OR has_permission('payments:edit')) WITH CHECK (is_super_admin() OR has_permission('orders:edit') OR has_permission('payments:edit'));
CREATE POLICY "payment_attempts_view_policy" ON public.payment_attempts FOR SELECT TO public USING (EXISTS (SELECT 1 FROM orders o WHERE o.id = payment_attempts.order_id AND ((o.user_id = auth.uid()) OR is_super_admin() OR has_permission('orders:view') OR has_permission('orders:edit') OR has_permission('payments:view') OR has_permission('payments:edit'))));

-- pincodes -------------------------------------------------------------------
CREATE POLICY "Public can read pincodes" ON public.pincodes FOR SELECT TO public USING (true);
CREATE POLICY "pincodes_delete_policy" ON public.pincodes FOR DELETE TO public USING (is_super_admin() OR has_permission('pincodes:edit'));
CREATE POLICY "pincodes_insert_policy" ON public.pincodes FOR INSERT TO public WITH CHECK (is_super_admin() OR has_permission('pincodes:edit'));
CREATE POLICY "pincodes_update_policy" ON public.pincodes FOR UPDATE TO public USING (is_super_admin() OR has_permission('pincodes:edit')) WITH CHECK (is_super_admin() OR has_permission('pincodes:edit'));
CREATE POLICY "pincodes_view_policy" ON public.pincodes FOR SELECT TO public USING (is_super_admin() OR has_permission('pincodes:view') OR has_permission('pincodes:edit'));

-- product_images  (no UPDATE policy) -----------------------------------------
CREATE POLICY "Public can read product images" ON public.product_images FOR SELECT TO public USING (true);
CREATE POLICY "product_images_delete_policy" ON public.product_images FOR DELETE TO public USING (is_super_admin() OR has_permission('products:edit'));
CREATE POLICY "product_images_insert_policy" ON public.product_images FOR INSERT TO public WITH CHECK (is_super_admin() OR has_permission('products:edit'));
CREATE POLICY "product_images_view_policy" ON public.product_images FOR SELECT TO public USING (is_super_admin() OR has_permission('products:view') OR has_permission('products:edit'));

-- product_variants -----------------------------------------------------------
CREATE POLICY "Public can read product variants" ON public.product_variants FOR SELECT TO public USING (true);
CREATE POLICY "product_variants_delete_policy" ON public.product_variants FOR DELETE TO public USING (is_super_admin() OR has_permission('products:edit'));
CREATE POLICY "product_variants_insert_policy" ON public.product_variants FOR INSERT TO public WITH CHECK (is_super_admin() OR has_permission('products:edit'));
CREATE POLICY "product_variants_update_policy" ON public.product_variants FOR UPDATE TO public USING (is_super_admin() OR has_permission('products:edit')) WITH CHECK (is_super_admin() OR has_permission('products:edit'));
CREATE POLICY "product_variants_view_policy" ON public.product_variants FOR SELECT TO public USING (is_super_admin() OR has_permission('products:view') OR has_permission('products:edit'));

-- products  (only the public-read SELECT; writes gated by products:edit) ------
CREATE POLICY "Public can read active products" ON public.products FOR SELECT TO public USING (true);
CREATE POLICY "products_delete_policy" ON public.products FOR DELETE TO public USING (is_super_admin() OR has_permission('products:edit'));
CREATE POLICY "products_insert_policy" ON public.products FOR INSERT TO public WITH CHECK (is_super_admin() OR has_permission('products:edit'));
CREATE POLICY "products_update_policy" ON public.products FOR UPDATE TO public USING (is_super_admin() OR has_permission('products:edit')) WITH CHECK (is_super_admin() OR has_permission('products:edit'));

-- reviews --------------------------------------------------------------------
CREATE POLICY "Users can insert own reviews" ON public.reviews FOR INSERT TO public WITH CHECK ((auth.uid() = user_id) AND EXISTS (SELECT 1 FROM orders WHERE orders.id = reviews.order_id AND orders.user_id = auth.uid() AND orders.status = 'delivered'));
CREATE POLICY "Users can read own reviews" ON public.reviews FOR SELECT TO public USING (auth.uid() = user_id);
CREATE POLICY "Users can update own reviews" ON public.reviews FOR UPDATE TO public USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "reviews_delete_policy" ON public.reviews FOR DELETE TO public USING (is_super_admin() OR has_permission('reviews:edit'));
CREATE POLICY "reviews_insert_policy" ON public.reviews FOR INSERT TO public WITH CHECK ((user_id = auth.uid()) OR is_super_admin() OR has_permission('reviews:edit'));
CREATE POLICY "reviews_update_policy" ON public.reviews FOR UPDATE TO public USING ((user_id = auth.uid()) OR is_super_admin() OR has_permission('reviews:edit')) WITH CHECK ((user_id = auth.uid()) OR is_super_admin() OR has_permission('reviews:edit'));
CREATE POLICY "reviews_view_policy" ON public.reviews FOR SELECT TO public USING (true);

-- roles ----------------------------------------------------------------------
CREATE POLICY "super_admin can delete roles" ON public.roles FOR DELETE TO public USING (is_super_admin());
CREATE POLICY "super_admin can insert roles" ON public.roles FOR INSERT TO public WITH CHECK (is_super_admin());
CREATE POLICY "super_admin can read roles" ON public.roles FOR SELECT TO public USING (is_super_admin());
CREATE POLICY "super_admin can update roles" ON public.roles FOR UPDATE TO public USING (is_super_admin()) WITH CHECK (is_super_admin());

-- subscription_daily_order_items ---------------------------------------------
CREATE POLICY "Users can read own subscription daily order items" ON public.subscription_daily_order_items FOR SELECT TO public USING (EXISTS (SELECT 1 FROM subscription_daily_orders sdo WHERE sdo.id = subscription_daily_order_items.daily_order_id AND sdo.user_id = auth.uid()));
CREATE POLICY "subscription_daily_order_items_delete_policy" ON public.subscription_daily_order_items FOR DELETE TO public USING (is_super_admin() OR has_permission('daily_ops:edit') OR has_permission('subscriptions:edit'));
CREATE POLICY "subscription_daily_order_items_insert_policy" ON public.subscription_daily_order_items FOR INSERT TO public WITH CHECK (is_super_admin() OR has_permission('daily_ops:edit') OR has_permission('subscriptions:edit'));
CREATE POLICY "subscription_daily_order_items_update_policy" ON public.subscription_daily_order_items FOR UPDATE TO public USING (is_super_admin() OR has_permission('daily_ops:edit') OR has_permission('subscriptions:edit')) WITH CHECK (is_super_admin() OR has_permission('daily_ops:edit') OR has_permission('subscriptions:edit'));
CREATE POLICY "subscription_daily_order_items_view_policy" ON public.subscription_daily_order_items FOR SELECT TO public USING (EXISTS (SELECT 1 FROM subscription_daily_orders sdo WHERE sdo.id = subscription_daily_order_items.daily_order_id AND ((sdo.user_id = auth.uid()) OR is_super_admin() OR has_permission('daily_ops:view') OR has_permission('daily_ops:edit') OR has_permission('subscriptions:view') OR has_permission('subscriptions:edit'))));

-- subscription_daily_orders --------------------------------------------------
CREATE POLICY "Users can read own subscription daily orders" ON public.subscription_daily_orders FOR SELECT TO public USING (auth.uid() = user_id);
CREATE POLICY "subscription_daily_orders_delete_policy" ON public.subscription_daily_orders FOR DELETE TO public USING (is_super_admin() OR has_permission('daily_ops:edit') OR has_permission('subscriptions:edit'));
CREATE POLICY "subscription_daily_orders_insert_policy" ON public.subscription_daily_orders FOR INSERT TO public WITH CHECK (is_super_admin() OR has_permission('daily_ops:edit') OR has_permission('subscriptions:edit'));
CREATE POLICY "subscription_daily_orders_update_policy" ON public.subscription_daily_orders FOR UPDATE TO public USING (is_super_admin() OR has_permission('daily_ops:edit') OR has_permission('subscriptions:edit')) WITH CHECK (is_super_admin() OR has_permission('daily_ops:edit') OR has_permission('subscriptions:edit'));
CREATE POLICY "subscription_daily_orders_view_policy" ON public.subscription_daily_orders FOR SELECT TO public USING ((user_id = auth.uid()) OR is_super_admin() OR has_permission('daily_ops:view') OR has_permission('daily_ops:edit') OR has_permission('subscriptions:view') OR has_permission('subscriptions:edit'));

-- subscription_items ---------------------------------------------------------
CREATE POLICY "Users can read own subscription items" ON public.subscription_items FOR SELECT TO public USING (EXISTS (SELECT 1 FROM subscriptions WHERE subscriptions.id = subscription_items.subscription_id AND subscriptions.user_id = auth.uid()));
CREATE POLICY "subscription_items_delete_policy" ON public.subscription_items FOR DELETE TO public USING (EXISTS (SELECT 1 FROM subscriptions s WHERE s.id = subscription_items.subscription_id AND (is_super_admin() OR has_permission('subscriptions:edit'))));
CREATE POLICY "subscription_items_insert_policy" ON public.subscription_items FOR INSERT TO public WITH CHECK (EXISTS (SELECT 1 FROM subscriptions s WHERE s.id = subscription_items.subscription_id AND ((s.user_id = auth.uid()) OR is_super_admin() OR has_permission('subscriptions:edit'))));
CREATE POLICY "subscription_items_update_policy" ON public.subscription_items FOR UPDATE TO public USING (EXISTS (SELECT 1 FROM subscriptions s WHERE s.id = subscription_items.subscription_id AND ((s.user_id = auth.uid()) OR is_super_admin() OR has_permission('subscriptions:edit')))) WITH CHECK (EXISTS (SELECT 1 FROM subscriptions s WHERE s.id = subscription_items.subscription_id AND ((s.user_id = auth.uid()) OR is_super_admin() OR has_permission('subscriptions:edit'))));
CREATE POLICY "subscription_items_view_policy" ON public.subscription_items FOR SELECT TO public USING (EXISTS (SELECT 1 FROM subscriptions s WHERE s.id = subscription_items.subscription_id AND ((s.user_id = auth.uid()) OR is_super_admin() OR has_permission('subscriptions:view') OR has_permission('subscriptions:edit'))));

-- subscription_pauses --------------------------------------------------------
CREATE POLICY "Users can insert own subscription pauses" ON public.subscription_pauses FOR INSERT TO public WITH CHECK (EXISTS (SELECT 1 FROM subscriptions WHERE subscriptions.id = subscription_pauses.subscription_id AND subscriptions.user_id = auth.uid() AND subscriptions.status = 'active'));
CREATE POLICY "Users can read own subscription pauses" ON public.subscription_pauses FOR SELECT TO public USING (EXISTS (SELECT 1 FROM subscriptions WHERE subscriptions.id = subscription_pauses.subscription_id AND subscriptions.user_id = auth.uid()));
CREATE POLICY "subscription_pauses_delete_policy" ON public.subscription_pauses FOR DELETE TO public USING (EXISTS (SELECT 1 FROM subscriptions s WHERE s.id = subscription_pauses.subscription_id AND (is_super_admin() OR has_permission('subscriptions:edit'))));
CREATE POLICY "subscription_pauses_insert_policy" ON public.subscription_pauses FOR INSERT TO public WITH CHECK (EXISTS (SELECT 1 FROM subscriptions s WHERE s.id = subscription_pauses.subscription_id AND ((s.user_id = auth.uid()) OR is_super_admin() OR has_permission('subscriptions:edit'))));
CREATE POLICY "subscription_pauses_view_policy" ON public.subscription_pauses FOR SELECT TO public USING (EXISTS (SELECT 1 FROM subscriptions s WHERE s.id = subscription_pauses.subscription_id AND ((s.user_id = auth.uid()) OR is_super_admin() OR has_permission('subscriptions:view') OR has_permission('subscriptions:edit'))));

-- subscriptions --------------------------------------------------------------
CREATE POLICY "Users can read own subscriptions" ON public.subscriptions FOR SELECT TO public USING (auth.uid() = user_id);
CREATE POLICY "subscriptions_create_policy" ON public.subscriptions FOR INSERT TO public WITH CHECK ((user_id = auth.uid()) OR is_super_admin() OR has_permission('subscriptions:edit'));
CREATE POLICY "subscriptions_delete_policy" ON public.subscriptions FOR DELETE TO public USING (is_super_admin() OR has_permission('subscriptions:edit'));
CREATE POLICY "subscriptions_update_policy" ON public.subscriptions FOR UPDATE TO public USING ((user_id = auth.uid()) OR is_super_admin() OR has_permission('subscriptions:edit')) WITH CHECK ((user_id = auth.uid()) OR is_super_admin() OR has_permission('subscriptions:edit'));
CREATE POLICY "subscriptions_view_policy" ON public.subscriptions FOR SELECT TO public USING ((user_id = auth.uid()) OR is_super_admin() OR has_permission('subscriptions:view') OR has_permission('subscriptions:edit'));

-- users ----------------------------------------------------------------------
CREATE POLICY "Enable insert for users based on user_id" ON public.users FOR INSERT TO authenticated WITH CHECK ((auth.uid() = id) OR is_super_admin() OR has_permission('customers:edit'));
CREATE POLICY "user info delete" ON public.users FOR DELETE TO authenticated USING (auth.uid() = id);
CREATE POLICY "user info update" ON public.users FOR UPDATE TO authenticated USING (auth.uid() = id) WITH CHECK (auth.uid() = id);
CREATE POLICY "users_delete_policy" ON public.users FOR DELETE TO public USING ((id = auth.uid()) OR is_super_admin() OR has_permission('customers:edit'));
CREATE POLICY "users_update_policy" ON public.users FOR UPDATE TO public USING ((id = auth.uid()) OR is_super_admin() OR has_permission('customers:edit')) WITH CHECK ((id = auth.uid()) OR is_super_admin() OR has_permission('customers:edit'));
CREATE POLICY "users_view_policy" ON public.users FOR SELECT TO public USING ((id = auth.uid()) OR is_super_admin() OR has_permission('customers:view') OR has_permission('customers:edit'));

-- wallet_transactions --------------------------------------------------------
CREATE POLICY "Users can read own wallet transactions" ON public.wallet_transactions FOR SELECT TO public USING (auth.uid() = user_id);
CREATE POLICY "wallet_transactions_insert_policy" ON public.wallet_transactions FOR INSERT TO public WITH CHECK (is_super_admin() OR has_permission('customers:edit'));
CREATE POLICY "wallet_transactions_view_policy" ON public.wallet_transactions FOR SELECT TO public USING ((user_id = auth.uid()) OR is_super_admin() OR has_permission('customers:view') OR has_permission('customers:edit'));
