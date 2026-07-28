-- conditions/boss.lua: active while a boss-grade enemy is an active threat:
-- SWAT turrets (only while active and nearby), Captain Winters
-- (phalanx_vip), heist-specific bosses, and the Restoration Mod captains
-- (Spring, Summers, Autumn, the Headless Horseless Titan Dozer from HELL).
--
-- Enemies are identified by tweak-table name (unit:base()._tweak_table)
-- against a configurable set; turrets come from the group-AI turret
-- registry. The full scan is throttled to 2 Hz.
--
-- Two refinements over a plain alive-check:
--  * Turrets stop counting when destroyed, when their brain deactivates
--    (folded up after an assault), or when left behind beyond
--    turret_max_distance. A dormant turret two rooms back shouldn't keep
--    boss music running.
--  * intensity is proximity-shaped: 1.0 at point blank, easing down to
--    proximity_min at proximity_range and beyond. A layer opts in with
--    follow_intensity:true, giving roughly a 4 dB swell as you close in
--    on the captain. Layers without it play at full volume as before.

local XDM = _G.ExtraDynamicMusic

local BOSS_TWEAKS = {
	-- vanilla captains / heist bosses
	phalanx_vip = true,
	biker_boss = true,
	mobster_boss = true,
	hector_boss = true,
	drug_lord_boss = true,
	drug_lord_boss_stealth = true,
	-- Restoration Mod captains & friends
	spring = true,
	summers = true,
	autumn = true,
	headless_hatman = true,
}

XDM:RegisterCondition({
	id = "boss",
	default_priority = 50,

	_next_scan = 0,
	_seen = false,
	_intensity_held = 0,
	_extra = {},

	-- Distances are in game units (centimeters).
	_turret_max_dis = 4000,   -- "left behind" cutoff for turrets: 40 m
	_prox_range = 3000,       -- distance of the quiet end of the swell: 30 m
	_prox_min = 0.63,         -- gain factor at/beyond prox_range (~ -4 dB)

	-- Stock tuning between songs; must mirror the initial values above.
	-- _extra empties too, so one song's custom boss names can't follow the
	-- next song around (configure() refills it right afterwards).
	reset = function(self)
		self._extra = {}
		self._turret_max_dis = 4000
		self._prox_range = 3000
		self._prox_min = 0.63
	end,

	configure = function(self, params)
		if type(params.extra_tweak_names) == "table" then
			for _, name in ipairs(params.extra_tweak_names) do
				self._extra[tostring(name)] = true
			end
		end
		self._turret_max_dis = tonumber(params.turret_max_distance) or self._turret_max_dis
		self._prox_range = tonumber(params.proximity_range) or self._prox_range
		self._prox_min = tonumber(params.proximity_min) or self._prox_min
	end,

	poll = function(self, t, dt)
		if t < self._next_scan then
			self.active = self._seen
			self.intensity = self._intensity_held
			return
		end
		self._next_scan = t + 0.5

		local ppos
		pcall(function()
			local plr = managers.player and managers.player:player_unit()
			if plr and alive(plr) then
				ppos = plr:position()
			end
		end)

		-- Returns the distance to the unit if it is a live threat, or nil.
		local function threat_distance(unit, is_turret)
			if not (unit and alive(unit)) then
				return nil
			end
			local ok, dead = pcall(function()
				return unit:character_damage() and unit:character_damage():dead()
			end)
			if ok and dead then
				return nil
			end
			local dist
			pcall(function()
				if ppos then
					dist = mvector3.distance(ppos, unit:position())
				end
			end)
			if is_turret then
				-- Folded-up / deactivated turret brains read as inactive.
				local fine, inactive = pcall(function()
					local b = unit:brain()
					return b and b._active == false
				end)
				if fine and inactive then
					return nil
				end
				if dist and dist > self._turret_max_dis then
					return nil -- left behind; no longer a threat
				end
			end
			return dist or 0
		end

		local nearest

		-- Deployed SWAT turrets.
		local state = managers.groupai and managers.groupai:state()
		if state and state.turrets then
			local fine, turrets = pcall(state.turrets, state)
			if fine and type(turrets) == "table" then
				for _, unit in pairs(turrets) do
					local d = threat_distance(unit, true)
					if d and (not nearest or d < nearest) then
						nearest = d
					end
				end
			end
		end

		-- Boss-grade enemies by tweak name.
		if managers.enemy then
			local fine, enemies = pcall(managers.enemy.all_enemies, managers.enemy)
			if fine and type(enemies) == "table" then
				for _, data in pairs(enemies) do
					local unit = data.unit
					local ok, tweak = pcall(function()
						return unit and alive(unit) and unit:base()._tweak_table
					end)
					if ok and tweak and (BOSS_TWEAKS[tweak] or self._extra[tweak]) then
						local d = threat_distance(unit, false)
						if d and (not nearest or d < nearest) then
							nearest = d
						end
					end
				end
			end
		end

		self._seen = nearest ~= nil
		if self._seen then
			-- Proximity swell: 1.0 up close, easing to _prox_min at range.
			local prox = 1 - math.clamp((nearest or 0) / self._prox_range, 0, 1)
			self._intensity_held = self._prox_min + (1 - self._prox_min) * prox
		else
			self._intensity_held = 0
		end
		self.active = self._seen
		self.intensity = self._intensity_held
	end,
})
