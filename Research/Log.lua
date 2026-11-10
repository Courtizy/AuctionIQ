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
-- plus the fixed reagents the advisor knows about. On a crafting order the slots the customer
-- filled (provided) cost you nothing and are left out. nil when a reagent has no price.
local function usedCost(r, reagents, provided)
	if type(reagents) ~= "table" or not r then return nil end
	-- units the customer gives in each slot (true: all of it); those come off what's charged
	local left = {}
	for slot, n in pairs(provided or {}) do left[slot] = n == true and math.huge or n end
	local total = 0
	for _, x in ipairs(reagents) do
		local id = x.itemID or (x.reagent and x.reagent.itemID)
		local slot = x.dataSlotIndex or (x.reagentInfo and x.reagentInfo.dataSlotIndex)
		local n = x.quantity or 0
		local off = slot and math.min(n, left[slot] or 0) or 0
		if off > 0 then left[slot] = left[slot] - off end
		if n - off > 0 then
			local p = price("chmat", id)
			if id and not p then return nil end
			total = total + (p or 0) * (n - off)
		end
	end
	-- fixed slots: an advisor result for this order already took the customer's units off
	for _, slot in ipairs(r.fixed or {}) do
		local n = slot.qty or 0
		local g = not r.order and (provided or {})[slot.index]
		if g then n = g == true and 0 or math.max(0, n - g) end
		if n > 0 then
			local p = price("chmat", slot.items and slot.items[1])
			if not p then return nil end
			total = total + p * n
		end
	end
	return total
end

-- The order a craft fills: { commission, rewards, providedSlots } from the advisor's order, else
-- from the game's live order. nil when the craft isn't for an order, or the order can't be found.
local function orderFor(r, orderID)
	if r and r.order and (orderID == nil or CH.Orders.Same(r.order.orderID, orderID)) then return r.order end
	if orderID == nil or not CH.Orders then return nil end
	local live = CH.Orders.Live and CH.Orders.Live(orderID)
	return live and CH.Orders.FromOrder(live) or { orderID = orderID }
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
	local order = orderFor(r, orderID)
	-- an advisor row priced for a different order (or for the AH) isn't this craft's cost
	if row and order and not r.order then row = nil end
	local cost = row and row.cost or usedCost(r, reagents, order and order.providedSlots)
	pending = { recipeID = recipeID, count = count or 1, concentrate = concentrate,
		expected = row and row.profit, cost = cost, mc = row and row.parts and row.parts.mc,
		res = row and row.parts and row.parts.res, ing = row and row.ingenuity, name = r and r.name,
		order = order and true or nil,
		-- the forecast's yield, Resourcefulness and item value, kept so results can be explained later
		items = row and CH.Decide and CH.Decide.Items(r.made, row.parts) or nil, expSaved = row and row.parts and row.parts.resGold or nil,
		unit = row and row.unit or nil,
		-- what the order pays you: the commission after the consortium's cut, plus patron rewards
		orderIncome = order and ((order.commission or 0) + (order.rewards or 0)) or nil }
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
	-- An order's item goes to the customer, so what it made is the order's pay, once per order,
	-- not the item at market. Kept apart too, so you can see what orders brought in.
	local order = pending and pending.order
	local income
	if order then
		income = pending.orderIncome or 0
		pending.orderIncome = nil -- paid once, even when the game reports the craft in parts
		e.orderCrafts = (e.orderCrafts or 0) + 1
		e.orderIncome = (e.orderIncome or 0) + income
	else
		local unit = price("chvalue", data.itemID)
		income = unit and unit * CH.AH_CUT * qty
	end
	if income then e.value = e.value + income end
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
		e.concGold = (e.concGold or 0) + (income or 0) + saved - (pending and pending.cost or 0)
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
		if pending.items then
			-- only crafts the advisor forecast count toward the yield comparison
			e.fcCrafts = (e.fcCrafts or 0) + 1
			e.fcItems = (e.fcItems or 0) + qty
			e.expItems = (e.expItems or 0) + pending.items
			e.expSaved = (e.expSaved or 0) + (pending.expSaved or 0)
			e.fcSaved = (e.fcSaved or 0) + saved
			e.expUnit = (e.expUnit or 0) + (pending.unit or 0) * pending.items
		end
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
					concSpent = e.concSpent, concActual = e.concGold, stages = Lg.Stages(c.name, id, e) })
			end
		end
	end
	table.sort(out, function(a, b) return a.crafts > b.crafts end)
	return out
end

--- A recipe's crafts in three stages, kept apart:
---   forecast  what the advisor expected at craft time (profit, saved when each craft was made)
---   actual    what the crafts really gave: items made and reagents used, valued at market when made
---   realized  what has sold: later sales matched to these crafts by item and date, oldest first
--- Unsold items keep an estimated value; they count as realized only once they sell. Where the
--- forecast is known it explains the gap: yield (items against expected), Resourcefulness (reagents
--- saved against expected) and sale price (what sold units fetched against their forecast).
function Lg.Stages(char, recipeID, e)
	local out = { forecast = e.expected or 0, actual = (e.value or 0) + (e.saved or 0) - (e.cost or 0), crafts = e.crafts or 0 }
	if (e.fcCrafts or 0) > 0 then
		local each = (e.expItems or 0) > 0 and (e.expUnit or 0) / e.expItems or 0
		out.produced = { items = e.fcItems, expected = e.expItems, gold = ((e.fcItems or 0) - (e.expItems or 0)) * each }
		out.saved = { got = e.fcSaved or 0, expected = e.expSaved or 0, gold = (e.fcSaved or 0) - (e.expSaved or 0) }
	end
	-- realized: the batches these crafts recorded, with what has sold of each
	local made, sold, revenue, soldCost, forecastSold, unsold = 0, 0, 0, 0, 0, 0
	local unsoldValue, unsoldMargin = 0, 0
	if CH.Forecast then
		local byItem = {}
		for _, b in ipairs(CH.Forecast.Store()) do
			if b.recipe == recipeID and (not b.char or not char or b.char == char) then byItem[b.id] = true end
		end
		for id in pairs(byItem) do
			local value = CH.Prices.Get("chvalue", "i:" .. id)
			for _, b in ipairs(CH.Forecast.Batches(id)) do
				if b.recipe == recipeID and (not b.char or not char or b.char == char) then
					made = made + b.qty
					sold = sold + (b.sold or 0)
					revenue = revenue + (b.revenue or 0)
					soldCost = soldCost + (b.cost and b.cost / b.qty or 0) * (b.sold or 0)
					forecastSold = forecastSold + (b.expectEach or 0) * (b.sold or 0)
					local left = b.qty - (b.sold or 0)
					unsold = unsold + left
					unsoldValue = unsoldValue + left * (value or 0) * CH.AH_CUT
					unsoldMargin = unsoldMargin + left * ((b.expectEach or 0) - (b.cost and b.cost / b.qty or 0))
				end
			end
		end
	end
	if made > 0 then
		out.realized = { made = made, sold = sold, revenue = revenue, cost = soldCost, profit = revenue - soldCost,
			unsold = unsold, unsoldValue = unsoldValue, unsoldMargin = unsoldMargin, price = sold > 0 and (revenue - forecastSold) or nil }
	end
	return out
end

--- The forecast-to-realized waterfall for a recipe: { { label, value, total } }, each step what moved
--- the result, ending on what has really been realized. The steps:
---   Forecast at craft time
---   + yield (items against expected, at the expected value) + Resourcefulness (against expected)
---   + market by craft time (the rest of the gap to the crafts' value when made)
---   = Actual at market
---   + sale price (what sold units fetched against their forecast)
---   - still unsold (their expected margin isn't realized yet)
---   + the rest (deposits, Resourcefulness not in batch costs, matching)
---   = Realized
--- nil before any of these crafts have a forecast and a recorded batch.
function Lg.Waterfall(s)
	if not (s.produced and s.realized) then return nil end
	local r = s.realized
	local steps = { { "Forecast at craft time", s.forecast, true } }
	local y, sv = s.produced.gold, s.saved and s.saved.gold or 0
	table.insert(steps, { "Yield", y })
	table.insert(steps, { "Resourcefulness", sv })
	table.insert(steps, { "Market by craft time", s.actual - s.forecast - y - sv })
	table.insert(steps, { "Actual at market", s.actual, true })
	local price = r.price or 0
	table.insert(steps, { "Sale price", price })
	table.insert(steps, { "Still unsold", -r.unsoldMargin })
	table.insert(steps, { "Deposits, matching, rest", r.profit - s.actual - price + r.unsoldMargin })
	table.insert(steps, { "Realized", r.profit, true })
	return steps
end

--- Hover lines explaining one recipe's stages: { { label, value } }.
function Lg.StageLines(d)
	local T, M = CH.Theme, CH.FormatMoney
	local s = d.stages
	local mut = function(t) return T.Color("muted", t) end
	local signed = function(c) return T.Color(c >= 0 and "ok" or "bad", (c >= 0 and "+" or "") .. M(c)) end
	local out = { { T.Color("accent", (d.name or "?") .. "  " .. (d.char or "")) } }
	table.insert(out, { "1. Forecast at craft time", M(s.forecast) })
	table.insert(out, { mut("   what the advisor expected, " .. s.crafts .. " crafts"), "" })
	table.insert(out, { "2. Actual yield and reagents", M(s.actual) })
	table.insert(out, { mut("   items made and reagents used, at market when made"), "" })
	if s.produced then
		table.insert(out, { string.format("   Yield: %d items, %.1f expected", s.produced.items or 0, s.produced.expected or 0), signed(s.produced.gold) })
		table.insert(out, { "   Resourcefulness: saved against expected", signed(s.saved.gold) })
	end
	local r = s.realized
	if r then
		table.insert(out, { "3. Realized sales", signed(r.profit) })
		table.insert(out, { string.format("   %d of %d sold for %s, their reagents %s", r.sold, r.made, M(r.revenue), M(r.cost)), "" })
		if r.price then table.insert(out, { "   Sale price against the forecast", signed(r.price) }) end
		if r.unsold > 0 then table.insert(out, { string.format("   %d unsold, estimated value (not realized)", r.unsold), M(r.unsoldValue) }) end
		local w = Lg.Waterfall(s)
		if w then
			table.insert(out, { T.Color("accent", "Forecast to realized") })
			local big = 1
			for _, st in ipairs(w) do big = math.max(big, math.abs(st[2])) end
			for _, st in ipairs(w) do
				local bar = CH.UI and CH.UI.TextBar and CH.UI.TextBar(math.abs(st[2]) / big, 60) or ""
				table.insert(out, { (st[3] and st[1] or ("   " .. st[1])) .. "  " .. bar, st[3] and M(st[2]) or signed(st[2]) })
			end
		end
		table.insert(out, { mut("Estimated attribution: sales are matched to crafts by item and date, oldest first. Deposits aren't matched to crafts.") })
	else
		table.insert(out, { "3. Realized sales", mut("none matched yet") })
	end
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
	local crafts, forecast, actual, realized = 0, 0, 0, 0
	local M = CH.FormatMoney
	for _, d in ipairs(Lg.AllRows()) do
		if ctx.keepName(d.name) then
			local s = d.stages
			local r = s.realized
			crafts, forecast, actual = crafts + d.crafts, forecast + s.forecast, actual + s.actual
			if r then realized = realized + r.profit end
			local yield = s.produced and (T.Color((s.produced.items or 0) + 0.5 >= (s.produced.expected or 0) and "ok" or "bad", tostring(s.produced.items or 0))
				.. T.Color("muted", string.format("/%.0f", s.produced.expected or 0))) or T.Color("muted", "-")
			table.insert(out, { tip = function() return Lg.StageLines(d) end,
				cells = { d.name or "?", d.char, d.crafts, T.Color("muted", M(s.forecast)), T.Color(s.actual >= s.forecast and "ok" or "bad", M(s.actual)), yield,
					r and T.Color(r.profit >= 0 and "ok" or "bad", M(r.profit)) or T.Color("muted", "none sold"),
					r and string.format("%d/%d", r.sold, r.made) or T.Color("muted", "-") },
				sort = { d.name or "", d.char, d.crafts, s.forecast, s.actual, s.produced and (s.produced.items - s.produced.expected) or 0, r and r.profit or -math.huge,
					r and r.made > 0 and r.sold / r.made or -1 } })
		end
	end
	if not out[1] then
		return out, T.Color("muted", "Nothing logged yet. Every craft is recorded here, on each character.")
	end
	local cal = CH.Decide and CH.Decide.Calibration()
	local calText = cal and string.format("  Batch forecasts: %d checked, %d inside their 80%% range, %d came in under the median%s.", cal.checked, cal.inside, cal.under,
		cal.checked >= 4 and cal.under / cal.checked >= 0.7 and " (runs optimistic)" or "") or ""
	return out, string.format("%d crafts: forecast %s, actual %s at market, %s realized from sales.", crafts, M(forecast), M(actual), M(realized)) .. calText
		.. T.Color("muted", "  Hover a row for the gap. Unsold items aren't realized. /aiq results clear empties this character's log.")
end

-- (Research/Views.lua puts it in Research, under Performance)
CH.LedgerUI.Register("research", { results = { label = "Craft results", sort = 3, noTime = true, rows = resultRows,
	cols = { { "Recipe", 0, 170 }, { "Character", 174, 80 }, { "Crafts", 258, 44 }, { "Forecast", 306, 80 }, { "Actual", 390, 84 },
		{ "Yield", 478, 66 }, { "Realized", 548, 96 }, { "Sold", 648, 76 } } } }, {})

--- Craft results now live in Analytics.
function LUI.Open() if CH.UI and CH.UI.Page then CH.UI.Page("research", "results") end end
LUI.Toggle = LUI.Open
function LUI.Refresh() end

Lg.Changed = function() if CH.UI and CH.UI.IsShown and CH.UI.IsShown() then CH.UI.Refresh() end end
