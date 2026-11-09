-- Auctioning panel beside the Auction House: Post scan, then Post one click at a time; Cancel scan,
-- then Cancel one click at a time; Shop queue, then Buy the crafting queue's reagents one click at a
-- time (each buy is quoted first and needs a second click to confirm). The Warband counts as one seller (see Auction.lua).
local _, CH = ...

local AUI = {}
CH.AuctionUI = AUI
local frame, rows, status, postButton, skipButton, cancelButton, buyButton
local W, H, N = 460, 470, 17
local plan, mode, confirmNext = {}, nil, false
local offset = 0
local pending -- the post sent and not yet answered: { e, n, before, token }
local buying  -- the buy asked for: { e, quoted = { unit, total } once the AH quotes it, confirmed }
local WAIT = 4

local function money(c) return c and CH.FormatMoney(c) or "-" end

function AUI.Plan() return plan, mode end

-- What the next click does in each mode.
local KIND = { post = "post", cancel = "cancel", shop = "buy" }
local function kindOf(m) return KIND[m] or "post" end

local function nextEntry(kind)
	for _, e in ipairs(plan) do if e.d.action == kind and not e.done then return e end end
end

function AUI.Refresh()
	if not frame then return end
	local T = CH.Theme
	local todo = 0
	for _, e in ipairs(plan) do if (e.d.action == "post" or e.d.action == "cancel" or e.d.action == "buy") and not e.done then todo = todo + 1 end end
	-- keep the entry the next click acts on in view
	local nextE = (pending and pending.e) or (mode and nextEntry(kindOf(mode)))
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
				.. (e.level and T.Color("muted", " ilvl " .. e.level) or "")
			r.cells[1]:SetText(e.done and not e.failed and T.Color("muted", text) or text)
			if e.d.action == "post" then
				r.cells[2]:SetText(e.d.qty .. " x " .. money(e.d.price))
			elseif e.d.action == "cancel" then
				r.cells[2]:SetText(money(e.price))
			elseif e.d.action == "buy" or (mode == "shop" and e.d.qty) then
				r.cells[2]:SetText(e.d.qty .. " x " .. money(e.d.unit))
			else
				r.cells[2]:SetText("")
			end
			local c = e.failed and "bad" or e.done and "muted" or (e.d.action == "skip" or e.d.action == "keep") and "muted" or "ok"
			local label = e.failed and "failed: " or e.done and "done: " or ((pending and pending.e == e) or cancelling == e or (buying and buying.e == e)) and (buying and buying.quoted and "confirm: " or "sending: ") or (e.d.action .. ": ")
			r.cells[3]:SetText(T.Color(c, label .. (e.d.why or "")))
		else
			for _, c in ipairs(r.cells) do c:SetText("") end
		end
	end
	postButton:SetEnabled(mode == "post" and (confirmNext or (not pending and nextEntry("post") ~= nil)))
	cancelButton:SetEnabled(mode == "cancel" and nextEntry("cancel") ~= nil)
	buyButton:SetEnabled(mode == "shop" and ((buying and buying.quoted) or (not buying and nextEntry("buy") ~= nil)))
	buyButton:SetText(buying and buying.quoted and "Confirm" or "Buy")
	if mode and todo == 0 and not AUI.busy then status:SetText(T.Color("muted", "Nothing left to " .. (mode == "shop" and "buy" or mode) .. ".")) end
end

-- Search each item in turn (gear once per item level: { id, level }), then decide.
local function searchAll(ids, decide, finish)
	local i = 0
	AUI.busy = true
	local function step()
		i = i + 1
		local item = ids[i]
		if not item then AUI.busy = false; finish(); AUI.Refresh(); return end
		local id, level = type(item) == "table" and item.id or item, type(item) == "table" and item.level or nil
		status:SetText(CH.Theme.Color("accent", string.format("Searching %d / %d ...", i, #ids)))
		CH.Auction.Search(id, function(results)
			decide(id, results, level, item)
			AUI.Refresh()
			C_Timer.After(0.2, step)
		end, level)
	end
	step()
end

function AUI.PostScan()
	plan, mode, offset = {}, "post", 0
	local _, items = CH.Auction.Postable()
	searchAll(items, function(id, results, level, item)
		local other, mine = CH.Auction.Lowest(results)
		table.insert(plan, { id = id, level = level, d = CH.Auction.Decide(id, results, item.count, level), other = other, mine = mine, held = item.count })
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
				local key = a.id .. ":" .. (a.level or 0) -- gear: each item level against its own listings
				if not byItem[key] then byItem[key] = {}; table.insert(ids, { id = a.id, level = a.level, key = key }) end
				table.insert(byItem[key], a)
			end
		end
		searchAll(ids, function(id, results, level, item)
			for _, a in ipairs(byItem[item.key]) do
				local other = CH.Auction.Lowest(results)
				table.insert(plan, { id = id, level = level, auctionID = a.auctionID, price = a.price, other = other, d = CH.Auction.DecideCancel(id, a.price, results, level) })
			end
		end, function()
			local n = 0
			for _, e in ipairs(plan) do if e.d.action == "cancel" then n = n + 1 end end
			status:SetText(string.format("%d undercut by someone outside your account. Cancel them one click each, then Post scan.", n))
		end)
	end)
end

local function itemName(id, level)
	return ((C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or ("item " .. id)) .. (level and (" (ilvl " .. level .. ")") or "")
end

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
		status:SetText(CH.Theme.Color("ok", string.format("Posted %d x %s.", p.n, itemName(e.id, e.level))))
	else
		e.done, e.failed = true, true
		e.d.why = why
		status:SetText(CH.Theme.Color("bad", string.format("%s was not posted: %s", itemName(e.id, e.level), why)))
	end
	AUI.Refresh()
end
AUI.Settle = settle

-- No answer in time: if the item left your bags it went up, else it didn't.
local function waitFor(token)
	C_Timer.After(WAIT, function()
		if not pending or pending.token ~= token or confirmNext then return end
		if CH.Auction.InBags(pending.e.id, pending.e.level) < pending.before then settle(true) else settle(false, pending.err or "the AH didn't take it, it's still in your bags") end
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
	local before = CH.Auction.InBags(e.id, e.level)
	local n = CH.Auction.Post(e.id, e.d, e.level)
	if not n then
		e.done, e.failed, e.d.why = true, true, "none left in your bags"
	else
		pending = { e = e, n = n, before = before, token = {} }
		status:SetText(CH.Theme.Color("accent", string.format("Posting %d x %s, waiting for the AH ...", n, itemName(e.id, e.level))))
		waitFor(pending.token)
	end
	AUI.Refresh()
end

-- A cancel waits for the AH to say it's gone (AUCTION_CANCELED) before the row counts as done.
local cancelling
local function cancelSettled(ok, why)
	local e = cancelling
	if not e then return end
	cancelling = nil
	e.done = true
	if ok then
		status:SetText(CH.Theme.Color("ok", "Cancelled " .. itemName(e.id, e.level) .. "."))
	else
		e.failed, e.d.why = true, why
		status:SetText(CH.Theme.Color("bad", itemName(e.id, e.level) .. " was not cancelled: " .. why))
	end
	AUI.Refresh()
end
AUI.CancelSettled = cancelSettled

function AUI.CancelNext()
	if cancelling then return end
	local e = nextEntry("cancel")
	if not e then return end
	cancelling, e.err = e, nil
	C_AuctionHouse.CancelAuction(e.auctionID)
	status:SetText(CH.Theme.Color("accent", "Cancelling " .. itemName(e.id, e.level) .. ", waiting for the AH ..."))
	C_Timer.After(WAIT, function()
		if cancelling == e then cancelSettled(false, e.err or "the AH didn't answer, Cancel scan to check") end
	end)
	AUI.Refresh()
end
CH.On("AUCTION_CANCELED", function(_, auctionID)
	if cancelling and (auctionID == nil or auctionID == cancelling.auctionID) then cancelSettled(true) end
end)
CH.On("UI_ERROR_MESSAGE", function(_, _, msg) if cancelling and type(msg) == "string" then cancelling.err = msg end end)
CH.On("AUCTION_HOUSE_CLOSED", function() cancelSettled(false, "the AH closed before it answered") end)

function AUI.SkipNext()
	if pending and confirmNext then settle(false, "skipped at the price warning"); return end
	if buying then local b = buying; buying = nil; b.e.done, b.e.d.why = true, "skipped"
		if C_AuctionHouse.CancelCommoditiesPurchase then pcall(C_AuctionHouse.CancelCommoditiesPurchase) end
		AUI.Refresh(); return end
	local e = nextEntry(kindOf(mode))
	if e then e.done = true; e.d.why = "skipped" end
	AUI.Refresh()
end

-- Shopping: the crafting queue's reagents ---------------------------------------------------
AUI.SHOP_OVER = 1.25 -- skip a buy whose live price is this much over the usual (chmat) price

--- Decide one shopping row from the AH's listings: buy (with the live average unit price for the
--- quantity) or skip, and why.
function AUI.DecideBuy(s, results)
	if results then CH.Depth.Remember(s.itemID, results) end
	local d = CH.Depth.Cost(s.itemID, s.buy)
	local usual = CH.Prices.Get("chmat", "i:" .. s.itemID)
	local why = string.format("need %d, have %d", s.need, s.have)
	if not d or d.source ~= "ah" then return { action = "skip", qty = s.buy, why = "no listings on the AH" } end
	if d.short > 0 then why = why .. string.format(", only %d listed", s.buy - d.short) end
	if usual and d.unit > usual * AUI.SHOP_OVER then
		return { action = "skip", qty = s.buy, unit = d.unit, why = string.format("%d%% over the usual %s", math.floor((d.unit / usual - 1) * 100 + 0.5), money(usual)) }
	end
	return { action = "buy", qty = s.buy - d.short, unit = d.unit, cost = d.cost, why = why }
end

function AUI.ShopScan()
	plan, mode, offset, buying = {}, "shop", 0, nil
	local need = {}
	for _, s in ipairs(CH.Queue.ShoppingList()) do if s.buy > 0 then table.insert(need, s) end end
	if #need == 0 then
		status:SetText(CH.Theme.Color("muted", "Nothing to buy: the crafting queue's reagents are all in your bags, bank or Warband bank."))
		AUI.Refresh()
		return
	end
	local byID, ids = {}, {}
	for _, s in ipairs(need) do byID[s.itemID] = s; table.insert(ids, s.itemID) end
	searchAll(ids, function(id, results)
		table.insert(plan, { id = id, d = AUI.DecideBuy(byID[id], results) })
	end, function()
		table.sort(plan, function(a, b) return (a.d.action == "buy" and 0 or 1) < (b.d.action == "buy" and 0 or 1) end)
		local n, total = 0, 0
		for _, e in ipairs(plan) do if e.d.action == "buy" then n, total = n + 1, total + (e.d.cost or 0) end end
		status:SetText(string.format("%d to buy for about %s. Press Buy for a quote, then Confirm.", n, money(total)))
	end)
end

local function buySettled(ok, why)
	local b = buying
	if not b then return end
	buying = nil
	local e = b.e
	e.done = true
	if ok then
		e.d.why = "bought for " .. money(b.quoted and b.quoted.total)
		status:SetText(CH.Theme.Color("ok", string.format("Bought %d x %s.", e.d.qty, itemName(e.id))))
	else
		e.failed, e.d.why = true, why
		status:SetText(CH.Theme.Color("bad", itemName(e.id) .. " was not bought: " .. why))
	end
	AUI.Refresh()
end
AUI.BuySettled = buySettled

--- First click: ask the AH for a quote. Second click: confirm it (a purchase needs your click).
function AUI.BuyNext()
	local AH = C_AuctionHouse
	if buying then
		if not buying.quoted or buying.confirmed then return end
		buying.confirmed = true
		AH.ConfirmCommoditiesPurchase(buying.e.id, buying.e.d.qty)
		status:SetText(CH.Theme.Color("accent", "Buying " .. itemName(buying.e.id) .. ", waiting for the AH ..."))
		local b = buying
		C_Timer.After(WAIT * 2, function() if buying == b then buySettled(false, "the AH didn't answer, check your bags") end end)
		AUI.Refresh()
		return
	end
	local e = nextEntry("buy")
	if not e then return end
	buying = { e = e }
	AH.StartCommoditiesPurchase(e.id, e.d.qty)
	status:SetText(CH.Theme.Color("accent", "Asking the AH for a price on " .. e.d.qty .. " x " .. itemName(e.id) .. " ..."))
	local b = buying
	C_Timer.After(WAIT, function() if buying == b and not b.quoted then buySettled(false, "no price from the AH") end end)
	AUI.Refresh()
end

CH.On("COMMODITY_PRICE_UPDATED", function(_, unit, total)
	if not buying or buying.quoted then return end
	buying.quoted = { unit = unit, total = total }
	local e = buying.e
	local moved = e.d.unit and unit and unit > e.d.unit * 1.05
	local T = CH.Theme
	status:SetText(T.Color(moved and "bad" or "accent", string.format("%d x %s for %s (%s each)%s. Press Confirm to buy, Skip to drop it.",
		e.d.qty, itemName(e.id), money(total), money(unit),
		moved and string.format(", %d%% over the scan", math.floor((unit / e.d.unit - 1) * 100 + 0.5)) or "")))
	AUI.Refresh()
end)
CH.On("COMMODITY_PRICE_UNAVAILABLE", function() buySettled(false, "the AH has no price for it now") end)
CH.On("COMMODITY_PURCHASE_SUCCEEDED", function() if buying and buying.confirmed then buySettled(true) end end)
CH.On("COMMODITY_PURCHASE_FAILED", function() buySettled(false, (buying and buying.err) or "the AH refused the purchase") end)
CH.On("UI_ERROR_MESSAGE", function(_, _, msg) if buying and type(msg) == "string" then buying.err = msg end end)
CH.On("AUCTION_HOUSE_CLOSED", function() buySettled(false, "the AH closed before it answered") end)

--- The whole story behind one row: what it will do and why, and the operation's prices.
function AUI.HoverLines(i)
	local e = plan[i + offset]
	if not e then return nil end
	local T, m = CH.Theme, money
	local lines = { { T.Color("accent", itemName(e.id, e.level)) } }
	local d = e.d
	if d.action == "post" then
		table.insert(lines, { "Posts", string.format("%d x %s", d.qty, m(d.price)) })
		if d.duration then table.insert(lines, { "Duration", ({ "12 hours", "24 hours", "48 hours" })[d.duration] or tostring(d.duration) }) end
	elseif d.action == "cancel" then
		table.insert(lines, { "Your listing", m(e.price) })
	end
	if mode == "shop" then
		table.insert(lines, { (e.failed and "Failed: " or e.done and "Done: " or (d.action:gsub("^%l", string.upper) .. ": ")) .. (d.why or "") })
		if d.qty then table.insert(lines, { "Buys", string.format("%d x %s", d.qty, m(d.unit)) }) end
		if d.cost then table.insert(lines, { "Total, walking the listings", m(d.cost) }) end
		table.insert(lines, { "Usual price (chmat)", m(CH.Prices.Get("chmat", "i:" .. e.id)) })
		return lines
	end
	table.insert(lines, { (e.failed and "Failed: " or e.done and "Done: " or (d.action:gsub("^%l", string.upper) .. ": ")) .. (d.why or "") })
	if e.other then table.insert(lines, { "Cheapest outside your account", m(e.other) }) end
	if e.mine then table.insert(lines, { "Your cheapest listing", m(e.mine) }) end
	local p = CH.Groups.Prices(e.id, nil, e.level)
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
	local b4 = T.Button(frame, "Shop queue", 100, 22); b4:SetPoint("TOPLEFT", 12, -62); b4:SetScript("OnClick", AUI.ShopScan)
	buyButton = T.Button(frame, "Buy", 80, 22); buyButton:SetPoint("TOPLEFT", 118, -62); buyButton:SetScript("OnClick", AUI.BuyNext)
	status = Wd.Text(frame, 12, -90, W - 24)
	status:SetText(CH.Theme.Color("muted", "Your whole Warband counts as one seller: your own listings are never undercut."))
	rows = Wd.Table(frame, { { "Item", 12, 190 }, { "Post / price", 206, 100 }, { "Why", 310, 140, "LEFT" } }, N, -110, 20, nil, hover, W)
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
