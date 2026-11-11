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

--- /aiq cleanup
function C.Report()
	local r = C.Run()
	local msg = string.format("cleanup: %d item scans nothing uses dropped (they come back the next time the AH shows them), %d kept.", r.scans, r.kept)
	if r.professions[1] then msg = msg .. " Dropped saved data for professions this character no longer has: " .. table.concat(r.professions, ", ") .. "." end
	CH.Print(msg)
	return r
end

CH.On("PLAYER_LOGOUT", function() if CH.db then pcall(C.Run) end end)
