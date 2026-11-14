-- Shared window parts for the scan, queue and results windows: a themed, draggable panel with a
-- title bar, and a table of rows with hover and click.
local _, CH = ...

local W = {}
CH.Window = W

--- A movable panel with the AuctionIQ title bar. Returns the frame; frame.bar holds buttons,
--- frame.title the title text, frame.close the close button.
--- Close a window with Escape, like the game's own windows and other addons: it joins the game's
--- list of windows Escape closes, so the first press closes it before the game menu opens. As a
--- backup, while it shows it hears Escape itself (outside combat, where that is allowed) and closes.
function W.CloseOnEscape(f, name)
	if name and UISpecialFrames then
		local known = false
		for _, n in ipairs(UISpecialFrames) do if n == name then known = true end end
		if not known then table.insert(UISpecialFrames, name) end
	end
	if not (f and f.EnableKeyboard and f.SetPropagateKeyboardInput) then return end
	f:EnableKeyboard(true)
	f:SetPropagateKeyboardInput(true)
	f:SetScript("OnKeyDown", function(self, key)
		if InCombatLockdown and InCombatLockdown() then return end -- keys pass on; the list closes it
		if key == "ESCAPE" then
			-- one press closes every AuctionIQ window, as the game closes all of its own
			self:SetPropagateKeyboardInput(false)
			for _, n in ipairs(UISpecialFrames or {}) do
				local w = type(n) == "string" and n:find("^AuctionIQ") and _G[n]
				if w and w.IsShown and w:IsShown() then w:Hide() end
			end
			self:Hide()
			self:SetPropagateKeyboardInput(true)
		end
	end)
end

-- Pixel-perfect windows. A window is scaled so one of its units is a whole number of screen pixels
-- (k, the nearest whole number to what the UI's own scale gives, at least 1), and its top-left
-- corner is nudged onto a whole pixel. With every card, row and line laid out on whole units, each
-- edge then lands on a pixel: no blurred borders, and no 1 px gaps or overlaps where neighbours round
-- differently. On a pixel-perfect ElvUI scale k is 1 and nothing changes size.
local scaled = {}

--- Screen pixels per UI unit at UIParent's scale, and the physical screen height (nil without them).
local function pixelRatio()
	local h = GetPhysicalScreenSize and select(2, GetPhysicalScreenSize())
	local parent = UIParent and UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()
	if type(h) ~= "number" or h <= 0 or type(parent) ~= "number" or parent <= 0 then return nil end
	return parent * h / 768, h, parent
end

--- The scale that makes a window's unit a whole number of pixels (1 without screen info).
function W.PixelScale()
	local ratio, h, parent = pixelRatio()
	if not ratio then return 1 end
	return math.max(1, math.floor(ratio + 0.5)) * 768 / h / parent
end

--- Scale a window to whole pixels, times user (the main window's size setting, which is pixel-perfect
--- at 1), and keep it so when the UI scale or the screen changes.
function W.Pixel(f, user)
	if not (f and f.SetScale) then return f end
	f.aiqUserScale = user
	f:SetScale(W.PixelScale() * (user or 1))
	scaled[f] = true
	if CH.Theme and CH.Theme.Edges then CH.Theme.Edges(f) end
	return f
end

--- Nudge a window by under a pixel so its top-left corner sits on a whole screen pixel.
function W.Snap(f)
	if not f then return end
	local l, t = f.GetLeft and f:GetLeft(), f.GetTop and f:GetTop()
	local s = f.GetEffectiveScale and f:GetEffectiveScale()
	local h = GetPhysicalScreenSize and select(2, GetPhysicalScreenSize())
	if type(l) ~= "number" or type(t) ~= "number" or type(s) ~= "number" or s <= 0 or type(h) ~= "number" or h <= 0 then return end
	local ppu = s * h / 768
	local dx = (math.floor(l * ppu + 0.5) - l * ppu) / ppu
	local dy = (math.floor(t * ppu + 0.5) - t * ppu) / ppu
	if math.abs(dx) < 1e-3 and math.abs(dy) < 1e-3 then return end
	local p, rel, rp, x, y = f:GetPoint(1)
	if not p then return end
	f:SetPoint(p, rel, rp, (x or 0) + dx, (y or 0) + dy)
end

local function rescale()
	for f in pairs(scaled) do
		f:SetScale(W.PixelScale() * (tonumber(rawget(f, "aiqUserScale")) or 1))
		if CH.Theme and CH.Theme.Edges then CH.Theme.Edges(f) end
		if f:IsShown() then W.Snap(f) end
	end
	if W.Arrange then W.Arrange() end
end
if CH.On then
	CH.On("UI_SCALE_CHANGED", rescale)
	CH.On("DISPLAY_SIZE_CHANGED", rescale)
end

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
	f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); W.Snap(self) end)
	f:SetPoint("CENTER")
	W.Pixel(f)
	f:HookScript("OnShow", function(self) W.Snap(self) end)
	f:Hide()
	W.CloseOnEscape(f, name)

	local bar = CreateFrame("Frame", nil, f, "BackdropTemplate")
	T.Panel(bar, "panel", 1)
	bar:SetPoint("TOPLEFT")
	bar:SetPoint("TOPRIGHT")
	bar:SetHeight(26)
	local rule = bar:CreateTexture(nil, "ARTWORK")
	T.AccentTexture(rule)
	rule:SetPoint("BOTTOMLEFT", 1, 0)
	rule:SetPoint("BOTTOMRIGHT", -1, 0)
	rule:SetHeight(T.Px(f, 2)) -- ToxiUI's accent line under the title bar
	f.rule = rule
	-- the brand alone, no icon: AUCTIONIQ with IQ in the theme colour
	f.title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.title:SetPoint("LEFT", 10, 0)
	T.BrandTitle(f.title, title)
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
				-- which column the cursor is over, so a cell can have its own tooltip
				local function column(self)
					if not (GetCursorPosition and parent.GetLeft and parent:GetLeft()) then return nil end
					local x = GetCursorPosition() / (self.GetEffectiveScale and self:GetEffectiveScale() or 1) - parent:GetLeft()
					for j, c in ipairs(cols) do if x >= c[2] and x < c[2] + c[3] + 4 then return j end end
					return nil
				end
				-- follow the cursor across columns only while it's over this row: OnUpdate runs on
				-- every shown frame, so a row it isn't over would take the tooltip over
				local function track(self)
					local j = column(self)
					if j ~= self.col then self.col = j; onEnter(self, i, j) end
				end
				b:SetScript("OnEnter", function(self)
					self.col = column(self); onEnter(self, i, self.col)
					self:SetScript("OnUpdate", track)
				end)
				b:SetScript("OnLeave", function(self) self:SetScript("OnUpdate", nil); self.col = nil; GameTooltip:Hide() end)
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
	--- Move the bar across (the table it scrolls got narrower or wider).
	function bar:SetX(nx)
		if nx == x then return end
		x = nx
		track:ClearAllPoints(); track:SetPoint("TOPLEFT", x, y)
		if count.ClearAllPoints then count:ClearAllPoints(); count:SetPoint("TOPLEFT", x - 116, y - h - 2) end
	end
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
		local th = math.floor(math.max(12, h * shown / total) + 0.5)
		local room = h - th
		local at = total > shown and math.floor(room * offset / (total - shown) + 0.5) or 0
		thumb:ClearAllPoints()
		thumb:SetPoint("TOPLEFT", x, y - at)
		thumb:SetHeight(th)
		bar.text = string.format("%d-%d of %d", offset + 1, math.min(total, offset + shown), total)
		count:SetText(bar.text)
	end
	return bar
end

--- Show tooltip lines ({left, right} or {left}) on owner.
--- lines: { left, right, rightColor, leftColor }, as the item tooltip draws them: a line that
--- isn't indented is a heading or total (accent), an indented one is a line item (fg); colors are
--- Theme names. A line with no right side is a note and wraps.
function W.Tooltip(owner, lines)
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	local Th = CH.Theme
	for _, l in ipairs(lines) do
		if l[2] then
			local lc = Th[l[4] or (tostring(l[1]):sub(1, 2) == "  " and "fg" or "accent")] or Th.fg
			local rc = Th[l[3] or "fg"] or Th.fg
			GameTooltip:AddDoubleLine(l[1], l[2], lc[1], lc[2], lc[3], rc[1], rc[2], rc[3])
		else
			GameTooltip:AddLine(l[1], 1, 1, 1, true)
		end
	end
	GameTooltip:Show()
end

--- Bookkeeping lines for tooltips, laid out like the statements and the item tooltip:
---   Head("Profit")                       heading
---   Line("Commission", 7200000)          line item, gold in, as is
---   Line("Reagents", -451000, true)      line item, gold out in red
---   Sub("Paid price", text)              detail under a line, muted
---   Total("Profit", 690000)              total, green or red
---   Note("Only what you supply.")        muted note
local Book = {}
W.Book = Book
local function gold(c) return CH.FormatMoney(c or 0) end
function Book.Head(label, right) return { label, right or "", "muted", "accent" } end
function Book.Line(label, c, out)
	if c == nil then return { "  " .. label, CH.Theme.Color("muted", "-"), "muted", "fg" } end
	local neg = out or c < 0
	return { "  " .. label, (neg and c ~= 0 and "-" or "") .. gold(math.abs(c)), neg and c ~= 0 and "bad" or "fg", "fg" }
end
function Book.Text(label, text, color) return { "  " .. label, text, color or "fg", "fg" } end
function Book.Sub(label, text) return { "      " .. label, text, "muted", "muted" } end
function Book.Total(label, c) return { label, (c and c < 0 and "-" or "") .. gold(math.abs(c or 0)), (c or 0) >= 0 and "ok" or "bad", "accent" } end
function Book.Note(text) return { CH.Theme.Color("muted", text) } end

--- An item's icon, inline in text. The game has every item icon loaded, so this is cheap.
function W.ItemIcon(itemID, size)
	local icon = itemID and C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)
	if not icon then return "" end
	size = size or 16
	return "|T" .. icon .. ":" .. size .. ":" .. size .. ":0:0:64:64:5:59:5:59|t "
end

--- The Concentration icon, inline in text (the currency's own icon once a profession has shown it).
function W.ConcIcon(size)
	size = size or 14
	local icon = CH.db and CH.db.concIcon
	if not icon then return CH.Theme.Color("accent", "C") end
	return "|T" .. icon .. ":" .. size .. ":" .. size .. ":0:0:64:64:5:59:5:59|t"
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
	-- two windows, Craft and Queue: the old Advisor window only when Settings turns it back on
	if key == "advisor" then return deck().classic == true end
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
	W.Pixel(strip)
	strip:SetFrameStrata("HIGH")
	strip:SetSize(10, 22)
	strip:Hide()
	if UISpecialFrames then table.insert(UISpecialFrames, "AuctionIQTabs") end
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
		W.Snap(f)
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
		-- one tab (the queue popped out) is no choice: no row
		strip:SetShown(#labels > 1 or undocked)
	elseif strip then
		strip:Hide()
	end
	local q = byKey.queue and byKey.queue.frame
	if q and q:IsShown() and not W.InTabs("queue") then
		local p = ws().queuePoint
		q:ClearAllPoints()
		if p then
			q:SetPoint(p[1], UIParent, p[3], p[4], p[5])
		elseif f and f:IsShown() then
			-- beside the Craft window, the two side by side; under it when the screen has no room
			local right, sw, qw = f.GetRight and f:GetRight(), UIParent.GetWidth and UIParent:GetWidth(), q.GetWidth and q:GetWidth()
			if type(right) == "number" and type(sw) == "number" and type(qw) == "number" and right + 4 + qw > sw then
				q:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -4)
			else
				q:SetPoint("TOPLEFT", f, "TOPRIGHT", 4, 0)
			end
		else
			q:SetPoint("CENTER", 0, 80)
		end
		W.Snap(q)
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
--- Once: forget where the popped-out queue was dragged, so it opens beside the Craft window.
function W.ResetQueueSpot()
	local s = ws()
	if s and not s.queueBeside then s.queueBeside = true; s.queuePoint = nil end
end

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
W.AddTab("scan", "Craft", function() CH.ScanUI.Open() end, "Every recipe in this profession, ranked, and the one you pick.")
W.AddTab("queue", "Queue", function() CH.QueueUI.Show() end, "Your craft queue and shopping list.")

--- A side panel beside a table, as the design draws it (the Craft page's Next Move panel): a card
--- with the accent line holding a kicker, a headline, a sub line, three big figures, an optional
--- gradient bar and label and value rows; a second card with a section of rows (each explains itself
--- on hover); a note; and buttons from the bottom up (the first, the main one, filled with the accent
--- and lowest). opts: { rows = 6, srows = 5, buttons = 3, onAction = function(button) end,
--- stepper = function(delta) end (a - and + beside the main button) }.
--- Fill it with W.DrawSidePanel(panel, d): d = { kicker, title, item (the title names this item: it
--- takes the item's quality colour, white when unknown; no item, the theme colour), sub, figures = { { label, value, tip = lines } x3 },
--- bar = 0..1, rows = { { label, value } }, section = { head, rows = { { label, value, tip = lines } }, toggle = { on, run, tip } }, note,
--- actions = { { label, run, tip, off } } }. The blocks stack from the top, each as tall as its text.
function W.SidePanel(parent, width, height, opts)
	opts = opts or {}
	local T = CH.Theme
	local det = CreateFrame("Frame", nil, parent)
	det:SetSize(width, height)
	det.width, det.height = width, height
	local function text(w, justify, template, lines)
		local fs = W.Text(det, 12, 0, w, justify, template)
		if lines and fs.SetMaxLines then fs:SetWordWrap(true); fs:SetMaxLines(lines) elseif not lines then W.OneLine(fs) end
		return fs
	end
	local function tipHit()
		local hit = CreateFrame("Button", nil, det)
		hit:SetScript("OnEnter", function(self) if self.tip and self.tip[1] then W.Tooltip(self, self.tip) end end)
		hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
		-- a row can also do something when clicked (pick a quality)
		hit:SetScript("OnClick", function(self) if self.run then self.run() end end)
		hit:Hide()
		return hit
	end
	local nRows, nSec, nBtn = opts.rows or 6, opts.srows or 5, opts.buttons or 3
	local IW = width - 24
	det.IW = IW
	det.cardTop = T.BorderCard(det, 0, 0, width, 120)
	det.accentBar = det:CreateTexture(nil, "ARTWORK")
	det.accentBar:SetPoint("TOPLEFT", 0, 0)
	det.accentBar:SetSize(width, 2)
	T.AccentTexture(det.accentBar)
	det.cardPrices = T.BorderCard(det, 0, -130, width, 100)
	det.kicker = text(IW, "LEFT", "GameFontNormalSmall")
	T.TitleFont(det.kicker, 10, "bold")
	det.title = text(IW, "LEFT", "GameFontNormalLarge", 2)
	det.title:SetTextColor(T.accent[1], T.accent[2], T.accent[3]) -- the theme colour, not the game's gold
	T.TitleFont(det.title, 15, "black")
	det.sub = text(IW, "LEFT", "GameFontDisableSmall", 2)
	det.subHit = tipHit()
	det.figures = {}
	-- the three figures: the middle one (Cost, and how many a craft makes) a little wider
	local FX = { 0, math.floor(IW * 0.30), math.floor(IW * 0.72) }
	local FWS = { FX[2], FX[3] - FX[2], IW - FX[3] }
	det.FX, det.FWS = FX, FWS
	for k = 1, 3 do
		local f = { label = text(FWS[k] - 4, "LEFT", "GameFontDisableSmall"), value = text(FWS[k] - 4, "LEFT", "GameFontHighlightLarge"), hit = tipHit() }
		T.TitleFont(f.label, 9, "bold")
		T.TitleFont(f.value, 15, "black")
		det.figures[k] = f
	end
	-- the bar under the figures: a dark track and the theme's gradient
	det.track = det:CreateTexture(nil, "ARTWORK")
	det.track:SetColorTexture(0.067, 0.067, 0.067, 1)
	det.track:SetSize(IW, 6)
	det.fill = det:CreateTexture(nil, "OVERLAY")
	det.fill:SetSize(IW, 6)
	T.Gradient(det.fill)
	local function pair()
		local r = { label = text(IW - 100, "LEFT", "GameFontHighlightSmall"), value = text(110, "RIGHT", "GameFontHighlightSmall") }
		r.label:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
		return r
	end
	det.rows = {}
	for k = 1, nRows do local r = pair(); r.hit = tipHit(); det.rows[k] = r end
	det.head = text(IW, "LEFT", "GameFontNormalSmall")
	T.TitleFont(det.head, 10, "bold")
	det.srows = {}
	for k = 1, nSec do
		local r = pair()
		r.hit = tipHit()
		-- a picked row: an accent wash and a bar on its left, as the list marks its selected row
		r.sel = det:CreateTexture(nil, "BORDER")
		r.sel:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 0.18)
		r.sel:Hide()
		r.mark = det:CreateTexture(nil, "ARTWORK")
		r.mark:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 1)
		r.mark:Hide()
		det.srows[k] = r
	end
	-- a switch on the section's head line (Concentrate on or off)
	det.toggle = text(120, "RIGHT", "GameFontNormalSmall")
	T.TitleFont(det.toggle, 10, "bold")
	-- the switch itself: a track that fills with the accent when on, and a knob that slides right
	det.switch = CreateFrame("Frame", nil, det)
	det.switch:SetSize(26, 12)
	det.switch.track = det.switch:CreateTexture(nil, "ARTWORK")
	det.switch.track:SetAllPoints()
	det.switch.knob = det.switch:CreateTexture(nil, "OVERLAY")
	det.switch.knob:SetSize(10, 10)
	det.switch:Hide()
	det.toggleHit = tipHit()
	det.note = text(IW, "LEFT", "GameFontDisableSmall", 4)
	-- a line chart's head, price range, first and last dates, and its lines (made as drawn)
	det.chartHead = text(IW, "LEFT", "GameFontNormalSmall")
	T.TitleFont(det.chartHead, 10, "bold")
	det.chartRange = text(IW, "RIGHT", "GameFontDisableSmall")
	det.chartFrom = text(IW, "LEFT", "GameFontDisableSmall")
	det.chartTo = text(IW, "RIGHT", "GameFontDisableSmall")
	det.chartLines = {}
	det.noteHit = tipHit()
	det.said = W.Text(det, 12, 0, IW, "LEFT", "GameFontHighlightSmall")
	if det.said.SetMaxLines then det.said:SetWordWrap(true); det.said:SetMaxLines(2) end
	-- the buttons, bottom up: the main one (accent, a little taller), then the others, dark
	det.buttons = {}
	local by = 0
	for k = 1, nBtn do
		local h = k == 1 and 28 or 24
		local w = (k == 1 and opts.stepper) and (width - 56) or width
		local b = T.Button(det, "", w, h)
		b:SetPoint("BOTTOMLEFT", 0, by)
		by = by + h + 6
		if k == 1 then T.Primary(b) end
		b:SetScript("OnClick", function(self)
			if not self.run or self.blocked then return end
			if opts.onAction then opts.onAction(self) else self.run() end
		end)
		local enter = b.GetScript and b:GetScript("OnEnter")
		b:SetScript("OnEnter", function(self)
			if type(enter) == "function" then enter(self) end
			if self.tipText or self.blocked then W.Tooltip(self, { { self.label or "" }, { T.Color("muted", self.blocked or self.tipText) } }) end
		end)
		det.buttons[k] = b
	end
	det.buttonsHeight = by
	det.stepper = {}
	if opts.stepper then
		for k, dlt in ipairs({ -1, 1 }) do
			local b = T.Button(det, dlt < 0 and "-" or "+", 24, 28)
			b:SetPoint("BOTTOMRIGHT", -(k == 1 and 28 or 0), 0)
			b:SetScript("OnClick", function() opts.stepper(IsShiftKeyDown and IsShiftKeyDown() and dlt * 10 or dlt) end)
			local enter = b.GetScript and b:GetScript("OnEnter")
			b:SetScript("OnEnter", function(self)
				if type(enter) == "function" then enter(self) end
				W.Tooltip(self, { { dlt < 0 and "One fewer" or "One more" }, { T.Color("muted", "How many to queue. Shift-click for 10 at a time.") } })
			end)
			det.stepper[k] = b
		end
	end
	det:Hide()
	return det
end

W.WHITE = { 1, 1, 1 }
--- An item's quality colour as { r, g, b }, or nil when the game doesn't know the item yet.
function W.ItemColor(itemID)
	local id = tonumber(itemID)
	if not id or not C_Item or not C_Item.GetItemQualityByID then return nil end
	local ok, q = pcall(C_Item.GetItemQualityByID, id)
	if not ok or type(q) ~= "number" then return nil end
	local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
	if c and c.r then return { c.r, c.g, c.b } end
	if C_Item.GetItemQualityColor then
		local r, g, b = C_Item.GetItemQualityColor(q)
		if r then return { r, g, b } end
	end
	return nil
end

--- Fill a side panel (W.SidePanel) from d, with said (a line saying what the last action did) above
--- the buttons. The blocks stack from the top as tall as their text. Shows the panel and returns d.
function W.DrawSidePanel(det, d, said)
	local T = CH.Theme
	local function at(fs, x, y) fs:ClearAllPoints(); fs:SetPoint("TOPLEFT", x, y) end
	-- how tall a wrapped line of text is: its width over the line's, up to two lines
	local function height(fs, lineH)
		local sw = fs.GetStringWidth and fs:GetStringWidth()
		if type(sw) ~= "number" or sw <= 0 then return lineH end
		return lineH * math.min(2, math.max(1, math.ceil(sw / det.IW)))
	end
	local y = -8
	at(det.kicker, 12, y)
	det.kicker:SetText(d.kicker and T.Color("accent", d.kicker) or "")
	y = y - 14
	at(det.title, 12, y)
	-- an item's name in its quality colour (white until the game knows it), else the theme colour
	local tc = d.item and W.ItemColor(d.item) or (d.item == nil and T.accent) or W.WHITE
	det.title:SetTextColor(tc[1], tc[2], tc[3])
	det.title:SetText(d.title or "")
	y = y - height(det.title, 17) - 2
	at(det.sub, 12, y)
	det.sub:SetText(d.sub or "")
	-- the sub line always takes its two lines, so what's under it stays put as it changes
	local subH = (d.sub and d.sub ~= "") and 24 or 0
	det.subHit:ClearAllPoints(); det.subHit:SetPoint("TOPLEFT", 10, y + 2); det.subHit:SetSize(det.IW, subH + 2)
	det.subHit.tip = d.subTip or false
	det.subHit:SetShown(d.subTip ~= nil and subH > 0)
	if subH > 0 then y = y - subH - 2 end
	local FX, FWS = det.FX, det.FWS
	local anyFig = d.figures and d.figures[1]
	y = y - 2
	for k, f in ipairs(det.figures) do
		local x = d.figures and d.figures[k]
		at(f.label, 12 + FX[k], y); at(f.value, 12 + FX[k], y - 12)
		f.label:SetText(x and x[1] or ""); f.value:SetText(x and x[2] or "")
		f.hit:ClearAllPoints(); f.hit:SetPoint("TOPLEFT", 10 + FX[k], y + 2); f.hit:SetSize(FWS[k], 32)
		f.hit.tip = x and x.tip or false
		f.hit:SetShown(x ~= nil and x.tip ~= nil)
	end
	if anyFig then y = y - 32 end
	local bar = type(d.bar) == "number" and math.max(0, math.min(1, d.bar)) or nil
	det.track:ClearAllPoints(); det.track:SetPoint("TOPLEFT", 12, y)
	det.fill:ClearAllPoints(); det.fill:SetPoint("TOPLEFT", 12, y)
	det.track:SetShown(bar ~= nil); det.fill:SetShown(bar ~= nil and bar > 0)
	if bar then det.fill:SetWidth(math.max(1, math.floor(det.IW * bar + 0.5))); y = y - 12 end
	local shown = 0
	for k, r in ipairs(det.rows) do
		local x = d.rows and d.rows[k]
		at(r.label, 12, y); at(r.value, det.width - 122, y)
		r.label:SetText(x and x[1] or ""); r.value:SetText(x and x[2] or "")
		r.hit:ClearAllPoints(); r.hit:SetPoint("TOPLEFT", 4, y + 1); r.hit:SetSize(det.width - 8, 14)
		r.hit.tip = x and x.tip or false
		r.hit:SetShown(x ~= nil and x.tip ~= nil)
		if x then y = y - 14; shown = shown + 1 end
	end
	y = y - 4
	det.cardTop:Place(0, 0, det.width, -y)
	-- the section, on its own card
	local sec = d.section
	y = y - 6
	local secTop = y
	at(det.head, 12, y - 6)
	det.head:SetText(sec and T.Color("accent", sec.head or "") or "")
	local tg = sec and sec.toggle
	at(det.toggle, det.width - 164, y - 6)
	det.toggle:SetText(tg and T.Color(tg.on and "accent" or "muted", "CONCENTRATE  " .. (tg.on and "ON" or "OFF")) or "")
	local sw = det.switch
	sw:ClearAllPoints(); sw:SetPoint("TOPLEFT", det.width - 38, y - 5)
	if tg then
		local c = tg.on and T.accent or T.line
		sw.track:SetColorTexture(c[1], c[2], c[3], 1)
		local k = tg.on and T.bg or T.muted
		sw.knob:SetColorTexture(k[1], k[2], k[3], 1)
		sw.knob:ClearAllPoints(); sw.knob:SetPoint(tg.on and "RIGHT" or "LEFT", sw, tg.on and "RIGHT" or "LEFT", tg.on and -1 or 1, 0)
	end
	sw:SetShown(tg ~= nil)
	if tg then sw.isOn = tg.on == true else sw.isOn = nil end
	det.toggleHit:ClearAllPoints(); det.toggleHit:SetPoint("TOPLEFT", det.width - 168, y - 2); det.toggleHit:SetSize(160, 16)
	det.toggleHit.tip = tg and tg.tip or false
	det.toggleHit.run = tg and tg.run or false
	det.toggleHit:SetShown(tg ~= nil)
	if sec then y = y - 20 end
	for k, r in ipairs(det.srows) do
		local x = sec and sec.rows and sec.rows[k]
		at(r.label, 12, y); at(r.value, det.width - 122, y)
		r.label:SetText(x and x[1] or ""); r.value:SetText(x and x[2] or "")
		r.hit:ClearAllPoints(); r.hit:SetPoint("TOPLEFT", 4, y + 1); r.hit:SetSize(det.width - 8, 14)
		r.hit.tip = x and x.tip or false
		r.hit.run = x and x.run or false
		r.sel:ClearAllPoints(); r.sel:SetPoint("TOPLEFT", 1, y + 1); r.sel:SetSize(det.width - 2, 14)
		r.mark:ClearAllPoints(); r.mark:SetPoint("TOPLEFT", 1, y + 1); r.mark:SetSize(2, 14)
		r.sel:SetShown(x ~= nil and x.on == true); r.mark:SetShown(x ~= nil and x.on == true)
		r.hit:SetShown(x ~= nil and (x.tip ~= nil or x.run ~= nil))
		if x then y = y - 14 end
	end
	if sec then
		y = y - 4
		det.cardPrices:Place(0, secTop, det.width, secTop - y)
		y = y - 6
	end
	-- or, with no section, a line chart on that card: d.chart = { head, values, lo, hi, from, to }
	local ch = not sec and d.chart and d.chart.values and #d.chart.values >= 2 and d.chart or nil
	for _, l in pairs(det.chartLines) do if l then l:Hide() end end
	for _, fs in ipairs({ det.chartHead, det.chartRange, det.chartFrom, det.chartTo }) do fs:SetText("") end
	if ch then
		local top = y
		at(det.chartHead, 12, y - 6); det.chartHead:SetText(T.Color("accent", ch.head or ""))
		at(det.chartRange, 12, y - 6)
		local M = CH.FormatMoney
		det.chartRange:SetText(ch.lo and ch.hi and (M(ch.lo, true) .. " - " .. M(ch.hi, true)) or "")
		local PH, plotTop = 60, y - 24
		local lo, hi = ch.lo or math.huge, ch.hi or 0
		if not (ch.lo and ch.hi) then for _, v in ipairs(ch.values) do lo, hi = math.min(lo, v), math.max(hi, v) end end
		if hi <= lo then hi, lo = lo + 1, lo - 1 end
		local n = #ch.values
		local function px(i) return 12 + det.IW * (i - 1) / (n - 1), plotTop - PH * (1 - (ch.values[i] - lo) / (hi - lo)) end
		for i = 2, n do
			local l = det.chartLines[i]
			if l == nil and det.CreateLine then l = det:CreateLine(nil, "ARTWORK"); det.chartLines[i] = l or false end
			if l then
				local x0, y0 = px(i - 1)
				local x1, y1 = px(i)
				l:SetThickness(2)
				l:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 1)
				l:SetStartPoint("TOPLEFT", det, x0, y0)
				l:SetEndPoint("TOPLEFT", det, x1, y1)
				l:Show()
			end
		end
		y = plotTop - PH - 4
		at(det.chartFrom, 12, y); det.chartFrom:SetText(ch.from or "")
		at(det.chartTo, 12, y); det.chartTo:SetText(ch.to or "")
		y = y - 16
		det.cardPrices:Place(0, top, det.width, top - y)
		y = y - 6
	end
	det.chartShown = ch ~= nil
	det.cardPrices:Visible(sec ~= nil or ch ~= nil)
	-- the note, in what's left above the buttons
	at(det.note, 12, y)
	det.note:SetText(d.note or "")
	det.noteHit:ClearAllPoints(); det.noteHit:SetPoint("TOPLEFT", 10, y + 2); det.noteHit:SetSize(det.IW, 26)
	det.noteHit.tip = d.noteTip or false
	det.noteHit:SetShown(d.noteTip ~= nil)
	local nb = 0
	local by = 0
	for k, b in ipairs(det.buttons) do
		local a = d.actions and d.actions[k]
		b.run, b.tipText, b.blocked = a and a.run or false, a and a.tip or false, a and a.off or false
		if a then
			nb = k
			by = by + (k == 1 and 28 or 24) + 6
			local f = b.text or (b.GetFontString and b:GetFontString())
			local label = (a.label or ""):upper()
			if f then f:SetText(label) elseif b.SetText then b:SetText(label) end
			b.label = a.label
			if b.SetAlpha then b:SetAlpha(a.off and 0.45 or 1) end
		end
		b:SetShown(a ~= nil)
	end
	for _, s in ipairs(det.stepper or {}) do s:SetShown(nb > 0) end
	local room = ((det.GetHeight and det:GetHeight()) or det.height) + y - by - 4
	if det.note.SetMaxLines then det.note:SetMaxLines(math.max(1, math.min(4, math.floor(room / 12)))) end
	det.said:ClearAllPoints()
	det.said:SetPoint("BOTTOMLEFT", 12, by + 4)
	det.said:SetText(said or "")
	det:Show()
	return d
end
