-- Analytics: what is working, why, and what should change. Each view answers one question and ends
-- in what to do about it:
--   Performance          which lines and characters make the profit, and what changed
--   Profit drivers       did profit move because of price, volume or cost
--   Forecast accuracy    expected against observed (LedgerUI's "perf")
--   Capital efficiency   where gold is tied up against what it earns
--   Crafting efficiency  gold per Concentration point and per crafting hour, procs against expected
--   Scenarios            what reagent or selling price changes would do to each craft
--   Gold per hour        LedgerUI's "time"
--   Craft results        Research/Log.lua
-- Profit here is realized: crafted items' sales after the cut, less reagents at what you paid
-- (Ledger.ProductPL). Comparisons are against the period of the same length just before.
local _, CH = ...

local AV = {}
CH.AnalyticsViews = AV
local LUI = CH.LedgerUI
local DAY = 86400

local function money(c) return LUI.Money(c) end
local function signed(c) return LUI.Signed(c) end
local function pct(x) return x and string.format("%d%%", math.floor(x * 100 + 0.5)) or CH.Theme.Color("muted", "-") end

-- The period a view looks at, and the one before it: all-time compares the last 30 days.
local function periods(ctx)
	local now = ctx.now
	local start = ctx.since > -math.huge and ctx.since or now - 30 * DAY
	local len = now - start
	return start, start - len, len
end

-- Product P&L for [from, to): ProductPL counts everything since a time, so subtract.
local function plBetween(from, to, char)
	local L = CH.Ledger
	local a, b = {}, {}
	for _, e in ipairs(L.ProductPL(from, char)) do a[e.id] = e end
	for _, e in ipairs(L.ProductPL(to, char)) do b[e.id] = e end
	local out = {}
	for id, e in pairs(a) do
		local later = b[id]
		local sold = e.sold - (later and later.sold or 0)
		if sold > 0 then
			local revenue = e.revenue - (later and later.revenue or 0)
			out[id] = { id = id, line = e.line, sold = sold, revenue = revenue, cost = e.each * sold, profit = revenue - e.each * sold, each = e.each }
		end
	end
	return out
end
AV.PLBetween = plBetween

local function plSince(since, char)
	local out = {}
	for _, e in ipairs(CH.Ledger.ProductPL(since, char)) do out[e.id] = e end
	return out
end

-- An item's category: its product line when crafted, else its top group, else Other.
local function category(id, crafted)
	local c = crafted and crafted[id]
	if c and CH.Paths and CH.Paths.MainGroup then
		local line = CH.Paths.MainGroup(c.name)
		if line then return line end
	end
	local path = CH.Groups and CH.Groups.Path(id)
	return path and path:match("^([^/]+)") or "Other"
end

local function needLedger(out)
	if CH.Ledger.Available() then return nil end
	return out, CH.Theme.Color("muted", "Needs TradeSkillMaster: it reads your sales and inventory.")
end

-- Performance ---------------------------------------------------------------------------------
function AV.Performance(ctx)
	local start, before = periods(ctx)
	local now, prev = plSince(start), plBetween(before, start)
	local by = {} -- [kind .. name] = { kind, name, sold, revenue, profit, prev }
	local total, totalPrev = 0, 0
	local function add(kind, name, e, field)
		local k = kind .. "|" .. name
		local x = by[k] or { kind = kind, name = name, sold = 0, revenue = 0, profit = 0, prev = 0 }
		by[k] = x
		if field == "now" then x.sold, x.revenue, x.profit = x.sold + e.sold, x.revenue + e.revenue, x.profit + e.profit
		else x.prev = x.prev + e.profit end
	end
	for _, e in pairs(now) do add("Line", e.line or "Other", e, "now"); total = total + e.profit end
	for _, e in pairs(prev) do add("Line", e.line or "Other", e, "prev"); totalPrev = totalPrev + e.profit end
	for _, c in ipairs(CH.Ledger.Characters()) do
		for _, e in pairs(plSince(start, c.name)) do add("Character", c.name, e, "now") end
		for _, e in pairs(plBetween(before, start, c.name)) do add("Character", c.name, e, "prev") end
	end
	local out = {}
	for _, x in pairs(by) do
		if ctx.keepName(x.name) then table.insert(out, x) end
	end
	return out, total, totalPrev
end

local function performanceRows(ctx)
	local out = {}
	if needLedger(out) then return needLedger(out) end
	local list, total, totalPrev = AV.Performance(ctx)
	local T = CH.Theme
	local up, down
	for _, x in ipairs(list) do
		local change = x.profit - x.prev
		if x.kind == "Line" then
			if not up or change > up.change then up = { name = x.name, change = change } end
			if not down or change < down.change then down = { name = x.name, change = change } end
		end
		table.insert(out, { cells = { x.name, T.Color("muted", x.kind), x.sold, money(x.revenue), signed(x.profit), money(x.prev), signed(change),
			total > 0 and pct(x.profit / total) or T.Color("muted", "-") },
			sort = { x.name, x.kind, x.sold, x.revenue, x.profit, x.prev, change, x.profit } })
	end
	if not out[1] then return out, T.Color("muted", "No crafted sales in this time frame. Sales of items your scans know how to make count here.") end
	local foot = string.format("Profit %s, %s before (%s).", signed(total), money(totalPrev), signed(total - totalPrev))
	if up and up.change > 0 then foot = foot .. "  Up most: " .. up.name .. " " .. signed(up.change) .. "." end
	if down and down.change < 0 then foot = foot .. "  Down most: " .. down.name .. " " .. signed(down.change) .. ", see Profit drivers." end
	return out, foot
end

-- Profit drivers ------------------------------------------------------------------------------
--- Why an item's profit changed between the periods. With p = price each, q = units sold and
--- c = cost each: price effect (p1 - p0) x q1, volume effect (q1 - q0) x (p0 - c0), cost effect
--- -(c1 - c0) x q1. They add up to the change. Costs come from what you paid for the reagents, so
--- the cost effect is usually small; quality and procs show in Crafting efficiency.
function AV.Drivers(ctx)
	local start, before = periods(ctx)
	local now, prev = plSince(start), plBetween(before, start)
	local ids = {}
	for id in pairs(now) do ids[id] = true end
	for id in pairs(prev) do ids[id] = true end
	local out = {}
	for id in pairs(ids) do
		local a, b = prev[id], now[id]
		local q0, q1 = a and a.sold or 0, b and b.sold or 0
		local p0 = a and a.revenue / a.sold or (b and b.revenue / b.sold) or 0
		local p1 = b and b.revenue / b.sold or p0
		local c0 = a and a.each or (b and b.each) or 0
		local c1 = b and b.each or c0
		local x = { id = id, now = b and b.profit or 0, before = a and a.profit or 0 }
		x.change = x.now - x.before
		x.price = (p1 - p0) * q1
		x.volume = (q1 - q0) * (p0 - c0)
		x.cost = -(c1 - c0) * q1
		local big, name = 0, "-"
		for _, k in ipairs({ "price", "volume", "cost" }) do
			if math.abs(x[k]) > math.abs(big) then big, name = x[k], k end
		end
		x.driver, x.big = name, big
		table.insert(out, x)
	end
	return out
end

local DRIVER = { price = "selling price", volume = "how many sold", cost = "reagent cost" }

local function driverRows(ctx)
	local out = {}
	if needLedger(out) then return needLedger(out) end
	local T = CH.Theme
	local sums = { price = 0, volume = 0, cost = 0 }
	for _, x in ipairs(AV.Drivers(ctx)) do
		local text, name = LUI.ItemText(x.id)
		if ctx.keepName(name) then
			for k in pairs(sums) do sums[k] = sums[k] + x[k] end
			local why = x.driver == "-" and T.Color("muted", "no change")
				or T.Color(x.big >= 0 and "ok" or "bad", (x.big >= 0 and "up on " or "down on ") .. DRIVER[x.driver])
			table.insert(out, { id = x.id, cells = { text, signed(x.now), money(x.before), signed(x.change), signed(x.price), signed(x.volume),
				signed(x.cost), why },
				sort = { name, x.now, x.before, x.change, x.price, x.volume, x.cost, math.abs(x.change) } })
		end
	end
	if not out[1] then return out, T.Color("muted", "No crafted sales in either period to compare.") end
	return out, string.format("Against the period before: price %s, volume %s, cost %s.", signed(sums.price), signed(sums.volume), signed(sums.cost))
		.. T.Color("muted", "  Estimated: each split holds the other two still.")
end

-- Capital efficiency ----------------------------------------------------------------------------
--- Per category: gold tied up in stock (at AuctionIQ value) against the profit it made in the
--- period, and how many days of sales the stock is.
function AV.Capital(ctx)
	local start, _, len = periods(ctx)
	local crafted = CH.Ledger.Crafted()
	local by, held, earned = {}, 0, 0
	local function cat(name)
		local x = by[name] or { name = name, value = 0, profit = 0, revenue = 0 }
		by[name] = x
		return x
	end
	for _, e in ipairs(CH.Ledger.Inventory(nil, ctx.opts.char)) do
		if e.id and e.value > 0 then
			local x = cat(category(e.id, crafted))
			x.value, held = x.value + e.value, held + e.value
		end
	end
	for _, e in pairs(plSince(start, ctx.opts.char)) do
		local x = cat(category(e.id, crafted))
		x.profit, x.revenue, earned = x.profit + e.profit, x.revenue + e.revenue, earned + e.profit
	end
	local days = len / DAY
	local out = {}
	for _, x in pairs(by) do
		x.valueShare = held > 0 and x.value / held or 0
		x.profitShare = earned > 0 and math.max(0, x.profit) / earned or 0
		x.daysOfStock = x.revenue > 0 and x.value / (x.revenue / days) or nil
		x.turn = x.value > 0 and x.profit / x.value or nil -- profit per gold held, this period
		if ctx.keepName(x.name) then table.insert(out, x) end
	end
	return out, held, earned
end

local function capitalRows(ctx)
	local out = {}
	if needLedger(out) then return needLedger(out) end
	local T = CH.Theme
	local list, held, earned = AV.Capital(ctx)
	local worst
	for _, x in ipairs(list) do
		local verdict
		if x.value > 0 and x.valueShare >= 0.05 and x.valueShare > 2 * x.profitShare then
			verdict = T.Color("bad", "ties up gold: see Dead stock")
			if not worst or x.valueShare - x.profitShare > worst.gap then worst = { x = x, gap = x.valueShare - x.profitShare } end
		elseif x.profitShare > x.valueShare then verdict = T.Color("ok", "earns its keep")
		else verdict = T.Color("muted", "in line") end
		table.insert(out, { cells = { x.name, money(x.value), pct(x.valueShare), signed(x.profit), pct(x.profitShare),
			x.daysOfStock and string.format("%.0f", x.daysOfStock) or T.Color("muted", "no sales"), x.turn and pct(x.turn) or T.Color("muted", "-"), verdict },
			sort = { x.name, x.value, x.valueShare, x.profit, x.profitShare, x.daysOfStock or math.huge, x.turn or -math.huge, x.valueShare - x.profitShare } })
	end
	if not out[1] then return out, T.Color("muted", "Nothing held and nothing sold in this time frame.") end
	local foot = string.format("%s held, %s profit in this time frame.", money(held), signed(earned))
	if worst then
		foot = foot .. string.format("  %s holds %s of your stock's value but made %s of the profit.", worst.x.name, pct(worst.x.valueShare), pct(worst.x.profitShare))
	end
	return out, foot
end

-- Crafting efficiency ---------------------------------------------------------------------------
--- Per recipe from the craft log: output at market per craft, gold per Concentration point spent,
--- and how the procs compare with what the advisor expected.
function AV.Crafting(ctx)
	local out = {}
	for _, d in ipairs(CH.Log.AllRows()) do
		if ctx.keepName(d.name) then
			d.each = d.crafts > 0 and d.actual / d.crafts or 0
			d.perPoint = d.concSpent and d.concSpent > 0 and d.concActual and d.concActual / d.concSpent or nil
			table.insert(out, d)
		end
	end
	return out
end

local function rate(a, b)
	if not a then return CH.Theme.Color("muted", "-") end
	local s = pct(a)
	if b then s = CH.Theme.Color(a + 0.02 >= b and "ok" or "bad", s) .. CH.Theme.Color("muted", " / " .. pct(b)) end
	return s
end

local function craftingRows(ctx)
	local T = CH.Theme
	local out = {}
	local crafts, made = 0, 0
	for _, d in ipairs(AV.Crafting(ctx)) do
		crafts, made = crafts + d.crafts, made + d.actual
		table.insert(out, { cells = { d.name or "?", d.char, d.crafts, signed(d.each), d.perPoint and money(d.perPoint) or T.Color("muted", "no Conc."),
			rate(d.mcRate, d.expMcRate), rate(d.resRate, d.expResRate), rate(d.ingRate, d.expIngRate) },
			sort = { d.name or "", d.char, d.crafts, d.each, d.perPoint or -math.huge, d.mcRate or 0, d.resRate or 0, d.ingRate or 0 } })
	end
	local x = CH.Planner and CH.Planner.Time(ctx.since > -math.huge and ctx.since or ctx.now - 30 * DAY)
	local hours = x and x.kinds and x.kinds.Crafting or 0
	local start = periods(ctx)
	local profit = 0
	if CH.Ledger.Available() then for _, e in pairs(plSince(start)) do profit = profit + e.profit end end
	local perHour = hours > 0 and string.format("  %s realized profit per crafting hour (%.1f hours with a profession open).", signed(profit / hours), hours) or ""
	if not out[1] then return out, T.Color("muted", "Nothing logged yet. Every craft is recorded, on each character.") .. perHour end
	return out, string.format("%d crafts, %s at market.", crafts, money(made)) .. perHour
		.. T.Color("muted", "  Procs: what you got / what was expected.")
end

-- Scenarios ----------------------------------------------------------------------------------
AV.SCENARIO = { reagents = 0.10, price = 0.10 } -- the defaults; yours are saved in CH.db.scenario
AV.STEPS = { 0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.40, 0.50 }

--- The scenario you set: { reagents = 0.15, price = 0.10 }.
function AV.Scenario()
	local s = CH.db and CH.db.scenario
	return { reagents = s and s.reagents or AV.SCENARIO.reagents, price = s and s.price or AV.SCENARIO.price }
end

--- Set how far reagents rise and selling prices fall (fractions, 0 to 1). nil keeps one.
function AV.SetScenario(r, p)
	local cur = AV.Scenario()
	r = math.max(0, math.min(1, r or cur.reagents))
	p = math.max(0, math.min(1, p or cur.price))
	CH.db.scenario = { reagents = r, price = p }
	return CH.db.scenario
end

-- the next step up (dir 1) or down (dir -1) from x
local function step(x, dir)
	local S = AV.STEPS
	if dir > 0 then
		for _, v in ipairs(S) do if v > x + 1e-9 then return v end end
		return S[#S]
	end
	for i = #S, 1, -1 do if S[i] < x - 1e-9 then return S[i] end end
	return S[1]
end

--- What price changes would do to each craft in your saved scans: profit a craft now, with reagents
--- up, with the selling price down, both, and the reagent rise that would wipe the profit out.
--- Estimated from the scan: value a craft = profit + reagent cost.
function AV.Scenarios(ctx, r, p)
	local sc = AV.Scenario()
	r, p = r or sc.reagents, p or sc.price
	local out = {}
	for key, c in pairs(CH.db.characters or {}) do
		for _, prof in pairs(c.professions or {}) do
			for _, row in ipairs(prof.scan and prof.scan.rows or {}) do
				-- each character's own scan: their stats make each craft's numbers
				if row.profit and row.cost and row.cost > 0 and row.profit > 0 and ctx.keepName(row.name) then
					local value = row.profit + row.cost
					table.insert(out, { id = row.item, name = row.name, char = c.name or key, profit = row.profit,
						reagentsUp = row.profit - r * row.cost, priceDown = row.profit - p * value,
						both = row.profit - r * row.cost - p * value, breakEven = row.profit / row.cost })
				end
			end
		end
	end
	return out
end

local function scenarioRows(ctx)
	local T = CH.Theme
	local out, fragile = {}, 0
	for _, x in ipairs(AV.Scenarios(ctx)) do
		if x.both < 0 then fragile = fragile + 1 end
		table.insert(out, { id = x.id, cells = { x.name, x.char, signed(x.profit), signed(x.reagentsUp), signed(x.priceDown), signed(x.both),
			T.Color(x.breakEven < 0.2 and "bad" or x.breakEven < 0.5 and "fg" or "ok", "+" .. pct(x.breakEven)),
			x.both < 0 and T.Color("bad", "loses money") or T.Color("ok", "holds up") },
			sort = { x.name, x.char, x.profit, x.reagentsUp, x.priceDown, x.both, x.breakEven, x.both } })
	end
	if not out[1] then return out, T.Color("muted", "Scan a profession first: scenarios use your saved scans' profitable crafts.") end
	local sc = AV.Scenario()
	return out, string.format("Reagents +%d%%, selling price -%d%%. %d of %d crafts lose money if both happen.",
		math.floor(sc.reagents * 100 + 0.5), math.floor(sc.price * 100 + 0.5), fragile, #out)
		.. T.Color("muted", "  Break-even: how far reagents can rise before the craft stops paying. Estimated from your scans.")
end

AV.VIEWS = {
	performance = { label = "Performance", sort = 5, rows = performanceRows, cols = { { "Line or character", 0, 180 }, { "", 184, 70 },
		{ "Sold", 258, 44 }, { "Revenue", 306, 84 }, { "Profit", 394, 84 }, { "Before", 482, 80 }, { "Change", 566, 80 }, { "Share", 650, 74 } } },
	drivers = { label = "Profit drivers", sort = 8, rows = driverRows, cols = { { "Item", 0, 180 }, { "Profit", 184, 76 }, { "Before", 264, 76 },
		{ "Change", 344, 76 }, { "Price", 424, 70 }, { "Volume", 498, 70 }, { "Cost", 572, 60 }, { "Driver", 636, 88 } } },
	capital = { label = "Capital efficiency", sort = 8, rows = capitalRows, cols = { { "Category", 0, 140 }, { "Held", 144, 84 },
		{ "Of stock", 232, 56 }, { "Profit", 292, 84 }, { "Of profit", 380, 60 }, { "Days stock", 444, 64 }, { "Per gold", 512, 56 }, { "", 572, 152 } } },
	crafting = { label = "Crafting efficiency", sort = 3, noTime = true, rows = craftingRows, cols = { { "Recipe", 0, 170 }, { "Character", 174, 80 },
		{ "Crafts", 258, 44 }, { "Per craft", 306, 80 }, { "Per Conc. pt", 390, 80 }, { "Multicraft", 474, 80 }, { "Resourceful", 558, 84 },
		{ "Ingenuity", 646, 78 } } },
	scenarios = { label = "Scenarios", sort = 7, asc = true, noTime = true, rows = scenarioRows, cols = { { "Craft", 0, 170 }, { "Character", 174, 76 },
		{ "Profit now", 254, 76 }, { "Reagents +10%", 334, 86 }, { "Price -10%", 424, 76 }, { "Both", 504, 70 }, { "Break-even", 578, 70 },
		{ "", 652, 72 } } },
}

-- Scenarios' two settings, as buttons over the table; the column headings follow them
local function pctOf(x) return math.floor(x * 100 + 0.5) end
local function label(kind)
	local sc = AV.Scenario()
	local cols = AV.VIEWS.scenarios.cols
	cols[4][1] = string.format("Reagents +%d%%", pctOf(sc.reagents))
	cols[5][1] = string.format("Price -%d%%", pctOf(sc.price))
	return kind == "reagents" and string.format("Reagents +%d%%", pctOf(sc.reagents)) or string.format("Price -%d%%", pctOf(sc.price))
end
AV.VIEWS.scenarios.controls = {
	{ label = function() return label("reagents") end, tip = "How far reagent prices rise in this scenario.",
		click = function(dir) AV.SetScenario(step(AV.Scenario().reagents, dir), nil) end },
	{ label = function() return label("price") end, tip = "How far your selling prices fall in this scenario.",
		click = function(dir) AV.SetScenario(nil, step(AV.Scenario().price, dir)) end },
}

-- Gold per hour and Craft results register their own definitions; this sets the order.
LUI.Register("research", AV.VIEWS, { "performance", "drivers", "perf", "capital", "crafting", "scenarios", "time", "results" }, "Performance")
