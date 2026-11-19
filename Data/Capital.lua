-- Capital allocation: where your gold does the most, measured the same way for every opportunity.
--
-- Each opportunity puts gold in now and gets it back, with a profit, as it sells:
--   craft  a profitable craft from your saved scans, at the batch Compare crafts suggests
--          (Decide.Suggest): gold in is the reagents for the batch, profit is the profit a craft
--          times the crafts, and it's tied up until the batch sells at its sales rate
--   flip   buying a scanned item off the AH to relist it: as many as a week's sales take while each
--          one bought (walking the listings) costs less than relisting it brings in
--
-- The common measures (Phase 5.5), on every opportunity:
--   gain      expected profit over the feasible alternative. For a craft the scan already counts the
--             reagents you hold at what they'd sell for, so its profit is what it adds over selling
--             them (or over doing nothing, when every reagent is bought)
--   cash      the gold it needs up front
--   back      expected days until that gold is back: the items that cover it, at the sales rate
--   downside  the profit in the slow case (half the sales, the price down by the Scenarios fall),
--             unsold stock valued at that price
--   minutes   active minutes, once they're measured (not yet: shown as not measured)
-- The return (profit / gold in / days tied up, gold a day for each gold in) stays as a second
-- figure, never the only one. Your gold, less what you keep back, goes to the first in the ranking
-- you pick (most profit, or best return), then the next, a whole craft at a time, until it runs out:
-- what's left is idle.
local _, AuctionIQ = ...

local Cp = { RESERVES = { 0, 0.1, 0.25, 0.5 }, MIN_DAYS = 1, RANKS = { "gain", "rate" } }
AuctionIQ.Capital = Cp

--- The share of your gold kept back, not allocated (a setting).
function Cp.Reserve()
	local s = AuctionIQ.db and AuctionIQ.db.settings
	return s and s.capitalReserve or 0.1
end

function Cp.SetReserve(v)
	AuctionIQ.db.settings = AuctionIQ.db.settings or {}
	AuctionIQ.db.settings.capitalReserve = v
end

--- Step the reserve through RESERVES (dir 1 up, -1 down, wrapping).
function Cp.StepReserve(dir)
	local list, cur, at = Cp.RESERVES, Cp.Reserve(), 1
	for i, v in ipairs(list) do if math.abs(v - cur) < 1e-9 then at = i end end
	at = (at - 1 + dir) % #list + 1
	Cp.SetReserve(list[at])
end

--- How opportunities are ranked: "gain" (most expected profit, the default) or "rate" (best return).
function Cp.Rank()
	local s = AuctionIQ.db and AuctionIQ.db.settings
	return s and s.capitalRank or "gain"
end

function Cp.StepRank()
	AuctionIQ.db.settings = AuctionIQ.db.settings or {}
	AuctionIQ.db.settings.capitalRank = Cp.Rank() == "gain" and "rate" or "gain"
end

local function better(a, b)
	if Cp.Rank() == "rate" then
		if a.rate ~= b.rate then return a.rate > b.rate end
		return a.profit > b.profit
	end
	if a.profit ~= b.profit then return a.profit > b.profit end
	return a.rate > b.rate
end

local function opportunity(o)
	o.days = math.max(Cp.MIN_DAYS, o.days or Cp.MIN_DAYS)
	o.rate = o.cost > 0 and o.profit / o.cost / o.days or 0
	o.each = o.cost / o.units
	-- the common measures
	o.gain = o.gain or o.profit
	o.cash = o.cash or o.cost
	o.back = o.back or o.days
	return o
end

--- Every opportunity: { kind ("craft"), id, name, char, units (crafts or items), cost,
--- profit, days, rate, each (gold in per unit) }, best return first. Only ones that make a profit.
function Cp.Opportunities(ctx, now)
	now = now or time()
	ctx = ctx or { now = now, keepName = function() return true end }
	local out = {}
	local AV = AuctionIQ.AnalyticsViews
	local ok, crafts = pcall(AV and AV.Scenarios or function() return {} end, ctx)
	for _, x in ipairs(ok and crafts or {}) do
		local sg = x.suggest
		local sc = sg and sg.n and sg.n > 0 and sg.scenarios and sg.scenarios.expected
		if sc and sc.cost > 0 and x.profit > 0 then
			local daily = AuctionIQ.Scan and AuctionIQ.Scan.DailyUnits and AuctionIQ.Scan.DailyUnits(x.id) or 0
			local days = daily > 0 and sc.items / daily or nil
			if days then
				-- the gold is back once enough items have sold to cover it, at each item's money after the cut
				local each = sc.each or 0
				local cover = each > 0 and math.min(sc.items, sc.cost / each) or sc.items
				local slow = sg.scenarios.slow
				out[#out + 1] = opportunity({ kind = "craft", id = x.id, name = x.name, char = x.char, units = sg.n, cost = sc.cost,
					profit = x.profit * sg.n, days = days, x = x, cash = sc.cost, back = math.max(Cp.MIN_DAYS, cover / daily),
					downside = slow and (slow.cash + slow.stockValue - slow.cost) or nil,
					against = "over selling the reagents you hold" })
			end
		end
	end
	-- buy and relist: an item a scan priced, when buying it off the AH and relisting beats what it costs
	local seen = {}
	for _, x in ipairs(ok and crafts or {}) do
		if x.id and not seen[x.id] then
			seen[x.id] = true
			local o = Cp.Flip(x.id, x.row, now)
			if o then out[#out + 1] = opportunity(o) end
		end
	end
	table.sort(out, better)
	return out
end

--- Buying an item off the AH to relist it: as many as a week's sales take while each one bought
--- (walking the listings) still costs less than relisting it brings in. nil when it doesn't pay or
--- there's no sales rate. row: a scan row (for Scan.BuyOrCraft), optional.
function Cp.Flip(id, row, now)
	local Sc = AuctionIQ.Scan
	local bc = Sc and Sc.BuyOrCraft and Sc.BuyOrCraft(row or { item = id })
	if not (bc and bc.flip and bc.flip > 0 and bc.resell) then return nil end
	local daily = Sc.DailyUnits and Sc.DailyUnits(id) or 0
	if daily <= 0 then return nil end
	local Dp, D = AuctionIQ.Depth, AuctionIQ.Decide
	local week = math.max(1, math.floor(daily * (D and D.HORIZON or 7)))
	-- one more is worth buying while its own price (the walk's added cost) is under the resale value
	local q, cost = 0, 0
	for n = 1, week do
		local c = Dp and Dp.Cost(id, n)
		local total = c and c.cost or bc.buy * n
		if total - cost >= bc.resell then break end
		q, cost = n, total
	end
	if q == 0 then return nil end
	local profit = bc.resell * q - cost
	local fall = D and D.Scenario().price or 0.1
	-- slow: half the sales in the week, the price down by the Scenarios fall, the rest held at that price
	local slow = bc.resell * (1 - fall) * q - cost
	local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id) or (row and row.name) or ("item " .. id)
	return { kind = "flip", id = id, name = name, units = q, cost = cost, profit = profit, days = q / daily, cash = cost,
		back = math.min(q, cost / bc.resell) / daily, downside = slow, against = "over not buying" }
end

--- Split budget over opportunities (in ranking order), whole units at a time. Each gets take
--- (units), spend and gain; returns { list, budget, spent, gain, idle, perDay }.
function Cp.Allocate(list, budget)
	local left, spent, gain, perDay = budget, 0, 0, 0
	for _, o in ipairs(list) do
		local n = o.each > 0 and math.min(o.units, math.floor(left / o.each + 1e-9)) or 0
		o.take = n
		o.spend = n * o.each
		o.gain = o.units > 0 and o.profit * n / o.units or 0
		left, spent, gain = left - o.spend, spent + o.spend, gain + o.gain
		-- the batch earns its gain over the days it's tied up
		perDay = perDay + (n > 0 and o.gain / o.days or 0)
	end
	return { list = list, budget = budget, spent = spent, gain = gain, idle = math.max(0, left), perDay = perDay }
end

--- Your gold (this character), less the reserve: what's allocated.
function Cp.Budget()
	local money = GetMoney and GetMoney() or 0
	return math.floor(money * (1 - Cp.Reserve())), money
end

--- The whole plan: Allocate(Opportunities, Budget). With budget, that instead of your gold.
function Cp.Plan(ctx, budget)
	local b, money = Cp.Budget()
	local plan = Cp.Allocate(Cp.Opportunities(ctx), budget or b)
	plan.money = money
	return plan
end
