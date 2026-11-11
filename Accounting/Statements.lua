-- Accounting statements: Income Statement, Balance Sheet and Cash Flow, the accountant's view of
-- the same records the Ledger views list. Each line opens the transactions behind it.
--
--   Income Statement: what you earned over the period. Sales are booked when they sell, against what
--     those items cost you (cost of goods sold); buying stock isn't an expense until it sells.
--   Balance Sheet: what you hold now. Inventory at the lower of cost or net realizable value (what
--     it sells for after the AH cut and the deposits you expect to lose); gathered and looted items,
--     which cost nothing, at net realizable value. Market value is a memo line.
--   Cash Flow: why your gold changed over the period. TSM's gold log sets the change; the ledger
--     classifies what it can, and the rest is Unclassified gold movement. Gold moved between your
--     own characters is neither in nor out.
local _, CH = ...

local St = {}
CH.Statements = St

local DAY = 86400
local WEEK = 7 * DAY

-- Periods ------------------------------------------------------------------------------------
-- "This week" runs from the weekly reset, like the game's own week.
St.PERIODS = { "week", "lastweek", "30", "all" }
local LABEL = { week = "This week", lastweek = "Last week", ["30"] = "Last 30 days", all = "All time" }
local period = "week"
local custom -- { from, to, label }: a week opened from Performance's chart

--- When this week began: the last weekly reset (seven days ago without the game's clock).
function St.WeekStart(now)
	now = now or time()
	local left = C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset and C_DateAndTime.GetSecondsUntilWeeklyReset()
	if left and left > 0 then return now + left - WEEK end
	return now - WEEK
end

--- The open period's range: from, to, label.
function St.Range(p, now)
	p, now = p or period, now or time()
	if p == "custom" and custom then return custom.from, custom.to, custom.label end
	local wk = St.WeekStart(now)
	if p == "lastweek" then return wk - WEEK, wk, LABEL[p] end
	if p == "30" then return now - 30 * DAY, now, LABEL[p] end
	if p == "all" then return 0, now, LABEL[p] end
	return wk, now, LABEL.week
end

function St.Period() return period end
function St.SetPeriod(p) if LABEL[p] then period = p end return period end
--- Open the statements on any range (a week picked on Performance's chart). The period button
--- steps back to the usual periods from it.
function St.SetRange(from, to, label)
	custom = { from = from, to = to, label = label or "Custom" }
	period = "custom"
	return period
end
function St.Step(dir)
	local i = dir and dir < 0 and 2 or #St.PERIODS
	for k, p in ipairs(St.PERIODS) do if p == period then i = k end end
	period = St.PERIODS[(i - 1 + (dir or 1)) % #St.PERIODS + 1]
	return period
end

-- Shared pieces --------------------------------------------------------------------------------
local function mine()
	local set = {}
	for _, c in ipairs(CH.Ledger.Characters()) do set[c.name] = true end
	return set
end

-- In range and in scope: one character, or (none named) the characters the Dashboard includes, so
-- the statement and the gold series it explains always cover the same characters
local function within(r, from, to, char)
	if r.time < from or r.time >= to + 1 then return false end
	if char then return r.player == char end
	return not r.player or CH.Ledger.Included(r.player)
end
local function isAuction(r) return r.source == nil or r.source == "Auction" end

-- What one unit of an item cost you at time t: crafted at the reagent prices you paid, bought at
-- what you paid. nil when it cost you nothing you recorded (gathered, looted, a quest reward).
local function costEach(id, t, ctx)
	local cr = ctx.crafted[id]
	if cr then
		local each, share = CH.Ledger.CostAt(cr.acc, ctx.index, t)
		return each, "crafted", share
	end
	local p = CH.Ledger.PaidAt(ctx.index, id, t)
	if p then return p, "bought", 1 end
	return nil, "gathered"
end

local function context()
	local L = CH.Ledger
	return { crafted = L.Crafted(), index = L.PaidIndex() }
end

-- Income Statement -----------------------------------------------------------------------------
--- What you earned from `from` to `to`: { auction, cut, other, net, cogs = { crafted, bought, free,
--- freeUnits }, gross, deposits, expenses = { { type, gold } }, expenseTotal, income, netIncome }.
function St.Income(from, to, char)
	local L, E = CH.Ledger, CH.Expect
	local ctx, own = context(), mine()
	local s = { auction = 0, other = 0, cogs = { crafted = 0, bought = 0, free = 0, freeUnits = 0 }, deposits = 0, expenses = {}, expenseTotal = 0, income = 0 }
	for _, r in ipairs(L.Records("Sales")) do
		if within(r, from, to, char) then
			if isAuction(r) then s.auction = s.auction + (r.amount or 0) else s.other = s.other + (r.amount or 0) end
			local each, how, share = costEach(r.id, r.time, ctx)
			if each then
				s.cogs[how] = s.cogs[how] + each * r.quantity
				s.cogs.backed = (s.cogs.backed or 0) + each * r.quantity * (share or 0)
			else s.cogs.freeUnits = s.cogs.freeUnits + r.quantity end
		end
	end
	s.cut = -s.auction * (1 - CH.AH_CUT)
	s.net = s.auction + s.cut + s.other
	s.cogsTotal = s.cogs.crafted + s.cogs.bought
	s.cogs.backedShare = s.cogsTotal > 0 and (s.cogs.backed or 0) / s.cogsTotal or nil
	s.gross = s.net - s.cogsTotal
	-- deposits lost on listings that expired or were cancelled (TSM doesn't record deposits: estimated)
	for _, kind in ipairs({ "Expired", "Cancelled" }) do
		for _, r in ipairs(L.Records(kind)) do
			if within(r, from, to, char) and r.id and E and E.LostDeposit then s.deposits = s.deposits + E.LostDeposit(r.id, r.quantity) end
		end
	end
	local types = {}
	for _, r in ipairs(L.Records("Expense")) do
		if within(r, from, to, char) and not own[r.other] then
			local k = r.source or "Other"
			if not types[k] then types[k] = { type = k, gold = 0 }; table.insert(s.expenses, types[k]) end
			types[k].gold = types[k].gold + r.amount
			s.expenseTotal = s.expenseTotal + r.amount
		end
	end
	table.sort(s.expenses, function(a, b) return a.gold > b.gold end)
	for _, r in ipairs(L.Records("Income")) do
		if within(r, from, to, char) and not own[r.other] then s.income = s.income + r.amount end
	end
	s.netIncome = s.gross - s.deposits - s.expenseTotal + s.income
	return s
end

--- Each item's profit from `from` to `to` on the Income Statement's basis (sales after the AH cut,
--- less what the units cost you): { [id] = { id, sold, revenue, cost, profit, each } }. Their profits
--- add up to the statement's gross profit, less sales TSM logged without an item.
function St.Items(from, to, char)
	local L = CH.Ledger
	local ctx, out = context(), {}
	for _, r in ipairs(L.Records("Sales")) do
		if r.id and within(r, from, to, char) then
			local x = out[r.id] or { id = r.id, sold = 0, revenue = 0, cost = 0 }
			out[r.id] = x
			x.sold = x.sold + (r.quantity or 0)
			x.revenue = x.revenue + (isAuction(r) and (r.amount or 0) * CH.AH_CUT or (r.amount or 0))
			local each = costEach(r.id, r.time, ctx)
			x.cost = x.cost + (each or 0) * (r.quantity or 0)
		end
	end
	for _, x in pairs(out) do
		x.profit = x.revenue - x.cost
		x.each = x.sold > 0 and x.cost / x.sold or 0
	end
	return out
end

-- Balance Sheet --------------------------------------------------------------------------------
--- One item's value per unit: book (what the Balance Sheet carries), nrv, cost (nil if it cost
--- nothing), how ("crafted", "bought" or "gathered"), market.
function St.Value(e, ctx, now)
	if not e.unit or e.unit <= 0 then return nil end
	local E = CH.Expect
	local nrv = (E and E.Value and E.Value(e.id, e.unit)) or e.unit * CH.AH_CUT
	nrv = math.max(0, nrv)
	local cost, how = costEach(e.id, now, ctx)
	return { book = cost and math.min(cost, nrv) or nrv, nrv = nrv, cost = cost, how = how, market = e.unit }
end

--- What you hold now: { gold, holders = { { name, money } }, held = { book, market, costed, free },
--- listed = { book, market }, assets, market (inventory at market), unrealized }.
function St.Balance(char, now)
	local L = CH.Ledger
	now = now or time()
	local ctx = context()
	local b = { holders = {}, gold = 0, held = { book = 0, market = 0, costed = 0, free = 0, writedown = 0 }, listed = { book = 0, market = 0 },
		liquid = { week = 0, slow = 0, dead = 0, n = { week = 0, slow = 0, dead = 0 } } }
	-- how fast each item turns back into gold: your own sales over 30 days
	local sold30 = {}
	for _, r in ipairs(L.Records("Sales")) do
		if r.id and r.time >= now - 30 * 86400 then sold30[r.id] = (sold30[r.id] or 0) + (r.quantity or 0) end
	end
	for _, h in ipairs(L.Holders()) do
		if h.included ~= false and (not char or h.name == char) then
			table.insert(b.holders, { name = h.name, money = h.money or 0 })
			b.gold = b.gold + (h.money or 0)
		end
	end
	table.sort(b.holders, function(x, y) return x.money > y.money end)
	for _, e in ipairs(L.Inventory(nil, char)) do
		local v = not e.bound and St.Value(e, ctx, now)
		if v then
			local listed = e.ah or 0
			local held = (e.total or 0) - listed
			b.held.book = b.held.book + v.book * held
			b.held.market = b.held.market + v.market * held
			if v.how == "gathered" then b.held.free = b.held.free + v.book * held
			else
				b.held.costed = b.held.costed + v.book * held
				if v.cost and v.cost > v.nrv then b.held.writedown = b.held.writedown + (v.cost - v.nrv) * held end
			end
			b.listed.book = b.listed.book + v.book * listed
			b.listed.market = b.listed.market + v.market * listed
			local worth = v.book * (e.total or 0)
			local k = St.Speed(e.total or 0, sold30[e.id] or 0)
			b.liquid[k] = b.liquid[k] + worth
			b.liquid.n[k] = b.liquid.n[k] + 1
			if not b.top or worth > b.top.worth then b.top = { id = e.id, name = e.name, worth = worth, units = e.total, v = v } end
		end
	end
	b.inventory = b.held.book + b.listed.book
	b.assets = b.gold + b.inventory
	b.market = b.held.market + b.listed.market
	b.unrealized = b.market - b.inventory
	-- gold already promised: reagents still to buy for the crafts you've queued
	b.committed = 0
	if CH.Queue and CH.Queue.ShoppingList then
		local ok, _, total = pcall(CH.Queue.ShoppingList)
		if ok then b.committed = total or 0 end
	end
	b.freeGold = b.gold - b.committed
	return b
end

--- How fast stock turns back into gold, from your own sales: "week" (sells within a week),
--- "slow" (1 to 4 weeks) or "dead" (none sold in 30 days, or over 4 weeks of stock).
function St.Speed(held, sold30)
	if (sold30 or 0) <= 0 then return "dead" end
	local days = held / (sold30 / 30)
	if days <= 7 then return "week" end
	if days <= 28 then return "slow" end
	return "dead"
end

--- Why net worth (gold plus inventory at AuctionIQ value, the daily snapshot) moved since `from`:
--- { opening, netIncome, unclassified, prices (the rest: price changes on stock you hold and stock
--- you gathered), closing, since (the snapshot day it starts from) } or nil without snapshots.
function St.Bridge(from, to)
	local L = CH.Ledger
	if not L.WorthChange then return nil end
	local change, first, last, firstK = L.WorthChange(from)
	if not change then return nil end
	local opening, closing = first.gold + first.inventory, last.gold + last.inventory
	local inc = St.Income(from, to)
	local cash = St.Cash(from, to)
	local x = { opening = opening, closing = closing, netIncome = inc.netIncome or 0, unclassified = cash.unclassified or 0, since = firstK }
	x.prices = closing - opening - x.netIncome - x.unclassified
	return x
end

-- Cash Flow ------------------------------------------------------------------------------------
--- Why gold changed from `from` to `to`: { opening, closing, change, inflows = { auction, other,
--- income }, outflows = { buys, expenses }, classified, unclassified }. The opening and closing come
--- from TSM's gold log; transfers between your own characters aren't counted either way.
function St.Cash(from, to, char)
	local L = CH.Ledger
	local own = mine()
	local c = { inflows = { auction = 0, other = 0, income = 0 }, outflows = { buys = 0, expenses = 0 } }
	for _, r in ipairs(L.Records("Sales")) do
		if within(r, from, to, char) then
			if isAuction(r) then c.inflows.auction = c.inflows.auction + L.Net(r) else c.inflows.other = c.inflows.other + L.Net(r) end
		end
	end
	for _, r in ipairs(L.Records("Income")) do
		if within(r, from, to, char) and not own[r.other] then c.inflows.income = c.inflows.income + r.amount end
	end
	for _, r in ipairs(L.Records("Buys")) do
		if within(r, from, to, char) then c.outflows.buys = c.outflows.buys - r.amount end
	end
	for _, r in ipairs(L.Records("Expense")) do
		if within(r, from, to, char) and not own[r.other] then c.outflows.expenses = c.outflows.expenses - r.amount end
	end
	c.inTotal = c.inflows.auction + c.inflows.other + c.inflows.income
	c.outTotal = c.outflows.buys + c.outflows.expenses
	c.classified = c.inTotal + c.outTotal
	local series = L.GoldSeries(math.max(from, 0), to, 2)
	local function goldOf(pt)
		if not pt then return nil end
		if not char then return pt.v end
		for _, x in ipairs(pt.by or {}) do if x.name == char then return x.v end end
		return 0
	end
	c.opening, c.closing = goldOf(series[1]), goldOf(series[#series])
	if c.opening and c.closing then
		c.change = c.closing - c.opening
		c.unclassified = c.change - c.classified
	end
	return c
end

-- Views ----------------------------------------------------------------------------------------
local LUI = CH.LedgerUI
local T = CH.Theme
local function money(c) return CH.FormatMoney and CH.FormatMoney(c or 0) or tostring(c) end
local function amount(c, kind)
	if not c then return T.Color("muted", "-") end
	if kind == "total" then return T.Color(c >= 0 and "ok" or "bad", money(c)) end
	if kind == "memo" then return T.Color("muted", money(c)) end
	return c < 0 and T.Color("bad", money(c)) or money(c)
end

-- A statement's lines in order: { label, gold, kind = "head" | "line" | "sub" | "total" | "memo" |
-- "gap", go = { tab, view }, tip }. Headings and totals stand out; lines that open something say so.
local function lines(list)
	local out = {}
	for i, l in ipairs(list) do
		local label = l[1]
		if l.kind == "head" then label = T.Color("accent", string.upper(label))
		elseif l.kind == "sub" then label = "      " .. label
		elseif l.kind == "line" then label = "   " .. label
		elseif l.kind == "total" then label = T.Color("fg", label)
		elseif l.kind == "memo" then label = "   " .. T.Color("muted", label) end
		local val = (l.kind == "head" or l.kind == "gap") and "" or amount(l[2], l.kind)
		local tip = l.tip and { { l[1] }, { T.Color("muted", l.tip) } } or nil
		if l.go then
			tip = tip or { { l[1] } }
			table.insert(tip, { T.Color("accent", "Click for the transactions behind it.") })
		end
		table.insert(out, { key = "st" .. i, cells = { label, val }, sort = { i, i }, go = l.go, tip = tip })
	end
	return out
end

local function periodNote(from, to)
	local _, _, label = St.Range()
	local d = date and date("%b %d", from) or tostring(from)
	return T.Color("muted", label .. (period ~= "all" and (" (from " .. d .. ")") or ""))
end

local function incomeRows(ctx)
	local from, to = St.Range(nil, ctx.now)
	local s = St.Income(from, to, ctx.opts.char)
	local list = {
		{ "Revenue", kind = "head" },
		{ "Auction sales", s.auction, kind = "line", go = { "ledger", "sales" }, tip = "What your auctions sold for, before the AH cut." },
		{ "AH cut (5%)", s.cut, kind = "sub", tip = "The auction house keeps 5% of each sale." },
		{ "Vendor and trade sales", s.other, kind = "line", go = { "ledger", "sales" } },
		{ "Net sales", s.net, kind = "total" },
		{ "Cost of goods sold", kind = "head" },
		{ "Crafted items", -s.cogs.crafted, kind = "line", go = { "ledger", "pl" },
			tip = "What the crafts you sold cost to make: their reagents at what you paid in the 30 days before each sale (today's price for any you never bought), after Resourcefulness and Multicraft." },
		{ "Resold items", -s.cogs.bought, kind = "line", go = { "ledger", "purchases" }, tip = "What you paid for the items you bought and sold again." },
		{ string.format("Gathered and looted (%d sold, no cost)", s.cogs.freeUnits), 0, kind = "line",
			tip = "Items you sold that cost you nothing you recorded: gathered, looted or rewards. Their sales are all profit." },
		{ s.cogs.backedShare and string.format("Backed by your purchase records: %d%% of that cost", math.floor(s.cogs.backedShare * 100 + 0.5)) or "No cost of goods sold yet",
			s.cogsTotal > 0 and -s.cogsTotal or 0, kind = "memo",
			tip = "The rest uses today's reagent prices, for reagents you didn't buy in the 30 days before each sale (gathered, or bought earlier)." },
		{ "Gross profit", s.gross, kind = "total", tip = "Net sales less what the items you sold cost." },
		{ "Operating expenses", kind = "head" },
		{ "Deposits lost (estimated)", -s.deposits, kind = "line", go = { "ledger", "expired" },
			tip = "Deposits you lost on listings that expired or were cancelled. TSM doesn't record deposits, so each is the deposit the item would take now." },
	}
	for _, e in ipairs(s.expenses) do table.insert(list, { e.type, -e.gold, kind = "line", go = { "ledger", "expense" } }) end
	if not s.expenses[1] then table.insert(list, { "Other expenses", 0, kind = "line", go = { "ledger", "expense" } }) end
	table.insert(list, { "Other income", s.income, kind = "line", go = { "ledger", "income" }, tip = "Quest gold and other gold TSM logged as income, not from your own characters." })
	table.insert(list, { "Net income", s.netIncome, kind = "total", tip = "Gross profit, less expenses, plus other income. Buying stock isn't an expense here: it costs you when it sells." })
	return lines(list), periodNote(from, to) .. T.Color("muted", "   Purchases are on the Balance Sheet until they sell. Click a line for its transactions.")
end

local function balanceRows(ctx)
	local b = St.Balance(ctx.opts.char, ctx.now)
	local list = { { "Assets", kind = "head" }, { "Gold", b.gold, kind = "line", tip = "Gold on each character and in the warband bank, from TSM." } }
	for i, h in ipairs(b.holders) do
		if i <= 6 then table.insert(list, { h.name, h.money, kind = "sub" }) end
	end
	if #b.holders > 6 then
		local rest = 0
		for i = 7, #b.holders do rest = rest + b.holders[i].money end
		local n = #b.holders - 6
		if rest > 0 then table.insert(list, { n == 1 and b.holders[7].name or string.format("%d others", n), rest, kind = "sub" }) end
	end
	table.insert(list, { "Inventory, by how fast it becomes gold", b.inventory, kind = "line", go = { "ledger", "inventory" },
		tip = string.format("Bags, banks, mail, the warband bank and the AH, each item at the lower of what it cost and what it would bring after the AH cut and expected lost deposits. Bought or crafted %s%s; gathered or looted %s.",
			money(b.held.costed + 0), b.held.writedown > 0 and (" (written down " .. money(b.held.writedown) .. ")") or "", money(b.held.free)) })
	table.insert(list, { string.format("Sells within a week (%d items)", b.liquid.n.week), b.liquid.week, kind = "sub", go = { "ledger", "inventory" },
		tip = "At your own sales rate over the last 30 days, what you hold sells in 7 days or less." })
	table.insert(list, { string.format("Slow: 1 to 4 weeks (%d items)", b.liquid.n.slow), b.liquid.slow, kind = "sub", go = { "ledger", "inventory" },
		tip = "At your sales rate, these take 1 to 4 weeks to sell." })
	table.insert(list, { string.format("Dead or unsellable (%d items)", b.liquid.n.dead), b.liquid.dead, kind = "sub", go = { "operations", "dead" },
		tip = "None sold in 30 days, or over 4 weeks of stock at your sales rate. Gold you can't count on soon." })
	table.insert(list, { "Of which listed on the auction house", b.listed.book, kind = "memo", go = { "operations", "post" }, tip = "Items on the AH now, valued the same way." })
	-- one item can carry most of the value: say so, with what its value rests on
	if b.top and b.inventory > 0 and b.top.worth / b.inventory >= 0.25 then
		local t = b.top
		table.insert(list, { string.format("Largest: %s, %d%% of inventory", t.name or ("item " .. tostring(t.id)), math.floor(t.worth / b.inventory * 100 + 0.5)),
			t.worth, kind = "memo", go = { "ledger", "inventory" },
			tip = string.format("%d held at %s each (%s). Market price %s from AuctionIQ value, %s after the cut and expected lost deposits. Check its live price before relying on this total.",
				t.units or 0, money(t.v.book), t.v.how == "gathered" and "no cost recorded, so net value" or ("cost " .. money(t.v.cost or 0) .. ", carried at the lower of cost or net value"),
				money(t.v.market), money(t.v.nrv)) })
	end
	table.insert(list, { "Total assets", b.assets, kind = "total" })
	table.insert(list, { "Commitments", kind = "head" })
	table.insert(list, { "Reagents to buy for your queue", b.committed > 0 and -b.committed or 0, kind = "line", go = { "operations", "shopping" },
		tip = "Gold you've already promised: the reagents your queued crafts still need, at today's prices. Nothing in WoW is owed, so this is the only claim on your gold." })
	table.insert(list, { "Free gold", b.freeGold, kind = "total", tip = "Gold less what your queue still has to buy: what you can spend without dropping a planned craft." })
	table.insert(list, { "Net worth", b.assets, kind = "total", tip = "What you own: gold plus inventory at book value. Buying the queue's reagents swaps gold for stock, so it doesn't change this." })
	-- how net worth moved over the period, tying the three statements together
	if not ctx.opts.char then
		local from, to = St.Range(nil, ctx.now)
		local x = St.Bridge(from, to)
		if x then
			table.insert(list, { "", nil, kind = "gap" })
			table.insert(list, { "Net worth over the period", kind = "head" })
			table.insert(list, { "Opening net worth", x.opening, kind = "total", tip = "Gold plus inventory at AuctionIQ value, from the first daily snapshot in the period." })
			table.insert(list, { "Net income", x.netIncome, kind = "line", go = { "ledger", "statement" }, tip = "From the Income Statement for the same period." })
			table.insert(list, { "Unclassified gold movement", x.unclassified, kind = "line", go = { "ledger", "cashflow" }, tip = "From the Cash Flow statement for the same period." })
			table.insert(list, { "Price changes on stock you hold, and other", x.prices, kind = "line", go = { "ledger", "inventory" },
				tip = "The rest of the change: market prices moving on what you hold, and stock gathered or looted. Snapshots value stock at market, so this also carries the gap between market and book value." })
			table.insert(list, { "Closing net worth", x.closing, kind = "total", tip = "Today's snapshot." })
		end
	end
	table.insert(list, { "", nil, kind = "gap" })
	table.insert(list, { "Memo: inventory at market value", b.market, kind = "memo", tip = "Every item at its AuctionIQ market price, before the AH cut. The Dashboard's figure." })
	table.insert(list, { "Memo: profit not yet made", b.unrealized, kind = "memo", tip = "Market value less book value: what selling everything at market would add, before the cut. Not counted until it sells." })
	return lines(list), T.Color("muted", "As of now (TSM keeps no history of what you held). Inventory: lower of cost or net realizable value.")
end

local function cashRows(ctx)
	local from, to = St.Range(nil, ctx.now)
	local c = St.Cash(from, to, ctx.opts.char)
	local list = {
		{ "Opening gold", c.opening, kind = "total" },
		{ "Gold in", kind = "head" },
		{ "Auction sales (after the cut)", c.inflows.auction, kind = "line", go = { "ledger", "sales" } },
		{ "Vendor and trade sales", c.inflows.other, kind = "line", go = { "ledger", "sales" } },
		{ "Other income", c.inflows.income, kind = "line", go = { "ledger", "income" } },
		{ "Gold out", kind = "head" },
		{ "Purchases", c.outflows.buys, kind = "line", go = { "ledger", "purchases" } },
		{ "Expenses", c.outflows.expenses, kind = "line", go = { "ledger", "expense" } },
		{ "Net classified", c.classified, kind = "total", tip = "Gold in less gold out, from the ledger." },
		{ "Unclassified gold movement", c.unclassified, kind = "line",
			tip = "What the gold log moved that the ledger doesn't explain: bank and guild transfers, deposits, mail TSM didn't log, gold from characters it doesn't track. Gold sent between your own characters isn't counted either way." },
		{ "Closing gold", c.closing, kind = "total" },
	}
	return lines(list), periodNote(from, to) .. T.Color("muted", "   The change in gold is from TSM's gold log; the ledger classifies what it can.")
end

local function periodControl()
	return { label = function() local _, _, l = St.Range(); return l end, tip = "Which period the statement covers.",
		click = function(dir) St.Step(dir) end }
end

local COLS = { { "Line", 0, 470 }, { "Amount", 474, 160 } }
St.VIEWS = {
	statement = { label = "Income Statement", fixed = true, noTime = true, rows = incomeRows, cols = COLS, controls = { periodControl() } },
	balance = { label = "Balance Sheet", fixed = true, noTime = true, rows = balanceRows, cols = COLS },
	cashflow = { label = "Cash Flow", fixed = true, noTime = true, rows = cashRows, cols = COLS, controls = { periodControl() } },
}

if LUI and LUI.Register then
	LUI.Register("ledger", St.VIEWS, { "statement", "balance", "cashflow" }, "Reports")
	LUI.Order("ledger", { "Reports", "Revenue", "Expenses", "Inventory", "Profit" })
end
