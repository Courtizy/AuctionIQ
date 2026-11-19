-- The order book: what buying a quantity of a reagent really costs. The cheapest listing only
-- covers its own stack, so a big buy walks up the book:
--   cost(q) = sum over listings i of min(q_i, q - Q_(i-1)) * p_i      (Q_i = units in listings 1..i)
-- Listings come from the AH when you've searched the item there in the last 15 minutes, else
-- from the last full AH search AuctionIQ saved for it (Scans.lua), else the cost is aiqbuy x quantity.
local _, AuctionIQ = ...

local D = { LIVE_SECONDS = 15 * 60, SCAN_CAP = 25000 }
AuctionIQ.Depth = D

local live = {} -- [id] = { at = time(), rows = { { price, qty } } } from AH searches

--- Keep an AH search's listings (from Auction.Results). Your own listings are left out.
function D.Remember(id, results)
	if not id or type(results) ~= "table" then return end
	local rows = {}
	for _, r in ipairs(results) do
		if r.price and (r.qty or 0) > 0 and not r.mine then rows[#rows + 1] = { r.price, r.qty } end
	end
	table.sort(rows, function(a, b) return a[1] < b[1] end)
	live[id] = { at = time(), rows = rows }
end

function D.Forget(id) if id then live[id] = nil else live = {} end end

-- Walk exact listings. Returns cost of what they fill and how many units they fill.
local function walk(rows, q)
	local got, spent = 0, 0
	for _, r in ipairs(rows) do
		local take = math.min(r[2], q - got)
		got, spent = got + take, spent + take * r[1]
		if got >= q then break end
	end
	return spent, got
end

-- A saved scan's ladder holds (qty, average price) points; cost between points is a straight line,
-- which is never below the real walk because the real cost curve bends upward.
local function ladder(points, q)
	local pq, pc = 0, 0
	for _, pt in ipairs(points) do
		local cq, cc = pt[1], pt[1] * pt[2]
		if q <= cq then return pc + (cc - pc) * (q - pq) / (cq - pq), q end
		pq, pc = cq, cc
	end
	return pc, pq
end

--- Listings to price an item from: rows, source ("ah" or "scan") and their age in seconds.
function D.Book(id)
	local l = live[id]
	if l and time() - l.at <= D.LIVE_SECONDS and l.rows[1] then return l.rows, "ah", time() - l.at end
	local pts, at = AuctionIQ.Scans.Depth(id)
	if pts then return pts, "scan", time() - at end
	return nil
end

--- What buying q of an item costs, in copper, and how it was worked out:
--- { cost, unit (average), source = "ah" | "scan" | "aiqbuy", short = units the book can't fill,
---   first = cheapest unit price, age }. Units past the book are priced at its last price.
--- nil when there is nothing to price it with.
function D.Cost(id, q)
	q = math.floor(q or 0)
	if not id or q <= 0 then return nil end
	local rows, source, age = D.Book(id)
	local aiqbuy = AuctionIQ.Prices.Get("aiqbuy", "i:" .. id)
	if not rows then
		if not aiqbuy then return nil end
		return { cost = aiqbuy * q, unit = aiqbuy, source = "aiqbuy", short = 0, first = aiqbuy }
	end
	local spent, got, first, last
	if source == "ah" then
		spent, got = walk(rows, q)
		first, last = rows[1][1], rows[#rows][1]
	else
		spent, got = ladder(rows, q)
		first = rows[1][2]
		local n = #rows
		local pq, pc = n > 1 and rows[n - 1][1] or 0, n > 1 and rows[n - 1][1] * rows[n - 1][2] or 0
		last = (rows[n][1] * rows[n][2] - pc) / (rows[n][1] - pq)
	end
	local short = q - got
	if short > 0 then spent = spent + short * math.max(last, aiqbuy or 0) end
	-- a saved scan keeps the book only up to its last point; past that it's a guess, not a shortage
	if source == "scan" and rows[#rows][1] >= D.SCAN_CAP then short = 0 end
	spent = math.ceil(spent)
	return { cost = spent, unit = spent / q, source = source, short = short, first = first, age = age }
end

--- How much more q costs than q at the cheapest listing, as a fraction (0.12 = 12% more). nil if unknown.
function D.Slippage(id, q)
	local c = D.Cost(id, q)
	if not c or not c.first or c.first <= 0 then return nil end
	return c.unit / c.first - 1
end

-- The sell side ----------------------------------------------------------------------------------
-- What posting q at a price is likely to bring in before the listing runs out. Buyers take the
-- cheapest listings first, so the units others have up below your price sell before yours:
--   ahead     units listed below your price (your AH search, else the last full AH search; your own
--             listings are left out of a search, not always of a saved scan)
--   demand    units bought over the listing's time: the sales estimate's belief (Demand.lua, your
--             sales on the days you had it up blended with the region's) spread over those hours
--   sold      E[min(q, demand - ahead)], with demand - ahead never under 0
--   proceeds  sold x price after the cut, less the deposit lost on what expires
-- It is an estimate and says what it rests on: where the listings come from and how old, and where
-- the sales rate comes from.

--- Units others have listed below `price`, and where that comes from: (units, source, age) or nil
--- without a book.
function D.Ahead(id, price)
	local rows, source, age = D.Book(id)
	if not (rows and price) then return nil end
	local n = 0
	if source == "ah" then
		for _, r in ipairs(rows) do
			if r[1] < price then n = n + r[2] else break end
		end
	else
		-- a ladder of (units, average price) points: each step's own price is its added cost over its added units
		local pq, pc = 0, 0
		for _, pt in ipairs(rows) do
			local cq, cc = pt[1], pt[1] * pt[2]
			local step = cq > pq and (cc - pc) / (cq - pq) or pt[2]
			if step >= price then break end
			n = cq
			pq, pc = cq, cc
		end
	end
	return n, source, age
end

--- Posting q at price: { q, price, hours, ahead, bookSource, bookAge, demand (the estimate), sold
--- (expected), low, high (80% of how many sell), proceeds (expected, after the cut and lost
--- deposits), gross (all q sold), lost (deposits on what expires), deposit (paid up front), slow (proceeds
--- when only the low end sells), text } or nil without a price.
--- opts: hours (else the item's posting duration), demand (a Demand.Estimate), ahead (units).
function D.Sell(id, q, price, opts)
	opts = opts or {}
	q = math.floor(q or 0)
	if not (id and price and price > 0 and q > 0) then return nil end
	local E = AuctionIQ.Expect
	local hours = opts.hours or (E and E.Hours(id)) or 24
	local ahead, bookSource, bookAge = opts.ahead, opts.ahead and "given" or nil, nil
	if not ahead then ahead, bookSource, bookAge = D.Ahead(id, price) end
	local e = opts.demand or (AuctionIQ.Demand and AuctionIQ.Demand.Estimate(id))
	local R = AuctionIQ.Restock
	local each = price * AuctionIQ.AH_CUT
	local deposit = E and E.Deposit(id, hours) or 0
	local out = { q = q, price = price, hours = hours, ahead = ahead, bookSource = bookSource, bookAge = bookAge, demand = e,
		gross = each * q }
	local d = R and R.Demand(e, hours / 24, math.ceil((ahead or 0) + q) + 1)
	if not d then
		out.text = "No sales rate for it yet, so how many sell in time is unknown."
		return out
	end
	local a = ahead or 0
	out.sold = R.Sold(d, a + q) - R.Sold(d, a)
	-- how many sell: demand past the stock ahead, at most q (from the demand's 10% and 90% points)
	out.low = math.max(0, math.min(q, d.low - a))
	out.high = math.max(0, math.min(q, d.high - a))
	out.lost = deposit * (q - out.sold)
	out.proceeds = each * out.sold - out.lost
	out.deposit = deposit * q
	-- the slow case: only the low end of the range sells
	out.slow = each * out.low - deposit * (q - out.low)
	out.text = D.SellText(out)
	return out
end

local function hoursText(h) return h % 24 == 0 and string.format("%d day%s", h / 24, h == 24 and "" or "s") or string.format("%d hours", h) end

--- "Likely 2 to 4 of 5 sell in 1 day: 30 are listed below your price (your last AH scan, 2 hr old)."
function D.SellText(s)
	if not (s and s.sold) then return s and s.text or nil end
	local range = s.low == s.high and tostring(s.low) or string.format("%d to %d", s.low, s.high)
	local where = s.bookSource == "ah" and "your AH search" or s.bookSource == "scan" and "your last AH scan" or nil
	local age = where and s.bookAge and AuctionIQ.Scans and AuctionIQ.Scans.Age and (", " .. AuctionIQ.Scans.Age(s.bookAge) .. " old") or ""
	local ahead = s.ahead == nil and "no listings seen to compare with"
		or s.ahead == 0 and "nothing is listed below your price" .. (where and (" (" .. where .. age .. ")") or "")
		or string.format("%d %s listed below your price%s", s.ahead, s.ahead == 1 and "is" or "are", where and (" (" .. where .. age .. ")") or "")
	return string.format("Likely %s of %d sell in %s: %s.", range, s.q, hoursText(s.hours), ahead)
end
