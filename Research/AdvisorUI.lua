-- Crafting advisor panel: docked to the right of the profession window, or dragged off to stand on
-- its own. Shows every result quality for the selected recipe, marks CraftSim-style picks.
-- Click a row to select it; the bar under the rows queues the selected craft, as many as you set.
local _, CH = ...

local AUI = {}
CH.AdvisorUI = AUI
local panel, rows, notes, current
local ROWS = 8
local TOP = 68 -- the Next Move block under the title bar
local HEIGHT = 456 + TOP
-- Simulation: extra skill, and a knowledge point plan from the Paths window.
local sim = { skill = 0, plan = nil }
local order -- the crafting order on screen, if any
local live -- the result without simulation, to compare against
local gearPick -- top gear for the recipe on screen
local sel, selQty, selRecipe = nil, 1, nil -- the selected row (by quality and Concentration), how many, and for which recipe
local pane = "notes" -- what the area under the rows shows: notes, chart (break-even) or batch
local batchCache = {} -- batch analyses by row, so redrawing doesn't run them again
local PANE_H = 104
-- name, x, width. Hover breakdowns on cost (3), proceeds (4), profit (5) and max (7).
local COLS = { { "Quality", 0, 70 }, { "Conc.", 70, 50 }, { "Cost", 120, 86 }, { "Expected proceeds", 206, 106 },
	{ "Avg profit/craft", 312, 104 }, { "Extra/pt", 416, 70 }, { "Max", 486, 40 } }
local HOVER = { 3, 4, 5, 7 }
local WIDTH = 540

local function settings() return CH.db.settings.advisor end

local function qualityIcon(q, tiers) return CH.Window.QualityIcon(q, 18, tiers) end

local function ownProfession()
	local ui = C_TradeSkillUI
	return not ((ui.IsTradeSkillLinked and ui.IsTradeSkillLinked()) or (ui.IsTradeSkillGuild and ui.IsTradeSkillGuild())
		or (ui.IsNPCCrafting and ui.IsNPCCrafting()))
end

function AUI.Place()
	if panel then CH.Window.Place(panel) end
end

local function build()
	local T = CH.Theme
	T.Sync()
	panel = CreateFrame("Frame", "AuctionIQAdvisor", UIParent, "BackdropTemplate")
	T.Panel(panel, "bg", 0.95)
	panel:SetSize(WIDTH, HEIGHT)
	panel:SetFrameStrata("HIGH")
	panel:SetMovable(true)
	panel:SetClampedToScreen(true)
	panel:EnableMouse(true)
	panel:RegisterForDrag("LeftButton")
	panel:Hide()
	CH.Window.CloseOnEscape(panel, "AuctionIQAdvisor")

	local bar = CreateFrame("Frame", nil, panel, "BackdropTemplate")
	T.Panel(bar, "panel", 1)
	bar:SetPoint("TOPLEFT")
	bar:SetPoint("TOPRIGHT")
	bar:SetHeight(26)
	local rule = bar:CreateTexture(nil, "ARTWORK")
	T.AccentTexture(rule)
	rule:SetPoint("BOTTOMLEFT", 1, 0)
	rule:SetPoint("BOTTOMRIGHT", -1, 0)
	rule:SetHeight(2)
	local title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("LEFT", 10, 0)
	T.BrandTitle(title, "Crafting advisor")
	local close = T.Button(bar, "x", 18, 18)
	close:SetPoint("RIGHT", -4, 0)
	close:SetScript("OnClick", function() settings().hide = true; panel:Hide(); CH.Print("advisor hidden. /aiq advisor brings it back.") end)
	local queue = T.Button(bar, "Queue", 56, 18)
	queue:SetPoint("RIGHT", close, "LEFT", -4, 0)
	queue:SetScript("OnClick", function() CH.QueueUI.Toggle() end)
	panel.queue = queue
	-- the area under the rows shows the notes, the break-even chart or a batch analysis
	local function paneButton(label, w, anchor, key, tip)
		local b = T.Button(bar, label, w, 18)
		b:SetPoint("RIGHT", anchor, "LEFT", -4, 0)
		b:SetScript("OnClick", function() AUI.SetPane(pane == key and "notes" or key) end)
		b:SetScript("OnEnter", function(self) CH.Window.Tooltip(self, tip) end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		return b
	end
	panel.chartBtn = paneButton("Break-even", 72, queue, "chart", { { "Break-even chart" },
		{ T.Color("muted", "Profit a craft against the sale price, for the plain and Concentration crafts. Click again for the notes.") } })
	panel.batchBtn = paneButton("Analyze batch", 96, panel.chartBtn, "batch", { { "Analyze batch" },
		{ T.Color("muted", "What could happen to 10, 30 or 100 of the selected craft over a week: the chance the sales pay back the reagents, the cash that comes back, and the stock left. Click again for the notes.") } })

	-- Next Move: the selected craft and how many, then profit, break-even and the chance to
	-- recover the spend in a week, biggest first (the summary hierarchy from the style review)
	local nx = CreateFrame("Frame", nil, panel, "BackdropTemplate")
	T.Panel(nx, "panel", 1)
	nx:SetPoint("TOPLEFT", 6, -32)
	nx:SetSize(WIDTH - 12, TOP - 6)
	panel.next = nx
	nx.label = T.TitleFont(CH.Window.OneLine(CH.Window.Text(nx, 8, -5, 120, "LEFT", "GameFontNormalSmall")), 9, "bold")
	nx.label:SetText(T.Color("accent", "NEXT MOVE"))
	nx.head = T.TitleFont(CH.Window.OneLine(CH.Window.Text(nx, 8, -17, 330, "LEFT", "GameFontHighlight")), 14)
	nx.sub = CH.Window.OneLine(CH.Window.Text(nx, WIDTH - 12 - 8 - 180, -20, 180, "RIGHT", "GameFontDisableSmall"))
	nx.stats = {}
	-- short labels; each figure's hover says what it means and how it was reached
	local hit = CreateFrame("Button", nil, nx)
	hit:SetPoint("TOPLEFT", 0, 0)
	hit:SetSize(WIDTH - 12, 32)
	hit:SetScript("OnEnter", function(self) CH.Window.Tooltip(self, AUI.NextTip()) end)
	hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
	for i, f in ipairs({ { "PROFIT", "profit" }, { "BREAK-EVEN", "breakEven" }, { "RECOVER", "recover" } }) do
		local x = 8 + (i - 1) * 132
		local l = T.TitleFont(CH.Window.OneLine(CH.Window.Text(nx, x, -36, 128, "LEFT", "GameFontDisableSmall")), 9, "bold")
		l:SetText(T.Color("muted", f[1]))
		local v = T.TitleFont(CH.Window.OneLine(CH.Window.Text(nx, x, -46, 128, "LEFT", "GameFontHighlight")), 13)
		nx.stats[i] = v
		local h = CreateFrame("Button", nil, nx)
		h:SetPoint("TOPLEFT", x - 4, -32)
		h:SetSize(i == 3 and (WIDTH - 12 - x) or 132, 30) -- Recover takes in the bar beside it
		h:SetScript("OnEnter", function(self) CH.Window.Tooltip(self, AUI.NextTip(f[2])) end)
		h:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end
	nx.back = nx:CreateTexture(nil, "ARTWORK")
	nx.back:SetPoint("TOPLEFT", 8 + 3 * 132, -50)
	nx.barW = WIDTH - 12 - 16 - 3 * 132
	nx.back:SetSize(nx.barW, 6)
	nx.back:SetColorTexture(0, 0, 0, 0.6)
	nx.fill = nx:CreateTexture(nil, "OVERLAY")
	nx.fill:SetPoint("TOPLEFT", nx.back, "TOPLEFT", 0, 0)
	nx.fill:SetSize(1, 6)
	T.Gradient(nx.fill)

	panel.recipe = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	panel.recipe:SetPoint("TOPLEFT", 12, -34 - TOP)
	panel.recipe:SetWidth(WIDTH - 24)
	panel.recipe:SetJustifyH("LEFT")
	CH.Window.OneLine(panel.recipe)

	local y = -56 - TOP
	for _, c in ipairs(COLS) do
		local h = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		h:SetPoint("TOPLEFT", 12 + c[2], y)
		h:SetWidth(c[3])
		h:SetJustifyH(c[2] == 0 and "LEFT" or "RIGHT")
		h:SetText(c[1])
		h:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
	end
	rows = {}
	for i = 1, ROWS do
		local r = { cells = {} }
		r.bg = panel:CreateTexture(nil, "BACKGROUND")
		r.bg:SetPoint("TOPLEFT", 6, y - 4 - i * 20)
		r.bg:SetSize(WIDTH - 12, 20)
		r.bg:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 0.12)
		r.sel = panel:CreateTexture(nil, "BORDER")
		r.sel:SetPoint("TOPLEFT", 6, y - 4 - i * 20)
		r.sel:SetSize(3, 20)
		r.sel:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 1)
		r.sel:Hide()
		for j, c in ipairs(COLS) do
			local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			fs:SetPoint("TOPLEFT", 12 + c[2], y - i * 20)
			fs:SetWidth(c[3])
			fs:SetJustifyH(j == 1 and "LEFT" or "RIGHT")
			r.cells[j] = CH.Window.OneLine(fs)
		end
		local click = CreateFrame("Button", nil, panel)
		click:SetPoint("TOPLEFT", 6, y - 4 - i * 20)
		click:SetSize(WIDTH - 12, 20)
		click:SetScript("OnClick", function() AUI.RowClick(i) end)
		-- One mouse frame per row: the column under the cursor picks the breakdown. (Separate hover
		-- frames per cell overlapped the next row's click frame, so only the first row's showed.)
		click:SetScript("OnEnter", function(self)
			self.col = nil
			self:SetScript("OnUpdate", function()
				local col = AUI.ColumnAt(self)
				if col ~= self.col then
					self.col = col
					if col then AUI.ShowBreakdown(self, i, col) else GameTooltip:Hide() end
				end
			end)
		end)
		click:SetScript("OnLeave", function(self) self:SetScript("OnUpdate", nil); self.col = nil; GameTooltip:Hide() end)
		rows[i] = r
	end
	-- The selected craft and the button that queues it
	local ay = y - (ROWS + 1) * 20 - 4
	local act = CreateFrame("Frame", nil, panel)
	act:SetPoint("TOPLEFT", 0, ay)
	act:SetSize(WIDTH, 22)
	panel.act = act
	act.label = CH.Window.OneLine(CH.Window.Text(act, 12, -4, 236))
	local function aButton(label, w, x, fn, tip)
		local b = T.Button(act, label, w, 18)
		b:SetPoint("TOPRIGHT", x, -1)
		b:SetScript("OnClick", fn)
		b:SetScript("OnEnter", function(self) CH.Window.Tooltip(self, tip(self)) end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		return b
	end
	act.queue = aButton("Queue", 128, -10, function(self) if not self.off then AUI.QueueSelected() end end, function(self)
		return { { self.text and self.text:GetText() or "Queue" }, { T.Color("muted", self.off or self.tip or "") } }
	end)
	act.max = aButton("Max", 38, -142, function() AUI.SetQty(AUI.SelectedRow() and AUI.SelectedRow().max or 1) end,
		function() return { { "As many as you can make now" }, { T.Color("muted", "From bags, banks and the warband bank, and your Concentration.") } } end)
	act.plus = aButton("+", 20, -184, function() AUI.SetQty(selQty + (IsShiftKeyDown and IsShiftKeyDown() and 10 or 1)) end,
		function() return { { "One more" }, { T.Color("muted", "Shift-click for 10.") } } end)
	act.qty = CH.Window.OneLine(CH.Window.Text(act, WIDTH - 206 - 34, -4, 32, "CENTER", "GameFontHighlight"))
	act.minus = aButton("-", 20, -242, function() AUI.SetQty(selQty - (IsShiftKeyDown and IsShiftKeyDown() and 10 or 1)) end,
		function() return { { "One fewer" }, { T.Color("muted", "Shift-click for 10.") } } end)
	CH.Window.OneLine(CH.Window.Text(act, WIDTH - 262 - 24, -4, 22, "RIGHT")):SetText("Qty")

	notes = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	notes:SetPoint("TOPLEFT", 12, ay - 28)
	notes:SetWidth(WIDTH - 24)
	notes:SetJustifyH("LEFT")
	notes:SetSpacing(3)

	-- Break-even chart and batch bars share one frame over the notes
	local chart = CreateFrame("Frame", nil, panel)
	chart:SetPoint("TOPLEFT", 0, ay - 26)
	chart:SetSize(WIDTH, PANE_H)
	chart:Hide()
	panel.chart = chart
	chart.title = CH.Window.OneLine(CH.Window.Text(chart, 12, 0, WIDTH - 24))
	chart.foot = CH.Window.OneLine(CH.Window.Text(chart, 12, -(PANE_H - 14), WIDTH - 24))
	chart.labels = {}
	for i = 1, 8 do chart.labels[i] = CH.Window.OneLine(CH.Window.Text(chart, 12, -16, 120)) end
	chart.dots = {}

	-- Top gear: equip the better set
	panel.equip = T.Button(panel, "Equip", 54, 16)
	panel.equip:SetPoint("BOTTOMRIGHT", -10, 64)
	panel.equip:Hide()
	panel.equip:SetScript("OnClick", function()
		local g = gearPick
		if g and g.set then
			local ok, why = CH.Gear.Equip(g.set)
			if not ok then CH.Print("can't change gear " .. (why or "")) end
			C_Timer.After(1, function() AUI.Show() end)
		end
	end)

	-- Simulation bar
	local simBar = CreateFrame("Frame", nil, panel)
	simBar:SetPoint("BOTTOMLEFT", 6, 36)
	simBar:SetPoint("BOTTOMRIGHT", -6, 36)
	simBar:SetHeight(22)
	panel.simText = simBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	panel.simText:SetPoint("LEFT", 6, 0)
	local function stepper(label, x, d)
		local b = T.Button(simBar, label, 30, 18)
		b:SetPoint("RIGHT", x, 0)
		b:SetScript("OnClick", function()
			sim.skill = math.max(0, sim.skill + (IsShiftKeyDown and IsShiftKeyDown() and d * 5 or d))
			AUI.Show()
		end)
		return b
	end
	stepper("+1", -4, 1)
	stepper("-1", -38, -1)
	local off = T.Button(simBar, "Off", 34, 18)
	off:SetPoint("RIGHT", -72, 0)
	off:SetScript("OnClick", function() sim.skill = 0; sim.plan = nil; AUI.Show() end)

	panel.status = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	panel.status:SetPoint("BOTTOMRIGHT", -10, 14)
	panel.status:SetJustifyH("RIGHT")
	T.Fonts(panel)
	CH.Window.Attach("advisor", panel)
	AUI.Place()
end

local shown -- the result on screen, for the hover breakdowns

-- Concentration you have now for the open profession, if known.
local function concNow()
	local ui = C_TradeSkillUI
	local info = ui.GetChildProfessionInfo and ui.GetChildProfessionInfo()
	local id = info and ui.GetConcentrationCurrencyID and ui.GetConcentrationCurrencyID(info.professionID)
	local c = id and id ~= 0 and C_CurrencyInfo.GetCurrencyInfo(id)
	return c and c.quantity
end

local function money(c)
	if not c then return CH.Theme.Color("muted", "no price") end
	return CH.Theme.Color(c >= 0 and "ok" or "bad", CH.FormatMoney(c))
end

--- Fill the panel from an Advisor result (or a reason it has none). Returns the lines it wrote, for tests.
function AUI.Render(result, reason)
	if not panel then build() end
	local T = CH.Theme
	for _, r in ipairs(rows) do
		r.bg:Hide()
		r.sel:Hide()
		for _, fs in ipairs(r.cells) do fs:SetText("") end
	end
	shown = result
	if not result then
		panel.recipe:SetText(T.Color("muted", reason or "Select a recipe."))
		notes:SetText("")
		AUI.RenderAction()
		AUI.RenderPane()
		return {}
	end
	-- a new recipe (or order) selects its recommended craft, one of it
	local rkey = tostring(result.recipeID) .. (result.order and ":order" or "")
	if rkey ~= selRecipe then
		selRecipe, selQty = rkey, 1
		local pick = result.best or result.bestConc
		sel = pick and { quality = pick.quality, conc = pick.concentration ~= nil } or nil
	end
	local itemID = (result.best and result.best.item) or (result.bestConc and result.bestConc.item) or (result.model and result.model.output)
	local head = CH.Window.ItemIcon(itemID, 18) .. T.Color("accent", result.name or "?") .. (result.made ~= 1 and T.Color("muted", string.format("  makes %.1f", result.made)) or "")
	if result.order then
		local o = result.order
		head = head .. T.Color("muted", "  order" .. (o.customer and (" for " .. o.customer) or "")
			.. (o.minQuality and o.minQuality > 1 and ("  min Q" .. o.minQuality) or "") .. "  pays ") .. CH.FormatMoney((o.commission or 0) + (o.rewards or 0))
	elseif result.model and result.model.recraftFrom then
		head = head .. T.Color("muted", "  recraft from Q" .. result.model.recraftFrom)
	end
	if result.sim then head = head .. "  " .. T.Color("bad", "SIM") end
	panel.recipe:SetText(head)
	local out = {}
	for i, r in ipairs(result.rows) do
		if i > ROWS then break end
		local row = rows[i]
		local q = qualityIcon(r.quality, result.model and result.model.maxQ) .. (r.short and T.Color("bad", " low")
			or r.recommended and T.Color("accent", " best") or r.bestConcentration and T.Color("accent", " conc") or "")
		row.cells[1]:SetText(q)
		row.cells[2]:SetText(r.concentration and tostring(r.concentration) or T.Color("muted", "-"))
		local pct = r.profit and r.cost and r.cost > 0 and string.format(" %d%%", math.floor(r.profit / r.cost * 100 + 0.5)) or ""
		r.max = CH.Advisor.MaxCraftable(result, r, concNow())
		row.cells[3]:SetText(CH.FormatMoney(r.cost))
		r.post = AUI.PostCheck(result, r)
		row.cells[4]:SetText(r.value and (r.post and T.Color("bad", CH.FormatMoney(r.value) .. " !") or CH.FormatMoney(r.value))
			or CH.Theme.Color("muted", "no price"))
		row.cells[5]:SetText(money(r.profit) .. (pct ~= "" and CH.Theme.Color(r.profit >= 0 and "ok" or "bad", pct) or ""))
		-- per point: what the points add over the plain craft (the whole profit per point is in the hover)
		local gpp = r.gain and r.gain.perPoint or r.perPoint
		row.cells[6]:SetText(gpp and money(gpp) or "")
		row.cells[7]:SetText(r.max > 0 and tostring(r.max) or CH.Theme.Color("muted", "0"))
		if r.recommended or r.bestConcentration then row.bg:Show() end
		if AUI.IsSelected(r) then row.sel:Show() end
		table.insert(out, string.format("Q%d %s cost=%s profit=%s pp=%s%s%s", r.quality, r.concentration and ("conc" .. r.concentration) or "plain",
			tostring(r.cost and math.floor(r.cost)), tostring(r.profit and math.floor(r.profit)), tostring(r.perPoint and math.floor(r.perPoint)),
			r.recommended and " BEST" or "", r.bestConcentration and " BESTCONC" or ""))
	end
	local lines = AUI.SummaryLines(result)
	for _, l in ipairs(AUI.FinishingLines(result)) do table.insert(lines, l) end
	local src = AUI.SourceLine(result)
	if src then table.insert(lines, src) end
	for _, l in ipairs(AUI.PostLines(result)) do table.insert(lines, l) end
	if #result.qual == 0 then table.insert(lines, T.Color("muted", "No reagent qualities to choose for this recipe.")) end
	local g = gearPick
	panel.equip:SetShown(g ~= nil and g.set ~= nil and not result.sim)
	if g and g.set then
		table.insert(lines, T.Color("accent", "Top gear: ") .. CH.Gear.SwapText(g.set) .. "  " .. T.Color("ok", "+" .. CH.FormatMoney(g.gain))
			.. T.Color("muted", g.mode == "conc" and " a point" or " a craft"))
	elseif g and g.current then
		table.insert(lines, T.Color("muted", "Top gear: you're wearing the best set for this."))
	end
	notes:SetText(table.concat(lines, "\n"))
	AUI.RenderAction()
	AUI.RenderPane()
	-- simulation bar
	local st = {}
	if sim.skill > 0 then table.insert(st, "+" .. sim.skill .. " skill") end
	if sim.plan then table.insert(st, "plan for " .. (sim.plan.label or "?") .. " (" .. (sim.plan.budget or 0) .. " points)") end
	panel.simText:SetText(T.Color("accent", "Simulate: ") .. (#st > 0 and table.concat(st, ", ") or T.Color("muted", "off")))
	if result.sim and live and live.best and result.best and live.best.profit and result.best.profit then
		local d = result.best.profit - live.best.profit
		panel.status:SetText("vs now: " .. T.Color(d >= 0 and "ok" or "bad", (d >= 0 and "+" or "") .. CH.FormatMoney(d)) .. " a craft")
	else
		panel.status:SetText("")
	end
	return out
end

local function pctText(x) return string.format("%d%%", math.floor(x * 100 + 0.5)) end

--- The decision summary at the top of the notes: the craft to make and its profit, its break-even
--- sale price against the estimate, the downside scenario and what the sales estimate rests on, then
--- what Concentration adds over it and how many crafts your points cover. Units on every number.
function AUI.SummaryLines(result)
	local T, M, Dc = CH.Theme, CH.FormatMoney, CH.Decide
	local mut = function(t) return T.Color("muted", t) end
	local lines = {}
	local b, c = result.best, result.bestConc
	if b then
		local roc = b.profit and b.cost and b.cost > 0 and b.profit / b.cost
		table.insert(lines, T.Color("accent", string.format("Craft Q%d: ", b.quality)) .. money(b.profit) .. " expected profit per craft"
			.. (roc and mut("  (return on cost " .. pctText(roc) .. ")") or ""))
		local be = b.breakEven
		if be then
			local cushion = be.cushion >= 0 and mut(string.format(": the price can fall %s before it loses", pctText(be.cushion)))
				or T.Color("bad", ": already below break-even")
			table.insert(lines, "  Break-even " .. M(be.price) .. mut(" per item, estimated sale price ") .. M(be.estimate) .. mut(" per item") .. cushion)
		end
		local parts = Dc and Dc.RowParts(result, b)
		if parts then
			local sc = Dc.Scenario()
			local down = Dc.Reprice(parts, sc.reagents, sc.price)
			local basis = Dc.EvidenceText(Dc.Evidence(b.item)).basis
			table.insert(lines, "  Downside " .. money(down) .. mut(string.format(" per craft if reagents rise %s and the price falls %s", pctText(sc.reagents), pctText(sc.price)))
				.. mut("; sell rate: " .. basis))
		end
		table.insert(lines, mut("  Use ") .. CH.Advisor.PicksText(result, b.picks, b.finishing))
	elseif result.order then
		table.insert(lines, T.Color("bad", "No reagents reach the quality this order asks for without Concentration."))
	end
	if c then
		local g = c.gain
		local head = T.Color("accent", string.format("Concentration Q%d: ", c.quality))
		if g and b then
			head = head .. money(g.gain) .. " more per craft than the plain craft, " .. money(g.perPoint) .. " per expected point"
		else
			head = head .. money(c.profit) .. " per craft, " .. money(g and g.perPoint or c.perPoint) .. " per expected point"
		end
		table.insert(lines, head .. mut(string.format("  (%d points; %s a point in all)", c.concentration or 0, M(c.perPoint or 0))))
		local f = Dc and Dc.ConcForecastFor(c, concNow())
		if f then table.insert(lines, mut("  " .. Dc.ConcForecastText(f) .. ".")) end
		table.insert(lines, mut("  Use ") .. CH.Advisor.PicksText(result, c.picks, c.finishing))
	end
	return lines
end

-- Break-even chart --------------------------------------------------------------------------------

--- The chart's lines: profit per craft for the plain and Concentration crafts as the sale price moves,
--- in steps of the estimated price (factor 1 = the estimate). { lo, hi, ymin, ymax, series = { { label,
--- color, be, estimate, points = { {f, profit} } } } }, or nil when nothing has a price.
function AUI.ChartData(result, steps)
	local Dc = CH.Decide
	if not (Dc and result) or result.order then return nil end
	steps = steps or 48
	local series = {}
	local function add(r, label, color)
		local parts = r and Dc.RowParts(result, r)
		if parts and r.price and r.price > 0 then table.insert(series, { r = r, parts = parts, label = label, color = color, be = r.breakEven, estimate = r.price }) end
	end
	if result.best then add(result.best, string.format("Plain Q%d", result.best.quality), "accent") end
	if result.bestConc then add(result.bestConc, string.format("Concentration Q%d", result.bestConc.quality), "ok") end
	if #series == 0 then return nil end
	local lo, hi = 0.5, 1.3
	for _, s in ipairs(series) do if s.be and s.be.factor < lo + 0.1 then lo = math.max(0, s.be.factor - 0.1) end end
	local ymin, ymax = 0, 0
	for _, s in ipairs(series) do
		s.points = {}
		for k = 0, steps do
			local f = lo + (hi - lo) * k / steps
			local y = Dc.ProfitAt(s.parts, s.estimate, f * s.estimate)
			s.points[#s.points + 1] = { f, y }
			ymin, ymax = math.min(ymin, y), math.max(ymax, y)
		end
	end
	if ymax - ymin < 1 then ymax = ymin + 1 end
	return { lo = lo, hi = hi, ymin = ymin, ymax = ymax, series = series }
end

--- The chart's legend lines, for its foot and the tests.
function AUI.ChartLines(data)
	local T, M = CH.Theme, CH.FormatMoney
	local out = {}
	for _, s in ipairs(data and data.series or {}) do
		local be = s.be
		table.insert(out, T.Color(s.color, s.label) .. ": " .. (be and ("breaks even at " .. M(be.price) .. " per item, "
			.. (be.cushion >= 0 and (pctText(be.cushion) .. " under") or (pctText(-be.cushion) .. " over")) .. " the estimate of " .. M(s.estimate))
			or "no break-even price"))
	end
	return out
end

local function chartTexture(chart, i)
	local t = chart.dots[i]
	if not t then
		t = chart:CreateTexture(nil, "ARTWORK")
		chart.dots[i] = t
	end
	return t
end

local function drawChart(chart, data)
	local T = CH.Theme
	local x0, y0, w, h = 70, 18, WIDTH - 70 - 16, PANE_H - 18 - 44
	local n = 0
	local function dot(px, py, sw, sh, color, a)
		n = n + 1
		local t = chartTexture(chart, n)
		local c = T[color] or T.fg or { 1, 1, 1 }
		t:SetColorTexture(c[1], c[2], c[3], a or 1)
		t:ClearAllPoints()
		t:SetPoint("TOPLEFT", chart, "TOPLEFT", x0 + px, -(y0 + py))
		t:SetSize(sw, sh)
		t:Show()
	end
	local function X(f) return (f - data.lo) / (data.hi - data.lo) * w end
	local function Y(v) return (data.ymax - v) / (data.ymax - data.ymin) * h end
	dot(0, Y(0), w, 1, "muted", 0.6)                 -- zero profit
	dot(X(1), 0, 1, h, "muted", 0.6)                 -- the estimate
	for _, s in ipairs(data.series) do
		for _, p in ipairs(s.points) do dot(X(p[1]) - 1, Y(p[2]) - 1, 3, 3, s.color) end
		if s.be and s.be.factor >= data.lo and s.be.factor <= data.hi then dot(X(s.be.factor) - 3, Y(0) - 3, 7, 7, "bad") end
	end
	for i = n + 1, #chart.dots do chart.dots[i]:Hide() end
	local L, M = chart.labels, CH.FormatMoney
	local function label(i, text, x, y, wd, just)
		local fs = L[i]
		fs:ClearAllPoints()
		fs:SetPoint("TOPLEFT", chart, "TOPLEFT", x, y)
		fs:SetWidth(wd)
		fs:SetJustifyH(just or "LEFT")
		fs:SetText(T.Color("muted", text))
		fs:Show()
	end
	label(1, M(data.ymax), 4, -y0, x0 - 8, "RIGHT")
	label(2, M(data.ymin), 4, -(y0 + h - 10), x0 - 8, "RIGHT")
	label(3, pctText(data.lo), x0, -(y0 + h + 2), 60)
	label(4, "estimate", x0 + X(1) - 30, -(y0 + h + 2), 60, "CENTER")
	label(5, pctText(data.hi), x0 + w - 60, -(y0 + h + 2), 60, "RIGHT")
	for i = 6, #L do L[i]:Hide() end
end

-- Batch analysis ----------------------------------------------------------------------------------

-- The row the batch analysis is for: the selected one, made as you can make it now.
local function batchRow()
	local r = AUI.SelectedRow()
	if r and shown and shown.sim then
		for _, lr in ipairs(live and live.rows or {}) do
			if lr.quality == r.quality and (lr.concentration ~= nil) == (r.concentration ~= nil) then return live, lr end
		end
		return nil
	end
	return shown, r
end

--- Batch outcomes for the selected craft (run once per row and kept): result, row, inputs, outcomes.
function AUI.BatchFor(result, r)
	if not (result and r and CH.Decide) or result.order then return nil end
	local key = table.concat({ result.recipeID or 0, r.quality, r.concentration and "c" or "", math.floor(r.cost or 0), math.floor(r.price or 0) }, ":")
	local hit = batchCache[key]
	if hit then return hit end
	local Dc = CH.Decide
	local inp = Dc.BatchInputs(result, r)
	if not inp then return nil end
	-- how many to make, then the simulation for half that, that and double it (10, 30 and 100 without one)
	local cf = r.concentration and Dc.ConcForecastFor(r, concNow())
	local sug = Dc.Suggest(inp, { gain = r.concentration and r.gain or nil, concCrafts = cf and cf.now or nil })
	local sizes
	if sug and sug.n > 0 then
		sizes = {}
		local seen = {}
		for _, n in ipairs({ math.max(1, math.floor(sug.n / 2 + 0.5)), sug.n, sug.n * 2 }) do
			if not seen[n] then seen[n] = true; sizes[#sizes + 1] = n end
		end
	end
	local out = { inputs = inp, suggest = sug, sizes = Dc.Batch(inp, sizes and { sizes = sizes } or nil) }
	batchCache[key] = out
	return out
end

--- Lines for the batch pane: one per batch size, then where the inputs come from.
function AUI.BatchLines(b)
	local T, M = CH.Theme, CH.FormatMoney
	local out = {}
	if not b then return out end
	local st = CH.Decide.SuggestText(b.suggest)
	if st then
		table.insert(out, st)
		if b.suggest.n > 0 then table.insert(out, b.suggest.why) end
	end
	for _, s in ipairs(b.sizes or {}) do
		table.insert(out, string.format("%d crafts: %s chance the week's sales pay back %s of reagents; median cash back %s, net %s; about %d left unsold (%s)",
			s.n, pctText(s.recover), M(s.spend), M(s.cashBack.p50 or 0), M(s.net.p50 or 0), math.floor((s.left or 0) + 0.5), M(s.leftValue or 0)))
	end
	local inp = b.inputs
	local ev = CH.Decide.EvidenceText(inp.evidence)
	local cap = CH.db.settings.scan and CH.db.settings.scan.dailyCap or 10
	table.insert(out, string.format("Sales %s a day for %d days (%s, capped at your %d a day). Price spread: falls %s or more in 1 run of 10 (Scenarios).",
		inp.daily % 1 == 0 and tostring(inp.daily) or string.format("%.1f", inp.daily), CH.Decide.HORIZON, ev.volume:gsub("^Volume: ", ""), cap, pctText(CH.Decide.Scenario().price)))
	table.insert(out, "Procs from your stats. Cash counts only what sells; unsold stock is valued apart. " .. ev.rate .. ".")
	return out
end

local function drawBatch(chart, b)
	local T, M = CH.Theme, CH.FormatMoney
	local sizes = b and b.sizes or {}
	local lo, hi = 0, 0
	for _, s in ipairs(sizes) do lo, hi = math.min(lo, s.net.p10 or 0), math.max(hi, s.net.p90 or 0) end
	if hi - lo < 1 then hi = lo + 1 end
	local x0, w = 200, WIDTH - 200 - 150
	local function X(v) return (v - lo) / (hi - lo) * w end
	local n = 0
	local function bar(px, py, sw, sh, color, a)
		n = n + 1
		local t = chartTexture(chart, n)
		local c = T[color] or { 1, 1, 1 }
		t:SetColorTexture(c[1], c[2], c[3], a or 1)
		t:ClearAllPoints()
		t:SetPoint("TOPLEFT", chart, "TOPLEFT", x0 + px, py)
		t:SetSize(math.max(1, sw), sh)
		t:Show()
	end
	local L = chart.labels
	for i, s in ipairs(sizes) do
		local y = -16 - (i - 1) * 20
		bar(X(s.net.p10), y - 3, X(s.net.p90) - X(s.net.p10), 10, (s.net.p50 or 0) >= 0 and "ok" or "bad", 0.45)
		bar(X(s.net.p50) - 1, y - 1, 3, 14, "fg")
		local l = L[i * 2 - 1]
		l:ClearAllPoints(); l:SetPoint("TOPLEFT", chart, "TOPLEFT", 12, y); l:SetWidth(184); l:SetJustifyH("LEFT")
		local mark = b.suggest and b.suggest.n == s.n and T.Color("accent", "> ") or ""
		l:SetText(mark .. string.format("%d crafts  ", s.n) .. T.Color(s.recover >= 0.8 and "ok" or s.recover >= 0.5 and "fg" or "bad", pctText(s.recover)) .. T.Color("muted", " pay back"))
		l:Show()
		local r = L[i * 2]
		r:ClearAllPoints(); r:SetPoint("TOPLEFT", chart, "TOPLEFT", WIDTH - 146, y); r:SetWidth(134); r:SetJustifyH("RIGHT")
		r:SetText(money(s.net.p50) .. T.Color("muted", string.format(", %d left", math.floor((s.left or 0) + 0.5))))
		r:Show()
	end
	if #sizes > 0 then bar(X(0), -14, 1, #sizes * 20, "muted", 0.8) end -- where the batch breaks even
	for i = n + 1, #chart.dots do chart.dots[i]:Hide() end
	for i = #sizes * 2 + 1, #L do L[i]:Hide() end
end

--- Show the notes, the break-even chart ("chart") or the batch analysis ("batch") under the rows.
function AUI.SetPane(p)
	pane = (p == "chart" or p == "batch") and p or "notes"
	AUI.RenderPane()
	return pane
end

function AUI.Pane() return pane end
--- The pane's title as shown, for the tests.
function AUI.PaneTitle() return panel and panel.chart and panel.chart.title:GetText() or "" end

--- Draw the area under the rows for the pane that's on. Returns its text lines, for the tests.
function AUI.RenderPane()
	if not panel or not panel.chart then return {} end
	local chart, T = panel.chart, CH.Theme
	local function setOn(b, on) if b and b.SetAlpha then b:SetAlpha(on and 1 or 0.7) end end
	setOn(panel.chartBtn, pane == "chart"); setOn(panel.batchBtn, pane == "batch")
	local lines = {}
	if pane == "notes" or not shown then
		chart:Hide(); notes:Show()
		return lines
	end
	notes:Hide(); chart:Show()
	if pane == "chart" then
		local data = AUI.ChartData(shown)
		if not data then
			chart.title:SetText(T.Color("muted", shown.order and "An order pays a set commission: there's no sale price to break even on." or "No sale price for this recipe."))
			chart.foot:SetText("")
			drawBatch(chart, nil)
			return lines
		end
		chart.title:SetText(T.Color("accent", "Break-even") .. T.Color("muted", "  profit per craft (up) against the sale price, as a share of the estimate (across)"))
		lines = AUI.ChartLines(data)
		chart.foot:SetText(table.concat(lines, "   "))
		drawChart(chart, data)
	else
		local result, r = batchRow()
		local b = AUI.BatchFor(result, r)
		if not b then
			chart.title:SetText(T.Color("muted", (shown and shown.order) and "Orders pay a set commission: there's no batch to sell." or "Select a craft with a sale price to analyze a batch."))
			chart.foot:SetText("")
			drawBatch(chart, nil)
			return lines
		end
		local sg = b.suggest
		chart.title:SetText(sg and sg.n > 0 and (T.Color("accent", "Make " .. sg.n) .. T.Color("muted", string.format(": %s at risk if slow; %d / %d / %d left in a week (slow / expected / fast)",
			CH.FormatMoney(sg.scenarios.slow.atRisk), math.floor(sg.scenarios.slow.left + 0.5), math.floor(sg.scenarios.expected.left + 0.5), math.floor(sg.scenarios.fast.left + 0.5))))
			or sg and T.Color("bad", sg.why) or (T.Color("accent", "Batch, " .. CH.Decide.HORIZON .. " days") .. T.Color("muted", "  bars: net cash, middle 80% of runs")))
		lines = AUI.BatchLines(b)
		local inp = b.inputs
		chart.foot:SetText(T.Color("muted", string.format("Bars: net cash, middle 80%% of runs. Sales %s a day, price -%s in 1 of 10.",
			inp.daily % 1 == 0 and tostring(inp.daily) or string.format("%.1f", inp.daily), pctText(CH.Decide.Scenario().price))))
		drawBatch(chart, b)
	end
	return lines
end

local function rankText(q, tiers)
	if not q then return "" end
	return " " .. CH.Window.QualityIcon(q, 14, tiers)
end

--- One line on finishing reagents for the advisor's notes: use the one you have, buy one that pays
--- for itself, or that none is worth it. Each option's gain is per plain craft.
function AUI.FinishingLines(result)
	local T, M = CH.Theme, CH.FormatMoney
	local adv = CH.Advisor.FinishingAdvice(result)
	if #adv == 0 or result.order then return {} end
	local name = CH.Advisor.ItemName
	local use, buy = nil, nil
	for _, a in ipairs(adv) do
		if a.verdict == "use" and not use then use = a end
		if a.verdict == "buy" and not buy then buy = a end
	end
	local out = {}
	if use then
		table.insert(out, T.Color("accent", "Finishing: ") .. string.format("use your %s (have %d)", name(use.itemID), use.own)
			.. "  " .. T.Color("ok", "+" .. M(use.gain)) .. T.Color("muted", " a craft, " .. use.effect))
	end
	if buy and (not use or buy.boughtGain > use.gain) then
		table.insert(out, T.Color("accent", use and "Or buy: " or "Finishing: ") .. string.format("buy %s at %s", name(buy.itemID), M(buy.buy))
			.. "  " .. T.Color("ok", "+" .. M(buy.boughtGain)) .. T.Color("muted", " a craft, " .. buy.effect))
	end
	if #out == 0 then
		table.insert(out, T.Color("muted", "Finishing: none pays for itself here"
			.. (adv[1].own > 0 and string.format(" (best you have: %s)", name(adv[1].itemID)) or "") .. "."))
	end
	return out
end

--- The expected-value steps for one unit (Expect.Value's detail): cut, deposits, carrying.
function AUI.ExpectLines(d)
	local out = {}
	if not d or not d.gross then return out end
	local M, mut = CH.FormatMoney, function(t) return CH.Theme.Color("muted", t) end
	table.insert(out, { "After 5% auction cut", M(d.gross) })
	if d.p then
		local b = d.belief
		table.insert(out, { string.format("Sells %d%% of posts", math.floor(d.p * 100 + 0.5))
			.. mut(b and b.n > 0 and string.format("  your %d posts + region", b.n) or "  region rate"), "" })
		if d.deposits >= 1 then table.insert(out, { "  Deposits lost to expiries", "-" .. M(d.deposits) }) end
		table.insert(out, { string.format("  Gold tied up %.1f days at %s%%/day", d.days, tostring(CH.Expect.Setting("carry") * 100)), "-" .. M(d.carry) })
		table.insert(out, { "Expected each", M(d.gross - d.deposits - d.carry) })
	end
	return out
end

--- A reagent's buy-now cost for the units a craft needs, when AH listings have been seen and it
--- differs from the estimate: { { label, money } } (empty otherwise). c: an Advisor.CostLines entry.
function AUI.BuyNowLines(c)
	local out = {}
	if not (c and c.id and not c.finishing and CH.Depth) then return out end
	local d = CH.Depth.Cost(c.id, c.n)
	if not d or d.source == "chmat" then return out end
	local from = d.source == "ah" and ("AH search " .. CH.Scans.Age(d.age) .. (d.age and d.age >= 60 and " ago" or ""))
		or ("AH scan " .. CH.Scans.Age(d.age) .. " old")
	local unit = math.floor(d.unit + 0.5)
	if c.unit and math.abs(unit - c.unit) < 0.005 * c.unit then return out end
	local mut = function(t) return CH.Theme.Color("muted", t) end
	table.insert(out, { mut("   buy now, " .. from), mut(CH.FormatMoney(unit) .. " ea  " .. CH.FormatMoney(d.cost)) })
	if (d.short or 0) > 0 then table.insert(out, { CH.Theme.Color("bad", "   only " .. (c.n - d.short) .. " listed"), "" }) end
	return out
end

--- A row's bought reagents totalled on each costing basis (Prices.ReagentCost), the one in use
--- marked: { { label, money } }. Reagents you craft and finishing reagents count as they are in the row.
function AUI.BasisLines(result, r)
	local out = {}
	local P, M, T = CH.Prices, CH.FormatMoney, CH.Theme
	if not (P and P.ReagentCost) then return out end
	local cur = P.CostBasis()
	local totals, missing, fell = {}, {}, {}
	for _, b in ipairs(P.BASES) do totals[b], missing[b], fell[b] = 0, false, 0 end
	for _, c in ipairs(CH.Advisor.CostLines(result, r.picks, r.finishing)) do
		for _, b in ipairs(P.BASES) do
			local each, from
			if c.finishing or c.crafted or not c.id then each, from = c.unit, b
			else each, from = P.ReagentCost(c.id, b) end
			if not each then missing[b] = true
			else
				totals[b] = totals[b] + each * c.n
				if from ~= b then fell[b] = fell[b] + 1 end
			end
		end
	end
	table.insert(out, { T.Color("accent", "Costing basis") .. T.Color("muted", "  /aiq basis to change"), "" })
	local why = { replacement = "  to buy them again today", tsm = "  as TSM's Crafting settings cost them", paid = "  what your last buys cost" }
	for _, b in ipairs(P.BASES) do
		local label = "   " .. P.BASIS_NAMES[b] .. (b == cur and T.Color("ok", "  in use") or T.Color("muted", why[b]))
		if fell[b] > 0 then label = label .. T.Color("muted", string.format("  (%d at replacement)", fell[b])) end
		table.insert(out, { label, missing[b] and T.Color("muted", "none") or M(math.floor(totals[b] + 0.5)) })
	end
	return out
end

--- What the item's posting operation would do, next to the market estimate (price): its min,
--- normal and max and where it would post against the freshest listings, or that it wouldn't.
function AUI.PostingLines(item, level, price)
	local out = {}
	local pc = item and CH.Auction and CH.Auction.PostCheck and CH.Auction.PostCheck(item, level)
	if not pc then return out end
	local M, T = CH.FormatMoney, CH.Theme
	table.insert(out, { T.Color("accent", "Posting") .. T.Color("muted", "  " .. tostring(pc.op or "no operation")), "" })
	table.insert(out, { "   Min / normal / max", string.format("%s / %s / %s", pc.min and M(pc.min) or "-", pc.normal and M(pc.normal) or "-", pc.max and M(pc.max) or "-") })
	local from = pc.source == "ah" and ("your AH search " .. CH.Scans.Age(pc.age) .. " ago")
		or pc.source == "scan" and ("your last AH scan, " .. CH.Scans.Age(pc.age) .. " old") or "no AH listings seen"
	if pc.cheapest then table.insert(out, { "   Cheapest listed" .. T.Color("muted", "  " .. from), M(pc.cheapest) })
	else table.insert(out, { T.Color("muted", "   " .. from), "" }) end
	if pc.action == "post" then
		table.insert(out, { "   Would post at" .. T.Color("muted", "  " .. (pc.why or "")), M(pc.price) })
		if price and pc.price and pc.price < price * 0.95 then
			table.insert(out, { T.Color("bad", "   Posts under the market estimate: profit is likely lower"), "" })
		end
	else
		table.insert(out, { T.Color("bad", "   Would not post: " .. (pc.why or "")), "" })
		table.insert(out, { T.Color("bad", "   The profit above assumes a sale the operation won't make now"), "" })
	end
	return out
end

--- Replacement cost (today's prices: should I craft another?) against paid cost (your purchases:
--- what did the last batch likely cost?), per item made, and how much of the paid figure is from
--- known purchases. Empty without TradeSkillMaster's accounting or for an order.
function AUI.PaidLines(result, r)
	local out = {}
	if result.order or not (CH.Ledger and CH.Ledger.Available() and CH.Scan and CH.Scan.Accounts) then return out end
	local ok, acc = pcall(CH.Scan.Accounts, result, r)
	if not ok or not acc then return out end
	local now = CH.Scan.CraftEach(r, result.made)
	local paid, share = CH.Ledger.CostAtPaid(acc, CH.Ledger.Paid())
	if not now or not paid then return out end
	local T, M = CH.Theme, CH.FormatMoney
	table.insert(out, { T.Color("accent", "Cost per item made") .. T.Color("muted", "  after Resourcefulness and Multicraft"), "" })
	table.insert(out, { "   Replacement, today's prices" .. T.Color("muted", "  craft another batch?"), M(now) })
	table.insert(out, { "   At what you paid" .. T.Color("muted", "  what this batch cost you"), M(paid) })
	table.insert(out, { T.Color("muted", string.format("   %s from your purchases (30 days), the rest at today's prices", pctText(share))), "" })
	return out
end

--- Lines for a row's hover breakdown: col 3 reagents, col 4 profit. Also used by the tests.
function AUI.BreakdownLines(result, r, col)
	local lines = {}
	local function add(l, rt) table.insert(lines, { l, rt }) end
	if col == 3 then
		add(CH.Theme.Color("accent", "Reagents") .. CH.Theme.Color("muted", "  estimated cost"))
		local live
		for _, c in ipairs(CH.Advisor.CostLines(result, r.picks, r.finishing)) do
			add(string.format("%dx %s%s", c.n, c.name, rankText(c.rank, c.tiers)) .. (c.crafted and CH.Theme.Color("muted", "  cost to craft") or ""),
				(c.unit and (CH.FormatMoney(c.unit) .. " ea  ") or "") .. CH.FormatMoney(c.total))
			-- what buying them really costs, from AH listings you've seen (walking up the book)
			for _, l in ipairs(AUI.BuyNowLines(c)) do add(l[1], l[2]); live = true end
		end
		add(CH.Theme.Color("accent", "Total"), CH.FormatMoney(r.cost))
		-- the same reagents on each costing basis: they answer different questions
		for _, l in ipairs(AUI.BasisLines(result, r)) do add(l[1], l[2]) end
		add(CH.Theme.Color("muted", "Replacement: TSM's last lowest listing, at least 80% of market value. An estimate for planning."))
		if live then add(CH.Theme.Color("muted", "Buy now: the listings you've seen for that many, which is what you'd pay.")) end
		-- two questions, two costs: restocking today against what the reagents you hold cost you
		for _, l in ipairs(AUI.PaidLines(result, r)) do add(l[1], l[2]) end
		if result.order and next(result.order.providedSlots or {}) then add(CH.Theme.Color("muted", "The customer provides the rest.")) end
	elseif col == 4 then
		local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(r.item) or ("item " .. tostring(r.item))
		add(CH.Theme.Color("accent", name) .. rankText(r.quality, result.model and result.model.maxQ))
		for _, src in ipairs(CH.Advisor.PriceSources(r.item)) do
			local v = src.value
			local text = not v and CH.Theme.Color("muted", "none")
				or src.kind == "rate" and string.format("%.0f%%", v <= 1 and v * 100 or v / 10) -- TSM gives 0-1 or x1000
				or src.kind == "count" and string.format(v % 1 == 0 and "%d" or "%.1f", v)
				or CH.FormatMoney(v)
			add("   " .. src.label, text)
		end
		local vals = CH.Prices.Values(r.item)
		if vals.realized then add(string.format("   RZ  Realized, your %d sales", vals.n), CH.FormatMoney(vals.realized)) end
		add("Market estimate (chvalue)", CH.FormatMoney(r.price and r.price / (r.shade or 1)))
		if r.shade then
			add(string.format("Your record: x%.2f", r.shade) .. CH.Theme.Color("muted", "  " .. (r.shadeWhy or "")), CH.FormatMoney(r.price))
		end
		for _, l in ipairs(AUI.ExpectLines(r.ev)) do add(l[1], l[2]) end
		if (result.made or 1) ~= 1 then add(string.format("x %.1f made", result.made), CH.FormatMoney(r.value)) end
		-- the operation that would post it decides separately from the estimate: show both
		if not result.order then
			local key = result.model and result.model.outputKeys and result.model.outputKeys[r.quality]
			local level = key and tonumber(tostring(key):match("::i(%d+)"))
			for _, l in ipairs(AUI.PostingLines(r.item, level, r.price)) do add(l[1], l[2]) end
		end
	elseif col == 5 then
		add(CH.Theme.Color("accent", "Average profit") .. CH.Theme.Color("muted", "  per craft"))
		add(result.order and "Commission and rewards" or "Expected sale value", CH.FormatMoney(r.value))
		add("Less reagents", CH.FormatMoney(-r.cost))
		local pp = r.parts
		if pp and pp.mc > 0 and not result.order then
			add(string.format("Multicraft  %d%% x %.1f more", math.floor(pp.mc * 100 + 0.5), pp.extraItems), "+" .. CH.FormatMoney(pp.mcGold))
		end
		if pp and pp.res > 0 then
			add(string.format("Resourcefulness  %d%% saves %s", math.floor(pp.res * 100 + 0.5), CH.FormatMoney(pp.saved)), "+" .. CH.FormatMoney(pp.resGold))
		end
		if r.oldValue then add("Less the item you recraft", CH.FormatMoney(-r.oldValue)) end
		add(CH.Theme.Color("accent", "Profit"), money(r.profit))
		if r.profit and r.cost and r.cost > 0 then add("Return on cost" .. CH.Theme.Color("muted", "  profit / reagents"), string.format("%d%%", math.floor(r.profit / r.cost * 100 + 0.5))) end
		-- margin: profit over what the craft brings in (proceeds, Multicraft's extras included)
		local proceeds = r.value and r.parts and (r.value + (r.parts.mcGold or 0))
		if r.profit and proceeds and proceeds > 0 and not result.order then
			add("Margin" .. CH.Theme.Color("muted", "  profit / proceeds"), string.format("%d%%", math.floor(r.profit / proceeds * 100 + 0.5)))
		end
		if r.breakEven then
			add("Break-even sale price", CH.FormatMoney(r.breakEven.price) .. " per item")
			add(CH.Theme.Color("muted", string.format("  estimate %s per item; can fall %s", CH.FormatMoney(r.breakEven.estimate),
				pctText(math.max(0, r.breakEven.cushion)))), "")
		end
		if r.concentration then
			local g = r.gain
			if g then
				add(string.format("Concentration %d points", r.concentration), "")
				add("  Over the best plain craft" .. CH.Theme.Color("muted", g.plain > 0 and "" or "  (none pays, so over not crafting)"), money(g.gain) .. " per craft")
				add("  Extra per expected point", money(g.perPoint))
				add(CH.Theme.Color("muted", "  Whole profit per point (as CraftSim)"), money(r.perPoint))
			else
				add(string.format("Concentration %d points", r.concentration), money(r.perPoint) .. " per point")
			end
			if (r.ingenuity or 0) > 0 then
				add(string.format("  Ingenuity %d%%, %.0f points on average", math.floor(r.ingenuity * 100 + 0.5), r.avgConcentration or r.concentration), "")
			end
		end
		if result.sim and live then
			for _, lr in ipairs(live.rows) do
				if lr.quality == r.quality and (lr.concentration ~= nil) == (r.concentration ~= nil) and lr.profit and r.profit then
					add(CH.Theme.Color("muted", "Now, without the simulation"), money(lr.profit))
					break
				end
			end
		end
	else
		local max, have = CH.Advisor.MaxCraftable(result, r, concNow())
		add(CH.Theme.Color("accent", "Can craft " .. max) .. CH.Theme.Color("muted", "  bags, banks and warband bank"))
		for _, h in ipairs(have) do
			local ok = h.have >= h.need
			add(h.name .. rankText(h.rank, h.tiers), CH.Theme.Color(ok and "fg" or "bad", string.format("%d have, %d each", h.have, h.need)))
		end
		if r.concentration then
			add("Concentration", string.format("%s have, %d each", tostring(concNow() or "?"), r.concentration))
		end
	end
	return lines
end

--- The hover column (cost, proceeds, profit, max) under the cursor on a row's frame, or nil.
function AUI.ColumnAt(frame)
	local left = frame.GetLeft and frame:GetLeft()
	if not left or not GetCursorPosition then return nil end
	local x = GetCursorPosition() / (frame:GetEffectiveScale() or 1) - left
	for _, col in ipairs(HOVER) do
		local c = COLS[col]
		if x >= 6 + c[2] and x <= 6 + c[2] + c[3] then return col end
	end
end

function AUI.ShowBreakdown(owner, i, col)
	local r = shown and shown.rows[i]
	if not r then return end
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	for _, l in ipairs(AUI.BreakdownLines(shown, r, col)) do
		if l[2] then GameTooltip:AddDoubleLine(l[1], l[2], 1, 1, 1, 1, 1, 1) else GameTooltip:AddLine(l[1]) end
	end
	GameTooltip:Show()
end

--- Update the advisor for a recipe (or the one on screen). It comes to the front unless another tab
--- is open: then it updates quietly, ready for when you click its tab.
function AUI.Show(recipeID, force)
	if not CH.db or (settings().hide and not force) or not ownProfession() then
		if panel then panel:Hide() end
		return
	end
	if recipeID and recipeID ~= current and not (order and order.spellID == recipeID) then order = nil end
	current = recipeID or current
	if not panel then build() end
	AUI.Place()
	if current then
		local ok, result, reason = pcall(AUI.Compute, current)
		if ok then
			AUI.Render(result, reason)
		else
			AUI.Render(nil, "Couldn't work this recipe out.")
			if CH.debugErrors ~= false then CH.Print("advisor error (please send this): " .. tostring(result)) end
		end
	else
		AUI.Render(nil)
	end
	if force or not CH.Window.Busy("advisor") then panel:Show() end
end

--- The Advisor tab: bring it to the front (turning it back on if it was closed).
function AUI.Open()
	if not CH.OpenProfessionID() and not current then
		CH.Print("open a profession to see the crafting advisor.")
		return
	end
	settings().hide = false
	AUI.Show(nil, true)
end

--- The simulated stat change for a recipe, or nil when the simulation is off.
function AUI.SimDelta(recipeID)
	if sim.skill == 0 and not sim.plan then return nil end
	local d = CH.Stats.New()
	d.skill = sim.skill
	local prof = CH.OpenProfessionID()
	if sim.plan and sim.plan.ranks and prof == sim.plan.prof then
		local tree = CH.Spec.Tree(prof)
		if tree then CH.Stats.Add(d, CH.Spec.Delta(prof, tree, sim.plan.ranks, recipeID)) end
	end
	return d
end

--- Measure the recipe (as an order or recraft when that's what's open) and evaluate it, with the
--- simulation if one is on. Also works out the top gear.
function AUI.Compute(recipeID)
	local prof = CH.OpenProfessionID()
	local opts = { professionID = prof }
	if order and order.spellID == recipeID then
		opts.order = CH.Orders.FromOrder(order)
	else
		local rc = CH.Orders and CH.Orders.RecraftContext()
		if rc then opts.allocationGUID, opts.recraftQuality = rc.guid, rc.quality end
	end
	local model, reason = CH.Advisor.Measure(recipeID, opts)
	if not model then return nil, reason end
	live = CH.Advisor.Evaluate(model)
	local result = live
	local d = AUI.SimDelta(recipeID)
	if d then result = CH.Advisor.Evaluate(model, { sim = d }) end
	gearPick = nil
	if not opts.order and CH.Gear then
		local ok, g = pcall(CH.Gear.Best, model, (live.bestConc and not live.best) and "conc" or nil)
		if ok then gearPick = g end
	end
	return result
end

--- The result on screen (for the results log to compare against).
function AUI.Current() return shown end

--- Show a crafting order from the Orders tab.
function AUI.ShowOrder(o)
	order = o
	if o and o.spellID then AUI.Show(o.spellID) end
end

--- Turn on the simulation of a knowledge point plan (from the Paths window).
function AUI.SetPlan(plan)
	sim.plan = plan
	if not plan then return end
	CH.Print("simulating the " .. (plan.label or "") .. " plan in the crafting advisor. Press Off on its Simulate bar to stop.")
	if ProfessionsFrame and ProfessionsFrame:IsShown() then AUI.Open() end
end

function AUI.SetSimSkill(n) sim.skill = n or 0 end

--- Is this advisor row the selected one?
function AUI.IsSelected(r)
	return sel ~= nil and r ~= nil and r.quality == sel.quality and (r.concentration ~= nil) == sel.conc
end

--- The selected row of the result on screen, or nil.
function AUI.SelectedRow()
	for i, r in ipairs(shown and shown.rows or {}) do
		if i > ROWS then break end
		if AUI.IsSelected(r) then return r end
	end
end

-- The same craft without the simulation: same quality, same Concentration choice.
local function liveMatch(r)
	for _, lr in ipairs(live and live.rows or {}) do
		if lr.quality == r.quality and (lr.concentration ~= nil) == (r.concentration ~= nil) then return lr end
	end
end

local function setLabel(b, t)
	if b.text then b.text:SetText(t) elseif b.SetText then b:SetText(t) end
end

--- What the queue button would do for the selected row: label, and why it can't (or nil).
function AUI.QueueAction()
	local r = AUI.SelectedRow()
	if not r then return "Queue", "Click a row to pick a craft first." end
	if shown.sim then
		local lr = liveMatch(r)
		if not lr then return "Queue live craft", "This quality is only reachable in the simulation. Press Off on the Simulate bar to see what you can make now." end
		return "Queue live craft", nil, lr
	end
	if r.short then
		return "Queue", string.format("This quality is below the Q%d the order asks for.", shown.order and shown.order.minQuality or 0)
	end
	return string.format("Queue %d %s", selQty, selQty == 1 and "craft" or "crafts"), nil, r
end

--- Draw the bar under the rows: the selected craft, the quantity, and the queue button.
function AUI.RenderAction()
	local act = panel and panel.act
	if not act then return end
	local T = CH.Theme
	act.qty:SetText(tostring(selQty))
	local r = AUI.SelectedRow()
	if r then
		act.label:SetText(T.Color("muted", "Selected ") .. qualityIcon(r.quality, shown.model and shown.model.maxQ)
			.. (r.concentration and T.Color("accent", " + " .. r.concentration .. " Conc.") or T.Color("muted", " no Conc."))
			.. "  " .. money(r.profit) .. T.Color("muted", " a craft") .. (shown.sim and T.Color("bad", "  SIM") or ""))
	else
		act.label:SetText(T.Color("muted", shown and "Click a row to pick a craft." or ""))
	end
	local label, off, target = AUI.QueueAction()
	setLabel(act.queue, label)
	act.queue.off = off
	act.queue.tip = target and (shown.sim
		and string.format("A simulated row. This queues %d of the same quality as you can make it now: %s a craft.", selQty, CH.FormatMoney(target.profit or 0))
		or string.format("Adds %d x Q%d%s with the reagents in the notes below.", selQty, target.quality,
			target.concentration and (", using " .. target.concentration .. " Concentration each") or ", no Concentration")) or nil
	act.queue:SetAlpha(off and 0.4 or 1)
	act:SetShown(shown ~= nil)
	AUI.RenderNext()
end

local nextCache = {} -- recovery chances by craft and quantity

--- The Next Move block's figures for the selected row and quantity: { head, sub, profit, breakEven,
--- recover (0..1 or nil), items, mc }. nil with nothing selected.
function AUI.NextMove()
	local r = shown and AUI.SelectedRow()
	if not r then return nil end
	local Dc = CH.Decide
	local qty = selQty
	local made = shown.made or 1
	local per = Dc and Dc.Items(made, r.parts) or made
	local mc = r.parts and (r.parts.mc or 0) > 0
	local out = { qty = qty, row = r, profit = r.profit, items = qty * per, mc = mc,
		breakEven = r.breakEven and r.breakEven.price, estimate = r.price }
	out.head = string.format("Craft %d × %s", qty, shown.name or "?")
	local n = math.floor(out.items + 0.5)
	if mc then out.sub = string.format("about %d items expected with Multicraft", n)
	elseif made ~= 1 or qty > 1 then out.sub = string.format("%d items", n) end
	if Dc and not shown.order then
		local key = table.concat({ shown.recipeID or 0, r.quality, r.concentration and "c" or "", math.floor(r.cost or 0), math.floor(r.price or 0), qty }, ":")
		local hit = nextCache[key]
		if hit == nil then
			local inp = Dc.BatchInputs(shown, r)
			local b = inp and Dc.Batch(inp, { sizes = { qty } })
			hit = b and b[1] or false
			nextCache[key] = hit
		end
		if hit then out.recover, out.batch = hit.recover, hit end
	end
	return out
end

--- Fill the Next Move block. Returns NextMove's figures, for the tests.
function AUI.RenderNext()
	local nx = panel and panel.next
	if not nx then return nil end
	local T, M = CH.Theme, CH.FormatMoney
	local m = AUI.NextMove()
	nx.lastMove = m
	if not m then
		nx.head:SetText(T.Color("muted", shown and "Click a row to pick a craft." or "Select a recipe."))
		nx.sub:SetText("")
		for _, v in ipairs(nx.stats) do v:SetText(T.Color("muted", "-")) end
		nx.fill:Hide()
		return nil
	end
	nx.head:SetText(m.head .. (m.row.concentration and T.Color("accent", "  Conc.") or "") .. (shown.sim and T.Color("bad", "  SIM") or ""))
	nx.sub:SetText(m.sub and T.Color("muted", m.sub) or "")
	nx.stats[1]:SetText(money(m.profit))
	nx.stats[2]:SetText(m.breakEven and T.Color("gold", M(m.breakEven)) or T.Color("muted", shown.order and "order" or "-"))
	if m.recover then
		nx.stats[3]:SetText(pctText(m.recover))
		T.Gradient(nx.fill)
		nx.fill:SetWidth(math.max(1, nx.barW * m.recover))
		nx.fill:Show()
	else
		nx.stats[3]:SetText(T.Color("muted", "-"))
		nx.fill:Hide()
	end
	return m
end

--- The Next Move hovers. which: nil for the craft line, "profit", "breakEven" or "recover" for a
--- figure: what it means, then the breakdown that reaches it.
function AUI.NextTip(which)
	local T, M = CH.Theme, CH.FormatMoney
	local mut = function(t) return T.Color("muted", t) end
	local m = (panel and panel.next and panel.next.lastMove) or AUI.NextMove()
	if not m then return { { "Next move" }, { mut("Click a row in the table to pick a craft, and set how many under it.") } } end
	local r = m.row
	local pp = r.parts
	if which == "profit" then
		local tip = { { "Profit" }, { mut("Expected profit for one craft, on average: what it sells for after the AH cut and deposits, less the reagents.") } }
		table.insert(tip, { shown.order and "Commission and rewards" or "Expected sale value", M(r.value or 0) })
		table.insert(tip, { "Less reagents", M(-(r.cost or 0)) })
		if pp and (pp.mc or 0) > 0 and not shown.order then
			table.insert(tip, { string.format("Multicraft  %s x %.1f more", pctText(pp.mc), pp.extraItems or 0), "+" .. M(pp.mcGold or 0) })
		end
		if pp and (pp.res or 0) > 0 then table.insert(tip, { string.format("Resourcefulness  %s", pctText(pp.res)), "+" .. M(pp.resGold or 0) }) end
		if r.oldValue then table.insert(tip, { "Less the item you recraft", M(-r.oldValue) }) end
		table.insert(tip, { T.Color("accent", "Profit per craft"), money(r.profit) })
		if r.profit and r.cost and r.cost > 0 then table.insert(tip, { "Return on cost" .. mut("  profit / reagents"), pctText(r.profit / r.cost) }) end
		local proceeds = r.value and pp and (r.value + (pp.mcGold or 0))
		if r.profit and proceeds and proceeds > 0 and not shown.order then table.insert(tip, { "Margin" .. mut("  profit / proceeds"), pctText(r.profit / proceeds) }) end
		if m.qty > 1 and r.profit then table.insert(tip, { string.format("For %d crafts", m.qty), money(r.profit * m.qty) }) end
		return tip
	elseif which == "breakEven" then
		local be = r.breakEven
		local tip = { { "Break-even" }, { mut("The sale price per item where this craft stops making money: below it, each craft loses gold.") } }
		if not be then
			table.insert(tip, { mut(shown.order and "An order pays a fixed commission, so it has no break-even price." or "No price to compare against yet.") })
			return tip
		end
		table.insert(tip, { "Break-even per item", T.Color("gold", M(be.price)) })
		table.insert(tip, { "Estimated sale price", M(be.estimate) })
		table.insert(tip, { "Room before a loss", be.cushion >= 0 and T.Color("ok", pctText(be.cushion)) or T.Color("bad", "already below") })
		table.insert(tip, { mut(string.format("Reagents %s%s, spread over about %.1f items a craft%s.", M(r.cost or 0),
			pp and (pp.resGold or 0) > 0 and (" less " .. M(pp.resGold) .. " Resourcefulness saves") or "", m.items / m.qty,
			r.oldValue and ", plus the item you recraft" or "")) })
		table.insert(tip, { mut("The AH cut and deposits are counted on every sale.") })
		return tip
	elseif which == "recover" then
		local tip = { { "Recover" }, { mut(string.format("The chance that a week's sales pay back what %d %s cost in reagents.", m.qty, m.qty == 1 and "craft" or "crafts")) } }
		local b = m.batch
		if not b then
			table.insert(tip, { mut(shown.order and "An order pays on delivery, so there's nothing to recover." or "Needs a price and a sales rate for this item.") })
			return tip
		end
		table.insert(tip, { "Chance to recover", pctText(b.recover) })
		table.insert(tip, { "Reagents spent", M(b.spend or 0) })
		table.insert(tip, { "Cash back by day " .. CH.Decide.HORIZON, M(b.cashBack.p50 or 0) .. mut("  median") })
		table.insert(tip, { mut("  middle 80%"), M(b.cashBack.p10 or 0) .. " to " .. M(b.cashBack.p90 or 0) })
		table.insert(tip, { "Items made", string.format("%d", math.floor((b.items or 0) + 0.5)) .. mut(string.format(", about %d unsold", math.floor((b.left or 0) + 0.5))) })
		table.insert(tip, { mut(string.format("From %d simulated weeks: your Multicraft and Resourcefulness, the item's sales rate and price swings (Scenarios).", CH.Decide.RUNS)) })
		return tip
	end
	local tip = { { "Next move" }, { mut(string.format("%d %s; the queue button adds them.", m.qty, m.qty == 1 and "craft" or "crafts")) } }
	if m.mc then table.insert(tip, { mut(string.format("Multicraft makes extra items: about %.1f in all, on average.", m.items)) }) end
	table.insert(tip, { mut("Hover Profit, Break-even or Recover for how each was reached.") })
	return tip
end

--- Set how many of the selected craft to queue (1 to 999).
function AUI.SetQty(n)
	selQty = math.max(1, math.min(999, math.floor(tonumber(n) or 1)))
	AUI.RenderAction()
	return selQty
end

--- Click a row to select it. Queueing is the button under the rows, so a stray click queues nothing.
function AUI.RowClick(i)
	local r = shown and shown.rows[i]
	if not r then return end
	if not AUI.IsSelected(r) then selQty = 1 end
	sel = { quality = r.quality, conc = r.concentration ~= nil }
	AUI.Render(shown)
end

--- Queue the selected craft, as many as the quantity says. Returns the queue entry, or nil and why.
function AUI.QueueSelected()
	local _, off, target = AUI.QueueAction()
	if off then CH.Print("can't queue that: " .. off); return nil, off end
	local from = shown.sim and live or shown
	local e = CH.Queue.Add(from, target, selQty)
	-- what the simulation says about this batch, kept to check against what it really brings in
	if CH.Decide and not from.order then
		local inp = CH.Decide.BatchInputs(from, target)
		local s = inp and CH.Decide.Batch(inp, { sizes = { selQty }, runs = 300 })
		if s and s[1] then CH.Decide.SaveForecast(target.item, from.recipeID, s[1]) end
	end
	CH.Print(string.format("queued %d x %s (Q%d%s)", selQty, from.name or "?", target.quality, target.concentration and ", Concentration" or ""))
	if not CH.Window.InTabs("queue") then CH.QueueUI.Show() end
	return e
end

--- Whether posting would treat a row's item differently from its expected proceeds: below its
--- operation's min price, or an operation that doesn't post it. nil when it posts normally.
--- { kind = "min" | "nopost", op, min, reset }.
function AUI.PostCheck(result, r)
	if result.order or not r.price or not r.item or not (CH.Groups and CH.Groups.Prices) then return nil end
	local key = result.model and result.model.outputKeys and result.model.outputKeys[r.quality]
	local level = key and tonumber(tostring(key):match("::i(%d+)"))
	local ok, p = pcall(CH.Groups.Prices, r.item, nil, level)
	if not ok or not p then return nil end
	if p.post == false then return { kind = "nopost", op = p.op } end
	if p.min and r.price < p.min then return { kind = "min", op = p.op, min = p.min, reset = p.priceReset } end
end

--- Where the proceeds come from, in one muted line for the notes.
function AUI.SourceLine(result)
	local T = CH.Theme
	if result.order then return T.Color("muted", "Expected proceeds: what the order pays, commission and rewards.") end
	local shaded, modeled = {}, false
	for i, r in ipairs(result.rows) do
		if i > ROWS then break end
		if r.shade then table.insert(shaded, string.format("Q%d x%.2f", r.quality, r.shade)) end
		if r.ev and r.ev.p then modeled = true end
	end
	local text = "Expected proceeds: TSM price (chvalue) after the 5% cut" .. (modeled and ", expected deposits and carrying" or "")
	if #shaded > 0 then text = text .. ". Your sales: " .. table.concat(shaded, ", ") end
	text = text .. ". Hover for each step."
	-- the evidence behind the recommended craft's estimate: source, age, and how much is yours
	local pick = result.best or result.bestConc
	if pick and pick.item and CH.Decide then
		local e = CH.Decide.EvidenceText(CH.Decide.Evidence(pick.item))
		text = text .. "\n" .. e.price .. ". " .. e.rate .. ". " .. e.sales .. ". " .. e.volume .. "."
	end
	return T.Color("muted", text)
end

--- Lines for rows whose item posting wouldn't sell at the proceeds shown (marked ! in the table),
--- one for each quality: a plain and a Concentration row of one quality make the same item.
function AUI.PostLines(result)
	local T, M = CH.Theme, CH.FormatMoney
	local out, seen = {}, {}
	for i, r in ipairs(result.rows) do
		if i > ROWS then break end
		local p = r.post
		if p and not seen[r.quality] then
			seen[r.quality] = true
			local tag = T.Color("bad", string.format("Q%d !", r.quality))
			if p.kind == "nopost" then
				table.insert(out, tag .. T.Color("muted", string.format(" Your %s operation doesn't post this item.", p.op or "?")))
			else
				local what = (not p.reset or p.reset == "none" or p.reset == "ignore") and "posting would skip it"
					or ("posting lists it at your " .. tostring(p.reset):gsub("Price", "") .. " price instead")
				table.insert(out, tag .. T.Color("muted", string.format(" Below posting minimum (%s min %s): %s.", p.op or "?", M(p.min), what)))
			end
		end
	end
	return out
end

function AUI.UpdateQueueButton()
	if panel and panel.queue then
		local n = CH.Queue.Count()
		local t = n > 0 and ("Queue " .. n) or "Queue"
		if panel.queue.text then panel.queue.text:SetText(t) elseif panel.queue.SetText then panel.queue:SetText(t) end
	end
end

function AUI.Hide()
	if panel then panel:Hide() end
end

function AUI.IsShown() return panel ~= nil and panel:IsShown() end

function AUI.ToggleSetting()
	local s = settings()
	s.hide = not s.hide
	if s.hide then AUI.Hide() elseif ProfessionsFrame and ProfessionsFrame:IsShown() then AUI.Show() end
	CH.Print("crafting advisor " .. (s.hide and "off" or "on"))
end

local hooked = false
local function hook()
	if hooked then return end
	if EventRegistry and EventRegistry.RegisterCallback then
		EventRegistry:RegisterCallback("ProfessionsRecipeListMixin.Event.OnRecipeSelected", function(_, info)
			if info and info.recipeID then AUI.Show(info.recipeID) end
		end, AUI)
		hooked = true
	end
	if ProfessionsFrame and ProfessionsFrame.HookScript then
		ProfessionsFrame:HookScript("OnHide", function()
			AUI.Hide()
			if CH.db.settings.advisor.docked ~= false then CH.Window.CloseTabs() end
		end)
	end
end

CH.On("TRADE_SKILL_SHOW", function() hook(); AUI.Show() end)
CH.On("TRADE_SKILL_CLOSE", AUI.Hide)
