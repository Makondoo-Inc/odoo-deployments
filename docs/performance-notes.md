# Odoo performance notes

Findings from measuring real Odoo 19 deployments with `stress-test/` and
`diagnose/`. Each note says what we saw, what caused it, and what fixed it.
Numbers are from the machines we had; yours will differ, the mechanisms will not.

## Docker is not the slow part

The same database copy and the same load series on two machines:

| | 4 shared vCPUs (cloud VM, Docker) | 4 dedicated cores, 5.8 GHz Xeon (bare metal) |
|---|---|---|
| One-core Python benchmark | 1.06 s | 0.43 s |
| Visitors served within target | about 50 | about 200 |
| Bookings per minute at peak | 16–17 | 97–117 |

The per-core speed differs by 2.5x and the capacity by about 4x. The container
runtime adds no measurable CPU cost: a container is the same kernel and the same
interpreter with a namespace around it. When a Docker deployment is slow while
`docker stats` shows low CPU use, the processes are *waiting*, and the usual
causes are listed in `diagnose/README.md`: CPU quota throttling, a memory limit
on the PostgreSQL container (it caps the page cache too), PostgreSQL left at its
defaults (`shared_buffers` 128 MB, `/dev/shm` 64 MB), state written to the
overlay filesystem, slow DNS inside the container, `proxy_mode` off or
`/websocket` not routed, and shared-vCPU hosts stealing time.

Compare only on identical hardware. A shared-vCPU VM is not a smaller version of
a dedicated server; it is a different machine every minute.

## Above the CPU ceiling, more workers do nothing

At the breaking point of the dedicated 4-core server, Odoo used about 2.7 cores,
PostgreSQL about 0.8 and the load generator 1: the machine was full. Adding
workers at that point adds queueing, not capacity. The levers are more cores or
taking work away from Odoo (a cache for pages without forms, a CDN for assets).

Odoo gives every anonymous visitor a session cookie and puts a per-visitor CSRF
token in any page with a form, so a reverse-proxy page cache can only serve
pages without forms, and only when it ignores the cookie deliberately.

## Booking confirmations that fail when two customers pay at once

`sale` confirms an order inside the customer's request and builds the order PDF
there; `event` updates one shared mail-scheduler record per event in the same
transaction. Two customers confirming in the same second collide on that record
and one of them is refused. Two standard settings move both out of the request:
`event.event_mail_async = True` and `sale.async_emails = True`, with the crons
`event.event_mail_scheduler` and `sale.send_pending_emails_cron` active. Failed
bookings went from 40% at two simultaneous buyers to none up to 200 visitors.

## Order emails that cannot keep up

The sale email cron sends each confirmation synchronously and attaches the order
PDF, which takes about 1.6 s per email; the cron loop then yields, so the
effective rate was 6 emails a minute against 97 bookings a minute, leaving 1,600
waiting after a rush. Giving online orders a confirmation template without the
PDF (a website setting: *Confirmation email template*) cut the cost to 0.08 s;
the queue then stayed at a minute's worth of orders. Back-office confirmations
keep their PDF.

Odoo's general mail queue drained 5,500 emails in 138 s to a local sink, about
40 a second. A real provider is slower and may cap daily volume; check before a
launch.

## Emails sent inside the customer's request

Assigning every online order to a salesperson makes Odoo email that person "you
have been assigned", and with fewer than 100 recipients it sends immediately, in
the request. Each booking then waits for an SMTP round trip, and the salesperson
gets one email per order. Set the website's salesperson deliberately, or give
that user in-app notifications instead of email.

## Tools and method

- Copy the database, neutralise it, verify, and serve the copy from its own Odoo
  process pinned with `dbfilter`; an Odoo that serves several databases answers
  anonymous requests from whichever it picks first.
- Run the load generator on the server itself, capped at one core, so the
  network is not part of the measurement; results are then slightly pessimistic.
- Double visitors at each step, five minutes per step, and stop at the first step
  that fails more than 5% of requests. Completed orders per minute levelling off
  is the throughput ceiling; the step where whole-flow time jumps is where
  customers start to feel it.
- Keep the Odoo log and `pg_stat_activity` in view during the run: serialization
  retries, lock waits and worker kills explain failures that response-time
  percentiles only show as a symptom.
- `pkill -f pattern` over SSH matches the SSH session's own command line and
  kills it; kill by PID.
