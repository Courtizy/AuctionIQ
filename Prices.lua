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

function Prices.ClearCache()
	cache, cacheTime, customOK = {}, {}, {}
end
