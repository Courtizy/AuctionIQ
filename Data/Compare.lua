-- Price cross-check: the same item from three places, side by side.
--   AH scan   what the auction house showed you (Blizzard's live data, Scans.lua)
--   TSM       TSM's realm market value (dbmarket) and region average (dbregionmarketavg)
--   Oribos    Oribos Exchange's realm and region prices, read directly or through TSM
-- Realm prices are compared with each other; region prices are shown for reference.
local _, CH = ...

local C = { CHEAP = 0.85, PRICEY = 1.15, DISAGREE = 0.25, FRESH = 24 * 3600 }
CH.Compare = C

local function median(t)
	local s = {}
	for _, v in ipairs(t) do s[#s + 1] = v end
	table.sort(s)
	local n = #s
	if n == 0 then return nil end
	return n % 2 == 1 and s[(n + 1) / 2] or (s[n / 2] + s[n / 2 + 1]) / 2
end
C.Median = median

--- One item across the sources:
--- { ah, ahMin, ahAge, ahFresh, tsm, tsmRegion, oe, oeRegion, region, mid, spread, verdict, gap }.
--- mid is the middle of the realm prices, spread is (highest - lowest) / mid, gap is the AH scan
--- against TSM and Oribos (0.2 = 20% above). verdict: "cheap now", "pricey now", "disagree",
--- "agree", "one source" or "no prices".
function C.Row(id)
	local P = CH.Prices
	local scan = P.Market(id)
	local key = "i:" .. id
	local oe = P.Oribos(id)
	local r = {
		ah = scan and scan.market, ahMin = scan and scan.min, ahAge = scan and scan.age,
		tsm = P.Raw("dbmarket", id), tsmRegion = P.Raw("dbregionmarketavg", id),
		oe = (oe and oe.market) or P.Get("oerealm", key), oeRegion = (oe and oe.region) or P.Get("oeregion", key),
	}
	r.ahFresh = r.ah ~= nil and (r.ahAge or math.huge) <= C.FRESH
	r.region = r.tsmRegion or r.oeRegion
	local realm = {}
	if r.ahFresh then realm[#realm + 1] = r.ah end
	if r.tsm then realm[#realm + 1] = r.tsm end
	if r.oe then realm[#realm + 1] = r.oe end
	if not realm[1] and r.ah then realm[1] = r.ah end
	r.mid = median(realm)
	if not r.mid then r.verdict = "no prices"; return r end
	local lo, hi = math.huge, 0
	for _, v in ipairs(realm) do lo, hi = math.min(lo, v), math.max(hi, v) end
	r.spread = #realm > 1 and r.mid > 0 and (hi - lo) / r.mid or nil
	local others = {}
	if r.tsm then others[#others + 1] = r.tsm end
	if r.oe then others[#others + 1] = r.oe end
	local ref = median(others)
	if r.ahFresh and ref and ref > 0 then
		r.gap = r.ah / ref - 1
		if r.ah <= ref * C.CHEAP then r.verdict = "cheap now"
		elseif r.ah >= ref * C.PRICEY then r.verdict = "pricey now" end
	end
	if not r.verdict then
		if #realm < 2 then r.verdict = "one source"
		elseif r.tsm and r.oe and math.abs(r.tsm - r.oe) / math.max(r.tsm, r.oe) > C.DISAGREE then r.verdict = "disagree"
		else r.verdict = "agree" end
	end
	return r
end

--- Items worth checking: held, sold in the last 30 days, on the shopping list, or fully searched
--- at the AH in the last day. { [id] = held count }.
function C.Items(char, now)
	now = now or time()
	local ids = {}
	local L = CH.Ledger
	if L and L.Available and L.Available() then
		for _, e in ipairs(L.Inventory(nil, char)) do
			if e.id and not e.bound then ids[e.id] = (ids[e.id] or 0) + (e.total or 0) end
		end
		for _, r in ipairs(L.Records("Sales")) do if r.id and r.time >= now - 30 * 86400 then ids[r.id] = ids[r.id] or 0 end end
	end
	if CH.Queue and CH.Queue.ShoppingList then
		for _, s in ipairs((CH.Queue.ShoppingList())) do ids[s.itemID] = ids[s.itemID] or 0 end
	end
	for _, id in ipairs(CH.Scans.Items()) do
		local s = CH.Scans.Get(id)
		if s and s.full and s.age <= C.FRESH then ids[id] = ids[id] or 0 end
	end
	return ids
end
