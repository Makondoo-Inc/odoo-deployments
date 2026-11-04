"""Odoo load test: back office, tills, website visitors and ticket buyers.

Run ONLY against a neutralised throwaway copy (see README.md). prep.py builds
the prep.json this file needs and refuses to run on a non-neutralised database.

User counts per class come from environment variables; `locust -u` must equal
their sum (run.sh does that):
    N_BACKEND   staff in the back office (lists, forms, searches, reports, quotations)
    N_POS       tills sending paid orders
    N_BROWSER   anonymous website visitors (pages from PAGES)
    N_BUYER     anonymous customers buying event tickets end to end (needs EVENT_SLUG)

Other settings:
    PREP_JSON        path to prep.json (default ./prep.json)
    ODOO_DB          database name (default: from prep.json)
    ODOO_PASSWORD    password prep.py set for every internal user
    ODOO_LANG/ODOO_TZ context for RPC calls (default en_US / UTC)
    PAGES            comma-separated public pages for visitors (default "/,/contactus")
    EVENT_SLUG       event page slug for the ticket flow, e.g. "daily-pass-1"
    REQUEST_TIMEOUT  seconds after which a customer gives up (counted as failure, default 60)

Copyright (C) 2025-2026 Makondoo Inc. Licence: AGPL-3.0-or-later
"""

import json
import os
import random
import re
import time
import uuid
from datetime import datetime, timezone

from locust import HttpUser, between, events, task

PREP = json.load(open(os.environ.get("PREP_JSON", "prep.json")))
DB = os.environ.get("ODOO_DB") or PREP["db"]
PASSWORD = os.environ.get("ODOO_PASSWORD") or PREP.get("password", "loadtest")
LANG = os.environ.get("ODOO_LANG", "en_US")
TZ = os.environ.get("ODOO_TZ", "UTC")
EVENT = os.environ.get("EVENT_SLUG", "")
PAGES = [p for p in os.environ.get("PAGES", "/,/contactus").split(",") if p]
REQUEST_TIMEOUT = float(os.environ.get("REQUEST_TIMEOUT", 60))

POS_LOGINS = [u["login"] for u in PREP["users"] if u["pos"]]


def count(var, available=True):
    """Users for a class: N from the environment, or 0 when the class cannot run.

    Locust gives leftover users to every class whose fixed_count is 0 unless its
    weight is 0 too, so both are set from the same number.
    """
    return int(os.environ.get(var, 0)) if available else 0
CSRF_RE = re.compile(r'name="csrf_token" value="([^"]+)"')
TICKET_RE = re.compile(r'name="nb_register-(\d+)"')

# Back-office views, filtered per user by what they may read (prep.json "models")
LIST_VIEWS = [
    ("sale.order", {"name": {}, "partner_id": {"fields": {"display_name": {}}},
                    "date_order": {}, "amount_total": {}, "state": {}}),
    ("account.move", {"name": {}, "partner_id": {"fields": {"display_name": {}}},
                      "invoice_date": {}, "amount_total_signed": {}, "state": {},
                      "payment_state": {}}),
    ("res.partner", {"display_name": {}, "phone": {}, "email": {}, "city": {}}),
    ("product.template", {"name": {}, "list_price": {}, "qty_available": {},
                          "categ_id": {"fields": {"display_name": {}}}}),
    ("stock.picking", {"name": {}, "partner_id": {"fields": {"display_name": {}}},
                       "scheduled_date": {}, "state": {}}),
    ("pos.order", {"name": {}, "date_order": {}, "amount_total": {}, "state": {},
                   "session_id": {"fields": {"display_name": {}}}}),
    ("event.registration", {"name": {}, "event_id": {"fields": {"display_name": {}}},
                            "event_ticket_id": {"fields": {"display_name": {}}},
                            "state": {}}),
    ("stock.quant", {"product_id": {"fields": {"display_name": {}}},
                     "location_id": {"fields": {"display_name": {}}},
                     "quantity": {}}),
]


def give_up_after_timeout(user):
    """A customer gives up after REQUEST_TIMEOUT seconds; count that as a failure."""
    original = user.client.request

    def request(method, url, **kwargs):
        kwargs.setdefault("timeout", REQUEST_TIMEOUT)
        return original(method, url, **kwargs)

    user.client.request = request


class OdooRpc:
    def rpc(self, url, params, name=None):
        payload = {"jsonrpc": "2.0", "method": "call", "id": random.randint(1, 10**9),
                   "params": params}
        with self.client.post(url, json=payload, name=name or url,
                              catch_response=True) as resp:
            try:
                data = resp.json()
            except ValueError:
                resp.failure(f"HTTP {resp.status_code}, not JSON")
                return None
            if "error" in data:
                err = data["error"].get("data", {}).get("message") or data["error"]
                resp.failure(str(err)[:200])
                return None
            return data.get("result")

    def call(self, model, method, args=(), kwargs=None, name=None):
        kw = dict(kwargs or {})
        kw.setdefault("context", {"lang": LANG, "tz": TZ})
        return self.rpc(f"/web/dataset/call_kw/{model}/{method}",
                        {"model": model, "method": method, "args": list(args), "kwargs": kw},
                        name=name or f"{model}.{method}")

    def login(self, login):
        self.rpc("/web/session/authenticate",
                 {"db": DB, "login": login, "password": PASSWORD}, name="login")


class BackOfficeUser(OdooRpc, HttpUser):
    """Staff in the back office: lists, forms, searches, quotations, reports."""

    fixed_count = count("N_BACKEND", bool(PREP["users"]))
    weight = 1 if fixed_count else 0
    wait_time = between(5, 15)

    def on_start(self):
        give_up_after_timeout(self)
        self.user = random.choice(PREP["users"])
        self.login(self.user["login"])
        self.client.get("/odoo", name="web client")
        self.client.get("/web/webclient/load_menus", name="load_menus")
        self.ids = {}

    def _views(self):
        return [v for v in LIST_VIEWS if v[0] in self.user["models"]] or LIST_VIEWS[2:3]

    @task(10)
    def open_list(self):
        model, spec = random.choice(self._views())
        res = self.call(model, "web_search_read", kwargs={
            "domain": [], "specification": spec, "offset": 0, "limit": 80,
            "count_limit": 10001}, name=f"list {model}")
        if res and res.get("records"):
            self.ids[model] = [r["id"] for r in res["records"]]

    @task(5)
    def open_form(self):
        model, spec = random.choice(self._views())
        ids = self.ids.get(model)
        if not ids:
            return self.open_list()
        self.call(model, "web_read", [[random.choice(ids)]], {"specification": spec},
                  name=f"form {model}")

    @task(3)
    def search(self):
        model = random.choice(["res.partner", "product.product"])
        self.call(model, "name_search", kwargs={
            "name": random.choice(["a", "e", "ma", "jo", "pa", "co"]), "limit": 8},
            name=f"search {model}")

    @task(2)
    def report(self):
        if "account.move.line" not in self.user["models"]:
            return self.open_list()
        self.call("account.move.line", "formatted_read_group", kwargs={
            "domain": [("parent_state", "=", "posted")],
            "groupby": ["account_id"], "aggregates": ["balance:sum"]},
            name="report account.move.line by account")
        if "pos.order.line" in self.user["models"]:
            self.call("pos.order.line", "formatted_read_group", kwargs={
                "domain": [], "groupby": ["product_id"],
                "aggregates": ["price_subtotal_incl:sum", "qty:sum"]},
                name="report pos sales by product")

    @task(1)
    def quotation(self):
        if not self.user["sales"] or not PREP["sale_products"] or not PREP["partners"]:
            return self.open_list()
        product = random.choice(PREP["sale_products"])
        partner = random.choice(PREP["partners"])
        res = self.call("sale.order", "web_save", [[], {
            "partner_id": partner,
            "order_line": [[0, 0, {"product_id": product, "product_uom_qty": random.randint(1, 5)}]],
        }], {"specification": {"name": {}, "amount_total": {}}}, name="sale.order create")
        if res:
            self.call("sale.order", "action_confirm", [[res[0]["id"]]], name="sale.order confirm")


class TillCashier(OdooRpc, HttpUser):
    """A till: loads its data once, then sends a paid order every 20-60 s."""

    fixed_count = count("N_POS", bool(PREP.get("pos")) and bool(POS_LOGINS))
    weight = 1 if fixed_count else 0
    wait_time = between(20, 60)

    def on_start(self):
        give_up_after_timeout(self)
        self.till = PREP["pos"][self._index() % len(PREP["pos"])]
        self.login(random.choice(POS_LOGINS))
        self.call("pos.session", "load_data", [[self.till["session_id"]], []],
                  name="till open (load_data)")
        self.seq = 0

    def _index(self):
        TillCashier._count = getattr(TillCashier, "_count", -1) + 1
        return TillCashier._count

    @task
    def sell(self):
        till = self.till
        if not till["lines"]:
            return
        picks = random.sample(till["lines"], k=min(len(till["lines"]), random.randint(1, 4)))
        lines, total, excl = [], 0.0, 0.0
        for item in picks:
            qty = random.randint(1, 3)
            lines.append([0, 0, {
                "uuid": str(uuid.uuid4()), "product_id": item["product_id"], "qty": qty,
                "price_unit": item["price_unit"], "discount": 0,
                "price_subtotal": round(item["excl"] * qty, 2),
                "price_subtotal_incl": round(item["incl"] * qty, 2),
                "tax_ids": [[6, 0, item["tax_ids"]]], "pack_lot_ids": [],
            }])
            total += item["incl"] * qty
            excl += item["excl"] * qty
        total = round(total, 2)
        self.seq += 1
        now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
        order = {
            "uuid": str(uuid.uuid4()), "name": f"LT {uuid.uuid4().hex[:8]}",
            "session_id": till["session_id"], "config_id": till["config_id"],
            "pricelist_id": till["pricelist_id"],
            "fiscal_position_id": till["fiscal_position_id"] or False,
            "date_order": now, "state": "paid", "partner_id": False, "to_invoice": False,
            "amount_paid": total, "amount_return": 0, "amount_total": total,
            "amount_tax": round(total - excl, 2), "lines": lines,
            "payment_ids": [[0, 0, {"uuid": str(uuid.uuid4()), "amount": total, "name": now,
                                    "payment_method_id": till["payment_method_id"]}]],
            "last_order_preparation_change": "{}", "sequence_number": self.seq,
        }
        self.call("pos.order", "sync_from_ui", [[order]], {
            "context": {"lang": LANG, "tz": TZ, "config_id": till["config_id"]}},
            name="till order (sync_from_ui)")


class WebsiteBrowser(HttpUser):
    """Anonymous visitor looking around the public website without buying."""

    fixed_count = count("N_BROWSER")
    weight = 1 if fixed_count else 0
    wait_time = between(3, 10)

    def on_start(self):
        give_up_after_timeout(self)

    @task
    def page(self):
        pages = list(PAGES)
        if EVENT:
            pages += ["/event", f"/event/{EVENT}/register"]
        page = random.choice(pages)
        self.client.get(page, name=f"web: {page}")


class TicketBuyer(OdooRpc, HttpUser):
    """Anonymous customer buying event tickets end to end with the demo payment provider."""

    fixed_count = count("N_BUYER", bool(EVENT))
    weight = 1 if fixed_count else 0
    wait_time = between(5, 15)

    def on_start(self):
        give_up_after_timeout(self)

    @task
    def buy(self):
        start = time.perf_counter()
        ok = self._buy()
        events.request.fire(request_type="FLOW", name="book: whole booking (customer view)",
                            response_time=(time.perf_counter() - start) * 1000,
                            response_length=0, exception=None if ok else Exception("booking not completed"),
                            context={})

    def _buy(self):
        self.client.cookies.clear()
        self.client.get("/", name="web: /")
        page = self.client.get(f"/event/{EVENT}/register", name=f"web: /event/{EVENT}/register").text
        tickets = TICKET_RE.findall(page)
        if not tickets:
            return False
        chosen = {t: 0 for t in tickets}
        for _ in range(random.choice([1, 2, 2, 3, 4])):
            chosen[random.choice(tickets)] += 1
        form = self.rpc(f"/event/{EVENT}/registration/new",
                        {f"nb_register-{t}": str(n) for t, n in chosen.items()},
                        name="book: choose tickets")
        if not form:
            return False
        data = {"csrf_token": CSRF_RE.search(form).group(1)}
        for field, value in re.findall(r'name="(\d+-event_ticket_id)" value="(\d+)"', form):
            data[field] = value
        resp = self.client.post(f"/event/{EVENT}/registration/confirm", data=data,
                                name="book: confirm attendees", allow_redirects=False)
        checkout = self.client.get("/shop/checkout?try_skip_step=true",
                                   name="book: checkout (address)")
        token = CSRF_RE.search(checkout.text)
        partner = re.search(r'name="partner_id" value="(\d+)"', checkout.text)
        if not token or resp.status_code not in (302, 303):
            return False
        n = random.randint(10**6, 10**7 - 1)
        address = {
            "csrf_token": token.group(1), "address_type": "billing",
            "use_delivery_as_billing": "True", "partner_id": partner.group(1) if partner else "",
            "required_fields": "name,phone", "name": f"Load Test {n}",
            "phone": f"0700{n:06d}"[:10], "email": f"lt{n}@example.com",
            "country_id": PREP["country_id"],
        }
        if PREP.get("state_id"):
            address["state_id"] = PREP["state_id"]
        self.client.post("/shop/address/submit", name="book: submit address", data=address)
        pay = self.client.get("/shop/payment", name="book: payment page").text
        order = re.search(r'data-order-id="(\d+)"', pay)
        access = re.search(r'data-access-token="([^"]+)"', pay)
        amount = re.search(r'data-amount="([\d.]+)"', pay)
        method = re.search(r'data-payment-option-id="(\d+)"[^>]*data-provider-id="(\d+)"', pay)
        if not (order and access and amount and method):
            return False
        tx = self.rpc(f"/shop/payment/transaction/{order.group(1)}", {
            "access_token": access.group(1), "provider_id": int(method.group(2)),
            "payment_method_id": int(method.group(1)), "token_id": None,
            "amount": float(amount.group(1)), "flow": "direct",
            "tokenization_requested": False, "landing_route": "/shop/payment/validate",
            "is_validation": False}, name="book: start payment")
        if not tx:
            return False
        self.rpc("/payment/demo/simulate_payment", {
            "reference": tx["reference"], "payment_details": "4242",
            "simulated_state": "done"}, name="book: card paid (demo)")
        self.rpc("/payment/status/poll", {}, name="book: confirm order + tickets (PDFs)")
        conf = self.client.get("/shop/payment/validate", name="book: confirmation page")
        return conf.ok and "/shop/confirmation" in conf.url


@events.init_command_line_parser.add_listener
def _(parser):
    parser.add_argument("--stage", default="", help="label for this run")
