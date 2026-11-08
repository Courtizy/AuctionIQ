-- The books at the top of the Briefing: the last 7, 30 and 90 days side by side (sales, purchases,
-- overhead, cash profit, net worth change), top sellers and profit by product line. Also the
-- Ledger's Export box: any table as CSV text to copy out.
local _, CH = ...

local RUI = {}
CH.ReportUI = RUI
local page

local SPANS = { { "Last 7 days", 7 }, { "Last 30 days", 30 }, { "Last 90 days", 90 } }

--- The report's numbers for a span: { sales (after cut), buys, overhead, cash, worth, top = { {id, gold} }, lines = { {line, profit} } }.
function RUI.Numbers(days, now)
	now = now or time()
	local L = CH.Ledger
	local since = now - days * 86400
	local o = L.Overhead(since)
	local top = {}
	for _, s in ipairs(L.Records("Sales")) do
		if s.id and s.time >= since then top[s.id] = (top[s.id] or 0) + s.amount end
	end
	local list = {}
	for id, g in pairs(top) do table.insert(list, { id = id, gold = g }) end
	table.sort(list, function(a, b) return a.gold > b.gold end)
	for i = #list, 6, -1 do list[i] = nil end
	local lines, byLine = {}, {}
	for _, e in ipairs(L.ProductPL(since)) do byLine[e.line] = (byLine[e.line] or 0) + e.profit end
	for line, p in pairs(byLine) do table.insert(lines, { line = line, profit = p }) end
	table.sort(lines, function(a, b) return a.profit > b.profit end)
	return { sales = o.sales, buys = o.buys, overhead = o.total, cash = o.afterOverhead, worth = L.WorthChange(since), top = list, lines = lines }
end

--- The report as text lines (also what the page shows).
function RUI.Text(now)
	local T, m = CH.Theme, CH.FormatMoney
	if not (CH.Ledger and CH.Ledger.Available()) then return { T.Color("muted", "Needs TradeSkillMaster: the report reads its accounting.") } end
	local out = {}
	local cols = {}
	for _, s in ipairs(SPANS) do table.insert(cols, RUI.Numbers(s[2], now)) end
	local function row(label, key, signed)
		local cells = {}
		for _, c in ipairs(cols) do
			local v = c[key]
			local t = v and m(v) or T.Color("muted", "-")
			if signed and v then t = T.Color(v >= 0 and "ok" or "bad", (v > 0 and "+" or "") .. m(v)) end
			table.insert(cells, t)
		end
		return label, cells
	end
	RUI.rows = {
		{ row("Sales, after the AH cut", "sales") },
		{ row("Purchases", "buys") },
		{ row("Overhead (repairs, postage...)", "overhead") },
		{ row("Cash profit", "cash", true) },
		{ row("Net worth change (gold + stock)", "worth", true) },
	}
	for _, s in ipairs(SPANS) do table.insert(out, s[1]) end
	local c30 = cols[2]
	local tops = {}
	for _, t in ipairs(c30.top) do table.insert(tops, CH.LedgerUI.ItemText(t.id) .. "  " .. m(t.gold)) end
	local lines = {}
	for _, l in ipairs(c30.lines) do table.insert(lines, l.line .. "  " .. T.Color(l.profit >= 0 and "ok" or "bad", m(l.profit))) end
	RUI.tops, RUI.linesText = tops, lines
	return out
end

local function csvEscape(v)
	v = tostring(v or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("|H.-|h(.-)|h", "%1")
	if v:find("[,\"]") then v = '"' .. v:gsub('"', '""') .. '"' end
	return v
end

--- A Ledger view as CSV text (header + rows, as sorted values, not formatted text).
function RUI.CSV(view, opts)
	local v = CH.LedgerUI.VIEWS[view]
	local rows = CH.LedgerUI.Rows(view, opts or { days = 30 })
	local out = {}
	local head = {}
	for _, c in ipairs(v.cols) do table.insert(head, csvEscape(c[1])) end
	table.insert(out, table.concat(head, ","))
	for _, r in ipairs(rows) do
		local cells = {}
		for j = 1, #v.cols do
			local x = r.sort and r.sort[j]
			if j == 1 then x = select(2, CH.LedgerUI.ItemText(r.id)) or r.cells[1] end
			if type(x) == "number" and x ~= math.huge and x ~= -math.huge and x >= 10000 and (v.cols[j][1]:find("Total") or v.cols[j][1]:find("Per") or v.cols[j][1]:find("Value")
				or v.cols[j][1]:find("Revenue") or v.cols[j][1]:find("Profit") or v.cols[j][1]:find("Cost") or v.cols[j][1]:find("Amount") or v.cols[j][1]:find("Avg")) then
				x = string.format("%.2f", x / 10000) -- gold
			end
			table.insert(cells, csvEscape(x))
		end
		table.insert(out, table.concat(cells, ","))
	end
	return table.concat(out, "\n"), #rows
end

--- The books, drawn at the top of the Briefing page (height 170).
function RUI.Build(p, fs, panel)
	page = p
	local box = panel(p, 0, 0, 560, 166)
	p.head = {}
	for i, s in ipairs(SPANS) do
		p.head[i] = fs(box, 240 + (i - 1) * 106, -8, 100, "RIGHT", "GameFontNormal")
		p.head[i]:SetText(s[1])
	end
	p.lines = {}
	for i = 1, 5 do
		local y = -30 - (i - 1) * 20
		local r = { label = fs(box, 10, y, 230), cells = {} }
		for j = 1, #SPANS do r.cells[j] = fs(box, 240 + (j - 1) * 106, y, 100, "RIGHT") end
		p.lines[i] = r
	end
	p.note = fs(box, 10, -134, 540, "LEFT", "GameFontDisableSmall")
	p.note:SetText("Cash profit counts reagents bought as spent; net worth change counts stock you still hold. Export any table from the Ledger.")
	if p.note.SetMaxLines then p.note:SetMaxLines(2) end
	local side = panel(p, 572, 0, 324, 166)
	p.side = fs(side, 10, -8, 304, "LEFT")
	p.side:SetJustifyV("TOP")
	if p.side.SetMaxLines then p.side:SetMaxLines(10) end
end

local popup
--- A copy box with a Ledger table as CSV: the Ledger's Export button.
function RUI.Export(view, opts)
	local text, n = RUI.CSV(view, opts)
	if not popup then
		popup = CH.Window.New("ClearinghouseExport", "", 640, 400)
		popup.title:SetText(CH.Theme.Color("accent", "Export as CSV"))
		popup.note = popup:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		popup.note:SetPoint("TOPLEFT", 14, -34)
		local scroll = CreateFrame("ScrollFrame", nil, popup, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 14, -52)
		scroll:SetPoint("BOTTOMRIGHT", -34, 14)
		local eb = CreateFrame("EditBox", nil, scroll)
		eb:SetMultiLine(true)
		eb:SetAutoFocus(false)
		eb:SetFontObject("GameFontHighlightSmall")
		eb:SetWidth(580)
		eb:SetScript("OnEscapePressed", function() popup:Hide() end)
		scroll:SetScrollChild(eb)
		popup.box = eb
	end
	popup.box:SetText(text)
	popup.note:SetText(string.format("%s: %d rows, selected. Ctrl+C to copy, then paste into a sheet or your notes.", CH.LedgerUI.VIEWS[view].label, n))
	popup:Show()
	popup.box:SetFocus()
	popup.box:HighlightText()
	return text, n
end

function RUI.Refresh()
	local p = page
	if not p then return {} end
	local out = RUI.Text()
	for i, r in ipairs(p.lines) do
		local row = RUI.rows and RUI.rows[i]
		r.label:SetText(row and row[1] or (i == 1 and out[1] or ""))
		for j, c in ipairs(r.cells) do c:SetText(row and row[2][j] or "") end
	end
	local side = {}
	if RUI.tops and #RUI.tops > 0 then
		table.insert(side, CH.Theme.Color("accent", "Top sellers, last 30 days"))
		for _, t in ipairs(RUI.tops) do table.insert(side, "  " .. t) end
	end
	if RUI.linesText and #RUI.linesText > 0 then
		table.insert(side, CH.Theme.Color("accent", "Crafted profit by line, 30 days"))
		for _, t in ipairs(RUI.linesText) do table.insert(side, "  " .. t) end
	end
	p.side:SetText(table.concat(side, "\n"))
	return RUI.rows or {}
end
