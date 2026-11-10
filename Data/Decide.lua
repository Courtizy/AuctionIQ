-- Decision math shared by the advisor, the scan, Scenarios, the queue and the Dashboard. Each
-- function answers one question with the numbers AuctionIQ already has:
--   BreakEven     how low can the sale price go before this craft stops paying (per item)
--   ConcGain      what spending Concentration adds over the best plain craft, and per point
--   Evidence      where a sale estimate comes from: source, age and how many of your own sales
--   ConcForecast  how many Concentration crafts the points cover now, and the refund upside
--   Batch         what could happen to a batch over a week (Monte Carlo, on demand)
-- A craft's money is split the same way everywhere ("parts"): revenue (items after the cut, net of
-- expected deposits and gold tied up, Multicraft's extras included), reagents consumed, what
-- Resourcefulness gives back, deposits (which don't move with the price) and a fixed cost (the item a
-- recraft uses up). Profit = revenue - consumed + returned - fixed.
local _, CH = ...

local D = {}
CH.Decide = D
D.FEW = 5 -- fewer of your own posts than this and the region's numbers carry the estimate

-- Parts and scenarios ----------------------------------------------------------------------------

--- Items a craft makes on average, Multicraft's extras included.
function D.Items(made, p)
	p = p or {}
	return math.max(0.01, (made or 1) + (p.mc or 0) * (p.extraItems or 0))
end

--- Parts of a live advisor row (one craft). nil for an order (it pays a fixed commission).
function D.RowParts(result, r)
	if not r or not r.unit or not r.cost or (result and result.order) then return nil end
	local items = D.Items(result and result.made, r.parts)
	return { revenue = r.unit * items, consumed = r.cost, returned = r.parts and r.parts.resGold or 0,
		deposits = (r.ev and r.ev.deposits or 0) * items, fixed = r.oldValue or 0, items = items, price = r.price }
end

--- Parts of a saved scan row's accounts (Scan.Accounts). Older scans without the breakdown count
--- everything as revenue less reagents.
function D.AccountParts(row, acc)
	local a = acc or row.accounts
	if a and a.sales and a.cost then
		local revenue = a.sales + (a.mcGold or 0)
		local units = (a.unit and a.unit > 0) and revenue / a.unit or 0
		return { revenue = revenue, consumed = a.cost, returned = a.resGold or 0, deposits = (a.deposit or 0) * units,
			fixed = 0, items = units, price = a.price }
	end
	return { revenue = (row.profit or 0) + (row.cost or 0), consumed = row.cost or 0, returned = 0, deposits = 0, fixed = 0 }
end

--- Profit with reagents up r and the selling price down p (fractions). Reagents Resourcefulness
--- gives back are worth more too; deposits stay what they are.
function D.Reprice(parts, r, p)
	local revenue = parts.revenue - p * (parts.revenue + parts.deposits)
	return revenue - parts.consumed * (1 + r) + parts.returned * (1 + r) - (parts.fixed or 0)
end

--- The downside scenario you set in Scenarios: { reagents, price } (fractions).
function D.Scenario()
	local s = CH.db and CH.db.scenario
	return { reagents = s and s.reagents or 0.10, price = s and s.price or 0.10 }
end

-- Break-even ---------------------------------------------------------------------------------------

--- The sale price (per item, before the cut) at which a craft makes nothing, for this exact recipe
--- mix: the cut, expected yield (Multicraft), Resourcefulness, expected deposits and gold tied up all
--- included, since revenue moves in step with the price. Returns { price, estimate, factor, cushion }
--- where factor = price / estimate and cushion = how far the estimate can fall (0.12 = 12%).
--- nil without a price, or when no sale price covers it.
function D.BreakEvenParts(parts, estimate)
	if not parts or not estimate or estimate <= 0 then return nil end
	local scale = parts.revenue + parts.deposits -- revenue at the estimate, before deposits
	if scale <= 0 then return nil end
	local factor = (parts.deposits + parts.consumed - parts.returned + (parts.fixed or 0)) / scale
	if factor < 0 then factor = 0 end
	return { price = factor * estimate, estimate = estimate, factor = factor, cushion = 1 - factor }
end

function D.BreakEven(result, r)
	local parts = D.RowParts(result, r)
	return parts and D.BreakEvenParts(parts, r.price)
end

--- Profit a craft at sale price x (per item, before the cut): a straight line through the break-even.
function D.ProfitAt(parts, estimate, x)
	if not parts or not estimate or estimate <= 0 then return nil end
	return D.Reprice(parts, 0, 1 - x / estimate)
end

-- Concentration over the plain craft --------------------------------------------------------------

--- What a Concentration craft adds over the best plain craft you could make instead (or over not
--- crafting, when no plain craft pays): { plain, gain, perPoint (gain per expected point), total
--- (CraftSim's whole profit per point), avg }. plainProfit is the plain craft's profit, if any.
function D.ConcGain(c, plainProfit)
	if not c or not c.profit then return nil end
	local avg = c.avgConcentration or c.concentration
	if not avg or avg <= 0 then return nil end
	local plain = math.max(0, plainProfit or 0)
	local gain = c.profit - plain
	return { plain = plain, gain = gain, perPoint = gain / avg, total = c.profit / avg, avg = avg }
end

-- Evidence behind a sale estimate -----------------------------------------------------------------

local function raw(name, id) return CH.Prices.Raw and CH.Prices.Raw(name, id) end

--- Which TSM number chvalue mostly comes from, following its formula: min(listing now, post price).
--- "listing" (realm's lowest listing), "market" (realm market value, the 80% floor), "region" (a region
--- average), or nil without TSM. Only a label: a custom chvalue source may differ.
function D.PriceBasis(id)
	if not id or not CH.Prices.Available() then return nil end
	local minb, mkt, rmkt, rsale = raw("dbminbuyout", id), raw("dbmarket", id), raw("dbregionmarketavg", id), raw("dbregionsaleavg", id)
	local first = minb or mkt or rmkt
	local floor = (mkt or rmkt) and 0.8 * (mkt or rmkt)
	local now, nowKind = first, minb and "listing" or mkt and "market" or rmkt and "region"
	if floor and (not now or floor > now) then now, nowKind = floor, mkt and "market" or "region" end
	local base = rsale or rmkt
	local post = base and mkt and math.max(base, math.min(mkt, 4 * base)) or base
	local postKind = post and (mkt and post == mkt and "market" or "region")
	if post and (not now or post < now) then return postKind end
	return nowKind
end

D.BASIS = { listing = "your realm's lowest listing", market = "your realm's market value", region = "the region average" }

--- What a sale estimate for an item rests on: { basis, scan = { age } (your own AH scan of it),
--- sales = { n, last } (your sales, 30 days), posts = { sold, expired } (your posts, 30 days),
--- regionRate, regionPerDay, shade = { n, why }, fallback } where fallback names what stands in for
--- missing history ("region sale rate", "no sale rate").
function D.Evidence(id, now)
	now = now or time()
	local e = { basis = D.PriceBasis(id) }
	local scan = CH.Scans and CH.Scans.Get(id)
	if scan then e.scan = { age = scan.age } end
	if CH.Ledger and CH.Ledger.Available() then
		local v = CH.Prices.Values(id, now)
		if v.realized then e.sales = { n = v.n, last = v.lastSale } end
		local sold, expired = CH.Ledger.SellThrough(id)
		e.posts = { sold = sold or 0, expired = expired or 0 }
	end
	e.regionRate = CH.Expect and CH.Expect.RegionRate(id)
	e.regionPerDay = CH.Advisor and CH.Advisor.SoldPerDay(id)
	if CH.Forecast then
		local f, why = CH.Forecast.Shade(id, now)
		if f then e.shade = { factor = f, why = why } end
	end
	local own = e.posts and (e.posts.sold + e.posts.expired) or 0
	e.ownPosts = own
	if own < D.FEW then e.fallback = e.regionRate and "region sale rate" or nil end
	return e
end


--- The evidence as short phrases: { price, rate, volume } for one line or a hover.
function D.EvidenceText(e)
	local out = {}
	local age = function(s) return CH.Scans and CH.Scans.Age(s) or "?" end
	out.price = "Price: TSM, " .. (D.BASIS[e.basis] or "no TSM price")
		.. (e.scan and (", your AH scan " .. age(e.scan.age) .. " old") or " (TSM doesn't tell addons how old its data is)")
	if e.ownPosts >= D.FEW then
		out.rate = string.format("Sell rate: your %d posts in 30 days", e.ownPosts)
	elseif e.fallback then
		out.rate = e.ownPosts > 0 and string.format("Sell rate: only %d of your posts, so mostly the %s", e.ownPosts, e.fallback)
			or ("Sell rate: none of your posts, so the " .. e.fallback)
	else
		out.rate = e.ownPosts > 0 and string.format("Sell rate: only %d of your posts and no region rate", e.ownPosts)
			or "Sell rate: none known, so proceeds are the price after the cut"
	end
	out.basis = e.ownPosts >= D.FEW and string.format("%d of your posts", e.ownPosts)
		or e.fallback and (e.ownPosts > 0 and string.format("only %d of your posts, mostly the %s", e.ownPosts, e.fallback) or ("the " .. e.fallback .. ", none of your posts"))
		or "no sale rate yet"
	if e.sales then
		out.sales = string.format("Your sales: %d in 30 days", e.sales.n)
	else
		out.sales = "Your sales: none in 30 days"
	end
	out.volume = e.regionPerDay and string.format("Volume: region %s a day", e.regionPerDay % 1 == 0 and tostring(e.regionPerDay)
		or string.format("%.1f", e.regionPerDay)) or "Volume: region not reported"
	if e.shade then out.shade = "Your record: " .. e.shade.why end
	return out
end

-- Concentration forecast (exact) -------------------------------------------------------------------

--- How many crafts at `cost` points each the budget covers. Each craft needs its full cost before it
--- starts; an Ingenuity proc (chance ing) then gives back refund points. Worked out exactly over the
--- number of procs, not simulated. Returns { now = crafts covered without any refund, chance = {
--- [k] = chance of at least now + k crafts }, expected }. limit caps the crafts considered.
function D.ConcForecast(budget, cost, ing, refund, limit)
	budget, cost = budget or 0, cost or 0
	local out = { now = 0, chance = {}, expected = 0 }
	if cost <= 0 then return out end
	out.now = math.floor(budget / cost + 1e-9)
	ing, refund = math.max(0, math.min(1, ing or 0)), math.max(0, refund or 0)
	limit = limit or 500
	if ing <= 0 or refund <= 0 then out.expected = out.now; return out end
	-- alive[k]: chance of having made n crafts with k refunds so far and still being able to go on
	local alive, total = { [0] = 1 }, 0
	for n = 0, limit - 1 do
		local nxt, any = {}, false
		local reach = 0
		for k, p in pairs(alive) do
			if budget - n * cost + k * refund >= cost - 1e-9 then
				reach = reach + p -- craft n + 1 happens
				nxt[k] = (nxt[k] or 0) + p * (1 - ing)
				nxt[k + 1] = (nxt[k + 1] or 0) + p * ing
				any = true
			end
		end
		total = total + reach
		if n + 1 > out.now and reach > 1e-4 then out.chance[n + 1 - out.now] = reach end
		if not any or reach < 1e-4 then break end
		alive = nxt
	end
	out.expected = total
	return out
end

--- "Can make 8 now · 60% chance of a 9th" for a Concentration row and the points you have.
function D.ConcForecastFor(r, budget)
	if not r or not r.concentration or not budget then return nil end
	local s = r.stats or {}
	local ing = r.ingenuity or 0
	local refund = r.concentration * ((CH.Stats.REFUND or 0.5) + (s.refundExtra or 0))
	return D.ConcForecast(budget, r.concentration, ing, refund)
end

local function ordinal(n)
	local s = (n % 100 >= 11 and n % 100 <= 13) and "th" or ({ "st", "nd", "rd" })[n % 10] or "th"
	return n .. s
end
D.Ordinal = ordinal

function D.ConcForecastText(f)
	if not f then return nil end
	local t = string.format("Can make %d now", f.now)
	local p = f.chance[1]
	if p and p >= 0.005 then t = t .. string.format(", %d%% chance of a %s with Ingenuity refunds", math.floor(p * 100 + 0.5), ordinal(f.now + 1)) end
	return t
end

-- Batch outcomes (Monte Carlo) ---------------------------------------------------------------------
-- The question: what could happen to this batch in a week? Each run draws every craft's yield
-- (Multicraft procs and how many extra), Resourcefulness procs, one price shock shared by the whole
-- batch, and the week's sales. Cash recovered is only what sells; what's left is stock, valued apart.

D.SIZES = { 10, 30, 100 }
D.RUNS = 1000
D.HORIZON = 7

-- a small seeded generator, so a batch gives the same answer each time it's drawn
local function rng(seed)
	local s = (math.floor(seed or 1) % 2147483646) + 1
	return function()
		s = (s * 16807) % 2147483647
		return s / 2147483647
	end
end
D.RNG = rng

local function normal(u)
	local a, b = u(), u()
	return math.sqrt(-2 * math.log(math.max(a, 1e-12))) * math.cos(2 * math.pi * b)
end

local function poisson(u, mean)
	if mean <= 0 then return 0 end
	if mean > 40 then return math.max(0, math.floor(mean + math.sqrt(mean) * normal(u) + 0.5)) end
	local l, k, p = math.exp(-mean), 0, 1
	repeat k = k + 1; p = p * u() until p <= l
	return k - 1
end

local function quantile(sorted, q)
	if #sorted == 0 then return nil end
	local i = math.max(1, math.min(#sorted, math.floor(q * (#sorted - 1) + 1.5)))
	return sorted[i]
end

--- The inputs for one craft, from an advisor row: what it makes, its procs, its cost to buy for n
--- crafts (walking the AH listings you've seen) and the week's demand. Labels say where each comes
--- from, so the result shows which inputs are yours and which are the region's or assumptions.
function D.BatchInputs(result, r)
	if not result or not r or not r.unit or result.order then return nil end
	local St = CH.Stats
	local s = r.stats or St.New()
	local made = result.made or 1
	local mc, res = St.Chance(s, "multicraft"), St.Chance(s, "resourcefulness")
	local maxExtra = (St.MC_CONSTANT[made] or St.MC_CONSTANT.default) * made * (1 + (s.mcExtra or 0))
	local lines = CH.Advisor.CostLines(result, r.picks, r.finishing)
	local deposit = r.ev and r.ev.deposits or 0
	local item = r.item
	local daily = item and CH.Scan and CH.Scan.DailyUnits(item) or 0
	local ev = D.Evidence(item)
	return { made = made, mc = mc, maxExtra = math.max(1, maxExtra), res = res, saved = r.parts and r.parts.saved or 0,
		price = r.price, deposit = deposit, unit = r.unit, reagents = lines, daily = daily,
		have = function(id) return C_Item and C_Item.GetItemCount and C_Item.GetItemCount(id, true, false, true, true) or 0 end,
		evidence = ev, seed = (result.recipeID or 1) * 7 + r.quality * 131 + (r.concentration and 1 or 0) }
end

--- What buying the reagents for n crafts costs: walking the listings you've seen for what you don't
--- own. Returns material (everything at what buying it costs), cash (only what you'd buy).
function D.BatchCost(inp, n)
	local material, cash = 0, 0
	for _, c in ipairs(inp.reagents) do
		local need = c.n * n
		local unit = c.unit or 0
		local d = (not c.finishing) and CH.Depth and CH.Depth.Cost(c.id, need)
		local all = d and d.cost or unit * need
		material = material + all
		local buy = math.max(0, need - (inp.have and inp.have(c.id) or 0))
		if buy > 0 then
			local db = (not c.finishing) and CH.Depth and CH.Depth.Cost(c.id, buy)
			cash = cash + (db and db.cost or unit * buy)
		end
	end
	return material, cash
end

--- Batch outcomes for each size: { n, spend, cash (up front), recover (chance cash from sales
--- covers spend in the horizon), net = { p10, p50, p90 }, cashBack = { p10, p50, p90 }, left (median
--- items unsold), leftValue (their estimated value), items (median made) }. opts: sizes, runs, days,
--- price (the price spread: in 1 run of 10 it falls at least this much; default the Scenarios price).
function D.Batch(inp, opts)
	opts = opts or {}
	if not inp then return nil end
	local sizes, runs, days = opts.sizes or D.SIZES, opts.runs or D.RUNS, opts.days or D.HORIZON
	local fall = opts.price or D.Scenario().price
	local sd = fall / 1.2816 -- the 10th percentile of the price shock is -fall
	local out = {}
	for _, n in ipairs(sizes) do
		local u = rng(inp.seed + n)
		local spend, upfront = D.BatchCost(inp, n)
		local nets, backs, lefts, made = {}, {}, {}, {}
		local covered = 0
		local baseWhole = math.floor(inp.made)
		local baseFrac = inp.made - baseWhole
		for k = 1, runs do
			local items, saved = 0, 0
			for _ = 1, n do
				local base = baseWhole + ((baseFrac > 0 and u() < baseFrac) and 1 or 0)
				items = items + base
				if inp.mc > 0 and u() < inp.mc then items = items + 1 + u() * (inp.maxExtra - 1) end
				if inp.res > 0 and u() < inp.res then saved = saved + inp.saved end
			end
			items = math.floor(items + 0.5)
			local shock = math.max(0.05, 1 + sd * normal(u))
			local sold = math.min(items, poisson(u, inp.daily * days))
			local cash = sold * math.max(0, (inp.price or 0) * shock * CH.AH_CUT - (inp.deposit or 0))
			local cost = spend - saved
			if cash >= cost then covered = covered + 1 end
			nets[k], backs[k], lefts[k], made[k] = cash - cost, cash, items - sold, items
		end
		table.sort(nets); table.sort(backs); table.sort(lefts); table.sort(made)
		local left = quantile(lefts, 0.5)
		out[#out + 1] = { n = n, spend = spend, cash = upfront, recover = covered / runs,
			net = { p10 = quantile(nets, 0.1), p50 = quantile(nets, 0.5), p90 = quantile(nets, 0.9) },
			cashBack = { p10 = quantile(backs, 0.1), p50 = quantile(backs, 0.5), p90 = quantile(backs, 0.9) },
			left = left, leftValue = left * (inp.unit or 0), items = quantile(made, 0.5) }
	end
	return out
end

-- Concentration over a queue (exact) -------------------------------------------------------------

--- For a run of Concentration crafts in order, each { cost, ing, refund }: the chance each one can
--- start (it needs its full cost; a refund lands only after the craft that earns it). Worked out
--- exactly over the refunds that have landed. Returns reach[k] for k = 1..#crafts.
function D.ConcSequence(budget, crafts)
	local states = { [0] = 1 } -- refunded points so far (rounded to a tenth) -> chance, among runs still going
	local key = function(x) return math.floor(x * 10 + 0.5) end
	local spent, reach = 0, {}
	for k, c in ipairs(crafts) do
		local nxt, p = {}, 0
		for r10, pr in pairs(states) do
			if budget - spent + r10 / 10 >= c.cost - 1e-9 then
				p = p + pr
				local ing = math.max(0, math.min(1, c.ing or 0))
				nxt[r10] = (nxt[r10] or 0) + pr * (1 - ing)
				if ing > 0 then
					local k2 = r10 + key(c.refund or 0)
					nxt[k2] = (nxt[k2] or 0) + pr * ing
				end
			end
		end
		reach[k] = p
		if p < 1e-6 then for j = k + 1, #crafts do reach[j] = 0 end break end
		states, spent = nxt, spent + c.cost
	end
	return reach
end

-- Restock plans ----------------------------------------------------------------------------------
-- Compare plans (lists of queue entries) by what they cost up front, the gold that comes back in a
-- week, and the stock left. Each item's sales are drawn from its daily volume; prices move with one
-- market shock shared by every item plus each item's own, so related items don't all move apart.

D.SHARED = 0.6 -- how much of a price move is the market's (shared) rather than the item's own

--- What one queued craft makes and sells for, from the best saved scan that makes its item:
--- { item, items (per craft, Multicraft included), price, deposit, unit, daily } or nil.
function D.EntryModel(e)
	if not (e and e.item and CH.Queue and CH.Queue.ScanRowFor) then return nil end
	local _, _, row = CH.Queue.ScanRowFor(e.item)
	local acc = row and ((e.concentration and row.concAccounts) or row.accounts)
	local price = acc and acc.price or CH.Prices.Get("chvalue", "i:" .. e.item)
	if not price then return nil end
	local items = acc and ((acc.made or 1) + (acc.extraItems or 0)) or (row and row.made) or 1
	return { item = e.item, items = items, price = price, deposit = acc and acc.deposit or 0,
		unit = acc and acc.unit or price * CH.AH_CUT, daily = CH.Scan and CH.Scan.DailyUnits(e.item) or 0 }
end

--- Outcomes of a plan: { cash (to buy what you don't have, walking the listings), crafts, back = {
--- p10, p50, p90 } (gold from sales in `days`), left (median value of unsold stock), recover (chance
--- the week's sales cover the reagents' cost), unpriced (entries left out: no scan or price) }.
function D.Plan(entries, opts)
	opts = opts or {}
	local runs, days = opts.runs or 500, opts.days or D.HORIZON
	local fall = opts.price or D.Scenario().price
	local sd = fall / 1.2816
	local shop, cash = CH.Queue.ShoppingList(entries)
	local spend = 0
	for _, s in ipairs(shop) do spend = spend + (s.unit or 0) * s.need end
	local byItem, unpriced, crafts = {}, 0, 0
	for _, e in ipairs(entries) do
		local m = D.EntryModel(e)
		if m then
			local x = byItem[m.item] or { m = m, items = 0 }
			x.items = x.items + m.items * e.qty
			byItem[m.item] = x
			crafts = crafts + e.qty
		else
			unpriced = unpriced + 1
		end
	end
	local u = rng(opts.seed or 11)
	local backs, lefts, covered = {}, {}, 0
	for k = 1, runs do
		local market = normal(u)
		local back, left = 0, 0
		for _, x in pairs(byItem) do
			local z = D.SHARED * market + math.sqrt(1 - D.SHARED ^ 2) * normal(u)
			local shock = math.max(0.05, 1 + sd * z)
			local made = math.floor(x.items + u()) -- whole items, fractions drawn
			local sold = math.min(made, poisson(u, x.m.daily * days))
			back = back + sold * math.max(0, x.m.price * shock * CH.AH_CUT - x.m.deposit)
			left = left + (made - sold) * x.m.unit
		end
		if back >= spend then covered = covered + 1 end
		backs[k], lefts[k] = back, left
	end
	table.sort(backs); table.sort(lefts)
	return { cash = cash, spend = spend, crafts = crafts, unpriced = unpriced, recover = covered / runs,
		back = { p10 = quantile(backs, 0.1), p50 = quantile(backs, 0.5), p90 = quantile(backs, 0.9) }, left = quantile(lefts, 0.5) or 0 }
end

--- The plans worth comparing for the queue: as queued, and lean (each item up to `leanDays` days of
--- its sales, less what you hold). { { label, entries } }.
D.LEAN_DAYS = 3
function D.Plans(queue)
	queue = queue or CH.db.queue
	local lean, made = {}, {}
	for _, e in ipairs(queue) do
		local m = D.EntryModel(e)
		local copy = {}
		for k, v in pairs(e) do copy[k] = v end
		if m and m.items > 0 then
			local held = C_Item and C_Item.GetItemCount and C_Item.GetItemCount(e.item, true, false, true, true) or 0
			local want = math.max(0, m.daily * D.LEAN_DAYS - held - (made[e.item] or 0))
			copy.qty = math.min(e.qty, math.ceil(want / m.items))
			made[e.item] = (made[e.item] or 0) + copy.qty * m.items
		end
		if copy.qty > 0 then lean[#lean + 1] = copy end
	end
	return { { label = "As queued", entries = queue }, { label = string.format("Lean (%d days of sales)", D.LEAN_DAYS), entries = lean } }
end

-- Checking the batch forecasts -------------------------------------------------------------------
-- Each batch you queue saves what the simulation said about it; a week later the sales say what
-- happened. Over many batches that shows whether the simulation runs optimistic.

local function forecasts()
	CH.db.batchForecasts = CH.db.batchForecasts or {}
	return CH.db.batchForecasts
end
D.Forecasts = forecasts

--- Save a batch forecast: one size's outcome from D.Batch, for an item. Keeps the last 200.
function D.SaveForecast(item, recipeID, s, now)
	if not (item and s and s.cashBack) then return nil end
	local list = forecasts()
	local f = { at = now or time(), item = item, recipe = recipeID, n = s.n, p10 = s.cashBack.p10, p50 = s.cashBack.p50,
		p90 = s.cashBack.p90, recover = s.recover, spend = s.spend }
	list[#list + 1] = f
	while #list > 200 do table.remove(list, 1) end
	return f
end

--- How the saved forecasts held up, for those a full horizon old: what the item really brought in
--- over the days after each (your sales after the cut) against the forecast range. { checked, inside
--- (within the middle 80%), under (below the median), over } or nil before any can be checked.
function D.Calibration(now)
	now = now or time()
	if not (CH.Ledger and CH.Ledger.Available()) then return nil end
	local sales = CH.Ledger.Records("Sales")
	local out = { checked = 0, inside = 0, under = 0, over = 0 }
	for _, f in ipairs(forecasts()) do
		local to = f.at + D.HORIZON * 86400
		if to <= now then
			local got = 0
			for _, s in ipairs(sales) do
				if s.id == f.item and s.time >= f.at and s.time < to then got = got + CH.Ledger.Net(s) end
			end
			out.checked = out.checked + 1
			if got >= (f.p10 or 0) and got <= (f.p90 or math.huge) then out.inside = out.inside + 1 end
			if got < (f.p50 or 0) then out.under = out.under + 1 else out.over = out.over + 1 end
		end
	end
	return out.checked > 0 and out or nil
end
