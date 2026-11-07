-- Clearinghouse main window, opened with /ch or from the addon compartment, like TSM's.
local _, CH = ...

local UI = {}
CH.UI = UI
local frame, text

local function classColor(class)
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	return c and c.colorStr and ("|c" .. c.colorStr) or "|cffffffff"
end

local function sortedCharacters()
	local list = {}
	for key, c in pairs(CH.db.characters) do
		c.key = key
		table.insert(list, c)
	end
	table.sort(list, function(a, b) return (a.gold or 0) > (b.gold or 0) end)
	return list
end

--- The briefing as text: gold, Concentration, best crafts. Also used by the tests.
function UI.BriefingText(now)
	now = now or time()
	local chars, out = sortedCharacters(), {}
	local total = 0
	for _, c in ipairs(chars) do total = total + (c.gold or 0) end
	table.insert(out, CH.Theme.Color("accent", "Gold") .. "  " .. CH.FormatMoney(total) .. " across " .. #chars .. " characters")
	for _, c in ipairs(chars) do
		table.insert(out, "   " .. classColor(c.class) .. (c.name or c.key) .. "|r  " .. CH.FormatMoney(c.gold or 0))
	end

	table.insert(out, "")
	table.insert(out, CH.Theme.Color("accent", "Concentration"))
	local any, idle = false, 0
	for _, c in ipairs(chars) do
		for _, p in pairs(c.professions or {}) do
			local cur, max = CH.ConcentrationNow(p, now)
			if cur then
				any = true
				local full = cur >= max
				if full then idle = idle + 1 end
				local hours = full and 0 or math.ceil((max - cur) / CH.CONC_PER_HOUR)
				table.insert(out, string.format("   %s%s|r %s  %d / %d  %s", classColor(c.class), c.name or c.key, p.name or "?", cur, max,
					full and CH.Theme.Color("bad", "FULL, spend it") or ("full in " .. hours .. "h")))
			end
		end
	end
	if not any then
		table.insert(out, "   Open each character's professions once to see Concentration here.")
	elseif idle > 0 then
		table.insert(out, "   " .. CH.Theme.Color("bad", idle .. " at full. Idle Concentration is gold left on the table."))
	end

	table.insert(out, "")
	table.insert(out, CH.Theme.Color("accent", "Best crafts") .. CH.Theme.Color("muted", "  profit per craft after the 5% cut, top quality"))
	local listed = false
	for _, c in ipairs(chars) do
		for _, p in pairs(c.professions or {}) do
			for i, r in ipairs(p.crafts or {}) do
				if i > 3 then break end
				listed = true
				table.insert(out, string.format("   %s%s|r %s: %s  %s", classColor(c.class), c.name or c.key, p.name or "?", r.name or "?", CH.Theme.Color(r.profit >= 0 and "ok" or "bad", CH.FormatMoney(r.profit))))
			end
		end
	end
	if not listed then
		table.insert(out, CH.Prices.Available() and "   Open a profession window to rank its recipes."
			or "   Needs TradeSkillMaster for prices.")
	end
	return table.concat(out, "\n")
end

local function build()
	local T = CH.Theme
	T.Sync()
	frame = CreateFrame("Frame", "ClearinghouseFrame", UIParent, "BackdropTemplate")
	T.Panel(frame, "bg", 0.95)
	frame:SetSize(560, 460)
	frame:SetPoint("CENTER")
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetFrameStrata("HIGH")
	frame:Hide()
	table.insert(UISpecialFrames, "ClearinghouseFrame") -- Esc closes it

	-- Title bar: panel colour, gold rule underneath, name in gold, page in grey.
	local bar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
	T.Panel(bar, "panel", 1)
	bar:SetPoint("TOPLEFT", 0, 0)
	bar:SetPoint("TOPRIGHT", 0, 0)
	bar:SetHeight(26)
	local rule = bar:CreateTexture(nil, "ARTWORK")
	rule:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 1)
	rule:SetPoint("BOTTOMLEFT", 1, 0)
	rule:SetPoint("BOTTOMRIGHT", -1, 0)
	rule:SetHeight(1)
	local badge = bar:CreateTexture(nil, "ARTWORK")
	badge:SetTexture("Interface\\AddOns\\Clearinghouse\\Media\\Icon")
	badge:SetSize(18, 18)
	badge:SetPoint("LEFT", 5, 0)
	local title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("LEFT", badge, "RIGHT", 6, 0)
	title:SetText(T.Color("accent", "Clearinghouse") .. "  " .. T.Color("muted", "Briefing"))
	frame.TitleText = title
	local close = T.Button(bar, "x", 18, 18)
	close:SetPoint("RIGHT", -4, 0)
	close:SetScript("OnClick", function() frame:Hide() end)

	-- Body: wheel scrolling, no Blizzard scroll bar.
	local scroll = CreateFrame("ScrollFrame", nil, frame)
	scroll:SetPoint("TOPLEFT", 14, -38)
	scroll:SetPoint("BOTTOMRIGHT", -14, 34)
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local y = math.max(0, math.min(self:GetVerticalScrollRange(), self:GetVerticalScroll() - delta * 40))
		self:SetVerticalScroll(y)
	end)
	local child = CreateFrame("Frame", nil, scroll)
	child:SetSize(530, 10)
	scroll:SetScrollChild(child)
	text = child:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	text:SetPoint("TOPLEFT")
	text:SetWidth(530)
	text:SetJustifyH("LEFT")
	text:SetSpacing(4)
	text:SetTextColor(T.fg[1], T.fg[2], T.fg[3])

	local footRule = frame:CreateTexture(nil, "ARTWORK")
	footRule:SetColorTexture(T.line[1], T.line[2], T.line[3], 1)
	footRule:SetPoint("BOTTOMLEFT", 1, 26)
	footRule:SetPoint("BOTTOMRIGHT", -1, 26)
	footRule:SetHeight(1)
	local foot = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	foot:SetPoint("BOTTOMLEFT", 12, 9)
	foot:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
	foot:SetText("Coming next: Opportunities, Flip & Craft, Assets.   /ch help for commands")
	local motto = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	motto:SetPoint("BOTTOMRIGHT", -12, 9)
	motto:SetText(T.Color("accent", "All trades settled in gold."))
	frame:SetScript("OnShow", UI.Refresh)
	T.Fonts(frame)
end

function UI.Refresh()
	if not text then return end
	text:SetText(UI.BriefingText())
	text:GetParent():SetHeight(text:GetStringHeight() + 10)
end

function UI.IsShown()
	return frame ~= nil and frame:IsShown()
end

function UI.Toggle()
	if not frame then build() end
	if frame:IsShown() then frame:Hide() else frame:Show() end
end
