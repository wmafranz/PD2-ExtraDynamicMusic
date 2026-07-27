-- hooks/musicmanager.lua: ties XDM into the game's music flow.
--
-- Three jobs:
--  1. Track the current phase from every post_event (works for vanilla AND
--     BeardLib songs: BeardLib routes phase changes through post_event too).
--  2. Notice when BeardLib (re)starts its main custom source, so 'layer'
--     sources can start at the exact same moment.
--  3. Notice when custom music stops, and when a vanilla (Wwise) track is
--     carrying the music instead, so XDM knows which ducking path to use.
--
-- This file loads with priority below BeardLib's own musicmanager hook, so
-- BeardLib's replacement functions are already in place when wrapped.

if not _G.ExtraDynamicMusic then
	dofile(ModPath .. "lua/core.lua")
end
local XDM = _G.ExtraDynamicMusic

-- (1) Phase tracking: Every music event passes through post_event.
Hooks:PostHook(MusicManager, "post_event", "XDM_PostEvent", function(self, name)
	local ok, err = pcall(function()
		-- music_uno_fade_reset is a routine music RESET the game posts at
		-- heist start (and elsewhere): BeardLib ignores it and so must we.
		-- It is emphatically NOT an end-of-heist signal: treating it as one
		-- latched the mod silent for whole heists. End-of-heist detection
		-- lives solely in core.lua's state-machine backstop (victoryscreen/
		-- gameoverscreen), which is unambiguous.
		if name == "music_uno_fade_reset" then
			return
		end

		XDM:OnMusicEvent(name)

		-- (3b) Vanilla path detection: BeardLib's attempt_play leaves
		-- _current_custom_track nil when the song is a stock one; if music
		-- events flow while no custom track is set, Wwise is the player.
		-- Once the heist has ended, stay down — results screens post music
		-- events too, and those must not resurrect the layers.
		--
		-- CRITICAL guard: while a BeardLib song is playing, some events pass
		-- through with _current_custom_track momentarily unset. Firing here
		-- then rebuilds (= restarts) every sample-locked layer mid-song,
		-- re-labels the main track vanilla (wrong trim), and steamrolls the
		-- intro-hold. So: only synthesize when nothing is playing, or the
		-- selected track genuinely changed.
		if not XDM.music.ended
			and not self._current_custom_track and Global.music_manager and Global.music_manager.current_track then
			if not XDM.music.main_playing
				or XDM.music.track_id ~= Global.music_manager.current_track then
				XDM:Dbg("vanilla-path synthesizer fired (event '" .. tostring(name) .. "')")
				XDM:OnMainPlay(false, false)
			end
		end
	end)
	if not ok then
		XDM:Dbg("post_event hook: " .. tostring(err))
	end
end)

-- (2) BeardLib main-source start. MusicManager:play only exists once
-- BeardLib's music hook has defined it; guard for BeardLib-less installs.
if MusicManager.play then
	Hooks:PostHook(MusicManager, "play", "XDM_MainPlay", function(self, src, use_xaudio, custom_volume)
		local ok, err = pcall(function()
			-- Is this play a start_* intro segment? BeardLib's pick_track
			-- leaves event.keep_index truthy exactly while a start_source
			-- is the playing segment; when the real loop takes over, play
			-- fires again with it cleared. Layers hold while it's set.
			local sw = self._switch_at_end
			local intro = sw and sw.event and sw.event.keep_index and true or false
			XDM:OnMainPlay(true, use_xaudio and _G.XAudio ~= nil, intro)
		end)
		if not ok then
			XDM:Dbg("play hook: " .. tostring(err))
		end
	end)
end

-- (3) Custom music stopped (heist end, track change, listen-stop...).
if MusicManager.stop_custom then
	Hooks:PostHook(MusicManager, "stop_custom", "XDM_MainStop", function(self)
		pcall(function()
			XDM:OnMainStop()
		end)
	end)
end

-- (4) Upgraded-vanilla takeover ("replaces" in a repack's definition).
-- check_music_switch is where the game commits to a track for the heist;
-- our posthook runs after BeardLib's (lower mod priority), swaps the vanilla
-- id for its repack, and starts it through BeardLib's own machinery. The
-- first phase event arrives later, so the swap is seamless and Wwise never
-- begins playing the vanilla version.
Hooks:PostHook(MusicManager, "check_music_switch", "XDM_ShadowSwitch", function(self)
	pcall(function()
		if XDM.settings.use_upgrades then
			local cur = Global.music_manager and Global.music_manager.current_track
			local shadow = cur and XDM.Definitions and XDM.Definitions:GetShadow(cur)
			if shadow and shadow ~= cur
				and _G.BeardLib and BeardLib.MusicMods and BeardLib.MusicMods[shadow]
				and self.attempt_play then
				Global.music_manager.current_track = shadow
				XDM:Dbg("upgraded vanilla '" .. cur .. "' -> '" .. shadow .. "'")
				if self:attempt_play(shadow) then
					-- May legitimately not exist yet at loadout time.
					local src = Global.music_manager.source
					if src and src.stop then
						src:stop()
					end
				end
			end
		end
	end)

	-- Preload in its OWN pcall: a hiccup in the takeover above must never
	-- cost the decode staging this hook exists to provide. The track for
	-- this heist is now decided and music is still seconds away — decode
	-- this song's layer buffers here, during the loadout, instead of
	-- stalling the game when the music starts.
	pcall(function()
		if XDM.Layers then
			XDM.Layers:PreloadFor(Global.music_manager and Global.music_manager.current_track)
		end
	end)
end)

-- Hide repack entries from the jukebox lists so each song appears once,
-- under its vanilla name. Runs after BeardLib's init posthook inserted them.
Hooks:PostHook(MusicManager, "init", "XDM_HideShadowTracks", function(self)
	pcall(function()
		if not (XDM.Definitions and tweak_data and tweak_data.music) then
			return
		end
		for _, list in ipairs({ tweak_data.music.track_list or {},
			tweak_data.music.track_ghost_list or {} }) do
			for i = #list, 1, -1 do
				local id = list[i] and list[i].track
				if id and XDM.Definitions:IsShadow(id) then
					table.remove(list, i)
				end
			end
		end
	end)
end)
