-- Clearinghouse tooltip lines on every item.
local _, CH = ...


local function itemID(link)
	if type(link) == "number" then return link end
	return tonumber(tostring(link or ""):match("item:(%d+)") or tostring(link or ""):match("^i:(%d+)"))
end

--- The scanned craft that makes this item, on any of your characters: the newest scan wins.
--- Returns the scan row, its accounts (with or without Concentration) and when it was scanned.
function CH.CraftAccounts(id)
	if not id then return nil end
	local found, foundAcc, at
	for _, char in pairs(CH.db.characters or {}) do
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

-- Lines are { left, right, right colour, left colour }. A left text starting with spaces is a
-- line item under the heading above it; four spaces is a detail under a line item.
local function cutPct() return string.format("AH cut (%d%%)", math.floor((1 - CH.AH_CUT) * 100 + 0.5)) end

-- A craft as a statement: revenue (sales, Multicraft, the cut), then reagents itemised, then profit.
local function craftLines(lines, row, acc, at)
	local T, m = CH.Theme, CH.FormatMoney
	local how = acc.concentration and string.format("with Concentration (%d)", acc.concentration) or "without Concentration"
	table.insert(lines, { "Crafting, per craft", T.Color("muted", how .. (at and date and date(", scan %H:%M", at) or "")) })
	-- revenue, before the cut
	local cut = CH.AH_CUT
	local sales, mc = acc.sales or 0, acc.mcGold or 0
	local made = math.floor((acc.made or 0) * 10 + 0.5) / 10
	table.insert(lines, { string.format("  Sales, %g made at %s", made, m((acc.unit or 0) / cut)), m(sales / cut) })
	if mc ~= 0 then
		table.insert(lines, { string.format("  Multicraft, +%.2f items on average", acc.extraItems or 0), "+" .. m(mc / cut), "ok" })
	end
	table.insert(lines, { "  " .. cutPct(), m(-((sales + mc) / cut - (sales + mc))), "bad" })
	table.insert(lines, { "  Revenue after cut", m(sales + mc), nil, "accent" })
	-- reagents, itemised
	table.insert(lines, { "  Reagents", m(-(acc.cost or 0)), "bad" })
	for _, rg in ipairs(acc.reagents or {}) do
		local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(rg.itemID)) or ("item " .. rg.itemID)
		local q = rg.rank and rg.tiers and rg.tiers > 1 and (" " .. CH.Window.QualityIcon(rg.rank, 12, rg.tiers)) or ""
		local n = string.format("%g", math.floor(rg.n * 10 + 0.5) / 10)
		table.insert(lines, { "    " .. n .. "x " .. name .. q, rg.cost and m(rg.cost) or "-", "muted", "muted" })
	end
	local res = acc.resGold or 0
	if res ~= 0 then
		table.insert(lines, { "  Resourcefulness, reagents saved", "+" .. m(res), "ok" })
		table.insert(lines, { "  Reagents after savings", m(-((acc.cost or 0) - res)), "bad", "accent" })
	end
	-- the bottom line
	local good = acc.profit >= 0 and "ok" or "bad"
	table.insert(lines, { "Profit per craft", m(acc.profit), good })
	local items = (acc.made or 1) + (acc.extraItems or 0)
	if items > 0 then
		table.insert(lines, { string.format("  Per item (%.2f a craft)", items), m(acc.profit / items), good })
	end
	if acc.avgConcentration and acc.avgConcentration > 0 then
		table.insert(lines, { string.format("  Per Concentration point (%d)", acc.avgConcentration), m(acc.profit / acc.avgConcentration), good })
	end
end

function CH.TooltipLines(link)
	local lines = {}
	local m = CH.FormatMoney
	local value = CH.Prices.Get("chvalue", link)
	local now, post = CH.Prices.Get("chmat", link), CH.Prices.Get("chpost", link)
	if value then
		-- sale price, the cut, what you keep
		table.insert(lines, { "Clearinghouse value", "" })
		if now and post then
			table.insert(lines, { "    Buy now (lowest listing)", m(now), "muted", "muted" })
			table.insert(lines, { "    Post price", m(post), "muted", "muted" })
			local lower = math.abs(value - math.min(now, post)) < 1
			table.insert(lines, { lower and "  Sale price, the lower" or "  Sale price", m(value) })
		else
			table.insert(lines, { "  Sale price", m(value) })
		end
		table.insert(lines, { "  " .. cutPct(), m(-(value - value * CH.AH_CUT)), "bad" })
		table.insert(lines, { "  Value after cut", m(value * CH.AH_CUT), "ok", "accent" })
		local sold = CH.Prices.Get("avgsell", link)
		if sold then table.insert(lines, { "    Your average sale", m(sold), "muted", "muted" }) end
	elseif now then
		table.insert(lines, { "Clearinghouse buy price", m(now) })
	end
	local row, acc, at = CH.CraftAccounts(itemID(link))
	if row and acc and acc.profit then
		craftLines(lines, row, acc, at)
	else
		local profit = CH.Prices.CraftProfit(link)
		if profit then
			local word = profit >= 0 and "Craft profit" or "Craft loss"
			table.insert(lines, { word, m(profit), profit >= 0 and "ok" or "bad" })
		end
	end
	return lines
end

local function onItemTooltip(tooltip)
	if not CH.db or not CH.db.settings.tooltip or not CH.Prices.Available() then return end
	if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
	local _, link = tooltip:GetItem()
	if not link then return end
	local lines = CH.TooltipLines(link)
	for _, l in ipairs(lines) do
		local r = CH.Theme[l[3] or "fg"]
		local a = CH.Theme[l[4] or (l[1]:sub(1, 2) == "  " and "fg" or "accent")]
		tooltip:AddDoubleLine(l[1], l[2], a[1], a[2], a[3], r[1], r[2], r[3])
	end
end

if TooltipDataProcessor and Enum and Enum.TooltipDataType then
	-- A price lookup must never break someone's tooltip, so errors are swallowed here.
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip)
		pcall(onItemTooltip, tooltip)
	end)
end
