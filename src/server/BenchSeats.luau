-- Gives every Seat tagged "BenchSeat" a proximity "Sit" prompt.
-- Seats are placed with CanTouch off so players don't sit by walking into them;
-- jumping gets them back up (default Humanoid behaviour).
local CollectionService = game:GetService("CollectionService")

local TAG = "BenchSeat"

local BenchSeats = {}

local function setup(seat: Instance)
	if not seat:IsA("Seat") or seat:FindFirstChild("SitPrompt") then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "SitPrompt"
	prompt.ActionText = "Sit"
	prompt.ObjectText = "Bench"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Parent = seat

	prompt.Triggered:Connect(function(player)
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 or humanoid.Sit or seat.Occupant then
			return
		end
		seat:Sit(humanoid)
	end)

	-- Hide the prompt while someone is sitting so it doesn't float over them.
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		prompt.Enabled = seat.Occupant == nil
	end)
end

function BenchSeats.init()
	for _, seat in CollectionService:GetTagged(TAG) do
		setup(seat)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(setup)
end

return BenchSeats
