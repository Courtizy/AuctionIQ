-- Craft queue and shopping list panel. Docks under the crafting advisor; /ch queue opens it anywhere
-- (at the auction house, say) on its own.
local _, CH = ...

local QUI = {}
CH.QueueUI = QUI
local panel, qrows, srows, shopHead, empty
local QROWS, SROWS, W = 8, 8, 540
local qOffset, sOffset = 0, 0
local qBar, sBar

-- A hover area over a list row that shows the game's item tooltip (with AuctionIQ's lines).
local function itemHover(parent, x, y, w)
	local hit = CreateFrame("Button", nil, parent)
	hit:SetPoint("TOPLEFT", x, y + 2)
	hit:SetSize(w, 18)
	hit:SetScript("OnEnter", function(self)
		if self.id and GameTooltip.SetItemByID then GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetItemByID(self.id); GameTooltip:Show() end
	end)
	hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return hit
end

--- Hover lines for a shopping row's cost: where the price came from and how far up the book it goes.
function QUI.CostLines(s)
	local T, M = CH.Theme, CH.FormatMoney
	local out = {}
	if not s or s.buy <= 0 or not s.cost then return out end
	local from = s.source == "ah" and "your AH search" or s.source == "scan" and ("your last AH scan, " .. CH.Scans.Age(s.age) .. " old")
		or "chmat (no listings seen)"
	out[#out + 1] = "Buying " .. s.buy .. " costs " .. M(s.cost)
	if s.first and s.source ~= "chmat" then
		out[#out + 1] = T.Color("muted", "Cheapest " .. M(s.first) .. " each, " .. M(math.floor(s.unit + 0.5)) .. " each on average")
		local slip = s.first > 0 and s.unit / s.first - 1 or 0
		if slip >= 0.005 then out[#out + 1] = T.Color("accent", string.format("%d%% above the cheapest listing", math.floor(slip * 100 + 0.5))) end
	end
	if (s.short or 0) > 0 then out[#out + 1] = T.Color("bad", "Only " .. (s.buy - s.short) .. " listed; the rest is priced at the top listing") end
	out[#out + 1] = T.Color("muted", "From " .. from)
	return out
end

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
	panel = CreateFrame("Frame", "AuctionIQQueue", UIParent, "BackdropTemplate")
	T.Panel(panel, "bg", 0.95)
	panel:SetSize(W, 74 + (QROWS + SROWS) * 18 + 40)
	panel:SetFrameStrata("HIGH")
	panel:SetMovable(true)
	panel:SetClampedToScreen(true)
	panel:EnableMouse(true)
	panel:RegisterForDrag("LeftButton")
	panel:Hide()
	table.insert(UISpecialFrames, "AuctionIQQueue")

	local bar = CreateFrame("Frame", nil, panel, "BackdropTemplate")
	T.Panel(bar, "panel", 1)
	bar:SetPoint("TOPLEFT")
	bar:SetPoint("TOPRIGHT")
	bar:SetHeight(26)
	local badge = bar:CreateTexture(nil, "ARTWORK")
	badge:SetTexture(CH.ICON)
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
		local prof = CH.OpenProfessionID()
		local plan, why
		if prof then plan, why = CH.Queue.FillPlan(prof) end
		if plan then
			CH.Print(string.format("queued %d Concentration crafts (%d of %d points) and %d without, about %s profit.",
				plan.conc, math.floor(plan.points + 0.5), plan.budget, plan.plain, CH.FormatMoney(plan.profit)))
		else
			CH.Print(why or "open a profession to fill the queue from its scan.")
		end
	end)
	fill:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Fill from the scan: Concentration crafts first, best gold per point, only as many as your Concentration covers. Then crafts that profit without it. Each up to what sells in a day (/aiq cap), less what you own.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	fill:SetScript("OnLeave", function() GameTooltip:Hide() end)

	local function fillButton(label, anchor, tip, fn)
		local b = T.Button(bar, label, label:len() * 7 + 16, 18)
		b:SetPoint("RIGHT", anchor, "LEFT", -4, 0)
		b:SetScript("OnClick", fn)
		b:SetScript("OnEnter", function(self) CH.Window.Tooltip(self, { { tip } }) end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		return b
	end
	local orders = fillButton("Orders", fill, "Queue the crafting orders worth doing: those whose commission and rewards cover the reagents, or that reward knowledge or Acuity. Open the Crafting Orders tab first so the game lists them. Each order's button goes Claim, Craft, Turn in; Next step in the Scan tab's Work orders does them in order.", function()
		local n, profit = CH.Queue.FillOrders()
		CH.Print(n > 0 and string.format("queued %d orders, about %s profit.", n, CH.FormatMoney(profit))
			or "no orders worth doing. Open the Crafting Orders tab so the game lists them.")
	end)
	fillButton("1st crafts", orders, "Queue every recipe you haven't made yet, once each at its cheapest, for the first-craft knowledge point.", function()
		local n, cost = CH.Queue.FillFirstCrafts()
		CH.Print(n > 0 and string.format("queued %d first crafts for %s of reagents: %d knowledge points.", n, CH.FormatMoney(cost), n)
			or "no first crafts left in this profession (or open it first).")
	end)

	local y = -34
	empty = text(panel, 12, y, W - 24, "LEFT")
	qrows = {}
	for i = 1, QROWS do
		local r = {}
		local ry = y - (i - 1) * 18
		r.name = CH.Window.OneLine(text(panel, 12, ry, 250))
		r.hit = itemHover(panel, 12, ry, 250)
		r.who = CH.Window.OneLine(text(panel, 266, ry, 90))
		r.profit = CH.Window.OneLine(text(panel, 360, ry, 86, "RIGHT"))
		r.craft = T.Button(panel, "Turn in", 58, 16)
		r.craft:SetPoint("TOPLEFT", 454, ry + 2)
		r.minus = T.Button(panel, "-", 18, 16)
		r.minus:SetPoint("TOPLEFT", 516, ry + 2)
		qrows[i] = r
	end

	local qwheel = CreateFrame("Frame", nil, panel)
	qwheel:SetPoint("TOPLEFT", 0, y + 2)
	qwheel:SetSize(W, QROWS * 18)
	qBar = CH.Window.ScrollBar(panel, W - 5, y + 2, QROWS * 18, true)
	CH.Window.Wheel(qwheel, QROWS, function() return qOffset end, function(v) qOffset = v end, function() return #CH.db.queue end, QUI.Refresh, qBar)
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
		r.hit = itemHover(panel, 12, ry, 250)
		r.costHit = CreateFrame("Button", nil, panel)
		r.costHit:SetPoint("TOPLEFT", 432, ry + 2)
		r.costHit:SetSize(96, 18)
		r.costHit:SetScript("OnEnter", function(self)
			local lines = QUI.CostLines(self.row)
			if not lines[1] then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			for _, l in ipairs(lines) do GameTooltip:AddLine(l, 1, 1, 1) end
			GameTooltip:Show()
		end)
		r.costHit:SetScript("OnLeave", function() GameTooltip:Hide() end)
		srows[i] = r
	end
	local swheel = CreateFrame("Frame", nil, panel)
	swheel:SetPoint("TOPLEFT", 0, y - 16)
	swheel:SetSize(W, SROWS * 18)
	sBar = CH.Window.ScrollBar(panel, W - 5, y - 16, SROWS * 18, true)
	CH.Window.Wheel(swheel, SROWS, function() return sOffset end, function(v) sOffset = v end, function() return #(CH.Queue.ShoppingList()) end, QUI.Refresh, sBar)
	T.Fonts(panel)
	CH.Window.Attach("queue", panel)
end

--- Redraw. Returns the queue and shopping lines it wrote, for the tests.
function QUI.Refresh()
	if not panel or not panel:IsShown() then return end
	local T = CH.Theme
	local q = CH.db.queue
	panel.title:SetText(T.Color("accent", "AuctionIQ") .. "  " .. T.Color("muted", "Queue (" .. CH.Queue.Count() .. ")"
		.. (#q > QROWS and string.format(", rows %d-%d of %d, scroll", qOffset + 1, math.min(#q, qOffset + QROWS), #q) or "")))
	empty:SetText(#q == 0 and T.Color("muted", "Empty. Click a row in the crafting advisor to queue one, shift-click to queue as many as you can make.") or "")
	local lines = { queue = {}, shop = {} }
	qOffset = math.max(0, math.min(qOffset, #q - QROWS))
	qBar:Set(qOffset, QROWS, #q)
	for i, r in ipairs(qrows) do
		local e = q[i + qOffset]
		r.hit.id = e and e.item
		local show = e ~= nil
		r.craft:SetShown(show)
		r.minus:SetShown(show)
		if show then
			local tag = (e.concentration and T.Color("accent", " conc") or "") .. (e.firstCraft and T.Color("accent", " 1KP") or "")
				.. (e.orderID and T.Color("accent", " order") or "") .. (e.special and T.Color("accent", " reward") or "")
			r.name:SetText(string.format("%s%s%s x%d%s", CH.Window.ItemIcon(e.item, 15), e.name or "?", rank(e.quality, e.tiers), e.qty, tag))
			r.who:SetText(classColor(e.class) .. (e.charName or "?") .. "|r")
			r.profit:SetText(e.profit and T.Color(e.profit >= 0 and "ok" or "bad", CH.FormatMoney(e.profit * e.qty)) or "")
			local can, why = CH.Queue.CanCraftHere(e)
			r.craft:SetEnabled(can)
			local step = CH.Queue.OrderStep(e)
			if r.craft.text then r.craft.text:SetText(step) elseif r.craft.SetText then r.craft:SetText(step) end
			r.craft:SetScript("OnClick", function() CH.Queue.Craft(e, e.qty) end)
			r.craft:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_TOP")
				GameTooltip:AddLine(not can and ("Craft " .. why)
					or step == "Claim" and ("Claim " .. (e.customer or "the") .. "'s order")
					or step == "Turn in" and "Turn in the order"
					or ("Craft " .. e.qty .. " with the queued reagents" .. (e.concentration and " and Concentration" or "")), 1, 1, 1)
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
	shopHead:SetText(T.Color("accent", "Shopping list") .. (#shop > 0 and T.Color("muted", "  buy for " .. CH.FormatMoney(total) .. ", Shop queue at the AH") or ""))
	sOffset = math.max(0, math.min(sOffset, #shop - SROWS))
	sBar:Set(sOffset, SROWS, #shop)
	if #shop > SROWS then shopHead:SetText(shopHead:GetText() .. CH.Theme.Color("muted", string.format("  (%d-%d of %d, scroll)", sOffset + 1, math.min(#shop, sOffset + SROWS), #shop))) end
	for i, r in ipairs(srows) do
		local s = shop[i + sOffset]
		r.hit.id = s and s.itemID
		r.costHit.row = s
		if s then
			r[1]:SetText(CH.Window.ItemIcon(s.itemID, 15) .. s.name .. rank(s.rank, s.tiers))
			r[2]:SetText(s.need)
			r[3]:SetText(T.Color(s.have >= s.need and "ok" or "fg", tostring(s.have)))
			r[4]:SetText(s.buy > 0 and T.Color("accent", tostring(s.buy)) or T.Color("muted", "0"))
			r[5]:SetText(s.buy > 0 and s.cost and T.Color((s.short or 0) > 0 and "bad" or "fg", CH.FormatMoney(s.cost)) or "")
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

CH.Queue.Changed = function() QUI.Refresh(); if CH.AdvisorUI and CH.AdvisorUI.UpdateQueueButton then CH.AdvisorUI.UpdateQueueButton() end; if CH.ScanUI and CH.ScanUI.UpdateNext then CH.ScanUI.UpdateNext() end end
CH.On("BAG_UPDATE_DELAYED", function() QUI.Refresh() end)
CH.On("TRADE_SKILL_SHOW", function() if QUI.IsShown() then CH.Window.Arrange(); QUI.Refresh() end end)
