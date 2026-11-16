-- Tune TSM, the record: what was suggested, what you changed in TSM, and how the period after the
-- change compares with the period before it. Saved in AuctionIQ.db.tune:
--   log    one entry per suggestion: { n, at, group, op, kind, key, setting, lever, from, to,
--          projected = { gold, actions, text }, why, status ("suggested", "changed", "dropped"),
--          changedAt, value (what TSM has after the change), how ("seen" or "marked") }
--   snaps  [n] = { [day] = gold tied up (held + up, at sale value) } for each entry's items, one a day
--   visits [n] = { times } your AH visits where any of the entry's items was up (a posting session)
-- A change is seen when TSM's saved setting no longer matches the value suggested from; TSM writes
-- its saved data at /reload or logout, so the change counts from the first load that shows it.
-- Mark it yourself (/aiq tune changed <n>) to set the time to now.
--
-- The comparison is like for like: the same number of whole days before and after the change (the
-- days since it, up to the evidence window), over the group's items: net profit (sales after the
-- cut less buys), units sold, units expired, cancels, gold tied up (the average of the daily
-- snapshots) and posting sessions. Everything measured is labelled observed; the suggestion's own
-- estimate stays labelled projected beside it.
local _, AuctionIQ = ...

local T = AuctionIQ.Tune
local DAY = 86400
T.LOG_MAX = 200
T.MIN_COMPARE_DAYS = 7 -- fewer days after the change than this and the comparison waits
local VISIT_GAP = 30 * 60 -- AH updates closer together than this are one posting session

local function store()
	local db = AuctionIQ.db
	db.tune = db.tune or {}
	local s = db.tune
	s.log, s.snaps, s.visits = s.log or {}, s.snaps or {}, s.visits or {}
	s.next = s.next or 1
	return s
end
T.Store = store

local function setupOf(e)
	local g = AuctionIQ.TSMSetup.Group(e.group)
	local k = g and g[e.kind or "Auctioning"]
	if not (k and k.op) then return nil end
	for _, s in ipairs(k.settings) do if s.key == e.key then return s, k end end
end

-- The items an entry is about: the group's items in TSM now.
local function itemsOf(e)
	local out = {}
	for id, path in pairs(AuctionIQ.Groups.TSMGroups()) do if path == e.group then out[#out + 1] = id end end
	table.sort(out)
	return out
end
T.ItemsOf = itemsOf

--- Record a diagnosed group's suggestion (from Diagnose), once: an open entry for the same group
--- and setting is kept (and updated to the newer suggestion while it is still only suggested).
--- Returns the entry.
function T.Note(r, now)
	local s = r and r.suggest
	if not s then return nil end
	now = now or time()
	local st = store()
	local kind = s.kind or "Auctioning"
	for _, e in ipairs(st.log) do
		if e.group == r.path and e.key == s.key and e.status == "suggested" then
			e.to, e.from, e.lever, e.why, e.op = s.suggest, tostring(s.current), s.lever, s.why, r.op
			e.projected = { gold = s.gold, actions = s.actions, text = s.projected, days = r.window.days }
			return e
		end
	end
	local e = { n = st.next, at = now, group = r.path, op = r.op, kind = kind, key = s.key, setting = s.setting, lever = s.lever,
		from = tostring(s.current), to = s.suggest, why = s.why, status = "suggested",
		projected = { gold = s.gold, actions = s.actions, text = s.projected, days = r.window.days } }
	st.next = st.next + 1
	table.insert(st.log, e)
	while #st.log > T.LOG_MAX do
		local old = table.remove(st.log, 1)
		st.snaps[old.n], st.visits[old.n] = nil, nil
	end
	return e
end

function T.Entry(n)
	for _, e in ipairs(store().log) do if e.n == n then return e end end
end

--- Look at TSM for every suggested entry: one whose setting no longer reads as it did is changed,
--- from now, with the value TSM has. Returns how many it found.
function T.CheckChanges(now)
	now = now or time()
	local found = 0
	for _, e in ipairs(store().log) do
		if e.status == "suggested" then
			local s = setupOf(e)
			local raw = s and s.saved and tostring(s.raw) or nil
			if raw and raw ~= e.from then
				e.status, e.changedAt, e.value, e.how = "changed", now, raw, "seen"
				found = found + 1
			end
		end
	end
	return found
end

--- You changed it in TSM: count the change from now (or `at`). Returns the entry, or nil and why.
function T.MarkChanged(n, at)
	local e = T.Entry(n)
	if not e then return nil, "no suggestion " .. tostring(n) end
	local s = setupOf(e)
	e.status, e.changedAt, e.how = "changed", at or time(), "marked"
	e.value = s and s.saved and tostring(s.raw) or e.to
	return e
end

--- You won't make it: kept in the record as dropped. Returns the entry, or nil and why.
function T.Drop(n)
	local e = T.Entry(n)
	if not e then return nil, "no suggestion " .. tostring(n) end
	e.status = "dropped"
	return e
end

-- What one item ties up now: held across the Warband plus up on the AH, at its sale value.
local function tiedUp(ids)
	local g = 0
	for _, id in ipairs(ids) do
		local n = (AuctionIQ.Par and AuctionIQ.Par.Held(id) or 0) + (AuctionIQ.Auction and AuctionIQ.Auction.Listed(id) or 0)
		if n > 0 then
			local v = AuctionIQ.Prices and AuctionIQ.Prices.Get("aiqvalue", "i:" .. id)
			g = g + n * (v or 0)
		end
	end
	return g
end

--- Today's gold tied up for each open entry's items (one snapshot a day, the latest of the day
--- wins). Entries dropped, or compared over a full window already, aren't snapshot.
function T.Snapshot(now)
	now = now or time()
	local st = store()
	local d = math.floor(now / DAY)
	for _, e in ipairs(st.log) do
		local done = e.status == "dropped" or (e.changedAt and now - e.changedAt > (T.Get("days") + 1) * DAY)
		if not done then
			st.snaps[e.n] = st.snaps[e.n] or {}
			st.snaps[e.n][d] = tiedUp(itemsOf(e))
			-- only the days a comparison can use
			for day in pairs(st.snaps[e.n]) do if day < d - 2 * T.Get("days") - 1 then st.snaps[e.n][day] = nil end end
		end
	end
end

--- An AH visit with your auctions listed (OWNED_AUCTIONS_UPDATED): a posting session for each open
--- entry with an item up, unless one was counted in the last half hour.
function T.Visit(items, now)
	now = now or time()
	local st = store()
	for _, e in ipairs(st.log) do
		if e.status ~= "dropped" then
			local up = false
			for _, id in ipairs(itemsOf(e)) do if (items[id] or 0) > 0 then up = true; break end end
			if up then
				local v = st.visits[e.n] or {}
				st.visits[e.n] = v
				if not v[#v] or now - v[#v] >= VISIT_GAP then
					table.insert(v, now)
					while #v > 400 do table.remove(v, 1) end
				end
			end
		end
	end
end

-- The measures over [from, to) for an entry's items.
local function measure(e, ids, from, to)
	local want = {}
	for _, id in ipairs(ids) do want[id] = true end
	local by = T.Evidence({ from = from, to = to - 1 }, want)
	local m = { net = 0, sold = 0, expired = 0, cancels = 0, bought = 0 }
	for _, x in pairs(by) do
		m.net = m.net + x.net - x.paid
		m.sold, m.expired, m.cancels, m.bought = m.sold + x.sold, m.expired + x.expired, m.cancels + x.cancelRows, m.bought + x.bought
	end
	local st = store()
	local snaps, n, sum = st.snaps[e.n] or {}, 0, 0
	-- whole days: the change's own day counts after it
	for day = math.floor(from / DAY), math.floor(to / DAY) - 1 do
		if snaps[day] then n, sum = n + 1, sum + snaps[day] end
	end
	m.tied, m.tiedDays = n > 0 and sum / n or nil, n
	local visits = 0
	for _, t in ipairs(st.visits[e.n] or {}) do if t >= from and t < to then visits = visits + 1 end end
	m.sessions = visits
	return m
end

--- Before and after the change, the same number of whole days each side: { days, before, after,
--- ready, why, projected }, or nil and why. ready is false until T.MIN_COMPARE_DAYS have passed.
function T.Compare(n, now)
	now = now or time()
	local e = T.Entry(n)
	if not e then return nil, "no suggestion " .. tostring(n) end
	if e.status ~= "changed" or not e.changedAt then return nil, "not changed yet: change it in TSM, then /reload (or /aiq tune changed " .. n .. ")" end
	local days = math.min(T.Get("days"), math.floor((now - e.changedAt) / DAY))
	local out = { entry = e, days = days, projected = e.projected }
	if days < T.MIN_COMPARE_DAYS then
		out.ready, out.why = false, string.format("%d of %d days after the change so far", math.max(0, days), T.MIN_COMPARE_DAYS)
		return out
	end
	local ids = itemsOf(e)
	local c = e.changedAt
	out.before = measure(e, ids, c - days * DAY, c)
	out.after = measure(e, ids, c, c + days * DAY)
	out.ready = true
	-- gold tied up and sessions are recorded from the suggestion on: say when the before side is short
	if (out.before.tiedDays or 0) < days then
		out.tiedNote = string.format("gold tied up was recorded on %d of the %d days before", out.before.tiedDays or 0, days)
	end
	if e.at > c - days * DAY then out.sessionNote = "posting sessions were counted only from the suggestion on, so the days before are short" end
	return out
end

local function money(c) return c and AuctionIQ.FormatMoney(c, true) or "-" end

--- Chat lines for a comparison.
function T.CompareLines(c)
	local e = c.entry
	local out = { string.format("#%d %s: %s %s -> %s (changed %s, %s)", e.n, e.group, e.setting, e.from, tostring(e.value or e.to),
		date and date("%Y-%m-%d", e.changedAt) or tostring(e.changedAt), e.how == "marked" and "marked by you" or "seen in TSM") }
	if not c.ready then table.insert(out, "  too early to compare: " .. c.why); return out end
	local b, a = c.before, c.after
	local function row(label, x, y, fmt)
		local d = (x and y) and (y - x) or nil
		table.insert(out, string.format("  observed %s: %s before, %s after (%s)", label, fmt(x), fmt(y),
			d and ((d >= 0 and "+" or "") .. fmt(d)) or "-"))
	end
	local num = function(v) return v and tostring(math.floor(v + 0.5)) or "-" end
	table.insert(out, string.format("  %d days before against %d days after", c.days, c.days))
	row("net profit", b.net, a.net, function(v) return v and (v < 0 and "-" .. money(-v) or money(v)) or "-" end)
	row("units sold", b.sold, a.sold, num)
	row("units expired", b.expired, a.expired, num)
	row("cancels", b.cancels, a.cancels, num)
	row("gold tied up (average)", b.tied, a.tied, function(v) return v and money(v) or "-" end)
	row("posting sessions", b.sessions, a.sessions, num)
	if c.tiedNote then table.insert(out, "  " .. c.tiedNote) end
	if c.sessionNote then table.insert(out, "  " .. c.sessionNote) end
	local p = c.projected
	if p and p.text then table.insert(out, string.format("  projected when suggested (%d days): %s", p.days or 30, p.text)) end
	return out
end

--- Chat lines for the record: each entry, newest first.
function T.LogLines(limit)
	local list = store().log
	local out = {}
	for i = #list, math.max(1, #list - (limit or 10) + 1), -1 do
		local e = list[i]
		local when = date and date("%m-%d", e.at) or tostring(e.at)
		local state = e.status == "changed" and ("changed to " .. tostring(e.value)) or e.status
		table.insert(out, string.format("#%d %s %s: %s %s -> %s, %s", e.n, when, e.group, e.setting, e.from, e.to, state))
	end
	if #out == 0 then out[1] = "No Tune TSM suggestions recorded yet: /aiq tune records the ones it shows." end
	return out
end

-- Each login: see what changed in TSM, and take today's snapshot.
AuctionIQ.On("PLAYER_LOGIN", function()
	if not (AuctionIQ.db and AuctionIQ.db.tune and AuctionIQ.db.tune.log and #AuctionIQ.db.tune.log > 0) then return end
	pcall(T.CheckChanges)
	pcall(T.Snapshot)
end)
