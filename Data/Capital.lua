-- Capital allocation: where your gold earns the most gold a day for the gold tied up.
--
-- Each opportunity puts gold in now and gets it back, with a profit, as it sells:
--   craft  a profitable craft from your saved scans, at the batch Compare crafts suggests
--          (Decide.Suggest): gold in is the reagents for the batch, profit is the profit a craft
--          times the crafts, and it's tied up until the batch sells at its sales rate
--   deal   a listing to buy and relist (Deals.lua): gold in is what it costs, profit its gain, tied up
--          until the units sell at their sales rate
--
-- Its return is profit / gold in / days tied up: gold a day for each gold in. Days are at least one
-- (nothing sells the moment it's listed). Your gold, less what you keep back, goes to the best
-- return first, then the next, a whole craft or unit at a time, until it runs out: what's left is
-- idle.
local _, CH = ...

local Cp = { RESERVES = { 0, 0.1, 0.25, 0.5 }, MIN_DAYS = 1 }
CH.Capital = Cp

--- The share of your gold kept back, not allocated (a setting).
function Cp.Reserve()
	local s = CH.db and CH.db.settings
	return s and s.capitalReserve or 0.1
end

function Cp.SetReserve(v)
	CH.db.settings = CH.db.settings or {}
	CH.db.settings.capitalReserve = v
end

--- Step the reserve through RESERVES (dir 1 up, -1 down, wrapping).
function Cp.StepReserve(dir)
	local list, cur, at = Cp.RESERVES, Cp.Reserve(), 1
	for i, v in ipairs(list) do if math.abs(v - cur) < 1e-9 then at = i end end
	at = (at - 1 + dir) % #list + 1
	Cp.SetReserve(list[at])
end

local function opportunity(o)
	o.days = math.max(Cp.MIN_DAYS, o.days or Cp.MIN_DAYS)
	o.rate = o.cost > 0 and o.profit / o.cost / o.days or 0
	o.each = o.cost / o.units
	return o
end

--- Every opportunity: { kind ("craft" or "deal"), id, name, char, units (crafts or items), cost,
--- profit, days, rate, each (gold in per unit) }, best return first. Only ones that make a profit.
function Cp.Opportunities(ctx, now)
	now = now or time()
	ctx = ctx or { now = now, keepName = function() return true end }
	local out = {}
	local AV = CH.AnalyticsViews
	local ok, crafts = pcall(AV and AV.Scenarios or function() return {} end, ctx)
	for _, x in ipairs(ok and crafts or {}) do
		local sg = x.suggest
		local sc = sg and sg.n and sg.n > 0 and sg.scenarios and sg.scenarios.expected
		if sc and sc.cost > 0 and x.profit > 0 then
			local daily = CH.Scan and CH.Scan.DailyUnits and CH.Scan.DailyUnits(x.id) or 0
			local days = daily > 0 and sc.items / daily or nil
			if days then
				out[#out + 1] = opportunity({ kind = "craft", id = x.id, name = x.name, char = x.char, units = sg.n, cost = sc.cost,
					profit = x.profit * sg.n, days = days, x = x })
			end
		end
	end
	local deals = CH.Deals and CH.Deals.Cached and CH.Deals.Cached(now) or nil
	for _, d in ipairs(deals or {}) do
		local units = d.demand and d.demand.units or 0
		if units > 0 and d.cost > 0 and d.gain > 0 then
			local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(d.id) or ("item " .. d.id)
			if ctx.keepName(name) then
				out[#out + 1] = opportunity({ kind = "deal", id = d.id, name = name, units = d.buy, cost = d.cost, profit = d.gain,
					days = d.buy / units, deal = d })
			end
		end
	end
	table.sort(out, function(a, b) if a.rate ~= b.rate then return a.rate > b.rate end return a.profit > b.profit end)
	return out
end

--- Split budget over opportunities (best return first), whole units at a time. Each gets take
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
