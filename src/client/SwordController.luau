-- Directional sword slashes with momentum.
--
-- Hold left click to ready the sword (the camera locks), then flick the mouse.
-- The flick's direction picks the slash: the blade winds up on the opposite side
-- and sweeps through the centre of the screen that way. Faster flicks give
-- faster slashes. Keep holding and flick again to chain, but each slash is
-- followed by a short cooldown and can't go the same way as the one before it.
-- Release to drift back to guard: the camera stays locked until any slash has
-- finished, then eases back in so the end of a flick doesn't throw the view around.

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

-- Blade spring
local RETURN_STIFFNESS = 50 -- pull back to guard / ready pose
local RETURN_DAMPING = 1
local STRIKE_STIFFNESS = 420 -- how hard the blade follows the slash path
local STRIKE_DAMPING = 0.75 -- below 1 = a little overshoot at the end (momentum)
local MAX_ANGULAR_SPEED = 16 -- radians/second cap; lower = heavier sword
local VERTICAL_SPEED_MULTIPLIER = 1.6 -- up/down swings respond this much faster and can go this much faster
local MAX_SUBSTEP = 1 / 120 -- keeps the spring stable at low frame rates
local EDGE_TURN_RATE = 14 -- how quickly the edge rotates to face the swing direction
local IMPACT_SLOWDOWN = 0.3 -- fraction of blade speed kept after biting into something

-- Slashes
local MOUSE_SENSITIVITY = 1
local GESTURE_THRESHOLD = 0.07 -- flick distance (half screen heights) that triggers a slash
local GESTURE_DECAY = 8 -- per second; slow drifting fades out instead of triggering
local SWING_CENTER = Vector2.new(math.rad(5), math.rad(8)) -- slashes pass through here
local SWING_HALF_ARC = Vector2.new(math.rad(75), math.rad(62)) -- half-length of a slash, side / up-down
local WINDUP_TIME = 0.09 -- seconds to pull back before the strike (less if already close)
local STRIKE_TIME_FAST = 0.16 -- strike duration for a fast flick...
local STRIKE_TIME_SLOW = 0.3 -- ...and for a slow one
local FLICK_SPEED_FAST = 6 -- flick speed (half screen heights/second) counted as "fast"
local FOLLOW_THROUGH_TIME = 0.12 -- hold at the end of the slash
local SLASH_COOLDOWN = 0.25 -- seconds after a slash ends before another can start
local SAME_DIRECTION_ANGLE = math.rad(45) -- flicks within this angle of the last slash are ignored
local DIRECTION_MEMORY = 1.0 -- seconds without slashing before the same direction is allowed again
local LOOK_SETTLE_TIME = 0.2 -- seconds for mouse look to fade back in after the camera lock ends
local LUNGE_SPEED = 16 -- studs/second of the step taken at the start of a strike, along the held WASD direction
local LUNGE_TIME = 0.22 -- seconds for that step to fade to a stop

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
local MAX_LEAN = math.rad(2)
local LEAN_RATE = 8
local BREATH_RATE = 1.6 -- guard-pose bob speed
local BREATH_AMOUNT = math.rad(1.5)

local SAMPLE_COUNT = 7 -- points along the blade that sweep for hits

local SwordController = {}

type Slash = { direction: Vector2, from: Vector2, to: Vector2, windup: number, strike: number, t: number }

local sword = SwordModel.new()
local aim = GUARD_AIM
local aimVelocity = Vector2.zero
local dir = Vector3.zAxis
local edge = Vector3.xAxis
local reach = 0 -- 0 = arms pulled in, 1 = fully extended
local lean = 0
local readied = false -- left click held
local gesture = Vector2.zero -- recent mouse movement while readied, screen space (+Y up)
local gestureTime = 0
local slash: Slash? = nil
local cooldownUntil = 0
local lastCameraLock = 0 -- when the sword last held the camera still
local baseWalkSpeed: number? = nil -- the humanoid's normal speed, saved while a slash overrides it
local lastDirection: Vector2? = nil
local lastSlashEnd = 0
local prevSamples: { Vector3 }? = nil
local prevLocalSamples: { Vector3 }? = nil
local lastHitTimes: { [Instance]: number } = {}
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

local hitSound = newSound("rbxasset://sounds/swordlunge.wav", 0.9)

local function aimToDirection(a: Vector2): Vector3
	local cosUp = math.cos(a.Y)
	return Vector3.new(math.sin(a.X) * cosUp, math.sin(a.Y), -math.cos(a.X) * cosUp)
end

-- `v` with its component along `d` removed, normalized; nil if that leaves nothing.
local function perpendicular(v: Vector3, d: Vector3): Vector3?
	local p = v - d * v:Dot(d)
	return if p.Magnitude > 1e-4 then p.Unit else nil
end

local function findDummy(instance: Instance): Instance?
	local current = instance
	while current.Parent and current.Parent ~= dummiesFolder do
		current = current.Parent
	end
	return if current.Parent == dummiesFolder then current else nil
end

local function resetGesture()
	gesture = Vector2.zero
	gestureTime = 0
end

-- Called by the camera with this frame's mouse delta; returns whatever the sword didn't use.
local function consumeMouse(delta: Vector2): Vector2
	-- Only build up a flick while a new slash is allowed, so input during a
	-- slash or its cooldown can't queue one up.
	if readied and not slash and os.clock() >= cooldownUntil then
		gesture += Vector2.new(delta.X, -delta.Y) / (camera.ViewportSize.Y / 2) * MOUSE_SENSITIVITY
	end
	if readied or slash then
		lastCameraLock = os.clock()
		return Vector2.zero
	end
	-- Just unlocked: the hand is probably still finishing the flick, so fade mouse look back in.
	local settle = math.clamp((os.clock() - lastCameraLock) / LOOK_SETTLE_TIME, 0, 1)
	return delta * settle * settle
end

local function isRepeatDirection(direction: Vector2): boolean
	if not lastDirection or os.clock() - lastSlashEnd > DIRECTION_MEMORY then
		return false
	end
	return direction:Dot(lastDirection) > math.cos(SAME_DIRECTION_ANGLE)
end

-- Starts a slash along `direction` (screen space, +Y up): wind up on the
-- opposite side of SWING_CENTER, then sweep through it to the far side.
local function startSlash(direction: Vector2, flickSpeed: number)
	-- Scale the unit direction onto the arc ellipse so diagonals aren't longer.
	local radius = 1 / (direction / SWING_HALF_ARC).Magnitude
	local half = direction * radius
	local from = (SWING_CENTER - half):Max(AIM_MIN):Min(AIM_MAX)
	local to = (SWING_CENTER + half):Max(AIM_MIN):Min(AIM_MAX)

	-- Skip most of the wind-up when the blade is already near the start (e.g. chaining).
	local windupDistance = (from - aim).Magnitude / (2 * radius)
	local fast = math.clamp(flickSpeed / FLICK_SPEED_FAST, 0, 1)
	slash = {
		direction = direction,
		from = from,
		to = to,
		windup = WINDUP_TIME * math.clamp(windupDistance, 0.25, 1),
		strike = STRIKE_TIME_SLOW + (STRIKE_TIME_FAST - STRIKE_TIME_SLOW) * fast,
		t = 0,
	}
end

-- Advances the slash in progress and returns where the blade should aim this frame.
local function stepSlash(current: Slash, dt: number): Vector2?
	current.t += dt
	local t = current.t
	if t < current.windup then
		return current.from
	end
	t -= current.windup
	if t < current.strike then
		-- Ease in-out so the blade accelerates through the middle of the arc.
		local alpha = t / current.strike
		alpha = alpha * alpha * (3 - 2 * alpha)
		return current.from:Lerp(current.to, alpha)
	end
	if t < current.strike + FOLLOW_THROUGH_TIME then
		return current.to
	end
	return nil
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

-- `samples` are world positions along the blade; `localSamples` are the same points
-- in camera space, so speeds count only the swing, not turning or running.
local function detectHits(samples: { Vector3 }, localSamples: { Vector3 }, dt: number)
	if not prevSamples or not prevLocalSamples then
		return
	end

	-- Only the strike itself can hit: not the wind-up, and not a sword just being carried.
	if not slash or slash.t < slash.windup then
		return
	end

	-- Sweep each blade sample from where it was last frame to where it is now,
	-- so fast swings can't skip through the target between frames.
	local now = os.clock()
	for i = 1, SAMPLE_COUNT do
		local from, to = prevSamples[i], samples[i]
		local speed = (localSamples[i] - prevLocalSamples[i]).Magnitude / dt
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

local function updateSlash(dt: number)
	if readied and not slash and os.clock() >= cooldownUntil then
		gesture *= math.exp(-GESTURE_DECAY * dt)
		gestureTime += dt
		if gesture.Magnitude >= GESTURE_THRESHOLD then
			local direction = gesture.Unit
			if not isRepeatDirection(direction) then
				startSlash(direction, gesture.Magnitude / math.max(gestureTime, 1 / 60))
			end
			resetGesture()
		end
	end

	-- A slash that has started always finishes, even if the button is released.
	local target = slash and stepSlash(slash, dt)
	if slash and not target then
		lastDirection = slash.direction
		lastSlashEnd = os.clock()
		cooldownUntil = lastSlashEnd + SLASH_COOLDOWN
		slash = nil
		resetGesture()
	end

	if target then
		stepSpring(target, STRIKE_STIFFNESS, STRIKE_DAMPING, dt)
	elseif readied then
		-- Readied but not slashing: hold the blade up in front, ready to go any way.
		stepSpring(SWING_CENTER, RETURN_STIFFNESS, RETURN_DAMPING, dt)
	else
		local breathing = Vector2.new(0, math.sin(os.clock() * BREATH_RATE) * BREATH_AMOUNT)
		stepSpring(GUARD_AIM + breathing, RETURN_STIFFNESS, RETURN_DAMPING, dt)
	end
end

-- A slash plants the feet, apart from a short step into the strike. Walk speed is
-- all that changes, so the step follows the held WASD keys and none means no step.
local function updateMovement(humanoid: Humanoid)
	if slash then
		baseWalkSpeed = baseWalkSpeed or humanoid.WalkSpeed
		local t = slash.t - slash.windup
		humanoid.WalkSpeed = if t >= 0 and t < LUNGE_TIME then LUNGE_SPEED * (1 - t / LUNGE_TIME) else 0
	elseif baseWalkSpeed then
		humanoid.WalkSpeed = baseWalkSpeed
		baseWalkSpeed = nil
	end
end

local function update(dt: number)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not (humanoid and root and humanoid.Health > 0) then
		sword.model.Parent = nil
		prevSamples = nil
		slash = nil
		baseWalkSpeed = nil -- the next character starts with its own speed
		SwordController.camera.setLockPaused(false)
		return
	end
	sword.model.Parent = camera

	updateSlash(dt)
	updateMovement(humanoid)
	SwordController.camera.setLockPaused(slash ~= nil)

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
	local localSamples = table.create(SAMPLE_COUNT)
	for i = 1, SAMPLE_COUNT do
		local distance = SwordModel.BladeStart
			+ (SwordModel.BladeEnd - SwordModel.BladeStart) * (i - 1) / (SAMPLE_COUNT - 1)
		local point = Vector3.new(0, 0, -distance)
		samples[i] = handCFrame * point
		localSamples[i] = localHand * point
	end
	detectHits(samples, localSamples, dt)
	prevSamples = samples
	prevLocalSamples = localSamples
end

function SwordController.isSwinging(): boolean
	return readied or slash ~= nil
end

function SwordController.start(firstPersonCamera)
	SwordController.camera = firstPersonCamera
	dummiesFolder = workspace:WaitForChild("Dummies")
	rayParams.FilterDescendantsInstances = { dummiesFolder }

	firstPersonCamera.setInputSink(consumeMouse)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not gameProcessed and input.UserInputType == Enum.UserInputType.MouseButton1 then
			resetGesture()
			readied = true
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			readied = false
		end
	end)

	RunService:BindToRenderStep("KnightSword", Enum.RenderPriority.Camera.Value + 2, update)
end

return SwordController
