-- Craft queue and shopping list, across the whole warband. Entries come from the crafting advisor:
-- each keeps the advisor's reagent picks and whether to use Concentration, so crafting from the
-- queue uses exactly what the advisor recommended.
local _, CH = ...

local Q = {}
CH.Queue = Q

local function list() return CH.db.queue end

local function have(id)
	if not C_Item or not C_Item.GetItemCount then return 0 end
	return C_Item.GetItemCount(id, true, false, true, true) or 0 -- bags, bank, reagent bank, warband bank
end

-- The exact craft an entry is: its reagents (item, slot and count, finishing ones included) and its
-- Concentration, so two mixes that reach the same quality stay two entries with their own forecasts.
local function mixOf(e)
	local parts = {}
	for _, r in ipairs(e.reagents or {}) do parts[#parts + 1] = string.format("%s@%s*%s", tostring(r.itemID), tostring(r.slot), tostring(r.n)) end
	table.sort(parts)
	return table.concat(parts, ",")
end
Q.MixOf = mixOf

local function keyOf(e)
	return table.concat({ e.char, e.recipeID, e.quality, e.concentration and tostring(e.concentration) or "", e.orderID and tostring(e.orderID) or "", mixOf(e) }, ":")
end

--- Turn an advisor row into a queue entry for this character.
function Q.FromRow(result, r)
	local reagents, shop = {}, {}
	for i, slot in ipairs(result.qual) do
		for q, id in ipairs(slot.items) do
			local n = r.picks[i][q] or 0
			if n > 0 then
				table.insert(reagents, { itemID = id, slot = slot.index, n = n })
				table.insert(shop, { itemID = id, n = n, rank = q, tiers = #slot.items })
			end
		end
	end
	for _, slot in ipairs(result.fixed) do table.insert(shop, { itemID = slot.items[1], n = slot.qty }) end
	for _, f in ipairs(r.finishing or {}) do
		table.insert(reagents, { itemID = f.itemID, slot = f.slot, n = 1 })
		table.insert(shop, { itemID = f.itemID, n = 1 })
	end
	-- what the customer gives, as the advisor planned it: the craft supplies only the rest
	local given
	for _, g in ipairs(result.order and result.order.provided or {}) do
		given = given or {}
		given[g.itemID] = (given[g.itemID] or 0) + (g.quantity or 0)
	end
	local me = CH.Me()
	return { given = given,
		char = CH.CharacterKey(), charName = me.name, class = me.class,
		recipeID = result.recipeID, name = result.name, quality = r.quality, tiers = result.model and result.model.maxQ,
		concentration = r.concentration, profit = r.profit, cost = r.cost, item = r.item,
		-- Ingenuity: the chance a Concentration craft refunds, and how many points it gives back
		ingenuity = r.concentration and r.ingenuity or nil,
		refund = r.concentration and r.concentration * ((CH.Stats.REFUND or 0.5) + (r.stats and r.stats.refundExtra or 0)) or nil,
		reagents = reagents, shop = shop, qty = 0,
	}
end

--- Add qty crafts of an advisor row; the same recipe, quality and Concentration choice stack.
--- extra adds fields to a new entry: firstCraft, orderID, customer, rewards.
function Q.Add(result, r, qty, extra)
	local e = Q.FromRow(result, r)
	for k, v in pairs(extra or {}) do e[k] = v end
	-- order IDs are kept as text: they can be numbers too big to save and compare reliably
	if e.orderID then e.orderID = tostring(e.orderID) end
	return Q.AddEntry(e, qty)
end

--- Add a ready-made entry (from Q.FromScan), stacking with the same recipe, quality and Concentration.
function Q.AddEntry(e, qty)
	-- an order is one craft: queueing it again (Queue all twice) changes nothing
	if e.orderID then
		local x = Q.ForOrder(e.orderID)
		if x then return x end
	end
	-- only the exact same craft stacks: the entry keeps its own reagents, so nothing is overwritten
	local k = keyOf(e)
	for _, x in ipairs(list()) do
		if keyOf(x) == k then
			x.qty = x.qty + (qty or 1)
			Q.Changed()
			return x
		end
	end
	e.qty = qty or 1
	table.insert(list(), e)
	Q.Changed()
	return e
end

--- A queue entry from a saved scan row, for any character, without the profession window open.
--- conc picks the Concentration craft. nil when the scan predates saving reagent slots.
function Q.FromScan(charKey, char, row, conc)
	-- the Concentration craft needs its own saved mix: never the plain one under its name
	local acc
	if conc then acc = row.concAccounts else acc = row.accounts end
	if not acc or not acc.queue then return nil end
	local shop = {}
	for _, s in ipairs(acc.reagents or {}) do table.insert(shop, { itemID = s.itemID, n = s.n, rank = s.rank, tiers = s.tiers }) end
	return { char = charKey, charName = char.name, class = char.class, recipeID = row.recipeID, name = row.name,
		quality = conc and row.concQuality or row.quality, tiers = row.tiers, concentration = conc and row.concentration or nil,
		profit = conc and row.concProfit or row.profit, cost = acc.cost, item = conc and (row.concItem or row.item) or row.item,
		avgConcentration = conc and (row.avgConcentration or acc.avgConcentration) or nil,
		reagents = acc.queue, shop = shop, qty = 0 }
end

--- The best saved scan row, on any character, that makes an item: charKey, char, row, or nil.
function Q.ScanRowFor(itemID)
	local bk, bc, br
	for k, c in pairs(CH.db.characters or {}) do
		for _, p in pairs(c.professions or {}) do
			for _, r in ipairs(p.scan and p.scan.rows or {}) do
				if r.item == itemID and r.accounts and r.accounts.queue and (not br or (r.profit or 0) > (br.profit or 0)) then
					bk, bc, br = k, c, r
				end
			end
		end
	end
	return bk, bc, br
end

function Q.Remove(e, qty)
	for i, x in ipairs(list()) do
		if x == e then
			x.qty = x.qty - (qty or x.qty)
			if x.qty <= 0 then table.remove(list(), i) end
			break
		end
	end
	Q.Changed()
end

function Q.Clear()
	wipe(list())
	Q.Changed()
end

function Q.Count()
	local n = 0
	for _, e in ipairs(list()) do n = n + e.qty end
	return n
end

--- Queue the best craft (by profit, without Concentration) of the top recipes in the open profession.
function Q.FillFromBest(limit)
	local added = 0
	local best = CH.Scan and CH.Scan.Top(CH.OpenProfessionID(), limit or 5)
	if best and #best > 0 then
		for _, c in ipairs(best) do
			local ok, result = pcall(CH.Advisor.Analyze, c.recipeID, { professionID = CH.OpenProfessionID() })
			if ok and result and result.best and result.best.profit and result.best.profit > 0 then
				Q.Add(result, result.best, 1)
				added = added + 1
			end
		end
		return added
	end
	for _, c in ipairs(CH.BestCrafts(limit or 5)) do
		local ok, result = pcall(CH.Advisor.Analyze, c.recipeID, { professionID = CH.OpenProfessionID() })
		if ok and result and result.best and result.best.profit and result.best.profit > 0 then
			Q.Add(result, result.best, 1)
			added = added + 1
		end
	end
	return added
end

local function eligible(info)
	return info and info.learned and not info.isRecraft and not info.isSalvageRecipe and not info.isGatheringRecipe
		and not info.isDummyRecipe
end

--- The cheapest craft of a result that the game accepts (any quality, no Concentration).
local function cheapest(result)
	local best
	for _, r in ipairs(result and result.rows or {}) do
		if r.cost and not r.short and not r.concentration and (not best or r.cost < best.cost) then best = r end
	end
	return best
end

--- Queue every learned recipe of the open profession that still gives its first-craft bonus (a
--- knowledge point), each once, at its cheapest. Returns how many and what they cost.
function Q.FillFirstCrafts()
	local ui = C_TradeSkillUI
	if not ui or not ui.GetAllRecipeIDs then return 0, 0 end
	local n, cost = 0, 0
	for _, id in ipairs(ui.GetAllRecipeIDs() or {}) do
		local info = ui.GetRecipeInfo(id)
		if eligible(info) and info.firstCraft then
			local ok, result = pcall(CH.Advisor.Analyze, id, { professionID = CH.OpenProfessionID() })
			local r = ok and cheapest(result)
			if r then
				Q.Add(result, r, 1, { firstCraft = true })
				n, cost = n + 1, cost + (r.cost or 0)
			end
		end
	end
	return n, cost
end

--- Patron (NPC) and personal orders for the open profession, as the game last listed them.
local function openOrders()
	local co = C_CraftingOrders
	if not co or not co.GetCrafterOrders then return {} end
	return CH.Orders and CH.Orders.All and CH.Orders.All() or co.GetCrafterOrders() or {}
end

--- Queue the crafting orders worth doing: each order's best craft that meets its minimum quality,
--- when the commission and rewards cover the reagents, or when it rewards something you can't buy
--- (knowledge, Artisan's Acuity and so on). Returns how many were queued and their total profit.
function Q.FillOrders(opts)
	opts = opts or {}
	local n, profit = 0, 0
	for _, order in ipairs(openOrders()) do
		local ok, result = pcall(CH.Orders.Analyze, order)
		local r = ok and result and (result.best or result.bestConc) -- Concentration when only it reaches the rank
		if r then
			local special = false
			for _, rw in ipairs(order.npcOrderRewards or {}) do
				local id = rw.itemLink and C_Item.GetItemInfoInstant and C_Item.GetItemInfoInstant(rw.itemLink)
				if id and CH.Unsellable(id) then special = true end
			end
			if (r.profit or 0) >= 0 or special or opts.all then
				Q.Add(result, r, 1, { orderID = order.orderID, customer = order.customerName or "Patron", special = special })
				n, profit = n + 1, profit + (r.profit or 0)
			end
		end
	end
	return n, profit
end

--- The profession the open window is (Enum.Profession), for the order calls.
local function profession()
	local ui = C_TradeSkillUI
	local info = ui and ui.GetChildProfessionInfo and ui.GetChildProfessionInfo()
	return info and info.profession
end

--- What the queue row's button does next for an order: "Claim", "Craft" or "Turn in". The game's
--- own claimed order wins over what we remember: crafted when it says the order can be turned in.
function Q.OrderStep(e)
	if not e.orderID then return Q.NeedsShatter(e.recipeID) and "Shatter" or "Craft" end
	local waiting = Q.Pending(e)
	if waiting then return Q.PENDING_LABEL[waiting] end
	local co = C_CraftingOrders
	local claimed = co and co.GetClaimedOrder and co.GetClaimedOrder()
	if claimed and CH.Orders.Same(claimed.orderID, e.orderID) then
		if claimed.isFulfillable then e.stage = "crafted" elseif e.stage ~= "crafted" then e.stage = "claimed" end
	end
	if e.stage == "claimed" and Q.NeedsShatter(e.recipeID) then return "Shatter" end
	return e.stage == "crafted" and "Turn in" or e.stage == "claimed" and "Craft" or "Claim"
end

--- Work an order's craft out again from the game's claimed order, right before crafting it: the
--- reagents and whether it takes Concentration (only when no plain craft reaches the rank asked),
--- as CraftSim does with the live order. A plan queued earlier can be stale or missing.
function Q.Replan(e)
	local co = C_CraftingOrders
	local claimed = co and co.GetClaimedOrder and co.GetClaimedOrder()
	if not (claimed and CH.Orders.Same(claimed.orderID, e.orderID)) then return false end
	local ok, result = pcall(CH.Orders.Analyze, claimed)
	if not (ok and result) then return false end
	local r = result.best or result.bestConc
	if not r then return false end
	local f = Q.FromRow(result, r)
	e.reagents, e.given, e.concentration, e.quality = f.reagents, f.given, f.concentration, f.quality
	return true
end

-- Shatter -----------------------------------------------------------------------------------------
-- Midnight enchanting: casting Shatter on a mote gives Shattering Essence (more Resourcefulness,
-- Multicraft and Ingenuity on the crafts after it). Like CraftSim, an enchanting craft casts it first
-- whenever the buff is missing.
Q.SHATTER = { recipe = 1235731, buff = 1235733 }

local function professionOf(recipeID)
	local ui = C_TradeSkillUI
	local p = ui and ui.GetProfessionInfoByRecipeID and recipeID and ui.GetProfessionInfoByRecipeID(recipeID)
	return p and p.professionID
end

--- Whether Shattering Essence is on you.
function Q.HasShatterBuff()
	local ua = C_UnitAuras
	return ua and ua.GetPlayerAuraBySpellID and ua.GetPlayerAuraBySpellID(Q.SHATTER.buff) ~= nil or false
end

--- Whether a craft of this recipe should cast Shatter first: a Midnight enchanting recipe (same
--- skill line as Shatter), Shatter learned, and the buff not on you.
function Q.NeedsShatter(recipeID)
	if not recipeID or recipeID == Q.SHATTER.recipe then return false end
	local ui = C_TradeSkillUI
	local info = ui and ui.GetRecipeInfo and ui.GetRecipeInfo(Q.SHATTER.recipe)
	if not (info and info.learned) then return false end
	local line = professionOf(Q.SHATTER.recipe)
	if not line or professionOf(recipeID) ~= line then return false end
	return not Q.HasShatterBuff()
end

-- What Shattering Essence adds, in rating: 5 of each, plus its perks at their spec ranks (CraftSim's
-- CreateShatteringEssenceBuffMidnight; the game's data doesn't carry the perks).
local SHATTER_PERKS = {
	{ node = 107616, stat = "resourcefulness", at = { [5] = 5, [15] = 10, [25] = 20 } }, -- Responsible Resources
	{ node = 107615, stat = "ingenuity", at = { [5] = 5, [15] = 10, [25] = 20 } },       -- Infinite Ingenuity
	{ node = 107614, stat = "multicraft", at = { [5] = 5, [15] = 10, [25] = 20 } },      -- Multicrafting Meticulously
	{ node = 100037, stat = "multicraft", at = { [5] = 30, [15] = 30, [25] = 30 } },     -- Magnificent Multicrafting
}
function Q.ShatterStats(professionID)
	local d = { ingenuity = 5, multicraft = 5, resourcefulness = 5 }
	local ps, tr = C_ProfSpecs, C_Traits
	local config = ps and ps.GetConfigIDForSkillLine and professionID and ps.GetConfigIDForSkillLine(professionID)
	if config and config ~= 0 and tr and tr.GetNodeInfo then
		for _, p in ipairs(SHATTER_PERKS) do
			local info = tr.GetNodeInfo(config, p.node)
			local rank = info and info.activeRank and (info.activeRank - 1) or -1
			for threshold, n in pairs(p.at) do
				if rank >= threshold then d[p.stat] = d[p.stat] + n end
			end
		end
	end
	return d
end

--- What Shatter would use: the cheapest mote you hold. Returns itemID, bag, slot, or nil.
--- The items Shatter can take: what the game lists as salvageable for it, and every reagent its
--- schematic's slots name (where CraftSim reads them; the salvage list can come back empty).
function Q.ShatterCandidates()
	local ui = C_TradeSkillUI
	local ids, seen = {}, {}
	local function add(id) if id and not seen[id] then seen[id] = true; ids[#ids + 1] = id end end
	local ok, list = pcall(function() return ui and ui.GetSalvagableItemIDs and ui.GetSalvagableItemIDs(Q.SHATTER.recipe) end)
	for _, id in ipairs(ok and list or {}) do add(id) end
	local ok2, sch = pcall(function() return ui and ui.GetRecipeSchematic and ui.GetRecipeSchematic(Q.SHATTER.recipe, false) end)
	for _, slot in ipairs(ok2 and sch and sch.reagentSlotSchematics or {}) do
		for _, r in ipairs(slot.reagents or {}) do add(r.itemID or (r.reagent and r.reagent.itemID)) end
	end
	return ids
end

-- Where to look for a mote: your bags and reagent bag first, then the bank, reagent bank and
-- warband bank tabs (the game salvages from those too, as CraftSim does, while it knows their contents).
local function containers()
	local out = {}
	local last = math.max(NUM_TOTAL_EQUIPPED_BAG_SLOTS or 0, Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag or 0, 5)
	for bag = 0, last do out[#out + 1] = bag end
	local B = Enum and Enum.BagIndex or {}
	for _, k in ipairs({ "Bank", "Reagentbank", "ReagentBank" }) do if B[k] then out[#out + 1] = B[k] end end
	for i = 1, 8 do
		if B["CharacterBankTab_" .. i] then out[#out + 1] = B["CharacterBankTab_" .. i] end
	end
	for i = 1, 8 do
		if B["AccountBankTab_" .. i] then out[#out + 1] = B["AccountBankTab_" .. i] end
	end
	return out
end
Q.ShatterContainers = containers

local function find(id)
	local C = C_Container
	if not (C and C.GetContainerNumSlots and C.GetContainerItemID) then return nil end
	for _, bag in ipairs(containers()) do
		local ok, n = pcall(C.GetContainerNumSlots, bag)
		for slot = 1, (ok and n or 0) do
			if C.GetContainerItemID(bag, slot) == id then return bag, slot end
		end
	end
end

--- What Shatter would use: the cheapest mote you own that the game can reach (bags first, then
--- bank and warband bank). Returns itemID, bag, slot; or itemID alone when you own it but its slot
--- can't be found (a bank the game hasn't shown this session); or nil when you own none.
function Q.ShatterItem()
	local owned = {}
	for _, id in ipairs(Q.ShatterCandidates()) do
		local n = C_Item and C_Item.GetItemCount and C_Item.GetItemCount(id, true, false, true, true) or 0
		if n > 0 then owned[#owned + 1] = { id = id, p = CH.Prices.Get("chmat", "i:" .. id) or math.huge } end
	end
	if not owned[1] then return nil end
	table.sort(owned, function(a, b) return a.p < b.p end)
	for _, o in ipairs(owned) do
		local bag, slot = find(o.id)
		if bag then return o.id, bag, slot end
	end
	return owned[1].id
end

--- Cast Shatter on the cheapest mote in your bags. Must be called from a click. true, or false and why.
function Q.Shatter()
	local id, bag, slot = Q.ShatterItem()
	if not id then return false, "you have no motes Shatter can take" end
	if not bag then return false, "your motes are in a bank the game hasn't shown yet: open your bank (or take a mote out to your bags) and try again" end
	local loc = ItemLocation and ItemLocation.CreateFromBagAndSlot and ItemLocation:CreateFromBagAndSlot(bag, slot)
	if not loc then return false, "can't find the mote in your bags" end
	C_TradeSkillUI.CraftSalvage(Q.SHATTER.recipe, 1, loc, {}, false)
	return true
end

--- The queue entry for an order, or nil.
function Q.ForOrder(orderID)
	for _, e in ipairs(list()) do
		if e.orderID and CH.Orders.Same(e.orderID, orderID) then return e end
	end
end

--- The next thing to do in the queue on this character: the order you have claimed first, then the
--- first order, then the first craft. Returns the entry and its step, or nil.
function Q.NextStep()
	local first, firstOrder
	for _, e in ipairs(list()) do
		if Q.CanCraftHere(e) then
			if e.orderID then
				if e.stage == "claimed" or e.stage == "crafted" then return e, Q.OrderStep(e) end
				firstOrder = firstOrder or e
			end
			first = first or e
		end
	end
	local e = firstOrder or first
	if e then return e, Q.OrderStep(e) end
end

--- Do the next step (one click, one step: claim, craft, turn in, next order). Returns the step done
--- and the entry, or false and why.
function Q.DoNext()
	local e, step = Q.NextStep()
	if not e then return false, "nothing in the queue you can craft here" end
	local ok, why = Q.Craft(e, e.orderID and 1 or e.qty)
	if not ok then return false, why end
	return step, e
end

--- Fill the queue from the saved scan of a profession, on a Concentration budget:
---   1. Concentration crafts, best extra gold per point first, only as many as your Concentration pays
---      for (budget, default what you have now) and as many as sell in a day (less what you own).
---   2. Then crafts that make a profit without Concentration, up to what sells in a day.
--- Returns a summary { conc, plain, points, budget, profit, recipes }, or nil and why.
--- The TSM Crafting rule for an item (Groups.CraftRule), or nil.
function Q.Rule(itemID) return itemID and CH.Groups and CH.Groups.CraftRule and CH.Groups.CraftRule(itemID) or nil end

function Q.FillPlan(profID, opts)
	opts = opts or {}
	local scan = CH.Scan and CH.Scan.Results(profID)
	if not scan or #scan.rows == 0 then return nil, "scan the profession first (the Scan tab)" end
	local p = CH.Me().professions[profID]
	local budget = opts.budget or (p and CH.ConcentrationNow(p)) or 0
	local out = { conc = 0, plain = 0, points = 0, budget = budget, profit = 0, recipes = 0, entries = {} } -- entries: a dry run's would-be crafts
	local limit = opts.limit or 12
	local results, queued, done = {}, {}, {}
	local function analyze(id)
		if results[id] == nil then
			local ok, r = pcall(CH.Advisor.Analyze, id, { professionID = profID })
			results[id] = ok and r or false
		end
		return results[id]
	end
	local function demand(r, itemID)
		-- a TSM Crafting operation's restock rule first (up to its max, held across the warband, and
		-- nothing under its min), else your stock target (counting stock on every character), else a day's sales
		local rule = Q.Rule(itemID)
		if rule then
			local want = rule.maxRestock - CH.Par.Held(itemID) - (queued[itemID] or 0)
			if want < math.max(1, rule.minRestock) then return 0 end
			return math.ceil(want / (r.made or 1))
		end
		local par = CH.Par and itemID and CH.Par.Target(itemID)
		local units = par or CH.Scan.DailyUnits(itemID)
		local held = par and CH.Par.Held(itemID) or have(itemID or 0)
		return math.max(0, math.ceil((units - held - (queued[itemID or 0] or 0)) / (r.made or 1)))
	end
	-- a TSM Crafting operation's minimum profit, per item made
	local function profitable(r, itemID, profit)
		local rule = Q.Rule(itemID)
		if not (rule and rule.minProfit) then return true end
		return profit and profit / math.max(r.made or 1, 0.01) >= rule.minProfit
	end
	local function add(r, row, n, isConc)
		if not done[r.recipeID] then
			if out.recipes >= limit then return false end
			done[r.recipeID] = true
			out.recipes = out.recipes + 1
		end
		if opts.dry then
			table.insert(out.entries, { name = row.name or (r.result and r.result.name), item = row.item, n = n, conc = isConc, profit = (row.profit or 0) * n })
		else
			Q.Add(r.result, row, n)
		end
		queued[row.item or 0] = (queued[row.item or 0] or 0) + n * (r.made or 1)
		out.profit = out.profit + (row.profit or 0) * n
		if isConc then out.conc = out.conc + n else out.plain = out.plain + n end
		return true
	end

	-- 1. Concentration, best extra gold per point first
	local conc = {}
	for _, r in ipairs(scan.rows) do
		local avg = r.avgConcentration or r.concentration
		local gain = r.concProfit and (r.concProfit - math.max(0, r.profit or 0))
		if avg and avg > 0 and gain and gain > 0 then
			table.insert(conc, { row = r, avg = avg, gpp = gain / avg })
		end
	end
	table.sort(conc, function(a, b) return a.gpp > b.gpp end)
	for _, c in ipairs(conc) do
		local r = c.row
		local raw = r.concentration or c.avg
		if budget >= raw and profitable(r, r.concItem, r.concProfit) then
			local n = math.min(demand(r, r.concItem), 1 + math.floor((budget - raw) / c.avg))
			local res = n > 0 and analyze(r.recipeID)
			if res and res.bestConc then
				if add({ recipeID = r.recipeID, made = r.made, result = res }, res.bestConc, n, true) then
					budget = budget - c.avg * n
					out.points = out.points + c.avg * n
				end
			end
		end
	end

	-- 2. Profitable without Concentration
	local plain = {}
	for _, r in ipairs(scan.rows) do
		if r.profit and r.profit > 0 then table.insert(plain, r) end
	end
	table.sort(plain, function(a, b) return (a.perDay or 0) > (b.perDay or 0) end)
	for _, r in ipairs(plain) do
		local n = profitable(r, r.item, r.profit) and demand(r, r.item) or 0
		local res = n > 0 and analyze(r.recipeID)
		if res and res.best then add({ recipeID = r.recipeID, made = r.made, result = res }, res.best, n, false) end
	end
	return out
end

--- Reagents for the whole queue: need, have, buy and what buying costs, walking the listings. Sorted by cost, biggest first.
function Q.ShoppingList(entries)
	local need, rank, tiers = {}, {}, {}
	for _, e in ipairs(entries or list()) do
		for _, s in ipairs(e.shop) do
			need[s.itemID] = (need[s.itemID] or 0) + s.n * e.qty
			rank[s.itemID] = s.rank
			tiers[s.itemID] = s.tiers
		end
	end
	local out, total = {}, 0
	for id, n in pairs(need) do
		local h = have(id)
		local buy = math.max(0, n - h)
		-- walk the order book for the quantity bought, not chmat x quantity (see Depth.lua)
		local d = buy > 0 and CH.Depth.Cost(id, buy)
		local unit = d and d.unit or CH.Prices.Get("chmat", "i:" .. id)
		local cost = d and d.cost or (unit and unit * buy)
		total = total + (cost or 0)
		-- someone on the warband makes it for less than buying it: say who, and what it would cost them
		local made = CH.Scan and CH.Scan.SubrecipesOn and CH.Scan.SubrecipesOn() and CH.Scan.Crafted(id)
		local craft = made and buy > 0 and (not unit or made.each < unit) and
			{ char = made.char, key = made.key, recipeID = made.recipeID, name = made.name, each = made.each, cost = made.each * buy } or nil
		-- a TSM Shopping operation's maximum price: how many the listings seen offer at or under it
		local rule = CH.Groups and CH.Groups.ShopRule and CH.Groups.ShopRule(id)
		local maxPrice = rule and rule.maxPrice
		local overMax, underMax
		if maxPrice and buy > 0 then
			local rows, src = CH.Depth.Book(id)
			if rows and src == "ah" then
				underMax = 0
				for _, r in ipairs(rows) do if r[1] <= maxPrice then underMax = underMax + r[2] end end
				overMax = underMax < buy
			else
				overMax = unit and unit > maxPrice or nil
			end
		end
		table.insert(out, { itemID = id, rank = rank[id], tiers = tiers[id], need = n, have = h, buy = buy, unit = unit, cost = cost, craft = craft,
			maxPrice = maxPrice, shopOp = rule and rule.op, overMax = overMax, underMax = underMax,
			source = d and d.source, short = d and d.short or 0, first = d and d.first, age = d and d.age,
			name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id) or ("item " .. id) })
	end
	table.sort(out, function(a, b) return (a.cost or 0) > (b.cost or 0) end)
	return out, total
end

-- The saved profession on a character that has a recipe (from its scan or its best crafts).
local function professionOf(charKey, recipeID)
	local c = CH.db.characters and CH.db.characters[charKey]
	for id, p in pairs(c and c.professions or {}) do
		for _, r in ipairs(p.scan and p.scan.rows or {}) do
			if r.recipeID == recipeID then return p, id end
		end
		for _, r in ipairs(p.crafts or {}) do
			if r.recipeID == recipeID then return p, id end
		end
	end
	if charKey == CH.CharacterKey() and CH.OpenProfessionID then
		local id = CH.OpenProfessionID()
		local info = id and C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(recipeID)
		if info and info.learned then return c and c.professions[id], id end
	end
end
Q.ProfessionOf = professionOf

--- What the queue needs against what you have: gold (to buy the reagents you're short of, against
--- this character's gold), reagents (their value on hand against all the queue uses) and
--- Concentration (each craft's full cost, on each character's profession; refunds aren't counted
--- until they happen). Also the first craft, in queue order, that hits each limit: { gold, reagents,
--- conc = { need, have, entry, n, why } ... , stop = { entry, n, why } } where n is the craft's
--- number within its entry and why is "gold", "reagents" or "concentration".
function Q.Budget()
	local shop, total = Q.ShoppingList()
	local out = { shop = shop, gold = { need = total, have = GetMoney and GetMoney() or 0 }, reagents = { need = 0, have = 0 },
		conc = { need = 0, have = 0, by = {} } } -- by: { char, prof, need, have } per character's profession
	local unit = {}
	for _, s in ipairs(shop) do
		local u = s.unit or 0
		unit[s.itemID] = u
		out.reagents.need = out.reagents.need + s.need * u
		out.reagents.have = out.reagents.have + math.min(s.have, s.need) * u
	end
	-- walk the queue craft by craft: reagents on hand first, then buying, then Concentration
	local stock, gold, points, seen, seq, start = {}, out.gold.have, {}, {}, {}, {}
	-- Ingenuity on an entry: saved with it, else worked out from the average cost its scan kept
	local function refundOf(e) return e.refund or (e.concentration or 0) * (CH.Stats.REFUND or 0.5) end
	local function ingOf(e)
		if e.ingenuity then return e.ingenuity end
		local avg = e.avgConcentration
		if not avg or not e.concentration or e.concentration <= 0 then return 0 end
		return math.max(0, math.min(1, (1 - avg / e.concentration) / (CH.Stats.REFUND or 0.5)))
	end
	local function first(kind, e, n, extra)
		if not out[kind].stop then out[kind].stop = { entry = e, n = n, why = kind, extra = extra } end
		if not out.stop and kind ~= "reagents" then out.stop = out[kind].stop end
	end
	for _, e in ipairs(list()) do
		local p, pid
		if e.concentration then p, pid = professionOf(e.char, e.recipeID) end
		local pk = p and (e.char .. ":" .. tostring(pid))
		if pk and not seen[pk] then
			seen[pk] = { char = e.charName or e.char, prof = p.name, need = 0, have = CH.ConcentrationNow(p) or 0 }
			table.insert(out.conc.by, seen[pk])
			points[pk] = seen[pk].have
			start[pk] = points[pk]
			out.conc.have = out.conc.have + points[pk]
		end
		if e.concentration then
			out.conc.need = out.conc.need + e.concentration * e.qty
			if pk then seen[pk].need = seen[pk].need + e.concentration * e.qty end
		end
		for n = 1, e.qty do
			for _, s in ipairs(e.shop or {}) do
				if stock[s.itemID] == nil then stock[s.itemID] = have(s.itemID) end
				local take = math.min(stock[s.itemID], s.n)
				stock[s.itemID] = stock[s.itemID] - take
				local short = s.n - take
				if short > 0 then
					first("reagents", e, n, s.itemID)
					gold = gold - short * (unit[s.itemID] or 0)
					if gold < 0 then first("gold", e, n) end
				end
			end
			if e.concentration then
				if pk then
					if points[pk] < e.concentration then first("conc", e, n) else points[pk] = points[pk] - e.concentration end
					seq[pk] = seq[pk] or {}
					table.insert(seq[pk], { cost = e.concentration, ing = ingOf(e), refund = refundOf(e), entry = e, n = n })
				end
			end
		end
	end
	-- refund upside: the chance Ingenuity refunds earlier in the queue let the blocked craft start
	local st = out.conc.stop
	if st and CH.Decide then
		for pk, list in pairs(seq) do
			local reach = CH.Decide.ConcSequence(start[pk], list)
			for k, c in ipairs(list) do
				if c.entry == st.entry and c.n == st.n then
					st.upside = reach[k]
					-- crafts beyond the points you have that refunds cover on average
					local extra = 0
					for j = k, #list do extra = extra + (reach[j] or 0) end
					st.extra = extra
				end
			end
		end
	end
	return out
end

--- What each queued entry can do right now, walking the queue in order so earlier entries take the
--- reagents and Concentration first. Per entry: { now, blocked, why, short = { [itemID] = n }, shortN,
--- need (its Concentration), have (points left for it) }. why is nil (all ready), "switch" (another
--- character's), "reagents" or "conc". Totals: { now, blocked }.
function Q.Readiness()
	local here = CH.CharacterKey and CH.CharacterKey()
	local stock, points, out, tot = {}, {}, {}, { now = 0, blocked = 0 }
	for _, e in ipairs(list()) do
		local r = { now = 0, blocked = 0, short = {}, shortN = 0 }
		out[e] = r
		if e.char ~= here then
			r.why, r.blocked = "switch", e.qty
		else
			local p, pid
			if e.concentration then p, pid = professionOf(e.char, e.recipeID) end
			local pk = p and (e.char .. ":" .. tostring(pid))
			if pk and points[pk] == nil then points[pk] = CH.ConcentrationNow(p) or 0 end
			for _ = 1, e.qty do
				local ok = true
				for _, s in ipairs(e.shop or {}) do
					if stock[s.itemID] == nil then stock[s.itemID] = have(s.itemID) end
					if stock[s.itemID] < s.n then ok = false end
				end
				local concOK = not (pk and points[pk] < e.concentration)
				if ok and concOK then
					for _, s in ipairs(e.shop or {}) do stock[s.itemID] = stock[s.itemID] - s.n end
					if pk then points[pk] = points[pk] - e.concentration end
					r.now = r.now + 1
				else
					-- a blocked craft takes what's left, so the shortfall adds up across crafts
					for _, s in ipairs(e.shop or {}) do
						local take = math.min(stock[s.itemID], s.n)
						stock[s.itemID] = stock[s.itemID] - take
						if s.n > take then r.short[s.itemID] = (r.short[s.itemID] or 0) + s.n - take; r.shortN = r.shortN + s.n - take end
					end
					r.blocked = r.blocked + 1
					r.why = r.why or (not ok and "reagents" or "conc")
					if not concOK then r.need, r.have = e.concentration, points[pk] end
				end
			end
		end
		tot.now, tot.blocked = tot.now + r.now, tot.blocked + r.blocked
	end
	return out, tot
end

--- Whether this character can craft an entry now: theirs, profession open, recipe known.
function Q.CanCraftHere(e)
	if e.char ~= CH.CharacterKey() then return false, "on " .. (e.charName or e.char) end
	local ui = C_TradeSkillUI
	local info = ui and ui.GetRecipeInfo and ui.GetRecipeInfo(e.recipeID)
	if not info or not info.learned then return false, "open its profession" end
	if ProfessionsFrame and not ProfessionsFrame:IsShown() then return false, "open its profession" end
	return true
end

local crafting -- the entry being crafted, to count finished crafts off it
local PENDING_FOR = 15 -- seconds to wait for the game to answer a step before letting you retry

local function okResult(result)
	local ok = Enum and Enum.CraftingOrderResult and Enum.CraftingOrderResult.Ok or 0
	return result == nil or result == ok
end

local function claimedOrder(id)
	local co = C_CraftingOrders
	local c = co and co.GetClaimedOrder and co.GetClaimedOrder()
	if c and CH.Orders.Same(c.orderID, id) then return c end
end

local function now() return GetTime and GetTime() or time() end

--- A step sent to the game and not yet answered: "claim", "craft" or "turnin", or nil. A step
--- unanswered for PENDING_FOR seconds lapses, so it can be tried again.
function Q.Pending(e)
	if not (e and e.pending) then return nil end
	if e.pendingAt and now() - e.pendingAt > PENDING_FOR then e.pending, e.pendingAt = nil, nil; return nil end
	return e.pending
end
local function setPending(e, what) e.pending, e.pendingAt = what, what and now() or nil; Q.Changed() end
Q.PENDING_LABEL = { claim = "Claiming...", craft = "Crafting...", turnin = "Turning in..." }

local function entryForOrder(orderID)
	for _, e in ipairs(list()) do if e.orderID and CH.Orders.Same(e.orderID, orderID) then return e end end
end

-- The game answers a claim or a turn-in later: the queue moves on only when it says yes.
CH.On("CRAFTINGORDERS_CLAIM_ORDER_RESPONSE", function(_, result, orderID)
	local e = entryForOrder(orderID)
	if not e then return end
	setPending(e, nil)
	if okResult(result) then
		e.stage = "claimed"
		CH.Print("claimed: " .. (e.name or "the order"))
	else
		e.stage = nil
		CH.Print("the game didn't let you claim that order (" .. tostring(result) .. "). Someone may have taken it, or you're at your claim limit.")
	end
	Q.Changed()
end)
CH.On("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", function(_, result, orderID)
	local e = entryForOrder(orderID)
	if okResult(result) then CH.Orders.Forget(orderID) end
	if not e then return end
	setPending(e, nil)
	if okResult(result) then
		CH.Print("turned in: " .. (e.name or "the order"))
		Q.Remove(e)
	else
		e.stage = "crafted"
		CH.Print("the game didn't take that order (" .. tostring(result) .. "). It's still in the queue: press Turn in to try again.")
		Q.Changed()
	end
end)

-- Released (Cancel Order on the game's page) or timed out: the order goes back to Claim.
local function released(orderID)
	local co = C_CraftingOrders
	local now = co and co.GetClaimedOrder and co.GetClaimedOrder()
	for _, e in ipairs(list()) do
		if e.orderID and e.stage and (orderID == nil and not (now and CH.Orders.Same(now.orderID, e.orderID))
			or orderID ~= nil and CH.Orders.Same(e.orderID, orderID)) then
			e.stage, e.confirmed = nil, nil
			setPending(e, nil)
		end
	end
	Q.Changed()
end
CH.On("CRAFTINGORDERS_RELEASE_ORDER_RESPONSE", function(_, result, orderID) if okResult(result) then released(orderID) end end)
CH.On("CRAFTINGORDERS_CLAIMED_ORDER_REMOVED", function() released(nil) end)

-- Is a reagent slot required (a basic reagent) or optional (finishing, optional)?
local function slotRequired(sl)
	if sl.required ~= nil then return sl.required end
	local basic = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
	return basic == nil or sl.reagentType == nil or sl.reagentType == basic
end

--- Work out exactly what an order craft will send: your reagents less what the customer gives,
--- without locked slots. A required reagent you're short of stops it, named; an optional one you're
--- short of is left out. Returns { mine, names, dropped } or nil and why.
function Q.OrderAllocation(e, claimed)
	local ui = C_TradeSkillUI
	local supplied = {}
	for _, r in ipairs(claimed.reagents or {}) do
		local info = r.reagentInfo or r
		local id = info.reagent and info.reagent.itemID or info.itemID
		if id then supplied[id] = (supplied[id] or 0) + (info.quantity or math.huge) end
	end
	-- only what they give beyond what the advisor already planned for comes off ours
	for id, n in pairs(e.given or {}) do if supplied[id] then supplied[id] = math.max(0, supplied[id] - n) end end
	local sch = ui and ui.GetRecipeSchematic and ui.GetRecipeSchematic(e.recipeID, false)
	local slots = {}
	for _, sl in ipairs(sch and sch.reagentSlotSchematics or {}) do slots[sl.dataSlotIndex] = sl end
	local mine, names, dropped = {}, {}, {}
	for _, r in ipairs(e.reagents or {}) do
		local off = math.min(r.n, supplied[r.itemID] or 0)
		if off > 0 then supplied[r.itemID] = supplied[r.itemID] - off end
		local n = r.n - off
		if n > 0 then
			local nm = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(r.itemID) or ("item " .. r.itemID)
			local sl = r.slot and slots[r.slot]
			local required = not sl or slotRequired(sl)
			local have = C_Item and C_Item.GetItemCount and C_Item.GetItemCount(r.itemID, true, false, true, true) or n
			if sl and CH.Advisor and CH.Advisor.SlotLocked and CH.Advisor.SlotLocked(e.recipeID, sl) then
				if required then return nil, string.format("%s goes in a slot that's locked for you", nm) end
				dropped[#dropped + 1] = nm .. " (slot locked)"
			elseif have < n then
				if required then return nil, string.format("you need %d %s and have %d", n, nm, have) end
				dropped[#dropped + 1] = string.format("%s (have %d of %d)", nm, have, n)
			else
				-- the game's own shape, as CraftSim passes it
				mine[#mine + 1] = { reagent = { itemID = r.itemID }, quantity = n, dataSlotIndex = r.slot }
				names[#names + 1] = string.format("%dx %s", n, nm)
			end
		end
	end
	return { mine = mine, names = names, dropped = dropped }
end

-- What these exact reagents make for the order, with or without Concentration: rank and points.
local function orderRank(e, claimed, mine, conc)
	local ui = C_TradeSkillUI
	if not (ui and ui.GetCraftingOperationInfoForOrder) then return nil end
	local all = {}
	for _, r in ipairs(mine) do all[#all + 1] = r end
	-- the customer's graded reagents count too; a single-quality one makes the game answer nothing
	local graded = {}
	local sch = ui.GetRecipeSchematic and ui.GetRecipeSchematic(e.recipeID, false)
	for _, sl in ipairs(sch and sch.reagentSlotSchematics or {}) do
		if #(sl.reagents or {}) > 1 then
			for _, x in ipairs(sl.reagents) do graded[x.itemID or (x.reagent and x.reagent.itemID) or 0] = true end
		end
	end
	for _, r in ipairs(claimed.reagents or {}) do
		local info = r.reagentInfo or r
		local id = info.reagent and info.reagent.itemID
		if id and (graded[id] or not sch) then all[#all + 1] = info end
	end
	local ok, op = pcall(ui.GetCraftingOperationInfoForOrder, e.recipeID, all, claimed.orderID, conc)
	if not (ok and op) then return nil end
	return op.craftingQuality, op.concentrationCost
end

--- Craft an entry with its queued reagents and Concentration. Must be called from a click.
--- An order goes claim, craft, turn in, each with the game's live order (as CraftSim does it), and
--- each moves on only when the game confirms it. The craft settles its final reagents first and
--- checks that exact set; if it differs from the plan (a reagent left out, Concentration needed), it
--- says how and the next press crafts it.
function Q.Craft(e, amount)
	local ok, why = Q.CanCraftHere(e)
	if not ok then return false, why end
	local waiting = Q.Pending(e)
	if waiting then return false, "waiting for the game to confirm: " .. Q.PENDING_LABEL[waiting]:lower() end
	if Q.OrderStep(e) == "Shatter" then return Q.Shatter() end
	if e.orderID and Q.OrderStep(e) == "Craft" then Q.Replan(e) end
	local reagents = {}
	for _, r in ipairs(e.reagents) do
		table.insert(reagents, { reagent = { itemID = r.itemID }, itemID = r.itemID, dataSlotIndex = r.slot, quantity = r.n })
	end
	if e.orderID then
		local step = Q.OrderStep(e)
		if step == "Claim" then
			local o = CH.Orders.Live(e.orderID)
			if not o then return false, "that order isn't listed any more: fetch the work orders again" end
			setPending(e, "claim")
			C_CraftingOrders.ClaimOrder(o.orderID, profession())
			return true
		end
		local claimed = claimedOrder(e.orderID)
		if not claimed then
			e.stage = nil
			Q.Changed()
			return false, "that order isn't claimed any more: claim it again"
		end
		if step == "Turn in" then
			setPending(e, "turnin")
			C_CraftingOrders.FulfillOrder(claimed.orderID, "", profession())
			return true
		end
		-- 1. the exact reagents this craft will send
		local alloc, stop = Q.OrderAllocation(e, claimed)
		if not alloc then return false, stop end
		-- 2. check that exact set reaches the rank asked; Concentration only if that's what reaches it
		local conc = e.concentration ~= nil
		local need = claimed.minQuality or 0
		local points
		if need > 1 then
			local q, cost = orderRank(e, claimed, alloc.mine, conc)
			points = conc and cost or nil
			if q and q < need and not conc then
				local qc, cc = orderRank(e, claimed, alloc.mine, true)
				if not (qc and qc >= need) then
					return false, string.format("the order needs rank %d but these reagents reach rank %d, even with Concentration", need, qc or q)
				end
				conc, points = true, cc
			elseif q and q < need then
				return false, string.format("the order needs rank %d but these reagents only reach rank %d with Concentration", need, q)
			end
		end
		-- 3. a craft that differs from the plan waits for a second press, after saying how
		local changes = {}
		if #alloc.dropped > 0 then changes[#changes + 1] = "leaves out " .. table.concat(alloc.dropped, ", ") end
		if conc and e.concentration == nil then
			changes[#changes + 1] = string.format("uses Concentration (%s points) to reach rank %d", points and tostring(math.floor(points + 0.5)) or "?", need)
		end
		local sig = table.concat(changes, "; ")
		if sig ~= "" and e.confirmed ~= sig then
			e.confirmed = sig
			Q.Changed()
			return false, "this craft " .. sig .. ". Press again to craft it this way."
		end
		e.confirmed = nil
		setPending(e, "craft")
		crafting = e
		CH.Print(string.format("crafting %s into the order with %s, Concentration %s%s",
			e.name or "?", #alloc.names > 0 and table.concat(alloc.names, ", ") or "only the customer's reagents",
			conc and "on" or "off", points and conc and string.format(" (%d points)", math.floor(points + 0.5)) or ""))
		local ui = C_TradeSkillUI
		if (claimed.isRecraft or claimed.outputItemGUID) and ui.RecraftRecipeForOrder and claimed.outputItemGUID then
			ui.RecraftRecipeForOrder(claimed.orderID, claimed.outputItemGUID, alloc.mine, nil, conc)
		else
			ui.CraftRecipe(e.recipeID, 1, alloc.mine, nil, claimed.orderID, conc)
		end
		return true
	end
	crafting = e
	local ui = C_TradeSkillUI
	if Q.IsEnchant(e.recipeID) then
		-- an enchant for the AH goes on Enchanting Vellum: CraftEnchant with the vellum as its target
		local bag, slot = Q.FindVellum()
		if not bag then crafting = nil; return false, "no Enchanting Vellum in your bags" end
		local loc = ItemLocation and ItemLocation.CreateFromBagAndSlot and ItemLocation:CreateFromBagAndSlot(bag, slot)
		if not (loc and ui.CraftEnchant) then crafting = nil; return false, "the game can't target the vellum" end
		ui.CraftEnchant(e.recipeID, amount or 1, reagents, loc, e.concentration ~= nil)
		return true
	end
	ui.CraftRecipe(e.recipeID, amount or 1, reagents, nil, nil, e.concentration ~= nil)
	return true
end

Q.VELLUM = 38682
--- Whether a recipe is an enchant (cast on an item: for the AH, onto Enchanting Vellum).
function Q.IsEnchant(recipeID)
	local ui = C_TradeSkillUI
	local info = ui and ui.GetRecipeInfo and recipeID and ui.GetRecipeInfo(recipeID)
	return info and info.isEnchantingRecipe and true or false
end

--- The bag and slot of an Enchanting Vellum in your bags, or nil.
function Q.FindVellum()
	local C = C_Container
	if not (C and C.GetContainerNumSlots and C.GetContainerItemID) then return nil end
	local last = math.max(NUM_TOTAL_EQUIPPED_BAG_SLOTS or 0, Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag or 0, 5)
	for bag = 0, last do
		for slot = 1, (C.GetContainerNumSlots(bag) or 0) do
			if C.GetContainerItemID(bag, slot) == Q.VELLUM then return bag, slot end
		end
	end
end

-- A recipe ID is its spell ID: each successful cast is one craft done.
CH.On("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellID)
	if unit ~= "player" or not crafting or crafting.recipeID ~= spellID then return end
	if crafting.orderID then
		-- crafted for the order only if the game now says it can be turned in
		local e, co = crafting, C_CraftingOrders
		crafting = nil
		local function settle()
			setPending(e, nil)
			local claimed = co and co.GetClaimedOrder and co.GetClaimedOrder()
			if not claimed or not CH.Orders.Same(claimed.orderID, e.orderID) or claimed.isFulfillable then
				e.stage = "crafted"
			else
				CH.Print("that craft didn't go into the order. Press Craft on the order's page (Crafting Orders tab), then Turn in next.")
			end
			Q.Changed()
		end
		if co and co.GetClaimedOrder and C_Timer then C_Timer.After(0.5, settle) else settle() end
		return
	end
	-- a craft straight from the Craft window isn't in the queue: just count it down
	if crafting.direct then crafting.qty = crafting.qty - 1 else Q.Remove(crafting, 1) end
	if crafting.qty <= 0 then crafting = nil end
end)
-- a craft the game stopped: the order's step is free to try again
for _, ev in ipairs({ "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED" }) do
	CH.On(ev, function(_, unit, _, spellID)
		if unit ~= "player" or not crafting or crafting.recipeID ~= spellID then return end
		if crafting.orderID then setPending(crafting, nil) end
		crafting = nil
	end)
end

--- Craft an advisor row now, without queueing it: the Craft window's Craft button. n crafts with
--- the row's reagents and Concentration. Returns true, or false and why.
function Q.CraftNow(result, r, n)
	if not (result and r) then return false, "pick a quality first" end
	local e = Q.FromRow(result, r)
	e.direct, e.qty = true, math.max(1, math.floor(n or 1))
	return Q.Craft(e, e.qty)
end

-- UI hook; QueueUI replaces it.
function Q.Changed() end
