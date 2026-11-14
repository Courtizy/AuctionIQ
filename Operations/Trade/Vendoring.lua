-- Vendoring: at a merchant, buy what the craft queue still needs that the merchant sells, and sell
-- junk.
--
--   Buy   the queue's shopping list (Queue.ShoppingList), for each reagent this merchant sells for
--         gold: what's still to buy, in stacks the merchant allows. Items sold for currencies or
--         other items are left alone.
--   Junk  poor quality (grey) items, and items the vendor pays more for than the AH would bring
--         (what one is worth to you after the cut, deposits and waiting, Expect.Value) that are in
--         no group and aren't gear. Gear stays: transmog and item levels aren't priced here.
--         A merchant buys back only the last 12 things sold, so the button sells at most JUNK_MAX
--         stacks a press, a few a second.
local _, CH = ...

local Vd = { STEP = 0.2, JUNK_MAX = 12 }
CH.Vendoring = Vd

local function name(id) return C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id) or ("item " .. id) end

-- One merchant slot: { index, id, price (copper for stack), stack, available, gold (sold for gold only) }.
local function merchantItem(i)
	local id = GetMerchantItemID and GetMerchantItemID(i)
	if not id then return nil end
	local price, stack, available, extended
	if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
		local info = C_MerchantFrame.GetItemInfo(i)
		if info then price, stack, available, extended = info.price, info.stackCount, info.numAvailable, info.hasExtendedCost end
	elseif GetMerchantItemInfo then
		local _, _, p, s, a, _, _, ext = GetMerchantItemInfo(i)
		price, stack, available, extended = p, s, a, ext
	end
	return { index = i, id = id, price = price or 0, stack = math.max(1, stack or 1), available = available or -1, gold = not extended and (price or 0) > 0 }
end

--- The queue's reagents this merchant sells for gold: { { index, id, qty, cost, each } }.
function Vd.BuyList()
	local sells = {}
	for i = 1, (GetMerchantNumItems and GetMerchantNumItems() or 0) do
		local m = merchantItem(i)
		if m and m.gold and not sells[m.id] then sells[m.id] = m end
	end
	local out = {}
	if not (CH.Queue and CH.Queue.ShoppingList) then return out end
	local ok, list = pcall(CH.Queue.ShoppingList)
	for _, r in ipairs(ok and list or {}) do
		local m = sells[r.itemID]
		if m and (r.buy or 0) > 0 then
			local qty = r.buy
			if m.available >= 0 then qty = math.min(qty, m.available * m.stack) end
			if qty > 0 then
				local each = m.price / m.stack
				-- sold in bundles (5 vials a purchase): whole bundles, enough to cover what's needed
				if m.stack > 1 then qty = math.ceil(qty / m.stack) * m.stack end
				out[#out + 1] = { index = m.index, id = m.id, qty = qty, each = each, cost = math.ceil(each * qty), stack = m.stack }
			end
		end
	end
	table.sort(out, function(a, b) return a.cost > b.cost end)
	return out
end

--- Buy the BuyList. done(bought, spent) when finished. Returns false and why when there's nothing.
function Vd.Buy(done)
	local list = Vd.BuyList()
	if #list == 0 then return false, "this merchant sells none of the queue's reagents still to buy" end
	local money = GetMoney and GetMoney() or math.huge
	local bought, spent = 0, 0
	for _, b in ipairs(list) do
		local left = b.qty
		if b.stack > 1 then
			-- one purchase is one bundle
			while left > 0 do
				local cost = math.ceil(b.each * b.stack)
				if cost > money - spent then break end
				BuyMerchantItem(b.index, 1)
				bought, spent, left = bought + b.stack, spent + cost, left - b.stack
			end
		else
			local max = GetMerchantItemMaxStack and GetMerchantItemMaxStack(b.index) or left
			while left > 0 do
				local n = math.min(left, math.max(1, max or left))
				local cost = math.ceil(b.each * n)
				if cost > money - spent then break end
				BuyMerchantItem(b.index, n)
				bought, spent, left = bought + n, spent + cost, left - n
			end
		end
	end
	if done then done(bought, spent) end
	return true, bought, spent
end

-- What a bag slot holds: { bag, slot, id, count, quality, vendor (copper each), link, bound }.
local function bagSlots()
	local out = {}
	local C = C_Container
	if not (C and C.GetContainerNumSlots and C.GetContainerItemInfo) then return out end
	local last = math.max(NUM_TOTAL_EQUIPPED_BAG_SLOTS or 0, Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag or 0, 4)
	for bag = 0, last do
		for slot = 1, (C.GetContainerNumSlots(bag) or 0) do
			local info = C.GetContainerItemInfo(bag, slot)
			if info and info.itemID then out[#out + 1] = { bag = bag, slot = slot, id = info.itemID, count = info.stackCount or 1,
				quality = info.quality, link = info.hyperlink, bound = info.isBound, noValue = info.hasNoValue, locked = info.isLocked } end
		end
	end
	return out
end

local function vendorPrice(id)
	local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	return get and select(11, get(id)) or 0
end

local function isGear(id)
	local instant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
	local classID = instant and select(6, instant(id))
	return classID == 2 or classID == 4
end

--- Junk in your bags, most gold first: { { bag, slot, id, count, gold, why } }. why: "grey" or
--- "vendor pays more" (than the AH would bring, for what's in no group and isn't gear).
function Vd.JunkList()
	local out = {}
	for _, s in ipairs(bagSlots()) do
		local each = vendorPrice(s.id) or 0
		if each > 0 and not s.noValue and not s.locked then
			local why
			if s.quality == 0 then
				why = "grey"
			elseif not isGear(s.id) and not (CH.Groups and CH.Groups.Path and CH.Groups.Path(s.id)) then
				local value = CH.Prices.Get("chvalue", "i:" .. s.id)
				local ah = value and (CH.Expect and CH.Expect.Value(s.id, value) or value * CH.AH_CUT)
				-- no AH price at all is unknown, not worthless: leave it
				if ah and ah < each then why = "vendor pays more" end
			end
			if why then out[#out + 1] = { bag = s.bag, slot = s.slot, id = s.id, count = s.count, gold = each * s.count, why = why } end
		end
	end
	table.sort(out, function(a, b) return a.gold > b.gold end)
	return out
end

local selling
--- Sell up to JUNK_MAX stacks of the JunkList, a few a second. done(sold, gold, left).
function Vd.Sell(done)
	if selling then return false, "already selling" end
	local list = Vd.JunkList()
	if #list == 0 then return false, "no junk in your bags" end
	local i, sold, gold = 0, 0, 0
	selling = true
	local function step()
		i = i + 1
		local j = list[i]
		if not j or i > Vd.JUNK_MAX or not Vd.open then
			selling = false
			if done then done(sold, gold, math.max(0, #list - sold)) end
			return
		end
		local info = C_Container.GetContainerItemInfo(j.bag, j.slot)
		if info and info.itemID == j.id then
			C_Container.UseContainerItem(j.bag, j.slot)
			sold, gold = sold + 1, gold + j.gold
		end
		C_Timer.After(Vd.STEP, step)
	end
	step()
	return true, math.min(#list, Vd.JUNK_MAX)
end

function Vd.Reset() selling = false end

-- The panel beside the merchant ---------------------------------------------------------------
local frame, status, buyButton, sellButton
local W, H = 300, 120

function Vd.Refresh()
	if not frame then return end
	local M = CH.FormatMoney
	local buys, junk = Vd.BuyList(), Vd.JunkList()
	local cost, gold = 0, 0
	for _, b in ipairs(buys) do cost = cost + b.cost end
	for _, j in ipairs(junk) do gold = gold + j.gold end
	buyButton:SetText(#buys > 0 and string.format("Buy queue reagents (%s)", M(cost, true)) or "Buy queue reagents")
	buyButton:SetEnabled(#buys > 0 and not selling)
	sellButton:SetText(#junk > 0 and string.format("Sell junk (%s)", M(gold, true)) or "Sell junk")
	sellButton:SetEnabled(#junk > 0 and not selling)
end

local function build()
	local T, Wd = CH.Theme, CH.Window
	frame = Wd.New("AuctionIQVendoring", "Vendoring", W, H)
	buyButton = T.Primary(T.Button(frame, "Buy queue reagents", W - 24, 22)); buyButton:SetPoint("TOPLEFT", 12, -36)
	buyButton:SetScript("OnClick", function()
		local ok, why = Vd.Buy(function(n, spent)
			status:SetText(T.Color("ok", string.format("Bought %d for %s.", n, CH.FormatMoney(spent))))
		end)
		if not ok then status:SetText(T.Color("bad", why)) end
		Vd.Refresh()
	end)
	sellButton = T.Button(frame, "Sell junk", W - 24, 22); sellButton:SetPoint("TOPLEFT", 12, -62)
	sellButton:SetScript("OnClick", function()
		local ok, n = Vd.Sell(function(sold, gold, left)
			status:SetText(T.Color("ok", string.format("Sold %d stack%s for %s%s.", sold, sold == 1 and "" or "s", CH.FormatMoney(gold),
				left > 0 and string.format("; %d more: press again (the merchant buys back only the last %d)", left, Vd.JUNK_MAX) or "")))
			Vd.Refresh()
		end)
		if ok then status:SetText(T.Color("accent", string.format("Selling %d stack%s ...", n, n == 1 and "" or "s")))
		else status:SetText(T.Color("bad", n)) end
		Vd.Refresh()
	end)
	status = Wd.Text(frame, 12, -90, W - 24)
	T.Fonts(frame)
	frame:Hide()
end

function Vd.Build() if not frame then build() end return frame end

CH.On("MERCHANT_SHOW", function()
	Vd.open = true
	if not frame then build() end
	frame:ClearAllPoints()
	if MerchantFrame then frame:SetPoint("TOPLEFT", MerchantFrame, "TOPRIGHT", 4, 0) end
	frame:Show()
	Vd.Refresh()
end)
CH.On("MERCHANT_CLOSED", function() Vd.open = false; if frame then frame:Hide() end end)
CH.On("BAG_UPDATE_DELAYED", function() if frame and frame:IsShown() and not selling then Vd.Refresh() end end)
