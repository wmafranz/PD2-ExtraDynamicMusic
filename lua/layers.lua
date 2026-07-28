-- layers.lua: The mixer. Owns every XDM audio source, runs all fades,
-- arbitrates replace-vs-overlay and priorities/cancels, ducks the main track,
-- and keeps 'layer'-synced sources locked to the song.

local XDM = _G.ExtraDynamicMusic
if not XDM or XDM.Layers then
	return
end

local L = {
	_instances = {},      -- normalized layer def -> live instance table
	_track_id = nil,
	_phase_index = 0,
	_duck = { cur = 1, target = 1, rate = 0 },
	_beardlib_duck_sent = nil,
}
XDM.Layers = L

local PHASE_INDEX = { setup = 1, control = 2, anticipation = 3, assault = 4 }

local math_clamp = math.clamp
local math_min = math.min

-- Ease intensity so a half-full detection meter is quieter than half volume;
-- feels much more musical than a straight line.
local function smoothstep(x)
	x = math_clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

--------------------------------------------------------- instance helpers --

local function close_instance(inst)
	if inst.src then
		pcall(function()
			if not inst.src:is_closed() then
				inst.src:close()
			end
		end)
		if XDM.Effects then
			XDM.Effects:ForgetSource(inst.src)
		end
		inst.src = nil
	end
	inst.started = false
	inst.cur = 0
end

-- Decoded-buffer cache, filled ahead of time by PreloadFor (below) during
-- the loadout screen so no decoding ever happens at the moment music starts.
local _precache = {}

local function load_buffer(inst)
	-- Separated from source creation so all decoding happens BEFORE any
	-- source starts, otherwise the first-ever play of a pack staggers its
	-- layers by their decode times. XAudio caches buffers process-wide, so
	-- the cost is paid once per game session per file.
	if inst.buffer then
		return 0
	end
	if _precache[inst.def.path] then
		inst.buffer = _precache[inst.def.path]
		return 0
	end
	local t0 = os.clock()
	local ok = pcall(function()
		inst.buffer = XAudio.Buffer:new(inst.def.path)
	end)
	local ms = (os.clock() - t0) * 1000
	if not ok then
		XDM:Log("buffer load FAILED for '" .. tostring(inst.def.path) .. "'")
	elseif ms > 15 then
		XDM:Dbg(("buffer '%s' decoded in %dms (NOT preloaded, decoded at music start)"):format(
			tostring(inst.def.path), ms))
	end
	return ms
end

-- Decode every layer buffer for a track ahead of need. Called when the game
-- commits to a heist track (check_music_switch during the loadout screen,
-- seconds before any music plays), so the decode cost lands where nobody
-- can see it. Safe to call repeatedly; already-cached files cost nothing.
function L:PreloadFor(track_id)
	local def = XDM.Definitions and XDM.Definitions:GetFor(track_id)
	if not def then
		return
	end
	local total, n = 0, 0
	for _, layer in ipairs(def.layers) do
		if layer.path and not _precache[layer.path] then
			local t0 = os.clock()
			local ok, buf = pcall(function()
				return XAudio.Buffer:new(layer.path)
			end)
			if ok and buf then
				_precache[layer.path] = buf
				total = total + (os.clock() - t0) * 1000
				n = n + 1
			end
		end
	end
	if n > 0 then
		XDM:Dbg(("preloaded %d buffer(s) for '%s' in %dms (loadout time)"):format(
			n, tostring(track_id), total))
	end
end

local function make_source(inst)
	local ok, err = pcall(function()
		if not inst.buffer then
			inst.buffer = XAudio.Buffer:new(inst.def.path)
		end
		local src = XAudio.Source:new()
		src:set_single_sound(false)
		src:set_buffer(inst.buffer)
		src:set_type(XAudio.Source.MUSIC)
		src:set_relative(true)
		src:set_looping(inst.def.loop)
		src:set_volume(0)
		src:play()
		inst.src = src
		inst.started = true
		if XDM.Effects and inst.def.self_effect ~= "none" then
			XDM.Effects:ApplySelf(src, inst.def.self_effect)
		end
	end)
	if not ok then
		XDM:Log("could not start layer '" .. tostring(inst.def.path) .. "': " .. tostring(err))
		inst.src = nil
		inst.started = false
	end
end

------------------------------------------------------------- track events --

function L:OnMainPlay(track_id)
	-- The main track (re)started: rebuild every instance so 'layer'-synced
	-- sources begin life at the same instant as the music.
	self:CloseAll()
	self._track_id = track_id

	-- Fresh slate for condition tuning; this song's params re-apply below.
	XDM:ResetConditionTuning()

	local def = XDM.Definitions and XDM.Definitions:GetFor(track_id)
	if not def then
		-- Loudest possible hint in the debug log: conditions may fire, but
		-- with no definition for this song there is nothing to play.
		XDM:Dbg("no definition targets '" .. tostring(track_id) .. "' layers idle for this song")
		return
	end

	local t0 = os.clock()

	for _, layer in ipairs(def.layers) do
		local inst = {
			def = layer,
			src = nil,
			buffer = nil,
			cur = 0,      -- current volume 0..1 (pre master multiplier)
			target = 0,   -- where the fade is heading
			started = false,
			was_active = false,
		}
		table.insert(self._instances, inst)

		-- Per-song tuning: hand this layer's params to its condition.
		if layer.trigger_kind == "condition" and next(layer.params) then
			local cond = XDM:GetCondition(layer.trigger_id)
			if cond and cond.configure then
				pcall(cond.configure, cond, layer.params)
			end
		end
	end

	-- Pass 1: decode everything first (see load_buffer).
	for _, inst in ipairs(self._instances) do
		if inst.def.path then
			load_buffer(inst)
		end
	end

	-- Pass 2: start the sample-locked sources back to back, then report the
	-- millisecond stagger between the main track's play and each layer's.
	for _, inst in ipairs(self._instances) do
		if inst.def.path and inst.def.sync == "layer" then
			make_source(inst)
			if XDM.settings.debug and inst.started then
				XDM:Dbg(("layer '%s' up %+dms after main play"):format(
					inst.def.path:match("[^/]+$") or inst.def.path,
					(os.clock() - t0) * 1000))
			end
		end
	end

	XDM:Dbg("built " .. #self._instances .. " layer instance(s) for '" .. tostring(track_id) .. "'")

	-- Sync oracle: compare every layer's loop length against the main
	-- track's current buffer. A nonzero delta predicts drift: the layer
	-- slips by that amount every repeat of its loop. "Feels early" is
	-- usually a SHORTER layer wrapping ahead of the song.
	if XDM.settings.debug then
		pcall(function()
			local main_src = managers.music and managers.music._xa_source
			local main_buf = main_src and main_src._buffer
			local main_len = main_buf and main_buf:get_length()
			if not main_len then
				return
			end
			for _, inst in ipairs(self._instances) do
				if inst.buffer then
					local len = inst.buffer:get_length()
					XDM:Dbg(("length check: main %.3fs | %s %.3fs (Δ%+dms/repeat)"):format(
						main_len, inst.def.path:match("[^/]+$") or "?", len,
						(len - main_len) * 1000))
				end
			end
		end)
	end
end

function L:OnMainStop()
	self:CloseAll()
	self:_send_duck(1, 0.5)
end

function L:OnPhaseChanged(phase, old_phase)
	self._phase_index = PHASE_INDEX[phase] or 0
end

function L:CloseAll()
	for _, inst in ipairs(self._instances) do
		close_instance(inst)
	end
	self._instances = {}
	if XDM.Effects then
		XDM.Effects:SetMainEffect(nil)
	end
end

function L:PanicSilence(dt)
	-- Mod switched off mid-heist: fade fast, then drop everything. The
	-- volume must go through the SAME multiplier chain as Update, or the
	-- first panic frames would JUMP layers up to full scale (the vanilla
	-- trim alone is 0.35x) before fading.
	local any = false
	local trim = XDM.music.main_is_custom and 1 or 0.35
	for _, inst in ipairs(self._instances) do
		if inst.src then
			inst.cur = math_clamp(inst.cur - dt * 2, 0, 1)
			pcall(inst.src.set_volume, inst.src,
				math_clamp(inst.cur * XDM.settings.overlay_volume * trim, 0, 1))
			any = any or inst.cur > 0
		end
	end
	if not any and #self._instances > 0 then
		self:CloseAll()
	end
	self:_send_duck(1, 0.5)
end

function L:OnPausedTick()
	-- XAudio auto-pauses its sources; nothing to do, kept as a hook point.
end

------------------------------------------------------------------ ducking --

-- One knob, two mechanisms: BeardLib custom music (XAudio or video player)
-- gets BeardLib's own fade-aware volume multiplier; vanilla Wwise music gets
-- MusicManager's set_volume lerped by us (restoring the player's real
-- setting afterwards).
function L:_send_duck(target, fade)
	if XDM.music.main_is_custom and managers.music and managers.music.set_volume_multiplier then
		if self._beardlib_duck_sent ~= target then
			self._beardlib_duck_sent = target
			pcall(managers.music.set_volume_multiplier, managers.music, "xdm_duck", target, fade)
		end
		return
	end
	-- Vanilla path: steer our own lerp; applied in Update.
	self._duck.target = target
	self._duck.rate = fade > 0 and (1 / fade) or 0
end

function L:_apply_vanilla_duck(dt)
	local d = self._duck
	if d.cur == d.target then
		return
	end
	if d.rate <= 0 then
		d.cur = d.target
	else
		local step = d.rate * dt
		d.cur = d.cur < d.target and math_min(d.cur + step, d.target) or math.max(d.cur - step, d.target)
	end
	local base = Global.music_manager and Global.music_manager.volume or 1
	pcall(function()
		managers.music:set_volume(base * d.cur)
	end)
end

------------------------------------------------------------------- update --

function L:Update(t, dt)
	if #self._instances == 0 then
		self:_apply_vanilla_duck(dt)
		return
	end

	local phase_idx = self._phase_index
	local phase = XDM.music.phase

	-- Pass 1: figure out which instances *want* to be audible right now.
	local active_replace = nil       -- highest-priority active replace layer
	local cancel_set = {}
	for _, inst in ipairs(self._instances) do
		local def = inst.def
		local want, intensity = false, 1

		if def.trigger_kind == "phase" then
			local trig_idx = PHASE_INDEX[def.trigger_id] or 99
			want = phase_idx == trig_idx or (def.sticky and phase_idx > trig_idx)
		else
			local cond = XDM:GetCondition(def.trigger_id)
			if cond and cond.active then
				want = true
				intensity = cond.intensity
			end
		end

		-- Optional per-layer phase restriction.
		if want and def.phases and phase and not def.phases[phase] then
			want = false
		end

		-- Hold every layer while a BeardLib start_* intro segment plays;
		-- the loop that follows re-triggers play and releases the hold, so
		-- entrances land on the loop rather than over the intro.
		if want and XDM.music.intro_active then
			want = false
		end

		inst._want = want
		inst._intensity = intensity

		if want then
			for _, victim in ipairs(def.cancels) do
				local prev = cancel_set[victim]
				if not prev or def.priority > prev then
					cancel_set[victim] = def.priority
				end
			end
			if def.mode == "replace" and def.path then
				if not active_replace or def.priority > active_replace.def.priority then
					active_replace = inst
				end
			end
		end
	end

	-- Pass 2: resolve each instance's target volume.
	local main_effect, main_effect_prio = nil, -1
	for _, inst in ipairs(self._instances) do
		local def = inst.def
		local want = inst._want

		-- A higher-priority layer may explicitly cancel this trigger.
		local cancel_prio = cancel_set[def.trigger_id]
		if want and cancel_prio and cancel_prio > def.priority then
			want = false
		end
		-- Only the winning replace layer of several may sound.
		if want and def.mode == "replace" and def.path and inst ~= active_replace then
			want = false
		end

		local target = 0
		if want and def.path then
			target = def.volume
			if def.follow_intensity then
				target = target * smoothstep(inst._intensity)
			end
		end
		inst.target = target

		-- 'start'-synced sources exist only while their trigger runs.
		if def.path and def.sync == "start" then
			if want and not inst.started then
				make_source(inst)
			elseif not want and inst.started and inst.cur <= 0.001 then
				close_instance(inst)
			end
			-- One-shots (loop=false) close themselves once finished.
			if inst.started and not def.loop and inst.src then
				local fine, state = pcall(inst.src.get_state, inst.src)
				if fine and state == XAudio.Source.STOPPED then
					close_instance(inst)
					inst.was_active = want
				end
			end
		end

		-- Advance the fade and push the volume.
		if inst.src then
			local rate
			if inst.cur < inst.target then
				rate = def.fade_in > 0 and dt / def.fade_in or 1
				inst.cur = math_min(inst.cur + rate, inst.target)
			elseif inst.cur > inst.target then
				rate = def.fade_out > 0 and dt / def.fade_out or 1
				inst.cur = math.max(inst.cur - rate, inst.target)
			end
			-- Fixed trim for layers over VANILLA (Wwise) main tracks: the
			-- engine mixes its music bed well below XAudio's full scale.
			-- BeardLib songs share our gain pipeline and need none. Not a
			-- user setting (pack authors control loudness via 'volume').
			local trim = XDM.music.main_is_custom and 1 or 0.35
			pcall(inst.src.set_volume, inst.src,
				math_clamp(inst.cur * XDM.settings.overlay_volume * trim, 0, 1))
		end

		-- Collect the strongest requested main-track effect.
		if want and def.effect ~= "none" and def.priority > main_effect_prio then
			main_effect, main_effect_prio = def.effect, def.priority
		end

		inst.was_active = want
	end

	-- Pass 3: duck (or restore) the main track for the winning replace layer.
	if active_replace and active_replace._want and active_replace.started ~= false then
		self:_send_duck(0, active_replace.def.fade_in)
	else
		self:_send_duck(1, active_replace and active_replace.def.fade_out or 1.5)
	end
	self:_apply_vanilla_duck(dt)

	-- Pass 4: stock effects on the main track.
	if XDM.Effects then
		XDM.Effects:SetMainEffect(XDM.settings.effects_enabled and main_effect or nil)
	end
end
