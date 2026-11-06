-- Builds the local-only silver sword + armored forearm viewmodel out of plain parts.
-- Everything is positioned relative to a "hand" CFrame whose:
--   LookVector  = direction the blade points
--   RightVector = direction the cutting edge faces
--   UpVector    = normal of the flat of the blade

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SwordConfig = require(ReplicatedStorage.Shared.SwordConfig)

local BLADE_START = 0.63 -- distance from the hand to where the blade leaves the guard
local TIP_LENGTH = 0.45 -- length of the angled point
local STRAIGHT_LENGTH = SwordConfig.BladeLength - TIP_LENGTH -- blade before the point
local BLADE_WIDTH = 0.42 -- edges run parallel all the way to the point
local BLADE_THICKNESS = 0.07

local SILVER = Color3.fromRGB(200, 203, 210)
local SHADED_SILVER = Color3.fromRGB(150, 153, 160) -- one bevel catches less light than the other
local DARK_STEEL = Color3.fromRGB(70, 72, 80)
local GRIP_LEATHER = Color3.fromRGB(165, 95, 40)
local ARMOR = Color3.fromRGB(95, 98, 108)
local DARK_LEATHER = Color3.fromRGB(42, 30, 24)
local CLOTH = Color3.fromRGB(58, 52, 50)

local RIGHT_HAND_OFFSET = CFrame.new(0, 0, -0.22)
local LEFT_HAND_OFFSET = CFrame.new(0, 0, 0.38)
local WRIST_OFFSET = CFrame.new(-0.28, 0, 0) -- from a hand's centre to where its forearm ends

local FINGER_RADIUS = 0.17 -- from the centre of the grip to the middle of the fingers
local FINGER_ANGLES = { 40, -15, -70 } -- degrees around the grip, from the knuckle to the fingertip
local FINGER_POSITIONS = { -0.15, -0.05, 0.05, 0.15 } -- along the grip
local THUMB_ANGLES = { 195, 245 }
local THUMB_POSITION = -0.22

type Piece = { part: BasePart, offset: CFrame }
-- A slice of forearm, measured back along the arm from the wrist. No length = all the way to the root.
type ArmPiece = { part: BasePart, start: number, length: number?, diameter: number }

local SwordModel = {}
SwordModel.__index = SwordModel

-- Distances along the hand's LookVector covered by the blade (used for hit detection).
SwordModel.BladeStart = BLADE_START
SwordModel.BladeEnd = BLADE_START + SwordConfig.BladeLength

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

local function newArm(model: Instance, name: string): { ArmPiece }
	local metal = Enum.Material.Metal
	local function slice(pieceName, color, material, start, length, diameter): ArmPiece
		local part = newPart(model, name .. pieceName, Enum.PartType.Cylinder, Vector3.one * diameter, color, material)
		return { part = part, start = start, length = length, diameter = diameter }
	end
	return {
		slice("Sleeve", CLOTH, Enum.Material.Fabric, 0.75, nil, 0.46),
		slice("Vambrace", ARMOR, metal, 0.04, 0.8, 0.38),
		slice("Cuff", DARK_STEEL, metal, 0, 0.1, 0.44),
		slice("StrapNear", DARK_LEATHER, Enum.Material.Leather, 0.28, 0.06, 0.4),
		slice("StrapFar", DARK_LEATHER, Enum.Material.Leather, 0.6, 0.06, 0.4),
	}
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

	local block, cylinder, wedge = Enum.PartType.Block, Enum.PartType.Cylinder, Enum.PartType.Wedge
	local metal = Enum.Material.Metal
	local alongBlade = CFrame.Angles(0, math.pi / 2, 0) -- turns a cylinder's axis onto the blade

	-- Grip long enough for both hands, wrapped in leather with a dark cord spiralling round it.
	piece("Grip", cylinder, Vector3.new(1.3, 0.22, 0.22), GRIP_LEATHER, Enum.Material.Leather,
		CFrame.new(0, 0, 0.1) * alongBlade)
	for i = 0, 8 do
		piece("GripWrap", cylinder, Vector3.new(0.025, 0.235, 0.235), DARK_LEATHER, Enum.Material.Leather,
			CFrame.new(0, 0, -0.48 + i * 0.145) * alongBlade * CFrame.Angles(0, 0, math.rad(22)))
	end

	-- Square block pommel.
	piece("Pommel", block, Vector3.new(0.34, 0.34, 0.26), SILVER, metal, CFrame.new(0, 0, 0.88))
	piece("PommelCap", block, Vector3.new(0.28, 0.28, 0.05), SHADED_SILVER, metal, CFrame.new(0, 0, 1.03))

	-- Chunky rectangular crossguard with a groove near each end, and a collar onto the grip.
	piece("Guard", block, Vector3.new(0.95, 0.22, 0.3), SILVER, metal, CFrame.new(0, 0, -0.52))
	for _, side in { -1, 1 } do
		piece("GuardGroove", block, Vector3.new(0.035, 0.23, 0.31), DARK_STEEL, metal, CFrame.new(side * 0.34, 0, -0.52))
	end
	piece("GuardCollar", block, Vector3.new(0.2, 0.2, 0.12), SHADED_SILVER, metal, CFrame.new(0, 0, -0.39))

	-- Straight blade with parallel edges: each half is its own bevel, one catching more
	-- light than the other, with a dark groove down the middle.
	local blade = piece("Blade", block, Vector3.new(BLADE_WIDTH / 2, BLADE_THICKNESS, STRAIGHT_LENGTH), SILVER, metal,
		CFrame.new(BLADE_WIDTH / 4, 0, -(BLADE_START + STRAIGHT_LENGTH / 2)))
	piece("BladeShade", block, Vector3.new(BLADE_WIDTH / 2, BLADE_THICKNESS, STRAIGHT_LENGTH), SHADED_SILVER, metal,
		CFrame.new(-BLADE_WIDTH / 4, 0, -(BLADE_START + STRAIGHT_LENGTH / 2)))
	piece("Fuller", block, Vector3.new(0.04, BLADE_THICKNESS + 0.01, STRAIGHT_LENGTH * 0.9), DARK_STEEL, metal,
		CFrame.new(0, 0, -(BLADE_START + STRAIGHT_LENGTH * 0.45)))

	-- Angled point: a wedge on each side, each narrowing from the blade's edge to the tip.
	for _, side in { -1, 1 } do
		piece("Tip", wedge, Vector3.new(BLADE_THICKNESS, BLADE_WIDTH / 2, TIP_LENGTH), if side > 0 then SILVER else SHADED_SILVER, metal,
			CFrame.new(side * BLADE_WIDTH / 4, 0, -(BLADE_START + STRAIGHT_LENGTH + TIP_LENGTH / 2))
				* CFrame.Angles(0, 0, -side * math.pi / 2))
	end

	-- A gauntlet closed around the grip. `side` is which flat of the blade the back of the hand is on.
	local function gauntlet(name: string, handOffset: CFrame, side: number)
		local function handPiece(pieceName, shape, size, color, material, offset)
			piece(name .. pieceName, shape, size, color, material, handOffset * offset)
		end
		-- One joint of a finger or thumb, lying tangent to the grip at `degrees` around it.
		local function joint(pieceName, degrees: number, z: number, length: number, color)
			local angle = math.rad(degrees)
			handPiece(pieceName, block, Vector3.new(length, 0.085, 0.09), color, metal,
				CFrame.new(math.cos(angle) * FINGER_RADIUS, side * math.sin(angle) * FINGER_RADIUS, z)
					* CFrame.Angles(0, 0, side * angle + math.pi / 2))
		end

		handPiece("Palm", block, Vector3.new(0.16, 0.26, 0.38), DARK_LEATHER, Enum.Material.Leather,
			CFrame.new(-0.2, side * 0.03, 0))
		handPiece("Back", block, Vector3.new(0.42, 0.09, 0.4), ARMOR, metal, CFrame.new(-0.08, side * 0.2, 0))
		handPiece("Knuckles", block, Vector3.new(0.09, 0.07, 0.42), DARK_STEEL, metal, CFrame.new(0.12, side * 0.25, 0))
		for _, z in FINGER_POSITIONS do
			for i, degrees in FINGER_ANGLES do
				joint("Finger", degrees, z, 0.17, if i == 1 then DARK_STEEL else ARMOR)
			end
		end
		for _, degrees in THUMB_ANGLES do
			joint("Thumb", degrees, THUMB_POSITION, 0.17, ARMOR)
		end
	end
	gauntlet("Right", RIGHT_HAND_OFFSET, 1)
	gauntlet("Left", LEFT_HAND_OFFSET, -1)

	-- Swoosh streak along the outer part of the blade, only shown on fast swings.
	local trailStart = Instance.new("Attachment")
	-- "Blade" is the right half, so shift left onto the centre line.
	trailStart.Position = Vector3.new(-BLADE_WIDTH / 4, 0, STRAIGHT_LENGTH / 2 - STRAIGHT_LENGTH * 0.35)
	trailStart.Parent = blade
	local trailEnd = Instance.new("Attachment")
	trailEnd.Position = Vector3.new(-BLADE_WIDTH / 4, 0, -STRAIGHT_LENGTH / 2 - TIP_LENGTH)
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
		rightArm = newArm(model, "RightArm"),
		leftArm = newArm(model, "LeftArm"),
	}, SwordModel)
end

local function stretchArm(arm: { ArmPiece }, from: Vector3, to: Vector3)
	local total = (to - from).Magnitude
	local back = (from - to).Unit
	local facing = CFrame.lookAt(to, from).Rotation * CFrame.Angles(0, math.pi / 2, 0) -- cylinder axis along the arm
	for _, slice in arm do
		local length = math.max(slice.length or total - slice.start, 0.05)
		slice.part.Size = Vector3.new(length, slice.diameter, slice.diameter)
		slice.part.CFrame = CFrame.new(to + back * (slice.start + length / 2)) * facing
	end
end

-- Arm roots are the world positions the forearms stretch from (off-screen, below the camera).
function SwordModel:update(handCFrame: CFrame, rightArmRoot: Vector3, leftArmRoot: Vector3)
	for _, p in self.pieces do
		p.part.CFrame = handCFrame * p.offset
	end
	stretchArm(self.rightArm, rightArmRoot, (handCFrame * RIGHT_HAND_OFFSET * WRIST_OFFSET).Position)
	stretchArm(self.leftArm, leftArmRoot, (handCFrame * LEFT_HAND_OFFSET * WRIST_OFFSET).Position)
end

function SwordModel:setTrailEnabled(enabled: boolean)
	self.trail.Enabled = enabled
end

return SwordModel
