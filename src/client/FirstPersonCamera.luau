-- Custom first-person camera.
-- We drive the camera ourselves (Scriptable) instead of using Roblox's default
-- first-person mode so the sword controller can "steal" mouse movement while
-- the player is holding left click.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local LOOK_SENSITIVITY = math.rad(0.4) -- radians per mouse pixel
local MAX_PITCH = math.rad(80)
local EYE_OFFSET = Vector3.new(0, 0.25, 0)
local SHAKE_DECAY = 4 -- shake units lost per second
local SHAKE_STRENGTH = 0.05 -- radians at full shake

local FirstPersonCamera = {}

local yaw = 0
local pitch = 0
local shake = 0
local roll = 0
local inputSink: ((Vector2) -> Vector2)? = nil
-- Parts/decals of our own character, hidden locally so they don't block the view.
local hideable: { BasePart | Decal } = {}

local function trackHideable(instance: Instance)
	if instance:IsA("BasePart") or instance:IsA("Decal") then
		table.insert(hideable, instance)
	end
end

local function onCharacterAdded(character: Model)
	hideable = {}
	for _, descendant in character:GetDescendants() do
		trackHideable(descendant)
	end
	character.DescendantAdded:Connect(trackHideable)

	local root = character:WaitForChild("HumanoidRootPart") :: BasePart
	local _, rootYaw = root.CFrame:ToOrientation()
	yaw = rootYaw
	pitch = 0
end

local function update(dt: number)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local head = character and character:FindFirstChild("Head") :: BasePart?
	if not (humanoid and root and head) then
		return
	end

	camera.CameraType = Enum.CameraType.Scriptable
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false
	humanoid.AutoRotate = false

	-- Give the sword first pick of the mouse movement; whatever it doesn't use turns the camera.
	local delta = UserInputService:GetMouseDelta()
	if inputSink then
		delta = inputSink(delta)
	end
	yaw -= delta.X * LOOK_SENSITIVITY
	pitch = math.clamp(pitch - delta.Y * LOOK_SENSITIVITY, -MAX_PITCH, MAX_PITCH)

	local facing = CFrame.Angles(0, yaw, 0)
	if humanoid.Health > 0 then
		root.CFrame = CFrame.new(root.Position) * facing
	end

	shake = math.max(shake - SHAKE_DECAY * dt, 0)
	local s = shake * shake * SHAKE_STRENGTH
	local shakeOffset =
		CFrame.Angles((math.random() - 0.5) * s, (math.random() - 0.5) * s, (math.random() - 0.5) * s)

	camera.CFrame = CFrame.new(head.Position + EYE_OFFSET) * facing * CFrame.Angles(pitch, 0, roll) * shakeOffset
	camera.Focus = camera.CFrame

	for _, instance in hideable do
		instance.LocalTransparencyModifier = 1
	end
end

-- `sink` receives the frame's mouse delta (pixels) and returns the part it didn't consume.
function FirstPersonCamera.setInputSink(sink: ((Vector2) -> Vector2)?)
	inputSink = sink
end

-- Turns the view right by `right` radians and up by `up` radians (negative = left/down).
function FirstPersonCamera.turn(right: number, up: number)
	yaw -= right
	pitch = math.clamp(pitch + up, -MAX_PITCH, MAX_PITCH)
end

-- Tilts the view sideways (radians), e.g. to lean into a swing.
function FirstPersonCamera.setRoll(radians: number)
	roll = radians
end

-- Adds screen shake; `amount` is roughly 0..1.
function FirstPersonCamera.shake(amount: number)
	shake = math.min(shake + amount, 1)
end

function FirstPersonCamera.start()
	player.CharacterAdded:Connect(onCharacterAdded)
	if player.Character then
		task.spawn(onCharacterAdded, player.Character)
	end
	RunService:BindToRenderStep("KnightCamera", Enum.RenderPriority.Camera.Value + 1, update)
end

return FirstPersonCamera
