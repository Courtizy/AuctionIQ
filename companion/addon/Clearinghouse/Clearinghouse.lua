-- Clearinghouse: market history from the Clearinghouse app, read by AuctionIQ.
-- ClearinghouseMarket.Get(itemID) returns { min, market, qty, avg7, avg30, change7, vol30, days,
-- source = "realm" | "commodity" } in copper (change7 and vol30 as fractions), or nil.
local data = ClearinghouseData or {}
local index = {}

local function build(kind)
	local t = {}
	for id, rest in (data[kind] or ""):gmatch("(%d+):([^;]*);") do t[tonumber(id)] = rest end
	index[kind] = t
	return t
end

local function num(s) return s ~= "" and tonumber(s) or nil end

local function decode(rest, source)
	local f = {}
	for v in (rest .. ","):gmatch("([^,]*),") do f[#f + 1] = v end
	local ch, vol = num(f[6]), num(f[7])
	return { min = num(f[1]), market = num(f[2]), qty = num(f[3]), avg7 = num(f[4]), avg30 = num(f[5]),
		change7 = ch and ch / 1000, vol30 = vol and vol / 1000, days = num(f[8]), source = source }
end

ClearinghouseMarket = {}

--- The app's numbers for an item: realm listings first, then region commodities.
function ClearinghouseMarket.Get(id)
	id = tonumber(id)
	if not id then return nil end
	local r = (index.realmItems or build("realmItems"))[id]
	if r then return decode(r, "realm") end
	local c = (index.commodities or build("commodities"))[id]
	if c then return decode(c, "commodity") end
	return nil
end

--- When the data was written (unix time), and for which realm.
function ClearinghouseMarket.Info()
	return data.updated or 0, data.realm or "", data.region or ""
end
