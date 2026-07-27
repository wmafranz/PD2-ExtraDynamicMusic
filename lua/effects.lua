-- effects.lua: "stock effects": tinny / warbly / muffled treatments that
-- need no extra audio files. They lean on two bindings that only exist in
-- the extended SuperBLT DLL (currently private/unpublished- the subsystem
-- is DORMANT in this release; see TECHNICAL_GUIDE section 9):
--
--   raw_source:setpitch(f)                       -- core OpenAL AL_PITCH
--   raw_source:setfilter(type, gain, glf, ghf)   -- EFX direct filter
--   blt.xaudio.getfxcaps()                       -- "pitch" / "pitch filter"
--
-- On a stock DLL every public function here degrades to a silent no-op, so
-- definitions using effects are always safe to install.
--
-- Effects can only touch XAudio audio. The vanilla (Wwise) main track cannot
-- be filtered- SetMainEffect quietly does nothing when Wwise is playing.

local XDM = _G.ExtraDynamicMusic
if not XDM or XDM.Effects then
	return
end

local E = {
	_caps = nil,            -- nil = not probed yet; {pitch=bool, filter=bool}
	_main_preset = nil,     -- desired preset on the main track
	_main_handle = nil,     -- raw AL handle we last applied it to
	_self_fx = {},          -- XAudio.Source -> preset name (our own layers)
	_warble_t = 0,
}
XDM.Effects = E

-- preset -> how to realize it. filter args: type, gain, gainlf, gainhf.
local PRESETS = {
	muffle = { filter = { "lowpass", 1.0, 1.0, 0.10 } },
	tinny = { filter = { "bandpass", 0.9, 0.06, 0.65 } },
	underwater = { filter = { "lowpass", 1.0, 1.0, 0.05 }, pitch = 0.92 },
	warble = { warble = true }, -- pitch LFO, driven per-frame
}
local WARBLE_DEPTH = 0.055
local WARBLE_HZ = 5.5

--------------------------------------------------------------- capability --

function E:Caps()
	if self._caps then
		return self._caps
	end
	local caps = { pitch = false, filter = false }
	local xa = blt and blt.xaudio
	if not (xa and xa.getfxcaps) then
		-- Stock DLL: the binding cannot appear mid-session, so cache the
		-- negative: this probe never runs (or allocates) again.
		self._caps = caps
		return caps
	end
	local ok, str = pcall(xa.getfxcaps)
	if ok and type(str) == "string" then
		caps.pitch = str:find("pitch") ~= nil
		caps.filter = str:find("filter") ~= nil
		-- EFX is probed against the *current device*, and before XAudio has
		-- opened one the answer can still improve. Only latch it once it is
		-- final: the filter is present, or a device exists (issetup), making
		-- "no filter" that device's real answer. Otherwise keep re-probing.
		local final = caps.filter
		if not final then
			local fine, setup = pcall(function()
				return xa.issetup and xa.issetup() and true or false
			end)
			final = fine and setup
		end
		if final then
			self._caps = caps
			XDM:Log("stock effects available: " .. str)
		end
	end
	return caps
end

------------------------------------------------------------ raw appliers --

local function raw_handle(xa_source)
	if not xa_source then
		return nil
	end
	local fine, closed = pcall(xa_source.is_closed, xa_source)
	if not fine or closed then
		return nil
	end
	return xa_source._source
end

local function apply_static(handle, preset_name, caps)
	local p = PRESETS[preset_name]
	if not p or not handle then
		return
	end
	if p.filter and caps.filter then
		pcall(handle.setfilter, handle, unpack(p.filter))
	end
	if p.pitch and caps.pitch then
		pcall(handle.setpitch, handle, p.pitch)
	end
end

local function clear_all(handle, caps)
	if not handle then
		return
	end
	if caps.filter then
		pcall(handle.setfilter, handle, "none")
	end
	if caps.pitch then
		pcall(handle.setpitch, handle, 1.0)
	end
end

------------------------------------------------------------------ public --

-- The layer manager calls this every frame with the winning preset (or nil).
function E:SetMainEffect(preset_name)
	if preset_name and not PRESETS[preset_name] then
		preset_name = nil
	end
	self._main_preset = preset_name
end

-- Permanent effect on one of our own layer sources (from 'self_effect').
function E:ApplySelf(xa_source, preset_name)
	if PRESETS[preset_name] then
		self._self_fx[xa_source] = preset_name
		apply_static(raw_handle(xa_source), preset_name, self:Caps())
	end
end

function E:ForgetSource(xa_source)
	self._self_fx[xa_source] = nil
end

-- Mod switched off mid-heist: whatever preset sits on the main track
-- (including a warble frozen mid-sine) must not stay behind. Cheap no-op
-- after the first call, so core may invoke it every disabled frame.
function E:PanicClear()
	self._main_preset = nil
	if self._main_handle and self._applied_main then
		clear_all(self._main_handle, self:Caps())
		self._applied_main = nil
	end
end

function E:Update(t, dt)
	local caps = self:Caps()
	if not (caps.pitch or caps.filter) then
		return
	end

	self._warble_t = self._warble_t + dt

	-- Track the main BeardLib source; it is recreated on every track/phase
	-- switch, so re-apply (or clean) whenever the handle changes.
	local main = managers.music and managers.music._xa_source
	local handle = XDM.music.main_is_xaudio and raw_handle(main) or nil

	if handle ~= self._main_handle then
		-- Old handle is gone with its source; nothing to clean there.
		self._main_handle = handle
		self._applied_main = nil
	end

	if handle then
		local wanted = XDM.settings.effects_enabled and self._main_preset or nil
		if wanted ~= self._applied_main then
			-- Presets don't overwrite what they don't set, so scrub the
			-- outgoing preset's leftovers: a warble's last sine sample
			-- (detune) or a filter the new preset lacks would otherwise
			-- stick to the main track.
			local old = self._applied_main and PRESETS[self._applied_main]
			local new_p = wanted and PRESETS[wanted]
			if old then
				if caps.pitch and (old.pitch or old.warble)
					and not (new_p and (new_p.pitch or new_p.warble)) then
					pcall(handle.setpitch, handle, 1.0)
				end
				if caps.filter and old.filter and not (new_p and new_p.filter) then
					pcall(handle.setfilter, handle, "none")
				end
			end
			if wanted then
				apply_static(handle, wanted, caps)
			else
				clear_all(handle, caps)
			end
			self._applied_main = wanted
		end

		-- Warble is an LFO, it needs fresh pitch every frame.
		if self._applied_main == "warble" and caps.pitch then
			local f = 1 + WARBLE_DEPTH * math.sin(self._warble_t * WARBLE_HZ * 2 * math.pi)
			pcall(handle.setpitch, handle, f)
		end
	end

	-- Keep warbling self-effected layers too.
	for src, preset in pairs(self._self_fx) do
		if preset == "warble" and caps.pitch then
			local h = raw_handle(src)
			if h then
				local f = 1 + WARBLE_DEPTH * math.sin((self._warble_t + 0.25) * WARBLE_HZ * 2 * math.pi)
				pcall(h.setpitch, h, f)
			end
		end
	end
end
