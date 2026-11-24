-- Per-profession facts the game's API doesn't give: recipes locked to a specialization, recipes that
-- need a camp crafting station, recipes bought with Merchant's Favor (and how much), and cooldown
-- recipes (the API gives the time left; the list is for the cooldown strip when a crafter's
-- profession hasn't been opened yet). Each profession's file registers one small table; only the
-- open profession's table is ever looked at. Data, not code, so the Summer 2027 professions update
-- is a data change.
--
-- ProfData.Register("Blacksmithing", {
--   spec    = { ["Recipe name"] = "Weaponsmith" },
--   station = { ["Recipe name"] = "Master Forge" },
--   favor   = { ["Recipe name"] = 120 },          -- Favor paid for the recipe
--   cooldown = { ["Recipe name"] = 47 },          -- hours
-- })
--
-- Merchant's Favor in gold: (Waylaid Crate price + fill mats at market) ÷ Favor returned, per crate
-- type, the cheapest one wins. Without crate prices only the Favor amount shows.
local _, AuctionIQ = ...

local PD = { by = {}, crates = {} }
AuctionIQ.ProfData = PD

function PD.Register(profession, t)
	PD.by[profession] = t
end

--- Crates: { item = Waylaid Crate item ID, favor = Favor it returns, fill = { { item, qty } } }.
function PD.RegisterCrate(c)
	PD.crates[#PD.crates + 1] = c
end

local function get(profession, kind, recipe)
	local t = profession and PD.by[profession]
	return t and t[kind] and t[kind][recipe] or nil
end

function PD.Spec(profession, recipe) return get(profession, "spec", recipe) end
function PD.Station(profession, recipe) return get(profession, "station", recipe) end
function PD.Favor(profession, recipe) return get(profession, "favor", recipe) end
function PD.Cooldown(profession, recipe) return get(profession, "cooldown", recipe) end

--- Gold (copper) per point of Favor from the cheapest crate with prices, and that crate. nil when no
--- crate has a price.
function PD.FavorRate()
	local best, crate
	for _, c in ipairs(PD.crates) do
		local price = AuctionIQ.Value.Market(c.item)
		local ok = price ~= nil and (c.favor or 0) > 0
		local total = price or 0
		for _, f in ipairs(c.fill or {}) do
			local m = AuctionIQ.Value.Market(f.item or f[1])
			if not m then ok = false break end
			total = total + m * (f.qty or f[2] or 1)
		end
		if ok then
			local rate = total / c.favor
			if not best or rate < best then best, crate = rate, c end
		end
	end
	return best, crate
end

--- A Favor recipe's cost: copper (or nil without crate prices) and the Favor amount.
function PD.FavorCost(profession, recipe)
	local favor = PD.Favor(profession, recipe)
	if not favor then return nil end
	local rate = PD.FavorRate()
	return rate and math.floor(rate * favor + 0.5) or nil, favor
end
