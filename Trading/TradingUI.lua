-- Trading tab: what to do at the auction house and the mailbox, worked out before you get there.
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
				local price = p.normal
				if ah and price and ah < price then price = math.max(ah - (p.undercut or 1), p.min or 0) end
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

local function postRows(ctx)
	local T = CH.Theme
	local out, n, worth, held, full = {}, 0, 0, 0, 0
	for _, r in ipairs(TUI.PostPlan()) do
		local text, name = LUI.ItemText(r.id)
		if ctx.keepName(name) then
			if r.verdict == "post" then n, worth = n + r.post, worth + r.value
			elseif r.verdict == "hold" then held = held + 1
			else full = full + 1 end
			local v = VERDICT[r.verdict]
			table.insert(out, { id = r.id, cells = { text, T.Color("muted", r.path), r.held, string.format("%d / %d", r.up, r.cap or 0),
				r.post > 0 and r.post or T.Color("muted", "0"), money(r.price), r.ah and money(r.ah) or T.Color("muted", "no scan"),
				T.Color(v[1], v[2]) },
				sort = { name, r.path, r.held, r.up, r.verdict == "post" and r.post or -1, r.price or 0, r.ah or 0,
					(r.verdict == "post" and 0 or r.verdict == "hold" and 1 or 2) * 1e15 - r.value } })
		end
	end
	if not CH.Ledger.Available() then
		return out, T.Color("muted", "Needs TradeSkillMaster: it counts what each character holds.")
	end
	if not out[1] then
		return out, T.Color("muted", "Nothing to post: no items you hold are in a posting group. Set groups up in Settings, Edit groups.")
	end
	return out, string.format("%s to post, worth %s after the cut", T.Color("ok", n), money(worth))
		.. (held > 0 and T.Color("bad", string.format("   %d held: the AH is under your min", held)) or "")
		.. (full > 0 and T.Color("muted", string.format("   %d at their cap", full)) or "")
		.. T.Color("muted", "   Post them at the AH: Auctioning opens beside it.")
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
	post = { label = "Ready to post", sort = 8, asc = true, noTime = true, rows = postRows, cols = { { "Item", 0, 176 }, { "Group", 180, 96 },
		{ "Held", 280, 44 }, { "Up / cap", 328, 60 }, { "Post", 392, 40 }, { "Price", 436, 84 }, { "AH now", 524, 84 }, { "Do", 612, 112 } } },
	mail = { label = "To mail", sort = 5, noTime = true, rows = mailRows, cols = { { "Item", 0, 200 }, { "From", 204, 100 }, { "To", 308, 100 },
		{ "Qty", 412, 50 }, { "Worth", 466, 100 }, { "", 570, 154 } } },
}

LUI.Register("trading", TUI.VIEWS, { "post", "mail" })
