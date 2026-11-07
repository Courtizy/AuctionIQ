-- Clearinghouse look: flat dark panels with a 1px border (ElvUI style) in the same colours as the
-- companion page. See THEME.md; change a colour here and in the page together.
local _, CH = ...

local function hex(h)
	return { tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255 }
end

local T = {
	hex = { bg = "141821", panel = "1b202b", line = "2c3342", fg = "e6e8ee", muted = "9aa2b3", accent = "e0a83a", ok = "6cc58f", bad = "ef7d72" },
}
for k, h in pairs(T.hex) do T[k] = hex(h) end
CH.Theme = T

-- "|cffe0a83atext|r" in a theme colour.
function T.Color(name, text)
	return "|cff" .. T.hex[name] .. text .. "|r"
end

local FLAT = "Interface\\Buttons\\WHITE8X8"
local BACKDROP = { bgFile = FLAT, edgeFile = FLAT, edgeSize = 1 }

-- A flat panel: background colour, 1px border.
function T.Panel(frame, bg, alpha)
	if not frame.SetBackdrop then Mixin(frame, BackdropTemplateMixin) end
	frame:SetBackdrop(BACKDROP)
	local c = T[bg or "bg"]
	frame:SetBackdropColor(c[1], c[2], c[3], alpha or 0.95)
	frame:SetBackdropBorderColor(T.line[1], T.line[2], T.line[3], 1)
	return frame
end

-- A flat text button that turns gold on hover.
function T.Button(parent, label, w, h)
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
