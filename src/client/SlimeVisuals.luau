-- Draws the jiggling slime body around each server-simulated SlimeCore ball.
--
-- The body is a soft mesh: every vertex sits on its own spring and is tied to its
-- neighbours, so a shove from landing, tackling or a sword hit ripples across the
-- surface, and vertices that reach the ground flatten out and bulge sideways.
--
-- That needs EditableMesh ("Allow Mesh & Image APIs" in Experience Settings >
-- Security). Without it the body falls back to one ball squashed by a spring.

local AssetService = game:GetService("AssetService")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local SLIME_COLOR = Color3.fromRGB(95, 200, 70)
local NUCLEUS_COLOR = Color3.fromRGB(30, 85, 30)
local FLASH_COLOR = Color3.fromRGB(235, 255, 225)
local TRANSPARENCY = 0.3

local SUBDIVISIONS = 2 -- 162 vertices
local SIMULATE_RANGE = 220 -- further than this the body stops updating

-- Vertex springs
local STIFFNESS = 170 -- pull back to the resting shape; lower = looser jiggle
local DAMPING = 5.5 -- lower = wobbles for longer
local NEIGHBOR_PULL = 150 -- how strongly a wobble spreads to nearby vertices
local INERTIA = 0.55 -- how much of a velocity change the surface resists
local MAX_SHOVE = 55 -- studs/second of velocity change counted in one frame
local GROUND_SPREAD = 0.3 -- how far flattened vertices bulge outward
local HIT_DENT = 9 -- inward speed per point of sword damage, scaled by closeness...
local HIT_DENT_MAX = 180 -- ...up to this

-- Resting shape
local DOME_HEIGHT = 0.82 -- top of the blob compared to a sphere
local CROUCH_HEIGHT = 0.55 -- top of the blob when winding up
local CROUCH_WIDTH = 1.22
local POSE_RATE = 12
local BREATH_RATE = 2.2
local BREATH_AMOUNT = 0.025
local MAX_DT = 1 / 30

local SlimeVisuals = {}

local bodies: { [BasePart]: any } = {}
local folder: Folder

local function newPart(name: string, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = Enum.PartType.Ball
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Parent = folder
	return part
end

-- Unit icosphere: outward-facing triangles plus each vertex's neighbours.
local function buildIcosphere(subdivisions: number)
	local t = (1 + math.sqrt(5)) / 2
	local verts = {
		Vector3.new(-1, t, 0), Vector3.new(1, t, 0), Vector3.new(-1, -t, 0), Vector3.new(1, -t, 0),
		Vector3.new(0, -1, t), Vector3.new(0, 1, t), Vector3.new(0, -1, -t), Vector3.new(0, 1, -t),
		Vector3.new(t, 0, -1), Vector3.new(t, 0, 1), Vector3.new(-t, 0, -1), Vector3.new(-t, 0, 1),
	}
	for i, v in verts do
		verts[i] = v.Unit
	end
	local faces = {
		{ 1, 12, 6 }, { 1, 6, 2 }, { 1, 2, 8 }, { 1, 8, 11 }, { 1, 11, 12 },
		{ 2, 6, 10 }, { 6, 12, 5 }, { 12, 11, 3 }, { 11, 8, 7 }, { 8, 2, 9 },
		{ 4, 10, 5 }, { 4, 5, 3 }, { 4, 3, 7 }, { 4, 7, 9 }, { 4, 9, 10 },
		{ 5, 10, 6 }, { 3, 5, 12 }, { 7, 3, 11 }, { 9, 7, 8 }, { 10, 9, 2 },
	}
	for _ = 1, subdivisions do
		local midpoints = {}
		local function midpoint(a: number, b: number): number
			local key = if a < b then a * 100000 + b else b * 100000 + a
			local index = midpoints[key]
			if not index then
				table.insert(verts, (verts[a] + verts[b]).Unit)
				index = #verts
				midpoints[key] = index
			end
			return index
		end
		local nextFaces = {}
		for _, f in faces do
			local a, b, c = f[1], f[2], f[3]
			local ab, bc, ca = midpoint(a, b), midpoint(b, c), midpoint(c, a)
			table.insert(nextFaces, { a, ab, ca })
			table.insert(nextFaces, { b, bc, ab })
			table.insert(nextFaces, { c, ca, bc })
			table.insert(nextFaces, { ab, bc, ca })
		end
		faces = nextFaces
	end

	local neighborSets = {}
	for i = 1, #verts do
		neighborSets[i] = {}
	end
	for _, f in faces do
		for i = 1, 3 do
			local a, b = f[i], f[i % 3 + 1]
			neighborSets[a][b] = true
			neighborSets[b][a] = true
		end
	end
	local neighbors = {}
	for i, set in neighborSets do
		local list = {}
		for n in set do
			table.insert(list, n)
		end
		neighbors[i] = list
	end
	return verts, faces, neighbors
end

local sphereVerts, sphereFaces, sphereNeighbors = buildIcosphere(SUBDIVISIONS)

-- Builds the soft mesh; returns nil if EditableMesh isn't available in this experience.
local meshUnavailable = false

local function tryBuildMesh(radius: number)
	if meshUnavailable then
		return nil
	end
	local ok, mesh, part, ids = pcall(function()
		local editable = AssetService:CreateEditableMesh({})
		local vertexIds = table.create(#sphereVerts)
		for i, v in sphereVerts do
			vertexIds[i] = editable:AddVertex(v * radius)
		end
		for _, f in sphereFaces do
			editable:AddTriangle(vertexIds[f[1]], vertexIds[f[2]], vertexIds[f[3]])
		end
		local meshPart = AssetService:CreateMeshPartAsync(Content.fromObject(editable))
		return editable, meshPart, vertexIds
	end)
	if not ok then
		meshUnavailable = true
		warn(`[Slime] Using the simple body: {mesh}`)
		return nil
	end
	return mesh, part, ids
end

local function setupBody(core: BasePart)
	local radius = core:GetAttribute("Radius") or 3
	local body: any = {
		core = core,
		radius = radius,
		lastVelocity = core.AssemblyLinearVelocity,
		pose = 0, -- 0 = resting, 1 = crouched
		flash = 0,
		phase = math.random() * 6,
		nucleusPos = core.Position,
		nucleusVel = Vector3.zero,
		-- Fallback squash spring, as a fraction of size per axis.
		squash = Vector3.zero,
		squashVel = Vector3.zero,
		lastAction = core:GetAttribute("Action"),
		rayParams = RaycastParams.new(),
	}
	body.rayParams.FilterType = Enum.RaycastFilterType.Include
	body.rayParams.FilterDescendantsInstances = { workspace.Terrain }
	bodies[core] = body

	body.nucleus = newPart("SlimeNucleus", NUCLEUS_COLOR, Enum.Material.SmoothPlastic)
	body.nucleus.Size = Vector3.one * radius * 0.65
	body.nucleus.Transparency = 0.15
	body.bubbles = {}
	for i = 1, 4 do
		local bubble = newPart("SlimeBubble", Color3.fromRGB(190, 240, 170), Enum.Material.SmoothPlastic)
		bubble.Size = Vector3.one * (0.25 + i * 0.07)
		bubble.Transparency = 0.45
		body.bubbles[i] = bubble
	end

	local mesh, part, ids = tryBuildMesh(radius)
	if bodies[core] ~= body then
		-- The slime went away while the mesh was being created.
		if part then
			part:Destroy()
		end
		return
	end
	if mesh then
		body.mesh, body.ids = mesh, ids
		body.part = part
		local count = #sphereVerts
		body.offsets = table.create(count, Vector3.zero)
		body.velocities = table.create(count, Vector3.zero)
		body.weights = table.create(count, 0)
		for i = 1, count do
			body.weights[i] = 0.85 + math.random() * 0.3 -- uneven, so it doesn't move as one
		end
	else
		body.part = newPart("SlimeBody", SLIME_COLOR, Enum.Material.Glass)
	end
	local bodyPart = body.part
	bodyPart.Name = "SlimeBody"
	bodyPart.Anchored = true
	bodyPart.CanCollide = false
	bodyPart.CanQuery = false
	bodyPart.CanTouch = false
	bodyPart.Color = SLIME_COLOR
	bodyPart.Material = Enum.Material.Glass
	bodyPart.Transparency = TRANSPARENCY
	bodyPart.CFrame = CFrame.new(core.Position)
	bodyPart.Parent = folder
end

local function removeBody(core: BasePart)
	local body = bodies[core]
	if not body then
		return
	end
	bodies[core] = nil
	if body.part then
		body.part:Destroy()
	end
	body.nucleus:Destroy()
	for _, bubble in body.bubbles do
		bubble:Destroy()
	end
end

local function stepMesh(body, dt: number, shove: Vector3, breath: number, ground: RaycastResult?)
	local radius = body.radius
	local center = body.core.Position
	local offsets, velocities, weights = body.offsets, body.velocities, body.weights
	local height = DOME_HEIGHT + (CROUCH_HEIGHT - DOME_HEIGHT) * body.pose
	local width = 1 + (CROUCH_WIDTH - 1) * body.pose
	local planePoint = ground and ground.Position
	local planeNormal = ground and ground.Normal

	for i, unit in sphereVerts do
		-- Only the top of the dome shrinks, so the base stays planted on the ground.
		local rest = Vector3.new(
			unit.X * radius * width * (1 + breath),
			unit.Y * radius * (if unit.Y > 0 then height * (1 - breath) else 1),
			unit.Z * radius * width * (1 + breath)
		)
		local offset = offsets[i]
		local average = Vector3.zero
		local list = sphereNeighbors[i]
		for _, n in list do
			average += offsets[n]
		end
		average /= #list

		local goal = rest - unit * radius
		local force = (goal - offset) * STIFFNESS + (average - offset) * NEIGHBOR_PULL - velocities[i] * DAMPING
		local velocity = velocities[i] + force * dt - shove * weights[i] * INERTIA
		offset += velocity * dt

		if planePoint then
			local world = center + unit * radius + offset
			local depth = (world - planePoint):Dot(planeNormal)
			if depth < 0 then
				-- Pressed into the ground: flatten, and bulge out to the sides.
				offset -= planeNormal * depth
				local outward = unit - planeNormal * unit:Dot(planeNormal)
				offset -= outward * depth * GROUND_SPREAD
				local into = velocity:Dot(planeNormal)
				if into < 0 then
					velocity -= planeNormal * into
				end
			end
		end

		offsets[i] = offset
		velocities[i] = velocity
	end

	local mesh, ids = body.mesh, body.ids
	for i, unit in sphereVerts do
		mesh:SetPosition(ids[i], unit * radius + offsets[i])
	end
	body.part.CFrame = CFrame.new(center)
end

local function stepFallback(body, dt: number, shove: Vector3, breath: number, ground: RaycastResult?)
	local force = -body.squash * STIFFNESS - body.squashVel * DAMPING
	body.squashVel += force * dt - shove * 0.03
	body.squash += body.squashVel * dt
	local s = body.squash
	local stretch = Vector3.new(math.abs(s.X), math.abs(s.Y), math.abs(s.Z))
	local total = stretch.X + stretch.Y + stretch.Z
	-- Stretching along an axis narrows the other two, keeping the volume roughly constant.
	local scale = Vector3.one * (1 - total * 0.4) + stretch * 1.2
	scale = Vector3.new(
		math.clamp(scale.X, 0.55, 1.6),
		math.clamp(scale.Y, 0.45, 1.6),
		math.clamp(scale.Z, 0.55, 1.6)
	)
	local height = DOME_HEIGHT + (CROUCH_HEIGHT - DOME_HEIGHT) * body.pose
	local width = 1 + (CROUCH_WIDTH - 1) * body.pose
	local size = body.radius * 2 * scale * Vector3.new(width + breath, height - breath, width + breath)
	local position = body.core.Position
	if ground and position.Y - ground.Position.Y < body.radius * 1.15 then
		-- Keep the base on the ground however squashed the ball is.
		position = Vector3.new(position.X, ground.Position.Y + size.Y * 0.47, position.Z)
	end
	body.part.Size = size
	body.part.CFrame = CFrame.new(position)
end

local function stepInsides(body, dt: number, shove: Vector3)
	local center = body.core.Position
	-- The nucleus hangs loosely inside and lags behind the body.
	local force = (center - body.nucleusPos) * 70 - body.nucleusVel * 7
	body.nucleusVel += force * dt - shove * 0.6
	body.nucleusPos += body.nucleusVel * dt
	local fromCenter = body.nucleusPos - center
	local limit = body.radius * 0.45
	if fromCenter.Magnitude > limit then
		body.nucleusPos = center + fromCenter.Unit * limit
	end
	body.nucleus.CFrame = CFrame.new(body.nucleusPos)

	local t = os.clock() + body.phase
	for i, bubble in body.bubbles do
		local angle = t * (0.4 + i * 0.13) + i * 1.7
		local rise = ((t * 0.25 + i * 0.27) % 1) * 2 - 1
		local ring = body.radius * 0.5 * math.sqrt(1 - rise * rise * 0.8)
		bubble.CFrame = CFrame.new(
			body.nucleusPos * 0.3
				+ center * 0.7
				+ Vector3.new(math.cos(angle) * ring, rise * body.radius * 0.5, math.sin(angle) * ring)
		)
	end
end

local function onHit(core: BasePart, hitPosition: Vector3, damage: number)
	local body = bodies[core]
	if not body then
		return
	end
	body.flash = 1
	if body.mesh then
		local into = (core.Position - hitPosition)
		into = if into.Magnitude > 1e-3 then into.Unit else Vector3.yAxis
		local speed = math.min(damage * HIT_DENT, HIT_DENT_MAX)
		for i, unit in sphereVerts do
			local closeness = math.max(unit:Dot(-into), 0)
			body.velocities[i] += into * speed * closeness * closeness * closeness
		end
	else
		body.squashVel += Vector3.new(0, -damage * 0.12, 0)
	end
end

local function onAction(body, action: string)
	if action ~= "Spit" then
		return
	end
	-- Heave the front of the body forward as the goo leaves.
	local forward = body.core.CFrame.LookVector
	if body.mesh then
		for i, unit in sphereVerts do
			local closeness = math.max(unit:Dot(forward), 0)
			body.velocities[i] += forward * 60 * closeness * closeness
		end
	else
		body.squashVel += Vector3.new(math.abs(forward.X), 0, math.abs(forward.Z)) * 3
	end
end

local function update(dt: number)
	dt = math.min(dt, MAX_DT)
	local cameraPosition = camera.CFrame.Position
	for core, body in bodies do
		if body.part and (core.Position - cameraPosition).Magnitude <= SIMULATE_RANGE then
			local velocity = core.AssemblyLinearVelocity
			local shove = velocity - body.lastVelocity
			body.lastVelocity = velocity
			if shove.Magnitude > MAX_SHOVE then
				shove = shove.Unit * MAX_SHOVE
			end

			local action = core:GetAttribute("Action")
			if action ~= body.lastAction then
				body.lastAction = action
				onAction(body, action)
			end
			local poseGoal = if action == "WindUp" then 1 else 0
			body.pose += (poseGoal - body.pose) * (1 - math.exp(-POSE_RATE * dt))
			body.flash = math.max(body.flash - dt * 5, 0)
			body.part.Color = SLIME_COLOR:Lerp(FLASH_COLOR, body.flash)

			local breath = math.sin(os.clock() * BREATH_RATE + body.phase) * BREATH_AMOUNT
			local ground = workspace:Raycast(core.Position, Vector3.new(0, -body.radius * 2, 0), body.rayParams)
			if body.mesh then
				stepMesh(body, dt, shove, breath, ground)
			else
				stepFallback(body, dt, shove, breath, ground)
			end
			stepInsides(body, dt, shove)
		end
	end
end

function SlimeVisuals.start()
	folder = Instance.new("Folder")
	folder.Name = "SlimeVisuals"
	folder.Parent = workspace

	local function onAdded(instance: Instance)
		if instance:IsA("BasePart") then
			task.spawn(setupBody, instance)
		end
	end
	for _, core in CollectionService:GetTagged("SlimeCore") do
		onAdded(core)
	end
	CollectionService:GetInstanceAddedSignal("SlimeCore"):Connect(onAdded)
	CollectionService:GetInstanceRemovedSignal("SlimeCore"):Connect(removeBody)

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	remotes:WaitForChild("SlimeHit").OnClientEvent:Connect(onHit)
	remotes:WaitForChild("SlimeKnockback").OnClientEvent:Connect(function(velocity: Vector3)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			root.AssemblyLinearVelocity = velocity
		end
	end)

	RunService.RenderStepped:Connect(update)
end

return SlimeVisuals
