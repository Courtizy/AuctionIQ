-- Alerts: a line in chat (and on screen) when Concentration is full on any character, an item you
-- keep at par runs out, or something you hold jumps in price. Each alert repeats at most every 6
-- hours. Also tracks the WoW Token price so gold can be read as tokens. /aiq alerts turns them off.
local _, AuctionIQ = ...

local Al = {}
AuctionIQ.Alerts = Al

local REPEAT = 6 * 3600
local JUMP = 0.3 -- 30% up
local MIN_VALUE = 1000 * 10000 -- only holdings worth 1000g+

local function store()
	AuctionIQ.db.alerts = AuctionIQ.db.alerts or { last = {}, prices = {}, on = true }
	return AuctionIQ.db.alerts
end

local function fire(key, text, now)
	local s = store()
	if s.last[key] and now - s.last[key] < REPEAT then return false end
	s.last[key] = now
	AuctionIQ.Print(text)
	if UIErrorsFrame and UIErrorsFrame.AddMessage then UIErrorsFrame:AddMessage("AuctionIQ: " .. text, 1, 0.82, 0.3) end
	return true
end

--- Check everything once. Returns the alerts that fired (for tests).
function Al.Check(now)
	now = now or time()
	local s = store()
	if s.on == false then return {} end
	local out = {}
	local function add(key, text) if fire(key, text, now) then table.insert(out, text) end end
	-- Concentration full
	for _, c in pairs(AuctionIQ.db.characters or {}) do
		for _, p in pairs(c.professions or {}) do
			local cur, max = AuctionIQ.ConcentrationNow(p, now)
			if cur and max and cur >= max then add("conc:" .. (c.name or "?") .. ":" .. (p.name or "?"), (c.name or "?") .. "'s " .. (p.name or "?") .. " Concentration is full") end
		end
	end
	if AuctionIQ.Ledger and AuctionIQ.Ledger.Available() then
		-- sold out: an item you keep at par with none left
		for _, e in ipairs(AuctionIQ.Par.List(now)) do
			if e.held == 0 and e.weekly > 0 then add("out:" .. e.id, (AuctionIQ.LedgerUI and select(2, AuctionIQ.LedgerUI.ItemText(e.id)) or e.id) .. " sold out (target " .. e.target .. ")") end
		end
		-- price jumps on what you hold
		for _, e in ipairs(AuctionIQ.Ledger.Inventory()) do
			if e.id and e.unit then
				local before = s.prices[e.id]
				if before and e.unit >= before * (1 + JUMP) and e.value >= MIN_VALUE then
					add("jump:" .. e.id, string.format("%s is up %d%% (%s each, you hold %d)", select(2, AuctionIQ.LedgerUI.ItemText(e.id)),
						math.floor((e.unit / before - 1) * 100 + 0.5), AuctionIQ.FormatMoney(e.unit), e.total))
				end
				if not before or now - (s.prices.at or 0) > 86400 then s.prices[e.id] = e.unit end
			end
		end
		if now - (s.prices.at or 0) > 86400 then s.prices.at = now end
	end
	return out
end

function Al.Toggle()
	local s = store()
	s.on = not (s.on ~= false)
	AuctionIQ.Print("alerts " .. (s.on and "on" or "off"))
end

-- WoW Token ---------------------------------------------------------------------------------------
--- The last token price seen (copper) and when.
function Al.Token()
	local t = AuctionIQ.db.token
	return t and t.price, t and t.at
end

--- Gold in tokens, as text: "12.3 tokens". nil when the price isn't known yet.
function Al.InTokens(copper)
	local price = Al.Token()
	if not price or price <= 0 or not copper then return nil end
	return string.format("%.1f tokens", copper / price)
end

local function readToken()
	local p = C_WowTokenPublic and C_WowTokenPublic.GetCurrentMarketPrice and C_WowTokenPublic.GetCurrentMarketPrice()
	if p and p > 0 then AuctionIQ.db.token = { price = p, at = time() } end
end
AuctionIQ.On("TOKEN_MARKET_PRICE_UPDATED", readToken)

AuctionIQ.On("PLAYER_LOGIN", function()
	if C_WowTokenPublic and C_WowTokenPublic.UpdateMarketPrice then C_WowTokenPublic.UpdateMarketPrice() end
	C_Timer.After(20, function() AuctionIQ.Measure("alerts check", pcall, Al.Check) end)
	if C_Timer.NewTicker then C_Timer.NewTicker(300, function() AuctionIQ.Measure("alerts check", pcall, Al.Check) end) end
end)
