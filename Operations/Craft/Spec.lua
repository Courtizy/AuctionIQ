-- Specialization trees: reads the ranks you have, works out what each node gives a recipe (from the
-- node data in Professions/AuctionIQ_<Profession>/Spec.lua, built from Blizzard's game tables), and the stats a different set of ranks would give.
local _, CH = ...

local S = {}
CH.Spec = S

local STAT_KEYS = { skill = "skill", multicraft = "multicraft", resourcefulness = "resourcefulness",
	ingenuity = "ingenuity", craftingspeed = "craftingspeed" }
-- perk bonuses are given in percent
local EXTRA_KEYS = { additionalitemscraftedwithmulticraft = "mcExtra", reagentssavedfromresourcefulness = "resExtra",
	ingenuityrefundincrease = "refundExtra", reduceconcentrationcost = "concReduce" }

function S.Data(professionID) return CH.SpecData and CH.SpecData[professionID] end

-- Each profession's tree (and Enchanting's scrolls) is its own addon, AuctionIQ_<Profession>, loaded
-- on demand: only the professions this character has are loaded.
S.ADDONS = { [171] = "Alchemy", [164] = "Blacksmithing", [333] = "Enchanting", [202] = "Engineering",
	[773] = "Inscription", [755] = "Jewelcrafting", [165] = "Leatherworking", [197] = "Tailoring" }
S.loaded = {}

--- Load the data addons for this character's professions. Returns the names loaded now.
function S.LoadData()
	local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
	if not (load and GetProfessions and GetProfessionInfo) then return {} end
	local out = {}
	local slots = { GetProfessions() }
	for k = 1, select("#", GetProfessions()) do
		local i = slots[k]
		local line = i and select(7, GetProfessionInfo(i))
		local name = line and S.ADDONS[line]
		if name and not S.loaded[name] then
			local ok, loaded = pcall(load, "AuctionIQ_" .. name)
			if ok and loaded then S.loaded[name] = true; out[#out + 1] = name end
		end
	end
	return out
end
CH.On("PLAYER_LOGIN", function() S.LoadData() end)
CH.On("SKILL_LINES_CHANGED", function() S.LoadData() end)
CH.On("TRADE_SKILL_SHOW", function() S.LoadData() end)

local function nodeName(configID, nodeID)
	local ok, info = pcall(C_Traits.GetNodeInfo, configID, nodeID)
	if not ok or not info then return nil end
	local entry = info.entryIDs and info.entryIDs[1] and C_Traits.GetEntryInfo(configID, info.entryIDs[1])
	local def = entry and entry.definitionID and C_Traits.GetDefinitionInfo(entry.definitionID)
	return def and (def.overrideName or def.name), info
end

--- Reads the open profession's tree into a plain table we can save and simulate on:
--- { unspent, nodes = { [nodeID] = { name, rank, max, parent, available, perks = { [perkID] = threshold } } } }
--- rank is -1 for a node not yet unlocked, 0 for unlocked with no points, up to max.
function S.Read(professionID)
	local data = S.Data(professionID)
	if not data or not C_ProfSpecs or not C_Traits then return nil end
	local configID = C_ProfSpecs.GetConfigIDForSkillLine(professionID)
	if not configID or configID == 0 then return nil end
	local tree = { at = time(), nodes = {}, unspent = 0 }
	local cur = C_ProfSpecs.GetCurrencyInfoForSkillLine and C_ProfSpecs.GetCurrencyInfoForSkillLine(professionID)
	tree.unspent = cur and cur.numAvailable or 0
	tree.currency = cur and cur.currencyName
	for perkID, n in pairs(data.nodes) do
		if n.base then
			local name, info = nodeName(configID, perkID)
			local node = tree.nodes[perkID] or { perks = {} }
			tree.nodes[perkID] = node
			node.name = name or ("Node " .. perkID)
			node.max = n.maxRank
			node.rank = info and info.activeRank and (info.activeRank - 1) or -1
			node.available = info and (info.activeRank or 0) > 0 or (info and info.meetsEdgeRequirements) or false
		end
	end
	for perkID, n in pairs(data.nodes) do
		if not n.base and tree.nodes[n.nodeID] then
			local ok, threshold = pcall(C_ProfSpecs.GetUnlockRankForPerk, perkID)
			tree.nodes[n.nodeID].perks[perkID] = ok and threshold or n.unlock or 0
		end
	end
	-- parents, so a plan unlocks a node only after the one above it; and the trees' layout as the game
	-- draws them (each tab its own tree: position, icon, links), for the Paths tab
	tree.tabs, tree.layout = {}, {}
	if C_ProfSpecs.GetSpecTabIDsForSkillLine then
		local function walk(pathID, parent, tab, guard)
			if guard > 20 then return end
			if tree.nodes[pathID] then tree.nodes[pathID].parent = parent end
			local name, info = nodeName(configID, pathID)
			local icon
			if info and info.entryIDs and info.entryIDs[1] then
				local entry = C_Traits.GetEntryInfo(configID, info.entryIDs[1])
				local def = entry and entry.definitionID and C_Traits.GetDefinitionInfo(entry.definitionID)
				icon = def and (def.overrideIcon or (def.spellID and C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(def.spellID)))
			end
			local n = tree.nodes[pathID]
			tree.layout[pathID] = { x = info and info.posX or 0, y = info and info.posY or 0, icon = icon, parent = parent,
				name = (n and n.name) or name or ("Node " .. pathID), tab = tab.id,
				rank = n and n.rank or (info and info.activeRank and info.activeRank - 1) or -1,
				max = n and n.max or (info and info.maxRanks and math.max(0, info.maxRanks - 1)) or 0 }
			table.insert(tab.nodes, pathID)
			for _, child in ipairs(C_ProfSpecs.GetChildrenForPath(pathID) or {}) do walk(child, pathID, tab, guard + 1) end
		end
		for _, tabID in ipairs(C_ProfSpecs.GetSpecTabIDsForSkillLine(professionID) or {}) do
			local ok, ti = pcall(C_ProfSpecs.GetTabInfo or function() end, tabID)
			local tab = { id = tabID, name = ok and ti and ti.name or nil, nodes = {} }
			local root = C_ProfSpecs.GetRootPathForTab(tabID)
			if root then walk(root, nil, tab, 0) end
			tab.name = tab.name or (tree.layout[root or 0] and tree.layout[root].name) or ("Tab " .. tabID)
			table.insert(tree.tabs, tab)
		end
	end
	return tree
end

--- Ranks as { [nodeID] = rank } from a tree.
function S.Ranks(tree)
	local r = {}
	for id, n in pairs(tree and tree.nodes or {}) do r[id] = n.rank end
	return r
end

--- What the tree gives one recipe at these ranks: skill and stat ratings plus perk extras.
function S.RecipeStats(professionID, tree, ranks, recipeID)
	local data = S.Data(professionID)
	local out = CH.Stats.New()
	if not data or not tree then return out end
	for _, perkID in ipairs(data.recipes[recipeID] or {}) do
		local n = data.nodes[perkID]
		local node = n and tree.nodes[n.nodeID]
		local rank = node and (ranks[n.nodeID] or node.rank) or -1
		local times
		if n and n.base then
			times = math.max(0, rank)
		elseif node then
			times = (rank >= 0 and rank >= (node.perks[perkID] or 0)) and 1 or 0
		end
		if times and times > 0 then
			for stat, amount in pairs(n.stats or {}) do
				if STAT_KEYS[stat] then
					out[stat] = out[stat] + amount * times
				elseif EXTRA_KEYS[stat] then
					local k = EXTRA_KEYS[stat]
					out[k] = out[k] + amount / 100 * times
				end
			end
		end
	end
	return out
end

--- Change in a recipe's stats if the tree had these ranks instead of the current ones.
function S.Delta(professionID, tree, ranks, recipeID)
	local now = S.RecipeStats(professionID, tree, S.Ranks(tree), recipeID)
	local sim = S.RecipeStats(professionID, tree, ranks, recipeID)
	return CH.Stats.Diff(sim, now)
end

--- Recipes a node touches.
function S.NodeRecipes(professionID, nodeID)
	local data = S.Data(professionID)
	local out = {}
	if not data then return out end
	for recipeID, perks in pairs(data.recipes) do
		for _, perkID in ipairs(perks) do
			local n = data.nodes[perkID]
			if n and n.nodeID == nodeID then out[recipeID] = true; break end
		end
	end
	return out
end

--- What a node's perks give, as short text ("+30 Multicraft", "+5% Ingenuity refund").
function S.PerkText(professionID, perkID)
	local data = S.Data(professionID)
	local n = data and data.nodes[perkID]
	local parts = {}
	local LABEL = { skill = "skill", multicraft = "Multicraft", resourcefulness = "Resourcefulness", ingenuity = "Ingenuity",
		craftingspeed = "% crafting speed", additionalitemscraftedwithmulticraft = "% more Multicraft items",
		reagentssavedfromresourcefulness = "% more saved by Resourcefulness", ingenuityrefundincrease = "% more Ingenuity refund",
		reduceconcentrationcost = "% less Concentration", unlockreagentslot = " reagent slot unlocked" }
	for stat, amount in pairs(n and n.stats or {}) do
		local label = LABEL[stat] or stat
		if label:sub(1, 1) == "%" or label:sub(1, 1) == " " then
			table.insert(parts, "+" .. amount .. label)
		else
			table.insert(parts, "+" .. amount .. " " .. label)
		end
	end
	table.sort(parts)
	if #parts == 0 and n and n.text then return n.text end
	return table.concat(parts, ", ")
end

--- A gathering stat (Disenchanting skill) at these ranks, from the nodes under the given paths:
--- a path counts its stat per point, a perk once it's unlocked.
function S.GatherStat(professionID, tree, ranks, paths, stat)
	local data = S.Data(professionID)
	local total = 0
	if not data or not tree then return 0 end
	for perkID, n in pairs(data.nodes) do
		local amount = n.stats and n.stats[stat]
		local node = tree.nodes[n.nodeID]
		if amount and paths[n.nodeID] and node then
			local rank = ranks[n.nodeID] or node.rank or -1
			if n.base then
				total = total + amount * math.max(0, rank)
			elseif rank >= 0 and rank >= (node.perks[perkID] or n.unlock or 0) then
				total = total + amount
			end
		end
	end
	return total
end

--- Saves the tree with the character's profession, so plans work later and for alts.
function S.Record(professionID)
	local tree = S.Read(professionID)
	if not tree then return nil end
	local p = CH.Me().professions[professionID]
	if p then p.spec = tree end
	return tree
end

local cache = {}
CH.On("TRAIT_NODE_CHANGED", function() wipe(cache) end)
CH.On("TRAIT_TREE_CURRENCY_INFO_UPDATED", function() wipe(cache) end)
CH.On("TRADE_SKILL_CLOSE", function() wipe(cache) end)

--- The tree for this character's profession: freshly read when the window is open (kept for a few
--- seconds, since a recipe scan asks for it once per recipe), else the saved one.
function S.Tree(professionID)
	local c = cache[professionID]
	if c and GetTime() - c.at < 10 then return c.tree end
	local tree = S.Read(professionID)
	if tree then
		cache[professionID] = { tree = tree, at = GetTime() }
		local p = CH.Me().professions[professionID]
		if p then p.spec = tree end
		return tree
	end
	local p = CH.Me().professions[professionID]
	return p and p.spec
end
