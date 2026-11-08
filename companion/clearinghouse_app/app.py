"""The Clearinghouse app: one themed window (a web view) plus a tray icon.

pywebview owns the main thread and shows ui/index.html, whose JavaScript calls api.Api. pystray runs
the tray icon on its own thread, and one worker thread runs syncs. Closing the window hides it to
the tray; Quit (tray or window) ends the app.
"""

from __future__ import annotations

import logging
import sys
import threading
import time
from logging.handlers import RotatingFileHandler
from pathlib import Path

from . import config, winutil
from .api import Api
from .blizzard import Blizzard
from .store import Store
from .sync import Syncer

log = logging.getLogger("clearinghouse")


def resource(name: str) -> Path:
    base = Path(getattr(sys, "_MEIPASS", Path(__file__).parent))
    p = base / name
    return p if p.exists() else Path(__file__).parent / name


class State:
    def __init__(self):
        self.status = "Starting"           # Synced, Syncing, Paused, Error, Waiting
        self.message = ""
        self.last_sync: float | None = None
        self.next_sync: float | None = None
        self.items = (0, 0)


class App:
    def __init__(self):
        self.dir = config.app_dir()
        handler = RotatingFileHandler(self.dir / "clearinghouse.log", maxBytes=1_000_000, backupCount=3, encoding="utf-8")
        handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
        log.addHandler(handler)
        log.setLevel(logging.INFO)
        self.settings = config.Settings.load()
        self.store = Store(self.dir / "history.sqlite")
        self.syncer = Syncer(self.store, self.client, winutil.wow_running)
        self.state = State()
        self.wake = threading.Event()
        self.stop = threading.Event()
        self.window = None

    def client(self) -> Blizzard:
        return Blizzard(config.make_auth(self.settings), self.settings.region)

    # worker ------------------------------------------------------------------------------------
    def worker(self):
        while not self.stop.is_set():
            now = time.time()
            due = self.state.next_sync is None or now >= self.state.next_sync
            forced = self.wake.is_set()
            self.wake.clear()
            if not self.settings.ready():
                self.set_status("Setup", "Log in and pick your realm to start syncing.", quiet=True)
            elif forced or (due and not self.settings.paused):
                self.sync_once()
            elif self.syncer.pending and not (self.settings.wait_for_wow_closed and winutil.wow_running()):
                res = self.syncer.write(self.settings, self.settings.addon_dir(), int(now))
                self.after_result(res, wrote_only=True)
            self.wake.wait(30)

    def sync_once(self):
        self.set_status("Syncing", "Fetching from Blizzard...")
        res = self.syncer.run(self.settings, self.settings.addon_dir())
        self.after_result(res)

    def after_result(self, res, wrote_only=False):
        now = time.time()
        if not wrote_only:
            self.state.last_sync = now
            self.state.next_sync = now + self.settings.interval_minutes * 60
        if res.wrote:
            self.state.items = (res.realm_items, res.commodity_items)
        status = "Error" if not res.ok else ("Waiting" if res.pending_write else ("Paused" if self.settings.paused else "Synced"))
        self.set_status(status, res.message)

    def set_status(self, status, message, quiet=False):
        if quiet and (self.state.status, self.state.message) == (status, message):
            return
        self.state.status, self.state.message = status, message
        log.info("%s: %s", status, message)
        self.push()

    def push(self):
        """Tell the tray and the window something changed (safe from any thread)."""
        tray = getattr(self, "tray", None)
        if tray:
            tray.title = self.tray_title()
            tray.update_menu()
        win = getattr(self, "window", None)
        if win:
            try:
                win.evaluate_js("window.CH && CH.refresh()")
            except Exception:
                pass

    # tray --------------------------------------------------------------------------------------
    def build_tray(self):
        import pystray
        from PIL import Image
        base = Image.open(resource("icon.png")).convert("RGBA")
        self.icons = {"base": base}

        def item(text, action, **kw):
            return pystray.MenuItem(text, lambda *_: action(), **kw)

        menu = pystray.Menu(
            pystray.MenuItem(lambda _: f"Clearinghouse: {self.state.status}", None, enabled=False),
            item("Open Clearinghouse", self.show, default=True),
            item("Sync now", self.sync_now),
            item("Pause", self.toggle_pause, checked=lambda _: self.settings.paused),
            item("Start with Windows", self.toggle_autostart, checked=lambda _: winutil.start_with_windows()),
            item("Open log", lambda: self.open(self.dir / "clearinghouse.log")),
            pystray.Menu.SEPARATOR,
            item("Quit", self.quit),
        )
        self.tray = pystray.Icon("Clearinghouse", base, "Clearinghouse", menu)

    def tray_title(self):
        s = self.state
        last = time.strftime("%H:%M", time.localtime(s.last_sync)) if s.last_sync else "never"
        return f"Clearinghouse: {s.status} (last sync {last})"[:120]

    def sync_now(self):
        self.wake.set()

    def toggle_pause(self):
        self.settings.paused = not self.settings.paused
        self.settings.save()
        if not self.settings.paused:
            self.state.next_sync = time.time()
            self.wake.set()
        self.set_status("Paused" if self.settings.paused else "Synced",
                        "Paused: no syncs until you resume." if self.settings.paused else "Resumed.")

    def toggle_autostart(self):
        winutil.set_start_with_windows(not winutil.start_with_windows())
        self.push()

    def open(self, path: Path):
        import os
        if winutil.is_windows() and path.exists():
            os.startfile(str(path))  # noqa: S606 - opens the log in the default editor

    def show(self):
        if self.window:
            self.window.show()
            self.window.restore()

    def hide(self):
        if self.window:
            self.window.hide()

    def quit(self):
        self.stop.set()
        self.wake.set()
        self.quitting = True
        if self.window:
            self.window.destroy()

    # window (pywebview, main thread) ----------------------------------------------------------
    def run(self, minimized: bool = False):
        import webview
        self.window = None
        self.quitting = False
        self.build_tray()
        self.tray.run_detached()
        threading.Thread(target=self.worker, daemon=True).start()
        api = Api(self)

        def check_update():
            time.sleep(8)
            if api.check_update().get("update"):
                self.push()
        threading.Thread(target=check_update, daemon=True).start()
        self.window = webview.create_window(
            "Clearinghouse", url=str(resource("ui") / "index.html"), js_api=api,
            width=1040, height=700, min_size=(820, 560), background_color="#1c1222",
            hidden=minimized and self.settings.ready())

        def closing():
            if self.quitting:
                return True
            self.window.hide()       # the close box sends it to the tray
            return False
        self.window.events.closing += closing
        webview.start(gui="edgechromium" if winutil.is_windows() else None, debug=False)
        self.stop.set()
        self.tray.stop()



def main():
    if not winutil.single_instance():
        return
    App().run(minimized="--minimized" in sys.argv)
