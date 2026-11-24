"""Loads AuctionIQ the way WoW: Forever does (AuctionIQ_Camelot.toc, WOW_PROJECT_ID 18) and checks
that the Forever build starts, detects the game and opens its window without errors.
Run: python3 tests/forever_tests.py   (needs `pip install lupa`)"""
import sys
abs = abs
from pathlib import Path

try:
    from lupa.lua51 import LuaRuntime
except ImportError:
    from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
toc = (ROOT / "AuctionIQ_Camelot.toc").read_text().splitlines()
files = [l.strip().replace("\\", "/") for l in toc if l.strip().endswith(".lua")]
L = LuaRuntime(unpack_returned_tuples=True)
L.execute((ROOT / "tests" / "wow_stub.lua").read_text())
L.execute("WOW_PROJECT_ID = 18; WOW_PROJECT_MAINLINE = 1")
ns = L.table()
for f in files:
    chunk = L.eval("function(src, name) return assert(loadstring(src, name)) end")((ROOT / f).read_text(), f)
    chunk("AuctionIQ", ns)

fails = []
def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)

run = L.execute
check("interface 16001 in the Forever TOC", "## Interface: 16001" in toc)
check("no retail-only files in the Forever TOC",
      not any(x in f for f in files for x in ("Orders.lua", "Concentration", "Spec", "Professions/")))
check("every file in the Forever TOC exists", all((ROOT / f).exists() for f in files))
run('STUB.Fire("ADDON_LOADED", "AuctionIQ"); STUB.Fire("PLAYER_LOGIN")')
A0 = L.globals().AuctionIQ
check("saved data reaches the current version without the retail modules", A0.db.version == A0.DB_VERSION)
A = L.globals().AuctionIQ
check("game detected as forever", A.Game == "forever" and A.IsForever() and not A.IsRetail())
check("other project IDs", (A.DetectGame(1), A.DetectGame(18), A.DetectGame(5)) == ("retail", "forever", "other"))
check("saved data set up", A.db is not None and A.db.settings is not None)
tabs = [A.Shell.Tabs()[i][2] for i in range(1, len(A.Shell.Tabs()) + 1)]
check("Forever tabs are Craft and Analytics", tabs == ["Craft", "Analytics"])
rt = A.Shell.Tabs("retail")
check("retail tabs add Work Orders in the middle", [rt[i][2] for i in range(1, len(rt) + 1)] == ["Craft", "Work Orders", "Analytics"])
run('SlashCmdList.AUCTIONIQ("")')
check("/aiq opens the window on Craft", A.Shell.IsShown() and A.Shell.current == "craft")
run('SlashCmdList.AUCTIONIQ("sales")')
check("/aiq sales opens Analytics", A.Shell.current == "analytics")
run('SlashCmdList.AUCTIONIQ("orders")')
check("/aiq orders isn't a Forever tab", A.Shell.current == "analytics")
run('SlashCmdList.AUCTIONIQ("")')
check("/aiq again closes it", not A.Shell.IsShown())
run('SlashCmdList.AUCTIONIQ("scan")')
check("an older command doesn't error on Forever", True)
run('AuctionIQ_OnAddonCompartmentClick()')
check("the addon compartment opens it", A.Shell.IsShown())

# realm: Forever answers the ruleset name at load, then an empty string
check("realm read at load is kept when GetRealmName goes blank", (run('GetRealmName = function() return "" end') or True) and A.RealmName() == "Emerald Dream")
run('AuctionIQ.db.characters = { ["Seyko-"] = { name = "Seyko", realm = "", gold = 5 } }')
me = A.Me()
check("a record saved under a blank realm moves to the right key",
      A.db.characters["Seyko-Emerald Dream"] is not None and A.db.characters["Seyko-"] is None and me.gold == 5 and me.realm == "Emerald Dream")

# sortable tables
rows = L.eval("""{ { name = "B", profit = 5 }, { name = "A", profit = 9 }, { name = "C", profit = 5 },
  { name = "X", profit = 99, last = true }, { name = "D" } }""")
A.Table.Sort(rows, "profit", "desc")
check("sort desc, ties by name, missing values after, pinned rows last",
      [rows[i].name for i in range(1, 6)] == ["A", "B", "C", "D", "X"])
A.Table.Sort(rows, "profit", "asc")
check("sort asc keeps missing values after and pinned rows last",
      [rows[i].name for i in range(1, 6)] == ["B", "C", "A", "D", "X"])
cols = L.eval("""{ { key = "name", label = "Item", width = 200, default = "asc" },
  { key = "profit", label = "Profit", width = 80, align = "RIGHT" } }""")
w = A.Table.New(L.globals().UIParent, "winners", cols, L.eval('{ "profit", "desc" }'))
lo = A.Table.New(L.globals().UIParent, "losers", cols, L.eval('{ "profit", "desc" }'))
A.Table.Link(w, lo)
A.Table.SetRows(w, L.eval('{ { name = "a", profit = 1 }, { name = "b", profit = 3 } }'), 10)
A.Table.SetRows(lo, L.eval('{ { name = "c", profit = -1 }, { name = "d", profit = -3 } }'), 10)
check("table starts on its default sort", w.rows[1].name == "b" and w.heads[2].text.t.endswith("\u25bc"))
A.Table.Click(w, "name")
check("a header click sorts linked tables together, in the column's default direction",
      w.rows[1].name == "a" and lo.rows[1].name == "c" and lo.sort[1] == "name" and lo.sort[2] == "asc")
A.Table.Click(lo, "name")
check("clicking the same header again flips both", w.rows[1].name == "b" and lo.rows[1].name == "d")
check("the sort is saved per table", A.db.settings.sort.winners[2] == "desc" and A.db.settings.sort.losers[1] == "name")

# header badge and settings
check("badge says Vendor without TSM or Oribos Exchange", (run("TSM_API = nil; OEMarketInfo = nil") or True) and A.Sources.Active().key == "vendor")
run("OEMarketInfo = function() end")
check("Oribos Exchange is next", A.Sources.Active().key == "oe")
run('TSM_API = { GetCustomPriceValue = function(src, item) return nil end }')
check("TSM without market data falls to Oribos Exchange", A.Sources.Active().key == "oe")
run('TSM_API = { GetCustomPriceValue = function(src, item) if src == "DBMarket" then return 1000 end end }')
check("TSM with market data is the source", A.Sources.Active().key == "tsm" and A.Sources.Active().ok)
run('SlashCmdList.AUCTIONIQ("settings")')
check("/aiq settings opens Settings on General", A.Shell.settings.IsShown and A.Shell.settingsPage == "General")
run('AuctionIQ.Shell.OpenSettings("About")')
check("Settings pages switch", A.Shell.settingsPage == "About")

# prices and costs (Data/Value.lua)
run("""
P = { dbmarket = { [1] = 500 }, dbregionmarketavg = { [2] = 400 }, smartavgbuy = { [1] = 300 },
      crafting = { [5] = 700 }, dbregionsalerate = { [1] = 0.42 } }
TSM_API = { GetCustomPriceValue = function(src, item) local id = tonumber(item:match("i:(%d+)")); return P[src] and P[src][id] end,
            ToItemString = function(i) return i end, IsCustomPriceValid = function() return false end }
OE = { [3] = { market = 250 } }
OEMarketInfo = function(item, t) local id = tonumber(item:match("item:(%d+)")); local r = OE[id]; if r then t.market = r.market; t.region = r.region end; return t end
Auctionator = { API = { v1 = { GetAuctionPriceByItemID = function(_, id) if id == 4 then return 150 end end } } }
C_Item.GetItemInfo = function(id) if id == 6 or id == 1 then return "x", nil, nil, nil, nil, nil, nil, nil, nil, nil, 25 end end
AuctionIQ.Prices.ClearCache()
""")
V = A.Value
def mk(i): return V.Market(i)
check("market: TSM realm, then TSM region", mk(1) == (500, "tsm") and mk(2) == (400, "tsm"))
check("market: then Oribos Exchange, Auctionator, vendor", mk(3) == (250, "oe") and mk(4) == (150, "auctionator") and mk(6) == (25, "vendor"))
check("market: nothing known is nil", mk(99) is None)
check("market: takes item strings and links", mk("i:1")[0] == 500 and mk("|cff|Hitem:1::|h[x]|h|r")[0] == 500)
check("sale rate from TSM", V.SaleRate(1) == 0.42 and V.SaleRate(3) is None)
check("paid: SmartAvgBuy, then crafting cost, then farmed at market",
      V.Paid(1) == (300, "bought") and V.Paid(5) == (700, "crafted") and V.Paid(3) == (250, "farmed"))
A.db.settings.costs.farmedAt = "zero"
check("paid: farmed at zero when Settings says so", V.Paid(3) == (0, "farmed"))
A.db.settings.costs.farmedAt = "market"
total, cov = V.Coverage(L.eval("{ { item = 1, qty = 2 }, { item = 5, qty = 1 }, { item = 3, qty = 4 } }"))
check("coverage: share of paid value from real buys and crafts", total == 600 + 700 + 1000 and abs(cov - 1300 / 2300) < 1e-9)
check("coverage of nothing is full", V.Coverage(L.eval("{}"))[1] == 1)

run("""
TradeSkillMasterDB = {
  _currentProfile = { ["Seyko - Emerald Dream"] = "Main" },
  ["p@Main@userData@items"] = { ["i:1"] = "Potions`Flasks", ["i:2"] = "Potions", ["i:3"] = "Herbs" },
  ["p@Main@userData@groups"] = {
    [""] = { Crafting = { "#Default", override = true } },
    ["Potions"] = { Crafting = { "Pots", override = true } },
    ["Potions`Flasks"] = { Crafting = { override = false } },
    ["Herbs"] = { Crafting = { override = false } } },
  ["p@Main@userData@operations"] = { Crafting = { Pots = { minRestock = "5", maxRestock = "40" } } },
  ["g@ @userData@sharedOperations"] = { Crafting = { ["#Default"] = { minRestock = "10", maxRestock = "20" } } },
}
""")
r1, r2, r3 = V.Restock(1), V.Restock(2), V.Restock(3)
check("restock: a subgroup inherits its parent's Crafting operation", r1 is not None and r1.max == 40 and r1.min == 5 and r1.op == "Pots" and r1.group == "Potions`Flasks")
check("restock: the group's own operation", r2 is not None and r2.max == 40)
check("restock: falls through to the base group's shared operation", r3 is not None and r3.max == 20 and r3.op == "#Default")
check("restock: an item in no group has none", V.Restock(4) is None)
run('TradeSkillMasterDB["g@ @userData@sharedOperations"].Crafting["#Default"].maxRestock = "dbmarket"')
check("restock: a max that isn't a number is treated as unknown", V.Restock(3) is None)
run("TradeSkillMasterDB = 5")
check("restock: unreadable TSM settings answer nil", V.Restock(1) is None)

# saved data: version read before defaults, backup, newer-save guard (R-05, R-06)
run("STUB_PRINTS = {}; local p = AuctionIQ.Print; AuctionIQ.Print = function(m) table.insert(STUB_PRINTS, m) end")
raw, db = A.Load(L.eval("{ mail = { x = 1 }, ledger = { days = { 1 } } }"))
check("an unversioned save runs every step from 2", raw.mail is None and raw.version == A.DB_VERSION)
check("the keys the steps touch are backed up first", raw.backup is not None and raw.backup["from"] == 1 and raw.backup.data.mail.x == 1)
check("defaults fill in after migrating", db.settings is not None and db.settings.costs.farmedAt == "market")
raw, db = A.Load(None)
check("a new save starts at the current version with nothing to migrate", raw.version == A.DB_VERSION and raw.backup is None)
raw, db = A.Load(L.eval("{ version = 99, keep = { 1 } }"))
check("a save from a newer AuctionIQ opens read-only", A.readOnly == 99 and raw.settings is None and db.settings is not None and raw.version == 99)
run("AuctionIQ.MIGRATIONS[4] = function(db) db.mail = 'half'; error('boom') end; AuctionIQ.MIGRATION_KEYS[4] = { 'mail' }; AuctionIQ.DB_VERSION = 4")
raw, db = A.Load(L.eval("{ version = 3, mail = { kept = true } }"))
check("a step that fails puts the data back and says so", raw.mail.kept == True and raw.version == 3 and raw.migrationFailed is not None and raw.migrationFailed.to == 4)
run("AuctionIQ.MIGRATIONS[4] = nil; AuctionIQ.MIGRATION_KEYS[4] = nil; AuctionIQ.DB_VERSION = 3; AuctionIQ.readOnly = nil")

# character name: TSM's longer Forever name wins and old records move to it
run("""
UnitName = function() return "Auren" end
GetRealmName = function() return "Roleplay" end
TradeSkillMasterDB = { _currentProfile = { ["Auren Lightweaver - Roleplay"] = "Default", ["Aurelia - Roleplay"] = "Default" } }
AuctionIQ.db.characters = { ["Auren-"] = { gold = 5 } }
""")
check("the name matches TSM's, surname included", A.PlayerName() == "Auren Lightweaver" and A.CharacterKey() == "Auren Lightweaver-Roleplay")
me = A.Me()
check("a record saved under the first name moves to the full name", me.gold == 5 and A.db.characters["Auren-"] is None and me.name == "Auren Lightweaver")
run('TradeSkillMasterDB = nil')
check("without TSM the game's name is used", A.PlayerName() == "Auren")

# Craft: recipes (both readers), Market / Paid / Full, Make N, the tab
run("""
UnitName = function() return "Bram" end
GetRealmName = function() return "Roleplay" end
TradeSkillMasterDB = nil
AuctionIQ.db.characters = {}
STUB.money = 1000 * 10000
-- Classic-style profession: a header, the Thorium Greatsword (10 bars + 1 crystal), a cooldown
CLASSIC = {
  { "Weapons", "header" },
  { "Thorium Greatsword", "optimal", 1, link = "|Hitem:7001|h", made = { 1, 1 }, reagents = { { "Thorium Bar", 10, 7101 }, { "Arcane Crystal", 1, 7102 } } },
  { "Transmute: Arcanite", "medium", 0, link = "|Hitem:7002|h", made = { 1, 1 }, reagents = { { "Thorium Bar", 1, 7101 } }, cd = 3600 },
}
GetNumTradeSkills = function() return #CLASSIC end
GetTradeSkillInfo = function(i) local r = CLASSIC[i]; if r then return r[1], r[2], r[3] or 0, true end end
GetTradeSkillItemLink = function(i) return CLASSIC[i].link end
GetTradeSkillNumMade = function(i) return CLASSIC[i].made[1], CLASSIC[i].made[2] end
GetTradeSkillNumReagents = function(i) return #(CLASSIC[i].reagents or {}) end
GetTradeSkillReagentInfo = function(i, n) local g = CLASSIC[i].reagents[n]; return g[1], nil, g[2], 0 end
GetTradeSkillReagentItemLink = function(i, n) return "|Hitem:" .. CLASSIC[i].reagents[n][3] .. "|h" end
GetTradeSkillCooldown = function(i) return CLASSIC[i].cd end
GetTradeSkillLine = function() return "Blacksmithing", 295, 300 end
DoTradeSkill = function(i, n) STUB.didCraft = { i, n } end
C_TradeSkillUI.GetAllRecipeIDs = function() return {} end
-- prices: sword 247g market, bars 21g market / 18.5g paid, crystal 0 (farmed at market 0? no: priced)
P = { dbmarket = { [7001] = 2470000, [7101] = 210000, [7102] = 0 }, smartavgbuy = { [7101] = 185000 },
      dbregionsalerate = { [7001] = 0.5 } }
P.dbmarket[7102] = nil
OE = {}
Auctionator = nil
C_Item.GetItemInfo = function(id) if id == 7001 then return "Thorium Greatsword", nil, 4, nil, nil, nil, nil, nil, nil, nil, 100000 end end
AuctionIQ.Prices.ClearCache()
""")
R, C = A.Recipes, A.Craft
check("classic reader is used when the retail-style list is empty", R.Reader() == "classic")
p = R.Refresh()
check("classic: recipes read, headers skipped", p is not None and len(p.recipes) == 2 and p.name == "Blacksmithing" and p.skill == 295)
sw = p.recipes[1]
check("classic: output, reagents and makes", sw.item == 7001 and sw.makes == 1 and len(sw.reagents) == 2 and sw.reagents[1].qty == 10 and sw.canMake == 1)
check("classic: cooldown becomes a ready time", p.recipes[2].readyAt is not None and p.recipes[2].cooldown == 3600)
check("the profession is kept for this character", R.Get("Blacksmithing") is not None and list(R.Professions().values()) == ["Blacksmithing"])
c = C.Cost(sw)
check("unpriced reagent leaves the craft unpriced", not c.priced and c.missing == 1)
run("P.dbmarket[7102] = 0; P.dbmarket[7102] = nil; Auctionator = { API = { v1 = { GetAuctionPriceByItemID = function(_, id) if id == 7102 then return 100000 end end } } }; AuctionIQ.Prices.ClearCache()")
c = C.Cost(sw)
gross, cut = 2470000, 123500
deposit = round(100000 * 0.15 * 2)
check("all three columns take off the same cut and relist", c.priced and c.cut == cut and c.relist == deposit and c.fees == cut + deposit)
check("Market / Paid / Full differ only by reagent cost and payback",
      c.profit.market == gross - cut - deposit - (10 * 210000 + 100000)
      and c.profit.paid == gross - cut - deposit - (10 * 185000 + 100000)
      and c.profit.full == c.profit.paid)
check("coverage: bars bought, crystal farmed", abs(c.coverage - (1850000 / 1950000)) < 1e-9)
m = C.MakeN(sw, c)
check("Make N without history or groups: try 2, capped by what you can afford", m.n == 2 and m.reason == "sales")
run("STUB.money = 0")
m = C.MakeN(sw, c)
check("Make N: affordability sets it when gold runs out", m.n == 1 and m.reason == "afford" and "afford 1" in C.Reason(m, 1))
run("STUB.money = 1000 * 10000")
run("""TradeSkillMasterDB = { _currentProfile = { ["Bram - Roleplay"] = "Default" },
  ["p@Default@userData@items"] = { ["i:7001"] = "Swords" },
  ["p@Default@userData@groups"] = { [""] = { Crafting = { "#Default", override = true } } },
  ["g@ @userData@sharedOperations"] = { Crafting = { ["#Default"] = { minRestock = "10", maxRestock = "1" } } } }
STUB.bags[7001] = 0""")
m = C.MakeN(sw, c)
check("Make N: TSM restock sets it when the group's max is lowest", m.n == 1 and m.reason == "restock" and m.restock == 1 and "TSM restock 1" in C.Reason(m, 1))
run("STUB.bags[7001] = 3")
m = C.MakeN(sw, c)
check("Make N: 0 when already stocked", m.n == 0 and m.reason == "stocked")
run("TradeSkillMasterDB = nil; STUB.bags[7001] = 0; P.dbmarket[7001] = 150000; AuctionIQ.Prices.ClearCache()")
m = C.MakeN(sw)
check("Make N: 0 when it loses money", m.n == 0 and m.reason == "loss")
run("P.dbmarket[7001] = 2470000; AuctionIQ.Prices.ClearCache()")
two = L.eval("{ key = 'x', name = 'Two', item = 7001, makes = 2, reagents = { { item = 7101, qty = 1 } }, canMake = 0 }")
m2 = C.MakeN(two)
check("Make N counts crafts, items beside it", m2.n == 2 and m2["items"] == 4 and "try 2 crafts" in C.Reason(m2, 2))
check("payback: a recorded recipe cost spread over the setting's crafts",
      (run("AuctionIQ.db.settings.costs.recipeCost = { [\"cThorium Greatsword\"] = 200000 }") or True) and C.Cost(sw).payback == 4000 and C.Cost(sw).profit.full == C.Cost(sw).profit.paid - 4000)
run("AuctionIQ.db.settings.costs.recipeCost = nil")

UI = A.CraftUI
check("gold: whole gold, silver, signs", (UI.Gold(1850000), UI.Gold(420000, True), UI.Gold(-40000), UI.Gold(4500), UI.Gold(None)) == ("185g", "+42g", "\u221244g".replace("44", "4"), "45s", "\u2014"))
cds = L.eval("{ { name = 'Transmute: Arcanite', char = 'Alynna', readyAt = 100 }, { name = 'Mooncloth', char = 'Bram', readyAt = 100 + 6 * 3600 } }")
left, right = UI.StripText(cds, 3, 200)
check("strip: ready and coming cooldowns, items below restock", "Arcanite" in left and "ready" in left and "in 6h" in left and "3 items below restock" in right)
run('SlashCmdList.AUCTIONIQ("craft")')
pg = A.Shell.frame.pages.craft
check("the Craft tab builds and lists the recipes", len(pg.list.rows) == 2 and pg.list.rows[1].key == "cThorium Greatsword")
d = pg.detail
check("detail shows the three columns and Make N", d.make.t is not None and "Make 2" in d.make.t and "195g" in d.reagents.v[2].t and "220g" in d.reagents.v[1].t)
check("craft button needs the profession open", "Craft 1 of 2" in (pg.detail.button.text.t if pg.detail.button.text else ""))
run("AuctionIQ.CraftUI.CraftOne()")
run("AuctionIQ.CraftUI.ToggleHouse()")
check("the house switch moves every column to the 15% cut", A.Craft.Cut() == 0.15 and A.Craft.Cost(sw).cut == 370500 and "Neutral AH 15%" in pg.detail.house.text.t)
run("AuctionIQ.CraftUI.ToggleHouse()")
check("and back to 5%", A.Craft.Cut() == 0.05)
check("Craft crafts one through the Classic call", L.eval("STUB.didCraft")[1] == 2 and L.eval("STUB.didCraft")[2] == 1 and "Craft 2 of 2" in pg.detail.button.text.t)
run('STUB.Fire("TRADE_SKILL_CLOSE")')
run('SlashCmdList.AUCTIONIQ("craft")')
check("closing the profession keeps the recipes, the button says to open it", len(pg.list.rows) == 2 and "Open Blacksmithing" in pg.detail.button.text.t)

# retail-style reader on Forever, if its C_TradeSkillUI answers
run("""
GetNumTradeSkills = function() return 0 end
C_TradeSkillUI.GetAllRecipeIDs = function() return { 50 } end
C_TradeSkillUI.GetRecipeInfo = function(id) return { learned = true, name = "Mooncloth", numAvailable = 3 } end
C_TradeSkillUI.GetRecipeSchematic = function(id) return { outputItemID = 14342, quantityMin = 1, quantityMax = 1,
  reagentSlotSchematics = { { reagentType = 1, quantityRequired = 2, reagents = { { itemID = 14256 } } } } } end
C_TradeSkillUI.GetRecipeCooldown = function() return 86400 end
C_TradeSkillUI.GetBaseProfessionInfo = function() return { professionName = "Tailoring", skillLevel = 300, maxSkillLevel = 300 } end
""")
p2 = R.ReadOpen()
check("retail-style reader: recipe, reagents, cooldown, profession",
      p2 is not None and p2.reader == "modern" and p2.name == "Tailoring" and p2.recipes[1].item == 14342 and p2.recipes[1].reagents[1].qty == 2 and p2.recipes[1].cooldown == 86400)
run('STUB.Fire("TRADE_SKILL_SHOW"); STUB.RunTimers()')
probe = A.Recipes.Probe()
lines = list(A.Recipes.ProbeLines().values())
check("probe: records the reader, calls and events", probe.reader == "modern" and probe.calls["DoTradeSkill"] == True and probe.events.TRADE_SKILL_SHOW.n >= 1 and any("Tailoring" in l for l in lines))

print(f"\n{len(fails)} failed" if fails else "\nall Forever checks passed")
sys.exit(1 if fails else 0)
