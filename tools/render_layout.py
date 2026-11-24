"""Renders the Forever window from the addon's own frame layout, without a game client.

    python3 tools/render_layout.py out_dir          (needs lupa; node + playwright for PNGs)

Loads AuctionIQ_Camelot.toc under tests/wow_stub.lua, fills a demo Blacksmithing profession with
prices, opens the Craft tab and then Settings, and resolves every frame, texture and font string the
addon created (anchors, sizes, colours, text) into absolutely positioned HTML. Each scene is saved
as HTML and, when node and playwright are available, a PNG.

What this shows: the layout, sizes, anchoring, colours, text and what is shown or hidden, exactly as
the code sets them. What it can't show: the game's real fonts and their widths, textures and icons
(drawn as labelled boxes), ElvUI/ToxiUI skins, UI scale, and frame strata beyond draw order. It is a
check of the layout, not a screenshot of the game."""
import html
import re
import subprocess
import sys
from pathlib import Path

try:
    from lupa.lua51 import LuaRuntime
except ImportError:
    from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]

PATCH = r"""
local origCF = CreateFrame
local function patchTex(t)
  t.pts = {}
  t.SetPoint = function(s, ...) table.insert(s.pts, { ... }) end
  t.ClearAllPoints = function(s) s.pts = {} end
  t.SetAllPoints = function(s) s.fill = true end
  t.SetColorTexture = function(s, r, g, b, a) s.col = { r, g, b, a or 1 }; s.tex = nil end
  t.SetTexture = function(s, p) s.tex = p end
  t.SetGradient = function(s, o, a, b) s.grad = { a, b } end
  t.SetAlpha = function(s, a) s.alpha = a end
  t.IsShown = function(s) return s.shown end
  return t
end
local function patchFs(fs)
  fs.SetFont = function(s, path, size) s.size = size; s.bold = path and path:find("Black") or (path and path:find("Bold")) end
  fs.GetFont = function(s) return "font", s.size end
  fs.SetJustifyH = function(s, j) s.justify = j end
  fs.SetSize = function(s, w, h) s.w, s.fh = w, h end
  fs.SetAlpha = function(s, a) s.alpha = a end
  return fs
end
function PATCHFRAME(f)
  f.shown = true -- as in WoW, a new frame is shown until hidden
  f.SetBackdropColor = function(s, r, g, b, a) s.bg = { r, g, b, a or 1 } end
  f.SetBackdropBorderColor = function(s, r, g, b, a) s.bd = { r, g, b, a or 1 } end
  f.SetBackdrop = function(s, b) s.backdrop = b end
  f.SetAlpha = function(s, a) s.alpha = a end
  f.SetFrameStrata = function(s, v) s.strata = v end
  f.SetEnabled = function(s, v) s.enabled = v end
  f.SetNormalFontObject = function() end
  local oct, ocf = f.CreateTexture, f.CreateFontString
  f.CreateTexture = function(self, ...) return patchTex(oct(self, ...)) end
  f.CreateFontString = function(self, n, layer, font) return patchFs(ocf(self, n, layer, font)) end
  return f
end
CreateFrame = function(...) return PATCHFRAME(origCF(...)) end
PATCHFRAME(UIParent)
UIParent.w, UIParent.h = 1600, 900
UIParent.shown = true
CreateColor = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end
"""

RESOLVE = r"""
local FONT = { GameFontNormal = 12, GameFontHighlight = 12, GameFontNormalSmall = 10, GameFontHighlightSmall = 10 }
local GOLD = { GameFontNormal = true, GameFontNormalSmall = true }
local cache = {}
local function size(r)
  if rawget(r, "isText") then
    local sz = rawget(r, "size") or FONT[rawget(r, "font")] or 12
    local w = (rawget(r, "w") and rawget(r, "w") > 0) and rawget(r, "w") or (STUB.TextWidth and STUB.TextWidth(rawget(r, "t") or "", rawget(r, "font")) or 0)
    if not w or w == 0 then w = #((rawget(r, "t") or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) * sz * 0.55 end
    return w, rawget(r, "fh") or (sz + 2)
  end
  return rawget(r, "w") or 0, rawget(r, "h") or 0
end
local function parentOf(r) if rawget(r, "isText") or rawget(r, "isTex") then return rawget(r, "owner") end return rawget(r, "parent") end
local rect
local function anchor(rc, p)
  local l, b, w, h = rc[1], rc[2], rc[3], rc[4]
  local x = (p:find("LEFT") and l) or (p:find("RIGHT") and l + w) or (l + w / 2)
  local y = (p:find("TOP") and b + h) or (p:find("BOTTOM") and b) or (b + h / 2)
  return x, y
end
rect = function(r)
  if cache[r] then return cache[r] end
  if r == UIParent then cache[r] = { 0, 0, UIParent.w, UIParent.h }; return cache[r] end
  local par = parentOf(r) or UIParent
  if rawget(r, "fill") then cache[r] = rect(par); return cache[r] end
  local pts = rawget(r, "isTex") and rawget(r, "pts") or rawget(r, "points") or {}
  local w, h = size(r)
  local L, R, T, B, CX, CY
  for _, p in ipairs(pts) do
    local point, rel, relPoint, x, y = p[1], p[2], p[3], p[4], p[5]
    if type(rel) == "number" then x, y, rel, relPoint = rel, relPoint, nil, nil end
    if type(rel) == "string" then rel = _G[rel] end
    rel = rel or par
    relPoint = relPoint or point
    local ax, ay = anchor(rect(rel), relPoint)
    ax, ay = ax + (x or 0), ay + (y or 0)
    if point:find("LEFT") then L = ax elseif point:find("RIGHT") then R = ax else CX = ax end
    if point:find("TOP") then T = ay elseif point:find("BOTTOM") then B = ay else CY = ay end
  end
  if L and R then w = R - L end
  if T and B then h = T - B end
  local l = L or (R and R - w) or (CX and CX - w / 2) or 0
  local b = B or (T and T - h) or (CY and CY - h / 2) or 0
  cache[r] = { l, b, w, h }
  return cache[r]
end
local function visible(f)
  while f and f ~= UIParent do
    if not rawget(f, "shown") then return false end
    f = rawget(f, "parent")
  end
  return true
end
function DUMP(root)
  cache = {}
  local out = {}
  local function add(t) out[#out + 1] = t end
  local function walk(f)
    if not visible(f) then return end
    local rc = rect(f)
    if rawget(f, "bg") or rawget(f, "bd") then add({ kind = "frame", r = rc, bg = rawget(f, "bg"), bd = rawget(f, "bd"), alpha = rawget(f, "alpha") }) end
    for _, t in ipairs(rawget(f, "texs") or {}) do
      rawset(t, "isTex", true); rawset(t, "owner", f)
      if rawget(t, "shown") ~= false and (rawget(t, "col") or rawget(t, "tex")) then add({ kind = "tex", r = rect(t), col = rawget(t, "col"), grad = rawget(t, "grad"), tex = rawget(t, "tex"), alpha = rawget(t, "alpha") }) end
    end
    for _, s in ipairs(rawget(f, "texts") or {}) do
      rawset(s, "isText", true); rawset(s, "owner", f)
      if not rawget(s, "hidden") and rawget(s, "t") and rawget(s, "t") ~= "" and s ~= rawget(f, "TitleText") then
        local col = rawget(s, "color") or (GOLD[rawget(s, "font")] and { 1, 0.82, 0 }) or { 1, 1, 1 }
        add({ kind = "text", r = rect(s), t = rawget(s, "t"), size = rawget(s, "size") or FONT[rawget(s, "font")] or 12, col = col, justify = rawget(s, "justify"), bold = rawget(s, "bold"), wrap = rawget(s, "w") and rawget(s, "w") > 0, alpha = rawget(f, "alpha") })
      end
    end
    if type(rawget(f, "label")) == "string" and rawget(f, "label") ~= "" and not rawget(f, "text") then
      add({ kind = "text", r = rc, t = rawget(f, "label"), size = 12, col = { 1, 0.82, 0 }, justify = "CENTER" })
    end
    for _, k in ipairs(rawget(f, "kids") or {}) do walk(k) end
  end
  walk(root)
  return out
end
"""

DEMO = r"""
GetRealmName = function() return "Roleplay" end
UnitName = function() return "Auren" end
UnitClass = function() return "Paladin", "PALADIN" end
UnitFactionGroup = function() return "Alliance" end
STUB.money = 4200 * 10000
TradeSkillMasterDB = { _currentProfile = { ["Auren Lightweaver - Roleplay"] = "Default" } }
local R = {
  { 1, "Thorium Greatsword", 12784, { { 12359, 10 }, { 12363, 1 } }, 1 },
  { 2, "Dark Iron Plate", 11604, { { 11371, 20 }, { 7076, 2 } }, 0 },
  { 3, "Arcanite Reaper", 12784 + 1, { { 12360, 15 }, { 12644, 2 } }, 0 },
  { 4, "Thorium Belt", 12424, { { 12359, 4 } }, 4 },
  { 5, "Imperial Plate Belt", 12411, { { 12359, 6 }, { 11186, 2 } }, 2 },
  { 6, "Thorium Shield Spike", 12645, { { 12359, 4 }, { 7076, 4 } }, 1 },
}
local P = { dbmarket = { [12784] = 2470000, [11604] = 1600000, [12785] = 4100000, [12424] = 300000, [12411] = 420000, [12645] = 520000,
  [12359] = 210000, [12363] = 100000, [2589] = 1000, [11371] = 50000, [7076] = 120000, [12360] = 2400000, [12644] = 30000, [11186] = 60000 },
  smartavgbuy = { [12359] = 175000 }, dbregionsalerate = { [12784] = 0.22, [12424] = 0.4 } }
TSM_API = { GetCustomPriceValue = function(src, item) local id = tonumber(tostring(item):match("i:(%d+)")); return P[src:lower()] and P[src:lower()][id] end,
  ToItemString = function(i) return i end, IsCustomPriceValid = function() return true end }
local NAMES = { [12784] = "Thorium Greatsword", [11604] = "Dark Iron Plate", [12785] = "Arcanite Reaper", [12424] = "Thorium Belt", [12411] = "Imperial Plate Belt", [12645] = "Thorium Shield Spike",
  [12359] = "Thorium Bar", [12363] = "Arcane Crystal", [11371] = "Dark Iron Bar", [7076] = "Essence of Earth", [12360] = "Arcanite Bar", [12644] = "Dense Grinding Stone", [11186] = "Imperial Plate" }
local Q = { [12784] = 4, [11604] = 3, [12785] = 3, [12424] = 2, [12411] = 2, [12645] = 2 }
C_Item.GetItemInfo = function(id) return NAMES[id], nil, Q[id] or 1, nil, nil, nil, nil, nil, nil, nil, 10000 end
ITEM_QUALITY_COLORS = { [1] = { hex = "|cffffffff" }, [2] = { hex = "|cff1eff00" }, [3] = { hex = "|cff0070dd" }, [4] = { hex = "|cffa335ee" } }
C_TradeSkillUI.IsTradeSkillReady = function() return true end
C_TradeSkillUI.GetAllRecipeIDs = function() local t = {}; for _, r in ipairs(R) do t[#t + 1] = r[1] end; return t end
C_TradeSkillUI.GetRecipeInfo = function(id) local r = R[id]; return { learned = true, name = r[2], numAvailable = r[5] } end
C_TradeSkillUI.GetRecipeSchematic = function(id) local r = R[id]; local s = {}
  for _, g in ipairs(r[4]) do s[#s + 1] = { reagentType = 1, quantityRequired = g[2], reagents = { { itemID = g[1] } } } end
  return { outputItemID = r[3], quantityMin = 1, quantityMax = 1, reagentSlotSchematics = s } end
C_TradeSkillUI.GetRecipeCooldown = function() return 0 end
C_TradeSkillUI.GetBaseProfessionInfo = function() return { professionName = "Blacksmithing", skillLevel = 295, maxSkillLevel = 300 } end
GetNumTradeSkills = nil
STUB.Fire("ADDON_LOADED", "AuctionIQ"); STUB.Fire("PLAYER_LOGIN")
AuctionIQ.Prices.ClearCache()
AuctionIQ.Recipes.Refresh()
AuctionIQ.Recipes.open = "Blacksmithing"
local me = AuctionIQ.Me()
AuctionIQ.db.characters["Alynna-Roleplay"] = { name = "Alynna", crafting = { Alchemy = { recipes = { { name = "Transmute: Arcanite", readyAt = time() - 60 } } } } }
AuctionIQ.db.characters["Bram-Roleplay"] = { name = "Bram", crafting = { Tailoring = { recipes = { { name = "Mooncloth", readyAt = time() + 6 * 3600 } } } } }
"""


def color(c, alpha=None):
    if not c:
        return "transparent"
    r, g, b = (float(c[i]) for i in (1, 2, 3))
    a = float(c[4]) if 4 in c else 1
    if alpha is not None:
        a *= float(alpha)
    return f"rgba({round(r*255)},{round(g*255)},{round(b*255)},{a:.3f})"


def wow_text(t):
    out, i, stack = "", 0, 0
    t = html.escape(t).replace("\\n", "<br>")
    for m in re.finditer(r"\|c([0-9a-fA-F]{8})|\|r", t):
        out += t[i:m.start()]
        if m.group(1):
            out += f'<span style="color:#{m.group(1)[2:]}">'
            stack += 1
        elif stack:
            out += "</span>"
            stack -= 1
        i = m.end()
    return out + t[i:] + "</span>" * stack


def scene_html(items, H, title):
    divs = []
    minx = min(float(it.r[1]) for it in items)
    maxy = max(float(it.r[2]) + float(it.r[4]) for it in items)
    for it in items:
        l, b, w, h = (float(it.r[i]) for i in (1, 2, 3, 4))
        x, y = l - minx + 20, maxy - (b + h) + 20
        box = f"left:{x:.1f}px;top:{y:.1f}px;width:{max(w,0):.1f}px;height:{max(h,0):.1f}px"
        if it.kind == "frame":
            divs.append(f'<div style="position:absolute;{box};background:{color(it.bg, it.alpha)};box-shadow:inset 0 0 0 1px {color(it.bd) if it.bd else "transparent"}"></div>')
        elif it.kind == "tex":
            if it.tex:
                name = str(it.tex).split("\\")[-1]
                divs.append(f'<div title="{html.escape(name)}" style="position:absolute;{box};background:#555;opacity:{float(it.alpha or 1)};font:7px sans-serif;color:#ddd;overflow:hidden">{html.escape(name[:10])}</div>')
            else:
                bg = color(it.col, it.alpha)
                if it.grad:
                    a, c = it.grad[1], it.grad[2]
                    bg = f"linear-gradient(90deg, rgb({a.r*255:.0f},{a.g*255:.0f},{a.b*255:.0f}), rgb({c.r*255:.0f},{c.g*255:.0f},{c.b*255:.0f}))"
                divs.append(f'<div style="position:absolute;{box};background:{bg}"></div>')
        else:
            j = {"RIGHT": "right", "CENTER": "center"}.get(str(it.justify), "left")
            size = float(it.size)
            ws = "normal" if it.wrap else "nowrap"
            divs.append(f'<div style="position:absolute;{box};display:flex;align-items:center;justify-content:{ {"left":"flex-start","right":"flex-end","center":"center"}[j] };'
                        f'text-align:{j};font:{"700 " if it.bold else ""}{size:.0f}px/1.15 Arial,Helvetica,sans-serif;color:{color(it.col, it.alpha)};white-space:{ws};overflow:visible">'
                        f'<span>{wow_text(str(it.t))}</span></div>')
    return (f'<!doctype html><meta charset="utf-8"><title>{title}</title><body style="margin:0;background:#3a4450">'
            f'<div style="position:relative;width:1600px;height:{H}px">' + "\n".join(divs) + "</div></body>")


def main(out):
    out.mkdir(parents=True, exist_ok=True)
    toc = (ROOT / "AuctionIQ_Camelot.toc").read_text().splitlines()
    files = [l.strip().replace("\\", "/") for l in toc if l.strip().endswith(".lua")]
    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute((ROOT / "tests" / "wow_stub.lua").read_text())
    L.execute("WOW_PROJECT_ID = 18; WOW_PROJECT_MAINLINE = 1")
    L.execute(PATCH)
    ns = L.table()
    for f in files:
        L.eval("function(src, name) return assert(loadstring(src, name)) end")((ROOT / f).read_text(), f)("AuctionIQ", ns)
    L.execute(RESOLVE)
    L.execute(DEMO)
    scenes = {}
    L.execute('AuctionIQ.Shell.Show("craft"); AuctionIQ.CraftUI.Select("r1")')
    scenes["craft"] = L.eval("DUMP(AuctionIQ.Shell.frame)")
    L.execute('AuctionIQ.Shell.OpenSettings("General")')
    scenes["settings"] = L.eval("DUMP(AuctionIQSettings)")
    paths = []
    for name, items in scenes.items():
        items = [items[i] for i in range(1, len(items) + 1)]
        p = out / f"layout-{name}.html"
        p.write_text(scene_html(items, 700, f"AuctionIQ {name} layout"))
        paths.append(p)
    js = out / "shot.js"
    js.write_text("""const { chromium } = require('playwright');
(async () => { const b = await chromium.launch(); const pg = await b.newPage({ viewport: { width: 860, height: 600 }, deviceScaleFactor: 2 });
for (const f of process.argv.slice(2)) { await pg.goto('file://' + f); await pg.screenshot({ path: f.replace('.html', '.png') }); }
await b.close(); })();""")
    try:
        subprocess.run(["node", str(js), *map(str, paths)], check=True, cwd="/tmp")
    except Exception as e:  # no node or playwright: the HTML is still there
        print("no PNGs:", e)
    js.unlink()
    print("\n".join(str(p) for p in paths))


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "dist/layout"))
