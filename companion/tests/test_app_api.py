import json

import pytest

from clearinghouse_app import api as api_mod
from clearinghouse_app import auth, config, names, updater
from clearinghouse_app.api import Api
from clearinghouse_app.blizzard import Blizzard, BlizzardError
from clearinghouse_app.config import Settings
from clearinghouse_app.store import Store

DAY = 86400


class Resp:
    def __init__(self, status, body):
        self.status_code, self._body = status, body

    def json(self):
        return self._body


class Session:
    """Records posts and gets; answers from a {url-suffix: Resp} table."""

    def __init__(self, table):
        self.table, self.calls = table, []

    def _answer(self, url, **kw):
        self.calls.append((url, kw))
        for suffix, resp in self.table.items():
            if url.endswith(suffix):
                return resp
        return Resp(404, {})

    post = _answer

    def get(self, url, **kw):
        return self._answer(url, **kw)


def test_server_auth_trades_the_device_token():
    s = Session({"/token": Resp(200, {"access_token": "abc", "expires_in": 3600})})
    assert auth.ServerAuth("https://keys.example/", "dev").token(s) == ("abc", 3600)
    url, kw = s.calls[0]
    assert url == "https://keys.example/token" and kw["headers"]["Authorization"] == "Bearer dev"


def test_server_auth_signed_out_and_errors():
    with pytest.raises(BlizzardError, match="Log in again"):
        auth.ServerAuth("https://k", "dev").token(Session({"/token": Resp(401, {})}))
    with pytest.raises(BlizzardError, match="no Blizzard keys"):
        auth.ServerAuth("https://k", "dev").token(Session({"/token": Resp(503, {"error": "The server has no Blizzard keys yet."})}))


def test_login_returns_device_token_or_the_servers_error():
    good = Session({"/login": Resp(200, {"device_token": "dt", "user": "jason"})})
    assert auth.login("https://k", " Jason ", "pw", good) == "dt"
    assert good.calls[0][1]["json"] == {"user": "Jason", "password": "pw"}
    with pytest.raises(BlizzardError, match="wrong"):
        auth.login("https://k", "jason", "no", Session({"/login": Resp(401, {"error": "That user name or password is wrong."})}))


def test_blizzard_uses_auth_and_lists_realms():
    class A:
        n = 0

        def token(self, session):
            A.n += 1
            return "tok", 3600
    realms = {"realms": [{"name": "Stormrage"}, {"name": "Area 52"}, {"name": {"en_US": "Emerald Dream"}}, {"name": None}]}
    b = Blizzard(A(), "us", session=Session({"/realm/index": Resp(200, realms)}))
    b.session.get = lambda url, **kw: type("R", (), {"status_code": 200, "json": lambda self: realms, "headers": {}})()
    assert b.realms() == ["Area 52", "Emerald Dream", "Stormrage"]
    b.realms()
    assert A.n == 1   # the token is reused until it expires


def test_store_history_and_movers(tmp_path):
    st = Store(tmp_path / "h.sqlite")
    t0 = 1_800_000_000
    for d in range(10):
        st.add(t0 + d * DAY, "realm", {1: (90_000, 100_000 + d * 10_000, 5), 2: (500, 600, 9), 3: (200_000, 200_000, 1)})
    now = t0 + 9 * DAY
    hist = st.history(1, "realm", now=now)
    assert len(hist) == 10 and hist[0][1] == 100_000 and hist[-1][1] == 190_000
    m = st.movers("realm", now=now)
    assert [r["item"] for r in m] == [1, 3]           # item 2 is under the price floor; 1 moved most
    assert m[0]["change7"] > 0.5 and m[1]["change7"] == 0


def test_names_parse_only_item_names():
    text = 'AuctionIQDB = {\n["x"] = { [5] = "not a name" },\n["itemNames"] = {\n[19019] = "Thunderfury, \\"Blessed\\"",\n[2589] = "Linen Cloth",\n},\n["y"] = {[7] = "nope"}}'
    assert names.parse(text) == {19019: 'Thunderfury, "Blessed"', 2589: "Linen Cloth"}


def test_names_load_reads_every_account(tmp_path):
    for acct, body in (("A", '["itemNames"] = {[1] = "One"}'), ("B", '["itemNames"] = {[2] = "Two"}')):
        f = tmp_path / "WTF" / "Account" / acct / "SavedVariables" / "AuctionIQ.lua"
        f.parent.mkdir(parents=True)
        f.write_text("AuctionIQDB = {" + body + "}", encoding="utf-8")
    assert names.load(tmp_path) == {1: "One", 2: "Two"}
    assert names.load(None) == {}


def test_updater_picks_newest_companion_release():
    rel = lambda tag, asset=True, **kw: {"tag_name": tag, "assets": [{"name": updater.ASSET, "browser_download_url": f"https://dl/{tag}"}] if asset else [], **kw}
    releases = [rel("v1.4.0"), rel("companion-v0.3.0"), rel("companion-v0.10.0", prerelease=True), rel("companion-v0.4.1"),
                rel("companion-v0.9.0", asset=False)]
    best = updater.newest(releases, "0.2.0")
    assert best["version"] == "0.4.1" and best["url"] == "https://dl/companion-v0.4.1"
    assert updater.newest(releases, "0.4.1") is None
    assert updater.version_tuple("companion-v0.10.0") > updater.version_tuple("0.9.9")


class FakeApp:
    def __init__(self, tmp_path):
        self.settings = Settings()
        self.settings.save = lambda path=None: None
        self.state = type("S", (), {"status": "Setup", "message": "", "last_sync": None, "next_sync": None, "items": (0, 0)})()
        self.store = Store(tmp_path / "h.sqlite")
        self.synced = self.pushed = 0

    def sync_now(self):
        self.synced += 1

    def push(self):
        self.pushed += 1


@pytest.fixture
def keyring_box(monkeypatch):
    box = {}
    monkeypatch.setattr(config, "get_device_token", lambda: box.get("dt", ""))
    monkeypatch.setattr(config, "set_device_token", lambda t: box.__setitem__("dt", t) if t else box.pop("dt", None))
    monkeypatch.setattr(api_mod.winutil, "start_with_windows", lambda: False)
    monkeypatch.setattr(api_mod.winutil, "set_start_with_windows", lambda on: None)
    monkeypatch.setattr(api_mod.winutil, "find_wow_retail", lambda: None)
    return box


def test_setup_flow_login_realm_then_ready(tmp_path, monkeypatch, keyring_box):
    app = FakeApp(tmp_path)
    a = Api(app)
    st = a.state()
    assert not st["ready"] and not st["signedIn"] and st["realm"] == ""
    json.dumps(st)   # everything the window gets is plain JSON

    monkeypatch.setattr(auth, "login", lambda server, user, pw: (_ for _ in ()).throw(BlizzardError("That user name or password is wrong.")))
    assert a.login("jason", "bad") == {"ok": False, "error": "That user name or password is wrong."}
    monkeypatch.setattr(auth, "login", lambda server, user, pw: "device-token")
    assert a.login(" Jason ", "pw")["ok"] and keyring_box["dt"] == "device-token" and app.settings.user == "jason"
    assert a.state()["signedIn"] and not a.state()["ready"]

    monkeypatch.setattr(Blizzard, "realms", lambda self: ["Area 52", "Emerald Dream"])
    assert a.realms("us") == {"ok": True, "realms": ["Area 52", "Emerald Dream"]}
    assert not a.realms("mars")["ok"]

    assert a.save({"region": "us", "realm": ""}) == {"ok": False, "error": "Pick your realm."}
    assert not a.save({"region": "us", "realm": "Area 52", "wowPath": str(tmp_path)})["ok"]   # no Interface\AddOns there
    assert a.save({"region": "us", "realm": "Area 52"})["ok"]
    assert a.state()["ready"] and app.synced == 1

    a.logout()
    assert not a.state()["ready"] and "dt" not in keyring_box


def test_movers_get_names(tmp_path, monkeypatch, keyring_box):
    app = FakeApp(tmp_path)
    for d in range(9):
        app.store.add(1_800_000_000 + d * DAY, "realm", {7: (10_000, 20_000 + d * 2_000, 3)})
    monkeypatch.setattr(app.store, "movers", lambda source: [{"item": 7, "market": 1, "change7": 0.1}, {"item": 8, "market": 1, "change7": 0.1}])
    monkeypatch.setattr(names, "load", lambda retail: {7: "Linen Cloth"})
    rows = Api(app).movers("realm")["rows"]
    assert [r["name"] for r in rows] == ["Linen Cloth", "Item 8"]
    assert len(Api(app).history(7)["points"]) == 9
