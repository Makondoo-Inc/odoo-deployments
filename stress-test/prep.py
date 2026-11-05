# Prepare a NEUTRALISED throwaway copy for the load test and write prep.json.
#
# Run inside `odoo shell` on the copy:
#   odoo shell -c odoo.conf -d <copy> --no-http < prep.py          (bare metal)
#   docker compose exec -T odoo odoo shell -d <copy> --no-http < prep.py
# with these environment variables (STRESS_DB is a safety check: it must match
# the shell's database):
#   STRESS_DB          name of the copy
#   STRESS_PASSWORD    password to set on EVERY internal user of the copy (default loadtest)
#   STRESS_COUNTRY     country code for buyer addresses (default from the company)
#   PREP_OUT           where to write prep.json (default: printed on stdout after PREPJSON)
#
# It refuses to run unless the database is marked neutralised (odoo neutralize),
# because it changes every password and opens till sessions.
#
# Copyright (C) 2025-2026 Makondoo Inc. Licence: AGPL-3.0-or-later
import json
import os

want = os.environ.get("STRESS_DB")
assert want, "set STRESS_DB to the name of the throwaway copy"
assert env.cr.dbname == want, f"shell is on {env.cr.dbname!r}, STRESS_DB is {want!r}"  # noqa: F821
icp = env["ir.config_parameter"].sudo()  # noqa: F821
assert icp.get_param("database.is_neutralized"), "database is not neutralised: run `odoo neutralize` first"

password = os.environ.get("STRESS_PASSWORD", "loadtest")
out = {"db": env.cr.dbname, "password": password, "users": [], "pos": [],  # noqa: F821
       "sale_products": [], "partners": [], "country_id": None, "state_id": None}

# --- users: same password everywhere, record what each one may read ---------
models = ["sale.order", "account.move", "account.move.line", "res.partner", "product.template",
          "product.product", "stock.picking", "stock.quant", "pos.order", "pos.order.line",
          "event.registration"]
Users = env["res.users"]  # noqa: F821
users = Users.search([("share", "=", False), ("active", "=", True)])
# Written straight to the table: a normal write would email every user a
# "your password was changed" notice (and fails on some custom templates).
hashed = Users._crypt_context().hash(password)
for u in users:
    Users._set_encrypted_password(u.id, hashed)
    readable = [m for m in models if m in env and env[m].with_user(u).has_access("read")]  # noqa: F821
    out["users"].append({
        "login": u.login,
        "admin": u.has_group("base.group_system"),
        "sales": "sale.order" in env and env["sale.order"].with_user(u).has_access("create"),  # noqa: F821
        "pos": "pos.config" in env and u.has_group("point_of_sale.group_pos_user"),  # noqa: F821
        "models": readable,
    })

# --- tills: one open session each, plus priced lines the till can sell -------
if "pos.config" in env:  # noqa: F821
    admin = env.ref("base.user_admin")  # noqa: F821
    for config in env["pos.config"].search([]):  # noqa: F821
        if not config.current_session_id:
            env["pos.session"].with_user(admin).create({"user_id": admin.id, "config_id": config.id})  # noqa: F821
        session = config.current_session_id
        if session.state == "opening_control":
            session.set_opening_control(0, "")
        methods = config.payment_method_ids
        pm = methods.filtered(lambda p: not p.is_cash_count and not p.use_payment_terminal)[:1] \
            or methods.filtered("is_cash_count")[:1] or methods[:1]
        if not pm:
            continue
        fpos = config.default_fiscal_position_id
        domain = [("available_in_pos", "=", True), ("type", "!=", "combo"), ("is_storable", "=", False)]
        if config.limit_categories and config.iface_available_categ_ids:
            domain.append(("pos_categ_ids", "in", config.iface_available_categ_ids.ids))
        lines = []
        for p in env["product.product"].search(domain, limit=60):  # noqa: F821
            if p.lst_price <= 0:
                continue
            price = config.pricelist_id._get_product_price(p, 1) if config.pricelist_id else p.lst_price
            taxes = fpos.map_tax(p.taxes_id) if fpos else p.taxes_id
            tv = taxes.compute_all(price, config.currency_id, 1, product=p)
            lines.append({"product_id": p.id, "price_unit": price, "tax_ids": taxes.ids,
                          "excl": tv["total_excluded"], "incl": tv["total_included"]})
        out["pos"].append({"config_id": config.id, "name": config.name, "session_id": session.id,
                           "payment_method_id": pm.id, "pm_name": pm.name,
                           "pricelist_id": config.pricelist_id.id, "fiscal_position_id": fpos.id,
                           "lines": lines})

# --- quotations: sellable services/consumables and existing customers --------
if "sale.order" in env:  # noqa: F821
    prods = env["product.product"].search([  # noqa: F821
        ("sale_ok", "=", True), ("active", "=", True), ("list_price", ">", 0),
        ("type", "in", ("consu", "service")), ("is_storable", "=", False)], limit=30)
    out["sale_products"] = prods.ids
    out["partners"] = env["res.partner"].search([("customer_rank", ">", 0), ("active", "=", True)], limit=50).ids  # noqa: F821

# --- buyer address: a country (and a state if the country has them) ---------
code = os.environ.get("STRESS_COUNTRY") or env.company.country_id.code or "US"  # noqa: F821
country = env["res.country"].search([("code", "=", code)], limit=1)  # noqa: F821
out["country_id"] = country.id
state = env["res.country.state"].search([("country_id", "=", country.id)], limit=1)  # noqa: F821
out["state_id"] = state.id or None

env.cr.commit()  # noqa: F821
dest = os.environ.get("PREP_OUT")
if dest:
    with open(dest, "w") as fh:
        json.dump(out, fh)
    print(f"prep.json written to {dest}: {len(out['users'])} users, {len(out['pos'])} tills, "
          f"{len(out['sale_products'])} sale products, {len(out['partners'])} partners")
else:
    print("PREPJSON" + json.dumps(out))
