-- Availability: when your stock of an item was actually up on the AH, and when it ran out.
--
-- Demand.lua counts listed days, but a day says nothing about how long stock lasted: selling five and
-- running out at noon is not selling five while fifty stayed up all day. So every time the AH lists
-- a character's auctions (OWNED_AUCTIONS_UPDATED), the units up for each item are noted, but only
-- when the count changes, or as a heartbeat every HEARTBEAT seconds so a long quiet stretch still
-- shows as observed.
--
--   AuctionIQ.db.avail[character][itemID] = { {t, n}, ... }  ascending by time t, n units up
--
-- What a pair of readings says:
--   n > 0, then n > 0   up the whole time (at least the smaller count), within OBSERVED of each other
--   n > 0, then 0       ran out (sold, expired or cancelled) somewhere between the two readings
--   readings far apart  the gap between them is unobserved: nothing is assumed about it
-- Readings older than KEEP days are dropped, and at most MAX per item are kept.
local _, AuctionIQ = ...

local Av = { HEARTBEAT = 6 * 3600, OBSERVED = 12 * 3600, KEEP = 60, MAX = 400 }
AuctionIQ.Availability = Av

local DAY = 86400

local function store()
	AuctionIQ.db.avail = AuctionIQ.db.avail or {}
	return AuctionIQ.db.avail
end

local function trim(list, now)
	local cut = now - Av.KEEP * DAY
	local drop = 0
	while list[drop + 1] and list[drop + 1][1] < cut do drop = drop + 1 end
	drop = math.max(drop, #list - Av.MAX)
	if drop > 0 then
		for i = 1, #list - drop do list[i] = list[i + drop] end
		for i = #list, #list - drop + 1, -1 do list[i] = nil end
	end
end

--- One reading of a character's auctions: items = { [itemID] = units up }. Items this character had
--- up at the last reading and doesn't now read as 0 (they ran out).
function Av.Observe(who, items, now)
	if not (AuctionIQ.db and who) then return end
	now = now or time()
	local s = store()
	local mine = s[who] or {}
	s[who] = mine
	local function note(id, n)
		local list = mine[id]
		if not list then
			if n == 0 then return end
			list = {}
			mine[id] = list
		end
		local last = list[#list]
		if last and last[2] == n and now - last[1] < Av.HEARTBEAT then return end
		if last and last[1] > now then return end -- a clock step back: keep the order
		local wasOut = last and last[2] == 0
		list[#list + 1] = { now, n }
		trim(list, now)
		-- a run-out, or posting again after one, changes the demand estimate's exposure: let it rebuild
		if (n == 0 or wasOut) and AuctionIQ.Demand then AuctionIQ.Demand.version = (AuctionIQ.Demand.version or 0) + 1 end
	end
	for id, n in pairs(items or {}) do
		id = tonumber(id)
		if id then note(id, math.max(0, tonumber(n) or 0)) end
	end
	for id, list in pairs(mine) do
		local last = list[#list]
		if not (items and items[id]) and last and last[2] > 0 then note(id, 0) end
	end
end

--- Every character's readings for an item, each list ascending: { [character] = { {t, n}, ... } }.
function Av.Readings(id)
	local out = {}
	for who, mine in pairs(AuctionIQ.db and AuctionIQ.db.avail or {}) do
		if mine[id] then out[who] = mine[id] end
	end
	return out
end

--- What the readings since `from` show for an item: { up = seconds seen up, unobserved = seconds
--- with no reading close enough to say, outs = { {after, before} } times it ran out between two
--- readings }. Each character is counted on its own. `now` is the end of the span (readings after it
--- don't count), so a past span can be read too.
function Av.Summary(id, from, now)
	now = now or time()
	from = from or (now - 30 * DAY)
	local out = { up = 0, unobserved = 0, outs = {} }
	for _, list in pairs(Av.Readings(id)) do
		for i = 1, #list do
			local a, b = list[i], list[i + 1]
			local t0 = math.max(a[1], from)
			local t1 = math.min(b and b[1] or now, now)
			if t1 > t0 and a[2] > 0 then
				if t1 - a[1] <= Av.OBSERVED then out.up = out.up + (t1 - t0)
				else out.unobserved = out.unobserved + (t1 - t0) end
			end
			if b and a[2] > 0 and b[2] == 0 and b[1] >= from and b[1] <= now then table.insert(out.outs, { a[1], b[1] }) end
		end
	end
	table.sort(out.outs, function(x, y) return x[2] < y[2] end)
	return out
end

--- For the demand estimate: on each day in [from, to) that an item ran out, the share of that day
--- its stock was up, { [itemID] = { [day] = share } }. The run-out time is the midpoint between
--- the last reading with stock and the first at 0, and only when they are within OBSERVED of each
--- other. A day it was posted again after running out isn't cut short.
function Av.DayShares(from, to)
	local out = {}
	for _, mine in pairs(AuctionIQ.db and AuctionIQ.db.avail or {}) do
		for id, list in pairs(mine) do
			for i = 1, #list - 1 do
				local a, b = list[i], list[i + 1]
				if a[2] > 0 and b[2] == 0 and b[1] - a[1] <= Av.OBSERVED then
					local t = (a[1] + b[1]) / 2
					if t >= from and t < to then
						local day = math.floor(t / DAY)
						local again = false
						for j = i + 2, #list do
							if list[j][1] >= (day + 1) * DAY then break end
							if list[j][2] > 0 then again = true; break end
						end
						if not again then
							out[id] = out[id] or {}
							local share = (t - day * DAY) / DAY
							out[id][day] = math.min(out[id][day] or 1, share)
						end
					end
				end
			end
		end
	end
	return out
end
