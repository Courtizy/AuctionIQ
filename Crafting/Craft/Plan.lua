-- One craft plan, the same wherever it's made: the live advisor (the profession window open), a
-- saved scan row (any character, window closed), the Dashboard and the Craft card. The queue keeps
-- plans as its entries, the shopping list and the budget read their reagents, and the craft log and
-- forecast read their numbers, so every screen describes the same craft.
--
-- A plan:
--   char, charName, class          who crafts it
--   recipeID, name, item, quality, tiers   what it makes, and at which rank
--   reagents { itemID, slot, n }   the exact allocation per craft, finishing reagents included
--   shop { itemID, n, rank?, tiers? }   everything one craft uses, the fixed reagents and vellum too
--   given { [itemID] = n }         a work order's reagents the customer supplies (advisor plans only)
--   concentration, avgConcentration, ingenuity, refund   Concentration per craft and its expected refund
--   profit, cost, basis            the forecast per craft, and the cost basis it was priced on
--   qty                            crafts (the queue sets it)
--   source, at                     "advisor" or "scan", and when its numbers were worked out
local _, AuctionIQ = ...

local P = {}
AuctionIQ.Plan = P
P.VERSION = 1

local function basis() return AuctionIQ.Prices and AuctionIQ.Prices.CostBasis and AuctionIQ.Prices.CostBasis() or nil end

--- A plan from a live advisor row (Advisor.Analyze's result and one of its rows), for this character.
function P.FromAdvisor(result, r)
	local reagents, shop = {}, {}
	for i, slot in ipairs(result.qual) do
		for q, id in ipairs(slot.items) do
			local n = r.picks[i][q] or 0
			if n > 0 then
				table.insert(reagents, { itemID = id, slot = slot.index, n = n })
				table.insert(shop, { itemID = id, n = n, rank = q, tiers = #slot.items })
			end
		end
	end
	for _, slot in ipairs(result.fixed) do table.insert(shop, { itemID = slot.items[1], n = slot.qty }) end
	for _, f in ipairs(r.finishing or {}) do
		table.insert(reagents, { itemID = f.itemID, slot = f.slot, n = 1 })
		table.insert(shop, { itemID = f.itemID, n = 1 })
	end
	-- what the customer gives, as the advisor planned it: the craft supplies only the rest
	local given
	for _, g in ipairs(result.order and result.order.provided or {}) do
		given = given or {}
		given[g.itemID] = (given[g.itemID] or 0) + (g.quantity or 0)
	end
	local me = AuctionIQ.Me()
	return { given = given,
		char = AuctionIQ.CharacterKey(), charName = me.name, class = me.class,
		recipeID = result.recipeID, name = result.name, quality = r.quality, tiers = result.model and result.model.maxQ,
		concentration = r.concentration, avgConcentration = r.concentration and r.avgConcentration or nil,
		profit = r.profit, cost = r.cost, item = r.item, basis = basis(),
		-- Ingenuity: the chance a Concentration craft refunds, and how many points it gives back
		ingenuity = r.concentration and r.ingenuity or nil,
		refund = r.concentration and r.concentration * ((AuctionIQ.Stats.REFUND or 0.5) + (r.stats and r.stats.refundExtra or 0)) or nil,
		reagents = reagents, shop = shop, qty = 0,
		source = "advisor", at = time(),
	}
end

--- Ingenuity's chance from what a Concentration craft costs on average (the scan keeps that, not the
--- chance): avg = cost x (1 - chance x refund share).
local function ingenuityFrom(cost, avg)
	if not (cost and cost > 0 and avg) then return nil end
	return math.max(0, math.min(1, (1 - avg / cost) / (AuctionIQ.Stats.REFUND or 0.5)))
end

--- A plan from a saved scan row, for any character, without the profession window open. conc picks
--- the Concentration craft. nil when the scan predates saving reagent slots.
function P.FromScan(charKey, char, row, conc)
	-- the Concentration craft needs its own saved mix: never the plain one under its name
	local acc
	if conc then acc = row.concAccounts else acc = row.accounts end
	if not acc or not acc.queue then return nil end
	local shop = {}
	for _, s in ipairs(acc.reagents or {}) do table.insert(shop, { itemID = s.itemID, n = s.n, rank = s.rank, tiers = s.tiers }) end
	local cost = conc and row.concentration or nil
	local avg = conc and (row.avgConcentration or acc.avgConcentration) or nil
	local ing = conc and ingenuityFrom(cost, avg) or nil
	return { char = charKey, charName = char.name, class = char.class, recipeID = row.recipeID, name = row.name,
		quality = conc and row.concQuality or row.quality, tiers = row.tiers, concentration = cost,
		profit = conc and row.concProfit or row.profit, cost = acc.cost, basis = basis(), item = conc and (row.concItem or row.item) or row.item,
		avgConcentration = avg, ingenuity = ing,
		refund = cost and cost * (AuctionIQ.Stats.REFUND or 0.5) or nil,
		reagents = acc.queue, shop = shop, qty = 0,
		source = "scan", at = row.at,
	}
end

--- Whether two plans are the same craft: who, what, which rank, Concentration and the exact reagents.
function P.Same(a, b)
	if not (a and b) then return false end
	if a.char ~= b.char or a.recipeID ~= b.recipeID or a.quality ~= b.quality then return false end
	if (a.concentration == nil) ~= (b.concentration == nil) then return false end
	return AuctionIQ.Queue.MixOf(a) == AuctionIQ.Queue.MixOf(b)
end

local function ago(s)
	if s < 3600 then return string.format("%d min ago", math.floor(s / 60)) end
	if s < 86400 then return string.format("%dh ago", math.floor(s / 3600)) end
	return string.format("%d days ago", math.floor(s / 86400))
end

P.STALE = 86400 -- a plan's numbers older than a day are worth checking again before acting on

--- Where a plan's numbers come from, for a label: who, how old, which prices.
--- Returns the text and whether it's stale.
function P.Provenance(e, now)
	if not e then return nil end
	local parts = {}
	parts[#parts + 1] = e.charName or (e.char and e.char:match("^[^-]+")) or "?"
	local age = e.at and (now or time()) - e.at
	if e.source == "scan" then parts[#parts + 1] = age and ("scanned " .. ago(age)) or "scanned (age unknown)"
	elseif e.source == "advisor" then parts[#parts + 1] = age and ("worked out " .. ago(age)) or "worked out live"
	else parts[#parts + 1] = "age unknown" end
	local b = e.basis and AuctionIQ.Prices and AuctionIQ.Prices.BASIS_NAMES and AuctionIQ.Prices.BASIS_NAMES[e.basis]
	if b then parts[#parts + 1] = b end
	return table.concat(parts, ", "), age == nil or age > P.STALE
end

-- The batch decision for a planned craft ------------------------------------------------------
-- One summary the Crafting tab shows for a saved scan row, whatever the view: how many, the cash
-- it needs now, break-even, the expected net and stock left after the horizon, what Concentration
-- adds per point over a plain craft you could actually make, and the choices worth comparing
-- (craft, sell the reagents, wait), with where the numbers come from.

--- row: a saved scan row (as the Crafting list shows it, with canMake/canMakeConc when known).
--- conc: the Concentration craft. n: crafts (nil: the suggestion, else 1). opts: gold (copper you
--- have; nil leaves affordability out), held (items of the product you hold), now.
--- Returns nil when the scan row lacks the numbers, else { n, suggested, action, text, binding,
--- cashNow, material, breakEven, net, netSlow, stockLeft, items, horizon, gain = { perPoint, gain,
--- versus = "plain" | "nothing" } (Concentration crafts), choices = { { key, label, gold, note } },
--- source (label), stale }.
function P.Batch(row, conc, n, opts)
	opts = opts or {}
	local D = AuctionIQ.Decide
	local inp = D and D.ScanInputs(row, conc)
	if not inp then return nil end
	local q = D.Quantity(inp, { gold = opts.gold, held = opts.held, noExplore = true,
		canMake = conc and row.canMakeConc or row.canMake })
	local size = n or (q.n and q.n > 0 and q.n) or 1
	local material, cash = D.BatchCost(inp, size)
	local sc = D.Scenarios(inp, size, { held = q.held })
	local out = { n = size, suggested = q.suggested, action = q.action, text = q.text, binding = q.binding,
		cashNow = cash, material = material, breakEven = conc and row.concBreakEven or row.breakEven,
		net = sc.expected.net, netSlow = sc.slow.net, stockLeft = sc.expected.left, items = sc.expected.items,
		horizon = D.HORIZON }
	if conc and row.concProfit then
		-- against the plain craft only when you could make it now: else against not crafting
		local plainOk = row.profit and row.profit > 0 and (row.canMake == nil or row.canMake >= 1)
		local g = D.ConcGain({ profit = row.concProfit, avgConcentration = row.avgConcentration, concentration = row.concentration },
			plainOk and row.profit or 0)
		if g then out.gain = { perPoint = g.perPoint, gain = g.gain, versus = plainOk and "plain" or "nothing" } end
	end
	-- the choices worth comparing, for this batch
	local choices = { { key = "craft", label = string.format("Craft %d", size), gold = out.net,
		note = string.format("expected net over %d days, %s if it sells slowly", out.horizon, AuctionIQ.FormatMoney and AuctionIQ.FormatMoney(out.netSlow) or tostring(out.netSlow)) } }
	local acc = conc and row.concAccounts or row.accounts
	local cs = acc and AuctionIQ.CraftOrSell and AuctionIQ.CraftOrSell(acc)
	if cs and cs.sell and cs.sell > 0 then
		choices[#choices + 1] = { key = "sell", label = "Sell the reagents you hold", gold = cs.sell, note = "gold now, after the cut, instead of crafting with them" }
	end
	local label, stale = P.Provenance(P.FromScan(opts.charKey or (AuctionIQ.CharacterKey and AuctionIQ.CharacterKey()), opts.char or (AuctionIQ.Me and AuctionIQ.Me()) or {}, row, conc)
		or { source = "scan", at = row.at, charName = opts.char and opts.char.name, basis = AuctionIQ.Prices and AuctionIQ.Prices.CostBasis and AuctionIQ.Prices.CostBasis() }, opts.now)
	out.source, out.stale = label, stale
	if q.action == "hold" or stale then
		choices[#choices + 1] = { key = "wait", label = stale and "Rescan, then decide" or "Wait",
			note = stale and "these numbers are over a day old" or q.text }
	end
	out.choices = choices
	return out
end
