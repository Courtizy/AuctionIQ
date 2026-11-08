import assert from "node:assert/strict";
import test from "node:test";
import { handle, issue, resetCache, users, verify } from "../worker.js";

const env = { BLIZZARD_CLIENT_ID: "id", BLIZZARD_CLIENT_SECRET: "secret", CH_USERS: "Jason:hunter22\nfriend:pw" };
const post = (path, body, headers = {}) => new Request("https://x" + path, { method: "POST", body: JSON.stringify(body), headers });

function fakeBlizzard() {
  const calls = [];
  const f = async (url, init) => { calls.push([url, init]); return new Response(JSON.stringify({ access_token: "tok", expires_in: 86399 })); };
  f.calls = calls;
  return f;
}

test("users parses name:password lines, names lower-cased", () => {
  assert.equal(users(env).get("jason"), "hunter22");
  assert.equal(users(env).get("friend"), "pw");
});

test("login gives a device token that verifies, wrong password does not", async () => {
  const ok = await handle(post("/login", { user: "JASON", password: "hunter22" }), env);
  assert.equal(ok.status, 200);
  const { device_token } = await ok.json();
  assert.equal(await verify(env, device_token), "jason");
  const bad = await handle(post("/login", { user: "jason", password: "nope" }), env);
  assert.equal(bad.status, 401);
});

test("changing the password signs old devices out", async () => {
  const t = await issue(env, "jason", "hunter22");
  assert.equal(await verify({ ...env, CH_USERS: "jason:newpass" }, t), null);
  assert.equal(await verify(env, t.replace(/.$/, (c) => (c === "A" ? "B" : "A"))), null);
});

test("token trades a device token for a cached Blizzard token", async () => {
  resetCache();
  const f = fakeBlizzard();
  const dev = await issue(env, "jason", "hunter22");
  const r = await handle(post("/token", {}, { authorization: "Bearer " + dev }), env, f);
  assert.equal(r.status, 200);
  const body = await r.json();
  assert.equal(body.access_token, "tok");
  assert.ok(body.expires_in > 80000);
  await handle(post("/token", {}, { authorization: "Bearer " + dev }), env, f);
  assert.equal(f.calls.length, 1);
  assert.match(f.calls[0][1].headers.authorization, /^Basic /);
});

test("token without a device token is refused and never calls Blizzard", async () => {
  resetCache();
  const f = fakeBlizzard();
  const r = await handle(post("/token", {}), env, f);
  assert.equal(r.status, 401);
  assert.equal(f.calls.length, 0);
});

test("no keys configured is a clear 503", async () => {
  const r = await handle(post("/login", { user: "jason", password: "hunter22" }), { CH_USERS: env.CH_USERS });
  assert.equal(r.status, 503);
});
