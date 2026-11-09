-- Craft results log: what each craft really gave (Multicraft extras, reagents Resourcefulness saved,
-- Ingenuity refunds, Concentration spent) against what the advisor expected, so you can see whether
-- the averages hold for you. Kept per character.
local _, CH = ...

local Lg = {}
CH.Log = Lg

local pending -- the craft just started: recipe, expected row

local function log()
	local me = CH.Me()
	me.log = me.log or {}
	return me.log
end

local function price(kind, id) return id and CH.Prices.Get(kind, "i:" .. id) end

-- The reagents a craft really used ({ itemID, quantity } infos from CraftRecipe), priced at chmat,
-- plus the fixed reagents the advisor knows about. nil when a reagent has no price.
local function usedCost(r, reagents)
	if type(reagents) ~= "table" or not r then return nil end
	local total = 0
	for _, x in ipairs(reagents) do
		local id = x.itemID or (x.reagent and x.reagent.itemID)
		local p = price("chmat", id)
		if id and not p then return nil end
		total = total + (p or 0) * (x.quantity or 0)
	end
	for _, slot in ipairs(r.fixed or {}) do
		local p = price("chmat", slot.items and slot.items[1])
		if not p then return nil end
		total = total + p * (slot.qty or 0)
	end
	return total
end

-- The advisor row these reagents match (same units of each quality in each slot), if any.
local function matchRow(r, reagents, concentrate)
	if type(reagents) ~= "table" then return nil end
	local used = {}
	for _, x in ipairs(reagents) do
		local id = x.itemID or (x.reagent and x.reagent.itemID)
		if id then used[id] = (used[id] or 0) + (x.quantity or 0) end
	end
	for _, row in ipairs(r.rows or {}) do
		if (row.concentration ~= nil) == (concentrate and true or false) and row.picks then
			local same = true
			for i, slot in ipairs(r.qual or {}) do
				for q, id in ipairs(slot.items) do
					if ((row.picks[i] or {})[q] or 0) ~= (used[id] or 0) then same = false end
				end
			end
			if same then return row end
		end
	end
end

--- Called when a craft starts (any craft, ours or the game's Craft button), with the reagents and
--- order the game was given. The expected figures come from the advisor row with those exact
--- reagents; when none matches, the cost is worked out from the reagents and nothing is expected.
function Lg.Started(recipeID, count, concentrate, reagents, orderID)
	local r = CH.AdvisorUI and CH.AdvisorUI.Current and CH.AdvisorUI.Current()
	if r and r.recipeID ~= recipeID then r = nil end
	local row
	if r then
		if type(reagents) == "table" and #reagents > 0 then row = matchRow(r, reagents, concentrate)
		else row = concentrate and r.bestConc or r.best end
	end
	local cost = row and row.cost or usedCost(r, reagents)
	pending = { recipeID = recipeID, count = count or 1, concentrate = concentrate,
		expected = row and row.profit, cost = cost, mc = row and row.parts and row.parts.mc,
		res = row and row.parts and row.parts.res, ing = row and row.ingenuity, name = r and r.name,
		order = (orderID ~= nil) or (r and r.order ~= nil) or nil }
end

--- The craft just started, as logged (for tests and the results window).
function Lg.Pending() return pending end

--- One crafting result from the game (TRADE_SKILL_ITEM_CRAFTED_RESULT).
function Lg.Result(data)
	if not data then return end
	local recipeID = pending and pending.recipeID or data.recipeID
	if not recipeID then return end
	local L = log()
	local e = L[recipeID] or { crafts = 0, items = 0, mcProcs = 0, extraItems = 0, resProcs = 0, saved = 0,
		ingProcs = 0, concSpent = 0, concRefund = 0, value = 0, cost = 0, expected = 0, expMc = 0, expRes = 0, expIng = 0, concCrafts = 0 }
	L[recipeID] = e
	local info = C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(recipeID)
	e.name = (info and info.name) or (pending and pending.name) or e.name
	e.crafts = e.crafts + 1
	local qty = data.quantity or 1
	e.items = e.items + qty
	local extra = data.multicraft or 0
	if extra > 0 then e.mcProcs = e.mcProcs + 1; e.extraItems = e.extraItems + extra end
	local unit = price("chvalue", data.itemID)
	if unit then e.value = e.value + unit * CH.AH_CUT * qty end
	local saved = 0
	for _, r in ipairs(data.resourcesReturned or {}) do
		local p = price("chmat", r.itemID)
		if p then saved = saved + p * (r.quantity or 0) end
	end
	if #(data.resourcesReturned or {}) > 0 then e.resProcs = e.resProcs + 1 end
	e.saved = e.saved + saved
	if data.hasIngenuityProc then e.ingProcs = e.ingProcs + 1 end
	if (data.concentrationSpent or 0) > 0 then e.concCrafts = e.concCrafts + 1 end
	e.concSpent = e.concSpent + (data.concentrationSpent or 0)
	-- what the Concentration crafts alone made (output at market + saved - reagents), for gold per point
	if (data.concentrationSpent or 0) > 0 then
		e.concGold = (e.concGold or 0) + (unit and unit * CH.AH_CUT * qty or 0) + saved - (pending and pending.cost or 0)
	end
	e.concRefund = e.concRefund + (data.ingenuityRefund or 0)
	-- the forecast for this batch, matched to its sales later (orders go to the customer, not the AH)
	if CH.Forecast and data.itemID and not (pending and pending.order) then
		CH.Forecast.Record(data.itemID, qty, { cost = pending and pending.cost, profit = pending and pending.expected,
			concentration = (data.concentrationSpent or 0) > 0, recipeID = recipeID })
	end
	if pending then
		e.cost = e.cost + (pending.cost or 0)
		e.expected = e.expected + (pending.expected or 0)
		e.expMc = e.expMc + (pending.mc or 0)
		e.expRes = e.expRes + (pending.res or 0)
		e.expIng = e.expIng + (pending.ing or 0)
		pending.count = pending.count - 1
		if pending.count <= 0 then pending = nil end
	end
	e.at = time()
	if Lg.Changed then Lg.Changed() end
end

--- Rows for the results window: per recipe, what the crafts made valued at market now (not what
--- they sold for) against what the advisor expected.
function Lg.Rows()
	local out = {}
	for id, e in pairs(log()) do
		local actual = e.value + e.saved - e.cost
		table.insert(out, { recipeID = id, name = e.name, crafts = e.crafts, actual = actual, expected = e.expected,
			mcRate = e.mcProcs / e.crafts, expMcRate = e.expMc / e.crafts, resRate = e.resProcs / e.crafts,
			expResRate = e.expRes / e.crafts, ingRate = e.concCrafts > 0 and e.ingProcs / e.concCrafts or nil,
			expIngRate = e.concCrafts > 0 and e.expIng / e.concCrafts or nil, e = e })
	end
	table.sort(out, function(a, b) return a.crafts > b.crafts end)
	return out
end

function Lg.Clear() wipe(log()); if Lg.Changed then Lg.Changed() end end

if hooksecurefunc and C_TradeSkillUI and C_TradeSkillUI.CraftRecipe then
	hooksecurefunc(C_TradeSkillUI, "CraftRecipe", function(recipeID, count, reagents, _, orderID, concentrate)
		Lg.Started(recipeID, count, concentrate, reagents, orderID)
	end)
end
CH.On("TRADE_SKILL_ITEM_CRAFTED_RESULT", function(_, data) Lg.Result(data) end)

-- Results, in Analytics -----------------------------------------------------------------------
-- What each character's crafts really gave against what the advisor expected, one row per character
-- and recipe. Profit here is the crafts' output valued at market now, not what it sold for.
local LUI = {}
CH.LogUI = LUI

--- Rows for every character: { char, recipeID, name, crafts, actual, expected, rates... }.
function Lg.AllRows()
	local out = {}
	for key, c in pairs(CH.db.characters or {}) do
		for id, e in pairs(c.log or {}) do
			if (e.crafts or 0) > 0 then
				table.insert(out, { char = c.name or key, recipeID = id, name = e.name, crafts = e.crafts,
					actual = e.value + e.saved - e.cost, expected = e.expected,
					mcRate = e.mcProcs / e.crafts, expMcRate = e.expMc / e.crafts, resRate = e.resProcs / e.crafts,
					expResRate = e.expRes / e.crafts, ingRate = e.concCrafts > 0 and e.ingProcs / e.concCrafts or nil,
					expIngRate = e.concCrafts > 0 and e.expIng / e.concCrafts or nil,
					concSpent = e.concSpent, concActual = e.concGold })
			end
		end
	end
	table.sort(out, function(a, b) return a.crafts > b.crafts end)
	return out
end

local function pct(a, b)
	if not a then return CH.Theme.Color("muted", "-") end
	local s = string.format("%d%%", math.floor(a * 100 + 0.5))
	if b then s = s .. CH.Theme.Color("muted", string.format("/%d", math.floor(b * 100 + 0.5))) end
	return s
end

local function resultRows(ctx)
	local T, out = CH.Theme, {}
	local crafts, actual, expected = 0, 0, 0
	for _, d in ipairs(Lg.AllRows()) do
		if ctx.keepName(d.name) then
			crafts, actual, expected = crafts + d.crafts, actual + d.actual, expected + d.expected
			table.insert(out, { cells = { d.name or "?", d.char, d.crafts, pct(d.mcRate, d.expMcRate), pct(d.resRate, d.expResRate),
				pct(d.ingRate, d.expIngRate), T.Color(d.actual >= d.expected and "ok" or "bad", CH.FormatMoney(d.actual)),
				T.Color("muted", CH.FormatMoney(d.expected)) },
				sort = { d.name or "", d.char, d.crafts, d.mcRate or 0, d.resRate or 0, d.ingRate or 0, d.actual, d.expected } })
		end
	end
	if not out[1] then
		return out, T.Color("muted", "Nothing logged yet. Every craft is recorded here, on each character.")
	end
	return out, string.format("%d crafts: %s at market against %s expected.", crafts, CH.FormatMoney(actual), CH.FormatMoney(expected))
		.. T.Color("muted", "  Rates are what you got / what was expected. /aiq results clear empties this character's log.")
end

-- (Analytics/Views.lua puts it in the Analytics nav, in order)
CH.LedgerUI.Register("analytics", { results = { label = "Craft results", sort = 3, noTime = true, rows = resultRows,
	cols = { { "Recipe", 0, 190 }, { "Character", 194, 90 }, { "Crafts", 288, 50 }, { "Multicraft", 342, 76 }, { "Resourceful", 422, 80 },
		{ "Ingenuity", 506, 70 }, { "At market", 580, 72 }, { "Expected", 656, 68 } } } }, {})

--- Craft results now live in Analytics.
function LUI.Open() if CH.UI and CH.UI.Page then CH.UI.Page("analytics", "results") end end
LUI.Toggle = LUI.Open
function LUI.Refresh() end

Lg.Changed = function() if CH.UI and CH.UI.IsShown and CH.UI.IsShown() then CH.UI.Refresh() end end
