# stress-test

A load test for Odoo 17–20 that behaves like real use: staff in the back office,
tills sending paid orders, anonymous visitors on the website and, if the site
sells event tickets, customers booking end to end with the demo payment
provider. Built on [Locust](https://locust.io).

It answers: how many people can this server serve at the same time before
pages slow past a target or requests fail, and what breaks first.

## Never test production

A load test sends thousands of emails, creates orders and payments, and fires
every cron and webhook. The recipe here makes that impossible to do by
accident:

1. **Copy** the database and its filestore to a throwaway name.
2. **Neutralise** it with Odoo's own `odoo neutralize` (mail servers replaced by a
   dummy, crons off, payment providers in test mode) **plus**
   `neutralize_extra.sql` (every provider except the demo one disabled, IAP tokens
   voided, WhatsApp off, mailings parked, webhook automations off, fiscal
   integrations to demo mode, `web.base.url` reset).
3. **Verify** with `verify_neutralized.sql`: the copy script stops on any FAIL.
4. **Serve the copy from its own Odoo process** (`--db-filter=^copy$ -d copy`):
   an Odoo that serves several databases answers anonymous page requests from
   whichever it picks first, not from your copy.
5. `prep.py` **refuses to run** unless the database is marked neutralised. It
   sets one password on every internal user of the copy (never on production)
   and opens a till session per POS.
6. **Delete the copy** when done. The copy scripts print the commands.

The load generator runs on the same machine, capped at one CPU core, so the
numbers are slightly pessimistic rather than optimistic.

## Quick start (Docker Compose stack)

```bash
cd /path/to/compose/project
SRC_DB=production DST_DB=loadtest PREP_OUT=/tmp/lt/prep.json \
  /path/to/odoo-deployments/stress-test/copy-docker.sh

# a throwaway Odoo pinned to the copy, on its own port
docker compose run --rm -d --name loadtest-odoo -p 127.0.0.1:18069:8069 odoo \
  odoo -d loadtest --db-filter='^loadtest$' --workers=4

cd /path/to/odoo-deployments/stress-test
python3 -m venv venv && venv/bin/pip install -r requirements.txt
cp stages.example.txt /tmp/lt/stages.txt           # edit the steps
URL=http://127.0.0.1:18069 PREP_JSON=/tmp/lt/prep.json RESULTS=/tmp/lt/results \
  PAGES="/,/shop,/contactus" EVENT_SLUG=daily-pass-1 \
  MONITOR_CMD='docker stats --no-stream --format "{{.Name}}={{.CPUPerc}}" loadtest-odoo myproj-db-1' \
  ./run.sh /tmp/lt/stages.txt
```

Bare metal: `copy-baremetal.sh` (needs `ODOO_BIN` and `ODOO_CONF`), then start a
second `odoo-bin` with a config pointing at the copy (own `http_port`,
`db_name`, `dbfilter`, `data_dir` can be shared), for example as a transient
systemd unit: `systemd-run --unit=loadtest-odoo --uid=odoo python odoo-bin -c /tmp/loadtest.conf`.

## What the simulated people do

| Class | Count variable | Behaviour | Pace |
|---|---|---|---|
| Back office | `N_BACKEND` | logs in as a random internal user; lists and forms of sales, invoices, contacts, products, transfers, till orders, registrations (only models that user may read), searches, grouped reports, quotations (if allowed) | an action every 5–15 s |
| Till | `N_POS` | opens a POS session's data once, then sends a paid order of 1–4 items via `sync_from_ui` | an order every 20–60 s |
| Visitor | `N_BROWSER` | opens public pages from `PAGES` (plus the event pages when `EVENT_SLUG` is set) | a page every 3–10 s |
| Ticket buyer | `N_BUYER` | full booking: chooses 1–4 tickets, confirms attendees, enters an address, pays with the demo provider, reaches the confirmation page; the whole flow is also recorded as one `FLOW` request | 5–15 s between bookings |

A request slower than `REQUEST_TIMEOUT` (60 s) counts as a failure: a customer
would have given up.

## Reading the results

`run.sh` writes Locust's CSVs per stage to `RESULTS` and runs `analyze.py`, which
prints one line per stage and writes `summary.json` with per-group typical (p50)
and slowest-5% (p95) times, failure counts, requests/s, load average and the
CPU figures from `MONITOR_CMD`. The groups: `backend`, `till_order`,
`web_page`, `book_step`, `book_confirm` (the step after payment that builds the
order and tickets), `login`.

Judge a stage as *within target* when the slowest 5% of pages are under about
5 s and no request failed; as *broken* when more than 5% of requests fail
(`STOP_RATIO`). Completed bookings per minute levelling off while visitors
keep rising is the server's throughput ceiling.

`email_backlog.sh` logs, every 30 s, how many order confirmations wait for the
sale cron and how many mails sit in the outgoing queue, so you can see whether
emails keep up with sales. `smtp_sink.py` is a throwaway SMTP server that
accepts and discards mail, to measure how fast the queue drains without a real
provider.

## Things we learnt running this

- Odoo's default `sale` confirmation path builds the order PDF inside the
  customer's request and, with `event`, updates one shared record per event:
  two customers paying at once can make one of them fail. The standard
  settings `sale.async_emails` and `event.event_mail_async` (with their crons
  active, `KEEP_CRONS=sale.send_pending_emails_cron,event.event_mail_scheduler`)
  move that out of the request.
- The sale email cron sends synchronously and attaches the order PDF; with the
  online-order confirmation template set to one without the PDF (a website
  setting), each email drops from about 1.6 s to 0.08 s.
- An email sent with "force send" to the salesperson of every online order runs
  inside the customer's request. Check who the website's salesperson is.
- Odoo gives every anonymous visitor a session cookie and the ticket page a
  per-visitor security token: public pages cannot be cached naively.
- Run the generator capped at one core, on the server itself: the network is
  then not part of the measurement, and the cap keeps it from starving Odoo.
- Compare runs only on the same hardware; a 2.5x per-core difference between
  a shared-vCPU VM and a dedicated server showed up as a 4x capacity difference.
