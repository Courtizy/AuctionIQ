#!/usr/bin/env python3
"""AuctionIQ companion: keeps a daily price history longer than the addon's 30 days.

The addon keeps one market price a day for each item the AH has shown you, for the last 30 days
(AuctionIQDB.scans in your saved variables). This script, run on your PC, reads those saved
variables from every WoW account folder, adds each day to a history kept in SQLite (a year by
default), and writes the last DAYS days back as AuctionIQ_History/History.lua, which the game
loads next time you log in or /reload. Market trends then charts months instead of weeks.

    python companion.py                       # finds WoW in the usual places, runs once
    python companion.py --wow "D:\\Games\\World of Warcraft\\_retail_"
    python companion.py --watch 15            # again every 15 minutes, while you play
    python companion.py --csv prices.csv      # also write the whole history as CSV

Only the Python standard library is used. WoW writes saved variables when you log out or
/reload, so run it after one of those (or leave --watch on) and /reload to load the history.
"""
import argparse
import datetime
import os
import re
import sqlite3
import sys
import time
from pathlib import Path

KEEP_DAYS = 365  # how much history the database keeps
WRITE_DAYS = 180  # how much of it goes back into the game
HERE = Path(__file__).resolve().parent

# -- Reading saved variables -----------------------------------------------------------------------
_TOKEN = re.compile(r"""
    \s+ | --\[(?P<eq>=*)\[.*?\](?P=eq)\] | --[^\n]* |
    (?P<str>"(?:\\.|[^"\\])*") |
    (?P<num>-?(?:0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?|inf|nan)) |
    (?P<name>[A-Za-z_][A-Za-z0-9_]*) |
    (?P<sym>[{}\[\]=,;-])
""", re.X | re.S)

_ESC = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "a": "\a", "b": "\b", "f": "\f", "v": "\v", "\n": "\n"}


def _unescape(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c != "\\":
            out.append(c); i += 1; continue
        n = s[i + 1]
        if n.isdigit():
            j = i + 1
            while j < len(s) and j < i + 4 and s[j].isdigit():
                j += 1
            out.append(chr(int(s[i + 1:j]))); i = j
        else:
            out.append(_ESC.get(n, n)); i += 2
    return "".join(out)


def _tokens(text):
    pos = 0
    for m in _TOKEN.finditer(text):
        if m.start() != pos:
            raise ValueError(f"can't read saved variables at character {pos}: {text[pos:pos + 30]!r}")
        pos = m.end()
        if m.group("str") is not None:
            yield ("str", _unescape(m.group("str")[1:-1]))
        elif m.group("num") is not None:
            t = m.group("num")
            low = t.lower().lstrip("-")
            if low in ("inf", "nan"):
                yield ("num", float(t))
            elif "x" in low:
                yield ("num", int(t, 16))
            elif re.fullmatch(r"-?\d+", t):
                yield ("num", int(t))
            else:
                yield ("num", float(t))
        elif m.group("name") is not None:
            yield ("name", m.group("name"))
        elif m.group("sym") is not None:
            yield ("sym", m.group("sym"))
    if pos != len(text):
        raise ValueError(f"can't read saved variables at character {pos}")


class _Parser:
    def __init__(self, text):
        self.toks = list(_tokens(text))
        self.i = 0

    def peek(self, k=0):
        return self.toks[self.i + k] if self.i + k < len(self.toks) else (None, None)

    def take(self, kind=None, value=None):
        t = self.peek()
        if (kind and t[0] != kind) or (value is not None and t[1] != value):
            raise ValueError(f"expected {value or kind}, got {t[1]!r}")
        self.i += 1
        return t

    def value(self):
        kind, v = self.peek()
        if kind == "sym" and v == "{":
            return self.table()
        if kind == "sym" and v == "-":  # a negative number written "- 5"
            self.take()
            return -self.take("num")[1]
        self.take()
        if kind in ("str", "num"):
            return v
        if kind == "name":
            return {"true": True, "false": False, "nil": None}.get(v, v)
        raise ValueError(f"unexpected {v!r}")

    def table(self):
        self.take("sym", "{")
        out, n = {}, 0
        while self.peek() != ("sym", "}"):
            kind, v = self.peek()
            if kind == "sym" and v == "[":
                self.take(); key = self.value(); self.take("sym", "]"); self.take("sym", "=")
                out[key] = self.value()
            elif kind == "name" and self.peek(1) == ("sym", "="):
                self.take(); self.take("sym", "=")
                out[v] = self.value()
            else:
                n += 1
                out[n] = self.value()
            if self.peek()[0] == "sym" and self.peek()[1] in (",", ";"):
                self.take()
        self.take("sym", "}")
        return out

    def assignments(self):
        out = {}
        while self.i < len(self.toks):
            name = self.take("name")[1]
            self.take("sym", "=")
            out[name] = self.value()
        return out


def read_saved_variables(text):
    """Every global a saved variables file sets: { name: value }, Lua tables as dicts."""
    return _Parser(text).assignments()


def daily_prices(db):
    """(item, day, price, scans) for every day of every item in AuctionIQDB.scans."""
    scans = db.get("scans") if isinstance(db, dict) else None
    for item, e in (scans or {}).items():
        if not isinstance(item, int) or not isinstance(e, dict):
            continue
        for p in (e.get("daily") or {}).values():
            if isinstance(p, dict) and isinstance(p.get(1), (int, float)) and isinstance(p.get(2), (int, float)):
                yield item, int(p[1]), float(p[2]), int(p.get(3) or 1)


# -- The history ------------------------------------------------------------------------------------
def open_db(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(str(path))
    con.execute("CREATE TABLE IF NOT EXISTS prices (item INTEGER, day INTEGER, price REAL, scans INTEGER, PRIMARY KEY (item, day))")
    con.execute("CREATE TABLE IF NOT EXISTS names (item INTEGER PRIMARY KEY, name TEXT)")
    return con


def merge(con, rows, keep_days=KEEP_DAYS, today=None):
    """Add days to the history. A day already there keeps whichever saw more scans (the game's own
    number for a day only grows), so running twice changes nothing. Days older than keep_days go."""
    today = today if today is not None else int(time.time() // 86400)
    n = 0
    for item, day, price, scans in rows:
        if day <= today - keep_days:
            continue
        cur = con.execute("SELECT scans FROM prices WHERE item = ? AND day = ?", (item, day)).fetchone()
        if cur is None or scans >= cur[0]:
            con.execute("INSERT OR REPLACE INTO prices VALUES (?, ?, ?, ?)", (item, day, price, scans))
            n += 1
    con.execute("DELETE FROM prices WHERE day <= ?", (today - keep_days,))
    con.commit()
    return n


def write_history(con, out_path, days=WRITE_DAYS, today=None):
    """The last `days` days as a Lua file the History addon loads: one string per item, "day:price"
    pairs with days counted from `base`. Returns how many items it wrote."""
    today = today if today is not None else int(time.time() // 86400)
    base = today - days + 1
    items = {}
    for item, day, price in con.execute("SELECT item, day, price FROM prices WHERE day >= ? ORDER BY item, day", (base,)):
        items.setdefault(item, []).append(f"{day - base}:{int(round(price))}")
    lines = [
        "-- Written by companion.py: daily market prices from your AuctionIQ scans, kept past the addon's 30 days.",
        "-- Don't edit: the next run writes it again. An addon update puts back an empty one until then.",
        f"AuctionIQ_HistoryData = {{ at = {int(time.time())}, base = {base}, days = {days}, items = {{",
    ]
    for item in sorted(items):
        lines.append(f'[{item}]="{",".join(items[item])}",')
    lines.append("} }")
    tmp = out_path.with_suffix(".tmp")
    tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.replace(tmp, out_path)
    return len(items)


def write_csv(con, path):
    with open(path, "w", encoding="utf-8") as f:
        f.write("item,date,price_gold,scans\n")
        for item, day, price, scans in con.execute("SELECT item, day, price, scans FROM prices ORDER BY item, day"):
            date = datetime.date(1970, 1, 1) + datetime.timedelta(days=day)
            f.write(f"{item},{date.isoformat()},{price / 10000:.4f},{scans}\n")


# -- Finding WoW -----------------------------------------------------------------------------------
def find_wow(given=None):
    """The _retail_ folder: the one given, the one this script sits in (Interface/AddOns/...), or
    the usual install places."""
    tries = [Path(given)] if given else []
    tries.append(HERE.parent.parent.parent)  # _retail_/Interface/AddOns/AuctionIQ_History
    for root in ("C:/Program Files (x86)", "C:/Program Files", "D:/", "D:/Games", "C:/Games"):
        tries += [Path(root) / "World of Warcraft" / "_retail_", Path(root) / "Games" / "World of Warcraft" / "_retail_"]
    tries.append(Path("/Applications/World of Warcraft/_retail_"))
    for t in tries:
        if (t / "WTF" / "Account").is_dir():
            return t
    return None


def saved_variables(wow):
    """Every account's AuctionIQ saved variables file."""
    return sorted((wow / "WTF" / "Account").glob("*/SavedVariables/AuctionIQ.lua"))


def run_once(wow, db_path, out_path, days, csv=None, quiet=False):
    con = open_db(db_path)
    added, files = 0, 0
    for f in saved_variables(wow):
        try:
            g = read_saved_variables(f.read_text(encoding="utf-8", errors="replace"))
        except ValueError as e:
            print(f"skipped {f}: {e}", file=sys.stderr)
            continue
        db = g.get("AuctionIQDB") or {}
        added += merge(con, daily_prices(db))
        for item, name in (db.get("itemNames") or {}).items():
            if isinstance(item, int) and isinstance(name, str):
                con.execute("INSERT OR REPLACE INTO names VALUES (?, ?)", (item, name))
        con.commit()
        files += 1
    n = write_history(con, out_path, days)
    if csv:
        write_csv(con, csv)
    total = con.execute("SELECT COUNT(*), COUNT(DISTINCT item) FROM prices").fetchone()
    con.close()
    if not quiet:
        print(f"{files} saved variables file(s), {added} day(s) added; history holds {total[0]} days of {total[1]} items; "
              f"wrote {n} items to {out_path}. /reload in game to load it.")
    return files, added, n


def main(argv=None):
    ap = argparse.ArgumentParser(description="Keep AuctionIQ's daily prices past 30 days and load them back into the game.")
    ap.add_argument("--wow", help="the _retail_ folder (found automatically if left out)")
    ap.add_argument("--db", help="the history database (default: WTF/AuctionIQ_History.sqlite, which addon updates leave alone)")
    ap.add_argument("--out", help="the History.lua to write (default: next to this script)")
    ap.add_argument("--days", type=int, default=WRITE_DAYS, help=f"days written back into the game (default {WRITE_DAYS})")
    ap.add_argument("--csv", help="also write the whole history to this CSV file")
    ap.add_argument("--watch", type=float, metavar="MINUTES", help="run again every this many minutes")
    a = ap.parse_args(argv)
    wow = find_wow(a.wow)
    if not wow:
        print("Couldn't find World of Warcraft's _retail_ folder: pass it with --wow.", file=sys.stderr)
        return 2
    # in WTF, not beside this script: an addon update replaces this folder, never WTF
    db_path = Path(a.db) if a.db else wow / "WTF" / "AuctionIQ_History.sqlite"
    out_path = Path(a.out) if a.out else HERE / "History.lua"
    while True:
        run_once(wow, db_path, out_path, a.days, a.csv)
        if not a.watch:
            return 0
        time.sleep(a.watch * 60)


if __name__ == "__main__":
    sys.exit(main())
