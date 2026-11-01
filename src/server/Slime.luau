-- Slime monster: server-side body and AI. It hops around, tackles and spits goo.
--
-- The server only simulates an invisible physics ball ("Core", tagged SlimeCore).
-- Each client draws the jiggling body around it (see client/SlimeVisuals), driven
-- by the ball's real velocity, so anything that shoves it makes it wobble.

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local RADIUS = 3 -- visual radius; the collider is a little smaller so the body overhangs it
local MAX_HEALTH = 120
local RESPAWN_DELAY = 25

local SLEEP_RANGE = 220 -- no player this close: freeze to save physics
local AGGRO_RANGE = 90
local WANDER_RADIUS = 30

local HOP_SPEED = 24
local HOP_UP = 46
local WANDER_HOP_SPEED = 13
local WANDER_HOP_UP = 32
local HOP_WINDUP = 0.22 -- seconds spent compressing before each hop
local REST_MIN, REST_MAX = 0.2, 0.5
local WANDER_REST_MIN, WANDER_REST_MAX = 0.8, 2.5

local TACKLE_RANGE = 28
local TACKLE_WINDUP = 0.55
local TACKLE_SPEED = 72
local TACKLE_UP = 34
local TACKLE_DAMAGE = 18
local TACKLE_KNOCKBACK = 70
local TACKLE_COOLDOWN = 3
local TACKLE_RECOVER = 0.9 -- sits still afterward: the player's window to hit back

local GOO_MIN_RANGE, GOO_MAX_RANGE = 16, 70
local GOO_WINDUP = 0.45
local GOO_SPEED = 75
local GOO_DAMAGE = 12
local GOO_SPLASH_RADIUS = 4
local GOO_COOLDOWN = 3.5
local GOO_LIFETIME = 3

local KNOCKBACK_PER_DAMAGE = 1.3

local SLIME_COLOR = Color3.fromRGB(95, 200, 70)

local Slime = {}
Slime.__index = Slime

local slimes: { any } = {}
local slimesByModel: { [Instance]: any } = {}
local goos: { any } = {}
local parentFolder: Instance
local showDamageNumber: (number, Vector3) -> ()
local hitRemote: RemoteEvent
local knockbackRemote: RemoteEvent
local gooFolder: Folder

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

function Slime.new(position: Vector3)
	local model = Instance.new("Model")
	model.Name = "Slime"

	local core = Instance.new("Part")
	core.Name = "Core"
	core.Shape = Enum.PartType.Ball
	core.Size = Vector3.one * RADIUS * 1.84
	core.Transparency = 1
	core.CFrame = CFrame.new(position)
	core.CustomPhysicalProperties = PhysicalProperties.new(0.8, 1, 0, 100, 100)
	core:SetAttribute("Radius", RADIUS)
	core:SetAttribute("Action", "Idle")
	core.Parent = model
	model.PrimaryPart = core

	local attachment = Instance.new("Attachment")
	attachment.Parent = core
	local align = Instance.new("AlignOrientation") -- keeps the ball from rolling
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.MaxTorque = math.huge
	align.Responsiveness = 30
	align.Parent = core

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.new(4, 0, 0.45, 0)
	gui.StudsOffset = Vector3.new(0, RADIUS + 1.2, 0)
	gui.MaxDistance = 60
	local back = Instance.new("Frame")
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	back.BorderSizePixel = 0
	back.Parent = gui
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = SLIME_COLOR
	fill.BorderSizePixel = 0
	fill.Parent = back
	gui.Parent = core

	model.Parent = parentFolder
	core:SetNetworkOwner(nil)
	CollectionService:AddTag(core, "SlimeCore")

	local self = setmetatable({
		model = model,
		core = core,
		pivot = core, -- the sword hit check measures distance from `pivot`
		align = align,
		fill = fill,
		home = position,
		health = MAX_HEALTH,
		state = "Rest",
		timer = math.random() * 2,
		target = nil :: any,
		tackleHit = false,
		tackleReadyAt = 0,
		gooReadyAt = 0,
		asleep = false,
		dead = false,
		rayParams = RaycastParams.new(),
	}, Slime)
	self.rayParams.FilterDescendantsInstances = { model, gooFolder }
	table.insert(slimes, self)
	slimesByModel[model] = self
	return self
end

function Slime.fromModel(model: Instance)
	return slimesByModel[model]
end

function Slime:_setAction(action: string)
	self.core:SetAttribute("Action", action)
end

function Slime:_face(direction: Vector3)
	self.align.CFrame = CFrame.lookAt(Vector3.zero, flatUnit(direction))
end

function Slime:_isGrounded(): boolean
	local reach = self.core.Size.Y / 2 + 0.8
	return workspace:Raycast(self.core.Position, Vector3.new(0, -reach, 0), self.rayParams) ~= nil
end

function Slime:_nearest(roots, range: number)
	local best, bestDistance = nil, range
	for _, entry in roots do
		local distance = (entry.root.Position - self.core.Position).Magnitude
		if distance < bestDistance then
			best, bestDistance = entry, distance
		end
	end
	return best, bestDistance
end

function Slime:_hop(direction: Vector3, speed: number, up: number)
	self:_face(direction)
	self.hopVelocity = flatUnit(direction) * speed + Vector3.yAxis * up
	self.state = "WindHop"
	self.timer = HOP_WINDUP
	self:_setAction("WindUp")
end

function Slime:_land(restMin: number, restMax: number)
	self.state = "Rest"
	self.timer = restMin + math.random() * (restMax - restMin)
	self:_setAction("Idle")
end

local function splat(position: Vector3, normal: Vector3)
	local part = Instance.new("Part")
	part.Name = "GooSplat"
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(0.15, 6, 6)
	part.Color = SLIME_COLOR
	part.Material = Enum.Material.Glass
	part.Transparency = 0.25
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	-- A cylinder's flat faces point along its X axis.
	part.CFrame = CFrame.lookAt(position + normal * 0.08, position + normal * 1.08) * CFrame.Angles(0, math.pi / 2, 0)
	part.Parent = gooFolder
	TweenService:Create(part, TweenInfo.new(3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Transparency = 1,
		Size = Vector3.new(0.15, 4, 4),
	}):Play()
	Debris:AddItem(part, 3.1)
end

local function explodeGoo(goo, position: Vector3, normal: Vector3)
	goo.part:Destroy()
	splat(position, normal)
	for _, entry in alivePlayerRoots() do
		if (entry.root.Position - position).Magnitude <= GOO_SPLASH_RADIUS + 2.5 then
			entry.humanoid:TakeDamage(GOO_DAMAGE)
		end
	end
end

function Slime:_spit(targetPosition: Vector3)
	local mouth = self.core.Position + flatUnit(targetPosition - self.core.Position) * RADIUS + Vector3.yAxis * 1
	local distance = (targetPosition - mouth).Magnitude
	local flightTime = math.clamp(distance / GOO_SPEED, 0.3, 1.1)
	local velocity = (targetPosition - mouth) / flightTime + Vector3.yAxis * (0.5 * workspace.Gravity * flightTime)

	local part = Instance.new("Part")
	part.Name = "Goo"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.one * 1.5
	part.Color = SLIME_COLOR
	part.Material = Enum.Material.Glass
	part.Transparency = 0.2
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CFrame = CFrame.new(mouth)
	part.Parent = gooFolder
	part:SetNetworkOwner(nil)
	part.AssemblyLinearVelocity = velocity

	local a0, a1 = Instance.new("Attachment"), Instance.new("Attachment")
	a0.Position, a1.Position = Vector3.new(0, 0.6, 0), Vector3.new(0, -0.6, 0)
	a0.Parent, a1.Parent = part, part
	local trail = Instance.new("Trail")
	trail.Attachment0, trail.Attachment1 = a0, a1
	trail.Color = ColorSequence.new(SLIME_COLOR)
	trail.Transparency = NumberSequence.new(0.4, 1)
	trail.Lifetime = 0.25
	trail.Parent = part

	table.insert(goos, {
		part = part,
		last = mouth,
		expires = os.clock() + GOO_LIFETIME,
		owner = self.model,
		rayParams = self.rayParams,
	})

	-- Recoil, so the spit visibly jolts the body.
	self.core.AssemblyLinearVelocity = -flatUnit(velocity) * 16 + Vector3.yAxis * 10
end

function Slime:_decide(roots)
	local target, distance = self:_nearest(roots, AGGRO_RANGE)
	self.target = target
	local now = os.clock()

	if not target then
		local offset = self.home - self.core.Position
		local direction = if flat(offset).Magnitude > WANDER_RADIUS
			then offset
			else Vector3.new(math.random() - 0.5, 0, math.random() - 0.5)
		self:_hop(direction, WANDER_HOP_SPEED, WANDER_HOP_UP)
		return
	end

	local toTarget = target.root.Position - self.core.Position
	self:_face(toTarget)
	if distance <= TACKLE_RANGE and now >= self.tackleReadyAt then
		self.state = "WindTackle"
		self.timer = TACKLE_WINDUP
		self:_setAction("WindUp")
	elseif distance >= GOO_MIN_RANGE and distance <= GOO_MAX_RANGE and now >= self.gooReadyAt then
		self.state = "WindSpit"
		self.timer = GOO_WINDUP
		self:_setAction("WindUp")
	else
		-- Not a perfect beeline, so it reads as hopping rather than homing.
		local angle = math.rad((math.random() - 0.5) * 50)
		self:_hop(CFrame.Angles(0, angle, 0) * flatUnit(toTarget), HOP_SPEED, HOP_UP)
	end
end

function Slime:_step(dt: number, roots)
	if self.dead then
		return
	end

	local _, nearest = self:_nearest(roots, SLEEP_RANGE)
	local shouldSleep = nearest == SLEEP_RANGE
	if shouldSleep ~= self.asleep then
		self.asleep = shouldSleep
		self.core.Anchored = shouldSleep
		if not shouldSleep then
			self.core:SetNetworkOwner(nil)
		end
	end
	if shouldSleep then
		return
	end

	self.timer -= dt
	local state = self.state

	if state == "Rest" then
		if self.timer <= 0 and self:_isGrounded() then
			self:_decide(roots)
		end
	elseif state == "WindHop" then
		if self.timer <= 0 then
			self.core.AssemblyLinearVelocity = self.hopVelocity
			self:_setAction("Hop")
			self.state = "Air"
			self.timer = 0.15 -- ignore the ground for a moment while taking off
		end
	elseif state == "Air" then
		if self.timer <= 0 and self:_isGrounded() then
			if self.target then
				self:_land(REST_MIN, REST_MAX)
			else
				self:_land(WANDER_REST_MIN, WANDER_REST_MAX)
			end
		end
	elseif state == "WindTackle" then
		local target = self.target
		if target and target.root.Parent then
			self:_face(target.root.Position - self.core.Position)
		end
		if self.timer <= 0 then
			if target and target.root.Parent then
				local direction = flatUnit(target.root.Position - self.core.Position)
				self.core.AssemblyLinearVelocity = direction * TACKLE_SPEED + Vector3.yAxis * TACKLE_UP
				self.state = "Tackling"
				self.timer = 0.2
				self.tackleHit = false
				self.tackleReadyAt = os.clock() + TACKLE_COOLDOWN
				self:_setAction("Tackle")
			else
				self:_land(REST_MIN, REST_MAX)
			end
		end
	elseif state == "Tackling" then
		if not self.tackleHit then
			for _, entry in roots do
				if (entry.root.Position - self.core.Position).Magnitude <= RADIUS + 2.5 then
					self.tackleHit = true
					entry.humanoid:TakeDamage(TACKLE_DAMAGE)
					local push = flatUnit(entry.root.Position - self.core.Position) * TACKLE_KNOCKBACK
					knockbackRemote:FireClient(entry.player, push + Vector3.yAxis * 35)
					-- Splats against the player and loses its momentum.
					self.core.AssemblyLinearVelocity *= 0.25
					break
				end
			end
		end
		if self.timer <= 0 and self:_isGrounded() then
			self:_land(TACKLE_RECOVER, TACKLE_RECOVER)
		end
	elseif state == "WindSpit" then
		local target = self.target
		if target and target.root.Parent then
			self:_face(target.root.Position - self.core.Position)
		end
		if self.timer <= 0 then
			if target and target.root.Parent then
				-- Aim ahead of a moving player.
				local distance = (target.root.Position - self.core.Position).Magnitude
				local lead = target.root.AssemblyLinearVelocity * math.clamp(distance / GOO_SPEED, 0.3, 1.1) * 0.7
				self:_spit(target.root.Position + flat(lead))
				self.gooReadyAt = os.clock() + GOO_COOLDOWN
				self:_setAction("Spit")
			end
			self:_land(0.5, 0.8)
			self.core:SetAttribute("Action", "Spit") -- stays set until the next action, for the visuals
		end
	end
end

function Slime:takeHit(damage: number, hitPosition: Vector3, attackerPosition: Vector3)
	if self.dead then
		return
	end
	self.health = math.max(self.health - damage, 0)
	self.fill.Size = UDim2.fromScale(self.health / MAX_HEALTH, 1)
	showDamageNumber(damage, hitPosition)
	hitRemote:FireAllClients(self.core, hitPosition, damage)

	if not self.core.Anchored then
		local away = flatUnit(self.core.Position - attackerPosition)
		self.core.AssemblyLinearVelocity += away * damage * KNOCKBACK_PER_DAMAGE + Vector3.yAxis * damage * 0.5
	end

	if self.health == 0 then
		self:_die()
	end
end

function Slime:_die()
	self.dead = true
	local position = self.core.Position
	local home = self.home

	for _ = 1, 10 do
		local blob = Instance.new("Part")
		blob.Name = "SlimeBlob"
		blob.Shape = Enum.PartType.Ball
		blob.Size = Vector3.one * (0.6 + math.random() * 0.9)
		blob.Color = SLIME_COLOR
		blob.Material = Enum.Material.Glass
		blob.Transparency = 0.25
		blob.CFrame = CFrame.new(position + Vector3.new(math.random() - 0.5, math.random(), math.random() - 0.5) * RADIUS)
		blob.Parent = gooFolder
		blob:SetNetworkOwner(nil)
		blob.AssemblyLinearVelocity = Vector3.new(math.random() * 70 - 35, 30 + math.random() * 35, math.random() * 70 - 35)
		Debris:AddItem(blob, 2.5)
	end
	local ground = workspace:Raycast(position, Vector3.new(0, -RADIUS * 3, 0), self.rayParams)
	if ground then
		splat(ground.Position, ground.Normal)
	end

	table.remove(slimes, table.find(slimes, self))
	slimesByModel[self.model] = nil
	self.model:Destroy()
	task.delay(RESPAWN_DELAY, function()
		Slime.new(home)
	end)
end

local function stepGoos()
	for i = #goos, 1, -1 do
		local goo = goos[i]
		local part = goo.part
		local position = part.Position
		local hit = workspace:Raycast(goo.last, position - goo.last, goo.rayParams)
		if hit then
			explodeGoo(goo, hit.Position, hit.Normal)
			table.remove(goos, i)
		elseif os.clock() > goo.expires then
			part:Destroy()
			table.remove(goos, i)
		else
			goo.last = position
		end
	end
end

function Slime.start(parent: Instance, damageNumber: (number, Vector3) -> ())
	parentFolder = parent
	showDamageNumber = damageNumber
	hitRemote = getRemote("SlimeHit")
	knockbackRemote = getRemote("SlimeKnockback")
	gooFolder = Instance.new("Folder")
	gooFolder.Name = "SlimeGoo"
	gooFolder.Parent = workspace

	RunService.Heartbeat:Connect(function(dt)
		local roots = alivePlayerRoots()
		for _, slime in table.clone(slimes) do
			slime:_step(dt, roots)
		end
		stepGoos()
	end)
end

return Slime
