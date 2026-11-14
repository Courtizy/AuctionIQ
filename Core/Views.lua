-- Analytics: what is working, why, and what should change. Each view answers one question and ends
-- in what to do about it:
--   Performance          which lines and characters make the profit, and what changed
--   Profit drivers       did profit move because of price, volume or cost
--   Forecast accuracy    expected against observed (LedgerUI's "perf")
--   Capital efficiency   where gold is tied up against what it earns
--   Crafting efficiency  gold per Concentration point and per crafting hour, procs against expected
--   Scenarios            what reagent or selling price changes would do to each craft
--   Craft results        Accounting/Log.lua
--   Batch results        each batch you queued: forecast against actual, and which of sale price,
--                        sell-through, reagent cost or yield made the difference (Forecast.Explain)
-- Profit here is crafted items' real sales after the cut, less reagents at what you paid for them
-- around the time of each sale (Ledger.ProductPL): an estimate of cost, since bought reagents
-- aren't tracked batch by batch. Comparisons are against the period of the same length just before.
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
			-- each sale was costed at its own time, so the period's cost is the difference too (not
			-- the whole span's average cost times the period's units)
			local revenue = e.revenue - (later and later.revenue or 0)
			local cost = e.cost - (later and later.cost or 0)
			out[id] = { id = id, line = e.line, sold = sold, revenue = revenue, cost = cost, profit = revenue - cost, each = cost / sold }
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
AV.Category = category

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
	local now, prev
	-- opened from Performance's chart: its exact windows, on the Income Statement's basis
	local range = ctx.opts and ctx.opts.focus and ctx.opts.focus.range
	if range and CH.Statements and CH.Statements.Items then
		now = CH.Statements.Items(range.from, range.to - 1, ctx.opts.char)
		prev = CH.Statements.Items(range.pfrom, range.pto - 1, ctx.opts.char)
	else
		local start, before = periods(ctx)
		now, prev = plSince(start), plBetween(before, start)
	end
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
	local range = ctx.opts.focus and ctx.opts.focus.range
	return out, string.format("%s: price %s, volume %s, cost %s.", range and (range.label .. " against " .. range.prior) or "Against the period before",
		signed(sums.price), signed(sums.volume), signed(sums.cost))
		.. T.Color("muted", "  Estimated: each split holds the other two still.")
end

-- Capital efficiency ----------------------------------------------------------------------------
--- Per category: gold tied up in stock (at AuctionIQ value) against the profit it made in the
--- period, and how many days of sales the stock is (units held over units sold a day, so a price
--- change between buying and selling doesn't skew it).
function AV.Capital(ctx)
	local start, _, len = periods(ctx)
	local crafted = CH.Ledger.Crafted()
	local by, held, earned = {}, 0, 0
	local function cat(name)
		local x = by[name] or { name = name, value = 0, profit = 0, revenue = 0, units = 0, sold = 0 }
		by[name] = x
		return x
	end
	for _, e in ipairs(CH.Ledger.Inventory(nil, ctx.opts.char)) do
		if e.id and e.value > 0 then
			local x = cat(category(e.id, crafted))
			x.value, held = x.value + e.value, held + e.value
			x.units = x.units + (e.total or 0)
		end
	end
	for _, e in pairs(plSince(start, ctx.opts.char)) do
		local x = cat(category(e.id, crafted))
		x.profit, x.revenue, earned = x.profit + e.profit, x.revenue + e.revenue, earned + e.profit
		x.sold = x.sold + (e.sold or 0)
	end
	local days = len / DAY
	local out = {}
	for _, x in pairs(by) do
		x.valueShare = held > 0 and x.value / held or 0
		x.profitShare = earned > 0 and math.max(0, x.profit) / earned or 0
		x.daysOfStock = x.sold > 0 and x.units / (x.sold / days) or nil
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

--- What a craft's money is made of, from its saved scan (Decide.AccountParts): revenue, reagents
--- consumed, what Resourcefulness gives back, and deposits lost to expiries.
function AV.Parts(row) return CH.Decide.AccountParts(row) end

--- A craft's profit with reagents up r and the selling price down p (fractions): Decide.Reprice.
function AV.Reprice(parts, r, p) return CH.Decide.Reprice(parts, r, p) end

--- What price changes would do to each craft in your saved scans: profit a craft now, with reagents
--- up, with the selling price down, both, and the reagent rise that would wipe the profit out.
function AV.Scenarios(ctx, r, p)
	local sc = AV.Scenario()
	r, p = r or sc.reagents, p or sc.price
	local out = {}
	for key, c in pairs(CH.db.characters or {}) do
		for pid, prof in pairs(c.professions or {}) do
			for _, row in ipairs(prof.scan and prof.scan.rows or {}) do
				-- each character's own scan: their stats make each craft's numbers
				if row.profit and row.cost and row.cost > 0 and row.profit > 0 and ctx.keepName(row.name) then
					local parts = AV.Parts(row)
					local now = AV.Reprice(parts, 0, 0)
					local net = parts.consumed - parts.returned
					local be = CH.Decide.BreakEvenParts(parts, parts.price)
					table.insert(out, { id = row.item, name = row.name, char = c.name or key, charKey = key, c = c, row = row,
						prof = prof.name, profID = pid, scanAt = prof.scan.at, profit = now,
						reagentsUp = AV.Reprice(parts, r, 0), priceDown = AV.Reprice(parts, 0, p), both = AV.Reprice(parts, r, p),
						breakEven = net > 0 and now / net or math.huge,
						-- the sale price per item where the craft makes nothing, and how far the estimate can fall
						salePrice = be and be.price, estimate = be and be.estimate, cushion = be and be.cushion, priceFrom = parts.priceFrom,
						-- how many to make (Decide.Suggest), from this scan
						suggest = CH.Decide.Suggest(CH.Decide.ScanInputs(row), { fall = p }) })
				end
			end
		end
	end
	return out
end

--- Compare crafts: what each column is and how this craft's number was worked out, for its hover.
--- Columns: 2 character, 3 profit now, 4 reagents up, 5 price down, 6 both, 7 break-even, 8 room, 9 make.
function AV.ScenarioTip(x, j)
	local T, M = CH.Theme, CH.FormatMoney
	local sc = AV.Scenario()
	local r, p = sc.reagents, sc.price
	local parts = AV.Parts(x.row)
	local net = parts.consumed - parts.returned
	local function head(t, say) return { { T.Color("accent", t) }, { T.Color("muted", say) } } end
	local function add(out, label, v, sign) table.insert(out, { label, (sign and v >= 0 and "+" or "") .. M(v) }) end
	-- the craft's money now: revenue after the cut, deposits, reagents, what Resourcefulness gives back
	local function now(out)
		add(out, "Revenue after the AH cut" .. (x.row.accounts and x.row.accounts.mcGold and x.row.accounts.mcGold > 0 and ", Multicraft in" or ""), parts.revenue)
		if parts.deposits >= 1 then add(out, "Deposits lost to expiries", -parts.deposits) end
		add(out, "Reagents used", -parts.consumed)
		if parts.returned >= 1 then add(out, "Resourcefulness gives back", parts.returned, true) end
	end
	local pctR, pctP = math.floor(r * 100 + 0.5), math.floor(p * 100 + 0.5)
	local out
	if j == 2 then
		local age = x.scanAt and CH.Scans and CH.Scans.Age(time() - x.scanAt) or "?"
		out = head("Character", "Whose scan this is. Their skill, Multicraft and Resourcefulness make this craft's numbers.")
		table.insert(out, { string.format("%s, %s, scanned %s ago", x.char or "?", x.prof or "?", age) })
	elseif j == 3 then
		out = head("Profit now", "Profit a craft at today's prices, from the last scan.")
		now(out)
		add(out, "Profit a craft", x.profit, true)
		-- the reagents you hold: what crafting gives up by not selling them
		for _, l in ipairs(CH.CraftOrSellBook(x.row and (x.row.item ~= x.id and x.row.concAccounts or x.row.accounts))) do table.insert(out, l) end
	elseif j == "up" then
		out = head(string.format("Reagents +%d%%", pctR), "Profit a craft if reagent prices rise this much. Resourcefulness gives back more too. Change it with the button above.")
		add(out, "Profit now", x.profit, true)
		add(out, string.format("Reagents used, +%d%%", pctR), -parts.consumed * r)
		if parts.returned >= 1 then add(out, string.format("Resourcefulness back, +%d%%", pctR), parts.returned * r, true) end
		add(out, "Profit a craft", x.reagentsUp, true)
	elseif j == "down" then
		out = head(string.format("Price -%d%%", pctP), "Profit a craft if your selling price falls this much. Deposits stay the same. Change it with the button above.")
		add(out, "Profit now", x.profit, true)
		add(out, string.format("Revenue, -%d%%", pctP), -p * (parts.revenue + parts.deposits))
		add(out, "Profit a craft", x.priceDown, true)
	elseif j == "both" then
		out = head("Both", string.format("Reagents +%d%% and price -%d%% together: the downside case.", pctR, pctP))
		add(out, "Profit now", x.profit, true)
		add(out, string.format("Reagents used, +%d%%", pctR), -parts.consumed * r)
		if parts.returned >= 1 then add(out, string.format("Resourcefulness back, +%d%%", pctR), parts.returned * r, true) end
		add(out, string.format("Revenue, -%d%%", pctP), -p * (parts.revenue + parts.deposits))
		add(out, "Profit a craft", x.both, true)
	elseif j == 4 then
		out = head("Break-even per item", "The sale price per item where this craft makes nothing, and how far today's estimate can fall before it does.")
		if x.salePrice then
			add(out, "Estimated sale price", x.estimate or 0)
			add(out, "Costs to cover a craft", parts.deposits + net)
			add(out, "Revenue at the estimate, before deposits", parts.revenue + parts.deposits)
			table.insert(out, { "Break-even = estimate x costs / revenue", M(x.salePrice) })
			table.insert(out, { "The estimate can fall", pct(x.cushion) })
			if x.priceFrom ~= "scan" then
				table.insert(out, { T.Color("muted", "This scan didn't save its sale price, so this uses " .. (x.priceFrom == "market" and "today's market price" or "the price worked back from what an item keeps")
					.. ". Rescan the profession for the exact figure.") })
			end
		else
			table.insert(out, { T.Color("muted", "This scan is older and didn't save a sale price. Scan the profession again.") })
		end
	elseif j == 5 then
		out = head("Cushion", "How far today's estimated sale price can fall before this craft stops paying.")
		if x.salePrice and x.estimate then
			add(out, "Estimated sale price", x.estimate)
			add(out, "Break-even per item", x.salePrice)
			table.insert(out, { "Cushion = 1 - break-even / estimate", pct(x.cushion) })
		else
			table.insert(out, { T.Color("muted", "This scan is older and didn't save a sale price. Scan the profession again.") })
		end
	elseif j == "room" then
		out = head("Room", "How far reagent prices can rise before this craft stops paying.")
		add(out, "Profit now", x.profit, true)
		add(out, "Reagents, less what Resourcefulness gives back", net)
		table.insert(out, { "Room = profit / reagents", x.breakEven == math.huge and "any" or ("+" .. pct(x.breakEven)) })
	elseif j == 6 then
		local sg = x.suggest
		out = head("Make", "How many to craft: the biggest batch that still pays back if it sells slowly, without piling up stock.")
		if sg then
			table.insert(out, { CH.Decide.SuggestText(sg) })
			if sg.n > 0 and sg.why then table.insert(out, { T.Color("muted", sg.why) }) end
		else
			table.insert(out, { T.Color("muted", "No sale price in this scan, so no batch size.") })
		end
	end
	return out
end

local function scenarioRows(ctx)
	local T = CH.Theme
	local out, fragile = {}, 0
	for _, x in ipairs(AV.Scenarios(ctx)) do
		if x.both < 0 then fragile = fragile + 1 end
		local sg = x.suggest
		local make = not sg and T.Color("muted", "-") or sg.n == 0 and T.Color(sg.limit == "rate" and "muted" or "bad", sg.limit == "rate" and "-" or "0") or tostring(sg.n)
		table.insert(out, { id = x.id, key = (x.charKey or "") .. ":" .. tostring(x.row and x.row.recipeID) .. ":" .. tostring(x.id), x = x,
			cells = { x.name, x.char, signed(x.profit), x.salePrice and money(x.salePrice) or T.Color("muted", "older scan"),
				x.cushion and T.Color(x.cushion < 0.1 and "bad" or "fg", pct(x.cushion)) or T.Color("muted", "-"), make },
			sort = { x.name, x.char, x.profit, x.salePrice or math.huge, x.cushion or -math.huge, sg and sg.n or -1 },
			cellTip = function(j) return AV.ScenarioTip(x, j) end })
	end
	if not out[1] then return out, T.Color("muted", "Scan a profession first: scenarios use your saved scans' profitable crafts.") end
	local sc = AV.Scenario()
	return out, string.format("Reagents +%d%%, selling price -%d%%. %d of %d crafts lose money if both happen.",
		math.floor(sc.reagents * 100 + 0.5), math.floor(sc.price * 100 + 0.5), fragile, #out)
		.. T.Color("muted", "  Hover a number for how it was worked out. The panel shows the selected craft's scenarios.")
end

-- Craft detail -------------------------------------------------------------------------------
-- The selected craft in Operations > Craft > Compare crafts: the same result the Crafting Advisor
-- shows when that recipe is open in the profession window (live), else the last scan, labelled with
-- its character and age. How many to make, what it costs and risks, whether Concentration is worth
-- it, and what a knowledge plan changes; its buttons queue the batch and save the decision.

--- The live advisor result for a recipe, if the profession window has it open: result, row.
function AV.LiveFor(recipeID)
	local a = CH.AdvisorUI and CH.AdvisorUI.Current and CH.AdvisorUI.Current()
	if not (a and recipeID and a.recipeID == recipeID and not a.order and not a.sim) then return nil end
	if ProfessionsFrame and ProfessionsFrame.IsShown and not ProfessionsFrame:IsShown() then return nil end
	return a, (CH.AdvisorUI.SelectedRow and CH.AdvisorUI.SelectedRow()) or a.best
end

--- What a knowledge plan does to this craft: { from, to, char } or nil.
function AV.PlanFor(item)
	for _, sum in pairs(CH.db.plans or {}) do
		for _, r in ipairs(sum.rows or {}) do
			local saves = r.concQ and r.fromConc and r.toConc and r.fromConc - r.toConc >= 1 and math.floor(r.fromConc - r.toConc + 0.5) or nil
			local qUp = r.fromQ and r.toQ and r.toQ > r.fromQ and r.toQ or nil
			if r.id == item and (saves or qUp or (r.toProfit and r.fromProfit and math.abs(r.toProfit - r.fromProfit) >= 1)) then
				return { from = r.fromProfit, to = r.toProfit, char = sum.char, label = sum.label, saves = saves, quality = qUp }
			end
		end
	end
end

--- A plan's effect on one recipe, in a line: "This plan saves 12 Concentration a craft", "... makes it
--- Q2 without Concentration", else its profit now and planned.
function AV.PlanText(plan)
	local M = CH.FormatMoney
	local name = "Your plan (" .. (plan.label or "Paths") .. ")"
	local d = plan.from and plan.to and plan.to - plan.from
	local more = d and math.abs(d) >= 1 and string.format(", %s%s a craft", d >= 0 and "+" or "", M(d)) or ""
	if plan.quality then return string.format("%s makes it Q%d without Concentration%s.", name, plan.quality, more) end
	if plan.saves then return string.format("%s saves %d Concentration a craft%s.", name, plan.saves, more) end
	return string.format("%s takes it from %s to %s a craft.", name, M(plan.from or 0), M(plan.to or 0))
end

--- Rescan the profession a Compare crafts row came from. Returns ok, what happened.
function AV.Rescan(x)
	local open = CH.OpenProfessionID and CH.OpenProfessionID()
	local me = CH.CharacterKey and CH.CharacterKey()
	if x.charKey ~= me then return false, "That scan is " .. (x.char or "?") .. "'s: log in as them, open " .. (x.prof or "the profession") .. ", then rescan." end
	if not open or (x.profID and open ~= x.profID) then return false, "Open " .. (x.prof or "the profession") .. " first (a crafting table for the best numbers), then rescan." end
	if not (CH.ScanUI and CH.ScanUI.Start) then return false, "The scanner isn't loaded." end
	CH.ScanUI.Start()
	return true, "Scanning " .. (x.prof or "the profession") .. ": this list updates when it finishes."
end

--- Queue a batch of a scanned craft and save the decision behind it. Returns ok, what happened.
function AV.QueueScan(x, n, conc, inp, plan)
	local e = CH.Queue and CH.Queue.FromScan(x.charKey, x.c, x.row, conc)
	if not e then return false, "This scan is too old to queue from: scan the profession again." end
	CH.Queue.AddEntry(e, n)
	if inp and CH.Forecast and CH.Forecast.SaveDecision then
		local sc = CH.Decide.Scenarios(inp, n).expected
		CH.Forecast.SaveDecision({ item = e.item, recipe = x.row.recipeID, name = x.name, char = x.char, quality = e.quality, conc = conc or nil,
			n = n, itemsEach = CH.Decide.ItemsPerCraft(inp), costEach = sc.cost / n, priceEach = inp.price, netEach = sc.each,
			daily = inp.daily, leftWeek = sc.left, profit = sc.items * sc.each - sc.cost, source = "the last scan", from = "craft", plan = plan })
	end
	return true, string.format("Queued %d x %s%s for %s", n, x.name or "?", conc and " with Concentration" or "", x.char or "?")
end

-- Concentration picked in the Craft pane, by row: it outlasts a redraw, not a reload.
local concChoice = {}
local function rowKey(x) return (x.charKey or "") .. ":" .. tostring(x.row and x.row.recipeID) .. ":" .. tostring(x.id) end

--- The one craft the Craft pane shows, queues and forecasts, so the three never disagree: the live
--- advisor result while the profession window has the recipe open, else the last scan. Carries the
--- character, quality, Concentration choice, batch size (crafts), its inputs and the data's age.
--- focus is a Dashboard handoff: { name, qty, unit = "crafts" | "items", conc }.
function AV.Selection(x, focus)
	local row = x.row
	local canConc = (row.concProfit and row.concAccounts and row.concentration and row.concentration > 0) and true or false
	local f = focus and focus.name == x.name and focus or nil
	local key = rowKey(x)
	-- a choice made in the pane holds until a new hand-off arrives with its own
	local ch = concChoice[key]
	local conc
	if ch and ch.focus == focus then conc = ch.on else conc = (f and f.conc) and true or false end
	conc = conc and canConc
	local live, lr = AV.LiveFor(row.recipeID)
	if live then
		-- the live row for the same choice: the advisor's pick when it matches, else its best of that kind
		if conc then lr = (lr and lr.concentration) and lr or live.bestConc
		else lr = (lr and not lr.concentration) and lr or live.best end
		if not lr then live = nil end
	end
	local inp, sug
	if live then
		local b = CH.AdvisorUI.BatchFor(live, lr)
		inp, sug = b and b.inputs, b and b.suggest
	end
	inp = inp or CH.Decide.ScanInputs(row, conc) or (conc and nil) or CH.Decide.ScanInputs(row)
	sug = sug or (inp and CH.Decide.Suggest(inp, {}))
	-- the same quantity decision as the Craft card (can make, can afford, suggested), so what the
	-- pane suggests is what's saved beside the batch you queue
	local q = inp and CH.Decide.Quantity(inp, { suggest = sug, gold = GetMoney and GetMoney() or nil, noExplore = true }) or nil
	local made = inp and CH.Decide.ItemsPerCraft(inp) or 1
	-- how many crafts: the Dashboard's number (in items or crafts, as it said), else the suggestion
	local n, from
	if f and f.qty and f.qty > 0 then
		n = f.unit == "items" and math.max(1, math.ceil(f.qty / math.max(made, 0.01) - 1e-9)) or math.floor(f.qty)
		from = f.unit == "items" and string.format("%d items from %s", f.qty, f.title or "Dashboard") or (f.title or "Dashboard")
	else
		n = q and q.n > 0 and q.n or sug and sug.n > 0 and sug.n or 1
	end
	local profit = live and lr.profit or (conc and row.concProfit or row.profit)
	return { x = x, key = key, live = live, row = lr, conc = conc, canConc = canConc, n = n, from = from, made = made,
		inputs = inp, suggest = sug, quantity = q, profit = profit, quality = live and lr.quality or (conc and row.concQuality or row.quality),
		char = x.char, scanAt = x.scanAt, source = live and "live" or "scan" }
end

--- Use Concentration (or not) for a Compare crafts row. Returns the choice.
function AV.SetConc(x, on)
	local f = CH.LedgerUI and CH.LedgerUI.Focus and CH.LedgerUI.Focus()
	concChoice[rowKey(x)] = { on = on and true or false, focus = f }
	return on and true or false
end

--- Queue exactly what the pane shows and save the decision behind it. Returns ok, what happened.
function AV.QueueSelection(sel)
	local x, n = sel.x, sel.n
	if sel.live and sel.row and CH.AdvisorUI.QueueFrom then
		local e = CH.AdvisorUI.QueueFrom(sel.live, sel.row, n, "craft")
		if not e then return false, "The profession window didn't take that craft." end
		return true, string.format("Queued %d x %s (Q%d%s) for %s", n, x.name or "?", sel.row.quality or 0, sel.conc and ", Concentration" or "", x.char or "?")
	end
	return AV.QueueScan(x, n, sel.conc, sel.inputs, CH.Decide.PlanRecord(sel.quantity))
end

function AV.CraftDetail(d, ctx)
	local x = d.x
	if not x then return nil end
	local T, M = CH.Theme, CH.FormatMoney
	local sel = AV.Selection(x, ctx and ctx.focus)
	local live, inp, sug, n, row = sel.live, sel.inputs, sel.suggest, sel.n, x.row
	local age = x.scanAt and CH.Scans and CH.Scans.Age(time() - x.scanAt) or "?"
	local profit = sel.profit or 0
	local function gold(v) return v and M(math.floor(v / 10000 + 0.5) * 10000) or "-" end
	local function whole(v) return math.floor(v + 0.5) end
	-- every figure is for the n crafts shown, the same n the Queue button adds
	local sc = inp and CH.Decide.Scenarios(inp, n)
	local made = sel.made
	local figures = { { "PROFIT", T.Color(profit >= 0 and "ok" or "bad", gold(profit)) },
		{ "AT RISK", sc and T.Color("bad", gold(sc.slow.atRisk)) or T.Color("muted", "-") },
		{ "BREAK-EVEN", x.salePrice and T.Color("gold", gold(x.salePrice)) or T.Color("muted", "-") } }
	local rows = {}
	-- what you'll queue, and the suggestion beside it when they differ (both are saved with the batch)
	local q = sel.quantity
	local said = q and (q.action == "hold" and "hold off" or q.action == "skip" and "skip" or q.action == "trial" and ("try " .. q.n) or (q.action == "make" and tostring(q.n))) or nil
	local differs = q and (((q.action == "hold" or q.action == "skip") and n > 0) or ((q.action == "make" or q.action == "trial") and q.n ~= n))
	rows[#rows + 1] = { "Make", tostring(n) .. (said and differs and T.Color("muted", string.format("  (suggested %s)", said)) or "") }
	if sc then rows[#rows + 1] = { "Left after a week", string.format("%d · %d · %d", whole(sc.slow.left), whole(sc.expected.left), whole(sc.fast.left)) } end
	if x.cushion then rows[#rows + 1] = { "Estimate can fall", pct(x.cushion) } end
	if sel.canConc then
		local gain = (row.concProfit or 0) - (row.profit or 0)
		rows[#rows + 1] = { sel.conc and T.Color("accent", "Concentration on") or "Concentration off",
			gain > 0 and string.format("+%s a craft", M(gain)) or T.Color("muted", "doesn't pay") }
	end
	rows[#rows + 1] = { "Reagents for " .. n, M(sc and sc.expected.cost or (row.cost or 0) * n) }
	-- the price scenarios for this craft, each explaining itself on hover
	local s = AV.Scenario()
	local srows = { { "Profit now", signed(x.profit), tip = AV.ScenarioTip(x, 3) },
		{ string.format("Reagents +%d%%", math.floor(s.reagents * 100 + 0.5)), signed(x.reagentsUp), tip = AV.ScenarioTip(x, "up") },
		{ string.format("Price -%d%%", math.floor(s.price * 100 + 0.5)), signed(x.priceDown), tip = AV.ScenarioTip(x, "down") },
		{ "Both", signed(x.both), tip = AV.ScenarioTip(x, "both") },
		{ "Room to rise", x.breakEven == math.huge and "any" or ("+" .. pct(x.breakEven)), tip = AV.ScenarioTip(x, "room") } }
	local plan = AV.PlanFor(x.id)
	local why = sc and (sug and sug.why and (sug.why .. " ") or "") or (sug and sug.why) or "No sale price in this scan, so no batch size."
	if sel.from then why = "From " .. sel.from .. ". " .. why end
	local note = (plan and (AV.PlanText(plan) .. " ") or "") .. why
	local what = string.format("%d %s%s", n, n == 1 and "craft" or "crafts", sel.conc and " with Concentration" or "")
	local actions = { { label = "Queue " .. what,
		tip = "Add exactly this: " .. what .. " of " .. (x.name or "?") .. (live and ", the reagents and quality the profession window shows" or ", from " .. (x.char or "?") .. "'s scan")
			.. ". The forecast saved with it uses the same numbers as this panel.",
		run = function() return AV.QueueSelection(sel) end } }
	if sel.canConc then
		actions[2] = { label = sel.conc and "Plain instead" or "Use Concentration",
			tip = sel.conc and "Show and queue the plain craft instead." or "Show and queue the Concentration craft instead: the figures above change to it.",
			run = function() AV.SetConc(x, not sel.conc); return true, sel.conc and "Showing the plain craft." or "Showing the Concentration craft." end }
	end
	-- a fresh scan: only this character can rescan its own profession, at the profession window
	actions[#actions + 1] = { label = "Rescan " .. (x.prof or "profession"), tip = "Scan every recipe of " .. (x.prof or "this profession") .. " again with today's prices. "
		.. "Log in as " .. (x.char or "?") .. ", open the profession at a crafting table, then press this (or Scan in the profession window's AuctionIQ bar).",
		run = function() return AV.Rescan(x) end }
	return { kicker = live and "NEXT MOVE  ·  LIVE" or "NEXT MOVE", title = string.format("Craft %d x %s", n, x.name or "?"), item = x.id or false,
		sub = (live and T.Color("ok", "Live") or (T.Color("muted", string.format("%s, scanned %s ago", x.char or "?", age))))
			.. T.Color("muted", string.format("  ·  Q%s%s  ·  ~%d items", tostring(sel.quality or "?"), sel.conc and " Conc." or "", whole(n * made))),
		figures = figures, rows = rows, section = { head = "IF PRICES MOVE", rows = srows }, note = T.Color("muted", note),
		actions = actions, n = n, live = live ~= nil, selection = sel }
end

-- Batch results ------------------------------------------------------------------------------
AV.CAUSES = { { "price", "Sale price", "what each sold for against the forecast price" },
	{ "sell", "Sell-through", "sold more or fewer than the forecast rate says by now" },
	{ "reagents", "Reagent cost", "the reagents at craft time against the forecast" },
	{ "yield", "Craft yield", "items made against expected, as far as they could sell by now" } }

--- One line per cause and the takeaway, for a batch's hover.
function AV.ExplainLines(d, x)
	local T, M = CH.Theme, CH.FormatMoney
	local out = { { (d.name or "?") .. T.Color("muted", string.format("  %d of %d crafts, %d days since the first", d.crafts or 0, d.n or 0, math.floor(x.days + 0.5))) } }
	table.insert(out, { x.takeaway })
	table.insert(out, { "Forecast by now", M(x.forecast) })
	for _, c in ipairs(AV.CAUSES) do
		table.insert(out, { "  " .. c[2] .. T.Color("muted", "  " .. c[3]), signed(x.causes[c[1]]) })
	end
	table.insert(out, { "Actual by now", M(x.actual) })
	table.insert(out, { T.Color("muted", string.format("Sold %d of %d made (%.0f forecast by now, %.1f made a craft expected). %d left, worth %s at the forecast price.",
		x.sold, x.made, x.soldForecast, d.itemsEach or 0, x.left, M(x.leftWorth))) })
	if d.source then table.insert(out, { T.Color("muted", "Sell rate from " .. d.source .. "; reagents at market when crafted.") }) end
	-- only crafted units are credited: say how many sales went to stock you held or bought instead
	local other = CH.Forecast.OtherSold and CH.Forecast.OtherSold(d.item) or 0
	if other > 0 then
		table.insert(out, { T.Color("muted", string.format("%d sold of this item came out of stock you held or bought, so they aren't counted here.", other)) })
	end
	-- your plan, not the suggestion, is what the forecast measures; the suggestion's, for comparison
	local dep = x.departure
	if dep then
		table.insert(out, { T.Color("accent", dep.text) .. T.Color("muted", dep.strength and string.format("  (evidence: %s)", dep.strength) or "") })
		table.insert(out, { T.Color("muted", "  The forecast above is for the crafts you chose."), "" })
		if x.atSuggested and dep.kind ~= "against" then
			table.insert(out, { T.Color("muted", string.format("  At the suggested %d, by now", dep.suggested)) .. T.Color("muted", "  (modeled)"), M(x.atSuggested) })
		end
	elseif d.plan then
		table.insert(out, { T.Color("muted", "You queued what AuctionIQ suggested.") })
	end
	return out
end

local function batchRows(ctx)
	local T = CH.Theme
	local out = {}
	local fc, act, n = 0, 0, 0
	for _, d in ipairs(CH.Forecast.Decisions()) do
		local x = CH.Forecast.Explain(d, ctx.now)
		if x and ctx.keepName(d.name or "") then
			n, fc, act = n + 1, fc + x.forecast, act + x.actual
			local word = x.main and ({ price = "Sale price", sell = "Sell-through", reagents = "Reagent cost", yield = "Craft yield" })[x.main] or "On forecast"
			table.insert(out, { id = d.item, cells = { (d.name or "?") .. (d.conc and (" " .. CH.Window.ConcIcon(13)) or ""), d.char or "?",
				string.format("%d/%d", d.crafts, d.n), string.format("%d/%d", x.sold, x.made), money(x.forecast), money(x.actual), signed(x.miss),
				T.Color(x.main and (x.causes[x.main] >= 0 and "ok" or "bad") or "muted", word) },
				sort = { d.name or "", d.char or "", d.crafts, x.sold, x.forecast, x.actual, x.miss, x.main or "" },
				tip = function() return AV.ExplainLines(d, CH.Forecast.Explain(d)) end })
		end
	end
	if not out[1] then
		return out, T.Color("muted", "No batches yet. Queue a craft from the advisor, craft it, and its forecast against what really happens shows here.")
	end
	return out, string.format("%d batches: %s forecast by now, %s actual.", n, money(fc), money(act))
		.. T.Color("muted", "  Gold back from sales so far less reagents. Hover a batch for what made the difference.")
end

-- By profession: each profession's sales, profit and the stock it has made, and how fast stock turns
--- Per profession over the time frame: { name, sold, revenue, cost, profit, margin, held (what you hold
--- that it makes, at AuctionIQ value), turns (revenue / held), daysToTurn (held / revenue a day) },
--- and the totals { revenue, profit, held }.
function AV.Professions(ctx)
	local start = periods(ctx)
	local days = math.max(1, (ctx.now - start) / DAY)
	local crafted = CH.Ledger.Crafted()
	local by, total = {}, { revenue = 0, profit = 0, held = 0, sold = 0 }
	local function prof(name)
		local x = by[name] or { name = name, sold = 0, revenue = 0, cost = 0, profit = 0, held = 0 }
		by[name] = x
		return x
	end
	for _, e in pairs(plSince(start, ctx.opts and ctx.opts.char)) do
		local x = prof(e.prof or (crafted[e.id] and crafted[e.id].prof) or "Other")
		x.sold, x.revenue, x.cost, x.profit = x.sold + e.sold, x.revenue + e.revenue, x.cost + e.cost, x.profit + e.profit
		total.sold, total.revenue, total.profit = total.sold + e.sold, total.revenue + e.revenue, total.profit + e.profit
	end
	for _, e in ipairs(CH.Ledger.Inventory(nil, ctx.opts and ctx.opts.char)) do
		local c = e.id and crafted[e.id]
		if c and e.value > 0 then
			local x = prof(c.prof or "Other")
			x.held, total.held = x.held + e.value, total.held + e.value
		end
	end
	local out = {}
	for _, x in pairs(by) do
		x.margin = x.revenue > 0 and x.profit / x.revenue or nil
		x.turns = x.held > 0 and x.revenue / x.held or nil
		x.daysToTurn = x.held > 0 and (x.revenue > 0 and x.held / (x.revenue / days) or math.huge) or nil
		if ctx.keepName(x.name) then table.insert(out, x) end
	end
	total.days = days
	return out, total
end

--- Inventory turnover over the time frame: the cost of what sold (the Income Statement's) over the
--- average inventory of the daily snapshots. { cogs, avg, turns, days (to turn it once), snapshots } or nil.
function AV.Turnover(ctx)
	local start = periods(ctx)
	local St = CH.Statements
	local avg, n = CH.Ledger.AverageInventory and CH.Ledger.AverageInventory(start, ctx.now)
	if not (St and avg and avg > 0) then return nil end
	local inc = St.Income(start, ctx.now, ctx.opts and ctx.opts.char)
	local cogs = inc.cogsTotal or 0
	local len = math.max(1, (ctx.now - start) / DAY)
	local turns = cogs / avg
	return { cogs = cogs, avg = avg, turns = turns, days = turns > 0 and len / turns or nil, snapshots = n }
end

local function professionRows(ctx)
	local out = {}
	if needLedger(out) then return needLedger(out) end
	local T = CH.Theme
	local list, total = AV.Professions(ctx)
	for _, x in ipairs(list) do
		local dtt = x.daysToTurn
		table.insert(out, { cells = { x.name, x.sold, money(x.revenue), money(x.cost), signed(x.profit), x.margin and pct(x.margin) or T.Color("muted", "-"),
			money(x.held), dtt and (dtt == math.huge and T.Color("bad", "no sales") or T.Color(dtt > 28 and "bad" or dtt > 7 and "accent" or "ok", string.format("%.0f", dtt))) or T.Color("muted", "-"),
			total.profit > 0 and pct(math.max(0, x.profit) / total.profit) or T.Color("muted", "-") },
			sort = { x.name, x.sold, x.revenue, x.cost, x.profit, x.margin or -math.huge, x.held, x.daysToTurn or -1, x.profit } })
	end
	if not out[1] then return out, T.Color("muted", "No crafted sales or stock yet: scan your professions so AuctionIQ knows what each one makes.") end
	local foot = string.format("%s revenue, %s profit, %s of crafted stock held.", money(total.revenue), signed(total.profit), money(total.held))
	local tv = AV.Turnover(ctx)
	if tv then
		foot = foot .. string.format("  Inventory turned %.1f times (cost of what sold %s over an average %s held%s).", tv.turns, money(tv.cogs), money(tv.avg),
			tv.days and string.format(", once every %.0f days", tv.days) or "")
	end
	return out, foot .. T.Color("muted", "  Days to turn: what you hold that it makes, over its sales a day.")
end

AV.VIEWS = {
	performance = { label = "Performance", sort = 5, rows = performanceRows, cols = { { "Line or character", 0, 180 }, { "", 184, 70 },
		{ "Sold", 258, 44 }, { "Revenue", 306, 84 }, { "Profit", 394, 84 }, { "Before", 482, 80 }, { "Change", 566, 80 }, { "Share", 650, 74 } } },
	drivers = { label = "Profit drivers", sort = 8, rows = driverRows, cols = { { "Item", 0, 180 }, { "Profit", 184, 76 }, { "Before", 264, 76 },
		{ "Change", 344, 76 }, { "Price", 424, 70 }, { "Volume", 498, 70 }, { "Cost", 572, 60 }, { "Driver", 636, 88 } } },
	capital = { label = "Capital efficiency", sort = 8, rows = capitalRows, cols = { { "Category", 0, 140 }, { "Held", 144, 84 },
		{ "Of stock", 232, 56 }, { "Profit", 292, 84 }, { "Of profit", 380, 60 }, { "Days stock", 444, 64 }, { "Per gold", 512, 56 }, { "", 572, 152 } } },
	byprofession = { label = "By profession", sort = 5, rows = professionRows, cols = { { "Profession", 0, 140 }, { "Sold", 144, 44 },
		{ "Revenue", 192, 84 }, { "Cost", 280, 84 }, { "Profit", 368, 84 }, { "Margin", 456, 54 }, { "Held", 514, 84 }, { "Days to turn", 602, 68 },
		{ "Share", 674, 50 } } },
	crafting = { label = "Crafting efficiency", sort = 3, noTime = true, rows = craftingRows, cols = { { "Recipe", 0, 170 }, { "Character", 174, 80 },
		{ "Crafts", 258, 44 }, { "Per craft", 306, 80 }, { "Per Conc. pt", 390, 80 }, { "Multicraft", 474, 80 }, { "Resourceful", 558, 84 },
		{ "Ingenuity", 646, 78 } } },
	batches = { label = "Batch results", sort = 7, asc = true, noTime = true, rows = batchRows, cols = { { "Batch", 0, 172 },
		{ "Character", 176, 74 }, { "Crafts", 254, 46 }, { "Sold", 304, 54 }, { "Forecast", 362, 86 }, { "Actual", 452, 86 },
		{ "Miss", 542, 80 }, { "Why", 626, 98 } } },
	scenarios = { label = "Compare crafts", detail = function(d, ctx) return AV.CraftDetail(d, ctx) end, sort = 5, asc = true, noTime = true, rows = scenarioRows, cols = { { "Craft", 0, 206 }, { "Character", 210, 100 },
		{ "Profit", 314, 108 }, { "Break-even", 426, 108 }, { "Cushion", 538, 96 }, { "Make", 638, 82 } } },
}

-- Scenarios' two settings, as buttons over the table; the column headings follow them
local function pctOf(x) return math.floor(x * 100 + 0.5) end
local function label(kind)
	local sc = AV.Scenario()
	return kind == "reagents" and string.format("Reagents +%d%%", pctOf(sc.reagents)) or string.format("Price -%d%%", pctOf(sc.price))
end
AV.VIEWS.scenarios.controls = {
	{ label = function() return label("reagents") end, tip = "How far reagent prices rise in this scenario.",
		click = function(dir) AV.SetScenario(step(AV.Scenario().reagents, dir), nil) end },
	{ label = function() return label("price") end, tip = "How far your selling prices fall in this scenario.",
		click = function(dir) AV.SetScenario(nil, step(AV.Scenario().price, dir)) end },
}

-- Compare crafts' Character picker: each character, then each of their professions under them
local function profName(p) return p and (p.parent or p.name) or "?" end
AV.VIEWS.scenarios.charChoices = function()
	local list = {}
	for key, c in pairs(CH.db.characters or {}) do
		local profs = {}
		for pid, p in pairs(c.professions or {}) do
			if p.scan then table.insert(profs, { profName(p), pid }) end
		end
		if #profs > 0 then
			local name = c.name or key:match("^[^%-]+")
			table.sort(profs, function(a, b) return a[1] < b[1] end)
			table.insert(list, { name = name, profs = profs })
		end
	end
	table.sort(list, function(a, b) return a.name < b.name end)
	local out = {}
	for _, e in ipairs(list) do
		table.insert(out, { e.name, e.name })
		for _, p in ipairs(e.profs) do table.insert(out, { "   " .. e.name .. " - " .. p[1], e.name .. "#" .. tostring(p[2]) }) end
	end
	return out
end
AV.VIEWS.scenarios.charLabel = function(v)
	local name, pid = v:match("^([^#]+)#?(.*)$")
	if pid == "" then return name end
	for key, c in pairs(CH.db.characters or {}) do
		if (c.name or key:match("^[^%-]+")) == name then
			local p = (c.professions or {})[tonumber(pid) or pid]
			if p then return name .. " - " .. profName(p) end
		end
	end
	return name
end

-- Compare crafts' Scan button: scan every profession of the character you're on, one after another,
-- and the list fills in as each finishes. Another character's professions are scanned on them.
local lastRefresh = 0
AV.VIEWS.scenarios.action = {
	label = function()
		local all = CH.Scan.all
		if all and all.waiting then return "Open" end -- the status line names which: "Open Enchanting" overflowed the button
		return all and "Stop" or "Scan"
	end,
	status = function() return CH.Scan.AllStatus and CH.Scan.AllStatus() end,
	tip = function()
		local w = CH.Scan.all and CH.Scan.all.waiting
		if w then return { { "Open " .. (w.name or "the next profession") }, { CH.Theme.Color("muted", "Opens it and scans it, then goes on to the next.") } } end
		local names = {}
		for _, p in ipairs(CH.Scan.MyProfessions()) do table.insert(names, p.name) end
		return { { CH.Scan.all and "Stop scanning" or "Scan my professions" },
			{ CH.Theme.Color("muted", "Opens and scans each of this character's professions in turn ("
				.. (#names > 0 and table.concat(names, ", ") or "none found") .. "), then shows them here.") },
			{ CH.Theme.Color("muted", "The game only lets an addon read the professions of the character you're logged in as, so log in as each crafter once and press Scan.") },
			{ CH.Theme.Color("muted", "Stand at a crafting table for the best numbers: its bonuses count only while you're at it.") } }
	end,
	click = function()
		if CH.Scan.all and CH.Scan.all.waiting then
			local name = CH.Scan.all.waiting.name
			CH.Scan.ContinueAll()
			return true, "Scanning " .. (name or "the next profession") .. "."
		end
		if CH.Scan.all then CH.Scan.StopAll(); return true, "Stopping after this profession." end
		local ok, why = CH.Scan.ScanAll(function()
			local now = GetTime and GetTime() or 0
			if now - lastRefresh > 0.5 then lastRefresh = now; if CH.UI.IsShown() then CH.UI.Refresh() end end
		end, function(results)
			local parts = {}
			for _, r in ipairs(results) do
				table.insert(parts, r.why and (r.name .. " " .. r.why) or string.format("%s %d crafts", r.name, r.rows))
			end
			CH.Print("scanned " .. table.concat(parts, ", "))
			if CH.UI.IsShown() then CH.UI.Refresh() end
		end)
		if not ok then return false, "Can't scan: " .. (why or "?") .. "." end
		return true, "Scanning your professions: the list fills in as each one finishes."
	end,
}

-- Gold per hour and Craft results register their own definitions; this sets the order. Performance
-- explains what happened, so it sits in Accounting. Compare crafts (the downside scenarios beside
-- break-even) is a craft decision, so it opens Operations, Professions, ahead of the knowledge pages.
-- They have no sub-tab of their own: Reports > Performance (Accounting/Performance.lua) sums them up
-- and opens each one from its charts and links.
LUI.Register("ledger", AV.VIEWS, {})
-- Operations (the COO): Craft (what to make), Trade (what to post, hold or buy, from what you hold and
-- the market) and Queue (the work planned: crafts, shopping and what's blocking it).
-- Craft here is only what crosses characters: Compare crafts and Specialization. Scanning, the advisor,
-- work orders and the queue live in the window docked beside the profession window.
LUI.Register("operations", {}, { "scenarios", "paths" }, "Craft")
-- Plan payoff by recipe and the weekly knowledge checklist open from Specialization, so they sit in
-- Craft without a nav line of their own
for _, k in ipairs({ "plans", "professions" }) do
	if LUI.ViewDef(k) then LUI.ViewDef(k).parent = "Craft" end
end
LUI.Register("operations", {}, { "post", "markets", "marketgroups", "risk", "capitalplan", "rules" }, "Trade")
LUI.Register("operations", {}, { "queue", "shopping", "restock" }, "Queue")
LUI.Order("operations", { "Craft", "Trade", "Queue" })
