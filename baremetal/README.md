# baremetal

Odoo on the host, no containers: a Python virtualenv, a systemd service,
PostgreSQL and nginx on the same machine, all sized by `lib/tuning.sh`. This is
the layout we run production on when the box is dedicated to one Odoo.

Debian/Ubuntu only for now (apt). Idempotent: run it again to apply a changed
setting; it keeps the existing master password, database and data.

```bash
cp deploy.env.example site.env && edit site.env
sudo ./install.sh --config site.env --dry-run     # plan only: sizes, paths, nothing changed
sudo ./install.sh --config site.env               # install or update
sudo ./uninstall.sh --config site.env [--drop-db] [--remove-data] [--remove-source]
```

## What install.sh does

1. **Packages**: build dependencies, fonts, PostgreSQL (from the PGDG repository
   when the distribution does not ship the requested major version), nginx,
   wkhtmltopdf 0.12.6.1 (the version Odoo supports). On Ubuntu with a system
   Python older than Odoo needs, python3.12 from the deadsnakes PPA.
2. **Source and venv**: clones the community branch if `ODOO_SRC` is missing,
   installs Odoo's pinned requirements into `VENV` (survives distro upgrades).
   Enterprise and custom addons are your own checkouts, listed in `site.env`.
3. **User and directories**: system user `odoo`, data dir (filestore), log dir,
   backup dir; repositories readable by the service user.
4. **Kernel**: swappiness, dirty ratios, connection backlogs, file limits and,
   on machines with 8 GB or more, huge pages sized to `shared_buffers` (PostgreSQL
   runs with `huge_pages = try`).
5. **PostgreSQL**: a cluster for the requested version (on `PG_DATA_DIR` if given,
   e.g. a RAID volume), `conf.d/90-odoo.conf` generated from the tuning library
   plus the planner costs chosen from the disk under the data directory (HDD vs
   SSD), peer authentication over the unix socket (no password, no TCP), the
   `odoo` role, the database with `unaccent`, `pg_trgm` and
   `pg_stat_statements`. A second major version on the same host gets port 5433
   and `odoo.conf` follows it.
6. **Odoo**: `/etc/odoo/<project>.conf` (workers, memory limits, `db_maxconn`,
   `dbfilter`, `list_db = False`, `proxy_mode` when nginx is in front), a
   hardened systemd unit, logrotate, a nightly `pg_dump` + filestore backup
   timer (keeps `BACKUP_KEEP_DAYS` days, never prunes files named `*_before_*`),
   and `<project>-update` to pull the repositories, upgrade modules and restart.
7. **Database initialisation** (`base`, `web`, no demo data) when the database
   is empty.
8. **nginx**: a site with websocket routing, forwarded headers, gzip and an
   asset cache; with `DOMAIN`, a Let's Encrypt certificate by webroot and an
   https server block enabled only once the certificate exists.
9. **Start and health check** on the Odoo port and through nginx.

## Operating it

| Task | Command |
|---|---|
| Logs | `journalctl -u <project> -f` and `<LOG_DIR>/odoo.log` |
| Restart | `sudo systemctl restart <project>` |
| Update modules after a `git pull` | `sudo <project>-update module_a,module_b` |
| Backup now | `sudo <project>-backup` |
| Restore | `sudo -u postgres pg_restore -d <db> --no-owner --role=odoo file.dump`, untar the filestore into `<DATA_DIR>/filestore/<db>`, restart |
| Re-size after a hardware change | re-run `install.sh` (same config) |
| Is it slow? | `sudo ../diagnose/odoo-diagnose.sh` |

## Why these choices

- **Unix socket, peer auth**: no database password anywhere, no TCP listener.
- **Workers planned on the soft memory limit**: the steady-state footprint;
  the hard limit only guards runaway requests. See the tuning library.
- **`jit = off`, `random_page_cost` from the disk type, `max_locks_per_transaction = 256`**:
  Odoo's workload is many small queries and module updates that touch hundreds
  of tables; these three avoid the most common PostgreSQL surprises.
- **Huge pages**: saves TLB misses on a large `shared_buffers`; sized from it,
  with headroom, and only on machines where the reservation is affordable.
- **nginx asset cache**: bundled assets are content-hashed, so caching them
  for two weeks is safe and keeps asset storms off the Python workers.
