#!/bin/bash
# shellcheck disable=SC2034  # every variable set here is output for the sourcing script
# lib/tuning.sh - resource-tuning maths shared by every deployment mode.
#
# Copyright (C) 2025-2026 Makondoo Inc.
# Licence: AGPL-3.0-or-later
#
# Pure functions: sourcing this file defines functions only. Nothing is read
# from the machine until odoo_tuning_detect is called, and nothing is written
# anywhere. Every generated config (odoo.conf, postgresql.conf, pgbouncer.ini,
# nginx.conf, docker-compose shm_size) derives from the variables that
# odoo_tuning_compute exports, so the whole stack scales together, from a
# 2-core VPS to a 256-core server.
#
# Inputs (set before calling odoo_tuning_compute):
#   CPU_CORES      number of cores
#   TOTAL_RAM_MB   total RAM in MB
#   NUM_VERSIONS   Odoo versions sharing this host (default 1)
#   USE_PGBOUNCER  "true" or "false" (default "false")
#
# Outputs: see odoo_tuning_vars. The formulas are the ones from
# nginx/autodeploy-nginx.sh v1; tests/tuning.bats proves equivalence against a
# verbatim copy of that block, so change both together.

# clamp VALUE MIN MAX
clamp() {
    local v=$1 lo=$2 hi=$3
    [ "$v" -lt "$lo" ] && v=$lo
    [ "$v" -gt "$hi" ] && v=$hi
    echo "$v"
}

# Overridable warning hook (deploy scripts replace it with their print_warning)
tuning_warn() { echo "[WARN] $1" >&2; }

# Read cores and RAM from the running machine.
odoo_tuning_detect() {
    CPU_CORES=$(nproc)
    TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
}

# The variables odoo_tuning_compute sets, in display order.
odoo_tuning_vars() {
    echo CPU_CORES TOTAL_RAM_MB NUM_VERSIONS USE_PGBOUNCER \
        OPTIMAL_WORKERS MAX_CRON_THREADS WORKER_MEMORY_MB SOFT_LIMIT_MB \
        HARD_LIMIT_BYTES SOFT_LIMIT_BYTES DB_MAXCONN ODOO_DB_HOST \
        MAX_CONNECTIONS SHARED_BUFFERS EFFECTIVE_CACHE_SIZE MAINTENANCE_WORK_MEM \
        WORK_MEM MAX_WAL_SIZE MIN_WAL_SIZE AUTOVACUUM_WORKERS \
        MAX_WORKER_PROCESSES MAX_PARALLEL_WORKERS MAX_PARALLEL_PER_GATHER \
        MAX_PARALLEL_MAINTENANCE SHM_SIZE IO_WORKERS \
        PGB_DEFAULT_POOL_SIZE PGB_MAX_DB_CONNECTIONS PGB_MAX_CLIENT_CONN \
        NGINX_WORKER_CONNECTIONS NGINX_RLIMIT_NOFILE NGINX_KEEPALIVE NGINX_KEEPALIVE_CHAT
}

odoo_tuning_compute() {
    : "${CPU_CORES:?set CPU_CORES or call odoo_tuning_detect}"
    : "${TOTAL_RAM_MB:?set TOTAL_RAM_MB or call odoo_tuning_detect}"
    NUM_VERSIONS=${NUM_VERSIONS:-1}
    USE_PGBOUNCER=${USE_PGBOUNCER:-false}
    [ "$NUM_VERSIONS" -ge 1 ] || NUM_VERSIONS=1

    # --- PostgreSQL memory ---------------------------------------------------
    SHARED_BUFFERS=$((TOTAL_RAM_MB / 4))  # 25% of RAM...
    # ...capped at 16GB: beyond that OLTP workloads like Odoo see diminishing
    # returns and double-buffering waste; the OS page cache
    # (effective_cache_size) covers the rest.
    [ "$SHARED_BUFFERS" -gt 16384 ] && SHARED_BUFFERS=16384
    EFFECTIVE_CACHE_SIZE=$((TOTAL_RAM_MB * 3 / 4))  # 75% of RAM
    MAINTENANCE_WORK_MEM=$(clamp $((TOTAL_RAM_MB / 16)) 64 4096)  # ~6% RAM, 4GB cap

    # --- Odoo workers per version --------------------------------------------
    # Worker memory tiers by total RAM: the soft limit is the steady-state
    # footprint (Odoo recycles a worker above it after the current request);
    # the hard limit only guards abnormal spikes.
    if [ "$TOTAL_RAM_MB" -lt 4096 ]; then
        WORKER_MEMORY_MB=512;  SOFT_LIMIT_MB=400
    elif [ "$TOTAL_RAM_MB" -lt 8192 ]; then
        WORKER_MEMORY_MB=1024; SOFT_LIMIT_MB=800
    else
        WORKER_MEMORY_MB=2048; SOFT_LIMIT_MB=1600
    fi

    MAX_CRON_THREADS=2

    # RAM budget: 80% safety factor, minus a small OS reserve and what postgres
    # itself claims (shared_buffers), split evenly across deployed versions.
    # Workers are planned at their SOFT limit; sizing at the hard limit would
    # leave half the machine idle.
    local available_ram_mb reserved_ram odoo_ram_budget per_version_ram
    local max_workers_by_ram max_workers_by_cpu
    available_ram_mb=$(( TOTAL_RAM_MB * 80 / 100 ))
    reserved_ram=$(( 512 + SHARED_BUFFERS ))
    odoo_ram_budget=$(( available_ram_mb - reserved_ram ))
    [ "$odoo_ram_budget" -lt 0 ] && odoo_ram_budget=0
    per_version_ram=$(( odoo_ram_budget / NUM_VERSIONS ))
    max_workers_by_ram=$(( per_version_ram / SOFT_LIMIT_MB ))

    # CPU guidance (workers = cores*2+1) is for a dedicated host, so the total
    # is spread across versions (ceiling division), not granted to each one.
    max_workers_by_cpu=$(( (CPU_CORES * 2 + 1 + NUM_VERSIONS - 1) / NUM_VERSIONS ))

    OPTIMAL_WORKERS=$(( max_workers_by_ram < max_workers_by_cpu ? max_workers_by_ram : max_workers_by_cpu ))
    # Very low resources: workers=0 runs Odoo single-process threaded mode
    [ "$OPTIMAL_WORKERS" -lt 1 ] && OPTIMAL_WORKERS=0
    MAX_WORKERS_BY_RAM=$max_workers_by_ram
    MAX_WORKERS_BY_CPU=$max_workers_by_cpu

    # --- Connection budget ---------------------------------------------------
    PGB_DEFAULT_POOL_SIZE=""; PGB_MAX_DB_CONNECTIONS=""; PGB_MAX_CLIENT_CONN=""
    if [[ "$USE_PGBOUNCER" == "true" ]]; then
        # PgBouncer (transaction mode) multiplexes any number of Odoo client
        # connections onto a small backend pool, so workers stay bounded by
        # CPU/RAM only. Postgres itself only needs ~4 active backends per core.
        MAX_CONNECTIONS=$(clamp $(( CPU_CORES * 4 + 20 )) 100 500)
        # Per database/user pair pool; big reports hold a backend for their
        # whole transaction, so give each database room to fan out.
        PGB_DEFAULT_POOL_SIZE=$(clamp $(( CPU_CORES * 2 )) 8 64)
        # Hard per-database backend cap so one busy database cannot starve others
        PGB_MAX_DB_CONNECTIONS=$(( MAX_CONNECTIONS - 20 ))
        # Client side is cheap: every Odoo process may hold up to db_maxconn
        PGB_MAX_CLIENT_CONN=$(clamp $(( NUM_VERSIONS * (OPTIMAL_WORKERS + MAX_CRON_THREADS + 2) * 16 )) 1000 10000)
        ODOO_DB_HOST="pgbouncer"
    else
        # Direct connections: peak per version is HTTP workers at ~2
        # connections each under load, plus cron threads, plus a gevent/bus +
        # maintenance allowance; +20% headroom and 10 reserved.
        local per_version_conns budget_per_version
        per_version_conns=$(( OPTIMAL_WORKERS * 2 + MAX_CRON_THREADS + 8 ))
        MAX_CONNECTIONS=$(( per_version_conns * NUM_VERSIONS * 120 / 100 + 10 ))
        [ "$MAX_CONNECTIONS" -lt 100 ] && MAX_CONNECTIONS=100
        if [ "$MAX_CONNECTIONS" -gt 1000 ]; then
            # Past ~1000 backends, per-process overhead dominates; clamp and
            # derive the worker count back from the budget. PgBouncer removes
            # this limit entirely.
            MAX_CONNECTIONS=1000
            budget_per_version=$(( (MAX_CONNECTIONS - 10) * 100 / 120 / NUM_VERSIONS ))
            OPTIMAL_WORKERS=$(( (budget_per_version - MAX_CRON_THREADS - 8) / 2 ))
            tuning_warn "Worker count limited by 1000-connection budget - enable PgBouncer to go beyond"
        fi
        ODOO_DB_HOST="db"
    fi

    # Per-process pool cap in Odoo; scaled to the computed worker count so a
    # single runaway process cannot drain the whole cluster budget.
    DB_MAXCONN=$(clamp $(( OPTIMAL_WORKERS * 2 + 16 )) 64 256)

    # --- work_mem: bounded against the connection budget, not just cores -----
    # Worst case is work_mem x concurrent sort/hash ops; dividing non-shared
    # RAM by max_connections keeps a fully loaded box out of OOM territory.
    WORK_MEM=$(clamp $(( (TOTAL_RAM_MB - SHARED_BUFFERS) / MAX_CONNECTIONS )) 4 256)

    # --- WAL sizing, autovacuum, shared memory by RAM tier -------------------
    if [ "$TOTAL_RAM_MB" -lt 8192 ]; then
        MAX_WAL_SIZE="2GB";  MIN_WAL_SIZE="512MB"
    elif [ "$TOTAL_RAM_MB" -lt 32768 ]; then
        MAX_WAL_SIZE="4GB";  MIN_WAL_SIZE="1GB"
    else
        MAX_WAL_SIZE="8GB";  MIN_WAL_SIZE="2GB"
    fi

    AUTOVACUUM_WORKERS=$(clamp $(( CPU_CORES / 4 )) 3 8)

    # --- Parallel query: what makes a single huge report fast ----------------
    # Postgres defaults cap every query at 2 parallel workers from a global
    # pool of 8 no matter how many cores exist.
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

    # --- PostgreSQL 18+ async I/O --------------------------------------------
    # io_method=worker with io_workers scaled to CPU instead of the fixed 3.
    # io_uring is not used: Docker's default seccomp profile blocks it.
    IO_WORKERS=$(clamp $(( CPU_CORES / 4 )) 3 32)

    # --- Nginx (only used when the embedded proxy is enabled) ----------------
    NGINX_WORKER_CONNECTIONS=$(clamp $(( CPU_CORES * 1024 )) 1024 8192)
    # Each proxied client costs ~2 fds (client + upstream)
    NGINX_RLIMIT_NOFILE=$(( NGINX_WORKER_CONNECTIONS * 2 + 512 ))
    NGINX_KEEPALIVE=$(clamp $(( OPTIMAL_WORKERS * 4 )) 32 128)
    NGINX_KEEPALIVE_CHAT=$(( NGINX_KEEPALIVE / 2 ))

    # --- Odoo memory limits (bytes) ------------------------------------------
    HARD_LIMIT_BYTES=$(( WORKER_MEMORY_MB * 1024 * 1024 ))
    SOFT_LIMIT_BYTES=$(( SOFT_LIMIT_MB * 1024 * 1024 ))
}

# Print the plan. FORMAT: text (default), env (KEY=VALUE lines), json.
odoo_tuning_print() {
    local fmt=${1:-text} v
    case "$fmt" in
        env)
            for v in $(odoo_tuning_vars); do echo "$v=${!v}"; done ;;
        json)
            local sep="" out="{"
            for v in $(odoo_tuning_vars); do
                local val=${!v}
                if [[ "$val" =~ ^-?[0-9]+$ ]]; then out+="$sep\"$v\": $val"; else out+="$sep\"$v\": \"$val\""; fi
                sep=", "
            done
            echo "$out}" ;;
        *)
            echo "Machine:    ${CPU_CORES} cores, ${TOTAL_RAM_MB} MB RAM, ${NUM_VERSIONS} Odoo version(s), pgbouncer=${USE_PGBOUNCER}"
            echo "Odoo:       workers=${OPTIMAL_WORKERS} per version (RAM allows ${MAX_WORKERS_BY_RAM}, CPU allows ${MAX_WORKERS_BY_CPU}), max_cron_threads=${MAX_CRON_THREADS}"
            echo "            limit_memory_soft=${SOFT_LIMIT_MB}MB limit_memory_hard=${WORKER_MEMORY_MB}MB db_maxconn=${DB_MAXCONN} db_host=${ODOO_DB_HOST}"
            echo "PostgreSQL: max_connections=${MAX_CONNECTIONS} shared_buffers=${SHARED_BUFFERS}MB effective_cache_size=${EFFECTIVE_CACHE_SIZE}MB"
            echo "            work_mem=${WORK_MEM}MB maintenance_work_mem=${MAINTENANCE_WORK_MEM}MB wal=${MIN_WAL_SIZE}..${MAX_WAL_SIZE} shm_size=${SHM_SIZE}"
            echo "            parallel: ${MAX_PARALLEL_PER_GATHER}/query from ${MAX_PARALLEL_WORKERS} (max_worker_processes=${MAX_WORKER_PROCESSES}), autovacuum_max_workers=${AUTOVACUUM_WORKERS}, io_workers=${IO_WORKERS} (PG18+)"
            if [[ "$USE_PGBOUNCER" == "true" ]]; then
                echo "PgBouncer:  transaction mode, default_pool_size=${PGB_DEFAULT_POOL_SIZE} max_db_connections=${PGB_MAX_DB_CONNECTIONS} max_client_conn=${PGB_MAX_CLIENT_CONN}"
            fi
            echo "nginx:      worker_connections=${NGINX_WORKER_CONNECTIONS} worker_rlimit_nofile=${NGINX_RLIMIT_NOFILE} keepalive=${NGINX_KEEPALIVE} (chat ${NGINX_KEEPALIVE_CHAT})" ;;
    esac
}
