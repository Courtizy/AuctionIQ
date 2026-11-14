-- Professions: learns each character's professions, Concentration and best crafts
-- whenever a profession window is open.
local _, CH = ...

local MAX_CRAFTS = 8
local pending = false
local Prof

local function currentProfession()
	local ui = C_TradeSkillUI
	if not ui or not ui.IsTradeSkillReady or not ui.IsTradeSkillReady() then return nil end
	if (ui.IsTradeSkillLinked and ui.IsTradeSkillLinked()) or (ui.IsTradeSkillGuild and ui.IsTradeSkillGuild())
		or (ui.IsNPCCrafting and ui.IsNPCCrafting()) then
		return nil -- someone else's profession: nothing to record for this character
	end
	local info = ui.GetChildProfessionInfo and ui.GetChildProfessionInfo()
	if not info or not info.professionID or info.professionID == 0 then return nil end
	return info
end

local function concentration(professionID)
	local id = C_TradeSkillUI.GetConcentrationCurrencyID and C_TradeSkillUI.GetConcentrationCurrencyID(professionID)
	if not id or id == 0 then return nil end
	local c = C_CurrencyInfo.GetCurrencyInfo(id)
	if not c then return nil end
	if c.iconFileID and CH.db then CH.db.concIcon = c.iconFileID end -- for the Concentration icon everywhere
	return c.quantity, c.maxQuantity
end

-- The item a recipe makes: its top quality when it has qualities, since that is what
-- Concentration and skill are for.
local function outputItem(recipeID, info)
	if info.qualityItemIDs and #info.qualityItemIDs > 0 then
		return info.qualityItemIDs[#info.qualityItemIDs], #info.qualityItemIDs
	end
	local s = C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
	return s and s.outputItemID, nil
end

--- Skill line of the open profession (the expansion one, e.g. Midnight Alchemy), or nil.
function CH.OpenProfessionID()
	local info = currentProfession()
	return info and info.professionID
end

-- One recipe's part of the walk: its cooldown into cds, and (with prices) its profit into crafts.
local function walkRecipe(recipeID, crafts, cds, now, priced)
	local ui = C_TradeSkillUI
	local info = ui.GetRecipeInfo(recipeID)
	if not (info and info.learned) then return end
	if cds and ui.GetRecipeCooldown then
		local cd, _, charges, maxCharges = ui.GetRecipeCooldown(recipeID)
		if (cd and cd > 0) or (maxCharges and maxCharges > 0) then
			cds[recipeID] = { name = info.name, readyAt = now + (cd or 0), charges = charges, max = maxCharges, at = now }
		end
	end
	if priced and not info.isRecraft and not info.isSalvageRecipe and not info.isGatheringRecipe then
		local itemID, quality = outputItem(recipeID, info)
		local profit = itemID and CH.Prices.CraftProfit("i:" .. itemID)
		if profit and profit > 0 then
			table.insert(crafts, { recipeID = recipeID, name = info.name, itemID = itemID, quality = quality, profit = profit })
		end
	end
end

local function topCrafts(out, limit)
	table.sort(out, function(a, b) return a.profit > b.profit end)
	for i = #out, (limit or MAX_CRAFTS) + 1, -1 do out[i] = nil end
	return out
end

--- The open profession's most profitable learned crafts at TSM's prices, best first.
function CH.BestCrafts(limit)
	local out = {}
	for _, recipeID in ipairs(C_TradeSkillUI.GetAllRecipeIDs() or {}) do walkRecipe(recipeID, out, nil, 0, true) end
	return topCrafts(out, limit)
end

-- Best crafts and cooldowns come from one walk over every recipe the profession has, all
-- expansions (Enchanting has well over a thousand): a few milliseconds a frame, so opening the
-- window never stalls. The game sends the recipe list again after every craft, so a profession
-- walked in the last few minutes isn't walked again; learning a recipe walks it afresh.
Prof = {}
CH.Professions = Prof
Prof.WALK_MS, Prof.FRESH = 4, 300
local walk -- { id, ids, i, crafts, cds, now, priced, p }

local function finishWalk(w)
	walk = nil
	w.p.cooldowns = w.cds
	if w.priced then w.p.crafts, w.p.craftsAt = topCrafts(w.crafts), w.now end
	w.p.walkAt = w.now
	if CH.UI.IsShown() then CH.UI.Refresh() end
end

local function walkStep()
	local w = walk
	if not w then return end
	local clock = debugprofilestop
	local t0 = clock and clock()
	while w.i < #w.ids do
		w.i = w.i + 1
		walkRecipe(w.ids[w.i], w.crafts, w.cds, w.now, w.priced)
		if clock and w.i % 8 == 0 and w.i < #w.ids and clock() - t0 >= Prof.WALK_MS then
			if CH.MeasureAdd then CH.MeasureAdd("profession: recipe walk", clock() - t0) end
			return C_Timer.After(0, walkStep)
		end
	end
	if clock and CH.MeasureAdd then CH.MeasureAdd("profession: recipe walk", clock() - t0) end
	finishWalk(w)
end

--- Walk the open profession's recipes for its best crafts and cooldowns, unless done lately.
function Prof.Walk(professionID, p, force)
	local now = time()
	if not force and p.walkAt and now - p.walkAt < Prof.FRESH then
		-- walked lately: only the recipes known to have a cooldown need reading again
		for id in pairs(p.cooldowns or {}) do
			local cds = {}
			walkRecipe(id, nil, cds, now, false)
			p.cooldowns[id] = cds[id]
		end
		return false
	end
	if walk and walk.id == professionID then return false end
	walk = { id = professionID, ids = C_TradeSkillUI.GetAllRecipeIDs() or {}, i = 0, crafts = {}, cds = {}, now = now,
		priced = CH.Prices.Available(), p = p }
	if C_Timer and debugprofilestop then C_Timer.After(0, walkStep) else walkStep() end
	return true
end
CH.On("NEW_RECIPE_LEARNED", function() for _, p in pairs(CH.Me and CH.db and CH.Me().professions or {}) do p.walkAt = nil end end)
CH.On("TRADE_SKILL_CLOSE", function() walk = nil end)

function CH.RecordProfession()
	pending = false
	local info = currentProfession()
	if not info then return end
	local me = CH.Me()
	local p = me.professions[info.professionID] or {}
	me.professions[info.professionID] = p
	p.name = info.professionName or info.parentProfessionName
	p.parent = info.parentProfessionName
	p.skill, p.maxSkill = info.skillLevel, info.maxSkillLevel
	p.conc, p.concMax = concentration(info.professionID)
	p.concAt = time()
	if CH.Spec then CH.Spec.Record(info.professionID) end
	if not Prof.Walk(info.professionID, p) and CH.UI.IsShown() then CH.UI.Refresh() end
end

local function schedule()
	if pending then return end
	pending = true
	C_Timer.After(1, function() CH.Measure("profession: record", CH.RecordProfession) end) -- the recipe list arrives in bursts; read it once it settles
end

CH.On("TRADE_SKILL_SHOW", schedule)
CH.On("TRADE_SKILL_LIST_UPDATE", schedule)
CH.On("TRADE_SKILL_DATA_SOURCE_CHANGED", schedule)

--- Concentration now, counting the refill since it was last seen.
function CH.ConcentrationNow(p, now)
	if not p.conc or not p.concMax then return nil end
	local hours = ((now or time()) - (p.concAt or 0)) / 3600
	return math.min(p.concMax, math.floor(p.conc + hours * CH.CONC_PER_HOUR)), p.concMax
end
