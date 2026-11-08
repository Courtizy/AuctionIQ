"""One sync: fetch what changed, add it to the history, write Data.lua for the addon."""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass, field
from pathlib import Path

from . import export
from .blizzard import Blizzard, BlizzardError, summarize
from .store import Store

log = logging.getLogger("clearinghouse")


@dataclass
class Result:
    ok: bool
    message: str
    realm_items: int = 0
    commodity_items: int = 0
    fetched: list[str] = field(default_factory=list)
    wrote: bool = False
    pending_write: bool = False


class Syncer:
    def __init__(self, store: Store, client_factory, wow_running=lambda: False):
        self.store = store
        self.client_factory = client_factory      # () -> Blizzard
        self.wow_running = wow_running
        self.pending = False

    def run(self, settings, addon_dir: Path | None, now: int | None = None) -> Result:
        now = int(now or time.time())
        if addon_dir is None:
            return Result(False, "Couldn't find World of Warcraft. Set its _retail_ folder in Settings.")
        try:
            client: Blizzard = self.client_factory()
            key = f"crid:{settings.region}:{settings.realm}"
            crid = self.store.get_meta(key)
            if not crid:
                crid = str(client.connected_realm_id(settings.realm))
                self.store.set_meta(key, crid)
            fetched = []
            for source, call in (("realm", lambda since: client.auctions(int(crid), since)),
                                 ("commodity", lambda since: client.commodities(since))):
                mkey = f"lastmod:{settings.region}:{settings.realm}:{source}"
                got = call(self.store.get_meta(mkey))
                if got.data is None:
                    continue
                self.store.add(now, source, summarize(got.data.get("auctions") or []))
                self.store.set_meta(mkey, got.last_modified)
                fetched.append(source)
        except BlizzardError as e:
            log.warning("sync failed: %s", e)
            return Result(False, str(e))
        except Exception as e:  # network trouble, bad JSON
            log.exception("sync failed")
            return Result(False, f"Sync failed: {e.__class__.__name__}: {e}")
        target = addon_dir / "Data.lua"
        if fetched or not target.exists() or self.pending:
            self.pending = True
        res = Result(True, "", fetched=fetched)
        if self.pending:
            res = self.write(settings, addon_dir, now, res)
        res.message = res.message or (
            f"Updated {', '.join(fetched)}." if fetched else "Nothing new from Blizzard since the last sync.")
        return res

    def write(self, settings, addon_dir: Path, now: int, res: Result | None = None) -> Result:
        res = res or Result(True, "")
        if settings.wait_for_wow_closed and self.wow_running():
            res.pending_write = True
            res.message = "New data is ready; it will be written when WoW closes."
            return res
        realm = self.store.stats("realm", now)
        comm = self.store.stats("commodity", now)
        text = export.render(settings.region, settings.realm, realm, comm,
                             self.store.latest("realm"), self.store.latest("commodity"), now)
        try:
            export.write_atomic(addon_dir / "Data.lua", text)
        except PermissionError:
            res.ok = False
            res.message = f"Windows won't let the app write to {addon_dir}. Check that folder's permissions."
            return res
        self.pending = False
        res.wrote, res.realm_items, res.commodity_items = True, len(realm), len(comm)
        log.info("wrote %s (%d realm items, %d commodities)", addon_dir / "Data.lua", len(realm), len(comm))
        return res
