"""Settings in %APPDATA%\\Clearinghouse\\settings.json; Blizzard keys in Windows Credential Manager."""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, fields
from pathlib import Path

KEYRING_SERVICE = "Clearinghouse (AuctionIQ)"


def app_dir() -> Path:
    base = os.environ.get("APPDATA") or str(Path.home() / ".config")
    d = Path(base) / "Clearinghouse"
    d.mkdir(parents=True, exist_ok=True)
    return d


@dataclass
class Settings:
    region: str = "us"
    realm: str = "Emerald Dream"
    wow_path: str = ""              # the _retail_ folder; found from the registry when blank
    interval_minutes: int = 60
    wait_for_wow_closed: bool = False
    paused: bool = False

    @classmethod
    def load(cls, path: Path | None = None) -> "Settings":
        path = path or app_dir() / "settings.json"
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            raw = {}
        known = {f.name for f in fields(cls)}
        s = cls(**{k: v for k, v in raw.items() if k in known})
        s.interval_minutes = max(15, int(s.interval_minutes or 60))
        return s

    def save(self, path: Path | None = None) -> None:
        path = path or app_dir() / "settings.json"
        path.write_text(json.dumps(asdict(self), indent=2), encoding="utf-8")

    def addon_dir(self) -> Path | None:
        from . import winutil
        root = Path(self.wow_path) if self.wow_path else winutil.find_wow_retail()
        return root / "Interface" / "AddOns" / "Clearinghouse" if root else None


def get_keys() -> tuple[str, str]:
    try:
        import keyring
        return (keyring.get_password(KEYRING_SERVICE, "client_id") or "",
                keyring.get_password(KEYRING_SERVICE, "client_secret") or "")
    except Exception:
        return "", ""


def set_keys(client_id: str, client_secret: str) -> None:
    import keyring
    keyring.set_password(KEYRING_SERVICE, "client_id", client_id.strip())
    keyring.set_password(KEYRING_SERVICE, "client_secret", client_secret.strip())
