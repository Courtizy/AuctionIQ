-- AuctionIQ: core, saved data and slash commands. Accounting is its ledger (the books).
local addonName, AuctionIQ = ...
_G.AuctionIQ = AuctionIQ
AuctionIQ.ICON = "Interface\\AddOns\\" .. addonName .. "\\Media\\Icon"

AuctionIQ.version = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addonName, "Version") or "dev"
AuctionIQ.AH_CUT = 0.95
-- Concentration refills from empty to its 1,000 cap in about four days.
AuctionIQ.CONC_PER_HOUR = 1000 / (4 * 24)

local DEFAULTS = { queue = {}, settings = { tooltip = true, coins = true, minimap = { hide = false, angle = 225 }, advisor = { hide = false, docked = true }, scan = { dailyCap = 10 }, window = { popQueue = false }, model = { service = 0.9, carry = 0.01, cover = 7 }, costs = { farmedAt = "market", paybackCrafts = 50, house = "faction" }, craft = { dock = true } }, characters = {} }

local function copyDefaults(dst, src)
	for k, v in pairs(src) do
		if dst[k] == nil then
			dst[k] = type(v) == "table" and copyDefaults({}, v) or v
		elseif type(v) == "table" and type(dst[k]) == "table" then
			copyDefaults(dst[k], v)
		end
	end
	return dst
end

-- Items the auction house won't take: soulbound (BoP), quest items and warbound items, including
-- warbound until equipped. AuctionIQ treats them as worth nothing to sell: no value, no net worth,
-- no dead stock or price alerts. Item bind types from GetItemInfo's 14th return.
local NO_AH = { [1] = true, [4] = true, [7] = true, [8] = true, [9] = true }
local unsellable = {}
function AuctionIQ.Unsellable(id)
	if not id then return false end
	local known = unsellable[id]
	if known ~= nil then return known end
	if not (C_Item and C_Item.GetItemInfo) then return false end
	local bind = select(14, C_Item.GetItemInfo(id))
	if bind == nil then return false end -- not loaded yet: ask again next time
	unsellable[id] = NO_AH[bind] == true
	return unsellable[id]
end

function AuctionIQ.Print(msg)
	local T = AuctionIQ.Theme
	local brand = T and T.hex and T.hex.brand or "3fc7eb"
	print("|cfff2f2f2Auction|r|cff" .. brand .. "IQ|r: " .. tostring(msg))
end

local COIN = {
	g = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t",
	s = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t",
	c = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t",
}

-- "12,345g", "12g 50s", "75s", "9c": short enough for a tooltip line. Shown with the game's coin
-- icons, like TSM, unless coins are turned off (/aiq coins) or plain is asked for.
function AuctionIQ.FormatMoney(copper, plain)
	if not copper then return "-" end
	local icons = not plain and not (AuctionIQ.db and AuctionIQ.db.settings.coins == false)
	local function u(n, unit) return n .. (icons and COIN[unit] or unit) end
	local neg = copper < 0
	copper = math.floor(math.abs(copper) + 0.5)
	local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	local out
	if g >= 100 then
		local str = tostring(g)
		local k
		repeat
			str, k = str:gsub("^(%d+)(%d%d%d)", "%1,%2")
		until k == 0
		out = u(str, "g")
	elseif g > 0 then
		out = s > 0 and (u(g, "g") .. " " .. u(s, "s")) or u(g, "g")
	elseif s > 0 then
		out = u(s, "s")
	else
		out = u(c, "c")
	end
	return (neg and "-" or "") .. out
end

-- The realm's name, read once while the addon loads too: on WoW: Forever, GetRealmName() answers
-- the ruleset's name ("Roleplay") at load but an empty string later in the session. TSM keeps its
-- data under the name read at load, so this matches TSM's keys.
local REALM_AT_LOAD = GetRealmName and GetRealmName() or ""
function AuctionIQ.RealmName()
	local r = GetRealmName and GetRealmName() or ""
	if r == "" then r = REALM_AT_LOAD end
	if r == "" and GetNormalizedRealmName then r = GetNormalizedRealmName() or "" end
	return r
end

-- The character's name as TSM saves it. On WoW: Forever a character can have a surname, and TSM
-- keeps "Auren Lightweaver" where a later UnitName("player") can answer just "Auren". So the name read
-- at load is kept, and if TSM has a profile for a longer name that starts with it on this realm,
-- that name wins.
local NAME_AT_LOAD = UnitName and UnitName("player") or nil
local function tsmName(short, realm)
	local cur = type(TradeSkillMasterDB) == "table" and TradeSkillMasterDB._currentProfile
	if type(cur) ~= "table" then return nil end
	local best
	for key in pairs(cur) do
		local n, r = tostring(key):match("^(.-) %- (.+)$")
		if n and r == realm and (n == short or n:sub(1, #short + 1) == short .. " ") then
			if not best or #n > #best then best = n end
		end
	end
	return best
end
function AuctionIQ.PlayerName()
	local short = UnitName and UnitName("player") or ""
	local name = short
	if NAME_AT_LOAD and #NAME_AT_LOAD > #name and NAME_AT_LOAD:sub(1, #name) == name then name = NAME_AT_LOAD end
	local ok, t = pcall(tsmName, name, AuctionIQ.RealmName())
	if ok and t and #t > #name then name = t end
	return name
end

function AuctionIQ.CharacterKey()
	return AuctionIQ.PlayerName() .. "-" .. AuctionIQ.RealmName()
end

-- This character's record, created on first use. Records saved under an older key move to the
-- right one: an empty realm (Forever builds before the realm fix) or the first name only (before
-- the surname fix).
function AuctionIQ.Me()
	local key = AuctionIQ.CharacterKey()
	local chars = AuctionIQ.db.characters
	local short = UnitName("player")
	if not chars[key] then
		for _, old in ipairs({ short .. "-" .. AuctionIQ.RealmName(), short .. "-", AuctionIQ.PlayerName() .. "-" }) do
			if old ~= key and chars[old] then
				chars[key], chars[old] = chars[old], nil
				break
			end
		end
	end
	if not chars[key] then
		local _, class = UnitClass("player")
		chars[key] = { professions = {}, class = class }
	end
	chars[key].name, chars[key].realm = AuctionIQ.PlayerName(), AuctionIQ.RealmName()
	return chars[key]
end

local function updateGold()
	local me = AuctionIQ.Me()
	me.gold = GetMoney()
	me.updated = time()
end

local frame = CreateFrame("Frame")
AuctionIQ.eventFrame = frame
local handlers = {}
AuctionIQ.handlers = handlers

function AuctionIQ.On(event, fn)
	handlers[event] = handlers[event] or {}
	table.insert(handlers[event], fn)
	pcall(frame.RegisterEvent, frame, event) -- an event this game version doesn't have is skipped, not an error
end

-- What AuctionIQ spends its time on, for /aiq perf: per event (and the tooltip hook), calls and
-- milliseconds, since login or the last /aiq perf reset.
local perf = { since = time and time() or 0, by = {} }
AuctionIQ.perf = perf
local clock = debugprofilestop
function AuctionIQ.Measure(name, fn, ...)
	if not clock then return fn(...) end
	local t0 = clock()
	local a, b, c = fn(...)
	local p = perf.by[name]
	if not p then p = { calls = 0, ms = 0, max = 0 }; perf.by[name] = p end
	local dt = clock() - t0
	p.calls, p.ms, p.max = p.calls + 1, p.ms + dt, math.max(p.max, dt)
	return a, b, c
end

--- Add a timing measured by hand (ms) under name, as AuctionIQ.Measure does.
function AuctionIQ.MeasureAdd(name, dt)
	local p = perf.by[name]
	if not p then p = { calls = 0, ms = 0, max = 0 }; perf.by[name] = p end
	p.calls, p.ms, p.max = p.calls + 1, p.ms + dt, math.max(p.max, dt)
end

local function dispatch(event, ...)
	for _, fn in ipairs(handlers[event] or {}) do
		fn(event, ...)
	end
end
frame:SetScript("OnEvent", function(_, event, ...)
	AuctionIQ.Measure(event, dispatch, event, ...)
end)

--- The /aiq perf report lines: AuctionIQ's memory and its costliest events since login or reset.
function AuctionIQ.PerfLines()
	local out = {}
	local name = addonName
	if UpdateAddOnMemoryUsage then UpdateAddOnMemoryUsage() end
	local getMem = (C_AddOns and C_AddOns.GetAddOnMemoryUsage) or GetAddOnMemoryUsage
	local kb = getMem and getMem(name)
	local secs = time() - (perf.since or time())
	table.insert(out, string.format("AuctionIQ over the last %d min: %s memory", math.floor(secs / 60 + 0.5), kb and string.format("%.1f MB", kb / 1024) or "?"))
	local list = {}
	for ev, p in pairs(perf.by) do list[#list + 1] = { ev = ev, p = p } end
	table.sort(list, function(a, b) return a.p.ms > b.p.ms end)
	for i = 1, math.min(8, #list) do
		local x = list[i]
		table.insert(out, string.format("  %s: %d calls, %.0f ms total, %.1f ms each, slowest %.0f ms", x.ev, x.p.calls, x.p.ms, x.p.ms / x.p.calls, x.p.max))
	end
	if not list[1] then table.insert(out, "  nothing measured yet") end
	return out
end

-- Whole-client frame times while AuctionIQ is loaded (the game's own, everything included): how many
-- frames fell in each band, and the slowest, since login or the last reset. A frame over 50 ms is a
-- hitch you can feel; it isn't always AuctionIQ's, which is what the per-event timings are for.
local FRAME_BANDS = { 16.7, 33.3, 50, 100 }
perf.frames = { n = 0, bands = { 0, 0, 0, 0, 0 }, max = 0 }
function AuctionIQ.PerfFrame(elapsed)
	local f = perf.frames
	local ms = (elapsed or 0) * 1000
	f.n = f.n + 1
	local k = #FRAME_BANDS + 1
	for i, b in ipairs(FRAME_BANDS) do if ms < b then k = i; break end end
	f.bands[k] = f.bands[k] + 1
	if ms > f.max then f.max = ms end
end
frame:SetScript("OnUpdate", function(_, elapsed) AuctionIQ.PerfFrame(elapsed) end)
AuctionIQ.FRAME_BANDS = FRAME_BANDS

function AuctionIQ.PerfReset() perf.by, perf.since = {}, time(); perf.frames = { n = 0, bands = { 0, 0, 0, 0, 0 }, max = 0 } end

--- Save what's been measured since the last reset as one workload of the live baseline (L-02),
--- then reset: AuctionIQ.db.debug.baseline[name] = { at, secs, mem (KB), frames, by = { name, calls,
--- ms, max } (every timing, slowest first) }. Returns the entry.
function AuctionIQ.PerfMark(name)
	if not (AuctionIQ.db and name and name ~= "") then return nil end
	if UpdateAddOnMemoryUsage then UpdateAddOnMemoryUsage() end
	local getMem = (C_AddOns and C_AddOns.GetAddOnMemoryUsage) or GetAddOnMemoryUsage
	local list = {}
	for n, p in pairs(perf.by) do list[#list + 1] = { name = n, calls = p.calls, ms = math.floor(p.ms + 0.5), max = math.floor(p.max * 10 + 0.5) / 10 } end
	table.sort(list, function(a, b) return a.max > b.max end)
	local f = perf.frames
	local e = { at = time(), secs = time() - (perf.since or time()), mem = getMem and math.floor(getMem(addonName) or 0) or nil, by = list,
		frames = { n = f.n, bands = { f.bands[1], f.bands[2], f.bands[3], f.bands[4], f.bands[5] }, max = math.floor(f.max * 10 + 0.5) / 10 },
		build = AuctionIQ.version }
	AuctionIQ.db.debug = AuctionIQ.db.debug or {}
	AuctionIQ.db.debug.baseline = AuctionIQ.db.debug.baseline or {}
	AuctionIQ.db.debug.baseline[name] = e
	AuctionIQ.PerfReset()
	return e
end

-- Kept in the saved variables at logout or /reload (the costliest 20), so a lag report can be read
-- after the session that had it.
AuctionIQ.On("PLAYER_LOGOUT", function()
	if not AuctionIQ.db then return end
	local list = {}
	for name, p in pairs(perf.by) do list[#list + 1] = { name = name, calls = p.calls, ms = math.floor(p.ms + 0.5), max = math.floor(p.max * 10 + 0.5) / 10 } end
	table.sort(list, function(a, b) return a.max > b.max end)
	for i = #list, 21, -1 do list[i] = nil end
	AuctionIQ.db.debug = AuctionIQ.db.debug or {}
	AuctionIQ.db.debug.perf = { at = time(), since = perf.since, by = list }
end)

-- SavedVariables versions. Each step brings data saved by an older build up to the next version;
-- AuctionIQ.Load also tidies what can go stale between sessions (every load, cheap and idempotent).
AuctionIQ.DB_VERSION = 3
AuctionIQ.MIGRATIONS = {
	-- 1 -> 2: the mail feature was removed; craft records (batches) get a bounded history
	[2] = function(db)
		db.mail = nil
	end,
	-- 2 -> 3: day-by-day history older than a few months is rolled into months, and competition
	-- notes are capped (Ledger.ArchiveMonths); every load after keeps it that way (Tidy)
	[3] = function(db)
		if AuctionIQ.Ledger then AuctionIQ.Ledger.ArchiveMonths(db) end -- not loaded on Forever yet
	end,
}
-- Craft records follow CraftSim's rule: no age limit (they go with the profession), only a cap on
-- how many, oldest first, so SavedVariables stays a safe size.
AuctionIQ.BATCHES_MAX = 5000

-- The saved keys each step changes. They're copied into db.backup before the first step runs, and
-- put back if a step fails.
AuctionIQ.MIGRATION_KEYS = { [2] = { "mail" }, [3] = { "ledger" } }

local function deepcopy(v)
	if type(v) ~= "table" then return v end
	local t = {}
	for k, x in pairs(v) do t[k] = deepcopy(x) end
	return t
end
AuctionIQ.DeepCopy = deepcopy

--- Brings a save up to DB_VERSION. The version is read before anything else touches the table, the
--- keys the steps change are backed up first (one backup is kept), and a step that fails puts them
--- back, stops, and leaves db.migrationFailed for Settings ▸ About.
function AuctionIQ.Migrate(db)
	local v = tonumber(db.version) or 1
	if v >= AuctionIQ.DB_VERSION then return db end
	local backup = { from = v, at = time and time() or 0, data = {} }
	for to = v + 1, AuctionIQ.DB_VERSION do
		for _, k in ipairs(AuctionIQ.MIGRATION_KEYS[to] or {}) do
			if backup.data[k] == nil then backup.data[k] = deepcopy(db[k]) or false end
		end
	end
	db.backup = backup
	for to = v + 1, AuctionIQ.DB_VERSION do
		local step = AuctionIQ.MIGRATIONS[to]
		if step then
			local ok, err = pcall(step, db)
			if not ok then
				for k, x in pairs(backup.data) do db[k] = x or nil end
				db.migrationFailed = { to = to, err = tostring(err), at = backup.at }
				AuctionIQ.Print("couldn't update saved data to version " .. to .. ", so it was left as it was: " .. tostring(err))
				return db
			end
		end
		db.version = to
	end
	db.migrationFailed = nil
	return db
end

--- The saved table to use this session, from what WoW loaded. A save written by a newer AuctionIQ
--- is opened read-only: the addon works on a copy, and the original goes back to disk unchanged.
function AuctionIQ.Load(raw)
	AuctionIQ.readOnly = nil
	if raw == nil then
		raw = { version = AuctionIQ.DB_VERSION }
	elseif (tonumber(raw.version) or 1) > AuctionIQ.DB_VERSION then
		AuctionIQ.readOnly = raw.version
		AuctionIQ.Print("this save was written by a newer AuctionIQ (data version " .. tostring(raw.version) .. "). It's open read-only, so nothing changes on disk. Update AuctionIQ to use it fully.")
		return raw, AuctionIQ.Tidy(copyDefaults(deepcopy(raw), DEFAULTS))
	end
	AuctionIQ.Migrate(raw)
	return raw, AuctionIQ.Tidy(copyDefaults(raw, DEFAULTS))
end

--- Every load: queue entries from older builds get the fields the queue relies on (an entry that
--- names no recipe is dropped), steps waiting on the game from an earlier session are cleared
--- (GetTime restarts with the client), and craft records over the cap are trimmed, oldest first.
function AuctionIQ.Tidy(db, now)
	now = now or (time and time()) or 0
	local keep = {}
	for _, e in ipairs(db.queue or {}) do
		if type(e) == "table" and e.recipeID then
			e.reagents, e.shop = e.reagents or {}, e.shop or {}
			e.qty = tonumber(e.qty) or 1
			e.char = e.char or "?"
			if e.orderID then e.orderID = tostring(e.orderID) end
			e.pending, e.pendingAt, e.confirmed = nil, nil, nil
			if e.qty > 0 then keep[#keep + 1] = e end
		end
	end
	db.queue = keep
	-- old days roll into months as they age (the version 3 migration did it once for what was there)
	if AuctionIQ.Ledger and AuctionIQ.Ledger.ArchiveMonths then pcall(AuctionIQ.Ledger.ArchiveMonths, db, now) end
	local b = db.batches
	if type(b) == "table" then
		local extra = #b - AuctionIQ.BATCHES_MAX
		if extra > 0 then
			local out = {}
			for i = extra + 1, #b do out[#out + 1] = b[i] end
			db.batches = out
		end
	end
	return db
end

AuctionIQ.On("ADDON_LOADED", function(_, name)
	if name ~= addonName then return end
	AuctionIQDB, AuctionIQ.db = AuctionIQ.Load(AuctionIQDB)
end)

AuctionIQ.On("PLAYER_LOGIN", function()
	updateGold()
	if not AuctionIQ.Prices.Available() then
		AuctionIQ.Print("TradeSkillMaster isn't loaded, so prices are off. Install TSM to see values and profits.")
	end
end)
AuctionIQ.On("PLAYER_MONEY", updateGold)

SLASH_AUCTIONIQ1 = "/aiq"
SLASH_AUCTIONIQ2 = "/auctioniq"
SlashCmdList.AUCTIONIQ = function(msg)
	-- the new window takes the commands it knows; on Forever the older screens aren't loaded at all
	if AuctionIQ.Shell and AuctionIQ.Shell.Command(msg) then return end
	if AuctionIQ.IsForever and AuctionIQ.IsForever() then
		AuctionIQ.Print("/aiq opens the window. /aiq craft, /aiq sales or /aiq inv opens a tab, /aiq settings opens Settings. /aiq game shows the game and realm detected.")
		return
	end
	local raw = msg or ""
	msg = strtrim and strtrim(msg or ""):lower() or (msg or ""):lower()
	if msg == "perf" then
		for _, l in ipairs(AuctionIQ.PerfLines()) do AuctionIQ.Print(l) end
		return
	elseif msg == "mem" then
		-- what AuctionIQ holds once the garbage is cleared, and what it's made of
		local getMem = (C_AddOns and C_AddOns.GetAddOnMemoryUsage) or GetAddOnMemoryUsage
		if UpdateAddOnMemoryUsage then UpdateAddOnMemoryUsage() end
		local before = getMem and getMem(addonName) or 0
		collectgarbage("collect")
		if UpdateAddOnMemoryUsage then UpdateAddOnMemoryUsage() end
		local after = getMem and getMem(addonName) or 0
		AuctionIQ.Print(string.format("memory %.1f MB, %.1f MB after clearing garbage", before / 1024, after / 1024))
		for _, l in ipairs(AuctionIQ.MemLines and AuctionIQ.MemLines() or {}) do AuctionIQ.Print("  " .. l) end
		return
	elseif msg == "perf reset" then
		AuctionIQ.PerfReset(); AuctionIQ.Print("perf counters reset.")
		return
	elseif msg:match("^perf mark") then
		local name = msg:match("^perf mark%s+(.+)$")
		if not name then AuctionIQ.Print("/aiq perf mark <workload>: saves what's been measured since the last reset under that name, then resets."); return end
		local e = AuctionIQ.PerfMark(name)
		local top = e and e.by[1]
		local f = e and e.frames
		AuctionIQ.Print(string.format("saved \"%s\" (%d s): %s; frames %d, slowest %.0f ms, %d over 50 ms. /reload when you're done so it's written.",
			name, e and e.secs or 0, top and string.format("slowest AuctionIQ work %s at %.0f ms", top.name, top.max) or "no AuctionIQ work measured",
			f and f.n or 0, f and f.max or 0, f and (f.bands[4] + f.bands[5]) or 0))
		return
	elseif msg == "tooltip" then
		AuctionIQ.db.settings.tooltip = not AuctionIQ.db.settings.tooltip
		AuctionIQ.Print("tooltip lines " .. (AuctionIQ.db.settings.tooltip and "on" or "off"))
	elseif msg == "coins" then
		AuctionIQ.db.settings.coins = not AuctionIQ.db.settings.coins
		AuctionIQ.Print("coin icons " .. (AuctionIQ.db.settings.coins and "on" or "off"))
		if AuctionIQ.UI.IsShown() then AuctionIQ.UI.Refresh() end
	elseif msg:match("^event ") then
		local day, name = msg:match("^event (%d+%-%d+%-%d+) (.+)$")
		if day then AuctionIQ.Planner.AddEvent(day, name); AuctionIQ.Print("added " .. day .. " " .. name) else AuctionIQ.Print("/aiq event 2026-12-01 Season 2 starts") end
	elseif msg:match("^task ") then
		local name = msg:match("^task (.+)$")
		table.insert(AuctionIQ.Planner.Store().tasks, name)
		AuctionIQ.Print("weekly task added: " .. name)
	elseif msg == "theme" then
		AuctionIQ.db.settings.theme = AuctionIQ.db.settings.theme ~= "elvui" and "elvui" or "aiq"
		AuctionIQ.Print(AuctionIQ.db.settings.theme == "elvui" and "using ElvUI's colours. /reload to apply everywhere." or "using the AuctionIQ and Accounting colours. /reload to apply everywhere.")
		AuctionIQ.Theme.Use(AuctionIQ.Theme.palette)
		if AuctionIQ.UI.IsShown() then AuctionIQ.UI.Refresh() end
	elseif msg == "basis" or msg:match("^basis ") then
		local want = msg:match("^basis (%a+)$")
		local P = AuctionIQ.Prices
		if not want then
			-- no name: the next one
			local cur, i = P.CostBasis(), 1
			for k, b in ipairs(P.BASES) do if b == cur then i = k end end
			want = P.BASES[i % #P.BASES + 1]
		end
		if not P.BASIS_NAMES[want] then AuctionIQ.Print("/aiq basis held | replacement | tsm | paid")
		else P.CostBasis(want); AuctionIQ.Print("reagents costed at: " .. P.BASIS_NAMES[want]); if AuctionIQ.UI.IsShown() then AuctionIQ.UI.Refresh() end end
	elseif msg == "alerts" then
		AuctionIQ.Alerts.Toggle()
	elseif msg == "minimap" then
		AuctionIQ.db.settings.minimap.hide = not AuctionIQ.db.settings.minimap.hide
		AuctionIQ.UpdateMinimapButton()
		AuctionIQ.Print("minimap button " .. (AuctionIQ.db.settings.minimap.hide and "hidden" or "shown"))
	elseif msg == "orders" then
		AuctionIQ.Orders.Debug()
	elseif msg == "deals" then
		AuctionIQ.Print("deals and AH buying are TSM's job now: use TSM's Shopping tab (Sniper or a Shopping operation).")
	elseif msg == "shatter" then
		-- what Shatter could take, and how many of each you hold in bags / everywhere
		local ids = AuctionIQ.Queue.ShatterCandidates()
		AuctionIQ.Print(#ids .. " items Shatter can take" .. (#ids == 0 and " (open your enchanting window first)" or ":"))
		for _, id in ipairs(ids) do
			local bags = C_Item.GetItemCount(id) or 0
			local all = C_Item.GetItemCount(id, true, false, true, true) or 0
			AuctionIQ.Print(string.format("  %s (%d): %d in bags, %d in all", AuctionIQ.Advisor.ItemName(id), id, bags, all))
		end
		local id, bag, slot = AuctionIQ.Queue.ShatterItem()
		AuctionIQ.Print("would use: " .. (id and (AuctionIQ.Advisor.ItemName(id) .. (bag and (" in bag " .. bag .. " slot " .. slot) or " (not in your bags)")) or "nothing"))
	elseif msg == "queue" then
		AuctionIQ.QueueUI.Toggle()
	elseif msg == "scan" then
		AuctionIQ.ScanUI.Toggle()
	elseif msg == "paths" or msg:match("^plan") or msg:match("^path ") then
		local goal = msg:match("^plan%s+(.+)") or msg:match("^path%s+(.+)")
		if AuctionIQ.Paths.Load() then
			if not AuctionIQ.PathsUI.IsShown() then AuctionIQ.PathsUI.Open() end
			if goal then AuctionIQ.PathsUI.Run(goal) end
		end
	elseif msg == "results clear" then
		AuctionIQ.Log.Clear(); AuctionIQ.Print("this character's craft results log is empty again.")
	elseif msg == "results" or msg == "log" then
		AuctionIQ.LogUI.Open()
	elseif msg:match("^cap") then
		local n = tonumber(msg:match("(%d+)"))
		if n then AuctionIQ.db.settings.scan.dailyCap = n end
		AuctionIQ.Print("the region's sold a day counts at most " .. AuctionIQ.db.settings.scan.dailyCap .. " a day per item until your own sales take over. /aiq cap 20 to change.")
	elseif msg == "de" or msg:match("^de ") or msg:match("^disenchant") then
		local a, b, c = msg:match("(%d+)%s+(%d+)%s+(%d+)")
		if a then AuctionIQ.Paths.SetDailyYield(2909, { dust = tonumber(a), shard = tonumber(b), crystal = tonumber(c) })
		elseif msg:match("auto") then AuctionIQ.Paths.SetDailyYield(2909, nil) end
		local d, from, days = AuctionIQ.Paths.DailyYield(2909)
		local src = from == "set" and "as you set them (/aiq de auto to use what you really disenchant)"
			or from == "seen" and string.format("from what you disenchanted over the last %d days", days)
			or "as a starting guess until you disenchant something"
		AuctionIQ.Print(string.format("disenchanting plans count %.0f Eversinging Dust, %.0f Radiant Shards and %.0f Dawn Crystals a day, %s.",
			d.dust, d.shard, d.crystal, src))
	elseif msg == "overview" or msg == "dashboard" then AuctionIQ.UI.Page("today") -- dashboard: the old name
	elseif msg == "crafting" or msg == "operations" or msg == "craft" then AuctionIQ.UI.Page("operations", "scenarios") -- operations: the old name
	elseif msg == "trade" or msg == "markets" then AuctionIQ.UI.Page("ledger", "markets")
	elseif msg == "shopping" then AuctionIQ.UI.Page("operations", "shopping")
	elseif msg:match("^scenario") then
		local r, p = msg:match("^scenarios?%s+(%d+)%s+(%d+)")
		if r and AuctionIQ.AnalyticsViews then AuctionIQ.AnalyticsViews.SetScenario(tonumber(r) / 100, tonumber(p) / 100) end
		AuctionIQ.UI.Page("operations", "scenarios")
	elseif msg == "accounting" then AuctionIQ.UI.Page("ledger")
	elseif msg == "settings" then AuctionIQ.UI.Page("settings")
	elseif msg == "advisor" then
		AuctionIQ.AdvisorUI.ToggleSetting()
	elseif msg == "cleanup" then
		AuctionIQ.Cleanup.Report()
	elseif msg:match("^prune") then
		AuctionIQ.Cleanup.AskPrune(tonumber(msg:match("^prune%s+(%d+)")))
	elseif msg == "mechanics" then
		for _, l in ipairs(AuctionIQ.Mechanics.Lines()) do AuctionIQ.Print(l) end
	elseif msg == "tune" or msg:match("^tune ") then
		AuctionIQ.Tune.Command(msg:match("^tune%s*(.*)$"))
	elseif msg == "tsm" or msg:match("^tsm ") then
		-- group paths keep their case
		AuctionIQ.TSMSetup.Command(raw:match("^%s*[Tt][Ss][Mm]%s*(.*)$"))
	elseif msg == "help" then
		AuctionIQ.Print("/aiq opens the window. /aiq settings opens Settings, where all of these can be changed without commands. /aiq tooltip turns the tooltip lines on or off. /aiq coins switches between coin icons and g/s/c. /aiq minimap hides or shows the minimap button. /aiq advisor turns the crafting advisor on or off. /aiq queue opens the craft queue and shopping list. /aiq scan ranks every recipe of the open profession. /aiq plan potions plans knowledge points for what you want to sell. /aiq results shows what your crafts really gave. /aiq mechanics shows what Resourcefulness, Ingenuity and Multicraft give, as measured from your own crafts. /aiq cap 20 sets the most of the region's sold a day counted for one item, until your own sales take over. Disenchanting plans count what you really disenchant; /aiq de 40 8 2 sets it by hand, /aiq de auto goes back. /aiq alerts turns alerts on or off. /aiq overview, crafting (or craft, shopping) or accounting opens that tab; /aiq markets opens Accounting > Markets. /aiq tsm with an item link, item ID or TSM group shows how TSM is set up for it: the operation that applies, where it's set, its settings and what can't be read reliably. /aiq tune lists, for your TSM groups, the one change to each group's operation with the strongest evidence from the last 30 days, with a value to copy into TSM, and records each one; /aiq tune log lists them and /aiq tune compare 3 compares the days after you changed #3 in TSM with the days before. /aiq scenario 15 10 sets the Scenarios to reagents +15%, prices -10%. /aiq theme switches between the AuctionIQ colours and ElvUI's. /aiq cleanup lets go of what AuctionIQ keeps only for speed and drops saved data nothing uses (the saved part also runs at logout). /aiq prune 365 removes history older than 365 days, after asking.")
	else
		AuctionIQ.UI.Toggle()
	end
end

function AuctionIQ_OnAddonCompartmentClick()
	local ui = AuctionIQ.Shell or AuctionIQ.UI -- the new window where it's loaded (Forever for now)
	ui.Toggle()
end
