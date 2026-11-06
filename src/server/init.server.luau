local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SwordConfig = require(ReplicatedStorage.Shared.SwordConfig)
local TrainingDummy = require(script.TrainingDummy)
local BenchSeats = require(script.BenchSeats)
local Slime = require(script.Slime)
local Goblin = require(script.Goblin)
local Guard = require(script.Guard)

BenchSeats.init()
Guard.start()

local swordHitRemote = ReplicatedStorage.Remotes.SwordHit

local dummiesFolder = Instance.new("Folder")
dummiesFolder.Name = "Dummies"
dummiesFolder.Parent = workspace

TrainingDummy.new(Vector3.new(0, 0, -10), dummiesFolder)

-- Monsters live in the same folder so the sword's hit detection finds them too.
local TEST_GOBLIN_POSITION = Vector3.new(10, 45, 30) -- near the player spawn; remove once done testing

local function showDamageNumber(damage, position)
	TrainingDummy._showDamageNumber(nil, damage, position)
end
Slime.start(dummiesFolder, showDamageNumber)
Goblin.start(dummiesFolder, showDamageNumber)
Goblin.new(TEST_GOBLIN_POSITION)

-- Each forest clearing gets a slime at its first spawn marker and a goblin at its second.
local monsterSpawns = workspace.Kingdom.KingsRoad.KingsWood:FindFirstChild("MonsterSpawns")
if monsterSpawns then
	local spawnsUsed = {}
	for _, spawnPoint in monsterSpawns:GetChildren() do
		local clearing = spawnPoint:GetAttribute("Clearing")
		local used = (spawnsUsed[clearing] or 0) + 1
		spawnsUsed[clearing] = used
		local position = spawnPoint.Position + Vector3.new(0, 5, 0)
		if used == 1 then
			Slime.new(position)
		elseif used == 2 then
			Goblin.new(position)
		end
	end
end

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
	local dummy = TrainingDummy.fromModel(dummyModel) or Slime.fromModel(dummyModel) or Goblin.fromModel(dummyModel)
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
