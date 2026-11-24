-- The new AuctionIQ window: the wordmark, then on the right the faction crest, the price source badge
-- and close; an accent rule; tabs in the accent badge style; one page per tab. Craft · Analytics on
-- Forever, Craft · Work Orders · Analytics on retail. The badge's tooltip lists where prices come from
-- and a click opens Settings ▸ General (Prices). Settings is its own window with a left-hand menu.
local _, AuctionIQ = ...
local T = AuctionIQ.Theme

local Shell = { WIDTH = 780, HEIGHT = 520, SETTINGS_W = 780, SETTINGS_H = 440 }
AuctionIQ.Shell = Shell
--- Tab pages that are built: Shell.Pages[key] = { build = function(page), refresh = function(page) }.
Shell.Pages = {}

--- The tabs for this game, left to right: { key, label }.
function Shell.Tabs(game)
	local tabs = { { "craft", "Craft" } }
	if (game or AuctionIQ.Game) ~= "forever" then tabs[#tabs + 1] = { "orders", "Work Orders" } end
	tabs[#tabs + 1] = { "analytics", "Analytics" }
	return tabs
end

--- The Settings menu, top to bottom ("-" is a divider).
Shell.SETTINGS = { "General", "Analytics", "Data", "-", "About", "Changelog", "Reset" }

local CREST = { Horde = "Interface\\FriendsFrame\\PlusManz-Horde", Alliance = "Interface\\FriendsFrame\\PlusManz-Alliance" }

-- A tab or badge as the design draws it: a bordered box, muted text; the open one darker with the
-- accent text and a faint accent outline.
local function badge(parent, label, w, h)
	local b = CreateFrame("Button", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
	b:SetSize(w, h)
	T.Panel(b, "panel", 1)
	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fs:SetPoint("CENTER", 0, 0)
	fs:SetText(label)
	T.TitleFont(fs, nil, "bold")
	b.text = fs
	return b
end

function Shell.SetBadge(b, on)
	b.on = on and true or false
	local c = on and T.accent or T.muted
	b.text:SetTextColor(c[1], c[2], c[3])
	if b.SetBackdropColor then
		local bg = on and T.bg or T.panel
		b:SetBackdropColor(bg[1], bg[2], bg[3], 1)
		if on then b:SetBackdropBorderColor(T.accent[1], T.accent[2], T.accent[3], 0.45)
		else b:SetBackdropBorderColor(T.line[1], T.line[2], T.line[3], 1) end
	end
end

local function window(name, w, h)
	local f = CreateFrame("Frame", name, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
	f:SetSize(w, h)
	f:SetPoint("CENTER")
	f:SetFrameStrata("HIGH")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	T.Panel(f, "bg", T.OPAQUE)
	table.insert(UISpecialFrames, name) -- Escape closes it

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 10, -9)
	f.title = title

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 2, 2)
	close:SetScript("OnClick", function() f:Hide() end)
	f.close = close

	local bar = f:CreateTexture(nil, "ARTWORK")
	bar:SetPoint("TOPLEFT", 1, -30)
	bar:SetPoint("TOPRIGHT", -1, -30)
	bar:SetHeight(2)
	T.AccentTexture(bar)
	return f
end

--- The badge's tooltip: the source in use, each source's state, and how to change it.
function Shell.BadgeTooltip(owner)
	local s = AuctionIQ.Sources.Active()
	GameTooltip:SetOwner(owner, "ANCHOR_BOTTOMLEFT")
	GameTooltip:AddLine("Prices from " .. ({ tsm = "TradeSkillMaster", oe = "Oribos Exchange", vendor = "vendor prices" })[s.key])
	if not s.ok then GameTooltip:AddLine("No market prices yet: values and profits are limited.", 1, 0.5, 0.45, true) end
	for _, l in ipairs(s.lines) do GameTooltip:AddDoubleLine(l[1], l[2], 0.64, 0.64, 0.67, 0.95, 0.95, 0.95) end
	GameTooltip:AddLine("Click to change in Settings", 0.25, 0.78, 0.92)
	GameTooltip:Show()
end

function Shell.UpdateBadge()
	local f = Shell.frame
	if not (f and f.price) then return end
	local s = AuctionIQ.Sources.Active()
	f.price.text:SetText(s.label)
	local c = s.ok and T.accent or T.bad or T.muted
	f.price.text:SetTextColor(c[1], c[2], c[3])
end

local function build()
	local f = window("AuctionIQShell", Shell.WIDTH, Shell.HEIGHT)
	T.BrandTitle(f.title)

	local price = badge(f, "TSM", 44, 18)
	price:SetPoint("TOPRIGHT", -30, -6)
	price:SetScript("OnEnter", function(self) Shell.BadgeTooltip(self) end)
	price:SetScript("OnLeave", function() GameTooltip:Hide() end)
	price:SetScript("OnClick", function() Shell.OpenSettings("General") end)
	f.price = price

	local faction = UnitFactionGroup and UnitFactionGroup("player")
	if CREST[faction] then
		local crest = f:CreateTexture(nil, "ARTWORK")
		crest:SetSize(18, 18)
		crest:SetPoint("RIGHT", price, "LEFT", -8, 0)
		crest:SetTexture(CREST[faction])
		f.crest = crest
	end

	f.tabs, f.pages = {}, {}
	local x = 10
	for _, t in ipairs(Shell.Tabs()) do
		local key, label = t[1], t[2]
		local w = 28 + #label * 7
		local b = badge(f, label:upper(), w, 24)
		b:SetPoint("TOPLEFT", x, -40)
		b:SetScript("OnClick", function() Shell.Show(key) end)
		f.tabs[key] = b
		x = x + w + 4

		local page = CreateFrame("Frame", nil, f)
		page:SetPoint("TOPLEFT", 10, -72)
		page:SetPoint("BOTTOMRIGHT", -10, 10)
		local note = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		note:SetPoint("CENTER")
		note:SetText(T.Color("muted", label .. " is coming in the next build."))
		page.note = note
		page:Hide()
		f.pages[key] = page
		if Shell.Pages[key] then
			note:Hide()
			Shell.Pages[key].build(page)
		end
	end

	local gear = CreateFrame("Button", nil, f)
	gear:SetSize(20, 20)
	gear:SetPoint("TOPRIGHT", -12, -42)
	local g = gear:CreateTexture(nil, "ARTWORK")
	g:SetAllPoints()
	g:SetTexture("Interface\\Buttons\\UI-OptionsButton")
	gear:SetScript("OnClick", function() Shell.OpenSettings() end)
	f.gear = gear
	return f
end

--- Show the window on a tab (the last one open, else Craft).
function Shell.Show(key)
	Shell.frame = Shell.frame or build()
	local f = Shell.frame
	key = (key and f.pages[key]) and key or Shell.current or "craft"
	Shell.current = key
	for k, page in pairs(f.pages) do
		page:SetShown(k == key)
		Shell.SetBadge(f.tabs[k], k == key)
	end
	Shell.UpdateBadge()
	f:Show()
	local P = Shell.Pages[key]
	if P and P.refresh then P.refresh(f.pages[key]) end
end

function Shell.IsShown() return Shell.frame and Shell.frame:IsShown() or false end

function Shell.Toggle()
	if Shell.IsShown() then Shell.frame:Hide() else Shell.Show() end
end

-- Settings ---------------------------------------------------------------------------------------

local function buildSettings()
	local f = window("AuctionIQSettings", Shell.SETTINGS_W, Shell.SETTINGS_H)
	T.BrandTitle(f.title, "Settings")
	local nav = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
	nav:SetPoint("TOPLEFT", 1, -32)
	nav:SetPoint("BOTTOMLEFT", 1, 1)
	nav:SetWidth(150)
	T.Panel(nav, "panel", 1)
	f.items, f.pages = {}, {}
	local y = -8
	for _, name in ipairs(Shell.SETTINGS) do
		if name == "-" then
			local rule = nav:CreateTexture(nil, "ARTWORK")
			rule:SetPoint("TOPLEFT", 10, y - 6)
			rule:SetSize(130, 1)
			rule:SetColorTexture(T.line[1], T.line[2], T.line[3], 1)
			y = y - 14
		else
			local b = CreateFrame("Button", nil, nav)
			b:SetSize(148, 24)
			b:SetPoint("TOPLEFT", 1, y)
			local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			fs:SetPoint("LEFT", 12, 0)
			fs:SetText(name)
			b.text = fs
			local mark = b:CreateTexture(nil, "ARTWORK")
			mark:SetPoint("TOPLEFT")
			mark:SetSize(2, 24)
			T.AccentTexture(mark)
			b.mark = mark
			b:SetScript("OnClick", function() Shell.OpenSettings(name) end)
			f.items[name] = b
			y = y - 26

			local page = CreateFrame("Frame", nil, f)
			page:SetPoint("TOPLEFT", 162, -42)
			page:SetPoint("BOTTOMRIGHT", -10, 10)
			local note = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			note:SetPoint("CENTER")
			note:SetText(T.Color("muted", name .. " settings are coming in a later build."))
			page:Hide()
			f.pages[name] = page
		end
	end
	return f
end

--- Open Settings on a page (the last one open, else General).
function Shell.OpenSettings(page)
	Shell.settings = Shell.settings or buildSettings()
	local f = Shell.settings
	page = (page and f.pages[page]) and page or Shell.settingsPage or "General"
	Shell.settingsPage = page
	for name, b in pairs(f.items) do
		local on = name == page
		local c = on and T.accent or T.muted
		b.text:SetTextColor(c[1], c[2], c[3])
		b.mark:SetShown(on)
		f.pages[name]:SetShown(on)
	end
	f:Show()
end

--- /aiq on the new window. Returns true when it handled the command.
function Shell.Command(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "" then Shell.Toggle(); return true end
	local tab = ({ craft = "craft", orders = "orders", sales = "analytics", inv = "analytics", analytics = "analytics" })[msg]
	if tab and (tab ~= "orders" or AuctionIQ.IsRetail()) then Shell.Show(tab); return true end
	if msg == "settings" or msg == "config" then Shell.OpenSettings(); return true end
	if msg == "probe" and AuctionIQ.Recipes then
		AuctionIQ.Recipes.Probe()
		for _, l in ipairs(AuctionIQ.Recipes.ProbeLines()) do AuctionIQ.Print(l) end
		AuctionIQ.Print("saved for the next /reload")
		return true
	end
	if msg == "game" then
		AuctionIQ.Print("game: " .. AuctionIQ.Game .. " (project " .. tostring(WOW_PROJECT_ID) .. "), realm: " .. AuctionIQ.RealmName() .. ", version: " .. tostring(AuctionIQ.version))
		local full = UnitFullName and table.concat({ tostring((UnitFullName("player"))), tostring(select(2, UnitFullName("player"))) }, " / ") or "?"
		AuctionIQ.Print("character: " .. AuctionIQ.PlayerName() .. " (UnitName " .. tostring(UnitName("player")) .. ", UnitFullName " .. full .. ")")
		if AuctionIQ.readOnly then AuctionIQ.Print("saved data is read-only: it was written by a newer AuctionIQ") end
		if AuctionIQ.db and AuctionIQ.db.migrationFailed then AuctionIQ.Print("the last saved-data update failed and was undone: " .. tostring(AuctionIQ.db.migrationFailed.err)) end
		return true
	end
	return false
end
