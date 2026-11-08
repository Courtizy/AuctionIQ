-- What a crafted item is really worth to you: its price after the AH cut, less the deposits you
-- expect to lose to expiries before it sells and the cost of the gold sitting on the AH meanwhile.
--
--   p      chance one listing sells: your own sold and expired record as a Beta belief, starting
--          from the region's sale rate (TSM) and moving toward yours as evidence comes in
--   EV     = P*cut - D*(1-p)/p - P*cut*carry*days,   days = hours / (24*p)
--   D      deposit per unit: 15% of the vendor price per 12 hours listed
--
-- Settings (CH.db.settings.model): service (stock target service level), carry (gold a day it
-- costs to have gold tied up, 0.01 = 1%), cover (days of sales a stock target covers).
local _, CH = ...

local E = {}
CH.Expect = E

E.DEFAULTS = { service = 0.9, carry = 0.01, cover = 7 }
E.HOURS = { 12, 24, 48 }   -- operation durations 1, 2, 3
E.MIN_P = 0.05

function E.Setting(key)
	local m = CH.db and CH.db.settings and CH.db.settings.model
	local v = m and m[key]
	if v == nil then v = E.DEFAULTS[key] end
	return v
end

function E.Set(key, v)
	CH.db.settings.model = CH.db.settings.model or {}
	CH.db.settings.model[key] = v
end

--- The region's sale rate for an item from TSM, 0-1, or nil.
function E.RegionRate(id)
	if not TSM_API or not id then return nil end
	local ok, v = pcall(TSM_API.GetCustomPriceValue, "dbregionsalerate", "i:" .. id)
	if not ok or not v then return nil end
	return v <= 1 and v or v / 1000 -- TSM gives 0-1 or x1000
end

--- Chance one listing sells before it expires, and the belief behind it ({ mean, n, pUp, pDown }),
--- or nil when there is neither your record nor a region rate.
function E.SellChance(id)
	local sold, expired = 0, 0
	if CH.Ledger and CH.Ledger.Available() then sold, expired = CH.Ledger.SellThrough(id) end
	local prior = E.RegionRate(id)
	if not prior and sold + expired == 0 then return nil end
	local st = CH.Prob.SellThrough(sold, expired, prior or 0.5)
	return math.max(E.MIN_P, st.mean), st
end

--- The deposit for one unit listed `hours` hours (copper), from the vendor price.
function E.Deposit(id, hours)
	local sell = C_Item and C_Item.GetItemInfo and select(11, C_Item.GetItemInfo(id)) or 0
	return math.floor((sell or 0) * 0.15 * (hours or 24) / 12)
end

--- How long an item's own posting operation lists it, in hours.
function E.Hours(id)
	local op = CH.Groups and CH.Groups.Operation and CH.Groups.Operation(id)
	return E.HOURS[op and op.duration or 2] or 24
end

--- Expected gold from one unit priced at `price`: (ev, detail). detail = { gross, p, days, deposits,
--- carry, hours, belief }. Without any sale rate, ev is just the price after the cut.
function E.Value(id, price, hours)
	if not price then return nil end
	local gross = price * CH.AH_CUT
	local p, belief = E.SellChance(id)
	if not p then return gross, { gross = gross } end
	hours = hours or E.Hours(id)
	local days = hours / (24 * p)
	local deposits = E.Deposit(id, hours) * (1 - p) / p
	local carry = gross * E.Setting("carry") * days
	return gross - deposits - carry, { gross = gross, p = p, days = days, deposits = deposits, carry = carry, hours = hours, belief = belief }
end

--- The deposit you lost on an expired listing of `qty` units (an estimate: TSM doesn't record it).
function E.LostDeposit(id, qty)
	return E.Deposit(id, E.Hours(id)) * (qty or 1)
end
