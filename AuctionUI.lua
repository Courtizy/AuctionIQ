-- Auctioning panel beside the Auction House: Post scan, then Post one click at a time; Cancel scan,
-- then Cancel one click at a time. The Warband counts as one seller (see Auction.lua).
local _, CH = ...

local AUI = {}
CH.AuctionUI = AUI
local frame, rows, status, postButton, skipButton, cancelButton
local W, H, N = 460, 470, 18
local plan, mode, confirmNext = {}, nil, false

local function money(c) return c and CH.FormatMoney(c) or "-" end

function AUI.Plan() return plan, mode end

local function nextEntry(kind)
	for _, e in ipairs(plan) do if e.d.action == kind and not e.done then return e end end
end

function AUI.Refresh()
	if not frame then return end
	local T = CH.Theme
	local todo = 0
	for _, e in ipairs(plan) do if (e.d.action == "post" or e.d.action == "cancel") and not e.done then todo = todo + 1 end end
	for i, r in ipairs(rows) do
		local e = plan[i]
		if e then
			local text = CH.Window.ItemIcon(e.id, 14) .. ((C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(e.id)) or ("item " .. e.id))
			r.cells[1]:SetText(e.done and T.Color("muted", text) or text)
			if e.d.action == "post" then
				r.cells[2]:SetText(e.d.qty .. " x " .. money(e.d.price))
			elseif e.d.action == "cancel" then
				r.cells[2]:SetText(money(e.price))
			else
				r.cells[2]:SetText("")
			end
			local c = e.done and "muted" or (e.d.action == "skip" or e.d.action == "keep") and "muted" or "ok"
			r.cells[3]:SetText(T.Color(c, (e.done and "done: " or (e.d.action .. ": ")) .. (e.d.why or "")))
		else
			for _, c in ipairs(r.cells) do c:SetText("") end
		end
	end
	postButton:SetEnabled(mode == "post" and nextEntry("post") ~= nil)
	cancelButton:SetEnabled(mode == "cancel" and nextEntry("cancel") ~= nil)
	if mode and todo == 0 and not AUI.busy then status:SetText(T.Color("muted", "Nothing left to " .. mode .. ".")) end
end

-- Search each item in turn, then decide.
local function searchAll(ids, decide, finish)
	local i = 0
	AUI.busy = true
	local function step()
		i = i + 1
		local id = ids[i]
		if not id then AUI.busy = false; finish(); AUI.Refresh(); return end
		status:SetText(CH.Theme.Color("accent", string.format("Searching %d / %d ...", i, #ids)))
		CH.Auction.Search(id, function(results)
			decide(id, results)
			AUI.Refresh()
			C_Timer.After(0.2, step)
		end)
	end
	step()
end

function AUI.PostScan()
	plan, mode = {}, "post"
	local held = CH.Auction.Postable()
	local ids = {}
	for id in pairs(held) do table.insert(ids, id) end
	table.sort(ids)
	searchAll(ids, function(id, results)
		table.insert(plan, { id = id, d = CH.Auction.Decide(id, results, held[id]) })
	end, function()
		table.sort(plan, function(a, b) return (a.d.action == "post" and 0 or 1) < (b.d.action == "post" and 0 or 1) end)
		local n = 0
		for _, e in ipairs(plan) do if e.d.action == "post" then n = n + 1 end end
		status:SetText(string.format("%d to post. Press Post (or bind a key) once for each.", n))
	end)
end

function AUI.CancelScan()
	plan, mode = {}, "cancel"
	status:SetText(CH.Theme.Color("accent", "Asking the AH for your auctions ..."))
	CH.Auction.QueryOwned(function(list)
		local byItem, ids = {}, {}
		for _, a in ipairs(list) do
			if CH.Groups.Path(a.id) then
				if not byItem[a.id] then byItem[a.id] = {}; table.insert(ids, a.id) end
				table.insert(byItem[a.id], a)
			end
		end
		searchAll(ids, function(id, results)
			for _, a in ipairs(byItem[id]) do
				table.insert(plan, { id = id, auctionID = a.auctionID, price = a.price, d = CH.Auction.DecideCancel(id, a.price, results) })
			end
		end, function()
			local n = 0
			for _, e in ipairs(plan) do if e.d.action == "cancel" then n = n + 1 end end
			status:SetText(string.format("%d undercut by someone outside your account. Cancel them one click each, then Post scan.", n))
		end)
	end)
end

function AUI.PostNext()
	if confirmNext then
		confirmNext = false
		if C_AuctionHouse.ConfirmPostCommodity then pcall(C_AuctionHouse.ConfirmPostCommodity) end
		if C_AuctionHouse.ConfirmPostItem then pcall(C_AuctionHouse.ConfirmPostItem) end
		return
	end
	local e = nextEntry("post")
	if e and CH.Auction.Post(e.id, e.d) then e.done = true end
	AUI.Refresh()
end

function AUI.CancelNext()
	local e = nextEntry("cancel")
	if e then C_AuctionHouse.CancelAuction(e.auctionID); e.done = true end
	AUI.Refresh()
end

function AUI.SkipNext()
	local e = nextEntry(mode == "cancel" and "cancel" or "post")
	if e then e.done = true; e.d.why = "skipped" end
	AUI.Refresh()
end

local function build()
	local T, Wd = CH.Theme, CH.Window
	frame = Wd.New("ClearinghouseAuction", "Auctioning", W, H)
	local b1 = T.Button(frame, "Post scan", 100, 22); b1:SetPoint("TOPLEFT", 12, -36); b1:SetScript("OnClick", AUI.PostScan)
	postButton = T.Button(frame, "Post", 80, 22); postButton:SetPoint("TOPLEFT", 118, -36); postButton:SetScript("OnClick", AUI.PostNext)
	local b3 = T.Button(frame, "Cancel scan", 100, 22); b3:SetPoint("TOPLEFT", 216, -36); b3:SetScript("OnClick", AUI.CancelScan)
	cancelButton = T.Button(frame, "Cancel", 70, 22); cancelButton:SetPoint("TOPLEFT", 322, -36); cancelButton:SetScript("OnClick", AUI.CancelNext)
	skipButton = T.Button(frame, "Skip", 50, 22); skipButton:SetPoint("TOPLEFT", 398, -36); skipButton:SetScript("OnClick", AUI.SkipNext)
	status = Wd.Text(frame, 12, -64, W - 24)
	status:SetText(CH.Theme.Color("muted", "Your whole Warband counts as one seller: your own listings are never undercut."))
	rows = Wd.Table(frame, { { "Item", 12, 190 }, { "Post / price", 206, 100 }, { "Why", 310, 140, "LEFT" } }, N, -84, 20, nil, nil, W)
	T.Fonts(frame)
	frame:Hide()
end

CH.On("AUCTION_HOUSE_SHOW", function()
	if not frame then build() end
	frame:ClearAllPoints()
	if AuctionHouseFrame then frame:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 4, 0) end
	frame:Show()
end)
CH.On("AUCTION_HOUSE_CLOSED", function() if frame then frame:Hide() end end)
CH.On("AUCTION_HOUSE_POST_WARNING", function()
	confirmNext = true
	if status then status:SetText(CH.Theme.Color("bad", "The AH wants a confirmation for this price: press Post again to confirm, Skip to drop it.")) end
end)

-- Build the panel without the AH (tests).
function AUI.Build() if not frame then build() end return frame end
