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

local Mk = { MIN_DAYS = 5, RISING = 0.05, CHOPPY = 0.12, THIN = 0.2 }
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

--- An item's market: { id, price, points (daily, oldest first), trend, trendFrom ("scans" per week,
--- "tsm" vs 60 days), vol, days, units, demand, region, saleRate, goldDay, held, up, daysToSell, read }.
function Mk.Item(id, now)
	now = now or time()
	local P = CH.Prices
	local x = { id = id, price = price(id) }
	local points = CH.Scans and CH.Scans.Daily and CH.Scans.Daily(id)
	x.points = points or {}
	x.trend, x.vol, x.days = Mk.Fit(points)
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
	x.up = CH.Auction and CH.Auction.Listed and CH.Auction.Listed(id) or 0
	local have = x.held + x.up
	x.daysToSell = have > 0 and (x.units > 0 and have / x.units or math.huge) or nil
	x.read = Mk.Read(x)
	return x
end

-- every grouped item (base ids) and its group
local function grouped()
	local out = {}
	local G = CH.Groups
	if not (G and G.Members) then return out end
	for key, path in pairs(G.Members()) do
		if type(key) == "number" and not out[key] then out[key] = path end
	end
	return out
end

-- the last list, kept a minute while no scan is added (a view redraws on every scroll)
local last, lastVersion, lastAt

--- Every item in your groups with a price: { Mk.Item + path }, biggest gold a day first. Kept a
--- minute while no scan is added.
function Mk.Items(now)
	now = now or time()
	local v = CH.Scans and CH.Scans.version or 0
	if last and lastVersion == v and now - lastAt >= 0 and now - lastAt < 60 then return last end
	local out = {}
	for id, path in pairs(grouped()) do
		local x = Mk.Item(id, now)
		if x.price then x.path = path; out[#out + 1] = x end
	end
	table.sort(out, function(a, b) if a.goldDay ~= b.goldDay then return a.goldDay > b.goldDay end return a.id < b.id end)
	last, lastVersion, lastAt = out, v, now
	return out
end

function Mk.Clear() last = nil end

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
