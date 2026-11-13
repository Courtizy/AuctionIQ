-- Draws a specialization tree the way the game lays it out (each tab its own tree: the game's node
-- positions, icons and links) with a knowledge point plan on top: a gold ring and "now > planned" on
-- each node the plan raises, and the plan's step numbers in a badge.
local CH = AuctionIQ -- part of AuctionIQ_Paths, loaded on demand (CH.Paths.Load)

local TV = {}
CH.TreeView = TV

local NODE = 30
local PAD = 26

local stepText = CH.Paths.StepText
TV.StepText = stepText

--- Rank text for a node: "12/30", or "12>20/30" when the plan raises it, "locked" ranks show as 0.
function TV.RankText(rank, max, to)
	local now = math.max(0, rank or -1)
	if to and to > (rank or -1) then return string.format("%d>%d/%d", now, to, max or 0) end
	return string.format("%d/%d", now, max or 0)
end

local function color(t, a) return t[1], t[2], t[3], a or 1 end

--- Where each node of a tab sits. The game's own positions when it gives distinct ones; otherwise
--- (profession trees often report every node at 0,0) a tidy tree: the root on top, each level a row,
--- leaves spread evenly and each parent centred over its children.
function TV.Layout(tab, L)
	local out, seen = {}, {}
	local distinct = 0
	for _, id in ipairs(tab.nodes) do
		local n = L[id]
		local k = (n.x or 0) .. ":" .. (n.y or 0)
		if not seen[k] then seen[k] = true; distinct = distinct + 1 end
	end
	if distinct == #tab.nodes and distinct > 1 then
		for _, id in ipairs(tab.nodes) do out[id] = { x = L[id].x, y = L[id].y } end
		return out
	end
	local kids, roots = {}, {}
	for _, id in ipairs(tab.nodes) do
		local p = L[id].parent
		if p and L[p] then kids[p] = kids[p] or {}; table.insert(kids[p], id) else table.insert(roots, id) end
	end
	local nextLeaf = 0
	local function place(id, depth)
		local c = kids[id]
		local x
		if not c or #c == 0 then
			x = nextLeaf; nextLeaf = nextLeaf + 1
		else
			local sum = 0
			for _, k in ipairs(c) do sum = sum + place(k, depth + 1) end
			x = sum / #c
		end
		out[id] = { x = x, y = depth }
		return x
	end
	for _, r in ipairs(roots) do place(r, 0) end
	return out
end

--- A tree view inside parent at x, y, w by h. Returns the view; view:Draw(tree, tabID, marks, prof)
--- lays out that tab and returns the nodes it drew, for tests.
function TV.New(parent, x, y, w, h)
	local T = CH.Theme
	local v = CreateFrame("Frame", nil, parent)
	v:SetPoint("TOPLEFT", x, y)
	v:SetSize(w, h)
	v.w, v.h = w, h
	v.nodes, v.lines = {}, {}

	local function nodeWidget(i)
		local b = v.nodes[i]
		if b then return b end
		b = CreateFrame("Frame", nil, v, "BackdropTemplate")
		b:SetSize(NODE, NODE)
		b.icon = b:CreateTexture(nil, "ARTWORK")
		b.icon:SetPoint("TOPLEFT", 2, -2)
		b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
		b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		b.ring = b:CreateTexture(nil, "BACKGROUND")
		b.ring:SetAllPoints()
		b.rank = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		b.rank:SetPoint("TOP", b, "BOTTOM", 0, -1)
		b.rank.aiqOverhang = true -- sits under the node on purpose
		b.badge = CreateFrame("Frame", nil, b, "BackdropTemplate")
		b.badge:SetSize(16, 14)
		b.badge:SetPoint("CENTER", b, "TOPRIGHT", -1, -1)
		T.Panel(b.badge, "panel", 1)
		if b.badge.SetBackdropColor then b.badge:SetBackdropColor(color(T.accent)) end
		b.badge.text = b.badge:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		b.badge.text:SetPoint("CENTER", 0, 0)
		b.badge.text:SetTextColor(color(T.bg))
		b:EnableMouse(true)
		b:SetScript("OnEnter", function(self) if self.tip then CH.Window.Tooltip(self, self.tip) end end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		-- the tree calculator: the page decides what a click does
		b:SetScript("OnMouseUp", function(self, button) if self.nodeID and v.onClick then v.onClick(self.nodeID, button) end end)
		v.nodes[i] = b
		return b
	end

	local function line(i)
		local l = v.lines[i]
		if l == nil and v.CreateLine then
			l = v:CreateLine(nil, "BACKGROUND")
			v.lines[i] = l or false
		end
		return l or nil
	end

	function v:Draw(tree, tabID, marks, prof)
		marks = marks or {}
		local tab
		for _, t in ipairs(tree and tree.tabs or {}) do if t.id == tabID then tab = t end end
		for _, b in ipairs(self.nodes) do b:Hide() end
		for _, l in pairs(self.lines) do if l then l:Hide() end end
		local drawn = {}
		if not tab then return drawn end
		local L = tree.layout
		local XY = TV.Layout(tab, L)
		local minX, maxX, minY, maxY
		for _, id in ipairs(tab.nodes) do
			local n = XY[id]
			minX, maxX = math.min(minX or n.x, n.x), math.max(maxX or n.x, n.x)
			minY, maxY = math.min(minY or n.y, n.y), math.max(maxY or n.y, n.y)
		end
		local sx = (maxX > minX) and (self.w - 2 * PAD) / (maxX - minX) or 0
		local sy = (maxY > minY) and (self.h - 2 * PAD - 12) / (maxY - minY) or 0
		local pos, widgets = {}, {}
		for i, id in ipairs(tab.nodes) do
			local n = L[id]
			local xy = XY[id]
			local px = (sx > 0) and PAD + (xy.x - minX) * sx or self.w / 2
			local py = (sy > 0) and PAD + (xy.y - minY) * sy or self.h / 2
			pos[id] = { px, py }
			local b = nodeWidget(i)
			b.nodeID = id
			widgets[id] = b
			b:ClearAllPoints()
			b:SetPoint("CENTER", self, "TOPLEFT", px, -py)
			b.icon:SetTexture(n.icon or 134400)
			local m = marks[id]
			local planned = m and m.to > (n.rank or -1)
			local locked = (n.rank or -1) < 0 and not planned
			if b.icon.SetDesaturated then b.icon:SetDesaturated(locked) end
			b.icon:SetAlpha(locked and 0.5 or 1)
			b.ring:SetColorTexture(color(planned and T.accent or T.line))
			local rankText = TV.RankText(n.rank, n.max, planned and m.to or nil)
			b.rank:SetText(rankText)
			b.rank:SetTextColor(color(planned and T.accent or T.muted))
			b.badge:SetShown(planned and #m.steps > 0)
			if planned then b.badge.text:SetText(stepText(m.steps)); b.badge:SetWidth(math.max(16, 8 + 6 * #stepText(m.steps))) end
			local tip = { { T.Color("accent", n.name or "?") }, { "Rank", TV.RankText(n.rank, n.max) } }
			if planned then table.insert(tip, { "Plan", string.format("+%d points, step %s", m.to - (n.rank or -1), stepText(m.steps)) }) end
			local node = tree.nodes[id]
			if node and prof then
				local perks = {}
				for perkID, th in pairs(node.perks or {}) do table.insert(perks, { th = th, text = CH.Spec.PerkText(prof, perkID) }) end
				table.sort(perks, function(a, c) return a.th < c.th end)
				for _, p in ipairs(perks) do
					if p.text ~= "" then
						local have = (n.rank or -1) >= p.th
						local will = planned and m.to >= p.th
						table.insert(tip, { string.format("  at %d", p.th), T.Color(have and "ok" or will and "accent" or "muted", p.text) })
					end
				end
			end
			b.tip = tip
			b:Show()
			table.insert(drawn, { id = id, rank = rankText, planned = planned, steps = planned and stepText(m.steps) or nil })
		end
		local li = 0
		for _, id in ipairs(tab.nodes) do
			local n = L[id]
			if n.parent and pos[n.parent] then
				li = li + 1
				local l = line(li)
				if l then
					local on = marks[id] and marks[id].to > (n.rank or -1)
					l:SetThickness(on and 3 or 2)
					l:SetColorTexture(color(on and T.accent or T.line))
					l:SetStartPoint("CENTER", widgets[n.parent])
					l:SetEndPoint("CENTER", widgets[id])
					l:Show()
				end
			end
		end
		return drawn
	end
	return v
end
