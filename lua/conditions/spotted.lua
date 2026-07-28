-- conditions/spotted.lua: Stealth tension. Swells with the highest active
-- detection meter (guard, camera or civilian noticing you), lingers a few
-- seconds when meters empty without an alert, and if someone fully spots you
-- it stays on until that observer is dead, tied down or otherwise inert.
--
-- Signals arrive from hooks/playermovement.lua (local player) and
-- hooks/unitnetworkhandler.lua (client HUD sync):
--   status == false   observer calmed down / meter gone
--   status == number  meter filling, 0..1
--   status == true    fully spotted by that observer
-- "weapons_hot" clears everything (the alarm makes this condition moot).

local XDM = _G.ExtraDynamicMusic

XDM:RegisterCondition({
	id = "spotted",
	default_priority = 70,

	_observers = {},   -- unit key -> { unit=, susp=0..1, alerted=bool }
	_linger = 4.0,
	_linger_until = 0,

	-- Stock tuning between songs; observers and timers are runtime state
	-- and deliberately survive (this also runs on phase-switch rebuilds).
	reset = function(self)
		self._linger = 4.0
	end,

	configure = function(self, params)
		self._linger = tonumber(params.linger) or self._linger
	end,

	on_signal = function(self, name, observer_unit, status)
		if name == "weapons_hot" then
			self._observers = {}
			self._linger_until = 0
			return
		end
		if name ~= "suspicion" then
			return
		end
		local key
		local ok = pcall(function()
			key = observer_unit and observer_unit:key()
		end)
		if not ok or not key then
			return
		end

		XDM:Dbg("spotted signal: status=" .. tostring(status) .. " observer=" .. tostring(key))

		-- Host-side status grammar (on_criminal_suspicion_progress):
		--   false        calm: meter gone
		--   number       meter filling, 0..1
		--   "suspicious" investigating what they saw
		--   "calling"/"called"/true  alerted: spotted for real
		if status == false then
			-- Calm again; alerted observers only clear via neutralization.
			local entry = self._observers[key]
			if entry and not entry.alerted then
				self._observers[key] = nil
			end
		elseif status == true or status == "calling" or status == "called" then
			self._observers[key] = self._observers[key] or { unit = observer_unit }
			self._observers[key].unit = observer_unit
			self._observers[key].alerted = true
			self._observers[key].susp = 1
		elseif status == "suspicious" then
			local e = self._observers[key] or { unit = observer_unit }
			e.unit = observer_unit
			e.susp = math.max(e.susp or 0, 0.65)
			self._observers[key] = e
		elseif type(status) == "number" then
			self._observers[key] = self._observers[key] or { unit = observer_unit }
			self._observers[key].unit = observer_unit
			self._observers[key].susp = math.clamp(status, 0, 1)
		end
	end,

	poll = function(self, t, dt)
		local state = managers.groupai and managers.groupai:state()

		-- Loud already? Nothing to whisper about.
		local whisper = true
		if state and state.whisper_mode then
			local fine, w = pcall(state.whisper_mode, state)
			whisper = not fine or w and true or false
		end
		if not whisper then
			self._observers = {}
			self._linger_until = 0
			self.active = false
			self.intensity = 0
			return
		end

		-- Prune neutralized observers (dead, tied, converted, deleted).
		local max_susp = 0
		for key, entry in pairs(self._observers) do
			local drop = true
			local unit = entry.unit
			if unit and alive(unit) then
				local fine, inert = pcall(function()
					local dmg = unit.character_damage and unit:character_damage()
					if dmg and dmg.dead and dmg:dead() then
						return true
					end
					local brain = unit.brain and unit:brain()
					if brain then
						if brain.surrendered and brain:surrendered() then
							return true
						end
						if brain.is_tied and brain:is_tied() then
							return true
						end
						if brain.converted and brain:converted() then
							return true
						end
					end
					return false
				end)
				-- If the inert-check ERRORS (exotic unit types like cameras
				-- lack brains, some mods add odd observers), KEEP the
				-- observer rather than silently deleting it every poll,
				-- which would eat the detection meter. weapons_hot and
				-- calm-signals still clear such entries.
				drop = (fine and inert) or false
			end
			if drop then
				self._observers[key] = nil
			else
				local s = entry.alerted and 1 or entry.susp or 0
				if s > max_susp then
					max_susp = s
				end
			end
		end

		if max_susp > 0 then
			self._linger_until = t + self._linger
			self.active = true
			self.intensity = max_susp
		elseif t < self._linger_until then
			self.active = true
			self.intensity = 0.25   -- quiet tail while nerves settle
		else
			self.active = false
			self.intensity = 0
		end
	end,
})
