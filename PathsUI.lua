-- Paths window: type what you want to sell, get a knowledge point plan for the open profession,
-- then try it in the crafting advisor (simulation) before spending a point.
local _, CH = ...

local PUI = {}
CH.PathsUI = PUI
local frame, input, out, pointsText, goalButtons
local W, H = 520, 470
local extra = 0
local lastPlan

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

function PUI.Run(goal)
	if not frame then PUI.Toggle() end
	goal = goal or (input and input:GetText()) or ""
	render({ CH.Theme.Color("accent", "Working out a plan for \"" .. goal .. "\" ...") })
	local plan, why = CH.Paths.Plan({ goal = goal, points = extra, onDone = function(p)
		lastPlan = p
		if p.error then render({ CH.Theme.Color("bad", "Couldn't finish the plan: " .. tostring(p.error)) }) else render(p.text) end
		PUI.simButton:SetEnabled(p.ranks ~= nil)
	end })
	if not plan then render({ CH.Theme.Color("muted", why) }) end
end

local function build()
	local T, Wd = CH.Theme, CH.Window
	frame = Wd.New("ClearinghousePaths", "Profession paths", W, H)
	local ask = Wd.Text(frame, 12, -36, W - 24, "LEFT", "GameFontNormal")
	ask:SetText("What do you want to sell?")
	input = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	input:SetSize(W - 120, 20)
	input:SetPoint("TOPLEFT", 18, -56)
	input:SetAutoFocus(false)
	input:SetText("potions")
	input:SetScript("OnEnterPressed", function(self) self:ClearFocus(); PUI.Run() end)
	local go = T.Button(frame, "Plan", 70, 20)
	go:SetPoint("TOPRIGHT", -14, -56)
	go:SetScript("OnClick", function() PUI.Run() end)

	goalButtons = {}
	for i = 1, 5 do
		local b = T.Button(frame, "", 94, 18)
		b:SetPoint("TOPLEFT", 12 + (i - 1) * 99, -84)
		b:Hide()
		goalButtons[i] = b
	end

	pointsText = Wd.Text(frame, 12, -112, 300)
	local minus = T.Button(frame, "-5", 30, 18)
	minus:SetPoint("TOPLEFT", 320, -108)
	minus:SetScript("OnClick", function() extra = math.max(0, extra - 5); updatePoints() end)
	local plus = T.Button(frame, "+5", 30, 18)
	plus:SetPoint("TOPLEFT", 354, -108)
	plus:SetScript("OnClick", function() extra = extra + 5; updatePoints() end)
	PUI.simButton = T.Button(frame, "Simulate", 100, 18)
	PUI.simButton:SetPoint("TOPRIGHT", -14, -108)
	PUI.simButton:SetEnabled(false)
	PUI.simButton:SetScript("OnClick", function()
		if lastPlan and lastPlan.ranks then CH.AdvisorUI.SetPlan(lastPlan) end
	end)
	PUI.simButton:SetScript("OnEnter", function(self)
		CH.Window.Tooltip(self, { { "Show the crafting advisor's numbers as if you'd spent these points. Turn it off from the advisor's Sim bar." } })
	end)
	PUI.simButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

	local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 12, -136)
	scroll:SetPoint("BOTTOMRIGHT", -30, 12)
	local child = CreateFrame("Frame", nil, scroll)
	child:SetSize(W - 44, 10)
	scroll:SetScrollChild(child)
	frame.child = child
	out = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	out:SetPoint("TOPLEFT")
	out:SetWidth(W - 48)
	out:SetJustifyH("LEFT")
	out:SetSpacing(3)
	T.Fonts(frame)
end

local function fillGoals()
	local goals = CH.OpenProfessionID() and CH.Paths.Goals() or {}
	for i, b in ipairs(goalButtons) do
		local g = goals[i]
		if g then
			local label = g.name
			if b.text then b.text:SetText(label) elseif b.SetText then b:SetText(label) end
			b:SetScript("OnClick", function() input:SetText(label); PUI.Run(label) end)
			b:Show()
		else
			b:Hide()
		end
	end
end

function PUI.Toggle()
	if not frame then build() end
	if frame:IsShown() then frame:Hide(); return end
	frame:Show()
	updatePoints()
	fillGoals()
	if not CH.OpenProfessionID() then
		render({ CH.Theme.Color("muted", "Open the profession you want a plan for (Alchemy, Enchanting, Jewelcrafting or Inscription), then type a goal like \"potions\" or \"gems\".") })
	elseif not lastPlan then
		render({ CH.Theme.Color("muted", "Type what you want to sell, or pick a category, and press Plan. Points are planned for the open profession on this character.") })
	end
end

function PUI.IsShown() return frame ~= nil and frame:IsShown() end
