-- Minimap button with the AuctionIQ icon: click opens the window, drag moves it around the
-- minimap. /ch minimap hides or shows it. No libraries, so it works without LibDBIcon.
local _, CH = ...

local ICON = CH.ICON
local button

local function place()
	local a = math.rad(CH.db.settings.minimap.angle or 225)
	local r = (Minimap:GetWidth() / 2) + 5
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

local function onDrag(self)
	local mx, my = Minimap:GetCenter()
	local scale = Minimap:GetEffectiveScale()
	local cx, cy = GetCursorPosition()
	CH.db.settings.minimap.angle = math.deg((math.atan2 or math.atan)(cy / scale - my, cx / scale - mx)) % 360
	place()
end

function CH.CreateMinimapButton()
	if button or not Minimap then return button end
	button = CreateFrame("Button", "AuctionIQMinimapButton", Minimap)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForClicks("AnyUp")
	button:RegisterForDrag("LeftButton")
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetTexture(ICON)
	icon:SetSize(20, 20)
	icon:SetPoint("TOPLEFT", 6, -5)
	if CH.Theme.Elv() and button.SetTemplate then
		-- ElvUI's minimap is square: a square skinned button instead of the round ring
		button:SetSize(24, 24)
		button:SetTemplate("Default")
		icon:ClearAllPoints()
		icon:SetPoint("TOPLEFT", 1, -1)
		icon:SetPoint("BOTTOMRIGHT", -1, 1)
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	else
		local border = button:CreateTexture(nil, "OVERLAY")
		border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
		border:SetSize(53, 53)
		border:SetPoint("TOPLEFT")
	end

	button:SetScript("OnClick", function() CH.UI.Toggle() end)
	button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", onDrag) end)
	button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine(CH.Theme.Color("accent", "AuctionIQ"))
		GameTooltip:AddLine("Click to open AuctionIQ. Drag to move.", 1, 1, 1)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)
	place()
	CH.UpdateMinimapButton()
	return button
end

function CH.UpdateMinimapButton()
	if not button then return end
	if CH.db.settings.minimap.hide then button:Hide() else button:Show() end
end

CH.On("PLAYER_LOGIN", function() CH.CreateMinimapButton() end)
