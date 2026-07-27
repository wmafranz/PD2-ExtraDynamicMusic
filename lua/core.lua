-- core.lua: Extra Dynamic Music (XDM)
-- Central singleton: settings, module loading, music-state tracking,
-- the condition registry and the per-frame update pump.
--
-- Everything player-facing is wrapped in pcall so a surprise engine change can
-- never take the game down with it; failures are logged and skipped.

if _G.ExtraDynamicMusic then
	return
end

local XDM = {
	_VERSION = "0.1.0",

	ModPath = ModPath,
	SavePath = SavePath and (SavePath .. "xdm_settings.txt") or "mods/saves/xdm_settings.txt",
	-- Central packs live in the shared saves folder (not inside the mod), so
	-- they survive mod reinstalls/updates and match where other mods keep
	-- user data. Note: inside this constructor, SavePath is still the BLT
	-- global ("mods/saves/"), not the settings-file field above.
	PacksPath = (SavePath or "mods/saves/") .. "xdm_packs/",

	settings = {
		enabled = true,
		overlay_volume = 1.0,   -- master multiplier for every XDM layer
		effects_enabled = true, -- stock effects (needs extended DLL)
		use_upgrades = true,    -- repacks with "replaces" take over their
		                        -- vanilla tracks (single jukebox entry)
		debug = false,
		conditions = {          -- per-condition master switches
			disoriented = true,
			ponr = true,
			drama = true,
			boss = true,
			spotted = true,
			endless = true,
		},
	},

	-- Live music state, maintained by hooks/musicmanager.lua
	music = {
		track_id = nil,      -- current song id (BeardLib id or vanilla track name)
		phase = nil,         -- "setup" | "control" | "anticipation" | "assault"
		main_is_custom = false, -- BeardLib is playing the main track
		main_is_xaudio = false, -- ...specifically through XAudio
		main_playing = false,
		intro_active = false,   -- a start_* intro segment is playing; layers hold
		ended = false,          -- heist reached its end screens; stay silent
	},

	_conditions = {},        -- id -> condition object
	_condition_order = {},   -- stable iteration order
	_loaded = false,
}
_G.ExtraDynamicMusic = XDM

------------------------------------------------------------------- logging --

function XDM:Log(msg)
	log("[XDM] " .. tostring(msg))
end

function XDM:Dbg(msg)
	if self.settings.debug then
		log("[XDM:dbg] " .. tostring(msg))
	end
end

------------------------------------------------------------------ settings --

function XDM:SaveSettings()
	local ok, err = pcall(function()
		local f = io.open(self.SavePath, "w")
		if f then
			f:write(json.encode(self.settings))
			f:close()
		end
	end)
	if not ok then
		self:Log("SaveSettings failed: " .. tostring(err))
	end
end

function XDM:LoadSettings()
	local ok, err = pcall(function()
		local f = io.open(self.SavePath, "r")
		if not f then
			return
		end
		local data = json.decode(f:read("*all"))
		f:close()
		if type(data) ~= "table" then
			return
		end
		for k, v in pairs(data) do
			if k == "conditions" and type(v) == "table" then
				for ck, cv in pairs(v) do
					if self.settings.conditions[ck] ~= nil then
						self.settings.conditions[ck] = cv and true or false
					end
				end
			elseif self.settings[k] ~= nil and type(self.settings[k]) ~= "table" then
				self.settings[k] = v
			end
		end
	end)
	if not ok then
		self:Log("LoadSettings failed: " .. tostring(err))
	end
end

------------------------------------------------------- condition registry --

-- A condition object supplies:
--   id                (string)
--   default_priority  (number)
--   default_follow    (bool)  should layers follow intensity by default
--   poll(self, t, dt) called every frame in-game; must set self.active
--                     (bool) and self.intensity (0..1)
--   on_signal(self, name, ...) optional; async events pushed from hooks
-- XDM adds: active, intensity, params (per-layer tables read them directly).

function XDM:RegisterCondition(cond)
	if not cond or not cond.id or self._conditions[cond.id] then
		return
	end
	cond.active = false
	cond.intensity = 0
	cond.default_priority = cond.default_priority or 50
	self._conditions[cond.id] = cond
	table.insert(self._condition_order, cond.id)
	self:Dbg("registered condition '" .. cond.id .. "'")
end

function XDM:GetCondition(id)
	return self._conditions[id]
end

-- Hooks push async game events here; they are fanned out to conditions.
function XDM:Signal(name, ...)
	for _, id in ipairs(self._condition_order) do
		local c = self._conditions[id]
		if c.on_signal then
			local ok, err = pcall(c.on_signal, c, name, ...)
			if not ok then
				self:Dbg("signal '" .. tostring(name) .. "' failed in '" .. id .. "': " .. tostring(err))
			end
		end
	end
end

-- Every condition returns to stock tuning between songs (and between the
-- rebuilds BeardLib triggers on phase switches- configure() immediately
-- re-applies the current song's params after this, so within one song the
-- values are stable). Prevents one song's 'params' leaking into the next.
function XDM:ResetConditionTuning()
	for _, id in ipairs(self._condition_order) do
		local c = self._conditions[id]
		if c.reset then
			pcall(c.reset, c)
		end
	end
end

-------------------------------------------------------- music state hooks --

local PHASE_SUFFIXES = {
	setup = "setup",
	control = "control",
	anticipation = "anticipation",
	assault = "assault",
}

-- Called on every MusicManager:post_event with the raw Wwise/BeardLib event
-- name (e.g. "music_heist_assault"). The phase is the last _token.
function XDM:OnMusicEvent(event)
	if type(event) ~= "string" then
		return
	end
	local last = event:match("([^_]+)$")
	local phase = last and PHASE_SUFFIXES[last]
	if phase and phase ~= self.music.phase then
		local old = self.music.phase
		self.music.phase = phase
		self:Dbg("phase: " .. tostring(old) .. " -> " .. phase)
		if self.Layers then
			self.Layers:OnPhaseChanged(phase, old)
		end
	end
end

-- Called (via posthook) after BeardLib's MusicManager:play spins up the main
-- custom source, and also synthesized for vanilla tracks. This is the moment
-- 'layer'-synced sources must start so they stay sample-locked.
function XDM:OnMainPlay(is_custom, is_xaudio, intro_active)
	local track = Global.music_manager and Global.music_manager.current_track

	-- Vanilla path only: a re-synthesized "play" for the same track is not
	-- a new clock (there IS no clock), rebuilding would just restart every
	-- layer mid-phase. BeardLib plays are real source restarts and must
	-- always rebuild so 'layer' sources start with the new source.
	if not is_custom and not self.music.main_is_custom
		and self.music.main_playing and self.music.track_id == track
		and self.Layers and #self.Layers._instances > 0 then
		self:Dbg("main play (vanilla, same track): keeping existing layers")
		return
	end

	self.music.main_is_custom = is_custom and true or false
	self.music.main_is_xaudio = is_xaudio and true or false
	self.music.main_playing = true
	self.music.intro_active = intro_active and true or false
	self.music.track_id = track
	self:Dbg("main play; track=" .. tostring(track) .. " xaudio=" .. tostring(is_xaudio)
		.. (self.music.intro_active and " (intro segment: layers holding)" or ""))
	if self.Definitions then
		self.Definitions:EnsureLoadedFor(track)
	end
	if self.Layers then
		self.Layers:OnMainPlay(track)
	end
end

function XDM:OnMainStop()
	self.music.main_playing = false
	if self.Layers then
		self.Layers:OnMainStop()
	end
end

-- Terminal stop: the heist is over. Beyond stopping, this latches
-- music.ended so the vanilla-path synthesizer in hooks/musicmanager.lua
-- does not resurrect layers when the results screens post music events.
-- A fresh heist runs in a fresh Lua state, which clears the latch.
function XDM:OnHeistEnded(why)
	if not self.music.ended then
		self:Dbg("heist ended (" .. tostring(why) .. "): layers down for good")
	end
	self.music.ended = true
	self:OnMainStop()
end

--------------------------------------------------------------- frame pump --

local END_STATES = {
	victoryscreen = true,
	gameoverscreen = true,
	server_left = true,
	kicked = true,
}

function XDM:Update(t, dt)
	if not self.settings.enabled then
		if self.Layers then
			self.Layers:PanicSilence(dt)
		end
		if self.Effects then
			self.Effects:PanicClear()
		end
		return
	end
	if not (managers and managers.music) then
		return
	end

	-- Backstop for the vanilla path: when the heist reaches an end screen,
	-- drop everything even if no stop event ever arrives. Checked at 1 Hz.
	if self.music.main_playing and t > (self._next_state_check or 0) then
		self._next_state_check = t + 1
		local fine, state_name = pcall(function()
			return game_state_machine and game_state_machine:current_state_name()
		end)
		if fine and state_name and END_STATES[state_name] then
			self:OnHeistEnded(state_name)
		end
	end

	-- Poll every enabled condition.
	for _, id in ipairs(self._condition_order) do
		local c = self._conditions[id]
		local was_active = c.active
		if self.settings.conditions[id] == false then
			c.active = false
			c.intensity = 0
		else
			local ok, err = pcall(c.poll, c, t, dt)
			if not ok then
				c.active = false
				c.intensity = 0
				self:Dbg("poll failed in '" .. id .. "': " .. tostring(err))
			end
		end
		-- Transition log: with debug on, every condition edge is visible,
		-- which turns "I didn't hear it" into an answerable question.
		if c.active ~= was_active then
			self:Dbg("condition '" .. id .. "' -> "
				.. (c.active and ("ACTIVE (intensity " .. string.format("%.2f", c.intensity or 0) .. ")") or "inactive"))
		end
	end

	if self.Layers then
		self.Layers:Update(t, dt)
	end
	if self.Effects then
		self.Effects:Update(t, dt)
	end
end

----------------------------------------------------------- module loading --

function XDM:LoadModules()
	if self._loaded then
		return
	end
	self._loaded = true

	if not _G.XAudio then
		self:Log("SuperBLT XAudio not found, Extra Dynamic Music is disabled.")
		self.settings.enabled = false
		return
	end

	local base = self.ModPath .. "lua/"
	local files = {
		"definitions.lua",
		"layers.lua",
		"effects.lua",
		"conditions/disoriented.lua",
		"conditions/ponr.lua",
		"conditions/drama.lua",
		"conditions/boss.lua",
		"conditions/spotted.lua",
		"conditions/endless.lua",
	}
	for _, f in ipairs(files) do
		local ok, err = pcall(dofile, base .. f)
		if not ok then
			self:Log("failed to load " .. f .. ": " .. tostring(err))
		end
	end

	self:LoadSettings()
	if self.Definitions then
		self.Definitions:ScanPacks()
	end
	self:Log("v" .. self._VERSION .. " loaded (" .. tostring(#self._condition_order) .. " conditions)")
end

XDM:LoadModules()

-- The in-heist frame pump. GameSetupUpdate only runs during gameplay, which
-- is exactly when we want to be alive; the menu needs none of this.
Hooks:Add("GameSetupUpdate", "XDM_Update", function(t, dt)
	local ok, err = pcall(XDM.Update, XDM, t, dt)
	if not ok then
		XDM:Dbg("update failed: " .. tostring(err))
	end
end)

-- Keep fading correctly through pause menus (sources auto-pause themselves;
-- we only avoid advancing fade math while paused).
Hooks:Add("GameSetupPausedUpdate", "XDM_PausedUpdate", function(t, dt)
	if XDM.Layers then
		pcall(XDM.Layers.OnPausedTick, XDM.Layers)
	end
end)
