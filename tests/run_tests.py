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
rows, foot = CH.LedgerUI.Rows("pl", L.eval("{ }"))
check("CFO views draw rows", len(list(rows.values())) == 1 and "best line: Flasks" in plain(foot))
for v in ["dead", "holdings", "overhead"]:
    CH.LedgerUI.Rows(v, L.eval("{ days = 30 }"))
run("Clearinghouse.Par.Refresh()")
check("par: a week of what you sold, by default", CH.Par.Target(302)[0] == 1 and CH.Par.Target(301)[0] == 1 and CH.Par.Target(201) is None)
run("Clearinghouse.Par.Set(302, 6); Clearinghouse.Par.Refresh()")
par = {e.id: e for e in CH.Par.List().values()}
check("par: set by hand, short counts stock on every character", par[302].manual and par[302].held == 4 and par[302].short == 2)
check("par view: shift-click +1, alt-click back to automatic", CH.LedgerUI.ParClick(302, "shift")[0] == 7 and CH.LedgerUI.ParClick(302, "alt")[0] == 1)
run("Clearinghouse.Par.Set(302, 6); Clearinghouse.Par.Refresh()")
check("briefing lists what's below par", "Below par" in plain(CH.UI.BriefingText()))
rows, foot = CH.LedgerUI.Rows("par", L.eval("{ }"))
check("par view rows", len(list(rows.values())) == 2 and plain(foot).startswith("1 items below par"))
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
d = CH.Auction.Decide(302, L.eval("{ { price = 2900000, qty = 3, mine = false }, { price = 2950000, qty = 1, mine = true } }"), 10)
check("auction: undercut the cheapest seller outside the account", d.action == "post" and d.price == 2899999 and d.qty == 5)
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
run("Clearinghouse.GroupsUI.Select('Crafted'); Clearinghouse.UI.Page('groups')")
grows = list(CH.GroupsUI.Refresh().values())
check("groups page: the group's items with their prices", any(r.id == 302 for r in grows) and CH.UI.IsShown())
check("auction panel builds", CH.AuctionUI.Build() is not None)
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
# Clearinghouse companion data in the tooltip
run("""ClearinghouseMarket = { Get = function(id) if id == 302 then return { market = 123400, avg7 = 110000, change7 = 0.12, qty = 40, days = 9, source = 'realm' } end end }""")
tl = [l[1] for l in CH.TooltipLines("item:302").values()]
check("tooltip: Clearinghouse market history shows", "Clearinghouse market" in tl and any("7-day average  +12% in 7 days" in x for x in tl))
run("ClearinghouseMarket = nil")
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
check("ledger failed auctions", len(list(rows.values())) == 1 and plain(foot).startswith("1 items expired"))
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
check("markets opens on market prices", LUI.Section() == "markets" and LUI.View() == "market")
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
run("ClearinghouseMarket = { Get = function(id) if id == 301 then return { market = 20000, min = 19000, avg7 = 18000, change7 = 0.11, qty = 40 } end end, Info = function() return 0, 'Emerald Dream', 'us' end }")
mrows = L.eval("(Clearinghouse.LedgerUI.Rows('market', {}))")
r301 = [r for r in mrows.values() if r.id == 301]
check("market prices list held or sold items with app data", len(r301) == 1 and "+11%" in plain(r301[0].cells[5]))
run("ClearinghouseMarket = nil")
tfoot = L.eval("select(2, Clearinghouse.LedgerUI.Rows('time', { days = 30 }))")
check("gold per hour moved to analytics", "hours" in plain(tfoot))
run("Clearinghouse.UI.Page('ledger')")
check("the Clearinghouse remembers its last view", LUI.Section() == "ledger" and LUI.View() == "report")
run("Clearinghouse.UI.Page('groups')"); run("Clearinghouse.UI.Page('plan')"); run("Clearinghouse.UI.Page('dashboard')")
check("old page names open the new tabs", CH.UI.IsShown())
nxt = list(CH.Next.List().values())
check("do next is ranked, leaking value first", len(nxt) > 0 and all(nxt[i].tier <= nxt[i + 1].tier for i in range(len(nxt) - 1)))
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
run("C_TradeSkillUI.GetRecipeInfo = STUB.oldInfo; STUB.recipeIDs = nil; Clearinghouse.Queue.Clear()")
run("C_CraftingOrders = { GetCrafterOrders = function() return { { orderID = 77, spellID = 10, minQuality = 1, tipAmount = 50000000, consortiumCut = 0, customerName = 'Patron', reagents = {} } } end, ClaimOrder = function(id) STUB.claimed = id end, FulfillOrder = function(id) STUB.fulfilled = id end }")
n2 = L.eval("(Clearinghouse.Queue.FillOrders())")
oq = list(CH.db.queue.values())
check("orders: a paying order is queued with its order ID", n2 == 1 and oq[0].orderID == 77)
check("orders: the button goes Claim first", CH.Queue.OrderStep(oq[0]) == "Claim")
run("Clearinghouse.Queue.Craft(Clearinghouse.db.queue[1])")
check("orders: Claim claims it, then Craft", L.eval("STUB.claimed") == 77 and CH.Queue.OrderStep(oq[0]) == "Craft")
run("Clearinghouse.Queue.Craft(Clearinghouse.db.queue[1])")
check("orders: crafting passes the order ID", L.eval("STUB.crafted.id") == 10)
run('STUB.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 10)')
check("orders: after the craft it's Deliver", CH.Queue.OrderStep(oq[0]) == "Deliver")
run("Clearinghouse.Queue.Craft(Clearinghouse.db.queue[1])")
check("orders: Deliver fulfils it and it leaves the queue", L.eval("STUB.fulfilled") == 77 and CH.Queue.Count() == 0)
run("C_CraftingOrders = nil")

# warbound and soulbound items can't go on the AH: no value, and the tooltip says so
run("C_Item.GetItemInfo = function(id) if id == 302 then return 'Warbound Cloak', nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, 7 end end")
inv2 = {e.id: e for e in LG.Inventory().values()}
check("warbound items count as held but worth nothing", 302 in inv2 and inv2[302].bound and inv2[302].value == 0)
check("the tooltip says it can't go on the AH", "can't go on the AH" in plain(CH.TooltipLines("i:302")[1][2]))
check("other items keep their value", CH.Unsellable(100) is False or CH.Unsellable(100) is None or not CH.Unsellable(100))
run("C_Item.GetItemInfo = nil")

# layout: nothing outside its panel, no one-line text cut off, button labels fit
L.execute((ROOT / "tests" / "layout_audit.lua").read_text())
audit_all = []
def audit(where):
    roots = L.eval("(function() local r = {} for _, f in ipairs(STUB.frames) do if (f.parent == nil or f.parent == UIParent) and f.w > 0 then table.insert(r, f) end end return r end)()")
    for p in L.eval("STUB.Audit")(roots).values():
        audit_all.append(where + ": " + p)
for tab in ["today", "markets", "crafting", "trading", "analytics", "ledger", "report"]:
    run(f"Clearinghouse.UI.Page('{tab}')")
    audit(tab)
for v in ["inventory", "sales", "income", "resale", "purchases", "expense", "expired", "cancelled", "pl", "holdings", "overhead", "market", "rivals", "when", "par", "dead", "time"]:
    run(f"Clearinghouse.UI.Page('ledger', '{v}')")
    audit("view " + v)
run("Clearinghouse.UI.Page('today')")
for w in ["ScanUI", "PathsUI", "QueueUI", "LogUI"]:
    run(f"if Clearinghouse.{w} and Clearinghouse.{w}.Toggle then pcall(Clearinghouse.{w}.Toggle) end")
    audit(w)
for a in sorted(set(audit_all)):
    print("LAYOUT " + a)
check("layout: nothing spills out of its panel or gets cut off", len(set(audit_all)) == 0)

print(f"\n{len(fails)} failed" if fails else "\nall passed")
sys.exit(1 if fails else 0)
