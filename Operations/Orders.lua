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
	local SRC = Enum and Enum.CraftingOrderReagentSource
	local customer = SRC and SRC.Customer or 1
	for _, r in ipairs(order.reagents or {}) do
		local info = r.reagentInfo or r
		local slot = info.dataSlotIndex or r.dataSlotIndex or r.slotIndex
		local given = r.source == nil or r.source == customer
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
function O.Open(order, recipeID)
	local pf = ProfessionsFrame
	local page = pf and pf.OrdersPage
	if order and page and page.ViewOrder then
		if pf.craftingOrdersTabID and pf.SetTab and pf.GetTab and pf:GetTab() ~= pf.craftingOrdersTabID then
			pf:SetTab(pf.craftingOrdersTabID)
		end
		local ok = pcall(page.ViewOrder, page, order)
		if ok then return true end
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

local function remember(orders)
	local now = time()
	for _, o in ipairs(orders or {}) do
		if o.orderID then O.cache[tostring(o.orderID)] = o; O.seen[tostring(o.orderID)] = now end
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
				remember(co.GetCrafterOrders and co.GetCrafterOrders())
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
	local fresh, got, i = {}, false, 0
	local old = O.cache
	O.cache = fresh
	local function step()
		i = i + 1
		if not types[i] then
			O.fetching = false
			if not got then O.cache = old end -- nothing came back: keep what we had
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

--- Every order the game has listed for the open profession, worked out like the advisor does:
--- { order, orderID, recipeID, name, item, from, kind, minQuality, commission, rewards, rewardValue,
---   kp, cost, profit, quality, concentration, row, result, ok (some craft meets the minimum) }.
--- Best profit first; orders you can't fill go last.
function O.List()
	local co = C_CraftingOrders
	local out = {}
	local current = CH.Scan and CH.Scan.CurrentLine and CH.Scan.CurrentLine()
	local ui = C_TradeSkillUI
	local child = ui and ui.GetChildProfessionInfo and ui.GetChildProfessionInfo()
	local cid = child and ui.GetConcentrationCurrencyID and ui.GetConcentrationCurrencyID(child.professionID)
	local cinfo = cid and cid ~= 0 and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(cid)
	local concNow = cinfo and cinfo.quantity
	for _, order in ipairs(O.All()) do
		local line, expansion
		if CH.Scan and CH.Scan.Expansion then line, expansion = CH.Scan.Expansion(order.spellID) end
		local ok, result = pcall(O.Analyze, order)
		result = ok and result or nil
		local r = result and (result.best or result.bestConc)
		local rewards, value, kp = O.Rewards(order)
		-- whether your bags, banks and warband bank hold the reagents (and Concentration) for one craft
		local have, missing
		if r then
			local n, lines = CH.Advisor.MaxCraftable(result, r, concNow)
			have = n >= 1
			missing = {}
			for _, l in ipairs(lines) do if l.have < l.need then table.insert(missing, l) end end
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
			have = have, missing = missing,
			-- no row because a reagent you'd supply has no price, not because the quality is out of reach
			unpriced = not r and result and result.model and result.model.unpriced or nil })
	end
	table.sort(out, function(a, b)
		if a.ok ~= b.ok then return a.ok end
		if (a.have or false) ~= (b.have or false) then return a.have or false end
		if a.kp ~= b.kp then return a.kp end
		return (a.profit or -math.huge) > (b.profit or -math.huge)
	end)
	return out
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
