-- Demand: how many of an item you can expect to sell a day, and what that number rests on.
--
-- The region's sold-a-day figure (TSM) is every realm in the region, not your realm and not your
-- share of it. Your own sales are the better evidence, but only on days you had the item up: a day
-- with nothing listed says nothing about demand. So:
--
--   listed days  days in the last WINDOW days that AuctionIQ knows you had it on the AH: a day you
--                sold, expired or cancelled one (TSM's records), or a day AuctionIQ saw it among your
--                auctions (the owned-auctions list, a confirmed post, TSM's auction counts at login)
--   own rate     units you sold on those days / listed days
--   prior        the region's sold a day, counted at most your cap (/aiq cap, a rule you set)
--   estimate     (sold + K * prior) / (listed days + K): your own rate once you have a few weeks of
--                listed days, the capped region figure while you have none, a blend between
--
-- Days are UTC days (time() / 86400). Listed days are a lower bound before AuctionIQ started
-- recording them (only sale, expiry and cancel days are known), which makes the own rate read high
-- for older history; the text says how many listed days it rests on.
local _, CH = ...

local Dm = { WINDOW = 30, KEEP = 60, PRIOR_DAYS = 5, OWN_SHARE = 0.75 }
CH.Demand = Dm

local DAY = 86400
local function today(now) return math.floor((now or time()) / DAY) end

-- AuctionIQDB.exposure = { [itemID] = { day, day, ... } } ascending, each day once, KEEP days at most
local function store()
	CH.db.exposure = CH.db.exposure or {}
	return CH.db.exposure
end
Dm.version = 0
local index -- see build() below

--- Note that you had an item on the AH on a day (today by default).
function Dm.Mark(id, now)
	id = tonumber(id)
	if not (id and CH.db) then return end
	local d = today(now)
	local s = store()
	local days = s[id]
	if not days then days = {}; s[id] = days end
	local n = #days
	if days[n] == d then return end
	if n == 0 or days[n] < d then days[n + 1] = d
	else
		for i = 1, n do
			if days[i] == d then return end
			if days[i] > d then table.insert(days, i, d); break end
		end
	end
	local c = index
	local current = c and c.version == Dm.version
	Dm.version = Dm.version + 1
	-- the index is still right but for this one day: add it there instead of rebuilding
	if current and c.day >= d and d > c.day - Dm.WINDOW then
		local e = c.by[id]
		if not e then e = { sold = 0, listed = 0, days = {} }; c.by[id] = e end
		if not e.days[d] then e.days[d] = true; e.listed = e.listed + 1 end
		c.version = Dm.version
	end
end

--- Note every item in a { [itemID] = qty } table as listed today.
function Dm.MarkAll(items, now)
	for id, q in pairs(items or {}) do if (tonumber(q) or 1) > 0 then Dm.Mark(id, now) end end
end

--- Drop days older than KEEP and items with none left. Returns how many items went.
function Dm.Prune(now)
	if not CH.db or not CH.db.exposure then return 0 end
	local cut, gone = today(now) - Dm.KEEP, 0
	for id, days in pairs(store()) do
		local k = 0
		for i = 1, #days do if days[i] > cut then k = k + 1; days[k] = days[i] end end
		for i = #days, k + 1, -1 do days[i] = nil end
		if k == 0 then store()[id] = nil; gone = gone + 1 end
	end
	Dm.version = Dm.version + 1
	return gone
end

-- Per item over the window: { sold (units), listed (days), days = { [day] = true } }. Built in one
-- pass over the sales, expiries and cancels, kept until those records, the recorded days or the
-- date change. A newly marked day updates it in place (Mark), so the AH's owned-auctions list
-- doesn't make the next estimate walk every sale again.
local function build(now)
	local L = CH.Ledger
	local avail = L and L.Available()
	local sales = avail and L.Records("Sales") or nil
	local expired = avail and L.Records("Expired") or nil
	local cancelled = avail and L.Records("Cancelled") or nil
	local d = today(now)
	local c = index
	if c and c.sales == sales and c.expired == expired and c.cancelled == cancelled and c.version == Dm.version and c.day == d then return c.by end
	local from = d - Dm.WINDOW + 1
	local by = {}
	local function item(id)
		local e = by[id]
		if not e then e = { sold = 0, listed = 0, days = {} }; by[id] = e end
		return e
	end
	local function listedOn(e, day)
		if day >= from and day <= d and not e.days[day] then e.days[day] = true; e.listed = e.listed + 1 end
	end
	local F = L and L.F
	local fid, fq, ft = F and F.id, F and F.quantity, F and F.time
	-- only the window's records: each kind in time order, from the window's first day
	local function window(kind)
		if not avail then return {}, 1 end
		local list = L.ByTime(kind)
		return list, L.From(list, from * DAY)
	end
	local sl, si = window("Sales")
	for i = si, #sl do
		local s = sl[i]
		local id, q, t = s[fid], s[fq], s[ft]
		local day = t and math.floor(t / DAY)
		if day and day > d then break end
		if id and q and q > 0 and day and day >= from then
			local e = item(id)
			e.sold = e.sold + q
			listedOn(e, day)
		end
	end
	for _, kind in ipairs({ "Expired", "Cancelled" }) do
		local list, start = window(kind)
		for i = start, #list do
			local r = list[i]
			local id, t = r[fid], r[ft]
			local day = t and math.floor(t / DAY)
			if day and day > d then break end
			if id and day and day >= from then listedOn(item(id), day) end
		end
	end
	if CH.db and CH.db.exposure then
		for id, days in pairs(CH.db.exposure) do
			for _, day in ipairs(days) do if day >= from and day <= d then listedOn(item(id), day) end end
		end
	end
	index = { sales = sales, expired = expired, cancelled = cancelled, version = Dm.version, day = d, by = by }
	Dm.builds = (Dm.builds or 0) + 1
	return by
end

function Dm.Clear() index = nil end

--- Build the index now (one pass over the window's records), so the first estimate inside a
--- frame-budgeted scan doesn't pay for it.
function Dm.Warm(now) build(now) end

--- Expected units sold a day for an item, and what it rests on:
--- { units, source = "own" | "blend" | "region" | "none", sold, listed (days), window, region
---   (TSM's region sold a day, uncapped), cap, capped (the region figure counted at the cap),
---   weight (share of the estimate that is your own record, 0 to 1) }.
function Dm.Estimate(id, now)
	local cap = CH.db and CH.db.settings and CH.db.settings.scan and CH.db.settings.scan.dailyCap or 10
	local region = id and CH.Advisor and CH.Advisor.SoldPerDay and CH.Advisor.SoldPerDay(id) or nil
	local out = { units = 0, source = "none", sold = 0, listed = 0, window = Dm.WINDOW, region = region, cap = cap, weight = 0 }
	if not id then return out end
	local e = build(now)[id]
	local sold, listed = e and e.sold or 0, e and e.listed or 0
	out.sold, out.listed = sold, listed
	local prior = region and math.min(region, cap) or nil
	local k = Dm.PRIOR_DAYS
	if prior then
		out.capped = region > cap
		out.weight = listed / (listed + k)
		out.units = (sold + k * prior) / (listed + k)
		out.source = listed == 0 and "region" or out.weight >= Dm.OWN_SHARE and "own" or "blend"
	elseif listed > 0 then
		-- no region figure: your record alone, however thin (the text says how thin)
		out.weight = 1
		out.units = sold / listed
		out.source = "own"
	end
	return out
end

local function rate(x)
	if x >= 100 then return string.format("%.0f", x) end
	return (x % 1 == 0) and tostring(x) or string.format("%.1f", x)
end
Dm.Rate = rate

--- The estimate in a few words, for a line or a hover: "1.4 a day: your 12 sold over 9 days
--- listed, blended with the region's 340 counted as 10 (your cap)".
function Dm.Text(e)
	if not e then return "no sales rate" end
	local regionPart = e.region and (e.capped and string.format("the region's %s a day counted as %s (your cap)", rate(e.region), rate(e.cap))
		or string.format("the region's %s a day", rate(e.region)))
	local own = string.format("your %d sold over %d day%s listed", e.sold, e.listed, e.listed == 1 and "" or "s")
	if e.source == "none" then return "no sales rate: you haven't listed it and TSM has no region figure" end
	if e.source == "region" then return string.format("%s a day: %s; you haven't listed it in %d days", rate(e.units), regionPart, e.window) end
	if e.source == "blend" then return string.format("%s a day: %s, blended with %s", rate(e.units), own, regionPart) end
	return string.format("%s a day: %s", rate(e.units), own) .. (regionPart and e.weight < 1 and (", a little of " .. regionPart) or "")
end

--- Short label for where the number comes from: "your sales", "your sales + region", "region".
Dm.SOURCE = { own = "your sales", blend = "your sales + region", region = "region", none = "none" }

-- Recording listed days ----------------------------------------------------------------------
-- TSM's auction counts per character are a snapshot from each character's last visit to the AH:
-- at login, items any character on this realm has up count as listed today.
local function markTSM(now)
	local db = type(TradeSkillMasterDB) == "table" and TradeSkillMasterDB
	if not (db and CH.Ledger and CH.Ledger.Characters) then return end
	for _, c in ipairs(CH.Ledger.Characters()) do
		local t = db["s@" .. c.key .. "@internalData@auctionQuantity"]
		if type(t) == "table" then
			for itemString, n in pairs(t) do
				local id = tonumber(tostring(itemString):match("^i:(%d+)"))
				if id and (tonumber(n) or 0) > 0 then Dm.Mark(id, now) end
			end
		end
	end
end
Dm.MarkTSM = markTSM

CH.On("PLAYER_LOGIN", function()
	if not CH.db then return end
	pcall(Dm.Prune)
	if C_Timer then C_Timer.After(12, function() pcall(markTSM) end) else pcall(markTSM) end
end)
