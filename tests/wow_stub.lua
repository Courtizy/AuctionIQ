-- Minimal stand-ins for the WoW API, enough to load Clearinghouse and drive its events.
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

local function newFrame()
	local f = { shown = false, scripts = {} }
	function f:RegisterEvent(e) events[e] = events[e] or {}; table.insert(events[e], self) end
	function f:SetScript(k, fn) self.scripts[k] = fn end
	function f:SetPoint(...) self.point = { ... } end
	function f:Show() self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end
	function f:Hide() self.shown = false end
	function f:IsShown() return self.shown end
	function f:CreateFontString()
		local fs = { t = "" }
		function fs:SetText(t) self.t = t end
		function fs:GetStringHeight() return 100 end
		function fs:GetParent() return f end
		setmetatable(fs, { __index = function() return function() end end })
		return fs
	end
	function f:CreateTexture() return setmetatable({}, { __index = function() return function() end end }) end
	f.TitleText = f:CreateFontString()
	setmetatable(f, { __index = function() return function() end end })
	return f
end
function CreateFrame() return newFrame() end
UIParent = newFrame()
function Mixin(t) return t end
Minimap = newFrame()
function Minimap:GetWidth() return 140 end
function Minimap:GetCenter() return 100, 100 end
function Minimap:GetEffectiveScale() return 1 end
function GetCursorPosition() return 200, 100 end
BackdropTemplateMixin = {}

function STUB.Fire(event, ...)
	for _, f in ipairs(events[event] or {}) do f.scripts.OnEvent(f, event, ...) end
end

-- TSM: prices keyed by item string; "crafting" costs separately. chvalue is not a custom source here,
-- so Clearinghouse must fall back to passing the formula itself.
STUB.prices = { ["i:100"] = { formula_value = 5000000, crafting = 1000000, mat = 4500000 } }
TSM_API = {
	ToItemString = function(item) local id = tostring(item):match("item:(%d+)") or tostring(item):match("^i:(%d+)"); return id and ("i:" .. id) end,
	IsCustomPriceValid = function(s) return s ~= "chvalue" and s ~= "chmat" end,
	GetCustomPriceValue = function(s, item)
		local p = STUB.prices[item]; if not p then return nil, "no data" end
		if s == "crafting" then return p.crafting end
		if s:sub(1, 4) == "min(" then return p.formula_value end
		if s:sub(1, 4) == "max(" then return p.mat end
		return nil, "unknown"
	end,
}

-- Tooltips
Enum = { TooltipDataType = { Item = 0 } }
GameTooltip = { lines = {} }
function GameTooltip:GetItem() return "Potion", STUB.tooltipLink end
function GameTooltip:AddDoubleLine(a, b) table.insert(self.lines, a .. "=" .. b) end
TooltipDataProcessor = { AddTooltipPostCall = function(_, fn) STUB.tooltipFn = fn end }

-- Professions
C_CurrencyInfo = { GetCurrencyInfo = function() return { quantity = 400, maxQuantity = 1000 } end }
C_TradeSkillUI = {
	IsTradeSkillReady = function() return true end,
	IsTradeSkillLinked = function() return false end,
	IsTradeSkillGuild = function() return false end,
	IsNPCCrafting = function() return false end,
	GetChildProfessionInfo = function() return { professionID = 2906, professionName = "Midnight Enchanting", skillLevel = 80, maxSkillLevel = 100 } end,
	GetConcentrationCurrencyID = function() return 3000 end,
	GetAllRecipeIDs = function() return { 1, 2, 3 } end,
	GetRecipeInfo = function(id)
		if id == 1 then return { learned = true, name = "Phoenix Oil", qualityItemIDs = { 99, 100 } } end
		if id == 2 then return { learned = false, name = "Unlearned", qualityItemIDs = { 100 } } end
		return { learned = true, name = "No price", qualityItemIDs = { 555 } }
	end,
	GetRecipeSchematic = function() return { outputItemID = 555 } end,
}
