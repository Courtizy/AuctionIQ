-- Groups and operations: which items Clearinghouse posts, buys or mails, and how. Built for you from
-- what you craft, use and resell (re-run any time), falling back to your TSM groups (read only).
-- Move an item yourself and that sticks. Each group's operation sets the posting prices:
--   min    never post below it: crafted goods at what they cost to make after the cut, resale at
--          what you paid after the cut, anything else at 80% of its buy price
--   normal post here when nobody is cheaper: Clearinghouse value
--   max    never post above it: 3x normal
-- and how many to keep up across the whole Warband (par level, else a cap).
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
	-- TSM's auctioning operations for items in TSM groups: "strict" (both must agree), "tsm" or "off"
	s.tsmRules = s.tsmRules or "tsm"
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

local function tsmValue(v, item)
	if v == nil then return nil end
	if type(v) == "number" then return v end
	local n = tonumber(v)
	if n then return n end
	if not CH.Prices.Available() then return nil end
	local ok, r = pcall(TSM_API.GetCustomPriceValue, v, item)
	return ok and r or nil
end

--- TSM's auctioning operation for an item in a TSM group, read only, or nil:
--- { name, min, normal, max, cap, undercut, duration, post }. Prices are TSM custom prices for the item.
function G.TSMAuction(id)
	G.TSMGroups()
	local path = tsmRaw and tsmRaw[id]
	local db = TradeSkillMasterDB
	if not path or type(db) ~= "table" then return nil end
	local profile = tsmProfile(db)
	local groups = profile and db["p@" .. profile .. "@userData@groups"]
	local ops = profile and db["p@" .. profile .. "@userData@operations"]
	if type(groups) ~= "table" then return nil end
	-- the nearest group up the path with Auctioning operations of its own (TSM's override)
	local name, p = nil, path
	while p do
		local g = groups[p]
		local a = type(g) == "table" and g.Auctioning
		if type(a) == "table" and (a.override or not p:find("`")) then name = a[1]; break end
		p = p:match("^(.*)`[^`]*$")
	end
	if not name then return { post = false, why = "no TSM auctioning operation" } end
	local op = type(ops) == "table" and type(ops.Auctioning) == "table" and ops.Auctioning[name]
	if type(op) ~= "table" then return { post = false, name = name, why = "TSM operation missing" } end
	local item = "i:" .. id
	return { name = name, post = true, min = tsmValue(op.minPrice, item), normal = tsmValue(op.normalPrice, item),
		max = tsmValue(op.maxPrice, item), cap = tsmValue(op.postCap, item), undercut = tsmValue(op.undercut, item),
		duration = tonumber(op.duration), keep = tsmValue(op.keepQuantity, item),
		priceReset = op.priceReset, aboveMax = op.aboveMax }
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

--- An item's group: yours if you moved it, else the automatic one, else TSM's (if used).
function G.Path(id)
	local s = store()
	return s.manual[id] or s.auto[id] or (s.useTSM and G.TSMGroups()[id]) or nil
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
	local seen = {}
	for id, p in pairs(s.manual) do seen[id] = true; count(p) end
	for id, p in pairs(s.auto) do if not seen[id] then seen[id] = true; count(p) end end
	if s.useTSM then for id, p in pairs(G.TSMGroups()) do if not seen[id] then count(p) end end end
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
	local s, out, seen = store(), {}, {}
	local function want(p) return p == path or p:sub(1, #path + 1) == path .. SEP end
	for id, p in pairs(s.manual) do seen[id] = true; if want(p) then table.insert(out, id) end end
	for id, p in pairs(s.auto) do if not seen[id] then seen[id] = true; if want(p) then table.insert(out, id) end end end
	if s.useTSM then for id, p in pairs(G.TSMGroups()) do if not seen[id] and want(p) then table.insert(out, id) end end end
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

--- Posting prices for an item: { min, normal, max, cap, undercut, duration, post, op, why }.
function G.Prices(id)
	local op, name = G.Operation(id)
	op = op or store().ops.Default
	local item = "i:" .. id
	local normal = CH.Prices.Get("chvalue", item)
	local floor, why
	if op.floor == "cost" then
		local c = costEach(id)
		floor, why = c and c / CH.AH_CUT, "cost to make"
	elseif op.floor == "paid" then
		local p = CH.Ledger and CH.Ledger.Available() and CH.Ledger.Paid()[id]
		floor, why = p and p.each / CH.AH_CUT, "what you paid"
	end
	if not floor then floor, why = CH.Prices.Get("chmat", item), "buy price" end
	local min = floor and math.floor(floor * (op.floorPct or 1))
	local cap = op.cap or (CH.Par and CH.Par.Target(id)) or 5
	local out = { min = min, normal = normal, max = normal and math.floor(normal * (op.maxMult or 3)), cap = cap,
		undercut = op.undercut or 1, duration = op.duration or 2, post = op.post ~= false, op = name, why = why }
	local mode = store().tsmRules
	local t = mode ~= "off" and G.TSMAuction(id)
	if not t then return out end
	out.tsm = t
	if mode == "tsm" then
		out.post, out.op = t.post, "TSM: " .. (t.name or "none")
		if not t.post then out.why = t.why; return out end
		out.min, out.why = t.min or out.min, t.min and "TSM min" or out.why
		out.normal, out.max = t.normal or out.normal, t.max or out.max
		out.cap, out.undercut, out.duration = t.cap or out.cap, t.undercut or out.undercut, t.duration or out.duration
		out.keep, out.priceReset, out.aboveMax = t.keep, t.priceReset, t.aboveMax
		return out
	end
	-- stricter of the two: post only if both would, the higher min, the lower cap
	if not t.post then out.post, out.why, out.op = false, t.why, name .. " + TSM"; return out end
	out.op = name .. " + TSM"
	if t.min and (not out.min or t.min > out.min) then out.min, out.why = t.min, "TSM min" end
	if t.cap and t.cap < out.cap then out.cap = t.cap end
	if t.normal then out.normal = t.normal end
	if t.max then out.max = t.max end
	if out.max and out.min and out.max < out.min then out.max = out.min end
	return out
end
