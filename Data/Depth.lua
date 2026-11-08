-- The order book: what buying a quantity of a reagent really costs. The cheapest listing only
-- covers its own stack, so a big buy walks up the book:
--   cost(q) = sum over listings i of min(q_i, q - Q_(i-1)) * p_i      (Q_i = units in listings 1..i)
-- Listings come from the AH when you've searched the item there in the last 15 minutes, else
-- from the Clearinghouse app's last commodity scan, else the cost is chmat x quantity.
local _, CH = ...

local D = { LIVE_SECONDS = 15 * 60, APP_CAP = 25000 }
CH.Depth = D

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

-- The app's ladder holds (qty, average price) points; cost between points is a straight line,
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

--- Listings to price an item from: rows, source ("ah" or "app") and their age in seconds.
function D.Book(id)
	local l = live[id]
	if l and time() - l.at <= D.LIVE_SECONDS and l.rows[1] then return l.rows, "ah", time() - l.at end
	if type(ClearinghouseMarket) == "table" and ClearinghouseMarket.Depth then
		local ok, pts = pcall(ClearinghouseMarket.Depth, id)
		if ok and pts then
			local at = ClearinghouseMarket.DepthTime and ClearinghouseMarket.DepthTime() or 0
			return pts, "app", at > 0 and time() - at or nil
		end
	end
	return nil
end

--- What buying q of an item costs, in copper, and how it was worked out:
--- { cost, unit (average), source = "ah" | "app" | "chmat", short = units the book can't fill,
---   first = cheapest unit price, age }. Units past the book are priced at its last price.
--- nil when there is nothing to price it with.
function D.Cost(id, q)
	q = math.floor(q or 0)
	if not id or q <= 0 then return nil end
	local rows, source, age = D.Book(id)
	local chmat = CH.Prices.Get("chmat", "i:" .. id)
	if not rows then
		if not chmat then return nil end
		return { cost = chmat * q, unit = chmat, source = "chmat", short = 0, first = chmat }
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
	if short > 0 then spent = spent + short * math.max(last, chmat or 0) end
	-- the app keeps the book only up to its last point; past that it's a guess, not a shortage
	if source == "app" and rows[#rows][1] >= D.APP_CAP then short = 0 end
	spent = math.ceil(spent)
	return { cost = spent, unit = spent / q, source = source, short = short, first = first, age = age }
end

--- How much more q costs than q at the cheapest listing, as a fraction (0.12 = 12% more). nil if unknown.
function D.Slippage(id, q)
	local c = D.Cost(id, q)
	if not c or not c.first or c.first <= 0 then return nil end
	return c.unit / c.first - 1
end
