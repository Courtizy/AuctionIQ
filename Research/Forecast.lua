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
	table.insert(store(), b)
	Fc.Clear()
	return b
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
		local each = (s.amount / s.quantity) * CH.AH_CUT
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
