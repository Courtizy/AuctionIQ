-- Operations > Trade: Market trends (each item in your groups) and Market by group (the same,
-- rolled up). Trend, volatility and liquidity come from Data/Market.lua; selecting an item charts
-- its daily price over the last 30 days beside the table.
local _, CH = ...

local MUI = {}
CH.MarketsUI = MUI

local LUI = CH.LedgerUI
local function money(c) return LUI.Money(c) end
local HUGE = math.huge

local function rate(x)
	if not x then return CH.Theme.Color("muted", "-") end
	return CH.Demand and CH.Demand.Rate and CH.Demand.Rate(x) or string.format("%.1f", x)
end

local function pct(x) if not x then return CH.Theme.Color("muted", "-") end return string.format("%d%%", math.floor(x * 100 + 0.5)) end

local function footer(n, rising, falling, choppy, thin, gold)
	local T = CH.Theme
	return string.format("%d items, selling %s a day.", n, money(gold))
		.. T.Color("ok", string.format("   %d rising", rising)) .. T.Color("bad", string.format("   %d falling   %d choppy", falling, choppy))
		.. T.Color("muted", string.format("   %d thin", thin))
		.. T.Color("muted", string.format("   Trend is a line through %d+ days of your AH scans, per week; until then TSM's market against its 60-day price.", CH.Market.MIN_DAYS))
end

local function itemRows(ctx)
	local Mk = CH.Market
	local out = {}
	local count = { rising = 0, falling = 0, choppy = 0, thin = 0 }
	local gold = 0
	for _, x in ipairs(Mk.Items(ctx.now)) do
		local text, name = LUI.ItemText(x.id)
		if ctx.keepName(name) or ctx.keepName(x.path) then
			count[x.read] = (count[x.read] or 0) + 1
			gold = gold + x.goldDay
			table.insert(out, { id = x.id, key = x.id, x = x, cells = { text, money(x.price), Mk.TrendText(x), Mk.VolText(x), rate(x.units), pct(x.saleRate),
				money(x.goldDay), Mk.DaysText(x.daysToSell), Mk.ReadText(x) },
				sort = { name, x.price or 0, x.trend or -HUGE, x.vol or -1, x.units, x.saleRate or -1, x.goldDay, x.daysToSell or -1, x.read } })
		end
	end
	if not out[1] then
		return out, CH.Theme.Color("muted", "No priced items in your groups. Put items in groups (Manage rules), and scan the AH or keep TSM's prices for them.")
	end
	return out, footer(#out, count.rising, count.falling, count.choppy, count.thin, gold)
end

local function groupRows(ctx)
	local Mk = CH.Market
	local T = CH.Theme
	local out = {}
	for _, g in ipairs(Mk.Groups(Mk.Items(ctx.now))) do
		if ctx.keepName(g.path) then
			table.insert(out, { key = "g:" .. g.path, g = g, cells = { string.rep("  ", g.depth) .. g.name, tostring(g.n), Mk.TrendText(g), Mk.VolText(g),
				money(g.goldDay), money(g.heldValue), Mk.DaysText(g.daysToSell), Mk.ReadText(g) },
				-- sorted by path keeps each group under its parent
				sort = { g.path, g.n, g.trend or -HUGE, g.vol or -1, g.goldDay, g.heldValue, g.daysToSell or -1, g.read } })
		end
	end
	if not out[1] then return out, T.Color("muted", "No priced items in your groups yet.") end
	return out, T.Color("muted", "Trend and volatility weigh each item by the gold a day it sells for. Days held: the gold you hold and have up over the gold a day the group sells.")
end

--- The chart for an item's daily prices: { head, values, from, to, lo, hi } or nil.
function MUI.Chart(x)
	local pts = x and x.points
	if not (pts and #pts >= 2) then return nil end
	local values, lo, hi = {}, HUGE, 0
	for i, p in ipairs(pts) do values[i] = p[2]; lo, hi = math.min(lo, p[2]), math.max(hi, p[2]) end
	local function date(day) return date and os and os.date and os.date("%b %d", day * 86400) or ("day " .. day) end
	local okFrom, from = pcall(date, pts[1][1])
	local okTo, to = pcall(date, pts[#pts][1])
	return { head = string.format("MARKET PRICE, %d DAYS", #pts), values = values, days = pts, lo = lo, hi = hi,
		from = okFrom and from or "", to = okTo and to or "" }
end

function MUI.ItemDetail(d)
	local x = d and d.x
	if not x then return nil end
	local T, Mk = CH.Theme, CH.Market
	local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(x.id) or ("item " .. x.id)
	local rows = {
		{ "Group", x.path or "-" },
		{ "Sold a day", rate(x.units) .. T.Color("muted", "  " .. ((CH.Demand and CH.Demand.SOURCE[x.demand and x.demand.source or "none"]) or "")),
			tip = { { "Sales rate" }, { T.Color("muted", CH.Demand and CH.Demand.Text(x.demand) or "-") } } },
		{ "Region sale rate", pct(x.saleRate), tip = { { "Region sale rate" }, { T.Color("muted", "TSM's share of the region's listings of it that sell.") } } },
		{ "Gold a day", money(x.goldDay) },
		{ "Held / up, days to sell", string.format("%d / %d", x.held, x.up) .. T.Color("muted", ", ") .. Mk.DaysText(x.daysToSell) },
	}
	if x.change90 then
		rows[#rows + 1] = { "Over 90 days", T.Color(x.change90 >= 0 and "ok" or "bad", string.format("%+d%%", math.floor(x.change90 * 100 + 0.5))),
			tip = { { "Over 90 days" }, { T.Color("muted", "The last day scanned against the nearest day 90 or more days before it.") } } }
	end
	if x.hi and x.span and x.span > 30 then
		rows[#rows + 1] = { string.format("High / low, %d days", x.span), money(x.hi) .. T.Color("muted", " / ") .. money(x.lo) }
	end
	local note
	if x.trendFrom == "scans" then
		note = string.format("A line through %d days of AH scans moves %s a week; a typical day moves it %s.", x.days,
			Mk.TrendText(x), x.vol and string.format("%.1f%%", x.vol * 100) or "-")
	else
		note = string.format("%d of %d days scanned: search it at the AH on more days for a trend and volatility of its own.", x.days or 0, Mk.MIN_DAYS)
			.. (x.trend and string.format(" TSM's market is %s its 60-day price.", Mk.TrendText(x)) or "")
	end
	return { kicker = "MARKET", title = name, item = x.id, sub = T.Color(Mk.READ_COLOR[x.read] or "fg", x.read),
		figures = { { "PRICE", money(x.price) }, { "TREND", Mk.TrendText(x) }, { "VOLATILITY", Mk.VolText(x) } },
		rows = rows, chart = MUI.Chart(x), note = note }
end

function MUI.GroupDetail(d)
	local g = d and d.g
	if not g then return nil end
	local T, Mk = CH.Theme, CH.Market
	local top = { head = "BIGGEST SELLERS", rows = {} }
	for i, x in ipairs(g.items) do
		if i > 6 then break end
		local _, name = LUI.ItemText(x.id)
		top.rows[i] = { name, money(x.goldDay) .. T.Color("muted", "/day") }
	end
	return { kicker = "MARKET GROUP", title = g.name, sub = T.Color(Mk.READ_COLOR[g.read] or "fg", g.read) .. T.Color("muted", "  " .. g.path),
		figures = { { "GOLD A DAY", money(g.goldDay) }, { "TREND", Mk.TrendText(g) }, { "VOLATILITY", Mk.VolText(g) } },
		rows = { { "Items", tostring(g.n) }, { "Held and up", money(g.heldValue) }, { "Days to sell them", Mk.DaysText(g.daysToSell) } },
		section = top }
end

MUI.VIEWS = {
	markets = { label = "Market trends", detail = function(d) return MUI.ItemDetail(d) end, sort = 7, noTime = true, rows = itemRows,
		cols = { { "Item", 0, 176 }, { "Price", 180, 80 }, { "Trend", 264, 78 }, { "Volatility", 346, 76 }, { "Sold/day", 426, 54 },
			{ "Sale rate", 484, 54 }, { "Gold/day", 542, 76 }, { "Days held", 622, 52 }, { "Read", 678, 46 } } },
	marketgroups = { label = "Market by group", detail = function(d) return MUI.GroupDetail(d) end, sort = 1, asc = true, noTime = true, rows = groupRows,
		cols = { { "Group", 0, 196 }, { "Items", 200, 44 }, { "Trend", 248, 80 }, { "Volatility", 332, 80 }, { "Gold/day", 416, 86 },
			{ "Held and up", 506, 92 }, { "Days held", 602, 60 }, { "Read", 666, 58 } } },
}

-- Capital allocation: where your gold earns the most a day (Data/Capital.lua) ------------------
local function capitalRows(ctx)
	local T, Cp = CH.Theme, CH.Capital
	local plan = Cp.Plan(ctx)
	local out = {}
	for _, o in ipairs(plan.list) do
		local name = o.kind == "craft" and o.name or select(1, LUI.ItemText(o.id))
		local fund = o.take == o.units and T.Color("ok", "all " .. o.units) or o.take > 0 and T.Color("accent", string.format("%d of %d", o.take, o.units))
			or T.Color("muted", "no gold left")
		table.insert(out, { id = o.id, cells = { name, o.kind == "craft" and ("craft" .. T.Color("muted", "  " .. (o.char or ""))) or "buy and relist",
			money(o.cost), money(o.profit), string.format("%.1f", o.days), string.format("%.2f%%", o.rate * 100), fund },
			sort = { o.name or "", o.kind, o.cost, o.profit, o.days, o.rate, o.take },
			tip = function()
				return { { o.name or "?" },
					{ "Gold in", money(o.cost) .. T.Color("muted", string.format("  (%d %s)", o.units, o.kind == "craft" and "crafts, the suggested batch" or "units")) },
					{ "Profit", money(o.profit) },
					{ "Tied up", string.format("%.1f days", o.days) .. T.Color("muted", "  until it sells, at its sales rate") },
					{ "Gold a day per gold in", string.format("%.2f%%", o.rate * 100) .. T.Color("muted", "  profit / gold in / days") },
					{ "Funded", o.take > 0 and string.format("%d: %s in, %s profit", o.take, money(o.spend), money(o.gain)) or "none: your gold went to better returns" } }
			end })
	end
	if not out[1] then
		return out, T.Color("muted", "Nothing to put gold in yet: scan your professions (Compare crafts) and the AH (Deals), and crafts and deals that pay show here, best return first.")
	end
	local foot = string.format("%s of your %s (keeping %d%% back): %s goes in, %s profit, about %s a day.", money(plan.budget), money(plan.money),
		math.floor(Cp.Reserve() * 100 + 0.5), money(plan.spent), money(plan.gain), money(plan.perDay))
	if plan.idle > 0 then foot = foot .. T.Color("muted", string.format("  %s left idle: nothing else pays.", money(plan.idle))) end
	return out, foot .. T.Color("muted", "  Best return first: profit / gold in / days until it sells.")
end

MUI.VIEWS.capitalplan = { label = "Capital allocation", sort = 6, noTime = true, rows = capitalRows,
	cols = { { "Opportunity", 0, 190 }, { "Kind", 194, 130 }, { "Gold in", 328, 88 }, { "Profit", 420, 84 }, { "Days", 508, 40 },
		{ "Per gold/day", 552, 74 }, { "Fund", 630, 94 } },
	controls = { { label = function() return string.format("Keep back %d%%", math.floor(CH.Capital.Reserve() * 100 + 0.5)) end,
		tip = "How much of your gold stays out of the plan.", click = function(dir) CH.Capital.StepReserve(dir) end } } }

-- Risk: what you hold and have up, and how far its price could fall while it sells -------------
local function riskRows(ctx)
	local T, Mk = CH.Theme, CH.Market
	local items = Mk.Items(ctx.now)
	local typical = Mk.TypicalVol(items)
	local out, exposed, atRisk, assumed = {}, 0, 0, 0
	for _, x in ipairs(items) do
		if x.held + x.up > 0 then
			local text, name = LUI.ItemText(x.id)
			if ctx.keepName(name) or ctx.keepName(x.path) then
				local r = Mk.Risk(x, typical)
				exposed, atRisk = exposed + r.exposed, atRisk + (r.atRisk or 0)
				if r.assumed then assumed = assumed + 1 end
				local volText = r.vol and (string.format("%.1f%%", r.vol * 100) .. (r.assumed and T.Color("muted", " typ.") or "")) or T.Color("muted", "-")
				table.insert(out, { id = x.id, cells = { text, tostring(x.held + x.up), money(r.exposed), volText, string.format("%.0f", r.horizon),
					r.downside and money(r.downside) or T.Color("muted", "-"), r.atRisk and T.Color(r.atRisk > 0.2 * r.exposed and "bad" or "fg", money(r.atRisk)) or T.Color("muted", "-") },
					sort = { name, x.held + x.up, r.exposed, r.vol or -1, r.horizon, r.downside or 0, r.atRisk or -1 },
					tip = function()
						return { { name },
							{ "Price now", money(x.price) },
							{ "Volatility", r.vol and string.format("%.1f%% a day", r.vol * 100) .. (r.assumed and T.Color("muted", "  (your items' typical: too few days scanned)") or "") or "unknown" },
							{ "Days to sell what you hold", string.format("%.1f", r.horizon) .. T.Color("muted", string.format("  (1 to %d)", Mk.RISK_DAYS)) },
							{ "Downside price", r.downside and money(r.downside) or "-" },
							{ T.Color("muted", string.format("%d%% of the time the price stays above it while you sell: price x e^(-1.64 x vol x sqrt(days)).", Mk.CONF * 100)) },
							{ "At risk", r.atRisk and money(r.atRisk) or "-" } }
					end })
			end
		end
	end
	if not out[1] then return out, T.Color("muted", "You hold nothing in your groups with a price.") end
	return out, string.format("%s held and up; %s at risk at the %d%% downside.", money(exposed), money(atRisk), Mk.CONF * 100)
		.. (assumed > 0 and T.Color("muted", string.format("  %d without enough days scanned use your items' typical volatility.", assumed)) or "")
		.. T.Color("muted", "  Days: how long what you hold takes to sell, and so how long the price has to move.")
end

MUI.VIEWS.risk = { label = "Risk", sort = 7, noTime = true, rows = riskRows,
	cols = { { "Item", 0, 210 }, { "Held+up", 214, 54 }, { "Exposed", 272, 96 }, { "Volatility", 372, 84 }, { "Days", 460, 40 },
		{ "Downside", 504, 104 }, { "At risk", 612, 112 } } }

LUI.Register("operations", MUI.VIEWS, {})
