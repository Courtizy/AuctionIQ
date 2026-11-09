-- Mail: open everything in one go, and send items to the character that uses them by group routes
-- (a group sends to a character; sub-groups inherit). Each send is one click (a Blizzard rule);
-- opening runs on its own, a little at a time.
local _, CH = ...

local M = {}
CH.Mail = M

local function store()
	CH.db.mail = CH.db.mail or { routes = {} }
	return CH.db.mail
end
M.Store = store

--- Send a group's items to a character (nil stops routing it).
function M.Route(path, char) store().routes[path] = char end

--- Where an item goes: the nearest group (or parent) with a route.
function M.Destination(id)
	local path = CH.Groups.Path(id)
	local r = store().routes
	while path do
		if r[path] then return r[path], path end
		path = path:match("^(.*)/[^/]+$")
	end
end

--- Reagents the crafting queue's other crafters are short, on this realm: { [name] = { [itemID] = n } }.
--- Short is what their queued crafts need less what they hold (bags, bank, mail on its way) and the
--- Warband bank, which they can take from themselves. The Warband bank is one stock shared by
--- everyone: what this character's own queued crafts will take from it comes off first, then each
--- crafter in name order takes what's left, so no unit is counted twice.
function M.ReagentNeeds()
	local out = {}
	local here = CH.CharacterKey and CH.CharacterKey()
	local me = UnitName and UnitName("player")
	local realm = GetRealmName and GetRealmName()
	local need, mine = {}, {}
	for _, e in ipairs(CH.db and CH.db.queue or {}) do
		local name, r = tostring(e.char or ""):match("^(.-)%-(.+)$")
		if (e.qty or 0) > 0 and e.stage ~= "crafted" then
			local into
			if e.char == here then into = mine
			elseif name and r == realm then need[name] = need[name] or {}; into = need[name] end
			if into then
				for _, x in ipairs(e.shop or {}) do into[x.itemID] = (into[x.itemID] or 0) + (x.n or 0) * e.qty end
			end
		end
	end
	if not next(need) then return out, mine end
	local ok = CH.Ledger and CH.Ledger.Available()
	local function holds(name)
		local held = {}
		for _, it in ipairs(ok and CH.Ledger.Inventory(nil, name) or {}) do
			if it.id then held[it.id] = (it.bags or 0) + (it.bank or 0) + (it.mail or 0) end
		end
		return held
	end
	local warband = {}
	for _, it in ipairs(ok and CH.Ledger.Inventory() or {}) do if it.id then warband[it.id] = it.warband or 0 end end
	-- this character's own crafts take from the Warband bank first
	local myHeld = next(mine) and holds(me) or {}
	local keep = {} -- what this character's crafts need from its own bags, after the Warband bank
	for id, n in pairs(mine) do
		local fromBank = math.min(warband[id] or 0, math.max(0, n - (myHeld[id] or 0)))
		if warband[id] then warband[id] = warband[id] - fromBank end
		keep[id] = math.max(0, n - fromBank)
	end
	local names = {}
	for name in pairs(need) do table.insert(names, name) end
	table.sort(names)
	for _, name in ipairs(names) do
		local held = holds(name)
		for id, n in pairs(need[name]) do
			local short = n - (held[id] or 0)
			local fromBank = math.min(warband[id] or 0, math.max(0, short))
			if fromBank > 0 then warband[id] = warband[id] - fromBank end
			short = short - fromBank
			if short > 0 then out[name] = out[name] or {}; out[name][id] = short end
		end
	end
	return out, keep
end

--- What to send from here: { [char] = { { id, bag, slot, count, send, reagent } } }, never to
--- yourself: reagents a queued crafter is short (only as many as they need: send < count splits the
--- stack), then what's left of the stack to the character its group routes to. A bag slot is never
--- given out twice, and one recipient gets one entry per slot.
function M.Outbox()
	local out, me = {}, UnitName and UnitName("player")
	if not C_Container then return out end
	local short, own = M.ReagentNeeds()
	-- reagents this character's own queued crafts use stay here
	local keep = {}
	for id, n in pairs(own or {}) do keep[id] = n end
	local names = {}
	for name in pairs(short) do if name ~= me then table.insert(names, name) end end
	table.sort(names)
	local function give(to, id, bag, slot, count, n, reagent)
		out[to] = out[to] or {}
		for _, it in ipairs(out[to]) do
			if it.bag == bag and it.slot == slot then it.send = it.send + n; return end
		end
		table.insert(out[to], { id = id, bag = bag, slot = slot, count = count, send = n, reagent = reagent })
	end
	for bag = 0, (NUM_BAG_SLOTS or 4) + 1 do
		for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.itemID and not info.isBound then
				local id, count = info.itemID, info.stackCount or 1
				local left = count
				local k = math.min(left, keep[id] or 0)
				if k > 0 then keep[id] = keep[id] - k; left = left - k end
				-- a queued crafter short of this reagent gets it first, only as many as they need
				for _, name in ipairs(names) do
					local want = short[name][id] or 0
					if left > 0 and want > 0 then
						local n = math.min(left, want)
						short[name][id] = want - n
						left = left - n
						give(name, id, bag, slot, count, n, true)
					end
				end
				local to = M.Destination(id)
				if left > 0 and to and to ~= me then give(to, id, bag, slot, count, left) end
			end
		end
	end
	return out
end

--- Who the next mail goes to (alphabetical, so the button can name them), and what's in it.
function M.NextTo()
	local box, names = M.Outbox(), {}
	for to in pairs(box) do table.insert(names, to) end
	table.sort(names)
	return names[1], names[1] and box[names[1]]
end

--- Send the next mail (up to 12 attachments to one character). Run from a click. Returns who to.
function M.SendNext()
	local to, list = M.NextTo()
	if to then
		-- attachments only take when the Send Mail tab is the one showing
		if SendMailFrame and not SendMailFrame:IsShown() and MailFrameTab_OnClick then pcall(MailFrameTab_OnClick, nil, 2) end
		if ClearSendMail then ClearSendMail() end
		for i = 1, math.min(#list, ATTACHMENTS_MAX_SEND or 12) do
			local it = list[i]
			if it.send and it.send < it.count and C_Container.SplitContainerItem then
				C_Container.SplitContainerItem(it.bag, it.slot, it.send) -- just the part they need, on the cursor
			else
				C_Container.PickupContainerItem(it.bag, it.slot)
			end
			ClickSendMailItemButton(i)
		end
		SendMail(to, "AuctionIQ", "")
		if ClearCursor then ClearCursor() end
		return to, math.min(#list, 12)
	end
end

--- What's waiting in this mailbox: gold, mails, mails with items, cash-on-delivery mails. Also saved
--- per character, so the briefing can add up gold waiting in every character's mail.
function M.Waiting()
	local w = { gold = 0, mails = 0, items = 0, cod = 0 }
	if not GetInboxNumItems then return w end
	for i = 1, GetInboxNumItems() do
		local _, _, _, _, money, cod, _, hasItem = GetInboxHeaderInfo(i)
		w.mails = w.mails + 1
		if (cod or 0) > 0 then w.cod = w.cod + 1 else w.gold = w.gold + (money or 0) end
		if hasItem then w.items = w.items + 1 end
	end
	local s = store()
	s.waiting = s.waiting or {}
	if UnitName then s.waiting[UnitName("player")] = { gold = w.gold, items = w.items, at = time() } end
	return w
end

--- Gold waiting in mail across your characters, as last seen at each mailbox: total, { name = gold }.
function M.WaitingAll()
	local total, by = 0, {}
	for name, w in pairs(store().waiting or {}) do
		if (w.gold or 0) > 0 then total = total + w.gold; by[name] = w.gold end
	end
	return total, by
end

-- Open all: take money and items from every mail that isn't cash on delivery, one every 0.3s.
-- Each take is checked: if the inbox doesn't change after a few tries (bags full, an item you
-- can't carry) it stops and says why, and it stops when the mailbox closes.
local opening, finish
local function inboxSig()
	local n, sum = GetInboxNumItems(), 0
	for i = 1, n do
		local _, _, _, _, money, _, _, items = GetInboxHeaderInfo(i)
		sum = sum + (money or 0) + (tonumber(items) or (items and 1 or 0)) * 1e12
	end
	return n .. ":" .. sum
end
function M.OpenAll(done)
	if opening or not GetInboxNumItems then return end
	opening = true
	local startMoney = GetMoney and GetMoney()
	local gold, taken, tries, lastSig, pendingGold = 0, 0, 0, nil, 0
	finish = function(why)
		if not opening then return end
		opening, finish = false, nil
		if startMoney and GetMoney then gold = GetMoney() - startMoney end
		M.Waiting()
		if done then done(taken, gold, why) end
	end
	local function step()
		if not opening then return end
		local sig = inboxSig()
		if lastSig then
			if sig == lastSig then
				tries = tries + 1
				if tries >= 3 then return finish("stopped: your bags are full, or a mail can't be taken") end
			else
				taken, gold, tries = taken + 1, gold + pendingGold, 0
			end
		end
		local n = GetInboxNumItems()
		for i = n, 1, -1 do
			local _, _, _, _, money, cod, _, hasItem = GetInboxHeaderInfo(i)
			if (cod or 0) == 0 and ((money or 0) > 0 or hasItem) then
				pendingGold = money or 0
				lastSig = sig
				AutoLootMailItem(i)
				C_Timer.After(0.3, step)
				return
			end
		end
		finish()
	end
	step()
end
CH.On("MAIL_CLOSED", function() if finish then finish("stopped: the mailbox closed") end end)
