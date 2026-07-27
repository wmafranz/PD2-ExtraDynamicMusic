-- hooks/groupaistatebase.lua: The suspicion artery. On the host, every
-- detection-meter change flows through
-- GroupAIStateBase:on_criminal_suspicion_progress(u_suspect, u_observer,
-- status): This is the hook the working detection HUD on this install
-- (DDSC) feeds from, and the reliable one under Restoration Mod's reworked
-- detection (PlayerMovement:on_suspicion proved dry there). We forward only
-- events about the LOCAL player to the spotted condition.
--
-- status grammar (host side): false = calm, number = meter fill,
-- "suspicious" = investigating, "calling"/"called"/true = alerted.

if not _G.ExtraDynamicMusic then
	dofile(ModPath .. "lua/core.lua")
end
local XDM = _G.ExtraDynamicMusic

if GroupAIStateBase and GroupAIStateBase.on_criminal_suspicion_progress then
	Hooks:PostHook(GroupAIStateBase, "on_criminal_suspicion_progress", "XDM_SuspicionProgress",
		function(self, u_suspect, u_observer, status)
			pcall(function()
				local plr = managers.player and managers.player:player_unit()
				if plr and u_suspect == plr then
					XDM:Signal("suspicion", u_observer, status)
				end
			end)
		end)
end

if GroupAIStateBase and GroupAIStateBase.on_enemy_weapons_hot then
	Hooks:PostHook(GroupAIStateBase, "on_enemy_weapons_hot", "XDM_WeaponsHotGAI", function(self)
		pcall(function()
			XDM:Signal("weapons_hot")
		end)
	end)
end
