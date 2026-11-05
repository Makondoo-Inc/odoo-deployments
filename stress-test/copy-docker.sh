#!/bin/bash
# Make a NEUTRALISED throwaway copy of an Odoo database in a Docker Compose
# stack, verify it cannot reach the outside world, and build prep.json.
#
# Usage (from the compose project directory):
#   SRC_DB=production DST_DB=loadtest ./copy-docker.sh
# Settings:
#   SRC_DB        database to copy (required)
#   DST_DB        name of the copy (required; must not exist unless REPLACE=true)
#   DB_SERVICE    compose service running PostgreSQL (default db)
#   ODOO_SERVICE  compose service running Odoo (default odoo)
#   DB_USER       PostgreSQL user (default odoo)
#   FILESTORE     filestore root inside the Odoo container (default /var/lib/odoo/filestore)
#   STRESS_PASSWORD  password set on every internal user of the copy (default loadtest)
#   KEEP_CRONS    comma-separated cron xml ids to re-enable, e.g. "sale.send_pending_emails_cron,event.event_mail_scheduler"
#   PREP_OUT      where to write prep.json on the host (default ./prep.json)
#
# The copy keeps the filestore of the source so attachments and assets work.
# Nothing is changed in SRC_DB.
#
# Copyright (C) 2025-2026 Makondoo Inc. Licence: AGPL-3.0-or-later
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
: "${SRC_DB:?SRC_DB is required}"; : "${DST_DB:?DST_DB is required}"
DB_SERVICE=${DB_SERVICE:-db}; ODOO_SERVICE=${ODOO_SERVICE:-odoo}; DB_USER=${DB_USER:-odoo}
FILESTORE=${FILESTORE:-/var/lib/odoo/filestore}; STRESS_PASSWORD=${STRESS_PASSWORD:-loadtest}
PREP_OUT=${PREP_OUT:-./prep.json}; REPLACE=${REPLACE:-false}
[ "$SRC_DB" != "$DST_DB" ] || { echo "SRC_DB and DST_DB must differ"; exit 1; }
psql_() { docker compose exec -T "$DB_SERVICE" psql -X -q -U "$DB_USER" "$@"; }

echo "== 1. copy database ${SRC_DB} -> ${DST_DB}"
if psql_ -d postgres -tAc "select 1 from pg_database where datname='${DST_DB}'" | grep -q 1; then
    [ "$REPLACE" = true ] || { echo "${DST_DB} exists (set REPLACE=true to drop it)"; exit 1; }
    psql_ -d postgres -c "drop database \"${DST_DB}\""
fi
psql_ -d postgres -c "create database \"${DST_DB}\" owner \"${DB_USER}\""
# Odoo marks unaccent(text) IMMUTABLE at database creation so it can index with
# it; pg_dump does not carry that over, and every unaccent index would fail.
psql_ -d "$DST_DB" -c "create extension if not exists pg_trgm; create extension if not exists unaccent; alter function unaccent(text) immutable" 2>/dev/null || echo "(no unaccent extension available; unaccent indexes will be skipped)"
docker compose exec -T "$DB_SERVICE" sh -c "pg_dump -U '${DB_USER}' -Fc '${SRC_DB}' | pg_restore -U '${DB_USER}' -d '${DST_DB}' --no-owner --role='${DB_USER}'" 2>&1 | tail -1

echo "== 2. copy filestore"
docker compose exec -T "$ODOO_SERVICE" sh -c "rm -rf '${FILESTORE}/${DST_DB}' && cp -a '${FILESTORE}/${SRC_DB}' '${FILESTORE}/${DST_DB}'" || echo "WARNING: filestore copy failed (no attachments in the copy)"

echo "== 3. odoo neutralize"
docker compose exec -T "$ODOO_SERVICE" odoo neutralize -d "$DST_DB" --no-http 2>&1 | tail -2

echo "== 4. extra neutralisation"
psql_ -d "$DST_DB" < "$HERE/neutralize_extra.sql"
if [ -n "${KEEP_CRONS:-}" ]; then
    for xid in ${KEEP_CRONS//,/ }; do
        mod=${xid%%.*}; name=${xid#*.}
        psql_ -d "$DST_DB" -c "update ir_cron set active=true where id=(select res_id from ir_model_data where model='ir.cron' and module='${mod}' and name='${name}')"
    done
fi

echo "== 5. verify"
psql_ -d "$DST_DB" -tA -F' ' < "$HERE/verify_neutralized.sql" | tee /dev/stderr | grep -q FAIL && { echo "NOT SAFE: fix the FAIL rows before testing"; exit 1; }

echo "== 6. prep.json"
docker compose exec -T -e STRESS_DB="$DST_DB" -e STRESS_PASSWORD="$STRESS_PASSWORD" "$ODOO_SERVICE" \
    odoo shell -d "$DST_DB" --no-http --logfile= --log-level=error < "$HERE/prep.py" 2>/dev/null | grep '^PREPJSON' | sed 's/^PREPJSON//' > "$PREP_OUT"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(f\"prep.json: {len(d['users'])} users, {len(d['pos'])} tills, {len(d['sale_products'])} sale products, {len(d['partners'])} partners\")" "$PREP_OUT"
echo "copy ready: ${DST_DB} (password for every internal user: ${STRESS_PASSWORD})"
echo "when done: docker compose exec -T ${DB_SERVICE} dropdb -U ${DB_USER} ${DST_DB}; docker compose exec -T ${ODOO_SERVICE} rm -rf ${FILESTORE}/${DST_DB}"
