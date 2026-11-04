#!/bin/bash

# Odoo Multi-Version Deployment Script
# 
# Automated deployment tool for running multiple Odoo versions with optional Nginx reverse proxy.
# Supports host-based routing with wildcard DNS (sslip.io) for zero-configuration local development.
#
# Features:
# - Multi-version Odoo deployment (16, 17, 18, 19)
# - Optional Nginx reverse proxy with host-based routing
# - Wildcard DNS support (sslip.io) - no /etc/hosts editing required
# - Auto-configured PostgreSQL 18 (default) with performance tuning + async I/O
# - Docker Compose orchestration
# - SELinux-compatible volume mounts
# - Custom entrypoints with proper configuration loading
#
# Usage: ./autodeploy-nginx.sh
#
# Copyright (C) 2025-2026 Makondoo Inc.
# Licence: AGPL-3.0-or-later

set -e
set -o pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() { echo -e "\n${CYAN}==== $1 ====${NC}"; }
print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_input() { echo -e "${BLUE}[INPUT]${NC} $1"; }

# Welcome (clear fails on dumb/absent TERM, e.g. when piped - never fatal)
clear 2>/dev/null || true
echo -e "${CYAN}Odoo Multi-Version Deployment Script${NC}"
echo -e "${CYAN}Production-ready with optional Nginx reverse proxy${NC}"
echo

# Get project name
print_input "Project name:"
read -r PROJECT_NAME

# Sanitize
PROJECT_NAME=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')

if [[ -z "$PROJECT_NAME" ]]; then
    print_error "Project name cannot be empty!"
    exit 1
fi

# Check existing
if [ -d "$PROJECT_NAME" ]; then
    print_warning "Directory exists. Overwrite? (y/N):"
    read -r OVERWRITE
    [[ ! "$OVERWRITE" =~ ^[Yy]$ ]] && exit 0
    rm -rf "$PROJECT_NAME"
fi

# Check port availability function
check_port() {
    local port=$1
    if command -v nc &> /dev/null; then
        nc -z localhost "$port" &> /dev/null
        return $?
    elif command -v netstat &> /dev/null; then
        # No -q: grep must consume the full stream, otherwise netstat gets
        # SIGPIPE and pipefail turns a found port into a false negative
        netstat -tuln | grep ":$port " > /dev/null
        return $?
    else
        # Fallback to a basic check
        (echo > /dev/tcp/127.0.0.1/"$port") &> /dev/null
        return $?
    fi
}

# Edition selection
print_input "Edition? (1) Community (2) Enterprise [1]:"
read -r EDITION_CHOICE
ODOO_EDITION=$([[ "$EDITION_CHOICE" == "2" ]] && echo "enterprise" || echo "community")

# Versions
print_input "Versions (comma-separated) [16,17,18,19]:"
read -r VERSIONS_INPUT
[[ -z "$VERSIONS_INPUT" ]] && VERSIONS_INPUT="16,17,18,19"

# Parse and validate versions immediately
IFS=',' read -ra VERSIONS <<< "$VERSIONS_INPUT"
VALID_VERSIONS=()
for version in "${VERSIONS[@]}"; do
    version=$(echo "$version" | tr -d ' ')
    if [[ "$version" =~ ^1[5-9]$ ]]; then
        VALID_VERSIONS+=("$version")
    fi
done

if [ ${#VALID_VERSIONS[@]} -eq 0 ]; then
    print_error "No valid versions!"
    exit 1
fi

print_success "Valid versions: ${VALID_VERSIONS[*]}"

# Odoo master password
print_input "Odoo master password (leave empty for random):"
read -rs ADMIN_PASSWD
echo
if [[ -z "$ADMIN_PASSWD" ]]; then
    ADMIN_PASSWD=$(openssl rand -base64 32)
    print_warning "Generated random password: ${ADMIN_PASSWD}"
    print_warning "Save this password securely!"
fi

# Python requirements strategy
print_header "Python Requirements Strategy"
echo "1) Install at container start (flexible: edit requirements.txt + restart)"
echo "2) Bake custom image (faster restarts, no internet needed at runtime,"
echo "   update via './manage.sh rebuild' - same feel as 'docker compose pull')"
print_input "Select option [1]:"
read -r BAKE_CHOICE
BAKE_IMAGE=$([[ "$BAKE_CHOICE" == "2" ]] && echo "true" || echo "false")
if [[ "$BAKE_IMAGE" == "true" ]]; then
    print_success "Baking custom images - edit {VERSION}-build/requirements.txt then './manage.sh rebuild VERSION'"
else
    print_success "Installing requirements at container start - edit {VERSION}-config/requirements.txt then restart"
fi

# Nginx option - ASK FIRST
print_input "Include Nginx proxy? (y/N):"
read -r NGINX_CHOICE
USE_NGINX=$([[ "$NGINX_CHOICE" =~ ^[Yy]$ ]] && echo "true" || echo "false")

if [[ "$USE_NGINX" == "true" ]]; then
    print_input "Nginx listening port [80]:"
    read -r NGINX_PORT
    [[ -z "$NGINX_PORT" ]] && NGINX_PORT=80

    if ! [[ "$NGINX_PORT" =~ ^[0-9]+$ ]]; then
        print_error "Nginx port must be a number!"
        exit 1
    fi
    
    print_header "Domain Configuration"
    echo "1) Use 127-0-0-1.sslip.io (wildcard DNS, no /etc/hosts needed) [RECOMMENDED for testing]"
    echo "2) Use localhost (local testing)"
    echo "3) Custom domain(s) - you specify EXACT domain for each version"
    print_input "Select option [1]:"
    read -r DOMAIN_CHOICE
    [[ -z "$DOMAIN_CHOICE" ]] && DOMAIN_CHOICE=1
    
    case "$DOMAIN_CHOICE" in
        1)
            BASE_DOMAIN="127-0-0-1.sslip.io"
            DOMAIN_MODE="auto"
            print_success "Using sslip.io - access at http://127-0-0-1.sslip.io:${NGINX_PORT}"
            ;;
        2)
            BASE_DOMAIN="localhost"
            DOMAIN_MODE="auto"
            print_success "Using localhost - access at http://localhost:${NGINX_PORT}"
            ;;
        3)
            DOMAIN_MODE="custom"
            declare -A CUSTOM_DOMAINS
            
            if [ ${#VALID_VERSIONS[@]} -eq 1 ]; then
                print_input "Enter your domain (e.g., portal.yourdomain.com):"
                read -r CUSTOM_DOMAIN
                [[ -z "$CUSTOM_DOMAIN" ]] && CUSTOM_DOMAIN="localhost"
                CUSTOM_DOMAINS[${VALID_VERSIONS[0]}]="$CUSTOM_DOMAIN"
                print_success "Odoo ${VALID_VERSIONS[0]} will be accessible at: http://${CUSTOM_DOMAIN}:${NGINX_PORT}"
            else
                echo ""
                print_status "Enter domain for each Odoo version:"
                for version in "${VALID_VERSIONS[@]}"; do
                    print_input "Domain for Odoo ${version} (e.g., portal.client1.com):"
                    read -r CUSTOM_DOMAIN
                    [[ -z "$CUSTOM_DOMAIN" ]] && CUSTOM_DOMAIN="odoo${version}.localhost"
                    CUSTOM_DOMAINS[$version]="$CUSTOM_DOMAIN"
                    print_success "Odoo ${version} → http://${CUSTOM_DOMAIN}:${NGINX_PORT}"
                done
            fi
            ;;
    esac
    
    BASE_PORT=0  # Flag to indicate no direct host port mapping
else
    # Only ask for Odoo ports if NOT using Nginx
    print_input "Starting host port for Odoo instances [8069]:"
    read -r BASE_PORT
    [[ -z "$BASE_PORT" ]] && BASE_PORT=8069

    # Validate port is numeric
    if ! [[ "$BASE_PORT" =~ ^[0-9]+$ ]]; then
        print_error "Port must be a number!"
        exit 1
    fi
    BASE_DOMAIN="localhost"
fi

if [[ "$USE_NGINX" == "true" ]]; then
    print_status "Creating: ${PROJECT_NAME} with versions ${VALID_VERSIONS[*]} (${ODOO_EDITION}) + Nginx on port ${NGINX_PORT}"
    if [[ "$DOMAIN_MODE" == "custom" ]]; then
        print_status "Using custom domains as specified"
    else
        print_status "Using ${BASE_DOMAIN} for access"
    fi
else
    print_status "Creating: ${PROJECT_NAME} with versions ${VALID_VERSIONS[*]} (${ODOO_EDITION})"
    print_status "Odoo instances will be directly accessible starting from port ${BASE_PORT}"
fi

# Create project
mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# Create directory structure
for version in "${VALID_VERSIONS[@]}"; do
    mkdir -p "${version}-config"
    mkdir -p "${version}-addons/custom"
    mkdir -p "${version}-addons/third-party"

    if [ "$ODOO_EDITION" = "enterprise" ]; then
        mkdir -p "${version}-addons/enterprise"
        mkdir -p "${version}-addons/industry"
    fi
done

# Default to PostgreSQL 18 for all Odoo versions: PG18 is compatibility-safe
# for Odoo's ORM-generated SQL and brings the async-I/O subsystem (io_method/
# io_workers) plus pg_stat_io byte-level stats. Older PG remains an explicit
# opt-down at the prompt below (e.g. to match an existing production DB).
PG_VERSION_DEFAULT="18"

# Let the deployer pick (e.g. matching an existing production DB for a sandbox clone)
print_input "PostgreSQL version [${PG_VERSION_DEFAULT}]:"
read -r PG_VERSION
[[ -z "$PG_VERSION" ]] && PG_VERSION=$PG_VERSION_DEFAULT

if ! [[ "$PG_VERSION" =~ ^[0-9]+$ ]] || [ "$PG_VERSION" -lt 13 ]; then
    print_error "PostgreSQL version must be a number >= 13 (Odoo 16+ requires PG 13+)"
    exit 1
fi

if [ "$PG_VERSION" != "$PG_VERSION_DEFAULT" ]; then
    print_warning "Using PostgreSQL ${PG_VERSION} (recommended for your Odoo versions: ${PG_VERSION_DEFAULT})"
fi

# Optional PgBouncer connection pooler
print_header "Connection Pooling (PgBouncer)"
echo "PgBouncer multiplexes all Odoo connections onto a small pool of postgres"
echo "backends. Worker counts stop being limited by max_connections entirely,"
echo "and connection storms are absorbed by the pooler instead of postgres."
echo "Odoo's websocket bus (LISTEN/NOTIFY on the 'postgres' DB) is routed in"
echo "session mode automatically, so realtime chat/notifications keep working."
print_input "Add PgBouncer connection pooler? (Y/n):"
read -r PGB_CHOICE
USE_PGBOUNCER=$([[ "$PGB_CHOICE" =~ ^[Nn]$ ]] && echo "false" || echo "true")
if [[ "$USE_PGBOUNCER" == "true" ]]; then
    print_success "PgBouncer enabled - transaction pooling with session-mode bus routing"
else
    print_status "No pooler - Odoo connects to postgres directly (worker count stays connection-budgeted)"
fi

# The postgres:18+ image moved its volume to /var/lib/postgresql; the old
# /var/lib/postgresql/data layout leaves a stray anonymous volume there.
if [ "$PG_VERSION" -ge 18 ]; then
    PG_VOLUME_MOUNT="db-data:/var/lib/postgresql:Z"
    PG_DATA_ENV=""
else
    PG_VOLUME_MOUNT="db-data:/var/lib/postgresql/data:Z"
    PG_DATA_ENV="PGDATA: /var/lib/postgresql/data/pgdata"
fi

# ============================================================================
# Resource detection & tuning math - SINGLE SOURCE OF TRUTH
# Every generated config (postgresql.conf, odoo.conf, docker-compose shm_size,
# nginx.conf, performance-tuner.sh) derives from the values computed here so
# the whole stack scales together, from 2-core VPS to 256-core bare metal.
# ============================================================================
CPU_CORES=$(nproc)
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
NUM_VERSIONS=${#VALID_VERSIONS[@]}

# clamp VALUE MIN MAX
clamp() {
    local v=$1 lo=$2 hi=$3
    [ "$v" -lt "$lo" ] && v=$lo
    [ "$v" -gt "$hi" ] && v=$hi
    echo "$v"
}

# --- PostgreSQL memory -------------------------------------------------------
SHARED_BUFFERS=$((TOTAL_RAM_MB / 4))  # 25% of RAM...
# ...capped at 16GB: beyond that OLTP workloads like Odoo see diminishing
# returns and double-buffering waste; the OS page cache (effective_cache_size)
# covers the rest. huge_pages=try in postgresql.conf avoids TLB thrashing.
[ "$SHARED_BUFFERS" -gt 16384 ] && SHARED_BUFFERS=16384
EFFECTIVE_CACHE_SIZE=$((TOTAL_RAM_MB * 3 / 4))  # 75% of RAM
MAINTENANCE_WORK_MEM=$(clamp $((TOTAL_RAM_MB / 16)) 64 4096)  # ~6% RAM, 4GB cap

# --- Odoo workers per version ------------------------------------------------
# Worker memory tiers by total RAM
if [ "$TOTAL_RAM_MB" -lt 4096 ]; then
    WORKER_MEMORY_MB=512
    SOFT_LIMIT_MB=400
elif [ "$TOTAL_RAM_MB" -lt 8192 ]; then
    WORKER_MEMORY_MB=1024
    SOFT_LIMIT_MB=800
else
    WORKER_MEMORY_MB=2048
    SOFT_LIMIT_MB=1600
fi

MAX_CRON_THREADS=2

# RAM budget: 80% safety factor, minus a small OS reserve and what postgres
# itself claims (shared_buffers), split evenly across deployed versions.
# Workers are planned at their SOFT limit: that is the steady-state footprint
# (Odoo recycles a worker that exceeds it after the current request), while
# the hard limit only guards abnormal spikes - sizing at the hard limit would
# leave half the machine idle.
available_ram_mb=$(( TOTAL_RAM_MB * 80 / 100 ))
RESERVED_RAM=$(( 512 + SHARED_BUFFERS ))
odoo_ram_budget=$(( available_ram_mb - RESERVED_RAM ))
[ "$odoo_ram_budget" -lt 0 ] && odoo_ram_budget=0
per_version_ram=$(( odoo_ram_budget / NUM_VERSIONS ))
max_workers_by_ram=$(( per_version_ram / SOFT_LIMIT_MB ))

# CPU guidance (workers = cores*2+1) is for a dedicated host, so the total is
# spread across versions (ceiling division) instead of granted to each one.
max_workers_by_cpu=$(( (CPU_CORES * 2 + 1 + NUM_VERSIONS - 1) / NUM_VERSIONS ))

OPTIMAL_WORKERS=$(( max_workers_by_ram < max_workers_by_cpu ? max_workers_by_ram : max_workers_by_cpu ))
# Very low resources: workers=0 runs Odoo single-process threaded mode
[ "$OPTIMAL_WORKERS" -lt 1 ] && OPTIMAL_WORKERS=0

# --- Connection budget (replaces the old flat max_connections=200 / cap of 8
# workers, which silently throttled anything bigger than a 4-core box) -------
if [[ "$USE_PGBOUNCER" == "true" ]]; then
    # PgBouncer (transaction mode) multiplexes any number of Odoo client
    # connections onto a small backend pool, so workers stay bounded by
    # CPU/RAM only. Postgres itself only needs ~4 active backends per core -
    # more than that just queue on CPU anyway.
    MAX_CONNECTIONS=$(clamp $(( CPU_CORES * 4 + 20 )) 100 500)
    # Per database/user pair pool; big reports hold a backend for their whole
    # transaction, so give each database room to fan out.
    PGB_DEFAULT_POOL_SIZE=$(clamp $(( CPU_CORES * 2 )) 8 64)
    # Hard per-database backend cap so one busy database cannot starve others
    PGB_MAX_DB_CONNECTIONS=$(( MAX_CONNECTIONS - 20 ))
    # Client side is cheap: every Odoo process may hold up to db_maxconn
    PGB_MAX_CLIENT_CONN=$(clamp $(( NUM_VERSIONS * (OPTIMAL_WORKERS + MAX_CRON_THREADS + 2) * 16 )) 1000 10000)
else
    # Direct connections: peak per version is HTTP workers at ~2 connections
    # each under load, plus cron threads, plus a gevent/bus + maintenance
    # allowance.
    PER_VERSION_CONNS=$(( OPTIMAL_WORKERS * 2 + MAX_CRON_THREADS + 8 ))
    MAX_CONNECTIONS=$(( PER_VERSION_CONNS * NUM_VERSIONS * 120 / 100 + 10 ))  # +20% headroom +10 reserve
    [ "$MAX_CONNECTIONS" -lt 100 ] && MAX_CONNECTIONS=100
    if [ "$MAX_CONNECTIONS" -gt 1000 ]; then
        # Past ~1000 backends, per-process overhead dominates; clamp and derive
        # the worker count back from the budget. Enabling PgBouncer removes
        # this limit entirely.
        MAX_CONNECTIONS=1000
        budget_per_version=$(( (MAX_CONNECTIONS - 10) * 100 / 120 / NUM_VERSIONS ))
        OPTIMAL_WORKERS=$(( (budget_per_version - MAX_CRON_THREADS - 8) / 2 ))
        print_warning "Worker count limited by 1000-connection budget - enable PgBouncer to go beyond"
    fi
fi

# Per-process pool cap in Odoo; scaled to the computed worker count so a
# single runaway process cannot drain the whole cluster budget.
DB_MAXCONN=$(clamp $(( OPTIMAL_WORKERS * 2 + 16 )) 64 256)

# --- work_mem: bounded against the connection budget, not just cores --------
# Worst case is work_mem x concurrent sort/hash ops; dividing non-shared RAM
# by max_connections keeps a fully loaded box out of OOM territory (the old
# RAM/(cores*4) formula produced 512MB on a 2-core/4GB box).
WORK_MEM=$(clamp $(( (TOTAL_RAM_MB - SHARED_BUFFERS) / MAX_CONNECTIONS )) 4 256)

# --- WAL sizing, autovacuum, shared memory by RAM tier -----------------------
if [ "$TOTAL_RAM_MB" -lt 8192 ]; then
    MAX_WAL_SIZE="2GB";  MIN_WAL_SIZE="512MB"
elif [ "$TOTAL_RAM_MB" -lt 32768 ]; then
    MAX_WAL_SIZE="4GB";  MIN_WAL_SIZE="1GB"
else
    MAX_WAL_SIZE="8GB";  MIN_WAL_SIZE="2GB"
fi

AUTOVACUUM_WORKERS=$(clamp $(( CPU_CORES / 4 )) 3 8)

# --- Parallel query: what actually makes a single huge report fast ----------
# Postgres defaults cap every query at 2 parallel workers (out of a global
# pool of 8) no matter how many cores exist. Scale the pool to the machine so
# big scans/sorts/aggregations fan out across cores.
MAX_WORKER_PROCESSES=$(clamp "$CPU_CORES" 8 128)
MAX_PARALLEL_WORKERS=$(clamp "$CPU_CORES" 8 128)
MAX_PARALLEL_PER_GATHER=$(clamp $(( CPU_CORES / 4 )) 2 8)
MAX_PARALLEL_MAINTENANCE=$(clamp $(( CPU_CORES / 8 )) 2 4)

if [ "$TOTAL_RAM_MB" -lt 4096 ]; then
    SHM_SIZE="256mb"
elif [ "$TOTAL_RAM_MB" -lt 8192 ]; then
    SHM_SIZE="512mb"
elif [ "$TOTAL_RAM_MB" -lt 32768 ]; then
    SHM_SIZE="1gb"
else
    SHM_SIZE="2gb"
fi

# --- PostgreSQL 18+ async I/O -----------------------------------------------
# io_method=worker (async I/O via worker processes) is the PG18 default but is
# pinned explicitly, with io_workers scaled to CPU instead of the fixed 3.
# io_uring is NOT used: Docker's default seccomp profile blocks io_uring
# syscalls, so postgres would fail at startup inside the container.
IO_WORKERS=$(clamp $(( CPU_CORES / 4 )) 3 32)

# --- Nginx (only used when the embedded proxy is enabled) --------------------
NGINX_WORKER_CONNECTIONS=$(clamp $(( CPU_CORES * 1024 )) 1024 8192)
# Each proxied client costs ~2 fds (client + upstream); keep rlimit above that
NGINX_RLIMIT_NOFILE=$(( NGINX_WORKER_CONNECTIONS * 2 + 512 ))
NGINX_KEEPALIVE=$(clamp $(( OPTIMAL_WORKERS * 4 )) 32 128)
NGINX_KEEPALIVE_CHAT=$(( NGINX_KEEPALIVE / 2 ))

# --- Odoo memory limits (bytes) ----------------------------------------------
HARD_LIMIT_BYTES=$(( WORKER_MEMORY_MB * 1024 * 1024 ))
SOFT_LIMIT_BYTES=$(( SOFT_LIMIT_MB * 1024 * 1024 ))

# Where Odoo connects: through the pooler when enabled, else straight to postgres
if [[ "$USE_PGBOUNCER" == "true" ]]; then
    ODOO_DB_HOST="pgbouncer"
else
    ODOO_DB_HOST="db"
fi

print_status "Detected ${CPU_CORES} cores, ${TOTAL_RAM_MB}MB RAM, ${NUM_VERSIONS} Odoo version(s)"
print_status "Tuning: ${OPTIMAL_WORKERS} workers/version, db_maxconn=${DB_MAXCONN}, pg max_connections=${MAX_CONNECTIONS}, work_mem=${WORK_MEM}MB"

# Generate docker-compose.yml with custom entrypoint
print_status "Generating docker-compose.yml with custom entrypoint..."

cat > docker-compose.yml << EOF
services:
  db:
    image: postgres:${PG_VERSION}
    restart: unless-stopped
    environment:
      POSTGRES_USER: odoo
      POSTGRES_PASSWORD: odoo
      POSTGRES_DB: postgres
      TZ: Africa/Nairobi
EOF

if [ -n "$PG_DATA_ENV" ]; then
    echo "      ${PG_DATA_ENV}" >> docker-compose.yml
fi

cat >> docker-compose.yml << EOF
    volumes:
      - ${PG_VOLUME_MOUNT}
      - ./conf/postgresql:/etc/postgresql:ro,z
    # Load the generated tuning config - without this postgres silently runs
    # with defaults (128MB shared_buffers) and the mounted files do nothing
    command: >
      postgres
      -c config_file=/etc/postgresql/postgresql.conf
      -c hba_file=/etc/postgresql/pg_hba.conf
    # Scaled by RAM tier: parallel query DSM segments and sort spills live here
    shm_size: "${SHM_SIZE}"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U odoo"]
      interval: 10s
      timeout: 5s
      retries: 5

EOF

# Add PgBouncer pooler if requested. It listens on 5432 itself so odoo.conf
# keeps db_port unchanged; only db_host differs.
if [[ "$USE_PGBOUNCER" == "true" ]]; then
    cat >> docker-compose.yml << EOF
  pgbouncer:
    image: edoburu/pgbouncer:latest
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    volumes:
      - ./conf/pgbouncer:/etc/pgbouncer:ro,z
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -p 5432 -U odoo"]
      interval: 10s
      timeout: 5s
      retries: 5

EOF
    # Odoo containers must additionally wait for the pooler
    PGB_DEPENDS="
      pgbouncer:
        condition: service_healthy"
else
    PGB_DEPENDS=""
fi

# Add nginx service if requested
if [[ "$USE_NGINX" == "true" ]]; then
    cat >> docker-compose.yml << EOF
  nginx:
    image: nginx:alpine
    restart: unless-stopped
    ports:
      - "${NGINX_PORT}:80"
    volumes:
      - ./conf/nginx/nginx.conf:/etc/nginx/nginx.conf:ro,z
      - ./conf/nginx/conf.d:/etc/nginx/conf.d:ro,z
    depends_on:
EOF

    for version in "${VALID_VERSIONS[@]}"; do
        echo "      - odoo${version}" >> docker-compose.yml
    done

    echo >> docker-compose.yml
fi

# Generate services for each version
for version in "${VALID_VERSIONS[@]}"; do
    # Image source: official image, or locally baked image with requirements
    if [[ "$BAKE_IMAGE" == "true" ]]; then
        IMAGE_BLOCK="build:
      context: ./${version}-build
    image: ${PROJECT_NAME}-odoo${version}:latest"
    else
        IMAGE_BLOCK="image: odoo:${version}.0"
    fi

    if [[ "$USE_NGINX" == "true" ]]; then
        # With Nginx: no host port mapping, only internal container ports
        print_status "Odoo ${version} will be accessible via Nginx (internal ports only)"
        
        cat >> docker-compose.yml << EOF
  odoo${version}:
    ${IMAGE_BLOCK}
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy${PGB_DEPENDS}
    expose:
      - "8069"
      - "8072"
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:8069/web/health || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    environment:
      HOST: ${ODOO_DB_HOST}
      USER: odoo
      PASSWORD: odoo
      ODOO_RC: /etc/odoo/odoo.conf
      TZ: Africa/Nairobi
    volumes:
      - odoo${version}-data:/var/lib/odoo:Z
      - ./${version}-config:/etc/odoo:Z
      - ./${version}-addons/custom:/mnt/custom-addons:Z
      - ./${version}-addons/third-party:/mnt/third-party-addons:Z
      - ./${version}-logs:/var/log/odoo:Z
EOF

        if [ "$ODOO_EDITION" = "enterprise" ]; then
            cat >> docker-compose.yml << EOF
      - ./${version}-addons/enterprise:/mnt/enterprise-addons:Z
      - ./${version}-addons/industry:/mnt/industry-addons:Z
EOF
        fi

        cat >> docker-compose.yml << EOF
    entrypoint: ["/etc/odoo/entrypoint.sh"]
    command: ["odoo"]

EOF
    else
        # Without Nginx: expose host ports for direct access
        HOST_PORT=$((BASE_PORT + version - 16))
        HOST_LONGPOLL_PORT=$((HOST_PORT + 1000))

        # Check port availability
        if check_port "$HOST_PORT"; then
            print_warning "Host port $HOST_PORT is already in use! Using alternative port."
            HOST_PORT=$((HOST_PORT + 100))
        fi

        if check_port "$HOST_LONGPOLL_PORT"; then
            print_warning "Longpolling host port $HOST_LONGPOLL_PORT is already in use! Using alternative port."
            HOST_LONGPOLL_PORT=$((HOST_LONGPOLL_PORT + 100))
        fi

        print_status "Odoo ${version} will use host port ${HOST_PORT} (longpolling: ${HOST_LONGPOLL_PORT})"

        cat >> docker-compose.yml << EOF
  odoo${version}:
    ${IMAGE_BLOCK}
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy${PGB_DEPENDS}
    ports:
      - "${HOST_PORT}:8069"
      - "${HOST_LONGPOLL_PORT}:8072"
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:8069/web/health || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    environment:
      HOST: ${ODOO_DB_HOST}
      USER: odoo
      PASSWORD: odoo
      ODOO_RC: /etc/odoo/odoo.conf
      TZ: Africa/Nairobi
    volumes:
      - odoo${version}-data:/var/lib/odoo:Z
      - ./${version}-config:/etc/odoo:Z
      - ./${version}-addons/custom:/mnt/custom-addons:Z
      - ./${version}-addons/third-party:/mnt/third-party-addons:Z
      - ./${version}-logs:/var/log/odoo:Z
EOF

        if [ "$ODOO_EDITION" = "enterprise" ]; then
            cat >> docker-compose.yml << EOF
      - ./${version}-addons/enterprise:/mnt/enterprise-addons:Z
      - ./${version}-addons/industry:/mnt/industry-addons:Z
EOF
        fi

        cat >> docker-compose.yml << EOF
    entrypoint: ["/etc/odoo/entrypoint.sh"]
    command: ["odoo"]

EOF
    fi
done

# Add volumes section
cat >> docker-compose.yml << 'EOF'
volumes:
  db-data:
EOF

for version in "${VALID_VERSIONS[@]}"; do
    echo "  odoo${version}-data:" >> docker-compose.yml
done

# Create PostgreSQL configuration
mkdir -p conf/postgresql

# Create optimized PostgreSQL configuration (values from the tuning block above)
cat > conf/postgresql/postgresql.conf << EOF
# PostgreSQL ${PG_VERSION} Configuration - Auto-generated for Odoo
# System: ${CPU_CORES} cores, ${TOTAL_RAM_MB}MB RAM, ${NUM_VERSIONS} Odoo version(s)

# Connection Settings
# listen_addresses MUST be '*' here: this file replaces the image-generated
# config (which the docker image patches to listen on all interfaces).
# Without it postgres only listens on loopback and Odoo gets
# "Connection refused" while the socket-based healthcheck stays green.
listen_addresses = '*'
port = 5432
# Sized from the Odoo worker budget: ~(workers*2 + cron + gevent allowance)
# per version, +20% headroom. Scales with the hardware instead of a flat 200.
max_connections = ${MAX_CONNECTIONS}
superuser_reserved_connections = 3

# Memory Settings
shared_buffers = ${SHARED_BUFFERS}MB
huge_pages = try
effective_cache_size = ${EFFECTIVE_CACHE_SIZE}MB
maintenance_work_mem = ${MAINTENANCE_WORK_MEM}MB
# Bounded against max_connections so worst-case concurrent sorts cannot OOM
work_mem = ${WORK_MEM}MB

# Checkpoint / WAL sizing
# Raising max_wal_size from the conservative built-in default spreads
# checkpoints out - Odoo's constant small transactional writes otherwise
# force needless checkpoint I/O churn.
checkpoint_completion_target = 0.9
checkpoint_timeout = 15min
max_wal_size = ${MAX_WAL_SIZE}
min_wal_size = ${MIN_WAL_SIZE}
wal_buffers = 16MB
default_statistics_target = 100

# Query Planner (all deployments run on NVMe/SSD storage)
random_page_cost = 1.1
effective_io_concurrency = 200
maintenance_io_concurrency = 200

# Parallel query - this is what makes a single multi-million-row report scan
# fan out across cores. Postgres defaults cap every query at 2 workers from a
# global pool of 8 regardless of core count.
max_worker_processes = ${MAX_WORKER_PROCESSES}
max_parallel_workers = ${MAX_PARALLEL_WORKERS}
max_parallel_workers_per_gather = ${MAX_PARALLEL_PER_GATHER}
max_parallel_maintenance_workers = ${MAX_PARALLEL_MAINTENANCE}

# Write Ahead Logging
wal_level = replica
max_wal_senders = 3
max_replication_slots = 3

# Observability - lets you verify the tuning actually helps.
# Query the stats via: SELECT ... FROM pg_stat_statements / pg_stat_io;
# (run "CREATE EXTENSION pg_stat_statements;" once in the DB you query from)
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.track = all
track_io_timing = on

# Safety timeouts
# statement_timeout stays 0: Odoo enforces its own limit_time_cpu/real and a
# global cap here would kill long module installs/upgrades.
statement_timeout = 0
# Abandoned transactions hold connections and block autovacuum; 30min sits
# safely above Odoo's limit_time_real (20min).
idle_in_transaction_session_timeout = 1800s

# Logging
log_destination = 'stderr'
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_rotation_age = 1d
log_rotation_size = 100MB
log_min_duration_statement = 1000
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
log_temp_files = 0

# Performance
autovacuum = on
autovacuum_max_workers = ${AUTOVACUUM_WORKERS}
autovacuum_naptime = 20s
autovacuum_vacuum_threshold = 50
autovacuum_analyze_threshold = 50
autovacuum_vacuum_scale_factor = 0.1
autovacuum_analyze_scale_factor = 0.05

# Locale and Formatting
lc_messages = 'en_US.utf8'
lc_monetary = 'en_US.utf8'
lc_numeric = 'en_US.utf8'
lc_time = 'en_US.utf8'
default_text_search_config = 'pg_catalog.english'

# Timezone
timezone = 'UTC'

# Security
ssl = off
password_encryption = scram-sha-256
EOF

# PostgreSQL 18+ asynchronous I/O - these GUCs do not exist on older versions
# and would prevent startup, so the block is strictly version-gated.
if [ "$PG_VERSION" -ge 18 ]; then
    cat >> conf/postgresql/postgresql.conf << EOF

# Asynchronous I/O (PostgreSQL 18+)
# 'worker' async I/O; io_uring is deliberately NOT used because Docker's
# default seccomp profile blocks io_uring syscalls (postgres would fail to
# start). If running with a custom seccomp profile that allows it AND the
# image links liburing (postgres:18 bookworm does), io_uring is a valid
# opt-in here after testing.
io_method = worker
# Scaled to ~1/4 of CPU threads (default is a fixed 3, starving many-core hosts)
io_workers = ${IO_WORKERS}
# -1 = auto-derive from shared_buffers / connection settings (explicit defaults,
# kept visible here as the knobs to revisit with real workload benchmarks)
io_max_concurrency = -1
io_combine_limit = 128kB
EOF
fi

# Create pg_hba.conf for authentication
cat > conf/postgresql/pg_hba.conf << 'EOF'
# PostgreSQL Client Authentication Configuration File
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# "local" is for Unix domain socket connections only
local   all             all                                     trust
# IPv4 local connections:
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             0.0.0.0/0               scram-sha-256
# IPv6 local connections:
host    all             all             ::1/128                 scram-sha-256
# Allow replication connections from localhost, by a user with the
# replication privilege.
local   replication     all                                     trust
host    replication     all             127.0.0.1/32            scram-sha-256
host    replication     all             ::1/128                 scram-sha-256
EOF

print_status "PostgreSQL ${PG_VERSION} auto-configured with ${SHARED_BUFFERS}MB shared_buffers"

# Create PgBouncer configuration
if [[ "$USE_PGBOUNCER" == "true" ]]; then
    mkdir -p conf/pgbouncer

    cat > conf/pgbouncer/pgbouncer.ini << EOF
; PgBouncer configuration - Auto-generated for Odoo
; System: ${CPU_CORES} cores, ${NUM_VERSIONS} Odoo version(s)

[databases]
; Odoo's realtime bus does LISTEN/NOTIFY on the 'postgres' maintenance DB
; (verified in odoo/addons/bus/models/bus.py across 16..19: both the
; ImDispatch LISTEN loop and the postcommit NOTIFY use db_connect('postgres')).
; LISTEN breaks under transaction pooling, so this one database is pinned to
; session mode. The Odoo database manager (CREATE DATABASE) also lives here.
postgres = host=db port=5432 dbname=postgres pool_mode=session

; Every actual Odoo database: transaction pooling - client connections are
; multiplexed onto a small backend pool, decoupling Odoo worker count from
; postgres max_connections.
* = host=db port=5432

[pgbouncer]
listen_addr = 0.0.0.0
; pgbouncer answers on 5432 itself so Odoo's db_port stays unchanged
listen_port = 5432
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
admin_users = odoo

pool_mode = transaction
max_client_conn = ${PGB_MAX_CLIENT_CONN}
; per database/user pair - reports hold a backend for their whole transaction
default_pool_size = ${PGB_DEFAULT_POOL_SIZE}
min_pool_size = 0
reserve_pool_size = 5
reserve_pool_timeout = 3
; one busy database cannot starve the others
max_db_connections = ${PGB_MAX_DB_CONNECTIONS}
server_idle_timeout = 600

; psycopg2 sends this at connect time; pass it through instead of rejecting
ignore_startup_parameters = extra_float_digits

log_connections = 0
log_disconnections = 0
EOF

    # Plaintext password in the auth file works with scram on both sides:
    # pgbouncer derives what it needs for client auth and server auth.
    cat > conf/pgbouncer/userlist.txt << 'EOF'
"odoo" "odoo"
EOF

    print_status "PgBouncer configured: transaction pooling (pool=${PGB_DEFAULT_POOL_SIZE}/db), session mode for bus"
fi

# Create config files and entrypoints for each version
for version in "${VALID_VERSIONS[@]}"; do

    # Build addons path based on edition
    if [ "$ODOO_EDITION" = "enterprise" ]; then
        ADDONS_PATH="/usr/lib/python3/dist-packages/odoo/addons,/mnt/enterprise-addons,/mnt/industry-addons,/mnt/third-party-addons,/mnt/custom-addons"
    else
        ADDONS_PATH="/usr/lib/python3/dist-packages/odoo/addons,/mnt/third-party-addons,/mnt/custom-addons"
    fi

    print_status "Creating auto-configured Odoo ${version}..."

    # Worker count, memory limits and connection budget all come from the
    # unified tuning block near the top of this script - one formula for the
    # whole stack, already divided across the ${NUM_VERSIONS} deployed version(s).
    DEV_WORKERS=$OPTIMAL_WORKERS
    PROD_WORKERS=$OPTIMAL_WORKERS

    # Create comprehensive odoo.conf
    if [[ "$USE_NGINX" == "true" ]]; then
        # With Nginx: no need to track host ports
        HOST_PORT="N/A (via Nginx)"
        HOST_LONGPOLL_PORT="N/A (via Nginx)"
        PROXY_MODE="True"
    else
        # Without Nginx: calculate and track host ports
        HOST_PORT=$((BASE_PORT + version - 16))
        HOST_LONGPOLL_PORT=$((HOST_PORT + 1000))
        PROXY_MODE="False"

        # Check if host ports are already in use and adjust if needed
        if check_port "$HOST_PORT"; then
            HOST_PORT=$((HOST_PORT + 100))
        fi
        if check_port "$HOST_LONGPOLL_PORT"; then
            HOST_LONGPOLL_PORT=$((HOST_LONGPOLL_PORT + 100))
        fi
    fi

    cat > "${version}-config/odoo.conf" << EOF
[options]
# Database
db_host = ${ODOO_DB_HOST}
db_port = 5432
db_user = odoo
db_password = odoo
# Per-process pool cap, scaled with worker count (matches pg max_connections budget)
db_maxconn = ${DB_MAXCONN}

# Server
addons_path = ${ADDONS_PATH}
data_dir = /var/lib/odoo
admin_passwd = ${ADMIN_PASSWD}
http_port = 8069

# Workers: Auto-configured for this system (${CPU_CORES} cores, ${TOTAL_RAM_MB}MB RAM, ${NUM_VERSIONS} version(s) sharing)
workers = ${DEV_WORKERS}
max_cron_threads = ${MAX_CRON_THREADS}

# Memory limits (in bytes) - Auto-calculated
limit_memory_hard = ${HARD_LIMIT_BYTES}
limit_memory_soft = ${SOFT_LIMIT_BYTES}
limit_request = 8192
limit_time_cpu = 600
limit_time_real = 1200

# Gevent
gevent_port = 8072
proxy_mode = ${PROXY_MODE}

# Logging
log_level = info
logfile = /var/log/odoo/odoo.log

# Security
list_db = True
dbfilter = .*${version}.*

# Performance
transient_age_limit = 1.0
osv_memory_count_limit = 0

# Project: ${PROJECT_NAME}
# Version: ${version}.0
# Host Port: ${HOST_PORT} (longpolling: ${HOST_LONGPOLL_PORT})
EOF

    # Create custom entrypoint with version-specific pip handling
    cat > "${version}-config/entrypoint.sh" << 'ENTRYPOINT_EOF'
#!/bin/bash
set -e

# Set Kenya timezone
export TZ=Africa/Nairobi

# Database connection settings
: ${HOST:=${DB_PORT_5432_TCP_ADDR:='db'}}
: ${PORT:=${DB_PORT_5432_TCP_PORT:=5432}}
: ${USER:=${DB_ENV_POSTGRES_USER:=${POSTGRES_USER:='odoo'}}}
: ${PASSWORD:=${DB_ENV_POSTGRES_PASSWORD:=${POSTGRES_PASSWORD:='odoo'}}}

# Install additional Python packages if requirements.txt exists
if [ -f "/etc/odoo/requirements.txt" ]; then
    echo "Installing additional Python packages..."
ENTRYPOINT_EOF

    # Add version-specific pip handling
    if [ "$version" -ge 18 ]; then
        cat >> "${version}-config/entrypoint.sh" << 'ENTRYPOINT_EOF'
    pip3 install --break-system-packages -r /etc/odoo/requirements.txt || echo "WARNING: pip install failed, continuing with existing packages"
ENTRYPOINT_EOF
    else
        cat >> "${version}-config/entrypoint.sh" << 'ENTRYPOINT_EOF'
    pip3 install -r /etc/odoo/requirements.txt || echo "WARNING: pip install failed, continuing with existing packages"
ENTRYPOINT_EOF
    fi

    cat >> "${version}-config/entrypoint.sh" << 'ENTRYPOINT_EOF'
fi

# Fix permissions where possible. This entrypoint runs as the unprivileged
# "odoo" user (official image drops root), so chown on root-owned bind mounts
# is expected to fail - it must never abort startup.
chown -R odoo:odoo /var/lib/odoo 2>/dev/null || true
chown -R odoo:odoo /var/log/odoo 2>/dev/null || true

# Function to check database connectivity
wait_for_db() {
    echo "Waiting for database to be ready..."
    while ! pg_isready -h "$HOST" -p "$PORT" -U "$USER" > /dev/null 2>&1; do
        sleep 1
    done
    echo "Database is ready!"
}

# Start logrotate in background
if [ -f "/etc/odoo/logrotate" ]; then
    (while true; do sleep 86400; logrotate /etc/odoo/logrotate; done) &
fi

# Build database arguments
DB_ARGS=()
function check_config() {
    param="$1"
    value="$2"
    if [ -f "$ODOO_RC" ] && grep -q -E "^\s*\b${param}\b\s*=" "$ODOO_RC"; then
        value=$(grep -E "^\s*\b${param}\b\s*=" "$ODOO_RC" | cut -d '=' -f2 | sed 's/[[:space:]]*//g')
    fi
    DB_ARGS+=("--${param}")
    DB_ARGS+=("${value}")
}

# Don't pass db_name in connection args - let Odoo handle it
check_config "db_host" "$HOST"
check_config "db_port" "$PORT"
check_config "db_user" "$USER"
check_config "db_password" "$PASSWORD"

# If the mounted log directory is not writable by the odoo user, override the
# configured logfile so Odoo logs to stdout instead of crashing on startup.
if [ ! -w /var/log/odoo ]; then
    echo "WARNING: /var/log/odoo is not writable - logging to stdout instead"
    DB_ARGS+=("--logfile=")
fi

case "$1" in
    -- | odoo)
        shift
        if [[ "$1" == "scaffold" ]]; then
            exec odoo "$@"
        else
            wait_for_db
            exec odoo --config="$ODOO_RC" "$@" "${DB_ARGS[@]}"
        fi
        ;;
    -*)
        wait_for_db
        exec odoo --config="$ODOO_RC" "$@" "${DB_ARGS[@]}"
        ;;
    *)
        exec "$@"
esac

exit 1
ENTRYPOINT_EOF

    # Make entrypoint executable
    chmod +x "${version}-config/entrypoint.sh"

    # Create requirements.txt for additional packages.
    # Bake mode: lives in the build context and gets baked into the image
    #   (the entrypoint pip step auto-skips since /etc/odoo/requirements.txt
    #   won't exist). Update flow: edit + './manage.sh rebuild VERSION'.
    # Runtime mode: lives in {VERSION}-config and installs at container start.
    if [[ "$BAKE_IMAGE" == "true" ]]; then
        REQUIREMENTS_FILE="${version}-build/requirements.txt"
        mkdir -p "${version}-build"
    else
        REQUIREMENTS_FILE="${version}-config/requirements.txt"
    fi

    cat > "$REQUIREMENTS_FILE" << EOF
# Additional Python packages for Odoo ${version}
requests>=2.25.0
python-dateutil>=2.8.0
psutil>=5.8.0
reportlab>=3.5.0
qrcode>=6.1
xlsxwriter>=1.3.0
xlrd>=1.2.0
gevent>=21.0.0
psycopg2-binary>=2.8.6
EOF

    # Create Dockerfile for baked image mode
    if [[ "$BAKE_IMAGE" == "true" ]]; then
        if [ "$version" -ge 18 ]; then
            PIP_FLAGS="--break-system-packages"
        else
            PIP_FLAGS=""
        fi
        cat > "${version}-build/Dockerfile" << EOF
FROM odoo:${version}.0

# Python requirements baked in at build time.
# Add packages to requirements.txt, then: ./manage.sh rebuild ${version}
COPY requirements.txt /tmp/requirements.txt
USER root
RUN pip3 install ${PIP_FLAGS} --no-cache-dir -r /tmp/requirements.txt \\
    && rm /tmp/requirements.txt
USER odoo
EOF
    fi

    # Create log directory
    mkdir -p "${version}-logs" 2>/dev/null || true
    chmod 777 "${version}-logs" 2>/dev/null || true

    # Create logrotate config
    cat > "${version}-config/logrotate" << EOF
/var/log/odoo/*.log {
    daily
    missingok
    rotate 30
    compress
    notifempty
    create 644 odoo odoo
}
EOF

    # Create addon README
    cat > "${version}-addons/README.md" << EOF
# Odoo ${version} Addons

## Custom Addons (\`custom/\`)
Place your custom modules here.

## Third-party Addons (\`third-party/\`)
Place external modules here.

EOF

    if [ "$ODOO_EDITION" = "enterprise" ]; then
        cat >> "${version}-addons/README.md" << EOF
## Enterprise Addons (\`enterprise/\`)
Place official Odoo Enterprise modules here.

## Industry Addons (\`industry/\`)
Place industry-specific modules here.

EOF
    fi

    cat >> "${version}-addons/README.md" << EOF
## Installation
1. Add your modules to the appropriate directory
2. Restart the container: \`../manage.sh restart ${version}\`
3. Update the apps list in Odoo
4. Install your modules

## Addons Path
\`${ADDONS_PATH}\`
EOF

done

# Create initialization script for first run
cat > init-setup.sh << 'EOF'
#!/bin/bash
# Auto-initialization script - runs once on first startup

set -e

print_info() { echo -e "\033[0;34m[INIT]\033[0m $1"; }
print_success() { echo -e "\033[0;32m[SUCCESS]\033[0m $1"; }

print_info "Starting auto-initialization..."

# Wait for database to be ready
print_info "Waiting for PostgreSQL to be ready..."
while ! docker compose exec -T db pg_isready -U odoo > /dev/null 2>&1; do
    sleep 2
done

# Create databases for each version if they don't exist
for version in VERSIONS_PLACEHOLDER; do
    db_name="PROJECT_NAME_${version}"
    if ! docker compose exec -T db psql -U odoo -lqt | cut -d \| -f 1 | grep -qw "$db_name"; then
        print_info "Creating database: $db_name"
        docker compose exec -T db createdb -U odoo -O odoo "$db_name"
        print_success "Database $db_name created"
    fi
done

# Initialize Odoo databases
for version in VERSIONS_PLACEHOLDER; do
    db_name="PROJECT_NAME_${version}"
    print_info "Initializing Odoo $version database..."
    # Odoo 18+ creates databases without demo data by default;
    # --without-demo=all is deprecated there and only needed for <= 17
    if [ "$version" -ge 18 ]; then
        demo_flag=""
    else
        demo_flag="--without-demo=all"
    fi
    docker compose exec odoo$version odoo --config=/etc/odoo/odoo.conf -d "$db_name" -i base --stop-after-init $demo_flag
    print_success "Odoo $version initialized"
done

print_success "Auto-initialization complete!"
print_info "Run './manage.sh urls' to see access URLs"
EOF

# Replace placeholders in init script
sed -i "s/VERSIONS_PLACEHOLDER/${VALID_VERSIONS[*]}/g" init-setup.sh
sed -i "s/PROJECT_NAME/${PROJECT_NAME}/g" init-setup.sh
chmod +x init-setup.sh

# Create nginx configuration directory and template
mkdir -p conf/nginx
mkdir -p conf/nginx/conf.d

if [[ "$USE_NGINX" == "true" ]]; then
    # Create main nginx.conf - worker limits scaled to detected CPU cores
    cat > conf/nginx/nginx.conf << EOF
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

# Must sit comfortably above worker_connections*2 (each proxied client costs
# a downstream + an upstream fd) or raising worker_connections does nothing.
worker_rlimit_nofile ${NGINX_RLIMIT_NOFILE};

events {
    worker_connections ${NGINX_WORKER_CONNECTIONS};
    use epoll;
    multi_accept on;
}

EOF

    cat >> conf/nginx/nginx.conf << 'EOF'
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/xml+rss application/json image/svg+xml;

    include /etc/nginx/conf.d/*.conf;
}
EOF

    # Create Odoo-specific nginx config with HOST-BASED routing
    cat > conf/nginx/conf.d/odoo.conf << EOF
# Odoo Multi-Version Nginx Configuration - HOST-BASED ROUTING
# Generated for project: ${PROJECT_NAME}
# Base domain: ${BASE_DOMAIN}

# Rate limiting
limit_req_zone \$binary_remote_addr zone=login:10m rate=5r/m;
limit_req_zone \$binary_remote_addr zone=api:10m rate=20r/m;

# WebSocket upgrade mapping
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

EOF

    # Generate upstream blocks
    for version in "${VALID_VERSIONS[@]}"; do
        cat >> conf/nginx/conf.d/odoo.conf << EOF
# Upstream for Odoo ${version}
upstream odoo${version} {
    server odoo${version}:8069;
    keepalive ${NGINX_KEEPALIVE};
}

upstream odoo${version}chat {
    server odoo${version}:8072;
    keepalive ${NGINX_KEEPALIVE_CHAT};
}

EOF
    done

    # Generate a server block for EACH version
    for version in "${VALID_VERSIONS[@]}"; do
        if [[ "$DOMAIN_MODE" == "custom" ]]; then
            # Custom domain: use EXACTLY what user specified
            SERVER_NAME="${CUSTOM_DOMAINS[$version]}"
        elif [[ "$DOMAIN_MODE" == "auto" ]]; then
            # Auto mode: use base domain with version prefix for multiple versions
            if [ ${#VALID_VERSIONS[@]} -eq 1 ]; then
                SERVER_NAME="${BASE_DOMAIN}"
            else
                SERVER_NAME="odoo${version}.${BASE_DOMAIN}"
            fi
        fi
        
        cat >> conf/nginx/conf.d/odoo.conf << EOF
# Server block for Odoo ${version} - ${SERVER_NAME}
server {
    listen 80;
    server_name ${SERVER_NAME};

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

    # Timeouts
    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    # Buffer sizes
    proxy_buffer_size 128k;
    proxy_buffers 4 256k;
    proxy_busy_buffers_size 256k;

    # Client settings
    client_max_body_size 200M;
    client_body_timeout 60s;
    client_header_timeout 60s;

    # Logging
    access_log /var/log/nginx/odoo${version}-access.log;
    error_log /var/log/nginx/odoo${version}-error.log;

    # Block common attack patterns
    location ~* (\.git|\.env|\.htaccess|\.svn|\.DS_Store|web\.config) {
        deny all;
        return 404;
    }

    # NOTE: no SQL-injection regex filtering here on purpose. Nginx location
    # matching only sees the decoded URI path (never the query string), so
    # such regexes catch nothing real while risking false positives on
    # legitimate Odoo routes. SQL injection defense belongs in the ORM.

    # WebSocket/Longpolling
    location /websocket {
        proxy_pass http://odoo${version}chat;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
        proxy_http_version 1.1;
    }

    location /longpolling {
        proxy_pass http://odoo${version}chat;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
        proxy_http_version 1.1;
    }

    # Rate limiting for login (prevents brute force)
    location ~* ^/web/(login|session/authenticate) {
        limit_req zone=login burst=5 nodelay;
        proxy_pass http://odoo${version};
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
        proxy_http_version 1.1;
    }

    # Static files with caching
    location ~* ^/[^/]+/static/.+\\.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        proxy_pass http://odoo${version};
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # API endpoints with rate limiting (prevents API abuse)
    location ~* ^/(xmlrpc|jsonrpc|api) {
        limit_req zone=api burst=10 nodelay;
        proxy_pass http://odoo${version};
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
        proxy_http_version 1.1;
    }

    # Main location
    location / {
        proxy_pass http://odoo${version};
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
        proxy_http_version 1.1;
    }

    # Security: Block sensitive files
    location ~* \\.(conf|log|py|pyc|pyo|bak|sql|db)\$ {
        deny all;
        return 404;
    }
}

EOF
    done

    # Default server block - catch-all for unmatched domains
    cat >> conf/nginx/conf.d/odoo.conf << EOF
# Default server - shows available instances (catch-all)
server {
    listen 80 default_server;
    server_name _;

    location / {
        return 200 "Odoo Multi-Version Proxy (Host-Based Routing)\\n\\nAvailable instances:\\n$(for v in "${VALID_VERSIONS[@]}"; do echo "- http://odoo${v}.${BASE_DOMAIN}:${NGINX_PORT}\\n"; done)\\n\\nNote: Access via subdomains (odoo16.domain.com, odoo17.domain.com, etc.)";
        add_header Content-Type text/plain;
    }
}
EOF

    print_status "Nginx configured on port ${NGINX_PORT} with HOST-BASED routing"
    print_status "Subdomains: $(for v in "${VALID_VERSIONS[@]}"; do echo -n "odoo${v}.${BASE_DOMAIN} "; done)"
else
    # No embedded Nginx - create host nginx template
    print_status "Creating host Nginx template for external proxy..."
    
    for version in "${VALID_VERSIONS[@]}"; do
        HOST_PORT=$((BASE_PORT + version - 16))
        
        cat > "conf/nginx-host-odoo${version}.conf" << EOF
# Nginx configuration for Odoo ${version}
# Copy to: /etc/nginx/sites-available/odoo${version}
# Enable: ln -s /etc/nginx/sites-available/odoo${version} /etc/nginx/sites-enabled/
# SSL: certbot --nginx -d yourdomain.com

upstream odoo${version} {
    server 127.0.0.1:${HOST_PORT};
}

upstream odoo${version}chat {
    server 127.0.0.1:$((HOST_PORT + 1000));
}

server {
    listen 80;
    server_name yourdomain.com;  # CHANGE THIS

    client_max_body_size 200M;
    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    # Logging
    access_log /var/log/nginx/odoo${version}.access.log;
    error_log /var/log/nginx/odoo${version}.error.log;

    # WebSocket/Longpolling
    location /websocket {
        proxy_pass http://odoo${version}chat;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
    }

    location /longpolling {
        proxy_pass http://odoo${version}chat;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
    }

    # Main location
    location / {
        proxy_pass http://odoo${version};
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
    }
}
EOF
    done
    
    print_success "Host Nginx templates created in conf/nginx-host-odoo*.conf"
fi

# Create nginx template for HTTP (before SSL)
cat > conf/nginx/odoo-http-template.conf << 'EOF'
# Odoo HTTP Configuration Template
# Copy this file and modify for your domain, then run certbot for SSL

# Upstream definitions
upstream odoo {
    server 127.0.0.1:8069;
}

upstream odoochat {
    server 127.0.0.1:8072;
}

# Rate limiting
limit_req_zone $binary_remote_addr zone=login:10m rate=5r/m;
limit_req_zone $binary_remote_addr zone=api:10m rate=20r/m;

# Map for WebSocket upgrade
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

# Map for CSP headers on static files
map $sent_http_content_type $content_type_csp {
    default "";
    ~image/ "default-src 'none'";
}

# Main server block
server {
    listen 80;
    server_name your-domain.com;  # CHANGE THIS

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Timeouts
    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    # Buffer sizes
    proxy_buffer_size 128k;
    proxy_buffers 4 256k;
    proxy_busy_buffers_size 256k;

    # Client settings
    client_max_body_size 200M;
    client_body_timeout 60s;
    client_header_timeout 60s;

    # Logging
    access_log /var/log/nginx/odoo.access.log;
    error_log /var/log/nginx/odoo.error.log;

    # Rate limiting for login
    location ~* ^/web/(login|session/authenticate) {
        limit_req zone=login burst=5 nodelay;
        proxy_pass http://odoo;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_redirect off;
    }

    # WebSocket/Gevent handling
    location /websocket {
        proxy_pass http://odoochat;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Real-IP $remote_addr;

        # WebSocket specific timeouts
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # Static files with caching
    location ~* ^/[^/]+/static/.+\.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        add_header Content-Security-Policy $content_type_csp;

        # Try to serve static files directly, fallback to Odoo
        try_files $uri @odoo;
    }

    # API endpoints with rate limiting
    location ~* ^/(xmlrpc|jsonrpc|api) {
        limit_req zone=api burst=10 nodelay;
        proxy_pass http://odoo;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_redirect off;
    }

    # Main location block
    location / {
        proxy_pass http://odoo;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_redirect off;
    }

    # Fallback for static files
    location @odoo {
        proxy_pass http://odoo;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_redirect off;
    }

    # Security: Block access to sensitive files
    location ~* \.(conf|log|py|pyc|pyo)$ {
        deny all;
        return 404;
    }

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/javascript
        application/xml+rss
        application/json
        image/svg+xml;
}
EOF

# Create performance tuning script.
# IMPORTANT: this helper mirrors the EXACT formulas used at deploy time (the
# unified tuning block in autodeploy-nginx.sh). If you change one, change both
# - a diverging helper recommends configs that disagree with what's deployed.
cat > conf/performance-tuner.sh << 'EOF'
#!/bin/bash
# Odoo Performance Tuning Helper
# Re-runs the deploy-time tuning math against current hardware and compares
# with what is actually deployed. Useful after a RAM/CPU upgrade to see what
# a redeploy would give you.

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

echo "🚀 Odoo Performance Tuning Helper"
echo

clamp() {
    local v=$1 lo=$2 hi=$3
    [ "$v" -lt "$lo" ] && v=$lo
    [ "$v" -gt "$hi" ] && v=$hi
    echo "$v"
}

# Detect system resources
CPU_CORES=$(nproc)
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')

# Number of deployed Odoo versions sharing this host (from docker-compose.yml)
COMPOSE_FILE="docker-compose.yml"
[ -f "$COMPOSE_FILE" ] || COMPOSE_FILE="../docker-compose.yml"
# grep -c prints the count but exits non-zero on 0 matches; '|| true' keeps
# set -e happy without corrupting the value
NUM_VERSIONS=$(grep -cE '^  odoo[0-9]+:' "$COMPOSE_FILE" 2>/dev/null || true)
case "$NUM_VERSIONS" in ''|0|*[!0-9]*) NUM_VERSIONS=1 ;; esac

# PgBouncer deployments decouple workers from the postgres connection budget
USE_PGBOUNCER=false
grep -qE '^  pgbouncer:' "$COMPOSE_FILE" 2>/dev/null && USE_PGBOUNCER=true

print_info "System Resources Detected:"
echo "  CPU Cores: $CPU_CORES"
echo "  Total RAM: ${TOTAL_RAM_MB}MB"
echo "  Odoo versions sharing host: $NUM_VERSIONS"
echo "  PgBouncer pooler: $USE_PGBOUNCER"
echo

# --- Same math as the deploy script ---
SHARED_BUFFERS=$((TOTAL_RAM_MB / 4))
[ "$SHARED_BUFFERS" -gt 16384 ] && SHARED_BUFFERS=16384

if [ "$TOTAL_RAM_MB" -lt 4096 ]; then
    WORKER_MEMORY_MB=512;  SOFT_LIMIT_MB=400
elif [ "$TOTAL_RAM_MB" -lt 8192 ]; then
    WORKER_MEMORY_MB=1024; SOFT_LIMIT_MB=800
else
    WORKER_MEMORY_MB=2048; SOFT_LIMIT_MB=1600
fi

MAX_CRON_THREADS=2
available_ram_mb=$(( TOTAL_RAM_MB * 80 / 100 ))
RESERVED_RAM=$(( 512 + SHARED_BUFFERS ))
odoo_ram_budget=$(( available_ram_mb - RESERVED_RAM ))
[ "$odoo_ram_budget" -lt 0 ] && odoo_ram_budget=0
max_workers_by_ram=$(( odoo_ram_budget / NUM_VERSIONS / SOFT_LIMIT_MB ))
max_workers_by_cpu=$(( (CPU_CORES * 2 + 1 + NUM_VERSIONS - 1) / NUM_VERSIONS ))
OPTIMAL_WORKERS=$(( max_workers_by_ram < max_workers_by_cpu ? max_workers_by_ram : max_workers_by_cpu ))
[ "$OPTIMAL_WORKERS" -lt 1 ] && OPTIMAL_WORKERS=0

if [ "$USE_PGBOUNCER" = "true" ]; then
    # Pooled: workers bounded by CPU/RAM only
    MAX_CONNECTIONS=$(clamp $(( CPU_CORES * 4 + 20 )) 100 500)
else
    PER_VERSION_CONNS=$(( OPTIMAL_WORKERS * 2 + MAX_CRON_THREADS + 8 ))
    MAX_CONNECTIONS=$(( PER_VERSION_CONNS * NUM_VERSIONS * 120 / 100 + 10 ))
    [ "$MAX_CONNECTIONS" -lt 100 ] && MAX_CONNECTIONS=100
    if [ "$MAX_CONNECTIONS" -gt 1000 ]; then
        MAX_CONNECTIONS=1000
        budget_per_version=$(( (MAX_CONNECTIONS - 10) * 100 / 120 / NUM_VERSIONS ))
        OPTIMAL_WORKERS=$(( (budget_per_version - MAX_CRON_THREADS - 8) / 2 ))
    fi
fi
DB_MAXCONN=$(clamp $(( OPTIMAL_WORKERS * 2 + 16 )) 64 256)

HARD_LIMIT_BYTES=$(( WORKER_MEMORY_MB * 1024 * 1024 ))
SOFT_LIMIT_BYTES=$(( SOFT_LIMIT_MB * 1024 * 1024 ))

print_info "Recommended per version (deploy-time formula):"
echo "  RAM limited:  $max_workers_by_ram workers"
echo "  CPU limited:  $max_workers_by_cpu workers"
echo "  workers = $OPTIMAL_WORKERS"
echo "  db_maxconn = $DB_MAXCONN"
echo "  limit_memory_hard = $HARD_LIMIT_BYTES  # ${WORKER_MEMORY_MB}MB"
echo "  limit_memory_soft = $SOFT_LIMIT_BYTES  # ${SOFT_LIMIT_MB}MB"
echo "  (postgres max_connections should be $MAX_CONNECTIONS)"
echo

# Compare with what is actually deployed
for conf in [0-9][0-9]-config/odoo.conf ../[0-9][0-9]-config/odoo.conf; do
    [ -f "$conf" ] || continue
    deployed_workers=$(grep -E '^workers *=' "$conf" | head -1 | tr -d ' ' | cut -d= -f2)
    deployed_maxconn=$(grep -E '^db_maxconn *=' "$conf" | head -1 | tr -d ' ' | cut -d= -f2)
    if [ "$deployed_workers" != "$OPTIMAL_WORKERS" ] || [ "$deployed_maxconn" != "$DB_MAXCONN" ]; then
        print_warning "$conf: deployed workers=$deployed_workers db_maxconn=$deployed_maxconn differ from recommendation - hardware may have changed since deploy"
    else
        print_success "$conf: matches current hardware recommendation"
    fi
done
echo

# Generate config snippet
cat > performance-config.conf << EOL
# Generated Performance Configuration (same formula as deploy time)
# System: ${CPU_CORES} cores, ${TOTAL_RAM_MB}MB RAM, ${NUM_VERSIONS} version(s)
# Generated: $(date)

[options]
# Performance settings
workers = $OPTIMAL_WORKERS
max_cron_threads = $MAX_CRON_THREADS
limit_memory_hard = $HARD_LIMIT_BYTES
limit_memory_soft = $SOFT_LIMIT_BYTES
limit_request = 8192
limit_time_cpu = 600
limit_time_real = 1200
db_maxconn = $DB_MAXCONN

# For production, also set:
# proxy_mode = True
# list_db = False
# log_level = warn
EOL

print_success "Configuration saved to: performance-config.conf"
print_info "Copy relevant settings to your odoo.conf files"
EOF

chmod +x conf/performance-tuner.sh

# Create enhanced management script
cat > manage.sh << 'SCRIPT_EOF'
#!/bin/bash

set -e

PROJECT_NAME=$(basename "$(pwd)")
AVAILABLE_VERSIONS=(VERSIONS_PLACEHOLDER)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }

show_usage() {
    echo "Usage: $0 [COMMAND] [VERSION]"
    echo
    echo "Commands:"
    echo "  start [VERSION]     Start all or specific version"
    echo "  stop [VERSION]      Stop all or specific version"
    echo "  restart [VERSION]   Restart services"
    echo "  logs [VERSION]      Show logs"
    echo "  shell VERSION       Open container shell"
    echo "  config VERSION      Edit config file"
    echo "  urls                Show access URLs"
    echo "  update VERSION      Update modules"
    echo "  scaffold MODULE VERSION  Create new module"
    echo "  clean               Remove everything (docker compose down -v)"
    echo "  reset               Clean + remove volumes completely"
    echo "  performance         Run performance analysis"
    echo "  production VERSION  Switch to production config"
    echo "  development VERSION Switch to development config"
    echo "  debug VERSION       Enable single-threaded debug mode"
    echo "  monitor [VERSION]   Show resource usage"
    echo "  backup [VERSION]    Backup database and filestore"
    echo "  restore FILE VERSION [FILESTORE_FILE]"
    echo "                      Restore from .sql, .sql.gz or Odoo manager .zip"
    echo "                      (.zip includes the filestore automatically)"
    echo "  rebuild [VERSION]   Update images: rebuilds baked images with --pull,"
    echo "                      or pulls latest official images, then restarts"
    echo "  init                Auto-initialize databases (first run)"
    echo
    echo "Available versions: ${AVAILABLE_VERSIONS[*]}"
}

rebuild_images() {
    local version=$1
    local services=()
    if [ -n "$version" ]; then
        validate_version "$version"
        services=("odoo$version")
    fi

    if grep -q "    build:" docker-compose.yml 2>/dev/null; then
        print_info "Rebuilding baked image(s) with latest base + requirements..."
        docker compose build --pull "${services[@]}"
    else
        print_info "Pulling latest official image(s)..."
        docker compose pull "${services[@]}"
    fi

    print_info "Restarting with updated image(s)..."
    docker compose up -d "${services[@]}"
    print_success "Images updated and services restarted"
}

validate_version() {
    local version=$1
    if [[ ! " ${AVAILABLE_VERSIONS[*]} " =~ " ${version} " ]]; then
        print_error "Invalid version '$version'. Available: ${AVAILABLE_VERSIONS[*]}"
        exit 1
    fi
}

start_services() {
    local version=$1
    if [ -z "$version" ]; then
        print_info "Starting all services..."
        docker compose up -d
    else
        validate_version "$version"
        print_info "Starting Odoo $version..."
        docker compose up -d db odoo$version
    fi
    print_success "Started"
    show_urls
}

stop_services() {
    local version=$1
    if [ -z "$version" ]; then
        print_info "Stopping all services..."
        docker compose down
    else
        validate_version "$version"
        print_info "Stopping Odoo $version..."
        docker compose stop odoo$version
    fi
    print_success "Stopped"
}

show_urls() {
    echo
    print_info "Access URLs:"
    
    # Check if using Nginx by looking for nginx service in docker-compose.yml
    if grep -q "nginx:" docker-compose.yml 2>/dev/null; then
        # Get Nginx port and base domain from nginx config
        nginx_port=$(grep -A 3 "nginx:" docker-compose.yml | grep -oP '"\K[0-9]+(?=:80")' | head -1)
        [[ -z "$nginx_port" ]] && nginx_port=80
        
        base_domain=$(grep "server_name odoo" conf/nginx/conf.d/odoo.conf 2>/dev/null | head -1 | sed 's/.*odoo[0-9]*\.\([^;]*\);/\1/' || echo "localhost")
        
        echo "   Nginx Proxy (Host-based routing)"
        echo ""
        for version in "${AVAILABLE_VERSIONS[@]}"; do
            if docker compose ps odoo$version --format json 2>/dev/null | grep -q '"State":"running"'; then
                status="[RUNNING]"
            else
                status="[STOPPED]"
            fi
            
            echo "  $status Odoo $version: http://odoo${version}.${base_domain}:${nginx_port}"
        done
        echo ""
        if [[ "$base_domain" == "127-0-0-1.sslip.io" ]]; then
            echo "  Using sslip.io wildcard DNS (no /etc/hosts required)"
        elif [[ "$base_domain" == "localhost" ]]; then
            echo "  Add to /etc/hosts:"
            for version in "${AVAILABLE_VERSIONS[@]}"; do
                echo "    sudo bash -c 'echo \"127.0.0.1 odoo${version}.localhost\" >> /etc/hosts'"
            done
        fi
    else
        # Direct access without Nginx
        local version_index=1
        for version in "${AVAILABLE_VERSIONS[@]}"; do
            # Get actual host port from docker-compose.yml
            host_port=$(grep -oP '"\K[0-9]+(?=:8069")' docker-compose.yml | sed -n "${version_index}p" 2>/dev/null || echo "N/A")
            host_longpoll_port=$(grep -oP '"\K[0-9]+(?=:8072")' docker-compose.yml | sed -n "${version_index}p" 2>/dev/null || echo "N/A")

            if docker compose ps odoo$version --format json 2>/dev/null | grep -q '"State":"running"'; then
                status="[RUNNING]"
            else
                status="[STOPPED]"
            fi
            
            if [[ "$host_port" != "N/A" ]]; then
                echo "  $status Odoo $version: http://localhost:$host_port"
                echo "     └─ Longpolling: http://localhost:$host_longpoll_port"
            else
                echo "  $status Odoo $version: Internal only (no host port)"
            fi
            (( version_index++ ))
        done
    fi
    
    echo ""
    echo "    PostgreSQL: internal only (service 'db', user: odoo, pass: odoo)"
    echo "    Master password (DB manager): see <version>-config/odoo.conf (admin_passwd)"
    echo "    First login: create a database via the web UI - you set the admin user there"
    echo
}

edit_config() {
    local version=$1
    if [ -z "$version" ]; then
        print_error "Version required: $0 config VERSION"
        exit 1
    fi
    validate_version "$version"

    local config_file="${version}-config/odoo.conf"
    if [ ! -f "$config_file" ]; then
        print_error "Config file not found: $config_file"
        exit 1
    fi

    ${EDITOR:-nano} "$config_file"
    print_info "Config updated. Restart container to apply changes:"
    print_info "  $0 restart $version"
}

update_modules() {
    local version=$1
    if [ -z "$version" ]; then
        print_error "Version required: $0 update VERSION"
        exit 1
    fi
    validate_version "$version"

    print_info "Updating module list for Odoo $version..."
    docker compose exec odoo$version odoo -u base --stop-after-init
    print_success "Module list updated"
}

scaffold_module() {
    local module=$1
    local version=$2

    if [ -z "$module" ] || [ -z "$version" ]; then
        print_error "Usage: $0 scaffold MODULE_NAME VERSION"
        exit 1
    fi

    validate_version "$version"

    print_info "Creating module '$module' for Odoo $version..."
    docker compose exec odoo$version odoo scaffold "$module" /mnt/custom-addons/
    print_success "Module '$module' created in ${version}-addons/custom/"
}

clean_all() {
    print_warning "This removes containers and volumes (clean start)"
    read -p "Continue? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        docker compose down -v
        print_success "Clean complete"
    fi
}

reset_all() {
    print_warning "This removes EVERYTHING including named volumes"
    read -p "Continue? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        docker compose down -v --remove-orphans
        # Remove named volumes
        for version in "${AVAILABLE_VERSIONS[@]}"; do
            docker volume rm "${PROJECT_NAME}_odoo${version}-data" 2>/dev/null || true
        done
        docker volume rm "${PROJECT_NAME}_db-data" 2>/dev/null || true
        print_success "Reset complete"
    fi
}

run_performance_analysis() {
    if [ -f "conf/performance-tuner.sh" ]; then
        print_info "Running performance analysis..."
        ./conf/performance-tuner.sh
    else
        print_error "Performance tuner not found. Run from project root."
        exit 1
    fi
}

switch_to_production() {
    local version=$1
    if [ -z "$version" ]; then
        print_error "Version required: $0 production VERSION"
        exit 1
    fi
    validate_version "$version"

    local prod_config="${version}-config/odoo-production.conf"
    local dev_config="${version}-config/odoo.conf"

    if [ ! -f "$prod_config" ]; then
        print_error "Production config not found: $prod_config"
        exit 1
    fi

    # Backup current config
    cp "$dev_config" "${dev_config}.backup"
    cp "$prod_config" "$dev_config"

    print_success "Switched Odoo $version to production config"
    print_warning "Remember to:"
    echo "  1. Set proper admin_passwd"
    echo "  2. Configure proxy_mode if using nginx"
    echo "  3. Restart container: $0 restart $version"
}

switch_to_development() {
    local version=$1
    if [ -z "$version" ]; then
        print_error "Version required: $0 development VERSION"
        exit 1
    fi
    validate_version "$version"

    local dev_backup="${version}-config/odoo.conf.backup"
    local dev_config="${version}-config/odoo.conf"

    if [ -f "$dev_backup" ]; then
        cp "$dev_backup" "$dev_config"
        print_success "Restored development config for Odoo $version"
    else
        print_warning "No backup found, manually edit: $dev_config"
        print_info "Development mode uses multi-processing (production-like)"
    fi
}

enable_debug_mode() {
    local version=$1
    if [ -z "$version" ]; then
        print_error "Version required: $0 debug VERSION"
        exit 1
    fi
    validate_version "$version"

    local config_file="${version}-config/odoo.conf"

    if [ ! -f "$config_file" ]; then
        print_error "Config file not found: $config_file"
        exit 1
    fi

    # Backup current config
    cp "$config_file" "${config_file}.backup"

    # Enable single-threaded debug mode
    sed -i 's/^workers = .*/workers = 0/' "$config_file"
    sed -i 's/^dev_mode = .*/dev_mode = reload/' "$config_file"
    sed -i 's/^log_level = .*/log_level = debug/' "$config_file"

    print_success "Enabled debug mode for Odoo $version"
    print_warning "Debug mode uses single-threaded processing"
    print_info "Restart container: $0 restart $version"
    print_info "Disable debug: $0 development $version"
}

monitor_resources() {
    local version=$1

    print_info "Resource Usage Monitor"
    echo

    if [ -z "$version" ]; then
        print_info "Overall system resources:"
        docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}"
    else
        validate_version "$version"
        print_info "Resources for Odoo $version:"
        docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}" "${PROJECT_NAME}-odoo${version}-1" "${PROJECT_NAME}-db-1" 2>/dev/null || \
        docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}" "${PROJECT_NAME}_odoo${version}_1" "${PROJECT_NAME}_db_1" 2>/dev/null || \
        print_error "Containers not running or not found"
    fi
}

backup_database() {
    local version=$1
    if [ -z "$version" ]; then
        print_error "Version required: $0 backup VERSION"
        exit 1
    fi
    validate_version "$version"

    local backup_dir="backups"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="${backup_dir}/odoo${version}_${timestamp}.sql"
    local filestore_backup="${backup_dir}/filestore_${version}_${timestamp}.tar.gz"

    mkdir -p "$backup_dir"

    print_info "Creating backup for Odoo $version (database + filestore)..."

    # Get database name
    local db_name="${PROJECT_NAME}_${version}"

    # Backup database
    if docker compose exec -T db pg_dump -U odoo -d "$db_name" | gzip > "${backup_file}.gz.tmp" 2>/dev/null; then
        mv "${backup_file}.gz.tmp" "${backup_file}.gz"
        print_success "Database backup: ${backup_file}.gz"
    else
        rm -f "${backup_file}.gz.tmp"
        print_warning "Database $db_name not found, trying default names..."
        for db_try in "${PROJECT_NAME}" "odoo" "postgres"; do
            if docker compose exec -T db psql -U odoo -lqt | cut -d \| -f 1 | grep -qw "$db_try"; then
                docker compose exec -T db pg_dump -U odoo -d "$db_try" | gzip > "${backup_file}.gz"
                print_success "Database backup (${db_try}): ${backup_file}.gz"
                break
            fi
        done
    fi

    # Backup filestore (attachments, documents, etc.)
    docker compose exec -T odoo$version tar -czf - -C /var/lib/odoo/filestore . > "$filestore_backup" 2>/dev/null || {
        print_warning "Filestore empty or not accessible"
        rm -f "$filestore_backup"
    }

    print_success "Backup complete:"
    echo "  Database: $backup_file"
    [ -f "$filestore_backup" ] && echo "  Filestore: $filestore_backup"
}

restore_database() {
    local backup_file=$1
    local version=$2
    local filestore_file=$3

    if [ -z "$backup_file" ] || [ -z "$version" ]; then
        print_error "Usage: $0 restore BACKUP_FILE VERSION [FILESTORE_BACKUP.tar.gz]"
        print_error "  BACKUP_FILE: .sql, .sql.gz, or .zip (Odoo database manager backup"
        print_error "  with dump.sql + filestore - filestore restored automatically)"
        exit 1
    fi

    if [ ! -f "$backup_file" ]; then
        print_error "Database backup file not found: $backup_file"
        exit 1
    fi

    validate_version "$version"

    local db_name="${PROJECT_NAME}_${version}"

    print_warning "This will replace the database and filestore for Odoo $version"
    read -p "Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 0
    fi

    # Odoo database manager zip: contains dump.sql (+ optional filestore/)
    local zip_tmp_dir=""
    if [[ "$backup_file" == *.zip ]]; then
        if ! command -v unzip > /dev/null 2>&1; then
            print_error "unzip is required to restore .zip backups (apt install unzip)"
            exit 1
        fi
        zip_tmp_dir=$(mktemp -d)
        print_info "Extracting Odoo backup zip..."
        unzip -q "$backup_file" -d "$zip_tmp_dir"
        if [ ! -f "$zip_tmp_dir/dump.sql" ]; then
            print_error "Invalid Odoo backup zip: dump.sql not found inside"
            rm -rf "$zip_tmp_dir"
            exit 1
        fi
    fi

    print_info "Stopping Odoo $version..."
    docker compose stop odoo$version

    print_info "Restoring database from $backup_file..."

    # Drop and recreate database
    docker compose exec -T db psql -U odoo -c "DROP DATABASE IF EXISTS $db_name;"
    docker compose exec -T db psql -U odoo -c "CREATE DATABASE $db_name OWNER odoo;"

    # Restore from backup (handling format)
    if [ -n "$zip_tmp_dir" ]; then
        docker compose exec -T db psql -U odoo -d "$db_name" < "$zip_tmp_dir/dump.sql"
    elif [[ "$backup_file" == *.gz ]]; then
        gunzip -c "$backup_file" | docker compose exec -T db psql -U odoo -d "$db_name"
    else
        docker compose exec -T db psql -U odoo -d "$db_name" < "$backup_file"
    fi

    # Restore filestore bundled in the zip (goes to filestore/<db_name>)
    if [ -n "$zip_tmp_dir" ] && [ -d "$zip_tmp_dir/filestore" ]; then
        print_info "Restoring filestore from zip..."
        docker compose run --rm -T --entrypoint sh odoo$version -c \
            "rm -rf /var/lib/odoo/filestore/$db_name && mkdir -p /var/lib/odoo/filestore/$db_name && tar -xf - -C /var/lib/odoo/filestore/$db_name" \
            < <(tar -C "$zip_tmp_dir/filestore" -cf - .)
        print_success "Filestore restored"
    fi

    # Restore separately-provided filestore archive (full filestore tree)
    if [ -n "$filestore_file" ] && [ -f "$filestore_file" ]; then
        print_info "Restoring filestore from $filestore_file..."
        docker compose run --rm -T --entrypoint sh odoo$version -c \
            "rm -rf /var/lib/odoo/filestore/* && tar -xzf - -C /var/lib/odoo/filestore" \
            < "$filestore_file"
        print_success "Filestore restored"
    fi

    [ -n "$zip_tmp_dir" ] && rm -rf "$zip_tmp_dir"

    print_info "Starting Odoo $version..."
    docker compose start odoo$version

    print_success "Restore complete"
}

run_initialization() {
    if [ -f "init-setup.sh" ]; then
        print_info "Running auto-initialization..."
        ./init-setup.sh
    else
        print_error "Initialization script not found. Run from project root."
        exit 1
    fi
}

case "$1" in
    start) start_services $2 ;;
    stop) stop_services $2 ;;
    restart)
        stop_services $2
        sleep 2
        start_services $2 ;;
    logs)
        if [ -z "$2" ]; then
            docker compose logs -f
        else
            validate_version "$2"
            docker compose logs -f odoo$2
        fi ;;
    shell)
        if [ -z "$2" ]; then
            print_error "Version required: $0 shell VERSION"
            exit 1
        fi
        validate_version "$2"
        docker compose exec odoo$2 /bin/bash ;;
    config) edit_config $2 ;;
    urls) show_urls ;;
    update) update_modules $2 ;;
    scaffold) scaffold_module $2 $3 ;;
    clean) clean_all ;;
    reset) reset_all ;;
    performance) run_performance_analysis ;;
    production) switch_to_production $2 ;;
    development) switch_to_development $2 ;;
    debug) enable_debug_mode $2 ;;
    monitor) monitor_resources $2 ;;
    backup) backup_database $2 ;;
    restore) restore_database $2 $3 $4 ;;
    rebuild) rebuild_images $2 ;;
    init) run_initialization ;;
    *) show_usage ;;
esac
SCRIPT_EOF

# Replace placeholder
sed -i "s/VERSIONS_PLACEHOLDER/${VALID_VERSIONS[*]}/g" manage.sh
chmod +x manage.sh

# Create comprehensive README
cat > README.md << EOF
# ${PROJECT_NAME} - Odoo Multi-Version (${ODOO_EDITION^})

## Quick Start
\`\`\`bash
./manage.sh start     # Start all versions
./manage.sh urls      # Show access URLs
./manage.sh config 17 # Edit Odoo 17 config
\`\`\`

## Access URLs
EOF

if [[ "$USE_NGINX" == "true" ]]; then
    echo "**Nginx Reverse Proxy (Host-Based Routing)**" >> README.md
    echo "" >> README.md
    for version in "${VALID_VERSIONS[@]}"; do
        echo "- **Odoo ${version}**: http://odoo${version}.${BASE_DOMAIN}:${NGINX_PORT}" >> README.md
    done
    echo "" >> README.md
    if [[ "$BASE_DOMAIN" == "127-0-0-1.sslip.io" ]]; then
        echo "**Wildcard DNS Configuration**" >> README.md
        echo "" >> README.md
        echo "Using sslip.io for automatic DNS resolution - no /etc/hosts configuration required." >> README.md
        echo "" >> README.md
        echo "DNS Resolution:" >> README.md
        for version in "${VALID_VERSIONS[@]}"; do
            echo "- \`odoo${version}.127-0-0-1.sslip.io\` resolves to \`127.0.0.1\`" >> README.md
        done
    elif [[ "$BASE_DOMAIN" == "localhost" ]]; then
        echo "**Add to /etc/hosts:**" >> README.md
        echo "\`\`\`bash" >> README.md
        echo "sudo bash -c 'cat >> /etc/hosts << EOF" >> README.md
        for version in "${VALID_VERSIONS[@]}"; do
            echo "127.0.0.1 odoo${version}.localhost" >> README.md
        done
        echo "EOF'" >> README.md
        echo "\`\`\`" >> README.md
    fi
else
    echo "**Direct access to Odoo instances:**" >> README.md
    echo "" >> README.md
    for version in "${VALID_VERSIONS[@]}"; do
        host_port=$((BASE_PORT + version - 16))
        host_longpoll_port=$((host_port + 1000))
        echo "- **Odoo ${version}**: http://localhost:${host_port}" >> README.md
        echo "  - Longpolling: http://localhost:${host_longpoll_port}" >> README.md
    done
fi

echo "" >> README.md

# Docs strings depending on requirements strategy
if [[ "$BAKE_IMAGE" == "true" ]]; then
    REQ_DOC_PATH="{VERSION}-build/requirements.txt"
    REQ_DOC_HINT="baked into image, apply with ./manage.sh rebuild VERSION"
    REBUILD_DOC_HINT="rebuilds baked images with latest base + requirements"
else
    REQ_DOC_PATH="{VERSION}-config/requirements.txt"
    REQ_DOC_HINT="installed at container start, apply with ./manage.sh restart VERSION"
    REBUILD_DOC_HINT="pulls latest official images and restarts"
fi

if [[ "$USE_PGBOUNCER" == "true" ]]; then
    PGB_README_LINE="- **PgBouncer**: service \`pgbouncer\` - Odoo connects through it (transaction pooling; the bus/LISTEN traffic on the \`postgres\` DB is session-pooled automatically)"
else
    PGB_README_LINE=""
fi

cat >> README.md << EOF
**Database:**
- **PostgreSQL**: internal only, service \`db\` (odoo/odoo)
${PGB_README_LINE}

**Credentials:**
- Master password (database manager): \`admin_passwd\` in \`{VERSION}-config/odoo.conf\`
- Odoo admin user: created by YOU when you create a database via the web UI

## Configuration Features
- ✅ **Custom entrypoints** for proper config loading
- ✅ **Development mode** with auto-reload
- ✅ **Custom addons paths** properly configured
- ✅ **Requirements.txt** support for additional packages
- ✅ **Logrotate** configuration included

## Commands
| Command | Description |
|---------|-------------|
| \`./manage.sh start [VERSION]\` | Start services |
| \`./manage.sh config VERSION\` | Edit config file |
| \`./manage.sh scaffold MODULE VERSION\` | Create new module |
| \`./manage.sh update VERSION\` | Update module list |
| \`./manage.sh shell VERSION\` | Container shell |
| \`./manage.sh clean\` | Clean restart |

## Adding Custom Modules
\`\`\`bash
# Method 1: Use scaffold
./manage.sh scaffold my_module 17

# Method 2: Copy existing module
cp -r /path/to/my_module ./17-addons/custom/
./manage.sh restart 17
\`\`\`

## Configuration Files
Each version has its own complete config:
- \`{VERSION}-config/odoo.conf\` - Main configuration
- \`{VERSION}-config/entrypoint.sh\` - Custom entrypoint
- \`${REQ_DOC_PATH}\` - Python packages (${REQ_DOC_HINT})
- \`{VERSION}-config/logrotate\` - Log rotation

## Updating Images
\`\`\`bash
./manage.sh rebuild      # All versions: ${REBUILD_DOC_HINT}
./manage.sh rebuild 17   # Single version
\`\`\`

## Debugging
\`\`\`bash
./manage.sh logs 17        # View logs
./manage.sh shell 17       # Container shell
./manage.sh config 17      # Edit config
\`\`\`
EOF

# Create .gitignore
cat > .gitignore << 'EOF'
# Logs
*.log

# IDE
.vscode/
.idea/
*.swp

# OS
.DS_Store
Thumbs.db

# Python
__pycache__/
*.pyc
*.pyo

# Enterprise addons (uncomment to exclude from git)
# */enterprise/
# */industry/
EOF

print_header "Deployment Configuration Complete"
print_success "Project: ${PROJECT_NAME}"
print_success "Versions: ${VALID_VERSIONS[*]}"
print_success "Edition: ${ODOO_EDITION^}"
echo
print_status "Configuration Summary:"
echo "  - Custom entrypoints with proper config loading"
echo "  - PostgreSQL ${PG_VERSION} optimized for ${CPU_CORES} cores, ${TOTAL_RAM_MB}MB RAM"
if [ "$PG_VERSION" -ge 18 ]; then
    echo "  - PostgreSQL async I/O: io_method=worker, io_workers=${IO_WORKERS}"
fi
echo "  - Parallel query: up to ${MAX_PARALLEL_PER_GATHER} workers/query from a pool of ${MAX_PARALLEL_WORKERS}"
if [[ "$USE_PGBOUNCER" == "true" ]]; then
    echo "  - PgBouncer: transaction pooling (${PGB_DEFAULT_POOL_SIZE}/db pool, ${PGB_MAX_CLIENT_CONN} max clients), bus in session mode"
fi
echo "  - Connection budget: max_connections=${MAX_CONNECTIONS}, db_maxconn=${DB_MAXCONN} (${NUM_VERSIONS} version(s))"
echo "  - Odoo workers per version: ${DEV_WORKERS} (development) / ${PROD_WORKERS} (production)"
echo "  - SELinux-compatible volume mounts"
if [[ "$BAKE_IMAGE" == "true" ]]; then
    echo "  - Python requirements baked into custom images ({VERSION}-build/)"
    echo "    Update: edit requirements.txt, then './manage.sh rebuild VERSION'"
else
    echo "  - Python requirements installed at container start ({VERSION}-config/)"
    echo "    Update: edit requirements.txt, then './manage.sh restart VERSION'"
fi
if [[ "$USE_NGINX" == "true" ]]; then
    echo "  - Nginx reverse proxy on port ${NGINX_PORT}"
    echo
    print_status "Access URLs:"
    if [[ "$DOMAIN_MODE" == "custom" ]]; then
        for version in "${VALID_VERSIONS[@]}"; do
            echo "  Odoo ${version}: http://${CUSTOM_DOMAINS[$version]}:${NGINX_PORT}"
        done
        echo
        print_warning "Ensure DNS records point to your server IP:"
        for version in "${VALID_VERSIONS[@]}"; do
            echo "  ${CUSTOM_DOMAINS[$version]} → $(hostname -I | awk '{print $1}')"
        done
    else
        if [ ${#VALID_VERSIONS[@]} -eq 1 ]; then
            echo "  http://${BASE_DOMAIN}:${NGINX_PORT}"
        else
            for version in "${VALID_VERSIONS[@]}"; do
                echo "  http://odoo${version}.${BASE_DOMAIN}:${NGINX_PORT}"
            done
        fi
        
        if [[ "$BASE_DOMAIN" == "127-0-0-1.sslip.io" ]]; then
            echo
            print_status "Using sslip.io wildcard DNS (no /etc/hosts required)"
        elif [[ "$BASE_DOMAIN" == "localhost" ]] && [ ${#VALID_VERSIONS[@]} -gt 1 ]; then
            echo
            print_warning "Add to /etc/hosts:"
            for version in "${VALID_VERSIONS[@]}"; do
                echo "  sudo bash -c 'echo \"127.0.0.1 odoo${version}.localhost\" >> /etc/hosts'"
            done
        fi
    fi
fi
echo
print_info "Next Steps:"
echo "  cd ${PROJECT_NAME}"
echo "  ./manage.sh start"
echo "  ./manage.sh urls     # Display access information"
echo
print_warning "Database Naming Convention (REQUIRED):"
echo "  Each version requires the version number in the database name to prevent conflicts"
for version in "${VALID_VERSIONS[@]}"; do
    echo "  - Odoo ${version}: Include '${version}' in name (e.g., test${version}, prod${version}, ${version}_db, my_${version}_app)"
done
echo "  This prevents version conflicts and cron job interference"
