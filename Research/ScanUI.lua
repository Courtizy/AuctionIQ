-- Recipe scan window, three lists under one bar:
--   Recipes      every learned recipe, in three views of the same scan:
--                  Craft          profit without Concentration, sales and gold a day
--                  Concentration  what spending points pays, per craft and per point
--                  Buy vs craft   the cheapest listing against making it
--   Work orders  every order the game has listed, with what it really pays and 1KP when it gives knowledge
--   First crafts recipes that still give their first-craft knowledge point, and what each point costs
-- Click a column header to sort by it (again to flip). Click a recipe to select it and open it: the
-- strip under the list shows both crafts the scan found for it, each with its own Queue button, so
-- what you queue is the craft you were looking at. Orders and first crafts: click to open,
-- shift-click to queue that row.
local _, CH = ...

local SUI = {}
CH.ScanUI = SUI
local frame, status, detail
local N, W, H = 21, 836, 18
local DETAIL = 0 -- the selected recipe now sits in the side panel, right of the list
local SIDE = 270 -- the Recipes views' side panel (the Craft page's Next Move panel)
-- The layout, on a 6 px gutter: the table card from x 6, the side panel 6 to its right and 6 from the
-- window's edge, both from y -48 to 6 above the bottom. TWR is the table's width inside its card.
local GUT = 6
local CARD_H = N * H + 28
local TWR = W - SIDE - 3 * GUT - 10 -- the Recipes table's width beside it
local offset, data = 0, {}
local scrollBar
local showOlder = true
local mode = "recipes"
local view = "craft" -- the Recipes list's view: craft, conc or buy
local selected -- recipeID of the selected recipe
local qty = 1
local tables, heads = {}, {}

-- { label, x, width, sort key, justify }. craft, conc and buy are the Recipes views.
local COLS = {
	-- short tables: only the columns that rank the rows. The selected row's numbers are in the side
	-- card, which answers the one question each view is for
	-- the snapshot: the best pick (most profit a craft, with or without Concentration), what it
	-- earns and costs, margin, and how many you can make now
	craft = { { "Recipe", 12, 164, "name" }, { "Best", 180, 48, "bestQ", "CENTER" }, { "Profit", 230, 88, "bestProfit" },
		{ "Cost", 320, 80, "bestCost" }, { "Margin", 402, 60, "bestPct" }, { "Max", 464, 86, "bestCan" } },
	conc = { { "Recipe", 12, 216, "name" }, { "With Conc.", 232, 112, "concProfit" }, { "Extra/pt", 348, 96, "gainPerPoint" },
		{ "Max", 448, 102, "canMakeConc" } },
	buy = { { "Recipe", 12, 216, "name" }, { "Craft each", 232, 104, "craftEach" }, { "Cheapest", 340, 100, "buyPrice" },
		{ "Saves", 444, 106, "buySave" } },
	-- like CraftSim's: who it's for, rewards, profit, what your reagents cost and the Concentration it takes
	orders = { { "Recipe", 62, 196, "name" }, { "Customer", 262, 96, "from", "LEFT" }, { "Profit", 362, 100, "profit" },
		{ "", 466, 84, "concentration" } },
	first = { { "Recipe", 12, 290, "name" }, { "Proceeds", 306, 120, "value" }, { "Point costs", 430, 120, "net" } },
}
function SUI.Columns(m) return COLS[m] end
local SORT = { craft = { key = "bestProfit" }, conc = { key = "gainPerPoint" }, buy = { key = "buySave" }, orders = { key = "default" }, first = { key = "net" } }
local VIEWS = { { "craft", "Craft", 60 }, { "conc", "Concentration", 108 }, { "buy", "Buy vs craft", 96 } }
local NAMES = { concentration = "Concentration needed", name = "name", profit = "profit per craft", pct = "margin", concProfit = "profit with Concentration",
	perPoint = "gold per Concentration point", gainPerPoint = "gold Concentration adds per expected point", soldPerDay = "sold a day", perDay = "gold a day", buySave = "how much buying beats crafting",
	from = "who it's from", commission = "commission", rewardValue = "rewards", cost = "reagents", quality = "quality",
	value = "what it sells for", net = "cheapest point first", default = "fillable, knowledge, then profit",
	canMake = "how many you can make now", canMakeConc = "how many you can make with Concentration now",
	bestQ = "best quality", bestProfit = "profit of the best pick", bestCost = "cost of the best pick", bestPct = "margin of the best pick",
	bestCan = "how many of the best pick you can make now",
	concentration = "Concentration points", craftEach = "what one costs to make", buyPrice = "cheapest listing",
	resell = "what it resells for", flip = "buy and relist profit" }

-- The list on screen: a Recipes view, or orders / first.
local function listKey() return mode == "recipes" and view or mode end

--- Sort rows by key (numbers biggest first, names A-Z; asc flips it). Missing values go last.
local function sortRows(list, key, asc)
	if key == "default" then return list end
	table.sort(list, function(a, b)
		local x, y = a[key], b[key]
		if x == nil or y == nil then
			if x == nil and y == nil then return (a.name or "") < (b.name or "") end
			return y == nil
		end
		if type(x) == "string" then
			x, y = x:lower(), tostring(y):lower()
			if asc then return x > y end
			return x < y
		end
		if asc then return x < y end
		return x > y
	end)
	return list
end
SUI.SortRows = sortRows

local function money(c)
	if not c then return CH.Theme.Color("muted", "-") end
	return CH.Theme.Color(c >= 0 and "ok" or "bad", CH.FormatMoney(c))
end

--- The queue entry for one of a scanned recipe's two crafts, exactly as the scan found it: the
--- plain craft, or (conc) the Concentration craft, with the reagents the scan picked. A scan saved
--- before reagent slots were kept is worked out again, and queued only if it still finds the same
--- craft at the same quality. Returns the entry, or nil and why.
function SUI.ScanEntry(r, conc)
	if not r or r.header then return nil, "pick a recipe first" end
	if conc and not r.concProfit then return nil, "this recipe has no Concentration craft" end
	if not conc and not r.profit then return nil, "this recipe has no plain craft with a price" end
	local e = CH.Queue.FromScan(CH.CharacterKey(), CH.Me(), r, conc)
	if e then return e end
	local ok, result = pcall(CH.Advisor.Analyze, r.recipeID, { professionID = CH.OpenProfessionID() })
	if not (ok and result) then return nil, "open the profession to queue it" end
	local pick = conc and result.bestConc or (not conc and result.best)
	if not pick or pick.quality ~= (conc and r.concQuality or r.quality) then
		return nil, "the best craft has changed since the scan. Scan again, then queue it"
	end
	return CH.Queue.FromRow(result, pick)
end

local function queueRow(r)
	if mode == "recipes" then return SUI.QueueSelected(false, 1, r) end
	if not r.row or not r.result then
		return false
	elseif mode == "orders" then
		CH.Queue.Add(r.result, r.row, 1, { orderID = r.orderID, customer = r.from, special = r.kp })
	else
		CH.Queue.Add(r.result, r.row, 1, { firstCraft = true })
	end
	CH.Print("queued 1 x " .. (r.name or "?"))
	return true
end

-- The selected recipe's scan row, if it's still in the list.
local function selectedRow()
	if not selected then return nil end
	for _, d in ipairs(data) do if not d.header and d.recipeID == selected then return d end end
end
SUI.SelectedRow = selectedRow

--- Queue n of the selected recipe's plain craft, or (conc) its Concentration craft. r picks a row
--- other than the selected one. Returns true, or false and why (also printed).
function SUI.QueueSelected(conc, n, r)
	r = r or selectedRow()
	n = math.max(1, math.floor(n or qty))
	local e, why = SUI.ScanEntry(r, conc)
	if not e then
		CH.Print("can't queue that: " .. why)
		return false, why
	end
	CH.Queue.AddEntry(e, n)
	CH.Print(string.format("queued %d x %s (Q%d%s)", n, r.name or "?", e.quality or 0,
		e.concentration and (", Concentration " .. e.concentration .. " points") or ", no Concentration"))
	return true
end

--- Select a recipe in the Recipes list (as a click does); the quantity goes back to 1.
function SUI.Select(recipeID)
	if recipeID ~= selected then qty = 1 end
	-- the Details view follows the picked recipe; a click on the list means it isn't showing
	selected = recipeID
	return SUI.Refresh()
end
function SUI.Selected() return selected end
function SUI.SetQty(n) qty = math.max(1, math.min(999, math.floor(n or 1))); return SUI.Refresh() end
function SUI.Qty() return qty end

local function click(i)
	local r = data[i + offset]
	if not r then return end
	if mode ~= "recipes" then
		SUI.selRow = SUI.RowKey(r)
		if IsShiftKeyDown and IsShiftKeyDown() then queueRow(r)
		elseif mode == "orders" then CH.Orders.Open(r.order, r.recipeID)
		elseif C_TradeSkillUI.OpenRecipe then C_TradeSkillUI.OpenRecipe(r.recipeID) end
		SUI.Refresh()
		return
	end
	if r.header then
		if not r.current then showOlder = false; offset = 0; SUI.Refresh() end
		return
	end
	-- a click selects the recipe and opens it; queueing is the strip's buttons, so it's always the craft shown there
	SUI.Select(r.recipeID)
	if C_TradeSkillUI.OpenRecipe then C_TradeSkillUI.OpenRecipe(r.recipeID) end
end
SUI.Click = click

--- A work order's or first craft's key, to keep it selected across redraws.
function SUI.RowKey(d) return d and (d.orderID and ("o" .. d.orderID) or ("r" .. tostring(d.recipeID))) or nil end

local function kpTag(yes) return yes and CH.Theme.Color("accent", " 1KP") or "" end

--- Hover lines for a work order or first craft row (also used by the tests).
function SUI.OrderLines(d)
	local T, M = CH.Theme, CH.FormatMoney
	local lines = { { T.Color("accent", d.name or "?") .. kpTag(d.kp or not d.orderID) } }
	if d.orderID then
		table.insert(lines, { d.kind .. " order", d.from })
		if d.expansion then table.insert(lines, { "Expansion", d.expansion .. (d.current and "" or T.Color("muted", "  (older)")) }) end
		if d.minQuality then table.insert(lines, { "Asks for at least", CH.Window.QualityIcon(d.minQuality, 14, d.tiers) }) end
		local B = CH.Window.Book
		table.insert(lines, B.Head("Revenue"))
		table.insert(lines, B.Line("Commission, after the consortium's cut", d.commission or 0))
		for _, rw in ipairs(d.rewards) do
			local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(rw.id)) or ("item " .. rw.id)
			local label = rw.count .. " x " .. name .. (rw.knowledge and T.Color("accent", "  knowledge") or "")
			table.insert(lines, rw.value and B.Line(label, rw.value) or B.Text(label, T.Color("muted", "can't be sold"), "muted"))
		end
		if d.ok and d.have then
			table.insert(lines, { "Reagents", T.Color("ok", "you have them all") })
		elseif d.ok then
			table.insert(lines, { T.Color("bad", "Missing reagents") })
			for _, l in ipairs(d.missing or {}) do
				table.insert(lines, { "  " .. (l.name or "?") .. (l.rank and (" " .. CH.Window.QualityIcon(l.rank, 12, l.tiers)) or ""),
					string.format("have %d, need %d", l.have, l.need) })
			end
			if not (d.missing and d.missing[1]) then table.insert(lines, { "  Concentration", T.Color("bad", "not enough right now") }) end
		end
		if d.ok then
			-- commission and rewards less your reagents, then what procs save on average
			local pays = (d.commission or 0) + (d.rewardValue or 0)
			table.insert(lines, B.Head("Costs"))
			table.insert(lines, B.Line("Your reagents", -(d.cost or 0), true))
			local procs = (d.profit or 0) - (pays - (d.cost or 0))
			if math.abs(procs) >= 100 then table.insert(lines, B.Line("Resourcefulness, on average", procs)) end
			table.insert(lines, B.Total("Profit", d.profit))
			if d.concentration then table.insert(lines, { T.Color("muted", "Needs " .. d.concentration .. " Concentration to reach the quality asked.") }) end
		elseif d.learned == false then
			table.insert(lines, { T.Color("bad", "You haven't learned this recipe.") })
		elseif d.unpriced then
			local n = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(d.unpriced)) or ("item " .. d.unpriced)
			table.insert(lines, { T.Color("bad", "No price for " .. n .. ": TSM has no value for it, so the cost can't be worked out.") })
		else
			table.insert(lines, { T.Color("bad", "No craft reaches the quality this order asks for.") })
		end
		table.insert(lines, { T.Color("muted", "Profit counts only rewards that sell. Click to open, shift-click to queue.") })
	else
		table.insert(lines, { "First craft gives", T.Color("accent", "1 knowledge point") })
		table.insert(lines, { "Cheapest reagents", M(d.cost or 0) })
		table.insert(lines, { "The item sells for, after the cut", d.value and M(d.value) or T.Color("muted", "no price") })
		if d.net then table.insert(lines, { d.net >= 0 and "Profit on top of the point" or "The point costs you", money(d.net >= 0 and d.net or -d.net) }) end
		table.insert(lines, { T.Color("muted", "Click to open, shift-click to queue. Queue all adds every one.") })
	end
	return lines
end

--- A work order cell's own tooltip: rewards (3), profit (4) or crafting costs (5), laid out like a
--- statement (CH.Window.Book). nil for the rest.
function SUI.OrderCellLines(d, col)
	local T, M, B = CH.Theme, CH.FormatMoney, CH.Window.Book
	if col == 3 then
		local lines = { B.Head("Rewards") }
		for _, rw in ipairs(d.rewards) do
			local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(rw.id)) or ("item " .. rw.id)
			local label = CH.Window.ItemIcon(rw.id, 14) .. rw.count .. " x " .. name .. (rw.knowledge and T.Color("accent", "  knowledge") or "")
			table.insert(lines, rw.value and B.Line(label, rw.value) or B.Text(label, T.Color("muted", "can't be sold"), "muted"))
		end
		if not d.rewards[1] then table.insert(lines, B.Note("No rewards beyond the commission.")) end
		table.insert(lines, B.Total("Total", d.rewardValue or 0))
		table.insert(lines, B.Note("Sellable rewards at what they bring after the AH cut."))
		return lines
	elseif col == 4 and d.ok then
		local pays = (d.commission or 0) + (d.rewardValue or 0)
		local procs = (d.profit or 0) - (pays - (d.cost or 0))
		local lines = { B.Head("Revenue"), B.Line("Commission, after the consortium's cut", d.commission or 0) }
		if (d.rewardValue or 0) > 0 then table.insert(lines, B.Line("Rewards you can sell", d.rewardValue)) end
		table.insert(lines, B.Head("Costs"))
		table.insert(lines, B.Line("Reagents you supply", -(d.cost or 0), true))
		if math.abs(procs) >= 100 then table.insert(lines, B.Line("Resourcefulness, on average", procs)) end
		table.insert(lines, B.Total("Profit", d.profit))
		for _, l in ipairs(CH.Advisor.CraftOrSellLines(d.result, d.row)) do table.insert(lines, l) end
		if d.concentration then table.insert(lines, B.Note("Needs " .. math.floor(d.concentration + 0.5) .. " Concentration to reach the quality asked.")) end
		return lines
	elseif col == 5 and d.ok then
		local lines = { B.Head("Crafting costs") }
		for _, l in ipairs(d.costLines or {}) do
			local label = CH.Window.ItemIcon(l.id, 14) .. l.n .. " x " .. (l.name or "?") .. (l.rank and (" " .. CH.Window.QualityIcon(l.rank, 12, l.tiers)) or "")
				.. T.Color(l.have >= l.n and "ok" or "bad", string.format("  (have %d)", l.have))
			table.insert(lines, l.total and B.Line(label, -l.total, true) or B.Text(label, T.Color("bad", "no price"), "bad"))
			for _, t in ipairs(CH.Advisor.HeldText(l)) do table.insert(lines, t) end
		end
		if not (d.costLines and d.costLines[1]) then table.insert(lines, B.Note("The customer provides every reagent.")) end
		table.insert(lines, B.Total("Total", -(d.cost or 0)))
		table.insert(lines, B.Note("Only what you supply: the customer's reagents aren't counted."))
		return lines
	end
	return nil
end

--- A Recipes cell's own hover, in Book lines: the reagents column shows each reagent at what it
--- costs you (the opportunity cost of yours), the profit columns the craft's statement and craft or
--- sell. nil for the other cells (the recipe's general hover).
function SUI.RecipeCellLines(r, col, v)
	v = v or view
	if not r or r.header then return nil end
	local acc, title
	-- craft: Profit (3) and Cost (4) explain the best pick, plain or with Concentration
	if v == "craft" and (col == 3 or col == 4) then
		if r.bestConc then acc, title = r.concAccounts, "With Concentration" else acc, title = r.accounts, "Without Concentration" end
	elseif v == "conc" and col == 2 then acc, title = r.concAccounts, "With Concentration" end
	if not acc then return nil end
	local B, T = CH.Window.Book, CH.Theme
	local lines = { { T.Color("accent", r.name or "?"), T.Color("muted", title) } }
	if v == "craft" and col == 4 then
		for _, l in ipairs((CH.ReagentBook(acc))) do lines[#lines + 1] = l end
		if CH.Prices.CostBasis and CH.Prices.CostBasis() == "held" then
			lines[#lines + 1] = B.Note("Reagents you hold cost what they'd sell for after the cut: selling them is what crafting gives up. The rest cost the buy price.")
		end
		for _, l in ipairs(CH.CraftOrSellBook(acc)) do lines[#lines + 1] = l end
	else
		for _, l in ipairs((CH.CraftBook(acc))) do lines[#lines + 1] = l end
		lines[#lines + 1] = B.Note("Hover the Cost column for each reagent's opportunity cost.")
	end
	return lines
end

local function hover(owner, i, col)
	local r = data[i + offset]
	if not r then return end
	if mode == "orders" then CH.Window.Tooltip(owner, SUI.OrderCellLines(r, col) or SUI.OrderLines(r)); return end
	if mode ~= "recipes" then CH.Window.Tooltip(owner, SUI.OrderLines(r)); return end
	local T = CH.Theme
	local cell = SUI.RecipeCellLines(r, col)
	if cell then CH.Window.Tooltip(owner, cell); return end
	if r.header then
		CH.Window.Tooltip(owner, { { T.Color("accent", r.expansion) }, { T.Color("muted", r.current
			and "Recipes from the current expansion." or "Older expansion recipes: usually fewer buyers, so check Sold/day. Click to hide them.") } })
		return
	end
	local lines = { { T.Color("accent", r.name or "?") } }
	if r.expansion then table.insert(lines, { "Expansion", r.expansion .. (r.current and "" or T.Color("muted", "  (older)")) }) end
	if r.quality then table.insert(lines, { "Best without Concentration", CH.Window.QualityIcon(r.quality, 14, r.tiers) .. " " .. CH.FormatMoney(r.profit) }) end
	if r.cost then table.insert(lines, { "Reagents", CH.FormatMoney(r.cost) }) end
	if r.perPoint then
		table.insert(lines, { "Best with Concentration", CH.Window.QualityIcon(r.concQuality, 14, r.tiers) .. " " .. CH.FormatMoney(r.concProfit) })
		local gain = r.concProfit and (r.concProfit - math.max(0, r.profit or 0))
		if gain then table.insert(lines, { "  More than the plain craft", CH.FormatMoney(gain) .. " per craft" }) end
		if r.gainPerPoint then table.insert(lines, { string.format("  Extra per expected point (%d points)", r.concentration or 0), CH.FormatMoney(r.gainPerPoint) }) end
		table.insert(lines, { T.Color("muted", "  Whole profit per point (as CraftSim)"), CH.FormatMoney(r.perPoint) })
	end
	local function short(id)
		if id == "concentration" then return "Concentration" end
		return id and ((C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or ("item " .. id)) or nil
	end
	if r.canMake then
		table.insert(lines, { "Max you can make now", r.canMake .. (r.canMake == 0 and r.shortItem and T.Color("muted", "  short of " .. short(r.shortItem))
			or (r.shortItem and T.Color("muted", "  until " .. short(r.shortItem) .. " runs out") or "")) })
	end
	if r.canMakeConc then
		table.insert(lines, { "  with Concentration", r.canMakeConc .. (r.shortConc and T.Color("muted", "  until " .. short(r.shortConc) .. " runs out") or "") })
	end
	table.insert(lines, { T.Color("muted", "Counts use the scan's best reagents and finishing reagents, from bags, banks and the warband bank.") })
	table.insert(lines, { "Sold per day, region", r.soldPerDay and string.format("%.1f", r.soldPerDay) or "-" })
	table.insert(lines, { string.format("Gold a day at up to %d sold", CH.db.settings.scan.dailyCap or 10), CH.FormatMoney(r.perDay) })
	local bc = r.bc
	if bc and bc.buy then
		table.insert(lines, { T.Color("accent", "Buy or craft, per item") })
		table.insert(lines, { "  Cheapest listing", CH.FormatMoney(bc.buy) })
		if bc.craft then table.insert(lines, { "  Crafting it", CH.FormatMoney(bc.craft) }) end
		if bc.resell then table.insert(lines, { "  Resells for, after cut", CH.FormatMoney(bc.resell) }) end
		if bc.save and bc.save > 0 then
			table.insert(lines, { "  Buying saves", T.Color("ok", CH.FormatMoney(bc.save)) })
		end
		if bc.flip and bc.flip > 0 then
			table.insert(lines, { "  Buy and relist for", T.Color("ok", "+" .. CH.FormatMoney(bc.flip)) })
		end
		table.insert(lines, { T.Color("muted", "The cheapest listing may be only a few items; check the AH before buying out.") })
	end
	if r.perPoint then table.insert(lines, { T.Color("muted", "Gold a day counts Concentration crafts up to what a day's refill (about 250) pays for.") }) end
	table.insert(lines, { T.Color("muted", "Click to select and open it. Queue it with the buttons under the list.") })
	CH.Window.Tooltip(owner, lines)
end

local fetchNote -- why the last order fetch came back empty, if it did
--- Ask the game for every patron, personal, public and guild order, then redraw.
function SUI.FetchOrders()
	fetchNote = nil
	local started = CH.Orders.Fetch(function(_, why)
		fetchNote = why
		if mode == "orders" then SUI.Refresh() end
	end)
	if mode == "orders" then SUI.Refresh() end
	return started
end
local function setMode(m)
	mode = (mode == m and m ~= "recipes") and "recipes" or m -- a lit list button toggles back to Recipes
	offset = 0
	if mode == "orders" then SUI.FetchOrders() end
	SUI.Refresh()
end
SUI.SetMode = function(m) mode = m; offset = 0; if m == "orders" then SUI.FetchOrders() end return SUI.Refresh() end
function SUI.Mode() return mode end
--- Show or hide older-expansion recipes and orders.
--- Switch the Recipes list's view: "craft", "conc" or "buy". Shows Recipes if another list is up.
function SUI.SetView(v)
	if not COLS[v] or v == "orders" or v == "first" then return {} end
	mode, view, offset = "recipes", v, 0
	return SUI.Refresh()
end
function SUI.View() return view end
function SUI.ToggleOlder() showOlder = not showOlder; offset = 0; return SUI.Refresh() end

--- Sort by a column (as a header click does): a new column sorts it biggest first, the same one flips.
function SUI.SortBy(key)
	local s = SORT[listKey()]
	if s.key == key then s.asc = not s.asc else s.key, s.asc = key, false end
	offset = 0
	return SUI.Refresh()
end

local function build()
	local Wd, T = CH.Window, CH.Theme
	frame = Wd.New("AuctionIQScan", "Crafting", W, 48 + CARD_H + GUT + DETAIL)
	local x = -26
	local function barButton(label, width, fn)
		local b = T.Button(frame.bar, label, width, 18)
		b:SetPoint("RIGHT", x, 0)
		b:SetScript("OnClick", fn)
		x = x - width - 4
		return b
	end
	-- Recipes: Fill queue from the scan, its plan shown on hover first. Orders and first crafts: queue them all.
	SUI.allButton = barButton("Queue all", 72, function() if mode == "recipes" then SUI.Fill() else SUI.QueueAll() end end)
	SUI.allButton:SetScript("OnEnter", function(self) Wd.Tooltip(self, SUI.AllLines()) end)
	SUI.allButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
	SUI.firstButton = barButton("First crafts", 86, function() setMode("first") end)
	SUI.ordersButton = barButton("Work orders", 90, function() setMode("orders") end)
	barButton("Scan", 50, function() SUI.Start() end)
	SUI.olderButton = barButton("Older: shown", 100, function() SUI.ToggleOlder() end)
	-- Work orders: one button that walks the orders: claim, craft, turn in, next order
	SUI.nextButton = barButton("Claim next", 100, function() SUI.Next() end)
	SUI.nextButton:SetScript("OnEnter", function(self) Wd.Tooltip(self, SUI.NextLines()) end)
	SUI.nextButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
	status = Wd.Text(frame, 12, -34, W - 24)
	-- the Recipes views, at the right of the status line
	SUI.viewButtons = {}
	local vx = -12
	for k = #VIEWS, 1, -1 do
		local v = VIEWS[k]
		local b = T.Tab(frame, v[2], v[3], 20)
		b:SetPoint("TOPRIGHT", vx, -28)
		b:SetScript("OnClick", function() SUI.SetView(v[1]) end)
		b.view = v[1]
		vx = vx - v[3] - 4
		SUI.viewButtons[k] = b
	end
	SUI.viewsWidth = -vx
	for m, cols in pairs(COLS) do
		local blank = {}
		for j, c in ipairs(cols) do blank[j] = { "", c[2], c[3], c[5] } end
		tables[m] = Wd.Table(frame, blank, N, -54, H, click, hover, TWR)
		if m == "orders" then
			-- a Claim button at the start of each order's row
			for i, r in ipairs(tables[m]) do
				local b = T.Button(frame, "Claim", 50, H - 2)
				b:SetPoint("TOPLEFT", 10, -54 - i * H + 2)
				local lvl = r.button and r.button.GetFrameLevel and r.button:GetFrameLevel()
				if lvl and b.SetFrameLevel then b:SetFrameLevel(lvl + 2) end
				b:SetScript("OnClick", function()
					-- say what went wrong instead of failing silently (errors are often hidden)
					local ok, err = xpcall(SUI.Claim, debugstack and function(m) return tostring(m) .. "\n" .. debugstack(2, 3, 0) end or tostring, data[i + offset])
					if not ok then CH.Print("that step hit an error: " .. tostring(err)) end
				end)
				b:SetScript("OnEnter", function(self) Wd.Tooltip(self, SUI.ClaimLines(data[i + offset])) end)
				b:SetScript("OnLeave", function() GameTooltip:Hide() end)
				b:Hide()
				r.claim = b
			end
		end
		heads[m] = {}
		for j, c in ipairs(cols) do
			local hb = CreateFrame("Button", nil, frame)
			hb:SetPoint("TOPLEFT", c[2], -52)
			hb:SetSize(c[3], 16)
			hb.text = Wd.OneLine(Wd.Text(frame, c[2], -54, c[3], c[5] or (j == 1 and "LEFT" or "RIGHT"), "GameFontDisableSmall"))
			hb:SetScript("OnClick", function() SUI.SortBy(c[4]) end)
			hb:SetScript("OnEnter", function(self) local tip = { { "Sort by " .. (NAMES[c[4]] or c[1]) } }
				tip[#tip + 1] = { T.Color("muted", "Click again to flip it.") }
				Wd.Tooltip(self, tip) end)
			hb:SetScript("OnLeave", function() GameTooltip:Hide() end)
			hb.key, hb.label = c[4], c[1]
			heads[m][j] = hb
		end
	end
	-- the table on its own dark card, as the design draws it; each row a hairline under it and the
	-- selected one an accent bar on its left
	SUI.tableCard = T.BorderCard(frame, GUT, -48, TWR + 10, CARD_H)
	for _, rows in pairs(tables) do
		for i, r in ipairs(rows) do
			local ry = -54 - i * H
			local line = frame:CreateTexture(nil, "BACKGROUND", nil, 3)
			line:SetPoint("TOPLEFT", 7, ry + 3 - H)
			line:SetSize(TWR + 8, T.Px(frame))
			line:SetColorTexture(0, 0, 0, 0.6)
			r.line = line
			local mark = frame:CreateTexture(nil, "ARTWORK")
			mark:SetPoint("TOPLEFT", 7, ry + 3)
			mark:SetSize(2, H)
			T.AccentTexture(mark)
			mark:Hide()
			r.mark = mark
		end
	end
	scrollBar = Wd.ScrollBar(frame, W - 8, -70, N * H)
	SUI.scrollBar = scrollBar
	-- The selected recipe, in a side panel right of the list (the Craft page's Next Move panel):
	-- what it makes and costs at today's prices, its reagents at what they cost you, craft or sell,
	-- and the Queue buttons, with a quantity stepper on the card
	detail = Wd.SidePanel(frame, SIDE, CARD_H, { rows = 5, srows = 7, buttons = 4,
		onAction = function(self) self.run() end, stepper = function(d) SUI.SetQty(qty + d) end })
	detail:SetPoint("TOPLEFT", W - SIDE - GUT, -48)
	SUI.BuildDetails()
	frame:EnableMouseWheel(true)
	frame:SetScript("OnMouseWheel", function(_, d)
		offset = math.max(0, math.min(math.max(0, #data - N), offset - d * 3))
		SUI.Refresh()
		scrollBar:Set(offset, N, #data)
	end)
	T.Fonts(frame)
	Wd.Attach("scan", frame)
end

-- Details: one item, over the list -----------------------------------------------------------------
local details -- the Details view, over the table while it's on
local detailsOn = false
local DW, DH = TWR + 10, N * H + 28 -- the table card's size: the view covers it exactly
local GAP, PAD = 6, 10

-- A section card of the Details view: a heading, a verdict line and label / value rows.
local function section(parent, x, y, w, nRows, vw)
	vw = vw or 100
	local Wd, T = CH.Window, CH.Theme
	local sc = { x = x, y = y, w = w }
	sc.card = T.BorderCard(parent, x, y, w, 40)
	sc.head = Wd.OneLine(Wd.Text(parent, x + PAD, y - 8, w - 2 * PAD, "LEFT", "GameFontNormalSmall"))
	T.TitleFont(sc.head, 10, "bold")
	sc.verdict = Wd.OneLine(Wd.Text(parent, x + PAD, y - 22, w - 2 * PAD, "LEFT", "GameFontHighlightSmall"))
	sc.rows = {}
	for k = 1, nRows do
		local ry = y - 40 - (k - 1) * 14
		-- label and value never share pixels: the value takes the right vw, the label the rest less 4
		local r = { label = Wd.OneLine(Wd.Text(parent, x + PAD, ry, w - 2 * PAD - vw - 4, "LEFT", "GameFontHighlightSmall")),
			value = Wd.OneLine(Wd.Text(parent, x + w - PAD - vw, ry, vw, "RIGHT", "GameFontHighlightSmall")) }
		r.label:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
		r.hit = CreateFrame("Button", nil, parent)
		r.hit:SetPoint("TOPLEFT", x + 2, ry + 1)
		r.hit:SetSize(w - 4, 14)
		r.hit:SetScript("OnEnter", function(self) if self.tip then Wd.Tooltip(self, self.tip) end end)
		r.hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
		sc.rows[k] = r
	end
	return sc
end

local function fillSection(sc, head, d)
	local T = CH.Theme
	sc.head:SetText(T.Color("accent", head))
	sc.verdict:SetText(d and d.verdict or "")
	local n = 0
	for k, r in ipairs(sc.rows) do
		local x = d and d.rows and d.rows[k]
		r.label:SetText(x and x[1] or ""); r.value:SetText(x and x[2] or "")
		r.hit.tip = x and x.tip or nil
		r.hit:SetShown(x ~= nil and x.tip ~= nil)
		if x then n = k end
	end
	return n
end

--- Build the Details view: a back bar, the break-even chart, then Price check and Will it sell side
--- by side, then What drives the cost. Every block sits on the table card's grid, 6 px apart.
function SUI.BuildDetails()
	local Wd, T = CH.Window, CH.Theme
	details = CreateFrame("Frame", nil, frame)
	details:SetPoint("TOPLEFT", 6, -48)
	details:SetSize(DW, DH)
	details:SetFrameLevel((frame.GetFrameLevel and frame:GetFrameLevel() or 1) + 20)
	details:EnableMouse(true) -- the list under it takes no clicks
	details.bg = details:CreateTexture(nil, "BACKGROUND")
	details.bg:SetAllPoints()
	details.bg:SetColorTexture(0.059, 0.059, 0.059, 1)
	local back = T.Button(details, "< Back", 64, 18)
	back:SetPoint("TOPLEFT", 0, 0)
	back:SetScript("OnClick", function() SUI.SetDetails(false) end)
	details.title = Wd.OneLine(Wd.Text(details, 72, -3, DW - 72, "LEFT", "GameFontNormal"))
	details.title:SetTextColor(CH.Theme.accent[1], CH.Theme.accent[2], CH.Theme.accent[3])
	-- the chart, full width
	local cy = -18 - GAP
	local CH_H = 150
	details.chartCard = T.BorderCard(details, 0, cy, DW, CH_H)
	details.chartHead = Wd.OneLine(Wd.Text(details, PAD, cy - 8, DW - 2 * PAD, "LEFT", "GameFontNormalSmall"))
	T.TitleFont(details.chartHead, 10, "bold")
	local chart = CreateFrame("Frame", nil, details)
	chart:SetPoint("TOPLEFT", 0, cy - 20)
	chart:SetSize(DW, CH_H - 20)
	-- the plot is ch - 62 tall; its axis labels end 30 px above the card's bottom, for two foot lines
	chart.cw, chart.ch = DW, CH_H - 16
	chart.dots, chart.labels = {}, {}
	for i = 1, 8 do chart.labels[i] = Wd.OneLine(Wd.Text(chart, 12, -16, 120)) end
	details.foot = { Wd.OneLine(Wd.Text(details, PAD, cy - CH_H + 26, DW - 2 * PAD)), Wd.OneLine(Wd.Text(details, PAD, cy - CH_H + 14, DW - 2 * PAD)) }
	details.chart = chart
	-- price check and will it sell, side by side
	local y2 = cy - CH_H - GAP
	local half = math.floor((DW - GAP) / 2)
	details.price = section(details, 0, y2, half, 4)
	details.sell = section(details, half + GAP, y2, DW - half - GAP, 4)
	-- what drives the cost, full width, to the bottom
	details.y3 = y2 - (40 + 4 * 14 + 6) - GAP
	details.cost = section(details, 0, details.y3, DW, 5, 170)
	T.Fonts(details)
	details:Hide()
end

--- Turn the Details view on or off for the selected recipe. Returns what it drew, for tests.
function SUI.SetDetails(on)
	detailsOn = on and true or false
	return SUI.Refresh()
end
function SUI.DetailsOn() return detailsOn end
function SUI.DetailsShown() return details ~= nil and details:IsShown() end

local function renderDetails()
	if not details then return nil end
	local A = CH.AdvisorUI
	local cur = A and A.Current()
	local live = mode == "recipes" and detailsOn and cur and cur.recipeID == selected and not cur.order and not A.Classic()
	local d = live and A.Details(qty, selectedRow()) or nil
	details:SetShown(d ~= nil)
	if scrollBar and scrollBar.SetShown then scrollBar:SetShown(d == nil) end
	if not d then return nil end
	local T = CH.Theme
	details.title:SetText(T.Color("accent", d.title) .. T.Color("muted", "  details"))
	details.chartHead:SetText(T.Color("accent", "BREAK-EVEN") .. T.Color("muted", "   profit a craft against the sale price"))
	if d.chart then
		A.DrawChart(details.chart, d.chart)
		details.chart:Show()
	else
		details.chart:Hide()
	end
	-- each series' break-even, one line each under the chart
	local foot = d.chartLines or {}
	details.foot[1]:SetText(foot[1] or T.Color("muted", "No price to chart yet."))
	details.foot[2]:SetText(foot[2] or "")
	local np = fillSection(details.price, "PRICE CHECK", d.price)
	local ns = fillSection(details.sell, "WILL IT SELL?", d.sell)
	local hh = 40 + math.max(np, ns, 1) * 14 + 6
	details.price.card:Place(details.price.x, details.price.y, details.price.w, hh)
	details.sell.card:Place(details.sell.x, details.sell.y, details.sell.w, hh)
	local nc = fillSection(details.cost, "WHAT DRIVES THE COST", d.cost)
	details.cost.card:Place(details.cost.x, details.cost.y, details.cost.w, 40 + math.max(nc, 1) * 14 + 6)
	SUI.lastDetails = d
	return d
end

-- Show only the active list's table and headers, with an arrow on the sorted column.
local function showTable()
	local T = CH.Theme
	for m, rows in pairs(tables) do
		local on = m == listKey()
		for _, r in ipairs(rows) do
			for _, c in ipairs(r.cells) do c:SetText("") end
			if r.button then r.button:SetShown(on) end
			if r.claim and not on then r.claim:Hide() end
			if not on then r.bg:Hide() end
		end
		for _, hb in ipairs(heads[m]) do
			hb:SetShown(on)
			local sorted = on and SORT[m].key == hb.key
			local label = m == "orders" and hb.key == "concentration" and CH.Window.ConcIcon(14) or hb.label
			label = label:find("|T") and label or label:upper()
			hb.text:SetText(not on and "" or sorted and T.Color("accent", label .. (SORT[m].asc and " ^" or " v")) or label)
		end
	end
	if SUI.olderButton then
		SUI.olderButton:SetShown(mode == "recipes" or mode == "orders")
		SUI.olderButton:SetText(showOlder and "Older: shown" or "Older: hidden")
	end
	if SUI.allButton then SUI.allButton:SetText(mode == "recipes" and "Fill queue" or "Queue all") end
	if SUI.nextButton then SUI.nextButton:SetShown(mode == "orders"); SUI.UpdateNext() end
	for m, b in pairs({ orders = SUI.ordersButton, first = SUI.firstButton }) do
		if b and b.SetAlpha then b:SetAlpha(mode == m and 1 or 0.65) end
	end
	for _, b in ipairs(SUI.viewButtons or {}) do
		T.SetTab(b, mode == "recipes" and view == b.view)
		-- one list: the card's Which quality? answers Concentration and buy or make
		b:SetShown(SUI.ShowViews == true)
	end
	if scrollBar and scrollBar.SetX then scrollBar:SetX(TWR + 4) end
	if SUI.tableCard then SUI.tableCard:Place(6, -48, TWR + 10, N * H + 28) end
	for m, rows in pairs(tables) do
		local on = m == listKey()
		for _, r in ipairs(rows) do
			if r.line then
				r.line:SetShown(on)
				r.line:SetWidth(TWR + 8)
			end
			if r.mark then r.mark:Hide() end
		end
	end
	return tables[listKey()]
end

--- The bar's queue button, on hover: in Recipes, the restock plan Fill queue would add (a dry run);
--- in Work orders and First crafts, what Queue all adds.
function SUI.AllLines()
	local T, M = CH.Theme, CH.FormatMoney
	if mode == "orders" then
		return { { "Queue eligible orders" }, { T.Color("muted", "Queue the listed orders that pay, or give knowledge, with reagents you have.") } }
	elseif mode == "first" then
		local n, cost = 0, 0
		for _, d in ipairs(data) do n = n + 1; cost = cost + (d.cost or 0) end
		local out = { { "Queue every first craft" }, { T.Color("muted", "Once each at its cheapest, for the first-craft knowledge point.") } }
		if n > 0 then table.insert(out, { "  " .. n .. " knowledge points", M(cost) .. T.Color("muted", n > 0 and ("  " .. M(math.floor(cost / n + 0.5)) .. " a point") or "") }) end
		return out
	end
	local out = { { "Review restock plan" } }
	local prof = CH.OpenProfessionID and CH.OpenProfessionID()
	local plan, why
	if prof then plan, why = CH.Queue.FillPlan(prof, { dry = true }) end
	if not plan then
		table.insert(out, { T.Color("muted", why or "Open a profession to plan from its scan.") })
		return out
	end
	if not plan.entries[1] then
		table.insert(out, { T.Color("muted", "Nothing to add: no craft profits within what sells in a day, less what you own.") })
		return out
	end
	for i, x in ipairs(plan.entries) do
		if i > 10 then table.insert(out, { T.Color("muted", "  and " .. (#plan.entries - 10) .. " more") }); break end
		table.insert(out, { "  " .. (x.name or "?") .. " x" .. x.n .. (x.conc and (" " .. CH.Window.ConcIcon(12)) or ""), T.Color(x.profit >= 0 and "ok" or "bad", M(x.profit)), "fg", "fg" })
	end
	table.insert(out, { string.format("%d Concentration crafts (%d of %d points), %d without", plan.conc, math.floor(plan.points + 0.5), plan.budget, plan.plain), M(plan.profit), "ok", "muted" })
	table.insert(out, { T.Color("muted", "Concentration crafts first, best gold per point; then crafts that profit without it. Each up to what sells in a day (/aiq cap), less what you own. Click to queue them.") })
	return out
end

--- Fill the queue from the open profession's scan (Queue.FillPlan).
function SUI.Fill()
	local prof = CH.OpenProfessionID and CH.OpenProfessionID()
	local plan, why
	if prof then plan, why = CH.Queue.FillPlan(prof) end
	if plan then
		CH.Print(string.format("queued %d Concentration crafts (%d of %d points) and %d without, about %s profit.",
			plan.conc, math.floor(plan.points + 0.5), plan.budget, plan.plain, CH.FormatMoney(plan.profit)))
	else
		CH.Print(why or "open a profession to fill the queue from its scan.")
	end
	return plan
end

--- Queue every work order that pays or gives knowledge, or every first craft. Returns how many.
function SUI.QueueAll()
	local n = 0
	for _, d in ipairs(data) do
		if mode == "first" or (mode == "orders" and d.ok and d.have and ((d.profit or 0) >= 0 or d.kp)) then
			if queueRow(d) then n = n + 1 end
		end
	end
	if n == 0 then CH.Print(mode == "first" and "no first crafts to queue" or "no work orders pay or give knowledge with reagents you have") end
	return n
end

-- The next order step, for the one-button walk through the queued orders.
local function nextOrder()
	local e, step = CH.Queue.NextStep()
	if e and e.orderID then return e, step end
end

function SUI.UpdateNext()
	local b = SUI.nextButton
	if not b then return end
	local _, step = nextOrder()
	local label = (step == "Turn in" and "Turn in next") or (step == "Craft" and "Craft next") or (step == "Shatter" and "Shatter next") or "Claim next"
	if b.text then b.text:SetText(label) elseif b.SetText then b:SetText(label) end
end

function SUI.NextLines()
	local T = CH.Theme
	local e, step = nextOrder()
	local lines = { { "Next step" } }
	if e then
		table.insert(lines, { step .. ": " .. (e.name or "?"), e.customer or "" })
	else
		table.insert(lines, { T.Color("muted", "Nothing queued yet: the first click queues every order that pays or gives knowledge.") })
	end
	table.insert(lines, { T.Color("muted", "Each click does one step: claim the order, craft it with the advisor's reagents, turn it in, then the next order.") })
	return lines
end

local claimedID, claimedRow -- the order we asked the game to claim, to show it once the game says yes

--- One click, one step through the work orders. Queues the worthwhile orders first if none are.
function SUI.Next()
	if not nextOrder() then
		local before = CH.Queue.Count()
		SUI.QueueAll()
		if CH.Queue.Count() == before then
			CH.Print("no work order to start: none pays or gives knowledge at a rank you can reach. Type /aiq orders to see why for each.")
			return
		end
	end
	local step, e = CH.Queue.DoNext()
	if step == "Claim" then
		-- show the claimed order once the game says yes, as it does when you claim it yourself
		claimedID, claimedRow = e.orderID, { concentration = e.concentration }
	end
	if step then
		-- claimed / turned in are said when the game confirms them
		CH.Print(string.format("%s: %s", step == "Turn in" and "turning in" or step == "Claim" and "claiming" or step == "Shatter" and "shattering a mote before" or "crafting", e.name or "?"))
	elseif e then
		CH.Print(e)
	end
	SUI.UpdateNext()
end

-- Claiming an order from its row ---------------------------------------------------------------
local function redraw()
	if frame and frame:IsShown() and mode == "orders" then SUI.Refresh() end
end


local function claimedOrder()
	local co = C_CraftingOrders
	return co and co.GetClaimedOrder and co.GetClaimedOrder()
end

--- What an order row's button does next, as CraftSim's does: "claim", "craft" (it's yours: crafts
--- it with the advisor's reagents and Concentration), "turnin" (crafted), or "busy" (another order is
--- claimed: the game allows one at a time).
function SUI.ClaimState(d)
	if not (d and d.orderID) then return nil end
	-- asked the game and waiting for its answer: Claiming..., Crafting..., Turning in...
	local qe = CH.Queue.ForOrder(d.orderID)
	if qe and CH.Queue.Pending(qe) then return "pending" end
	local c = claimedOrder()
	if c and CH.Orders.Same(c.orderID, d.orderID) then
		if c.isFulfillable then return "turnin" end
		return CH.Queue.NeedsShatter(d.recipeID) and "shatter" or "craft"
	end
	return c and "busy" or "claim"
end

local LABELS = { claim = "Claim", busy = "Claim", shatter = "Shatter", craft = "Craft", turnin = "Turn in", pending = "Waiting..." }
--- The button's text; while the game is answering, what it's doing (Claiming..., Crafting..., Turning in...).
function SUI.ClaimLabel(state, d)
	if state == "pending" and d then
		local qe = CH.Queue.ForOrder(d.orderID)
		local w = qe and CH.Queue.Pending(qe)
		if w then return CH.Queue.PENDING_LABEL[w] end
	end
	return LABELS[state]
end

function SUI.ClaimLines(d)
	local T, M = CH.Theme, CH.FormatMoney
	local state = SUI.ClaimState(d)
	if not state then return { { "Claim" } } end
	local lines = { { SUI.ClaimLabel(state, d) .. " " .. (d.name or "the order"), d.customer or d.from or "" } }
	if state == "pending" then
		table.insert(lines, { T.Color("muted", "Waiting for the game to confirm. If it says no, the order stays queued so you can try again.") })
	elseif state == "shatter" then
		local id = CH.Queue.ShatterItem()
		local name = id and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
		table.insert(lines, { T.Color("muted", "Casts Shatter on " .. (id and (CH.Window.ItemIcon(id, 12) .. (name or "a mote")) .. " (your cheapest mote)" or "a mote")
			.. " for Shattering Essence: more Resourcefulness, Multicraft and Ingenuity on the craft. Then the button crafts.") })
		if not id then table.insert(lines, { T.Color("bad", "You have no mote to Shatter.") }) end
	elseif state == "craft" then
		table.insert(lines, { T.Color("muted", "Crafts it into the order with the advisor's reagents"
			.. (d.concentration and (" and " .. CH.Window.ConcIcon(12) .. " " .. math.floor(d.concentration + 0.5) .. " Concentration") or "") .. ".") })
	elseif state == "turnin" then
		table.insert(lines, { T.Color("muted", "Turns the order in for " .. M(d.commission or 0) .. " and its rewards.") })
	elseif state == "busy" then
		table.insert(lines, { T.Color("bad", "You already have an order claimed. Turn it in or release it first.") })
	else
		table.insert(lines, { T.Color("muted", "Claims the order. The button then crafts it, then turns it in.") })
		if not d.ok then table.insert(lines, { T.Color("bad", "AuctionIQ couldn't work this one out: craft it from the order's page.") }) end
	end
	return lines
end

-- the order's queue entry, queueing it first if it isn't (so the queue's craft and turn-in do the work)
local function entryFor(d)
	local e = CH.Queue.ForOrder(d.orderID)
	if not e and d.ok and d.row and d.result then
		e = CH.Queue.Add(d.result, d.row, 1, { orderID = d.orderID, customer = d.from, special = d.kp })
	end
	return e
end

--- One click, one step for this order: claim it, craft it, turn it in. Must be called from a click.
function SUI.Claim(d)
	local state = SUI.ClaimState(d)
	if not state then return false end
	if state == "busy" then
		CH.Print("you already have an order claimed: turn it in or release it before claiming another.")
		return false
	end
	if state == "pending" then
		CH.Print("still waiting for the game to confirm the last step on " .. (d.name or "that order") .. ".")
		return false
	end
	if state == "claim" then
		local o = CH.Orders.Live(d.orderID)
		if not o then
			CH.Print("that order isn't listed any more: click Work orders to fetch them again.")
			return false
		end
		local qe = entryFor(d)
		claimedID, claimedRow = o.orderID, d
		if qe then
			-- the queue claims it, marks it Claiming..., and moves on when the game says yes
			local ok, why = CH.Queue.Craft(qe)
			if not ok then claimedID, claimedRow = nil, nil; CH.Print("can't claim " .. (d.name or "that order") .. ": " .. tostring(why)) end
			redraw()
			return ok
		end
		local ui = C_TradeSkillUI
		local info = ui and ui.GetChildProfessionInfo and ui.GetChildProfessionInfo()
		claimedID, claimedRow = o.orderID, d
		C_CraftingOrders.ClaimOrder(o.orderID, info and info.profession)
		return true
	end
	if state == "shatter" then
		-- Shatter needs no plan for the order: just the buff
		local ok, why = CH.Queue.Shatter()
		if not ok then CH.Print("can't Shatter: " .. tostring(why)) end
		return ok
	end
	local e = entryFor(d)
	if not e then
		-- nothing AuctionIQ can craft for it: leave it to the order's page
		CH.Orders.Open(claimedOrder(), d.recipeID, d.concentration ~= nil)
		CH.Print("AuctionIQ can't craft " .. (d.name or "that order") .. " for you: use the order's page.")
		return false
	end
	local ok, why = CH.Queue.Craft(e)
	if not ok then CH.Print("can't " .. LABELS[state]:lower() .. " " .. (d.name or "that order") .. " yet: " .. tostring(why)); redraw(); return false end
	-- "turned in" is said when the game confirms it, not here
	redraw()
	return true
end

CH.On("CRAFTINGORDERS_CLAIM_ORDER_RESPONSE", function(_, result, orderID)
	if not claimedID or not CH.Orders.Same(claimedID, orderID) then return end
	claimedID = nil
	local ok = Enum and Enum.CraftingOrderResult and Enum.CraftingOrderResult.Ok or 0
	if result ~= nil and result ~= ok then
		-- a queued order's refusal is told by the queue; only say it for one AuctionIQ couldn't queue
		if not CH.Queue.ForOrder(orderID) then
			CH.Print("the game didn't let you claim that order (" .. tostring(result) .. "). Someone may have taken it.")
		end
	else
		local o = CH.Orders.Live(orderID)
		if o then CH.Orders.Open(o, nil, claimedRow and claimedRow.concentration ~= nil) end
	end
	claimedRow = nil
	redraw()
end)
-- the button moves on (Craft, Turn in) as the game updates the claimed order
CH.On("CRAFTINGORDERS_CLAIMED_ORDER_UPDATED", function() redraw() end)
-- released (Cancel Order) or timed out: back to Claim, and the other orders can be claimed again
CH.On("CRAFTINGORDERS_RELEASE_ORDER_RESPONSE", function() redraw(); SUI.UpdateNext() end)
CH.On("CRAFTINGORDERS_CLAIMED_ORDER_REMOVED", function() redraw(); SUI.UpdateNext() end)
-- and to Craft once Shatter's buff lands
local hadShatter
CH.On("UNIT_AURA", function(_, unit)
	if unit ~= "player" then return end
	local has = CH.Queue.HasShatterBuff()
	if has ~= hadShatter then hadShatter = has; redraw() end
end)
CH.On("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", function()
	redraw()
	-- the list changes once the game takes it: fetch again for the next order
	if C_Timer then C_Timer.After(1, SUI.FetchOrders) end
end)
CH.On("UNIT_SPELLCAST_SUCCEEDED", function(_, unit)
	if unit == "player" and C_Timer then C_Timer.After(0.8, redraw) end
end)

-- Work orders and first crafts.
local function refreshLists()
	local T = CH.Theme
	local rows = showTable()
	local list, older = mode == "orders" and CH.Orders.List() or CH.Orders.FirstCrafts(), 0
	if mode == "orders" then
		-- orders from older expansions show a tag, and "Older: hidden" leaves them out
		local keep = {}
		for _, d in ipairs(list) do
			if not d.current then older = older + 1 end
			if d.current or showOlder then table.insert(keep, d) end
		end
		list = keep
	end
	data = sortRows(list, SORT[mode].key, SORT[mode].asc) -- mode is orders or first here
	offset = math.max(0, math.min(offset, #data - N))
	scrollBar:Set(offset, N, #data)
	if mode == "orders" then
		local pays, kp = 0, 0
		for _, d in ipairs(data) do
			if d.ok and (d.profit or 0) >= 0 then pays = pays + 1 end
			if d.kp then kp = kp + 1 end
		end
		local fetching = CH.Orders.fetching and T.Color("accent", "  Fetching orders from the game...") or ""
		local olderNote = older > 0 and T.Color("muted", showOlder and string.format("   %d from older expansions", older)
			or string.format("   %d older-expansion orders hidden", older)) or ""
		local total = 0
		for _, d in ipairs(data) do if d.ok and (d.profit or 0) > 0 then total = total + d.profit end end
		status:SetText(#data > 0 and string.format("%d Total Work Orders: %s profit, %s KP", #data, T.Color("ok", CH.FormatMoney(total)), T.Color("accent", kp)) .. olderNote .. fetching
			or fetching ~= "" and fetching
			or T.Color("muted", "No work orders found" .. (fetchNote and ": " .. fetchNote or " for this profession right now") .. ". Click Work orders twice to fetch again."))
	else
		local cost = 0
		for _, d in ipairs(data) do if d.net and d.net < 0 then cost = cost - d.net end end
		status:SetText(#data > 0 and string.format("%d first crafts left (%s knowledge points), %s to make them all after selling what they make",
			#data, T.Color("accent", #data), CH.FormatMoney(cost))
			or T.Color("muted", "No first crafts left in this profession, or open a profession to see them."))
	end
	local out = {}
	for i, r in ipairs(rows) do
		local d = data[i + offset]
		local sel = d ~= nil and SUI.selRow ~= nil and SUI.RowKey(d) == SUI.selRow
		r.bg:SetShown(sel)
		if r.mark then r.mark:SetShown(sel) end
		if r.claim then
			local state = d and mode == "orders" and SUI.ClaimState(d)
			r.claim:SetShown(state and true or false)
			if state then
				r.claim:SetText(SUI.ClaimLabel(state, d))
				if r.claim.SetAlpha then r.claim:SetAlpha((state == "busy" or state == "pending") and 0.45 or 1) end
			end
		end
		if d and mode == "orders" then
			r.cells[1]:SetText(CH.Window.ItemIcon(d.item, 15) .. (d.current and "" or T.Color("muted", "[" .. (d.expansion or "older") .. "] ")) .. (d.name or "?")
				.. (d.minQuality and (" " .. CH.Window.QualityIcon(d.minQuality, 14, d.tiers) .. "+") or "") .. kpTag(d.kp))
			r.cells[2]:SetText(d.customer or d.from)
			r.cells[3]:SetText(d.ok and money(d.profit) or T.Color("bad", d.learned == false and "not learned" or d.unpriced and "no price" or "can't reach"))
			-- the Concentration the craft needs, as CraftSim: 0 when its reagents (and Shatter) reach the rank
			r.cells[4]:SetText(d.ok and tostring(math.floor((d.concentration or 0) + 0.5)) or T.Color("muted", "-"))
			-- already crafted: what's left is handing it in, not whether you can reach it
			if SUI.ClaimState(d) == "turnin" then
				r.cells[3]:SetText(T.Color("ok", "crafted"))
				r.cells[4]:SetText("")
			end
			table.insert(out, string.format("%s from=%s profit=%s kp=%s", d.name, d.from, d.profit and math.floor(d.profit) or "-", tostring(d.kp)))
		elseif d then
			r.cells[1]:SetText(CH.Window.ItemIcon(d.item, 15) .. (d.name or "?") .. kpTag(true))
			r.cells[2]:SetText(d.value and CH.FormatMoney(d.value) or T.Color("muted", "no price"))
			r.cells[3]:SetText(d.net and (d.net >= 0 and T.Color("ok", "free, +" .. CH.FormatMoney(d.net)) or T.Color("bad", CH.FormatMoney(-d.net))) or T.Color("muted", "-"))
			table.insert(out, string.format("%s net=%s", d.name, d.net and math.floor(d.net) or "-"))
		end
	end
	SUI.RenderPanel()
	return out
end

--- Redraw from the saved scan. Returns the row texts, for tests.
-- Side cards: each view's card answers the one question the view is for, about the selected row.
-- { kicker, title, sub, figures, rows, section, note, actions } for Window.DrawSidePanel.

-- A reagent list as the card's section rows: each at what it costs you, yours marked with *, each
-- hovering its opportunity cost, stock and prices. From a scan's accounts.
local function reagentRows(acc)
	local T = CH.Theme
	local rows, rbook = {}, acc and (CH.ReagentBook(acc)) or nil
	local list = acc and acc.reagents or {}
	local P = CH.Prices
	for k, rg in ipairs(list) do
		if k > 4 and #list > 5 then rows[#rows + 1] = { string.format("%d more", #list - 4), "", tip = rbook }; break end
		local one = CH.ReagentBook({ reagents = { rg } })
		local held = P.Held and P.Held(rg.itemID) or 0
		local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(rg.itemID)) or ("item " .. rg.itemID)
		local q = rg.rank and rg.tiers and rg.tiers > 1 and (" " .. CH.Window.QualityIcon(rg.rank, 12, rg.tiers)) or ""
		local tip = { { T.Color("accent", name) .. q } }
		for j = 2, #one do tip[#tip + 1] = one[j] end
		rows[#rows + 1] = { (held > 0 and T.Color("accent", "* ") or "") .. string.format("%gx %s%s", rg.n or 0, name, q), one[2] and one[2][2] or "-", tip = tip }
	end
	return rows, rbook
end

-- The same from an order's or first craft's cost lines (Advisor.CostLines, with what you hold).
local function costLineRows(lines)
	local T, M = CH.Theme, CH.FormatMoney
	local rows = {}
	for k, l in ipairs(lines or {}) do
		if k > 4 and #lines > 5 then rows[#rows + 1] = { string.format("%d more", #lines - 4), "" }; break end
		local q = l.rank and l.tiers and l.tiers > 1 and (" " .. CH.Window.QualityIcon(l.rank, 12, l.tiers)) or ""
		local tip = { { T.Color("accent", l.name or "?") .. q } }
		for _, t in ipairs(CH.Advisor.HeldText(l)) do tip[#tip + 1] = t end
		if #tip == 1 then tip[#tip + 1] = { "Price each", l.unit and M(l.unit) or "-" } end
		rows[#rows + 1] = { ((l.own or 0) > 0 and T.Color("accent", "* ") or "") .. string.format("%gx %s%s", l.n or 0, l.name or "?", q),
			l.total and ("-" .. M(l.total)) or T.Color("bad", "no price"), tip = tip }
	end
	return rows
end

local function figure(label, v, tip, color)
	local T = CH.Theme
	if v == nil then return { label, T.Color("muted", "-"), tip = tip } end
	return { label, color and T.Color(color, CH.FormatMoney(v)) or money(v), tip = tip }
end

local HELD_NOTE = "* you hold some: they cost what they'd sell for, since selling them is what crafting gives up."

--- Craft view: craft it, or sell the reagents you hold?
function SUI.RecipePanel(r, n, v)
	if not r or r.header then return nil end
	v = v or view
	if v == "conc" then return SUI.ConcPanel(r, n) elseif v == "buy" then return SUI.BuyPanel(r, n) end
	local T, M = CH.Theme, CH.FormatMoney
	n = n or qty
	-- the recipe open in the profession window: the advisor's live card, with its qualities
	local live = SUI.LiveCard(r.recipeID, n, r)
	if live then return live end
	local acc = r.accounts or r.concAccounts
	local book, profit = acc and CH.CraftBook(acc)
	local rbook, rcost
	if acc then rbook, rcost = CH.ReagentBook(acc) end
	local cs = acc and CH.CraftOrSell(acc)
	local csTip = cs and CH.CraftOrSellBook(acc) or { { "Craft or sell?" }, { T.Color("muted", "You hold none of this craft's reagents, so there's nothing to sell instead.") } }
	local verdict = not cs and T.Color("muted", "You hold none of its reagents: crafting is the only use.")
		or cs.verdict == "even" and T.Color("fg", "About even: craft it, or sell the reagents for about the same.")
		or cs.gain >= 0 and T.Color("ok", "Craft it: earns " .. M(cs.gain) .. " more than selling your reagents.")
		or T.Color("bad", "Sell the reagents: they earn " .. M(-cs.gain) .. " more than crafting.")
	-- what you paid is sunk: say what the choice costs against it, when they've lost value
	if cs and cs.paid and math.max(cs.sell, cs.craft) < cs.paid then
		verdict = verdict .. T.Color("muted", " Below what you paid: you lose " .. M(cs.paid - math.max(cs.sell, cs.craft)) .. " either way.")
	end
	local figures = { figure("PROFIT", profit or r.profit, book, (profit or r.profit or 0) >= 0 and "ok" or "bad"),
		figure("COST", rcost, rbook),
		-- craft or sell is the sentence above: its numbers are on that sentence's hover
		{ "MARGIN", r.pct and T.Color(r.pct >= 0 and "ok" or "bad", string.format("%d%%", math.floor(r.pct * 100 + 0.5))) or T.Color("muted", "-"),
			tip = { { "Margin" }, { T.Color("muted", "Profit over what the reagents cost: what each gold spent on a craft brings back on top.") } } } }
	local rows = {
		{ "Sold a day, region", r.soldPerDay and string.format(r.soldPerDay >= 100 and "%.0f" or "%.1f", r.soldPerDay) or T.Color("muted", "-") },
		{ "Gold a day", r.perDay and money(r.perDay) or T.Color("muted", "-"), tip = r.perDay and CH.AdvisorUI and CH.AdvisorUI.PerDayTip and CH.AdvisorUI.PerDayTip(r) or nil } }
	if cs and cs.paid then table.insert(rows, 1, { "You paid for yours", M(cs.paid) }) end
	local srows = reagentRows(acc)
	local function act(conc)
		local ok, why = SUI.ScanEntry(r, conc)
		local what = string.format("%d %s", n, n == 1 and "craft" or "crafts")
		local label = conc and ("Queue " .. what .. " with Conc.") or ("Queue " .. what)
		local tip = conc and "Adds the Concentration craft, with the reagents the scan picked." or "Adds the plain craft, with the reagents the scan picked."
		-- more than your bags cover: say how many you can make now, and what runs short
		local can, shortID = r.canMake, r.shortItem
		if conc then can, shortID = r.canMakeConc, r.shortConc or r.shortItem end
		if can and can < n then
			label = string.format(conc and "Queue %d w/ Conc. · Max %d" or "Queue %d · Max %d", n, can)
			local nm = shortID and C_Item.GetItemNameByID and C_Item.GetItemNameByID(shortID)
			tip = tip .. " You have the reagents for " .. can .. " of the " .. n .. " now"
				.. (shortID and ("; " .. (nm or "a reagent") .. " runs short first") or "") .. ". The Shopping list has the rest."
		end
		return { label = label, tip = tip,
			off = not ok and (why:sub(1, 1):upper() .. why:sub(2) .. ".") or nil,
			run = function() return SUI.QueueSelected(conc, n, r) end }
	end
	return { kicker = "CRAFT OR SELL?", title = r.name or "?", sub = verdict, subTip = csTip,
		figures = figures, bar = cs and math.max(0, math.min(1, cs.craft / math.max(1, cs.craft + cs.sell))) or nil,
		rows = rows, section = { head = "REAGENTS, AT WHAT THEY COST YOU", rows = srows },
		note = T.Color("muted", HELD_NOTE), actions = { act(false) }, act = act }
end

--- Concentration view: is the Concentration worth spending on this craft?
function SUI.ConcPanel(r, n)
	local T, M = CH.Theme, CH.FormatMoney
	n = n or qty
	local acc = r.concAccounts
	local plainBook = r.accounts and CH.CraftBook(r.accounts, "Without Concentration")
	local concBook = acc and CH.CraftBook(acc, "With Concentration")
	local extra = r.concProfit and (r.concProfit - math.max(0, r.profit or 0))
	local prof = CH.OpenProfessionID and CH.OpenProfessionID() and CH.Me().professions[CH.OpenProfessionID()]
	local have = prof and CH.ConcentrationNow and CH.ConcentrationNow(prof)
	local need = r.concentration or 0
	local rows = { { "Points a craft", need > 0 and tostring(need) or T.Color("muted", "-") },
		{ "You have now", have and tostring(math.floor(have)) or T.Color("muted", "-") },
		{ "Crafts it covers", r.canMakeConc and tostring(r.canMakeConc) or T.Color("muted", "-") } }
	if have and CH.CONC_PER_HOUR and CH.CONC_PER_HOUR > 0 and need > 0 then
		local short = need - have
		rows[#rows + 1] = { short > 0 and "Enough for one in" or "Refill a craft's worth", string.format("%.0f h", math.max(0, short > 0 and short or need) / CH.CONC_PER_HOUR) }
	end
	local verdict = not extra and T.Color("muted", "No Concentration craft lifts the quality.")
		or extra > 0 and T.Color("ok", string.format("Worth it: +%s a craft, %s a point.", M(extra), M(r.gainPerPoint or 0)))
		or T.Color("bad", "Not worth it: the plain craft earns as much.")
	local p = SUI.RecipePanel(r, n, "craft")
	return { kicker = "WORTH THE CONCENTRATION?", title = r.name or "?", sub = verdict,
		figures = { figure("PLAIN", r.profit, plainBook, (r.profit or 0) >= 0 and "ok" or "bad"),
			figure("WITH CONC.", r.concProfit, concBook, (r.concProfit or 0) >= 0 and "ok" or "bad"),
			figure("EXTRA/PT", r.gainPerPoint, nil, (r.gainPerPoint or 0) >= 0 and "ok" or "bad") },
		bar = have and need > 0 and math.min(1, have / (need * math.max(1, n))) or nil,
		rows = rows, section = { head = "REAGENTS, AT WHAT THEY COST YOU", rows = (reagentRows(acc or r.accounts)) },
		note = T.Color("muted", "The bar: your Concentration against what " .. n .. (n == 1 and " craft needs." or " crafts need.")),
		actions = { p.act(true), p.act(false) } }
end

--- Buy vs craft view: buy it from the AH, or make it?
function SUI.BuyPanel(r, n)
	local T, M = CH.Theme, CH.FormatMoney
	n = n or qty
	local bc = r.bc or {}
	local acc = r.accounts or r.concAccounts
	local save = bc.save
	local verdict = not (bc.buy and bc.craft) and T.Color("muted", "No listing or no craft price to compare.")
		or save > 0 and T.Color("ok", "Buy it: " .. M(save) .. " less than making it.")
		or T.Color("ok", "Make it: " .. M(-save) .. " less than the cheapest listing.")
	local p = SUI.RecipePanel(r, n, "craft")
	return { kicker = "BUY IT OR MAKE IT?", title = r.name or "?", sub = verdict,
		figures = { figure("MAKE EACH", bc.craft, acc and (CH.ReagentBook(acc))), figure("BUY EACH", bc.buy),
			save and { save > 0 and "BUYING SAVES" or "MAKING SAVES", T.Color("ok", M(math.abs(save))) } or { "SAVES", T.Color("muted", "-") } },
		rows = { { "Resells for, after cut", bc.resell and M(bc.resell) or T.Color("muted", "-") },
			{ "Buy and relist", bc.flip and money(bc.flip) or T.Color("muted", "-") },
			{ "Sold a day, region", r.soldPerDay and string.format(r.soldPerDay >= 100 and "%.0f" or "%.1f", r.soldPerDay) or T.Color("muted", "-") } },
		section = { head = "REAGENTS, AT WHAT THEY COST YOU", rows = (reagentRows(acc)) },
		note = T.Color("muted", "The cheapest listing may be only a few items: check the AH before buying out."),
		actions = { p.actions[1] } }
end

--- Work orders: take this order?
function SUI.OrderPanel(d)
	if not d then return nil end
	local T, M = CH.Theme, CH.FormatMoney
	local pays = (d.commission or 0) + (d.rewardValue or 0)
	local state = SUI.ClaimState(d)
	local cs = d.ok and d.result and d.row and CH.Advisor.CraftOrSell(d.result, d.row)
	local verdict = not d.ok and T.Color("bad", d.learned == false and "You haven't learned this recipe." or d.unpriced and "A reagent has no price." or "No craft reaches the quality asked.")
		or (d.profit or 0) >= 0 and T.Color("ok", "Take it: " .. M(d.profit) .. " profit" .. (d.kp and " and a knowledge point." or "."))
		or d.kp and T.Color("accent", "Costs " .. M(-d.profit) .. ", but gives a knowledge point.")
		or T.Color("bad", "Skip it: it costs you " .. M(-d.profit) .. ".")
	local rows = { { "From", (d.kind and (d.kind .. ", ") or "") .. (d.customer or d.from or "?") } }
	if d.minQuality then rows[#rows + 1] = { "Asks for at least", CH.Window.QualityIcon(d.minQuality, 14, d.tiers) } end
	rows[#rows + 1] = { "Concentration", d.ok and tostring(math.floor((d.concentration or 0) + 0.5)) or T.Color("muted", "-") }
	rows[#rows + 1] = { "Reagents", not d.ok and T.Color("muted", "-") or d.have and T.Color("ok", "you have them all") or T.Color("bad", "some missing") }
	if cs and cs.gain < 0 then rows[#rows + 1] = { "Selling yours instead", T.Color("bad", "+" .. M(-cs.gain)) } end
	local actions = {}
	if state then
		actions[1] = { label = SUI.ClaimLabel(state, d) or "Claim", tip = "The next step for this order.",
			off = state == "busy" and "Another order is claimed: turn it in or release it first."
				or state == "pending" and "Waiting for the game to confirm the last step." or nil,
			run = function() return SUI.Claim(d) end }
	end
	actions[#actions + 1] = { label = "Open order", tip = "Show it in the game's order window.", run = function() CH.Orders.Open(d.order, d.recipeID) end }
	return { kicker = "TAKE THIS ORDER?", title = (d.name or "?") .. kpTag(d.kp), sub = verdict,
		figures = { figure("PAYS", pays, SUI.OrderCellLines(d, 3)), figure("REAGENTS", d.ok and d.cost or nil, d.ok and SUI.OrderCellLines(d, 5) or nil),
			figure("PROFIT", d.ok and d.profit or nil, d.ok and SUI.OrderCellLines(d, 4) or nil, (d.profit or 0) >= 0 and "ok" or "bad") },
		rows = rows, section = { head = "REAGENTS YOU SUPPLY", rows = costLineRows(d.costLines) },
		note = T.Color("muted", (d.costLines and d.costLines[1]) and HELD_NOTE or "The customer provides every reagent."), actions = actions }
end

--- First crafts: is the knowledge point worth what it costs?
function SUI.FirstPanel(d)
	if not d then return nil end
	local T, M = CH.Theme, CH.FormatMoney
	local net = d.net
	local verdict = not net and T.Color("muted", "No price for the item, so the point's cost is unknown.")
		or net >= 0 and T.Color("ok", "Free: selling it pays back the reagents, +" .. M(net) .. ".")
		or T.Color("accent", "The knowledge point costs " .. M(-net) .. ".")
	local lines = d.result and d.row and d.row.picks and CH.Advisor.CostLines(d.result, d.row.picks, d.row.finishing) or {}
	return { kicker = "WORTH THE KNOWLEDGE?", title = (d.name or "?") .. kpTag(true), sub = verdict,
		figures = { figure("REAGENTS", d.cost), figure("SELLS FOR", d.value),
			net and { net >= 0 and "POINT IS FREE" or "POINT COSTS", T.Color(net >= 0 and "ok" or "bad", M(math.abs(net))) } or { "POINT COSTS", T.Color("muted", "-") } },
		rows = { { "Gives", T.Color("accent", "1 knowledge point") } },
		section = { head = "REAGENTS, AT WHAT THEY COST YOU", rows = costLineRows(lines) },
		note = T.Color("muted", HELD_NOTE),
		actions = { { label = "Queue it", tip = "Add this first craft to the queue.", run = function() return queueRow(d) end },
			{ label = "Open recipe", tip = "Show it in the profession window.", run = function() if C_TradeSkillUI.OpenRecipe then C_TradeSkillUI.OpenRecipe(d.recipeID) end end } } }
end

--- The advisor's card for a recipe, when it's the one worked out live (open in the profession
--- window, not as an order) and the old Advisor window is off. nil otherwise.
function SUI.LiveCard(recipeID, n, scanRow)
	local A = CH.AdvisorUI
	if not (A and A.Card and recipeID) or A.Classic() then return nil end
	local cur = A.Current()
	if not cur or cur.recipeID ~= recipeID or cur.order then return nil end
	return A.Card(n or qty, scanRow)
end

-- The selected row's card, for the list showing.
local function renderDetail()
	if not detail then return end
	local T = CH.Theme
	local d
	if mode == "recipes" then
		local sr = selectedRow()
		d = sr and SUI.RecipePanel(sr) or (view == "craft" and SUI.LiveCard(selected, qty))
	else
		for _, x in ipairs(data) do if SUI.RowKey(x) == SUI.selRow then d = x; break end end
		d = d and (mode == "orders" and SUI.OrderPanel(d) or SUI.FirstPanel(d))
	end
	if not d then
		local ask = mode == "orders" and "TAKE THIS ORDER?" or mode == "first" and "WORTH THE KNOWLEDGE?"
			or view == "conc" and "WORTH THE CONCENTRATION?" or view == "buy" and "BUY IT OR MAKE IT?" or "CRAFT OR SELL?"
		d = { kicker = ask, title = T.Color("muted", mode == "recipes" and "Pick a recipe" or "Pick a row"),
			note = T.Color("muted", "Click a row to see the numbers that answer it.") }
	end
	CH.Window.DrawSidePanel(detail, d)
	SUI.lastPanel = d
end
SUI.RenderPanel = function() renderDetail() end
SUI.RenderDetail = renderDetail

-- What a Recipes view leaves out: rows with nothing to show in it.
local INVIEW = {
	craft = function() return true end,
	conc = function(r) return r.concProfit ~= nil end,
	buy = function(r) return r.buyPrice ~= nil end,
}

--- Redraw from the saved scan. Returns the row texts, for tests.
function SUI.Refresh()
	if not frame then return {} end
	if mode ~= "recipes" then status:SetWidth(W - 24); renderDetails(); return refreshLists() end
	status:SetWidth(W - 24 - (SUI.ShowViews and SUI.viewsWidth or 0))
	local rows = showTable()
	local T = CH.Theme
	local profID = CH.OpenProfessionID() or SUI.prof
	local s = CH.Scan.Results(profID)
	data = {}
	local prof = profID and CH.Me().professions[profID]
	local concNow = prof and CH.ConcentrationNow(prof)
	local current = s and (s.currentLine or CH.Scan.CurrentLine(s.rows))
	local groups, order, hidden, count = {}, {}, 0, 0
	for _, saved in ipairs(s and s.rows or {}) do
		if not saved.line then saved.line, saved.expansion = CH.Scan.Expansion(saved.recipeID) end
		-- today's prices, the same the hovers use; the saved row keeps the scan's
		local r = CH.Scan.Live(saved)
		r.current = not r.line or not current or r.line == current
		r.canMake, r.canMakeConc, r.shortItem, r.shortConc = CH.Scan.Craftable(r, concNow)
		r.bc = CH.Scan.BuyOrCraft(r)
		r.buySave = r.bc and r.bc.save
		r.buyPrice, r.resell, r.flip = r.bc and r.bc.buy, r.bc and r.bc.resell, r.bc and r.bc.flip
		r.gainPerPoint = CH.Scan.GainPerPoint(r)
		-- the best pick: the Concentration craft when it earns more a craft than the plain one
		local useConc = r.concProfit ~= nil and (r.profit == nil or r.concProfit > r.profit)
		r.bestConc = useConc
		r.bestQ = useConc and r.concQuality or r.quality
		r.bestProfit = useConc and r.concProfit or r.profit
		r.bestCost = useConc and (r.concCost or r.cost) or r.cost
		r.bestPct = r.bestProfit and r.bestCost and r.bestCost > 0 and r.bestProfit / r.bestCost or nil
		r.bestCan = useConc and r.canMakeConc or r.canMake
		-- the recipe open in the card knows about the Concentration craft with your own reagents
		if useConc and r.bestCan == 0 then
			local held = SUI.HeldMax and SUI.HeldMax(r.recipeID)
			if held and held > 0 then r.bestCan = held end
		end
		if not INVIEW[view](r) then
			-- not part of this view
		elseif r.current or showOlder then
			local key = r.current and math.huge or (r.line or 0)
			if not groups[key] then groups[key] = {}; table.insert(order, key) end
			table.insert(groups[key], r)
			count = count + 1
		else
			hidden = hidden + 1
		end
	end
	-- the current expansion first, then older ones newest first, each under its own header
	table.sort(order, function(a, b) return a > b end)
	local split = #order > 1 or (#order == 1 and order[1] ~= math.huge)
	for _, key in ipairs(order) do
		local g = sortRows(groups[key], SORT[view].key, SORT[view].asc)
		if split then
			local cur = key == math.huge
			table.insert(data, { header = true, current = cur, n = #g,
				expansion = g[1].expansion or (cur and "Current expansion" or "Older recipes") })
		end
		for _, r in ipairs(g) do table.insert(data, r) end
	end
	offset = math.max(0, math.min(offset, #data - N))
	scrollBar:Set(offset, N, #data)
	SUI.olderButton:SetText(showOlder and "Older: shown" or "Older: hidden")
	if not CH.Scan.IsRunning() then
		local age = s and time() - s.at
		local ago = age and (age < 3600 and string.format("%d min ago", math.floor(age / 60))
			or age < 86400 and string.format("%dh ago", math.floor(age / 3600)) or string.format("%d days ago, scan again", math.floor(age / 86400)))
		local what = view == "conc" and "recipes can use Concentration" or view == "buy" and "recipes have a listing" or "recipes"
		status:SetText(s and T.Color(age and age >= 86400 and "bad" or "muted", string.format("%d %s, scanned %s.%s", count, what,
			ago or "", hidden > 0 and string.format(" %d older hidden.", hidden) or ""))
			or T.Color("muted", "Open a profession and press Scan."))
	end
	local function n(k) return k and T.Color(k > 0 and "fg" or "muted", tostring(k)) or T.Color("muted", "-") end
	local function m(c) return c and money(c) or T.Color("muted", "-") end
	local out = {}
	for i, r in ipairs(rows) do
		local d = data[i + offset]
		local sel = d ~= nil and not d.header and d.recipeID == selected
		r.bg:SetShown(sel)
		if r.mark then r.mark:SetShown(sel) end
		if d and d.header then
			r.cells[1]:SetText(T.Color(d.current and "accent" or "muted", d.expansion) .. T.Color("muted", string.format(d.current and "  current, %d" or "  older, %d", d.n)))
			table.insert(out, "== " .. d.expansion)
		elseif d then
			local q = view == "conc" and d.concQuality or d.quality
			r.cells[1]:SetText(CH.Window.ItemIcon(view == "conc" and (d.concItem or d.item) or (d.item or d.concItem), 15)
				.. CH.Window.QualityIcon(q, 14, d.tiers) .. " " .. (d.current and (d.name or "?") or T.Color("muted", d.name or "?")))
			if view == "craft" then
				-- the best pick: its rank (and Concentration), profit, cost, margin, how many now
				-- rank, and the Concentration mark when the best pick uses it (its points are on the card)
				r.cells[2]:SetText(CH.Window.QualityIcon(d.bestQ, 13, d.tiers) .. (d.bestConc and (" " .. CH.Window.ConcIcon(11)) or ""))
				r.cells[3]:SetText(money(d.bestProfit))
				r.cells[4]:SetText(d.bestCost and CH.FormatMoney(d.bestCost) or T.Color("muted", "-"))
				r.cells[5]:SetText(d.bestPct and T.Color(d.bestPct >= 0 and "ok" or "bad", string.format("%d%%", math.floor(d.bestPct * 100 + 0.5))) or T.Color("muted", "-"))
				r.cells[6]:SetText(n(d.bestCan))
				table.insert(out, string.format("%s profit=%d", d.name, math.floor(d.bestProfit or 0)))
			elseif view == "conc" then
				r.cells[2]:SetText(CH.Window.QualityIcon(d.concQuality, 14, d.tiers) .. " " .. money(d.concProfit))
				r.cells[3]:SetText(m(d.gainPerPoint or d.perPoint))
				r.cells[4]:SetText(n(d.canMakeConc))
				table.insert(out, string.format("%s conc=%d pp=%d", d.name, math.floor(d.concProfit or 0), math.floor(d.perPoint or 0)))
			else
				local bc = d.bc or {}
				r.cells[2]:SetText(bc.craft and CH.FormatMoney(bc.craft) or T.Color("muted", "-"))
				r.cells[3]:SetText(bc.buy and CH.FormatMoney(bc.buy) or T.Color("muted", "-"))
				r.cells[4]:SetText(bc.save and (bc.save > 0 and T.Color("ok", "buy, " .. CH.FormatMoney(bc.save)) or T.Color("muted", "craft"))
					or T.Color("muted", "-"))
				table.insert(out, string.format("%s save=%d", d.name, math.floor(bc.save or 0)))
			end
		end
	end
	renderDetail()
	renderDetails()
	return out
end

function SUI.Start()
	if not frame then build() end
	mode = "recipes"
	local ok = CH.Scan.Run(function(done, total)
		status:SetText(CH.Theme.Color("accent", string.format("Scanning %d / %d ...", done, total)))
	end, function(_, why)
		SUI.Refresh()
		if why then status:SetText(CH.Theme.Color("muted", "Scan " .. why .. ". Scan again for this one.")) end
	end)
	if not ok then status:SetText(CH.Theme.Color("muted", "Open one of your professions (with TSM loaded) to scan it.")) end
end

function SUI.Toggle()
	if frame and frame:IsShown() then frame:Hide() else SUI.Open() end
end

--- The Scan tab: show the saved scan, or scan now if there isn't one for the open profession.
function SUI.Open()
	if not frame then build() end
	SUI.prof = CH.OpenProfessionID() or SUI.prof
	frame:Show()
	if CH.OpenProfessionID() and not CH.Scan.Results(CH.OpenProfessionID()) then SUI.Start() else SUI.Refresh() end
end

--- How many of the Concentration craft with your own reagents you can make, for the recipe open in
--- the card (the scan doesn't price that mix), or nil.
function SUI.HeldMax(recipeID)
	local A = CH.AdvisorUI
	local res = A and A.Current and A.Current()
	if not (res and res.recipeID == recipeID and res.rows) then return nil end
	for _, x in ipairs(res.rows) do
		if x.fromBags then return x.max end
	end
end

function SUI.IsShown() return frame ~= nil and frame:IsShown() end

--- A recipe picked in the profession window: select it in the list (scrolled into view) and show
--- its card. Comes to the front unless the Queue tab is showing, or force.
function SUI.ShowRecipe(recipeID, force)
	if not frame then build() end
	SUI.prof = CH.OpenProfessionID() or SUI.prof
	if recipeID then
		if mode ~= "recipes" and force then mode = "recipes" end
		if mode == "recipes" then
			if recipeID ~= selected then qty = 1 end
			selected = recipeID
		end
	end
	if force or not CH.Window.Busy("scan") then frame:Show() end
	SUI.Refresh()
	-- scroll the picked recipe into view
	if mode == "recipes" and selected then
		for i, d in ipairs(data) do
			if not d.header and d.recipeID == selected then
				if i <= offset or i > offset + N then
					offset = math.max(0, math.min(math.max(0, #data - N), i - math.floor(N / 2)))
					SUI.Refresh()
				end
				break
			end
		end
	end
end
