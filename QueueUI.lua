-- Craft queue and shopping list panel. Docks under the crafting advisor; /ch queue opens it anywhere
-- (at the auction house, say) on its own.
local _, CH = ...

local QUI = {}
CH.QueueUI = QUI
local panel, qrows, srows, shopHead, empty
local QROWS, SROWS, W = 8, 8, 540

local function classColor(class)
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	return c and c.colorStr and ("|c" .. c.colorStr) or "|cffffffff"
end

local function rank(q, tiers)
	if not q then return "" end
	return " " .. CH.Window.QualityIcon(q, 14, tiers)
end

local function updatePop()
	local popped = not CH.Window.InTabs("queue")
	local b = panel.pop
	local t = popped and "Tab" or "Pop out"
	if b.text then b.text:SetText(t) elseif b.SetText then b:SetText(t) end
end

local function text(parent, x, y, w, justify, template)
	local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetWidth(w)
	fs:SetJustifyH(justify or "LEFT")
	return fs
end

local function build()
	local T = CH.Theme
	T.Sync()
	panel = CreateFrame("Frame", "ClearinghouseQueue", UIParent, "BackdropTemplate")
	T.Panel(panel, "bg", 0.95)
	panel:SetSize(W, 74 + (QROWS + SROWS) * 18 + 40)
	panel:SetFrameStrata("HIGH")
	panel:SetMovable(true)
	panel:SetClampedToScreen(true)
	panel:EnableMouse(true)
	panel:RegisterForDrag("LeftButton")
	panel:Hide()
	table.insert(UISpecialFrames, "ClearinghouseQueue")

	local bar = CreateFrame("Frame", nil, panel, "BackdropTemplate")
	T.Panel(bar, "panel", 1)
	bar:SetPoint("TOPLEFT")
	bar:SetPoint("TOPRIGHT")
	bar:SetHeight(26)
	local badge = bar:CreateTexture(nil, "ARTWORK")
	badge:SetTexture("Interface\\AddOns\\Clearinghouse\\Media\\Icon")
	badge:SetSize(18, 18)
	badge:SetPoint("LEFT", 5, 0)
	panel.title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	panel.title:SetPoint("LEFT", badge, "RIGHT", 6, 0)
	local close = T.Button(bar, "x", 18, 18)
	close:SetPoint("RIGHT", -4, 0)
	close:SetScript("OnClick", function() panel:Hide() end)
	local clear = T.Button(bar, "Clear", 46, 18)
	clear:SetPoint("RIGHT", close, "LEFT", -4, 0)
	clear:SetScript("OnClick", function() CH.Queue.Clear() end)
	local pop = T.Button(bar, "Pop out", 60, 18)
	pop:SetPoint("RIGHT", clear, "LEFT", -4, 0)
	pop:SetScript("OnClick", function() CH.Window.ToggleQueuePop(); updatePop() end)
	pop:SetScript("OnEnter", function(self)
		CH.Window.Tooltip(self, { { CH.Window.InTabs("queue") and "Take the queue out of the tabs so it sits under them, next to the advisor."
			or "Put the queue back in the tabs." } })
	end)
	pop:SetScript("OnLeave", function() GameTooltip:Hide() end)
	panel.pop = pop
	local fill = T.Button(bar, "Fill", 40, 18)
	fill:SetPoint("RIGHT", pop, "LEFT", -4, 0)
	fill:SetScript("OnClick", function()
		local n = CH.Queue.FillFromBest(5)
		CH.Print(n > 0 and ("queued the best craft of " .. n .. " recipes") or "open a profession to fill the queue from its best crafts")
	end)
	fill:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Queue one of each of the open profession's five best crafts, with the advisor's reagents.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	fill:SetScript("OnLeave", function() GameTooltip:Hide() end)

	local y = -34
	empty = text(panel, 12, y, W - 24, "LEFT")
	qrows = {}
	for i = 1, QROWS do
		local r = {}
		local ry = y - (i - 1) * 18
		r.name = CH.Window.OneLine(text(panel, 12, ry, 250))
		r.who = CH.Window.OneLine(text(panel, 266, ry, 90))
		r.profit = CH.Window.OneLine(text(panel, 360, ry, 86, "RIGHT"))
		r.craft = T.Button(panel, "Craft", 44, 16)
		r.craft:SetPoint("TOPLEFT", 454, ry + 2)
		r.minus = T.Button(panel, "-", 18, 16)
		r.minus:SetPoint("TOPLEFT", 504, ry + 2)
		qrows[i] = r
	end

	y = y - QROWS * 18 - 8
	shopHead = text(panel, 12, y, W - 24, "LEFT", "GameFontNormalSmall")
	local cols = { { "Reagent", 12, 250, "LEFT" }, { "Need", 264, 54 }, { "Have", 320, 54 }, { "Buy", 376, 54 }, { "Cost", 432, 96 } }
	y = y - 16
	for _, c in ipairs(cols) do
		local h = text(panel, c[2], y, c[3], c[4] or "RIGHT", "GameFontDisableSmall")
		h:SetText(c[1])
	end
	srows = {}
	for i = 1, SROWS do
		local ry = y - i * 18
		local r = {}
		for j, c in ipairs(cols) do r[j] = CH.Window.OneLine(text(panel, c[2], ry, c[3], c[4] or "RIGHT")) end
		srows[i] = r
	end
	T.Fonts(panel)
	CH.Window.Attach("queue", panel)
end

--- Redraw. Returns the queue and shopping lines it wrote, for the tests.
function QUI.Refresh()
	if not panel or not panel:IsShown() then return end
	local T = CH.Theme
	local q = CH.db.queue
	panel.title:SetText(T.Color("accent", "Clearinghouse") .. "  " .. T.Color("muted", "Craft queue (" .. CH.Queue.Count() .. ")"))
	empty:SetText(#q == 0 and T.Color("muted", "Empty. Click a row in the crafting advisor to queue one, shift-click to queue as many as you can make.") or "")
	local lines = { queue = {}, shop = {} }
	for i, r in ipairs(qrows) do
		local e = q[i]
		local show = e ~= nil
		r.craft:SetShown(show)
		r.minus:SetShown(show)
		if show then
			r.name:SetText(string.format("%s%s x%d%s", e.name or "?", rank(e.quality, e.tiers), e.qty, e.concentration and T.Color("accent", " conc") or ""))
			r.who:SetText(classColor(e.class) .. (e.charName or "?") .. "|r")
			r.profit:SetText(e.profit and T.Color(e.profit >= 0 and "ok" or "bad", CH.FormatMoney(e.profit * e.qty)) or "")
			local can, why = CH.Queue.CanCraftHere(e)
			r.craft:SetEnabled(can)
			r.craft:SetScript("OnClick", function() CH.Queue.Craft(e, e.qty) end)
			r.craft:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_TOP")
				GameTooltip:AddLine(can and ("Craft " .. e.qty .. " with the queued reagents" .. (e.concentration and " and Concentration" or "")) or ("Craft " .. why), 1, 1, 1)
				GameTooltip:Show()
			end)
			r.craft:SetScript("OnLeave", function() GameTooltip:Hide() end)
			r.minus:SetScript("OnClick", function() CH.Queue.Remove(e, IsShiftKeyDown() and e.qty or 1) end)
			table.insert(lines.queue, string.format("%s Q%d x%d %s", e.name, e.quality or 0, e.qty, e.charName or ""))
		else
			r.name:SetText(""); r.who:SetText(""); r.profit:SetText("")
		end
	end
	local shop, total = CH.Queue.ShoppingList()
	shopHead:SetText(T.Color("accent", "Shopping list") .. (#shop > 0 and T.Color("muted", "  buy for " .. CH.FormatMoney(total) .. " at chmat") or ""))
	for i, r in ipairs(srows) do
		local s = shop[i]
		if s then
			r[1]:SetText(s.name .. rank(s.rank, s.tiers))
			r[2]:SetText(s.need)
			r[3]:SetText(T.Color(s.have >= s.need and "ok" or "fg", tostring(s.have)))
			r[4]:SetText(s.buy > 0 and T.Color("accent", tostring(s.buy)) or T.Color("muted", "0"))
			r[5]:SetText(s.buy > 0 and CH.FormatMoney(s.cost) or "")
			table.insert(lines.shop, string.format("%s need=%d have=%d buy=%d", s.name, s.need, s.have, s.buy))
		else
			for j = 1, 5 do r[j]:SetText("") end
		end
	end
	return lines
end

function QUI.Show()
	if not panel then build() end
	updatePop()
	panel:Show()
	CH.Window.Arrange()
	return QUI.Refresh()
end

function QUI.Toggle()
	if panel and panel:IsShown() then panel:Hide() else QUI.Show() end
end

function QUI.IsShown() return panel ~= nil and panel:IsShown() end

CH.Queue.Changed = function() QUI.Refresh(); if CH.AdvisorUI and CH.AdvisorUI.UpdateQueueButton then CH.AdvisorUI.UpdateQueueButton() end end
CH.On("BAG_UPDATE_DELAYED", function() QUI.Refresh() end)
CH.On("TRADE_SKILL_SHOW", function() if QUI.IsShown() then CH.Window.Arrange(); QUI.Refresh() end end)
