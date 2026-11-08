-- AuctionIQ look: flat dark panels with a 1px border (ElvUI style). Two palettes: AuctionIQ is navy,
-- gold and emerald; its Clearinghouse ledger is plum, parchment and gold. With ElvUI (and ToxiUI on
-- top of it) the frames keep ElvUI's templates, borders, fonts, shadows and noise, tinted with the
-- palette; /aiq theme switches to ElvUI's own colours instead. See THEME.md.
local _, CH = ...

local function hex(h)
	return { tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255 }
end

local PALETTES = {
	auctioniq = { bg = "0e1729", panel = "15213b", line = "263a63", fg = "e6e8ee", muted = "9aa6bd", accent = "e0a83a", iq = "34c77b", ok = "6cc58f", bad = "ef7d72" },
	clearinghouse = { bg = "1c1222", panel = "281a30", line = "45304f", fg = "efe4c8", muted = "b8a69a", accent = "e0a83a", iq = "d8c39a", ok = "6cc58f", bad = "ef7d72" },
}
local T = { hex = {}, PALETTES = PALETTES }
CH.Theme = T

local function elvColours()
	return CH.db and CH.db.settings and CH.db.settings.theme == "elvui"
end

--- Switch palette: "auctioniq" (default) or "clearinghouse". ElvUI's colours win when /aiq theme says so.
function T.Use(name)
	T.palette = PALETTES[name] and name or "auctioniq"
	for k, h in pairs(PALETTES[T.palette]) do T.hex[k] = h; T[k] = hex(h) end
	if T.Sync then T.Sync() end
end

-- "|cffe0a83atext|r" in a theme colour.
function T.Color(name, text)
	return "|cff" .. T.hex[name] .. text .. "|r"
end

local FLAT = "Interface\\Buttons\\WHITE8X8"
local BACKDROP = { bgFile = FLAT, edgeFile = FLAT, edgeSize = 1 }

-- ElvUI, when it's loaded: its own templates, fonts and value colour, so Clearinghouse looks like
-- the rest of the UI. ToxiUI hooks ElvUI's SetTemplate, so its shadows and noise come along too.
function T.Elv()
	if T.noElv then return nil end
	local E = ElvUI and ElvUI[1]
	return E and E.media and E or nil
end

-- Pull ElvUI's colours into the theme (border, backdrop, value colour). Call before building frames.
function T.Sync()
	local E = T.Elv()
	if not E or not elvColours() then return end
	local m = E.media
	local function set(name, c)
		if c and c[1] then
			T[name] = { c[1], c[2], c[3] }
			local function b(v) return math.floor(v * 255 + 0.5) end
			T.hex[name] = string.format("%02x%02x%02x", b(c[1]), b(c[2]), b(c[3]))
		end
	end
	set("accent", m.rgbvaluecolor)
	set("line", m.bordercolor)
	set("bg", m.backdropfadecolor)
	set("panel", m.backdropcolor)
end

-- ElvUI's font on every font string in a frame and its children, keeping each one's size.
function T.Fonts(frame)
	if not T.Elv() or not frame then return end
	for _, r in ipairs({ frame:GetRegions() }) do
		if r.GetObjectType and r:GetObjectType() == "FontString" and r.FontTemplate then
			local _, size = r:GetFont()
			r:FontTemplate(nil, size)
		end
	end
	for _, c in ipairs({ frame:GetChildren() }) do T.Fonts(c) end
end

-- A flat panel: background colour, 1px border. With ElvUI, its Transparent or Default template.
function T.Panel(frame, bg, alpha)
	frame.aiqBg, frame.aiqAlpha = bg or "bg", alpha
	if T.Elv() and frame.SetTemplate then
		frame:SetTemplate(bg == "panel" and "Default" or "Transparent")
		T.Tint(frame)
		return frame
	end
	if not frame.SetBackdrop then Mixin(frame, BackdropTemplateMixin) end
	frame:SetBackdrop(BACKDROP)
	T.Tint(frame)
	return frame
end

--- Colour a panel from the current palette. With ElvUI the template's border, shadow and alpha stay.
function T.Tint(frame)
	if not frame.SetBackdropColor or not frame.aiqBg then return end
	local c = T[frame.aiqBg] or T.bg
	local E = T.Elv()
	if E then
		if elvColours() then return end
		local fade = E.media.backdropfadecolor
		local a = frame.aiqBg == "panel" and 1 or (fade and fade[4]) or 0.8
		frame:SetBackdropColor(c[1], c[2], c[3], a)
		return
	end
	frame:SetBackdropColor(c[1], c[2], c[3], frame.aiqAlpha or 0.95)
	frame:SetBackdropBorderColor(T.line[1], T.line[2], T.line[3], 1)
end

--- Re-tint a window and everything in it after a palette switch.
function T.Repaint(root)
	if not root then return end
	T.Tint(root)
	if root.GetChildren then for _, c in ipairs({ root:GetChildren() }) do T.Repaint(c) end end
end

-- A flat text button that turns gold on hover (ElvUI: its button skin, or its close button for "x").
function T.Button(parent, label, w, h)
	local E = T.Elv()
	if E then
		local S = E.GetModule and E:GetModule("Skins", true)
		if label == "x" and S and S.HandleCloseButton then
			local c = CreateFrame("Button", nil, parent, "UIPanelCloseButton")
			c:SetSize(w or 20, h or 20)
			S:HandleCloseButton(c)
			return c
		end
		if S and S.HandleButton then
			local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
			b:SetSize(w or 20, h or 20)
			b:SetText(label)
			S:HandleButton(b)
			return b
		end
	end
	local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
	b:SetSize(w or 20, h or 20)
	T.Panel(b, "panel", 1)
	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	fs:SetPoint("CENTER", 0, 1)
	fs:SetText(label)
	b.text = fs
	b:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(T.accent[1], T.accent[2], T.accent[3], 1); fs:SetTextColor(T.accent[1], T.accent[2], T.accent[3]) end)
	b:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(T.line[1], T.line[2], T.line[3], 1); fs:SetTextColor(T.fg[1], T.fg[2], T.fg[3]) end)
	return b
end

-- ElvUI sets its media during its own login; take its colours once everything has loaded.
T.Use("auctioniq")
CH.On("PLAYER_LOGIN", function() T.Use(T.palette) end)
