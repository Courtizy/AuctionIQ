-- Layout audit for the test stub: finds frames and text that sit outside their parent panel, and
-- one-line text too long for its width (the game would cut it to "..."). Uses the geometry the
-- stub records (sizes, anchors, parents) and its text width estimate.
local FRAC = { TOPLEFT = { 0, 0 }, TOP = { 0.5, 0 }, TOPRIGHT = { 1, 0 }, LEFT = { 0, 0.5 }, CENTER = { 0.5, 0.5 },
	RIGHT = { 1, 0.5 }, BOTTOMLEFT = { 0, 1 }, BOTTOM = { 0.5, 1 }, BOTTOMRIGHT = { 1, 1 } }
local SLACK = 2

local function plain(t)
	t = tostring(t or "")
	return (t:gsub("|T.-|t", "[i]"):gsub("|A.-|a", "[i]"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- Where a point list puts an object of size w, h inside parent (pw, ph): left, top, w, h, or nil
-- when it is anchored to something other than its parent.
local function rect(o, parent, w, h)
	local pts = rawget(o, "points") or {}
	if #pts == 0 then return nil end
	local pw, ph = parent.w or 0, parent.h or 0
	local function resolve(p)
		local pt, rel, relPt, x, y = p[1], nil, nil, 0, 0
		if type(p[2]) == "number" or p[2] == nil then
			rel, relPt, x, y = parent, pt, p[2] or 0, p[3] or 0
		else
			rel = p[2]
			if type(p[3]) == "string" then relPt, x, y = p[3], p[4] or 0, p[5] or 0 else relPt, x, y = pt, p[3] or 0, p[4] or 0 end
		end
		if rel ~= parent or not FRAC[pt] or not FRAC[relPt] then return nil end
		local ax, ay = FRAC[relPt][1] * pw + x, FRAC[relPt][2] * ph - y
		return pt, ax, ay
	end
	if #pts >= 2 then
		local a, ax, ay = resolve(pts[1])
		local b, bx, by = resolve(pts[2])
		if not a or not b then return nil end
		local l, r = math.min(ax, bx), math.max(ax, bx)
		local t, bt = math.min(ay, by), math.max(ay, by)
		if a:find("LEFT") and b:find("RIGHT") or a:find("RIGHT") and b:find("LEFT") then w = r - l else l = ax - FRAC[a][1] * w end
		if a:find("TOP") and b:find("BOTTOM") or a:find("BOTTOM") and b:find("TOP") then h = bt - t else t = ay - FRAC[a][2] * h end
		return l, t, w, h
	end
	local pt, ax, ay = resolve(pts[1])
	if not pt then return nil end
	return ax - FRAC[pt][1] * w, ay - FRAC[pt][2] * h, w, h
end

local function name(o)
	local bits = {}
	local f = o
	for _ = 1, 4 do
		if type(f) ~= "table" then break end
		local label = rawget(f, "label") or (rawget(f, "t") ~= nil and plain(rawget(f, "t")):sub(1, 30)) or nil
		if not label and rawget(f, "texts") then
			for _, t in ipairs(f.texts) do if t.t and t.t ~= "" then label = plain(t.t):sub(1, 30); break end end
		end
		table.insert(bits, label and ("'" .. label .. "'") or (rawget(f, "kind") or "frame"))
		f = rawget(f, "parent") or rawget(f, "owner")
	end
	return table.concat(bits, " < ")
end

local function shownChain(f)
	local guard = 0
	while type(f) == "table" and guard < 30 do
		if rawget(f, "shown") == false and rawget(f, "parent") then return false end
		f = rawget(f, "parent"); guard = guard + 1
	end
	return true
end

--- Problems under the given roots: { "what: why" }.
function STUB.Audit(roots)
	local out, seen = {}, {}
	local function add(s) if not seen[s] then seen[s] = true; table.insert(out, s) end end
	local function visit(f)
		local pw, ph = f.w or 0, f.h or 0
		if pw > 0 and ph > 0 and f.kind ~= "ScrollFrame" then
			for _, fs in ipairs(f.texts or {}) do
				local text = plain(fs.t)
				if text ~= "" and not fs.hidden and not rawget(fs, "aiqOverhang") then
					local est = STUB.TextWidth(fs.t, fs.font)
					local w = fs.w and fs.w > 0 and fs.w or est
					local oneLine = fs.wrap == false or fs.maxLines == 1
					if fs.w and fs.w > 0 and est > fs.w + 4 and oneLine then
						add(string.format("cut off (%d px of text in %d): %s", est, fs.w, name(fs)))
					end
					local l, t = rect(fs, f, w, 14)
					if l and (l < -SLACK or l + math.min(w, est) > pw + SLACK or t < -SLACK or t > ph - 8) then
						add(string.format("text outside its panel (x %.0f..%.0f of %.0f, y %.0f of %.0f): %s", l, l + math.min(w, est), pw, t, ph, name(fs)))
					end
				end
			end
			for _, k in ipairs(f.kids or {}) do
				if (k.w or 0) > 0 and (k.h or 0) > 0 and shownChain(k) then
					local l, t, w, h = rect(k, f, k.w, k.h)
					if l and (l < -SLACK or t < -SLACK or l + w > pw + SLACK or t + h > ph + SLACK) then
						add(string.format("outside its panel (%d,%d %dx%d in %dx%d): %s", l, t, w, h, pw, ph, name(k)))
					end
				end
				-- a button's own label
				local label = rawget(k, "label")
				if label and (k.w or 0) > 0 and STUB.TextWidth(label, "GameFontHighlight") > k.w - 6 then
					add(string.format("button label too wide (%d px in %d): '%s'", STUB.TextWidth(label, "GameFontHighlight"), k.w, plain(label)))
				end
				for _, t in ipairs(k.texts or {}) do
					if t.points[1] and t.points[1][1] == "CENTER" and (k.w or 0) > 0 and plain(t.t) ~= "" and STUB.TextWidth(t.t, t.font) > k.w - 6 then
						add(string.format("button label too wide (%d px in %d): '%s'", STUB.TextWidth(t.t, t.font), k.w, plain(t.t)))
					end
				end
			end
		end
		for _, k in ipairs(f.kids or {}) do visit(k) end
	end
	for _, r in ipairs(roots) do visit(r) end
	return out
end
