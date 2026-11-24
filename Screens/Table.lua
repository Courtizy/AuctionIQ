-- A table for the new screens: a header row whose columns sort when clicked (again to flip, with a
-- ▲/▼ on the active one), rows drawn from a small pool and scrolled with the mouse wheel. Each table
-- remembers its sort in saved data. Rows marked `last` (expired or unfillable work orders) stay at the
-- bottom whatever the sort. Tables can be linked so one header click sorts them all (Sales' Winners
-- and Losers).
local _, AuctionIQ = ...
local T = AuctionIQ.Theme

local Tbl = { ROW_H = 20, HEAD_H = 20 }
AuctionIQ.Table = Tbl

local function UP() return " " .. T.Arrow("up", 10) end
local function DOWN() return " " .. T.Arrow("down", 10) end

--- Order rows by a column, in place. dir "asc" or "desc". Rows with `last` go after the rest, in
--- the same order among themselves. Missing values sort after present ones both ways; ties keep
--- the name order so a re-sort doesn't shuffle equal rows.
function Tbl.Sort(rows, key, dir)
	local desc = dir == "desc"
	local function v(r) local x = r[key]; if type(x) == "string" then return x:lower() end; return x end
	local function name(r) return tostring(r.name or r.item or ""):lower() end
	table.sort(rows, function(a, b)
		if (a.last and true or false) ~= (b.last and true or false) then return not a.last end
		local x, y = v(a), v(b)
		if x == nil or y == nil or type(x) ~= type(y) then
			if x ~= nil and y == nil then return true end
			if x == nil and y ~= nil then return false end
			return name(a) < name(b)
		end
		if x == y then return name(a) < name(b) end
		if desc then return x > y end
		return x < y
	end)
	return rows
end

local function sortStore()
	local db = AuctionIQ.db
	if not db then return {} end
	db.settings.sort = db.settings.sort or {}
	return db.settings.sort
end

--- A new table in parent. id names it for the saved sort. cols: { { key, label, width, align
--- ("LEFT" or "RIGHT"), text = function(row) -> string, default = "asc"|"desc" } }. sort: the default
--- { key, dir }.
function Tbl.New(parent, id, cols, sort)
	local t = CreateFrame("Frame", nil, parent)
	t.id, t.cols, t.rows, t.offset, t.lines = id, cols, {}, 0, {}
	local saved = sortStore()[id]
	t.sort = saved and { saved[1], saved[2] } or { sort and sort[1] or cols[1].key, sort and sort[2] or "desc" }
	t.heads = {}
	local x = 0
	for i, c in ipairs(cols) do
		local h = CreateFrame("Button", nil, t)
		h:SetSize(c.width, Tbl.HEAD_H)
		h:SetPoint("TOPLEFT", x, 0)
		local fs = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		fs:SetPoint(c.align == "RIGHT" and "RIGHT" or "LEFT", c.align == "RIGHT" and -6 or 6, 0)
		h.text = fs
		h:SetScript("OnClick", function() Tbl.Click(t, c.key) end)
		t.heads[i] = h
		x = x + c.width
	end
	t.width = x
	local rule = t:CreateTexture(nil, "ARTWORK")
	rule:SetPoint("TOPLEFT", 0, -Tbl.HEAD_H)
	rule:SetSize(x, 1)
	rule:SetColorTexture(T.line[1], T.line[2], T.line[3], 1)
	t:EnableMouseWheel(true)
	t:SetScript("OnMouseWheel", function(self, delta) Tbl.Scroll(self, -delta) end)
	Tbl.DrawHeads(t)
	return t
end

--- Sort these tables together: a header click on one sorts every one of them by that column.
function Tbl.Link(...)
	local group = { ... }
	for _, t in ipairs(group) do t.linked = group end
	for i = 2, #group do group[i].sort = { group[1].sort[1], group[1].sort[2] } end
end

function Tbl.DrawHeads(t)
	for i, c in ipairs(t.cols) do
		local on = t.sort[1] == c.key
		local label = c.label .. (on and (t.sort[2] == "desc" and DOWN() or UP()) or "")
		local col = on and T.accent or T.muted
		t.heads[i].text:SetText(label)
		t.heads[i].text:SetTextColor(col[1], col[2], col[3])
	end
end

--- A header click: the same column flips, another column starts in its default direction.
function Tbl.Click(t, key)
	local col
	for _, c in ipairs(t.cols) do if c.key == key then col = c end end
	local dir
	if t.sort[1] == key then dir = t.sort[2] == "desc" and "asc" or "desc" else dir = col and col.default or "desc" end
	for _, o in ipairs(t.linked or { t }) do
		o.sort = { key, dir }
		sortStore()[o.id] = { key, dir }
		Tbl.SetRows(o, o.rows)
	end
end

function Tbl.Scroll(t, by)
	local visible = t.visible or 0
	t.offset = math.max(0, math.min(t.offset + by, math.max(0, #t.rows - visible)))
	Tbl.Draw(t)
end

--- Show rows (sorted by the table's sort). visible: how many fit; the rest scroll.
function Tbl.SetRows(t, rows, visible)
	t.rows = Tbl.Sort(rows or {}, t.sort[1], t.sort[2])
	if visible then t.visible = visible end
	t.offset = math.min(t.offset, math.max(0, #t.rows - (t.visible or #t.rows)))
	Tbl.DrawHeads(t)
	Tbl.Draw(t)
end

local function line(t, i)
	local l = t.lines[i]
	if l then return l end
	l = CreateFrame("Button", nil, t)
	l:SetSize(t.width, Tbl.ROW_H)
	l:SetPoint("TOPLEFT", 0, -(Tbl.HEAD_H + 1 + (i - 1) * Tbl.ROW_H))
	local hl = l:CreateTexture(nil, "BACKGROUND")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.04)
	hl:Hide()
	l.hl = hl
	l:SetScript("OnEnter", function(self) self.hl:Show() end)
	l:SetScript("OnLeave", function(self) self.hl:SetShown(self.selected and true or false) end)
	l:SetScript("OnClick", function(self) if t.onClick and self.row then t.onClick(self.row) end end)
	l.cells = {}
	local x = 0
	for c, col in ipairs(t.cols) do
		local fs = l:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetSize(col.width - 12, Tbl.ROW_H)
		fs:SetPoint("LEFT", x + 6, 0)
		fs:SetJustifyH(col.align == "RIGHT" and "RIGHT" or "LEFT")
		l.cells[c] = fs
		x = x + col.width
	end
	t.lines[i] = l
	return l
end

function Tbl.Draw(t)
	local n = t.visible or #t.rows
	for i = 1, math.max(n, #t.lines) do
		local row = i <= n and t.rows[t.offset + i] or nil
		local l = (row or t.lines[i]) and line(t, i)
		if l then
			l.row = row
			l.selected = row and t.selectedKey ~= nil and row.key == t.selectedKey or false
			l.hl:SetShown(l.selected)
			if row then
				for c, col in ipairs(t.cols) do
					local v = col.text and col.text(row) or row[col.key]
					l.cells[c]:SetText(v == nil and "" or tostring(v))
					local dim = (row.last or row.dim) and T.muted or T.fg
					l.cells[c]:SetTextColor(dim[1], dim[2], dim[3])
				end
				l:Show()
			else
				l:Hide()
			end
		end
	end
end
