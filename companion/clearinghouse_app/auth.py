"""Where the app gets a Blizzard access token.

ServerAuth (the default): log in once to the Clearinghouse key server, keep its device token in
Windows Credential Manager, and trade it for a Blizzard token when one is needed. The Blizzard keys
stay on the server, so nothing secret ships in the download.

KeysAuth: your own client ID and secret from develop.battle.net, for development and the CI check.
"""

from __future__ import annotations

import requests

from .blizzard import TOKEN_URL, BlizzardError

# The key server's address. Override it in Settings (server_url) if it moves.
DEFAULT_SERVER = "https://clearinghouse-keys.courtizy.workers.dev"


class KeysAuth:
    name = "your own Blizzard keys"

    def __init__(self, client_id: str, client_secret: str):
        if not client_id or not client_secret:
            raise BlizzardError("Log in to Clearinghouse first.")
        self.client_id, self.client_secret = client_id, client_secret

    def token(self, session: requests.Session) -> tuple[str, int]:
        r = session.post(TOKEN_URL, data={"grant_type": "client_credentials"},
                         auth=(self.client_id, self.client_secret), timeout=30)
        if r.status_code in (400, 401):
            raise BlizzardError("Blizzard refused the client ID or secret.")
        if r.status_code != 200:
            raise BlizzardError(f"Couldn't sign in to Blizzard (HTTP {r.status_code}).")
        body = r.json()
        return body["access_token"], int(body.get("expires_in", 3600))


class ServerAuth:
    name = "the Clearinghouse server"

    def __init__(self, server: str, device_token: str):
        if not device_token:
            raise BlizzardError("Log in to Clearinghouse first.")
        self.server, self.device_token = server.rstrip("/"), device_token

    def token(self, session: requests.Session) -> tuple[str, int]:
        try:
            r = session.post(f"{self.server}/token", headers={"Authorization": f"Bearer {self.device_token}"}, timeout=30)
        except requests.RequestException as e:
            raise BlizzardError(f"Couldn't reach the Clearinghouse server ({e.__class__.__name__}).") from e
        if r.status_code == 401:
            raise BlizzardError("Signed out of Clearinghouse. Log in again.")
        if r.status_code != 200:
            raise BlizzardError(_error(r, "The Clearinghouse server"))
        body = r.json()
        return body["access_token"], int(body.get("expires_in", 3600))


def login(server: str, user: str, password: str, session: requests.Session | None = None) -> str:
    """Log in to the key server; returns the device token to keep."""
    session = session or requests.Session()
    try:
        r = session.post(f"{server.rstrip('/')}/login", json={"user": user.strip(), "password": password}, timeout=30)
    except requests.RequestException as e:
        raise BlizzardError(f"Couldn't reach the Clearinghouse server ({e.__class__.__name__}).") from e
    if r.status_code != 200:
        raise BlizzardError(_error(r, "Login"))
    return r.json()["device_token"]


def _error(r: requests.Response, what: str) -> str:
    try:
        return r.json().get("error") or f"{what} failed (HTTP {r.status_code})."
    except ValueError:
        return f"{what} failed (HTTP {r.status_code})."
