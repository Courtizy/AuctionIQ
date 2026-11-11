-- Settings page of the main window: the options the /aiq commands change, your posting operations
-- with every rule and price formula, and your own price sources. All edits save as you make them.
local _, CH = ...

local SUI = {}
CH.SettingsUI = SUI
local page, selected, opOffset, srcOffset = nil, "Default", 0, 0
local OP_ROWS, SRC_ROWS = 12, 5

local function say(text, bad) if page then page.status:SetText(CH.Theme.Color(bad and "bad" or "muted", text)) end end
local function label(b, t) if b.text then b.text:SetText(t) elseif b.SetText then b:SetText(t) end end
local function box(parent, x, y, w)
	local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	eb:SetSize(w, 20)
	eb:SetPoint("TOPLEFT", x + 6, y + 1)
	eb:SetAutoFocus(false)
	eb:SetScript("OnEscapePressed", function(self) self:ClearFocus(); SUI.Refresh() end)
	return eb
end

function SUI.Select(name) selected = name; SUI.Refresh() end
function SUI.Selected() return selected end

function SUI.Build(p, fs, panel)
	local T, S = CH.Theme, CH.Settings
	page = p
	-- General ------------------------------------------------------------------------------------
	local gen = panel(p, 0, 0, 280, 552)
	fs(gen, 12, -10, 256, "LEFT", "GameFontNormal"):SetText("General")
	p.general = {}
	for i, o in ipairs(S.GENERAL) do
		local y = -34 - (i - 1) * 24
		fs(gen, 12, y - 3, 170, "LEFT"):SetText(o[2])
		local b = T.Button(gen, "", 80, 18)
		b:SetPoint("TOPLEFT", 186, y)
		b:SetScript("OnClick", function() S.Flip(o[1]); if CH.UI.IsShown() then CH.UI.Refresh() end end)
		p.general[i] = { b = b, key = o[1] }
	end
	local cy = -34 - #S.GENERAL * 24
	fs(gen, 12, cy - 3, 170, "LEFT"):SetText("Gold a day: sold a day")
	local minus = T.Button(gen, "-", 18, 18); minus:SetPoint("TOPLEFT", 186, cy)
	p.cap = fs(gen, 204, cy - 3, 42, "CENTER")
	local plus = T.Button(gen, "+", 18, 18); plus:SetPoint("TOPLEFT", 248, cy)
	minus:SetScript("OnClick", function() S.DailyCap(S.DailyCap() - 1); SUI.Refresh() end)
	plus:SetScript("OnClick", function() S.DailyCap(S.DailyCap() + 1); SUI.Refresh() end)

	local gy = cy - 30
	fs(gen, 12, gy, 140, "LEFT", "GameFontNormal"):SetText("Groups")
	local groupsBtn = T.Button(gen, "Edit groups", 110, 18)
	groupsBtn:SetPoint("TOPLEFT", 156, gy + 2)
	groupsBtn:SetScript("OnClick", function() CH.UI.Go("settings", "groups") end)
	groupsBtn:SetScript("OnEnter", function(self) CH.Window.Tooltip(self, { { "The group tree: which items are in which group and their prices." } }) end)
	groupsBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	p.useTSM = T.Button(gen, "", 80, 18); p.useTSM:SetPoint("TOPLEFT", 186, gy - 24)
	fs(gen, 12, gy - 27, 170, "LEFT"):SetText("Use TSM's groups")
	p.useTSM:SetScript("OnClick", function() S.UseTSM(not S.UseTSM()); CH.UI.Refresh() end)
	p.preferTSM = T.Button(gen, "", 80, 18); p.preferTSM:SetPoint("TOPLEFT", 186, gy - 48)
	fs(gen, 12, gy - 51, 170, "LEFT"):SetText("TSM's groups come first")
	p.preferTSM:SetScript("OnClick", function() S.PreferTSM(not S.PreferTSM()); CH.UI.Refresh() end)
	local import = T.Button(gen, "Import TSM rules", 150, 18)
	import:SetPoint("TOPLEFT", 12, gy - 78)
	import:SetScript("OnClick", function()
		local n, err = CH.Groups.ImportTSM()
		if n then
			local head, lines = CH.Groups.ImportSummary(n)
			say("Copied from TSM: " .. head .. "." .. (#lines > 0 and string.format(" %d differences from TSM, listed in chat.", #lines) or ""))
			for _, l in ipairs(lines) do CH.Print(l) end
		else say("Couldn't import: " .. tostring(err), true) end
		CH.UI.Refresh()
	end)
	local my = gy - 104
	fs(gen, 12, my, 256, "LEFT", "GameFontNormal"):SetText("Math")
	p.model = {}
	for i, m in ipairs(S.MODEL) do
		local y = my - 24 - (i - 1) * 24
		fs(gen, 12, y - 3, 170, "LEFT"):SetText(m[2])
		local mm = T.Button(gen, "-", 18, 18); mm:SetPoint("TOPLEFT", 186, y)
		local v = fs(gen, 204, y - 3, 42, "CENTER")
		local mp = T.Button(gen, "+", 18, 18); mp:SetPoint("TOPLEFT", 248, y)
		mm:SetScript("OnClick", function() S.Model(m[1], -1); SUI.Refresh() end)
		mp:SetScript("OnClick", function() S.Model(m[1], 1); SUI.Refresh() end)
		p.model[i] = { key = m[1], value = v }
	end
	local note = fs(gen, 12, my - 24 - #S.MODEL * 24 - 8, 256, "LEFT", "GameFontDisableSmall")
	note:SetText("The /aiq commands still work too.")
	-- About: the logo, the version and where it lives
	local ay0 = my - 24 - #S.MODEL * 24 - 26
	local logo = gen:CreateTexture(nil, "ARTWORK")
	logo:SetTexture("Interface\\AddOns\\AuctionIQ\\Media\\Logo-Branded")
	logo:SetTexCoord(0, 1, 0, 193 / 256)
	logo:SetSize(118, 89)
	logo:SetPoint("TOPLEFT", 12, ay0)
	p.logo = logo
	p.about = {}
	local ver = tostring(CH.version or "dev")
	if ver:find("^@") then ver = "dev build" end -- unpackaged: the toc still says @project-version@
	for i, t in ipairs({ { "Version " .. ver, 0 }, { "Gold-making for", 16 }, { "crafters and traders.", 28 },
		{ "On GitHub:", 42 }, { "Courtizy/AuctionIQ", 54 } }) do
		p.about[i] = fs(gen, 138, ay0 - 6 - t[2], 130, "LEFT", "GameFontDisableSmall")
		t = t[1]
		p.about[i]:SetText(t)
	end

	-- Operations -----------------------------------------------------------------------------------
	local ops = panel(p, 292, 0, 604, 360)
	p.opsTitle = fs(ops, 12, -10, 580, "LEFT", "GameFontNormal")
	p.opList = {}
	for i = 1, OP_ROWS do
		local b = CreateFrame("Button", nil, ops)
		b:SetPoint("TOPLEFT", 8, -32 - (i - 1) * 19)
		b:SetSize(150, 18)
		b.text = fs(b, 4, -2, 146, "LEFT")
		b:SetScript("OnClick", function(self) if self.name then SUI.Select(self.name) end end)
		p.opList[i] = b
	end
	CH.Window.Wheel(ops, OP_ROWS, function() return opOffset end, function(v) opOffset = v end, function() return #S.OpNames() end, SUI.Refresh)
	local by = -32 - OP_ROWS * 19 - 6
	p.nameBox = box(ops, 8, by - 26, 140)
	local new = T.Button(ops, "New", 46, 18); new:SetPoint("TOPLEFT", 8, by)
	new:SetScript("OnClick", function()
		local typed = p.nameBox:GetText()
		local name, err = S.NewOp(typed ~= "" and typed or ("Operation " .. #S.OpNames()), "Default")
		if name then selected = name; p.nameBox:SetText(""); say("Made " .. name .. " from Default.") else say(err, true) end
		SUI.Refresh()
	end)
	local copy = T.Button(ops, "Copy", 46, 18); copy:SetPoint("TOPLEFT", 58, by)
	copy:SetScript("OnClick", function()
		local typed = p.nameBox:GetText()
		local name, err = S.NewOp(typed ~= "" and typed or (selected .. " copy"), selected)
		if name then selected = name; p.nameBox:SetText(""); say("Copied to " .. name .. ".") else say(err, true) end
		SUI.Refresh()
	end)
	local del = T.Button(ops, "Delete", 52, 18); del:SetPoint("TOPLEFT", 108, by)
	del:SetScript("OnClick", function()
		local n, err = S.DeleteOp(selected)
		if n then say(string.format("Deleted %s; %d groups now inherit.", selected, n)); selected = "Default" else say(err, true) end
		CH.UI.Refresh()
	end)
	p.nameBox:SetScript("OnEnterPressed", function(self)
		self:ClearFocus()
		local name, err = S.RenameOp(selected, self:GetText())
		if name then selected = name; self:SetText(""); say("Renamed to " .. name .. ".") else say(err, true) end
		CH.UI.Refresh()
	end)
	fs(ops, 8, by - 50, 150, "LEFT", "GameFontDisableSmall"):SetText("Type a name: New, Copy")
	fs(ops, 8, by - 64, 150, "LEFT", "GameFontDisableSmall"):SetText("or Enter to rename")

	local X = 172
	p.uses = fs(ops, X, -32, 420, "LEFT", "GameFontDisableSmall")
	p.fields = {}
	for i, f in ipairs(S.OP_FIELDS) do
		local col, row = math.floor((i - 1) / 6), (i - 1) % 6
		local x, y = X + col * 216, -54 - row * 24
		fs(ops, x, y - 3, 110, "LEFT"):SetText(f[2])
		local e = { f = f }
		if f[3] == "num" then
			local m = T.Button(ops, "-", 18, 18); m:SetPoint("TOPLEFT", x + 112, y)
			e.val = fs(ops, x + 130, y - 3, 52, "CENTER")
			local pl = T.Button(ops, "+", 18, 18); pl:SetPoint("TOPLEFT", x + 182, y)
			m:SetScript("OnClick", function() S.OpStep(selected, f[1], -1); CH.UI.Refresh() end)
			pl:SetScript("OnClick", function() S.OpStep(selected, f[1], 1); CH.UI.Refresh() end)
		else
			e.button = T.Button(ops, "", 88, 18); e.button:SetPoint("TOPLEFT", x + 112, y)
			e.button:SetScript("OnClick", function() S.OpStep(selected, f[1], 1); CH.UI.Refresh() end)
		end
		p.fields[i] = e
	end
	p.formulas = {}
	local fy = -54 - 6 * 24 - 8
	for i, f in ipairs(S.FORMULAS) do
		local y = fy - (i - 1) * 24
		fs(ops, X, y - 3, 48, "LEFT"):SetText(f[2])
		local eb = box(ops, X + 50, y, 364)
		eb:SetScript("OnEnterPressed", function(self)
			self:ClearFocus()
			local ok, err = S.SetOpFormula(selected, f[1], self:GetText())
			if ok then say(f[2] .. " saved.") else say("That formula doesn't read: " .. tostring(err), true) end
			CH.UI.Refresh()
		end)
		p.formulas[i] = { box = eb, f = f }
	end
	fs(ops, X, fy - 3 * 24 - 2, 420, "LEFT", "GameFontDisableSmall"):SetText("TSM syntax, Enter saves. Blank = the floor and multipliers.")
	local ty = fy - 3 * 24 - 24
	fs(ops, X, ty - 3, 80, "LEFT"):SetText("Try on item")
	p.tryBox = box(ops, X + 80, ty, 70)
	p.tryOut = fs(ops, X + 166, ty - 3, 254, "LEFT")
	p.tryBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); SUI.Refresh() end)

	-- Price sources ------------------------------------------------------------------------------------
	local src = panel(p, 292, -372, 604, 180)
	fs(src, 12, -10, 120, "LEFT", "GameFontNormal"):SetText("Price sources")
	fs(src, 130, -12, 460, "LEFT", "GameFontDisableSmall"):SetText("Your own names for formulas, usable in any operation.")
	p.sources = {}
	for i = 1, SRC_ROWS do
		local y = -34 - (i - 1) * 22
		local r = { name = fs(src, 12, y - 3, 120, "LEFT") }
		r.box = box(src, 136, y, 400)
		r.box:SetScript("OnEnterPressed", function(self)
			self:ClearFocus()
			if not r.key then return end
			local ok, err = S.SetSource(r.key, self:GetText())
			if ok then say(r.key .. " saved.") else say("That formula doesn't read: " .. tostring(err), true) end
			SUI.Refresh()
		end)
		r.del = T.Button(src, "x", 18, 18); r.del:SetPoint("TOPLEFT", 556, y)
		r.del:SetScript("OnClick", function() if r.key then S.DeleteSource(r.key); say("Deleted " .. r.key .. "."); SUI.Refresh() end end)
		p.sources[i] = r
	end
	CH.Window.Wheel(src, SRC_ROWS, function() return srcOffset end, function(v) srcOffset = v end, function() return #S.Sources() end, SUI.Refresh)
	local ay = -34 - SRC_ROWS * 22 - 8
	p.newName = box(src, 6, ay, 120)
	p.newFormula = box(src, 136, ay, 400)
	local add = T.Button(src, "Add", 40, 18); add:SetPoint("TOPLEFT", 552, ay)
	local function addSource()
		local ok, err = S.SetSource(p.newName:GetText(), p.newFormula:GetText())
		if ok then say("Added " .. p.newName:GetText():lower() .. "."); p.newName:SetText(""); p.newFormula:SetText("") else say(tostring(err), true) end
		SUI.Refresh()
	end
	add:SetScript("OnClick", addSource)
	p.newFormula:SetScript("OnEnterPressed", function(self) self:ClearFocus(); addSource() end)

	p.status = fs(gen, 12, -528, 256, "LEFT", "GameFontDisableSmall")
end

--- Redraw. Returns the operation list shown, for tests.
function SUI.Refresh()
	local p = page
	if not p then return {} end
	local T, S = CH.Theme, CH.Settings
	local on = function(v) return v and T.Color("ok", "on") or T.Color("muted", "off") end
	for _, g in ipairs(p.general) do label(g.b, on(S.Get(g.key))) end
	p.cap:SetText(tostring(S.DailyCap()))
	for _, m in ipairs(p.model or {}) do m.value:SetText(select(2, S.Model(m.key))) end
	label(p.useTSM, on(S.UseTSM()))
	label(p.preferTSM, on(S.PreferTSM()))

	local names = S.OpNames()
	if not CH.Groups.Store().ops[selected] then selected = "Default" end
	opOffset = math.max(0, math.min(opOffset, #names - OP_ROWS))
	for i, b in ipairs(p.opList) do
		local n = names[i + opOffset]
		b.name = n
		b.text:SetText(n and (n == selected and T.Color("accent", n) or n) or "")
	end
	local op = CH.Groups.Store().ops[selected]
	p.opsTitle:SetText("Posting operations" .. T.Color("muted", "   editing ") .. T.Color("accent", selected)
		.. (op.imported and T.Color("muted", "  (from TSM, now yours)") or ""))
	local used = S.OpGroups(selected)
	p.uses:SetText(#used > 0 and ("Used by " .. table.concat(used, ", ", 1, math.min(#used, 4)) .. (#used > 4 and string.format(" and %d more", #used - 4) or ""))
		or "No group picks it directly yet: choose it in Edit groups.")
	for _, e in ipairs(p.fields) do
		local k = e.f[1]
		if e.f[3] == "num" then
			local v = S.OpValue(selected, k)
			if k == "cap" and v == 0 then e.val:SetText("target")
			elseif k == "maxExpires" and v == 0 then e.val:SetText("off")
			elseif k == "undercut" and type(v) == "number" then e.val:SetText(v >= 100 and CH.FormatMoney(v, true) or (v .. "c"))
			elseif type(v) == "string" then e.val:SetText("formula")
			else e.val:SetText(tostring(v)) end
		elseif e.f[3] == "bool" then
			label(e.button, on(S.OpValue(selected, k)))
		else
			local _, text = S.OpValue(selected, k)
			label(e.button, text)
		end
	end
	for _, e in ipairs(p.formulas) do
		if not (e.box.HasFocus and e.box:HasFocus() == true) then e.box:SetText(op[e.f[1]] or "") end
	end
	local id = tonumber(p.tryBox:GetText() or "")
	if id then
		local pr = CH.Groups.Prices(id, selected)
		local m = function(c) return c and CH.FormatMoney(c) or "-" end
		p.tryOut:SetText(string.format("min %s, normal %s, max %s", m(pr.min), m(pr.normal), m(pr.max)))
	else
		p.tryOut:SetText(T.Color("muted", "an item ID shows its prices"))
	end

	local list = S.Sources()
	srcOffset = math.max(0, math.min(srcOffset, #list - SRC_ROWS))
	for i, r in ipairs(p.sources) do
		local s = list[i + srcOffset]
		r.key = s and s.name
		r.name:SetText(s and s.name or (i == 1 and #list == 0 and T.Color("muted", "none yet") or ""))
		r.box:SetShown(s ~= nil)
		r.del:SetShown(s ~= nil)
		if s and not (r.box.HasFocus and r.box:HasFocus() == true) then r.box:SetText(s.formula) end
	end
	return names
end
