-- Crafting advisor panel: docked to the right of the profession window, or dragged off to stand on
-- its own. Shows every result quality for the selected recipe, marks CraftSim-style picks.
local _, CH = ...

local AUI = {}
CH.AdvisorUI = AUI
local panel, rows, notes, current
local ROWS = 8
local HEIGHT = 430
-- Simulation: extra skill, and a knowledge point plan from the Paths window.
local sim = { skill = 0, plan = nil }
local order -- the crafting order on screen, if any
local live -- the result without simulation, to compare against
local gearPick -- top gear for the recipe on screen
-- name, x, width. Hover breakdowns on cost (3), sell (4), profit (5) and max (7).
local COLS = { { "Quality", 0, 70 }, { "Conc.", 70, 50 }, { "Cost", 120, 86 }, { "Sells for", 206, 86 },
	{ "Avg profit/craft", 292, 124 }, { "Per pt", 416, 70 }, { "Max", 486, 40 } }
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

local shown, selected

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
	badge:SetTexture(CH.ICON)
	badge:SetSize(18, 18)
	badge:SetPoint("LEFT", 5, 0)
	local title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("LEFT", badge, "RIGHT", 6, 0)
	title:SetText(T.Color("accent", "AuctionIQ") .. "  " .. T.Color("muted", "Crafting advisor"))
	local close = T.Button(bar, "x", 18, 18)
	close:SetPoint("RIGHT", -4, 0)
	close:SetScript("OnClick", function() settings().hide = true; panel:Hide(); CH.Print("advisor hidden. /aiq advisor brings it back.") end)
	local queue = T.Button(bar, "Queue", 56, 18)
	queue:SetPoint("RIGHT", close, "LEFT", -4, 0)
	queue:SetScript("OnClick", function() CH.QueueUI.Toggle() end)
	panel.queue = queue

	panel.recipe = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	panel.recipe:SetPoint("TOPLEFT", 12, -34)
	panel.recipe:SetWidth(WIDTH - 24)
	panel.recipe:SetJustifyH("LEFT")
	CH.Window.OneLine(panel.recipe)

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
	notes = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	notes:SetPoint("TOPLEFT", 12, y - (ROWS + 1) * 20 - 6)
	notes:SetWidth(WIDTH - 24)
	notes:SetJustifyH("LEFT")
	notes:SetSpacing(3)

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

	panel.add = T.Button(panel, "Queue selected craft", 135, 18)
	panel.add:SetPoint("BOTTOMLEFT", 68, 8)
	panel.add:SetScript("OnClick", function() AUI.QueueSelected() end)
	panel.quantity = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
	panel.quantity:SetSize(42, 18)
	panel.quantity:SetPoint("BOTTOMLEFT", 16, 8)
	panel.quantity:SetAutoFocus(false)
	panel.quantity:SetText("1")
	panel.quantity:SetScript("OnEnterPressed", function(self) self:ClearFocus(); AUI.QueueSelected() end)
	panel.quantity:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

	panel.status = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	panel.status:SetPoint("BOTTOMRIGHT", -10, 14)
	panel.status:SetJustifyH("RIGHT")
	T.Fonts(panel)
	CH.Window.Attach("advisor", panel)
	AUI.Place()
end

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
	shown, selected = result, nil
	panel.add:Hide()
	panel.quantity:Hide()
	if not result then
		panel.recipe:SetText(T.Color("muted", reason or "Select a recipe."))
		notes:SetText("")
		return {}
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
		local q = qualityIcon(r.quality, result.model and result.model.maxQ) .. (r.recommended and T.Color("accent", " best") or r.bestConcentration and T.Color("accent", " conc")
			or r.short and T.Color("bad", " low") or "")
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
		local b = result.best
		table.insert(lines, T.Color("accent", string.format("Make Q%d: ", b.quality)) .. money(b.profit) .. " avg profit a craft, reagents "
			.. CH.FormatMoney(b.cost) .. ". " .. T.Color("muted", "Use ") .. CH.Advisor.PicksText(result, b.picks, b.finishing))
	elseif result.order then
		table.insert(lines, T.Color("bad", "No reagents reach the quality this order asks for without Concentration."))
	end
	if result.bestConc then
		local c = result.bestConc
		table.insert(lines, T.Color("accent", string.format("With Concentration, Q%d: ", c.quality)) .. money(c.profit) .. " a craft for "
			.. string.format("%d points", c.concentration or 0) .. " (" .. CH.FormatMoney(c.perPoint) .. " a point). " .. T.Color("muted", "Use ")
			.. CH.Advisor.PicksText(result, c.picks, c.finishing))
		-- what spending the points adds over the plain craft you'd make anyway
		local plain = result.best and result.best.profit
		if plain and plain > 0 and c.profit then
			table.insert(lines, T.Color("muted", "  Over the plain craft: ") .. money(c.profit - plain) .. T.Color("muted", " more a craft"))
		end
	end
	for _, l in ipairs(AUI.FinishingLines(result)) do table.insert(lines, l) end
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
		add(CH.Theme.Color("muted", "Bought reagents at chmat: TSM's last lowest listing, at least 80% of market value. An estimate for planning."))
		if live then add(CH.Theme.Color("muted", "Buy now: the listings you've seen for that many, which is what you'd pay.")) end
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
		if r.profit and r.cost and r.cost > 0 then add("Return on reagents", string.format("%d%%", math.floor(r.profit / r.cost * 100 + 0.5))) end
		if r.concentration then
			add(string.format("Concentration %d points", r.concentration), money(r.perPoint) .. " per point")
			local plain = result.best and result.best.profit
			if plain and plain > 0 and r.profit then add("  More than the plain craft", money(r.profit - plain)) end
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

--- The hover column (cost, sells for, profit, max) under the cursor on a row's frame, or nil.
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

--- Click a row to queue one craft of it; shift-click to queue as many as you can make now.
function AUI.RowClick(i)
	local r = shown and shown.rows[i]
	if not r then return end
	selected = i
	for j, row in ipairs(rows) do
		local candidate = shown.rows[j]
		row.bg:SetShown(candidate ~= nil and (j == i or candidate.recommended or candidate.bestConcentration) or false)
	end
	local canQueue = not shown.sim and not r.short
	panel.add:SetShown(canQueue)
	panel.quantity:SetShown(canQueue and not shown.order)
	panel.quantity:SetText("1")
	local label = r.concentration and ("Queue Q%d (%d pt)"):format(r.quality, r.concentration)
		or ("Queue Q%d plain"):format(r.quality)
	panel.add.text:SetText(label)
end

function AUI.QueueSelected()
	local r = shown and shown.rows[selected]
	if not r or shown.sim or r.short then return nil end
	local qty = shown.order and 1 or tonumber(panel.quantity:GetText())
	if not qty or qty < 1 or qty > 9999 or qty ~= math.floor(qty) then
		CH.Print("Enter a whole craft quantity between 1 and 9999.")
		return nil
	end
	local order = shown.order
	local entry = CH.Queue.Add(shown, r, qty, order and { orderID = order.orderID, customer = order.customer })
	CH.Print(string.format("queued %d x %s (Q%d%s)", qty, shown.name or "?", r.quality, r.concentration and ", Concentration" or ""))
	if not CH.Window.InTabs("queue") then CH.QueueUI.Show() end
	return entry
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
