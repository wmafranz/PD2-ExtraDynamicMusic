-- hooks/menumanager.lua: Boot + options menu. menumanager is the classic
-- BLT entry point: it runs early, in menus and in-game alike, so core loads
-- here exactly once.

if not _G.ExtraDynamicMusic then
	dofile(ModPath .. "lua/core.lua")
end
local XDM = _G.ExtraDynamicMusic

-- Localization arrives through two doors, most-native first: the classic
-- PostChangeTexts listener in hooks/localizationmanager.lua. And in case
-- that ever fails on some BLT flavor- this direct feed into the vanilla
-- localization manager right before our menu is built.
local function xdm_ensure_strings()
	if XDM._loc_loaded then
		return
	end
	local ok, err = pcall(function()
		local f = io.open(XDM.ModPath .. "loc/english.txt", "r")
		if not f then
			error("loc/english.txt missing")
		end
		local data = json.decode(f:read("*all"))
		f:close()
		if type(data) == "table" and managers and managers.localization then
			managers.localization:add_localized_strings(data)
			XDM._loc_loaded = true
		end
	end)
	if not ok then
		XDM:Log("loc fallback failed: " .. tostring(err))
	end
end

Hooks:Add("MenuManagerSetupCustomMenus", "XDM_SetupMenu", function(menu_manager, nodes)
	xdm_ensure_strings()
	MenuHelper:NewMenu("xdm_options")
end)

Hooks:Add("MenuManagerPopulateCustomMenus", "XDM_PopulateMenu", function(menu_manager, nodes)
	xdm_ensure_strings()
	local S = XDM.settings

	MenuCallbackHandler.xdm_toggle_enabled = function(_, item)
		S.enabled = item:value() == "on"
		XDM:SaveSettings()
	end
	MenuCallbackHandler.xdm_toggle_debug = function(_, item)
		S.debug = item:value() == "on"
		XDM:SaveSettings()
	end
	-- Volume arrives as 0..100 (the slider lives among the game's own
	-- percentage sliders in the sound settings).
	MenuCallbackHandler.xdm_set_overlay_volume = function(_, item)
		S.overlay_volume = math.clamp((tonumber(item:value()) or 100) / 100, 0, 1)
		XDM:SaveSettings()
	end

	MenuHelper:AddToggle({
		id = "xdm_enabled", title = "xdm_opt_enabled", desc = "xdm_opt_enabled_desc",
		callback = "xdm_toggle_enabled", value = S.enabled,
		menu_id = "xdm_options", priority = 100,
	})
	-- (The layer-volume slider lives in the game's own sound settings
	-- injected in the build hook below, with this menu as fallback.)
	MenuCallbackHandler.xdm_toggle_upgrades = function(_, item)
		S.use_upgrades = item:value() == "on"
		XDM:SaveSettings()
	end
	MenuHelper:AddToggle({
		id = "xdm_upgrades", title = "xdm_opt_upgrades", desc = "xdm_opt_upgrades_desc",
		callback = "xdm_toggle_upgrades", value = S.use_upgrades,
		menu_id = "xdm_options", priority = 78,
	})

	-- One toggle per condition.
	local prio = 70
	for _, cid in ipairs({ "disoriented", "ponr", "drama", "boss", "spotted", "endless" }) do
		local cb = "xdm_toggle_cond_" .. cid
		MenuCallbackHandler[cb] = function(_, item)
			S.conditions[cid] = item:value() == "on"
			XDM:SaveSettings()
		end
		MenuHelper:AddToggle({
			id = "xdm_cond_" .. cid,
			title = "xdm_opt_cond_" .. cid,
			desc = "xdm_opt_cond_" .. cid .. "_desc",
			callback = cb, value = S.conditions[cid],
			menu_id = "xdm_options", priority = prio,
		})
		prio = prio - 1
	end

	MenuHelper:AddToggle({
		id = "xdm_debug", title = "xdm_opt_debug", desc = "xdm_opt_debug_desc",
		callback = "xdm_toggle_debug", value = S.debug,
		menu_id = "xdm_options", priority = 10,
	})
end)

-- Builds one percentage slider item the way MenuHelper does internally,
-- so it looks native anywhere we put it.
local function xdm_make_volume_item(node)
	local data = {
		type = "CoreMenuItemSlider.ItemSlider",
		min = 0, max = 100, step = 5,
		show_value = true,
		is_percentage = true,
		decimal_count = 0,
		show_scale = 1,
	}
	local params = {
		name = "xdm_overlay_volume",
		text_id = "xdm_opt_volume",
		help_id = "xdm_opt_volume_desc",
		callback = "xdm_set_overlay_volume",
		localize = true,
		localize_help = true,
	}
	local item = node:create_item(data, params)
	item:set_value(math.clamp((XDM.settings.overlay_volume or 1) * 100, 0, 100))
	return item
end

-- Find the game's own sound-settings node: rather than guessing its name,
-- look for the node that carries the vanilla "music_volume" slider, and
-- slot ours in directly beneath it.
local function xdm_inject_volume_slider(nodes)
	for _, node in pairs(nodes) do
		local fine, has = pcall(function()
			return node.item and node:item("music_volume") ~= nil
		end)
		if fine and has then
			local item = xdm_make_volume_item(node)
			local pos
			for i, it in ipairs(node:items()) do
				if it:name() == "music_volume" then
					pos = i + 1
					break
				end
			end
			if pos and node.insert_item then
				node:insert_item(item, pos)
			else
				node:add_item(item)
			end
			return true
		end
	end
	return false
end

Hooks:Add("MenuManagerBuildCustomMenus", "XDM_BuildMenu", function(menu_manager, nodes)
	nodes.xdm_options = MenuHelper:BuildMenu("xdm_options", { back_callback = function()
		XDM:SaveSettings()
	end })
	MenuHelper:AddMenuItem(nodes["blt_options"], "xdm_options", "xdm_menu_title", "xdm_menu_desc")

	-- Layer volume belongs with the game's other volume sliders. If the
	-- sound node isn't found in this menu (layout mods etc.), fall back to
	-- our own options page so the control always exists somewhere.
	local ok, injected = pcall(xdm_inject_volume_slider, nodes)
	if not (ok and injected) then
		pcall(function()
			nodes.xdm_options:add_item(xdm_make_volume_item(nodes.xdm_options))
		end)
		XDM:Dbg("sound node not found; volume slider fell back to XDM menu")
	end
end)
