-- WoW: Forever Tailoring: see Data/ProfData.lua for the format. Lists fill in as recipes are confirmed
-- in game (/aiq probe) or from a reliable source.
local _, AuctionIQ = ...
AuctionIQ.ProfData.Register("Tailoring", {
	spec = {},
	station = {},
	favor = {},
	cooldown = { Mooncloth = 95 },
})
