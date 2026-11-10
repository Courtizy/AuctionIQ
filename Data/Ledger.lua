-- Ledger: gold, sales, purchases and inventory for the Dashboard and Ledger tabs.
--
-- History comes from TSM's own saved data (TradeSkillMasterDB), read only: its gold log per
-- character, its accounting (sales, buys, income, expenses, expired and cancelled auctions) and its
-- inventory counts (bags, bank, mail, auctions, warband bank). AuctionIQ also keeps its own copy:
--   * a daily summary of the accounting, so history survives TSM trimming old records
--   * a daily net worth snapshot (gold + what your inventory is worth at AuctionIQ value), which
--     TSM doesn't keep, so profit can be shown as the change in net worth
-- Nothing is ever written to TSM's data.
local _, CH = ...

local Lg = {}
CH.Ledger = Lg

local DAY = 86400

local function tsm() return type(TradeSkillMasterDB) == "table" and TradeSkillMasterDB or nil end

function Lg.Available() return tsm() ~= nil end

local function realm() return GetRealmName and GetRealmName() or "" end

-- "Luxaren - Alliance - Emerald Dream" -> "Luxaren", "Emerald Dream"
local function splitChar(scope)
	local parts = {}
	for p in string.gmatch(scope, "[^%-]+") do parts[#parts + 1] = strtrim(p) end
	return parts[1], parts[#parts]
end

--- Your characters on this realm in TSM's data: { name, key, money } (key is TSM's scope).
function Lg.Characters()
	local db, out, here = tsm(), {}, realm()
	if not db then return out end
	for k, v in pairs(db) do
		local scope = type(k) == "string" and k:match("^s@(.-)@internalData@money$")
		if scope then
			local name, r = splitChar(scope)
			if r == here then table.insert(out, { name = name, key = scope, money = tonumber(v) or 0 }) end
		end
	end
	table.sort(out, function(a, b) return a.money > b.money end)
	return out
end

local function own()
	local set = {}
	for _, c in ipairs(Lg.Characters()) do set[c.name] = true end
	return set
end

local function warbandMoney()
	local db = tsm()
	return db and tonumber(db["g@ @internalData@warbankMoney"]) or 0
end

--- Gold now: every character on the realm plus the warband bank.
function Lg.Gold()
	local total = Lg.Included and Lg.Included(Lg.WARBAND) and warbandMoney() or 0
	for _, c in ipairs(Lg.Characters()) do if Lg.Included(c.name) then total = total + c.money end end
	return total
end

--- Gold now per character and the warband bank: { { name, money, included } }.
function Lg.Holders()
	local out = {}
	for _, c in ipairs(Lg.Characters()) do table.insert(out, { name = c.name, money = c.money, included = Lg.Included(c.name) }) end
	table.insert(out, { name = Lg.WARBAND, money = warbandMoney(), included = Lg.Included(Lg.WARBAND) })
	return out
end

-- CSV parsing ---------------------------------------------------------------------------------
local parsed = {} -- [key] = { text, rows }: the text itself, so an edit of the same length is seen

local function csv(key)
	local db = tsm()
	local text = db and db[key]
	if type(text) ~= "string" then return {} end
	local c = parsed[key]
	if c and c.text == text then return c.rows end
	local rows, header = {}, nil
	for line in string.gmatch(text, "[^\n]+") do
		local f = {}
		for v in string.gmatch(line .. ",", "([^,]*),") do f[#f + 1] = v end
		if not header then
			header = f
		else
			local r = {}
			for i, h in ipairs(header) do r[h] = f[i] end
			table.insert(rows, r)
		end
	end
	parsed[key] = { text = text, rows = rows }
	return rows
end

local function num(v) return tonumber(v) or 0 end
local function itemID(s) return tonumber((s or ""):match("^i:(%d+)")) end

--- TSM's records of one kind for this realm: "Sales", "Buys", "Income", "Expense", "Expired",
--- "Cancelled". Each row: time, player, other, item (itemString), id, quantity, price (each),
--- amount (total copper), source or type.
-- Normalized records, kept per parsed CSV (a new parse, when TSM's text changes, makes new ones).
local normalized = setmetatable({}, { __mode = "k" })

--- TSM's accounting records of one kind, normalized. Shared between callers: read them, don't change them.
function Lg.Records(kind)
	local rows = csv("r@" .. realm() .. "@internalData@csv" .. kind)
	if normalized[rows] then return normalized[rows] end
	local out = {}
	for _, r in ipairs(rows) do
		local q = num(r.quantity)
		local amount = r.amount and num(r.amount) or num(r.price) * q
		table.insert(out, { time = num(r.time), player = r.player, other = r.otherPlayer, item = r.itemString,
			id = itemID(r.itemString), quantity = q, price = num(r.price), amount = amount, source = r.source or r.type })
	end
	if rows[1] then normalized[rows] = out end
	return out
end

--- The gold a sale put in your bags: an auction sale after the AH cut, a vendor or trade sale as is.
function Lg.Net(s)
	if not s then return 0 end
	local src = s.source
	if src == nil or src == "Auction" then return (s.amount or 0) * CH.AH_CUT end
	return s.amount or 0
end

-- Gold history --------------------------------------------------------------------------------
local function goldLog(scope)
	local out = {}
	for _, r in ipairs(csv("s@" .. scope .. "@internalData@goldLog")) do
		table.insert(out, { t = num(r.minute) * 60, v = num(r.copper) })
	end
	return out
end

Lg.WARBAND = "Warband"

local function store0()
	CH.db.ledger = CH.db.ledger or { days = {}, worth = {} }
	CH.db.ledger.exclude = CH.db.ledger.exclude or {}
	return CH.db.ledger
end

--- Whether a character (or Lg.WARBAND) counts in the gold totals and chart. All do by default.
function Lg.Included(name) return not store0().exclude[name] end
function Lg.SetIncluded(name, on) store0().exclude[name] = (not on) or nil end

-- Gold logs for everyone included: { { name, log } }.
local function logs()
	local out = {}
	for _, c in ipairs(Lg.Characters()) do
		if Lg.Included(c.name) then table.insert(out, { name = c.name, log = goldLog(c.key) }) end
	end
	if Lg.Included(Lg.WARBAND) then
		local wb = {}
		for _, r in ipairs(csv("g@ @internalData@warbankGoldLog")) do table.insert(wb, { t = num(r.minute) * 60, v = num(r.copper) }) end
		table.insert(out, { name = Lg.WARBAND, log = wb })
	end
	return out
end

local function at(log, t)
	local v = 0
	for _, e in ipairs(log) do if e.t <= t then v = e.v else break end end
	return v
end

--- Total gold over time for everyone included, sampled at n points from `from` to `to`
--- (seconds). Each point also has `by` = { { name, v } } for the chart's hover.
function Lg.GoldSeries(from, to, n)
	local all = logs()
	n = math.max(2, n or 60)
	local out = {}
	for i = 0, n - 1 do
		local t = from + (to - from) * i / (n - 1)
		local total, by = 0, {}
		for _, l in ipairs(all) do
			local v = at(l.log, t)
			total = total + v
			by[#by + 1] = { name = l.name, v = v }
		end
		out[#out + 1] = { t = t, v = total, by = by }
	end
	return out
end

-- Daily archive -------------------------------------------------------------------------------
local store = store0

local function dayOf(t) return math.floor(t / DAY) end

--- Summarise TSM's accounting by day into AuctionIQ's own archive (days TSM still has are
--- rebuilt, older days are kept). Transfers between your own characters aren't income or expense.
function Lg.Archive()
	local mine = own()
	local days = {}
	local function d(t)
		local k = dayOf(t)
		days[k] = days[k] or { sales = 0, buys = 0, income = 0, expense = 0, sold = 0, items = {} }
		return days[k]
	end
	for _, r in ipairs(Lg.Records("Sales")) do
		local e = d(r.time)
		-- what reached your bags: auction sales after the cut (TSM records the price before it)
		local net = Lg.Net(r)
		e.sales, e.sold = e.sales + net, e.sold + r.quantity
		if r.id then e.items[r.id] = (e.items[r.id] or 0) + net end
	end
	for _, r in ipairs(Lg.Records("Buys")) do local e = d(r.time); e.buys = e.buys + r.amount end
	for _, r in ipairs(Lg.Records("Income")) do
		if not mine[r.other] then local e = d(r.time); e.income = e.income + r.amount end
	end
	for _, r in ipairs(Lg.Records("Expense")) do
		if not mine[r.other] then local e = d(r.time); e.expense = e.expense + r.amount end
	end
	local s = store()
	-- days archived before sales were counted after the AH cut: those TSM no longer has are
	-- brought into line once (nearly all of them are auction sales)
	if not s.net then
		for k, v in pairs(s.days) do
			if not days[k] then
				v.sales = (v.sales or 0) * CH.AH_CUT
				for id, g in pairs(v.items or {}) do v.items[id] = g * CH.AH_CUT end
			end
		end
		s.net = true
	end
	for k, v in pairs(days) do s.days[k] = v end
	return s.days
end

--- Totals since a time from the archive: sales, buys, income, expense, profit (cash), top item.
function Lg.Summary(since)
	local days = store().days
	local first = dayOf(since or 0)
	local t = { sales = 0, buys = 0, income = 0, expense = 0, sold = 0, days = 0 }
	local items, spentItems = {}, {}
	local seen = {}
	for k, e in pairs(days) do
		if k >= first then
			t.sales, t.buys = t.sales + e.sales, t.buys + e.buys
			t.income, t.expense, t.sold = t.income + e.income, t.expense + e.expense, t.sold + (e.sold or 0)
			for id, v in pairs(e.items or {}) do items[id] = (items[id] or 0) + v end
			if not seen[k] then seen[k] = true; t.days = t.days + 1 end
		end
	end
	local best, bestV = nil, 0
	for id, v in pairs(items) do if v > bestV then best, bestV = id, v end end
	t.topItem, t.topItemGold = best, bestV
	t.earned = t.sales + t.income
	t.spent = t.buys + t.expense
	t.cash = t.earned - t.spent
	return t
end

-- Activity: one entry per character per mailbox visit (an hour), like TSM's log ----------------
function Lg.Activity(limit)
	local groups, order = {}, {}
	local function g(r)
		local k = (r.player or "?") .. "@" .. math.floor(r.time / 3600)
		if not groups[k] then
			groups[k] = { player = r.player, time = r.time, sold = 0, gold = 0, expired = 0, bought = 0, spent = 0 }
			table.insert(order, groups[k])
		end
		local e = groups[k]
		if r.time > e.time then e.time = r.time end
		return e
	end
	for _, r in ipairs(Lg.Records("Sales")) do
		if r.source == "Auction" then local e = g(r); e.sold, e.gold = e.sold + r.quantity, e.gold + r.amount end
	end
	for _, r in ipairs(Lg.Records("Expired")) do local e = g(r); e.expired = e.expired + r.quantity end
	for _, r in ipairs(Lg.Records("Buys")) do
		if r.source == "Auction" then local e = g(r); e.bought, e.spent = e.bought + r.quantity, e.spent + r.amount end
	end
	table.sort(order, function(a, b) return a.time > b.time end)
	for i = #order, (limit or 50) + 1, -1 do order[i] = nil end
	return order
end

-- Inventory -----------------------------------------------------------------------------------
--- Every item you hold on this realm, from TSM's counts: { item, id, bags, bank, mail, ah, warband,
--- total, value } sorted by value (AuctionIQ value x total). filter is a name keyword.
function Lg.Inventory(filter, char)
	local db = tsm()
	local items = {}
	if not db then return {} end
	local function add(t, field)
		if type(t) ~= "table" then return end
		for itemString, n in pairs(t) do
			local base = itemString:match("^(i:%d+)") or itemString
			local e = items[base]
			if not e then e = { item = base, id = itemID(base), bags = 0, bank = 0, mail = 0, ah = 0, warband = 0, total = 0 }; items[base] = e end
			e[field] = e[field] + (tonumber(n) or 0)
			e.total = e.total + (tonumber(n) or 0)
		end
	end
	for _, c in ipairs(Lg.Characters()) do
		if char and c.name ~= char then -- one character only
		else
		add(db["s@" .. c.key .. "@internalData@bagQuantity"], "bags")
		add(db["s@" .. c.key .. "@internalData@bankQuantity"], "bank")
		add(db["s@" .. c.key .. "@internalData@mailQuantity"], "mail")
		add(db["s@" .. c.key .. "@internalData@auctionQuantity"], "ah")
		end
	end
	if not char then add(db["g@ @internalData@warbankQuantity"], "warband") end
	local out = {}
	local key = filter and filter ~= "" and string.lower(filter) or nil
	for _, e in pairs(items) do
		e.name = e.id and C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(e.id) or nil
		if not key or (e.name and string.lower(e.name):find(key, 1, true)) then
			e.bound = CH.Unsellable(e.id)
			local unit = not e.bound and CH.Prices.Get("chvalue", e.item) or nil
			e.unit = unit
			e.value = unit and unit * e.total or 0
			table.insert(out, e)
		end
	end
	table.sort(out, function(a, b) return a.value > b.value end)
	return out
end

--- What your inventory is worth now at AuctionIQ value.
function Lg.InventoryValue()
	local v = 0
	for _, e in ipairs(Lg.Inventory()) do v = v + e.value end
	return v
end

--- Record today's net worth (gold + inventory value). Called on login and when the dashboard opens.
function Lg.Snapshot(now)
	if not Lg.Available() then return nil end
	local gold, inv = Lg.Gold(), Lg.InventoryValue()
	local s = store()
	s.worth[dayOf(now or time())] = { gold = gold, inventory = inv }
	return gold + inv, gold, inv
end

--- Net worth on the first day on or after `since` that has a snapshot, and now.
function Lg.WorthChange(since)
	local s = store()
	local first, firstK = nil, nil
	for k, w in pairs(s.worth) do
		if k >= dayOf(since) and (not firstK or k < firstK) then firstK, first = k, w end
	end
	local nowK, now = nil, nil
	for k, w in pairs(s.worth) do if not nowK or k > nowK then nowK, now = k, w end end
	if not first or not now then return nil end
	return (now.gold + now.inventory) - (first.gold + first.inventory), first, now, firstK
end

-- CFO views ----------------------------------------------------------------------------------
--- What you paid on average for each item, from TSM's purchase records since `since`.
--- What you paid per item: { [itemID] = { n, gold, each } }. Without `since`, each item's buys from
--- its last 30 days of buying (so old prices age out), else every buy since then.
function Lg.Paid(since)
	local t, last = {}, {}
	local buys = Lg.Records("Buys")
	if not since then
		for _, b in ipairs(buys) do if b.id and (not last[b.id] or b.time > last[b.id]) then last[b.id] = b.time end end
	end
	for _, b in ipairs(buys) do
		local from = since or (b.id and last[b.id] and last[b.id] - 30 * DAY) or -math.huge
		if b.id and b.time >= from and b.quantity > 0 then
			local e = t[b.id] or { n = 0, gold = 0 }
			t[b.id] = e
			e.n, e.gold = e.n + b.quantity, e.gold + b.amount
		end
	end
	for _, e in pairs(t) do e.each = e.gold / e.n end
	return t
end

--- Every crafted item you've scanned, on any character: { [itemID] = { name, accounts } }.
function Lg.Crafted()
	local out = {}
	for _, c in pairs(CH.db.characters or {}) do
		for _, p in pairs(c.professions or {}) do
			for _, r in ipairs(p.scan and p.scan.rows or {}) do
				if r.item and r.accounts and not out[r.item] then out[r.item] = { name = r.name, acc = r.accounts, row = r } end
				if r.concItem and r.concAccounts and not out[r.concItem] then out[r.concItem] = { name = r.name, acc = r.concAccounts, row = r } end
			end
		end
	end
	return out
end

--- Cost to make one item at what you actually paid for its reagents (today's price for any you
--- never bought), after Resourcefulness, over what Multicraft makes. Also the share at paid prices.
function Lg.CostAtPaid(acc, paid)
	local cost, known, total = 0, 0, 0
	for _, rg in ipairs(acc.reagents or {}) do
		local p = paid[rg.itemID]
		local each = p and p.each or (rg.cost and rg.n > 0 and rg.cost / rg.n) or 0
		cost = cost + each * rg.n
		total = total + each * rg.n
		if p then known = known + each * rg.n end
	end
	local saved = (acc.cost and acc.cost > 0) and (acc.resGold or 0) / acc.cost or 0
	local items = (acc.made or 1) + (acc.extraItems or 0)
	return cost * (1 - saved) / math.max(items, 0.01), total > 0 and known / total or 0
end

--- What you paid for each item around a time: { [itemID] = { times, n, gold } } built once from
--- TSM's buys (sorted, with running totals), and PaidAt(index, id, t) = the average of that item's
--- buys in the 30 days up to t, else the last buy before t, else nil. A later purchase never
--- changes what an earlier sale cost.
function Lg.PaidIndex()
	local by = {}
	for _, b in ipairs(Lg.Records("Buys")) do
		if b.id and b.quantity > 0 then
			local e = by[b.id] or {}
			by[b.id] = e
			e[#e + 1] = b
		end
	end
	for id, list in pairs(by) do
		table.sort(list, function(x, y) return x.time < y.time end)
		local ix = { times = {}, n = { [0] = 0 }, gold = { [0] = 0 } }
		for i, b in ipairs(list) do
			ix.times[i] = b.time
			ix.n[i] = ix.n[i - 1] + b.quantity
			ix.gold[i] = ix.gold[i - 1] + b.amount
		end
		by[id] = ix
	end
	return by
end

-- the last index whose time is <= t (0 if none)
local function upTo(times, t)
	local lo, hi = 0, #times
	while lo < hi do
		local mid = math.floor((lo + hi + 1) / 2)
		if times[mid] <= t then lo = mid else hi = mid - 1 end
	end
	return lo
end

function Lg.PaidAt(index, id, t)
	local ix = index[id]
	if not ix then return nil end
	local j = upTo(ix.times, t)
	if j == 0 then return nil end
	local i = upTo(ix.times, t - 30 * DAY)
	if j > i then return (ix.gold[j] - ix.gold[i]) / (ix.n[j] - ix.n[i]) end
	return (ix.gold[j] - ix.gold[j - 1]) / (ix.n[j] - ix.n[j - 1])
end

--- Cost to make one item at the reagent prices you paid around time t (today's price for any you
--- hadn't bought by then), after Resourcefulness, over what Multicraft makes. Also the paid share.
function Lg.CostAt(acc, index, t)
	local cost, known = 0, 0
	for _, rg in ipairs(acc.reagents or {}) do
		local p = Lg.PaidAt(index, rg.itemID, t)
		local each = p or (rg.cost and rg.n > 0 and rg.cost / rg.n) or 0
		cost = cost + each * rg.n
		if p then known = known + each * rg.n end
	end
	local saved = (acc.cost and acc.cost > 0) and (acc.resGold or 0) / acc.cost or 0
	local items = (acc.made or 1) + (acc.extraItems or 0)
	return cost * (1 - saved) / math.max(items, 0.01), cost > 0 and known / cost or 0
end

--- Profit by crafted item over a period: sales after the cut less the cost of making them, each sale
--- at the reagent prices you paid in the 30 days before it (so buying more later never rewrites an
--- earlier period). Estimated: it uses the recipe's current reagent mix and procs from your scans.
--- { id, name, line, sold, revenue, cost, each, profit, margin, paidShare }.
local plCache = setmetatable({}, { __mode = "k" })
function Lg.ProductPL(since, char)
	-- one build per set of records: Performance asks for several periods and characters in a row
	local sales, buys = Lg.Records("Sales"), Lg.Records("Buys")
	local c = plCache[sales]
	local now = GetTime and GetTime() or 0
	if not c or c.buys ~= buys or now - c.at > 60 then -- and at most a minute old, for new scans
		c = { buys = buys, crafted = Lg.Crafted(), index = Lg.PaidIndex(), memo = {}, at = now }
		plCache[sales] = c
	end
	local key = tostring(since) .. "|" .. tostring(char)
	if c.memo[key] then return c.memo[key] end
	local crafted, index = c.crafted, c.index
	local rows = {}
	for _, s in ipairs(sales) do
		local cr = s.id and crafted[s.id]
		if cr and s.time >= since and (not char or s.player == char) then
			local e = rows[s.id]
			if not e then
				e = { id = s.id, name = cr.name, line = CH.Paths and CH.Paths.MainGroup and CH.Paths.MainGroup(cr.name) or "Other",
					sold = 0, revenue = 0, cost = 0, known = 0 }
				rows[s.id] = e
			end
			local each, share = Lg.CostAt(cr.acc, index, s.time)
			e.sold = e.sold + s.quantity
			e.revenue = e.revenue + Lg.Net(s)
			e.cost = e.cost + each * s.quantity
			e.known = e.known + share * s.quantity
		end
	end
	local out = {}
	for _, e in pairs(rows) do
		e.line = e.line or "Other"
		e.each = e.sold > 0 and e.cost / e.sold or 0
		e.paidShare = e.sold > 0 and e.known / e.sold or 0
		e.profit = e.revenue - e.cost
		e.margin = e.revenue > 0 and e.profit / e.revenue or 0
		table.insert(out, e)
	end
	c.memo[key] = out
	return out
end

--- Last time each item sold: { [itemID] = time }.
function Lg.LastSold()
	local t = {}
	for _, s in ipairs(Lg.Records("Sales")) do
		if s.id and (not t[s.id] or s.time > t[s.id]) then t[s.id] = s.time end
	end
	return t
end

-- Per item: last sale, expiries since it, and 30-day sold and expired units (both in units, so a
-- stack that partly sells and partly expires counts right). Rebuilt at most once a minute.
local stats, statsAt
local function itemStats()
	local now = GetTime and GetTime() or 0
	if stats and statsAt and now - statsAt < 60 then return stats end
	stats, statsAt = {}, now
	local cut = time() - 30 * DAY
	local function e(id) local x = stats[id]; if not x then x = { last = 0, since = 0, sold30 = 0, exp30 = 0, n = 0, gold = 0 }; stats[id] = x end return x end
	for _, s in ipairs(Lg.Records("Sales")) do
		if s.id then
			local x = e(s.id)
			if s.time > x.last then x.last = s.time end
			if s.time >= cut then x.sold30 = x.sold30 + s.quantity end
			x.n, x.gold = x.n + s.quantity, x.gold + (s.amount or 0)
		end
	end
	for _, r in ipairs(Lg.Records("Expired")) do
		if r.id then
			local x = e(r.id)
			if r.time >= cut then x.exp30 = x.exp30 + math.max(1, r.quantity or 1) end
		end
	end
	for _, r in ipairs(Lg.Records("Expired")) do
		if r.id and r.time > stats[r.id].last then stats[r.id].since = stats[r.id].since + 1 end
	end
	return stats
end
function Lg.ClearStats() stats = nil; parsed = {} end

--- How many times an item expired since it last sold (TSM's numexpires).
function Lg.NumExpires(id) local x = itemStats()[id]; return x and x.since or 0 end

--- Your average sale price for an item, or nil.
function Lg.AvgSell(id) local x = itemStats()[id]; return x and x.n > 0 and x.gold / x.n or nil end

--- Sold units and expiries in the last 30 days: sold, expired.
function Lg.SellThrough(id) local x = itemStats()[id]; return x and x.sold30 or 0, x and x.exp30 or 0 end

--- Stock that isn't moving: held items with no sale in `days` days or 3+ expiries in that time.
--- { id, held, value, lastSold, expired, advice }.
function Lg.DeadStock(now, days, char)
	now, days = now or time(), days or 30
	local since = now - days * DAY
	local last, expired = Lg.LastSold(), {}
	for _, e in ipairs(Lg.Records("Expired")) do
		if e.id and e.time >= since then expired[e.id] = (expired[e.id] or 0) + 1 end
	end
	local out = {}
	for _, e in ipairs(Lg.Inventory(nil, char)) do
		if e.id and e.value > 0 then
			local ls, ex = last[e.id], expired[e.id] or 0
			local idle = not ls or ls < since
			if idle or ex >= 3 then
				local advice = ex >= 3 and "Cut the price or stop posting"
					or (not ls and (ex > 0 and "Never sold: vendor or rethink" or "Never sold here: list it?"))
					or "Slow: lower the price"
				table.insert(out, { id = e.id, held = e.total, value = e.value, lastSold = ls, expired = ex, advice = advice })
			end
		end
	end
	return out
end

--- Your stock against what you paid: { id, held, paid (each), now (each), gain, pct, daysOfStock }.
function Lg.Holdings(now, char)
	now = now or time()
	local paid = Lg.Paid()
	local sold30 = {}
	for _, s in ipairs(Lg.Records("Sales")) do
		if s.id and s.time >= now - 30 * DAY then sold30[s.id] = (sold30[s.id] or 0) + s.quantity end
	end
	local out = {}
	for _, e in ipairs(Lg.Inventory(nil, char)) do
		local p = e.id and paid[e.id]
		if p and e.unit then
			local gain = (e.unit - p.each) * e.total
			local perDay = (sold30[e.id] or 0) / 30
			table.insert(out, { id = e.id, held = e.total, paid = p.each, now = e.unit, gain = gain,
				pct = p.each > 0 and (e.unit - p.each) / p.each or 0, daysOfStock = perDay > 0 and e.total / perDay or nil })
		end
	end
	return out
end

--- Overhead since a time: TSM's other expenses (repairs, postage and so on, not transfers between
--- your characters) by type, plus totals to set against trading. { types = { type, n, gold }, total,
--- sales (after cut), buys, profit, afterOverhead }.
function Lg.Overhead(since, char)
	local mine = own()
	local types, list, total = {}, {}, 0
	for _, r in ipairs(Lg.Records("Expense")) do
		if r.time >= since and not mine[r.other] and (not char or r.player == char) then
			local k = r.source or "Other"
			if not types[k] then types[k] = { type = k, n = 0, gold = 0 }; table.insert(list, types[k]) end
			types[k].n, types[k].gold = types[k].n + 1, types[k].gold + r.amount
			total = total + r.amount
		end
	end
	local sales, buys = 0, 0
	for _, s in ipairs(Lg.Records("Sales")) do if s.time >= since and (not char or s.player == char) then sales = sales + Lg.Net(s) end end
	for _, b in ipairs(Lg.Records("Buys")) do if b.time >= since and (not char or b.player == char) then buys = buys + b.amount end end
	return { types = list, total = total, sales = sales, buys = buys, profit = sales - buys, afterOverhead = sales - buys - total }
end

-- When things sell ---------------------------------------------------------------------------
--- Your sales of each item by weekday and hour: { id, sold, gold, days = {[1..7]=n}, hours = {[0..23]=n},
--- bestDay (1 = Sunday), bestHour (start of the best 4-hour window), share (of sales in that window) }.
function Lg.SaleTimes(since, char)
	local t = {}
	for _, s in ipairs(Lg.Records("Sales")) do
		if s.id and s.time >= (since or -math.huge) and (not char or s.player == char) then
			local e = t[s.id]
			if not e then e = { id = s.id, sold = 0, gold = 0, days = {}, hours = {} }; t[s.id] = e end
			local d = date("*t", s.time)
			e.sold, e.gold = e.sold + s.quantity, e.gold + s.amount
			e.days[d.wday] = (e.days[d.wday] or 0) + s.quantity
			e.hours[d.hour] = (e.hours[d.hour] or 0) + s.quantity
		end
	end
	local out = {}
	for _, e in pairs(t) do
		local bd, bv = 1, -1
		for d = 1, 7 do if (e.days[d] or 0) > bv then bd, bv = d, e.days[d] or 0 end end
		local bh, hv = 0, -1
		for h = 0, 23 do
			local w = 0
			for k = 0, 3 do w = w + (e.hours[(h + k) % 24] or 0) end
			if w > hv then bh, hv = h, w end
		end
		e.bestDay, e.bestHour, e.share = bd, bh, e.sold > 0 and hv / e.sold or 0
		table.insert(out, e)
	end
	return out
end

-- Competition --------------------------------------------------------------------------------
local function rivals()
	CH.db.competition = CH.db.competition or {}
	return CH.db.competition
end

--- Note what a search found for an item: whether someone outside your account was cheaper, and who.
function Lg.NoteCompetition(id, beaten, owners)
	local c = rivals()[id] or { seen = 0, beaten = 0, by = {} }
	rivals()[id] = c
	c.seen, c.at = c.seen + 1, time()
	if beaten then
		c.beaten = c.beaten + 1
		for _, o in ipairs(owners or {}) do c.by[o] = (c.by[o] or 0) + 1 end
	end
end

--- Per item: how often you're undercut and cancel, and by whom. { id, cancels, seen, beaten, rival, status }.
function Lg.Competition(since)
	local cancels = {}
	for _, r in ipairs(Lg.Records("Cancelled")) do
		if r.id and r.time >= (since or -math.huge) then cancels[r.id] = (cancels[r.id] or 0) + 1 end
	end
	local ids = {}
	for id in pairs(cancels) do ids[id] = true end
	for id in pairs(rivals()) do ids[id] = true end
	local out = {}
	for id in pairs(ids) do
		local c = rivals()[id] or { seen = 0, beaten = 0, by = {} }
		local rival, rn = nil, 0
		for o, n in pairs(c.by) do if n > rn then rival, rn = o, n end end
		local rate = c.seen > 0 and c.beaten / c.seen or nil
		local n = cancels[id] or 0
		local status = (n >= 5 or (rate and rate >= 0.6)) and "contested" or ((rate and rate >= 0.3) or n >= 2) and "busy" or "safe"
		table.insert(out, { id = id, cancels = n, seen = c.seen, beaten = c.beaten, rate = rate, rival = rival, status = status })
	end
	return out
end

-- Morning report -----------------------------------------------------------------------------
--- What changed and what needs doing: last day's sales and buys, items you sold this week and
--- now hold none of, and what came back unsold (and what keeps coming back).
function Lg.Report(now)
	now = now or time()
	local day, week, fortnight = now - DAY, now - 7 * DAY, now - 14 * DAY
	local r = { sold = 0, earned = 0, bought = 0, spent = 0, top = {}, restock = {}, expired = {}, stale = {} }
	local byItem = {}
	for _, s in ipairs(Lg.Records("Sales")) do
		if s.time >= day then
			r.sold, r.earned = r.sold + s.quantity, r.earned + Lg.Net(s)
			if s.id then byItem[s.id] = (byItem[s.id] or 0) + Lg.Net(s) end
		end
	end
	for _, b in ipairs(Lg.Records("Buys")) do
		if b.time >= day then r.bought, r.spent = r.bought + b.quantity, r.spent + b.amount end
	end
	for id, g in pairs(byItem) do table.insert(r.top, { id = id, gold = g }) end
	table.sort(r.top, function(a, b) return a.gold > b.gold end)
	for i = #r.top, 4, -1 do r.top[i] = nil end
	-- sold this week, none left anywhere
	local held = {}
	for _, e in ipairs(Lg.Inventory()) do if e.id then held[e.id] = e.total end end
	local weekly = {}
	for _, s in ipairs(Lg.Records("Sales")) do
		if s.time >= week and s.id and (held[s.id] or 0) == 0 then
			local e = weekly[s.id] or { id = s.id, sold = 0, gold = 0 }
			weekly[s.id] = e
			e.sold, e.gold = e.sold + s.quantity, e.gold + Lg.Net(s)
		end
	end
	for _, e in pairs(weekly) do table.insert(r.restock, e) end
	table.sort(r.restock, function(a, b) return a.gold > b.gold end)
	for i = #r.restock, 6, -1 do r.restock[i] = nil end
	-- came back in the last day; and what has come back 3+ times in two weeks
	local back, count = {}, {}
	for _, e in ipairs(Lg.Records("Expired")) do
		if e.id and e.time >= fortnight then
			count[e.id] = (count[e.id] or 0) + 1
			if e.time >= day then back[e.id] = (back[e.id] or 0) + e.quantity end
		end
	end
	for id, n in pairs(back) do table.insert(r.expired, { id = id, n = n }) end
	table.sort(r.expired, function(a, b) return a.n > b.n end)
	for id, n in pairs(count) do if n >= 3 then table.insert(r.stale, { id = id, times = n }) end end
	table.sort(r.stale, function(a, b) return a.times > b.times end)
	r.worth = Lg.WorthChange(day)
	return r
end

CH.On("PLAYER_LOGIN", function()
	C_Timer.After(10, function()
		if Lg.Available() then pcall(Lg.Archive); pcall(Lg.Snapshot) end
	end)
end)
