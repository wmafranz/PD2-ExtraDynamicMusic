-- hooks/unitnetworkhandler.lua: Client-side stealth signals. When you are
-- not the host, suspicion updates about you arrive over the network as
-- suspicion_hud(observer_unit, status); same status grammar as on_suspicion.

if not _G.ExtraDynamicMusic then
	dofile(ModPath .. "lua/core.lua")
end
local XDM = _G.ExtraDynamicMusic

if UnitNetworkHandler.suspicion_hud then
	Hooks:PostHook(UnitNetworkHandler, "suspicion_hud", "XDM_NetSuspicion", function(self, observer_unit, status)
		pcall(function()
			XDM:Signal("suspicion", observer_unit, status)
		end)
	end)
end
