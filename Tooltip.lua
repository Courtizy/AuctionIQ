-- Clearinghouse tooltip lines on every item.
local _, CH = ...

local GOLD = { 0.88, 0.66, 0.23 }

function CH.TooltipLines(link)
	local lines = {}
	local value = CH.Prices.Get("chvalue", link)
	if value then
		table.insert(lines, { "Clearinghouse value", CH.FormatMoney(value * CH.AH_CUT) .. " after cut" })
	end
	local mat = CH.Prices.Get("chmat", link)
	if mat and mat ~= value then
		table.insert(lines, { "Clearinghouse buy price", CH.FormatMoney(mat) })
	end
	local profit = CH.Prices.CraftProfit(link)
	if profit then
		local word = profit >= 0 and "Craft profit" or "Craft loss"
		table.insert(lines, { word, CH.FormatMoney(profit) })
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
		tooltip:AddDoubleLine(l[1], l[2], GOLD[1], GOLD[2], GOLD[3], 1, 1, 1)
	end
end

if TooltipDataProcessor and Enum and Enum.TooltipDataType then
	-- A price lookup must never break someone's tooltip, so errors are swallowed here.
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip)
		pcall(onItemTooltip, tooltip)
	end)
end
