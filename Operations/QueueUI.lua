-- Craft queue and shopping list panel. A tab beside Craft, or popped out beside it; /aiq queue opens it anywhere
-- (at the auction house, say) on its own.
local _, CH = ...

local QUI = {}
CH.QueueUI = QUI
local panel, qrows, srows, shopHead, empty, blocker
local QROWS, SROWS, W = 8, 8, 540
local budget -- { head, rows = { { label, text } } }
local qOffset, sOffset = 0, 0
local qBar, sBar
local showCovered = false -- the shopping list's covered reagents, folded away by default

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
-- The cards, top down: the queue, the next blocker, the shopping list, the budget. Each card's y and height.
local QY = -48
local QH = 22 + QROWS * H + 6
local KY = QY - QH - 6
local KH = 22
local SY = KY - KH - 6
local SH = 38 + SROWS * H + 6
local BY = SY - SH - 6
local BH = 70
-- the queue's columns: x and width
local C = { name = { 12, 206 }, who = { 222, 72 }, state = { 298, 96 }, profit = { 398, 60 }, craft = { 462, 50 }, minus = { 516, 18 } }

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
	line:SetSize(w, CH.Theme.Px(parent))
	line:SetColorTexture(0, 0, 0, 0.6)
	return line
end

local function hoverTip(f, lines)
	f:SetScript("OnEnter", function(self) local l = lines(self); if l and l[1] then CH.Window.Tooltip(self, l) end end)
	f:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

--- The bar's More menu: what it offers, for the menu and the tests. { label, run }.
function QUI.MenuItems()
	return {
		{ "Compare restock plans", function() if CH.UI and CH.UI.Page then CH.UI.Page("operations", "restock") end end },
		{ "Clear queue", function() CH.Queue.Clear() end },
	}
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
		if tip then hoverTip(b, function() return type(tip) == "function" and tip() or { { label }, { T.Color("muted", tip) } } end) end
		x = x - width - 4
		return b
	end
	-- the rarely used and the destructive sit in a menu, away from the routine buttons
	barButton("More", 48, "Compare restock plans (on the Queue page), or clear the queue.", function(self)
		if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
		MenuUtil.CreateContextMenu(self, function(_, root)
			for i, it in ipairs(QUI.MenuItems()) do
				if i == #QUI.MenuItems() and root.CreateDivider then root:CreateDivider() end
				root:CreateButton(it[1], it[2])
			end
		end)
	end)
	panel.pop = barButton("Pop out", 70, function()
		return { { CH.Window.InTabs("queue") and "Pop out" or "Join tabs" }, { T.Color("muted", CH.Window.InTabs("queue")
			and "Take the queue out of the tabs so it sits beside the Craft window." or "Put the queue back in the tabs, behind the Craft window.") } }
	end, function() CH.Window.ToggleQueuePop(); updatePop() end)
	-- a status line under the bar, as the Craft window's
	panel.status = Wd.OneLine(text(panel, 12, -32, W - 24, "LEFT"))

	-- the queue, on its card
	T.BorderCard(panel, 6, QY, W - 12, QH)
	local y = QY - 6
	colHeads(panel, y, { { "Recipe", C.name[1], C.name[2], "LEFT" }, { "Crafter", C.who[1], C.who[2], "LEFT" },
		{ "Status", C.state[1], C.state[2], "LEFT" }, { "Profit", C.profit[1], C.profit[2], "RIGHT" } })
	y = y - 16
	empty = text(panel, 12, y - 2, W - 24, "LEFT")
	qrows = {}
	for i = 1, QROWS do
		local r = {}
		local ry = y - (i - 1) * H
		r.name = Wd.OneLine(text(panel, C.name[1], ry, C.name[2]))
		r.hit = itemHover(panel, C.name[1], ry, C.name[2])
		r.who = Wd.OneLine(text(panel, C.who[1], ry, C.who[2]))
		r.state = Wd.OneLine(text(panel, C.state[1], ry, C.state[2]))
		r.stateHit = CreateFrame("Button", nil, panel)
		r.stateHit:SetPoint("TOPLEFT", C.state[1], ry + 2)
		r.stateHit:SetSize(C.state[2], H)
		hoverTip(r.stateHit, function(self) return self.lines end)
		r.profit = Wd.OneLine(text(panel, C.profit[1], ry, C.profit[2], "RIGHT"))
		r.craft = T.Primary(T.Button(panel, "Craft", C.craft[2], 16))
		r.craft:SetPoint("TOPLEFT", C.craft[1], ry + 2)
		r.minus = T.Button(panel, "-", C.minus[2], 16)
		r.minus:SetPoint("TOPLEFT", C.minus[1], ry + 2)
		hoverTip(r.minus, function(self) return self.lines end)
		r.line = hairline(panel, ry - H + 3, W - 14)
		qrows[i] = r
	end
	local qwheel = CreateFrame("Frame", nil, panel)
	qwheel:SetPoint("TOPLEFT", 0, y + 2)
	qwheel:SetSize(W, QROWS * H)
	qBar = Wd.ScrollBar(panel, W - 9, y + 2, QROWS * H, true)
	Wd.Wheel(qwheel, QROWS, function() return qOffset end, function(v) qOffset = v end, function() return #CH.db.queue end, QUI.Refresh, qBar)

	-- the first thing in the way, between the work and what to buy
	T.BorderCard(panel, 6, KY, W - 12, KH)
	blocker = Wd.OneLine(text(panel, 12, KY - 5, W - 24))

	-- the shopping list, on its card: shortages first, what you hold folded under one row
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
		r.hit:SetScript("OnClick", function(self) if self.toggle then showCovered = not showCovered; QUI.Refresh() end end)
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
	Wd.Wheel(swheel, SROWS, function() return sOffset end, function(v) sOffset = v end, function() return #(QUI.ShopRows()) end, QUI.Refresh, sBar)

	-- Budget: what the shopping costs, what's missing, and Concentration on each character's profession
	T.BorderCard(panel, 6, BY, W - 12, BH)
	y = BY - 8
	budget = { head = head(panel, 12, y, W - 24), rows = {} }
	for i, name in ipairs({ "Shopping cost", "Missing materials", "Concentration required" }) do
		local by = y - 4 - i * 14
		local b = { label = Wd.OneLine(text(panel, 12, by, 176)) }
		b.label:SetText(name)
		b.label:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
		b.text = Wd.OneLine(text(panel, 192, by, W - 192 - 12, "RIGHT"))
		budget.rows[i] = b
	end
	T.Fonts(panel)
	Wd.Attach("queue", panel)
end

--- The shopping list as the card shows it: reagents to buy first, then one row that folds the covered
--- ones away (or opens them under it). Returns the rows, the total to buy and the full list.
function QUI.ShopRows()
	local shop, total = CH.Queue.ShoppingList()
	local rows, covered = {}, {}
	for _, s in ipairs(shop) do
		if s.buy > 0 then rows[#rows + 1] = s else covered[#covered + 1] = s end
	end
	if covered[1] then
		rows[#rows + 1] = { toggle = true, n = #covered }
		if showCovered then for _, s in ipairs(covered) do rows[#rows + 1] = s end end
	end
	return rows, total, shop
end

function QUI.SetShowCovered(on) showCovered = on and true or false; return QUI.Refresh() end

local function itemName(id, shop)
	for _, s in ipairs(shop or {}) do if s.itemID == id then return s.name end end
	return C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id) or ("item " .. tostring(id))
end

-- An entry's shortfall, biggest first: "6 Sanguithorn and 2 more".
local function shortText(rd, shop)
	local list = {}
	for id, n in pairs(rd.short) do list[#list + 1] = { id = id, n = n } end
	table.sort(list, function(a, b) return a.n > b.n end)
	if not list[1] then return nil, list end
	return list[1].n .. " " .. itemName(list[1].id, shop) .. (#list > 1 and (" and " .. (#list - 1) .. " more") or ""), list
end

--- A queue row's status: its text and the hover lines. rd from Queue.Readiness, can/why from CanCraftHere.
function QUI.RowState(e, rd, can, why, step, shop)
	local T = CH.Theme
	local lines = { { e.name or "?" } }
	local function count() return string.format("Craft %d now · %d blocked", rd.now, rd.blocked) end
	if step == "Turn in" then return T.Color("ok", "Ready"), { { "Ready to turn in" } } end
	if rd.why == "switch" then
		table.insert(lines, { T.Color("muted", "Queued for " .. (e.charName or "another character") .. ": log in as them to craft it.") })
		return T.Color("accent", "Switch character"), lines
	end
	if not can then
		table.insert(lines, { T.Color("muted", "Craft " .. (why or "") .. ".") })
		return T.Color("muted", "Open profession"), lines
	end
	table.insert(lines, { rd.blocked > 0 and T.Color("fg", count()) or T.Color("ok", "All " .. e.qty .. " ready to craft") })
	local st, list = shortText(rd, shop)
	for _, x in ipairs(list) do table.insert(lines, { T.Color("bad", "Short " .. x.n .. " " .. itemName(x.id, shop)) }) end
	if rd.need then table.insert(lines, { T.Color("bad", string.format("Needs %d Concentration, %d left", rd.need, math.floor(rd.have or 0))) }) end
	if rd.blocked == 0 then return T.Color("ok", "Ready"), lines end
	if rd.now > 0 then return T.Color("accent", string.format("%d now · %d blocked", rd.now, rd.blocked)), lines end
	return T.Color("bad", rd.why == "conc" and "No Concentration" or "Missing reagents"), lines
end

--- The line between the queue and the shopping list: the first thing that stops you, or that nothing does.
function QUI.BlockerLine(ready, tot, b)
	local T, M = CH.Theme, CH.FormatMoney
	local q = CH.db.queue
	if not q[1] then return "" end
	if not ready then ready, tot = CH.Queue.Readiness() end
	b = b or CH.Queue.Budget()
	local gold = b.gold.need > b.gold.have and b.gold.need >= 1
		and T.Color("muted", string.format(". Buying it all costs %s, you have %s", M(b.gold.need), M(b.gold.have))) or ""
	for _, e in ipairs(q) do
		local rd = ready[e]
		if rd and rd.blocked > 0 and rd.why ~= "switch" then
			local what = string.format("%s x%d: craft %d now · %d blocked", e.name or "?", e.qty, rd.now, rd.blocked)
			if rd.why == "conc" then
				local cs = b.conc.stop
				local up = cs and cs.entry == e and cs.upside and cs.upside >= 0.005 and string.format(" (%d%% chance refunds cover it)", math.floor(cs.upside * 100 + 0.5)) or ""
				return T.Color("bad", "Next blocker: ") .. what .. T.Color("bad", string.format(", needs %d Concentration, %d left", rd.need or 0, math.floor(rd.have or 0))) .. T.Color("muted", up)
			end
			return T.Color("bad", "Next blocker: ") .. what .. T.Color("bad", ", short " .. (shortText(rd, b.shop) or "reagents")) .. gold
		end
	end
	if tot.blocked > 0 then
		local who
		for _, e in ipairs(q) do if ready[e] and ready[e].why == "switch" then who = e.charName or e.char; break end end
		return (tot.now > 0 and T.Color("ok", string.format("%d ready here. ", tot.now)) or "")
			.. T.Color("accent", "The rest is on " .. tostring(who or "another character") .. ": log in as them to craft it.")
	end
	return T.Color("ok", string.format("Nothing blocks: all %d %s ready.", tot.now, tot.now == 1 and "craft is" or "crafts are"))
end

--- Redraw. Returns the queue and shopping lines it wrote, for the tests.
function QUI.Refresh()
	if not panel or not panel:IsShown() then return end
	local T = CH.Theme
	local q = CH.db.queue
	local ready, tot = CH.Queue.Readiness()
	local b = CH.Queue.Budget()
	-- the status line: how many crafts, how many you can make now, and what they should earn
	local n, sum = CH.Queue.Count(), 0
	for _, e in ipairs(q) do sum = sum + (e.profit or 0) * (e.qty or 0) end
	panel.status:SetText(n == 0 and T.Color("muted", "Nothing queued.")
		or (T.Color("muted", string.format("%d %s queued · ", n, n == 1 and "craft" or "crafts"))
		.. T.Color(tot.now > 0 and "ok" or "muted", tot.now .. " ready now") .. T.Color("muted", " · Estimated profit ")
		.. T.Color(sum >= 0 and "ok" or "bad", CH.FormatMoney(sum))
		.. (#q > QROWS and T.Color("muted", string.format(" · rows %d-%d of %d", qOffset + 1, math.min(#q, qOffset + QROWS), #q)) or "")))
	empty:SetText(#q == 0 and T.Color("muted", "Empty. Queue crafts from the Craft window: a recipe's Queue button, Fill queue, Work orders or First crafts.") or "")
	local shopRows, total, shop = QUI.ShopRows()
	local lines = { queue = {}, shop = {}, state = {} }
	qOffset = math.max(0, math.min(qOffset, #q - QROWS))
	qBar:Set(qOffset, QROWS, #q)
	for i, r in ipairs(qrows) do
		local e = q[i + qOffset]
		r.hit.id = e and e.item
		local show = e ~= nil
		r.craft:SetShown(show)
		r.minus:SetShown(show)
		r.line:SetShown(show)
		r.stateHit:SetShown(show)
		if show then
			local tag = (e.concentration and (" " .. CH.Window.ConcIcon(13)) or "") .. (e.firstCraft and T.Color("accent", " 1KP") or "")
				.. (e.orderID and T.Color("accent", " order") or "") .. (e.special and T.Color("accent", " reward") or "")
			-- the count first, so a long name cut short keeps it
			r.name:SetText(string.format("%s%dx %s%s%s", CH.Window.ItemIcon(e.item, 15), e.qty, e.name or "?", rank(e.quality, e.tiers), tag))
			r.who:SetText(classColor(e.class) .. (e.charName or "?") .. "|r")
			r.profit:SetText(e.profit and T.Color(e.profit >= 0 and "ok" or "bad", CH.FormatMoney(e.profit * e.qty)) or "")
			local rd = ready[e] or { now = 0, blocked = e.qty, short = {} }
			local can, why = CH.Queue.CanCraftHere(e)
			local step = CH.Queue.OrderStep(e)
			local state, tip = QUI.RowState(e, rd, can, why, step, shop)
			r.state:SetText(state)
			r.stateHit.lines = tip
			-- a craft waits for its reagents and Concentration; claiming and turning in don't
			local gated = step ~= "Claim" and step ~= "Turn in"
			r.craft:SetEnabled(can and (not gated or rd.now > 0))
			local label = gated and step == "Craft" and rd.now > 0 and rd.now < e.qty and ("Craft " .. rd.now) or step
			if r.craft.text then r.craft.text:SetText(label) elseif r.craft.SetText then r.craft:SetText(label) end
			r.craft:SetScript("OnClick", function()
				-- check again: bags and Concentration may have changed since the redraw
				local now = CH.Queue.Readiness()[e]
				if gated and not (now and now.now > 0) then
					CH.Print("can't craft " .. (e.name or "it") .. " yet: " .. T.Color("bad", (now and now.why == "conc") and "not enough Concentration" or "reagents missing") .. ".")
					return QUI.Refresh()
				end
				CH.Queue.Craft(e, gated and step == "Craft" and math.min(e.qty, now.now) or e.qty)
			end)
			r.craft:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_TOP")
				GameTooltip:AddLine(not can and ("Craft " .. why)
					or step == "Claim" and ("Claim " .. (e.customer or "the") .. "'s order")
					or step == "Turn in" and "Turn in the order"
					or step == "Shatter" and "Cast Shatter first (Shattering Essence: more Resourcefulness, Multicraft and Ingenuity)"
					or rd.now == 0 and "Nothing to craft yet: see the status"
					or ("Craft " .. math.min(e.qty, rd.now) .. " with the queued reagents" .. (e.concentration and " and Concentration" or "")
						.. (rd.blocked > 0 and (", " .. rd.blocked .. " stay queued") or "")), 1, 1, 1)
				GameTooltip:Show()
			end)
			r.craft:SetScript("OnLeave", function() GameTooltip:Hide() end)
			r.minus:SetScript("OnClick", function() CH.Queue.Remove(e, IsShiftKeyDown() and e.qty or 1) end)
			r.minus.lines = { { "Remove one" }, { T.Color("muted", e.qty > 1 and ("Shift-click removes all " .. e.qty .. ".") or "It's the last one: the row goes.") } }
			table.insert(lines.queue, string.format("%s Q%d x%d %s", e.name, e.quality or 0, e.qty, e.charName or ""))
			table.insert(lines.state, state)
		else
			r.name:SetText(""); r.who:SetText(""); r.profit:SetText(""); r.state:SetText("")
		end
	end
	blocker:SetText(QUI.BlockerLine(ready, tot, b))
	lines.blocker = blocker:GetText()
	local buyN = 0
	for _, s in ipairs(shop) do if s.buy > 0 then buyN = buyN + 1 end end
	shopHead:SetText(T.Color("accent", "SHOPPING LIST") .. (#shop > 0 and T.Color("muted", (total or 0) >= 1
		and string.format("  %d to buy for %s, Shop queue at the AH", buyN, CH.FormatMoney(total)) or "  nothing to buy: you have it all") or ""))
	sOffset = math.max(0, math.min(sOffset, #shopRows - SROWS))
	sBar:Set(sOffset, SROWS, #shopRows)
	if #shopRows > SROWS then shopHead:SetText(shopHead:GetText() .. CH.Theme.Color("muted", string.format("  (%d-%d of %d, scroll)", sOffset + 1, math.min(#shopRows, sOffset + SROWS), #shopRows))) end
	for i, r in ipairs(srows) do
		local s = shopRows[i + sOffset]
		r.hit.id = s and s.itemID
		r.hit.toggle = s and s.toggle
		r.costHit.row = s and not s.toggle and s or nil
		r.line:SetShown(s ~= nil)
		if s and s.toggle then
			r[1]:SetText(T.Color("muted", string.format("%s %d covered %s", showCovered and "-" or "+", s.n, s.n == 1 and "reagent" or "reagents"))
				.. T.Color("muted", showCovered and "  (click to fold)" or "  (click to show)"))
			for j = 2, 5 do r[j]:SetText("") end
			table.insert(lines.shop, string.format("covered=%d %s", s.n, showCovered and "open" or "folded"))
		elseif s then
			r[1]:SetText(CH.Window.ItemIcon(s.itemID, 15) .. s.name .. rank(s.rank, s.tiers))
			r[2]:SetText(s.need)
			r[3]:SetText(T.Color(s.have >= s.need and "ok" or "fg", tostring(s.have)))
			r[4]:SetText(s.buy > 0 and T.Color("bad", tostring(s.buy)) or T.Color("muted", "0"))
			r[5]:SetText(s.buy > 0 and s.cost and T.Color((s.short or 0) > 0 and "bad" or "fg", CH.FormatMoney(s.cost)) or "")
		else
			for j = 1, 5 do r[j]:SetText("") end
		end
	end
	lines.shopAll = {}
	for _, s in ipairs(shop) do table.insert(lines.shopAll, string.format("%s need=%d have=%d buy=%d", s.name, s.need, s.have, s.buy)) end
	lines.budget = QUI.RenderBudget(b)
	return lines
end

--- The budget lines: shopping cost against your gold, the reagents still missing, and Concentration
--- needed against what each character's profession has. Also used by the tests.
function QUI.BudgetLines(b)
	local T, M = CH.Theme, CH.FormatMoney
	b = b or CH.Queue.Budget()
	local out = {}
	local g = b.gold
	out[1] = g.need < 1 and T.Color("muted", "nothing to buy")
		or g.need <= g.have and (T.Color("ok", M(g.need)) .. T.Color("muted", ", you have " .. M(g.have)))
		or (T.Color("bad", M(g.need)) .. T.Color("muted", ", you have " .. M(g.have) .. ": ") .. T.Color("bad", M(g.need - g.have) .. " short"))
	local units, kinds = 0, 0
	for _, s in ipairs(b.shop or {}) do if s.buy > 0 then units, kinds = units + s.buy, kinds + 1 end end
	out[2] = units == 0 and T.Color("ok", "all on hand")
		or T.Color("bad", string.format("%d %s short", units, units == 1 and "reagent" or "reagents")) .. T.Color("muted", string.format(" (%d %s)", kinds, kinds == 1 and "kind" or "kinds"))
	local parts = {}
	for _, x in ipairs(b.conc.by or {}) do
		if x.need > 0 then
			parts[#parts + 1] = T.Color("muted", tostring(x.char) .. " " .. tostring(x.prof or "") .. " ")
				.. T.Color(x.need <= x.have and "ok" or "bad", string.format("%d of %d", math.floor(x.need + 0.5), math.floor(x.have)))
		end
	end
	out[3] = parts[1] and table.concat(parts, T.Color("muted", ", ")) or T.Color("muted", "none needed")
	return out
end

--- Draw the budget lines. Returns them.
function QUI.RenderBudget(b)
	if not budget then return {} end
	local T = CH.Theme
	local lines = QUI.BudgetLines(b)
	budget.head:SetText(T.Color("accent", "BUDGET") .. T.Color("muted", "  what the queue needs against what you have"))
	for i, row in ipairs(budget.rows) do row.text:SetText(lines[i]) end
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
