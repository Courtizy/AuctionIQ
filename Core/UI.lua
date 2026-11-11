-- AuctionIQ main window, opened with /aiq or from the addon compartment, like TSM's.
local _, CH = ...

local UI = {}
CH.UI = UI
local frame, text
local W, H = 920, 600
local MIN_W, MAX_W, MIN_H, MAX_H = 920, 1800, 600, 1200 -- the corner grip resizes within these
local pages, pageButtons = {}, {}
local build -- the window, laid out for its size (below)
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
-- A tab or toggle: the active one in the accent with ToxiUI's 2px accent line under it.
-- white line icons in Media, tinted in the label: theme colour on the active tab, grey otherwise
local function iconText(name, c, label)
	local t = ("|TInterface\\AddOns\\AuctionIQ\\Media\\Tab-%s:14:14:0:0:64:64:0:64:0:64:%d:%d:%d|t"):format(
		name, math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
	return label and (t .. " " .. label) or t
end
UI.IconText = iconText

local function colorButton(b, on)
	local T = CH.Theme
	local f = b.text or (b.GetFontString and b:GetFontString())
	local c = on and T.accent or T.fg
	local icon = rawget(b, "aiqIcon")
	if icon then
		c = on and T.accent or T.muted
		b:SetText(iconText(icon, c, rawget(b, "aiqLabel")))
	end
	if f and f.SetTextColor then f:SetTextColor(c[1], c[2], c[3]) end
	local line = rawget(b, "aiqLine")
	if not line and b.CreateTexture then
		line = b:CreateTexture(nil, "OVERLAY")
		line:SetPoint("BOTTOMLEFT", 1, 1)
		line:SetPoint("BOTTOMRIGHT", -1, 1)
		line:SetHeight(2)
		b.aiqLine = line
	end
	if line then
		line:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 1)
		line:SetShown(on and true or false)
	end
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
	-- What changed explains the gold change with the Cash Flow statement for exactly this range and
	-- these characters, so the gold series and the ledger lines can't disagree on scope
	if CH.Statements and CH.Statements.Cash then
		local ok, c = pcall(CH.Statements.Cash, since, now)
		if ok and c and c.change then d.cash = c end
	end
	d.activity = L.Activity(40)
	return d
end

--- What changed over the range, explained: the change in gold (from TSM's gold log) and up to three
--- moves behind it, biggest first, each opening the Accounting lines behind it. Moves: sales, other
--- income, purchases, other expenses, stock (net worth change less the gold change, estimated) and
--- whatever the ledger can't explain (mail, bank and guild transfers). Returns { gold, moves = {
--- { key, label, gold, go = { tab, view }, tip } } } or nil without data.
function UI.WhatChanged(data)
	if not data or not data.series or not data.series[1] then return nil end
	local s = data.summary
	local c = data.cash
	local first, last = data.series[1].v, data.series[#data.series].v
	local gold = c and c.change or (last - first)
	local function name(id) local n = id and C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id); return n or (id and ("item " .. id)) end
	-- the same lines as the Cash Flow statement, over the same range and characters
	local sales = c and (c.inflows.auction + c.inflows.other) or s.sales
	local income = c and c.inflows.income or s.income
	local buys = c and -c.outflows.buys or s.buys
	local expense = c and -c.outflows.expenses or s.expense
	local moves = {
		{ key = "sales", label = "Sales", gold = sales, go = { "ledger", "sales" },
			tip = s.topItem and ("Top seller: " .. name(s.topItem) .. ", " .. CH.FormatMoney(s.topItemGold or 0)) or nil },
		{ key = "income", label = "Other income", gold = income, go = { "ledger", "income" }, tip = "Quest gold, vendor sales, and other gold TSM logged as income." },
		{ key = "buys", label = "Purchases", gold = -buys, go = { "ledger", "purchases" },
			tip = data.topSpentItem and ("Most spent on: " .. name(data.topSpentItem)) or nil },
		{ key = "expense", label = "Other expenses", gold = -expense, go = { "ledger", "expense" }, tip = "Repairs, deposits, postage, and other gold TSM logged as spent." },
	}
	-- what the gold log moved that the ledger doesn't explain: transfers and anything TSM didn't log
	local other = c and c.unclassified or (gold - s.cash)
	if math.abs(other) >= 10000 then
		table.insert(moves, { key = "other", label = "Unclassified gold movement", gold = other, go = { "ledger", "cashflow" },
			tip = "Gold that moved without a sale, purchase or expense behind it: mail, bank and guild transfers, and anything TSM didn't log." })
	end
	if data.worthChange then
		table.insert(moves, { key = "stock", label = "Stock (estimated)", gold = data.worthChange - gold, go = { "ledger", "inventory" },
			tip = "Net worth change less the change in gold: what you hold now against the start, at estimated value." })
	end
	local keep = {}
	for _, m in ipairs(moves) do if math.abs(m.gold or 0) >= 10000 then table.insert(keep, m) end end
	table.sort(keep, function(a, b) return math.abs(a.gold) > math.abs(b.gold) end)
	for i = #keep, 4, -1 do keep[i] = nil end
	return { gold = gold, moves = keep }
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
local CARDS = 4 -- Do next cards: two columns of two (the wheel scrolls to more)

local function buildDashboard(p)
	local T = CH.Theme
	local d = {}
	pages.dashboard = p
	p.d = d
	local PW = W - 24
	-- the figures across the top: gold, stock, queued work and Concentration, each opening its page
	d.figures = {}
	local FW = math.floor((PW - 3 * 8) / 4)
	for i, f in ipairs({ { "gold", "Available gold", { "ledger", "inventory" } }, { "stock", "Inventory value", { "ledger", "inventory" } },
		{ "queued", "Queued crafts", { "operations", "queue" } }, { "conc", "Full Concentration", { "operations", "professions" } } }) do
		local x = (i - 1) * (FW + 8)
		local box = panel(p, x, 0, FW, 46)
		local lab = fs(box, 10, -6, FW - 20, "LEFT", "GameFontNormalSmall")
		lab:SetText(f[2])
		local v = fs(box, 10, -22, FW - 20, "LEFT", "GameFontHighlightLarge")
		local sub = fs(box, 112, -7, FW - 122, "RIGHT", "GameFontDisableSmall")
		local hit = CreateFrame("Button", nil, box)
		hit:SetAllPoints(box)
		hit:SetScript("OnClick", function() UI.Go(f[3][1], f[3][2]) end)
		hit:SetScript("OnEnter", function(self) if self.tip then CH.Window.Tooltip(self, self.tip) end end)
		hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
		d.figures[f[1]] = { value = v, sub = sub, hit = hit }
	end
	-- Do next, the page's main block: what to do now, each card with a button that does it
	local top = panel(p, 0, -54, PW, 172)
	d.top = top
	-- Do next is the page's main block: the accent line along its top, like the Next Move cards
	d.topAccent = top:CreateTexture(nil, "OVERLAY")
	d.topAccent:SetPoint("TOPLEFT", 1, -1)
	d.topAccent:SetPoint("TOPRIGHT", -1, -1)
	d.topAccent:SetHeight(2)
	T.AccentTexture(d.topAccent)
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
		local y = -32 - math.floor((i - 1) / 2) * 68
		c.bg = panel(top, x, y, CW, 64)
		-- the text sits on the card itself: a card is a frame of its own, drawn over its parent's text
		c.who = fs(c.bg, 8, -6, CW - 200)
		c.time = fs(c.bg, CW - 196, -6, 100, "RIGHT")
		c.l1 = fs(c.bg, 8, -22, CW - 104)
		if c.l1.SetMaxLines then c.l1:SetWordWrap(true); c.l1:SetMaxLines(2) end
		c.l2 = fs(c.bg, 8, -48, CW - 104)
		c.l3 = fs(c.bg, CW - 92, -22, 84, "RIGHT")
		-- the card opens where the work is; its button does the work
		c.hit = CreateFrame("Button", nil, top)
		c.hit:SetPoint("TOPLEFT", x, y)
		c.hit:SetSize(CW - 96, 64)
		c.hit:SetScript("OnClick", function(self) if self.go then UI.Go(self.go[1], self.go[2], self.go[3]) end end)
		c.hit:SetScript("OnEnter", function(self)
			local lines = {}
			for _, f in ipairs({ c.who, c.l1, c.l2 }) do
				local s = f:GetText()
				if type(s) == "string" and s ~= "" then table.insert(lines, { s }) end
			end
			-- why, what it's worth, and what could make it wrong
			local e = self.entry
			if e and e.gold and e.gold > 0 then table.insert(lines, { "Expected benefit", CH.FormatMoney(e.gold) }) end
			if e and e.risk then table.insert(lines, { CH.Theme.Color("muted", "Biggest uncertainty: " .. e.risk) }) end
			if self.go then table.insert(lines, { CH.Theme.Color("muted", "Click to open it in " .. UI.PlaceName(self.go) .. ".") }) end
			if #lines > 0 then CH.Window.Tooltip(self, lines) end
		end)
		c.hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
		c.act = T.Primary(T.Button(top, "", 84, 22))
		c.act:SetPoint("TOPLEFT", x + CW - 92, y - 21)
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
	local y0 = -234
	local cw = math.floor(PW * 560 / 896) -- the chart takes the same share of a wider window
	local extra = H - 600 -- and the height a taller one adds
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
	local chart = panel(p, 0, y0 - 44, cw, 166 + extra)
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
	for i = 1, 5 do d.xLabels[i] = fs(chart, 0, -150 - extra, 80, "CENTER", "GameFontDisableSmall") end

	-- stat row under the chart
	d.stats = {}
	local labels = { { "52W HIGH", "high" }, { "AVG DAILY SALES", "avgSold" }, { "TOP SALE", "topSale" },
		{ "52W LOW", "low" }, { "DAILY CHANGE", "dailyChange" }, { "TOP PURCHASE", "topBuy" } }
	for i, l in ipairs(labels) do
		local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
		local sx = math.floor(col * cw / 3)
		local lab = fs(p, sx, y0 - 218 - extra - row * 18, 104, "LEFT", "GameFontNormalSmall")
		lab:SetText(l[1])
		d.stats[l[2]] = fs(p, sx + 104, y0 - 218 - extra - row * 18, math.floor(cw / 3) - 108, "RIGHT")
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
	-- what changed, beside the gold trend: the change in gold and the three moves behind it
	section("WHAT CHANGED")
	d.changed = { head = fs(box, 10, y, bw - 20), rows = {} }
	y = y - 16
	for k = 1, 3 do
		local r = { label = fs(box, 18, y, bw - 130), value = fs(box, bw - 120, y, 110, "RIGHT") }
		local hit = CreateFrame("Button", nil, box)
		hit:SetPoint("TOPLEFT", 6, y + 2)
		hit:SetSize(bw - 12, 15)
		hit:SetScript("OnClick", function(self) if self.go then UI.Go(self.go[1], self.go[2]) end end)
		hit:SetScript("OnEnter", function(self)
			if not self.move then return end
			local lines = { { self.move.label, CH.FormatMoney(self.move.gold) } }
			if self.move.tip then table.insert(lines, { CH.Theme.Color("muted", self.move.tip) }) end
			table.insert(lines, { CH.Theme.Color("muted", "Click to see the lines behind it in " .. UI.PlaceName(self.go) .. ".") })
			CH.Window.Tooltip(self, lines)
		end)
		hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
		r.hit = hit
		d.changed.rows[k] = r
		y = y - 15
	end
	y = y - 4
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
	local RW = W - 24 - 172 - 16 -- the Report sits in the Accounting tab, right of its nav
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

-- Three tabs, each answering one question. Dashboard: what should I do next? Operations: what should
-- I craft, buy or post (Craft, Trade, Queue)? Accounting: what happened, and what should
-- I learn from it (Overview, Revenue, Expenses, Profit, Performance)? The AH, profession and mailbox
-- windows carry out what Operations plans.
local TABS = { { "today", "Dashboard" }, { "operations", "Operations" }, { "ledger", "Accounting" } }
-- which page frame each tab shows; Operations and Accounting share the table page
local FRAME = { today = "dashboard", operations = "ledger", ledger = "ledger", settings = "settings" }
-- Settings has a second view, Groups and items (the group tree, items and routes)
local settingsView = "main"
local function frameOf(pg)
	if pg == "settings" and settingsView == "groups" then return "groups" end
	return FRAME[pg]
end
UI.TABS = TABS

--- Where a { tab, view } opens, in words: "Operations > Craft".
function UI.PlaceName(go)
	local tabName
	for _, t in ipairs(TABS) do if t[1] == go[1] then tabName = t[2] end end
	local def = go[2] and CH.LedgerUI and CH.LedgerUI.ViewDef(go[2])
	local sec = go[2] and CH.LedgerUI and CH.LedgerUI.SectionOf(go[2])
	if sec == "operations" then tabName = "Operations" elseif sec == "ledger" then tabName = "Accounting" end
	local group = def and def.parent
	return (tabName or "AuctionIQ") .. (group and (" > " .. group) or "")
end

--- The window title: AuctionIQ, on every tab.
local function titleText()
	return CH.Theme.Wordmark() -- the icon is the title bar's badge, beside it
end
UI.TitleText = titleText

--- Lay the tabs out from their real text widths (fonts differ under ElvUI and ToxiUI), starting
--- after the widest title so a title change never pushes into them.
local function layoutTabs()
	local title = frame.title
	local keep = title:GetText()
	local widest = 0
	for _, t in ipairs({ titleText() }) do
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

--- A grip in the window's bottom-right corner. Drag it down or up to make the window taller or
--- shorter: tables and lists show more rows. Shift-drag scales the whole window instead. Both are
--- saved; double-click puts them back.
local MIN_SCALE, MAX_SCALE = 0.6, 1.6
local function settings()
	CH.db.settings.window = CH.db.settings.window or {}
	return CH.db.settings.window
end

-- keep the top-left corner where it is while the window changes
local function pin(old, new)
	local left, top = frame:GetLeft(), frame:GetTop()
	if left and top then
		frame:ClearAllPoints()
		frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * old / new, top * old / new)
	end
end

function UI.SetScale(scale)
	scale = math.max(MIN_SCALE, math.min(MAX_SCALE, scale or 1))
	settings().scale = scale
	if frame then
		local old = frame:GetScale() or 1
		local new = CH.Window.PixelScale() * scale -- whole screen pixels per unit at size 1
		pin(old, new)
		CH.Window.Pixel(frame, scale)
	end
	return scale
end

--- Resize the window to w by h (920 to 1800 wide, 600 to 1200 tall, and within the screen). Every
--- page is laid out again for the new size. Returns the size.
function UI.SetSize(w, h)
	local sw = UIParent.GetWidth and UIParent:GetWidth()
	local sh = UIParent.GetHeight and UIParent:GetHeight()
	local sc = frame and frame:GetScale() or 1
	local maxW = (type(sw) == "number" and sw > 0) and math.min(MAX_W, math.floor(sw / sc) - 20) or MAX_W
	local maxH = (type(sh) == "number" and sh > 0) and math.min(MAX_H, math.floor(sh / sc) - 20) or MAX_H
	W = math.floor(math.max(MIN_W, math.min(math.max(MIN_W, maxW), w or W)))
	H = math.floor(math.max(MIN_H, math.min(math.max(MIN_H, maxH), h or H)))
	settings().width, settings().height = W, H
	UI.Rebuild()
	return W, H
end

function UI.SetHeight(h) local _, nh = UI.SetSize(W, h); return nh end
function UI.Size() return W, H end
function UI.Height() return H end

--- Build the window again at the current size, on the same page, in the same place.
function UI.Rebuild()
	if not frame then return end
	local old = frame
	local shown = old:IsShown()
	local left, top = old:GetLeft(), old:GetTop()
	old:SetScript("OnShow", nil)
	old:Hide()
	pages, pageButtons = {}, {}
	build()
	if left and top then
		frame:ClearAllPoints()
		frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
	end
	if shown then frame:Show() end
end

function UI.AddSizer(f)
	local grip = CreateFrame("Button", nil, f)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -2, 2)
	grip:SetFrameLevel((f:GetFrameLevel() or 1) + 10)
	if grip.SetNormalTexture then
		grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
		grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
		grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	end
	grip:SetScript("OnMouseDown", function(self)
		local x, y = GetCursorPosition()
		self.fromX, self.fromY, self.fromScale, self.fromW, self.fromH = x, y, settings().scale or 1, W, H
		self.fromPx = f:GetEffectiveScale() or 1 -- screen pixels per window unit, as the drag starts
		self.scaling = IsShiftKeyDown and IsShiftKeyDown()
		self:SetScript("OnUpdate", function(g)
			local cx, cy = GetCursorPosition()
			local px = g.fromPx
			if g.scaling then
				UI.SetScale(g.fromScale * (1 + (cx - g.fromX) / px / W))
			else
				-- the outline follows the cursor; the pages are laid out again on release
				g.toW = math.max(MIN_W, math.min(MAX_W, g.fromW + (cx - g.fromX) / px))
				g.toH = math.max(MIN_H, math.min(MAX_H, g.fromH + (g.fromY - cy) / px))
				f:SetSize(g.toW, g.toH)
			end
		end)
	end)
	grip:SetScript("OnMouseUp", function(self)
		self:SetScript("OnUpdate", nil)
		if not self.scaling and self.toW then UI.SetSize(self.toW, self.toH); self.toW = nil end
	end)
	grip:SetScript("OnDoubleClick", function() UI.SetScale(1); UI.SetSize(MIN_W, MIN_H) end)
	grip:SetScript("OnEnter", function(self) CH.Window.Tooltip(self, { { "Drag to resize the window. Shift-drag to make everything bigger or smaller. Double-click for the normal size." } }) end)
	grip:SetScript("OnLeave", function() GameTooltip:Hide() end)
	f.sizer = grip
	local saved = CH.db and CH.db.settings.window
	CH.Window.Pixel(f, saved and saved.scale or 1)
	return grip
end

function build()
	local T = CH.Theme
	local saved = CH.db and CH.db.settings.window
	if saved then
		W = math.max(MIN_W, math.min(MAX_W, saved.width or W))
		H = math.max(MIN_H, math.min(MAX_H, saved.height or H))
	end
	frame = CH.Window.New("AuctionIQFrame", "", W, H)
	-- above the windows docked to the profession window (and other addons' crafting windows), and
	-- brought to the front when clicked
	frame:SetFrameStrata("DIALOG")
	if frame.SetToplevel then frame:SetToplevel(true) end
	UI.AddSizer(frame)
	frame.title:SetText(titleText())
	frame.TitleText = frame.title
	-- AuctionIQ's pages first, then its Accounting ledger last
	for _, pg in ipairs(TABS) do
		-- a small symbol before each name, the same size and style on every tab
		local b = T.Button(frame.bar, iconText(pg[2], T.muted, pg[2]), 84, 20)
		b.aiqIcon, b.aiqLabel = pg[2], pg[2]
		b:SetScript("OnClick", function() UI.Go(pg[1]) end)
		pageButtons[pg[1]] = b
	end
	-- sub-tabs under the tabs (Operations: Craft, Trade, Queue; Accounting: five)
	frame.subs = {}
	for i = 1, 6 do
		local b = T.Button(frame, "", 90, 20)
		b:SetScript("OnClick", function(self) if self.view then UI.Go(page, self.view) end end)
		b:Hide()
		frame.subs[i] = b
	end
	-- Settings is the gear alone, named in its tooltip
	local settings = T.Button(frame.bar, iconText("Settings", T.muted), 26, 20)
	settings.aiqIcon = "Settings"
	settings:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:AddLine("Settings")
		GameTooltip:Show()
	end)
	settings:HookScript("OnLeave", function() GameTooltip:Hide() end)
	settings:SetPoint("RIGHT", frame.close, "LEFT", -6, 0)
	settings:SetScript("OnClick", function() UI.Go(page == "settings" and "today" or "settings") end)
	pageButtons.settings = settings
	frame.gold = frame.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	frame.gold:SetPoint("RIGHT", settings, "LEFT", -10, 0)
	local function buildGroups(p) pages.groups = p; CH.GroupsUI.Build(p, fs, panel) end
	local function buildPlan(p) pages.plan = p; CH.PlanUI.Build(p, fs, panel) end
	local function buildPaths(p) pages.paths = p; CH.PathsUI.Build(p) end
	local function buildPerf(p) pages.perf = p; if CH.Performance then CH.Performance.Build(p, fs) end end
	local function buildSettings(p) pages.settings = p; CH.SettingsUI.Build(p, fs, panel) end
	for _, b in ipairs({ buildDashboard, buildLedger, buildGroups, buildPlan, buildPaths, buildBriefing, buildPerf, buildSettings }) do
		local p = CreateFrame("Frame", nil, frame)
		p:SetPoint("TOPLEFT", 12, -36)
		p:SetSize(W - 24, H - 48)
		-- the Report, Knowledge and Paths sit in a tab's table page, right of its nav
		if b == buildBriefing or b == buildPlan or b == buildPaths or b == buildPerf then
			p:ClearAllPoints()
			p:SetPoint("TOPLEFT", 12 + 172, -36)
			p:SetSize(W - 24 - 172, H - 48)
		end
		b(p)
	end
	frame.foot = fs(frame, 12, -H + 16, W - 40, "LEFT", "GameFontDisableSmall")
	frame.foot:ClearAllPoints()
	frame.foot:SetPoint("BOTTOMLEFT", 12, 8) -- stays at the bottom when the window is resized
	frame.foot:SetWidth(300)
	-- Concentration on the fullest characters, as class-gradient bars along the footer
	frame.conc = {}
	local prev
	for i = 3, 1, -1 do
		local s = CreateFrame("Frame", nil, frame)
		s:SetSize(170, 14)
		if prev then s:SetPoint("RIGHT", prev, "LEFT", -12, 0) else s:SetPoint("BOTTOMRIGHT", -28, 6) end
		s.name = CH.Window.OneLine(fs(s, 0, -1, 70, "RIGHT", "GameFontHighlightSmall"))
		s.back = s:CreateTexture(nil, "BACKGROUND")
		s.back:SetPoint("LEFT", 76, 0)
		s.back:SetSize(60, 6)
		s.back:SetColorTexture(0, 0, 0, 0.6)
		s.fill = s:CreateTexture(nil, "ARTWORK")
		s.fill:SetPoint("LEFT", s.back, "LEFT", 0, 0)
		s.fill:SetSize(60, 6)
		s.value = CH.Window.OneLine(fs(s, 140, -1, 30, "LEFT", "GameFontDisableSmall"))
		local hit = CreateFrame("Button", nil, s)
		hit:SetAllPoints(s)
		hit:SetScript("OnClick", function() UI.Go("operations", "professions") end)
		hit:SetScript("OnEnter", function(self) if s.tip then CH.Window.Tooltip(self, s.tip) end end)
		hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
		s:Hide()
		frame.conc[i] = s
		prev = s
	end
	frame:SetScript("OnShow", function(self)
		CH.Window.Snap(self)
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
		local y = math.floor(top - ch * frac + 0.5) -- on a whole pixel, so the gridlines stay crisp
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
		d.mark:SetPoint("CENTER", d.chart, "TOPLEFT", math.floor(p[1] + 0.5), math.floor(p[2] + 0.5))
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

--- The Dashboard's figures: gold, inventory value, queued crafts (ready, short of reagents, on
--- other characters) and how many professions sit at full Concentration.
function UI.DashboardFigures(now)
	now = now or time()
	local L = CH.Ledger
	local f = { queued = 0, ready = 0, short = 0, elsewhere = 0, conc = 0, concList = {} }
	if L and L.Available() then f.gold = L.Gold(); f.stock = L.InventoryValue() end
	local me = CH.CharacterKey and CH.CharacterKey()
	for _, x in ipairs(CH.TradingUI and CH.TradingUI.QueuePlan() or {}) do
		f.queued = f.queued + (x.e.qty or 0)
		if x.e.char ~= me then f.elsewhere = f.elsewhere + 1
		elseif x.status == "buy reagents" then f.short = f.short + 1
		else f.ready = f.ready + 1 end
	end
	for _, c in pairs(CH.db.characters or {}) do
		for _, pr in pairs(c.professions or {}) do
			local cur, max
			if CH.ConcentrationNow then cur, max = CH.ConcentrationNow(pr, now) end
			if cur and max and max > 0 and cur >= max then
				f.conc = f.conc + 1
				table.insert(f.concList, (c.name or "?") .. ": " .. (pr.name or "?"))
			end
		end
	end
	return f
end

--- Concentration on every character's professions, fullest first: { char, class, prof, cur, max,
--- hours (to full), best = { name, gain (gold per expected point over the plain craft) } }.
function UI.ConcentrationBars(now)
	now = now or time()
	local out = {}
	for key, c in pairs(CH.db.characters or {}) do
		for _, p in pairs(c.professions or {}) do
			local cur, max
			if CH.ConcentrationNow then cur, max = CH.ConcentrationNow(p, now) end
			if cur and max and max > 0 then
				local best
				for _, r in ipairs(p.scan and p.scan.rows or {}) do
					local g = CH.Scan and CH.Scan.GainPerPoint(r)
					if g and g > 0 and (not best or g > best.gain) then best = { name = r.name, gain = g } end
				end
				table.insert(out, { key = key, char = c.name or key, class = c.class, prof = p.name, cur = cur, max = max,
					hours = cur >= max and 0 or math.ceil((max - cur) / CH.CONC_PER_HOUR), best = best })
			end
		end
	end
	table.sort(out, function(a, b) if a.hours ~= b.hours then return a.hours < b.hours end return a.char < b.char end)
	return out
end

-- A bar drawn in text, for tooltips: filled share of `width` pixels in one colour, the rest in another.
local BAR = "|TInterface\\Buttons\\WHITE8X8:8:%d:0:0:8:8:0:8:0:8:%d:%d:%d|t"
local function textBar(share, width)
	local T = CH.Theme
	local on = math.max(0, math.min(width, math.floor(share * width + 0.5)))
	local function part(w, c) return w > 0 and string.format(BAR, w, math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255)) or "" end
	return part(on, T.accent) .. part(width - on, T.muted)
end
UI.TextBar = textBar

--- The footer's Concentration bars: the three fullest characters, each a class-gradient bar with
--- its points. Returns what it drew, for the tests: { { char, cur, max, share } }.
function UI.RenderConcFooter()
	local slots = frame and frame.conc
	local out = {}
	if not slots then return out end
	local T = CH.Theme
	local bars = UI.ConcentrationBars()
	for i, s in ipairs(slots) do
		local b = bars[i]
		s:SetShown(b ~= nil)
		if b then
			local share = math.max(0, math.min(1, b.cur / b.max))
			s.name:SetText(classColor(b.class) .. b.char .. "|r")
			T.Gradient(s.fill)
			s.fill:SetWidth(math.max(1, math.floor(60 * share + 0.5)))
			s.fill:SetShown(share > 0)
			s.value:SetText(b.cur >= b.max and T.Color("bad", tostring(b.cur)) or tostring(b.cur))
			s.tip = { { (b.char or "?") .. "  " .. T.Color("muted", b.prof or "") }, { string.format("%d/%d Concentration", b.cur, b.max) },
				{ b.hours == 0 and T.Color("bad", "Full: spend it before it's wasted.") or T.Color("muted", "Full in " .. b.hours .. "h.") } }
			table.insert(out, { char = b.char, cur = b.cur, max = b.max, share = share })
		end
	end
	return out
end

local function refreshFigures(d)
	local T = CH.Theme
	local f = UI.DashboardFigures()
	local F = d.figures
	F.gold.value:SetText(f.gold and CH.FormatMoney(f.gold) or T.Color("muted", "-"))
	F.gold.sub:SetText("")
	F.gold.hit.tip = { { "Gold on the characters you count, and the warband bank." }, { T.Color("muted", "Pick who counts with Characters, below.") } }
	F.stock.value:SetText(f.stock and CH.FormatMoney(f.stock) or T.Color("muted", "-"))
	F.stock.sub:SetText(T.Color("muted", "estimated"))
	F.stock.hit.tip = { { "What you hold, at market value. An estimate, not gold in hand." }, { T.Color("muted", "Click for the inventory records.") } }
	F.queued.value:SetText(tostring(f.queued))
	F.queued.sub:SetText(f.queued > 0 and (f.short > 0 and T.Color("bad", f.short .. " short") or T.Color("ok", f.ready .. " ready")) or "")
	F.queued.hit.tip = { { "Crafts in the queue on every character." },
		{ string.format("%d ready here, %d missing reagents, %d on other characters", f.ready, f.short, f.elsewhere) },
		{ T.Color("muted", "Click for the work queue in Operations.") } }
	F.conc.value:SetText(f.conc > 0 and T.Color("accent", f.conc) or "0")
	F.conc.sub:SetText(f.conc > 0 and T.Color("muted", "wasting") or T.Color("muted", "none full"))
	local tip = { { "Concentration by character, fullest first: who to log into first." } }
	for _, b in ipairs(UI.ConcentrationBars()) do
		table.insert(tip, { classColor(b.class) .. b.char .. "|r " .. T.Color("muted", b.prof or "?") .. "  " .. textBar(b.cur / b.max, 80),
			string.format("%d/%d  ", b.cur, b.max) .. (b.hours == 0 and T.Color("bad", "full") or T.Color("muted", "full in " .. b.hours .. "h")) })
		if b.best then
			table.insert(tip, { T.Color("muted", "   best: " .. (b.best.name or "?")), T.Color("ok", "+" .. CH.FormatMoney(b.best.gain)) .. T.Color("muted", " a point over plain") })
		end
	end
	if #tip == 1 then table.insert(tip, { T.Color("muted", "Open each character's professions once to see it here.") }) end
	F.conc.hit.tip = tip
	return f
end

local function refreshDashboard()
	local d = pages.dashboard.d
	local T = CH.Theme
	refreshFigures(d)
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
	local wch = UI.WhatChanged(data)
	d.changed.head:SetText(wch and ("Gold " .. T.Color(wch.gold >= 0 and "ok" or "bad", money(wch.gold, true)) .. T.Color("muted", " over the range")) or T.Color("muted", "No gold history yet."))
	for k, r in ipairs(d.changed.rows) do
		local m = wch and wch.moves[k]
		r.label:SetText(m and m.label or "")
		r.value:SetText(m and T.Color(m.gold >= 0 and "ok" or "bad", money(m.gold, true)) or "")
		r.hit.move, r.hit.go = m, m and m.go
		r.hit:SetShown(m ~= nil)
	end
	d.whatChanged = wch
	local wc = data.worthChange
	d.box.worth:SetText(wc and T.Color(wc >= 0 and "ok" or "bad", money(wc, true)) or T.Color("muted", "tracking from today"))
	d.note:SetText("Cash profit counts reagents as spent, like TSM.\nNet worth change counts stock you still hold.")
	-- left column: Do next, or the activity log
	for k, b in pairs(d.modeButtons) do colorButton(b, k == d.mode) end
	if d.mode == "next" then
		-- the few decisions that matter most, one card per kind of action: no list to scroll
		local list, all = CH.Next.Ranked(nil, #d.cards)
		d.logOffset = 0
		local urgent = 0
		for _, e in ipairs(list) do if e.tier == 1 then urgent = urgent + 1 end end
		d.heading:SetText("Do next" .. T.Color("muted", #list == 0 and "  nothing waiting"
			or string.format("  the %d that matter most%s", #list, all > #list and string.format(" (of %d)", all) or "")))
		for i, c in ipairs(d.cards) do
			local e = list[i + d.logOffset]
			c.hit.go = e and e.go
			c.hit.entry = e
			c.act.run = e and e.act and e.act.run
			c.act.key = e and e.title
			if e and e.act then setLabel(c.act, e.act.label); c.act:Show() else c.act:Hide() end
			if e then
				local did = d.acted[e.title]
				c.who:SetText(T.Color(e.tier == 1 and "accent" or "fg", e.title))
				c.time:SetText(e.gold and e.gold > 0 and money(e.gold) or "")
				c.l1:SetText(e.detail)
				-- after its button: one line of detail, then what happened (or why not)
				if c.l1.SetMaxLines then c.l1:SetMaxLines(2) end
				c.l2:SetText(did and T.Color(did.ok and "ok" or "bad", (did.ok and "Done: " or "Not yet: ") .. did.msg)
					or (e.risk and T.Color("muted", "Risk: " .. e.risk)) or "")
				c.l3:SetText((not e.act and e.go) and T.Color("accent", "Review") or "")
			else
				c.who:SetText(i == 1 and T.Color("muted", "Nothing urgent. Nice.") or "")
				c.time:SetText(""); c.l1:SetText(""); c.l2:SetText(""); c.l3:SetText("")
			end
		end
	else
	d.heading:SetText("Activity" .. T.Color("muted", "  what sold, bought and expired, newest first"))
	for i, c in ipairs(d.cards) do
		c.hit.go = nil
		c.hit.entry = nil
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
	-- one palette on every tab (Accounting used to switch to plum)
	local want = "auctioniq"
	if CH.Theme.palette ~= want or frame.palette ~= want then
		CH.Theme.Use(want)
		CH.Theme.Repaint(frame)
		frame.palette = want
		frame.title:SetText(titleText())
	end
	if FRAME[page] == "ledger" then CH.LedgerUI.SetSection(page) end
	-- a view that is a page of its own (the Report, Professions) shows beside the nav
	local def = FRAME[page] == "ledger" and CH.LedgerUI.ViewDef()
	local beside = def and def.page
	local report = beside == "briefing"
	for k, p in pairs(pages) do p:SetShown(k == frameOf(page) or k == beside) end
	UI.LayoutSubTabs()
	for k, b in pairs(pageButtons) do colorButton(b, k == page) end
	if not frame.tabsLaid then frame.tabsLaid = true; layoutTabs() end -- again once fonts and positions are final
	if CH.Ledger and CH.Ledger.Available() then frame.gold:SetText(CH.FormatMoney(CH.Ledger.Gold())) end
	frame.foot:SetText(CH.Theme.Color("muted", "/aiq help for commands.  Esc closes."))
	UI.RenderConcFooter()
	if page == "today" then return refreshDashboard()
	elseif beside == "plan" then refreshLedger(); return CH.PlanUI.Refresh()
	elseif beside == "paths" then refreshLedger(); return CH.PathsUI.Refresh()
	elseif beside == "perf" then refreshLedger(); return CH.Performance.Refresh()
	elseif page == "settings" then return settingsView == "groups" and CH.GroupsUI.Refresh() or CH.SettingsUI.Refresh()
	elseif report then
		refreshLedger()
		CH.ReportUI.Refresh()
		text:SetText(UI.BriefingText())
		text:GetParent():SetHeight(text:GetStringHeight() + 10)
	else return refreshLedger() end
end

--- The open tab's sub-tabs across the top, and the table page moved down under them. Returns the
--- sub-tab labels shown, for tests.
function UI.LayoutSubTabs()
	local groups = FRAME[page] == "ledger" and CH.LedgerUI.Groups(page)
	local open = CH.LedgerUI.Group()
	local shift = groups and 26 or 0
	local x, shown = 12, {}
	for i, b in ipairs(frame.subs) do
		local g = groups and groups[i]
		if g then
			setLabel(b, g[1])
			b.label, b.view = g[1], g[2]
			local f = b.text or (b.GetFontString and b:GetFontString())
			local w = math.max(80, math.ceil((f and f:GetStringWidth() or 70) + 24))
			b:SetWidth(w)
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -36)
			colorButton(b, g[1] == open)
			x = x + w + 4
			table.insert(shown, g[1])
		end
		b:SetShown(g ~= nil)
	end
	for k, left in pairs({ ledger = 12, plan = 12 + 172, paths = 12 + 172, briefing = 12 + 172, perf = 12 + 172 }) do
		local p = pages[k]
		if p then
			p:ClearAllPoints()
			p:SetPoint("TOPLEFT", frame, "TOPLEFT", left, -36 - shift)
			p:SetHeight(H - 54 - shift)
		end
	end
	-- the nav stops above the footer line
	if pages.ledger and pages.ledger.navPanel then pages.ledger.navPanel:SetHeight(H - 54 - shift) end
	-- as many table rows as the page has room for, above the table's footer line
	if CH.LedgerUI.SetRows then CH.LedgerUI.SetRows(math.floor((H - 54 - shift - 52 - 34) / 18)) end
	return shown
end

--- Open a tab, and optionally one of its views: UI.Go("operations", "par").
local function choose(tab, view, focus)
	if not FRAME[tab] then return false end
	-- a view that moved tabs (stock targets and dead stock to Trading, say) opens where it lives now
	local home = view and FRAME[tab] == "ledger" and CH.LedgerUI.SectionOf and CH.LedgerUI.SectionOf(view)
	if home and home ~= tab and FRAME[home] then tab = home end
	page = tab
	if tab == "settings" then settingsView = view == "groups" and "groups" or "main" end
	if view and FRAME[tab] == "ledger" then CH.LedgerUI.Set({ view = view, focus = focus }) end
	return true
end

--- Open a tab and view; focus (optional) hands over what a recommendation is about: { name, id, char,
--- qty, title }, so the view opens on it.
function UI.Go(tab, view, focus)
	local ok = choose(tab, view, focus)
	if ok and frame then UI.Refresh() end
	return ok
end

--- Show a tab: "today" (the Dashboard), "operations" or "ledger" (Accounting),
--- and optionally a view. The old names (markets, crafting, trading, analytics, plan, report...) still work.
function UI.Page(name, view, focus)
	if not frame then build() end
	if name then choose(name, view, focus) end
	-- one refresh: showing the frame refreshes it (OnShow), else refresh it here
	if not frame:IsShown() then frame:Show() else UI.Refresh() end
end

function UI.SetRange(r) range = r end
--- The page frames by name (dashboard, ledger, plan...), for tests.
function UI.Pages() return pages end
function UI.Buttons() return pageButtons end

function UI.IsShown()
	return frame ~= nil and frame:IsShown()
end

function UI.Toggle()
	if not frame then build() end
	if frame:IsShown() then frame:Hide() else frame:Show() end
end
