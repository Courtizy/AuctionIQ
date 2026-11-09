-- Planning: knowledge points per character and profession each week (from the spec trees), a weekly
-- checklist of knowledge sources you tick off (it clears at the weekly reset), coming events (the
-- game calendar's holidays plus dates you add), and time spent goldmaking for gold per hour.
local _, CH = ...

local Pl = {}
CH.Planner = Pl

local WEEK = 7 * 86400

local function store()
	CH.db.planner = CH.db.planner or {}
	local s = CH.db.planner
	s.kp = s.kp or {}            -- [charKey][profName] = { [weekStart] = total }
	s.tasks = s.tasks or { "Treatise", "Weekly quest", "Weekly drops", "Gathering / disenchant drops" }
	s.done = s.done or {}        -- [weekStart][charKey .. "|" .. prof .. "|" .. task] = true
	s.events = s.events or {}    -- { { date = "YYYY-MM-DD", name } }
	s.sessions = s.sessions or {} -- { { kind, char, start, stop } }
	return s
end
Pl.Store = store

--- Start of this game week (the last weekly reset).
function Pl.WeekStart(now)
	now = now or time()
	local left = C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset and C_DateAndTime.GetSecondsUntilWeeklyReset()
	if left then return math.floor((now + left - WEEK) / 60) * 60 end
	return now - (now % WEEK)
end

-- Knowledge points ----------------------------------------------------------------------------
--- Points a spec tree holds: spent on nodes plus unspent.
function Pl.TreeTotal(tree)
	if not tree then return nil end
	local t = tree.unspent or 0
	for _, n in pairs(tree.nodes or {}) do if (n.rank or -1) >= 0 then t = t + n.rank + 1 end end
	return t
end

--- Record this week's total for every profession of this character (from its last tree read).
function Pl.RecordKP(now)
	local me, key = CH.Me(), CH.CharacterKey()
	local s = store()
	local wk = Pl.WeekStart(now)
	s.kp[key] = s.kp[key] or {}
	for _, p in pairs(me.professions or {}) do
		local total = Pl.TreeTotal(p.spec)
		if total and p.name then
			local t = s.kp[key][p.name] or {}
			s.kp[key][p.name] = t
			t.first = t.first or {}
			if not t.first[wk] then t.first[wk] = total end
			t.now, t.unspent = total, p.spec.unspent
		end
	end
end

--- Every character and profession: { char, key, prof, gained (this week), unspent, total, tasks = { {name, done} } }.
function Pl.Knowledge(now)
	local s, wk = store(), Pl.WeekStart(now)
	local out = {}
	for key, profs in pairs(s.kp) do
		local c = CH.db.characters[key]
		for prof, t in pairs(profs) do
			local start = t.first and t.first[wk]
			local tasks = {}
			for _, name in ipairs(s.tasks) do
				table.insert(tasks, { name = name, done = (s.done[wk] or {})[key .. "|" .. prof .. "|" .. name] == true })
			end
			table.insert(out, { char = c and c.name or key, key = key, prof = prof, gained = start and t.now and (t.now - start) or 0,
				unspent = t.unspent or 0, total = t.now, tasks = tasks })
		end
	end
	table.sort(out, function(a, b) if a.char ~= b.char then return a.char < b.char end return a.prof < b.prof end)
	return out
end

--- Tick (or untick) a weekly task for a character's profession.
function Pl.Tick(key, prof, task, now)
	local s, wk = store(), Pl.WeekStart(now)
	s.done[wk] = s.done[wk] or {}
	local k = key .. "|" .. prof .. "|" .. task
	s.done[wk][k] = not s.done[wk][k] or nil
	for w in pairs(s.done) do if w < wk - 4 * WEEK then s.done[w] = nil end end
	return s.done[wk][k] == true
end

-- Calendar -------------------------------------------------------------------------------------
--- Add a date of your own: "2026-12-01", "Season 2 starts".
function Pl.AddEvent(day, name) table.insert(store().events, { date = day, name = name }) end

local DEMAND = { { "season", "stock potions, flasks and gems" }, { "raid", "stock flasks and potions" }, { "patch", "stock consumables; reagent prices move" },
	{ "darkmoon", "Darkmoon profession quests: knowledge" }, { "timewalking", "older consumables sell" } }

local function hint(name)
	local l = string.lower(name or "")
	for _, d in ipairs(DEMAND) do if l:find(d[1], 1, true) then return d[2] end end
end

--- Events in the next `days` days: { date, name, hint, mine }.
function Pl.Upcoming(now, days)
	now, days = now or time(), days or 14
	local out = {}
	for _, e in ipairs(store().events) do
		local y, m, d = (e.date or ""):match("^(%d+)-(%d+)-(%d+)$")
		if y then
			local t = time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
			if t >= now - 86400 and t <= now + days * 86400 then table.insert(out, { t = t, date = e.date, name = e.name, hint = hint(e.name), mine = true }) end
		end
	end
	if C_Calendar and C_Calendar.GetNumDayEvents and C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime then
		local seen = {}
		for i = 0, days do
			local t = now + i * 86400
			local dt = date("*t", t)
			local ok, n = pcall(C_Calendar.GetNumDayEvents, 0, dt.day)
			if ok and dt.month == date("*t", now).month then
				for j = 1, n or 0 do
					local ev = C_Calendar.GetDayEvent(0, dt.day, j)
					if ev and ev.calendarType == "HOLIDAY" and ev.title and not seen[ev.title] then
						seen[ev.title] = true
						table.insert(out, { t = t, date = date("%Y-%m-%d", t), name = ev.title, hint = hint(ev.title) })
					end
				end
			end
		end
	end
	table.sort(out, function(a, b) return a.t < b.t end)
	return out
end

-- Time spent -------------------------------------------------------------------------------------
local open = {}
local function start(kind) open[kind] = time() end
local function stop(kind)
	if not open[kind] then return end
	local s = store()
	table.insert(s.sessions, { kind = kind, char = UnitName and UnitName("player"), start = open[kind], stop = time() })
	open[kind] = nil
	while #s.sessions > 2000 do table.remove(s.sessions, 1) end
end
Pl.StartSession, Pl.StopSession = start, stop

--- Hours per activity since a time and gold per hour of goldmaking time: { kinds = { [kind] = hours },
--- hours, profit (cash, from TSM), perHour }.
function Pl.Time(since)
	local kinds, total, spans = {}, 0, {}
	for _, x in ipairs(store().sessions) do
		if x.stop >= since then
			local a = math.max(x.start, since)
			kinds[x.kind] = (kinds[x.kind] or 0) + (x.stop - a) / 3600
			table.insert(spans, { a, x.stop })
		end
	end
	-- the total counts time once when two windows were open together (the AH and a profession)
	table.sort(spans, function(p, q) return p[1] < q[1] end)
	local upTo
	for _, sp in ipairs(spans) do
		local a = upTo and math.max(sp[1], upTo) or sp[1]
		if sp[2] > a then total = total + (sp[2] - a) / 3600 end
		upTo = upTo and math.max(upTo, sp[2]) or sp[2]
	end
	local profit
	if CH.Ledger and CH.Ledger.Available() then
		local o = CH.Ledger.Overhead(since)
		profit = o.afterOverhead
	end
	return { kinds = kinds, hours = total, profit = profit, perHour = profit and total > 0 and profit / total or nil }
end

CH.On("AUCTION_HOUSE_SHOW", function() start("Auction House") end)
CH.On("AUCTION_HOUSE_CLOSED", function() stop("Auction House") end)
CH.On("MAIL_SHOW", function() start("Mailbox") end)
CH.On("MAIL_CLOSED", function() stop("Mailbox") end)
CH.On("TRADE_SKILL_SHOW", function() start("Crafting") end)
CH.On("TRADE_SKILL_CLOSE", function() stop("Crafting"); pcall(Pl.RecordKP) end)
CH.On("PLAYER_LOGOUT", function() for k in pairs(open) do stop(k) end end)
