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

--- What to send from here: { [char] = { { id, bag, slot, count } } }, never to yourself.
function M.Outbox()
	local out, me = {}, UnitName and UnitName("player")
	if not C_Container then return out end
	for bag = 0, (NUM_BAG_SLOTS or 4) + 1 do
		for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.itemID and not info.isBound then
				local to = M.Destination(info.itemID)
				if to and to ~= me then
					out[to] = out[to] or {}
					table.insert(out[to], { id = info.itemID, bag = bag, slot = slot, count = info.stackCount or 1 })
				end
			end
		end
	end
	return out
end

--- Send the next mail (up to 12 attachments to one character). Run from a click. Returns who to.
function M.SendNext()
	local box = M.Outbox()
	for to, list in pairs(box) do
		-- attachments only take when the Send Mail tab is the one showing
		if SendMailFrame and not SendMailFrame:IsShown() and MailFrameTab_OnClick then pcall(MailFrameTab_OnClick, nil, 2) end
		if ClearSendMail then ClearSendMail() end
		for i = 1, math.min(#list, ATTACHMENTS_MAX_SEND or 12) do
			C_Container.PickupContainerItem(list[i].bag, list[i].slot)
			ClickSendMailItemButton(i)
		end
		SendMail(to, "AuctionIQ", "")
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
local opening
function M.OpenAll(done)
	if opening or not GetInboxNumItems then return end
	opening = true
	local gold, taken = 0, 0
	local function step()
		local n = GetInboxNumItems()
		for i = n, 1, -1 do
			local _, _, _, _, money, cod, _, hasItem = GetInboxHeaderInfo(i)
			if (cod or 0) == 0 and ((money or 0) > 0 or hasItem) then
				if (money or 0) > 0 then gold = gold + money end
				taken = taken + 1
				AutoLootMailItem(i)
				C_Timer.After(0.3, step)
				return
			end
		end
		opening = false
		M.Waiting()
		if done then done(taken, gold) end
	end
	step()
end
