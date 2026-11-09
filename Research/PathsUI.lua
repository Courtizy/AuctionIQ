-- Research, Professions, Paths: type what you want to sell, get a knowledge point plan for the open
-- profession, see it on the profession's own trees (the game's layout), then try it in the crafting
-- advisor (simulation) before spending a point. A page beside Research's nav, 724 wide.
local _, CH = ...

local PUI = {}
CH.PathsUI = PUI
local frame, input, out, pointsText, goalButtons, tabButtons, view, treeNote
local W = 724
local TREE_W, TREE_H = 724, 270 -- the whole tree across the page; the plan explained below it
local TABS_Y, TREE_Y = -98, -122
local extra = 0
local lastPlan
local selectedTab

local function render(lines)
	out:SetText(table.concat(lines or {}, "\n"))
	if frame.child then frame.child:SetHeight(math.max(10, (out.GetStringHeight and out:GetStringHeight() or 0) + 10)) end
end

local function updatePoints()
	local prof = CH.OpenProfessionID()
	local tree = prof and CH.Spec.Tree(prof)
	local unspent = tree and tree.unspent or 0
	pointsText:SetText(string.format("Plan %d points  %s", unspent + extra,
		CH.Theme.Color("muted", string.format("(%d unspent + %d to earn)", unspent, extra))))
end

local function setLabel(b, t)
	if b.text then b.text:SetText(t) elseif b.SetText then b:SetText(t) end
end

--- Redraw the tree for the selected spec tab with the current plan on it. Returns what it drew.
function PUI.DrawTree()
	if not frame then return {} end
	local T = CH.Theme
	local prof = CH.OpenProfessionID() or (lastPlan and lastPlan.prof)
	local tree = prof and CH.Spec.Tree(prof)
	local plan = CH.Paths.Current(prof)
	local marks = CH.Paths.Marks(plan)
	local tabs = tree and tree.tabs or {}
	-- keep the chosen tab, else the one the plan starts in, else the first
	local valid = false
	for _, t in ipairs(tabs) do if t.id == selectedTab then valid = true end end
	if not valid then
		selectedTab = tabs[1] and tabs[1].id
		local first = plan and plan.steps[1] and tree.layout[plan.steps[1].node]
		if first then selectedTab = first.tab end
	end
	local tx = 12
	for i, b in ipairs(tabButtons) do
		local t = tabs[i]
		if t then
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", frame, "TOPLEFT", tx, TABS_Y)
			local n = 0
			for _, id in ipairs(t.nodes) do if marks[id] then n = n + 1 end end
			setLabel(b, t.name .. (n > 0 and (" (" .. n .. ")") or ""))
			local fs = b.text or (b.GetFontString and b:GetFontString())
			local c = t.id == selectedTab and T.accent or T.fg
			if fs and fs.SetTextColor then fs:SetTextColor(c[1], c[2], c[3]) end
			b:SetScript("OnClick", function() selectedTab = t.id; PUI.DrawTree() end)
			local w = math.max(80, math.ceil((fs and fs.GetStringWidth and fs:GetStringWidth() or 90) + 20))
			b:SetWidth(w)
			tx = tx + w + 4
			b:Show()
		else
			b:Hide()
		end
	end
	if #tabs == 0 then
		treeNote:SetText(T.Color("muted", "Open the profession to see its specialization trees here."))
	else
		treeNote:SetText(plan and T.Color("muted", "Gold ring: points the plan adds. Badge: the step to spend them in. Hover a node for its perks.") or "")
	end
	return view:Draw(tree, selectedTab, marks, prof)
end

--- Plan for a typed goal, or for a picked set of recipes (recipes + label from the group picker).
function PUI.Run(goal, recipes)
	if not PUI.IsShown() then PUI.Open() end
	goal = goal or (input and input:GetText()) or ""
	render({ CH.Theme.Color("accent", "Working out a plan for \"" .. goal .. "\" ...") })
	local plan, why = CH.Paths.Plan({ goal = goal, recipes = recipes, label = recipes and goal or nil, points = extra, onDone = function(p)
		lastPlan = p
		if p.error then
			render({ CH.Theme.Color("bad", "Couldn't finish the plan: " .. tostring(p.error)) })
		else
			render(p.text)
			selectedTab = nil
			CH.Paths.SetCurrent(p)
		end
		PUI.simButton:SetEnabled(p.ranks ~= nil)
	end })
	if not plan then render({ CH.Theme.Color("muted", why) }) end
end

--- Set the points to what finishing the path for these recipes takes (less what's unspent).
function PUI.DefaultPoints(recipes)
	local prof = CH.OpenProfessionID()
	local tree = prof and CH.Spec.Tree(prof)
	if not tree then return extra end
	if not recipes then recipes = CH.Paths.Match(input and input:GetText() or "") end
	local goal = input and input:GetText() or ""
	extra = math.max(0, CH.Paths.PathCost(prof, recipes, (not recipes or #recipes == 0) and goal or nil) - (tree.unspent or 0))
	updatePoints()
	return extra
end

--- Pick a group (or one of its splits) and plan it.
function PUI.Pick(label, recipes)
	input:SetText(label)
	PUI.DefaultPoints(recipes)
	PUI.Run(label, recipes)
end

--- Build the page into p (from the main window: Research, Professions, Paths).
function PUI.Build(p)
	local T, Wd = CH.Theme, CH.Window
	frame = p
	local ask = Wd.Text(frame, 0, -4, W, "LEFT", "GameFontNormal")
	ask:SetText("What do you want to sell?" .. T.Color("muted", "  a knowledge point plan for the open profession"))
	input = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	input:SetSize(420, 20)
	input:SetPoint("TOPLEFT", 6, -24)
	input:SetAutoFocus(false)
	input:SetText("potions")
	input:SetScript("OnEnterPressed", function(self) self:ClearFocus(); PUI.DefaultPoints(); PUI.Run() end)
	local go = T.Button(frame, "Plan", 70, 20)
	go:SetPoint("TOPLEFT", 434, -24)
	go:SetScript("OnClick", function() PUI.DefaultPoints(); PUI.Run() end)

	goalButtons = {}
	for i = 1, 7 do
		local b = T.Button(frame, "", 100, 18)
		b:SetPoint("TOPLEFT", (i - 1) * 104, -50)
		b:Hide()
		goalButtons[i] = b
	end

	pointsText = Wd.Text(frame, 0, -78, 300)
	local minus = T.Button(frame, "-5", 30, 18)
	minus:SetPoint("TOPLEFT", 308, -74)
	minus:SetScript("OnClick", function() extra = math.max(0, extra - 5); updatePoints() end)
	local plus = T.Button(frame, "+5", 30, 18)
	plus:SetPoint("TOPLEFT", 342, -74)
	plus:SetScript("OnClick", function() extra = extra + 5; updatePoints() end)
	PUI.simButton = T.Button(frame, "Simulate", 90, 18)
	PUI.simButton:SetPoint("TOPRIGHT", -66, -74)
	PUI.simButton:SetEnabled(false)
	PUI.simButton:SetScript("OnClick", function()
		if lastPlan and lastPlan.ranks then CH.AdvisorUI.SetPlan(lastPlan) end
	end)
	PUI.simButton:SetScript("OnEnter", function(self)
		CH.Window.Tooltip(self, { { "Show the crafting advisor's numbers as if you'd spent these points. Turn it off from the advisor's Sim bar." } })
	end)
	PUI.simButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
	local clear = T.Button(frame, "Clear", 60, 18)
	clear:SetPoint("TOPRIGHT", 0, -74)
	clear:SetScript("OnClick", function()
		CH.Paths.ClearCurrent(lastPlan and lastPlan.prof or CH.OpenProfessionID())
		lastPlan = nil
		PUI.simButton:SetEnabled(false)
		render({ CH.Theme.Color("muted", "Plan cleared.") })
	end)
	clear:SetScript("OnEnter", function(self) CH.Window.Tooltip(self, { { "Take the plan off the trees, here and in the game's Specializations tab." } }) end)
	clear:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- the profession's spec tabs, then its tree as the game lays it out
	tabButtons = {}
	for i = 1, 6 do
		local b = T.Button(frame, "", 104, 18)
		b:SetPoint("TOPLEFT", (i - 1) * 108, TABS_Y)
		b:Hide()
		tabButtons[i] = b -- widths and positions set from their names in DrawTree
	end
	view = CH.TreeView.New(frame, 0, TREE_Y, TREE_W, TREE_H)
	treeNote = CH.Window.OneLine(Wd.Text(frame, 0, TREE_Y - TREE_H - 4, TREE_W))

	local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 0, TREE_Y - TREE_H - 22)
	scroll:SetPoint("BOTTOMRIGHT", -22, 0)
	local cw = W - 26
	local child = CreateFrame("Frame", nil, scroll)
	child:SetSize(cw, 10)
	scroll:SetScrollChild(child)
	frame.child = child
	out = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	out:SetPoint("TOPLEFT")
	out:SetWidth(cw - 4)
	out:SetJustifyH("LEFT")
	out:SetSpacing(3)
	T.Fonts(frame)
end

-- A group button: the whole group, or a menu of its splits (Light or Void potions) when it has any.
local function groupMenu(owner, g)
	if g.yield then return PUI.Pick(g.name) end
	if not (MenuUtil and MenuUtil.CreateContextMenu) or #g.subs == 0 then return PUI.Pick(g.name, g.recipes) end
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle(g.name)
		root:CreateButton("All " .. string.lower(g.name) .. " (" .. #g.recipes .. ")", function() PUI.Pick(g.name, g.recipes) end)
		for _, sub in ipairs(g.subs) do
			local label = g.name .. " - " .. sub.name
			root:CreateButton(sub.name .. " (" .. #sub.recipes .. ")", function() PUI.Pick(label, sub.recipes) end)
		end
	end)
end

local function fillGoals()
	local groups = CH.OpenProfessionID() and CH.Paths.GoalGroups() or {}
	PUI.groups = groups
	local gx = 0
	for i, b in ipairs(goalButtons) do
		local g = groups[i]
		if g then
			setLabel(b, g.name .. (#g.subs > 0 and " +" or ""))
			local gfs = b.text or (b.GetFontString and b:GetFontString())
			b:SetWidth(math.max(80, math.ceil((gfs and gfs.GetStringWidth and gfs:GetStringWidth() or 90) + 20)))
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", frame, "TOPLEFT", gx, -84)
			gx = gx + b:GetWidth() + 4
			if gx > W + 4 then b:Hide() end -- no room left on the line
			b:SetScript("OnClick", function(self) groupMenu(self, g) end)
			b:SetScript("OnEnter", function(self)
				local lines = { { g.name }, g.yield and { "Plans the Disenchanting tree for more rank 2 materials", "" } or { #g.recipes .. " recipes", "" } }
				if #g.subs > 0 then table.insert(lines, { CH.Theme.Color("muted", "Click to pick all of them or one branch.") }) end
				CH.Window.Tooltip(self, lines)
			end)
			b:SetScript("OnLeave", function() GameTooltip:Hide() end)
			b:Show()
		else
			b:Hide()
		end
	end
end

--- Open Research, Professions, Paths in the main window; again closes the window.
function PUI.Toggle()
	if PUI.IsShown() then CH.UI.Toggle() else PUI.Open() end
end

function PUI.Open() CH.UI.Page("research", "paths") end

--- Fill the page: the goal groups, the points and the tree. The main window calls it when the
--- page shows.
function PUI.Refresh()
	if not frame then return {} end
	fillGoals()
	if CH.OpenProfessionID() and not lastPlan then PUI.DefaultPoints() else updatePoints() end
	if not CH.OpenProfessionID() then
		render({ CH.Theme.Color("muted", "Open the profession you want a plan for (any of the eight crafting professions), then type a goal like \"potions\", \"gems\" or \"disenchanting\".") })
	elseif not lastPlan then
		render({ CH.Theme.Color("muted", "Pick a group above (some open a menu, like Light or Void potions) or type what you want to sell and press Plan. Points start at what finishing that path takes; change them with -5 and +5.") })
	end
	return PUI.DrawTree()
end

function PUI.IsShown() return frame ~= nil and frame:IsShown() and CH.UI.IsShown() end

local function changed()
	if PUI.IsShown() then PUI.DrawTree() end
	if CH.SpecOverlay then CH.SpecOverlay.Refresh() end
end
CH.Paths.Changed = changed
CH.On("TRAIT_NODE_CHANGED", function() C_Timer.After(0.2, changed) end)
