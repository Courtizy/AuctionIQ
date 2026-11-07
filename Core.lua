-- Clearinghouse: core, saved data and slash commands.
local addonName, CH = ...
_G.Clearinghouse = CH

CH.version = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addonName, "Version") or "dev"
CH.AH_CUT = 0.95
-- Concentration refills from empty to its 1,000 cap in about four days.
CH.CONC_PER_HOUR = 1000 / (4 * 24)

local DEFAULTS = { version = 1, settings = { tooltip = true }, characters = {} }

local function copyDefaults(dst, src)
	for k, v in pairs(src) do
		if dst[k] == nil then
			dst[k] = type(v) == "table" and copyDefaults({}, v) or v
		elseif type(v) == "table" and type(dst[k]) == "table" then
			copyDefaults(dst[k], v)
		end
	end
	return dst
end

function CH.Print(msg)
	print("|cffe0a83aClearinghouse|r: " .. tostring(msg))
end

-- "12,345g", "12g 50s", "75s", "9c": short enough for a tooltip line.
function CH.FormatMoney(copper)
	if not copper then return "-" end
	local neg = copper < 0
	copper = math.floor(math.abs(copper) + 0.5)
	local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	local out
	if g >= 100 then
		local str = tostring(g)
		local k
		repeat
			str, k = str:gsub("^(%d+)(%d%d%d)", "%1,%2")
		until k == 0
		out = str .. "g"
	elseif g > 0 then
		out = s > 0 and string.format("%dg %ds", g, s) or (g .. "g")
	elseif s > 0 then
		out = s .. "s"
	else
		out = c .. "c"
	end
	return (neg and "-" or "") .. out
end

function CH.CharacterKey()
	return UnitName("player") .. "-" .. GetRealmName()
end

-- This character's record, created on first use.
function CH.Me()
	local key = CH.CharacterKey()
	local chars = CH.db.characters
	if not chars[key] then
		local _, class = UnitClass("player")
		chars[key] = { name = UnitName("player"), realm = GetRealmName(), class = class, professions = {} }
	end
	return chars[key]
end

local function updateGold()
	local me = CH.Me()
	me.gold = GetMoney()
	me.updated = time()
end

local frame = CreateFrame("Frame")
CH.eventFrame = frame
local handlers = {}
CH.handlers = handlers

function CH.On(event, fn)
	handlers[event] = handlers[event] or {}
	table.insert(handlers[event], fn)
	frame:RegisterEvent(event)
end

frame:SetScript("OnEvent", function(_, event, ...)
	for _, fn in ipairs(handlers[event] or {}) do
		fn(event, ...)
	end
end)

CH.On("ADDON_LOADED", function(_, name)
	if name ~= addonName then return end
	ClearinghouseDB = copyDefaults(ClearinghouseDB or {}, DEFAULTS)
	CH.db = ClearinghouseDB
end)

CH.On("PLAYER_LOGIN", function()
	updateGold()
	if not CH.Prices.Available() then
		CH.Print("TradeSkillMaster isn't loaded, so prices are off. Install TSM to see values and profits.")
	end
end)
CH.On("PLAYER_MONEY", updateGold)

SLASH_CLEARINGHOUSE1 = "/clearinghouse"
SLASH_CLEARINGHOUSE2 = "/ch"
SlashCmdList.CLEARINGHOUSE = function(msg)
	msg = strtrim and strtrim(msg or ""):lower() or (msg or ""):lower()
	if msg == "tooltip" then
		CH.db.settings.tooltip = not CH.db.settings.tooltip
		CH.Print("tooltip lines " .. (CH.db.settings.tooltip and "on" or "off"))
	elseif msg == "help" then
		CH.Print("/ch opens the window. /ch tooltip turns the tooltip lines on or off.")
	else
		CH.UI.Toggle()
	end
end

function Clearinghouse_OnAddonCompartmentClick()
	CH.UI.Toggle()
end
