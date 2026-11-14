-- Profession cooldowns: recipes on a timer or with charges, recorded per character whenever the
-- profession window is open (Professions.lua reads them in its recipe walk), so the briefing can
-- say what's ready across the warband.
local _, CH = ...

local C = {}
CH.Cooldowns = C

--- Every cooldown across the warband: { char, name, ready (bool), readyAt, charges, max }, ready first.
function C.All(now)
	now = now or time()
	local out = {}
	for _, ch in pairs(CH.db.characters) do
		for _, p in pairs(ch.professions or {}) do
			for _, c in pairs(p.cooldowns or {}) do
				local ready = (c.max and c.max > 0 and (c.charges or 0) > 0) or now >= (c.readyAt or 0)
				table.insert(out, { char = ch.name, class = ch.class, name = c.name, ready = ready, readyAt = c.readyAt, charges = c.charges, max = c.max })
			end
		end
	end
	table.sort(out, function(a, b)
		if a.ready ~= b.ready then return a.ready end
		return (a.readyAt or 0) < (b.readyAt or 0)
	end)
	return out
end
