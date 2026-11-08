-- Probability helpers for the math engine: the Beta distribution (how sure we are of a sell-through
-- rate), Poisson quantiles (stock that covers demand at a service level) and the normal quantile.
-- Plain Lua, no game calls, so the tests run them directly.
local _, CH = ...

local P = {}
CH.Prob = P

local exp, log, sqrt, floor, abs = math.exp, math.log, math.sqrt, math.floor, math.abs

--- log Gamma(x) for x > 0 (Lanczos, g = 7).
local LANCZOS = { 0.99999999999980993, 676.5203681218851, -1259.1392167224028, 771.32342877765313,
	-176.61502916214059, 12.507343278686905, -0.13857109526572012, 9.9843695780195716e-6, 1.5056327351493116e-7 }
function P.LogGamma(x)
	if x < 0.5 then return log(math.pi / abs(math.sin(math.pi * x))) - P.LogGamma(1 - x) end
	x = x - 1
	local a, t = LANCZOS[1], x + 7.5
	for i = 2, 9 do a = a + LANCZOS[i] / (x + i - 1) end
	return 0.5 * log(2 * math.pi) + (x + 0.5) * log(t) - t + log(a)
end

-- Continued fraction for the incomplete beta (Numerical Recipes betacf).
local function betacf(a, b, x)
	local qab, qap, qam = a + b, a + 1, a - 1
	local c, d = 1, 1 - qab * x / qap
	if abs(d) < 1e-30 then d = 1e-30 end
	d = 1 / d
	local h = d
	for m = 1, 200 do
		local m2 = 2 * m
		local aa = m * (b - m) * x / ((qam + m2) * (a + m2))
		d = 1 + aa * d; if abs(d) < 1e-30 then d = 1e-30 end
		c = 1 + aa / c; if abs(c) < 1e-30 then c = 1e-30 end
		d = 1 / d; h = h * d * c
		aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
		d = 1 + aa * d; if abs(d) < 1e-30 then d = 1e-30 end
		c = 1 + aa / c; if abs(c) < 1e-30 then c = 1e-30 end
		d = 1 / d
		local del = d * c
		h = h * del
		if abs(del - 1) < 1e-10 then break end
	end
	return h
end

--- P(X <= x) for X ~ Beta(a, b).
function P.BetaCDF(x, a, b)
	if x <= 0 then return 0 end
	if x >= 1 then return 1 end
	local bt = exp(P.LogGamma(a + b) - P.LogGamma(a) - P.LogGamma(b) + a * log(x) + b * log(1 - x))
	if x < (a + 1) / (a + b + 2) then return bt * betacf(a, b, x) / a end
	return 1 - bt * betacf(b, a, 1 - x) / b
end

--- The standard normal quantile (Acklam's approximation, about 1e-9 relative error).
function P.NormInv(p)
	if p <= 0 then return -math.huge elseif p >= 1 then return math.huge end
	local a = { -39.69683028665376, 220.9460984245205, -275.9285104469687, 138.3577518672690, -30.66479806614716, 2.506628277459239 }
	local b = { -54.47609879822406, 161.5858368580409, -155.6989798598866, 66.80131188771972, -13.28068155288572 }
	local c = { -0.007784894002430293, -0.3223964580411365, -2.400758277161838, -2.549732539343734, 4.374664141464968, 2.938163982698783 }
	local d = { 0.007784695709041462, 0.3224671290700398, 2.445134137142996, 3.754408661907416 }
	local lo = 0.02425
	if p < lo then
		local q = sqrt(-2 * log(p))
		return (((((c[1] * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) * q + c[6]) / ((((d[1] * q + d[2]) * q + d[3]) * q + d[4]) * q + 1)
	elseif p > 1 - lo then
		local q = sqrt(-2 * log(1 - p))
		return -(((((c[1] * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) * q + c[6]) / ((((d[1] * q + d[2]) * q + d[3]) * q + d[4]) * q + 1)
	end
	local q = p - 0.5
	local r = q * q
	return (((((a[1] * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * r + a[6]) * q
		/ (((((b[1] * r + b[2]) * r + b[3]) * r + b[4]) * r + b[5]) * r + 1)
end

--- The smallest s with P(D <= s) >= alpha for D ~ Poisson(mean).
function P.PoissonQuantile(mean, alpha)
	if not mean or mean <= 0 then return 0 end
	alpha = math.min(0.9999, math.max(0, alpha or 0.9))
	if mean > 500 then -- exp(-mean) underflows; the normal approximation is close here
		return math.max(0, math.ceil(mean + P.NormInv(alpha) * sqrt(mean) - 0.5))
	end
	local p = exp(-mean)
	local cdf, s = p, 0
	while cdf < alpha and s < 100000 do
		s = s + 1
		p = p * mean / s
		cdf = cdf + p
	end
	return s
end

--- A sell-through rate as a Beta belief: a prior worth `strength` posts at `prior` (0-1), updated
--- by units sold and expired. { mean, a, b, pUp = P(rate > hi), pDown = P(rate < lo), n }.
function P.SellThrough(sold, expired, prior, strength, hi, lo)
	prior = math.min(0.95, math.max(0.05, prior or 0.5))
	strength = strength or 4
	local a, b = strength * prior + (sold or 0), strength * (1 - prior) + (expired or 0)
	return { a = a, b = b, mean = a / (a + b), n = (sold or 0) + (expired or 0),
		pUp = 1 - P.BetaCDF(hi or 0.8, a, b), pDown = P.BetaCDF(lo or 0.4, a, b) }
end

