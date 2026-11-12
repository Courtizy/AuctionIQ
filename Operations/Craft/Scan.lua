-- Recipe scan: runs the crafting advisor on every learned recipe of the open profession, with the
-- best reagents (and finishing reagents) for each, and ranks them. Spread over frames so the game
-- doesn't stall. Results are saved with the character, so the briefing and the path planner can use
-- them when the profession is closed.
local _, CH = ...

local Sc = {}
CH.Scan = Sc
Sc.models = {} -- [professionID][recipeID] = advisor model, for simulations this session

local PER_FRAME = 2  -- at least this many recipes a frame without a clock...
local BUDGET_MS = 6  -- ...and with one, more while the next recipe should still finish inside this
local running

local function settings() return CH.db.settings.scan end

local function eligible(info)
	return info and info.learned and not info.isRecraft and not info.isSalvageRecipe and not info.isGatheringRecipe
		and not info.isDummyRecipe
end

--- How many of an item you'd sell a day: your own sales on the days you had it listed, blended
--- with the region's figure (counted at most your cap) while your record is thin. See Demand.lua.
function Sc.DailyUnits(itemID)
	if not itemID then return 0 end
	return CH.Demand.Estimate(itemID).units
end

--- A craft's accounts, saved with the scan for the item tooltip: reagents (with what each cost at
--- scan time), sales, Multicraft and Resourcefulness, per craft.
local function accounts(result, r)
	if not r or not r.profit then return nil end
	local reagents = {}
	-- every rank of a reagent with ranks, so what you hold counts whatever rank it is
	local ranksOf = {}
	for _, slot in ipairs(result.qual or {}) do
		if slot.items and #slot.items > 1 then
			for _, id in ipairs(slot.items) do ranksOf[id] = slot.items end
		end
	end
	local ok, e = pcall(CH.Queue.FromRow, result, r)
	for _, s in ipairs(ok and e and e.shop or {}) do
		local unit, via = Sc.ReagentPrice(s.itemID, result.recipeID)
		table.insert(reagents, { itemID = s.itemID, n = s.n, rank = s.rank, tiers = s.tiers, cost = unit and unit * s.n,
			crafted = via and via.char or nil, ranks = ranksOf[s.itemID] })
	end
	local p = r.parts or {}
	return { quality = r.quality, concentration = r.concentration, avgConcentration = r.avgConcentration,
		made = result.made, unit = r.unit, price = r.price, sales = r.value, cost = r.cost, extraItems = (p.mc or 0) * (p.extraItems or 0),
		mcGold = p.mcGold, resGold = p.resGold, profit = r.profit, reagents = reagents,
		deposit = r.ev and r.ev.deposits, -- deposits lost to expiries, per item sold: they don't move with the price
		queue = ok and e and e.reagents or nil } -- the reagents by slot, to queue this craft without the profession open
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

-- Subrecipes --------------------------------------------------------------------------------
-- A reagent someone on the warband crafts is worth what making it costs, when that's less than
-- buying it. The cost per item comes from each character's last scan (the best plain craft, with
-- Multicraft and Resourcefulness). Only crafts priced at bought reagents count, one level deep, so
-- two recipes that make each other's reagents can't drive each other's cost down.
Sc.CRAFTED_MAX_AGE = 14 * 86400 -- an older scan's cost is too stale to price by
local craftedIndex
function Sc.ClearCrafted() craftedIndex = nil end
local function crafted()
	if craftedIndex then return craftedIndex end
	craftedIndex = {}
	local now = time()
	for key, c in pairs(CH.db and CH.db.characters or {}) do
		for _, p in pairs(c.professions or {}) do
			local sc = p.scan
			if sc and sc.at and now - sc.at <= Sc.CRAFTED_MAX_AGE then
				for _, r in ipairs(sc.rows or {}) do
					local e = r.item and r.craftEach and not r.viaCraft and r.craftEach > 0 and craftedIndex[r.item]
					if r.item and r.craftEach and not r.viaCraft and r.craftEach > 0 and (not e or r.craftEach < e.each) then
						craftedIndex[r.item] = { each = r.craftEach, recipeID = r.recipeID, name = r.name, char = c.name or key, key = key, at = sc.at }
					end
				end
			end
		end
	end
	return craftedIndex
end

--- What making one of an item costs on your warband: { each, recipeID, name, char, key, at } or nil.
function Sc.Crafted(itemID) return itemID and crafted()[itemID] or nil end

--- Whether reagents you can craft are priced at what making them costs (Settings, on by default).
function Sc.SubrecipesOn() return not (CH.db and CH.db.settings.subrecipes == false) end

--- A reagent's price for a craft: buying it (chmat), or making it when that's cheaper. Returns the
--- price and the craft it came from (nil when buying wins). notRecipe skips the recipe being priced.
function Sc.ReagentPrice(itemID, notRecipe)
	-- buying it, on the costing basis in Settings (replacement by default: chmat)
	local buy = itemID and CH.Prices.ReagentCost(itemID)
	if not Sc.SubrecipesOn() then return buy end
	local c = Sc.Crafted(itemID)
	if c and c.recipeID ~= notRecipe and (not buy or c.each < buy) then return c.each, c end
	return buy
end

--- Buy or craft: the cheapest listing of a scanned row's item against making it. Returns
--- { buy, craft, resell (your value after cut), flip (resell less buy), save (craft less buy) }.
function Sc.BuyOrCraft(r)
	local item = r and (r.item or r.concItem)
	local craft = r and r.craftEach
	if not item then return nil end
	local buy = CH.Prices.Get("chmat", "i:" .. item)
	local value = CH.Prices.Get("chvalue", "i:" .. item)
	local resell = value and CH.Expect.Value(item, value)
	return { buy = buy, craft = craft, resell = resell, flip = buy and resell and resell - buy,
		save = buy and craft and craft - buy }
end

--- What a scanned row's Concentration craft adds per expected point over its best plain craft (or
--- over not crafting, when no plain craft pays). Works on scans saved before it was kept.
function Sc.GainPerPoint(r)
	if not r then return nil end
	if r.gainPerPoint then return r.gainPerPoint end
	local avg = r.avgConcentration or r.concentration
	if not (r.concProfit and avg and avg > 0) then return nil end
	return (r.concProfit - math.max(0, r.profit or 0)) / avg
end

--- A saved scan row at today's prices, for the Scan list: a view of the row (it reads through to
--- the saved one, which stays as scanned) whose profit, reagents, margin, Concentration profit,
--- gain per point, gold a day and sell-instead come from the same live statement the hovers show.
--- Rows saved without accounts come back as they are.
function Sc.Live(r)
	if not (r and (r.accounts or r.concAccounts)) or not CH.CraftBook then return r end
	local v = { scanned = r }
	local function live(acc)
		if not acc then return nil end
		local ok, _, profit = pcall(CH.CraftBook, acc)
		if not ok or not profit then return nil end
		local _, cost = CH.ReagentBook(acc)
		return profit, cost
	end
	local p, c = live(r.accounts)
	if p then
		v.profit, v.cost = p, c
		v.pct = c and c > 0 and p / c or nil
		local cs = CH.CraftOrSell(r.accounts)
		v.sellInstead = cs and cs.verdict == "sell" and cs.sell or false
	end
	local cp, cc = live(r.concAccounts)
	if cp then v.concProfit, v.concCost = cp, cc end
	local avg = r.avgConcentration or r.concentration
	local gpp = Sc.GainPerPoint(r)
	if gpp and avg and avg > 0 then
		local dConc = (v.concProfit or r.concProfit or 0) - (r.concProfit or 0)
		local dPlain = math.max(0, v.profit or r.profit or 0) - math.max(0, r.profit or 0)
		v.gainPerPoint = gpp + (dConc - dPlain) / avg
	end
	-- gold a day moves with the profit it was worked from
	local was = math.max(0, r.profit or 0) + math.max(0, r.concProfit or 0)
	local now = math.max(0, v.profit or r.profit or 0) + math.max(0, v.concProfit or r.concProfit or 0)
	if r.perDay and was > 0 then v.perDay = r.perDay * now / was end
	return setmetatable(v, { __index = r })
end

local function summary(result)
	local b, c = result.best, result.bestConc
	local item = b and b.item or (c and c.item)
	local made = result.made or 1
	-- items a craft makes on average, Multicraft included, as the profit per craft counts them
	local function yield(r)
		local p = r and r.parts or {}
		return math.max(0.01, made + (p.mc or 0) * (p.extraItems or 0))
	end
	local units = Sc.DailyUnits(item)
	local plainCrafts = b and units / yield(b) or 0
	local perDay = b and b.profit and b.profit > 0 and b.profit * plainCrafts or 0
	-- With Concentration: as many crafts a day as its own item sells, up to what a day's refill pays for.
	local avg = c and (c.avgConcentration or c.concentration)
	if c and c.profit and c.profit > 0 and avg and avg > 0 then
		local same = not b or c.item == b.item
		local cUnits = same and units or Sc.DailyUnits(c.item)
		local crafts = math.min(cUnits / yield(c), CH.CONC_PER_HOUR * 24 / avg)
		local plain = math.max(0, b and b.profit or 0)
		local conc
		if same then
			-- the same item: Concentration crafts take sales from plain ones; any left sell without it
			conc = crafts * c.profit + math.max(0, plainCrafts - crafts * yield(c) / yield(b or c)) * plain
			if conc > perDay then perDay = conc end
		else
			-- a better item sells to its own buyers, on top of the plain crafts
			perDay = perDay + crafts * c.profit
		end
	end
	return {
		recipeID = result.recipeID, name = result.name, made = made, tiers = result.model and result.model.maxQ,
		quality = b and b.quality, profit = b and b.profit, cost = b and b.cost, item = item,
		pct = b and b.cost and b.cost > 0 and b.profit / b.cost or nil,
		concQuality = c and c.quality, perPoint = c and c.perPoint, concProfit = c and c.profit, concentration = c and c.concentration,
		avgConcentration = avg, concItem = c and c.item,
		accounts = accounts(result, b), concAccounts = accounts(result, c),
		craftEach = Sc.CraftEach(b, made),
		-- the decision numbers, kept with the scan: what Concentration adds per point, the break-even price
		gainPerPoint = c and c.gain and c.gain.perPoint, concGain = c and c.gain and c.gain.gain,
		breakEven = b and b.breakEven and b.breakEven.price, cushion = b and b.breakEven and b.breakEven.cushion,
		concBreakEven = c and c.breakEven and c.breakEven.price,
		-- priced with a reagent you craft: not used to price other crafts, so costs never loop
		viaCraft = result.model and result.model.viaCraft or nil,
		soldPerDay = CH.Advisor.SoldPerDay(item),
		-- the sales a day gold a day counts, and where that comes from (Demand.SOURCE)
		dailyUnits = item and units or nil, demandSource = item and CH.Demand.Estimate(item).source or nil,
		perDay = perDay,
		-- selling the reagents you hold beats crafting: what they'd bring after the cut
		sellInstead = (function()
			local ok, cs = pcall(CH.Advisor.CraftOrSell, result, b)
			return ok and cs and cs.gain < 0 and cs.sell or nil
		end)(),
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

--- The expansion AuctionIQ works on: the one the profession window has open (Midnight by default,
--- Khaz Algar when you switch to it there), else the newest of the profession's lines, else the
--- newest in rows.
function Sc.CurrentLine(rows)
	local ui, best = C_TradeSkillUI, nil
	local open = ui.GetChildProfessionInfo and ui.GetChildProfessionInfo()
	if open and open.professionID and open.professionID ~= 0 then return open.professionID end
	for _, p in ipairs(ui.GetChildProfessionInfos and ui.GetChildProfessionInfos() or {}) do
		if p.professionID and (not best or p.professionID > best) then best = p.professionID end
	end
	if best then return best end
	for _, r in ipairs(rows or {}) do if r.line and (not best or r.line > best) then best = r.line end end
	return best
end

--- Recipe IDs worth scanning in the open profession: the expansion the window has open only.
function Sc.Recipes()
	local out = {}
	local ui = C_TradeSkillUI
	local line = Sc.CurrentLine()
	for _, id in ipairs(ui.GetAllRecipeIDs and ui.GetAllRecipeIDs() or {}) do
		if eligible(ui.GetRecipeInfo(id)) then
			local ok, l = true, nil
			if line and ui.GetTradeSkillLineForRecipe then ok, l = pcall(ui.GetTradeSkillLineForRecipe, id) end
			if not (ok and l and line) or l == line then table.insert(out, id) end
		end
	end
	return out
end

-- The recipe being worked out, as a coroutine, and when this frame's share of work began.
local work, frameStart
local work_t0 -- when the recipe being worked out started (it may span frames: then it isn't timed)
local bg -- the background job (Sc.Background), if one is running
local clock = debugprofilestop

--- Called from inside the advisor's longer loops: when the scan has used this frame's budget, pause
--- the recipe there and carry on next frame. Does nothing outside a scan.
function Sc.Yield()
	local co = coroutine.running()
	if co and clock and ((work and co == work) or (bg and co == bg.co)) and clock() - frameStart >= BUDGET_MS then
		coroutine.yield()
	end
end

--- Run fn() in the background, a few milliseconds a frame (pausing wherever the advisor calls
--- Sc.Yield), then onDone(ok, result). One job at a time: a new one replaces the one running.
--- Without timers (tests) it runs at once.
function Sc.Background(fn, onDone)
	if not (C_Timer and clock) then
		local ok, r = pcall(fn)
		if onDone then onDone(ok, r) end
		return
	end
	local job = { co = coroutine.create(fn), onDone = onDone }
	bg = job
	local function step()
		if bg ~= job then return end -- replaced
		if work then return C_Timer.After(0, step) end -- the scan has the frame
		frameStart = clock()
		local ok, r = coroutine.resume(job.co)
		if coroutine.status(job.co) ~= "dead" then return C_Timer.After(0, step) end
		bg = nil
		if job.onDone then job.onDone(ok, r) end
	end
	C_Timer.After(0, step)
end

--- Stop a scan that's running; what it has found so far isn't saved.
function Sc.Stop() if running then running = "stop" end end

--- Scan the open profession. onStep(done, total) while it runs, onDone(rows) at the end. Each frame
--- works for up to BUDGET_MS (at least PER_FRAME recipes without a clock), and a recipe that takes
--- longer pauses part-way and resumes next frame.
function Sc.Run(onStep, onDone)
	if running then return false end
	local profID = CH.OpenProfessionID()
	if not profID then return false end
	if not CH.Prices.Available() then return false end
	pcall(CH.Demand.Warm) -- the sales index, once, before the frame-budgeted work starts
	local ids = Sc.Recipes()
	local i, rows = 0, {}
	Sc.models[profID] = Sc.models[profID] or {}
	running, clock = true, debugprofilestop
	-- recipes that errored: they keep their row from the last good scan, so a failure never wipes it
	local failed, firstError = {}, nil
	local function finish(why)
		running, work = false, nil
		local report
		local p = CH.Me().professions[profID]
		if not why and #failed > 0 then
			local old = {}
			for _, r in ipairs(p and p.scan and p.scan.rows or {}) do if r.recipeID then old[r.recipeID] = r end end
			local kept = 0
			-- nothing scanned at all: keep the last scan as it was
			if #rows == 0 or #failed >= #ids then
				why = "failed: every recipe errored (" .. tostring(firstError) .. "), so the last scan is kept"
				CH.Print("scan " .. why .. ".")
			else
				for _, id in ipairs(failed) do
					if old[id] then old[id].stale = true; table.insert(rows, old[id]); kept = kept + 1 end
				end
				CH.Print(string.format("scan: %d of %d recipes errored (%s); %d kept their last scan's numbers.", #failed, #ids, tostring(firstError), kept))
			end
			report = { failed = #failed, kept = kept, total = #ids, error = firstError }
		end
		if not why then
			table.sort(rows, function(a, b) return (a.profit or -math.huge) > (b.profit or -math.huge) end)
			if p then p.scan = { at = time(), rows = rows, currentLine = Sc.CurrentLine(rows), failed = report and report.failed or nil } end
			Sc.ClearCrafted()
		end
		if onDone then onDone(rows, why, report) end
	end
	local function begin(id)
		return coroutine.create(function()
			local model = CH.Advisor.Measure(id, { professionID = profID })
			if not model then return nil end
			Sc.models[profID][id] = model
			local result = CH.Advisor.Evaluate(model)
			-- what the card shows about finishing reagents, worked out now while the scan has the time
			if CH.Advisor.FinishingAdvice then pcall(CH.Advisor.FinishingAdvice, result) end
			-- the craft card reuses it: a click on this recipe needn't work it out again
			if CH.AdvisorUI and CH.AdvisorUI.Remember then CH.AdvisorUI.Remember(id, model, result) end
			return model, result
		end)
	end
	local function step()
		if running == "stop" then return finish("stopped") end
		-- the profession changed under us: this scan's results would be for the wrong one
		if CH.OpenProfessionID() ~= profID then return finish("stopped: the profession changed") end
		frameStart = clock and clock()
		local n = 0
		while true do
			if not work then
				-- start another recipe only when it should finish inside the budget (from how long
				-- recipes have been taking), so a frame doesn't run long on its last one
				if clock then
					if n >= 1 and clock() - frameStart + (Sc.avgMs or 1) > BUDGET_MS then break end
				elseif n >= PER_FRAME then break end
				i = i + 1
				local id = ids[i]
				if not id then return finish() end
				work, n = begin(id), n + 1
				work_t0 = clock and clock()
			end
			local ok, err, result = coroutine.resume(work)
			if coroutine.status(work) ~= "dead" then break end -- paused: out of time this frame
			if clock and work_t0 and n >= 1 then
				local took = clock() - work_t0
				Sc.avgMs = Sc.avgMs and (Sc.avgMs * 0.8 + took * 0.2) or took
			end
			work = nil
			-- a recipe that errors keeps its last good row, and the scan says how many did
			if not ok then
				table.insert(failed, ids[i])
				firstError = firstError or tostring(err):gsub("^.-:%d+: ", "")
			elseif result and (result.best or result.bestConc) then
				local row = summary(result)
				row.line, row.expansion = Sc.Expansion(ids[i])
				table.insert(rows, row)
			end
		end
		if onStep then onStep(i, #ids) end
		C_Timer.After(0, step)
	end
	-- the first recipes next frame: listing them is this frame's work
	if C_Timer and clock then C_Timer.After(0, step) else step() end
	return true
end

function Sc.IsRunning() return running or Sc.all ~= nil end

--- This character's professions worth scanning: the two primary ones and Cooking, as { name, skillLine }.
function Sc.MyProfessions()
	local out = {}
	if not (GetProfessions and GetProfessionInfo) then return out end
	local p1, p2, _, _, cook = GetProfessions()
	for _, idx in ipairs({ p1 or 0, p2 or 0, cook or 0 }) do
		if idx ~= 0 then
			local name, _, _, _, _, _, skillLine = GetProfessionInfo(idx)
			if name and skillLine then table.insert(out, { name = name, skillLine = skillLine }) end
		end
	end
	return out
end

-- Is the profession window showing this base profession (Alchemy, not someone else's), ready to scan?
local function showing(skillLine)
	local ui = C_TradeSkillUI
	if not (ui.IsTradeSkillReady and ui.IsTradeSkillReady()) or not CH.OpenProfessionID() then return false end
	local base = ui.GetBaseProfessionInfo and ui.GetBaseProfessionInfo()
	return not base or not base.professionID or base.professionID == skillLine
end

--- Scan every profession this character has, one after another: open each, scan it, move on. The
--- game only shows an addon the professions of the character you're logged in as, so another
--- character's are scanned on that character. onStep() as it goes (Sc.all says where it is),
--- onDone(results) at the end, results = { { name, rows, why } }. Returns ok, why not.
--- From a click: open the profession Scan all is waiting on and carry on scanning.
function Sc.ContinueAll()
	local all = Sc.all
	local prof = all and all.waiting
	if not prof then return false end
	all.waiting = nil
	local ui = C_TradeSkillUI
	if ui.OpenTradeSkill then ui.OpenTradeSkill(prof.skillLine) end
	all.wait()
	return true
end

function Sc.ScanAll(onStep, onDone)
	if Sc.IsRunning() then return false, "a scan is already running" end
	if InCombatLockdown and InCombatLockdown() then return false, "you're in combat" end
	if not CH.Prices.Available() then return false, "prices aren't loaded (TSM)" end
	local list = Sc.MyProfessions()
	if #list == 0 then return false, "this character has no professions to scan" end
	local ui = C_TradeSkillUI
	local wasOpen = CH.OpenProfessionID() ~= nil
	local all = { list = list, i = 0, results = {} }
	Sc.all = all
	local nextOne
	local function finish()
		Sc.all = nil
		if not wasOpen and ui.CloseTradeSkill then ui.CloseTradeSkill() end
		if onDone then onDone(all.results) end
	end
	local function record(prof, rows, why)
		table.insert(all.results, { name = prof.name, rows = rows and #rows or 0, why = why })
		nextOne()
	end
	nextOne = function()
		if all.stop then return finish() end
		all.i = all.i + 1
		local prof = list[all.i]
		if not prof then return finish() end
		all.name, all.done, all.total = prof.name, 0, nil
		local tries = 0
		local function wait()
			if all.stop then return finish() end
			if showing(prof.skillLine) then
				local ok = Sc.Run(function(done, total)
					all.done, all.total = done, total
					if onStep then onStep() end
				end, function(rows, why) record(prof, rows, why) end)
				if not ok then record(prof, nil, "couldn't start") end
				return
			end
			tries = tries + 1
			if tries > 40 then return record(prof, nil, "didn't open") end -- about 8 seconds
			C_Timer.After(0.2, wait)
		end
		all.wait = wait
		-- the game only lets a click open a profession: the first opens from the Scan press; each
		-- after that waits for a press of the button (it reads Open <profession>)
		if not showing(prof.skillLine) then
			if all.i > 1 or all.clickUsed then
				all.waiting = prof
				if onStep then onStep() end
				return
			end
			all.clickUsed = true
			if ui.OpenTradeSkill then ui.OpenTradeSkill(prof.skillLine) end
		end
		wait()
		if onStep then onStep() end
	end
	nextOne()
	return true
end

--- What the scan of every profession is doing, for a button or status line: nil when it isn't running.
function Sc.AllStatus()
	local a = Sc.all
	if not a then return nil end
	if a.waiting then return string.format("Press Open to scan %s (%d of %d)", a.waiting.name or "?", a.i, #a.list) end
	return string.format("Scanning %s (%d of %d)%s", a.name or "?", a.i, #a.list,
		a.total and string.format(" %d/%d", a.done or 0, a.total) or "")
end

--- Stop the scan of every profession after the one it's on.
function Sc.StopAll()
	if not Sc.all then return end
	if Sc.all.waiting then Sc.all = nil; return end
	Sc.all.stop = true; Sc.Stop()
end

--- The saved scan for a profession on this character.
function Sc.Results(profID)
	local p = profID and CH.Me().professions[profID]
	return p and p.scan
end

local function held(id)
	return C_Item and C_Item.GetItemCount and C_Item.GetItemCount(id, true, false, true, true) or 0
end

-- Scans saved before the ranks were kept: each reagent's ranks from the recipe's schematic, which
-- the game answers for a known recipe without the profession open. itemID -> { rank 1 ID, rank 2 ID, ... }
local schematicCache = {}
local function schematicRanks(recipeID)
	local hit = schematicCache[recipeID]
	if hit ~= nil then return hit or nil end
	local out = false
	if recipeID and C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic then
		local ok, sch = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
		if ok and sch and sch.reagentSlotSchematics then
			out = {}
			for _, slot in ipairs(sch.reagentSlotSchematics) do
				local ids = {}
				for _, rg in ipairs(slot.reagents or {}) do if rg.itemID then ids[#ids + 1] = rg.itemID end end
				if #ids > 1 then for _, id in ipairs(ids) do out[id] = ids end end
			end
		end
	end
	schematicCache[recipeID] = out
	return out or nil
end

--- What one craft needs against what you hold, per reagent (bags, bank, reagent bank, warband
--- bank), like CraftSim's have/need: the ranks of a reagent count together, since the game takes
--- any mix of them. acc: a scan row's accounts. Returns a list of
--- { itemID, need, have, crafts, exact, ranks = { { itemID, rank, tiers, need, have } } }, where
--- crafts is how many crafts what you hold covers at any rank and exact how many at the scan's own
--- ranks (fewer when you'd fill in with other ranks, which can change the quality). nil without reagents.
function Sc.Needs(acc, recipeID)
	if not acc or not acc.reagents or #acc.reagents == 0 then return nil end
	local fallback
	local groups, byKey = {}, {}
	for _, rg in ipairs(acc.reagents) do
		local need = rg.n or 1
		if need > 0 then
			local ranks = rg.ranks
			if not ranks and (rg.tiers or 0) > 1 then
				fallback = fallback or schematicRanks(recipeID) or {}
				ranks = fallback[rg.itemID]
			end
			local key = ranks and ranks[1] or rg.itemID
			local g = byKey[key]
			if not g then
				g = { itemID = rg.itemID, need = 0, have = 0, ranks = {} }
				for q, id in ipairs(ranks or { rg.itemID }) do
					local h = held(id)
					g.ranks[q] = { itemID = id, rank = ranks and q or nil, tiers = ranks and #ranks or nil, need = 0, have = h }
					g.have = g.have + h
				end
				byKey[key] = g
				groups[#groups + 1] = g
			end
			g.need = g.need + need
			local found
			for _, x in ipairs(g.ranks) do
				if x.itemID == rg.itemID then x.need = x.need + need; found = true end
			end
			if not found then
				local h = held(rg.itemID)
				table.insert(g.ranks, { itemID = rg.itemID, rank = rg.rank, tiers = rg.tiers, need = need, have = h })
				g.have = g.have + h
			end
		end
	end
	for _, g in ipairs(groups) do
		g.crafts = math.floor(g.have / g.need)
		local exact = math.huge
		for _, x in ipairs(g.ranks) do
			if x.need > 0 then exact = math.min(exact, math.floor(x.have / x.need)) end
		end
		g.exact = exact == math.huge and g.crafts or exact
	end
	return groups
end

--- How many times you can make a scanned recipe now from what you own (bags, bank, reagent bank,
--- warband bank), with the reagents and finishing reagents the scan picked as best, any rank of
--- each counting (see Sc.Needs). With Concentration it is also capped by the points you have.
--- Returns plain, withConc, and the reagent that runs out first for each (its item ID).
function Sc.Craftable(r, concNow)
	local function count(acc)
		local groups = Sc.Needs(acc, r.recipeID)
		if not groups then return nil end
		local n, short = math.huge, nil
		for _, g in ipairs(groups) do
			if g.crafts < n then n, short = g.crafts, g.itemID end
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

--- /aiq mem: how much AuctionIQ is holding, by kind (counts, to see what grows).
function CH.MemLines()
	local out = {}
	local nm, nf = 0, 0
	for _, byRecipe in pairs(Sc.models) do
		for _, m in pairs(byRecipe) do
			nm = nm + 1
			nf = nf + (m.frontierCache and m.frontierCache.states and #m.frontierCache.states or 0)
		end
	end
	table.insert(out, string.format("recipe models this session: %d (%d reagent-mix states)", nm, nf))
	if CH.AdvisorUI and CH.AdvisorUI.KnownCount then table.insert(out, "recipes worked out and kept: " .. CH.AdvisorUI.KnownCount()) end
	if CH.Ledger and CH.Ledger.ParsedCounts then
		for _, l in ipairs(CH.Ledger.ParsedCounts()) do table.insert(out, l) end
	end
	local scans = 0
	for _, p in pairs(CH.Me().professions or {}) do scans = scans + (p.scan and p.scan.rows and #p.scan.rows or 0) end
	table.insert(out, "saved scan rows (this character): " .. scans)
	return out
end
