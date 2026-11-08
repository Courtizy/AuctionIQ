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

-- Accounting lines for a craft, TSM-style: reagents, sales, procs, profit. Indented sub-lines.
local function craftLines(lines, row, acc, at)
	local T, m = CH.Theme, CH.FormatMoney
	local how = acc.concentration and string.format("with Concentration (%d)", acc.concentration) or "without Concentration"
	table.insert(lines, { "Crafting, per craft", T.Color("muted", how .. (at and date and date(", scan %H:%M", at) or "")), "accent" })
	for _, rg in ipairs(acc.reagents or {}) do
		local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(rg.itemID)) or ("item " .. rg.itemID)
		local q = rg.rank and rg.tiers and rg.tiers > 1 and (" " .. CH.Window.QualityIcon(rg.rank, 12, rg.tiers)) or ""
		local n = string.format("%g", math.floor(rg.n * 10 + 0.5) / 10)
		table.insert(lines, { "    " .. name .. q .. " x" .. n, rg.cost and m(rg.cost) or "-", "muted" })
	end
	table.insert(lines, { "  Reagents", m(-(acc.cost or 0)), "bad" })
	if acc.sales then
		table.insert(lines, { string.format("  Sales, %g made at %s", math.floor((acc.made or 0) * 10 + 0.5) / 10, m(acc.unit or 0)), m(acc.sales) })
	end
	if (acc.mcGold or 0) ~= 0 then
		table.insert(lines, { string.format("  Multicraft, +%.2f items on average", acc.extraItems or 0), "+" .. m(acc.mcGold), "ok" })
	end
	if (acc.resGold or 0) ~= 0 then table.insert(lines, { "  Resourcefulness, reagents saved", "+" .. m(acc.resGold), "ok" }) end
	local items = (acc.made or 1) + (acc.extraItems or 0)
	table.insert(lines, { "  Profit per craft", m(acc.profit), acc.profit >= 0 and "ok" or "bad" })
	if items > 0 then
		table.insert(lines, { string.format("  Profit per item (%.2f a craft)", items), m(acc.profit / items), acc.profit >= 0 and "ok" or "bad" })
	end
	if acc.avgConcentration and acc.avgConcentration > 0 then
		table.insert(lines, { "  Per Concentration point", m(acc.profit / acc.avgConcentration), "ok" })
	end
end

function CH.TooltipLines(link)
	local lines = {}
	local shownNow
	local value = CH.Prices.Get("chvalue", link)
	if value then
		table.insert(lines, { "Clearinghouse value", CH.FormatMoney(value * CH.AH_CUT) .. " after cut" })
		local now, post = CH.Prices.Get("chmat", link), CH.Prices.Get("chpost", link)
		shownNow = now and post
		if shownNow then
			table.insert(lines, { "    Lower of buy now / post price", CH.FormatMoney(now) .. " / " .. CH.FormatMoney(post), "muted" })
		end
		local sold = CH.Prices.Get("avgsell", link)
		if sold then table.insert(lines, { "    Your average sale", CH.FormatMoney(sold), "muted" }) end
	end
	local mat = CH.Prices.Get("chmat", link)
	if mat and mat ~= value and not shownNow then
		table.insert(lines, { "Clearinghouse buy price", CH.FormatMoney(mat) })
	end
	local row, acc, at = CH.CraftAccounts(itemID(link))
	if row and acc and acc.profit then
		craftLines(lines, row, acc, at)
	else
		local profit = CH.Prices.CraftProfit(link)
		if profit then
			local word = profit >= 0 and "Craft profit" or "Craft loss"
			table.insert(lines, { word, CH.FormatMoney(profit), profit >= 0 and "ok" or "bad" })
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
		local a, r = CH.Theme.accent, CH.Theme[l[3] or "fg"]
		if l[1]:sub(1, 2) == "  " then a = CH.Theme.fg end
		tooltip:AddDoubleLine(l[1], l[2], a[1], a[2], a[3], r[1], r[2], r[3])
	end
end

if TooltipDataProcessor and Enum and Enum.TooltipDataType then
	-- A price lookup must never break someone's tooltip, so errors are swallowed here.
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip)
		pcall(onItemTooltip, tooltip)
	end)
end
