-- Groups page of the main window: the group tree on the left, the selected group's items with the
-- prices its operation gives them on the right, and the operation's settings. Rebuild re-sorts your
-- items automatically; right-click an item to move it yourself.
local _, CH = ...

local GUI = {}
CH.GroupsUI = GUI
local page, selected, treeOffset, itemOffset = nil, "Crafted", 0, 0
local TREE_ROWS, ITEM_ROWS, RH = 26, 20, 18
local X0 = 232

local function money(c) return c and CH.FormatMoney(c) or CH.Theme.Color("muted", "-") end

local OP_FIELDS = {
	{ "post", "Post it", "bool" }, { "undercut", "Undercut (copper)", "num", 1 }, { "duration", "Duration (1=12h 2=24h 3=48h)", "num", 1 },
	{ "floorPct", "Min, x the floor", "num", 0.05 }, { "maxMult", "Max, x normal", "num", 0.5 }, { "cap", "Keep up (blank = par)", "num", 1 },
}

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

--- Right-click a group: mail its items to one of your characters.
function GUI.RouteMenu(owner, path)
	if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle("Mail " .. path .. " to")
		for _, c in ipairs(CH.Ledger.Characters()) do
			root:CreateRadio(c.name, function() return CH.Mail.Store().routes[path] == c.name end,
				function() CH.Mail.Route(path, c.name); CH.UI.Refresh() end)
		end
		root:CreateButton("Don't mail", function() CH.Mail.Route(path, nil); CH.UI.Refresh() end)
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
		if b.RegisterForClicks then b:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
		b:SetScript("OnClick", function(self, button)
			if not self.path then return end
			if button == "RightButton" then return GUI.RouteMenu(self, self.path) end
			selected, itemOffset = self.path, 0
			CH.UI.Refresh()
		end)
		p.tree[i] = b
	end
	local rebuild = T.Button(tree, "Rebuild", 70, 18)
	rebuild:SetPoint("TOPLEFT", 6, -6)
	rebuild:SetScript("OnClick", function() local n = CH.Groups.Rebuild(); CH.Print("groups rebuilt: " .. n .. " items sorted"); CH.UI.Refresh() end)
	local tsm = T.Button(tree, "TSM groups", 90, 18)
	tsm:SetPoint("TOPLEFT", 82, -6)
	tsm:SetScript("OnClick", function() local s = CH.Groups.Store(); s.useTSM = not s.useTSM; CH.UI.Refresh() end)
	p.tsmButton = tsm
	tree:EnableMouseWheel(true)
	tree:SetScript("OnMouseWheel", function(_, d) treeOffset = math.max(0, treeOffset - d * 3); CH.UI.Refresh() end)

	p.title = fs(p, X0, -2, 400, "LEFT", "GameFontNormal")
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
	local cols = { { "Item", 0, 230 }, { "Min", 234, 88 }, { "Normal", 326, 88 }, { "Max", 418, 88 }, { "Keep up", 510, 54 },
		{ "Listed", 568, 48 }, { "Operation", 620, 100 } }
	for _, c in ipairs(cols) do
		local h = fs(p, X0 + c[2], -26, c[3], c[2] == 0 and "LEFT" or "RIGHT", "GameFontNormalSmall")
		h:SetText(c[1])
	end
	p.items = {}
	for i = 1, ITEM_ROWS do
		local r = { cells = {} }
		local hit = CreateFrame("Button", nil, p)
		hit:SetPoint("TOPLEFT", X0, -42 - (i - 1) * RH)
		hit:SetSize(724, RH)
		if hit.RegisterForClicks then hit:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
		hit:SetScript("OnClick", function(self, button) if self.id and button == "RightButton" then moveMenu(self, self.id) end end)
		hit:SetScript("OnEnter", function(self)
			if self.id and GameTooltip.SetItemByID then GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetItemByID(self.id); GameTooltip:Show() end
		end)
		hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
		r.hit = hit
		for j, c in ipairs(cols) do r.cells[j] = fs(p, X0 + c[2], -44 - (i - 1) * RH, c[3], j == 1 and "LEFT" or "RIGHT") end
		p.items[i] = r
	end
	p:EnableMouseWheel(true)
	p:SetScript("OnMouseWheel", function(_, d) itemOffset = math.max(0, itemOffset - d * 5); CH.UI.Refresh() end)

	-- operation settings for the selected group's operation
	p.opTitle = fs(p, X0, -44 - ITEM_ROWS * RH - 8, 400, "LEFT", "GameFontNormal")
	p.opFields = {}
	for i, f in ipairs(OP_FIELDS) do
		local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
		local x, y = X0 + col * 242, -44 - ITEM_ROWS * RH - 30 - row * 24
		local label = fs(p, x, y - 3, 150, "LEFT")
		label:SetText(f[2])
		local minus = T.Button(p, "-", 18, 18); minus:SetPoint("TOPLEFT", x + 150, y)
		local val = fs(p, x + 170, y - 3, 44, "CENTER")
		local plus = T.Button(p, "+", 18, 18); plus:SetPoint("TOPLEFT", x + 216, y)
		local function change(dir)
			local _, name = CH.Groups.Operation(CH.Groups.Items(selected)[1] or 0)
			local op = CH.Groups.Store().ops[name or "Default"]
			if f[3] == "bool" then op[f[1]] = not (op[f[1]] ~= false)
			else op[f[1]] = math.max(0, (op[f[1]] or (f[1] == "cap" and 0) or 0) + dir * f[4]) end
			if f[1] == "cap" and op.cap == 0 then op.cap = nil end
			CH.UI.Refresh()
		end
		minus:SetScript("OnClick", function() change(-1) end)
		plus:SetScript("OnClick", function() change(1) end)
		p.opFields[i] = { val = val, f = f }
	end
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
			local to = CH.Mail and CH.Mail.Store().routes[g.path]
			if to then own = own .. T.Color("muted", " > " .. to) end
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
	local _, name = CH.Groups.Operation(CH.Groups.Items(selected)[1] or 0)
	name = name or "Default"
	if p.opButton.text then p.opButton.text:SetText("Operation: " .. name) end
	local op = s.ops[name]
	p.opTitle:SetText("Operation " .. T.Color("accent", name) .. T.Color("muted", "  (shared by every group using it; min's floor: " .. (op.floor or "market") .. ")"))
	for _, e in ipairs(p.opFields) do
		local v = op[e.f[1]]
		if e.f[3] == "bool" then e.val:SetText(v ~= false and T.Color("ok", "yes") or T.Color("bad", "no"))
		elseif e.f[1] == "cap" and not v then e.val:SetText("par")
		else e.val:SetText(tostring(v or 0)) end
	end
	return rows
end

function GUI.Select(path) selected, itemOffset = path, 0 end
