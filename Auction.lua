-- Auctioning: post and cancel by your groups' operations, with the whole Warband as one seller.
--   * a listing the AH marks as yours (any character on the account) is never undercut: if yours
--     is the cheapest, a new post matches it
--   * every character's live auctions count toward an item's cap
--   * the cancel scan only reposts when someone outside your account is cheaper
-- Posting and cancelling take one click each (a Blizzard rule); searching runs on its own.
local _, CH = ...

local A = {}
CH.Auction = A

local DAY = 86400

local function me() return (UnitName and UnitName("player") or "?") end

local function store()
	CH.db.auctions = CH.db.auctions or {}
	return CH.db.auctions
end

--- Your live auctions of an item across the Warband: this account's own record for each character
--- where there is one from the last two days, else TSM's count for that character.
function A.Listed(id)
	local n, counted = 0, {}
	local now = time()
	for name, rec in pairs(store()) do
		if rec.at and now - rec.at < 2 * DAY then
			counted[name] = true
			n = n + (rec.items[id] or 0)
		end
	end
	local db = type(TradeSkillMasterDB) == "table" and TradeSkillMasterDB
	if db and CH.Ledger then
		for _, c in ipairs(CH.Ledger.Characters()) do
			if not counted[c.name] then
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

--- Record this character's live auctions: { { id, qty } }.
function A.RecordOwned(list)
	local items = {}
	for _, a in ipairs(list) do items[a.id] = (items[a.id] or 0) + (a.qty or 1) end
	store()[me()] = { at = time(), items = items }
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

function A.Decide(id, results, held)
	local p = CH.Groups.Prices(id)
	note(id, results, p.normal)
	if not p.post then return { action = "skip", why = p.tsm and (p.why or "TSM doesn't post it") or "its group doesn't post" } end
	if not p.normal then return { action = "skip", why = "no price" } end
	local other, mine = lowest(results)
	local price, why
	if not other then
		price, why = mine and math.min(mine, p.normal) or p.normal, mine and "matching your own listing" or "nobody else listed"
	else
		price, why = other - p.undercut, "undercutting the cheapest"
		if mine and mine <= other then price, why = mine, "yours is cheapest: matching it" end
		if p.min and price < p.min then
			-- TSM's "below minimum" setting; without TSM rules (or set to don't post) it skips
			local reset = p.priceReset
			if reset == "minPrice" or reset == "normalPrice" or reset == "maxPrice" then
				price, why = p[({ minPrice = "min", normalPrice = "normal", maxPrice = "max" })[reset]], "under min: TSM resets to " .. reset
			else
				return { action = "skip", why = string.format("cheapest is under your min (%s, %s)", CH.FormatMoney(p.min), p.why or "") }
			end
		end
	end
	if p.max and price > p.max then
		local above = p.aboveMax
		if above == "minPrice" or above == "normalPrice" then
			price, why = p[above == "minPrice" and "min" or "normal"], "above max: TSM posts at " .. above
		elseif above == "none" then
			return { action = "skip", why = "above max (TSM: don't post)" }
		else
			price, why = p.max, "capped at max"
		end
	end
	if p.min and price < p.min then price = p.min end
	-- the AH only takes whole silver: round down, but never under your min
	price = math.floor(price / 100) * 100
	if p.min and price < p.min then price = math.ceil(p.min / 100) * 100 end
	price = math.max(100, price)
	local room = p.cap - A.Listed(id)
	if room <= 0 then return { action = "skip", why = string.format("Warband already has %d up (cap %d)", A.Listed(id), p.cap) } end
	local qty = math.min(room, held or room)
	if p.keep and p.keep > 0 and held then
		qty = math.min(qty, held - p.keep)
		if qty <= 0 then return { action = "skip", why = string.format("keeping %d (TSM keep quantity)", p.keep) } end
	end
	if qty <= 0 then return { action = "skip", why = "none in bags" } end
	return { action = "post", price = math.floor(price), qty = qty, why = why, duration = p.duration }
end

--- Whether to cancel one of your auctions: { action = "cancel"|"keep", why }.
function A.DecideCancel(id, price, results)
	local p = CH.Groups.Prices(id)
	local other = lowest(results)
	if not other or other >= price then return { action = "keep", why = "still cheapest outside your account" } end
	local repost = other - p.undercut
	if p.min and repost < p.min then return { action = "keep", why = "beating them would go under your min" } end
	return { action = "cancel", why = string.format("undercut: %s vs your %s", CH.FormatMoney(other), CH.FormatMoney(price)) }
end

-- The game side --------------------------------------------------------------------------------
local AH = C_AuctionHouse

-- Bag slots holding an item: { { bag, slot, count } }.
function A.BagSlots(id)
	local out = {}
	if not C_Container then return out end
	for bag = 0, (NUM_BAG_SLOTS or 4) + 1 do
		for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.itemID == id and not info.isBound then table.insert(out, { bag = bag, slot = slot, count = info.stackCount or 1 }) end
		end
	end
	return out
end

-- Items in your bags that belong to a group: { [id] = count }.
function A.Postable()
	local out = {}
	if not C_Container then return out end
	for bag = 0, (NUM_BAG_SLOTS or 4) + 1 do
		for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.itemID and not info.isBound and CH.Groups.Path(info.itemID) then
				out[info.itemID] = (out[info.itemID] or 0) + (info.stackCount or 1)
			end
		end
	end
	return out
end

local function isCommodity(id)
	local slots = A.BagSlots(id)
	if not slots[1] or not ItemLocation then return true end
	local loc = ItemLocation:CreateFromBagAndSlot(slots[1].bag, slots[1].slot)
	return AH.GetItemCommodityStatus(loc) == Enum.ItemCommodityStatus.Commodity
end

-- Search one item; calls back with its results once the AH answers (or after 3 seconds).
local waiting
function A.Search(id, done)
	if not AH then return done({}) end
	local key = AH.MakeItemKey(id)
	waiting = { id = id, key = key, done = done, commodity = isCommodity(id) }
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

local function answered(id)
	if waiting and waiting.id == id then
		local w = waiting
		waiting = nil
		w.done(A.Results(w.id, w.key, w.commodity))
	end
end
CH.On("COMMODITY_SEARCH_RESULTS_UPDATED", function(id) answered(id) end)
CH.On("ITEM_SEARCH_RESULTS_UPDATED", function(key) answered(key and key.itemID) end)

--- How many of an item are in your bags (unbound).
function A.InBags(id)
	local n = 0
	for _, s in ipairs(A.BagSlots(id)) do n = n + (s.count or 1) end
	return n
end

--- Post one decision (must run from a click). Sends it and returns how many it asked to list, or
--- nil when there is nothing to post. Whether the AH took it comes back as an event (see AuctionUI).
function A.Post(id, d)
	local slots = A.BagSlots(id)
	if not slots[1] or not ItemLocation then return nil end
	local loc = ItemLocation:CreateFromBagAndSlot(slots[1].bag, slots[1].slot)
	local price = math.max(100, math.floor(d.price / 100) * 100)
	if isCommodity(id) then
		AH.PostCommodity(loc, d.duration, d.qty, price)
		return d.qty
	end
	AH.PostItem(loc, d.duration, 1, nil, price)
	return 1
end

--- Count a post the AH confirmed toward this character's live auctions.
function A.Posted(id, n)
	local rec = store()[me()] or { at = time(), items = {} }
	rec.items[id] = (rec.items[id] or 0) + n
	rec.at = rec.at or time()
	store()[me()] = rec
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
			table.insert(list, { auctionID = a.auctionID, id = a.itemKey.itemID, qty = a.quantity or 1, price = a.buyoutAmount or a.bidAmount })
		end
	end
	A.RecordOwned(list)
	if ownedDone then local f = ownedDone; ownedDone = nil; f(list) end
end)
