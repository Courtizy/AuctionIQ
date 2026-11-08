"""What the window's JavaScript can call (window.pywebview.api.*). Every method returns plain JSON.

Kept apart from the window so it can be tested without one: `app` is anything with settings, state,
store, sync_now(), toggle_pause(), quit(), hide() and push().
"""

from __future__ import annotations

import logging
import time
from pathlib import Path

from . import __version__, auth, config, names, updater, winutil
from .blizzard import REGIONS, Blizzard, BlizzardError

log = logging.getLogger("clearinghouse")


def ok(**kw):
    return {"ok": True, **kw}


def fail(msg: str):
    return {"ok": False, "error": msg}


class Api:
    def __init__(self, app, realm_cache: Path | None = None):
        self._app = app
        self._realms: dict[str, list[str]] = {}
        self._update: dict | None = None

    # setup ----------------------------------------------------------------------------------
    def state(self) -> dict:
        a, s, st = self._app, self._app.settings, self._app.state
        retail = Path(s.wow_path) if s.wow_path else winutil.find_wow_retail()
        counts = a.store.counts()
        return {
            "version": __version__, "ready": s.ready(), "signedIn": bool(s.use_own_keys or config.get_device_token()),
            "user": s.user, "region": s.region, "realm": s.realm, "regions": list(REGIONS),
            "status": st.status, "message": st.message, "lastSync": st.last_sync, "nextSync": st.next_sync,
            "realmItems": st.items[0], "commodityItems": st.items[1], "days": counts["days"], "snapshots": counts["snapshots"],
            "paused": s.paused, "interval": s.interval_minutes, "waitForWow": s.wait_for_wow_closed,
            "autostart": winutil.start_with_windows(), "wowPath": str(retail) if retail else "", "wowFound": bool(retail),
            "addonDir": str(s.addon_dir() or ""), "update": self._update, "now": time.time(),
        }

    def login(self, user: str, password: str) -> dict:
        s = self._app.settings
        try:
            token = auth.login(s.server(), user, password)
        except BlizzardError as e:
            return fail(str(e))
        config.set_device_token(token)
        s.user, s.use_own_keys = user.strip().lower(), False
        s.save()
        log.info("logged in as %s", s.user)
        return ok()

    def logout(self) -> dict:
        config.set_device_token("")
        self._app.settings.user = ""
        self._app.settings.save()
        self._app.push()
        return ok()

    def realms(self, region: str) -> dict:
        if region not in REGIONS:
            return fail("Pick a region.")
        if region not in self._realms:
            try:
                self._realms[region] = Blizzard(config.make_auth(self._app.settings), region).realms()
            except BlizzardError as e:
                return fail(str(e))
            except Exception as e:  # network trouble
                return fail(f"Couldn't load realms: {e.__class__.__name__}")
        return ok(realms=self._realms[region])

    def save(self, form: dict) -> dict:
        s = self._app.settings
        region, realm = form.get("region", s.region), (form.get("realm") or s.realm or "").strip()
        if region not in REGIONS:
            return fail("Pick a region.")
        if not realm:
            return fail("Pick your realm.")
        path = (form.get("wowPath") or "").strip()
        if path and not (Path(path) / "Interface" / "AddOns").is_dir():
            return fail("That folder has no Interface\\AddOns. Pick WoW's _retail_ folder.")
        try:
            interval = max(15, int(form.get("interval", s.interval_minutes)))
        except (TypeError, ValueError):
            return fail("Sync every: enter a number of minutes.")
        changed = (region, realm) != (s.region, s.realm)
        found = winutil.find_wow_retail()
        s.region, s.realm, s.interval_minutes = region, realm, interval
        s.wow_path = "" if found and path and Path(path) == found else path
        s.wait_for_wow_closed = bool(form.get("waitForWow", s.wait_for_wow_closed))
        s.save()
        if "autostart" in form:
            winutil.set_start_with_windows(bool(form["autostart"]))
        if changed or not self._app.state.last_sync:
            self._app.sync_now()
        self._app.push()
        return ok()

    # dashboard ------------------------------------------------------------------------------
    def movers(self, source: str = "realm") -> dict:
        a = self._app
        rows = a.store.movers(source)
        named = names.load(Path(a.settings.wow_path) if a.settings.wow_path else winutil.find_wow_retail())
        for r in rows:
            r["name"] = named.get(r["item"]) or f"Item {r['item']}"
        return ok(rows=rows)

    def history(self, item: int, source: str = "realm") -> dict:
        return ok(points=[{"day": d, "market": m, "min": mn} for d, m, mn in self._app.store.history(int(item), source)])

    # actions --------------------------------------------------------------------------------
    def sync_now(self) -> dict:
        self._app.sync_now()
        return ok()

    def toggle_pause(self) -> dict:
        self._app.toggle_pause()
        return ok(paused=self._app.settings.paused)

    def check_update(self) -> dict:
        try:
            self._update = updater.check()
        except Exception as e:
            return fail(f"Couldn't check for updates: {e.__class__.__name__}")
        return ok(update=self._update)

    def install_update(self) -> dict:
        if not self._update:
            return fail("No update to install.")
        try:
            updater.install(self._update)
        except Exception as e:
            return fail(f"Update failed: {e.__class__.__name__}")
        self._app.quit()
        return ok()

    def open_log(self) -> dict:
        self._app.open(config.app_dir() / "clearinghouse.log")
        return ok()

    def hide(self) -> dict:
        self._app.hide()
        return ok()

    def quit(self) -> dict:
        self._app.quit()
        return ok()
