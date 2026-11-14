-- Auctioning decisions by your groups' operations (TSM's Auctioning rules), with the whole Warband as
-- one seller, for Ready to post and the tooltip. Posting and cancelling are TSM's Auctioning tab.
--   * a listing the AH marks as yours (any character on the account) is never undercut: if yours
--     is the cheapest, a new post matches it
--   * every character's live auctions count toward an item's cap
-- Searches run on their own; every AH search answered is saved as a scan.
local _, CH = ...

local A = {}
CH.Auction = A

local DAY = 86400

-- Records are keyed by name and realm: two characters with the same name on different realms
-- are different sellers, and only this realm's auction house counts toward a cap here.
local function realm() return GetRealmName and GetRealmName() or "?" end
local function me() return (UnitName and UnitName("player") or "?") .. "-" .. realm() end

local function store()
	CH.db.auctions = CH.db.auctions or {}
	return CH.db.auctions
end

--- Your live auctions of an item across the Warband: this account's own record for each character
--- where there is one from the last two days, else TSM's count for that character.
function A.Listed(id)
	local n, counted = 0, {}
	local now = time()
	local here = realm()
	for key, rec in pairs(store()) do
		if rec.at and now - rec.at < 2 * DAY and rec.realm == here then
			counted[key] = true
			n = n + (rec.items[id] or 0)
		end
	end
	local db = type(TradeSkillMasterDB) == "table" and TradeSkillMasterDB
	if db and CH.Ledger then
		for _, c in ipairs(CH.Ledger.Characters()) do
			if not counted[c.name .. "-" .. here] then
				local t = db["s@" .. c.key .. "@internalData@auctionQuantity"]
				if type(t) == "table" then
					for s, q in pairs(t) do
						if tonumber(tostring(s):match("^i:(%d+)")) == id then n = n + (tonumber(q) or 0) end
					end
				end
			end
		end
	end
	return n
end

--- Listed (above) for every item at once: { [id] = units up }, one pass over the records rather
--- than one per item, for a list of thousands.
function A.ListedAll()
	local out, counted = {}, {}
	local now, here = time(), realm()
	for key, rec in pairs(store()) do
		if rec.at and now - rec.at < 2 * DAY and rec.realm == here then
			counted[key] = true
			for id, q in pairs(rec.items or {}) do out[id] = (out[id] or 0) + q end
		end
	end
	local db = type(TradeSkillMasterDB) == "table" and TradeSkillMasterDB
	if db and CH.Ledger then
		for _, c in ipairs(CH.Ledger.Characters()) do
			if not counted[c.name .. "-" .. here] then
				local t = db["s@" .. c.key .. "@internalData@auctionQuantity"]
				if type(t) == "table" then
					for str, q in pairs(t) do
						local id = tonumber(tostring(str):match("^i:(%d+)"))
						if id then out[id] = (out[id] or 0) + (tonumber(q) or 0) end
					end
				end
			end
		end
	end
	return out
end

--- Record this character's live auctions: { { id, qty } }.
function A.RecordOwned(list)
	local items = {}
	for _, a in ipairs(list) do items[a.id] = (items[a.id] or 0) + (a.qty or 1) end
	store()[me()] = { at = time(), items = items, realm = realm() }
	-- what's up today counts as a listed day for the demand estimate
	if CH.Demand then CH.Demand.MarkAll(items) end
end

-- Results: { { price (each), qty, mine } }, mine = yours or any character on your account.
local function lowest(results)
	local other, mine
	for _, r in ipairs(results or {}) do
		if r.mine then
			if not mine or r.price < mine then mine = r.price end
		elseif not other or r.price < other then
			other = r.price
		end
	end
	return other, mine
end
A.Lowest = lowest

--- What to do with an item you hold: { action = "post"|"skip", price, qty, why }.
--- results: the AH's listings for it; held: how many you have to post.
-- Remember whether someone outside the account was cheaper than your normal price, and who.
local function note(id, results, normal)
	if not (CH.Ledger and CH.Ledger.NoteCompetition) then return end
	local other, owners
	for _, r in ipairs(results or {}) do
		if not r.mine and (not other or r.price < other) then other, owners = r.price, r.owners end
	end
	CH.Ledger.NoteCompetition(id, other ~= nil and normal ~= nil and other < normal, owners)
end

-- The cheapest listing outside the account, and yours. With "ignore auctions below min" (TSM's
-- priceReset = "ignore"), listings under your min don't count as competition.
local function competition(results, p)
	if p.priceReset ~= "ignore" or not p.min then return lowest(results) end
	local kept = {}
	for _, r in ipairs(results or {}) do if r.mine or r.price >= p.min then kept[#kept + 1] = r end end
	return lowest(kept)
end

--- The price an operation posts an item at against these listings, before caps and bags:
--- { action = "post", price, why } or { action = "skip", why }. p: Groups.Prices.
function A.PostPrice(p, results)
	if not p.normal then return { action = "skip", why = "no price" } end
	local other, mine = competition(results, p)
	local price, why
	if not other then
		price, why = mine and math.min(mine, p.normal) or p.normal, mine and "matching your own listing" or "nobody else listed"
	else
		price, why = other - p.undercut, "undercutting the cheapest"
		if mine and mine <= other then price, why = mine, "yours is cheapest: matching it" end
		if p.min and price < p.min then
			-- below min: post at min, normal or max if the operation says so, else don't post
			local reset = p.priceReset
			if reset == "minPrice" or reset == "normalPrice" or reset == "maxPrice" then
				price, why = p[({ minPrice = "min", normalPrice = "normal", maxPrice = "max" })[reset]], "cheapest is under min: posting at " .. reset:gsub("Price", "")
			else
				return { action = "skip", why = string.format("cheapest is under your min (%s, %s)", CH.FormatMoney(p.min), p.why or "") }
			end
		end
	end
	if p.max and price > p.max then
		local above = p.aboveMax
		if above == "minPrice" or above == "normalPrice" then
			price, why = p[above == "minPrice" and "min" or "normal"], "above max: posting at " .. above:gsub("Price", "")
		elseif above == "none" then
			return { action = "skip", why = "above max: set not to post" }
		else
			price, why = p.max, "capped at max"
		end
	end
	if p.min and price < p.min then price = p.min end
	-- the AH only takes whole silver: round down, but never under your min
	price = math.floor(price / 100) * 100
	if p.min and price < p.min then price = math.ceil(p.min / 100) * 100 end
	price = math.max(100, price)
	return { action = "post", price = math.floor(price), why = why }
end

--- The one posting-rule check: what your operation allows for an item against these listings.
--- Trade's Ready to post and the AH panel both use it, so they can't disagree.
--- o: results (AH listings), held (how many you can post), listed (already up; default what the
--- AH panel counts), level (gear item level), note (remember the competition).
--- { action = "post"|"skip", price, qty, why, duration, kind = nil|"off"|"noprice"|"expired"|"min"|"max"|"full"|"keep"|"none" }
function A.Evaluate(id, o)
	o = o or {}
	local results, held, level = o.results or {}, o.held, o.level
	local p = CH.Groups.Prices(id, nil, level)
	if o.note then note(id, results, p.normal) end
	if not p.post then return { action = "skip", kind = "off", why = (p.op or "its operation") .. " doesn't post it" } end
	if not p.normal then return { action = "skip", kind = "noprice", why = "no price" } end
	if p.maxExpires and p.maxExpires > 0 and CH.Ledger and CH.Ledger.Available() then
		local n = CH.Ledger.NumExpires(id)
		if n >= p.maxExpires then
			return { action = "skip", kind = "expired", why = string.format("expired %d times since it last sold (max %d)", n, p.maxExpires) }
		end
	end
	local pp = A.PostPrice(p, results)
	if pp.action ~= "post" then
		pp.kind = pp.why and pp.why:find("^above max") and "max" or "min"
		return pp
	end
	local price, why = pp.price, pp.why
	local listed = o.listed or A.Listed(id)
	local room = (p.cap or 0) - listed
	if room <= 0 then return { action = "skip", kind = "full", price = price, why = string.format("Warband already has %d up (cap %d)", listed, p.cap or 0) } end
	local qty = math.min(room, held or room)
	if p.keep and p.keep > 0 and held then
		qty = math.min(qty, held - p.keep)
		if qty <= 0 then return { action = "skip", kind = "keep", price = price, why = string.format("keeping %d in bags", p.keep) } end
	end
	if qty <= 0 then return { action = "skip", kind = "none", price = price, why = "none in bags" } end
	if p.learned then why = why .. "; " .. p.learned end
	return { action = "post", price = math.floor(price), qty = qty, why = why, duration = p.duration }
end

function A.Decide(id, results, held, level)
	return A.Evaluate(id, { results = results, held = held, level = level, note = true })
end

--- The freshest listings there are for an item: your AH search in the last 15 minutes, else your
--- last AH scan, else none. Returns results ({ { price, qty } }), source ("ah"|"scan"|nil), age.
function A.Listings(id)
	local rows, src, a
	if CH.Depth then rows, src, a = CH.Depth.Book(id) end
	if rows and src == "ah" then
		local results = {}
		for _, r in ipairs(rows) do results[#results + 1] = { price = r[1], qty = r[2] } end
		return results, "ah", a
	end
	local sc = CH.Scans and CH.Scans.Get(id)
	if sc and sc.min then return { { price = sc.min, qty = 1 } }, "scan", sc.age end
	return nil
end

--- What the item's own operation would do right now, apart from any market estimate: its min,
--- normal and max, and the price it would post at against the freshest AH listings there are
--- (your AH search in the last 15 minutes, else your last AH scan, else none: posting at normal).
--- Caps and bags aren't counted: this is whether and where it posts, not how many.
--- { op, min, normal, max, action = "post"|"skip", price, why, source = "ah"|"scan"|nil, age, cheapest }
function A.PostCheck(id, level)
	if not id then return nil end
	local p = CH.Groups.Prices(id, nil, level)
	local out = { op = p.op or "Default", min = p.min, normal = p.normal, max = p.max }
	local results, source, age = A.Listings(id)
	out.source, out.age = source, age
	out.cheapest = results and results[1] and results[1].price or nil
	if not p.post then out.action, out.why = "skip", (p.op or "its operation") .. " doesn't post it"; return out end
	local pp = A.PostPrice(p, results or {})
	out.action, out.price, out.why = pp.action, pp.price, pp.why
	return out
end

-- The game side --------------------------------------------------------------------------------
local AH = C_AuctionHouse

-- Gear (weapons, armour, profession tools) lists on the AH by item level, and each rank of a
-- crafted rod or tool is its own item level: its level, or nil for anything else.
local GEAR = { [2] = true, [4] = true, [19] = true }
function A.Level(id, link)
	if not (id and link and C_Item and C_Item.GetItemInfoInstant and C_Item.GetDetailedItemLevelInfo) then return nil end
	local classID = select(6, C_Item.GetItemInfoInstant(id))
	if not GEAR[classID] then return nil end
	local level = C_Item.GetDetailedItemLevelInfo(link)
	return level and level > 0 and level or nil
end

-- Bag slots holding an item (at one item level, if given): { { bag, slot, count } }.
function A.BagSlots(id, level)
	local out = {}
	if not C_Container then return out end
	for bag = 0, (NUM_BAG_SLOTS or 4) + 1 do
		for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.itemID == id and not info.isBound and (not level or A.Level(id, info.hyperlink) == level) then
				table.insert(out, { bag = bag, slot = slot, count = info.stackCount or 1 })
			end
		end
	end
	return out
end

-- Items in your bags that belong to a group: { [id] = count }, and the same split by item level
-- for gear: { { id, level (nil if not gear), count } }, by item then level.
function A.Postable()
	local out, byKey, list = {}, {}, {}
	if not C_Container then return out, list end
	for bag = 0, (NUM_BAG_SLOTS or 4) + 1 do
		for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			local level = info and info.itemID and A.Level(info.itemID, info.hyperlink)
			if info and info.itemID and not info.isBound and CH.Groups.Path(info.itemID, level) then
				local id, n = info.itemID, info.stackCount or 1
				out[id] = (out[id] or 0) + n
				local key = id .. ":" .. (level or 0)
				if not byKey[key] then byKey[key] = { id = id, level = level, count = 0 }; table.insert(list, byKey[key]) end
				byKey[key].count = byKey[key].count + n
			end
		end
	end
	table.sort(list, function(a, b) if a.id ~= b.id then return a.id < b.id end return (a.level or 0) > (b.level or 0) end)
	return out, list
end

local function isCommodity(id, level)
	local slots = A.BagSlots(id, level)
	if not slots[1] or not ItemLocation then
		-- none in your bags to ask about: gear (an item level, or a weapon or armor) is never a commodity
		if level then return false end
		local classID = select(6, (C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant or function() end)(id))
		if classID == 2 or classID == 4 then return false end
		return true
	end
	local loc = ItemLocation:CreateFromBagAndSlot(slots[1].bag, slots[1].slot)
	return AH.GetItemCommodityStatus(loc) == Enum.ItemCommodityStatus.Commodity
end

A.IsCommodity = isCommodity

-- Search one item (gear at one item level); calls back with its results once the AH answers (or
-- after 3 seconds).
local waiting
function A.Search(id, done, level)
	if not AH then return done({}) end
	local key = AH.MakeItemKey(id, level)
	waiting = { id = id, key = key, done = done, commodity = isCommodity(id, level), level = level }
	AH.SendSearchQuery(key, { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }, true)
	local w = waiting
	C_Timer.After(3, function() if waiting == w then waiting = nil; done(A.Results(id, key, w.commodity)) end end)
end

--- The AH's listings for an item as { price, qty, mine }.
function A.Results(id, key, commodity)
	local out = {}
	if commodity then
		for i = 1, AH.GetNumCommoditySearchResults(id) or 0 do
			local r = AH.GetCommoditySearchResultInfo(id, i)
			if r then table.insert(out, { price = r.unitPrice, qty = r.quantity, mine = r.containsOwnerItem or r.containsAccountItem }) end
		end
	else
		for i = 1, AH.GetNumItemSearchResults(key) or 0 do
			local r = AH.GetItemSearchResultInfo(key, i)
			if r and r.buyoutAmount then
				table.insert(out, { price = r.buyoutAmount, qty = r.quantity or 1, mine = r.containsOwnerItem or r.containsAccountItem, owners = r.owners })
			end
		end
	end
	return out
end

local function answered(id, level)
	if waiting and waiting.id == id and (not level or not waiting.level or level == waiting.level) then
		local w = waiting
		waiting = nil
		w.done(A.Results(w.id, w.key, w.commodity))
	end
end
-- Every search answered in the AH window (AuctionIQ's, yours or TSM's) is saved as a scan
-- (Scans.lua) and kept for pricing big buys (Depth.lua), then handed to a waiting A.Search.
CH.On("COMMODITY_SEARCH_RESULTS_UPDATED", function(_, id)
	if not id then return end
	local res = A.Results(id, nil, true)
	CH.Depth.Remember(id, res)
	CH.Scans.Record(id, res, true)
	answered(id)
end)
CH.On("ITEM_SEARCH_RESULTS_UPDATED", function(_, key)
	local id = key and key.itemID
	if not id then return end
	-- a search at one item level is that rank's price: don't save it as the item's scan
	if not (key.itemLevel and key.itemLevel > 0) then CH.Scans.Record(id, A.Results(id, key, false), false) end
	answered(id, key.itemLevel and key.itemLevel > 0 and key.itemLevel or nil)
end)

--- How many of an item are in your bags (unbound), at one item level if given.
function A.InBags(id, level)
	local n = 0
	for _, s in ipairs(A.BagSlots(id, level)) do n = n + (s.count or 1) end
	return n
end

--- Ask the AH for your auctions; calls back with { { auctionID, id, qty, price } }.
local ownedDone
function A.QueryOwned(done)
	ownedDone = done
	AH.QueryOwnedAuctions({})
end
CH.On("OWNED_AUCTIONS_UPDATED", function()
	local list = {}
	for i = 1, AH.GetNumOwnedAuctions() or 0 do
		local a = AH.GetOwnedAuctionInfo(i)
		if a and a.status == 0 and a.itemKey then
			local lvl = a.itemKey.itemLevel
			table.insert(list, { auctionID = a.auctionID, id = a.itemKey.itemID, qty = a.quantity or 1, price = a.buyoutAmount or a.bidAmount,
				level = lvl and lvl > 0 and GEAR[select(6, C_Item.GetItemInfoInstant(a.itemKey.itemID)) or 0] and lvl or nil })
		end
	end
	A.RecordOwned(list)
	if ownedDone then local f = ownedDone; ownedDone = nil; f(list) end
end)
