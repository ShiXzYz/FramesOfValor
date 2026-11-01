-- Caps Lock toggles a soft camera lock on the closest monster: the view is nudged
-- toward it, but aiming and landing the hit are still up to the player. The lock holds
-- that monster until it dies or gets away, then moves to the next closest one in range.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local LOCK_RANGE = 100 -- studs; monsters further than this can't be picked
local BREAK_RANGE = 130 -- studs; a locked monster further than this is dropped

local LockOn = {}

local target: BasePart? = nil
local firstPersonCamera

local function getLiveRoot(): BasePart?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	return if humanoid and root and humanoid.Health > 0 then root else nil
end

local function findClosest(origin: Vector3): BasePart?
	local closest, closestDistance = nil, LOCK_RANGE
	for _, core in CollectionService:GetTagged("SlimeCore") do
		local distance = (core.Position - origin).Magnitude
		if distance < closestDistance and core:IsDescendantOf(workspace) then
			closest, closestDistance = core, distance
		end
	end
	return closest
end

local function setTarget(newTarget: BasePart?)
	target = newTarget
	firstPersonCamera.setLockTarget(newTarget)
end

local function update()
	if not target then
		return
	end
	local root = getLiveRoot()
	if not root then
		setTarget(nil)
	elseif not target:IsDescendantOf(workspace) or (target.Position - root.Position).Magnitude > BREAK_RANGE then
		setTarget(findClosest(root.Position))
	end
end

function LockOn.isLocked(): boolean
	return target ~= nil
end

function LockOn.start(camera)
	firstPersonCamera = camera

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed or input.KeyCode ~= Enum.KeyCode.CapsLock then
			return
		end
		local root = getLiveRoot()
		setTarget(if not target and root then findClosest(root.Position) else nil)
	end)

	RunService:BindToRenderStep("KnightLockOn", Enum.RenderPriority.Camera.Value, update)
end

return LockOn
