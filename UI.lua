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
	table.insert(out, "|cffe0a83aGold|r  " .. CH.FormatMoney(total) .. " across " .. #chars .. " characters")
	for _, c in ipairs(chars) do
		table.insert(out, "   " .. classColor(c.class) .. (c.name or c.key) .. "|r  " .. CH.FormatMoney(c.gold or 0))
	end

	table.insert(out, "")
	table.insert(out, "|cffe0a83aConcentration|r")
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
					full and "|cffff5555FULL, spend it|r" or ("full in " .. hours .. "h")))
			end
		end
	end
	if not any then
		table.insert(out, "   Open each character's professions once to see Concentration here.")
	elseif idle > 0 then
		table.insert(out, "   |cffff5555" .. idle .. " at full: Concentration is being wasted.|r")
	end

	table.insert(out, "")
	table.insert(out, "|cffe0a83aBest crafts|r  profit per craft after the 5% cut, top quality")
	local listed = false
	for _, c in ipairs(chars) do
		for _, p in pairs(c.professions or {}) do
			for i, r in ipairs(p.crafts or {}) do
				if i > 3 then break end
				listed = true
				table.insert(out, string.format("   %s%s|r %s: %s  %s", classColor(c.class), c.name or c.key, p.name or "?", r.name or "?", CH.FormatMoney(r.profit)))
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
	frame = CreateFrame("Frame", "ClearinghouseFrame", UIParent, "BasicFrameTemplateWithInset")
	frame:SetSize(560, 460)
	frame:SetPoint("CENTER")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetFrameStrata("HIGH")
	frame:Hide()
	table.insert(UISpecialFrames, "ClearinghouseFrame") -- Esc closes it
	frame.TitleText:SetText("Clearinghouse · Briefing")

	local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 14, -32)
	scroll:SetPoint("BOTTOMRIGHT", -32, 34)
	local child = CreateFrame("Frame", nil, scroll)
	child:SetSize(500, 10)
	scroll:SetScrollChild(child)
	text = child:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	text:SetPoint("TOPLEFT")
	text:SetWidth(500)
	text:SetJustifyH("LEFT")
	text:SetSpacing(3)

	local foot = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	foot:SetPoint("BOTTOMLEFT", 16, 12)
	foot:SetText("Coming next: Opportunities, Flip & Craft, Assets.  /ch tooltip turns tooltip lines on or off.")
	frame:SetScript("OnShow", UI.Refresh)
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
