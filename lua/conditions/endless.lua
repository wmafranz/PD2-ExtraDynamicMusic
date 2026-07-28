-- conditions/endless.lua: Endless police assault, from any of its three
-- real-world sources:
--
--  1. Captain-driven endless (Restoration Mod: Winters/Spring/Summers/
--     Autumn/HHTDFH alive): vanilla GroupAIStateBesiege:set_assault_endless
--     is posthooked in hooks/groupaistatebesiege.lua and arrives here as the
--     "assault_endless" signal. This is the common case on this modlist.
--  2. Vanilla hunt mode (mission scripts that never end the assault):
--     polled from the group-AI state, both the _hunt_mode field and the
--     get_hunt_mode accessor (whichever this install offers).
--  3. Client sync: the HUD's synced assault-mode changes forwarded from
--     hooks/hudassaultcorner.lua ("assault_mode" signal).

local XDM = _G.ExtraDynamicMusic

XDM:RegisterCondition({
	id = "endless",
	default_priority = 60,

	_synced_endless = false,
	_captain_endless = false,

	on_signal = function(self, name, arg)
		if name == "assault_mode" then
			self._synced_endless = tostring(arg) == "endless"
		elseif name == "assault_endless" then
			self._captain_endless = arg and true or false
		end
	end,

	poll = function(self, t, dt)
		local on = self._synced_endless or self._captain_endless
		if not on then
			local state = managers.groupai and managers.groupai:state()
			if state then
				if state._hunt_mode then
					on = true
				elseif state.get_hunt_mode then
					local fine, hunt = pcall(state.get_hunt_mode, state)
					on = fine and hunt and true or false
				end
			end
		end
		self.active = on
		self.intensity = on and 1 or 0
	end,
})
