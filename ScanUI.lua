-- Recipe scan window: every learned recipe of the open profession ranked by profit, gold per
-- Concentration point or gold a day. Click a row to open the recipe, shift-click to queue its best craft.
local _, CH = ...

local SUI = {}
CH.ScanUI = SUI
local frame, rows, status
local N, W, H = 16, 736, 18
local offset, sortKey, data = 0, "profit", {}

local COLS = { { "Recipe", 12, 226 }, { "Profit", 240, 92 }, { "%", 334, 44 }, { "With Conc.", 380, 104 },
	{ "Per pt", 486, 72 }, { "Sold/day", 560, 64 }, { "Gold/day", 626, 98 } }
local SORTS = { profit = "profit per craft", concProfit = "profit with Concentration", perPoint = "gold per Concentration point",
	perDay = "gold a day" }

local function money(c)
	if not c then return CH.Theme.Color("muted", "-") end
	return CH.Theme.Color(c >= 0 and "ok" or "bad", CH.FormatMoney(c))
end

local function click(i)
	local r = data[i + offset]
	if not r then return end
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
	local lines = { { T.Color("accent", r.name or "?") } }
	if r.quality then table.insert(lines, { "Best without Concentration", CH.Window.QualityIcon(r.quality, 14, r.tiers) .. " " .. CH.FormatMoney(r.profit) }) end
	if r.cost then table.insert(lines, { "Reagents", CH.FormatMoney(r.cost) }) end
	if r.perPoint then
		table.insert(lines, { "Best with Concentration", CH.Window.QualityIcon(r.concQuality, 14, r.tiers) .. " " .. CH.FormatMoney(r.concProfit) })
		table.insert(lines, { string.format("  %d points", r.concentration or 0), CH.FormatMoney(r.perPoint) .. " per point" })
	end
	table.insert(lines, { "Sold per day, region", r.soldPerDay and string.format("%.1f", r.soldPerDay) or "-" })
	table.insert(lines, { string.format("Gold a day at up to %d sold", CH.db.settings.scan.dailyCap or 10), CH.FormatMoney(r.perDay) })
	if r.perPoint then table.insert(lines, { T.Color("muted", "Gold a day counts Concentration crafts up to what a day's refill (about 250) pays for.") }) end
	table.insert(lines, { T.Color("muted", "Click to open it (see it on the Advisor tab), shift-click to queue the best craft.") })
	CH.Window.Tooltip(owner, lines)
end

local function build()
	local Wd = CH.Window
	frame = Wd.New("ClearinghouseScan", "Recipe scan", W, 92 + N * H)
	local T = CH.Theme
	local x = -26
	for _, s in ipairs({ { "perDay", "Per day" }, { "perPoint", "Per pt" }, { "concProfit", "Conc." }, { "profit", "Profit" } }) do
		local b = T.Button(frame.bar, s[2], 56, 18)
		b:SetPoint("RIGHT", x, 0)
		b:SetScript("OnClick", function() sortKey = s[1]; offset = 0; SUI.Refresh() end)
		x = x - 60
	end
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
	for _, r in ipairs(s and s.rows or {}) do table.insert(data, r) end
	CH.Scan.Sort(data, sortKey)
	if not CH.Scan.IsRunning() then
		status:SetText(s and T.Color("muted", string.format("%d recipes, scanned %s. Sorted by %s.", #data,
			date and date("%H:%M", s.at) or "", SORTS[sortKey] or sortKey))
			or T.Color("muted", "Open a profession and press Scan."))
	end
	local out = {}
	for i, r in ipairs(rows) do
		local d = data[i + offset]
		if d then
			r.cells[1]:SetText(CH.Window.ItemIcon(d.item or d.concItem, 15) .. CH.Window.QualityIcon(d.quality, 14, d.tiers) .. " " .. (d.name or "?"))
			r.cells[2]:SetText(money(d.profit))
			r.cells[3]:SetText(d.pct and string.format("%d%%", math.floor(d.pct * 100 + 0.5)) or "")
			r.cells[4]:SetText(d.concProfit and (CH.Window.QualityIcon(d.concQuality, 14, d.tiers) .. " " .. money(d.concProfit)) or "")
			r.cells[5]:SetText(d.perPoint and money(d.perPoint) or "")
			r.cells[6]:SetText(d.soldPerDay and string.format("%.0f", d.soldPerDay) or "-")
			r.cells[7]:SetText(money(d.perDay))
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
