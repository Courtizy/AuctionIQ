-- Shared window parts for the scan, paths and results windows: a themed, draggable panel with a
-- title bar, and a table of rows with hover and click.
local _, CH = ...

local W = {}
CH.Window = W

--- A movable panel with the Clearinghouse title bar. Returns the frame; frame.bar holds buttons,
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
	badge:SetTexture("Interface\\AddOns\\Clearinghouse\\Media\\Icon")
	badge:SetSize(18, 18)
	badge:SetPoint("LEFT", 5, 0)
	f.title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.title:SetPoint("LEFT", badge, "RIGHT", 6, 0)
	f.title:SetText(T.Color("accent", "Clearinghouse") .. "  " .. T.Color("muted", title))
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

--- Show tooltip lines ({left, right} or {left}) on owner.
function W.Tooltip(owner, lines)
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	for _, l in ipairs(lines) do
		if l[2] then GameTooltip:AddDoubleLine(l[1], l[2], 1, 1, 1, 1, 1, 1) else GameTooltip:AddLine(l[1], 1, 1, 1, true) end
	end
	GameTooltip:Show()
end

function W.QualityIcon(q, size)
	if not q then return "" end
	if CreateAtlasMarkup then return CreateAtlasMarkup("Professions-Icon-Quality-Tier" .. q .. "-Small", size or 16, size or 16) end
	return "Q" .. q
end
