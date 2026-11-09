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

local function reagentType(name, fallback)
	return Enum and Enum.CraftingReagentType and Enum.CraftingReagentType[name] or fallback
end

--- Required reagent slots, split into those with qualities (we choose) and fixed ones (we just pay),
--- plus finishing slots. Slots the customer fills on a crafting order are left out.
function A.Slots(schematic, provided)
	local qual, fixed, finishing = {}, {}, {}
	local basic, fin = reagentType("Basic", 1), reagentType("Finishing", 2)
	for _, s in ipairs(schematic.reagentSlotSchematics or {}) do
		local items = {}
		for _, r in ipairs(s.reagents or {}) do
			local id = r.itemID or (r.reagent and r.reagent.itemID)
			if id then table.insert(items, id) end
		end
		if not (provided and provided[s.dataSlotIndex]) and #items > 0 then
			local slot = { index = s.dataSlotIndex, qty = s.quantityRequired or 1, items = items }
			if s.reagentType == basic and s.required ~= false then
				table.insert(#items > 1 and qual or fixed, slot)
			elseif s.reagentType == fin then
				table.insert(finishing, slot)
			end
		end
	end
	return qual, fixed, finishing
end

-- picks[i][q] = units of quality q in quality slot i
local function reagentInfos(model, picks, fin)
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
	for _, r in ipairs(model.provided or {}) do table.insert(t, r) end
	return t
end

local function operation(model, picks, concentrate, fin)
	local ui = api()
	local infos = reagentInfos(model, picks, fin)
	local ok, info
	if model.orderID and ui.GetCraftingOperationInfoForOrder then
		ok, info = pcall(ui.GetCraftingOperationInfoForOrder, model.recipeID, infos, model.orderID, concentrate or false)
		if not (ok and info) then -- the game may not answer for an order you haven't claimed
			ok, info = pcall(ui.GetCraftingOperationInfo, model.recipeID, infos, nil, concentrate or false)
		end
	else
		ok, info = pcall(ui.GetCraftingOperationInfo, model.recipeID, infos, model.allocationGUID, concentrate or false)
	end
	return ok and info or nil
end
A.Operation = operation

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

-- Reagents this recipe needs that Resourcefulness can save (all required ones we pay for).
local function cost(model, picks)
	local total = 0
	for i, slot in ipairs(model.qual) do
		for q, id in ipairs(slot.items) do
			local n = picks[i][q] or 0
			if n > 0 then
				local p = price("chmat", id)
				if not p then return nil end
				total = total + n * p
			end
		end
	end
	for _, slot in ipairs(model.fixed) do
		local p = price("chmat", slot.items[1])
		if not p then return nil end
		total = total + slot.qty * p
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
	local qual, fixed, finishing = A.Slots(schematic, order and order.providedSlots)
	local outputs = info.qualityItemIDs or {}
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
		provided = order and order.provided, professionID = opts.professionID, thresholds = {},
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

	-- Skill each unit adds at each reagent quality, measured like CraftSim.
	model.perUnit, model.moves = {}, {}
	for i, slot in ipairs(qual) do
		model.perUnit[i] = { [1] = 0 }
		for q = 2, #slot.items do
			local p = copyPicks(base); p[i] = { [q] = slot.qty }
			local op = operation(model, p)
			local perUnit = op and (skillOf(op) - model.skill0) / slot.qty or 0
			model.perUnit[i][q] = perUnit
			local extra = (price("chmat", slot.items[q]) or math.huge) - (price("chmat", slot.items[1]) or 0)
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
					local d = St().Diff(St().FromOperation(op), model.stats0)
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

-- A row's value: item price after cut (or the order's commission) and the average profit.
local function valueRow(model, row, stats, item, costR, fin)
	local key = model.outputKeys and model.outputKeys[row.quality]
	local unit = key and CH.Prices.Get("chvalue", key) or price("chvalue", item)
	local total = costR + finCost(fin)
	row.cost, row.required, row.item, row.finishing, row.stats = total, costR, item, fin, stats
	local order = model.order
	if order then
		-- Orders pay the commission; extra items from Multicraft go to the customer.
		local s = St().Copy(stats); s.supports.multicraft = nil
		local avg, parts = St().Average(0, 0, total, costR, s)
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
	local avg, parts = St().Average(unit, model.made, total, costR, stats)
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
		-- The same reagents with Concentration: it lifts the craft to the next quality.
		if model.supportsQualities and q < model.maxQ then
			local cc, cq
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
local function slotMixes(model, i)
	local slot, out = model.qual[i], {}
	local prices = {}
	for q, id in ipairs(slot.items) do prices[q] = price("chmat", id) end
	local nq = #slot.items
	local function walk(q, left, row, sk, c)
		if q == nq then
			if left > 0 and not prices[q] then return end
			local r = {}
			for k, v in pairs(row) do r[k] = v end
			if left > 0 then r[q] = left end
			out[#out + 1] = { sk + left * (model.perUnit[i][q] or 0), c + left * (prices[q] or 0), r }
			return
		end
		for n = 0, left do
			if n > 0 and not prices[q] then break end
			row[q] = n > 0 and n or nil
			walk(q + 1, left - n, row, sk + n * (model.perUnit[i][q] or 0), c + n * (prices[q] or 0))
		end
		row[q] = nil
	end
	walk(1, slot.qty, {}, 0, 0)
	return out
end

--- The exact cheapest reagent mix for each quality the model can reach, from skill (picks[i][q]).
--- Slot by slot, it keeps every (skill, cost) state that some cheaper state doesn't beat on skill:
--- skill is kept exact (fractions too, since the game adds every slot's share before rounding the
--- total), and a state is dropped only when another reaches at least as much skill for no more gold.
function A.Cheapest(model, base)
	if not model.perUnit or #model.qual == 0 then return {} end
	local states = { { s = 0, c = 0 } }
	for i = 1, #model.qual do
		local mixes = slotMixes(model, i)
		if #mixes == 0 then return {} end
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
	local out = {}
	for k = 1, model.maxQ do
		local need = k == 1 and -math.huge or (model.thresholds[k] or math.huge)
		local pick
		for _, st in ipairs(states) do
			if math.floor((base or 0) + st.s + 1e-6) >= need and (not pick or st.c < pick.c) then pick = st end
		end
		if pick then
			local picks, st = {}, pick
			for i = #model.qual, 1, -1 do
				local row = {}
				for q, n in pairs(st.row) do row[q] = n end
				picks[i], st = row, st.prev
			end
			out[#out + 1] = picks
		end
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
	local all = combos(model)
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
	return { recipeID = model.recipeID, name = model.name, rows = rows, qual = model.qual, fixed = model.fixed,
		made = model.made, best = best, bestConc = bestConc, model = model, sim = delta, order = model.order }
end

--- What each finishing reagent is worth on this recipe: { itemID, own, buy, cost, gain, effect,
--- picked, verdict } best first. gain is the plain craft's profit with it less the best without any,
--- with the reagent's own cost already taken off (what you'd sell an owned one for, else its price).
--- verdict: "use" (you have it and it pays), "buy" (it pays even bought), "skip".
function A.FinishingAdvice(result)
	local model = result and result.model
	if not model or not model.finishing or #model.finishing == 0 then return {} end
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

--- Each reagent in a row: name, rank, units, price per unit, line total. Fixed reagents have no rank.
function A.CostLines(result, picks, fin)
	local out = {}
	for i, slot in ipairs(result.qual) do
		for q = #slot.items, 1, -1 do
			local n = picks[i][q] or 0
			if n > 0 then
				local unit = price("chmat", slot.items[q])
				table.insert(out, { name = itemName(slot.items[q]), rank = q, tiers = #slot.items, n = n, unit = unit, total = unit and unit * n })
			end
		end
	end
	for _, slot in ipairs(result.fixed) do
		local unit = price("chmat", slot.items[1])
		table.insert(out, { name = itemName(slot.items[1]), n = slot.qty, unit = unit, total = unit and unit * slot.qty })
	end
	for _, f in ipairs(fin or {}) do
		table.insert(out, { name = itemName(f.itemID), n = 1, unit = f.cost, total = f.cost, finishing = true })
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
