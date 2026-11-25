-- The open profession's recipes, read the same way on Forever and retail, and kept per character so
-- the Craft tab and its cooldown strip work with the profession closed.
--
-- WoW: Forever carries retail's C_TradeSkillUI namespace, but nobody has crafted on it with AuctionIQ
-- loaded yet, so both readers are here: the retail one (GetAllRecipeIDs, GetRecipeSchematic,
-- CraftRecipe) and the Classic one (GetNumTradeSkills, GetTradeSkillInfo, DoTradeSkill). The first
-- that answers wins. /aiq probe records which calls exist and which events fire, for the record.
--
-- A recipe: { key, name, item (output item ID), link, makes (average items per craft), reagents =
-- { { item, qty, have, name } }, canMake, cooldown (seconds), readyAt, source = "modern"|"classic",
-- index (Classic list position), category (the profession window's heading, e.g. "Potions") }.
local _, AuctionIQ = ...

local R = {}
AuctionIQ.Recipes = R

local function itemID(link)
	return link and tonumber(tostring(link):match("item:(%d+)")) or nil
end

local function now() return time and time() or 0 end

-- Retail-style reader ----------------------------------------------------------------------------

local function modernReady()
	local ui = C_TradeSkillUI
	if not (ui and ui.GetAllRecipeIDs and ui.GetRecipeInfo and ui.GetRecipeSchematic) then return false end
	if ui.IsTradeSkillReady and not ui.IsTradeSkillReady() then return false end
	local ok, ids = pcall(ui.GetAllRecipeIDs)
	return ok and type(ids) == "table" and #ids > 0
end

local function modernProfession()
	local ui = C_TradeSkillUI
	local info = ui.GetBaseProfessionInfo and ui.GetBaseProfessionInfo()
	if type(info) == "table" and info.professionName then
		return info.professionName, info.skillLevel, info.maxSkillLevel
	end
	if ui.GetTradeSkillLine then
		local _, name, rank, max = ui.GetTradeSkillLine()
		return name, rank, max
	end
end

local function modernRead()
	local ui = C_TradeSkillUI
	local list = {}
	for _, id in ipairs(ui.GetAllRecipeIDs()) do
		local info = ui.GetRecipeInfo(id)
		if type(info) == "table" and info.learned ~= false and not info.isDummyRecipe then
			local s = ui.GetRecipeSchematic(id, false)
			if type(s) == "table" and s.outputItemID then
				local r = { key = "r" .. id, recipeID = id, name = info.name or s.name, item = s.outputItemID,
					makes = ((s.quantityMin or 1) + (s.quantityMax or s.quantityMin or 1)) / 2,
					canMake = info.numAvailable or 0, reagents = {}, source = "modern" }
				if info.categoryID and ui.GetCategoryInfo then
					local ok, cat = pcall(ui.GetCategoryInfo, info.categoryID)
					if ok and type(cat) == "table" then r.category = cat.name end
				end
				for _, slot in ipairs(s.reagentSlotSchematics or {}) do
					local first = slot.reagents and slot.reagents[1]
					-- required reagents only (type 1 on retail); Forever has no optional or finishing slots
					if first and first.itemID and (slot.reagentType == nil or slot.reagentType == 1) and (slot.required ~= false) then
						r.reagents[#r.reagents + 1] = { item = first.itemID, qty = slot.quantityRequired or 1 }
					end
				end
				if ui.GetRecipeCooldown then
					local ok, cd = pcall(ui.GetRecipeCooldown, id)
					if ok and type(cd) == "number" and cd > 0 then r.cooldown = cd end
				end
				list[#list + 1] = r
			end
		end
	end
	return list
end

-- Classic-style reader ---------------------------------------------------------------------------

local function classicReady()
	return type(GetNumTradeSkills) == "function" and type(GetTradeSkillInfo) == "function" and (GetNumTradeSkills() or 0) > 0
end

local function classicRead()
	local list = {}
	local header
	for i = 1, GetNumTradeSkills() do
		local name, kind, available = GetTradeSkillInfo(i)
		if name and (kind == "header" or kind == "subheader") then header = name end
		if name and kind ~= "header" and kind ~= "subheader" then
			local link = GetTradeSkillItemLink and GetTradeSkillItemLink(i)
			local id = itemID(link)
			if id then
				local lo, hi = 1, 1
				if GetTradeSkillNumMade then lo, hi = GetTradeSkillNumMade(i); lo = lo or 1; hi = hi or lo end
				local r = { key = "c" .. name, name = name, item = id, link = link, makes = (lo + hi) / 2,
					canMake = available or 0, reagents = {}, source = "classic", index = i, category = header }
				for n = 1, (GetTradeSkillNumReagents and GetTradeSkillNumReagents(i) or 0) do
					local rname, _, count = GetTradeSkillReagentInfo(i, n)
					local rid = itemID(GetTradeSkillReagentItemLink and GetTradeSkillReagentItemLink(i, n))
					if rid then r.reagents[#r.reagents + 1] = { item = rid, qty = count or 1, name = rname } end
				end
				local cd = GetTradeSkillCooldown and GetTradeSkillCooldown(i)
				if type(cd) == "number" and cd > 0 then r.cooldown = cd end
				list[#list + 1] = r
			end
		end
	end
	return list
end

local function classicProfession()
	if GetTradeSkillLine then return GetTradeSkillLine() end
end

-- Reading and keeping ----------------------------------------------------------------------------

--- Which reader works right now: "modern", "classic" or nil (no profession open).
function R.Reader()
	local ok, m = pcall(modernReady)
	if ok and m then return "modern" end
	ok, m = pcall(classicReady)
	if ok and m then return "classic" end
	return nil
end

--- Reads the open profession. Returns { name, skill, max, recipes, at, reader } or nil.
function R.ReadOpen()
	local reader = R.Reader()
	if not reader then return nil end
	local ok, list = pcall(reader == "modern" and modernRead or classicRead)
	if not ok or #list == 0 then return nil end
	local name, skill, max = (reader == "modern" and modernProfession or classicProfession)()
	local t = now()
	for _, r in ipairs(list) do
		if r.cooldown then r.readyAt = t + r.cooldown end
		r.profession = name
	end
	return { name = name or "Profession", skill = skill, max = max, recipes = list, at = t, reader = reader }
end

local function store()
	local me = AuctionIQ.Me()
	me.crafting = me.crafting or {}
	return me.crafting
end

--- Reads the open profession and keeps it for this character. Returns what was read, or nil.
function R.Refresh()
	local p = R.ReadOpen()
	if not p then return nil end
	store()[p.name] = p
	R.open = p.name
	return p
end

--- Professions saved for this character, by name, open one first.
function R.Professions()
	local out = {}
	for name in pairs(store()) do out[#out + 1] = name end
	table.sort(out, function(a, b)
		if a == R.open then return true elseif b == R.open then return false end
		return a < b
	end)
	return out
end

function R.Get(name)
	return name and store()[name] or nil
end

--- Cooldowns across every character: { name, char, readyAt } with the soonest first. Recipes ready
--- for more than a week are left out (nobody's using them).
function R.Cooldowns(at)
	at = at or now()
	local out = {}
	for key, c in pairs(AuctionIQ.db.characters or {}) do
		for _, p in pairs(c.crafting or {}) do
			for _, r in ipairs(p.recipes or {}) do
				if r.readyAt and at - r.readyAt < 7 * 86400 then
					out[#out + 1] = { name = r.name, char = c.name or key:match("^(.-)%-") or key, readyAt = r.readyAt }
				end
			end
		end
	end
	table.sort(out, function(a, b) return a.readyAt < b.readyAt end)
	return out
end

--- Crafts one: CraftRecipe on the retail-style API, DoTradeSkill on Classic. Needs the profession
--- open and a click (a hardware event). Returns true when the game was asked to craft.
function R.Craft(r, count)
	count = count or 1
	if r.source == "modern" and C_TradeSkillUI and C_TradeSkillUI.CraftRecipe then
		return pcall(C_TradeSkillUI.CraftRecipe, r.recipeID, count)
	end
	if r.source == "classic" and DoTradeSkill and r.index then
		-- the list can reorder after a skill-up; find the recipe by name again
		local i = r.index
		if GetTradeSkillInfo and GetTradeSkillInfo(i) ~= r.name then
			for n = 1, (GetNumTradeSkills and GetNumTradeSkills() or 0) do
				if GetTradeSkillInfo(n) == r.name then i = n; break end
			end
		end
		return pcall(DoTradeSkill, i, count)
	end
	return false
end

--- Selects the recipe in the game's own profession window too, where that's possible.
function R.Select(r)
	if r.source == "classic" and r.index then
		if TradeSkillFrame_SetSelection then pcall(TradeSkillFrame_SetSelection, r.index)
		elseif SelectTradeSkill then pcall(SelectTradeSkill, r.index) end
		if TradeSkillFrame_Update then pcall(TradeSkillFrame_Update) end
	elseif r.source == "modern" and C_TradeSkillUI and C_TradeSkillUI.OpenRecipe then
		pcall(C_TradeSkillUI.OpenRecipe, r.recipeID)
	end
end

-- Probe ------------------------------------------------------------------------------------------
-- /aiq probe: which crafting calls this client has, what they answer for the open profession, and
-- which crafting events fired this session. Kept in saved data (db.probe) for after /reload.

R.PROBE_CALLS = {
	"C_TradeSkillUI.GetAllRecipeIDs", "C_TradeSkillUI.GetRecipeInfo", "C_TradeSkillUI.GetRecipeSchematic",
	"C_TradeSkillUI.CraftRecipe", "C_TradeSkillUI.GetRecipeCooldown", "C_TradeSkillUI.IsTradeSkillReady",
	"C_TradeSkillUI.GetBaseProfessionInfo", "C_TradeSkillUI.OpenRecipe",
	"GetNumTradeSkills", "GetTradeSkillInfo", "GetTradeSkillItemLink", "GetTradeSkillNumMade",
	"GetTradeSkillReagentInfo", "GetTradeSkillReagentItemLink", "GetTradeSkillCooldown", "GetTradeSkillLine",
	"DoTradeSkill", "SelectTradeSkill", "TradeSkillFrame_SetSelection",
}
R.PROBE_EVENTS = { "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_UPDATE", "TRADE_SKILL_CLOSE",
	"TRADE_SKILL_ITEM_CRAFTED_RESULT", "UNIT_SPELLCAST_SUCCEEDED", "NEW_RECIPE_LEARNED", "CHAT_MSG_LOOT" }

local seen = {}
R.seen = seen

local function lookup(path)
	local v = _G
	for part in path:gmatch("[^%.]+") do
		if type(v) ~= "table" then return nil end
		v = v[part]
	end
	return v
end

function R.Probe()
	local out = { at = now(), game = AuctionIQ.Game, version = AuctionIQ.version, calls = {}, events = {} }
	for _, c in ipairs(R.PROBE_CALLS) do out.calls[c] = type(lookup(c)) == "function" end
	out.reader = R.Reader()
	local p = R.ReadOpen()
	if p then
		out.profession = { name = p.name, skill = p.skill, max = p.max, recipes = #p.recipes, reader = p.reader }
		local first = p.recipes[1]
		if first then
			out.sample = { name = first.name, item = first.item, makes = first.makes, reagents = #first.reagents, canMake = first.canMake, cooldown = first.cooldown }
		end
	end
	for _, e in ipairs(R.PROBE_EVENTS) do out.events[e] = seen[e] end
	out.frames = {}
	for _, f in ipairs({ "TradeSkillFrame", "ProfessionsFrame" }) do
		local fr = _G[f]
		out.frames[f] = fr and (fr.IsShown and fr:IsShown() and "shown" or "hidden") or false
	end
	-- Merchant's Favor: the currency's ID, and any Waylaid Crates in the bags (their item IDs)
	local cur = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo
	if cur then
		for id = 1, 4000 do
			local ok, c = pcall(cur, id)
			if ok and type(c) == "table" and c.name and c.name:find("Favor") then out.favor = { id = id, name = c.name, quantity = c.quantity }; break end
		end
	end
	local C = C_Container
	if C and C.GetContainerNumSlots and C.GetContainerItemInfo then
		out.crates = {}
		for bag = 0, 4 do
			for slot = 1, (C.GetContainerNumSlots(bag) or 0) do
				local ok, info = pcall(C.GetContainerItemInfo, bag, slot)
				local link = ok and type(info) == "table" and info.hyperlink
				if link and link:find("Crate") then out.crates[#out.crates + 1] = { id = tonumber(link:match("item:(%d+)")), name = link:match("%[(.-)%]") } end
			end
		end
	end
	AuctionIQ.db.probe = out
	return out
end

function R.ProbeLines(p)
	p = p or AuctionIQ.db.probe
	if not p then return { "no probe yet: open a profession, then /aiq probe" } end
	local have, missing = {}, {}
	for _, c in ipairs(R.PROBE_CALLS) do
		local list = p.calls[c] and have or missing
		list[#list + 1] = c:gsub("^C_TradeSkillUI%.", "C_")
	end
	local lines = { "crafting reader: " .. tostring(p.reader or "none (open a profession first)") }
	if p.profession then
		lines[#lines + 1] = ("%s %s/%s: %d recipes"):format(tostring(p.profession.name), tostring(p.profession.skill), tostring(p.profession.max), p.profession.recipes)
	end
	if p.sample then
		lines[#lines + 1] = ("first: %s makes %s, %d reagents, can make %s%s"):format(tostring(p.sample.name), tostring(p.sample.makes), p.sample.reagents, tostring(p.sample.canMake), p.sample.cooldown and (", cooldown " .. p.sample.cooldown .. "s") or "")
	end
	if p.favor then lines[#lines + 1] = ("Merchant's Favor: currency %d, you have %s"):format(p.favor.id, tostring(p.favor.quantity)) end
	for _, c in ipairs(p.crates or {}) do lines[#lines + 1] = ("crate in bags: %s (item %s)"):format(tostring(c.name), tostring(c.id)) end
	lines[#lines + 1] = "missing calls: " .. (#missing > 0 and table.concat(missing, ", ") or "none")
	local ev = {}
	for _, e in ipairs(R.PROBE_EVENTS) do
		if p.events[e] then ev[#ev + 1] = e .. " x" .. p.events[e].n end
	end
	lines[#lines + 1] = "events this session: " .. (#ev > 0 and table.concat(ev, ", ") or "none yet")
	return lines
end

for _, e in ipairs(R.PROBE_EVENTS) do
	AuctionIQ.On(e, function(_, ...)
		if e == "UNIT_SPELLCAST_SUCCEEDED" and ... ~= "player" then return end
		local s = seen[e] or { n = 0 }
		s.n = s.n + 1
		local args = { ... }
		for i = 1, math.min(#args, 4) do args[i] = type(args[i]) == "table" and "table" or tostring(args[i]) end
		s.last = table.concat(args, ", ", 1, math.min(#args, 4))
		seen[e] = s
	end)
end

-- Keep the saved copy fresh while the profession is open. The list events come in bursts, so one
-- read follows a burst.
local pending = false
local function read()
	pending = false
	if not AuctionIQ.db then return end
	local p = R.Refresh()
	if p and R.onRefresh then R.onRefresh(p) end
end
local function refresh()
	if pending then return end
	pending = true
	if C_Timer and C_Timer.After then C_Timer.After(0.2, read) else read() end
end
AuctionIQ.On("TRADE_SKILL_SHOW", refresh)
AuctionIQ.On("TRADE_SKILL_LIST_UPDATE", refresh)
AuctionIQ.On("TRADE_SKILL_UPDATE", refresh)
AuctionIQ.On("TRADE_SKILL_CLOSE", function() R.open = nil; if R.onClose then R.onClose() end end)
