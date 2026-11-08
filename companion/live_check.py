"""CI smoke test against the real Blizzard API: one sync into a temp folder, counts only.

Reads BLIZZARD_CLIENT_ID / BLIZZARD_CLIENT_SECRET from the environment (GitHub secrets); never prints them.
"""
import os
import sys
import tempfile
from pathlib import Path

from clearinghouse_app.auth import KeysAuth
from clearinghouse_app.blizzard import Blizzard
from clearinghouse_app.config import Settings
from clearinghouse_app.store import Store
from clearinghouse_app.sync import Syncer

cid, secret = os.environ.get("BLIZZARD_CLIENT_ID", ""), os.environ.get("BLIZZARD_CLIENT_SECRET", "")
if not cid or not secret:
    print("No Blizzard secrets in this run; skipping the live check.")
    sys.exit(0)
with tempfile.TemporaryDirectory() as d:
    settings = Settings(region="us", realm="Emerald Dream")
    syncer = Syncer(Store(Path(d) / "h.sqlite"), lambda: Blizzard(KeysAuth(cid, secret), "us"))
    res = syncer.run(settings, Path(d) / "Clearinghouse")
    print(res.message)
    print(f"{len(Blizzard(KeysAuth(cid, secret), 'us').realms())} US realms in the realm picker")
    if not res.ok:
        sys.exit(1)
    size = (Path(d) / "Clearinghouse" / "Data.lua").stat().st_size
    print(f"Emerald Dream: {res.realm_items} realm items, {res.commodity_items} region commodities, Data.lua {size / 1e6:.1f} MB")
