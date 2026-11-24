-- The Craft tab, as the design draws it: a to-do strip (cooldowns across your characters, items under
-- TSM restock), the recipe list on the left ranked by Full profit per craft with Make N, and the cost
-- detail on the right with Market / Paid / Full, the paid-cost coverage bar, Make N with its reason,
-- and a Craft button that crafts one per click. It opens docked beside the profession window.
local _, AuctionIQ = ...
local T = AuctionIQ.Theme
local Tbl = AuctionIQ.Table
local R = AuctionIQ.Recipes
local Craft = AuctionIQ.Craft

local CraftUI = { LEFT_W = 300, ROWS = 15 }
AuctionIQ.CraftUI = CraftUI

--- Gold for the design's columns: "185g", "+42g", "−4g", "45s", "—" when unknown.
function CraftUI.Gold(copper, signed)
	if copper == nil then return "—" end
	local neg = copper < 0
	local a = math.abs(copper)
	local s
	if a >= 10000 then
		s = tostring(math.floor(a / 10000 + 0.5)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "") .. "g"
	elseif a >= 100 then s = math.floor(a / 100 + 0.5) .. "s"
	else s = a .. "c" end
	if neg then return "-" .. s end
	return (signed and "+" or "") .. s
end

local function signed(copper)
	if copper == nil then return T.Color("muted", "—") end
	return T.Color(copper < 0 and "bad" or "ok", CraftUI.Gold(copper, true))
end

local function qualityName(item, name)
	local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	local q = get and select(3, get(item))
	local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
	if c and c.hex then return c.hex .. (name or "?") .. "|r" end
	return name or "?"
end

local function icon(item)
	local get = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
	return get and get(item) or "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function text(parent, size, kind, justify)
	local fs = parent:CreateFontString(nil, "OVERLAY", kind == "small" and "GameFontHighlightSmall" or "GameFontHighlight")
	if justify then fs:SetJustifyH(justify) end
	if size then T.TitleFont(fs, size, kind == "bold" and "bold" or nil) end
	return fs
end

local function label(b, s)
	if b.text then b.text:SetText(s) elseif b.SetText then b:SetText(s) end
end

-- State: which profession and recipe are showing, and crafts done since the recipe was picked.
local S = { show = "all", done = 0 }
CraftUI.state = S

local SHOWS = { "all", "profitable", "can" }
local SHOW_LABEL = { all = "All", profitable = "Profitable", can = "Can make" }

local function filtered(rows)
	local out = {}
	for _, row in ipairs(rows) do
		if S.show == "all" or (S.show == "profitable" and (row.profit or 0) > 0) or (S.show == "can" and row.canMake > 0) then
			row.dim = row.n == 0
			out[#out + 1] = row
		end
	end
	return out
end

-- The strip -------------------------------------------------------------------------------------

function CraftUI.StripText(cooldowns, below, at)
	at = at or (time and time() or 0)
	local parts = {}
	for _, c in ipairs(cooldowns) do
		if #parts >= 3 then break end
		local left = c.readyAt - at
		if left <= 0 then
			parts[#parts + 1] = T.Dot("ok") .. " " .. c.name .. T.Color("muted", " ready · " .. c.char)
		elseif left < 24 * 3600 then
			local h = left >= 3600 and (math.floor(left / 3600 + 0.5) .. "h") or (math.ceil(left / 60) .. "m")
			parts[#parts + 1] = T.Dot("gold") .. " " .. c.name .. T.Color("muted", " in " .. h .. " · " .. c.char)
		end
	end
	local left = #parts > 0 and table.concat(parts, "    ") or T.Color("muted", "No cooldowns coming up")
	local right = below > 0 and T.Color("accent", below .. (below == 1 and " item" or " items") .. " below restock") or ""
	return left, right
end

-- Building ---------------------------------------------------------------------------------------

local function build(page)
	CraftUI.page = page
	local W = 760

	-- to-do strip
	local strip = CreateFrame("Frame", nil, page, BackdropTemplateMixin and "BackdropTemplate" or nil)
	strip:SetPoint("TOPLEFT", 0, 0)
	strip:SetSize(W, 24)
	T.Panel(strip, "panel", 1)
	page.stripLeft = text(strip, nil, "small", "LEFT")
	page.stripLeft:SetPoint("LEFT", 8, 0)
	page.stripRight = text(strip, nil, "small", "RIGHT")
	page.stripRight:SetPoint("RIGHT", -8, 0)

	-- recipes
	local left = CreateFrame("Frame", nil, page, BackdropTemplateMixin and "BackdropTemplate" or nil)
	left:SetPoint("TOPLEFT", 0, -30)
	left:SetSize(CraftUI.LEFT_W, 408)
	T.Panel(left, "panel", 1)
	local title = text(left, 12, "bold", "LEFT")
	title:SetPoint("TOPLEFT", 10, -10)
	title:SetText(T.Color("accent", "RECIPES"))
	local prof = T.Button(left, "Profession", 140, 20)
	prof:SetPoint("TOPRIGHT", -8, -6)
	prof:SetScript("OnClick", function() CraftUI.NextProfession() end)
	page.prof = prof

	local t = Tbl.New(left, "craft.recipes", {
		{ key = "name", label = "Recipe", width = 172, default = "asc", text = function(r) return qualityName(r.recipe.item, r.name) end },
		{ key = "profit", label = "Profit", width = 62, align = "RIGHT", text = function(r) return r.profit and signed(r.profit) or T.Color("muted", "—") end },
		{ key = "n", label = "Make", width = 50, align = "RIGHT" },
	}, { "profit", "desc" })
	t:SetPoint("TOPLEFT", 8, -34)
	t:SetSize(284, 340)
	t.onClick = function(row) CraftUI.Select(row.key) end
	page.list = t

	local showLabel = text(left, nil, "small", "LEFT")
	showLabel:SetPoint("BOTTOMLEFT", 10, 12)
	showLabel:SetText(T.Color("muted", "Show"))
	local show = T.Button(left, "All", 90, 20)
	show:SetPoint("BOTTOMLEFT", 46, 8)
	show:SetScript("OnClick", function()
		for i, k in ipairs(SHOWS) do if k == S.show then S.show = SHOWS[i % #SHOWS + 1]; break end end
		CraftUI.Refresh()
	end)
	page.show = show
	page.empty = text(left, nil, nil, "CENTER")
	page.empty:SetPoint("CENTER", 0, 0)
	page.empty:SetWidth(260)

	-- detail
	local d = CreateFrame("Frame", nil, page, BackdropTemplateMixin and "BackdropTemplate" or nil)
	d:SetPoint("TOPLEFT", CraftUI.LEFT_W + 10, -30)
	d:SetSize(W - CraftUI.LEFT_W - 10, 408)
	T.Panel(d, "panel", 1)
	page.detail = d
	local DW = W - CraftUI.LEFT_W - 10
	d.icon = d:CreateTexture(nil, "ARTWORK")
	d.icon:SetSize(22, 22)
	d.icon:SetPoint("TOPLEFT", 10, -8)
	d.name = text(d, 14, "bold", "LEFT")
	d.name:SetPoint("LEFT", d.icon, "RIGHT", 8, 0)
	d.meta = text(d, nil, "small", "RIGHT")
	d.meta:SetPoint("TOPRIGHT", -10, -14)

	local COLS = { DW - 190, DW - 110, DW - 14 } -- right edges of Market, Paid, Full
	local function row(y, name)
		local r = CreateFrame("Button", nil, d)
		r:SetPoint("TOPLEFT", 6, y)
		r:SetSize(DW - 12, 20)
		r.label = text(r, nil, nil, "LEFT")
		r.label:SetPoint("LEFT", 6, 0)
		r.label:SetText(name)
		r.v = {}
		for i, x in ipairs(COLS) do
			local fs = text(r, nil, nil, "RIGHT")
			fs:SetPoint("RIGHT", r, "LEFT", x - 6, 0)
			r.v[i] = fs
		end
		return r
	end
	d.head = row(-38, T.Color("muted", "Cost per craft"))
	d.head.v[1]:SetText(T.Color("muted", "Market")); d.head.v[2]:SetText(T.Color("muted", "Paid")); d.head.v[3]:SetText(T.Color("accent", "Full"))
	d.rule1 = d:CreateTexture(nil, "ARTWORK")
	d.rule1:SetPoint("TOPLEFT", 10, -59); d.rule1:SetSize(DW - 20, 1); d.rule1:SetColorTexture(T.line[1], T.line[2], T.line[3], 1)
	d.reagents = row(-62, "Reagents")
	d.reagents:SetScript("OnEnter", function(self) CraftUI.ReagentTooltip(self) end)
	d.reagents:SetScript("OnLeave", function() GameTooltip:Hide() end)
	d.fees = row(-84, "AH cut + relist")
	d.fees:SetScript("OnEnter", function(self) CraftUI.FeeTooltip(self) end)
	d.fees:SetScript("OnLeave", function() GameTooltip:Hide() end)
	d.payback = row(-106, "Recipe payback")
	d.rule2 = d:CreateTexture(nil, "ARTWORK")
	d.rule2:SetPoint("TOPLEFT", 10, -132); d.rule2:SetSize(DW - 20, 1); d.rule2:SetColorTexture(T.line[1], T.line[2], T.line[3], 1)
	d.sells = row(-138, "Sells for")
	local house = T.Button(d, "Faction AH", 120, 18)
	house:SetPoint("TOPLEFT", 110, -139) -- on the Sells for line, where Market and Paid are empty
	house:SetScript("OnClick", function() CraftUI.ToggleHouse() end)
	house:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Where you sell")
		GameTooltip:AddLine("Your faction's auction house takes 5%, the neutral one (Blackwater) 15%. Click to switch; every column follows.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	house:SetScript("OnLeave", function() GameTooltip:Hide() end)
	d.house = house
	d.profit = row(-162, "Profit")
	T.TitleFont(d.profit.label, nil, "bold")

	d.cover = text(d, nil, "small", "LEFT")
	d.cover:SetPoint("TOPLEFT", 12, -194)
	d.track = d:CreateTexture(nil, "ARTWORK")
	d.track:SetPoint("TOPLEFT", 12, -212); d.track:SetSize(DW - 24, 4); d.track:SetColorTexture(0, 0, 0, 0.6)
	d.bar = d:CreateTexture(nil, "OVERLAY")
	d.bar:SetPoint("TOPLEFT", d.track, "TOPLEFT")
	d.bar:SetHeight(4)
	T.AccentTexture(d.bar)
	d.barW = DW - 24

	d.rule3 = d:CreateTexture(nil, "ARTWORK")
	d.rule3:SetPoint("TOPLEFT", 10, -232); d.rule3:SetSize(DW - 20, 1); d.rule3:SetColorTexture(T.line[1], T.line[2], T.line[3], 1)
	d.reason = text(d, nil, "small", "LEFT")
	d.reason:SetPoint("TOPLEFT", 12, -252)
	d.reason:SetWidth(DW - 150)
	d.make = text(d, 22, "bold", "RIGHT")
	d.make:SetPoint("TOPRIGHT", -12, -242)
	d.items = text(d, nil, "small", "RIGHT")
	d.items:SetPoint("TOPRIGHT", d.make, "BOTTOMRIGHT", 0, -2)

	d.tsm = text(d, nil, "small", "LEFT")
	d.tsm:SetPoint("TOPLEFT", 12, -306)
	d.tsm:SetText(T.Color("muted", "Or queue it with TSM: ") .. T.Color("accent", "Restock"))
	local btn = T.Button(d, "Craft", 150, 30)
	btn:SetPoint("TOPRIGHT", -12, -296)
	T.Primary(btn)
	btn:SetScript("OnClick", function() CraftUI.CraftOne() end)
	d.button = btn

	d.none = text(d, nil, nil, "CENTER")
	d.none:SetPoint("CENTER")
	d.none:SetWidth(DW - 60)
end

-- Showing ----------------------------------------------------------------------------------------

--- The recipe line: "≈ 340g (120 Favor) · pays back in ~5 crafts", "120 Favor", or "—".
function CraftUI.PaybackText(c)
	local cost
	if c.recipeCost and c.recipeFavor then cost = "~" .. CraftUI.Gold(c.recipeCost) .. " (" .. c.recipeFavor .. " Favor)"
	elseif c.recipeCost then cost = CraftUI.Gold(c.recipeCost)
	elseif c.recipeFavor then cost = c.recipeFavor .. " Favor" end
	if not cost then return T.Color("muted", "cost not known · kept out of profit") end
	if c.paybackCrafts then return cost .. T.Color("muted", " · pays back in ~" .. c.paybackCrafts .. (c.paybackCrafts == 1 and " craft" or " crafts")) end
	return cost
end

--- Faction AH (5%) ⇄ neutral AH (15%), for every column.
function CraftUI.ToggleHouse()
	local c = AuctionIQ.db.settings.costs
	c.house = Craft.House() == "faction" and "neutral" or "faction"
	CraftUI.Refresh()
end

function CraftUI.NextProfession()
	local list = R.Professions()
	if #list == 0 then return end
	local i = 1
	for n, name in ipairs(list) do if name == S.profession then i = n % #list + 1 end end
	S.profession, S.selected, S.done = list[i], nil, 0
	CraftUI.Refresh()
end

function CraftUI.Select(key)
	if S.selected ~= key then S.done = 0 end
	S.selected = key
	for _, row in ipairs(S.rows or {}) do
		if row.key == key then R.Select(row.recipe) end
	end
	CraftUI.Refresh()
end

local function selectedRow()
	for _, row in ipairs(S.rows or {}) do if row.key == S.selected then return row end end
end

function CraftUI.ReagentTooltip(owner)
	local row = selectedRow()
	if not row then return end
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	GameTooltip:AddLine("Reagents per craft")
	local HOW = { bought = "bought", crafted = "crafted", farmed = "farmed" }
	for _, l in ipairs(row.cost.lines) do
		local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
		local name = (get and get(l.item)) or l.name or ("item " .. l.item)
		GameTooltip:AddDoubleLine(l.qty .. " \195\151 " .. name,
			CraftUI.Gold(l.market and l.market * l.qty) .. " market · " .. CraftUI.Gold(l.paid and l.paid * l.qty) .. " " .. (HOW[l.how] or "paid"),
			0.95, 0.95, 0.95, 0.64, 0.64, 0.67)
	end
	GameTooltip:Show()
end

function CraftUI.FeeTooltip(owner)
	local row = selectedRow()
	if not row then return end
	local c = row.cost
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	GameTooltip:AddLine("Taken off every column")
	GameTooltip:AddDoubleLine("AH cut (" .. math.floor(Craft.Cut() * 100 + 0.5) .. "%)", CraftUI.Gold(c.cut), 0.95, 0.95, 0.95, 0.95, 0.95, 0.95)
	GameTooltip:AddDoubleLine("Relist (deposits lost to expiries)", c.relistKnown and (CraftUI.Gold(c.relist) .. " est.") or "no sale rate", 0.95, 0.95, 0.95, 0.95, 0.95, 0.95)
	GameTooltip:Show()
end

local function showDetail(d, row, p)
	local show = row ~= nil
	for _, k in ipairs({ "icon", "name", "meta", "reagents", "fees", "payback", "sells", "profit", "cover", "bar", "reason", "make", "items", "tsm", "button", "house", "head", "rule1", "rule2", "rule3", "track" }) do
		d[k]:SetShown(show)
	end
	d.none:SetShown(not show)
	if not show then
		d.none:SetText(T.Color("muted", "Pick a recipe on the left."))
		return
	end
	local r, c, m = row.recipe, row.cost, row.make
	d.icon:SetTexture(icon(r.item))
	d.name:SetText(qualityName(r.item, r.name))
	local makes = c.makes == math.floor(c.makes) and tostring(c.makes) or ("%.1f"):format(c.makes)
	d.meta:SetText(T.Color("muted", "makes " .. makes .. (p.skill and (" · skill " .. p.skill .. "/" .. (p.max or "?")) or "")))
	d.reagents.v[1]:SetText(CraftUI.Gold(c.reagents.market)); d.reagents.v[2]:SetText(CraftUI.Gold(c.reagents.paid)); d.reagents.v[3]:SetText(CraftUI.Gold(c.reagents.full))
	for i = 1, 3 do d.fees.v[i]:SetText(CraftUI.Gold(c.fees)) end
	label(d.house, Craft.HOUSES[Craft.House()].label .. " " .. math.floor(Craft.Cut() * 100 + 0.5) .. "% " .. T.Arrow("down"))
	for i = 1, 3 do d.payback.v[i]:SetText("") end
	d.payback.label:SetText(T.Color("muted", "Recipe ") .. CraftUI.PaybackText(c))
	d.sells.v[1]:SetText(""); d.sells.v[2]:SetText("")
	d.sells.v[3]:SetText(c.sells and ("~" .. CraftUI.Gold(c.sells) .. (c.makes ~= 1 and (" \195\151 " .. makes) or "")) or T.Color("muted", "no price"))
	if c.priced then
		d.profit.v[1]:SetText(signed(c.profit.market)); d.profit.v[2]:SetText(signed(c.profit.paid)); d.profit.v[3]:SetText(signed(c.profit.full))
	else
		for i = 1, 3 do d.profit.v[i]:SetText(T.Color("muted", "—")) end
	end
	local pct = math.floor(c.coverage * 100 + 0.5)
	d.cover:SetText(T.Color("muted", "Paid cost: ") .. pct .. "%" .. T.Color("muted", " from real purchases or crafts · " .. (100 - pct) .. "% farmed at " .. ((AuctionIQ.db.settings.costs.farmedAt == "zero") and "zero" or "market")))
	d.bar:SetWidth(math.max(1, d.barW * c.coverage))
	d.reason:SetText(T.Color("muted", Craft.Reason(m, c.makes)))
	d.make:SetText(T.Color(m.n > 0 and "accent" or "muted", "Make " .. m.n))
	d.items:SetText(c.makes ~= 1 and m.n > 0 and T.Color("muted", (m.n == 1 and "craft" or "crafts") .. " · " .. (m.items or 0) .. " items") or "")
	-- the button: crafting needs the profession open; one craft per click
	local open = R.open == p.name
	local b = d.button
	local enable, txt
	if not open then
		enable, txt = false, "Open " .. (p.name or "the profession")
	elseif (r.canMake or 0) <= 0 then
		enable, txt = false, "Missing reagents"
	elseif m.n > 0 and S.done < m.n then
		enable, txt = true, ("Craft %d of %d"):format(S.done + 1, m.n)
	else
		enable, txt = true, "Craft 1"
	end
	label(b, txt)
	if b.SetEnabled then b:SetEnabled(enable) end
	b:SetAlpha(enable and 1 or 0.5)
end

--- Redraws the tab from the saved professions.
function CraftUI.Refresh()
	local page = CraftUI.page
	if not page then return end
	local list = R.Professions()
	if not S.profession or not R.Get(S.profession) then S.profession = R.open or list[1] end
	local p = R.Get(S.profession)
	S.rows = p and Craft.Rows(p) or {}
	label(page.prof, (S.profession or "No profession") .. " " .. T.Arrow("down"))
	label(page.show, SHOW_LABEL[S.show] .. " " .. T.Arrow("down"))
	local rows = filtered(S.rows)
	page.list.selectedKey = S.selected
	Tbl.SetRows(page.list, rows, CraftUI.ROWS)
	if not S.selected and page.list.rows[1] then
		S.selected = page.list.rows[1].key
		page.list.selectedKey = S.selected
		Tbl.Draw(page.list)
	end
	page.empty:SetShown(#rows == 0)
	page.empty:SetText(T.Color("muted", #list == 0 and "Open a profession once and its recipes show here, even after you close it." or "Nothing matches this filter."))
	showDetail(page.detail, selectedRow(), p or {})
	local left, right = CraftUI.StripText(R.Cooldowns(), Craft.BelowRestock(S.rows))
	page.stripLeft:SetText(left)
	page.stripRight:SetText(right)
end

function CraftUI.CraftOne()
	local row = selectedRow()
	if not row then return end
	if R.Craft(row.recipe, 1) then S.done = S.done + 1 end
	CraftUI.Refresh()
end

AuctionIQ.Shell.Pages.craft = { build = build, refresh = function() CraftUI.Refresh() end }

-- Docking: the profession opens, the Craft tab opens beside it (Settings can turn that off), and
-- closes with it if it opened that way.
local PROFESSION_FRAMES = { "TradeSkillFrame", "ProfessionsFrame" }
local docked = false
R.onRefresh = function(p)
	local Shell = AuctionIQ.Shell
	local craft = AuctionIQ.db.settings.craft or {}
	if p.name ~= S.profession and R.open == p.name and not Shell.IsShown() then S.profession, S.selected, S.done = p.name, nil, 0 end
	if not Shell.IsShown() and craft.dock ~= false then
		Shell.Show("craft")
		docked = true
		for _, name in ipairs(PROFESSION_FRAMES) do
			local f = _G[name]
			if f and f.IsShown and f:IsShown() then
				Shell.frame:ClearAllPoints()
				Shell.frame:SetPoint("TOPLEFT", f, "TOPRIGHT", 4, 0)
				break
			end
		end
	elseif Shell.IsShown() and Shell.current == "craft" then
		CraftUI.Refresh()
	end
end
R.onClose = function()
	local Shell = AuctionIQ.Shell
	if docked and Shell.frame then
		Shell.frame:Hide()
		Shell.frame:ClearAllPoints()
		Shell.frame:SetPoint("CENTER")
	end
	docked = false
	if Shell.IsShown() and Shell.current == "craft" then CraftUI.Refresh() end
end
