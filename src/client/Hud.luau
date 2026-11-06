-- Minimal HUD: a crosshair that dims while swinging and turns red while locked on, and a controls hint.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Hud = {}

function Hud.start(swordController, lockOn, sprint)
	local gui = Instance.new("ScreenGui")
	gui.Name = "KnightHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true

	local crosshair = Instance.new("Frame")
	crosshair.AnchorPoint = Vector2.new(0.5, 0.5)
	crosshair.Position = UDim2.fromScale(0.5, 0.5)
	crosshair.Size = UDim2.fromOffset(6, 6)
	crosshair.BackgroundColor3 = Color3.new(1, 1, 1)
	crosshair.BackgroundTransparency = 0.2
	crosshair.BorderSizePixel = 0
	Instance.new("UICorner", crosshair).CornerRadius = UDim.new(1, 0)
	crosshair.Parent = gui

	local hint = Instance.new("TextLabel")
	hint.AnchorPoint = Vector2.new(0.5, 1)
	hint.Position = UDim2.new(0.5, 0, 1, -24)
	hint.Size = UDim2.fromOffset(1600, 24)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.GothamMedium
	hint.TextSize = 16
	hint.TextColor3 = Color3.new(1, 1, 1)
	hint.TextStrokeTransparency = 0.5
	hint.Text = "Hold Left Click + flick the mouse to slash that way  •  Alternate directions to chain  •  Hold Right Click to guard, move the mouse to angle it across the attack (raise it just as the hit lands to parry)  •  Shift to sprint  •  Caps Lock to lock on"
	hint.Parent = gui

	-- Shield bar: drains while guarding and when blocking; red while the guard is broken.
	local shieldBack = Instance.new("Frame")
	shieldBack.AnchorPoint = Vector2.new(0.5, 1)
	shieldBack.Position = UDim2.new(0.5, 0, 1, -56)
	shieldBack.Size = UDim2.fromOffset(220, 8)
	shieldBack.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
	shieldBack.BackgroundTransparency = 0.3
	shieldBack.BorderSizePixel = 0
	Instance.new("UICorner", shieldBack).CornerRadius = UDim.new(1, 0)
	shieldBack.Parent = gui
	local shieldFill = Instance.new("Frame")
	shieldFill.Size = UDim2.fromScale(1, 1)
	shieldFill.BorderSizePixel = 0
	Instance.new("UICorner", shieldFill).CornerRadius = UDim.new(1, 0)
	shieldFill.Parent = shieldBack

	-- Stamina bar, just below the shield bar: drains while sprinting; dim while winded.
	local staminaBack = shieldBack:Clone()
	staminaBack.Position = UDim2.new(0.5, 0, 1, -44)
	staminaBack.Parent = gui
	local staminaFill = staminaBack:FindFirstChildOfClass("Frame") :: Frame

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	RunService.RenderStepped:Connect(function()
		crosshair.BackgroundTransparency = if swordController.isSwinging() then 0.7 else 0.2
		crosshair.BackgroundColor3 = if lockOn.isLocked() then Color3.fromRGB(255, 70, 70) else Color3.new(1, 1, 1)

		local player = Players.LocalPlayer
		local shield = (player:GetAttribute("Shield") or 100) / 100
		shieldFill.Size = UDim2.fromScale(shield, 1)
		-- Flashes white for a moment after a parry.
		local sinceParry = workspace:GetServerTimeNow() - (player:GetAttribute("ParryTime") or 0)
		local base = if player:GetAttribute("GuardBroken")
			then Color3.fromRGB(220, 60, 50)
			elseif swordController.isGuarding() then Color3.fromRGB(130, 200, 255)
			else Color3.fromRGB(80, 150, 230)
		shieldFill.BackgroundColor3 = base:Lerp(Color3.new(1, 1, 1), math.clamp(1 - sinceParry / 0.3, 0, 1))
		-- Only shown when it matters: guarding, or not yet refilled.
		shieldBack.Visible = swordController.isGuarding() or shield < 1

		local stamina = sprint.stamina()
		staminaFill.Size = UDim2.fromScale(stamina, 1)
		staminaFill.BackgroundColor3 = if sprint.isWinded() then Color3.fromRGB(140, 120, 60) else Color3.fromRGB(240, 200, 70)
		staminaBack.Visible = sprint.isSprinting() or stamina < 1
	end)
end

return Hud
