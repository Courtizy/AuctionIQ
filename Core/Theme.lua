-- AuctionIQ look, after ToxiUI's Dark style: graphite panels with black 1px borders and a soft
-- shadow, the player's class colour as the accent, ToxiUI's class gradients on progress bars and
-- Montserrat titles. The Accounting tab keeps its plum, parchment and gold. With ElvUI (and ToxiUI on
-- top of it) the frames keep ElvUI's templates, borders, fonts, shadows and noise, tinted with the
-- palette; /aiq theme switches to ElvUI's own colours instead. See THEME.md.
local _, CH = ...

local function hex(h)
	return { tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255 }
end

local PALETTES = {
	-- ToxiUI's ElvUI colours: backdrop #1a1a1a, see-through backdrop #292929 at 80%, black borders.
	-- The accent becomes the player's class colour once the game knows the class.
	auctioniq = { bg = "292929", panel = "1a1a1a", line = "000000", fg = "f2f2f2", muted = "a3a3ab", accent = "3fc7eb", iq = "34c77b", ok = "34c77b", bad = "ef7d72", gold = "e0a83a", bgAlpha = 0.8, classAccent = true },
	-- the earlier navy look
	navy = { bg = "0e1729", panel = "15213b", line = "263a63", fg = "e6e8ee", muted = "9aa6bd", accent = "e0a83a", iq = "34c77b", ok = "6cc58f", bad = "ef7d72", gold = "e0a83a" },
	accounting = { bg = "1c1222", panel = "281a30", line = "45304f", fg = "efe4c8", muted = "b8a69a", accent = "e0a83a", iq = "d8c39a", ok = "6cc58f", bad = "ef7d72", gold = "e0a83a" },
}
-- ToxiUI's class gradients (its Gradient Mode colours): left (shifted) to right (normal).
local GRADIENTS = {
	DEATHKNIGHT = { "911622", "ff2855" }, DEMONHUNTER = { "8200a9", "e500d1" }, DRUID = { "e76200", "ffa900" },
	EVOKER = { "33706f", "32fedc" }, HUNTER = { "4acc35", "abed4f" }, MAGE = { "0080d7", "00d8ff" },
	MONK = { "009463", "00ff8c" }, PALADIN = { "d960a4", "ff95d8" }, PRIEST = { "b9b9b9", "fcfcfc" },
	ROGUE = { "ffb759", "fff368" }, SHAMAN = { "0061bf", "0a7ded" }, WARLOCK = { "562fbd", "9946ff" },
	WARRIOR = { "946837", "dfaa73" },
}
local T = { hex = {}, PALETTES = PALETTES, GRADIENTS = GRADIENTS }
CH.Theme = T

local function playerClass()
	if not UnitClass then return nil end
	local _, class = UnitClass("player")
	return class
end

-- The player's class colour as a hex string, or nil before the game knows the class.
function T.ClassHex(class)
	class = class or playerClass()
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if not c then return nil end
	if not c.r then return c.colorStr and c.colorStr:sub(3):lower() or nil end
	local function b(v) return math.floor(v * 255 + 0.5) end
	return string.format("%02x%02x%02x", b(c.r), b(c.g), b(c.b))
end

--- The class gradient for progress bars: two colours { r, g, b }. ToxiUI's own map when it is
--- loaded (it may be customised), else the same defaults; the accent for an unknown class.
function T.GradientColors(class)
	class = class or playerClass()
	local E = T.Elv()
	local db = E and E.db and E.db.TXUI and E.db.TXUI.themes and E.db.TXUI.themes.gradientMode
	local map = db and db.classColorMap
	if map and class then
		local l, r = map.SHIFT and map.SHIFT[class], map.NORMAL and map.NORMAL[class]
		if not l then for k, v in pairs(map) do if type(v) == "table" and v[class] then if l then r = r or v[class] else l = v[class] end end end end
		if l and r and l.r and r.r then return { l.r, l.g, l.b }, { r.r, r.g, r.b } end
	end
	local g = class and GRADIENTS[class]
	if g then return hex(g[1]), hex(g[2]) end
	local a = T.accent or { 1, 1, 1 }
	return { a[1] * 0.7, a[2] * 0.7, a[3] * 0.7 }, a
end

--- Paint a bar texture with the class gradient, left to right (a flat accent where the game has
--- no gradients).
function T.Gradient(tex)
	if not tex then return tex end
	local l, r = T.GradientColors()
	if tex.SetGradient and CreateColor then
		tex:SetColorTexture(1, 1, 1, 1)
		tex:SetGradient("HORIZONTAL", CreateColor(l[1], l[2], l[3], 1), CreateColor(r[1], r[2], r[3], 1))
	else
		tex:SetColorTexture(r[1], r[2], r[3], 1)
	end
	tex.aiqGradient = { l, r }
	return tex
end

-- ToxiUI's title fonts, when it is installed.
local FONTS = { black = "Montserrat-Black.ttf", bold = "Montserrat-Bold.ttf" }
local function toxiLoaded()
	local f = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
	return f and f("ElvUI_ToxiUI") and true or false
end

--- A title in Montserrat Black (bold for "bold"), as ToxiUI sets its headings; keeps the game font
--- without ToxiUI. size defaults to the string's own.
function T.TitleFont(fs, size, kind)
	if not (fs and fs.SetFont) then return fs end
	local _, own, flags = fs.GetFont and fs:GetFont()
	size = size or own or 12
	if toxiLoaded() then
		fs:SetFont("Interface\\AddOns\\ElvUI_ToxiUI\\Media\\Fonts\\" .. FONTS[kind or "black"], size, flags or "")
	elseif fs.GetFont and fs:GetFont() then
		fs:SetFont((fs:GetFont()), size, flags or "")
	end
	fs.aiqTitle = kind or "black"
	return fs
end

--- The "AUCTIONIQ" wordmark, with IQ in the accent.
function T.Wordmark()
	return T.Color("fg", "AUCTION") .. T.Color("accent", "IQ")
end

local function elvColours()
	return CH.db and CH.db.settings and CH.db.settings.theme == "elvui"
end

--- Switch palette: "auctioniq" (default) or "accounting" (the Accounting tab). ElvUI's colours win when /aiq theme says so.
function T.Use(name)
	T.palette = PALETTES[name] and name or "auctioniq"
	local pal = PALETTES[T.palette]
	for k, h in pairs(pal) do if type(h) == "string" then T.hex[k] = h; T[k] = hex(h) end end
	T.bgAlpha = pal.bgAlpha
	local class = pal.classAccent and T.ClassHex()
	if class then T.hex.accent = class; T.accent = hex(class) end
	if T.Sync then T.Sync() end
end

-- "|cffe0a83atext|r" in a theme colour.
function T.Color(name, text)
	return "|cff" .. T.hex[name] .. text .. "|r"
end

local FLAT = "Interface\\Buttons\\WHITE8X8"
local BACKDROP = { bgFile = FLAT, edgeFile = FLAT, edgeSize = 1 }

-- ElvUI, when it's loaded: its own templates, fonts and value colour, so AuctionIQ looks like
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
		if r.GetObjectType and r:GetObjectType() == "FontString" and r.FontTemplate and not r.aiqTitle then
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
	local a = frame.aiqAlpha or 0.95
	if frame.aiqBg == "bg" and T.bgAlpha then a = math.min(a, T.bgAlpha) end
	frame:SetBackdropColor(c[1], c[2], c[3], a)
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
