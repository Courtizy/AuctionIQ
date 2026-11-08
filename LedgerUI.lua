-- Ledger page of the main window, like TSM's: Inventory; Revenue (Sales, Other, Resale);
-- Expenses (Purchases, Other); Failed Auctions (Expired, Cancelled). Filter by name, character and
-- time frame, sort by any column, hover an item for its tooltip. Data comes from CH.Ledger, which
-- reads TSM's saved accounting and never writes to it.
local _, CH = ...

local LUI = {}
CH.LedgerUI = LUI

local X0, TW = 172, 724 -- table left edge and width inside the page
local ROWS, RH = 25, 18

local view = "inventory"
local filter, char, days = "", nil, 30
local sortCol, sortDesc = nil, true
local offset = 0
local page

local TIMES = { { "Last Day", 1 }, { "Last 7 Days", 7 }, { "Last 30 Days", 30 }, { "Last 90 Days", 90 }, { "Last Year", 365 }, { "All Time", nil } }

-- Columns: { label, x, width, default sort when picked }. Column 1 is left-aligned.
local ITEM_TIME = { { "Item", 0, 220 }, { "Character", 224, 90 }, { "Type", 318, 60 }, { "Qty", 382, 50 }, { "Per item", 436, 90 },
	{ "Total", 530, 96 }, { "Time frame", 630, 94 } }
local OTHER = { { "Type", 0, 180 }, { "Character", 184, 110 }, { "Other character", 298, 128 }, { "Amount", 430, 120 }, { "Time frame", 630, 94 } }
local VIEWS = {
	inventory = { label = "Inventory", sort = 8, cols = { { "Item", 0, 230 }, { "Total", 234, 60 }, { "Bags", 298, 56 }, { "Bank", 358, 56 },
		{ "Mail", 418, 50 }, { "Warband", 472, 66 }, { "AH", 542, 50 }, { "Value", 596, 128 } } },
	sales = { label = "Sales", parent = "Revenue", sort = 7, asc = true, cols = ITEM_TIME },
	income = { label = "Other", parent = "Revenue", sort = 5, asc = true, cols = OTHER },
	resale = { label = "Resale", parent = "Revenue", sort = 7, cols = { { "Item", 0, 200 }, { "Bought", 204, 56 }, { "Avg buy", 264, 90 },
		{ "Sold", 358, 56 }, { "Avg sell", 418, 90 }, { "Avg profit", 512, 100 }, { "Total profit", 616, 108 } } },
	purchases = { label = "Purchases", parent = "Expenses", sort = 7, asc = true, cols = ITEM_TIME },
	expense = { label = "Other", parent = "Expenses", sort = 5, asc = true, cols = OTHER },
	expired = { label = "Expired", parent = "Failed Auctions", sort = 4, asc = true,
		cols = { { "Item", 0, 300 }, { "Character", 304, 120 }, { "Qty", 428, 60 }, { "Time frame", 630, 94 } } },
	cancelled = { label = "Cancelled", parent = "Failed Auctions", sort = 4, asc = true,
		cols = { { "Item", 0, 300 }, { "Character", 304, 120 }, { "Qty", 428, 60 }, { "Time frame", 630, 94 } } },
}
local NAV = { { "inventory" }, { "Revenue", "sales" }, { "sales", sub = true }, { "income", sub = true }, { "resale", sub = true },
	{ "Expenses", "purchases" }, { "purchases", sub = true }, { "expense", sub = true },
	{ "Failed Auctions", "expired" }, { "expired", sub = true }, { "cancelled", sub = true } }
LUI.VIEWS = VIEWS

-- Formatting ----------------------------------------------------------------------------------
local function money(c, sign)
	if not c then return CH.Theme.Color("muted", "-") end
	local t = CH.FormatMoney(c)
	if sign and c > 0 then t = "+" .. t end
	return t
end

local function signed(c) return CH.Theme.Color(c >= 0 and "ok" or "bad", money(c)) end

--- An item as TSM shows it: icon, name in its rarity colour with its quality pip. Plain name too.
function LUI.ItemText(id)
	if not id then return "?", "?" end
	local name, link
	if C_Item and C_Item.GetItemInfo then name, link = C_Item.GetItemInfo(id) end
	name = name or (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or ("item " .. id)
	local shown = link and link:gsub("|H.-|h%[?(.-)%]?|h", "%1") or name
	return CH.Window.ItemIcon(id, 14) .. shown, name
end

--- "2 Days 3 Hr", "21 Hr 41 Min", "28 Min", like TSM's time frame.
function LUI.Ago(t, now)
	local d = math.max(0, (now or time()) - t)
	if d < 3600 then return string.format("%d Min", math.floor(d / 60)) end
	if d < 86400 then return string.format("%d Hr %d Min", math.floor(d / 3600), math.floor(d % 3600 / 60)) end
	local n = math.floor(d / 86400)
	return string.format("%d Day%s %d Hr", n, n == 1 and "" or "s", math.floor(d % 86400 / 3600))
end

-- Data ----------------------------------------------------------------------------------------
--- Rows for a view: { cells = { text... }, sort = { value... }, id = itemID }, then the footer
--- text. opts: filter (name keyword), char (character name), days (nil = all time), now.
function LUI.Rows(v, opts)
	opts = opts or {}
	local L = CH.Ledger
	local now = opts.now or time()
	local since = opts.days and (now - opts.days * 86400) or -math.huge
	local key = opts.filter and opts.filter ~= "" and string.lower(opts.filter) or nil
	local mine = {}
	for _, c in ipairs(L.Characters()) do mine[c.name] = true end
	local out = {}
	local function keepName(name) return not key or string.lower(name or ""):find(key, 1, true) end
	local function keepRec(r) return r.time >= since and (not opts.char or r.player == opts.char) end

	if v == "inventory" then
		local total = 0
		for _, e in ipairs(L.Inventory(opts.filter, opts.char)) do
			local text, name = LUI.ItemText(e.id)
			total = total + e.value
			table.insert(out, { id = e.id, cells = { text, e.total, e.bags, e.bank, e.mail, e.warband, e.ah, money(e.value) },
				sort = { name, e.total, e.bags, e.bank, e.mail, e.warband, e.ah, e.value } })
		end
		return out, "Total value: " .. money(total)
	end

	if v == "sales" or v == "purchases" then
		local n, total = 0, 0
		for _, r in ipairs(L.Records(v == "sales" and "Sales" or "Buys")) do
			if keepRec(r) then
				local text, name = LUI.ItemText(r.id)
				if keepName(name) then
					n, total = n + r.quantity, total + r.amount
					table.insert(out, { id = r.id, cells = { text, r.player or "?", r.source or "", r.quantity, money(r.price), money(r.amount), LUI.Ago(r.time, now) },
						sort = { name, r.player or "", r.source or "", r.quantity, r.price, r.amount, now - r.time } })
				end
			end
		end
		return out, string.format("%d items %s: %s", n, v == "sales" and "sold" or "bought", money(total))
	end

	if v == "income" or v == "expense" then
		local total, transfers = 0, 0
		for _, r in ipairs(L.Records(v == "income" and "Income" or "Expense")) do
			if keepRec(r) and keepName(r.source) then
				local own = mine[r.other]
				if own then transfers = transfers + r.amount else total = total + r.amount end
				local other = own and CH.Theme.Color("muted", r.other .. " (yours)") or (r.other or "")
				table.insert(out, { cells = { r.source or "?", r.player or "?", other, money(r.amount), LUI.Ago(r.time, now) },
					sort = { r.source or "", r.player or "", r.other or "", r.amount, now - r.time } })
			end
		end
		local foot = "Total: " .. money(total)
		if transfers > 0 then foot = foot .. CH.Theme.Color("muted", "   (plus " .. money(transfers) .. " moved between your characters)") end
		return out, foot
	end

	if v == "resale" then
		local items = {}
		local function add(r, buy)
			if not keepRec(r) or not r.id then return end
			local e = items[r.id] or { bq = 0, bg = 0, sq = 0, sg = 0 }
			items[r.id] = e
			if buy then e.bq, e.bg = e.bq + r.quantity, e.bg + r.amount else e.sq, e.sg = e.sq + r.quantity, e.sg + r.amount end
		end
		for _, r in ipairs(L.Records("Buys")) do add(r, true) end
		for _, r in ipairs(L.Records("Sales")) do add(r, false) end
		local n, total = 0, 0
		for id, e in pairs(items) do
			if e.bq > 0 and e.sq > 0 then
				local text, name = LUI.ItemText(id)
				if keepName(name) then
					local ab, as = e.bg / e.bq, e.sg / e.sq
					local each = as - ab
					local units = math.min(e.bq, e.sq)
					n, total = n + units, total + each * units
					table.insert(out, { id = id, cells = { text, e.bq, money(ab), e.sq, money(as), signed(each), signed(each * units) },
						sort = { name, e.bq, ab, e.sq, as, each, each * units } })
				end
			end
		end
		return out, string.format("%d items resold   Total profit: %s", n, signed(total))
	end

	-- expired / cancelled
	local n = 0
	for _, r in ipairs(L.Records(v == "expired" and "Expired" or "Cancelled")) do
		if keepRec(r) then
			local text, name = LUI.ItemText(r.id)
			if keepName(name) then
				n = n + r.quantity
				table.insert(out, { id = r.id, cells = { text, r.player or "?", r.quantity, LUI.Ago(r.time, now) },
					sort = { name, r.player or "", r.quantity, now - r.time } })
			end
		end
	end
	return out, string.format("%d items %s", n, v)
end

local function sortRows(rows, col, desc)
	table.sort(rows, function(a, b)
		local x, y = a.sort[col], b.sort[col]
		if x == y then return (a.sort[1] or "") < (b.sort[1] or "") end
		if type(x) ~= type(y) then x, y = tostring(x), tostring(y) end
		if desc then return x > y end
		return x < y
	end)
	return rows
end

-- Building ------------------------------------------------------------------------------------
local function setView(v)
	view, offset = v, 0
	sortCol, sortDesc = VIEWS[v].sort, not VIEWS[v].asc
	CH.UI.Refresh()
end

local function pick(owner, title, list, onPick)
	if MenuUtil and MenuUtil.CreateContextMenu then
		MenuUtil.CreateContextMenu(owner, function(_, root)
			root:CreateTitle(title)
			for _, e in ipairs(list) do
				root:CreateRadio(e[1], function() return e.selected end, function() onPick(e[2]) end)
			end
		end)
	else -- no menus (tests): step to the next choice
		for i, e in ipairs(list) do
			if e.selected then return onPick((list[i % #list + 1])[2]) end
		end
		onPick(list[1][2])
	end
end

function LUI.Build(p, fs, panel)
	local T = CH.Theme
	page = p
	sortCol, sortDesc = VIEWS[view].sort, not VIEWS[view].asc
	local nav = panel(p, 0, 0, 160, p:GetHeight() or 552)
	p.nav = {}
	local y = -8
	for _, n in ipairs(NAV) do
		local target = n[2] or n[1]
		local label = VIEWS[n[1]] and VIEWS[n[1]].label or n[1]
		local b = T.Button(nav, label, n.sub and 128 or 144, n.sub and 18 or 20)
		b:SetPoint("TOPLEFT", n.sub and 24 or 8, y)
		b:SetScript("OnClick", function() setView(target) end)
		b.view, b.parent = n[1], not n.sub and n[2] and n[1] or nil
		table.insert(p.nav, b)
		y = y - (n.sub and 21 or 25)
	end

	local search = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
	search:SetSize(250, 20)
	search:SetPoint("TOPLEFT", X0 + 6, -4)
	search:SetAutoFocus(false)
	search:SetScript("OnTextChanged", function(self) filter = self:GetText() or ""; offset = 0; CH.UI.Refresh() end)
	search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	p.hint = fs(p, X0 + 10, -8, 200, "LEFT", "GameFontDisableSmall")
	search:SetScript("OnEditFocusGained", function() p.hint:SetText("") end)
	search:SetScript("OnEditFocusLost", function(self) if (self:GetText() or "") == "" then p.hint:SetText("Filter by name") end end)
	p.hint:SetText("Filter by name")

	p.charButton = T.Button(p, "All characters", 150, 20)
	p.charButton:SetPoint("TOPLEFT", X0 + 268, -4)
	p.charButton:SetScript("OnClick", function(self)
		local list = { { "All characters", false, selected = char == nil } }
		for _, c in ipairs(CH.Ledger.Characters()) do table.insert(list, { c.name, c.name, selected = char == c.name }) end
		pick(self, "Character", list, function(v) char = v or nil; offset = 0; CH.UI.Refresh() end)
	end)
	p.timeButton = T.Button(p, "Last 30 Days", 110, 20)
	p.timeButton:SetPoint("TOPLEFT", X0 + 424, -4)
	p.timeButton:SetScript("OnClick", function(self)
		local list = {}
		for _, t in ipairs(TIMES) do table.insert(list, { t[1], t[2] or false, selected = days == t[2] }) end
		pick(self, "Time frame", list, function(v) days = v or nil; offset = 0; CH.UI.Refresh() end)
	end)

	-- sortable headers
	p.heads = {}
	for j = 1, 8 do
		local h = CreateFrame("Button", nil, p)
		h:SetHeight(16)
		h.text = fs(h, 0, -2, 10, "LEFT", "GameFontNormalSmall")
		h:SetScript("OnClick", function()
			if sortCol == j then sortDesc = not sortDesc else sortCol, sortDesc = j, j ~= 1 end
			CH.UI.Refresh()
		end)
		p.heads[j] = h
	end
	-- rows, each with a hover area for the item's tooltip
	p.rows = {}
	for i = 1, ROWS do
		local r = { cells = {} }
		local hit = CreateFrame("Button", nil, p)
		hit:SetPoint("TOPLEFT", X0, -50 - (i - 1) * RH)
		hit:SetSize(TW, RH)
		hit:SetScript("OnEnter", function(self)
			if self.id and GameTooltip.SetItemByID then
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetItemByID(self.id)
				GameTooltip:Show()
			end
		end)
		hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
		local bg = hit:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.03 or 0)
		r.hit = hit
		for j = 1, 8 do r.cells[j] = fs(p, 0, -52 - (i - 1) * RH, 10) end
		p.rows[i] = r
	end
	p.footer = fs(p, X0, -52 - ROWS * RH - 8, TW, "CENTER", "GameFontNormal")
	p:EnableMouseWheel(true)
	p:SetScript("OnMouseWheel", function(_, delta) offset = math.max(0, offset - delta * 5); CH.UI.Refresh() end)
end

--- Redraw. Returns the rows shown (all of them, sorted) and the footer, for tests.
function LUI.Refresh()
	local p = page
	if not p then return {} end
	local T = CH.Theme
	local v = VIEWS[view]
	for _, b in ipairs(p.nav) do
		local on = b.view == view or (b.parent and v.parent == b.parent)
		local f = b.text or (b.GetFontString and b:GetFontString())
		local c = on and T.accent or T.fg
		if f and f.SetTextColor then f:SetTextColor(c[1], c[2], c[3]) end
	end
	local charLabel = char or "All characters"
	if p.charButton.text then p.charButton.text:SetText(charLabel) end
	for _, t in ipairs(TIMES) do if t[2] == days and p.timeButton.text then p.timeButton.text:SetText(t[1]) end end
	p.timeButton:SetShown(view ~= "inventory")

	for j, h in ipairs(p.heads) do
		local c = v.cols[j]
		if c then
			h:ClearAllPoints()
			h:SetPoint("TOPLEFT", X0 + c[2], -32)
			h:SetWidth(c[3])
			h.text:SetWidth(c[3])
			h.text:SetJustifyH(j == 1 and "LEFT" or "RIGHT")
			local arrow = sortCol == j and (sortDesc and " v" or " ^") or ""
			h.text:SetText((sortCol == j and T.Color("accent", c[1] .. arrow)) or c[1])
			h:Show()
		else
			h:Hide()
		end
	end

	local rows, footer = {}, ""
	if CH.Ledger.Available() then
		rows, footer = LUI.Rows(view, { filter = filter, char = char, days = view ~= "inventory" and days or nil })
		sortRows(rows, sortCol or 1, sortDesc)
	end
	offset = math.max(0, math.min(offset, #rows - ROWS))
	for i, r in ipairs(p.rows) do
		local d = rows[i + offset]
		r.hit.id = d and d.id
		for j, cell in ipairs(r.cells) do
			local c = v.cols[j]
			if c and d then
				cell:ClearAllPoints()
				cell:SetPoint("TOPLEFT", X0 + c[2], -52 - (i - 1) * RH)
				cell:SetWidth(c[3])
				cell:SetJustifyH(j == 1 and "LEFT" or "RIGHT")
				cell:SetText(tostring(d.cells[j] or ""))
			else
				cell:SetText("")
			end
		end
	end
	local more = #rows > ROWS and T.Color("muted", string.format("   rows %d-%d of %d, scroll for more", offset + 1, math.min(#rows, offset + ROWS), #rows)) or ""
	p.footer:SetText(CH.Ledger.Available() and (footer .. more) or T.Color("muted", "Needs TradeSkillMaster."))
	return rows, footer
end

--- Switch the view, filters and sort from code (tests, slash commands).
function LUI.Set(opts)
	if opts.view then view = opts.view; sortCol, sortDesc = VIEWS[view].sort, not VIEWS[view].asc end
	if opts.filter ~= nil then filter = opts.filter end
	if opts.char ~= nil then char = opts.char or nil end
	if opts.days ~= nil then days = opts.days or nil end
	if opts.sort then sortCol, sortDesc = opts.sort, opts.desc end
	offset = 0
end

-- Item names arrive from the server a moment after first asked for: redraw once they do.
local pending
CH.On("GET_ITEM_INFO_RECEIVED", function()
	if pending or not (page and page:IsShown()) then return end
	pending = true
	C_Timer.After(0.3, function() pending = nil; if page and page:IsShown() then CH.UI.Refresh() end end)
end)
