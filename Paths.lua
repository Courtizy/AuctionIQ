-- Knowledge point planner. You say what you want to sell ("potions", "flasks", "gems") and it works
-- out which specialization nodes to put points into, in order, for the most gold a day on your
-- market:
--   * the goal picks the recipes (by name and recipe category)
--   * each recipe's gold a day = average profit per craft x how many the region sells (up to your
--     cap), plus what Concentration earns per point x the points you regain a day
--   * every node you could put points into next is tried in steps (to its next perk or 5 points),
--     with the crafting advisor re-run on the simulated stats; the best gold per point wins, repeat
--     until the points run out
-- A node under another is only planned once the one above it is full (the planner's assumption;
-- the game's own "available" flag is used for nodes it already reports).
local _, CH = ...

local P = {}
CH.Paths = P
local unpack = unpack or table.unpack

local STEP = 5
local MAX_RECIPES = 20
local SYNONYMS = { pots = "potion", pot = "potion", gems = "gem", inks = "ink", enchants = "enchant", oils = "oil",
	phials = "phial", flasks = "flask", rings = "ring", necks = "neck", necklaces = "neck", glyphs = "glyph",
	elixirs = "elixir", cauldrons = "cauldron", runes = "rune", contracts = "contract", treatises = "treatise",
	transmutes = "transmute", transmutation = "transmute", wands = "wand", rods = "rod", vantus = "vantus" }
local EVERYTHING = { money = true, gold = true, profit = true, everything = true, anything = true, all = true, best = true }

local function words(text)
	local out = {}
	for word in string.gmatch(string.lower(text or ""), "[%a']+") do
		local w = SYNONYMS[word] or word
		if #w > 3 and w:sub(-3) == "ies" then w = w:sub(1, -4) .. "y"
		elseif #w > 3 and w:sub(-1) == "s" and w:sub(-2) ~= "ss" then w = w:sub(1, -2) end
		out[#out + 1] = w
	end
	return out
end
P.Words = words

local STOP = { i = true, want = true, to = true, sell = true, make = true, craft = true, the = true, ["and"] = true,
	a = true, of = true, some = true, more = true, my = true, on = true, ["for"] = true, with = true, like = true, ["i'd"] = true,
	focus = true, mostly = true, into = true, get = true, go = true, be = true, just = true }

local function categoryNames(catID)
	local names, ui = {}, C_TradeSkillUI
	local guard = 0
	while catID and catID ~= 0 and ui.GetCategoryInfo and guard < 6 do
		local c = ui.GetCategoryInfo(catID)
		if not c then break end
		table.insert(names, c.name or "")
		catID = c.parentCategoryID
		guard = guard + 1
	end
	return names
end

--- Recipe categories in the open profession, as goals to pick from: { name, recipes = {id...} }.
function P.Goals()
	local byName, out = {}, {}
	for _, id in ipairs(CH.Scan.Recipes()) do
		local info = C_TradeSkillUI.GetRecipeInfo(id)
		local names = categoryNames(info and info.categoryID)
		local name = names[1]
		if name and name ~= "" then
			if not byName[name] then byName[name] = { name = name, recipes = {} }; table.insert(out, byName[name]) end
			table.insert(byName[name].recipes, id)
		end
	end
	table.sort(out, function(a, b) return #a.recipes > #b.recipes end)
	return out
end

-- Main groups for the picker, matched against a recipe's categories, then its name.
local MAIN = {
	{ "Potions", { "potion", "tonic", "draught", "serum", "tincture" } },
	{ "Flasks & Phials", { "flask", "phial" } },
	{ "Elixirs", { "elixir" } },
	{ "Transmutations", { "transmut" } },
	{ "Oils", { "oil" } },
	{ "House Decor", { "decor", "house", "furnish", "housing" } },
}

local function mainGroup(text)
	return P.MainGroup(text)
end

--- The picker's main group for a category or recipe name ("Potions", "Flasks & Phials"...), or nil.
function P.MainGroup(text)
	text = string.lower(text or "")
	for _, g in ipairs(MAIN) do
		for _, k in ipairs(g[2]) do if text:find(k, 1, true) then return g[1] end end
	end
end

--- The open profession's recipes in main groups, each with the spec nodes that split it (Light
--- and Void potions, say): { { name, recipes, subs = { { name, node, recipes } } } }.
function P.GoalGroups(prof)
	prof = prof or CH.OpenProfessionID()
	local byName, out = {}, {}
	for _, id in ipairs(CH.Scan.Recipes()) do
		local info = C_TradeSkillUI.GetRecipeInfo(id)
		local cats = table.concat(categoryNames(info and info.categoryID), " ")
		local name = mainGroup(cats) or mainGroup(info and info.name) or "Other"
		if not byName[name] then byName[name] = { name = name, recipes = {}, subs = {} }; table.insert(out, byName[name]) end
		table.insert(byName[name].recipes, id)
	end
	local order = {}
	for i, g in ipairs(MAIN) do order[g[1]] = i end
	order.Other = #MAIN + 1
	table.sort(out, function(a, b) return order[a.name] < order[b.name] end)
	local tree = prof and CH.Spec.Tree(prof)
	if tree then
		for _, g in ipairs(out) do
			local set = {}
			for _, id in ipairs(g.recipes) do set[id] = true end
			for nodeID, n in pairs(tree.nodes) do
				local ids = {}
				for recipeID in pairs(CH.Spec.NodeRecipes(prof, nodeID)) do if set[recipeID] then table.insert(ids, recipeID) end end
				-- a node that covers some of the group but not all of it splits the group
				if #ids > 0 and #ids < #g.recipes then
					local label = (n.name or ""):match(" %- (.+)$") or n.name or ("node " .. nodeID)
					table.sort(ids)
					table.insert(g.subs, { name = label, node = nodeID, recipes = ids })
				end
			end
			table.sort(g.subs, function(a, b) if #a.recipes ~= #b.recipes then return #a.recipes > #b.recipes end return a.name < b.name end)
			for i = #g.subs, 9, -1 do g.subs[i] = nil end
		end
	end
	return out
end

--- Points to finish every node that helps these recipes, including locked nodes on the way.
function P.PathCost(prof, recipes)
	local tree = prof and CH.Spec.Tree(prof)
	if not tree then return 0 end
	local want = {}
	local set = {}
	for _, id in ipairs(recipes or {}) do set[id] = true end
	for nodeID in pairs(tree.nodes) do
		for recipeID in pairs(CH.Spec.NodeRecipes(prof, nodeID)) do
			if set[recipeID] then want[nodeID] = true; break end
		end
	end
	local counted, total = {}, 0
	local function add(nodeID, guard)
		local n = tree.nodes[nodeID]
		if not n or counted[nodeID] or guard > 10 then return end
		counted[nodeID] = true
		total = total + math.max(0, n.max - (n.rank or -1))
		if (n.rank or -1) < 0 and not n.available and n.parent then add(n.parent, guard + 1) end
	end
	for nodeID in pairs(want) do add(nodeID, 0) end
	return total
end

--- Recipes a goal means. "I want to sell potions" -> every learned recipe whose name or category
--- says potion. Returns ids and a label; everything when the goal is just "gold".
function P.Match(text)
	local ws, keys = words(text), {}
	local all = false
	for _, w in ipairs(ws) do
		if EVERYTHING[w] then all = true elseif not STOP[w] then table.insert(keys, w) end
	end
	local ids = {}
	for _, id in ipairs(CH.Scan.Recipes()) do
		local info = C_TradeSkillUI.GetRecipeInfo(id)
		if all or #keys == 0 then
			table.insert(ids, id)
		else
			local hay = string.lower((info and info.name or "") .. " " .. table.concat(categoryNames(info and info.categoryID), " "))
			for _, k in ipairs(keys) do
				if hay:find(k, 1, true) then table.insert(ids, id); break end
			end
		end
	end
	local label = (#keys == 0 or all) and "everything you can craft" or table.concat(keys, ", ")
	return ids, label, keys
end

-- Gold a day for a set of recipes at these ranks.
local function value(ctx, ranks)
	local total, concBest, per = 0, 0, {}
	for _, id in ipairs(ctx.recipes) do
		local m = ctx.models[id]
		local delta = CH.Spec.Delta(ctx.prof, ctx.tree, ranks, id)
		local ok, r = pcall(CH.Advisor.Evaluate, m, { sim = delta })
		if ok and r then
			local b, c = r.best, r.bestConc
			local item = b and b.item or (c and c.item)
			local crafts = CH.Scan.DailyUnits(item) / (r.made or 1)
			local g = b and b.profit and b.profit > 0 and b.profit * crafts or 0
			total = total + g
			if c and c.perPoint and c.perPoint > concBest then concBest = c.perPoint end
			per[id] = { quality = b and b.quality, profit = b and b.profit, perPoint = c and c.perPoint, perDay = g, name = r.name }
		end
	end
	local concDay = concBest * CH.CONC_PER_HOUR * 24
	return total + concDay, per, concBest, total
end

local function relevantNodes(ctx)
	local out = {}
	local set = {}
	for _, id in ipairs(ctx.recipes) do set[id] = true end
	for nodeID in pairs(ctx.tree.nodes) do
		for recipeID in pairs(CH.Spec.NodeRecipes(ctx.prof, nodeID)) do
			if set[recipeID] then table.insert(out, nodeID); break end
		end
	end
	return out
end

local function canRaise(ctx, ranks, nodeID)
	local n = ctx.tree.nodes[nodeID]
	local r = ranks[nodeID]
	if r >= n.max then return false end
	if r >= 0 or n.available then return true end
	if not n.parent then return true end -- a tab's first node
	local parent = ctx.tree.nodes[n.parent]
	return parent and ranks[n.parent] >= parent.max
end

-- Next stop for a node: its next perk, or STEP points on, capped at max and the points left.
local function target(ctx, ranks, nodeID, left)
	local n = ctx.tree.nodes[nodeID]
	local r = ranks[nodeID]
	local to = math.min(n.max, math.max(r, 0) + STEP)
	for _, th in pairs(n.perks) do
		if th > r and th < to and th > 0 then to = th end
	end
	if r < 0 then to = math.max(0, to) end
	local costOf = function(t) return t - r end
	while costOf(to) > left and to > r + 1 do to = to - 1 end
	if costOf(to) > left then return nil end
	return to, costOf(to)
end

local function perksBetween(ctx, nodeID, from, to)
	local out = {}
	for perkID, th in pairs(ctx.tree.nodes[nodeID].perks) do
		if th > from and th <= to then
			local text = CH.Spec.PerkText(ctx.prof, perkID)
			if text ~= "" then table.insert(out, text) end
		end
	end
	return out
end

--- Builds a plan. opts: prof, goal (text) or recipes, points (extra beyond unspent), onDone(plan),
--- sync (run in one go, for tests). The work is spread over frames otherwise.
function P.Plan(opts)
	local prof = opts.prof or CH.OpenProfessionID()
	if not prof then return nil, "Open the profession you want a plan for." end
	if not CH.Spec.Data(prof) then return nil, "No specialization data for this profession yet." end
	local tree = CH.Spec.Tree(prof)
	if not tree then return nil, "Couldn't read your specialization tree. Open the profession window." end
	local ids, label = opts.recipes, opts.label
	if not ids then ids, label = P.Match(opts.goal) end
	-- the goal's recipes we can value, best first if there are many
	local ctx = { prof = prof, tree = tree, models = {}, recipes = {} }
	for _, id in ipairs(ids) do
		local m = CH.Scan.Model(prof, id)
		if m then ctx.models[id] = m; table.insert(ctx.recipes, id) end
	end
	if #ctx.recipes == 0 then return nil, "None of your recipes match \"" .. (opts.goal or "") .. "\", or none have prices." end
	if #ctx.recipes > MAX_RECIPES then
		local scan = CH.Scan.Results(prof)
		local rank = {}
		for i, r in ipairs(scan and CH.Scan.Sort({ unpack(scan.rows) }, "perDay") or {}) do rank[r.recipeID] = i end
		table.sort(ctx.recipes, function(a, b) return (rank[a] or 999) < (rank[b] or 999) end)
		for i = #ctx.recipes, MAX_RECIPES + 1, -1 do ctx.recipes[i] = nil end
	end

	local budget = (tree.unspent or 0) + (opts.points or 0)
	local ranks = CH.Spec.Ranks(tree)
	local plan = { prof = prof, goal = opts.goal, label = label, recipes = ctx.recipes, budget = budget,
		unspent = tree.unspent or 0, steps = {}, ranks = nil }

	local work = coroutine.create(function()
		local start, startPer, startConc, startPlain = value(ctx, ranks)
		plan.start, plan.startPer, plan.startConc, plan.startPlain = start, startPer, startConc, startPlain
		local nodes = relevantNodes(ctx)
		local now, nowPer = start, startPer
		local left = budget
		while left > 0 do
			local best
			for _, nodeID in ipairs(nodes) do
				if canRaise(ctx, ranks, nodeID) then
					local to, c = target(ctx, ranks, nodeID, left)
					if to then
						local from = ranks[nodeID]
						ranks[nodeID] = to
						local v, per = value(ctx, ranks)
						ranks[nodeID] = from
						local gain = (v - now) / c
						if not best or gain > best.rate then best = { node = nodeID, from = from, to = to, cost = c, rate = gain, v = v, per = per } end
						if not opts.sync then coroutine.yield() end
					end
				end
			end
			if not best or best.rate <= 0 then break end
			ranks[best.node] = best.to
			left = left - best.cost
			local changes = {}
			for id, p in pairs(best.per) do
				local o = nowPer[id]
				if o and ((p.quality or 0) ~= (o.quality or 0) or math.abs((p.profit or 0) - (o.profit or 0)) >= 1) then
					table.insert(changes, { name = p.name, fromQ = o.quality, toQ = p.quality, dProfit = (p.profit or 0) - (o.profit or 0),
						dDay = (p.perDay or 0) - (o.perDay or 0) })
				end
			end
			table.sort(changes, function(a, b) return math.abs(a.dDay) > math.abs(b.dDay) end)
			table.insert(plan.steps, { node = best.node, name = ctx.tree.nodes[best.node].name, from = best.from, to = best.to,
				cost = best.cost, gain = best.v - now, perks = perksBetween(ctx, best.node, best.from, best.to), changes = changes })
			now, nowPer = best.v, best.per
		end
		local final, finalPer, finalConc, finalPlain = value(ctx, ranks)
		plan.final, plan.finalPer, plan.finalConc, plan.finalPlain = final, finalPer, finalConc, finalPlain
		plan.ranks = ranks
		plan.left = left
		plan.text = P.Describe(plan)
	end)

	local function resume()
		local ok, err = coroutine.resume(work)
		if not ok then plan.error = err; if opts.onDone then opts.onDone(plan) end; return end
		if coroutine.status(work) == "dead" then
			if opts.onDone then opts.onDone(plan) end
		else
			C_Timer.After(0, resume)
		end
	end
	if opts.sync then
		local ok, err = coroutine.resume(work)
		if not ok then return nil, err end
		return plan
	end
	resume()
	return plan
end

local function m(c) return CH.FormatMoney(c) end

--- The plan in plain words, as lines.
function P.Describe(plan)
	local T = CH.Theme
	local L = {}
	local prof = CH.SpecData[plan.prof] and CH.SpecData[plan.prof].name or "this profession"
	table.insert(L, T.Color("accent", "Goal: ") .. "sell " .. plan.label .. T.Color("muted", string.format("  (%d recipes in %s)", #plan.recipes, prof)))
	table.insert(L, string.format("Points to spend: %d%s.", plan.budget,
		plan.budget > plan.unspent and string.format(" (%d unspent now, %d still to earn)", plan.unspent, plan.budget - plan.unspent) or " unspent"))
	table.insert(L, "Today these recipes make about " .. m(plan.start) .. " a day on your market.")
	table.insert(L, "")
	if #plan.steps == 0 then
		table.insert(L, T.Color("muted", "No node would add gold for this goal. Either it's already maxed, or the gains come from other recipes."))
	end
	for i, s in ipairs(plan.steps) do
		local from = s.from < 0 and "unlock" or tostring(s.from)
		table.insert(L, T.Color("accent", string.format("%d. %s", i, s.name)) .. string.format("  %s to %d  (%d point%s)", from, s.to, s.cost, s.cost == 1 and "" or "s")
			.. "  " .. T.Color(s.gain >= 0 and "ok" or "bad", (s.gain >= 0 and "+" or "") .. m(s.gain) .. " a day"))
		for _, p in ipairs(s.perks) do table.insert(L, "    " .. T.Color("muted", "Perk: ") .. p) end
		for j, c in ipairs(s.changes) do
			if j > 3 then break end
			local q = (c.toQ and c.fromQ and c.toQ ~= c.fromQ) and string.format(" reaches Q%d without Concentration,", c.toQ) or ""
			table.insert(L, string.format("    %s%s %s%s a craft", c.name or "?", q, c.dProfit >= 0 and "+" or "", m(c.dProfit)))
		end
	end
	table.insert(L, "")
	local gain = (plan.final or 0) - (plan.start or 0)
	table.insert(L, T.Color("accent", "After the plan: ") .. m(plan.final) .. " a day" .. T.Color(gain >= 0 and "ok" or "bad", string.format("  (%s%s)", gain >= 0 and "+" or "", m(gain))))
	if (plan.finalConc or 0) > 0 then
		table.insert(L, string.format("Concentration earns %s a point at best (now %s).", m(plan.finalConc), m(plan.startConc)))
	end
	table.insert(L, T.Color("muted", string.format("Gold a day counts up to %d sold a day per item (/aiq cap to change) and a day's Concentration on the best recipe.",
		CH.db.settings.scan.dailyCap or 10)))
	return L
end

--- Where a plan puts points: { [nodeID] = { from, to, steps = { step numbers } } }.
function P.Marks(plan)
	local out = {}
	for i, s in ipairs(plan and plan.steps or {}) do
		local m = out[s.node]
		if not m then m = { from = s.from, to = s.to, steps = {} }; out[s.node] = m end
		m.to = math.max(m.to, s.to)
		table.insert(m.steps, i)
	end
	return out
end

-- The last plan made for each profession this session, shown on the trees.
P.current = {}
function P.SetCurrent(plan)
	if plan and plan.prof then P.current[plan.prof] = plan end
	if P.Changed then P.Changed(plan and plan.prof) end
end
function P.Current(prof) return prof and P.current[prof] end
function P.ClearCurrent(prof)
	if prof then P.current[prof] = nil end
	if P.Changed then P.Changed(prof) end
end
