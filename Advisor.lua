-- Crafting advisor: for one recipe, the cheapest reagents that reach each result quality, what each
-- craft is worth, and what Concentration earns per point. Same method as CraftSim:
--   * skill per reagent: ask the game (GetCraftingOperationInfo) with one slot raised to each quality
--   * cheapest mix per quality: raise reagent units cheapest-gold-per-skill first
--   * Concentration value = profit when concentrating / average Concentration cost, where the average
--     cost takes off what Ingenuity refunds (chance x 50%)
local _, CH = ...

local A = {}
CH.Advisor = A

local INGENUITY_REFUND = 0.5

local function api() return C_TradeSkillUI end

local function price(kind, itemID)
	return itemID and CH.Prices.Get(kind, "i:" .. itemID)
end

-- Required reagent slots, split into those with qualities (we choose) and fixed ones (we just pay).
function A.Slots(schematic)
	local qual, fixed = {}, {}
	local basic = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic or 1
	for _, s in ipairs(schematic.reagentSlotSchematics or {}) do
		if s.reagentType == basic and s.required ~= false and s.reagents and #s.reagents > 0 then
			local items = {}
			for _, r in ipairs(s.reagents) do
				local id = r.itemID or (r.reagent and r.reagent.itemID)
				if id then table.insert(items, id) end
			end
			local slot = { index = s.dataSlotIndex, qty = s.quantityRequired or 1, items = items }
			table.insert(#items > 1 and qual or fixed, slot)
		end
	end
	return qual, fixed
end

-- picks[i][q] = units of quality q in quality slot i
local function reagentInfos(qual, picks)
	local t = {}
	for i, slot in ipairs(qual) do
		for q, id in ipairs(slot.items) do
			local n = picks[i][q] or 0
			if n > 0 then
				table.insert(t, { reagent = { itemID = id }, itemID = id, dataSlotIndex = slot.index, quantity = n })
			end
		end
	end
	return t
end

local function operation(recipeID, qual, picks, concentrate)
	local ok, info = pcall(api().GetCraftingOperationInfo, recipeID, reagentInfos(qual, picks), nil, concentrate or false)
	return ok and info or nil
end

local function skillOf(info) return (info.baseSkill or 0) + (info.bonusSkill or 0) end

local function lowest(qual)
	local picks = {}
	for i, slot in ipairs(qual) do picks[i] = { [1] = slot.qty } end
	return picks
end

local function copyPicks(p)
	local c = {}
	for i, row in pairs(p) do c[i] = {}; for q, n in pairs(row) do c[i][q] = n end end
	return c
end

local function cost(qual, fixed, picks)
	local total = 0
	for i, slot in ipairs(qual) do
		for q, id in ipairs(slot.items) do
			local n = picks[i][q] or 0
			if n > 0 then
				local p = price("chmat", id)
				if not p then return nil end
				total = total + n * p
			end
		end
	end
	for _, slot in ipairs(fixed) do
		local p = price("chmat", slot.items[1])
		if not p then return nil end
		total = total + slot.qty * p
	end
	return total
end

local function ingenuityChance(info)
	local name = string.lower(ITEM_MOD_INGENUITY_SHORT or "Ingenuity")
	for _, s in ipairs(info.bonusStats or {}) do
		if string.lower(s.bonusStatName or "") == name then return (s.ratingPct or 0) / 100 end
	end
	return 0
end

--- Every reachable result quality with its cheapest reagents, value and profit, with and without
--- Concentration. Returns nil, reason when the recipe can't be judged.
function A.Analyze(recipeID)
	local ui = api()
	if not ui or not ui.GetCraftingOperationInfo then return nil, "This game version has no crafting simulation." end
	if not CH.Prices.Available() then return nil, "Needs TradeSkillMaster for prices." end
	local info = ui.GetRecipeInfo(recipeID)
	local schematic = ui.GetRecipeSchematic(recipeID, false)
	if not info or not schematic then return nil, "No recipe data." end
	local qual, fixed = A.Slots(schematic)
	local outputs = info.qualityItemIDs or {}
	local made = ((schematic.quantityMin or 1) + (schematic.quantityMax or schematic.quantityMin or 1)) / 2

	local base = lowest(qual)
	local op0 = operation(recipeID, qual, base)
	if not op0 then return nil, "The game gave no crafting result for this recipe." end

	-- Skill each unit adds at each reagent quality, measured like CraftSim.
	local moves = {}
	for i, slot in ipairs(qual) do
		for q = 2, #slot.items do
			local p = copyPicks(base); p[i] = { [q] = slot.qty }
			local op = operation(recipeID, qual, p)
			local perUnit = op and (skillOf(op) - skillOf(op0)) / slot.qty or 0
			local extra = (price("chmat", slot.items[q]) or math.huge) - (price("chmat", slot.items[1]) or 0)
			if perUnit > 0 and extra < math.huge then
				table.insert(moves, { slot = i, q = q, skill = perUnit, extra = math.max(0, extra) })
			end
		end
	end
	-- Cheapest gold per skill first. A unit only moves up, never back down.
	table.sort(moves, function(a, b) return a.extra / a.skill < b.extra / b.skill end)

	local found, order = {}, {}
	local function record(picks)
		local op = operation(recipeID, qual, picks)
		local q = op and (op.craftingQuality or 1)
		if not q or found[q] then return end
		local c = cost(qual, fixed, picks)
		if not c then return end
		found[q] = { quality = q, picks = copyPicks(picks), cost = c, op = op }
		table.insert(order, q)
	end
	record(base)
	local picks = copyPicks(base)
	for _, m in ipairs(moves) do
		local row = picks[m.slot]
		for _ = 1, qual[m.slot].qty do
			local from
			for q = m.q - 1, 1, -1 do if (row[q] or 0) > 0 then from = q; break end end
			if not from then break end
			row[from] = row[from] - 1
			row[m.q] = (row[m.q] or 0) + 1
			record(picks)
		end
	end
	table.sort(order)

	local rows = {}
	for _, q in ipairs(order) do
		local f = found[q]
		local item = outputs[q] or schematic.outputItemID
		local value = price("chvalue", item)
		local worth = value and value * made * CH.AH_CUT
		table.insert(rows, { quality = q, picks = f.picks, cost = f.cost, value = worth, profit = worth and worth - f.cost, item = item })
		-- The same reagents with Concentration: the game says what it costs and the quality it lands on.
		local opc = info.supportsQualities ~= false and operation(recipeID, qual, f.picks, true)
		local cc = opc and opc.concentrationCost or 0
		local cq = opc and opc.craftingQuality or q
		if cc > 0 and cq > q then -- Concentration that doesn't lift the quality is wasted
			local citem = outputs[cq] or item
			local cvalue = price("chvalue", citem)
			local cworth = cvalue and cvalue * made * CH.AH_CUT
			local avgCost = cc * (1 - ingenuityChance(opc) * INGENUITY_REFUND)
			local profit = cworth and cworth - f.cost
			table.insert(rows, { quality = cq, from = q, concentration = cc, picks = f.picks, cost = f.cost, value = cworth,
				profit = profit, perPoint = profit and profit / avgCost, item = citem })
		end
	end

	-- Recommendations, as CraftSim shows them: best profit without Concentration, best gold per point with it.
	local best, bestConc
	for _, r in ipairs(rows) do
		if r.profit then
			if not r.concentration and (not best or r.profit > best.profit) then best = r end
			if r.concentration and r.perPoint and r.perPoint > 0 and (not bestConc or r.perPoint > bestConc.perPoint) then bestConc = r end
		end
	end
	if best then best.recommended = true end
	if bestConc then bestConc.bestConcentration = true end
	return { recipeID = recipeID, name = info.name, rows = rows, qual = qual, fixed = fixed, made = made, best = best, bestConc = bestConc }
end

--- "3x Q2 Bismuth, 2x Q1 Mote" for a row's reagent picks; names from the item cache when known.
function A.PicksText(result, picks)
	local parts = {}
	for i, slot in ipairs(result.qual) do
		for q = #slot.items, 1, -1 do
			local n = picks[i][q] or 0
			if n > 0 then
				local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(slot.items[q]) or ("item " .. slot.items[q])
				table.insert(parts, string.format("%dx Q%d %s", n, q, name))
			end
		end
	end
	return table.concat(parts, ", ")
end
