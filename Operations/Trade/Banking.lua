-- Banking: move a group's items between your bags and the Warband bank in one click.
--
-- With the bank open on its Warband tab, pick a group (yours, AuctionIQ's automatic ones or TSM's)
-- and press To Warband bank or To bags. Every stack of the group's items moves, a few a second
-- (the server drops moves sent too fast), skipping what the Warband bank won't take (soulbound
-- items) and stopping when the bags or the bank are full.
local _, CH = ...

local Bk = { STEP = 0.15 } -- seconds between moves
CH.Banking = Bk

local function enumBags()
	local B = Enum and Enum.BagIndex or {}
	local bags, bank = {}, {}
	local last = math.max(NUM_TOTAL_EQUIPPED_BAG_SLOTS or 0, B.ReagentBag or 0, 4)
	for bag = 0, last do bags[#bags + 1] = bag end
	for i = 1, 8 do if B["AccountBankTab_" .. i] then bank[#bank + 1] = B["AccountBankTab_" .. i] end end
	return bags, bank
end
Bk.Containers = enumBags

local function slots(list)
	local out = {}
	local C = C_Container
	if not (C and C.GetContainerNumSlots and C.GetContainerItemInfo) then return out end
	for _, bag in ipairs(list) do
		local ok, n = pcall(C.GetContainerNumSlots, bag)
		for slot = 1, (ok and n or 0) do
			local info = C.GetContainerItemInfo(bag, slot)
			out[#out + 1] = { bag = bag, slot = slot, id = info and info.itemID, count = info and info.stackCount or 0, bound = info and info.isBound }
		end
	end
	return out
end

-- Whether the Warband bank takes the item in that slot (soulbound items stay with the character).
local function allowed(s)
	local loc = ItemLocation and ItemLocation.CreateFromBagAndSlot and ItemLocation:CreateFromBagAndSlot(s.bag, s.slot)
	if C_Bank and C_Bank.IsItemAllowedInBankType and Enum.BankType and loc then
		local ok, yes = pcall(C_Bank.IsItemAllowedInBankType, Enum.BankType.Account, loc)
		if ok then return yes and true or false end
	end
	return not s.bound
end

--- Whether the Warband bank is open to move items into and out of.
function Bk.Open()
	if not (C_Bank and C_Bank.CanUseBank and Enum and Enum.BankType) then return Bk.bankOpen and true or false end
	local ok, yes = pcall(C_Bank.CanUseBank, Enum.BankType.Account)
	return ok and yes and true or false
end

-- Whether a group path is `path` or under it.
local function within(p, path)
	local sep = CH.Groups.SEP or "/"
	return p == path or p:sub(1, #path + #sep) == path .. sep
end

--- How many of each group's items are in your bags and in the Warband bank, for groups that have
--- any: { { path, name, depth, bags, bank } }, in the groups' order. Works from what you hold (each
--- item's group, counted into it and the groups above it), not from the groups: TSM's can hold tens
--- of thousands of items, and walking them all for each group stalled the game for seconds.
function Bk.Counts()
	local bags, bank = enumBags()
	local inBags, inBank = {}, {}
	for _, s in ipairs(slots(bags)) do if s.id then inBags[s.id] = (inBags[s.id] or 0) + s.count end end
	for _, s in ipairs(slots(bank)) do if s.id then inBank[s.id] = (inBank[s.id] or 0) + s.count end end
	local sep = CH.Groups.SEP or "/"
	local by = {}
	local function add(id)
		local path = CH.Groups.Path(id)
		if not path then return end
		local acc = ""
		for part in string.gmatch(path, "[^" .. sep .. "]+") do
			acc = acc == "" and part or (acc .. sep .. part)
			local g = by[acc]
			if not g then
				local _, depth = acc:gsub(sep, "")
				g = { path = acc, name = part, depth = depth, bags = 0, bank = 0 }
				by[acc] = g
			end
			g.bags, g.bank = g.bags + (inBags[id] or 0), g.bank + (inBank[id] or 0)
		end
	end
	local seen = {}
	for id in pairs(inBags) do seen[id] = true; add(id) end
	for id in pairs(inBank) do if not seen[id] then add(id) end end
	local out = {}
	for _, g in pairs(by) do out[#out + 1] = g end
	table.sort(out, function(a, b) return a.path < b.path end)
	return out
end

--- The moves for a group: { { bag, slot, id, count } }, every stack of its items (its sub-groups'
--- too) on the side they leave. to = "bank" (from your bags, the ones the Warband bank takes) or "bags".
function Bk.Plan(path, to)
	local bags, bank = enumBags()
	local out, mine = {}, {}
	for _, s in ipairs(slots(to == "bank" and bags or bank)) do
		if s.id then
			if mine[s.id] == nil then
				local p = CH.Groups.Path(s.id)
				mine[s.id] = p and within(p, path) or false
			end
			if mine[s.id] and (to ~= "bank" or allowed(s)) then out[#out + 1] = s end
		end
	end
	return out
end

-- Free slots on one side, so a move that has nowhere to go stops instead of failing silently.
local function free(list)
	local n = 0
	local C = C_Container
	for _, bag in ipairs(list) do
		local ok, f = pcall(C.GetContainerNumFreeSlots or function() return 0 end, bag)
		n = n + (ok and tonumber(f) or 0)
	end
	return n
end
Bk.Free = free

local running
--- Move a group's items (see Plan). done(moved, why) once finished or stopped. Returns false and
--- why when it can't start.
function Bk.Move(path, to, done)
	if running then return false, "already moving: wait for it to finish" end
	if not Bk.Open() then return false, "open your bank on the Warband tab first" end
	local plan = Bk.Plan(path, to)
	if #plan == 0 then return false, to == "bank" and "none of the group's items in your bags can go to the Warband bank" or "none of the group's items are in the Warband bank" end
	local bags, bank = enumBags()
	local target = to == "bank" and bank or bags
	local i, moved = 0, 0
	running = true
	local function stop(why)
		running = false
		if done then done(moved, why) end
	end
	local function step()
		i = i + 1
		local s = plan[i]
		if not s then return stop(nil) end
		if not Bk.Open() then return stop("the bank closed") end
		if free(target) <= 0 then return stop(to == "bank" and "the Warband bank is full" or "your bags are full") end
		local info = C_Container.GetContainerItemInfo(s.bag, s.slot)
		-- still the same stack (nothing else moved it meanwhile)
		if info and info.itemID == s.id then
			if to == "bank" then
				C_Container.UseContainerItem(s.bag, s.slot, nil, Enum.BankType and Enum.BankType.Account)
			else
				C_Container.UseContainerItem(s.bag, s.slot)
			end
			moved = moved + 1
		end
		C_Timer.After(Bk.STEP, step)
	end
	step()
	return true, #plan
end

function Bk.Busy() return running and true or false end
function Bk.Reset() running = false end

-- The panel beside the bank -------------------------------------------------------------------
local frame, rows, status, toBank, toBags, scrollBar
local list, offset, selected = {}, 0, nil
local N, W, H = 12, 330, 380

function Bk.Refresh()
	if not frame then return end
	local T = CH.Theme
	list = Bk.Counts()
	offset = math.max(0, math.min(offset, #list - N))
	scrollBar:Set(offset, N, #list)
	for i, r in ipairs(rows) do
		local g = list[i + offset]
		if g then
			local name = string.rep("  ", g.depth) .. g.name
			r.cells[1]:SetText(g.path == selected and T.Color("accent", name) or name)
			r.cells[2]:SetText(g.bags > 0 and tostring(g.bags) or T.Color("muted", "-"))
			r.cells[3]:SetText(g.bank > 0 and tostring(g.bank) or T.Color("muted", "-"))
		else
			for _, c in ipairs(r.cells) do c:SetText("") end
		end
	end
	local open = Bk.Open()
	toBank:SetEnabled(open and selected ~= nil and not running)
	toBags:SetEnabled(open and selected ~= nil and not running)
	if not open and not running then status:SetText(T.Color("muted", "Open the bank's Warband tab to move items.")) end
end

local function go(to)
	if not selected then return end
	local T = CH.Theme
	local ok, n = Bk.Move(selected, to, function(moved, why)
		status:SetText(T.Color(why and "bad" or "ok", string.format("Moved %d stack%s %s%s.", moved, moved == 1 and "" or "s",
			to == "bank" and "to the Warband bank" or "to your bags", why and (": stopped, " .. why) or "")))
		Bk.Refresh()
	end)
	if ok then status:SetText(T.Color("accent", string.format("Moving %d stack%s ...", n, n == 1 and "" or "s")))
	else status:SetText(T.Color("bad", n)) end
	Bk.Refresh()
end

local function build()
	local T, Wd = CH.Theme, CH.Window
	frame = Wd.New("AuctionIQBanking", "Banking", W, H)
	toBank = T.Primary(T.Button(frame, "To Warband bank", 130, 22)); toBank:SetPoint("TOPLEFT", 12, -36)
	toBank:SetScript("OnClick", function() go("bank") end)
	toBags = T.Button(frame, "To bags", 80, 22); toBags:SetPoint("TOPLEFT", 148, -36)
	toBags:SetScript("OnClick", function() go("bags") end)
	status = Wd.Text(frame, 12, -64, W - 24)
	rows = Wd.Table(frame, { { "Group", 12, 190 }, { "Bags", 206, 50 }, { "Warband", 260, 56 } }, N, -84, 20, function(i)
		local g = list[i + offset]
		if g then selected = g.path; Bk.Refresh() end
	end, nil, W)
	scrollBar = Wd.ScrollBar(frame, W - 10, -102, N * 20)
	Wd.Wheel(frame, N, function() return offset end, function(v) offset = v end, function() return #list end, Bk.Refresh, scrollBar)
	T.Fonts(frame)
	frame:Hide()
end

function Bk.Build() if not frame then build() end return frame end
function Bk.Select(path) selected = path end

CH.On("BANKFRAME_OPENED", function()
	Bk.bankOpen = true
	if not frame then build() end
	frame:ClearAllPoints()
	local anchor = BankFrame
	if anchor then frame:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 4, 0) end
	frame:Show()
	Bk.Refresh()
end)
CH.On("BANKFRAME_CLOSED", function() Bk.bankOpen = false; if frame then frame:Hide() end end)
CH.On("BAG_UPDATE_DELAYED", function() if frame and frame:IsShown() and not running then Bk.Refresh() end end)
