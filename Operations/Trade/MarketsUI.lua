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
	return { head = string.format("MARKET PRICE, %d DAYS SCANNED", #pts), values = values, days = pts, lo = lo, hi = hi,
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
		{ "Held / up", string.format("%d / %d", x.held, x.up) },
		{ "Days to sell them", Mk.DaysText(x.daysToSell) },
	}
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

LUI.Register("operations", MUI.VIEWS, {})
