-- Cursor-guided sword swinging with momentum.
--
-- Hold left click to "grab" the sword: the camera locks and the mouse moves an
-- invisible on-screen cursor. The blade tip is pulled toward the cursor by a
-- spring, so slow drags are precise while fast drags build momentum and
-- overshoot a little, like a heavy blade would. The cursor can't leave the
-- screen, so swinging never jerks the camera; holding it near any screen edge
-- slowly pans the view that way for wide, spinning, overhead or low slashes.
-- Release to drift back to guard.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

local SwordConfig = require(ReplicatedStorage.Shared.SwordConfig)
local SwordModel = require(script.Parent.SwordModel)

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local swordHitRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("SwordHit") :: RemoteEvent

-- Aim is (right, up) angles in radians of the blade direction, relative to the camera.
local GUARD_AIM = Vector2.new(math.rad(25), math.rad(50))
local AIM_MIN = Vector2.new(math.rad(-85), math.rad(-70))
local AIM_MAX = Vector2.new(math.rad(85), math.rad(85))

-- Swing feel
local CURSOR_SENSITIVITY = 1 -- 1 = sword cursor moves exactly like a normal mouse cursor
local CURSOR_LIMIT = 0.92 -- how close to the screen edge the cursor may go (1 = edge)
local SWING_STIFFNESS = 240 -- how hard the blade is pulled toward the cursor
local SWING_DAMPING = 0.65 -- below 1 = fast drags overshoot (momentum); 1 = no overshoot
local RETURN_STIFFNESS = 50 -- pull back to guard after releasing
local RETURN_DAMPING = 1
local MAX_ANGULAR_SPEED = 16 -- radians/second cap; lower = heavier sword
local VERTICAL_SPEED_MULTIPLIER = 1.6 -- up/down swings respond this much faster and can go this much faster
local MAX_SUBSTEP = 1 / 120 -- keeps the spring stable at low frame rates
local EDGE_TURN_RATE = 14 -- how quickly the edge rotates to face the swing direction
local IMPACT_SLOWDOWN = 0.3 -- fraction of blade speed kept after biting into something

-- Holding the cursor near a screen edge slowly turns the camera that way.
local EDGE_PAN_ENABLED = true
local EDGE_PAN_START = 0.85 -- fraction of the cursor limit where panning begins
local EDGE_PAN_SPEED = math.rad(150) -- radians/second at the very edge

-- Camera-space anchor points (studs). +X right, +Y up, -Z forward.
local SHOULDER = Vector3.new(0.45, -1.5, -0.1) -- the hand orbits this point
local RIGHT_ARM_ROOT = Vector3.new(1.1, -2.2, 0.6) -- forearms are drawn from these to the hands
local LEFT_ARM_ROOT = Vector3.new(-0.7, -2.3, 0.5)
local HAND_DISTANCE = 1.3

-- Procedural animation
local WRIST_LEAD = 0.07 -- seconds of swing the hands lead the blade by
local MAX_WRIST_LEAD = math.rad(25)
local ARM_RETRACT = -0.15 -- hand distance change at rest (pulled in)...
local ARM_EXTEND = 0.35 -- ...and at full swing speed (reaching out)
local REACH_RATE = 10
local TRAIL_SPEED = 7 -- radians/second of blade speed before the swoosh trail shows
local LEAN_PER_SPEED = 0.006 -- camera roll (radians) per radian/second of sideways swing
local MAX_LEAN = math.rad(4)
local LEAN_RATE = 8
local BREATH_RATE = 1.6 -- guard-pose bob speed
local BREATH_AMOUNT = math.rad(1.5)
local TIP_DISTANCE = HAND_DISTANCE + SwordModel.BladeEnd -- shoulder to blade tip

local SAMPLE_COUNT = 7 -- points along the blade that sweep for hits
local WHOOSH_SPEED = 45
local WHOOSH_COOLDOWN = 0.35

local SwordController = {}

local sword = SwordModel.new()
local aim = GUARD_AIM
local aimVelocity = Vector2.zero
local dir = Vector3.zAxis
local edge = Vector3.xAxis
local reach = 0 -- 0 = arms pulled in, 1 = fully extended
local lean = 0
local swinging = false
-- Sword cursor, measured from screen center in units of half the screen height, +Y up.
local cursor = Vector2.zero
local prevSamples: { Vector3 }? = nil
local lastHitTimes: { [Instance]: number } = {}
local lastWhoosh = 0
local dummiesFolder: Instance
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Include

local function newSound(id: string, volume: number): Sound
	local sound = Instance.new("Sound")
	sound.SoundId = id
	sound.Volume = volume
	sound.Parent = SoundService
	return sound
end

local whooshSound = newSound("rbxasset://sounds/swordslash.wav", 0.6)
local hitSound = newSound("rbxasset://sounds/swordlunge.wav", 0.9)

local function aimToDirection(a: Vector2): Vector3
	local cosUp = math.cos(a.Y)
	return Vector3.new(math.sin(a.X) * cosUp, math.sin(a.Y), -math.cos(a.X) * cosUp)
end

local function directionToAim(d: Vector3): Vector2
	return Vector2.new(math.atan2(d.X, -d.Z), math.asin(math.clamp(d.Y, -1, 1)))
end

-- `v` with its component along `d` removed, normalized; nil if that leaves nothing.
local function perpendicular(v: Vector3, d: Vector3): Vector3?
	local p = v - d * v:Dot(d)
	return if p.Magnitude > 1e-4 then p.Unit else nil
end

local function tanHalfFov(): number
	return math.tan(math.rad(camera.FieldOfView) / 2)
end

local function cursorRadii(): Vector2
	local viewport = camera.ViewportSize
	return Vector2.new(viewport.X / viewport.Y, 1) * CURSOR_LIMIT
end

-- How far out the cursor is, where 1 = on the boundary ellipse.
local function cursorReach(c: Vector2): number
	return (c / cursorRadii()).Magnitude
end

local function clampCursor(c: Vector2): Vector2
	local reach = cursorReach(c)
	return if reach > 1 then c / reach else c
end

-- Blade direction (camera space) that puts the tip exactly under the cursor.
local function cursorToDirection(c: Vector2): Vector3
	local tanHalf = tanHalfFov()
	local ray = Vector3.new(c.X * tanHalf, c.Y * tanHalf, -1).Unit
	-- Solve |ray * t - SHOULDER| = TIP_DISTANCE for the far intersection.
	local b = ray:Dot(SHOULDER)
	local t = b + math.sqrt(b * b - SHOULDER:Dot(SHOULDER) + TIP_DISTANCE * TIP_DISTANCE)
	return (ray * t - SHOULDER).Unit
end

-- Where on screen (cursor units) the blade tip currently is, kept inside the
-- edge-pan zone so grabbing the sword from guard doesn't start turning the camera.
local function tipToCursor(d: Vector3): Vector2
	local tip = SHOULDER + d * TIP_DISTANCE
	local c = if tip.Z > -0.5
		then Vector2.new(tip.X, tip.Y) * 100
		else Vector2.new(tip.X, tip.Y) / (-tip.Z * tanHalfFov())
	local maxReach = EDGE_PAN_START * 0.9
	local reach = cursorReach(c)
	return if reach > maxReach then c * (maxReach / reach) else c
end

local function findDummy(instance: Instance): Instance?
	local current = instance
	while current.Parent and current.Parent ~= dummiesFolder do
		current = current.Parent
	end
	return if current.Parent == dummiesFolder then current else nil
end

-- Called by the camera with this frame's mouse delta; returns whatever the sword didn't use.
local function consumeMouse(delta: Vector2): Vector2
	if not swinging then
		return delta
	end
	local halfHeight = camera.ViewportSize.Y / 2
	cursor = clampCursor(cursor + Vector2.new(delta.X, -delta.Y) / halfHeight * CURSOR_SENSITIVITY)
	return Vector2.zero
end

local function stepSpring(target: Vector2, stiffness: number, dampingRatio: number, dt: number)
	-- The vertical axis gets a proportionally stiffer spring (same damping ratio)
	-- and a higher speed cap, so up/down swings are snappier than side to side.
	local axisScale = Vector2.new(1, VERTICAL_SPEED_MULTIPLIER)
	local axisStiffness = axisScale * axisScale * stiffness
	local axisDamping = axisScale * (2 * dampingRatio * math.sqrt(stiffness))
	local remaining = dt
	while remaining > 0 do
		local h = math.min(remaining, MAX_SUBSTEP)
		remaining -= h
		aimVelocity += ((target - aim) * axisStiffness - aimVelocity * axisDamping) * h
		local scaledSpeed = (aimVelocity / axisScale).Magnitude
		if scaledSpeed > MAX_ANGULAR_SPEED then
			aimVelocity *= MAX_ANGULAR_SPEED / scaledSpeed
		end
		aim += aimVelocity * h
	end

	local clamped = aim:Max(AIM_MIN):Min(AIM_MAX)
	if clamped ~= aim then
		aimVelocity = Vector2.new(
			if clamped.X ~= aim.X then 0 else aimVelocity.X,
			if clamped.Y ~= aim.Y then 0 else aimVelocity.Y
		)
		aim = clamped
	end
end

local function onHit(dummy: Instance, position: Vector3, speed: number)
	lastHitTimes[dummy] = os.clock()
	swordHitRemote:FireServer(dummy, position, speed)

	local strength = math.clamp(SwordConfig.damageForSpeed(speed) / SwordConfig.MaxDamage, 0, 1)
	hitSound.PlaybackSpeed = 1.15 - strength * 0.3
	hitSound:Play()
	SwordController.camera.shake(0.25 + strength * 0.5)

	-- The blade bites in and loses most of its momentum.
	aimVelocity *= IMPACT_SLOWDOWN
end

local function detectHits(samples: { Vector3 }, dt: number, rootVelocity: Vector3)
	if not prevSamples then
		return
	end

	local tipSpeed = ((samples[SAMPLE_COUNT] - prevSamples[SAMPLE_COUNT]) / dt - rootVelocity).Magnitude
	local now = os.clock()
	if tipSpeed >= WHOOSH_SPEED and now - lastWhoosh > WHOOSH_COOLDOWN then
		lastWhoosh = now
		whooshSound.PlaybackSpeed = 0.9 + math.random() * 0.2
		whooshSound:Play()
	end

	-- Sweep each blade sample from where it was last frame to where it is now,
	-- so fast swings can't skip through the target between frames.
	for i = 1, SAMPLE_COUNT do
		local from, to = prevSamples[i], samples[i]
		local speed = ((to - from) / dt - rootVelocity).Magnitude
		if speed >= SwordConfig.MinHitSpeed then
			local result = workspace:Raycast(from, to - from, rayParams)
			local dummy = result and findDummy(result.Instance)
			if dummy and now - (lastHitTimes[dummy] or 0) >= SwordConfig.HitCooldown then
				onHit(dummy, result.Position, speed)
				return
			end
		end
	end
end

local function update(dt: number)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not (humanoid and root and humanoid.Health > 0) then
		sword.model.Parent = nil
		prevSamples = nil
		return
	end
	sword.model.Parent = camera

	if swinging then
		if EDGE_PAN_ENABLED then
			local reach = cursorReach(cursor)
			if reach > EDGE_PAN_START then
				local push = (reach - EDGE_PAN_START) / (1 - EDGE_PAN_START)
				local pan = (cursor / cursorRadii()) * push * EDGE_PAN_SPEED * dt
				SwordController.camera.turn(pan.X, pan.Y)
			end
		end
		local target = directionToAim(cursorToDirection(cursor)):Max(AIM_MIN):Min(AIM_MAX)
		stepSpring(target, SWING_STIFFNESS, SWING_DAMPING, dt)
	else
		local breathing = Vector2.new(0, math.sin(os.clock() * BREATH_RATE) * BREATH_AMOUNT)
		stepSpring(GUARD_AIM + breathing, RETURN_STIFFNESS, RETURN_DAMPING, dt)
	end

	local prevDir = dir
	dir = aimToDirection(aim)

	-- Turn the edge toward the direction of travel. The sword is double-edged,
	-- so pick whichever edge is closer to avoid spinning it around.
	local motion = dir - prevDir
	local edgeGoal = (if motion.Magnitude > 2e-3 then perpendicular(motion, dir) else nil)
		or perpendicular(Vector3.xAxis, dir)
		or edge
	if edgeGoal:Dot(edge) < 0 then
		edgeGoal = -edgeGoal
	end
	edge = perpendicular(edge:Lerp(edgeGoal, 1 - math.exp(-EDGE_TURN_RATE * dt)), dir) or edgeGoal

	-- Procedural animation: the hands lead the swing and the blade trails behind
	-- (wrist lag), the arms reach out as the swing speeds up, and the body leans into it.
	local speed01 = math.clamp(aimVelocity.Magnitude / MAX_ANGULAR_SPEED, 0, 1)
	local lead = aimVelocity * WRIST_LEAD
	if lead.Magnitude > MAX_WRIST_LEAD then
		lead = lead.Unit * MAX_WRIST_LEAD
	end
	local handDir = aimToDirection(aim + lead)
	reach += (speed01 - reach) * (1 - math.exp(-REACH_RATE * dt))
	local handDistance = HAND_DISTANCE + ARM_RETRACT + (ARM_EXTEND - ARM_RETRACT) * reach

	local localHand = CFrame.fromMatrix(SHOULDER + handDir * handDistance, edge, (-dir):Cross(edge))
	local handCFrame = camera.CFrame * localHand
	sword:update(handCFrame, camera.CFrame * RIGHT_ARM_ROOT, camera.CFrame * LEFT_ARM_ROOT)
	sword:setTrailEnabled(aimVelocity.Magnitude > TRAIL_SPEED)

	local rollGoal = math.clamp(-aimVelocity.X * LEAN_PER_SPEED, -MAX_LEAN, MAX_LEAN)
	lean += (rollGoal - lean) * (1 - math.exp(-LEAN_RATE * dt))
	SwordController.camera.setRoll(lean)

	local samples = table.create(SAMPLE_COUNT)
	for i = 1, SAMPLE_COUNT do
		local distance = SwordModel.BladeStart
			+ (SwordModel.BladeEnd - SwordModel.BladeStart) * (i - 1) / (SAMPLE_COUNT - 1)
		samples[i] = handCFrame * Vector3.new(0, 0, -distance)
	end
	detectHits(samples, dt, root.AssemblyLinearVelocity)
	prevSamples = samples
end

function SwordController.isSwinging(): boolean
	return swinging
end

function SwordController.start(firstPersonCamera)
	SwordController.camera = firstPersonCamera
	dummiesFolder = workspace:WaitForChild("Dummies")
	rayParams.FilterDescendantsInstances = { dummiesFolder }

	firstPersonCamera.setInputSink(consumeMouse)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not gameProcessed and input.UserInputType == Enum.UserInputType.MouseButton1 then
			-- Start the cursor where the tip already is (or as close as the screen allows).
			cursor = tipToCursor(dir)
			swinging = true
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			swinging = false
		end
	end)

	RunService:BindToRenderStep("KnightSword", Enum.RenderPriority.Camera.Value + 2, update)
end

return SwordController
