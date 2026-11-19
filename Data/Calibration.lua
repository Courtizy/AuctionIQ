-- Forecast calibration: how the forecasts behind each batch you queued held up, one part at a time,
-- so a miss can be traced to the forecast that made it.
--
-- Each batch decision (Forecast.SaveDecision) keeps what it forecast; the crafts that fill it and
-- the sales matched to them (Forecast.Explain) say what happened. For each decision at least a
-- day past its first craft, four forecasts are measured apart, each as actual / forecast - 1:
--
--   price    what an item sold for after the cut, against the forecast net an item. Its range is
--            the Scenarios price fall either way (the forecast's 10% and 90% points)
--   volume   units sold so far against the forecast sales over the same days, from what was really
--            made (so a yield miss isn't counted twice). Its range is the 80% band of a Poisson at
--            the forecast rate, at most what was made
--   yield    items a craft made against the items a craft was forecast to make (Multicraft). No
--            range is kept for it: bias and typical error only
--   cost     what the reagents cost against the forecast reagents a craft. Its range is the
--            Scenarios reagent rise either way
--
-- For each, over a group of decisions: how many were checked, the bias (the average error: + means
-- the actual came in above the forecast), the typical error (the median of the errors' sizes) and,
-- where there's a range, the share that landed inside it. An 80% range that holds well under 80% of
-- outcomes is too narrow; one that holds nearly all of them is too wide. Grouped by horizon (days
-- since the first craft) and by how strong the sales evidence was when you queued it.
local _, AuctionIQ = ...

local Cb = { MIN_DAYS = 1, HORIZONS = { { 3, "1 to 3 days" }, { 7, "3 to 7 days" }, { math.huge, "a week or more" } },
	MIN_JUDGE = 10, NARROW = 0.65, WIDE = 0.95 }
AuctionIQ.Calibration = Cb

local DAY = 86400
Cb.MEASURES = { { "price", "Sale price" }, { "volume", "Sales volume" }, { "yield", "Yield" }, { "cost", "Reagent cost" } }

local function horizon(days)
	for _, h in ipairs(Cb.HORIZONS) do if days < h[1] then return h[2] end end
	return Cb.HORIZONS[#Cb.HORIZONS][2]
end

--- One decision's samples: { { measure, error, inside (true/false, nil without a range), horizon,
--- strength } }. Empty before it can be checked.
function Cb.Samples(d, now)
	local Fc, D, P = AuctionIQ.Forecast, AuctionIQ.Decide, AuctionIQ.Prob
	local out = {}
	if not (Fc and d and (d.crafts or 0) > 0) then return out end
	now = now or time()
	local days = (now - (d.first or d.at)) / DAY
	if days < Cb.MIN_DAYS then return out end
	local x = Fc.Explain(d, now)
	if not x then return out end
	local sc = D and D.Scenario() or { price = 0.1, reagents = 0.1 }
	local h = horizon(days)
	local strength = d.plan and d.plan.strength or "unknown"
	local function add(measure, err, inside)
		if err and err == err and err > -math.huge and err < math.huge then
			out[#out + 1] = { measure = measure, error = err, inside = inside, horizon = h, strength = strength }
		end
	end
	if x.sold > 0 and (d.netEach or 0) > 0 then
		local e = x.revenue / x.sold / d.netEach - 1
		add("price", e, math.abs(e) <= sc.price + 1e-9)
	end
	local mean = (d.daily or 0) * days
	local made = x.made or 0
	local forecast = math.min(made, mean)
	if forecast > 0 then
		local lo = math.min(made, P.PoissonQuantile(mean, 0.1))
		local hi = math.min(made, P.PoissonQuantile(mean, 0.9))
		add("volume", x.sold / forecast - 1, x.sold >= lo and x.sold <= hi)
	end
	if (d.itemsEach or 0) > 0 and made > 0 then add("yield", made / d.crafts / d.itemsEach - 1, nil) end
	local fcost = d.crafts * (d.costEach or 0)
	if fcost > 0 and (d.paid or 0) > 0 then
		local e = d.paid / fcost - 1
		add("cost", e, math.abs(e) <= sc.reagents + 1e-9)
	end
	return out
end

local function median(t)
	if #t == 0 then return nil end
	table.sort(t)
	local m = (#t + 1) / 2
	return (t[math.floor(m)] + t[math.ceil(m)]) / 2
end

--- Every check, summed up: { [measure] = { all = s, horizon = { [label] = s }, strength = { [s] = s } } }
--- with each s = { n, bias, typical, ranged, inside, coverage, verdict ("narrow" | "wide" | nil) }.
--- decisions: the list to check (Forecast.Decisions() by default).
function Cb.Summary(now, decisions)
	local acc = {}
	local function bucket(m, kind, key)
		acc[m] = acc[m] or { all = { errs = {}, abs = {}, ranged = 0, inside = 0 }, horizon = {}, strength = {} }
		if kind == "all" then return acc[m].all end
		local t = acc[m][kind]
		t[key] = t[key] or { errs = {}, abs = {}, ranged = 0, inside = 0 }
		return t[key]
	end
	local list = decisions or (AuctionIQ.Forecast and AuctionIQ.Forecast.Decisions()) or {}
	for _, d in ipairs(list) do
		for _, s in ipairs(Cb.Samples(d, now)) do
			for _, b in ipairs({ bucket(s.measure, "all"), bucket(s.measure, "horizon", s.horizon), bucket(s.measure, "strength", s.strength) }) do
				b.errs[#b.errs + 1] = s.error
				b.abs[#b.abs + 1] = math.abs(s.error)
				if s.inside ~= nil then
					b.ranged = b.ranged + 1
					if s.inside then b.inside = b.inside + 1 end
				end
			end
		end
	end
	local function finish(b)
		local sum = 0
		for _, e in ipairs(b.errs) do sum = sum + e end
		local n = #b.errs
		local out = { n = n, bias = n > 0 and sum / n or nil, typical = median(b.abs), ranged = b.ranged, inside = b.inside }
		out.coverage = b.ranged > 0 and b.inside / b.ranged or nil
		if out.coverage and b.ranged >= Cb.MIN_JUDGE then
			out.verdict = out.coverage < Cb.NARROW and "narrow" or out.coverage > Cb.WIDE and "wide" or nil
		end
		return out
	end
	local out = {}
	for m, a in pairs(acc) do
		local o = { all = finish(a.all), horizon = {}, strength = {} }
		for k, b in pairs(a.horizon) do o.horizon[k] = finish(b) end
		for k, b in pairs(a.strength) do o.strength[k] = finish(b) end
		out[m] = o
	end
	return out
end

local function pct(x) return x and string.format("%+.0f%%", x * 100) or "-" end
Cb.Pct = pct

--- "runs 12% low" / "runs 8% high" / "on target" for a bias (actual against forecast).
function Cb.BiasText(b)
	if not b then return "-" end
	if math.abs(b) < 0.02 then return "on target" end
	-- actual above forecast: the forecast runs low
	return string.format("runs %d%% %s", math.floor(math.abs(b) * 100 + 0.5), b > 0 and "low" or "high")
end

--- "8 of 10 inside (80%)", with "too narrow" / "too wide" once there are enough to say.
function Cb.CoverageText(s)
	if not (s and s.coverage) then return "no range kept" end
	local t = string.format("%d of %d inside (%d%%)", s.inside, s.ranged, math.floor(s.coverage * 100 + 0.5))
	if s.verdict == "narrow" then t = t .. ", range too narrow" elseif s.verdict == "wide" then t = t .. ", range too wide" end
	return t
end
