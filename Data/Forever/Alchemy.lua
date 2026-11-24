-- WoW: Forever Alchemy: see Data/ProfData.lua for the format. Lists fill in as recipes are confirmed
-- in game (/aiq probe) or from a reliable source.
local _, AuctionIQ = ...
AuctionIQ.ProfData.Register("Alchemy", {
	spec = {},
	station = {},
	favor = {},
	cooldown = { ["Transmute: Arcanite"] = 47, ["Transmute: Legionite"] = 47 }, -- essence transmutes 23h
})
