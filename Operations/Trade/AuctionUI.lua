-- Buying panel beside the Auction House, for what TSM doesn't know about. Posting and cancelling are
-- TSM's Auctioning tab: Ready to post reads the same operations, so the prices are the same.
--   Shop queue  buy what AuctionIQ's craft queue still needs, priced by walking the listings, and
--               skipped when it's 25% over the usual price or over a TSM Shopping max price
--   Deals       search the top deals (Deals.lua) again and buy the units still under their return
-- Each buy is one click for a quote and a second to confirm (a purchase needs your click).
local _, CH = ...

local AUI = {}
CH.AuctionUI = AUI
local frame, rows, status, skipButton, buyButton, scrollBar
local W, H, N = 460, 470, 17
local plan, mode = {}, nil
local offset = 0
local buying  -- the buy asked for: { e, quoted = { unit, total } once the AH quotes it, confirmed }
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
	for _, e in ipairs(plan) do if e.d.action == "buy" and not e.done then todo = todo + 1 end end
	-- keep the entry the next click acts on in view
	local nextE = (buying and buying.e) or (mode and nextEntry("buy"))
	-- (only when it moves on, so scrolling by hand still works)
	if nextE ~= AUI.lastNext then
		AUI.lastNext = nextE
		for k, e in ipairs(plan) do
			if e == nextE and (k <= offset or k > offset + N) then offset = math.max(0, k - 1) end
		end
	end
	offset = math.max(0, math.min(offset, #plan - N))
	scrollBar:Set(offset, N, #plan)
	for i, r in ipairs(rows) do
		local e = plan[i + offset]
		if e then
			local text = CH.Window.ItemIcon(e.id, 14) .. ((C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(e.id)) or ("item " .. e.id))
				.. (e.level and T.Color("muted", " ilvl " .. e.level) or "")
			r.cells[1]:SetText(e.done and not e.failed and T.Color("muted", text) or text)
			if e.d.qty then
				r.cells[2]:SetText(e.d.qty .. " x " .. money(e.d.unit))
			else
				r.cells[2]:SetText("")
			end
			local c = e.failed and "bad" or e.done and "muted" or (e.d.action == "skip" or e.d.action == "keep") and "muted" or "ok"
			local label = e.failed and "failed: " or e.done and "done: " or (buying and buying.e == e) and (buying and buying.quoted and "confirm: " or "sending: ") or (e.d.action .. ": ")
			r.cells[3]:SetText(T.Color(c, label .. (e.d.why or "")))
		else
			for _, c in ipairs(r.cells) do c:SetText("") end
		end
	end
	buyButton:SetEnabled(mode == "shop" and ((buying and buying.quoted) or (not buying and nextEntry("buy") ~= nil)))
	buyButton:SetText(buying and buying.quoted and "Confirm" or "Buy")
	if mode and todo == 0 and not AUI.busy then status:SetText(T.Color("muted", "Nothing left to buy.")) end
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

local function itemName(id, level)
	return ((C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or ("item " .. id)) .. (level and (" (ilvl " .. level .. ")") or "")
end

function AUI.SkipNext()
	if buying then local b = buying; buying = nil; b.e.done, b.e.d.why = true, "skipped"
		if C_AuctionHouse.CancelCommoditiesPurchase then pcall(C_AuctionHouse.CancelCommoditiesPurchase) end
		AUI.Refresh(); return end
	local e = nextEntry("buy")
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
	-- only what's listed can be bought: price that, and keep the shortage apart
	local short = d.short
	if short > 0 then
		why = why .. string.format(", only %d listed", s.buy - short)
		if s.buy - short <= 0 then return { action = "skip", qty = s.buy, short = short, why = "none listed" } end
		d = CH.Depth.Cost(s.itemID, s.buy - short)
	end
	-- a TSM Shopping operation's maximum price: buy only what's listed at or under it (the AH
	-- sells commodities cheapest first, so n units under it cost no more than it each)
	local rule = CH.Groups.ShopRule and CH.Groups.ShopRule(s.itemID)
	if rule and rule.maxPrice then
		local rows = CH.Depth.Book(s.itemID)
		local under = 0
		for _, r in ipairs(rows or {}) do if r[1] <= rule.maxPrice then under = under + r[2] end end
		local want = s.buy - short
		if under <= 0 then
			return { action = "skip", qty = s.buy, unit = d.unit, why = string.format("over %s's max price %s", rule.op, money(rule.maxPrice)) }
		elseif under < want then
			short = short + (want - under)
			why = why .. string.format(", only %d at or under %s", under, money(rule.maxPrice))
			d = CH.Depth.Cost(s.itemID, under)
		end
	end
	if usual and d.unit > usual * AUI.SHOP_OVER then
		return { action = "skip", qty = s.buy, unit = d.unit, why = string.format("%d%% over the usual %s", math.floor((d.unit / usual - 1) * 100 + 0.5), money(usual)) }
	end
	return { action = "buy", qty = s.buy - short, unit = d.unit, cost = d.cost, short = short > 0 and short or nil, why = why }
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
		local n, total, short = 0, 0, 0
		for _, e in ipairs(plan) do
			if e.d.action == "buy" then n, total = n + 1, total + (e.d.cost or 0) end
			if e.d.short then short = short + 1 end
		end
		status:SetText(string.format("%d to buy for about %s. Press Buy for a quote, then Confirm.", n, money(total))
			.. (short > 0 and CH.Theme.Color("bad", string.format("  %d reagent%s not fully listed: still short after buying.", short, short == 1 and " is" or "s are")) or ""))
	end)
end

-- Deals: listings well under what they resell for (Deals.lua) -------------------------------
--- Decide one deal from the AH's listings now: buy the units still under the deal's most per unit
--- (what one brings back, less the deal's minimum return), up to a week of sales; skip it when the
--- listings moved or it isn't a commodity (the AH buys gear and pets from its own list, one click each).
function AUI.DecideDeal(d, results, commodity)
	if results then CH.Depth.Remember(d.id, results) end
	local max = d.each / (1 + CH.Deals.MIN_ROI)
	local rows = CH.Depth.Book(d.id)
	local n, spent = 0, 0
	for _, r in ipairs(rows or {}) do
		if r[1] > max then break end
		local take = math.min(r[2], d.buy - n)
		n, spent = n + take, spent + take * r[1]
		if n >= d.buy then break end
	end
	if n <= 0 then
		local first = rows and rows[1] and rows[1][1]
		return { action = "skip", qty = d.buy, why = first and string.format("gone: the cheapest is %s now, over %s", money(first), money(max)) or "gone: none listed" }
	end
	local gain = d.each * n - spent
	local why = string.format("each brings %s back, +%s", money(d.each), money(gain))
	if not commodity then
		return { action = "skip", qty = n, unit = spent / n, why = "not a commodity: buy it in the AH's list, " .. why }
	end
	return { action = "buy", qty = n, unit = spent / n, cost = spent, why = why, gain = gain }
end

--- Search every deal on the AH now and line up the buys: Buy for a quote, then Confirm.
function AUI.DealScan()
	plan, mode, offset, buying = {}, "shop", 0, nil
	local deals = CH.Deals.List()
	if #deals == 0 then
		status:SetText(CH.Theme.Color("muted", "No deals in what the AH has shown lately. A full scan (TSM's, or browsing) finds more."))
		AUI.Refresh()
		return
	end
	local byID, ids = {}, {}
	for i, d in ipairs(deals) do
		if i > 20 then break end
		byID[d.id] = d; table.insert(ids, d.id)
	end
	searchAll(ids, function(id, results)
		table.insert(plan, { id = id, d = AUI.DecideDeal(byID[id], results, CH.Auction.IsCommodity(id)) })
	end, function()
		table.sort(plan, function(a, b) return (a.d.action == "buy" and 0 or 1) < (b.d.action == "buy" and 0 or 1) end)
		local n, total, gain = 0, 0, 0
		for _, e in ipairs(plan) do
			if e.d.action == "buy" then n, total, gain = n + 1, total + (e.d.cost or 0), gain + (e.d.gain or 0) end
		end
		status:SetText(string.format("%d deals to buy for about %s, bringing about %s more back. Press Buy for a quote, then Confirm.", n, money(total), money(gain)))
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
	table.insert(lines, { (e.failed and "Failed: " or e.done and "Done: " or (d.action:gsub("^%l", string.upper) .. ": ")) .. (d.why or "") })
	if d.qty then table.insert(lines, { "Buys", string.format("%d x %s", d.qty, m(d.unit)) }) end
	if d.cost then table.insert(lines, { "Total, walking the listings", m(d.cost) }) end
	if d.gain then table.insert(lines, { "Brings back over its cost", m(d.gain) }) end
	table.insert(lines, { "Usual price (chmat)", m(CH.Prices.Get("chmat", "i:" .. e.id)) })
	return lines
end

local function hover(owner, i)
	local lines = AUI.HoverLines(i)
	if lines then CH.Window.Tooltip(owner, lines) end
end

local function build()
	local T, Wd = CH.Theme, CH.Window
	frame = Wd.New("AuctionIQAuction", "AuctionIQ buying", W, H)
	local b4 = T.Button(frame, "Shop queue", 100, 22); b4:SetPoint("TOPLEFT", 12, -36); b4:SetScript("OnClick", AUI.ShopScan)
	local b5 = T.Button(frame, "Deals", 70, 22); b5:SetPoint("TOPLEFT", 118, -36); b5:SetScript("OnClick", AUI.DealScan)
	buyButton = T.Primary(T.Button(frame, "Buy", 80, 22)); buyButton:SetPoint("TOPLEFT", 194, -36); buyButton:SetScript("OnClick", AUI.BuyNext)
	skipButton = T.Button(frame, "Skip", 50, 22); skipButton:SetPoint("TOPLEFT", 280, -36); skipButton:SetScript("OnClick", AUI.SkipNext)
	status = Wd.Text(frame, 12, -64, W - 24)
	status:SetText(CH.Theme.Color("muted", "Buys your craft queue's reagents and the best deals. Post and cancel with TSM's Auctioning tab: it uses the same rules."))
	rows = Wd.Table(frame, { { "Item", 12, 190 }, { "Buy / price", 206, 100 }, { "Why", 310, 140, "LEFT" } }, N, -84, 20, nil, hover, W)
	scrollBar = Wd.ScrollBar(frame, W - 10, -102, N * 20)
	Wd.Wheel(frame, N, function() return offset end, function(v) offset = v end, function() return #plan end, AUI.Refresh, scrollBar)
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

-- Build the panel without the AH (tests).
function AUI.Build() if not frame then build() end return frame end
