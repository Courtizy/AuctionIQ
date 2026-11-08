-- Mail panel beside the mailbox: Open all, then Send (one click per mail) by your group routes.
local _, CH = ...

local MUI = {}
CH.MailUI = MUI
local frame, status, list, sendButton

function MUI.Refresh()
	if not frame then return end
	if not CH.Mail.opening then
		local w = CH.Mail.Waiting()
		frame.waiting:SetText(string.format("Waiting: %s in %d mails, %d with items%s", CH.FormatMoney(w.gold), w.mails, w.items,
			w.cod > 0 and CH.Theme.Color("bad", ", " .. w.cod .. " cash on delivery") or ""))
	end
	local box = CH.Mail.Outbox()
	local lines, n = {}, 0
	for to, items in pairs(box) do
		n = n + 1
		local counts = {}
		for _, it in ipairs(items) do counts[it.id] = (counts[it.id] or 0) + it.count end
		local parts = {}
		for id, c in pairs(counts) do table.insert(parts, CH.Window.ItemIcon(id, 12) .. c) end
		table.insert(lines, CH.Theme.Color("accent", to) .. "  " .. table.concat(parts, "  "))
	end
	local routes = {}
	for path, to in pairs(CH.Mail.Store().routes) do table.insert(routes, path .. " → " .. to) end
	table.sort(routes)
	list:SetText((#lines > 0 and table.concat(lines, "\n") or CH.Theme.Color("muted", "Nothing to send from this character."))
		.. "\n\n" .. CH.Theme.Color("muted", "Routes (set on the Groups page: right-click a group):\n" .. (#routes > 0 and table.concat(routes, "\n") or "none yet")))
	sendButton:SetEnabled(n > 0)
end

local function build()
	local T, Wd = CH.Theme, CH.Window
	frame = Wd.New("ClearinghouseMail", "Mail", 360, 320)
	local open = T.Button(frame, "Open all", 90, 22)
	open:SetPoint("TOPLEFT", 12, -36)
	open:SetScript("OnClick", function()
		status:SetText(T.Color("accent", "Opening ..."))
		CH.Mail.OpenAll(function(n, gold)
			status:SetText(string.format("Opened %d, %s collected. Cash on delivery left alone.", n, CH.FormatMoney(gold)))
			MUI.Refresh()
		end)
	end)
	sendButton = T.Button(frame, "Send", 80, 22)
	sendButton:SetPoint("TOPLEFT", 108, -36)
	sendButton:SetScript("OnClick", function()
		local to, n = CH.Mail.SendNext()
		if to then status:SetText(string.format("Sent %d to %s.", n, to)) end
		C_Timer.After(1, MUI.Refresh)
	end)
	frame.waiting = Wd.Text(frame, 12, -64, 336)
	status = Wd.Text(frame, 12, -82, 336)
	list = Wd.Text(frame, 12, -104, 336)
	list:SetJustifyV("TOP")
	T.Fonts(frame)
	frame:Hide()
end

CH.On("MAIL_SHOW", function()
	if not frame then build() end
	frame:ClearAllPoints()
	if MailFrame then frame:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", 4, 0) end
	frame:Show()
	MUI.Refresh()
end)
CH.On("MAIL_CLOSED", function() if frame then frame:Hide() end end)
CH.On("MAIL_INBOX_UPDATE", function() if frame and frame:IsShown() then MUI.Refresh() end end)
CH.On("BAG_UPDATE_DELAYED", function() if frame and frame:IsShown() then MUI.Refresh() end end)

function MUI.Build() if not frame then build() end return frame end
