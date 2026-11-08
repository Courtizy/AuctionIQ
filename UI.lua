-- Clearinghouse main window, opened with /ch or from the addon compartment, like TSM's.
local _, CH = ...

local UI = {}
CH.UI = UI
local frame, text
local W, H = 920, 600
local pages, pageButtons = {}, {}
local page = "dashboard"
local range = "1M"
local ledgerView, ledgerFilter, ledgerOffset = "inventory", "", 0
local RANGES = { { "1D", 1 }, { "1W", 7 }, { "1M", 30 }, { "3M", 91 }, { "6M", 182 }, { "1Y", 365 }, { "All", nil } }

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
			-- the recipe scan (best reagents, average profit) when there is one, else the quick top-quality list
			local scanned = p.scan and p.scan.rows
			local list = scanned or p.crafts or {}
			local n = 0
			for _, r in ipairs(list) do
				if n >= 3 then break end
				if r.profit and r.profit > 0 then
					n = n + 1
					listed = true
					table.insert(out, string.format("   %s%s|r %s: %s%s  %s", classColor(c.class), c.name or c.key, p.name or "?", r.name or "?",
						scanned and r.quality and (" Q" .. r.quality) or "", CH.Theme.Color(r.profit >= 0 and "ok" or "bad", CH.FormatMoney(r.profit))))
				end
			end
		end
	end
	if not listed then
		table.insert(out, CH.Prices.Available() and "   Open a profession window to rank its recipes."
			or "   Needs TradeSkillMaster for prices.")
	end

	local cds = CH.Cooldowns and CH.Cooldowns.All(now) or {}
	if #cds > 0 then
		table.insert(out, "")
		table.insert(out, CH.Theme.Color("accent", "Cooldowns"))
		for i, cd in ipairs(cds) do
			if i > 6 then break end
			local when = cd.ready and CH.Theme.Color("ok", "ready")
				or ("in " .. math.ceil(((cd.readyAt or now) - now) / 3600) .. "h")
			table.insert(out, string.format("   %s%s|r %s  %s", classColor(cd.class), cd.char or "?", cd.name or "?", when))
		end
	end
	return table.concat(out, "\n")
end

-- Window -------------------------------------------------------------------------------------
local function fs(parent, x, y, w, justify, template)
	local f = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
	f:SetPoint("TOPLEFT", x, y)
	if w then f:SetWidth(w) end
	f:SetJustifyH(justify or "LEFT")
	return CH.Window.OneLine(f)
end

local function panel(parent, x, y, w, h)
	local p = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	p:SetPoint("TOPLEFT", x, y)
	p:SetSize(w, h)
	CH.Theme.Panel(p, "panel", 1)
	return p
end

local function setLabel(b, t) if b.text then b.text:SetText(t) elseif b.SetText then b:SetText(t) end end
local function colorButton(b, on)
	local T = CH.Theme
	local f = b.text or (b.GetFontString and b:GetFontString())
	local c = on and T.accent or T.fg
	if f and f.SetTextColor then f:SetTextColor(c[1], c[2], c[3]) end
end

local function money(c, sign)
	if not c then return CH.Theme.Color("muted", "-") end
	local t = CH.FormatMoney(c)
	if sign and c > 0 then t = "+" .. t end
	return t
end

local function shortGold(c)
	local g = (c or 0) / 10000
	if math.abs(g) >= 1000000 then return string.format("%.1fm", g / 1000000) end
	if math.abs(g) >= 1000 then return string.format("%dk", math.floor(g / 1000 + 0.5)) end
	return string.format("%dg", math.floor(g + 0.5))
end

local function rangeStart(now)
	for _, r in ipairs(RANGES) do
		if r[1] == range then return r[2] and (now - r[2] * 86400) or nil end
	end
end

-- Dashboard data (also used by the tests) -----------------------------------------------------
--- Everything the Dashboard shows for the current range.
function UI.DashboardData(now)
	now = now or time()
	local L = CH.Ledger
	if not L.Available() then return nil end
	if not next(CH.db.ledger and CH.db.ledger.days or {}) then L.Archive() end
	local since = rangeStart(now)
	local first = now
	for _, r in ipairs(L.Records("Sales")) do if r.time < first then first = r.time end end
	since = since or first
	local d = { since = since, now = now }
	d.summary = L.Summary(since)
	local spanDays = math.max(1, (now - since) / 86400)
	d.avgEarned, d.avgSpent = d.summary.earned / spanDays, d.summary.spent / spanDays
	d.avgSold = d.summary.sold / spanDays
	d.series = L.GoldSeries(since, now, 90)
	local hi, lo
	local started = false -- skip the stretch before TSM started logging gold
	for _, p in ipairs(L.GoldSeries(now - 364 * 86400, now, 120)) do
		started = started or p.v > 0
		if started then hi, lo = math.max(hi or p.v, p.v), math.min(lo or p.v, p.v) end
	end
	d.high, d.low = hi, lo
	d.gold = L.Gold()
	local dayAgo = L.GoldSeries(now - 86400, now, 2)
	d.dailyChange = dayAgo[2].v - dayAgo[1].v
	local topSale, topBuy, spentItems = 0, 0, {}
	for _, r in ipairs(L.Records("Sales")) do if r.time >= since and r.amount > topSale then topSale = r.amount end end
	for _, r in ipairs(L.Records("Buys")) do
		if r.time >= since then
			if r.amount > topBuy then topBuy = r.amount end
			if r.id then spentItems[r.id] = (spentItems[r.id] or 0) + r.amount end
		end
	end
	local bi, bv = nil, 0
	for id, v in pairs(spentItems) do if v > bv then bi, bv = id, v end end
	d.topSale, d.topBuy, d.topSpentItem = topSale, topBuy, bi
	d.worthChange = L.WorthChange(since)
	d.activity = L.Activity(40)
	return d
end

local VIEWS = {
	inventory = { label = "Inventory", cols = { { "Item", 0, 250 }, { "Total", 256, 70 }, { "Bags", 330, 64 }, { "Bank", 398, 70 },
		{ "Mail", 472, 56 }, { "Warband", 532, 70 }, { "AH", 606, 56 }, { "Value", 666, 112 } } },
	revenue = { label = "Revenue", cols = { { "Item", 0, 250 }, { "Player", 256, 90 }, { "Qty", 350, 50 }, { "Each", 404, 90 },
		{ "Total", 498, 100 }, { "Source", 602, 76 }, { "When", 682, 96 } } },
	expenses = { label = "Expenses", cols = { { "Item", 0, 250 }, { "Player", 256, 90 }, { "Qty", 350, 50 }, { "Each", 404, 90 },
		{ "Total", 498, 100 }, { "Source", 602, 76 }, { "When", 682, 96 } } },
	failed = { label = "Failed Auctions", cols = { { "Item", 0, 250 }, { "Player", 256, 90 }, { "Qty", 350, 50 }, { "Why", 404, 100 },
		{ "When", 682, 96 } } },
}
local VIEW_ORDER = { "inventory", "revenue", "expenses", "failed" }

local function itemName(id, fallback)
	local n = id and C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
	return n or fallback or (id and ("item " .. id)) or "?"
end

local function when(t)
	return date and date("%b %d %H:%M", t) or tostring(t)
end

--- Ledger rows for a view as lists of cell texts, plus the footer text. Filter matches names.
function UI.LedgerRows(view, filter)
	local L = CH.Ledger
	local out, total = {}, 0
	local key = filter and filter ~= "" and string.lower(filter) or nil
	local function keep(name) return not key or string.lower(name or ""):find(key, 1, true) end
	if view == "inventory" then
		for _, e in ipairs(L.Inventory(filter)) do
			total = total + e.value
			table.insert(out, { CH.Window.ItemIcon(e.id, 14) .. itemName(e.id, e.item), e.total, e.bags, e.bank, e.mail, e.warband, e.ah, money(e.value) })
		end
		return out, "Total value: " .. money(total)
	end
	local list = {}
	if view == "revenue" then
		for _, r in ipairs(L.Records("Sales")) do table.insert(list, r) end
		for _, r in ipairs(L.Records("Income")) do r.label = r.source; table.insert(list, r) end
	elseif view == "expenses" then
		for _, r in ipairs(L.Records("Buys")) do table.insert(list, r) end
		for _, r in ipairs(L.Records("Expense")) do r.label = r.source; table.insert(list, r) end
	else
		for _, r in ipairs(L.Records("Expired")) do r.why = "Expired"; table.insert(list, r) end
		for _, r in ipairs(L.Records("Cancelled")) do r.why = "Cancelled"; table.insert(list, r) end
	end
	table.sort(list, function(a, b) return a.time > b.time end)
	for _, r in ipairs(list) do
		local name = r.label or itemName(r.id, r.item)
		if keep(name) then
			if view == "failed" then
				total = total + r.quantity
				table.insert(out, { CH.Window.ItemIcon(r.id, 14) .. name, r.player or "?", r.quantity, r.why, when(r.time) })
			else
				total = total + r.amount
				table.insert(out, { (r.id and CH.Window.ItemIcon(r.id, 14) or "") .. name, r.player or "?", r.label and "" or r.quantity,
					r.label and "" or money(r.price), money(r.amount), r.label and (r.other or "") or (r.source or ""), when(r.time) })
			end
		end
	end
	return out, view == "failed" and (total .. " items came back") or ("Total: " .. money(total))
end

-- Building ------------------------------------------------------------------------------------
local function buildDashboard(p)
	local T = CH.Theme
	local d = {}
	pages.dashboard = p
	p.d = d
	-- activity log
	local log = panel(p, 0, 0, 250, H - 70)
	local head = fs(log, 10, -10, 230, "LEFT", "GameFontNormal")
	head:SetText("Activity Log")
	d.cards = {}
	for i = 1, 7 do
		local c = {}
		local y = -36 - (i - 1) * 70
		c.who = fs(log, 10, y, 140)
		c.time = fs(log, 150, y, 90, "RIGHT")
		c.l1 = fs(log, 20, y - 16, 220)
		c.l2 = fs(log, 20, y - 30, 220)
		c.l3 = fs(log, 20, y - 44, 220, "RIGHT")
		d.cards[i] = c
	end
	d.logOffset = 0
	log:EnableMouseWheel(true)
	log:SetScript("OnMouseWheel", function(_, delta) d.logOffset = math.max(0, d.logOffset - delta); UI.Refresh() end)

	-- chart
	local x0 = 262
	local cw = W - 24 - x0
	d.title = fs(p, x0, -4, 300, "LEFT", "GameFontNormalLarge")
	d.sub = fs(p, x0, -26, 300, "LEFT")
	d.rangeButtons = {}
	local bx = W - 24
	for i = #RANGES, 1, -1 do
		local r = RANGES[i]
		local b = T.Button(p, r[1], 36, 18)
		b:SetPoint("TOPRIGHT", p, "TOPLEFT", bx, -4)
		b:SetScript("OnClick", function() range = r[1]; UI.Refresh() end)
		d.rangeButtons[r[1]] = b
		bx = bx - 40
	end
	local chart = panel(p, x0, -48, cw, 210)
	d.chart = chart
	d.grid, d.gridLabels, d.lines, d.xLabels = {}, {}, {}, {}
	for i = 1, 5 do
		local g = chart:CreateTexture(nil, "BACKGROUND")
		g:SetColorTexture(T.line[1], T.line[2], T.line[3], 1)
		g:SetHeight(1)
		d.grid[i] = g
		d.gridLabels[i] = fs(chart, 4, 0, 56, "RIGHT", "GameFontDisableSmall")
	end
	for i = 1, 5 do d.xLabels[i] = fs(chart, 0, -194, 80, "CENTER", "GameFontDisableSmall") end

	-- stat row
	d.stats = {}
	local labels = { { "52W HIGH", "high" }, { "AVG DAILY SALES", "avgSold" }, { "TOP SALE", "topSale" },
		{ "52W LOW", "low" }, { "DAILY CHANGE", "dailyChange" }, { "TOP PURCHASE", "topBuy" } }
	for i, l in ipairs(labels) do
		local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
		local lab = fs(p, x0 + col * 210, -268 - row * 20, 120, "LEFT", "GameFontNormalSmall")
		lab:SetText(l[1])
		d.stats[l[2]] = fs(p, x0 + col * 210 + 112, -268 - row * 20, 92, "RIGHT")
	end

	-- sales / expenses / profit
	local box = panel(p, x0, -312, cw, H - 70 - 312)
	d.box = {}
	local y = -10
	local function section(title)
		local h = fs(box, 10, y, 200, "LEFT", "GameFontNormal")
		h:SetText(title)
		y = y - 18
	end
	local function line(key, label)
		local a = fs(box, 10, y, 300)
		a:SetText(label)
		d.box[key] = fs(box, cw - 330, y, 320, "RIGHT")
		y = y - 15
	end
	section("SALES")
	line("earned", "Total gold earned")
	line("avgEarned", "Average earned per day")
	line("topItem", "Top item")
	y = y - 4
	section("EXPENSES")
	line("spent", "Total gold spent")
	line("avgSpent", "Average spent per day")
	line("topSpent", "Top item")
	y = y - 4
	section("PROFIT")
	line("cash", "Cash profit (earned less spent)")
	line("worth", "Net worth change (gold + inventory)")
	d.note = fs(box, 10, y - 2, cw - 20, "LEFT", "GameFontDisableSmall")
end

local function buildLedger(p)
	local T = CH.Theme
	pages.ledger = p
	local nav = panel(p, 0, 0, 160, H - 70)
	p.nav = {}
	for i, k in ipairs(VIEW_ORDER) do
		local b = T.Button(nav, VIEWS[k].label, 144, 22)
		b:SetPoint("TOPLEFT", 8, -10 - (i - 1) * 26)
		b:SetScript("OnClick", function() ledgerView = k; ledgerOffset = 0; UI.Refresh() end)
		p.nav[k] = b
	end
	local x0 = 172
	local search = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
	search:SetSize(300, 20)
	search:SetPoint("TOPLEFT", x0 + 6, -4)
	search:SetAutoFocus(false)
	search:SetScript("OnTextChanged", function(self) ledgerFilter = self:GetText() or ""; ledgerOffset = 0; UI.Refresh() end)
	search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	p.hint = fs(p, x0 + 320, -8, 300, "LEFT", "GameFontDisableSmall")
	p.hint:SetText("Filter by item name")
	p.heads, p.rows = {}, {}
	for j = 1, 8 do p.heads[j] = fs(p, 0, -34, 10, "LEFT", "GameFontNormalSmall") end
	for i = 1, 24 do
		local r = {}
		for j = 1, 8 do r[j] = fs(p, 0, -52 - (i - 1) * 18, 10) end
		p.rows[i] = r
	end
	p.footer = fs(p, x0, -H + 86, W - x0 - 24, "CENTER", "GameFontNormal")
	p:EnableMouseWheel(true)
	p:SetScript("OnMouseWheel", function(_, delta) ledgerOffset = math.max(0, ledgerOffset - delta * 5); UI.Refresh() end)
end

local function buildBriefing(p)
	local T = CH.Theme
	pages.briefing = p
	local scroll = CreateFrame("ScrollFrame", nil, p)
	scroll:SetPoint("TOPLEFT", 4, 0)
	scroll:SetPoint("BOTTOMRIGHT", -4, 0)
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local y = math.max(0, math.min(self:GetVerticalScrollRange(), self:GetVerticalScroll() - delta * 40))
		self:SetVerticalScroll(y)
	end)
	local child = CreateFrame("Frame", nil, scroll)
	child:SetSize(W - 40, 10)
	scroll:SetScrollChild(child)
	text = child:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	text:SetPoint("TOPLEFT")
	text:SetWidth(W - 40)
	text:SetJustifyH("LEFT")
	text:SetSpacing(4)
	text:SetTextColor(T.fg[1], T.fg[2], T.fg[3])
end

local function build()
	local T = CH.Theme
	frame = CH.Window.New("ClearinghouseFrame", "", W, H)
	frame.title:SetText(T.Color("accent", "Clearinghouse"))
	frame.TitleText = frame.title
	local x = 150
	for _, pg in ipairs({ { "dashboard", "Dashboard" }, { "ledger", "Ledger" }, { "briefing", "Briefing" } }) do
		local b = T.Button(frame.bar, pg[2], 84, 20)
		b:SetPoint("LEFT", x, 0)
		b:SetScript("OnClick", function() page = pg[1]; UI.Refresh() end)
		pageButtons[pg[1]] = b
		x = x + 88
	end
	frame.gold = frame.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	frame.gold:SetPoint("RIGHT", frame.close, "LEFT", -10, 0)
	for _, b in ipairs({ buildDashboard, buildLedger, buildBriefing }) do
		local p = CreateFrame("Frame", nil, frame)
		p:SetPoint("TOPLEFT", 12, -36)
		p:SetSize(W - 24, H - 48)
		b(p)
	end
	frame.foot = fs(frame, 12, -H + 18, W - 24, "LEFT", "GameFontDisableSmall")
	frame:SetScript("OnShow", function()
		if CH.Ledger.Available() then pcall(CH.Ledger.Archive); pcall(CH.Ledger.Snapshot) end
		UI.Refresh()
	end)
	T.Fonts(frame)
end

-- Drawing -------------------------------------------------------------------------------------
local function drawChart(d, data)
	local chart = d.chart
	local cw, ch = chart:GetWidth() or (W - 286), 170
	local left, top = 64, -12
	local series = data.series
	local lo, hi
	for _, p in ipairs(series) do lo, hi = math.min(lo or p.v, p.v), math.max(hi or p.v, p.v) end
	lo, hi = lo or 0, hi or 1
	if hi - lo < 10000 then hi = lo + 10000 end
	local pad = (hi - lo) * 0.1
	lo, hi = math.max(0, lo - pad), hi + pad
	local plotW = cw - left - 12
	for i, g in ipairs(d.grid) do
		local frac = (i - 1) / (#d.grid - 1)
		local y = top - ch * frac
		g:ClearAllPoints()
		g:SetPoint("TOPLEFT", chart, "TOPLEFT", left, y)
		g:SetPoint("TOPRIGHT", chart, "TOPRIGHT", -12, y)
		local lab = d.gridLabels[i]
		lab:ClearAllPoints()
		lab:SetPoint("TOPLEFT", chart, "TOPLEFT", 2, y + 6)
		lab:SetText(shortGold(hi - (hi - lo) * frac))
	end
	for _, l in pairs(d.lines) do if l then l:Hide() end end
	local T = CH.Theme
	local px = {}
	for i, p in ipairs(series) do
		px[i] = { left + plotW * (i - 1) / math.max(1, #series - 1), top - ch * (1 - (p.v - lo) / (hi - lo)) }
	end
	for i = 2, #px do
		local l = d.lines[i]
		if l == nil and chart.CreateLine then l = chart:CreateLine(nil, "ARTWORK"); d.lines[i] = l or false end
		if l then
			l:SetThickness(2)
			l:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 1)
			l:SetStartPoint("TOPLEFT", chart, px[i - 1][1], px[i - 1][2])
			l:SetEndPoint("TOPLEFT", chart, px[i][1], px[i][2])
			l:Show()
		end
	end
	for i, lab in ipairs(d.xLabels) do
		local frac = (i - 1) / (#d.xLabels - 1)
		local t = data.since + (data.now - data.since) * frac
		lab:ClearAllPoints()
		lab:SetPoint("TOPLEFT", chart, "TOPLEFT", left + plotW * frac - 40, top - ch - 6)
		lab:SetText(date and date(range == "1D" and "%H:%M" or "%b %d", t) or "")
	end
	return px
end

local function refreshDashboard()
	local d = pages.dashboard.d
	local T = CH.Theme
	for k, b in pairs(d.rangeButtons) do colorButton(b, k == range) end
	if not CH.Ledger.Available() then
		d.title:SetText("Dashboard")
		d.sub:SetText(T.Color("muted", "Needs TradeSkillMaster: the dashboard reads its gold log and accounting."))
		return nil
	end
	local data = UI.DashboardData()
	d.title:SetText("Gold")
	d.sub:SetText(T.Color("muted", "All characters on " .. (GetRealmName and GetRealmName() or "") .. " + warband bank, now ") .. CH.FormatMoney(data.gold))
	drawChart(d, data)
	d.stats.high:SetText(money(data.high))
	d.stats.low:SetText(money(data.low))
	d.stats.avgSold:SetText(string.format("%.1f", data.avgSold))
	d.stats.dailyChange:SetText(T.Color(data.dailyChange >= 0 and "ok" or "bad", money(data.dailyChange, true)))
	d.stats.topSale:SetText(money(data.topSale))
	d.stats.topBuy:SetText(money(data.topBuy))
	local s = data.summary
	d.box.earned:SetText(T.Color("ok", money(s.earned)))
	d.box.avgEarned:SetText(money(data.avgEarned))
	d.box.topItem:SetText(s.topItem and (CH.Window.ItemIcon(s.topItem, 14) .. itemName(s.topItem)) or "-")
	d.box.spent:SetText(T.Color("bad", money(s.spent)))
	d.box.avgSpent:SetText(money(data.avgSpent))
	d.box.topSpent:SetText(data.topSpentItem and (CH.Window.ItemIcon(data.topSpentItem, 14) .. itemName(data.topSpentItem)) or "-")
	d.box.cash:SetText(T.Color(s.cash >= 0 and "ok" or "bad", money(s.cash, true)))
	local wc = data.worthChange
	d.box.worth:SetText(wc and T.Color(wc >= 0 and "ok" or "bad", money(wc, true)) or T.Color("muted", "tracking from today"))
	d.note:SetText("Cash profit counts reagents you bought as spent, like TSM. Net worth change also counts what you still hold, so stock you bought to craft with isn't a loss.")
	-- activity cards
	for i, c in ipairs(d.cards) do
		local a = data.activity[i + d.logOffset]
		if a then
			c.who:SetText(a.player or "?")
			c.time:SetText(T.Color("muted", date and date("%b %d %H:%M", a.time) or ""))
			c.l1:SetText(a.expired > 0 and (a.expired .. T.Color("muted", " expired")) or "")
			local sold = a.sold > 0 and (a.sold .. T.Color("muted", " sold  ") .. money(a.gold)) or ""
			local bought = a.bought > 0 and (a.bought .. T.Color("muted", " bought  ") .. money(a.spent)) or ""
			c.l2:SetText(sold ~= "" and sold or bought)
			local net = a.gold - a.spent
			c.l3:SetText(net ~= 0 and T.Color(net >= 0 and "ok" or "bad", money(net, true)) or "")
		else
			c.who:SetText(""); c.time:SetText(""); c.l1:SetText(""); c.l2:SetText(""); c.l3:SetText("")
		end
	end
	return data
end

local function refreshLedger()
	local p = pages.ledger
	for k, b in pairs(p.nav) do colorButton(b, k == ledgerView) end
	local v = VIEWS[ledgerView]
	local x0 = 172
	for j, h in ipairs(p.heads) do
		local c = v.cols[j]
		h:ClearAllPoints()
		if c then
			h:SetPoint("TOPLEFT", x0 + c[2], -34)
			h:SetWidth(c[3])
			h:SetJustifyH(j == 1 and "LEFT" or "RIGHT")
			h:SetText(c[1])
		else
			h:SetText("")
		end
	end
	local rows, footer = {}, ""
	if CH.Ledger.Available() then rows, footer = UI.LedgerRows(ledgerView, ledgerFilter) end
	ledgerOffset = math.max(0, math.min(ledgerOffset, #rows - #p.rows))
	for i, r in ipairs(p.rows) do
		local data = rows[i + ledgerOffset]
		for j, cell in ipairs(r) do
			local c = v.cols[j]
			cell:ClearAllPoints()
			if c and data then
				cell:SetPoint("TOPLEFT", x0 + c[2], -52 - (i - 1) * 18)
				cell:SetWidth(c[3])
				cell:SetJustifyH(j == 1 and "LEFT" or "RIGHT")
				cell:SetText(tostring(data[j] or ""))
			else
				cell:SetText("")
			end
		end
	end
	p.footer:SetText(CH.Ledger.Available() and footer or CH.Theme.Color("muted", "Needs TradeSkillMaster."))
	return rows
end

function UI.Refresh()
	if not frame then return end
	for k, p in pairs(pages) do p:SetShown(k == page) end
	for k, b in pairs(pageButtons) do colorButton(b, k == page) end
	if CH.Ledger and CH.Ledger.Available() then frame.gold:SetText(CH.FormatMoney(CH.Ledger.Gold())) end
	frame.foot:SetText(CH.Theme.Color("muted", "/ch scan, /ch paths, /ch queue, /ch results open the crafting tabs.  /ch help for more.")
		.. "   " .. CH.Theme.Color("accent", "All trades settled in gold."))
	if page == "dashboard" then return refreshDashboard()
	elseif page == "ledger" then return refreshLedger()
	else
		text:SetText(UI.BriefingText())
		text:GetParent():SetHeight(text:GetStringHeight() + 10)
	end
end

--- Show a page: "dashboard", "ledger" or "briefing".
function UI.Page(name)
	if not frame then build() end
	page = name or page
	if not frame:IsShown() then frame:Show() else UI.Refresh() end
	return UI.Refresh()
end

function UI.SetRange(r) range = r end

function UI.IsShown()
	return frame ~= nil and frame:IsShown()
end

function UI.Toggle()
	if not frame then build() end
	if frame:IsShown() then frame:Hide() else frame:Show() end
end
