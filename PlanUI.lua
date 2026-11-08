-- Crafting tab of the main window: the weekly knowledge checklist for every character and
-- profession, what's coming up, best crafts and Concentration, and buttons for the crafting windows
-- (the advisor stays docked to the profession window). Gold per hour moved to Analytics.
local _, CH = ...

local PUI = {}
CH.PlanUI = PUI
local page
local ROWS, TASKS = 14, 4

function PUI.Build(p, fs, panel)
	local T = CH.Theme
	page = p
	local kp = panel(p, 0, 0, 560, 330)
	local h = fs(kp, 10, -8, 540, "LEFT", "GameFontNormal")
	h:SetText("Knowledge this week" .. T.Color("muted", "  tick what you've done; it clears at the weekly reset"))
	p.heads = {}
	for j, c in ipairs({ { "Character", 10, 90 }, { "Profession", 102, 130 }, { "Gained", 234, 50 }, { "Unspent", 286, 54 } }) do
		local f = fs(kp, c[2], -30, c[3], j <= 2 and "LEFT" or "RIGHT", "GameFontNormalSmall"); f:SetText(c[1])
	end
	p.taskHeads = {}
	for t = 1, TASKS do p.taskHeads[t] = fs(kp, 346 + (t - 1) * 52, -30, 50, "CENTER", "GameFontNormalSmall") end
	p.rows = {}
	for i = 1, ROWS do
		local y = -48 - (i - 1) * 19
		local r = { cells = {}, ticks = {} }
		r.cells[1] = fs(kp, 10, y, 90); r.cells[2] = fs(kp, 102, y, 130)
		r.cells[3] = fs(kp, 234, y, 50, "RIGHT"); r.cells[4] = fs(kp, 286, y, 54, "RIGHT")
		for t = 1, TASKS do
			local b = T.Button(kp, "", 46, 16)
			b:SetPoint("TOPLEFT", 348 + (t - 1) * 52, y + 2)
			b:SetScript("OnClick", function(self) if self.k then CH.Planner.Tick(self.k[1], self.k[2], self.k[3]); CH.UI.Refresh() end end)
			r.ticks[t] = b
		end
		p.rows[i] = r
	end
	local up = panel(p, 572, 0, 324, 330)
	local uh = fs(up, 10, -8, 300, "LEFT", "GameFontNormal"); uh:SetText("Coming up" .. T.Color("muted", "  next 14 days"))
	p.upcoming = fs(up, 10, -30, 304, "LEFT")
	p.upcoming:SetJustifyV("TOP")
	if p.upcoming.SetMaxLines then p.upcoming:SetMaxLines(16) end
	local tm = panel(p, 0, -342, 896, 168)
	local scroll = CreateFrame("ScrollFrame", nil, tm)
	scroll:SetPoint("TOPLEFT", 10, -8)
	scroll:SetPoint("BOTTOMRIGHT", -10, 6)
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		self:SetVerticalScroll(math.max(0, math.min(self:GetVerticalScrollRange(), self:GetVerticalScroll() - delta * 30)))
	end)
	local child = CreateFrame("Frame", nil, scroll)
	child:SetSize(876, 10)
	scroll:SetScrollChild(child)
	p.crafts = child:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	p.crafts:SetPoint("TOPLEFT")
	p.crafts:SetWidth(876)
	p.crafts:SetJustifyH("LEFT")
	p.crafts:SetSpacing(3)
	-- the crafting windows
	local x = 0
	for _, b in ipairs({ { "Scan recipes", function() CH.ScanUI.Toggle() end, "Rank every recipe of the open profession" },
		{ "Paths", function() CH.PathsUI.Toggle() end, "Plan knowledge points for what you want to sell" },
		{ "Queue and shopping", function() CH.QueueUI.Toggle() end, "The craft queue and what to buy for it" },
		{ "Results", function() CH.LogUI.Toggle() end, "What your crafts really gave" },
		{ "Advisor on/off", function() CH.AdvisorUI.ToggleSetting() end, "The advisor docked to the profession window" } }) do
		local w = b[1]:len() * 7 + 24
		local btn = T.Button(p, b[1], w, 20)
		btn:SetPoint("TOPLEFT", x, -518)
		btn:SetScript("OnClick", b[2])
		btn:SetScript("OnEnter", function(self) CH.Window.Tooltip(self, { { b[3] } }) end)
		btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
		x = x + w + 6
	end
end

function PUI.Refresh()
	local p = page
	if not p then return {} end
	local T, Pl = CH.Theme, CH.Planner
	pcall(Pl.RecordKP)
	local tasks = Pl.Store().tasks
	for t = 1, TASKS do p.taskHeads[t]:SetText(tasks[t] and tasks[t]:sub(1, 8) or "") end
	local rows = Pl.Knowledge()
	for i, r in ipairs(p.rows) do
		local d = rows[i]
		r.cells[1]:SetText(d and d.char or ""); r.cells[2]:SetText(d and d.prof or "")
		r.cells[3]:SetText(d and (d.gained > 0 and T.Color("ok", "+" .. d.gained) or "0") or "")
		r.cells[4]:SetText(d and (d.unspent > 0 and T.Color("accent", d.unspent) or "0") or "")
		for t, b in ipairs(r.ticks) do
			local task = d and d.tasks[t]
			if task then
				b.k = { d.key, d.prof, task.name }
				if b.text then b.text:SetText(task.done and T.Color("ok", "done") or T.Color("muted", "-")) end
				b:Show()
			else
				b.k = nil; b:Hide()
			end
		end
	end
	local lines = {}
	for _, e in ipairs(Pl.Upcoming()) do
		table.insert(lines, T.Color("accent", e.date:sub(6)) .. "  " .. e.name .. (e.hint and T.Color("muted", "\n      " .. e.hint) or ""))
	end
	p.upcoming:SetText(#lines > 0 and table.concat(lines, "\n") or T.Color("muted", "Nothing in the game calendar. Add your own: /aiq event 2026-12-01 Season 2 starts"))
	p.crafts:SetText(CH.UI.CraftingText())
	p.crafts:GetParent():SetHeight(p.crafts:GetStringHeight() + 10)
	return rows
end
