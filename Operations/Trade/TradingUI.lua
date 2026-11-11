-- Operations tab: the work planned or underway, worked out before you get to the auction house,
-- or the profession window. The AH and profession windows carry it out.
--   Production queue: every queued craft on every character, and what holds it up.
--   Shopping list: the reagents the queue still needs to buy (Shopping at the AH buys them).
--   Ready to post: each item in a posting group, what you hold on every character and the warband
--     bank, what's already up, how many to post under the group's cap and what they're worth, and
--     whether the AH's last price is under your minimum (hold) or not (post).
-- Setting up groups and operations lives in Settings (Groups and items).
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
				-- what's in this character's bags can go up now; the rest (bank, warband bank, other
				-- characters) has to be fetched first
				local here = C_Item and C_Item.GetItemCount and C_Item.GetItemCount(e.id, false) or 0
				table.insert(out, { id = e.id, path = path, held = held, here = here, fetch = math.max(0, held - here), up = up, cap = p.cap, post = post, price = price,
					ah = ah or ahNow(e.id), source = source, age = age, why = ev.why, op = p.op,
					check = source == nil and not vals.realized or nil,
					min = p.min, value = verdict == "post" and price and price * post * CH.AH_CUT or 0, verdict = verdict, mail = e.mail })
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
	local T, M, B = CH.Theme, CH.FormatMoney, CH.Window.Book
	local qty = a.qty or 0
	local lines = {
		{ D_LABEL(a) .. ((a.action == "post" or a.action == "fewer") and r.price and ("  at " .. M(r.price)) or ""), "", "muted", "accent" },
		{ T.Color("muted", "Because " .. a.reason .. ".") },
		B.Head("Quantity"),
		B.Text("Recommended", tostring(qty)),
		B.Text("Allowed by your rules", tostring(r.post or 0)),
		B.Sub("Up / cap", string.format("%d / %d", r.up or 0, r.cap or 0)),
		B.Sub("In your bags now", tostring(r.here or 0)),
		B.Head("Price"),
		B.Text("Post at", r.price and M(r.price) or "-"),
		B.Sub("Price from", r.source and string.format("%s, %s ago", SOURCE[r.source] or r.source, CH.Scans and CH.Scans.Age and r.age and CH.Scans.Age(r.age) or "?")
			or T.Color("bad", "no AH scan")),
	}
	if qty > (r.here or 0) then
		lines[#lines + 1] = { T.Color("bad", string.format("Fetch %d first: only %d of them are in this character's bags (the rest are in a bank or on another character).", qty - (r.here or 0), r.here or 0)) }
	end
	if r.min then lines[#lines + 1] = B.Sub("Your min", M(r.min)) end
	if r.why then lines[#lines + 1] = B.Sub("Rule check", r.why) end
	if r.price and qty > 0 then
		lines[#lines + 1] = B.Head("Proceeds")
		lines[#lines + 1] = B.Line(string.format("%d x %s", qty, M(r.price)), r.price * qty)
		lines[#lines + 1] = B.Line("AH cut (5%)", -(r.price * qty * (1 - CH.AH_CUT)), true)
		lines[#lines + 1] = B.Total("After the cut", r.price * qty * CH.AH_CUT)
	end
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
	local now = time()
	local function find(list) for _, e in ipairs(list or {}) do if e.id == r.id then return e end end end
	local L = CH.Ledger
	local rows = {
		{ "Recommended", a and T.Color(ACTION[a.action] or "fg", label) or "-" },
		{ "Allowed by your rules", tostring(r.post or 0) .. T.Color("muted", "  (" .. (r.op or "Default") .. ")") },
		{ "Held / up / cap", string.format("%d / %d / %d", r.held or 0, r.up or 0, r.cap or 0) },
		{ "Price from", r.source and string.format("%s, %s ago", SOURCE[r.source] or r.source, CH.Scans and CH.Scans.Age and r.age and CH.Scans.Age(r.age) or "?")
			or T.Color("bad", "no scan") },
	}
	if r.why then rows[#rows + 1] = { "Rule check", r.why } end
	rows[#rows + 1] = { "Worth to you (EV)", x.ev and M(x.ev) or T.Color("muted", "-") }
	rows[#rows + 1] = { "You've sold for (RZ)", x.realized and M(x.realized) or T.Color("muted", "none sold") }
	-- the market for this one item: what Market prices, Compare prices, When it sells, Competition,
	-- Stock targets and Dead stock showed as separate lists
	local mk = {}
	local m = CH.Prices.MarketAny and CH.Prices.MarketAny(r.id)
	if m then
		local ch = m.change7
		mk[#mk + 1] = { "Market / 7-day avg", M(m.market or m.min or 0) .. T.Color("muted", " / " .. (m.avg7 and M(m.avg7) or "-"))
			.. (ch and T.Color(ch >= 0 and "ok" or "bad", string.format("  %+d%%", math.floor(ch * 100 + 0.5))) or ""),
			tip = { { "Listed now", tostring(m.qty or "-") } } }
	end
	local c = CH.Compare and CH.Compare.Row(r.id)
	if c and c.verdict ~= "no prices" then
		mk[#mk + 1] = { "Sources", T.Color(c.verdict == "cheap now" and "ok" or c.verdict == "pricey now" and "bad" or "muted", c.verdict),
			tip = { { "AH scan", c.ah and M(c.ah) or "-" }, { "TSM market", c.tsm and M(c.tsm) or "-" }, { "Oribos", c.oe and M(c.oe) or "-" },
				{ "Region", c.region and M(c.region) or "-" } } }
	end
	local DAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
	local w = find(L.SaleTimes(now - 90 * 86400))
	if w and w.sold >= 3 then
		mk[#mk + 1] = { "Sells best", string.format("%s %02d:00-%02d:00", DAYS[w.bestDay], w.bestHour, (w.bestHour + 4) % 24)
			.. T.Color(w.share >= 0.4 and "ok" or "muted", string.format("  %d%%", math.floor(w.share * 100 + 0.5))),
			tip = { { "Sales counted", tostring(w.sold) }, { "Post by", string.format("%s %02d:00", DAYS[w.bestDay], (w.bestHour + 23) % 24) } } }
	end
	local cp = find(L.Competition(now - 30 * 86400))
	if cp then
		mk[#mk + 1] = { "Competition", T.Color(cp.status == "contested" and "bad" or cp.status == "busy" and "accent" or "ok", cp.status)
			.. (cp.rival and T.Color("muted", "  " .. cp.rival) or ""),
			tip = { { "Cancels", tostring(cp.cancels) }, { "Undercut", cp.rate and string.format("%d%%", math.floor(cp.rate * 100 + 0.5)) or "-" } } }
	end
	local target, manual
	if CH.Par then target, manual = CH.Par.Target(r.id, now) end
	local dead = find(L.DeadStock(now, 30))
	mk[#mk + 1] = { "Stock target", (target and tostring(target) or T.Color("muted", "none")) .. (manual and T.Color("accent", " (you)") or "")
		.. (dead and T.Color("bad", "  not moving") or ""),
		tip = { { "Shift-click +1, ctrl-click -1, alt-click automatic", "" }, dead and { dead.advice, dead.lastSold and LUI.Ago(dead.lastSold, now) or "never sold" } or nil },
		run = function() LUI.ParClick(r.id) end }
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
		rows = rows, section = { head = "MARKET", rows = mk }, note = T.Color("muted", note), actions = actions }
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

TUI.VIEWS = {
	post = { label = "Ready to post", detail = function(d) return TUI.PostDetail(d) end, sort = 6, asc = true, noTime = true, rows = postRows,
		cols = { { "Item", 0, 220 }, { "Held", 224, 44 }, { "Up / cap", 272, 74 }, { "Price", 350, 110 }, { "AH now", 464, 110 },
		{ "Advice", 578, 146 } } },
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


--- The queue as work for the character you're on: what you can craft now first, then what's blocked,
--- grouped by what unlocks it. { e, short, group (1 ready .. 3 another character), unlock }.
TUI.UNLOCK = { "Ready now", "Buy reagents", "Log in as another character" }
function TUI.ReadyPlan()
	local out = {}
	local here = CH.CharacterKey and CH.CharacterKey()
	for _, x in ipairs(TUI.QueuePlan()) do
		local e = x.e
		local group, unlock
		if e.char ~= here then
			group, unlock = 3, "log in as " .. (e.charName or tostring(e.char or "?"):match("^[^-]+") or "?")
		elseif x.short > 0 then
			group, unlock = 2, string.format("buy %d reagent%s", x.short, x.short == 1 and "" or "s")
		else
			group, unlock = 1, x.status == "turn in" and "turn in" or (e.orderID and (CH.Queue.OrderStep(e) or "craft"):lower()) or "craft"
		end
		table.insert(out, { e = e, short = x.short, group = group, unlock = unlock })
	end
	return out
end

-- The Queue: every queued craft in one list, what you can make here first, each with what's
-- blocking it, and the shopping it needs in the footer.
local function queueRows(ctx)
	local T = CH.Theme
	local out, n, profit = {}, { 0, 0, 0 }, 0
	for _, x in ipairs(TUI.ReadyPlan()) do
		local e = x.e
		if ctx.keepName(e.name) then
			n[x.group] = n[x.group] + 1
			local p = (e.profit or 0) * e.qty
			profit = profit + p
			local name = (e.item and CH.Window.ItemIcon(e.item, 14) or "") .. (e.name or "?") .. (e.quality and T.Color("muted", " Q" .. e.quality) or "")
			table.insert(out, { id = e.item, cells = { name, e.charName or "?", e.qty, e.profit and LUI.Signed(e.profit) or T.Color("muted", "-"),
				e.profit and LUI.Signed(p) or T.Color("muted", "-"), e.concentration and T.Color("accent", "yes") or T.Color("muted", "-"),
				T.Color(x.group == 1 and "ok" or x.group == 2 and "bad" or "fg", x.unlock) },
				sort = { e.name or "", e.charName or "", e.qty, e.profit or 0, p, e.concentration and 1 or 0, x.group * 1e15 - p } })
		end
	end
	if not out[1] then
		return out, T.Color("muted", "Nothing queued. Queue crafts from Compare crafts or the advisor at a profession window.")
	end
	local list, total = CH.Queue.ShoppingList()
	local buys = 0
	for _, r in ipairs(list) do if r.buy > 0 then buys = buys + 1 end end
	local shop = buys > 0 and string.format("%d reagents to buy, about %s (Shopping list).", buys, money(total)) or T.Color("ok", "Nothing to buy.")
	return out, string.format("%s ready here, %d need reagents, %d on other characters. %s expected profit (an estimate). %s",
		T.Color("ok", n[1]), n[2], n[3], money(profit), shop)
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

--- Restock plans: the queue as it is against a lean plan of a few days' sales, each run through the
--- price and sales simulation: gold up front, gold back by the horizon (median and the middle 80%),
--- the chance sales cover the reagents, and the stock left. opts go to Decide.Plan (runs, for the tests).
function TUI.PlanRows(opts)
	local T = CH.Theme
	local out = {}
	if not (CH.db.queue and CH.db.queue[1]) then
		return out, T.Color("muted", "The queue is empty. Queue crafts first, then compare plans here before you buy.")
	end
	local skipped = 0
	for _, plan in ipairs(CH.Decide.Plans()) do
		local r = CH.Decide.Plan(plan.entries, opts)
		skipped = math.max(skipped, r.unpriced or 0)
		table.insert(out, { cells = { T.Color("accent", plan.label), r.crafts, money(r.cash), money(r.back.p50 or 0),
			T.Color("muted", money(r.back.p10 or 0) .. " to " .. money(r.back.p90 or 0)),
			string.format("%d%%", math.floor(r.recover * 100 + 0.5)), money(r.left) },
			sort = { plan.label, r.crafts, r.cash, r.back.p50 or 0, r.back.p10 or 0, r.recover, r.left }, plan = r })
	end
	return out, string.format("Gold back by day %d counts only what sells. Sales from region volume capped at your daily cap; price spread from Scenarios; prices share one market move.", CH.Decide.HORIZON)
		.. (skipped > 0 and T.Color("muted", string.format("   %d entries left out: no scan or price for their item.", skipped)) or "")
end

TUI.PRODUCTION = {
	restock = { label = "Restock plans", noTime = true, rows = function() return TUI.PlanRows() end, cols = { { "Plan", 0, 140 }, { "Crafts", 144, 44 },
		{ "Gold up front", 192, 92 }, { "Gold back, day 7", 288, 108 }, { "Middle 80%", 400, 136 }, { "Covers reagents", 540, 96 }, { "Stock left", 640, 84 } } },
	queue = { label = "Queue", sort = 7, asc = true, noTime = true, rows = queueRows, cols = { { "Craft", 0, 200 }, { "Character", 204, 90 },
		{ "Qty", 298, 36 }, { "Per craft", 338, 80 }, { "Est. profit", 422, 86 }, { "Conc.", 512, 40 }, { "Next step", 556, 168 } } },
	shopping = { label = "Shopping list", sort = 6, noTime = true, rows = shoppingRows, cols = { { "Reagent", 0, 200 }, { "Need", 204, 54 },
		{ "Have", 262, 54 }, { "Buy", 320, 60 }, { "Each", 384, 84 }, { "Cost", 472, 96 }, { "", 572, 152 } } },
}
TUI.MOVING = {
	rules = { label = "Groups and rules", noTime = true, cols = {}, go = function() CH.UI.Go("settings", "groups") end },
}

-- (Core/Views.lua files these under Operations: Trade for what you hold, Queue for the work.)
-- Manage rules opens Settings' groups and posting rules, from Trade.
TUI.MOVING.rules.label = "Manage rules"
LUI.Register("operations", TUI.PRODUCTION, {})
LUI.Register("operations", TUI.VIEWS, {})
LUI.Register("operations", TUI.MOVING, {})
