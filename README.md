# odoo-deployments

Scripts and tools for deploying, tuning and load-testing Odoo (16 to 20), sized to
the hardware they run on. Maintained by [Makondoo Inc.](https://makondoo.org) and
used on real client installs; published so that other integrators can reuse and
improve them.

Licence: **AGPL-3.0-or-later** (see `LICENSE`). If you change these scripts and
ship them, publish your changes under the same licence.

## What is here

| Directory | What it is | Status |
|---|---|---|
| `lib/` | `tuning.sh`: the resource-tuning maths every deployment mode shares (workers, memory limits, PostgreSQL, PgBouncer, nginx). One copy, unit-tested. | stable |
| `bin/` | `odoo-tune`: prints the tuning plan for a machine without deploying anything. | stable |
| `nginx/` | `autodeploy-nginx.sh`: Docker Compose deployment of one or more Odoo versions with tuned PostgreSQL 18, optional PgBouncer and optional nginx reverse proxy. **Start here.** | active |
| `stateless/` | `autodeploy-stateless.sh`: horizontally scalable variant (PgBouncer, MinIO filestore, Redis sessions, separate chat workers). | experimental |
| `quick-deploy/` | `quickdeploy.sh`: older multi-version bootstrap without the proxy. Superseded by `nginx/` run without nginx. | legacy |
| `diagnose/` | `odoo-diagnose.sh`: read-only checks that show what a slow Odoo is *waiting* on (CPU throttling, I/O, memory limits, locks, DNS, misconfiguration), for Docker and bare metal. | active |
| `stress-test/` | Locust load test with Odoo-shaped users (back office, tills, visitors, ticket buyers) and a copy-and-neutralise recipe with verification, so it cannot be run against production by accident. | active |
| `medical/` | ICD-10 import helper for health-sector Odoo installs. | as is |
| `tests/` | bats tests for the tuning library and the shellcheck runner. | active |

Planned, in this order: `baremetal/` (venv + systemd + PostgreSQL on the host, same
tuning library), performance notes from real deployments.

## Quick start

```bash
git clone https://github.com/Makondoo-Inc/odoo-deployments.git
cd odoo-deployments

# See what the tuning maths would do on this machine (nothing is installed)
bin/odoo-tune

# Why is an existing Odoo slow while the CPU is idle? (read-only)
sudo diagnose/odoo-diagnose.sh

# Deploy Odoo 19 with PostgreSQL 18, PgBouncer and nginx (answers the prompts)
cd nginx && ./autodeploy-nginx.sh
```

Run the scripts from a checkout: they source `lib/tuning.sh` relative to their own
location.

## Requirements

- Linux host with Docker Engine 24+ and the Compose plugin (`docker compose`).
- `nproc`, `free`, `openssl`; `nc` or `netstat` for the port checks.
- For the tests: Docker (bats and shellcheck run from pinned images) or local
  `bats` 1.11 and `shellcheck` 0.10.

## Tests

```bash
tests/run.sh          # shellcheck on every script + bats on lib/
```

## How the tuning works

`lib/tuning.sh` takes the core count, RAM, the number of Odoo versions sharing the
host and whether PgBouncer is used, and derives everything else:

- Odoo workers per version, planned on the **soft** memory limit (the steady-state
  footprint) and capped by `cores * 2 + 1` shared across versions;
- a PostgreSQL connection budget that follows the worker count (or the core count
  when PgBouncer multiplexes connections), and `work_mem` bounded by that budget so
  a fully loaded box cannot run out of memory;
- PostgreSQL 18 async I/O and parallel-query settings scaled to the cores;
- nginx worker connections and keepalive sized to the same numbers.

`bin/odoo-tune --cores 64 --ram-mb 262144 --pgbouncer` shows the plan for a
machine you do not have in front of you; `--format env` or `--format json` for
scripts.

## Contributing

Conventional commits (`feat(nginx): ...`, `fix(lib): ...`). Every change to
`lib/tuning.sh` needs a bats test. Scripts must pass shellcheck at warning level.
