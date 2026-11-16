-- How TSM itself is set up for a group or an item, read straight from TSM's saved data (read only):
-- which Auctioning, Crafting and Shopping operation applies, where it is set (the group's own or a
-- parent's), each setting as TSM saved it and, for an item, what it comes to now, which other groups
-- use the same operation, and what can't be read reliably. This is what Tune TSM starts from.
--
-- TSM's rules followed here:
--   * a group uses its own operations when it overrides its parent, else its parent's, up to the
--     base group
--   * of several operations, the first that isn't ignored for the character you're on applies
--   * an operation saved in the profile wins over a shared one of the same name
local _, AuctionIQ = ...

local S = {}
AuctionIQ.TSMSetup = S

local SEP = "/"

-- The settings shown, in order, with TSM's field names. kind: "price" (a formula in copper),
-- "count", "duration", "choice" or "flag".
S.FIELDS = {
	Auctioning = {
		{ key = "postCap", label = "Post cap", kind = "count" },
		{ key = "duration", label = "Duration", kind = "duration" },
		{ key = "minPrice", label = "Auctioning minimum", kind = "price" },
		{ key = "normalPrice", label = "Normal price", kind = "price" },
		{ key = "maxPrice", label = "Maximum price", kind = "price" },
		{ key = "undercut", label = "Undercut", kind = "price" },
		{ key = "keepQuantity", label = "Keep in bags", kind = "count" },
		{ key = "maxExpires", label = "Max expires", kind = "count" },
		{ key = "priceReset", label = "Below minimum", kind = "choice" },
		{ key = "aboveMax", label = "Above maximum", kind = "choice" },
		{ key = "cancelUndercut", label = "Cancel when undercut", kind = "flag" },
		{ key = "cancelRepost", label = "Cancel to repost higher", kind = "flag" },
		{ key = "cancelRepostThreshold", label = "Repost higher by", kind = "price" },
	},
	Crafting = {
		{ key = "minRestock", label = "Min restock", kind = "count" },
		{ key = "maxRestock", label = "Max restock", kind = "count" },
		{ key = "minProfit", label = "Minimum profit", kind = "price" },
	},
	Shopping = {
		{ key = "maxPrice", label = "Shopping maximum", kind = "price" },
	},
}
local KINDS = { "Auctioning", "Crafting", "Shopping" }
S.KINDS = KINDS

S.DURATION = { [1] = "12 hours", [2] = "24 hours", [3] = "48 hours" }

-- "TSM/A/B" -> "A`B" (TSM's own form), "TSM" -> "" (the base group), anything else -> nil.
local function tsmKey(path)
	if path == "TSM" then return "" end
	local rest = type(path) == "string" and path:match("^TSM" .. SEP .. "(.+)$")
	return rest and (rest:gsub(SEP, "`")) or nil
end
local function ourPath(key) return key == "" and "TSM" or ("TSM" .. SEP .. key:gsub("`", SEP)) end
local function parentKey(key)
	if key == "" then return nil end
	return key:match("^(.*)`[^`]+$") or ""
end

-- TSM's saved data for the current profile: db, groups, and the operations of one kind by name
-- (profile over shared), or nil and why.
local function tsm()
	local db = TradeSkillMasterDB
	if type(db) ~= "table" then return nil, "TSM's saved data isn't loaded" end
	local profile = AuctionIQ.Groups.TSMProfile(db)
	if not profile then return nil, "TSM has no profile for this character" end
	local groups = db["p@" .. profile .. "@userData@groups"]
	if type(groups) ~= "table" then return nil, "TSM has no groups in profile " .. profile end
	local ops = {}
	for _, kind in ipairs(KINDS) do
		ops[kind] = {}
		for _, t in ipairs({ db["g@ @userData@sharedOperations"], db["p@" .. profile .. "@userData@operations"] }) do
			if type(t) == "table" and type(t[kind]) == "table" then
				for name, op in pairs(t[kind]) do if type(op) == "table" then ops[kind][name] = op end end
			end
		end
	end
	return { db = db, profile = profile, groups = groups, ops = ops }
end

-- Where a group's operations of one kind are set: the group itself when it overrides, else the
-- nearest parent that does, else the base group. Returns that group's key and its list.
local function setAt(t, key, kind)
	local k = key
	while k do
		local g = t.groups[k]
		local a = type(g) == "table" and g[kind]
		if type(a) == "table" and (a.override or k == "") then
			local list = {}
			for _, name in ipairs(a) do list[#list + 1] = name end
			return k, list
		end
		k = parentKey(k)
	end
end

-- Every group that sets an operation itself (overrides with it), by operation name and kind.
local function usersOf(t, kind, name)
	local out = {}
	for key, g in pairs(t.groups) do
		local a = type(g) == "table" and g[kind]
		if type(a) == "table" and (a.override or key == "") then
			for _, n in ipairs(a) do if n == name then out[#out + 1] = ourPath(key); break end end
		end
	end
	table.sort(out)
	return out
end

local function money(c)
	if not c then return nil end
	return AuctionIQ.FormatMoney and AuctionIQ.FormatMoney(math.floor(c + 0.5), true) or tostring(c)
end

-- One setting as TSM saved it, and (with an item) what it comes to for that item now.
local function setting(f, op, id, level, ctx)
	local raw = op[f.key]
	local r = { key = f.key, label = f.label, kind = f.kind, raw = raw, saved = raw ~= nil }
	if raw == nil then r.text = "TSM's default (not in its saved data)"; return r end
	if f.kind == "duration" then r.value = tonumber(raw); r.text = S.DURATION[r.value] or tostring(raw)
	elseif f.kind == "flag" then r.value = raw ~= false; r.text = r.value and "on" or "off"
	elseif f.kind == "choice" then r.value = raw; r.text = tostring(raw)
	elseif f.kind == "count" then
		r.value = tonumber(raw)
		if not r.value and id then r.value = AuctionIQ.Formula.Value(tostring(raw), id, nil, level) end
		r.text = tostring(raw)
	else -- price
		r.text = tostring(raw)
		if id then
			r.value = AuctionIQ.Formula.Value(type(raw) == "number" and raw or tostring(raw), id, ctx, level)
			if r.value == nil then r.unpriced = true end
		end
	end
	if f.kind == "price" and r.value then r.valueText = money(r.value)
	elseif f.kind == "count" and r.value and tostring(r.value) ~= tostring(raw) then r.valueText = tostring(math.floor(r.value)) end
	return r
end

-- One kind of operation for a TSM group key: { kind, from (where set), ops (in order), op (the one
-- that applies here), skipped (ignored for this character), missing (named but not saved),
-- settings, shared (groups that set the same operation), limits }.
local function resolve(t, key, kind, id, level)
	local at, list = setAt(t, key, kind)
	local r = { kind = kind, ops = list or {}, skipped = {}, missing = {}, settings = {}, limits = {} }
	if not at then return r end
	r.from, r.own = ourPath(at), at == key
	local ignored = false
	for _, name in ipairs(r.ops) do
		local op = t.ops[kind][name]
		if not op then table.insert(r.missing, name)
		elseif type(op.ignorePlayer) == "table" and next(op.ignorePlayer) then
			ignored = true
			if AuctionIQ.Groups.AppliesHere(op) then if not r.op then r.op = name end
			else table.insert(r.skipped, name) end
		elseif not r.op then r.op = name end
	end
	for _, name in ipairs(r.missing) do
		table.insert(r.limits, string.format("%s is set on the group but isn't in TSM's saved operations", name))
	end
	if ignored then
		local me = UnitName and UnitName("player") or "this character"
		table.insert(r.limits, "Which operation applies is worked out for " .. me .. "; other characters may use another one")
	end
	if not r.op then return r end
	local op = t.ops[kind][r.op]
	local ctx = {}
	for _, f in ipairs(S.FIELDS[kind]) do
		local s = setting(f, op, id, level, ctx)
		-- TSM's later prices may refer to the earlier ones (normal in max, min in a threshold)
		if f.key == "normalPrice" then ctx.normal = s.value elseif f.key == "minPrice" then ctx.min = s.value
		elseif f.key == "maxPrice" and kind == "Auctioning" then ctx.max = s.value end
		table.insert(r.settings, s)
		if s.unpriced then
			table.insert(r.limits, string.format("%s (%s) has no value for this item now: a price source it reads has no data", s.label, s.text))
		end
	end
	local unsaved = 0
	for _, s in ipairs(r.settings) do if not s.saved then unsaved = unsaved + 1 end end
	if unsaved > 0 then
		table.insert(r.limits, string.format("%d setting%s aren't in TSM's saved data, so TSM's defaults apply and aren't shown", unsaved, unsaved == 1 and "" or "s"))
	end
	if kind == "Auctioning" then
		for _, why in ipairs(AuctionIQ.Groups.Unsupported(op)) do table.insert(r.limits, "TSM also uses " .. why) end
	end
	r.shared = usersOf(t, kind, r.op)
	return r
end

local ASOF = "Read from TSM's saved data, which TSM writes when you /reload or log out: changes made in TSM since then don't show yet"

--- TSM's setup for a group ("TSM/A/B", or "TSM" for the base group): { group, exists, Auctioning,
--- Crafting, Shopping (see resolve), limits }, or nil and why. Without an item, prices are shown as
--- TSM saved them, not worked out.
function S.Group(path, id, level)
	local t, err = tsm()
	if not t then return nil, err end
	local key = tsmKey(path)
	if not key then return nil, "not a TSM group" end
	local out = { group = path, exists = key == "" or type(t.groups[key]) == "table", limits = { ASOF } }
	if not out.exists then table.insert(out.limits, path .. " isn't one of TSM's groups now") end
	for _, kind in ipairs(KINDS) do
		-- TSM's Crafting and Shopping operations don't run from the base group
		if kind == "Auctioning" or key ~= "" then out[kind] = resolve(t, key, kind, id, level) end
	end
	return out
end

--- TSM's setup for an item (at an item level): the same as Group for its TSM group, with each price
--- worked out for it now, plus where AuctionIQ acts differently: { item, level, ..., differs }.
function S.Item(id, level)
	local G = AuctionIQ.Groups
	local path = G.TSMPath(id, level)
	local out, err
	if path then
		out, err = S.Group(path, id, level)
		if not out then return nil, err end
	else
		out, err = S.Group("TSM", id, level)
		if not out then return nil, err end
		local conflict = not level and G.TSMGroups()[id] == nil and next(G.TSMGroupsByString()) and (function()
			for str in pairs(G.TSMGroupsByString()) do if tonumber(str:match("^i:(%d+)")) == id then return true end end
		end)()
		table.insert(out.limits, conflict and "Its item levels sit in different TSM groups, so pick an item level to see which applies"
			or "It isn't in a TSM group, so only TSM's base group applies to it")
	end
	out.item, out.level, out.differs = id, level, {}
	-- AuctionIQ posts by its own copy of the operation: say where that isn't TSM's
	local mine, mineName = G.Operation(id, level)
	local a = out.Auctioning
	if a and a.op and mineName ~= a.op then
		local where = G.Path(id, level)
		table.insert(out.differs, string.format("AuctionIQ posts it by %s (group %s), not TSM's %s", tostring(mineName), tostring(where), a.op))
	elseif a and a.op and type(mine) == "table" then
		local MAP = { postCap = "cap", minPrice = "minPrice", normalPrice = "normalPrice", maxPrice = "maxPrice", undercut = "undercut",
			keepQuantity = "keepQuantity", maxExpires = "maxExpires", duration = "duration", priceReset = "priceReset", aboveMax = "aboveMax" }
		for _, s in ipairs(a.settings) do
			local k = MAP[s.key]
			if k and s.saved and mine[k] ~= nil and tostring(mine[k]) ~= tostring(s.raw) then
				table.insert(out.differs, string.format("%s: TSM has %s, AuctionIQ's copy has %s", s.label, tostring(s.raw), tostring(mine[k])))
			end
		end
	end
	return out
end

--- Chat lines for a setup from Group or Item.
function S.Lines(r)
	local out = {}
	local head = r.item and string.format("item %d%s in %s", r.item, r.level and (" at item level " .. r.level) or "", r.group or "?")
		or ("group " .. tostring(r.group))
	table.insert(out, "TSM setup for " .. head)
	for _, kind in ipairs(KINDS) do
		local k = r[kind]
		if k and k.op then
			local where = k.own and "its own" or ("from " .. tostring(k.from))
			table.insert(out, string.format("%s: %s (%s)%s", kind, k.op, where,
				#k.shared > 1 and (", also set on " .. (#k.shared - 1) .. " other group" .. (#k.shared == 2 and "" or "s")) or ""))
			if #k.skipped > 0 then table.insert(out, "  skipped here: " .. table.concat(k.skipped, ", ")) end
			for _, s in ipairs(k.settings) do
				if s.saved then
					table.insert(out, string.format("  %s: %s%s", s.label, s.text, s.valueText and (" = " .. s.valueText) or ""))
				end
			end
		elseif k and #k.ops > 0 then
			table.insert(out, kind .. ": none applies to this character")
		end
	end
	for _, l in ipairs(r.differs or {}) do table.insert(out, "Differs: " .. l) end
	local limits = {}
	for _, l in ipairs(r.limits) do limits[#limits + 1] = l end
	for _, kind in ipairs(KINDS) do for _, l in ipairs(r[kind] and r[kind].limits or {}) do limits[#limits + 1] = kind .. ": " .. l end end
	for _, l in ipairs(limits) do table.insert(out, "Can't read reliably: " .. l) end
	return out
end

--- /aiq tsm <item link, item ID or TSM group path>: prints the setup.
function S.Command(arg)
	arg = arg and arg:match("^%s*(.-)%s*$") or ""
	local r, err
	local id, level = arg:match("item:(%d+)")
	if id then
		id = tonumber(id)
		if C_Item and C_Item.GetDetailedItemLevelInfo then
			local lv = C_Item.GetDetailedItemLevelInfo(arg)
			-- only gear has levels TSM groups apart
			local class = C_Item.GetItemInfoInstant and select(6, C_Item.GetItemInfoInstant(id))
			if lv and (class == 2 or class == 4) then level = lv end
		end
		r, err = S.Item(id, level)
	elseif tonumber(arg) then r, err = S.Item(tonumber(arg))
	elseif arg ~= "" then r, err = S.Group(arg:match("^TSM") and arg or ("TSM" .. SEP .. arg))
	else err = "use /aiq tsm with an item link, an item ID or a TSM group (A/B)" end
	if not r then AuctionIQ.Print(err); return end
	for _, l in ipairs(S.Lines(r)) do AuctionIQ.Print(l) end
end
