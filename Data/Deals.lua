-- Deals: listings well under what the item resells for, to buy and relist.
--
-- From every item the AH has shown (Scans.lua: your searches, AuctionIQ's and TSM's full scans):
--
--   resale  what one is worth to relist: the lower of TSM's realm market value and the price
--           AuctionIQ would post at (chpost), not chvalue, which follows the cheapest listing and
--           so would call any cheap listing fair
--   each    resale after the cut, the deposits you expect to lose to expiries and the gold tied up
--           while it waits (Expect.Value): what one bought now brings back
--   buy     the cheapest listings, as the scan saw them: for a commodity its buying ladder, as many
--           units as stay under each / (1 + MIN_ROI); otherwise the one cheapest listing
--   units   no more than a week of sales (Demand.Estimate, your record blended with the region's)
--           less what you hold and have listed: a deal you can't sell isn't one
--
-- A deal is a return of at least MIN_ROI on what it costs and at least MIN_GAIN gold. Listings
-- move fast, so a scan older than FRESH says to search it again before buying.
local _, CH = ...

local Dl = { MIN_ROI = 0.3, MIN_GAIN = 100000, FRESH = 1800, MAX_AGE = 6 * 3600, COVER_DAYS = 7, MAX = 50 }
CH.Deals = Dl

-- the price to relist at: the lower of the realm's market value and what AuctionIQ would post at
local function resale(id)
	local P = CH.Prices
	local post = P.Get("chpost", "i:" .. id)
	local market = P.Get("dbmarket", "i:" .. id)
	if post and market then return math.min(post, market) end
	return post or market
end
Dl.Resale = resale

-- How many to buy from a ladder ({ { qty, avg } }, each point the average to buy that many) while
-- each extra unit costs at most `max`: units and their total cost.
local function fromLadder(points, max)
	local n, spent = 0, 0
	local pq, pc = 0, 0
	for _, p in ipairs(points) do
		local q, total = p[1], p[1] * p[2]
		local marginal = (total - pc) / math.max(1, q - pq)
		if marginal > max then break end
		n, spent, pq, pc = q, total, q, total
	end
	return n, spent
end
Dl.FromLadder = fromLadder

--- One item as a deal, or nil with why not: { id, buy (units), cost, unit (average), each (what
--- one brings back), resale, gain, roi, age, stale, commodity, demand (Demand.Estimate), held }.
function Dl.Evaluate(id, now)
	now = now or time()
	local min, at = CH.Scans.Cheapest(id)
	if not (min and min > 0) then return nil, "no scan" end
	local age = now - at
	if age > Dl.MAX_AGE then return nil, "scan too old" end
	local r = resale(id)
	if not r then return nil, "no resale price" end
	-- the cheapest listing can't be a deal: skip the rest of the work
	local gross = r * CH.AH_CUT
	if min * (1 + Dl.MIN_ROI) > gross then return nil, "not under value" end
	local each = CH.Expect and CH.Expect.Value(id, r) or gross
	if not each or each <= 0 then return nil, "no value after deposits" end
	local max = each / (1 + Dl.MIN_ROI)
	if min > max then return nil, "not under value after deposits" end
	-- a week of sales, less what you hold and have up
	local d = CH.Demand and CH.Demand.Estimate(id, now)
	if not (d and d.units and d.units > 0) then return nil, "no sales rate" end
	local held = CH.Par and CH.Par.Held(id) or 0
	local up = CH.Auction and CH.Auction.Listed and CH.Auction.Listed(id) or 0
	local room = math.ceil(d.units * Dl.COVER_DAYS) - held - up
	if room <= 0 then return nil, "you hold a week's sales" end
	local points = CH.Scans.Depth(id)
	local n, cost
	if points then
		n, cost = fromLadder(points, max)
		if n > room then n, cost = room, nil end
		if not cost then
			-- priced on the ladder up to the cap: the average for that many
			local c = CH.Depth and CH.Depth.Cost(id, n)
			cost = c and c.cost or min * n
		end
	else
		n, cost = 1, min
	end
	if n <= 0 then return nil, "not under value" end
	local gain = each * n - cost
	if gain < Dl.MIN_GAIN then return nil, "gain too small" end
	return { id = id, buy = n, cost = cost, unit = cost / n, each = each, resale = r, gain = gain, roi = gain / cost,
		age = age, stale = age > Dl.FRESH, commodity = points ~= nil, demand = d, held = held, up = up }
end

-- the last list, kept until the scans change (Scans.version) or a minute passes
local last, lastVersion, lastAt
local function fresh(now) return last and lastVersion == (CH.Scans.version or 0) and now - lastAt < 60 end

--- Working the deals out as steps: job.step(budgetMs) does up to that many milliseconds (all of it
--- without a budget) and returns the list once done, else nil. After a full scan the AH has shown
--- tens of thousands of items, each a few price lookups: too much for one frame.
function Dl.Job(now)
	now = now or time()
	local v = CH.Scans.version or 0
	local ids, i, out = CH.Scans.Items(), 1, {}
	-- each item's sell chance reads your sell-through stats: build them in steps first, if TSM's
	-- records changed since they were last built, rather than in the first item's frame
	local L = CH.Ledger
	local stats = L and L.Available() and L.StatsJob and L.StatsJob() or nil
	local job = {}
	function job.step(budget)
		if fresh(now) then return last end
		local clock = budget and debugprofilestop
		local t0 = clock and clock()
		if stats then
			local left = t0 and math.max(0.01, budget - (clock() - t0)) or nil
			local ok, built = pcall(stats.step, left)
			if ok and not built then return nil end
			stats = nil
		end
		while i <= #ids do
			local ok, d = pcall(Dl.Evaluate, ids[i], now)
			if ok and d then out[#out + 1] = d end
			i = i + 1
			if t0 and i % 32 == 0 and clock() - t0 >= budget then return nil end
		end
		table.sort(out, function(a, b) return a.gain > b.gain end)
		for k = #out, Dl.MAX + 1, -1 do out[k] = nil end
		last, lastVersion, lastAt = out, v, now
		return out
	end
	return job
end

--- Every deal, biggest gain first (at most MAX). Kept a minute while no scan is added.
function Dl.List(now)
	now = now or time()
	if fresh(now) then return last end
	return Dl.Job(now).step()
end

local running
--- The last list worked out (nil before the first), starting a new one in the background when it's
--- out of date: for the Dashboard, which shouldn't stall on it.
function Dl.Cached(now)
	now = now or time()
	if fresh(now) or running or not C_Timer then return last end
	local job = Dl.Job(now)
	running = true
	local function tick()
		local ok, done = pcall(job.step, (CH.Ledger and CH.Ledger.FRAME_MS) or 4)
		if ok and not done then C_Timer.After(0, tick) else running = false end
	end
	C_Timer.After(0, tick)
	return last
end

function Dl.Clear() last = nil; running = false end

--- One deal as a line: "Item: buy 20 at 12g (each brings 18g back), +120g, 50%, scanned 5 min ago".
function Dl.Line(d)
	local M = CH.FormatMoney
	local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(d.id) or ("item " .. d.id)
	return string.format("%s: buy %d at %s (each brings %s back), %s, %d%%, scanned %s ago%s", name, d.buy, M(d.unit), M(d.each),
		"+" .. M(d.gain), math.floor(d.roi * 100 + 0.5), CH.Scans.Age(d.age), d.stale and ": search it again first" or "")
end

--- /aiq deals: the top ten in chat, worked out a few milliseconds a frame first.
function Dl.Print(list)
	if not list and C_Timer then
		local job = Dl.Job()
		local function tick()
			local ok, done = pcall(job.step, (CH.Ledger and CH.Ledger.FRAME_MS) or 4)
			if not ok then CH.Print("deals: " .. tostring(done)) elseif done then Dl.Print(done) else C_Timer.After(0, tick) end
		end
		tick()
		return
	end
	list = list or Dl.List()
	if #list == 0 then
		CH.Print(string.format("no deals in what the AH has shown in the last %d hours (a %d%% return and %s at least, within a week of sales)",
			Dl.MAX_AGE / 3600, Dl.MIN_ROI * 100, CH.FormatMoney(Dl.MIN_GAIN)))
		return
	end
	CH.Print(string.format("%d deals, biggest first:", #list))
	for i, d in ipairs(list) do
		if i > 10 then break end
		CH.Print("  " .. Dl.Line(d))
	end
end
