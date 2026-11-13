-- Specialization paths, the part that's always loaded: the main recipe groups (Groups, Views and
-- the Ledger use them), disenchanting yields (recorded as you loot), the plan shown on the trees,
-- and loading the planner. The knowledge point planner itself, its presets, the tree view and the
-- Paths page are their own addon, AuctionIQ_Paths, loaded the first time the page opens (P.Load).
local _, CH = ...

local P = {}
CH.Paths = P
local SYNONYMS = { pots = "potion", pot = "potion", gems = "gem", inks = "ink", enchants = "enchant", oils = "oil",
	phials = "phial", flasks = "flask", rings = "ring", necks = "neck", necklaces = "neck", glyphs = "glyph",
	elixirs = "elixir", cauldrons = "cauldron", runes = "rune", contracts = "contract", treatises = "treatise",
	transmutes = "transmute", transmutation = "transmute", wands = "wand", rods = "rod", vantus = "vantus" }
local EVERYTHING = { money = true, gold = true, profit = true, everything = true, anything = true, all = true, best = true }

local function words(text)
	local out = {}
	for word in string.gmatch(string.lower(text or ""), "[%a']+") do
		local w = SYNONYMS[word] or word
		if #w > 3 and w:sub(-3) == "ies" then w = w:sub(1, -4) .. "y"
		elseif #w > 3 and w:sub(-1) == "s" and w:sub(-2) ~= "ss" then w = w:sub(1, -2) end
		out[#out + 1] = w
	end
	return out
end
P.Words = words

P.EVERYTHING = EVERYTHING

-- Main groups for the picker, per profession, from the game's own Midnight recipe categories
-- (checked against Blizzard's TradeSkillCategory table). Matched against a recipe's categories,
-- then its name; the first match wins, so "Armor Kits" comes before "Armor".
local MAIN = {
	[2906] = { -- Alchemy
		{ "Potions", { "potion", "tonic", "draught", "serum", "tincture" } },
		{ "Flasks & Phials", { "flask", "phial" } },
		{ "Elixirs", { "elixir" } },
		{ "Transmutations", { "transmut" } },
		{ "Oils", { "oil" } },
		{ "House Decor", { "decor", "house", "furnish", "housing" } },
	},
	[2907] = { -- Blacksmithing
		{ "Weapons", { "weapon" } },
		{ "Armor", { "armor", "plate" } },
		{ "Profession Gear", { "profession" } },
		{ "Smelting & Stone", { "smelt", "stonework" } },
		{ "House Decor", { "decor", "house" } },
	},
	[2909] = { -- Enchanting
		{ "Enchants", { "enchant" } },
		{ "Illusions", { "glamour", "illusion" } },
		{ "Rods & Wands", { "rod", "wand" } },
		{ "Shattering", { "shatter" } },
		{ "House Decor", { "decor", "house" } },
	},
	[2910] = { -- Engineering
		{ "Equipment", { "equipment" } },
		{ "Tools & Accessories", { "tools and", "accessor" } },
		{ "Bits & Parts", { "bits", "parts", "cogwheel" } },
		{ "Bots", { "bots" } },
		{ "Guns", { "gun" } },
		{ "House Decor", { "decor", "house" } },
	},
	[2913] = { -- Inscription
		{ "Treatises", { "treatise" } },
		{ "Profession Gear", { "profession equipment" } },
		{ "Weapons & Trinkets", { "weapon", "trinket" } },
		{ "Contracts & Missives", { "contract", "stats", "rune" } },
		{ "Mysteries", { "myster" } },
		{ "House Decor", { "decor", "house" } },
	},
	[2914] = { -- Jewelcrafting
		{ "Gems", { "peridot", "lapis", "amethyst", "garnet", "diamond" } },
		{ "Jewelry", { "ring", "locket" } },
		{ "Profession Gear", { "couture" } },
		{ "Prospecting & Crushing", { "prospect", "crush" } },
		{ "Reagents", { "reagent" } },
		{ "House Decor", { "decor", "house" } },
	},
	[2915] = { -- Leatherworking
		{ "Armor Kits", { "armor kit" } },
		{ "Armor", { "armor" } },
		{ "Profession Gear", { "profession" } },
		{ "Reagents", { "reagent" } },
		{ "House Decor", { "decor", "house" } },
	},
	[2918] = { -- Tailoring
		{ "Garments", { "garment" } },
		{ "Profession Gear", { "profession" } },
		{ "Bags", { "bag" } },
		{ "Cloth & Spellthread", { "woven", "spellthread" } },
		{ "Wardrobe", { "wardrobe" } },
		{ "House Decor", { "decor", "house" } },
	},
}
P.MAIN = MAIN

--- The picker's main group for a category or recipe name ("Potions", "Flasks & Phials"...), or nil.
--- The finishing-reagent appendices ("Appendix I - Terms") are left to Other.
function P.MainGroup(text, prof)
	text = string.lower(text or "")
	if text:find("appendix", 1, true) then return nil end
	for _, g in ipairs(MAIN[prof or CH.OpenProfessionID() or 2906] or MAIN[2906]) do
		for _, k in ipairs(g[2]) do if text:find(k, 1, true) then return g[1] end end
	end
end
P.MAIN = MAIN

-- Gathering paths: trees that raise what you get from something other than a recipe. Enchanting's
-- Disenchanting tree raises your skill when disenchanting Midnight gear, which lifts the share of
-- rank 2 materials. Each line is a kind of gear, the path for it and what it breaks into.
local YIELD = {
	[2909] = { name = "Disenchanting", stat = "gatherskill", all = 107649,
		words = { "disenchant", "disenchanting", "de", "dust", "shard", "crystal" },
		lines = {
			{ key = "dust", path = 107648, items = { 243599, 243600 }, label = "Eversinging Dust", from = "uncommon gear", daily = 40 },
			{ key = "shard", path = 107647, items = { 243602, 243603 }, label = "Radiant Shard", from = "rare gear", daily = 8 },
			{ key = "crystal", path = 107646, items = { 243605, 243606 }, label = "Dawn Crystal", from = "epic gear", daily = 2 },
		} },
}
for _, y in pairs(YIELD) do
	y.paths = { [y.all] = true }
	for _, l in ipairs(y.lines) do y.paths[l.path] = true end
end
P.YIELD = YIELD

-- What your disenchanting really gives, recorded as you loot it: CH.db.yieldLog[prof][day] =
-- { [itemID] = n }. Loot counts when it comes out of an item (a disenchant), not off a mob.
local DAY, WINDOW = 86400, 14
local lineOf = {}
for prof, y in pairs(YIELD) do
	for _, l in ipairs(y.lines) do
		for q, id in ipairs(l.items) do lineOf[id] = { prof = prof, line = l, q = q } end
	end
end

local function yieldLog(prof)
	CH.db.yieldLog = CH.db.yieldLog or {}
	CH.db.yieldLog[prof] = CH.db.yieldLog[prof] or {}
	return CH.db.yieldLog[prof]
end

--- Record one loot window's gathering materials (called on LOOT_OPENED).
function P.RecordLoot(now)
	if not (GetNumLootItems and GetLootSlotLink) then return end
	now = now or time()
	local day = math.floor(now / DAY)
	for slot = 1, GetNumLootItems() or 0 do
		local link = GetLootSlotLink(slot)
		local id = link and tonumber(link:match("item:(%d+)"))
		local hit = id and lineOf[id]
		local fromItem = false
		if hit and GetLootSourceInfo then
			local guid = GetLootSourceInfo(slot)
			fromItem = type(guid) == "string" and guid:find("^Item%-") ~= nil
		end
		if hit and fromItem then
			local qty = select(3, GetLootSlotInfo(slot)) or 1
			local log = yieldLog(hit.prof)
			log[day] = log[day] or {}
			log[day][id] = (log[day][id] or 0) + qty
		end
	end
	-- keep a month
	for prof in pairs(YIELD) do
		local log = yieldLog(prof)
		for d in pairs(log) do if d < day - 30 then log[d] = nil end end
	end
end
CH.On("LOOT_OPENED", function() P.RecordLoot() end)

--- What you really gathered over the last two weeks: { [key] = { n = per day, share = rank 2 share } },
--- the days it covers, or nil when nothing is recorded.
function P.Observed(prof, now)
	local y = YIELD[prof]
	if not y then return nil end
	local today = math.floor((now or time()) / DAY)
	local first, totals = nil, {}
	for d, items in pairs(yieldLog(prof)) do
		if d > today - WINDOW then
			first = math.min(first or d, d)
			for id, n in pairs(items) do totals[id] = (totals[id] or 0) + n end
		end
	end
	if not first then return nil end
	local days = today - first + 1
	local out = {}
	for _, l in ipairs(y.lines) do
		local n1, n2 = totals[l.items[1]] or 0, totals[l.items[2]] or 0
		out[l.key] = { n = (n1 + n2) / days, share = (n1 + n2) > 0 and n2 / (n1 + n2) or nil }
	end
	return out, days
end

--- How much of each gathering line you get a day: what /aiq de set, else what you've really
--- disenchanted over the last two weeks, else a starting guess. { [key] = n }, and where it came from.
function P.DailyYield(prof)
	local y = YIELD[prof]
	if not y then return {} end
	CH.db.settings.paths = CH.db.settings.paths or {}
	local set = CH.db.settings.paths[prof]
	if set and set.manual then return set, "set" end
	local seen, days = P.Observed(prof)
	local d = {}
	for _, l in ipairs(y.lines) do d[l.key] = seen and seen[l.key].n or l.daily end
	return d, seen and "seen" or "guess", days
end

--- Set what you disenchant a day by hand, or clear it (nil) to go back to what's recorded.
function P.SetDailyYield(prof, d)
	CH.db.settings.paths = CH.db.settings.paths or {}
	if d then d.manual = true end
	CH.db.settings.paths[prof] = d
end

--- The gathering path a goal means for this profession ("disenchanting", "dust"), or nil.
function P.Yield(prof, goal)
	local y = prof and YIELD[prof]
	if not y then return nil end
	for _, w in ipairs(words(goal)) do
		for _, k in ipairs(y.words) do if w == k or w:find("^disenchant") then return y end end
	end
end

--- Where a plan puts points: { [nodeID] = { from, to, steps = { step numbers } } }.
function P.Marks(plan)
	local out = {}
	for i, s in ipairs(plan and plan.steps or {}) do
		local m = out[s.node]
		if not m then m = { from = s.from, to = s.to, steps = {} }; out[s.node] = m end
		m.to = math.max(m.to, s.to)
		table.insert(m.steps, i)
	end
	return out
end

--- A plan, small enough to save: what it's for, gold a day and Concentration value now and with it,
--- its steps, and each recipe now and planned. Research, Professions compares them.
function P.Summary(plan)
	if not (plan and plan.prof and plan.final) then return nil end
	local me = CH.Me and CH.Me() or {}
	local out = { prof = plan.prof, profName = CH.SpecData and CH.SpecData[plan.prof] and CH.SpecData[plan.prof].name or tostring(plan.prof),
		label = plan.label or plan.goal, char = me.name, at = time(), budget = plan.budget, start = plan.start, final = plan.final,
		startConc = plan.startConc, finalConc = plan.finalConc, steps = {}, rows = {} }
	for _, s in ipairs(plan.steps or {}) do table.insert(out.steps, { name = s.name, node = s.node, from = s.from, to = s.to, cost = s.cost }) end
	for id, a in pairs(plan.startPer or {}) do
		local b = (plan.finalPer or {})[id] or a
		table.insert(out.rows, { id = id, name = a.name or b.name, fromQ = a.quality, toQ = b.quality, fromShare = a.share, toShare = b.share,
			fromProfit = a.profit, toProfit = b.profit, fromDay = a.perDay or 0, toDay = b.perDay or 0,
			fromConc = a.conc, toConc = b.conc, concQ = (a.concQ == b.concQ) and a.concQ or nil })
	end
	return out
end

-- The last plan made for each profession this session, shown on the trees; a summary of it is saved
-- per character and profession for Research.
P.current = {}
function P.SetCurrent(plan)
	if plan and plan.prof then
		P.current[plan.prof] = plan
		local sum = P.Summary(plan)
		if sum and CH.db then
			CH.db.plans = CH.db.plans or {}
			CH.db.plans[(sum.char or "?") .. ":" .. sum.prof] = sum
		end
	end
	if P.Changed then P.Changed(plan and plan.prof) end
end
function P.Current(prof) return prof and P.current[prof] end
function P.ClearCurrent(prof)
	if prof then P.current[prof] = nil end
	if P.Changed then P.Changed(prof) end
end


--- Step numbers for a node's badge: "1,3,4" or "1,2,3,+".
function P.StepText(steps)
	local t = {}
	for i, s in ipairs(steps) do
		if i > 3 then t[#t + 1] = "+"; break end
		t[#t + 1] = tostring(s)
	end
	return table.concat(t, ",")
end

--- Load the planner and the Paths page (AuctionIQ_Paths) if they aren't yet. True once loaded.
function P.Load()
	if CH.PathsUI then return true end
	local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
	if not load then return false end
	local ok, loaded, why = pcall(load, "AuctionIQ_Paths")
	if not (ok and loaded and CH.PathsUI) then
		if not P.loadWarned then
			P.loadWarned = true
			CH.Print("couldn't load the Paths page (AuctionIQ_Paths: " .. tostring(why or loaded or "missing") .. "). Restart WoW after updating, and check the addon is enabled.")
		end
		return false
	end
	return true
end
