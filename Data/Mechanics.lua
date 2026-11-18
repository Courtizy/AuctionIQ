-- Crafting mechanics measured from your own crafts, so the averages in Stats.lua rest on what the
-- game actually did rather than on community-measured constants:
--
--   Resourcefulness  on a proc, the share of the required reagents handed back, before perks:
--                    (units returned / units required) / (1 + perk bonus)
--   Ingenuity        on a proc, the share of the Concentration spent that comes back, before perks:
--                    refund / spent - perk bonus
--   Multicraft       on a proc, the extra items are spread evenly from 1 to c x base x (1 + perk),
--                    so their average is (1 + max) / 2 and c = (2 x average - 1) / (base x (1 + perk)),
--                    kept per base yield (the items one craft makes)
--
-- Each craft result (TRADE_SKILL_ITEM_CRAFTED_RESULT) with a proc adds one sample, when the craft's
-- perk bonuses are known (the advisor's row for it). A measured value is used once it rests on
-- MIN_SAMPLES procs; until then the starting value stands, and Mx.Value says which it is.
-- Saved in AuctionIQ.db.mechanics = { res = { n, sum }, ing = { n, sum }, mc = { [base] = { n, sum } } }.
local _, AuctionIQ = ...

local Mx = { MIN_SAMPLES = 20 }
AuctionIQ.Mechanics = Mx

-- The starting values, used until enough of your own procs are recorded.
Mx.DEFAULT = { res = 0.30, ing = 0.50, mc = { [1] = 2.1, [2] = 1.83, [5] = 1.875, default = 2.5 } }
-- what a single sample may read before it is treated as a misread and skipped
local RANGE = { res = { 0.02, 1 }, ing = { 0.05, 1 }, mc = { 0.1, 20 } }

local function store()
	local db = AuctionIQ.db
	if not db then return nil end
	db.mechanics = db.mechanics or {}
	local m = db.mechanics
	m.res, m.ing, m.mc = m.res or { n = 0, sum = 0 }, m.ing or { n = 0, sum = 0 }, m.mc or {}
	return m
end

local function add(acc, kind, v)
	local r = RANGE[kind]
	if not v or v ~= v or v < r[1] or v > r[2] then return false end
	acc.n, acc.sum = acc.n + 1, acc.sum + v
	return true
end

--- One craft result. data is the game's result; ctx = { base = items a craft makes, mcExtra,
--- resExtra, refundExtra (the perk bonuses, from the advisor's row), required = { [itemID] = units
--- the craft needs in its required basic slots } }. Returns how many samples it added.
function Mx.Note(data, ctx)
	local m = store()
	if not (m and data and ctx) then return 0 end
	local added = 0
	-- Resourcefulness: the units handed back against the units required
	local returned, required = 0, 0
	for _, r in ipairs(data.resourcesReturned or {}) do
		local need = ctx.required and ctx.required[r.itemID]
		if need and need > 0 then returned, required = returned + (r.quantity or 0), required + need end
	end
	if required > 0 and returned > 0 and ctx.resExtra then
		if add(m.res, "res", returned / required / (1 + ctx.resExtra)) then added = added + 1 end
	end
	-- Ingenuity: the refund against what was spent
	local spent, refund = data.concentrationSpent or 0, data.ingenuityRefund or 0
	if data.hasIngenuityProc and spent > 0 and refund > 0 and ctx.refundExtra then
		if add(m.ing, "ing", refund / spent - ctx.refundExtra) then added = added + 1 end
	end
	-- Multicraft: the extra items one proc made
	local extra, base = data.multicraft or 0, ctx.base
	if extra > 0 and base and base > 0 and ctx.mcExtra then
		local key = tostring(base)
		m.mc[key] = m.mc[key] or { n = 0, sum = 0 }
		if add(m.mc[key], "mc", (2 * extra - 1) / (base * (1 + ctx.mcExtra))) then added = added + 1 end
	end
	return added
end

--- A mechanic's value: kind "res", "ing" or "mc" (with base). Returns the value, whether it is
--- measured, and how many procs it rests on.
function Mx.Value(kind, base)
	local m = AuctionIQ.db and AuctionIQ.db.mechanics
	local acc
	if kind == "mc" then acc = m and m.mc and m.mc[tostring(base)]
	else acc = m and m[kind] end
	if acc and acc.n >= Mx.MIN_SAMPLES then return acc.sum / acc.n, true, acc.n end
	local d = Mx.DEFAULT[kind]
	if kind == "mc" then d = d[base] or d.default end
	return d, false, acc and acc.n or 0
end

--- The required basic reagents of a recipe, in units: { [itemID] = units } (each quality of a
--- reagent counts toward its slot). Empty when the game doesn't say.
function Mx.Required(recipeID)
	local ui = C_TradeSkillUI
	local out = {}
	if not (ui and ui.GetRecipeSchematic) then return out end
	local ok, s = pcall(ui.GetRecipeSchematic, recipeID, false)
	local basic = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic or 1
	for _, slot in ipairs(ok and s and s.reagentSlotSchematics or {}) do
		if slot.reagentType == basic and slot.required ~= false then
			for _, r in ipairs(slot.reagents or {}) do
				if r.itemID then out[r.itemID] = slot.quantityRequired or 1 end
			end
		end
	end
	return out
end

--- Chat lines: each mechanic, measured or starting value, and on how many procs.
function Mx.Lines()
	local out = {}
	local function line(label, kind, base, fmt)
		local v, measured, n = Mx.Value(kind, base)
		table.insert(out, string.format("  %s: %s (%s)", label, fmt(v),
			measured and string.format("measured from %d of your procs", n)
			or string.format("starting value, %d of %d procs recorded", n, Mx.MIN_SAMPLES)))
	end
	local pct = function(v) return string.format("%.1f%%", v * 100) end
	table.insert(out, "Crafting mechanics:")
	line("Resourcefulness returns", "res", nil, pct)
	line("Ingenuity refunds", "ing", nil, pct)
	local m = AuctionIQ.db and AuctionIQ.db.mechanics
	local bases = { 1 }
	for k in pairs(m and m.mc or {}) do if tonumber(k) ~= 1 then bases[#bases + 1] = tonumber(k) end end
	table.sort(bases)
	for _, b in ipairs(bases) do
		line(string.format("Multicraft constant (makes %d)", b), "mc", b, function(v) return string.format("%.2f", v) end)
	end
	return out
end
