#!/bin/bash
# tests/reference_v1.sh - the tuning block of nginx/autodeploy-nginx.sh as it was
# before extraction to lib/tuning.sh (lines 292-435 of commit 58ded96), verbatim,
# wrapped in a function. It is the oracle for the equivalence test: do not edit.
# shellcheck disable=all
reference_v1_compute() {
    print_warning() { tuning_warn "$1"; }
    
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
}
