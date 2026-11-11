-- Forecast vs actual: every craft saves what the advisor expected (cost, sale price, profit), later
-- sales are matched to those crafts oldest first, and each item's record says how far its real sale
-- prices land from the forecast. The crafting advisor shades an item's expected sale price by that
-- record, so items that keep falling short drop down the scan.
local _, CH = ...

local Fc = {}
CH.Forecast = Fc

local DAY = 86400
Fc.PRIOR = 5             -- shading trusts your record as much as this many units sold on forecast
Fc.HALF_LIFE = 30 * DAY  -- a sale this old counts half
Fc.WINDOW = 90 * DAY     -- only crafts from the last 90 days count toward the record
Fc.SHADE_MIN, Fc.SHADE_MAX = 0.3, 1.5 -- only a guard; shrinkage keeps it near 1

local function store()
	CH.db.batches = CH.db.batches or {}
	return CH.db.batches
end
Fc.Store = store

local cache, cacheAt

function Fc.Clear() cache, cacheAt = nil, nil end

--- Save one craft: item made, how many, and the forecast at that moment. f = { cost (the whole
--- craft's reagents), profit (the advisor's expected profit for the craft), concentration }.
function Fc.Record(itemID, qty, f)
	if not itemID or not qty or qty <= 0 then return nil end
	f = f or {}
	local value = CH.Prices.Get("chvalue", "i:" .. itemID)
	local cost = f.cost
	if not cost and CH.Groups and CH.Groups.CostEach then
		local each = CH.Groups.CostEach(itemID)
		cost = each and each * qty
	end
	local b = { at = time(), id = itemID, qty = qty, char = UnitName and UnitName("player") or nil,
		cost = cost, expectEach = value and value * CH.AH_CUT, profit = f.profit, conc = f.concentration and true or nil,
		recipe = f.recipeID }
	-- the batch decision this craft fills, if you queued one for this item on this character
	local d = Fc.OpenDecision(itemID, b.char, b.at)
	if d then
		b.decision = d.key
		d.crafts = (d.crafts or 0) + 1
		d.made = (d.made or 0) + qty
		d.paid = (d.paid or 0) + (cost or 0)
		d.first = d.first or b.at
	end
	local list = store()
	table.insert(list, b)
	-- bounded: the record only reads the last Fc.WINDOW, so the oldest past the cap can go
	while #list > (CH.BATCHES_MAX or 5000) do table.remove(list, 1) end
	Fc.Clear()
	return b
end

-- Batch decisions ------------------------------------------------------------------------------
-- Queueing a batch saves the whole decision: how many, what each craft should make, what the
-- reagents and the sale price were, how fast it should sell and what should be left after a week.
-- The crafts that follow (same item and character, within two weeks, up to the crafts queued) link
-- back to it, their sales are matched to them as for every craft, and Fc.Explain splits the
-- difference between forecast and actual into sale price, sell-through, reagent cost and yield.

Fc.KEEP = 200            -- decisions kept
Fc.LINK = 14 * DAY       -- crafts this long after queueing still fill the decision

local function decisions()
	CH.db.decisions = CH.db.decisions or {}
	return CH.db.decisions
end
Fc.Decisions = decisions

--- Save a batch decision when it's queued. f = { item, recipe, name, quality, conc, n (crafts),
--- itemsEach, costEach (reagents a craft, net of Resourcefulness), priceEach (sale price an item),
--- netEach (an item after the cut and deposit), daily (sales a day), leftWeek, profit, source }.
function Fc.SaveDecision(f, now)
	if not (f and f.item and f.n and f.n > 0) then return nil end
	local list = decisions()
	CH.db.decisionSeq = (CH.db.decisionSeq or 0) + 1
	f.key = CH.db.decisionSeq
	f.at = now or time()
	f.char = f.char or (UnitName and UnitName("player")) or nil
	f.crafts, f.made, f.paid = 0, 0, 0
	f.expDays = (f.daily or 0) > 0 and f.n * (f.itemsEach or 1) / f.daily or nil
	list[#list + 1] = f
	while #list > Fc.KEEP do table.remove(list, 1) end
	return f
end

--- The newest decision a craft of item on char at time t still fills, or nil.
function Fc.OpenDecision(item, char, t)
	local list = decisions()
	for i = #list, 1, -1 do
		local d = list[i]
		if d.item == item and d.char == char and t - d.at <= Fc.LINK and t >= d.at and (d.crafts or 0) < d.n then return d end
	end
	return nil
end

--- Forecast against actual for one decision, by the time of `now`: { forecast, actual, miss, causes
--- = { price, sell, reagents, yield } (they add up to miss), sold, made, expItems, soldForecast, left
--- (items still unsold), leftWorth (at the forecast price), days (since the first craft), main (the
--- cause with the biggest effect), takeaway } or nil before any craft. Forecast and actual both
--- count gold back from sales so far less what the reagents cost.
function Fc.Explain(d, now)
	if not d or (d.crafts or 0) == 0 then return nil end
	now = now or time()
	local sold, revenue = 0, 0
	for _, b in ipairs(Fc.Batches(d.item)) do
		if b.decision == d.key then sold, revenue = sold + (b.sold or 0), revenue + (b.revenue or 0) end
	end
	local net = d.netEach or 0
	local days = math.max(0, (now - (d.first or d.at)) / DAY)
	local expItems = d.crafts * (d.itemsEach or 1)
	local demand = (d.daily or 0) * days
	local soldForecast = math.min(expItems, demand)        -- what the forecast says has sold by now
	local soldIfYield = math.min(d.made or 0, demand)      -- the same, from the items really made
	local forecastCost = d.crafts * (d.costEach or 0)
	local paid = (d.paid and d.paid > 0) and d.paid or forecastCost
	local causes = {
		price = revenue - sold * net,
		sell = (sold - soldIfYield) * net,
		yield = (soldIfYield - soldForecast) * net,
		reagents = forecastCost - paid,
	}
	local forecast = soldForecast * net - forecastCost
	local actual = revenue - paid
	local main, big = nil, 0
	for _, k in ipairs({ "price", "sell", "reagents", "yield" }) do
		if math.abs(causes[k]) > big then main, big = k, math.abs(causes[k]) end
	end
	local miss = actual - forecast
	if big < math.max(1, math.abs(forecast) * 0.05) then main = nil end
	local WORDS = { price = { "Sold above the forecast price", "Sold under the forecast price" },
		sell = { "Sold faster than forecast", "Sold slower than forecast" },
		reagents = { "Reagents cost less than forecast", "Reagents cost more than forecast" },
		yield = { "Made more than expected (Multicraft)", "Made fewer than expected" } }
	local takeaway = main and WORDS[main][causes[main] >= 0 and 1 or 2] or "On forecast so far"
	if main and main ~= "price" and sold > 0 and math.abs(causes.price) < big * 0.25 then takeaway = takeaway .. "; the price held" end
	return { forecast = forecast, actual = actual, miss = miss, causes = causes, sold = sold, made = d.made or 0, expItems = expItems,
		soldForecast = soldForecast, left = (d.made or 0) - sold, leftWorth = ((d.made or 0) - sold) * net, days = days, main = main,
		takeaway = takeaway, revenue = revenue, paid = paid }
end

-- Match sales to crafts, oldest first per item. Each batch gets sold, revenue (after the cut),
-- and saleDays (sum over units of days from craft to sale).
local function match()
	local now = time()
	if cache and cacheAt and now - cacheAt < 60 then return cache end
	local byItem = {}
	for _, b in ipairs(store()) do
		b.sold, b.revenue, b.saleDays, b.lastSale = 0, 0, 0, nil
		byItem[b.id] = byItem[b.id] or {}
		table.insert(byItem[b.id], b)
	end
	for _, list in pairs(byItem) do table.sort(list, function(a, c) return a.at < c.at end) end
	local sales = {}
	if CH.Ledger and CH.Ledger.Available() then
		for _, s in ipairs(CH.Ledger.Records("Sales")) do
			if s.id and byItem[s.id] and s.quantity > 0 then table.insert(sales, s) end
		end
	end
	table.sort(sales, function(a, c) return a.time < c.time end)
	-- a cursor per item skips batches already sold out, so the pass is about sales + batches
	local cursor = {}
	for _, s in ipairs(sales) do
		local left = s.quantity
		local each = CH.Ledger.Net(s) / s.quantity
		local list = byItem[s.id]
		local i = cursor[s.id] or 1
		while list[i] and list[i].sold >= list[i].qty do i = i + 1 end
		cursor[s.id] = i
		for k = i, #list do
			local b = list[k]
			if left <= 0 or b.at > s.time then break end -- batches are oldest first: later ones aren't made yet
			if b.sold < b.qty then
				local n = math.min(left, b.qty - b.sold)
				b.sold = b.sold + n
				b.revenue = b.revenue + each * n
				b.saleDays = b.saleDays + n * (s.time - b.at) / DAY
				b.lastSale = s.time
				left = left - n
			end
		end
	end
	cache, cacheAt = byItem, now
	return byItem
end

--- Batches of one item, oldest first, with what has sold of each.
function Fc.Batches(id) return match()[id] or {} end

--- Per item over crafts since `since`: { id, batches, made, sold, cost, revenue, forecast, realized,
--- expectEach, actualEach, accuracy (actual / expected sale price), days (average to sell) }.
function Fc.Performance(since)
	since = since or 0
	local out = {}
	for id, list in pairs(match()) do
		local e = { id = id, batches = 0, made = 0, sold = 0, cost = 0, soldCost = 0, revenue = 0, expected = 0, forecast = 0, saleDays = 0 }
		for _, b in ipairs(list) do
			if b.at >= since then
				e.batches = e.batches + 1
				e.made = e.made + b.qty
				e.sold = e.sold + b.sold
				local costEach = b.cost and b.cost / b.qty or 0
				e.cost = e.cost + (b.cost or 0)
				e.soldCost = e.soldCost + costEach * b.sold
				e.revenue = e.revenue + b.revenue
				if b.expectEach then e.expected = e.expected + b.expectEach * b.sold end
				e.forecast = e.forecast + (b.expectEach and (b.expectEach - costEach) * b.sold or 0)
				e.saleDays = e.saleDays + b.saleDays
			end
		end
		if e.batches > 0 then
			e.realized = e.revenue - e.soldCost
			e.expectEach = e.sold > 0 and e.expected / e.sold or nil
			e.actualEach = e.sold > 0 and e.revenue / e.sold or nil
			e.accuracy = e.expected > 0 and e.revenue / e.expected or nil
			e.days = e.sold > 0 and e.saleDays / e.sold or nil
			table.insert(out, e)
		end
	end
	table.sort(out, function(a, c) return a.realized > c.realized end)
	return out
end

--- How much of the forecast sale price an item really fetches, as a factor (1 = on forecast) and
--- why, or nil before anything has sold. Each sold unit counts with a 30-day half-life, and the ratio
--- is shrunk toward 1 by a prior worth Fc.PRIOR units: shade = (n*r + k) / (n + k). So three sales
--- at 60% shade to about 85%, and an old bad patch fades out.
function Fc.Shade(id, now)
	if not id then return nil end
	now = now or time()
	local since = now - Fc.WINDOW
	local n, expected, revenue, sold = 0, 0, 0, 0
	for _, b in ipairs(Fc.Batches(id)) do
		if b.at >= since and b.expectEach and b.expectEach > 0 and b.sold > 0 then
			local w = 0.5 ^ ((now - b.at) / Fc.HALF_LIFE)
			n = n + w * b.sold
			expected = expected + w * b.expectEach * b.sold
			revenue = revenue + w * b.revenue
			sold = sold + b.sold
		end
	end
	if sold == 0 or expected <= 0 then return nil end
	local r = revenue / expected
	local f = (n * r + Fc.PRIOR) / (n + Fc.PRIOR)
	f = math.max(Fc.SHADE_MIN, math.min(Fc.SHADE_MAX, f))
	return f, string.format("%d sold at %d%% of forecast", sold, math.floor(r * 100 + 0.5))
end
