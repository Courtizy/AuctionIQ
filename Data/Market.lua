-- Market: trend, volatility and liquidity for each item in your groups, and for each group.
--
--   trend       how fast the price moves, per week: a straight line through the log of the daily
--               market price the AH showed you (Scans.lua, the last 30 days), so +10% means the
--               line rises 10% a week. It needs MIN_DAYS days scanned; until then it is TSM's
--               realm market against its 60-day historical price, which says where the price is,
--               not how fast it moves, and is shown as "vs 60 days".
--   volatility  how far the price moves from one scanned day to the next: the standard deviation
--               of the daily log changes (a two-day gap counts as two days' moves). Needs
--               MIN_DAYS days scanned.
--   liquidity   how much sells: units a day (Demand.Estimate: your record blended with the
--               region's), the region's sale rate (the share of listings that sell), gold a day
--               (units at the price) and how many days what you hold and have up lasts.
--
-- A group's trend and volatility weigh its items by the gold a day they sell for, so a few
-- big sellers count for more than many small ones; its days to sell is the gold held over the
-- gold a day.
local _, CH = ...

local Mk = { MIN_DAYS = 5, FIT_DAYS = 30, RISING = 0.05, CHOPPY = 0.12, THIN = 0.2 }
CH.Market = Mk

local function price(id)
	local P = CH.Prices
	local s = CH.Scans and CH.Scans.Get(id)
	return (s and (s.market or s.min)) or P.Get("dbmarket", "i:" .. id) or P.Get("dbregionmarketavg", "i:" .. id)
end

--- Trend (per week) and volatility (per day) from daily points { { day, price } }: trend, vol, n.
--- nil for either when there are fewer than MIN_DAYS points.
function Mk.Fit(points)
	local n = points and #points or 0
	if n < Mk.MIN_DAYS then return nil, nil, n end
	local sx, sy, sxx, sxy = 0, 0, 0, 0
	local x0 = points[1][1]
	for _, p in ipairs(points) do
		local x, y = p[1] - x0, math.log(math.max(1, p[2]))
		sx, sy, sxx, sxy = sx + x, sy + y, sxx + x * x, sxy + x * y
	end
	local den = n * sxx - sx * sx
	local trend = den > 0 and math.exp(7 * (n * sxy - sx * sy) / den) - 1 or nil
	-- daily changes, each scaled to one day: a move over a two-day gap is two days' worth
	local sum, sum2, k = 0, 0, 0
	for i = 2, n do
		local gap = points[i][1] - points[i - 1][1]
		if gap > 0 then
			local r = math.log(math.max(1, points[i][2]) / math.max(1, points[i - 1][2])) / math.sqrt(gap)
			sum, sum2, k = sum + r, sum2 + r * r, k + 1
		end
	end
	local vol = k >= 2 and math.sqrt(math.max(0, (sum2 - sum * sum / k) / (k - 1))) or nil
	return trend, vol, n
end

--- One word for an item or group: "thin" (under THIN a day sells), "choppy" (moves CHOPPY a day
--- or more), "rising" or "falling" (RISING a week or more), else "steady"; "no data" without a price.
function Mk.Read(x)
	if not x or not x.price then return "no data" end
	if (x.units or 0) < Mk.THIN then return "thin" end
	if x.vol and x.vol >= Mk.CHOPPY then return "choppy" end
	if x.trend and x.trendFrom == "scans" then
		if x.trend >= Mk.RISING then return "rising" end
		if x.trend <= -Mk.RISING then return "falling" end
	end
	return "steady"
end

--- An item's market: { id, price, points (daily, oldest first: your scans and, with the companion's
--- history, the months before), trend, trendFrom ("scans" per week, "tsm" vs 60 days), vol, days
--- (days in the last FIT_DAYS the trend and volatility use), span (days the points cover), hi, lo,
--- change90 (the price now against the nearest day 90 or more days back), units, demand, region,
--- saleRate, goldDay, held, up, daysToSell, read }.
function Mk.Item(id, now, listed)
	now = now or time()
	local P = CH.Prices
	local x = { id = id, price = price(id) }
	local points = (CH.History and CH.History.Series or CH.Scans.Daily)(id) or {}
	x.points = points
	-- trend and volatility from the last FIT_DAYS: what the price does now, not months ago
	local today, recent = math.floor(now / 86400), points
	if points[1] and points[1][1] <= today - Mk.FIT_DAYS then
		recent = {}
		for _, p in ipairs(points) do if p[1] > today - Mk.FIT_DAYS then recent[#recent + 1] = p end end
	end
	x.trend, x.vol, x.days = Mk.Fit(recent)
	if points[1] then
		x.span = points[#points][1] - points[1][1] + 1
		local hi, lo, back = 0, math.huge, nil
		for _, p in ipairs(points) do
			hi, lo = math.max(hi, p[2]), math.min(lo, p[2])
			if p[1] <= today - 90 then back = p end
		end
		x.hi, x.lo = hi, lo
		local last = points[#points][2]
		if back and back[2] > 0 then x.change90 = last / back[2] - 1 end
	end
	if x.trend then
		x.trendFrom = "scans"
	else
		local mkt, hist = P.Get("dbmarket", "i:" .. id), P.Get("dbhistorical", "i:" .. id)
		if mkt and hist and hist > 0 then x.trend, x.trendFrom = mkt / hist - 1, "tsm" end
	end
	local d = CH.Demand and CH.Demand.Estimate(id, now)
	x.demand = d
	x.units = d and d.units or 0
	x.region = d and d.region
	x.saleRate = P.Raw and P.Raw("dbregionsalerate", id) or nil
	x.goldDay = x.price and x.units * x.price or 0
	x.held = CH.Par and CH.Par.Held and CH.Par.Held(id) or 0
	x.up = listed and (listed[id] or 0) or CH.Auction and CH.Auction.Listed and CH.Auction.Listed(id) or 0
	local have = x.held + x.up
	x.daysToSell = have > 0 and (x.units > 0 and have / x.units or math.huge) or nil
	x.read = Mk.Read(x)
	return x
end

-- The items worth a line: grouped and either scanned at the AH (or in the companion's history) or
-- held or up. TSM's groups can hold tens of thousands of items with nothing to chart and nothing at
-- risk: walking them all stalled the game, so this starts from what's scanned, held and up (a few
-- thousand at most) and keeps the grouped ones.
local function candidates(listed)
	local ids, seen = {}, {}
	local function add(id) if type(id) == "number" and not seen[id] then seen[id] = true; ids[#ids + 1] = id end end
	for _, id in ipairs(CH.Scans.Items()) do add(id) end
	local hd = type(AuctionIQ_HistoryData) == "table" and AuctionIQ_HistoryData.items
	if type(hd) == "table" then for id in pairs(hd) do add(id) end end
	for id, n in pairs(listed) do if n > 0 then add(id) end end
	local held = CH.Par and CH.Par.HeldAll and CH.Par.HeldAll()
	if held then
		for id, n in pairs(held) do if n > 0 then add(id) end end
	elseif CH.Par and CH.Par.Held then
		-- no TSM counts: what's in reach now, for the grouped items (the old way, slower)
		for key in pairs(CH.Groups.Members()) do if type(key) == "number" and CH.Par.Held(key) > 0 then add(key) end end
	end
	return ids
end

-- the last list, kept a minute while no scan is added (a view redraws on every scroll)
local last, lastVersion, lastAt
local function fresh(now)
	return last and lastVersion == (CH.Scans and CH.Scans.version or 0) and now - lastAt >= 0 and now - lastAt < 60
end

--- Working the list out as steps: job.step(budgetMs) does up to that many milliseconds (all of it
--- without a budget) and returns the list once done, else nil.
function Mk.Job(now)
	now = now or time()
	local v = CH.Scans and CH.Scans.version or 0
	local job, keys, listed, heldDone, i, out = {}, nil, nil, false, 1, {}
	function job.step(budget)
		if fresh(now) then return last end
		local clock = budget and debugprofilestop
		local t0 = clock and clock()
		-- what's up, what's held (pricing your inventory), then what's scanned: each its own frame
		if not listed then
			listed = CH.Auction and CH.Auction.ListedAll and CH.Auction.ListedAll() or {}
			if t0 then return nil end
		end
		if not heldDone then
			heldDone = true
			if CH.Par and CH.Par.HeldAll then CH.Par.HeldAll() end
			if t0 then return nil end
		end
		if not keys then
			keys = candidates(listed)
			-- the first group lookup reads TSM's groups (tens of thousands): its own frame too
			if CH.Groups and CH.Groups.Path then CH.Groups.Path(0) end
			if t0 then return nil end
		end
		local G = CH.Groups
		while i <= #keys do
			local id = keys[i]
			local path = G and G.Path and G.Path(id)
			if path then
				local x = Mk.Item(id, now, listed)
				if x.price then x.path = path; out[#out + 1] = x end
			end
			i = i + 1
			if t0 and i % 8 == 0 and clock() - t0 >= budget then return nil end
		end
		table.sort(out, function(a, b) if a.goldDay ~= b.goldDay then return a.goldDay > b.goldDay end return a.id < b.id end)
		last, lastVersion, lastAt = out, v, now
		return out
	end
	return job
end

--- Every item in your groups that you've scanned, hold or have up, with a price: { Mk.Item + path },
--- biggest gold a day first. Kept a minute while no scan is added. All at once: the views use Cached.
function Mk.Items(now)
	now = now or time()
	if fresh(now) then return last end
	return Mk.Job(now).step()
end

local running
--- The last list (nil before the first), working a new one out a few milliseconds a frame when it's
--- out of date, then redrawing the window: for the views, which mustn't stall the game.
function Mk.Cached(now)
	now = now or time()
	if fresh(now) or running or not C_Timer then return last, running end
	local job = Mk.Job(now)
	running = true
	local function tick()
		local ok, done = pcall(job.step, (CH.Ledger and CH.Ledger.FRAME_MS) or 4)
		if ok and not done then C_Timer.After(0, tick); return end
		running = false
		if CH.UI and CH.UI.IsShown and CH.UI.IsShown() and CH.UI.Refresh then CH.UI.Refresh() end
	end
	C_Timer.After(0, tick)
	return last, running
end

function Mk.Clear() last = nil; running = false end

--- Each group (sub-groups count in their parents) from items (Mk.Items): { path, name, depth, n,
--- goldDay, trend, vol, heldValue, daysToSell, items (biggest first), read }.
function Mk.Groups(items)
	local sep = CH.Groups and CH.Groups.SEP or "/"
	local by = {}
	for _, x in ipairs(items) do
		local acc = ""
		for part in string.gmatch(x.path or "", "[^" .. sep .. "]+") do
			acc = acc == "" and part or (acc .. sep .. part)
			local g = by[acc]
			if not g then
				local _, depth = acc:gsub(sep, "")
				g = { path = acc, name = part, depth = depth, n = 0, goldDay = 0, units = 0, heldValue = 0, tw = 0, tsum = 0, vw = 0, vsum = 0, items = {} }
				by[acc] = g
			end
			g.n, g.goldDay, g.units = g.n + 1, g.goldDay + x.goldDay, g.units + x.units
			g.heldValue = g.heldValue + (x.held + x.up) * x.price
			-- weigh by gold a day, at least a copper, so a group of items that don't sell still gets a figure
			local w = math.max(1, x.goldDay)
			if x.trend and x.trendFrom == "scans" then g.tw, g.tsum = g.tw + w, g.tsum + w * x.trend end
			if x.vol then g.vw, g.vsum = g.vw + w, g.vsum + w * x.vol end
			g.items[#g.items + 1] = x
		end
	end
	local out = {}
	for _, g in pairs(by) do
		g.trend = g.tw > 0 and g.tsum / g.tw or nil
		g.trendFrom = g.trend and "scans" or nil
		g.vol = g.vw > 0 and g.vsum / g.vw or nil
		g.daysToSell = g.heldValue > 0 and (g.goldDay > 0 and g.heldValue / g.goldDay or math.huge) or nil
		g.read = Mk.Read({ price = true, units = g.units, vol = g.vol, trend = g.trend, trendFrom = g.trendFrom })
		g.tw, g.tsum, g.vw, g.vsum = nil, nil, nil, nil
		out[#out + 1] = g
	end
	table.sort(out, function(a, b) return a.path < b.path end)
	return out
end

-- Risk ---------------------------------------------------------------------------------------
-- How far an item's price could fall while you sell what you hold: at CONF (95%) of the time the
-- price after h days stays above price * exp(-z * vol * sqrt(h)), z the normal quantile, h the days
-- it takes to sell what you hold and have up (at least 1, at most RISK_DAYS). Stock exposed is
-- what you hold and have up at today's price, and at risk its loss at that downside. An item with
-- too few days scanned for a volatility of its own takes the middle one of your items that have one.
Mk.CONF, Mk.RISK_DAYS = 0.95, 30

--- The middle volatility of items (Mk.Item list), or nil when none has one.
function Mk.TypicalVol(items)
	local v = {}
	for _, x in ipairs(items) do if x.vol then v[#v + 1] = x.vol end end
	if not v[1] then return nil end
	table.sort(v)
	local m = (#v + 1) / 2
	return (v[math.floor(m)] + v[math.ceil(m)]) / 2
end

--- An item's risk (x from Mk.Item): { horizon, vol, assumed, downside (price), exposed, atRisk }.
--- typical stands in for an item without a volatility of its own.
function Mk.Risk(x, typical)
	local have = (x.held or 0) + (x.up or 0)
	local vol, assumed = x.vol, false
	if not vol then vol, assumed = typical, typical ~= nil end
	local h = math.max(1, math.min(Mk.RISK_DAYS, x.daysToSell or Mk.RISK_DAYS))
	local z = CH.Prob and CH.Prob.NormInv and CH.Prob.NormInv(Mk.CONF) or 1.6449
	local exposed = have * (x.price or 0)
	local r = { horizon = h, vol = vol, assumed = assumed, exposed = exposed }
	if vol and x.price then
		r.downside = x.price * math.exp(-z * vol * math.sqrt(h))
		r.atRisk = have * (x.price - r.downside)
	end
	return r
end

-- Formatting, shared by the views ------------------------------------------------------------
function Mk.TrendText(x)
	local T = CH.Theme
	if not x.trend then return T.Color("muted", "-") end
	local pct = math.floor(x.trend * 100 + 0.5)
	local c = x.trend >= Mk.RISING and "ok" or x.trend <= -Mk.RISING and "bad" or "fg"
	return T.Color(c, string.format("%+d%%", pct)) .. T.Color("muted", x.trendFrom == "tsm" and " vs 60d" or "/wk")
end

function Mk.VolText(x)
	local T = CH.Theme
	if not x.vol then return T.Color("muted", "-") end
	return T.Color(x.vol >= Mk.CHOPPY and "bad" or "fg", string.format("%.1f%%", x.vol * 100)) .. T.Color("muted", "/day")
end

function Mk.DaysText(days)
	local T = CH.Theme
	if not days then return T.Color("muted", "-") end
	if days == math.huge then return T.Color("bad", "never") end
	if days >= 100 then return T.Color("bad", string.format("%.0f", days)) end
	return T.Color(days > 30 and "bad" or days > 7 and "accent" or "ok", days >= 10 and string.format("%.0f", days) or string.format("%.1f", days))
end

Mk.READ_COLOR = { rising = "ok", falling = "bad", choppy = "bad", thin = "muted", steady = "fg", ["no data"] = "muted" }
function Mk.ReadText(x) return CH.Theme.Color(Mk.READ_COLOR[x.read] or "fg", x.read) end
