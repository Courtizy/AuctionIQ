# Acceptance flows, end to end through the stubbed game: what the advisor picks is what the queue
# holds, what the shopping list asks for, what the game is sent, and what the log records.
# Run from run_tests.py (shares L, run, check, plain).

# Flow 1: an ordinary batch of Test Potion (recipe 11), three crafts, plain (no Concentration).
af1 = L.eval("""(function()
  local A, Q, Lg = AuctionIQ.Advisor, AuctionIQ.Queue, AuctionIQ.Log
  local out = {}
  Q.Clear(); wipe(Q.inflight); Lg.Clear()
  local res = A.Analyze(11, { professionID = AuctionIQ.OpenProfessionID() })
  local row = res.best
  out.quality, out.conc = row.quality, row.concentration
  -- the advisor's per-craft units by item, from its picks and fixed slots
  local want = {}
  for i, slot in ipairs(res.qual) do for q, id in ipairs(slot.items) do
    local n = row.picks[i][q] or 0; if n > 0 then want[id] = (want[id] or 0) + n end end end
  for _, slot in ipairs(res.fixed) do want[slot.items[1]] = (want[slot.items[1]] or 0) + slot.qty end
  for _, f in ipairs(row.finishing or {}) do want[f.itemID] = (want[f.itemID] or 0) + 1 end
  local e = Q.Add(res, row, 3)
  out.qty = e.qty
  out.sameQuality = e.quality == row.quality and (e.concentration == nil) == (row.concentration == nil)
  -- shopping list: per-craft units x 3, item for item
  local shop = Q.ShoppingList({ e })
  local shopOk, nShop = true, 0
  for _, s in ipairs(shop) do nShop = nShop + 1; if s.need ~= (want[s.itemID] or -1) * 3 then shopOk = false end end
  for id in pairs(want) do local seen = false; for _, s in ipairs(shop) do if s.itemID == id then seen = true end end; if not seen then shopOk = false end end
  out.shopOk = shopOk
  -- craft: everything on hand; the game gets exactly the queued reagents for 3 crafts
  local oldCount = C_Item.GetItemCount
  C_Item.GetItemCount = function() return 999 end
  STUB.crafted = nil
  out.sent = Q.Craft(e, 3)
  local c = STUB.crafted
  out.n, out.sentConc = c and c.n, c and c.conc
  local sentOk = c ~= nil
  local got = {}
  for _, r in ipairs(c and c.reagents or {}) do got[r.reagent.itemID] = (got[r.reagent.itemID] or 0) + r.quantity end
  for _, r in ipairs(e.reagents) do if got[r.itemID] ~= r.n then sentOk = false end end
  out.sentOk = sentOk
  -- the log matched the craft to the advisor row it came from
  local p = Lg.Pending()
  out.logCost, out.logExpected = p and p.cost, p and p.expected
  out.rowCost, out.rowProfit = row.cost, row.profit
  -- three crafts finish: each takes one off the queue and logs a result
  for i = 1, 3 do
    STUB.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 11)
    STUB.Fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { recipeID = 11, itemID = row.item, quantity = 2 })
  end
  out.left = Q.Count()
  local log = AuctionIQ.Me().log[11]
  out.crafts, out.cost, out.expected = log and log.crafts, log and log.cost, log and log.expected
  out.inflight = Q.OpenRequests()
  C_Item.GetItemCount = oldCount
  Q.Clear(); Lg.Clear()
  return out
end)()""")
check("acceptance 1 (batch): the queue keeps the advisor's quality and Concentration choice, 3 crafts", af1.qty == 3 and af1.sameQuality)
check("acceptance 1 (batch): the shopping list asks for the advisor's units of each reagent, times 3", af1.shopOk)
check("acceptance 1 (batch): the game is sent exactly the queued reagents, 3 crafts, Concentration as picked",
      af1.sent and af1.sentOk and af1.n == 3 and bool(af1.sentConc) == (af1.conc is not None))
check("acceptance 1 (batch): the log matches the craft to its advisor row (same cost and profit)",
      af1.logCost == af1.rowCost and af1.logExpected == af1.rowProfit)
check("acceptance 1 (batch): three finished crafts empty the entry and log 3 crafts at 3x the forecast",
      af1.left == 0 and af1.inflight == 0 and af1.crafts == 3 and abs(af1.cost - 3 * af1.rowCost) < 1e-6 and abs(af1.expected - 3 * af1.rowProfit) < 1e-6)

# Flow 2: a partly supplied enchant work order: claim, craft into the order, turn in.
af2 = L.eval("""(function()
  local ui, Q, Lg = C_TradeSkillUI, AuctionIQ.Queue, AuctionIQ.Log
  local out = {}
  local oldInfo, oldSch, oldCount, oldCO, oldCR, oldCE = ui.GetRecipeInfo, ui.GetRecipeSchematic, C_Item.GetItemCount, C_CraftingOrders, ui.CraftRecipe, ui.CraftEnchant
  ui.GetRecipeInfo = function(id) local i = oldInfo(id); if id == 10 and i then local c = {}; for k, v in pairs(i) do c[k] = v end
    c.qualityItemIDs = nil; c.isEnchantingRecipe = true; return c end; return i end
  ui.GetRecipeSchematic = function(id, ...) local sch = oldSch(id, ...); if id == 10 and sch then local c = {}; for k, v in pairs(sch) do c[k] = v end; c.outputItemID = nil; return c end; return sch end
  STUB.craftingDataID = 3837
  STUB.prices["i:244030"] = { formula_value = 500 * 10000, sold = 5 }; STUB.prices["i:244031"] = { formula_value = 900 * 10000, sold = 5 }
  Q.Clear(); wipe(Q.inflight); Lg.Clear()
  -- the customer gives 3 of the 4 in slot 1 (rank 2, item 202)
  local order = { orderID = 500, spellID = 10, minQuality = 1, tipAmount = 300000, consortiumCut = 30000, customerName = 'Pat',
    reagents = { { reagentInfo = { reagent = { itemID = 202 }, quantity = 3, dataSlotIndex = 1 } } } }
  local claimed
  C_CraftingOrders = { GetCrafterOrders = function() return { order } end, GetClaimedOrder = function() return claimed end,
    ClaimOrder = function(id) out.claimCalls = (out.claimCalls or 0) + 1 end,
    FulfillOrder = function(id) out.fulfilled = id end }
  AuctionIQ.Orders.Live = function(id) return tostring(id) == '500' and order or nil end
  local res = AuctionIQ.Orders.Analyze(order)
  local row = res.best
  out.hasRow = row ~= nil
  -- the plan the advisor made: no vellum (an order's enchant goes to the customer), 1 more of slot 1
  local slot1 = 0
  for i, slot in ipairs(res.qual) do if slot.index == 1 then for q in ipairs(slot.items) do slot1 = slot1 + (row.picks[i][q] or 0) end end end
  out.slot1 = slot1
  local e = Q.Add(res, row, 1, { orderID = 500, customer = 'Pat' })
  local vellum = false
  for _, s in ipairs(e.shop) do if s.itemID == 38682 then vellum = true end end
  out.vellum = vellum
  -- Queue all twice: still one entry
  Q.Add(res, row, 1, { orderID = 500 })
  out.entries = #AuctionIQ.db.queue
  -- claim, then the game's answer; a duplicate late answer changes nothing
  out.step1 = Q.OrderStep(e)
  Q.Craft(e)
  out.pendingClaim = Q.OrderStep(e)
  out.claimAgain = Q.Craft(e)
  claimed = { orderID = 500, isFulfillable = false, minQuality = 1, reagents = order.reagents }
  STUB.Fire("CRAFTINGORDERS_CLAIM_ORDER_RESPONSE", 0, 500)
  STUB.Fire("CRAFTINGORDERS_CLAIM_ORDER_RESPONSE", 0, 500)
  out.step2 = Q.OrderStep(e)
  -- craft: into the order with CraftRecipe (as CraftSim), never CraftEnchant, and only the crafter's part
  C_Item.GetItemCount = function() return 999 end
  local sent
  ui.CraftRecipe = function(id, n, reagents, _, orderID, conc) sent = { id = id, n = n, reagents = reagents, orderID = orderID, conc = conc } end
  ui.CraftEnchant = function() out.enchantCalled = true end
  local ok, why = Q.Craft(e)
  out.craftOk, out.craftWhy = ok, why
  if not ok and why and why:find("Press again") then ok, why = Q.Craft(e); out.craftOk, out.craftWhy = ok, why end
  local mine202 = 0
  for _, r in ipairs(sent and sent.reagents or {}) do if r.reagent.itemID == 202 or r.reagent.itemID == 201 then mine202 = mine202 + r.quantity end end
  out.sentOrder, out.mineSlot1 = sent and sent.orderID, mine202
  out.step3 = Q.OrderStep(e)
  claimed.isFulfillable = true
  STUB.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 10)
  STUB.RunTimers()
  out.step4 = Q.OrderStep(e)
  -- turn in: a failed answer keeps it; then a good one removes it
  Q.Craft(e)
  STUB.Fire("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 1, 500)
  out.afterFail = Q.OrderStep(e)
  out.stillQueued = Q.ForOrder(500) ~= nil
  Q.Craft(e)
  STUB.Fire("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 500)
  out.gone = Q.ForOrder(500) == nil
  ui.GetRecipeInfo, ui.GetRecipeSchematic, C_Item.GetItemCount, C_CraftingOrders, ui.CraftRecipe, ui.CraftEnchant = oldInfo, oldSch, oldCount, oldCO, oldCR, oldCE
  STUB.craftingDataID = nil
  Q.Clear(); wipe(Q.inflight); Lg.Clear()
  return out
end)()""")
check("acceptance 2 (enchant order): the advisor plans the crafter's 1 of slot 1 (customer gives 3 of 4), no vellum for an order",
      af2.hasRow and af2.slot1 == 1 and not af2.vellum)
check("acceptance 2 (enchant order): queueing the order twice keeps one entry", af2.entries == 1)
check("acceptance 2 (enchant order): Claim, then Claiming... until the game answers, and a second press doesn't claim again",
      af2.step1 == "Claim" and af2.pendingClaim == "Claiming..." and not af2.claimAgain and af2.claimCalls == 1)
check("acceptance 2 (enchant order): once the game confirms (even twice), the step is Craft", af2.step2 == "Craft")
check("acceptance 2 (enchant order): the craft goes into the order with CraftRecipe and only the crafter's 1 of slot 1",
      af2.craftOk and af2.sentOrder == 500 and af2.mineSlot1 == 1 and not af2.enchantCalled)
check("acceptance 2 (enchant order): Crafting... then Turn in once the game says it can be", af2.step3 == "Crafting..." and af2.step4 == "Turn in")
check("acceptance 2 (enchant order): a refused turn-in keeps the order at Turn in; an accepted one removes it",
      af2.afterFail == "Turn in" and af2.stillQueued and af2.gone)

# The same flows with failures injected.
af3 = L.eval("""(function()
  local A, Q, Lg = AuctionIQ.Advisor, AuctionIQ.Queue, AuctionIQ.Log
  local out = {}
  Q.Clear(); wipe(Q.inflight); Lg.Clear()
  local res = A.Analyze(11, { professionID = AuctionIQ.OpenProfessionID() })
  local e = Q.Add(res, res.best, 3)
  local oldCount = C_Item.GetItemCount
  C_Item.GetItemCount = function() return 999 end
  Q.Craft(e, 3)
  STUB.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 11)
  -- the player moves: the rest of the batch stops
  STUB.Fire("UNIT_SPELLCAST_INTERRUPTED", "player", "cast", 11)
  out.left, out.inflight = e.qty, Q.OpenRequests()
  -- a late success after the interrupt debits nothing
  STUB.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 11)
  out.leftLate = e.qty
  -- pressing Craft again sends the remaining two
  STUB.crafted = nil
  out.resend = Q.Craft(e, e.qty)
  out.resendN = STUB.crafted and STUB.crafted.n
  -- the game refuses to start it (FAILED): nothing debited, Craft can be pressed again
  STUB.Fire("UNIT_SPELLCAST_FAILED", "player", "cast", 11)
  out.afterFail, out.inflight2 = e.qty, Q.OpenRequests()
  -- reagents run out between presses: Craft stops and names it
  C_Item.GetItemCount = function(id) return 0 end
  local ok, why = Q.Craft(e, 2)
  out.shortOk, out.shortWhy = ok, why
  C_Item.GetItemCount = oldCount
  Q.Clear(); wipe(Q.inflight); Lg.Clear()
  return out
end)()""")
check("failure 1 (batch): an interrupt after one craft leaves two queued and nothing in flight; a late success debits nothing",
      af3.left == 2 and af3.inflight == 0 and af3.leftLate == 2)
check("failure 1 (batch): pressing Craft again sends the remaining two; a refused start debits nothing and frees the button",
      af3.resend and af3.resendN == 2 and af3.afterFail == 2 and af3.inflight2 == 0)
check("failure 1 (batch): reagents gone between presses stop Craft before the game, named", not af3.shortOk and "have 0" in (af3.shortWhy or ""))
af4 = L.eval("""(function()
  local Q = AuctionIQ.Queue
  local out = {}
  local oldCO, oldLive = C_CraftingOrders, AuctionIQ.Orders.Live
  Q.Clear(); wipe(Q.inflight)
  local order = { orderID = 501, spellID = 10, minQuality = 1, reagents = {} }
  local claimed
  C_CraftingOrders = { GetCrafterOrders = function() return { order } end, GetClaimedOrder = function() return claimed end,
    ClaimOrder = function() end, FulfillOrder = function() end }
  AuctionIQ.Orders.Live = function(id) return tostring(id) == '501' and order or nil end
  local res = AuctionIQ.Orders.Analyze(order)
  local e = Q.Add(res, res.best, 1, { orderID = 501 })
  -- a rejected claim goes back to Claim
  Q.Craft(e)
  STUB.Fire("CRAFTINGORDERS_CLAIM_ORDER_RESPONSE", 7, 501)
  out.afterReject = Q.OrderStep(e)
  -- no answer at all: after the timeout it can be pressed again
  Q.Craft(e)
  e.pendingAt = e.pendingAt - 60
  out.afterTimeout = Q.OrderStep(e)
  -- claimed, then the claim is lost (released or expired): Craft says so and the order goes back to Claim
  Q.Craft(e)
  claimed = { orderID = 501, isFulfillable = false, reagents = {} }
  STUB.Fire("CRAFTINGORDERS_CLAIM_ORDER_RESPONSE", 0, 501)
  out.claimed = Q.OrderStep(e)
  claimed = nil
  STUB.Fire("CRAFTINGORDERS_CLAIMED_ORDER_REMOVED")
  out.afterLost = Q.OrderStep(e)
  local ok, why = Q.Craft(e)
  out.craftAfterLost = Q.OrderStep(e)
  -- the order vanishes from the list: Claim says to fetch again
  e.pending, e.pendingAt = nil, nil -- the re-claim above lapsed
  AuctionIQ.Orders.Live = function() return nil end
  local ok2, why2 = Q.Craft(e)
  out.goneWhy = why2
  C_CraftingOrders, AuctionIQ.Orders.Live = oldCO, oldLive
  Q.Clear(); wipe(Q.inflight)
  return out
end)()""")
check("failure 2 (order): a rejected claim goes back to Claim; an unanswered one can be retried after the timeout",
      af4.afterReject == "Claim" and af4.afterTimeout == "Claim")
check("failure 2 (order): a lost claim takes the order back to Claim, never to Turn in", af4.claimed == "Craft" and af4.afterLost == "Claim")
check("failure 2 (order): an order no longer listed can't be claimed, and says to fetch again", "fetch" in (af4.goneWhy or ""))

# Ledger: TSM adding records at the end parses only the new lines, with the same result as a full parse
inc = L.eval("""(function()
  local key = "r@" .. GetRealmName() .. "@internalData@csvSales"
  local old = TradeSkillMasterDB
  local head = "itemString,stackSize,quantity,price,otherPlayer,player,time,source"
  local a = head .. "\\ni:301,1,1,100,B,Courtizy,1000,Auction\\ni:302,1,2,200,B,Luxaren,2000,Auction"
  TradeSkillMasterDB = { [key] = a }
  local r1 = AuctionIQ.Ledger.Records("Sales")
  TradeSkillMasterDB = { [key] = a .. "\\ni:303,1,3,300,B,Courtizy,3000,Auction" }
  local r2 = AuctionIQ.Ledger.Records("Sales")
  local out = { n1 = #r1, n2 = #r2, newList = r1 ~= r2, last = r2[3] and r2[3].id, q = r2[3] and r2[3].quantity, first = r2[1].id }
  TradeSkillMasterDB = { [key] = head .. "\\ni:309,1,1,1,B,Courtizy,9,Auction" } -- rewritten, not appended
  local r3 = AuctionIQ.Ledger.Records("Sales")
  out.rewritten = #r3 == 1 and r3[1].id == 309
  TradeSkillMasterDB = old
  return out
end)()""")
check("ledger: records TSM appends are parsed on their own into a new list, same as a full parse; a rewrite parses in full",
      inc.n1 == 2 and inc.n2 == 3 and inc.newList and inc.last == 303 and inc.q == 3 and inc.first == 301 and inc.rewritten)

# Ledger: the background parse after login spreads the work over frames and gives the same records
bg = L.eval("""(function()
  local key = "r@" .. GetRealmName() .. "@internalData@csvSales"
  local old = TradeSkillMasterDB
  local t = { "itemString,stackSize,quantity,price,otherPlayer,player,time,source" }
  for i = 1, 2500 do t[#t + 1] = "i:" .. (300 + i % 40) .. ",1," .. (1 + i % 3) .. "," .. (i * 10) .. ",B,Courtizy," .. (1000 + i) .. ",Auction" end
  t[#t + 1] = "i:999,1,1,5,B,Courtizy,1" -- a short line still parses
  local text = table.concat(t, "\\n")
  TradeSkillMasterDB = { [key] = text }
  AuctionIQ.Ledger.ClearStats()
  local sync = AuctionIQ.Ledger.Records("Sales")
  local ref = {}
  for i, r in ipairs(sync) do ref[i] = r.id .. ":" .. r.quantity .. ":" .. r.time end
  AuctionIQ.Ledger.ClearStats()
  local frames, finished = 0, false
  AuctionIQ.Ledger.Warm({ "Sales" }, function() finished = true end, 1000)
  while not finished and frames < 50 do frames = frames + 1; STUB.RunTimers() end
  local rows = AuctionIQ.Ledger.Records("Sales")
  local same = #rows == #ref
  for i, r in ipairs(rows) do if ref[i] ~= r.id .. ":" .. r.quantity .. ":" .. r.time then same = false end end
  -- a caller that needs the records mid-parse finishes it then and there
  AuctionIQ.Ledger.ClearStats()
  AuctionIQ.Ledger.Warm({ "Sales" }, nil, 1000)
  local mid = AuctionIQ.Ledger.Records("Sales")
  STUB.RunTimers(); STUB.RunTimers(); STUB.RunTimers()
  local after = AuctionIQ.Ledger.Records("Sales")
  TradeSkillMasterDB = old
  AuctionIQ.Ledger.ClearStats()
  return { frames = frames, finished = finished, same = same, n = #rows, mid = #mid, stable = mid == after }
end)()""")
check("ledger: the login parse runs 1,000 lines a frame over several frames, with the same records as parsing at once",
      bg.finished and bg.frames >= 2 and bg.same and bg.n == 2501)
check("ledger: asking for the records mid-parse finishes the parse right away; the background parse then leaves it alone",
      bg.mid == 2501 and bg.stable)

# Settings: a custom source another source or an operation uses can't be deleted out from under it
dep = L.eval("""(function()
  local S = AuctionIQ.Settings
  S.SetSource("audit_one", "10g"); S.SetSource("audit_two", "audit_one * 2"); S.SetSource("audit_three", "audit_onex")
  local ok1, why1 = S.DeleteSource("audit_one")
  local still = AuctionIQ.Formula.Custom().audit_one ~= nil
  S.DeleteSource("audit_two")
  local ok2 = S.DeleteSource("audit_one")
  S.DeleteSource("audit_three")
  return { ok1 = ok1, why1 = why1 or "", still = still, ok2 = ok2 }
end)()""")
check("settings: deleting a source another source uses is refused and names the user; once unused it deletes",
      dep.ok1 == False and "audit_two" in dep.why1 and "audit_three" not in dep.why1 and dep.still and dep.ok2)

# SavedVariables: older and incomplete data loads without errors
sv = L.eval("""(function()
  local Q = AuctionIQ.Queue
  local out = {}
  local saved = AuctionIQ.db.queue
  AuctionIQ.db.queue = {
    { char = AuctionIQ.CharacterKey(), recipeID = 11, name = 'No shop', reagents = { { itemID = 211, slot = 1, n = 3 } }, qty = 2 },
    { char = AuctionIQ.CharacterKey(), recipeID = 11, name = 'No reagents', shop = { { itemID = 211, n = 3 } }, qty = 1 },
    { char = 'Gone-Realm', recipeID = 999999, qty = 1 },
    { orderID = 12345678901234, recipeID = 10, qty = 1, pending = 'claim', pendingAt = 999999999, stage = 'claimed' },
  }
  local before = #AuctionIQ.db.queue
  AuctionIQ.Tidy(AuctionIQ.db) -- what a /reload does with them
  out.kept = #AuctionIQ.db.queue
  local function try(name, f, ...) local ok, err = pcall(f, ...); if not ok then out[#out + 1] = name .. ": " .. tostring(err) end end
  try("ShoppingList", Q.ShoppingList)
  try("Budget", Q.Budget)
  try("Readiness", Q.Readiness)
  try("Count", Q.Count)
  try("NextStep", Q.NextStep)
  for i, e in ipairs(AuctionIQ.db.queue) do
    try("OrderStep " .. i, Q.OrderStep, e)
    try("Craft " .. i, Q.Craft, e, 1)
  end
  if AuctionIQ.QueueUI and AuctionIQ.QueueUI.Refresh then try("QueueUI.Refresh", AuctionIQ.QueueUI.Refresh) end
  local o = AuctionIQ.db.queue[4]
  out.pendingCleared = o and o.pending == nil and o.orderID == '12345678901234'
  AuctionIQ.db.queue = saved
  return out
end)()""")
errs = [str(v) for k, v in sv.items() if isinstance(k, int)]
print("\n".join("  " + e for e in errs))
check("saved data: queue entries from older builds (no shop, no reagents, gone recipe, huge order ID) don't error anywhere", not errs)
check("saved data: a pending step saved in another session is cleared on load; order IDs kept as text", sv.pendingCleared)
mg = L.eval("""(function()
  local now = time()
  local db = { version = 1, mail = { routes = {} }, queue = {}, batches = {} }
  for i = 1, 6000 do db.batches[i] = { at = now - (6000 - i) * 3600 } end
  db.batches[1].at = now - 400 * 86400
  AuctionIQ.Tidy(AuctionIQ.Migrate(db), now)
  local small = { queue = {}, batches = { { at = now - 400 * 86400 }, { at = now - 200 * 86400 }, { at = now } } }
  AuctionIQ.Tidy(small, now)
  return { v = db.version, mail = db.mail == nil, n = #db.batches, newest = db.batches[#db.batches].at == now,
    old = #small.batches, oldestDays = (now - small.batches[1].at) / 86400 }
end)()""")
check("saved data: version 1 migrates to 2 (mail removed); craft records are capped at 5000, oldest first",
      mg.v == 2 and mg.mail and mg.n == 5000 and mg.newest)
check("saved data: craft records have no age limit (CraftSim's rule): a 400-day-old batch under the cap stays",
      mg.old == 3 and mg.oldestDays == 400)

# Trade: Ready to post separates what's in this character's bags from what has to be fetched
pf = L.eval("""(function()
  local lines = AuctionIQ.TradingUI.PostLines({ id = 302, held = 10, here = 3, fetch = 7, up = 0, cap = 10, post = 10, price = 10000 },
    { action = "post", qty = 6, reason = "it sells" })
  local t = {}
  for _, l in ipairs(lines) do t[#t + 1] = tostring(l[1]) .. " " .. tostring(l[2] or "") end
  return table.concat(t, "\\n")
end)()""")
check("trade: posting advice says how many are in your bags and to fetch the rest first", "In your bags now" in pf and "Fetch 3 first" in plain(pf))

# Accounting: excluding a character takes their sales out of the Cash statement, as it does their gold
cs = L.eval("""(function()
  local L = AuctionIQ.Ledger
  local now = STUB.now
  local key = "r@" .. GetRealmName() .. "@internalData@csvSales"
  local old = TradeSkillMasterDB
  TradeSkillMasterDB = { [key] = "itemString,stackSize,quantity,price,otherPlayer,player,time,source\\ni:301,1,1,100000,B,Courtizy," .. (now - 100) .. ",Auction\\ni:301,1,1,500000,B,Luxaren," .. (now - 100) .. ",Auction" }
  local all = AuctionIQ.Statements.Cash(now - 1000, now).inflows.auction
  L.SetIncluded("Luxaren", false)
  local some = AuctionIQ.Statements.Cash(now - 1000, now).inflows.auction
  local one = AuctionIQ.Statements.Cash(now - 1000, now, "Luxaren").inflows.auction
  L.SetIncluded("Luxaren", true)
  TradeSkillMasterDB = old
  return { all = all, some = some, one = one }
end)()""")
check("accounting: an excluded character's sales leave the Cash statement (same scope as the gold series); naming them still shows theirs",
      cs.all == 570000 and cs.some == 95000 and cs.one == 475000)

# Failure flows on one request at a time: every click is its own request, results go to the request
# that made them, and the game's duplicate or out-of-order events don't move the counts.
af9 = L.eval("""(function()
  local A, Q, Lg = AuctionIQ.Advisor, AuctionIQ.Queue, AuctionIQ.Log
  local out = {}
  local oldCount = C_Item.GetItemCount
  C_Item.GetItemCount = function() return 999 end
  local function batch(n)
    Q.Clear(); wipe(Q.inflight); Lg.Clear()
    local res = A.Analyze(11, { professionID = AuctionIQ.OpenProfessionID() })
    local e = Q.Add(res, res.best, n); Q.Craft(e, n)
    return e, res.best
  end
  local function done(item, guid)
    STUB.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", guid or "cast", 11)
    STUB.Fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { recipeID = 11, itemID = item, quantity = 1 })
  end
  -- 1. the game's Craft button pressed for another recipe mid-batch, refused
  local e, row = batch(3)
  done(row.item)
  C_TradeSkillUI.CraftRecipe(10, 1); STUB.Fire("UNIT_SPELLCAST_FAILED", "player", "cast", 10)
  done(row.item); done(row.item)
  local l11 = AuctionIQ.Me().log[11]
  out.other = { crafts = l11.crafts, expected = l11.expected, want = 3 * row.profit, wrong = AuctionIQ.Me().log[10] ~= nil, left = Q.Count() }
  -- 2. the same recipe's button pressed again mid-batch, refused
  e, row = batch(3)
  done(row.item)
  C_TradeSkillUI.CraftRecipe(11, 1); STUB.Fire("UNIT_SPELLCAST_FAILED", "player", "cast", 11)
  done(row.item); done(row.item)
  l11 = AuctionIQ.Me().log[11]
  out.same = { crafts = l11.crafts, expected = l11.expected, want = 3 * row.profit, left = Q.Count(), open = Q.OpenRequests() }
  -- 3. a result before its cast's success event
  e, row = batch(2)
  STUB.Fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { recipeID = 11, itemID = row.item, quantity = 1 })
  STUB.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 11)
  done(row.item)
  l11 = AuctionIQ.Me().log[11]
  out.late = { crafts = l11.crafts, expected = l11.expected, want = 2 * row.profit, left = Q.Count() }
  -- 4. one cast's success reported twice (same cast GUID)
  e, row = batch(3)
  STUB.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3-1-1-11-AAAA", 11)
  STUB.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3-1-1-11-AAAA", 11)
  out.dup = Q.Count()
  C_Item.GetItemCount = oldCount
  Q.Clear(); wipe(Q.inflight); Lg.Clear()
  return out
end)()""")
check("failure 9 (requests): a refused click on another recipe mid-batch logs nothing under it; the batch keeps its 3 crafts and forecast",
      af9.other.crafts == 3 and abs(af9.other.expected - af9.other.want) < 1e-6 and not af9.other.wrong and af9.other.left == 0)
check("failure 9 (requests): a refused second click on the same recipe doesn't cancel the batch: the queue still counts its crafts",
      af9.same.crafts == 3 and abs(af9.same.expected - af9.same.want) < 1e-6 and af9.same.left == 0 and af9.same.open == 0)
check("failure 9 (requests): a result that lands before its cast's success still goes to that batch",
      af9.late.crafts == 2 and abs(af9.late.expected - af9.late.want) < 1e-6 and af9.late.left == 0)
check("failure 9 (requests): one cast reported twice takes one craft off the queue", af9.dup == 2)

# Queue lifecycle: a /reload in the middle of a batch, and work orders that time out, get released or
# disappear while you're away. The queue is saved; what was on its way to the game isn't.
af10 = L.eval("""(function()
  local A, Q, Lg, O = AuctionIQ.Advisor, AuctionIQ.Queue, AuctionIQ.Log, AuctionIQ.Orders
  local out = {}
  local oldCount, oldCO, oldLive = C_Item.GetItemCount, C_CraftingOrders, O.Live
  C_Item.GetItemCount = function() return 999 end
  local function reload()
    -- what a /reload keeps is the saved queue: requests in flight and the log's pending craft go
    wipe(Q.inflight); Lg.Forget(Lg.Pending())
    AuctionIQ.db = AuctionIQ.Tidy(AuctionIQ.db)
  end
  -- 1. a batch of 5, reloaded after 2: 3 stay queued, the next click sends those 3, the log keeps all 5
  Q.Clear(); wipe(Q.inflight); Lg.Clear()
  local res = A.Analyze(11, { professionID = AuctionIQ.OpenProfessionID() })
  local e = Q.Add(res, res.best, 5)
  local sent = {}
  local oldCR = C_TradeSkillUI.CraftRecipe
  C_TradeSkillUI.CraftRecipe = function(id, n, ...) sent[#sent + 1] = n; return oldCR(id, n, ...) end
  Q.Craft(e, 5)
  for _ = 1, 2 do
    STUB.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 11)
    STUB.Fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { recipeID = 11, itemID = res.best.item, quantity = 1 })
  end
  reload()
  e = AuctionIQ.db.queue[1]
  out.batch = { left = e and e.qty, open = Q.OpenRequests() }
  local ok = Q.Craft(e, e.qty)
  for _ = 1, 3 do
    STUB.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 11)
    STUB.Fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { recipeID = 11, itemID = res.best.item, quantity = 1 })
  end
  out.batch.resent, out.batch.sent2, out.batch.after, out.batch.crafts = ok, sent[2], Q.Count(), AuctionIQ.Me().log[11].crafts
  C_TradeSkillUI.CraftRecipe = oldCR
  -- orders: entries as the queue saves them
  Q.Clear(); wipe(Q.inflight); Lg.Clear()
  local listed, claimed = {}, nil
  C_CraftingOrders = { GetCrafterOrders = function() return listed end, GetClaimedOrder = function() return claimed end,
    ClaimOrder = function() end, FulfillOrder = function() end }
  O.Live = function(id) for _, o in ipairs(listed) do if tostring(o.orderID) == tostring(id) then return o end end end
  local me = AuctionIQ.CharacterKey()
  local function order(id, extra)
    local x = { recipeID = 11, name = "Order " .. id, char = me, qty = 1, reagents = {}, shop = { { itemID = 201, n = 2 } }, profit = 1000, orderID = tostring(id), profession = 3 }
    for k, v in pairs(extra or {}) do x[k] = v end
    return Q.AddEntry(x, 1)
  end
  -- 2. reloaded while crafting into a claimed order: the game says it's done, so Turn in
  local a = order(601, { stage = "claimed", pending = "craft", pendingAt = Q.Now() })
  claimed = { orderID = 601, isFulfillable = true }
  reload()
  out.midCraft = Q.OrderStep(a)
  -- 3. claimed, then the claim timed out while you were away: a fetch lists it again, so Claim
  claimed = nil
  local b = order(602, { stage = "claimed" })
  -- 4. gone from the board and not claimed: marked, never bought for, skipped by Next, removed on click
  local c = order(603)
  -- 5. another profession's order: a fetch of this one doesn't touch it
  local d = order(604, { profession = 9 })
  listed = { { orderID = 602, expirationTime = time() + 3600 } }
  local fetched = { ["602"] = listed[1] }
  out.before = { b = Q.OrderStep(b), c = Q.OrderStep(c) }
  out.changed = Q.Reconcile(fetched, 3)
  out.after = { a = Q.OrderStep(a), b = Q.OrderStep(b), c = Q.OrderStep(c), d = Q.OrderStep(d), bExpires = b.expires == listed[1].expirationTime }
  local need = 0
  for _, s in ipairs(Q.ShoppingList()) do if s.itemID == 201 then need = s.need end end
  out.need201 = need -- 602 and 604 still need theirs (2 each); 601 and 603 need none
  local nx = Q.NextStep()
  out.nextNotGone = nx ~= c
  out.active = #Q.Active()
  -- 6. past its expiry time with no fetch since: Remove too
  local f = order(605, { expires = time() - 1 })
  out.expired = { step = Q.OrderStep(f), why = Q.Lapsed(f) }
  local rmOk = Q.Craft(c)
  Q.Craft(f)
  out.removed = Q.ForOrder(603) == nil and Q.ForOrder(605) == nil and Q.ForOrder(602) ~= nil
  out.rmOk = rmOk
  -- 7. a full fetch reconciles; one that doesn't hear back from every kind of order leaves the queue alone
  local g = order(606, { stage = "claimed" })
  local fail = false
  C_CraftingOrders.RequestCrafterOrders = function(t)
    STUB.Fire("CRAFTINGORDERS_CAN_REQUEST")
    t.callback(fail and t.orderType == 0 and 5 or 0)
  end
  listed = {}
  fail = true
  O.Fetch(); STUB.RunTimers(); STUB.RunTimers()
  out.partial = Q.OrderStep(g)
  fail = false
  O.Fetch(); STUB.RunTimers(); STUB.RunTimers()
  out.full = Q.OrderStep(g)
  C_Item.GetItemCount, C_CraftingOrders, O.Live = oldCount, oldCO, oldLive
  Q.Clear(); wipe(Q.inflight); Lg.Clear()
  return out
end)()""")
check("lifecycle 10 (reload): a batch of 5 reloaded after 2 keeps 3 queued with nothing left in flight",
      af10.batch.left == 3 and af10.batch.open == 0)
check("lifecycle 10 (reload): the next click sends the 3 left; the queue empties and the log has all 5 crafts",
      af10.batch.resent and af10.batch.sent2 == 3 and af10.batch.after == 0 and af10.batch.crafts == 5)
check("lifecycle 10 (reload): reloaded mid-craft into an order, the step follows the game: Turn in", af10.midCraft == "Turn in")
check("lifecycle 10 (orders): a claim that timed out while away goes back to Claim once a fetch lists it again",
      af10.before.b == "Craft" and af10.after.b == "Claim" and af10.after.bExpires)
check("lifecycle 10 (orders): an order neither listed nor claimed is marked gone (as is a crafted one whose turn-in answer a reload lost); another profession's is untouched",
      af10.before.c == "Claim" and af10.after.c == "Remove" and af10.after.a == "Remove" and af10.after.d == "Claim" and af10.changed == 3)
check("lifecycle 10 (orders): a gone order needs no reagents, isn't the next step and drops out of the totals",
      af10.need201 == 4 and af10.nextNotGone and af10.active == 2)
check("lifecycle 10 (orders): past its expiry time an order is Expired; clicking a gone or expired order removes only it",
      af10.expired.step == "Remove" and af10.expired.why == "expired" and af10.removed and af10.rmOk)
check("lifecycle 10 (orders): a fetch that misses a kind of order changes nothing; a full one reconciles",
      af10.partial == "Craft" and af10.full == "Remove")
