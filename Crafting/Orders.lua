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
	for _, r in ipairs(order.reagents or {}) do
		local info = r.reagentInfo or r
		local slot = info.dataSlotIndex or r.dataSlotIndex or r.slotIndex
		if info and info.reagent and slot then
			table.insert(provided, { reagent = { itemID = info.reagent.itemID }, itemID = info.reagent.itemID, dataSlotIndex = slot, quantity = info.quantity or 1 })
			slots[slot] = true
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
	for _, order in ipairs(co and co.GetCrafterOrders and co.GetCrafterOrders() or {}) do
		local ok, result = pcall(O.Analyze, order)
		result = ok and result or nil
		local r = result and (result.best or result.bestConc)
		local rewards, value, kp = O.Rewards(order)
		local info = C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(order.spellID)
		table.insert(out, { order = order, orderID = order.orderID, recipeID = order.spellID, item = order.itemID,
			name = (info and info.name) or (order.itemID and C_Item.GetItemNameByID and C_Item.GetItemNameByID(order.itemID)) or "?",
			from = order.customerName or TYPES[order.orderType] or "?", kind = TYPES[order.orderType] or "?",
			minQuality = order.minQuality, commission = (order.tipAmount or 0) - (order.consortiumCut or 0),
			rewards = rewards, rewardValue = value, kp = kp, row = r, result = result, ok = r ~= nil,
			tiers = result and result.model and result.model.maxQ,
			cost = r and r.cost, profit = r and r.profit, quality = r and r.quality, concentration = r and r.concentration })
	end
	table.sort(out, function(a, b)
		if a.ok ~= b.ok then return a.ok end
		if a.kp ~= b.kp then return a.kp end
		return (a.profit or -math.huge) > (b.profit or -math.huge)
	end)
	return out
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
