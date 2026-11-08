import json
from pathlib import Path

import pytest

from clearinghouse_app import export
from clearinghouse_app.auth import ServerAuth
from clearinghouse_app.blizzard import Blizzard, BlizzardError, Fetched, realm_slug, summarize
from clearinghouse_app.config import Settings
from clearinghouse_app.store import Store
from clearinghouse_app.sync import Syncer

ADDON = Path(__file__).resolve().parents[1] / "addon" / "Clearinghouse"
DAY = 86400


def test_realm_slug():
    assert realm_slug("Emerald Dream") == "emerald-dream"
    assert realm_slug("Mal'Ganis") == "malganis"


def test_summarize_market_is_cheapest_15_percent():
    auctions = [{"item": {"id": 1}, "quantity": 10, "unit_price": 100},
                {"item": {"id": 1}, "quantity": 90, "unit_price": 1000},
                {"item": {"id": 2}, "quantity": 1, "buyout": 5000},
                {"item": {"id": 2}, "quantity": 2, "buyout": 8000},
                {"item": {"id": 3}, "quantity": 1, "bid": 10}]
    s = summarize(auctions)
    # 15 of 100 units: 10 at 100 + 5 at 1000 -> 400 average
    assert s[1] == (100, 400, 100)
    assert s[2] == (4000, 4000, 3)
    assert 3 not in s


def test_blizzard_needs_a_login():
    with pytest.raises(BlizzardError):
        Blizzard(None, "us")
    with pytest.raises(BlizzardError):
        ServerAuth("https://x", "")


def test_store_stats_history(tmp_path):
    st = Store(tmp_path / "h.sqlite")
    t0 = 1_800_000_000
    for d in range(10):
        st.add(t0 + d * DAY, "commodity", {7: (90 + d, 100 + d * 10, 50)})
    now = t0 + 9 * DAY
    s = st.stats("commodity", now)[7]
    assert s.market == 190 and s.min == 99 and s.qty == 50
    assert s.days == 10
    assert s.avg7 == round(sum(100 + d * 10 for d in range(3, 10)) / 7)
    assert abs(s.change7 - (190 / 120 - 1)) < 1e-9   # 7 days ago the market was 120
    assert s.vol30 is not None and s.vol30 > 0


def test_store_prunes_old_snapshots(tmp_path):
    st = Store(tmp_path / "h.sqlite")
    st.add(1_800_000_000, "realm", {1: (1, 1, 1)})
    st.add(1_800_000_000 + 20 * DAY, "realm", {1: (2, 2, 1)})
    assert st.counts()["snapshots"] == 1 and st.counts()["days"] == 2


class FakeClient:
    def __init__(self):
        self.calls = []

    def connected_realm_id(self, realm):
        self.calls.append(("realm", realm))
        return 1234

    def auctions(self, crid, since):
        self.calls.append(("auctions", crid, since))
        if since == "A":
            return Fetched(None, "A")
        return Fetched({"auctions": [{"item": {"id": 10}, "quantity": 1, "buyout": 25000}]}, "A")

    def commodities(self, since):
        self.calls.append(("commodities", since))
        return Fetched({"auctions": [{"item": {"id": 20}, "quantity": 5, "unit_price": 300}]}, "C")


def test_sync_writes_data_lua_and_lua_reads_it(tmp_path):
    lupa = pytest.importorskip("lupa")
    addon = tmp_path / "Clearinghouse"
    st = Store(tmp_path / "h.sqlite")
    fake = FakeClient()
    syncer = Syncer(st, lambda: fake)
    s = Settings(realm="Emerald Dream")
    res = syncer.run(s, addon, now=1_800_000_000)
    assert res.ok and res.wrote and res.fetched == ["realm", "commodity"]
    assert (res.realm_items, res.commodity_items) == (1, 1)
    # second run: realm unchanged (304), connected realm id cached
    res2 = syncer.run(s, addon, now=1_800_003_600)
    assert res2.ok and res2.fetched == ["commodity"]
    assert sum(1 for c in fake.calls if c[0] == "realm") == 1
    assert ("auctions", 1234, "A") in fake.calls

    L = lupa.LuaRuntime()
    L.execute((addon / "Data.lua").read_text(encoding="utf-8"))
    L.execute((ADDON / "Clearinghouse.lua").read_text(encoding="utf-8"))
    g = L.globals()
    sword = g.ClearinghouseMarket.Get(10)
    herb = g.ClearinghouseMarket.Get(20)
    assert sword.market == 25000 and sword.source == "realm" and sword.days == 1
    assert herb.min == 300 and herb.qty == 5 and herb.source == "commodity"
    assert g.ClearinghouseMarket.Get(99) is None
    info = g.ClearinghouseMarket.Info
    assert info()[1] == "Emerald Dream"


def test_shipped_empty_data_file_loads():
    lupa = pytest.importorskip("lupa")
    L = lupa.LuaRuntime()
    L.execute((ADDON / "Data.lua").read_text(encoding="utf-8"))
    L.execute((ADDON / "Clearinghouse.lua").read_text(encoding="utf-8"))
    assert L.globals().ClearinghouseMarket.Get(1) is None


def test_wait_for_wow_holds_the_write(tmp_path):
    addon = tmp_path / "Clearinghouse"
    syncer = Syncer(Store(tmp_path / "h.sqlite"), FakeClient, wow_running=lambda: True)
    s = Settings(wait_for_wow_closed=True)
    res = syncer.run(s, addon, now=1_800_000_000)
    assert res.ok and res.pending_write and not (addon / "Data.lua").exists()
    syncer.wow_running = lambda: False
    res = syncer.write(s, addon, 1_800_000_100)
    assert res.wrote and (addon / "Data.lua").exists()


def test_errors_are_reported_not_raised(tmp_path):
    class Bad(FakeClient):
        def connected_realm_id(self, realm):
            raise BlizzardError("Blizzard refused the client ID or secret. Check them in Settings.")
    res = Syncer(Store(tmp_path / "h.sqlite"), Bad).run(Settings(), tmp_path / "x")
    assert not res.ok and "client ID" in res.message
    assert Syncer(Store(tmp_path / "h2.sqlite"), Bad).run(Settings(), None).message.startswith("Couldn't find World")


def test_settings_roundtrip(tmp_path):
    p = tmp_path / "s.json"
    Settings(realm="Area 52", interval_minutes=5).save(p)
    s = Settings.load(p)
    assert s.realm == "Area 52" and s.interval_minutes == 15
    assert "secret" not in json.loads(p.read_text()).keys()


def test_lua_string_escaping():
    assert export.lua_quote('a"b\\c') == '"a\\"b\\\\c"'
