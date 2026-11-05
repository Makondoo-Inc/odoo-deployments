# diagnose

`odoo-diagnose.sh` answers one question: **why is Odoo slow while the CPU looks
idle?** Low CPU use plus slow responses means the processes are *waiting*, and
`docker stats` or `top` cannot show waiting. This script reads the counters that
can, and reports them as ok / warning / critical.

It is read-only: nothing is changed, restarted or written.

```bash
sudo ./odoo-diagnose.sh                      # auto-detect host, containers, PostgreSQL, Odoo
./odoo-diagnose.sh --odoo-conf /etc/odoo/odoo.conf --log /var/log/odoo/odoo.log
./odoo-diagnose.sh --pg-cmd "docker exec -i mydb psql -U odoo -d postgres"
./odoo-diagnose.sh --strict                  # exit 2 when anything critical is found (for cron/CI)
```

Root (or sudo) is needed for cgroup counters, PostgreSQL on the host and log
files; without it those checks say `[skip]`.

## What it looks at

| Area | Evidence of waiting |
|---|---|
| Host | load vs cores, iowait and **steal** over a short sample, kernel pressure stall info (PSI) for CPU, memory and I/O, swap, transparent hugepages, CPU governor, rotational disks, conntrack fill |
| Containers | CPU limits and the cgroup's **throttling counters** (periods throttled), memory limit vs use and page cache inside it, OOM kills, where PostgreSQL data and the filestore are mounted (overlay vs volume), `/dev/shm` size for PostgreSQL, DNS resolution time of the database host from inside Odoo, logging driver |
| PostgreSQL | the main memory settings, connections in use vs `max_connections`, idle-in-transaction sessions, long queries, **what active backends are waiting on** (locks, I/O), buffer cache hit ratio, temp-file spills, checkpoint pressure, dead rows, slowest statements if `pg_stat_statements` is on |
| Odoo config | workers (0 is critical), cron threads, memory limits, `dev_mode`, `log_level`, `list_db`/`dbfilter`, `proxy_mode` behind a proxy, and the worker count `lib/tuning.sh` would choose for this machine |
| Odoo log | worker kills, time-limit kills, connection exhaustion, serialization retries, database errors, wkhtmltopdf failures, failed websocket requests, requests over 5 s |
| Reverse proxy | `/websocket` routed, `X-Forwarded-Proto`, asset caching |

## The usual suspects

When a Docker deployment is slow with low CPU use, the cause is almost always
one of these, not the container runtime itself:

1. **CPU quota throttling** (`cpus:` on the service): the container gets its share
   in 100 ms periods; once it is used, every process waits for the next period.
   `nr_throttled` in `cpu.stat` is the proof.
2. **A memory limit on the PostgreSQL container**: the limit also caps the page
   cache, so data that bare-metal PostgreSQL serves from RAM is read from disk.
3. **PostgreSQL left at defaults** inside the container (`shared_buffers` 128 MB,
   `/dev/shm` 64 MB).
4. **State on the overlay filesystem**: database or filestore not on a volume.
5. **Slow DNS inside the container**: every new database connection resolves
   `db` first; search domains and an unreachable upstream resolver add seconds.
6. **`proxy_mode` off or `/websocket` not routed**: browsers fall back to polling.
7. **Shared-vCPU cloud hosts**: `steal` time. The machine is idle because it is
   not being given the CPU.

For the Odoo side: `workers = 0`, tight `limit_memory_soft` (constant worker
recycling), `dev_mode`, `log_level = debug`, or `list_db` without a `dbfilter`.
