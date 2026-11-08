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
