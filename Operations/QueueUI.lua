-- Craft queue and shopping list panel. A tab beside Craft, or popped out beside it; /aiq queue opens it anywhere
-- (at the auction house, say) on its own.
local _, CH = ...

local QUI = {}
CH.QueueUI = QUI
local panel, qrows, srows, shopHead, empty
local QROWS, SROWS, W = 8, 8, 540
local BUDGET_H = 84 -- the budget bars under the shopping list
local budget -- { head, bars = { { label, fill, need, text } }, stop }
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
	-- a TSM Shopping operation's maximum price for it
	if s.maxPrice then
		local head = "Max price " .. M(s.maxPrice) .. (s.shopOp and ("  (" .. s.shopOp .. ")") or "")
		if s.overMax then
			out[#out + 1] = T.Color("bad", head .. (s.underMax and (": only " .. s.underMax .. " listed at or under it") or ": the price is above it"))
		else out[#out + 1] = T.Color("muted", head) end
	end
	if s.craft then
		out[#out + 1] = T.Color("ok", string.format("Cheaper to craft: %s makes it (%s) for %s each, %s for %d",
			s.craft.char or "?", s.craft.name or "?", M(math.floor(s.craft.each + 0.5)), M(math.floor(s.craft.cost + 0.5)), s.buy))
	end
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
	local t = popped and "Join tabs" or "Pop out"
	if b.text then b.text:SetText(t) elseif b.SetText then b:SetText(t) end
end

local function text(parent, x, y, w, justify, template)
	local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetWidth(w)
	fs:SetJustifyH(justify or "LEFT")
	return fs
end

local H = 18 -- a row, as the Craft window's
-- The cards, top down: the queue, the shopping list, the budget. Each card's y and height.
local QY, SY, BY = -48, nil, nil
local QH = 22 + QROWS * H + 6
SY = QY - QH - 6
local SH = 38 + SROWS * H + 6
BY = SY - SH - 6
local BH = 84

-- A card's heading, as the Craft window's side panel draws QUALITY: small, bold, the theme colour.
local function head(parent, x, y, w)
	local fs = CH.Window.OneLine(text(parent, x, y, w, "LEFT", "GameFontNormalSmall"))
	CH.Theme.TitleFont(fs, 10, "bold")
	return fs
end

-- Column heads, as the Craft list has them: muted capitals.
local function colHeads(parent, y, cols)
	for _, c in ipairs(cols) do
		local h = CH.Window.OneLine(text(parent, c[2], y, c[3], c[4] or "RIGHT", "GameFontDisableSmall"))
		h:SetText(c[1]:upper())
	end
end

-- A hairline under each row, as the Craft list has.
local function hairline(parent, y, w)
	local line = parent:CreateTexture(nil, "BACKGROUND", nil, 3)
	line:SetPoint("TOPLEFT", 7, y)
	line:SetSize(w, 1)
	line:SetColorTexture(0, 0, 0, 0.6)
	return line
end

local function build()
	local T, Wd = CH.Theme, CH.Window
	panel = Wd.New("AuctionIQQueue", "Queue", W, -BY + BH + 8)
	panel:SetScript("OnDragStart", nil); panel:SetScript("OnDragStop", nil) -- Attach moves it with the tabs
	local bar = panel.bar
	local x = -26
	local function barButton(label, width, tip, fn)
		local b = T.Button(bar, label, width, 18)
		b:SetPoint("RIGHT", x, 0)
		b:SetScript("OnClick", fn)
		if tip then
			b:SetScript("OnEnter", function(self) Wd.Tooltip(self, type(tip) == "function" and tip() or { { label }, { T.Color("muted", tip) } }) end)
			b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		end
		x = x - width - 4
		return b
	end
	barButton("Clear", 46, "Empty the queue.", function() CH.Queue.Clear() end)
	panel.pop = barButton("Pop out", 70, function()
		return { { CH.Window.InTabs("queue") and "Pop out" or "Join tabs" }, { T.Color("muted", CH.Window.InTabs("queue")
			and "Take the queue out of the tabs so it sits beside the Craft window." or "Put the queue back in the tabs, behind the Craft window.") } }
	end, function() CH.Window.ToggleQueuePop(); updatePop() end)
	barButton("Fill", 40, "Fill from the scan: Concentration crafts first, best gold per point, only as many as your Concentration covers. Then crafts that profit without it. Each up to what sells in a day (/aiq cap), less what you own.", function()
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
	barButton("Orders", 58, "Queue the crafting orders worth doing: those whose commission and rewards cover the reagents, or that reward knowledge or Acuity. Open the Crafting Orders tab first so the game lists them.", function()
		local n, profit = CH.Queue.FillOrders()
		CH.Print(n > 0 and string.format("queued %d orders, about %s profit.", n, CH.FormatMoney(profit))
			or "no orders worth doing. Open the Crafting Orders tab so the game lists them.")
	end)
	barButton("First crafts", 86, "Queue every recipe you haven't made yet, once each at its cheapest, for the first-craft knowledge point.", function()
		local n, cost = CH.Queue.FillFirstCrafts()
		CH.Print(n > 0 and string.format("queued %d first crafts for %s of reagents: %d knowledge points.", n, CH.FormatMoney(cost), n)
			or "no first crafts left in this profession (or open it first).")
	end)
	-- a status line under the bar, as the Craft window's
	panel.status = Wd.OneLine(text(panel, 12, -32, W - 24, "LEFT"))

	-- the queue, on its card
	T.BorderCard(panel, 6, QY, W - 12, QH)
	local y = QY - 6
	colHeads(panel, y, { { "Recipe", 12, 250, "LEFT" }, { "Crafter", 266, 90, "LEFT" }, { "Profit", 360, 86, "RIGHT" } })
	y = y - 16
	empty = text(panel, 12, y - 2, W - 24, "LEFT")
	qrows = {}
	for i = 1, QROWS do
		local r = {}
		local ry = y - (i - 1) * H
		r.name = Wd.OneLine(text(panel, 12, ry, 250))
		r.hit = itemHover(panel, 12, ry, 250)
		r.who = Wd.OneLine(text(panel, 266, ry, 90))
		r.profit = Wd.OneLine(text(panel, 360, ry, 86, "RIGHT"))
		r.craft = T.Primary(T.Button(panel, "Turn in", 58, 16))
		r.craft:SetPoint("TOPLEFT", 454, ry + 2)
		r.minus = T.Button(panel, "-", 18, 16)
		r.minus:SetPoint("TOPLEFT", 516, ry + 2)
		r.line = hairline(panel, ry - H + 3, W - 14)
		qrows[i] = r
	end
	local qwheel = CreateFrame("Frame", nil, panel)
	qwheel:SetPoint("TOPLEFT", 0, y + 2)
	qwheel:SetSize(W, QROWS * H)
	qBar = Wd.ScrollBar(panel, W - 9, y + 2, QROWS * H, true)
	Wd.Wheel(qwheel, QROWS, function() return qOffset end, function(v) qOffset = v end, function() return #CH.db.queue end, QUI.Refresh, qBar)

	-- the shopping list, on its card
	T.BorderCard(panel, 6, SY, W - 12, SH)
	shopHead = head(panel, 12, SY - 8, W - 24)
	local cols = { { "Reagent", 12, 250, "LEFT" }, { "Need", 264, 54 }, { "Have", 320, 54 }, { "Buy", 376, 54 }, { "Cost", 432, 96 } }
	y = SY - 24
	colHeads(panel, y, cols)
	srows = {}
	for i = 1, SROWS do
		local ry = y - i * H
		local r = {}
		for j, c in ipairs(cols) do r[j] = Wd.OneLine(text(panel, c[2], ry, c[3], c[4] or "RIGHT")) end
		r.hit = itemHover(panel, 12, ry, 250)
		r.costHit = CreateFrame("Button", nil, panel)
		r.costHit:SetPoint("TOPLEFT", 432, ry + 2)
		r.costHit:SetSize(96, H)
		r.costHit:SetScript("OnEnter", function(self)
			local lines = QUI.CostLines(self.row)
			if not lines[1] then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			for _, l in ipairs(lines) do GameTooltip:AddLine(l, 1, 1, 1) end
			GameTooltip:Show()
		end)
		r.costHit:SetScript("OnLeave", function() GameTooltip:Hide() end)
		r.line = hairline(panel, ry - H + 3, W - 14)
		srows[i] = r
	end
	local swheel = CreateFrame("Frame", nil, panel)
	swheel:SetPoint("TOPLEFT", 0, y - 16)
	swheel:SetSize(W, SROWS * H)
	sBar = Wd.ScrollBar(panel, W - 9, y - 16, SROWS * H, true)
	Wd.Wheel(swheel, SROWS, function() return sOffset end, function(v) sOffset = v end, function() return #(CH.Queue.ShoppingList()) end, QUI.Refresh, sBar)

	-- Budget: gold, reagents and Concentration, on hand against still needed, and what stops the queue
	T.BorderCard(panel, 6, BY, W - 12, BH)
	y = BY - 8
	budget = { head = head(panel, 12, y, W - 24 - 110), bars = {} }
	local plans = T.Button(panel, "Compare plans", 100, 16)
	plans:SetPoint("TOPRIGHT", -12, y + 2)
	plans:SetScript("OnClick", function(self) Wd.Tooltip(self, QUI.PlanLines()) end)
	plans:SetScript("OnEnter", function(self) Wd.Tooltip(self, { { "Compare restock plans" },
		{ T.Color("muted", "The queue as it is against a lean plan of a few days' sales: gold up front, gold back in a week, and stock left. Click to run it.") } }) end)
	plans:SetScript("OnLeave", function() GameTooltip:Hide() end)
	budget.plans = plans
	for i, name in ipairs({ "Gold", "Reagents", "Concentration" }) do
		local by = y - 4 - i * 14
		local b = { label = Wd.OneLine(text(panel, 12, by, 100)) }
		b.label:SetText(name)
		b.label:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
		b.track = panel:CreateTexture(nil, "ARTWORK")
		b.track:SetPoint("TOPLEFT", 116, by - 3)
		b.track:SetSize(250, 6)
		b.track:SetColorTexture(0.067, 0.067, 0.067, 1)
		b.fill = panel:CreateTexture(nil, "OVERLAY")
		b.fill:SetPoint("TOPLEFT", 116, by - 3)
		b.fill:SetSize(1, 6)
		T.Gradient(b.fill)
		b.text = Wd.OneLine(text(panel, 372, by, W - 372 - 12, "RIGHT"))
		budget.bars[i] = b
	end
	budget.stop = Wd.OneLine(text(panel, 12, y - 4 - 4 * 14, W - 24))
	T.Fonts(panel)
	Wd.Attach("queue", panel)
end

--- Redraw. Returns the queue and shopping lines it wrote, for the tests.
function QUI.Refresh()
	if not panel or not panel:IsShown() then return end
	local T = CH.Theme
	local q = CH.db.queue
	-- the status line: how many crafts and what they earn, as the Craft window says how many recipes
	local n, sum = CH.Queue.Count(), 0
	for _, e in ipairs(q) do sum = sum + (e.profit or 0) * (e.qty or 0) end
	panel.status:SetText(T.Color("muted", n == 0 and "Nothing queued." or string.format("%d %s queued, ", n, n == 1 and "craft" or "crafts"))
		.. (n > 0 and T.Color(sum >= 0 and "ok" or "bad", CH.FormatMoney(sum)) .. T.Color("muted", " profit") or "")
		.. (#q > QROWS and T.Color("muted", string.format(". Rows %d-%d of %d, scroll.", qOffset + 1, math.min(#q, qOffset + QROWS), #q)) or ""))
	empty:SetText(#q == 0 and T.Color("muted", "Empty. Pick a recipe in the Craft window and press Queue, or fill it from the buttons above.") or "")
	local lines = { queue = {}, shop = {} }
	qOffset = math.max(0, math.min(qOffset, #q - QROWS))
	qBar:Set(qOffset, QROWS, #q)
	for i, r in ipairs(qrows) do
		local e = q[i + qOffset]
		r.hit.id = e and e.item
		local show = e ~= nil
		r.craft:SetShown(show)
		r.minus:SetShown(show)
		r.line:SetShown(show)
		if show then
			local tag = (e.concentration and (" " .. CH.Window.ConcIcon(13)) or "") .. (e.firstCraft and T.Color("accent", " 1KP") or "")
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
					or step == "Shatter" and "Cast Shatter first (Shattering Essence: more Resourcefulness, Multicraft and Ingenuity)"
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
	shopHead:SetText(T.Color("accent", "SHOPPING LIST") .. (#shop > 0 and T.Color("muted", (total or 0) >= 1
		and ("  buy for " .. CH.FormatMoney(total) .. ", Shop queue at the AH") or "  nothing to buy: you have it all") or ""))
	sOffset = math.max(0, math.min(sOffset, #shop - SROWS))
	sBar:Set(sOffset, SROWS, #shop)
	if #shop > SROWS then shopHead:SetText(shopHead:GetText() .. CH.Theme.Color("muted", string.format("  (%d-%d of %d, scroll)", sOffset + 1, math.min(#shop, sOffset + SROWS), #shop))) end
	for i, r in ipairs(srows) do
		local s = shop[i + sOffset]
		r.hit.id = s and s.itemID
		r.costHit.row = s
		r.line:SetShown(s ~= nil)
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
	lines.budget = QUI.RenderBudget()
	return lines
end

local function ordinal(n) return CH.Decide and CH.Decide.Ordinal(n) or tostring(n) end

--- The budget lines: each bar's text, and the craft that hits a limit first. Also used by the tests.
function QUI.BudgetLines(b)
	local T, M = CH.Theme, CH.FormatMoney
	b = b or CH.Queue.Budget()
	local out = {}
	local function line(x, fmt, unitFmt)
		if x.need <= 0 then return T.Color("muted", "none needed") end
		local short = math.max(0, x.need - x.have)
		-- one short line: what's still needed, or that it's covered (the bar shows the share)
		return short > 0 and T.Color("bad", unitFmt(short) .. " short") .. T.Color("muted", " of " .. unitFmt(x.need))
			or T.Color("ok", unitFmt(x.need) .. " covered")
	end
	out[1] = line(b.gold, nil, M)
	out[2] = line(b.reagents, nil, M)
	out[3] = line(b.conc, nil, function(v) return tostring(math.floor(v + 0.5)) .. " pts" end)
	local function at(st)
		local e = st.entry
		return string.format("the %s %s%s", ordinal(st.n), e.name or "?", e.charName and (" (" .. e.charName .. ")") or "")
	end
	local WHY = { gold = "you run out of gold to buy its reagents", conc = "Concentration runs out", reagents = "reagents on hand run out" }
	local cs = b.conc.stop
	local up = cs and cs.upside and cs.upside >= 0.005 and T.Color("muted", string.format(" %d%% chance refunds cover it.", math.floor(cs.upside * 100 + 0.5))) or ""
	if b.stop then
		out[4] = T.Color("bad", "Stops at " .. at(b.stop) .. ": " .. WHY[b.stop.why]) .. "." .. (b.stop == cs and up or "")
	elseif b.reagents.stop then
		out[4] = T.Color("muted", "Buy first: " .. WHY.reagents .. " at " .. at(b.reagents.stop) .. ". Gold and Concentration cover the rest.")
	elseif CH.db.queue[1] then
		out[4] = T.Color("ok", "Nothing blocks this queue.")
	else
		out[4] = ""
	end
	return out
end

--- The plan comparison, as tooltip lines: for each plan, gold up front, gold back in a week (median
--- and the middle 80% of runs), the chance it pays back, and the stock left. Also used by the tests.
function QUI.PlanLines(opts)
	local T, M = CH.Theme, CH.FormatMoney
	local out = { { T.Color("accent", "Restock plans") .. T.Color("muted", string.format("  %d days, prices share one market move", CH.Decide.HORIZON)) } }
	if not CH.db.queue[1] then
		table.insert(out, { T.Color("muted", "The queue is empty.") })
		return out
	end
	for _, plan in ipairs(CH.Decide.Plans()) do
		local r = CH.Decide.Plan(plan.entries, opts)
		table.insert(out, { T.Color("accent", plan.label), string.format("%d crafts", r.crafts) })
		table.insert(out, { "   Gold up front, to buy reagents", M(r.cash) })
		table.insert(out, { "   Gold back by day " .. CH.Decide.HORIZON .. T.Color("muted", string.format("  80%%: %s to %s", M(r.back.p10 or 0), M(r.back.p90 or 0))), M(r.back.p50 or 0) })
		table.insert(out, { "   Chance sales cover the reagents", string.format("%d%%", math.floor(r.recover * 100 + 0.5)) })
		table.insert(out, { "   Stock left, estimated value", M(r.left) })
		if r.unpriced > 0 then table.insert(out, { T.Color("muted", string.format("   %d entries left out: no scan or price for their item", r.unpriced)) }) end
	end
	table.insert(out, { T.Color("muted", "Sales from region volume capped at your daily cap; price spread from Scenarios. Gold back counts only what sells.") })
	return out
end

--- Draw the budget bars. Returns their lines.
function QUI.RenderBudget()
	if not budget then return {} end
	local T = CH.Theme
	local b = CH.Queue.Budget()
	local lines = QUI.BudgetLines(b)
	budget.head:SetText(T.Color("accent", "BUDGET") .. T.Color("muted", "  the bar fills as you have what the queue needs"))
	for i, k in ipairs({ "gold", "reagents", "conc" }) do
		local x, bar = b[k], budget.bars[i]
		local share = x.need > 0 and math.min(1, x.have / x.need) or 1
		bar.fill:SetSize(math.max(1, 250 * share), 9)
		bar.track:SetAlpha(x.need > 0 and 1 or 0.3)
		bar.fill:SetAlpha(x.need > 0 and 1 or 0.3)
		bar.text:SetText(lines[i])
	end
	budget.stop:SetText(lines[4])
	return lines
end

function QUI.Show()
	if CH.Window.ResetQueueSpot then CH.Window.ResetQueueSpot() end
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
