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

--- { { title, detail, gold, tier, go = { tab, view }, act = { label, run } } }, best first.
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
					gold = conc and conc.concProfit * n or (best and best.profit), tier = 1, go = { "operations", "professions" },
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
			table.concat(names, ", "), #below > 2 and ", ..." or ""), tier = 2, go = { "operations", "scenarios" }, rows = below })
	end
	for _, cd in ipairs(CH.Cooldowns and CH.Cooldowns.All(now) or {}) do
		if cd.ready then add({ title = "Cooldown ready", detail = (cd.char or "?") .. ": " .. (cd.name or "?"), tier = 1, go = { "operations", "professions" } }) end
	end
	local mail = CH.Mail and CH.Mail.WaitingAll() or 0
	if mail > 0 then add({ title = "Collect mail", detail = "gold waiting in the mailbox", gold = mail, tier = 1 }) end

	if CH.Ledger and CH.Ledger.Available() then
		local hour = tonumber(date("%H", now))
		for _, e in ipairs(CH.Ledger.SaleTimes(now - 30 * 86400)) do
			local ahead = (e.bestHour - hour) % 24
			if e.sold >= 3 and e.share >= 0.4 and ahead <= 3 then
				add({ title = "Post now", detail = string.format("%s: %d%% of sales from %02d:00", name(e.id), math.floor(e.share * 100 + 0.5), e.bestHour),
					gold = e.gold, tier = 1, go = { "operations", "when" }, act = postAct("Post") })
			end
		end

		-- 2. stock work, by gold
		local ok, r = pcall(CH.Ledger.Report, now)
		if ok and r then
			for _, e in ipairs(r.restock or {}) do
				add({ title = "Restock", detail = string.format("%s: %d sold this week, none left", name(e.id), e.sold), gold = e.gold, tier = 2, go = { "operations", "queue" },
					act = makeAct(e.id, e.sold) })
			end
			for _, e in ipairs(r.expired or {}) do
				local unit = CH.Prices.Get("chvalue", "i:" .. e.id)
				add({ title = "Repost", detail = string.format("%s x%d came back unsold", name(e.id), e.n), gold = unit and unit * CH.AH_CUT * e.n, tier = 2,
					go = { "ledger", "expired" }, act = postAct("Repost") })
			end
			for _, e in ipairs(r.stale or {}) do
				add({ title = "Rethink", detail = string.format("%s: %d expiries in 2 weeks, cut the price or stop", name(e.id), e.times), tier = 3,
					go = { "operations", "dead" } })
			end
		end
		for _, e in ipairs(CH.Par and CH.Par.List(now) or {}) do
			if e.short > 0 then
				add({ title = "Below stock target", detail = string.format("%s: %d of %d, make or buy %d", name(e.id), e.held, e.target, e.short),
					gold = e.value, tier = 2, go = { "operations", "par" }, act = makeAct(e.id, e.short) })
			end
		end
	end

	-- 3. the week's chores
	if CH.Planner then
		local left = 0
		for _, k in ipairs(CH.Planner.Knowledge(now)) do for _, t in ipairs(k.tasks) do if not t.done then left = left + 1 end end end
		if left > 0 then add({ title = "Weekly knowledge", detail = left .. " sources not ticked yet", tier = 3, go = { "operations", "professions" } }) end
	end

	table.sort(out, function(a, b)
		if a.tier ~= b.tier then return a.tier < b.tier end
		if (a.gold or 0) ~= (b.gold or 0) then return (a.gold or 0) > (b.gold or 0) end
		return a.detail < b.detail
	end)
	return out
end
