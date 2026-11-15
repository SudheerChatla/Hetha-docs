-- Wallet low-balance reminder: the scheduler tick (task W-08e, owner step O-07)
--
-- NOT a numbered migration. It holds an environment-specific URL and secret,
-- so run it ONCE PER ENVIRONMENT (production now; staging when it exists) in
-- that project's Supabase SQL Editor, after migration 039 is applied and the
-- admin panel with /api/cron/wallet-reminder is deployed.
--
-- What it does: every 10 minutes, all day, it POSTs to the admin panel's
-- /api/cron/wallet-reminder. The DATABASE decides whether it is reminder time
-- (public.wallet_reminder_settings, changed in Admin → Settings →
-- Wallet & Notifications) and who is due. The schedule below is only the
-- tick; it is NOT the reminder time and must not be changed to one.
--
-- Before running:
--   1. In Vercel (Hetha_admin → Settings → Environment Variables) add
--      CRON_SECRET = a long random string (32+ characters), then redeploy.
--      Use a different value for each environment.
--   2. In Supabase → Database → Extensions, make sure pg_cron and pg_net are
--      enabled. Vault is available on every Supabase project.
--   3. Replace the two placeholders below (keep the quotes).
--
-- Checked against the Supabase pattern for calling an HTTP endpoint from
-- pg_cron (pg_net net.http_post with named arguments; secrets read from
-- vault.decrypted_secrets; vault.create_secret(secret, name)). Not run by
-- Claude: the owner runs it.
--
-- To change the URL or secret later:
--   SELECT vault.update_secret(
--     (SELECT id FROM vault.secrets WHERE name = 'wallet_reminder_cron_secret'),
--     '<NEW_CRON_SECRET>');
-- To check:   SELECT * FROM cron.job WHERE jobname = 'wallet-reminder-tick';
--             SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 20;
--             SELECT * FROM net._http_response ORDER BY created DESC LIMIT 20;
-- To stop:    SELECT cron.unschedule('wallet-reminder-tick');

-- 1. Store the endpoint and the shared secret in Supabase Vault (once).
--    <ADMIN_BASE_URL>  e.g. https://your-admin.vercel.app   (no trailing slash)
--    <CRON_SECRET>     the same value as the CRON_SECRET env var in Vercel
SELECT vault.create_secret('<ADMIN_BASE_URL>', 'wallet_reminder_base_url');
SELECT vault.create_secret('<CRON_SECRET>',    'wallet_reminder_cron_secret');

-- 2. Schedule the tick. Every 10 minutes, all day.
SELECT cron.schedule(
  'wallet-reminder-tick',
  '*/10 * * * *',
  $$
  SELECT net.http_post(
    url     := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'wallet_reminder_base_url')
               || '/api/cron/wallet-reminder',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' ||
                   (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'wallet_reminder_cron_secret')),
    body    := '{}'::jsonb,
    timeout_milliseconds := 55000
  );
  $$
);
