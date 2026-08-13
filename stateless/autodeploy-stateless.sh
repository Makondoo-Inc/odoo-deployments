#!/bin/bash

#===============================================================================
# STATELESS ODOO DEPLOYMENT SCRIPT - PRODUCTION GRADE
#===============================================================================
#
# Purpose: Deploy a fully stateless, auto-scaling Odoo instance that maximizes
#          100% of server resources through intelligent architecture
#
# Architecture:
#   - Stateless Odoo workers (web + chat separated, web horizontally scalable)
#   - PgBouncer connection pooling (session mode)
#   - PostgreSQL optimized for massive concurrency
#   - MinIO S3-compatible object storage for filestore
#   - Redis session store via camptocamp session_redis module (redis db 1)
#   - Production-grade Nginx proxy (port 8080)
#   - Auto-downloads and configures OCA storage + session_redis modules
#
# Features:
#   - Dynamic resource allocation based on system specs
#   - Zero user configuration required
#   - SELinux compatible
#   - Production-ready out of the box
#   - Tmpfs data_dir for true statelessness (temp files live in RAM)
#   - Idempotent dependency installation
#   - Pinned image tags for reproducible deploys
#   - Secrets injected via .env (compose interpolation), not baked in YAML
#
# Architectural Trade-offs & Design Decisions:
#
#   1. PgBouncer Session Mode (not Transaction Mode)
#      - WHY: Works with any Odoo version, no code patches needed
#      - TRADE-OFF: Caps at ~100-200 concurrent connections vs thousands
#      - SCALE PATH: For 128+ cores, switch to transaction mode + bus_alt_connection
#
#   2. Single Deployment (not Multi-Role)
#      - WHY: Simplicity - one script, one deployment
#      - TRADE-OFF: Cron runs on web workers (acceptable for <64 cores)
#      - SCALE PATH: Run script multiple times for cron-only, analytics-only workers
#
#   3. No Varnish/CDN Layer
#      - WHY: Nginx caching sufficient for most deployments (<1000 users)
#      - TRADE-OFF: Asset storms can hit Python workers
#      - SCALE PATH: Add Varnish or CDN when needed
#
#   4. Runtime Dependency Installation (with idempotent check)
#      - WHY: Simplicity - no custom image building required
#      - TRADE-OFF: First boot slower (~30s), not fully immutable
#      - SCALE PATH: Build custom Odoo image with baked-in dependencies
#
#   5. No Table Partitioning / Read Replicas
#      - WHY: Out of scope - these are operational concerns, not deployment
#      - SCALE PATH: Implement at application/DBA level when needed
#
# Target: 4-64 cores, scales to 128 cores with documented modifications
#
# Author: ghoat-debug
# License: MIT
#===============================================================================

set -e
set -o pipefail

#===============================================================================
# COLORS AND FORMATTING
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

print_header() { echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"; echo -e "${CYAN}║  $1${NC}"; echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"; }
print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_info() { echo -e "${BLUE}[ℹ]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[⚠]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_input() { echo -e "${MAGENTA}[?]${NC} $1"; }

#===============================================================================
# SYSTEM RESOURCE DETECTION
#===============================================================================

detect_system_resources() {
    print_header "Detecting System Resources"

    TOTAL_CORES=$(nproc)
    TOTAL_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
    TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')

    print_info "CPU Cores: ${TOTAL_CORES}"
    print_info "Total RAM: ${TOTAL_RAM_GB}GB (${TOTAL_RAM_MB}MB)"

    # Resource Distribution (percentages)
    PG_RAM_MB=$((TOTAL_RAM_MB * 30 / 100))           # 30% to PostgreSQL
    REDIS_RAM_MB=$((TOTAL_RAM_MB * 5 / 100))         # 5% to Redis
    MINIO_RAM_MB=$((TOTAL_RAM_MB * 5 / 100))         # 5% to MinIO
    OS_BUFFER_MB=$((TOTAL_RAM_MB * 10 / 100))        # 10% OS overhead
    ODOO_POOL_MB=$((TOTAL_RAM_MB * 50 / 100))        # 50% to Odoo workers

    print_status "Resource Allocation:"
    echo "  PostgreSQL: ${PG_RAM_MB}MB (30%)"
    echo "  Redis: ${REDIS_RAM_MB}MB (5%)"
    echo "  MinIO: ${MINIO_RAM_MB}MB (5%)"
    echo "  OS Buffer: ${OS_BUFFER_MB}MB (10%)"
    echo "  Odoo Workers: ${ODOO_POOL_MB}MB (50%)"

    # Worker Calculation
    WORKER_RAM_MB=1024  # 1GB per worker (safe estimate)
    MAX_WORKERS_RAM=$((ODOO_POOL_MB / WORKER_RAM_MB))
    MAX_WORKERS_CPU=$((TOTAL_CORES * 2 + 1))

    # Use the smaller of the two to avoid resource exhaustion
    if [ $MAX_WORKERS_RAM -lt $MAX_WORKERS_CPU ]; then
        ACTUAL_HTTP_WORKERS=$MAX_WORKERS_RAM
    else
        ACTUAL_HTTP_WORKERS=$MAX_WORKERS_CPU
    fi

    # Ensure minimum of 2 workers
    if [ $ACTUAL_HTTP_WORKERS -lt 2 ]; then
        ACTUAL_HTTP_WORKERS=2
    fi

    # PgBouncer pool sizing
    # Session mode doesn't pool, so this is just for PgBouncer's client connection limit
    DEFAULT_POOL_SIZE=$((ACTUAL_HTTP_WORKERS + 10))

    # PostgreSQL max_connections calculation for session mode
    # Formula: (web workers * 2 + 5) + (chat: 10) + (buffer for multiple DBs: 50) + (system: 10)
    # This ensures enough connections for multiple databases
    WEB_DB_MAXCONN=$((ACTUAL_HTTP_WORKERS * 2 + 2 + 5))
    CHAT_DB_MAXCONN=10
    PG_MAX_CONNECTIONS=$(( (WEB_DB_MAXCONN + CHAT_DB_MAXCONN) * 3 + 10 ))

    # Ensure minimum of 100 connections
    if [ $PG_MAX_CONNECTIONS -lt 100 ]; then
        PG_MAX_CONNECTIONS=100
    fi

    # PostgreSQL tuning calculations
    PG_SHARED_BUFFERS=$((PG_RAM_MB * 25 / 100))      # 25% of PG allocation
    PG_EFFECTIVE_CACHE=$((PG_RAM_MB * 75 / 100))     # 75% of PG allocation
    PG_MAINTENANCE_WORK_MEM=$((PG_RAM_MB / 16))      # ~6% of PG allocation
    PG_WORK_MEM=$((PG_RAM_MB / (PG_MAX_CONNECTIONS * 4)))  # Per connection

    # Floor work_mem at 4MB - integer division on small hosts can hit 0,
    # which is below PostgreSQL's minimum (64kB) and produces bad plans anyway
    if [ $PG_WORK_MEM -lt 4 ]; then
        PG_WORK_MEM=4
    fi

    # Parallel workers
    PG_MAX_PARALLEL_WORKERS=$TOTAL_CORES
    PG_MAX_PARALLEL_PER_GATHER=$((TOTAL_CORES / 4))
    if [ $PG_MAX_PARALLEL_PER_GATHER -lt 2 ]; then
        PG_MAX_PARALLEL_PER_GATHER=2
    fi

    # Autovacuum workers - scale with cores for high-core systems
    PG_AUTOVACUUM_WORKERS=$((TOTAL_CORES / 8))
    if [ $PG_AUTOVACUUM_WORKERS -lt 4 ]; then
        PG_AUTOVACUUM_WORKERS=4
    fi
    if [ $PG_AUTOVACUUM_WORKERS -gt 16 ]; then
        PG_AUTOVACUUM_WORKERS=16  # Cap at 16 to avoid overhead
    fi

    print_success "Calculated Configuration:"
    echo "  HTTP Workers: ${ACTUAL_HTTP_WORKERS}"
    echo "  Odoo web db_maxconn: ${WEB_DB_MAXCONN}"
    echo "  Odoo chat db_maxconn: ${CHAT_DB_MAXCONN}"
    echo "  PgBouncer client limit: ${DEFAULT_POOL_SIZE}"
    echo "  PostgreSQL max_connections: ${PG_MAX_CONNECTIONS}"
    echo "  PostgreSQL autovacuum_workers: ${PG_AUTOVACUUM_WORKERS}"
    echo "  PostgreSQL shared_buffers: ${PG_SHARED_BUFFERS}MB"
    echo "  PostgreSQL work_mem: ${PG_WORK_MEM}MB"
    echo ""
}

#===============================================================================
# WELCOME AND PROJECT SETUP
#===============================================================================

clear
cat << "EOF"
╔═══════════════════════════════════════════════════════════════════════════╗
║                                                                           ║
║   ███████╗████████╗ █████╗ ████████╗███████╗██╗     ███████╗███████╗███████╗
║   ██╔════╝╚══██╔══╝██╔══██╗╚══██╔══╝██╔════╝██║     ██╔════╝██╔════╝██╔════╝
║   ███████╗   ██║   ███████║   ██║   █████╗  ██║     █████╗  ███████╗███████╗
║   ╚════██║   ██║   ██╔══██║   ██║   ██╔══╝  ██║     ██╔══╝  ╚════██║╚════██║
║   ███████║   ██║   ██║  ██║   ██║   ███████╗███████╗███████╗███████║███████║
║   ╚══════╝   ╚═╝   ╚═╝  ╚═╝   ╚═╝   ╚══════╝╚══════╝╚══════╝╚══════╝╚══════╝
║                                                                           ║
║              ODOO DEPLOYMENT - PRODUCTION GRADE STATELESS                ║
║                                                                           ║
╚═══════════════════════════════════════════════════════════════════════════╝

EOF

echo -e "${CYAN}Features:${NC}"
echo "  ✓ Stateless architecture (no local filestore)"
echo "  ✓ Auto-scaling workers based on system resources"
echo "  ✓ PgBouncer session-mode pooling (safe for CREATE DATABASE)"
echo "  ✓ MinIO S3-compatible object storage"
echo "  ✓ Redis session management (session_redis module)"
echo "  ✓ Separated web/chat containers"
echo "  ✓ OCA storage + session_redis auto-downloaded"
echo ""

# Detect system resources first
detect_system_resources

# Get project name
print_input "Enter project name:"
read -r PROJECT_NAME

# Sanitize project name
PROJECT_NAME=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')

if [[ -z "$PROJECT_NAME" ]]; then
    print_error "Project name cannot be empty!"
    exit 1
fi

# Check if directory exists
if [ -d "$PROJECT_NAME" ]; then
    print_warning "Directory '$PROJECT_NAME' already exists. Overwrite? (y/N):"
    read -r OVERWRITE
    if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
        print_info "Deployment cancelled."
        exit 0
    fi
    rm -rf "$PROJECT_NAME"
fi

# Odoo version selection
print_input "Select Odoo version (16/17/18/19) [19]:"
read -r ODOO_VERSION
[[ -z "$ODOO_VERSION" ]] && ODOO_VERSION=19

# Validate version
if [[ ! "$ODOO_VERSION" =~ ^(16|17|18|19)$ ]]; then
    print_error "Invalid Odoo version. Must be 16, 17, 18, or 19."
    exit 1
fi

# PostgreSQL version selection (recommended: 17 for Odoo <=18, 18 for Odoo 19)
PG_VERSION_DEFAULT=17
[ "$ODOO_VERSION" -ge 19 ] && PG_VERSION_DEFAULT=18
print_input "PostgreSQL version (15/16/17/18) [${PG_VERSION_DEFAULT}]:"
read -r PG_VERSION
[[ -z "$PG_VERSION" ]] && PG_VERSION=$PG_VERSION_DEFAULT
if [[ ! "$PG_VERSION" =~ ^(15|16|17|18)$ ]]; then
    print_error "Invalid PostgreSQL version. Must be 15, 16, 17, or 18."
    exit 1
fi
# postgres:18+ moved its volume root to /var/lib/postgresql (not .../data)
if [ "$PG_VERSION" -ge 18 ]; then
    PG_VOLUME_MOUNT="postgres-data:/var/lib/postgresql:Z"
    PG_DATA_ENV_LINE=""
else
    PG_VOLUME_MOUNT="postgres-data:/var/lib/postgresql/data:Z"
    PG_DATA_ENV_LINE="      PGDATA: /var/lib/postgresql/data/pgdata"
fi

# Edition selection
print_input "Edition? (1) Community (2) Enterprise [1]:"
read -r EDITION_CHOICE
ODOO_EDITION=$([[ "$EDITION_CHOICE" == "2" ]] && echo "enterprise" || echo "community")

# Enterprise source cannot be downloaded automatically (requires subscription).
# We wire up the mount + addons_path; the user drops the source in addons/enterprise.
if [ "$ODOO_EDITION" = "enterprise" ]; then
    print_warning "Enterprise selected: place the Odoo Enterprise ${ODOO_VERSION}.0 source in addons/enterprise/"
    print_warning "(git clone git@github.com:odoo/enterprise.git -b ${ODOO_VERSION}.0 addons/enterprise)"
    ENTERPRISE_ADDONS_PREFIX="/mnt/enterprise,"
    ENTERPRISE_VOLUME_LINE="      - ./addons/enterprise:/mnt/enterprise:ro"
else
    ENTERPRISE_ADDONS_PREFIX=""
    ENTERPRISE_VOLUME_LINE=""
fi

#-------------------------------------------------------------------------------
# PINNED IMAGE TAGS (reproducible deploys - bump deliberately, not via :latest)
#-------------------------------------------------------------------------------
PGBOUNCER_IMAGE="edoburu/pgbouncer:v1.25.2-p0"
# Pin MinIO before community console removals; bump deliberately.
MINIO_IMAGE="minio/minio:RELEASE.2024-12-18T13-15-44Z"
MC_IMAGE="minio/mc:RELEASE.2024-11-21T17-21-54Z"
REDIS_IMAGE="redis:7.4-alpine"
NGINX_IMAGE="nginx:1.27-alpine"

# pip on Debian bookworm images (Odoo 18/19) enforces PEP 668 and needs
# --break-system-packages; the flag doesn't exist on the older pip shipped
# with Odoo 16 (bullseye) / 17 (ubuntu jammy) images.
if [ "$ODOO_VERSION" -ge 18 ]; then
    PIP_INSTALL_FLAGS="--no-cache-dir --break-system-packages"
else
    PIP_INSTALL_FLAGS="--no-cache-dir"
fi

# Generate secure passwords
print_info "Generating secure passwords..."
DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
ADMIN_PASSWD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
MINIO_ROOT_USER="minioadmin"
MINIO_ROOT_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)

print_success "Project Configuration:"
echo "  Name: ${PROJECT_NAME}"
echo "  Odoo Version: ${ODOO_VERSION}.0"
echo "  Edition: ${ODOO_EDITION}"
echo "  PostgreSQL: ${PG_VERSION}"
echo "  HTTP Workers: ${ACTUAL_HTTP_WORKERS}"
echo ""

print_warning "IMPORTANT: Save these credentials securely!"
echo "  Database Password: ${DB_PASSWORD}"
echo "  Odoo Master Password: ${ADMIN_PASSWD}"
echo "  MinIO Root User: ${MINIO_ROOT_USER}"
echo "  MinIO Root Password: ${MINIO_ROOT_PASSWORD}"
echo ""

print_input "Press Enter to continue..."
read -r

#===============================================================================
# CREATE PROJECT STRUCTURE
#===============================================================================

print_header "Creating Project Structure"

mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# Create directory structure
mkdir -p config/{odoo,postgresql,pgbouncer,nginx,redis}
mkdir -p addons/{custom,oca-storage}
mkdir -p data/{postgres,minio}
mkdir -p logs/{odoo-web,odoo-chat,nginx,postgres}
mkdir -p scripts

# Set proper permissions for log directories
# PostgreSQL runs as user 70 (postgres) in Alpine image
# Odoo runs as user 101 (odoo)
# Nginx runs as user 101 (nginx)
chmod -R 777 logs/  # Allow all containers to write logs

print_status "Project structure created with proper permissions"


#===============================================================================
# DOWNLOAD OCA STORAGE MODULES
#===============================================================================

print_header "Downloading OCA Modules with Dependencies"

# Determine OCA branch based on Odoo version
OCA_BRANCH="${ODOO_VERSION}.0"

print_info "Cloning OCA repositories (branch: ${OCA_BRANCH})..."

# Clone OCA server-env repository (required dependency for fs_storage)
print_info "Cloning OCA server-env repository..."
if git clone --depth 1 --branch "$OCA_BRANCH" https://github.com/OCA/server-env.git addons/oca-temp-server-env 2>/dev/null; then
    print_status "OCA server-env repository cloned"
else
    print_error "Failed to clone OCA server-env repository"
    exit 1
fi

# Clone OCA storage repository
print_info "Cloning OCA storage repository..."
if git clone --depth 1 --branch "$OCA_BRANCH" https://github.com/OCA/storage.git addons/oca-temp-storage 2>/dev/null; then
    print_status "OCA storage repository cloned"
else
    print_error "Failed to clone OCA storage repository"
    rm -rf addons/oca-temp-server-env
    exit 1
fi

# Clone camptocamp odoo-cloud-platform (session_redis - real Redis session store).
# No 19.0 branch yet: use 18.0 for Odoo 18/19 (shim applied below for 19).
if [ "$ODOO_VERSION" -ge 18 ]; then
    CLOUD_PLATFORM_BRANCH="18.0"
elif [ "$ODOO_VERSION" -eq 17 ]; then
    CLOUD_PLATFORM_BRANCH="17.0"
else
    CLOUD_PLATFORM_BRANCH="16.0"
fi
print_info "Cloning camptocamp odoo-cloud-platform (branch: ${CLOUD_PLATFORM_BRANCH})..."
if git clone --depth 1 --branch "$CLOUD_PLATFORM_BRANCH" https://github.com/camptocamp/odoo-cloud-platform.git addons/oca-temp-cloud-platform 2>/dev/null; then
    print_status "odoo-cloud-platform repository cloned"
else
    print_error "Failed to clone odoo-cloud-platform repository (branch ${CLOUD_PLATFORM_BRANCH})"
    rm -rf addons/oca-temp-server-env addons/oca-temp-storage
    exit 1
fi

# Extract required modules with dependencies
print_info "Extracting required modules and dependencies..."

# From server-env: Required by fs_storage
# Note: base_sparse_field is in Odoo core, not OCA
SERVER_ENV_MODULES=(
    "server_environment"
)

# From storage: Core stateless modules for Odoo 19.0
# Note: fs_file and fs_image are unported (still on 18.0), not available for 19.0
STORAGE_MODULES=(
    "fs_storage"
    "fs_attachment"
    "fs_attachment_s3"
)

# Copy server-env modules
for module in "${SERVER_ENV_MODULES[@]}"; do
    if [ -d "addons/oca-temp-server-env/$module" ]; then
        cp -r "addons/oca-temp-server-env/$module" addons/oca-storage/
        print_status "Copied dependency: $module"
    else
        print_error "Module $module not found in server-env repository"
        rm -rf addons/oca-temp-server-env addons/oca-temp-storage
        exit 1
    fi
done

# From odoo-cloud-platform: real Redis session store (loaded server-wide)
CLOUD_PLATFORM_MODULES=(
    "session_redis"
)

# Copy storage modules
for module in "${STORAGE_MODULES[@]}"; do
    if [ -d "addons/oca-temp-storage/$module" ]; then
        cp -r "addons/oca-temp-storage/$module" addons/oca-storage/
        print_status "Copied module: $module"
    else
        print_error "Module $module not found in storage repository"
        rm -rf addons/oca-temp-server-env addons/oca-temp-storage addons/oca-temp-cloud-platform
        exit 1
    fi
done

# Copy cloud-platform modules
for module in "${CLOUD_PLATFORM_MODULES[@]}"; do
    if [ -d "addons/oca-temp-cloud-platform/$module" ]; then
        cp -r "addons/oca-temp-cloud-platform/$module" addons/oca-storage/
        print_status "Copied module: $module"
    else
        print_error "Module $module not found in odoo-cloud-platform repository"
        rm -rf addons/oca-temp-server-env addons/oca-temp-storage addons/oca-temp-cloud-platform
        exit 1
    fi
done

# Odoo 19 API shim for session_redis (Camptocamp still on 18.0):
# - rotate() gained a soft= kwarg
# - delete_old_sessions() is called by the filesystem store path in Odoo 19
if [ "$ODOO_VERSION" -ge 19 ]; then
    print_info "Applying Odoo 19 compatibility shim to session_redis..."
    sed -i 's/"version": "18.0.1.0.0"/"version": "19.0.1.0.0"/' addons/oca-storage/session_redis/__manifest__.py
    python3 - <<'PY'
from pathlib import Path
path = Path("addons/oca-storage/session_redis/session.py")
text = path.read_text()
old = '''    def rotate(self, session, env):
        self.delete(session)
        session.sid = self.generate_key()
        if session.uid and env:
            session.session_token = security.compute_session_token(session, env)
        self.save(session)

    def vacuum(self, *args, **kwargs):
        """Do not garbage collect the sessions

        Redis keys are automatically cleaned at the end of their
        expiration.
        """
        return None
'''
new = '''    def rotate(self, session, env, soft=False):
        # soft=True (Odoo 19): keep a recoverable identity half on disk stores.
        # Redis has no partial-key semantics; hard-rotate is the safe equivalent.
        self.delete(session)
        session.sid = self.generate_key()
        if session.uid and env:
            session.session_token = security.compute_session_token(session, env)
        session.should_rotate = False
        self.save(session)

    def delete_old_sessions(self, session):
        # Filesystem store GC hook (Odoo 19). Redis TTLs already expire keys.
        if isinstance(session, dict) or hasattr(session, "get"):
            if "gc_previous_sessions" in session:
                try:
                    del session["gc_previous_sessions"]
                    self.save(session)
                except Exception:
                    pass

    def vacuum(self, *args, **kwargs):
        """Do not garbage collect the sessions

        Redis keys are automatically cleaned at the end of their
        expiration.
        """
        return None
'''
if old not in text:
    raise SystemExit("session_redis rotate() block not found - upstream changed, update shim")
path.write_text(text.replace(old, new))
print("session_redis Odoo 19 shim applied")
PY
fi

# Consolidate Python dependencies from all modules
print_info "Consolidating Python dependencies..."
cat > addons/oca-storage/requirements.txt << 'PYREQ'
# Consolidated Python dependencies for OCA storage modules
# Generated automatically - do not edit manually

# Base dependencies (required by Odoo module system)
packaging>=20.0

# fs_storage dependencies
fsspec>=2024.5.0

# fs_attachment_s3 dependencies (S3/MinIO support)
s3fs>=2024.5.0
boto3>=1.26.0
botocore>=1.29.0
aiobotocore>=2.5.0

# fs_attachment external deps
python-slugify>=8.0.0

# session_redis dependency (Redis session store)
redis>=4.5.0

# Additional common dependencies
python-dateutil>=2.8.0
PYREQ

print_status "Created consolidated requirements.txt"

# Clean up temp directories
rm -rf addons/oca-temp-server-env addons/oca-temp-storage addons/oca-temp-cloud-platform

print_success "OCA storage modules ready"

#===============================================================================
# GENERATE DOCKER COMPOSE FILE
#===============================================================================

print_header "Generating Docker Compose Configuration"

cat > docker-compose.yml << EOF
#===============================================================================
# STATELESS ODOO DEPLOYMENT - DOCKER COMPOSE
#===============================================================================
# Project: ${PROJECT_NAME}
# Odoo Version: ${ODOO_VERSION}.0
# Generated: $(date)
# Architecture: Stateless with PgBouncer, Redis, MinIO
#
# Secrets are NOT stored in this file - they are interpolated from .env
# (compose reads .env automatically). Keep .env chmod 600.
#===============================================================================

services:
  #=============================================================================
  # POSTGRESQL DATABASE
  #=============================================================================
  postgres:
    image: postgres:${PG_VERSION}-alpine
    container_name: ${PROJECT_NAME}-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: postgres
      POSTGRES_USER: odoo
      POSTGRES_PASSWORD: \${DB_PASSWORD}
      TZ: Africa/Nairobi
EOF

if [ -n "$PG_DATA_ENV_LINE" ]; then
    # Append PGDATA only for PG < 18 (quoted so the generator expands the line)
    echo "${PG_DATA_ENV_LINE}" >> docker-compose.yml
fi

cat >> docker-compose.yml << EOF
    shm_size: "256mb"
    volumes:
      - ${PG_VOLUME_MOUNT}
      - ./config/postgresql/postgresql.conf:/etc/postgresql/postgresql.conf:ro
      - ./config/postgresql/pg_hba.conf:/etc/postgresql/pg_hba.conf:ro
      - ./logs/postgres:/var/log/postgresql:z
    command: >
      postgres
      -c config_file=/etc/postgresql/postgresql.conf
      -c hba_file=/etc/postgresql/pg_hba.conf
      -c logging_collector=on
      -c log_directory=/var/log/postgresql
    deploy:
      resources:
        limits:
          memory: ${PG_RAM_MB}M
          cpus: '${TOTAL_CORES}'
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U odoo"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - odoo-network

  #=============================================================================
  # PGBOUNCER CONNECTION POOLER
  #=============================================================================
  pgbouncer:
    image: ${PGBOUNCER_IMAGE}
    container_name: ${PROJECT_NAME}-pgbouncer
    restart: unless-stopped
    volumes:
      - ./config/pgbouncer/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro
      - ./config/pgbouncer/userlist.txt:/etc/pgbouncer/userlist.txt:ro
    command: ["/usr/bin/pgbouncer", "/etc/pgbouncer/pgbouncer.ini"]
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - odoo-network
    healthcheck:
      test: ["CMD", "pg_isready", "-h", "localhost", "-p", "5432"]
      interval: 10s
      timeout: 5s
      retries: 3

  #=============================================================================
  # REDIS SESSION STORE
  #=============================================================================
  redis:
    image: ${REDIS_IMAGE}
    container_name: ${PROJECT_NAME}-redis
    restart: unless-stopped
    # AOF persistence: sessions survive redis restarts (users stay logged in).
    # volatile-lru: only evicts keys with a TTL (sessions have one) under
    # memory pressure, instead of dropping arbitrary keys.
    command: >
      redis-server
      --maxmemory ${REDIS_RAM_MB}mb
      --maxmemory-policy volatile-lru
      --appendonly yes
      --appendfsync everysec
    volumes:
      - redis-data:/data:Z
    deploy:
      resources:
        limits:
          memory: $((REDIS_RAM_MB + 128))M
    networks:
      - odoo-network
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 3

  #=============================================================================
  # MINIO S3-COMPATIBLE OBJECT STORAGE
  #=============================================================================
  minio:
    image: ${MINIO_IMAGE}
    container_name: ${PROJECT_NAME}-minio
    restart: unless-stopped
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: \${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: \${MINIO_ROOT_PASSWORD}
    volumes:
      - minio-data:/data:Z
    ports:
      - "127.0.0.1:9000:9000"   # S3 API
      - "127.0.0.1:9001:9001"   # Web Console
    deploy:
      resources:
        limits:
          memory: ${MINIO_RAM_MB}M
    networks:
      - odoo-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 10s
      retries: 3

  #=============================================================================
  # MINIO CLIENT - BUCKET INITIALIZATION
  #=============================================================================
  minio-init:
    image: ${MC_IMAGE}
    container_name: ${PROJECT_NAME}-minio-init
    depends_on:
      minio:
        condition: service_healthy
    environment:
      MINIO_ROOT_USER: \${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: \${MINIO_ROOT_PASSWORD}
    # Bucket stays PRIVATE: Odoo accesses it with authenticated S3 credentials.
    entrypoint: >
      /bin/sh -c "
      mc alias set myminio http://minio:9000 \$\$MINIO_ROOT_USER \$\$MINIO_ROOT_PASSWORD;
      mc mb myminio/odoo-filestore --ignore-existing;
      echo 'MinIO bucket initialized successfully';
      "
    networks:
      - odoo-network

  #=============================================================================
  # ODOO WEB WORKERS (HTTP TRAFFIC)
  #=============================================================================
  # NOTE: no container_name here - fixed names break 'docker compose up --scale'.
  # Sessions live in Redis and the filestore in MinIO, so replicas are
  # interchangeable (no sticky sessions needed).
  odoo-web:
    image: odoo:${ODOO_VERSION}.0
    restart: unless-stopped
    depends_on:
      pgbouncer:
        condition: service_healthy
      redis:
        condition: service_healthy
      minio:
        condition: service_healthy
      minio-init:
        condition: service_completed_successfully
    environment:
      HOST: pgbouncer
      PORT: 5432
      USER: odoo
      PASSWORD: \${DB_PASSWORD}
      # S3/MinIO Configuration
      AWS_HOST: minio:9000
      AWS_REGION: us-east-1
      AWS_ACCESS_KEY_ID: \${MINIO_ROOT_USER}
      AWS_SECRET_ACCESS_KEY: \${MINIO_ROOT_PASSWORD}
      AWS_BUCKETNAME: odoo-filestore
      # Redis session store (session_redis module, loaded server-wide).
      # URL form selects redis db 1 and avoids the module's TLS default.
      ODOO_SESSION_REDIS: 1
      ODOO_SESSION_REDIS_URL: redis://redis:6379/1
      ODOO_SESSION_REDIS_PREFIX: odoo_sess
    volumes:
      - ./config/odoo/odoo-web.conf:/etc/odoo/odoo.conf:ro
      - ./addons/custom:/mnt/custom-addons:ro
      - ./addons/oca-storage:/mnt/oca-storage:ro
${ENTERPRISE_VOLUME_LINE}
      - ./logs/odoo-web:/var/log/odoo:z
      - ./scripts/entrypoint-web.sh:/entrypoint-web.sh:ro
    # data_dir in tmpfs: temp files/report artifacts live in RAM and vanish on
    # restart - nothing stateful remains in the container (uid 100 = odoo).
    tmpfs:
      - /var/lib/odoo:size=2g,uid=100,gid=101,mode=0755
    entrypoint: ["/entrypoint-web.sh"]
    command: ["odoo", "--config=/etc/odoo/odoo.conf"]
    deploy:
      resources:
        limits:
          memory: $((ODOO_POOL_MB))M
          cpus: '${TOTAL_CORES}'
    networks:
      - odoo-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8069/web/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

  #=============================================================================
  # ODOO CHAT WORKERS (WEBSOCKET/LONGPOLLING)
  #=============================================================================
  odoo-chat:
    image: odoo:${ODOO_VERSION}.0
    container_name: ${PROJECT_NAME}-odoo-chat
    restart: unless-stopped
    depends_on:
      pgbouncer:
        condition: service_healthy
      redis:
        condition: service_healthy
      minio:
        condition: service_healthy
      minio-init:
        condition: service_completed_successfully
    environment:
      HOST: pgbouncer
      PORT: 5432
      USER: odoo
      PASSWORD: \${DB_PASSWORD}
      # S3/MinIO Configuration
      AWS_HOST: minio:9000
      AWS_REGION: us-east-1
      AWS_ACCESS_KEY_ID: \${MINIO_ROOT_USER}
      AWS_SECRET_ACCESS_KEY: \${MINIO_ROOT_PASSWORD}
      AWS_BUCKETNAME: odoo-filestore
      # Redis session store (session_redis module, loaded server-wide).
      ODOO_SESSION_REDIS: 1
      ODOO_SESSION_REDIS_URL: redis://redis:6379/1
      ODOO_SESSION_REDIS_PREFIX: odoo_sess
    volumes:
      - ./config/odoo/odoo-chat.conf:/etc/odoo/odoo.conf:ro
      - ./addons/custom:/mnt/custom-addons:ro
      - ./addons/oca-storage:/mnt/oca-storage:ro
${ENTERPRISE_VOLUME_LINE}
      - ./logs/odoo-chat:/var/log/odoo:z
      - ./scripts/entrypoint-chat.sh:/entrypoint-chat.sh:ro
    tmpfs:
      - /var/lib/odoo:size=1g,uid=100,gid=101,mode=0755
    entrypoint: ["/entrypoint-chat.sh"]
    command: ["odoo", "gevent", "--config=/etc/odoo/odoo.conf"]
    deploy:
      resources:
        limits:
          memory: 1024M
          cpus: '2'
    networks:
      - odoo-network
    healthcheck:
      # /websocket/health exists on all supported versions (16+), bus module
      test: ["CMD", "curl", "-f", "http://localhost:8072/websocket/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

  #=============================================================================
  # NGINX REVERSE PROXY (INTERNAL - PORT 8080)
  #=============================================================================
  nginx:
    image: ${NGINX_IMAGE}
    container_name: ${PROJECT_NAME}-nginx
    restart: unless-stopped
    ports:
      - "8080:8080"  # Internal proxy - host reverse proxy forwards here
    volumes:
      - ./config/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./logs/nginx:/var/log/nginx:z
    depends_on:
      - odoo-web
      - odoo-chat
    networks:
      - odoo-network
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:8080/"]
      interval: 30s
      timeout: 10s
      retries: 3

#===============================================================================
# NETWORKS
#===============================================================================
networks:
  odoo-network:
    driver: bridge

#===============================================================================
# VOLUMES
#===============================================================================
volumes:
  postgres-data:
    driver: local
  minio-data:
    driver: local
  redis-data:
    driver: local
EOF

print_status "Docker Compose file generated"


#===============================================================================
# GENERATE POSTGRESQL CONFIGURATION
#===============================================================================

print_header "Generating PostgreSQL Configuration"

cat > config/postgresql/postgresql.conf << EOF
#===============================================================================
# POSTGRESQL ${PG_VERSION} CONFIGURATION - OPTIMIZED FOR ODOO
#===============================================================================
# System: ${TOTAL_CORES} cores, ${TOTAL_RAM_GB}GB RAM
# Generated: $(date)
# Optimized for massive concurrency with PgBouncer protection
#===============================================================================

#-------------------------------------------------------------------------------
# CONNECTION SETTINGS
#-------------------------------------------------------------------------------
# Session mode requires higher max_connections since PgBouncer doesn't pool
# Calculated dynamically: (web_maxconn + chat_maxconn) * 3 + system_overhead
# This supports multiple databases with adequate connection headroom
listen_addresses = '*'
max_connections = ${PG_MAX_CONNECTIONS}
superuser_reserved_connections = 5

#-------------------------------------------------------------------------------
# MEMORY SETTINGS
#-------------------------------------------------------------------------------
shared_buffers = ${PG_SHARED_BUFFERS}MB
effective_cache_size = ${PG_EFFECTIVE_CACHE}MB
maintenance_work_mem = ${PG_MAINTENANCE_WORK_MEM}MB
work_mem = ${PG_WORK_MEM}MB

#-------------------------------------------------------------------------------
# CHECKPOINT AND WAL SETTINGS
#-------------------------------------------------------------------------------
wal_level = replica
wal_compression = zstd
max_wal_size = 4GB
min_wal_size = 1GB
checkpoint_completion_target = 0.9
wal_buffers = 16MB

#-------------------------------------------------------------------------------
# QUERY PLANNER
#-------------------------------------------------------------------------------
random_page_cost = 1.1
effective_io_concurrency = 200
default_statistics_target = 100

#-------------------------------------------------------------------------------
# PARALLEL QUERY EXECUTION
#-------------------------------------------------------------------------------
max_worker_processes = ${TOTAL_CORES}
max_parallel_workers_per_gather = ${PG_MAX_PARALLEL_PER_GATHER}
max_parallel_workers = ${PG_MAX_PARALLEL_WORKERS}
max_parallel_maintenance_workers = 4

#-------------------------------------------------------------------------------
# AUTOVACUUM (AGGRESSIVE FOR HIGH-WRITE WORKLOAD)
#-------------------------------------------------------------------------------
# autovacuum_max_workers scales with cores: min 4, max 16
autovacuum = on
autovacuum_max_workers = ${PG_AUTOVACUUM_WORKERS}
autovacuum_naptime = 10s
autovacuum_vacuum_threshold = 50
autovacuum_analyze_threshold = 50
autovacuum_vacuum_scale_factor = 0.05
autovacuum_analyze_scale_factor = 0.02
autovacuum_vacuum_cost_delay = 2ms
autovacuum_vacuum_cost_limit = 1000

#-------------------------------------------------------------------------------
# LOGGING
#-------------------------------------------------------------------------------
logging_collector = on
log_directory = '/var/log/postgresql'
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
log_autovacuum_min_duration = 0

#-------------------------------------------------------------------------------
# LOCALE AND FORMATTING
#-------------------------------------------------------------------------------
# 'C' locale: the alpine image (musl libc) does not ship en_US.utf8 -
# setting it here would abort startup. Encoding is still UTF8 (set at initdb).
lc_messages = 'C'
lc_monetary = 'C'
lc_numeric = 'C'
lc_time = 'C'
default_text_search_config = 'pg_catalog.english'
timezone = 'UTC'

#-------------------------------------------------------------------------------
# SECURITY
#-------------------------------------------------------------------------------
password_encryption = scram-sha-256
ssl = off

#-------------------------------------------------------------------------------
# PERFORMANCE TUNING
#-------------------------------------------------------------------------------
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.track = all
pg_stat_statements.max = 10000
track_activity_query_size = 2048
track_io_timing = on
EOF

print_status "PostgreSQL configuration generated"

#===============================================================================
# GENERATE POSTGRESQL AUTHENTICATION CONFIGURATION
#===============================================================================

print_header "Generating PostgreSQL Authentication Configuration"

cat > config/postgresql/pg_hba.conf << 'EOF'
#===============================================================================
# POSTGRESQL CLIENT AUTHENTICATION CONFIGURATION
#===============================================================================
# TYPE  DATABASE        USER            ADDRESS                 METHOD
#===============================================================================

# "local" is for Unix domain socket connections only
local   all             all                                     trust

# IPv4 local connections
host    all             all             127.0.0.1/32            scram-sha-256

# Docker network connections (allow all internal Docker IPs)
host    all             all             0.0.0.0/0               scram-sha-256

# IPv6 local connections
host    all             all             ::1/128                 scram-sha-256

# Replication connections
local   replication     all                                     trust
host    replication     all             127.0.0.1/32            scram-sha-256
host    replication     all             ::1/128                 scram-sha-256
EOF

print_status "PostgreSQL authentication configuration generated"

#===============================================================================
# GENERATE PGBOUNCER CONFIGURATION
#===============================================================================

print_header "Generating PgBouncer Configuration"

# Generate userlist.txt with SCRAM-SHA-256 password hash
cat > config/pgbouncer/userlist.txt << EOF
"odoo" "${DB_PASSWORD}"
EOF

# Generate pgbouncer.ini with wildcard database routing
cat > config/pgbouncer/pgbouncer.ini << EOF
#===============================================================================
# PGBOUNCER CONFIGURATION - WILDCARD DATABASE ROUTING
#===============================================================================
# Generated: $(date)
# Allows any database name to be routed to PostgreSQL
#===============================================================================

[databases]
# Wildcard routing - allows any database name
* = host=postgres port=5432 user=odoo password=${DB_PASSWORD}

[pgbouncer]
# Network
listen_addr = 0.0.0.0
listen_port = 5432
unix_socket_dir =

# Authentication
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
auth_user = odoo

# Connection pooling
# IMPORTANT: Session mode is required for database creation operations
# Transaction mode causes "serialization failure" errors during CREATE DATABASE
# Trade-off: Session mode doesn't pool connections, so PostgreSQL max_connections
# must be set high enough to handle all Odoo workers across all databases
pool_mode = session
max_client_conn = 1000
default_pool_size = ${DEFAULT_POOL_SIZE}
reserve_pool_size = 10
min_pool_size = 5

# Connection limits
server_idle_timeout = 600
server_lifetime = 3600
server_connect_timeout = 15
server_login_retry = 15

# Query handling
server_reset_query = DISCARD ALL
server_reset_query_always = 0
ignore_startup_parameters = extra_float_digits,options

# Logging
admin_users = postgres,odoo
stats_users = postgres,odoo

# Timeouts
query_timeout = 0
query_wait_timeout = 120
client_idle_timeout = 0
idle_transaction_timeout = 0

# Dangerous settings (disabled for safety)
max_db_connections = 0
max_user_connections = 0
EOF

# Set proper permissions for PgBouncer config files
chmod 644 config/pgbouncer/pgbouncer.ini
chmod 644 config/pgbouncer/userlist.txt

print_status "PgBouncer configuration generated with wildcard database routing"

#===============================================================================
# GENERATE ODOO WEB CONFIGURATION
#===============================================================================

print_header "Generating Odoo Web Configuration"

# server_wide_modules: session_redis must be loaded at server start (it patches
# the session store via post_load, no DB install needed). Odoo 19 split XML-RPC
# into the 'rpc' module which is part of its defaults - keep it.
if [ "$ODOO_VERSION" -ge 19 ]; then
    SERVER_WIDE_MODULES="base,rpc,web,session_redis"
else
    SERVER_WIDE_MODULES="base,web,session_redis"
fi

# longpolling_port was replaced by gevent_port in Odoo 16.3+ and removed in 17
if [ "$ODOO_VERSION" -ge 17 ]; then
    CHAT_PORT_DIRECTIVE="gevent_port = 8072"
else
    CHAT_PORT_DIRECTIVE="longpolling_port = 8072"
fi

cat > config/odoo/odoo-web.conf << EOF
[options]
#===============================================================================
# ODOO WEB WORKERS CONFIGURATION - STATELESS
#===============================================================================
# Project: ${PROJECT_NAME}
# Version: ${ODOO_VERSION}.0
# Workers: ${ACTUAL_HTTP_WORKERS}
# Generated: $(date)
#===============================================================================

#-------------------------------------------------------------------------------
# DATABASE CONNECTION (via PgBouncer)
#-------------------------------------------------------------------------------
# db_maxconn: Odoo's internal connection pool per database
# Calculated: (workers * 2) + max_cron_threads + buffer
db_host = pgbouncer
db_port = 5432
db_user = odoo
db_password = ${DB_PASSWORD}
db_maxconn = ${WEB_DB_MAXCONN}
db_template = template0

#-------------------------------------------------------------------------------
# SERVER CONFIGURATION
#-------------------------------------------------------------------------------
http_port = 8069
proxy_mode = True
admin_passwd = ${ADMIN_PASSWD}

#-------------------------------------------------------------------------------
# ADDONS PATH / SERVER-WIDE MODULES
#-------------------------------------------------------------------------------
# OCA storage modules available but not auto-installed
# Install via: ./manage.sh install-modules <db_name>
# session_redis is loaded server-wide (sessions in Redis, no install needed)
addons_path = ${ENTERPRISE_ADDONS_PREFIX}/usr/lib/python3/dist-packages/odoo/addons,/mnt/custom-addons,/mnt/oca-storage
server_wide_modules = ${SERVER_WIDE_MODULES}

#-------------------------------------------------------------------------------
# WORKERS CONFIGURATION (STATELESS HTTP WORKERS)
#-------------------------------------------------------------------------------
workers = ${ACTUAL_HTTP_WORKERS}
max_cron_threads = 2

#-------------------------------------------------------------------------------
# MEMORY LIMITS
#-------------------------------------------------------------------------------
limit_memory_hard = 1073741824
limit_memory_soft = 858993459
limit_request = 8192
limit_time_cpu = 600
limit_time_real = 1200
limit_time_real_cron = 3600

#-------------------------------------------------------------------------------
# GEVENT (DISABLED ON WEB WORKERS)
#-------------------------------------------------------------------------------
gevent_port = 0

#-------------------------------------------------------------------------------
# LOGGING
#-------------------------------------------------------------------------------
log_level = info
logfile = /var/log/odoo/odoo-web.log
log_handler = :INFO
log_db = False

#-------------------------------------------------------------------------------
# SECURITY
#-------------------------------------------------------------------------------
list_db = True
dbfilter = .*

#-------------------------------------------------------------------------------
# PERFORMANCE
#-------------------------------------------------------------------------------
transient_age_limit = 1.0
osv_memory_count_limit = 0

#-------------------------------------------------------------------------------
# SESSION STORAGE (REDIS)
#-------------------------------------------------------------------------------
# Sessions stored in Redis DB 1 for stateless operation
# Configured via environment variables in docker-compose.yml

#-------------------------------------------------------------------------------
# FILESTORE (S3/MinIO)
#-------------------------------------------------------------------------------
# Filestore handled by OCA fs_attachment modules
# data_dir used for temp files, reports, wkhtmltopdf artifacts (not persistent)
data_dir = /var/lib/odoo
EOF

print_status "Odoo web configuration generated"
chmod 600 config/odoo/odoo-web.conf

#===============================================================================
# GENERATE ODOO CHAT CONFIGURATION
#===============================================================================

print_header "Generating Odoo Chat Configuration"

cat > config/odoo/odoo-chat.conf << EOF
[options]
#===============================================================================
# ODOO CHAT WORKERS CONFIGURATION - GEVENT/WEBSOCKET
#===============================================================================
# Project: ${PROJECT_NAME}
# Version: ${ODOO_VERSION}.0
# Mode: Single-threaded gevent
# Generated: $(date)
#===============================================================================

#-------------------------------------------------------------------------------
# DATABASE CONNECTION (via PgBouncer)
#-------------------------------------------------------------------------------
# db_maxconn for chat: Fixed at 10 (gevent handles concurrency internally)
db_host = pgbouncer
db_port = 5432
db_user = odoo
db_password = ${DB_PASSWORD}
db_maxconn = ${CHAT_DB_MAXCONN}
db_template = template0

#-------------------------------------------------------------------------------
# SERVER CONFIGURATION
#-------------------------------------------------------------------------------
http_port = 8069
proxy_mode = True
admin_passwd = ${ADMIN_PASSWD}

#-------------------------------------------------------------------------------
# ADDONS PATH / SERVER-WIDE MODULES
#-------------------------------------------------------------------------------
# session_redis is loaded server-wide (sessions in Redis, no install needed)
addons_path = ${ENTERPRISE_ADDONS_PREFIX}/usr/lib/python3/dist-packages/odoo/addons,/mnt/custom-addons,/mnt/oca-storage
server_wide_modules = ${SERVER_WIDE_MODULES}

#-------------------------------------------------------------------------------
# WORKERS CONFIGURATION (GEVENT MODE)
#-------------------------------------------------------------------------------
workers = 0
max_cron_threads = 0

#-------------------------------------------------------------------------------
# MEMORY LIMITS
#-------------------------------------------------------------------------------
limit_memory_hard = 1073741824
limit_memory_soft = 858993459
limit_request = 8192
limit_time_cpu = 600
limit_time_real = 1200

#-------------------------------------------------------------------------------
# GEVENT (ENABLED FOR WEBSOCKET/LONGPOLLING)
#-------------------------------------------------------------------------------
${CHAT_PORT_DIRECTIVE}

#-------------------------------------------------------------------------------
# LOGGING
#-------------------------------------------------------------------------------
log_level = info
logfile = /var/log/odoo/odoo-chat.log
log_handler = :INFO
log_db = False

#-------------------------------------------------------------------------------
# SECURITY
#-------------------------------------------------------------------------------
list_db = True
dbfilter = .*

#-------------------------------------------------------------------------------
# PERFORMANCE
#-------------------------------------------------------------------------------
transient_age_limit = 1.0
osv_memory_count_limit = 0

#-------------------------------------------------------------------------------
# SESSION STORAGE (REDIS)
#-------------------------------------------------------------------------------
# Sessions stored in Redis DB 1 for stateless operation
# Configured via environment variables in docker-compose.yml

#-------------------------------------------------------------------------------
# FILESTORE (S3/MinIO)
#-------------------------------------------------------------------------------
# Filestore handled by OCA fs_attachment modules
# data_dir used for temp files, reports, wkhtmltopdf artifacts (not persistent)
data_dir = /var/lib/odoo
EOF

print_status "Odoo chat configuration generated"
chmod 600 config/odoo/odoo-chat.conf
chmod 600 config/pgbouncer/userlist.txt
chmod 600 config/pgbouncer/pgbouncer.ini


#===============================================================================
# GENERATE NGINX CONFIGURATION
#===============================================================================

print_header "Generating Nginx Configuration"

# Determine websocket endpoint based on Odoo version
if [ "$ODOO_VERSION" -ge 17 ]; then
    WS_ENDPOINT="/websocket"
else
    WS_ENDPOINT="/longpolling"
fi

cat > config/nginx/nginx.conf << EOF
#===============================================================================
# NGINX CONFIGURATION - INTERNAL STACK PROXY (PORT 8080)
#===============================================================================
# Project: ${PROJECT_NAME}
# Odoo Version: ${ODOO_VERSION}.0
# WebSocket Endpoint: ${WS_ENDPOINT}
# Generated: $(date)
#
# PURPOSE: Internal load balancer and connection optimizer for Odoo stack
#          NOT a public-facing proxy - your host Nginx/Caddy/Traefik handles that
#
# This Nginx:
#   - Load balances between web/chat workers
#   - Handles websocket upgrades internally
#   - Buffers connections to protect Odoo workers
#   - Routes traffic efficiently within the stack
#
# Your public proxy should:
#   - Forward to localhost:8080
#   - Handle SSL/TLS termination
#   - Implement public caching (Varnish/CDN)
#   - Add security headers
#   - Handle rate limiting for public traffic
#===============================================================================

user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 2048;
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    #---------------------------------------------------------------------------
    # LOGGING
    #---------------------------------------------------------------------------
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for" '
                    'rt=\$request_time uct="\$upstream_connect_time" '
                    'uht="\$upstream_header_time" urt="\$upstream_response_time"';

    access_log /var/log/nginx/access.log main;

    #---------------------------------------------------------------------------
    # PERFORMANCE - INTERNAL OPTIMIZATION
    #---------------------------------------------------------------------------
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    client_max_body_size 200M;
    client_body_timeout 60s;
    client_header_timeout 60s;

    #---------------------------------------------------------------------------
    # GZIP - INTERNAL COMPRESSION (reduces bandwidth between containers)
    #---------------------------------------------------------------------------
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_comp_level 2;  # Low compression - we're internal, speed > size
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/javascript
        application/xml+rss
        application/json;

    #---------------------------------------------------------------------------
    # WEBSOCKET UPGRADE MAPPING
    #---------------------------------------------------------------------------
    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        ''      close;
    }

    #---------------------------------------------------------------------------
    # UPSTREAM DEFINITIONS - LOAD BALANCING
    #---------------------------------------------------------------------------
    upstream odoo_web {
        least_conn;  # Route to least busy worker
        server odoo-web:8069 max_fails=3 fail_timeout=30s;
        keepalive 32;  # Connection pooling to workers
    }

    upstream odoo_chat {
        least_conn;
        server odoo-chat:8072 max_fails=3 fail_timeout=30s;
        keepalive 16;
    }

    #---------------------------------------------------------------------------
    # SERVER BLOCK - INTERNAL STACK ROUTER
    #---------------------------------------------------------------------------
    server {
        listen 8080;
        server_name _;

        #-----------------------------------------------------------------------
        # PROXY SETTINGS - OPTIMIZED FOR INTERNAL STACK
        #-----------------------------------------------------------------------
        proxy_read_timeout 720s;
        proxy_connect_timeout 720s;
        proxy_send_timeout 720s;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
        proxy_http_version 1.1;

        #-----------------------------------------------------------------------
        # WEBSOCKET/LONGPOLLING - ROUTE TO CHAT WORKERS
        #-----------------------------------------------------------------------
        location ${WS_ENDPOINT} {
            proxy_pass http://odoo_chat;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$http_host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header X-Forwarded-Host \$http_host;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            proxy_buffering off;  # Websockets need unbuffered
        }

        #-----------------------------------------------------------------------
        # MAIN LOCATION - ROUTE TO WEB WORKERS
        #-----------------------------------------------------------------------
        location / {
            proxy_pass http://odoo_web;
            proxy_set_header Host \$http_host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header X-Forwarded-Host \$http_host;
            proxy_redirect off;
            proxy_set_header Connection "";  # Enable keepalive to upstream
        }
    }
}
EOF

print_status "Nginx configuration generated"

#===============================================================================
# GENERATE ENTRYPOINT SCRIPTS
#===============================================================================

print_header "Generating Entrypoint Scripts"

# Web worker entrypoint — PIP_INSTALL_FLAGS expanded at generate time;
# \$HOST etc. stay as runtime container env vars.
cat > scripts/entrypoint-web.sh << EOF
#!/bin/bash
set -e

echo "Starting Odoo Web Workers..."

# Wait for database connection
echo "Waiting for database connection..."
until python3 -c "import psycopg2; psycopg2.connect(host='\$HOST', port='\$PORT', user='\$USER', password='\$PASSWORD', dbname='postgres')" 2>/dev/null; do
    echo "Database not ready, waiting..."
    sleep 2
done

echo "Database is ready!"

# Install Python dependencies for OCA / session_redis (idempotent)
if [ -f "/mnt/oca-storage/requirements.txt" ]; then
    if ! python3 -c "import s3fs, redis" 2>/dev/null; then
        echo "Installing Python dependencies..."
        pip3 install ${PIP_INSTALL_FLAGS} -r /mnt/oca-storage/requirements.txt
        echo "Dependencies installed successfully"
    else
        echo "Dependencies already installed, skipping..."
    fi
fi

# Log dir may be a root-owned bind mount; never abort on chown failure
mkdir -p /var/log/odoo
chown -R odoo:odoo /var/log/odoo 2>/dev/null || true

echo "Starting Odoo..."
exec "\$@"
EOF

chmod +x scripts/entrypoint-web.sh

# Chat worker entrypoint
cat > scripts/entrypoint-chat.sh << EOF
#!/bin/bash
set -e

echo "Starting Odoo Chat Workers (Gevent)..."

echo "Waiting for database connection..."
until python3 -c "import psycopg2; psycopg2.connect(host='\$HOST', port='\$PORT', user='\$USER', password='\$PASSWORD', dbname='postgres')" 2>/dev/null; do
    echo "Database not ready, waiting..."
    sleep 2
done

echo "Database is ready!"

if [ -f "/mnt/oca-storage/requirements.txt" ]; then
    if ! python3 -c "import s3fs, redis" 2>/dev/null; then
        echo "Installing Python dependencies..."
        pip3 install ${PIP_INSTALL_FLAGS} -r /mnt/oca-storage/requirements.txt
        echo "Dependencies installed successfully"
    else
        echo "Dependencies already installed, skipping..."
    fi
fi

mkdir -p /var/log/odoo
chown -R odoo:odoo /var/log/odoo 2>/dev/null || true

echo "Starting Odoo Chat..."
exec "\$@"
EOF

chmod +x scripts/entrypoint-chat.sh

print_status "Entrypoint scripts generated"



#===============================================================================
# GENERATE MANAGEMENT SCRIPT
#===============================================================================

print_header "Generating Management Script"

cat > manage.sh << 'MGMT_EOF'
#!/bin/bash

set -e

PROJECT_NAME=$(basename "$(pwd)")

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_info() { echo -e "${BLUE}[ℹ]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[⚠]${NC} $1"; }

show_usage() {
    cat << EOF
Usage: $0 [COMMAND]

Commands:
  start           Start all services
  stop            Stop all services
  restart         Restart all services
  logs [SERVICE]  Show logs (all or specific service)
  ps              Show running containers
  shell SERVICE   Open shell in container
  db-shell        Open PostgreSQL shell
  redis-cli       Open Redis CLI
  minio-console   Show MinIO console URL
  install-modules DB  Install OCA storage modules into DATABASE
  scale-web N         Scale web replicas to N (rebalances workers/replica)
  restore DIR         Restore from a ./manage.sh backup directory
  stats               Show resource usage
  backup              Backup database and MinIO data
  clean               Stop and remove all containers
  reset               Clean + remove all volumes (DESTRUCTIVE)
  help                Show this help message

Services:
  odoo-web        HTTP workers (scalable)
  odoo-chat       WebSocket/longpolling workers
  postgres        PostgreSQL database
  pgbouncer       Connection pooler
  redis           Session store
  minio           Object storage
  nginx           Reverse proxy

Examples:
  $0 start
  $0 logs odoo-web
  $0 shell odoo-web
  $0 install-modules production
  $0 scale-web 4
  $0 restore backups/20260101_120000
  $0 stats

EOF
}

case "$1" in
    start)
        print_info "Starting all services..."
        docker compose up -d
        print_success "Services started"
        echo ""
        print_info "Access URLs:"
        echo "  Odoo: http://localhost:8080"
        echo "  MinIO Console: http://localhost:9001"
        echo ""
        print_info "View logs: ./manage.sh logs"
        ;;

    stop)
        print_info "Stopping all services..."
        docker compose down
        print_success "Services stopped"
        ;;

    restart)
        print_info "Restarting all services..."
        docker compose restart
        print_success "Services restarted"
        ;;

    logs)
        # Usage: ./manage.sh logs [SERVICE]  — never treat -f as a service name
        if [ -z "$2" ]; then
            docker compose logs -f
        else
            docker compose logs -f "$2"
        fi
        ;;

    ps)
        docker compose ps
        ;;

    shell)
        if [ -z "$2" ]; then
            print_error "Service name required. Example: $0 shell odoo-web"
            exit 1
        fi
        docker compose exec "$2" /bin/bash
        ;;

    db-shell)
        print_info "Opening PostgreSQL shell..."
        docker compose exec postgres psql -U odoo -d postgres
        ;;

    redis-cli)
        print_info "Opening Redis CLI..."
        docker compose exec redis redis-cli
        ;;

    minio-console)
        print_info "MinIO Console: http://localhost:9001"
        print_info "Credentials are in .env / CREDENTIALS.txt"
        ;;

    install-modules)
        DB_NAME="${2:-}"
        if [ -z "$DB_NAME" ]; then
            print_error "Usage: $0 install-modules DATABASE_NAME"
            print_error "Create the database via the Odoo UI first, then pass its name here."
            exit 1
        fi
        print_info "Installing OCA storage modules into database '$DB_NAME'..."
        print_warning "Temporarily stopping Odoo services"
        docker compose stop odoo-web odoo-chat

        # One shot: Odoo resolves dependency order itself
        docker compose run --rm odoo-web odoo \
            --config=/etc/odoo/odoo.conf \
            -d "$DB_NAME" \
            -i server_environment,fs_storage,fs_attachment,fs_attachment_s3 \
            --stop-after-init

        docker compose start odoo-web odoo-chat
        print_success "Modules installed on '$DB_NAME'"
        echo ""
        echo "Next steps:"
        echo "  1. Settings > Technical > FS Storage — create S3 backend:"
        echo "       Protocol: s3"
        echo "       Directory Path: odoo-filestore/"
        echo "       Options JSON:"
        echo '         {"endpoint_url":"http://minio:9000","key":"<MINIO_ROOT_USER>","secret":"<MINIO_ROOT_PASSWORD>","client_kwargs":{"region_name":"us-east-1"}}'
        echo "  2. Attachments tab — set as default storage"
        echo "  (credentials in CREDENTIALS.txt)"
        ;;

    scale-web)
        if [ -z "$2" ] || ! [[ "$2" =~ ^[0-9]+$ ]] || [ "$2" -lt 1 ]; then
            print_error "Number of replicas required. Example: $0 scale-web 4"
            exit 1
        fi
        N="$2"
        # Rebalance workers so total capacity stays ~ACTUAL_HTTP_WORKERS
        if [ -f .env ]; then
            # shellcheck disable=SC1091
            set -a; . ./.env; set +a
        fi
        TOTAL=${ACTUAL_HTTP_WORKERS:-8}
        PER=$(( (TOTAL + N - 1) / N ))
        [ "$PER" -lt 2 ] && PER=2
        print_info "Scaling to $N replicas at $PER workers each (target capacity ~$((PER * N)), designed for $TOTAL)"
        sed -i "s/^workers = .*/workers = ${PER}/" config/odoo/odoo-web.conf
        docker compose up -d --scale odoo-web="$N" --force-recreate odoo-web
        print_success "Web scaled to $N replicas × $PER workers"
        print_warning "PgBouncer/Postgres max_connections sized for original capacity — watch SHOW POOLS if you scale far beyond design"
        ;;

    stats)
        print_info "Resource Usage:"
        docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}"
        ;;

    backup)
        print_info "Creating backup..."
        BACKUP_DIR="backups/$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"

        print_info "Backing up database..."
        docker compose exec -T postgres pg_dumpall -U odoo | gzip > "$BACKUP_DIR/database.sql.gz"

        print_info "Backing up MinIO data..."
        docker compose exec -T minio tar czf - -C /data . > "$BACKUP_DIR/minio-data.tar.gz"

        # Snapshot .env / configs needed to restore identity
        cp -a .env CREDENTIALS.txt "$BACKUP_DIR/" 2>/dev/null || true
        print_success "Backup created: $BACKUP_DIR"
        echo "  Restore with: $0 restore $BACKUP_DIR"
        ;;

    restore)
        BACKUP_DIR="${2:-}"
        if [ -z "$BACKUP_DIR" ] || [ ! -d "$BACKUP_DIR" ]; then
            print_error "Usage: $0 restore backups/YYYYMMDD_HHMMSS"
            exit 1
        fi
        if [ ! -f "$BACKUP_DIR/database.sql.gz" ]; then
            print_error "Missing $BACKUP_DIR/database.sql.gz"
            exit 1
        fi
        print_warning "This REPLACES the current database and MinIO data from $BACKUP_DIR"
        read -p "Continue? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 0
        fi
        print_info "Stopping Odoo..."
        docker compose stop odoo-web odoo-chat

        print_info "Restoring database..."
        gunzip -c "$BACKUP_DIR/database.sql.gz" | docker compose exec -T postgres psql -U odoo -d postgres

        if [ -f "$BACKUP_DIR/minio-data.tar.gz" ]; then
            print_info "Restoring MinIO data..."
            docker compose exec -T minio sh -c 'rm -rf /data/* && tar xzf - -C /data' < "$BACKUP_DIR/minio-data.tar.gz"
        fi

        docker compose start odoo-web odoo-chat
        print_success "Restore complete from $BACKUP_DIR"
        ;;

    clean)
        print_warning "This will stop and remove all containers"
        read -p "Continue? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            docker compose down
            print_success "Containers removed"
        fi
        ;;

    reset)
        print_warning "This will DESTROY all data (containers + volumes)"
        read -p "Are you sure? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            docker compose down -v
            print_success "All data removed"
        fi
        ;;

    help|*)
        show_usage
        ;;
esac
MGMT_EOF

chmod +x manage.sh

print_status "Management script generated"

#===============================================================================
# GENERATE ENVIRONMENT FILE
#===============================================================================

print_header "Generating Environment File"

cat > .env << EOF
#===============================================================================
# ENVIRONMENT VARIABLES - STATELESS ODOO DEPLOYMENT
#===============================================================================
# Project: ${PROJECT_NAME}
# Generated: $(date)
#
# IMPORTANT: Keep this file secure! It contains sensitive credentials.
#===============================================================================

#-------------------------------------------------------------------------------
# PROJECT CONFIGURATION
#-------------------------------------------------------------------------------
PROJECT_NAME=${PROJECT_NAME}
ODOO_VERSION=${ODOO_VERSION}
ODOO_EDITION=${ODOO_EDITION}

#-------------------------------------------------------------------------------
# SYSTEM RESOURCES
#-------------------------------------------------------------------------------
TOTAL_CORES=${TOTAL_CORES}
TOTAL_RAM_MB=${TOTAL_RAM_MB}
ACTUAL_HTTP_WORKERS=${ACTUAL_HTTP_WORKERS}
DEFAULT_POOL_SIZE=${DEFAULT_POOL_SIZE}

#-------------------------------------------------------------------------------
# DATABASE CREDENTIALS
#-------------------------------------------------------------------------------
DB_PASSWORD=${DB_PASSWORD}
ADMIN_PASSWD=${ADMIN_PASSWD}

#-------------------------------------------------------------------------------
# MINIO CREDENTIALS
#-------------------------------------------------------------------------------
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}

#-------------------------------------------------------------------------------
# RESOURCE LIMITS
#-------------------------------------------------------------------------------
PG_RAM_MB=${PG_RAM_MB}
REDIS_RAM_MB=${REDIS_RAM_MB}
MINIO_RAM_MB=${MINIO_RAM_MB}
ODOO_POOL_MB=${ODOO_POOL_MB}
EOF

chmod 600 .env

print_status "Environment file generated"

#===============================================================================
# GENERATE README
#===============================================================================

print_header "Generating Documentation"

cat > README.md << EOF
# ${PROJECT_NAME} - Stateless Odoo Deployment

## 🚀 Quick Start

\`\`\`bash
# Start all services
./manage.sh start

# View logs
./manage.sh logs

# Access Odoo
open http://localhost:8080
\`\`\`

## 📋 System Information

- **Odoo Version**: ${ODOO_VERSION}.0 (${ODOO_EDITION})
- **PostgreSQL**: ${PG_VERSION}
- **HTTP Workers**: ${ACTUAL_HTTP_WORKERS}
- **System Resources**: ${TOTAL_CORES} cores, ${TOTAL_RAM_GB}GB RAM

## 🏗️ Architecture

This deployment uses a **stateless architecture** for maximum scalability:

\`\`\`
┌─────────────────────────────────────────────────────────────┐
│              Nginx Reverse Proxy (Port 8080)                │
└─────────────────────────────────────────────────────────────┘
                              ↓
        ┌─────────────────────┴─────────────────────┐
        ↓                                           ↓
┌───────────────────┐                    ┌──────────────────┐
│   Odoo-Web        │                    │   Odoo-Chat      │
│   (HTTP Workers)  │                    │   (WebSocket)    │
│   ${ACTUAL_HTTP_WORKERS} workers       │                    │   workers=0      │
└───────────────────┘                    └──────────────────┘
        ↓                                           ↓
        └─────────────────────┬─────────────────────┘
                              ↓
                    ┌──────────────────┐
                    │    PgBouncer     │
                    │   Session Mode   │
                    └──────────────────┘
                              ↓
                    ┌──────────────────┐
                    │  PostgreSQL ${PG_VERSION}  │
                    └──────────────────┘

┌──────────────┐    ┌──────────────┐
│    MinIO     │    │    Redis     │
│  (Filestore) │    │  (Sessions)  │
└──────────────┘    └──────────────┘
\`\`\`

### Key Features

- ✅ **Stateless Workers**: No local filestore, fully scalable
- ✅ **PgBouncer**: Session-mode pooling (safe with Odoo CREATE DATABASE)
- ✅ **MinIO**: S3-compatible object storage for attachments
- ✅ **Redis**: Centralized sessions via \`session_redis\` (server-wide module)
- ✅ **Separated Services**: Web and chat workers optimized independently
- ✅ **OCA Modules**: Pre-downloaded storage modules (+ session_redis)

## 🔐 Credentials

**IMPORTANT**: Save these credentials securely!

\`\`\`
Odoo Master Password: ${ADMIN_PASSWD}
Database Password: ${DB_PASSWORD}
MinIO Root User: ${MINIO_ROOT_USER}
MinIO Root Password: ${MINIO_ROOT_PASSWORD}
\`\`\`

## 📦 Services

| Service | Port | Description |
|---------|------|-------------|
| Odoo | 8080 | Main application |
| MinIO Console | 9001 | Object storage admin |
| PostgreSQL | 5432 | Database (internal) |
| Redis | 6379 | Session store (internal) |

## 🛠️ Management Commands

\`\`\`bash
# Start/Stop
./manage.sh start
./manage.sh stop
./manage.sh restart

# Logs
./manage.sh logs              # All services
./manage.sh logs odoo-web     # Specific service

# Shell Access
./manage.sh shell odoo-web    # Odoo container
./manage.sh db-shell          # PostgreSQL
./manage.sh redis-cli         # Redis

# Scaling
./manage.sh scale-web 8       # Scale to 8 web workers

# Monitoring
./manage.sh ps                # Container status
./manage.sh stats             # Resource usage

# Backup
./manage.sh backup            # Backup database + MinIO

# Maintenance
./manage.sh clean             # Remove containers
./manage.sh reset             # Remove everything (DESTRUCTIVE)
\`\`\`

## 📁 Directory Structure

\`\`\`
${PROJECT_NAME}/
├── config/
│   ├── odoo/              # Odoo configurations
│   ├── postgresql/        # PostgreSQL tuning
│   ├── nginx/             # Reverse proxy config
│   └── pgbouncer/         # Connection pooler
├── addons/
│   ├── custom/            # Your custom modules
│   └── oca-storage/       # OCA storage modules
├── logs/                  # Service logs
├── scripts/               # Entrypoint scripts
├── docker-compose.yml     # Service definitions
├── manage.sh              # Management script
└── .env                   # Environment variables
\`\`\`

## 🔧 Configuration

### Installing OCA Storage Modules

\`\`\`bash
# Install modules
./manage.sh install-modules production

# Configure in Odoo UI:
# Settings > Technical > Storage Backends
# Create new backend:
#   - Type: S3
#   - Endpoint: http://minio:9000
#   - Access Key: ${MINIO_ROOT_USER}
#   - Secret Key: ${MINIO_ROOT_PASSWORD}
#   - Bucket: odoo-filestore
\`\`\`

### Adding Custom Modules

\`\`\`bash
# Copy your module to addons/custom/
cp -r /path/to/my_module addons/custom/

# Restart Odoo
./manage.sh restart

# Install in Odoo UI or via CLI:
docker compose exec odoo-web odoo -d postgres -i my_module --stop-after-init
\`\`\`

### Scaling Workers

\`\`\`bash
# Scale web workers horizontally
./manage.sh scale-web 16

# Or edit docker-compose.yml:
# services:
#   odoo-web:
#     deploy:
#       replicas: 16
\`\`\`

## 🔍 Monitoring

### Resource Usage

\`\`\`bash
# Real-time stats
./manage.sh stats

# Detailed container info
docker compose ps
docker stats
\`\`\`

### Logs

\`\`\`bash
# All logs
./manage.sh logs

# Specific service
./manage.sh logs odoo-web
./manage.sh logs postgres
./manage.sh logs nginx

# Follow logs
./manage.sh logs -f odoo-web
\`\`\`

### Database Performance

\`\`\`bash
# PostgreSQL shell
./manage.sh db-shell

# Check active queries
SELECT pid, usename, application_name, state, query
FROM pg_stat_activity
WHERE state = 'active';

# Check connection count
SELECT count(*) FROM pg_stat_activity;

# PgBouncer stats (from host)
docker compose exec pgbouncer psql -p 5432 -U odoo -d pgbouncer -c "SHOW POOLS;"
\`\`\`

## 🚨 Troubleshooting

### Odoo won't start

\`\`\`bash
# Check logs
./manage.sh logs odoo-web

# Check database connection
./manage.sh db-shell

# Restart services
./manage.sh restart
\`\`\`

### Out of memory

\`\`\`bash
# Check resource usage
./manage.sh stats

# Reduce workers in config/odoo/odoo-web.conf
# workers = 4  # Reduce this number

# Restart
./manage.sh restart
\`\`\`

### MinIO connection issues

\`\`\`bash
# Check MinIO status
docker compose ps minio

# Access MinIO console
open http://localhost:9001

# Check bucket exists
docker compose exec minio mc ls myminio/
\`\`\`

## 📊 Performance Tuning

### Calculated Configuration

This deployment was auto-configured based on your system:

- **PostgreSQL shared_buffers**: ${PG_SHARED_BUFFERS}MB
- **PostgreSQL work_mem**: ${PG_WORK_MEM}MB
- **PgBouncer pool size**: ${DEFAULT_POOL_SIZE}
- **Odoo workers**: ${ACTUAL_HTTP_WORKERS}
- **Worker memory limit**: 1GB per worker

### Optimization Tips

1. **Monitor PgBouncer**: Check if pool is saturated
   \`\`\`bash
   docker compose exec pgbouncer psql -p 5432 -U odoo -d pgbouncer -c "SHOW POOLS;"
   \`\`\`

2. **Scale horizontally**: Add more web workers
   \`\`\`bash
   ./manage.sh scale-web 16
   \`\`\`

3. **Tune PostgreSQL**: Edit \`config/postgresql/postgresql.conf\`

4. **Monitor Redis**: Check memory usage
   \`\`\`bash
   ./manage.sh redis-cli INFO memory
   \`\`\`

## 🔒 Security

### Production Checklist

- [ ] Change default passwords in \`.env\`
- [ ] Configure firewall rules
- [ ] Enable SSL/TLS on host reverse proxy
- [ ] Set \`list_db = False\` in Odoo config
- [ ] Configure proper \`dbfilter\` in Odoo config
- [ ] Enable PostgreSQL SSL
- [ ] Restrict MinIO access
- [ ] Set up regular backups
- [ ] Monitor logs for suspicious activity

### Backup Strategy

\`\`\`bash
# Manual backup
./manage.sh backup

# Automated backup (add to crontab)
0 2 * * * cd /path/to/${PROJECT_NAME} && ./manage.sh backup
\`\`\`

## 📚 Additional Resources

- [Odoo Documentation](https://www.odoo.com/documentation/${ODOO_VERSION}.0/)
- [OCA Storage Modules](https://github.com/OCA/storage)
- [PgBouncer Documentation](https://www.pgbouncer.org/)
- [MinIO Documentation](https://min.io/docs/minio/linux/index.html)

## 🤝 Support

For issues or questions:
1. Check logs: \`./manage.sh logs\`
2. Review this README
3. Check Odoo/OCA documentation
4. Open an issue on your project repository

---

**Generated**: $(date)
**System**: ${TOTAL_CORES} cores, ${TOTAL_RAM_GB}GB RAM
**Architecture**: Stateless, Auto-scaling, Production-ready
EOF

print_status "Documentation generated"


#===============================================================================
# GENERATE HOST NGINX CONFIGURATION TEMPLATE
#===============================================================================

print_header "Generating Host Nginx Template"

cat > nginx-host-config.conf << EOF
#===============================================================================
# HOST NGINX CONFIGURATION - PORT 80 REVERSE PROXY
#===============================================================================
# This configuration should be placed on your host server's Nginx
# Path: /etc/nginx/sites-available/${PROJECT_NAME}
#
# Installation:
#   sudo cp nginx-host-config.conf /etc/nginx/sites-available/${PROJECT_NAME}
#   sudo ln -s /etc/nginx/sites-available/${PROJECT_NAME} /etc/nginx/sites-enabled/
#   sudo nginx -t
#   sudo systemctl reload nginx
#===============================================================================

upstream ${PROJECT_NAME}_backend {
    server 127.0.0.1:8080;
    keepalive 32;
}

server {
    listen 80;
    server_name your-domain.com;  # CHANGE THIS

    client_max_body_size 200M;
    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    # Logging
    access_log /var/log/nginx/${PROJECT_NAME}-access.log;
    error_log /var/log/nginx/${PROJECT_NAME}-error.log;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    # Proxy to internal Nginx (port 8080)
    location / {
        proxy_pass http://${PROJECT_NAME}_backend;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_redirect off;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }
}

# SSL Configuration (after running certbot)
# server {
#     listen 443 ssl http2;
#     server_name your-domain.com;
#
#     ssl_certificate /etc/letsencrypt/live/your-domain.com/fullchain.pem;
#     ssl_certificate_key /etc/letsencrypt/live/your-domain.com/privkey.pem;
#     ssl_protocols TLSv1.2 TLSv1.3;
#     ssl_ciphers HIGH:!aNULL:!MD5;
#
#     # ... rest of configuration same as above ...
# }
EOF

print_status "Host Nginx template generated"

#===============================================================================
# CREATE CREDENTIALS FILE
#===============================================================================

print_header "Saving Credentials"

cat > CREDENTIALS.txt << EOF
#===============================================================================
# ${PROJECT_NAME} - CREDENTIALS
#===============================================================================
# Generated: $(date)
#
# ⚠️  IMPORTANT: Keep this file secure! Do not commit to version control.
#===============================================================================

PROJECT NAME: ${PROJECT_NAME}
ODOO VERSION: ${ODOO_VERSION}.0
EDITION: ${ODOO_EDITION}

#-------------------------------------------------------------------------------
# ODOO ACCESS
#-------------------------------------------------------------------------------
URL: http://localhost:8080
Master Password: ${ADMIN_PASSWD}
Default Database: postgres

#-------------------------------------------------------------------------------
# DATABASE
#-------------------------------------------------------------------------------
Host: localhost (via PgBouncer)
Port: 5432
User: odoo
Password: ${DB_PASSWORD}
Database: postgres

#-------------------------------------------------------------------------------
# MINIO OBJECT STORAGE
#-------------------------------------------------------------------------------
Console URL: http://localhost:9001
Root User: ${MINIO_ROOT_USER}
Root Password: ${MINIO_ROOT_PASSWORD}
Bucket: odoo-filestore
S3 Endpoint: http://minio:9000 (internal)

#-------------------------------------------------------------------------------
# SYSTEM CONFIGURATION
#-------------------------------------------------------------------------------
Total Cores: ${TOTAL_CORES}
Total RAM: ${TOTAL_RAM_GB}GB
HTTP Workers: ${ACTUAL_HTTP_WORKERS}
PgBouncer Pool: ${DEFAULT_POOL_SIZE}
PostgreSQL Version: ${PG_VERSION}

#-------------------------------------------------------------------------------
# RESOURCE ALLOCATION
#-------------------------------------------------------------------------------
PostgreSQL: ${PG_RAM_MB}MB (30%)
Redis: ${REDIS_RAM_MB}MB (5%)
MinIO: ${MINIO_RAM_MB}MB (5%)
Odoo Workers: ${ODOO_POOL_MB}MB (50%)
OS Buffer: ${OS_BUFFER_MB}MB (10%)

#===============================================================================
# QUICK START
#===============================================================================

1. Start services:
   ./manage.sh start

2. Access Odoo:
   http://localhost:8080

3. Create database:
   - Database name: production
   - Master password: ${ADMIN_PASSWD}
   - Admin password: (choose your own)

4. Install OCA storage modules:
   ./manage.sh install-modules production

5. Configure S3 storage in Odoo:
   Settings > Technical > Storage Backends
   - Type: S3
   - Endpoint: http://minio:9000
   - Access Key: ${MINIO_ROOT_USER}
   - Secret Key: ${MINIO_ROOT_PASSWORD}
   - Bucket: odoo-filestore

#===============================================================================
# BACKUP THESE CREDENTIALS
#===============================================================================
EOF

chmod 600 CREDENTIALS.txt

print_status "Credentials saved to CREDENTIALS.txt"

#===============================================================================
# CREATE .gitignore
#===============================================================================

cat > .gitignore << EOF
# Environment and credentials
.env
CREDENTIALS.txt

# Data directories
data/
logs/

# Docker volumes
postgres-data/
minio-data/

# Temporary files
*.log
*.tmp
*.bak
*.swp
*~

# OS files
.DS_Store
Thumbs.db
EOF

print_status ".gitignore created"

#===============================================================================
# PERFORMANCE GUIDE (why beefy servers feel slow)
#===============================================================================

cat > PERFORMANCE.md << 'PERF_EOF'
# Why Odoo Feels Slow When CPU Is Idle

If top shows <20% CPU but users wait seconds per click, you are not
"under-utilizing hardware" — you are **latency-bound**, not CPU-bound.
Docker vs bare metal (~15% gap) is a red herring; the bottleneck is usually
**serial work per request**, not missing cores.

## Mental model

```
Browser ──► Nginx ──► ONE Odoo worker ──► Postgres (locks / queries)
                 └── other workers sit idle waiting for their next request
```

Odoo is multi-*process*, not multi-*threaded* for HTTP. One HTTP request
occupies **one worker for its entire duration**. 16 cores with 2 workers
and 200ms DB waits = ~2% CPU and an angry user base.

## Checklist (run these before blaming Docker)

1. **Workers**
   - `workers = 0` = single-threaded. Instant death under concurrency.
   - Target: `min(CPU*2+1, RAM_GB)`-ish, capped by DB connections.
   - This stack sizes workers at generate time; verify in
     `config/odoo/odoo-web.conf`.

2. **DB lock contention** (most common "idle CPU / slow Odoo")
   ```sql
   SELECT pid, usename, state, wait_event_type, wait_event,
          now()-query_start AS age, left(query,120)
   FROM pg_stat_activity
   WHERE datname IS NOT NULL AND state <> 'idle'
   ORDER BY age DESC;
   ```
   Long `Lock` / `LWLock` waits = app design (write-heavy crons, stock,
   account concurrent posts), not infrastructure.

3. **Slow queries**
   - `log_min_duration_statement = 1000` is already on.
   - Enable `pg_stat_statements` (loaded) and:
     `SELECT query, calls, mean_exec_time FROM pg_stat_statements
      ORDER BY mean_exec_time DESC LIMIT 20;`
   - Missing indexes / N+1 ORM loops show up here.

4. **Cron storms**
   - Heavy crons on the same workers as HTTP steal request slots.
   - Scale path: dedicated cron container (`max_cron_threads` only,
     `workers=0` or low, no nginx traffic).

5. **Assets / chatter / bus**
   - Without a warm reverse-proxy cache, every page reloads static
     assets through Python. Host nginx/CDN caching is the fix —
     this stack's internal nginx deliberately does not cache for public.

6. **Attachments I/O**
   - Local filestore on spinning disk or overlayfs hurts.
   - This stack puts attachments on MinIO (object storage) so web
     replicas stay interchangeable.

7. **Sessions**
   - Filesystem sessions + multiple web replicas = random logouts.
   - Fixed here via `session_redis` + Redis AOF.

8. **PgBouncer mode**
   - Session mode (this script): correct for Odoo CREATE DATABASE,
     limited multiplexing.
   - Transaction mode: more connections, but needs Odoo patches /
     careful prepared-statement handling — only for 64+ core farms.

## Docker vs bare metal

Expect ~5–15% overhead from overlay networking / virtio. If bare metal
is only 15% faster and still "slow", **the app/DB path is the war**, not
the container runtime. Fix queries, locks, workers, and caching first.

## Useful commands on this stack

```bash
./manage.sh stats
./manage.sh logs odoo-web
./manage.sh db-shell
# Inside psql:
#   SELECT count(*) FROM pg_stat_activity;
docker compose exec pgbouncer psql -p 5432 -U odoo -d pgbouncer -c "SHOW POOLS;"
./manage.sh scale-web 4   # rebalances workers/replica automatically
```

## When to go bare metal anyway

- Extreme IOPS on local NVMe filestore (and you refuse object storage)
- Kernel-level tracing / eBPF profiling of native extensions
- Compliance that forbids containers

Otherwise stay containerized: rebuildable, scale-out ready, same bottlenecks
visible either way.
PERF_EOF

print_status "PERFORMANCE.md generated"

print_header "Deployment Complete!"

cat << EOF

${GREEN}╔═══════════════════════════════════════════════════════════════════════════╗
║                                                                           ║
║                    🎉 DEPLOYMENT SUCCESSFUL! 🎉                           ║
║                                                                           ║
╚═══════════════════════════════════════════════════════════════════════════╝${NC}

${CYAN}📋 Project Summary:${NC}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Project Name:      ${PROJECT_NAME}
  Odoo Version:      ${ODOO_VERSION}.0 (${ODOO_EDITION})
  PostgreSQL:        ${PG_VERSION}
  HTTP Workers:      ${ACTUAL_HTTP_WORKERS}
  System Resources:  ${TOTAL_CORES} cores, ${TOTAL_RAM_GB}GB RAM
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

${CYAN}🚀 Quick Start:${NC}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  1. Start services:
     ${GREEN}cd ${PROJECT_NAME} && ./manage.sh start${NC}

  2. Access Odoo:
     ${BLUE}http://localhost:8080${NC}

  3. View logs:
     ${GREEN}./manage.sh logs${NC}

  4. Install OCA storage modules:
     ${GREEN}./manage.sh install-modules production${NC}

${CYAN}🔐 Important Files:${NC}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ${YELLOW}CREDENTIALS.txt${NC}  - All passwords and access details
  ${YELLOW}.env${NC}             - Environment variables
  ${YELLOW}README.md${NC}        - Complete documentation
  ${YELLOW}manage.sh${NC}        - Management commands

${RED}⚠️  SECURITY WARNING:${NC}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ${YELLOW}Backup CREDENTIALS.txt immediately!${NC}
  ${YELLOW}Do NOT commit .env or CREDENTIALS.txt to version control!${NC}
  ${YELLOW}Change default passwords before production use!${NC}

${CYAN}📊 Architecture Highlights:${NC}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✅ PgBouncer session-mode pooling (${DEFAULT_POOL_SIZE} client slots)
  ✅ MinIO S3-compatible storage (private bucket)
  ✅ Redis sessions via session_redis (AOF persisted)
  ✅ Separated web/chat containers (web is horizontally scalable)
  ✅ OCA storage modules + session_redis downloaded
  ✅ Dynamic resource allocation + PERFORMANCE.md guide
  ✅ Production-oriented configuration

${CYAN}📚 Next Steps:${NC}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  1. Review README.md for detailed documentation
  2. Configure host Nginx (nginx-host-config.conf)
  3. Set up SSL with certbot
  4. Create Odoo database via UI (http://localhost:8080)
  5. Install OCA storage modules: Settings > Apps > Update Apps List > Search "fs_"
  6. Configure S3 storage: Settings > Technical > Filesystems
     - Protocol: s3
     - Directory Path: odoo-filestore/  (bucket name with trailing slash)
     - Options: {"endpoint_url": "http://minio:9000", "key": "minioadmin", "secret": "YOUR_PASSWORD", "client_kwargs": {"region_name": "us-east-1"}}
  7. Add your custom modules to addons/custom/
  8. Set up automated backups
  9. Monitor resource usage with ./manage.sh stats

${CYAN}🔧 Management Commands:${NC}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ./manage.sh start          - Start all services
  ./manage.sh stop           - Stop all services
  ./manage.sh logs           - View logs
  ./manage.sh stats          - Resource usage
  ./manage.sh scale-web N    - Scale web workers
  ./manage.sh backup         - Backup data
  ./manage.sh help           - Show all commands

${CYAN}🌐 Access URLs:${NC}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Odoo:          ${BLUE}http://localhost:8080${NC}
  MinIO Console: ${BLUE}http://localhost:9001${NC}

${GREEN}╔═══════════════════════════════════════════════════════════════════════════╗
║                                                                           ║
║  Your stateless, production-ready Odoo deployment is ready to launch! 🚀 ║
║                                                                           ║
╚═══════════════════════════════════════════════════════════════════════════╝${NC}

EOF

# Change to project directory for user convenience
cd ..

print_success "Deployment script completed successfully!"
print_info "Project location: $(pwd)/${PROJECT_NAME}"
print_info "To get started: cd ${PROJECT_NAME} && ./manage.sh start"

echo ""
