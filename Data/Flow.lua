-- Production, sales and stock left, week by week: am I making this faster than it sells?
--
--   made    units your crafts made (the craft log's batches, Forecast.lua)
--   sold    units sold (TSM's sales records)
--   bought  units bought (TSM's buy records)
--   stock   units held plus up on the AH at the end of each week, worked back from today's count:
--           stock(end of week w) = stock now - (made + bought - sold) after week w
-- The stock line is an estimate: what leaves by mail, the vendor or as a reagent in your own
-- crafts isn't in these records, so it can read high. Weeks are the 7-day blocks ending today.
local _, AuctionIQ = ...

local Fl = { WEEKS = 8, FASTER = 1.25 }
AuctionIQ.Flow = Fl

local DAY = 86400

--- Week by week for an item: { weeks = { { from (day), made, sold, bought, stock } }, made, sold,
--- bought, stockNow, verdict ("faster", "slower", "even" or nil with too little to say), text }.
function Fl.Weekly(id, weeks, now)
	weeks = weeks or Fl.WEEKS
	now = now or time()
	local today = math.floor(now / DAY)
	local first = today - 7 * weeks + 1
	local from = first * DAY
	local out = { weeks = {}, made = 0, sold = 0, bought = 0 }
	for w = 1, weeks do out.weeks[w] = { from = first + 7 * (w - 1), made = 0, sold = 0, bought = 0 } end
	local function week(t)
		local w = math.floor((math.floor(t / DAY) - first) / 7) + 1
		return out.weeks[w]
	end
	-- after-today flows can't exist; flows inside the window go to their week
	for _, b in ipairs(AuctionIQ.Forecast and AuctionIQ.Forecast.Store() or {}) do
		if b.id == id and b.at and b.at >= from and b.at <= now then
			local w = week(b.at)
			if w then w.made = w.made + (b.qty or 0) end
		end
	end
	local L = AuctionIQ.Ledger
	if L and L.Available() then
		local F = L.F
		for kind, key in pairs({ Sales = "sold", Buys = "bought" }) do
			local list = L.ByTime(kind)
			for i = L.From(list, from), #list do
				local r = list[i]
				local t = r[F.time]
				if t and t > now then break end
				if r[F.id] == id and t then
					local w = week(t)
					if w then w[key] = w[key] + (r[F.quantity] or 0) end
				end
			end
		end
	end
	local held = AuctionIQ.Par and AuctionIQ.Par.Held and AuctionIQ.Par.Held(id) or 0
	local up = AuctionIQ.Auction and AuctionIQ.Auction.Listed and AuctionIQ.Auction.Listed(id) or 0
	out.stockNow = (held or 0) + (up or 0)
	local stock = out.stockNow
	for w = weeks, 1, -1 do
		local x = out.weeks[w]
		x.stock = math.max(0, stock)
		stock = stock - x.made - x.bought + x.sold
		out.made, out.sold, out.bought = out.made + x.made, out.sold + x.sold, out.bought + x.bought
	end
	if out.made + out.sold > 0 then
		if out.made > out.sold * Fl.FASTER and out.weeks[weeks].stock > out.weeks[1].stock then out.verdict = "faster"
		elseif out.sold > out.made * Fl.FASTER then out.verdict = "slower"
		else out.verdict = "even" end
	end
	out.text = Fl.Text(out, weeks)
	return out
end

--- One line: "Over 8 weeks you made 40 and sold 25: making faster than it sells, 15 more in stock."
function Fl.Text(f, weeks)
	if not f.verdict then return string.format("Nothing made or sold in the last %d weeks.", weeks or Fl.WEEKS) end
	local s = string.format("Over %d weeks you made %d and sold %d", weeks or Fl.WEEKS, f.made, f.sold)
	if f.verdict == "faster" then
		return s .. string.format(": making faster than it sells, stock up from %d to %d.", f.weeks[1].stock, f.weeks[#f.weeks].stock)
	elseif f.verdict == "slower" then
		return s .. ": selling faster than you make it."
	end
	return s .. ": making about as fast as it sells."
end

--- The chart for the item card: weekly bars (made, sold) and the stock line, on one axis of units.
--- nil when there's nothing to draw.
function Fl.Chart(id, now)
	local f = Fl.Weekly(id, Fl.WEEKS, now)
	if not f.verdict then return nil end
	local bars, line, hi = {}, {}, 0
	for i, w in ipairs(f.weeks) do
		bars[i] = { w.made, w.sold }
		line[i] = w.stock
		hi = math.max(hi, w.made, w.sold, w.stock)
	end
	local function label(day)
		local ok, s = pcall(function() return date("%b %d", day * DAY) end)
		return ok and s or ("day " .. day)
	end
	return { kind = "bars", head = string.format("MADE, SOLD AND STOCK, %d WEEKS", #f.weeks), bars = bars, values = line,
		hi = hi, from = label(f.weeks[1].from), to = label(f.weeks[#f.weeks].from + 6), flow = f }
end
