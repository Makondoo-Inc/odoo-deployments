"""Summarise a results directory from run.sh into summary.json and a text table.

Usage: python3 analyze.py results/ stages.txt

Copyright (C) 2025-2026 Makondoo Inc. Licence: AGPL-3.0-or-later
"""

import csv
import json
import re
import sys
from pathlib import Path

GROUPS = {
    "backend": lambda n: n.startswith(("list ", "form ", "search ", "report ", "sale.order")),
    "till_order": lambda n: n.startswith("till order"),
    "till_open": lambda n: n.startswith("till open"),
    "web_page": lambda n: n.startswith("web: "),
    "book_step": lambda n: n.startswith("book: ") and "PDFs" not in n,
    "book_confirm": lambda n: "PDFs" in n,
    "login": lambda n: n in ("login", "web client", "load_menus"),
}


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def weighted(rows, key):
    total = sum(r["n"] for r in rows)
    if not total:
        return None
    return round(sum(r[key] * r["n"] for r in rows) / total)


def cpu_stats(path):
    """Parse the .stats file: epoch, load average, then NAME=NN% tokens from MONITOR_CMD."""
    load, series = [], {}
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        try:
            load.append(float(parts[1]))
        except ValueError:
            continue
        for p in parts[2:]:
            m = re.match(r"(.+?)=([\d.]+)%", p)
            if m:
                series.setdefault(m.group(1), []).append(float(m.group(2)))
    out = {"load_avg": round(sum(load) / len(load), 2) if load else None, "load_max": max(load, default=None)}
    for name, xs in series.items():
        key = "db" if re.search(r"db|postgres", name, re.I) else "odoo" if re.search(r"odoo", name, re.I) else name
        out[f"{key}_cpu_avg"] = round(sum(xs) / len(xs))
        out[f"{key}_cpu_max"] = max(xs)
    return out


def main(results, stages_file):
    results = Path(results)
    out = []
    for line in Path(stages_file).read_text().strip().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        label, nb, npos, nw, nbuy, _ = line.split()
        stats = results / f"{label}_stats.csv"
        if not stats.exists():
            continue
        rows, agg = [], None
        for r in csv.DictReader(stats.open()):
            row = {"name": r["Name"], "n": int(r["Request Count"]), "fail": int(r["Failure Count"]),
                   "p50": num(r["50%"]), "p95": num(r["95%"]), "p99": num(r["99%"]),
                   "max": num(r["Max Response Time"]), "rps": num(r["Requests/s"])}
            if r["Name"] == "Aggregated":
                agg = row
            else:
                rows.append(row)
        groups = {}
        for g, match in GROUPS.items():
            sel = [r for r in rows if match(r["name"])]
            if sel:
                groups[g] = {"n": sum(r["n"] for r in sel), "fail": sum(r["fail"] for r in sel),
                             "p50": weighted(sel, "p50"), "p95": max((r["p95"] for r in sel if r["n"]), default=0),
                             "p95_w": weighted(sel, "p95"), "max": max(r["max"] for r in sel)}
        fails = []
        fpath = results / f"{label}_failures.csv"
        if fpath.exists():
            fails = [{"name": r["Name"], "error": r["Error"][:160], "n": int(r["Occurrences"])}
                     for r in csv.DictReader(fpath.open())]
        sp = results / f"{label}.stats"
        out.append({"stage": label, "backend": int(nb), "pos": int(npos), "browser": int(nw),
                    "buyer": int(nbuy), "rps": agg and round(agg["rps"], 2),
                    "requests": agg and agg["n"], "failures": agg and agg["fail"],
                    "groups": groups, "errors": fails,
                    "cpu": cpu_stats(sp) if sp.exists() else {}, "rows": rows})
    json.dump(out, open(results / "summary.json", "w"), indent=1)
    for s in out:
        g = s["groups"]
        fmt = lambda k: f"{g[k]['p50']}/{int(g[k]['p95'])}" if k in g else "-"  # noqa: E731
        print(f"{s['stage']:6} users b{s['backend']:>3} p{s['pos']} w{s['browser']:>3} buy{s['buyer']:>3} "
              f"rps {s['rps']:>6} fail {s['failures']:>4}/{s['requests']:<6} "
              f"backend {fmt('backend'):>11} till {fmt('till_order'):>11} web {fmt('web_page'):>11} "
              f"book {fmt('book_step'):>11} confirm {fmt('book_confirm'):>11} "
              f"load {s['cpu'].get('load_avg')}/{s['cpu'].get('load_max')} "
              f"odoo {s['cpu'].get('odoo_cpu_avg', '-')}% db {s['cpu'].get('db_cpu_avg', '-')}%  (typical/slowest5% ms)")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
