// Clearinghouse key server: a Cloudflare Worker that keeps the Blizzard API keys so the app never
// ships them. You log in once from the app; the Worker hands back a device token, and from then on
// trades that token for a short-lived Blizzard access token whenever the app asks.
//
// Secrets (set in Cloudflare, never in the repo):
//   BLIZZARD_CLIENT_ID, BLIZZARD_CLIENT_SECRET  the keys from develop.battle.net
//   CH_USERS                                    one "name:password" per line, who may log in
//
// Routes:
//   POST /login  {"user","password"}            -> {"device_token","user"}
//   POST /token  Authorization: Bearer <device> -> {"access_token","expires_in"}
//   GET  /health                                -> {"ok":true}
//
// A device token is "<base64url(json)>.<base64url(hmac)>", signed with a key made from the client
// secret and that user's password, so changing a password signs every old device out.

const TOKEN_URL = "https://oauth.battle.net/token";
const enc = new TextEncoder();
let cached = null; // { token, until } per Worker instance

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });
}

function b64url(bytes) {
  let s = "";
  for (const b of new Uint8Array(bytes)) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function unb64url(s) {
  const pad = s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4);
  return Uint8Array.from(atob(pad), (c) => c.charCodeAt(0));
}

/** Equal-time string compare, so a wrong password takes as long as a right one. */
export function same(a, b) {
  const x = enc.encode(String(a)), y = enc.encode(String(b));
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] || 0) ^ (y[i] || 0);
  return diff === 0;
}

export function users(env) {
  const out = new Map();
  for (const line of String(env.CH_USERS || "").split(/\r?\n/)) {
    const i = line.indexOf(":");
    if (i > 0) out.set(line.slice(0, i).trim().toLowerCase(), line.slice(i + 1).trim());
  }
  return out;
}

async function sign(env, password, payload) {
  const key = await crypto.subtle.importKey("raw", enc.encode(`${env.BLIZZARD_CLIENT_SECRET}\n${password}`),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return b64url(await crypto.subtle.sign("HMAC", key, enc.encode(payload)));
}

export async function issue(env, user, password, now = Date.now()) {
  const payload = b64url(enc.encode(JSON.stringify({ u: user, iat: Math.floor(now / 1000), v: 1 })));
  return `${payload}.${await sign(env, password, payload)}`;
}

/** The user a device token belongs to, or null. */
export async function verify(env, token) {
  const [payload, sig] = String(token || "").split(".");
  if (!payload || !sig) return null;
  let claims;
  try { claims = JSON.parse(new TextDecoder().decode(unb64url(payload))); } catch { return null; }
  const password = users(env).get(String(claims.u || "").toLowerCase());
  if (!password) return null;
  return same(await sign(env, password, payload), sig) ? claims.u : null;
}

async function blizzardToken(env, fetcher = fetch, now = Date.now()) {
  if (cached && now < cached.until) return cached;
  const r = await fetcher(TOKEN_URL, {
    method: "POST",
    headers: { authorization: "Basic " + btoa(`${env.BLIZZARD_CLIENT_ID}:${env.BLIZZARD_CLIENT_SECRET}`),
      "content-type": "application/x-www-form-urlencoded" },
    body: "grant_type=client_credentials",
  });
  if (!r.ok) throw new Error(`Blizzard answered HTTP ${r.status}`);
  const body = await r.json();
  const life = Number(body.expires_in || 3600);
  cached = { token: body.access_token, until: now + (life - 300) * 1000 };
  return cached;
}

export function resetCache() { cached = null; }

export async function handle(request, env, fetcher = fetch) {
  const url = new URL(request.url);
  if (request.method === "GET" && url.pathname === "/health") return json({ ok: true });
  if (!env.BLIZZARD_CLIENT_ID || !env.BLIZZARD_CLIENT_SECRET) return json({ error: "The server has no Blizzard keys yet." }, 503);

  if (request.method === "POST" && url.pathname === "/login") {
    let body;
    try { body = await request.json(); } catch { return json({ error: "Send a user and password." }, 400); }
    const user = String(body.user || "").trim().toLowerCase();
    const want = users(env).get(user);
    if (!want || !same(want, body.password || "")) {
      await new Promise((r) => setTimeout(r, 500)); // slow down guessing
      return json({ error: "That user name or password is wrong." }, 401);
    }
    return json({ device_token: await issue(env, user, want), user });
  }

  if (request.method === "POST" && url.pathname === "/token") {
    const auth = request.headers.get("authorization") || "";
    const user = await verify(env, auth.replace(/^Bearer\s+/i, ""));
    if (!user) return json({ error: "Signed out. Log in again in the app." }, 401);
    try {
      const t = await blizzardToken(env, fetcher);
      return json({ access_token: t.token, expires_in: Math.max(60, Math.floor((t.until - Date.now()) / 1000)) });
    } catch (e) {
      return json({ error: String(e.message || e) }, 502);
    }
  }
  return json({ error: "Not found" }, 404);
}

export default { fetch: (request, env) => handle(request, env) };
