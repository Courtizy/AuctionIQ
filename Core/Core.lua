-- AuctionIQ: core, saved data and slash commands. Accounting is its ledger (the books).
local addonName, AuctionIQ = ...
_G.AuctionIQ = AuctionIQ
AuctionIQ.ICON = "Interface\\AddOns\\" .. addonName .. "\\Media\\Icon"

AuctionIQ.version = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addonName, "Version") or "dev"
AuctionIQ.AH_CUT = 0.95
-- Concentration refills from empty to its 1,000 cap in about four days.
AuctionIQ.CONC_PER_HOUR = 1000 / (4 * 24)

local DEFAULTS = { version = 2, queue = {}, settings = { tooltip = true, coins = true, minimap = { hide = false, angle = 225 }, advisor = { hide = false, docked = true }, scan = { dailyCap = 10 }, window = { popQueue = false }, model = { service = 0.9, carry = 0.01, cover = 7 } }, characters = {} }

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
-- icons, like TSM, unless coins are turned off (/ch coins) or plain is asked for.
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

function AuctionIQ.CharacterKey()
	return UnitName("player") .. "-" .. GetRealmName()
end

-- This character's record, created on first use.
function AuctionIQ.Me()
	local key = AuctionIQ.CharacterKey()
	local chars = AuctionIQ.db.characters
	if not chars[key] then
		local _, class = UnitClass("player")
		chars[key] = { name = UnitName("player"), realm = GetRealmName(), class = class, professions = {} }
	end
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

function AuctionIQ.PerfReset() perf.by, perf.since = {}, time() end

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
AuctionIQ.DB_VERSION = 2
AuctionIQ.MIGRATIONS = {
	-- 1 -> 2: the mail feature was removed; craft records (batches) get a bounded history
	[2] = function(db)
		db.mail = nil
	end,
}
-- Craft records follow CraftSim's rule: no age limit (they go with the profession), only a cap on
-- how many, oldest first, so SavedVariables stays a safe size.
AuctionIQ.BATCHES_MAX = 5000

function AuctionIQ.Migrate(db)
	local v = tonumber(db.version) or 1
	for to = v + 1, AuctionIQ.DB_VERSION do
		local step = AuctionIQ.MIGRATIONS[to]
		if step then
			local ok, err = pcall(step, db)
			if not ok then AuctionIQ.Print("couldn't update saved data to version " .. to .. ": " .. tostring(err)); return db end
		end
		db.version = to
	end
	return db
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
	AuctionIQDB = copyDefaults(AuctionIQDB or {}, DEFAULTS)
	AuctionIQ.db = AuctionIQ.Tidy(AuctionIQ.Migrate(AuctionIQDB))
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
	elseif msg == "trade" then AuctionIQ.UI.Page("operations", "post")
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
	elseif msg == "help" then
		AuctionIQ.Print("/aiq opens the window (/ch works too). /aiq settings opens Settings, where all of these can be changed without commands. /aiq tooltip turns the tooltip lines on or off. /aiq coins switches between coin icons and g/s/c. /aiq minimap hides or shows the minimap button. /aiq advisor turns the crafting advisor on or off. /aiq queue opens the craft queue and shopping list. /aiq scan ranks every recipe of the open profession. /aiq plan potions plans knowledge points for what you want to sell. /aiq results shows what your crafts really gave. /aiq cap 20 sets the most of the region's sold a day counted for one item, until your own sales take over. Disenchanting plans count what you really disenchant; /aiq de 40 8 2 sets it by hand, /aiq de auto goes back. /aiq alerts turns alerts on or off. /aiq dashboard, operations (or craft, trade, shopping) or accounting opens that tab. /aiq scenario 15 10 sets the Scenarios to reagents +15%, prices -10%. /aiq theme switches between the AuctionIQ colours and ElvUI's. /aiq cleanup lets go of what AuctionIQ keeps only for speed and drops saved data nothing uses (the saved part also runs at logout). /aiq prune 365 removes history older than 365 days, after asking.")
	else
		AuctionIQ.UI.Toggle()
	end
end

function AuctionIQ_OnAddonCompartmentClick()
	AuctionIQ.UI.Toggle()
end
