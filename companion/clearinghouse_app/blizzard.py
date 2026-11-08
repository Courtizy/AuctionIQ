"""Blizzard Battle.net API client: OAuth client credentials, realm lookup, auctions, commodities."""

from __future__ import annotations

import re
import time
from dataclasses import dataclass, field

import requests

TOKEN_URL = "https://oauth.battle.net/token"
REGIONS = ("us", "eu", "kr", "tw")


class BlizzardError(Exception):
    """A failed call, with a message fit to show in the status window."""


def realm_slug(name: str) -> str:
    """"Emerald Dream" -> "emerald-dream", "Mal'Ganis" -> "malganis"."""
    s = name.strip().lower().replace("'", "")
    s = re.sub(r"[^a-z0-9]+", "-", s)
    return s.strip("-")


@dataclass
class Fetched:
    """One response: data is None when Blizzard says nothing changed since `since`."""

    data: dict | None
    last_modified: str | None


@dataclass
class Blizzard:
    client_id: str
    client_secret: str
    region: str = "us"
    session: requests.Session = field(default_factory=requests.Session)
    timeout: float = 120.0
    _token: str | None = None
    _token_until: float = 0.0

    def __post_init__(self) -> None:
        if self.region not in REGIONS:
            raise BlizzardError(f"Unknown region {self.region!r}; use one of {', '.join(REGIONS)}.")
        if not self.client_id or not self.client_secret:
            raise BlizzardError("Add your Blizzard client ID and secret in Settings.")

    def token(self) -> str:
        if self._token and time.time() < self._token_until:
            return self._token
        r = self.session.post(TOKEN_URL, data={"grant_type": "client_credentials"},
                              auth=(self.client_id, self.client_secret), timeout=30)
        if r.status_code in (400, 401):
            raise BlizzardError("Blizzard refused the client ID or secret. Check them in Settings.")
        if r.status_code != 200:
            raise BlizzardError(f"Couldn't sign in to Blizzard (HTTP {r.status_code}).")
        body = r.json()
        self._token = body["access_token"]
        self._token_until = time.time() + int(body.get("expires_in", 3600)) - 60
        return self._token

    def get(self, path: str, namespace: str, since: str | None = None) -> Fetched:
        url = f"https://{self.region}.api.blizzard.com{path}"
        headers = {"Authorization": f"Bearer {self.token()}"}
        if since:
            headers["If-Modified-Since"] = since
        params = {"namespace": f"{namespace}-{self.region}", "locale": "en_US"}
        r = self.session.get(url, params=params, headers=headers, timeout=self.timeout)
        if r.status_code == 304:
            return Fetched(None, since)
        if r.status_code == 404:
            raise BlizzardError(f"Blizzard has no {path} (check the realm name and region).")
        if r.status_code == 429:
            raise BlizzardError("Blizzard is rate limiting; the next sync will try again.")
        if r.status_code != 200:
            raise BlizzardError(f"Blizzard answered HTTP {r.status_code} for {path}.")
        return Fetched(r.json(), r.headers.get("Last-Modified"))

    def connected_realm_id(self, realm: str) -> int:
        data = self.get(f"/data/wow/realm/{realm_slug(realm)}", "dynamic").data or {}
        href = (data.get("connected_realm") or {}).get("href", "")
        m = re.search(r"/connected-realm/(\d+)", href)
        if not m:
            raise BlizzardError(f"Couldn't find the connected realm for {realm!r}.")
        return int(m.group(1))

    def auctions(self, connected_realm: int, since: str | None = None) -> Fetched:
        return self.get(f"/data/wow/connected-realm/{connected_realm}/auctions", "dynamic", since)

    def commodities(self, since: str | None = None) -> Fetched:
        return self.get("/data/wow/auctions/commodities", "dynamic", since)


def summarize(auctions: list[dict], share: float = 0.15) -> dict[int, tuple[int, int, int]]:
    """Per item id: (lowest unit price, market value, quantity listed), prices in copper.

    Market value is the average unit price of the cheapest `share` of the quantity listed (at least
    one unit), so a handful of silly high listings don't move it. Bid-only auctions are skipped.
    """
    by_item: dict[int, list[tuple[int, int]]] = {}
    for a in auctions:
        item = (a.get("item") or {}).get("id")
        qty = int(a.get("quantity") or 1)
        if not item or qty <= 0:
            continue
        unit = a.get("unit_price")
        if unit is None:
            buyout = a.get("buyout")
            if not buyout:
                continue
            unit = buyout / qty
        by_item.setdefault(int(item), []).append((int(round(unit)), qty))
    out: dict[int, tuple[int, int, int]] = {}
    for item, rows in by_item.items():
        rows.sort()
        total = sum(q for _, q in rows)
        want = max(1, int(total * share))
        got, spent = 0, 0
        for price, q in rows:
            take = min(q, want - got)
            got += take
            spent += take * price
            if got >= want:
                break
        out[item] = (rows[0][0], int(round(spent / got)), total)
    return out
