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

local function keyOf(e)
	return table.concat({ e.char, e.recipeID, e.quality, e.concentration and "c" or "", e.orderID and tostring(e.orderID) or "" }, ":")
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
	local k = keyOf(e)
	for _, x in ipairs(list()) do
		if keyOf(x) == k then
			x.qty = x.qty + (qty or 1)
			x.reagents, x.shop, x.profit, x.cost = e.reagents, e.shop, e.profit, e.cost -- latest picks and prices
			Q.Changed()
			return x
		end
	end
	e.qty = qty or 1
	table.insert(list(), e)
	Q.Changed()
	return e
end

--- Add a ready-made entry (from Q.FromScan), stacking with the same recipe, quality and Concentration.
function Q.AddEntry(e, qty)
	local k = keyOf(e)
	for _, x in ipairs(list()) do
		if keyOf(x) == k then
			x.qty = x.qty + (qty or 1)
			x.reagents, x.shop, x.profit, x.cost = e.reagents, e.shop, e.profit, e.cost
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
	local acc = conc and row.concAccounts or row.accounts
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
function Q.ShatterItem()
	local ui = C_TradeSkillUI
	local ids = ui and ui.GetSalvagableItemIDs and ui.GetSalvagableItemIDs(Q.SHATTER.recipe) or {}
	local best, bestPrice
	for _, id in ipairs(ids) do
		local n = C_Item and C_Item.GetItemCount and C_Item.GetItemCount(id) or 0
		if n > 0 then
			local p = CH.Prices.Get("chmat", "i:" .. id) or math.huge
			if not best or p < bestPrice then best, bestPrice = id, p end
		end
	end
	if not best then return nil end
	local C = C_Container
	for bag = 0, (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4) do
		for slot = 1, (C and C.GetContainerNumSlots and C.GetContainerNumSlots(bag) or 0) do
			if C.GetContainerItemID(bag, slot) == best then return best, bag, slot end
		end
	end
	return best -- in a bank, not your bags
end

--- Cast Shatter on the cheapest mote in your bags. Must be called from a click. true, or false and why.
function Q.Shatter()
	local id, bag, slot = Q.ShatterItem()
	if not id then return false, "no mote to Shatter in your bags" end
	if not bag then return false, "your motes for Shatter are in the bank: take one out first" end
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
	local out = { conc = 0, plain = 0, points = 0, budget = budget, profit = 0, recipes = 0 }
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
		Q.Add(r.result, row, n)
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
	local out = { gold = { need = total, have = GetMoney and GetMoney() or 0 }, reagents = { need = 0, have = 0 },
		conc = { need = 0, have = 0 } }
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
			seen[pk] = true
			points[pk] = CH.ConcentrationNow(p) or 0
			start[pk] = points[pk]
			out.conc.have = out.conc.have + points[pk]
		end
		if e.concentration then out.conc.need = out.conc.need + e.concentration * e.qty end
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
local delivering = {} -- orders turned in, until the game says it took them

local function okResult(result)
	local ok = Enum and Enum.CraftingOrderResult and Enum.CraftingOrderResult.Ok or 0
	return result == nil or result == ok
end

local function claimedOrder(id)
	local co = C_CraftingOrders
	local c = co and co.GetClaimedOrder and co.GetClaimedOrder()
	if c and CH.Orders.Same(c.orderID, id) then return c end
end

-- The game answers a claim or a turn-in later: undo what we assumed if it said no.
CH.On("CRAFTINGORDERS_CLAIM_ORDER_RESPONSE", function(_, result, orderID)
	if okResult(result) then return end
	for _, e in ipairs(list()) do
		if CH.Orders.Same(e.orderID, orderID) and e.stage == "claimed" then e.stage = nil end
	end
	CH.Print("the game didn't let you claim that order (" .. tostring(result) .. "). Someone may have taken it, or you're at your claim limit.")
	Q.Changed()
end)
CH.On("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", function(_, result, orderID)
	local key = tostring(orderID)
	local e = delivering[key]
	delivering[key] = nil
	if okResult(result) then CH.Orders.Forget(orderID) end
	if not e or okResult(result) then return end
	e.stage, e.qty = "crafted", 1
	table.insert(list(), 1, e)
	CH.Print("the game didn't take that order (" .. tostring(result) .. "). It's back at the top of the queue.")
	Q.Changed()
end)

--- Craft an entry with its queued reagents and Concentration. Must be called from a click.
--- An order goes claim, craft, turn in, each with the game's live order (as CraftSim does it).
function Q.Craft(e, amount)
	local ok, why = Q.CanCraftHere(e)
	if not ok then return false, why end
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
			C_CraftingOrders.ClaimOrder(o.orderID, profession())
			e.stage = "claimed"
			Q.Changed()
			return true
		end
		local claimed = claimedOrder(e.orderID)
		if not claimed then
			e.stage = nil
			Q.Changed()
			return false, "that order isn't claimed any more: claim it again"
		end
		if step == "Turn in" then
			C_CraftingOrders.FulfillOrder(claimed.orderID, "", profession())
			delivering[tostring(e.orderID)] = e
			Q.Remove(e)
			return true
		end
		-- craft into the order: the customer's reagents are theirs, leave them out of ours
		-- only what they give beyond what the advisor already planned for comes off ours
		local supplied = {}
		for _, r in ipairs(claimed.reagents or {}) do
			local info = r.reagentInfo or r
			local id = info.reagent and info.reagent.itemID or info.itemID
			if id then supplied[id] = (supplied[id] or 0) + (info.quantity or math.huge) end
		end
		for id, n in pairs(e.given or {}) do if supplied[id] then supplied[id] = math.max(0, supplied[id] - n) end end
		local mine = {}
		for _, r in ipairs(reagents) do
			local off = math.min(r.quantity, supplied[r.itemID] or 0)
			if off > 0 then supplied[r.itemID] = supplied[r.itemID] - off end
			if r.quantity - off > 0 then
				table.insert(mine, { reagent = r.reagent, itemID = r.itemID, dataSlotIndex = r.dataSlotIndex, quantity = r.quantity - off })
			end
		end
		-- The game silently refuses a craft below the order's rank, so ask it first what these
		-- reagents make for this order, and turn Concentration on when that's what reaches it.
		local conc = e.concentration ~= nil
		local need = claimed.minQuality or 0
		local ui = C_TradeSkillUI
		if need > 1 and ui.GetCraftingOperationInfoForOrder then
			local all = {}
			for _, r in ipairs(mine) do table.insert(all, r) end
			-- only reagents with qualities: a single-quality one makes the game answer nothing
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
				if id and (graded[id] or not sch) then table.insert(all, info) end
			end
			local function rank(c)
				local ok, op = pcall(ui.GetCraftingOperationInfoForOrder, e.recipeID, all, claimed.orderID, c)
				return ok and op and op.craftingQuality
			end
			local q = rank(conc)
			if q and q < need and not conc then
				local qc = rank(true)
				if qc and qc >= need then
					conc = true
					e.concentration = e.concentration or true
					CH.Print(string.format("the order needs rank %d and these reagents make rank %d, so this craft uses Concentration.", need, q))
				else
					return false, string.format("the order needs rank %d but your reagents only reach rank %d, even with Concentration", need, qc or q)
				end
			elseif q and q < need then
				return false, string.format("the order needs rank %d but your reagents only reach rank %d with Concentration", need, q)
			end
		end
		crafting = e
		if (claimed.isRecraft or claimed.outputItemGUID) and ui.RecraftRecipeForOrder and claimed.outputItemGUID then
			ui.RecraftRecipeForOrder(claimed.orderID, claimed.outputItemGUID, mine, nil, conc)
		else
			-- a reagent you don't hold enough of makes the game refuse the craft without a word: leave
			-- optional ones (finishing) out and say so
			local held, names = {}, {}
			for _, r in ipairs(mine) do
				local have = C_Item and C_Item.GetItemCount and C_Item.GetItemCount(r.itemID, true, false, true, true) or r.quantity
				local nm = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(r.itemID) or ("item " .. r.itemID)
				if have >= r.quantity then
					table.insert(held, r)
					names[#names + 1] = string.format("%dx %s", r.quantity, nm)
				else
					CH.Print(string.format("left out %s: you have %d of the %d it takes", nm, have, r.quantity))
				end
			end
			mine = held
			-- a reagent in a slot the game has locked for you (an unopened finishing slot) is dropped
			local sch2 = ui.GetRecipeSchematic and ui.GetRecipeSchematic(e.recipeID, false)
			local lockedSlot = {}
			for _, sl in ipairs(sch2 and sch2.reagentSlotSchematics or {}) do
				if CH.Advisor and CH.Advisor.SlotLocked and CH.Advisor.SlotLocked(e.recipeID, sl) then lockedSlot[sl.dataSlotIndex] = true end
			end
			held, names = {}, {}
			for _, r in ipairs(mine) do
				local nm = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(r.itemID) or ("item " .. r.itemID)
				if r.dataSlotIndex and lockedSlot[r.dataSlotIndex] then
					CH.Print(string.format("left out %s: that slot is locked for you", nm))
				else
					-- the game's own shape, as CraftSim passes it
					table.insert(held, { reagent = { itemID = r.itemID }, quantity = r.quantity, dataSlotIndex = r.dataSlotIndex })
					names[#names + 1] = string.format("%dx %s", r.quantity, nm)
				end
			end
			mine = held
			CH.Print(string.format("crafting %s into the order with %s, Concentration %s, rank %s needed",
				e.name or "?", #names > 0 and table.concat(names, ", ") or "only the customer's reagents", conc and "on" or "off", tostring(need)))
			ui.CraftRecipe(e.recipeID, 1, mine, nil, claimed.orderID, conc)
		end
		return true
	end
	crafting = e
	C_TradeSkillUI.CraftRecipe(e.recipeID, amount or 1, reagents, nil, nil, e.concentration ~= nil)
	return true
end

-- A recipe ID is its spell ID: each successful cast is one craft done.
CH.On("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellID)
	if unit ~= "player" or not crafting or crafting.recipeID ~= spellID then return end
	if crafting.orderID then
		-- crafted for the order only if the game now says it can be turned in
		local e, co = crafting, C_CraftingOrders
		crafting = nil
		local function settle()
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
	Q.Remove(crafting, 1)
	if crafting.qty <= 0 then crafting = nil end
end)

-- UI hook; QueueUI replaces it.
function Q.Changed() end
