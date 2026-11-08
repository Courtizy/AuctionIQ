"""Item names for the dashboard, read from AuctionIQ's saved names (AuctionIQDB.itemNames).

Read only: the file is opened for reading and never written, so it is safe while WoW runs.
"""

from __future__ import annotations

import re
from pathlib import Path

ENTRY = re.compile(r'\[(\d+)\]\s*=\s*"((?:[^"\\]|\\.)*)"')
_cache: dict[str, tuple[float, dict[int, str]]] = {}


def saved_files(retail: Path | None) -> list[Path]:
    if not retail:
        return []
    return sorted((retail / "WTF" / "Account").glob("*/SavedVariables/AuctionIQ.lua"))


def parse(text: str) -> dict[int, str]:
    """The [id] = "name" pairs inside ["itemNames"] = { ... }."""
    start = text.find('["itemNames"]')
    if start < 0:
        return {}
    open_at = text.find("{", start)
    depth, i = 0, open_at
    while i < len(text):
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                break
        elif c == '"':
            i += 1
            while i < len(text) and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
        i += 1
    body = text[open_at:i]
    return {int(k): v.replace('\\"', '"').replace("\\\\", "\\") for k, v in ENTRY.findall(body)}


def load(retail: Path | None) -> dict[int, str]:
    out: dict[int, str] = {}
    for f in saved_files(retail):
        try:
            mtime = f.stat().st_mtime
            hit = _cache.get(str(f))
            if not hit or hit[0] != mtime:
                hit = (mtime, parse(f.read_text(encoding="utf-8", errors="replace")))
                _cache[str(f)] = hit
            out.update(hit[1])
        except OSError:
            continue
    return out
