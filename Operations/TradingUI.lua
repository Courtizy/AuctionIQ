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

--- The post plan for every grouped item you hold: { id, held, up, cap, post, price, ah, value, verdict }.
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
				local post = math.max(0, math.min((p.cap or 0) - up, held - (p.keep or 0)))
				local ah = ahNow(e.id)
				local verdict
				if post == 0 then verdict = "full"
				elseif ah and p.min and ah < p.min then verdict = "hold"
				else verdict = "post" end
				-- priced the way posting prices it: undercut the cheapest, kept between your min and max
				local price = p.normal
				if ah and price then
					price = ah - (p.undercut or 1)
					if p.max and price > p.max then price = p.max end
					if p.min and price < p.min then price = p.min end
				end
				table.insert(out, { id = e.id, path = path, held = held, up = up, cap = p.cap, post = post, price = price, ah = ah,
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

local VERDICT = { post = { "ok", "post" }, hold = { "bad", "hold: AH under your min" }, full = { "muted", "full" } }

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
local ACTION = { post = "ok", fewer = "accent", wait = "muted" }

local function postRows(ctx)
	local T = CH.Theme
	local out, n, worth, held, full, fewer, wait = {}, 0, 0, 0, 0, 0, 0
	local plan = TUI.PostPlan()
	local advice = TUI.Advice(plan, ctx.now)
	for _, r in ipairs(plan) do
		local text, name = LUI.ItemText(r.id)
		if ctx.keepName(name) then
			local a = advice[r.id]
			if r.verdict == "hold" then held = held + 1 elseif r.verdict == "full" then full = full + 1 end
			if a and a.action ~= "wait" then n, worth = n + a.qty, worth + (r.price or 0) * a.qty * CH.AH_CUT end
			if a and a.action == "fewer" then fewer = fewer + 1 elseif a and a.action == "wait" then wait = wait + 1 end
			-- EV: what one is worth to you at this price; RZ: what you've really sold it for
			local vals = CH.Prices.Values(r.id)
			local ev = r.price and CH.Expect and CH.Expect.Value(r.id, r.price)
			local tip = a and {
				{ D_LABEL(a) .. (a.action ~= "wait" and r.price and ("  at " .. CH.FormatMoney(r.price)) or "") },
				{ T.Color("muted", "Because " .. a.reason .. ".") },
				{ "TSM would post", (r.verdict == "post" and r.post or 0) .. T.Color("muted", string.format("  (%d up of a %d cap)", r.up, r.cap or 0)) },
				r.min and { "Your min", CH.FormatMoney(r.min) } or nil,
			}
			table.insert(out, { id = r.id, tip = tip, cells = { text, r.held, string.format("%d / %d", r.up, r.cap or 0),
				money(r.price), r.ah and money(r.ah) or T.Color("muted", "no scan"), ev and money(ev) or T.Color("muted", "-"),
				vals.realized and money(vals.realized) or T.Color("muted", "none sold"),
				a and T.Color(ACTION[a.action], D_LABEL(a)) or "" },
				sort = { name, r.held, r.up, r.price or 0, r.ah or 0, ev or 0, vals.realized or 0,
					(a and (a.action == "post" and 0 or a.action == "fewer" and 1 or 2) or 3) * 1e15 - r.value } })
		end
	end
	if not CH.Ledger.Available() then
		return out, T.Color("muted", "Needs TradeSkillMaster: it counts what each character holds.")
	end
	if not out[1] then
		return out, T.Color("muted", "Nothing to post: no items you hold are in a posting group. Set groups up in Settings, Edit groups.")
	end
	return out, string.format("%s to post, worth %s after the cut", T.Color("ok", n), money(worth))
		.. (fewer > 0 and T.Color("accent", string.format("   %d fewer than TSM would", fewer)) or "")
		.. (wait > 0 and T.Color("muted", string.format("   %d to wait on", wait)) or "")
		.. (held > 0 and T.Color("bad", string.format(" (%d under your min)", held)) or "")
		.. T.Color("muted", string.format("   Enough up is %d days of sales; hover a row for why. Post at the AH: Auctioning opens beside it.", CH.Decide.POST_DAYS))
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
	post = { label = "Ready to post", sort = 8, asc = true, noTime = true, rows = postRows, cols = { { "Item", 0, 170 },
		{ "Held", 174, 40 }, { "Up / cap", 218, 56 }, { "Price", 278, 76 }, { "AH now", 358, 76 }, { "EV", 438, 76 }, { "RZ", 518, 76 },
		{ "Advice", 598, 126 } } },
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
