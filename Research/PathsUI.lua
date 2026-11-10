-- Research, Professions, Paths: type what you want to sell, get a knowledge point plan for the open
-- profession, see it on the profession's own trees (the game's layout), then try it in the crafting
-- advisor (simulation) before spending a point. A page beside Research's nav, 724 wide.
local _, CH = ...

local PUI = {}
CH.PathsUI = PUI
local frame, input, out, pointsText, goalButtons, tabButtons, view, treeNote
local W = 724 -- the page's width, and the tree's: both follow the window (set in Build)
local TREE_W, TREE_H = 724, 228 -- the whole tree across the page; the plan explained below it
-- top down: the profession, Knowledge and Plan payoff for it, then Paths (ask, goals, points, the tree)
local KP_Y, PAY_Y = -4, -26
local ASK_Y, INPUT_Y, GOALS_Y, POINTS_Y, TABS_Y, TREE_Y = -52, -70, -96, -122, -146, -170
local extra = 0
local lastPlan
local selectedTab
local chosenProf, profButtons

-- Each profession's Midnight skill line (the one with a specialization tree), by its base skill line
local MIDNIGHT = { [171] = 2906, [164] = 2907, [333] = 2909, [202] = 2910, [773] = 2913, [755] = 2914, [165] = 2915, [197] = 2918 }
PUI.MIDNIGHT = MIDNIGHT

--- This character's crafting professions that have trees: { { id, name } }, read from the game
--- (no profession window needed), else from what AuctionIQ saw when a profession was last open.
function PUI.Professions()
	local out, seen = {}, {}
	local function add(id, name)
		if id and not seen[id] and CH.Spec.Data(id) then seen[id] = true; table.insert(out, { id = id, name = name or ("Profession " .. id) }) end
	end
	if GetProfessions and GetProfessionInfo then
		local a, b = GetProfessions()
		for _, ix in ipairs({ a or false, b or false }) do
			if ix then
				local name, _, _, _, _, _, line = GetProfessionInfo(ix)
				add(MIDNIGHT[line], name)
			end
		end
	end
	for id, p in pairs(CH.Me().professions or {}) do add(id, p.parent or p.name) end
	return out
end

--- The profession the page shows: the open profession window's, else the one picked, else the first.
function PUI.Prof()
	local open = CH.OpenProfessionID()
	if open and CH.Spec.Data(open) then return open end
	local list = PUI.Professions()
	for _, p in ipairs(list) do if p.id == chosenProf then return chosenProf end end
	return list[1] and list[1].id or open
end

--- Pick which profession's tree to show.
function PUI.Choose(id)
	chosenProf = id
	if lastPlan and lastPlan.prof ~= id then lastPlan = nil end
	selectedTab = nil
	extra = 0
	PUI.Refresh()
end

-- true when planning can run: the page's profession is the one open in the profession window
local function canPlan() return CH.OpenProfessionID() ~= nil and CH.OpenProfessionID() == PUI.Prof() end

local function render(lines)
	out:SetText(table.concat(lines or {}, "\n"))
	if frame.child then frame.child:SetHeight(math.max(10, (out.GetStringHeight and out:GetStringHeight() or 0) + 10)) end
end

local function updatePoints()
	local prof = PUI.Prof()
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
	local prof = PUI.Prof() or (lastPlan and lastPlan.prof)
	local tree = prof and CH.Spec.Tree(prof)
	local plan = CH.Paths.Current(prof)
	local marks = CH.Paths.Marks(plan)
	local tabs = tree and tree.tabs or {}
	-- keep the chosen tab, else the one the plan starts in, else the first
	local valid = false
	for _, t in ipairs(tabs) do if t.id == selectedTab then valid = true end end
	if not valid then
		-- no plan: the tab where you've spent the most points
		local most = -1
		for _, t in ipairs(tabs) do
			local spent = 0
			for _, id in ipairs(t.nodes) do spent = spent + math.max(0, (tree.layout[id] and tree.layout[id].rank) or 0) end
			if spent > most then most, selectedTab = spent, t.id end
		end
		local first = plan and plan.steps[1] and tree.layout[plan.steps[1].node]
		if first then selectedTab = first.tab end
	end
	-- the tabs across the page: their names at full size when they fit, else the small font
	local function lay(font, pad)
		local tx = 0
		for i, b in ipairs(tabButtons) do
			local t = tabs[i]
			if t then
				local n = 0
				for _, id in ipairs(t.nodes) do if marks[id] then n = n + 1 end end
				setLabel(b, t.name .. (n > 0 and (" (" .. n .. ")") or ""))
				local fs = b.text or (b.GetFontString and b:GetFontString())
				if fs and fs.SetFontObject then fs:SetFontObject(font) end
				CH.Window.OneLine(fs or {})
				local c = t.id == selectedTab and T.accent or T.fg
				if fs and fs.SetTextColor then fs:SetTextColor(c[1], c[2], c[3]) end
				b:SetScript("OnClick", function() selectedTab = t.id; PUI.DrawTree() end)
				local w = math.max(60, math.ceil((fs and fs.GetStringWidth and fs:GetStringWidth() or 90) + pad))
				b:SetWidth(w)
				b:ClearAllPoints()
				b:SetPoint("TOPLEFT", frame, "TOPLEFT", tx, TABS_Y)
				tx = tx + w + 4
				b:Show()
			else
				b:Hide()
			end
		end
		return tx - 4
	end
	if lay("GameFontHighlight", 20) > W then lay("GameFontHighlightSmall", 12) end
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
	if not canPlan() then
		local name = "the profession"
		for _, p in ipairs(PUI.Professions()) do if p.id == PUI.Prof() then name = p.name end end
		render({ CH.Theme.Color("muted", "Open " .. name .. " to plan for it: a plan needs its recipes. The tree above shows where your points are now.") })
		return
	end
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
	local prof = canPlan() and PUI.Prof()
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
	W = math.max(724, math.floor(p:GetWidth() or 724))
	TREE_W = W
	TREE_H = 228 + math.max(0, (CH.UI.Height and CH.UI.Height() or 600) - 600) -- a taller window, a taller tree
	selectedTab = nil
	-- your professions, to pick whose tree to show
	profButtons = {}
	for i = 1, 3 do
		local b = T.Button(frame, "", 100, 20)
		b:SetPoint("TOPLEFT", (i - 1) * 104, 0)
		b:Hide()
		profButtons[i] = b
	end
	-- Knowledge and Plan payoff for the profession picked, above Paths
	frame.kpText = Wd.OneLine(Wd.Text(frame, 336, KP_Y, W - 336, "LEFT", "GameFontHighlightSmall"))
	frame.payText = Wd.OneLine(Wd.Text(frame, 0, PAY_Y, W - 110, "LEFT", "GameFontHighlightSmall"))
	local byRecipe = T.Button(frame, "By recipe", 100, 18)
	byRecipe:SetPoint("TOPRIGHT", 0, PAY_Y + 2)
	byRecipe:SetScript("OnClick", function() CH.UI.Go("operations", "plans") end)
	byRecipe:SetScript("OnEnter", function(self) CH.Window.Tooltip(self, { { "Each saved plan, recipe by recipe: quality and profit now against planned." } }) end)
	byRecipe:SetScript("OnLeave", function() GameTooltip:Hide() end)
	frame.byRecipe = byRecipe
	local ask = Wd.Text(frame, 0, ASK_Y, W, "LEFT", "GameFontNormal")
	ask:SetText("Paths: what do you want to sell?" .. T.Color("muted", "  a knowledge point plan for the open profession"))
	input = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	input:SetSize(420, 20)
	input:SetPoint("TOPLEFT", 6, INPUT_Y)
	input:SetAutoFocus(false)
	input:SetText("")
	input:SetScript("OnEnterPressed", function(self) self:ClearFocus(); PUI.DefaultPoints(); PUI.Run() end)
	local go = T.Button(frame, "Plan", 70, 20)
	go:SetPoint("TOPLEFT", 434, INPUT_Y)
	go:SetScript("OnClick", function() PUI.DefaultPoints(); PUI.Run() end)

	goalButtons = {}
	for i = 1, 7 do
		local b = T.Button(frame, "", 100, 18)
		b:SetPoint("TOPLEFT", (i - 1) * 104, GOALS_Y)
		b:Hide()
		goalButtons[i] = b
	end

	pointsText = Wd.Text(frame, 0, POINTS_Y - 4, 300)
	local minus = T.Button(frame, "-5", 30, 18)
	minus:SetPoint("TOPLEFT", 308, POINTS_Y)
	minus:SetScript("OnClick", function() extra = math.max(0, extra - 5); updatePoints() end)
	local plus = T.Button(frame, "+5", 30, 18)
	plus:SetPoint("TOPLEFT", 342, POINTS_Y)
	plus:SetScript("OnClick", function() extra = extra + 5; updatePoints() end)
	PUI.simButton = T.Button(frame, "Simulate", 90, 18)
	PUI.simButton:SetPoint("TOPRIGHT", -66, POINTS_Y)
	PUI.simButton:SetEnabled(lastPlan ~= nil and lastPlan.ranks ~= nil) -- kept when the window is resized
	PUI.simButton:SetScript("OnClick", function()
		if lastPlan and lastPlan.ranks then CH.AdvisorUI.SetPlan(lastPlan) end
	end)
	PUI.simButton:SetScript("OnEnter", function(self)
		CH.Window.Tooltip(self, { { "Show the crafting advisor's numbers as if you'd spent these points. Turn it off from the advisor's Sim bar." } })
	end)
	PUI.simButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
	local clear = T.Button(frame, "Clear", 60, 18)
	clear:SetPoint("TOPRIGHT", 0, POINTS_Y)
	clear:SetScript("OnClick", function()
		CH.Paths.ClearCurrent(lastPlan and lastPlan.prof or PUI.Prof())
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
	local groups = canPlan() and CH.Paths.GoalGroups() or {}
	PUI.groups = groups
	local gx = 0
	for i, b in ipairs(goalButtons) do
		local g = groups[i]
		if g then
			setLabel(b, g.name .. (#g.subs > 0 and " +" or ""))
			local gfs = b.text or (b.GetFontString and b:GetFontString())
			b:SetWidth(math.max(80, math.ceil((gfs and gfs.GetStringWidth and gfs:GetStringWidth() or 90) + 20)))
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", frame, "TOPLEFT", gx, GOALS_Y)
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
local function fillProfessions()
	local T = CH.Theme
	local list, current = PUI.Professions(), PUI.Prof()
	local x = 0
	for i, b in ipairs(profButtons) do
		local p = list[i]
		if p then
			setLabel(b, p.name)
			local f = b.text or (b.GetFontString and b:GetFontString())
			local c = p.id == current and T.accent or T.fg
			if f and f.SetTextColor then f:SetTextColor(c[1], c[2], c[3]) end
			b:SetWidth(math.max(90, math.ceil((f and f.GetStringWidth and f:GetStringWidth() or 80) + 20)))
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", frame, "TOPLEFT", x, 0)
			x = x + b:GetWidth() + 4
			b:SetScript("OnClick", function() PUI.Choose(p.id) end)
			b:Show()
		else
			b:Hide()
		end
	end
end

function PUI.Toggle()
	if PUI.IsShown() then CH.UI.Toggle() else PUI.Open() end
end

function PUI.Open() CH.UI.Page("operations", "paths") end

--- Knowledge for a profession on this character, in a line: unspent points, gained this week and the
--- weekly sources ticked off.
function PUI.KnowledgeLine(prof)
	local T = CH.Theme
	local name = CH.SpecData and CH.SpecData[prof] and CH.SpecData[prof].name
	local tree = prof and CH.Spec.Tree(prof)
	local key = CH.CharacterKey and CH.CharacterKey()
	local row
	pcall(CH.Planner.RecordKP)
	for _, r in ipairs(CH.Planner.Knowledge()) do
		if r.key == key and name and (r.prof == name or r.prof:find(name, 1, true) or name:find(r.prof, 1, true)) then row = r end
	end
	local unspent = tree and tree.unspent or (row and row.unspent) or 0
	local t = T.Color("accent", "Knowledge  ") .. string.format("%d unspent", unspent)
	if row then
		local done = 0
		for _, task in ipairs(row.tasks) do if task.done then done = done + 1 end end
		t = t .. string.format(", %s this week. Weekly sources: %d of %d done.", row.gained > 0 and ("+" .. row.gained) or "0", done, #row.tasks)
	else
		t = t .. "."
	end
	return t
end

--- How far a saved plan has got on the tree now: points in, points it plans (nil without node ids).
function PUI.PlanProgress(sum, tree)
	if not (sum and tree and tree.layout) then return nil end
	local done, total = 0, 0
	for _, s in ipairs(sum.steps or {}) do
		if not s.node then return nil end
		local span = (s.to or 0) - (s.from or 0)
		local cur = tree.layout[s.node] and tree.layout[s.node].rank or -1
		total = total + span
		done = done + math.max(0, math.min(span, cur - (s.from or 0)))
	end
	return done, total
end

--- Plan payoff for a profession, in a line: this character's saved plan, its gold a day now and once
--- finished, and how many of its points are in.
function PUI.PayoffLine(prof)
	local T, M = CH.Theme, CH.FormatMoney
	local me = CH.Me and CH.Me() or {}
	local sum
	for _, s in pairs(CH.db.plans or {}) do
		if s.prof == prof and (not sum or s.char == me.name) then sum = s end
	end
	local name = CH.SpecData and CH.SpecData[prof] and CH.SpecData[prof].name or "this profession"
	if not sum then return T.Color("accent", "Plan payoff  ") .. T.Color("muted", "No saved plan for " .. name .. " yet. Plan below and it shows here.") end
	local gain = (sum.final or 0) - (sum.start or 0)
	local t = T.Color("accent", "Plan payoff  ") .. string.format("%s, %d points: %s to %s a day ", sum.label or "?", sum.budget or 0, M(sum.start or 0), M(sum.final or 0))
		.. T.Color(gain >= 0 and "ok" or "bad", string.format("(%s%s)", gain >= 0 and "+" or "", M(gain)))
	local done, total = PUI.PlanProgress(sum, CH.Spec.Tree(prof))
	if done and total > 0 then
		t = t .. (done >= total and T.Color("ok", ". Done.") or string.format(". %d of %d points in.", done, total))
	end
	return t
end

--- Fill the page: the goal groups, the points and the tree. The main window calls it when the
--- page shows.
function PUI.Refresh()
	if not frame then return {} end
	fillGoals()
	fillProfessions()
	updatePoints()
	local prof = PUI.Prof()
	frame.kpText:SetText(prof and PUI.KnowledgeLine(prof) or "")
	frame.payText:SetText(prof and PUI.PayoffLine(prof) or "")
	frame.byRecipe:SetShown(prof ~= nil)
	if not PUI.Prof() then
		render({ CH.Theme.Color("muted", "No crafting profession with a specialization tree on this character.") })
	elseif not canPlan() then
		if not lastPlan then render({ CH.Theme.Color("muted", "The tree shows where your knowledge points are now. To plan where the next ones go, open this profession and pick what you want to sell.") }) end
	elseif not lastPlan then
		render({ CH.Theme.Color("muted", "Pick a group above (some open a menu, like Light or Void potions) or type what you want to sell and press Plan. Points start at what finishing that path takes; change them with -5 and +5.") })
	end
	return PUI.DrawTree()
end

--- What the page says under the tree, for tests.
function PUI.Text() return out and out:GetText() or "" end

function PUI.IsShown() return frame ~= nil and frame:IsShown() and CH.UI.IsShown() end

local function changed()
	if PUI.IsShown() then PUI.DrawTree() end
	if CH.SpecOverlay then CH.SpecOverlay.Refresh() end
end
CH.Paths.Changed = changed
CH.On("TRAIT_NODE_CHANGED", function() C_Timer.After(0.2, changed) end)
