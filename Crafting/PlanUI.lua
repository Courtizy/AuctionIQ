-- Research, Professions: the weekly knowledge checklist for every character and profession,
-- what's coming up, best crafts and Concentration, and buttons for the crafting windows (Paths
-- plans knowledge trees; the advisor stays docked to the profession window). It sits right of
-- Research's nav, 724 wide.
local _, CH = ...

local PUI = {}
CH.PlanUI = PUI
local page
local ROWS, TASKS = 14, 4

function PUI.Build(p, fs, panel)
	local T = CH.Theme
	page = p
	local kp = panel(p, 0, 0, 476, 330)
	local h = fs(kp, 10, -8, 456, "LEFT", "GameFontNormal")
	h:SetText("Knowledge this week" .. T.Color("muted", "  tick what's done; clears at the reset"))
	p.heads = {}
	for j, c in ipairs({ { "Character", 10, 86 }, { "Profession", 98, 110 }, { "Gained", 210, 48 }, { "Unspent", 260, 50 } }) do
		local f = fs(kp, c[2], -30, c[3], j <= 2 and "LEFT" or "RIGHT", "GameFontNormalSmall"); f:SetText(c[1])
	end
	p.taskHeads = {}
	for t = 1, TASKS do p.taskHeads[t] = fs(kp, 314 + (t - 1) * 40, -30, 40, "CENTER", "GameFontNormalSmall") end
	p.rows = {}
	for i = 1, ROWS do
		local y = -48 - (i - 1) * 19
		local r = { cells = {}, ticks = {} }
		r.cells[1] = fs(kp, 10, y, 86); r.cells[2] = fs(kp, 98, y, 110)
		r.cells[3] = fs(kp, 210, y, 48, "RIGHT"); r.cells[4] = fs(kp, 260, y, 50, "RIGHT")
		for t = 1, TASKS do
			local b = T.Button(kp, "", 36, 16)
			b:SetPoint("TOPLEFT", 316 + (t - 1) * 40, y + 2)
			b:SetScript("OnClick", function(self) if self.k then CH.Planner.Tick(self.k[1], self.k[2], self.k[3]); CH.UI.Refresh() end end)
			r.ticks[t] = b
		end
		p.rows[i] = r
	end
	local up = panel(p, 484, 0, 240, 330)
	local uh = fs(up, 10, -8, 220, "LEFT", "GameFontNormal"); uh:SetText("Coming up" .. T.Color("muted", "  next 14 days"))
	p.upcoming = fs(up, 10, -30, 220, "LEFT")
	p.upcoming:SetJustifyV("TOP")
	if p.upcoming.SetMaxLines then p.upcoming:SetMaxLines(16) end
	local tm = panel(p, 0, -340, 724, 144)
	local scroll = CreateFrame("ScrollFrame", nil, tm)
	scroll:SetPoint("TOPLEFT", 10, -8)
	scroll:SetPoint("BOTTOMRIGHT", -10, 6)
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		self:SetVerticalScroll(math.max(0, math.min(self:GetVerticalScrollRange(), self:GetVerticalScroll() - delta * 30)))
	end)
	local child = CreateFrame("Frame", nil, scroll)
	child:SetSize(704, 10)
	scroll:SetScrollChild(child)
	p.crafts = child:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	p.crafts:SetPoint("TOPLEFT")
	p.crafts:SetWidth(704)
	p.crafts:SetJustifyH("LEFT")
	p.crafts:SetSpacing(3)
	-- the crafting windows
	local x = 0
	for _, b in ipairs({ { "Scan recipes", function() CH.ScanUI.Toggle() end, "Rank every recipe of the open profession" },
		{ "Paths", function() CH.PathsUI.Toggle() end, "Plan knowledge points for what you want to sell" },
		{ "Queue and shopping", function() CH.QueueUI.Toggle() end, "The craft queue and what to buy for it" },
		{ "Results", function() CH.LogUI.Open() end, "What your crafts really gave, in Performance" },
		{ "Advisor on/off", function() CH.AdvisorUI.ToggleSetting() end, "The advisor docked to the profession window" } }) do
		local w = b[1]:len() * 7 + 24
		local btn = T.Button(p, b[1], w, 20)
		btn:SetPoint("TOPLEFT", x, -494)
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
	for t = 1, TASKS do p.taskHeads[t]:SetText(tasks[t] and tasks[t]:sub(1, 6) or "") end
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

-- Plan comparison: each saved knowledge plan (made in Paths), recipe by recipe, now against planned
local function q(x, share)
	if share then return string.format("%d%%", math.floor(share * 100 + 0.5)) end
	return x and ("Q" .. x) or "-"
end

local function planRows(ctx)
	local T, LUI = CH.Theme, CH.LedgerUI
	local out, notes = {}, {}
	for _, sum in pairs(CH.db.plans or {}) do
		local gain = (sum.final or 0) - (sum.start or 0)
		table.insert(notes, string.format("%s %s (%s, %d points): %s to %s a day", sum.char or "?", sum.profName or "?", sum.label or "?",
			sum.budget or 0, CH.FormatMoney(sum.start or 0), CH.FormatMoney(sum.final or 0)) .. T.Color(gain >= 0 and "ok" or "bad", string.format(" (%s%s)", gain >= 0 and "+" or "", CH.FormatMoney(gain))))
		for _, r in ipairs(sum.rows or {}) do
			if ctx.keepName(r.name) then
				local dDay = (r.toDay or 0) - (r.fromDay or 0)
				local qual = q(r.fromQ, r.fromShare) .. " > " .. q(r.toQ, r.toShare)
				if (r.toQ or 0) > (r.fromQ or 0) then qual = T.Color("ok", qual) end
				table.insert(out, { id = r.id, cells = { r.name or "?", sum.profName or "?", qual, r.fromProfit and LUI.Signed(r.fromProfit) or "-",
					r.toProfit and LUI.Signed(r.toProfit) or "-", CH.FormatMoney(r.fromDay or 0), CH.FormatMoney(r.toDay or 0),
					T.Color(dDay > 0 and "ok" or dDay < 0 and "bad" or "muted", (dDay > 0 and "+" or "") .. CH.FormatMoney(dDay)) },
					sort = { r.name or "", sum.profName or "", (r.toQ or 0) - (r.fromQ or 0), r.fromProfit or 0, r.toProfit or 0, r.fromDay or 0, r.toDay or 0, dDay } })
			end
		end
	end
	if not notes[1] then
		return out, T.Color("muted", "No plans yet. Open a profession, then Paths, and plan for what you sell: it shows up here, current against planned.")
	end
	table.sort(notes)
	return out, table.concat(notes, "   ") .. T.Color("muted", "   Estimated from your scans. Spend points in the game's Specializations panel.")
end

-- Research, Professions: this page beside the nav, and the plan comparison
CH.LedgerUI.Register("research", {
	professions = { label = "Knowledge", page = "plan", noTime = true, cols = {} },
	plans = { label = "Plan comparison", sort = 8, noTime = true, rows = planRows, cols = { { "Recipe", 0, 196 }, { "Profession", 200, 84 },
		{ "Quality", 288, 64 }, { "Profit now", 356, 80 }, { "Planned", 440, 80 }, { "A day now", 524, 64 }, { "Planned", 592, 64 },
		{ "Change", 660, 64 } } },
}, { "professions", "plans" }, "Professions")
