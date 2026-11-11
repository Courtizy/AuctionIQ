-- Ledger page of the main window, like TSM's, with sub-tabs: Overview (Report, Inventory); Revenue
-- (Sales, Other); Expenses (Purchases, Other, Expired, Cancelled); Profit (Product P&L,
-- Holdings, Overhead); Performance (Core/Views.lua: where forecasts missed). Filter by name, character and
-- time frame, sort by any column, hover an item for its tooltip. Data comes from CH.Ledger, which
-- reads TSM's saved accounting and never writes to it.
local _, CH = ...

local LUI = {}
CH.LedgerUI = LUI

local X0, TW = 172, 724 -- table left edge and width inside the page (TW follows the window)
local BASE_TW = 724 -- the width the columns are laid out for; a wider table spreads them
-- a column's width, kept clear of the scroll bar down the table's right edge
local TWT = 724 -- the table's own width: TW, less the side panel on a view that has one
local SIDE = 270 -- the side panel's width
local function colX(c) return math.floor(c[2] * TWT / BASE_TW) end
local function cellWidth(c) return math.min(math.floor(c[3] * TWT / BASE_TW), TWT - 10 - colX(c)) end
local ROWS, RH = 23, 18 -- rows shown: as many as the window height has room for (LUI.SetRows)
-- A view with detail = function(row, ctx) shows the selected row's detail in a panel right of the
-- table: { kicker, title, sub, figures = { { label, value } x3 }, rows = { { label, value } },
-- section = { head, rows = { { label, value, tip = lines } } }, note, actions = { { label, run, tip } } }.
-- run() returns ok and a line saying what happened, shown in the panel.
local selected, said -- the selected row's key (row.key, else its id and first cell), and the last action's result
local MAX_ROWS = 60

local view = "inventory"
local filter, char, days = "", nil, 30
-- what a Dashboard recommendation handed over: { name, id, char, qty, title, why }; cleared when you
-- change view or clear the name filter
local focus
local sortCol, sortDesc = nil, true
local offset = 0
local page

local TIMES = { { "Last Day", 1 }, { "Last 7 Days", 7 }, { "Last 30 Days", 30 }, { "Last 90 Days", 90 }, { "Last Year", 365 }, { "All Time", nil } }

-- Columns: { label, x, width, default sort when picked }. Column 1 is left-aligned.
local ITEM_TIME = { { "Item", 0, 220 }, { "Character", 224, 90 }, { "Type", 318, 60 }, { "Qty", 382, 50 }, { "Per item", 436, 90 },
	{ "Total", 530, 96 }, { "Time frame", 630, 94 } }
local OTHER = { { "Type", 0, 180 }, { "Character", 184, 110 }, { "Other character", 298, 128 }, { "Amount", 430, 120 }, { "Time frame", 630, 94 } }
local VIEWS = {
	-- what you hold and what it's worth against what it cost; hover Held for where it is
	inventory = { label = "Inventory", parent = "Inventory", sort = 5, cols = { { "Item", 0, 166 }, { "Held", 170, 46 }, { "Paid each", 220, 78 },
		{ "Worth each", 302, 78 }, { "Value", 384, 90 }, { "Unrealized", 478, 84 }, { "Last sold", 566, 70 }, { "Days of stock", 640, 84 } } },
	sales = { label = "Sales", parent = "Revenue", sort = 7, asc = true, cols = ITEM_TIME },
	income = { label = "Other", parent = "Revenue", sort = 5, asc = true, cols = OTHER },
	purchases = { label = "Purchases", parent = "Expenses", sort = 7, asc = true, cols = ITEM_TIME },
	expense = { label = "Other", parent = "Expenses", sort = 5, asc = true, cols = OTHER },
	expired = { label = "Expired", parent = "Expenses", sort = 5, asc = true,
		cols = { { "Item", 0, 300 }, { "Character", 304, 120 }, { "Qty", 428, 60 }, { "Deposit lost", 492, 134 }, { "Time frame", 630, 94 } } },
	cancelled = { label = "Cancelled", parent = "Expenses", sort = 5, asc = true,
		cols = { { "Item", 0, 300 }, { "Character", 304, 120 }, { "Qty", 428, 60 }, { "Deposit lost", 492, 134 }, { "Time frame", 630, 94 } } },
	pl = { label = "Product P&L", parent = "Profit", sort = 6, cols = { { "Item", 0, 196 }, { "Line", 200, 96 }, { "Sold", 300, 44 },
		{ "Revenue", 348, 96 }, { "Cost (paid)", 448, 90 }, { "Realized profit", 542, 100 }, { "Margin", 646, 78 } } },
	perf = { label = "Forecast accuracy", sort = 8, cols = { { "Item", 0, 196 }, { "Made", 200, 44 }, { "Sold", 248, 44 },
		{ "Forecast each", 296, 90 }, { "Sold each", 390, 90 }, { "vs forecast", 484, 70 }, { "Days", 558, 44 }, { "Realized", 606, 118 } } },
	holdings = { label = "Holdings", parent = "Inventory", sort = 6, cols = { { "Item", 0, 196 }, { "Held", 200, 54 }, { "Paid each", 258, 88 },
		{ "Worth each", 350, 88 }, { "Change", 442, 60 }, { "Unrealized", 506, 112 }, { "Days of stock", 622, 102 } } },
	overhead = { label = "Overhead", parent = "Profit", sort = 3, cols = { { "Type", 0, 220 }, { "Count", 224, 70 }, { "Total", 298, 120 },
		{ "Per day", 422, 110 }, { "Share", 536, 80 } } },
}
-- Two tabs share this table page, each with sub-tabs across the top and their views in the left
-- nav: Operations (Professions, Markets, Queue, Stock: what to craft, buy or post) and Accounting
-- (Overview, Revenue, Expenses, Profit, Performance: what happened and what to learn from it).
-- Other modules fill theirs in with LUI.Register; LUI.Order sets the sub-tabs' order.
local SECTIONS = {
	ledger = { tabbed = true,
		{ "Revenue", "sales" }, { "sales", sub = true }, { "income", sub = true },
		{ "Expenses", "purchases" }, { "purchases", sub = true }, { "expense", sub = true },
		{ "expired", sub = true }, { "cancelled", sub = true },
		{ "Inventory", "inventory" }, { "inventory", sub = true },
		{ "Profit", "pl" }, { "pl", sub = true }, { "overhead", sub = true } },
	operations = {},
}
local section = "ledger"
local lastView = { ledger = "inventory" }
LUI.SECTIONS = SECTIONS
LUI.VIEWS = VIEWS

-- Formatting ----------------------------------------------------------------------------------
local function money(c, sign)
	if not c then return CH.Theme.Color("muted", "-") end
	local t = CH.FormatMoney(c)
	if sign and c > 0 then t = "+" .. t end
	return t
end

local function signed(c) return CH.Theme.Color(c >= 0 and "ok" or "bad", money(c)) end
LUI.Money, LUI.Signed = money, signed

--- Another tab adds its views to this page: section is "operations" or "ledger", views maps a
--- view key to { label, sort, cols, rows = function(ctx) return rows, footer end, noTime = true },
--- nav lists the keys in the order the left nav shows them, and group, if given, files them under
--- a heading ("Markets"). ctx carries now, since, opts, keepName, keepRec. A view with page = "plan"
--- shows that page frame beside the nav instead of a table; one with go = function opens elsewhere.
function LUI.Register(sec, views, nav, group)
	SECTIONS[sec] = SECTIONS[sec] or {}
	for k, def in pairs(views) do VIEWS[k] = def; def.section = def.section or sec end
	if group and nav[1] then
		SECTIONS[sec].tabbed = true
		table.insert(SECTIONS[sec], { group, nav[1] })
		for _, k in ipairs(nav) do
			if VIEWS[k] then VIEWS[k].parent = group end
			table.insert(SECTIONS[sec], { k, sub = true })
		end
	else
		for _, k in ipairs(nav) do table.insert(SECTIONS[sec], { k }) end
	end
	lastView[sec] = lastView[sec] or nav[1]
end

--- Add a view to an existing sub-tab's nav, after its other views.
function LUI.AddNav(sec, group, k)
	local list = SECTIONS[sec]
	if not list then return end
	local at
	for i, n in ipairs(list) do
		if not n.sub and n[1] == group then at = i
		elseif at and not n.sub then break
		elseif at then at = i end
	end
	if not at then return end
	table.insert(list, at + 1, { k, sub = true })
	if VIEWS[k] then VIEWS[k].parent = group end
end

--- The order of a tab's sub-tabs, by label: LUI.Order("operations", { "Craft", "Trade", "Queue" }).
--- The tab opens on the first one. Sub-tabs not listed follow, in the order they registered.
function LUI.Order(sec, labels)
	local list = SECTIONS[sec]
	if not list then return end
	list.order = {}
	for i, g in ipairs(labels) do list.order[g] = i end
	for _, n in ipairs(list) do
		if not n.sub and n[1] == labels[1] then lastView[sec] = n[2]; break end
	end
end

--- A tab's sub-tabs: { { label, view } } with the view each one opens (the last one open in it),
--- or nil for a tab without them.
local lastIn = {}
function LUI.Groups(sec)
	local list = SECTIONS[sec]
	if not (list and list.tabbed) then return nil end
	local out = {}
	for i, n in ipairs(list) do
		if not n.sub then table.insert(out, { n[1], lastIn[n[1]] or n[2], at = list.order and list.order[n[1]] or 100 + i }) end
	end
	table.sort(out, function(a, b) return a.at < b.at end)
	return out
end
--- The sub-tab the open view is in, or nil.
function LUI.Group() return SECTIONS[section] and SECTIONS[section].tabbed and VIEWS[view] and VIEWS[view].parent or nil end

--- A view's definition (label, cols, page...), for the main window.
function LUI.ViewDef(v) return VIEWS[v or view] end

--- An item as TSM shows it: icon, name in its rarity colour with its quality pip. Plain name too.
function LUI.ItemText(id)
	if not id then return "?", "?" end
	local name, link
	if C_Item and C_Item.GetItemInfo then name, link = C_Item.GetItemInfo(id) end
	name = name or (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id))
	if name and CH.db then CH.db.itemNames = CH.db.itemNames or {}; CH.db.itemNames[id] = name end -- for the Python export
	name = name or ("item " .. id)
	local shown = link and link:gsub("|H.-|h%[?(.-)%]?|h", "%1") or name
	return CH.Window.ItemIcon(id, 14) .. shown, name
end

--- "2 Days 3 Hr", "21 Hr 41 Min", "28 Min", like TSM's time frame.
function LUI.Ago(t, now)
	local d = math.max(0, (now or time()) - t)
	if d < 3600 then return string.format("%d Min", math.floor(d / 60)) end
	if d < 86400 then return string.format("%d Hr %d Min", math.floor(d / 3600), math.floor(d % 3600 / 60)) end
	local n = math.floor(d / 86400)
	return string.format("%d Day%s %d Hr", n, n == 1 and "" or "s", math.floor(d % 86400 / 3600))
end

-- Data ----------------------------------------------------------------------------------------
--- Rows for a view: { cells = { text... }, sort = { value... }, id = itemID }, then the footer
--- text. opts: filter (name keyword), char (character name), days (nil = all time), now.
--- The Character picker for a view with its own rows: keep the rows whose Character column is that
--- character (by name, with or without the realm). Views that filter their own records pass through.
function LUI.KeepChar(def, rows, char)
	if not char or type(rows) ~= "table" or not def.cols then return rows end
	-- "Name#professionID" (Compare crafts' picker) also keeps only that profession's crafts
	local name, prof = char:match("^([^#]+)#?(.*)$")
	local col
	for j, c in ipairs(def.cols) do if c[1] == "Character" then col = j; break end end
	if not col then return rows end
	local function plain(t)
		local x = tostring(t or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
		return ((x:match("^%s*([^%-]*)") or ""):gsub("%s+$", ""))
	end
	local out = {}
	for _, r in ipairs(rows) do
		local pid = r.profID or (r.x and r.x.profID)
		if r.cells and plain(r.cells[col]) == name and (prof == "" or tostring(pid) == prof) then table.insert(out, r) end
	end
	return out
end

function LUI.Rows(v, opts)
	opts = opts or {}
	local L = CH.Ledger
	local now = opts.now or time()
	local since = opts.days and (now - opts.days * 86400) or -math.huge
	local key = opts.filter and opts.filter ~= "" and string.lower(opts.filter) or nil
	local mine = {}
	for _, c in ipairs(L.Characters()) do mine[c.name] = true end
	local out = {}
	local function keepName(name) return not key or string.lower(name or ""):find(key, 1, true) end
	local function keepRec(r) return r.time >= since and (not opts.char or r.player == opts.char) end
	local def = VIEWS[v]
	if def and def.rows then
		local rows, footer = def.rows({ now = now, since = since, opts = opts, keepName = keepName, keepRec = keepRec, mine = mine })
		rows = LUI.KeepChar(def, rows, opts.char)
		-- a grouped Dashboard card hands over its exact items: show that shortlist only
		local ids = opts.focus and opts.focus.ids
		if ids and type(rows) == "table" then
			local keep = {}
			for _, r in ipairs(rows) do if r.id and ids[r.id] then table.insert(keep, r) end end
			rows = keep
		end
		return rows, footer
	end

	if v == "inventory" then
		local T = CH.Theme
		local total, gain = 0, 0
		-- what each cost: what you paid in the last 30 days of buying it, else what it costs to make
		local paid, crafted, index = L.Paid(), L.Crafted(), L.PaidIndex()
		local sold30, sold7, last = {}, {}, {}
		for _, s in ipairs(L.Records("Sales")) do
			if s.id and s.time >= now - 30 * 86400 then sold30[s.id] = (sold30[s.id] or 0) + s.quantity end
			if s.id and s.time >= now - 7 * 86400 then sold7[s.id] = (sold7[s.id] or 0) + s.quantity end
			if s.id and (not last[s.id] or s.time > last[s.id].time) then last[s.id] = s end
		end
		for _, e in ipairs(L.Inventory(opts.filter, opts.char)) do
			local text, name = LUI.ItemText(e.id)
			total = total + e.value
			local each, how = paid[e.id] and paid[e.id].each, "bought"
			if not each and crafted[e.id] then each, how = (L.CostAt(crafted[e.id].acc, index, now)), "crafted" end
			local un = each and e.unit and (e.unit - each) * e.total or nil
			if un then gain = gain + un end
			local perDay = (sold30[e.id] or 0) / 30
			local days = perDay > 0 and e.total / perDay or nil
			-- when you last sold one, in days (TSM keeps your sales, not the market's)
			local ls = last[e.id]
			local ago = ls and math.max(0, math.floor((now - ls.time) / 86400))
			local agoText = not ls and T.Color("muted", "never") or ago == 0 and T.Color("ok", "today")
				or T.Color(ago <= 7 and "ok" or ago <= 30 and "fg" or "bad", ago .. (ago == 1 and " day" or " days"))
			table.insert(out, { id = e.id, cells = { text, e.total, each and money(each) or T.Color("muted", "-"),
				e.bound and T.Color("muted", "bound") or money(e.unit), e.bound and T.Color("muted", "-") or money(e.value),
				un and signed(un) or T.Color("muted", "-"), agoText,
				days and (days > 365 and T.Color("bad", "1 yr+") or string.format("%.0f", days)) or T.Color("muted", "no history") },
				sort = { name, e.total, each or -1, e.unit or 0, e.value, un or -math.huge, ago or math.huge, days or math.huge },
				cellTip = function(j)
					if j == 2 then
						local lines = { { "Where it is" } }
						for _, w in ipairs({ { "Bags", e.bags }, { "Bank", e.bank }, { "Mail", e.mail }, { "Warband bank", e.warband }, { "On the AH", e.ah } }) do
							if (w[2] or 0) > 0 then table.insert(lines, { w[1], tostring(w[2]) }) end
						end
						return lines
					elseif j == 3 then
						return { { "Paid each" }, { T.Color("muted", each and (how == "bought" and "Average of what you paid in your last 30 days of buying it."
							or "What it costs to make, at the reagent prices you paid (today's for any you didn't buy).") or "No purchase or craft on record: gathered, looted or a reward.") } }
					elseif j == 6 and un and each > 0 then
						return { { "Unrealized" }, { "Worth against paid", string.format("%+d%%", math.floor((e.unit - each) / each * 100 + 0.5)) },
							{ T.Color("muted", "Not profit until it sells. The Balance Sheet carries the lower of the two, after the AH cut.") } }
					elseif j == 7 then
						local lines = { { "Last sold" } }
						if ls then
							table.insert(lines, { "Last sale", string.format("%s x%d at %s", LUI.Ago(ls.time, now), ls.quantity or 1, money(ls.price)) })
						else table.insert(lines, { "Last sale", T.Color("muted", "none on record") }) end
						table.insert(lines, { "Sold in 7 days", tostring(sold7[e.id] or 0) })
						table.insert(lines, { "Sold in 30 days", string.format("%d (%.1f a day)", sold30[e.id] or 0, perDay) })
						local sold, expired = 0, 0
						if L.SellThrough then sold, expired = L.SellThrough(e.id) end
						if (sold or 0) + (expired or 0) > 0 then
							table.insert(lines, { "Sell-through, 30 days", string.format("%d%% (%d sold, %d expired)", math.floor(sold / (sold + expired) * 100 + 0.5), sold, expired) })
						end
						local rate = CH.Expect and CH.Expect.RegionRate and CH.Expect.RegionRate(e.id)
						local perDayRegion = CH.Advisor and CH.Advisor.SoldPerDay and CH.Advisor.SoldPerDay(e.id)
						if perDayRegion then table.insert(lines, { "Region sold a day", string.format("%.1f", perDayRegion) }) end
						if rate then table.insert(lines, { "Region sale rate", string.format("%d%%", math.floor(rate * 100 + 0.5)) }) end
						table.insert(lines, { T.Color("muted", "Your own sales, from TSM. The region figures are TSM's market data for every seller.") })
						return lines
					elseif j == 8 then
						if not days then
							return { { "Days of stock" }, { "Sold in 30 days", "0" }, { T.Color("muted", "Insufficient sales history: nothing sold in 30 days, so how long this lasts can't be estimated.") } }
						end
						return { { "Days of stock" }, { "Sold in 30 days", tostring(sold30[e.id] or 0) }, { T.Color("muted", "How long what you hold lasts at that rate.") } }
					end
					return { { ({ "", "", "", "Worth each", "Value" })[j] or "" }, { T.Color("muted", "AuctionIQ value (market) per item, and for all you hold.") } }
				end })
		end
		return out, "Total value: " .. money(total) .. "   Unrealized on what has a cost: " .. signed(gain)
			.. CH.Theme.Color("muted", "   Hover Held for where it is.")
	end

	if v == "sales" or v == "purchases" then
		local n, total = 0, 0
		for _, r in ipairs(L.Records(v == "sales" and "Sales" or "Buys")) do
			if keepRec(r) then
				local text, name = LUI.ItemText(r.id)
				if keepName(name) then
					n, total = n + r.quantity, total + r.amount
					table.insert(out, { id = r.id, cells = { text, r.player or "?", r.source or "", r.quantity, money(r.price), money(r.amount), LUI.Ago(r.time, now) },
						sort = { name, r.player or "", r.source or "", r.quantity, r.price, r.amount, now - r.time } })
				end
			end
		end
		return out, string.format("%d items %s: %s", n, v == "sales" and "sold" or "bought", money(total))
	end

	if v == "income" or v == "expense" then
		local total, transfers = 0, 0
		for _, r in ipairs(L.Records(v == "income" and "Income" or "Expense")) do
			if keepRec(r) and keepName(r.source) then
				local own = mine[r.other]
				if own then transfers = transfers + r.amount else total = total + r.amount end
				local other = own and CH.Theme.Color("muted", r.other .. " (yours)") or (r.other or "")
				table.insert(out, { cells = { r.source or "?", r.player or "?", other, money(r.amount), LUI.Ago(r.time, now) },
					sort = { r.source or "", r.player or "", r.other or "", r.amount, now - r.time } })
			end
		end
		local foot = "Total: " .. money(total)
		if transfers > 0 then foot = foot .. CH.Theme.Color("muted", "   (plus " .. money(transfers) .. " moved between your characters)") end
		return out, foot
	end

	if v == "pl" then
		local rows = L.ProductPL(since, opts.char)
		local rev, prof, lines = 0, 0, {}
		for _, e in ipairs(rows) do
			local text, name = LUI.ItemText(e.id)
			if keepName(name) or keepName(e.line) then
				rev, prof = rev + e.revenue, prof + e.profit
				lines[e.line] = (lines[e.line] or 0) + e.profit
				local est = e.paidShare < 0.5 and CH.Theme.Color("muted", "*") or ""
				table.insert(out, { id = e.id, cells = { text, e.line, e.sold, money(e.revenue), money(e.cost) .. est, signed(e.profit),
					string.format("%d%%", math.floor(e.margin * 100 + 0.5)) },
					sort = { name, e.line, e.sold, e.revenue, e.cost, e.profit, e.margin } })
			end
		end
		local best, bv
		for l, g in pairs(lines) do if not bv or g > bv then best, bv = l, g end end
		return out, string.format("Crafted sales %s, profit %s%s", money(rev), signed(prof),
			best and ("   best line: " .. best .. " " .. money(bv)) or "")
			.. CH.Theme.Color("muted", "   * mostly today's prices: you bought few of its reagents")
	end

	if v == "perf" then
		local made, sold, rev, exp, real, fc = 0, 0, 0, 0, 0, 0
		for _, e in ipairs(CH.Forecast.Performance(opts.days and since or 0)) do
			local text, name = LUI.ItemText(e.id)
			if keepName(name) then
				made, sold, rev, real, fc = made + e.made, sold + e.sold, rev + e.revenue, real + e.realized, fc + e.forecast
				exp = exp + (e.expectEach and e.expectEach * e.sold or 0)
				local acc = e.accuracy and (e.accuracy - 1)
				table.insert(out, { id = e.id, cells = { text, e.made, e.sold, money(e.expectEach), money(e.actualEach),
					acc and CH.Theme.Color(acc >= -0.05 and "ok" or "bad", string.format("%+d%%", math.floor(acc * 100 + 0.5))) or CH.Theme.Color("muted", "-"),
					e.days and string.format("%.1f", e.days) or CH.Theme.Color("muted", "-"), signed(e.realized) },
					sort = { name, e.made, e.sold, e.expectEach or 0, e.actualEach or 0, acc or 0, e.days or 1e9, e.realized } })
			end
		end
		if made == 0 then
			return out, CH.Theme.Color("muted", "Nothing yet: every craft from now on saves its forecast, and sales are matched to it oldest first.")
		end
		local acc = exp > 0 and string.format("%+d%%", math.floor((rev / exp - 1) * 100 + 0.5)) or "-"
		return out, string.format("%d made, %d sold   Sold %s vs forecast   Realized %s (forecast %s)", made, sold, acc, signed(real), money(fc))
	end

	if v == "holdings" then
		local gain = 0
		for _, e in ipairs(L.Holdings(now, opts.char)) do
			local text, name = LUI.ItemText(e.id)
			if keepName(name) then
				gain = gain + e.gain
				table.insert(out, { id = e.id, cells = { text, e.held, money(e.paid), money(e.now),
					CH.Theme.Color(e.pct >= 0 and "ok" or "bad", string.format("%+d%%", math.floor(e.pct * 100 + 0.5))), signed(e.gain),
					e.daysOfStock and string.format("%.0f", e.daysOfStock) or CH.Theme.Color("muted", "no sales") },
					sort = { name, e.held, e.paid, e.now, e.pct, e.gain, e.daysOfStock or math.huge } })
			end
		end
		return out, "Unrealized gain on stock you bought: " .. signed(gain)
	end

	if v == "overhead" then
		local o = L.Overhead(since, opts.char)
		local span = math.max(1, (now - (opts.days and since or (now - 365 * 86400))) / 86400)
		for _, t in ipairs(o.types) do
			if keepName(t.type) then
				table.insert(out, { cells = { t.type, t.n, money(t.gold), money(t.gold / span),
					o.total > 0 and string.format("%d%%", math.floor(t.gold / o.total * 100 + 0.5)) or "" },
					sort = { t.type, t.n, t.gold, t.gold / span, t.gold } })
			end
		end
		return out, string.format("Trading profit %s, overhead %s, after overhead %s", signed(o.profit), money(-o.total), signed(o.afterOverhead))
	end


	-- expired / cancelled
	-- TSM doesn't record the deposit, so it's estimated from the vendor price and the item's duration
	local n, lost = 0, 0
	for _, r in ipairs(L.Records(v == "expired" and "Expired" or "Cancelled")) do
		if keepRec(r) then
			local text, name = LUI.ItemText(r.id)
			if keepName(name) then
				local d = r.id and CH.Expect.LostDeposit(r.id, r.quantity) or 0
				n, lost = n + r.quantity, lost + d
				table.insert(out, { id = r.id, cells = { text, r.player or "?", r.quantity, d > 0 and money(d) or CH.Theme.Color("muted", "-"),
					LUI.Ago(r.time, now) }, sort = { name, r.player or "", r.quantity, d, now - r.time } })
			end
		end
	end
	return out, string.format("%d items %s, about %s in deposits lost", n, v, money(lost))
		.. CH.Theme.Color("muted", "   estimated from vendor price and listing length")
end

local function sortRows(rows, col, desc)
	table.sort(rows, function(a, b)
		local x, y = a.sort[col], b.sort[col]
		if x == y then return (a.sort[1] or "") < (b.sort[1] or "") end
		if type(x) ~= type(y) then x, y = tostring(x), tostring(y) end
		if desc then return x > y end
		return x < y
	end)
	return rows
end

-- Building ------------------------------------------------------------------------------------
local function setView(v)
	if VIEWS[v] and VIEWS[v].go then return VIEWS[v].go() end
	if v ~= view then focus = nil; selected = nil; said = nil end
	-- a profession picked in Compare crafts means nothing to other views: keep just the character
	if char and char:find("#", 1, true) and not (VIEWS[v] and VIEWS[v].charChoices) then char = char:match("^[^#]+") end
	view, offset = v, 0
	lastView[section] = v
	if VIEWS[v].parent then lastIn[VIEWS[v].parent] = v end
	sortCol, sortDesc = VIEWS[v].sort, not VIEWS[v].asc
	CH.UI.Refresh()
end

local function pick(owner, title, list, onPick)
	if MenuUtil and MenuUtil.CreateContextMenu then
		MenuUtil.CreateContextMenu(owner, function(_, root)
			root:CreateTitle(title)
			for _, e in ipairs(list) do
				root:CreateRadio(e[1], function() return e.selected end, function() onPick(e[2]) end)
			end
		end)
	else -- no menus (tests): step to the next choice
		for i, e in ipairs(list) do
			if e.selected then return onPick((list[i % #list + 1])[2]) end
		end
		onPick(list[1][2])
	end
end

function LUI.Build(p, fs, panel)
	local T = CH.Theme
	page = p
	TW = math.max(BASE_TW, math.floor((p:GetWidth() or (X0 + BASE_TW)) - X0))
	TWT = TW
	sortCol, sortDesc = VIEWS[view].sort, not VIEWS[view].asc
	local nav = panel(p, 0, 0, 160, p:GetHeight() or 552)
	p.navPanel = nav
	p.nav = {}
	for sec, list in pairs(SECTIONS) do
	local y = -8
	local group
	for _, n in ipairs(list) do
	-- a tab with sub-tabs (Operations, Accounting): its group headings are the sub-tabs across the
	-- top, and the nav lists only the open sub-tab's views, each flush left from the top
	if list.tabbed and not n.sub then group, y = n[1], -8 else
			local sub = n.sub and not list.tabbed
			local target = n[2] or n[1]
			local label = VIEWS[n[1]] and VIEWS[n[1]].label or n[1]
			if n[2] and y ~= -8 then y = y - 6 end -- breathing room before each group
			local b = T.Button(nav, label, sub and 120 or 144, sub and 18 or 20)
			b:SetPoint("TOPLEFT", sub and 32 or 8, y)
			b:SetScript("OnClick", function() setView(target) end)
			b.view, b.parent, b.sub, b.section, b.guide = n[1], not sub and n[2] and n[1] or false, sub or false, sec, false
			-- left-aligned labels: groups flush left, their views indented under a guide line
			local f = b.text or (b.GetFontString and b:GetFontString())
			if f then
				f:ClearAllPoints()
				f:SetPoint("LEFT", 8, 0)
				f:SetPoint("RIGHT", -4, 0)
				f:SetJustifyH("LEFT")
				if sub and f.SetFontObject then f:SetFontObject("GameFontHighlightSmall") end
				-- one line always: a label too long for the button gets the smaller font, never a
				-- second line running into the next button
				CH.Window.OneLine(f)
				local room = (sub and 120 or 144) - 12
				if f.GetStringWidth and f:GetStringWidth() > room and f.SetFontObject then f:SetFontObject("GameFontHighlightSmall") end
				b.fits = not (f.GetStringWidth and f:GetStringWidth() > room)
			end
			if sub then
				local c = T.line
				local v = nav:CreateTexture(nil, "ARTWORK")
				v:SetColorTexture(c[1], c[2], c[3], 1)
				v:SetPoint("TOPLEFT", nav, "TOPLEFT", 18, y + 3)
				v:SetSize(1, 21)
				local h = nav:CreateTexture(nil, "ARTWORK")
				h:SetColorTexture(c[1], c[2], c[3], 1)
				h:SetPoint("TOPLEFT", nav, "TOPLEFT", 18, y - 9)
				h:SetSize(12, 1)
				b.guide = { v, h }
			end
			local mark = b:CreateTexture(nil, "OVERLAY")
			mark:SetPoint("TOPLEFT", 1, -1)
			mark:SetPoint("BOTTOMLEFT", 1, 1)
			mark:SetWidth(2)
			b.mark = mark
			b:HookScript("OnLeave", function(self)
				local fs, c = self.text or (self.GetFontString and self:GetFontString()), self.navColor
				if fs and c then fs:SetTextColor(c[1], c[2], c[3]) end
			end)
			table.insert(p.nav, b)
			y = y - (sub and 21 or 25)
			b.group = list.tabbed and group or nil
		end
	end
	end
	-- the table and its controls; hidden while the Report shows in their place
	local body = CreateFrame("Frame", nil, p)
	body:SetAllPoints(p)
	p.body = body

	local search = CreateFrame("EditBox", nil, body, "InputBoxTemplate")
	search:SetSize(250, 20)
	search:SetPoint("TOPLEFT", X0 + 6, -4)
	search:SetAutoFocus(false)
	search:SetScript("OnTextChanged", function(self)
		local t = self:GetText() or ""
		if t == filter then return end
		filter = t; offset = 0
		if focus and t ~= (focus.name or "") then focus = nil end
		CH.UI.Refresh()
	end)
	p.search = search
	search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	p.hint = fs(body, X0 + 10, -8, 200, "LEFT", "GameFontDisableSmall")
	search:SetScript("OnEditFocusGained", function() p.hint:SetText("") end)
	search:SetScript("OnEditFocusLost", function(self) if (self:GetText() or "") == "" then p.hint:SetText("Filter by name") end end)
	p.hint:SetText("Filter by name")

	p.charButton = T.Button(body, "All characters", 150, 20)
	p.charButton:SetPoint("TOPLEFT", X0 + 268, -4)
	p.charButton:SetScript("OnClick", function(self)
		local list = { { "All characters", false, selected = char == nil } }
		local own = VIEWS[view] and VIEWS[view].charChoices
		if own then
			for _, e in ipairs(own()) do table.insert(list, { e[1], e[2], selected = char == e[2] }) end
		else
			for _, c in ipairs(CH.Ledger.Characters()) do table.insert(list, { c.name, c.name, selected = char == c.name }) end
		end
		pick(self, own and "Character and profession" or "Character", list, function(v) char = v or nil; offset = 0; CH.UI.Refresh() end)
	end)
	p.timeButton = T.Button(body, "Last 30 Days", 110, 20)
	p.timeButton:SetPoint("TOPLEFT", X0 + 424, -4)
	p.timeButton:SetScript("OnClick", function(self)
		local list = {}
		for _, t in ipairs(TIMES) do table.insert(list, { t[1], t[2] or false, selected = days == t[2] }) end
		pick(self, "Time frame", list, function(v) days = v or nil; offset = 0; CH.UI.Refresh() end)
	end)

	-- a view's own settings (Scenarios: how far reagents rise, prices fall): left-click up, right-click down
	p.controls = {}
	for i, x in ipairs({ 424, 614 }) do
		local b = T.Button(body, "", 104, 20)
		b:SetPoint("TOPLEFT", X0 + x, -4)
		if b.RegisterForClicks then b:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
		b:SetScript("OnClick", function(self, button)
			local c = VIEWS[view].controls and VIEWS[view].controls[i]
			if c then c.click(button == "RightButton" and -1 or 1); CH.UI.Refresh() end
		end)
		b:SetScript("OnEnter", function(self)
			local c = VIEWS[view].controls and VIEWS[view].controls[i]
			if c and c.tip then CH.Window.Tooltip(self, { { c.tip }, { "Left-click raises it, right-click lowers it." } }) end
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		b:Hide()
		p.controls[i] = b
	end

	p.exportButton = T.Button(body, "Export", 70, 20)
	p.exportButton:SetPoint("TOPLEFT", X0 + 540, -4)
	p.exportButton:SetScript("OnClick", function() CH.Export.Export(view, { filter = filter, char = char, days = days }) end)
	-- a view's own action in Export's place (Compare crafts: scan your professions)
	p.actionButton = T.Button(body, "", 70, 20)
	p.actionButton:SetPoint("TOPLEFT", X0 + 540, -4)
	T.Primary(p.actionButton)
	p.actionButton:SetScript("OnClick", function()
		local a = VIEWS[view] and VIEWS[view].action
		if not a then return end
		local ok, msg = a.click()
		said = msg and { ok = ok, msg = msg } or nil
		CH.UI.Refresh()
	end)
	p.actionButton:SetScript("OnEnter", function(self)
		local a = VIEWS[view] and VIEWS[view].action
		if a and a.tip then CH.Window.Tooltip(self, a.tip()) end
	end)
	p.actionButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
	p.actionButton:Hide()

	-- sortable headers
	p.heads = {}
	for j = 1, 8 do
		local h = CreateFrame("Button", nil, body)
		h:SetHeight(16)
		h.text = fs(h, 0, -2, 10, "LEFT", "GameFontNormalSmall")
		h:SetScript("OnClick", function()
			if sortCol == j then sortDesc = not sortDesc else sortCol, sortDesc = j, j ~= 1 end
			CH.UI.Refresh()
		end)
		-- a short code heading (MV, RV, EV, RZ) explains itself on hover
		h:SetScript("OnEnter", function(self)
			local say = self.code and CH.GLOSSARY and CH.GLOSSARY[self.code]
			if say then CH.Window.Tooltip(self, { { CH.Theme.Color("accent", self.code) }, { say } }) end
		end)
		h:SetScript("OnLeave", function() GameTooltip:Hide() end)
		p.heads[j] = h
	end
	-- rows, each with a hover area for the item's tooltip
	p.rows = {}
	for i = 1, MAX_ROWS do
		local r = { cells = {} }
		local hit = CreateFrame("Button", nil, body)
		hit:SetPoint("TOPLEFT", X0, -50 - (i - 1) * RH)
		hit:SetSize(TW, RH)
		hit:SetScript("OnEnter", function(self)
			-- a row with cell tips explains the column under the cursor (OnUpdate follows it across)
			if self.cellTip then self.col = nil; return LUI.ShowCellTip(self) end
			-- a row can carry its own explanation (tip lines); else the item's tooltip
			if self.tip then
				local lines = type(self.tip) == "function" and self.tip() or self.tip
				if lines and lines[1] then CH.Window.Tooltip(self, lines) end
			elseif self.id and GameTooltip.SetItemByID and not ((LUI.quietUntil or 0) > (GetTime and GetTime() or 0)) then
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetItemByID(self.id)
				GameTooltip:Show()
			end
		end)
		hit:SetScript("OnLeave", function(self) self.col = nil; GameTooltip:Hide() end)
		hit:SetScript("OnUpdate", function(self)
			if self.cellTip and self.col and self.IsMouseOver and self:IsMouseOver() then LUI.ShowCellTip(self) end
		end)
		hit:SetScript("OnClick", function(self)
			-- a statement line opens the transactions behind it
			if self.go then return CH.UI.Go(self.go[1], self.go[2]) end
			if VIEWS[view] and VIEWS[view].detail and self.key then LUI.Select(self.key) end
		end)
		local bg = hit:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.03 or 0)
		r.bg, r.zebra = bg, i % 2 == 0 and 0.03 or 0
		r.hit = hit
		for j = 1, 10 do r.cells[j] = fs(body, 0, -52 - (i - 1) * RH, 10) end
		p.rows[i] = r
	end
	-- the selected row's detail, in a panel right of the table, for a view that has one: a kicker, a
	-- headline, three figures, label and value rows, a section of rows (each explains itself on hover),
	-- a note, and buttons from the bottom up (the first, the main one, lowest)
	local det = CH.Window.SidePanel(body, SIDE, ROWS * RH + 20, { rows = 7, srows = 6, onAction = function(self)
		local ok, msg = self.run()
		said = msg and { ok = ok, msg = msg } or nil
		CH.UI.Refresh()
	end })
	det:Hide()
	p.detail = det
	p.footer = fs(body, X0, -52 - ROWS * RH - 8, TW, "CENTER", "GameFontNormal")
	p.bar = CH.Window.ScrollBar(body, X0 + TW - 3, -50, ROWS * RH, true)
	LUI.SetRows(ROWS)
	p:EnableMouseWheel(true)
	p:SetScript("OnMouseWheel", function(_, delta) offset = math.max(0, offset - delta * 5); CH.UI.Refresh() end)
end

--- Redraw. Returns the rows shown (all of them, sorted) and the footer, for tests.
function LUI.Refresh()
	local p = page
	if not p then return {} end
	local T = CH.Theme
	local v = VIEWS[view]
	-- a view with a detail panel gives the table's right side to it
	TWT = v.detail and (TW - SIDE - 8) or TW
	for _, b in ipairs(p.nav) do
		local mine = b.section == section and (not b.group or b.group == v.parent)
		b:SetShown(mine)
		if b.guide then for _, g in ipairs(b.guide) do g:SetShown(mine) end end
	end
	p.body:SetShown(not v.page)
	for _, b in ipairs(p.nav) do
		local on = b.view == view or (b.parent and v.parent == b.parent)
		local f = b.text or (b.GetFontString and b:GetFontString())
		-- group names always read gold; the open view also gets a gold bar on its left edge
		local c = (on or not b.sub) and T.accent or T.fg
		b.navColor = c
		if f and f.SetTextColor then f:SetTextColor(c[1], c[2], c[3]) end
		if b.mark then
			b.mark:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 1)
			b.mark:SetShown(b.view == view)
		end
	end
	if v.page then
		if p.detail then p.detail:Hide(); LUI.lastDetail = nil end
		return {}, ""
	end
	local charLabel = char and (v.charLabel and v.charLabel(char) or char:match("^[^#]+")) or "All characters"
	if p.charButton.text then p.charButton.text:SetText(charLabel) end
	for _, t in ipairs(TIMES) do if t[2] == days and p.timeButton.text then p.timeButton.text:SetText(t[1]) end end
	p.timeButton:SetShown(view ~= "inventory" and not (VIEWS[view] and VIEWS[view].noTime))

	local act = v.action
	p.actionButton:SetShown(act ~= nil)
	p.exportButton:SetShown(act == nil)
	if act then
		local f = p.actionButton.text or (p.actionButton.GetFontString and p.actionButton:GetFontString())
		if f then f:SetText(act.label()) end
		p.actionButton.label = act.label()
	end
	for i, b in ipairs(p.controls) do
		local c = v.controls and v.controls[i]
		if c then
			local f = b.text or (b.GetFontString and b:GetFontString())
			if f then f:SetText(c.label()) end
			b.label = c.label()
		end
		b:SetShown(c ~= nil)
	end
	for j, h in ipairs(p.heads) do
		local c = v.cols[j]
		if c then
			h:ClearAllPoints()
			h:SetPoint("TOPLEFT", X0 + colX(c), -32)
			h:SetWidth(cellWidth(c))
			h.text:SetWidth(cellWidth(c))
			h.text:SetJustifyH(j == 1 and "LEFT" or "RIGHT")
			local arrow = sortCol == j and (sortDesc and " v" or " ^") or ""
			h.text:SetText((sortCol == j and T.Color("accent", c[1] .. arrow)) or c[1])
			h.code = c[1]
			h:Show()
		else
			h:Hide()
		end
	end

	local rows, footer = {}, ""
	if CH.Ledger.Available() then
		rows, footer = LUI.Rows(view, { filter = filter, char = char, days = view ~= "inventory" and days or nil, focus = focus })
		if not v.fixed then sortRows(rows, sortCol or 1, sortDesc) end -- a statement keeps its own order
	end
	local SHOWN = ROWS
	offset = math.max(0, math.min(offset, #rows - SHOWN))
	if p.bar then
		if p.bar.SetX then p.bar:SetX(X0 + TWT - 3) end
		p.bar:Set(offset, SHOWN, #rows)
		if p.bar.SetLength then p.bar:SetLength(SHOWN * RH) end
	end
	local function keyOf(d) return d.key or (tostring(d.id) .. ":" .. tostring(d.cells[1]) .. ":" .. tostring(d.cells[2])) end
	local sel
	if v.detail then
		for _, d in ipairs(rows) do if keyOf(d) == selected then sel = d end end
		if not sel and rows[1] then sel = rows[1]; selected = keyOf(sel); said = nil end
	end
	for i, r in ipairs(p.rows) do
		local d = i <= SHOWN and rows[i + offset] or nil
		r.hit:SetShown(i <= SHOWN)
		r.hit:SetWidth(TWT)
		r.hit.id = d and d.id
		r.hit.tip = d and d.tip
		r.hit.cellTip = d and d.cellTip
		r.hit.key = d and keyOf(d)
		r.hit.go = d and d.go
		if r.bg then r.bg:SetColorTexture(1, 1, 1, (sel and d == sel) and 0.14 or r.zebra) end
		for j, cell in ipairs(r.cells) do
			local c = v.cols[j]
			if c and d then
				cell:ClearAllPoints()
				cell:SetPoint("TOPLEFT", X0 + colX(c), -52 - (i - 1) * RH)
				cell:SetWidth(cellWidth(c))
				cell:SetJustifyH(j == 1 and "LEFT" or "RIGHT")
				cell:SetText(tostring(d.cells[j] or ""))
			else
				cell:SetText("")
			end
		end
	end
	local more = #rows > SHOWN and T.Color("muted", string.format("   rows %d-%d of %d, scroll for more", offset + 1, math.min(#rows, offset + SHOWN), #rows)) or ""
	LUI.DrawDetail(p, v, sel, SHOWN)
	if p.search and (p.search:GetText() or "") ~= filter then
		p.search:SetText(filter)
		p.hint:SetText(filter == "" and "Filter by name" or "")
	end
	if focus and CH.Ledger.Available() then footer = LUI.FocusText(focus) .. "   " .. footer end
	p.footer:SetText(CH.Ledger.Available() and (footer .. more) or T.Color("muted", "Needs TradeSkillMaster."))
	return rows, footer
end

--- The column (its index in the open view) at x pixels from the table's left edge.
function LUI.ColumnAt(x)
	local v = VIEWS[view]
	local at = 1
	for j, c in ipairs(v and v.cols or {}) do if x >= colX(c) - 2 then at = j end end
	return at
end

--- A row's tooltip for the column under the cursor: the first column shows the item, the others what
--- the number is and how it was worked out (row.cellTip(j) gives the lines). Redraws only when the
--- cursor moves to another column. Returns the column.
function LUI.ShowCellTip(hit, j)
	if not j then
		local x = GetCursorPosition and GetCursorPosition() or 0
		local scale = hit.GetEffectiveScale and hit:GetEffectiveScale() or 1
		j = LUI.ColumnAt(x / (scale > 0 and scale or 1) - (hit.GetLeft and hit:GetLeft() or 0))
	end
	if j == hit.col then return j end
	hit.col = j
	local lines = j > 1 and hit.cellTip and hit.cellTip(j)
	if lines and lines[1] then
		CH.Window.Tooltip(hit, lines)
	elseif j == 1 and hit.id and GameTooltip.SetItemByID and not ((LUI.quietUntil or 0) > (GetTime and GetTime() or 0)) then
		GameTooltip:SetOwner(hit, "ANCHOR_RIGHT")
		GameTooltip:SetItemByID(hit.id)
		GameTooltip:Show()
	else
		GameTooltip:Hide()
	end
	return j
end

--- Select a row of a view with a detail pane, by its key; the pane shows it.
function LUI.Select(key)
	if key ~= selected then said = nil end
	selected = key
	CH.UI.Refresh()
end
function LUI.Selected() return selected end

--- Draw the detail pane for the selected row, under the table's `shown` rows. Returns what it drew
--- ({ title, lines, actions }), for tests.
function LUI.DrawDetail(p, v, sel, shown)
	local det = p and p.detail
	if not det then return nil end
	if not (v.detail and sel) then det:Hide(); LUI.lastDetail = nil; return nil end
	local ok, d = pcall(v.detail, sel, { focus = focus })
	if not ok or not d then det:Hide(); LUI.lastDetail = nil; return nil end
	det:ClearAllPoints()
	det:SetPoint("TOPLEFT", X0 + TW - SIDE, -32)
	det:SetHeight(ROWS * RH + 20)
	local busy = v.action and v.action.status and v.action.status()
	CH.Window.DrawSidePanel(det, d, busy and CH.Theme.Color("accent", busy) or said and CH.Theme.Color(said.ok and "ok" or "bad", said.msg) or "")
	LUI.lastDetail = d
	return d
end

--- How many table rows to show (the window got taller or shorter). Returns the count.
function LUI.SetRows(n)
	ROWS = math.max(10, math.min(MAX_ROWS, n or ROWS))
	local p = page
	if p and p.footer then
		p.footer:ClearAllPoints()
		p.footer:SetPoint("TOPLEFT", X0, -52 - ROWS * RH - 8)
		if p.bar and p.bar.SetLength then p.bar:SetLength(ROWS * RH) end
		for i, r in ipairs(p.rows) do
			r.hit:SetShown(i <= ROWS)
			if i > ROWS then for _, c in ipairs(r.cells) do c:SetText("") end end
		end
	end
	return ROWS
end

--- An item's stock target (Trade's item panel): shift-click raises an item's target by 1, ctrl-click lowers it, alt-click goes
--- back to the automatic one (a week of sales).
function LUI.ParClick(id, mod)
	mod = mod or (IsAltKeyDown and IsAltKeyDown() and "alt") or (IsControlKeyDown and IsControlKeyDown() and "ctrl")
		or (IsShiftKeyDown and IsShiftKeyDown() and "shift")
	local cur = CH.Par.Target(id) or 0
	if mod == "alt" then CH.Par.Set(id, nil)
	elseif mod == "ctrl" then CH.Par.Set(id, cur - 1)
	elseif mod == "shift" then CH.Par.Set(id, cur + 1) end
	CH.UI.Refresh()
	return CH.Par.Target(id)
end

--- Which tab's views the page shows: "ledger" (Accounting) or "operations".
function LUI.SetSection(sec)
	if not SECTIONS[sec] then return end
	if section ~= sec then
		section = sec
		view, offset = lastView[sec], 0
		sortCol, sortDesc = VIEWS[view].sort, not VIEWS[view].asc
	end
end
function LUI.Section() return section end
function LUI.View() return view end
--- The Character picker's choice (nil for all characters).
function LUI.Char() return char end
--- The tab a view lives in.
function LUI.SectionOf(v)
	for sec, list in pairs(SECTIONS) do for _, n in ipairs(list) do if n[1] == v then return sec end end end
	return VIEWS[v] and VIEWS[v].section
end

--- The line a handed-over recommendation puts over a view's footer.
function LUI.FocusText(f)
	local T = CH.Theme
	local what = (f.qty and f.qty > 0 and (f.qty .. " x ") or "") .. (f.name or "")
	return T.Color("accent", "From Dashboard: " .. (f.title or "") .. (what ~= "" and (", " .. what) or ""))
		.. (f.char and T.Color("muted", " on " .. f.char) or "")
end
--- What the open view was handed (nil when nothing was, or you've moved on).
function LUI.Focus() return focus end

--- Switch the view, filters and sort from code (tests, slash commands). opts.focus hands over a
--- recommendation: { name, id, char, qty, title }; the view opens filtered to its name.
function LUI.Set(opts)
	if opts.view and opts.view ~= view then focus = nil; selected = nil; said = nil end
	if opts.focus then
		focus = opts.focus
		-- the page opens under the cursor: hold the item tooltip a moment so it doesn't cover the pane
		LUI.quietUntil = (GetTime and GetTime() or 0) + 1.5
		if opts.filter == nil then opts.filter = focus.name or "" end
	end
	if opts.view and VIEWS[opts.view] then
		section = LUI.SectionOf(opts.view) or section
		view = opts.view; lastView[section] = view
		if VIEWS[view].parent then lastIn[VIEWS[view].parent] = view end
		sortCol = VIEWS[view].sort; sortDesc = not VIEWS[view].asc
	end
	if opts.filter ~= nil then filter = opts.filter end
	if opts.char ~= nil then char = opts.char or nil end
	if opts.days ~= nil then days = opts.days or nil end
	if opts.sort then sortCol, sortDesc = opts.sort, opts.desc end
	offset = 0
end

-- Item names arrive from the server a moment after first asked for: redraw once they do.
local pending
CH.On("GET_ITEM_INFO_RECEIVED", function()
	if pending or not (page and page:IsShown()) then return end
	pending = true
	C_Timer.After(0.3, function() pending = nil; if page and page:IsShown() then CH.UI.Refresh() end end)
end)
