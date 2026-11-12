-- Crafting orders and recrafts. For an order: the commission and any patron rewards against what
-- your own reagents cost, which qualities meet the customer's minimum, and the cheapest way to get
-- there (with or without Concentration). For a recraft: what lifting the item's quality costs
-- against what the better item sells for.
local _, CH = ...

local O = {}
CH.Orders = O

local function price(id) return id and CH.Prices.Get("chvalue", "i:" .. id) end

--- Advisor options for a crafting order (as the game hands it to the order view).
function O.FromOrder(order)
	if not order then return nil end
	local provided, slots = {}, {}
	-- only what the customer gives comes off your cost: an order's list can also name reagents the
	-- crafter must bring (source Crafter), which you still pay for
	-- (the game lists what the customer gives; only a source of Crafter means you bring it)
	local SRC = Enum and Enum.CraftingOrderReagentSource
	local crafter = SRC and SRC.Crafter
	for _, r in ipairs(order.reagents or {}) do
		local info = r.reagentInfo or r
		local slot = info.dataSlotIndex or r.dataSlotIndex or r.slotIndex
		local given = crafter == nil or r.source ~= crafter
		if info and info.reagent and slot and given then
			table.insert(provided, { reagent = { itemID = info.reagent.itemID }, itemID = info.reagent.itemID, dataSlotIndex = slot, quantity = info.quantity or 1 })
			slots[slot] = (slots[slot] or 0) + (info.quantity or 1) -- units the customer gives in this slot
		end
	end
	local rewards = 0
	for _, rw in ipairs(order.npcOrderRewards or {}) do
		local id = rw.itemLink and C_Item.GetItemInfoInstant and C_Item.GetItemInfoInstant(rw.itemLink)
		local p = id and price(id)
		if p then rewards = rewards + p * CH.AH_CUT * (rw.count or 1) end
	end
	return {
		orderID = order.orderID, recipeID = order.spellID, minQuality = order.minQuality,
		commission = (order.tipAmount or 0) - (order.consortiumCut or 0), rewards = rewards,
		provided = provided, providedSlots = slots, customer = order.customerName, orderType = order.orderType,
	}
end

--- Advisor result for an order: rows below the customer's minimum quality are marked short.
function O.Analyze(order)
	local o = O.FromOrder(order)
	if not o or not o.recipeID then return nil, "No order selected." end
	return CH.Advisor.Analyze(o.recipeID, { order = o, professionID = CH.OpenProfessionID() })
end

--- The recraft the profession window is set up for: { guid, quality } or nil.
function O.RecraftContext()
	local form = ProfessionsFrame and ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.SchematicForm
	local tx = form and form.GetTransaction and form:GetTransaction()
	if not tx or not tx.IsRecraft or not tx:IsRecraft() then return nil end
	local guid = tx.GetRecraftAllocation and tx:GetRecraftAllocation()
	if not guid then return nil end
	local link = C_Item.GetItemLinkByGUID and C_Item.GetItemLinkByGUID(guid)
	local q = link and C_TradeSkillUI.GetItemCraftedQualityByItemInfo and C_TradeSkillUI.GetItemCraftedQualityByItemInfo(link)
	return { guid = guid, quality = q, link = link }
end

-- Follow the order the player opens in the Crafting Orders tab.
local hooked
function O.Hook()
	if hooked then return end
	local view = ProfessionsFrame and ProfessionsFrame.OrdersPage and ProfessionsFrame.OrdersPage.OrderView
	if not view or not hooksecurefunc then return end
	hooksecurefunc(view, "SetOrder", function(_, order) O.current = order; CH.AdvisorUI.ShowOrder(order) end)
	if view.HookScript then view:HookScript("OnHide", function() O.current = nil; CH.AdvisorUI.Show() end) end
	hooked = true
end

CH.On("TRADE_SKILL_SHOW", function() O.Hook() end)

--- Open an order the way the game does: the profession's Crafting Orders tab, showing that order.
--- Falls back to the recipe when the order view isn't there. Returns true when the order opened.
--- Tick (or untick) Use Concentration on the order's page, as clicking its toggle would.
--- Returns true when the page took it.
function O.UseConcentration(on)
	local pf = ProfessionsFrame
	local view = pf and pf.OrdersPage and pf.OrdersPage.OrderView
	local form = view and view.OrderDetails and view.OrderDetails.SchematicForm
	if not form then return false end
	local choices = form.Details and form.Details.CraftingChoicesContainer
	local button = (choices and choices.ConcentrateContainer and choices.ConcentrateContainer.ConcentrateToggleButton)
		or (form.Concentrate and form.Concentrate.ConcentrateToggleButton)
	if button and button.GetChecked and button.Click and button.IsShown and button:IsShown() then
		if button.IsEnabled and not button:IsEnabled() then return false end -- not enough, or already top rank
		if (button:GetChecked() and true or false) ~= on then button:Click() end
		return (button:GetChecked() and true or false) == on
	end
	local tx = form.GetTransaction and form:GetTransaction() or form.transaction
	if tx and tx.SetApplyConcentration then tx:SetApplyConcentration(on); return true end
	return false
end

--- Show an order on the Crafting Orders tab. conc ticks Use Concentration once the page is up,
--- when the advisor's craft for it uses Concentration.
function O.Open(order, recipeID, conc)
	local pf = ProfessionsFrame
	local page = pf and pf.OrdersPage
	if order and page and page.ViewOrder then
		if pf.craftingOrdersTabID and pf.SetTab and pf.GetTab and pf:GetTab() ~= pf.craftingOrdersTabID then
			pf:SetTab(pf.craftingOrdersTabID)
		end
		local ok = pcall(page.ViewOrder, page, order)
		if ok then
			if conc then
				-- the page fills in its reagents a moment later, and that can reset the toggle
				local function tick() O.UseConcentration(true) end
				if C_Timer then C_Timer.After(0.2, tick); C_Timer.After(0.8, tick) else tick() end
			end
			return true
		end
	end
	if recipeID and C_TradeSkillUI and C_TradeSkillUI.OpenRecipe then C_TradeSkillUI.OpenRecipe(recipeID) end
	return false
end

-- Fetching the orders -------------------------------------------------------------------------
-- The game only keeps the list it last showed (GetCrafterOrders), so asking it once gets whatever
-- the Crafting Orders tab happened to show. Instead ask for each kind of order in turn (patron,
-- personal, public, guild), waiting for the game to allow the next request and retrying when it
-- says slow down, and keep every order seen. Order IDs are compared as text: they can be large
-- numbers that don't compare equal once copied.

--- Whether two order IDs are the same order.
function O.Same(a, b) return a ~= nil and b ~= nil and tostring(a) == tostring(b) end

O.cache = {}      -- [id as text] = order, from the last fetch
O.fetching = false
local canRequest = true
CH.On("CRAFTINGORDERS_CAN_REQUEST", function() canRequest = true end)

O.seen = {}       -- [id as text] = when the game last listed it
O.STALE = 10 * 60 -- an order not seen in the game's list for this long isn't treated as available

local function remember(orders, into)
	local now = time()
	into = into or O.cache
	for _, o in ipairs(orders or {}) do
		if o.orderID then into[tostring(o.orderID)] = o; O.seen[tostring(o.orderID)] = now end
	end
end

--- Drop an order from the list (it was fulfilled, or the game says it's gone).
function O.Forget(id)
	if id == nil then return end
	O.cache[tostring(id)], O.seen[tostring(id)] = nil, nil
end

--- Every order known: the last fetch, what the game lists now, and your claimed order.
function O.All()
	local co = C_CraftingOrders
	if co and co.GetCrafterOrders then remember(co.GetCrafterOrders()) end
	local claimed = co and co.GetClaimedOrder and co.GetClaimedOrder()
	if claimed then remember({ claimed }) end
	local out = {}
	for _, o in pairs(O.cache) do table.insert(out, o) end
	table.sort(out, function(a, b) return tostring(a.orderID) < tostring(b.orderID) end)
	return out
end

--- The live order for an ID (claimed, else listed by the game recently), or nil. A remembered
--- order the game hasn't listed for a while is only an old sighting, so it isn't returned.
function O.Live(id)
	local co = C_CraftingOrders
	local claimed = co and co.GetClaimedOrder and co.GetClaimedOrder()
	if claimed and O.Same(claimed.orderID, id) then return claimed end
	O.All()
	local k = tostring(id)
	if O.seen[k] and time() - O.seen[k] <= O.STALE then return O.cache[k] end
	return nil
end

local function profession()
	local info = C_TradeSkillUI and C_TradeSkillUI.GetChildProfessionInfo and C_TradeSkillUI.GetChildProfessionInfo()
	return info and info.profession
end

local function request(orderType, prof, done, tries)
	local co = C_CraftingOrders
	local waited = 0
	local function send()
		if not canRequest and waited < 8 then
			waited = waited + 0.25
			return C_Timer.After(0.25, send)
		end
		canRequest = false
		local E = Enum and Enum.CraftingOrderResult or {}
		local cb = function(result)
			if result == nil or result == (E.Ok or 0) then
				remember(co.GetCrafterOrders and co.GetCrafterOrders(), O.incoming)
				return done(true)
			end
			if (result == E.ThrottleViolation or result == E.Timeout) and (tries or 0) < 3 then
				return C_Timer.After(1, function() request(orderType, prof, done, (tries or 0) + 1) end)
			end
			done(false)
		end
		local S = Enum and Enum.CraftingOrderSortType or {}
		local ok = pcall(co.RequestCrafterOrders, {
			orderType = orderType, searchFavorites = false, initialNonPublicSearch = false,
			primarySort = { sortType = S.ItemName or 0, reversed = false },
			secondarySort = { sortType = S.MaxTip or 0, reversed = false },
			forCrafter = true, offset = 0, profession = prof,
			callback = C_FunctionContainers and C_FunctionContainers.CreateCallback and C_FunctionContainers.CreateCallback(cb) or cb,
		})
		if not ok then done(false) end
	end
	send()
end

--- Ask the game for every kind of order for the open profession, one after another; onDone(n, why)
--- once they're in. The list keeps what earlier fetches found until a fetch replaces it.
function O.Fetch(onDone)
	local co = C_CraftingOrders
	local prof = profession()
	if not (co and co.RequestCrafterOrders and prof) then
		if onDone then onDone(#O.All(), "open the profession window first") end
		return false
	end
	if O.fetching then return false end
	O.fetching = true
	local T = Enum and Enum.CraftingOrderType or {}
	local types = { T.Npc or 3, T.Personal or 2, T.Public or 0, T.Guild or 1 }
	-- the list on screen keeps the orders it has while the new ones come in, and swaps to the new
	-- set once every kind is in (as CraftSim's does), rather than emptying and filling again
	local fresh, got, i = {}, false, 0
	O.incoming = fresh
	local function step()
		i = i + 1
		if not types[i] then
			O.fetching = false
			O.incoming = nil
			if got then
				local co2 = C_CraftingOrders
				local claimed = co2 and co2.GetClaimedOrder and co2.GetClaimedOrder()
				if claimed then remember({ claimed }, fresh) end
				O.cache = fresh
			end
			local n = #O.All()
			if onDone then onDone(n, not got and "the game didn't answer; open the Crafting Orders tab and try again" or nil) end
			return
		end
		request(types[i], prof, function(ok) got = got or ok; step() end)
	end
	step()
	return true
end

-- Order and first-craft lists (the Orders tab) ------------------------------------------------

local knowledge = {}
--- Does an item give profession knowledge (a knowledge point)? Read from its tooltip, cached.
function O.IsKnowledge(id)
	if not id then return false end
	if knowledge[id] ~= nil then return knowledge[id] end
	local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
	local yes = name and name:find("Knowledge") and true or false
	local tip = not yes and C_TooltipInfo and C_TooltipInfo.GetItemByID and C_TooltipInfo.GetItemByID(id)
	for _, l in ipairs(tip and tip.lines or {}) do
		if l.leftText and l.leftText:find("Knowledge") then yes = true; break end
	end
	if name or tip then knowledge[id] = yes end
	return yes
end

local TYPES = { [0] = "Public", [1] = "Guild", [2] = "Personal", [3] = "Patron" }

--- An order's rewards: { { id, count, value (after cut, nil if it can't be sold), knowledge } },
--- their sellable total, and whether any gives a knowledge point.
function O.Rewards(order)
	local out, total, kp = {}, 0, false
	for _, rw in ipairs(order and order.npcOrderRewards or {}) do
		local id = rw.itemLink and C_Item.GetItemInfoInstant and C_Item.GetItemInfoInstant(rw.itemLink)
		if id then
			local n = rw.count or 1
			local p = not CH.Unsellable(id) and price(id)
			local k = O.IsKnowledge(id)
			kp = kp or k
			table.insert(out, { id = id, count = n, value = p and p * CH.AH_CUT * n or nil, knowledge = k })
			total = total + (p and p * CH.AH_CUT * n or 0)
		end
	end
	return out, total, kp
end

--- The reagents you supply for an order's craft, with how many you hold, most expensive first.
function O.CostLines(result, r)
	local out = CH.Advisor.CostLines(result, r.picks, r.finishing)
	for _, l in ipairs(out) do
		l.have = (C_Item and C_Item.GetItemCount and l.id and C_Item.GetItemCount(l.id, true, false, true, true)) or 0
	end
	table.sort(out, function(a, b) return (a.total or 0) > (b.total or 0) end)
	return out
end

--- Every order the game has listed for the open profession, worked out like the advisor does:
--- { order, orderID, recipeID, name, item, from, kind, minQuality, commission, rewards, rewardValue,
---   kp, cost, profit, quality, concentration, row, result, ok (some craft meets the minimum) }.
--- Best profit first; orders you can't fill go last.
-- Working an order out is the advisor's full search plus a bag count per reagent, so O.List keeps
-- each order's row and only works it out again when something it depends on changes: your bags,
-- Concentration or skill (O.Invalidate), the order itself, or after a minute (prices drift).
-- Claim, Craft and Turn in redraw the list several times a click; without this each redraw
-- re-ran the search for every order.
local rows, gen = {}, 0
O.MAX_AGE = 60
function O.Invalidate() gen = gen + 1 end
for _, ev in ipairs({ "BAG_UPDATE_DELAYED", "CURRENCY_DISPLAY_UPDATE", "SKILL_LINES_CHANGED", "TRAIT_CONFIG_UPDATED", "PLAYERBANKSLOTS_CHANGED", "NEW_RECIPE_LEARNED" }) do
	CH.On(ev, O.Invalidate)
end

local function signature(order)
	return table.concat({ tostring(order.spellID), tostring(order.minQuality), tostring(order.tipAmount),
		tostring(order.consortiumCut), tostring(#(order.reagents or {})), tostring(#(order.npcOrderRewards or {})), tostring(order.customerName), tostring(order.orderType) }, ":")
end

function O.List()
	local out = {}
	local now = time()
	local fresh = {}
	for _, order in ipairs(O.All()) do
		local k, sig = tostring(order.orderID), signature(order)
		local c = rows[k]
		if not (c and c.gen == gen and c.sig == sig and now - c.at < O.MAX_AGE) then
			c = { gen = gen, sig = sig, at = now, entry = O.Row(order) }
		end
		c.entry.order = order -- the latest copy the game gave (claimed, fulfillable)
		fresh[k] = c
		table.insert(out, c.entry)
	end
	rows = fresh
	table.sort(out, function(a, b)
		if a.ok ~= b.ok then return a.ok end
		if (a.have or false) ~= (b.have or false) then return a.have or false end
		if a.kp ~= b.kp then return a.kp end
		return (a.profit or -math.huge) > (b.profit or -math.huge)
	end)
	return out
end

--- One order worked out for the list (uncached; O.List keeps these).
function O.Row(order)
	local out = {}
	local current = CH.Scan and CH.Scan.CurrentLine and CH.Scan.CurrentLine()
	local ui = C_TradeSkillUI
	local child = ui and ui.GetChildProfessionInfo and ui.GetChildProfessionInfo()
	local cid = child and ui.GetConcentrationCurrencyID and ui.GetConcentrationCurrencyID(child.professionID)
	local cinfo = cid and cid ~= 0 and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(cid)
	local concNow = cinfo and cinfo.quantity
	do
		local line, expansion
		if CH.Scan and CH.Scan.Expansion then line, expansion = CH.Scan.Expansion(order.spellID) end
		local ok, result = pcall(O.Analyze, order)
		result = ok and result or nil
		local r = result and (result.best or result.bestConc)
		local rewards, value, kp = O.Rewards(order)
		-- whether your bags, banks and warband bank hold the reagents (and Concentration) for one craft
		local have, missing, reagentsHave, reagentsNeed, lowName
		if r then
			local n, lines = CH.Advisor.MaxCraftable(result, r, concNow)
			have = n >= 1
			missing = {}
			local low
			for _, l in ipairs(lines) do
				if l.have < l.need then table.insert(missing, l) end
				-- each reagent the craft takes: whether you hold enough of it
				-- the reagent you're furthest short on (or closest to running short of): its units
				local ratio = l.need > 0 and l.have / l.need or math.huge
				if not low or ratio < low then low, reagentsHave, reagentsNeed, lowName = ratio, l.have, l.need, l.name end
			end
		end
		local info = C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(order.spellID)
		-- a recipe this character hasn't learned can't be crafted, whatever the numbers say
		local learned = not (info and info.learned == false)
		if not learned then r = nil end
		table.insert(out, { order = order, orderID = order.orderID, recipeID = order.spellID, item = order.itemID,
			name = (info and info.name) or (order.itemID and C_Item.GetItemNameByID and C_Item.GetItemNameByID(order.itemID)) or "?",
			from = order.customerName or TYPES[order.orderType] or "?", kind = TYPES[order.orderType] or "?",
			minQuality = order.minQuality, commission = (order.tipAmount or 0) - (order.consortiumCut or 0),
			rewards = rewards, rewardValue = value, kp = kp, row = r, result = result, ok = r ~= nil, learned = learned,
			tiers = result and result.model and result.model.maxQ,
			cost = r and r.cost, profit = r and r.profit, quality = r and r.quality, concentration = r and r.concentration,
			line = line, expansion = expansion, current = not line or not current or line == current,
			have = have, missing = missing, reagentsHave = reagentsHave, reagentsNeed = reagentsNeed,
			reagentsPct = reagentsNeed and reagentsNeed > 0 and reagentsHave / reagentsNeed or nil, reagentsLow = lowName,
			customer = order.orderType == 3 and "NPC" or order.customerName or TYPES[order.orderType] or "?",
			costLines = r and result and O.CostLines(result, r) or nil,
			-- no row because a reagent you'd supply has no price, not because the quality is out of reach
			unpriced = not r and result and result.model and result.model.unpriced or nil })
	end
	return out[1]
end

--- Print, for each listed order, what the advisor makes of it: the rank it needs, the ranks it
--- found with and without Concentration, and any error. For working out "can't reach".
function O.Debug()
	local orders = O.All()
	CH.Print(string.format("%d orders known (%s)", #orders, O.fetching and "fetching" or "not fetching"))
	for _, order in ipairs(orders) do
		local ok, result, why = pcall(O.Analyze, order)
		local info = C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(order.spellID)
		local head = string.format("%s (recipe %s) needs rank %s:", info and info.name or "?", tostring(order.spellID), tostring(order.minQuality))
		-- what the order lists, and who brings it (source 1 customer, 2 crafter)
		local given = {}
		for _, r in ipairs(order.reagents or {}) do
			local i = r.reagentInfo or r
			given[#given + 1] = string.format("%s:%sx%s@%s", tostring(r.source), tostring(i.reagent and i.reagent.itemID), tostring(i.quantity), tostring(i.dataSlotIndex or r.slotIndex))
		end
		CH.Print(string.format("  reagentState %s, listed: %s", tostring(order.reagentState), #given > 0 and table.concat(given, " ") or "none"))
		-- the recipe's slots: data slot, units, first item, to match against what the order lists
		local sch = C_TradeSkillUI.GetRecipeSchematic and C_TradeSkillUI.GetRecipeSchematic(order.spellID, false)
		local slots = {}
		for _, sl in ipairs(sch and sch.reagentSlotSchematics or {}) do
			local first = sl.reagents and sl.reagents[1]
			slots[#slots + 1] = string.format("%s:%sx%s", tostring(sl.dataSlotIndex), tostring(first and (first.itemID or first.reagent and first.reagent.itemID)), tostring(sl.quantityRequired))
		end
		CH.Print("  recipe slots: " .. (#slots > 0 and table.concat(slots, " ") or "none"))
		if not ok then
			CH.Print(head .. " error " .. tostring(result))
		elseif not result then
			CH.Print(head .. " no result" .. (why and (": " .. tostring(why)) or ""))
		else
			local m = result.model or {}
			local parts = {}
			for _, r in ipairs(result.rows or {}) do
				parts[#parts + 1] = string.format("r%s%s %s%s", tostring(r.quality), r.concentration and ("c" .. math.floor(r.concentration)) or "",
					r.profit and CH.FormatMoney(math.floor(r.profit)) or "nil", r.short and " short" or "")
			end
			CH.Print(string.format("%s skill %s/%s, ranks %s, %d rows: %s%s", head, tostring(m.skill0), tostring(m.difficulty), tostring(m.maxQ),
				#(result.rows or {}), table.concat(parts, "; "), m.unpriced and ("; no price for item " .. tostring(m.unpriced)) or ""))
		end
	end
end

--- Learned recipes of the open profession that still give their first-craft knowledge point, at
--- their cheapest craft: { recipeID, name, item, quality, cost, value (what the item sells for,
--- after the cut), net (value less cost: negative is what the point costs you), row, result }.
--- Cheapest point first.
function O.FirstCrafts()
	local ui = C_TradeSkillUI
	local out = {}
	if not ui or not ui.GetAllRecipeIDs then return out end
	for _, id in ipairs(ui.GetAllRecipeIDs() or {}) do
		local info = ui.GetRecipeInfo(id)
		if info and info.learned and info.firstCraft and not info.isRecraft and not info.isSalvageRecipe
			and not info.isGatheringRecipe and not info.isDummyRecipe then
			local ok, result = pcall(CH.Advisor.Analyze, id, { professionID = CH.OpenProfessionID() })
			local best
			for _, r in ipairs(ok and result and result.rows or {}) do
				if r.cost and not r.short and not r.concentration and (not best or r.cost < best.cost) then best = r end
			end
			table.insert(out, { recipeID = id, name = info.name or "?", item = best and best.item, quality = best and best.quality,
				tiers = result and result.model and result.model.maxQ, cost = best and best.cost, value = best and best.value,
				net = best and best.cost and ((best.value or 0) - best.cost), row = best, result = ok and result or nil })
		end
	end
	table.sort(out, function(a, b) return (a.net or -math.huge) > (b.net or -math.huge) end)
	return out
end
