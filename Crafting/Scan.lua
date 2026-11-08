-- Recipe scan: runs the crafting advisor on every learned recipe of the open profession, with the
-- best reagents (and finishing reagents) for each, and ranks them. Spread over frames so the game
-- doesn't stall. Results are saved with the character, so the briefing and the path planner can use
-- them when the profession is closed.
local _, CH = ...

local Sc = {}
CH.Scan = Sc
Sc.models = {} -- [professionID][recipeID] = advisor model, for simulations this session

local PER_FRAME = 2
local running

local function settings() return CH.db.settings.scan end

local function eligible(info)
	return info and info.learned and not info.isRecraft and not info.isSalvageRecipe and not info.isGatheringRecipe
		and not info.isDummyRecipe
end

--- How many of an item you'd sell a day: what the region sells, up to your own cap.
function Sc.DailyUnits(itemID)
	local sold = CH.Advisor.SoldPerDay(itemID) or 0
	return math.min(sold, settings().dailyCap or 10)
end

--- A craft's accounts, saved with the scan for the item tooltip: reagents (with what each cost at
--- scan time), sales, Multicraft and Resourcefulness, per craft.
local function accounts(result, r)
	if not r or not r.profit then return nil end
	local reagents = {}
	local ok, e = pcall(CH.Queue.FromRow, result, r)
	for _, s in ipairs(ok and e and e.shop or {}) do
		local unit = CH.Prices.Get("chmat", "i:" .. s.itemID)
		table.insert(reagents, { itemID = s.itemID, n = s.n, rank = s.rank, tiers = s.tiers, cost = unit and unit * s.n })
	end
	local p = r.parts or {}
	return { quality = r.quality, concentration = r.concentration, avgConcentration = r.avgConcentration,
		made = result.made, unit = r.unit, sales = r.value, cost = r.cost, extraItems = (p.mc or 0) * (p.extraItems or 0),
		mcGold = p.mcGold, resGold = p.resGold, profit = r.profit, reagents = reagents }
end
Sc.Accounts = accounts

--- What one item costs to make with the best plain craft: reagents less what Resourcefulness saves,
--- spread over the items a craft makes on average (Multicraft included).
function Sc.CraftEach(b, made)
	if not b or not b.cost then return nil end
	local p = b.parts or {}
	local items = (made or 1) + (p.mc or 0) * (p.extraItems or 0)
	return (b.cost - (p.resGold or 0)) / math.max(items, 0.01)
end

--- Buy or craft: the cheapest listing of a scanned row's item against making it. Returns
--- { buy, craft, resell (your value after cut), flip (resell less buy), save (craft less buy) }.
function Sc.BuyOrCraft(r)
	local item = r and (r.item or r.concItem)
	local craft = r and r.craftEach
	if not item then return nil end
	local buy = CH.Prices.Get("chmat", "i:" .. item)
	local value = CH.Prices.Get("chvalue", "i:" .. item)
	local resell = value and value * CH.AH_CUT
	return { buy = buy, craft = craft, resell = resell, flip = buy and resell and resell - buy,
		save = buy and craft and craft - buy }
end

local function summary(result)
	local b, c = result.best, result.bestConc
	local item = b and b.item or (c and c.item)
	local units = Sc.DailyUnits(item)
	local made = result.made or 1
	local perDay = b and b.profit and b.profit > 0 and b.profit * units / made or 0
	-- With Concentration: as many crafts a day as sell, up to what a day's refill pays for.
	local avg = c and (c.avgConcentration or c.concentration)
	if c and c.profit and c.profit > 0 and avg and avg > 0 then
		local crafts = math.min(units / made, CH.CONC_PER_HOUR * 24 / avg)
		local plain = math.max(0, b and b.profit or 0)
		-- the Concentration crafts replace plain ones; any left sell without it
		local conc = crafts * c.profit + math.max(0, units / made - crafts) * plain
		if conc > perDay then perDay = conc end
	end
	return {
		recipeID = result.recipeID, name = result.name, made = made, tiers = result.model and result.model.maxQ,
		quality = b and b.quality, profit = b and b.profit, cost = b and b.cost, item = item,
		pct = b and b.cost and b.cost > 0 and b.profit / b.cost or nil,
		concQuality = c and c.quality, perPoint = c and c.perPoint, concProfit = c and c.profit, concentration = c and c.concentration,
		avgConcentration = avg, concItem = c and c.item,
		accounts = accounts(result, b), concAccounts = accounts(result, c),
		craftEach = Sc.CraftEach(b, made),
		soldPerDay = CH.Advisor.SoldPerDay(item),
		perDay = perDay,
	}
end
Sc.Summary = summary

--- The expansion a recipe comes from: its skill line ID and a short name such as "Khaz Algar".
function Sc.Expansion(recipeID)
	local ui = C_TradeSkillUI
	if not ui.GetTradeSkillLineForRecipe then return nil end
	local ok, line, lineName = pcall(ui.GetTradeSkillLineForRecipe, recipeID)
	if not ok or not line then return nil end
	for _, p in ipairs(ui.GetChildProfessionInfos and ui.GetChildProfessionInfos() or {}) do
		if p.professionID == line and p.expansionName and p.expansionName ~= "" then return line, p.expansionName end
	end
	-- "Khaz Algar Alchemy" -> "Khaz Algar"; the classic line is just "Alchemy"
	return line, lineName and lineName:match("^(.-)%s+%S+$") or "Classic"
end

--- The current expansion's skill line: the newest of the profession's lines, else the newest in rows.
function Sc.CurrentLine(rows)
	local ui, best = C_TradeSkillUI, nil
	for _, p in ipairs(ui.GetChildProfessionInfos and ui.GetChildProfessionInfos() or {}) do
		if p.professionID and (not best or p.professionID > best) then best = p.professionID end
	end
	if best then return best end
	for _, r in ipairs(rows or {}) do if r.line and (not best or r.line > best) then best = r.line end end
	return best
end

--- Recipe IDs worth scanning in the open profession.
function Sc.Recipes()
	local out = {}
	local ui = C_TradeSkillUI
	for _, id in ipairs(ui.GetAllRecipeIDs and ui.GetAllRecipeIDs() or {}) do
		if eligible(ui.GetRecipeInfo(id)) then table.insert(out, id) end
	end
	return out
end

--- Scan the open profession. onStep(done, total) while it runs, onDone(rows) at the end.
function Sc.Run(onStep, onDone)
	if running then return false end
	local profID = CH.OpenProfessionID()
	if not profID then return false end
	if not CH.Prices.Available() then return false end
	local ids = Sc.Recipes()
	local i, rows = 0, {}
	Sc.models[profID] = Sc.models[profID] or {}
	running = true
	local function step()
		for _ = 1, PER_FRAME do
			i = i + 1
			local id = ids[i]
			if not id then
				running = false
				table.sort(rows, function(a, b) return (a.profit or -math.huge) > (b.profit or -math.huge) end)
				local p = CH.Me().professions[profID]
				if p then p.scan = { at = time(), rows = rows, currentLine = Sc.CurrentLine(rows) } end
				if onDone then onDone(rows) end
				return
			end
			local ok, model = pcall(CH.Advisor.Measure, id, { professionID = profID })
			if ok and model then
				Sc.models[profID][id] = model
				local ok2, result = pcall(CH.Advisor.Evaluate, model)
				if ok2 and result and (result.best or result.bestConc) then
					local row = summary(result)
					row.line, row.expansion = Sc.Expansion(id)
					table.insert(rows, row)
				end
			end
		end
		if onStep then onStep(i, #ids) end
		C_Timer.After(0, step)
	end
	step()
	return true
end

function Sc.IsRunning() return running end

--- The saved scan for a profession on this character.
function Sc.Results(profID)
	local p = profID and CH.Me().professions[profID]
	return p and p.scan
end

--- How many times you can make a scanned recipe now from what you own (bags, bank, reagent bank,
--- warband bank), with the reagents and finishing reagents the scan picked as best. With
--- Concentration it is also capped by the points you have. Returns plain, withConc, and the
--- reagent that runs out first for each (its item ID).
function Sc.Craftable(r, concNow)
	local function count(acc)
		if not acc or not acc.reagents or #acc.reagents == 0 then return nil end
		local n, short = math.huge, nil
		for _, rg in ipairs(acc.reagents) do
			local need = rg.n or 1
			if need > 0 then
				local have = C_Item and C_Item.GetItemCount and C_Item.GetItemCount(rg.itemID, true, false, true, true) or 0
				local k = math.floor(have / need)
				if k < n then n, short = k, rg.itemID end
			end
		end
		return n == math.huge and 0 or n, short
	end
	local plain, plainShort = count(r.accounts)
	local conc, concShort = count(r.concAccounts)
	if conc and r.concentration and r.concentration > 0 and concNow then
		local byPoints = math.floor(concNow / r.concentration)
		if byPoints < conc then conc, concShort = byPoints, "concentration" end
	end
	return plain, conc, plainShort, concShort
end

--- Best n recipes by profit from the saved scan.
function Sc.Top(profID, n)
	local s = Sc.Results(profID)
	local out = {}
	for _, r in ipairs(s and s.rows or {}) do
		if r.profit and r.profit > 0 then table.insert(out, r) end
		if #out >= n then break end
	end
	return out
end

--- Sorts scan rows by a column: profit, pct, concProfit, perPoint, perDay or soldPerDay.
function Sc.Sort(rows, key)
	table.sort(rows, function(a, b) return (a[key] or -math.huge) > (b[key] or -math.huge) end)
	return rows
end

--- A model for a recipe: from this session's scan, else measured now (profession must be open).
function Sc.Model(profID, recipeID)
	local m = Sc.models[profID] and Sc.models[profID][recipeID]
	if m then return m end
	local ok, model = pcall(CH.Advisor.Measure, recipeID, { professionID = profID })
	if ok and model then
		Sc.models[profID] = Sc.models[profID] or {}
		Sc.models[profID][recipeID] = model
		return model
	end
end

CH.On("TRADE_SKILL_CLOSE", function() wipe(Sc.models) end)
