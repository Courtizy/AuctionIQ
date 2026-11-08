-- Auctioning panel beside the Auction House: Post scan, then Post one click at a time; Cancel scan,
-- then Cancel one click at a time. The Warband counts as one seller (see Auction.lua).
local _, CH = ...

local AUI = {}
CH.AuctionUI = AUI
local frame, rows, status, postButton, skipButton, cancelButton
local W, H, N = 460, 470, 18
local plan, mode, confirmNext = {}, nil, false
local offset = 0
local pending -- the post sent and not yet answered: { e, n, before, token }
local WAIT = 4

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
	-- keep the entry the next click acts on in view
	local nextE = (pending and pending.e) or (mode and nextEntry(mode == "cancel" and "cancel" or "post"))
	-- (only when it moves on, so scrolling by hand still works)
	if nextE ~= AUI.lastNext then
		AUI.lastNext = nextE
		for k, e in ipairs(plan) do
			if e == nextE and (k <= offset or k > offset + N) then offset = math.max(0, k - 1) end
		end
	end
	offset = math.max(0, math.min(offset, #plan - N))
	for i, r in ipairs(rows) do
		local e = plan[i + offset]
		if e then
			local text = CH.Window.ItemIcon(e.id, 14) .. ((C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(e.id)) or ("item " .. e.id))
			r.cells[1]:SetText(e.done and not e.failed and T.Color("muted", text) or text)
			if e.d.action == "post" then
				r.cells[2]:SetText(e.d.qty .. " x " .. money(e.d.price))
			elseif e.d.action == "cancel" then
				r.cells[2]:SetText(money(e.price))
			else
				r.cells[2]:SetText("")
			end
			local c = e.failed and "bad" or e.done and "muted" or (e.d.action == "skip" or e.d.action == "keep") and "muted" or "ok"
			local label = e.failed and "failed: " or e.done and "done: " or (pending and pending.e == e) and "sending: " or (e.d.action .. ": ")
			r.cells[3]:SetText(T.Color(c, label .. (e.d.why or "")))
		else
			for _, c in ipairs(r.cells) do c:SetText("") end
		end
	end
	postButton:SetEnabled(mode == "post" and (confirmNext or (not pending and nextEntry("post") ~= nil)))
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
	plan, mode, offset = {}, "post", 0
	local held = CH.Auction.Postable()
	local ids = {}
	for id in pairs(held) do table.insert(ids, id) end
	table.sort(ids)
	searchAll(ids, function(id, results)
		local other, mine = CH.Auction.Lowest(results)
		table.insert(plan, { id = id, d = CH.Auction.Decide(id, results, held[id]), other = other, mine = mine, held = held[id] })
	end, function()
		table.sort(plan, function(a, b) return (a.d.action == "post" and 0 or 1) < (b.d.action == "post" and 0 or 1) end)
		local n = 0
		for _, e in ipairs(plan) do if e.d.action == "post" then n = n + 1 end end
		status:SetText(string.format("%d to post. Press Post (or bind a key) once for each.", n))
	end)
end

function AUI.CancelScan()
	plan, mode, offset = {}, "cancel", 0
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
				local other = CH.Auction.Lowest(results)
				table.insert(plan, { id = id, auctionID = a.auctionID, price = a.price, other = other, d = CH.Auction.DecideCancel(id, a.price, results) })
			end
		end, function()
			local n = 0
			for _, e in ipairs(plan) do if e.d.action == "cancel" then n = n + 1 end end
			status:SetText(string.format("%d undercut by someone outside your account. Cancel them one click each, then Post scan.", n))
		end)
	end)
end

local function itemName(id) return (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or ("item " .. id) end

-- The AH answered (or we gave up waiting): ok = it listed, else why not.
local function settle(ok, why)
	local p = pending
	if not p then return end
	pending, confirmNext = nil, false
	local e = p.e
	if ok then
		CH.Auction.Posted(e.id, p.n)
		e.posted = (e.posted or 0) + p.n
		if e.posted >= e.d.qty then
			e.done = true
		else
			e.d.why = string.format("posted %d of %d, press Post for the next", e.posted, e.d.qty)
		end
		status:SetText(CH.Theme.Color("ok", string.format("Posted %d x %s.", p.n, itemName(e.id))))
	else
		e.done, e.failed = true, true
		e.d.why = why
		status:SetText(CH.Theme.Color("bad", string.format("%s was not posted: %s", itemName(e.id), why)))
	end
	AUI.Refresh()
end
AUI.Settle = settle

-- No answer in time: if the item left your bags it went up, else it didn't.
local function waitFor(token)
	C_Timer.After(WAIT, function()
		if not pending or pending.token ~= token or confirmNext then return end
		if CH.Auction.InBags(pending.e.id) < pending.before then settle(true) else settle(false, pending.err or "the AH didn't take it, it's still in your bags") end
	end)
end

function AUI.PostNext()
	if confirmNext then
		confirmNext = false
		if C_AuctionHouse.ConfirmPostCommodity then pcall(C_AuctionHouse.ConfirmPostCommodity) end
		if C_AuctionHouse.ConfirmPostItem then pcall(C_AuctionHouse.ConfirmPostItem) end
		if pending then pending.token = {}; waitFor(pending.token) end
		return
	end
	if pending then return end
	local e = nextEntry("post")
	if not e then return end
	local before = CH.Auction.InBags(e.id)
	local n = CH.Auction.Post(e.id, e.d)
	if not n then
		e.done, e.failed, e.d.why = true, true, "none left in your bags"
	else
		pending = { e = e, n = n, before = before, token = {} }
		status:SetText(CH.Theme.Color("accent", string.format("Posting %d x %s, waiting for the AH ...", n, itemName(e.id))))
		waitFor(pending.token)
	end
	AUI.Refresh()
end

function AUI.CancelNext()
	local e = nextEntry("cancel")
	if e then C_AuctionHouse.CancelAuction(e.auctionID); e.done = true end
	AUI.Refresh()
end

function AUI.SkipNext()
	if pending and confirmNext then settle(false, "skipped at the price warning"); return end
	local e = nextEntry(mode == "cancel" and "cancel" or "post")
	if e then e.done = true; e.d.why = "skipped" end
	AUI.Refresh()
end

--- The whole story behind one row: what it will do and why, and the operation's prices.
function AUI.HoverLines(i)
	local e = plan[i + offset]
	if not e then return nil end
	local T, m = CH.Theme, money
	local lines = { { T.Color("accent", itemName(e.id)) } }
	local d = e.d
	if d.action == "post" then
		table.insert(lines, { "Posts", string.format("%d x %s", d.qty, m(d.price)) })
		if d.duration then table.insert(lines, { "Duration", ({ "12 hours", "24 hours", "48 hours" })[d.duration] or tostring(d.duration) }) end
	elseif d.action == "cancel" then
		table.insert(lines, { "Your listing", m(e.price) })
	end
	table.insert(lines, { (e.failed and "Failed: " or e.done and "Done: " or (d.action:gsub("^%l", string.upper) .. ": ")) .. (d.why or "") })
	if e.other then table.insert(lines, { "Cheapest outside your account", m(e.other) }) end
	if e.mine then table.insert(lines, { "Your cheapest listing", m(e.mine) }) end
	local p = CH.Groups.Prices(e.id)
	table.insert(lines, { T.Color("accent", "Operation " .. (p.op or "?")) })
	table.insert(lines, { "  Min / normal / max", m(p.min) .. " / " .. m(p.normal) .. " / " .. m(p.max) })
	table.insert(lines, { "  Post cap, live now", string.format("%d, %d up", p.cap or 0, CH.Auction.Listed(e.id)) })
	if e.held then table.insert(lines, { "  In bags", tostring(e.held) .. (p.keep and p.keep > 0 and (", keep " .. p.keep) or "") }) end
	if p.maxExpires and p.maxExpires > 0 and CH.Ledger.Available() then
		table.insert(lines, { "  Expired since last sale", string.format("%d (max %d)", CH.Ledger.NumExpires(e.id), p.maxExpires) })
	end
	if p.why then table.insert(lines, { T.Color("muted", p.why) }) end
	return lines
end

local function hover(owner, i)
	local lines = AUI.HoverLines(i)
	if lines then CH.Window.Tooltip(owner, lines) end
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
	rows = Wd.Table(frame, { { "Item", 12, 190 }, { "Post / price", 206, 100 }, { "Why", 310, 140, "LEFT" } }, N, -84, 20, nil, hover, W)
	Wd.Wheel(frame, N, function() return offset end, function(v) offset = v end, function() return #plan end, AUI.Refresh)
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
CH.On("AUCTION_HOUSE_AUCTION_CREATED", function() if pending and not confirmNext then settle(true) end end)
-- an error while waiting is only a likely reason: the bag check at the end decides
CH.On("UI_ERROR_MESSAGE", function(_, _, msg) if pending and not confirmNext and type(msg) == "string" then pending.err = msg end end)
CH.On("AUCTION_HOUSE_CLOSED", function() if pending then settle(false, "the AH closed before it answered") end end)
CH.On("AUCTION_HOUSE_POST_WARNING", function()
	confirmNext = true
	if status then status:SetText(CH.Theme.Color("bad", "The AH wants a confirmation for this price: press Post again to confirm, Skip to drop it.")) end
end)

-- Build the panel without the AH (tests).
function AUI.Build() if not frame then build() end return frame end
