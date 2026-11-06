-- Player guarding and parrying, decided on the server.
--
-- Holding right click raises the sword, and moving the mouse tilts it (the client
-- reports both through the Guard remote). Whether a hit is parried, blocked or gets
-- through depends on the timing and on the blade's angle against the attack's
-- direction: see shared/ParryRules. A parry costs nothing and staggers the attacker,
-- a block costs shield, and a miss lands in full and knocks the guard down. The
-- shield also drains while guarding and refills while not; if it runs out the guard
-- breaks and can't be raised again until it has refilled partway.
--
-- State is shown to the client through attributes on the Player: Shield (0-100),
-- Guarding, GuardBroken, and ParryTime / BlockTime / GuardMissTime (server time of
-- the latest one).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ParryRules = require(ReplicatedStorage.Shared.ParryRules)

local MAX_SHIELD = 100
local GUARD_MAX_TIME = 1.5 -- a guard drops by itself after this long
local DRAIN_PER_SECOND = 22 -- while guarding
local BLOCK_COST_PER_DAMAGE = 3 -- shield lost per point of damage blocked
local REGEN_PER_SECOND = 25
local REGEN_DELAY = 0.8 -- after lowering the guard, before the shield starts refilling
local BROKEN_UNTIL = 50 -- a broken guard can be raised again once the shield is back to this
local GUARD_ARC = math.rad(80) -- half-angle in front of the player that the guard covers

local Guard = {}

type State = {
	shield: number,
	guarding: boolean,
	guardStart: number,
	lastGuardEnd: number,
	broken: boolean,
	tilt: number, -- radians, as reported by the client; see ParryRules
}

local states: { [Player]: State } = {}

local function getState(player: Player): State
	local state = states[player]
	if not state then
		state = { shield = MAX_SHIELD, guarding = false, guardStart = 0, lastGuardEnd = 0, broken = false, tilt = 0 }
		states[player] = state
	end
	return state
end

local function publish(player: Player, state: State)
	player:SetAttribute("Shield", math.floor(state.shield + 0.5))
	player:SetAttribute("Guarding", state.guarding)
	player:SetAttribute("GuardBroken", state.broken)
end

local function lower(player: Player, state: State)
	if state.guarding then
		state.guarding = false
		state.lastGuardEnd = os.clock()
		publish(player, state)
	end
end

local function flatUnit(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-3 then f.Unit else Vector3.zAxis
end

-- Call before damaging `player` with the attack `attackName` (a key of
-- ParryRules.ATTACKS) from `attackerPosition`. Returns "parry" or "block" if the
-- guard stopped it (the caller should then skip the damage), or nil if it lands.
function Guard.tryBlock(player: Player, attackerPosition: Vector3, damage: number, attackName: string): string?
	local state = states[player]
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not (state and state.guarding and root) then
		return nil
	end
	local facing = flatUnit(root.CFrame.LookVector)
	if facing:Dot(flatUnit(attackerPosition - root.Position)) < math.cos(GUARD_ARC) then
		return nil -- from the side or behind
	end

	local result = ParryRules.judge(attackName, state.tilt, os.clock() - state.guardStart)
	if result == "parry" then
		player:SetAttribute("ParryTime", workspace:GetServerTimeNow())
		return "parry"
	elseif result == "miss" then
		-- The blade didn't cross the attack: it gets through and knocks the guard aside.
		player:SetAttribute("GuardMissTime", workspace:GetServerTimeNow())
		lower(player, state)
		return nil
	end
	state.shield = math.max(state.shield - damage * BLOCK_COST_PER_DAMAGE, 0)
	if state.shield == 0 then
		-- The blow gets through and breaks the guard.
		state.broken = true
		lower(player, state)
		return nil
	end
	player:SetAttribute("BlockTime", workspace:GetServerTimeNow())
	publish(player, state)
	return "block"
end

function Guard.start()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local remote = remotes:FindFirstChild("Guard") :: RemoteEvent?
	if not remote then
		local created = Instance.new("RemoteEvent")
		created.Name = "Guard"
		created.Parent = remotes
		remote = created
	end

	-- ("raise", tilt), ("tilt", tilt) or ("lower").
	(remote :: RemoteEvent).OnServerEvent:Connect(function(player, action, tilt)
		local state = getState(player)
		if typeof(tilt) == "number" and tilt == tilt then -- tilt == tilt rejects NaN
			state.tilt = math.clamp(tilt, -ParryRules.MAX_TILT, ParryRules.MAX_TILT)
		end
		if action == "raise" then
			if not state.guarding and not state.broken and state.shield > 0 then
				state.guarding = true
				state.guardStart = os.clock()
				publish(player, state)
			end
		elseif action == "lower" then
			lower(player, state)
		end
	end)

	Players.PlayerAdded:Connect(function(player)
		publish(player, getState(player))
	end)
	for _, player in Players:GetPlayers() do
		publish(player, getState(player))
	end
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)

	RunService.Heartbeat:Connect(function(dt)
		local now = os.clock()
		for player, state in states do
			local before = state.shield
			if state.guarding then
				state.shield = math.max(state.shield - DRAIN_PER_SECOND * dt, 0)
				if state.shield == 0 then
					state.broken = true
					lower(player, state)
				elseif now - state.guardStart > GUARD_MAX_TIME + 0.25 then
					lower(player, state) -- the client should have dropped it already; small allowance for lag
				end
			elseif now - state.lastGuardEnd > REGEN_DELAY then
				state.shield = math.min(state.shield + REGEN_PER_SECOND * dt, MAX_SHIELD)
				if state.broken and state.shield >= BROKEN_UNTIL then
					state.broken = false
					publish(player, state)
				end
			end
			if math.floor(state.shield + 0.5) ~= math.floor(before + 0.5) then
				publish(player, state)
			end
		end
	end)
end

return Guard
