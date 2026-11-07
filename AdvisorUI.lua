-- Crafting advisor panel: docked to the right of the profession window, or dragged off to stand on
-- its own. Shows every result quality for the selected recipe, marks CraftSim-style picks.
local _, CH = ...

local AUI = {}
CH.AdvisorUI = AUI
local panel, rows, notes, current
local ROWS = 8
-- name, x, width. Hover breakdowns on cost (3), sell (4), profit (5) and max (7).
local COLS = { { "Quality", 0, 50 }, { "Conc.", 50, 40 }, { "Cost", 90, 72 }, { "Sells for", 162, 72 },
	{ "Profit", 234, 104 }, { "Per pt", 338, 58 }, { "Max", 396, 34 } }
local HOVER = { 3, 4, 5, 7 }
local WIDTH = 454

local function settings() return CH.db.settings.advisor end

local function qualityIcon(q)
	if CreateAtlasMarkup then
		return CreateAtlasMarkup("Professions-Icon-Quality-Tier" .. q .. "-Small", 18, 18)
	end
	return "Q" .. q
end

local function ownProfession()
	local ui = C_TradeSkillUI
	return not ((ui.IsTradeSkillLinked and ui.IsTradeSkillLinked()) or (ui.IsTradeSkillGuild and ui.IsTradeSkillGuild())
		or (ui.IsNPCCrafting and ui.IsNPCCrafting()))
end

function AUI.Place()
	if not panel then return end
	local s = settings()
	panel:ClearAllPoints()
	if s.docked ~= false and ProfessionsFrame then
		panel:SetPoint("TOPLEFT", ProfessionsFrame, "TOPRIGHT", 2, 0)
	elseif s.point then
		panel:SetPoint(s.point[1], UIParent, s.point[3], s.point[4], s.point[5])
	else
		panel:SetPoint("CENTER")
	end
	if panel.dock then panel.dock:SetShown(s.docked == false) end
end

local function build()
	local T = CH.Theme
	panel = CreateFrame("Frame", "ClearinghouseAdvisor", UIParent, "BackdropTemplate")
	T.Panel(panel, "bg", 0.95)
	panel:SetSize(WIDTH, 330)
	panel:SetFrameStrata("HIGH")
	panel:SetMovable(true)
	panel:SetClampedToScreen(true)
	panel:EnableMouse(true)
	panel:RegisterForDrag("LeftButton")
	panel:SetScript("OnDragStart", function(self)
		settings().docked = false
		self:StartMoving()
	end)
	panel:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local p, _, rp, x, y = self:GetPoint()
		settings().point = { p, nil, rp, x, y }
		AUI.Place()
	end)
	panel:Hide()

	local bar = CreateFrame("Frame", nil, panel, "BackdropTemplate")
	T.Panel(bar, "panel", 1)
	bar:SetPoint("TOPLEFT")
	bar:SetPoint("TOPRIGHT")
	bar:SetHeight(26)
	local rule = bar:CreateTexture(nil, "ARTWORK")
	rule:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 1)
	rule:SetPoint("BOTTOMLEFT", 1, 0)
	rule:SetPoint("BOTTOMRIGHT", -1, 0)
	rule:SetHeight(1)
	local badge = bar:CreateTexture(nil, "ARTWORK")
	badge:SetTexture("Interface\\AddOns\\Clearinghouse\\Media\\Icon")
	badge:SetSize(18, 18)
	badge:SetPoint("LEFT", 5, 0)
	local title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("LEFT", badge, "RIGHT", 6, 0)
	title:SetText(T.Color("accent", "Clearinghouse") .. "  " .. T.Color("muted", "Crafting advisor"))
	local close = T.Button(bar, "x", 18, 18)
	close:SetPoint("RIGHT", -4, 0)
	close:SetScript("OnClick", function() settings().hide = true; panel:Hide(); CH.Print("advisor hidden. /ch advisor brings it back.") end)
	local dock = T.Button(bar, "Dock", 44, 18)
	dock:SetPoint("RIGHT", close, "LEFT", -4, 0)
	dock:SetScript("OnClick", function() settings().docked = true; AUI.Place() end)
	panel.dock = dock

	panel.recipe = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	panel.recipe:SetPoint("TOPLEFT", 12, -34)
	panel.recipe:SetWidth(WIDTH - 24)
	panel.recipe:SetJustifyH("LEFT")

	local y = -56
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
		for j, c in ipairs(COLS) do
			local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			fs:SetPoint("TOPLEFT", 12 + c[2], y - i * 20)
			fs:SetWidth(c[3])
			fs:SetJustifyH(j == 1 and "LEFT" or "RIGHT")
			r.cells[j] = fs
		end
		r.hover = {}
		for _, col in ipairs(HOVER) do
			local h = CreateFrame("Frame", nil, panel)
			h:SetPoint("TOPLEFT", 12 + COLS[col][2], y - i * 20 + 3)
			h:SetSize(COLS[col][3], 18)
			h:EnableMouse(true)
			h:SetScript("OnEnter", function(self) AUI.ShowBreakdown(self, i, col) end)
			h:SetScript("OnLeave", function() GameTooltip:Hide() end)
			r.hover[col] = h
		end
		rows[i] = r
	end
	notes = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	notes:SetPoint("TOPLEFT", 12, y - (ROWS + 1) * 20 - 6)
	notes:SetWidth(WIDTH - 24)
	notes:SetJustifyH("LEFT")
	notes:SetSpacing(3)
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
		for _, fs in ipairs(r.cells) do fs:SetText("") end
	end
	shown = result
	if not result then
		panel.recipe:SetText(T.Color("muted", reason or "Select a recipe."))
		notes:SetText("")
		return {}
	end
	panel.recipe:SetText(T.Color("accent", result.name or "?") .. (result.made ~= 1 and T.Color("muted", string.format("  makes %.1f", result.made)) or ""))
	local out = {}
	for i, r in ipairs(result.rows) do
		if i > ROWS then break end
		local row = rows[i]
		local q = qualityIcon(r.quality) .. (r.recommended and T.Color("accent", " best") or r.bestConcentration and T.Color("accent", " conc") or "")
		row.cells[1]:SetText(q)
		row.cells[2]:SetText(r.concentration and tostring(r.concentration) or T.Color("muted", "-"))
		local pct = r.profit and r.cost and r.cost > 0 and string.format(" %d%%", math.floor(r.profit / r.cost * 100 + 0.5)) or ""
		r.max = CH.Advisor.MaxCraftable(result, r, concNow())
		row.cells[3]:SetText(CH.FormatMoney(r.cost))
		row.cells[4]:SetText(r.value and CH.FormatMoney(r.value) or CH.Theme.Color("muted", "no price"))
		row.cells[5]:SetText(money(r.profit) .. (pct ~= "" and CH.Theme.Color(r.profit >= 0 and "ok" or "bad", pct) or ""))
		row.cells[6]:SetText(r.perPoint and money(r.perPoint) or "")
		row.cells[7]:SetText(r.max > 0 and tostring(r.max) or CH.Theme.Color("muted", "0"))
		if r.recommended or r.bestConcentration then row.bg:Show() end
		table.insert(out, string.format("Q%d %s cost=%s profit=%s pp=%s%s%s", r.quality, r.concentration and ("conc" .. r.concentration) or "plain",
			tostring(r.cost and math.floor(r.cost)), tostring(r.profit and math.floor(r.profit)), tostring(r.perPoint and math.floor(r.perPoint)),
			r.recommended and " BEST" or "", r.bestConcentration and " BESTCONC" or ""))
	end
	local lines = {}
	if result.best then
		table.insert(lines, T.Color("accent", "Recommended: ") .. CH.Advisor.PicksText(result, result.best.picks))
	end
	if result.bestConc then
		table.insert(lines, T.Color("accent", "With Concentration: ") .. CH.FormatMoney(result.bestConc.perPoint) .. " per point, using "
			.. CH.Advisor.PicksText(result, result.bestConc.picks))
	end
	if #result.qual == 0 then table.insert(lines, T.Color("muted", "No reagent qualities to choose for this recipe.")) end
	notes:SetText(table.concat(lines, "\n"))
	return out
end

local function rankText(q)
	if not q then return "" end
	return CreateAtlasMarkup and (" " .. CreateAtlasMarkup("Professions-Icon-Quality-Tier" .. q .. "-Small", 14, 14)) or (" Q" .. q)
end

--- Lines for a row's hover breakdown: col 3 reagents, col 4 profit. Also used by the tests.
function AUI.BreakdownLines(result, r, col)
	local lines = {}
	local function add(l, rt) table.insert(lines, { l, rt }) end
	if col == 3 then
		add(CH.Theme.Color("accent", "Reagents") .. CH.Theme.Color("muted", "  bought at chmat"))
		for _, c in ipairs(CH.Advisor.CostLines(result, r.picks)) do
			add(string.format("%dx %s%s", c.n, c.name, rankText(c.rank)),
				(c.unit and (CH.FormatMoney(c.unit) .. " ea  ") or "") .. CH.FormatMoney(c.total))
		end
		add(CH.Theme.Color("accent", "Total"), CH.FormatMoney(r.cost))
	elseif col == 4 then
		local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(r.item) or ("item " .. tostring(r.item))
		add(CH.Theme.Color("accent", name) .. rankText(r.quality))
		for _, src in ipairs(CH.Advisor.PriceSources(r.item)) do
			local v = src.value
			local text = not v and CH.Theme.Color("muted", "none")
				or src.kind == "rate" and string.format("%.0f%%", v <= 1 and v * 100 or v / 10) -- TSM gives 0-1 or x1000
				or src.kind == "count" and string.format(v % 1 == 0 and "%d" or "%.1f", v)
				or CH.FormatMoney(v)
			add("   " .. src.label, text)
		end
		add("Clearinghouse value (chvalue)", CH.FormatMoney(r.value and r.value / CH.AH_CUT / (result.made or 1)))
		if (result.made or 1) ~= 1 then add(string.format("x %.1f made", result.made), "") end
		add("After 5% auction cut", CH.FormatMoney(r.value))
	elseif col == 5 then
		add(CH.Theme.Color("accent", "Profit"))
		add("Sells for, after cut", CH.FormatMoney(r.value))
		add("Less reagents", CH.FormatMoney(-r.cost))
		add(CH.Theme.Color("accent", "Profit"), money(r.profit))
		if r.profit and r.cost and r.cost > 0 then add("Return on reagents", string.format("%d%%", math.floor(r.profit / r.cost * 100 + 0.5))) end
		if r.concentration then
			add(string.format("Concentration %d points", r.concentration), money(r.perPoint) .. " per point")
		end
	else
		local max, have = CH.Advisor.MaxCraftable(result, r, concNow())
		add(CH.Theme.Color("accent", "Can craft " .. max) .. CH.Theme.Color("muted", "  bags, banks and warband bank"))
		for _, h in ipairs(have) do
			local ok = h.have >= h.need
			add(h.name .. rankText(h.rank), CH.Theme.Color(ok and "fg" or "bad", string.format("%d have, %d each", h.have, h.need)))
		end
		if r.concentration then
			add("Concentration", string.format("%s have, %d each", tostring(concNow() or "?"), r.concentration))
		end
	end
	return lines
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

function AUI.Show(recipeID)
	if not CH.db or settings().hide or not ownProfession() then
		if panel then panel:Hide() end
		return
	end
	current = recipeID or current
	if not panel then build() end
	AUI.Place()
	if current then
		local ok, result, reason = pcall(CH.Advisor.Analyze, current)
		if ok then AUI.Render(result, reason) else AUI.Render(nil, "Couldn't work this recipe out.") end
	else
		AUI.Render(nil)
	end
	panel:Show()
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
	if ProfessionsFrame and ProfessionsFrame.HookScript then ProfessionsFrame:HookScript("OnHide", AUI.Hide) end
end

CH.On("TRADE_SKILL_SHOW", function() hook(); AUI.Show() end)
CH.On("TRADE_SKILL_CLOSE", AUI.Hide)
