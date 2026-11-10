-- Mail panel beside the mailbox: Open all, then Send (one click per mail) by your group routes, and
-- the reagents each queued crafter is short of.
local _, CH = ...

local MUI = {}
CH.MailUI = MUI
local frame, status, list, sendButton, routeButton

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
		local reagents = false
		for _, it in ipairs(items) do
			counts[it.id] = (counts[it.id] or 0) + (it.send or it.count)
			reagents = reagents or it.reagent
		end
		local parts = {}
		for id, c in pairs(counts) do table.insert(parts, CH.Window.ItemIcon(id, 12) .. c) end
		table.insert(lines, CH.Theme.Color("accent", to) .. "  " .. table.concat(parts, "  ")
			.. (reagents and CH.Theme.Color("muted", "  (reagents for their queued crafts)") or ""))
	end
	local routes = {}
	for path, to in pairs(CH.Mail.Store().routes) do table.insert(routes, path .. " → " .. to) end
	table.sort(routes)
	local why = #routes == 0 and "Nothing to send yet: press Routes to pick which character gets each group."
		or "Nothing in your bags belongs to a routed group."
	list:SetText((#lines > 0 and table.concat(lines, "\n") or CH.Theme.Color("muted", why))
		.. "\n\n" .. CH.Theme.Color("muted", "Routes (Routes button, or right-click a group in Settings, Edit groups):\n" .. (#routes > 0 and table.concat(routes, "\n") or "none yet")))
	local nextTo = CH.Mail.NextTo()
	sendButton:SetEnabled(n > 0 and not MUI.sending)
	sendButton:SetText(MUI.sending and "Sending..." or nextTo and ("Send: " .. nextTo) or "Send")
	MUI.sendCount = n
end

local function build()
	local T, Wd = CH.Theme, CH.Window
	frame = Wd.New("AuctionIQMail", "Mail", 360, 320)
	local open = T.Button(frame, "Open all", 90, 22)
	open:SetPoint("TOPLEFT", 12, -36)
	open:SetScript("OnClick", function()
		status:SetText(T.Color("accent", "Opening ..."))
		CH.Mail.OpenAll(function(n, gold, why)
			status:SetText(string.format("Opened %d, %s collected. Cash on delivery left alone.", n, CH.FormatMoney(gold))
				.. (why and ("\n" .. T.Color("bad", why)) or ""))
			MUI.Refresh()
		end)
	end)
	sendButton = T.Primary(T.Button(frame, "Send", 140, 22))
	sendButton:SetPoint("TOPLEFT", 108, -36)
	sendButton:SetScript("OnClick", function()
		if MUI.sending then return end
		local to, n = CH.Mail.SendNext()
		if not to then return end
		-- sent only once the game says so (MAIL_SEND_SUCCESS), failed on MAIL_FAILED or no answer
		local s = { to = to, n = n }
		MUI.sending = s
		status:SetText(T.Color("accent", string.format("Sending %d to %s ...", n, to)))
		C_Timer.After(6, function() if MUI.sending == s then MUI.SendDone(false, "no answer from the mailbox") end end)
		MUI.Refresh()
	end)
	routeButton = T.Button(frame, "Routes", 80, 22)
	routeButton:SetPoint("TOPLEFT", 254, -36)
	routeButton:SetScript("OnClick", function(self) MUI.RouteMenu(self) end)
	frame.waiting = Wd.Text(frame, 12, -64, 336)
	status = Wd.Text(frame, 12, -82, 336)
	list = Wd.Text(frame, 12, -104, 336)
	list:SetJustifyV("TOP")
	frame.sendButton, frame.status = sendButton, status
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

--- The game answered the mail just sent (or it timed out).
function MUI.SendDone(ok, why)
	local s = MUI.sending
	if not s then return end
	MUI.sending = nil
	if status then
		status:SetText(ok and CH.Theme.Color("ok", string.format("Sent %d to %s.", s.n, s.to))
			or CH.Theme.Color("bad", string.format("Not sent to %s: %s", s.to, why or "the game refused it")))
	end
	MUI.Refresh()
end
CH.On("MAIL_SEND_SUCCESS", function() MUI.SendDone(true) end)
CH.On("MAIL_FAILED", function() MUI.SendDone(false, MUI.lastError) end)
CH.On("UI_ERROR_MESSAGE", function(_, _, msg) if MUI.sending and type(msg) == "string" then MUI.lastError = msg end end)
CH.On("MAIL_INBOX_UPDATE", function() if frame and frame:IsShown() then MUI.Refresh() end end)
CH.On("BAG_UPDATE_DELAYED", function() if frame and frame:IsShown() then MUI.Refresh() end end)

--- Routes from the mailbox: each group (two levels deep) with your characters to send it to.
function MUI.RouteMenu(owner)
	if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
	local routes = CH.Mail.Store().routes
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle("Send each group to")
		local tree = CH.Groups.Tree()
		if not tree[1] then root:CreateTitle("No groups yet: press Rebuild in Settings, Edit groups.") end
		for _, g in ipairs(tree) do
			if g.depth <= 2 then
				local sub = root:CreateButton(string.rep("  ", g.depth) .. g.name .. (routes[g.path] and ("  > " .. routes[g.path]) or ""))
				for _, c in ipairs(CH.Ledger.Characters()) do
					sub:CreateRadio(c.name, function() return routes[g.path] == c.name end,
						function() CH.Mail.Route(g.path, c.name); MUI.Refresh() end)
				end
				sub:CreateButton("Don't mail", function() CH.Mail.Route(g.path, nil); MUI.Refresh() end)
			end
		end
	end)
end

function MUI.Build() if not frame then build() end return frame end
