-- Tune TSM: for each TSM group, what costs gold or time under its operation, and the one change with
-- the strongest evidence. Every suggestion names the setting, its value now, a value to copy into
-- TSM, the window its evidence comes from and the numbers behind it. The effect is a projection,
-- labelled as one: nothing here is observed until you change the setting and the period after it is
-- compared (4.3). AuctionIQ never changes TSM; you make the change in TSM.
--
-- The levers, each from your own TSM records over the window:
--   post cap down   listings expire more than they sell: post about what sells over one listing's
--                   duration, so fewer listings sit and lose their deposit
--   post cap up     nearly everything posted sells and you hold more than the cap: post more at a time
--   duration        listings expire often at 12 or 24 hours: list longer, repost less often
--   auctioning min  units sold below what they cost you (crafted or bought): put the minimum at cost
--   shopping max    units bought above what they resell for, or above the market: lower the maximum
--   cancel/repost   more cancels than sales: each cancel loses its deposit and a posting pass, so
--                   raise the repost threshold or stop canceling to repost higher
local _, AuctionIQ = ...

local T = {}
AuctionIQ.Tune = T

local DAY = 86400
T.DAYS = 30
T.MIN_EVENTS = 5 -- fewer sales, expiries or buys than this and a lever isn't suggested

-- Copper in TSM's syntax, for pasting: "12g50s", "75s", "3c".
local function tsmMoney(c)
	c = math.floor((c or 0) + 0.5)
	local g, s, cc = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
	local out = ""
	if g > 0 then out = out .. g .. "g" end
	if s > 0 then out = out .. s .. "s" end
	if cc > 0 or out == "" then out = out .. cc .. "c" end
	return out
end
T.Money = tsmMoney

local function money(c) return AuctionIQ.FormatMoney(c, true) end
local function plural(n, one, many) return n == 1 and one or (many or (one .. "s")) end

--- The window: the last `days` days to now: { from, to, days, label }.
function T.Window(now, days)
	now, days = now or time(), days or T.DAYS
	return { from = now - days * DAY, to = now, days = days, label = "last " .. days .. " days" }
end

-- Per item over the window, from TSM's records: sold units, net gold (after the cut), sale rows,
-- expired and cancelled units and listings, bought units and gold, and the lowest sale.
local function evidence(win, want)
	local L = AuctionIQ.Ledger
	local by = {}
	local function e(id)
		local x = by[id]
		if not x then
			x = { sold = 0, net = 0, saleRows = 0, belowCost = 0, lostBelow = 0, expired = 0, expiredRows = 0,
				cancelled = 0, cancelRows = 0, bought = 0, paid = 0, sales = {}, buys = {} }
			by[id] = x
		end
		return x
	end
	if not (L and L.Available()) then return by end
	local function inWin(r) return r.id and want[r.id] and r.time and r.time >= win.from and r.time <= win.to end
	for _, s in ipairs(L.Records("Sales")) do
		if inWin(s) and (s.source == nil or s.source == "Auction") then
			local x = e(s.id)
			local q = s.quantity or 0
			x.sold, x.net, x.saleRows = x.sold + q, x.net + L.Net(s), x.saleRows + 1
			table.insert(x.sales, { q = q, each = q > 0 and L.Net(s) / q or 0 })
		end
	end
	for _, r in ipairs(L.Records("Expired")) do
		if inWin(r) then local x = e(r.id); x.expired, x.expiredRows = x.expired + math.max(1, r.quantity or 1), x.expiredRows + 1 end
	end
	for _, r in ipairs(L.Records("Cancelled")) do
		if inWin(r) then local x = e(r.id); x.cancelled, x.cancelRows = x.cancelled + math.max(1, r.quantity or 1), x.cancelRows + 1 end
	end
	for _, b in ipairs(L.Records("Buys")) do
		if inWin(b) then
			local x = e(b.id)
			local q = b.quantity or 0
			x.bought, x.paid = x.bought + q, x.paid + (b.amount or 0)
			table.insert(x.buys, { q = q, each = q > 0 and (b.amount or 0) / q or 0 })
		end
	end
	return by
end
T.Evidence = evidence

local function median(list)
	if #list == 0 then return nil end
	table.sort(list)
	local m = math.floor((#list + 1) / 2)
	return #list % 2 == 1 and list[m] or (list[m] + list[m + 1]) / 2
end

local function setting(a, key)
	for _, s in ipairs(a and a.settings or {}) do if s.key == key then return s end end
end

local function sum(by, ids, field)
	local n = 0
	for _, id in ipairs(ids) do n = n + (by[id] and by[id][field] or 0) end
	return n
end

local function deposit(id, hours) return AuctionIQ.Expect and AuctionIQ.Expect.Deposit(id, hours) or 0 end
local HOURS = { [1] = 12, [2] = 24, [3] = 48 }
local function S_DUR(d) return ({ [1] = "12-hour", [2] = "24-hour", [3] = "48-hour" })[d] or "24-hour" end

-- The candidates for one group. Each: { lever, key, setting (label), current, suggest (to copy), gold
-- (projected over the window), actions (posting actions saved over the window), strength (events),
-- why, evidence = { lines }, projected }.
local function candidates(path, ids, by, win, setup)
	local out = {}
	local a = setup.Auctioning
	local hasAuc = a and a.op
	local days = win.days
	local capS, durS = setting(a, "postCap"), setting(a, "duration")
	local cap = capS and tonumber(capS.raw) or nil
	local dur = durS and tonumber(durS.raw) or 2
	local hours = HOURS[dur] or 24
	local sold, expired, expRows = sum(by, ids, "sold"), sum(by, ids, "expired"), sum(by, ids, "expiredRows")
	local cancels = sum(by, ids, "cancelRows")
	local saleRows = sum(by, ids, "saleRows")
	local function lostDeposits(field)
		local g = 0
		for _, id in ipairs(ids) do local x = by[id]; if x then g = g + deposit(id, hours) * x[field] end end
		return g
	end

	-- what one listing's duration sells, per item that sold: the post cap that matches it
	local needs = {}
	for _, id in ipairs(ids) do
		local x = by[id]
		if x and x.sold > 0 then needs[#needs + 1] = math.max(1, math.ceil(x.sold / days * hours / 24)) end
	end
	local need = median(needs)
	local share = (sold + expired) > 0 and sold / (sold + expired) or nil

	if hasAuc and cap and cap > 0 and share and share < 0.5 and expRows >= T.MIN_EVENTS then
		local to = math.max(1, need or 1)
		if to < cap then
			local lost = lostDeposits("expired")
			-- the share of listings the lower cap wouldn't have put up, at most what expired
			local cutShare = 1 - to / cap
			table.insert(out, { lever = "post cap down", key = "postCap", setting = "Post cap", current = capS.raw, suggest = tostring(to),
				gold = lost * cutShare, actions = math.floor(expRows * cutShare + 0.5), strength = expRows + saleRows,
				why = string.format("%d%% of units posted sold; the rest expired", math.floor(share * 100 + 0.5)),
				evidence = {
					string.format("%d sold, %d expired (%d %s)", sold, expired, expRows, plural(expRows, "listing")),
					string.format("a %s listing sells about %d of an item (median of %d %s that sold)", S_DUR(dur), to, #needs, plural(#needs, "item")),
					string.format("deposits lost to expiries: about %s", money(lost)),
				},
				projected = string.format("about %s less lost to deposits and %d fewer expired %s over %d days",
					money(lost * cutShare), math.floor(expRows * cutShare + 0.5), plural(math.floor(expRows * cutShare + 0.5), "listing"), days) })
		end
	end

	if hasAuc and cap and cap > 0 and share and share >= 0.8 and saleRows >= T.MIN_EVENTS and need and need > cap then
		local held = 0
		for _, id in ipairs(ids) do held = held + (AuctionIQ.Par and AuctionIQ.Par.Held(id) or 0) end
		if held > cap then
			local avg = sold > 0 and sum(by, ids, "net") / sold or 0
			table.insert(out, { lever = "post cap up", key = "postCap", setting = "Post cap", current = capS.raw, suggest = tostring(need),
				gold = 0, actions = 0, strength = saleRows,
				why = string.format("%d%% of units posted sold and you hold %d", math.floor(share * 100 + 0.5), held),
				evidence = {
					string.format("%d sold, %d expired", sold, expired),
					string.format("a %s listing sells about %d of an item; the cap posts %d", S_DUR(dur), need, cap),
					string.format("average sale %s after the cut", money(avg)),
				},
				projected = string.format("more of what you hold up at once; not counted as gold until the period after the change shows it") })
		end
	end

	if hasAuc and dur < 3 and share and share < 0.5 and expRows >= T.MIN_EVENTS then
		local saved = math.floor(expRows / 2 + 0.5)
		table.insert(out, { lever = "duration", key = "duration", setting = "Duration", current = durS and durS.raw or "2", suggest = tostring(dur + 1),
			gold = 0, actions = saved, strength = expRows,
			why = string.format("listings expire often at %s", S_DUR(dur)),
			evidence = { string.format("%d expired %s over %d days", expRows, plural(expRows, "listing"), days),
				"the deposit is per hour listed, so a longer listing costs the same per hour and is lost only if it expires" },
			projected = string.format("about %d fewer reposts over %d days, at %s each", saved, days, S_DUR(dur + 1)) })
	end

	if hasAuc then
		-- sales below what the item cost you: crafted at cost to make, bought at what you paid
		local lost, units, rows, basis = 0, 0, 0, nil
		local paid = AuctionIQ.Ledger.Available() and AuctionIQ.Ledger.Paid() or {}
		for _, id in ipairs(ids) do
			local x = by[id]
			if x and x.sold > 0 then
				local cost, kind = AuctionIQ.Groups.CostEach(id), "crafting"
				if not cost then
					local p = paid[id]
					cost, kind = p and p.each, "avgbuy"
				end
				if cost then
					for _, s in ipairs(x.sales) do
						if s.each < cost then lost, units, rows = lost + (cost - s.each) * s.q, units + s.q, rows + 1; basis = basis or kind end
					end
				end
			end
		end
		local minS = setting(a, "minPrice")
		if rows >= T.MIN_EVENTS or (rows > 0 and lost >= 100 * 10000) then
			local cur = minS and minS.saved and tostring(minS.raw) or nil
			-- the minimum that covers cost after the 5% cut, with TSM's own cost source
			local floor = "106% " .. (basis or "crafting")
			table.insert(out, { lever = "auctioning minimum", key = "minPrice", setting = "Auctioning minimum", current = cur or "TSM's default",
				suggest = cur and ("max(" .. cur .. ", " .. floor .. ")") or floor,
				gold = lost, actions = 0, strength = rows,
				why = string.format("%d %s sold below what %s cost you", units, plural(units, "unit"), units == 1 and "it" or "they"),
				evidence = { string.format("%d %s under cost, %s short of cost after the cut", rows, plural(rows, "sale"), money(lost)),
					basis == "avgbuy" and "cost: what you paid (TSM's avgbuy)" or "cost: cost to make (TSM's crafting)" },
				projected = string.format("up to %s more over %d days if those units sell at cost instead; some may sell later or not at all", money(lost), days) })
		end
	end

	local sh = setup.Shopping
	if sh and sh.op then
		local over, units, rows, basis = 0, 0, 0, nil
		for _, id in ipairs(ids) do
			local x = by[id]
			if x and x.bought > 0 then
				local resale = AuctionIQ.Ledger.AvgSell(id)
				local ref, kind = resale and resale * AuctionIQ.AH_CUT, "avgsell"
				if not ref then ref, kind = AuctionIQ.Prices.Get("dbmarket", "i:" .. id), "dbmarket" end
				if ref then
					for _, b in ipairs(x.buys) do
						if b.each > ref then over, units, rows = over + (b.each - ref) * b.q, units + b.q, rows + 1; basis = basis or kind end
					end
				end
			end
		end
		if rows >= T.MIN_EVENTS or (rows > 0 and over >= 100 * 10000) then
			local mx = setting(sh, "maxPrice")
			local cur = mx and mx.saved and tostring(mx.raw) or nil
			local cap = basis == "avgsell" and "90% avgsell" or "100% dbmarket"
			table.insert(out, { lever = "shopping maximum", key = "maxPrice", setting = "Shopping maximum", current = cur or "TSM's default",
				suggest = cur and ("min(" .. cur .. ", " .. cap .. ")") or cap, kind = "Shopping",
				gold = over, actions = 0, strength = rows,
				why = string.format("%d %s bought above %s", units, plural(units, "unit"), basis == "avgsell" and "what they resell for after the cut" or "the market price"),
				evidence = { string.format("%d %s over, %s above it in all", rows, plural(rows, "buy"), money(over)) },
				projected = string.format("up to %s less spent over %d days, if the same items were found at or under the new maximum", money(over), days) })
		end
	end

	if hasAuc and cancels >= 2 * T.MIN_EVENTS and cancels >= 2 * math.max(1, saleRows) then
		local lost = lostDeposits("cancelled")
		local cr, th = setting(a, "cancelRepost"), setting(a, "cancelRepostThreshold")
		local lever, key, cur, sug
		if cr and cr.value and th and th.saved then
			local avg = sold > 0 and sum(by, ids, "net") / sold or nil
			-- the threshold as it stands, worked out for the group's first item (a group alone shows it as saved)
			local now = th.value or AuctionIQ.Formula.Value(th.raw, ids[1]) or 0
			local want = math.max(now * 2, avg and avg * 0.05 or 0)
			lever, key, cur, sug = "repost threshold", "cancelRepostThreshold", tostring(th.raw), tsmMoney(want)
		else
			lever, key, cur, sug = "cancel when undercut", "cancelUndercut", "on", "off"
		end
		table.insert(out, { lever = lever, key = key, setting = lever == "repost threshold" and "Repost higher by" or "Cancel when undercut",
			current = cur, suggest = sug, gold = lost / 2, actions = math.floor(cancels / 2 + 0.5), strength = cancels,
			why = string.format("%d cancels against %d %s", cancels, saleRows, plural(saleRows, "sale")),
			evidence = { string.format("%d cancelled %s, %d %s over %d days", cancels, plural(cancels, "listing"), saleRows, plural(saleRows, "sale"), days),
				string.format("deposits lost to cancels: about %s", money(lost)) },
			projected = string.format("about half the cancels, %s in deposits and %d posting actions over %d days", money(lost / 2), math.floor(cancels / 2 + 0.5), days) })
	end
	return out
end

-- Strongest first: gold over the window, then posting actions saved, then how many events back it.
local function better(x, y)
	if math.floor(x.gold) ~= math.floor(y.gold) then return x.gold > y.gold end
	if x.actions ~= y.actions then return x.actions > y.actions end
	return x.strength > y.strength
end
T.Better = better

--- Every TSM group with items, each with its one suggestion (the strongest lever) and the others it
--- beat: { path, op, items, shared (other groups using the operation), suggest, others, setup,
--- evidence (per item) }, strongest first. Groups with nothing to suggest are left out unless all.
function T.Diagnose(now, days, all)
	local win = T.Window(now, days)
	local groups = {}
	for id, path in pairs(AuctionIQ.Groups.TSMGroups()) do
		groups[path] = groups[path] or {}
		table.insert(groups[path], id)
	end
	local want = {}
	for _, ids in pairs(groups) do for _, id in ipairs(ids) do want[id] = true end end
	local by = evidence(win, want)
	local out = {}
	for path, ids in pairs(groups) do
		table.sort(ids)
		local setup = AuctionIQ.TSMSetup.Group(path)
		if setup then
			local list = candidates(path, ids, by, win, setup)
			table.sort(list, better)
			local a = setup.Auctioning
			local r = { path = path, items = ids, window = win, setup = setup, suggest = list[1], others = { unpack(list, 2) },
				op = list[1] and list[1].kind == "Shopping" and setup.Shopping.op or (a and a.op) }
			local k = list[1] and (list[1].kind == "Shopping" and setup.Shopping or a)
			r.shared = {}
			for _, p in ipairs(k and k.shared or {}) do if p ~= (k.from or path) then r.shared[#r.shared + 1] = p end end
			r.inherited = k and not k.own and k.from or nil
			if r.suggest or all then table.insert(out, r) end
		end
	end
	table.sort(out, function(x, y)
		if x.suggest and y.suggest then return better(x.suggest, y.suggest) end
		if x.suggest or y.suggest then return x.suggest ~= nil end
		return x.path < y.path
	end)
	return out, win
end

--- Chat lines for one diagnosed group.
function T.Lines(r)
	local s = r.suggest
	local out = {}
	if not s then
		table.insert(out, string.format("%s: nothing to change (%s)", r.path, r.window.label))
		return out
	end
	table.insert(out, string.format("%s (%s): %s %s -> %s", r.path, tostring(r.op), s.setting, tostring(s.current), s.suggest))
	table.insert(out, "  why: " .. s.why .. " (" .. r.window.label .. ")")
	for _, l in ipairs(s.evidence) do table.insert(out, "  evidence: " .. l) end
	table.insert(out, "  projected, not observed: " .. s.projected)
	if r.inherited then
		table.insert(out, "  the operation is set on " .. r.inherited .. ", so the change applies there and to every group under it")
	end
	if #r.shared > 0 then
		table.insert(out, string.format("  %d other %s use%s %s too: %s", #r.shared, plural(#r.shared, "group"), #r.shared == 1 and "s" or "", tostring(r.op), table.concat(r.shared, ", ")))
	end
	return out
end

--- /aiq tune [n]: the n strongest suggestions (5 by default).
function T.Command(arg)
	local n = tonumber(arg and arg:match("%d+")) or 5
	local list, win = T.Diagnose()
	if #list == 0 then AuctionIQ.Print("Tune TSM: nothing to suggest from the " .. win.label .. " (a lever needs " .. T.MIN_EVENTS .. " sales, expiries or buys behind it)"); return end
	AuctionIQ.Print(string.format("Tune TSM, %s: %d %s with a suggestion, strongest first", win.label, #list, plural(#list, "group")))
	for i = 1, math.min(n, #list) do for _, l in ipairs(T.Lines(list[i])) do AuctionIQ.Print(l) end end
end
