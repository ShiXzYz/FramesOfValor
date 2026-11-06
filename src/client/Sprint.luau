-- Hold Left Shift to sprint, spending stamina.
--
-- Stamina drains only while actually moving at a sprint and refills shortly after
-- stopping. Running it dry leaves the player winded: no sprinting until it has
-- refilled partway. Sprinting isn't possible with the sword readied, mid-slash or
-- guarding. This owns the character's walk speed, except during a slash, when the
-- sword controller takes it over for the step into the strike.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local WALK_SPEED = 16
local SPRINT_SPEED = 25
local MAX_STAMINA = 100
local DRAIN_PER_SECOND = 20 -- five seconds of sprinting from full
local REGEN_PER_SECOND = 18
local REGEN_DELAY = 0.8 -- after sprinting stops, before stamina starts refilling
local WINDED_UNTIL = 35 -- after running dry, sprinting comes back once stamina reaches this
local BASE_FOV = 70
local SPRINT_FOV = 78
local FOV_RATE = 8

local Sprint = {}

local stamina = MAX_STAMINA
local winded = false
local sprinting = false
local lastSprint = 0

function Sprint.stamina(): number
	return stamina / MAX_STAMINA
end

function Sprint.isSprinting(): boolean
	return sprinting
end

function Sprint.isWinded(): boolean
	return winded
end

function Sprint.start(swordController)
	RunService.RenderStepped:Connect(function(dt)
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then
			sprinting = false
			stamina = MAX_STAMINA
			winded = false
			return
		end

		local wantsSprint = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		local fighting = swordController.isSwinging() or swordController.isGuarding()
		local moving = humanoid.MoveDirection.Magnitude > 0.1
		sprinting = wantsSprint and moving and not fighting and not winded and stamina > 0

		if sprinting then
			stamina = math.max(stamina - DRAIN_PER_SECOND * dt, 0)
			lastSprint = os.clock()
			if stamina == 0 then
				winded = true
			end
		elseif os.clock() - lastSprint > REGEN_DELAY then
			stamina = math.min(stamina + REGEN_PER_SECOND * dt, MAX_STAMINA)
			if winded and stamina >= WINDED_UNTIL then
				winded = false
			end
		end

		if not swordController.isSlashing() then
			humanoid.WalkSpeed = if sprinting then SPRINT_SPEED else WALK_SPEED
		end
		local fovGoal = if sprinting then SPRINT_FOV else BASE_FOV
		camera.FieldOfView += (fovGoal - camera.FieldOfView) * (1 - math.exp(-FOV_RATE * dt))
	end)
end

return Sprint
