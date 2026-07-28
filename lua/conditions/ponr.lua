-- conditions/ponr.lua: Point of no Return. Active from the moment the
-- red escape timer starts until it is removed (escape made, or timer cancelled).
--
-- Signal: GroupAIStateBase._point_of_no_return_timer is a number while a PonR
-- countdown is live and nil otherwise, on every peer. Restoration Mod also
-- maintains _ponr_is_on; either one lights us up.

local XDM = _G.ExtraDynamicMusic

XDM:RegisterCondition({
	id = "ponr",
	default_priority = 80,

	poll = function(self, t, dt)
		local on = false
		local state = managers.groupai and managers.groupai:state()
		if state then
			if type(state._point_of_no_return_timer) == "number" then
				on = true
			elseif state._ponr_is_on then -- Restoration Mod alternate flag
				on = true
			end
		end
		self.active = on
		self.intensity = on and 1 or 0
	end,
})
