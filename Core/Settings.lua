-- Settings: every option the slash commands change, plus posting operations and your own price
-- sources, as plain functions the Settings page (SettingsUI.lua) calls. Nothing here touches TSM.
local _, CH = ...

local S = {}
CH.Settings = S

-- General options -------------------------------------------------------------------------------
-- { key, label, get, set } in the order the page shows them.
S.GENERAL = {
	{ "tooltip", "Tooltip lines", function() return CH.db.settings.tooltip ~= false end,
		function(v) CH.db.settings.tooltip = v end },
	{ "coins", "Coin icons (off = g s c)", function() return CH.db.settings.coins ~= false end,
		function(v) CH.db.settings.coins = v end },
	{ "minimap", "Minimap button", function() return not CH.db.settings.minimap.hide end,
		function(v) CH.db.settings.minimap.hide = not v; if CH.UpdateMinimapButton then CH.UpdateMinimapButton() end end },
	{ "elvui", "ElvUI colours", function() return CH.db.settings.theme == "elvui" end,
		function(v) CH.db.settings.theme = v and "elvui" or "aiq"; if CH.Theme.Use then CH.Theme.Use(CH.Theme.palette) end end },
	{ "alerts", "Alerts", function() return not CH.db.alerts or CH.db.alerts.on ~= false end,
		function(v) CH.db.alerts = CH.db.alerts or { last = {}, prices = {} }; CH.db.alerts.on = v end },
	{ "advisor", "Crafting advisor", function() return not CH.db.settings.advisor.hide end,
		function(v)
			CH.db.settings.advisor.hide = not v
			if CH.AdvisorUI then
				if not v then CH.AdvisorUI.Hide() elseif ProfessionsFrame and ProfessionsFrame:IsShown() then CH.AdvisorUI.Show() end
			end
		end },
	{ "subrecipes", "Reagents you craft at cost", function() return CH.db.settings.subrecipes ~= false end,
		function(v) CH.db.settings.subrecipes = v end },
	{ "popQueue", "Queue in its own window", function() return CH.db.settings.window.popQueue == true end,
		function(v) if (CH.db.settings.window.popQueue == true) ~= v then CH.Window.ToggleQueuePop() end end },
}

function S.Get(key)
	for _, o in ipairs(S.GENERAL) do if o[1] == key then return o[3]() end end
end

function S.Set(key, v)
	for _, o in ipairs(S.GENERAL) do if o[1] == key then o[4](v); return true end end
end

function S.Flip(key) return S.Set(key, not S.Get(key)) end

--- How many a day the scan counts as sellable for gold a day (/aiq cap).
function S.DailyCap(n)
	if n then CH.db.settings.scan.dailyCap = math.max(1, math.floor(n)) end
	return CH.db.settings.scan.dailyCap or 10
end

-- Math model ------------------------------------------------------------------------------------
-- The numbers behind expected value and stock targets (see Data/Expect.lua): { key, label, step,
-- min, max, how to show it }.
S.MODEL = {
	{ "service", "Stock target service", 0.01, 0.5, 0.99, function(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end },
	{ "cover", "Stock covers (days)", 1, 1, 30, function(v) return tostring(v) end },
	{ "carry", "Gold tied up, a day", 0.0025, 0, 0.05, function(v) return string.format("%.2f%%", v * 100) end },
}

--- A math setting's value, or with `delta`, step it within its bounds and return the new value.
function S.Model(key, delta)
	for _, m in ipairs(S.MODEL) do
		if m[1] == key then
			local v = CH.Expect.Setting(key)
			if delta then
				v = math.max(m[4], math.min(m[5], v + delta * m[3]))
				v = math.floor(v / m[3] + 0.5) * m[3]
				CH.Expect.Set(key, v)
				if CH.Par then CH.Par.Refresh() end
			end
			return v, m[6](v)
		end
	end
end

-- Operations ------------------------------------------------------------------------------------
-- Every field an operation has, how it's edited, and what it means. kind: bool, num (step), pick
-- (choices), formula.
S.OP_FIELDS = {
	{ "post", "Post it", "bool" },
	{ "undercut", "Undercut", "num", 100 },
	{ "duration", "Duration", "pick", { 1, 2, 3 }, { "12 hours", "24 hours", "48 hours" } },
	{ "cap", "Post cap", "num", 1 },
	{ "keepQuantity", "Keep in bags", "num", 1 },
	{ "maxExpires", "Max expires", "num", 1 },
	{ "floor", "Floor", "pick", { "market", "cost", "paid" }, { "market", "cost to make", "what you paid" } },
	{ "floorPct", "Min, x the floor", "num", 0.05 },
	{ "maxMult", "Max, x normal", "num", 0.5 },
	{ "priceReset", "Under min", "pick", { "none", "minPrice", "normalPrice", "maxPrice" }, { "don't post", "post at min", "post at normal", "post at max" } },
	{ "aboveMax", "Over max", "pick", { "maxPrice", "minPrice", "normalPrice", "none" }, { "post at max", "post at min", "post at normal", "don't post" } },
	{ "learn", "Learn from sales", "bool" },
}
S.FORMULAS = { { "minPrice", "Min" }, { "normalPrice", "Normal" }, { "maxPrice", "Max" } }

local function ops() return CH.Groups.Store().ops end

--- Operation names, Default first, then A to Z.
function S.OpNames()
	local out = {}
	for name in pairs(ops()) do if name ~= "Default" then table.insert(out, name) end end
	table.sort(out)
	table.insert(out, 1, "Default")
	return out
end

local function field(key)
	for _, f in ipairs(S.OP_FIELDS) do if f[1] == key then return f end end
end

--- A field's value as the page shows it.
function S.OpValue(name, key)
	local op = ops()[name]
	if not op then return nil end
	local f, v = field(key), op[key]
	if not f then return v end
	if f[3] == "bool" then
		if key == "learn" then return v == true end
		return v ~= false
	end
	if f[3] == "pick" then
		local default = f[4][1]
		if key == "duration" then default = 2 end
		v = v == nil and default or v
		for i, c in ipairs(f[4]) do if c == v then return v, f[5][i] end end
		return v, tostring(v)
	end
	if key == "cap" and v == nil then return 0 end
	return v or 0
end

--- Change a field: bools flip, picks go to the next choice, numbers step by dir (+1 or -1).
function S.OpStep(name, key, dir)
	local op, f = ops()[name], field(key)
	if not (op and f) then return end
	if f[3] == "bool" then
		op[key] = not S.OpValue(name, key)
	elseif f[3] == "pick" then
		local cur = S.OpValue(name, key)
		local n = #f[4]
		for i, c in ipairs(f[4]) do
			if c == cur then op[key] = f[4][((i - 1 + (dir or 1)) % n) + 1]; break end
		end
	else
		local v = op[key]
		if type(v) == "string" then v = CH.Formula.Value(v, 0) or 0 end
		v = math.max(0, (v or 0) + (dir or 1) * f[4])
		if f[4] < 1 then v = math.floor(v * 100 + 0.5) / 100 end
		op[key] = v
		if key == "cap" and v == 0 then op.cap = nil end
	end
end

--- Set a price formula (blank clears it). Returns true, or false and why it doesn't read.
function S.SetOpFormula(name, key, text)
	local op = ops()[name]
	if not op then return false, "no such operation" end
	text = tostring(text or ""):match("^%s*(.-)%s*$")
	if text == "" then op[key] = nil; return true end
	local ok, err = CH.Formula.Valid(text)
	if not ok then return false, err end
	op[key] = text
	return true
end

local PROTECTED = { Default = true }
for k in pairs(CH.Groups and CH.Groups.DEFAULT_OPS or {}) do PROTECTED[k] = true end

local function cleanName(name)
	name = tostring(name or ""):match("^%s*(.-)%s*$")
	if name == "" or #name > 40 then return nil end
	return name
end

--- Make an operation, copying another one (or Default). Returns its name, or nil and why.
function S.NewOp(name, from)
	name = cleanName(name)
	if not name then return nil, "give it a name" end
	if ops()[name] then return nil, name .. " already exists" end
	local src = ops()[from or "Default"] or ops().Default
	local c = {}
	for k, v in pairs(src) do c[k] = v end
	c.imported = nil
	ops()[name] = c
	return name
end

--- Rename an operation and every group that uses it. The built-in ones keep their names.
function S.RenameOp(old, new)
	new = cleanName(new)
	local s = CH.Groups.Store()
	if not s.ops[old] then return nil, "no such operation" end
	if PROTECTED[old] then return nil, old .. " is built in: copy it instead" end
	if not new then return nil, "give it a name" end
	if s.ops[new] then return nil, new .. " already exists" end
	s.ops[new], s.ops[old] = s.ops[old], nil
	for path, op in pairs(s.assign) do if op == old then s.assign[path] = new end end
	for _, list in pairs(s.assignAll or {}) do
		for i, op in ipairs(list) do if op == old then list[i] = new end end
	end
	return new
end

--- Delete an operation; groups that used it go back to inheriting. Built-in ones stay.
function S.DeleteOp(name)
	local s = CH.Groups.Store()
	if PROTECTED[name] then return nil, name .. " is built in" end
	if not s.ops[name] then return nil, "no such operation" end
	s.ops[name] = nil
	local n = 0
	for path, op in pairs(s.assign) do if op == name then s.assign[path] = nil; n = n + 1 end end
	-- a group with TSM's ordered list falls to the next operation in it
	for path, list in pairs(s.assignAll or {}) do
		for i = #list, 1, -1 do if list[i] == name then table.remove(list, i) end end
		if list[1] then
			if not s.assign[path] then s.assign[path] = list[1] end
		else s.assignAll[path] = nil end
	end
	return n
end

--- Groups that use an operation directly.
function S.OpGroups(name)
	local out = {}
	for path, op in pairs(CH.Groups.Store().assign) do if op == name then table.insert(out, path) end end
	table.sort(out)
	return out
end

-- Group sources -----------------------------------------------------------------------------------
function S.UseTSM(v)
	local s = CH.Groups.Store()
	if v ~= nil then s.useTSM = v; if CH.Groups.ResetTSM then CH.Groups.ResetTSM() end end
	return s.useTSM ~= false
end

function S.PreferTSM(v)
	local s = CH.Groups.Store()
	if v ~= nil then s.preferTSM = v end
	return s.preferTSM == true
end

-- Price sources -----------------------------------------------------------------------------------
-- Names the formulas already use; a source of yours can't take one.
local BUILT_IN = { crafting = true, vendorsell = true, numexpires = true, avgbuy = true, avgsell = true, chvalue = true,
	chmat = true, chpost = true, dbmarket = true, dbminbuyout = true, dbhistorical = true, dbregionmarketavg = true,
	dbregionsaleavg = true, dbregionhistorical = true, dbregionsoldperday = true, dbregionsalerate = true, destroy = true,
	normal = true, min = true, max = true, first = true, avg = true, check = true, round = true, roundup = true,
	rounddown = true, ifgte = true, ifgt = true, iflte = true, iflt = true, ifeq = true }

--- Your price sources as { { name, formula } }, A to Z.
function S.Sources()
	local out = {}
	for name, f in pairs(CH.Formula.Custom()) do table.insert(out, { name = name, formula = f }) end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

--- Add or change a price source. Returns true, or false and why.
function S.SetSource(name, formula)
	name = tostring(name or ""):lower():match("^%s*(.-)%s*$")
	if not name:match("^[a-z][a-z0-9_]*$") then return false, "names are letters, digits and _, starting with a letter" end
	if BUILT_IN[name] then return false, name .. " is already a built-in source" end
	local ok, err = CH.Formula.Valid(formula)
	if not ok then return false, err end
	CH.Formula.Custom()[name] = tostring(formula):match("^%s*(.-)%s*$")
	return true
end

function S.DeleteSource(name)
	local c = CH.Formula.Custom()
	if c[name] == nil then return false end
	c[name] = nil
	return true
end

--- What a formula gives for an item, for trying one out: copper or nil.
function S.Try(formula, id)
	if not CH.Formula.Valid(formula) then return nil end
	return CH.Formula.Value(formula, id)
end
