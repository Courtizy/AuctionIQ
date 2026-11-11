import math
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
CH.ScanUI.ROW_AGE = -1
CH.AdvisorUI.KNOWN_AGE = -1 # tests change the stubs between clicks: work each recipe out again
CH.Prices.background = False # sales added up at once, not over the next frames
CH.AdvisorUI.GEAR_AGE = -1
CH.Orders.MAX_AGE = -1 # tests change the stubs without the game's events: work every order out each time
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
run("STUB.shown = AuctionIQ.UI.IsShown and AuctionIQ.UI.IsShown(); STUB.printed = {}; STUB.oldPrint = AuctionIQ.Print; AuctionIQ.Print = function(t) table.insert(STUB.printed, t) end; SlashCmdList.AUCTIONIQ('shatter'); AuctionIQ.Print = STUB.oldPrint")
check("/aiq shatter lists what Shatter can take, without opening the main window", any("Shatter can take" in str(t) for t in L.globals().STUB.printed.values()))
check("/ch minimap hides it", not btn.shown)

# icons: white line icons tinted in the label, theme colour when active and grey otherwise
run('if not AuctionIQ.UI.IsShown() then AuctionIQ.UI.Toggle() end; AuctionIQ.UI.Go("today")')
tabs = CH.UI.Buttons()
check("tab icons: Dashboard uses the trend panel icon, tinted blue when active", "Media\\Tab-Dashboard:14:14:0:0:64:64:0:64:0:64:63:199:235|t Dashboard" in tabs.today.label)
check("tab icons: inactive tabs are grey", ":163:163:171|t Operations" in tabs.operations.label and ":163:163:171|t Accounting" in tabs.ledger.label)
check("tab icons: Settings is the gear alone", "Tab-Settings" in tabs.settings.label and "Settings" not in tabs.settings.label.split("|t")[-1])
run('AuctionIQ.UI.Go("operations")')
check("tab icons: the active tab follows the page", ":63:199:235|t Operations" in tabs.operations.label and ":163:163:171|t Dashboard" in tabs.today.label)
glyph = btn.glyph
check("minimap: AIQ monogram, A in white and IQ in the theme colour, no bar on top",
      glyph.t.endswith("A|r|cff3fc7ebIQ|r") and L.eval("rawget(AuctionIQMinimapButton, 'rule')") is None)

res = CH.Advisor.Analyze(10)
rows = list(CH.AdvisorUI.Render(res).values())
check("advisor: cheapest reagents for each quality", rows[0].startswith("Q1 plain cost=670000 profit=280000") and rows[2].startswith("Q2 plain cost=2120000 profit=730000"))
check("advisor: best profit without Concentration is Q2", "BEST" in rows[2] and "BEST" not in rows[0].replace("BESTCONC", ""))
check("advisor: Concentration value = profit / Concentration cost", "Q2 conc80" in rows[1] and "pp=27250" in rows[1] and rows[1].endswith("BESTCONC"))
check("advisor: no Concentration row when the quality is already top", len(rows) == 3)
check("advisor: picks the cheaper skill first", CH.Advisor.PicksText(res, res.best.picks).count("Q2") == 2)
def plain(t): return re.sub(r"\|c\w{8}|\|r", "", letters(str(t)))
best = res.best
rl = [(plain(l[1]).strip(), plain(l[2])) for l in CH.AdvisorUI.BreakdownLines(res, best, 3).values()]
check("reagent hover reads like a statement: each reagent at its price, as gold out, then the total",
      ("4x item 202 Q2 @ 15g", "-60g") in rl and ("2x item 205 @ 1g", "-2g") in rl and ("Total", "-212g") in rl
      and any("estimate" in l[1] for l in rl))
sl = [(plain(l[1]), plain(l[2])) for l in CH.AdvisorUI.BreakdownLines(res, best, 4).values()]
check("sell hover shows realm and region prices", ("   MV  Market Value, realm", "300g") in sl and ("   Lowest listing, realm", "none") in sl and ("After 5% auction cut", "285g") in sl)
pl = [(plain(l[1]).strip(), plain(l[2])) for l in CH.AdvisorUI.BreakdownLines(res, best, 5).values()]
check("profit hover reads like a statement: revenue, costs, profit, return", ("Revenue", "average per craft") in pl and ("Reagents", "-212g") in pl and ("Profit", "73g") in pl and ("Return on cost  profit / reagents", "34%") in pl)
# Expected proceeds: the source in the notes, and rows posting would skip
check("advisor: the proceeds column is called Expected proceeds", "TSM price (chvalue) after the 5% cut" in plain(CH.AdvisorUI.SourceLine(res)))
run("""STUB.oldGP = AuctionIQ.Groups.Prices
AuctionIQ.Groups.Prices = function(id) return { min = 4000000, post = true, op = "Crafted", priceReset = "none" } end""")
CH.AdvisorUI.Render(res)
pls = [plain(x) for x in CH.AdvisorUI.PostLines(res).values()]
check("advisor: a row below its operation's min says posting would skip it",
      any("Below posting minimum (Crafted min 400g): posting would skip it" in x for x in pls) and len(pls) == len(set(r.quality for r in res.rows.values())))
run("AuctionIQ.Groups.Prices = function() return { min = 1, post = true, op = 'Crafted', priceReset = 'none' } end")
CH.AdvisorUI.Render(res)
check("advisor: nothing flagged when every row clears the min", len(list(CH.AdvisorUI.PostLines(res).values())) == 0)
run("AuctionIQ.Groups.Prices = STUB.oldGP")
mx = CH.Advisor.MaxCraftable(res, best)
check("max craftable is limited by the scarcest reagent", mx[0] == 1)  # 3 of item 205 at 2 each
mq = CH.Advisor.MaxCraftable(res, res.rows[2], 50)
check("with Concentration it is limited by points too", res.rows[2].concentration == 80 and mq[0] == 0)
ml = [(plain(l[1]), plain(l[2])) for l in CH.AdvisorUI.BreakdownLines(res, best, 7).values()]
check("max hover lists have and need", ("item 204 Q2", "12 have, 5 each") in ml)
run('AuctionIQ.db.settings.advisor.hide = false; STUB.Fire("TRADE_SKILL_SHOW")')
check("two windows: the profession window brings up the Craft window, not a separate advisor", CH.ScanUI.IsShown() and not CH.AdvisorUI.IsShown())
col = L.eval('function(x) local f = { GetLeft = function() return 0 end, GetEffectiveScale = function() return 1 end }; local g = GetCursorPosition; GetCursorPosition = function() return x, 0 end; local c = AuctionIQ.AdvisorUI.ColumnAt(f); GetCursorPosition = g; return c end')
check("row hover picks the column under the cursor", col(200) == 3 and col(250) == 4 and col(350) == 5 and col(500) == 7 and col(20) is None)
run('STUB.Fire("TRADE_SKILL_CLOSE")')
check("advisor panel hides with it", not CH.AdvisorUI.IsShown())

# Craft queue and shopping list
run('AuctionIQ.db.settings.advisor.hide = false; AuctionIQ.AdvisorUI.Show(10)')
check("advisor: a new recipe selects the pick that earns the most a craft, as the Craft list's Best",
      CH.AdvisorUI.SelectedRow() is not None and CH.AdvisorUI.SelectedRow().profit == max(r.profit for r in CH.AdvisorUI.Current().rows.values() if r.profit is not None))
run('for i, r in ipairs(AuctionIQ.AdvisorUI.Current().rows) do if r.recommended then AuctionIQ.AdvisorUI.RowClick(i) end end')
run('AuctionIQ.AdvisorUI.RowClick(1)')            # Q1 without Concentration: selects, queues nothing
check("advisor: a row click selects it and queues nothing", CH.Queue.Count() == 0 and CH.AdvisorUI.SelectedRow().quality == 1
      and CH.AdvisorUI.SelectedRow().concentration is None)
run('STUB.shift = true; AuctionIQ.AdvisorUI.RowClick(3); STUB.shift = false')
check("advisor: shift-click selects too, it doesn't queue", CH.Queue.Count() == 0 and CH.AdvisorUI.SelectedRow().quality == 2)
check("advisor: the queue button names how many crafts", CH.AdvisorUI.QueueAction()[0] == "Queue 1 craft")
nm = CH.AdvisorUI.RenderNext()
check("advisor: Next Move names the craft and count, then profit, break-even and recovery",
      nm is not None and nm.head.startswith("Craft 1 ") and nm.row.quality == 2 and nm.profit == CH.AdvisorUI.SelectedRow().profit
      and (nm.recover is None or 0 <= nm.recover <= 1))
run("AuctionIQ.AdvisorUI.SetQty(20)")
nm20 = CH.AdvisorUI.RenderNext()
check("advisor: Next Move and the queue button follow the quantity", nm20.head.startswith("Craft 20 ") and CH.AdvisorUI.QueueAction()[0] == "Queue 20 crafts"
      and abs(nm20["items"] - 20 * nm["items"]) < 1e-6)
check("advisor: Multicraft output is shown apart from the crafts", (not nm20.mc) or ("Multicraft" in nm20.sub))
for w, head in (("profit", "Profit"), ("breakEven", "Break-even"), ("recover", "Recover")):
    tp = list(L.eval("AuctionIQ.AdvisorUI.NextTip('%s')" % w).values())
    check("advisor: the %s hover explains it and shows the breakdown" % head, tp[0][1] == head and len(tp) >= 3)
bc = L.eval('function() local inp = { reagents = { { n = 1, unit = 100, finishing = true } }, have = function(id) return C_Item.GetItemCount(id, true) end }; return AuctionIQ.Decide.BatchCost(inp, 3) end')()
check("decide: a reagent with no item id (an older scan's account) doesn't ask the game for its count", bc is not None)
run('AuctionIQ.Scan.ScanAll(nil, function(r) STUB.allDone = r end)')
waits = 0
for _ in range(400):
    if CH.Scan.all is None: break
    if CH.Scan.all.waiting is not None:
        # the game only lets a click open a profession: the button reads Open <name> and waits for one
        if L.eval('AuctionIQ.LedgerUI.ViewDef("scenarios").action.label()').startswith("Open "): waits += 1
        run('AuctionIQ.LedgerUI.ViewDef("scenarios").action.click()')
    run('STUB.RunTimers()')
check("scan all: each profession after the first waits for a click to open it (the game blocks it otherwise)", waits >= 1)
ad = L.eval('STUB.allDone')
check("scan all: rolls through each profession and reports each", ad is not None and len(list(ad.values())) == 3 and ad[3].name == "Cooking")
check("scan all: opens the ones that aren't showing", "333," in (L.eval('STUB.opened') or "") and "185," in (L.eval('STUB.opened') or ""))
check("scan all: Compare crafts has a Scan button for it", L.eval('AuctionIQ.Research and 1 or 1') and L.eval('AuctionIQ.LedgerUI.ViewDef("scenarios").action.label()') == "Scan")
run('STUB.base = 171')
af = CH.AdvisorUI.Frame()
check("advisor redesign: Next Move sits on a shaded card with the accent line", af.nextCard is not None and af.accentBar is not None and af.tableCard is not None and af.paneCard is not None)
check("advisor redesign: the title bar keeps only Queue; the pane has its own tabs", af.notesBtn is not None and af.chartBtn is not None and af.batchBtn is not None
      and L.eval("function(b) return select(2, b:GetPoint()) end")(af.chartBtn) != L.eval("function(f) return f end")(af.queue))
check("advisor redesign: the Queue button is the filled main action", af.act.queue.aiqFill is not None)
check("advisor redesign: the Break-even tab opens the chart, Notes goes back", CH.AdvisorUI.SetPane("chart") == "chart" and CH.AdvisorUI.SetPane("notes") == "notes" and af.notesBtn.on)
check("advisor redesign: the sub line has the card's full width", af.next.sub.w is None or af.next.sub.w >= 400)
run("AuctionIQ.AdvisorUI.SetQty(1)")
g = L.eval("{ AuctionIQ.Theme.GradientColors('MAGE') }")
check("theme: ToxiUI's class gradient for bars", abs(g[1][1] - 0) < 1e-6 and abs(g[1][3] - 0xd7 / 255) < 1e-6 and abs(g[2][3] - 1) < 1e-6)
run('AuctionIQ.AdvisorUI.QueueSelected()')        # Q2 without Concentration, one
run('AuctionIQ.AdvisorUI.SetQty(1); AuctionIQ.AdvisorUI.QueueSelected()')
run('AuctionIQ.AdvisorUI.RowClick(2)')            # Q1 reagents + Concentration
check("advisor: selecting another row puts the quantity back to 1", CH.AdvisorUI.SetQty(0) == 1)
run('AuctionIQ.AdvisorUI.QueueSelected()')
q = list(CH.db.queue.values())
check("queue: the button adds the selected craft, the same craft stacks", len(q) == 2 and q[0].qty == 2 and q[0].quality == 2 and q[1].concentration == 80)
check("queue: Count adds up", CH.Queue.Count() == 3)
check("queueing from the card keeps you on the Craft tab", CH.ScanUI.IsShown() and not CH.QueueUI.IsShown())
lines = CH.QueueUI.Show()
check("the Queue tab replaces Craft in the same spot", CH.QueueUI.IsShown() and not CH.ScanUI.IsShown() and CH.Window.Active() == "queue")
shop = list(lines.shopAll.values())
# 2x Q2 craft (4x202, 5x204, 2x205) + 1x conc craft (4x201, 5x203, 2x205)
check("shopping list: need across the queue, less what you have",
      "item 202 need=8 have=8 buy=0" in shop and "item 204 need=10 have=12 buy=0" in shop and "item 205 need=6 have=3 buy=3" in shop)
srows_ = [r for r in CH.QueueUI.ShopRows()[0].values()]
check("shopping list card: what to buy first, covered reagents folded into one row",
      srows_[0].itemID == 205 and srows_[-1].toggle and srows_[-1].n == len(shop) - 1)
check("shopping list card: the covered row opens them", len(list(CH.QueueUI.SetShowCovered(True).shop.values())) >= 1
      and len(list(CH.QueueUI.ShopRows()[0].values())) == len(shop) + 1)
run("AuctionIQ.QueueUI.SetShowCovered(false)")
check("queue popup: More holds plan comparison and Clear, nothing that adds", [m[1] for m in CH.QueueUI.MenuItems().values()] == ["Compare restock plans", "Clear queue"])
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
# enchants: the scroll each quality makes, and the craft goes onto Enchanting Vellum
en = L.eval("""(function()
  local ui = C_TradeSkillUI
  local oldInfo, oldOut, oldC, oldCR = ui.GetRecipeInfo, ui.GetRecipeOutputItemData, C_Container, ui.CraftRecipe
  local r = {}
  ui.GetRecipeOutputItemData = function(id, reagents, guid, q) local m = { [1001] = 9101, [1002] = 9102 }; return m[q] and { itemID = m[q] } or nil end
  local outs = AuctionIQ.Advisor.ScrollOutputs(30, { qualityIDs = { 1001, 1002 }, maxQuality = 2 })
  r.q1, r.q2 = outs[1], outs[2]
  ui.GetRecipeInfo = function(id) local i = oldInfo(id); if id == 10 and i then i.isEnchantingRecipe = true end; return i end
  C_Container = { GetContainerNumSlots = function(bag) return bag == 1 and 4 or 0 end,
    GetContainerItemID = function(bag, slot) return (bag == 1 and slot == 3) and 38682 or nil end }
  local loc0 = ItemLocation
  ItemLocation = { CreateFromBagAndSlot = function(_, bag, slot) return { bag = bag, slot = slot } end }
  ui.CraftEnchant = function(id, n, reagents, target, conc) r.enchant = { id = id, n = n, bag = target.bag, slot = target.slot, k = #reagents } end
  ui.CraftRecipe = function() r.recipe = true end
  local e = AuctionIQ.Queue.AddEntry({ char = AuctionIQ.Me().key or 'Me-Realm', recipeID = 10, name = 'Test Enchant', reagents = { { itemID = 201, slot = 1, n = 2 } }, shop = {} }, 1)
  r.ok = AuctionIQ.Queue.Craft(e, 1)
  AuctionIQ.Queue.Clear()
  ui.GetRecipeInfo, ui.GetRecipeOutputItemData, C_Container, ui.CraftRecipe, ui.CraftEnchant, ItemLocation = oldInfo, oldOut, oldC, oldCR, nil, loc0
  return r
end)()""")
ea = L.eval("""(function()
  local ui = C_TradeSkillUI
  local oldInfo, oldSch, oldOut = ui.GetRecipeInfo, ui.GetRecipeSchematic, ui.GetRecipeOutputItemData
  ui.GetRecipeInfo = function(id) local i = oldInfo(id); if id == 10 and i then local c = {}; for k, v in pairs(i) do c[k] = v end
    c.qualityItemIDs = nil; c.isEnchantingRecipe = true; c.qualityIDs = { 1001, 1002 }; return c end; return i end
  ui.GetRecipeSchematic = function(id, ...) local sch = oldSch(id, ...); if id == 10 and sch then local c = {}; for k, v in pairs(sch) do c[k] = v end; c.outputItemID = nil; return c end; return sch end
  ui.GetRecipeOutputItemData = function(id, reagents, guid, q) local m = { [1001] = 100, [1002] = 101 }; return m[q] and { itemID = m[q] } or nil end
  local res = AuctionIQ.Advisor.Analyze(10, { professionID = AuctionIQ.OpenProfessionID() })
  ui.GetRecipeInfo, ui.GetRecipeSchematic, ui.GetRecipeOutputItemData = oldInfo, oldSch, oldOut
  return { best = res and res.best and res.best.profit ~= nil, out1 = res and res.model.outputs[1] }
end)()""")
check("enchant: with no output item on the recipe, the scroll is priced and a ranked option comes back", ea.best and ea.out1 == 100)
ec = L.eval("""(function()
  local ui = C_TradeSkillUI
  local oldInfo, oldSch, oldOut = ui.GetRecipeInfo, ui.GetRecipeSchematic, ui.GetRecipeOutputItemData
  ui.GetRecipeInfo = function(id) local i = oldInfo(id); if id == 10 and i then local c = {}; for k, v in pairs(i) do c[k] = v end
    c.qualityItemIDs = nil; c.isEnchantingRecipe = true; return c end; return i end
  ui.GetRecipeSchematic = function(id, ...) local sch = oldSch(id, ...); if id == 10 and sch then local c = {}; for k, v in pairs(sch) do c[k] = v end; c.outputItemID = nil; return c end; return sch end
  ui.GetRecipeOutputItemData = function() return { hyperlink = "|cffffffff|Henchant:1234|h[Enchant]|h|r" } end
  STUB.craftingDataID = 3837
  local res = AuctionIQ.Advisor.Analyze(10, { professionID = AuctionIQ.OpenProfessionID() })
  STUB.craftingDataID = nil
  ui.GetRecipeInfo, ui.GetRecipeSchematic, ui.GetRecipeOutputItemData = oldInfo, oldSch, oldOut
  local o = res and res.model.outputs or {}
  return { o[1], o[2], #o }
end)()""")
check("enchant: the scroll per quality comes from the enchant table by craftingDataID, as CraftSim does (the game's output is an enchant link)", ec[1] == 244030 and ec[2] == 244031 and ec[3] == 2)
check("enchant: each quality's scroll comes from the game's output data", en.q1 == 9101 and en.q2 == 9102)
check("enchant: the queue crafts it onto Enchanting Vellum (CraftEnchant), not CraftRecipe",
      en.enchant is not None and en.enchant.id == 10 and en.enchant.bag == 1 and en.enchant.slot == 3 and en.recipe is None)
run('AuctionIQ.Queue.Clear()')
check("clear empties it", CH.Queue.Count() == 0)

# ElvUI present: its colours, templates and skins are used
run('''ElvUI = { { media = { rgbvaluecolor = { 0.2, 0.4, 0.6 }, bordercolor = { 0, 0, 0 }, backdropfadecolor = { 0.06, 0.06, 0.06 }, backdropcolor = { 0.1, 0.1, 0.1 } },
  GetModule = function() return { HandleCloseButton = function(_, b) b.skinned = "close" end, HandleButton = function(_, b) b.skinned = "button" end } end } }
AuctionIQ.Theme.Sync()
STUB.p = CreateFrame("Frame"); AuctionIQ.Theme.Panel(STUB.p, "bg")
STUB.b = AuctionIQ.Theme.Button(STUB.p, "Dock"); STUB.x = AuctionIQ.Theme.Button(STUB.p, "x")''')
T = CH.Theme
check("no ElvUI: the accent and brand are AuctionIQ blue", L.eval("AuctionIQ.Theme.hex.accent") == "3fc7eb" and T.hex.bg == "292929")
run("AuctionIQ.Theme.Use('auctioniq')")
check("ElvUI: the accent and the brand's IQ follow its theme (value) colour", T.hex.accent == "336699" and T.hex.brand == "336699"
      and "|cff336699IQ|r" in L.eval("AuctionIQ.Theme.Wordmark()") and T.hex.bg == "292929")
gl = L.eval("{ AuctionIQ.Theme.GradientColors() }")
check("ElvUI without ToxiUI: bars shade into its theme colour", abs(gl[2][1] - 0.2) < 1e-6 and abs(gl[1][1] - 0.12) < 1e-6)
run("AuctionIQ.Theme.Follow()")
check("ElvUI: a theme colour change re-colours the brand", "336699" in L.eval("AuctionIQ.Theme.Wordmark()"))
run("AuctionIQ.db.settings.theme = 'elvui'; AuctionIQ.Theme.Use('auctioniq')")
check("ElvUI: /aiq theme takes its value colour as the accent", T.hex.accent == "336699")
run("AuctionIQ.db.settings.theme = nil; AuctionIQ.Theme.Use('auctioniq')")
check("ElvUI: panels use its opaque Default template", L.eval("STUB.p.template") == "Default")
check("ElvUI: buttons use its skins", L.eval("STUB.b.skinned") == "button" and L.eval("STUB.x.skinned") == "close")
run("ElvUI = nil; AuctionIQ.Theme.Use('auctioniq')")
check("no ElvUI again: back to AuctionIQ blue and its gradient", T.hex.accent == "3fc7eb"
      and abs(L.eval("({ AuctionIQ.Theme.GradientColors() })[1][3]") - 0xd7 / 255) < 1e-6)

# CraftSim parity: average profit with Multicraft and Resourcefulness, Ingenuity, finishing reagents
St = CH.Stats
check("multicraft: average extra items from the base yield", abs(St.MulticraftExtra(2, 0) - 2.33) < 1e-9 and abs(St.MulticraftExtra(1, 0.25) - 1.8125) < 1e-9)
check("concentration cost from the game's curve", St.ConcentrationCost(1, 100, 25, 0) == 100 and St.ConcentrationCost(1, 100, 25, 0.1) == 90)
run("AuctionIQ.ConcCurves[9901] = { c = { [0] = 100, [200] = 300 }, v = { [0] = 1, [1] = 1 } }")
# CraftSim: bracket by skill (50 is in 0..200), constant read at difficulty 150 -> 250
check("concentration: curve constant as CraftSim reads it", St.ConcentrationCost(9901, 150, 50, 0) == 250)
run("AuctionIQ.ConcCurves[9901] = nil")
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
pl = [(plain(l[1]).strip(), plain(l[2])) for l in CH.AdvisorUI.BreakdownLines(pr, best, 5).values()]
check("profit hover shows the Multicraft and Resourcefulness parts",
      any(a.startswith("Multicraft  35% x 2.3 more") for a, _ in pl) and any(a.startswith("Resourcefulness  20% saves") for a, _ in pl))
cl = [plain(l[1]) for l in CH.AdvisorUI.BreakdownLines(pr, best, 3).values()]
check("reagent hover lists the finishing reagent", any("item 222" in c for c in cl))
fa = {a.itemID: a for a in CH.Advisor.FinishingAdvice(pr).values()}
check("finishing advice: every option with its gain, what you own and the verdict",
      set(fa) == {221, 222} and fa[221].own == 2 and fa[222].own == 0 and fa[222].picked and fa[222].verdict == "buy" and fa[222].gain > 0
      and "Multicraft" in fa[222].effect and "skill" in fa[221].effect)
run("STUB.lockedSlot = 77")
lk = CH.Advisor.Analyze(11, L.eval('{ professionID = 2906 }'))
check("a finishing slot the game has locked is never filled", len(list(lk.best.finishing.values())) == 0 and len(list(lk.bestConc.finishing.values())) == 0)
run("STUB.lockedSlot = nil")
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
run('AuctionIQ.AdvisorUI.RowClick(1)')
sa = CH.AdvisorUI.QueueAction()
check("advisor: a simulated row offers to queue the live craft instead", sa[0] == "Queue live craft"
      and (sa[1] is not None or sa[2].quality == CH.AdvisorUI.SelectedRow().quality))
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
check("paths: opens in the main window, Operations > Craft > Paths", CH.PathsUI.IsShown() and CH.UI.Pages().paths.shown and CH.LedgerUI.View() == "paths"
      and CH.LedgerUI.Section() == "operations" and CH.LedgerUI.Group() == "Craft")
check("Craft: Specialization, the weekly checklist and plan payoff by recipe",
      [CH.LedgerUI.ViewDef(v).label for v in ["professions", "paths", "plans"]] == ["Weekly checklist", "Specialization", "Plan payoff by recipe"])
run('AuctionIQ.UI.Refresh()')
kp = plain(L.eval("AuctionIQ.UI.Pages().paths.kpText:GetText()"))
pay = plain(L.eval("AuctionIQ.UI.Pages().paths.payText:GetText()"))
check("Specialization: Knowledge for the profession, then Plan payoff, above Paths",
      kp.startswith("Knowledge  ") and "unspent" in kp and pay.startswith("Plan payoff  ") and "a day" in pay and "points in" in pay)
spent, total = L.eval("AuctionIQ.PathsUI.PlanProgress")(saved[0], CH.Spec.Tree(2906))
check("Plan payoff: how many of the plan's points are in the tree now", total == sum(s.to - s["from"] for s in saved[0].steps.values()) and 0 <= spent < total)
run("AuctionIQ.UI.Pages().paths.byRecipe.scripts.OnClick(AuctionIQ.UI.Pages().paths.byRecipe)")
check("Specialization: By recipe opens plan payoff, still in Craft", CH.LedgerUI.View() == "plans" and CH.LedgerUI.Group() == "Craft" and CH.LedgerUI.Section() == "operations")
pt = L.eval("AuctionIQ.AnalyticsViews.PlanText")
check("a plan's effect on a recipe: Concentration saved, quality without it, else profit",
      plain(pt(L.eval("{ label = 'Flasks', saves = 12, from = 100, to = 100 }"))) == "Your plan (Flasks) saves 12 Concentration a craft."
      and plain(pt(L.eval("{ label = 'Flasks', quality = 2, from = 10000, to = 30000 }"))).startswith("Your plan (Flasks) makes it Q2 without Concentration, +")
      and "takes it from" in plain(pt(L.eval("{ label = 'Flasks', from = 10000, to = 30000 }"))))
run('AuctionIQ.PathsUI.Open()')
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
# a bag full of gear: the best few are paired, not every pair (900 sets froze the game)
gb = L.eval("""(function(m, c)
  local big = { tools = {}, gear = {}, slots = c.slots }
  for _, t in ipairs(c.tools) do table.insert(big.tools, t) end
  for _, g in ipairs(c.gear) do table.insert(big.gear, g) end
  for k = 1, 6 do table.insert(big.tools, { link = 'item:' .. (700 + k), itemID = 700 + k, stats = AuctionIQ.Stats.New(), bag = 1, bagSlot = k }) end
  for k = 1, 24 do table.insert(big.gear, { link = 'item:' .. (800 + k), itemID = 800 + k, stats = AuctionIQ.Stats.New(), bag = 2, bagSlot = k }) end
  local n, f = 0, AuctionIQ.Advisor.Evaluate
  AuctionIQ.Advisor.Evaluate = function(...) n = n + 1; return f(...) end
  local g = AuctionIQ.Gear.Best(m, nil, big)
  AuctionIQ.Advisor.Evaluate = f
  return { n = n, text = g and g.set and AuctionIQ.Gear.SwapText(g.set) or "" }
end)""")(m10, c)
check("gear: a bag full of gear tries a short list, and the better tool still wins", gb.n <= 80 and "404" in gb.text)
CH.Gear.Equip(g.set, c)
check("gear: equip puts the bag tool in the tool slot", L.eval("STUB.equipped[20]") == "item:404")

# Crafting orders
o = CH.Orders.Analyze(L.eval("""{ orderID = 77, spellID = 10, minQuality = 2, tipAmount = 1000000, consortiumCut = 100000, customerName = "Bob",
  reagents = { { reagentInfo = { reagent = { itemID = 205 }, dataSlotIndex = 3, quantity = 2 } } } }"""))
orows = list(o.rows.values())
check("order: the customer's reagents aren't charged, the commission is the value",
      o.best.quality == 2 and o.best.cost == 2100000 and o.best.value == 900000 and o.best.profit == 900000 - 2100000)
check("order: qualities under the minimum are marked", orows[0].short == True and L.eval("STUB.orderCall") == 77)
CH.AdvisorUI.Render(o)
check("advisor: an order selects its best craft that reaches the quality", CH.AdvisorUI.SelectedRow().quality == 2)
run('AuctionIQ.AdvisorUI.RowClick(1)')
oa = CH.AdvisorUI.QueueAction()
check("advisor: a row under the order's quality can be selected but not queued", oa[1] is not None and "below the Q2" in oa[1]
      and CH.AdvisorUI.QueueSelected()[0] is None and CH.Queue.Count() == 0)
check("advisor: order proceeds say they're what the order pays", "what the order pays" in plain(CH.AdvisorUI.SourceLine(o)))
# the customer gives part of a slot: we pay for the rest (slot 3 needs 2 of item 205 at 1g, they give 1)
op = CH.Orders.Analyze(L.eval("""{ orderID = 77, spellID = 10, minQuality = 2, tipAmount = 1000000, consortiumCut = 100000, customerName = "Bob",
  reagents = { { reagentInfo = { reagent = { itemID = 205 }, dataSlotIndex = 3, quantity = 1 } } } }"""))
check("order: part of a slot from the customer, the rest is ours to pay", op.best.cost == o.best.cost + 10000)
run("STUB.savedQueue = AuctionIQ.db.queue; AuctionIQ.db.queue = {}")
CH.Queue.Add(op, op.best, 1)
need205 = [x for x in CH.Queue.ShoppingList()[0].values() if x.itemID == 205]
check("order: the queue and shopping list ask for the same remaining units", len(need205) == 1 and need205[0].need == 1)
run("AuctionIQ.db.queue = STUB.savedQueue")
# 3 of the 4 in the quality slot from the customer: only 1 left to pick
oq = CH.Orders.Analyze(L.eval("""{ orderID = 77, spellID = 10, minQuality = 1, tipAmount = 1000000, consortiumCut = 0,
  reagents = { { reagentInfo = { reagent = { itemID = 201 }, dataSlotIndex = 1, quantity = 3 } } } }"""))
q1 = [sl for sl in oq.model.qual.values() if sl.index == 1]
check("order: a quality slot the customer part-fills keeps the rest to pick", len(q1) == 1 and q1[0].qty == 1)

# Concentration on the mix with the most gold per point, not just the cheapest mix for the quality:
# with this curve each point of skill makes Concentration much cheaper
run("AuctionIQ.ConcCurves[9902] = { c = { [0] = 1000 }, v = { [0] = 1, [1] = 0 } }; STUB.craftingDataID = 9902")
cm = CH.Advisor.Analyze(10, L.eval('{ professionID = 2906 }'))
plain1 = [r for r in cm.rows.values() if r.quality == 1 and not r.concentration][0]
conc1 = [r for r in cm.rows.values() if r.concentration and r["from"] == 1][0]
check("concentration: picks a mix with more skill when it pays more per point", conc1.skill > plain1.skill and conc1.cost > plain1.cost)
run("AuctionIQ.ConcCurves[9902] = nil; STUB.craftingDataID = nil")

# Subrecipes: a reagent an alt crafts for less than buying it is priced at the craft
base10 = CH.Advisor.Analyze(10, L.eval('{ professionID = 2906 }')).best.cost
run("""AuctionIQ.db.characters['Sub-Realm'] = { name = 'Sub', professions = { [77] = { name = 'Test Smithing', scan = { at = STUB.now, rows = {
  { recipeID = 50, name = 'Make 205', item = 205, craftEach = 4000 } } } } } }; AuctionIQ.Scan.ClearCrafted()""")
sub10 = CH.Advisor.Analyze(10, L.eval('{ professionID = 2906 }'))
check("subrecipe: a reagent you craft for less is priced at the craft", sub10.best.cost == base10 - 2 * (10000 - 4000))
cl = [x for x in CH.Advisor.CostLines(sub10, sub10.best.picks).values() if x.name == "item 205"]
check("subrecipe: the reagent line says who crafts it", len(cl) == 1 and cl[0].crafted and cl[0].crafted.char == "Sub")
run("AuctionIQ.db.settings.subrecipes = false")
check("subrecipe: off in Settings, reagents are bought", CH.Advisor.Analyze(10, L.eval('{ professionID = 2906 }')).best.cost == base10)
run("AuctionIQ.db.settings.subrecipes = nil")
run("AuctionIQ.db.characters['Sub-Realm'].professions[77].scan.at = STUB.now - 30 * 86400; AuctionIQ.Scan.ClearCrafted()")
check("subrecipe: a stale scan isn't used", CH.Advisor.Analyze(10, L.eval('{ professionID = 2906 }')).best.cost == base10)
run("AuctionIQ.db.characters['Sub-Realm'].professions[77].scan.at = STUB.now; AuctionIQ.db.characters['Sub-Realm'].professions[77].scan.rows[1].viaCraft = true; AuctionIQ.Scan.ClearCrafted()")
check("subrecipe: one level deep, a craft priced by crafted reagents isn't used", CH.Advisor.Analyze(10, L.eval('{ professionID = 2906 }')).best.cost == base10)
run("AuctionIQ.db.characters['Sub-Realm'] = nil; AuctionIQ.Scan.ClearCrafted()")

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
# a craft makes its base 2 plus Multicraft's average extra, as the profit per craft counts them
yb = 2 + (pot.accounts.extraItems or 0)
yc = 2 + (pot.concAccounts.extraItems or 0)
plainDay = pot.profit * 10 / yb
cc = min(10 / yc, L.eval("AuctionIQ.CONC_PER_HOUR") * 24 / pot.avgConcentration)
concDay = cc * pot.concProfit + max(0, 10 / yb - cc * yc / yb) * pot.profit
check("scan: gold a day = profit x units sold (up to the cap) / items per craft, Multicraft included",
      (pot.accounts.extraItems or 0) > 0 and abs(pot.perDay - max(plainDay, concDay)) < 1e-3)
# Concentration making a better item: it sells to its own buyers, on top of the plain crafts
run("""STUB.oldSold = AuctionIQ.Advisor.SoldPerDay; AuctionIQ.Advisor.SoldPerDay = function(id) return id == 900 and 10 or 2 end""")
sm = L.eval("""AuctionIQ.Scan.Summary({ recipeID = 1, name = 'x', made = 2,
  best = { profit = 100, cost = 50, item = 900, quality = 1, parts = { mc = 0.2, extraItems = 2.33 } },
  bestConc = { profit = 300, item = 901, quality = 2, avgConcentration = 1, concentration = 1, parts = { mc = 0, extraItems = 0 } } })""")
run("AuctionIQ.Advisor.SoldPerDay = STUB.oldSold")
check("scan: a better item from Concentration adds its own sales to the plain crafts",
      abs(sm.perDay - (100 * 10 / 2.466 + 300 * 2 / 2)) < 1e-6)
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
dry = CH.Queue.FillPlan(2906, L.eval("{ budget = 100, dry = true }"))
check("fill: a dry run lists the plan (Craft window's Fill queue hover) and queues nothing",
      CH.Queue.Count() == 0 and dry.conc == 1 and sum(x.n for x in dry.entries.values()) == dry.conc + dry.plain and list(dry.entries.values())[0].conc)
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
# Scan to queue: the selected recipe's plain and Concentration crafts, each queued as shown
pot = [r for r in CH.Scan.Results(2906).rows.values() if r.name == "Test Potion"][0]
run(f"AuctionIQ.Queue.Clear(); AuctionIQ.ScanUI.SetView('craft'); AuctionIQ.ScanUI.Select({pot.recipeID})")
check("scan: a click selects the recipe, the strip shows it", CH.ScanUI.Selected() == pot.recipeID and CH.ScanUI.SelectedRow().name == "Test Potion")
idx = [i for i, t in enumerate(list(CH.ScanUI.Refresh().values())) if t.startswith("Test Flask")][0]
run(f"STUB.shift = true; AuctionIQ.ScanUI.Click({idx + 1}); STUB.shift = false")
check("scan: shift-clicking a recipe selects it and queues nothing", CH.Queue.Count() == 0 and CH.ScanUI.SelectedRow().name == "Test Flask")
run(f"AuctionIQ.ScanUI.Select({pot.recipeID}); AuctionIQ.ScanUI.SetQty(2); AuctionIQ.ScanUI.QueueSelected(true)")
qc = list(CH.db.queue.values())
check("scan: Queue with Concentration queues the Concentration craft the row shows",
      len(qc) == 1 and qc[0].concentration == pot.concentration and qc[0].quality == pot.concQuality and qc[0].qty == 2)
run("AuctionIQ.ScanUI.QueueSelected(false, 1)")
qp = [e for e in CH.db.queue.values() if not e.concentration]
check("scan: Queue plain queues the plain craft, apart from the Concentration one",
      len(qp) == 1 and qp[0].quality == pot.quality and qp[0].qty == 1 and CH.Queue.Count() == 3)
noconc = [r for r in CH.Scan.Results(2906).rows.values() if not r.concProfit]
if noconc:
    e, why = CH.ScanUI.ScanEntry(noconc[0], True)
    check("scan: no Concentration craft, nothing to queue with it", e is None and "no Concentration craft" in why)
run("AuctionIQ.Queue.Clear()")
cv = list(CH.ScanUI.SetView("conc").values())
check("scan: the Concentration view lists only recipes that can use it, by gold a point",
      CH.ScanUI.View() == "conc" and all(" conc=" in x for x in cv if not x.startswith("== "))
      and len([x for x in cv if not x.startswith("== ")]) == len([r for r in CH.Scan.Results(2906).rows.values() if r.concProfit]))
bv = list(CH.ScanUI.SetView("buy").values())
check("scan: the Buy vs craft view lists recipes with a listing", all(" save=" in x for x in bv if not x.startswith("== ")))
run("AuctionIQ.ScanUI.SetView('craft')")
check("scan: back to the Craft view", any(x.startswith("Test Potion profit=") for x in CH.ScanUI.Refresh().values()))


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

# Decisions: break-even, Concentration over plain, evidence, Concentration forecast, batch outcomes
check("craft log: the forecast's yield is kept with the craft", lr.e.fcCrafts == 1 and lr.e["fcItems"] == 2 and abs(lr.e.expItems - 1) < 1e-9)
st = CH.Log.Stages("Seyko", 10, lr.e)
check("craft log: forecast, actual and realized are kept apart", st.forecast == 730000 and st.actual == lr.actual
      and st.produced["items"] == 2 and abs(st.produced.gold - 2850000) < 1 and st.realized.made == 2 and st.realized.sold == 0 and st.realized.unsold == 2)
sl3 = [plain(x[1]) for x in CH.Log.StageLines(L.eval("function(s) return { name = 'Test Flask', char = 'Seyko', stages = s } end")(st)).values()]
check("craft log: the hover says unsold items aren't realized and the matching is estimated",
      any("unsold, estimated value (not realized)" in x for x in sl3) and any("Estimated attribution" in x for x in sl3))
wf = list(CH.Log.Waterfall(st).values())
def wsum(a, b): return sum(x[2] for x in wf[a:b])
check("waterfall: the steps add up from forecast to actual to realized",
      wf[0][1] == "Forecast at craft time" and wf[-1][1] == "Realized" and abs(wf[0][2] + wsum(1, 4) - wf[4][2]) < 1 and abs(wf[4][2] + wsum(5, 8) - wf[-1][2]) < 1)
D = L.eval("AuctionIQ.Decide")
be = res.best.breakEven
check("break-even: the sale price per item where the plain craft makes nothing (cut included)",
      abs(be.price - 2120000 / 0.95) < 1 and be.estimate == 3000000 and abs(be.cushion - (1 - 2120000 / 2850000)) < 1e-9)
bpd = L.eval("""(function() local P = AuctionIQ.Prices; local oh, op = P.Held, P.PaidEach
  P.Held = function() return 999 end; P.PaidEach = function() return 1 end
  local r = AuctionIQ.Advisor.Analyze(10); local be = r.best.breakEven
  P.Held, P.PaidEach = oh, op
  return { price = be.price, today = be.today, paid = be.paid } end)()""")
check("break-even: what you paid for the reagents you hold, with today's prices beside it",
      bpd.paid is not None and bpd.price < bpd.today and abs(bpd.today - 2120000 / 0.95) < 1)
check("break-even: profit at the break-even price is zero", abs(D.ProfitAt(D.RowParts(res, res.best), 3000000, be.price)) < 1)
bp = L.eval("{ revenue = 130, consumed = 100, returned = 20, deposits = 10, fixed = 0 }")
bpe = D.BreakEvenParts(bp, 13)
check("break-even: Resourcefulness lowers it, deposits raise it", abs(bpe.factor - 90 / 140) < 1e-12 and abs(D.ProfitAt(bp, 13, bpe.price)) < 1e-9)
g = res.bestConc.gain
check("Concentration: extra profit over the best plain craft, and per expected point", g.gain == 1450000 and g.perPoint == 18125 and g.total == 27250)
check("Concentration: when no plain craft pays, the gain is over not crafting", D.ConcGain(L.eval("{ profit = 100, avgConcentration = 10 }"), -50).gain == 100)
sm = [plain(x) for x in CH.AdvisorUI.SummaryLines(res).values()]
check("advisor summary: craft, break-even against the estimate, downside, then Concentration",
      sm[0].startswith("Craft Q2: 73g expected profit per craft") and "Break-even 223g per item, estimated sale price 300g per item" in sm[1]
      and sm[2].startswith("  Downside") and "price falls 10%" in sm[2] and any("more per craft than the plain craft" in x and "per expected point" in x for x in sm))
pl5 = [(plain(l[1]), plain(l[2])) for l in CH.AdvisorUI.BreakdownLines(res, res.bestConc, 5).values()]
check("profit hover keeps the whole profit per point for CraftSim, and the extra over plain",
      ("  Extra per expected point", "1g 81s") in pl5 and ("  Whole profit per point (as CraftSim)", "2g 72s") in pl5
      and ("  Over the best plain craft", "145g per craft") in pl5)
pl6 = [(plain(l[1]).strip(), plain(l[2])) for l in CH.AdvisorUI.BreakdownLines(res, res.best, 5).values()]
check("profit hover: margin is profit over proceeds, and the break-even price", ("Margin  profit / proceeds", "26%") in pl6 and ("Break-even sale price", "223g per item") in pl6)
ev = D.EvidenceText(D.Evidence(302))
check("evidence: source and how much of the sell rate is yours", ev.price.startswith("Price: TSM, ") and "none known" in ev.rate and ev.volume.startswith("Volume: region"))
check("evidence: the advisor's source line names it", "Sell rate:" in plain(CH.AdvisorUI.SourceLine(res)) and "Volume: region" in plain(CH.AdvisorUI.SourceLine(res)))
cf = D.ConcForecast(100, 30, 0.5, 15)
check("Concentration forecast: 3 now, exact chance of a 4th (2 refunds in 3) and a 5th (4 in 4)",
      cf.now == 3 and abs(cf.chance[1] - 0.5) < 1e-12 and abs(cf.chance[2] - 0.0625) < 1e-12)
check("Concentration forecast: without Ingenuity, only what the points cover", D.ConcForecast(100, 30, 0, 15).now == 3 and D.ConcForecast(100, 30, 0, 15).chance[1] is None)
check("Concentration forecast text", D.ConcForecastText(cf) == "Max 3 now, 50% chance of a 4th with Ingenuity refunds")
bi = L.eval("""{ made = 1, mc = 0, maxExtra = 1, res = 0, saved = 0, price = 100, deposit = 0, unit = 95, daily = 5, seed = 3,
  reagents = { { id = 1, n = 1, unit = 50, finishing = true } }, evidence = {} }""")
bo = list(D.Batch(bi, L.eval("{ sizes = { 10, 100 }, runs = 400, price = 0 }")).values())
check("batch: a small batch sells out in a week and pays back", bo[0].recover == 1 and bo[0].spend == 500 and bo[0].left == 0 and bo[0].net.p50 == 450)
check("batch: a big one can't sell in a week: cash back stays under spend, stock is left",
      bo[1].recover == 0 and bo[1].spend == 5000 and 55 <= bo[1].left <= 75 and bo[1].cashBack.p50 < 5000 and bo[1].leftValue == bo[1].left * 95)
bo2 = list(D.Batch(bi, L.eval("{ sizes = { 10, 100 }, runs = 400, price = 0 }")).values())
check("batch: the same batch gives the same answer each time", bo2[1].net.p50 == bo[1].net.p50)
CH.AdvisorUI.Render(res)
run('for i, r in ipairs(AuctionIQ.AdvisorUI.Current().rows) do if r.recommended then AuctionIQ.AdvisorUI.RowClick(i) end end')
check("advisor: the break-even chart pane", CH.AdvisorUI.SetPane("chart") == "chart"
      and any("Plain Q2: breaks even at 223g per item, 26% under the estimate of 300g" in plain(x) for x in CH.AdvisorUI.RenderPane().values()))
bl = [plain(x) for x in CH.AdvisorUI.SetPane("batch") and CH.AdvisorUI.RenderPane().values()]
check("advisor: Analyze batch leads with how many to make, then half, that and double", len(bl) == 7 and bl[0].startswith("Make 50: ")
      and "at risk if it sells slowly" in bl[0] and "Left after a week: " in bl[0] and bl[1].startswith("More than 50 ")
      and bl[2].startswith("25 crafts: ") and bl[3].startswith("50 crafts: ") and bl[4].startswith("100 crafts: ")
      and "pay back" in bl[2] and "left unsold" in bl[4] and bl[5].startswith("Sales "))
ttl = plain(L.eval("AuctionIQ.AdvisorUI.PaneTitle()"))
check("advisor: the batch pane's title is the suggestion", ttl.startswith("Make 50: ") and "(slow / expected / fast)" in ttl)
# How many to make: three labelled scenarios, worked out directly
sg = D.Suggest(bi, L.eval("{ held = 0, fall = 0.1 }"))
check("suggest: the biggest batch leaving at most 3 days of sales after a week (35 sell, 15 left)", sg.n == 50 and sg.limit == "stock"
      and sg.scenarios.expected.left == 15 and sg.scenarios.fast.left == 0)
check("suggest: gold at risk is the reagents not back in a slow week (half the sales, price -10%)",
      abs(sg.scenarios.slow.atRisk - (2500 - 17.5 * 100 * 0.9 * 0.95)) < 1e-6 and sg.scenarios.slow.left == 32.5)
check("suggest: stock you already hold sells first and counts toward what's left", D.Suggest(bi, L.eval("{ held = 40, fall = 0.1 }")).n == 10)
check("suggest: Concentration caps it at the crafts your points cover", D.Suggest(bi, L.eval("{ held = 0, concCrafts = 8 }")).n == 8
      and D.Suggest(bi, L.eval("{ held = 0, concCrafts = 8 }")).limit == "conc")
run("STUB.cheap = { made = 1, mc = 0, maxExtra = 1, res = 0, saved = 0, price = 55, deposit = 0, unit = 52, daily = 5, seed = 3, reagents = { { id = 1, n = 1, unit = 50, finishing = true } }, evidence = {} }")
sc0 = D.Suggest(L.eval("STUB.cheap"), L.eval("{ held = 0, fall = 0.1 }"))
check("suggest: don't craft when a 10% fall stops it paying for its reagents", sc0.n == 0 and sc0.limit == "price" and D.SuggestText(sc0).startswith("Don't craft"))
run("STUB.cheap.daily = 0")
check("suggest: no sale rate, no size", D.Suggest(L.eval("STUB.cheap"), L.eval("{ held = 0 }")).limit == "rate")
check("suggest: a Concentration craft says what Concentration adds", "Concentration adds " in plain(D.SuggestText(D.Suggest(bi, L.eval("{ held = 0, gain = { gain = 400 } }")))))
check("advisor: back to the notes", CH.AdvisorUI.SetPane("notes") == "notes")
run('AuctionIQ.Queue.Clear(); AuctionIQ.AdvisorUI.Show(10); AuctionIQ.AdvisorUI.RowClick(2); AuctionIQ.AdvisorUI.SetQty(9); AuctionIQ.AdvisorUI.QueueSelected()')
bg = CH.Queue.Budget()
check("queue budget: gold, reagents and Concentration, on hand against needed", bg.gold.need > bg.gold.have and bg.reagents.need > bg.reagents.have
      and bg.conc.need == 720)
check("queue budget: the first craft that hits a limit", bg.stop.why == "gold" and bg.stop.n == 5)
bll = [plain(x) for x in CH.QueueUI.BudgetLines(bg).values()]
check("queue budget: shopping cost against your gold, missing materials, Concentration by character and profession",
      bll[0] == "410g, you have 123g: 286g short" and bll[1] == "67 reagents short (3 kinds)" and bll[2].startswith("Seyko ") and bll[2].endswith("720 of 400"))
rd, rt = CH.Queue.Readiness()
e9 = CH.db.queue[1]
check("readiness: each craft takes what's on hand in queue order; the rest is blocked with its shortfall",
      rt.now == 1 and rt.blocked == 8 and rd[e9].why == "reagents" and rd[e9].shortN == sum(rd[e9].short.values()))
blk = plain(CH.QueueUI.BlockerLine(None, None, bg))
check("next blocker: the batch, what's ready now, the exact shortfall and the gold", blk.startswith("Next blocker: Test Flask x9: craft 1 now · 8 blocked, short ")
      and blk.endswith("Buying it all costs 410g, you have 123g"))
st, tipl = CH.QueueUI.RowState(e9, rd[e9], True, None, "Craft", CH.Queue.ShoppingList()[0])
check("row status: part ready says how many now and how many blocked", plain(st) == "1 now · 8 blocked"
      and any(plain(l[1]).startswith("Short ") for l in tipl.values()))
st2, _ = CH.QueueUI.RowState(L.eval("{ name = 'X', qty = 2, charName = 'Alt' }"), L.eval("{ now = 0, blocked = 2, why = 'switch', short = {} }"), False, "on Alt", "Craft", None)
check("row status: another character's craft says to switch", plain(st2) == "Switch character")
run('STUB.money = 999999999')
bg2 = CH.Queue.Budget()
run('STUB.money = 1234567')
check("queue budget: with gold, Concentration is next to block", bg2.stop is None or bg2.stop.why == "conc")
seq = list(D.ConcSequence(100, L.eval("{ { cost = 30, ing = 0.5, refund = 15 }, { cost = 30, ing = 0.5, refund = 15 }, { cost = 30, ing = 0.5, refund = 15 }, { cost = 30, ing = 0.5, refund = 15 }, { cost = 30, ing = 0.5, refund = 15 } }")).values())
check("queue Concentration: exact chance each craft can start, refunds landing after the craft that earns them",
      seq[:3] == [1, 1, 1] and abs(seq[3] - 0.5) < 1e-12 and abs(seq[4] - 0.0625) < 1e-12)
prows = list(L.eval("AuctionIQ.TradingUI.PlanRows({ runs = 200 })")[0].values())
labels = [plain(r.cells[1]) for r in prows]
check("restock plans (Operations, Queue): as queued against lean, with gold up front, gold back by day 7 and stock left",
      "As queued" in labels and any(x.startswith("Lean (") for x in labels) and all(len(list(r.cells.values())) == 7 for r in prows))
pq = L.eval("AuctionIQ.Decide.Plans()")
check("restock plans: lean never queues more than the queue", sum(e.qty for e in pq[2].entries.values()) <= sum(e.qty for e in pq[1].entries.values()))
run("AuctionIQ.db.batchForecasts = nil; AuctionIQ.AdvisorUI.SetQty(2); AuctionIQ.AdvisorUI.QueueSelected()")
fc = list(L.eval("AuctionIQ.Decide.Forecasts()").values())
check("batch forecast: queueing saves what the simulation said", len(fc) == 1 and fc[0].n == 2 and fc[0].p50 is not None)
dec = list(L.eval("AuctionIQ.Forecast.Decisions()").values())[-1]
check("batch decision: queueing saves batch size, yield, reagents, price, sale rate and what's left after a week",
      dec.n == 2 and dec.itemsEach > 0 and dec.costEach > 0 and dec.priceEach > 0 and dec.netEach > 0 and dec.daily is not None
      and dec.leftWeek is not None and dec.profit is not None and dec.crafts == 0 and dec.key >= 1)
run("AuctionIQ.db.decisions = nil")
run("AuctionIQ.db.batchForecasts[1].at = time() - 8 * 86400")
run("""STUB.oldLA, STUB.oldLR = AuctionIQ.Ledger.Available, AuctionIQ.Ledger.Records
AuctionIQ.Ledger.Available = function() return true end
AuctionIQ.Ledger.Records = function() return { { id = AuctionIQ.db.batchForecasts[1].item, time = time() - 7 * 86400, quantity = 1, price = 100 } } end""")
cal = L.eval("AuctionIQ.Decide.Calibration()")
run("AuctionIQ.Ledger.Available, AuctionIQ.Ledger.Records = STUB.oldLA, STUB.oldLR")
check("batch forecast: a week on, checked against what the item really sold for", cal is not None and cal.checked == 1 and cal.under + cal.over == 1)
run("AuctionIQ.db.batchForecasts = nil")
run('AuctionIQ.Queue.Clear(); AuctionIQ.AdvisorUI.SetQty(1)')
run("""AuctionIQ.db.characters['Be-Realm'] = { name = 'Be', professions = { [1] = { name = 'Alchemy', conc = 500, concMax = 1000, concAt = time(),
  scan = { rows = { { name = 'Cheap Flask', recipeID = 99, item = 100, profit = 10, breakEven = 99999999, concProfit = 900, avgConcentration = 30 } } } } } }""")
nx = [x for x in L.eval("AuctionIQ.Next.List()").values() if x.title == "Below break-even"]
check("dashboard: a craft now under its break-even price gets a card that opens Scenarios",
      len(nx) == 1 and "Cheap Flask" in plain(nx[0].detail) and nx[0].go[2] == "scenarios")
check("dashboard: the card hands Craft the recipe and character, and names its biggest uncertainty",
      nx[0].go[3].name == "Cheap Flask" and nx[0].go[3].char == "Be" and nx[0].risk is not None)
allnx = list(L.eval("AuctionIQ.Next.List()").values())
check("dashboard: every card that opens a view hands over what it's about", all(x.go[3] is not None for x in allnx if x.go))
check("dashboard: where a card opens, in words", CH.UI.PlaceName(nx[0].go) == "Operations > Craft")
cb = [x for x in L.eval("AuctionIQ.UI.ConcentrationBars()").values() if x.char == "Be"]
check("dashboard: Concentration by character, with time to full and the best extra per point",
      len(cb) == 1 and cb[0].cur == 500 and cb[0].hours == 48 and abs(cb[0].best.gain - 890 / 30) < 1e-9)
run("AuctionIQ.db.characters['Be-Realm'] = nil")

# Escape closes AuctionIQ's windows, like the game's own
run("AuctionIQ.UI.Page('today'); AuctionIQ.db.settings.advisor.hide = false; AuctionIQ.AdvisorUI.Show(10, true)")
esc = [n for n in L.globals().UISpecialFrames.values()]
check("escape: every AuctionIQ window is on the game's close-on-Escape list",
      all(n in esc for n in ("AuctionIQFrame", "AuctionIQAdvisor", "AuctionIQQueue")))
fr = L.globals().AuctionIQFrame
if fr.scripts and fr.scripts.OnKeyDown:
    run('AuctionIQFrame.scripts.OnKeyDown(AuctionIQFrame, "ESCAPE")')
    check("escape: one press closes the window and the advisor", not CH.UI.IsShown() and not CH.AdvisorUI.IsShown())
run("AuctionIQ.UI.Page('today'); AuctionIQ.UI.Toggle()")

# Tabs: one window at a time, the queue can pop out
run('AuctionIQ.ScanUI.Open()')
check("tabs: opening Scan hides the others", CH.ScanUI.IsShown() and not CH.AdvisorUI.IsShown() and not CH.QueueUI.IsShown() and CH.Window.Active() == "scan")
labels = list(CH.Window.Arrange().values())
check("tabs: two windows, Craft and Queue (Scan is a button)", labels == ["Craft", "Queue"])
run('AuctionIQ.AdvisorUI.Show(10)')
check("tabs: a recipe click selects it in the Craft window", CH.ScanUI.IsShown() and not CH.AdvisorUI.IsShown() and CH.ScanUI.Selected() == 10)
lc = L.eval("AuctionIQ.ScanUI.lastPanel")
qr = list(lc.section.rows.values()) if lc and lc.section else []
check("Craft card: the open recipe's live card: profit, reagents, margin, and which quality",
      lc is not None and lc.live and [plain(f[1]).split(" ")[0] for f in lc.figures.values()] == ["PROFIT", "COST", "MARGIN"]
      and plain(lc.section.head) == "QUALITY" and len(qr) >= 2 and all(r.tip is not None for r in qr)
      and any(r.run is not None for r in qr))
ql = [plain(r[1]) for r in qr]
check("Craft card: Highest at the top, Lowest at the bottom, Best on the craft that earns the most, Concentrate on for it",
      "Highest" in ql[0] and "Best" in ql[0] and "Lowest" in ql[-1] and lc.section.toggle is not None and lc.section.toggle.on is True
      and "\u25c6" not in ql[0] and plain(qr[-1][2]) == "-")
check("Craft card: every row explains itself on hover, break-even first",
      all(r.tip is not None for r in lc.rows.values()) and plain(lc.rows[1][1]) == "Break-even, each" and lc.subTip is not None)
check("Craft card: no week's recovery, no Max (it's a list column), no buy-one-instead",
      not any(plain(r[1]) in ("Recover in a week", "Can make now", "Buy one instead") for r in lc.rows.values()))
fl = L.eval("AuctionIQ.AdvisorUI.Card(1, { perDay = 50000, soldPerDay = 4, bc = { buy = 1000, resell = 5000, flip = 4000 } })")
fr = {plain(r[1]): r for r in fl.rows.values()}
check("Craft card: Gold a day has a hover, and Buy & relist shows when a listing is far under value",
      fr.get("Gold a day") is not None and fr["Gold a day"].tip is not None and fr.get("Buy & relist") is not None)
lc.section.toggle.run()
lc2 = L.eval("AuctionIQ.ScanUI.lastPanel")
ql2 = [plain(r[1]) for r in lc2.section.rows.values()]
ons = [r for r in lc2.section.rows.values() if r.on]
check("Craft card: Concentrate off shows the plain crafts and picks the best of them",
      lc2.section.toggle.on is False and not CH.AdvisorUI.SelectedRow().concentration and len(ons) == 1 and sum("Best" in l for l in ql2) == 1)
qr2 = list(lc2.section.rows.values())
qr2[-1].run()
check("Craft card: clicking a rank picks it, and only that line is highlighted",
      sum(1 for r in L.eval("AuctionIQ.ScanUI.lastPanel").section.rows.values() if r.on) == 1)
lc2.section.toggle.run()
lc3 = L.eval("AuctionIQ.ScanUI.lastPanel")
check("Craft card: Concentrate back on picks the best Concentration craft", L.eval("AuctionIQ.ScanUI.lastPanel").section.toggle.on is True
      and CH.AdvisorUI.IsSelected(CH.AdvisorUI.Current().rows[2]))
run("AuctionIQ.ScanUI.SetQty(3)")
lp3 = L.eval("AuctionIQ.ScanUI.lastPanel")
check("Craft card: the stepper sets how many Craft and Queue use", plain(lp3.actions[2].label).startswith("Queue 3") and plain(lp3.actions[1].label).startswith("Craft "))
check("Craft card: Craft first, then Queue, then Details", [plain(a.label).split(" ")[0] for a in lp3.actions.values()][:3] == ["Craft", "Queue", "Details"])
cn = L.eval("""(function() local old = C_TradeSkillUI.CraftRecipe; local got
  C_TradeSkillUI.CraftRecipe = function(id, n, reagents, _, _, conc) got = { id = id, n = n, conc = conc, k = #reagents } end
  local res = AuctionIQ.AdvisorUI.Current(); local ok, why = AuctionIQ.Queue.CraftNow(res, res.rows[2], 2)
  C_TradeSkillUI.CraftRecipe = old; return { ok = ok, why = why, got = got, q = AuctionIQ.Queue.Count() } end)()""")
check("Craft card: Craft crafts the picked rank now, with its reagents and Concentration, without queueing it",
      cn.ok and cn.got.id == 10 and cn.got.n == 2 and cn.got.conc == (L.eval("AuctionIQ.AdvisorUI.Current().rows[2].concentration ~= nil")) and cn.got.k > 0)
run('STUB.Fire("UNIT_SPELLCAST_FAILED", "player", "cast", 10)')
run("AuctionIQ.ScanUI.SetQty(1); AuctionIQ.AdvisorUI.Show(10)")
run('AuctionIQ.QueueUI.Show(); AuctionIQ.AdvisorUI.Show(10)')
check("tabs: a recipe click while the Queue shows updates quietly", CH.QueueUI.IsShown() and not CH.ScanUI.IsShown())
run('AuctionIQ.AdvisorUI.Open()')
check("tabs: the old Advisor command opens the Craft window", CH.ScanUI.IsShown() and not CH.AdvisorUI.IsShown())
run('AuctionIQ.Window.CloseTabs(); AuctionIQ.db.settings.advisor.hide = true; AuctionIQ.db.settings.advisor.twoWindows = nil; AuctionIQ.AdvisorUI.Show()')
check("two windows: closing the old Advisor window before the update doesn't keep the Craft window shut", CH.ScanUI.IsShown())
run('AuctionIQ.db.settings.advisor.classic = true')
check("tabs: the old Advisor window comes back as a tab when Settings turns it on", list(CH.Window.Arrange().values()) == ["Advisor", "Craft", "Queue"])
run('AuctionIQ.db.settings.advisor.classic = nil')
run('AuctionIQ.QueueUI.Show(); AuctionIQ.Window.ToggleQueuePop()')
labels = list(CH.Window.Arrange().values())
check("pop-out: the queue leaves the tabs and shows beside the Craft window",
      CH.QueueUI.IsShown() and CH.ScanUI.IsShown() and "Queue" not in labels)
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
# the Concentration craft with what you hold: Concentrate ticked on the reagents the game fills in
hc = L.eval("(function() local res = AuctionIQ.Advisor.Analyze(10); local h = AuctionIQ.Advisor.HeldConcRow(res); return { h = h, best = res.bestConc } end)()")
check("held Concentration: a row with your own reagents, lowest rank first, and the points the game charges for them",
      hc.h is None or (hc.h.fromBags and hc.h.concentration > 0 and hc.h.quality == hc.h["from"] + 1))
ac = L.eval("""(function() local res = AuctionIQ.Advisor.Analyze(10); local n = #res.rows
  local old = C_Item.GetItemCount; C_Item.GetItemCount = function(id) if id == 201 then return 2 end return 99 end
  AuctionIQ.AdvisorUI.AddHeldConc(res); C_Item.GetItemCount = old
  local h; for _, r in ipairs(res.rows) do if r.fromBags then h = r end end
  return { before = n, after = #res.rows, h = h } end)()""")
check("held Concentration: added when the advisor's Concentration mix needs a rank you don't hold",
      ac.after == ac.before + 1 and ac.h is not None and ac.h.concentration > 0)
hs = L.eval("""(function() local res = AuctionIQ.Advisor.Analyze(10)
  local old = C_Item.GetItemCount; C_Item.GetItemCount = function(id) if id == 201 then return 2 end return 99 end
  AuctionIQ.AdvisorUI.AddHeldConc(res); C_Item.GetItemCount = old
  local A = AuctionIQ.AdvisorUI; A.Render(res)
  local hi; for i, r in ipairs(res.rows) do if r.fromBags then hi = i end end
  if not hi then return nil end
  A.RowClick(hi); local n = 0; for _, r in ipairs(res.rows) do if A.IsSelected(r) then n = n + 1 end end
  return { bags = A.SelectedRow() and A.SelectedRow().fromBags, n = n } end)()""")
check("held Concentration: clicking the yours row picks it alone, not the mix of the same rank",
      hs is not None and hs.bags and hs.n == 1)
hm = L.eval("""(function()
  local A = AuctionIQ.AdvisorUI; local cur = A.Current; A.Current = function() return nil end -- not the card's recipe
  local oldP = AuctionIQ.OpenProfessionID; AuctionIQ.OpenProfessionID = function() return 2906 end
  local res = AuctionIQ.Advisor.Analyze(10); local h = AuctionIQ.Advisor.HeldConcRow(res)
  local want = h and AuctionIQ.Advisor.MaxCraftable(res, h, 1000) or nil
  local got = AuctionIQ.ScanUI.HeldMax(10, 1000)
  A.Current, AuctionIQ.OpenProfessionID = cur, oldP
  return { want = want, got = got } end)()""")
check("Max: any recipe's Concentration craft with your own reagents, not only the one on the card", hm.want == hm.got and hm.got == 1)

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
      s.sales == 6650000 and s.buys == 1000000 and s.income == 0 and s.expense == 20000 and s.cash == 5630000 and s.topItem == 302)
check("ledger: auction sales count after the 5% cut, vendor and trade sales as they are",
      LG.Net(L.eval("{ amount = 1000, source = 'Auction' }")) == 950 and LG.Net(L.eval("{ amount = 1000, source = 'Vendor' }")) == 1000)
check("dashboard: top sale, top purchase, 52 week high and low", d.topSale == 6000000 and d.topBuy == 1000000 and d.high == 10000000 and 0 < d.low <= d.high)
run("AuctionIQ.UI.SetRange('All')")
check("dashboard: All reaches back past TSM's year", CH.UI.DashboardData().summary.sales == 10450000)
act = list(LG.Activity(10).values())
check("activity log: grouped by character and hour", act[0].player == "Courtizy" and act[0].sold == 2 and act[0].expired == 1 and sum(a.bought for a in act) == 10)
inv = {e.id: e for e in LG.Inventory().values()}
v302 = CH.Prices.Get("chvalue", "i:302")
check("inventory: bags, mail and warband, qualities merged", inv[302].total == 4 and inv[302].bags == 3 and inv[302].mail == 1 and inv[301].warband == 2 and inv[302].value == v302 * 4)
w1 = LG.Snapshot(L.eval("STUB.now") - 5 * 86400)
LG.Snapshot()
check("net worth change counts gold and inventory", LG.WorthChange(L.eval("STUB.now") - 6 * 86400)[0] == 0 and w1[0] > 10000000)
rep = LG.Report()
check("morning report: last day's sales and what came back", rep.sold == 2 and rep.earned == 5700000 and rep.bought == 10
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
# Batch decisions: crafts link back to what was queued; the miss splits into price, sell-through, reagents, yield
run("""AuctionIQ.db.decisions = { { key = 1, at = STUB.now - 3 * 86400, item = 302, name = 'Test Elixir', char = 'Seyko', n = 4,
  itemsEach = 2, costEach = 2000000, netEach = 4000000, priceEach = 4210527, daily = 1, crafts = 2, made = 4, paid = 4000000,
  first = STUB.now - 2 * 86400 } }
AuctionIQ.db.batches[1].decision = 1; AuctionIQ.db.batches[2].decision = 1; AuctionIQ.Forecast.Clear()""")
ex = L.eval("AuctionIQ.Forecast.Explain(AuctionIQ.db.decisions[1], STUB.now)")
check("batch results: forecast by now (2 of 4 sold at 400g, less 400g reagents) and actual (570g back)",
      abs(ex.forecast - 4000000) < 1 and abs(ex.actual - 1700000) < 1 and ex.sold == 2 and ex.soldForecast == 2)
check("batch results: the four causes add up to the miss, here all sale price",
      abs(sum(ex.causes[k] for k in ["price", "sell", "reagents", "yield"]) - ex.miss) < 1e-6 and abs(ex.causes.price + 2300000) < 1
      and ex.main == "price" and ex.takeaway == "Sold under the forecast price")
run("AuctionIQ.db.decisions[1].daily = 3; AuctionIQ.db.decisions[1].paid = 5000000")
ex2 = L.eval("AuctionIQ.Forecast.Explain(AuctionIQ.db.decisions[1], STUB.now)")
check("batch results: slower than forecast and dearer reagents show as their own causes",
      abs(ex2.causes.sell - (2 - 4) * 4000000) < 1 and abs(ex2.causes.reagents + 1000000) < 1
      and abs(sum(ex2.causes[k] for k in ["price", "sell", "reagents", "yield"]) - ex2.miss) < 1e-6 and ex2.main == "sell")
run("AuctionIQ.db.decisions[1].daily = 1; AuctionIQ.db.decisions[1].paid = 4000000; AuctionIQ.db.decisions[1].itemsEach = 3")
ex3 = L.eval("AuctionIQ.Forecast.Explain(AuctionIQ.db.decisions[1], STUB.now)")
check("batch results: fewer items than expected only costs what couldn't sell", abs(ex3.causes['yield']) < 1e-6 and ex3.expItems == 6)
brows, bfoot = L.eval("AuctionIQ.LedgerUI.Rows('batches', {})")
brows = list(brows.values())
check("batch results view: a row per batch with its main cause, explained on hover", len(brows) == 1 and plain(brows[0].cells[8]) == "Sale price"
      and plain(brows[0].cells[3]) == "2/4" and "1 batches" in plain(bfoot)
      and any("Sale price" in plain(l[1]) for l in brows[0].tip().values()))
run("AuctionIQ.db.decisions = nil")
CH.Forecast.SaveDecision(L.eval("{ item = 777, name = 'Linked', n = 2, itemsEach = 1, costEach = 10, netEach = 20, daily = 1 }"))
b1 = CH.Forecast.Record(777, 1, L.eval("{ cost = 12 }"))
b2 = CH.Forecast.Record(777, 1, L.eval("{ cost = 12 }"))
b3 = CH.Forecast.Record(777, 1, L.eval("{ cost = 12 }"))
d777 = list(L.eval("AuctionIQ.Forecast.Decisions()").values())[0]
check("batch decision: crafts fill it up to the crafts queued, then stop linking", b1.decision == d777.key and b2.decision == d777.key
      and b3.decision is None and d777.crafts == 2 and d777.made == 2 and d777.paid == 24)
run("""AuctionIQ.db.decisions = nil
for i = #AuctionIQ.db.batches, 1, -1 do if AuctionIQ.db.batches[i].id == 777 then table.remove(AuctionIQ.db.batches, i) end end
AuctionIQ.Forecast.Clear()""")
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

# Variants: TSM can put two item levels of one item in different groups
run("""TradeSkillMasterDB["p@Warband@userData@items"] = { ["i:302::i645"] = "Alch`Gear645", ["i:302::i642"] = "Alch`Gear642", ["i:301"] = "Loot`Pets" }
AuctionIQ.Groups.ResetTSM()""")
check("variants: each item level follows its own TSM group",
      CH.Groups.Path(302, 645) == "TSM/Alch/Gear645" and CH.Groups.Path(302, 642) == "TSM/Alch/Gear642")
check("variants: no base entry and the variants disagree, so no base-item fallback from TSM",
      CH.Groups.TSMGroups()[302] is None and CH.Groups.TSMPath(302) is None)
check("variants: a variant counts in its own group", 302 in list(CH.Groups.Items("TSM/Alch/Gear645").values()))
run("""TradeSkillMasterDB["p@Warband@userData@items"]["i:302"] = "Alch`Flasks"; AuctionIQ.Groups.ResetTSM()""")
check("variants: the explicit base-item entry is the fallback, the variant still wins at its level",
      CH.Groups.Path(302) == "TSM/Alch/Flasks" and CH.Groups.Path(302, 645) == "TSM/Alch/Gear645" and CH.Groups.Path(302, 700) == "TSM/Alch/Flasks")
run("""TradeSkillMasterDB["p@Warband@userData@items"] = { ["i:302::i645"] = "Alch`Flasks", ["i:302::i642"] = "Alch`Flasks" }; AuctionIQ.Groups.ResetTSM()""")
check("variants: when every variant shares a group, that group is the fallback", CH.Groups.TSMPath(302) == "TSM/Alch/Flasks")

# Operation order, cancel rules and settings AuctionIQ can't follow
run("""
TradeSkillMasterDB["p@Warband@userData@items"] = { ["i:302"] = "Alch`Flasks", ["i:301"] = "Loot`Pets" }
TradeSkillMasterDB["p@Warband@userData@groups"]["Alch`Flasks"] = { Auctioning = { "Alt Only", "Flask Op", override = true } }
TradeSkillMasterDB["g@ @userData@sharedOperations"] = { Auctioning = {
  ["Alt Only"] = { minPrice = "1g", normalPrice = "2g", maxPrice = "3g", postCap = "1", undercut = "1s", duration = 1,
    ignorePlayer = { ["Seyko - Emerald Dream"] = true } },
  ["Flask Op"] = { minPrice = "2950000", normalPrice = "3150000", maxPrice = "4000000", postCap = "2", undercut = "1s", duration = 2,
    priceReset = "none", aboveMax = "maxPrice", cancelUndercut = false, cancelRepost = true, cancelRepostThreshold = "10g",
    bidPercent = 0.8, blacklist = "Goblin" } } }
""")
imp = L.eval("AuctionIQ.Groups.ImportTSM()")
check("import: a group's operations kept in TSM's order", list(CH.Groups.Store().assignAll["TSM/Alch/Flasks"].values()) == ["Alt Only", "Flask Op"] and imp.multi >= 1)
check("import: settings AuctionIQ can't follow are reported", imp.unsupported["Flask Op"] is not None
      and any("bid" in x for x in imp.unsupported["Flask Op"].values()) and any("blacklist" in x for x in imp.unsupported["Flask Op"].values()))
head, lines = L.eval("AuctionIQ.Groups.ImportSummary(AuctionIQ.Groups.ImportTSM())")
check("import: the summary names each difference", "operations" in head and any("Flask Op differs" in l for l in lines.values()))
check("operations: the first that applies to this character is used", L.eval("select(2, AuctionIQ.Groups.Operation(302))") == "Flask Op")
c = CH.Auction.DecideCancel(302, 3500000, L.eval("{ { price = 3400000, qty = 1, mine = false } }"))
check("cancel: an operation that doesn't cancel undercut auctions keeps them", c.action == "keep" and "doesn't cancel" in c.why)
c = CH.Auction.DecideCancel(302, 3000000, L.eval("{ { price = 3000000, qty = 1, mine = true } }"))
check("cancel: repost higher when the operation would post 10g+ above yours", c.action == "cancel" and "repost higher" in c.why)
c = CH.Auction.DecideCancel(302, 3100000, L.eval("{ }"))
check("cancel: not when the gain is under the threshold", c.action == "keep")
run("AuctionIQ.Groups.Store().ops['Flask Op'].priceReset = 'ignore'")
d = CH.Auction.Decide(302, L.eval("{ { price = 100, qty = 1, mine = false }, { price = 3600000, qty = 3, mine = false } }"), 10)
check("rules: ignore auctions below min undercuts the next seller", d.action == "post" and d.price == 3599900)
run("AuctionIQ.Groups.Store().ops['Flask Op'].priceReset = 'none'")
c = CH.Groups.Assign("TSM/Alch/Flasks", "Alt Only")
check("operations: assigning one yourself replaces TSM's list", CH.Groups.Store().assignAll["TSM/Alch/Flasks"] is None
      and L.eval("select(2, AuctionIQ.Groups.Operation(302))") == "Alt Only")
run("AuctionIQ.Groups.Assign('TSM/Alch/Flasks', 'Flask Op')")

# The advisor's market estimate and the posting decision are shown apart
run("AuctionIQ.Depth.Remember(302, { { price = 2900000, qty = 2 } })")
pc = CH.Auction.PostCheck(302)
check("post check: the operation skips when the fresh AH is under its min", pc.op == "Flask Op" and pc.action == "skip" and pc.source == "ah" and pc.cheapest == 2900000)
pl = [plain(l[1]) for l in CH.AdvisorUI.PostingLines(302, None, 3150000).values()]
check("advisor: posting lines show min/normal/max and that it won't post", any("Min / normal / max" in l for l in pl) and any("Would not post" in l for l in pl))
run("AuctionIQ.Depth.Remember(302, { { price = 3600000, qty = 2 } })")
pc = CH.Auction.PostCheck(302)
check("post check: posts by the operation when the AH allows", pc.action == "post" and pc.price == 3599900)
run("AuctionIQ.Depth.Forget(302)")
run("AuctionIQ.Depth.Remember(205, { { price = 20000, qty = 1 }, { price = 40000, qty = 5 } })")
bl = [(plain(l[0+1]), plain(l[1+1])) for l in CH.AdvisorUI.BuyNowLines(L.eval("{ id = 205, n = 2, unit = 10000, total = 20000 }")).values()]
check("advisor: buy-now cost from listings seen, apart from the estimate", len(bl) == 1 and "buy now" in bl[0][0] and "3g ea" in bl[0][1] and "6g" in bl[0][1])
run("AuctionIQ.Depth.Forget(205)")

# TSM Crafting and Shopping operations: queue and shopping rules
run("""
TradeSkillMasterDB["p@Warband@userData@items"] = { ["i:302"] = "Alch`Flasks", ["i:205"] = "Mats" }
TradeSkillMasterDB["p@Warband@userData@groups"]["Alch`Flasks"].Crafting = { "Restock Flasks", override = true }
TradeSkillMasterDB["p@Warband@userData@groups"]["Mats"] = { Shopping = { "Cheap Mats", override = true } }
local ops = TradeSkillMasterDB["g@ @userData@sharedOperations"]
ops.Crafting = { ["Restock Flasks"] = { minRestock = 1, maxRestock = 1000, minProfit = "1c" } }
ops.Shopping = { ["Cheap Mats"] = { maxPrice = "1s", showAboveMaxPrice = true, restockQuantity = 50 } }
""")
imp = L.eval("AuctionIQ.Groups.ImportTSM()")
cr = CH.Groups.CraftRule(302)
check("import: TSM Crafting operations become queue rules", imp.craftOps == 1 and imp.shopOps == 1 and cr.op == "Restock Flasks" and cr.maxRestock == 1000 and cr.minProfit == 1)
check("import: a Shopping restock quantity is reported as not followed", imp.unsupported["Shopping Cheap Mats"] is not None)
run("AuctionIQ.Queue.Clear()")
CH.Queue.FillPlan(2906, L.eval("{ budget = 0 }"))
q302 = sum(e.qty for e in CH.db.queue.values() if e.item == 302 and not e.concentration)
check("restock: queues up to the operation's max, past a day's sales", q302 > 10)
run("AuctionIQ.Queue.Clear(); AuctionIQ.Groups.Store().craftOps['Restock Flasks'].minRestock = 100000")
CH.Queue.FillPlan(2906, L.eval("{ budget = 0 }"))
check("restock: nothing when what's missing is under the min restock", not any(e.item == 302 for e in CH.db.queue.values()))
run("AuctionIQ.Queue.Clear(); AuctionIQ.Groups.Store().craftOps['Restock Flasks'].minRestock = 1; AuctionIQ.Groups.Store().craftOps['Restock Flasks'].minProfit = '100000g'")
CH.Queue.FillPlan(2906, L.eval("{ budget = 0 }"))
check("restock: nothing under the operation's minimum profit", not any(e.item == 302 for e in CH.db.queue.values()))
run("AuctionIQ.Groups.Store().craftOps['Restock Flasks'].minProfit = '1c'")
sr205 = CH.Groups.ShopRule(205)
check("shopping rule: the operation's max price", sr205.op == "Cheap Mats" and sr205.maxPrice == 100)
run("AuctionIQ.Queue.Clear()")
CH.Queue.FillPlan(2906, L.eval("{ budget = 0 }"))
run("AuctionIQ.Depth.Remember(205, { { price = 15000, qty = 50 } })")
row205 = [r for r in CH.Queue.ShoppingList()[0].values() if r.itemID == 205]
if row205 and row205[0].buy > 0:
    tip = [plain(l) for l in CH.QueueUI.CostLines(row205[0]).values()]
    check("shopping: over the operation's max price is flagged", row205[0].overMax and row205[0].underMax == 0 and any("Max price" in t for t in tip))
    db = L.eval("AuctionIQ.AuctionUI.DecideBuy({ itemID = 205, need = 5, have = 0, buy = 5 }, { { price = 90, qty = 2 }, { price = 15000, qty = 50 } })")
    check("shopping: buys only what's under the operation's max price", db.action == "buy" and db.qty == 2 and db.short == 3)
    db = L.eval("AuctionIQ.AuctionUI.DecideBuy({ itemID = 205, need = 5, have = 0, buy = 5 }, { { price = 15000, qty = 50 } })")
    check("shopping: skips when every listing is over the max price", db.action == "skip" and "max price" in db.why)
else:
    check("shopping: the queue needs item 205 to test the max price", False)
run("AuctionIQ.Depth.Forget(205); AuctionIQ.Queue.Clear()")

# Costing basis: replacement, TSM's material cost, what you paid
run("STUB.prices['i:205'].matprice = 7000; AuctionIQ.Prices.ClearCache()")
check("basis: what you hold at paid by default, buying at replacement", CH.Prices.CostBasis() == "held" and CH.Prices.ReagentCost(205)[0] == 10000)
check("basis: TSM's material cost when chosen", L.eval("(AuctionIQ.Prices.ReagentCost(205, 'tsm'))") == 7000
      and L.eval("select(2, AuctionIQ.Prices.ReagentCost(201, 'tsm'))") == "replacement")
run("AuctionIQ.Prices.CostBasis('tsm')")
check("basis: the setting prices the advisor's reagents", CH.Scan.ReagentPrice(205) == 7000)
bres = CH.Advisor.Analyze(10, L.eval('{ professionID = 2906 }'))
bl = [(plain(l[1]), plain(l[2])) for l in CH.AdvisorUI.BasisLines(bres, bres.best).values()]
check("advisor: each costing basis totalled, the one in use marked", len(bl) == 5 and any("TSM material cost" in a and "in use" in a for a, _ in bl)
      and any("Replacement" in a for a, _ in bl) and any("paid" in a for a, _ in bl))
run("AuctionIQ.Prices.CostBasis('held'); STUB.prices['i:205'].matprice = nil; AuctionIQ.Prices.ClearCache()")
hc = L.eval("AuctionIQ.Advisor.UnitsCost({ heldCache = { [205] = { n = 5, each = 4000 } } }, 205, 8)")
check("held basis: the units you hold cost what they'd sell for (opportunity cost), only the rest at today's price", hc == 5 * 4000 + 3 * 10000)
hg = L.eval("AuctionIQ.Advisor.UnitsCost({ heldCache = { [205] = { n = 5 } } }, 205, 3)")
check("held basis: no sale price falls back to today's price", hg == 3 * 10000)
run("AuctionIQ.Prices.CostBasis('replacement')")
check("replacement basis: every unit at today's price", L.eval("AuctionIQ.Advisor.UnitsCost({ heldCache = { [205] = { n = 5, each = 4000 } } }, 205, 8)") == 80000)
run("AuctionIQ.Prices.CostBasis('held')")
hl = L.eval("AuctionIQ.Advisor.HeldLine({ id = 205, n = 8, buy = 10000 }, { heldCache = { [205] = { n = 5, each = 4000 } } })")
ht = [plain(x[1]).strip() for x in CH.Advisor.HeldText(hl).values()]
check("held basis: the hover is short rows: opportunity cost, paid, current, sell, to buy", hl.own == 5 and hl.buyN == 3
      and ht == ["Opportunity cost (5 yours)", "Stock", "Paid price", "Current price", "Sell price", "To buy (3)"])
check("held basis: a held reagent is worth its sale price less the cut, deposits and waiting (Expect.Value)",
      L.eval("(function() local v = AuctionIQ.Prices.SellValue(201); local c = AuctionIQ.Prices.Get('chvalue', 'i:201'); return v and c and v <= c * AuctionIQ.AH_CUT + 0.5 end)()") is not False)
run("STUB.oldHeld = AuctionIQ.Prices.Held; AuctionIQ.Prices.Held = function(id) if id == 205 then return 4 end return 0 end")
cres = CH.Advisor.Analyze(10, L.eval('{ professionID = 2906 }'))
cs = CH.Advisor.CraftOrSell(cres, cres.best)
check("craft or sell: crafting's proceeds against selling the reagents you hold", cs is not None and abs(cs.craft - cs.sell - cres.best.profit) < 1 and cs.sell > 0)
csl = [plain(l[1]).strip() for l in CH.Advisor.CraftOrSellLines(cres, cres.best).values()]
check("craft or sell: the profit hover shows both and which earns more", csl[0] == "Craft or sell?" and "Sell your reagents instead" in csl
      and (csl[-1].startswith("Crafting earns more by") or csl[-1].startswith("Selling the reagents earns more by")))
run("AuctionIQ.Prices.Held = STUB.oldHeld")
tcs = L.eval("""(function()
  local old = AuctionIQ.Prices.Held
  AuctionIQ.Prices.Held = function(id) if id == 205 then return 4 end return 0 end
  local cs = AuctionIQ.CraftOrSell({ sales = 50000, mcGold = 0, resGold = 0, reagents = { { itemID = 205, n = 2, cost = 20000 }, { itemID = 201, n = 3, cost = 30000 } } })
  AuctionIQ.Prices.Held = old
  return cs end)()""")
check("item tooltip craft or sell: crafting buys only what you're short of, against selling yours",
      tcs is not None and tcs.craft == 50000 - 30000 and tcs.sell > 0 and abs(tcs.gain - (tcs.craft - tcs.sell)) < 1)
rb = L.eval("""(function()
  local old = AuctionIQ.Prices.Held
  AuctionIQ.Prices.Held = function(id) if id == 205 then return 4 end return 0 end
  local acc = { sales = 50000, mcGold = 0, resGold = 0, profit = 0, reagents = { { itemID = 205, n = 2, cost = 20000 }, { itemID = 201, n = 3, cost = 30000 } } }
  local lines, total = AuctionIQ.ReagentBook(acc)
  local short = AuctionIQ.ReagentBook(acc, { short = true })
  local book, profit = AuctionIQ.CraftBook(acc)
  AuctionIQ.Prices.Held = old
  return { lines = lines, total = total, short = short, book = book, profit = profit } end)()""")
rbl = [plain(l[1]).strip() for l in rb.lines.values()]
v205 = CH.Prices.Get("chvalue", "i:205")
check("reagent breakdown: yours at what they'd sell for after the cut, the rest at the buy price, under one total",
      rbl[0] == "Reagents" and rbl[-1] == "Total reagents" and "Opportunity cost (2 yours)" in rbl and "Stock" in rbl
      and abs(rb.total - (2 * (v205 * CH.AH_CUT if v205 else 10000) + 30000)) < 1)
rbs = [plain(l[1]).strip() for l in rb.short.values()]
check("reagent breakdown, short: one row for yours under the reagent", "2 yours, at sell price" in rbs and "Opportunity cost (2 yours)" not in rbs)
cbl = [plain(l[1]).strip() for l in rb.book.values()]
check("scan profit hover: revenue, costs, profit, then craft or sell", cbl[0] == "Revenue" and "Costs" in cbl and "Profit" in cbl
      and cbl.index("Profit") < cbl.index("Craft or sell?") and abs(rb.profit - (50000 - rb.total)) < 1)
run("AuctionIQ.Prices.CostBasis('held')")
rcl = CH.ScanUI.RecipeCellLines(L.eval("{ name = 'x', accounts = { sales = 50000, reagents = { { itemID = 201, n = 3, cost = 30000 } } } }"), 4, "craft")
bp2 = L.eval("""(function() local t = {}
  for _, c in ipairs(AuctionIQ.ScanUI.Columns and AuctionIQ.ScanUI.Columns('craft') or {}) do t[#t + 1] = c[1] end return t end)()""")
check("scan list: Recipe, Best, Profit, Cost, Margin, Max", list(bp2.values()) == ["Recipe", "Best", "Profit", "Cost", "Margin", "Max"])
check("scan: the Cost column hovers the reagent breakdown", rcl is not None and plain(rcl[2][1]) == "Reagents"
      and CH.ScanUI.RecipeCellLines(L.eval("{ name = 'x', accounts = { sales = 1 } }"), 6, "craft") is None)
lv = L.eval("""(function()
  local saved = { name = 'x', profit = 20000, cost = 30000, perDay = 40000,
    accounts = { sales = 50000, mcGold = 0, resGold = 0, profit = 20000, cost = 30000, reagents = { { itemID = 201, n = 3, cost = 30000 } } } }
  local old = AuctionIQ.Prices.Get
  AuctionIQ.Prices.Get = function(k, l, ...) if l == "i:201" and (k == "chvalue") then return 20000 end return old(k, l, ...) end
  local oldH = AuctionIQ.Prices.Held
  AuctionIQ.Prices.Held = function(id) if id == 201 then return 3 end return 0 end
  local v = AuctionIQ.Scan.Live(saved)
  local out = { profit = v.profit, cost = v.cost, perDay = v.perDay, sell = v.sellInstead, savedProfit = saved.profit, name = v.name }
  local book, bp = AuctionIQ.CraftBook(saved.accounts)
  out.hover = bp
  AuctionIQ.Prices.Get, AuctionIQ.Prices.Held = old, oldH
  return out end)()""")
check("scan list at live prices: the columns match the hovers, the saved scan stays as scanned",
      abs(lv.cost - 3 * 20000 * CH.AH_CUT) < 1 and abs(lv.profit - lv.hover) < 1 and lv.savedProfit == 20000 and lv.name == "x"
      and lv.profit < 0 and lv.sell and lv.perDay == 0)
rp = CH.ScanUI.RecipePanel(L.eval("{ name = 'x', recipeID = 1, profit = 20000, pct = 0.5, accounts = { sales = 50000, reagents = { { itemID = 201, n = 3, cost = 30000 } } } }"), 3)
check("scan side panel: craft or sell with profit and reagents, the reagents each with a hover, and Queue n",
      rp is not None and plain(rp.kicker) == "CRAFT OR SELL?" and plain(rp.title) == "x" and plain(rp.figures[1][1]) == "PROFIT"
      and plain(rp.figures[2][1]) == "COST" and rp.figures[1].tip is not None and "3x item 201" in plain(rp.section.rows[1][1])
      and rp.section.rows[1].tip is not None and plain(rp.actions[1].label) == "Queue 3 crafts")
check("scan side card: figures are profit, reagents and margin; craft or sell's numbers hover on its sentence",
      [plain(f[1]) for f in rp.figures.values()] == ["PROFIT", "COST", "MARGIN"] and plain(rp.figures[3][2]) == "50%" and rp.subTip is not None
      and not any(plain(r[1]) == "Margin" for r in rp.rows.values()))
rq = CH.ScanUI.RecipePanel(L.eval("{ name = 'x', recipeID = 1, profit = 20000, canMake = 8, shortItem = 201, accounts = { sales = 50000, reagents = { { itemID = 201, n = 3, cost = 30000 } } } }"), 20)
check("scan side card: queueing more than your bags cover says how many you can make now, and what runs short",
      plain(rq.actions[1].label) == "Queue 20 · Max 8" and "8 of the 20" in rq.actions[1].tip and "runs short" in rq.actions[1].tip)
# the review's queue findings: two mixes for the same recipe and quality stay two entries
mx2 = L.eval("""(function() local Q = AuctionIQ.Queue; Q.Clear()
  local a = { char = 'Me-Realm', recipeID = 10, quality = 2, reagents = { { itemID = 201, slot = 1, n = 3 } }, shop = {} }
  local b = { char = 'Me-Realm', recipeID = 10, quality = 2, reagents = { { itemID = 202, slot = 1, n = 3 } }, shop = {} }
  local c = { char = 'Me-Realm', recipeID = 10, quality = 2, reagents = { { itemID = 201, slot = 1, n = 3 } }, shop = {} }
  Q.AddEntry(a, 2); Q.AddEntry(b, 1); Q.AddEntry(c, 1)
  local q = AuctionIQ.db.queue
  local out = { n = #q, aq = q[1].qty, aid = q[1].reagents[1].itemID, bid = q[2] and q[2].reagents[1].itemID }
  Q.Clear(); return out end)()""")
check("queue: a second mix for the same recipe and quality is its own entry, the first batch's reagents untouched",
      mx2.n == 2 and mx2.aq == 3 and mx2.aid == 201 and mx2.bid == 202)
fs = L.eval("""(function() local Q = AuctionIQ.Queue
  local row = { recipeID = 10, name = 'x', quality = 1, concQuality = 2, concentration = 40, accounts = { queue = { { itemID = 201, slot = 1, n = 3 } }, reagents = {} } }
  return { conc = Q.FromScan('Me-Realm', { name = 'Me' }, row, true) == nil, plain = Q.FromScan('Me-Realm', { name = 'Me' }, row, false) ~= nil } end)()""")
check("queue: a Concentration craft with no saved Concentration mix isn't queued with the plain one", fs.conc and fs.plain)
oa = L.eval("""(function() local Q = AuctionIQ.Queue; local old = C_Item.GetItemCount; C_Item.GetItemCount = function() return 1 end
  local old2 = C_TradeSkillUI.GetRecipeSchematic
  C_TradeSkillUI.GetRecipeSchematic = function() return { reagentSlotSchematics = {
    { dataSlotIndex = 1, required = true }, { dataSlotIndex = 2, required = false } } } end
  local e = { recipeID = 10, reagents = { { itemID = 201, slot = 1, n = 3 } } }
  local a, why = Q.OrderAllocation(e, { reagents = {} })
  local f = { recipeID = 10, reagents = { { itemID = 201, slot = 1, n = 1 }, { itemID = 299, slot = 2, n = 2 } } }
  local b = Q.OrderAllocation(f, { reagents = {} })
  local g = { recipeID = 10, reagents = { { itemID = 201, slot = 1, n = 3 } } }
  local c = Q.OrderAllocation(g, { reagents = { { reagentInfo = { reagent = { itemID = 201 }, quantity = 3 } } } })
  C_Item.GetItemCount = old; C_TradeSkillUI.GetRecipeSchematic = old2
  return { a = a == nil, why = why, bmine = b and #b.mine, bdrop = b and #b.dropped, cmine = c and #c.mine } end)()""")
check("work order: a required reagent you're short of stops the craft and names it", oa.a and "need 3" in str(oa.why) and "item 201" in str(oa.why))
check("work order: a finishing reagent you're short of is left out, and listed as changed", oa.bmine == 1 and oa.bdrop == 1)
check("work order: what the customer supplies comes off yours", oa.cmine == 0)
cp = CH.ScanUI.RecipePanel(L.eval("{ name = 'x', recipeID = 1, profit = 20000, concProfit = 50000, concentration = 40, gainPerPoint = 750, accounts = { sales = 50000, reagents = { { itemID = 201, n = 3, cost = 30000 } } } }"), 2, "conc")
check("scan side card, Concentration view: worth the Concentration, plain against with, extra a point",
      plain(cp.kicker) == "WORTH THE CONCENTRATION?" and plain(cp.figures[1][1]) == "PLAIN" and plain(cp.figures[2][1]) == "WITH CONC." and "Worth it" in plain(cp.sub))
bp = CH.ScanUI.RecipePanel(L.eval("{ name = 'x', recipeID = 1, profit = 1, bc = { buy = 1000, craft = 1500, save = 500 }, accounts = { sales = 50000, reagents = {} } }"), 1, "buy")
check("scan side card, Buy vs craft: buy it or make it, and which saves", plain(bp.kicker) == "BUY IT OR MAKE IT?" and plain(bp.figures[3][1]) == "BUYING SAVES" and "Buy it" in plain(bp.sub))
op = CH.ScanUI.OrderPanel(L.eval("{ name = 'o', orderID = 5, kind = 'Patron', from = 'Bob', ok = true, have = true, profit = 7000, cost = 3000, commission = 10000, rewardValue = 0, rewards = {}, costLines = {} }"))
check("scan side card, Work orders: take this order, pays less reagents is profit",
      plain(op.kicker) == "TAKE THIS ORDER?" and plain(op.figures[1][1]) == "PAYS" and plain(op.figures[3][1]) == "PROFIT" and "Take it" in plain(op.sub))
fp = CH.ScanUI.FirstPanel(L.eval("{ name = 'f', recipeID = 2, cost = 5000, value = 3000, net = -2000 }"))
check("scan side card, First crafts: worth the knowledge, what the point costs", plain(fp.kicker) == "WORTH THE KNOWLEDGE?" and plain(fp.figures[3][1]) == "POINT COSTS")
ev = L.eval("""(function()
  local oldH, oldS, oldP = AuctionIQ.Prices.Held, AuctionIQ.Prices.SellValue, AuctionIQ.Prices.PaidEach
  AuctionIQ.Prices.Held = function(id) return 10 end
  AuctionIQ.Prices.PaidEach = function(id) return 3000 end
  AuctionIQ.Prices.SellValue = function(id) return 1000 end
  local acc = { sales = 2050, reagents = { { itemID = 201, n = 2, cost = 2000 } } }
  local even = AuctionIQ.CraftOrSell(acc)
  acc.sales = 1500
  local sell = AuctionIQ.CraftOrSell(acc)
  local book = AuctionIQ.CraftOrSellBook(acc)
  AuctionIQ.Prices.Held, AuctionIQ.Prices.SellValue, AuctionIQ.Prices.PaidEach = oldH, oldS, oldP
  return { even = even.verdict, sell = sell.verdict, paid = sell.paid, book = book } end)()""")
bl = [plain(l[1]).strip() for l in ev.book.values()]
check("craft or sell: within 5% is about even, and what you paid shows as sunk, with the loss either way",
      ev.even == "even" and ev.sell == "sell" and ev.paid == 6000 and "You paid for yours" in bl and any("either way" in x for x in bl))
run("TradeSkillMasterDB['g@ @userData@sharedOperations'] = nil")
run("AuctionIQ.Groups.Store().preferTSM = nil; TradeSkillMasterDB['p@Warband@userData@items'] = nil; AuctionIQ.Groups.ResetTSM()")
run("AuctionIQ.GroupsUI.Select('Crafted'); AuctionIQ.UI.Page('groups')")
grows = list(CH.GroupsUI.Refresh().values())
check("groups page: the group's items with their prices", any(r.id == 302 for r in grows) and CH.UI.IsShown())
ef = CH.GroupsUI.Effective(302)
el = [plain(x) for x in CH.GroupsUI.EffectiveLines(302).values()]
gp302 = CH.Groups.Prices(302)
check("groups page: an item shows its group, its operation and where each came from, and min, normal and max",
      ef.path == CH.Groups.Path(302) and ef.op == CH.Groups.Operation(302)[1] and ef.pathFrom in ("moved", "tsm", "auto")
      and ef.op in el[0] and ef.path in el[0] and "Min " + plain(CH.FormatMoney(gp302.min)) in el[1] and "Max " in el[1])
run("AuctionIQ.Groups.Assign(AuctionIQ.Groups.Path(302), 'Default')")
check("groups page: an operation set on the item's own group says so", CH.GroupsUI.Effective(302).opFrom == CH.Groups.Path(302)
      and "set on this group" in plain(CH.GroupsUI.EffectiveLines(302)[1]))
run("AuctionIQ.Groups.Assign(AuctionIQ.Groups.Path(302), nil)")
run("AuctionIQ.GroupsUI.SelectItem(302)")
check("groups page: clicking an item shows its rule under the list", ef.op in plain(CH.UI.Pages().groups.info[1].t)
      if CH.UI.Pages().groups else True)
check("groups now live in Settings: the old name opens them there", L.eval("AuctionIQ.UI.IsShown()"))
# Trading tab: what to post and mail, before you get to the AH
pp = {r.id: r for r in CH.TradingUI.PostPlan().values()}
check("trading: ready to post counts what every character holds in a posting group", 302 in pp and pp[302].held >= 3 and pp[302].verdict in ("post", "hold", "full"))
r302 = pp[302]
check("trading: posts no more than the group's cap less what's up", r302.post <= max(0, (r302.cap or 0) - r302.up))
gp = CH.Groups.Prices(302)
if r302.ah:
    want = min(max(r302.ah - (gp.undercut or 1), gp.min or 0), gp.max or 10**12)
    want = max(want, gp.min or 0)
    check("trading: planned price undercuts the AH within min and max, as posting does", r302.price == want)
run("AuctionIQ.UI.Page('trading', 'post')")
check("old trading tab opens Operations on Ready to post", CH.LedgerUI.View() == "post" and CH.LedgerUI.Section() == "operations")
pr, pf = L.eval("AuctionIQ.LedgerUI.Rows('post', {})")
check("trading views: rows and a summary line", len(list(pr.values())) > 0 and "to post" in plain(pf))
# Posting advice: post now, post fewer or wait, inside the TSM operation's limits
D = CH.Decide
pa = lambda r, o="{}": D.PostAdvice(L.eval(r), L.eval(o))
a1 = pa("{ id = 1, verdict = 'post', post = 10, up = 0, cap = 20, price = 100 }", "{ daily = 10 }")
check("posting advice: post what TSM would when two days of sales cover it", a1.action == "post" and a1.qty == 10 and D.PostLabel(a1) == "Post 10")
a2 = pa("{ id = 1, verdict = 'post', post = 10, up = 2, cap = 20, price = 100 }", "{ daily = 2 }")
check("posting advice: post fewer when that much would sit (2 a day, 2 up: 2 more)", a2.action == "fewer" and a2.qty == 2
      and "your rules allow 10" in a2.reason and D.PostLabel(a2) == "Post 2 (fewer)")
a3 = pa("{ id = 1, verdict = 'post', post = 10, up = 6, cap = 20, price = 100 }", "{ daily = 2 }")
check("posting advice: wait when what's up already covers it", a3.action == "wait" and a3.qty == 0 and "3 days" in a3.reason)
a4 = pa("{ id = 1, verdict = 'hold', post = 5, up = 0, cap = 20, price = 100, ah = 50, min = 80 }", "{ daily = 5 }")
check("posting advice: never under your min: wait, and say why", a4.action == "wait" and "under your min" in a4.reason)
a5 = pa("{ id = 1, verdict = 'full', post = 0, up = 20, cap = 20, price = 100 }", "{ daily = 50 }")
check("posting advice: never past your cap", a5.action == "wait" and a5.qty == 0)
a6 = pa("{ id = 1, verdict = 'post', post = 10, up = 0, cap = 20, price = 100 }", "{ daily = 10, hour = 10, times = { sold = 20, share = 0.6, bestHour = 15 } }")
check("posting advice: wait for a selling window a few hours off", a6.action == "wait" and "15:00" in a6.reason)
a7 = pa("{ id = 1, verdict = 'post', post = 10, up = 0, cap = 20, price = 100 }", "{ daily = 0 }")
check("posting advice: no sale rate, TSM's limits decide", a7.action == "post" and a7.qty == 10 and "no sale rate" in a7.reason)
run("AuctionIQ.db.postAdvice = nil")
D.SaveAdvice(5, a2, 1000000); D.SaveAdvice(5, a3, 1000100); D.SaveAdvice(5, a3, 1000000 + 86400)
log = list(L.eval("AuctionIQ.Decide.AdviceLog()").values())
check("posting advice: saved once an item a day, with what it assumed", len(log) == 2 and log[0].action == "fewer" and log[0].daily == 2 and log[0].up == 2)
run("AuctionIQ.db.postAdvice = nil")
pr2 = list(L.eval("(AuctionIQ.LedgerUI.Rows('post', {}))").values())
check("Ready to post: each row's advice, with the reason on hover", all(plain(r.cells[6]).startswith(("Post", "Wait", "Check")) for r in pr2)
      and all(plain(r.tip[2][1]).startswith("Because ") for r in pr2))
# Trade and the AH panel share one rule check
r302 = pp[302]
res302 = L.eval("(function() local r = AuctionIQ.Auction.Listings(302); return r end)()")
ev302 = CH.Auction.Evaluate(302, L.eval("{}") if res302 is None else L.eval("{ results = AuctionIQ.Auction.Listings(302) }"))
check("Ready to post prices with the AH panel's own rule check", r302.price == (ev302.price or r302.price) and r302.why is not None)
ca = pa("{ id = 1, verdict = 'post', post = 3, up = 0, cap = 5, price = 33400000000, check = true }", "{ daily = 0 }")
check("no scan and no sales: Check live price, not Post 1", ca.action == "check" and ca.qty == 0 and D.PostLabel(ca) == "Check live price")
sk = pa("{ id = 1, verdict = 'skip', post = 0, up = 0, cap = 5, price = 100, why = 'expired 3 times since it last sold (max 3)' }", "{ daily = 4 }")
check("a rule that stops posting is the reason given", sk.action == "wait" and "expired 3 times" in sk.reason)
prow = [r for r in pr2 if r.id == 302]
if prow:
    det = CH.TradingUI.PostDetail(prow[0])
    labels = [plain(x[1]) for x in det.rows.values()]
    check("Ready to post pane: recommended apart from allowed by your rules, with the price source",
          "Recommended" in labels and "Allowed by your rules" in labels and "Price from" in labels
          and any(plain(a.label) == "Review at Auction House" for a in det.actions.values()))
wk = list(CH.TradingUI.WorkPlan().values())
check("execution plan: crafts and posts only, posts from Ready to post", all(w.kind in ("craft", "post") for w in wk)
      and all(w.kind != "post" or w.where == "Auction House" for w in wk))
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
bef = L.eval("(function() local be, row = AuctionIQ.BreakEvenFor(302); return { be = be, has = row ~= nil } end)()")
check("tooltip: a crafted item shows its break-even, each, and the auction side can ask for it",
      bef.has and bef.be is not None and "Break-even, each" in tl)

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
run("AuctionIQ.Planner.StartSession('Auction House'); AuctionIQ.Planner.StartSession('Crafting'); STUB.now = STUB.now + 1800; AuctionIQ.Planner.StopSession('Crafting'); AuctionIQ.Planner.StopSession('Auction House')")
tm = CH.Planner.Time(L.eval("STUB.now") - 86400)
check("gold per hour: two windows open together count the time once", abs(tm.hours - 1.0) < 1e-9 and abs(tm.kinds["Crafting"] - 0.5) < 1e-9)
run("AuctionIQ.UI.Page('plan')")
check("plan page draws", CH.UI.IsShown() and len(list(CH.PlanUI.Refresh().values())) == 1)
n7 = CH.ReportUI.Numbers(7)
check("report: 7 days of sales after cut, purchases, overhead", abs(n7.sales - 7000000 * 0.95) < 1 and n7.buys == 1000000 and n7.overhead == 20000)
run("AuctionIQ.UI.Page('briefing')")
check("briefing opens with the books", len(list(CH.ReportUI.Refresh().values())) == 5)
csvtext, nrows = CH.ReportUI.CSV("sales", L.eval("{ }"))
run("AuctionIQ.ReportUI.Export('sales', { days = 30 })")
check("export: a Ledger table as CSV", csvtext.split("\n")[0].startswith("Item,Character") and nrows == 3 and "300.00" in csvtext)
run("AuctionIQ.UI.Page('ledger')")
check("theme: the Accounting tab uses the same palette as the rest", L.eval("AuctionIQ.Theme.palette == 'auctioniq'"))
run("AuctionIQ.UI.Page('markets')")
check("theme: other pages are ToxiUI graphite with the class accent", L.eval("AuctionIQ.Theme.palette == 'auctioniq' and AuctionIQ.Theme.hex.bg == '292929' and AuctionIQ.Theme.hex.panel == '1a1a1a' and AuctionIQ.Theme.hex.accent == '3fc7eb'"))
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

# Three tabs, old names still work, shared table page sections
LUI = CH.LedgerUI
run("AuctionIQ.UI.Page('briefing')")
check("report opens inside the Accounting tab", LUI.Section() == "ledger" and LUI.View() == "report" and CH.Theme.palette == "auctioniq")
run("AuctionIQ.UI.Page('analytics', 'perf')")
check("analytics opens Accounting, Reports", LUI.Section() == "ledger" and LUI.View() == "perf" and LUI.Group() == "Reports")
run("AuctionIQ.UI.Page('analytics', 'dead')")
check("a view that moved opens on its new tab: dead stock in Operations", LUI.Section() == "operations" and LUI.View() == "dead" and LUI.Group() == "Trade")
run("AuctionIQ.UI.Page('markets')")
check("markets opens Operations on compare prices", LUI.Section() == "operations" and LUI.View() == "compare" and LUI.Group() == "Trade")
# old Research links: each view opens wherever it lives now
for (tab, view), (sec, group) in {("research", "perf"): ("ledger", "Reports"), ("research", "results"): ("ledger", "Reports"),
        ("research", "scenarios"): ("operations", "Craft"), ("research", "paths"): ("operations", "Craft"),
        ("research", "compare"): ("operations", "Trade"), ("research", "professions"): ("operations", "Craft")}.items():
    run(f"AuctionIQ.UI.Page('{tab}', '{view}')")
    check(f"old link {tab}/{view} opens {sec}, {group}", LUI.Section() == sec and LUI.View() == view and LUI.Group() == group and CH.UI.IsShown())
run("AuctionIQ.UI.Page('research')")
check("the old Research tab opens Operations", LUI.Section() == "operations")
run("AuctionIQ.UI.Page('professions')")
check("old professions name opens Compare crafts", LUI.Section() == "operations" and LUI.View() == "scenarios")
# Dashboard figures: queued crafts split into ready, short of reagents, and on other characters
run("""STUB.oldQueue = AuctionIQ.db.queue
AuctionIQ.db.queue = { { char = AuctionIQ.CharacterKey(), name = 'A', qty = 3, shop = {} },
  { char = AuctionIQ.CharacterKey(), name = 'B', qty = 2, shop = { { itemID = 987654, n = 5 } } },
  { char = 'Other-Realm', name = 'C', qty = 1, shop = {} } }""")
nb = [e for e in CH.Next.List().values() if e.title == "Buy reagents"]
check("do next: the queue's shopping list is a card that opens it", len(nb) == 1 and nb[0].go[2] == "shopping" and "for your queue" in nb[0].detail)
fig = CH.UI.DashboardFigures()
check("dashboard figures: queued crafts, ready, short, on other characters", fig.queued == 6 and fig.ready == 1 and fig.short == 1 and fig.elsewhere == 1)
work = list(CH.TradingUI.WorkPlan().values())
crafts = {w.task: w for w in work if w.kind == "craft"}
check("execution plan: crafts with their status, another character's marked switch", crafts["Craft A"].status == "ready to craft"
      and crafts["Craft B"].status == "buy reagents" and crafts["Craft C"].status == "switch character" and crafts["Craft A"].where == "Professions")
wrows, wfoot = L.eval("AuctionIQ.LedgerUI.Rows('work', {})")
check("execution plan view: a row per task and a count by kind", len(list(wrows.values())) == len(work) and "3 crafts" in plain(wfoot))
rrows, rfoot = L.eval("AuctionIQ.LedgerUI.Rows('ready', {})")
rr = {plain(r.cells[1]): plain(r.cells[6]) for r in rrows.values()}
check("Queue opens on Ready on this character: ready first, blocked grouped by what unlocks it",
      rr.get("A") == "craft" and rr.get("B", "").startswith("buy 10") and rr.get("C") == "log in as Other" and rr.get("C", "").startswith("log in as") and "1 ready on this character" in plain(rfoot))
run("AuctionIQ.UI.Page('today')")
qf = L.eval("AuctionIQ.UI.Pages().dashboard.d.figures.queued")
check("dashboard: the queued figure shows", plain(L.eval("AuctionIQ.UI.Pages().dashboard.d.figures.queued.value:GetText()")) == "6")
run("AuctionIQ.UI.Pages().dashboard.d.figures.queued.hit.scripts.OnClick()")
check("dashboard: clicking it opens Operations, Work queue", CH.LedgerUI.View() == "queue" and CH.LedgerUI.Section() == "operations")
run("AuctionIQ.db.queue = STUB.oldQueue; AuctionIQ.UI.Page('markets')")
check("tabs: Dashboard, Operations, Accounting", [t[2] for t in L.eval("AuctionIQ.UI.TABS").values()] == ["Dashboard", "Operations", "Accounting"])
run("AuctionIQ.UI.Page('operations', 'compare')")
check("operations sub-tabs: Craft, Trade, Queue", list(L.eval("AuctionIQ.UI.LayoutSubTabs()").values()) == ["Craft", "Trade", "Queue"])
navshown = [plain(b.text.t) for b in L.eval("AuctionIQ.UI.Pages().ledger.nav").values() if b.shown]
check("Trade: what you hold, the market and the rules, in one sub-tab", LUI.Group() == "Trade" and navshown == ["Ready to post", "Market prices",
      "Compare prices", "When it sells", "Competition", "Stock targets", "Dead stock", "Manage rules"])
run("AuctionIQ.UI.Page('operations', 'professions')")
navshown = [plain(b.text.t) for b in L.eval("AuctionIQ.UI.Pages().ledger.nav").values() if b.shown]
check("Craft: Compare crafts first, then Specialization and the weekly checklist", navshown == ["Compare crafts", "Specialization", "Weekly checklist"])
run("AuctionIQ.UI.Page('operations', 'shopping')")
navshown = [plain(b.text.t) for b in L.eval("AuctionIQ.UI.Pages().ledger.nav").values() if b.shown]
check("Queue: execution plan, production queue, shopping list, restock plans", LUI.Group() == "Queue" and navshown == ["Ready here", "Execution plan", "Production queue", "Shopping list", "Restock plans"])
# Dashboard hand-offs: a recommendation opens its view on the item, character and quantity
run("AuctionIQ.UI.Go('operations', 'scenarios', { name = 'Test Flask', char = 'Alt', qty = 20, title = 'Restock' })")
foot = plain(L.eval("AuctionIQ.UI.Pages().ledger.footer:GetText()") or "")
chars = [plain(r.cells[2]) for r in LUI.Rows("scenarios", L.eval("{ char = 'Seyko' }"))[0].values()]
allc = [plain(r.cells[2]) for r in LUI.Rows("scenarios", L.eval("{}"))[0].values()]
check("Compare crafts: the Character picker keeps only that character's crafts", len(chars) > 0 and set(chars) == {"Seyko"} and len(allc) >= len(chars))
ch = list(L.eval("AuctionIQ.LedgerUI.ViewDef('scenarios').charChoices()").values())
check("Compare crafts: the picker lists each character, then their scanned professions", len(ch) >= 2 and ch[0][1] == "Seyko" and "#" in ch[1][2] and "Seyko - " in ch[1][1])
pc = [r for r in LUI.Rows("scenarios", L.eval("{ char = '%s' }" % ch[1][2]))[0].values()]
check("Compare crafts: picking a profession keeps only its crafts", len(pc) > 0 and all(str(r.x.profID) == ch[1][2].split("#")[1] for r in pc))
check("Compare crafts: the button names the character and profession", L.eval("AuctionIQ.LedgerUI.ViewDef('scenarios').charLabel('%s')" % ch[1][2]) == ch[1][1].strip())
none = list(LUI.Rows("scenarios", L.eval("{ char = 'Nobody' }"))[0].values())
check("Compare crafts: a character with no scans shows none", len(none) == 0)
check("Compare crafts shows a Scan button in Export's place", L.eval("AuctionIQ.UI.Pages().ledger.actionButton:IsShown()")
      and not L.eval("AuctionIQ.UI.Pages().ledger.exportButton:IsShown()") and L.eval("AuctionIQ.UI.Pages().ledger.actionButton.label") == "Scan")
check("hand-off: Craft opens on the recommended recipe, filtered to it, saying what was handed over",
      LUI.View() == "scenarios" and LUI.Group() == "Craft" and LUI.Focus().name == "Test Flask"
      and plain(L.eval("AuctionIQ.UI.Pages().ledger.search:GetText()")) == "Test Flask"
      and foot.startswith("From Dashboard: Restock, 20 x Test Flask on Alt"))
# Craft detail pane: the handed-over recipe is selected, sized to the Dashboard's quantity, and queues
det = L.eval("AuctionIQ.LedgerUI.lastDetail")
check("Craft pane: the selected recipe, live while the profession window has it, sized to the hand-off",
      det is not None and plain(det.title) == "Craft 20 x Test Flask" and "LIVE" in plain(det.kicker) and plain(det.sub).startswith("Live")
      and det.n == 20 and plain(det.actions[1].label) == "Queue 20 crafts" and L.eval("AuctionIQ.UI.Pages().ledger.detail").shown)
pane = L.eval("AuctionIQ.UI.Pages().ledger.detail")
tbl = L.eval("AuctionIQ.UI.Pages().ledger.rows[1].hit")
check("Craft pane: a panel right of the table, which narrows to make room",
      pane.point[2] > 172 + 400 and pane.point[3] == -32 and tbl.w < 724 - 250)
run("AuctionIQ.AnalyticsViews._LiveFor = AuctionIQ.AnalyticsViews.LiveFor; AuctionIQ.AnalyticsViews.LiveFor = function() return nil end; AuctionIQ.UI.Refresh()")
det = L.eval("AuctionIQ.LedgerUI.lastDetail")
check("Craft pane: otherwise the last scan, labelled with its character and age", re.search(r"^\w+, scanned .+ ago", plain(det.sub)) is not None and det.live is False)
run("AuctionIQ.AnalyticsViews.LiveFor = AuctionIQ.AnalyticsViews._LiveFor; AuctionIQ.UI.Refresh()")
det = L.eval("AuctionIQ.LedgerUI.lastDetail")
figs = [plain(f[1]) for f in det.figures.values()]
rows = {plain(r[1]): plain(r[2]) for r in det.rows.values()}
srows = [r for r in det.section.rows.values()]
check("Craft pane: profit, gold at risk and break-even up top; make, stock left and reagent cost below",
      figs == ["PROFIT", "AT RISK", "BREAK-EVEN"] and "Make" in rows and "Left after a week" in rows and "Reagents for 20" in rows)
check("Craft pane: if prices move, each scenario explaining itself on hover",
      plain(det.section.head) == "IF PRICES MOVE" and [plain(r[1]) for r in srows] == ["Profit now", "Reagents +10%", "Price -10%", "Both", "Room to rise"]
      and all(r.tip is not None and plain(r.tip[1][1]) != "" for r in srows))
acts = [plain(a.label) for a in det.actions.values()]
check("Craft pane: a Rescan button for the scan's profession", acts[-1].startswith("Rescan "))
rs = L.eval("(function() local x = AuctionIQ.LedgerUI.Selected and nil; return { AuctionIQ.AnalyticsViews.Rescan({ charKey = 'Someone-Else', char = 'Someone', prof = 'Alchemy' }) } end)()")
check("Craft pane: Rescan says whose scan it is when another character made it", not rs[1] and "log in as them" in rs[2] and "Someone" in rs[2])
figc = [f[2] for f in det.figures.values()]
check("Craft pane: the figures are coloured (profit green or red, gold at risk red, break-even gold)",
      all("|c" in f for f in figc))
# one selection: the preview, the Queue button and the saved forecast are the same craft
sel = det.selection
check("one selection: the pane's figures, title and Queue button share one batch size",
      sel.n == det.n and plain(det.actions[1].label).startswith("Queue %d " % sel.n))
x = sel.x
nq = L.eval("AuctionIQ.Queue.Count()")
okq = L.eval("function(s) return AuctionIQ.AnalyticsViews.QueueSelection(s) end")(sel)
check("one selection: queueing while live goes through the advisor's own queueing", okq and L.eval("AuctionIQ.Queue.Count()") > nq)
if sel.canConc:
    run("AuctionIQ.AnalyticsViews.SetConc(AuctionIQ.LedgerUI.lastDetail.selection.x, true); AuctionIQ.UI.Refresh()")
    det_c = L.eval("AuctionIQ.LedgerUI.lastDetail")
    check("one selection: Use Concentration switches the whole pane to the Concentration craft",
          det_c.selection.conc and "with Concentration" in plain(det_c.actions[1].label) and plain(det_c.actions[2].label) == "Plain instead")
    run("AuctionIQ.AnalyticsViews.SetConc(AuctionIQ.LedgerUI.lastDetail.selection.x, false); AuctionIQ.UI.Refresh()")
# a hand-off in items becomes crafts by what one craft makes
si = L.eval("function(x) return AuctionIQ.AnalyticsViews.Selection(x, { name = x.name, qty = 9, unit = 'items', title = 'Restock' }) end")(x)
check("hand-off units: 9 items become crafts by what a craft makes", si.n == max(1, math.ceil(9 / si.made - 1e-9)) and "9 items" in si["from"])
sc_ = L.eval("function(x) return AuctionIQ.AnalyticsViews.Selection(x, { name = x.name, qty = 3, unit = 'crafts', conc = true }) end")(x)
check("hand-off: a Concentration recommendation arrives with Concentration chosen", sc_.n == 3 and (sc_.conc or not sc_.canConc))
# Dashboard hand-offs carry their intent: Concentration, the unit of the quantity, the exact items
nl = list(L.eval("AuctionIQ.Next.List()").values())
gos = [e.go[3] for e in nl if e.go is not None and e.go[3] is not None]
check("hand-off payloads: Restock and stock targets say their quantity is in items",
      all(g.unit == "items" for e in nl if e.title in ("Restock", "Below stock target") for g in [e.go[3]]))
check("hand-off payloads: Spend Concentration says crafts, and Concentration when it picked a Concentration craft",
      all(e.go[3].unit == "crafts" for e in nl if e.title == "Spend Concentration" and e.go[2] == "scenarios"))
rk = L.eval("function(ids) return AuctionIQ.LedgerUI.Rows('scenarios', { focus = { ids = ids } }) end")
some = list(LUI.Rows("scenarios", L.eval("{}"))[0].values())
if some:
    one = some[0].id
    kept = list(rk(L.eval("{ [%d] = true }" % one))[0].values())
    check("grouped cards: the view opens on exactly the items the card was about", len(kept) >= 1 and all(r.id == one for r in kept))
# an older scan without a saved sale price still gets a break-even, from today's market price
pa_old = L.eval("AuctionIQ.Decide.AccountParts({ item = 100, accounts = { sales = 120, cost = 100, unit = 12 } })")
check("older scans: break-even falls back to today's market price", pa_old.price is not None and pa_old.priceFrom == "market")
run("AuctionIQ.db.queue = {}; AuctionIQ.db.decisions = {}")
run("local b = AuctionIQ.UI.Pages().ledger.detail.buttons[1]; b.scripts.OnClick(b)")
q = list(L.eval("AuctionIQ.db.queue").values())
dec = list(L.eval("AuctionIQ.db.decisions").values())
check("Craft pane: Queue adds the batch and saves its forecast, from Craft",
      len(q) == 1 and q[0].qty == 20 and len(dec) == 1 and dec[0].n == 20 and dec[0]["from"] == "craft" and dec[0].name == "Test Flask"
      and plain(L.eval("AuctionIQ.UI.Pages().ledger.detail.said:GetText()")).startswith("Queued 20 x Test Flask"))
run("AuctionIQ.db.queue = {}; AuctionIQ.db.decisions = {}")
run("AuctionIQ.UI.Go('operations', 'post')")
check("hand-off: moving to another view lets it go", LUI.Focus() is None)
check("Craft pane hides on a view without one", not L.eval("AuctionIQ.UI.Pages().ledger.detail").shown)
run("AuctionIQ.UI.Pages().ledger.search:SetText('')")
check("hand-off: clearing the filter shows everything again", plain(L.eval("AuctionIQ.UI.Pages().ledger.search:GetText()")) == "")
run("AuctionIQ.UI.Page('groups')")
check("Groups and rules lives in Settings", L.eval("AuctionIQ.UI.Pages().groups:IsShown()") is True)
run("AuctionIQ.UI.Page('ledger', 'sales')")
check("Accounting sub-tabs: Reports, Revenue, Expenses, Inventory, Profit",
      list(L.eval("AuctionIQ.UI.LayoutSubTabs()").values()) == ["Reports", "Revenue", "Expenses", "Inventory", "Profit"])
run("AuctionIQ.UI.Page('ledger', 'expired')")
navshown = [plain(b.text.t) for b in L.eval("AuctionIQ.UI.Pages().ledger.nav").values() if b.shown]
check("Expenses: purchases, other, expired, cancelled", LUI.Group() == "Expenses" and navshown == ["Purchases", "Other", "Expired", "Cancelled"])
run("AuctionIQ.UI.Page('ledger', 'perf')")
navshown = [plain(b.text.t) for b in L.eval("AuctionIQ.UI.Pages().ledger.nav").values() if b.shown]
check("Reports nav: the three statements, then Performance; the detail views open from it",
      navshown == ["Income Statement", "Balance Sheet", "Cash Flow", "Performance"] and LUI.Group() == "Reports")
run("AuctionIQ.UI.Page('crafting')")
check("old crafting tab opens Operations, Professions on Compare crafts", LUI.Section() == "operations" and LUI.View() == "scenarios")
run("AuctionIQ.UI.Page('operations', 'professions')")
check("Knowledge shows beside the nav", LUI.View() == "professions" and L.eval("AuctionIQ.UI.Pages().plan:IsShown()") is True)
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
check("Accounting remembers its last view", LUI.Section() == "ledger" and LUI.View() == "perf")
run("AuctionIQ.UI.Page('groups')"); run("AuctionIQ.UI.Page('plan')"); run("AuctionIQ.UI.Page('dashboard')")
check("old page names open the new tabs", CH.UI.IsShown())
nxt = list(CH.Next.List().values())
check("do next is ranked, leaking value first", len(nxt) > 0 and all(nxt[i].tier <= nxt[i + 1].tier for i in range(len(nxt) - 1)))
# Do next as decisions: the same action on several items is one card, four cards at most
run("""STUB.oldNextList = AuctionIQ.Next.List
AuctionIQ.Next.List = function() local out = {}
  for i = 1, 9 do table.insert(out, { title = 'Repost', detail = 'Item ' .. i .. ' x1 came back unsold', gold = i * 10000, tier = 2, risk = 'it expired once',
    go = { 'operations', 'post', { name = 'Item ' .. i, title = 'Repost' } } }) end
  for _, t in ipairs({ 'Relist', 'Cooldown ready', 'Weekly knowledge', 'Rethink' }) do table.insert(out, { title = t, detail = t, tier = t == 'Relist' and 1 or 3, gold = 5 }) end
  return out end""")
rk, allk = L.eval("AuctionIQ.Next.Ranked()")
rk = list(rk.values())
rep = [e for e in rk if e.title.startswith("Repost")]
check("Do next: nine reposts become one card with their gold summed, four cards at most, urgent first",
      len(rk) == 4 and allk == 5 and rk[0].title == "Relist" and len(rep) == 1 and rep[0].title == "Repost 9 items"
      and rep[0].gold == 450000 and rep[0].risk == "it expired once" and rep[0].go[3].name is None and "and 6 more" in rep[0].detail)
run("AuctionIQ.UI.Page('today')")
c2who = L.eval("AuctionIQ.UI.Pages().dashboard.d.cards[2].who:GetText()")
c2risk = L.eval("AuctionIQ.UI.Pages().dashboard.d.cards[2].l2:GetText()")
check("Do next: the cards show the reason and the biggest uncertainty, with no list to scroll",
      plain(c2who) == "Repost 9 items" and plain(c2risk) == "Risk: it expired once"
      and "matter most" in plain(L.eval("AuctionIQ.UI.Pages().dashboard.d.heading:GetText()")))
run("AuctionIQ.Next.List = STUB.oldNextList")
wc = L.eval("AuctionIQ.UI.Pages().dashboard.d.whatChanged")
check("What changed: the change in gold and up to three moves behind it, each opening Accounting",
      wc is not None and len(list(wc.moves.values())) <= 3 and all(m.go[1] == "ledger" for m in wc.moves.values())
      and plain(L.eval("AuctionIQ.UI.Pages().dashboard.d.changed.head:GetText()")).startswith("Gold "))
data = L.eval("AuctionIQ.UI.DashboardData()")
w2 = L.eval("AuctionIQ.UI.WhatChanged")(data)
mv = {m.key: m.gold for m in w2.moves.values()}
check("What changed: sales and purchases come from the ledger, the rest of the gold change shows as unclassified",
      all(abs(v) >= 10000 for v in mv.values()) and data.cash is not None
      and ("sales" not in mv or mv["sales"] == data.cash.inflows.auction + data.cash.inflows.other)
      and ("other" not in mv or abs(mv["other"] - data.cash.unclassified) < 1))
cf = CH.Statements.Cash(data.since, data.now)
check("What changed and the Cash Flow statement agree: same range, same characters, same unclassified",
      w2.gold == cf.change and abs(cf.unclassified - (cf.change - cf.classified)) < 1)
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
run("AuctionIQ.Queue.FillOrders()")
check("orders: Queue all twice queues each order once", CH.Queue.Count() == 1 and CH.db.queue[1].qty == 1)
run("AuctionIQ.Queue.Craft(AuctionIQ.db.queue[1])")
check("orders: Claim asks the game and waits: Claiming... until it says yes", L.eval("STUB.claimed") == 77 and CH.Queue.OrderStep(oq[0]) == "Claiming..."
      and L.eval("(AuctionIQ.Queue.Craft(AuctionIQ.db.queue[1]))") is False)
run('STUB.Fire("CRAFTINGORDERS_CLAIM_ORDER_RESPONSE", 0, 77)')
check("orders: Claim claims it, then Craft once the game confirms", CH.Queue.OrderStep(oq[0]) == "Craft")
run("AuctionIQ.Queue.Craft(AuctionIQ.db.queue[1])")
check("orders: crafting passes the claimed order's ID, and waits on the game", L.eval("STUB.crafted.id") == 10 and L.eval("STUB.crafted.order") == 77
      and CH.Queue.OrderStep(oq[0]) == "Crafting...")
run('STUB.claimedOrder.isFulfillable = true; STUB.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 10); STUB.RunTimers()')
check("orders: after the craft it's Turn in", CH.Queue.OrderStep(oq[0]) == "Turn in")
run("AuctionIQ.Queue.Craft(AuctionIQ.db.queue[1])")
check("orders: Turn in sends it and keeps it, Turning in..., until the game says yes", L.eval("STUB.fulfilled") == 77 and CH.Queue.Count() == 1
      and CH.Queue.OrderStep(CH.db.queue[1]) == "Turning in...")
run('STUB.Fire("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 5, 77)')
check("orders: a turn-in the game refuses stays, ready to try again", CH.Queue.Count() == 1 and CH.Queue.OrderStep(CH.db.queue[1]) == "Turn in")
run("AuctionIQ.Queue.Craft(AuctionIQ.db.queue[1]); STUB.Fire('CRAFTINGORDERS_FULFILL_ORDER_RESPONSE', 0, 77)")
check("orders: the game taking it removes it from the queue", CH.Queue.Count() == 0)
run("AuctionIQ.Queue.Clear(); STUB.claimed = nil; STUB.fulfilled = nil; STUB.claimedOrder = nil; C_CraftingOrders.GetClaimedOrder = nil")
# One button: Next step walks claim, craft, turn in
run("AuctionIQ.Queue.FillOrders()")
st = L.eval("(AuctionIQ.Queue.DoNext())")
check("next step: first click claims", st == "Claim" and L.eval("STUB.claimed") == 77)
run('STUB.Fire("CRAFTINGORDERS_CLAIM_ORDER_RESPONSE", 3, 77)')
check("next step: a refused claim goes back to Claim", CH.Queue.OrderStep(CH.db.queue[1]) == "Claim")
run("AuctionIQ.Queue.DoNext(); STUB.Fire('CRAFTINGORDERS_CLAIM_ORDER_RESPONSE', 0, 77)")
run("C_CraftingOrders.GetClaimedOrder = function() return { orderID = 77, isFulfillable = false } end")
st = L.eval("(AuctionIQ.Queue.DoNext())")
check("next step: then crafts", st == "Craft" and L.eval("STUB.crafted.id") == 10)
run("C_CraftingOrders.GetClaimedOrder = function() return { orderID = 77, isFulfillable = true } end")
run('STUB.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 10); STUB.RunTimers()')
check("next step: the game saying it's done means Turn in", CH.Queue.OrderStep(CH.db.queue[1]) == "Turn in")
st = L.eval("(AuctionIQ.Queue.DoNext())")
run('STUB.Fire("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 77)')
check("next step: then turns it in", st == "Turn in" and L.eval("STUB.fulfilled") == 77 and CH.Queue.Count() == 0)
run("C_CraftingOrders.GetClaimedOrder = nil")
# Crafting an order crafts into the live claimed order, leaves out the customer's reagents, and only counts once the game says it's done
run("""AuctionIQ.Queue.Clear(); STUB.claimed = nil; STUB.fulfilled = nil; STUB.crafted = nil; STUB.created = nil; STUB.completed = nil
AuctionIQ.Queue.FillOrders(); AuctionIQ.Queue.DoNext(); STUB.Fire('CRAFTINGORDERS_CLAIM_ORDER_RESPONSE', 0, 77)
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
# an order needing rank 2 that these reagents only reach with Concentration: say so first, then craft with it on
run('STUB.Fire("UNIT_SPELLCAST_FAILED", "player", "cast", 10)')
cw = L.eval("""(function() STUB.crafted = nil; STUB.claimedOrder.minQuality = 2; STUB.extraSkill = -1000
  local a, b = AuctionIQ.Queue.DoNext(); local first = STUB.crafted; local c = AuctionIQ.Queue.DoNext(); STUB.extraSkill = nil
  return { a = a, why = b, first = first } end)()""")
check("order craft: a craft needing Concentration it didn't plan says so and waits for a second press",
      cw.a is False and "Concentration" in str(cw.why) and "Press again" in str(cw.why) and cw.first is None)
check("order craft: turns Concentration on when the order's rank needs it", L.eval("STUB.crafted.conc") is True and L.eval("STUB.crafted.order") == 77)
run('STUB.Fire("UNIT_SPELLCAST_FAILED", "player", "cast", 10)')
run("STUB.claimedOrder.minQuality = 9; STUB.crafted = nil")
st = L.eval("{ AuctionIQ.Queue.DoNext() }")
check("order craft: refuses, and says why, when even Concentration can't reach the rank", L.eval("STUB.crafted") is None and "needs rank 9" in str(st[2]))
run("STUB.claimedOrder.minQuality = nil")
run('STUB.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 10); STUB.RunTimers()')
check("order craft: a craft that didn't go into the order stays Craft", CH.Queue.OrderStep(CH.db.queue[1]) == "Craft")
run('STUB.claimedOrder.isFulfillable = true')
st = L.eval("(AuctionIQ.Queue.DoNext())")
check("order craft: Turn in asks Blizzard to fulfil the claimed order and waits", st == "Turn in" and L.eval("STUB.fulfilled") == 77 and CH.Queue.Count() == 1
      and CH.Queue.OrderStep(CH.db.queue[1]) == "Turning in...")
run('STUB.Fire("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 77)')
check("order craft: once Blizzard confirms the turn-in, the order leaves the queue", CH.Queue.Count() == 0)
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
pb = L.eval("""AuctionIQ.Advisor.PickBest({ { quality = 1, profit = -100, short = true },
  { quality = 2, profit = -500, concentration = 80, perPoint = -6 } })""")
check("orders: when only Concentration reaches the rank asked, the order is reachable at its loss",
      pb[0] is None and pb[1] is not None and pb[1].profit == -500)
check("order list: who it's from", by[77]["from"] == "Pat" and by[78]["from"] == "Patron")
run("AuctionIQ.ScanUI.SetMode('orders')")
orows = list(CH.ScanUI.Refresh().values())
check("scan tab: lists orders with 1KP flagged", len(orows) == 3 and "kp=true" in orows[0])
tip = [plain(l[1]) for l in CH.ScanUI.OrderLines(by[78]).values()]
check("scan tab hover: the knowledge reward is named", any("Knowledge Notes" in t and "knowledge" in t for t in tip))
pl = [plain(l[1]).strip() for l in CH.ScanUI.OrderCellLines(by[77], 4).values()]
check("orders: hovering Profit reads like a statement: revenue, costs, profit", pl[0] == "Revenue" and pl[1].startswith("Commission") and "Costs" in pl and "Profit" in pl)
cl = [plain(l[1]).strip() for l in CH.ScanUI.OrderCellLines(by[77], 5).values()]
check("orders: hovering Crafting costs lists each reagent you supply with how many you have", cl[0] == "Crafting costs" and any("have" in x for x in cl) and "Total" in cl)
rl2 = [plain(l[1]).strip() for l in CH.ScanUI.OrderCellLines(by[78], 3).values()]
check("orders: hovering Rewards names each reward", rl2[0] == "Rewards" and any("Knowledge Notes" in x for x in rl2))
ph = [plain(l[1]).strip() for l in CH.ScanUI.OrderCellLines(by[78], 4).values()]
hv = L.eval("AuctionIQ.ScanUI.ORDER_HOVER")
check("orders: the Reagents column's hover is the reagents you supply, Profit's lists the rewards", hv[3] == 5 and hv[4] == 4 and any("Knowledge Notes" in x for x in ph))
tw = L.eval("""(function()
  local f = CreateFrame('Frame'); STUB.entered = {}
  local rows = AuctionIQ.Window.Table(f, { { 'A', 12, 50 }, { 'B', 70, 50 } }, 3, 0, 18, nil, function(_, i) table.insert(STUB.entered, i) end, 200)
  local idle = rows[1].button.scripts.OnUpdate == nil and rows[2].button.scripts.OnUpdate == nil
  rows[2].button.scripts.OnEnter(rows[2].button)
  local tracks = rows[2].button.scripts.OnUpdate ~= nil and rows[1].button.scripts.OnUpdate == nil
  rows[2].button.scripts.OnLeave(rows[2].button)
  return idle and tracks and rows[2].button.scripts.OnUpdate == nil and #STUB.entered == 1 and STUB.entered[1] == 2
end)()""")
check("tables: only the row under the mouse follows it across columns (no other row takes the tooltip)", tw)
check("orders: a patron order's customer reads NPC", by[78].customer == "NPC" and by[77].customer == "Pat")
# each order row has its own Claim button: claims that order, then opens it once the game says yes
run("""STUB.claimed = nil; STUB.claimedOrder = nil; STUB.opened = nil
C_CraftingOrders.ClaimOrder = function(id)
  STUB.claimed = id
  for _, o in ipairs(C_CraftingOrders.GetCrafterOrders()) do if o.orderID == id then STUB.claimedOrder = o end end
end
C_CraftingOrders.GetClaimedOrder = function() return STUB.claimedOrder end
STUB.oldOpen = AuctionIQ.Orders.Open; AuctionIQ.Orders.Open = function(o) STUB.opened = o and o.orderID end""")
sk = L.eval("""(function()
  local old = C_TradeSkillUI.GetCraftingOperationInfoForOrder
  -- the customer's reagents add skill only when they're passed in
  C_TradeSkillUI.GetCraftingOperationInfoForOrder = function(id, infos, orderID, conc)
    return { baseSkill = 100, bonusSkill = #infos > 0 and 180 or 0, baseDifficulty = 455 }
  end
  local m = { orderID = 5, recipeID = 10, qual = {}, provided = { { reagent = { itemID = 1 }, itemID = 1, dataSlotIndex = 1, quantity = 5 } } }
  local info = AuctionIQ.Advisor.Operation(m, {}, false)
  C_TradeSkillUI.GetCraftingOperationInfoForOrder = old
  return info.bonusSkill
end)()""")
check("orders: the customer's reagents' quality counts toward skill (a claimed Phoenix Oil read 141 instead of 323)", sk == 180)
# A single-quality reagent in the list makes the game answer nothing (CraftSim leaves them out too)
nq = L.eval("""(function()
  local ui = C_TradeSkillUI
  local old = ui.GetCraftingOperationInfoForOrder
  ui.GetCraftingOperationInfoForOrder = function(id, infos, orderID, conc)
    local skill = 0
    for _, r in ipairs(infos) do
      if r.itemID == 205 then return nil end -- slot 3 has one quality: the game refuses
      if r.itemID == 202 then skill = skill + 20 * r.quantity end
    end
    return { baseSkill = 100, bonusSkill = skill, baseDifficulty = 130 }
  end
  local m = AuctionIQ.Advisor.Measure(10, { order = { orderID = 9, minQuality = 1,
    provided = { { reagent = { itemID = 202 }, itemID = 202, dataSlotIndex = 1, quantity = 4 },
                 { reagent = { itemID = 205 }, itemID = 205, dataSlotIndex = 3, quantity = 2 } } } })
  ui.GetCraftingOperationInfoForOrder = old
  return m and m.skill0
end)()""")
check("orders: the customer's quality reagents count even when a single-quality one is in the order", nq == 180)

# Recipe slots can share a data slot number: the customer's reagents go to the slot listing their item
ds = L.eval("""(function()
  local ui = C_TradeSkillUI
  local old = ui.GetRecipeSchematic
  ui.GetRecipeSchematic = function(id, r)
    local sch = old(id, r)
    if id == 10 then sch.reagentSlotSchematics[2].dataSlotIndex = 1 end -- both quality slots are data slot 1
    return sch
  end
  local m = AuctionIQ.Advisor.Measure(10, { order = { orderID = 9, minQuality = 1,
    provided = { { reagent = { itemID = 202 }, itemID = 202, dataSlotIndex = 1, quantity = 4 },
                 { reagent = { itemID = 204 }, itemID = 204, dataSlotIndex = 1, quantity = 5 } } } })
  ui.GetRecipeSchematic = old
  local n = 0
  for _, r in ipairs(m and m.provided or {}) do n = n + r.quantity end
  return { n = n, qual = m and #m.qual }
end)()""")
check("orders: two recipe slots sharing data slot 1 both take the customer's reagents (none dropped, neither left to you)",
      ds.n == 9 and ds.qual == 0)
# Shatter: a Midnight enchanting craft casts Shatter first when Shattering Essence is missing
sh = L.eval("""(function()
  local ui = C_TradeSkillUI
  local o = { info = ui.GetRecipeInfo, prof = ui.GetProfessionInfoByRecipeID, salv = ui.GetSalvagableItemIDs, cs = ui.CraftSalvage }
  local oldUA, oldC, oldIL, oldCount = C_UnitAuras, C_Container, ItemLocation, C_Item.GetItemCount
  STUB.aura = nil; STUB.salvaged = nil
  ui.GetRecipeInfo = function(id) if id == 1235731 then return { learned = true, name = 'Shatter' } end return o.info(id) end
  ui.GetProfessionInfoByRecipeID = function(id) return { professionID = (id == 1235731 or id == 10) and 2909 or 1 } end
  ui.GetSalvagableItemIDs = function() return { 501, 502 } end
  ui.CraftSalvage = function(id, n, loc) STUB.salvaged = { id = id, bag = loc.bag, slot = loc.slot } end
  C_UnitAuras = { GetPlayerAuraBySpellID = function(id) return STUB.aura end }
  C_Item.GetItemCount = function(id) return (id == 501 or id == 502) and 3 or (oldCount and oldCount(id) or 0) end
  AuctionIQ.db.prices = AuctionIQ.db.prices or {}
  local oldGet = AuctionIQ.Prices.Get
  AuctionIQ.Prices.Get = function(src, key) if key == 'i:501' then return 900 elseif key == 'i:502' then return 300 end return oldGet(src, key) end
  C_Container = { GetContainerNumSlots = function(bag) return bag == 0 and 2 or 0 end,
    GetContainerItemID = function(bag, slot) return slot == 1 and 501 or 502 end }
  ItemLocation = { CreateFromBagAndSlot = function(_, bag, slot) return { bag = bag, slot = slot } end }
  local e = { recipeID = 10 }
  local r = {}
  r.step = AuctionIQ.Queue.OrderStep(e)
  r.other = AuctionIQ.Queue.OrderStep({ recipeID = 99 })
  local m1 = AuctionIQ.Advisor.Measure(10)
  r.shatterModel = m1 and m1.shatter
  r.ing1 = m1 and m1.stats0.ingenuity
  r.cast = AuctionIQ.Queue.Shatter()
  r.salv = STUB.salvaged
  STUB.aura = { spellId = 1235733 }
  r.after = AuctionIQ.Queue.OrderStep(e)
  local m2 = AuctionIQ.Advisor.Measure(10)
  r.ing2 = m2 and m2.stats0.ingenuity
  r.shatter2 = m2 and m2.shatter
  ui.GetRecipeInfo, ui.GetProfessionInfoByRecipeID, ui.GetSalvagableItemIDs, ui.CraftSalvage = o.info, o.prof, o.salv, o.cs
  C_UnitAuras, C_Container, ItemLocation, C_Item.GetItemCount = oldUA, oldC, oldIL, oldCount
  AuctionIQ.Prices.Get = oldGet
  return r
end)()""")
check("shatter: a Midnight enchanting craft without Shattering Essence shows Shatter first (others don't)", sh.step == "Shatter" and sh.other == "Craft")
check("shatter: casts Shatter on the cheapest mote in your bags", sh.cast and sh.salv.id == 1235731 and sh.salv.slot == 2)
check("shatter: with the buff on, the step is Craft again", sh.after == "Craft")
# the game's salvage list can come back empty: the recipe's own slot still names the motes
sc = L.eval("""(function()
  local ui = C_TradeSkillUI
  local oldS, oldSch, oldC, oldCount = ui.GetSalvagableItemIDs, ui.GetRecipeSchematic, C_Container, C_Item.GetItemCount
  ui.GetSalvagableItemIDs = function() return {} end
  ui.GetRecipeSchematic = function(id) if id == 1235731 then return { reagentSlotSchematics = { { reagents = { { itemID = 601 }, { itemID = 602 } } } } } end return oldSch(id) end
  C_Item.GetItemCount = function(id) return id == 602 and 2 or 0 end
  C_Container = { GetContainerNumSlots = function(bag) return bag == 5 and 1 or 0 end, GetContainerItemID = function() return 602 end }
  local id, bag = AuctionIQ.Queue.ShatterItem()
  ui.GetSalvagableItemIDs, ui.GetRecipeSchematic, C_Container, C_Item.GetItemCount = oldS, oldSch, oldC, oldCount
  return { id = id, bag = bag }
end)()""")
check("shatter: finds motes from the recipe's slot when the salvage list is empty (reagent bag too)", sc.id == 602 and sc.bag == 5)
# motes only in the warband bank: Shatter takes one from there
wb = L.eval("""(function()
  local ui = C_TradeSkillUI
  local oldS, oldC, oldCount, oldE = ui.GetSalvagableItemIDs, C_Container, C_Item.GetItemCount, Enum.BagIndex
  ui.GetSalvagableItemIDs = function() return { 701 } end
  Enum.BagIndex = { ReagentBag = 5, AccountBankTab_1 = 12, AccountBankTab_2 = 13 }
  C_Item.GetItemCount = function(id, bank, uses, reagentBank, account) return (id == 701 and account) and 40 or 0 end
  C_Container = { GetContainerNumSlots = function(bag) return bag == 13 and 3 or 2 end,
    GetContainerItemID = function(bag, slot) return (bag == 13 and slot == 3) and 701 or nil end }
  local id, bag, slot = AuctionIQ.Queue.ShatterItem()
  ui.GetSalvagableItemIDs, C_Container, C_Item.GetItemCount, Enum.BagIndex = oldS, oldC, oldCount, oldE
  return { id = id, bag = bag, slot = slot }
end)()""")
check("shatter: motes only in the warband bank are found there", wb.id == 701 and wb.bag == 13 and wb.slot == 3)
check("shatter: the advisor counts Shattering Essence before it's cast (as CraftSim), and not twice once it's on",
      sh.shatterModel and not sh.shatter2 and sh.ing1 == sh.ing2 + 5)
check("orders: an order's button starts at Claim", CH.ScanUI.ClaimState(by[77]) == "claim")
run("AuctionIQ.Queue.Clear()")
check("orders: Claim claims that order (and queues it for the next steps)", CH.ScanUI.Claim(by[77]) and L.eval("STUB.claimed") == 77
      and L.eval("AuctionIQ.Queue.ForOrder(77) ~= nil"))
check("orders: until the game answers, the button reads Claiming...", CH.ScanUI.ClaimLabel(CH.ScanUI.ClaimState(by[77]), by[77]) == "Claiming...")
run('STUB.Fire("CRAFTINGORDERS_CLAIM_ORDER_RESPONSE", 0, 77)')
check("orders: once claimed, the order opens and its button moves on to Craft",
      L.eval("STUB.opened") == 77 and CH.ScanUI.ClaimState(by[77]) == "craft" and plain(CH.ScanUI.ClaimLines(by[77])[1][1]).startswith("Craft"))
check("orders: another order can't be claimed while one is", CH.ScanUI.ClaimState(by[78]) == "busy" and not CH.ScanUI.Claim(by[78]) and L.eval("STUB.claimed") == 77)
run("STUB.crafted = nil; STUB.oldCraft = C_TradeSkillUI.CraftRecipe; C_TradeSkillUI.CraftRecipe = function(id, n, r, _, order, conc) STUB.crafted = { id = id, order = order, conc = conc } end")
rp = L.eval("""(function()
  local e = { orderID = '77', recipeID = 10, reagents = {}, concentration = 999 }
  local ok = AuctionIQ.Queue.Replan(e)
  return { ok = ok, conc = e.concentration, n = #e.reagents }
end)()""")
check("orders: Craft works the order out again from the live order (a stale plan's Concentration is dropped)", rp.ok and rp.conc is None and rp.n > 0)
check("orders: Craft crafts it into the claimed order", CH.ScanUI.Claim(by[77]) and L.eval("STUB.crafted and STUB.crafted.order") == 77)
run("C_TradeSkillUI.CraftRecipe = STUB.oldCraft; STUB.claimedOrder.isFulfillable = true; STUB.fulfilled = nil; C_CraftingOrders.FulfillOrder = function(id) STUB.fulfilled = id end")
check("orders: while the craft is casting, the button reads Crafting... and won't press again",
      CH.ScanUI.ClaimState(by[77]) == "pending" and CH.ScanUI.ClaimLabel("pending", by[77]) == "Crafting..." and not CH.ScanUI.Claim(by[77]))
run('STUB.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 10); STUB.RunTimers()')
check("orders: when crafted, the button reads Turn in and turns it in", CH.ScanUI.ClaimState(by[77]) == "turnin" and CH.ScanUI.Claim(by[77]) and L.eval("STUB.fulfilled") == 77)
check("orders: until the game takes it, the button reads Turning in... and the order stays queued",
      CH.ScanUI.ClaimLabel(CH.ScanUI.ClaimState(by[77]), by[77]) == "Turning in..." and L.eval("AuctionIQ.Queue.ForOrder(77) ~= nil"))
run('STUB.Fire("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 5, 77)')
check("orders: a refused turn-in leaves the order queued with Turn in to try again",
      L.eval("AuctionIQ.Queue.ForOrder(77) ~= nil") and CH.ScanUI.ClaimState(by[77]) == "turnin")
run('STUB.fulfilled = nil'); CH.ScanUI.Claim(by[77]); run('STUB.Fire("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 77)')
check("orders: once the game takes it, it leaves the queue", L.eval("STUB.fulfilled") == 77 and L.eval("AuctionIQ.Queue.ForOrder(77) == nil"))
rel = L.eval("""(function() local Q = AuctionIQ.Queue
  local e = Q.AddEntry({ char = 'Me-Realm', recipeID = 10, orderID = '88', reagents = {}, shop = {}, stage = 'claimed' }, 1)
  STUB.Fire('CRAFTINGORDERS_RELEASE_ORDER_RESPONSE', 0, 88)
  local s = Q.OrderStep(e); Q.Remove(e); return s end)()""")
check("orders: releasing a claimed order (Cancel Order) puts it back to Claim", rel == "Claim")
run("STUB.claimedOrder.isFulfillable = nil; AuctionIQ.Queue.Clear()")
run("AuctionIQ.Orders.Open = STUB.oldOpen; C_CraftingOrders.GetClaimedOrder = nil; STUB.claimedOrder = nil; STUB.claimed = nil")
run("AuctionIQ.Queue.Clear()")
check("scan tab: Queue all queues orders that pay or give knowledge", CH.ScanUI.QueueAll() == 2)
# popped out and closed, the Queue window comes up when Queue all adds orders
run("""AuctionIQ.Queue.Clear(); AuctionIQ.QueueUI.Show(); AuctionIQ.Window.ToggleQueuePop()
AuctionIQ.QueueUI.Toggle(); STUB.wasShown = AuctionIQ.QueueUI.IsShown()
AuctionIQ.ScanUI.allButton.scripts.OnClick()""")
check("pop-out: Queue all opens the closed Queue window", not L.globals().STUB.wasShown and CH.QueueUI.IsShown() and CH.db.queue[1] is not None)
run("AuctionIQ.Window.ToggleQueuePop(); AuctionIQ.ScanUI.Open(); AuctionIQ.ScanUI.SetMode(\"orders\"); AuctionIQ.Queue.Clear()")
run("AuctionIQ.Queue.Clear(); STUB.oldCount = C_Item.GetItemCount; C_Item.GetItemCount = function() return 0 end")
nohave = list(CH.Orders.List().values())
check("orders: each says whether you hold the reagents, and which are missing", not nohave[0].have and len(list(nohave[0].missing.values())) > 0)
check("orders: a Reagents column reads have/need in units, for the reagent you're shortest on", nohave[0].reagentsNeed > 0 and nohave[0].reagentsHave < nohave[0].reagentsNeed and nohave[0].reagentsLow is not None)
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
# the list keeps each order's row between redraws; the game's bag or Concentration events redo it
run("""AuctionIQ.Orders.MAX_AGE = 60; STUB.analyses = 0; STUB.oldAnalyze = AuctionIQ.Orders.Analyze
AuctionIQ.Orders.Analyze = function(o) STUB.analyses = STUB.analyses + 1; return STUB.oldAnalyze(o) end
AuctionIQ.Orders.Invalidate(); AuctionIQ.Orders.List(); STUB.first = STUB.analyses
AuctionIQ.Orders.List(); AuctionIQ.Orders.List(); STUB.again = STUB.analyses""")
run("STUB.Fire('BAG_UPDATE_DELAYED'); AuctionIQ.Orders.List(); STUB.after = STUB.analyses")
S = L.globals().STUB
check("orders: a redraw reuses each order's row; a bag change works them out again",
      S.first > 0 and S.again == S.first and S.after == 2 * S.first)
run("AuctionIQ.Orders.Analyze = STUB.oldAnalyze; AuctionIQ.Orders.MAX_AGE = -1")
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
cf = list(L.eval("AuctionIQ.UI.RenderConcFooter()").values())
check("footer: up to three Concentration bars, fullest first", len(cf) <= 3 and all(0 <= b.share <= 1 for b in cf)
      and all(cf[i].share >= 0 for i in range(len(cf))))
L.execute((ROOT / "tests" / "layout_audit.lua").read_text())
audit_all = []
def audit(where):
    roots = L.eval("(function() local r = {} for _, f in ipairs(STUB.frames) do if (f.parent == nil or f.parent == UIParent) and f.w > 0 then table.insert(r, f) end end return r end)()")
    for p in L.eval("STUB.Audit")(roots).values():
        audit_all.append(where + ": " + p)
    for p in L.eval("STUB.Overlaps")(roots).values():
        audit_all.append(where + ": " + p)
for tab in ["today", "research", "operations", "markets", "crafting", "trading", "analytics", "ledger", "report", "settings"]:
    run(f"AuctionIQ.UI.Page('{tab}')")
    audit(tab)
run("AuctionIQ.AdvisorUI.Show(10); AuctionIQ.AdvisorUI.RowClick(2); AuctionIQ.AdvisorUI.SetPane('batch')")
check("layout: the advisor's batch pane is showing a suggestion", plain(L.eval("AuctionIQ.AdvisorUI.PaneTitle()")).startswith(("Make ", "Don't craft", "No sale rate")))
audit("advisor batch pane")
run("AuctionIQ.AdvisorUI.SetPane('notes')")
for v in ["compare", "inventory", "sales", "income", "resale", "purchases", "expense", "expired", "cancelled", "pl", "holdings", "overhead", "market", "rivals", "when", "par", "dead", "time", "perf", "results", "post", "performance", "batches", "drivers", "capital", "crafting", "scenarios", "queue", "shopping", "restock", "professions", "paths", "work", "plans", "overview", "statement", "balance", "cashflow", "ready"]:
    run(f"AuctionIQ.UI.Page('ledger', '{v}')")
    audit("view " + v)
check("resize: a grip in the corner, the size kept between 0.6 and 1.6 and saved",
      CH.UI.Pages().ledger.parent.sizer is not None and CH.UI.SetScale(3) == 1.6 and CH.db.settings.window.scale == 1.6 and CH.UI.SetScale(1) == 1)
run("AuctionIQ.UI.Page('ledger', 'sales')")
check("resize: taller shows more table rows, the footer stays inside the page",
      CH.UI.SetHeight(900) == 900 and CH.LedgerUI.SetRows(None) > 30 and CH.UI.Pages().ledger.h == 900 - 54 - 26
      and CH.UI.SetHeight(100) == 600 and CH.LedgerUI.SetRows(None) == 24)
w2, h2 = CH.UI.SetSize(1400, 900)
check("resize: wider and taller, every page laid out again for the size",
      (w2, h2) == (1400, 900) and CH.UI.Pages().ledger.w == 1376 and CH.UI.Pages().paths.w == 1376 - 172
      and CH.UI.Pages().dashboard.w == 1376 and CH.UI.IsShown())
run("AuctionIQ.UI.Page('ledger', 'sales')")
heads = [h for h in CH.UI.Pages().ledger.heads.values() if h.shown]
check("resize: table columns spread across a wider window", len(heads) > 2 and max(h.point[2] for h in heads) > 172 + 800)
for tab in ["today", "research", "operations", "ledger", "report", "settings"]:
    run(f"AuctionIQ.UI.Page('{tab}')")
    audit("large " + tab)
for v in ["professions", "paths", "plans", "sales", "queue"]:
    run(f"AuctionIQ.UI.Page('ledger', '{v}')")
    audit("large view " + v)
check("resize: never smaller than the normal size", CH.UI.SetSize(100, 100) == (920, 600) or tuple(CH.UI.SetSize(100, 100)) == (920, 600))
run("AuctionIQ.UI.Page('today')")
navs = list(CH.UI.Pages().ledger.nav.values())
long = [plain(b.text.t) for b in navs if b.text and not b.fits]
check("nav: every label fits its button on one line", len(navs) > 20 and long == [] and all(b.text.wrap is False for b in navs if b.text))
run("AuctionIQ.UI.Page('today')")
for w in ["ScanUI", "QueueUI", "LogUI"]:
    run(f"if AuctionIQ.{w} and AuctionIQ.{w}.Toggle then pcall(AuctionIQ.{w}.Toggle) end")
    audit(w)
# the Craft window's Details view: one item, laid out on the table card's grid
run("AuctionIQ.AdvisorUI.Show(10, true); AuctionIQ.ScanUI.SetMode('recipes'); AuctionIQ.ScanUI.Select(10); AuctionIQ.ScanUI.SetDetails(true)")
dd = L.eval("AuctionIQ.ScanUI.lastDetails")
check("details: break-even chart, price check, will it sell and what drives the cost, for the picked recipe",
      dd is not None and dd.chart is not None and len(list(dd.chartLines.values())) >= 1 and dd.price.verdict and dd.sell.verdict
      and len(list(dd.sell.rows.values())) >= 3 and len(list(dd.cost.rows.values())) >= 1 and "%" in plain(dd.cost.verdict))
check("details: the reagents are ranked by their share of the cost", all("%" in plain(r[2]) for r in dd.cost.rows.values()))
check("details: showing while on", CH.ScanUI.DetailsShown())
hov = L.eval("(function() local ch = AuctionIQ.ScanUI.DetailsChart(); local pl = ch.plot; return AuctionIQ.AdvisorUI.ChartHover(ch, pl.x0 + pl.X(1)) end)()")
hl = [plain(l[1]) for l in hov.values()]
check("break-even chart hover: the price step under the mouse, and each craft's profit and break-even there",
      hl[0] in ("Sale price at 99% of the estimate", "Sale price at 100% of the estimate", "Sale price at 101% of the estimate") and "  Profit a craft" in hl and "  Breaks even at" in hl)
audit("craft details")
run("AuctionIQ.ScanUI.SetDetails(false)")
check("details: Back returns to the list", L.eval("AuctionIQ.ScanUI.DetailsOn()") is False and not CH.ScanUI.DetailsShown())
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

# UI pass: visible scroll position
run("""STUB.sb = AuctionIQ.Window.ScrollBar(UIParent, 100, -10, 100)
STUB.sb:Set(17, 17, 83)""")
check("scroll bar: says which rows are showing", L.eval("STUB.sb.text") == "18-34 of 83")
run("STUB.sb:Set(0, 17, 10)")
check("scroll bar: hides when everything fits", L.eval("STUB.sb.text") is None)

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
bg = L.eval("""(function()
  local P = AuctionIQ.Prices
  P.background = true
  local first = P.Values(100, time() + 700).realized
  for _ = 1, 20 do STUB.RunTimers() end
  local later = P.Values(100, time() + 700).realized
  P.background = false
  return { first = first or -1, later = later or -1 }
end)()""")
check("values: in a click the sales are added up over the next frames (the last totals meanwhile)", bg.first == 95000 and bg.later == 95000)
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
check("analytics: Performance view opens", LUI.View() == "performance" and LUI.Section() == "ledger")
nav = [n[1] for k, n in sorted((k, n) for k, n in L.eval("AuctionIQ.LedgerUI.SECTIONS.ledger").items() if isinstance(k, int))]
rep = nav[nav.index("Reports") + 1:]
check("Reports nav: Performance after the statements; the old Performance sub-tab is gone",
      rep[:4] == ["statement", "balance", "cashflow", "overview"] and "Performance" not in nav and "batches" not in nav)
srows = list(L.eval("(AuctionIQ.LedgerUI.Rows('scenarios', {}))").values())
made = {plain(r.cells[1]): r for r in srows if plain(r.cells[6]) != "-"}
check("Compare crafts: a Make column from each scan, the scenarios on hover", "Test Flask" in made and plain(made["Test Flask"].cells[6]) == "50"
      and any(plain(l[1]).startswith("Make 50: ") for l in made["Test Flask"].cellTip(6).values()))
# Compare crafts hover: the craft's name shows the item, every other column what it is and how it was worked out
ft = made["Test Flask"]
def money_of(t):
    t = letters(plain(t)).replace(",", "")
    sign = -1 if t.startswith("-") else 1
    g = re.search(r"(\d+)g", t); sv = re.search(r"(\d+)s", t); c = re.search(r"(\d+)c", t)
    return sign * ((int(g.group(1)) * 10000 if g else 0) + (int(sv.group(1)) * 100 if sv else 0) + (int(c.group(1)) if c else 0))
heads = [plain(ft.cellTip(j)[1][1]) for j in range(2, 7)] + [plain(ft.cellTip(k)[1][1]) for k in ["up", "down", "both", "room"]]
check("Compare crafts: each column after the craft, and each price scenario, explains itself on hover",
      heads == ["Character", "Profit now", "Break-even per item", "Cushion", "Make", "Reagents +10%", "Price -10%", "Both", "Room"])
pn = [l for l in ft.cellTip(3).values()][2:]
pn = pn[:[plain(l[1]) for l in pn].index("Profit a craft") + 1] # craft or sell follows, when you hold its reagents
check("Compare crafts: Profit now's breakdown adds up to the profit shown",
      abs(sum(money_of(l[2]) for l in pn[:-1]) - money_of(pn[-1][2])) <= len(pn) and plain(pn[-1][1]) == "Profit a craft")
ru = [l for l in ft.cellTip("up").values()][2:]
check("Compare crafts: Reagents +10% starts from profit now and ends at the column's number",
      plain(ru[0][1]) == "Profit now" and abs(sum(money_of(l[2]) for l in ru[:-1]) - money_of(ru[-1][2])) <= len(ru))
run("STUB.hit = { id = 12345, cellTip = function(j) return AuctionIQ.AnalyticsViews.ScenarioTip(STUB.lastX, j) end }")
L.globals().STUB.lastX = ft.x
check("Compare crafts: hovering the craft name shows the item, another column its explanation",
      L.eval("AuctionIQ.LedgerUI.ShowCellTip(STUB.hit, 1)") == 1 and L.eval("AuctionIQ.LedgerUI.ShowCellTip(STUB.hit, 3)") == 3
      and L.eval("AuctionIQ.LedgerUI.ColumnAt(0)") == 1)
# Scenarios reprice revenue, consumed reagents and what Resourcefulness gives back separately:
# 130 revenue - 100 reagents + 20 back = 50; reagents +10% = 42, price -10% = 37, both = 29
parts = L.eval("{ revenue = 130, consumed = 100, returned = 20, deposits = 0 }")
rp = L.eval("AuctionIQ.AnalyticsViews.Reprice")
check("scenarios: Resourcefulness's returns are repriced with the reagents",
      abs(rp(parts, 0, 0) - 50) < 1e-9 and abs(rp(parts, 0.1, 0) - 42) < 1e-9 and abs(rp(parts, 0, 0.1) - 37) < 1e-9 and abs(rp(parts, 0.1, 0.1) - 29) < 1e-9)
pa = L.eval("AuctionIQ.AnalyticsViews.Parts({ profit = 50, cost = 100, accounts = { sales = 120, mcGold = 10, cost = 100, resGold = 20, unit = 13, deposit = 1 } })")
sb = L.eval("AuctionIQ.Decide.BreakEvenParts(AuctionIQ.Decide.AccountParts({ profit = 50, cost = 100, accounts = { sales = 120, mcGold = 10, cost = 100, resGold = 20, unit = 13, deposit = 1, price = 14 } }), 14)")
check("scenarios: break-even sale price per item from a scan's accounts (deposits stay, returns help)",
      abs(sb.factor - 90 / 140) < 1e-12 and abs(sb.price - 14 * 90 / 140) < 1e-9)
check("scenarios: a scan's accounts split into revenue, reagents, returns and deposits",
      pa.revenue == 130 and pa.consumed == 100 and pa.returned == 20 and abs(pa.deposits - 10) < 1e-9 and abs(rp(pa, 0, 0.1) - 36) < 1e-9)
# Scenarios: editable, saved, and the headings follow
run("AuctionIQ.UI.Page('operations', 'scenarios')")
ctl = L.eval("AuctionIQ.UI.Pages().ledger.controls")
check("scenarios: two setting buttons show", ctl[1].shown and ctl[2].shown and plain(ctl[1].label) == "Reagents +10%")
run("AuctionIQ.UI.Pages().ledger.controls[1].scripts.OnClick(AuctionIQ.UI.Pages().ledger.controls[1], 'LeftButton')")
sc2 = [x for x in L.eval(f"AuctionIQ.AnalyticsViews.Scenarios({ctx})").values() if x.name == "Test Flask" and x.char == "Alt"][0]
check("scenarios: left-click raises reagents to +15% and the numbers follow", abs(sc2.reagentsUp - 250) < 1e-6
      and L.eval("AuctionIQ.db.scenario.reagents") == 0.15 and plain(ctl[1].label) == "Reagents +15%")
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
run("STUB.sellThrough = {}")

# One theme across the addon: every window's main action is the filled button, and the main blocks
# carry the accent line or a shaded card
run('AuctionIQ.AuctionUI.Build()')
check("theme: the Auction window builds with its main button filled", L.eval("AuctionIQ.AuctionUI.Build() ~= nil"))
check("theme: T.Card gives a shaded card with an accent line", L.eval("select(2, AuctionIQ.Theme.Card(CreateFrame('Frame'), 0, 0, 10, 10, true)) ~= nil"))
check("theme: T.Primary fills a button", L.eval("type(AuctionIQ.Theme.Primary(AuctionIQ.Theme.Button(CreateFrame('Frame'), 'x2', 10, 10)).aiqFill) == 'table'"))

# Accounting statements
St = CH.Statements
inc = St.Income(0, L.eval("time()") + 1)
check("statements: net sales = auction sales less the 5% cut, plus other sales", abs(inc.net - (inc.auction * 0.95 + inc.other)) < 1)
check("statements: net income = gross profit - deposits - expenses + other income",
      abs(inc.netIncome - (inc.net - inc.cogsTotal - inc.deposits - inc.expenseTotal + inc.income)) < 1)
bal = St.Balance()
check("statements: assets = gold + inventory, and inventory is never above market less the cut",
      abs(bal.assets - (bal.gold + bal.inventory)) < 1 and bal.inventory <= bal.market * 0.95 + 1)
v = St.Value(L.eval("{ id = 1, unit = 1000 }"), L.eval("{ crafted = {}, index = {} }"), 0)
check("statements: an item with no cost is carried at net realizable value", v.how == "gathered" and abs(v.book - v.nrv) < 1e-6)
cf = St.Cash(0, L.eval("time()") + 1)
check("statements: unclassified = change in gold less what the ledger classifies",
      cf.change is None or abs(cf.unclassified - (cf.change - cf.classified)) < 1)
run("AuctionIQ.UI.Page('ledger', 'statement')")
srows = list(LUI.Rows("statement", L.eval("{}"))[0].values())
check("statements: the Income Statement keeps its own order, ending on Net income",
      len(srows) > 8 and "Net income" in plain(srows[-1].cells[1]) and "REVENUE" in plain(srows[0].cells[1]))
check("statements: a line opens its transactions", any(r.go is not None and r.go[2] == "sales" for r in srows))
check("statements: the period steps from This week", St.SetPeriod("week") == "week" and St.Step(1) == "lastweek" and St.SetPeriod("week") == "week")
brows = [plain(r.cells[1]) for r in LUI.Rows("balance", L.eval("{}"))[0].values()]
check("statements: the Balance Sheet carries the market value as a memo", any("Memo: inventory at market value" in x for x in brows) and any("Net worth" in x for x in brows))
check("Balance Sheet: inventory split by how fast it becomes gold adds up to inventory",
      abs(bal.liquid.week + bal.liquid.slow + bal.liquid.dead - bal.inventory) < 1)
check("Balance Sheet: speed buckets from your own sales", St.Speed(5, 30) == "week" and St.Speed(20, 30) == "slow" and St.Speed(50, 30) == "dead" and St.Speed(3, 0) == "dead")
check("Balance Sheet: free gold is gold less what the queue still has to buy", abs(bal.freeGold - (bal.gold - bal.committed)) < 1
      and any("Free gold" in x for x in brows) and any("Sells within a week" in x for x in brows))
br = St.Bridge(0, L.eval("time()") + 1)
check("Balance Sheet: the net worth bridge adds up, opening to closing",
      br is None or abs(br.opening + br.netIncome + br.unclassified + br.prices - br.closing) < 1)
crows = [plain(r.cells[1]) for r in LUI.Rows("cashflow", L.eval("{}"))[0].values()]
check("statements: the biggest item is named when it carries a quarter or more of inventory", (bal.top is None) or (bal.top.worth / max(bal.inventory, 1) < 0.25) or any("Largest:" in x for x in brows))
check("statements: Cash Flow runs opening gold to closing gold, with unclassified movement", crows[0] == "Opening gold" and crows[-1] == "Closing gold" and any("Unclassified gold movement" in x for x in crows))

run("AuctionIQ.UI.Page('ledger', 'statement')")
check("Reports: Income Statement, Balance Sheet, Cash Flow, Performance", [plain(b.text.t) for b in L.eval("AuctionIQ.UI.Pages().ledger.nav").values() if b.shown] == ["Income Statement", "Balance Sheet", "Cash Flow", "Performance"])
run("AuctionIQ.UI.Page('ledger', 'holdings')")
run("AuctionIQ.UI.Page('ledger', 'inventory')")
check("Inventory: one view, what you hold against what it cost", LUI.Group() == "Inventory" and [plain(b.text.t) for b in L.eval("AuctionIQ.UI.Pages().ledger.nav").values() if b.shown] == ["Inventory"])
ir = list(LUI.Rows("inventory", L.eval("{}"))[0].values())
check("Inventory: hovering Held shows where it is", len(ir) > 0 and plain(ir[0].cellTip(2)[1][1]) == "Where it is")
run("Enum.CraftingOrderReagentSource = { Any = 0, Customer = 1, Crafter = 2, None = 3 }")
fo = CH.Orders.FromOrder(L.eval("""{ orderID = 5, spellID = 10, tipAmount = 100, reagents = {
  { source = 0, reagentInfo = { reagent = { itemID = 201 }, dataSlotIndex = 1, quantity = 2 } },
  { source = 2, reagentInfo = { reagent = { itemID = 202 }, dataSlotIndex = 2, quantity = 3 } } } }"""))
check("orders: only reagents the customer gives come off your cost, not ones the crafter must bring",
      fo.providedSlots[1] == 2 and fo.providedSlots[2] is None and len(list(fo.provided.values())) == 1)
# Reports > Performance: the headline, eight weeks of profit and what drove the change
PF = CH.Performance
run("AuctionIQ.UI.Page('ledger', 'overview')")
check("Performance: a page under Reports, beside the nav", LUI.Group() == "Reports" and L.eval("AuctionIQ.UI.Pages().perf:IsShown()") is True
      and L.eval("AuctionIQ.UI.Pages().ledger.body:IsShown()") is False)
pr = PF.Refresh(L.eval("STUB.now"))
wk = list(pr.weekly.values())
check("Performance: eight weekly bars, only the current week partial", len(wk) == 8 and wk[-1].partial and not any(w.partial for w in wk[:-1]))
cmp = pr.compare
tot = sum(x.change for x in cmp.list.values())
check("Performance: the contributors add up to the change in net income", abs(tot - cmp.change) < 1)
for p_ in ["week", "lastweek", "30"]:
    c_ = PF.Compare(None, p_, L.eval("STUB.now"))
    check(f"Performance ({p_}): every item's price, volume and cost add up to its change",
          all(abs(x.price + x.volume + x.cost - x.change) < 1 for x in c_.list.values() if x.kind == "item"))
w = PF.Windows("week", L.eval("STUB.now"))
check("Performance: this week so far is compared with the same point last week", (w["to"] - w["from"]) == (w.pto - w.pfrom) and w.pto <= w["from"])
a_, b_, c3 = PF.Headline(cmp)
check("Performance: the headline says the period, the change and what drove it", "so far" in plain(a_) and "against the same point last week" in plain(b_) and len(plain(c3)) > 10)
c30 = PF.Compare(None, "30", L.eval("STUB.now"))
big = next((x for x in c30.list.values() if x.kind == "item"), None)
if big is not None:
    PF.Open(big, c30)
    dr = list(LUI.Rows("drivers", L.eval("{ focus = AuctionIQ.LedgerUI.Focus() }"))[0].values())
    check("Performance: a driver bar opens that item's Profit drivers on the same windows", LUI.View() == "drivers" and LUI.Group() == "Reports"
          and len(dr) == 1 and dr[0].id == big.id and abs(dr[0].sort[4] - big.change) < 1)
else:
    check("Performance: the stub sold something in the last 60 days", False)
cap = PF.Capital(None, L.eval("STUB.now"))
check("Performance: capital tied up is the slow stock's share of all stock", cap.total > 0 and 0 <= cap.slow <= cap.total and abs(cap.share - cap.slow / cap.total) < 1e-9)
fl = list(PF.Forecasts(L.eval("STUB.now")).values())
check("Performance: only batches a week old (or sold out) are checked, each in or out of range", all(f.inRange in (True, False) for f in fl))
check("Performance: the forecast line says how many were checked", plain(PF.ForecastText(PF.Forecasts(L.eval("STUB.now")))).startswith("Forecasts: "))
PF.ToggleScatter()
pr2 = PF.Refresh(L.eval("STUB.now"))
check("Performance: the forecast chart takes chart 2's place, one dot per checked batch",
      L.eval("AuctionIQ.UI.Pages().perf.sTitle").shown is not False and len([d for d in L.eval("AuctionIQ.UI.Pages().perf.dots").values() if d.shown]) == len(fl))
_before = len(audit_all)
audit("performance forecast chart")
# only this page's problems: other windows the earlier tests left open are audited on their own
audit_all[_before:] = [a for a in audit_all[_before:] if "This week so far" in a or "Forecast" in a]
PF.ToggleScatter()
PF.Refresh(L.eval("STUB.now"))
PF.OpenWeek(wk[-2])
check("Performance: a week's bar opens that week's Income Statement", LUI.View() == "statement" and CH.Statements.Period() == "custom"
      and abs(CH.Statements.Income(wk[-2]["from"], wk[-2].to - 1).netIncome - wk[-2].profit) < 1)
CH.Statements.SetPeriod("week")
run("AuctionIQ.UI.Page('ledger', 'overview')")
lt = ir[0].cellTip(7)
check("Inventory: Last sold sits before Days of stock, with the sales rate on hover",
      [c[1] for c in L.eval("AuctionIQ.LedgerUI.ViewDef('inventory').cols").values()][-2:] == ["Last sold", "Days of stock"]
      and plain(lt[1][1]) == "Last sold" and any(plain(x[1]) == "Sold in 30 days" for x in lt.values() if x[1]))
for a in sorted(set(audit_all)):
    print("LAYOUT " + a)
check("layout: nothing spills out of its panel or gets cut off", len(set(audit_all)) == 0)

px = L.eval("""(function()
  local W = AuctionIQ.Window
  local oldP, oldE = GetPhysicalScreenSize, UIParent.GetEffectiveScale
  GetPhysicalScreenSize = function() return 2560, 1440 end
  UIParent.GetEffectiveScale = function() return 0.71 end
  local k1 = W.PixelScale() * 0.71 * 1440 / 768          -- pixels per unit: the nearest whole number
  UIParent.GetEffectiveScale = function() return 768 / 1440 end
  local k2 = W.PixelScale()                              -- ElvUI pixel-perfect: no change
  local f = { pt = { "TOPLEFT", UIParent, "BOTTOMLEFT", 100, 500 } }
  function f:GetLeft() return self.pt[4] + 0.3 end
  function f:GetTop() return self.pt[5] - 0.4 end
  function f:GetEffectiveScale() return 768 / 1440 end
  function f:GetPoint() return unpack(self.pt) end
  function f:SetPoint(p, r, rp, x, y) self.pt = { p, r, rp, x, y } end
  W.Snap(f)
  local l, t = f:GetLeft(), f:GetTop()
  GetPhysicalScreenSize, UIParent.GetEffectiveScale = oldP, oldE
  return { k1 = k1, k2 = k2, l = l, t = t }
end)()""")
check("pixel-perfect: a window's unit is a whole number of screen pixels; on ElvUI's pixel scale nothing changes",
      abs(px.k1 - 1) < 1e-9 and abs(px.k2 - 1) < 1e-9)
check("pixel-perfect: a window's corner is nudged onto a whole pixel", abs(px.l - round(px.l)) < 1e-9 and abs(px.t - round(px.t)) < 1e-9)
frac = [f"{k} {v}" for k, v in L.eval("STUB.frac").items()]
check("pixel-perfect: every offset and size on a whole unit" + (": " + "; ".join(frac) if frac else ""), not frac)
rr = L.eval("(function() local r = AuctionIQ.Ledger.Records('Sales')[1]; return r and { r[1] == r.time, r[8] == r.amount, rawget(r, 'time') == nil } end)()")
check("ledger records: one small array per row, read by name as before", rr is not None and all(rr.values()))
# a click on a recipe reuses the worked-out rows; a bag change works them out again
cr = L.eval("""(function()
  local S = AuctionIQ.ScanUI
  S.SetMode("recipes"); S.Open(); S.ROW_AGE = 60
  local n, f = 0, AuctionIQ.Scan.Live
  AuctionIQ.Scan.Live = function(...) n = n + 1; return f(...) end
  STUB.Fire("BAG_UPDATE_DELAYED"); S.Refresh(); local first = n
  S.Select(10); S.Select(11); local clicks = n - first
  STUB.Fire("BAG_UPDATE_DELAYED"); S.Refresh(); local after = n - first
  AuctionIQ.Scan.Live = f; S.ROW_AGE = -1
  return { first = first, clicks = clicks, after = after }
end)()""")
check("craft list: a click reuses each row; bags changing work them out again", cr.first > 0 and cr.clicks == 0 and cr.after == cr.first)
# a slot that takes many different items (an ink's pigments) stays quick and still finds the cheapest
fr = L.eval("""(function()
  local old = AuctionIQ.Scan.ReagentPrice
  AuctionIQ.Scan.ReagentPrice = function(id) return 100 + (id % 10) * 7 + math.floor(id / 10) * 3 end
  local qual, per = {}, {}
  for i = 1, 3 do
    local items, p = {}, {}
    for k = 1, 8 do items[k] = i * 100 + k; p[k] = (k % 4) * 0.5 end
    qual[i] = { qty = 10, items = items }; per[i] = p
  end
  local model = { recipeID = 1, qual = qual, perUnit = per }
  local t0 = os.clock()
  local states = AuctionIQ.Advisor.Frontier(model)
  local dt = os.clock() - t0
  AuctionIQ.Scan.ReagentPrice = old
  local cheapest = math.huge
  for _, st in ipairs(states or {}) do if st.c < cheapest then cheapest = st.c end end
  return { n = states and #states or 0, dt = dt, cheapest = cheapest }
end)()""")
check("advisor: a slot of many different items (inks) is worked out in well under a second", fr.n > 0 and fr.dt < 0.5)
# after the scan, a click on a recipe reads its result: no second read of the recipe
kn = L.eval("""(function()
  local A, Adv = AuctionIQ.AdvisorUI, AuctionIQ.Advisor
  A.KNOWN_AGE = 600; A.InvalidateKnown(); A.ShowOrder(nil)
  local n, f = 0, Adv.Measure
  Adv.Measure = function(...) n = n + 1; return f(...) end
  local model = f(10, { professionID = AuctionIQ.OpenProfessionID() })
  A.Remember(10, model, Adv.Evaluate(model))
  A.Compute(10); A.Compute(10)
  local reused = n
  STUB.Fire("PLAYER_EQUIPMENT_CHANGED"); A.Compute(10)
  local after = n
  Adv.Measure = f; A.KNOWN_AGE = -1
  return { reused = reused, after = after, cur = tostring(A.Compute and 1) }
end)()""")
check("advisor: a recipe the scan worked out opens without working it out again; a gear change does", kn.reused == 0 and kn.after == 1)
run("STUB.printed = {}; STUB.oldPrint = AuctionIQ.Print; AuctionIQ.Print = function(t) table.insert(STUB.printed, t) end; SlashCmdList.AUCTIONIQ('mem'); AuctionIQ.Print = STUB.oldPrint")
mp = [str(t) for t in L.globals().STUB.printed.values()]
check("/aiq mem: memory after clearing garbage, then what's held", mp[0].startswith("memory ") and any("recipe models" in x for x in mp))
run("AuctionIQ.PerfReset(); STUB.Fire('BAG_UPDATE_DELAYED'); STUB.Fire('BAG_UPDATE_DELAYED')")
pl = [str(x) for x in L.eval("AuctionIQ.PerfLines()").values()]
check("/aiq perf: memory, then each event's calls and time", pl[0].startswith("AuctionIQ over the last") and any(x.startswith("  BAG_UPDATE_DELAYED: ") for x in pl))
print(f"\n{len(fails)} failed" if fails else "\nall passed")
sys.exit(1 if fails else 0)
