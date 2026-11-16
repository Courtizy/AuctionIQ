-- AuctionIQ tooltip lines on every item.
local _, AuctionIQ = ...


local function itemID(link)
	if type(link) == "number" then return link end
	return tonumber(tostring(link or ""):match("item:(%d+)") or tostring(link or ""):match("^i:(%d+)"))
end

--- The scanned craft that makes this item, on any of your characters: the newest scan wins.
--- Returns the scan row, its accounts (with or without Concentration) and when it was scanned.
function AuctionIQ.CraftAccounts(id)
	if not id then return nil end
	local found, foundAcc, at
	for _, char in pairs(AuctionIQ.db.characters or {}) do
		for _, p in pairs(char.professions or {}) do
			local scan = p.scan
			for _, r in ipairs(scan and scan.rows or {}) do
				local acc = (r.concItem == id and r.concAccounts) or (r.item == id and r.accounts)
				if acc and (not at or scan.at > at) then found, foundAcc, at = r, acc, scan.at end
			end
		end
	end
	return found, foundAcc, at
end

--- Break-even for an item you craft, from the newest scan: the sale price per item, before the cut,
--- that gets back what the reagents cost you (what you paid for those you hold, today's price for
--- the rest). Returns the price and the scan row, or nil. For the auctioning side to check a list
--- price against.
function AuctionIQ.BreakEvenFor(id)
	local row, acc = AuctionIQ.CraftAccounts(id)
	if not row then return nil end
	local be = (row.concItem == id and acc == row.concAccounts) and row.concBreakEven or row.breakEven
	return be, row
end

-- Lines are { left, right, right colour, left colour }. A left text starting with spaces is a
-- line item under the heading above it; four spaces is a detail under a line item.
local function cutPct() return string.format("AH cut (%d%%)", math.floor((1 - AuctionIQ.AH_CUT) * 100 + 0.5)) end

-- A craft as a statement: revenue (sales, Multicraft, the cut), then reagents itemised, then profit.
local function craftLines(lines, row, acc, at)
	local T, m = AuctionIQ.Theme, AuctionIQ.FormatMoney
	local isConc = acc == row.concAccounts
	local how = acc.concentration and string.format("with Concentration (%d)", acc.concentration) or "without Concentration"
	table.insert(lines, { "Crafting, per craft", T.Color("muted", how .. (at and date and date(", scan %H:%M", at) or "")) })
	-- revenue, before the cut
	-- the sale price (older scans didn't save it: then it's worked back from what you keep)
	local cut = AuctionIQ.AH_CUT
	local sales, mc = acc.sales or 0, acc.mcGold or 0
	local made = math.floor((acc.made or 0) * 10 + 0.5) / 10
	local items = (acc.made or 0) + (acc.extraItems or 0)
	local price = acc.price or (acc.unit or 0) / cut
	table.insert(lines, { string.format("  Sales, %g made at %s", made, m(price)), m(price * (acc.made or 0)) })
	if mc ~= 0 then
		table.insert(lines, { string.format("  Multicraft, +%.2f items on average", acc.extraItems or 0), "+" .. m(price * (acc.extraItems or 0)), "ok" })
	end
	local gross = price * items
	table.insert(lines, { "  " .. cutPct(), m(-(gross * (1 - cut))), "bad" })
	-- deposits lost to expiries and the gold tied up until it sells (Expect.Value)
	local losses = gross * cut - (sales + mc)
	if losses >= 1 then table.insert(lines, { "  Deposits and waiting to sell", m(-losses), "bad" }) end
	table.insert(lines, { "  Revenue after cut", m(sales + mc), nil, "accent" })
	-- reagents, itemised at what they cost you now: yours at what they'd sell for, the rest at the buy price
	local book, rcost = AuctionIQ.ReagentBook(acc, { short = true })
	table.insert(lines, { "  Reagents", m(-rcost), "bad" })
	for k = 2, #book - 1 do
		local l = book[k]
		table.insert(lines, { "  " .. l[1], l[2], "muted", "muted" })
	end
	local res = acc.resGold or 0
	if res ~= 0 then
		table.insert(lines, { "  Resourcefulness, reagents saved", "+" .. m(res), "ok" })
		table.insert(lines, { "  Reagents after savings", m(-(rcost - res)), "bad", "accent" })
	end
	acc = setmetatable({ profit = sales + mc + res - rcost }, { __index = acc })
	-- the bottom line
	local good = acc.profit >= 0 and "ok" or "bad"
	table.insert(lines, { "Profit per craft", m(acc.profit), good })
	if items > 0 then
		table.insert(lines, { string.format("  Per item (%.2f a craft)", items), m(acc.profit / items), good })
	end
	if acc.avgConcentration and acc.avgConcentration > 0 then
		table.insert(lines, { string.format("  Per Concentration point (%d)", acc.avgConcentration), m(acc.profit / acc.avgConcentration), good })
	end
	-- the lowest price that gets back what the reagents cost you: list under it and you lose gold
	local be = isConc and row.concBreakEven or row.breakEven
	if be then table.insert(lines, { "Break-even, each", m(be), "accent" }) end
end

--- Craft or sell, live: crafting and selling the item (buying only the reagents you're short of)
--- against selling the reagents you hold instead, at what they'd bring after the cut.
--- { craft, sell, gain } or nil when you hold none of the craft's reagents.
AuctionIQ.CRAFT_OR_SELL_EVEN = 0.05 -- within 5% of what your reagents would bring, it's about even

function AuctionIQ.CraftOrSell(acc)
	if not (acc and acc.reagents) then return nil end
	local P = AuctionIQ.Prices
	local sell, buy, paid, paidAll = 0, 0, 0, true
	for _, rg in ipairs(acc.reagents) do
		local n = rg.n or 0
		local unit = n > 0 and rg.cost and rg.cost / n or 0
		local own = math.min(n, P.Held and P.Held(rg.itemID) or 0)
		local v = own > 0 and P.SellValue(rg.itemID)
		-- a reagent you hold with no sale price is only worth buying again: today's price
		sell = sell + own * (v or unit)
		buy = buy + (n - own) * unit
		-- what you paid for yours: a sunk cost, shown for context, never in the decision
		if own > 0 then
			local pe = P.PaidEach and P.PaidEach(rg.itemID)
			if pe then paid = paid + own * pe else paidAll = false end
		end
	end
	if sell <= 0 then return nil end
	local craft = (acc.sales or 0) + (acc.mcGold or 0) + (acc.resGold or 0) - buy
	local gain = craft - sell
	-- a small difference isn't worth acting on: about even, so crafting stays the plan
	local verdict = math.abs(gain) <= AuctionIQ.CRAFT_OR_SELL_EVEN * sell and "even" or gain > 0 and "craft" or "sell"
	return { craft = craft, sell = sell, gain = gain, buy = buy, verdict = verdict,
		paid = paidAll and paid > 0 and paid or nil }
end

local function reagentName(rg)
	local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(rg.itemID)) or ("item " .. rg.itemID)
	local q = rg.rank and rg.tiers and rg.tiers > 1 and (" " .. AuctionIQ.Window.QualityIcon(rg.rank, 12, rg.tiers)) or ""
	return string.format("%gx %s%s", math.floor((rg.n or 0) * 10 + 0.5) / 10, name, q)
end

--- A craft's reagents as a Book statement, at today's prices: on the held basis the units you hold
--- cost what they'd sell for after the cut (the opportunity cost) and the rest what they cost to buy.
--- Under each reagent you hold: the opportunity cost, stock, paid, current and sell prices, and what
--- you'd buy (opts.short: one row each for yours and to buy). Returns the lines and the total.
function AuctionIQ.ReagentBook(acc, opts)
	local B, P, M = AuctionIQ.Window.Book, AuctionIQ.Prices, AuctionIQ.FormatMoney
	local held = P.CostBasis and P.CostBasis() == "held"
	local lines, total = { B.Head("Reagents", "per craft") }, 0
	for _, rg in ipairs(acc and acc.reagents or {}) do
		local n = rg.n or 0
		local buy = n > 0 and rg.cost and rg.cost / n or nil
		local stock = held and P.Held and P.Held(rg.itemID) or 0
		local own = math.min(n, stock)
		local v = own > 0 and P.SellValue(rg.itemID) or nil
		local ownEach = v or buy
		local cost
		if (own <= 0 or ownEach) and (own >= n or buy) then cost = own * (ownEach or 0) + (n - own) * (buy or 0) end
		total = total + (cost or 0)
		lines[#lines + 1] = B.Line(reagentName(rg), cost and -cost or nil, true)
		if own > 0 then
			if opts and opts.short then
				lines[#lines + 1] = B.Sub(string.format("%g yours, at sell price", own), M(ownEach or 0))
				if n - own > 0 then lines[#lines + 1] = B.Sub(string.format("%g to buy", n - own), buy and M(buy) or "-") end
			elseif AuctionIQ.Advisor and AuctionIQ.Advisor.HeldText then
				for _, t in ipairs(AuctionIQ.Advisor.HeldText({ id = rg.itemID, own = own, ownEach = ownEach, stock = stock,
					paidEach = P.PaidEach and P.PaidEach(rg.itemID), buyN = n - own, buy = buy })) do lines[#lines + 1] = t end
			end
		end
	end
	if not (acc and acc.reagents and acc.reagents[1]) then total = acc and acc.cost or 0 end -- an older scan: no itemised reagents
	lines[#lines + 1] = B.Total("Total reagents", -total)
	return lines, total
end

--- Craft or sell, as a Book block: crafting (after buying what you're short of) against selling the
--- reagents you hold. Empty when you hold none of them.
function AuctionIQ.CraftOrSellBook(acc)
	local cs = AuctionIQ.CraftOrSell(acc)
	if not cs then return {} end
	local B, M = AuctionIQ.Window.Book, AuctionIQ.FormatMoney
	local out = { B.Head("Craft or sell?", "with the reagents you hold"), B.Line("Craft and sell the item", cs.craft) }
	if cs.buy and cs.buy >= 1 then out[#out + 1] = B.Sub("after buying the rest for", M(cs.buy)) end
	out[#out + 1] = B.Line("Sell your reagents instead", cs.sell)
	if cs.verdict == "even" then
		out[#out + 1] = B.Total("About even, crafting by", cs.gain)
	else
		out[#out + 1] = cs.gain >= 0 and B.Total("Crafting earns more by", cs.gain) or B.Total("Selling the reagents earns more by", cs.gain)
	end
	-- what you paid: sunk, so it doesn't change the choice, but it says what the choice costs you
	if cs.paid then
		out[#out + 1] = B.Text("You paid for yours", M(cs.paid), "muted")
		local best = math.max(cs.sell, cs.sell + cs.gain)
		if best < cs.paid then
			out[#out + 1] = B.Note("They're worth less than you paid: you lose " .. M(cs.paid - best)
				.. " against that either way. The better choice just loses less.")
		end
	end
	return out
end

--- A scanned craft as a statement at today's prices: revenue, reagents (at what they cost you now),
--- Resourcefulness, profit, then craft or sell. For the Scan tab's profit hovers.
function AuctionIQ.CraftBook(acc, title)
	local B, M = AuctionIQ.Window.Book, AuctionIQ.FormatMoney
	local _, rcost = AuctionIQ.ReagentBook(acc)
	local out = { B.Head(title or "Revenue", "per craft") }
	out[#out + 1] = B.Line("Sales after the AH cut", acc.sales or 0)
	if (acc.mcGold or 0) ~= 0 then out[#out + 1] = B.Line("Multicraft", acc.mcGold) end
	out[#out + 1] = B.Head("Costs")
	out[#out + 1] = B.Line("Reagents", -rcost, true)
	if (acc.resGold or 0) ~= 0 then out[#out + 1] = B.Line("Resourcefulness saves", acc.resGold) end
	local profit = (acc.sales or 0) + (acc.mcGold or 0) + (acc.resGold or 0) - rcost
	out[#out + 1] = B.Total("Profit", profit)
	if acc.profit and math.abs(profit - acc.profit) >= 100 then out[#out + 1] = B.Sub("at the scan", M(acc.profit)) end
	for _, l in ipairs(AuctionIQ.CraftOrSellBook(acc)) do out[#out + 1] = l end
	return out, profit
end

local function craftOrSellLines(lines, acc)
	for _, l in ipairs(AuctionIQ.CraftOrSellBook(acc)) do table.insert(lines, l) end
end

function AuctionIQ.TooltipLines(link)
	local lines = {}
	local m = AuctionIQ.FormatMoney
	if AuctionIQ.Unsellable(itemID(link)) then
		return { { "AuctionIQ", AuctionIQ.Theme.Color("muted", "bound: can't go on the AH"), nil, "accent" } }
	end
	local value = AuctionIQ.Prices.Get("aiqvalue", link)
	local now, post = AuctionIQ.Prices.Get("aiqbuy", link), AuctionIQ.Prices.Get("aiqpost", link)
	if value then
		-- sale price, the cut, what you keep
		table.insert(lines, { "AuctionIQ value", "" })
		if now and post then
			table.insert(lines, { "    Buy now (lowest listing)", m(now), "muted", "muted" })
			table.insert(lines, { "    Post price", m(post), "muted", "muted" })
			local lower = math.abs(value - math.min(now, post)) < 1
			table.insert(lines, { lower and "  Sale price, the lower" or "  Sale price", m(value) })
		else
			table.insert(lines, { "  Sale price", m(value) })
		end
		table.insert(lines, { "  " .. cutPct(), m(-(value - value * AuctionIQ.AH_CUT)), "bad" })
		table.insert(lines, { "  Value after cut", m(value * AuctionIQ.AH_CUT), "ok", "accent" })
	elseif now then
		table.insert(lines, { "AuctionIQ buy price", m(now) })
	end
	-- the sell chance and posting rules read all of TSM's records and groups: until login's warm-up
	-- has read them (a few seconds), say so rather than stall the game on a hover
	local L = AuctionIQ.Ledger
	local warm = (not (L and L.Available()) or L.StatsReady()) and (not AuctionIQ.Groups or AuctionIQ.Groups.TSMReady())
	if warm then
		for _, l in ipairs(AuctionIQ.Prices.ValueLines(itemID(link))) do table.insert(lines, l) end
	else
		table.insert(lines, { "  Sell chance and posting", AuctionIQ.Theme.Color("muted", "once TSM's records are read"), "muted", "muted" })
		if L and L.Available() and L.WarmStats then L.WarmStats() end
		if AuctionIQ.Groups and not AuctionIQ.Groups.TSMReady() then AuctionIQ.Groups.WarmTSM() end
	end
	local mk = AuctionIQ.Prices.Market(itemID(link))
	if mk and mk.market then
		table.insert(lines, { "Your AH scan", AuctionIQ.Theme.Color("muted", AuctionIQ.Scans.Age(mk.age) .. " old") })
		table.insert(lines, { "  Market then", m(mk.market) })
		if mk.avg7 and (mk.days or 0) > 1 then
			local ch = mk.change7 and string.format("  %+.0f%% in 7 days", mk.change7 * 100) or ""
			table.insert(lines, { "  7-day average" .. ch, m(mk.avg7), "muted", mk.change7 and (mk.change7 >= 0 and "ok" or "bad") or "muted" })
		end
		if mk.qty then table.insert(lines, { "  Listed now", tostring(mk.qty), "muted", "muted" }) end
	end
	local oeR, oeG = AuctionIQ.Prices.Get("oerealm", link), AuctionIQ.Prices.Get("oeregion", link)
	if not (oeR or oeG) then
		local oe = AuctionIQ.Prices.Oribos(itemID(link))
		if oe then oeR, oeG = oe.market, oe.region end
	end
	if oeR or oeG then
		table.insert(lines, { "Oribos Exchange", "" })
		if oeR then table.insert(lines, { "  Realm", m(oeR), "muted", "muted" }) end
		if oeG then table.insert(lines, { "  Region", m(oeG), "muted", "muted" }) end
	end
	-- how AuctionIQ will post it: its group's operation and prices
	local id = itemID(link)
	local path = warm and id and AuctionIQ.Groups and AuctionIQ.Groups.Path(id)
	if path then
		local ok, p = pcall(AuctionIQ.Groups.Prices, id)
		if ok and p then
			table.insert(lines, { "Posting", AuctionIQ.Theme.Color("muted", (p.op or "?") .. (p.post and "" or ", doesn't post") .. ", " .. path) })
			if p.post and p.normal then
				table.insert(lines, { "  Min / normal / max", m(p.min or 0) .. " / " .. m(p.normal) .. " / " .. m(p.max or p.normal), "muted" })
			end
			if p.maxExpires and p.maxExpires > 0 and AuctionIQ.Ledger and AuctionIQ.Ledger.Available() then
				local n = AuctionIQ.Ledger.NumExpires(id)
				table.insert(lines, { "  Expired since it last sold", string.format("%d of %d", n, p.maxExpires), n >= p.maxExpires and "bad" or "muted" })
			end
		end
	end
	local row, acc, at = AuctionIQ.CraftAccounts(itemID(link))
	if row and acc and acc.profit then
		craftLines(lines, row, acc, at)
		craftOrSellLines(lines, acc)
	else
		local profit = AuctionIQ.Prices.CraftProfit(link)
		if profit then
			local word = profit >= 0 and "Craft profit" or "Craft loss"
			table.insert(lines, { word, m(profit), profit >= 0 and "ok" or "bad" })
		end
	end
	return lines
end

local function onItemTooltip(tooltip)
	if not AuctionIQ.db or not AuctionIQ.db.settings.tooltip or not AuctionIQ.Prices.Available() then return end
	if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
	local _, link = tooltip:GetItem()
	if not link then return end
	local lines = AuctionIQ.TooltipLines(link)
	for _, l in ipairs(lines) do
		local r = AuctionIQ.Theme[l[3] or "fg"]
		local a = AuctionIQ.Theme[l[4] or (l[1]:sub(1, 2) == "  " and "fg" or "accent")]
		tooltip:AddDoubleLine(l[1], l[2], a[1], a[2], a[3], r[1], r[2], r[3])
	end
end

if TooltipDataProcessor and Enum and Enum.TooltipDataType then
	-- A price lookup must never break someone's tooltip, so errors are swallowed here.
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip)
		AuctionIQ.Measure("item tooltip", pcall, onItemTooltip, tooltip)
	end)
end
