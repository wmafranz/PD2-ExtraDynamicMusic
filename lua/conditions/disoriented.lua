-- conditions/disoriented.lua: Anything that rips control or attention away
-- from the player: being tased, cuffed, flashbanged, or set on fire.
--
-- Signals used:
--   * player movement state name  ("tased", "arrested"): polled
--   * managers.environment_controller._current_flashbang: polled (0..1, decays)
--   * "player_fire" signal from hooks/playerdamage.lua: event + linger

local XDM = _G.ExtraDynamicMusic

local STATES = { tased = true, arrested = true }
local FLASH_THRESHOLD = 0.15

XDM:RegisterCondition({
	id = "disoriented",
	default_priority = 90,

	_fire_until = 0,
	_min_duration = 1.0,   -- once triggered, stay on at least this long
	_hold_until = 0,

	-- Stock tuning between songs; must mirror the initial values above.
	-- Runtime state (timers, active) is deliberately untouched- this also
	-- runs on BeardLib phase-switch rebuilds mid-song.
	reset = function(self)
		self._min_duration = 1.0
	end,

	configure = function(self, params)
		self._min_duration = tonumber(params.min_duration) or self._min_duration
	end,

	on_signal = function(self, name, arg)
		if name == "player_fire" then
			-- Signals arrive outside our update, where we don't know the
			-- game clock; stash the duration and let poll() timestamp it.
			self._fire_pending = tonumber(arg) or 3.0
		end
	end,

	poll = function(self, t, dt)
		local on = false

		-- Convert any pending fire signal into a game-clock window. Each
		-- fire tick re-signals, so the window naturally tracks the burn.
		if self._fire_pending then
			self._fire_until = t + self._fire_pending
			self._fire_pending = nil
		end

		-- Loss-of-control player states.
		local unit = managers.player and managers.player:player_unit()
		if unit and alive(unit) then
			local fine, state = pcall(function()
				return unit:movement():current_state_name()
			end)
			if fine and STATES[state] then
				on = true
			end
		end

		-- Flashbang whiteout (field decays back to 0 on its own).
		if not on and managers.environment_controller then
			local flash = managers.environment_controller._current_flashbang
			if type(flash) == "number" and flash > FLASH_THRESHOLD then
				on = true
			end
		end

		-- Burning.
		if not on and t < self._fire_until then
			on = true
		end

		-- Enforce a minimum audible duration so one-frame blips still read.
		if on then
			self._hold_until = t + self._min_duration
		end
		self.active = on or t < self._hold_until
		self.intensity = self.active and 1 or 0
	end,
})
