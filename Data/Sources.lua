-- Where prices come from, best first: TSM, then Oribos Exchange, then vendor prices. TSM is "best"
-- only when it has market data (its desktop app has synced this game); loaded without it, TSM still
-- gives vendor prices and your own buy and sell history, so the badge says so instead of hiding it.
local _, AuctionIQ = ...

local Sources = {}
AuctionIQ.Sources = Sources

-- Linen Cloth: on every auction house in every game, so a missing market price means no data at all.
local PROBE_ITEM = "i:2589"

local function tsmValue(src, item)
	if not (TSM_API and TSM_API.GetCustomPriceValue) then return nil end
	local ok, v = pcall(TSM_API.GetCustomPriceValue, src, item)
	return ok and v or nil
end

function Sources.TSM() return TSM_API ~= nil end
function Sources.TSMMarket() return tsmValue("DBMarket", PROBE_ITEM) ~= nil or tsmValue("DBRegionMarketAvg", PROBE_ITEM) ~= nil end
function Sources.Oribos() return type(OEMarketInfo) == "function" end

--- The source in use: { key = "tsm"|"oe"|"vendor", label (badge text), ok (has market prices),
--- lines = tooltip lines }.
function Sources.Active()
	local tsm, market, oe = Sources.TSM(), Sources.TSM() and Sources.TSMMarket(), Sources.Oribos()
	local lines = {
		{ "TradeSkillMaster", not tsm and "not loaded" or market and "market prices" or "loaded, no market data yet" },
		{ "Oribos Exchange", oe and "loaded" or "not loaded" },
		{ "Vendor prices", "always" },
	}
	if tsm and market then return { key = "tsm", label = "TSM", ok = true, lines = lines } end
	if oe then return { key = "oe", label = "OE", ok = true, lines = lines } end
	if tsm then return { key = "tsm", label = "TSM", ok = false, lines = lines } end
	return { key = "vendor", label = "Vendor", ok = false, lines = lines }
end
