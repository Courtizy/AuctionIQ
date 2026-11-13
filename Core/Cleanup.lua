-- Keeping the saved data small. AuctionIQ saves what the auction house showed for every item it
-- sees, and a TSM full scan shows twenty thousand of them; most are things you never hold, sell,
-- craft or buy. Those are kept for the session (they're seen again the next time the AH opens)
-- but not written to SavedVariables. What's kept: anything you searched yourself (a full search or
-- a buying ladder), and every item you hold, sold in the last 30 days, have on the shopping list or
-- in the queue, craft (or craft with Concentration), have post advice, rivals or alerts for.
--
-- Also, as CraftSim does when a profession is dropped: a character's saved data for a profession
-- it no longer has goes.
--
-- Runs at logout, and on /aiq cleanup (which says what it freed).
--
-- /aiq cleanup (and Settings, "Clean up") also lets go of what AuctionIQ only keeps for speed this
-- session: cached prices, auction-house depth, TSM's parsed records and their sorted views, demand,
-- forecasts and the advisor's worked-out results. Each rebuilds when it's next needed (the TSM
-- records in the background, a few milliseconds a frame). It never touches your queue, settings,
-- groups, crafting records, decisions or history.
--
-- Pruning history is separate and asks first, as TSM does (Settings > Accounting > Clear Old Data):
-- you choose the age, 365 days by default, and it says what will go before anything does. It covers
-- AuctionIQ's own day-by-day totals, net worth days and competition notes. Crafting records follow
-- CraftSim's rule instead: they stay with the character and go only with the profession.
local _, CH = ...

local C = {}
CH.Cleanup = C

local function add(set, id)
	id = tonumber(id)
	if id then set[id] = true end
end

--- The items whose scans are worth saving: { [id] = true }.
function C.Keep(now)
	local keep = {}
	if CH.Compare and CH.Compare.Items then
		local ok, ids = pcall(CH.Compare.Items, nil, now)
		if ok and type(ids) == "table" then for id in pairs(ids) do add(keep, id) end end
	end
	for _, c in pairs(CH.db.characters or {}) do
		for _, p in pairs(c.professions or {}) do
			for _, r in pairs(p.scan and p.scan.rows or {}) do add(keep, r.item); add(keep, r.concItem) end
		end
	end
	for _, q in pairs(CH.db.queue or {}) do add(keep, q.id or q.item or q.itemID) end
	for _, a in pairs(CH.db.postAdvice or {}) do add(keep, a.id) end
	for id in pairs(CH.db.competition or {}) do add(keep, id) end
	for _, b in pairs(CH.db.batches or {}) do add(keep, b.id) end
	for _, id in pairs(CH.db.alerts and CH.db.alerts.prices or {}) do add(keep, id) end
	return keep
end

--- Drop the scans of items nothing uses. Returns how many went and how many stay.
function C.Scans(now)
	local store = CH.db and CH.db.scans
	if not store then return 0, 0 end
	local keep = C.Keep(now)
	local dropped, kept = 0, 0
	for id, e in pairs(store) do
		if e.full or e.ladder or keep[id] then kept = kept + 1
		else store[id] = nil; dropped = dropped + 1 end
	end
	return dropped, kept
end

--- This character's professions from the game, by name ({ Enchanting = true }), or nil when the
--- game can't say (then nothing is dropped).
local function known()
	if not (GetProfessions and GetProfessionInfo) then return nil end
	local names, any = {}, false
	for _, ix in ipairs({ GetProfessions() }) do
		if ix then
			local name = GetProfessionInfo(ix)
			if name then names[name] = true; any = true end
		end
	end
	return any and names or nil
end

--- Drop this character's saved data for professions it no longer has. Returns the names dropped.
function C.Professions()
	local me = CH.Me and CH.Me()
	local names = known()
	local out = {}
	if not (me and me.professions and names) then return out end
	for id, p in pairs(me.professions) do
		-- only entries that name their base profession ("Enchanting" for Midnight Enchanting)
		local parent = p.parent
		if parent and not names[parent] then
			me.professions[id] = nil
			table.insert(out, p.name or parent)
		end
	end
	table.sort(out)
	return out
end

--- Everything above. Returns { scans = dropped, kept = n, professions = { names } }.
function C.Run(now)
	if not CH.db then return { scans = 0, kept = 0, professions = {} } end
	local dropped, kept = C.Scans(now)
	return { scans = dropped, kept = kept, professions = C.Professions() }
end


-- Temporary data --------------------------------------------------------------------------------
C.GC_FRAMES = 300 -- at most this many frames of collector steps before it reports

--- Let go of every session cache, and the saved scans nothing uses. The collector then runs a few
--- milliseconds a frame (no full collect, so no hitch) until its cycle is through, the memory is
--- measured, and only then do TSM's records start coming back in the background. `done(r)` runs
--- once measured and `rebuilt()` once the records are back. Returns r at once: { caches, scans,
--- kept, professions, before }; `after` (KB of Lua memory, as the game counts it, every addon's)
--- and `finished` (the cycle got through; when not, the game frees the rest as it goes) come later.
function C.Temporary(done, rebuilt)
	local before = collectgarbage("count")
	-- the saved scans first: what to keep reads TSM's records, which are still parsed now
	local r = C.Run()
	local n = 0
	local function clear(f, ...)
		if type(f) == "function" and pcall(f, ...) then n = n + 1 end
	end
	clear(CH.Prices and CH.Prices.ClearCache)
	clear(CH.Depth and CH.Depth.Forget)
	clear(CH.Demand and CH.Demand.Clear)
	clear(CH.Forecast and CH.Forecast.Clear)
	clear(CH.Par and CH.Par.Clear)
	clear(CH.Next and CH.Next.ClearAlternatives)
	clear(CH.Groups and CH.Groups.ResetTSM)
	clear(CH.TradingUI and CH.TradingUI.ClearPlanCache)
	clear(CH.Scan and CH.Scan.ClearCrafted)
	clear(CH.Orders and CH.Orders.Invalidate)
	clear(CH.ScanUI and CH.ScanUI.InvalidateRows)
	if CH.AdvisorUI and CH.AdvisorUI.ClearCaches then
		local ok, k = pcall(CH.AdvisorUI.ClearCaches)
		if ok then n = n + (tonumber(k) or 1) end
	end
	local L = CH.Ledger
	clear(L and L.ClearStats)
	r.caches, r.before = n, before
	local clock = debugprofilestop or function() return 0 end
	local frames = 0
	local function finish(finished)
		r.after, r.finished, r.frames = collectgarbage("count"), finished, frames
		if done then done(r) end
		-- TSM's records come back in the background, so the next Dashboard isn't a cold one
		if L and L.Available and L.WarmAll and L.Available() then pcall(L.WarmAll, rebuilt)
		elseif rebuilt then rebuilt() end
	end
	local function step()
		frames = frames + 1
		local t0 = clock()
		repeat
			if collectgarbage("step", 16) then return finish(true) end
		until clock() - t0 >= ((L and L.FRAME_MS) or 6)
		if frames >= C.GC_FRAMES or not C_Timer then return finish(false) end
		C_Timer.After(0, step)
	end
	if C_Timer then C_Timer.After(0, step) else step() end
	return r
end

local function mb(kb) return string.format("%.1f MB", (kb or 0) / 1024) end

--- What a cleanup did, as one chat line.
function C.ReportText(r)
	local msg = string.format("cleanup: let go of %d caches (they rebuild when needed) and %d item scans nothing uses (they come back the next time the AH shows them), %d scans kept. Addon memory is %s, down from %s%s.",
		r.caches, r.scans, r.kept, mb(r.after), mb(r.before), r.finished and "" or "; the game frees the rest as it goes")
	if r.professions[1] then msg = msg .. " Dropped saved data for professions this character no longer has: " .. table.concat(r.professions, ", ") .. "." end
	return msg .. " Your queue, settings, crafting records and history are untouched."
end

--- /aiq cleanup: runs it and says what it did once the memory is measured (a moment later).
function C.Report(done)
	return C.Temporary(function(r)
		CH.Print(C.ReportText(r))
		if done then done(r) end
	end)
end

-- Old history --------------------------------------------------------------------------------------
C.PRUNE_DAYS = 365 -- TSM's default for Clear Old Data

--- What pruning at `days` would remove, as one sentence, and the counts (Ledger.PruneHistory).
function C.PruneText(days, now)
	local p = CH.Ledger.PruneHistory(days, false, now)
	local cutDate = p.cut and date and date("%Y-%m-%d", p.cut * 86400) or "?"
	if p.days + p.worth + p.rivals == 0 then
		return string.format("Nothing in AuctionIQ's history is older than %d days.", days), p
	end
	return string.format("Remove AuctionIQ history older than %d days (before %s): %d days of sales totals, %d days of net worth and %d competition notes. Crafting records stay. This can't be undone.",
		days, cutDate, p.days, p.worth, p.rivals), p
end

--- Prune now, without asking (the confirm dialog calls this). Returns the counts removed.
function C.Prune(days, now)
	local p = CH.Ledger.PruneHistory(days, true, now)
	CH.Print(string.format("prune: removed %d days of sales totals, %d days of net worth and %d competition notes older than %d days.",
		p.days, p.worth, p.rivals, days))
	if CH.UI and CH.UI.IsShown and CH.UI.IsShown() then pcall(CH.UI.Refresh) end
	return p
end

--- Ask first: say what goes, and prune only on Remove. With no days, asks how many (365 to start).
function C.AskPrune(days)
	if not StaticPopupDialogs then return end
	StaticPopupDialogs.AUCTIONIQ_PRUNE_DAYS = StaticPopupDialogs.AUCTIONIQ_PRUNE_DAYS or {
		text = "AuctionIQ: remove history older than how many days?",
		button1 = CONTINUE or "Continue", button2 = CANCEL or "Cancel",
		hasEditBox = true, timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
		OnShow = function(self) local eb = self.editBox or self.EditBox; if eb then eb:SetText(tostring(C.PRUNE_DAYS)); eb:HighlightText() end end,
		OnAccept = function(self)
			local eb = self.editBox or self.EditBox
			local d = tonumber(eb and eb:GetText() or "")
			if d and d >= 1 then C_Timer.After(0, function() C.AskPrune(math.floor(d)) end)
			else CH.Print("prune: give a number of days, 1 or more.") end
		end,
		EditBoxOnEnterPressed = function(self) local p = self:GetParent(); StaticPopupDialogs.AUCTIONIQ_PRUNE_DAYS.OnAccept(p); p:Hide() end,
		EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	}
	if not days then StaticPopup_Show("AUCTIONIQ_PRUNE_DAYS"); return end
	local text, p = C.PruneText(days)
	if p.days + p.worth + p.rivals == 0 then CH.Print("prune: " .. text); return end
	StaticPopupDialogs.AUCTIONIQ_PRUNE = {
		text = "AuctionIQ: " .. text:gsub("%%", "%%%%"),
		button1 = REMOVE or "Remove", button2 = CANCEL or "Cancel",
		OnAccept = function() C.Prune(days) end,
		timeout = 0, whileDead = true, hideOnEscape = true, showAlert = true, preferredIndex = 3,
	}
	StaticPopup_Show("AUCTIONIQ_PRUNE")
end

CH.On("PLAYER_LOGOUT", function() if CH.db then pcall(C.Run) end end)
