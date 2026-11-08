-- Clearinghouse prices. One adapter so other price addons can plug in later; version 1 reads TSM.
--
-- chmat   what a reagent costs to buy today: the cheapest listing, floored at 80% of market
-- chvalue what a crafted item sells for: the lower of that and the price TSM would post it at
-- If the player hasn't added the chmat/chvalue custom sources to TSM, the same formulas are
-- passed to TSM directly, so everyone gets the same numbers.
local _, CH = ...

local NOW = "max(first(dbminbuyout,dbmarket,dbregionmarketavg),80%first(dbmarket,dbregionmarketavg))"
local POST = "max(first(dbregionsaleavg,dbregionmarketavg),min(dbmarket,400%first(dbregionsaleavg,dbregionmarketavg)))"
local FORMULA = {
	chmat = NOW,
	chpost = POST,
	avgsell = "avgsell",
	chvalue = "min(" .. NOW .. "," .. POST .. ")",
	crafting = "crafting",
	-- Oribos Exchange (Undermine Exchange's addon), through TSM, when it's installed
	oerealm = "oerealm",
	oeregion = "oeregion",
	-- TSM's own sources, for the Markets view when the Clearinghouse app has no data yet
	dbmarket = "dbmarket",
	dbminbuyout = "dbminbuyout",
	dbhistorical = "dbhistorical",
	dbregionmarketavg = "dbregionmarketavg",
}

local Prices = { FORMULA = FORMULA }
CH.Prices = Prices

local CACHE_SECONDS = 60
local cache, cacheTime = {}, {}
local customOK = {}

function Prices.Available()
	return type(TSM_API) == "table" and TSM_API.GetCustomPriceValue ~= nil
end

function Prices.ItemString(item)
	if not Prices.Available() or not item then return nil end
	return TSM_API.ToItemString(item)
end

local function query(kind, itemString)
	if kind ~= "crafting" then
		if customOK[kind] == nil then
			customOK[kind] = TSM_API.IsCustomPriceValid(kind) and true or false
		end
		if customOK[kind] then
			local v = TSM_API.GetCustomPriceValue(kind, itemString)
			if v then return v end
		end
	end
	return (TSM_API.GetCustomPriceValue(FORMULA[kind], itemString))
end

--- Price in copper, or nil when TSM has none. kind: "chmat", "chvalue" or "crafting".
function Prices.Get(kind, item)
	local itemString = Prices.ItemString(item)
	if not itemString or not FORMULA[kind] then return nil end
	local key = kind .. "|" .. itemString
	local now = GetTime()
	if cacheTime[key] and now - cacheTime[key] < CACHE_SECONDS then
		return cache[key] or nil
	end
	local ok, v = pcall(query, kind, itemString)
	v = ok and v or nil
	cache[key], cacheTime[key] = v or false, now
	return v
end

--- Profit in copper for crafting `item` and selling it, after the auction cut. nil if unknown.
function Prices.CraftProfit(item, quantity)
	local value, cost = Prices.Get("chvalue", item), Prices.Get("crafting", item)
	if not value or not cost then return nil end
	return value * CH.AH_CUT * (quantity or 1) - cost * (quantity or 1)
end

--- The Clearinghouse app's market history for an item (see the Clearinghouse addon), or nil.
function Prices.Market(id)
	if type(ClearinghouseMarket) ~= "table" or not id then return nil end
	local ok, v = pcall(ClearinghouseMarket.Get, id)
	return ok and v or nil
end

--- Oribos Exchange's numbers for an item: { market (realm), region, days }, or nil.
function Prices.Oribos(id)
	if type(OEMarketInfo) ~= "function" or not id then return nil end
	local t = {}
	local ok, r = pcall(OEMarketInfo, type(id) == "number" and ("item:" .. id) or id, t)
	if not ok then return nil end
	r = type(r) == "table" and r or t
	if not (r.market or r.region) then return nil end
	return { market = r.market, region = r.region, days = r.days }
end

--- Market numbers for an item from whatever is installed: the Clearinghouse app's history first,
--- else TSM's realm data and Oribos Exchange. Same shape as Prices.Market; from TSM/OE, avg7 is
--- TSM's 60-day historical price and change7 is today's market against it (avgDays says which).
function Prices.MarketAny(id)
	local m = Prices.Market(id)
	if m then m.avgDays = 7; return m end
	if not id then return nil end
	local key = "i:" .. id
	local oe = Prices.Oribos(id)
	local market = Prices.Get("dbmarket", key) or (oe and oe.market) or Prices.Get("dbregionmarketavg", key) or (oe and oe.region)
	if not market then return nil end
	local hist = Prices.Get("dbhistorical", key)
	local fromTSM = Prices.Get("dbmarket", key) ~= nil or Prices.Get("dbregionmarketavg", key) ~= nil
	return { market = market, min = Prices.Get("dbminbuyout", key), avg7 = hist, avgDays = hist and 60 or nil,
		change7 = hist and hist > 0 and (market / hist - 1) or nil, region = (oe and oe.region) or Prices.Get("dbregionmarketavg", key),
		source = fromTSM and "tsm" or "oribos" }
end

--- One TSM price source for an item (dbmarket, crafting ...), or nil without TSM. Cached like Get.
function Prices.Raw(name, id)
	if not Prices.Available() or not id then return nil end
	local key = "raw|" .. name .. "|" .. id
	local now = GetTime()
	if cacheTime[key] and now - cacheTime[key] < CACHE_SECONDS then return cache[key] or nil end
	local ok, v = pcall(TSM_API.GetCustomPriceValue, name, "i:" .. id)
	v = ok and v or nil
	cache[key], cacheTime[key] = v or false, now
	return v
end

function Prices.ClearCache()
	cache, cacheTime, customOK = {}, {}, {}
end
