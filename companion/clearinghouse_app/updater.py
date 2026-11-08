"""Updates from GitHub Releases: releases tagged companion-vX.Y.Z carry Clearinghouse-Setup.exe."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

import requests

from . import __version__

RELEASES = "https://api.github.com/repos/Courtizy/AuctionIQ/releases"
TAG = "companion-v"
ASSET = "Clearinghouse-Setup.exe"


def version_tuple(v: str) -> tuple[int, ...]:
    v = v.removeprefix(TAG).lstrip("v")
    out = []
    for part in v.split("."):
        digits = "".join(ch for ch in part if ch.isdigit())
        out.append(int(digits or 0))
    return tuple(out)


def newest(releases: list[dict], current: str = __version__) -> dict | None:
    """The newest companion release newer than `current` that has the installer, or None."""
    best = None
    for r in releases:
        tag = r.get("tag_name") or ""
        if not tag.startswith(TAG) or r.get("draft") or r.get("prerelease"):
            continue
        asset = next((a for a in r.get("assets") or [] if a.get("name") == ASSET), None)
        if not asset:
            continue
        if version_tuple(tag) > version_tuple(current) and (not best or version_tuple(tag) > version_tuple(best["version"])):
            best = {"version": tag.removeprefix(TAG), "url": asset["browser_download_url"], "notes": r.get("body") or "",
                    "page": r.get("html_url") or ""}
    return best


def check(session: requests.Session | None = None) -> dict | None:
    session = session or requests.Session()
    r = session.get(RELEASES, headers={"Accept": "application/vnd.github+json"}, timeout=20)
    r.raise_for_status()
    return newest(r.json())


def install(update: dict, session: requests.Session | None = None) -> None:
    """Download the installer and start it; it closes this app, replaces it and starts it again."""
    session = session or requests.Session()
    dest = Path(tempfile.gettempdir()) / ASSET
    with session.get(update["url"], stream=True, timeout=120) as r:
        r.raise_for_status()
        with open(dest, "wb") as f:
            for chunk in r.iter_content(1 << 16):
                f.write(chunk)
    subprocess.Popen([str(dest), "/SILENT", "/CLOSEAPPLICATIONS", "/RESTARTAPPLICATIONS"], close_fds=True)
