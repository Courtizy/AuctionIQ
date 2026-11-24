-- What one craft of a recipe earns, three ways, and how many to make.
--
-- Cost per craft, in three columns that differ only in what the reagents cost:
--   Market  reagents at today's market price
--   Paid    reagents at what you paid (Value.Paid: bought, crafted, or farmed at market or zero)
--   Full    Paid; the recipe's own cost stays out of it (once bought it's sunk, and spreading it per
--           craft would rank on a guess about future crafts). Payback is its own line instead:
--           what the recipe cost in gold (or Merchant's Favor, valued through crates) and how many
--           crafts at today's profit pay it back.
-- All three take off the same AH cut and expected relist cost, so they compare like for like.
-- The recipe list ranks on Full.
--
-- Relist cost is the deposits you expect to lose to expiries before one sells: deposit per listing
-- times (1 / sale rate − 1), at most 5 relists. The deposit is an estimate (15% of the vendor price
-- per 12 hours, 24-hour listings), shown as "est.". Without a sale rate it is 0 and says so.
--
-- Make N counts crafts. It's the smallest of:
--   restock     TSM restock max minus what you hold, when the item is in a TSM group
--   sales       what's likely to sell before your next session; with no sales history yet, 2
--   afford      crafts you have reagents for plus crafts your gold buys at market
-- and 0 when a craft doesn't make money. The reason names whichever one set the number.
local _, AuctionIQ = ...
local Value = AuctionIQ.Value

local Craft = { DEPOSIT_RATE = 0.15, LISTING_HOURS = 24, MAX_RELISTS = 5, TRY = 2 }
AuctionIQ.Craft = Craft

local function settings()
	local s = AuctionIQ.db and AuctionIQ.db.settings
	return s and s.costs or {}
end

-- Where you sell: your faction's auction house takes 5%, the neutral one (Blackwater on Forever) 15%.
Craft.HOUSES = { faction = { cut = 0.05, label = "Faction AH" }, neutral = { cut = 0.15, label = "Neutral AH" } }

--- Which house the numbers assume: "faction" or "neutral" (Settings, also switched on the Craft tab).
function Craft.House()
	return settings().house == "neutral" and "neutral" or "faction"
end

--- The AH's cut on a sale for that house.
function Craft.Cut()
	return Craft.HOUSES[Craft.House()].cut
end

--- Expected deposits lost per item sold, and whether it's known ("est." when estimated, nil when
--- there's no sale rate to go on).
function Craft.Relist(item)
	local vendor = Value.Vendor(Value.ID(item)) or 0
	local deposit = math.floor(vendor * Craft.DEPOSIT_RATE * Craft.LISTING_HOURS / 12 + 0.5)
	local rate = Value.SaleRate(item)
	if not rate or rate <= 0 then return 0, nil end
	local relists = math.min(1 / rate - 1, Craft.MAX_RELISTS)
	return math.floor(deposit * relists + 0.5), "est."
end

--- What the recipe cost: copper (nil when only Favor is known or nothing is), and Favor paid.
--- A cost recorded in Settings wins; else the profession data's Favor price, valued through crates.
function Craft.RecipeCost(r)
	local gold = settings().recipeCost and settings().recipeCost[r.key]
	if gold and gold > 0 then return gold, nil end
	local PD = AuctionIQ.ProfData
	if PD then return PD.FavorCost(r.profession, r.name) end
	return nil
end

--- The numbers for one craft of r. Fields (copper): sells (each), makes, gross, cut, relist,
--- recipeCost, recipeFavor, paybackCrafts, reagents = { market, paid, full }, profit = { market, paid, full }, coverage (0..1),
--- lines (per reagent: { item, qty, market, paid, how }), missing (reagents with no price), priced.
function Craft.Cost(r)
	local c = { makes = r.makes or 1, lines = {}, missing = 0, reagents = { market = 0, paid = 0 } }
	local list = {}
	for _, g in ipairs(r.reagents or {}) do
		local m = Value.Market(g.item)
		local p, how = Value.Paid(g.item)
		c.lines[#c.lines + 1] = { item = g.item, qty = g.qty, name = g.name, market = m, paid = p, how = how }
		if not m or not p then c.missing = c.missing + 1 end
		c.reagents.market = c.reagents.market + (m or 0) * g.qty
		c.reagents.paid = c.reagents.paid + (p or 0) * g.qty
		list[#list + 1] = { item = g.item, qty = g.qty }
	end
	local _, cov = Value.Coverage(list)
	c.coverage = cov
	local sells, src = Value.Market(r.item)
	c.sells, c.source = sells, src
	c.priced = sells ~= nil and src ~= "vendor" and c.missing == 0
	c.gross = (sells or 0) * c.makes
	c.cut = math.floor(c.gross * Craft.Cut() + 0.5)
	local relist, est = Craft.Relist(r.item)
	c.relist, c.relistKnown = math.floor(relist * c.makes + 0.5), est
	c.fees = c.cut + c.relist
	c.recipeCost, c.recipeFavor = Craft.RecipeCost(r)
	c.reagents.full = c.reagents.paid
	local net = c.gross - c.fees
	c.profit = {
		market = net - c.reagents.market,
		paid = net - c.reagents.paid,
		full = net - c.reagents.paid,
	}
	if c.recipeCost and c.profit.full > 0 then c.paybackCrafts = math.ceil(c.recipeCost / c.profit.full) end
	return c
end

local function held(item)
	local get = (C_Item and C_Item.GetItemCount) or GetItemCount
	if not get then return 0 end
	local ok, n = pcall(get, item, true)
	return ok and n or 0
end

--- How many crafts to make: { n, reason, items, restock, have }. reason is one of "unpriced",
--- "loss", "restock", "stocked", "sales", "afford".
function Craft.MakeN(r, c)
	c = c or Craft.Cost(r)
	local makes = c.makes > 0 and c.makes or 1
	local out = { have = held(r.item) }
	local PD = AuctionIQ.ProfData
	out.station = PD and PD.Station(r.profession, r.name)
	out.spec = PD and PD.Spec(r.profession, r.name)
	if not c.priced then out.n, out.reason = 0, "unpriced"; return out end
	if c.profit.full <= 0 then out.n, out.reason = 0, "loss"; return out end
	local caps = {}
	local rs = Value.Restock(r.item)
	if rs then
		out.restock = rs.max
		local gap = math.max(0, rs.max - out.have)
		caps[#caps + 1] = { math.floor(gap / makes), gap > 0 and "restock" or "stocked" }
	end
	caps[#caps + 1] = { Craft.TRY, "sales" }
	local per = c.reagents.market
	local afford = (r.canMake or 0) + (per > 0 and math.floor((GetMoney and GetMoney() or 0) / per) or 99)
	caps[#caps + 1] = { afford, "afford" }
	local best
	for _, cap in ipairs(caps) do
		if not best or cap[1] < best[1] then best = cap end
	end
	out.n, out.reason = best[1], best[2]
	out.items = math.floor(out.n * makes + 0.5)
	return out
end

--- One line saying what set Make N, for under the number.
function Craft.Reason(m, makes)
	local unit = (makes or 1) > 1 and " crafts" or ""
	local parts = {}
	if m.spec then parts[#parts + 1] = m.spec .. " only" end
	if m.station then parts[#parts + 1] = "needs a " .. m.station end
	if m.restock then parts[#parts + 1] = ("TSM restock %d · have %d"):format(m.restock, m.have) end
	if m.reason == "unpriced" then parts[#parts + 1] = "no market price for this or a reagent yet"
	elseif m.reason == "loss" then parts[#parts + 1] = "doesn't make money at today's prices"
	elseif m.reason == "stocked" then parts[#parts + 1] = "already stocked"
	elseif m.reason == "restock" then parts[#parts + 1] = "restock sets it"
	elseif m.reason == "sales" then parts[#parts + 1] = ("no sales history yet, try %d%s"):format(m.n, unit)
	elseif m.reason == "afford" then parts[#parts + 1] = ("you can afford %d%s"):format(m.n, unit) end
	local line = table.concat(parts, " · ")
	return (line:gsub("^%l", string.upper))
end

--- Rows for the recipe list: { key, name, recipe, cost, make, profit (Full per craft, nil when
--- unpriced), n }.
function Craft.Rows(p)
	local rows = {}
	for _, r in ipairs(p and p.recipes or {}) do
		local c = Craft.Cost(r)
		local m = Craft.MakeN(r, c)
		rows[#rows + 1] = { key = r.key, name = r.name, recipe = r, cost = c, make = m,
			profit = c.priced and c.profit.full or nil, n = m.n, canMake = r.canMake or 0 }
	end
	return rows
end

--- Recipes below their TSM restock, across the given professions.
function Craft.BelowRestock(rows)
	local n = 0
	for _, row in ipairs(rows or {}) do
		if row.make.restock and row.make.have < row.make.restock then n = n + 1 end
	end
	return n
end
