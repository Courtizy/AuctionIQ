"""The tray app: Sync now, Pause/Resume, Status, Settings, Start with Windows, Quit.

pystray runs the tray icon on its own thread; tkinter owns the main thread for the windows; one worker
thread runs syncs. They talk through a queue, so the windows are only ever touched by tkinter.
"""

from __future__ import annotations

import logging
import queue
import sys
import threading
import time
from logging.handlers import RotatingFileHandler
from pathlib import Path

from . import __version__, config, winutil
from .blizzard import REGIONS, Blizzard
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
        self.events: queue.Queue = queue.Queue()
        self.wake = threading.Event()
        self.stop = threading.Event()
        self.ui: queue.Queue = queue.Queue()

    def client(self) -> Blizzard:
        cid, secret = config.get_keys()
        return Blizzard(cid, secret, self.settings.region)

    # worker ------------------------------------------------------------------------------------
    def worker(self):
        while not self.stop.is_set():
            now = time.time()
            due = self.state.next_sync is None or now >= self.state.next_sync
            forced = self.wake.is_set()
            self.wake.clear()
            if forced or (due and not self.settings.paused):
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

    def set_status(self, status, message):
        self.state.status, self.state.message = status, message
        log.info("%s: %s", status, message)
        self.ui.put("refresh")

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
            item("Status...", lambda: self.ui.put("status"), default=True),
            item("Sync now", self.sync_now),
            item("Pause", self.toggle_pause, checked=lambda _: self.settings.paused),
            item("Settings...", lambda: self.ui.put("settings")),
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
        self.ui.put("refresh")

    def open(self, path: Path):
        import os
        if winutil.is_windows() and path.exists():
            os.startfile(str(path))  # noqa: S606 - opens the log in the default editor

    def quit(self):
        self.stop.set()
        self.wake.set()
        self.ui.put("quit")

    # windows (tkinter, main thread) -----------------------------------------------------------
    def run(self):
        import tkinter as tk
        self.tk = tk
        self.root = tk.Tk()
        self.root.withdraw()
        self.root.title("Clearinghouse")
        try:
            self.root.iconbitmap(default=str(resource("clearinghouse.ico")))
        except Exception:
            pass
        self.status_win = None
        self.build_tray()
        self.tray.run_detached()
        threading.Thread(target=self.worker, daemon=True).start()
        if not config.get_keys()[0]:
            self.ui.put("settings")
        self.root.after(200, self.pump)
        self.root.mainloop()
        self.tray.stop()

    def pump(self):
        try:
            while True:
                msg = self.ui.get_nowait()
                if msg == "quit":
                    self.root.quit()
                    return
                if msg == "status":
                    self.show_status()
                elif msg == "settings":
                    self.show_settings()
                elif msg == "refresh":
                    self.tray.title = self.tray_title()
                    self.tray.update_menu()
                    self.fill_status()
        except queue.Empty:
            pass
        self.root.after(250, self.pump)

    def show_status(self):
        tk = self.tk
        if self.status_win and self.status_win.winfo_exists():
            self.status_win.deiconify()
            self.status_win.lift()
            return
        w = tk.Toplevel(self.root)
        w.title("Clearinghouse status")
        w.geometry("520x360")
        w.resizable(False, True)
        self.status_text = tk.Text(w, wrap="word", height=12, font=("Segoe UI", 10), relief="flat", padx=12, pady=10)
        self.status_text.pack(fill="both", expand=True)
        bar = tk.Frame(w)
        bar.pack(fill="x", padx=10, pady=8)
        tk.Button(bar, text="Sync now", command=self.sync_now, width=12).pack(side="left")
        self.pause_btn = tk.Button(bar, text="Pause", command=self.toggle_pause, width=12)
        self.pause_btn.pack(side="left", padx=6)
        tk.Button(bar, text="Settings", command=self.show_settings, width=12).pack(side="left")
        tk.Button(bar, text="Close", command=w.withdraw, width=10).pack(side="right")
        w.protocol("WM_DELETE_WINDOW", w.withdraw)
        self.status_win = w
        self.fill_status()

    def fill_status(self):
        if not (self.status_win and self.status_win.winfo_exists()):
            return
        s, st = self.state, self.settings
        fmt = lambda t: time.strftime("%a %H:%M", time.localtime(t)) if t else "-"
        counts = self.store.counts()
        addon = st.addon_dir()
        lines = [
            f"State: {s.status}",
            f"{s.message}",
            "",
            f"Realm: {st.realm} ({st.region.upper()})",
            f"Last sync: {fmt(s.last_sync)}    Next sync: {'paused' if st.paused else fmt(s.next_sync)}",
            f"Items in the data file: {s.items[0]:,} on the realm, {s.items[1]:,} region commodities",
            f"History: {counts['days']} days, {counts['snapshots']} snapshots kept",
            f"Writes to: {addon / 'Data.lua' if addon else 'WoW not found'}",
            "",
            f"Version {__version__}. Never touches SavedVariables or TradeSkillMaster.",
        ]
        t = self.status_text
        t.configure(state="normal")
        t.delete("1.0", "end")
        t.insert("1.0", "\n".join(lines))
        t.configure(state="disabled")
        self.pause_btn.configure(text="Resume" if st.paused else "Pause")

    def show_settings(self):
        tk = self.tk
        w = tk.Toplevel(self.root)
        w.title("Clearinghouse settings")
        w.resizable(False, False)
        st = self.settings
        cid, secret = config.get_keys()
        vars_ = {
            "region": tk.StringVar(value=st.region), "realm": tk.StringVar(value=st.realm),
            "wow_path": tk.StringVar(value=st.wow_path), "interval": tk.StringVar(value=str(st.interval_minutes)),
            "wait": tk.BooleanVar(value=st.wait_for_wow_closed), "cid": tk.StringVar(value=cid),
            "secret": tk.StringVar(value=secret), "auto": tk.BooleanVar(value=winutil.start_with_windows()),
        }
        rows = [("Region", tk.OptionMenu(w, vars_["region"], *REGIONS)),
                ("Realm", tk.Entry(w, textvariable=vars_["realm"], width=40)),
                ("WoW _retail_ folder (blank = find it)", tk.Entry(w, textvariable=vars_["wow_path"], width=40)),
                ("Sync every (minutes, 15 or more)", tk.Entry(w, textvariable=vars_["interval"], width=8)),
                ("Blizzard client ID", tk.Entry(w, textvariable=vars_["cid"], width=40)),
                ("Blizzard client secret", tk.Entry(w, textvariable=vars_["secret"], width=40, show="*"))]
        for i, (label, widget) in enumerate(rows):
            tk.Label(w, text=label, anchor="w").grid(row=i, column=0, sticky="w", padx=12, pady=4)
            widget.grid(row=i, column=1, sticky="w", padx=12, pady=4)
        n = len(rows)
        tk.Checkbutton(w, text="Only write the data file while WoW is closed", variable=vars_["wait"]).grid(
            row=n, column=0, columnspan=2, sticky="w", padx=12)
        tk.Checkbutton(w, text="Start with Windows", variable=vars_["auto"]).grid(row=n + 1, column=0, columnspan=2, sticky="w", padx=12)
        tk.Label(w, text="Keys are kept in Windows Credential Manager on this PC. Get them at develop.battle.net.",
                 fg="#666").grid(row=n + 2, column=0, columnspan=2, sticky="w", padx=12, pady=(8, 0))
        msg = tk.Label(w, text="", fg="#a33")
        msg.grid(row=n + 3, column=0, columnspan=2, sticky="w", padx=12)

        def save():
            try:
                interval = max(15, int(vars_["interval"].get()))
            except ValueError:
                msg.configure(text="Sync every: enter a number of minutes.")
                return
            path = vars_["wow_path"].get().strip()
            if path and not (Path(path) / "Interface" / "AddOns").is_dir():
                msg.configure(text="That folder has no Interface\\AddOns. Pick the _retail_ folder.")
                return
            realm_changed = (vars_["realm"].get().strip(), vars_["region"].get()) != (st.realm, st.region)
            st.region, st.realm, st.wow_path = vars_["region"].get(), vars_["realm"].get().strip(), path
            st.interval_minutes, st.wait_for_wow_closed = interval, vars_["wait"].get()
            st.save()
            if vars_["cid"].get().strip() and vars_["secret"].get().strip():
                config.set_keys(vars_["cid"].get(), vars_["secret"].get())
            winutil.set_start_with_windows(vars_["auto"].get())
            w.destroy()
            if realm_changed or not self.state.last_sync:
                self.sync_now()
            self.ui.put("refresh")

        bar = tk.Frame(w)
        bar.grid(row=n + 4, column=0, columnspan=2, sticky="e", padx=12, pady=10)
        tk.Button(bar, text="Save", command=save, width=10).pack(side="left", padx=4)
        tk.Button(bar, text="Cancel", command=w.destroy, width=10).pack(side="left")


def main():
    if not winutil.single_instance():
        return
    App().run()
