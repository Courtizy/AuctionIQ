-- AuctionIQ: core, saved data and slash commands. Clearinghouse is its ledger (the books).
local addonName, CH = ...
_G.AuctionIQ = CH
_G.Clearinghouse = CH -- the old name, for macros and the tests
CH.ICON = "Interface\\AddOns\\" .. addonName .. "\\Media\\Icon"

CH.version = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addonName, "Version") or "dev"
CH.AH_CUT = 0.95
-- Concentration refills from empty to its 1,000 cap in about four days.
CH.CONC_PER_HOUR = 1000 / (4 * 24)

local DEFAULTS = { version = 1, queue = {}, settings = { tooltip = true, coins = true, minimap = { hide = false, angle = 225 }, advisor = { hide = false, docked = true }, scan = { dailyCap = 10 }, window = { popQueue = false } }, characters = {} }

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

-- Items the auction house won't take: soulbound (BoP), quest items and warbound items, including
-- warbound until equipped. AuctionIQ treats them as worth nothing to sell: no value, no net worth,
-- no dead stock or price alerts. Item bind types from GetItemInfo's 14th return.
local NO_AH = { [1] = true, [4] = true, [7] = true, [8] = true, [9] = true }
local unsellable = {}
function CH.Unsellable(id)
	if not id then return false end
	local known = unsellable[id]
	if known ~= nil then return known end
	if not (C_Item and C_Item.GetItemInfo) then return false end
	local bind = select(14, C_Item.GetItemInfo(id))
	if bind == nil then return false end -- not loaded yet: ask again next time
	unsellable[id] = NO_AH[bind] == true
	return unsellable[id]
end

function CH.Print(msg)
	print("|cffe0a83aAuctionIQ|r: " .. tostring(msg))
end

local COIN = {
	g = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t",
	s = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t",
	c = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t",
}

-- "12,345g", "12g 50s", "75s", "9c": short enough for a tooltip line. Shown with the game's coin
-- icons, like TSM, unless coins are turned off (/ch coins) or plain is asked for.
function CH.FormatMoney(copper, plain)
	if not copper then return "-" end
	local icons = not plain and not (CH.db and CH.db.settings.coins == false)
	local function u(n, unit) return n .. (icons and COIN[unit] or unit) end
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
		out = u(str, "g")
	elseif g > 0 then
		out = s > 0 and (u(g, "g") .. " " .. u(s, "s")) or u(g, "g")
	elseif s > 0 then
		out = u(s, "s")
	else
		out = u(c, "c")
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
	pcall(frame.RegisterEvent, frame, event) -- an event this game version doesn't have is skipped, not an error
end

frame:SetScript("OnEvent", function(_, event, ...)
	for _, fn in ipairs(handlers[event] or {}) do
		fn(event, ...)
	end
end)

CH.On("ADDON_LOADED", function(_, name)
	if name ~= addonName then return end
	-- First login after the rename: take over the data the addon kept as Clearinghouse. The old
	-- folder is left as a stub that only loads ClearinghouseDB; it isn't changed, so it stays a backup.
	if AuctionIQDB == nil and type(ClearinghouseDB) == "table" then
		AuctionIQDB = CopyTable and CopyTable(ClearinghouseDB) or ClearinghouseDB
		CH.migrated = true
	end
	AuctionIQDB = copyDefaults(AuctionIQDB or {}, DEFAULTS)
	CH.db = AuctionIQDB
end)

CH.On("PLAYER_LOGIN", function()
	updateGold()
	if CH.migrated then CH.Print("moved your Clearinghouse data over. Once it all looks right, you can delete the Clearinghouse folder in AddOns.") end
	if not CH.Prices.Available() then
		CH.Print("TradeSkillMaster isn't loaded, so prices are off. Install TSM to see values and profits.")
	end
end)
CH.On("PLAYER_MONEY", updateGold)

SLASH_CLEARINGHOUSE1 = "/aiq"
SLASH_CLEARINGHOUSE2 = "/auctioniq"
SLASH_CLEARINGHOUSE3 = "/ch"
SlashCmdList.CLEARINGHOUSE = function(msg)
	msg = strtrim and strtrim(msg or ""):lower() or (msg or ""):lower()
	if msg == "tooltip" then
		CH.db.settings.tooltip = not CH.db.settings.tooltip
		CH.Print("tooltip lines " .. (CH.db.settings.tooltip and "on" or "off"))
	elseif msg == "coins" then
		CH.db.settings.coins = not CH.db.settings.coins
		CH.Print("coin icons " .. (CH.db.settings.coins and "on" or "off"))
		if CH.UI.IsShown() then CH.UI.Refresh() end
	elseif msg:match("^event ") then
		local day, name = msg:match("^event (%d+%-%d+%-%d+) (.+)$")
		if day then CH.Planner.AddEvent(day, name); CH.Print("added " .. day .. " " .. name) else CH.Print("/aiq event 2026-12-01 Season 2 starts") end
	elseif msg:match("^task ") then
		local name = msg:match("^task (.+)$")
		table.insert(CH.Planner.Store().tasks, name)
		CH.Print("weekly task added: " .. name)
	elseif msg == "theme" then
		CH.db.settings.theme = CH.db.settings.theme ~= "elvui" and "elvui" or "aiq"
		CH.Print(CH.db.settings.theme == "elvui" and "using ElvUI's colours. /reload to apply everywhere." or "using the AuctionIQ and Clearinghouse colours. /reload to apply everywhere.")
		CH.Theme.Use(CH.Theme.palette)
		if CH.UI.IsShown() then CH.UI.Refresh() end
	elseif msg == "alerts" then
		CH.Alerts.Toggle()
	elseif msg == "minimap" then
		CH.db.settings.minimap.hide = not CH.db.settings.minimap.hide
		CH.UpdateMinimapButton()
		CH.Print("minimap button " .. (CH.db.settings.minimap.hide and "hidden" or "shown"))
	elseif msg == "queue" then
		CH.QueueUI.Toggle()
	elseif msg == "scan" then
		CH.ScanUI.Toggle()
	elseif msg == "paths" or msg:match("^plan") or msg:match("^path ") then
		local goal = msg:match("^plan%s+(.+)") or msg:match("^path%s+(.+)")
		if not CH.PathsUI.IsShown() then CH.PathsUI.Toggle() end
		if goal then CH.PathsUI.Run(goal) end
	elseif msg == "results" or msg == "log" then
		CH.LogUI.Toggle()
	elseif msg:match("^cap") then
		local n = tonumber(msg:match("(%d+)"))
		if n then CH.db.settings.scan.dailyCap = n end
		CH.Print("gold a day counts up to " .. CH.db.settings.scan.dailyCap .. " sold a day per item. /aiq cap 20 to change.")
	elseif msg == "today" or msg == "dashboard" then CH.UI.Page("today")
	elseif msg == "markets" or msg == "market" then CH.UI.Page("markets")
	elseif msg == "crafting" then CH.UI.Page("crafting")
	elseif msg == "trading" or msg == "groups" then CH.UI.Page("trading")
	elseif msg == "analytics" then CH.UI.Page("analytics")
	elseif msg == "report" or msg == "brief" or msg == "briefing" then CH.UI.Page("report")
	elseif msg == "ledger" or msg == "clearinghouse" or msg == "books" then CH.UI.Page("ledger")
	elseif msg == "advisor" then
		CH.AdvisorUI.ToggleSetting()
	elseif msg == "help" then
		CH.Print("/aiq opens the window (/ch works too). /aiq tooltip turns the tooltip lines on or off. /aiq coins switches between coin icons and g/s/c. /aiq minimap hides or shows the minimap button. /aiq advisor turns the crafting advisor on or off. /aiq queue opens the craft queue and shopping list. /aiq scan ranks every recipe of the open profession. /aiq plan potions plans knowledge points for what you want to sell. /aiq results shows what your crafts really gave. /aiq cap 20 sets how many a day you'd sell of one item. /aiq alerts turns alerts on or off. /aiq today, markets, crafting, trading, analytics or ledger opens that tab; /aiq report opens the Report in the Clearinghouse. /aiq theme switches between the AuctionIQ colours and ElvUI's.")
	else
		CH.UI.Toggle()
	end
end

function AuctionIQ_OnAddonCompartmentClick()
	CH.UI.Toggle()
end
