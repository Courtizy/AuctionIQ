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
CH = L.globals().Clearinghouse
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
run('Clearinghouse.db.settings.coins = false')
check("/ch coins setting gives g/s/c text", CH.FormatMoney(125000) == "12g 50s")
run('Clearinghouse.db.settings.coins = true')
check("tooltip shows value, buy now / post and profit",
      lines == ["AuctionIQ value=", "    Buy now (lowest listing)=450g", "    Post price=450g", "  Sale price=500g",
               "  AH cut (5%)=-25g", "  Value after cut=475g", "Craft profit=375g"])
run('Clearinghouse.db.settings.tooltip = false; GameTooltip.lines = {}; STUB.tooltipFn(GameTooltip)')
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

run('SlashCmdList.CLEARINGHOUSE("")')
check("/ch opens the window", CH.UI.IsShown())
run('SlashCmdList.CLEARINGHOUSE("")')
check("/ch again closes it", not CH.UI.IsShown())

btn = CH.CreateMinimapButton()
check("minimap button made at login", btn is not None and btn.shown)
run('Clearinghouse.CreateMinimapButton().scripts.OnClick()')
check("minimap button opens the window", CH.UI.IsShown())
run('local b = Clearinghouse.CreateMinimapButton(); b.scripts.OnDragStart(b); b.scripts.OnUpdate(b)')
check("dragging moves it round the minimap", abs(CH.db.settings.minimap.angle) < 0.001 and btn.point[4] == 75)
run('SlashCmdList.CLEARINGHOUSE("minimap")')
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
check("sell hover shows realm and region prices", ("   Market value, realm", "300g") in sl and ("   Lowest listing, realm", "none") in sl and sl[-1] == ("After 5% auction cut", "285g"))
pl = [(plain(l[1]), plain(l[2])) for l in CH.AdvisorUI.BreakdownLines(res, best, 5).values()]
check("profit hover shows the sum and return", ("Less reagents", "-212g") in pl and ("Profit", "73g") in pl and ("Return on reagents", "34%") in pl)
mx = CH.Advisor.MaxCraftable(res, best)
check("max craftable is limited by the scarcest reagent", mx[0] == 1)  # 3 of item 205 at 2 each
mq = CH.Advisor.MaxCraftable(res, res.rows[2], 50)
check("with Concentration it is limited by points too", res.rows[2].concentration == 80 and mq[0] == 0)
ml = [(plain(l[1]), plain(l[2])) for l in CH.AdvisorUI.BreakdownLines(res, best, 7).values()]
check("max hover lists have and need", ("item 204 Q2", "12 have, 5 each") in ml)
run('Clearinghouse.db.settings.advisor.hide = false; STUB.Fire("TRADE_SKILL_SHOW")')
check("advisor panel shows with the profession window", CH.AdvisorUI.IsShown())
col = L.eval('function(x) local f = { GetLeft = function() return 0 end, GetEffectiveScale = function() return 1 end }; local g = GetCursorPosition; GetCursorPosition = function() return x, 0 end; local c = Clearinghouse.AdvisorUI.ColumnAt(f); GetCursorPosition = g; return c end')
check("row hover picks the column under the cursor", col(200) == 3 and col(250) == 4 and col(350) == 5 and col(500) == 7 and col(20) is None)
run('STUB.Fire("TRADE_SKILL_CLOSE")')
check("advisor panel hides with it", not CH.AdvisorUI.IsShown())

# Craft queue and shopping list
run('Clearinghouse.db.settings.advisor.hide = false; Clearinghouse.AdvisorUI.Show(10)')
run('Clearinghouse.AdvisorUI.RowClick(3)')            # Q2 without Concentration, one
run('STUB.shift = true; Clearinghouse.AdvisorUI.RowClick(3); STUB.shift = false')  # shift: as many as you can make (1)
run('Clearinghouse.AdvisorUI.RowClick(2)')            # Q1 reagents + Concentration
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
run("Clearinghouse.Depth.Remember(205, { { price = 15000, qty = 5 }, { price = 10000, qty = 2 }, { price = 5000, qty = 9, mine = true } })")
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
run("Clearinghouse.db.scans = {}; Clearinghouse.db.scans[205] = { at = STUB.now - 600, ladder = { { 1, 9000 }, { 10, 12000 }, { 50, 20000 } } }")
d = D.Cost(205, 30)
check("order book: between a saved scan's points the cost is a straight line", d.cost == 120000 + 880000 * 20 // 40 and d.source == "scan" and d.age == 600)
d = D.Cost(205, 60)
check("order book: past the saved book it's short at the last step's price", d.short == 10 and d.cost == 1000000 + 10 * 22000)
check("order book: slippage is the average over the cheapest", abs(D.Slippage(205, 30) - (560000 / 30 / 9000 - 1)) < 1e-9)
lad = [tuple(x.values()) for x in CH.Scans.Ladder(L.eval("{ { 100, 5 }, { 200, 8 }, { 300, 50 } }")).values()]
check("scan ladder: average to buy 1, 10, 50 and all listed", lad == [(1, 100), (10, 150), (50, 264), (63, 272)])
run("Clearinghouse.db.scans = {}; Clearinghouse.Depth.Forget()")
ok = CH.Queue.Craft(q[1], 1)
c = L.eval("STUB.crafted")
check("craft uses the queued reagents and Concentration", ok and c.id == 10 and c.conc == True and c.reagents[1].reagent.itemID == 201 and c.reagents[1].quantity == 4)
run('STUB.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 10)')
check("a finished craft comes off the queue", CH.Queue.Count() == 2 and len(list(CH.db.queue.values())) == 1)
run('Clearinghouse.Queue.Clear()')
check("clear empties it", CH.Queue.Count() == 0)

# ElvUI present: its colours, templates and skins are used
run('''ElvUI = { { media = { rgbvaluecolor = { 0.2, 0.4, 0.6 }, bordercolor = { 0, 0, 0 }, backdropfadecolor = { 0.06, 0.06, 0.06 }, backdropcolor = { 0.1, 0.1, 0.1 } },
  GetModule = function() return { HandleCloseButton = function(_, b) b.skinned = "close" end, HandleButton = function(_, b) b.skinned = "button" end } end } }
Clearinghouse.Theme.Sync()
STUB.p = CreateFrame("Frame"); Clearinghouse.Theme.Panel(STUB.p, "bg")
STUB.b = Clearinghouse.Theme.Button(STUB.p, "Dock"); STUB.x = Clearinghouse.Theme.Button(STUB.p, "x")''')
T = CH.Theme
check("ElvUI: our palette stays by default, on ElvUI's templates", T.hex.accent == "e0a83a" and T.hex.bg == "0e1729")
run("Clearinghouse.db.settings.theme = 'elvui'; Clearinghouse.Theme.Use('auctioniq')")
check("ElvUI: /aiq theme takes its value colour as the accent", T.hex.accent == "336699")
run("Clearinghouse.db.settings.theme = nil; Clearinghouse.Theme.Use('auctioniq')")
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
run("STUB.prices['i:221'].formula_value = 10000; Clearinghouse.Prices.ClearCache()")   # you could sell yours for only 1g
pr2 = CH.Advisor.Analyze(11, L.eval('{ professionID = 2906 }'))
o221 = [o for opts in pr2.model.finishing.values() for o in opts.values() if o.itemID == 221][0]
check("finishing: one you own costs what you'd sell it for", o221.cost == 9500 and o221.buy == 30000)
run("STUB.prices['i:221'].formula_value = nil; Clearinghouse.Prices.ClearCache()")

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
run("""Clearinghouse.SpecData[2906] = { name = "Alchemy", recipes = { [10] = { 900, 9001 }, [11] = { 900, 9001, 901 } },
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
run('Clearinghouse.AdvisorUI.SetPlan(nil); Clearinghouse.AdvisorUI.SetSimSkill(0)')
check("spec: the trees' layout is read per tab, with links",
      tree.tabs[1].name == "Test Mastery" and list(tree.tabs[1].nodes.values()) == [900, 901]
      and tree.layout[901].parent == 900 and tree.layout[901].y == 600 and tree.layout[901].rank == -1)
marks = CH.Paths.Marks(plan)
check("plan marks: each node's planned rank and steps", marks[900].to == max(s.to for s in plan.steps.values() if s.node == 900) and marks[900].steps[1] == 1)
CH.Paths.SetCurrent(plan)
run('Clearinghouse.PathsUI.Open()')
drawn = list(CH.PathsUI.DrawTree().values())
check("paths tab draws the tree with the plan on it",
      len(drawn) == 2 and drawn[0].planned and drawn[0].steps.startswith("1") and ">" in drawn[0].rank)
groups = list(CH.Paths.GoalGroups(2906).values())
check("paths picker: recipes in main groups", [g.name for g in groups] == ["Potions", "Flasks & Phials", "Oils", "Other"])
check("paths picker: each profession has its own groups", L.eval('Clearinghouse.Paths.MainGroup("Weapon Enchants", 2909)') == "Enchants"
      and L.eval('Clearinghouse.Paths.MainGroup("Armor Kits", 2915)') == "Armor Kits" and L.eval('Clearinghouse.Paths.MainGroup("Leather Armor", 2915)') == "Armor"
      and L.eval('Clearinghouse.Paths.MainGroup("Appendix II - Stats", 2913)') is None and L.eval('Clearinghouse.Paths.MainGroup("Powerful Peridots", 2914)') == "Gems")
# Disenchanting: a gathering path, valued by the share of rank 2 materials
run("""STUB.oldTree = Clearinghouse.Spec.Tree
Clearinghouse.SpecData[2909] = { name = "Enchanting", recipes = {}, nodes = {
  [107649] = { nodeID = 107649, maxRank = 10, base = true, stats = { gatherskill = 1 } },
  [107648] = { nodeID = 107648, maxRank = 10, base = true, stats = { gatherskill = 1 } },
  [107647] = { nodeID = 107647, maxRank = 10, base = true, stats = { gatherskill = 1 } },
  [107646] = { nodeID = 107646, maxRank = 10, base = true, stats = { gatherskill = 1 } },
  [107634] = { nodeID = 107648, maxRank = 1, unlock = 5, stats = {}, text = "You have a chance to create more Eversinging Dust." } } }
Clearinghouse.Spec.Tree = function(prof) if prof ~= 2909 then return STUB.oldTree(prof) end
  return { unspent = 10, nodes = { [107649] = { name = "Disenchanting Delegate", rank = 0, max = 10, perks = {}, available = true },
    [107648] = { name = "Dust Deliverer", rank = 0, max = 10, perks = { [107634] = 5 }, parent = 107649 },
    [107647] = { name = "Shard Supplier", rank = -1, max = 10, perks = {}, parent = 107649 },
    [107646] = { name = "Crystal Collector", rank = -1, max = 10, perks = {}, parent = 107649 } } } end
STUB.prices['i:243599'] = { formula_value = 10000 }; STUB.prices['i:243600'] = { formula_value = 30000 }
Clearinghouse.Prices.ClearCache()""")
check("disenchanting: a goal for Enchanting", L.eval('(Clearinghouse.Paths.Yield(2909, "disenchanting"))') is not None
      and L.eval('(Clearinghouse.Paths.Yield(2906, "disenchanting"))') is None and L.eval('(Clearinghouse.Paths.Yield(2909, "potions"))') is None)
check("disenchanting: in the Enchanting picker", any(g.name == "Disenchanting" and g["yield"] for g in CH.Paths.GoalGroups(2909).values()))
dp = CH.Paths.Plan(L.eval('{ goal = "disenchanting", points = 0, sync = true, prof = 2909 }'))
check("disenchanting: plan puts points into dust when only dust sells", dp.steps[1].name in ("Disenchanting Delegate", "Dust Deliverer")
      and dp.final > dp.start and all(s.name not in ("Shard Supplier", "Crystal Collector") for s in dp.steps.values()))
check("disenchanting: describes the rank 2 share and the perk", any("rank 2 share" in plain(l) for l in dp.text.values())
      and any("more Eversinging Dust" in plain(l) for l in dp.text.values()))
check("disenchanting: default points finish its paths", CH.Paths.PathCost(2909, L.eval("{}"), "disenchanting") == 42)
# Disenchanting: what you really loot from items is recorded and used instead of the guess
check("disenchanting: a starting guess before anything is seen", L.eval("(select(2, Clearinghouse.Paths.DailyYield(2909)))") == "guess")
run("""local loot = { { "item:243599", 3, "Item-1-2-3" }, { "item:243600", 1, "Item-1-2-3" }, { "item:243600", 5, "Creature-0-1" } }
GetNumLootItems = function() return #loot end
GetLootSlotLink = function(i) return loot[i][1] end
GetLootSlotInfo = function(i) return nil, nil, loot[i][2] end
GetLootSourceInfo = function(i) return loot[i][3], 1 end
Clearinghouse.Paths.RecordLoot(86400 * 100)""")
ob = L.eval("(Clearinghouse.Paths.Observed(2909, 86400 * 100))")
check("disenchanting: only loot out of items counts", ob.dust.n == 4 and abs(ob.dust.share - 0.25) < 1e-9 and ob.shard.n == 0)
run("STUB.realTime = time; time = function() return 86400 * 100 end")
check("disenchanting: plans use what was really disenchanted", L.eval("(select(2, Clearinghouse.Paths.DailyYield(2909)))") == "seen")
dp2 = CH.Paths.Plan(L.eval('{ goal = "disenchanting", points = 0, sync = true, prof = 2909 }'))
check("disenchanting: the plan starts from your real rank 2 share", any("you really got (Eversinging Dust 25%)" in plain(l) for l in dp2.text.values())
      and dp2.startPer.dust.share == 0.25)
run("Clearinghouse.Paths.SetDailyYield(2909, { dust = 10, shard = 1, crystal = 0 })")
check("disenchanting: /aiq de by hand wins", L.eval("(select(2, Clearinghouse.Paths.DailyYield(2909)))") == "set")
run("Clearinghouse.Paths.SetDailyYield(2909, nil); time = STUB.realTime; GetNumLootItems = nil")
run("Clearinghouse.Spec.Tree = STUB.oldTree")
cost = CH.Paths.PathCost(2906, L.eval("{ 10 }"))
check("paths: default points finish the path for the goal", cost > 0 and CH.Paths.PathCost(2906, L.eval("{ }")) == 0)
run('Clearinghouse.PathsUI.Pick("Flasks & Phials", { 10 })')
check("picking a group plans it", CH.PathsUI.DefaultPoints(L.eval("{ 10 }")) == max(0, cost - CH.Spec.Tree(2906).unspent))
run("""STUB.btn = CreateFrame("Button"); STUB.btn:Show()
ProfessionsFrame = CreateFrame("Frame"); ProfessionsFrame.SpecPage = CreateFrame("Frame"); ProfessionsFrame.SpecPage:Show()
function ProfessionsFrame.SpecPage:GetTalentButtonByNodeID(id) return id == 900 and STUB.btn or nil end""")
check("game's spec tab gets a badge on each planned node", CH.SpecOverlay.Refresh() == 1)
run('Clearinghouse.Paths.ClearCurrent(2906)')
check("clearing the plan takes the badges off", CH.SpecOverlay.Refresh() == 0)
run('ProfessionsFrame = nil; Clearinghouse.PathsUI.Toggle()')

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

# Recipe scan
run('Clearinghouse.ScanUI.Toggle(); for i = 1, 20 do STUB.RunTimers() end')
sr = CH.Scan.Results(2906)
names = [r.name for r in sr.rows.values()]
check("scan: every learned recipe with a result, saved", "Test Flask" in names and "Test Potion" in names)
pot = [r for r in sr.rows.values() if r.name == "Test Potion"][0]
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
run('STUB.prices["i:302"].mat = 10000; Clearinghouse.Prices.ClearCache()')
bc = CH.Scan.BuyOrCraft(flask)
check("buy or craft: a listing under the crafting cost says buy", bc.buy == 10000 and bc.save > 0 and bc.flip == 3000000 * 0.95 - 10000)
run('STUB.prices["i:302"].mat = nil; Clearinghouse.Prices.ClearCache()')
check("scan: top recipe by profit", len(top) == 1 and top[0].profit == max(r.profit or 0 for r in sr.rows.values()))

# Queue on a Concentration budget
run('Clearinghouse.Queue.Clear()')
plan = CH.Queue.FillPlan(2906, L.eval("{ budget = 100 }"))
qs = list(CH.db.queue.values())
cq = [e for e in qs if e.concentration]
check("fill: Concentration crafts stay within the budget", plan.conc == 1 and plan.points == 80 and plan.conc == sum(e.qty for e in cq))
check("fill: profitable crafts without Concentration are added too", plan.plain > 0 and any(not e.concentration for e in qs))
check("fill: crafts per recipe stop at what sells in a day", all(e.qty <= 10 for e in qs))
run('Clearinghouse.Queue.Clear()')
plan0 = CH.Queue.FillPlan(2906, L.eval("{ budget = 0 }"))
check("fill: no Concentration, no Concentration crafts", plan0.conc == 0 and plan0.points == 0)
run('Clearinghouse.Queue.Clear()')
scan_cols = list(CH.ScanUI.Refresh().values())
check("scan shows profit with Concentration", any(r.concProfit for r in sr.rows.values()))
pot = [r for r in sr.rows.values() if r.name == "Test Potion"][0]
check("scan: each recipe tagged with its expansion", pot.line == 2871 and pot.expansion == "Khaz Algar" and sr.currentLine == 2906)
heads = [t for t in scan_cols if t.startswith("== ")]
check("scan: current expansion first, older under their own header",
      heads == ["== Midnight", "== Khaz Algar"] and scan_cols[0] == "== Midnight"
      and scan_cols.index("== Khaz Algar") < [i for i, t in enumerate(scan_cols) if t.startswith("Test Potion")][0])
run('Clearinghouse.ScanUI.olderButton.scripts.OnClick()')
hidden = list(CH.ScanUI.Refresh().values())
check("scan: older expansions can be hidden", not any(t.startswith("Test Potion") for t in hidden) and not any(t.startswith("== ") for t in hidden))
run('Clearinghouse.ScanUI.olderButton.scripts.OnClick()')
run('for _, r in ipairs(Clearinghouse.Scan.Results(2906).rows) do r.line = nil; r.expansion = nil end')
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
run('Clearinghouse.ScanUI.Open()')
check("tabs: opening Scan hides the others", CH.ScanUI.IsShown() and not CH.AdvisorUI.IsShown() and not CH.QueueUI.IsShown() and CH.Window.Active() == "scan")
labels = list(CH.Window.Arrange().values())
check("tabs: the row lists every window", labels == ["Advisor", "Scan", "Paths", "Queue", "Results"])
run('Clearinghouse.AdvisorUI.Show(10)')
check("tabs: a recipe click updates the advisor without leaving Scan", CH.ScanUI.IsShown() and not CH.AdvisorUI.IsShown())
run('Clearinghouse.AdvisorUI.Open()')
check("tabs: the Advisor tab brings it back", CH.AdvisorUI.IsShown() and not CH.ScanUI.IsShown())
run('Clearinghouse.QueueUI.Show(); Clearinghouse.Window.ToggleQueuePop()')
labels = list(CH.Window.Arrange().values())
check("pop-out: the queue leaves the tabs and shows beside the advisor",
      CH.QueueUI.IsShown() and CH.AdvisorUI.IsShown() and "Queue" not in labels)
run('Clearinghouse.PathsUI.Open()')
check("pop-out: switching tabs leaves the queue open", CH.PathsUI.IsShown() and CH.QueueUI.IsShown() and not CH.AdvisorUI.IsShown())
run('Clearinghouse.Window.ToggleQueuePop()')
check("back in the tabs: the queue takes the spot", CH.QueueUI.IsShown() and not CH.PathsUI.IsShown() and CH.Window.Active() == "queue")
run('Clearinghouse.Window.CloseTabs()')
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
run("Clearinghouse.UI.SetRange('1M')")
d = CH.UI.DashboardData()
s = d.summary
check("dashboard: sales, buys and real expenses in range; own transfers left out",
      s.sales == 7000000 and s.buys == 1000000 and s.income == 0 and s.expense == 20000 and s.cash == 5980000 and s.topItem == 302)
check("dashboard: top sale, top purchase, 52 week high and low", d.topSale == 6000000 and d.topBuy == 1000000 and d.high == 10000000 and 0 < d.low <= d.high)
run("Clearinghouse.UI.SetRange('All')")
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
dead = list(LG.DeadStock(L.eval("STUB.now"), 1).values())
check("dead stock: held, not sold in the window", [e.id for e in dead] == [301] and dead[0].advice.startswith("Slow"))
o = LG.Overhead(-1e12)
check("overhead: repairs, not your own transfers", o.total == 20000 and len(list(o.types.values())) == 1 and o.afterOverhead == o.profit - 20000)
# Phase 2: forecast vs actual
logged = [b for b in CH.Forecast.Store().values() if b.id == 302]
check("forecast: a craft saves its forecast with the batch", len(logged) == 1 and logged[0].qty == 2 and logged[0].cost and logged[0].expectEach)
run("""
Clearinghouse.db.batches = {
  { at = STUB.now - 2 * 86400, id = 302, qty = 1, cost = 1000000, expectEach = 4000000 },
  { at = STUB.now - 86400, id = 302, qty = 3, cost = 3000000, expectEach = 4000000 },
}
Clearinghouse.Forecast.Clear()
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
check("forecast: the Clearinghouse Performance view", len(list(prow.values())) == 1 and "Sold -29% vs forecast" in plain(pfoot))
pick = "(function() local r = Clearinghouse.Advisor.Analyze(10, {}); for _, x in ipairs(r.rows) do if x.item == 302 and not x.concentration then return x.unit, x.shade, r.best.item end end end)()"
run("Clearinghouse.Forecast.PRIOR = 1e15"); u0 = L.eval(pick)
run("Clearinghouse.Forecast.PRIOR = 5"); u5 = L.eval(pick)
run("Clearinghouse.Forecast.PRIOR = 0"); u1 = L.eval(pick)
check("forecast: the advisor values the item at what it really fetches", abs(u5[0] / u0[0] - want) < 1e-6 and abs(u1[0] / u0[0] - r_) < 1e-6)
check("forecast: a shaded item can lose its place as the best craft", u0[2] == 302 and u1[2] == 301)
run("Clearinghouse.Forecast.PRIOR = 5")

rows, foot = CH.LedgerUI.Rows("pl", L.eval("{ }"))
check("CFO views draw rows", len(list(rows.values())) == 1 and "best line: Flasks" in plain(foot))
for v in ["dead", "holdings", "overhead"]:
    CH.LedgerUI.Rows(v, L.eval("{ days = 30 }"))
run("Clearinghouse.Par.Refresh()")
# 1 sold a week: Poisson(1) stays at or under 2 about 92% of the time, so 2 at 90%; half a week (301) needs 1
check("stock target: a week's demand at a 90% service level, by default", CH.Par.Target(302)[0] == 2 and CH.Par.Target(301)[0] == 1 and CH.Par.Target(201) is None)
run("Clearinghouse.Settings.Model('service', 9); Clearinghouse.Par.Refresh()")
check("stock target: the service level is a setting (99% needs 4)", CH.Par.Target(302)[0] == 4 and CH.Settings.Model("service")[1] == "99%")
run("Clearinghouse.Settings.Model('service', -9); Clearinghouse.Par.Refresh()")
run("Clearinghouse.Par.Set(302, 6); Clearinghouse.Par.Refresh()")
par = {e.id: e for e in CH.Par.List().values()}
check("par: set by hand, short counts stock on every character", par[302].manual and par[302].held == 4 and par[302].short == 2)
check("par view: shift-click +1, alt-click back to automatic", CH.LedgerUI.ParClick(302, "shift")[0] == 7 and CH.LedgerUI.ParClick(302, "alt")[0] == 2)
run("Clearinghouse.Par.Set(302, 6); Clearinghouse.Par.Refresh()")
check("briefing lists what's below par", "Below stock target" in plain(CH.UI.BriefingText()))
rows, foot = CH.LedgerUI.Rows("par", L.eval("{ }"))
check("par view rows", len(list(rows.values())) == 2 and plain(foot).startswith("1 items below stock target"))
run("Clearinghouse.Par.Set(302, nil); Clearinghouse.Par.Refresh()")
# Groups and auctioning
n = CH.Groups.Rebuild()
check("groups: built from scans, reagents and resale", n > 0 and CH.Groups.Path(302).startswith("Crafted/") and CH.Groups.Path(201).startswith("Reagents/"))
check("groups: crafted goods post, reagents don't", CH.Groups.Prices(302).post and not CH.Groups.Prices(201).post)
run("Clearinghouse.Groups.Move(302, 'Mine/Flasks')")
check("groups: moving an item sticks", CH.Groups.Path(302) == "Mine/Flasks" and any(g.path == "Mine/Flasks" for g in CH.Groups.Tree().values()))
run("Clearinghouse.Groups.Move(302, nil)")
p302 = CH.Groups.Prices(302)
check("prices: min is the cost to make after the cut", p302.min and p302.why == "cost to make" and p302.normal == 3000000 and p302.max == 9000000)
check("warband listed: TSM's counts per character", CH.Auction.Listed(302) == 0)
run("Clearinghouse.Groups.Store().ops.Crafted.cap = 5")
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
_, pl = L.eval("Clearinghouse.Auction.Postable()"), L.eval("select(2, Clearinghouse.Auction.Postable())")
pl = list(pl.values())
check("post scan: gear split by item level, others not", [(e.id, e.level, e.count) for e in pl] == [(201, None, 20), (302, 645, 5), (302, 642, 10)])
check("post scan: bag counts per item level", L.eval("Clearinghouse.Auction.InBags(302, 642)") == 10 and L.eval("Clearinghouse.Auction.InBags(302)") == 15)
check("post scan: each item level priced on its own", CH.Groups.Prices(302, None, 645).normal == 4000000 and CH.Groups.Prices(302).normal != 4000000)
run("C_Container, C_Item.GetItemInfoInstant, C_Item.GetDetailedItemLevelInfo = STUB.oldC, STUB.oldII, nil")
d = CH.Auction.Decide(302, L.eval("{ { price = 2900000, qty = 3, mine = false }, { price = 2950000, qty = 1, mine = true } }"), 10)
check("auction: undercut the cheapest seller outside the account", d.action == "post" and d.price == 2899900 and d.qty == 5)
d = CH.Auction.Decide(302, L.eval("{ { price = 2800000, qty = 1, mine = true }, { price = 2900000, qty = 3, mine = false } }"), 10)
check("auction: never undercut your own Warband, match it", d.action == "post" and d.price == 2800000)
d = CH.Auction.Decide(302, L.eval("{ { price = 10, qty = 3, mine = false } }"), 10)
check("auction: skip when the cheapest is under your min", d.action == "skip" and "min" in d.why)
run("Clearinghouse.Auction.RecordOwned({ { id = 302, qty = 3 } })")
d = CH.Auction.Decide(302, L.eval("{ }"), 10)
check("auction: the Warband's live auctions count toward the cap", CH.Auction.Listed(302) == 3 and d.qty == 2 and d.price == 3000000)
c = CH.Auction.DecideCancel(302, 3000000, L.eval("{ { price = 2950000, qty = 1, mine = true } }"))
check("cancel: your own alts never trigger a repost", c.action == "keep")
c = CH.Auction.DecideCancel(302, 3000000, L.eval("{ { price = 2950000, qty = 1, mine = false } }"))
check("cancel: someone else cheaper does", c.action == "cancel")
# Formulas in TSM's syntax
FV = lambda f, id=302: L.eval(f"Clearinghouse.Formula.Value({f!r}, {id})")
check("formula: money, percent, functions", FV("1g50s") == 15000 and FV("150% 2g") == 30000 and FV("max(1g, 2g, 3s)") == 20000
      and FV("first(nosuchsource, 5s)") == 500 and FV("ifgte(10, 5, 1g, 2g)") == 10000 and FV("check(0, 1g, 2g)") == 20000
      and FV("0.25*avg(4g, 8g)") == 15000 and FV("400%2c") == 8)
check("formula: a missing source makes the whole thing missing, bad syntax reads as invalid",
      FV("2 * nosuchsource") is None and not L.eval("(Clearinghouse.Formula.Valid('max(1g,'))"))

# TSM's auctioning setup, imported once (TSM's data only read)
run("""
Clearinghouse.Auction.RecordOwned({})
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
Clearinghouse.Groups.ResetTSM()
Clearinghouse.Ledger.ClearStats()
""")
imp = L.eval("Clearinghouse.Groups.ImportTSM()")
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
run("Clearinghouse.Groups.Store().ops['Flask Op'].priceReset = 'normalPrice'")
d = CH.Auction.Decide(302, L.eval("{ { price = 2900000, qty = 3, mine = false } }"), 10)
check("rules: below min resets to normal when set", d.action == "post" and d.price == 3150000)
run("Clearinghouse.Groups.Store().ops['Flask Op'].maxExpires = 1")
d = CH.Auction.Decide(302, L.eval("{ }"), 5)
check("rules: max expires stops posting after too many expiries without a sale", d.action == "skip" and "expired 1 times" in d.why)
run("Clearinghouse.Groups.Store().ops['Flask Op'].maxExpires = 0; Clearinghouse.Groups.Store().ops['Sell Loot'].maxExpires = 0")
d = CH.Auction.Decide(301, L.eval("{ }"), 5)
check("rules: keep in bags holds some back", d.action == "post" and d.qty == 4)
run("Clearinghouse.Groups.Store().ops['Flask Op'].learn = true; STUB.ledgerLearn = true")
lf, lwhy = L.eval("Clearinghouse.Groups.Learn(302)"), None
check("learn: too few sales and expiries changes nothing", lf == 1)
run("Clearinghouse.Groups.Store().ops['Flask Op'].learn = false")
run("Clearinghouse.Groups.Store().preferTSM = nil; TradeSkillMasterDB['p@Warband@userData@items'] = nil; Clearinghouse.Groups.ResetTSM()")
run("Clearinghouse.GroupsUI.Select('Crafted'); Clearinghouse.UI.Page('groups')")
grows = list(CH.GroupsUI.Refresh().values())
check("groups page: the group's items with their prices", any(r.id == 302 for r in grows) and CH.UI.IsShown())
check("groups now live in Settings: the old name opens them there", L.eval("Clearinghouse.UI.IsShown()"))
# Trading tab: what to post and mail, before you get to the AH
pp = {r.id: r for r in CH.TradingUI.PostPlan().values()}
check("trading: ready to post counts what every character holds in a posting group", 302 in pp and pp[302].held >= 3 and pp[302].verdict in ("post", "hold", "full"))
r302 = pp[302]
check("trading: posts no more than the group's cap less what's up", r302.post <= max(0, (r302.cap or 0) - r302.up))
run("Clearinghouse.Mail.Route('Crafted', 'Luxaren')")
mp = list(CH.TradingUI.MailPlan().values())
check("trading: to mail lists items on a character other than their route", any(r.id == 302 and r["from"] == "Courtizy" and r.to == "Luxaren" for r in mp))
run("Clearinghouse.Mail.Route('Crafted', nil)")
run("Clearinghouse.UI.Page('trading', 'post')")
check("trading tab opens on Ready to post", CH.LedgerUI.View() == "post")
run("Clearinghouse.Mail.Route('Crafted', 'Luxaren')")
pr, pf = L.eval("Clearinghouse.LedgerUI.Rows('post', {})")
mr, mf = L.eval("Clearinghouse.LedgerUI.Rows('mail', {})")
check("trading views: rows and a summary line", len(list(pr.values())) > 0 and "to post" in plain(pf) and len(list(mr.values())) > 0 and "to send" in plain(mf))
run("Clearinghouse.Mail.Route('Crafted', nil)")
check("auction panel builds", CH.AuctionUI.Build() is not None)
# Posting waits for the AH's answer
run("""
STUB.ahPosts = {}
Clearinghouse.Auction.BagSlots = function(id) return STUB.owlBags > 0 and { { bag = 0, slot = 1, count = 1 } } or {} end
STUB.owlBags = 2
""")
run("""
local AUI = Clearinghouse.AuctionUI
local plan = AUI.Plan()
for k in pairs(plan) do plan[k] = nil end
table.insert(plan, { id = 302, d = { action = "post", qty = 2, price = 11000099, duration = 2, why = "undercutting" } })
""")
L.execute("Clearinghouse.AuctionUI.PostNext()")
pp = L.eval("STUB.ahPosts[1]")
e = L.eval("Clearinghouse.AuctionUI.Plan()[1]")
check("post: whole silver only, one item per click, not done until the AH answers",
      pp.buyout == 11000000 and pp.qty == 1 and not e.done)
L.execute("Clearinghouse.AuctionUI.PostNext()")
check("post: no second post while one is waiting", L.eval("#STUB.ahPosts") == 1)
run('STUB.owlBags = 1; STUB.Fire("AUCTION_HOUSE_AUCTION_CREATED", 1)')
check("post: the AH's confirmation counts it, the rest stay to post", e.posted == 1 and not e.done and "1 of 2" in e.d.why)
L.execute("Clearinghouse.AuctionUI.PostNext()")
run('STUB.Fire("UI_ERROR_MESSAGE", 1, "Item not found"); STUB.RunTimers()')
check("post: no confirmation and still in bags means failed, with the game's reason",
      e.failed and e.done and e.d.why == "Item not found")

# A long post scan scrolls, and every row (not only the first) explains itself on hover
run("""
local plan = Clearinghouse.AuctionUI.Plan()
for k in pairs(plan) do plan[k] = nil end
for i = 1, 25 do table.insert(plan, { id = 302, other = 90000, d = { action = "skip", why = "row " .. i } }) end
Clearinghouse.AuctionUI.Refresh()
""")
h1 = [plain(l[1]) for l in L.eval("Clearinghouse.AuctionUI.HoverLines(1)").values()]
check("auction hover: the why in full, the cheapest rival and the operation's prices",
      "Skip: row 1" in h1 and "Cheapest outside your account" in h1 and any(x.startswith("Operation") for x in h1) and "  Min / normal / max" in h1)
check("auction hover: the last row has its own story too", plain(L.eval("Clearinghouse.AuctionUI.HoverLines(18)")[2][1]) == "Skip: row 18")
run("Clearinghouse.AuctionUI.Build().scripts.OnMouseWheel(nil, -1)")
check("auction panel: the wheel scrolls past the first 18 rows", plain(L.eval("Clearinghouse.AuctionUI.HoverLines(1)")[2][1]) == "Skip: row 4")
run("local plan = Clearinghouse.AuctionUI.Plan(); for k in pairs(plan) do plan[k] = nil end; Clearinghouse.AuctionUI.Refresh()")
tl = [plain(l[1]) for l in CH.TooltipLines("i:302").values()]
check("tooltip: shows how AuctionIQ will post it", "Posting" in tl and "  Min / normal / max" in tl)

run("Clearinghouse.Mail.Route('Crafted', 'Luxaren')")
check("mail: a group's route reaches its sub-groups", CH.Mail.Destination(302)[0] == "Luxaren" and CH.Mail.Destination(201) is None)
check("mail panel builds", CH.MailUI.Build() is not None)
run("Clearinghouse.Mail.Route('Crafted', nil)")
st = {e.id: e for e in LG.SaleTimes(-1e12).values()}
check("when it sells: weekday and 4-hour window per item", st[301].sold == 5 and 1 <= st[301].bestDay <= 7 and st[302].share == 1)
comp = {e.id: e for e in LG.Competition(-1e12).values()}
check("competition: post scans count how often you're beaten", comp[302].seen >= 3 and comp[302].beaten >= 1)
for v in ["when", "rivals"]:
    CH.LedgerUI.Rows(v, L.eval("{ }"))
run("Clearinghouse.db.token = { price = 2500000000, at = 1 }")
check("token value: gold read as tokens", CH.Alerts.InTokens(5000000000) == "2.0 tokens")
run("for _, c in pairs(Clearinghouse.db.characters) do for _, p in pairs(c.professions) do p.conc = p.concMax; p.concAt = STUB.now end end")
fired = list(CH.Alerts.Check().values())
again = list(CH.Alerts.Check().values())
check("alerts fire once, then wait 6 hours", any("Concentration is full" in f for f in fired) and len(again) == 0)
run("Clearinghouse.Planner.Store().kp['Seyko-Emerald Dream'] = { ['Midnight Enchanting'] = { first = { [Clearinghouse.Planner.WeekStart()] = 20 }, now = 26, unspent = 4 } }")
kn = list(CH.Planner.Knowledge().values())
check("knowledge: points gained this week per character and profession", kn[0].gained == 6 and kn[0].unspent == 4 and len(list(kn[0].tasks.values())) == 4)
check("knowledge: tick a weekly source", CH.Planner.Tick("Seyko-Emerald Dream", "Midnight Enchanting", "Treatise") == True and list(CH.Planner.Knowledge().values())[0].tasks[1].done)
run("SlashCmdList.CLEARINGHOUSE('event ' .. date('%Y-%m-%d', STUB.now + 3 * 86400) .. ' Season 2 starts')")
up = list(CH.Planner.Upcoming().values())
check("calendar: your dates with what they mean for demand", up[0].name.lower() == "season 2 starts" and "potions" in up[0].hint)
run("Clearinghouse.Planner.StartSession('Auction House'); STUB.now = STUB.now + 1800; Clearinghouse.Planner.StopSession('Auction House')")
tm = CH.Planner.Time(L.eval("STUB.now") - 86400)
check("gold per hour: time per activity", abs(tm.kinds["Auction House"] - 0.5) < 1e-9 and tm.perHour is not None)
run("Clearinghouse.UI.Page('plan')")
check("plan page draws", CH.UI.IsShown() and len(list(CH.PlanUI.Refresh().values())) == 1)
run("""function GetInboxNumItems() return 3 end
function GetInboxHeaderInfo(i) return nil, nil, 'x', 's', ({ 5000000, 0, 7000000 })[i], ({ 0, 0, 100 })[i], 1, i == 2 end""")
w = CH.Mail.Waiting()
check("mail: gold waiting before opening, cash on delivery left out", w.gold == 5000000 and w.mails == 3 and w["items"] == 1 and w.cod == 1)
check("mail: waiting gold adds up across characters for the briefing", CH.Mail.WaitingAll()[0] == 5000000 and "Waiting in mail" in plain(CH.UI.BriefingText()))
run("GetInboxNumItems = nil; GetInboxHeaderInfo = nil; Clearinghouse.Mail.Store().waiting = {}")
n7 = CH.ReportUI.Numbers(7)
check("report: 7 days of sales after cut, purchases, overhead", abs(n7.sales - 7000000 * 0.95) < 1 and n7.buys == 1000000 and n7.overhead == 20000)
run("Clearinghouse.UI.Page('briefing')")
check("briefing opens with the books", len(list(CH.ReportUI.Refresh().values())) == 5)
csvtext, nrows = CH.ReportUI.CSV("sales", L.eval("{ }"))
run("Clearinghouse.ReportUI.Export('sales', { days = 30 })")
check("export: a Ledger table as CSV", csvtext.split("\n")[0].startswith("Item,Character") and nrows == 3 and "300.00" in csvtext)
# rename: a fresh AuctionIQ takes over the old Clearinghouse saved data
run("""_G.__saved = AuctionIQDB; AuctionIQDB = nil; ClearinghouseDB = { queue = {}, marker = 42 }
STUB.Fire("ADDON_LOADED", "AuctionIQ")""")
check("rename: old Clearinghouse data moves into AuctionIQ", L.eval("AuctionIQDB.marker == 42 and Clearinghouse.db == AuctionIQDB and Clearinghouse.migrated and AuctionIQ == Clearinghouse"))
run("AuctionIQDB = _G.__saved; Clearinghouse.db = AuctionIQDB; Clearinghouse.migrated = nil; ClearinghouseDB = nil")
run("Clearinghouse.UI.Page('ledger')")
check("theme: the Clearinghouse tab is plum", L.eval("Clearinghouse.Theme.palette == 'clearinghouse' and Clearinghouse.Theme.hex.bg == '1c1222'"))
run("Clearinghouse.UI.Page('markets')")
check("theme: other pages are AuctionIQ navy", L.eval("Clearinghouse.Theme.palette == 'auctioniq' and Clearinghouse.Theme.hex.bg == '0e1729'"))
# AH scans: any search answered in the AH window is saved (Data/Scans.lua)
run("""C_AuctionHouse.GetNumItemSearchResults = function() return 3 end
C_AuctionHouse.GetItemSearchResultInfo = function(key, i) return ({ { buyoutAmount = 100000, quantity = 1 }, { buyoutAmount = 140000, quantity = 1 },
  { buyoutAmount = 90000, quantity = 1, containsOwnerItem = true } })[i] end""")
run('STUB.Fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 302 })')
sc = CH.Scans.Get(302)
check("scan: an item search is saved with its cheapest and market price", sc.min == 90000 and sc.market == 90000 and sc.qty == 3 and sc.full and sc.age == 0)
run("STUB.now = STUB.now - 3 * 86400; Clearinghouse.Scans.Record(302, { { price = 110000, qty = 1 } }, false); STUB.now = STUB.now + 3 * 86400")
run("Clearinghouse.Scans.Record(302, { { price = 123400, qty = 1 } }, false)")
sc = CH.Scans.Get(302)
check("scan: one market price a day makes a 7-day average", sc.days == 2 and abs(sc.avg7 - (110000 + (90000 + 123400) / 2) / 2) < 1 and sc.change7 > 0)
tl = [l[1] for l in CH.TooltipLines("item:302").values()]
check("tooltip: your last AH scan shows", "Your AH scan" in tl and any("7-day average" in x for x in tl))
run("Clearinghouse.Scans.RecordBrowse(302, 50000, 9)")
check("scan: a browse row doesn't replace a fresh full search", CH.Scans.Get(302).market == 123400)
run("Clearinghouse.Scans.RecordBrowse(303, 50000, 9)")
check("scan: a browse row is kept as cheapest price", CH.Scans.Get(303).min == 50000 and not CH.Scans.Get(303).full)
run("STUB.now = STUB.now + 31 * 86400; Clearinghouse.Scans.Prune(); STUB.now = STUB.now - 31 * 86400")
check("scan: items not seen in 30 days are dropped", CH.Scans.Get(303) is None)
run("Clearinghouse.db.scans = {}")
run("Clearinghouse.Auction.RecordOwned({})")
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
run("Clearinghouse.UI.Page('ledger')")
run("Clearinghouse.LedgerUI.Set({ view = 'sales', days = false, sort = 6, desc = true })")
shown = list(CH.LedgerUI.Refresh()[0].values())
check("ledger table sorts by any column", [r.sort[6] for r in shown] == sorted([r.sort[6] for r in shown], reverse=True) and len(shown) == 3)
run("Clearinghouse.LedgerUI.Set({ sort = 6, desc = false })")
shown = list(CH.LedgerUI.Refresh()[0].values())
check("and back the other way", [r.sort[6] for r in shown] == sorted(r.sort[6] for r in shown))
check("time frame reads like TSM's", CH.LedgerUI.Ago(L.eval("STUB.now") - 3 * 86400 - 7200, L.eval("STUB.now")) == "3 Days 2 Hr")
run("Clearinghouse.UI.Page('dashboard')")
check("dashboard page draws", CH.UI.IsShown())
run("Clearinghouse.UI.Page('dashboard')")
pt = CH.UI.ChartHover(10000)
check("chart hover: nearest point with who held what", pt.v == LG.Gold() and sorted(b.name for b in pt.by.values()) == ["Courtizy", "Luxaren", "Warband"])
run("Clearinghouse.UI.CharacterMenu(nil, 'Warband'); Clearinghouse.UI.CharacterMenu(nil, 'Luxaren')")
check("characters can be left out, warband too", LG.Gold() == 5000000 and not LG.Included("Warband"))
last = list(LG.GoldSeries(L.eval("STUB.now") - 86400, L.eval("STUB.now"), 2).values())[1]
check("the chart leaves them out too", last.v == 5000000 and len(list(last.by.values())) == 1)
run("Clearinghouse.UI.CharacterMenu(nil, 'Warband'); Clearinghouse.UI.CharacterMenu(nil, 'Luxaren')")
check("and back in", LG.Gold() == 10000000)
run("Clearinghouse.UI.Page('ledger'); Clearinghouse.UI.Page('briefing')")
check("ledger and briefing pages draw", CH.UI.IsShown())

# Phase 1: six tabs, old names still work, shared table page sections
LUI = CH.LedgerUI
run("Clearinghouse.UI.Page('briefing')")
check("report opens inside the Clearinghouse tab", LUI.Section() == "ledger" and LUI.View() == "report" and CH.Theme.palette == "clearinghouse")
run("Clearinghouse.UI.Page('analytics', 'dead')")
check("analytics shows its own views", LUI.Section() == "analytics" and LUI.View() == "dead")
run("Clearinghouse.UI.Page('markets')")
check("markets opens on compare prices", LUI.Section() == "markets" and LUI.View() == "compare")
mfoot = L.eval("select(2, Clearinghouse.LedgerUI.Rows('market', {}))")
mrows0 = list(L.eval("(Clearinghouse.LedgerUI.Rows('market', {}))").values())
check("market prices without the app come from TSM", len(mrows0) >= 1 and "TSM (60-day avg)" in plain(mfoot) and "Clearinghouse app" not in plain(mfoot))
run("OEMarketInfo = function(item, t) if item == 'item:301' then t.market = 25000; t.region = 24000; t.days = 1 end return t end")
oe = CH.Prices.Oribos(301)
check("Oribos Exchange read directly", oe.market == 25000 and oe.region == 24000)
run("STUB.savedPrices = STUB.prices; STUB.prices = {}; Clearinghouse.Prices.ClearCache()")
m301 = CH.Prices.MarketAny(301)
mfoot2 = L.eval("select(2, Clearinghouse.LedgerUI.Rows('market', {}))")
check("market prices fall back to Oribos Exchange without TSM data", m301.market == 25000 and m301.source == "oribos" and "Oribos Exchange" in plain(mfoot2))
run("STUB.prices = STUB.savedPrices; OEMarketInfo = nil; Clearinghouse.Prices.ClearCache()")
run("STUB.now = STUB.now - 2 * 86400; Clearinghouse.Scans.Record(301, { { price = 18000, qty = 40 } }, true); STUB.now = STUB.now + 2 * 86400")
run("Clearinghouse.Scans.Record(301, { { price = 22000, qty = 40 } }, true)")
mrows = L.eval("(Clearinghouse.LedgerUI.Rows('market', {}))")
r301 = [r for r in mrows.values() if r.id == 301]
mfoot3 = L.eval("select(2, Clearinghouse.LedgerUI.Rows('market', {}))")
check("market prices use your AH scans first", len(r301) == 1 and "+10%" in plain(r301[0].cells[5]) and "your AH scans" in plain(mfoot3))
# Compare prices: AH scan vs TSM vs Oribos (Data/Compare.lua)
tsm301 = CH.Prices.Raw("dbmarket", 301)
cr = CH.Compare.Row(301)
check("compare: realm prices side by side with a gap", cr.ah == 22000 and cr.tsm == tsm301 and cr.ahFresh and cr.gap is not None and abs(cr.gap - (22000 / tsm301 - 1)) < 1e-9)
run("OEMarketInfo = function(item, t) if item == 'item:301' then t.market = 40000; t.region = 30000 end return t end")
cr = CH.Compare.Row(301)
check("compare: Oribos joins and the gap is against the middle of TSM and Oribos", cr.oe == 40000 and cr.oeRegion == 30000 and abs(cr.gap - (22000 / ((tsm301 + 40000) / 2) - 1)) < 1e-9)
check("compare: well under the others reads cheap now", (cr.verdict == "cheap now") == (22000 <= 0.85 * (tsm301 + 40000) / 2))
run("Clearinghouse.db.scans[301].at = STUB.now - 2 * 86400")
cr = CH.Compare.Row(301)
check("compare: an old scan is shown but not judged", not cr.ahFresh and cr.gap is None and cr.verdict in ("agree", "disagree"))
crow = [r for r in L.eval("(Clearinghouse.LedgerUI.Rows('compare', {}))").values() if r.id == 301]
check("compare view lists the item with each source", len(crow) == 1 and "2 days" in plain(crow[0].cells[3]) and plain(crow[0].cells[8]) == cr.verdict)
check("compare: median of an even list", CH.Compare.Median(L.eval("{ 4, 1, 3, 2 }")) == 2.5)
run("OEMarketInfo = nil; Clearinghouse.db.scans = {}; Clearinghouse.Prices.ClearCache()")
tfoot = L.eval("select(2, Clearinghouse.LedgerUI.Rows('time', { days = 30 }))")
check("gold per hour moved to analytics", "hours" in plain(tfoot))
run("Clearinghouse.UI.Page('ledger')")
check("the Clearinghouse remembers its last view", LUI.Section() == "ledger" and LUI.View() == "report")
run("Clearinghouse.UI.Page('groups')"); run("Clearinghouse.UI.Page('plan')"); run("Clearinghouse.UI.Page('dashboard')")
check("old page names open the new tabs", CH.UI.IsShown())
nxt = list(CH.Next.List().values())
check("do next is ranked, leaking value first", len(nxt) > 0 and all(nxt[i].tier <= nxt[i + 1].tier for i in range(len(nxt) - 1)))
# Do next cards carry a button that does the job: queue the Concentration craft or the restock
run("""STUB.oldConcNow = Clearinghouse.ConcentrationNow
Clearinghouse.ConcentrationNow = function(p) if p.name == 'Test Alchemy' then return 1000, 1000 end return STUB.oldConcNow(p) end
Clearinghouse.db.characters['Alt-Realm'] = { name = 'Alt', class = 'MAGE', professions = { [99] = { name = 'Test Alchemy', scan = { rows = {
  { recipeID = 10, name = 'Test Flask', item = 100, made = 1, profit = 1000, perPoint = 50, concProfit = 15000, concentration = 300, concQuality = 2,
    accounts = { cost = 500, reagents = { { itemID = 201, n = 2 } }, queue = { { itemID = 201, slot = 1, n = 2 } } },
    concAccounts = { cost = 500, reagents = { { itemID = 201, n = 2 } }, queue = { { itemID = 201, slot = 1, n = 2 } } } } } } } } }
Clearinghouse.Queue.Clear()""")
spend = [e for e in CH.Next.List().values() if e.title == "Spend Concentration" and "Alt" in e.detail]
check("do next: full Concentration names the best craft per point and how many", len(spend) == 1 and "x3" in spend[0].detail and spend[0].act is not None)
acted = L.eval("(function() for _, e in ipairs(Clearinghouse.Next.List()) do if e.title == 'Spend Concentration' and e.act and e.detail:find('Alt') then return { e.act.run() } end end end)()")
check("do next: the button says what it did, for the card", acted[1] is True and "Queued 3 x Test Flask with Concentration for Alt" == acted[2])
qe = list(CH.db.queue.values())
check("do next: its button queues that craft with Concentration for that character", len(qe) == 1 and qe[0].char == "Alt-Realm" and qe[0].qty == 3
      and qe[0].concentration == 300 and qe[0].reagents[1].slot == 1)
k = L.eval("{ Clearinghouse.Queue.ScanRowFor(100) }")
check("do next: a restock finds the saved scan that makes the item", k[1] == "Alt-Realm" and k[3].recipeID == 10)
run("Clearinghouse.UI.Page('today')")
d = L.eval("Clearinghouse.UI and nil")
run("Clearinghouse.Queue.Clear(); Clearinghouse.db.characters['Alt-Realm'] = nil; Clearinghouse.ConcentrationNow = STUB.oldConcNow")
check("crafting tab text has Concentration and best crafts", "Concentration" in plain(CH.UI.CraftingText()) and "Best crafts" in plain(CH.UI.CraftingText()))
check("the report still has everything", "Best crafts" in plain(CH.UI.BriefingText()) and "Gold" in plain(CH.UI.BriefingText()))

# recipe scan: how many you can make now, with finishing reagents and Concentration
run("STUB.bags[901] = 10; STUB.bags[902] = 3; STUB.bags[903] = 1")
cr = L.eval("{ Clearinghouse.Scan.Craftable({ accounts = { reagents = { { itemID = 901, n = 2 }, { itemID = 902, n = 1 } } }, concAccounts = { reagents = { { itemID = 901, n = 2 }, { itemID = 903, n = 1 } } }, concentration = 300 }, 650) }")
check("scan: can make counts the scarcest reagent", cr[1] == 3 and cr[3] == 902)
check("scan: with Concentration, a finishing reagent or the points cap it", cr[2] == 1 and cr[4] == 903)
cr2 = L.eval("{ Clearinghouse.Scan.Craftable({ concAccounts = { reagents = { { itemID = 901, n = 1 } } }, concentration = 300 }, 650) }")
check("scan: Concentration points can be the limit", cr2[2] == 2 and cr2[4] == "concentration")

# paths: profession trees that report every node at 0,0 get a tidy tree layout
lay = L.eval("Clearinghouse.TreeView.Layout({ nodes = { 1, 2, 3, 4 } }, { [1] = { x = 0, y = 0 }, [2] = { x = 0, y = 0, parent = 1 }, [3] = { x = 0, y = 0, parent = 1 }, [4] = { x = 0, y = 0, parent = 2 } })")
check("paths tree: root on top, children a row below, spread out", lay[1].y == 0 and lay[2].y == 1 and lay[4].y == 2 and lay[2].x != lay[3].x and lay[1].x == (lay[2].x + lay[3].x) / 2)
lay2 = L.eval("Clearinghouse.TreeView.Layout({ nodes = { 1, 2 } }, { [1] = { x = 10, y = 5 }, [2] = { x = 40, y = 90, parent = 1 } })")
check("paths tree: the game's own positions win when it gives them", lay2[2].x == 40 and lay2[2].y == 90)

# Queue first crafts and work orders
run("Clearinghouse.Queue.Clear(); STUB.recipeIDs = { 10 }; local g = C_TradeSkillUI.GetRecipeInfo; STUB.oldInfo = g; C_TradeSkillUI.GetRecipeInfo = function(id) local i = g(id); if id == 10 then i.firstCraft = true end return i end")
n1 = L.eval("(Clearinghouse.Queue.FillFirstCrafts())")
fq = list(CH.db.queue.values())
check("first crafts: unmade recipes queue once each, cheapest, marked 1KP", n1 == 1 and fq[0].firstCraft and fq[0].qty == 1 and not fq[0].concentration)
fc = list(CH.Orders.FirstCrafts().values())
check("first crafts list: each recipe with its cheapest reagents and what the point costs", len(fc) == 1 and fc[0].recipeID == 10 and fc[0].cost == fq[0].cost
      and abs(fc[0].net - ((fc[0].value or 0) - fc[0].cost)) < 1e-6)
run("Clearinghouse.Queue.Clear(); Clearinghouse.ScanUI.Open(); Clearinghouse.ScanUI.SetMode('first')")
frows = list(CH.ScanUI.Refresh().values())
check("scan tab: First crafts lists the recipe", CH.ScanUI.IsShown() and CH.ScanUI.Mode() == "first" and len(frows) == 1 and "net=" in frows[0])
check("scan tab: Queue all queues every first craft", CH.ScanUI.QueueAll() == 1 and list(CH.db.queue.values())[0].firstCraft)
run("C_TradeSkillUI.GetRecipeInfo = STUB.oldInfo; STUB.recipeIDs = nil; Clearinghouse.Queue.Clear()")
run("""C_CraftingOrders = { GetCrafterOrders = function() return { { orderID = 77, spellID = 10, minQuality = 1, tipAmount = 50000000, consortiumCut = 0, customerName = 'Patron', reagents = {} } } end, ClaimOrder = function(id) STUB.claimed = id; STUB.claimedOrder = { orderID = id, isFulfillable = false, reagents = {} } end, FulfillOrder = function(id) STUB.fulfilled = id end,
  GetClaimedOrder = function() return STUB.claimedOrder end }""")
n2 = L.eval("(Clearinghouse.Queue.FillOrders())")
oq = list(CH.db.queue.values())
check("orders: a paying order is queued with its order ID", n2 == 1 and oq[0].orderID == "77")
check("orders: the button goes Claim first", CH.Queue.OrderStep(oq[0]) == "Claim")
run("Clearinghouse.Queue.Craft(Clearinghouse.db.queue[1])")
check("orders: Claim claims it, then Craft", L.eval("STUB.claimed") == 77 and CH.Queue.OrderStep(oq[0]) == "Craft")
run("Clearinghouse.Queue.Craft(Clearinghouse.db.queue[1])")
check("orders: crafting passes the claimed order's ID", L.eval("STUB.crafted.id") == 10 and L.eval("STUB.crafted.order") == 77)
run('STUB.claimedOrder.isFulfillable = true; STUB.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 10); STUB.RunTimers()')
check("orders: after the craft it's Turn in", CH.Queue.OrderStep(oq[0]) == "Turn in")
run("Clearinghouse.Queue.Craft(Clearinghouse.db.queue[1])")
check("orders: Turn in fulfils it and it leaves the queue", L.eval("STUB.fulfilled") == 77 and CH.Queue.Count() == 0)
run('STUB.Fire("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 5, 77)')
check("orders: a turn-in the game refuses comes back to the top", CH.Queue.Count() == 1 and CH.Queue.OrderStep(CH.db.queue[1]) == "Turn in")
run("Clearinghouse.Queue.Clear(); STUB.claimed = nil; STUB.fulfilled = nil; STUB.claimedOrder = nil; C_CraftingOrders.GetClaimedOrder = nil")
# One button: Next step walks claim, craft, turn in
run("Clearinghouse.Queue.FillOrders()")
st = L.eval("(Clearinghouse.Queue.DoNext())")
check("next step: first click claims", st == "Claim" and L.eval("STUB.claimed") == 77)
run('STUB.Fire("CRAFTINGORDERS_CLAIM_ORDER_RESPONSE", 3, 77)')
check("next step: a refused claim goes back to Claim", CH.Queue.OrderStep(CH.db.queue[1]) == "Claim")
run("Clearinghouse.Queue.DoNext()")
run("C_CraftingOrders.GetClaimedOrder = function() return { orderID = 77, isFulfillable = false } end")
st = L.eval("(Clearinghouse.Queue.DoNext())")
check("next step: then crafts", st == "Craft" and L.eval("STUB.crafted.id") == 10)
run("C_CraftingOrders.GetClaimedOrder = function() return { orderID = 77, isFulfillable = true } end")
check("next step: the game saying it's done means Turn in", CH.Queue.OrderStep(CH.db.queue[1]) == "Turn in")
st = L.eval("(Clearinghouse.Queue.DoNext())")
check("next step: then turns it in", st == "Turn in" and L.eval("STUB.fulfilled") == 77 and CH.Queue.Count() == 0)
run("C_CraftingOrders.GetClaimedOrder = nil")
# Crafting an order crafts into the live claimed order, leaves out the customer's reagents, and only counts once the game says it's done
run("""Clearinghouse.Queue.Clear(); STUB.claimed = nil; STUB.fulfilled = nil; STUB.crafted = nil; STUB.created = nil; STUB.completed = nil
Clearinghouse.Queue.FillOrders(); Clearinghouse.Queue.DoNext()
STUB.claimedOrder = { orderID = 77, isFulfillable = false, reagents = { { reagentInfo = { reagent = { itemID = 201 } } } } }
C_CraftingOrders.GetClaimedOrder = function() return STUB.claimedOrder end
ProfessionsFrame = ProfessionsFrame or { IsShown = function() return true end }
ProfessionsFrame.OrdersPage = ProfessionsFrame.OrdersPage or {}
ProfessionsFrame.OrdersPage.OrderView = { order = { orderID = 77 }, IsShown = function() return true end,
  CreateButton = { Click = function() STUB.created = true end, IsEnabled = function() return true end },
  CompleteOrderButton = { Click = function() STUB.completed = true end, IsShown = function() return true end, IsEnabled = function() return true end } }""")
st = L.eval("(Clearinghouse.Queue.DoNext())")
check("order craft: crafts into the claimed order", st == "Craft" and L.eval("STUB.crafted.order") == 77)
check("order craft: the customer's reagents aren't sent as ours", L.eval("(function() for _, r in ipairs(STUB.crafted.reagents) do if r.itemID == 201 then return false end end return true end)()"))
# an order needing rank 2 that these reagents only reach with Concentration: craft with it on
run("""STUB.crafted = nil; STUB.claimedOrder.minQuality = 2; STUB.extraSkill = -1000; Clearinghouse.Queue.DoNext(); STUB.extraSkill = nil""")
check("order craft: turns Concentration on when the order's rank needs it", L.eval("STUB.crafted.conc") is True and L.eval("STUB.crafted.order") == 77)
run("STUB.claimedOrder.minQuality = 9; STUB.crafted = nil")
st = L.eval("{ Clearinghouse.Queue.DoNext() }")
check("order craft: refuses, and says why, when even Concentration can't reach the rank", L.eval("STUB.crafted") is None and "needs rank 9" in str(st[2]))
run("STUB.claimedOrder.minQuality = nil")
run('STUB.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 10); STUB.RunTimers()')
check("order craft: a craft that didn't go into the order stays Craft", CH.Queue.OrderStep(CH.db.queue[1]) == "Craft")
run('STUB.claimedOrder.isFulfillable = true')
st = L.eval("(Clearinghouse.Queue.DoNext())")
check("order craft: Turn in fulfils the claimed order", st == "Turn in" and L.eval("STUB.fulfilled") == 77 and CH.Queue.Count() == 0)
run("C_CraftingOrders.GetClaimedOrder = nil; ProfessionsFrame.OrdersPage.OrderView = nil")
run("STUB.claimed = nil; Clearinghouse.ScanUI.Open(); Clearinghouse.ScanUI.SetMode('orders'); Clearinghouse.ScanUI.Next()")
check("next step button: queues the paying orders and claims the first", CH.Queue.Count() == 1 and L.eval("STUB.claimed") == 77)
run("""STUB.viewed = nil; ProfessionsFrame = ProfessionsFrame or { IsShown = function() return true end }
ProfessionsFrame.craftingOrdersTabID = 3; ProfessionsFrame.tab = 1
ProfessionsFrame.GetTab = function(self) return self.tab end; ProfessionsFrame.SetTab = function(self, t) self.tab = t end
ProfessionsFrame.OrdersPage = ProfessionsFrame.OrdersPage or {}
ProfessionsFrame.OrdersPage.ViewOrder = function(_, o) STUB.viewed = o.orderID end
Clearinghouse.Orders.Open({ orderID = 77 }, 10)""")
check("clicking an order opens it on the Crafting Orders tab", L.eval("STUB.viewed") == 77 and L.eval("ProfessionsFrame.tab") == 3)
run("Clearinghouse.ScanUI.SetMode('recipes'); Clearinghouse.Queue.Clear()")
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
run("Clearinghouse.ScanUI.SetMode('orders')")
orows = list(CH.ScanUI.Refresh().values())
check("scan tab: lists orders with 1KP flagged", len(orows) == 3 and "kp=true" in orows[0])
tip = [plain(l[1]) for l in CH.ScanUI.OrderLines(by[78]).values()]
check("scan tab hover: the knowledge reward is named", any("Knowledge Notes" in t and "knowledge" in t for t in tip))
run("Clearinghouse.Queue.Clear()")
check("scan tab: Queue all queues orders that pay or give knowledge", CH.ScanUI.QueueAll() == 2)
run("Clearinghouse.Queue.Clear(); STUB.oldCount = C_Item.GetItemCount; C_Item.GetItemCount = function() return 0 end")
nohave = list(CH.Orders.List().values())
check("orders: each says whether you hold the reagents, and which are missing", not nohave[0].have and len(list(nohave[0].missing.values())) > 0)
CH.ScanUI.Refresh(); check("orders: Queue all skips orders you don't have the reagents for", CH.ScanUI.QueueAll() == 0)
tipm = [plain(l[1]) for l in CH.ScanUI.OrderLines(nohave[0]).values()]
check("orders hover: lists the missing reagents", "Missing reagents" in tipm)
run("C_Item.GetItemCount = STUB.oldCount; Clearinghouse.Queue.Clear(); Clearinghouse.ScanUI.Refresh(); Clearinghouse.ScanUI.QueueAll()")
# orders from an older expansion are tagged, and Older: hidden leaves them out
run("""STUB.oldLine = C_TradeSkillUI.GetTradeSkillLineForRecipe
C_TradeSkillUI.GetTradeSkillLineForRecipe = function(id) if id == 10 then return 2871, 'Khaz Algar Alchemy' end return 2906, 'Midnight Alchemy' end
STUB.oldInfos = C_TradeSkillUI.GetChildProfessionInfos
C_TradeSkillUI.GetChildProfessionInfos = function() return { { professionID = 2906, expansionName = 'Midnight' }, { professionID = 2871, expansionName = 'Khaz Algar' } } end""")
olist = list(CH.Orders.List().values())
check("orders: each order knows its expansion and whether it's the current one", olist[0].expansion == "Khaz Algar" and not olist[0].current)
run("Clearinghouse.ScanUI.ToggleOlder()")
check("orders: Older: hidden leaves older-expansion orders out", len(list(CH.ScanUI.Refresh().values())) == 0)
run("Clearinghouse.ScanUI.ToggleOlder()")
check("orders: Older: shown brings them back", len(list(CH.ScanUI.Refresh().values())) == 3)
run("C_TradeSkillUI.GetTradeSkillLineForRecipe = STUB.oldLine; C_TradeSkillUI.GetChildProfessionInfos = STUB.oldInfos")
run("Clearinghouse.ScanUI.SortBy('from')")
srt = list(CH.ScanUI.Refresh().values())
check("scan tab: clicking a header sorts by that column", srt[0].startswith("Test Flask from=Pat ") and "from=Patron" in srt[-1])
run("Clearinghouse.ScanUI.SortBy('from')")
check("scan tab: clicking the same header flips it", "from=Patron" in list(CH.ScanUI.Refresh().values())[0])
run("Clearinghouse.ScanUI.SetMode('recipes')")
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
Clearinghouse.Orders.cache = {}
STUB.fetched = nil
Clearinghouse.Orders.Fetch(function(n) STUB.fetched = n end)
for i = 1, 40 do STUB.Fire("CRAFTINGORDERS_CAN_REQUEST"); STUB.RunTimers() end""")
check("orders fetch: asks for patron, personal, public and guild, retrying a throttle", L.eval("STUB.fetched") == 4
      and len(list(L.eval("STUB.requests").values())) == 5)
check("orders fetch: the list holds every kind, not just the last one shown", len(list(CH.Orders.List().values())) == 4)
check("/aiq orders explains each order without erroring", L.eval("(pcall(Clearinghouse.Orders.Debug))"))
check("orders fetch: order IDs compare as text", L.eval("Clearinghouse.Orders.Same(77, '77')") and not L.eval("Clearinghouse.Orders.Same(77, nil)"))
run("C_CraftingOrders.GetCrafterOrders = STUB.oldList; C_CraftingOrders.RequestCrafterOrders = nil; Clearinghouse.Orders.cache = {}")
run("Clearinghouse.Queue.Clear(); C_CraftingOrders = nil; C_Item.GetItemNameByID = nil")

# warbound and soulbound items can't go on the AH: no value, and the tooltip says so
run("C_Item.GetItemInfo = function(id) if id == 302 then return 'Warbound Cloak', nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, 7 end end")
inv2 = {e.id: e for e in LG.Inventory().values()}
check("warbound items count as held but worth nothing", 302 in inv2 and inv2[302].bound and inv2[302].value == 0)
check("the tooltip says it can't go on the AH", "can't go on the AH" in plain(CH.TooltipLines("i:302")[1][2]))
check("other items keep their value", CH.Unsellable(100) is False or CH.Unsellable(100) is None or not CH.Unsellable(100))
run("C_Item.GetItemInfo = nil")

# Settings: what the commands did, as buttons; operations and price sources without commands
S = CH.Settings
run("Clearinghouse.UI.Page('settings')")
names = list(CH.SettingsUI.Refresh().values())
check("settings: opens from the window and lists the operations, Default first", names[0] == "Default" and "Crafted" in names)
was = S.Get("coins")
run("Clearinghouse.Settings.Flip('coins')")
check("settings: a toggle does what /aiq coins did", S.Get("coins") == (not was) and L.eval("Clearinghouse.db.settings.coins") == (not was))
run("Clearinghouse.Settings.Flip('coins')")
run("Clearinghouse.Settings.DailyCap(20)")
check("settings: gold a day cap", L.eval("Clearinghouse.db.settings.scan.dailyCap") == 20)
check("settings: a new operation copies Default", S.NewOp("Flasks") == "Flasks" and CH.Groups.Store().ops.Flasks.floorPct == CH.Groups.Store().ops.Default.floorPct)
check("settings: names can't repeat", S.NewOp("Flasks")[0] is None)
run("Clearinghouse.Settings.OpStep('Flasks', 'priceReset', 1); Clearinghouse.Settings.OpStep('Flasks', 'duration', 1); Clearinghouse.Settings.OpStep('Flasks', 'undercut', 1)")
fl = CH.Groups.Store().ops.Flasks
check("settings: picks cycle and numbers step", fl.priceReset == "minPrice" and fl.duration == 3 and fl.undercut == 101)
ok, err = S.SetOpFormula("Flasks", "minPrice", "max(")
check("settings: a bad formula is refused with the reason", ok is False and err and fl.minPrice is None)
check("settings: a good formula saves", S.SetOpFormula("Flasks", "minPrice", "80% chvalue") is True and fl.minPrice == "80% chvalue")
run("Clearinghouse.Groups.Assign('Crafted', 'Flasks')")
check("settings: renaming keeps the groups that use it", S.RenameOp("Flasks", "Flask rules") == "Flask rules" and CH.Groups.Store().assign.Crafted == "Flask rules")
check("settings: built-in operations can't be deleted", S.DeleteOp("Default")[0] is None and S.DeleteOp("Crafted")[0] is None)
check("settings: deleting one sends its groups back to inheriting", S.DeleteOp("Flask rules") == 1 and CH.Groups.Store().assign.Crafted is None)
check("settings: a price source saves", S.SetSource("MyFloor", "max(vendorsell, 1g)") is True and CH.Formula.Custom().myfloor == "max(vendorsell, 1g)")
check("settings: a source can't take a built-in name", S.SetSource("dbmarket", "1g")[0] is False)
check("settings: a source with a bad formula is refused", S.SetSource("broken", "min(")[0] is False)
check("settings: the source works in formulas", CH.Formula.Value("myfloor", 302) == 10000)
run("Clearinghouse.Settings.DeleteSource('myfloor')")
check("settings: delete a source", CH.Formula.Custom().myfloor is None)
run("Clearinghouse.Settings.UseTSM(false)")
check("settings: TSM groups off", CH.Groups.Store().useTSM is False)
run("Clearinghouse.Settings.UseTSM(true)")

# layout: nothing outside its panel, no one-line text cut off, button labels fit
L.execute((ROOT / "tests" / "layout_audit.lua").read_text())
audit_all = []
def audit(where):
    roots = L.eval("(function() local r = {} for _, f in ipairs(STUB.frames) do if (f.parent == nil or f.parent == UIParent) and f.w > 0 then table.insert(r, f) end end return r end)()")
    for p in L.eval("STUB.Audit")(roots).values():
        audit_all.append(where + ": " + p)
for tab in ["today", "markets", "crafting", "trading", "analytics", "ledger", "report", "settings"]:
    run(f"Clearinghouse.UI.Page('{tab}')")
    audit(tab)
for v in ["compare", "inventory", "sales", "income", "resale", "purchases", "expense", "expired", "cancelled", "pl", "holdings", "overhead", "market", "rivals", "when", "par", "dead", "time", "perf"]:
    run(f"Clearinghouse.UI.Page('ledger', '{v}')")
    audit("view " + v)
run("Clearinghouse.UI.Page('today')")
for w in ["ScanUI", "PathsUI", "QueueUI", "LogUI"]:
    run(f"if Clearinghouse.{w} and Clearinghouse.{w}.Toggle then pcall(Clearinghouse.{w}.Toggle) end")
    audit(w)
# Review fixes ---------------------------------------------------------------------------------
# 1. a browse doesn't make an old buying ladder look fresh, and a browse at a different price drops it
run("""Clearinghouse.db.scans = Clearinghouse.db.scans or {}
Clearinghouse.Scans.Record(950, { { price = 10000, qty = 100 }, { price = 20000, qty = 100 } }, true)""")
lad, at = L.eval("Clearinghouse.Scans.Depth(950)")
run("Clearinghouse.db.scans[950].ladderAt = Clearinghouse.db.scans[950].ladderAt - 7200; Clearinghouse.db.scans[950].at = Clearinghouse.db.scans[950].at - 7200")
run("Clearinghouse.Scans.RecordBrowse(950, 10000, 200)")
lad2, at2 = L.eval("Clearinghouse.Scans.Depth(950)")
check("scans: a browse at the same price keeps the ladder with its own, older time", lad2 is not None and L.eval("time()") - at2 >= 7200)
run("Clearinghouse.Scans.RecordBrowse(950, 90000, 50)")
check("scans: a browse at a different cheapest price drops the stale ladder", L.eval("Clearinghouse.Scans.Depth(950)") is None)
# 2. Open all stops when the inbox stops changing (bags full) instead of looping, and says why
run("""STUB.loots = 0; STUB.openDone = nil
function GetInboxNumItems() return 1 end
function GetInboxHeaderInfo(i) return nil, nil, 'x', 's', 0, 0, 1, 1 end
function AutoLootMailItem() STUB.loots = STUB.loots + 1 end
Clearinghouse.Mail.OpenAll(function(n, gold, why) STUB.openDone = { n = n, why = why } end)
for i = 1, 20 do STUB.RunTimers() end""")
check("mail: Open all gives up on a mail it can't take, and says why", L.eval("STUB.openDone") is not None and L.eval("STUB.loots") <= 4
      and "bags" in str(L.eval("STUB.openDone.why")) and L.eval("STUB.openDone.n") == 0)
run("""STUB.loots = 0; STUB.openDone = nil; STUB.mails = 2
function GetInboxNumItems() return STUB.mails end
function GetInboxHeaderInfo(i) return nil, nil, 'x', 's', 100, 0, 1, nil end
function AutoLootMailItem() STUB.loots = STUB.loots + 1; STUB.mails = STUB.mails - 1 end
Clearinghouse.Mail.OpenAll(function(n, gold, why) STUB.openDone = { n = n, why = why } end)
for i = 1, 20 do STUB.RunTimers() end""")
check("mail: Open all counts the mails it really took", L.eval("STUB.openDone.n") == 2 and L.eval("STUB.openDone.why") is None)
run("GetInboxNumItems = nil; GetInboxHeaderInfo = nil; AutoLootMailItem = nil")
# 3. the same name on two realms: separate sellers, and only this realm counts
run("""Clearinghouse.db.auctions = {}
Clearinghouse.Auction.RecordOwned({ { id = 951, qty = 3 } })
STUB.oldRealm = GetRealmName; GetRealmName = function() return 'Other Realm' end
Clearinghouse.Auction.RecordOwned({ { id = 951, qty = 7 } })""")
check("auctions: the same name on another realm doesn't overwrite this realm's record", L.eval("Clearinghouse.Auction.Listed(951)") == 7)
run("GetRealmName = STUB.oldRealm")
check("auctions: each realm counts its own listings", L.eval("Clearinghouse.Auction.Listed(951)") == 3)
run("Clearinghouse.db.auctions = {}")
# 5. the ledger sees a record that changed without changing length
run("""STUB.oldSales = TradeSkillMasterDB["r@Emerald Dream@internalData@csvSales"]
TradeSkillMasterDB["r@Emerald Dream@internalData@csvSales"] = [[itemString,stackSize,quantity,price,otherPlayer,player,time,source\ni:952,1,1,10000,Bob,Courtizy,100,Auction]]
""")
p1 = L.eval("(function() for _, r in ipairs(Clearinghouse.Ledger.Records('Sales')) do if r.id == 952 then return r.price end end end)()")
run("""TradeSkillMasterDB["r@Emerald Dream@internalData@csvSales"] = [[itemString,stackSize,quantity,price,otherPlayer,player,time,source\ni:952,1,1,90000,Bob,Courtizy,100,Auction]]
""")
p2 = L.eval("(function() for _, r in ipairs(Clearinghouse.Ledger.Records('Sales')) do if r.id == 952 then return r.price end end end)()")
check("ledger: an edited record of the same length is read again", p1 == 10000 and p2 == 90000)
run("""TradeSkillMasterDB["r@Emerald Dream@internalData@csvSales"] = STUB.oldSales; Clearinghouse.Ledger.ClearStats()""")

# Shopping: buy the queue's reagents at the AH, quoted first, confirmed on a second click
run("""STUB.buys = {}
C_AuctionHouse.StartCommoditiesPurchase = function(id, n) table.insert(STUB.buys, { 'start', id, n }) end
C_AuctionHouse.ConfirmCommoditiesPurchase = function(id, n) table.insert(STUB.buys, { 'confirm', id, n }) end
STUB.prices['i:981'] = { mat = 10000 }; STUB.prices['i:982'] = { mat = 10000 }; Clearinghouse.Prices.ClearCache()
Clearinghouse.AuctionUI.Build()""")
d1 = L.eval("Clearinghouse.AuctionUI.DecideBuy({ itemID = 981, need = 5, have = 1, buy = 4 }, { { price = 10500, qty = 10 } })")
d2 = L.eval("Clearinghouse.AuctionUI.DecideBuy({ itemID = 982, need = 5, have = 0, buy = 5 }, { { price = 20000, qty = 10 } })")
check("shopping: buys at the live price, skips one far over the usual price", d1.action == "buy" and d1.qty == 4 and d1.unit == 10500
      and d2.action == "skip" and "100%" in d2.why)
run("""STUB.oldSL = Clearinghouse.Queue.ShoppingList; STUB.oldSearch = Clearinghouse.Auction.Search
Clearinghouse.Queue.ShoppingList = function() return { { itemID = 981, need = 5, have = 1, buy = 4 }, { itemID = 982, need = 5, have = 0, buy = 5 } } end
Clearinghouse.Auction.Search = function(id, done) done(id == 981 and { { price = 10500, qty = 10 } } or { { price = 20000, qty = 10 } }) end
Clearinghouse.AuctionUI.ShopScan(); for i = 1, 5 do STUB.RunTimers() end""")
plan = L.eval("Clearinghouse.AuctionUI.Plan()")[0]
check("shopping: Shop queue lists the queue's buys first", plan[1].id == 981 and plan[1].d.action == "buy" and plan[2].d.action == "skip")
run("Clearinghouse.AuctionUI.BuyNext()")
check("shopping: the first click asks for a quote, nothing bought yet", L.eval("#STUB.buys") == 1 and L.eval("STUB.buys[1][1]") == "start" and L.eval("STUB.buys[1][3]") == 4)
run("STUB.Fire('COMMODITY_PRICE_UPDATED', 10500, 42000)")
run("Clearinghouse.AuctionUI.BuyNext()")
check("shopping: the second click confirms the quoted buy", L.eval("STUB.buys[2][1]") == "confirm" and not plan[1].done)
run("STUB.Fire('COMMODITY_PURCHASE_SUCCEEDED')")
check("shopping: done only once the AH says it went through", plan[1].done and not plan[1].failed and "bought" in plan[1].d.why)
run("""Clearinghouse.Queue.ShoppingList = STUB.oldSL; Clearinghouse.Auction.Search = STUB.oldSearch
local plan = Clearinghouse.AuctionUI.Plan(); for k in pairs(plan) do plan[k] = nil end
C_AuctionHouse.StartCommoditiesPurchase = nil; C_AuctionHouse.ConfirmCommoditiesPurchase = nil; Clearinghouse.Depth.Forget()""")

# UI pass: visible scroll position, and mail says Sent only once the game confirms it
run("""STUB.sb = Clearinghouse.Window.ScrollBar(UIParent, 100, -10, 100)
STUB.sb:Set(17, 17, 83)""")
check("scroll bar: says which rows are showing", L.eval("STUB.sb.text") == "18-34 of 83")
run("STUB.sb:Set(0, 17, 10)")
check("scroll bar: hides when everything fits", L.eval("STUB.sb.text") is None)
run("""STUB.oldNextTo = Clearinghouse.Mail.NextTo; STUB.oldSendNext = Clearinghouse.Mail.SendNext
Clearinghouse.Mail.NextTo = function() return 'Luxaren', { { id = 302, count = 1 } } end
Clearinghouse.Mail.SendNext = function() return 'Luxaren', 1 end
STUB.oldOutbox = Clearinghouse.Mail.Outbox; Clearinghouse.Mail.Outbox = function() return { Luxaren = { { id = 302, count = 1 } } } end
Clearinghouse.MailUI.Build(); Clearinghouse.MailUI.Refresh()""")
check("mail: the button names who the next mail goes to", plain(L.eval("Clearinghouse.MailUI.Build().sendButton.label")) == "Send: Luxaren")
run("Clearinghouse.MailUI.Build().sendButton.scripts.OnClick()")
check("mail: sending, not sent, until the game says so", L.eval("Clearinghouse.MailUI.sending ~= nil") is True)
run("STUB.Fire('MAIL_SEND_SUCCESS')")
check("mail: sent once the game confirms it", L.eval("Clearinghouse.MailUI.sending") is None and "Sent 1 to Luxaren" in plain(L.eval("Clearinghouse.MailUI.Build().status:GetText()")))
run("Clearinghouse.Mail.NextTo = STUB.oldNextTo; Clearinghouse.Mail.SendNext = STUB.oldSendNext; Clearinghouse.Mail.Outbox = STUB.oldOutbox")

# Second and third review fixes -------------------------------------------------------------------
# the exact cheapest mix: greedy cost-per-skill takes 19, the cheapest that clears the threshold is 13
run("""STUB.prices['i:961'] = { mat = 1 }; STUB.prices['i:962'] = { mat = 10 }
STUB.prices['i:963'] = { mat = 1 }; STUB.prices['i:964'] = { mat = 3 }; Clearinghouse.Prices.ClearCache()
STUB.cm = { qual = { { qty = 1, items = { 961, 962 } }, { qty = 3, items = { 963, 964 } } }, fixed = {},
  perUnit = { { [1] = 0, [2] = 10 }, { [1] = 0, [2] = 3 } }, maxQ = 2, thresholds = { [2] = 10 } }""")
cheap = L.eval("Clearinghouse.Advisor.Cheapest(STUB.cm, 0)")
q2 = cheap[2]
cost2 = (q2[1][1] or 0) * 1 + (q2[1][2] or 0) * 10 + (q2[2][1] or 0) * 1 + (q2[2][2] or 0) * 3
check("advisor: the exact cheapest mix for a quality, not the greedy one", cost2 == 13 and (q2[1][2] or 0) == 1)

# one evaluation with no finishing reagents asks the game once per mix, not twice
run("STUB.m10 = Clearinghouse.Advisor.Measure(10)")
run("""STUB.opCalls = 0; STUB.oldOp = C_TradeSkillUI.GetCraftingOperationInfo
C_TradeSkillUI.GetCraftingOperationInfo = function(...) STUB.opCalls = STUB.opCalls + 1; return STUB.oldOp(...) end""")
run("Clearinghouse.Advisor.Evaluate(STUB.m10)")
calls = L.eval("STUB.opCalls")
run("C_TradeSkillUI.GetCraftingOperationInfo = STUB.oldOp")
check("advisor: no finishing reagents means one build, not two", calls > 0 and calls <= 11)

# opening an order for another recipe keeps the order in the advisor
run("Clearinghouse.AdvisorUI.Show(11, true)")
run("Clearinghouse.AdvisorUI.ShowOrder({ orderID = 88, spellID = 10, minQuality = 1, tipAmount = 50000000, consortiumCut = 0, reagents = {} })")
check("advisor: opening an order for a different recipe keeps its order", L.eval("Clearinghouse.AdvisorUI.Current() and Clearinghouse.AdvisorUI.Current().order ~= nil") is True)

# knowledge paths: a day's Concentration can't sell more than demand
run("""STUB.oldDU = Clearinghouse.Scan.DailyUnits; Clearinghouse.Scan.DailyUnits = function() return 1 end
STUB.oldEval = Clearinghouse.Advisor.Evaluate
Clearinghouse.Advisor.Evaluate = function() return { made = 1, best = { profit = 1000, item = 1 },
  bestConc = { profit = 1100, perPoint = 1100 / 30, avgConcentration = 30, concentration = 30, item = 1 } } end
STUB.oldDelta = Clearinghouse.Spec.Delta; Clearinghouse.Spec.Delta = function() return {} end""")
pv = L.eval("Clearinghouse.Paths.Value({ recipes = { 1 }, models = { [1] = {} }, prof = 2906, tree = {} }, {})")
run("Clearinghouse.Scan.DailyUnits = STUB.oldDU; Clearinghouse.Advisor.Evaluate = STUB.oldEval; Clearinghouse.Spec.Delta = STUB.oldDelta")
check("paths: Concentration only replaces crafts the demand can sell", abs(pv[0] - 1100) < 1e-6)

# the craft log prices the reagents the craft really used
run("Clearinghouse.AdvisorUI.Show(10, true)")
r10 = L.eval("Clearinghouse.AdvisorUI.Current()")
check("craft log: a matching row is found for the test recipe", r10 is not None)
other = L.eval("(function() for _, r in ipairs(Clearinghouse.AdvisorUI.Current().rows) do if not r.concentration and r ~= Clearinghouse.AdvisorUI.Current().best then return r end end end)()")
if other is not None:
    run("""STUB.logOther = (function() for _, r in ipairs(Clearinghouse.AdvisorUI.Current().rows) do if not r.concentration and r ~= Clearinghouse.AdvisorUI.Current().best then return r end end end)()
local infos = {}
for i, slot in ipairs(Clearinghouse.AdvisorUI.Current().qual) do
  for q, id in ipairs(slot.items) do local n = STUB.logOther.picks[i][q] or 0; if n > 0 then table.insert(infos, { itemID = id, quantity = n }) end end
end
Clearinghouse.Log.Started(10, 1, false, infos, nil)""")
    check("craft log: the row matching the craft's reagents is the one expected", L.eval("Clearinghouse.Log.Pending().cost") == other.cost)

# posting: a confirmed post counts toward the cap before the owned list comes back
run("Clearinghouse.db.auctions = {}; Clearinghouse.Auction.Posted(971, 5)")
check("auctions: fresh posts count before the owned list updates", L.eval("Clearinghouse.Auction.Listed(971)") == 5)
run("Clearinghouse.db.auctions = {}")

# gear with no copy in the bags is searched as an item, not a commodity
check("auction search: gear at an item level isn't a commodity", L.eval("Clearinghouse.Auction.IsCommodity(999999, 645)") is False)

# cancels wait for the AH
run("""STUB.cancelled = nil; C_AuctionHouse.CancelAuction = function(id) STUB.cancelled = id end""")
run("""local plan = Clearinghouse.AuctionUI.Plan(); for k in pairs(plan) do plan[k] = nil end
table.insert(plan, { id = 302, auctionID = 4242, d = { action = 'cancel', why = 'undercut' } })""")
run("Clearinghouse.AuctionUI.CancelNext()")
pend = L.eval("Clearinghouse.AuctionUI.Plan()[1].done")
run("STUB.Fire('AUCTION_CANCELED', 4242)")
check("cancel: a row is done only once the AH says it's cancelled", L.eval("STUB.cancelled") == 4242 and not pend and L.eval("Clearinghouse.AuctionUI.Plan()[1].done") is True)
run("""table.insert(Clearinghouse.AuctionUI.Plan(), { id = 302, auctionID = 4243, d = { action = 'cancel', why = 'undercut' } })
Clearinghouse.AuctionUI.CancelNext(); STUB.RunTimers()""")
check("cancel: no answer from the AH marks it failed, not done", L.eval("Clearinghouse.AuctionUI.Plan()[2].failed") is True)
run("local plan = Clearinghouse.AuctionUI.Plan(); for k in pairs(plan) do plan[k] = nil end; C_AuctionHouse.CancelAuction = nil")

# a fulfilled order leaves the cache, and an old sighting isn't live
run("""Clearinghouse.Orders.cache = {}; Clearinghouse.Orders.seen = {}
STUB.oldCO = C_CraftingOrders; C_CraftingOrders = C_CraftingOrders or {}
STUB.oldList = C_CraftingOrders.GetCrafterOrders
C_CraftingOrders.GetCrafterOrders = function() return { { orderID = 501, spellID = 10 } } end
Clearinghouse.Orders.All()
C_CraftingOrders.GetCrafterOrders = function() return {} end""")
live1 = L.eval("Clearinghouse.Orders.Live(501) ~= nil")
run("STUB.Fire('CRAFTINGORDERS_FULFILL_ORDER_RESPONSE', 0, 501)")
check("orders: a fulfilled order leaves the list", live1 is True and L.eval("Clearinghouse.Orders.Live(501)") is None)
run("""C_CraftingOrders.GetCrafterOrders = function() return { { orderID = 502 } } end; Clearinghouse.Orders.All()
C_CraftingOrders.GetCrafterOrders = function() return {} end
Clearinghouse.Orders.seen['502'] = time() - 3600""")
check("orders: an order the game hasn't listed for an hour isn't live", L.eval("Clearinghouse.Orders.Live(502)") is None)
run("C_CraftingOrders.GetCrafterOrders = STUB.oldList; C_CraftingOrders = STUB.oldCO; Clearinghouse.Orders.cache = {}; Clearinghouse.Orders.seen = {}")

# opening a page refreshes it once
run("""STUB.refreshes = 0; STUB.oldRefresh = Clearinghouse.UI.Refresh
Clearinghouse.UI.Refresh = function(...) STUB.refreshes = STUB.refreshes + 1; return STUB.oldRefresh(...) end""")
run("Clearinghouse.UI.Page('today')")
n1 = L.eval("STUB.refreshes")
run("Clearinghouse.UI.Refresh = STUB.oldRefresh")
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
Clearinghouse.Ledger.SellThrough = function(id) local t = STUB.sellThrough[id]; if t then return t[1], t[2] end return 0, 0 end
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
run("Clearinghouse.Settings.Model('carry', -2)")
lines = [plain(l[1]) for l in CH.AdvisorUI.ExpectLines(d).values()]
check("expect: the advisor hover shows each step", any("Deposits lost" in x for x in lines) and any("Gold tied up" in x for x in lines) and lines[-1] == "Expected each")
check("failed auctions: deposits lost", CH.Expect.LostDeposit(905, 3) == 360000)
run("STUB.sellThrough = nil")

for a in sorted(set(audit_all)):
    print("LAYOUT " + a)
check("layout: nothing spills out of its panel or gets cut off", len(set(audit_all)) == 0)

print(f"\n{len(fails)} failed" if fails else "\nall passed")
sys.exit(1 if fails else 0)
