-- Builds the local-only greatsword + armored forearm viewmodel out of plain parts.
-- Everything is positioned relative to a "hand" CFrame whose:
--   LookVector  = direction the blade points
--   RightVector = direction the cutting edge faces
--   UpVector    = normal of the flat of the blade

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SwordConfig = require(ReplicatedStorage.Shared.SwordConfig)

local BLADE_START = 0.63 -- distance from the hand to where the blade leaves the guard
local TIP_LENGTH = 0.75 -- length of the tapered point
local STRAIGHT_LENGTH = SwordConfig.BladeLength + 0.28 - TIP_LENGTH -- blade before the point
local BLADE_WIDTH = 0.55 -- at the guard
local TIP_WIDTH = 0.36 -- where the point begins
local BLADE_THICKNESS = 0.08

local STEEL = Color3.fromRGB(190, 195, 205)
local BRIGHT_STEEL = Color3.fromRGB(225, 230, 238) -- the sharpened edges
local DARK_STEEL = Color3.fromRGB(70, 72, 80)
local BRASS = Color3.fromRGB(150, 120, 70)
local ARMOR = Color3.fromRGB(95, 98, 108)
local LEATHER = Color3.fromRGB(70, 45, 30)
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
SwordModel.BladeEnd = BLADE_START + STRAIGHT_LENGTH + TIP_LENGTH

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

	local block, ball, cylinder, wedge =
		Enum.PartType.Block, Enum.PartType.Ball, Enum.PartType.Cylinder, Enum.PartType.Wedge
	local metal = Enum.Material.Metal
	local alongBlade = CFrame.Angles(0, math.pi / 2, 0) -- turns a cylinder's axis onto the blade

	-- Long two-handed grip: right hand just under the guard, left hand near the pommel.
	piece("Grip", cylinder, Vector3.new(1.3, 0.22, 0.22), LEATHER, Enum.Material.Leather,
		CFrame.new(0, 0, 0.1) * alongBlade)
	for i = 0, 8 do
		piece("GripWrap", cylinder, Vector3.new(0.025, 0.235, 0.235), DARK_LEATHER, Enum.Material.Leather,
			CFrame.new(0, 0, -0.48 + i * 0.145) * alongBlade)
	end

	piece("PommelNeck", cylinder, Vector3.new(0.07, 0.27, 0.27), BRASS, metal, CFrame.new(0, 0, 0.74) * alongBlade)
	piece("Pommel", ball, Vector3.one * 0.38, DARK_STEEL, metal, CFrame.new(0, 0, 0.9))
	piece("PommelCap", ball, Vector3.one * 0.12, BRASS, metal, CFrame.new(0, 0, 1.06))

	piece("Guard", cylinder, Vector3.new(1.4, 0.14, 0.14), DARK_STEEL, metal, CFrame.new(0, 0, -0.52))
	piece("GuardBlock", block, Vector3.new(0.34, 0.17, 0.2), DARK_STEEL, metal, CFrame.new(0, 0, -0.54))
	piece("GuardCollar", block, Vector3.new(0.6, 0.12, 0.06), BRASS, metal, CFrame.new(0, 0, -0.62))
	for _, side in { -1, 1 } do
		piece("GuardFinial", ball, Vector3.one * 0.21, BRASS, metal, CFrame.new(side * 0.72, 0, -0.52))
	end

	local blade = piece("Blade", block, Vector3.new(TIP_WIDTH, BLADE_THICKNESS, STRAIGHT_LENGTH), STEEL, metal,
		CFrame.new(0, 0, -(BLADE_START + STRAIGHT_LENGTH / 2)))
	-- A groove down each flat; slightly thicker than the blade so it shows on both sides.
	piece("Fuller", block, Vector3.new(0.09, BLADE_THICKNESS + 0.01, STRAIGHT_LENGTH * 0.75), DARK_STEEL, metal,
		CFrame.new(0, 0, -(BLADE_START + STRAIGHT_LENGTH * 0.375)))

	-- A wedge's thin end faces forward, so each one narrows toward the tip. `inner` is
	-- how far its straight side sits from the blade's centre line, `base` where it starts.
	local function taper(name, side: number, inner: number, width: number, base: number, length: number, color)
		piece(name, wedge, Vector3.new(BLADE_THICKNESS, width, length), color, metal,
			CFrame.new(side * (inner + width / 2), 0, -(base + length / 2)) * CFrame.Angles(0, 0, -side * math.pi / 2))
	end
	for _, side in { -1, 1 } do
		taper("BladeEdge", side, TIP_WIDTH / 2, (BLADE_WIDTH - TIP_WIDTH) / 2, BLADE_START, STRAIGHT_LENGTH, BRIGHT_STEEL)
		taper("Tip", side, 0, TIP_WIDTH / 2, BLADE_START + STRAIGHT_LENGTH, TIP_LENGTH, STEEL)
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
	trailStart.Position = Vector3.new(0, 0, STRAIGHT_LENGTH / 2 - STRAIGHT_LENGTH * 0.35)
	trailStart.Parent = blade
	local trailEnd = Instance.new("Attachment")
	trailEnd.Position = Vector3.new(0, 0, -STRAIGHT_LENGTH / 2 - TIP_LENGTH)
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
