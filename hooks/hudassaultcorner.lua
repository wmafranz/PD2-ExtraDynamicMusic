-- hooks/hudassaultcorner.lua: endless-assault signal for clients. The host
-- decides hunt mode; clients only hear about it through the HUD's synced
-- assault-mode changes, so we forward those to the endless condition.

if not _G.ExtraDynamicMusic then
	dofile(ModPath .. "lua/core.lua")
end
local XDM = _G.ExtraDynamicMusic

if HUDAssaultCorner and HUDAssaultCorner.sync_set_assault_mode then
	Hooks:PostHook(HUDAssaultCorner, "sync_set_assault_mode", "XDM_AssaultMode", function(self, mode)
		pcall(function()
			XDM:Signal("assault_mode", mode)
		end)
	end)
end
