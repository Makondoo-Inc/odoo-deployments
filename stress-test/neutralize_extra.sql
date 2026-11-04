-- Extra neutralisation on top of `odoo neutralize`, for a load-test copy.
-- Idempotent. Run as the Odoo database user on the COPY only.
--
-- odoo neutralize already: deactivates outgoing/incoming mail servers and
-- replaces them with a dummy, disables every cron, sets payment providers to
-- test mode, deactivates IAP/SMS services it knows about. This adds what it
-- leaves alone and what custom modules add.
--
-- Copyright (C) 2025-2026 Makondoo Inc. Licence: AGPL-3.0-or-later

DO $$
BEGIN
    -- only the demo provider may stay enabled (test mode): nothing else can
    -- talk to a real payment or mobile-money service
    IF to_regclass('payment_provider') IS NOT NULL THEN
        UPDATE payment_provider SET state = 'disabled', is_published = false WHERE code <> 'demo';
        UPDATE payment_provider SET state = 'test', is_published = true WHERE code = 'demo';
    END IF;
    -- IAP tokens (SMS, snailmail, OCR, ...): make them unusable
    IF to_regclass('iap_account') IS NOT NULL THEN
        UPDATE iap_account SET account_token = 'neutralized';
    END IF;
    -- WhatsApp accounts (Enterprise)
    IF to_regclass('whatsapp_account') IS NOT NULL THEN
        UPDATE whatsapp_account SET active = false;
    END IF;
    -- SMS/email marketing cannot send without providers, but keep campaigns from "running"
    IF to_regclass('mailing_mailing') IS NOT NULL THEN
        UPDATE mailing_mailing SET state = 'draft' WHERE state IN ('in_queue', 'sending');
    END IF;
    -- webhooks/automations that call out
    IF to_regclass('base_automation') IS NOT NULL THEN
        UPDATE base_automation SET active = false WHERE trigger = 'on_webhook' OR url IS NOT NULL;
    END IF;
    -- Kenyan eTIMS/TIMS and similar fiscal integrations: switch off where the columns exist
    IF to_regclass('res_company') IS NOT NULL THEN
        IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'res_company' AND column_name = 'l10n_ke_server_mode') THEN
            UPDATE res_company SET l10n_ke_server_mode = 'demo';
        END IF;
        IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'res_company' AND column_name = 'l10n_ke_tims_active') THEN
            UPDATE res_company SET l10n_ke_tims_active = false;
        END IF;
    END IF;
    -- the copy must never be mistaken for production
    UPDATE ir_config_parameter SET value = 'http://localhost:8069' WHERE key = 'web.base.url';
    DELETE FROM ir_config_parameter WHERE key = 'web.base.url.freeze';
END $$;
