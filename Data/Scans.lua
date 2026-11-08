-- AH scans: what the auction house showed the last time an item was searched, by you, by AuctionIQ
-- or by TSM (any search or full scan in the AH window fires the same game events). This is
-- Blizzard's own live data; Markets compares it with TSM and Oribos Exchange.
--
-- Kept per item in AuctionIQDB.scans: the cheapest price, a market price (average of the cheapest
-- 15% of units listed), how many were listed, a buying ladder for commodities (see Depth.lua) and
-- one market price per day for the last 30 days.
local _, CH = ...

local S = { SHARE = 0.15, KEEP_DAYS = 30, POINTS = { 1, 10, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 25000 } }
CH.Scans = S

local function store()
	CH.db.scans = CH.db.scans or {}
	return CH.db.scans
end

local function day(t) return math.floor((t or time()) / 86400) end

-- Average unit price of buying each ladder point from sorted { price, qty } rows.
local function ladder(rows)
	local total = 0
	for _, r in ipairs(rows) do total = total + r[2] end
	local wants = {}
	for _, p in ipairs(S.POINTS) do if p <= total then wants[#wants + 1] = p end end
	if total < S.POINTS[#S.POINTS] and wants[#wants] ~= total then wants[#wants + 1] = total end
	local out, got, spent, i, left = {}, 0, 0, 1, rows[1] and rows[1][2] or 0
	for _, want in ipairs(wants) do
		while got < want do
			local take = math.min(left, want - got)
			got, spent, left = got + take, spent + take * rows[i][1], left - take
			if left == 0 then i = i + 1; left = rows[i] and rows[i][2] or 0 end
		end
		out[#out + 1] = { want, math.ceil(spent / want) }
	end
	return out
end
S.Ladder = ladder

local function addDay(e, now)
	if not e.market then return end
	e.daily = e.daily or {}
	local d = day(now)
	local at = #e.daily + 1
	for i, x in ipairs(e.daily) do
		if x[1] == d then x[2], x[3] = (x[2] * x[3] + e.market) / (x[3] + 1), x[3] + 1; at = nil; break end
		if x[1] > d then at = i; break end
	end
	if at then table.insert(e.daily, at, { d, e.market, 1 }) end
	while e.daily[1] and e.daily[1][1] <= d - S.KEEP_DAYS do table.remove(e.daily, 1) end
end

--- Save one item's search results ({ price, qty, mine } from Auction.Results).
function S.Record(id, results, commodity)
	if not id or type(results) ~= "table" or not CH.db then return end
	local all, others = {}, {}
	for _, r in ipairs(results) do
		if r.price and (r.qty or 0) > 0 then
			all[#all + 1] = { r.price, r.qty }
			if not r.mine then others[#others + 1] = { r.price, r.qty } end
		end
	end
	local now = time()
	local e = store()[id] or {}
	if not all[1] then
		e.at, e.min, e.market, e.qty, e.ladder = now, nil, nil, 0, nil
		store()[id] = e
		return
	end
	table.sort(all, function(a, b) return a[1] < b[1] end)
	table.sort(others, function(a, b) return a[1] < b[1] end)
	local total = 0
	for _, r in ipairs(all) do total = total + r[2] end
	local want, got, spent = math.max(1, math.floor(total * S.SHARE)), 0, 0
	for _, r in ipairs(all) do
		local take = math.min(r[2], want - got)
		got, spent = got + take, spent + take * r[1]
		if got >= want then break end
	end
	e.at, e.min, e.market, e.qty, e.full = now, all[1][1], math.floor(spent / got + 0.5), total, true
	e.ladder = commodity and others[1] and ladder(others) or nil
	addDay(e, now)
	store()[id] = e
end

--- Save a browse or full-scan row (cheapest price and quantity only). A full search of the same
--- item in the last hour is kept, since it knows more.
function S.RecordBrowse(id, minPrice, qty)
	if not id or not minPrice or not CH.db then return end
	local now = time()
	local e = store()[id] or {}
	if e.full and e.at and now - e.at < 3600 then return end
	e.at, e.min, e.market, e.qty, e.full = now, minPrice, minPrice, qty, false
	addDay(e, now)
	store()[id] = e
end

--- An item's last scan: { min, market, qty, at, age, avg7, change7, days, full, source = "scan" }, or nil.
function S.Get(id)
	local e = id and CH.db and store()[tonumber(id)]
	if not e or not e.at then return nil end
	local now = time()
	local sum, n, days = 0, 0, 0
	for _, d in ipairs(e.daily or {}) do
		days = days + 1
		if d[1] > day(now) - 7 then sum, n = sum + d[2], n + 1 end
	end
	local avg7 = n > 0 and sum / n or nil
	return { min = e.min, market = e.market, qty = e.qty, at = e.at, age = now - e.at, full = e.full,
		avg7 = avg7, change7 = avg7 and avg7 > 0 and e.market and (e.market / avg7 - 1) or nil, days = days, source = "scan" }
end

--- A commodity's buying ladder from its last full search: { { qty, avg } }, and when it was taken.
function S.Depth(id)
	local e = id and CH.db and store()[id]
	if not e or not e.ladder or not e.ladder[1] then return nil end
	return e.ladder, e.at
end

--- "just now", "12 min", "3 hr", "2 days": how old a scan is.
function S.Age(sec)
	if not sec then return "?" end
	if sec < 60 then return "just now" end
	if sec < 3600 then return math.floor(sec / 60) .. " min" end
	if sec < 86400 then return math.floor(sec / 3600) .. " hr" end
	local n = math.floor(sec / 86400)
	return n .. (n == 1 and " day" or " days")
end

--- Every item with a scan, as ids.
function S.Items()
	local out = {}
	for id in pairs(store()) do out[#out + 1] = id end
	return out
end

--- Drop items not seen in KEEP_DAYS.
function S.Prune(now)
	now = now or time()
	for id, e in pairs(store()) do
		if not e.at or now - e.at > S.KEEP_DAYS * 86400 then store()[id] = nil end
	end
end

CH.On("PLAYER_LOGIN", function() if CH.db then S.Prune() end end)

-- Browse results (the AH's front page, TSM's full scans): cheapest price and quantity per item.
local function browse(rows)
	for _, r in ipairs(rows or {}) do
		local key = r.itemKey
		if key and key.itemID and (key.battlePetSpeciesID or 0) == 0 then
			S.RecordBrowse(key.itemID, r.minPrice, r.totalQuantity)
		end
	end
end
CH.On("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", function()
	if C_AuctionHouse and C_AuctionHouse.GetBrowseResults then browse(C_AuctionHouse.GetBrowseResults()) end
end)
CH.On("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", function(_, added) browse(added) end)
