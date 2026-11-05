#!/bin/bash
# Make a NEUTRALISED throwaway copy of an Odoo database on a bare-metal host
# (PostgreSQL + Odoo installed on the machine), verify it, build prep.json.
#
# Usage (as root or with sudo):
#   SRC_DB=production DST_DB=loadtest ODOO_BIN=/opt/odoo/odoo-bin ODOO_CONF=/etc/odoo/odoo.conf ./copy-baremetal.sh
# Settings:
#   SRC_DB, DST_DB   source database and name of the copy (required)
#   ODOO_BIN         path to odoo-bin (required)
#   ODOO_CONF        Odoo config file to use for neutralize/shell (required)
#   PYTHON           interpreter for odoo-bin (default: the venv next to ODOO_BIN, else python3)
#   ODOO_USER        system user Odoo runs as (default odoo)
#   DATA_DIR         Odoo data_dir holding filestore/ (default: data_dir from ODOO_CONF)
#   DB_USER          PostgreSQL role owning the databases (default odoo)
#   STRESS_PASSWORD  password set on every internal user of the copy (default loadtest)
#   KEEP_CRONS       comma-separated cron xml ids to re-enable
#   PREP_OUT         where to write prep.json (default ./prep.json)
#
# Copyright (C) 2025-2026 Makondoo Inc. Licence: AGPL-3.0-or-later
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
: "${SRC_DB:?}"; : "${DST_DB:?}"; : "${ODOO_BIN:?}"; : "${ODOO_CONF:?}"
ODOO_USER=${ODOO_USER:-odoo}; DB_USER=${DB_USER:-odoo}; STRESS_PASSWORD=${STRESS_PASSWORD:-loadtest}
PREP_OUT=${PREP_OUT:-./prep.json}; REPLACE=${REPLACE:-false}
[ "$SRC_DB" != "$DST_DB" ] || { echo "SRC_DB and DST_DB must differ"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }
if [ -z "${PYTHON:-}" ]; then
    venv=$(dirname "$(dirname "$ODOO_BIN")")/venv/bin/python
    [ -x "$venv" ] && PYTHON=$venv || PYTHON=python3
fi
DATA_DIR=${DATA_DIR:-$(grep -E '^\s*data_dir' "$ODOO_CONF" | head -1 | cut -d= -f2 | tr -d ' ')}
psql_() { runuser -u postgres -- psql -X -q "$@"; }
odoo_() { runuser -u "$ODOO_USER" -- "$PYTHON" "$ODOO_BIN" -c "$ODOO_CONF" --no-http --logfile= "$@"; }

echo "== 1. copy database ${SRC_DB} -> ${DST_DB}"
if psql_ -d postgres -tAc "select 1 from pg_database where datname='${DST_DB}'" | grep -q 1; then
    [ "$REPLACE" = true ] || { echo "${DST_DB} exists (set REPLACE=true to drop it)"; exit 1; }
    psql_ -d postgres -c "drop database \"${DST_DB}\""
fi
psql_ -d postgres -c "create database \"${DST_DB}\" owner \"${DB_USER}\""
# Odoo marks unaccent(text) IMMUTABLE at database creation so it can index with
# it; pg_dump does not carry that over, and every unaccent index would fail.
psql_ -d "$DST_DB" -c "create extension if not exists pg_trgm; create extension if not exists unaccent; alter function unaccent(text) immutable" 2>/dev/null || echo "(no unaccent extension available; unaccent indexes will be skipped)"
runuser -u postgres -- sh -c "pg_dump -Fc '${SRC_DB}' | pg_restore -d '${DST_DB}' --no-owner --role='${DB_USER}'" 2>&1 | tail -1

echo "== 2. copy filestore"
if [ -n "$DATA_DIR" ] && [ -d "$DATA_DIR/filestore/$SRC_DB" ]; then
    rm -rf "$DATA_DIR/filestore/$DST_DB"; cp -a "$DATA_DIR/filestore/$SRC_DB" "$DATA_DIR/filestore/$DST_DB"; chown -R "$ODOO_USER": "$DATA_DIR/filestore/$DST_DB"
else echo "WARNING: no filestore found for ${SRC_DB} under ${DATA_DIR:-?}/filestore"; fi

echo "== 3. odoo neutralize"
odoo_ neutralize -d "$DST_DB" 2>&1 | tail -2

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
STRESS_DB="$DST_DB" STRESS_PASSWORD="$STRESS_PASSWORD" odoo_ shell -d "$DST_DB" --log-level=error < "$HERE/prep.py" 2>/dev/null | grep '^PREPJSON' | sed 's/^PREPJSON//' > "$PREP_OUT"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(f\"prep.json: {len(d['users'])} users, {len(d['pos'])} tills, {len(d['sale_products'])} sale products, {len(d['partners'])} partners\")" "$PREP_OUT"
echo "copy ready: ${DST_DB} (password for every internal user: ${STRESS_PASSWORD})"
echo "when done: sudo -u postgres dropdb ${DST_DB}; rm -rf ${DATA_DIR}/filestore/${DST_DB}"
