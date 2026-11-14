-- History: daily market prices from before the addon's own 30 days, from the AuctionIQ_History
-- addon, which companion.py (in that addon's folder) writes from your saved scans. Without it, or
-- before it has run, an item's series is just its scans (Scans.Daily).
local _, CH = ...

local H = {}
CH.History = H

local cache, cacheFor = {}, nil

local function data()
	local d = AuctionIQ_HistoryData
	if type(d) ~= "table" or type(d.items) ~= "table" then return nil end
	if cacheFor ~= d then cache, cacheFor = {}, d end
	return d
end

--- Whether a history is loaded, and when companion.py wrote it.
function H.Available() local d = data(); return d ~= nil, d and d.at end

--- An item's days from the history, oldest first: { { day, price } }, or nil.
function H.Points(id)
	local d = data()
	local s = d and id and d.items[id]
	if type(s) ~= "string" then return nil end
	if cache[id] then return cache[id] end
	local base, out = d.base or 0, {}
	for off, price in s:gmatch("(%d+):(%d+)") do out[#out + 1] = { base + tonumber(off), tonumber(price) } end
	cache[id] = out
	return out
end

--- An item's whole series: the history's days and the scans' together (a day in both takes the
--- scans', which may have more searches since the history was written; the history can also hold
--- days another account's scans saw). Oldest first: { { day, price } }.
function H.Series(id)
	local scans = CH.Scans and CH.Scans.Daily and CH.Scans.Daily(id)
	local hist = H.Points(id)
	if not hist then return scans end
	if not scans then return hist end
	local out, i, j = {}, 1, 1
	while i <= #hist or j <= #scans do
		local h, s = hist[i], scans[j]
		if s and (not h or s[1] <= h[1]) then
			out[#out + 1] = s
			if h and h[1] == s[1] then i = i + 1 end
			j = j + 1
		else
			out[#out + 1] = h
			i = i + 1
		end
	end
	return out
end

function H.Clear() cache, cacheFor = {}, nil end
