"""Local price history in SQLite: hourly snapshots for two weeks, daily rows for a year."""

from __future__ import annotations

import calendar
import math
import sqlite3
import threading
import time
from dataclasses import dataclass
from functools import wraps
from pathlib import Path

SNAP_DAYS = 14
DAILY_DAYS = 400


def day_of(ts: float) -> str:
    return time.strftime("%Y-%m-%d", time.gmtime(ts))


@dataclass
class ItemStats:
    min: int
    market: int
    qty: int
    avg7: int
    avg30: int
    change7: float | None   # market now vs the daily average 7 days ago, e.g. 0.12 = +12%
    vol30: float | None     # standard deviation of daily log changes over 30 days
    days: int               # days of history


def locked(fn):
    """The app's sync thread and its window both read the store; one at a time."""
    @wraps(fn)
    def run(self, *a, **kw):
        with self.lock:
            return fn(self, *a, **kw)
    return run


class Store:
    def __init__(self, path: Path | str):
        self.lock = threading.RLock()
        self.db = sqlite3.connect(str(path), check_same_thread=False)
        self.db.executescript(
            """
            CREATE TABLE IF NOT EXISTS snap (ts INTEGER, source TEXT, item INTEGER, minp INTEGER, mkt INTEGER, qty INTEGER,
                PRIMARY KEY (ts, source, item));
            CREATE TABLE IF NOT EXISTS daily (day TEXT, source TEXT, item INTEGER, sum_mkt INTEGER, n INTEGER, minp INTEGER, sum_qty INTEGER,
                PRIMARY KEY (day, source, item));
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
            """
        )

    @locked
    def get_meta(self, key: str) -> str | None:
        row = self.db.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        return row[0] if row else None

    @locked
    def set_meta(self, key: str, value: str | None) -> None:
        self.db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", (key, value))
        self.db.commit()

    @locked
    def add(self, ts: int, source: str, summary: dict[int, tuple[int, int, int]]) -> None:
        day = day_of(ts)
        cur = self.db.cursor()
        cur.executemany("INSERT OR REPLACE INTO snap VALUES (?, ?, ?, ?, ?, ?)",
                        [(ts, source, item, mn, mk, q) for item, (mn, mk, q) in summary.items()])
        cur.executemany(
            """INSERT INTO daily VALUES (?, ?, ?, ?, 1, ?, ?)
               ON CONFLICT (day, source, item) DO UPDATE SET sum_mkt = sum_mkt + excluded.sum_mkt, n = n + 1,
               minp = MIN(minp, excluded.minp), sum_qty = sum_qty + excluded.sum_qty""",
            [(day, source, item, mk, mn, q) for item, (mn, mk, q) in summary.items()])
        cur.execute("DELETE FROM snap WHERE ts < ?", (ts - SNAP_DAYS * 86400,))
        cur.execute("DELETE FROM daily WHERE day < ?", (day_of(ts - DAILY_DAYS * 86400),))
        self.db.commit()

    @locked
    def latest(self, source: str) -> int | None:
        row = self.db.execute("SELECT MAX(ts) FROM snap WHERE source = ?", (source,)).fetchone()
        return row[0] if row and row[0] else None

    @locked
    def stats(self, source: str, now: int | None = None) -> dict[int, ItemStats]:
        """Stats for every item in the latest snapshot of `source`."""
        ts = self.latest(source)
        if ts is None:
            return {}
        now = now or ts
        cur = {item: (mn, mk, q) for item, mn, mk, q in self.db.execute(
            "SELECT item, minp, mkt, qty FROM snap WHERE source = ? AND ts = ?", (source, ts))}
        since = day_of(now - 31 * 86400)
        hist: dict[int, list[tuple[str, float]]] = {}
        def dnum(d: str) -> int:
            return calendar.timegm(time.strptime(d, "%Y-%m-%d")) // 86400
        for day, item, s, n in self.db.execute(
                "SELECT day, item, sum_mkt, n FROM daily WHERE source = ? AND day >= ? ORDER BY day", (source, since)):
            hist.setdefault(item, []).append((day, s / n))
        d7, today = day_of(now - 7 * 86400), day_of(now)
        out: dict[int, ItemStats] = {}
        for item, (mn, mk, q) in cur.items():
            days = hist.get(item, [])
            last7 = [v for d, v in days if d > d7]
            last30 = [v for _, v in days]
            # the day nearest 7 days ago, within 2 days either side
            target = dnum(d7)
            near = sorted(((abs(dnum(d) - target), v) for d, v in days if abs(dnum(d) - target) <= 2), key=lambda x: x[0])
            change = (mk / near[0][1] - 1) if near and near[0][1] > 0 else None
            vol = None
            pts = [(dnum(d), v) for d, v in days if v > 0]
            if len(pts) >= 5:
                # daily log changes, a gap of g days scaled by sqrt(g) so missed days don't inflate it
                rets = [math.log(b / a) / math.sqrt(max(1, db - da)) for (da, a), (db, b) in zip(pts, pts[1:])]
                m = sum(rets) / len(rets)
                vol = math.sqrt(sum((r - m) ** 2 for r in rets) / (len(rets) - 1)) if len(rets) > 1 else None
            out[item] = ItemStats(mn, mk, q,
                                  int(round(sum(last7) / len(last7))) if last7 else mk,
                                  int(round(sum(last30) / len(last30))) if last30 else mk,
                                  change, vol, len({d for d, _ in days} | {today}))
        return out

    @locked
    def counts(self) -> dict[str, int]:
        rows = self.db.execute("SELECT COUNT(DISTINCT day) FROM daily").fetchone()
        snaps = self.db.execute("SELECT COUNT(DISTINCT ts) FROM snap").fetchone()
        return {"days": rows[0] or 0, "snapshots": snaps[0] or 0}

    @locked
    def history(self, item: int, source: str, days: int = 30, now: int | None = None) -> list[tuple[str, int, int]]:
        """(day, average market, lowest) for one item, oldest first, for the price chart."""
        since = day_of((now or int(time.time())) - days * 86400)
        return [(d, int(round(s / n)), mn) for d, s, n, mn in self.db.execute(
            "SELECT day, sum_mkt, n, minp FROM daily WHERE source = ? AND item = ? AND day >= ? ORDER BY day",
            (source, item, since))]

    @locked
    def movers(self, source: str, n: int = 8, min_price: int = 10000, now: int | None = None) -> list[dict]:
        """The items whose market moved most over 7 days, up or down, worth at least min_price."""
        rows = []
        for item, s in self.stats(source, now).items():
            if s.change7 is None or (s.market or 0) < min_price:
                continue
            rows.append({"item": item, "source": source, "market": s.market, "avg7": s.avg7,
                         "change7": s.change7, "qty": s.qty, "vol30": s.vol30})
        rows.sort(key=lambda r: abs(r["change7"]), reverse=True)
        return rows[:n]
