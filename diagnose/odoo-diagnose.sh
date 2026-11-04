#!/bin/bash
# odoo-diagnose.sh - why is Odoo slow while the CPU looks idle?
#
# Copyright (C) 2025-2026 Makondoo Inc.
# Licence: AGPL-3.0-or-later
#
# Read-only. Looks at the host, the containers (if any), PostgreSQL, the Odoo
# configuration and the Odoo log, and reports what the processes are waiting
# on: CPU throttling, I/O, memory pressure, locks, DNS, connection limits,
# misconfiguration. Low CPU use plus slow responses means waiting, and
# "docker stats" cannot show waiting.
#
# Usage:
#   sudo ./odoo-diagnose.sh                 auto-detect everything on this host
#   ./odoo-diagnose.sh --odoo-conf /etc/odoo/odoo.conf --log /var/log/odoo/odoo.log
#   ./odoo-diagnose.sh --pg-cmd "docker exec -i mydb psql -U odoo -d postgres"
#   ./odoo-diagnose.sh --project mysite     only the containers of that compose project
#   ./odoo-diagnose.sh --no-docker          skip container checks
#   ./odoo-diagnose.sh --strict             exit 2 if anything critical was found
#
# Root (or sudo) is needed for cgroup, PostgreSQL-on-host and log access;
# without it the related checks are skipped and say so.
set -o pipefail

ODOO_CONF=""; LOG_FILE=""; PG_CMD=""; USE_DOCKER=true; STRICT=false; SAMPLE_SECS=3; PROJECT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --odoo-conf) ODOO_CONF=$2; shift 2 ;;
        --log) LOG_FILE=$2; shift 2 ;;
        --pg-cmd) PG_CMD=$2; shift 2 ;;
        --no-docker) USE_DOCKER=false; shift ;;
        --project) PROJECT=$2; shift 2 ;;
        --strict) STRICT=true; shift ;;
        --sample) SAMPLE_SECS=$2; shift 2 ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------- output
if [ -t 1 ]; then R='\033[0;31m'; Y='\033[1;33m'; G='\033[0;32m'; B='\033[0;34m'; N='\033[0m'; else R=''; Y=''; G=''; B=''; N=''; fi
N_OK=0; N_WARN=0; N_CRIT=0
section() { echo; echo -e "${B}== $1${N}"; }
ok()   { N_OK=$((N_OK+1));   echo -e "  ${G}[ OK ]${N} $1"; }
warn() { N_WARN=$((N_WARN+1)); echo -e "  ${Y}[WARN]${N} $1"; }
crit() { N_CRIT=$((N_CRIT+1)); echo -e "  ${R}[CRIT]${N} $1"; }
info() { echo -e "  [info] $1"; }
skip() { echo -e "  [skip] $1"; }
have() { command -v "$1" >/dev/null 2>&1; }
num()  { [[ "$1" =~ ^[0-9]+$ ]]; }
AS_ROOT=false; [ "$(id -u)" = 0 ] && AS_ROOT=true
SUDO=""; if [ "$AS_ROOT" = false ] && have sudo && sudo -n true 2>/dev/null; then SUDO="sudo -n"; fi

# ---------------------------------------------------------------- 1. host
section "Host"
CORES=$(nproc); RAM_MB=$(free -m | awk '/^Mem:/{print $2}'); SWAP_USED=$(free -m | awk '/^Swap:/{print $3}')
read -r L1 L5 L15 _ < /proc/loadavg
info "$CORES cores, ${RAM_MB} MB RAM, load ${L1} / ${L5} / ${L15} (1/5/15 min)"
if awk -v l="$L5" -v c="$CORES" 'BEGIN{exit !(l > c*1.5)}'; then
    warn "5-minute load ${L5} is above 1.5x the core count: requests are queueing for CPU"
elif awk -v l="$L5" -v c="$CORES" 'BEGIN{exit !(l > c)}'; then
    warn "5-minute load ${L5} exceeds the core count ${CORES}"
else
    ok "load is below the core count"
fi
[ "${SWAP_USED:-0}" -gt 256 ] && warn "${SWAP_USED} MB of swap in use: something is being paged out; check memory limits and worker counts" || ok "swap use is ${SWAP_USED:-0} MB"

# CPU time split over a short sample: iowait and steal are the "idle but slow" tells
read -r _ u1 n1 s1 i1 w1 q1 sq1 st1 _ < /proc/stat
sleep "$SAMPLE_SECS"
read -r _ u2 n2 s2 i2 w2 q2 sq2 st2 _ < /proc/stat
TOT=$(( (u2+n2+s2+i2+w2+q2+sq2+st2) - (u1+n1+s1+i1+w1+q1+sq1+st1) ))
if [ "$TOT" -gt 0 ]; then
    P_USER=$(( (u2+n2-u1-n1)*100/TOT )); P_SYS=$(( (s2-s1)*100/TOT )); P_IOW=$(( (w2-w1)*100/TOT )); P_STEAL=$(( (st2-st1)*100/TOT )); P_IDLE=$(( (i2-i1)*100/TOT ))
    info "CPU over ${SAMPLE_SECS}s: user ${P_USER}% system ${P_SYS}% iowait ${P_IOW}% steal ${P_STEAL}% idle ${P_IDLE}%"
    [ "$P_IOW" -ge 20 ] && crit "iowait ${P_IOW}%: the CPU is idle because it is waiting for the disk" || { [ "$P_IOW" -ge 8 ] && warn "iowait ${P_IOW}%: disk is a visible bottleneck"; }
    [ "$P_STEAL" -ge 5 ] && crit "steal ${P_STEAL}%: a shared-vCPU host is taking CPU time away from this VM (looks idle, runs slow)" || { [ "$P_STEAL" -ge 1 ] && warn "steal ${P_STEAL}%: shared-vCPU host; expect uneven performance"; }
fi

# Pressure stall information: the kernel's own "how long were tasks waiting"
if [ -r /proc/pressure/io ]; then
    for res in cpu memory io; do
        some=$(awk '/^some/{for(i=1;i<=NF;i++) if($i ~ /^avg60=/){split($i,a,"="); print a[2]}}' /proc/pressure/$res 2>/dev/null)
        [ -n "$some" ] || continue
        if awk -v v="$some" 'BEGIN{exit !(v >= 10)}'; then crit "pressure: tasks waited on ${res} ${some}% of the last minute"
        elif awk -v v="$some" 'BEGIN{exit !(v >= 2)}'; then warn "pressure: tasks waited on ${res} ${some}% of the last minute"
        else ok "no ${res} pressure (${some}% of the last minute)"; fi
    done
else
    skip "no /proc/pressure (kernel without PSI)"
fi

THP=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | grep -o '\[.*\]' | tr -d '[]')
case "$THP" in
    always) warn "transparent hugepages = always: PostgreSQL recommends never or madvise (latency spikes from compaction)" ;;
    "") skip "transparent hugepage setting not readable" ;;
    *) ok "transparent hugepages = ${THP}" ;;
esac
GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
[ "$GOV" = "powersave" ] && warn "CPU governor is powersave: cores run slow until load builds (set performance on a server)"
SWAPPINESS=$(cat /proc/sys/vm/swappiness 2>/dev/null); [ -n "$SWAPPINESS" ] && [ "$SWAPPINESS" -gt 30 ] && info "vm.swappiness=${SWAPPINESS} (10 is usual for a database host)"
if have lsblk; then
    while read -r name rota size model; do
        [ "$rota" = 1 ] && info "disk ${name} (${size}, ${model:-?}) is rotational: PostgreSQL commits wait on it; random_page_cost should be ~3, not 1.1" || info "disk ${name} (${size}, ${model:-?}) is SSD/NVMe"
    done < <(lsblk -d -n -o NAME,ROTA,SIZE,MODEL 2>/dev/null | grep -vE '^(loop|sr|zram)')
fi
if [ -r /proc/sys/net/netfilter/nf_conntrack_count ]; then
    cc=$(cat /proc/sys/net/netfilter/nf_conntrack_count); cm=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
    [ "$cc" -gt $((cm*8/10)) ] && crit "conntrack table ${cc}/${cm}: new connections get dropped when it fills (Docker NAT uses it)" || ok "conntrack ${cc}/${cm}"
fi
SOMAX=$(cat /proc/sys/net/core/somaxconn 2>/dev/null); [ -n "$SOMAX" ] && [ "$SOMAX" -lt 1024 ] && info "net.core.somaxconn=${SOMAX}: raise to 4096 for a busy proxy"

# ---------------------------------------------------------------- 2. containers
ODOO_CONTAINERS=(); PG_CONTAINER=""
if [ "$USE_DOCKER" = true ] && have docker && docker info >/dev/null 2>&1; then
    section "Containers"
    CG_ROOT=/sys/fs/cgroup
    [ -f "$CG_ROOT/cgroup.controllers" ] || info "cgroup v1 host: throttling and memory counters are read from a different layout and may be skipped"
    UP=$(cat /etc/docker/daemon.json 2>/dev/null | tr -d ' \n' | grep -o '"userland-proxy":[a-z]*' | cut -d: -f2)
    [ "${UP:-true}" = "true" ] && info "userland-proxy on (default): every published port goes through a docker-proxy process; keep traffic inside the compose network or front it with nginx in the same network" || ok "userland-proxy off"
    NPROXY=$(pgrep -c docker-proxy 2>/dev/null || echo 0); [ "$NPROXY" -gt 0 ] && info "${NPROXY} docker-proxy process(es) running"
    # Pick the compose project to look at: --project, else the one of the first
    # Odoo container found (a workstation can run many stacks at once).
    if [ -z "$PROJECT" ]; then
        projects=$(docker ps --format '{{.Label "com.docker.compose.project"}} {{.Image}} {{.Names}}' | awk 'tolower($0) ~ /odoo|doodba/ && $1 != "" {print $1}' | sort -u)
        if [ "$(echo "$projects" | grep -c .)" -gt 1 ]; then
            PROJECT=$(echo "$projects" | head -1)
            info "several compose projects run Odoo ($(echo "$projects" | paste -sd' ')): checking '${PROJECT}' (pass --project to choose)"
        fi
    fi
    while read -r cid name image project; do
        [ -n "$PROJECT" ] && [ "$project" != "$PROJECT" ] && continue
        role=""
        case "${image,,}" in
            *pgbouncer*) role=pgbouncer ;;
            *postgres*|*timescale*) role=postgres ;;
            *nginx*|*traefik*|*caddy*|*gateway*|*proxy*) role=proxy ;;
            *redis*|*minio*|*mailhog*|*smtp*|*whitelist*) role=aux ;;
            *odoo*|*doodba*) role=odoo ;;
        esac
        if [ -z "$role" ]; then
            case "${name,,}" in
                *pgbouncer*) role=pgbouncer ;;
                *postgres*|*-db-*|*_db_*|*-db$) role=postgres ;;
                *proxy*|*nginx*|*gateway*) role=proxy ;;
                *redis*|*minio*|*smtp*|*mail*) role=aux ;;
                *odoo*) role=odoo ;;
                *) continue ;;
            esac
        fi
        [ "$role" = odoo ] && ODOO_CONTAINERS+=("$name")
        [ "$role" = postgres ] && [ -z "$PG_CONTAINER" ] && PG_CONTAINER=$name
        insp=$(docker inspect "$cid" 2>/dev/null)
        # cgroup directories use the full 64-character id, docker ps the short one
        cid=$(echo "$insp" | grep -o '"Id": *"[0-9a-f]*"' | head -1 | cut -d'"' -f4)
        nano=$(echo "$insp" | grep -o '"NanoCpus": *[0-9]*' | grep -o '[0-9]*$')
        quota=$(echo "$insp" | grep -o '"CpuQuota": *-\?[0-9]*' | grep -o '\-\?[0-9]*$')
        mem=$(echo "$insp" | grep -o '"Memory": *[0-9]*' | head -1 | grep -o '[0-9]*$')
        logdrv=$(echo "$insp" | grep -o '"Type": *"[a-z-]*"' | head -1 | cut -d'"' -f4)
        echo "  -- ${name} (${role}, ${image})"
        limits=""
        [ -n "$nano" ] && [ "$nano" != 0 ] && limits+="cpus=$(awk -v n="$nano" 'BEGIN{printf "%.1f", n/1e9}') "
        [ -n "$quota" ] && [ "$quota" != 0 ] && [ "$quota" != -1 ] && limits+="cpu_quota=${quota} "
        [ -n "$mem" ] && [ "$mem" != 0 ] && limits+="memory=$((mem/1048576))MB "
        [ -n "$limits" ] && info "limits: ${limits}" || ok "no CPU/memory limits on the container (the host's scheduler decides)"
        # cgroup v2 counters: the proof of throttling and memory pressure
        cg=$(docker inspect --format '{{.HostConfig.CgroupParent}}' "$cid" 2>/dev/null)
        for candidate in "$CG_ROOT/system.slice/docker-${cid}.scope" "$CG_ROOT/docker/${cid}" "$CG_ROOT/${cg}/docker-${cid}.scope"; do
            [ -d "$candidate" ] && cgdir=$candidate && break
        done
        if [ -n "${cgdir:-}" ] && [ -r "$cgdir/cpu.stat" ]; then
            nr_p=$(awk '/^nr_periods/{print $2}' "$cgdir/cpu.stat"); nr_t=$(awk '/^nr_throttled/{print $2}' "$cgdir/cpu.stat"); t_us=$(awk '/^throttled_usec/{print $2}' "$cgdir/cpu.stat")
            if [ -n "$nr_p" ] && [ "${nr_p:-0}" -gt 0 ] && [ "${nr_t:-0}" -gt 0 ]; then
                pct=$(( nr_t*100/nr_p ))
                [ "$pct" -ge 10 ] && crit "CPU throttled in ${pct}% of scheduler periods (${t_us} us total): the container's cpus limit is too low; processes sit idle waiting for the next period" || { [ "$pct" -ge 1 ] && warn "CPU throttled in ${pct}% of scheduler periods (${t_us} us total)"; }
            elif [ -n "$nr_p" ]; then ok "no CPU throttling"; fi
            if [ -r "$cgdir/memory.events" ]; then
                oom=$(awk '/^oom_kill/{print $2}' "$cgdir/memory.events"); high=$(awk '/^high/{print $2}' "$cgdir/memory.events"); mx=$(awk '/^max/{print $2}' "$cgdir/memory.events")
                [ "${oom:-0}" -gt 0 ] && crit "memory cgroup OOM-killed processes ${oom} time(s): workers die mid-request" || ok "no OOM kills in this container"
                [ "${mx:-0}" -gt 0 ] && warn "memory limit hit ${mx} time(s) (reclaim stalls)"
                [ "${high:-0}" -gt 0 ] && info "memory.high throttling events: ${high}"
            fi
            if [ -r "$cgdir/memory.current" ] && [ -r "$cgdir/memory.max" ]; then
                cur=$(cat "$cgdir/memory.current"); mxb=$(cat "$cgdir/memory.max")
                if [ "$mxb" != max ] && [ "$mxb" -gt 0 ]; then
                    pct=$(( cur*100/mxb )); file=$(awk '/^file /{print $2}' "$cgdir/memory.stat" 2>/dev/null)
                    [ "$pct" -ge 90 ] && warn "memory ${pct}% of its limit ($((cur/1048576))/$((mxb/1048576)) MB); page cache inside it: $((${file:-0}/1048576)) MB" || info "memory $((cur/1048576)) MB of $((mxb/1048576)) MB limit (page cache $((${file:-0}/1048576)) MB)"
                    [ "$role" = postgres ] && warn "a memory limit on the PostgreSQL container also caps its page cache: data that bare-metal PostgreSQL would read from RAM is read from disk here"
                fi
            fi
        elif [ -r "$CG_ROOT/cpu,cpuacct/docker/${cid}/cpu.stat" ] || [ -r "$CG_ROOT/cpu/docker/${cid}/cpu.stat" ]; then
            # cgroup v1 layout (older hosts)
            v1cpu=$CG_ROOT/cpu,cpuacct/docker/${cid}; [ -d "$v1cpu" ] || v1cpu=$CG_ROOT/cpu/docker/${cid}
            nr_p=$(awk '/^nr_periods/{print $2}' "$v1cpu/cpu.stat"); nr_t=$(awk '/^nr_throttled/{print $2}' "$v1cpu/cpu.stat"); t_ns=$(awk '/^throttled_time/{print $2}' "$v1cpu/cpu.stat")
            if [ "${nr_p:-0}" -gt 0 ] && [ "${nr_t:-0}" -gt 0 ]; then
                pct=$(( nr_t*100/nr_p ))
                [ "$pct" -ge 10 ] && crit "CPU throttled in ${pct}% of scheduler periods ($((t_ns/1000000)) ms total): the container's cpus limit is too low" || { [ "$pct" -ge 1 ] && warn "CPU throttled in ${pct}% of scheduler periods ($((t_ns/1000000)) ms total)"; }
            else ok "no CPU throttling"; fi
            v1mem=$CG_ROOT/memory/docker/${cid}
            if [ -r "$v1mem/memory.oom_control" ]; then
                oom=$(awk '/^oom_kill /{print $2}' "$v1mem/memory.oom_control"); [ "${oom:-0}" -gt 0 ] && crit "memory cgroup OOM-killed processes ${oom} time(s): workers die mid-request" || ok "no OOM kills in this container"
                cur=$(cat "$v1mem/memory.usage_in_bytes" 2>/dev/null); mxb=$(cat "$v1mem/memory.limit_in_bytes" 2>/dev/null); file=$(awk '/^cache /{print $2}' "$v1mem/memory.stat" 2>/dev/null)
                if [ -n "$mxb" ] && [ "$mxb" -lt 9000000000000000000 ]; then
                    pct=$(( cur*100/mxb )); [ "$pct" -ge 90 ] && warn "memory ${pct}% of its limit ($((cur/1048576))/$((mxb/1048576)) MB); page cache inside it: $((${file:-0}/1048576)) MB" || info "memory $((cur/1048576)) MB of $((mxb/1048576)) MB limit (page cache $((${file:-0}/1048576)) MB)"
                    [ "$role" = postgres ] && warn "a memory limit on the PostgreSQL container also caps its page cache: data that bare-metal PostgreSQL would read from RAM is read from disk here"
                fi
            fi
        else
            [ "$AS_ROOT" = true ] && skip "cgroup counters not found for this container (unknown cgroup layout)" || skip "cgroup counters not readable (run as root for throttling/OOM evidence)"
        fi
        unset cgdir
        # where the state lives
        while IFS='|' read -r mtype src dst; do
            [ -z "$dst" ] && continue
            case "$dst" in
                /var/lib/postgresql*|/var/lib/odoo*|/opt/odoo*|/mnt/*|/data*)
                    [ "$mtype" = volume ] || [ "$mtype" = bind ] && info "${dst} <- ${mtype} ${src}" ;;
            esac
        done < <(echo "$insp" | tr -d '\n' | grep -o '"Mounts": *\[[^]]*\]' | grep -o '{[^}]*}' | sed -E 's/.*"Type": *"([^"]*)".*"Source": *"([^"]*)".*"Destination": *"([^"]*)".*/\1|\2|\3/')
        if [ "$role" = postgres ]; then
            if ! echo "$insp" | tr -d '\n' | grep -o '"Mounts": *\[[^]]*\]' | grep -q '/var/lib/postgresql'; then
                crit "PostgreSQL data is not on a volume or bind mount: every write goes through the overlay filesystem"
            fi
            shm=$(docker exec "$cid" df -m /dev/shm 2>/dev/null | awk 'NR==2{print $2}')
            [ -n "$shm" ] && { [ "$shm" -le 64 ] && warn "/dev/shm is ${shm} MB (Docker default): parallel query and large sorts fail or spill; set shm_size" || ok "/dev/shm ${shm} MB"; }
        fi
        if [ "$role" = odoo ]; then
            if ! echo "$insp" | tr -d '\n' | grep -o '"Mounts": *\[[^]]*\]' | grep -qE '/var/lib/odoo|/opt/odoo|/data'; then
                warn "no volume for the Odoo data dir: the filestore is written into the container layer"
            fi
            # DNS inside the container: a slow resolver shows up as random stalls
            if docker exec "$cid" sh -c 'command -v getent' >/dev/null 2>&1; then
                dbhost=$(docker exec "$cid" sh -c 'grep -E "^\s*db_host" "${ODOO_RC:-/etc/odoo/odoo.conf}" 2>/dev/null | head -1 | cut -d= -f2 | tr -d " "' 2>/dev/null)
                [ -z "$dbhost" ] || [ "$dbhost" = False ] && dbhost=$(docker exec "$cid" sh -c 'echo "${HOST:-db}"' 2>/dev/null)
                t0=$(date +%s%N); docker exec "$cid" getent hosts "$dbhost" >/dev/null 2>&1; rc=$?; t1=$(date +%s%N); ms=$(( (t1-t0)/1000000 ))
                if [ $rc -ne 0 ]; then warn "cannot resolve db host '${dbhost}' from inside ${name}"
                elif [ "$ms" -ge 1000 ]; then crit "resolving '${dbhost}' inside the container took ${ms} ms: every new database connection waits that long (check resolv.conf search domains / ndots, upstream DNS)"
                elif [ "$ms" -ge 100 ]; then warn "resolving '${dbhost}' took ${ms} ms"
                else ok "resolves '${dbhost}' in ${ms} ms"; fi
            fi
            opts=$(docker exec "$cid" sh -c 'grep ^options /etc/resolv.conf' 2>/dev/null); [ -n "$opts" ] && info "resolv.conf: ${opts}"
            [ "$logdrv" = journald ] && warn "logging driver journald: Odoo's stdout logging blocks on journald under load; use json-file or a logfile"
        fi
    done < <(docker ps --format '{{.ID}} {{.Names}} {{.Image}} {{.Label "com.docker.compose.project"}}')
    [ ${#ODOO_CONTAINERS[@]} -eq 0 ] && [ -z "$PG_CONTAINER" ] && info "no Odoo/PostgreSQL containers running"
elif [ "$USE_DOCKER" = true ]; then
    section "Containers"; skip "docker not available or not running (bare-metal host, or run with sudo)"
fi

# ---------------------------------------------------------------- 3. postgresql
section "PostgreSQL"
if [ -z "$PG_CMD" ]; then
    if [ -n "$PG_CONTAINER" ]; then
        pguser=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$PG_CONTAINER" | awk -F= '/^POSTGRES_USER=/{print $2}')
        PG_CMD="docker exec -i $PG_CONTAINER psql -U ${pguser:-postgres} -d postgres"
    elif have psql && id postgres >/dev/null 2>&1; then
        if [ "$AS_ROOT" = true ]; then
            have runuser && PG_CMD="runuser -u postgres -- psql -d postgres" || PG_CMD="su postgres -c psql -d postgres"
        elif [ -n "$SUDO" ]; then
            PG_CMD="$SUDO -u postgres psql -d postgres"
        fi
    fi
fi
psq() { timeout 20 $PG_CMD -X -q -t -A -F'|' -c "$1" 2>/dev/null; }
if [ -n "$PG_CMD" ] && psq "select 1" | grep -q 1; then
    ver=$(psq "show server_version" | cut -d' ' -f1); info "server ${ver} via: ${PG_CMD}"
    for k in shared_buffers effective_cache_size work_mem maintenance_work_mem max_connections huge_pages synchronous_commit random_page_cost jit shared_preload_libraries track_io_timing; do
        printf '  [info] %-24s %s\n' "$k" "$(psq "show $k")"
    done
    [ "${ver%%.*}" -ge 18 ] 2>/dev/null && info "io_method = $(psq 'show io_method'), io_workers = $(psq 'show io_workers')"
    sb=$(psq "select setting::bigint*8/1024 from pg_settings where name='shared_buffers'")
    [ -n "$sb" ] && [ "$sb" -le 256 ] && crit "shared_buffers is ${sb} MB (the default): PostgreSQL has not been tuned for this machine"
    hp=$(psq "select setting from pg_settings where name='huge_pages_status'"); [ -n "$hp" ] && info "huge_pages_status = ${hp}"
    [ "$(psq 'show jit')" = on ] && info "jit=on: Odoo's many small queries pay JIT compile time; off is usually faster"
    mc=$(psq "show max_connections"); used=$(psq "select count(*) from pg_stat_activity where backend_type='client backend'")
    [ -n "$used" ] && { [ "$used" -ge $((mc*9/10)) ] && crit "${used}/${mc} connections in use: Odoo workers will fail with 'too many connections'" || ok "${used}/${mc} connections in use"; }
    iit=$(psq "select count(*) from pg_stat_activity where state='idle in transaction' and xact_start < now()-interval '2 minutes'")
    [ "${iit:-0}" -gt 0 ] && warn "${iit} session(s) idle in transaction for over 2 minutes: they hold locks and connections" || ok "no long idle-in-transaction sessions"
    longq=$(psq "select count(*) from pg_stat_activity where state='active' and query_start < now()-interval '30 seconds' and backend_type='client backend'")
    [ "${longq:-0}" -gt 0 ] && warn "${longq} query(ies) running for over 30 s" || ok "no query running longer than 30 s"
    waits=$(psq "select wait_event_type||':'||wait_event||'='||count(*) from pg_stat_activity where state='active' and wait_event is not null and backend_type='client backend' group by 1,2 order by count(*) desc limit 6" | paste -sd' ')
    if [ -n "$waits" ]; then
        info "active backends waiting on: ${waits}"
        echo "$waits" | grep -q '^Lock\|[ ]Lock' && crit "backends are waiting on locks: a transaction holds a row or table other requests need (check idle-in-transaction and long updates)"
        echo "$waits" | grep -q 'IO:' && warn "backends are waiting on disk I/O"
    else ok "no active backend is waiting on anything right now"; fi
    hit=$(psq "select round(100*sum(blks_hit)/nullif(sum(blks_hit)+sum(blks_read),0),1) from pg_stat_database")
    if [ -n "$hit" ]; then awk -v h="$hit" 'BEGIN{exit !(h < 95)}' && warn "buffer cache hit ratio ${hit}%: data is being read from disk (shared_buffers / RAM too small for the working set)" || ok "buffer cache hit ratio ${hit}%"; fi
    tmp=$(psq "select pg_size_pretty(sum(temp_bytes)) || ' in ' || sum(temp_files) || ' files since ' || min(stats_reset)::date from pg_stat_database where temp_files > 0")
    [ -n "$tmp" ] && info "temp files (sorts/hashes spilling past work_mem): ${tmp}"
    dl=$(psq "select sum(deadlocks) from pg_stat_database"); [ "${dl:-0}" -gt 0 ] && info "deadlocks since stats reset: ${dl}"
    if [ "${ver%%.*}" -ge 17 ] 2>/dev/null; then ck=$(psq "select num_timed||'|'||num_requested from pg_stat_checkpointer"); else ck=$(psq "select checkpoints_timed||'|'||checkpoints_req from pg_stat_bgwriter"); fi
    if [ -n "$ck" ]; then ct=${ck%%|*}; cr=${ck##*|}; [ "${cr:-0}" -gt "${ct:-0}" ] && warn "checkpoints requested (${cr}) exceed timed (${ct}): max_wal_size is too small, causing write bursts" || ok "checkpoints: ${ct} timed, ${cr} requested"; fi
    dead=$(psq "select string_agg(relname||'='||n_dead_tup, ' ') from (select relname, n_dead_tup from pg_stat_user_tables where n_dead_tup > 100000 order by n_dead_tup desc limit 5) t")
    [ -n "$dead" ] && warn "tables with over 100k dead rows (autovacuum lagging): ${dead}"
    # pg_stat_statements lives in whichever database created the extension:
    # look in every non-template database, Odoo databases first
    pss_db=""
    for d in $(psq "select datname from pg_database where not datistemplate order by (datname='postgres'), datname"); do
        if timeout 20 ${PG_CMD/-d postgres/-d "$d"} -X -q -t -A -c "select 1 from pg_extension where extname='pg_stat_statements'" 2>/dev/null | grep -q 1; then pss_db=$d; break; fi
    done
    if [ -n "$pss_db" ]; then
        info "slowest statements by total time (pg_stat_statements in ${pss_db}):"
        timeout 20 ${PG_CMD/-d postgres/-d "$pss_db"} -X -q -t -A -c "select round(total_exec_time/1000)||'s '||calls||'x '||round(mean_exec_time)||'ms  '||left(regexp_replace(query,'\s+',' ','g'),90) from pg_stat_statements where query not ilike '%pg_stat%' order by total_exec_time desc limit 5" 2>/dev/null | sed 's/^/         /'
    else info "pg_stat_statements not installed in any database: no per-query evidence (CREATE EXTENSION pg_stat_statements in the Odoo database)"; fi
else
    skip "no PostgreSQL access (give --pg-cmd, e.g. \"docker exec -i db psql -U odoo -d postgres\" or run with sudo on a bare-metal host)"
fi

# ---------------------------------------------------------------- 4. odoo config
section "Odoo configuration"
conf_text=""
if [ -n "$ODOO_CONF" ]; then conf_text=$($SUDO cat "$ODOO_CONF" 2>/dev/null); src=$ODOO_CONF
elif [ ${#ODOO_CONTAINERS[@]} -gt 0 ]; then conf_text=$(docker exec "${ODOO_CONTAINERS[0]}" sh -c 'cat "${ODOO_RC:-/etc/odoo/odoo.conf}"' 2>/dev/null); src="${ODOO_CONTAINERS[0]}:$(docker exec "${ODOO_CONTAINERS[0]}" sh -c 'echo "${ODOO_RC:-/etc/odoo/odoo.conf}"' 2>/dev/null)"
else for f in /etc/odoo/odoo.conf /etc/odoo.conf /opt/odoo/odoo.conf; do [ -r "$f" ] || $SUDO test -r "$f" 2>/dev/null && { conf_text=$($SUDO cat "$f" 2>/dev/null); src=$f; break; }; done; fi
cval() { echo "$conf_text" | grep -E "^\s*$1\s*=" | head -1 | cut -d= -f2- | tr -d ' \r'; }
if [ -n "$conf_text" ]; then
    info "reading ${src}"
    W=$(cval workers); CT=$(cval max_cron_threads); LMS=$(cval limit_memory_soft); LMH=$(cval limit_memory_hard); LTR=$(cval limit_time_real); DBM=$(cval db_maxconn)
    PM=$(cval proxy_mode); LDB=$(cval list_db); DBF=$(cval dbfilter); LL=$(cval log_level); DEV=$(cval dev_mode); DBN=$(cval db_name)
    info "workers=${W:-unset} max_cron_threads=${CT:-unset} limit_memory_soft=${LMS:-unset} limit_memory_hard=${LMH:-unset} limit_time_real=${LTR:-unset} db_maxconn=${DBM:-unset}"
    info "proxy_mode=${PM:-unset} list_db=${LDB:-unset} dbfilter=${DBF:-unset} db_name=${DBN:-unset} log_level=${LL:-unset} dev_mode=${DEV:-unset}"
    if [ -z "$W" ] || [ "$W" = 0 ]; then crit "workers=${W:-unset}: single-process mode serves one request at a time; production needs workers (cores*2+1 at most)"; else ok "${W} workers"; fi
    if num "${W:-x}" && [ "$W" -gt $((CORES*2+1)) ]; then warn "workers=${W} is above cores*2+1 (${CORES} cores): processes compete for CPU and PostgreSQL connections"; fi
    [ "${CT:-1}" = 0 ] && warn "max_cron_threads=0: scheduled actions (emails, reports) never run on this instance"
    if num "${LMS:-x}"; then [ "$LMS" -lt 629145600 ] && warn "limit_memory_soft=$((LMS/1048576)) MB is small for Odoo 16+: workers get recycled after big requests, each restart reloads the registry (seconds of waiting)"; fi
    [ "${DEV:-}" != "" ] && crit "dev_mode=${DEV} in the config: development mode on a production instance"
    [ "${LL:-info}" = debug ] && warn "log_level=debug: heavy logging costs CPU and disk on every request"
    if [ "${LDB:-True}" != False ] && [ -z "$DBF" ] && [ -z "$DBN" ]; then warn "list_db on and no dbfilter/db_name: Odoo guesses the database on every request and the manager is exposed"; fi
    proxy_present=false
    { have nginx || systemctl is-active --quiet nginx 2>/dev/null || docker ps --format '{{.Image}}' 2>/dev/null | grep -qiE 'nginx|traefik|caddy'; } && proxy_present=true
    [ "$proxy_present" = true ] && [ "${PM:-False}" != True ] && warn "a reverse proxy is present but proxy_mode is not True: client IPs, scheme and websocket upgrades are wrong behind it"
    # compare with the tuning library if this is a checkout
    LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/tuning.sh"
    if [ -f "$LIB" ] && num "${W:-x}"; then
        # shellcheck source=../lib/tuning.sh
        ( source "$LIB"; tuning_warn() { :; }; CPU_CORES=$CORES TOTAL_RAM_MB=$RAM_MB NUM_VERSIONS=1 USE_PGBOUNCER=false odoo_tuning_compute
          [ "$W" -ne "$OPTIMAL_WORKERS" ] && echo "  [info] lib/tuning.sh would size this machine at ${OPTIMAL_WORKERS} workers (RAM allows ${MAX_WORKERS_BY_RAM}, CPU ${MAX_WORKERS_BY_CPU}); deployed: ${W}" || echo "  [info] worker count matches lib/tuning.sh for this machine" )
    fi
else
    skip "no odoo.conf found (give --odoo-conf)"
fi

# ---------------------------------------------------------------- 5. odoo log
section "Odoo log (last 20000 lines)"
log_text=""
if [ -n "$LOG_FILE" ]; then log_text=$($SUDO tail -n 20000 "$LOG_FILE" 2>/dev/null); lsrc=$LOG_FILE
elif [ -n "$conf_text" ] && [ -n "$(cval logfile)" ] && [ ${#ODOO_CONTAINERS[@]} -eq 0 ]; then lf=$(cval logfile); log_text=$($SUDO tail -n 20000 "$lf" 2>/dev/null); lsrc=$lf
elif [ ${#ODOO_CONTAINERS[@]} -gt 0 ]; then
    lf=$(cval logfile); c=${ODOO_CONTAINERS[0]}
    if [ -n "$lf" ] && docker exec "$c" test -r "$lf" 2>/dev/null; then log_text=$(docker exec "$c" tail -n 20000 "$lf" 2>/dev/null | tr -d '\0'); lsrc="$c:$lf"
    else log_text=$(docker logs --tail 20000 "$c" 2>&1 | tr -d '\0'); lsrc="docker logs $c"; fi
fi
if [ -n "$log_text" ]; then
    info "reading ${lsrc}"
    cnt() { echo "$log_text" | grep -cE "$1"; }
    n=$(cnt 'Worker .*\(.*\) killed|limit_memory|MemoryError'); [ "$n" -gt 0 ] && warn "${n} worker recycle/kill messages: memory limits too tight or a runaway request" || ok "no worker kills"
    n=$(cnt 'CPU time limit|Request timed out|limit_time'); [ "$n" -gt 0 ] && warn "${n} request time/CPU limit messages" || ok "no request time-limit kills"
    n=$(cnt 'too many connections|connection pool is full|remaining connection slots'); [ "$n" -gt 0 ] && crit "${n} PostgreSQL connection exhaustion messages" || ok "no connection exhaustion"
    n=$(cnt 'could not serialize|deadlock detected'); [ "$n" -gt 0 ] && warn "${n} serialization/deadlock retries (concurrent writes to the same rows, e.g. sequences, stock quants, mail followers)" || ok "no serialization failures"
    n=$(cnt 'OperationalError|could not connect to server|server closed the connection'); [ "$n" -gt 0 ] && warn "${n} database connection errors" || ok "no database connection errors"
    n=$(cnt ' ERROR '); info "${n} ERROR lines"
    n=$(cnt 'wkhtmltopdf.*(not found|broken|failed)|You need Wkhtmltopdf'); [ "$n" -gt 0 ] && crit "wkhtmltopdf problems: PDF reports fall back or fail"
    n=$(cnt 'longpolling.*404|/websocket.*(404|400)'); [ "$n" -ge 20 ] && warn "${n} failed websocket/longpolling requests: the proxy is not routing /websocket to the gevent port, browsers fall back to polling" || { [ "$n" -gt 0 ] && info "${n} failed websocket/longpolling request(s) (a handful is usually scanners)"; }
    slow=$(echo "$log_text" | grep -oE 'werkzeug: [^ ]+ .* "[A-Z]+ [^ ]+ HTTP[^"]*" [0-9]{3} - [0-9]+ [0-9.]+ [0-9.]+' | awk '{t=$(NF); if (t+0 > 5) n++} END{print n+0}')
    [ "${slow:-0}" -gt 0 ] && warn "${slow} requests took more than 5 s of wall time in the sampled log" || ok "no request over 5 s in the sampled log"
else
    skip "no Odoo log found (give --log)"
fi

# ---------------------------------------------------------------- 6. proxy
section "Reverse proxy"
nconf=""
if have nginx; then nconf=$($SUDO nginx -T 2>/dev/null)
elif docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -qi nginx; then nc_name=$(docker ps --format '{{.Names}} {{.Image}}' | grep -i nginx | head -1 | cut -d' ' -f1); nconf=$(docker exec "$nc_name" nginx -T 2>/dev/null); fi
if [ -n "$nconf" ]; then
    echo "$nconf" | grep -q 'location /websocket' && ok "/websocket is routed" || crit "no 'location /websocket' in the nginx config: live chat/notifications fall back to polling and every tab hammers the workers"
    echo "$nconf" | grep -q 'X-Forwarded-Proto' && ok "X-Forwarded-Proto is set" || warn "X-Forwarded-Proto not set: Odoo builds http:// links behind https"
    echo "$nconf" | grep -qE 'proxy_cache|expires' && ok "static assets are cached (proxy_cache/expires found)" || info "no asset caching in nginx: every /web/assets and static file hits Odoo"
    echo "$nconf" | grep -qE 'proxy_read_timeout +[0-9]+' && info "proxy_read_timeout: $(echo "$nconf" | grep -oE 'proxy_read_timeout +[0-9]+[a-z]*' | head -1)"
else
    skip "no nginx found on the host or in a container"
fi

# ---------------------------------------------------------------- summary
section "Summary"
echo "  ${N_OK} ok, ${N_WARN} warnings, ${N_CRIT} critical"
if [ "$N_CRIT" -gt 0 ]; then echo "  Fix the critical items first; they explain 'idle but slow' far more often than Docker itself."; fi
[ "$STRICT" = true ] && [ "$N_CRIT" -gt 0 ] && exit 2
exit 0
