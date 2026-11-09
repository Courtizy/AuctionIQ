-- AuctionIQ main window, opened with /aiq or from the addon compartment, like TSM's.
local _, CH = ...

local UI = {}
CH.UI = UI
local frame, text
local W, H = 920, 600
local pages, pageButtons = {}, {}
local page = "today"
local range = "1M"
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

-- Concentration, best crafts and buy-instead-of-craft: the Report's crafting part, also the
-- Crafting tab's summary.
local function craftSections(out, chars, now)
	local T = CH.Theme
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

	local buys = {}
	for _, c in ipairs(chars) do
		for _, p in pairs(c.professions or {}) do
			for _, r in ipairs(p.scan and p.scan.rows or {}) do
				local bc = CH.Scan and CH.Scan.BuyOrCraft(r)
				if bc and bc.save and bc.save > 0 then table.insert(buys, { r = r, bc = bc }) end
			end
		end
	end
	if #buys > 0 then
		table.sort(buys, function(a, b) return a.bc.save > b.bc.save end)
		table.insert(out, "")
		table.insert(out, T.Color("accent", "Buy instead of craft") .. T.Color("muted", "  the cheapest listing is under your crafting cost"))
		for i, b in ipairs(buys) do
			if i > 4 then break end
			table.insert(out, string.format("   %s  buy %s, costs %s to make", b.r.name or "?", CH.FormatMoney(b.bc.buy), CH.FormatMoney(b.bc.craft)))
		end
	end

end

--- The Crafting tab's summary text.
function UI.CraftingText(now)
	local out = {}
	craftSections(out, sortedCharacters(), now or time())
	while out[1] == "" do table.remove(out, 1) end
	return table.concat(out, "\n")
end

--- The briefing as text: gold, Concentration, best crafts. Also used by the tests.
function UI.BriefingText(now)
	now = now or time()
	local chars, out = sortedCharacters(), {}
	local T = CH.Theme
	local function item(id) return CH.LedgerUI and CH.LedgerUI.ItemText(id) or ("item " .. id) end
	if CH.Ledger and CH.Ledger.Available() then
		local ok, r = pcall(CH.Ledger.Report, now)
		if ok and r then
			table.insert(out, T.Color("accent", "Last 24 hours") .. T.Color("muted", "  from TSM's accounting"))
			table.insert(out, string.format("   Sold %d for %s, bought %d for %s, cash %s", r.sold, CH.FormatMoney(r.earned), r.bought,
				CH.FormatMoney(r.spent), T.Color(r.earned - r.spent >= 0 and "ok" or "bad", CH.FormatMoney(r.earned - r.spent))))
			local mailGold = CH.Mail and CH.Mail.WaitingAll() or 0
			if mailGold > 0 then
				local _, by = CH.Mail.WaitingAll()
				local parts = {}
				for name, g in pairs(by) do table.insert(parts, name .. " " .. CH.FormatMoney(g)) end
				table.sort(parts)
				table.insert(out, "   Waiting in mail " .. CH.FormatMoney(mailGold) .. T.Color("muted", "  " .. table.concat(parts, ", ")))
			end
			if r.worth then
				local tk = CH.Alerts and CH.Alerts.InTokens(math.abs(r.worth))
				table.insert(out, "   Net worth (gold + stock) " .. T.Color(r.worth >= 0 and "ok" or "bad", (r.worth > 0 and "+" or "") .. CH.FormatMoney(r.worth))
					.. (tk and T.Color("muted", "  (" .. tk .. ")") or ""))
			end
			for _, t in ipairs(r.top) do table.insert(out, "   " .. item(t.id) .. "  " .. CH.FormatMoney(t.gold)) end
			local below = CH.Par and CH.Par.List(now) or {}
			table.sort(below, function(a, b) return a.value > b.value end)
			local nShort = 0
			for _, e in ipairs(below) do if e.short > 0 then nShort = nShort + 1 end end
			if nShort > 0 then
				table.insert(out, "")
				table.insert(out, T.Color("accent", "Below stock target") .. T.Color("muted", "  " .. nShort .. " items; the Queue's Fill crafts up to target"))
				local shown = 0
				for _, e in ipairs(below) do
					if e.short > 0 and shown < 6 then
						shown = shown + 1
						table.insert(out, string.format("   %s  %d of %d, short %d", item(e.id), e.held, e.target, e.short))
					end
				end
			end
			local hour, wday = tonumber(date("%H", now)), tonumber(date("%w", now)) + 1
			local postNow = {}
			for _, e in ipairs(CH.Ledger.SaleTimes(now - 30 * 86400)) do
				local ahead = (e.bestHour - hour) % 24
				if e.sold >= 3 and e.share >= 0.4 and ahead <= 3 then table.insert(postNow, e) end
			end
			table.sort(postNow, function(a, b) return a.gold > b.gold end)
			if #postNow > 0 then
				table.insert(out, "")
				table.insert(out, T.Color("accent", "Post now") .. T.Color("muted", "  their best selling hours start soon"))
				for i, e in ipairs(postNow) do
					if i > 5 then break end
					table.insert(out, string.format("   %s  %d%% of sales from %02d:00", item(e.id), math.floor(e.share * 100 + 0.5), e.bestHour))
				end
			end
			if #r.restock > 0 then
				table.insert(out, "")
				table.insert(out, T.Color("accent", "Restock") .. T.Color("muted", "  sold this week, none left on any character"))
				for _, e in ipairs(r.restock) do
					table.insert(out, string.format("   %s  %d sold, %s", item(e.id), e.sold, CH.FormatMoney(e.gold)))
				end
			end
			if #r.expired > 0 or #r.stale > 0 then
				table.insert(out, "")
				table.insert(out, T.Color("accent", "Came back unsold"))
				for i, e in ipairs(r.expired) do
					if i > 5 then break end
					table.insert(out, string.format("   %s  x%d  %s", item(e.id), e.n, T.Color("muted", "repost it")))
				end
				for i, e in ipairs(r.stale) do
					if i > 4 then break end
					table.insert(out, string.format("   %s  %s", item(e.id),
						T.Color("bad", e.times .. " expiries in 2 weeks: cut the price, vendor it or stop making it")))
				end
			end
			table.insert(out, "")
		end
	end
	local total = 0
	for _, c in ipairs(chars) do total = total + (c.gold or 0) end
	table.insert(out, CH.Theme.Color("accent", "Gold") .. "  " .. CH.FormatMoney(total) .. " across " .. #chars .. " characters")
	for _, c in ipairs(chars) do
		table.insert(out, "   " .. classColor(c.class) .. (c.name or c.key) .. "|r  " .. CH.FormatMoney(c.gold or 0))
	end

	craftSections(out, chars, now)

	if CH.Planner then
		local up = CH.Planner.Upcoming(now, 7)
		if #up > 0 then
			table.insert(out, "")
			table.insert(out, T.Color("accent", "Coming up"))
			for i, e in ipairs(up) do
				if i > 4 then break end
				table.insert(out, "   " .. e.date:sub(6) .. "  " .. e.name .. (e.hint and T.Color("muted", "  " .. e.hint) or ""))
			end
		end
		local left = 0
		for _, k in ipairs(CH.Planner.Knowledge(now)) do for _, t in ipairs(k.tasks) do if not t.done then left = left + 1 end end end
		if left > 0 then
			table.insert(out, "")
			table.insert(out, T.Color("accent", "Knowledge") .. "  " .. left .. " weekly sources not ticked yet " .. T.Color("muted", "(Plan page)"))
		end
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

local function itemName(id, fallback)
	local n = id and C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
	return n or fallback or (id and ("item " .. id)) or "?"
end

local function when(t)
	return date and date("%b %d %H:%M", t) or tostring(t)
end

--- Ledger rows for a view (see LedgerUI.Rows), for tests and older callers.
function UI.LedgerRows(view, filter)
	return CH.LedgerUI.Rows(view, { filter = filter })
end

-- Building ------------------------------------------------------------------------------------
local CARDS = 6 -- Do next cards: two columns of three

local function buildDashboard(p)
	local T = CH.Theme
	local d = {}
	pages.dashboard = p
	p.d = d
	local PW = W - 24
	-- Do next, the page's main block: what to do now, each card with a button that does it
	local top = panel(p, 0, 0, PW, 200)
	d.top = top
	d.heading = fs(top, 10, -8, 400, "LEFT", "GameFontNormal")
	d.mode = "next"
	d.modeButtons = {}
	for i, m in ipairs({ { "next", "Do next" }, { "activity", "Activity" } }) do
		local b = T.Button(top, m[2], 80, 18)
		b:SetPoint("TOPRIGHT", -8 - (2 - i) * 84, -6)
		b:SetScript("OnClick", function() d.mode, d.logOffset = m[1], 0; UI.Refresh() end)
		d.modeButtons[m[1]] = b
	end
	d.cards = {}
	local CW = math.floor((PW - 24) / 2)
	for i = 1, CARDS do
		local c = {}
		local x = 8 + ((i - 1) % 2) * (CW + 8)
		local y = -32 - math.floor((i - 1) / 2) * 56
		c.bg = panel(top, x, y, CW, 52)
		c.who = fs(top, x + 8, y - 6, CW - 200)
		c.time = fs(top, x + CW - 196, y - 6, 100, "RIGHT")
		c.l1 = fs(top, x + 8, y - 22, CW - 104)
		if c.l1.SetMaxLines then c.l1:SetWordWrap(true); c.l1:SetMaxLines(2) end
		c.l2 = fs(top, x + 8, y - 36, CW - 104)
		c.l3 = fs(top, x + CW - 92, y - 22, 84, "RIGHT")
		-- the card opens where the work is; its button does the work
		c.hit = CreateFrame("Button", nil, top)
		c.hit:SetPoint("TOPLEFT", x, y)
		c.hit:SetSize(CW - 96, 52)
		c.hit:SetScript("OnClick", function(self) if self.go then UI.Go(self.go[1], self.go[2]) end end)
		c.hit:SetScript("OnEnter", function(self)
			local lines = {}
			for _, f in ipairs({ c.who, c.l1, c.l2 }) do
				local s = f:GetText()
				if type(s) == "string" and s ~= "" then table.insert(lines, { s }) end
			end
			if self.go then table.insert(lines, { CH.Theme.Color("muted", "Click to see the details.") }) end
			if #lines > 0 then CH.Window.Tooltip(self, lines) end
		end)
		c.hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
		c.act = T.Button(top, "", 84, 22)
		c.act:SetPoint("TOPLEFT", x + CW - 92, y - 15)
		c.act:SetScript("OnClick", function(self)
			if not self.run then return end
			local ok, msg = self.run()
			-- what happened stays on the card (by its title), not only in chat
			if self.key and msg then d.acted[self.key] = { ok = ok ~= false, msg = msg } end
			UI.Refresh()
		end)
		c.act:Hide()
		d.cards[i] = c
	end
	d.logOffset = 0
	d.acted = {} -- [card title] = { ok, msg } after its button was pressed
	top:EnableMouseWheel(true)
	top:SetScript("OnMouseWheel", function(_, delta) d.logOffset = math.max(0, d.logOffset - delta * 2); UI.Refresh() end)

	-- gold: the chart and its stats on the left, sales and expenses on the right
	local y0 = -210
	local cw = 560
	d.title = fs(p, 0, y0 - 2, 200, "LEFT", "GameFontNormalLarge")
	d.sub = fs(p, 0, y0 - 24, cw, "LEFT")
	d.rangeButtons = {}
	local bx = cw
	for i = #RANGES, 1, -1 do
		local r = RANGES[i]
		local b = T.Button(p, r[1], 36, 18)
		b:SetPoint("TOPRIGHT", p, "TOPLEFT", bx, y0 - 2)
		b:SetScript("OnClick", function() range = r[1]; UI.Refresh() end)
		d.rangeButtons[r[1]] = b
		bx = bx - 40
	end
	-- who counts: each character and the warband bank can be switched off
	local who = T.Button(p, "Characters", 84, 18)
	who:SetPoint("TOPRIGHT", p, "TOPLEFT", bx - 4, y0 - 2)
	who:SetScript("OnClick", function(self) UI.CharacterMenu(self) end)
	who:SetScript("OnEnter", function(self) CH.Window.Tooltip(self, { { "Pick which characters (and the warband bank) count in the gold." } }) end)
	who:SetScript("OnLeave", function() GameTooltip:Hide() end)
	d.who = who
	local chart = panel(p, 0, y0 - 44, cw, 190)
	d.chart = chart
	-- hover: a marker on the nearest point and a tooltip with who held what
	local mark = chart:CreateTexture(nil, "OVERLAY")
	mark:SetColorTexture(T.fg[1], T.fg[2], T.fg[3], 1)
	mark:SetSize(7, 7)
	mark:Hide()
	local vline = chart:CreateTexture(nil, "ARTWORK")
	vline:SetColorTexture(T.muted[1], T.muted[2], T.muted[3], 0.5)
	vline:SetWidth(1)
	vline:Hide()
	d.mark, d.vline = mark, vline
	local hover = CreateFrame("Frame", nil, chart)
	hover:SetAllPoints()
	hover:EnableMouse(true)
	hover:SetScript("OnEnter", function(self)
		self:SetScript("OnUpdate", function(f)
			local left = f.GetLeft and f:GetLeft()
			if not left or not GetCursorPosition then return end
			local x = GetCursorPosition() / (f:GetEffectiveScale() or 1) - left
			UI.ChartHover(x)
		end)
	end)
	hover:SetScript("OnLeave", function(self)
		self:SetScript("OnUpdate", nil)
		mark:Hide(); vline:Hide(); GameTooltip:Hide()
		d.hoverIndex = nil
	end)
	d.grid, d.gridLabels, d.lines, d.xLabels = {}, {}, {}, {}
	for i = 1, 5 do
		local g = chart:CreateTexture(nil, "BACKGROUND")
		g:SetColorTexture(T.line[1], T.line[2], T.line[3], 1)
		g:SetHeight(1)
		d.grid[i] = g
		d.gridLabels[i] = fs(chart, 4, 0, 56, "RIGHT", "GameFontDisableSmall")
	end
	for i = 1, 5 do d.xLabels[i] = fs(chart, 0, -174, 80, "CENTER", "GameFontDisableSmall") end

	-- stat row under the chart
	d.stats = {}
	local labels = { { "52W HIGH", "high" }, { "AVG DAILY SALES", "avgSold" }, { "TOP SALE", "topSale" },
		{ "52W LOW", "low" }, { "DAILY CHANGE", "dailyChange" }, { "TOP PURCHASE", "topBuy" } }
	for i, l in ipairs(labels) do
		local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
		local lab = fs(p, col * 188, y0 - 242 - row * 18, 104, "LEFT", "GameFontNormalSmall")
		lab:SetText(l[1])
		d.stats[l[2]] = fs(p, col * 188 + 104, y0 - 242 - row * 18, 80, "RIGHT")
	end

	-- sales / expenses / profit
	local bw = PW - cw - 12
	local box = panel(p, cw + 12, y0, bw, H - 70 + y0)
	d.box = {}
	local y = -10
	local function section(title)
		local h = fs(box, 10, y, 200, "LEFT", "GameFontNormal")
		h:SetText(title)
		y = y - 18
	end
	local function line(key, label)
		local a = fs(box, 10, y, 150)
		a:SetText(label)
		d.box[key] = fs(box, bw - 170, y, 160, "RIGHT")
		y = y - 15
	end
	section("SALES")
	line("earned", "Total earned")
	line("avgEarned", "Average a day")
	line("topItem", "Top item")
	y = y - 4
	section("EXPENSES")
	line("spent", "Total spent")
	line("avgSpent", "Average a day")
	line("topSpent", "Top item")
	y = y - 4
	section("PROFIT")
	line("cash", "Cash profit")
	line("worth", "Net worth change")
	d.note = fs(box, 10, y - 4, bw - 20, "LEFT", "GameFontDisableSmall")
end

local function buildLedger(p)
	pages.ledger = p
	CH.LedgerUI.Build(p, fs, panel)
end

local function buildBriefing(p)
	local T = CH.Theme
	pages.briefing = p
	CH.ReportUI.Build(p, fs, panel)
	local scroll = CreateFrame("ScrollFrame", nil, p)
	scroll:SetPoint("TOPLEFT", 4, -176)
	local RW = W - 24 - 172 - 16 -- the Report sits in the Clearinghouse tab, right of its nav
	scroll:SetPoint("BOTTOMRIGHT", -4, 0)
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local y = math.max(0, math.min(self:GetVerticalScrollRange(), self:GetVerticalScroll() - delta * 40))
		self:SetVerticalScroll(y)
	end)
	local child = CreateFrame("Frame", nil, scroll)
	child:SetSize(RW, 10)
	scroll:SetScrollChild(child)
	text = child:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	text:SetPoint("TOPLEFT")
	text:SetWidth(RW)
	text:SetJustifyH("LEFT")
	text:SetSpacing(4)
	text:SetTextColor(T.fg[1], T.fg[2], T.fg[3])
end

local TABS = { { "today", "Today" }, { "markets", "Markets" }, { "crafting", "Crafting" }, { "trading", "Trading" },
	{ "analytics", "Analytics" }, { "ledger", "Clearinghouse" } }
-- which page frame each tab shows; Markets, Analytics and the Clearinghouse share the table page
local FRAME = { today = "dashboard", markets = "ledger", crafting = "plan", trading = "ledger", analytics = "ledger", ledger = "ledger",
	settings = "settings" }
-- old page names (commands, other modules) and where they live now
-- Settings has a second view, Groups and items (the group tree, items and routes)
local settingsView = "main"
local function frameOf(pg)
	if pg == "settings" and settingsView == "groups" then return "groups" end
	return FRAME[pg]
end
local OLD = { dashboard = { "today" }, groups = { "settings", "groups" }, plan = { "crafting" }, briefing = { "ledger", "report" }, report = { "ledger", "report" } }

--- Lay the tabs out from their real text widths (fonts differ under ElvUI and ToxiUI), starting
--- after the widest title so a title change never pushes into them.
local function layoutTabs()
	local title = frame.title
	local keep = title:GetText()
	local widest = 0
	for _, t in ipairs({ CH.Theme.Color("accent", "AuctionIQ"), CH.Theme.Color("accent", "Clearinghouse") }) do
		title:SetText(t)
		widest = math.max(widest, title:GetStringWidth() or 0)
	end
	title:SetText(keep)
	local x = (title:GetLeft() and frame.bar:GetLeft()) and (title:GetLeft() - frame.bar:GetLeft()) or 32
	x = x + widest + 18
	for _, pg in ipairs(TABS) do
		local b = pageButtons[pg[1]]
		local f = b.text or (b.GetFontString and b:GetFontString())
		local w = math.max(64, math.ceil((f and f:GetStringWidth() or 60) + 22))
		b:SetWidth(w)
		b:ClearAllPoints()
		b:SetPoint("LEFT", frame.bar, "LEFT", x, 0)
		x = x + w + 4
	end
end

local function build()
	local T = CH.Theme
	frame = CH.Window.New("ClearinghouseFrame", "", W, H)
	frame.title:SetText(T.Color("accent", "AuctionIQ"))
	frame.TitleText = frame.title
	-- AuctionIQ's pages first, then its Clearinghouse ledger last
	for _, pg in ipairs(TABS) do
		local b = T.Button(frame.bar, pg[2], 84, 20)
		b:SetScript("OnClick", function() UI.Go(pg[1]) end)
		pageButtons[pg[1]] = b
	end
	local settings = T.Button(frame.bar, "Settings", 70, 20)
	settings:SetPoint("RIGHT", frame.close, "LEFT", -6, 0)
	settings:SetScript("OnClick", function() UI.Go(page == "settings" and "today" or "settings") end)
	pageButtons.settings = settings
	frame.gold = frame.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	frame.gold:SetPoint("RIGHT", settings, "LEFT", -10, 0)
	local function buildGroups(p) pages.groups = p; CH.GroupsUI.Build(p, fs, panel) end
	local function buildPlan(p) pages.plan = p; CH.PlanUI.Build(p, fs, panel) end
	local function buildSettings(p) pages.settings = p; CH.SettingsUI.Build(p, fs, panel) end
	for _, b in ipairs({ buildDashboard, buildLedger, buildGroups, buildPlan, buildBriefing, buildSettings }) do
		local p = CreateFrame("Frame", nil, frame)
		p:SetPoint("TOPLEFT", 12, -36)
		p:SetSize(W - 24, H - 48)
		if b == buildBriefing then
			p:ClearAllPoints()
			p:SetPoint("TOPLEFT", 12 + 172, -36)
			p:SetSize(W - 24 - 172, H - 48)
		end
		b(p)
	end
	frame.foot = fs(frame, 12, -H + 18, W - 24, "LEFT", "GameFontDisableSmall")
	frame:SetScript("OnShow", function()
		if CH.Par then CH.Par.Refresh() end
		if CH.Ledger.Available() then pcall(CH.Ledger.Archive); pcall(CH.Ledger.Snapshot) end
		UI.Refresh()
	end)
	T.Fonts(frame)
	layoutTabs()
end

-- Drawing -------------------------------------------------------------------------------------
local function drawChart(d, data)
	local chart = d.chart
	local cw, ch = chart:GetWidth() or 560, (chart:GetHeight() or 210) - 40
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
	d.px, d.series, d.chartTop, d.chartH = px, series, top, ch
	return px
end

--- The chart point nearest x (pixels from the chart's left): shows the marker and a tooltip.
--- Returns the point, for tests.
function UI.ChartHover(x)
	local d = pages.dashboard and pages.dashboard.d
	if not d or not d.px or #d.px == 0 then return nil end
	local best, bestD
	for i, p in ipairs(d.px) do
		local dist = math.abs(p[1] - x)
		if not bestD or dist < bestD then best, bestD = i, dist end
	end
	local pt, p = d.series[best], d.px[best]
	if d.hoverIndex ~= best then
		d.hoverIndex = best
		d.mark:ClearAllPoints()
		d.mark:SetPoint("CENTER", d.chart, "TOPLEFT", p[1], p[2])
		d.mark:Show()
		d.vline:ClearAllPoints()
		d.vline:SetPoint("TOPLEFT", d.chart, "TOPLEFT", p[1], d.chartTop)
		d.vline:SetHeight(d.chartH)
		d.vline:Show()
		local T = CH.Theme
		local lines = { { date and date(range == "1D" and "%b %d %H:%M" or "%a %b %d, %Y", pt.t) or "", "" }, { "Total", CH.FormatMoney(pt.v) } }
		local by = {}
		for _, b in ipairs(pt.by or {}) do if b.v > 0 then table.insert(by, b) end end
		table.sort(by, function(a, b) return a.v > b.v end)
		for _, b in ipairs(by) do table.insert(lines, { "  " .. b.name, T.Color("muted", CH.FormatMoney(b.v)) }) end
		CH.Window.Tooltip(d.chart, lines)
	end
	return pt
end

--- The character picker: tick who counts in the gold. Without the game's menus, toggles name.
function UI.CharacterMenu(owner, name)
	local L = CH.Ledger
	if name then L.SetIncluded(name, not L.Included(name)); return UI.Refresh() end
	if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle("Count gold from")
		for _, h in ipairs(L.Holders()) do
			root:CreateCheckbox(h.name .. "  " .. CH.FormatMoney(h.money),
				function() return L.Included(h.name) end,
				function() L.SetIncluded(h.name, not L.Included(h.name)); UI.Refresh() end)
		end
		root:CreateDivider()
		root:CreateButton("Everyone", function()
			for _, h in ipairs(L.Holders()) do L.SetIncluded(h.name, true) end
			UI.Refresh()
		end)
	end)
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
	local holders, on = CH.Ledger.Holders(), 0
	for _, h in ipairs(holders) do if h.included then on = on + 1 end end
	local who = on == #holders and ("All characters on " .. (GetRealmName and GetRealmName() or "") .. " + warband bank")
		or string.format("%d of %d (characters + warband bank)", on, #holders)
	local tokens = CH.Alerts and CH.Alerts.InTokens(data.gold)
	d.sub:SetText(T.Color("muted", who .. ", now ") .. CH.FormatMoney(data.gold) .. (tokens and T.Color("muted", "  (" .. tokens .. ")") or ""))
	d.hoverIndex = nil
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
	d.note:SetText("Cash profit counts reagents as spent, like TSM.\nNet worth change counts stock you still hold.")
	-- left column: Do next, or the activity log
	for k, b in pairs(d.modeButtons) do colorButton(b, k == d.mode) end
	if d.mode == "next" then
		local list = CH.Next.List()
		d.logOffset = math.max(0, math.min(d.logOffset, #list - #d.cards))
		local urgent = 0
		for _, e in ipairs(list) do if e.tier == 1 then urgent = urgent + 1 end end
		d.heading:SetText("Do next" .. T.Color("muted", #list == 0 and "  nothing waiting"
			or string.format("  %d things, %d urgent%s", #list, urgent, #list > #d.cards and ", scroll for more" or "")))
		for i, c in ipairs(d.cards) do
			local e = list[i + d.logOffset]
			c.hit.go = e and e.go
			c.act.run = e and e.act and e.act.run
			c.act.key = e and e.title
			if e and e.act then setLabel(c.act, e.act.label); c.act:Show() else c.act:Hide() end
			if e then
				local did = d.acted[e.title]
				c.who:SetText(T.Color(e.tier == 1 and "accent" or "fg", e.title))
				c.time:SetText(e.gold and e.gold > 0 and money(e.gold) or "")
				c.l1:SetText(e.detail)
				-- after its button: one line of detail, then what happened (or why not)
				if c.l1.SetMaxLines then c.l1:SetMaxLines(did and 1 or 2) end
				c.l2:SetText(did and T.Color(did.ok and "ok" or "bad", (did.ok and "Done: " or "Not yet: ") .. did.msg) or "")
				c.l3:SetText((not e.act and e.go) and T.Color("muted", "click to open") or "")
			else
				c.who:SetText(i == 1 and T.Color("muted", "Nothing urgent. Nice.") or "")
				c.time:SetText(""); c.l1:SetText(""); c.l2:SetText(""); c.l3:SetText("")
			end
		end
	else
	d.heading:SetText("Activity" .. T.Color("muted", "  what sold, bought and expired, newest first"))
	for i, c in ipairs(d.cards) do
		c.hit.go = nil
		c.act.run = nil
		c.act:Hide()
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
	end
	return data
end

local function refreshLedger() return CH.LedgerUI.Refresh() end

function UI.Refresh()
	if not frame then return end
	-- the Clearinghouse tab is the ledger: plum and parchment; every other page is AuctionIQ navy
	local want = page == "ledger" and "clearinghouse" or "auctioniq"
	if CH.Theme.palette ~= want or frame.palette ~= want then
		CH.Theme.Use(want)
		CH.Theme.Repaint(frame)
		frame.palette = want
		frame.title:SetText(CH.Theme.Color("accent", want == "clearinghouse" and "Clearinghouse" or "AuctionIQ"))
	end
	if FRAME[page] == "ledger" then CH.LedgerUI.SetSection(page) end
	local report = page == "ledger" and CH.LedgerUI.View() == "report"
	for k, p in pairs(pages) do p:SetShown(k == frameOf(page) or (report and k == "briefing")) end
	for k, b in pairs(pageButtons) do colorButton(b, k == page) end
	if not frame.tabsLaid then frame.tabsLaid = true; layoutTabs() end -- again once fonts and positions are final
	if CH.Ledger and CH.Ledger.Available() then frame.gold:SetText(CH.FormatMoney(CH.Ledger.Gold())) end
	frame.foot:SetText(CH.Theme.Color("muted", "/aiq today, markets, crafting, trading, analytics, report.  /aiq help for more.")
		.. "   " .. CH.Theme.Color("accent", "All trades settled in gold."))
	if page == "today" then return refreshDashboard()
	elseif page == "crafting" then return CH.PlanUI.Refresh()
	elseif page == "settings" then return settingsView == "groups" and CH.GroupsUI.Refresh() or CH.SettingsUI.Refresh()
	elseif report then
		refreshLedger()
		CH.ReportUI.Refresh()
		text:SetText(UI.BriefingText())
		text:GetParent():SetHeight(text:GetStringHeight() + 10)
	else return refreshLedger() end
end

--- Open a tab, and optionally one of its views: UI.Go("analytics", "par").
local function choose(tab, view)
	if OLD[tab] then tab, view = OLD[tab][1], view or OLD[tab][2] end
	if not FRAME[tab] then return false end
	page = tab
	if tab == "settings" then settingsView = view == "groups" and "groups" or "main" end
	if view and FRAME[tab] == "ledger" then CH.LedgerUI.Set({ view = view }) end
	return true
end

function UI.Go(tab, view)
	if choose(tab, view) and frame then UI.Refresh() end
end

--- Show a tab: "today", "markets", "crafting", "trading", "analytics" or "ledger" (the
--- Clearinghouse). The old names (dashboard, groups, plan, briefing, report) still work.
function UI.Page(name, view)
	if not frame then build() end
	if name then choose(name, view) end
	-- one refresh: showing the frame refreshes it (OnShow), else refresh it here
	if not frame:IsShown() then frame:Show() else UI.Refresh() end
end

function UI.SetRange(r) range = r end

function UI.IsShown()
	return frame ~= nil and frame:IsShown()
end

function UI.Toggle()
	if not frame then build() end
	if frame:IsShown() then frame:Hide() else frame:Show() end
end
