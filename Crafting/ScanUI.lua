-- Recipe scan window: every learned recipe of the open profession ranked by profit, gold per
-- Concentration point or gold a day. Click a row to open the recipe, shift-click to queue its best craft.
local _, CH = ...

local SUI = {}
CH.ScanUI = SUI
local frame, rows, status
local N, W, H = 16, 836, 18
local offset, sortKey, data = 0, "profit", {}
local showOlder = true

local COLS = { { "Recipe", 12, 196 }, { "Profit (can make)", 210, 114 }, { "%", 326, 40 }, { "With Conc. (can make)", 368, 128 },
	{ "Per pt", 498, 60 }, { "Sold/day", 560, 64 }, { "Gold/day", 626, 98 }, { "Buy or craft", 728, 96 } }
local SORTS = { profit = "profit per craft", concProfit = "profit with Concentration", perPoint = "gold per Concentration point",
	perDay = "gold a day", buySave = "how much buying beats crafting" }

local function money(c)
	if not c then return CH.Theme.Color("muted", "-") end
	return CH.Theme.Color(c >= 0 and "ok" or "bad", CH.FormatMoney(c))
end

local function click(i)
	local r = data[i + offset]
	if not r then return end
	if r.header then
		if not r.current then showOlder = false; offset = 0; SUI.Refresh() end
		return
	end
	if IsShiftKeyDown and IsShiftKeyDown() then
		local ok, result = pcall(CH.Advisor.Analyze, r.recipeID, { professionID = CH.OpenProfessionID() })
		if ok and result and result.best then
			CH.Queue.Add(result, result.best, 1)
			CH.Print("queued 1 x " .. (r.name or "?"))
		end
	elseif C_TradeSkillUI.OpenRecipe then
		C_TradeSkillUI.OpenRecipe(r.recipeID)
	end
end

local function hover(owner, i)
	local r = data[i + offset]
	if not r then return end
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
		table.insert(lines, { string.format("  %d points", r.concentration or 0), CH.FormatMoney(r.perPoint) .. " per point" })
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
	table.insert(lines, { T.Color("muted", "Click to open it (see it on the Advisor tab), shift-click to queue the best craft.") })
	CH.Window.Tooltip(owner, lines)
end

local function build()
	local Wd = CH.Window
	frame = Wd.New("ClearinghouseScan", "Recipe scan", W, 92 + N * H)
	local T = CH.Theme
	local x = -26
	for _, s in ipairs({ { "buySave", "Buy?" }, { "perDay", "Per day" }, { "perPoint", "Per pt" }, { "concProfit", "Conc." }, { "profit", "Profit" } }) do
		local b = T.Button(frame.bar, s[2], 56, 18)
		b:SetPoint("RIGHT", x, 0)
		b:SetScript("OnClick", function() sortKey = s[1]; offset = 0; SUI.Refresh() end)
		x = x - 60
	end
	local older = T.Button(frame.bar, "Older: shown", 100, 18)
	older:SetPoint("RIGHT", x - 54, 0)
	older:SetScript("OnClick", function() showOlder = not showOlder; offset = 0; SUI.Refresh() end)
	SUI.olderButton = older
	local scan = T.Button(frame.bar, "Scan", 50, 18)
	scan:SetPoint("RIGHT", x, 0)
	scan:SetScript("OnClick", function() SUI.Start() end)
	status = Wd.Text(frame, 12, -34, W - 24)
	rows = Wd.Table(frame, COLS, N, -54, H, click, hover, W)
	frame:EnableMouseWheel(true)
	frame:SetScript("OnMouseWheel", function(_, d)
		offset = math.max(0, math.min(math.max(0, #data - N), offset - d * 3))
		SUI.Refresh()
	end)
	T.Fonts(frame)
	Wd.Attach("scan", frame)
end

--- Redraw from the saved scan. Returns the row texts, for tests.
function SUI.Refresh()
	if not frame then return {} end
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
		if r.current or showOlder then
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
		local g = CH.Scan.Sort(groups[key], sortKey)
		if split then
			local cur = key == math.huge
			table.insert(data, { header = true, current = cur, n = #g,
				expansion = g[1].expansion or (cur and "Current expansion" or "Older recipes") })
		end
		for _, r in ipairs(g) do table.insert(data, r) end
	end
	if SUI.olderButton then SUI.olderButton:SetText(showOlder and "Older: shown" or "Older: hidden") end
	if not CH.Scan.IsRunning() then
		status:SetText(s and T.Color("muted", string.format("%d recipes, scanned %s. Sorted by %s.%s", count,
			date and date("%H:%M", s.at) or "", SORTS[sortKey] or sortKey,
			hidden > 0 and string.format(" %d from older expansions hidden.", hidden) or ""))
			or T.Color("muted", "Open a profession and press Scan."))
	end
	local out = {}
	for i, r in ipairs(rows) do
		local d = data[i + offset]
		if d and d.header then
			for _, c in ipairs(r.cells) do c:SetText("") end
			r.cells[1]:SetText(T.Color(d.current and "accent" or "muted", d.expansion))
			r.cells[2]:SetText(T.Color("muted", string.format(d.current and "current, %d" or "older, %d", d.n)))
			table.insert(out, "== " .. d.expansion)
		elseif d then
			r.cells[1]:SetText(CH.Window.ItemIcon(d.item or d.concItem, 15) .. CH.Window.QualityIcon(d.quality, 14, d.tiers) .. " "
				.. (d.current and (d.name or "?") or T.Color("muted", d.name or "?")))
			local function n(k) return k and T.Color(k > 0 and "accent" or "muted", " (" .. k .. ")") or "" end
			r.cells[2]:SetText(money(d.profit) .. n(d.canMake))
			r.cells[3]:SetText(d.pct and string.format("%d%%", math.floor(d.pct * 100 + 0.5)) or "")
			r.cells[4]:SetText(d.concProfit and (CH.Window.QualityIcon(d.concQuality, 14, d.tiers) .. " " .. money(d.concProfit) .. n(d.canMakeConc)) or "")
			r.cells[5]:SetText(d.perPoint and money(d.perPoint) or "")
			r.cells[6]:SetText(d.soldPerDay and string.format("%.0f", d.soldPerDay) or "-")
			r.cells[7]:SetText(money(d.perDay))
			local bc = d.bc
			if bc and bc.save and bc.save > 0 then
				r.cells[8]:SetText(T.Color("ok", "Buy " .. CH.FormatMoney(bc.buy)))
			else
				r.cells[8]:SetText(bc and bc.craft and T.Color("muted", "Craft") or "")
			end
			table.insert(out, string.format("%s profit=%d", d.name, math.floor(d.profit or 0)))
		else
			for _, c in ipairs(r.cells) do c:SetText("") end
		end
	end
	return out
end

function SUI.Start()
	if not frame then build() end
	local ok = CH.Scan.Run(function(done, total)
		status:SetText(CH.Theme.Color("accent", string.format("Scanning %d / %d ...", done, total)))
	end, function() SUI.Refresh() end)
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
