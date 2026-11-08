# Clearinghouse key server

A Cloudflare Worker that keeps the Blizzard API keys so the Clearinghouse app never ships them. You
log in once from the app; the Worker hands back a device token, then trades it for a short-lived
Blizzard access token whenever the app needs one. It never sees or stores auction data.

| Route | Does |
|---|---|
| `POST /login` `{"user","password"}` | Checks the user against `CH_USERS` and returns a device token |
| `POST /token` with `Authorization: Bearer <device token>` | Returns a Blizzard access token (cached until near expiry) |
| `GET /health` | `{"ok": true}` |

Changing a user's password in `CH_USERS` signs that user's devices out.

## Secrets

Kept in Cloudflare as Worker secrets; the "Key server" workflow copies them from the repository's
secrets on every deploy and never prints them.

| Repository secret | Used for |
|---|---|
| `CLOUDFLARE_API_TOKEN` | Deploying (a token from the "Edit Cloudflare Workers" template) |
| `CLOUDFLARE_ACCOUNT_ID` | Which Cloudflare account to deploy to |
| `BLIZZARD_CLIENT_ID`, `BLIZZARD_CLIENT_SECRET` | The keys from develop.battle.net |
| `CH_USERS` | Who may log in: one `name:password` per line |

## Test and deploy

`cd server && npm test`. The workflow tests every pull request that touches `server/`, and deploys on
a push to main or when run by hand from the Actions tab.
