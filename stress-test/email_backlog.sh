#!/bin/bash
# Log the email backlog of the copy every 30 s during a run: order
# confirmations waiting for the sale cron, mails waiting in the outgoing queue,
# ticket mails not yet sent. Useful to see whether emails keep up with sales.
#
# Usage:  PSQL="docker compose exec -T db psql -U odoo -d loadtest" ./email_backlog.sh > results/email_backlog.log
#         PSQL="sudo -u postgres psql -d loadtest" ./email_backlog.sh
#
# Copyright (C) 2025-2026 Makondoo Inc. Licence: AGPL-3.0-or-later
: "${PSQL:?set PSQL to a psql command for the copy}"
q() { $PSQL -X -q -t -A -c "$1" 2>/dev/null | tr -d '[:space:]'; }
while true; do
    echo "$(date +%T) pending_sale_emails=$(q "select count(*) from sale_order where pending_email_template_id is not null") mail_outgoing=$(q "select count(*) from mail_mail where state='outgoing'") mail_exception=$(q "select count(*) from mail_mail where state='exception'") tickets_unsent=$(q "select coalesce(count(*),0) from event_mail_registration where not mail_sent") orders_confirmed=$(q "select count(*) from sale_order where state='sale'")"
    sleep 30
done
