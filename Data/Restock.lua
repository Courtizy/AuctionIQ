-- Restock by timing: how many to make now, given when you'll next be back to craft or post.
--
-- The week-long suggestion (Decide.Suggest) asks "what pays and sells within a week?". This asks a
-- narrower question: you'll be back in H days, so what you make now only has to last until then.
--
--   H         days to your next session: the typical gap between your past sessions (craft batches
--             and AH visits from the logs, a new session after SESSION_BREAK of quiet; the median
--             of the gaps over the last WINDOW days, once there are MIN_GAPS of them), or the days
--             you set in Settings (0 = learn), else DEFAULT_DAYS
--   demand    units sold over H: Demand.Estimate's Gamma(shape, rate) belief about the daily rate,
--             so over H days a Negative Binomial with r = shape and p = rate / (rate + H)
--   one more  the k-th unit you stock sells by then with chance P(D >= k) and earns its price after
--   sale      the cut and deposits; if it doesn't, it waits for the next session and costs
--   leftover  h = value x (carry + price decline a day) x H: the gold tied up (Settings) and the
--             price falling meanwhile (the item's scanned trend when it is falling, else nothing)
--   batch     the number of crafts, 0 to SEARCH_MAX, with the most expected profit: sales gained,
--             plus each unit left valued at what one costs to make (it saves making one next time)
--             less h, less what the reagents cost (walking the order book, so they get dearer as you
--             buy more). The same as stocking to the point where
--             P(D >= k) = h / (margin + h), but with real reagent costs.
-- It is optional: shown beside the week's suggestion, never instead of it.
local _, AuctionIQ = ...

local Rs = { SESSION_BREAK = 2 * 3600, WINDOW = 30, MIN_GAPS = 3, DEFAULT_DAYS = 2, MIN_DAYS = 0.25, MAX_DAYS = 14,
	SEARCH_MAX = 200 }
AuctionIQ.Restock = Rs

local DAY = 86400

--- Session start times over the last WINDOW days, ascending: craft batches and AH visits (the
--- availability readings), with a new session after SESSION_BREAK seconds of quiet.
function Rs.Sessions(now)
	now = now or time()
	local from = now - Rs.WINDOW * DAY
	local t = {}
	for _, b in ipairs(AuctionIQ.Forecast and AuctionIQ.Forecast.Store() or {}) do
		if b.at and b.at >= from and b.at <= now then t[#t + 1] = b.at end
	end
	for _, mine in pairs(AuctionIQ.db and AuctionIQ.db.avail or {}) do
		for _, list in pairs(mine) do
			for _, r in ipairs(list) do
				if r[1] >= from and r[1] <= now then t[#t + 1] = r[1] end
			end
		end
	end
	table.sort(t)
	local starts, last = {}, nil
	for _, x in ipairs(t) do
		if not last or x - last > Rs.SESSION_BREAK then starts[#starts + 1] = x end
		last = x
	end
	return starts
end

--- Days to your next session, and where it comes from: (days, "set" | "learned" | "default", gaps).
function Rs.Days(now)
	local set = AuctionIQ.Expect and AuctionIQ.Expect.Setting("session") or 0
	if set and set > 0 then return set, "set", 0 end
	local s = Rs.Sessions(now)
	local gaps = {}
	for i = 2, #s do gaps[#gaps + 1] = s[i] - s[i - 1] end
	if #gaps < Rs.MIN_GAPS then return Rs.DEFAULT_DAYS, "default", #gaps end
	table.sort(gaps)
	local m = #gaps % 2 == 1 and gaps[(#gaps + 1) / 2] or (gaps[#gaps / 2] + gaps[#gaps / 2 + 1]) / 2
	return math.max(Rs.MIN_DAYS, math.min(Rs.MAX_DAYS, m / DAY)), "learned", #gaps
end

--- The chance of selling at least k units over `days`: { tail = { [k] = P(D >= k) for k = 1..max },
--- mean, low, high (80%) }. From the demand estimate's Gamma belief (shape, rate) when it has one,
--- else a Poisson at its rate. nil without a rate.
function Rs.Demand(e, days, max)
	if not (e and e.units and e.units > 0 and days and days > 0) then return nil end
	max = max or 1000
	local shape, rate = e.shape, e.rate
	local pmf -- pmf(k) from pmf(k - 1)
	local p0
	if shape and rate and shape > 0 and rate > 0 then
		local p = rate / (rate + days)
		local lp0 = shape * math.log(p)
		if lp0 < -700 then shape = nil else
			p0 = math.exp(lp0)
			pmf = function(k, prev) return prev * (k - 1 + shape) / k * (1 - p) end
		end
	end
	if not pmf then
		local mean = e.units * days
		if mean > 700 then mean = 700 end
		p0 = math.exp(-mean)
		pmf = function(k, prev) return prev * mean / k end
	end
	local tail, cdf, prob = {}, p0, p0
	local low, high
	local mean = 0
	for k = 1, max do
		tail[k] = math.max(0, 1 - cdf)
		if not low and cdf >= 0.1 then low = k - 1 end
		if not high and cdf >= 0.9 then high = k - 1 end
		prob = pmf(k, prob)
		cdf = cdf + prob
		mean = mean + tail[k]
		if tail[k] < 1e-6 then
			for j = k + 1, max do tail[j] = 0 end
			break
		end
	end
	return { tail = tail, mean = mean, low = low or 0, high = high or max, max = max }
end

-- E[min(D, s)] for a stock s (fractional s interpolates between whole units)
local function sold(d, s)
	if s <= 0 then return 0 end
	local whole = math.floor(s)
	local sum = 0
	for k = 1, math.min(whole, d.max) do sum = sum + d.tail[k] end
	local frac = s - whole
	if frac > 0 and whole + 1 <= d.max then sum = sum + frac * d.tail[whole + 1] end
	return sum
end
Rs.Sold = sold

--- How fast the item's price is falling, a share a day (0 when it isn't, or there's no scanned trend).
function Rs.Decline(id, now)
	local Mk = AuctionIQ.Market
	if not (id and Mk and Mk.Item) then return 0 end
	local ok, x = pcall(Mk.Item, id, now)
	if not (ok and x and x.trend and x.trendFrom == "scans" and x.trend < 0) then return 0 end
	return 1 - (1 + x.trend) ^ (1 / 7)
end

--- The batch for your next session. inp: Decide.BatchInputs (or ScanInputs). opts: held (items of
--- it you have), days (else Rs.Days), demand (a Demand.Estimate, else the item's), decline (a share
--- a day, else Rs.Decline), cap (crafts at most, e.g. what Concentration covers), now.
--- Returns { n, days, from ("set" | "learned" | "default"), gaps, held, demand = { mean, low, high },
--- items (made), sold (of them, expected, by then), left, profit (expected, against making none),
--- cost, hold (leftover cost a unit), each (a unit sold, after cut and deposit), ratio (the chance
--- of a sale at which one more stops paying), text } or nil without a price or a sales rate.
function Rs.Plan(inp, opts)
	opts = opts or {}
	if not (inp and inp.price and inp.price > 0) then return nil end
	local D = AuctionIQ.Decide
	local days, from, gaps = opts.days, "given", 0
	if not days then days, from, gaps = Rs.Days(opts.now) end
	local e = opts.demand or (inp.evidence and inp.evidence.demand) or (inp.item and AuctionIQ.Demand and AuctionIQ.Demand.Estimate(inp.item, opts.now))
	local held = opts.held or (inp.item and inp.have and inp.have(inp.item)) or 0
	local perCraft = D.ItemsPerCraft(inp)
	local cap = math.min(Rs.SEARCH_MAX, opts.cap or Rs.SEARCH_MAX)
	local d = Rs.Demand(e, days, math.ceil(held + cap * perCraft) + 1)
	if not d then return nil end
	local each = math.max(0, inp.price * AuctionIQ.AH_CUT - (inp.deposit or 0))
	local carry = AuctionIQ.Expect and AuctionIQ.Expect.Setting("carry") or 0.01
	local decline = opts.decline or Rs.Decline(inp.item, opts.now)
	local hold = each * (carry + decline) * days
	local base = sold(d, held)
	-- a unit left over isn't lost: it saves making one next session, so it's worth what one costs to
	-- make (at the cheapest, one craft's reagents) less what holding it until then costs
	local unitCost = perCraft > 0 and (D.BatchCost(inp, 1) - (inp.res or 0) * (inp.saved or 0)) / perCraft or 0
	local best = { n = 0, profit = 0, items = 0, sold = 0, left = 0, cost = 0 }
	local worse = 0
	for n = 1, cap do
		local items = n * perCraft
		local gain = sold(d, held + items) - base
		local spend = D.BatchCost(inp, n)
		local cost = spend - n * (inp.res or 0) * (inp.saved or 0)
		local profit = each * gain + (unitCost - hold) * (items - gain) - cost
		if profit > best.profit then
			best = { n = n, profit = profit, items = items, sold = gain, left = items - gain, cost = cost }
			worse = 0
		else
			-- profit only falls once each unit's chance of selling is below the ratio: stop looking soon after
			worse = worse + 1
			if worse >= 10 and d.tail[math.max(1, math.floor(held + items))] < 0.01 then break end
		end
	end
	local margin = each - unitCost
	local out = { n = best.n, days = days, from = from, gaps = gaps, held = held, profit = best.profit, items = best.items,
		sold = best.sold, left = best.left, cost = best.cost, each = each, hold = hold, decline = decline,
		ratio = (margin > 0 and hold + margin > 0) and hold / (margin + hold) or nil,
		demand = { mean = d.mean, low = d.low, high = d.high } }
	out.text = Rs.Text(out)
	return out
end

local function daysText(x)
	if x < 1 then return string.format("%d hours", math.floor(x * 24 + 0.5)) end
	if x % 1 == 0 then return string.format("%d day%s", x, x == 1 and "" or "s") end
	return string.format("%.1f days", x)
end
Rs.DaysText = daysText

--- "Make 6 before your next session in about 2 days (your usual gap): 3 to 9 likely sell by then,
--- 1.2 of them likely left over."
function Rs.Text(p)
	if not p then return nil end
	local whence = p.from == "set" and "your setting" or p.from == "learned" and "your usual gap" or p.from == "default" and "not enough sessions yet to learn it" or nil
	local when = string.format("in about %s%s", daysText(p.days), whence and (" (" .. whence .. ")") or "")
	local likely = string.format("%d to %d likely sell by then", p.demand.low, p.demand.high)
	if p.n == 0 then
		if p.held > 0 then return string.format("Make none: your %d should last until your next session %s; %s.", p.held, when, likely) end
		return string.format("Make none for your next session %s: it doesn't pay at the chance it sells by then.", when)
	end
	return string.format("Make %d before your next session %s: %s, about %s of the new ones left over.", p.n, when, likely,
		p.left >= 10 and string.format("%.0f", p.left) or string.format("%.1f", p.left))
end
