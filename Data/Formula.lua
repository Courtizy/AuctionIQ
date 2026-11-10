-- Price formulas in TSM's syntax, worked out by AuctionIQ itself, so operations can price the way
-- TSM does without TSM. For example:
--   max(150% vendorsell, saleavg, min(dbmarket, 400% saleavg))
--   ifgte(numexpires, 5, 85% normal, normal)          check(crafting, 125% crafting, 2g)
-- Money: 1g50s20c. "150% x" is 1.5 * x. + - * / and brackets work. A source with no value makes
-- the whole formula have none, except inside min, max, first and avg, which skip missing values.
--
-- Sources, all per item:
--   crafting      what making one costs (AuctionIQ's scan and what you paid for reagents)
--   dbmarket, dbminbuyout, dbhistorical, dbregionmarketavg, dbregionsaleavg, dbregionhistorical,
--   dbregionsoldperday   market data from TSM
--   vendorsell    what a vendor pays
--   avgbuy, avgsell      your own average buy and sale price (ledger)
--   numexpires    times it expired since it last sold (ledger)
--   chvalue, chmat       AuctionIQ's sell value and buy price
--   any custom source you define (imported from TSM's custom sources or added yourself)
local _, CH = ...

local F = {}
CH.Formula = F
local unpack = unpack or table.unpack

local MONEY = { g = 10000, s = 100, c = 1 }

-- Tokens --------------------------------------------------------------------------------------
local function tokenize(s)
	local out, i, n = {}, 1, #s
	while i <= n do
		local c = s:sub(i, i)
		if c:match("%s") then
			i = i + 1
		elseif c:match("[%d%.]") then
			-- a number, maybe money (1g50s) or a percentage (150%)
			local j = i
			local money, total = false, 0
			while true do
				local num, unit = s:match("^(%d*%.?%d+)([gscGSC]?)", j)
				if not num then break end
				local after = s:sub(j + #num + #unit, j + #num + #unit)
				if unit ~= "" and not after:match("[%a_]") then
					money, total = true, total + tonumber(num) * MONEY[unit:lower()]
					j = j + #num + #unit
					if not s:sub(j):match("^%d") then break end
				else
					if money then break end
					total = tonumber(num)
					j = j + #num
					break
				end
			end
			if s:sub(j, j) == "%" and not money then
				table.insert(out, { t = "pct", v = total / 100 }); j = j + 1
			else
				table.insert(out, { t = "num", v = total })
			end
			i = j
		elseif c:match("[%a_]") then
			local w = s:match("^[%w_]+", i)
			table.insert(out, { t = "id", v = w:lower() })
			i = i + #w
		elseif c:match("[%(%),%+%-%*/]") then
			table.insert(out, { t = c })
			i = i + 1
		else
			error("unexpected '" .. c .. "'")
		end
	end
	return out
end

-- Parser: a tree of { op, ... } ----------------------------------------------------------------
local function parse(src)
	local toks, pos = tokenize(src), 1
	local function peek() return toks[pos] end
	local function take(t)
		local k = toks[pos]
		if not k or (t and k.t ~= t) then error("expected " .. (t or "more") .. " in " .. src) end
		pos = pos + 1
		return k
	end
	local expr
	local function starts(k) return k and (k.t == "num" or k.t == "pct" or k.t == "id" or k.t == "(" or k.t == "-") end
	local function factor()
		local k = take()
		if k.t == "num" then return { "n", k.v } end
		if k.t == "pct" then
			-- "150% x" multiplies; a bare "150%" is 1.5
			if starts(peek()) and peek().t ~= "-" then return { "*", { "n", k.v }, factor() } end
			return { "n", k.v }
		end
		if k.t == "-" then return { "neg", factor() } end
		if k.t == "(" then local e = expr(); take(")"); return e end
		if k.t == "id" then
			if peek() and peek().t == "(" then
				take("(")
				local args = {}
				if peek() and peek().t ~= ")" then
					table.insert(args, expr())
					while peek() and peek().t == "," do take(","); table.insert(args, expr()) end
				end
				take(")")
				return { "fn", k.v, args }
			end
			return { "src", k.v }
		end
		error("unexpected " .. k.t .. " in " .. src)
	end
	local function term()
		local a = factor()
		while peek() and (peek().t == "*" or peek().t == "/") do
			local op = take().t
			a = { op, a, factor() }
		end
		return a
	end
	function expr()
		local a = term()
		while peek() and (peek().t == "+" or peek().t == "-") do
			local op = take().t
			a = { op, a, term() }
		end
		return a
	end
	local tree = expr()
	if pos <= #toks then error("unexpected " .. toks[pos].t .. " in " .. src) end
	return tree
end

local compiled = {}
--- The parsed formula, or nil and the error.
function F.Compile(src)
	src = tostring(src or "")
	if compiled[src] ~= nil then return compiled[src] or nil, compiled[src] == false and "invalid" or nil end
	local ok, tree = pcall(parse, src)
	compiled[src] = ok and tree or false
	if not ok then return nil, tostring(tree):gsub("^.-:%d+: ", "") end
	return tree
end

-- Functions -----------------------------------------------------------------------------------
local function vals(args, ctx, ev)
	local out = {}
	for _, a in ipairs(args) do local v = ev(a, ctx); if v then table.insert(out, v) end end
	return out
end
local FN = {
	min = function(a, ctx, ev) local t = vals(a, ctx, ev); return t[1] and math.min(unpack(t)) end,
	max = function(a, ctx, ev) local t = vals(a, ctx, ev); return t[1] and math.max(unpack(t)) end,
	first = function(a, ctx, ev) for _, x in ipairs(a) do local v = ev(x, ctx); if v then return v end end end,
	avg = function(a, ctx, ev)
		local t = vals(a, ctx, ev); if not t[1] then return nil end
		local s = 0; for _, v in ipairs(t) do s = s + v end; return s / #t
	end,
	-- check(x, a, b): a when x is above 0, else b
	check = function(a, ctx, ev) local x = ev(a[1], ctx); if x and x > 0 then return ev(a[2], ctx) end return a[3] and ev(a[3], ctx) end,
	round = function(a, ctx, ev) local x, f = ev(a[1], ctx), a[2] and ev(a[2], ctx) or 1; return (x and f and f > 0) and math.floor(x / f + 0.5) * f or nil end,
	roundup = function(a, ctx, ev) local x, f = ev(a[1], ctx), a[2] and ev(a[2], ctx) or 1; return (x and f and f > 0) and math.ceil(x / f) * f or nil end,
	rounddown = function(a, ctx, ev) local x, f = ev(a[1], ctx), a[2] and ev(a[2], ctx) or 1; return (x and f and f > 0) and math.floor(x / f) * f or nil end,
}
local function compare(test)
	return function(a, ctx, ev)
		local x, y = ev(a[1], ctx), ev(a[2], ctx)
		if x == nil or y == nil then return nil end
		if test(x, y) then return ev(a[3], ctx) end
		return a[4] and ev(a[4], ctx)
	end
end
FN.ifgte = compare(function(x, y) return x >= y end)
FN.ifgt = compare(function(x, y) return x > y end)
FN.iflte = compare(function(x, y) return x <= y end)
FN.iflt = compare(function(x, y) return x < y end)
FN.ifeq = compare(function(x, y) return x == y end)

-- Sources -------------------------------------------------------------------------------------
local TSM_ONLY = { dbmarket = true, dbminbuyout = true, dbhistorical = true, dbregionmarketavg = true, dbregionsaleavg = true,
	dbregionhistorical = true, dbregionsoldperday = true, dbregionsalerate = true, destroy = true }

--- Your own price sources: { [name] = formula }, kept with AuctionIQ's settings.
function F.Custom()
	CH.db.formulas = CH.db.formulas or {}
	return CH.db.formulas
end

local function source(name, ctx, ev)
	local id, level = ctx.id, ctx.level
	local item = level and ("i:" .. id .. "::i" .. level) or ("i:" .. id)
	if ctx.extra and ctx.extra[name] ~= nil then return ctx.extra[name] end
	local custom = F.Custom()[name]
	if custom then
		ctx.depth = (ctx.depth or 0) + 1
		if ctx.depth > 12 then return nil end
		local tree = F.Compile(custom)
		local v = tree and ev(tree, ctx)
		ctx.depth = ctx.depth - 1
		return v
	end
	if name == "crafting" then return CH.Groups and CH.Groups.CostEach and CH.Groups.CostEach(id) or CH.Prices.Raw("crafting", id, level) end
	if name == "vendorsell" then
		local sell = C_Item and C_Item.GetItemInfo and select(11, C_Item.GetItemInfo(id))
		return sell and sell > 0 and sell or nil
	end
	if name == "numexpires" then return CH.Ledger and CH.Ledger.Available() and CH.Ledger.NumExpires(id) or 0 end
	if name == "avgbuy" then
		local p = CH.Ledger and CH.Ledger.Available() and CH.Ledger.Paid()[id]
		return p and p.each
	end
	if name == "avgsell" then return CH.Ledger and CH.Ledger.Available() and CH.Ledger.AvgSell and CH.Ledger.AvgSell(id) or nil end
	if name == "chvalue" or name == "chmat" then return CH.Prices.Get(name, item) end
	if TSM_ONLY[name] then
		return CH.Prices.Raw(name, id, level)
	end
	return CH.Prices.Raw(name, id, level)
end

local function ev(node, ctx)
	local op = node[1]
	if op == "n" then return node[2] end
	if op == "src" then return source(node[2], ctx, ev) end
	if op == "neg" then local v = ev(node[2], ctx); return v and -v end
	if op == "fn" then
		local f = FN[node[2]]
		if not f then return nil end
		return f(node[3], ctx, ev)
	end
	local a, b = ev(node[2], ctx), ev(node[3], ctx)
	if a == nil or b == nil then return nil end
	if op == "+" then return a + b end
	if op == "-" then return a - b end
	if op == "*" then return a * b end
	if op == "/" then return b ~= 0 and a / b or nil end
end

--- A formula's value for an item in copper (or a plain number), or nil when it has none.
--- extra: values for names that should win over the sources (for example { normal = 1234 }).
--- level: price gear at this item level (TSM's i:ID::iLEVEL), as each rank of a crafted rod is.
function F.Value(src, id, extra, level)
	if src == nil or id == nil then return nil end
	if type(src) == "number" then return src end
	local tree = F.Compile(src)
	if not tree then return nil end
	local ok, v = pcall(ev, tree, { id = id, extra = extra, level = level })
	return ok and v or nil
end

--- Whether a formula reads (for the operation editor): true, or false and why not.
function F.Valid(src)
	local tree, err = F.Compile(src)
	return tree ~= nil, err
end
