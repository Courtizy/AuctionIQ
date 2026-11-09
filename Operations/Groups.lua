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

-- TSM's groups for the current profile, read only: { [itemID] = "TSM/A/B" }.
local tsmCache, tsmRaw
function G.TSMGroups()
	if tsmCache then return tsmCache end
	tsmCache, tsmRaw = {}, {}
	local db = TradeSkillMasterDB
	if type(db) ~= "table" then return tsmCache end
	local profile = tsmProfile(db)
	local items = profile and db["p@" .. profile .. "@userData@items"]
	if type(items) ~= "table" then return tsmCache end
	for itemString, path in pairs(items) do
		local id = tonumber(tostring(itemString):match("^i:(%d+)"))
		if id and type(path) == "string" and path ~= "" then
			tsmCache[id] = "TSM" .. SEP .. path:gsub("`", SEP)
			tsmRaw[id] = path
		end
	end
	return tsmCache
end

--- Forget the TSM groups read so far (they're read once per session).
function G.ResetTSM() tsmCache, tsmRaw = nil, nil end

-- TSM's operation fields, copied into AuctionIQ's own operations.
local function num(v) return tonumber(v) end

--- Copy TSM's auctioning setup into AuctionIQ, once (TSM's data is only read):
---   * each Auctioning operation becomes an AuctionIQ operation of the same name with the same
---     formulas and settings (min, normal, max, undercut, post cap, keep, max expires, resets, duration)
---   * TSM's custom price sources become AuctionIQ's (see Formula.lua)
---   * each TSM group that sets its own operation gets it here too, and TSM's groups win over the
---     automatic ones, so items post as TSM would
--- After this nothing needs TSM: change the operations here and they stay yours.
--- Returns { ops, sources, groups } counts, or nil and why.
function G.ImportTSM()
	local db = TradeSkillMasterDB
	if type(db) ~= "table" then return nil, "TSM's saved data isn't loaded" end
	local profile = tsmProfile(db)
	local s = store()
	local n = { ops = 0, sources = 0, groups = 0 }
	local function opsFrom(t)
		if type(t) ~= "table" or type(t.Auctioning) ~= "table" then return end
		for name, op in pairs(t.Auctioning) do
			if type(op) == "table" then
				local cap = num(op.postCap)
				s.ops[name] = {
					post = cap ~= 0, imported = "TSM",
					minPrice = op.minPrice, normalPrice = op.normalPrice, maxPrice = op.maxPrice,
					undercut = op.undercut or 0, cap = cap, keepQuantity = num(op.keepQuantity) or 0,
					maxExpires = num(op.maxExpires) or 0, priceReset = op.priceReset or "none",
					aboveMax = op.aboveMax or "maxPrice", duration = num(op.duration) or 2,
					floor = "market", floorPct = 1, maxMult = 3, learn = false,
				}
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
				local here = path == "" and "TSM" or ("TSM" .. SEP .. path:gsub("`", SEP))
				s.assign[here] = a[1]
				n.groups = n.groups + 1
			end
		end
	end
	s.useTSM, s.preferTSM = true, true
	G.ResetTSM()
	return n
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
--- import from TSM, TSM's groups come before the automatic ones.
function G.Path(id)
	local s = store()
	local tsm = s.useTSM and G.TSMGroups()[id] or nil
	if s.manual[id] then return s.manual[id] end
	if s.preferTSM and tsm then return tsm end
	return s.auto[id] or tsm
end

-- Every grouped item and its group, by the same order as Path.
local function members()
	local s, out = store(), {}
	if s.useTSM then for id, p in pairs(G.TSMGroups()) do out[id] = p end end
	for id, p in pairs(s.auto) do if not (s.preferTSM and out[id]) then out[id] = p end end
	for id, p in pairs(s.manual) do out[id] = p end
	return out
end

--- Put an item in a group yourself (path), or back to automatic (nil).
function G.Move(id, path) store().manual[id] = path end

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
	for id, p in pairs(members()) do if want(p) then table.insert(out, id) end end
	table.sort(out)
	return out
end

--- The operation for an item: the group's own, else its parent's, else by top-level group.
function G.Operation(id)
	local s = store()
	local path = G.Path(id)
	if not path then return nil end
	local p = path
	while p do
		if s.assign[p] then return s.ops[s.assign[p]], s.assign[p] end
		p = p:match("^(.*)" .. SEP .. "[^" .. SEP .. "]+$")
	end
	local top = path:match("^([^" .. SEP .. "]+)")
	local name = (top == "Crafted" or top == "Resale" or top == "Reagents") and top or "Default"
	return s.ops[name], name
end

function G.Assign(path, opName) store().assign[path] = opName end

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
--- 30 days of sold and expired units. The price goes up (to +5%) only when it is likely that 80%+ of
--- posts sell, and down (to -10%) only when it is likely that under 40% do; the step grows with how
--- sure it is. Otherwise 1 (no change).
function G.Learn(id)
	if not (CH.Ledger and CH.Ledger.Available()) then return 1 end
	local sold, expired = CH.Ledger.SellThrough(id)
	if sold + expired == 0 then return 1 end
	local st = CH.Prob.SellThrough(sold, expired, CH.Expect and CH.Expect.RegionRate(id) or 0.5)
	local f, sure = 1, nil
	if st.pUp > 0.6 then f, sure = 1 + 0.05 * (st.pUp - 0.6) / 0.4, st.pUp
	elseif st.pDown > 0.6 then f, sure = 1 - 0.10 * (st.pDown - 0.6) / 0.4, st.pDown end
	f = math.floor(f * 200 + 0.5) / 200 -- half-percent steps
	if f == 1 then return 1 end
	return f, string.format("sells %d%% of posts (%d sold, %d expired), %d%% sure: %+.1f%%", math.floor(st.mean * 100 + 0.5),
		sold, expired, math.floor(sure * 100 + 0.5), (f - 1) * 100)
end

--- Posting prices and rules for an item: { min, normal, max, cap, undercut, duration, post, op, why,
--- keep, maxExpires, priceReset, aboveMax, learned }. opName prices it by that operation instead of its own. An operation with formulas (minPrice,
--- normalPrice, maxPrice: see Formula.lua) prices by them; without, by its floor and multipliers.
function G.Prices(id, opName, level)
	local op, name = G.Operation(id)
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
		aboveMax = op.aboveMax or "maxPrice", learned = learned }
end
