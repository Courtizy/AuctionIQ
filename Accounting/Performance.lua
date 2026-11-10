-- Reports > Performance: is my gold-making getting better, and what drove the change?
--
--   Headline         profit this period (the Income Statement's net income), the change against
--                    the period before, and the biggest measured driver in plain words.
--   Weekly profit    eight weeks of net income, the current week marked as partial. A product line
--                    filters the bars to that line's gross profit (expenses aren't split by line).
--   What drove it    the three items (or expenses) that added most to the change and the three
--                    that took most away. Each opens Profit drivers on the same windows and character.
--
-- The detail views (Profit drivers, Performance by line, Batch results, Forecast accuracy and the
-- rest) have no sub-tab of their own: the charts and the links under them open them.
local _, CH = ...

local P = {}
CH.Performance = P
local St = CH.Statements
local LUI = CH.LedgerUI

local DAY, WEEK = 86400, 7 * 86400

-- Periods: each compared with a window of the same length just before it. This week so far is
-- compared with the same point last week, so a partial week isn't set against a whole one.
P.PERIODS = { "week", "lastweek", "30" }
local LABEL = { week = "This week", lastweek = "Last week", ["30"] = "Last 30 days" }
local PRIOR = { week = "the same point last week", lastweek = "the week before", ["30"] = "the 30 days before" }
local period, line = "week", nil

function P.Period() return period end
function P.SetPeriod(p) if LABEL[p] then period = p end return period end
function P.Step(dir)
	local i = 1
	for k, p in ipairs(P.PERIODS) do if p == period then i = k end end
	period = P.PERIODS[(i - 1 + (dir or 1)) % #P.PERIODS + 1]
	return period
end
function P.Line() return line end
function P.SetLine(l) line = l end

--- The period's window and the one it's compared with: { from, to, pfrom, pto, label, prior }.
function P.Windows(p, now)
	p, now = p or period, now or time()
	local wk = St.WeekStart(now)
	local w
	if p == "lastweek" then w = { from = wk - WEEK, to = wk, pfrom = wk - 2 * WEEK, pto = wk - WEEK }
	elseif p == "30" then w = { from = now - 30 * DAY, to = now, pfrom = now - 60 * DAY, pto = now - 30 * DAY }
	else w = { from = wk, to = now, pfrom = wk - WEEK, pto = wk - WEEK + (now - wk) } end
	w.label, w.prior = LABEL[p] or LABEL.week, PRIOR[p] or PRIOR.week
	return w
end

-- [from, to): the statements count a record at `to` itself, so stop a second short of it
local function income(from, to, char) return St.Income(from, to - 1, char) end
local function items(from, to, char) return St.Items(from, to - 1, char) end

local function lineOf(id, crafted)
	local AV = CH.AnalyticsViews
	return AV and AV.Category and AV.Category(id, crafted) or "Other"
end

--- Eight weeks of profit, oldest first: { { from, to, profit, partial } }. With a product line, that
--- line's gross profit (sales after the cut less cost); without, net income as the statement has it.
function P.Weekly(char, l, now, n)
	now, n = now or time(), n or 8
	local wk = St.WeekStart(now)
	local crafted = l and CH.Ledger.Crafted()
	local out = {}
	for i = n - 1, 0, -1 do
		local from = wk - i * WEEK
		local to = i == 0 and now or from + WEEK
		local v
		if l then
			v = 0
			for id, x in pairs(items(from, to, char)) do if lineOf(id, crafted) == l then v = v + x.profit end end
		else
			v = income(from, to, char).netIncome
		end
		table.insert(out, { from = from, to = to, profit = v, partial = i == 0 })
	end
	return out
end

--- The product lines that sold anything in the last eight weeks, biggest profit first.
function P.Lines(char, now)
	now = now or time()
	local crafted = CH.Ledger.Crafted()
	local by = {}
	for id, x in pairs(items(St.WeekStart(now) - 7 * WEEK, now, char)) do
		local l = lineOf(id, crafted)
		by[l] = (by[l] or 0) + x.profit
	end
	local out = {}
	for l, v in pairs(by) do table.insert(out, { line = l, profit = v }) end
	table.sort(out, function(a, b) if a.profit ~= b.profit then return a.profit > b.profit end return a.line < b.line end)
	return out
end

-- Contributions ----------------------------------------------------------------------------------
-- Each item's change in profit, split three ways (the same split as Profit drivers): price (what each
-- sold for, at this period's volume), volume (how many sold, at the old margin) and cost (what each
-- cost, at this period's volume). The three add up to the item's change exactly.
local function split(id, a, b)
	local q0, q1 = b and b.sold or 0, a and a.sold or 0
	local p1 = a and a.sold > 0 and a.revenue / a.sold or nil
	local p0 = b and b.sold > 0 and b.revenue / b.sold or p1 or 0
	p1 = p1 or p0
	local c1 = a and a.each or nil
	local c0 = b and b.each or c1 or 0
	c1 = c1 or c0
	local x = { kind = "item", id = id, now = a and a.profit or 0, before = b and b.profit or 0, q0 = q0, q1 = q1, p0 = p0, p1 = p1, c0 = c0, c1 = c1 }
	x.change = x.now - x.before
	x.price, x.volume, x.cost = (p1 - p0) * q1, (q1 - q0) * (p0 - c0), -(c1 - c0) * q1
	local big, name = 0, nil
	for _, k in ipairs({ "volume", "price", "cost" }) do
		if math.abs(x[k]) > math.abs(big) then big, name = x[k], k end
	end
	x.driver = name
	return x
end

--- This period against the one before: { w, profit, prior, change, list (every contributor, the
--- change largest first), up (top 3 that added), down (top 3 that took away), big (the largest in
--- the direction profit moved) }. Contributors are items, expenses and lost deposits, other income, and sales TSM
--- logged without an item; together they add up to the change in net income.
function P.Compare(char, p, now)
	local w = P.Windows(p, now)
	local a, b = income(w.from, w.to, char), income(w.pfrom, w.pto, char)
	local ia, ib = items(w.from, w.to, char), items(w.pfrom, w.pto, char)
	local r = { w = w, profit = a.netIncome, prior = b.netIncome, change = a.netIncome - b.netIncome, list = {} }
	local ids, sum = {}, 0
	for id in pairs(ia) do ids[id] = true end
	for id in pairs(ib) do ids[id] = true end
	for id in pairs(ids) do
		local x = split(id, ia[id], ib[id])
		sum = sum + x.change
		if math.abs(x.change) >= 1 then table.insert(r.list, x) end
	end
	local function other(kind, label, change, view)
		sum = sum + change
		if math.abs(change) >= 1 then table.insert(r.list, { kind = kind, label = label, change = change, view = view }) end
	end
	other("expenses", "Expenses and lost deposits", (b.deposits + b.expenseTotal) - (a.deposits + a.expenseTotal), "expense")
	other("income", "Other income", a.income - b.income, "income")
	local rest = r.change - sum
	if math.abs(rest) >= 1 then table.insert(r.list, { kind = "other", label = "Sales without an item", change = rest, view = "sales" }) end
	table.sort(r.list, function(x, y) if x.change ~= y.change then return x.change > y.change end return (x.id or 0) < (y.id or 0) end)
	r.up, r.down = {}, {}
	for _, x in ipairs(r.list) do if x.change > 0 and #r.up < 3 then table.insert(r.up, x) end end
	for i = #r.list, 1, -1 do local x = r.list[i]; if x.change < 0 and #r.down < 3 then table.insert(r.down, x) end end
	-- the driver the headline names moves the same way as the total
	r.big = (r.change >= 0 and r.up[1]) or (r.change < 0 and r.down[1]) or nil
	return r
end

-- whole gold above 10g: silver and copper only clutter a headline
local function money(c)
	c = math.abs(c or 0)
	if c == 0 then return "0g" end
	if c >= 100000 then c = math.floor(c / 10000 + 0.5) * 10000 end
	return CH.FormatMoney(c)
end
local function signed(c) return (c >= 0 and "+" or "-") .. money(c) end
--- Gold in a few characters for chart labels: "12.3k", "1.2M", "450", with its sign.
function P.Compact(c)
	local g = (c or 0) / 10000
	local a = math.abs(g)
	local t
	if a >= 1e6 then t = string.format("%.1fM", a / 1e6)
	elseif a >= 1e4 then t = string.format("%.0fk", a / 1e3)
	elseif a >= 1e3 then t = string.format("%.1fk", a / 1e3)
	else t = string.format("%.0f", a) end
	return (g < 0 and "-" or "") .. t
end

function P.Name(x)
	if x.kind ~= "item" then return x.label end
	return select(2, LUI.ItemText(x.id))
end

--- One contributor in plain words: "12 more Flask of Alchemical Chaos sold".
function P.Explain(x)
	if x.kind == "expenses" then return x.change > 0 and "lower expenses and lost deposits" or "higher expenses and lost deposits" end
	if x.kind == "income" then return x.change > 0 and "more other income" or "less other income" end
	if x.kind == "other" then return "sales TSM logged without an item" end
	local name = P.Name(x)
	if x.q0 == 0 then return string.format("%d %s sold, none the period before", x.q1, name) end
	if x.q1 == 0 then return string.format("no %s sold, %d the period before", name, x.q0) end
	if x.driver == "price" then return string.format("%s selling for %s %s each", name, money(x.p1 - x.p0), x.p1 >= x.p0 and "more" or "less") end
	if x.driver == "cost" then return string.format("%s costing %s %s each", name, money(x.c1 - x.c0), x.c1 > x.c0 and "more" or "less") end
	local d = x.q1 - x.q0
	return string.format("%d %s %s sold", math.abs(d), d >= 0 and "more" or "fewer", name)
end

--- The headline: profit, the change, and the sentence about the biggest driver.
function P.Headline(r)
	local T = CH.Theme
	local first = string.format("%s: %s", r.w.label .. (period == "week" and " so far" or ""), T.Color(r.profit >= 0 and "ok" or "bad", (r.profit < 0 and "-" or "") .. money(r.profit)))
	local second = string.format("%s against %s (%s)", T.Color(r.change >= 0 and "ok" or "bad", signed(r.change)), r.w.prior, money(r.prior))
	local third
	if not r.big then third = T.Color("muted", "No sales in either window yet.")
	else
		third = string.format("%s mostly from %s (%s).", r.change >= 0 and "Up," or "Down,", P.Explain(r.big), T.Color(r.big.change >= 0 and "ok" or "bad", signed(r.big.change)))
	end
	return first, second, third
end

-- Forecast vs actual ------------------------------------------------------------------------------
P.CHECK_AFTER = 7 * DAY -- a batch's forecast can be checked a week after its first craft, or once it sold out
P.BAND = 0.2            -- in range: actual within 20% of the forecast (at least 5% of what the reagents cost)

--- The batch forecasts that can be checked now: { { d, x (Fc.Explain), forecast, actual, inRange,
--- shared } }. shared: another batch of the same item was made around the same time, so sales can't
--- be told apart by batch, and actual is item sales during the forecast window.
function P.Forecasts(now, char)
	now = now or time()
	local F, out = CH.Forecast, {}
	if not (F and F.Decisions and F.Explain) then return out end
	for _, d in ipairs(F.Decisions()) do
		if (not char or d.char == char) and (d.crafts or 0) > 0 then
			local x = F.Explain(d, now)
			local first = d.first or d.at
			if x and (now - first >= P.CHECK_AFTER or (x.made > 0 and x.left <= 0)) then
				local shared = false
				for _, b in ipairs(F.Batches(d.item)) do
					if b.decision ~= d.key and b.at > first - F.LINK and b.at < first + P.CHECK_AFTER then shared = true end
				end
				local band = math.max(math.abs(x.forecast) * P.BAND, (x.paid or 0) * 0.05, 10000)
				table.insert(out, { d = d, x = x, forecast = x.forecast, actual = x.actual, inRange = math.abs(x.actual - x.forecast) <= band,
					shared = shared, band = band })
			end
		end
	end
	return out
end

--- The forecast line: how many could be checked and how many landed in range.
function P.ForecastText(list)
	local T = CH.Theme
	if #list == 0 then
		return "Forecasts: " .. T.Color("muted", "none to check yet (a batch is checked a week after its first craft).")
	end
	local hit, shared = 0, 0
	for _, f in ipairs(list) do
		if f.inRange then hit = hit + 1 end
		if f.shared then shared = shared + 1 end
	end
	local pct = math.floor(hit / #list * 100 + 0.5)
	return string.format("Forecasts: %s of %d checked batches within %d%% of forecast (%d%%)%s", T.Color(pct >= 60 and "ok" or "bad", tostring(hit)),
		#list, math.floor(P.BAND * 100), pct, shared > 0 and T.Color("muted", string.format(", %d share sales", shared)) or "")
end

local scatter = false
function P.ToggleScatter() scatter = not scatter; return scatter end
function P.Scatter() return scatter end

-- Capital tied up --------------------------------------------------------------------------------
P.SLOW = 30 -- stock that takes longer than this many days to sell, at the last 30 days' rate

--- Gold in stock that won't sell within P.SLOW days: { total, slow, none (no sales in 30 days),
--- share, material, top = { id, name, value } }. Material when it's a quarter of stock and 1,000g+.
function P.Capital(char, now)
	now = now or time()
	local L = CH.Ledger
	local sold = {}
	for _, s in ipairs(L.Records("Sales")) do
		if s.id and s.time >= now - 30 * DAY then sold[s.id] = (sold[s.id] or 0) + (s.quantity or 0) end
	end
	local c = { total = 0, slow = 0, none = 0 }
	for _, e in ipairs(L.Inventory(nil, char)) do
		if not e.bound and (e.value or 0) > 0 then
			c.total = c.total + e.value
			local perDay = (sold[e.id] or 0) / 30
			local days = perDay > 0 and (e.total or 0) / perDay or nil
			if not days or days > P.SLOW then
				c.slow = c.slow + e.value
				if not days then c.none = c.none + e.value end
				if not c.top or e.value > c.top.value then c.top = { id = e.id, name = e.name, value = e.value } end
			end
		end
	end
	c.share = c.total > 0 and c.slow / c.total or 0
	c.material = c.share >= 0.25 and c.slow >= 1000 * 10000
	return c
end

--- Open Inventory, slowest stock first.
function P.OpenCapital()
	CH.UI.Go("ledger", "inventory")
	LUI.Set({ sort = 8, desc = true })
	CH.UI.Refresh()
end

-- Page ------------------------------------------------------------------------------------------
local page, cache
local CW, CH1 = 350, 208 -- each chart's width and body height
local Y0 = -126 -- the charts' top, under the headline and the forecast and capital strip
-- the weekly chart's plot: room above for the tallest bar's label, below for a loss's label, then dates
local PTOP, PH = Y0 - 44, 168

local function tip(owner, lines)
	if not GameTooltip then return end
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	for i, l in ipairs(lines) do
		if l[2] then GameTooltip:AddDoubleLine(l[1], l[2], 1, 1, 1, 1, 1, 1)
		else GameTooltip:AddLine(l[1], 1, 1, 1, i > 1) end
	end
	GameTooltip:Show()
end
local function untip() if GameTooltip then GameTooltip:Hide() end end

local function button(parent, w, label, click)
	local b = CH.Theme.Button(parent, label, w, 20)
	b:SetScript("OnClick", click)
	return b
end
local function setText(b, t)
	local f = b.text or (b.GetFontString and b:GetFontString())
	if f then f:SetText(t) end
	b.label = t
end

-- What a contributor's bar opens: an item opens Profit drivers on the same windows and character;
-- the rest open their ledger list.
function P.Open(x, r)
	local char = LUI.Char and LUI.Char()
	if x.kind == "item" then
		local name = P.Name(x)
		CH.UI.Go("ledger", "drivers", { id = x.id, name = name, ids = { [x.id] = true }, title = "Performance: " .. name, range = r.w })
	else
		CH.UI.Go("ledger", x.view or "statement")
	end
	if char then LUI.Set({ char = char }) end
end

--- Open one week of the chart as an Income Statement.
function P.OpenWeek(e)
	St.SetRange(e.from, e.to - 1, (date and date("Week of %b %d", e.from) or "Week") .. (e.partial and " (so far)" or ""))
	CH.UI.Go("ledger", "statement")
end

function P.Build(p, fs)
	local T = CH.Theme
	page = p
	local RW = 2 * CW + 16
	-- headline
	T.Card(p, 0, -4, RW, 70, true)
	p.head = fs(p, 12, -14, RW - 240, "LEFT", "GameFontHighlightLarge")
	p.change = fs(p, 12, -36, RW - 24, "LEFT", "GameFontHighlight")
	p.why = fs(p, 12, -54, RW - 24, "LEFT", "GameFontHighlightSmall")
	p.period = button(p, 110, "This week", function() P.Step(1); CH.UI.Refresh() end)
	p.period:SetPoint("TOPRIGHT", p, "TOPLEFT", RW - 8, -10)
	p.char = button(p, 110, "All characters", function()
		local list = { false }
		for _, c in ipairs(CH.Ledger.Characters()) do table.insert(list, c.name) end
		local cur, i = LUI.Char and LUI.Char() or false, 1
		for k, c in ipairs(list) do if c == cur then i = k end end
		LUI.Set({ char = list[i % #list + 1] })
		CH.UI.Refresh()
	end)
	p.char:SetPoint("TOPRIGHT", p.period, "TOPLEFT", -4, 0)

	-- chart 1: weekly profit
	-- forecasts and capital, one line each, under the headline
	T.Card(p, 0, -80, RW, 40)
	p.fcText = fs(p, 12, -86, RW - 140, "LEFT", "GameFontHighlightSmall")
	p.capHit = CreateFrame("Button", nil, p)
	p.capHit:SetPoint("TOPLEFT", 8, -100)
	p.capHit:SetSize(RW - 140, 16)
	p.capText = fs(p, 12, -102, RW - 140, "LEFT", "GameFontHighlightSmall")
	p.capHit:SetScript("OnClick", function() P.OpenCapital() end)
	p.capHit:SetScript("OnEnter", function(self) if self.tip then tip(self, self.tip) end end)
	p.capHit:SetScript("OnLeave", untip)
	p.fcButton = button(p, 120, "Forecast chart", function() P.ToggleScatter(); CH.UI.Refresh() end)
	p.fcButton:SetPoint("TOPRIGHT", p, "TOPLEFT", RW - 8, -90)

	local y = Y0
	T.Card(p, 0, y, CW, CH1 + 66)
	p.wTitle = fs(p, 10, y - 8, CW - 130, "LEFT", "GameFontNormal")
	p.wTitle:SetText("Weekly profit")
	p.line = button(p, 116, "All lines", function()
		local list = { false }
		for _, l in ipairs(P.Lines(LUI.Char and LUI.Char() or nil)) do table.insert(list, l.line) end
		local i = 1
		for k, l in ipairs(list) do if l == (line or false) then i = k end end
		line = list[i % #list + 1] or nil
		CH.UI.Refresh()
	end)
	p.line:SetPoint("TOPRIGHT", p, "TOPLEFT", CW - 6, y - 6)
	p.zero = p:CreateTexture(nil, "ARTWORK")
	p.zero:SetColorTexture(1, 1, 1, 0.25)
	p.weeks = {}
	local slot = math.floor((CW - 20) / 8)
	for i = 1, 8 do
		local hit = CreateFrame("Button", nil, p)
		hit:SetSize(slot - 6, PH)
		hit:SetPoint("TOPLEFT", 10 + (i - 1) * slot + 3, PTOP)
		hit.bar = hit:CreateTexture(nil, "ARTWORK")
		hit.value = fs(p, 10 + (i - 1) * slot, 0, slot, "CENTER", "GameFontHighlightSmall")
		hit.date = fs(p, 10 + (i - 1) * slot, PTOP - PH - 18, slot, "CENTER", "GameFontDisableSmall")
		hit:SetScript("OnEnter", function(self) if self.tip then tip(self, self.tip) end end)
		hit:SetScript("OnLeave", untip)
		hit:SetScript("OnClick", function(self) if self.e then P.OpenWeek(self.e) end end)
		p.weeks[i] = hit
	end
	p.wNote = fs(p, 10, PTOP - PH - 36, CW - 20, "LEFT", "GameFontDisableSmall")

	-- chart 2: what drove the change
	local x0 = CW + 16
	T.Card(p, x0, y, CW, CH1 + 66)
	p.dTitle = fs(p, x0 + 10, y - 8, CW - 20, "LEFT", "GameFontNormal")
	p.dTitle:SetText("What drove the change")
	p.mid = p:CreateTexture(nil, "ARTWORK")
	p.mid:SetColorTexture(1, 1, 1, 0.25)
	p.mid:SetPoint("TOPLEFT", x0 + 10 + 130 + 75, y - 32)
	p.mid:SetSize(1, 6 * 30 + 8)
	p.drivers = {}
	for i = 1, 6 do
		local ry = y - 32 - (i - 1) * 30 - (i > 3 and 8 or 0)
		local hit = CreateFrame("Button", nil, p)
		hit:SetSize(CW - 20, 20)
		hit:SetPoint("TOPLEFT", x0 + 10, ry)
		hit.label = fs(p, x0 + 10, ry - 4, 126, "LEFT", "GameFontHighlightSmall")
		hit.bar = hit:CreateTexture(nil, "ARTWORK")
		hit.value = fs(p, x0 + 10 + 130 + 150 + 4, ry - 4, CW - 20 - 284, "RIGHT", "GameFontHighlightSmall")
		hit:SetScript("OnEnter", function(self) if self.tip then tip(self, self.tip) end end)
		hit:SetScript("OnLeave", untip)
		hit:SetScript("OnClick", function(self) if self.x then P.Open(self.x, cache) end end)
		p.drivers[i] = hit
	end
	p.dNote = fs(p, x0 + 10, PTOP - PH - 36, CW - 20, "LEFT", "GameFontDisableSmall")

	-- forecast vs actual, in chart 2's place when asked for: one dot per checked batch
	p.sTitle = fs(p, x0 + 10, y - 8, CW - 20, "LEFT", "GameFontNormal")
	p.sTitle:SetText("Forecast vs actual")
	p.sAxis = fs(p, x0 + 10, PTOP - PH - 18, CW - 20, "LEFT", "GameFontDisableSmall")
	p.sNote = fs(p, x0 + 10, PTOP - PH - 36, CW - 20, "LEFT", "GameFontDisableSmall")
	p.sDiag = {}
	for i = 1, 24 do
		local t = p:CreateTexture(nil, "ARTWORK")
		t:SetColorTexture(1, 1, 1, 0.3)
		t:SetSize(2, 2)
		p.sDiag[i] = t
	end
	p.dots = {}
	for i = 1, 40 do
		local d = CreateFrame("Button", nil, p)
		d:SetSize(8, 8)
		d.t = d:CreateTexture(nil, "OVERLAY")
		d.t:SetAllPoints()
		d:SetScript("OnEnter", function(self) if self.tip then tip(self, self.tip) end end)
		d:SetScript("OnLeave", untip)
		d:SetScript("OnClick", function(self)
			if self.f then CH.UI.Go("ledger", "batches", { id = self.f.d.item, name = self.f.d.name, ids = { [self.f.d.item] = true }, title = "Forecast vs actual" }) end
		end)
		d:Hide()
		p.dots[i] = d
	end

	-- the detail views, one click away
	local ly = y - CH1 - 76
	p.more = fs(p, 0, ly - 4, 48, "LEFT", "GameFontDisableSmall")
	p.more:SetText("More:")
	p.links = {}
	local lx = 50
	for _, v in ipairs({ { "drivers", "Drivers" }, { "performance", "By line" }, { "batches", "Batches" }, { "perf", "Forecasts" },
		{ "capital", "Capital" }, { "crafting", "Crafting" }, { "time", "Per hour" }, { "results", "Craft log" } }) do
		local b = button(p, 82, v[2], function() CH.UI.Go("ledger", v[1]) end)
		b:SetPoint("TOPLEFT", p, "TOPLEFT", lx, ly)
		b.view = v[1]
		lx = lx + 84
		table.insert(p.links, b)
	end
end

local function short(t, n)
	t = tostring(t or "")
	if #t > n then return t:sub(1, n - 1) .. "..." end
	return t
end

--- Redraw. Returns what it drew, for tests: { compare, weekly }.
function P.Refresh(now)
	local p = page
	if not p then return nil end
	local T = CH.Theme
	now = now or time()
	if not (CH.Ledger and CH.Ledger.Available()) then
		p.head:SetText(T.Color("muted", "Needs TradeSkillMaster: Performance reads your sales."))
		p.change:SetText(""); p.why:SetText("")
		return nil
	end
	local char = LUI.Char and LUI.Char() or nil
	if char then char = char:match("^[^#]+") end
	local r = P.Compare(char, period, now)
	cache = r
	setText(p.period, r.w.label)
	setText(p.char, char or "All characters")
	setText(p.line, line and short(line, 16) or "All lines")
	local a, b, c = P.Headline(r)
	p.head:SetText(a); p.change:SetText(b); p.why:SetText(c)

	-- weekly bars from one zero line
	local weeks = P.Weekly(char, line, now)
	local hi, lo = 0, 0
	for _, e in ipairs(weeks) do hi, lo = math.max(hi, e.profit), math.min(lo, e.profit) end
	local span = math.max(1, hi - lo)
	local top = PTOP
	local zeroY = top - math.floor(PH * hi / span + 0.5)
	p.zero:ClearAllPoints()
	p.zero:SetPoint("TOPLEFT", 10, zeroY)
	p.zero:SetSize(CW - 20, 1)
	for i, hit in ipairs(p.weeks) do
		local e = weeks[i]
		local h = math.max(1, math.floor(PH * math.abs(e.profit) / span + 0.5))
		local col = e.profit >= 0 and T.ok or T.bad
		local alpha = e.partial and 0.45 or 0.9
		hit.bar:SetColorTexture(col[1], col[2], col[3], alpha)
		hit.bar:ClearAllPoints()
		hit.bar:SetPoint("TOPLEFT", hit, "TOPLEFT", 0, e.profit >= 0 and (zeroY - top + h) or (zeroY - top))
		hit.bar:SetSize(math.floor((CW - 20) / 8) - 6, h)
		hit.value:ClearAllPoints()
		hit.value:SetPoint("TOPLEFT", p, "TOPLEFT", 10 + (i - 1) * math.floor((CW - 20) / 8), e.profit >= 0 and (zeroY + h + 12) or (zeroY - h - 2))
		hit.value:SetText(e.profit ~= 0 and T.Color("muted", P.Compact(e.profit)) or "")
		hit.date:SetText(e.partial and "now" or (date and string.format("%d/%d", tonumber(date("%m", e.from)), tonumber(date("%d", e.from)))) or tostring(i))
		hit.e = e
		local label = date and date("Week of %b %d", e.from) or "Week"
		hit.tip = { { label .. (e.partial and " (so far)" or "") },
			{ line and (line .. " gross profit") or "Net income", (e.profit < 0 and "-" or "") .. money(e.profit) },
			{ T.Color("muted", e.partial and "The week isn't over: this bar is still growing." or (line and "Sales after the cut less what they cost. Expenses aren't split by line." or "The Income Statement's net income for the week.")) },
			{ T.Color("accent", "Click for that week's Income Statement.") } }
	end
	p.wNote:SetText(line and "Gross profit of that line. Faded: so far." or "Net income. Faded bar: this week so far.")

	-- top three each way, from one middle line
	local rows = {}
	for _, x in ipairs(r.up) do table.insert(rows, x) end
	for i = 1, 3 - #r.up do table.insert(rows, false) end
	for _, x in ipairs(r.down) do table.insert(rows, x) end
	local most = 1
	for _, x in ipairs(rows) do if x then most = math.max(most, math.abs(x.change)) end end
	for i, hit in ipairs(p.drivers) do
		local x = rows[i]
		hit:SetShown(x and true or false)
		hit.label:SetShown(x and true or false)
		hit.value:SetShown(x and true or false)
		if x then
			local w = math.max(1, math.floor(73 * math.abs(x.change) / most + 0.5))
			local col = x.change >= 0 and T.ok or T.bad
			hit.bar:SetColorTexture(col[1], col[2], col[3], 0.85)
			hit.bar:ClearAllPoints()
			hit.bar:SetPoint("TOPLEFT", hit, "TOPLEFT", x.change >= 0 and 205 or (205 - w), -4)
			hit.bar:SetSize(w, 12)
			hit.label:SetText(short(P.Name(x), 17))
			hit.value:SetText(T.Color(x.change >= 0 and "ok" or "bad", (x.change >= 0 and "+" or "") .. P.Compact(x.change)))
			hit.x = x
			local t = { { P.Name(x) }, { "Change", signed(x.change) }, { T.Color("muted", P.Explain(x)) } }
			if x.kind == "item" then
				table.insert(t, 3, { "Price", signed(x.price) })
				table.insert(t, 4, { "Volume", signed(x.volume) })
				table.insert(t, 5, { "Cost", signed(x.cost) })
				table.insert(t, { T.Color("accent", "Click for its Profit drivers over the same windows.") })
			else
				table.insert(t, { T.Color("accent", "Click for the transactions.") })
			end
			hit.tip = t
		else
			hit.x, hit.tip = nil, nil
		end
	end
	p.dNote:SetText(#r.list == 0 and "Nothing sold in either window yet." or ("Against " .. r.w.prior .. "."))

	-- forecasts and capital
	local fl = P.Forecasts(now, char)
	p.fcText:SetText(P.ForecastText(fl))
	local cap = P.Capital(char, now)
	if cap.material then
		p.capText:SetText(string.format("Capital tied up: %s, %d%% of stock, won't sell within %d days%s  %s", money(cap.slow), math.floor(cap.share * 100 + 0.5), P.SLOW,
			cap.top and (". Largest: " .. short(cap.top.name or "?", 22)) or "", T.Color("accent", "Show")))
		p.capHit.tip = { { "Capital tied up" }, { "Stock that won't sell within " .. P.SLOW .. " days", money(cap.slow) },
			{ "Of that, no sales in 30 days", money(cap.none) }, { "All stock at market value", money(cap.total) },
			{ T.Color("muted", "Days to sell: what you hold over what sold a day in the last 30 days.") },
			{ T.Color("accent", "Click for Inventory, slowest first.") } }
	else
		p.capText:SetText(T.Color("muted", string.format("Capital tied up: %s in slow stock, %d%% of it. Fine.", money(cap.slow), math.floor(cap.share * 100 + 0.5))))
		p.capHit.tip = nil
	end
	setText(p.fcButton, scatter and "Drivers chart" or "Forecast chart")

	-- chart 2's place: the drivers, or forecast vs actual
	p.dTitle:SetShown(not scatter); p.mid:SetShown(not scatter); p.dNote:SetShown(not scatter)
	for _, hit in ipairs(p.drivers) do
		if scatter then hit:Hide(); hit.label:Hide(); hit.value:Hide() end
	end
	p.sTitle:SetShown(scatter); p.sAxis:SetShown(scatter); p.sNote:SetShown(scatter)
	for _, t in ipairs(p.sDiag) do t:SetShown(scatter) end
	local lo, hi = 0, 1
	for _, f in ipairs(fl) do lo, hi = math.min(lo, f.forecast, f.actual), math.max(hi, f.forecast, f.actual) end
	local span = hi - lo
	local x0, side = CW + 16 + 10 + 40, PH -- a square plot: forecast across, actual up
	local function at(fv, av)
		return x0 + math.floor((fv - lo) / span * (side - 8) + 0.5), PTOP - (side - 8) + math.floor((av - lo) / span * (side - 8) + 0.5)
	end
	for i, t in ipairs(p.sDiag) do
		local v = lo + span * (i - 1) / (#p.sDiag - 1)
		local px, py = at(v, v)
		t:ClearAllPoints()
		t:SetPoint("TOPLEFT", p, "TOPLEFT", px + 3, py - 3)
	end
	for i, d in ipairs(p.dots) do
		local f = scatter and fl[i]
		d:SetShown(f and true or false)
		d.f, d.tip = f or nil, nil
		if f then
			local px, py = at(f.forecast, f.actual)
			d:ClearAllPoints()
			d:SetPoint("TOPLEFT", p, "TOPLEFT", px, py)
			local col = f.inRange and T.ok or T.bad
			d.t:SetColorTexture(col[1], col[2], col[3], f.shared and 0.4 or 1)
			d.tip = { { (f.d.name or "?") .. (f.d.char and (" - " .. f.d.char) or "") },
				{ "Forecast by now", (f.forecast < 0 and "-" or "") .. money(f.forecast) },
				{ f.shared and "Item sales during the forecast window" or "Batch result", (f.actual < 0 and "-" or "") .. money(f.actual) },
				{ T.Color(f.inRange and "ok" or "bad", f.inRange and "In range" or ("Missed by " .. money(f.actual - f.forecast))) },
				{ T.Color("muted", f.shared and "Another batch of this item overlapped, so its sales can't be split by batch." or (f.x.takeaway or "")) },
				{ T.Color("accent", "Click for Batch results.") } }
		end
	end
	p.sAxis:SetText(string.format("Across: forecast. Up: actual. %s to %s.", P.Compact(lo), P.Compact(hi)))
	p.sNote:SetText(#fl == 0 and "No batch can be checked yet." or "Green: within range. Faded: shares sales.")
	return { compare = r, weekly = weeks, forecasts = fl, capital = cap }
end

-- The detail views live under Reports now, opened from this page rather than a sub-tab of their own.
if LUI and LUI.Register then
	P.VIEWS = { overview = { label = "Performance", page = "perf", cols = {}, noTime = true } }
	LUI.Register("ledger", P.VIEWS, {})
	for _, k in ipairs({ "overview", "performance", "batches", "perf", "results", "drivers", "capital", "crafting", "time" }) do
		local d = LUI.ViewDef(k)
		if d then d.parent, d.section = "Reports", d.section or "ledger" end
	end
	LUI.AddNav("ledger", "Reports", "overview")
	LUI.Order("ledger", { "Reports", "Revenue", "Expenses", "Inventory", "Profit" })
end
