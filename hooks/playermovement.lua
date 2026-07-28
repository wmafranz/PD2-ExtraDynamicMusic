-- hooks/playermovement.lua: Local-player stealth signals.
--
-- PlayerMovement:on_suspicion fires whenever an observer's detection meter
-- over THIS player changes: status is false (calm), a 0..1 number (filling),
-- or true (spotted). clbk_enemy_weapons_hot is the alarm bell.

if not _G.ExtraDynamicMusic then
	dofile(ModPath .. "lua/core.lua")
end
local XDM = _G.ExtraDynamicMusic

Hooks:PostHook(PlayerMovement, "on_suspicion", "XDM_OnSuspicion", function(self, observer_unit, status)
	pcall(function()
		XDM:Signal("suspicion", observer_unit, status)
	end)
end)

Hooks:PostHook(PlayerMovement, "clbk_enemy_weapons_hot", "XDM_WeaponsHot", function(self)
	pcall(function()
		XDM:Signal("weapons_hot")
	end)
end)
