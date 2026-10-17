-- A wooden training dummy on a springy post: shows damage numbers, flashes,
-- wobbles away from hits, and resets after being knocked out.

local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

local MAX_HEALTH = 300
local RESET_DELAY = 2

local WOOD = Color3.fromRGB(110, 75, 45)
local BURLAP = Color3.fromRGB(196, 164, 112)
local ROPE = Color3.fromRGB(85, 60, 40)

local TrainingDummy = {}
TrainingDummy.__index = TrainingDummy

local dummiesByModel: { [Instance]: any } = {}

local function newPart(parent: Instance, name: string, props: { [string]: any }): Part
	local part = Instance.new("Part")
	part.Name = name
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props do
		(part :: any)[key] = value
	end
	part.Parent = parent
	return part
end

local function buildHealthBar(adornee: BasePart)
	local gui = Instance.new("BillboardGui")
	gui.Name = "HealthBar"
	gui.Size = UDim2.new(4, 0, 0.9, 0)
	gui.StudsOffset = Vector3.new(0, 1.6, 0)
	gui.MaxDistance = 80
	gui.Adornee = adornee

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 0.5)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.4
	label.Parent = gui

	local back = Instance.new("Frame")
	back.Position = UDim2.fromScale(0, 0.6)
	back.Size = UDim2.fromScale(1, 0.4)
	back.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	back.BorderSizePixel = 0
	back.Parent = gui

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BorderSizePixel = 0
	fill.Parent = back

	gui.Parent = adornee
	return label, fill
end

function TrainingDummy.new(position: Vector3, parent: Instance)
	local model = Instance.new("Model")
	model.Name = "TrainingDummy"

	newPart(model, "Base", {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.4, 3.2, 3.2),
		CFrame = CFrame.new(position + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Color = WOOD,
		Material = Enum.Material.Wood,
		Anchored = true,
	})

	-- Invisible anchored hinge at the top of the base. The upper body is welded
	-- to it, so tilting this one part makes the whole dummy wobble.
	local pivot = newPart(model, "Pivot", {
		Size = Vector3.one * 0.2,
		CFrame = CFrame.new(position + Vector3.new(0, 0.4, 0)),
		Transparency = 1,
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
	})
	model.PrimaryPart = pivot

	local function upper(name: string, offset: Vector3, props: { [string]: any })
		props.CFrame = pivot.CFrame + offset
		local part = newPart(model, name, props)
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = pivot
		weld.Part1 = part
		weld.Parent = part
		return part
	end

	upper("Post", Vector3.new(0, 1.3, 0), { Size = Vector3.new(0.45, 2.6, 0.45), Color = WOOD, Material = Enum.Material.Wood })
	upper("Torso", Vector3.new(0, 3.3, 0), { Size = Vector3.new(2, 2.4, 1.1), Color = BURLAP, Material = Enum.Material.Fabric })
	upper("Belt", Vector3.new(0, 2.5, 0), { Size = Vector3.new(2.05, 0.25, 1.15), Color = ROPE, Material = Enum.Material.Fabric })
	upper("Crossbar", Vector3.new(0, 3.9, 0), { Size = Vector3.new(4.4, 0.4, 0.4), Color = WOOD, Material = Enum.Material.Wood })
	local head = upper("Head", Vector3.new(0, 5.3, 0), {
		Shape = Enum.PartType.Ball,
		Size = Vector3.one * 1.5,
		Color = BURLAP,
		Material = Enum.Material.Fabric,
	})

	local highlight = Instance.new("Highlight")
	highlight.FillColor = Color3.new(1, 1, 1)
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 1
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = model

	local label, fill = buildHealthBar(head)

	model.Parent = parent

	local self = setmetatable({
		model = model,
		pivot = pivot,
		restCFrame = pivot.CFrame,
		highlight = highlight,
		label = label,
		fill = fill,
		health = MAX_HEALTH,
		knockedOut = false,
		wobbleTween = nil :: Tween?,
	}, TrainingDummy)
	self:_updateHealthBar()
	dummiesByModel[model] = self
	return self
end

function TrainingDummy.fromModel(model: Instance)
	return dummiesByModel[model]
end

function TrainingDummy:takeHit(damage: number, hitPosition: Vector3, attackerPosition: Vector3)
	if self.knockedOut then
		return
	end
	self.health = math.max(self.health - damage, 0)
	self:_updateHealthBar()
	self:_showDamageNumber(damage, hitPosition)
	self:_flash()
	self:_wobble(damage, attackerPosition)

	if self.health == 0 then
		self.knockedOut = true
		self.label.Text = "K.O.!"
		task.delay(RESET_DELAY, function()
			self.health = MAX_HEALTH
			self.knockedOut = false
			self:_updateHealthBar()
		end)
	end
end

function TrainingDummy:_updateHealthBar()
	local fraction = self.health / MAX_HEALTH
	self.fill.Size = UDim2.fromScale(fraction, 1)
	self.fill.BackgroundColor3 = Color3.fromRGB(220, 60, 50):Lerp(Color3.fromRGB(80, 210, 90), fraction)
	if not self.knockedOut then
		self.label.Text = `Training Dummy  {self.health}/{MAX_HEALTH}`
	end
end

function TrainingDummy:_showDamageNumber(damage: number, position: Vector3)
	local anchor = Instance.new("Part")
	anchor.Size = Vector3.one * 0.1
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Position = position

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.new(2.5, 0, 1.2, 0)
	gui.AlwaysOnTop = true
	local drift = (math.random() - 0.5) * 1.5
	gui.StudsOffset = Vector3.new(drift, 0.5, 0)
	gui.Parent = anchor

	local strength = math.clamp(damage / 35, 0, 1)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Text = if strength >= 0.75 then `{damage}!` else tostring(damage)
	label.TextColor3 = Color3.new(1, 1, 1):Lerp(Color3.fromRGB(255, 70, 40), strength)
	label.TextStrokeTransparency = 0
	label.Parent = gui

	anchor.Parent = workspace
	local info = TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(gui, info, { StudsOffset = Vector3.new(drift, 2.5, 0) }):Play()
	TweenService:Create(label, info, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	Debris:AddItem(anchor, 0.85)
end

function TrainingDummy:_flash()
	self.highlight.FillTransparency = 0.35
	TweenService:Create(self.highlight, TweenInfo.new(0.25), { FillTransparency = 1 }):Play()
end

function TrainingDummy:_wobble(damage: number, attackerPosition: Vector3)
	local away = (self.restCFrame.Position - attackerPosition) * Vector3.new(1, 0, 1)
	if away.Magnitude < 1e-3 then
		return
	end
	-- Rotating about (up x away) tips the top of the dummy in the `away` direction.
	local axis = Vector3.yAxis:Cross(away.Unit)
	local angle = math.rad(math.clamp(damage * 0.6, 3, 20))
	local tilted = CFrame.new(self.restCFrame.Position) * CFrame.fromAxisAngle(axis, angle) * self.restCFrame.Rotation

	if self.wobbleTween then
		self.wobbleTween:Cancel()
	end
	local tipOver = TweenService:Create(self.pivot, TweenInfo.new(0.06, Enum.EasingStyle.Quad), { CFrame = tilted })
	self.wobbleTween = tipOver
	tipOver.Completed:Connect(function(state)
		if state ~= Enum.PlaybackState.Completed then
			return
		end
		local settle = TweenService:Create(
			self.pivot,
			TweenInfo.new(1, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out),
			{ CFrame = self.restCFrame }
		)
		self.wobbleTween = settle
		settle:Play()
	end)
	tipOver:Play()
end

return TrainingDummy
