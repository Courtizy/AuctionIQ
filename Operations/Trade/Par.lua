-- Stock targets (internally "par"): how many of each item you want on hand across your characters,
-- or a number you set. By default, enough to cover a week's demand (Settings: cover days) at a 90%
-- service level (Settings): demand over the cover is Poisson at your recent sales rate, and the
-- target is the smallest stock it stays under 90% of the time. 2 a day over 7 days: 19, not 14.
-- The Queue's Fill crafts up to the target; the Analytics Stock targets view and the briefing show
-- what's short.
local _, CH = ...

local Par = {}
CH.Par = Par

local DAY = 86400

local function store()
	CH.db.par = CH.db.par or { manual = {}, weeks = 1 }
	CH.db.par.manual = CH.db.par.manual or {}
	return CH.db.par
end

local soldCache, soldAt, soldFrom
--- Units sold per week per item over the last two weeks: { [itemID] = n }. Kept until the sales
--- change or five minutes pass (it's asked once per item in a list).
function Par.Weekly(now)
	now = now or time()
	local records = CH.Ledger and CH.Ledger.Available() and CH.Ledger.Records("Sales") or nil
	if soldCache and soldFrom == records and math.abs(now - soldAt) < 300 then return soldCache end
	local t = {}
	if records then
		local F = CH.Ledger.F
		local since = now - 14 * DAY
		for _, s in ipairs(records) do
			local id = s[F.id]
			if id and s[F.time] >= since then t[id] = (t[id] or 0) + s[F.quantity] / 2 end
		end
	end
	soldCache, soldAt, soldFrom = t, now, records
	return t
end

--- The target for an item, and whether you set it by hand. nil when it has neither.
function Par.Target(itemID, now)
	if not itemID then return nil end
	local s = store()
	if s.manual[itemID] then return s.manual[itemID], true end
	local w = Par.Weekly(now)[itemID]
	if w and w > 0 then
		local E = CH.Expect
		local cover = E and E.Setting("cover") or 7
		return CH.Prob.PoissonQuantile(w / 7 * cover, E and E.Setting("service") or 0.9), false
	end
	return nil
end

--- Set a target by hand (n), or go back to the automatic one (nil).
function Par.Set(itemID, n)
	store().manual[itemID] = n and math.max(0, math.floor(n)) or nil
	soldCache = nil
end

local heldCache
--- How many you hold across your characters and the warband bank (TSM's counts), else in reach now.
function Par.Held(itemID)
	if CH.Ledger and CH.Ledger.Available() then
		if not heldCache then
			heldCache = {}
			for _, e in ipairs(CH.Ledger.Inventory()) do if e.id then heldCache[e.id] = e.total end end
			C_Timer.After(5, function() heldCache = nil end)
		end
		return heldCache[itemID] or 0
	end
	if C_Item and C_Item.GetItemCount then return C_Item.GetItemCount(itemID, true, false, true, true) or 0 end
	return 0
end

function Par.Refresh() heldCache, soldCache = nil, nil end

--- Every item with a target: { id, weekly, target, manual, held, short, value (of the shortfall) }.
function Par.List(now)
	local seen, out = {}, {}
	local function add(id)
		if seen[id] then return end
		seen[id] = true
		local target, manual = Par.Target(id, now)
		if not target then return end
		local held = Par.Held(id)
		local short = math.max(0, target - held)
		local unit = CH.Prices.Get("chvalue", "i:" .. id)
		table.insert(out, { id = id, weekly = Par.Weekly(now)[id] or 0, target = target, manual = manual, held = held, short = short,
			value = unit and unit * CH.AH_CUT * short or 0 })
	end
	for id in pairs(store().manual) do add(id) end
	for id in pairs(Par.Weekly(now)) do add(id) end
	return out
end
