-- Groups page of the main window: the group tree on the left, the selected group's items with the
-- prices its operation gives them on the right, and the operation's settings. Rebuild re-sorts your
-- items automatically; right-click an item to move it yourself. Click an item to see the rule that
-- really applies to it: its group and why it's there, its operation and where that was set, and the
-- min, normal and max it evaluates to.
local _, CH = ...

local GUI = {}
CH.GroupsUI = GUI
local page, selected, treeOffset, itemOffset = nil, "Crafted", 0, 0
local selItem -- the item whose effective rule is shown under the list
local TREE_ROWS, ITEM_ROWS, RH = 26, 14, 18
local INFO = 36 -- the effective-rule lines under the items
local X0 = 232

local function money(c) return c and CH.FormatMoney(c) or CH.Theme.Color("muted", "-") end

local OP_FIELDS = {
	{ "post", "Post it", "bool" }, { "undercut", "Undercut", "num", 100 }, { "duration", "Hours (1=12 2=24 3=48)", "num", 1 },
	{ "cap", "Post cap (blank = target)", "num", 1 }, { "keepQuantity", "Keep in bags", "num", 1 }, { "maxExpires", "Max expires (0 = off)", "num", 1 },
	{ "learn", "Learn from sales", "bool" }, { "floorPct", "Min, x the floor", "num", 0.05 }, { "maxMult", "Max, x normal", "num", 0.5 },
}
-- Price formulas (TSM's syntax, see Formula.lua); blank = the floor and multipliers above.
local FORMULAS = { { "minPrice", "Min" }, { "normalPrice", "Normal" }, { "maxPrice", "Max" } }

-- The operation the selected group uses: op, name.
local function currentOp()
	local _, name = CH.Groups.Operation(CH.Groups.Items(selected)[1] or 0)
	name = name or "Default"
	return CH.Groups.Store().ops[name], name
end

--- Set one of the selected operation's formulas (blank clears it). Returns true, or false and why.
function GUI.SetFormula(field, text)
	local op = currentOp()
	text = text and text:match("^%s*(.-)%s*$") or ""
	if text == "" then op[field] = nil; CH.UI.Refresh(); return true end
	local ok, err = CH.Formula.Valid(text)
	if not ok then CH.Print("that formula doesn't read: " .. tostring(err)); return false, err end
	op[field] = text
	CH.UI.Refresh()
	return true
end

--- Items of the selected group as rows (for tests): { id, cells }.
function GUI.Rows(path)
	local out = {}
	for _, id in ipairs(CH.Groups.Items(path or selected)) do
		local p = CH.Groups.Prices(id)
		local text, name = CH.LedgerUI.ItemText(id)
		table.insert(out, { id = id, name = name, cells = { text, money(p.min), money(p.normal), money(p.max), p.cap, CH.Auction.Listed(id),
			p.post and p.op or CH.Theme.Color("muted", p.op .. ", no post") } })
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

local SEP = "/"

--- The rule that applies to an item, and where each part came from:
--- { path, pathFrom, op, opFrom, prices } (pathFrom: "moved", "tsm", "auto"; opFrom: the group
--- path that sets it, or "default").
function GUI.Effective(id)
	local G, s = CH.Groups, CH.Groups.Store()
	local path = G.Path(id)
	if not path then return nil end
	local tsm = s.useTSM and G.TSMGroups()[id] or nil
	local pathFrom = s.manual[id] and "moved" or (tsm and path == tsm) and "tsm" or "auto"
	local _, name = G.Operation(id)
	local opFrom, p = "default", path
	while p do
		if s.assign[p] or (s.assignAll and s.assignAll[p]) then opFrom = p; break end
		p = p:match("^(.*)" .. SEP .. "[^" .. SEP .. "]+$")
	end
	return { path = path, pathFrom = pathFrom, op = name or "Default", opFrom = opFrom, prices = G.Prices(id) }
end

--- The two lines under the items for the selected item (also used by the tests).
function GUI.EffectiveLines(id)
	local T = CH.Theme
	local e = id and GUI.Effective(id)
	if not e then return { T.Color("muted", id and "This item isn't in any group." or "Click an item to see the rule that applies to it."), "" } end
	local _, name = CH.LedgerUI.ItemText(id)
	local from = ({ moved = "you moved it", tsm = "TSM group", auto = "automatic" })[e.pathFrom]
	local opFrom = e.opFrom == "default" and "default for " .. (e.path:match("^([^" .. SEP .. "]+)") or "its group")
		or e.opFrom == e.path and "set on this group" or ("from " .. e.opFrom)
	local p = e.prices
	local line1 = T.Color("accent", name or ("item " .. id)) .. "  " .. e.path .. T.Color("muted", " (" .. from .. ")")
		.. "  Op " .. T.Color("accent", e.op) .. T.Color("muted", " (" .. opFrom .. ")")
	local line2 = "Min " .. money(p.min) .. T.Color("muted", p.why and (" " .. p.why) or "") .. "   Normal " .. money(p.normal)
		.. (p.learned and T.Color("muted", " learned") or "") .. "   Max " .. money(p.max)
		.. "   " .. (p.post and ("posts up to " .. p.cap) or T.Color("bad", "doesn't post"))
	return { line1, line2 }
end

--- Show an item's effective rule under the list (as a click on it does).
function GUI.SelectItem(id) selItem = id; CH.UI.Refresh() end

local function moveMenu(owner, id)
	if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle("Move to group")
		for _, g in ipairs(CH.Groups.Tree()) do
			if g.depth <= 2 and g.path:sub(1, 4) ~= "TSM/" then
				root:CreateButton(string.rep("  ", g.depth) .. g.name, function() CH.Groups.Move(id, g.path); CH.UI.Refresh() end)
			end
		end
		root:CreateDivider()
		root:CreateButton("Back to automatic", function() CH.Groups.Move(id, nil); CH.UI.Refresh() end)
	end)
end

function GUI.Build(p, fs, panel)
	local T = CH.Theme
	page = p
	local tree = panel(p, 0, 0, 220, (p:GetHeight() or 552))
	p.tree = {}
	for i = 1, TREE_ROWS do
		local b = CreateFrame("Button", nil, tree)
		b:SetPoint("TOPLEFT", 6, -30 - (i - 1) * 19)
		b:SetSize(208, 18)
		b.text = fs(b, 0, -2, 208, "LEFT")
		b:SetScript("OnClick", function(self)
			if not self.path then return end
			selected, itemOffset, selItem = self.path, 0, nil
			CH.UI.Refresh()
		end)
		p.tree[i] = b
	end
	local rebuild = T.Button(tree, "Rebuild", 70, 18)
	rebuild:SetPoint("TOPLEFT", 6, -6)
	rebuild:SetScript("OnClick", function() local n = CH.Groups.Rebuild(); CH.Print("groups rebuilt: " .. n .. " items sorted"); CH.UI.Refresh() end)
	local tsm = T.Button(tree, "TSM groups", 110, 18)
	tsm:SetPoint("TOPLEFT", 82, -6)
	tsm:SetScript("OnClick", function() local s = CH.Groups.Store(); s.useTSM = not s.useTSM; CH.UI.Refresh() end)
	p.tsmButton = tsm
	tree:EnableMouseWheel(true)
	tree:SetScript("OnMouseWheel", function(_, d) treeOffset = math.max(0, treeOffset - d * 3); CH.UI.Refresh() end)

	p.title = fs(p, X0, -2, 396, "LEFT", "GameFontNormal")
	local back = T.Button(p, "< Settings", 90, 18)
	back:SetPoint("TOPLEFT", X0 + 408, -2)
	back:SetScript("OnClick", function() CH.UI.Go("settings") end)
	p.opButton = T.Button(p, "Operation", 140, 18)
	p.opButton:SetPoint("TOPRIGHT", p, "TOPLEFT", X0 + 664, -2)
	p.opButton:SetScript("OnClick", function(self)
		if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
		MenuUtil.CreateContextMenu(self, function(_, root)
			root:CreateTitle("Operation for " .. selected)
			for name in pairs(CH.Groups.Store().ops) do
				root:CreateButton(name, function() CH.Groups.Assign(selected, name); CH.UI.Refresh() end)
			end
			root:CreateButton("Inherit", function() CH.Groups.Assign(selected, nil); CH.UI.Refresh() end)
		end)
	end)
	local cols = { { "Item", 0, 220 }, { "Min", 224, 80 }, { "Normal", 308, 80 }, { "Max", 392, 80 }, { "Keep up", 476, 54 },
		{ "Listed", 534, 48 }, { "Operation", 586, 78 } } -- 664 wide: right of the group tree
	for _, c in ipairs(cols) do
		local h = fs(p, X0 + c[2], -26, c[3], c[2] == 0 and "LEFT" or "RIGHT", "GameFontNormalSmall")
		h:SetText(c[1])
	end
	p.items = {}
	for i = 1, ITEM_ROWS do
		local r = { cells = {} }
		local hit = CreateFrame("Button", nil, p)
		hit:SetPoint("TOPLEFT", X0, -42 - (i - 1) * RH)
		hit:SetSize(664, RH)
		if hit.RegisterForClicks then hit:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
		hit:SetScript("OnClick", function(self, button)
			if not self.id then return end
			if button == "RightButton" then moveMenu(self, self.id) else GUI.SelectItem(self.id) end
		end)
		hit:SetScript("OnEnter", function(self)
			if self.id and GameTooltip.SetItemByID then GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetItemByID(self.id); GameTooltip:Show() end
		end)
		hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
		r.hit = hit
		for j, c in ipairs(cols) do r.cells[j] = fs(p, X0 + c[2], -44 - (i - 1) * RH, c[3], j == 1 and "LEFT" or "RIGHT") end
		p.items[i] = r
	end
	p.info = {}
	for k = 1, 2 do p.info[k] = CH.Window.OneLine(fs(p, X0, -44 - ITEM_ROWS * RH - 2 - (k - 1) * 16, 664, "LEFT")) end
	p:EnableMouseWheel(true)
	p:SetScript("OnMouseWheel", function(_, d) itemOffset = math.max(0, itemOffset - d * 5); CH.UI.Refresh() end)

	-- operation settings for the selected group's operation
	p.opTitle = fs(p, X0, -44 - ITEM_ROWS * RH - INFO - 8, 500, "LEFT", "GameFontNormal")
	-- copy TSM's operations, custom sources and group assignments in, once
	p.importTSM = T.Button(p, "Import TSM rules", 150, 18)
	p.importTSM:SetPoint("TOPLEFT", X0 + 514, -44 - ITEM_ROWS * RH - INFO - 6)
	p.importTSM:SetScript("OnClick", function()
		local n, err = CH.Groups.ImportTSM()
		if n then
			local head, lines = CH.Groups.ImportSummary(n)
			CH.Print("copied from TSM: " .. head .. ". They're AuctionIQ's now.")
			for _, l in ipairs(lines) do CH.Print("  " .. l) end
		else CH.Print("couldn't import: " .. tostring(err)) end
		CH.UI.Refresh()
	end)
	p.opFields = {}
	for i, f in ipairs(OP_FIELDS) do
		local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
		local x, y = X0 + col * 242, -44 - ITEM_ROWS * RH - INFO - 30 - row * 24
		local label = fs(p, x, y - 3, 150, "LEFT")
		label:SetText(f[2])
		local minus = T.Button(p, "-", 18, 18); minus:SetPoint("TOPLEFT", x + 150, y)
		local val = fs(p, x + 170, y - 3, 44, "CENTER")
		local plus = T.Button(p, "+", 18, 18); plus:SetPoint("TOPLEFT", x + 216, y)
		local function change(dir)
			local op = currentOp()
			local v = op[f[1]]
			if f[3] == "bool" then
				if f[1] == "learn" then op.learn = not op.learn else op[f[1]] = not (v ~= false) end
			else
				if type(v) == "string" then v = CH.Formula.Value(v, CH.Groups.Items(selected)[1] or 0) or 0 end
				op[f[1]] = math.max(0, (v or 0) + dir * f[4])
			end
			if f[1] == "cap" and op.cap == 0 then op.cap = nil end
			CH.UI.Refresh()
		end
		minus:SetScript("OnClick", function() change(-1) end)
		plus:SetScript("OnClick", function() change(1) end)
		p.opFields[i] = { val = val, f = f }
	end
	p.formulas = {}
	local fy = -44 - ITEM_ROWS * RH - INFO - 30 - 3 * 24 - 6
	for i, f in ipairs(FORMULAS) do
		local y = fy - (i - 1) * 24
		local label = fs(p, X0, y - 3, 56, "LEFT")
		label:SetText(f[2])
		local eb = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
		eb:SetSize(600, 20)
		eb:SetPoint("TOPLEFT", X0 + 62, y + 1)
		eb:SetAutoFocus(false)
		eb:SetScript("OnEnterPressed", function(self) self:ClearFocus(); GUI.SetFormula(f[1], self:GetText()) end)
		eb:SetScript("OnEscapePressed", function(self) self:ClearFocus(); CH.UI.Refresh() end)
		p.formulas[i] = { box = eb, f = f }
	end
	p.formulaHelp = fs(p, X0, fy - 3 * 24 - 2, 664, "LEFT", "GameFontDisableSmall")
	p.formulaHelp:SetText("TSM syntax, e.g. max(150% vendorsell, saleavg). Blank = floor and multipliers.")
end

function GUI.Refresh()
	local p = page
	if not p then return {} end
	local T = CH.Theme
	local s = CH.Groups.Store()
	if p.tsmButton.text then p.tsmButton.text:SetText(s.useTSM and "TSM groups: on" or "TSM groups: off") end
	local tree = CH.Groups.Tree()
	treeOffset = math.max(0, math.min(treeOffset, #tree - TREE_ROWS))
	for i, b in ipairs(p.tree) do
		local g = tree[i + treeOffset]
		b.path = g and g.path
		if g then
			local own = s.assign[g.path] and T.Color("accent", " *") or ""
			local label = string.rep("   ", g.depth) .. g.name .. T.Color("muted", " " .. g.n) .. own
			b.text:SetText(g.path == selected and T.Color("accent", label) or label)
		else
			b.text:SetText("")
		end
	end
	local rows = GUI.Rows(selected)
	p.title:SetText(selected .. T.Color("muted", "  " .. #rows .. " items; right-click one to move it"))
	itemOffset = math.max(0, math.min(itemOffset, #rows - ITEM_ROWS))
	for i, r in ipairs(p.items) do
		local d = rows[i + itemOffset]
		r.hit.id = d and d.id
		for j, c in ipairs(r.cells) do c:SetText(d and tostring(d.cells[j] or "") or "") end
	end
	local lines = GUI.EffectiveLines(selItem)
	for k, fsk in ipairs(p.info) do fsk:SetText(lines[k] or "") end
	local _, name = CH.Groups.Operation(CH.Groups.Items(selected)[1] or 0)
	name = name or "Default"
	if p.opButton.text then p.opButton.text:SetText("Operation: " .. name) end
	local op = s.ops[name]
	p.opTitle:SetText("Operation " .. T.Color("accent", name) .. T.Color("muted", op.imported and "  (from TSM, now yours; shared by its groups)"
		or ("  (shared by its groups; floor: " .. (op.floor or "market") .. ")")))
	for _, e in ipairs(p.opFields) do
		local v = op[e.f[1]]
		if e.f[1] == "learn" then e.val:SetText(v and T.Color("ok", "yes") or T.Color("muted", "no"))
		elseif e.f[3] == "bool" then e.val:SetText(v ~= false and T.Color("ok", "yes") or T.Color("bad", "no"))
		elseif e.f[1] == "cap" and not v then e.val:SetText("target")
		elseif e.f[1] == "undercut" and type(v) == "number" then e.val:SetText(v >= 100 and CH.FormatMoney(v) or (v .. "c"))
		else e.val:SetText(tostring(v or 0)) end
	end
	for _, e in ipairs(p.formulas) do
		if not (e.box.HasFocus and e.box:HasFocus() == true) then e.box:SetText(op[e.f[1]] or "") end
	end
	return rows
end

function GUI.Select(path) selected, itemOffset = path, 0 end
