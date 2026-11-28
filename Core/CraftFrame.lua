-- Which window the open profession is showing in, for anything that docks beside it.
--
-- TradeSkillMaster replaces the game's profession window with its own crafting window when its UI
-- is on: it moves the game's window off screen (where it stays shown) and opens its own. Docking to
-- the game's window then puts AuctionIQ off screen too, or beside a window nobody sees. TSM tells
-- other addons when its crafting window shows and hides (TSM_API.RegisterUICallback "CRAFTING"),
-- so this keeps that window and hands it out first. Same on Forever and retail.
local _, AuctionIQ = ...

local CF = {}
AuctionIQ.CraftFrame = CF

local GAME_FRAMES = { "ProfessionsFrame", "TradeSkillFrame" }
local tsmFrame -- TSM's crafting window while it's up
local listeners = {}
local hooked = false

local function shown(f) return f ~= nil and f.IsShown ~= nil and f:IsShown() and true or false end

--- TSM's crafting window while it's showing, else nil.
function CF.TSM()
	if shown(tsmFrame) then return tsmFrame end
end

--- The game's own profession window while it's showing (off screen under TSM counts), else nil.
function CF.Game()
	for _, name in ipairs(GAME_FRAMES) do
		local f = _G[name]
		if shown(f) then return f end
	end
end

--- The window to dock beside: TSM's crafting window when it's up, else the game's.
function CF.Anchor() return CF.TSM() or CF.Game() end

--- Calls fn() after TSM's crafting window shows or hides (on the next frame, once it's placed),
--- so a docked window can move to whichever window is on screen now.
function CF.OnChange(fn) listeners[#listeners + 1] = fn end

local function notify()
	for _, fn in ipairs(listeners) do
		local ok, err = pcall(fn)
		if not ok and geterrorhandler then geterrorhandler()(err) end
	end
end

--- TSM's callback: (true, frame) when its crafting window shows, (false) when it goes.
function CF.Changed(isShown, frame)
	tsmFrame = isShown and frame or nil
	if C_Timer and C_Timer.After then C_Timer.After(0, notify) else notify() end
end

--- Ask TSM to report its crafting window. Safe to call again; nothing without TSM.
function CF.Hook()
	if hooked then return true end
	if type(TSM_API) ~= "table" or type(TSM_API.RegisterUICallback) ~= "function" then return false end
	hooked = pcall(TSM_API.RegisterUICallback, "CRAFTING", "AuctionIQ:Dock", CF.Changed) and true or false
	return hooked
end

-- TSM loads first (an optional dependency), so this usually takes now; login is the fallback.
CF.Hook()
AuctionIQ.On("PLAYER_LOGIN", function() CF.Hook() end)
