-- The new AuctionIQ window: brand title, the faction crest, tabs, and an empty page per tab.
-- Craft · Analytics on Forever; Craft · Work Orders · Analytics on retail. The pages arrive in
-- the next build phases; this is phase 0, the window loading at all.
local _, AuctionIQ = ...
local T = AuctionIQ.Theme

local Shell = { WIDTH = 780, HEIGHT = 520 }
AuctionIQ.Shell = Shell

--- The tabs for this game, left to right: { key, label }.
function Shell.Tabs(game)
	local tabs = { { "craft", "Craft" } }
	if (game or AuctionIQ.Game) ~= "forever" then tabs[#tabs + 1] = { "orders", "Work Orders" } end
	tabs[#tabs + 1] = { "analytics", "Analytics" }
	return tabs
end

local CREST = { Horde = "Interface\\FriendsFrame\\PlusManz-Horde", Alliance = "Interface\\FriendsFrame\\PlusManz-Alliance" }

local function build()
	local f = CreateFrame("Frame", "AuctionIQShell", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
	f:SetSize(Shell.WIDTH, Shell.HEIGHT)
	f:SetPoint("CENTER")
	f:SetFrameStrata("HIGH")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	T.Panel(f, "bg", T.OPAQUE)
	table.insert(UISpecialFrames, "AuctionIQShell") -- Escape closes it

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 10, -9)
	T.BrandTitle(title)
	f.title = title

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 2, 2)
	close:SetScript("OnClick", function() f:Hide() end)

	local faction = UnitFactionGroup and UnitFactionGroup("player")
	if CREST[faction] then
		local crest = f:CreateTexture(nil, "ARTWORK")
		crest:SetSize(18, 18)
		crest:SetPoint("TOPRIGHT", -34, -6)
		crest:SetTexture(CREST[faction])
		f.crest = crest
	end

	local bar = f:CreateTexture(nil, "ARTWORK")
	bar:SetPoint("TOPLEFT", 1, -30)
	bar:SetPoint("TOPRIGHT", -1, -30)
	bar:SetHeight(2)
	T.AccentTexture(bar)

	f.tabs, f.pages = {}, {}
	local x = 10
	for _, t in ipairs(Shell.Tabs()) do
		local key, label = t[1], t[2]
		local w = 24 + math.ceil((#label) * 7)
		local b = T.Tab(f, label, w, 24)
		b:SetPoint("TOPLEFT", x, -38)
		b:SetScript("OnClick", function() Shell.Show(key) end)
		f.tabs[key] = b
		x = x + w + 4

		local page = CreateFrame("Frame", nil, f)
		page:SetPoint("TOPLEFT", 10, -70)
		page:SetPoint("BOTTOMRIGHT", -10, 10)
		local note = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		note:SetPoint("CENTER")
		note:SetText(T.Color("muted", label .. " is coming in the next build."))
		page.note = note
		page:Hide()
		f.pages[key] = page
	end
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
		T.SetTab(f.tabs[k], k == key)
	end
	f:Show()
end

function Shell.IsShown() return Shell.frame and Shell.frame:IsShown() or false end

function Shell.Toggle()
	if Shell.IsShown() then Shell.frame:Hide() else Shell.Show() end
end

--- /aiq on the new window. Returns true when it handled the command.
function Shell.Command(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "" then Shell.Toggle(); return true end
	local tab = ({ craft = "craft", orders = "orders", sales = "analytics", inv = "analytics", analytics = "analytics" })[msg]
	if tab and (tab ~= "orders" or AuctionIQ.IsRetail()) then Shell.Show(tab); return true end
	if msg == "game" then AuctionIQ.Print("game: " .. AuctionIQ.Game .. " (project " .. tostring(WOW_PROJECT_ID) .. ")"); return true end
	return false
end
