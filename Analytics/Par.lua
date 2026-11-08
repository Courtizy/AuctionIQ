-- Stock targets (internally "par"): how many of each item you want on hand across your characters. By default a week of
-- what you actually sold (from TSM's sales), or a number you set. The Queue's Fill crafts up to the target,
-- the Analytics Stock targets view and the briefing show what's short.
local _, CH = ...

local Par = {}
CH.Par = Par

local DAY = 86400

local function store()
	CH.db.par = CH.db.par or { manual = {}, weeks = 1 }
	CH.db.par.manual = CH.db.par.manual or {}
	return CH.db.par
end

local soldCache, soldAt
--- Units sold per week per item over the last two weeks: { [itemID] = n }.
function Par.Weekly(now)
	now = now or time()
	if soldCache and soldAt == now then return soldCache end
	local t = {}
	if CH.Ledger and CH.Ledger.Available() then
		for _, s in ipairs(CH.Ledger.Records("Sales")) do
			if s.id and s.time >= now - 14 * DAY then t[s.id] = (t[s.id] or 0) + s.quantity / 2 end
		end
	end
	soldCache, soldAt = t, now
	return t
end

--- The target for an item, and whether you set it by hand. nil when it has neither.
function Par.Target(itemID, now)
	if not itemID then return nil end
	local s = store()
	if s.manual[itemID] then return s.manual[itemID], true end
	local w = Par.Weekly(now)[itemID]
	if w and w > 0 then return math.ceil(w * (s.weeks or 1)), false end
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
			value = unit and unit * short or 0 })
	end
	for id in pairs(store().manual) do add(id) end
	for id in pairs(Par.Weekly(now)) do add(id) end
	return out
end
