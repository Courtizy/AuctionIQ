-- Specialization presets: a ready-made build for each thing a profession sells (Potions, and Light
-- or Void potions within them, Flasks, Disenchanting...), worked out on your market, from your build
-- now to that focus finished. They aren't applied; they're there to look at and compare.
--
-- Each preset is the knowledge point planner (Paths.lua) run for that focus with the points it
-- takes to finish it. Then a Monte Carlo run asks how much each preset really brings when prices
-- and sales move: every simulation draws, for each item, a selling price, a reagent cost and how
-- many sell, from how much its price has moved over the last 30 days (your AH scans). The same
-- draws go to every preset, so "wins" is a fair head to head: in what share of the simulations
-- that preset made the most gold a day.
--
-- Saved per character and profession in AuctionIQDB.presets (a few KB each), worked out again
-- when they're a day old and the profession is open, or on Recalculate.
local _, CH = ...

local Pr = { MAX = 8, RUNS = 200, STALE = 86400, MAX_POINTS = 150,
	PRICE_CV = 0.15, COST_CV = 0.08, SALES_CV = 0.3, MIN_CV = 0.05, MAX_CV = 0.6 }
CH.Presets = Pr

local function key(prof) return (CH.CharacterKey and CH.CharacterKey() or "?") .. ":" .. tostring(prof) end

--- This character's presets for a profession: { at, list = { preset } }.
function Pr.Store(prof)
	CH.db.presets = CH.db.presets or {}
	local k = key(prof)
	CH.db.presets[k] = CH.db.presets[k] or { list = {} }
	return CH.db.presets[k]
end

--- The focuses a profession's presets cover: each main group, and the branches that split one
--- (Light and Void potions), up to MAX. { { key, label, recipes, yield } }
function Pr.Focuses(prof)
	local out = {}
	local groups = CH.Paths.GoalGroups(prof) or {}
	for _, g in ipairs(groups) do
		if g.yield then
			table.insert(out, { key = g.name, label = g.name, yield = true })
		elseif g.name ~= "Other" and #g.recipes >= 1 then
			table.insert(out, { key = g.name, label = g.name, recipes = g.recipes })
		end
	end
	-- then the branches, the bigger ones first, while there's room
	local subs = {}
	for _, g in ipairs(groups) do
		if not g.yield and g.name ~= "Other" then
			for i, s in ipairs(g.subs or {}) do
				if i <= 2 and #s.recipes >= 2 then
					table.insert(subs, { key = g.name .. " - " .. s.name, label = s.name, group = g.name, recipes = s.recipes })
				end
			end
		end
	end
	table.sort(subs, function(a, b) return #a.recipes > #b.recipes end)
	for _, s in ipairs(subs) do
		if #out >= Pr.MAX then break end
		table.insert(out, s)
	end
	while #out > Pr.MAX do table.remove(out) end
	return out
end

-- Random numbers that are the same for the same simulation and item, so every preset is tested
-- against the same market.
local function uniform(a, b)
	local x = (a * 104729 + b * 7919 + 12345) % 2147483646 + 1
	x = (x * 16807) % 2147483647
	local u1 = x / 2147483647
	x = (x * 16807) % 2147483647
	return u1, x / 2147483647
end

local function normal(run, id, salt)
	local u1, u2 = uniform(run, (id or 0) * 7 + salt)
	return math.sqrt(-2 * math.log(math.max(u1, 1e-12))) * math.cos(2 * math.pi * u2)
end

-- a multiplier around 1 with this spread (lognormal, mean 1)
local function draw(run, id, salt, cv)
	local sigma = math.sqrt(math.log(1 + cv * cv))
	return math.exp(sigma * normal(run, id, salt) - sigma * sigma / 2)
end
Pr.Draw = draw

--- How much an item's price moves day to day: the spread of its daily market prices over the last
--- 30 days, as a share of their average. A starting guess when there are fewer than 5 days.
function Pr.Spread(id)
	local e = id and CH.db.scans and CH.db.scans[id]
	local d = e and e.daily
	if not d or #d < 5 then return Pr.PRICE_CV end
	local sum, n = 0, 0
	for _, x in ipairs(d) do sum, n = sum + x[2], n + 1 end
	local mean = sum / n
	if mean <= 0 then return Pr.PRICE_CV end
	local v = 0
	for _, x in ipairs(d) do v = v + (x[2] - mean) ^ 2 end
	return math.max(Pr.MIN_CV, math.min(Pr.MAX_CV, math.sqrt(v / (n - 1)) / mean))
end

--- A preset's gold a day in one simulation.
function Pr.Day(p, run)
	local total = p.conc or 0
	for _, r in ipairs(p.per or {}) do
		local price = draw(run, r.item, 1, r.cv or Pr.PRICE_CV)
		local sells = draw(run, r.item, 3, Pr.SALES_CV)
		if r.cost then
			local cost = draw(run, r.item, 2, Pr.COST_CV)
			local each = (r.profit + r.cost) * price - r.cost * cost
			-- you'd stop crafting it at a loss
			if each > 0 then total = total + each * (r.crafts or 0) * sells end
		else
			total = total + (r.perDay or 0) * price * sells
		end
	end
	if p.conc and p.conc > 0 then
		-- Concentration is spent on the same items: it moves with their average price
		local m, n = 0, 0
		for _, r in ipairs(p.per or {}) do m, n = m + draw(run, r.item, 1, r.cv or Pr.PRICE_CV), n + 1 end
		total = total - p.conc + p.conc * (n > 0 and m / n or 1)
	end
	return total
end

--- Run the simulations over a profession's presets: each gets mean, p10 and p90 gold a day and
--- wins (its share of the runs where it made the most). With onDone it runs SLICE simulations a
--- frame and calls onDone(list) at the end; without it, all at once.
Pr.SLICE = 25
function Pr.Rank(list, runs, onDone)
	runs = runs or Pr.RUNS
	local samples, wins = {}, {}
	for i in ipairs(list) do samples[i], wins[i] = {}, 0 end
	local function sims(from, to)
		for run = from, to do
			local best, bestV
			for i, p in ipairs(list) do
				local v = Pr.Day(p, run)
				samples[i][run] = v
				if not bestV or v > bestV then best, bestV = i, v end
			end
			if best then wins[best] = wins[best] + 1 end
		end
	end
	local function sum()
		for i, p in ipairs(list) do
			local s = samples[i]
			table.sort(s)
			local total = 0
			for _, v in ipairs(s) do total = total + v end
			p.mean = #s > 0 and total / #s or 0
			p.p10 = s[math.max(1, math.floor(#s * 0.1))] or 0
			p.p90 = s[math.max(1, math.ceil(#s * 0.9))] or 0
			p.wins = runs > 0 and wins[i] / runs or 0
		end
		return list
	end
	if not onDone then sims(1, runs); return sum() end
	local at = 1
	local function step()
		local to = math.min(runs, at + Pr.SLICE - 1)
		sims(at, to)
		at = to + 1
		if at > runs then onDone(sum()) else C_Timer.After(0, step) end
	end
	step()
	return list
end

--- A finished plan, small enough to save.
function Pr.FromPlan(focus, plan)
	local p = { key = focus.key, label = focus.label, group = focus.group, yield = focus.yield, at = time(),
		points = plan.budget or 0, unspent = plan.unspent or 0, start = plan.start or 0, final = plan.final or 0,
		conc = math.max(0, (plan.final or 0) - (plan.finalPlain or plan.final or 0)), steps = {}, per = {} }
	for _, s in ipairs(plan.steps or {}) do
		table.insert(p.steps, { node = s.node, name = s.name, from = s.from, to = s.to, cost = s.cost, gain = s.gain })
	end
	for id, r in pairs(plan.finalPer or {}) do
		if (r.perDay or 0) > 0 or (r.profit or 0) > 0 then
			table.insert(p.per, { id = id, item = r.item, profit = r.profit or 0, cost = r.cost, crafts = r.crafts,
				perDay = r.perDay, cv = Pr.Spread(r.item) })
		end
	end
	table.sort(p.per, function(a, b) return (a.perDay or 0) > (b.perDay or 0) end)
	return p
end

--- A saved preset as a plan the tree and Paths can show (no planner run needed).
function Pr.AsPlan(prof, p)
	local plan = { prof = prof, label = p.label, goal = p.key, budget = p.points, unspent = p.unspent, start = p.start, final = p.final,
		steps = {}, recipes = {}, preset = p }
	for _, s in ipairs(p.steps) do
		table.insert(plan.steps, { node = s.node, name = s.name, from = s.from, to = s.to, cost = s.cost, gain = s.gain or 0, perks = {}, changes = {} })
	end
	-- the ranks once it's done, for the advisor's simulation
	local tree = CH.Spec.Tree(prof)
	if tree then
		plan.ranks = CH.Spec.Ranks(tree)
		for _, s in ipairs(p.steps) do
			if plan.ranks[s.node] ~= nil and s.to > plan.ranks[s.node] then plan.ranks[s.node] = s.to end
		end
	end
	return plan
end

--- Points a focus takes to finish from the build now, capped.
local function pointsFor(prof, focus)
	local tree = CH.Spec.Tree(prof)
	local need = CH.Paths.PathCost(prof, focus.recipes, focus.yield and "disenchant" or nil)
	need = math.min(Pr.MAX_POINTS, need)
	return math.max(0, need - (tree and tree.unspent or 0))
end

local running

--- Whether presets are being worked out now.
function Pr.Running() return running ~= nil end

--- How far a run has got: { at, of, label }.
function Pr.Progress() return running or {} end

--- Work out every preset for the open profession, one after another in the background, then rank
--- them. onDone(store) when finished; sync runs it all at once (tests).
function Pr.Build(prof, onDone, sync)
	prof = prof or CH.OpenProfessionID()
	if not prof or prof ~= CH.OpenProfessionID() then return nil, "Open the profession to work out its presets." end
	if running then return nil, "Already working them out." end
	local focuses = Pr.Focuses(prof)
	if #focuses == 0 then return nil, "No recipes to build presets for yet." end
	local done = {}
	-- one set of advisor answers for every focus: they share recipes (Potions and Light potions)
	-- and the same tree, so a recipe at the same stats is worked out once for the whole run
	local memo = {}
	running = { prof = prof, at = 0, of = #focuses }
	local function finish()
		local function saved(list)
			local store = Pr.Store(prof)
			store.list, store.at = list, time()
			running = nil
			if Pr.Changed then Pr.Changed(prof) end
			if onDone then onDone(store) end
		end
		running.label = "simulations"
		if sync then saved(Pr.Rank(done)) else Pr.Rank(done, nil, saved) end
	end
	local i = 0
	local function nextOne()
		i = i + 1
		local f = focuses[i]
		if not f then return finish() end
		running.at, running.label = i, f.label
		if Pr.Changed then Pr.Changed(prof) end
		local function got(plan)
			if plan and plan.final and not plan.error then table.insert(done, Pr.FromPlan(f, plan)) end
			if not sync then return nextOne() end
		end
		local opts = { prof = prof, recipes = f.recipes, label = f.label, goal = f.yield and "disenchant" or f.label,
			points = pointsFor(prof, f), sync = sync, memo = memo, onDone = (not sync) and got or nil }
		local plan, why = CH.Paths.Plan(opts)
		if sync or not plan then got(plan) end
		if sync then return nextOne() end
	end
	nextOne()
	return true
end

--- This character's presets for a profession, best gold a day first, and whether they're old.
function Pr.List(prof)
	local store = prof and CH.db and CH.db.presets and CH.db.presets[key(prof)]
	if not store or not store.list then return {}, true end
	local list = {}
	for _, p in ipairs(store.list) do table.insert(list, p) end
	table.sort(list, function(a, b) return (a.mean or a.final or 0) > (b.mean or b.final or 0) end)
	return list, not store.at or time() - store.at > Pr.STALE
end

--- One preset by its key.
function Pr.Get(prof, k)
	for _, p in ipairs((Pr.List(prof))) do if p.key == k then return p end end
end

--- Work them out when the profession opens and they're a day old (or missing).
function Pr.Auto(prof)
	prof = prof or CH.OpenProfessionID()
	if not prof or running then return end
	local _, stale = Pr.List(prof)
	if stale then Pr.Build(prof) end
end
