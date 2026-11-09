"""Loads the addon in a stubbed WoW environment (lupa) and checks its behaviour.
Run: python3 tests/run_tests.py   (needs `pip install lupa`)"""
import re
import sys
from pathlib import Path

from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
files = [l.strip().replace("\\", "/") for l in (ROOT / "AuctionIQ.toc").read_text().splitlines() if l.strip().endswith(".lua")]
L = LuaRuntime(unpack_returned_tuples=True)
L.execute((ROOT / "tests" / "wow_stub.lua").read_text())
ns = L.table()
for f in files:
    chunk = L.eval("function(src, name) return assert(loadstring and loadstring(src, name) or load(src, name)) end")((ROOT / f).read_text(), f)
    chunk("AuctionIQ", ns)

fails = []
def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)

run = L.execute
run('STUB.Fire("ADDON_LOADED", "AuctionIQ"); STUB.Fire("PLAYER_LOGIN")')
CH = L.globals().AuctionIQ
me = CH.db.characters["Seyko-Emerald Dream"]
check("gold recorded at login", me.gold == 1234567)

fm = lambda c: CH.FormatMoney(c, True)
COINS = {"Gold": "g", "Silver": "s", "Copper": "c"}
def letters(t): return re.sub(r"\|TInterface\\MoneyFrame\\UI-(Gold|Silver|Copper)Icon[^|]*\|t", lambda m: COINS[m.group(1)], t)
check("money format", (fm(123456789), fm(125000), fm(5000), fm(50), fm(-20000)) == ("12,345g", "12g 50s", "50s", "50c", "-2g"))

check("chvalue falls back to the formula when the custom source is missing", CH.Prices.Get("chvalue", "i:100") == 5000000)
check("craft profit = value after cut - crafting cost", CH.Prices.CraftProfit("i:100") == 5000000 * 0.95 - 1000000)
check("no price for unknown item", CH.Prices.Get("chvalue", "i:7") is None)

run('STUB.tooltipLink = "|cff|Hitem:100::|h[Potion]|h|r"; STUB.tooltipFn(GameTooltip)')
lines = [letters(l) for l in L.globals().GameTooltip.lines.values()]
check("money shows coin icons by default", "UI-GoldIcon" in CH.FormatMoney(125000) and "UI-SilverIcon" in CH.FormatMoney(125000))
run('AuctionIQ.db.settings.coins = false')
check("/ch coins setting gives g/s/c text", CH.FormatMoney(125000) == "12g 50s")
run('AuctionIQ.db.settings.coins = true')
check("tooltip shows value, buy now / post and profit",
      lines == ["AuctionIQ value=", "    Buy now (lowest listing)=450g", "    Post price=450g", "  Sale price=500g",
               "  AH cut (5%)=-25g", "  Value after cut=475g",
               "Values=", "  MV  Market Value=500g", "  EV  Estimated Value=475g", "Craft profit=375g"])
run('AuctionIQ.db.settings.tooltip = false; GameTooltip.lines = {}; STUB.tooltipFn(GameTooltip)')
check("tooltip can be turned off", len(list(L.globals().GameTooltip.lines.values())) == 0)

run('STUB.Fire("TRADE_SKILL_SHOW"); STUB.Fire("TRADE_SKILL_LIST_UPDATE"); STUB.RunTimers()')
p = me.professions[2906]
check("profession and Concentration recorded", p is not None and p.conc == 400 and p.concMax == 1000)
crafts = list(p.crafts.values())
check("best crafts: learned, priced, top quality only", len(crafts) == 1 and crafts[0].name == "Phoenix Oil" and crafts[0].itemID == 100)

run('STUB.now = STUB.now + 24 * 3600')  # a day later
check("Concentration refills about 250 a day", CH.ConcentrationNow(p)[0] == 650)
run('STUB.now = STUB.now + 48 * 3600')  # two more days
check("Concentration stops at its cap", CH.ConcentrationNow(p)[0] == 1000)
text = letters(CH.UI.BriefingText())
check("briefing lists gold, Concentration and the best craft",
      "123g" in text and "Midnight Enchanting  1000 / 1000" in re.sub(r"\|c\w{8}|\|r", "", text) and "Phoenix Oil" in text and "FULL" in text)

run('SlashCmdList.AUCTIONIQ("")')
check("/ch opens the window", CH.UI.IsShown())
run('SlashCmdList.AUCTIONIQ("")')
check("/ch again closes it", not CH.UI.IsShown())

btn = CH.CreateMinimapButton()
check("minimap button made at login", btn is not None and btn.shown)
run('AuctionIQ.CreateMinimapButton().scripts.OnClick()')
check("minimap button opens the window", CH.UI.IsShown())
run('local b = AuctionIQ.CreateMinimapButton(); b.scripts.OnDragStart(b); b.scripts.OnUpdate(b)')
check("dragging moves it round the minimap", abs(CH.db.settings.minimap.angle) < 0.001 and btn.point[4] == 75)
run('SlashCmdList.AUCTIONIQ("minimap")')
check("/ch minimap hides it", not btn.shown)

res = CH.Advisor.Analyze(10)
rows = list(CH.AdvisorUI.Render(res).values())
check("advisor: cheapest reagents for each quality", rows[0].startswith("Q1 plain cost=670000 profit=280000") and rows[2].startswith("Q2 plain cost=2120000 profit=730000"))
check("advisor: best profit without Concentration is Q2", "BEST" in rows[2] and "BEST" not in rows[0].replace("BESTCONC", ""))
check("advisor: Concentration value = profit / Concentration cost", "Q2 conc80" in rows[1] and "pp=27250" in rows[1] and rows[1].endswith("BESTCONC"))
check("advisor: no Concentration row when the quality is already top", len(rows) == 3)
check("advisor: picks the cheaper skill first", CH.Advisor.PicksText(res, res.best.picks).count("Q2") == 2)
def plain(t): return re.sub(r"\|c\w{8}|\|r", "", letters(str(t)))
best = res.best
rl = [(plain(l[1]), plain(l[2])) for l in CH.AdvisorUI.BreakdownLines(res, best, 3).values()]
check("reagent hover lists each reagent with rank, price each and total",
      ("4x item 202 Q2", "15g ea  60g") in rl and ("2x item 205", "1g ea  2g") in rl and rl[-1] == ("Total", "212g"))
sl = [(plain(l[1]), plain(l[2])) for l in CH.AdvisorUI.BreakdownLines(res, best, 4).values()]
check("sell hover shows realm and region prices", ("   MV  Market Value, realm", "300g") in sl and ("   Lowest listing, realm", "none") in sl and sl[-1] == ("After 5% auction cut", "285g"))
pl = [(plain(l[1]), plain(l[2])) for l in CH.AdvisorUI.BreakdownLines(res, best, 5).values()]
check("profit hover shows the sum and return", ("Less reagents", "-212g") in pl and ("Profit", "73g") in pl and ("Return on reagents", "34%") in pl)
mx = CH.Advisor.MaxCraftable(res, best)
check("max craftable is limited by the scarcest reagent", mx[0] == 1)  # 3 of item 205 at 2 each
mq = CH.Advisor.MaxCraftable(res, res.rows[2], 50)
check("with Concentration it is limited by points too", res.rows[2].concentration == 80 and mq[0] == 0)
ml = [(plain(l[1]), plain(l[2])) for l in CH.AdvisorUI.BreakdownLines(res, best, 7).values()]
check("max hover lists have and need", ("item 204 Q2", "12 have, 5 each") in ml)
run('AuctionIQ.db.settings.advisor.hide = false; STUB.Fire("TRADE_SKILL_SHOW")')
check("advisor panel shows with the profession window", CH.AdvisorUI.IsShown())
col = L.eval('function(x) local f = { GetLeft = function() return 0 end, GetEffectiveScale = function() return 1 end }; local g = GetCursorPosition; GetCursorPosition = function() return x, 0 end; local c = AuctionIQ.AdvisorUI.ColumnAt(f); GetCursorPosition = g; return c end')
check("row hover picks the column under the cursor", col(200) == 3 and col(250) == 4 and col(350) == 5 and col(500) == 7 and col(20) is None)
run('STUB.Fire("TRADE_SKILL_CLOSE")')
check("advisor panel hides with it", not CH.AdvisorUI.IsShown())

# Craft queue and shopping list
run('AuctionIQ.db.settings.advisor.hide = false; AuctionIQ.AdvisorUI.Show(10)')
run('AuctionIQ.AdvisorUI.RowClick(3)')            # Q2 without Concentration, one
run('STUB.shift = true; AuctionIQ.AdvisorUI.RowClick(3); STUB.shift = false')  # shift: as many as you can make (1)
run('AuctionIQ.AdvisorUI.RowClick(2)')            # Q1 reagents + Concentration
q = list(CH.db.queue.values())
check("queue: clicks add, the same craft stacks", len(q) == 2 and q[0].qty == 2 and q[0].quality == 2 and q[1].concentration == 80)
check("queue: Count adds up", CH.Queue.Count() == 3)
check("queueing from the advisor keeps you on the Advisor tab", CH.AdvisorUI.IsShown() and not CH.QueueUI.IsShown())
lines = CH.QueueUI.Show()
check("the Queue tab replaces the Advisor in the same spot", CH.QueueUI.IsShown() and not CH.AdvisorUI.IsShown() and CH.Window.Active() == "queue")
shop = list(lines.shop.values())
# 2x Q2 craft (4x202, 5x204, 2x205) + 1x conc craft (4x201, 5x203, 2x205)
check("shopping list: need across the queue, less what you have",
      "item 202 need=8 have=8 buy=0" in shop and "item 204 need=10 have=12 buy=0" in shop and "item 205 need=6 have=3 buy=3" in shop)
# Order book: buying a quantity walks up the listings (Data/Depth.lua)
D = CH.Depth
d = D.Cost(205, 3)
check("order book: with no listings seen, cost is chmat x quantity", d.cost == 30000 and d.source == "chmat")
run("AuctionIQ.Depth.Remember(205, { { price = 15000, qty = 5 }, { price = 10000, qty = 2 }, { price = 5000, qty = 9, mine = true } })")
d = D.Cost(205, 3)
check("order book: walks the AH search, cheapest first, skipping your own", d.cost == 2 * 10000 + 15000 and d.source == "ah" and d.short == 0 and d.first == 10000)
d = D.Cost(205, 10)
check("order book: past the listings it's short and priced at the top one", d.short == 3 and d.cost == 20000 + 5 * 15000 + 3 * 15000)
row = [r for r in CH.Queue.ShoppingList()[0].values() if r.itemID == 205][0]
check("shopping list prices the buy from the order book", row.buy == 3 and row.cost == 35000 and row.source == "ah")
tip = [plain(l) for l in CH.QueueUI.CostLines(row).values()]
check("shopping cost hover says how far above the cheapest", tip[0] == "Buying 3 costs 3g 50s" and "17% above the cheapest listing" in tip and tip[-1] == "From your AH search")
run("STUB.now = STUB.now + 16 * 60")
check("order book: an old AH search is dropped", D.Cost(205, 3).source == "chmat")
# a saved scan keeps a ladder after the live search expires
run("AuctionIQ.db.scans = {}; AuctionIQ.db.scans[205] = { at = STUB.now - 600, ladder = { { 1, 9000 }, { 10, 12000 }, { 50, 20000 } } }")
d = D.Cost(205, 30)
check("order book: between a saved scan's points the cost is a straight line", d.cost == 120000 + 880000 * 20 // 40 and d.source == "scan" and d.age == 600)
d = D.Cost(205, 60)
check("order book: past the saved book it's short at the last step's price", d.short == 10 and d.cost == 1000000 + 10 * 22000)
check("order book: slippage is the average over the cheapest", abs(D.Slippage(205, 30) - (560000 / 30 / 9000 - 1)) < 1e-9)
lad = [tuple(x.values()) for x in CH.Scans.Ladder(L.eval("{ { 100, 5 }, { 200, 8 }, { 300, 50 } }")).values()]
check("scan ladder: average to buy 1, 10, 50 and all listed", lad == [(1, 100), (10, 150), (50, 264), (63, 272)])
run("AuctionIQ.db.scans = {}; AuctionIQ.Depth.Forget()")
ok = CH.Queue.Craft(q[1], 1)
c = L.eval("STUB.crafted")
check("craft uses the queued reagents and Concentration", ok and c.id == 10 and c.conc == True and c.reagents[1].reagent.itemID == 201 and c.reagents[1].quantity == 4)
run('STUB.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 10)')
check("a finished craft comes off the queue", CH.Queue.Count() == 2 and len(list(CH.db.queue.values())) == 1)
run('AuctionIQ.Queue.Clear()')
check("clear empties it", CH.Queue.Count() == 0)

# ElvUI present: its colours, templates and skins are used
run('''ElvUI = { { media = { rgbvaluecolor = { 0.2, 0.4, 0.6 }, bordercolor = { 0, 0, 0 }, backdropfadecolor = { 0.06, 0.06, 0.06 }, backdropcolor = { 0.1, 0.1, 0.1 } },
  GetModule = function() return { HandleCloseButton = function(_, b) b.skinned = "close" end, HandleButton = function(_, b) b.skinned = "button" end } end } }
AuctionIQ.Theme.Sync()
STUB.p = CreateFrame("Frame"); AuctionIQ.Theme.Panel(STUB.p, "bg")
STUB.b = AuctionIQ.Theme.Button(STUB.p, "Dock"); STUB.x = AuctionIQ.Theme.Button(STUB.p, "x")''')
T = CH.Theme
check("ElvUI: our palette stays by default, on ElvUI's templates", T.hex.accent == "e0a83a" and T.hex.bg == "0e1729")
run("AuctionIQ.db.settings.theme = 'elvui'; AuctionIQ.Theme.Use('auctioniq')")
check("ElvUI: /aiq theme takes its value colour as the accent", T.hex.accent == "336699")
run("AuctionIQ.db.settings.theme = nil; AuctionIQ.Theme.Use('auctioniq')")
check("ElvUI: panels use its Transparent template", L.eval("STUB.p.template") == "Transparent")
check("ElvUI: buttons use its skins", L.eval("STUB.b.skinned") == "button" and L.eval("STUB.x.skinned") == "close")
run('ElvUI = nil')

# CraftSim parity: average profit with Multicraft and Resourcefulness, Ingenuity, finishing reagents
St = CH.Stats
check("multicraft: average extra items from the base yield", abs(St.MulticraftExtra(2, 0) - 2.33) < 1e-9 and abs(St.MulticraftExtra(1, 0.25) - 1.8125) < 1e-9)
check("concentration cost from the game's curve", St.ConcentrationCost(1, 100, 25, 0) == 100 and St.ConcentrationCost(1, 100, 25, 0.1) == 90)
pr = CH.Advisor.Analyze(11, L.eval('{ professionID = 2906 }'))
prow = list(pr.rows.values())
best = pr.best
check("average profit adds Multicraft extras and Resourcefulness savings",
      best.quality == 2 and best.cost == 260000 and abs(best.profit - (690000 + 0.35 * 2.33 * 475000 + 0.2 * 0.3 * 180000)) < 1)
check("finishing reagent picked per row: Multicraft one for the plain craft", [f.itemID for f in best.finishing.values()] == [222])
conc = pr.bestConc
check("skill finishing reagent picked for the Concentration craft, less Concentration",
      [f.itemID for f in conc.finishing.values()] == [221] and conc.concentration == 60 and conc.cost == 90000)
check("Ingenuity: average Concentration counts the refund", conc.avgConcentration == 51 and abs(conc.perPoint - conc.profit / 51) < 1e-6)
pl = [(plain(l[1]), plain(l[2])) for l in CH.AdvisorUI.BreakdownLines(pr, best, 5).values()]
check("profit hover shows the Multicraft and Resourcefulness parts",
      any(a.startswith("Multicraft  35% x 2.3 more") for a, _ in pl) and any(a.startswith("Resourcefulness  20% saves") for a, _ in pl))
cl = [plain(l[1]) for l in CH.AdvisorUI.BreakdownLines(pr, best, 3).values()]
check("reagent hover lists the finishing reagent", any("item 222" in c for c in cl))
fa = {a.itemID: a for a in CH.Advisor.FinishingAdvice(pr).values()}
check("finishing advice: every option with its gain, what you own and the verdict",
      set(fa) == {221, 222} and fa[221].own == 2 and fa[222].own == 0 and fa[222].picked and fa[222].verdict == "buy" and fa[222].gain > 0
      and "Multicraft" in fa[222].effect and "skill" in fa[221].effect)
fl = [plain(x) for x in CH.AdvisorUI.FinishingLines(pr).values()]
check("finishing advice in the advisor notes", any(x.startswith("Finishing: buy item 222") for x in fl) or any("Or buy: buy item 222" in x for x in fl))
run("STUB.prices['i:221'].formula_value = 10000; AuctionIQ.Prices.ClearCache()")   # you could sell yours for only 1g
pr2 = CH.Advisor.Analyze(11, L.eval('{ professionID = 2906 }'))
o221 = [o for opts in pr2.model.finishing.values() for o in opts.values() if o.itemID == 221][0]
check("finishing: one you own costs what you'd sell it for", o221.cost == 9500 and o221.buy == 30000)
run("STUB.prices['i:221'].formula_value = nil; AuctionIQ.Prices.ClearCache()")

# Gear with five qualities on one item ID (a rod): each quality priced at its item level
run("STUB.oldGII = C_Item.GetItemInfo; C_Item.GetItemInfo = function(id) if id == 320 then return 'Test Rod', nil, 3, 200 end return STUB.oldGII and STUB.oldGII(id) end")
rod = CH.Advisor.Analyze(12, L.eval('{ professionID = 2906 }'))
qs = sorted(set(r.quality for r in rod.rows.values() if not r.concentration))
check("gear: five qualities read from item level bonuses", rod.model.maxQ == 5 and rod.model.supportsQualities)
check("gear: better reagents reach a higher quality", qs[0] == 3 and qs[-1] == 5)
check("gear: each quality priced at its item level", rod.best.quality == 5 and rod.best.price == 160 * 10000)
check("gear: Concentration lifts one quality", any(r.concentration and r.quality == 4 and r['from'] == 3 for r in rod.rows.values()))
run("C_Item.GetItemInfo = STUB.oldGII")

# Simulation: more skill
m10 = CH.Advisor.Measure(10)
sim = CH.Advisor.Evaluate(m10, L.eval('{ sim = { skill = 30 } }'))
check("simulating +30 skill reaches Q2 with the cheapest reagents", sim.best.quality == 2 and sim.best.cost == 670000 and sim.best.profit == 2180000)
check("quality thresholds come from the game", m10.thresholds[2] == 130)

# Specialization: what ranks give, and a plan
run("""AuctionIQ.SpecData[2906] = { name = "Alchemy", recipes = { [10] = { 900, 9001 }, [11] = { 900, 9001, 901 } },
  nodes = { [900] = { nodeID = 900, maxRank = 20, base = true, stats = { skill = 1 } },
            [9001] = { nodeID = 900, maxRank = 1, stats = { multicraft = 50, additionalitemscraftedwithmulticraft = 25 } },
            [901] = { nodeID = 901, maxRank = 10, base = true, stats = { resourcefulness = 10 } } } }""")
run('STUB.Fire("TRAIT_NODE_CHANGED")')
tree = CH.Spec.Read(2906)
check("spec: tree read with ranks, perks and parents", tree.nodes[900].rank == 0 and tree.nodes[901].rank == -1 and tree.nodes[901].parent == 900
      and tree.nodes[900].perks[9001] == 10 and tree.unspent == 10)
ranks = L.eval("{ [900] = 12, [901] = 3 }")
d = CH.Spec.Delta(2906, tree, ranks, 11)
check("spec: delta for a recipe at other ranks", d.skill == 12 and d.multicraft == 50 and abs(d.mcExtra - 0.25) < 1e-9 and d.resourcefulness == 30)
check("goal text matches recipes by category", list(CH.Paths.Match("I want to sell potions")[0].values()) == [11]
      and list(CH.Paths.Match("flasks")[0].values()) == [10])
plan = CH.Paths.Plan(L.eval('{ goal = "flasks", points = 20, sync = true, prof = 2906 }'))
check("plan: puts points where the flask gains", plan.steps[1].name == "Node 900" and plan.final > plan.start and plan.budget == 30)
check("plan: describes itself in words", any("Node 900" in plain(l) for l in plan.text.values()) and "Goal:" in plain(plan.text[1]))
CH.AdvisorUI.SetPlan(plan)
CH.AdvisorUI.Show(10)
check("advisor simulates the plan", CH.AdvisorUI.Current().sim is not None)
run('AuctionIQ.AdvisorUI.SetPlan(nil); AuctionIQ.AdvisorUI.SetSimSkill(0)')
check("spec: the trees' layout is read per tab, with links",
      tree.tabs[1].name == "Test Mastery" and list(tree.tabs[1].nodes.values()) == [900, 901]
      and tree.layout[901].parent == 900 and tree.layout[901].y == 600 and tree.layout[901].rank == -1)
marks = CH.Paths.Marks(plan)
check("plan marks: each node's planned rank and steps", marks[900].to == max(s.to for s in plan.steps.values() if s.node == 900) and marks[900].steps[1] == 1)
CH.Paths.SetCurrent(plan)
saved = [v for v in L.eval("AuctionIQ.db.plans").values() if v.prof == 2906]
check("plan: a summary is saved for Research", len(saved) == 1 and saved[0].final == plan.final and len(list(saved[0].rows.values())) >= 1 and saved[0].steps[1].name == "Node 900")
prow, pfoot = L.eval("AuctionIQ.LedgerUI.Rows('plans', {})")
prow = list(prow.values())
check("plan comparison: each recipe now against planned, and the plan's gold a day", len(prow) >= 1 and ">" in plain(prow[0].cells[3]) and "a day" in plain(pfoot))
run('AuctionIQ.PathsUI.Open()')
drawn = list(CH.PathsUI.DrawTree().values())
check("paths: opens in the main window, Research > Professions > Paths", CH.PathsUI.IsShown() and CH.UI.Pages().paths.shown and CH.LedgerUI.View() == "paths")
check("paths: Professions lists Knowledge, Paths, Plan payoff",
      [CH.LedgerUI.ViewDef(v).label for v in ["professions", "paths", "plans"]] == ["Knowledge", "Paths", "Plan payoff"])
check("paths tab draws the tree with the plan on it",
      len(drawn) == 2 and drawn[0].planned and drawn[0].steps.startswith("1") and ">" in drawn[0].rank)
# Paths with the profession window closed: your professions from the game, the tree as you've spent it
run("""STUB.oldOpen = AuctionIQ.OpenProfessionID; AuctionIQ.OpenProfessionID = function() return nil end
function GetProfessions() return 1, 2 end
function GetProfessionInfo(i) if i == 1 then return "Alchemy", 0, 1, 1, 0, 0, 171 end return "Herbalism", 0, 1, 1, 0, 0, 182 end""")
profs = [(p.id, p.name) for p in CH.PathsUI.Professions().values()]
check("paths: reads your professions from the game, only ones with trees", profs == [(2906, "Alchemy")])
check("paths: shows a profession without its window open", CH.PathsUI.Prof() == 2906 and len(list(CH.PathsUI.Refresh().values())) == 2)
run('AuctionIQ.PathsUI.Run("potions")')
check("paths: planning asks for the profession window", "Open Alchemy" in plain(CH.PathsUI.Text()))
run("AuctionIQ.OpenProfessionID = STUB.oldOpen; GetProfessions = nil; GetProfessionInfo = nil")
groups = list(CH.Paths.GoalGroups(2906).values())
check("paths picker: recipes in main groups", [g.name for g in groups] == ["Potions", "Flasks & Phials", "Oils", "Other"])
check("paths picker: each profession has its own groups", L.eval('AuctionIQ.Paths.MainGroup("Weapon Enchants", 2909)') == "Enchants"
      and L.eval('AuctionIQ.Paths.MainGroup("Armor Kits", 2915)') == "Armor Kits" and L.eval('AuctionIQ.Paths.MainGroup("Leather Armor", 2915)') == "Armor"
      and L.eval('AuctionIQ.Paths.MainGroup("Appendix II - Stats", 2913)') is None and L.eval('AuctionIQ.Paths.MainGroup("Powerful Peridots", 2914)') == "Gems")
# Disenchanting: a gathering path, valued by the share of rank 2 materials
run("""STUB.oldTree = AuctionIQ.Spec.Tree
AuctionIQ.SpecData[2909] = { name = "Enchanting", recipes = {}, nodes = {
  [107649] = { nodeID = 107649, maxRank = 10, base = true, stats = { gatherskill = 1 } },
  [107648] = { nodeID = 107648, maxRank = 10, base = true, stats = { gatherskill = 1 } },
  [107647] = { nodeID = 107647, maxRank = 10, base = true, stats = { gatherskill = 1 } },
  [107646] = { nodeID = 107646, maxRank = 10, base = true, stats = { gatherskill = 1 } },
  [107634] = { nodeID = 107648, maxRank = 1, unlock = 5, stats = {}, text = "You have a chance to create more Eversinging Dust." } } }
AuctionIQ.Spec.Tree = function(prof) if prof ~= 2909 then return STUB.oldTree(prof) end
  return { unspent = 10, nodes = { [107649] = { name = "Disenchanting Delegate", rank = 0, max = 10, perks = {}, available = true },
    [107648] = { name = "Dust Deliverer", rank = 0, max = 10, perks = { [107634] = 5 }, parent = 107649 },
    [107647] = { name = "Shard Supplier", rank = -1, max = 10, perks = {}, parent = 107649 },
    [107646] = { name = "Crystal Collector", rank = -1, max = 10, perks = {}, parent = 107649 } } } end
STUB.prices['i:243599'] = { formula_value = 10000 }; STUB.prices['i:243600'] = { formula_value = 30000 }
AuctionIQ.Prices.ClearCache()""")
check("disenchanting: a goal for Enchanting", L.eval('(AuctionIQ.Paths.Yield(2909, "disenchanting"))') is not None
      and L.eval('(AuctionIQ.Paths.Yield(2906, "disenchanting"))') is None and L.eval('(AuctionIQ.Paths.Yield(2909, "potions"))') is None)
check("disenchanting: in the Enchanting picker", any(g.name == "Disenchanting" and g["yield"] for g in CH.Paths.GoalGroups(2909).values()))
dp = CH.Paths.Plan(L.eval('{ goal = "disenchanting", points = 0, sync = true, prof = 2909 }'))
check("disenchanting: plan puts points into dust when only dust sells", dp.steps[1].name in ("Disenchanting Delegate", "Dust Deliverer")
      and dp.final > dp.start and all(s.name not in ("Shard Supplier", "Crystal Collector") for s in dp.steps.values()))
check("disenchanting: describes the rank 2 share and the perk", any("rank 2 share" in plain(l) for l in dp.text.values())
      and any("more Eversinging Dust" in plain(l) for l in dp.text.values()))
check("disenchanting: default points finish its paths", CH.Paths.PathCost(2909, L.eval("{}"), "disenchanting") == 42)
# Disenchanting: what you really loot from items is recorded and used instead of the guess
check("disenchanting: a starting guess before anything is seen", L.eval("(select(2, AuctionIQ.Paths.DailyYield(2909)))") == "guess")
run("""local loot = { { "item:243599", 3, "Item-1-2-3" }, { "item:243600", 1, "Item-1-2-3" }, { "item:243600", 5, "Creature-0-1" } }
GetNumLootItems = function() return #loot end
GetLootSlotLink = function(i) return loot[i][1] end
GetLootSlotInfo = function(i) return nil, nil, loot[i][2] end
GetLootSourceInfo = function(i) return loot[i][3], 1 end
AuctionIQ.Paths.RecordLoot(86400 * 100)""")
ob = L.eval("(AuctionIQ.Paths.Observed(2909, 86400 * 100))")
check("disenchanting: only loot out of items counts", ob.dust.n == 4 and abs(ob.dust.share - 0.25) < 1e-9 and ob.shard.n == 0)
run("STUB.realTime = time; time = function() return 86400 * 100 end")
check("disenchanting: plans use what was really disenchanted", L.eval("(select(2, AuctionIQ.Paths.DailyYield(2909)))") == "seen")
dp2 = CH.Paths.Plan(L.eval('{ goal = "disenchanting", points = 0, sync = true, prof = 2909 }'))
check("disenchanting: the plan starts from your real rank 2 share", any("you really got (Eversinging Dust 25%)" in plain(l) for l in dp2.text.values())
      and dp2.startPer.dust.share == 0.25)
run("AuctionIQ.Paths.SetDailyYield(2909, { dust = 10, shard = 1, crystal = 0 })")
check("disenchanting: /aiq de by hand wins", L.eval("(select(2, AuctionIQ.Paths.DailyYield(2909)))") == "set")
run("AuctionIQ.Paths.SetDailyYield(2909, nil); time = STUB.realTime; GetNumLootItems = nil")
run("AuctionIQ.Spec.Tree = STUB.oldTree")
cost = CH.Paths.PathCost(2906, L.eval("{ 10 }"))
check("paths: default points finish the path for the goal", cost > 0 and CH.Paths.PathCost(2906, L.eval("{ }")) == 0)
run('AuctionIQ.PathsUI.Pick("Flasks & Phials", { 10 })')
check("picking a group plans it", CH.PathsUI.DefaultPoints(L.eval("{ 10 }")) == max(0, cost - CH.Spec.Tree(2906).unspent))
run("""STUB.btn = CreateFrame("Button"); STUB.btn:Show()
ProfessionsFrame = CreateFrame("Frame"); ProfessionsFrame.SpecPage = CreateFrame("Frame"); ProfessionsFrame.SpecPage:Show()
function ProfessionsFrame.SpecPage:GetTalentButtonByNodeID(id) return id == 900 and STUB.btn or nil end""")
check("game's spec tab gets a badge on each planned node", CH.SpecOverlay.Refresh() == 1)
run('AuctionIQ.Paths.ClearCurrent(2906)')
check("clearing the plan takes the badges off", CH.SpecOverlay.Refresh() == 0)
run('ProfessionsFrame = nil; AuctionIQ.PathsUI.Toggle()')

# Top gear
c = CH.Gear.Candidates()
check("gear: worn and bag items found", len(list(c.tools.values())) == 2 and len(list(c.gear.values())) == 2)
g = CH.Gear.Best(m10, None, c)
check("gear: the better tool wins for the flask", g.set is not None and g.gain > 0 and "404" in CH.Gear.SwapText(g.set))
CH.Gear.Equip(g.set, c)
check("gear: equip puts the bag tool in the tool slot", L.eval("STUB.equipped[20]") == "item:404")

# Crafting orders
o = CH.Orders.Analyze(L.eval("""{ orderID = 77, spellID = 10, minQuality = 2, tipAmount = 1000000, consortiumCut = 100000, customerName = "Bob",
  reagents = { { reagentInfo = { reagent = { itemID = 205 }, dataSlotIndex = 3, quantity = 2 } } } }"""))
orows = list(o.rows.values())
check("order: the customer's reagents aren't charged, the commission is the value",
      o.best.quality == 2 and o.best.cost == 2100000 and o.best.value == 900000 and o.best.profit == 900000 - 2100000)
check("order: qualities under the minimum are marked", orows[0].short == True and L.eval("STUB.orderCall") == 77)

# Recraft
rc = CH.Advisor.Analyze(10, L.eval('{ allocationGUID = "g1", recraftQuality = 1 }'))
check("recraft: profit is the better item less the one you have", rc.best.quality == 2 and rc.best.profit == 2850000 - 2120000 - 950000)

# The cheapest-reagent frontier is worked out once per recipe and price set, then reused
run("STUB.fm = AuctionIQ.Advisor.Measure(10, { professionID = 2906 }) or AuctionIQ.Advisor.Analyze(10).model")
f1 = L.eval("(function() local m = STUB.fm; m.frontierCache = nil; local a = AuctionIQ.Advisor.Cheapest(m, 0); local c1 = m.frontierCache; local b = AuctionIQ.Advisor.Cheapest(m, 20); return { same = m.frontierCache == c1, n = #a } end)()")
check("optimizer: the frontier is reused between calls at different skill", f1.same and f1.n > 0)
f2 = L.eval("""(function() local m = STUB.fm; local c1 = m.frontierCache; local id = m.qual[1].items[1]
  local old = STUB.prices['i:' .. id]; STUB.prices['i:' .. id] = { mat = 1 }; AuctionIQ.Prices.ClearCache()
  AuctionIQ.Advisor.Cheapest(m, 0); local changed = m.frontierCache ~= c1
  STUB.prices['i:' .. id] = old; AuctionIQ.Prices.ClearCache(); return changed end)()""")
check("optimizer: a reagent price change rebuilds the frontier", f2)
# Recipe scan
run('AuctionIQ.ScanUI.Toggle(); for i = 1, 20 do STUB.RunTimers() end')
sr = CH.Scan.Results(2906)
names = [r.name for r in sr.rows.values()]
check("scan: every learned recipe with a result, saved", "Test Flask" in names and "Test Potion" in names)
pot = [r for r in sr.rows.values() if r.name == "Test Potion"][0]
# a scan that runs out of frame time pauses inside a recipe and finishes it next frame, same results
before = sorted((r.name, r.profit) for r in sr.rows.values())
run("""STUB.tick = 0; STUB.scanSteps = 0; debugprofilestop = function() STUB.tick = STUB.tick + 10; return STUB.tick end
AuctionIQ.Scan.Run(function() STUB.scanSteps = STUB.scanSteps + 1 end)
for i = 1, 400 do if AuctionIQ.Scan.IsRunning() then STUB.RunTimers() end end
debugprofilestop = nil""")
after = sorted((r.name, r.profit) for r in CH.Scan.Results(2906).rows.values())
check("scan: a slow frame pauses part-way through a recipe and the results come out the same",
      not CH.Scan.IsRunning() and after == before and L.eval("STUB.scanSteps") > len(before))
run("""AuctionIQ.Scan.Run(); AuctionIQ.Scan.Stop(); for i = 1, 20 do STUB.RunTimers() end""")
check("scan: Stop ends a running scan", not CH.Scan.IsRunning())
check("scan: gold a day = profit x units sold (up to the cap) / per craft", abs(pot.perDay - pot.profit * 10 / 2) < 1e-6)
top = list(CH.Scan.Top(2906, 1).values())
tl = [(plain(l[1]), plain(l[2])) for l in CH.TooltipLines("i:302").values()]
names = [t[0] for t in tl]
acc = pot = [r for r in sr.rows.values() if r.item == 302 or r.concItem == 302][0]
check("tooltip: a scanned craft's accounts, reagents to profit",
      any(n.startswith("Crafting, per craft") for n in names) and "  Revenue after cut" in names and "Profit per craft" in names
      and names.index("  AH cut (5%)") < names.index("  Revenue after cut") < names.index("  Reagents") < names.index("Profit per craft")
      and any(n.startswith("    ") and "x item 20" in n for n in names[names.index("  Reagents"):]))
flask = [r for r in sr.rows.values() if r.item == 302][0]
check("scan: crafting cost per item, Resourcefulness and Multicraft counted", flask.craftEach and 0 < flask.craftEach <= flask.cost)
run('STUB.prices["i:302"].mat = 10000; AuctionIQ.Prices.ClearCache()')
bc = CH.Scan.BuyOrCraft(flask)
check("buy or craft: a listing under the crafting cost says buy", bc.buy == 10000 and bc.save > 0 and bc.flip == 3000000 * 0.95 - 10000)
run('STUB.prices["i:302"].mat = nil; AuctionIQ.Prices.ClearCache()')
check("scan: top recipe by profit", len(top) == 1 and top[0].profit == max(r.profit or 0 for r in sr.rows.values()))

# Queue on a Concentration budget
run('AuctionIQ.Queue.Clear()')
plan = CH.Queue.FillPlan(2906, L.eval("{ budget = 100 }"))
qs = list(CH.db.queue.values())
cq = [e for e in qs if e.concentration]
check("fill: Concentration crafts stay within the budget", plan.conc == 1 and plan.points == 80 and plan.conc == sum(e.qty for e in cq))
check("fill: profitable crafts without Concentration are added too", plan.plain > 0 and any(not e.concentration for e in qs))
check("fill: crafts per recipe stop at what sells in a day", all(e.qty <= 10 for e in qs))
run('AuctionIQ.Queue.Clear()')
plan0 = CH.Queue.FillPlan(2906, L.eval("{ budget = 0 }"))
check("fill: no Concentration, no Concentration crafts", plan0.conc == 0 and plan0.points == 0)
run('AuctionIQ.Queue.Clear()')
scan_cols = list(CH.ScanUI.Refresh().values())
check("scan shows profit with Concentration", any(r.concProfit for r in sr.rows.values()))
pot = [r for r in sr.rows.values() if r.name == "Test Potion"][0]
check("scan: each recipe tagged with its expansion", pot.line == 2871 and pot.expansion == "Khaz Algar" and sr.currentLine == 2906)
heads = [t for t in scan_cols if t.startswith("== ")]
check("scan: current expansion first, older under their own header",
      heads == ["== Midnight", "== Khaz Algar"] and scan_cols[0] == "== Midnight"
      and scan_cols.index("== Khaz Algar") < [i for i, t in enumerate(scan_cols) if t.startswith("Test Potion")][0])
run('AuctionIQ.ScanUI.olderButton.scripts.OnClick()')
hidden = list(CH.ScanUI.Refresh().values())
check("scan: older expansions can be hidden", not any(t.startswith("Test Potion") for t in hidden) and not any(t.startswith("== ") for t in hidden))
run('AuctionIQ.ScanUI.olderButton.scripts.OnClick()')
run('for _, r in ipairs(AuctionIQ.Scan.Results(2906).rows) do r.line = nil; r.expansion = nil end')
again = list(CH.ScanUI.Refresh().values())
check("scan: an older saved scan gets its expansions filled in", "== Khaz Algar" in again)


# Cooldowns
run('STUB.Fire("TRADE_SKILL_SHOW"); STUB.RunTimers()')
cd = list(CH.Cooldowns.All().values())
check("cooldowns recorded and listed", len(cd) == 1 and cd[0].name == "Phoenix Oil" and cd[0].ready == False)
check("briefing shows cooldowns", "Cooldowns" in plain(CH.UI.BriefingText()))

# Craft results log
CH.AdvisorUI.Show(10)
run('C_TradeSkillUI.CraftRecipe(10, 1, {}, nil, nil, false)')
run('STUB.Fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 302, quantity = 2, multicraft = 1, resourcesReturned = { { itemID = 204, quantity = 1 } } })')
lr = list(CH.Log.Rows().values())[0]
check("results log: craft, Multicraft proc and saved reagents counted",
      lr.crafts == 1 and lr.e.mcProcs == 1 and lr.e.saved == 300000 and lr.e.value == 2 * 3000000 * 0.95 and lr.expected == 730000)

# Tabs: one window at a time, the queue can pop out
run('AuctionIQ.ScanUI.Open()')
check("tabs: opening Scan hides the others", CH.ScanUI.IsShown() and not CH.AdvisorUI.IsShown() and not CH.QueueUI.IsShown() and CH.Window.Active() == "scan")
labels = list(CH.Window.Arrange().values())
check("tabs: the row lists every window (Results moved to Analytics)", labels == ["Advisor", "Scan", "Queue"])
run('AuctionIQ.AdvisorUI.Show(10)')
check("tabs: a recipe click updates the advisor without leaving Scan", CH.ScanUI.IsShown() and not CH.AdvisorUI.IsShown())
run('AuctionIQ.AdvisorUI.Open()')
check("tabs: the Advisor tab brings it back", CH.AdvisorUI.IsShown() and not CH.ScanUI.IsShown())
run('AuctionIQ.QueueUI.Show(); AuctionIQ.Window.ToggleQueuePop()')
labels = list(CH.Window.Arrange().values())
check("pop-out: the queue leaves the tabs and shows beside the advisor",
      CH.QueueUI.IsShown() and CH.AdvisorUI.IsShown() and "Queue" not in labels)
run('AuctionIQ.ScanUI.Open()')
check("pop-out: switching tabs leaves the queue open", CH.ScanUI.IsShown() and CH.QueueUI.IsShown() and not CH.AdvisorUI.IsShown())
run('AuctionIQ.Window.ToggleQueuePop()')
check("back in the tabs: the queue takes the spot", CH.QueueUI.IsShown() and not CH.ScanUI.IsShown() and CH.Window.Active() == "queue")
run('AuctionIQ.Window.CloseTabs()')
check("closing the profession closes the tabs", not CH.QueueUI.IsShown() and CH.Window.Active() is None)

# Midnight reports craftingQuality as a quality ID (13, 14), not 1, 2: quality comes from skill instead
run('STUB.qualityOffset = 12')
mq = CH.Advisor.Analyze(10)
check("quality from skill, not the game's quality ID", [r.quality for r in mq.rows.values()] == [1, 2, 2] and mq.best.item == 302 and mq.bestConc.perPoint == 27250)
run('STUB.qualityOffset = nil')

# Dashboard and Ledger from TSM's saved data (read only)
run(r"""
local now = STUB.now
local m = math.floor(now / 60)
local function lines(t) return table.concat(t, "\n") end
TradeSkillMasterDB = {
  ["s@Courtizy - Alliance - Emerald Dream@internalData@money"] = 5000000,
  ["s@Luxaren - Alliance - Emerald Dream@internalData@money"] = 3000000,
  ["s@Other - Horde - Area 52@internalData@money"] = 99990000,
  ["g@ @internalData@warbankMoney"] = 2000000,
  ["s@Courtizy - Alliance - Emerald Dream@internalData@goldLog"] = lines({ "minute,copper", (m - 3000) .. ",1000000", (m - 600) .. ",5000000" }),
  ["s@Luxaren - Alliance - Emerald Dream@internalData@goldLog"] = lines({ "minute,copper", (m - 3000) .. ",3000000" }),
  ["g@ @internalData@warbankGoldLog"] = lines({ "minute,copper", (m - 3000) .. ",2000000" }),
  ["r@Emerald Dream@internalData@csvSales"] = lines({ "itemString,stackSize,quantity,price,otherPlayer,player,time,source",
    "i:302,1,2,3000000,Buyer,Courtizy," .. (now - 3600) .. ",Auction",
    "i:301,1,1,1000000,Buyer,Luxaren," .. (now - 3 * 86400) .. ",Auction",
    "i:301,1,4,1000000,Buyer,Luxaren," .. (now - 400 * 86400) .. ",Auction" }),
  ["r@Emerald Dream@internalData@csvBuys"] = lines({ "itemString,stackSize,quantity,price,otherPlayer,player,time,source",
    "i:201,1,10,100000,Seller,Courtizy," .. (now - 7200) .. ",Auction" }),
  ["r@Emerald Dream@internalData@csvIncome"] = lines({ "type,amount,otherPlayer,player,time",
    "Money Transfer,500000,Luxaren,Courtizy," .. (now - 100) }),
  ["r@Emerald Dream@internalData@csvExpense"] = lines({ "type,amount,otherPlayer,player,time",
    "Money Transfer,500000,Courtizy,Luxaren," .. (now - 100), "Repair Bill,20000,Merchant,Courtizy," .. (now - 50) }),
  ["r@Emerald Dream@internalData@csvExpired"] = lines({ "itemString,stackSize,quantity,player,time", "i:302,1,1,Courtizy," .. (now - 3500) }),
  ["r@Emerald Dream@internalData@csvCancelled"] = "itemString,stackSize,quantity,player,time",
  ["s@Courtizy - Alliance - Emerald Dream@internalData@bagQuantity"] = { ["i:302"] = 3 },
  ["s@Luxaren - Alliance - Emerald Dream@internalData@mailQuantity"] = { ["i:302::q2"] = 1 },
  ["g@ @internalData@warbankQuantity"] = { ["i:301"] = 2 },
}
""")
LG = CH.Ledger
names = sorted(c.name for c in LG.Characters().values())
check("ledger: this realm's characters only", names == ["Courtizy", "Luxaren"] and LG.Gold() == 10000000)
gs = list(LG.GoldSeries(L.eval("STUB.now") - 2 * 86400, L.eval("STUB.now"), 3).values())
check("ledger: gold history adds up every character's log", gs[0].v == 6000000 and gs[2].v == 10000000)
run("AuctionIQ.UI.SetRange('1M')")
d = CH.UI.DashboardData()
s = d.summary
check("dashboard: sales, buys and real expenses in range; own transfers left out",
      s.sales == 7000000 and s.buys == 1000000 and s.income == 0 and s.expense == 20000 and s.cash == 5980000 and s.topItem == 302)
check("dashboard: top sale, top purchase, 52 week high and low", d.topSale == 6000000 and d.topBuy == 1000000 and d.high == 10000000 and 0 < d.low <= d.high)
run("AuctionIQ.UI.SetRange('All')")
check("dashboard: All reaches back past TSM's year", CH.UI.DashboardData().summary.sales == 11000000)
act = list(LG.Activity(10).values())
check("activity log: grouped by character and hour", act[0].player == "Courtizy" and act[0].sold == 2 and act[0].expired == 1 and sum(a.bought for a in act) == 10)
inv = {e.id: e for e in LG.Inventory().values()}
v302 = CH.Prices.Get("chvalue", "i:302")
check("inventory: bags, mail and warband, qualities merged", inv[302].total == 4 and inv[302].bags == 3 and inv[302].mail == 1 and inv[301].warband == 2 and inv[302].value == v302 * 4)
w1 = LG.Snapshot(L.eval("STUB.now") - 5 * 86400)
LG.Snapshot()
check("net worth change counts gold and inventory", LG.WorthChange(L.eval("STUB.now") - 6 * 86400)[0] == 0 and w1[0] > 10000000)
rep = LG.Report()
check("morning report: last day's sales and what came back", rep.sold == 2 and rep.earned == 6000000 and rep.bought == 10
      and list(rep.expired.values())[0].id == 302 and len(list(rep.restock.values())) == 0)
bt = plain(CH.UI.BriefingText())
check("briefing opens with the last 24 hours", bt.startswith("Last 24 hours") and "Came back unsold" in bt and "repost it" in bt)
pl = {e.id: e for e in LG.ProductPL(-1e12).values()}
check("product P&L: crafted sales after cut less cost at what you paid", 302 in pl and pl[302].sold == 2
      and abs(pl[302].revenue - 6000000 * 0.95) < 1 and abs(pl[302].profit - (pl[302].revenue - pl[302].cost)) < 1
      and pl[302].line == "Flasks & Phials")
# a purchase after the sale doesn't change what that sale cost (cost at the time, not today's pool);
# one before it does
k = "r@Emerald Dream@internalData@csvBuys"
run(f"""STUB.oldBuys = TradeSkillMasterDB["{k}"]
TradeSkillMasterDB["{k}"] = STUB.oldBuys .. "\\ni:202,1,10,9000000,Seller,Courtizy," .. STUB.now .. ",Auction"
AuctionIQ.Ledger.ClearStats()""")
pl2 = {e.id: e for e in LG.ProductPL(-1e12).values()}
run(f"""TradeSkillMasterDB["{k}"] = STUB.oldBuys .. "\\ni:202,1,10,9000000,Seller,Courtizy," .. (STUB.now - 7000) .. ",Auction"
AuctionIQ.Ledger.ClearStats()""")
pl3 = {e.id: e for e in LG.ProductPL(-1e12).values()}
check("product P&L: a later purchase leaves an earlier sale's cost alone", abs(pl2[302].cost - pl[302].cost) < 1)
check("product P&L: a purchase before the sale sets its cost", pl3[302].cost > pl[302].cost + 1 and pl3[302].paidShare > 0)
run(f"""TradeSkillMasterDB["{k}"] = STUB.oldBuys; AuctionIQ.Ledger.ClearStats()""")
dead = list(LG.DeadStock(L.eval("STUB.now"), 1).values())
check("dead stock: held, not sold in the window", [e.id for e in dead] == [301] and dead[0].advice.startswith("Slow"))
o = LG.Overhead(-1e12)
check("overhead: repairs, not your own transfers", o.total == 20000 and len(list(o.types.values())) == 1 and o.afterOverhead == o.profit - 20000)
# Phase 2: forecast vs actual
logged = [b for b in CH.Forecast.Store().values() if b.id == 302]
check("forecast: a craft saves its forecast with the batch", len(logged) == 1 and logged[0].qty == 2 and logged[0].cost and logged[0].expectEach)
run("""
AuctionIQ.db.batches = {
  { at = STUB.now - 2 * 86400, id = 302, qty = 1, cost = 1000000, expectEach = 4000000 },
  { at = STUB.now - 86400, id = 302, qty = 3, cost = 3000000, expectEach = 4000000 },
}
AuctionIQ.Forecast.Clear()
""")
bs = list(CH.Forecast.Batches(302).values())
check("forecast: sales match crafts oldest first", bs[0].sold == 1 and bs[1].sold == 1)
pf = {e.id: e for e in CH.Forecast.Performance().values()}[302]
check("forecast: made, sold, sold-each against forecast, realized profit",
      pf.made == 4 and pf.sold == 2 and abs(pf.accuracy - 0.7125) < 1e-6 and abs(pf.realized - 3700000) < 1 and abs(pf.days - 1.4583) < 0.01)
check("forecast: no shading before anything has sold", CH.Forecast.Shade(999) is None)
# each sale counts with a 30-day half-life, and the ratio is shrunk toward 1 by PRIOR units
now = L.eval("STUB.now")
wn = wexp = wrev = 0
for b in bs:
    if b.sold > 0:
        w = 0.5 ** ((now - b.at) / (30 * 86400))
        wn += w * b.sold; wexp += w * b.expectEach * b.sold; wrev += w * b.revenue
r_ = wrev / wexp
want = (wn * r_ + 5) / (wn + 5)
sh = CH.Forecast.Shade(302)
check("forecast: an item that sells under forecast is shaded down, shrunk toward 1",
      abs(sh[0] - want) < 1e-9 and 0.7125 < sh[0] < 1 and "2 sold at" in sh[1])
prow, pfoot = CH.LedgerUI.Rows("perf", L.eval("{ }"))
check("forecast: the Performance view", len(list(prow.values())) == 1 and "Sold -29% vs forecast" in plain(pfoot))
pick = "(function() local r = AuctionIQ.Advisor.Analyze(10, {}); for _, x in ipairs(r.rows) do if x.item == 302 and not x.concentration then return x.unit, x.shade, r.best.item end end end)()"
run("AuctionIQ.Forecast.PRIOR = 1e15"); u0 = L.eval(pick)
run("AuctionIQ.Forecast.PRIOR = 5"); u5 = L.eval(pick)
run("AuctionIQ.Forecast.PRIOR = 0"); u1 = L.eval(pick)
check("forecast: the advisor values the item at what it really fetches", abs(u5[0] / u0[0] - want) < 1e-6 and abs(u1[0] / u0[0] - r_) < 1e-6)
check("forecast: a shaded item can lose its place as the best craft", u0[2] == 302 and u1[2] == 301)
run("AuctionIQ.Forecast.PRIOR = 5")

rows, foot = CH.LedgerUI.Rows("pl", L.eval("{ }"))
check("CFO views draw rows", len(list(rows.values())) == 1 and "best line: Flasks" in plain(foot))
for v in ["dead", "holdings", "overhead"]:
    CH.LedgerUI.Rows(v, L.eval("{ days = 30 }"))
run("AuctionIQ.Par.Refresh()")
# 1 sold a week: Poisson(1) stays at or under 2 about 92% of the time, so 2 at 90%; half a week (301) needs 1
check("stock target: a week's demand at a 90% service level, by default", CH.Par.Target(302)[0] == 2 and CH.Par.Target(301)[0] == 1 and CH.Par.Target(201) is None)
run("AuctionIQ.Settings.Model('service', 9); AuctionIQ.Par.Refresh()")
check("stock target: the service level is a setting (99% needs 4)", CH.Par.Target(302)[0] == 4 and CH.Settings.Model("service")[1] == "99%")
run("AuctionIQ.Settings.Model('service', -9); AuctionIQ.Par.Refresh()")
run("AuctionIQ.Par.Set(302, 6); AuctionIQ.Par.Refresh()")
par = {e.id: e for e in CH.Par.List().values()}
check("par: set by hand, short counts stock on every character", par[302].manual and par[302].held == 4 and par[302].short == 2)
check("par view: shift-click +1, alt-click back to automatic", CH.LedgerUI.ParClick(302, "shift")[0] == 7 and CH.LedgerUI.ParClick(302, "alt")[0] == 2)
run("AuctionIQ.Par.Set(302, 6); AuctionIQ.Par.Refresh()")
check("briefing lists what's below par", "Below stock target" in plain(CH.UI.BriefingText()))
rows, foot = CH.LedgerUI.Rows("par", L.eval("{ }"))
check("par view rows", len(list(rows.values())) == 2 and plain(foot).startswith("1 items below stock target"))
run("AuctionIQ.Par.Set(302, nil); AuctionIQ.Par.Refresh()")
# Groups and auctioning
n = CH.Groups.Rebuild()
check("groups: built from scans, reagents and resale", n > 0 and CH.Groups.Path(302).startswith("Crafted/") and CH.Groups.Path(201).startswith("Reagents/"))
check("groups: crafted goods post, reagents don't", CH.Groups.Prices(302).post and not CH.Groups.Prices(201).post)
run("AuctionIQ.Groups.Move(302, 'Mine/Flasks')")
check("groups: moving an item sticks", CH.Groups.Path(302) == "Mine/Flasks" and any(g.path == "Mine/Flasks" for g in CH.Groups.Tree().values()))
run("AuctionIQ.Groups.Move(302, nil)")
p302 = CH.Groups.Prices(302)
check("prices: min is the cost to make after the cut", p302.min and p302.why == "cost to make" and p302.normal == 3000000 and p302.max == 9000000)
check("warband listed: TSM's counts per character", CH.Auction.Listed(302) == 0)
run("AuctionIQ.Groups.Store().ops.Crafted.cap = 5")
# Post scan: gear splits by item level (five rank 4 rods and ten rank 3 rods are two posts)
run("""STUB.oldC, STUB.oldII = C_Container, C_Item.GetItemInfoInstant
local bags = { [0] = {} }
for i = 1, 5 do bags[0][i] = { itemID = 302, stackCount = 1, hyperlink = "item:302:645" } end
for i = 6, 15 do bags[0][i] = { itemID = 302, stackCount = 1, hyperlink = "item:302:642" } end
bags[0][16] = { itemID = 201, stackCount = 20, hyperlink = "item:201" }
C_Container = { GetContainerNumSlots = function(b) return b == 0 and 16 or 0 end, GetContainerItemInfo = function(b, s) return bags[b] and bags[b][s] end }
C_Item.GetItemInfoInstant = function(id) return id, nil, nil, nil, nil, id == 302 and 2 or 7 end
C_Item.GetDetailedItemLevelInfo = function(link) return tonumber(link:match("item:%d+:(%d+)")) end
STUB.prices['i:302::i645'] = { formula_value = 4000000 }""")
_, pl = L.eval("AuctionIQ.Auction.Postable()"), L.eval("select(2, AuctionIQ.Auction.Postable())")
pl = list(pl.values())
check("post scan: gear split by item level, others not", [(e.id, e.level, e.count) for e in pl] == [(201, None, 20), (302, 645, 5), (302, 642, 10)])
check("post scan: bag counts per item level", L.eval("AuctionIQ.Auction.InBags(302, 642)") == 10 and L.eval("AuctionIQ.Auction.InBags(302)") == 15)
check("post scan: each item level priced on its own", CH.Groups.Prices(302, None, 645).normal == 4000000 and CH.Groups.Prices(302).normal != 4000000)
run("C_Container, C_Item.GetItemInfoInstant, C_Item.GetDetailedItemLevelInfo = STUB.oldC, STUB.oldII, nil")
d = CH.Auction.Decide(302, L.eval("{ { price = 2900000, qty = 3, mine = false }, { price = 2950000, qty = 1, mine = true } }"), 10)
check("auction: undercut the cheapest seller outside the account", d.action == "post" and d.price == 2899900 and d.qty == 5)
d = CH.Auction.Decide(302, L.eval("{ { price = 2800000, qty = 1, mine = true }, { price = 2900000, qty = 3, mine = false } }"), 10)
check("auction: never undercut your own Warband, match it", d.action == "post" and d.price == 2800000)
d = CH.Auction.Decide(302, L.eval("{ { price = 10, qty = 3, mine = false } }"), 10)
check("auction: skip when the cheapest is under your min", d.action == "skip" and "min" in d.why)
run("AuctionIQ.Auction.RecordOwned({ { id = 302, qty = 3 } })")
d = CH.Auction.Decide(302, L.eval("{ }"), 10)
check("auction: the Warband's live auctions count toward the cap", CH.Auction.Listed(302) == 3 and d.qty == 2 and d.price == 3000000)
c = CH.Auction.DecideCancel(302, 3000000, L.eval("{ { price = 2950000, qty = 1, mine = true } }"))
check("cancel: your own alts never trigger a repost", c.action == "keep")
c = CH.Auction.DecideCancel(302, 3000000, L.eval("{ { price = 2950000, qty = 1, mine = false } }"))
check("cancel: someone else cheaper does", c.action == "cancel")
# Formulas in TSM's syntax
FV = lambda f, id=302: L.eval(f"AuctionIQ.Formula.Value({f!r}, {id})")
check("formula: money, percent, functions", FV("1g50s") == 15000 and FV("150% 2g") == 30000 and FV("max(1g, 2g, 3s)") == 20000
      and FV("first(nosuchsource, 5s)") == 500 and FV("ifgte(10, 5, 1g, 2g)") == 10000 and FV("check(0, 1g, 2g)") == 20000
      and FV("0.25*avg(4g, 8g)") == 15000 and FV("400%2c") == 8)
check("formula: a missing source makes the whole thing missing, bad syntax reads as invalid",
      FV("2 * nosuchsource") is None and not L.eval("(AuctionIQ.Formula.Valid('max(1g,'))"))

# TSM's auctioning setup, imported once (TSM's data only read)
run("""
AuctionIQ.Auction.RecordOwned({})
TradeSkillMasterDB["_currentProfile"] = { ["Courtizy - Emerald Dream"] = "Warband" }
TradeSkillMasterDB["p@Warband@userData@items"] = { ["i:302"] = "Alch`Flasks", ["i:301"] = "Loot`Pets" }
TradeSkillMasterDB["p@Warband@userData@groups"] = { [""] = { Auctioning = { "Sell Loot", override = true } },
  ["Alch"] = { Auctioning = { "Flask Op", override = true } }, ["Alch`Flasks"] = { Auctioning = { "Flask Op" } }, ["Loot"] = { Auctioning = { "Sell Loot", override = true } } }
TradeSkillMasterDB["g@ @userData@sharedOperations"] = { Auctioning = {
  ["Flask Op"] = { minPrice = "2950000", normalPrice = "flaskstep", maxPrice = "4000000", postCap = "2", undercut = "1s", duration = 2,
    keepQuantity = "0", maxExpires = "0", priceReset = "none", aboveMax = "maxPrice" },
  ["Sell Loot"] = { minPrice = "1g", normalPrice = "5g", maxPrice = "10g", postCap = "5", undercut = "1s", duration = 3,
    keepQuantity = "1", maxExpires = "1", priceReset = "none", aboveMax = "maxPrice" } } }
TradeSkillMasterDB["g@ @userData@customPriceSources"] = { flaskstep = "ifgte(numexpires, 1, 90% 3500000, 3500000)" }
AuctionIQ.Groups.ResetTSM()
AuctionIQ.Ledger.ClearStats()
""")
imp = L.eval("AuctionIQ.Groups.ImportTSM()")
check("import: TSM operations, custom sources and group assignments copied", imp.ops == 2 and imp.sources == 1 and imp.groups >= 3)
run("TradeSkillMasterDB['g@ @userData@sharedOperations'] = nil; TradeSkillMasterDB['g@ @userData@customPriceSources'] = nil")
tp = CH.Groups.Prices(302)
check("import: TSM's groups win and price by the copied formulas, with TSM gone",
      CH.Groups.Path(302) == "TSM/Alch/Flasks" and tp.op == "Flask Op" and tp.min == 2950000 and tp.max == 4000000 and tp.cap == 2 and tp.undercut == 100)
check("import: a custom source steps the price down after an expiry", tp.normal == 3150000)
d = CH.Auction.Decide(302, L.eval("{ { price = 2900000, qty = 3, mine = false } }"), 10)
check("rules: under min and set not to reset means no post", d.action == "skip" and "min" in d.why)
d = CH.Auction.Decide(302, L.eval("{ { price = 3600000, qty = 3, mine = false } }"), 10)
check("rules: undercut and post cap", d.action == "post" and d.price == 3599900 and d.qty == 2)
d = CH.Auction.Decide(302, L.eval("{ { price = 9000000, qty = 3, mine = false } }"), 10)
check("rules: above max posts at max", d.action == "post" and d.price == 4000000)
run("AuctionIQ.Groups.Store().ops['Flask Op'].priceReset = 'normalPrice'")
d = CH.Auction.Decide(302, L.eval("{ { price = 2900000, qty = 3, mine = false } }"), 10)
check("rules: below min resets to normal when set", d.action == "post" and d.price == 3150000)
run("AuctionIQ.Groups.Store().ops['Flask Op'].maxExpires = 1")
d = CH.Auction.Decide(302, L.eval("{ }"), 5)
check("rules: max expires stops posting after too many expiries without a sale", d.action == "skip" and "expired 1 times" in d.why)
run("AuctionIQ.Groups.Store().ops['Flask Op'].maxExpires = 0; AuctionIQ.Groups.Store().ops['Sell Loot'].maxExpires = 0")
d = CH.Auction.Decide(301, L.eval("{ }"), 5)
check("rules: keep in bags holds some back", d.action == "post" and d.qty == 4)
run("AuctionIQ.Groups.Store().ops['Flask Op'].learn = true; STUB.ledgerLearn = true")
lf, lwhy = L.eval("AuctionIQ.Groups.Learn(302)"), None
check("learn: too few sales and expiries changes nothing", lf == 1)
run("AuctionIQ.Groups.Store().ops['Flask Op'].learn = false")
run("AuctionIQ.Groups.Store().preferTSM = nil; TradeSkillMasterDB['p@Warband@userData@items'] = nil; AuctionIQ.Groups.ResetTSM()")
run("AuctionIQ.GroupsUI.Select('Crafted'); AuctionIQ.UI.Page('groups')")
grows = list(CH.GroupsUI.Refresh().values())
check("groups page: the group's items with their prices", any(r.id == 302 for r in grows) and CH.UI.IsShown())
check("groups now live in Settings: the old name opens them there", L.eval("AuctionIQ.UI.IsShown()"))
# Trading tab: what to post and mail, before you get to the AH
pp = {r.id: r for r in CH.TradingUI.PostPlan().values()}
check("trading: ready to post counts what every character holds in a posting group", 302 in pp and pp[302].held >= 3 and pp[302].verdict in ("post", "hold", "full"))
r302 = pp[302]
check("trading: posts no more than the group's cap less what's up", r302.post <= max(0, (r302.cap or 0) - r302.up))
run("AuctionIQ.Mail.Route('Crafted', 'Luxaren')")
mp = list(CH.TradingUI.MailPlan().values())
check("trading: to mail lists items on a character other than their route", any(r.id == 302 and r["from"] == "Courtizy" and r.to == "Luxaren" for r in mp))
run("AuctionIQ.Mail.Route('Crafted', nil)")
run("AuctionIQ.UI.Page('trading', 'post')")
check("old trading tab opens Operations on Ready to post", CH.LedgerUI.View() == "post" and CH.LedgerUI.Section() == "operations")
run("AuctionIQ.Mail.Route('Crafted', 'Luxaren')")
pr, pf = L.eval("AuctionIQ.LedgerUI.Rows('post', {})")
mr, mf = L.eval("AuctionIQ.LedgerUI.Rows('mail', {})")
check("trading views: rows and a summary line", len(list(pr.values())) > 0 and "to post" in plain(pf) and len(list(mr.values())) > 0 and "to send" in plain(mf))
wk = list(CH.TradingUI.WorkPlan().values())
check("execution plan: a mail trip per sender and receiver, and posts from Ready to post", any(w.kind == "mail" and w.char == "Courtizy" and w.task == "Mail to Luxaren" and w.where == "Mailbox" for w in wk)
      and all(w.kind != "post" or w.where == "Auction House" for w in wk))
run("AuctionIQ.Mail.Route('Crafted', nil)")
check("auction panel builds", CH.AuctionUI.Build() is not None)
# Posting waits for the AH's answer
run("""
STUB.ahPosts = {}
AuctionIQ.Auction.BagSlots = function(id) return STUB.owlBags > 0 and { { bag = 0, slot = 1, count = 1 } } or {} end
STUB.owlBags = 2
""")
run("""
local AUI = AuctionIQ.AuctionUI
local plan = AUI.Plan()
for k in pairs(plan) do plan[k] = nil end
table.insert(plan, { id = 302, d = { action = "post", qty = 2, price = 11000099, duration = 2, why = "undercutting" } })
""")
L.execute("AuctionIQ.AuctionUI.PostNext()")
pp = L.eval("STUB.ahPosts[1]")
e = L.eval("AuctionIQ.AuctionUI.Plan()[1]")
check("post: whole silver only, one item per click, not done until the AH answers",
      pp.buyout == 11000000 and pp.qty == 1 and not e.done)
L.execute("AuctionIQ.AuctionUI.PostNext()")
check("post: no second post while one is waiting", L.eval("#STUB.ahPosts") == 1)
run('STUB.owlBags = 1; STUB.Fire("AUCTION_HOUSE_AUCTION_CREATED", 1)')
check("post: the AH's confirmation counts it, the rest stay to post", e.posted == 1 and not e.done and "1 of 2" in e.d.why)
L.execute("AuctionIQ.AuctionUI.PostNext()")
run('STUB.Fire("UI_ERROR_MESSAGE", 1, "Item not found"); STUB.RunTimers()')
check("post: no confirmation and still in bags means failed, with the game's reason",
      e.failed and e.done and e.d.why == "Item not found")

# A long post scan scrolls, and every row (not only the first) explains itself on hover
run("""
local plan = AuctionIQ.AuctionUI.Plan()
for k in pairs(plan) do plan[k] = nil end
for i = 1, 25 do table.insert(plan, { id = 302, other = 90000, d = { action = "skip", why = "row " .. i } }) end
AuctionIQ.AuctionUI.Refresh()
""")
h1 = [plain(l[1]) for l in L.eval("AuctionIQ.AuctionUI.HoverLines(1)").values()]
check("auction hover: the why in full, the cheapest rival and the operation's prices",
      "Skip: row 1" in h1 and "Cheapest outside your account" in h1 and any(x.startswith("Operation") for x in h1) and "  Min / normal / max" in h1)
check("auction hover: the last row has its own story too", plain(L.eval("AuctionIQ.AuctionUI.HoverLines(18)")[2][1]) == "Skip: row 18")
run("AuctionIQ.AuctionUI.Build().scripts.OnMouseWheel(nil, -1)")
check("auction panel: the wheel scrolls past the first 18 rows", plain(L.eval("AuctionIQ.AuctionUI.HoverLines(1)")[2][1]) == "Skip: row 4")
run("local plan = AuctionIQ.AuctionUI.Plan(); for k in pairs(plan) do plan[k] = nil end; AuctionIQ.AuctionUI.Refresh()")
tl = [plain(l[1]) for l in CH.TooltipLines("i:302").values()]
check("tooltip: shows how AuctionIQ will post it", "Posting" in tl and "  Min / normal / max" in tl)

run("AuctionIQ.Mail.Route('Crafted', 'Luxaren')")
check("mail: a group's route reaches its sub-groups", CH.Mail.Destination(302)[0] == "Luxaren" and CH.Mail.Destination(201) is None)
check("mail panel builds", CH.MailUI.Build() is not None)
run("AuctionIQ.Mail.Route('Crafted', nil)")
st = {e.id: e for e in LG.SaleTimes(-1e12).values()}
check("when it sells: weekday and 4-hour window per item", st[301].sold == 5 and 1 <= st[301].bestDay <= 7 and st[302].share == 1)
comp = {e.id: e for e in LG.Competition(-1e12).values()}
check("competition: post scans count how often you're beaten", comp[302].seen >= 3 and comp[302].beaten >= 1)
for v in ["when", "rivals"]:
    CH.LedgerUI.Rows(v, L.eval("{ }"))
run("AuctionIQ.db.token = { price = 2500000000, at = 1 }")
check("token value: gold read as tokens", CH.Alerts.InTokens(5000000000) == "2.0 tokens")
run("for _, c in pairs(AuctionIQ.db.characters) do for _, p in pairs(c.professions) do p.conc = p.concMax; p.concAt = STUB.now end end")
fired = list(CH.Alerts.Check().values())
again = list(CH.Alerts.Check().values())
check("alerts fire once, then wait 6 hours", any("Concentration is full" in f for f in fired) and len(again) == 0)
run("AuctionIQ.Planner.Store().kp['Seyko-Emerald Dream'] = { ['Midnight Enchanting'] = { first = { [AuctionIQ.Planner.WeekStart()] = 20 }, now = 26, unspent = 4 } }")
kn = list(CH.Planner.Knowledge().values())
check("knowledge: points gained this week per character and profession", kn[0].gained == 6 and kn[0].unspent == 4 and len(list(kn[0].tasks.values())) == 4)
check("knowledge: tick a weekly source", CH.Planner.Tick("Seyko-Emerald Dream", "Midnight Enchanting", "Treatise") == True and list(CH.Planner.Knowledge().values())[0].tasks[1].done)
run("SlashCmdList.AUCTIONIQ('event ' .. date('%Y-%m-%d', STUB.now + 3 * 86400) .. ' Season 2 starts')")
up = list(CH.Planner.Upcoming().values())
check("calendar: your dates with what they mean for demand", up[0].name.lower() == "season 2 starts" and "potions" in up[0].hint)
run("AuctionIQ.Planner.StartSession('Auction House'); STUB.now = STUB.now + 1800; AuctionIQ.Planner.StopSession('Auction House')")
tm = CH.Planner.Time(L.eval("STUB.now") - 86400)
check("gold per hour: time per activity", abs(tm.kinds["Auction House"] - 0.5) < 1e-9 and tm.perHour is not None)
run("AuctionIQ.UI.Page('plan')")
check("plan page draws", CH.UI.IsShown() and len(list(CH.PlanUI.Refresh().values())) == 1)
run("""function GetInboxNumItems() return 3 end
function GetInboxHeaderInfo(i) return nil, nil, 'x', 's', ({ 5000000, 0, 7000000 })[i], ({ 0, 0, 100 })[i], 1, i == 2 end""")
w = CH.Mail.Waiting()
check("mail: gold waiting before opening, cash on delivery left out", w.gold == 5000000 and w.mails == 3 and w["items"] == 1 and w.cod == 1)
check("mail: waiting gold adds up across characters for the briefing", CH.Mail.WaitingAll()[0] == 5000000 and "Waiting in mail" in plain(CH.UI.BriefingText()))
run("GetInboxNumItems = nil; GetInboxHeaderInfo = nil; AuctionIQ.Mail.Store().waiting = {}")
n7 = CH.ReportUI.Numbers(7)
check("report: 7 days of sales after cut, purchases, overhead", abs(n7.sales - 7000000 * 0.95) < 1 and n7.buys == 1000000 and n7.overhead == 20000)
run("AuctionIQ.UI.Page('briefing')")
check("briefing opens with the books", len(list(CH.ReportUI.Refresh().values())) == 5)
csvtext, nrows = CH.ReportUI.CSV("sales", L.eval("{ }"))
run("AuctionIQ.ReportUI.Export('sales', { days = 30 })")
check("export: a Ledger table as CSV", csvtext.split("\n")[0].startswith("Item,Character") and nrows == 3 and "300.00" in csvtext)
run("AuctionIQ.UI.Page('ledger')")
check("theme: the Accounting tab is plum", L.eval("AuctionIQ.Theme.palette == 'accounting' and AuctionIQ.Theme.hex.bg == '1c1222'"))
run("AuctionIQ.UI.Page('markets')")
check("theme: other pages are AuctionIQ navy", L.eval("AuctionIQ.Theme.palette == 'auctioniq' and AuctionIQ.Theme.hex.bg == '0e1729'"))
# AH scans: any search answered in the AH window is saved (Data/Scans.lua)
run("""C_AuctionHouse.GetNumItemSearchResults = function() return 3 end
C_AuctionHouse.GetItemSearchResultInfo = function(key, i) return ({ { buyoutAmount = 100000, quantity = 1 }, { buyoutAmount = 140000, quantity = 1 },
  { buyoutAmount = 90000, quantity = 1, containsOwnerItem = true } })[i] end""")
run('STUB.Fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 302 })')
sc = CH.Scans.Get(302)
check("scan: an item search is saved with its cheapest and market price", sc.min == 90000 and sc.market == 90000 and sc.qty == 3 and sc.full and sc.age == 0)
run("STUB.now = STUB.now - 3 * 86400; AuctionIQ.Scans.Record(302, { { price = 110000, qty = 1 } }, false); STUB.now = STUB.now + 3 * 86400")
run("AuctionIQ.Scans.Record(302, { { price = 123400, qty = 1 } }, false)")
sc = CH.Scans.Get(302)
check("scan: one market price a day makes a 7-day average", sc.days == 2 and abs(sc.avg7 - (110000 + (90000 + 123400) / 2) / 2) < 1 and sc.change7 > 0)
tl = [l[1] for l in CH.TooltipLines("item:302").values()]
check("tooltip: your last AH scan shows", "Your AH scan" in tl and any("7-day average" in x for x in tl))
run("AuctionIQ.Scans.RecordBrowse(302, 50000, 9)")
check("scan: a browse row doesn't replace a fresh full search", CH.Scans.Get(302).market == 123400)
run("AuctionIQ.Scans.RecordBrowse(303, 50000, 9)")
check("scan: a browse row is kept as cheapest price", CH.Scans.Get(303).min == 50000 and not CH.Scans.Get(303).full)
run("STUB.now = STUB.now + 31 * 86400; AuctionIQ.Scans.Prune(); STUB.now = STUB.now - 31 * 86400")
check("scan: items not seen in 30 days are dropped", CH.Scans.Get(303) is None)
run("AuctionIQ.db.scans = {}")
run("AuctionIQ.Auction.RecordOwned({})")
LU = CH.LedgerUI
rows, foot = LU.Rows("sales", L.eval("{ days = 30 }"))
check("ledger sales: in the time frame only, with the total", len(list(rows.values())) == 2 and plain(foot) == "3 items sold: 700g")
rows, foot = LU.Rows("sales", L.eval("{ char = 'Luxaren' }"))
check("ledger sales: one character", len(list(rows.values())) == 2 and all(r.cells[2] == "Luxaren" for r in rows.values()))
rows, foot = LU.Rows("income", L.eval("{ }"))
check("ledger other income: own transfers shown but kept out of the total", len(list(rows.values())) == 1 and plain(foot).startswith("Total: -") or "moved between" in plain(foot))
rows, foot = LU.Rows("expense", L.eval("{ }"))
check("ledger other expenses: repairs count", "Total: 2g" in plain(foot))
rows, foot = LU.Rows("expired", L.eval("{ }"))
check("ledger failed auctions", len(list(rows.values())) == 1 and plain(foot).startswith("1 items expired") and "deposits lost" in plain(foot))
rows, foot = LU.Rows("resale", L.eval("{ }"))
check("ledger resale: only items both bought and sold", len(list(rows.values())) == 0 and "0 items resold" in plain(foot))
inv = list(LU.Rows("inventory", L.eval("{ char = 'Courtizy' }"))[0].values())
check("ledger inventory: one character leaves out the others and the warband", len(inv) == 1 and inv[0].cells[2] == 3)
run("AuctionIQ.UI.Page('ledger')")
run("AuctionIQ.LedgerUI.Set({ view = 'sales', days = false, sort = 6, desc = true })")
shown = list(CH.LedgerUI.Refresh()[0].values())
check("ledger table sorts by any column", [r.sort[6] for r in shown] == sorted([r.sort[6] for r in shown], reverse=True) and len(shown) == 3)
run("AuctionIQ.LedgerUI.Set({ sort = 6, desc = false })")
shown = list(CH.LedgerUI.Refresh()[0].values())
check("and back the other way", [r.sort[6] for r in shown] == sorted(r.sort[6] for r in shown))
check("time frame reads like TSM's", CH.LedgerUI.Ago(L.eval("STUB.now") - 3 * 86400 - 7200, L.eval("STUB.now")) == "3 Days 2 Hr")
run("AuctionIQ.UI.Page('dashboard')")
check("dashboard page draws", CH.UI.IsShown())
run("AuctionIQ.UI.Page('dashboard')")
pt = CH.UI.ChartHover(10000)
check("chart hover: nearest point with who held what", pt.v == LG.Gold() and sorted(b.name for b in pt.by.values()) == ["Courtizy", "Luxaren", "Warband"])
run("AuctionIQ.UI.CharacterMenu(nil, 'Warband'); AuctionIQ.UI.CharacterMenu(nil, 'Luxaren')")
check("characters can be left out, warband too", LG.Gold() == 5000000 and not LG.Included("Warband"))
last = list(LG.GoldSeries(L.eval("STUB.now") - 86400, L.eval("STUB.now"), 2).values())[1]
check("the chart leaves them out too", last.v == 5000000 and len(list(last.by.values())) == 1)
run("AuctionIQ.UI.CharacterMenu(nil, 'Warband'); AuctionIQ.UI.CharacterMenu(nil, 'Luxaren')")
check("and back in", LG.Gold() == 10000000)
run("AuctionIQ.UI.Page('ledger'); AuctionIQ.UI.Page('briefing')")
check("ledger and briefing pages draw", CH.UI.IsShown())

# Four tabs, old names still work, shared table page sections
LUI = CH.LedgerUI
run("AuctionIQ.UI.Page('briefing')")
check("report opens inside the Accounting tab", LUI.Section() == "ledger" and LUI.View() == "report" and CH.Theme.palette == "accounting")
run("AuctionIQ.UI.Page('analytics', 'perf')")
check("analytics opens Research, Performance", LUI.Section() == "research" and LUI.View() == "perf" and LUI.Group() == "Performance")
run("AuctionIQ.UI.Page('analytics', 'dead')")
check("a view that moved opens on its new tab: dead stock in Operations", LUI.Section() == "operations" and LUI.View() == "dead" and LUI.Group() == "Inventory")
run("AuctionIQ.UI.Page('markets')")
check("markets opens Research on compare prices", LUI.Section() == "research" and LUI.View() == "compare")
# Dashboard figures: queued crafts split into ready, short of reagents, and on other characters
run("""STUB.oldQueue = AuctionIQ.db.queue
AuctionIQ.db.queue = { { char = AuctionIQ.CharacterKey(), name = 'A', qty = 3, shop = {} },
  { char = AuctionIQ.CharacterKey(), name = 'B', qty = 2, shop = { { itemID = 987654, n = 5 } } },
  { char = 'Other-Realm', name = 'C', qty = 1, shop = {} } }""")
fig = CH.UI.DashboardFigures()
check("dashboard figures: queued crafts, ready, short, on other characters", fig.queued == 6 and fig.ready == 1 and fig.short == 1 and fig.elsewhere == 1)
work = list(CH.TradingUI.WorkPlan().values())
crafts = {w.task: w for w in work if w.kind == "craft"}
check("execution plan: crafts with their status, another character's marked switch", crafts["Craft A"].status == "ready to craft"
      and crafts["Craft B"].status == "buy reagents" and crafts["Craft C"].status == "switch character" and crafts["Craft A"].where == "Profession window")
wrows, wfoot = L.eval("AuctionIQ.LedgerUI.Rows('work', {})")
check("execution plan view: a row per task and a count by kind", len(list(wrows.values())) == len(work) and "3 crafts" in plain(wfoot))
run("AuctionIQ.UI.Page('today')")
qf = L.eval("AuctionIQ.UI.Pages().dashboard.d.figures.queued")
check("dashboard: the queued figure shows", plain(L.eval("AuctionIQ.UI.Pages().dashboard.d.figures.queued.value:GetText()")) == "6")
run("AuctionIQ.UI.Pages().dashboard.d.figures.queued.hit.scripts.OnClick()")
check("dashboard: clicking it opens Operations, Work queue", CH.LedgerUI.View() == "queue" and CH.LedgerUI.Section() == "operations")
run("AuctionIQ.db.queue = STUB.oldQueue; AuctionIQ.UI.Page('markets')")
check("tabs: Dashboard, Research, Operations, Accounting", [t[2] for t in L.eval("AuctionIQ.UI.TABS").values()] == ["Dashboard", "Research", "Operations", "Accounting"])
check("research sub-tabs: Markets, Professions, Performance", list(L.eval("AuctionIQ.UI.LayoutSubTabs()").values()) == ["Markets", "Professions", "Performance"])
run("AuctionIQ.UI.Page('operations')")
check("operations sub-tabs: Work queue, Inventory, Rules & routes", list(L.eval("AuctionIQ.UI.LayoutSubTabs()").values()) == ["Work queue", "Inventory", "Rules & routes"])
navshown = [b.label for b in L.eval("AuctionIQ.UI.Pages().ledger.nav").values() if b.shown]
check("the nav lists only the open sub-tab's views", LUI.Group() is not None and len(navshown) >= 1 and len(navshown) <= 3)
run("AuctionIQ.UI.Page('ledger')")
check("Accounting has no sub-tabs", len(list(L.eval("AuctionIQ.UI.LayoutSubTabs()").values())) == 0)
run("AuctionIQ.UI.Page('crafting')")
check("old crafting tab opens Research, Professions beside the nav", LUI.View() == "professions" and L.eval("AuctionIQ.UI.Pages().plan:IsShown()") is True)
mfoot = L.eval("select(2, AuctionIQ.LedgerUI.Rows('market', {}))")
mrows0 = list(L.eval("(AuctionIQ.LedgerUI.Rows('market', {}))").values())
check("market prices without the app come from TSM", len(mrows0) >= 1 and "TSM (60-day avg)" in plain(mfoot) )
run("OEMarketInfo = function(item, t) if item == 'item:301' then t.market = 25000; t.region = 24000; t.days = 1 end return t end")
oe = CH.Prices.Oribos(301)
check("Oribos Exchange read directly", oe.market == 25000 and oe.region == 24000)
run("STUB.savedPrices = STUB.prices; STUB.prices = {}; AuctionIQ.Prices.ClearCache()")
m301 = CH.Prices.MarketAny(301)
mfoot2 = L.eval("select(2, AuctionIQ.LedgerUI.Rows('market', {}))")
check("market prices fall back to Oribos Exchange without TSM data", m301.market == 25000 and m301.source == "oribos" and "Oribos Exchange" in plain(mfoot2))
run("STUB.prices = STUB.savedPrices; OEMarketInfo = nil; AuctionIQ.Prices.ClearCache()")
run("STUB.now = STUB.now - 2 * 86400; AuctionIQ.Scans.Record(301, { { price = 18000, qty = 40 } }, true); STUB.now = STUB.now + 2 * 86400")
run("AuctionIQ.Scans.Record(301, { { price = 22000, qty = 40 } }, true)")
mrows = L.eval("(AuctionIQ.LedgerUI.Rows('market', {}))")
r301 = [r for r in mrows.values() if r.id == 301]
mfoot3 = L.eval("select(2, AuctionIQ.LedgerUI.Rows('market', {}))")
check("market prices use your AH scans first", len(r301) == 1 and "+10%" in plain(r301[0].cells[5]) and "your AH scans" in plain(mfoot3))
# Compare prices: AH scan vs TSM vs Oribos (Data/Compare.lua)
tsm301 = CH.Prices.Raw("dbmarket", 301)
cr = CH.Compare.Row(301)
check("compare: realm prices side by side with a gap", cr.ah == 22000 and cr.tsm == tsm301 and cr.ahFresh and cr.gap is not None and abs(cr.gap - (22000 / tsm301 - 1)) < 1e-9)
run("OEMarketInfo = function(item, t) if item == 'item:301' then t.market = 40000; t.region = 30000 end return t end")
cr = CH.Compare.Row(301)
check("compare: Oribos joins and the gap is against the middle of TSM and Oribos", cr.oe == 40000 and cr.oeRegion == 30000 and abs(cr.gap - (22000 / ((tsm301 + 40000) / 2) - 1)) < 1e-9)
check("compare: well under the others reads cheap now", (cr.verdict == "cheap now") == (22000 <= 0.85 * (tsm301 + 40000) / 2))
run("AuctionIQ.db.scans[301].at = STUB.now - 2 * 86400")
cr = CH.Compare.Row(301)
check("compare: an old scan is shown but not judged", not cr.ahFresh and cr.gap is None and cr.verdict in ("agree", "disagree"))
crow = [r for r in L.eval("(AuctionIQ.LedgerUI.Rows('compare', {}))").values() if r.id == 301]
check("compare view lists the item with each source", len(crow) == 1 and "2 days" in plain(crow[0].cells[3]) and plain(crow[0].cells[8]) == cr.verdict)
check("compare: median of an even list", CH.Compare.Median(L.eval("{ 4, 1, 3, 2 }")) == 2.5)
run("OEMarketInfo = nil; AuctionIQ.db.scans = {}; AuctionIQ.Prices.ClearCache()")
tfoot = L.eval("select(2, AuctionIQ.LedgerUI.Rows('time', { days = 30 }))")
check("gold per hour moved to analytics", "hours" in plain(tfoot))
run("AuctionIQ.UI.Page('ledger')")
check("Accounting remembers its last view", LUI.Section() == "ledger" and LUI.View() == "report")
run("AuctionIQ.UI.Page('groups')"); run("AuctionIQ.UI.Page('plan')"); run("AuctionIQ.UI.Page('dashboard')")
check("old page names open the new tabs", CH.UI.IsShown())
nxt = list(CH.Next.List().values())
check("do next is ranked, leaking value first", len(nxt) > 0 and all(nxt[i].tier <= nxt[i + 1].tier for i in range(len(nxt) - 1)))
# Do next cards carry a button that does the job: queue the Concentration craft or the restock
run("""STUB.oldConcNow = AuctionIQ.ConcentrationNow
AuctionIQ.ConcentrationNow = function(p) if p.name == 'Test Alchemy' then return 1000, 1000 end return STUB.oldConcNow(p) end
AuctionIQ.db.characters['Alt-Realm'] = { name = 'Alt', class = 'MAGE', professions = { [99] = { name = 'Test Alchemy', scan = { rows = {
  { recipeID = 10, name = 'Test Flask', item = 100, made = 1, profit = 1000, perPoint = 50, concProfit = 15000, concentration = 300, concQuality = 2,
    accounts = { cost = 500, reagents = { { itemID = 201, n = 2 } }, queue = { { itemID = 201, slot = 1, n = 2 } } },
    concAccounts = { cost = 500, reagents = { { itemID = 201, n = 2 } }, queue = { { itemID = 201, slot = 1, n = 2 } } } } } } } } }
AuctionIQ.Queue.Clear()""")
spend = [e for e in CH.Next.List().values() if e.title == "Spend Concentration" and "Alt" in e.detail]
check("do next: full Concentration names the best craft per point and how many", len(spend) == 1 and "x3" in spend[0].detail and spend[0].act is not None)
acted = L.eval("(function() for _, e in ipairs(AuctionIQ.Next.List()) do if e.title == 'Spend Concentration' and e.act and e.detail:find('Alt') then return { e.act.run() } end end end)()")
check("do next: the button says what it did, for the card", acted[1] is True and "Queued 3 x Test Flask with Concentration for Alt" == acted[2])
qe = list(CH.db.queue.values())
check("do next: its button queues that craft with Concentration for that character", len(qe) == 1 and qe[0].char == "Alt-Realm" and qe[0].qty == 3
      and qe[0].concentration == 300 and qe[0].reagents[1].slot == 1)
k = L.eval("{ AuctionIQ.Queue.ScanRowFor(100) }")
check("do next: a restock finds the saved scan that makes the item", k[1] == "Alt-Realm" and k[3].recipeID == 10)
run("AuctionIQ.UI.Page('today')")
d = L.eval("AuctionIQ.UI and nil")
run("AuctionIQ.Queue.Clear(); AuctionIQ.db.characters['Alt-Realm'] = nil; AuctionIQ.ConcentrationNow = STUB.oldConcNow")
check("crafting tab text has Concentration and best crafts", "Concentration" in plain(CH.UI.CraftingText()) and "Best crafts" in plain(CH.UI.CraftingText()))
check("the report still has everything", "Best crafts" in plain(CH.UI.BriefingText()) and "Gold" in plain(CH.UI.BriefingText()))

# recipe scan: how many you can make now, with finishing reagents and Concentration
run("STUB.bags[901] = 10; STUB.bags[902] = 3; STUB.bags[903] = 1")
cr = L.eval("{ AuctionIQ.Scan.Craftable({ accounts = { reagents = { { itemID = 901, n = 2 }, { itemID = 902, n = 1 } } }, concAccounts = { reagents = { { itemID = 901, n = 2 }, { itemID = 903, n = 1 } } }, concentration = 300 }, 650) }")
check("scan: can make counts the scarcest reagent", cr[1] == 3 and cr[3] == 902)
check("scan: with Concentration, a finishing reagent or the points cap it", cr[2] == 1 and cr[4] == 903)
cr2 = L.eval("{ AuctionIQ.Scan.Craftable({ concAccounts = { reagents = { { itemID = 901, n = 1 } } }, concentration = 300 }, 650) }")
check("scan: Concentration points can be the limit", cr2[2] == 2 and cr2[4] == "concentration")

# paths: profession trees that report every node at 0,0 get a tidy tree layout
lay = L.eval("AuctionIQ.TreeView.Layout({ nodes = { 1, 2, 3, 4 } }, { [1] = { x = 0, y = 0 }, [2] = { x = 0, y = 0, parent = 1 }, [3] = { x = 0, y = 0, parent = 1 }, [4] = { x = 0, y = 0, parent = 2 } })")
check("paths tree: root on top, children a row below, spread out", lay[1].y == 0 and lay[2].y == 1 and lay[4].y == 2 and lay[2].x != lay[3].x and lay[1].x == (lay[2].x + lay[3].x) / 2)
lay2 = L.eval("AuctionIQ.TreeView.Layout({ nodes = { 1, 2 } }, { [1] = { x = 10, y = 5 }, [2] = { x = 40, y = 90, parent = 1 } })")
check("paths tree: the game's own positions win when it gives them", lay2[2].x == 40 and lay2[2].y == 90)

# Queue first crafts and work orders
run("AuctionIQ.Queue.Clear(); STUB.recipeIDs = { 10 }; local g = C_TradeSkillUI.GetRecipeInfo; STUB.oldInfo = g; C_TradeSkillUI.GetRecipeInfo = function(id) local i = g(id); if id == 10 then i.firstCraft = true end return i end")
n1 = L.eval("(AuctionIQ.Queue.FillFirstCrafts())")
fq = list(CH.db.queue.values())
check("first crafts: unmade recipes queue once each, cheapest, marked 1KP", n1 == 1 and fq[0].firstCraft and fq[0].qty == 1 and not fq[0].concentration)
fc = list(CH.Orders.FirstCrafts().values())
check("first crafts list: each recipe with its cheapest reagents and what the point costs", len(fc) == 1 and fc[0].recipeID == 10 and fc[0].cost == fq[0].cost
      and abs(fc[0].net - ((fc[0].value or 0) - fc[0].cost)) < 1e-6)
run("AuctionIQ.Queue.Clear(); AuctionIQ.ScanUI.Open(); AuctionIQ.ScanUI.SetMode('first')")
frows = list(CH.ScanUI.Refresh().values())
check("scan tab: First crafts lists the recipe", CH.ScanUI.IsShown() and CH.ScanUI.Mode() == "first" and len(frows) == 1 and "net=" in frows[0])
check("scan tab: Queue all queues every first craft", CH.ScanUI.QueueAll() == 1 and list(CH.db.queue.values())[0].firstCraft)
run("C_TradeSkillUI.GetRecipeInfo = STUB.oldInfo; STUB.recipeIDs = nil; AuctionIQ.Queue.Clear()")
run("""C_CraftingOrders = { GetCrafterOrders = function() return { { orderID = 77, spellID = 10, minQuality = 1, tipAmount = 50000000, consortiumCut = 0, customerName = 'Patron', reagents = {} } } end, ClaimOrder = function(id) STUB.claimed = id; STUB.claimedOrder = { orderID = id, isFulfillable = false, reagents = {} } end, FulfillOrder = function(id) STUB.fulfilled = id end,
  GetClaimedOrder = function() return STUB.claimedOrder end }""")
n2 = L.eval("(AuctionIQ.Queue.FillOrders())")
oq = list(CH.db.queue.values())
check("orders: a paying order is queued with its order ID", n2 == 1 and oq[0].orderID == "77")
check("orders: the button goes Claim first", CH.Queue.OrderStep(oq[0]) == "Claim")
run("AuctionIQ.Queue.Craft(AuctionIQ.db.queue[1])")
check("orders: Claim claims it, then Craft", L.eval("STUB.claimed") == 77 and CH.Queue.OrderStep(oq[0]) == "Craft")
run("AuctionIQ.Queue.Craft(AuctionIQ.db.queue[1])")
check("orders: crafting passes the claimed order's ID", L.eval("STUB.crafted.id") == 10 and L.eval("STUB.crafted.order") == 77)
run('STUB.claimedOrder.isFulfillable = true; STUB.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 10); STUB.RunTimers()')
check("orders: after the craft it's Turn in", CH.Queue.OrderStep(oq[0]) == "Turn in")
run("AuctionIQ.Queue.Craft(AuctionIQ.db.queue[1])")
check("orders: Turn in fulfils it and it leaves the queue", L.eval("STUB.fulfilled") == 77 and CH.Queue.Count() == 0)
run('STUB.Fire("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 5, 77)')
check("orders: a turn-in the game refuses comes back to the top", CH.Queue.Count() == 1 and CH.Queue.OrderStep(CH.db.queue[1]) == "Turn in")
run("AuctionIQ.Queue.Clear(); STUB.claimed = nil; STUB.fulfilled = nil; STUB.claimedOrder = nil; C_CraftingOrders.GetClaimedOrder = nil")
# One button: Next step walks claim, craft, turn in
run("AuctionIQ.Queue.FillOrders()")
st = L.eval("(AuctionIQ.Queue.DoNext())")
check("next step: first click claims", st == "Claim" and L.eval("STUB.claimed") == 77)
run('STUB.Fire("CRAFTINGORDERS_CLAIM_ORDER_RESPONSE", 3, 77)')
check("next step: a refused claim goes back to Claim", CH.Queue.OrderStep(CH.db.queue[1]) == "Claim")
run("AuctionIQ.Queue.DoNext()")
run("C_CraftingOrders.GetClaimedOrder = function() return { orderID = 77, isFulfillable = false } end")
st = L.eval("(AuctionIQ.Queue.DoNext())")
check("next step: then crafts", st == "Craft" and L.eval("STUB.crafted.id") == 10)
run("C_CraftingOrders.GetClaimedOrder = function() return { orderID = 77, isFulfillable = true } end")
check("next step: the game saying it's done means Turn in", CH.Queue.OrderStep(CH.db.queue[1]) == "Turn in")
st = L.eval("(AuctionIQ.Queue.DoNext())")
check("next step: then turns it in", st == "Turn in" and L.eval("STUB.fulfilled") == 77 and CH.Queue.Count() == 0)
run("C_CraftingOrders.GetClaimedOrder = nil")
# Crafting an order crafts into the live claimed order, leaves out the customer's reagents, and only counts once the game says it's done
run("""AuctionIQ.Queue.Clear(); STUB.claimed = nil; STUB.fulfilled = nil; STUB.crafted = nil; STUB.created = nil; STUB.completed = nil
AuctionIQ.Queue.FillOrders(); AuctionIQ.Queue.DoNext()
STUB.claimedOrder = { orderID = 77, isFulfillable = false, reagents = { { reagentInfo = { reagent = { itemID = 201 } } } } }
C_CraftingOrders.GetClaimedOrder = function() return STUB.claimedOrder end
ProfessionsFrame = ProfessionsFrame or { IsShown = function() return true end }
ProfessionsFrame.OrdersPage = ProfessionsFrame.OrdersPage or {}
ProfessionsFrame.OrdersPage.OrderView = { order = { orderID = 77 }, IsShown = function() return true end,
  CreateButton = { Click = function() STUB.created = true end, IsEnabled = function() return true end },
  CompleteOrderButton = { Click = function() STUB.completed = true end, IsShown = function() return true end, IsEnabled = function() return true end } }""")
st = L.eval("(AuctionIQ.Queue.DoNext())")
check("order craft: crafts into the claimed order", st == "Craft" and L.eval("STUB.crafted.order") == 77)
check("order craft: the customer's reagents aren't sent as ours", L.eval("(function() for _, r in ipairs(STUB.crafted.reagents) do if r.itemID == 201 then return false end end return true end)()"))
# an order needing rank 2 that these reagents only reach with Concentration: craft with it on
run("""STUB.crafted = nil; STUB.claimedOrder.minQuality = 2; STUB.extraSkill = -1000; AuctionIQ.Queue.DoNext(); STUB.extraSkill = nil""")
check("order craft: turns Concentration on when the order's rank needs it", L.eval("STUB.crafted.conc") is True and L.eval("STUB.crafted.order") == 77)
run("STUB.claimedOrder.minQuality = 9; STUB.crafted = nil")
st = L.eval("{ AuctionIQ.Queue.DoNext() }")
check("order craft: refuses, and says why, when even Concentration can't reach the rank", L.eval("STUB.crafted") is None and "needs rank 9" in str(st[2]))
run("STUB.claimedOrder.minQuality = nil")
run('STUB.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 10); STUB.RunTimers()')
check("order craft: a craft that didn't go into the order stays Craft", CH.Queue.OrderStep(CH.db.queue[1]) == "Craft")
run('STUB.claimedOrder.isFulfillable = true')
st = L.eval("(AuctionIQ.Queue.DoNext())")
check("order craft: Turn in fulfils the claimed order", st == "Turn in" and L.eval("STUB.fulfilled") == 77 and CH.Queue.Count() == 0)
run("C_CraftingOrders.GetClaimedOrder = nil; ProfessionsFrame.OrdersPage.OrderView = nil")
run("STUB.claimed = nil; AuctionIQ.ScanUI.Open(); AuctionIQ.ScanUI.SetMode('orders'); AuctionIQ.ScanUI.Next()")
check("next step button: queues the paying orders and claims the first", CH.Queue.Count() == 1 and L.eval("STUB.claimed") == 77)
run("""STUB.viewed = nil; ProfessionsFrame = ProfessionsFrame or { IsShown = function() return true end }
ProfessionsFrame.craftingOrdersTabID = 3; ProfessionsFrame.tab = 1
ProfessionsFrame.GetTab = function(self) return self.tab end; ProfessionsFrame.SetTab = function(self, t) self.tab = t end
ProfessionsFrame.OrdersPage = ProfessionsFrame.OrdersPage or {}
ProfessionsFrame.OrdersPage.ViewOrder = function(_, o) STUB.viewed = o.orderID end
AuctionIQ.Orders.Open({ orderID = 77 }, 10)""")
check("clicking an order opens it on the Crafting Orders tab", L.eval("STUB.viewed") == 77 and L.eval("ProfessionsFrame.tab") == 3)
run("AuctionIQ.ScanUI.SetMode('recipes'); AuctionIQ.Queue.Clear()")
# Orders tab: every listed order with what it pays and whether it gives a knowledge point
run("""STUB.items = STUB.items or {}
C_Item.GetItemNameByID = function(id) if id == 901 then return "Alchemist's Knowledge Notes" end if id == 902 then return "Spark Shard" end end
STUB.prices['i:902'] = { formula_value = 200000 }
C_CraftingOrders.GetCrafterOrders = function() return {
  { orderID = 77, spellID = 10, minQuality = 1, tipAmount = 50000000, consortiumCut = 0, customerName = 'Pat', orderType = 2, reagents = {} },
  { orderID = 78, spellID = 10, minQuality = 1, tipAmount = 100, consortiumCut = 0, orderType = 3, reagents = {},
    npcOrderRewards = { { itemLink = 'item:901', count = 1 }, { itemLink = 'item:902', count = 2 } } },
  { orderID = 79, spellID = 10, minQuality = 9, tipAmount = 100, consortiumCut = 0, orderType = 3, reagents = {} } } end""")
ol = list(CH.Orders.List().values())
by = {o.orderID: o for o in ol}
check("order list: every order, the ones you can fill first", len(ol) == 3 and ol[-1].orderID == 79 and not by[79].ok)
check("order list: a knowledge reward marks it 1KP and sorts ahead of plain profit", by[78].kp and ol[0].orderID == 78 and not by[77].kp)
check("order list: sellable rewards are valued after the cut, knowledge isn't", abs(by[78].rewardValue - 2 * CH.Prices.Get("chvalue", "i:902") * CH.AH_CUT) < 1
      and [r.value for r in by[78].rewards.values()][0] is None)
check("order list: profit and reagent cost come from the advisor's best craft", by[77].profit == by[77].row.profit and by[77].cost == by[77].row.cost and by[77].profit > 0)
check("order list: who it's from", by[77]["from"] == "Pat" and by[78]["from"] == "Patron")
run("AuctionIQ.ScanUI.SetMode('orders')")
orows = list(CH.ScanUI.Refresh().values())
check("scan tab: lists orders with 1KP flagged", len(orows) == 3 and "kp=true" in orows[0])
tip = [plain(l[1]) for l in CH.ScanUI.OrderLines(by[78]).values()]
check("scan tab hover: the knowledge reward is named", any("Knowledge Notes" in t and "knowledge" in t for t in tip))
run("AuctionIQ.Queue.Clear()")
check("scan tab: Queue all queues orders that pay or give knowledge", CH.ScanUI.QueueAll() == 2)
run("AuctionIQ.Queue.Clear(); STUB.oldCount = C_Item.GetItemCount; C_Item.GetItemCount = function() return 0 end")
nohave = list(CH.Orders.List().values())
check("orders: each says whether you hold the reagents, and which are missing", not nohave[0].have and len(list(nohave[0].missing.values())) > 0)
CH.ScanUI.Refresh(); check("orders: Queue all skips orders you don't have the reagents for", CH.ScanUI.QueueAll() == 0)
tipm = [plain(l[1]) for l in CH.ScanUI.OrderLines(nohave[0]).values()]
check("orders hover: lists the missing reagents", "Missing reagents" in tipm)
run("C_Item.GetItemCount = STUB.oldCount; AuctionIQ.Queue.Clear(); AuctionIQ.ScanUI.Refresh(); AuctionIQ.ScanUI.QueueAll()")
# a recipe this character hasn't learned: never "can make", never queued
run("""STUB.oldInfo = C_TradeSkillUI.GetRecipeInfo
C_TradeSkillUI.GetRecipeInfo = function(id) local i = STUB.oldInfo(id); if id == 10 and i then i.learned = false end; return i end""")
nl = list(CH.Orders.List().values())
check("orders: an unlearned recipe isn't craftable", all(not o.ok and o.learned is False for o in nl))
nlrows = list(CH.ScanUI.Refresh().values())
check("orders: an unlearned recipe says so and Queue all skips it", CH.ScanUI.QueueAll() == 0
      and "You haven't learned this recipe." in [plain(l[1]) for l in CH.ScanUI.OrderLines(nl[0]).values()])
run("C_TradeSkillUI.GetRecipeInfo = STUB.oldInfo; AuctionIQ.Queue.Clear(); AuctionIQ.ScanUI.Refresh(); AuctionIQ.ScanUI.QueueAll()")
# orders from an older expansion are tagged, and Older: hidden leaves them out
run("""STUB.oldLine = C_TradeSkillUI.GetTradeSkillLineForRecipe
C_TradeSkillUI.GetTradeSkillLineForRecipe = function(id) if id == 10 then return 2871, 'Khaz Algar Alchemy' end return 2906, 'Midnight Alchemy' end
STUB.oldInfos = C_TradeSkillUI.GetChildProfessionInfos
C_TradeSkillUI.GetChildProfessionInfos = function() return { { professionID = 2906, expansionName = 'Midnight' }, { professionID = 2871, expansionName = 'Khaz Algar' } } end""")
olist = list(CH.Orders.List().values())
check("orders: each order knows its expansion and whether it's the current one", olist[0].expansion == "Khaz Algar" and not olist[0].current)
run("AuctionIQ.ScanUI.ToggleOlder()")
check("orders: Older: hidden leaves older-expansion orders out", len(list(CH.ScanUI.Refresh().values())) == 0)
run("AuctionIQ.ScanUI.ToggleOlder()")
check("orders: Older: shown brings them back", len(list(CH.ScanUI.Refresh().values())) == 3)
run("C_TradeSkillUI.GetTradeSkillLineForRecipe = STUB.oldLine; C_TradeSkillUI.GetChildProfessionInfos = STUB.oldInfos")
run("AuctionIQ.ScanUI.SortBy('from')")
srt = list(CH.ScanUI.Refresh().values())
check("scan tab: clicking a header sorts by that column", srt[0].startswith("Test Flask from=Pat ") and "from=Patron" in srt[-1])
run("AuctionIQ.ScanUI.SortBy('from')")
check("scan tab: clicking the same header flips it", "from=Patron" in list(CH.ScanUI.Refresh().values())[0])
run("AuctionIQ.ScanUI.SetMode('recipes')")
check("scan tab: back to recipes", CH.ScanUI.Mode() == "recipes" and len(list(CH.ScanUI.Refresh().values())) > 0)
# Fetching: every kind of order is asked for in turn and kept, like CraftSim, even when the game lists only the last one
run("""STUB.requests = {}; Enum.CraftingOrderResult = { Ok = 0, ThrottleViolation = 3, Timeout = 4 }
C_TradeSkillUI.GetChildProfessionInfo = function() return { profession = 3 } end
C_CraftingOrders.RequestCrafterOrders = function(req)
  table.insert(STUB.requests, req.orderType)
  STUB.lastList = { { orderID = 500 + req.orderType, spellID = 10, minQuality = 1, tipAmount = 100, consortiumCut = 0, orderType = req.orderType, reagents = {} } }
  local throttle = req.orderType == 0 and not STUB.throttled
  if throttle then STUB.throttled = true end
  C_Timer.After(0, function() req.callback(throttle and 3 or 0) end)
end
STUB.oldList = C_CraftingOrders.GetCrafterOrders
C_CraftingOrders.GetCrafterOrders = function() return STUB.lastList or {} end
AuctionIQ.Orders.cache = {}
STUB.fetched = nil
AuctionIQ.Orders.Fetch(function(n) STUB.fetched = n end)
for i = 1, 40 do STUB.Fire("CRAFTINGORDERS_CAN_REQUEST"); STUB.RunTimers() end""")
check("orders fetch: asks for patron, personal, public and guild, retrying a throttle", L.eval("STUB.fetched") == 4
      and len(list(L.eval("STUB.requests").values())) == 5)
check("orders fetch: the list holds every kind, not just the last one shown", len(list(CH.Orders.List().values())) == 4)
check("/aiq orders explains each order without erroring", L.eval("(pcall(AuctionIQ.Orders.Debug))"))
check("orders fetch: order IDs compare as text", L.eval("AuctionIQ.Orders.Same(77, '77')") and not L.eval("AuctionIQ.Orders.Same(77, nil)"))
run("C_CraftingOrders.GetCrafterOrders = STUB.oldList; C_CraftingOrders.RequestCrafterOrders = nil; AuctionIQ.Orders.cache = {}")
run("AuctionIQ.Queue.Clear(); C_CraftingOrders = nil; C_Item.GetItemNameByID = nil")

# warbound and soulbound items can't go on the AH: no value, and the tooltip says so
run("C_Item.GetItemInfo = function(id) if id == 302 then return 'Warbound Cloak', nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, 7 end end")
inv2 = {e.id: e for e in LG.Inventory().values()}
check("warbound items count as held but worth nothing", 302 in inv2 and inv2[302].bound and inv2[302].value == 0)
check("the tooltip says it can't go on the AH", "can't go on the AH" in plain(CH.TooltipLines("i:302")[1][2]))
check("other items keep their value", CH.Unsellable(100) is False or CH.Unsellable(100) is None or not CH.Unsellable(100))
run("C_Item.GetItemInfo = nil")

# Settings: what the commands did, as buttons; operations and price sources without commands
S = CH.Settings
run("AuctionIQ.UI.Page('settings')")
names = list(CH.SettingsUI.Refresh().values())
check("settings: opens from the window and lists the operations, Default first", names[0] == "Default" and "Crafted" in names)
was = S.Get("coins")
run("AuctionIQ.Settings.Flip('coins')")
check("settings: a toggle does what /aiq coins did", S.Get("coins") == (not was) and L.eval("AuctionIQ.db.settings.coins") == (not was))
run("AuctionIQ.Settings.Flip('coins')")
run("AuctionIQ.Settings.DailyCap(20)")
check("settings: gold a day cap", L.eval("AuctionIQ.db.settings.scan.dailyCap") == 20)
check("settings: a new operation copies Default", S.NewOp("Flasks") == "Flasks" and CH.Groups.Store().ops.Flasks.floorPct == CH.Groups.Store().ops.Default.floorPct)
check("settings: names can't repeat", S.NewOp("Flasks")[0] is None)
run("AuctionIQ.Settings.OpStep('Flasks', 'priceReset', 1); AuctionIQ.Settings.OpStep('Flasks', 'duration', 1); AuctionIQ.Settings.OpStep('Flasks', 'undercut', 1)")
fl = CH.Groups.Store().ops.Flasks
check("settings: picks cycle and numbers step", fl.priceReset == "minPrice" and fl.duration == 3 and fl.undercut == 101)
ok, err = S.SetOpFormula("Flasks", "minPrice", "max(")
check("settings: a bad formula is refused with the reason", ok is False and err and fl.minPrice is None)
check("settings: a good formula saves", S.SetOpFormula("Flasks", "minPrice", "80% chvalue") is True and fl.minPrice == "80% chvalue")
run("AuctionIQ.Groups.Assign('Crafted', 'Flasks')")
check("settings: renaming keeps the groups that use it", S.RenameOp("Flasks", "Flask rules") == "Flask rules" and CH.Groups.Store().assign.Crafted == "Flask rules")
check("settings: built-in operations can't be deleted", S.DeleteOp("Default")[0] is None and S.DeleteOp("Crafted")[0] is None)
check("settings: deleting one sends its groups back to inheriting", S.DeleteOp("Flask rules") == 1 and CH.Groups.Store().assign.Crafted is None)
check("settings: a price source saves", S.SetSource("MyFloor", "max(vendorsell, 1g)") is True and CH.Formula.Custom().myfloor == "max(vendorsell, 1g)")
check("settings: a source can't take a built-in name", S.SetSource("dbmarket", "1g")[0] is False)
check("settings: a source with a bad formula is refused", S.SetSource("broken", "min(")[0] is False)
check("settings: the source works in formulas", CH.Formula.Value("myfloor", 302) == 10000)
run("AuctionIQ.Settings.DeleteSource('myfloor')")
check("settings: delete a source", CH.Formula.Custom().myfloor is None)
run("AuctionIQ.Settings.UseTSM(false)")
check("settings: TSM groups off", CH.Groups.Store().useTSM is False)
run("AuctionIQ.Settings.UseTSM(true)")

# layout: nothing outside its panel, no one-line text cut off, button labels fit
L.execute((ROOT / "tests" / "layout_audit.lua").read_text())
audit_all = []
def audit(where):
    roots = L.eval("(function() local r = {} for _, f in ipairs(STUB.frames) do if (f.parent == nil or f.parent == UIParent) and f.w > 0 then table.insert(r, f) end end return r end)()")
    for p in L.eval("STUB.Audit")(roots).values():
        audit_all.append(where + ": " + p)
for tab in ["today", "research", "operations", "markets", "crafting", "trading", "analytics", "ledger", "report", "settings"]:
    run(f"AuctionIQ.UI.Page('{tab}')")
    audit(tab)
for v in ["compare", "inventory", "sales", "income", "resale", "purchases", "expense", "expired", "cancelled", "pl", "holdings", "overhead", "market", "rivals", "when", "par", "dead", "time", "perf", "results", "post", "mail", "performance", "drivers", "capital", "crafting", "scenarios", "queue", "shopping", "professions", "paths", "work", "plans"]:
    run(f"AuctionIQ.UI.Page('ledger', '{v}')")
    audit("view " + v)
check("resize: a grip in the corner, the size kept between 0.6 and 1.6 and saved",
      CH.UI.Pages().ledger.parent.sizer is not None and CH.UI.SetScale(3) == 1.6 and CH.db.settings.window.scale == 1.6 and CH.UI.SetScale(1) == 1)
run("AuctionIQ.UI.Page('ledger', 'sales')")
check("resize: taller shows more table rows, the footer stays inside the page",
      CH.UI.SetHeight(900) == 900 and CH.LedgerUI.SetRows(None) > 30 and CH.UI.Pages().ledger.h == 900 - 54
      and CH.UI.SetHeight(100) == 600 and CH.LedgerUI.SetRows(None) == 25)
run("AuctionIQ.UI.SetHeight(900)")
for tab in ["research", "operations", "ledger"]:
    run(f"AuctionIQ.UI.Page('{tab}')")
    audit("tall " + tab)
run("AuctionIQ.UI.SetHeight(600)")
navs = list(CH.UI.Pages().ledger.nav.values())
long = [plain(b.text.t) for b in navs if b.text and not b.fits]
check("nav: every label fits its button on one line", len(navs) > 20 and long == [] and all(b.text.wrap is False for b in navs if b.text))
run("AuctionIQ.UI.Page('today')")
for w in ["ScanUI", "QueueUI", "LogUI"]:
    run(f"if AuctionIQ.{w} and AuctionIQ.{w}.Toggle then pcall(AuctionIQ.{w}.Toggle) end")
    audit(w)
# Review fixes ---------------------------------------------------------------------------------
# 1. a browse doesn't make an old buying ladder look fresh, and a browse at a different price drops it
run("""AuctionIQ.db.scans = AuctionIQ.db.scans or {}
AuctionIQ.Scans.Record(950, { { price = 10000, qty = 100 }, { price = 20000, qty = 100 } }, true)""")
lad, at = L.eval("AuctionIQ.Scans.Depth(950)")
run("AuctionIQ.db.scans[950].ladderAt = AuctionIQ.db.scans[950].ladderAt - 7200; AuctionIQ.db.scans[950].at = AuctionIQ.db.scans[950].at - 7200")
run("AuctionIQ.Scans.RecordBrowse(950, 10000, 200)")
lad2, at2 = L.eval("AuctionIQ.Scans.Depth(950)")
check("scans: a browse at the same price keeps the ladder with its own, older time", lad2 is not None and L.eval("time()") - at2 >= 7200)
run("AuctionIQ.Scans.RecordBrowse(950, 90000, 50)")
check("scans: a browse at a different cheapest price drops the stale ladder", L.eval("AuctionIQ.Scans.Depth(950)") is None)
# 2. Open all stops when the inbox stops changing (bags full) instead of looping, and says why
run("""STUB.loots = 0; STUB.openDone = nil
function GetInboxNumItems() return 1 end
function GetInboxHeaderInfo(i) return nil, nil, 'x', 's', 0, 0, 1, 1 end
function AutoLootMailItem() STUB.loots = STUB.loots + 1 end
AuctionIQ.Mail.OpenAll(function(n, gold, why) STUB.openDone = { n = n, why = why } end)
for i = 1, 20 do STUB.RunTimers() end""")
check("mail: Open all gives up on a mail it can't take, and says why", L.eval("STUB.openDone") is not None and L.eval("STUB.loots") <= 4
      and "bags" in str(L.eval("STUB.openDone.why")) and L.eval("STUB.openDone.n") == 0)
run("""STUB.loots = 0; STUB.openDone = nil; STUB.mails = 2
function GetInboxNumItems() return STUB.mails end
function GetInboxHeaderInfo(i) return nil, nil, 'x', 's', 100, 0, 1, nil end
function AutoLootMailItem() STUB.loots = STUB.loots + 1; STUB.mails = STUB.mails - 1 end
AuctionIQ.Mail.OpenAll(function(n, gold, why) STUB.openDone = { n = n, why = why } end)
for i = 1, 20 do STUB.RunTimers() end""")
check("mail: Open all counts the mails it really took", L.eval("STUB.openDone.n") == 2 and L.eval("STUB.openDone.why") is None)
run("GetInboxNumItems = nil; GetInboxHeaderInfo = nil; AutoLootMailItem = nil")
# 3. the same name on two realms: separate sellers, and only this realm counts
run("""AuctionIQ.db.auctions = {}
AuctionIQ.Auction.RecordOwned({ { id = 951, qty = 3 } })
STUB.oldRealm = GetRealmName; GetRealmName = function() return 'Other Realm' end
AuctionIQ.Auction.RecordOwned({ { id = 951, qty = 7 } })""")
check("auctions: the same name on another realm doesn't overwrite this realm's record", L.eval("AuctionIQ.Auction.Listed(951)") == 7)
run("GetRealmName = STUB.oldRealm")
check("auctions: each realm counts its own listings", L.eval("AuctionIQ.Auction.Listed(951)") == 3)
run("AuctionIQ.db.auctions = {}")
# 5. the ledger sees a record that changed without changing length
run("""STUB.oldSales = TradeSkillMasterDB["r@Emerald Dream@internalData@csvSales"]
TradeSkillMasterDB["r@Emerald Dream@internalData@csvSales"] = [[itemString,stackSize,quantity,price,otherPlayer,player,time,source\ni:952,1,1,10000,Bob,Courtizy,100,Auction]]
""")
p1 = L.eval("(function() for _, r in ipairs(AuctionIQ.Ledger.Records('Sales')) do if r.id == 952 then return r.price end end end)()")
run("""TradeSkillMasterDB["r@Emerald Dream@internalData@csvSales"] = [[itemString,stackSize,quantity,price,otherPlayer,player,time,source\ni:952,1,1,90000,Bob,Courtizy,100,Auction]]
""")
p2 = L.eval("(function() for _, r in ipairs(AuctionIQ.Ledger.Records('Sales')) do if r.id == 952 then return r.price end end end)()")
check("ledger: an edited record of the same length is read again", p1 == 10000 and p2 == 90000)
run("""TradeSkillMasterDB["r@Emerald Dream@internalData@csvSales"] = STUB.oldSales; AuctionIQ.Ledger.ClearStats()""")

# Shopping: buy the queue's reagents at the AH, quoted first, confirmed on a second click
run("""STUB.buys = {}
C_AuctionHouse.StartCommoditiesPurchase = function(id, n) table.insert(STUB.buys, { 'start', id, n }) end
C_AuctionHouse.ConfirmCommoditiesPurchase = function(id, n) table.insert(STUB.buys, { 'confirm', id, n }) end
STUB.prices['i:981'] = { mat = 10000 }; STUB.prices['i:982'] = { mat = 10000 }; AuctionIQ.Prices.ClearCache()
AuctionIQ.AuctionUI.Build()""")
d1 = L.eval("AuctionIQ.AuctionUI.DecideBuy({ itemID = 981, need = 5, have = 1, buy = 4 }, { { price = 10500, qty = 10 } })")
d2 = L.eval("AuctionIQ.AuctionUI.DecideBuy({ itemID = 982, need = 5, have = 0, buy = 5 }, { { price = 20000, qty = 10 } })")
check("shopping: buys at the live price, skips one far over the usual price", d1.action == "buy" and d1.qty == 4 and d1.unit == 10500
      and d2.action == "skip" and "100%" in d2.why)
d3 = L.eval("AuctionIQ.AuctionUI.DecideBuy({ itemID = 981, need = 10, have = 0, buy = 10 }, { { price = 10500, qty = 4 } })")
check("shopping: only the listed units are priced, the rest shown as short", d3.action == "buy" and d3.qty == 4 and d3.cost == 42000 and d3.short == 6)
run("""STUB.oldSL = AuctionIQ.Queue.ShoppingList; STUB.oldSearch = AuctionIQ.Auction.Search
AuctionIQ.Queue.ShoppingList = function() return { { itemID = 981, need = 5, have = 1, buy = 4 }, { itemID = 982, need = 5, have = 0, buy = 5 } } end
AuctionIQ.Auction.Search = function(id, done) done(id == 981 and { { price = 10500, qty = 10 } } or { { price = 20000, qty = 10 } }) end
AuctionIQ.AuctionUI.ShopScan(); for i = 1, 5 do STUB.RunTimers() end""")
plan = L.eval("AuctionIQ.AuctionUI.Plan()")[0]
check("shopping: Shop queue lists the queue's buys first", plan[1].id == 981 and plan[1].d.action == "buy" and plan[2].d.action == "skip")
run("AuctionIQ.AuctionUI.BuyNext()")
check("shopping: the first click asks for a quote, nothing bought yet", L.eval("#STUB.buys") == 1 and L.eval("STUB.buys[1][1]") == "start" and L.eval("STUB.buys[1][3]") == 4)
run("STUB.Fire('COMMODITY_PRICE_UPDATED', 10500, 42000)")
run("AuctionIQ.AuctionUI.BuyNext()")
check("shopping: the second click confirms the quoted buy", L.eval("STUB.buys[2][1]") == "confirm" and not plan[1].done)
run("STUB.Fire('COMMODITY_PURCHASE_SUCCEEDED')")
check("shopping: done only once the AH says it went through", plan[1].done and not plan[1].failed and "bought" in plan[1].d.why)
run("""AuctionIQ.Queue.ShoppingList = STUB.oldSL; AuctionIQ.Auction.Search = STUB.oldSearch
local plan = AuctionIQ.AuctionUI.Plan(); for k in pairs(plan) do plan[k] = nil end
C_AuctionHouse.StartCommoditiesPurchase = nil; C_AuctionHouse.ConfirmCommoditiesPurchase = nil; AuctionIQ.Depth.Forget()""")

# UI pass: visible scroll position, and mail says Sent only once the game confirms it
run("""STUB.sb = AuctionIQ.Window.ScrollBar(UIParent, 100, -10, 100)
STUB.sb:Set(17, 17, 83)""")
check("scroll bar: says which rows are showing", L.eval("STUB.sb.text") == "18-34 of 83")
run("STUB.sb:Set(0, 17, 10)")
check("scroll bar: hides when everything fits", L.eval("STUB.sb.text") is None)
run("""STUB.oldNextTo = AuctionIQ.Mail.NextTo; STUB.oldSendNext = AuctionIQ.Mail.SendNext
AuctionIQ.Mail.NextTo = function() return 'Luxaren', { { id = 302, count = 1 } } end
AuctionIQ.Mail.SendNext = function() return 'Luxaren', 1 end
STUB.oldOutbox = AuctionIQ.Mail.Outbox; AuctionIQ.Mail.Outbox = function() return { Luxaren = { { id = 302, count = 1 } } } end
AuctionIQ.MailUI.Build(); AuctionIQ.MailUI.Refresh()""")
check("mail: the button names who the next mail goes to", plain(L.eval("AuctionIQ.MailUI.Build().sendButton.label")) == "Send: Luxaren")
run("AuctionIQ.MailUI.Build().sendButton.scripts.OnClick()")
check("mail: sending, not sent, until the game says so", L.eval("AuctionIQ.MailUI.sending ~= nil") is True)
run("STUB.Fire('MAIL_SEND_SUCCESS')")
check("mail: sent once the game confirms it", L.eval("AuctionIQ.MailUI.sending") is None and "Sent 1 to Luxaren" in plain(L.eval("AuctionIQ.MailUI.Build().status:GetText()")))
run("AuctionIQ.Mail.NextTo = STUB.oldNextTo; AuctionIQ.Mail.SendNext = STUB.oldSendNext; AuctionIQ.Mail.Outbox = STUB.oldOutbox")

# Mail: reagents a queued crafter on another character is short of, only as many as they need
run("""AuctionIQ.Queue.Clear()
table.insert(AuctionIQ.db.queue, { char = 'Alt-Emerald Dream', charName = 'Alt', recipeID = 10, qty = 3, shop = { { itemID = 991, n = 4 } }, reagents = {} })
table.insert(AuctionIQ.db.queue, { char = 'Far-Other Realm', charName = 'Far', recipeID = 10, qty = 3, shop = { { itemID = 991, n = 4 } }, reagents = {} })
STUB.oldInv = AuctionIQ.Ledger.Inventory; STUB.oldAvail = AuctionIQ.Ledger.Available
AuctionIQ.Ledger.Available = function() return true end
AuctionIQ.Ledger.Inventory = function(_, name)
  if name == 'Alt' then return { { id = 991, bags = 2, bank = 0, mail = 0, warband = 0 } } end
  if name == nil then return { { id = 991, bags = 0, bank = 0, mail = 0, warband = 3 } } end
  return {}
end""")
need = L.eval("AuctionIQ.Mail.ReagentNeeds()")
check("mail: a queued crafter is short what their crafts need less what they and the Warband bank hold",
      need["Alt"] is not None and need["Alt"][991] == 7 and need["Far"] is None)
run("""STUB.oldCC = C_Container
C_Container = { GetContainerNumSlots = function(bag) return bag == 0 and 1 or 0 end,
  GetContainerItemInfo = function(bag, slot) return { itemID = 991, stackCount = 20 } end,
  PickupContainerItem = function() STUB.mailPick = true end,
  SplitContainerItem = function(bag, slot, n) STUB.mailSplit = n end }
STUB.oldSend = SendMail; SendMail = function(to) STUB.mailTo = to end
STUB.oldCSMIB = ClickSendMailItemButton; ClickSendMailItemButton = function() end""")
box = L.eval("AuctionIQ.Mail.Outbox()")
check("mail: the outbox sends a crafter only the reagents they're short", box["Alt"][1].send == 7 and box["Alt"][1].reagent)
run("AuctionIQ.Mail.SendNext()")
check("mail: a part stack is split off, not the whole stack sent", L.eval("STUB.mailSplit") == 7 and L.eval("STUB.mailTo") == "Alt")
# Mail: the Warband bank is one stock. Your own queued crafts take from it first, then each crafter
# takes what's left, and one bag stack is never handed out twice.
run("""AuctionIQ.Queue.Clear()
table.insert(AuctionIQ.db.queue, { char = AuctionIQ.CharacterKey(), recipeID = 10, qty = 1, shop = { { itemID = 991, n = 1 } }, reagents = {} })
table.insert(AuctionIQ.db.queue, { char = 'Alt-Emerald Dream', charName = 'Alt', recipeID = 10, qty = 1, shop = { { itemID = 991, n = 4 } }, reagents = {} })
table.insert(AuctionIQ.db.queue, { char = 'Bee-Emerald Dream', charName = 'Bee', recipeID = 10, qty = 1, shop = { { itemID = 991, n = 4 } }, reagents = {} })
AuctionIQ.Ledger.Inventory = function(_, name)
  if name == nil then return { { id = 991, bags = 0, bank = 0, mail = 0, warband = 4 } } end
  return {}
end
C_Container = { GetContainerNumSlots = function(bag) return bag == 0 and 1 or 0 end,
  GetContainerItemInfo = function(bag, slot) return { itemID = 991, stackCount = 6 } end }""")
need = L.eval("AuctionIQ.Mail.ReagentNeeds()")
check("mail: the Warband bank isn't counted for more than one crafter",
      need["Alt"][991] == 1 and need["Bee"][991] == 4)
box = L.eval("AuctionIQ.Mail.Outbox()")
sends = [it.send for to in ("Alt", "Bee") if box[to] for it in box[to].values()]
check("mail: one stack is shared out, never sent twice", sends == [1, 4] and sum(sends) <= 6)
run("""C_Container = STUB.oldCC; SendMail = STUB.oldSend; ClickSendMailItemButton = STUB.oldCSMIB
AuctionIQ.Ledger.Inventory = STUB.oldInv; AuctionIQ.Ledger.Available = STUB.oldAvail; AuctionIQ.Queue.Clear()""")

# Craft results live in Analytics, for every character
run("""AuctionIQ.db.characters['Alt-Realm'] = { name = 'Alt', professions = {}, log = { [10] = { name = 'Test Flask', crafts = 4, items = 4,
  mcProcs = 1, extraItems = 1, resProcs = 0, saved = 0, ingProcs = 0, concSpent = 0, concRefund = 0, value = 50000, cost = 20000,
  expected = 25000, expMc = 0.8, expRes = 0.4, expIng = 0, concCrafts = 0 } } }""")
res = [r for r in L.eval("AuctionIQ.Log.AllRows()").values() if r.char == "Alt"]
check("results: every character's crafts are listed", len(res) == 1 and res[0].crafts == 4 and res[0].actual == 30000)
run("AuctionIQ.LogUI.Open()")
check("results: /aiq results opens the Analytics view", L.eval("AuctionIQ.LedgerUI.View()") == "results")
run("AuctionIQ.db.characters['Alt-Realm'] = nil; AuctionIQ.UI.Page('today')")

# Values: MV, RV, EV and RZ (realized, from your own sales) explain a price
run("""STUB.oldSales2 = TradeSkillMasterDB["r@Emerald Dream@internalData@csvSales"]
TradeSkillMasterDB["r@Emerald Dream@internalData@csvSales"] = "itemString,stackSize,quantity,price,otherPlayer,player,time,source\\ni:100,1,2,100000,Bob,Courtizy," .. (time() - 86400) .. ",Auction"
AuctionIQ.Ledger.ClearStats()""")
vals = L.eval("AuctionIQ.Prices.Values(100)")
check("values: realized is what you sold it for after the cut", vals.realized == 95000 and vals.n == 2 and vals.mv is not None and vals.ev is not None)
vl = [plain(l[0+1]) for l in L.eval("AuctionIQ.Prices.ValueLines(100)").values()]
check("values: short codes in the tooltip", vl[0] == "Values" and any(x.startswith("  MV") for x in vl) and any(x.startswith("  RZ  Realized, 2 sold, last 1d ago") for x in vl))
check("values: each code has its full meaning for the hover", all(L.eval(f"AuctionIQ.GLOSSARY.{c} ~= nil") for c in ["MV", "RV", "EV", "RZ"]))
run("""TradeSkillMasterDB["r@Emerald Dream@internalData@csvSales"] = STUB.oldSales2; AuctionIQ.Ledger.ClearStats()""")

# Analytics views: performance, drivers, capital, crafting efficiency, scenarios
run("""STUB.oldSales3 = TradeSkillMasterDB["r@Emerald Dream@internalData@csvSales"]
local t = time()
TradeSkillMasterDB["r@Emerald Dream@internalData@csvSales"] = "itemString,stackSize,quantity,price,otherPlayer,player,time,source\\n"
  .. "i:100,1,4,20000,Bob,Courtizy," .. (t - 2 * 86400) .. ",Auction\\n"
  .. "i:100,1,2,10000,Bob,Courtizy," .. (t - 10 * 86400) .. ",Auction"
AuctionIQ.Ledger.ClearStats()
AuctionIQ.db.characters['Alt-Realm'] = { name = 'Alt', professions = { [99] = { name = 'Test Alchemy', scan = { rows = {
  { recipeID = 10, name = 'Test Flask', item = 100, made = 1, profit = 1000, cost = 5000,
    accounts = { cost = 5000, reagents = { { itemID = 201, n = 2, cost = 5000 } } } } } } } },
  log = { [10] = { name = 'Test Flask', crafts = 2, items = 2, mcProcs = 0, extraItems = 0, resProcs = 0, saved = 0, ingProcs = 0,
    concSpent = 100, concRefund = 0, concGold = 5000, value = 20000, cost = 10000, expected = 9000, expMc = 0, expRes = 0, expIng = 0, concCrafts = 1 } } }""")
ctx = "{ now = time(), since = time() - 7 * 86400, opts = {}, keepName = function() return true end }"
perf = L.eval(f"(function() local l, t, p = AuctionIQ.AnalyticsViews.Performance({ctx}) return {{ t = t, p = p }} end)()")
check("analytics performance: this week's crafted profit against the week before", perf.p != 0 and perf.t != perf.p)
drv = [x for x in L.eval(f"AuctionIQ.AnalyticsViews.Drivers({ctx})").values() if x.id == 100][0]
check("analytics drivers: price, volume and cost effects add up to the change", abs(drv.price + drv.volume + drv.cost - drv.change) < 1 and drv.driver in ("price", "volume"))
run("""STUB.oldInvC = AuctionIQ.Ledger.Inventory
AuctionIQ.Ledger.Inventory = function() return { { id = 100, total = 10, value = 999999 } } end""")
capl = list(L.eval(f"AuctionIQ.AnalyticsViews.Capital({ctx})")[0].values())
run("AuctionIQ.Ledger.Inventory = STUB.oldInvC")
check("analytics capital: days of stock is units held over units sold a day", any(x.daysOfStock and abs(x.daysOfStock - 17.5) < 1e-6 for x in capl))
cr = [x for x in L.eval(f"AuctionIQ.AnalyticsViews.Crafting({ctx})").values() if x.char == "Alt"][0]
check("analytics crafting: gold per Concentration point from the Concentration crafts", cr.perPoint == 50 and cr.each == 5000)
sc = [x for x in L.eval(f"AuctionIQ.AnalyticsViews.Scenarios({ctx})").values() if x.name == "Test Flask" and x.char == "Alt"][0]
check("analytics scenarios: reagents +10% and price -10% from the scan", abs(sc.reagentsUp - 500) < 1e-6 and abs(sc.priceDown - 400) < 1e-6 and abs(sc.both + 100) < 1e-6 and abs(sc.breakEven - 0.2) < 1e-9)
run("AuctionIQ.UI.Page('analytics', 'performance')")
check("analytics: Performance view opens", LUI.View() == "performance" and LUI.Section() == "research")
nav = [n[1] for k, n in sorted((k, n) for k, n in L.eval("AuctionIQ.LedgerUI.SECTIONS.research").items() if isinstance(k, int))]
perfnav = nav[nav.index("Performance") + 1:]
check("performance nav: performance first, craft results last, no stock targets", perfnav[0] == "performance" and perfnav[-1] == "results" and "par" not in perfnav and "perf" in perfnav)
# Scenarios reprice revenue, consumed reagents and what Resourcefulness gives back separately:
# 130 revenue - 100 reagents + 20 back = 50; reagents +10% = 42, price -10% = 37, both = 29
parts = L.eval("{ revenue = 130, consumed = 100, returned = 20, deposits = 0 }")
rp = L.eval("AuctionIQ.AnalyticsViews.Reprice")
check("scenarios: Resourcefulness's returns are repriced with the reagents",
      abs(rp(parts, 0, 0) - 50) < 1e-9 and abs(rp(parts, 0.1, 0) - 42) < 1e-9 and abs(rp(parts, 0, 0.1) - 37) < 1e-9 and abs(rp(parts, 0.1, 0.1) - 29) < 1e-9)
pa = L.eval("AuctionIQ.AnalyticsViews.Parts({ profit = 50, cost = 100, accounts = { sales = 120, mcGold = 10, cost = 100, resGold = 20, unit = 13, deposit = 1 } })")
check("scenarios: a scan's accounts split into revenue, reagents, returns and deposits",
      pa.revenue == 130 and pa.consumed == 100 and pa.returned == 20 and abs(pa.deposits - 10) < 1e-9 and abs(rp(pa, 0, 0.1) - 36) < 1e-9)
# Scenarios: editable, saved, and the headings follow
run("AuctionIQ.UI.Page('research', 'scenarios')")
ctl = L.eval("AuctionIQ.UI.Pages().ledger.controls")
check("scenarios: two setting buttons show", ctl[1].shown and ctl[2].shown and plain(ctl[1].label) == "Reagents +10%")
run("AuctionIQ.UI.Pages().ledger.controls[1].scripts.OnClick(AuctionIQ.UI.Pages().ledger.controls[1], 'LeftButton')")
sc2 = [x for x in L.eval(f"AuctionIQ.AnalyticsViews.Scenarios({ctx})").values() if x.name == "Test Flask" and x.char == "Alt"][0]
check("scenarios: left-click raises reagents to +15% and the numbers follow", abs(sc2.reagentsUp - 250) < 1e-6
      and L.eval("AuctionIQ.db.scenario.reagents") == 0.15 and plain(L.eval("AuctionIQ.AnalyticsViews.VIEWS.scenarios.cols[4][1]")) == "Reagents +15%")
run("AuctionIQ.UI.Pages().ledger.controls[2].scripts.OnClick(AuctionIQ.UI.Pages().ledger.controls[2], 'RightButton')")
check("scenarios: right-click lowers prices to -5%", L.eval("AuctionIQ.AnalyticsViews.Scenario().price") == 0.05)
run("SlashCmdList.AUCTIONIQ('scenario 10 10')")
check("scenarios: /aiq scenario 10 10 sets both", L.eval("AuctionIQ.AnalyticsViews.Scenario().reagents") == 0.10 and L.eval("AuctionIQ.AnalyticsViews.Scenario().price") == 0.10)
run("AuctionIQ.UI.Page('operations', 'queue')")
check("scenario controls hide on other views", not L.eval("AuctionIQ.UI.Pages().ledger.controls")[1].shown)
run("""TradeSkillMasterDB["r@Emerald Dream@internalData@csvSales"] = STUB.oldSales3; AuctionIQ.Ledger.ClearStats()
AuctionIQ.db.characters['Alt-Realm'] = nil""")

# Second and third review fixes -------------------------------------------------------------------
# the exact cheapest mix: greedy cost-per-skill takes 19, the cheapest that clears the threshold is 13
run("""STUB.prices['i:961'] = { mat = 1 }; STUB.prices['i:962'] = { mat = 10 }
STUB.prices['i:963'] = { mat = 1 }; STUB.prices['i:964'] = { mat = 3 }; AuctionIQ.Prices.ClearCache()
STUB.cm = { qual = { { qty = 1, items = { 961, 962 } }, { qty = 3, items = { 963, 964 } } }, fixed = {},
  perUnit = { { [1] = 0, [2] = 10 }, { [1] = 0, [2] = 3 } }, maxQ = 2, thresholds = { [2] = 10 } }""")
cheap = L.eval("AuctionIQ.Advisor.Cheapest(STUB.cm, 0)")
q2 = cheap[2]
cost2 = (q2[1][1] or 0) * 1 + (q2[1][2] or 0) * 10 + (q2[2][1] or 0) * 1 + (q2[2][2] or 0) * 3
check("advisor: the exact cheapest mix for a quality, not the greedy one", cost2 == 13 and (q2[1][2] or 0) == 1)
# fractional skill: 3.5 + 2.5 reaches 6, though each slot rounded down would only make 5
run("""for id, p in pairs({ [971] = 1, [972] = 31, [973] = 1, [974] = 31, [975] = 1, [976] = 67 }) do STUB.prices['i:' .. id] = { mat = p } end
AuctionIQ.Prices.ClearCache()
STUB.cf = { qual = { { qty = 1, items = { 971, 972 } }, { qty = 1, items = { 973, 974 } }, { qty = 1, items = { 975, 976 } } }, fixed = {},
  perUnit = { { [1] = 0, [2] = 3.5 }, { [1] = 0, [2] = 2.5 }, { [1] = 0, [2] = 6 } }, maxQ = 2, thresholds = { [2] = 6 } }""")
cf = L.eval("AuctionIQ.Advisor.Cheapest(STUB.cf, 0)")[2]
costf = sum(n * {1: {1: 1, 2: 31}, 2: {1: 1, 2: 31}, 3: {1: 1, 2: 67}}[i][q] for i in (1, 2, 3) for q, n in cf[i].items())
check("advisor: fractional skill from two slots adds up to a threshold", costf == 63)

# one evaluation with no finishing reagents asks the game once per mix, not twice
run("STUB.m10 = AuctionIQ.Advisor.Measure(10)")
run("""STUB.opCalls = 0; STUB.oldOp = C_TradeSkillUI.GetCraftingOperationInfo
C_TradeSkillUI.GetCraftingOperationInfo = function(...) STUB.opCalls = STUB.opCalls + 1; return STUB.oldOp(...) end""")
run("AuctionIQ.Advisor.Evaluate(STUB.m10)")
calls = L.eval("STUB.opCalls")
run("C_TradeSkillUI.GetCraftingOperationInfo = STUB.oldOp")
check("advisor: no finishing reagents means one build, not two", calls > 0 and calls <= 11)

# opening an order for another recipe keeps the order in the advisor
run("AuctionIQ.AdvisorUI.Show(11, true)")
run("AuctionIQ.AdvisorUI.ShowOrder({ orderID = 88, spellID = 10, minQuality = 1, tipAmount = 50000000, consortiumCut = 0, reagents = {} })")
check("advisor: opening an order for a different recipe keeps its order", L.eval("AuctionIQ.AdvisorUI.Current() and AuctionIQ.AdvisorUI.Current().order ~= nil") is True)

# knowledge paths: a day's Concentration can't sell more than demand
run("""STUB.oldDU = AuctionIQ.Scan.DailyUnits; AuctionIQ.Scan.DailyUnits = function() return 1 end
STUB.oldEval = AuctionIQ.Advisor.Evaluate
AuctionIQ.Advisor.Evaluate = function() return { made = 1, best = { profit = 1000, item = 1 },
  bestConc = { profit = 1100, perPoint = 1100 / 30, avgConcentration = 30, concentration = 30, item = 1 } } end
STUB.oldDelta = AuctionIQ.Spec.Delta; AuctionIQ.Spec.Delta = function() return {} end""")
pv = L.eval("AuctionIQ.Paths.Value({ recipes = { 1 }, models = { [1] = {} }, prof = 2906, tree = {} }, {})")
run("AuctionIQ.Scan.DailyUnits = STUB.oldDU; AuctionIQ.Advisor.Evaluate = STUB.oldEval; AuctionIQ.Spec.Delta = STUB.oldDelta")
check("paths: Concentration only replaces crafts the demand can sell", abs(pv[0] - 1100) < 1e-6)

# the craft log prices the reagents the craft really used
run("AuctionIQ.AdvisorUI.Show(10, true)")
r10 = L.eval("AuctionIQ.AdvisorUI.Current()")
check("craft log: a matching row is found for the test recipe", r10 is not None)
other = L.eval("(function() for _, r in ipairs(AuctionIQ.AdvisorUI.Current().rows) do if not r.concentration and r ~= AuctionIQ.AdvisorUI.Current().best then return r end end end)()")
if other is not None:
    run("""STUB.logOther = (function() for _, r in ipairs(AuctionIQ.AdvisorUI.Current().rows) do if not r.concentration and r ~= AuctionIQ.AdvisorUI.Current().best then return r end end end)()
local infos = {}
for i, slot in ipairs(AuctionIQ.AdvisorUI.Current().qual) do
  for q, id in ipairs(slot.items) do local n = STUB.logOther.picks[i][q] or 0; if n > 0 then table.insert(infos, { itemID = id, quantity = n }) end end
end
AuctionIQ.Log.Started(10, 1, false, infos, nil)""")
    check("craft log: the row matching the craft's reagents is the one expected", L.eval("AuctionIQ.Log.Pending().cost") == other.cost)

# craft log: an order's craft is worth its pay (commission after the cut + rewards), not the item at market,
# and the reagents the customer provided cost you nothing
run("""STUB.oldCO = C_CraftingOrders
C_CraftingOrders = { GetClaimedOrder = function() return { orderID = 91, spellID = 10, tipAmount = 500000, consortiumCut = 50000, reagents = {} } end }
AuctionIQ.Log.Clear(); AuctionIQ.AdvisorUI.Show(10)
AuctionIQ.Log.Started(10, 1, false, { { itemID = 202, quantity = 1, dataSlotIndex = 1 } }, 91)""")
po = L.eval("AuctionIQ.Log.Pending()")
check("craft log: an order craft knows what the order pays", po.order and po.orderIncome == 450000)
run('STUB.Fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 302, quantity = 1 })')
oe = list(CH.Log.Rows().values())[0].e
check("craft log: the order's pay is counted once, not the item at market", oe.value == 450000 and oe.orderIncome == 450000 and oe.orderCrafts == 1)
run("""C_CraftingOrders = { GetClaimedOrder = function() return { orderID = 89, spellID = 10, tipAmount = 0, reagents = {
  { reagentInfo = { reagent = { itemID = 202 }, quantity = 1, dataSlotIndex = 1 } } } } end }
AuctionIQ.Log.Started(10, 1, false, { { itemID = 202, quantity = 1, dataSlotIndex = 1 } }, 89)""")
check("craft log: customer-provided reagents aren't your cost", L.eval("AuctionIQ.Log.Pending().cost") < L.eval("(function() local x = AuctionIQ.Prices.Get('chmat', 'i:202'); return x end)()") or L.eval("AuctionIQ.Log.Pending().cost") == 0)
run("C_CraftingOrders = STUB.oldCO; AuctionIQ.Log.Clear()")

# posting: a confirmed post counts toward the cap before the owned list comes back
run("AuctionIQ.db.auctions = {}; AuctionIQ.Auction.Posted(971, 5)")
check("auctions: fresh posts count before the owned list updates", L.eval("AuctionIQ.Auction.Listed(971)") == 5)
run("AuctionIQ.db.auctions = {}")

# gear with no copy in the bags is searched as an item, not a commodity
check("auction search: gear at an item level isn't a commodity", L.eval("AuctionIQ.Auction.IsCommodity(999999, 645)") is False)

# cancels wait for the AH
run("""STUB.cancelled = nil; C_AuctionHouse.CancelAuction = function(id) STUB.cancelled = id end""")
run("""local plan = AuctionIQ.AuctionUI.Plan(); for k in pairs(plan) do plan[k] = nil end
table.insert(plan, { id = 302, auctionID = 4242, d = { action = 'cancel', why = 'undercut' } })""")
run("AuctionIQ.AuctionUI.CancelNext()")
pend = L.eval("AuctionIQ.AuctionUI.Plan()[1].done")
run("STUB.Fire('AUCTION_CANCELED', 4242)")
check("cancel: a row is done only once the AH says it's cancelled", L.eval("STUB.cancelled") == 4242 and not pend and L.eval("AuctionIQ.AuctionUI.Plan()[1].done") is True)
run("""table.insert(AuctionIQ.AuctionUI.Plan(), { id = 302, auctionID = 4243, d = { action = 'cancel', why = 'undercut' } })
AuctionIQ.AuctionUI.CancelNext(); STUB.RunTimers()""")
check("cancel: no answer from the AH marks it failed, not done", L.eval("AuctionIQ.AuctionUI.Plan()[2].failed") is True)
run("local plan = AuctionIQ.AuctionUI.Plan(); for k in pairs(plan) do plan[k] = nil end; C_AuctionHouse.CancelAuction = nil")

# a fulfilled order leaves the cache, and an old sighting isn't live
run("""AuctionIQ.Orders.cache = {}; AuctionIQ.Orders.seen = {}
STUB.oldCO = C_CraftingOrders; C_CraftingOrders = C_CraftingOrders or {}
STUB.oldList = C_CraftingOrders.GetCrafterOrders
C_CraftingOrders.GetCrafterOrders = function() return { { orderID = 501, spellID = 10 } } end
AuctionIQ.Orders.All()
C_CraftingOrders.GetCrafterOrders = function() return {} end""")
live1 = L.eval("AuctionIQ.Orders.Live(501) ~= nil")
run("STUB.Fire('CRAFTINGORDERS_FULFILL_ORDER_RESPONSE', 0, 501)")
check("orders: a fulfilled order leaves the list", live1 is True and L.eval("AuctionIQ.Orders.Live(501)") is None)
run("""C_CraftingOrders.GetCrafterOrders = function() return { { orderID = 502 } } end; AuctionIQ.Orders.All()
C_CraftingOrders.GetCrafterOrders = function() return {} end
AuctionIQ.Orders.seen['502'] = time() - 3600""")
check("orders: an order the game hasn't listed for an hour isn't live", L.eval("AuctionIQ.Orders.Live(502)") is None)
run("C_CraftingOrders.GetCrafterOrders = STUB.oldList; C_CraftingOrders = STUB.oldCO; AuctionIQ.Orders.cache = {}; AuctionIQ.Orders.seen = {}")

# opening a page refreshes it once
run("""STUB.refreshes = 0; STUB.oldRefresh = AuctionIQ.UI.Refresh
AuctionIQ.UI.Refresh = function(...) STUB.refreshes = STUB.refreshes + 1; return STUB.oldRefresh(...) end""")
run("AuctionIQ.UI.Page('today')")
n1 = L.eval("STUB.refreshes")
run("AuctionIQ.UI.Refresh = STUB.oldRefresh")
check("ui: opening a page refreshes it once", n1 == 1)


# Math engine: probability helpers, Bayesian sell-through, expected value -----------------------
P = CH.Prob
check("prob: Beta CDF matches known values", abs(P.BetaCDF(0.5, 2, 2) - 0.5) < 1e-9 and abs(P.BetaCDF(0.3, 1, 1) - 0.3) < 1e-9
      and abs(P.BetaCDF(0.8, 9, 3) - 0.6174015488) < 1e-8)
check("prob: Poisson quantile (2 a day for 7 days at 90% is 19)", P.PoissonQuantile(14, 0.9) == 19 and P.PoissonQuantile(0, 0.9) == 0
      and P.PoissonQuantile(1, 0.5) == 1)
check("prob: big means use the normal approximation", abs(P.PoissonQuantile(10000, 0.9) - 10128) <= 1 and abs(P.NormInv(0.975) - 1.95996) < 1e-4)
st = P.SellThrough(16, 4, 0.5)
check("prob: sell-through belief", abs(st.mean - 18 / 24) < 1e-9 and st.n == 20 and 0 < st.pUp < 1 and st.pDown < 0.01)
run("""
STUB.sellThrough = {}
AuctionIQ.Ledger.SellThrough = function(id) local t = STUB.sellThrough[id]; if t then return t[1], t[2] end return 0, 0 end
STUB.sellThrough[901] = { 40, 2 }; STUB.sellThrough[902] = { 3, 1 }; STUB.sellThrough[903] = { 2, 30 }; STUB.sellThrough[904] = { 1, 1 }
""")
f901, f902, f903, f904 = (CH.Groups.Learn(i) for i in (901, 902, 903, 904))
check("learn: a strong record raises the price, by up to 5%", 1.03 <= f901[0] <= 1.05 and "sure" in f901[1])
check("learn: four posts are not enough to move it", f902 == 1 and f904 == 1)
check("learn: mostly expiring cuts it, by up to 10%", 0.9 <= f903[0] <= 0.93)
run("""
STUB.items[905] = STUB.items[905] or {}
local gi = C_Item.GetItemInfo
C_Item.GetItemInfo = function(id) if id == 905 then return "Thing", "link", 3, 1, 1, "", "", 20, "", 0, 400000 end return gi and gi(id) end
STUB.sellThrough[905] = { 5, 15 }
""")
ev, d = CH.Expect.Value(905, 1000000, 24)
# p = (4*0.5 + 5) / (4 + 20) = 7/24; deposit 15% of 40g for 24h = 12g a listing
p_ = 7 / 24
want = 950000 - 120000 * (1 - p_) / p_ - 950000 * 0.01 * (24 / (24 * p_))
check("expect: value = price after cut, less lost deposits and carrying", abs(ev - want) < 1 and abs(d.p - p_) < 1e-9 and abs(d.days - 1 / p_) < 1e-9)
check("expect: no sale rate means just the cut", CH.Expect.Value(906, 1000000)[0] == 950000)
check("expect: carrying cost is a setting", CH.Settings.Model("carry")[1] == "1.00%" and CH.Settings.Model("carry", 2)[1] == "1.50%")
run("AuctionIQ.Settings.Model('carry', -2)")
lines = [plain(l[1]) for l in CH.AdvisorUI.ExpectLines(d).values()]
check("expect: the advisor hover shows each step", any("Deposits lost" in x for x in lines) and any("Gold tied up" in x for x in lines) and lines[-1] == "Expected each")
check("failed auctions: deposits lost", CH.Expect.LostDeposit(905, 3) == 360000)
run("STUB.sellThrough = nil")

for a in sorted(set(audit_all)):
    print("LAYOUT " + a)
check("layout: nothing spills out of its panel or gets cut off", len(set(audit_all)) == 0)

print(f"\n{len(fails)} failed" if fails else "\nall passed")
sys.exit(1 if fails else 0)
