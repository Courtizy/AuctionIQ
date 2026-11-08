-- Marks the knowledge point plan on the game's own Specializations tab: a gold badge on each node
-- the plan raises, with its step numbers and the rank it goes to. The badges sit on Blizzard's node
-- buttons, and are redrawn when the tab or the tree changes. Only reads the game's frames, so it
-- can't break spending points; if Blizzard changes the frame, the badges just don't show.
local _, CH = ...

local SO = {}
CH.SpecOverlay = SO
local badges = {} -- [node button] = badge
local hooked

local function page() return ProfessionsFrame and ProfessionsFrame.SpecPage end

local function badgeFor(button)
	local b = badges[button]
	if b then return b end
	local T = CH.Theme
	b = CreateFrame("Frame", nil, button, "BackdropTemplate")
	if b.SetFrameLevel and button.GetFrameLevel then b:SetFrameLevel((button:GetFrameLevel() or 1) + 10) end
	b:SetSize(20, 15)
	b:SetPoint("CENTER", button, "TOPRIGHT", -4, -4)
	T.Panel(b, "panel", 1)
	if b.SetBackdropColor then b:SetBackdropColor(T.accent[1], T.accent[2], T.accent[3], 1) end
	b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	b.text:SetPoint("CENTER", 0, 0)
	b.text:SetTextColor(T.bg[1], T.bg[2], T.bg[3])
	b.to = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	b.to:SetPoint("TOP", button, "BOTTOM", 0, -1)
	b.to:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
	badges[button] = b
	return b
end

--- Redraw the badges for the open profession's current plan. Returns how many it placed.
function SO.Refresh()
	for _, b in pairs(badges) do b:Hide() end
	local sp = page()
	if not sp or not sp:IsShown() or not sp.GetTalentButtonByNodeID then return 0 end
	local prof = CH.OpenProfessionID()
	local plan = CH.Paths.Current(prof)
	if not plan then return 0 end
	local tree = CH.Spec.Tree(prof)
	local n = 0
	for nodeID, m in pairs(CH.Paths.Marks(plan)) do
		local ok, button = pcall(sp.GetTalentButtonByNodeID, sp, nodeID)
		local node = tree and tree.layout and tree.layout[nodeID]
		if ok and button and button:IsShown() and (not node or m.to > (node.rank or -1)) then
			local b = badgeFor(button)
			local t = CH.TreeView.StepText(m.steps)
			b.text:SetText(t)
			b:SetWidth(math.max(18, 8 + 6 * #t))
			b.to:SetText("> " .. m.to)
			b:Show()
			n = n + 1
		end
	end
	return n
end

local function later() C_Timer.After(0, SO.Refresh) end

local function hook()
	if hooked then return end
	local sp = page()
	if not sp then return end
	hooked = true
	if sp.HookScript then sp:HookScript("OnShow", later) end
	for _, fn in ipairs({ "SetSelectedTab", "LoadTalentTreeInternal", "UpdateTreeCurrencyInfo" }) do
		if type(sp[fn]) == "function" then hooksecurefunc(sp, fn, later) end
	end
end

CH.On("TRADE_SKILL_SHOW", function() hook(); later() end)
