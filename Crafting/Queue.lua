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
	return table.concat({ e.char, e.recipeID, e.quality, e.concentration and "c" or "", e.orderID or "" }, ":")
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
	local me = CH.Me()
	return {
		char = CH.CharacterKey(), charName = me.name, class = me.class,
		recipeID = result.recipeID, name = result.name, quality = r.quality, tiers = result.model and result.model.maxQ,
		concentration = r.concentration, profit = r.profit, cost = r.cost, item = r.item,
		reagents = reagents, shop = shop, qty = 0,
	}
end

--- Add qty crafts of an advisor row; the same recipe, quality and Concentration choice stack.
--- extra adds fields to a new entry: firstCraft, orderID, customer, rewards.
function Q.Add(result, r, qty, extra)
	local e = Q.FromRow(result, r)
	for k, v in pairs(extra or {}) do e[k] = v end
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
	return co.GetCrafterOrders() or {}
end

--- Queue the crafting orders worth doing: each order's best craft that meets its minimum quality,
--- when the commission and rewards cover the reagents, or when it rewards something you can't buy
--- (knowledge, Artisan's Acuity and so on). Returns how many were queued and their total profit.
function Q.FillOrders(opts)
	opts = opts or {}
	local n, profit = 0, 0
	for _, order in ipairs(openOrders()) do
		local ok, result = pcall(CH.Orders.Analyze, order)
		local r = ok and result and result.best
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
	if not e.orderID then return "Craft" end
	local co = C_CraftingOrders
	local claimed = co and co.GetClaimedOrder and co.GetClaimedOrder()
	if claimed and claimed.orderID == e.orderID then
		if claimed.isFulfillable then e.stage = "crafted" elseif e.stage ~= "crafted" then e.stage = "claimed" end
	end
	return e.stage == "crafted" and "Turn in" or e.stage == "claimed" and "Craft" or "Claim"
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
		-- up to your stock target when the item has one (counting stock on every character), else a day's sales
		local par = CH.Par and itemID and CH.Par.Target(itemID)
		local units = par or CH.Scan.DailyUnits(itemID)
		local held = par and CH.Par.Held(itemID) or have(itemID or 0)
		return math.max(0, math.ceil((units - held - (queued[itemID or 0] or 0)) / (r.made or 1)))
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
		if budget >= raw then
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
		local n = demand(r, r.item)
		local res = n > 0 and analyze(r.recipeID)
		if res and res.best then add({ recipeID = r.recipeID, made = r.made, result = res }, res.best, n, false) end
	end
	return out
end

--- Reagents for the whole queue: need, have, buy and what buying costs, walking the listings. Sorted by cost, biggest first.
function Q.ShoppingList()
	local need, rank, tiers = {}, {}, {}
	for _, e in ipairs(list()) do
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
		table.insert(out, { itemID = id, rank = rank[id], tiers = tiers[id], need = n, have = h, buy = buy, unit = unit, cost = cost,
			source = d and d.source, short = d and d.short or 0, first = d and d.first, age = d and d.age,
			name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id) or ("item " .. id) })
	end
	table.sort(out, function(a, b) return (a.cost or 0) > (b.cost or 0) end)
	return out, total
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

-- The game's order page when it is showing this order, else nil.
local function orderView(orderID)
	local page = ProfessionsFrame and ProfessionsFrame.OrdersPage
	local view = page and page.OrderView
	local o = view and view.order
	if o and o.orderID == orderID and (not view.IsShown or view:IsShown()) then return view end
end

local function okResult(result)
	local ok = Enum and Enum.CraftingOrderResult and Enum.CraftingOrderResult.Ok or 0
	return result == nil or result == ok
end

-- The game answers a claim or a turn-in later: undo what we assumed if it said no.
CH.On("CRAFTINGORDERS_CLAIM_ORDER_RESPONSE", function(_, result, orderID)
	if okResult(result) then return end
	for _, e in ipairs(list()) do
		if e.orderID == orderID and e.stage == "claimed" then e.stage = nil end
	end
	CH.Print("the game didn't let you claim that order (" .. tostring(result) .. "). Someone may have taken it, or you're at your claim limit.")
	Q.Changed()
end)
CH.On("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", function(_, result, orderID)
	local e = delivering[orderID]
	delivering[orderID] = nil
	if not e or okResult(result) then return end
	e.stage, e.qty = "crafted", 1
	table.insert(list(), 1, e)
	CH.Print("the game didn't take that order (" .. tostring(result) .. "). It's back at the top of the queue.")
	Q.Changed()
end)

--- Craft an entry with its queued reagents and Concentration. Must be called from a click.
function Q.Craft(e, amount)
	local ok, why = Q.CanCraftHere(e)
	if not ok then return false, why end
	local reagents = {}
	for _, r in ipairs(e.reagents) do
		table.insert(reagents, { reagent = { itemID = r.itemID }, itemID = r.itemID, dataSlotIndex = r.slot, quantity = r.n })
	end
	if e.orderID then
		local step = Q.OrderStep(e)
		if step == "Claim" then
			C_CraftingOrders.ClaimOrder(e.orderID, profession())
			e.stage = "claimed"
			Q.Changed()
			return true
		elseif step == "Turn in" then
			local view = orderView(e.orderID)
			local done = view and view.CompleteOrderButton
			if done and done.IsShown and done:IsShown() and (not done.IsEnabled or done:IsEnabled()) then
				done:Click()
			else
				C_CraftingOrders.FulfillOrder(e.orderID, "", profession())
			end
			delivering[e.orderID] = e
			Q.Remove(e)
			return true
		end
		-- Craft an order through the game's own order page, the way its Craft button does, so the
		-- item goes into the order: open the order there first if it isn't showing.
		local view = orderView(e.orderID)
		if not view then
			local co = C_CraftingOrders
			local claimed = co and co.GetClaimedOrder and co.GetClaimedOrder()
			if claimed and claimed.orderID == e.orderID and CH.Orders and CH.Orders.Open then CH.Orders.Open(claimed) end
			view = orderView(e.orderID)
		end
		crafting = e
		local create = view and view.CreateButton
		if create and create.Click and (not create.IsEnabled or create:IsEnabled()) then
			create:Click()
			return true
		end
		amount = 1
	end
	crafting = e
	C_TradeSkillUI.CraftRecipe(e.recipeID, amount or 1, reagents, nil, e.orderID, e.concentration ~= nil)
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
			if not claimed or claimed.orderID ~= e.orderID or claimed.isFulfillable then
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
