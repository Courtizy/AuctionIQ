-- Do next: the Today tab's ranked list of what to do now, from the same sources as the Report.
-- Things that waste value while they wait (full Concentration, ready cooldowns, a selling window
-- about to open, gold sitting in the mail) come first; then stock work, biggest gold first.
local _, CH = ...

local Next = {}
CH.Next = Next

local function name(id) return CH.LedgerUI and select(2, CH.LedgerUI.ItemText(id)) or ("item " .. tostring(id)) end

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
				add({ title = "Spend Concentration", detail = (c.name or "?") .. "'s " .. (p.name or "?") .. " is full"
					.. (pick and (": " .. (pick.name or "?") .. (conc and (" x" .. n) or "")) or "")
					.. (conc and gpp and string.format(", +%s a point over plain", CH.FormatMoney(gpp)) or ""),
					gold = conc and conc.concProfit * n or (best and best.profit), tier = 1,
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
	local mail = CH.Mail and CH.Mail.WaitingAll() or 0
	if mail > 0 then add({ title = "Collect mail", detail = "gold waiting in the mailbox", gold = mail, tier = 1 }) end

	if CH.Ledger and CH.Ledger.Available() then
		local hour = tonumber(date("%H", now))
		for _, e in ipairs(CH.Ledger.SaleTimes(now - 30 * 86400)) do
			local ahead = (e.bestHour - hour) % 24
			if e.sold >= 3 and e.share >= 0.4 and ahead <= 3 then
				add({ title = "Post now", detail = string.format("%s: %d%% of sales from %02d:00", name(e.id), math.floor(e.share * 100 + 0.5), e.bestHour),
					gold = e.gold, tier = 1, act = postAct("Post"),
					risk = string.format("the selling hour comes from your last %d sales of it", e.sold),
					go = { "operations", "post", { name = name(e.id), id = e.id, title = "Post now" } } })
			end
		end

		-- 2. stock work, by gold
		local ok, r = pcall(CH.Ledger.Report, now)
		if ok and r then
			for _, e in ipairs(r.restock or {}) do
				add({ title = "Restock", detail = string.format("%s: %d sold this week, none left", name(e.id), e.sold), gold = e.gold, tier = 2,
					risk = "whether this week's demand repeats", act = makeAct(e.id, e.sold),
					go = { "operations", "scenarios", { name = name(e.id), id = e.id, qty = e.sold, unit = "items", title = "Restock" } } })
			end
			for _, e in ipairs(r.expired or {}) do
				local unit = CH.Prices.Get("chvalue", "i:" .. e.id)
				add({ title = "Repost", detail = string.format("%s x%d came back unsold", name(e.id), e.n), gold = unit and unit * CH.AH_CUT * e.n, tier = 2,
					risk = "it already expired once at this price", act = postAct("Repost"),
					go = { "operations", "post", { name = name(e.id), id = e.id, qty = e.n, title = "Repost" } } })
			end
			for _, e in ipairs(r.stale or {}) do
				add({ title = "Rethink", detail = string.format("%s: %d expiries in 2 weeks, cut the price or stop", name(e.id), e.times), tier = 3,
					risk = "a cut may not sell it either: check who's undercutting",
					go = { "operations", "dead", { name = name(e.id), id = e.id, title = "Rethink" } } })
			end
		end
		for _, e in ipairs(CH.Par and CH.Par.List(now) or {}) do
			if e.short > 0 then
				add({ title = "Below stock target", detail = string.format("%s: %d of %d, make or buy %d", name(e.id), e.held, e.target, e.short),
					gold = e.value, tier = 2, act = makeAct(e.id, e.short), risk = "the stock target itself: it follows last weeks' sales",
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

	table.sort(out, function(a, b)
		if a.tier ~= b.tier then return a.tier < b.tier end
		if (a.gold or 0) ~= (b.gold or 0) then return (a.gold or 0) > (b.gold or 0) end
		return a.detail < b.detail
	end)
	return out
end

--- Do next as decisions, not a list: the same action on several items (Repost, Restock, Post now...)
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
			local gold, names, ids = 0, {}, {}
			for i, e in ipairs(g) do
				gold = gold + (e.gold or 0)
				local f = e.go and e.go[3]
				if f and f.id then ids[f.id] = true end
				local n = e.go and e.go[3] and e.go[3].name
				if n and i <= 3 then table.insert(names, n) end
			end
			local more = #g > #names and string.format(" and %d more", #g - #names) or ""
			table.insert(out, { title = string.format("%s %d items", first.title, #g),
				detail = (#names > 0 and table.concat(names, ", ") .. more or (#g .. " items")) .. ". Biggest: " .. first.detail,
				gold = gold > 0 and gold or nil, tier = first.tier, risk = first.risk, rows = g,
				-- one item's button can't do them all: the card opens its view on the whole list
				-- the exact items behind the card, so the view opens on that shortlist and nothing else
				go = first.go and { first.go[1], first.go[2], { title = first.title .. ", " .. #g .. " items", ids = next(ids) and ids or nil } } })
		end
	end
	table.sort(out, function(a, b)
		if a.tier ~= b.tier then return a.tier < b.tier end
		return (a.gold or 0) > (b.gold or 0)
	end)
	local all = #out
	for i = #out, (max or 4) + 1, -1 do out[i] = nil end
	return out, all
end
