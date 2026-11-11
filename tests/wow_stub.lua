-- Minimal stand-ins for the WoW API, enough to load AuctionIQ and drive its events.
local events, timers = {}, {}
STUB = { now = 1000000, gametime = 0, money = 1234567, tooltips = {} }

function time() return STUB.now end
function GetTime() return STUB.gametime end
function GetMoney() return STUB.money end
function UnitName() return "Seyko" end
function UnitClass() return "Druid", "DRUID" end
function GetRealmName() return "Emerald Dream" end
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
SlashCmdList, UISpecialFrames, RAID_CLASS_COLORS = {}, {}, { DRUID = { colorStr = "ffff7c0a" } }
C_AddOns = { GetAddOnMetadata = function() return "test" end }
C_Timer = { After = function(_, fn) table.insert(timers, fn) end }
function STUB.RunTimers() local t = timers; timers = {}; for _, fn in ipairs(t) do fn() end end

-- Frames keep their parent, size, anchor and children so tests/layout_audit.lua can check that
-- nothing sits outside its panel. Text width is estimated from the font: about 6 px a character
-- for small fonts, 7 for normal, 8.5 for large; a texture escape counts as one icon.
STUB.frames = {}
local function textWidth(t, font)
	t = tostring(t or "")
	local icons = 0
	t = t:gsub("|T.-|t", function() icons = icons + 1; return "" end):gsub("|A.-|a", function() icons = icons + 1; return "" end)
	t = t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h", ""):gsub("|h", "")
	local longest = 0
	for line in (t .. "\n"):gmatch("(.-)\n") do longest = math.max(longest, #line) end
	local per = (font or ""):find("Large") and 8.5 or (font or ""):find("Small") and 6 or 7
	return longest * per + icons * 15
end
STUB.TextWidth = textWidth

-- Geometry off the whole-unit grid: where a SetPoint offset or a size isn't a whole number, by
-- the addon's file and line. A window scaled to whole pixels per unit is pixel-perfect only when
-- everything on it sits on whole units.
STUB.frac = {}
local function whole(...)
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		if type(v) == "number" and math.abs(v - math.floor(v + 0.5)) > 1e-6 then
			local where = "?"
			for lvl = 3, 8 do
				local info = debug.getinfo(lvl, "Sl")
				if info and info.short_src and not info.short_src:find("stub") and not info.short_src:find("audit") then where = info.short_src .. ":" .. (info.currentline or 0); break end
			end
			STUB.frac[where] = v
			return
		end
	end
end
STUB.whole = whole

local function newFrame(parent, kind, template)
	local f = { shown = false, scripts = {}, parent = parent, kind = kind, xmlTemplate = template, kids = {}, texts = {}, w = 0, h = 0, points = {} }
	if type(parent) == "table" and type(rawget(parent, "kids")) == "table" then table.insert(parent.kids, f) end
	table.insert(STUB.frames, f)
	-- as in WoW, registering an event a frame already has does nothing (it fires once per frame)
	function f:RegisterEvent(e) events[e] = events[e] or {}; for _, x in ipairs(events[e]) do if x == self then return end end; table.insert(events[e], self) end
	function f:SetScript(k, fn) self.scripts[k] = fn end
	-- scale chain, as in WoW: a frame's effective scale is its own times its parent's; UIParent's is
	-- the UI scale (STUB.uiScale)
	function f:GetChildren() return unpack(rawget(self, "kids") or {}) end
	function f:SetScale(v) self.scale = v end
	function f:GetScale() return rawget(self, "scale") or 1 end
	function f:GetEffectiveScale()
		if self == UIParent then return STUB.uiScale or 1 end
		local p = rawget(self, "parent")
		local ps = (type(p) == "table" and p.GetEffectiveScale) and p:GetEffectiveScale() or (STUB.uiScale or 1)
		return (rawget(self, "scale") or 1) * ps
	end
	function f:SetPoint(...) whole(select(2, ...)); self.point = { ... }; table.insert(self.points, { ... }) end
	function f:ClearAllPoints() self.point = nil; self.points = {} end
	function f:SetAllPoints() self.fill = true end
	function f:SetSize(w, h) whole(w, h); self.w, self.h = w or self.w, h or self.h end
	function f:SetWidth(w) whole(w); self.w = w end
	function f:SetHeight(h) whole(h); self.h = h end
	function f:GetWidth() return self.w end
	function f:GetHeight() return self.h end
	function f:GetParent() return self.parent end
	function f:SetTemplate(t) self.template = t end
	function f:Show() self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end
	function f:Hide() local was = self.shown; self.shown = false; if was and self.scripts.OnHide then self.scripts.OnHide(self) end end
	function f:SetShown(v) if v then self:Show() else self:Hide() end end
	function f:HookScript(k, fn) local old = self.scripts[k]; self.scripts[k] = function(...) if old then old(...) end fn(...) end end
	function f:IsShown() return self.shown end
	function f:SetText(t) self.label = t; if self.scripts.OnTextChanged then self.scripts.OnTextChanged(self) end end
	function f:GetText() return self.label end
	function f:GetFontString() return nil end
	function f:CreateFontString(_, _, font)
		local fs = { t = "", font = font, w = 0, wrap = true, hidden = false, owner = f, points = {} }
		function fs:SetText(t) self.t = t end
		function fs:GetText() return self.t end
		function fs:GetStringHeight() return 100 end
		function fs:GetStringWidth() return textWidth(self.t, self.font) end
		function fs:GetParent() return f end
		function fs:SetWidth(w) whole(w); self.w = w end
		function fs:SetPoint(...) whole(select(2, ...)); self.point = { ... }; table.insert(self.points, { ... }) end
		function fs:ClearAllPoints() self.point = nil; self.points = {} end
		function fs:SetFontObject(o) self.font = o end
		function fs:SetWordWrap(v) self.wrap = v end
		function fs:SetMaxLines(n) self.maxLines = n end
		function fs:Hide() self.hidden = true end
		function fs:Show() self.hidden = false end
		function fs:SetShown(v) self.hidden = not v end
		setmetatable(fs, { __index = function() return function() end end })
		table.insert(f.texts, fs)
		return fs
	end
	function f:CreateTexture()
		local t = { shown = true }
		if not rawget(f, "texs") then rawset(f, "texs", {}) end
		table.insert(rawget(f, "texs"), t)
		function t:SetVertexColor(r, g, b) self.vc = { r, g, b } end
		function t:SetPoint(...) whole(select(2, ...)); self.pt = { ... } end
		function t:ClearAllPoints() self.pt = nil end
		function t:SetSize(w, h) whole(w, h); self.w, self.h = w, h end
		function t:SetWidth(w) whole(w); self.w = w end
		function t:SetHeight(h) whole(h); self.h = h end
		function t:Show() self.shown = true end
		function t:Hide() self.shown = false end
		function t:SetShown(v) self.shown = v and true or false end
		return setmetatable(t, { __index = function() return function() end end })
	end
	f.TitleText = f:CreateFontString()
	setmetatable(f, { __index = function() return function() end end })
	return f
end
function CreateFrame(kind, name, parent, template) local f = newFrame(parent, kind, template); if name then _G[name] = f end; return f end
UIParent = newFrame()
function GetPhysicalScreenSize() return STUB.screenW or 1920, STUB.screenH or 1080 end
UIParent.w, UIParent.h = 1920, 1080
function Mixin(t) return t end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function IsShiftKeyDown() return STUB.shift end
Minimap = newFrame()
function Minimap:GetWidth() return 140 end
function Minimap:GetCenter() return 100, 100 end
function Minimap:GetEffectiveScale() return 1 end
function GetCursorPosition() return 200, 100 end
BackdropTemplateMixin = {}
function debugprofilestop() return os.clock() * 1000 end

function STUB.Fire(event, ...)
	for _, f in ipairs(events[event] or {}) do f.scripts.OnEvent(f, event, ...) end
end

-- TSM: prices keyed by item string; "crafting" costs separately. chvalue is not a custom source here,
-- so AuctionIQ must fall back to passing the formula itself.
STUB.prices = { ["i:100"] = { formula_value = 5000000, crafting = 1000000, mat = 4500000 } }
for id, g in pairs({ [201] = 10, [202] = 15, [203] = 5, [204] = 30, [205] = 1, [211] = 2, [212] = 6, [221] = 3, [222] = 8 }) do STUB.prices["i:" .. id] = { mat = g * 10000 } end
STUB.prices["i:38682"] = { mat = 1 * 10000 } -- Enchanting Vellum
STUB.prices["i:301"] = { formula_value = 100 * 10000 }
STUB.prices["i:302"] = { formula_value = 300 * 10000, sold = 5 }
STUB.prices["i:301"].sold = 5
STUB.prices["i:311"] = { formula_value = 20 * 10000, sold = 40 }
STUB.prices["i:312"] = { formula_value = 50 * 10000, sold = 40 }
-- Test Rod (12): gear, one item ID for all five qualities, priced by item level (base 200, +0..+12)
for q, g in ipairs({ 10, 20, 40, 80, 160 }) do STUB.prices["i:320::i" .. (197 + 3 * q)] = { formula_value = g * 10000, sold = 5 } end
TSM_API = {
	ToItemString = function(item)
		if tostring(item):match("^i:%d+::i%d+$") then return item end
		local id = tostring(item):match("item:(%d+)") or tostring(item):match("^i:(%d+)"); return id and ("i:" .. id)
	end,
	IsCustomPriceValid = function(s) return s ~= "chvalue" and s ~= "chmat" end,
	GetCustomPriceValue = function(s, item)
		local p = STUB.prices[item]; if not p then return nil, "no data" end
		if s == "crafting" then return p.crafting end
		if s == "matprice" then return p.matprice end
		if s:sub(1, 4) == "min(" then return p.formula_value end
		if s:sub(1, 4) == "max(" then return p.mat end
		if s == "dbmarket" then return p.formula_value end
		if s == "dbregionsoldperday" then return p.sold end
		return nil, "unknown"
	end,
}

-- Tooltips
Enum = { TooltipDataType = { Item = 0 } }
GameTooltip = { lines = {} }
function GameTooltip:GetItem() return "Potion", STUB.tooltipLink end
function GameTooltip:AddDoubleLine(a, b) table.insert(self.lines, a .. "=" .. b) end
function GameTooltip:SetOwner() self.lines = {} end
function GameTooltip:AddLine(a) table.insert(self.lines, a) end
function GameTooltip:Show() end
function GameTooltip:Hide() end
TooltipDataProcessor = { AddTooltipPostCall = function(_, fn) STUB.tooltipFn = fn end }

-- Professions
STUB.bags = { [201] = 9, [202] = 8, [203] = 20, [204] = 12, [205] = 3, [211] = 30, [212] = 9, [221] = 2 }
C_Item = { GetItemCount = function(id) if id == nil then error("bad argument #1 to GetItemCount") end return STUB.bags[id] or 0 end }
C_CurrencyInfo = { GetCurrencyInfo = function() return { quantity = 400, maxQuantity = 1000 } end }
C_TradeSkillUI = {
	IsTradeSkillReady = function() return true end,
	IsTradeSkillLinked = function() return false end,
	IsTradeSkillGuild = function() return false end,
	IsNPCCrafting = function() return false end,
	GetChildProfessionInfo = function() return { professionID = 2906, profession = 3, parentProfessionName = "Alchemy", professionName = "Midnight Enchanting", skillLevel = 80, maxSkillLevel = 100 } end,
	GetProfessionSlots = function() return { 20, 21, 22 } end,
	GetBaseProfessionInfo = function() return { professionID = STUB.base } end,
	OpenTradeSkill = function(line) STUB.base = line; STUB.opened = (STUB.opened or "") .. line .. "," end,
	CloseTradeSkill = function() STUB.closed = true end,
	GetChildProfessionInfos = function() return { { professionID = 2906, expansionName = "Midnight" }, { professionID = 2871, expansionName = "Khaz Algar" } } end,
	GetTradeSkillLineForRecipe = function(id)
		if id == 11 then return 2871, "Khaz Algar Alchemy", 171 end
		return 2906, "Midnight Alchemy", 171
	end,
	GetCategoryInfo = function(id) return ({ [50] = { name = "Potions" }, [60] = { name = "Flasks" } })[id] end,
	GetRecipeCooldown = function(id) if id == 1 then return 7200, true, 0, 0 end return 0 end,
	GetConcentrationCurrencyID = function() return 3000 end,
	GetAllRecipeIDs = function() return STUB.recipeIDs or { 1, 2, 3, 10, 11 } end,
	GetRecipeInfo = function(id)
		if id == 10 then return { learned = true, name = "Test Flask", supportsQualities = true, qualityItemIDs = { 301, 302 }, categoryID = 60 } end
		if id == 11 then return { learned = true, name = "Test Potion", supportsQualities = true, qualityItemIDs = { 311, 312 }, categoryID = 50 } end
		if id == 12 then return { learned = true, name = "Test Rod", supportsQualities = true, qualityItemIDs = {}, maxQuality = 5,
			qualityIlvlBonuses = { 0, 3, 6, 9, 12 } } end
		if id == 1 then return { learned = true, name = "Phoenix Oil", qualityItemIDs = { 99, 100 } } end
		if id == 2 then return { learned = false, name = "Unlearned", qualityItemIDs = { 100 } } end
		return { learned = true, name = "No price", qualityItemIDs = { 555 } }
	end,
	GetReagentSlotStatus = function(mcr) return STUB.lockedSlot == mcr end,
	GetRecipeSchematic = function(id)
		if id == 10 then
			return { outputItemID = 301, quantityMin = 1, quantityMax = 1, reagentSlotSchematics = {
				{ reagentType = 1, required = true, dataSlotIndex = 1, quantityRequired = 4, reagents = { { itemID = 201 }, { itemID = 202 } } },
				{ reagentType = 1, required = true, dataSlotIndex = 2, quantityRequired = 5, reagents = { { itemID = 203 }, { itemID = 204 } } },
				{ reagentType = 1, required = true, dataSlotIndex = 3, quantityRequired = 2, reagents = { { itemID = 205 } } },
				{ reagentType = 0, required = false, dataSlotIndex = 4, quantityRequired = 1, reagents = { { itemID = 999 } } },
			} }
		end
		if id == 11 then
			return { recipeID = 11, outputItemID = 311, quantityMin = 2, quantityMax = 2, reagentSlotSchematics = {
				{ reagentType = 1, required = true, dataSlotIndex = 1, quantityRequired = 3, reagents = { { itemID = 211 }, { itemID = 212 } } },
				{ reagentType = 2, required = false, dataSlotIndex = 5, quantityRequired = 1, slotInfo = { mcrSlotID = 77 }, reagents = { { itemID = 221 }, { itemID = 222 } } },
			} }
		end
		if id == 12 then
			return { outputItemID = 320, quantityMin = 1, quantityMax = 1, reagentSlotSchematics = {
				{ reagentType = 1, required = true, dataSlotIndex = 1, quantityRequired = 3, reagents = { { itemID = 211 }, { itemID = 212 } } },
			} }
		end
		return { outputItemID = 555 }
	end,
	-- Skill 100 plus 5 per top-quality unit in slot 1 and 2 per unit in slot 2; quality 2 from 130.
	-- Concentration always lands on quality 2 and costs 20 + 2 per missing skill point.
	CraftRecipe = function(id, n, reagents, _, order, conc) STUB.crafted = { id = id, n = n, reagents = reagents, conc = conc, order = order } end,
	-- Test Potion (11): skill 100 + 10 per top-quality unit, +10 with finishing reagent 221; quality 2
	-- from 130. 20% Multicraft (+15% with finishing reagent 222), 20% Resourcefulness, 30% Ingenuity.
	GetCraftingOperationInfo = function(recipeID, infos, _, concentrate)
		local bonus, mc = STUB.extraSkill or 0, 220
		for _, r in ipairs(infos) do
			local id = r.reagent and r.reagent.itemID
			if id == 202 then bonus = bonus + 5 * r.quantity elseif id == 204 then bonus = bonus + 2 * r.quantity end
			if id == 212 then bonus = bonus + 10 * r.quantity elseif id == 221 then bonus = bonus + 10 elseif id == 222 then mc = mc + 165 end
		end
		local skill = 100 + bonus
		local q = skill >= 130 and 2 or 1
		local stats = {}
		if recipeID == 11 then
			stats = { { bonusStatName = "Multicraft", bonusStatValue = mc, ratingPct = mc / 11 },
				{ bonusStatName = "Resourcefulness", bonusStatValue = 180, ratingPct = 20 },
				{ bonusStatName = "Ingenuity", bonusStatValue = 300, ratingPct = 30 } }
		end
		return { baseSkill = 100, bonusSkill = bonus, baseDifficulty = 130, craftingQuality = (concentrate and 2 or q) + (STUB.qualityOffset or 0),
			lowerSkillThreshold = q == 2 and 130 or 0, upperSkillTreshold = q == 1 and 130 or 0,
			concentrationCost = 20 + 2 * math.max(0, 130 - skill), bonusStats = stats, craftingDataID = STUB.craftingDataID }
	end,
}

C_TradeSkillUI.GetCraftingOperationInfoForOrder = function(id, infos, orderID, conc)
	STUB.orderCall = orderID
	return C_TradeSkillUI.GetCraftingOperationInfo(id, infos, nil, conc)
end
function hooksecurefunc(t, name, fn)
	if type(t) == "string" then t, name, fn = _G, t, name end
	local orig = t[name]
	t[name] = function(...) local r = { orig(...) }; fn(...); return (table.unpack or unpack)(r) end
end
unpack = unpack or table.unpack

-- Specialization trees
STUB.ranks = { [900] = 0, [901] = -1 }
C_ProfSpecs = {
	GetConfigIDForSkillLine = function() return 1 end,
	GetCurrencyInfoForSkillLine = function() return { numAvailable = 10, currencyName = "Knowledge" } end,
	GetUnlockRankForPerk = function(id) return ({ [9001] = 10 })[id] or 0 end,
	GetSpecTabIDsForSkillLine = function() return { 1 } end,
	GetRootPathForTab = function() return 900 end,
	GetChildrenForPath = function(id) return id == 900 and { 901 } or {} end,
	GetTabInfo = function() return { name = "Test Mastery" } end,
}
C_Traits = {
	GetNodeInfo = function(_, id) return { activeRank = (STUB.ranks[id] or -1) + 1, entryIDs = { id }, posX = id * 10, posY = id == 900 and 0 or 600 } end,
	GetEntryInfo = function(_, id) return { definitionID = id } end,
	GetDefinitionInfo = function(id) return { overrideName = "Node " .. id } end,
}

-- Profession gear: worn tool 401 (+5 skill), accessories 402 and 403; a better tool 404 (+30 skill) in the bags.
STUB.items = {
	[401] = { loc = "INVTYPE_PROFESSION_TOOL", skill = 5 }, [402] = { loc = "INVTYPE_PROFESSION_GEAR" },
	[403] = { loc = "INVTYPE_PROFESSION_GEAR" }, [404] = { loc = "INVTYPE_PROFESSION_TOOL", skill = 30 },
}
STUB.worn = { [20] = "item:401", [21] = "item:402", [22] = "item:403" }
STUB.bagItems = { [0] = { "item:404" } }
local function idOf(link) return tonumber(tostring(link):match("item:(%d+)")) end
C_Item.GetItemInfoInstant = function(link) local id = idOf(link); local it = STUB.items[id]; return id, nil, nil, it and it.loc, nil, 19, 2 end
C_Item.GetItemStats = function() return {} end
C_TooltipInfo = { GetHyperlink = function(link) local it = STUB.items[idOf(link)]
	return { lines = { { leftText = it and it.skill and ("Equip: +" .. it.skill .. " Alchemy Skill") or "" } } } end }
function GetInventoryItemLink(_, slot) return STUB.worn[slot] end
C_Container = { GetContainerNumSlots = function(bag) return STUB.bagItems[bag] and #STUB.bagItems[bag] or 0 end,
	GetContainerItemLink = function(bag, s) return STUB.bagItems[bag] and STUB.bagItems[bag][s] end,
	PickupContainerItem = function(bag, s) STUB.cursor = STUB.bagItems[bag][s] end }
function EquipCursorItem(slot) STUB.equipped = STUB.equipped or {}; STUB.equipped[slot] = STUB.cursor end
function InCombatLockdown() return false end
STUB.base = 171
function GetProfessions() return 1, 2, nil, nil, 3 end
function GetProfessionInfo(i) return ({ "Alchemy", "Enchanting", "Cooking" })[i], 0, 1, 100, 0, 0, ({ 171, 333, 185 })[i] end
date = os.date

-- Auction House (posting)
STUB.ahPosts = {}
ItemLocation = { CreateFromBagAndSlot = function(_, bag, slot) return { bag = bag, slot = slot } end }
Enum.ItemCommodityStatus = { Item = 1, Commodity = 2 }
C_AuctionHouse = {
	GetItemCommodityStatus = function() return 1 end,
	PostItem = function(loc, dur, qty, bid, buyout) table.insert(STUB.ahPosts, { dur = dur, qty = qty, buyout = buyout }) end,
	PostCommodity = function(loc, dur, qty, unit) table.insert(STUB.ahPosts, { dur = dur, qty = qty, buyout = unit, commodity = true }) end,
}
