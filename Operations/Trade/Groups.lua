-- Groups and operations: which items AuctionIQ posts, buys or mails, and how. Built for you from
-- what you craft, use and resell (re-run any time), falling back to your TSM groups (read only).
-- Move an item yourself and that sticks. Each group's operation sets the posting prices:
--   min    never post below it: crafted goods at what they cost to make after the cut, resale at
--          what you paid after the cut, anything else at 80% of its buy price
--   normal post here when nobody is cheaper: AuctionIQ value
--   max    never post above it: 3x normal
-- and how many to keep up across the whole Warband (stock target, else a cap).
local _, CH = ...

local G = {}
CH.Groups = G

local SEP = "/"
G.SEP = SEP

-- Operations: fields
--   post (false = never post), undercut (copper), duration (1 = 12h, 2 = 24h, 3 = 48h), cap (nil = par),
--   floor ("cost", "paid" or "market"), floorPct, maxMult
G.DEFAULT_OPS = {
	Crafted = { post = true, undercut = 1, duration = 3, floor = "cost", floorPct = 1.0, maxMult = 3 },
	Resale = { post = true, undercut = 1, duration = 3, floor = "paid", floorPct = 1.1, maxMult = 3 },
	Reagents = { post = false, undercut = 1, duration = 2, floor = "market", floorPct = 0.9, maxMult = 3 },
	Default = { post = true, undercut = 1, duration = 2, floor = "market", floorPct = 0.8, maxMult = 3, cap = 5 },
}

local function store()
	CH.db.groups = CH.db.groups or {}
	local s = CH.db.groups
	s.auto = s.auto or {}
	s.manual = s.manual or {}
	s.ops = s.ops or {}
	s.assign = s.assign or {} -- [path] = operation name, inherited by sub-groups
	for k, v in pairs(G.DEFAULT_OPS) do
		if not s.ops[k] then local c = {}; for f, x in pairs(v) do c[f] = x end; s.ops[k] = c end
	end
	if s.useTSM == nil then s.useTSM = true end
	return s
end
G.Store = store

-- TSM's current profile name, or nil.
local function tsmProfile(db)
	local cur = db["_currentProfile"]
	if type(cur) ~= "table" then return nil end
	local me = (UnitName and UnitName("player") or "") .. " - " .. (GetRealmName and GetRealmName() or "")
	if cur[me] then return cur[me] end
	for _, p in pairs(cur) do return p end
end

-- TSM's groups for the current profile, read only. TSM assigns an item string, and two variants of
-- one item (gear at two item levels, "i:ID::iLEVEL") can sit in different groups, so each string is
-- kept as it is (byString). byID is the fallback for a lookup without a variant: the explicit
-- base-item entry ("i:ID") if TSM has one, else the variants' group when they all agree, else none
-- (conflicts[id] = true: the item level decides).
local tsmCache, tsmByString, tsmConflicts
-- "i:123::i645" stays as it is; any other variant ("i:123:0:2:...") is kept by its exact string too.
local function baseID(itemString) return tonumber(tostring(itemString):match("^i:(%d+)")) end
local function tsmPath(path) return "TSM" .. SEP .. path:gsub("`", SEP) end
local function readTSM()
	if tsmCache then return end
	tsmCache, tsmByString, tsmConflicts = {}, {}, {}
	local db = TradeSkillMasterDB
	if type(db) ~= "table" then return end
	local profile = tsmProfile(db)
	local items = profile and db["p@" .. profile .. "@userData@items"]
	if type(items) ~= "table" then return end
	local variants = {} -- [id] = path shared by every variant, or false when they differ
	for itemString, path in pairs(items) do
		local str, id = tostring(itemString), baseID(itemString)
		if id and type(path) == "string" and path ~= "" then
			local full = tsmPath(path)
			tsmByString[str] = full
			if str == "i:" .. id then
				tsmCache[id] = full
			elseif variants[id] == nil then variants[id] = full
			elseif variants[id] ~= full then variants[id] = false end
		end
	end
	for id, v in pairs(variants) do
		if not tsmCache[id] then
			if v then tsmCache[id] = v else tsmConflicts[id] = true end
		end
	end
end

--- TSM's groups by base item: { [itemID] = "TSM/A/B" } (see readTSM for variants).
function G.TSMGroups() readTSM(); return tsmCache end

--- TSM's groups by its own item strings: { ["i:ID" or "i:ID::iLEVEL" ...] = "TSM/A/B" }.
function G.TSMGroupsByString() readTSM(); return tsmByString end

--- TSM's group for one item, at one item level if given: that variant's own group first, then the
--- base item's (nil when only other variants are grouped and they disagree).
function G.TSMPath(id, level)
	readTSM()
	if not id then return nil end
	if level then
		local v = tsmByString["i:" .. id .. "::i" .. level]
		if v then return v end
	end
	return tsmCache[id]
end

--- Forget the TSM groups read so far (they're read once per session).
function G.ResetTSM() tsmCache, tsmByString, tsmConflicts = nil, nil, nil end

-- TSM's operation fields, copied into AuctionIQ's own operations.
local function num(v) return tonumber(v) end

-- What an imported operation does differently from TSM, one line per setting: { "bid at 80% of buyout" }.
local function unsupported(op)
	local out = {}
	local bid = num(op.bidPercent)
	if bid and bid < 1 then table.insert(out, string.format("bid at %d%% of buyout (AuctionIQ posts buyout only)", math.floor(bid * 100 + 0.5))) end
	local low = num(op.ignoreLowDuration)
	if low and low > 0 then table.insert(out, "ignoring auctions by time left (every listing counts here)") end
	if type(op.blacklist) == "string" and op.blacklist:match("%S") then table.insert(out, "blacklisted sellers (undercut like anyone else here)") end
	if type(op.keepQtySources) == "table" and next(op.keepQtySources) then table.insert(out, "amount kept counts bank or other sources (bags only here)") end
	if type(op.ignoreFactionrealm) == "table" and next(op.ignoreFactionrealm) then table.insert(out, "ignored on some realms (applies everywhere here)") end
	return out
end
G.Unsupported = unsupported

-- TSM keeps operations per group in order; "ignore operation on characters" skips one for some
-- characters. Whether an operation applies to the character you're on now.
local function appliesHere(op)
	local ig = op and op.ignorePlayer
	if type(ig) ~= "table" or not next(ig) then return true end
	local name = UnitName and UnitName("player") or ""
	local realm = GetRealmName and GetRealmName() or ""
	for key, on in pairs(ig) do
		local k = tostring(key)
		if on and k:find(name, 1, true) == 1 and (realm == "" or k:find(realm, 1, true)) then return false end
	end
	return true
end

--- Copy TSM's auctioning setup into AuctionIQ, once (TSM's data is only read):
---   * each Auctioning operation becomes an AuctionIQ operation of the same name with the same
---     formulas and settings (min, normal, max, undercut, post cap, keep, max expires, below min,
---     above max, duration) and canceling rules (cancel undercut, cancel to repost higher and its
---     threshold)
---   * TSM's custom price sources become AuctionIQ's (see Formula.lua)
---   * each TSM group that sets its own operations gets them here too, in TSM's order, and TSM's
---     groups win over the automatic ones, so items post as TSM would. The first operation that
---     applies to the character prices, posts and cancels (as TSM's aucopmin/normal/max read it)
---   * settings AuctionIQ can't follow are reported, so you know where it will act differently
--- After this nothing needs TSM: change the operations here and they stay yours.
---   * TSM's Crafting operations (min and max restock, minimum profit) and Shopping operations
---     (maximum price) become the craft queue's and shopping list's rules (see CraftRule, ShopRule)
--- Returns { ops, sources, groups, multi, unsupported = { [op] = { why } }, conflicts, craftOps,
--- shopOps }, or nil and why.
function G.ImportTSM()
	local db = TradeSkillMasterDB
	if type(db) ~= "table" then return nil, "TSM's saved data isn't loaded" end
	local profile = tsmProfile(db)
	local s = store()
	s.assignAll = s.assignAll or {}
	local n = { ops = 0, sources = 0, groups = 0, multi = 0, unsupported = {}, conflicts = 0 }
	local function opsFrom(t)
		if type(t) ~= "table" or type(t.Auctioning) ~= "table" then return end
		for name, op in pairs(t.Auctioning) do
			if type(op) == "table" then
				local cap = num(op.postCap)
				local ignore = {}
				if type(op.ignorePlayer) == "table" then for k, v in pairs(op.ignorePlayer) do ignore[k] = v end end
				s.ops[name] = {
					post = cap ~= 0, imported = "TSM",
					minPrice = op.minPrice, normalPrice = op.normalPrice, maxPrice = op.maxPrice,
					undercut = op.undercut or 0, cap = cap, keepQuantity = num(op.keepQuantity) or 0,
					maxExpires = num(op.maxExpires) or 0, priceReset = op.priceReset or "none",
					aboveMax = op.aboveMax or "maxPrice", duration = num(op.duration) or 2,
					-- TSM's defaults: cancel when undercut, and cancel to repost higher by 1g or more
					cancelUndercut = op.cancelUndercut ~= false, cancelRepost = op.cancelRepost ~= false,
					cancelRepostThreshold = op.cancelRepostThreshold or "1g",
					ignorePlayer = next(ignore) and ignore or nil,
					floor = "market", floorPct = 1, maxMult = 3, learn = false,
				}
				local u = unsupported(op)
				if #u > 0 then n.unsupported[name] = u end
				n.ops = n.ops + 1
			end
		end
	end
	opsFrom(db["g@ @userData@sharedOperations"])
	opsFrom(profile and db["p@" .. profile .. "@userData@operations"])
	local custom = db["g@ @userData@customPriceSources"]
	if type(custom) == "table" then
		local mine = CH.Formula.Custom()
		for k, v in pairs(custom) do
			if type(v) == "string" then mine[tostring(k):lower()] = v; n.sources = n.sources + 1 end
		end
	end
	local groups = profile and db["p@" .. profile .. "@userData@groups"]
	if type(groups) == "table" then
		for path, g in pairs(groups) do
			local a = type(g) == "table" and g.Auctioning
			if type(a) == "table" and a[1] and (a.override or path == "") then
				local here = path == "" and "TSM" or tsmPath(path)
				local list = {}
				for _, name in ipairs(a) do list[#list + 1] = name end
				s.assign[here], s.assignAll[here] = list[1], list
				if #list > 1 then n.multi = n.multi + 1 end
				n.groups = n.groups + 1
			end
		end
	end
	-- TSM's Crafting operations (restock between min and max, minimum profit) and Shopping
	-- operations (the most to pay), with each group's own, in TSM's order
	s.craftOps, s.shopOps, s.craftAssign, s.shopAssign = s.craftOps or {}, s.shopOps or {}, {}, {}
	n.craftOps, n.shopOps = 0, 0
	local function otherOps(t)
		if type(t) ~= "table" then return end
		for name, op in pairs(type(t.Crafting) == "table" and t.Crafting or {}) do
			if type(op) == "table" then
				local minProfit = op.minProfit
				if minProfit == "" or op.minProfitEnabled == false then minProfit = nil end
				s.craftOps[name] = { imported = "TSM", minRestock = op.minRestock or 1, maxRestock = op.maxRestock or 3,
					minProfit = minProfit, ignorePlayer = type(op.ignorePlayer) == "table" and next(op.ignorePlayer) and op.ignorePlayer or nil }
				if type(op.craftPriceMethod) == "string" and op.craftPriceMethod ~= "" then
					local k = "Crafting " .. name
					n.unsupported[k] = n.unsupported[k] or {}
					table.insert(n.unsupported[k], "its own crafted value (AuctionIQ values by chvalue)")
				end
				n.craftOps = n.craftOps + 1
			end
		end
		for name, op in pairs(type(t.Shopping) == "table" and t.Shopping or {}) do
			if type(op) == "table" then
				s.shopOps[name] = { imported = "TSM", maxPrice = op.maxPrice, showAbove = op.showAboveMaxPrice ~= false,
					ignorePlayer = type(op.ignorePlayer) == "table" and next(op.ignorePlayer) and op.ignorePlayer or nil }
				if num(op.restockQuantity) and num(op.restockQuantity) > 0 then
					local k = "Shopping " .. name
					n.unsupported[k] = n.unsupported[k] or {}
					table.insert(n.unsupported[k], "restock quantity (the shopping list buys what the craft queue needs)")
				end
				n.shopOps = n.shopOps + 1
			end
		end
	end
	otherOps(db["g@ @userData@sharedOperations"])
	otherOps(profile and db["p@" .. profile .. "@userData@operations"])
	if type(groups) == "table" then
		for path, g in pairs(groups) do
			-- TSM's Crafting and Shopping operations don't work on the base group
			if path ~= "" and type(g) == "table" then
				for kind, into in pairs({ Crafting = s.craftAssign, Shopping = s.shopAssign }) do
					local a = g[kind]
					if type(a) == "table" and a[1] and a.override then
						local list = {}
						for _, name in ipairs(a) do list[#list + 1] = name end
						into[tsmPath(path)] = list
					end
				end
			end
		end
	end
	s.useTSM, s.preferTSM = true, true
	G.ResetTSM()
	readTSM()
	for _ in pairs(tsmConflicts) do n.conflicts = n.conflicts + 1 end
	return n
end

--- One line for chat on what an import copied and where AuctionIQ will act differently from TSM.
function G.ImportSummary(n)
	local head = string.format("%d operations, %d price sources, %d groups", n.ops, n.sources, n.groups)
	if (n.craftOps or 0) + (n.shopOps or 0) > 0 then
		head = head .. string.format(", %d crafting and %d shopping operations", n.craftOps or 0, n.shopOps or 0)
	end
	local lines = {}
	if (n.multi or 0) > 0 then
		table.insert(lines, string.format("%d groups have more than one operation: kept in TSM's order, the first that applies to the character is used", n.multi))
	end
	if (n.conflicts or 0) > 0 then
		table.insert(lines, string.format("%d items have variants in different groups: each item level follows its own group", n.conflicts))
	end
	local names = {}
	for name in pairs(n.unsupported or {}) do names[#names + 1] = name end
	table.sort(names)
	for _, name in ipairs(names) do
		table.insert(lines, name .. " differs from TSM: " .. table.concat(n.unsupported[name], "; "))
	end
	return head, lines
end

--- Rebuild the automatic groups from your scans and TSM's records:
---   Crafted/<profession>/<line>, Reagents/<profession>, Resale. Returns how many items it placed.
function G.Rebuild()
	local s = store()
	local auto, n = {}, 0
	local function put(id, path) if id and not auto[id] then auto[id] = path; n = n + 1 end end
	for _, c in pairs(CH.db.characters or {}) do
		for _, p in pairs(c.professions or {}) do
			for _, r in ipairs(p.scan and p.scan.rows or {}) do
				local line = CH.Paths and CH.Paths.MainGroup and CH.Paths.MainGroup(r.name) or "Other"
				local path = "Crafted" .. SEP .. (p.name or "?") .. SEP .. line
				put(r.item, path)
				put(r.concItem, path)
			end
		end
	end
	for _, c in pairs(CH.db.characters or {}) do
		for _, p in pairs(c.professions or {}) do
			for _, r in ipairs(p.scan and p.scan.rows or {}) do
				for _, acc in ipairs({ r.accounts or {}, r.concAccounts or {} }) do
					for _, rg in ipairs(acc.reagents or {}) do put(rg.itemID, "Reagents" .. SEP .. (p.name or "?")) end
				end
			end
		end
	end
	if CH.Ledger and CH.Ledger.Available() then
		local paid, sold = CH.Ledger.Paid(), CH.Ledger.LastSold()
		for id in pairs(paid) do if sold[id] then put(id, "Resale") end end
	end
	s.auto = auto
	return n
end

--- An item's group: yours if you moved it, else the automatic one, else TSM's (if used). After an
--- import from TSM, TSM's groups come before the automatic ones. level: gear at that item level,
--- which TSM may group apart from the item's other levels.
function G.Path(id, level)
	local s = store()
	local tsm = s.useTSM and G.TSMPath(id, level) or nil
	if s.manual[id] then return s.manual[id] end
	if s.preferTSM and tsm then return tsm end
	return s.auto[id] or tsm
end

-- Every grouped item and its group, by the same order as Path.
local function members()
	local s, out = store(), {}
	if s.useTSM then
		for id, p in pairs(G.TSMGroups()) do out[id] = p end
		-- a variant grouped apart from its base item counts in its own group too
		for str, p in pairs(G.TSMGroupsByString()) do
			local id = baseID(str)
			if id and str ~= "i:" .. id and out[id] ~= p and not s.manual[id] then out[str] = p end
		end
	end
	for id, p in pairs(s.auto) do if not (s.preferTSM and out[id]) then out[id] = p end end
	for id, p in pairs(s.manual) do out[id] = p end
	return out
end

--- Every grouped item and its group: { [id or item string] = path }.
G.Members = members

--- Put an item in a group yourself (path), or back to automatic (nil).
function G.Move(id, path) store().manual[id] = path; if CH.Market then CH.Market.Clear() end end

--- Every group with its item count (sub-groups included), sorted: { path, n, own }.
function G.Tree()
	local counts = {}
	local s = store()
	local function count(path)
		local acc = ""
		for part in string.gmatch(path, "[^" .. SEP .. "]+") do
			acc = acc == "" and part or (acc .. SEP .. part)
			counts[acc] = (counts[acc] or 0) + 1
		end
	end
	for _, p in pairs(members()) do count(p) end
	local out = {}
	for path, n in pairs(counts) do
		local _, depth = path:gsub(SEP, "")
		table.insert(out, { path = path, n = n, depth = depth, name = path:match("([^" .. SEP .. "]+)$") })
	end
	table.sort(out, function(a, b) return a.path < b.path end)
	return out
end

--- Items in a group and its sub-groups.
function G.Items(path)
	local out = {}
	local function want(p) return p == path or p:sub(1, #path + 1) == path .. SEP end
	local seen = {}
	for key, p in pairs(members()) do
		local id = type(key) == "number" and key or baseID(key)
		if id and want(p) and not seen[id] then seen[id] = true; table.insert(out, id) end
	end
	table.sort(out)
	return out
end

--- The operation for an item (at an item level): the group's own, else its parent's, else by
--- top-level group. A group with several operations (from TSM) uses the first, in order, that
--- applies to the character you're on.
function G.Operation(id, level)
	local s = store()
	local path = G.Path(id, level)
	if not path then return nil end
	local p = path
	while p do
		local list = s.assignAll and s.assignAll[p]
		-- the ordered list only stands while the group's first operation is still the imported one
		if list and list[1] == s.assign[p] then
			for _, name in ipairs(list) do
				local op = s.ops[name]
				if op and appliesHere(op) then return op, name end
			end
		end
		if s.assign[p] then return s.ops[s.assign[p]], s.assign[p] end
		p = p:match("^(.*)" .. SEP .. "[^" .. SEP .. "]+$")
	end
	local top = path:match("^([^" .. SEP .. "]+)")
	local name = (top == "Crafted" or top == "Resale" or top == "Reagents") and top or "Default"
	return s.ops[name], name
end

-- The first operation of a kind that applies here, from the item's group or the nearest parent
-- that sets one: op, name. assign: { [path] = { names in order } }, ops: { [name] = op }.
-- These come from TSM, so they follow the item's TSM group even if you moved it here.
local function ruleFor(id, level, assign, ops)
	local path = G.TSMPath(id, level)
	while path do
		local list = assign and assign[path]
		if list then
			for _, name in ipairs(list) do
				local op = ops and ops[name]
				if op and appliesHere(op) then return op, name end
			end
		end
		path = path:match("^(.*)" .. SEP .. "[^" .. SEP .. "]+$")
	end
end

--- The craft queue's rule for an item, from its TSM Crafting operation: { op, minRestock, maxRestock,
--- minProfit (copper, nil = none) }, or nil. Restock: queue up to maxRestock held across the
--- warband, and nothing when that's fewer than minRestock. minProfit: per item made.
function G.CraftRule(id, level)
	local s = store()
	local op, name = ruleFor(id, level, s.craftAssign, s.craftOps)
	if not op then return nil end
	local F = CH.Formula
	local function v(x) return type(x) == "number" and x or (x and F.Value(x, id, nil, level)) end
	local minR, maxR = v(op.minRestock), v(op.maxRestock)
	return { op = name, minRestock = math.max(0, math.floor(minR or 1)), maxRestock = math.max(0, math.floor(maxR or 0)),
		minProfit = op.minProfit and v(op.minProfit) or nil }
end

--- The shopping list's rule for an item, from its TSM Shopping operation: { op, maxPrice (copper),
--- showAbove }, or nil.
function G.ShopRule(id, level)
	local s = store()
	local op, name = ruleFor(id, level, s.shopAssign, s.shopOps)
	if not op then return nil end
	local mp = op.maxPrice
	mp = type(mp) == "number" and mp or (mp and CH.Formula.Value(mp, id, nil, level))
	return { op = name, maxPrice = mp, showAbove = op.showAbove ~= false }
end

function G.Assign(path, opName)
	local s = store()
	s.assign[path] = opName
	if s.assignAll then s.assignAll[path] = nil end -- your choice replaces TSM's list
end

-- What making one costs, from the newest scan that makes it.
local function costEach(id)
	local _, acc = CH.CraftAccounts(id)
	if not acc then return nil end
	local paid = CH.Ledger and CH.Ledger.Available() and CH.Ledger.Paid() or {}
	return CH.Ledger and CH.Ledger.CostAtPaid(acc, paid) or nil
end

G.CostEach = costEach

--- How sales have gone lately, as a factor for the normal price and why. The sell-through rate is a
--- Beta belief (Prob.SellThrough) that starts at the region's sale rate and moves toward your own
--- last 30 days (Ledger.SellThrough: the share of units sold, counted once per day with a sale or
--- an expiry). The price goes up (to +5%) only when it is likely that 80%+ of
--- posts sell, and down (to -10%) only when it is likely that under 40% do; the step grows with how
--- sure it is. Otherwise 1 (no change).
function G.Learn(id)
	if not (CH.Ledger and CH.Ledger.Available()) then return 1 end
	local sold, expired, detail = CH.Ledger.SellThrough(id)
	if sold + expired == 0 then return 1 end
	local st = CH.Prob.SellThrough(sold, expired, CH.Expect and CH.Expect.RegionRate(id) or 0.5)
	local f, sure = 1, nil
	if st.pUp > 0.6 then f, sure = 1 + 0.05 * (st.pUp - 0.6) / 0.4, st.pUp
	elseif st.pDown > 0.6 then f, sure = 1 - 0.10 * (st.pDown - 0.6) / 0.4, st.pDown end
	f = math.floor(f * 200 + 0.5) / 200 -- half-percent steps
	if f == 1 then return 1 end
	local what = detail and string.format("%d sold, %d expired over %d day%s", detail.sold, detail.expired, detail.days, detail.days == 1 and "" or "s")
		or string.format("%.0f sold, %.0f expired", sold, expired)
	return f, string.format("sells %d%% of posts (%s), %d%% sure: %+.1f%%", math.floor(st.mean * 100 + 0.5),
		what, math.floor(sure * 100 + 0.5), (f - 1) * 100)
end

--- Posting prices and rules for an item: { min, normal, max, cap, undercut, duration, post, op, why,
--- keep, maxExpires, priceReset, aboveMax, learned, cancelUndercut, cancelRepost, repostThreshold }. opName prices it by that operation instead of its own. An operation with formulas (minPrice,
--- normalPrice, maxPrice: see Formula.lua) prices by them; without, by its floor and multipliers.
function G.Prices(id, opName, level)
	local op, name = G.Operation(id, level)
	if opName and store().ops[opName] then op, name = store().ops[opName], opName end
	op = op or store().ops.Default
	local F = CH.Formula
	local item = level and ("i:" .. id .. "::i" .. level) or ("i:" .. id)
	local normal = op.normalPrice and F.Value(op.normalPrice, id, nil, level) or CH.Prices.Get("chvalue", item)
	local learned
	if op.learn and normal then
		local f, why = G.Learn(id)
		if f ~= 1 then normal, learned = normal * f, why end
	end
	local min, why
	if op.minPrice then
		min, why = F.Value(op.minPrice, id, { normal = normal }, level), "min " .. tostring(op.minPrice)
	else
		local floor
		if op.floor == "cost" then
			local c = costEach(id)
			floor, why = c and c / CH.AH_CUT, "cost to make"
		elseif op.floor == "paid" then
			local p = CH.Ledger and CH.Ledger.Available() and CH.Ledger.Paid()[id]
			floor, why = p and p.each / CH.AH_CUT, "what you paid"
		end
		if not floor then floor, why = CH.Prices.Get("chmat", item), "buy price" end
		min = floor and floor * (op.floorPct or 1)
	end
	local max
	if op.maxPrice then max = F.Value(op.maxPrice, id, { normal = normal, min = min }, level)
	else max = normal and normal * (op.maxMult or 3) end
	local cap = op.cap or (CH.Par and CH.Par.Target(id)) or 5
	local undercut = type(op.undercut) == "number" and op.undercut or F.Value(op.undercut, id, nil, level) or 1
	return { min = min and math.floor(min), normal = normal and math.floor(normal), max = max and math.floor(max), cap = cap,
		undercut = undercut, duration = op.duration or 2, post = op.post ~= false and cap > 0, op = name, why = why,
		keep = op.keepQuantity or 0, maxExpires = op.maxExpires or 0, priceReset = op.priceReset or "none",
		aboveMax = op.aboveMax or "maxPrice", learned = learned,
		-- canceling: when undercut (unless the operation says not to), and to repost higher when the
		-- price it would post at now beats yours by the threshold (TSM's "cancel to repost higher")
		cancelUndercut = op.cancelUndercut ~= false, cancelRepost = op.cancelRepost == true,
		repostThreshold = op.cancelRepost == true and (type(op.cancelRepostThreshold) == "number" and op.cancelRepostThreshold
			or F.Value(op.cancelRepostThreshold or "1g", id, { normal = normal, min = min, max = max }, level)) or nil }
end
