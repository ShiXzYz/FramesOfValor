-- Animates goblins procedurally by posing their joints each frame.
--
-- The server says what a goblin is doing through its root's "Action" attribute; this
-- blends the joints toward a pose for that action, and layers a walk cycle, breathing
-- and a flinch on top. Wind-ups ease in slowly so the player can read them; strikes
-- snap through fast.
--
-- Works with either kind of rig: Motor6D joints with the names in JOINTS, or a skinned
-- mesh whose bones are listed in BONES. Bone axes point every which way, so each pose
-- rotation is converted from body axes into the bone's own axes.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local camera = workspace.CurrentCamera

local ANIMATE_RANGE = 200
local WIND_RATE = 10 -- how quickly joints blend toward a wind-up pose...
local STRIKE_RATE = 30 -- ...a strike...
local DEATH_RATE = 6 -- ...falling over...
local DEFAULT_RATE = 14 -- ...and everything else
local DEFAULT_LEG_LENGTH = 1.52 -- thigh + shin, if the model has no LegLength attribute
local FLINCH_TIME = 0.25
local BREATH_RATE_CALM = 1.7 -- radians/second of the breathing cycle at rest (~one breath every 3.7 s)...
local BREATH_RATE_WINDED = 5.5 -- ...and when worn out from running and fighting
local EXERTION_DECAY = 0.18 -- per second; how quickly it gets its breath back
local STEP_LENGTH = 1.6 -- studs covered per step; keeps the feet from sliding
local RUN_SPEED = 14 -- speed at which the gait is a full run

local STRIKES = { Stab = true, Slash = true, Chop = true }
local WINDUPS = { WindStab = true, WindSlash = true, WindChop = true }

-- Rigs without a joint (e.g. the part goblin has no collarbones) just skip it.
local JOINTS = {
	"Hips", "Waist", "Neck", "RightClavicle", "RightShoulder", "RightElbow", "RightWrist",
	"LeftClavicle", "LeftShoulder", "LeftElbow", "RightHip", "RightKnee", "LeftHip", "LeftKnee",
}

local BONES = {
	Hips = "Bip001 Pelvis",
	Waist = "Bip001 Spine1",
	Neck = "Bip001 Head",
	RightClavicle = "Bip001 R Clavicle",
	LeftClavicle = "Bip001 L Clavicle",
	RightShoulder = "Bip001 R UpperArm",
	RightElbow = "Bip001 R Forearm",
	RightWrist = "Bip001 R Hand",
	LeftShoulder = "Bip001 L UpperArm",
	LeftElbow = "Bip001 L Forearm",
	RightHip = "Bip001 R Thigh",
	RightKnee = "Bip001 R Calf",
	LeftHip = "Bip001 L Thigh",
	LeftKnee = "Bip001 L Calf",
}
-- The mesh goblin holds its dagger pointing forward at rest, not down along the arm.
local BONE_OFFSETS = { RightWrist = Vector3.new(-90, 0, 0) }

local GoblinVisuals = {}

type Pose = { [string]: Vector3 } -- joint name -> rotation in degrees; "Drop" -> hip drop in studs (X)

local function pose(entries: { [string]: { number } }): Pose
	local result = {}
	for name, v in entries do
		result[name] = Vector3.new(v[1] or 0, v[2] or 0, v[3] or 0)
	end
	return result
end

-- Rotations are around body axes: +X swings a hanging limb forward (and tips an
-- upright one back), +Y turns left, +Z swings a right limb outward.
local POSES: { [string]: Pose } = {
	Idle = pose({
		Drop = { 0.1 },
		Waist = { -14 }, Neck = { 12 },
		RightShoulder = { 15, 0, 10 }, RightElbow = { 30 }, RightWrist = { 45 },
		LeftShoulder = { 8, 0, -10 }, LeftElbow = { 20 },
		RightHip = { 0, 0, 5 }, LeftHip = { 0, 0, -5 },
	}),
	WindStab = pose({
		Drop = { 0.32 },
		Waist = { -18, -25 }, Neck = { 12, 22 },
		RightShoulder = { -35, 0, 25 }, RightElbow = { 105 }, RightWrist = { 20 },
		LeftShoulder = { 55, 0, -5 }, LeftElbow = { 35 },
		RightHip = { -10, 0, 5 }, LeftHip = { 20, 0, -5 }, LeftKnee = { -20 },
	}),
	Stab = pose({
		Drop = { 0.25 },
		Waist = { -24, 28 }, Neck = { 16, -25 },
		RightShoulder = { 80, 0, -8 }, RightElbow = { 8 }, RightWrist = { 2 },
		LeftShoulder = { -25, 0, -15 }, LeftElbow = { 25 },
		RightHip = { 35, 0, 5 }, RightKnee = { -25 }, LeftHip = { -25, 0, -5 }, LeftKnee = { -10 },
	}),
	-- Sideways sweep: dagger drawn back out to the right, then swept across to the left.
	WindSlash = pose({
		Drop = { 0.22 },
		Waist = { -8, -40 }, Neck = { 8, 32 },
		RightShoulder = { 75, 0, 80 }, RightElbow = { 40 }, RightWrist = { 10 },
		LeftShoulder = { 45, 0, -15 }, LeftElbow = { 40 },
		RightHip = { 10, 0, 8 }, LeftHip = { -5, 0, -8 },
	}),
	Slash = pose({
		Drop = { 0.28 },
		Waist = { -20, 40 }, Neck = { 14, -34 },
		RightShoulder = { 75, 0, -55 }, RightElbow = { 10 }, RightWrist = { 10 },
		LeftShoulder = { -15, 0, -20 }, LeftElbow = { 30 },
		RightHip = { 25, 0, 5 }, RightKnee = { -20 }, LeftHip = { -15, 0, -5 },
	}),
	-- Overhead chop: arm raised high with the dagger cocked behind the head, then
	-- brought straight down in front as the body hunches into it.
	WindChop = pose({
		Drop = { 0.15 },
		Waist = { 10, -12 }, Neck = { 0, 10 },
		RightShoulder = { 165, 0, 15 }, RightElbow = { 80 }, RightWrist = { 20 },
		LeftShoulder = { 60, 0, -20 }, LeftElbow = { 40 },
		RightHip = { -5, 0, 5 }, LeftHip = { 15, 0, -5 },
	}),
	Chop = pose({
		Drop = { 0.35 },
		Waist = { -38, 10 }, Neck = { 25, -8 },
		RightShoulder = { 50, 0, -5 }, RightElbow = { 10 }, RightWrist = { 25 },
		LeftShoulder = { -20, 0, -25 }, LeftElbow = { 30 },
		RightHip = { 30, 0, 5 }, RightKnee = { -20 }, LeftHip = { -15, 0, -5 },
	}),
	Hurt = pose({
		Drop = { 0.15 },
		Waist = { 12, 0, 8 }, Neck = { 18, 0, -10 },
		RightShoulder = { 30, 0, 40 }, RightElbow = { 40 }, RightWrist = { 30 },
		LeftShoulder = { 30, 0, -40 }, LeftElbow = { 40 },
	}),
	-- Topples onto its back: the whole body tips around the hips as they sink to the ground.
	Dead = pose({
		Drop = { 1.25 },
		Hips = { 80 }, Waist = { 10 }, Neck = { 25, 30 },
		RightShoulder = { 20, 0, 60 }, RightElbow = { 30 }, RightWrist = { 20 },
		LeftShoulder = { 20, 0, -60 }, LeftElbow = { 30 },
		RightHip = { 10, 0, 10 }, RightKnee = { -30 }, LeftHip = { 25, 0, -10 }, LeftKnee = { -15 },
	}),
}
POSES.Recover = POSES.Idle

type Joint = {
	set: (CFrame) -> (),
	offset: Vector3,
}

local goblins: { [BasePart]: any } = {}

local function findBone(model: Instance, name: string): Bone?
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Bone") and descendant.Name == name then
			return descendant
		end
	end
	return nil
end

-- Builds a setter for each joint that takes a rotation in body axes.
local function collectJoints(model: Instance, root: BasePart): { [string]: Joint }
	local joints = {}
	for _, name in JOINTS do
		local bone = BONES[name] and findBone(model, BONES[name])
		if bone then
			-- The bone's resting orientation in body space; conjugating by it turns a
			-- body-axis rotation into the same rotation around the bone's own axes.
			local rest = (root.CFrame:ToObjectSpace(bone.WorldCFrame)).Rotation
			local restInverse = rest:Inverse()
			joints[name] = {
				set = function(transform: CFrame)
					bone.Transform = restInverse * transform * rest
				end,
				offset = BONE_OFFSETS[name] or Vector3.zero,
			}
		else
			for _, descendant in model:GetDescendants() do
				if descendant:IsA("Motor6D") and descendant.Name == name then
					local motor = descendant
					joints[name] = {
						set = function(transform: CFrame)
							if motor.Parent then
								motor.Transform = transform
							end
						end,
						offset = Vector3.zero,
					}
					break
				end
			end
		end
	end
	return joints
end

-- A dagger mesh that isn't skinned to the hand gets carried along by it each frame.
local function collectDagger(model: Instance)
	local dagger = model:FindFirstChild("Dagger")
	local joint = dagger and dagger:FindFirstChild("DaggerJoint")
	local hand = BONES.RightWrist and findBone(model, BONES.RightWrist)
	if not (dagger and dagger:IsA("BasePart") and joint and joint:IsA("Motor6D") and hand and joint.Part0) then
		return nil
	end
	return {
		joint = joint,
		hand = hand,
		offset = hand.WorldCFrame:ToObjectSpace(dagger.CFrame), -- where it sits in the hand at rest
	}
end

local function onAdded(root: Instance)
	if not root:IsA("BasePart") then
		return
	end
	local model = root.Parent
	if not model then
		return
	end
	local current = {}
	for _, name in JOINTS do
		current[name] = Vector3.zero
	end
	current.Drop = Vector3.zero
	goblins[root] = {
		joints = collectJoints(model, root),
		dagger = collectDagger(model),
		legLength = model:GetAttribute("LegLength") or DEFAULT_LEG_LENGTH,
		current = current,
		phase = math.random() * 6,
		breath = math.random() * 6,
		exertion = 0,
	}
end

local function onRemoved(root: Instance)
	goblins[root :: BasePart] = nil
end

local function add(target: Pose, name: string, x: number, y: number?, z: number?)
	target[name] = (target[name] or Vector3.zero) + Vector3.new(x, y or 0, z or 0)
end

local function update(dt: number)
	local cameraPosition = camera.CFrame.Position
	local now = workspace:GetServerTimeNow()
	for root, goblin in goblins do
		if (root.Position - cameraPosition).Magnitude > ANIMATE_RANGE then
			continue
		end
		local action = root:GetAttribute("Action") or "Idle"
		local dead = action == "Dead"
		local target: Pose = table.clone(POSES[action] or POSES.Idle)

		if not dead then
			-- Gait: one full cycle every two steps, so the feet keep pace with the ground.
			-- `moving` fades it in from standing; `run` turns a walk into a hunched run.
			local velocity = root.AssemblyLinearVelocity
			local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
			local moving = math.clamp(speed / 3, 0, 1)
			local run = math.clamp(speed / RUN_SPEED, 0, 1)
			if moving > 0 and (action == "Idle" or action == "Recover") then
				goblin.phase += dt * math.pi * speed / STEP_LENGTH
				local s, c = math.sin(goblin.phase), math.cos(goblin.phase)
				local legSwing = (25 + 20 * run) * moving
				local kneeLift = (35 + 35 * run) * moving -- a leg bends as it swings forward
				add(target, "RightHip", s * legSwing)
				add(target, "LeftHip", -s * legSwing)
				add(target, "RightKnee", -math.max(c, 0) * kneeLift - 8 * moving)
				add(target, "LeftKnee", -math.max(-c, 0) * kneeLift - 8 * moving)
				-- Arms swing against the legs; the dagger arm less, and both bend more at a run.
				add(target, "LeftShoulder", s * (20 + 20 * run) * moving)
				add(target, "LeftElbow", 25 * run)
				add(target, "RightShoulder", -s * (10 + 12 * run) * moving)
				add(target, "RightElbow", 20 * run)
				add(target, "Waist", -(6 + 16 * run) * moving, s * 7 * moving, c * 3 * moving)
				add(target, "Neck", (4 + 12 * run) * moving) -- keeps the eyes up while leaning in
				add(target, "Drop", (0.03 + 0.07 * math.abs(c)) * moving * (0.5 + run))
			end

			-- Breathing: running and fighting wind it, and it slowly gets its breath back.
			local fighting = STRIKES[action] or WINDUPS[action]
			goblin.exertion = math.clamp(
				goblin.exertion + dt * ((if fighting then 0.6 else 0) + run * 0.35 - EXERTION_DECAY),
				0, 1)
			local exertion = goblin.exertion
			goblin.breath += dt * (BREATH_RATE_CALM + (BREATH_RATE_WINDED - BREATH_RATE_CALM) * exertion)
			-- Shaped so the inhale is quicker than the exhale, like real breathing.
			local inhale = (math.sin(goblin.breath) + 0.35 * math.sin(goblin.breath * 2)) / 1.2
			local depth = 1 + 0.8 * exertion
			add(target, "Waist", 3 * inhale * depth) -- chest lifts and the back straightens...
			add(target, "Neck", -2 * inhale * depth) -- ...with the head kept level
			add(target, "RightClavicle", 0, 0, 4 * inhale * depth) -- shoulders rise
			add(target, "LeftClavicle", 0, 0, -4 * inhale * depth)
			add(target, "RightShoulder", 0, 0, 2 * inhale * depth) -- arms drift out a little
			add(target, "LeftShoulder", 0, 0, -2 * inhale * depth)
			add(target, "Drop", -0.015 * inhale * depth)
			if exertion > 0.4 then
				add(target, "Waist", -6 * (exertion - 0.4)) -- hunches over when winded
			end

			-- Standing around: shifts its weight slowly from foot to foot and glances about.
			if moving < 0.5 and not fighting then
				local still = 1 - moving * 2
				local sway = math.sin(goblin.breath * 0.23 + goblin.phase)
				add(target, "Hips", 0, 0, 2 * sway * still)
				add(target, "Waist", 0, 0, -2.5 * sway * still)
				add(target, "RightHip", 0, 0, -2 * sway * still)
				add(target, "LeftHip", 0, 0, -2 * sway * still)
				local glance = math.sin(now * 0.37 + goblin.phase) * math.sin(now * 0.61 + goblin.phase * 2)
				add(target, "Neck", 0, 18 * glance * still)
			end

			local flinch = math.max(1 - (now - (root:GetAttribute("HitTime") or 0)) / FLINCH_TIME, 0)
			add(target, "Waist", 14 * flinch)
			add(target, "Neck", 12 * flinch)
		end

		local rate = if STRIKES[action]
			then STRIKE_RATE
			elseif WINDUPS[action] then WIND_RATE
			elseif dead then DEATH_RATE
			else DEFAULT_RATE
		local alpha = 1 - math.exp(-rate * dt)
		local current = goblin.current
		for name, value in current do
			current[name] = value:Lerp(target[name] or Vector3.zero, alpha)
		end

		-- Dropping the hips bends both legs so the feet stay on the ground (not once it's falling over).
		local drop = current.Drop.X
		local bend = if dead then 0 else math.deg(math.acos(math.clamp(1 - drop / goblin.legLength, -1, 1)))
		for name, joint in goblin.joints do
			local r = current[name] + joint.offset
			if name == "RightHip" or name == "LeftHip" then
				r += Vector3.new(bend, 0, 0)
			elseif name == "RightKnee" or name == "LeftKnee" then
				r -= Vector3.new(bend * 2, 0, 0)
			end
			local rotation = CFrame.Angles(math.rad(r.X), math.rad(r.Y), math.rad(r.Z))
			joint.set(if name == "Hips" then CFrame.new(0, -drop, 0) * rotation else rotation)
		end

		local dagger = goblin.dagger
		if dagger and dagger.joint.Parent and dagger.joint.Part0 then
			-- Part1 = Part0 * C0 * Transform * C1:Inverse(), solved for Transform.
			local joint = dagger.joint
			local goal = dagger.hand.TransformedWorldCFrame * dagger.offset
			joint.Transform = joint.C0:Inverse() * joint.Part0.CFrame:ToObjectSpace(goal) * joint.C1
		end
	end
end

function GoblinVisuals.start()
	for _, root in CollectionService:GetTagged("GoblinRoot") do
		onAdded(root)
	end
	CollectionService:GetInstanceAddedSignal("GoblinRoot"):Connect(onAdded)
	CollectionService:GetInstanceRemovedSignal("GoblinRoot"):Connect(onRemoved)
	-- Joints are posed before physics each frame, the same point Roblox's own Animator uses.
	RunService.PreSimulation:Connect(update)
end

return GoblinVisuals
