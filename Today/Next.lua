-- Do next: the Today tab's ranked list of what to do now, from the same sources as the Report.
-- Things that waste value while they wait (full Concentration, ready cooldowns, a selling window
-- about to open, gold sitting in the mail) come first; then stock work, biggest gold first.
local _, CH = ...

local Next = {}
CH.Next = Next

local function name(id) return CH.LedgerUI and select(2, CH.LedgerUI.ItemText(id)) or ("item " .. tostring(id)) end

--- { { title, detail, gold, tier, go = { tab, view } } }, best first.
function Next.List(now)
	now = now or time()
	local out = {}
	local function add(e) table.insert(out, e) end

	-- 1. value that leaks while it waits
	for _, c in pairs(CH.db.characters or {}) do
		for _, p in pairs(c.professions or {}) do
			local cur, max = CH.ConcentrationNow and CH.ConcentrationNow(p, now)
			if cur and max and max > 0 and cur >= max then
				local best
				for _, r in ipairs(p.scan and p.scan.rows or p.crafts or {}) do
					if r.profit and r.profit > 0 and (not best or r.profit > best.profit) then best = r end
				end
				add({ title = "Spend Concentration", detail = (c.name or "?") .. "'s " .. (p.name or "?") .. " is full"
					.. (best and (": " .. (best.name or "?")) or ""), gold = best and best.profit, tier = 1, go = { "crafting" } })
			end
		end
	end
	for _, cd in ipairs(CH.Cooldowns and CH.Cooldowns.All(now) or {}) do
		if cd.ready then add({ title = "Cooldown ready", detail = (cd.char or "?") .. ": " .. (cd.name or "?"), tier = 1, go = { "crafting" } }) end
	end
	local mail = CH.Mail and CH.Mail.WaitingAll() or 0
	if mail > 0 then add({ title = "Collect mail", detail = "gold waiting in the mailbox", gold = mail, tier = 1 }) end

	if CH.Ledger and CH.Ledger.Available() then
		local hour = tonumber(date("%H", now))
		for _, e in ipairs(CH.Ledger.SaleTimes(now - 30 * 86400)) do
			local ahead = (e.bestHour - hour) % 24
			if e.sold >= 3 and e.share >= 0.4 and ahead <= 3 then
				add({ title = "Post now", detail = string.format("%s: %d%% of sales from %02d:00", name(e.id), math.floor(e.share * 100 + 0.5), e.bestHour),
					gold = e.gold, tier = 1, go = { "markets", "when" } })
			end
		end

		-- 2. stock work, by gold
		local ok, r = pcall(CH.Ledger.Report, now)
		if ok and r then
			for _, e in ipairs(r.restock or {}) do
				add({ title = "Restock", detail = string.format("%s: %d sold this week, none left", name(e.id), e.sold), gold = e.gold, tier = 2, go = { "crafting" } })
			end
			for _, e in ipairs(r.expired or {}) do
				local unit = CH.Prices.Get("chvalue", "i:" .. e.id)
				add({ title = "Repost", detail = string.format("%s x%d came back unsold", name(e.id), e.n), gold = unit and unit * e.n, tier = 2,
					go = { "ledger", "expired" } })
			end
			for _, e in ipairs(r.stale or {}) do
				add({ title = "Rethink", detail = string.format("%s: %d expiries in 2 weeks, cut the price or stop", name(e.id), e.times), tier = 3,
					go = { "analytics", "dead" } })
			end
		end
		for _, e in ipairs(CH.Par and CH.Par.List(now) or {}) do
			if e.short > 0 then
				add({ title = "Below stock target", detail = string.format("%s: %d of %d, make or buy %d", name(e.id), e.held, e.target, e.short),
					gold = e.value, tier = 2, go = { "analytics", "par" } })
			end
		end
	end

	-- 3. the week's chores
	if CH.Planner then
		local left = 0
		for _, k in ipairs(CH.Planner.Knowledge(now)) do for _, t in ipairs(k.tasks) do if not t.done then left = left + 1 end end end
		if left > 0 then add({ title = "Weekly knowledge", detail = left .. " sources not ticked yet", tier = 3, go = { "crafting" } }) end
	end

	table.sort(out, function(a, b)
		if a.tier ~= b.tier then return a.tier < b.tier end
		if (a.gold or 0) ~= (b.gold or 0) then return (a.gold or 0) > (b.gold or 0) end
		return a.detail < b.detail
	end)
	return out
end
