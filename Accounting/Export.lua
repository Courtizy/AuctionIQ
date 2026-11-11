-- The Ledger's Export box: any table as CSV text to copy out.
local _, CH = ...

local EX = {}
CH.Export = EX

local function csvEscape(v)
	v = tostring(v or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("|H.-|h(.-)|h", "%1")
	if v:find("[,\"]") then v = '"' .. v:gsub('"', '""') .. '"' end
	return v
end

--- A Ledger view as CSV text (header + rows, as sorted values, not formatted text).
function EX.CSV(view, opts)
	local v = CH.LedgerUI.VIEWS[view]
	local rows = CH.LedgerUI.Rows(view, opts or { days = 30 })
	local out = {}
	local head = {}
	for _, c in ipairs(v.cols) do table.insert(head, csvEscape(c[1])) end
	table.insert(out, table.concat(head, ","))
	for _, r in ipairs(rows) do
		local cells = {}
		for j = 1, #v.cols do
			local x = r.sort and r.sort[j]
			if j == 1 then x = select(2, CH.LedgerUI.ItemText(r.id)) or r.cells[1] end
			if type(x) == "number" and x ~= math.huge and x ~= -math.huge and x >= 10000 and (v.cols[j][1]:find("Total") or v.cols[j][1]:find("Per") or v.cols[j][1]:find("Value")
				or v.cols[j][1]:find("Revenue") or v.cols[j][1]:find("Profit") or v.cols[j][1]:find("Cost") or v.cols[j][1]:find("Amount") or v.cols[j][1]:find("Avg")) then
				x = string.format("%.2f", x / 10000) -- gold
			end
			table.insert(cells, csvEscape(x))
		end
		table.insert(out, table.concat(cells, ","))
	end
	return table.concat(out, "\n"), #rows
end

local popup
--- A copy box with a Ledger table as CSV: the Ledger's Export button.
function EX.Export(view, opts)
	local text, n = EX.CSV(view, opts)
	if not popup then
		popup = CH.Window.New("AuctionIQExport", "", 640, 400)
		popup.title:SetText(CH.Theme.Color("accent", "Export as CSV"))
		popup.note = popup:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		popup.note:SetPoint("TOPLEFT", 14, -34)
		local scroll = CreateFrame("ScrollFrame", nil, popup, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 14, -52)
		scroll:SetPoint("BOTTOMRIGHT", -34, 14)
		local eb = CreateFrame("EditBox", nil, scroll)
		eb:SetMultiLine(true)
		eb:SetAutoFocus(false)
		eb:SetFontObject("GameFontHighlightSmall")
		eb:SetWidth(580)
		eb:SetScript("OnEscapePressed", function() popup:Hide() end)
		scroll:SetScrollChild(eb)
		popup.box = eb
	end
	popup.box:SetText(text)
	popup.note:SetText(string.format("%s: %d rows, selected. Ctrl+C to copy, then paste into a sheet or your notes.", CH.LedgerUI.VIEWS[view].label, n))
	popup:Show()
	popup.box:SetFocus()
	popup.box:HighlightText()
	return text, n
end
