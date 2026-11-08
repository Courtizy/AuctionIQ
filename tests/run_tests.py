"""Loads the addon in a stubbed WoW environment (lupa) and checks its behaviour.
Run: python3 tests/run_tests.py   (needs `pip install lupa`)"""
import re
import sys
from pathlib import Path

from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
files = [l.strip().replace("\\", "/") for l in (ROOT / "Clearinghouse.toc").read_text().splitlines() if l.strip().endswith(".lua")]
L = LuaRuntime(unpack_returned_tuples=True)
L.execute((ROOT / "tests" / "wow_stub.lua").read_text())
ns = L.table()
for f in files:
    chunk = L.eval("function(src, name) return assert(loadstring and loadstring(src, name) or load(src, name)) end")((ROOT / f).read_text(), f)
    chunk("Clearinghouse", ns)

fails = []
def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)

run = L.execute
run('STUB.Fire("ADDON_LOADED", "Clearinghouse"); STUB.Fire("PLAYER_LOGIN")')
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
      lines == ["Clearinghouse value=", "    Buy now (lowest listing)=450g", "    Post price=450g", "  Sale price=500g",
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
check("ElvUI: value colour becomes the accent", T.hex.accent == "336699")
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

print(f"\n{len(fails)} failed" if fails else "\nall passed")
sys.exit(1 if fails else 0)
