-- hooks/groupaistatebesiege.lua: The endless-assault signal that actually
-- fires on this modlist. Restoration Mod's captains (Winters, Spring,
-- Summers, Autumn, the Hatman) make assaults endless by calling the vanilla
-- GroupAIStateBesiege:set_assault_endless(true/false); vanilla hunt mode is
-- a separate, rarer mechanism (polled in the condition). Posthooking the
-- setter is exact: no guessing which internal field it writes.

if not _G.ExtraDynamicMusic then
	dofile(ModPath .. "lua/core.lua")
end
local XDM = _G.ExtraDynamicMusic

if GroupAIStateBesiege and GroupAIStateBesiege.set_assault_endless then
	Hooks:PostHook(GroupAIStateBesiege, "set_assault_endless", "XDM_AssaultEndless", function(self, enabled)
		pcall(function()
			XDM:Signal("assault_endless", enabled and true or false)
		end)
	end)
end
