-- =============================================================================
-- Migration 010 — EXECUTE GRANT HARDENING
-- =============================================================================
-- Run in: Supabase SQL Editor, AFTER 009_privilege_lockdown.sql.
--
-- WHY
--   Supabase ships the project with
--     ALTER DEFAULT PRIVILEGES IN SCHEMA public
--       GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;
--   so every function created in `public` gets an EXPLICIT grant to those three
--   roles. 009's `REVOKE ALL ... FROM PUBLIC` only drops the implicit PUBLIC
--   grant, which left this true after deployment:
--     has_function_privilege('anon', 'public.place_order(...)', 'EXECUTE')            → true
--     has_function_privilege('authenticated', 'public.create_payment_intent(...)')    → true
--
--   Neither was exploitable — place_order raises for an anonymous caller
--   (auth.uid() is null and it is not an admin), and the payment-intent functions
--   raise unless internal.is_service_actor(). This migration removes the grants
--   anyway so the privilege surface matches the intent.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Customer-callable, but never anonymous
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.place_order(uuid, uuid, text, numeric, jsonb) FROM anon;
REVOKE ALL ON FUNCTION public.create_subscription(uuid, timestamptz, timestamptz, text, jsonb, jsonb) FROM anon;
REVOKE ALL ON FUNCTION public.create_subscription(uuid, timestamptz, timestamptz, text, jsonb, jsonb, text) FROM anon;
REVOKE ALL ON FUNCTION public.upsert_pauses(uuid, jsonb) FROM anon;
REVOKE ALL ON FUNCTION public.remove_paused_dates(uuid, jsonb) FROM anon;
REVOKE ALL ON FUNCTION public.claim_adhoc_user(uuid, text, text, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.cancel_subscription(uuid, uuid, timestamptz, boolean, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.update_address_as_default(uuid, uuid, jsonb) FROM anon;
REVOKE ALL ON FUNCTION public.get_user_daily_commitment(uuid) FROM anon;

-- ---------------------------------------------------------------------------
-- Staff-only
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.update_wallet_balance(uuid, numeric, text, text, text, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.finalize_daily_run(date, uuid) FROM anon;

-- ---------------------------------------------------------------------------
-- Service-role only (edge functions)
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.create_payment_intent(uuid, text, bigint, uuid, jsonb) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.attach_razorpay_order(uuid, text)                      FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.finalize_wallet_topup(uuid, text, text, bigint)        FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.finalize_order_payment(uuid, text, text, bigint)       FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.mark_payment_intent_failed(uuid)                       FROM anon, authenticated;

-- `quote_cart` stays callable by anon/authenticated on purpose: it is read-only
-- and only returns catalog-derived numbers (used to render the cart total).

-- ---------------------------------------------------------------------------
-- Belt and braces: the internal schema must stay unreachable
-- ---------------------------------------------------------------------------
REVOKE ALL ON SCHEMA internal FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA internal FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Verification — every column below must be false
-- ---------------------------------------------------------------------------
-- SELECT
--   has_function_privilege('anon','public.place_order(uuid,uuid,text,numeric,jsonb)','EXECUTE')                  AS anon_place_order,
--   has_function_privilege('anon','public.update_wallet_balance(uuid,numeric,text,text,text,text,text)','EXECUTE') AS anon_wallet,
--   has_function_privilege('authenticated','public.create_payment_intent(uuid,text,bigint,uuid,jsonb)','EXECUTE') AS cust_intent,
--   has_function_privilege('authenticated','public.finalize_order_payment(uuid,text,text,bigint)','EXECUTE')      AS cust_settle,
--   has_schema_privilege('authenticated','internal','USAGE')                                                     AS cust_internal,
--   has_table_privilege('authenticated','public.payment_intents','SELECT')                                       AS cust_intents_table;
