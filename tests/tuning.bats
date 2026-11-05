#!/usr/bin/env bats
# Tests for lib/tuning.sh.
#
# 1. Equivalence: for a matrix of machines the library must produce exactly
#    the values the v1 inline block in nginx/autodeploy-nginx.sh produced
#    (tests/reference_v1.sh is that block, verbatim, wrapped in a function).
# 2. Expectations: a few hand-checked plans so a regression is readable.

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# Print VAR=value for every tuning variable after running the given function.
plan() {
    local fn=$1 cores=$2 ram=$3 versions=$4 pgb=$5 v
    (
        CPU_CORES=$cores TOTAL_RAM_MB=$ram NUM_VERSIONS=$versions USE_PGBOUNCER=$pgb
        "$fn"
        for v in OPTIMAL_WORKERS MAX_CRON_THREADS WORKER_MEMORY_MB SOFT_LIMIT_MB \
                 HARD_LIMIT_BYTES SOFT_LIMIT_BYTES DB_MAXCONN MAX_CONNECTIONS \
                 SHARED_BUFFERS EFFECTIVE_CACHE_SIZE MAINTENANCE_WORK_MEM WORK_MEM \
                 MAX_WAL_SIZE MIN_WAL_SIZE AUTOVACUUM_WORKERS MAX_WORKER_PROCESSES \
                 MAX_PARALLEL_WORKERS MAX_PARALLEL_PER_GATHER MAX_PARALLEL_MAINTENANCE \
                 SHM_SIZE IO_WORKERS PGB_DEFAULT_POOL_SIZE PGB_MAX_DB_CONNECTIONS \
                 PGB_MAX_CLIENT_CONN NGINX_WORKER_CONNECTIONS NGINX_RLIMIT_NOFILE \
                 NGINX_KEEPALIVE NGINX_KEEPALIVE_CHAT; do
            echo "$v=${!v:-}"
        done
    )
}

setup() {
    source "$REPO/lib/tuning.sh"
    source "$REPO/tests/reference_v1.sh"
    tuning_warn() { :; }
}

@test "library matches the v1 inline block across a machine matrix" {
    local cores ram versions pgb ref lib
    for cores in 1 2 4 8 16 32 64 128 256; do
        for ram in 2048 4096 8192 16384 32768 65536 262144 1048576; do
            for versions in 1 2 4; do
                for pgb in false true; do
                    ref=$(plan reference_v1_compute "$cores" "$ram" "$versions" "$pgb")
                    lib=$(plan odoo_tuning_compute "$cores" "$ram" "$versions" "$pgb")
                    if [ "$ref" != "$lib" ]; then
                        echo "mismatch for cores=$cores ram=$ram versions=$versions pgbouncer=$pgb"
                        diff <(echo "$ref") <(echo "$lib")
                        return 1
                    fi
                done
            done
        done
    done
}

@test "small VPS: 2 cores, 2 GB, no pooler" {
    CPU_CORES=2 TOTAL_RAM_MB=2048 NUM_VERSIONS=1 USE_PGBOUNCER=false
    odoo_tuning_compute
    [ "$OPTIMAL_WORKERS" -eq 1 ]
    [ "$WORKER_MEMORY_MB" -eq 512 ] && [ "$SOFT_LIMIT_MB" -eq 400 ]
    [ "$MAX_CONNECTIONS" -eq 100 ]
    [ "$DB_MAXCONN" -eq 64 ]
    [ "$SHARED_BUFFERS" -eq 512 ]
    [ "$SHM_SIZE" = "256mb" ]
    [ "$ODOO_DB_HOST" = "db" ]
}

@test "4 cores, 30 GB (a typical bare-metal box): workers follow the CPU cap" {
    CPU_CORES=4 TOTAL_RAM_MB=30720 NUM_VERSIONS=1 USE_PGBOUNCER=false
    odoo_tuning_compute
    [ "$OPTIMAL_WORKERS" -eq 9 ]      # cores*2+1
    [ "$MAX_WORKERS_BY_RAM" -eq 10 ]
    [ "$SHARED_BUFFERS" -eq 7680 ]
    [ "$MAX_CONNECTIONS" -eq 43 ] || [ "$MAX_CONNECTIONS" -eq 100 ]
    [ "$MAX_CONNECTIONS" -eq 100 ]    # floor
}

@test "64 cores, 256 GB, no pooler: RAM-bound at 120 workers, shared_buffers capped at 16 GB" {
    CPU_CORES=64 TOTAL_RAM_MB=262144 NUM_VERSIONS=1 USE_PGBOUNCER=false
    odoo_tuning_compute
    [ "$OPTIMAL_WORKERS" -eq 120 ]
    [ "$SHARED_BUFFERS" -eq 16384 ]
    [ "$MAX_CONNECTIONS" -eq 310 ]
    [ "$MAX_PARALLEL_WORKERS" -eq 64 ]
    [ "$IO_WORKERS" -eq 16 ]
}

@test "64 cores, 256 GB, pgbouncer: connection budget follows cores, not workers" {
    CPU_CORES=64 TOTAL_RAM_MB=262144 NUM_VERSIONS=1 USE_PGBOUNCER=true
    odoo_tuning_compute
    [ "$OPTIMAL_WORKERS" -eq 120 ]
    [ "$MAX_CONNECTIONS" -eq 276 ]
    [ "$PGB_DEFAULT_POOL_SIZE" -eq 64 ]
    [ "$PGB_MAX_DB_CONNECTIONS" -eq 256 ]
    [ "$PGB_MAX_CLIENT_CONN" -eq 1984 ]
    [ "$ODOO_DB_HOST" = "pgbouncer" ]
}

@test "256 cores, 1 TB, no pooler: hits the 1000-connection cap and warns" {
    CPU_CORES=256 TOTAL_RAM_MB=1048576 NUM_VERSIONS=1 USE_PGBOUNCER=false
    local warned=""
    tuning_warn() { warned=$1; }
    odoo_tuning_compute
    [ "$MAX_CONNECTIONS" -eq 1000 ]
    [ "$OPTIMAL_WORKERS" -eq 407 ]
    [[ "$warned" == *"1000-connection"* ]]
}

@test "four versions share the host: workers and connections are split" {
    CPU_CORES=8 TOTAL_RAM_MB=32768 NUM_VERSIONS=4 USE_PGBOUNCER=false
    odoo_tuning_compute
    [ "$MAX_WORKERS_BY_CPU" -eq 5 ]   # ceil(17/4)
    [ "$OPTIMAL_WORKERS" -eq 2 ]      # RAM-bound: (26214-8704)/4/1600 = 2.7
}

@test "print formats: env and json carry every variable" {
    CPU_CORES=4 TOTAL_RAM_MB=8192 NUM_VERSIONS=1 USE_PGBOUNCER=true
    odoo_tuning_compute
    run odoo_tuning_print env
    [[ "$output" == *"OPTIMAL_WORKERS="* ]]
    [[ "$output" == *"PGB_MAX_CLIENT_CONN="* ]]
    run odoo_tuning_print json
    [[ "$output" == "{"*"\"OPTIMAL_WORKERS\": "*"}" ]]
}

@test "odoo-tune CLI runs and accepts explicit hardware" {
    run "$REPO/bin/odoo-tune" --cores 4 --ram-mb 8192 --versions 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"workers=2 per version"* ]]
    run "$REPO/bin/odoo-tune" --cores 4 --ram-mb 8192 --pgbouncer --format env
    [ "$status" -eq 0 ]
    [[ "$output" == *"ODOO_DB_HOST=pgbouncer"* ]]
    run "$REPO/bin/odoo-tune" --cores x
    [ "$status" -ne 0 ]
}
