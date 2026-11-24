-- Which game this is. One codebase runs on retail (Midnight) and on WoW: Forever, which is its own
-- game version (WOW_PROJECT_ID 18, interface 16001) with the retail addon API but no crafting
-- quality, Concentration, specializations or crafting orders. Each game has its own WTF folder, so
-- saved data never mixes. Forever loads AuctionIQ_Camelot.toc ("Camelot" is its codename), which
-- leaves the retail-only files out; shared screens read AuctionIQ.Game for the small differences.
local _, AuctionIQ = ...

local RETAIL, FOREVER = 1, 18

--- "retail", "forever" or "other". A game this doesn't know is treated like retail.
function AuctionIQ.DetectGame(projectID)
	projectID = projectID or WOW_PROJECT_ID
	if projectID == FOREVER then return "forever" end
	if projectID == nil or projectID == RETAIL then return "retail" end
	return "other"
end

AuctionIQ.Game = AuctionIQ.DetectGame()
function AuctionIQ.IsForever() return AuctionIQ.Game == "forever" end
function AuctionIQ.IsRetail() return AuctionIQ.Game ~= "forever" end
