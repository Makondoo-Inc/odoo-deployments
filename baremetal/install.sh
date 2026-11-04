#!/bin/bash
# baremetal/install.sh - Odoo on the host: venv + systemd + PostgreSQL + nginx,
# sized by lib/tuning.sh. Debian/Ubuntu. Idempotent: re-run to apply changes.
#
# Copyright (C) 2025-2026 Makondoo Inc.
# Licence: AGPL-3.0-or-later
#
# Usage:
#   sudo ./install.sh --config site.env            install or update
#   sudo ./install.sh --config site.env --dry-run  show the plan, change nothing
#   ./install.sh --help
# Settings: see deploy.env.example (environment variables with the same names
# also work).
#
# What it does, in order: packages, wkhtmltopdf, Odoo source + venv, system
# user and directories, kernel settings (huge pages sized to shared_buffers,
# limits), PostgreSQL cluster + tuned conf.d file + role + database, odoo.conf,
# systemd unit, logrotate, nightly backup timer, update helper, optional
# database initialisation, nginx site (+ Let's Encrypt when DOMAIN is set),
# start and health check.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/tuning.sh
source "$HERE/../lib/tuning.sh"
log()  { echo -e "\n\033[1;34m== $*\033[0m"; }
warn() { echo -e "\033[1;33mWARNING:\033[0m $*" >&2; }
die()  { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }
tuning_warn() { warn "$1"; }

DRY_RUN=false; CONFIG_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --config|-c) CONFIG_FILE=$2; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done
if [ -n "$CONFIG_FILE" ]; then
    [ -f "$CONFIG_FILE" ] || die "config file not found: $CONFIG_FILE"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# ---------------------------------------------------------------- settings
PROJECT=${PROJECT:-odoo}; PROJECT=$(echo "$PROJECT" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
SERVICE=${SERVICE:-$PROJECT}
ODOO_VERSION=${ODOO_VERSION:-19}; [[ "$ODOO_VERSION" =~ ^(1[6-9]|20)$ ]] || die "ODOO_VERSION must be 16..20"
ODOO_EDITION=${ODOO_EDITION:-community}; [[ "$ODOO_EDITION" =~ ^(community|enterprise)$ ]] || die "ODOO_EDITION must be community or enterprise"
ODOO_SRC=${ODOO_SRC:-/opt/odoo${ODOO_VERSION}/odoo}
VENV=${VENV:-/opt/odoo${ODOO_VERSION}/venv}
ENTERPRISE_SRC=${ENTERPRISE_SRC:-}
CUSTOM_ADDONS=${CUSTOM_ADDONS:-}
DATA_DIR=${DATA_DIR:-/var/lib/odoo}; LOG_DIR=${LOG_DIR:-/var/log/odoo}
BACKUP_DIR=${BACKUP_DIR:-/var/backups/odoo}; BACKUP_KEEP_DAYS=${BACKUP_KEEP_DAYS:-14}
DB_NAME=${DB_NAME:-$PROJECT}; PG_VERSION=${PG_VERSION:-18}; PG_DATA_DIR=${PG_DATA_DIR:-}
HTTP_PORT=${HTTP_PORT:-8069}; GEVENT_PORT=${GEVENT_PORT:-8072}
USE_NGINX=${USE_NGINX:-true}; NGINX_PORT=${NGINX_PORT:-80}; DOMAIN=${DOMAIN:-}
ADMIN_PASSWD=${ADMIN_PASSWD:-}; TIMEZONE=${TIMEZONE:-UTC}; HUGEPAGES=${HUGEPAGES:-auto}
INIT_DB=${INIT_DB:-true}; ODOO_USER=${ODOO_USER:-odoo}
PYTHON_BIN=${PYTHON_BIN:-python3}; PYTHON_FROM_PPA=${PYTHON_FROM_PPA:-true}
# Odoo 16 runs on 3.8+, 17+ needs 3.10+; 19/20 are tested on 3.12
[ "$ODOO_VERSION" -ge 17 ] && PY_MIN="3.10" || PY_MIN="3.8"
CONF_FILE=/etc/odoo/${SERVICE}.conf
[ "$ODOO_EDITION" = enterprise ] && [ ! -d "$ENTERPRISE_SRC/web_enterprise" ] && die "ENTERPRISE_SRC must point at a checkout of the enterprise addons (web_enterprise not found in '${ENTERPRISE_SRC}')"

# addons path: enterprise first (it overrides community), then custom, then community
ADDONS_PATH=""
[ "$ODOO_EDITION" = enterprise ] && ADDONS_PATH="${ENTERPRISE_SRC},"
for d in ${CUSTOM_ADDONS//,/ }; do ADDONS_PATH+="${d},"; done
ADDONS_PATH+="${ODOO_SRC}/addons"

# ---------------------------------------------------------------- plan
odoo_tuning_detect
[ -n "${ODOO_TUNE_CORES:-}" ] && CPU_CORES=$ODOO_TUNE_CORES
[ -n "${ODOO_TUNE_RAM_MB:-}" ] && TOTAL_RAM_MB=$ODOO_TUNE_RAM_MB
# shellcheck disable=SC2034  # read by lib/tuning.sh
NUM_VERSIONS=1
# shellcheck disable=SC2034  # read by lib/tuning.sh
USE_PGBOUNCER=false
odoo_tuning_compute
AUTOVACUUM_WORKERS_MEM=$(( MAINTENANCE_WORK_MEM / 2 )); AUTOVACUUM_WORK_MEM=$AUTOVACUUM_WORKERS_MEM
# the disk under the PostgreSQL data directory decides the planner's cost model
pg_root=${PG_DATA_DIR:-/var/lib/postgresql}; while [ ! -d "$pg_root" ]; do pg_root=$(dirname "$pg_root"); done
PG_DISK_DEV=$(findmnt -no SOURCE --target "$pg_root" 2>/dev/null | sed 's/\[.*\]//' || true); PG_DISK_KIND=unknown; PG_ROTA=""
disk_rota() { # ROTA flag of a block device or of its parent disk; empty when unknown (overlay, network, VM without the flag)
    local dev=$1 r parent
    [[ "$dev" == /dev/* ]] || return 0
    r=$(lsblk -no ROTA "$dev" 2>/dev/null | head -1 | tr -d ' ' || true)
    if [ -z "$r" ]; then parent=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -1 || true); [ -n "$parent" ] && r=$(lsblk -no ROTA "/dev/$parent" 2>/dev/null | head -1 | tr -d ' ' || true); fi
    echo "$r"
}
command -v lsblk >/dev/null && PG_ROTA=$(disk_rota "$PG_DISK_DEV")
if [ "$PG_ROTA" = 1 ]; then PG_DISK_KIND="rotational (HDD)"; RANDOM_PAGE_COST=3.0; IO_CONCURRENCY=4
elif [ "$PG_ROTA" = 0 ]; then PG_DISK_KIND="SSD/NVMe"; RANDOM_PAGE_COST=1.1; IO_CONCURRENCY=200
else RANDOM_PAGE_COST=1.5; IO_CONCURRENCY=64; fi
case "$HUGEPAGES" in
    on) USE_HUGEPAGES=true ;; off) USE_HUGEPAGES=false ;;
    *) [ "$TOTAL_RAM_MB" -ge 8192 ] && USE_HUGEPAGES=true || USE_HUGEPAGES=false ;;
esac
if [ "$USE_HUGEPAGES" = true ]; then
    PG_HUGE_PAGES=try; NR_HUGEPAGES=$(( SHARED_BUFFERS * 107 / 100 / 2 + 50 ))  # 2 MB pages, 7% + 50 headroom
else PG_HUGE_PAGES=off; NR_HUGEPAGES=0; fi
[ "$PG_VERSION" -ge 15 ] && WAL_COMPRESSION=zstd || WAL_COMPRESSION=on
if [ "$PG_VERSION" -ge 18 ]; then PG18_IO=$'# PostgreSQL 18+ asynchronous I/O\nio_method = worker\nio_workers = '"$IO_WORKERS"; else PG18_IO=""; fi
if [ "$USE_NGINX" = true ]; then HTTP_INTERFACE=127.0.0.1; PROXY_MODE=True; else HTTP_INTERFACE=0.0.0.0; PROXY_MODE=False; fi

log "Plan for ${PROJECT}: Odoo ${ODOO_VERSION} ${ODOO_EDITION}, PostgreSQL ${PG_VERSION}, database ${DB_NAME}"
echo "  source ${ODOO_SRC}  venv ${VENV}  data ${DATA_DIR}  logs ${LOG_DIR}  backups ${BACKUP_DIR} (${BACKUP_KEEP_DAYS} days)"
echo "  addons_path ${ADDONS_PATH}"
echo "  http ${HTTP_INTERFACE}:${HTTP_PORT} gevent ${GEVENT_PORT}  nginx=${USE_NGINX} port ${NGINX_PORT} domain '${DOMAIN}'  tz ${TIMEZONE}"
echo "  PostgreSQL data on ${PG_DISK_KIND} -> random_page_cost ${RANDOM_PAGE_COST}; huge pages ${PG_HUGE_PAGES} (${NR_HUGEPAGES} x 2 MB)"
odoo_tuning_print
if [ "$DRY_RUN" = true ]; then echo; echo "dry run: nothing changed"; exit 0; fi

# ---------------------------------------------------------------- preflight
[ "$(id -u)" = 0 ] || die "run with sudo"
command -v apt-get >/dev/null || die "Debian/Ubuntu only for now (apt-get not found)"
export DEBIAN_FRONTEND=noninteractive
# Only the installer's own variables are substituted in templates; a generated
# script's runtime variables (${DB}, ${STAMP}, ...) stay as they are.
TEMPLATE_VARS="PROJECT SERVICE ODOO_VERSION ODOO_EDITION ODOO_SRC VENV DATA_DIR LOG_DIR BACKUP_DIR BACKUP_KEEP_DAYS DB_NAME PG_VERSION PG_PORT
  HTTP_PORT GEVENT_PORT NGINX_PORT DOMAIN TIMEZONE ODOO_USER CONF_FILE ADDONS_PATH HTTP_INTERFACE PROXY_MODE ADMIN_PASSWD GIT_REPOS
  CPU_CORES TOTAL_RAM_MB OPTIMAL_WORKERS MAX_CRON_THREADS SOFT_LIMIT_MB WORKER_MEMORY_MB SOFT_LIMIT_BYTES HARD_LIMIT_BYTES DB_MAXCONN
  MAX_CONNECTIONS SHARED_BUFFERS EFFECTIVE_CACHE_SIZE WORK_MEM MAINTENANCE_WORK_MEM AUTOVACUUM_WORK_MEM MIN_WAL_SIZE MAX_WAL_SIZE
  MAX_WORKER_PROCESSES MAX_PARALLEL_WORKERS MAX_PARALLEL_PER_GATHER MAX_PARALLEL_MAINTENANCE AUTOVACUUM_WORKERS IO_WORKERS
  PG_HUGE_PAGES RANDOM_PAGE_COST IO_CONCURRENCY WAL_COMPRESSION PG18_IO PG_DISK_KIND NGINX_KEEPALIVE HUGEPAGES_LINES HTTP_SERVER_NAMES DEFAULT_SERVER"
render() { # render TEMPLATE DEST MODE [owner:group]
    local vars; vars=$(grep -oE '\$\{[A-Z_0-9]+\}' "$1" | tr -d '${}' | sort -u | grep -xF -f <(printf '%s\n' $TEMPLATE_VARS) | sed 's/^/${/; s/$/}/' | tr '\n' ' ')
    # shellcheck disable=SC2086
    envsubst "$vars" < "$1" > "$2.tmp" && install -m "$3" ${4:+-o ${4%:*} -g ${4#*:}} "$2.tmp" "$2" && rm -f "$2.tmp"
}
export PROJECT SERVICE ODOO_VERSION ODOO_EDITION ODOO_SRC VENV DATA_DIR LOG_DIR BACKUP_DIR BACKUP_KEEP_DAYS DB_NAME PG_VERSION \
       HTTP_PORT GEVENT_PORT NGINX_PORT DOMAIN TIMEZONE ODOO_USER CONF_FILE ADDONS_PATH HTTP_INTERFACE PROXY_MODE \
       CPU_CORES TOTAL_RAM_MB OPTIMAL_WORKERS MAX_CRON_THREADS SOFT_LIMIT_MB WORKER_MEMORY_MB SOFT_LIMIT_BYTES HARD_LIMIT_BYTES DB_MAXCONN \
       MAX_CONNECTIONS SHARED_BUFFERS EFFECTIVE_CACHE_SIZE WORK_MEM MAINTENANCE_WORK_MEM AUTOVACUUM_WORK_MEM MIN_WAL_SIZE MAX_WAL_SIZE \
       MAX_WORKER_PROCESSES MAX_PARALLEL_WORKERS MAX_PARALLEL_PER_GATHER MAX_PARALLEL_MAINTENANCE AUTOVACUUM_WORKERS IO_WORKERS \
       PG_HUGE_PAGES RANDOM_PAGE_COST IO_CONCURRENCY WAL_COMPRESSION PG18_IO PG_DISK_KIND NGINX_KEEPALIVE

py_ok() { "$1" -c "import sys; sys.exit(0 if sys.version_info >= tuple(map(int, '$PY_MIN'.split('.'))) else 1)" 2>/dev/null; }

log "1. packages"
apt-get update -qq
apt-get install -y -qq git curl ca-certificates gnupg lsb-release python3 python3-venv python3-dev build-essential pkg-config \
    libpq-dev libxml2-dev libxslt1-dev zlib1g-dev libjpeg-dev libldap2-dev libsasl2-dev libffi-dev libssl-dev libfreetype-dev libpng-dev \
    fonts-dejavu-core fonts-freefont-ttf fonts-noto-core xfonts-75dpi xfonts-base libxrender1 libxext6 fontconfig gettext-base >/dev/null
if ! apt-cache show "postgresql-${PG_VERSION}" >/dev/null 2>&1; then
    log "1a. PostgreSQL ${PG_VERSION} is not in the distribution: adding the PGDG repository"
    install -d /usr/share/postgresql-common/pgdg
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
    apt-get update -qq
fi
apt-get install -y -qq "postgresql-${PG_VERSION}" "postgresql-contrib-${PG_VERSION}" "postgresql-client-${PG_VERSION}" >/dev/null
[ "$USE_NGINX" = true ] && apt-get install -y -qq nginx >/dev/null
if ! command -v "$PYTHON_BIN" >/dev/null || ! py_ok "$PYTHON_BIN"; then
    if [ "$PYTHON_FROM_PPA" = true ] && [ "$(lsb_release -is)" = Ubuntu ]; then
        log "1c. system Python is older than ${PY_MIN}: installing python3.12 from the deadsnakes PPA"
        apt-get install -y -qq software-properties-common >/dev/null
        add-apt-repository -y ppa:deadsnakes/ppa >/dev/null 2>&1
        apt-get update -qq && apt-get install -y -qq python3.12 python3.12-venv python3.12-dev >/dev/null
        PYTHON_BIN=python3.12
    else
        die "Odoo ${ODOO_VERSION} needs Python >= ${PY_MIN}; '${PYTHON_BIN}' is $("$PYTHON_BIN" --version 2>&1). Set PYTHON_BIN to a newer interpreter"
    fi
fi
echo "  python: $("$PYTHON_BIN" --version)"
if ! command -v wkhtmltopdf >/dev/null; then
    log "1b. wkhtmltopdf 0.12.6.1 (the version Odoo supports; no distro package)"
    arch=$(dpkg --print-architecture); code=$(lsb_release -cs)
    case "$code" in bookworm|jammy|noble|trixie|*) pkg="wkhtmltox_0.12.6.1-3.jammy_${arch}.deb" ;; esac
    [ "$code" = bookworm ] && pkg="wkhtmltox_0.12.6.1-3.bookworm_${arch}.deb"
    (cd /tmp && curl -fsSL -o wkhtmltox.deb "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/${pkg}" \
        && apt-get install -y -qq ./wkhtmltox.deb >/dev/null && rm -f wkhtmltox.deb) || warn "wkhtmltopdf install failed; PDF reports will not render until it is installed"
fi

log "2. system user and directories"
id "$ODOO_USER" >/dev/null 2>&1 || useradd --system --home-dir "$DATA_DIR" --create-home --shell /usr/sbin/nologin "$ODOO_USER"
mkdir -p "$DATA_DIR" "$LOG_DIR" /etc/odoo "$BACKUP_DIR" "$(dirname "$ODOO_SRC")"
chown -R "$ODOO_USER:$ODOO_USER" "$DATA_DIR" "$LOG_DIR"; chmod 750 "$DATA_DIR" "$LOG_DIR"

log "3. Odoo ${ODOO_VERSION} source and virtualenv"
if [ ! -f "$ODOO_SRC/odoo-bin" ]; then
    git clone --depth 1 -b "${ODOO_VERSION}.0" https://github.com/odoo/odoo.git "$ODOO_SRC"
fi
[ -x "$VENV/bin/python" ] || "$PYTHON_BIN" -m venv "$VENV"
py_ok "$VENV/bin/python" || die "the venv at ${VENV} uses $("$VENV/bin/python" --version 2>&1), older than ${PY_MIN}; remove it or set VENV to a new path"
"$VENV/bin/pip" install -q --upgrade pip wheel setuptools
"$VENV/bin/pip" install -q -r "$ODOO_SRC/requirements.txt"
"$VENV/bin/pip" install -q phonenumbers  # phone validation/SMS/WhatsApp; not in requirements.txt
"$VENV/bin/python" -c "import gevent, psycopg2, lxml, werkzeug, PIL, reportlab; print('venv ok:', 'gevent', gevent.__version__, 'psycopg2', psycopg2.__version__)"
# repositories readable by the service user, owned by whoever deploys them
chmod -R o+rX "$(dirname "$ODOO_SRC")" 2>/dev/null || true
for d in ${CUSTOM_ADDONS//,/ } "$ENTERPRISE_SRC"; do [ -n "$d" ] && chmod -R o+rX "$d" 2>/dev/null || true; done

log "4. kernel settings and limits"
if [ "$USE_HUGEPAGES" = true ]; then
    PG_GID=$(getent group postgres | cut -d: -f3)
    HUGEPAGES_LINES=$'vm.nr_hugepages = '"$NR_HUGEPAGES"$'  # shared_buffers / 2 MB pages + headroom\nvm.hugetlb_shm_group = '"$PG_GID"
else HUGEPAGES_LINES="# huge pages off (HUGEPAGES=${HUGEPAGES}, ${TOTAL_RAM_MB} MB RAM)"; fi
export HUGEPAGES_LINES
render "$HERE/templates/sysctl.conf" "/etc/sysctl.d/90-${SERVICE}.conf" 644
sysctl -q --system || true
printf '%s soft nofile 65536\n%s hard nofile 65536\npostgres soft nofile 65536\npostgres hard nofile 65536\npostgres soft memlock unlimited\npostgres hard memlock unlimited\n' "$ODOO_USER" "$ODOO_USER" > /etc/security/limits.d/90-odoo.conf
mkdir -p /etc/systemd/system/postgresql@.service.d
printf '[Service]\nLimitNOFILE=65536\nLimitMEMLOCK=infinity\n' > /etc/systemd/system/postgresql@.service.d/limits.conf

log "5. PostgreSQL ${PG_VERSION}"
if [ -n "$PG_DATA_DIR" ] && [ ! -d "$PG_DATA_DIR/$PG_VERSION/main" ]; then
    systemctl stop postgresql || true
    pg_lsclusters | grep -q "^$PG_VERSION *main" && pg_dropcluster --stop "$PG_VERSION" main
    mkdir -p "$PG_DATA_DIR" && chown postgres:postgres "$PG_DATA_DIR" && chmod 700 "$PG_DATA_DIR"
    pg_createcluster -d "$PG_DATA_DIR/$PG_VERSION/main" --locale C.UTF-8 "$PG_VERSION" main
elif ! pg_lsclusters | grep -q "^$PG_VERSION *main"; then
    pg_createcluster --locale C.UTF-8 "$PG_VERSION" main
fi
render "$HERE/templates/postgresql.conf" "/etc/postgresql/$PG_VERSION/main/conf.d/90-odoo.conf" 640 postgres:postgres
hba="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"
grep -qE "^local +all +${ODOO_USER} +peer" "$hba" || sed -i "1i local   all             ${ODOO_USER}                                    peer" "$hba"
systemctl daemon-reload; systemctl enable --now postgresql >/dev/null; systemctl restart postgresql; sleep 3
PG_PORT=$(pg_lsclusters -h | awk -v v="$PG_VERSION" '$1==v && $2=="main"{print $3}'); PG_PORT=${PG_PORT:-5432}; export PG_PORT
pg_isready -q -p "$PG_PORT" || die "PostgreSQL ${PG_VERSION} did not come up on port ${PG_PORT}; check: journalctl -u postgresql@${PG_VERSION}-main"
[ "$PG_PORT" != 5432 ] && echo "  cluster ${PG_VERSION}/main listens on port ${PG_PORT} (another major version holds 5432); odoo.conf uses it"
pgq() { runuser -u postgres -- psql -p "$PG_PORT" "$@"; }
pgq -tAc "SELECT 1 FROM pg_roles WHERE rolname='${ODOO_USER}'" | grep -q 1 || runuser -u postgres -- createuser -p "$PG_PORT" --createdb "$ODOO_USER"
if ! pgq -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
    runuser -u postgres -- createdb -p "$PG_PORT" -O "$ODOO_USER" -E UTF8 --locale=C.UTF-8 -T template0 "$DB_NAME"
fi
pgq -d "$DB_NAME" -qc "CREATE EXTENSION IF NOT EXISTS unaccent; CREATE EXTENSION IF NOT EXISTS pg_trgm; CREATE EXTENSION IF NOT EXISTS pg_stat_statements; ALTER FUNCTION unaccent(text) IMMUTABLE;"
echo "  shared_buffers=$(pgq -tAc 'SHOW shared_buffers') huge_pages=$(pgq -tAc "SELECT setting FROM pg_settings WHERE name='huge_pages_status'" 2>/dev/null || echo n/a)"

log "6. Odoo configuration, service, logrotate, backup timer, update helper"
if [ -f "$CONF_FILE" ] && [ -z "$ADMIN_PASSWD" ]; then
    ADMIN_PASSWD=$(grep -E '^admin_passwd' "$CONF_FILE" | head -1 | cut -d= -f2- | tr -d ' ')
fi
if [ -z "$ADMIN_PASSWD" ]; then
    ADMIN_PASSWD=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
    echo "  generated master password (admin_passwd); it is in ${CONF_FILE}"
fi
export ADMIN_PASSWD
render "$HERE/templates/odoo.conf" "$CONF_FILE" 640 "root:${ODOO_USER}"
render "$HERE/templates/odoo.service" "/etc/systemd/system/${SERVICE}.service" 644
printf '%s/*.log {\n    daily\n    rotate 30\n    compress\n    delaycompress\n    missingok\n    notifempty\n    copytruncate\n    create 640 %s %s\n}\n' "$LOG_DIR" "$ODOO_USER" "$ODOO_USER" > "/etc/logrotate.d/${SERVICE}"
render "$HERE/templates/backup.sh" "/usr/local/sbin/${SERVICE}-backup" 755
GIT_REPOS="${ODOO_SRC} ${ENTERPRISE_SRC} ${CUSTOM_ADDONS//,/ }"; export GIT_REPOS
render "$HERE/templates/update.sh" "/usr/local/sbin/${SERVICE}-update" 755
printf '[Unit]\nDescription=Odoo nightly backup (%s)\n[Service]\nType=oneshot\nExecStart=/usr/local/sbin/%s-backup\n' "$PROJECT" "$SERVICE" > "/etc/systemd/system/${SERVICE}-backup.service"
printf '[Unit]\nDescription=Run %s backup nightly at 01:30\n[Timer]\nOnCalendar=*-*-* 01:30:00\nPersistent=true\n[Install]\nWantedBy=timers.target\n' "$SERVICE" > "/etc/systemd/system/${SERVICE}-backup.timer"
systemctl daemon-reload
systemctl enable "${SERVICE}-backup.timer" >/dev/null && systemctl start "${SERVICE}-backup.timer"

if [ "$INIT_DB" = true ] && ! pgq -d "$DB_NAME" -tAc "SELECT 1 FROM information_schema.tables WHERE table_name='ir_module_module'" | grep -q 1; then
    log "7. initialising ${DB_NAME} (base, web; no demo data)"
    runuser -u "$ODOO_USER" -- "$VENV/bin/python" "$ODOO_SRC/odoo-bin" -c "$CONF_FILE" -d "$DB_NAME" -i base,web --stop-after-init --no-http --without-demo=all
fi

if [ "$USE_NGINX" = true ]; then
    log "8. nginx"
    mkdir -p /var/www/letsencrypt "/var/cache/nginx/${SERVICE}"; chown www-data:www-data "/var/cache/nginx/${SERVICE}"
    if [ -n "$DOMAIN" ]; then HTTP_SERVER_NAMES="$(hostname) _"; DEFAULT_SERVER=" default_server"; else HTTP_SERVER_NAMES="$(hostname) _"; DEFAULT_SERVER=" default_server"; fi
    export HTTP_SERVER_NAMES DEFAULT_SERVER
    # a second site on the same host must not claim default_server twice
    if grep -rqs "default_server" /etc/nginx/sites-enabled/ --exclude="${SERVICE}" 2>/dev/null; then DEFAULT_SERVER=""; HTTP_SERVER_NAMES="${SERVICE}.local"; export DEFAULT_SERVER HTTP_SERVER_NAMES; warn "another site is default_server; ${SERVICE} answers to Host '${SERVICE}.local' on port ${NGINX_PORT}"; fi
    render "$HERE/templates/nginx-common.conf" "/etc/nginx/snippets/${SERVICE}-common.conf" 644
    render "$HERE/templates/nginx-http.conf" "/etc/nginx/sites-available/${SERVICE}" 644
    ln -sf "/etc/nginx/sites-available/${SERVICE}" "/etc/nginx/sites-enabled/${SERVICE}"
    [ "$NGINX_PORT" = 80 ] && rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl enable --now nginx >/dev/null && systemctl reload nginx
    if [ -n "$DOMAIN" ]; then
        log "8b. https for ${DOMAIN} (Let's Encrypt, webroot)"
        apt-get install -y -qq certbot >/dev/null
        CERT=/etc/letsencrypt/live/$DOMAIN/fullchain.pem
        [ -f "$CERT" ] || certbot certonly --webroot -w /var/www/letsencrypt -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --deploy-hook "systemctl reload nginx" \
            || warn "no certificate for ${DOMAIN} yet (DNS and port 80 must reach this server); https stays off"
        if [ -f "$CERT" ]; then
            render "$HERE/templates/nginx-tls.conf" "/etc/nginx/sites-available/${SERVICE}-tls" 644
            ln -sf "/etc/nginx/sites-available/${SERVICE}-tls" "/etc/nginx/sites-enabled/${SERVICE}-tls"
            nginx -t && systemctl reload nginx
        fi
    fi
fi

log "9. start ${SERVICE}"
systemctl enable "${SERVICE}" >/dev/null; systemctl restart "${SERVICE}"
for _ in $(seq 1 40); do sleep 3; curl -fsS -o /dev/null "http://127.0.0.1:${HTTP_PORT}/web/login" 2>/dev/null && break; done
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HTTP_PORT}/web/login")
[ "$code" = 200 ] || { systemctl --no-pager --lines=20 status "$SERVICE" || true; die "Odoo did not answer on ${HTTP_PORT} (HTTP ${code}); see ${LOG_DIR}/odoo.log"; }
echo "  Odoo answers on 127.0.0.1:${HTTP_PORT} (HTTP ${code})"
[ "$USE_NGINX" = true ] && echo "  via nginx: $(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${HTTP_SERVER_NAMES%% *}" "http://127.0.0.1:${NGINX_PORT}/web/login")"
echo
echo "DONE. Database ${DB_NAME}; first login admin/admin (change it). Config ${CONF_FILE}; logs ${LOG_DIR}/odoo.log;"
echo "nightly backups in ${BACKUP_DIR}; update with: sudo ${SERVICE}-update <modules>; remove with: sudo ${HERE}/uninstall.sh --config <same config>"
