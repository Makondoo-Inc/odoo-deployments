#!/bin/bash
# baremetal/uninstall.sh - remove what install.sh set up for one project.
# Stops and removes the service, timer, config, logrotate, helpers, nginx site
# and sysctl file. Keeps packages. Data is only removed with explicit flags.
#
# Usage: sudo ./uninstall.sh --config site.env [--drop-db] [--remove-data] [--remove-source]
#
# Copyright (C) 2025-2026 Makondoo Inc. Licence: AGPL-3.0-or-later
set -uo pipefail
CONFIG_FILE=""; DROP_DB=false; REMOVE_DATA=false; REMOVE_SOURCE=false
while [ $# -gt 0 ]; do
    case "$1" in
        --config|-c) CONFIG_FILE=$2; shift 2 ;;
        --drop-db) DROP_DB=true; shift ;;
        --remove-data) REMOVE_DATA=true; shift ;;
        --remove-source) REMOVE_SOURCE=true; shift ;;
        -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
# shellcheck source=/dev/null
[ -n "$CONFIG_FILE" ] && source "$CONFIG_FILE"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
PROJECT=${PROJECT:-odoo}; PROJECT=$(echo "$PROJECT" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g'); SERVICE=${SERVICE:-$PROJECT}
ODOO_VERSION=${ODOO_VERSION:-19}; ODOO_SRC=${ODOO_SRC:-/opt/odoo${ODOO_VERSION}/odoo}; VENV=${VENV:-/opt/odoo${ODOO_VERSION}/venv}
DATA_DIR=${DATA_DIR:-/var/lib/odoo}; LOG_DIR=${LOG_DIR:-/var/log/odoo}; DB_NAME=${DB_NAME:-$PROJECT}; PG_VERSION=${PG_VERSION:-18}

echo "== stopping ${SERVICE}"
systemctl disable --now "${SERVICE}" 2>/dev/null; systemctl disable --now "${SERVICE}-backup.timer" 2>/dev/null
rm -f "/etc/systemd/system/${SERVICE}.service" "/etc/systemd/system/${SERVICE}-backup.service" "/etc/systemd/system/${SERVICE}-backup.timer"
systemctl daemon-reload
echo "== removing config, helpers, logrotate, sysctl"
rm -f "/etc/odoo/${SERVICE}.conf" "/etc/logrotate.d/${SERVICE}" "/usr/local/sbin/${SERVICE}-backup" "/usr/local/sbin/${SERVICE}-update" "/etc/sysctl.d/90-${SERVICE}.conf"
rm -f "/etc/postgresql/${PG_VERSION}/main/conf.d/90-odoo.conf"
if [ -f "/etc/nginx/sites-available/${SERVICE}" ]; then
    echo "== removing nginx site"
    rm -f "/etc/nginx/sites-enabled/${SERVICE}" "/etc/nginx/sites-enabled/${SERVICE}-tls" "/etc/nginx/sites-available/${SERVICE}" "/etc/nginx/sites-available/${SERVICE}-tls" "/etc/nginx/snippets/${SERVICE}-common.conf"
    rm -rf "/var/cache/nginx/${SERVICE}"
    nginx -t 2>/dev/null && systemctl reload nginx
fi
if [ "$DROP_DB" = true ]; then
    echo "== dropping database ${DB_NAME}"
    PG_PORT=$(pg_lsclusters -h 2>/dev/null | awk -v v="$PG_VERSION" '$1==v && $2=="main"{print $3}'); runuser -u postgres -- dropdb -p "${PG_PORT:-5432}" --if-exists "$DB_NAME"
    systemctl restart postgresql 2>/dev/null
fi
if [ "$REMOVE_DATA" = true ]; then
    echo "== removing ${DATA_DIR}/filestore/${DB_NAME} and ${LOG_DIR}"
    rm -rf "${DATA_DIR}/filestore/${DB_NAME}" "${DATA_DIR}/sessions" "$LOG_DIR"
fi
if [ "$REMOVE_SOURCE" = true ]; then
    echo "== removing ${ODOO_SRC} and ${VENV}"
    rm -rf "$ODOO_SRC" "$VENV"
fi
echo "done. Packages (postgresql, nginx, wkhtmltopdf) and the '${ODOO_USER:-odoo}' user were left in place."
