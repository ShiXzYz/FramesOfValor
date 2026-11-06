-- Goblin monster: server-side AI. It wanders, chases, circles the player while its
-- attack recovers, and fights with a dagger: a lunging stab, a wide slash and an
-- overhead chop, sometimes strung together into a two-hit combo.
--
-- The body is a real model (ServerStorage.MonsterTemplates.Goblin) that builders can
-- restyle in Studio; this only clones it. The server picks actions and sets them as
-- the "Action" attribute, and each client animates the joints to match (see
-- client/GoblinVisuals). Dagger hits are checked here against where the goblin
-- stands and faces, not against the animated dagger.

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Guard = require(script.Parent.Guard)

local MAX_HEALTH = 90
local RESPAWN_DELAY = 30
local CORPSE_TIME = 4

local SLEEP_RANGE = 220 -- no player this close: freeze to save physics
local AGGRO_RANGE = 70
local LEASH_RANGE = 120 -- gives up a chase this far from home
local WANDER_RADIUS = 25

local WANDER_SPEED = 7
local CHASE_SPEED = 14
local STRAFE_SPEED = 8
local STRAFE_DISTANCE = 6 -- circles at about this range while its attack recovers

local ATTACK_COOLDOWN = 0.8 -- after recovering, before the next attack

type Attack = {
	windup: number, -- seconds of telegraph before the strike
	time: number, -- length of the strike
	lunge: number, -- studs/second stepped forward during the strike...
	lungeTime: number, -- ...for this long
	range: number,
	cone: number, -- half-angle in front that it reaches
	damage: number,
	recover: number, -- stands still afterward: the player's window to hit back
}

-- Each name is also the "Action" the clients animate (with "Wind" in front for the wind-up).
local ATTACKS: { [string]: Attack } = {
	Stab = { windup = 0.5, time = 0.3, lunge = 30, lungeTime = 0.15, range = 6.5, cone = math.rad(35), damage = 14, recover = 0.6 },
	Slash = { windup = 0.4, time = 0.25, lunge = 10, lungeTime = 0.1, range = 5.5, cone = math.rad(80), damage = 10, recover = 0.45 },
	Chop = { windup = 0.6, time = 0.3, lunge = 16, lungeTime = 0.12, range = 6, cone = math.rad(40), damage = 18, recover = 0.75 },
}

-- Picked at random (by weight) among the patterns whose first attack reaches from where it stands.
local PATTERNS = {
	{ attacks = { "Stab" }, weight = 2, reach = 7 },
	{ attacks = { "Chop" }, weight = 3, reach = 6.5 },
	{ attacks = { "Slash" }, weight = 1, reach = 5.5 },
	{ attacks = { "Slash", "Chop" }, weight = 2, reach = 5.5 },
	{ attacks = { "Stab", "Slash" }, weight = 2, reach = 7 },
}
local ATTACK_RANGE = 7 -- the longest reach above
local COMBO_WINDUP_SCALE = 0.55 -- follow-up attacks in a combo wind up this much faster

local HIT_START, HIT_END = 0.05, 0.18 -- seconds into a strike when the dagger can connect
local KNOCKBACK = 30

local HURT_TIME = 0.35 -- a hit during a wind-up or while moving interrupts it this long
local PARRIED_TIME = 1.0 -- staggered this long after a player parries it
local KNOCKBACK_PER_DAMAGE = 0.35 -- studs/second of push per point of sword damage...
local MAX_KNOCKBACK = 10 -- ...up to this, so even a full-power hit only staggers it back a step or two

local Goblin = {}
Goblin.__index = Goblin

local goblins: { any } = {}
local goblinsByModel: { [Instance]: any } = {}
local parentFolder: Instance
local showDamageNumber: (number, Vector3) -> ()
local knockbackRemote: RemoteEvent

local function getRemote(name: string): RemoteEvent
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local remote = remotes:FindFirstChild(name)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = remotes
	end
	return remote
end

local function alivePlayerRoots(): { { player: Player, root: BasePart, humanoid: Humanoid } }
	local list = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if humanoid and root and humanoid.Health > 0 then
			table.insert(list, { player = player, root = root, humanoid = humanoid })
		end
	end
	return list
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function flatUnit(v: Vector3): Vector3
	local f = flat(v)
	return if f.Magnitude > 1e-3 then f.Unit else Vector3.zAxis
end

local function healthBar(root: BasePart)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.new(3, 0, 0.35, 0)
	gui.StudsOffset = Vector3.new(0, 3.4, 0)
	gui.MaxDistance = 60
	local back = Instance.new("Frame")
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	back.BorderSizePixel = 0
	back.Parent = gui
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(200, 60, 50)
	fill.BorderSizePixel = 0
	fill.Parent = back
	gui.Parent = root
	return fill
end

function Goblin.new(position: Vector3)
	local model = ServerStorage.MonsterTemplates.Goblin:Clone()
	local root = model.HumanoidRootPart :: BasePart
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	model:PivotTo(CFrame.new(position) * CFrame.Angles(0, math.random() * math.pi * 2, 0))
	humanoid.AutoRotate = false

	local attachment = Instance.new("Attachment")
	attachment.Parent = root
	local align = Instance.new("AlignOrientation") -- turns it to face where it's going or attacking
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.MaxTorque = math.huge
	align.Responsiveness = 25
	align.CFrame = root.CFrame.Rotation
	align.Parent = root

	local fill = healthBar(root)
	root:SetAttribute("Action", "Idle")
	model.Parent = parentFolder
	root:SetNetworkOwner(nil)
	CollectionService:AddTag(root, "GoblinRoot")
	CollectionService:AddTag(root, "Monster")

	local self = setmetatable({
		model = model,
		root = root,
		pivot = root, -- the sword hit check measures distance from `pivot`
		humanoid = humanoid,
		align = align,
		fill = fill,
		home = position,
		health = MAX_HEALTH,
		state = "Idle",
		timer = math.random() * 2,
		target = nil :: any,
		wanderGoal = position,
		attackReadyAt = 0,
		strafeSign = 1,
		strafeFlipAt = 0,
		stuckTime = 0,
		hitPlayers = {},
		combo = {} :: { string }, -- attack names in the pattern being performed
		comboIndex = 0,
		attack = nil :: Attack?,
		strikeTime = 0,
		asleep = false,
		dead = false,
	}, Goblin)
	table.insert(goblins, self)
	goblinsByModel[model] = self
	return self
end

function Goblin.fromModel(model: Instance)
	return goblinsByModel[model]
end

function Goblin:_setAction(action: string)
	self.root:SetAttribute("Action", action)
end

function Goblin:_face(direction: Vector3)
	self.align.CFrame = CFrame.lookAt(Vector3.zero, flatUnit(direction))
end

-- Walks along `direction` (or stands still for zero) at `speed`, facing that way.
function Goblin:_move(direction: Vector3, speed: number, faceMove: boolean)
	local f = flat(direction)
	self.humanoid.WalkSpeed = speed
	self.humanoid:Move(if f.Magnitude > 1e-3 then f.Unit else Vector3.zero)
	if faceMove and f.Magnitude > 1e-3 then
		self:_face(f)
	end
end

function Goblin:_nearest(roots, range: number)
	local best, bestDistance = nil, range
	for _, entry in roots do
		local distance = (entry.root.Position - self.root.Position).Magnitude
		if distance < bestDistance then
			best, bestDistance = entry, distance
		end
	end
	return best, bestDistance
end

-- Picks a pattern that can reach `distance`, or nil if none can.
local function pickPattern(distance: number)
	local total = 0
	for _, pattern in PATTERNS do
		if distance <= pattern.reach then
			total += pattern.weight
		end
	end
	local roll = math.random() * total
	for _, pattern in PATTERNS do
		if distance <= pattern.reach then
			roll -= pattern.weight
			if roll <= 0 then
				return pattern
			end
		end
	end
	return nil
end

-- Winds up the combo's attack number `index`.
function Goblin:_startAttack(index: number)
	local name = self.combo[index]
	self.comboIndex = index
	self.attack = ATTACKS[name]
	self.state = "Wind"
	self.timer = self.attack.windup * (if index > 1 then COMBO_WINDUP_SCALE else 1)
	self:_move(Vector3.zero, 0, false)
	self:_setAction("Wind" .. name)
end

function Goblin:_startStrike()
	self.state = "Strike"
	self.timer = self.attack.time
	self.strikeTime = 0
	table.clear(self.hitPlayers)
	self:_setAction(self.combo[self.comboIndex])
end

-- Damages every player inside the dagger's reach in front of the goblin, unless their
-- guard stops it. Returns true if someone parried it (the goblin is then staggered).
function Goblin:_strikePlayers(roots, range: number, cone: number, damage: number): boolean
	local look = flatUnit(self.root.CFrame.LookVector)
	for _, entry in roots do
		local offset = entry.root.Position - self.root.Position
		if not self.hitPlayers[entry.player]
			and flat(offset).Magnitude <= range
			and math.abs(offset.Y) < 4
			and look:Dot(flatUnit(offset)) >= math.cos(cone)
		then
			self.hitPlayers[entry.player] = true
			local guarded = Guard.tryBlock(entry.player, self.root.Position, damage, "Goblin" .. self.combo[self.comboIndex])
			if guarded == "parry" then
				self.state = "Hurt"
				self.timer = PARRIED_TIME
				self:_move(Vector3.zero, 0, false)
				self:_setAction("Hurt")
				self.root:SetAttribute("HitTime", workspace:GetServerTimeNow())
				self.attackReadyAt = os.clock() + PARRIED_TIME + ATTACK_COOLDOWN
				return true
			elseif guarded == "block" then
				knockbackRemote:FireClient(entry.player, flatUnit(offset) * KNOCKBACK * 0.4 + Vector3.yAxis * 8)
			else
				entry.humanoid:TakeDamage(damage)
				knockbackRemote:FireClient(entry.player, flatUnit(offset) * KNOCKBACK + Vector3.yAxis * 20)
			end
		end
	end
	return false
end

function Goblin:_step(dt: number, roots)
	if self.dead then
		return
	end

	local _, nearest = self:_nearest(roots, SLEEP_RANGE)
	local shouldSleep = nearest == SLEEP_RANGE
	if shouldSleep ~= self.asleep then
		self.asleep = shouldSleep
		self.root.Anchored = shouldSleep
		if not shouldSleep then
			self.root:SetNetworkOwner(nil)
		end
	end
	if shouldSleep then
		return
	end

	-- Keep the current target until it gets away, otherwise take the nearest one.
	local target = self.target
	if target and (not target.root.Parent or target.humanoid.Health <= 0
		or (target.root.Position - self.root.Position).Magnitude > AGGRO_RANGE * 1.3
		or (self.root.Position - self.home).Magnitude > LEASH_RANGE)
	then
		target = nil
	end
	if not target and (self.root.Position - self.home).Magnitude <= LEASH_RANGE then
		target = self:_nearest(roots, AGGRO_RANGE)
	end
	self.target = target

	self.timer -= dt
	local state = self.state
	local now = os.clock()
	local toTarget = if target then target.root.Position - self.root.Position else Vector3.zero
	local distance = flat(toTarget).Magnitude

	if state == "Idle" or state == "Wander" then
		if target then
			self.state = "Chase"
			self:_setAction("Idle")
		elseif state == "Idle" then
			self:_move(Vector3.zero, 0, false)
			if self.timer <= 0 then
				local angle = math.random() * math.pi * 2
				self.wanderGoal = self.home + Vector3.new(math.cos(angle), 0, math.sin(angle)) * math.random() * WANDER_RADIUS
				self.state = "Wander"
				self.timer = 8
			end
		else
			local toGoal = flat(self.wanderGoal - self.root.Position)
			self:_move(toGoal, WANDER_SPEED, true)
			if toGoal.Magnitude < 2 or self.timer <= 0 then
				self.state = "Idle"
				self.timer = 1 + math.random() * 2.5
			end
		end
	elseif state == "Chase" then
		if not target then
			self.state = "Wander"
			self.wanderGoal = self.home
			self.timer = 12
			return
		end
		self:_face(toTarget)
		local pattern = if distance <= ATTACK_RANGE and now >= self.attackReadyAt then pickPattern(distance) else nil
		if pattern then
			self.combo = pattern.attacks
			self:_startAttack(1)
			return
		end
		if distance <= STRAFE_DISTANCE + 2 and now < self.attackReadyAt then
			-- Waiting on its attack: circle around the player instead of standing in reach.
			if now >= self.strafeFlipAt then
				self.strafeSign = if math.random() < 0.5 then -1 else 1
				self.strafeFlipAt = now + 1 + math.random() * 1.5
			end
			local side = Vector3.yAxis:Cross(flatUnit(toTarget)) * self.strafeSign
			local keepRange = flatUnit(toTarget) * (distance - STRAFE_DISTANCE) * 0.5
			self:_move(side + keepRange, STRAFE_SPEED, false)
		else
			self:_move(toTarget, CHASE_SPEED, false)
		end
		-- Hop over whatever it's walking into.
		if flat(self.root.AssemblyLinearVelocity).Magnitude < 1.5 then
			self.stuckTime += dt
			if self.stuckTime > 0.6 then
				self.humanoid.Jump = true
				self.stuckTime = 0
			end
		else
			self.stuckTime = 0
		end
	elseif state == "Wind" then
		if target then
			self:_face(toTarget)
		end
		if self.timer <= 0 then
			self:_startStrike()
		end
	elseif state == "Strike" then
		local attack = self.attack
		self.strikeTime += dt
		if self.strikeTime < attack.lungeTime then
			self:_move(self.root.CFrame.LookVector, attack.lunge, false)
		else
			self:_move(Vector3.zero, 0, false)
		end
		if self.strikeTime >= HIT_START and self.strikeTime <= HIT_END
			and self:_strikePlayers(roots, attack.range, attack.cone, attack.damage)
		then
			return -- parried: staggered, and the rest of the combo is dropped
		end
		if self.timer <= 0 then
			if self.comboIndex < #self.combo then
				self:_startAttack(self.comboIndex + 1)
			else
				self.state = "Recover"
				self.timer = attack.recover
				self.attackReadyAt = now + attack.recover + ATTACK_COOLDOWN
				self:_setAction("Recover")
			end
		end
	elseif state == "Recover" or state == "Hurt" then
		self:_move(Vector3.zero, 0, false)
		if self.timer <= 0 then
			self.state = if target then "Chase" else "Idle"
			self.timer = 1
			self:_setAction("Idle")
		end
	end
end

function Goblin:takeHit(damage: number, hitPosition: Vector3, attackerPosition: Vector3)
	if self.dead then
		return
	end
	self.health = math.max(self.health - damage, 0)
	self.fill.Size = UDim2.fromScale(self.health / MAX_HEALTH, 1)
	showDamageNumber(damage, hitPosition)
	self.root:SetAttribute("HitTime", workspace:GetServerTimeNow())

	if self.health == 0 then
		self:_die(attackerPosition)
		return
	end

	-- A committed strike can't be interrupted; anything else flinches.
	if self.state ~= "Strike" and not self.root.Anchored then
		self.state = "Hurt"
		self.timer = HURT_TIME
		self:_setAction("Hurt")
		local away = flatUnit(self.root.Position - attackerPosition)
		self.root.AssemblyLinearVelocity += away * math.min(damage * KNOCKBACK_PER_DAMAGE, MAX_KNOCKBACK) + Vector3.yAxis * 2
	end
end

-- Stops where it stands; the clients play the fall (the "Dead" pose), then the body is removed.
function Goblin:_die(attackerPosition: Vector3)
	self.dead = true
	table.remove(goblins, table.find(goblins, self))
	goblinsByModel[self.model] = nil

	local model, root = self.model, self.root
	self:_face(attackerPosition - root.Position) -- the fall is backward, so this falls away from the blow
	self:_move(Vector3.zero, 0, false)
	self:_setAction("Dead")
	CollectionService:RemoveTag(root, "Monster")
	self.fill.Parent.Parent:Destroy() -- health bar
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanQuery = false
		end
	end
	-- Out of the monsters folder, so the sword stops treating the body as a target.
	model.Parent = workspace
	task.delay(0.15, function()
		if root.Parent then
			root.Anchored = true
		end
	end)
	Debris:AddItem(model, CORPSE_TIME)

	local home = self.home
	task.delay(RESPAWN_DELAY, function()
		Goblin.new(home)
	end)
end

function Goblin.start(parent: Instance, damageNumber: (number, Vector3) -> ())
	parentFolder = parent
	showDamageNumber = damageNumber
	-- Shared with the slime: the client sets its character's velocity to whatever this sends.
	knockbackRemote = getRemote("SlimeKnockback")

	RunService.Heartbeat:Connect(function(dt)
		local roots = alivePlayerRoots()
		for _, goblin in table.clone(goblins) do
			goblin:_step(dt, roots)
		end
	end)
end

return Goblin
