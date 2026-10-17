local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SwordConfig = require(ReplicatedStorage.Shared.SwordConfig)
local TrainingDummy = require(script.TrainingDummy)

local swordHitRemote = ReplicatedStorage.Remotes.SwordHit

local dummiesFolder = Instance.new("Folder")
dummiesFolder.Name = "Dummies"
dummiesFolder.Parent = workspace

TrainingDummy.new(Vector3.new(0, 0, -10), dummiesFolder)

-- Hit detection runs on the client for responsiveness; the server sanity-checks
-- each reported hit before applying damage.
local MAX_HIT_TO_DUMMY_DISTANCE = 8

local lastHitTimes: { [Player]: { [Instance]: number } } = {}

swordHitRemote.OnServerEvent:Connect(function(player, dummyModel, hitPosition, speed)
	if typeof(dummyModel) ~= "Instance" or typeof(hitPosition) ~= "Vector3" or typeof(speed) ~= "number" then
		return
	end
	if speed ~= speed or speed < SwordConfig.MinHitSpeed then -- speed ~= speed rejects NaN
		return
	end
	local dummy = TrainingDummy.fromModel(dummyModel)
	if not dummy then
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not (humanoid and root and humanoid.Health > 0) then
		return
	end
	if (root.Position - hitPosition).Magnitude > SwordConfig.MaxReach then
		return
	end
	if (dummy.pivot.Position - hitPosition).Magnitude > MAX_HIT_TO_DUMMY_DISTANCE then
		return
	end

	local playerHits = lastHitTimes[player] or {}
	lastHitTimes[player] = playerHits
	local now = os.clock()
	-- Small leeway for network jitter.
	if now - (playerHits[dummyModel] or 0) < SwordConfig.HitCooldown * 0.8 then
		return
	end
	playerHits[dummyModel] = now

	local damage = SwordConfig.damageForSpeed(math.min(speed, SwordConfig.MaxHitSpeed))
	dummy:takeHit(damage, hitPosition, root.Position)
end)

Players.PlayerRemoving:Connect(function(player)
	lastHitTimes[player] = nil
end)
