-- Clearinghouse: learns each character's professions, Concentration and best crafts
-- whenever a profession window is open.
local _, CH = ...

local MAX_CRAFTS = 8
local pending = false

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

function CH.BestCrafts(limit)
	local out = {}
	for _, recipeID in ipairs(C_TradeSkillUI.GetAllRecipeIDs() or {}) do
		local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
		if info and info.learned and not info.isRecraft and not info.isSalvageRecipe and not info.isGatheringRecipe then
			local itemID, quality = outputItem(recipeID, info)
			local profit = itemID and CH.Prices.CraftProfit("i:" .. itemID)
			if profit and profit > 0 then
				table.insert(out, { recipeID = recipeID, name = info.name, itemID = itemID, quality = quality, profit = profit })
			end
		end
	end
	table.sort(out, function(a, b) return a.profit > b.profit end)
	for i = #out, (limit or MAX_CRAFTS) + 1, -1 do out[i] = nil end
	return out
end

function CH.RecordProfession()
	pending = false
	local info = currentProfession()
	if not info then return end
	local me = CH.Me()
	local p = me.professions[info.professionID] or {}
	me.professions[info.professionID] = p
	p.name = info.professionName or info.parentProfessionName
	p.skill, p.maxSkill = info.skillLevel, info.maxSkillLevel
	p.conc, p.concMax = concentration(info.professionID)
	p.concAt = time()
	if CH.Spec then CH.Spec.Record(info.professionID) end
	if CH.Cooldowns then CH.Cooldowns.Record(p) end
	if CH.Prices.Available() then
		p.crafts = CH.BestCrafts()
		p.craftsAt = time()
	end
	if CH.UI.IsShown() then CH.UI.Refresh() end
end

local function schedule()
	if pending then return end
	pending = true
	C_Timer.After(1, CH.RecordProfession) -- the recipe list arrives in bursts; read it once it settles
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
