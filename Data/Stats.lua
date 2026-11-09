-- Crafting stats and average profit, the way CraftSim works them out (its ProfitCalculation and
-- ProfessionStats, MIT licence):
--   * Multicraft: chance x the average extra items a proc gives, (1 + constant x base yield x (1 + perk bonus)) / 2
--   * Resourcefulness: chance x 30% of the required reagents back on average, plus perk bonus
--   * Ingenuity: chance x (50% + perk bonus) of the Concentration back
--   * Concentration cost at any skill, from the game's cost curves (used when simulating)
local _, CH = ...

local St = {}
CH.Stats = St

-- Rating per 100% chance (CraftSim CONST.PERCENT_DIVISION_FACTORS, Midnight)
St.DIVISOR = { multicraft = 1100, resourcefulness = 900, ingenuity = 1000, craftingspeed = 2650 }
St.RES_SAVE = 0.30 -- average share of reagents a Resourcefulness proc returns
St.REFUND = 0.50   -- Ingenuity hands back half the Concentration before perks
St.MC_CONSTANT = { [1] = 2.1, [2] = 1.83, [5] = 1.875, default = 2.5 }

local NAMES = {
	multicraft = { "multicraft", "ITEM_MOD_MULTICRAFT_SHORT" },
	resourcefulness = { "resourcefulness", "ITEM_MOD_RESOURCEFULNESS_SHORT" },
	ingenuity = { "ingenuity", "ITEM_MOD_INGENUITY_SHORT" },
	craftingspeed = { "crafting speed", "ITEM_MOD_CRAFTING_SPEED_SHORT" },
}

local function statKey(name)
	name = string.lower(name or "")
	for key, n in pairs(NAMES) do
		if name == n[1] or (_G[n[2]] and name == string.lower(_G[n[2]])) then return key end
	end
end

--- Empty stat set: ratings, perk extras and which stats the recipe uses.
function St.New()
	return { skill = 0, difficulty = 0, multicraft = 0, resourcefulness = 0, ingenuity = 0, craftingspeed = 0,
		mcExtra = 0, resExtra = 0, refundExtra = 0, concReduce = 0, supports = {} }
end

--- Stats from a GetCraftingOperationInfo result. Gear, buffs and spec are already in what the game reports.
function St.FromOperation(op)
	local s = St.New()
	if not op then return s end
	s.skill = (op.baseSkill or 0) + (op.bonusSkill or 0)
	s.difficulty = (op.baseDifficulty or 0) + (op.bonusDifficulty or 0)
	s.craftingDataID = op.craftingDataID
	for _, b in ipairs(op.bonusStats or {}) do
		local key = statKey(b.bonusStatName)
		if key then
			local rating = b.bonusStatValue
			if not rating and b.ratingPct then rating = b.ratingPct / 100 * St.DIVISOR[key] end
			-- Multicraft is listed on recipes that can't proc it with no rating behind it
			if key ~= "multicraft" or (rating or 0) > 0 or (b.ratingPct or 0) > 0 then
				s[key] = rating or 0
				s.supports[key] = true
			end
		end
	end
	return s
end

--- Adds a change (from gear, spec ranks, finishing reagents or a simulation) to a stat set.
function St.Add(s, d)
	if not d then return s end
	for _, k in ipairs({ "skill", "multicraft", "resourcefulness", "ingenuity", "craftingspeed", "mcExtra", "resExtra", "refundExtra", "concReduce" }) do
		s[k] = (s[k] or 0) + (d[k] or 0)
	end
	return s
end

function St.Copy(s)
	local c = {}
	for k, v in pairs(s) do c[k] = v end
	c.supports = {}
	for k, v in pairs(s.supports or {}) do c.supports[k] = v end
	return c
end

function St.Chance(s, key)
	if not s.supports[key] then return 0 end
	return math.max(0, math.min(1, (s[key] or 0) / St.DIVISOR[key]))
end

--- Average extra items from one Multicraft proc.
function St.MulticraftExtra(base, mcExtra)
	local c = St.MC_CONSTANT[base] or St.MC_CONSTANT.default
	local maxExtra = c * base * (1 + (mcExtra or 0))
	return (1 + maxExtra) / 2
end

--- Average profit of one craft. unit is one item's value after the auction cut, base the items a
--- craft makes, cost all reagents, required the reagents Resourcefulness can save.
--- Returns the average and its parts so a tooltip can show the sum.
function St.Average(unit, base, cost, required, s)
	local mc, res = St.Chance(s, "multicraft"), St.Chance(s, "resourcefulness")
	local extra = St.MulticraftExtra(base, s.mcExtra)
	local plain = unit * base - cost
	local mcGold = mc * extra * unit
	local saved = (required or cost) * St.RES_SAVE * (1 + (s.resExtra or 0))
	local resGold = res * saved
	return plain + mcGold + resGold, {
		plain = plain, mc = mc, extraItems = extra, mcGold = mcGold, res = res, saved = saved, resGold = resGold,
	}
end

--- Concentration you spend on average once Ingenuity refunds are counted.
function St.AverageConcentration(cost, s)
	local ing = St.Chance(s, "ingenuity")
	return cost * (1 - ing * (St.REFUND + (s.refundExtra or 0))), ing
end

-- Sorted {index, value} pairs from a {[x] = y} table.
-- The curves are fixed data, so each is sorted once and the sorted copy kept.
local sortedCache = setmetatable({}, { __mode = "k" })
local function sorted(t)
	if sortedCache[t] then return sortedCache[t] end
	local out = {}
	for k, v in pairs(t) do table.insert(out, { k, v }) end
	table.sort(out, function(a, b) return a[1] < b[1] end)
	sortedCache[t] = out
	return out
end

local function bracket(x, list)
	for i, p in ipairs(list) do
		local nxt = list[i + 1]
		if x >= p[1] and (not nxt or x <= nxt[1]) then return p, nxt end
	end
end

--- Concentration to lift a craft to the next quality at this skill, from the game's curve for the
--- recipe (CraftSim's GetConcentrationCostForSkill). nil when the recipe has no known curve.
function St.ConcentrationCost(craftingDataID, difficulty, skill, reduce)
	local curve = CH.ConcCurves and craftingDataID and CH.ConcCurves[craftingDataID]
	if not curve or not difficulty or difficulty <= 0 then return nil end
	skill = math.min(skill, difficulty)
	local factor = skill / difficulty
	-- the constant follows the recipe's difficulty (clamped to the curve's ends); the value follows skill
	local cs = sorted(curve.c)
	local cc, ccNext = bracket(difficulty, cs)
	if not cc and cs[1] then
		if difficulty < cs[1][1] then cc = cs[1] else cc = cs[#cs] end
	end
	local constant = cc and cc[2] or 0
	if cc and ccNext and ccNext[1] ~= cc[1] then
		constant = cc[2] + (difficulty - cc[1]) * (ccNext[2] - cc[2]) / (ccNext[1] - cc[1])
	end
	local v, vNext = bracket(factor, sorted(curve.v))
	local fromF, toF = v and v[1] or 0, vNext and vNext[1] or 1
	local fromV, toV = v and v[2] or 0, vNext and vNext[2] or 1
	local fromS, toS = difficulty * fromF, difficulty * toF
	local value = fromV
	if toS ~= fromS then value = fromV + (skill - fromS) * (toV - fromV) / (toS - fromS) end
	local c = value * constant
	return math.floor(c * (1 - (reduce or 0)) + 0.5)
end

--- Skill needed for each quality, as fractions of difficulty, when the game didn't tell us.
St.THRESHOLDS = {
	[2] = { 0, 1 },
	[3] = { 0, 0.5, 1 },
	[5] = { 0, 0.2, 0.5, 0.8, 1 },
}

--- Stats a profession item gives: ratings from its stat list and skill from its "Equip:" line.
function St.FromItem(link)
	local s = St.New()
	if not link then return s end
	local stats = C_Item and C_Item.GetItemStats and C_Item.GetItemStats(link) or {}
	s.multicraft = stats.ITEM_MOD_MULTICRAFT_SHORT or 0
	s.resourcefulness = stats.ITEM_MOD_RESOURCEFULNESS_SHORT or 0
	s.ingenuity = stats.ITEM_MOD_INGENUITY_SHORT or 0
	s.craftingspeed = stats.ITEM_MOD_CRAFTING_SPEED_SHORT or 0
	local tip = C_TooltipInfo and C_TooltipInfo.GetHyperlink and C_TooltipInfo.GetHyperlink(link)
	for _, line in ipairs(tip and tip.lines or {}) do
		local text = line.leftText or ""
		if text:find((ITEM_SPELL_TRIGGER_ONEQUIP or "Equip:"), 1, true) and text:lower():find("skill") then
			s.skill = tonumber(text:match("(%d+)")) or 0
			break
		end
	end
	return s
end

--- a - b, for comparing two stat sets.
function St.Diff(a, b)
	local d = St.New()
	for _, k in ipairs({ "skill", "multicraft", "resourcefulness", "ingenuity", "craftingspeed", "mcExtra", "resExtra", "refundExtra", "concReduce" }) do
		d[k] = (a[k] or 0) - (b[k] or 0)
	end
	return d
end
