-- Top gear: which profession tool and accessories to wear for a recipe. Tries every combination of
-- what's equipped and what's in your bags, works out the stats each gives, and re-runs the
-- advisor's numbers with them (like CraftSim's Top Gear).
local _, CH = ...

local G = {}
CH.Gear = G

local TOOL, GEAR = "INVTYPE_PROFESSION_TOOL", "INVTYPE_PROFESSION_GEAR"

local function profession()
	local ui = C_TradeSkillUI
	return ui.GetChildProfessionInfo and ui.GetChildProfessionInfo()
end

--- The open profession's gear slots: tool, accessory, accessory.
function G.Slots()
	local info = profession()
	local prof = info and (info.profession or info.parentProfessionID)
	return prof and C_TradeSkillUI.GetProfessionSlots and C_TradeSkillUI.GetProfessionSlots(prof) or {}
end

local function instant(link)
	if not C_Item or not C_Item.GetItemInfoInstant then return end
	local id, _, _, equipLoc, _, classID, subclassID = C_Item.GetItemInfoInstant(link)
	return id, equipLoc, classID, subclassID
end

-- Is this item gear for the open profession? Same subclass as what's equipped, else by name.
local function forProfession(link, slots)
	local _, equipLoc, classID, subclassID = instant(link)
	if equipLoc ~= TOOL and equipLoc ~= GEAR then return nil end
	for _, slot in ipairs(slots) do
		local worn = GetInventoryItemLink("player", slot)
		if worn then
			local _, _, _, sub = instant(worn)
			return sub == subclassID and equipLoc or nil
		end
	end
	local info = profession()
	local name = C_Item.GetItemSubClassInfo and C_Item.GetItemSubClassInfo(classID, subclassID)
	return (name and info and info.parentProfessionName == name) and equipLoc or nil
end

--- Everything you could wear: { tools = {...}, gear = {...} }, each { link, itemID, stats, slot or bag+bagSlot }.
function G.Candidates()
	local slots = G.Slots()
	local out = { tools = {}, gear = {}, slots = slots }
	if #slots == 0 then return out end
	local function add(link, where)
		local loc = forProfession(link, slots)
		if not loc then return end
		local c = { link = link, itemID = (instant(link)), stats = CH.Stats.FromItem(link) }
		for k, v in pairs(where) do c[k] = v end
		table.insert(loc == TOOL and out.tools or out.gear, c)
	end
	for i, slot in ipairs(slots) do
		local link = GetInventoryItemLink("player", slot)
		if link then add(link, { worn = slot, wornIndex = i }) end
	end
	if C_Container then
		for bag = 0, (NUM_TOTAL_EQUIPPED_BAG_SLOTS or 5) do
			for s = 1, C_Container.GetContainerNumSlots(bag) or 0 do
				local link = C_Container.GetContainerItemLink(bag, s)
				if link then add(link, { bag = bag, bagSlot = s }) end
			end
		end
	end
	return out
end

local function sum(items)
	local s = CH.Stats.New()
	for _, it in ipairs(items) do if it then CH.Stats.Add(s, it.stats) end end
	return s
end

--- Every set: one tool (or the worn one) and two different accessories.
function G.Sets(c)
	local tools = #c.tools > 0 and c.tools or { false }
	local gear = c.gear
	local sets = {}
	for _, t in ipairs(tools) do
		if #gear < 2 then
			table.insert(sets, { tool = t or nil, gear = { gear[1] } })
		else
			for i = 1, #gear do
				for j = i + 1, #gear do
					if gear[i].itemID ~= gear[j].itemID then -- profession accessories are unique-equipped
						table.insert(sets, { tool = t or nil, gear = { gear[i], gear[j] } })
					end
				end
			end
		end
	end
	return sets
end

local function worn(c)
	local w = {}
	for _, it in ipairs(c.tools) do if it.worn then table.insert(w, it) end end
	for _, it in ipairs(c.gear) do if it.worn then table.insert(w, it) end end
	return w
end

local function setItems(set)
	local t = { set.tool }
	for _, g in ipairs(set.gear) do table.insert(t, g) end
	return t
end

local function isWorn(set)
	for _, it in ipairs(setItems(set)) do if it and not it.worn then return false end end
	return true
end

--- Best set for a recipe model. mode "conc" ranks by gold per Concentration point, else by profit.
--- Returns { set, gain, result, current } or nil when there's nothing to compare.
function G.Best(model, mode, c, finishing)
	c = c or G.Candidates()
	local sets = G.Sets(c)
	if #sets <= 1 then return nil end
	local now = sum(worn(c))
	local function score(r)
		if mode == "conc" then return r.bestConc and r.bestConc.perPoint end
		return r.best and r.best.profit
	end
	local base = CH.Advisor.Evaluate(model, { sim = CH.Stats.New(), finishing = finishing })
	local baseScore = score(base)
	if not baseScore then return nil end
	local best, bestScore, bestResult = nil, baseScore, base
	for _, set in ipairs(sets) do
		if not isWorn(set) then
			if CH.Scan and CH.Scan.Yield then CH.Scan.Yield() end -- in the background: a set at a time
			local delta = CH.Stats.Diff(sum(setItems(set)), now)
			local t0 = debugprofilestop and debugprofilestop()
			local r = CH.Advisor.Evaluate(model, { sim = delta, finishing = finishing })
			if t0 and CH.MeasureAdd then CH.MeasureAdd("advisor: gear, one set", debugprofilestop() - t0) end
			local s = score(r)
			if s and s > bestScore + 1 then best, bestScore, bestResult = set, s, r end
		end
	end
	if not best then return { current = true } end
	return { set = best, gain = bestScore - baseScore, result = bestResult, mode = mode }
end

--- Short text: "Swap in Alchemist's Mixing Rod, Chemist's Hat".
function G.SwapText(set)
	local names = {}
	for _, it in ipairs(setItems(set)) do
		if it and not it.worn then table.insert(names, (C_Item.GetItemNameByID and C_Item.GetItemNameByID(it.itemID)) or it.link) end
	end
	return table.concat(names, ", ")
end

--- Put a set on. Out of combat only; each bag item goes into the slot it replaces.
function G.Equip(set, c)
	if InCombatLockdown and InCombatLockdown() then return false, "in combat" end
	c = c or G.Candidates()
	local slots = c.slots
	local function put(it, slot)
		if not it or it.worn == slot then return end
		if it.bag then
			C_Container.PickupContainerItem(it.bag, it.bagSlot)
		elseif it.worn then
			PickupInventoryItem(it.worn)
		end
		EquipCursorItem(slot)
	end
	put(set.tool, slots[1])
	put(set.gear[1], slots[2])
	put(set.gear[2], slots[3])
	return true
end
