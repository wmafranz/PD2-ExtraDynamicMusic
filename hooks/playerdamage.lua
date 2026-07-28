-- hooks/playerdamage.lua: Fire-on-player signal for the disoriented
-- condition. damage_fire runs on every fire hit/tick against the local
-- player, so refreshing a short window here tracks the whole burn without
-- needing to know PlayerDamage's DOT internals.

if not _G.ExtraDynamicMusic then
	dofile(ModPath .. "lua/core.lua")
end
local XDM = _G.ExtraDynamicMusic

if PlayerDamage.damage_fire then
	Hooks:PostHook(PlayerDamage, "damage_fire", "XDM_PlayerFire", function(self, attack_data)
		pcall(function()
			XDM:Signal("player_fire", 3.0)
		end)
	end)
end
