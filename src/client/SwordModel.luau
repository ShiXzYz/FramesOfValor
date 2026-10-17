-- Builds the local-only greatsword + armored forearm viewmodel out of plain parts.
-- Everything is positioned relative to a "hand" CFrame whose:
--   LookVector  = direction the blade points
--   RightVector = direction the cutting edge faces
--   UpVector    = normal of the flat of the blade

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SwordConfig = require(ReplicatedStorage.Shared.SwordConfig)

local BLADE_LENGTH = SwordConfig.BladeLength
local BLADE_START = 0.63 -- distance from the hand to where the blade leaves the guard
local TIP_LENGTH = 0.28 -- how far the diamond tip sticks out past the blade

local STEEL = Color3.fromRGB(190, 195, 205)
local DARK_STEEL = Color3.fromRGB(70, 72, 80)
local ARMOR = Color3.fromRGB(95, 98, 108)
local LEATHER = Color3.fromRGB(70, 45, 30)

local RIGHT_HAND_OFFSET = CFrame.new(0, 0, -0.22)
local LEFT_HAND_OFFSET = CFrame.new(0, 0, 0.38)

type Piece = { part: BasePart, offset: CFrame }

local SwordModel = {}
SwordModel.__index = SwordModel

-- Distances along the hand's LookVector covered by the blade (used for hit detection).
SwordModel.BladeStart = BLADE_START
SwordModel.BladeEnd = BLADE_START + BLADE_LENGTH + TIP_LENGTH

local function newPart(parent: Instance, name: string, shape: Enum.PartType, size: Vector3, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape
	part.Size = size
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = parent
	return part
end

function SwordModel.new()
	local model = Instance.new("Model")
	model.Name = "SwordViewmodel"

	local pieces: { Piece } = {}
	local function piece(name, shape, size, color, material, offset)
		local part = newPart(model, name, shape, size, color, material)
		table.insert(pieces, { part = part, offset = offset })
		return part
	end

	local block, ball, cylinder = Enum.PartType.Block, Enum.PartType.Ball, Enum.PartType.Cylinder
	local metal = Enum.Material.Metal

	-- Long two-handed grip: right hand just under the guard, left hand near the pommel.
	piece("Grip", cylinder, Vector3.new(1.3, 0.22, 0.22), LEATHER, Enum.Material.Fabric,
		CFrame.new(0, 0, 0.1) * CFrame.Angles(0, math.pi / 2, 0))
	piece("Pommel", ball, Vector3.one * 0.38, DARK_STEEL, metal, CFrame.new(0, 0, 0.85))
	piece("Guard", block, Vector3.new(1.5, 0.2, 0.26), DARK_STEEL, metal, CFrame.new(0, 0, -0.5))
	local blade = piece("Blade", block, Vector3.new(0.55, 0.1, BLADE_LENGTH), STEEL, metal,
		CFrame.new(0, 0, -(BLADE_START + BLADE_LENGTH / 2)))
	-- A square rotated 45 degrees, centered on the blade's end, makes a pointed tip.
	piece("Tip", block, Vector3.new(0.39, 0.1, 0.39), STEEL, metal,
		CFrame.new(0, 0, -(BLADE_START + BLADE_LENGTH)) * CFrame.Angles(0, math.pi / 4, 0))
	piece("RightGauntlet", block, Vector3.new(0.45, 0.5, 0.5), ARMOR, metal, RIGHT_HAND_OFFSET)
	piece("LeftGauntlet", block, Vector3.new(0.45, 0.5, 0.5), ARMOR, metal, LEFT_HAND_OFFSET)

	-- Swoosh streak along the outer part of the blade, only shown on fast swings.
	local trailStart = Instance.new("Attachment")
	trailStart.Position = Vector3.new(0, 0, BLADE_LENGTH / 2 - BLADE_LENGTH * 0.35)
	trailStart.Parent = blade
	local trailEnd = Instance.new("Attachment")
	trailEnd.Position = Vector3.new(0, 0, -BLADE_LENGTH / 2 - TIP_LENGTH)
	trailEnd.Parent = blade
	local trail = Instance.new("Trail")
	trail.Attachment0 = trailStart
	trail.Attachment1 = trailEnd
	trail.Lifetime = 0.14
	trail.MinLength = 0
	trail.LightEmission = 0.5
	trail.Color = ColorSequence.new(Color3.fromRGB(235, 240, 255))
	trail.Transparency = NumberSequence.new(0.55, 1)
	trail.Enabled = false
	trail.Parent = blade

	return setmetatable({
		model = model,
		pieces = pieces,
		trail = trail,
		rightArm = newPart(model, "RightArm", block, Vector3.new(0.5, 0.5, 1), ARMOR, metal),
		leftArm = newPart(model, "LeftArm", block, Vector3.new(0.5, 0.5, 1), ARMOR, metal),
	}, SwordModel)
end

local function stretchArm(arm: BasePart, from: Vector3, to: Vector3)
	arm.Size = Vector3.new(0.5, 0.5, (to - from).Magnitude)
	arm.CFrame = CFrame.lookAt((from + to) / 2, to)
end

-- Arm roots are the world positions the forearms stretch from (off-screen, below the camera).
function SwordModel:update(handCFrame: CFrame, rightArmRoot: Vector3, leftArmRoot: Vector3)
	for _, p in self.pieces do
		p.part.CFrame = handCFrame * p.offset
	end
	stretchArm(self.rightArm, rightArmRoot, (handCFrame * RIGHT_HAND_OFFSET).Position)
	stretchArm(self.leftArm, leftArmRoot, (handCFrame * LEFT_HAND_OFFSET).Position)
end

function SwordModel:setTrailEnabled(enabled: boolean)
	self.trail.Enabled = enabled
end

return SwordModel
