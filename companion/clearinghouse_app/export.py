"""Writes AddOns/Clearinghouse/Data.lua, the file the Clearinghouse addon loads for AuctionIQ.

Each source is one long string of "id:min,market,qty,avg7,avg30,change7,vol30,days;" entries (prices
in copper, change and volatility in tenths of a percent, blank when unknown), parsed in game on first
use. One string keeps the file small and stays far under Lua's limit on constants per chunk.
"""

from __future__ import annotations

import os
import tempfile
import time
from pathlib import Path

from .store import ItemStats

FORMAT = 1


def _pm(x: float | None) -> str:
    return "" if x is None else str(int(round(x * 1000)))


def encode(stats: dict[int, ItemStats]) -> str:
    return "".join(
        f"{item}:{s.min},{s.market},{s.qty},{s.avg7},{s.avg30},{_pm(s.change7)},{_pm(s.vol30)},{s.days};"
        for item, s in sorted(stats.items()))


def lua_quote(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def render(region: str, realm: str, realm_stats: dict[int, ItemStats], commodity_stats: dict[int, ItemStats],
           realm_ts: int | None, commodity_ts: int | None, now: int | None = None) -> str:
    now = int(now or time.time())
    return (
        "-- Written by the Clearinghouse app. Don't edit: it's replaced on every sync.\n"
        "ClearinghouseData = {\n"
        f"\tformat = {FORMAT},\n"
        f"\tupdated = {now},\n"
        f"\tregion = {lua_quote(region)},\n"
        f"\trealm = {lua_quote(realm)},\n"
        f"\trealmScan = {realm_ts or 0},\n"
        f"\tcommodityScan = {commodity_ts or 0},\n"
        f"\trealmItems = {lua_quote(encode(realm_stats))},\n"
        f"\tcommodities = {lua_quote(encode(commodity_stats))},\n"
        "}\n"
    )


def write_atomic(path: Path, text: str) -> None:
    """Write next to the target and swap it in, so the game never reads half a file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".Data-", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
