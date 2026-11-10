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
local N, W, H = 16, 836, 18
local DETAIL = 72 -- the selected recipe's strip under the list
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
	craft = { { "Recipe", 12, 236, "name" }, { "Profit/craft", 250, 120, "profit" }, { "%", 372, 44, "pct" },
		{ "Reagents", 418, 96, "cost" }, { "Can make", 516, 70, "canMake" }, { "Sold/day", 588, 70, "soldPerDay" },
		{ "Est. gold/day", 660, 164, "perDay" } },
	conc = { { "Recipe", 12, 236, "name" }, { "Plain", 250, 130, "profit" }, { "With Conc.", 382, 140, "concProfit" },
		{ "Points", 524, 60, "concentration" }, { "Extra/pt", 586, 100, "gainPerPoint" }, { "Can make", 688, 136, "canMakeConc" } },
	buy = { { "Recipe", 12, 236, "name" }, { "Craft each", 250, 110, "craftEach" }, { "Cheapest listing", 362, 120, "buyPrice" },
		{ "Resells for", 484, 110, "resell" }, { "Buying saves", 596, 110, "buySave" }, { "Buy & relist", 708, 116, "flip" } },
	orders = { { "Order", 12, 250, "name" }, { "From", 264, 96, "from", "LEFT" }, { "Commission", 362, 92, "commission" },
		{ "Rewards", 456, 110, "rewardValue" }, { "Reagents", 568, 88, "cost" }, { "Order profit", 658, 90, "profit" }, { "Craft at", 750, 74, "quality" } },
	first = { { "Recipe", 12, 330, "name" }, { "Reagents", 344, 120, "cost" }, { "Proceeds", 466, 120, "value" },
		{ "Point costs", 588, 130, "net" } },
}
local SORT = { craft = { key = "profit" }, conc = { key = "gainPerPoint" }, buy = { key = "buySave" }, orders = { key = "default" }, first = { key = "net" } }
local VIEWS = { { "craft", "Craft", 60 }, { "conc", "Concentration", 108 }, { "buy", "Buy vs craft", 96 } }
local NAMES = { name = "name", profit = "profit per craft", pct = "margin", concProfit = "profit with Concentration",
	perPoint = "gold per Concentration point", gainPerPoint = "gold Concentration adds per expected point", soldPerDay = "sold a day", perDay = "gold a day", buySave = "how much buying beats crafting",
	from = "who it's from", commission = "commission", rewardValue = "rewards", cost = "reagents", quality = "quality",
	value = "what it sells for", net = "cheapest point first", default = "fillable, knowledge, then profit",
	canMake = "how many you can make now", canMakeConc = "how many you can make with Concentration now",
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
		if IsShiftKeyDown and IsShiftKeyDown() then queueRow(r)
		elseif mode == "orders" then CH.Orders.Open(r.order, r.recipeID)
		elseif C_TradeSkillUI.OpenRecipe then C_TradeSkillUI.OpenRecipe(r.recipeID) end
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

local function kpTag(yes) return yes and CH.Theme.Color("accent", " 1KP") or "" end

--- Hover lines for a work order or first craft row (also used by the tests).
function SUI.OrderLines(d)
	local T, M = CH.Theme, CH.FormatMoney
	local lines = { { T.Color("accent", d.name or "?") .. kpTag(d.kp or not d.orderID) } }
	if d.orderID then
		table.insert(lines, { d.kind .. " order", d.from })
		if d.expansion then table.insert(lines, { "Expansion", d.expansion .. (d.current and "" or T.Color("muted", "  (older)")) }) end
		if d.minQuality then table.insert(lines, { "Asks for at least", CH.Window.QualityIcon(d.minQuality, 14, d.tiers) }) end
		table.insert(lines, { "Commission, after the consortium's cut", M(d.commission) })
		for _, rw in ipairs(d.rewards) do
			local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(rw.id)) or ("item " .. rw.id)
			table.insert(lines, { "  " .. rw.count .. " x " .. name .. (rw.knowledge and T.Color("accent", "  knowledge") or ""),
				rw.value and M(rw.value) or T.Color("muted", "can't be sold") })
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
			table.insert(lines, { "Your reagents", "-" .. M(d.cost or 0) })
			table.insert(lines, { "Commission and rewards less reagents", money(pays - (d.cost or 0)) })
			local procs = (d.profit or 0) - (pays - (d.cost or 0))
			if math.abs(procs) >= 100 then table.insert(lines, { "Resourcefulness, on average", money(procs) }) end
			table.insert(lines, { "Profit", money(d.profit) })
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

local function hover(owner, i)
	local r = data[i + offset]
	if not r then return end
	if mode ~= "recipes" then CH.Window.Tooltip(owner, SUI.OrderLines(r)); return end
	local T = CH.Theme
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
		table.insert(lines, { "You can make now", r.canMake .. (r.canMake == 0 and r.shortItem and T.Color("muted", "  short of " .. short(r.shortItem))
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
	frame = Wd.New("AuctionIQScan", "Recipe scan", W, 92 + N * H + DETAIL)
	local x = -26
	local function barButton(label, width, fn)
		local b = T.Button(frame.bar, label, width, 18)
		b:SetPoint("RIGHT", x, 0)
		b:SetScript("OnClick", fn)
		x = x - width - 4
		return b
	end
	SUI.allButton = barButton("Queue all", 72, function() SUI.QueueAll() end)
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
		local b = T.Button(frame, v[2], v[3], 18)
		b:SetPoint("TOPRIGHT", vx, -30)
		b:SetScript("OnClick", function() SUI.SetView(v[1]) end)
		b.view = v[1]
		vx = vx - v[3] - 4
		SUI.viewButtons[k] = b
	end
	SUI.viewsWidth = -vx
	for m, cols in pairs(COLS) do
		local blank = {}
		for j, c in ipairs(cols) do blank[j] = { "", c[2], c[3], c[5] } end
		tables[m] = Wd.Table(frame, blank, N, -54, H, click, hover, W)
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
	scrollBar = Wd.ScrollBar(frame, W - 8, -70, N * H)
	-- The selected recipe: both crafts the scan found, each with its own Queue button
	detail = CreateFrame("Frame", nil, frame)
	detail:SetPoint("TOPLEFT", 0, -(70 + N * H + 4))
	detail:SetSize(W, DETAIL)
	local rule = detail:CreateTexture(nil, "ARTWORK")
	rule:SetColorTexture(T.line[1], T.line[2], T.line[3], 1)
	rule:SetPoint("TOPLEFT", 6, 0)
	rule:SetPoint("TOPRIGHT", -6, 0)
	rule:SetHeight(1)
	detail.card = T.Card(detail, 6, -1, W - 12, DETAIL - 2, false)
	detail.title = Wd.OneLine(Wd.Text(detail, 12, -6, W - 24 - 150, "LEFT", "GameFontHighlight"))
	local function stepper(label, x, d)
		local b = T.Button(detail, label, 22, 18)
		b:SetPoint("TOPRIGHT", x, -3)
		b:SetScript("OnClick", function() SUI.SetQty(qty + (IsShiftKeyDown and IsShiftKeyDown() and d * 10 or d)) end)
		b:SetScript("OnEnter", function(self) Wd.Tooltip(self, { { "How many to queue" }, { T.Color("muted", "Shift-click for 10 at a time.") } }) end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		return b
	end
	stepper("+", -12, 1)
	detail.qty = Wd.OneLine(Wd.Text(detail, W - 12 - 22 - 44, -6, 40, "CENTER", "GameFontHighlight"))
	stepper("-", -(12 + 22 + 48), -1)
	Wd.OneLine(Wd.Text(detail, W - 12 - 22 - 48 - 22 - 42, -6, 38, "RIGHT")):SetText("Qty")
	detail.lines, detail.buttons = {}, {}
	for k, conc in ipairs({ false, true }) do
		local y = -6 - k * 22
		detail.lines[k] = Wd.OneLine(Wd.Text(detail, 12, y, W - 24 - 190))
		local b = T.Button(detail, conc and "Queue with Concentration" or "Queue plain", 180, 18)
		b:SetPoint("TOPRIGHT", -12, y + 3)
		if not conc then T.Primary(b) end
		b:SetScript("OnClick", function(self) if not self.off then SUI.QueueSelected(conc) end end)
		b:SetScript("OnEnter", function(self)
			Wd.Tooltip(self, { { conc and "Queue the Concentration craft" or "Queue the plain craft" },
				{ T.Color("muted", self.off or "Adds the craft on this line, with the reagents the scan picked.") } })
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		detail.buttons[k] = b
	end
	frame:EnableMouseWheel(true)
	frame:SetScript("OnMouseWheel", function(_, d)
		offset = math.max(0, math.min(math.max(0, #data - N), offset - d * 3))
		SUI.Refresh()
		scrollBar:Set(offset, N, #data)
	end)
	T.Fonts(frame)
	Wd.Attach("scan", frame)
end

-- Show only the active list's table and headers, with an arrow on the sorted column.
local function showTable()
	local T = CH.Theme
	for m, rows in pairs(tables) do
		local on = m == listKey()
		for _, r in ipairs(rows) do
			for _, c in ipairs(r.cells) do c:SetText("") end
			if r.button then r.button:SetShown(on) end
			if not on then r.bg:Hide() end
		end
		for _, hb in ipairs(heads[m]) do
			hb:SetShown(on)
			local sorted = on and SORT[m].key == hb.key
			hb.text:SetText(not on and "" or sorted and T.Color("accent", hb.label .. (SORT[m].asc and " ^" or " v")) or hb.label)
		end
	end
	if SUI.olderButton then
		SUI.olderButton:SetShown(mode == "recipes" or mode == "orders")
		SUI.olderButton:SetText(showOlder and "Older: shown" or "Older: hidden")
	end
	if SUI.allButton then SUI.allButton:SetShown(mode ~= "recipes") end
	if SUI.nextButton then SUI.nextButton:SetShown(mode == "orders"); SUI.UpdateNext() end
	for m, b in pairs({ orders = SUI.ordersButton, first = SUI.firstButton }) do
		if b and b.SetAlpha then b:SetAlpha(mode == m and 1 or 0.65) end
	end
	for _, b in ipairs(SUI.viewButtons or {}) do
		if b.SetAlpha then b:SetAlpha(mode == "recipes" and view == b.view and 1 or 0.65) end
	end
	if detail then detail:SetShown(mode == "recipes") end
	return tables[listKey()]
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
	local label = (step == "Turn in" and "Turn in next") or (step == "Craft" and "Craft next") or "Claim next"
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
		-- show the claimed order, as the game does when you claim it yourself
		local o = CH.Orders.Live(e.orderID)
		if o then CH.Orders.Open(o) end
	elseif step == "Turn in" and C_Timer then
		-- the list changes once the game takes it: fetch again for the next order
		C_Timer.After(1, SUI.FetchOrders)
	end
	if step then
		CH.Print(string.format("%s: %s", step == "Turn in" and "turned in" or step == "Claim" and "claimed" or "crafting", e.name or "?"))
	elseif e then
		CH.Print(e)
	end
	SUI.UpdateNext()
end

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
		status:SetText(#data > 0 and string.format("%d work orders: %s pay, %s give a knowledge point (1KP)", #data, T.Color("ok", pays), T.Color("accent", kp)) .. olderNote .. fetching
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
		if d and mode == "orders" then
			r.cells[1]:SetText(CH.Window.ItemIcon(d.item, 15) .. (d.current and "" or T.Color("muted", "[" .. (d.expansion or "older") .. "] ")) .. (d.name or "?")
				.. (d.minQuality and (" " .. CH.Window.QualityIcon(d.minQuality, 14, d.tiers) .. "+") or "") .. kpTag(d.kp))
			r.cells[2]:SetText(d.from)
			r.cells[3]:SetText(money(d.commission))
			r.cells[4]:SetText(d.rewardValue > 0 and money(d.rewardValue) or (d.rewards[1] and T.Color("muted", "unsellable") or T.Color("muted", "-")))
			-- what your reagents cost, always (like CraftSim): green when you hold them, red when you'd buy
			r.cells[5]:SetText(not d.ok and T.Color("muted", "-") or T.Color(d.have and "ok" or "bad", CH.FormatMoney(d.cost or 0)))
			r.cells[6]:SetText(d.ok and money(d.profit) or T.Color("bad", d.learned == false and "not learned" or d.unpriced and "no price" or "can't reach"))
			r.cells[7]:SetText(d.ok and (CH.Window.QualityIcon(d.quality, 14, d.tiers) .. (d.concentration and T.Color("accent", " conc") or "")) or "")
			table.insert(out, string.format("%s from=%s profit=%s kp=%s", d.name, d.from, d.profit and math.floor(d.profit) or "-", tostring(d.kp)))
		elseif d then
			r.cells[1]:SetText(CH.Window.ItemIcon(d.item, 15) .. (d.name or "?") .. kpTag(true))
			r.cells[2]:SetText(d.cost and CH.FormatMoney(d.cost) or T.Color("muted", "-"))
			r.cells[3]:SetText(d.value and CH.FormatMoney(d.value) or T.Color("muted", "no price"))
			r.cells[4]:SetText(d.net and (d.net >= 0 and T.Color("ok", "free, +" .. CH.FormatMoney(d.net)) or T.Color("bad", CH.FormatMoney(-d.net))) or T.Color("muted", "-"))
			table.insert(out, string.format("%s net=%s", d.name, d.net and math.floor(d.net) or "-"))
		end
	end
	return out
end

--- Redraw from the saved scan. Returns the row texts, for tests.
-- The selected recipe's strip: what each Queue button would add, and whether it can.
local function renderDetail()
	if not detail then return end
	local T, M, Wd = CH.Theme, CH.FormatMoney, CH.Window
	local r = selectedRow()
	detail.qty:SetText(tostring(qty))
	if not r then
		detail.title:SetText(T.Color("muted", "Click a recipe to see its crafts and queue one."))
		for k = 1, 2 do detail.lines[k]:SetText(""); detail.buttons[k].off = "Pick a recipe first."; detail.buttons[k]:SetAlpha(0.4) end
		return
	end
	detail.title:SetText(Wd.ItemIcon(r.item or r.concItem, 16) .. T.Color("accent", r.name or "?")
		.. (r.made and r.made ~= 1 and T.Color("muted", string.format("  makes %.1f a craft", r.made)) or ""))
	local function can(n, short)
		if not n then return "" end
		local why = n == 0 and short and (short == "concentration" and "  not enough Concentration" or "  short of reagents") or ""
		return T.Color(n > 0 and "fg" or "bad", "  can make " .. n) .. T.Color("muted", why)
	end
	local plain = r.profit and (T.Color("accent", "Plain") .. "  " .. Wd.QualityIcon(r.quality, 14, r.tiers)
		.. "  reagents " .. M(r.cost or 0) .. "  profit " .. money(r.profit) .. " a craft" .. can(r.canMake, r.shortItem))
		or T.Color("muted", "Plain: no priced craft without Concentration")
	local acc = r.concAccounts
	local conc = r.concProfit and (T.Color("accent", "Concentration") .. "  " .. Wd.QualityIcon(r.concQuality, 14, r.tiers)
		.. string.format("  %d points", r.concentration or 0) .. "  reagents " .. M(acc and acc.cost or r.cost or 0)
		.. "  profit " .. money(r.concProfit) .. (r.perPoint and T.Color("muted", " (" .. M(r.perPoint) .. " a point)") or "")
		.. can(r.canMakeConc, r.shortConc))
		or T.Color("muted", "Concentration: no craft that lifts the quality")
	detail.lines[1]:SetText(plain)
	detail.lines[2]:SetText(conc)
	for k, c in ipairs({ false, true }) do
		local b = detail.buttons[k]
		local ok, why = SUI.ScanEntry(r, c)
		b.off = not ok and (why:sub(1, 1):upper() .. why:sub(2) .. ".") or nil
		b:SetAlpha(ok and 1 or 0.4)
	end
end
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
	if mode ~= "recipes" then status:SetWidth(W - 24); return refreshLists() end
	status:SetWidth(W - 24 - (SUI.viewsWidth or 0))
	local rows = showTable()
	local T = CH.Theme
	local profID = CH.OpenProfessionID() or SUI.prof
	local s = CH.Scan.Results(profID)
	data = {}
	local prof = profID and CH.Me().professions[profID]
	local concNow = prof and CH.ConcentrationNow(prof)
	local current = s and (s.currentLine or CH.Scan.CurrentLine(s.rows))
	local groups, order, hidden, count = {}, {}, 0, 0
	for _, r in ipairs(s and s.rows or {}) do
		if not r.line then r.line, r.expansion = CH.Scan.Expansion(r.recipeID) end
		r.current = not r.line or not current or r.line == current
		r.canMake, r.canMakeConc, r.shortItem, r.shortConc = CH.Scan.Craftable(r, concNow)
		r.bc = CH.Scan.BuyOrCraft(r)
		r.buySave = r.bc and r.bc.save
		r.buyPrice, r.resell, r.flip = r.bc and r.bc.buy, r.bc and r.bc.resell, r.bc and r.bc.flip
		r.gainPerPoint = CH.Scan.GainPerPoint(r)
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
		r.bg:SetShown(d ~= nil and not d.header and d.recipeID == selected)
		if d and d.header then
			r.cells[1]:SetText(T.Color(d.current and "accent" or "muted", d.expansion))
			r.cells[2]:SetText(T.Color("muted", string.format(d.current and "current, %d" or "older, %d", d.n)))
			table.insert(out, "== " .. d.expansion)
		elseif d then
			local q = view == "conc" and d.concQuality or d.quality
			r.cells[1]:SetText(CH.Window.ItemIcon(view == "conc" and (d.concItem or d.item) or (d.item or d.concItem), 15)
				.. CH.Window.QualityIcon(q, 14, d.tiers) .. " " .. (d.current and (d.name or "?") or T.Color("muted", d.name or "?")))
			if view == "craft" then
				r.cells[2]:SetText(money(d.profit))
				r.cells[3]:SetText(d.pct and string.format("%d%%", math.floor(d.pct * 100 + 0.5)) or "")
				r.cells[4]:SetText(d.cost and CH.FormatMoney(d.cost) or T.Color("muted", "-"))
				r.cells[5]:SetText(n(d.canMake))
				r.cells[6]:SetText(d.soldPerDay and string.format("%.0f", d.soldPerDay) or "-")
				r.cells[7]:SetText(money(d.perDay))
				table.insert(out, string.format("%s profit=%d", d.name, math.floor(d.profit or 0)))
			elseif view == "conc" then
				r.cells[2]:SetText(d.profit and (CH.Window.QualityIcon(d.quality, 14, d.tiers) .. " " .. money(d.profit)) or T.Color("muted", "-"))
				r.cells[3]:SetText(CH.Window.QualityIcon(d.concQuality, 14, d.tiers) .. " " .. money(d.concProfit))
				r.cells[4]:SetText(tostring(d.concentration or "-"))
				r.cells[5]:SetText(m(d.gainPerPoint or d.perPoint))
				r.cells[6]:SetText(n(d.canMakeConc))
				table.insert(out, string.format("%s conc=%d pp=%d", d.name, math.floor(d.concProfit or 0), math.floor(d.perPoint or 0)))
			else
				local bc = d.bc or {}
				r.cells[2]:SetText(bc.craft and CH.FormatMoney(bc.craft) or T.Color("muted", "-"))
				r.cells[3]:SetText(bc.buy and CH.FormatMoney(bc.buy) or T.Color("muted", "-"))
				r.cells[4]:SetText(bc.resell and CH.FormatMoney(bc.resell) or T.Color("muted", "-"))
				r.cells[5]:SetText(bc.save and (bc.save > 0 and T.Color("ok", "buy, " .. CH.FormatMoney(bc.save)) or T.Color("muted", "craft"))
					or T.Color("muted", "-"))
				r.cells[6]:SetText(bc.flip and money(bc.flip) or T.Color("muted", "-"))
				table.insert(out, string.format("%s save=%d", d.name, math.floor(bc.save or 0)))
			end
		end
	end
	renderDetail()
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

function SUI.IsShown() return frame ~= nil and frame:IsShown() end
