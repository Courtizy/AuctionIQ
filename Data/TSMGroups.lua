-- /aiq groups: TSM groups built from the recipes AuctionIQ has read, as text TSM imports (Groups > Import).
--
-- One group per profession, a subgroup per heading in the profession window (Potions, Elixirs,
-- Flasks...), and a materials subgroup for the reagents worth tracking (herbs, enchanting
-- materials). Vendor reagents (vials, thread) stay out. TSM keeps an item in one group only, so
-- an item already placed is not repeated.
--
-- The text is TSM's plain list: "group:Alchemy`Potions,i:118,i:858,group:Alchemy`Herbs,i:2447".
-- A group's operations (Crafting restock, Auctioning) are set in TSM after the import.
local _, AuctionIQ = ...

local G = {}
AuctionIQ.TSMGroups = G

-- Trade Goods (class 7) subclasses worth a group of their own: what the profession buys or farms.
G.MATERIALS = { [9] = "Herbs", [12] = "Enchanting materials", [10] = "Elemental", [7] = "Metal and stone" }

local function itemClass(item)
	if not GetItemInfoInstant then return nil end
	local ok, _, _, _, _, _, classID, subClassID = pcall(GetItemInfoInstant, item)
	if ok then return classID, subClassID end
end

local function material(item)
	local classID, sub = itemClass(item)
	if classID == 7 then return G.MATERIALS[sub] end
end

--- Groups for one profession: list of { path, items = { itemID... } }, in the profession window's
--- heading order, materials last.
function G.Build(prof, recipes)
	local out, byPath, seen = {}, {}, {}
	local function add(path, item)
		if not item or seen[item] then return end
		seen[item] = true
		local g = byPath[path]
		if not g then g = { path = path, items = {} }; byPath[path] = g; out[#out + 1] = g end
		g.items[#g.items + 1] = item
	end
	for _, r in ipairs(recipes or {}) do
		add(prof .. (r.category and r.category ~= "" and ("`" .. r.category) or ""), r.item)
	end
	local mats = {}
	for _, r in ipairs(recipes or {}) do
		for _, g in ipairs(r.reagents or {}) do
			local kind = material(g.item)
			if kind then mats[#mats + 1] = { prof .. "`" .. kind, g.item } end
		end
	end
	for _, m in ipairs(mats) do add(m[1], m[2]) end
	return out
end

--- The import text for those groups.
function G.Text(groups)
	local parts = {}
	for _, g in ipairs(groups) do
		parts[#parts + 1] = "group:" .. g.path
		for _, item in ipairs(g.items) do parts[#parts + 1] = "i:" .. item end
	end
	return table.concat(parts, ",")
end

--- Import text for a profession you've opened on this character (nil when it hasn't been read).
function G.For(prof)
	local me = AuctionIQ.Me and AuctionIQ.Me()
	local p = me and me.crafting and me.crafting[prof]
	if not p or not p.recipes or #p.recipes == 0 then return nil end
	local groups = G.Build(prof, p.recipes)
	return G.Text(groups), groups
end
