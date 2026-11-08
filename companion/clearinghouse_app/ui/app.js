// Clearinghouse window. Talks to Python through window.pywebview.api (see api.py); every call
// returns {ok, ...} or {ok:false, error}. In a plain browser a small demo api stands in.
"use strict";
const $ = (id) => document.getElementById(id);
const CH = (window.CH = {});
let api, S = {}, moverSrc = "realm", picked = null, moverRows = [];

// formatting ------------------------------------------------------------------------------------
function money(c) {
  if (c == null) return "-";
  const g = Math.floor(c / 10000), s = Math.floor((c % 10000) / 100);
  if (g >= 100) return `<span class="gold-text">${g.toLocaleString()}g</span>`;
  if (g > 0) return `<span class="gold-text">${g}g</span> ${s}s`;
  return `${s}s ${c % 100}c`;
}
const pct = (x) => (x == null ? "-" : `<span class="${x >= 0 ? "up" : "down"}">${x >= 0 ? "+" : ""}${Math.round(x * 100)}%</span>`);
function ago(t, now) {
  if (!t) return "never";
  const d = Math.max(0, now - t);
  if (d < 90) return "just now";
  if (d < 3600) return `${Math.round(d / 60)} min ago`;
  if (d < 86400) return `${Math.round(d / 3600)} h ago`;
  return `${Math.round(d / 86400)} days ago`;
}
function until(t, now) {
  if (!t) return "-";
  const d = t - now;
  if (d <= 60) return "any moment";
  if (d < 3600) return `in ${Math.round(d / 60)} min`;
  return new Date(t * 1000).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

// pages -----------------------------------------------------------------------------------------
function show(page) {
  document.querySelectorAll(".nav").forEach((b) => b.classList.toggle("on", b.dataset.page === page));
  document.querySelectorAll(".page").forEach((p) => (p.hidden = p.id !== "page-" + page));
  if (page === "settings") fillSettings();
  if (page === "markets") loadMarkets();
}
document.querySelectorAll(".nav").forEach((b) => b.addEventListener("click", () => show(b.dataset.page)));

// overview --------------------------------------------------------------------------------------
CH.refresh = async function () {
  S = await api.state();
  $("setup").hidden = S.ready;
  if (!S.ready) setupStep();
  $("who").textContent = S.user ? `Logged in as ${S.user}` : "";
  $("ver").textContent = `Version ${S.version}`;
  $("realm-title").textContent = S.realm || "Overview";
  $("realm-sub").textContent = S.realm ? `${S.region.toUpperCase()} realm and region commodities` : "";
  const busy = S.status === "Syncing", bad = S.status === "Error";
  $("dot").className = "dot " + (busy || S.status === "Waiting" ? "busy" : bad ? "bad" : S.status === "Synced" ? "ok" : "");
  $("status").textContent = S.status;
  $("last").textContent = S.lastSync ? `· last sync ${ago(S.lastSync, S.now)}` : "";
  $("message").textContent = S.message || "";
  $("next").textContent = S.paused ? "paused" : until(S.nextSync, S.now);
  $("pause").textContent = S.paused ? "Resume" : "Pause";
  $("sync").disabled = busy;
  $("t-realm").textContent = S.realmItems.toLocaleString();
  $("t-comm").textContent = S.commodityItems.toLocaleString();
  $("t-days").textContent = S.days;
  $("t-game").textContent = S.wowFound ? "Writing to AddOns" : "WoW not found";
  $("t-game-hint").textContent = S.wowFound ? "AuctionIQ reads it at login or /reload" : "Set the folder in Settings";
  $("update").hidden = !S.update;
  if (S.update) $("update-ver").textContent = S.update.version;
  if (S.ready) loadMovers();
};

async function loadMovers() {
  const r = await api.movers(moverSrc);
  moverRows = r.ok ? r.rows : [];
  const body = $("movers").tBodies[0];
  body.innerHTML = moverRows.map((m) => `<tr data-item="${m.item}"><td>${esc(m.name)}</td><td class="num">${money(m.market)}</td>
    <td class="num">${money(m.avg7)}</td><td class="num">${pct(m.change7)}</td><td class="num">${(m.qty || 0).toLocaleString()}</td></tr>`).join("");
  $("movers-empty").hidden = moverRows.length > 0;
  body.querySelectorAll("tr").forEach((tr) => tr.addEventListener("click", () => { picked = { item: +tr.dataset.item, source: moverSrc }; show("markets"); }));
}
$("mover-src").addEventListener("click", (e) => {
  const b = e.target.closest("button"); if (!b) return;
  moverSrc = b.dataset.src;
  $("mover-src").querySelectorAll("button").forEach((x) => x.classList.toggle("on", x === b));
  loadMovers();
});
$("sync").addEventListener("click", async () => { $("sync").disabled = true; await api.sync_now(); setTimeout(CH.refresh, 400); });
$("pause").addEventListener("click", async () => { await api.toggle_pause(); CH.refresh(); });
$("update-go").addEventListener("click", async () => { $("update-go").disabled = true; $("update-go").textContent = "Downloading..."; await api.install_update(); });

// markets ---------------------------------------------------------------------------------------
async function loadMarkets() {
  const r = await api.movers(moverSrc);
  const rows = r.ok ? r.rows : [];
  if (!picked && rows.length) picked = { item: rows[0].item, source: moverSrc };
  const body = $("market-list").tBodies[0];
  body.innerHTML = rows.map((m) => `<tr data-item="${m.item}" class="${picked && picked.item === m.item ? "on" : ""}"><td>${esc(m.name)}</td>
    <td class="num">${money(m.market)}</td><td class="num">${pct(m.change7)}</td><td class="num">${m.vol30 == null ? "-" : Math.round(m.vol30 * 100) + "%/day"}</td></tr>`).join("");
  body.querySelectorAll("tr").forEach((tr) => tr.addEventListener("click", () => { picked = { item: +tr.dataset.item, source: moverSrc }; loadMarkets(); }));
  if (!picked) return;
  const name = (rows.find((m) => m.item === picked.item) || {}).name || `Item ${picked.item}`;
  $("chart-title").textContent = name;
  const h = await api.history(picked.item, picked.source);
  drawChart(h.ok ? h.points : []);
}

function drawChart(pts) {
  const el = $("chart");
  if (pts.length < 2) { el.innerHTML = `<div class="empty muted">Not enough history yet for a chart.</div>`; $("chart-sub").textContent = ""; return; }
  const W = 900, H = 280, L = 70, R = 16, T = 12, B = 28;
  const vals = pts.flatMap((p) => [p.market, p.min]);
  let lo = Math.min(...vals), hi = Math.max(...vals);
  const pad = (hi - lo) * 0.1 || hi * 0.1 || 1; lo = Math.max(0, lo - pad); hi += pad;
  const x = (i) => L + (i * (W - L - R)) / (pts.length - 1), y = (v) => T + (1 - (v - lo) / (hi - lo)) * (H - T - B);
  const path = (k) => pts.map((p, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(p[k]).toFixed(1)}`).join("");
  const ticks = [0, 0.5, 1].map((f) => lo + f * (hi - lo));
  const gold = (c) => (c >= 10000 ? `${Math.round(c / 10000).toLocaleString()}g` : `${Math.round(c / 100)}s`);
  el.innerHTML = `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" role="img" aria-label="Market price over time">
    <defs><linearGradient id="fade" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#e0a83a" stop-opacity=".28"/><stop offset="1" stop-color="#e0a83a" stop-opacity="0"/></linearGradient></defs>
    ${ticks.map((v) => `<line class="axis" x1="${L}" x2="${W - R}" y1="${y(v)}" y2="${y(v)}"/><text class="tick" x="${L - 8}" y="${y(v) + 4}" text-anchor="end">${gold(v)}</text>`).join("")}
    <path class="area" d="${path("market")}L${x(pts.length - 1)},${H - B}L${L},${H - B}Z"/>
    <path class="low" d="${path("min")}"/><path class="line" d="${path("market")}"/>
    <text class="tick" x="${L}" y="${H - 8}">${pts[0].day}</text><text class="tick" x="${W - R}" y="${H - 8}" text-anchor="end">${pts[pts.length - 1].day}</text></svg>`;
  $("chart-sub").innerHTML = `market <span class="gold-text">━</span> &nbsp; lowest listing <span style="color:var(--parch)">┅</span>`;
}

// settings --------------------------------------------------------------------------------------
async function realmList(region, listEl, input) {
  input.placeholder = "Loading realms...";
  const r = await api.realms(region);
  listEl.innerHTML = r.ok ? r.realms.map((n) => `<option value="${esc(n)}">`).join("") : "";
  input.placeholder = r.ok ? "Start typing your realm" : "Type your realm";
  return r;
}
function regions(sel, cur) { sel.innerHTML = S.regions.map((r) => `<option value="${r}" ${r === cur ? "selected" : ""}>${r.toUpperCase()}</option>`).join(""); }

function fillSettings() {
  $("s-user").textContent = S.user || "-";
  regions($("s-region"), S.region);
  $("s-realm").value = S.realm;
  realmList(S.region, $("s-realms"), $("s-realm"));
  $("s-wow").value = S.wowPath;
  $("s-wow-hint").textContent = S.wowFound ? `Writes to ${S.addonDir}` : "Couldn't find WoW. Paste the path to its _retail_ folder.";
  $("s-interval").value = S.interval;
  $("s-wait").checked = S.waitForWow;
  $("s-auto").checked = S.autostart;
  $("s-ver").textContent = `Clearinghouse ${S.version}`;
  $("s-error").textContent = "";
}
$("s-region").addEventListener("change", () => realmList($("s-region").value, $("s-realms"), $("s-realm")));
$("s-save").addEventListener("click", async () => {
  const r = await api.save({ region: $("s-region").value, realm: $("s-realm").value, wowPath: $("s-wow").value,
    interval: +$("s-interval").value, waitForWow: $("s-wait").checked, autostart: $("s-auto").checked });
  $("s-error").textContent = r.ok ? "" : r.error;
  if (r.ok) { await CH.refresh(); show("overview"); }
});
$("logout").addEventListener("click", async () => { await api.logout(); CH.refresh(); });
$("s-check").addEventListener("click", async () => {
  const r = await api.check_update();
  $("s-ver").textContent = !r.ok ? r.error : r.update ? `Version ${r.update.version} is available` : `Clearinghouse ${S.version} is up to date`;
  CH.refresh();
});
$("s-log").addEventListener("click", () => api.open_log());
$("s-quit").addEventListener("click", () => api.quit());

// first-run setup -------------------------------------------------------------------------------
function steps(n) { [1, 2, 3].forEach((i) => { $("st-" + i).className = i < n ? "done" : i === n ? "on" : ""; }); }
let wizardRealmsFor = null;
function setupStep() {
  const step = !S.signedIn ? 1 : !S.realm ? 2 : 3;
  steps(step);
  $("w-login").hidden = step !== 1;
  $("w-realm").hidden = step !== 2;
  $("w-done").hidden = step !== 3;
  if (step === 2 && wizardRealmsFor !== "init") {
    wizardRealmsFor = "init";
    regions($("w-region"), S.region);
    realmList(S.region, $("w-realms"), $("w-realm-in")).then((r) => { if (!r.ok) $("w-realm-error").textContent = r.error; });
    $("w-wow").textContent = S.wowFound ? `Found World of Warcraft at ${S.wowPath}` : "Couldn't find World of Warcraft. You can set its folder in Settings after this.";
  }
}
$("w-login").addEventListener("submit", async (e) => {
  e.preventDefault();
  $("w-login-go").disabled = true;
  const r = await api.login($("w-user").value, $("w-pass").value);
  $("w-login-go").disabled = false;
  $("w-login-error").textContent = r.ok ? "" : r.error;
  if (r.ok) { $("w-pass").value = ""; CH.refresh(); }
});
$("w-region").addEventListener("change", () => realmList($("w-region").value, $("w-realms"), $("w-realm-in")));
$("w-realm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const r = await api.save({ region: $("w-region").value, realm: $("w-realm-in").value });
  $("w-realm-error").textContent = r.ok ? "" : r.error;
  if (r.ok) { steps(3); $("w-realm").hidden = true; $("w-done").hidden = false; }
});
$("w-finish").addEventListener("click", () => { $("setup").hidden = true; CH.refresh(); });

// start -----------------------------------------------------------------------------------------
function start(a) { api = a; CH.refresh(); setInterval(CH.refresh, 30000); }
window.addEventListener("pywebviewready", () => start(window.pywebview.api));
setTimeout(() => { if (!api && !window.pywebview) start(demoApi()); }, 400);

// A stand-in for previewing the window in a browser. Never used inside the app.
function demoApi() {
  const now = Date.now() / 1000;
  const names = ["Algari Mana Potion", "Mycobloom", "Storm Dust", "Ironclaw Ore", "Charged Alexandrite", "Null Lotus", "Spark of Omens", "Bismuth"];
  const rows = names.map((n, i) => ({ item: 1000 + i, name: n, market: [182000, 45500, 9200, 37800, 1450000, 3920000, 812000, 52100][i],
    avg7: [151000, 52000, 8000, 33400, 1620000, 3300000, 905000, 50000][i], change7: [0.21, -0.13, 0.15, 0.13, -0.1, 0.19, -0.1, 0.04][i],
    qty: [4120, 88000, 120440, 15200, 310, 46, 1220, 39000][i], vol30: [0.06, 0.04, 0.09, 0.05, 0.12, 0.08, 0.07, 0.03][i] }));
  const state = { version: "0.2.0", ready: true, signedIn: true, user: "jason", region: "us", realm: "Emerald Dream", regions: ["us", "eu", "kr", "tw"],
    status: "Synced", message: "Updated realm, commodity.", lastSync: now - 720, nextSync: now + 2880, realmItems: 18342, commodityItems: 9127,
    days: 23, snapshots: 336, paused: false, interval: 60, waitForWow: false, autostart: true, wowPath: "C:\\Program Files (x86)\\World of Warcraft\\_retail_",
    wowFound: true, addonDir: "C:\\Program Files (x86)\\World of Warcraft\\_retail_\\Interface\\AddOns\\Clearinghouse", update: null, now };
  const hist = (item) => Array.from({ length: 30 }, (_, i) => { const r = rows.find((x) => x.item === item) || rows[0];
    const v = r.avg7 * (0.85 + 0.25 * Math.sin(i / 4) * 0.5 + i * 0.006); return { day: `2026-10-${String(i + 1).padStart(2, "0")}`, market: Math.round(v), min: Math.round(v * 0.9) }; });
  const ok = (x = {}) => Promise.resolve({ ok: true, ...x });
  return { state: () => Promise.resolve(location.hash === "#setup" ? { ...state, ready: false, signedIn: false } : state),
    movers: () => ok({ rows }), history: (i) => ok({ points: hist(i) }), realms: () => ok({ realms: ["Area 52", "Emerald Dream", "Illidan", "Stormrage"] }),
    login: () => ok(), logout: ok, save: ok, sync_now: ok, toggle_pause: ok, check_update: () => ok({ update: null }), install_update: ok, open_log: ok, quit: ok, hide: ok };
}
