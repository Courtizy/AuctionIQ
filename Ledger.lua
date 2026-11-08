-- Ledger: gold, sales, purchases and inventory for the Dashboard and Ledger tabs.
--
-- History comes from TSM's own saved data (TradeSkillMasterDB), read only: its gold log per
-- character, its accounting (sales, buys, income, expenses, expired and cancelled auctions) and its
-- inventory counts (bags, bank, mail, auctions, warband bank). Clearinghouse also keeps its own copy:
--   * a daily summary of the accounting, so history survives TSM trimming old records
--   * a daily net worth snapshot (gold + what your inventory is worth at Clearinghouse value), which
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
local parsed = {} -- [key] = { len, rows }

local function csv(key)
	local db = tsm()
	local text = db and db[key]
	if type(text) ~= "string" then return {} end
	local c = parsed[key]
	if c and c.len == #text then return c.rows end
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
	parsed[key] = { len = #text, rows = rows }
	return rows
end

local function num(v) return tonumber(v) or 0 end
local function itemID(s) return tonumber((s or ""):match("^i:(%d+)")) end

--- TSM's records of one kind for this realm: "Sales", "Buys", "Income", "Expense", "Expired",
--- "Cancelled". Each row: time, player, other, item (itemString), id, quantity, price (each),
--- amount (total copper), source or type.
function Lg.Records(kind)
	local out = {}
	for _, r in ipairs(csv("r@" .. realm() .. "@internalData@csv" .. kind)) do
		local q = num(r.quantity)
		local amount = r.amount and num(r.amount) or num(r.price) * q
		table.insert(out, { time = num(r.time), player = r.player, other = r.otherPlayer, item = r.itemString,
			id = itemID(r.itemString), quantity = q, price = num(r.price), amount = amount, source = r.source or r.type })
	end
	return out
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

--- Summarise TSM's accounting by day into Clearinghouse's own archive (days TSM still has are
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
		e.sales, e.sold = e.sales + r.amount, e.sold + r.quantity
		if r.id then e.items[r.id] = (e.items[r.id] or 0) + r.amount end
	end
	for _, r in ipairs(Lg.Records("Buys")) do local e = d(r.time); e.buys = e.buys + r.amount end
	for _, r in ipairs(Lg.Records("Income")) do
		if not mine[r.other] then local e = d(r.time); e.income = e.income + r.amount end
	end
	for _, r in ipairs(Lg.Records("Expense")) do
		if not mine[r.other] then local e = d(r.time); e.expense = e.expense + r.amount end
	end
	local s = store()
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
--- total, value } sorted by value (Clearinghouse value x total). filter is a name keyword.
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
			local unit = CH.Prices.Get("chvalue", e.item)
			e.unit = unit
			e.value = unit and unit * e.total or 0
			table.insert(out, e)
		end
	end
	table.sort(out, function(a, b) return a.value > b.value end)
	return out
end

--- What your inventory is worth now at Clearinghouse value.
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
			r.sold, r.earned = r.sold + s.quantity, r.earned + s.amount
			if s.id then byItem[s.id] = (byItem[s.id] or 0) + s.amount end
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
			e.sold, e.gold = e.sold + s.quantity, e.gold + s.amount
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
