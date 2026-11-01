-- Minimal HUD: a crosshair that dims while swinging and turns red while locked on, and a controls hint.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Hud = {}

function Hud.start(swordController, lockOn)
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
	hint.Size = UDim2.fromOffset(1000, 24)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.GothamMedium
	hint.TextSize = 16
	hint.TextColor3 = Color3.new(1, 1, 1)
	hint.TextStrokeTransparency = 0.5
	hint.Text = "Hold Left Click + flick the mouse to slash that way  •  Alternate directions to chain  •  Caps Lock to lock on"
	hint.Parent = gui

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	RunService.RenderStepped:Connect(function()
		crosshair.BackgroundTransparency = if swordController.isSwinging() then 0.7 else 0.2
		crosshair.BackgroundColor3 = if lockOn.isLocked() then Color3.fromRGB(255, 70, 70) else Color3.new(1, 1, 1)
	end)
end

return Hud
