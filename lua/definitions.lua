-- definitions.lua: Finds, parses and normalizes xdm.json / xdm.xml
-- definition files from central packs and music-mod sidecars, and tells
-- the layer manager what layers any given song wants.

local XDM = _G.ExtraDynamicMusic
if not XDM or XDM.Definitions then
	return
end

local D = {
	_by_target = {},   -- track id -> { basedir=..., layers={...} }
	_shadows = {},     -- vanilla track id -> repack music id ("replaces")
	_is_shadow = {},   -- repack music id -> true (hidden from jukebox)
	_scanned = false,
}
XDM.Definitions = D

local CONDITION_IDS = {
	disoriented = true, ponr = true, drama = true,
	boss = true, spotted = true, endless = true,
}
local PHASES = { setup = true, control = true, anticipation = true, assault = true }

local DEFAULT_PRIORITY = {
	disoriented = 90, ponr = 80, spotted = 70,
	endless = 60, boss = 50, drama = 40, phase = 10,
}
local DEFAULT_FOLLOW = { spotted = true, drama = true }

local EFFECTS = { muffle = true, tinny = true, warble = true, underwater = true, none = true }

--------------------------------------------------------------- utilities --

local function file_exists(path)
	local f = io.open(path, "r")
	if f then
		f:close()
		return true
	end
	return false
end

local function read_all(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local data = f:read("*all")
	f:close()
	return data
end

-- Accepts "a b", "a,b", {"a","b"}, returns array of strings.
local function to_list(v)
	if type(v) == "table" then
		return v
	end
	if type(v) == "string" then
		local out = {}
		for tok in v:gmatch("[^%s,]+") do
			table.insert(out, tok)
		end
		return out
	end
	return {}
end

local function to_bool(v, default)
	if v == nil then
		return default
	end
	if type(v) == "boolean" then
		return v
	end
	return tostring(v) == "true"
end

local function to_num(v, default)
	local n = tonumber(v)
	return n ~= nil and n or default
end

--------------------------------------------------------- layer normalizing --

-- Turns one raw layer table (from JSON or XML attributes) into the fully
-- defaulted internal form the layer manager consumes. Returns nil + reason
-- when the entry is unusable.
local function normalize_layer(raw, basedir)
	local on = raw.on
	if type(on) ~= "string" then
		return nil, "layer missing 'on'"
	end

	local trigger_kind, trigger_id
	local phase = on:match("^phase:(%w+)$")
	if phase then
		if not PHASES[phase] then
			return nil, "unknown phase '" .. phase .. "'"
		end
		trigger_kind, trigger_id = "phase", phase
	elseif CONDITION_IDS[on] then
		trigger_kind, trigger_id = "condition", on
	else
		return nil, "unknown trigger '" .. on .. "'"
	end

	local effect = raw.effect or "none"
	local self_effect = raw.self_effect or "none"
	if not EFFECTS[effect] then effect = "none" end
	if not EFFECTS[self_effect] then self_effect = "none" end

	local path
	if raw.file and raw.file ~= "" then
		path = basedir .. raw.file
		if not file_exists(path) then
			return nil, "audio file not found: " .. path
		end
	elseif effect == "none" then
		return nil, "layer has neither 'file' nor 'effect'"
	end

	local default_prio = trigger_kind == "phase" and DEFAULT_PRIORITY.phase
		or DEFAULT_PRIORITY[trigger_id] or 50

	local phases_list = to_list(raw.phases)
	local phases_set
	if #phases_list > 0 then
		phases_set = {}
		for _, p in ipairs(phases_list) do
			if PHASES[p] then
				phases_set[p] = true
			end
		end
	end

	return {
		trigger_kind = trigger_kind,   -- "condition" | "phase"
		trigger_id = trigger_id,       -- condition id or phase name
		path = path,                   -- absolute-ish ogg path or nil (effect-only)
		mode = raw.mode == "replace" and "replace" or "overlay",
		sync = raw.sync == "start" and "start" or "layer",
		volume = math.min(math.max(to_num(raw.volume, 1.0), 0), 1),
		fade_in = to_num(raw.fade_in, 1.5),
		fade_out = to_num(raw.fade_out, 2.5),
		phases = phases_set,           -- nil = all phases
		sticky = to_bool(raw.sticky, false),
		priority = to_num(raw.priority, default_prio),
		cancels = to_list(raw.cancels),
		follow_intensity = to_bool(raw.follow_intensity,
			trigger_kind == "condition" and DEFAULT_FOLLOW[trigger_id] or false),
		loop = to_bool(raw.loop, true),
		effect = effect,
		self_effect = self_effect,
		params = type(raw.params) == "table" and raw.params or {},
	}
end

------------------------------------------------------------------ parsing --

-- BeardLib's custom_xml reader gives child nodes as array entries whose
-- _meta is the tag name and whose attributes are plain keys.
local function xml_to_raw(node)
	local def = { target = node.target, targets = node.targets, layers = {} }
	for _, child in ipairs(node) do
		if type(child) == "table" and child._meta == "layer" then
			table.insert(def.layers, child)
		end
	end
	return def
end

local function parse_definition_file(path)
	if path:match("%.json$") then
		local text = read_all(path)
		if not text then
			return nil, "unreadable"
		end
		local ok, data = pcall(json.decode, text)
		if not ok or type(data) ~= "table" then
			return nil, "invalid JSON"
		end
		return data
	end

	-- XML needs BeardLib's reader.
	if _G.FileIO and FileIO.ReadScriptData then
		local ok, data = pcall(FileIO.ReadScriptData, FileIO, path, "custom_xml")
		if ok and type(data) == "table" then
			return xml_to_raw(data)
		end
		return nil, "invalid XML"
	end
	return nil, "xdm.xml needs BeardLib installed; use xdm.json instead"
end

-- Registers one parsed definition under every target it names.
local function register_definition(raw, basedir, origin, implied_target)
	local targets = {}
	for _, t in ipairs(to_list(raw.targets)) do
		table.insert(targets, t)
	end
	if raw.target then
		table.insert(targets, raw.target)
	end
	if #targets == 0 and implied_target then
		table.insert(targets, implied_target)
	end
	if #targets == 0 then
		XDM:Log(origin .. ": no 'target' given and none could be inferred: skipped")
		return
	end

	-- "replaces": this definition's (BeardLib) target song shadows a vanilla
	-- track (plays whenever the vanilla one is selected, and its own
	-- jukebox entry is hidden so players see exactly one song).
	if raw.replaces and targets[1] then
		D._shadows[tostring(raw.replaces)] = targets[1]
		D._is_shadow[targets[1]] = true
		XDM:Dbg(origin .. ": '" .. targets[1] .. "' replaces vanilla '" .. tostring(raw.replaces) .. "'")
	end

	local layers = {}
	for i, raw_layer in ipairs(raw.layers or {}) do
		local layer, why = normalize_layer(raw_layer, basedir)
		if layer then
			table.insert(layers, layer)
		else
			XDM:Log(origin .. " layer #" .. i .. ": " .. why)
		end
	end
	if #layers == 0 then
		return
	end

	for _, target in ipairs(targets) do
		local slot = D._by_target[target]
		if not slot then
			slot = { layers = {} }
			D._by_target[target] = slot
		end
		local added = 0
		for _, l in ipairs(layers) do
			-- Definitions for one song stack on purpose (a central pack can
			-- add layers to a song whose own mod ships some) but the SAME
			-- audio file twice is almost certainly one definition installed
			-- in two places, and would double its volume. Skip those.
			local dup = false
			if l.path then
				for _, existing in ipairs(slot.layers) do
					if existing.path == l.path then
						dup = true
						break
					end
				end
			end
			if dup then
				XDM:Log(origin .. ": duplicate layer for '" .. target .. "' skipped ("
					.. l.path .. " already registered: same definition in two places?)")
			else
				table.insert(slot.layers, l)
				added = added + 1
			end
		end
		XDM:Dbg(origin .. ": +" .. added .. " layers for '" .. target .. "'")
	end
end

-- Tries to pull a MusicModule id out of a BeardLib music mod's main.xml so
-- sidecars may omit 'target'. Best-effort; returns nil quietly.
local function infer_music_id(mod_dir)
	if not (_G.FileIO and FileIO.ReadScriptData) then
		return nil
	end
	for _, name in ipairs({ "main.xml", "mod_config.xml" }) do
		local p = mod_dir .. name
		if file_exists(p) then
			local ok, data = pcall(FileIO.ReadScriptData, FileIO, p, "custom_xml")
			if ok and type(data) == "table" then
				for _, child in ipairs(data) do
					if type(child) == "table" and child._meta
						and tostring(child._meta):lower():match("musicmodule")
						and child.id then
						return child.id
					end
				end
			end
		end
	end
	return nil
end

----------------------------------------------------------------- scanning --

local function scan_dir_for_sidecar(dir)
	for _, fname in ipairs({ "xdm.json", "xdm.xml" }) do
		local p = dir .. fname
		if file_exists(p) then
			local raw, why = parse_definition_file(p)
			if raw then
				register_definition(raw, dir, p, infer_music_id(dir))
			else
				XDM:Log(p .. ": " .. tostring(why))
			end
			return
		end
	end
end

function D:ScanPacks()
	if self._scanned then
		return
	end
	self._scanned = true

	local ok, err = pcall(function()
		-- 1. Central packs in mods/saves/xdm_packs/: user data is located with
		--    the other mods' configs and survives XDM updates. (The packs/
		--    folder inside the mod itself is inert sample content.)
		local packs_root = XDM.PacksPath
		if file and file.GetDirectories then
			for _, d in ipairs(file.GetDirectories(packs_root) or {}) do
				scan_dir_for_sidecar(packs_root .. d .. "/")
			end
			-- 2. Sidecars inside other mods (BeardLib music mods live in
			--    mods/ and, as add-on modules, sometimes under Maps/).
			for _, root in ipairs({ "mods/", "Maps/" }) do
				for _, d in ipairs(file.GetDirectories(root) or {}) do
					if root .. d .. "/" ~= XDM.ModPath then
						scan_dir_for_sidecar(root .. d .. "/")
					end
				end
			end
		else
			XDM:Log("SuperBLT file API missing; definition scan skipped")
		end
	end)
	if not ok then
		XDM:Log("ScanPacks failed: " .. tostring(err))
	end

	local n = 0
	for _ in pairs(self._by_target) do
		n = n + 1
	end
	XDM:Log("definitions loaded for " .. n .. " song(s)")
end

function D:EnsureLoadedFor(track_id)
	-- Scanning is exhaustive at boot; nothing lazy needed yet. Kept as the
	-- extension point for hot-reloading definitions in a dev build.
	self:ScanPacks()
end

function D:GetFor(track_id)
	return track_id and self._by_target[track_id] or nil
end

function D:GetShadow(vanilla_id)
	return vanilla_id and self._shadows[vanilla_id] or nil
end

function D:IsShadow(music_id)
	return music_id and self._is_shadow[music_id] or false
end
