-- Orders tab: every crafting order the game has listed for the open profession with what it
-- really pays (commission and sellable rewards against the reagents you supply), which ones give a
-- knowledge point (1KP), and the first crafts still worth a point with what each point costs.
-- Click a row to open it, shift-click to queue it.
local _, CH = ...

local OUI = {}
CH.OrdersUI = OUI
local frame, rows, status, modeButtons, heads
local N, W, H = 16, 836, 18
local offset, mode, data = 0, "orders", {}

-- One table for both lists; first crafts use some of the order columns.
local COLS = { { "", 12, 236 }, { "", 250, 104, "LEFT" }, { "", 356, 90 }, { "", 448, 120 }, { "", 570, 90 }, { "", 662, 90 }, { "", 754, 70 } }
local HEADS = {
	orders = { "Order", "From", "Commission", "Rewards", "Reagents", "Profit", "Craft at" },
	first = { "Recipe", "", "Reagents", "Sells for", "", "Point costs", "" },
}

local function money(c)
	if not c then return CH.Theme.Color("muted", "-") end
	return CH.Theme.Color(c >= 0 and "ok" or "bad", CH.FormatMoney(c))
end

local function kpTag(yes) return yes and CH.Theme.Color("accent", " 1KP") or "" end

local function queue(d)
	if not d or not d.row or not d.result then return false end
	if mode == "orders" then
		CH.Queue.Add(d.result, d.row, 1, { orderID = d.orderID, customer = d.from, special = d.kp })
	else
		CH.Queue.Add(d.result, d.row, 1, { firstCraft = true })
	end
	CH.Print("queued 1 x " .. (d.name or "?"))
	return true
end
OUI.Queue = queue

local function click(i)
	local d = data[i + offset]
	if not d then return end
	if IsShiftKeyDown and IsShiftKeyDown() then queue(d)
	elseif C_TradeSkillUI.OpenRecipe then C_TradeSkillUI.OpenRecipe(d.recipeID) end
end

--- Hover lines for a row, for tests too.
function OUI.Lines(d)
	local T, M = CH.Theme, CH.FormatMoney
	local lines = { { T.Color("accent", d.name or "?") .. kpTag(d.kp or mode == "first") } }
	if d.orderID then
		table.insert(lines, { d.kind .. " order", d.from })
		if d.minQuality then table.insert(lines, { "Asks for at least", CH.Window.QualityIcon(d.minQuality, 14, d.tiers) }) end
		table.insert(lines, { "Commission, after the consortium's cut", M(d.commission) })
		for _, rw in ipairs(d.rewards) do
			local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(rw.id)) or ("item " .. rw.id)
			table.insert(lines, { "  " .. rw.count .. " x " .. name .. (rw.knowledge and T.Color("accent", "  knowledge") or ""),
				rw.value and M(rw.value) or T.Color("muted", "can't be sold") })
		end
		if d.ok then
			table.insert(lines, { "Your reagents", M(d.cost or 0) })
			table.insert(lines, { "Profit", money(d.profit) })
			if d.concentration then table.insert(lines, { T.Color("muted", "Needs " .. d.concentration .. " Concentration to reach the quality asked.") }) end
		else
			table.insert(lines, { T.Color("bad", "No craft reaches the quality this order asks for.") })
		end
		table.insert(lines, { T.Color("muted", "Profit counts only rewards that sell. Click to open, shift-click to queue.") })
	else
		table.insert(lines, { "First craft gives", T.Color("accent", "1 knowledge point") })
		table.insert(lines, { "Cheapest reagents", M(d.cost or 0) })
		table.insert(lines, { "The item sells for, after the cut", d.value and M(d.value) or T.Color("muted", "no price") })
		if d.net then table.insert(lines, { d.net >= 0 and "Profit on top of the point" or "The point costs you", money(d.net >= 0 and d.net or -d.net) }) end
		table.insert(lines, { T.Color("muted", "Click to open, shift-click to queue. Queue all adds every one.") })
	end
	return lines
end

local function hover(owner, i)
	local d = data[i + offset]
	if d then CH.Window.Tooltip(owner, OUI.Lines(d)) end
end

local function setMode(m)
	mode, offset = m, 0
	OUI.Open()
end

local function build()
	local Wd, T = CH.Window, CH.Theme
	frame = Wd.New("ClearinghouseOrders", "Orders and first crafts", W, 92 + N * H)
	local all = T.Button(frame.bar, "Queue all", 76, 18)
	all:SetPoint("RIGHT", -26, 0)
	all:SetScript("OnClick", function() OUI.QueueAll() end)
	local first = T.Button(frame.bar, "First crafts", 86, 18)
	first:SetPoint("RIGHT", -106, 0)
	first:SetScript("OnClick", function() if mode ~= "first" then setMode("first") end end)
	local orders = T.Button(frame.bar, "Orders", 60, 18)
	orders:SetPoint("RIGHT", -196, 0)
	orders:SetScript("OnClick", function() if mode ~= "orders" then setMode("orders") end end)
	modeButtons = { orders = orders, first = first }
	status = Wd.Text(frame, 12, -34, W - 24)
	rows = Wd.Table(frame, COLS, N, -54, H, click, hover, W)
	heads = {}
	for j, c in ipairs(COLS) do
		heads[j] = Wd.OneLine(Wd.Text(frame, c[2], -54, c[3], c[4] or (j == 1 and "LEFT" or "RIGHT"), "GameFontDisableSmall"))
		heads[j]:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
	end
	Wd.Wheel(frame, N, function() return offset end, function(v) offset = v end, function() return #data end, OUI.Refresh)
	T.Fonts(frame)
	Wd.Attach("orders", frame)
end

--- Queue every order that pays or gives knowledge, or every first craft. Returns how many.
function OUI.QueueAll()
	local n = 0
	for _, d in ipairs(data) do
		if mode == "first" or (d.ok and ((d.profit or 0) >= 0 or d.kp)) then
			if queue(d) then n = n + 1 end
		end
	end
	if n == 0 then CH.Print(mode == "first" and "no first crafts to queue" or "no orders pay or give knowledge") end
	return n
end

--- Redraw. Returns the row texts, for tests.
function OUI.Refresh()
	if not frame then return {} end
	local T = CH.Theme
	data = mode == "orders" and CH.Orders.List() or CH.Orders.FirstCrafts()
	offset = math.max(0, math.min(offset, #data - N))
	if mode == "orders" then
		local pays, kp = 0, 0
		for _, d in ipairs(data) do
			if d.ok and (d.profit or 0) >= 0 then pays = pays + 1 end
			if d.kp then kp = kp + 1 end
		end
		status:SetText(#data > 0 and string.format("%d orders: %s pay, %s give a knowledge point", #data, T.Color("ok", pays), T.Color("accent", kp))
			or T.Color("muted", "No orders listed. Open the Crafting Orders tab and search Patron and Personal, then come back."))
	else
		local cost = 0
		for _, d in ipairs(data) do if d.net and d.net < 0 then cost = cost - d.net end end
		status:SetText(#data > 0 and string.format("%d first crafts left, %s knowledge points, %s to make them all after selling what they make",
			#data, T.Color("accent", #data), CH.FormatMoney(cost))
			or T.Color("muted", "No first crafts left in this profession, or open a profession to see them."))
	end
	for j, h in ipairs(heads) do h:SetText(HEADS[mode][j]) end
	local out = {}
	for i, r in ipairs(rows) do
		local d = data[i + offset]
		for _, c in ipairs(r.cells) do c:SetText("") end
		if d and mode == "orders" then
			r.cells[1]:SetText(CH.Window.ItemIcon(d.item, 15) .. (d.name or "?")
				.. (d.minQuality and (" " .. CH.Window.QualityIcon(d.minQuality, 14, d.tiers) .. "+") or "") .. kpTag(d.kp))
			r.cells[2]:SetText(d.from)
			r.cells[3]:SetText(money(d.commission))
			r.cells[4]:SetText((d.rewardValue > 0 and money(d.rewardValue) or (d.rewards[1] and T.Color("muted", "unsellable") or T.Color("muted", "-"))))
			r.cells[5]:SetText(d.ok and CH.FormatMoney(d.cost or 0) or T.Color("muted", "-"))
			r.cells[6]:SetText(d.ok and money(d.profit) or T.Color("bad", "can't reach"))
			r.cells[7]:SetText(d.ok and (CH.Window.QualityIcon(d.quality, 14, d.tiers) .. (d.concentration and T.Color("accent", " conc") or "")) or "")
			table.insert(out, string.format("%s from=%s profit=%s kp=%s", d.name, d.from, d.profit and math.floor(d.profit) or "-", tostring(d.kp)))
		elseif d then
			r.cells[1]:SetText(CH.Window.ItemIcon(d.item, 15) .. (d.name or "?") .. kpTag(true))
			r.cells[3]:SetText(d.cost and CH.FormatMoney(d.cost) or T.Color("muted", "-"))
			r.cells[4]:SetText(d.value and CH.FormatMoney(d.value) or T.Color("muted", "no price"))
			r.cells[6]:SetText(d.net and (d.net >= 0 and T.Color("ok", "free, +" .. CH.FormatMoney(d.net)) or T.Color("bad", CH.FormatMoney(-d.net))) or T.Color("muted", "-"))
			table.insert(out, string.format("%s net=%s", d.name, d.net and math.floor(d.net) or "-"))
		end
	end
	for k, b in pairs(modeButtons or {}) do if b.SetAlpha then b:SetAlpha(k == mode and 1 or 0.6) end end
	return out
end

function OUI.Mode() return mode end
function OUI.SetMode(m) setMode(m) end

function OUI.Open()
	if not frame then build() end
	frame:Show()
	return OUI.Refresh()
end

function OUI.IsShown() return frame ~= nil and frame:IsShown() end
