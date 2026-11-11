-- AuctionIQ prices. One adapter so other price addons can plug in later; version 1 reads TSM.
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
	matprice = "matprice", -- TSM's material cost, as set in TSM's Crafting settings
	-- Oribos Exchange (Undermine Exchange's addon), through TSM, when it's installed
	oerealm = "oerealm",
	oeregion = "oeregion",
	-- TSM's own sources, for the Markets view and the price comparison
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

--- Profit in copper for crafting `item` and selling it: its expected value (after the cut, lost
--- deposits and carrying, see Expect.lua) less the cost. nil if unknown.
function Prices.CraftProfit(item, quantity)
	local value, cost = Prices.Get("chvalue", item), Prices.Get("crafting", item)
	if not value or not cost then return nil end
	local id = tonumber(tostring(Prices.ItemString(item) or ""):match("^i:(%d+)"))
	local ev = id and CH.Expect and CH.Expect.Value(id, value) or value * CH.AH_CUT
	return (ev - cost) * (quantity or 1)
end

--- What the AH showed for an item at its last scan (see Scans.lua), or nil.
function Prices.Market(id)
	return id and CH.Scans and CH.Scans.Get(id) or nil
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

--- Market numbers for an item from whatever there is: your AH scans first (avgDays 7),
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
function Prices.Raw(name, id, level)
	if not Prices.Available() or not id then return nil end
	local item = level and ("i:" .. id .. "::i" .. level) or ("i:" .. id)
	local key = "raw|" .. name .. "|" .. item
	local now = GetTime()
	if cacheTime[key] and now - cacheTime[key] < CACHE_SECONDS then return cache[key] or nil end
	local ok, v = pcall(TSM_API.GetCustomPriceValue, name, item)
	v = ok and v or nil
	cache[key], cacheTime[key] = v or false, now
	return v
end

--- How reagents are costed for crafting decisions (Settings, /aiq basis):
---   replacement  what buying it costs today: chmat (the default)
---   tsm          TSM's material cost (matprice), however you set it up in TSM
---   paid         what you paid on average over your last 30 days of buying it (TSM's purchase
---                records), else replacement
---   held         (default) the units you hold at their opportunity cost, what they'd sell for after
---                the cut, and only what you'd buy at today's price
Prices.BASES = { "held", "replacement", "tsm", "paid" }
Prices.BASIS_NAMES = { held = "What you hold at sale value, the rest at today's price", replacement = "Replacement cost (chmat)",
	tsm = "TSM material cost (matprice)", paid = "Estimated paid cost" }
function Prices.CostBasis(v)
	local st = CH.db and CH.db.settings
	if v and st and Prices.BASIS_NAMES[v] then st.costBasis = v; Prices.ClearCache() end
	local b = st and st.costBasis
	return Prices.BASIS_NAMES[b or ""] and b or "held"
end

local paidCache, paidAt
local function paidEach(id)
	if not (CH.Ledger and CH.Ledger.Available()) then return nil end
	local now = GetTime()
	if not paidCache or now - paidAt > CACHE_SECONDS then paidCache, paidAt = CH.Ledger.Paid(), now end
	local e = paidCache[id]
	return e and e.each or nil
end

--- What you paid for one, on average over your last 30 days of buying it (nil if you never bought it).
function Prices.PaidEach(id) return id and paidEach(id) or nil end

--- How many of an item you hold for crafting: bags, bank, reagent bank and warband bank.
function Prices.Held(id)
	if not (id and C_Item and C_Item.GetItemCount) then return 0 end
	return C_Item.GetItemCount(id, true, false, true, true) or 0
end

--- What one you hold would bring if you sold it instead of crafting with it: the sale price after
--- the AH cut, less the deposits lost to expiries and the cost of waiting for a slow seller
--- (Expect.Value), so a reagent that barely moves isn't valued as if it sold at once. nil with no
--- sale price. Second value: Expect's breakdown { gross, deposits, carry, days }.
function Prices.SellValue(id)
	local v = id and Prices.Get("chvalue", "i:" .. id)
	if not v then return nil end
	if CH.Expect and CH.Expect.Value then
		local ok, net, how = pcall(CH.Expect.Value, id, v)
		if ok and net then return math.max(0, net), how end
	end
	return v * CH.AH_CUT, { gross = v * CH.AH_CUT }
end

--- What one of a reagent costs on a costing basis (default: the one in Settings): copper and the
--- basis it really came from (paid falls back to replacement for what you never bought).
function Prices.ReagentCost(id, basis)
	if not id then return nil end
	basis = basis or Prices.CostBasis()
	if basis == "tsm" then
		local v = Prices.Get("matprice", "i:" .. id)
		if v then return v, "tsm" end
	elseif basis == "paid" then
		local v = paidEach(id)
		if v then return v, "paid" end
	end
	return Prices.Get("chmat", "i:" .. id), "replacement"
end

function Prices.ClearCache()
	cache, cacheTime, customOK, paidCache = {}, {}, {}, nil
end

--- Short codes used as column headings and labels, and what each means (shown on hover).
CH.GLOSSARY = {
	MV = "Market Value: TSM's market value on your realm, from AH scans.",
	RV = "Region Value: TSM's average market value across the whole region.",
	EV = "Estimated Value: what one is worth to you if you list it, after the AH cut, deposits lost to expiries and gold tied up while it waits.",
	RZ = "Realized Value: what you really sold it for, on average after the cut, over your last 30 days of sales.",
}

--- The four values that explain an item's price, each with where it comes from:
---   mv        Market Value: TSM's market value on this realm (dbmarket). Observed, from AH scans.
---   rv        Region Value: TSM's average market value across the region (dbregionmarketavg).
---   ev        Estimated Value: what one is worth to you if you list it at chvalue, after the cut,
---             deposits lost to expiries and gold tied up while it waits (Expect.lua). An estimate.
---   realized  Realized Value: what you really sold it for, on average after the cut, over the last
---             30 days of your sales (n of them, last at lastSale). nil when you haven't sold one.
function Prices.Values(id, now)
	if not id then return {} end
	now = now or time()
	local out = { mv = Prices.Raw("dbmarket", id), rv = Prices.Raw("dbregionmarketavg", id) }
	local sale = Prices.Get("chvalue", "i:" .. id)
	if sale and CH.Expect then out.ev = CH.Expect.Value(id, sale) end
	if CH.Ledger and CH.Ledger.Available() then
		local e = Prices.RecentSales(now)[id]
		if e and e.n > 0 then out.realized, out.n, out.lastSale = e.gold / e.n, e.n, e.last end
	end
	return out
end

-- Every item's last 30 days of sales, added up in one pass over the ledger and kept until the
-- ledger's records change or a minute passes, so a table of items doesn't walk the sales per row.
local recent = { at = 0 }
--- { [itemID] = { gold (after the cut), n (units), last (time) } } over the 30 days before now.
function Prices.RecentSales(now)
	now = now or time()
	local records = CH.Ledger.Records("Sales")
	if recent.records == records and math.abs(now - recent.at) < 60 then return recent.by end
	local by, from = {}, now - 30 * 86400
	for _, s in ipairs(records) do
		if s.id and s.quantity > 0 and s.time >= from and s.time <= now then
			local e = by[s.id]
			if not e then e = { gold = 0, n = 0 }; by[s.id] = e end
			e.gold, e.n = e.gold + CH.Ledger.Net(s), e.n + s.quantity
			if not e.last or s.time > e.last then e.last = s.time end
		end
	end
	recent.records, recent.at, recent.by = records, now, by
	return by
end

--- Tooltip lines for Prices.Values: { label, money, labelColor, valueColor }.
function Prices.ValueLines(id, now)
	local v, m, T = Prices.Values(id, now), CH.FormatMoney, CH.Theme
	local lines = {}
	if v.mv then table.insert(lines, { "  MV  Market Value", m(v.mv), "muted" }) end
	if v.rv then table.insert(lines, { "  RV  Region Value", m(v.rv), "muted" }) end
	if v.ev then table.insert(lines, { "  EV  Estimated Value", m(v.ev), "muted", "accent" }) end
	if v.realized then
		local ago = v.lastSale and math.floor(((now or time()) - v.lastSale) / 86400) or 0
		table.insert(lines, { string.format("  RZ  Realized, %d sold, last %s", v.n, ago == 0 and "today" or (ago .. "d ago")), m(v.realized), "muted", "ok" })
	end
	if #lines > 0 then table.insert(lines, 1, { "Values", "" }) end
	return lines
end

