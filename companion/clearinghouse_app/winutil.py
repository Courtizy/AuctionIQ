"""Windows helpers: find WoW, see if it's running, start with Windows, one copy at a time."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
APP_NAME = "Clearinghouse"


def is_windows() -> bool:
    return sys.platform == "win32"


def find_wow_retail() -> Path | None:
    candidates = []
    if is_windows():
        import winreg
        for key in (r"SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft",
                    r"SOFTWARE\Blizzard Entertainment\World of Warcraft"):
            try:
                with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key) as k:
                    p = Path(winreg.QueryValueEx(k, "InstallPath")[0])
                    candidates.append(p if p.name == "_retail_" else p / "_retail_")
            except OSError:
                pass
    candidates += [Path(r"C:\Program Files (x86)\World of Warcraft\_retail_"),
                   Path(r"C:\Program Files (x86)\Games\World of Warcraft\_retail_"),
                   Path(r"C:\Program Files\World of Warcraft\_retail_")]
    for p in candidates:
        if (p / "Interface" / "AddOns").is_dir():
            return p
    return None


def wow_running() -> bool:
    if not is_windows():
        return False
    try:
        out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq Wow.exe", "/NH"], capture_output=True, text=True,
                             creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0), timeout=10).stdout
        return "wow.exe" in out.lower()
    except Exception:
        return False


def exe_command() -> str:
    if getattr(sys, "frozen", False):
        return f'"{sys.executable}" --minimized'
    return f'"{sys.executable}" -m clearinghouse_app --minimized'


def start_with_windows() -> bool:
    if not is_windows():
        return False
    import winreg
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as k:
            winreg.QueryValueEx(k, APP_NAME)
            return True
    except OSError:
        return False


def set_start_with_windows(on: bool) -> None:
    if not is_windows():
        return
    import winreg
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as k:
        if on:
            winreg.SetValueEx(k, APP_NAME, 0, winreg.REG_SZ, exe_command())
        else:
            try:
                winreg.DeleteValue(k, APP_NAME)
            except OSError:
                pass


_mutex = None


def single_instance() -> bool:
    """True when this is the only copy running (Windows named mutex)."""
    global _mutex
    if not is_windows():
        return True
    import ctypes
    _mutex = ctypes.windll.kernel32.CreateMutexW(None, False, "Local\\ClearinghouseAuctionIQ")
    return ctypes.windll.kernel32.GetLastError() != 183  # ERROR_ALREADY_EXISTS
