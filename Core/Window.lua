-- Shared window parts for the scan, queue and results windows: a themed, draggable panel with a
-- title bar, and a table of rows with hover and click.
local _, CH = ...

local W = {}
CH.Window = W

--- A movable panel with the AuctionIQ title bar. Returns the frame; frame.bar holds buttons,
--- frame.title the title text, frame.close the close button.
function W.New(name, title, width, height)
	local T = CH.Theme
	T.Sync()
	local f = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
	T.Panel(f, "bg", 0.95)
	f:SetSize(width, height)
	f:SetFrameStrata("HIGH")
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetPoint("CENTER")
	f:Hide()
	table.insert(UISpecialFrames, name)

	local bar = CreateFrame("Frame", nil, f, "BackdropTemplate")
	T.Panel(bar, "panel", 1)
	bar:SetPoint("TOPLEFT")
	bar:SetPoint("TOPRIGHT")
	bar:SetHeight(26)
	local rule = bar:CreateTexture(nil, "ARTWORK")
	rule:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 1)
	rule:SetPoint("BOTTOMLEFT", 1, 0)
	rule:SetPoint("BOTTOMRIGHT", -1, 0)
	rule:SetHeight(1)
	local badge = bar:CreateTexture(nil, "ARTWORK")
	badge:SetTexture(CH.ICON)
	badge:SetSize(20, 20) -- a little larger than the 14px tab symbols
	badge:SetPoint("LEFT", 4, 0)
	f.title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.title:SetPoint("LEFT", badge, "RIGHT", 6, 0)
	f.title:SetText(T.Color("accent", "AuctionIQ") .. "  " .. T.Color("muted", title))
	f.close = T.Button(bar, "x", 18, 18)
	f.close:SetPoint("RIGHT", -4, 0)
	f.close:SetScript("OnClick", function() f:Hide() end)
	f.bar = bar
	return f
end

--- Keep a font string to one line: long text is cut with "..." instead of wrapping onto the row below.
function W.OneLine(fs)
	if fs.SetWordWrap then fs:SetWordWrap(false) end
	if fs.SetNonSpaceWrap then fs:SetNonSpaceWrap(false) end
	if fs.SetMaxLines then fs:SetMaxLines(1) end
	return fs
end

--- A line of text at x, y inside a frame.
function W.Text(parent, x, y, w, justify, template)
	local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetWidth(w)
	fs:SetJustifyH(justify or "LEFT")
	return fs
end

--- A table: cols = { { label, x, width, justify } }, n rows of height h from y. onClick(i, button)
--- and onEnter(owner, i, col) are optional. Returns rows, each { cells = {fs...}, bg }.
function W.Table(parent, cols, n, y, h, onClick, onEnter, width)
	local T = CH.Theme
	for _, c in ipairs(cols) do
		local fs = W.OneLine(W.Text(parent, c[2], y, c[3], c[4] or (c[2] <= 12 and "LEFT" or "RIGHT"), "GameFontDisableSmall"))
		fs:SetText(c[1])
		fs:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
	end
	local rows = {}
	for i = 1, n do
		local ry = y - i * h
		local r = { cells = {} }
		r.bg = parent:CreateTexture(nil, "BACKGROUND")
		r.bg:SetPoint("TOPLEFT", 6, ry + 3)
		r.bg:SetSize((width or parent:GetWidth()) - 12, h)
		r.bg:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 0.12)
		r.bg:Hide()
		for j, c in ipairs(cols) do
			r.cells[j] = W.OneLine(W.Text(parent, c[2], ry, c[3], c[4] or (j == 1 and "LEFT" or "RIGHT")))
		end
		if onClick or onEnter then
			local b = CreateFrame("Button", nil, parent)
			b:SetPoint("TOPLEFT", 6, ry + 3)
			b:SetSize((width or parent:GetWidth()) - 12, h)
			if b.RegisterForClicks then b:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
			if onClick then b:SetScript("OnClick", function(_, button) onClick(i, button) end) end
			if onEnter then
				b:SetScript("OnEnter", function(self) onEnter(self, i) end)
				b:SetScript("OnLeave", function() GameTooltip:Hide() end)
			end
			r.button = b
		end
		rows[i] = r
	end
	return rows
end

--- Scroll a list with the mouse wheel over frame: get() and set(n) hold the offset, total() the
--- row count and n the rows shown; refresh() redraws.
--- With bar (from W.ScrollBar), the wheel also moves it.
function W.Wheel(frame, n, get, set, total, refresh, bar)
	frame:EnableMouseWheel(true)
	frame:SetScript("OnMouseWheel", function(_, d)
		local t = total()
		set(math.max(0, math.min(math.max(0, t - n), get() - d * 3)))
		refresh()
		if bar then bar:Set(get(), n, t) end
	end)
end

--- A visible scroll position for a list: a thin track and thumb at x (from the parent's left) down
--- from y for h pixels, and a "1-17 of 83" count under it, right-aligned to the track. bar:Set(offset,
--- shown, total) after each redraw; both hide when everything fits. noCount leaves out the count
--- (for lists that already say it in their heading).
function W.ScrollBar(parent, x, y, h, noCount)
	local T = CH.Theme
	local bar = {}
	local track = parent:CreateTexture(nil, "ARTWORK")
	track:SetPoint("TOPLEFT", x, y)
	track:SetSize(4, h)
	track:SetColorTexture(T.muted[1], T.muted[2], T.muted[3], 0.25)
	local thumb = parent:CreateTexture(nil, "OVERLAY")
	thumb:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 0.8)
	thumb:SetSize(4, h)
	local count = noCount and { SetText = function() end } or W.OneLine(W.Text(parent, x - 116, y - h - 2, 120, "RIGHT", "GameFontDisableSmall"))
	bar.track, bar.thumb, bar.count = track, thumb, count
	--- A new length for the bar (the table it scrolls got more or fewer rows).
	function bar:SetLength(nh)
		h = nh
		track:SetSize(4, nh)
		if count.ClearAllPoints then count:ClearAllPoints(); count:SetPoint("TOPLEFT", x - 116, y - nh - 2) end
	end
	function bar:Set(offset, shown, total)
		offset, shown, total = offset or 0, shown or 0, total or 0
		local scrolls = total > shown
		track:SetShown(scrolls)
		thumb:SetShown(scrolls)
		if not scrolls then count:SetText(""); bar.text = nil; return end
		local th = math.max(12, h * shown / total)
		local room = h - th
		local at = total > shown and room * offset / (total - shown) or 0
		thumb:ClearAllPoints()
		thumb:SetPoint("TOPLEFT", x, y - at)
		thumb:SetHeight(th)
		bar.text = string.format("%d-%d of %d", offset + 1, math.min(total, offset + shown), total)
		count:SetText(bar.text)
	end
	return bar
end

--- Show tooltip lines ({left, right} or {left}) on owner.
function W.Tooltip(owner, lines)
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	for _, l in ipairs(lines) do
		if l[2] then GameTooltip:AddDoubleLine(l[1], l[2], 1, 1, 1, 1, 1, 1) else GameTooltip:AddLine(l[1], 1, 1, 1, true) end
	end
	GameTooltip:Show()
end

--- An item's icon, inline in text. The game has every item icon loaded, so this is cheap.
function W.ItemIcon(itemID, size)
	local icon = itemID and C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)
	if not icon then return "" end
	size = size or 16
	return "|T" .. icon .. ":" .. size .. ":" .. size .. ":0:0:64:64:5:59:5:59|t "
end

--- Quality icon. tiers is how many qualities the item has: Midnight's two-quality items and
--- reagents use their own icons (the ones in their chat links), older ones the five-tier set.
function W.QualityIcon(q, size, tiers)
	if not q then return "" end
	if not CreateAtlasMarkup then return "Q" .. q end
	size = size or 16
	if tiers == 2 then
		return CreateAtlasMarkup("Professions-ChatIcon-Quality-12-Tier" .. q, math.floor(size * 17 / 15 + 0.5), size)
	end
	return CreateAtlasMarkup("Professions-Icon-Quality-Tier" .. q .. "-Small", size, size)
end

-- Tabs ----------------------------------------------------------------------------------------
-- The advisor, scan, queue and results windows share one spot: beside the profession window
-- (docked), or wherever you last dragged one of them. A row of tabs sits under the one showing, and
-- opening one hides the others, so they never pile up. The queue can be popped out of the tabs to sit
-- under them, so the plan and the shopping list show together.
local tabs, byKey = {}, {}
local active, strip, switching

local function deck() return CH.db.settings.advisor end -- docked, point: shared with the advisor's old settings
local function ws() return CH.db.settings.window end

--- Register a tab. open() shows its window, building it if needed.
function W.AddTab(key, label, open, tip)
	local t = { key = key, label = label, open = open, tip = tip }
	table.insert(tabs, t)
	byKey[key] = t
	return t
end

--- Is this window one of the tabs right now (the queue isn't, when popped out)?
function W.InTabs(key)
	if key == "queue" then return not ws().popQueue end
	return byKey[key] ~= nil
end

--- The tab showing, if any.
function W.Active()
	return active and active.frame and active.frame:IsShown() and active.key or nil
end

--- True when another tab is showing, so a window that updates itself (the advisor, on each recipe
--- click) shouldn't jump in front of it.
function W.Busy(key)
	local a = W.Active()
	return a ~= nil and a ~= key
end

local function profOpen() return ProfessionsFrame and ProfessionsFrame:IsShown() end

--- Put a tab window in the shared spot.
function W.Place(f)
	local s = deck()
	f:ClearAllPoints()
	if s.docked ~= false and profOpen() then
		f:SetPoint("TOPLEFT", ProfessionsFrame, "TOPRIGHT", 2, 0)
	elseif s.point then
		f:SetPoint(s.point[1], UIParent, s.point[3], s.point[4], s.point[5])
	else
		f:SetPoint("CENTER", 0, 60)
	end
end

local function colorTab(b, on)
	local T = CH.Theme
	local fs = b.text or (b.GetFontString and b:GetFontString())
	local c = on and T.accent or T.muted
	if fs and fs.SetTextColor then fs:SetTextColor(c[1], c[2], c[3]) end
	if b.SetBackdropBorderColor then
		local l = on and T.accent or T.line
		b:SetBackdropBorderColor(l[1], l[2], l[3], 1)
	end
end

local function buildStrip()
	local T = CH.Theme
	strip = CreateFrame("Frame", "AuctionIQTabs", UIParent)
	strip:SetFrameStrata("HIGH")
	strip:SetSize(10, 22)
	strip:Hide()
	strip.buttons = {}
	for i, t in ipairs(tabs) do
		local b = T.Button(strip, t.label, 74, 22)
		b:SetScript("OnClick", function() t.open() end)
		b:SetScript("OnEnter", function(self)
			if t.tip then W.Tooltip(self, { { t.tip } }) end
		end)
		b:SetScript("OnLeave", function(self) GameTooltip:Hide(); colorTab(self, active == t) end)
		strip.buttons[i] = b
	end
	strip.dock = T.Button(strip, "Dock", 50, 22)
	strip.dock:SetScript("OnClick", function() deck().docked = true; deck().point = nil; W.Arrange() end)
	strip.dock:SetScript("OnEnter", function(self) W.Tooltip(self, { { "Put the window back beside the profession window." } }) end)
	strip.dock:SetScript("OnLeave", function() GameTooltip:Hide() end)
	T.Fonts(strip)
end

--- Lay the windows out: the active tab in the shared spot, the tab row under it, a popped-out queue
--- under that. Returns the labels of the tabs shown, for tests.
function W.Arrange()
	if active and not W.InTabs(active.key) then active = nil end
	local f = active and active.frame
	local labels = {}
	if f and f:IsShown() then
		W.Place(f)
		if not strip then buildStrip() end
		strip:ClearAllPoints()
		strip:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -1)
		local x = 0
		for i, t in ipairs(tabs) do
			local b = strip.buttons[i]
			local show = W.InTabs(t.key)
			b:SetShown(show)
			if show then
				b:ClearAllPoints()
				b:SetPoint("TOPLEFT", x, 0)
				x = x + 76
				colorTab(b, t == active)
				table.insert(labels, t.label)
			end
		end
		local undocked = deck().docked == false and ProfessionsFrame ~= nil
		strip.dock:SetShown(undocked)
		if undocked then strip.dock:ClearAllPoints(); strip.dock:SetPoint("TOPLEFT", x + 8, 0); x = x + 58 end
		strip:SetWidth(math.max(10, x))
		strip:Show()
	elseif strip then
		strip:Hide()
	end
	local q = byKey.queue and byKey.queue.frame
	if q and q:IsShown() and not W.InTabs("queue") then
		local p = ws().queuePoint
		q:ClearAllPoints()
		if p then
			q:SetPoint(p[1], UIParent, p[3], p[4], p[5])
		elseif strip and strip:IsShown() then
			q:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", 0, -4)
		else
			q:SetPoint("CENTER", 0, 80)
		end
	end
	return labels
end

--- Hand a built window to its tab: it takes the shared spot, hides the other tabs when it opens,
--- and dragging it moves them all.
function W.Attach(key, f)
	local t = byKey[key]
	t.frame = f
	f:SetScript("OnDragStart", function(self)
		if key == "queue" and not W.InTabs("queue") then self:StartMoving(); return end
		deck().docked = false
		self:StartMoving()
	end)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local p, _, rp, x, y = self:GetPoint()
		if key == "queue" and not W.InTabs("queue") then
			ws().queuePoint = { p, nil, rp, x, y }
		else
			deck().point = { p, nil, rp, x, y }
		end
		W.Arrange()
	end)
	f:HookScript("OnShow", function()
		if W.InTabs(key) then
			switching = true
			for _, o in ipairs(tabs) do
				if o ~= t and o.frame and o.frame:IsShown() and W.InTabs(o.key) then o.frame:Hide() end
			end
			switching = false
			active = t
		end
		W.Arrange()
	end)
	f:HookScript("OnHide", function()
		if switching then return end
		if active == t then active = nil end
		W.Arrange()
	end)
end

--- Close every tab (and the popped queue when it sits under them), as when the profession window
--- they were docked to closes.
function W.CloseTabs()
	local hadStrip = strip and strip:IsShown()
	for _, t in ipairs(tabs) do
		local f = t.frame
		if f and f:IsShown() and (W.InTabs(t.key) or (hadStrip and not ws().queuePoint)) then f:Hide() end
	end
end

--- Pop the queue out of the tabs, or put it back.
function W.ToggleQueuePop()
	local s = ws()
	s.popQueue = not s.popQueue
	s.queuePoint = nil
	local q = byKey.queue
	if s.popQueue then
		W.Arrange()
		if not W.Active() and CH.OpenProfessionID() then byKey.advisor.open() end
		W.Arrange()
	elseif q.frame and q.frame:IsShown() then
		q.frame:Hide()
		q.frame:Show()
	end
	return s.popQueue
end

W.AddTab("advisor", "Advisor", function() CH.AdvisorUI.Open() end, "Every result quality for the selected recipe.")
W.AddTab("scan", "Scan", function() CH.ScanUI.Open() end, "Every recipe in this profession, ranked.")
W.AddTab("queue", "Queue", function() CH.QueueUI.Show() end, "Your craft queue and shopping list.")
