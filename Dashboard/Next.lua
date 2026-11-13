-- Recommendations (Next.List): the Dashboard's ranked list of what to do now, from the same sources as the Report.
-- Things that waste value while they wait (full Concentration, ready cooldowns, a selling window
-- about to open, gold sitting in the mail) come first; then stock work.
--
-- One measure of gold ranks the cards: the expected gain from acting now, over the next week,
-- after the AH cut and expected deposits (card.value, kind "gain"; card.gold is its amount).
-- Other numbers a card knows (last month's sales, what the queue's reagents cost) are evidence
-- (card.evidence), shown with the card but never ranked against a gain. Within a tier, cards with
-- a gain come first, biggest first; cards without one keep the order they were found in, so a
-- number of another kind never decides where they sit.
local _, CH = ...

local Next = {}
CH.Next = Next

local function name(id) return CH.LedgerUI and select(2, CH.LedgerUI.ItemText(id)) or ("item " .. tostring(id)) end

Next.HORIZON_DAYS = 7

--- A card's value: { kind, amount (copper), basis (where it comes from, in words) }, or nil without
--- an amount. kinds: "gain" (what acting now adds over the next week, after fees: the only kind
--- that ranks), "pastSales" (what your sales brought in), "cost" (gold it takes), "stock" (what
--- stock is worth at market).
function Next.Value(kind, amount, basis)
	if not amount then return nil end
	return { kind = kind, amount = amount, basis = basis }
end

-- What one item you hold brings when posted: its price after the cut, less expected lost deposits
-- and gold tied up while it waits (Expect.Value). nil without a price.
local function postedEach(id)
	local price = id and CH.Prices.Get("chvalue", "i:" .. id)
	if not price then return nil end
	if CH.Expect and CH.Expect.Value then
		local ok, ev = pcall(CH.Expect.Value, id, price)
		if ok and ev then return math.max(0, ev) end
	end
	return price * CH.AH_CUT
end

-- What making n of an item adds: the best saved scan's profit a craft (after the cut, deposits and
-- Resourcefulness; reagents at your cost basis) times the crafts n items take. nil without a scan.
-- A scan row's options, kept a minute per row (they read what you hold and sale values per reagent,
-- and the list asks for the same rows on every refresh).
Next.ALT_SECONDS = 60
local altCache = setmetatable({}, { __mode = "k" })
function Next.AlternativesFor(r, now)
	local D = CH.Decide
	if not (r and r.accounts and D and D.Alternatives) then return nil end
	now = now or time()
	local c = altCache[r]
	if c and now - c.at < Next.ALT_SECONDS then return c.alt end
	local alt = D.Alternatives(r.accounts, { bc = CH.Scan and CH.Scan.BuyOrCraft and CH.Scan.BuyOrCraft(r) or nil, at = r.at, item = r.item, now = now })
	altCache[r] = { at = now, alt = alt }
	return alt
end
function Next.ClearAlternatives() altCache = setmetatable({}, { __mode = "k" }) end

-- What making n of an item adds: the best saved scan's profit a craft (after the cut, deposits and
-- Resourcefulness; reagents at your cost basis) times the crafts n items take. A scan too old to act
-- on gives no gold and says so. Returns the value, a note ("" when none) and the scan row, whose
-- options (Decide.Alternatives) the cards shown add later: they read live stock and sale values per
-- reagent, too slow for every card the list considers.
local function makeGain(id, n)
	if not (CH.Queue and CH.Queue.ScanRowFor and n and n > 0) then return nil, "" end
	local _, _, r = CH.Queue.ScanRowFor(id)
	if not (r and r.profit) then return nil, "" end
	local D = CH.Decide
	if r.at and D and D.SCAN_STALE and time() - r.at > D.SCAN_STALE then
		return nil, "; refresh first: the profession scan is " .. (CH.Scans and CH.Scans.Age and CH.Scans.Age(time() - r.at) or "old") .. " old: rescan it", r
	end
	local crafts = math.max(1, math.ceil(n / (r.made or 1)))
	return Next.Value("gain", r.profit * crafts, string.format("%d crafts at the last scan's profit", crafts)), "", r
end

--- Add a shown card's options: the note naming a better option than making it, or why to refresh.
function Next.AddAlternatives(e, now)
	if not (e and e.scanRow) or e.alternatives then return e end
	local alt = Next.AlternativesFor(e.scanRow, now)
	if not alt then return e end
	e.alternatives = alt
	local note = alt.verdict == "refresh" and ("; refresh first: " .. table.concat(alt.stale, "; "))
		or alt.verdict == "sell" and "; selling your reagents earns more"
		or alt.verdict == "flip" and "; buying it out to relist pays more"
		or alt.verdict == "keep" and "; at today's prices crafting loses" or nil
	if note and not e.detail:find(note, 1, true) and not e.detail:find("refresh first", 1, true) then e.detail = e.detail .. note end
	return e
end

--- A grouped card ("Restock 9 items") checks its items' options too, the first GROUP_ALT_MAX that
--- have a scan (each reads stock and sale values per reagent), and says how many have a better option
--- than making them, or need a fresh scan, by kind. Each item card keeps its own note for the view it opens.
Next.GROUP_ALT_MAX = 10
local GROUP_NOTES = {
	{ "refresh", "%d need a fresh scan first" },
	{ "sell", "selling the reagents earns more for %d" },
	{ "flip", "buying out to relist pays more for %d" },
	{ "keep", "crafting loses at today's prices for %d" },
}
function Next.AddGroupAlternatives(e, now)
	if not (e and e.rows) or e.groupAlternatives then return e end
	local counts, checked, scanned = {}, 0, 0
	for _, row in ipairs(e.rows) do
		if row.scanRow then
			scanned = scanned + 1
			if checked < Next.GROUP_ALT_MAX then
				checked = checked + 1
				Next.AddAlternatives(row, now)
				local v = row.alternatives and row.alternatives.verdict
				if v then counts[v] = (counts[v] or 0) + 1 end
			end
		end
	end
	e.groupAlternatives = { counts = counts, checked = checked, scanned = scanned }
	local parts = {}
	for _, n in ipairs(GROUP_NOTES) do
		if counts[n[1]] then table.insert(parts, string.format(n[2], counts[n[1]])) end
	end
	if #parts > 0 then
		local of = checked < scanned and string.format("of the first %d checked", checked) or string.format("of the %d items", #e.rows)
		e.detail = e.detail .. "; " .. of .. ", " .. table.concat(parts, ", ")
	end
	return e
end

-- Card buttons: each does the job itself where it can (queue the craft, open Auctioning).
local function queueAct(label, charKey, char, row, conc, qty)
	local e = CH.Queue and CH.Queue.FromScan(charKey, char, row, conc)
	if not e then return nil end
	return { label = label, run = function()
		CH.Queue.AddEntry(e, qty)
		if CH.QueueUI and CH.QueueUI.Show then pcall(CH.QueueUI.Show) end
		return true, string.format("Queued %d x %s%s for %s", qty, row.name or "?", conc and " with Concentration" or "", char.name or charKey)
	end }
end

local function postAct(label)
	return { label = label, run = function()
		if AuctionHouseFrame and AuctionHouseFrame:IsShown() and CH.AuctionUI then
			CH.AuctionUI.Build():Show()
			CH.AuctionUI.PostScan()
			return true, "Post scan running beside the AH"
		end
		return false, "Open the Auction House first, then press this again"
	end }
end

-- Queue enough crafts to make n of an item, from the best saved scan that makes it.
local function makeAct(id, n)
	if not (CH.Queue and n and n > 0) then return nil end
	local k, c, r = CH.Queue.ScanRowFor(id)
	if not r then return nil end
	local crafts = math.max(1, math.ceil(n / (r.made or 1)))
	return queueAct("Queue " .. crafts, k, c, r, false, crafts)
end

--- { { title, detail, gold, tier, risk, go = { tab, view, focus }, act = { label, run } } }, best first.
--- detail is the reason, gold the expected benefit and risk the biggest uncertainty behind it. focus
--- hands the item, character and quantity to the view go opens ({ name, id, char, qty, title }).
--- act.run() returns ok and a line saying what happened (or why it couldn't), shown on the card.
function Next.List(now)
	now = now or time()
	local out = {}
	local function add(e) table.insert(out, e) end

	-- 1. value that leaks while it waits
	for key, c in pairs(CH.db.characters or {}) do
		for _, p in pairs(c.professions or {}) do
			-- (not "a and f()": that keeps only f's first value, and max would always be nil)
			local cur, max
			if CH.ConcentrationNow then cur, max = CH.ConcentrationNow(p, now) end
			if cur and max and max > 0 and cur >= max then
				-- the craft that turns a point into the most gold, else the best plain craft
				-- by what the points add over the plain craft, per expected point
				local best, conc, gpp
				for _, r in ipairs(p.scan and p.scan.rows or {}) do
					local g = CH.Scan and CH.Scan.GainPerPoint(r)
					if g and g > 0 and r.concProfit and (not conc or g > gpp) then conc, gpp = r, g end
				end
				if not conc then
					for _, r in ipairs(p.scan and p.scan.rows or p.crafts or {}) do
						if r.profit and r.profit > 0 and (not best or r.profit > best.profit) then best = r end
					end
				end
				local pick = conc or best
				local n = conc and conc.concentration and conc.concentration > 0 and math.max(1, math.floor(cur / conc.concentration)) or 1
				-- what the points add over making the same crafts without them (per expected point x points
				-- a craft), not the Concentration craft's whole profit: the plain craft needs no points
				local value
				if conc then
					local avg = conc.avgConcentration or conc.concentration
					local each = conc.concGain or (gpp and avg and gpp * avg)
					value = each and Next.Value("gain", each * n, string.format("%d crafts, what Concentration adds over the plain craft", n))
				elseif best then
					value = Next.Value("gain", best.profit, "one plain craft at the last scan's profit")
				end
				add({ title = "Spend Concentration", detail = (c.name or "?") .. "'s " .. (p.name or "?") .. " is full"
					.. (pick and (": " .. (pick.name or "?") .. (conc and (" x" .. n) or "")) or "")
					.. (conc and gpp and string.format(", +%s a point over plain", CH.FormatMoney(gpp)) or ""),
					value = value, tier = 1,
					risk = pick and "the top-quality price holding while you sell " .. (conc and n or 1) or "which craft pays: scan the profession first",
					go = pick and { "operations", "scenarios", { name = pick.name, id = pick.item, char = c.name, qty = conc and n or 1, unit = "crafts", conc = conc and true or nil, title = "Spend Concentration" } }
						or { "operations", "professions", { char = c.name, title = "Spend Concentration" } },
					act = conc and queueAct("Queue " .. n, key, c, conc, true, n) or nil })
			end
		end
	end
	-- crafts the scan said pay that now sell under their break-even price
	local below = {}
	for _, c in pairs(CH.db.characters or {}) do
		for _, p in pairs(c.professions or {}) do
			for _, r in ipairs(p.scan and p.scan.rows or {}) do
				local now = r.breakEven and r.item and r.profit and r.profit > 0 and CH.Prices.Get("chvalue", "i:" .. r.item)
				if now and now < r.breakEven then
					table.insert(below, { name = r.name, now = now, be = r.breakEven, char = c.name })
				end
			end
		end
	end
	if #below > 0 then
		table.sort(below, function(a, b) return a.now / a.be < b.now / b.be end)
		local names = {}
		for i, x in ipairs(below) do
			if i > 2 then break end
			names[#names + 1] = string.format("%s %s < %s", x.name or "?", CH.FormatMoney(x.now), CH.FormatMoney(x.be))
		end
		add({ title = "Below break-even", detail = string.format("%d %s now sell under break-even: %s%s", #below, #below == 1 and "craft" or "crafts",
			table.concat(names, ", "), #below > 2 and ", ..." or ""), tier = 2, rows = below,
			risk = "today's price: one low listing can drag it under for a day",
			go = { "operations", "scenarios", { name = below[1].name, char = below[1].char, title = "Below break-even" } } })
	end
	for _, cd in ipairs(CH.Cooldowns and CH.Cooldowns.All(now) or {}) do
		if cd.ready then add({ title = "Cooldown ready", detail = (cd.char or "?") .. ": " .. (cd.name or "?"), tier = 1,
			go = { "operations", "professions", { char = cd.char, title = "Cooldown ready" } } }) end
	end
	-- the queue's shopping list: what still has to be bought before queued crafts can start
	if CH.Queue and CH.Queue.ShoppingList then
		local ok, list, total = pcall(CH.Queue.ShoppingList)
		if ok and list then
			local buys, names, ids = {}, {}, {}
			for _, r in ipairs(list) do
				if (r.buy or 0) > 0 then
					buys[#buys + 1] = r
					ids[r.itemID] = true
					if #names < 3 then names[#names + 1] = string.format("%d x %s", r.buy, name(r.itemID)) end
				end
			end
			if #buys > 0 then
				-- a cost, not a gain: it goes in the text, so the card doesn't read it as expected benefit
				add({ title = "Buy reagents", detail = string.format("%d reagent%s for your queue, about %s: %s%s", #buys, #buys == 1 and "" or "s",
					CH.FormatMoney(total or 0), table.concat(names, ", "), #buys > 3 and ", ..." or ""), cost = total, tier = 2,
					evidence = Next.Value("cost", total, "the queue's shopping list at the listings you've seen"),
					risk = "listings move: the AH's Shop queue buys at what's up when you get there",
					go = { "operations", "shopping", { title = "Buy reagents", ids = ids } } })
			end
		end
	end

	if CH.Ledger and CH.Ledger.Available() then
		local hour = tonumber(date("%H", now))
		-- the Trade call for an item, so a card hands over the same quantity and reason Trade shows
		local calls
		local function postCall(id)
			if not calls then
				calls = {}
				local ok, plan = pcall(function() return CH.TradingUI and CH.TradingUI.PostPlan() or {} end)
				local ok2, adv = pcall(function() return ok and CH.TradingUI.Advice(plan, now) or {} end)
				if ok2 then calls = adv end
			end
			return calls[id]
		end
		for _, e in ipairs(CH.Ledger.SaleTimes(now - 30 * 86400)) do
			local ahead = (e.bestHour - hour) % 24
			if e.sold >= 3 and e.share >= 0.4 and ahead <= 3 then
				-- what posting brings: the quantity Trade would post, each at what a listing is worth to you
				local a = postCall(e.id)
				local each = a and (a.qty or 0) > 0 and postedEach(e.id)
				add({ title = "Post now", detail = string.format("%s: %d%% of sales from %02d:00", name(e.id), math.floor(e.share * 100 + 0.5), e.bestHour),
					value = each and Next.Value("gain", each * a.qty, string.format("%d posted, each after the cut and expected deposits", a.qty)) or nil,
					evidence = Next.Value("pastSales", e.gold, string.format("%d sold in 30 days, before the cut", e.sold)),
					tier = 1, act = postAct("Post"),
					risk = string.format("the selling hour comes from your last %d sales of it", e.sold),
					go = { "operations", "post", (function()
						local a = postCall(e.id)
						return { name = name(e.id), id = e.id, title = "Post now", qty = a and a.qty, unit = "items",
							action = a and a.action, why = a and a.reason }
					end)() } })
			end
		end

		-- 2. stock work, by gold
		local ok, r = pcall(CH.Ledger.Report, now)
		if ok and r then
			for _, e in ipairs(r.restock or {}) do
				local value, note, row = makeGain(e.id, e.sold)
				add({ title = "Restock", detail = string.format("%s: %d sold this week, none left%s", name(e.id), e.sold, (value or note ~= "") and note or "; scan to price it"),
					scanRow = row,
					value = value, evidence = Next.Value("pastSales", e.gold, string.format("%d sold this week, after the cut", e.sold)), tier = 2,
					risk = "whether this week's demand repeats", act = makeAct(e.id, e.sold),
					go = { "operations", "scenarios", { name = name(e.id), id = e.id, qty = e.sold, unit = "items", title = "Restock" } } })
			end
			for _, e in ipairs(r.expired or {}) do
				local each = postedEach(e.id)
				add({ title = "Repost", detail = string.format("%s x%d came back unsold", name(e.id), e.n),
					value = each and Next.Value("gain", each * e.n, string.format("%d reposted, each after the cut and expected deposits", e.n)) or nil, tier = 2,
					risk = "it already expired once at this price", act = postAct("Repost"),
					go = { "operations", "post", { name = name(e.id), id = e.id, qty = e.n, title = "Repost" } } })
			end
			for _, e in ipairs(r.stale or {}) do
				add({ title = "Rethink", detail = string.format("%s: %d expiries in 2 weeks, cut the price or stop", name(e.id), e.times), tier = 3,
					risk = "a cut may not sell it either: check who's undercutting",
					go = { "operations", "post", { name = name(e.id), id = e.id, title = "Rethink" } } })
			end
		end
		for _, e in ipairs(CH.Par and CH.Par.List(now) or {}) do
			if e.short > 0 then
				local value, note, row = makeGain(e.id, e.short)
				add({ title = "Below stock target", detail = string.format("%s: %d of %d, make or buy %d%s", name(e.id), e.held, e.target, e.short, (value or note ~= "") and note or "; scan to price it"),
					scanRow = row,
					value = value, evidence = Next.Value("stock", e.value, "the shortfall at market, after the cut"), tier = 2, act = makeAct(e.id, e.short), risk = "the stock target itself: it follows last weeks' sales",
					go = { "operations", "scenarios", { name = name(e.id), id = e.id, qty = e.short, unit = "items", title = "Below stock target" } } })
			end
		end
	end

	-- 3. the week's chores
	if CH.Planner then
		local left = 0
		for _, k in ipairs(CH.Planner.Knowledge(now)) do for _, t in ipairs(k.tasks) do if not t.done then left = left + 1 end end end
		if left > 0 then add({ title = "Weekly knowledge", detail = left .. " sources not ticked yet", tier = 3,
			go = { "operations", "professions", { title = "Weekly knowledge" } } }) end
	end

	return Next.Order(out)
end

--- Sort cards: tier, then the expected gain (biggest first; a positive gain ahead of no estimate,
--- and no estimate ahead of a loss), then the order they were found in. Only a "gain" value ranks; card.gold is set to its amount.
local function class(g) return g == nil and 2 or g > 0 and 1 or 3 end
function Next.Order(out)
	for i, e in ipairs(out) do
		e.found = e.found or i
		local v = e.value
		if v and v.kind ~= "gain" then e.evidence, e.value, v = e.evidence or v, nil, nil end
		e.gold = v and v.amount or nil
	end
	table.sort(out, function(a, b)
		if a.tier ~= b.tier then return a.tier < b.tier end
		-- a gain first, then no estimate, then a loss (acting loses gold at the last scan's prices)
		local ca, cb = class(a.gold), class(b.gold)
		if ca ~= cb then return ca < cb end
		if a.gold and a.gold ~= b.gold then return a.gold > b.gold end
		return a.found < b.found
	end)
	return out
end

--- Recommendations as decisions, not a list: the same action on several items (Repost, Restock, Post now...)
--- becomes one card ("Repost 9 items"), its gold the sum, opening its view on all of them. Best first,
--- `max` of them at most (4 by default). Each card keeps its reason, gold and biggest uncertainty.
function Next.Ranked(now, max)
	local groups, order = {}, {}
	for _, e in ipairs(Next.List(now)) do
		local k = e.title .. "|" .. (e.go and (e.go[1] .. ":" .. e.go[2]) or "")
		local g = groups[k]
		if not g then g = { e }; groups[k] = g; table.insert(order, k) else table.insert(g, e) end
	end
	local out = {}
	for _, k in ipairs(order) do
		local g = groups[k]
		if #g == 1 then
			table.insert(out, g[1])
		else
			local first = g[1]
			-- only gains add up: a card in the group without one leaves the total as a lower bound
			local gold, names, ids, priced = 0, {}, {}, 0
			for i, e in ipairs(g) do
				local v = e.value
				if v and v.kind == "gain" then gold, priced = gold + v.amount, priced + 1 end
				local f = e.go and e.go[3]
				if f and f.id then ids[f.id] = true end
				local n = e.go and e.go[3] and e.go[3].name
				if n and i <= 3 then table.insert(names, n) end
			end
			local more = #g > #names and string.format(" and %d more", #g - #names) or ""
			table.insert(out, { title = string.format("%s %d items", first.title, #g),
				detail = (#names > 0 and table.concat(names, ", ") .. more or (#g .. " items")) .. ". Biggest: " .. first.detail,
				value = priced > 0 and Next.Value("gain", gold, priced < #g and string.format("%d of the %d items priced", priced, #g) or (first.value and first.value.basis)) or nil,
				tier = first.tier, risk = first.risk, rows = g, found = first.found,
				-- one item's button can't do them all: the card opens its view on the whole list
				-- the exact items behind the card, so the view opens on that shortlist and nothing else
				go = first.go and { first.go[1], first.go[2], { title = first.title .. ", " .. #g .. " items", ids = next(ids) and ids or nil } } })
		end
	end
	for i, e in ipairs(out) do e.found = i end
	Next.Order(out)
	local all = #out
	for i = #out, (max or 4) + 1, -1 do out[i] = nil end
	-- the cards shown say when another option beats making the item
	for _, e in ipairs(out) do
		if e.rows then Next.AddGroupAlternatives(e, now) else Next.AddAlternatives(e, now) end
	end
	return out, all
end
