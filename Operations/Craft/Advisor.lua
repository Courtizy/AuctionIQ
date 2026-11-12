-- Crafting advisor: for one recipe, the cheapest reagents that reach each result quality, what each
-- craft earns on average, and what Concentration earns per point. Same method as CraftSim:
--   * skill per reagent: ask the game (GetCraftingOperationInfo) with one slot raised to each quality
--   * cheapest mix per quality: the exact cheapest mix that clears each quality's skill threshold
--     (checked against the game when it's open), plus CraftSim's cheapest-gold-per-skill walk
--   * average profit counts Multicraft's extra items and Resourcefulness's saved reagents (Stats.lua)
--   * Concentration value = average profit when concentrating / average Concentration cost after
--     Ingenuity refunds, with spec perks that raise the refund
--   * finishing reagents: every combination is tried and the best kept
-- Measure() asks the game once; Evaluate() can then be re-run with simulated stats (more skill, a
-- spec plan, other gear) without asking again.
local _, CH = ...

local A = {}
CH.Advisor = A

local unpack = unpack or table.unpack

local function api() return C_TradeSkillUI end
local function St() return CH.Stats end

local function price(kind, itemID)
	return itemID and CH.Prices.Get(kind, "i:" .. itemID)
end

-- A reagent's price in a recipe: buying it, or making it when someone on the warband crafts it for
-- less (Scan.ReagentPrice). Marks the model when a crafted price was used.
local function reagentPrice(model, itemID)
	if not (CH.Scan and CH.Scan.ReagentPrice) then return price("chmat", itemID) end
	local p, via = CH.Scan.ReagentPrice(itemID, model and model.recipeID)
	if via and model then model.viaCraft = true end
	return p, via
end
A.ReagentPrice = reagentPrice

-- n units of a reagent: on the "held" basis the ones you hold cost what they'd sell for after the
-- cut (their opportunity cost; today's price if there's no sale price), and only the rest cost today's price.
-- On any other basis every unit costs the same. nil when there's no price for a unit you'd buy.
local function heldInfo(model, id)
	model.heldCache = model.heldCache or {}
	local h = model.heldCache[id]
	if not h then
		local P = CH.Prices
		local n = P.Held and P.Held(id) or 0
		-- opportunity cost: what yours would bring if you sold them instead (after the cut)
		local v = n > 0 and P.SellValue(id) or nil
		h = { n = n, each = v, paid = n > 0 and P.PaidEach and P.PaidEach(id) or nil }
		model.heldCache[id] = h
	end
	return h
end
-- What buying n of a reagent costs each, the way the shopping list prices it: walking the AH
-- listings you've seen (a live search, else your last scan) for those n units. Only on the
-- replacement basis (today's price), for a reagent you'd buy rather than craft; nil otherwise.
local function listedEach(model, id, n, via)
	if via or not (CH.Depth and CH.Depth.Cost) then return nil end -- crafting it is cheaper: that's its price
	-- listings change: a minute at most, then look again
	if not model.listedCache or time() - (model.listedAt or 0) > 60 then model.listedCache, model.listedAt = {}, time() end
	local key = id * 100000 + n
	local c = model.listedCache[key]
	if c == nil then
		local basis = CH.Prices.CostBasis and CH.Prices.CostBasis() or "replacement"
		local d = (basis == "replacement" or basis == "held") and CH.Depth.Cost(id, n)
		c = d and d.source ~= "chmat" and d.unit or false
		model.listedCache[key] = c
	end
	return c or nil
end
A.ListedEach = listedEach

local function unitsCost(model, id, n)
	if n <= 0 then return 0 end
	local buy, via = reagentPrice(model, id)
	buy = listedEach(model, id, n, via) or buy
	if not (CH.Prices.CostBasis and CH.Prices.CostBasis() == "held") then return buy and n * buy end
	local h = heldInfo(model, id)
	local own = math.min(n, h.n)
	local ownEach = h.each or buy
	if own > 0 and not ownEach then return nil end
	if n - own > 0 and not buy then return nil end
	return own * (ownEach or 0) + (n - own) * (buy or 0)
end
A.UnitsCost = unitsCost
A.HeldInfo = heldInfo

local function reagentType(name, fallback)
	return Enum and Enum.CraftingReagentType and Enum.CraftingReagentType[name] or fallback
end

--- True when the game has this slot locked for you (a finishing slot your specialization hasn't
--- opened yet shows a padlock). A craft that fills a locked slot is refused without a word.
function A.SlotLocked(recipeID, s)
	local ui = C_TradeSkillUI
	local mcr = s and s.slotInfo and s.slotInfo.mcrSlotID
	if not (ui and ui.GetReagentSlotStatus and mcr and recipeID) then return false end
	local info = ui.GetRecipeInfo and ui.GetRecipeInfo(recipeID)
	local ok, locked = pcall(ui.GetReagentSlotStatus, mcr, recipeID, info and info.skillLineAbilityID)
	return ok and locked == true
end

--- Required reagent slots, split into those with qualities (we choose) and fixed ones (we just pay),
--- plus finishing slots. On a crafting order, what the customer gives comes off each slot's quantity.
function A.Slots(schematic, provided)
	local qual, fixed, finishing = {}, {}, {}
	local basic, fin = reagentType("Basic", 1), reagentType("Finishing", 2)
	for _, s in ipairs(schematic.reagentSlotSchematics or {}) do
		local items = {}
		for _, r in ipairs(s.reagents or {}) do
			local id = r.itemID or (r.reagent and r.reagent.itemID)
			if id then table.insert(items, id) end
		end
		-- the customer may give all of a slot (left out) or part of it (we supply the rest)
		local given = provided and (provided[s] or provided[s.dataSlotIndex])
		local need = s.quantityRequired or 1
		if given == true then given = need end
		need = need - (given or 0)
		if need > 0 and #items > 0 then
			local slot = { index = s.dataSlotIndex, qty = need, items = items }
			if s.reagentType == basic and s.required ~= false then
				table.insert(#items > 1 and qual or fixed, slot)
			elseif s.reagentType == fin and not A.SlotLocked(schematic.recipeID, s) then
				table.insert(finishing, slot)
			end
		end
	end
	return qual, fixed, finishing
end

--- The scroll item each quality of an enchant makes: { [quality] = itemID }, or {} when the game
--- doesn't say. Tries the recipe's quality IDs (what the game's own page passes), then plain ranks.
A.VELLUM = 38682 -- Enchanting Vellum

function A.ScrollOutputs(recipeID, info)
	local ui = C_TradeSkillUI
	local out = {}
	-- the game has no output item for an enchant (GetRecipeOutputItemData answers nothing useful),
	-- so, as CraftSim does, the scroll comes from a table keyed by the recipe's craftingDataID
	if ui and ui.GetCraftingOperationInfo and CH.EnchantScrolls then
		local ok, op = pcall(ui.GetCraftingOperationInfo, recipeID, {}, nil, false)
		local ids = ok and op and op.craftingDataID and CH.EnchantScrolls[op.craftingDataID]
		if ids then for q, id in ipairs(ids) do out[q] = id end; return out end
	end
	if not (ui and ui.GetRecipeOutputItemData) then return out end
	local function ask(q)
		local ok, data = pcall(ui.GetRecipeOutputItemData, recipeID, {}, nil, q)
		if not (ok and data) then return nil end
		if data.itemID then return data.itemID end
		local link = data.hyperlink
		return link and tonumber(link:match("item:(%d+)")) or nil
	end
	local ids = info and info.qualityIDs
	if type(ids) == "table" and #ids > 0 then
		for q, qid in ipairs(ids) do out[q] = ask(qid) end
	end
	local n = math.max(1, info and info.maxQuality or 1, type(ids) == "table" and #ids or 0)
	local found = 0
	for q = 1, n do if out[q] then found = found + 1 end end
	if found == 0 then
		for q = 1, n do out[q] = ask(q); if out[q] then found = found + 1 end end
	end
	if found == 0 then return {} end
	-- a rank the game didn't name stays in its place as false (unpriced, shown as such), so a known
	-- rank 2 is kept even when rank 1 is missing
	local last = 0
	for q = 1, n do if out[q] then last = q end end
	for q = 1, last do if not out[q] then out[q] = false end end
	for q = last + 1, n do out[q] = nil end
	-- one ID for every quality is no quality split at all
	if #out > 1 then
		local same = true
		for q = 2, #out do if out[q] ~= out[1] then same = false end end
		if same then out = { out[1] } end
	end
	return out
end

-- picks[i][q] = units of quality q in quality slot i
local function reagentInfos(model, picks, fin, ownOnly)
	local t = {}
	for i, slot in ipairs(model.qual) do
		for q, id in ipairs(slot.items) do
			local n = picks[i][q] or 0
			if n > 0 then
				table.insert(t, { reagent = { itemID = id }, itemID = id, dataSlotIndex = slot.index, quantity = n })
			end
		end
	end
	for _, f in ipairs(fin or {}) do
		table.insert(t, { reagent = { itemID = f.itemID }, itemID = f.itemID, dataSlotIndex = f.slot, quantity = 1 })
	end
	if not ownOnly then for _, r in ipairs(model.provided or {}) do table.insert(t, r) end end
	return t
end

local function skillOf(info) return (info.baseSkill or 0) + (info.bonusSkill or 0) end

local function operation(model, picks, concentrate, fin)
	local ui = api()
	local infos = reagentInfos(model, picks, fin)
	local ok, info
	if model.orderID and ui.GetCraftingOperationInfoForOrder then
		-- Ask with the customer's reagents and with only yours, and keep the answer with more skill:
		-- the one that counts their reagents. (Only yours can leave their reagents' quality out: a
		-- claimed Phoenix Oil read skill 141 that way, where the order's page says 323.)
		local ok1, all = pcall(ui.GetCraftingOperationInfoForOrder, model.recipeID, infos, model.orderID, concentrate or false)
		local ok2, own = pcall(ui.GetCraftingOperationInfoForOrder, model.recipeID, reagentInfos(model, picks, fin, true), model.orderID, concentrate or false)
		all, own = ok1 and all or nil, ok2 and own or nil
		info = all
		if own and (not all or skillOf(own) > skillOf(all)) then info = own end
		ok = info ~= nil
		if not (ok and info) then -- the game may not answer for an order you haven't claimed
			ok, info = pcall(ui.GetCraftingOperationInfo, model.recipeID, infos, nil, concentrate or false)
		end
	else
		ok, info = pcall(ui.GetCraftingOperationInfo, model.recipeID, infos, model.allocationGUID, concentrate or false)
	end
	return ok and info or nil
end
A.Operation = operation


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

-- Reagents this recipe needs that Resourcefulness can save (all required ones we pay for).
local function cost(model, picks)
	local total = 0
	for i, slot in ipairs(model.qual) do
		for q, id in ipairs(slot.items) do
			local n = picks[i][q] or 0
			if n > 0 then
				local c = unitsCost(model, id, n)
				if not c then model.unpriced = id; return nil end
				total = total + c
			end
		end
	end
	for _, slot in ipairs(model.fixed) do
		local c = unitsCost(model, slot.items[1], slot.qty)
		if not c then model.unpriced = slot.items[1]; return nil end
		total = total + c
	end
	return total
end

local function skillAt(model, picks, base)
	local s = base
	for i, row in pairs(picks) do
		for q, n in pairs(row) do s = s + n * (model.perUnit[i][q] or 0) end
	end
	return s
end

--- Quality a skill reaches, from the thresholds the game reported (or the usual fractions).
function A.QualityAt(model, skill)
	local q = 1
	for k = 2, model.maxQ do
		if model.thresholds[k] and skill >= model.thresholds[k] - 1e-6 then q = k end
	end
	return q
end


--- Asks the game everything the advisor needs about one recipe. opts: allocationGUID (recraft),
--- order = { orderID, minQuality, provided = {reagentInfo...}, providedSlots = {[slot]=true},
--- commission, rewards }, professionID.
function A.Measure(recipeID, opts)
	opts = opts or {}
	local ui = api()
	if not ui or not ui.GetCraftingOperationInfo then return nil, "This game version has no crafting simulation." end
	if not CH.Prices.Available() then return nil, "Needs TradeSkillMaster for prices." end
	local info = ui.GetRecipeInfo(recipeID)
	local schematic = ui.GetRecipeSchematic(recipeID, opts.allocationGUID ~= nil)
	if not info or not schematic then return nil, "No recipe data." end
	local order = opts.order
	-- The slot a customer's reagent fills is the recipe slot that lists its item. Recipe slots can
	-- share a data slot number (Midnight's Phoenix Oil has Mote of Light and Eversinging Dust both in
	-- data slot 1), so slots are told apart by the item, never by the number alone.
	local slotOf, givenSlots = {}, order and order.providedSlots
	for _, s in ipairs(schematic.reagentSlotSchematics or {}) do
		for _, r in ipairs(s.reagents or {}) do
			local id = r.itemID or (r.reagent and r.reagent.itemID)
			if id then slotOf[id] = s end
		end
	end
	if order and order.provided then
		givenSlots = {}
		for _, r in ipairs(order.provided) do
			local key = slotOf[r.itemID] or r.dataSlotIndex
			if key then givenSlots[key] = (givenSlots[key] or 0) + (r.quantity or 1) end
		end
	end
	local qual, fixed, finishing = A.Slots(schematic, givenSlots)
	-- what the customer gives, no more units per slot than the slot takes (a list can name more)
	local provided
	if order and order.provided then
		local used = {}
		provided = {}
		for _, r in ipairs(order.provided) do
			local s = slotOf[r.itemID]
			local key = s or r.dataSlotIndex
			local slot = s and s.dataSlotIndex or r.dataSlotIndex
			local room = s and ((s.quantityRequired or 1) - (used[key] or 0)) or r.quantity
			local n = math.min(r.quantity or 1, room or 0)
			-- only reagents with qualities go to the game: a single-quality one (Phoenix Oil's Sunglass
			-- Vial) makes it answer nothing at all, as CraftSim notes, and adds no skill anyway
			local quality = not s or #(s.reagents or {}) > 1
			if n > 0 and key and quality then
				used[key] = (used[key] or 0) + n
				table.insert(provided, { reagent = r.reagent, itemID = r.itemID, dataSlotIndex = slot, quantity = n })
			end
		end
	end
	local outputs = info.qualityItemIDs or {}
	-- An enchant has no item of its own (it's cast on gear), so neither field names one: what it
	-- makes for the AH is the scroll on Enchanting Vellum. Ask the game what each quality's scroll is.
	if info.isEnchantingRecipe or (#outputs == 0 and not schematic.outputItemID) then
		local scrolls = A.ScrollOutputs(recipeID, info)
		if #scrolls > 0 then
			outputs = scrolls
			-- each scroll is cast onto one Enchanting Vellum: it costs like a reagent and goes on the
			-- shopping list, though the game takes it as the craft's target, not in a reagent slot
			if info.isEnchantingRecipe and not order then table.insert(fixed, { qty = 1, items = { A.VELLUM }, vellum = true }) end
		end
	end
	-- Gear (rods, tools, armour) keeps one item ID for every quality: the quality is its item level,
	-- so each quality is priced by the item at that level (TSM's "i:ID::iLEVEL").
	local keys, maxQ = {}, math.max(1, #outputs)
	local bonuses = info.qualityIlvlBonuses
	if #outputs <= 1 and type(bonuses) == "table" and #bonuses > 1 and schematic.outputItemID then
		maxQ = #bonuses
		local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
		local baseLevel = get and select(4, get(schematic.outputItemID))
		if baseLevel and baseLevel > 0 then
			for q, b in ipairs(bonuses) do keys[q] = "i:" .. schematic.outputItemID .. "::i" .. (baseLevel + b) end
		end
	end
	if info.maxQuality and info.maxQuality > maxQ and #outputs <= 1 then maxQ = info.maxQuality end
	local model = {
		recipeID = recipeID, name = info.name, info = info, qual = qual, fixed = fixed, finishingSlots = finishing,
		outputs = outputs, outputKeys = keys, output = schematic.outputItemID, maxQ = maxQ,
		made = ((schematic.quantityMin or 1) + (schematic.quantityMax or schematic.quantityMin or 1)) / 2,
		allocationGUID = opts.allocationGUID, order = order, orderID = order and order.orderID,
		provided = provided, professionID = opts.professionID, thresholds = {},
		supportsQualities = info.supportsQualities ~= false and maxQ > 1,
	}
	if opts.allocationGUID then
		model.made = 1
		model.recraftFrom = opts.recraftQuality
	end

	local base = lowest(qual)
	local op0 = operation(model, base)
	if not op0 then return nil, "The game gave no crafting result for this recipe." end
	model.op0 = op0
	model.stats0 = St().FromOperation(op0)
	model.skill0 = skillOf(op0)
	model.difficulty = model.stats0.difficulty
	model.craftingDataID = op0.craftingDataID

	-- What the spec adds that the game doesn't report: perk bonuses to Multicraft items,
	-- Resourcefulness savings, Ingenuity refunds and Concentration cost.
	local profID = opts.professionID
	local tree = profID and CH.Spec and CH.Spec.Tree(profID)
	model.tree = tree
	if tree then
		local s = CH.Spec.RecipeStats(profID, tree, CH.Spec.Ranks(tree), recipeID)
		model.stats0.mcExtra, model.stats0.resExtra = s.mcExtra, s.resExtra
		model.stats0.refundExtra, model.stats0.concReduce = s.refundExtra, s.concReduce
	end

	-- Midnight enchanting crafts cast Shatter first (the Craft button does it), so count Shattering
	-- Essence even before it's on you, as CraftSim does.
	if CH.Queue and CH.Queue.NeedsShatter and CH.Queue.NeedsShatter(recipeID) then
		model.raw0 = St().Copy(model.stats0) -- what the game reports, to measure finishing reagents against
		St().Add(model.stats0, CH.Queue.ShatterStats(profID))
		model.shatter = true
	end

	-- Skill each unit adds at each reagent quality, measured like CraftSim.
	model.perUnit, model.moves = {}, {}
	for i, slot in ipairs(qual) do
		model.perUnit[i] = { [1] = 0 }
		for q = 2, #slot.items do
			local p = copyPicks(base); p[i] = { [q] = slot.qty }
			local op = operation(model, p)
			local perUnit = op and (skillOf(op) - model.skill0) / slot.qty or 0
			model.perUnit[i][q] = perUnit
			local extra = (reagentPrice(model, slot.items[q]) or math.huge) - (reagentPrice(model, slot.items[1]) or 0)
			if perUnit > 0 and extra < math.huge then
				table.insert(model.moves, { slot = i, q = q, skill = perUnit, extra = math.max(0, extra) })
			end
		end
	end
	-- Cheapest gold per skill first. A unit only moves up, never back down.
	table.sort(model.moves, function(a, b) return a.extra / a.skill < b.extra / b.skill end)

	-- Finishing reagents: what each adds, measured the same way.
	model.finishing = {}
	for _, slot in ipairs(finishing) do
		local options = {}
		for _, id in ipairs(slot.items) do
			local p = price("chmat", id)
			local own = C_Item and C_Item.GetItemCount and C_Item.GetItemCount(id, true, false, true, true) or 0
			if p or own > 0 then
				local op = operation(model, base, false, { { itemID = id, slot = slot.index } })
				if op then
					local d = St().Diff(St().FromOperation(op), model.raw0 or model.stats0)
					local s = St().FromOperation(op)
					d.supports = s.supports
					d.mcExtra, d.resExtra, d.refundExtra, d.concReduce = 0, 0, 0, 0
					local helps = d.skill > 0 or d.multicraft > 0 or d.resourcefulness > 0 or d.ingenuity > 0
					if helps then
						-- One you already own costs what you'd get selling it instead (after the cut),
						-- never more than buying one; one you'd buy costs its price.
						local cost = p or 0
						if own > 0 then
							local sell = price("chvalue", id)
							cost = sell and math.min(cost > 0 and cost or math.huge, sell * CH.AH_CUT) or cost
						end
						table.insert(options, { itemID = id, slot = slot.index, cost = cost, buy = p, own = own, delta = d })
					end
				end
			end
		end
		if #options > 0 then table.insert(model.finishing, options) end
	end

	-- Skill each quality needs, as fractions of difficulty (CraftSim's GetQualityThresholds).
	local frac = St().THRESHOLDS[model.maxQ]
	for k = 2, model.maxQ do
		local f = frac and frac[k] or (k - 1) / (model.maxQ - 1)
		model.thresholds[k] = model.difficulty * f
	end
	return model
end

-- Every way to fill the finishing slots: none, or one option per slot.
local function combos(model)
	local out = { {} }
	for _, options in ipairs(model.finishing) do
		local nxt = {}
		for _, c in ipairs(out) do
			table.insert(nxt, c)
			for _, o in ipairs(options) do
				local c2 = { unpack(c) }
				table.insert(c2, o)
				table.insert(nxt, c2)
			end
		end
		out = nxt
	end
	return out
end

local function finCost(fin)
	local c = 0
	for _, f in ipairs(fin) do c = c + f.cost end
	return c
end

-- What the vellum costs in a scroll's reagents: Resourcefulness never saves it (it's what the
-- enchant goes on, not a reagent the craft can keep), so it comes out of what Resourcefulness counts.
local function vellumCost(model)
	for _, slot in ipairs(model.fixed or {}) do
		if slot.vellum then return unitsCost(model, slot.items[1], slot.qty) or 0 end
	end
	return 0
end

-- A row's value: item price after cut (or the order's commission) and the average profit.
local function valueRow(model, row, stats, item, costR, fin)
	local key = model.outputKeys and model.outputKeys[row.quality]
	local unit = key and CH.Prices.Get("chvalue", key) or price("chvalue", item)
	local total = costR + finCost(fin)
	-- the reagents Resourcefulness can save: all the required ones but the vellum
	local saveable = math.max(0, costR - vellumCost(model))
	row.cost, row.required, row.item, row.finishing, row.stats = total, costR, item, fin, stats
	local order = model.order
	if order then
		-- Orders pay the commission; extra items from Multicraft go to the customer.
		local s = St().Copy(stats); s.supports.multicraft = nil
		local avg, parts = St().Average(0, 0, total, saveable, s)
		row.value = (order.commission or 0) + (order.rewards or 0)
		row.profit, row.parts = row.value + avg, parts
		row.short = order.minQuality and row.quality < order.minQuality or nil
		return row
	end
	if not unit then row.value, row.profit = nil, nil; return row end
	-- your record: an item that keeps selling under forecast is valued at what it really fetches
	local shade, why
	if CH.Forecast then shade, why = CH.Forecast.Shade(item) end
	if shade then unit = unit * shade; row.shade, row.shadeWhy = shade, why end
	-- expected gold: after the cut, less deposits lost to expiries and gold tied up until it sells
	row.price = unit
	local ev, detail = CH.Expect.Value(item, unit)
	unit, row.ev = ev, detail
	local avg, parts = St().Average(unit, model.made, total, saveable, stats)
	row.unit, row.value, row.profit, row.parts = unit, unit * model.made, avg, parts
	if model.recraftFrom then
		local okey = model.outputKeys and model.outputKeys[model.recraftFrom]
		local old = okey and CH.Prices.Get("chvalue", okey) or price("chvalue", model.outputs[model.recraftFrom] or model.output)
		row.oldValue = old and old * CH.AH_CUT
		row.profit = row.oldValue and (row.profit - row.oldValue) or nil
	end
	return row
end

-- One pass: cheapest reagents for each quality with this finishing set. live asks the game for
-- quality and Concentration; otherwise the model works them out from skill (for simulations).
-- Long work (a scan) can pause here and pick up next frame, so one heavy recipe can't freeze the game.
local function yield() local s = CH.Scan; if s and s.Yield then s.Yield() end end

local frontier, picksOf -- below: the cheapest reagent mixes for each amount of skill

-- Concentration costs less the more skill the reagents give, so the cheapest mix for a quality isn't
-- always the best one to concentrate on (CraftSim optimises it apart). With the game's curve, every
-- mix on the skill/cost frontier that lands on this quality is scored by gold per point, and the
-- best is used. Without a curve the cheapest mix stays (only the game knows the cost).
local CONC_CANDIDATES = 60
local function concMix(model, q, f, s, base0, fin, item, citem)
	if not (model.craftingDataID and model.difficulty and model.perUnit and #model.qual > 0) then return f end
	if not St().ConcentrationCost(model.craftingDataID, model.difficulty, f.skill, s.concReduce) then return f end
	local states = frontier(model)
	if not states then return f end
	local list = {}
	for _, st in ipairs(states) do
		local sk = base0 + st.s
		if A.QualityAt(model, math.floor(sk + 1e-6)) == q then list[#list + 1] = { st = st, skill = sk } end
	end
	local step = math.max(1, math.ceil(#list / CONC_CANDIDATES))
	local function score(picks, c, sk)
		local cc = St().ConcentrationCost(model.craftingDataID, model.difficulty, sk, s.concReduce)
		if not cc or cc <= 0 then return nil end
		local r = valueRow(model, { quality = q + 1, from = q, concentration = cc, picks = picks, skill = sk }, s, citem, c, fin)
		local avg = St().AverageConcentration(cc, s)
		return r.profit and avg > 0 and r.profit / avg or nil
	end
	local best, bestPP = f, score(f.picks, f.cost, f.skill)
	for k = 1, #list, step do
		local picks = picksOf(model, list[k].st)
		local c = cost(model, picks)
		local pp = c and score(picks, c, list[k].skill)
		if pp and (not bestPP or pp > bestPP + 1e-9) then
			best, bestPP = { quality = q, picks = picks, cost = c, skill = list[k].skill }, pp
		end
	end
	return best
end

local function build(model, delta, fin, live)
	yield()
	local stats = St().Add(St().Copy(model.stats0), delta)
	for _, f in ipairs(fin) do
		St().Add(stats, f.delta)
		for k, v in pairs(f.delta.supports or {}) do stats.supports[k] = stats.supports[k] or v end
	end
	local base0 = model.skill0 + (delta and delta.skill or 0)
	for _, f in ipairs(fin) do base0 = base0 + f.delta.skill end

	local found, order, tried = {}, {}, {}
	local function record(picks)
		local key = {}
		for i = 1, #model.qual do
			local row = picks[i] or {}
			for q = 1, #model.qual[i].items do key[#key + 1] = row[q] or 0 end
		end
		key = table.concat(key, ",")
		if tried[key] then return end -- the same mix twice: don't ask the game again
		tried[key] = true
		local q, op
		if live then
			-- Quality from skill against difficulty, as CraftSim does: Midnight's craftingQuality isn't 1, 2.
			op = operation(model, picks, false, fin)
			q = op and A.QualityAt(model, skillOf(op))
		else
			q = A.QualityAt(model, skillAt(model, picks, base0))
		end
		if not q then return end
		local c = cost(model, picks)
		if not c or (found[q] and found[q].cost <= c) then return end
		if not found[q] then table.insert(order, q) end
		found[q] = { quality = q, picks = copyPicks(picks), cost = c, op = op, skill = op and skillOf(op) or skillAt(model, picks, base0) }
	end
	local picks = lowest(model.qual)
	record(picks)
	for _, m in ipairs(model.moves) do
		local row = picks[m.slot]
		for _ = 1, model.qual[m.slot].qty do
			local from
			for q = m.q - 1, 1, -1 do if (row[q] or 0) > 0 then from = q; break end end
			if not from then break end
			row[from] = row[from] - 1
			row[m.q] = (row[m.q] or 0) + 1
			record(picks)
		end
	end
	-- The greedy walk can miss a cheaper mix that clears a quality's threshold; check the exact
	-- cheapest mix for each quality too (the cheaper of the two is kept).
	for _, p in ipairs(A.Cheapest(model, base0)) do record(p) end
	table.sort(order)

	local rows = {}
	for _, q in ipairs(order) do
		local f = found[q]
		local s = stats
		if live and f.op then
			s = St().FromOperation(f.op)
			s.mcExtra, s.resExtra, s.refundExtra, s.concReduce = stats.mcExtra, stats.resExtra, stats.refundExtra, stats.concReduce
		end
		local item = model.outputs[q] or model.output
		table.insert(rows, valueRow(model, { quality = q, picks = f.picks, skill = f.skill }, s, item, f.cost, fin))
		-- With Concentration it lifts the craft to the next quality, on the mix that gives the most
		-- gold per point (often the cheapest one, sometimes one with more skill).
		if model.supportsQualities and q < model.maxQ then
			local cc, cq
			local g = concMix(model, q, f, s, base0, fin, item, model.outputs[q + 1] or item)
			if g ~= f and live then
				-- the game has the last word on the quality these reagents make
				local op = operation(model, g.picks, false, fin)
				if not (op and A.QualityAt(model, skillOf(op)) == q) then g = f else g.skill = skillOf(op) end
			end
			f = g
			if live then
				local opc = operation(model, f.picks, true, fin)
				cc, cq = opc and opc.concentrationCost or 0, q + 1
			else
				cc = St().ConcentrationCost(model.craftingDataID, model.difficulty, f.skill, s.concReduce)
				if not cc then
					-- no curve for this recipe: fall back to what the game charges at these reagents now
					local opc = operation(model, f.picks, true, fin)
					cc = opc and opc.concentrationCost
				end
				cq = q + 1
			end
			if cc and cc > 0 and cq > q then -- Concentration that doesn't lift the quality is wasted
				local citem = model.outputs[cq] or item
				local r = valueRow(model, { quality = cq, from = q, concentration = cc, picks = f.picks, skill = f.skill }, s, citem, f.cost, fin)
				local avgConc, ing = St().AverageConcentration(cc, s)
				r.avgConcentration, r.ingenuity = avgConc, ing
				r.perPoint = r.profit and avgConc > 0 and r.profit / avgConc or nil
				table.insert(rows, r)
			end
		end
	end
	return rows
end

-- Every way to fill one slot's units across its qualities: { skill, cost, row }.
-- A slot can take many different items (an ink's "any pigment" slot), not just ranks of one, and
-- every split of its units across them grows past millions. Two cuts keep it small without losing
-- the cheapest mix: of items that add the same skill a unit, only the cheapest for the whole slot
-- is tried; and if that still leaves too many splits, only mixes of at most two items are tried
-- (with skill linear in units, the cheapest mix for a skill needs no more than two).
local MAX_MIXES = 4000
local function choose(n, k) -- n choose k, capped
	local r = 1
	for i = 1, k do r = r * (n - k + i) / i; if r > 1e9 then return r end end
	return r
end

local function slotMixes(model, i)
	local slot, out = model.qual[i], {}
	local nq = #slot.items
	-- what n units of each quality cost (the ones you hold first, on the held basis)
	local costs = {}
	local function costN(q, n)
		if n == 0 then return 0 end
		costs[q] = costs[q] or {}
		local c = costs[q][n]
		if c == nil then c = unitsCost(model, slot.items[q], n) or false; costs[q][n] = c end
		return c or nil
	end
	-- the cheapest item for each skill a unit
	local bySkill, keep = {}, {}
	for q = 1, nq do
		local per = model.perUnit[i][q] or 0
		local k = string.format("%.6f", per)
		local full = costN(q, slot.qty)
		local cur = bySkill[k]
		if not cur then
			bySkill[k] = q; keep[#keep + 1] = q
		else
			local cc = costN(cur, slot.qty)
			if full and (not cc or full < cc) then
				for j, x in ipairs(keep) do if x == cur then keep[j] = q end end
				bySkill[k] = q
			end
		end
	end
	table.sort(keep)
	local function add(row, sk, c)
		local r = {}
		for k, v in pairs(row) do if v > 0 then r[k] = v end end
		out[#out + 1] = { sk, c, r }
	end
	local nk, qty = #keep, slot.qty
	if choose(qty + nk - 1, nk - 1) <= MAX_MIXES then
		local row = {}
		local function walk(j, left, sk, c)
			local q = keep[j]
			if j == nk then
				local cl = costN(q, left)
				if not cl then return end
				row[q] = left
				add(row, sk + left * (model.perUnit[i][q] or 0), c + cl)
				row[q] = nil
				return
			end
			for n = 0, left do
				local cn = costN(q, n)
				if not cn then break end
				row[q] = n
				walk(j + 1, left - n, sk + n * (model.perUnit[i][q] or 0), c + cn)
			end
			row[q] = nil
		end
		walk(1, qty, 0, 0)
	else
		-- too many to try every split: each item alone, and every pair split every way
		for a = 1, nk do
			local qa = keep[a]
			local ca = costN(qa, qty)
			if ca then add({ [qa] = qty }, qty * (model.perUnit[i][qa] or 0), ca) end
			for b = a + 1, nk do
				local qb = keep[b]
				for n = 1, qty - 1 do
					local c1, c2 = costN(qa, n), costN(qb, qty - n)
					if c1 and c2 then
						add({ [qa] = n, [qb] = qty - n }, n * (model.perUnit[i][qa] or 0) + (qty - n) * (model.perUnit[i][qb] or 0), c1 + c2)
					end
				end
			end
		end
	end
	return out
end

--- The exact cheapest reagent mix for each quality the model can reach, from skill (picks[i][q]).
--- Slot by slot, it keeps every (skill, cost) state that some cheaper state doesn't beat on skill:
--- skill is kept exact (fractions too, since the game adds every slot's share before rounding the
--- total), and a state is dropped only when another reaches at least as much skill for no more gold.
-- The frontier doesn't depend on skill, only on the reagents' prices, so it's worked out once per
-- recipe model and price set and reused by every finishing combination, simulation and rescan.
local function priceKey(model)
	local parts = {}
	for _, slot in ipairs(model.qual) do
		for _, id in ipairs(slot.items) do
			local h = CH.Prices.CostBasis and CH.Prices.CostBasis() == "held" and heldInfo(model, id)
			parts[#parts + 1] = tostring(reagentPrice(model, id) or "-") .. (h and ("/" .. h.n .. "@" .. tostring(h.each)) or "")
		end
	end
	return table.concat(parts, ",")
end

function frontier(model)
	local key = priceKey(model)
	local c = model.frontierCache
	if c and c.key == key and c.perUnit == model.perUnit then return c.states end
	local states = { { s = 0, c = 0 } }
	for i = 1, #model.qual do
		local mixes = slotMixes(model, i)
		if #mixes == 0 then states = nil; break end
		-- a mix that another beats on both skill and cost can't be in a cheapest answer: drop it
		-- before pairing with the slots so far (the pairing is what grows)
		table.sort(mixes, function(x, y) if math.abs(x[1] - y[1]) > 1e-9 then return x[1] > y[1] end return x[2] < y[2] end)
		local pruned, low = {}, math.huge
		for _, m in ipairs(mixes) do if m[2] < low - 1e-9 then pruned[#pruned + 1] = m; low = m[2] end end
		mixes = pruned
		local nxt = {}
		for _, st in ipairs(states) do
			for _, m in ipairs(mixes) do
				nxt[#nxt + 1] = { s = st.s + m[1], c = st.c + m[2], prev = st, row = m[3] }
			end
		end
		-- the frontier: most skill first, cheaper first on ties; keep each state cheaper than all above it
		table.sort(nxt, function(x, y) if math.abs(x.s - y.s) > 1e-9 then return x.s > y.s end return x.c < y.c end)
		states = {}
		local cheapest = math.huge
		for _, st in ipairs(nxt) do
			if st.c < cheapest - 1e-9 then states[#states + 1] = st; cheapest = st.c end
		end
	end
	model.frontierCache = { key = key, perUnit = model.perUnit, states = states }
	return states
end
A.Frontier = frontier

-- The reagent picks a frontier state stands for (picks[i][q]).
function picksOf(model, state)
	local picks, st = {}, state
	for i = #model.qual, 1, -1 do
		local row = {}
		for q, n in pairs(st.row) do row[q] = n end
		picks[i], st = row, st.prev
	end
	return picks
end

function A.Cheapest(model, base)
	if not model.perUnit or #model.qual == 0 then return {} end
	local states = frontier(model)
	if not states then return {} end
	local out = {}
	for k = 1, model.maxQ do
		local need = k == 1 and -math.huge or (model.thresholds[k] or math.huge)
		local pick
		for _, st in ipairs(states) do
			if math.floor((base or 0) + st.s + 1e-6) >= need and (not pick or st.c < pick.c) then pick = st end
		end
		if pick then out[#out + 1] = picksOf(model, pick) end
	end
	return out
end

local function pickBest(rows)
	local best, bestConc, anyConc
	for _, r in ipairs(rows) do
		if r.profit and not r.short then
			if not r.concentration and (not best or r.profit > best.profit) then best = r end
			if r.concentration and r.perPoint and r.perPoint > 0 and (not bestConc or r.perPoint > bestConc.perPoint) then bestConc = r end
			if r.concentration and (not anyConc or r.profit > anyConc.profit) then anyConc = r end
		end
	end
	-- only Concentration reaches the quality asked (an order), and it loses gold: still reachable,
	-- shown at its loss rather than as "can't reach"
	if not best and not bestConc then bestConc = anyConc end
	return best, bestConc
end
A.PickBest = pickBest

--- Rows for every reachable quality with and without Concentration. opts.sim is a stat change
--- (skill, ratings, perk extras) to simulate; without it the game is asked for quality and costs.
function A.Evaluate(model, opts)
	opts = opts or {}
	local delta = opts.sim
	local live = not delta and not opts.modelOnly
	-- Choose finishing reagents on the model (cheap), then build the real rows with the winners.
	local none = {}
	local finPlain, finConc = none, none -- one table, so no finishing choice builds once
	-- opts.finishing = { plain, conc } skips trying every finishing combination (Gear.Best reuses
	-- the live craft's picks: one search per gear set instead of one per set and combination)
	local all = opts.finishing and { {} } or combos(model)
	if opts.finishing then finPlain, finConc = opts.finishing.plain or none, opts.finishing.conc or none end
	if #all > 1 then
		local bp, bc
		for _, fin in ipairs(all) do
			local b, c = pickBest(build(model, delta, fin, false))
			if b and (not bp or b.profit > bp) then bp, finPlain = b.profit, fin end
			if c and (not bc or c.perPoint > bc) then bc, finConc = c.perPoint, fin end
		end
	end
	local rows = build(model, delta, finPlain, live)
	if finConc ~= finPlain then
		local keep = {}
		for _, r in ipairs(rows) do if not r.concentration then table.insert(keep, r) end end
		for _, r in ipairs(build(model, delta, finConc, live)) do if r.concentration then table.insert(keep, r) end end
		table.sort(keep, function(a, b)
			if (a.from or a.quality) ~= (b.from or b.quality) then return (a.from or a.quality) < (b.from or b.quality) end
			return not a.concentration and b.concentration
		end)
		rows = keep
	end
	local best, bestConc = pickBest(rows)
	if best then best.recommended = true end
	if bestConc then bestConc.bestConcentration = true end
	local result = { recipeID = model.recipeID, name = model.name, rows = rows, qual = model.qual, fixed = model.fixed,
		made = model.made, best = best, bestConc = bestConc, model = model, sim = delta, order = model.order,
		finishingPicks = { plain = finPlain, conc = finConc } }
	-- the decision numbers: break-even sale price, and what Concentration adds over the plain craft
	local Dc = CH.Decide
	if Dc then
		for _, r in ipairs(rows) do
			r.breakEven = Dc.BreakEven(result, r)
			if r.concentration then r.gain = Dc.ConcGain(r, best and best.profit) end
		end
	end
	return result
end

--- What each finishing reagent is worth on this recipe: { itemID, own, buy, cost, gain, effect,
--- picked, verdict } best first. gain is the plain craft's profit with it less the best without any,
--- with the reagent's own cost already taken off (what you'd sell an owned one for, else its price).
--- verdict: "use" (you have it and it pays), "buy" (it pays even bought), "skip".
function A.FinishingAdvice(result)
	local model = result and result.model
	if not model or not model.finishing or #model.finishing == 0 then return {} end
	-- a full search per finishing reagent: worked out once per result (the card asks on every redraw)
	if result.finishingAdvice then return result.finishingAdvice end
	local out = A.FinishingAdviceNow(result)
	result.finishingAdvice = out
	return out
end

function A.FinishingAdviceNow(result)
	local model = result.model
	local base = pickBest(build(model, result.sim, {}, false))
	local baseProfit = base and base.profit or 0
	local picked = {}
	for _, f in ipairs(result.best and result.best.finishing or {}) do picked[f.itemID] = true end
	local out = {}
	for _, options in ipairs(model.finishing) do
		for _, o in ipairs(options) do
			local b = pickBest(build(model, result.sim, { o }, false))
			local gain = b and b.profit and (b.profit - baseProfit) or nil
			local d, parts = o.delta, {}
			if d.skill > 0 then table.insert(parts, string.format("+%d skill", d.skill)) end
			for _, k in ipairs({ "multicraft", "resourcefulness", "ingenuity" }) do
				if (d[k] or 0) > 0 then
					local div = St().DIVISOR and St().DIVISOR[k]
					table.insert(parts, div and string.format("+%.1f%% %s", d[k] / div * 100, k:gsub("^%l", string.upper))
						or ("+" .. k:gsub("^%l", string.upper)))
				end
			end
			-- bought, it would cost its price; owned, the gain already uses the cheaper sell value
			local boughtGain = gain and o.buy and gain - (o.buy - o.cost) or nil
			local verdict = gain and gain > 0 and o.own > 0 and "use" or boughtGain and boughtGain > 0 and "buy" or "skip"
			table.insert(out, { itemID = o.itemID, slot = o.slot, own = o.own, buy = o.buy, cost = o.cost, gain = gain,
				boughtGain = boughtGain, effect = table.concat(parts, ", "), picked = picked[o.itemID] or false, verdict = verdict })
		end
	end
	table.sort(out, function(a, b) return (a.gain or -math.huge) > (b.gain or -math.huge) end)
	return out
end

--- Measure and evaluate in one go.
function A.Analyze(recipeID, opts)
	local model, reason = A.Measure(recipeID, opts)
	if not model then return nil, reason end
	return A.Evaluate(model, opts)
end

local function itemName(id)
	return C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id) or ("item " .. id)
end
A.ItemName = itemName

--- "3x Q2 Bismuth, 2x Q1 Mote" for a row's reagent picks; names from the item cache when known.
function A.PicksText(result, picks, fin)
	local parts = {}
	for i, slot in ipairs(result.qual) do
		for q = #slot.items, 1, -1 do
			local n = picks[i][q] or 0
			if n > 0 then
				table.insert(parts, string.format("%dx Q%d %s", n, q, itemName(slot.items[q])))
			end
		end
	end
	for _, f in ipairs(fin or {}) do table.insert(parts, "+ " .. itemName(f.itemID)) end
	return table.concat(parts, ", ")
end

--- Add to a reagent line what you hold of it: own (units from your stock), ownEach (what you paid,
--- or today's price), buyN (units to buy) and sell (what one would bring on the AH after the cut).
function A.HeldLine(l, model)
	if not (model and CH.Prices.CostBasis and CH.Prices.CostBasis() == "held") then return l end
	local h = heldInfo(model, l.id)
	l.own = math.min(l.n, h.n)
	l.buyN = l.n - l.own
	l.ownEach = h.each or l.buy
	l.sell = h.each
	l.paidEach = h.paid
	l.stock = h.n
	return l
end

--- A reagent line's prices for its hover, as { label, value } rows: the opportunity cost of the
--- units you hold, then what you paid, the current lowest listing and what you'd list it at, and
--- what the rest cost to buy. Empty off the held basis or when you hold none.
function A.HeldText(l)
	local out = {}
	if not (l and l.own and l.own > 0) then return out end
	local M, T = CH.FormatMoney, CH.Theme
	local function m(v) return v and M(v) or T.Color("muted", "-") end
	local B = CH.Window.Book
	local list = CH.Prices.Get("chvalue", "i:" .. l.id)
	local lowest = CH.Prices.Raw and CH.Prices.Raw("dbminbuyout", l.id) or l.buy
	out[#out + 1] = B.Sub(string.format("Opportunity cost (%d yours)", l.own), m(l.ownEach))
	out[#out + 1] = B.Sub("   Stock", tostring(l.stock or l.own))
	out[#out + 1] = B.Sub("   Paid price", m(l.paidEach))
	out[#out + 1] = B.Sub("   Current price", m(lowest))
	out[#out + 1] = B.Sub("   Sell price", m(list))
	-- what selling them would really leave you: the cut, plus deposits and waiting for a slow seller
	if list and l.ownEach and l.sell then
		local _, how = CH.Prices.SellValue(l.id)
		local days = how and how.days
		out[#out + 1] = B.Sub(days and days >= 0.5 and string.format("   Cut, deposits, ~%.0f days to sell", days) or "   Cut, deposits, wait",
			"-" .. M(math.max(0, list - l.ownEach)))
	end
	if (l.buyN or 0) > 0 then out[#out + 1] = B.Sub(string.format("To buy (%d)", l.buyN), m(l.buy)) end
	return out
end

--- Craft or sell: what crafting brings against selling the reagents you hold instead.
--- { sell (yours at what they'd sell for after the cut), craft (the craft's proceeds less what you'd
--- buy), gain (craft less sell: the row's profit) } or nil when you hold none of its reagents.
function A.CraftOrSell(result, r)
	if not (result and r and r.profit and r.picks) then return nil end
	local own = 0
	for _, l in ipairs(A.CostLines(result, r.picks, r.finishing)) do
		if l.own and l.own > 0 and l.ownEach then own = own + l.own * l.ownEach end
	end
	if own <= 0 then return nil end
	return { sell = own, craft = r.profit + own, gain = r.profit }
end

--- The craft-or-sell block for a profit hover, in Book lines (empty when you hold none of the reagents).
function A.CraftOrSellLines(result, r)
	local cs = A.CraftOrSell(result, r)
	if not cs then return {} end
	local B = CH.Window.Book
	return { B.Head("Craft or sell?"),
		B.Line("Craft and sell the item", cs.craft),
		B.Line("Sell your reagents instead", cs.sell),
		cs.gain >= 0 and B.Total("Crafting earns more by", cs.gain) or B.Total("Selling the reagents earns more by", cs.gain) }
end

--- Each reagent in a row: id, name, rank, units, price per unit (chmat: an estimate), line total.
--- Fixed reagents have no rank.
function A.CostLines(result, picks, fin)
	local out = {}
	for i, slot in ipairs(result.qual) do
		for q = #slot.items, 1, -1 do
			local n = picks[i][q] or 0
			if n > 0 then
				local id = slot.items[q]
				local unit, via = reagentPrice(result.model, id), CH.Scan and CH.Scan.ReagentPrice and select(2, CH.Scan.ReagentPrice(id, result.recipeID))
				local total = unitsCost(result.model, id, n)
				local listed = listedEach(result.model, id, n, via)
				table.insert(out, A.HeldLine({ id = id, name = itemName(id), rank = q, tiers = #slot.items, n = n, unit = total and total / n or unit,
					buy = listed or unit, listed = listed and true or nil, total = total, crafted = via }, result.model))
			end
		end
	end
	for _, slot in ipairs(result.fixed) do
		local id = slot.items[1]
		local unit, via = reagentPrice(result.model, id), CH.Scan and CH.Scan.ReagentPrice and select(2, CH.Scan.ReagentPrice(id, result.recipeID))
		local total = unitsCost(result.model, id, slot.qty)
		local listed = listedEach(result.model, id, slot.qty, via)
		table.insert(out, A.HeldLine({ id = id, name = itemName(id), n = slot.qty, unit = total and total / slot.qty or unit, buy = listed or unit,
			listed = listed and true or nil, total = total, crafted = via }, result.model))
	end
	for _, f in ipairs(fin or {}) do
		table.insert(out, { id = f.itemID, name = itemName(f.itemID), n = 1, unit = f.cost, total = f.cost, finishing = true })
	end
	return out
end

-- TSM's own sources behind chvalue, labelled by where they come from.
A.SOURCES = {
	{ "dbminbuyout", "Lowest listing, realm" },
	{ "dbmarket", "MV  Market Value, realm" },
	{ "dbregionmarketavg", "RV  Region Value" },
	{ "dbregionsaleavg", "Sale price, region" },
	{ "dbregionsalerate", "Sale rate, region", "rate" },
	{ "dbregionsoldperday", "Sold per day, region", "count" },
}

--- The prices behind a crafted item's value. "money" is copper, "rate" a sale rate, "count" units a day.
function A.PriceSources(itemID)
	local out = {}
	if not TSM_API or not itemID then return out end
	for _, s in ipairs(A.SOURCES) do
		local ok, v = pcall(TSM_API.GetCustomPriceValue, s[1], "i:" .. itemID)
		table.insert(out, { label = s[2], value = ok and v or nil, kind = s[3] or "money" })
	end
	return out
end

--- Units of an item the region sells a day, from TSM (nil if unknown).
function A.SoldPerDay(itemID)
	if not TSM_API or not itemID then return nil end
	local ok, v = pcall(TSM_API.GetCustomPriceValue, "dbregionsoldperday", "i:" .. itemID)
	return ok and v or nil
end

local function have(id)
	if not C_Item or not C_Item.GetItemCount then return 0 end
	-- bags, bank, reagent bank and warband bank
	return C_Item.GetItemCount(id, true, false, true, true) or 0
end

--- How many times a row can be crafted from the reagents you own (and, with Concentration, the
--- points you have now). Returns the count and a line per reagent: name, rank, have, need.
function A.MaxCraftable(result, r, concNow)
	local max, lines = math.huge, {}
	local function use(id, rank, need, tiers)
		local h = have(id)
		max = math.min(max, math.floor(h / need))
		table.insert(lines, { name = itemName(id), rank = rank, tiers = tiers, have = h, need = need })
	end
	for i, slot in ipairs(result.qual) do
		for q = #slot.items, 1, -1 do
			local n = r.picks[i][q] or 0
			if n > 0 then use(slot.items[q], q, n, #slot.items) end
		end
	end
	for _, slot in ipairs(result.fixed) do use(slot.items[1], nil, slot.qty) end
	for _, f in ipairs(r.finishing or {}) do use(f.itemID, nil, 1) end
	if r.concentration and concNow then
		max = math.min(max, math.floor(concNow / r.concentration))
	end
	if max == math.huge then max = 0 end
	return max, lines
end

--- The Concentration craft with the reagents you hold, as the game fills a slot by default (lowest
--- rank first): what the profession window charges when you tick Concentrate without changing a
--- reagent. The advisor's own Concentration mix can need a rank you don't hold; this one you can
--- make now when the points cover it. A row like Evaluate's (fromBags = true), or nil.
function A.HeldConcRow(result)
	local model = result and result.model
	if not model or result.order or result.sim or not model.supportsQualities or #model.qual == 0 then return nil end
	local picks = {}
	for i, slot in ipairs(model.qual) do
		local left, row = slot.qty, {}
		for q, id in ipairs(slot.items) do
			local n = math.min(left, have(id))
			if n > 0 then row[q] = n; left = left - n end
		end
		if left > 0 then return nil end
		picks[i] = row
	end
	for _, slot in ipairs(model.fixed) do if have(slot.items[1]) < slot.qty then return nil end end
	local op = operation(model, picks, false, {})
	if not op then return nil end
	local q = A.QualityAt(model, skillOf(op))
	if q >= model.maxQ then return nil end
	local opc = operation(model, picks, true, {})
	local cc = opc and opc.concentrationCost
	if not cc or cc <= 0 then return nil end
	local c = cost(model, picks)
	if not c then return nil end
	local s = St().FromOperation(opc)
	local s0 = model.stats0 or {}
	s.mcExtra, s.resExtra, s.refundExtra, s.concReduce = s0.mcExtra, s0.resExtra, s0.refundExtra, s0.concReduce
	local cq = q + 1
	local item = model.outputs[cq] or model.output
	local r = valueRow(model, { quality = cq, from = q, concentration = cc, picks = picks, skill = skillOf(op) }, s, item, c, {})
	local avgConc, ing = St().AverageConcentration(cc, s)
	r.avgConcentration, r.ingenuity = avgConc, ing
	r.perPoint = r.profit and avgConc and avgConc > 0 and r.profit / avgConc or nil
	r.fromBags = true
	local Dc = CH.Decide
	if Dc then
		r.breakEven = Dc.BreakEven(result, r)
		r.gain = Dc.ConcGain(r, result.best and result.best.profit)
	end
	return r
end
