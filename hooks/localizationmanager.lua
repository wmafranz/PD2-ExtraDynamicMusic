-- hooks/localizationmanager.lua: Menu strings. This must be its own hook
-- (not part of menumanager's) because the game loads localization and fires
-- the initial PostChangeTexts BEFORE the menu manager exists; a listener
-- registered from menumanager.lua misses that first event and every string
-- renders as "ERROR: <id>" until the user switches language.

if not _G.ExtraDynamicMusic then
	dofile(ModPath .. "lua/core.lua")
end
local XDM = _G.ExtraDynamicMusic

Hooks:Add("LocalizationManagerPostChangeTexts", "XDM_Loc", function(loc)
	loc:load_localization_file(XDM.ModPath .. "loc/english.txt")
end)

-- Belt and suspenders: if the initial load already happened, feed the file
-- in directly right now.
if managers and managers.localization then
	pcall(function()
		managers.localization:load_localization_file(XDM.ModPath .. "loc/english.txt")
	end)
end
