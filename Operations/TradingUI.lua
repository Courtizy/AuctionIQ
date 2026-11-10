-- Operations tab: the work planned or underway, worked out before you get to the auction house,
-- the profession window or the mailbox. The AH, profession and mailbox windows carry it out.
--   Production queue: every queued craft on every character, and what holds it up.
--   Shopping list: the reagents the queue still needs to buy (Shopping at the AH buys them).
--   Ready to post: each item in a posting group, what you hold on every character and the warband
--     bank, what's already up, how many to post under the group's cap and what they're worth, and
--     whether the AH's last price is under your minimum (hold) or not (post).
--   To mail: items sitting on a character other than the one their group's mail route sends them to.
-- Setting up groups, operations and routes lives in Settings (Groups and items).
local _, CH = ...

local TUI = {}
CH.TradingUI = TUI

local LUI = CH.LedgerUI
local function money(c) return LUI.Money(c) end

-- The AH's last cheapest price for an item: your scan if it's fresh, else TSM's minimum buyout.
local function ahNow(id)
	local s = CH.Scans and CH.Scans.Get(id)
	if s and s.min and s.age and s.age <= 86400 then return s.min, "scan" end
	local m = CH.Prices.Raw and CH.Prices.Raw("dbminbuyout", id)
	if m then return m, "tsm" end
	return s and s.min, s and "scan"
end

--- The post plan for every grouped item you hold, from the same rule check the AH panel posts with
--- (Auction.Evaluate): { id, held, up, cap, post (what your rules allow), price, ah, source, age,
--- why, check (no scan and no sales: check the live price first), value, verdict }.
function TUI.PostPlan()
	local out = {}
	if not (CH.Ledger and CH.Ledger.Available()) then return out end
	for _, e in ipairs(CH.Ledger.Inventory()) do
		local path = e.id and not e.bound and CH.Groups.Path(e.id)
		if path then
			local p = CH.Groups.Prices(e.id)
			local held = e.bags + e.bank + e.warband
			if p.post and held > (p.keep or 0) then
				local up = math.max(e.ah or 0, CH.Auction.Listed(e.id))
				local results, source, age = CH.Auction.Listings(e.id)
				local ev = CH.Auction.Evaluate(e.id, { results = results, held = held, listed = up })
				local verdict = ev.action == "post" and "post" or ev.kind == "full" and "full" or ev.kind == "min" and "hold" or "skip"
				local ah = results and results[1] and results[1].price or nil
				local vals = CH.Prices.Values and CH.Prices.Values(e.id) or {}
				local price = ev.price or p.normal
				local post = ev.action == "post" and ev.qty or 0
				table.insert(out, { id = e.id, path = path, held = held, up = up, cap = p.cap, post = post, price = price,
					ah = ah or ahNow(e.id), source = source, age = age, why = ev.why, op = p.op,
					check = source == nil and not vals.realized or nil,
					min = p.min, value = verdict == "post" and price and price * post * CH.AH_CUT or 0, verdict = verdict, mail = e.mail })
			end
		end
	end
	return out
end

--- What to mail: { id, from, to, n, value } for grouped items held by a character other than
--- the one their route sends them to (bags and bank; the warband bank is everyone's).
function TUI.MailPlan()
	local out = {}
	if not (CH.Ledger and CH.Ledger.Available() and CH.Mail) then return out end
	local held = {} -- [name] = { [id] = bags + bank }
	for _, c in ipairs(CH.Ledger.Characters()) do
		held[c.name] = {}
		for _, e in ipairs(CH.Ledger.Inventory(nil, c.name)) do
			local n = e.bags + e.bank
			if e.id then held[c.name][e.id] = n end
			local to = n > 0 and e.id and not e.bound and CH.Mail.Destination(e.id)
			if to and to ~= c.name then
				local unit = CH.Prices.Get("chvalue", "i:" .. e.id)
				table.insert(out, { id = e.id, from = c.name, to = to, n = n, bags = e.bags, value = unit and unit * n or 0 })
			end
		end
	end
	-- reagents a queued crafter is short of, from whoever holds them
	for to, items in pairs(CH.Mail.ReagentNeeds and CH.Mail.ReagentNeeds() or {}) do
		for id, short in pairs(items) do
			for from, h in pairs(held) do
				if short <= 0 then break end
				local n = from ~= to and math.min(h[id] or 0, short) or 0
				if n > 0 then
					short = short - n
					local unit = CH.Prices.Get("chmat", "i:" .. id)
					table.insert(out, { id = id, from = from, to = to, n = n, value = unit and unit * n or 0, reagent = true })
				end
			end
		end
	end
	return out
end


--- Posting advice for every Ready to post row, saved once an item a day: { [id] = advice }.
function TUI.Advice(plan, now)
	now = now or time()
	local times = {}
	if CH.Ledger and CH.Ledger.Available() then
		for _, e in ipairs(CH.Ledger.SaleTimes(now - 30 * 86400)) do times[e.id] = e end
	end
	local hour = tonumber(date("%H", now))
	local out = {}
	for _, r in ipairs(plan or TUI.PostPlan()) do
		local a = CH.Decide.PostAdvice(r, { times = times[r.id], hour = hour })
		out[r.id] = a
		if a then CH.Decide.SaveAdvice(r.id, a, now) end
	end
	return out
end

local function D_LABEL(a) return CH.Decide.PostLabel(a) end
local ACTION = { post = "ok", fewer = "accent", wait = "muted", check = "bad" }

local SOURCE = { ah = "your AH search", scan = "your last AH scan" }

--- One item's posting call, as lines: the recommendation, why, and what your rules allow apart from it.
function TUI.PostLines(r, a)
	local T, M = CH.Theme, CH.FormatMoney
	local lines = {
		{ D_LABEL(a) .. ((a.action == "post" or a.action == "fewer") and r.price and ("  at " .. M(r.price)) or "") },
		{ T.Color("muted", "Because " .. a.reason .. ".") },
		{ "Recommended quantity", tostring(a.qty or 0) },
		{ "Allowed by your rules", (r.post or 0) .. T.Color("muted", string.format("  (%d up of a %d cap)", r.up or 0, r.cap or 0)) },
	}
	if r.why then table.insert(lines, { "Rule check", T.Color("muted", r.why) }) end
	table.insert(lines, { "Price from", r.source and string.format("%s, %s ago", SOURCE[r.source] or r.source, CH.Scans and CH.Scans.Age and r.age and CH.Scans.Age(r.age) or "?")
		or T.Color("bad", "no AH scan: your operation's normal price") })
	if r.min then table.insert(lines, { "Your min", M(r.min) }) end
	return lines
end

--- The selected Ready to post row, in the panel beside the table: the same call the AH will make.
function TUI.PostDetail(d)
	local x = d and d.x
	if not (x and x.plan) then return nil end
	local r, a = x.plan, x.advice
	local T, M = CH.Theme, CH.FormatMoney
	local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(r.id) or ("item " .. r.id)
	local label = a and D_LABEL(a) or "-"
	local rows = {
		{ "Recommended", a and T.Color(ACTION[a.action] or "fg", label) or "-" },
		{ "Allowed by your rules", tostring(r.post or 0) },
		{ "Held / up / cap", string.format("%d / %d / %d", r.held or 0, r.up or 0, r.cap or 0) },
		{ "Operation", r.op or "Default" },
		{ "Price from", r.source and string.format("%s, %s ago", SOURCE[r.source] or r.source, CH.Scans and CH.Scans.Age and r.age and CH.Scans.Age(r.age) or "?")
			or T.Color("bad", "no scan") },
	}
	if r.why then rows[#rows + 1] = { "Rule check", r.why } end
	rows[#rows + 1] = { "Worth to you (EV)", x.ev and M(x.ev) or T.Color("muted", "-") }
	rows[#rows + 1] = { "You've sold for (RZ)", x.realized and M(x.realized) or T.Color("muted", "none sold") }
	local note = a and ("Because " .. a.reason .. ".") or ""
	local actions = {}
	local function ahOpen() return AuctionHouseFrame and AuctionHouseFrame.IsShown and AuctionHouseFrame:IsShown() end
	if (a and a.action == "check") or not r.source then
		actions[#actions + 1] = { label = "Check live price", tip = "At the auction house: search this item. AuctionIQ reads the listings and this call updates.",
			run = function()
				if not ahOpen() then return false, "Open the auction house first, then press this." end
				CH.Auction.Search(r.id, function() CH.UI.Refresh() end)
				return true, "Searching the AH for " .. name .. "..."
			end }
	end
	actions[#actions + 1] = { label = "Review at Auction House", tip = "Build the AH panel's post list: it posts with the same rule check as this table, one press each.",
		run = function()
			if not ahOpen() then return false, "Open the auction house: AuctionIQ's panel beside it posts with these rules." end
			if CH.AuctionUI and CH.AuctionUI.PostScan then CH.AuctionUI.PostScan() end
			return true, "Building your post list at the AH."
		end }
	return { kicker = "NEXT MOVE", title = name, sub = T.Color("muted", r.path or ""),
		figures = { { "PRICE", r.price and T.Color("gold", M(r.price)) or T.Color("muted", "-") },
			{ "AH NOW", r.ah and M(r.ah) or T.Color("muted", "no scan") },
			{ "WORTH", T.Color("gold", M((r.price or 0) * (a and a.qty or 0) * CH.AH_CUT)) } },
		rows = rows, note = T.Color("muted", note), actions = actions }
end

local function postRows(ctx)
	local T = CH.Theme
	local out, n, worth, held, full, fewer, wait, checks = {}, 0, 0, 0, 0, 0, 0, 0
	local plan = TUI.PostPlan()
	local advice = TUI.Advice(plan, ctx.now)
	for _, r in ipairs(plan) do
		local text, name = LUI.ItemText(r.id)
		if ctx.keepName(name) then
			local a = advice[r.id]
			if r.verdict == "hold" then held = held + 1 elseif r.verdict == "full" then full = full + 1 end
			if a and (a.action == "post" or a.action == "fewer") then n, worth = n + a.qty, worth + (r.price or 0) * a.qty * CH.AH_CUT end
			if a and a.action == "fewer" then fewer = fewer + 1 elseif a and a.action == "wait" then wait = wait + 1 end
			if a and a.action == "check" then checks = checks + 1 end
			-- EV: what one is worth to you at this price; RZ: what you've really sold it for
			local vals = CH.Prices.Values(r.id)
			local ev = r.price and CH.Expect and CH.Expect.Value(r.id, r.price)
			local tip = a and TUI.PostLines(r, a)
			table.insert(out, { id = r.id, key = r.id, x = { plan = r, advice = a, ev = ev, realized = vals.realized }, tip = tip,
				cells = { text, r.held, string.format("%d / %d", r.up, r.cap or 0),
				money(r.price), r.ah and money(r.ah) or T.Color("muted", "no scan"),
				a and T.Color(ACTION[a.action], D_LABEL(a)) or "" },
				sort = { name, r.held, r.up, r.price or 0, r.ah or 0,
					(a and (a.action == "post" and 0 or a.action == "fewer" and 1 or a.action == "check" and 2 or 3) or 4) * 1e15 - r.value } })
		end
	end
	if not CH.Ledger.Available() then
		return out, T.Color("muted", "Needs TradeSkillMaster: it counts what each character holds.")
	end
	if not out[1] then
		return out, T.Color("muted", "Nothing to post: no items you hold are in a posting group. Set groups up in Settings, Edit groups.")
	end
	return out, string.format("%s to post, worth %s after the cut", T.Color("ok", n), money(worth))
		.. (fewer > 0 and T.Color("accent", string.format("   %d fewer than your rules allow", fewer)) or "")
		.. (checks > 0 and T.Color("bad", string.format("   %d to check the live price on", checks)) or "")
		.. (wait > 0 and T.Color("muted", string.format("   %d to wait on", wait)) or "")
		.. (held > 0 and T.Color("bad", string.format(" (%d under your min)", held)) or "")
		.. T.Color("muted", string.format("   Enough up is %d days of sales. Select a row for why; the AH panel posts with the same rules.", CH.Decide.POST_DAYS))
end

local function mailRows(ctx)
	local T = CH.Theme
	local out, worth, sends = {}, 0, {}
	for _, r in ipairs(TUI.MailPlan()) do
		local text, name = LUI.ItemText(r.id)
		if ctx.keepName(name) then
			worth = worth + r.value
			sends[r.from .. ">" .. r.to] = true
			table.insert(out, { id = r.id, cells = { text, r.from, r.to, r.n, money(r.value),
				r.reagent and T.Color("accent", "reagents to craft") or r.bags < r.n and T.Color("muted", "some in the bank") or "" },
				sort = { name, r.from, r.to, r.n, r.value, r.bags or 0 } })
		end
	end
	if not out[1] then
		return out, T.Color("muted", "Nothing to mail. Queued crafts on another character get their reagents here, and routes send a group to one character: set them in Settings, Edit groups (right-click a group), or with Routes at the mailbox.")
	end
	local k = 0
	for _ in pairs(sends) do k = k + 1 end
	return out, string.format("%d items to send in %d trips, worth %s", #out, k, money(worth))
		.. T.Color("muted", "   At the mailbox, Send mails them by route from the character you're on.")
end

TUI.VIEWS = {
	post = { label = "Ready to post", detail = function(d) return TUI.PostDetail(d) end, sort = 6, asc = true, noTime = true, rows = postRows,
		cols = { { "Item", 0, 220 }, { "Held", 224, 44 }, { "Up / cap", 272, 74 }, { "Price", 350, 110 }, { "AH now", 464, 110 },
		{ "Advice", 578, 146 } } },
	mail = { label = "To mail", sort = 5, noTime = true, rows = mailRows, cols = { { "Item", 0, 200 }, { "From", 204, 100 }, { "To", 308, 100 },
		{ "Qty", 412, 50 }, { "Worth", 466, 100 }, { "", 570, 154 } } },
}

-- Production ----------------------------------------------------------------------------------
local function count(id)
	if not (C_Item and C_Item.GetItemCount) then return 0 end
	return C_Item.GetItemCount(id, true, false, true, true) or 0
end

--- The craft queue with each entry's status: { e, short = reagents still to buy, status }.
function TUI.QueuePlan()
	local out = {}
	for _, e in ipairs(CH.db.queue or {}) do
		local short = 0
		for _, sh in ipairs(e.shop or {}) do short = short + math.max(0, sh.n * e.qty - count(sh.itemID)) end
		local status
		if e.orderID then status = CH.Queue.OrderStep(e) == "Turn in" and "turn in" or (e.stage or "order")
		elseif short > 0 then status = "buy reagents"
		else status = "ready to craft" end
		table.insert(out, { e = e, short = short, status = status })
	end
	return out
end

local STATUS = { ["ready to craft"] = "ok", ["turn in"] = "ok", ["buy reagents"] = "bad" }

local function queueRows(ctx)
	local T = CH.Theme
	local out, profit, ready, blocked = {}, 0, 0, 0
	for _, x in ipairs(TUI.QueuePlan()) do
		local e = x.e
		if ctx.keepName(e.name) then
			local p = (e.profit or 0) * e.qty
			profit = profit + p
			if x.status == "buy reagents" then blocked = blocked + 1 else ready = ready + 1 end
			local name = (e.item and CH.Window.ItemIcon(e.item, 14) or "") .. (e.name or "?") .. (e.quality and T.Color("muted", " Q" .. e.quality) or "")
			table.insert(out, { id = e.item, cells = { name, e.charName or "?", e.qty, e.profit and LUI.Signed(e.profit) or "-", LUI.Signed(p),
				e.concentration and T.Color("accent", "yes") or T.Color("muted", "-"), x.short > 0 and x.short or T.Color("muted", "-"),
				T.Color(STATUS[x.status] or "fg", x.status) },
				sort = { e.name or "", e.charName or "", e.qty, e.profit or 0, p, e.concentration and 1 or 0, x.short, x.status } })
		end
	end
	if not out[1] then
		return out, T.Color("muted", "Nothing queued. Queue crafts from the advisor, Scan or Paths at a profession window.")
	end
	return out, string.format("%d queued, %s expected profit (estimated, not yet realized). %d ready, %d waiting on reagents.",
		#out, money(profit), ready, blocked)
		.. T.Color("muted", "   Craft them at the profession window: Queue and shopping.")
end

--- Every task waiting, in one list: crafts from the queue, posts from Ready to post, and mail trips
--- from To mail. { kind = "craft"|"post"|"mail", task, char, qty, worth, status, where, tone }.
function TUI.WorkPlan()
	local out = {}
	for _, x in ipairs(TUI.QueuePlan()) do
		local e = x.e
		local status = x.status
		if e.char ~= (CH.CharacterKey and CH.CharacterKey()) and status ~= "buy reagents" then status = "switch character" end
		table.insert(out, { kind = "craft", task = "Craft " .. (e.name or "?") .. (e.quality and (" Q" .. e.quality) or ""), id = e.item,
			char = e.charName or "?", qty = e.qty, worth = (e.profit or 0) * e.qty, status = status, where = "Professions",
			tone = STATUS[status] or "fg" })
	end
	-- posts follow the posting advice: how many it says, not just what TSM would put up
	local plan = TUI.PostPlan()
	local advice = TUI.Advice(plan)
	for _, r in ipairs(plan) do
		local a = advice[r.id]
		local qty = a and a.action ~= "wait" and a.qty or 0
		if r.verdict == "post" and qty > 0 then
			local _, name = LUI.ItemText(r.id)
			table.insert(out, { kind = "post", task = "Post " .. name, id = r.id, char = "any", qty = qty,
				worth = (r.price or 0) * qty * CH.AH_CUT, status = a.action == "fewer" and "post fewer" or "ready to post",
				where = "Auction House", tone = "ok" })
		end
	end
	local trips = {}
	for _, r in ipairs(TUI.MailPlan()) do
		local k = r.from .. ">" .. r.to
		local t = trips[k]
		if not t then
			t = { kind = "mail", task = "Mail to " .. r.to, char = r.from, qty = 0, worth = 0, status = "mailbox needed",
				where = "Mailbox", tone = "fg" }
			trips[k] = t
			table.insert(out, t)
		end
		t.qty = t.qty + r.n
		t.worth = t.worth + (r.value or 0)
		if r.reagent then t.status, t.tone = "reagents to craft", "accent" end
	end
	return out
end

local KIND = { craft = 1, post = 2, mail = 3 }

local function workRows(ctx)
	local T = CH.Theme
	local out, n = {}, { craft = 0, post = 0, mail = 0 }
	for _, w in ipairs(TUI.WorkPlan()) do
		if ctx.keepName(w.task) then
			n[w.kind] = n[w.kind] + 1
			table.insert(out, { id = w.id, cells = { (w.id and CH.Window.ItemIcon(w.id, 14) or "") .. w.task, w.char, w.qty,
				w.worth ~= 0 and money(w.worth) or T.Color("muted", "-"), T.Color(w.tone, w.status), T.Color("muted", w.where) },
				sort = { w.task, w.char, w.qty, w.worth, w.status, KIND[w.kind] * 1e15 - w.worth } })
		end
	end
	if not out[1] then
		return out, T.Color("muted", "Nothing to do: no crafts queued, nothing ready to post, nothing to mail.")
	end
	return out, string.format("%d crafts, %d posts, %d mail trips.", n.craft, n.post, n.mail)
		.. T.Color("muted", "   Worth: craft profit and post value are estimates. Do each at the window named.")
end

local function shoppingRows(ctx)
	local T = CH.Theme
	local out = {}
	local list, total = CH.Queue.ShoppingList()
	local buys = 0
	for _, r in ipairs(list) do
		local text, name = LUI.ItemText(r.itemID)
		if ctx.keepName(name) then
			if r.buy > 0 then buys = buys + 1 end
			table.insert(out, { id = r.itemID, cells = { text, r.need, r.have, r.buy > 0 and r.buy or T.Color("ok", "have all"),
				r.unit and money(r.unit) or T.Color("muted", "no price"), r.buy > 0 and money(r.cost) or "-",
				r.craft and T.Color("ok", "cheaper to craft: " .. (r.craft.char or "?") .. ", " .. money(r.craft.each) .. " each")
				or r.short and r.short > 0 and T.Color("bad", r.short .. " short on the AH") or T.Color("muted", r.source or "") },
				sort = { name, r.need, r.have, r.buy, r.unit or 0, r.cost or 0, r.short or 0 } })
		end
	end
	if not out[1] then return out, T.Color("muted", "Nothing to buy: the queue is empty or you hold every reagent.") end
	return out, string.format("%d reagents to buy, about %s (planned purchase budget).", buys, money(total))
		.. T.Color("muted", "   At the AH, Auctioning's Shop queue buys them.")
end

TUI.PRODUCTION = {
	work = { label = "Execution plan", sort = 6, asc = true, noTime = true, rows = workRows, cols = { { "Task", 0, 250 }, { "Character", 254, 96 },
		{ "Qty", 354, 40 }, { "Worth", 398, 96 }, { "Status", 498, 120 }, { "Where", 622, 102 } } },
	queue = { label = "Production queue", sort = 5, noTime = true, rows = queueRows, cols = { { "Craft", 0, 190 }, { "Character", 194, 90 },
		{ "Qty", 288, 36 }, { "Profit/craft", 328, 82 }, { "Profit", 414, 86 }, { "Conc.", 504, 44 }, { "To buy", 552, 50 }, { "Status", 606, 118 } } },
	shopping = { label = "Shopping list", sort = 6, noTime = true, rows = shoppingRows, cols = { { "Reagent", 0, 200 }, { "Need", 204, 54 },
		{ "Have", 262, 54 }, { "Buy", 320, 60 }, { "Each", 384, 84 }, { "Cost", 472, 96 }, { "", 572, 152 } } },
}
TUI.MOVING = {
	rules = { label = "Groups and rules", noTime = true, cols = {}, go = function() CH.UI.Go("settings", "groups") end },
}

-- (Research/Views.lua files these under Operations: Trade for what you hold, Queue for the work.)
-- Manage rules opens Settings' groups and posting rules, from Trade.
TUI.MOVING.rules.label = "Manage rules"
LUI.Register("operations", TUI.PRODUCTION, {})
LUI.Register("operations", TUI.VIEWS, {})
LUI.Register("operations", TUI.MOVING, {})
