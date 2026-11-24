-- What things are worth and what they cost you, for the new screens, on retail and Forever alike.
--
-- Market price, best source first: TSM (realm market, else region average), Oribos Exchange (realm,
-- else region), Auctionator's last scan, then the vendor sell price. Each answer says which source
-- it came from, so the screens can show it.
--
-- Paid cost per unit: what TSM says you paid (SmartAvgBuy); else what it costs to craft (TSM's
-- crafting cost); else, for things you farmed, the market price or zero (Settings). Coverage is how
-- much of a list's value rests on real purchases or crafts rather than that estimate.
--
-- Restock: TSM's Crafting operation min and max for an item, read from TSM's saved settings. That's
-- TSM's internal format, so anything unexpected answers nil and the Craft tab falls back to
-- "profitable up to N".
local _, AuctionIQ = ...

local Value = {}
AuctionIQ.Value = Value

--- An item ID from a number, "i:123", "item:123:..." or an item link.
function Value.ID(item)
	if type(item) == "number" then return item end
	if type(item) ~= "string" then return nil end
	return tonumber(item:match("^i:(%d+)") or item:match("item:(%d+)") or item:match("^(%d+)$"))
end

local function tsm(src, id)
	return AuctionIQ.Prices and AuctionIQ.Prices.Raw and AuctionIQ.Prices.Raw(src, id) or nil
end

local function oribos(id)
	return AuctionIQ.Prices and AuctionIQ.Prices.Oribos and AuctionIQ.Prices.Oribos(id) or nil
end

local function auctionator(id)
	local api = Auctionator and Auctionator.API and Auctionator.API.v1
	if not (api and api.GetAuctionPriceByItemID) then return nil end
	local ok, v = pcall(api.GetAuctionPriceByItemID, "AuctionIQ", id)
	return ok and type(v) == "number" and v > 0 and v or nil
end

--- What a vendor pays for one, or nil.
function Value.Vendor(id)
	local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	if not (get and id) then return nil end
	local v = select(11, get(id))
	return type(v) == "number" and v > 0 and v or nil
end

--- Market price of one unit in copper, and its source: "tsm", "oe", "auctionator" or "vendor".
--- nil when nothing knows the item.
function Value.Market(item)
	local id = Value.ID(item)
	if not id then return nil end
	local v = tsm("dbmarket", id) or tsm("dbregionmarketavg", id)
	if v then return v, "tsm" end
	local oe = oribos(id)
	v = oe and (oe.market or oe.region)
	if v then return v, "oe" end
	v = auctionator(id)
	if v then return v, "auctionator" end
	v = Value.Vendor(id)
	if v then return v, "vendor" end
	return nil
end

--- TSM's regional sale rate (0 to 1), or nil without it.
function Value.SaleRate(item)
	local id = Value.ID(item)
	return id and tsm("dbregionsalerate", id) or nil
end

local function farmedAt()
	local s = AuctionIQ.db and AuctionIQ.db.settings and AuctionIQ.db.settings.costs
	return s and s.farmedAt == "zero" and "zero" or "market"
end

--- What one unit cost you, in copper, and how that's known: "bought" (TSM SmartAvgBuy), "crafted"
--- (TSM's crafting cost) or "farmed" (market price or zero, per Settings). nil when nothing is known.
function Value.Paid(item)
	local id = Value.ID(item)
	if not id then return nil end
	local v = tsm("smartavgbuy", id)
	if v then return v, "bought" end
	v = tsm("crafting", id)
	if v then return v, "crafted" end
	if farmedAt() == "zero" then return 0, "farmed" end
	v = Value.Market(id)
	if v then return v, "farmed" end
	return nil
end

--- For a list of { item, qty }: total paid, and the share of it (0 to 1) that rests on real purchases
--- or crafts. A list worth nothing has full coverage.
function Value.Coverage(list)
	local total, known = 0, 0
	for _, e in ipairs(list or {}) do
		local each, how = Value.Paid(e.item or e[1])
		local v = (each or 0) * (e.qty or e[2] or 1)
		total = total + v
		if how == "bought" or how == "crafted" then known = known + v end
	end
	return total, total > 0 and known / total or 1
end

-- Restock ----------------------------------------------------------------------------------------

local SEP = "`" -- TSM's group path separator

local function profile(db)
	local cur = type(db._currentProfile) == "table" and db._currentProfile or {}
	local me = AuctionIQ.PlayerName() .. " - " .. AuctionIQ.RealmName()
	return cur[me] or "Default"
end

local function crafting(db, prof, name)
	for _, key in ipairs({ "p@" .. prof .. "@userData@operations", "g@ @userData@sharedOperations" }) do
		local ops = type(db[key]) == "table" and db[key].Crafting
		if type(ops) == "table" and type(ops[name]) == "table" then return ops[name] end
	end
	return nil
end

--- TSM's restock for an item: { min, max, op, group }, or nil when the item isn't in a TSM group
--- with a Crafting operation (or TSM's settings can't be read).
function Value.Restock(item)
	local db = TradeSkillMasterDB
	local id = Value.ID(item)
	if type(db) ~= "table" or not id then return nil end
	local ok, r = pcall(function()
		local prof = profile(db)
		local items = db["p@" .. prof .. "@userData@items"]
		local groups = db["p@" .. prof .. "@userData@groups"]
		if type(items) ~= "table" or type(groups) ~= "table" then return nil end
		local group = items["i:" .. id]
		if type(group) ~= "string" or group == "" then return nil end
		-- the group's own Crafting operation, else the nearest parent's that it inherits
		local path = group
		while true do
			local g = groups[path]
			local list = type(g) == "table" and g.Crafting
			if type(list) == "table" and (list.override or path == "") and list[1] then
				local op = crafting(db, prof, list[1])
				if not op then return nil end
				local mn, mx = tonumber(op.minRestock), tonumber(op.maxRestock)
				if not mx then return nil end
				return { min = mn or 0, max = mx, op = list[1], group = group }
			end
			if path == "" then return nil end
			path = path:match("^(.*)" .. SEP .. "[^" .. SEP .. "]*$") or ""
		end
	end)
	return ok and r or nil
end
