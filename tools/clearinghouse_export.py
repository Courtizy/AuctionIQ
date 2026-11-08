#!/usr/bin/env python3
"""Export Clearinghouse and TSM data from WoW's SavedVariables to CSV files and a Markdown report.

Run it after logging out (WoW writes SavedVariables on logout). It only reads the files.

    python clearinghouse_export.py "C:/Program Files (x86)/Games/World of Warcraft/_retail_/WTF/Account/NAME/SavedVariables" --out reports

Writes to the output folder:
    sales.csv, buys.csv, income.csv, expense.csv, expired.csv, cancelled.csv   TSM's accounting
    gold.csv          gold per character over time (TSM's gold log), plus the warband bank
    inventory.csv     what each character holds (bags, bank, mail, auctions) and the warband bank
    worth.csv         Clearinghouse's daily net worth snapshots (gold + inventory value)
    scan.csv          Clearinghouse's latest recipe scans
    report.md         a summary: last 7 and 30 days, top items, net worth trend
No third-party packages needed; pandas users can load the CSVs directly.
"""
import argparse
import csv
import datetime as dt
import os
import re
import sys
from collections import defaultdict


# --- a small reader for the Lua tables WoW writes ------------------------------------------------
class LuaReader:
    TOKEN = re.compile(r'\s*(?:--[^\n]*\n\s*)*(?:(\[\[.*?\]\])|("(?:\\.|[^"\\])*")|([{}\[\]=,;])|(-?\d+\.?\d*(?:[eE][-+]?\d+)?)|([A-Za-z_]\w*))', re.S)

    def __init__(self, text):
        self.text, self.pos = text, 0

    def tok(self):
        m = self.TOKEN.match(self.text, self.pos)
        if not m:
            return None
        self.pos = m.end()
        return m

    def peek(self):
        save = self.pos
        m = self.tok()
        self.pos = save
        return m

    def value(self):
        m = self.tok()
        if m.group(2) is not None:
            return self.unquote(m.group(2))
        if m.group(1) is not None:
            return m.group(1)[2:-2]
        if m.group(4) is not None:
            s = m.group(4)
            return float(s) if any(c in s for c in ".eE") else int(s)
        if m.group(5) is not None:
            return {"true": True, "false": False, "nil": None}.get(m.group(5), m.group(5))
        if m.group(3) == "{":
            return self.table()
        raise ValueError("unexpected %r at %d" % (m.group(0), self.pos))

    @staticmethod
    def unquote(s):
        s = s[1:-1]
        return re.sub(r'\\(n|t|"|\\|\d{1,3})', lambda m: {"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(m.group(1)) or chr(int(m.group(1))), s)

    def table(self):
        out, n = {}, 1
        while True:
            p = self.peek()
            if p.group(3) == "}":
                self.tok()
                return out
            if p.group(3) == "[":
                self.tok()
                k = self.value()
                self.tok()  # ]
                self.tok()  # =
                out[k] = self.value()
            elif p.group(5) and self.text[p.end():].lstrip().startswith("=") and not self.text[p.end():].lstrip().startswith("=="):
                self.tok()
                self.tok()  # =
                out[p.group(5)] = self.value()
            else:
                out[n] = self.value()
                n += 1
            p = self.peek()
            if p and p.group(3) in (",", ";"):
                self.tok()

    def globals(self):
        out = {}
        while True:
            m = self.tok()
            if not m:
                return out
            name = m.group(5)
            self.tok()  # =
            out[name] = self.value()


def read_saved(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return LuaReader(f.read()).globals()


# --- TSM data ----------------------------------------------------------------------------------
def csv_rows(text):
    lines = [l for l in (text or "").split("\n") if l]
    if not lines:
        return []
    head = lines[0].split(",")
    return [dict(zip(head, l.split(","))) for l in lines[1:]]


def item_id(s):
    m = re.match(r"i:(\d+)", s or "")
    return int(m.group(1)) if m else None


def when(t):
    return dt.datetime.fromtimestamp(int(t)).isoformat(sep=" ", timespec="minutes")


def gold(c):
    return round(int(c) / 10000, 4)


def write_csv(path, header, rows):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("saved", help="the account's SavedVariables folder")
    ap.add_argument("--realm", default="Emerald Dream")
    ap.add_argument("--out", default="clearinghouse-reports")
    a = ap.parse_args(argv)
    os.makedirs(a.out, exist_ok=True)

    tsm = read_saved(os.path.join(a.saved, "TradeSkillMaster.lua")).get("TradeSkillMasterDB", {})
    chp = os.path.join(a.saved, "Clearinghouse.lua")
    ch = read_saved(chp).get("ClearinghouseDB", {}) if os.path.exists(chp) else {}
    realm = a.realm
    names = {int(k): v for k, v in (ch.get("itemNames") or {}).items() if str(k).isdigit()}

    def label(s):
        i = item_id(s)
        return names.get(i, s) if i else s

    chars = {}
    for k, v in tsm.items():
        m = re.match(r"^s@(.+?) - (.+?) - (.+)@internalData@money$", str(k))
        if m and m.group(3) == realm:
            chars[m.group(1)] = "%s - %s - %s" % m.groups()
    mine = set(chars)

    # accounting
    kinds = {"Sales": "sales", "Buys": "buys", "Income": "income", "Expense": "expense", "Expired": "expired", "Cancelled": "cancelled"}
    records = {}
    for kind, name in kinds.items():
        rows = csv_rows(tsm.get("r@%s@internalData@csv%s" % (realm, kind)))
        records[name] = rows
        if kind in ("Sales", "Buys"):
            write_csv(os.path.join(a.out, name + ".csv"), ["time", "item", "item_id", "quantity", "price_each_g", "total_g", "player", "other", "source"],
                      [[when(r["time"]), label(r["itemString"]), item_id(r["itemString"]), r["quantity"], gold(r["price"]),
                        gold(int(r["price"]) * int(r["quantity"])), r["player"], r["otherPlayer"], r["source"]] for r in rows])
        elif kind in ("Income", "Expense"):
            write_csv(os.path.join(a.out, name + ".csv"), ["time", "type", "amount_g", "player", "other", "own_transfer"],
                      [[when(r["time"]), r["type"], gold(r["amount"]), r["player"], r["otherPlayer"], r["otherPlayer"] in mine] for r in rows])
        else:
            write_csv(os.path.join(a.out, name + ".csv"), ["time", "item", "item_id", "quantity", "player"],
                      [[when(r["time"]), r["itemString"], item_id(r["itemString"]), r["quantity"], r["player"]] for r in rows])

    # gold over time
    g = []
    for name, scope in chars.items():
        for r in csv_rows(tsm.get("s@%s@internalData@goldLog" % scope)):
            g.append([when(int(r["minute"]) * 60), name, gold(r["copper"])])
    for r in csv_rows(tsm.get("g@ @internalData@warbankGoldLog")):
        g.append([when(int(r["minute"]) * 60), "Warband", gold(r["copper"])])
    write_csv(os.path.join(a.out, "gold.csv"), ["time", "character", "gold"], sorted(g))

    # inventory now
    inv = []
    for name, scope in chars.items():
        for where in ("bag", "bank", "mail", "auction"):
            for s, n in (tsm.get("s@%s@internalData@%sQuantity" % (scope, where)) or {}).items():
                inv.append([name, where, s, item_id(s), n])
    for s, n in (tsm.get("g@ @internalData@warbankQuantity") or {}).items():
        inv.append(["Warband", "warband", s, item_id(s), n])
    write_csv(os.path.join(a.out, "inventory.csv"), ["character", "where", "item", "item_id", "quantity"], inv)

    # Clearinghouse's own history
    ledger = ch.get("ledger") or {}
    worth = sorted((int(d), w) for d, w in (ledger.get("worth") or {}).items())
    write_csv(os.path.join(a.out, "worth.csv"), ["date", "gold_g", "inventory_g", "net_worth_g"],
              [[dt.date.fromtimestamp(d * 86400).isoformat(), gold(w.get("gold", 0)), gold(w.get("inventory", 0)),
                gold(w.get("gold", 0) + w.get("inventory", 0))] for d, w in worth])
    scan = []
    for ck, c in (ch.get("characters") or {}).items():
        for _, p in (c.get("professions") or {}).items():
            for r in ((p.get("scan") or {}).get("rows") or {}).values():
                scan.append([c.get("name", ck), p.get("name"), r.get("name"), r.get("item"), gold(r.get("profit") or 0),
                             gold(r.get("concProfit") or 0), gold(r.get("perPoint") or 0), gold(r.get("perDay") or 0), r.get("soldPerDay")])
    write_csv(os.path.join(a.out, "scan.csv"), ["character", "profession", "recipe", "item_id", "profit_g", "conc_profit_g", "per_point_g", "per_day_g", "sold_per_day"], scan)

    # report
    now = dt.datetime.now().timestamp()
    lines = ["# Clearinghouse report", "", "Generated %s from %s." % (dt.datetime.now().isoformat(sep=" ", timespec="minutes"), realm), ""]
    for days in (7, 30):
        since = now - days * 86400
        sales = sum(int(r["price"]) * int(r["quantity"]) for r in records["sales"] if int(r["time"]) >= since)
        buys = sum(int(r["price"]) * int(r["quantity"]) for r in records["buys"] if int(r["time"]) >= since)
        over = sum(int(r["amount"]) for r in records["expense"] if int(r["time"]) >= since and r["otherPlayer"] not in mine)
        top = defaultdict(int)
        for r in records["sales"]:
            if int(r["time"]) >= since:
                top[r["itemString"]] += int(r["price"]) * int(r["quantity"])
        lines += ["## Last %d days" % days, "",
                  "| | gold |", "| --- | ---: |",
                  "| Sales | %s |" % format(gold(sales), ",.0f"), "| Purchases | %s |" % format(gold(buys), ",.0f"),
                  "| Overhead | %s |" % format(gold(over), ",.0f"), "| Cash profit | %s |" % format(gold(sales - buys - over), ",.0f"), "",
                  "Top items: " + ", ".join("%s (%sg)" % (label(k), format(gold(v), ",.0f")) for k, v in sorted(top.items(), key=lambda x: -x[1])[:5]), ""]
    if worth:
        first, last = worth[0][1], worth[-1][1]
        lines += ["## Net worth", "", "From %s to %s: %sg to %sg." % (
            dt.date.fromtimestamp(worth[0][0] * 86400), dt.date.fromtimestamp(worth[-1][0] * 86400),
            format(gold(first.get("gold", 0) + first.get("inventory", 0)), ",.0f"), format(gold(last.get("gold", 0) + last.get("inventory", 0)), ",.0f")), ""]
    with open(os.path.join(a.out, "report.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print("wrote %s (%d sales, %d characters)" % (os.path.abspath(a.out), len(records["sales"]), len(chars)))


if __name__ == "__main__":
    sys.exit(main())
