-- conditions/drama.lua: The game's hidden "drama" intensity meter.
--
-- GroupAIStateBase._drama_data.amount is a 0..1 value the drama system raises as
-- combat pressure mounts and decays in lulls. We switch on with hysteresis
-- (on above threshold_on, off only below threshold_off) so the music does not
-- flap around the threshold, and expose the raw amount as our intensity so
-- 'follow_intensity' layers can swell with the fight.

local XDM = _G.ExtraDynamicMusic

XDM:RegisterCondition({
	id = "drama",
	default_priority = 40,

	_threshold_on = 0.75,
	_threshold_off = 0.45,

	-- Stock tuning between songs; must mirror the initial values above.
	reset = function(self)
		self._threshold_on = 0.75
		self._threshold_off = 0.45
	end,

	configure = function(self, params)
		self._threshold_on = tonumber(params.threshold_on) or self._threshold_on
		self._threshold_off = tonumber(params.threshold_off) or self._threshold_off
	end,

	poll = function(self, t, dt)
		local amount = 0
		local state = managers.groupai and managers.groupai:state()
		local data = state and state._drama_data
		if data and type(data.amount) == "number" then
			amount = data.amount
		end

		if self.active then
			if amount < self._threshold_off then
				self.active = false
			end
		elseif amount >= self._threshold_on then
			self.active = true
		end

		-- Intensity ramps across the hysteresis band and rides the raw value
		-- above it, so a follow_intensity layer breathes with the fight.
		if self.active then
			local span = math.max(self._threshold_on - self._threshold_off, 0.001)
			self.intensity = math.clamp((amount - self._threshold_off) / span, 0.35, 1)
		else
			self.intensity = 0
		end
	end,
})
