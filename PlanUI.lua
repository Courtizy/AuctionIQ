-- Plan page of the main window: the weekly knowledge checklist for every character and profession,
-- what's coming up, and time spent goldmaking with gold per hour.
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
	local th = fs(tm, 10, -8, 600, "LEFT", "GameFontNormal"); th:SetText("Time spent goldmaking")
	p.time = fs(tm, 10, -30, 876, "LEFT")
	p.time:SetJustifyV("TOP")
	if p.time.SetMaxLines then p.time:SetMaxLines(8) end
end

local function fmtHours(h) return h >= 1 and string.format("%.1f h", h) or string.format("%d min", math.floor(h * 60 + 0.5)) end

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
	p.upcoming:SetText(#lines > 0 and table.concat(lines, "\n") or T.Color("muted", "Nothing in the game calendar. Add your own: /ch event 2026-12-01 Season 2 starts"))
	local out = {}
	for _, span in ipairs({ { "Last 7 days", 7 }, { "Last 30 days", 30 } }) do
		local x = Pl.Time(time() - span[2] * 86400)
		local parts = {}
		for k, h in pairs(x.kinds) do table.insert(parts, k .. " " .. fmtHours(h)) end
		table.sort(parts)
		table.insert(out, T.Color("accent", span[1]) .. "  " .. (x.hours > 0 and (fmtHours(x.hours) .. ": " .. table.concat(parts, ", ")) or "no sessions yet")
			.. (x.perHour and ("   " .. T.Color(x.perHour >= 0 and "ok" or "bad", CH.FormatMoney(x.perHour) .. " an hour")) or ""))
	end
	table.insert(out, T.Color("muted", "Time counts while the AH, mailbox or a profession window is open. Gold an hour is cash profit after overhead over that time, so heavy reagent buying shows as negative until the stock sells."))
	p.time:SetText(table.concat(out, "\n"))
	return rows
end
