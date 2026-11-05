#!/bin/bash
# Run a load series: one Locust run per stage, CPU of the load generator
# capped at one core so it cannot starve the system under test.
#
# Usage:
#   URL=http://127.0.0.1:8069 ./run.sh stages.txt
# A stages file has one line per stage:
#   label backend pos browser buyer minutes
# e.g.
#   C0025 10 3 20 5 5
#   C0050 10 3 40 10 5
# Settings:
#   URL          Odoo base URL (required)
#   PREP_JSON    prep.json from copy-*.sh (default ./prep.json)
#   RESULTS      results directory (default ./results)
#   STOP_RATIO   stop the series when a stage fails more than this share of requests (default 0.05)
#   SPAWN_RATE   users started per second (default 3; 8 above 450 users)
#   LOCUST       how to run locust: "venv" (default, ./venv) or "docker" (python:3.12 image)
#   CPU_QUOTA    cap for the load generator (default 100 = one core)
#   MONITOR_CMD  command printing one line of CPU use per call (optional; see below)
#   EVENT_SLUG, PAGES, ODOO_LANG, ODOO_TZ  passed to locustfile.py
#
# Every 5 s the stage's .stats file records the load average and, when
# MONITOR_CMD is set, its output (for example
#   MONITOR_CMD='docker stats --no-stream --format "{{.Name}}={{.CPUPerc}}" myproj-odoo-1 myproj-db-1'
# or, on systemd hosts, the CPU seconds of the odoo and postgresql units).
#
# Copyright (C) 2025-2026 Makondoo Inc. Licence: AGPL-3.0-or-later
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STAGE_FILE=${1:?usage: URL=http://host:8069 ./run.sh stages.txt}
: "${URL:?URL is required}"
PREP_JSON=${PREP_JSON:-./prep.json}; RESULTS=${RESULTS:-./results}; STOP_RATIO=${STOP_RATIO:-0.05}
LOCUST=${LOCUST:-venv}; CPU_QUOTA=${CPU_QUOTA:-100}
mkdir -p "$RESULTS"
[ -f "$PREP_JSON" ] || { echo "prep.json not found at $PREP_JSON (run copy-docker.sh or copy-baremetal.sh first)"; exit 1; }
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("db",""))' "$PREP_JSON")" != "" ] || { echo "prep.json has no db"; exit 1; }

locust_cmd() {
    # $@ = locust arguments; runs with the load-generator CPU cap
    local env_args=(PREP_JSON="$PREP_JSON" N_BACKEND="$NB" N_POS="$NP" N_BROWSER="$NW" N_BUYER="$NBUY"
                    EVENT_SLUG="${EVENT_SLUG:-}" PAGES="${PAGES:-/,/contactus}" ODOO_LANG="${ODOO_LANG:-en_US}" ODOO_TZ="${ODOO_TZ:-UTC}"
                    REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-60}")
    if [ "$LOCUST" = docker ]; then
        docker run --rm --cpus="$(awk -v q="$CPU_QUOTA" 'BEGIN{print q/100}')" --network host \
            -v "$HERE:/lt:ro" -v "$(cd "$(dirname "$PREP_JSON")" && pwd):/prep:ro" -v "$(cd "$RESULTS" && pwd):/results" \
            "${env_args[@]/#/-e }" -e PREP_JSON="/prep/$(basename "$PREP_JSON")" \
            python:3.12-slim sh -c "pip install -q locust==2.37.10 >/dev/null 2>&1 && locust -f /lt/locustfile.py $*"
    else
        [ -x "$HERE/venv/bin/locust" ] || { echo "no $HERE/venv: python3 -m venv $HERE/venv && $HERE/venv/bin/pip install -r $HERE/requirements.txt"; exit 1; }
        if command -v systemd-run >/dev/null && [ "$(id -u)" = 0 ]; then
            systemd-run --scope -q -p CPUQuota="${CPU_QUOTA}%" env "${env_args[@]}" "$HERE/venv/bin/locust" -f "$HERE/locustfile.py" "$@"
        elif command -v systemd-run >/dev/null && sudo -n true 2>/dev/null; then
            sudo -n systemd-run --scope -q -p CPUQuota="${CPU_QUOTA}%" --uid="$(id -u)" --gid="$(id -g)" env "${env_args[@]}" "$HERE/venv/bin/locust" -f "$HERE/locustfile.py" "$@"
        else
            echo "(no systemd-run/sudo: load generator not CPU-capped)" >&2
            env "${env_args[@]}" "$HERE/venv/bin/locust" -f "$HERE/locustfile.py" "$@"
        fi
    fi
}

while read -r L NB NP NW NBUY MIN; do
    [ -z "$L" ] && continue
    [[ "$L" == \#* ]] && continue
    if [ "$NBUY" -gt 0 ] && [ -z "${EVENT_SLUG:-}" ]; then echo "  (no EVENT_SLUG: running $L with 0 buyers)"; NBUY=0; fi
    if [ "$NP" -gt 0 ] && ! python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["pos"] else 1)' "$PREP_JSON"; then echo "  (no tills in prep.json: running $L with 0 tills)"; NP=0; fi
    TOTAL=$((NB+NP+NW+NBUY))
    [ "$TOTAL" -gt 0 ] || { echo "  nothing to run for $L"; continue; }
    R=${SPAWN_RATE:-$(( TOTAL > 450 ? 8 : 3 ))}
    echo "$(date +%T) stage $L backend=$NB pos=$NP browse=$NW buy=$NBUY users=$TOTAL rate=$R minutes=$MIN"
    ( while sleep 5; do
          echo "$(date +%s) $(cut -d' ' -f1 /proc/loadavg) $( [ -n "${MONITOR_CMD:-}" ] && eval "$MONITOR_CMD" 2>/dev/null | tr '\n' ' ')"
      done ) > "$RESULTS/$L.stats" &
    MON=$!
    locust_cmd --headless -u "$TOTAL" -r "$R" -t "${MIN}m" -H "$URL" --reset-stats \
        --csv "$RESULTS/$L" --only-summary --stage "$L" > "$RESULTS/$L.log" 2>&1
    kill $MON 2>/dev/null
    AGG=$(python3 - "$RESULTS/$L" <<'PY'
import csv, sys
try:
    for r in csv.DictReader(open(f"{sys.argv[1]}_stats.csv")):
        if r["Name"] == "Aggregated":
            n, f = int(r["Request Count"]), int(r["Failure Count"])
            print(f"{f/max(n,1):.3f} {n} {f} {r['95%']}")
except FileNotFoundError:
    print("1 0 0 0")
PY
)
    echo "$(date +%T) done $L fail_ratio/requests/failures/p95ms: $AGG"
    RATIO=${AGG%% *}
    if python3 -c "import sys; sys.exit(0 if float('${RATIO:-1}') > float('${STOP_RATIO}') else 1)"; then
        echo "$(date +%T) BROKEN at $L (failure ratio $RATIO > $STOP_RATIO), stopping the series"
        break
    fi
    sleep 20
done < "$STAGE_FILE"
echo "$(date +%T) ALL DONE"
python3 "$HERE/analyze.py" "$RESULTS" "$STAGE_FILE" || true
