-- Markets tab: Market prices, Competition and When it sells. The views draw in the Clearinghouse's
-- table page (Clearinghouse/LedgerUI.lua), which this file registers them with; the rows come from
-- CH.Prices and CH.Ledger, which only read TSM's data.
local _, CH = ...

local LUI = CH.LedgerUI
local MUI = {}
CH.MarketsUI = MUI

local function money(c) return LUI.Money(c) end

local function marketRows(ctx)
	local L, now, since, opts, keepName = CH.Ledger, ctx.now, ctx.since, ctx.opts, ctx.keepName
	local out = {}
	local ids, held = {}, {}
	for _, e in ipairs(L.Inventory(nil, opts.char)) do
		if e.id and not e.bound then held[e.id] = e.total; ids[e.id] = true end
	end
	for _, r in ipairs(L.Records("Sales")) do if r.id and r.time >= now - 30 * 86400 then ids[r.id] = true end end
	local any, sources = false, {}
	for id in pairs(ids) do
		local m = CH.Prices.MarketAny and CH.Prices.MarketAny(id)
		if m then
			any = true
			sources[m.source or "realm"] = true
			local text, name = LUI.ItemText(id)
			if keepName(name) then
				local h, mk = held[id] or 0, m.market or m.min
				local ch = m.change7
				table.insert(out, { id = id, cells = { text, h, money(mk), money(m.avg7),
					ch and CH.Theme.Color(ch >= 0 and "ok" or "bad", string.format("%+d%%", math.floor(ch * 100 + 0.5))) or CH.Theme.Color("muted", "-"),
					m.qty or "-", h > 0 and mk and money(mk * h) or "" },
					sort = { name, h, mk or 0, m.avg7 or 0, ch or 0, m.qty or 0, (mk or 0) * h } })
			end
		end
	end
	if not any then
		return out, CH.Theme.Color("muted", "No market data yet: needs TSM, Oribos Exchange or the Clearinghouse app.")
	end
	local from = {}
	if sources.realm or sources.commodity then
		local at, realm = 0, ""
		if ClearinghouseMarket and ClearinghouseMarket.Info then at, realm = ClearinghouseMarket.Info() end
		table.insert(from, "Clearinghouse app (" .. realm .. (at > 0 and (", " .. LUI.Ago(at, now) .. " old") or "") .. ", 7-day avg)")
	end
	if sources.tsm then table.insert(from, "TSM (60-day avg)") end
	if sources.oribos then table.insert(from, "Oribos Exchange") end
	return out, "Items you hold or sold this month" .. CH.Theme.Color("muted", "   from " .. table.concat(from, ", "))
end

local function rivalRows(ctx)
	local L, now, since, opts, keepName = CH.Ledger, ctx.now, ctx.since, ctx.opts, ctx.keepName
	local out = {}
	local n = 0
	for _, e in ipairs(L.Competition(since)) do
		local text, name = LUI.ItemText(e.id)
		if keepName(name) then
			if e.status == "contested" then n = n + 1 end
			local col = e.status == "contested" and "bad" or e.status == "busy" and "accent" or "ok"
			table.insert(out, { id = e.id, cells = { text, e.cancels, e.seen, e.rate and string.format("%d%%", math.floor(e.rate * 100 + 0.5)) or "-",
				e.rival or CH.Theme.Color("muted", "-"), CH.Theme.Color(col, e.status) },
				sort = { name, e.cancels, e.seen, e.rate or -1, e.rival or "", e.status } })
		end
	end
	return out, string.format("%d contested markets", n) .. CH.Theme.Color("muted", "   Undercut and rivals fill in from your post scans; commodities don't show sellers")
end

local function whenRows(ctx)
	local L, now, since, opts, keepName = CH.Ledger, ctx.now, ctx.since, ctx.opts, ctx.keepName
	local out = {}
	local DAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
	for _, e in ipairs(L.SaleTimes(since, opts.char)) do
		local text, name = LUI.ItemText(e.id)
		if keepName(name) and e.sold >= 3 then
			local post = (e.bestHour + 23) % 24
			table.insert(out, { id = e.id, cells = { text, e.sold, DAYS[e.bestDay], string.format("%02d:00-%02d:00", e.bestHour, (e.bestHour + 4) % 24),
				string.format("%d%%", math.floor(e.share * 100 + 0.5)), string.format("%s by %02d:00", DAYS[e.bestDay]:sub(1, 3), post) },
				sort = { name, e.sold, e.bestDay, e.bestHour, e.share, e.bestDay * 24 + post } })
		end
	end
	return out, "Items sold 3+ times. A 4-hour window holding 17% of sales is no pattern; 40%+ is worth posting for."
end

MUI.VIEWS = {
	market = { label = "Market prices", sort = 7, noTime = true, rows = marketRows, cols = { { "Item", 0, 220 }, { "Held", 224, 50 }, { "Market now", 278, 96 },
		{ "Average", 378, 96 }, { "Trend", 478, 60 }, { "Listed", 542, 70 }, { "Held worth", 616, 108 } } },
	when = { label = "When it sells", sort = 2, rows = whenRows, cols = { { "Item", 0, 220 }, { "Sold", 224, 60 }, { "Best day", 288, 90 },
		{ "Best hours", 382, 110 }, { "Share then", 496, 80 }, { "Post by", 580, 144 } } },
	rivals = { label = "Competition", sort = 2, rows = rivalRows, cols = { { "Item", 0, 220 }, { "Cancels", 224, 60 }, { "Seen", 288, 50 },
		{ "Undercut", 342, 80 }, { "Top rival", 426, 150 }, { "Market", 580, 144 } } },
}

LUI.Register("markets", MUI.VIEWS, { "market", "rivals", "when" })
