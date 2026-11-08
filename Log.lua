-- Craft results log: what each craft really gave (Multicraft extras, reagents Resourcefulness saved,
-- Ingenuity refunds, Concentration spent) against what the advisor expected, so you can see whether
-- the averages hold for you. Kept per character.
local _, CH = ...

local Lg = {}
CH.Log = Lg

local pending -- the craft just started: recipe, expected row

local function log()
	local me = CH.Me()
	me.log = me.log or {}
	return me.log
end

local function price(kind, id) return id and CH.Prices.Get(kind, "i:" .. id) end

--- Called when a craft starts (any craft, ours or the game's Craft button).
function Lg.Started(recipeID, count, concentrate)
	local r = CH.AdvisorUI and CH.AdvisorUI.Current and CH.AdvisorUI.Current()
	local row
	if r and r.recipeID == recipeID then
		row = concentrate and r.bestConc or r.best
	end
	pending = { recipeID = recipeID, count = count or 1, concentrate = concentrate,
		expected = row and row.profit, cost = row and row.cost, mc = row and row.parts and row.parts.mc,
		res = row and row.parts and row.parts.res, ing = row and row.ingenuity, name = r and r.name }
end

--- One crafting result from the game (TRADE_SKILL_ITEM_CRAFTED_RESULT).
function Lg.Result(data)
	if not data then return end
	local recipeID = pending and pending.recipeID or data.recipeID
	if not recipeID then return end
	local L = log()
	local e = L[recipeID] or { crafts = 0, items = 0, mcProcs = 0, extraItems = 0, resProcs = 0, saved = 0,
		ingProcs = 0, concSpent = 0, concRefund = 0, value = 0, cost = 0, expected = 0, expMc = 0, expRes = 0, expIng = 0, concCrafts = 0 }
	L[recipeID] = e
	local info = C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(recipeID)
	e.name = (info and info.name) or (pending and pending.name) or e.name
	e.crafts = e.crafts + 1
	local qty = data.quantity or 1
	e.items = e.items + qty
	local extra = data.multicraft or 0
	if extra > 0 then e.mcProcs = e.mcProcs + 1; e.extraItems = e.extraItems + extra end
	local unit = price("chvalue", data.itemID)
	if unit then e.value = e.value + unit * CH.AH_CUT * qty end
	local saved = 0
	for _, r in ipairs(data.resourcesReturned or {}) do
		local p = price("chmat", r.itemID)
		if p then saved = saved + p * (r.quantity or 0) end
	end
	if #(data.resourcesReturned or {}) > 0 then e.resProcs = e.resProcs + 1 end
	e.saved = e.saved + saved
	if data.hasIngenuityProc then e.ingProcs = e.ingProcs + 1 end
	if (data.concentrationSpent or 0) > 0 then e.concCrafts = e.concCrafts + 1 end
	e.concSpent = e.concSpent + (data.concentrationSpent or 0)
	e.concRefund = e.concRefund + (data.ingenuityRefund or 0)
	if pending then
		e.cost = e.cost + (pending.cost or 0)
		e.expected = e.expected + (pending.expected or 0)
		e.expMc = e.expMc + (pending.mc or 0)
		e.expRes = e.expRes + (pending.res or 0)
		e.expIng = e.expIng + (pending.ing or 0)
		pending.count = pending.count - 1
		if pending.count <= 0 then pending = nil end
	end
	e.at = time()
	if Lg.Changed then Lg.Changed() end
end

--- Rows for the results window: per recipe, actual against expected.
function Lg.Rows()
	local out = {}
	for id, e in pairs(log()) do
		local actual = e.value + e.saved - e.cost
		table.insert(out, { recipeID = id, name = e.name, crafts = e.crafts, actual = actual, expected = e.expected,
			mcRate = e.mcProcs / e.crafts, expMcRate = e.expMc / e.crafts, resRate = e.resProcs / e.crafts,
			expResRate = e.expRes / e.crafts, ingRate = e.concCrafts > 0 and e.ingProcs / e.concCrafts or nil,
			expIngRate = e.concCrafts > 0 and e.expIng / e.concCrafts or nil, e = e })
	end
	table.sort(out, function(a, b) return a.crafts > b.crafts end)
	return out
end

function Lg.Clear() wipe(log()); if Lg.Changed then Lg.Changed() end end

if hooksecurefunc and C_TradeSkillUI and C_TradeSkillUI.CraftRecipe then
	hooksecurefunc(C_TradeSkillUI, "CraftRecipe", function(recipeID, count, _, _, _, concentrate)
		Lg.Started(recipeID, count, concentrate)
	end)
end
CH.On("TRADE_SKILL_ITEM_CRAFTED_RESULT", function(_, data) Lg.Result(data) end)

-- Results window -----------------------------------------------------------------------------
local LUI = {}
CH.LogUI = LUI
local frame, rows
local N, W = 14, 560
local COLS = { { "Recipe", 12, 170 }, { "Crafts", 184, 44 }, { "Multicraft", 230, 76 }, { "Resourceful", 308, 76 },
	{ "Ingenuity", 386, 64 }, { "Profit vs expected", 452, 100 } }

local function pct(a, b)
	if not a then return CH.Theme.Color("muted", "-") end
	local s = string.format("%d%%", math.floor(a * 100 + 0.5))
	if b then s = s .. CH.Theme.Color("muted", string.format("/%d", math.floor(b * 100 + 0.5))) end
	return s
end

function LUI.Refresh()
	if not frame or not frame:IsShown() then return {} end
	local T = CH.Theme
	local data = Lg.Rows()
	frame.note:SetText(#data == 0 and T.Color("muted", "Nothing logged yet. Every craft on this character is recorded here.")
		or T.Color("muted", "Proc rates are what you got / what the advisor expected."))
	local out = {}
	for i, r in ipairs(rows) do
		local d = data[i]
		if d then
			r.cells[1]:SetText(d.name or "?")
			r.cells[2]:SetText(d.crafts)
			r.cells[3]:SetText(pct(d.mcRate, d.expMcRate))
			r.cells[4]:SetText(pct(d.resRate, d.expResRate))
			r.cells[5]:SetText(pct(d.ingRate, d.expIngRate))
			r.cells[6]:SetText(T.Color(d.actual >= d.expected and "ok" or "bad", CH.FormatMoney(d.actual)) .. T.Color("muted", " / " .. CH.FormatMoney(d.expected)))
			table.insert(out, string.format("%s crafts=%d actual=%d expected=%d", d.name or "?", d.crafts, math.floor(d.actual), math.floor(d.expected)))
		else
			for _, c in ipairs(r.cells) do c:SetText("") end
		end
	end
	return out
end

function LUI.Toggle()
	if not frame then
		frame = CH.Window.New("ClearinghouseResults", "Craft results", W, 84 + N * 18)
		local clear = CH.Theme.Button(frame.bar, "Clear", 50, 18)
		clear:SetPoint("RIGHT", -26, 0)
		clear:SetScript("OnClick", function() Lg.Clear() end)
		frame.note = CH.Window.Text(frame, 12, -34, W - 24)
		rows = CH.Window.Table(frame, COLS, N, -54, 18, nil, nil, W)
		CH.Theme.Fonts(frame)
	end
	if frame:IsShown() then frame:Hide() else frame:Show(); LUI.Refresh() end
end

Lg.Changed = function() LUI.Refresh() end
