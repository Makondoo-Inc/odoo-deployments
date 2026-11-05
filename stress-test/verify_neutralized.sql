-- Prove the copy cannot reach the outside world before any load is applied.
-- Every row must read OK (WARN is allowed); the copy scripts stop on FAIL.
-- plpgsql with dynamic SQL so that optional tables (WhatsApp, IAP, payment)
-- are only touched when they exist.
--
-- Copyright (C) 2025-2026 Makondoo Inc. Licence: AGPL-3.0-or-later
CREATE OR REPLACE FUNCTION pg_temp.stress_verify() RETURNS TABLE(check_name text, result text)
LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
    SELECT count(*) INTO n FROM ir_config_parameter WHERE key = 'database.is_neutralized' AND value = 'true';
    RETURN QUERY SELECT 'neutralized flag'::text, CASE WHEN n = 1 THEN 'OK' ELSE 'FAIL: database.is_neutralized is not true' END;

    SELECT count(*) INTO n FROM ir_mail_server WHERE active AND smtp_host NOT IN ('invalid', 'localhost', '127.0.0.1');
    RETURN QUERY SELECT 'outgoing mail servers'::text, CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL: a real SMTP server is still active' END;

    IF to_regclass('fetchmail_server') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FROM fetchmail_server WHERE active' INTO n;
        RETURN QUERY SELECT 'incoming mail servers'::text, CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL: an incoming mail server is active' END;
    END IF;

    IF to_regclass('payment_provider') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FROM payment_provider WHERE state <> ''disabled'' AND code <> ''demo''' INTO n;
        RETURN QUERY SELECT 'payment providers'::text, CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL: a non-demo payment provider is enabled' END;
    END IF;

    -- odoo neutralize leaves the harmless autovacuum job on; anything else must be deliberate (KEEP_CRONS)
    SELECT count(*) INTO n FROM ir_cron c WHERE c.active AND c.id NOT IN (SELECT res_id FROM ir_model_data WHERE model = 'ir.cron' AND module = 'base' AND name = 'autovacuum_job');
    RETURN QUERY SELECT 'scheduled actions'::text, CASE WHEN n = 0 THEN 'OK' ELSE 'WARN: ' || n || ' cron(s) active besides autovacuum (re-enabled on purpose?)' END;

    IF to_regclass('iap_account') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FROM iap_account WHERE account_token IS NOT NULL AND account_token <> ''neutralized''' INTO n;
        RETURN QUERY SELECT 'iap tokens'::text, CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL: live IAP token present' END;
    END IF;

    IF to_regclass('whatsapp_account') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FROM whatsapp_account WHERE active' INTO n;
        RETURN QUERY SELECT 'whatsapp accounts'::text, CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL: WhatsApp account active' END;
    END IF;

    SELECT count(*) INTO n FROM ir_config_parameter WHERE key = 'web.base.url' AND value LIKE 'http://localhost%';
    RETURN QUERY SELECT 'web.base.url'::text, CASE WHEN n = 1 THEN 'OK' ELSE 'WARN: web.base.url still points at the real site' END;
END $$;
SELECT * FROM pg_temp.stress_verify();
