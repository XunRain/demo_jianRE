-- 特效与浮动文字模块：负责属性门提示、掉落动画、命中特效和轻量 UI 动效。
local VFXController = {}

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

local vfxFolder = ReplicatedStorage:WaitForChild("VFX", 10)
local sourceVFX = vfxFolder and vfxFolder:WaitForChild("CollisionDoorVFX", 5)

local guiFolder = ReplicatedStorage:WaitForChild("GUI", 10)
local suspensionTextTemplate = guiFolder and guiFolder:WaitForChild("SuspensionText", 5)

local Controllers

-- 初始化特效模块依赖。
function VFXController.Init(deps)
	Controllers = deps
end

-- 启动特效模块；当前没有持续初始化逻辑，保留接口兼容。
function VFXController.Start()
end

-- 在 3D 物体上方创建悬浮文字。
function VFXController.CreateBillboard(part, text, textColor, yOffset)
	if not suspensionTextTemplate then
		warn("[VFXController] 未找到 ReplicatedStorage/GUI/SuspensionText。")
		return nil
	end

	local billboard = suspensionTextTemplate:Clone()
	billboard.StudsOffset = Vector3.new(0, 0, 0)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, (part.Size.Y / 2) + yOffset, 0)

	local label = billboard:FindFirstChild("Text")
	if label and label:IsA("TextLabel") then
		label.Text = text
		label.TextColor3 = textColor
		label.Font = Enum.Font.Cartoon
		if string.find(text, "\n") then
			billboard.Size = UDim2.new(
				billboard.Size.X.Scale,
				billboard.Size.X.Offset,
				billboard.Size.Y.Scale * 1.5,
				billboard.Size.Y.Offset
			)
			label.LineHeight = 0.8
		end
	else
		warn("[VFXController] SuspensionText 缺少名为 Text 的 TextLabel。")
	end

	billboard.Parent = part
	return label
end

-- 获取实例当前世界 CFrame，兼容 BasePart 和 Model。
local function getInstanceWorldCFrame(instance)
    if not instance then return nil end
    if instance:IsA("Model") then
        return instance:GetPivot()
    end

    local anchor = instance:IsA("BasePart") and instance or instance:FindFirstChildWhichIsA("BasePart", true)
    return anchor and anchor.CFrame or nil
end

-- 获取实例中真正用于挂载拖尾的零件，兼容 MeshPart、BasePart 和 Model。
local function getInstanceAnchorPart(instance)
	if not instance then return nil end
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	end

	return instance:FindFirstChildWhichIsA("BasePart", true)
end

-- 查找模型里的贴地标记；美术可放 GroundAnchor/GroundPart 来精确指定落地点。
local function findGroundMarker(instance)
	if not instance then return nil end

	local markerNames = {"GroundAnchor", "GroundPart", "GroundMarker", "DropGround", "RootPart", "FakeRootPart"}
	for _, name in ipairs(markerNames) do
		local marker = instance:FindFirstChild(name, true)
		if marker and (marker:IsA("BasePart") or marker:IsA("Attachment")) then
			return marker
		end
	end

	return nil
end

-- 计算“定位点”到模型底部的 Y 轴偏移；Model 会使用 Pivot，因此调 Pivot 后会真正影响贴地高度。
local function getInstanceGroundOffset(instance)
	if not instance then return 0 end

	if instance:IsA("Model") then
		local pivotY = instance:GetPivot().Position.Y
		local marker = findGroundMarker(instance)
		if marker then
			if marker:IsA("Attachment") then
				return pivotY - marker.WorldPosition.Y
			end

			if marker.Name == "GroundPart" then
				return pivotY - (marker.Position.Y - marker.Size.Y / 2)
			end

			return pivotY - marker.Position.Y
		end

		local boundsCFrame, boundsSize = instance:GetBoundingBox()
		return pivotY - (boundsCFrame.Position.Y - boundsSize.Y / 2)
	end

	local anchor = instance:IsA("BasePart") and instance or instance:FindFirstChildWhichIsA("BasePart", true)
	if not anchor then return 0 end

	local marker = findGroundMarker(anchor)
	if marker then
		if marker:IsA("Attachment") then
			return anchor.Position.Y - marker.WorldPosition.Y
		end

		if marker.Name == "GroundPart" then
			return anchor.Position.Y - (marker.Position.Y - marker.Size.Y / 2)
		end

		return anchor.Position.Y - marker.Position.Y
	end

	return anchor.Size.Y / 2
end

-- 将实例移动到指定世界坐标，并尽量保留原始朝向。
local function moveInstanceToPosition(instance, position)
    if not instance then return end
    if instance:IsA("Model") then
        instance:PivotTo(CFrame.new(position) * instance:GetPivot().Rotation)
        return
    end

    local anchor = instance:IsA("BasePart") and instance or instance:FindFirstChildWhichIsA("BasePart", true)
    if anchor then
        anchor.Position = position
    end
end

-- 给掉落物临时挂白色拖尾，表现烟花抛散时的速度感。
local function createDropTrail(instance, duration)
	local anchor = getInstanceAnchorPart(instance)
	if not anchor then return end

	local halfHeight = math.max(anchor.Size.Y * 0.25, 0.12)
	local attachment0 = Instance.new("Attachment")
	attachment0.Name = "DropTrailTop"
	attachment0.Position = Vector3.new(0, halfHeight, 0)
	attachment0.Parent = anchor

	local attachment1 = Instance.new("Attachment")
	attachment1.Name = "DropTrailBottom"
	attachment1.Position = Vector3.new(0, -halfHeight, 0)
	attachment1.Parent = anchor

	local trail = Instance.new("Trail")
	trail.Name = "DropBurstTrail"
	trail.Attachment0 = attachment0
	trail.Attachment1 = attachment1
	trail.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(0.65, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.45),
		NumberSequenceKeypoint.new(1, 0),
	})
	trail.Lifetime = (Controllers and Controllers.Config and Controllers.Config.DROP_TRAIL_LIFETIME) or 0.28
	trail.MinLength = 0.05
	trail.FaceCamera = true
	trail.LightEmission = 1
	trail.Parent = anchor

	local cleanupDelay = duration + trail.Lifetime + 0.1
	Debris:AddItem(trail, cleanupDelay)
	Debris:AddItem(attachment0, cleanupDelay)
	Debris:AddItem(attachment1, cleanupDelay)
end

-- 播放掉落物散开动画，让金币/经验从击杀点弹到地面。
function VFXController.PlayDropExplosion(part, startPos)
    local Config = Controllers and Controllers.Config
    local angle = math.random() * math.pi * 2
    local minRadius = (Config and Config.DROP_BURST_MIN_RADIUS) or 4
    local maxRadius = (Config and Config.DROP_BURST_MAX_RADIUS) or 11
    local minHeight = (Config and Config.DROP_BURST_MIN_HEIGHT) or 7
    local maxHeight = (Config and Config.DROP_BURST_MAX_HEIGHT) or 14
    local duration = (Config and Config.DROP_BURST_DURATION) or 0.6
    local radius = math.random(math.floor(minRadius * 100), math.floor(maxRadius * 100)) / 100
    local burstHeight = math.random(math.floor(minHeight * 100), math.floor(maxHeight * 100)) / 100
    local groundY = startPos.Y - 2

    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Include

    local trackFolder = Workspace:FindFirstChild("LocalTrack")
    if trackFolder then
        rayParams.FilterDescendantsInstances = {trackFolder}
        local hit = Workspace:Raycast(startPos, Vector3.new(0, -50, 0), rayParams)
        if hit then
            groundY = hit.Position.Y
        end
    end

    local targetPos = Vector3.new(
        startPos.X + math.cos(angle) * radius,
        groundY + getInstanceGroundOffset(part),
        startPos.Z + math.sin(angle) * radius
    )

    local startCFrame = getInstanceWorldCFrame(part)
    if not startCFrame then return end

    createDropTrail(part, duration)

    local startPosition = startCFrame.Position
    local tweenDriver = Instance.new("NumberValue")
    tweenDriver.Value = 0
    local connection = tweenDriver:GetPropertyChangedSignal("Value"):Connect(function()
        local alpha = tweenDriver.Value
        local flatPosition = startPosition:Lerp(targetPos, alpha)
        local arcOffset = math.sin(alpha * math.pi) * burstHeight
        moveInstanceToPosition(part, flatPosition + Vector3.new(0, arcOffset, 0))
    end)

    local tInfo = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    local tween = TweenService:Create(tweenDriver, tInfo, {Value = 1})
    tween.Completed:Connect(function()
        connection:Disconnect()
        moveInstanceToPosition(part, targetPos)
        tweenDriver:Destroy()
    end)
    tween:Play()
end
-- 播放属性门触碰特效。
function VFXController.PlayGateVFX(rootPart)
	if not sourceVFX or not rootPart then return end

	local vfxClone = sourceVFX:Clone()
	if vfxClone:IsA("PVInstance") then
		vfxClone:PivotTo(rootPart.CFrame)
	end
	vfxClone.Parent = rootPart

	if vfxClone:IsA("BasePart") then
		vfxClone.Anchored = false
		vfxClone.CanCollide = false

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = rootPart
		weld.Part1 = vfxClone
		weld.Parent = vfxClone
	elseif vfxClone:IsA("Model") then
		local primary = vfxClone.PrimaryPart or vfxClone:FindFirstChildWhichIsA("BasePart", true)
		if primary then
			primary.Anchored = false
			primary.CanCollide = false

			local weld = Instance.new("WeldConstraint")
			weld.Part0 = rootPart
			weld.Part1 = primary
			weld.Parent = vfxClone

			for _, p in ipairs(vfxClone:GetDescendants()) do
				if p:IsA("BasePart") then
					p.Anchored = false
					p.CanCollide = false
				end
			end
		end
	end

	for _, descendant in ipairs(vfxClone:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = true
			descendant.LockedToPart = true
			descendant:Emit(25)
		end
	end

	Debris:AddItem(vfxClone, 0.5)
end

-- 播放抽宠蛋的左右摇晃动画。
function VFXController.PlayEggShakeVFX(model)
	if not model or not model:IsA("PVInstance") then return end
	local baseCFrame = getInstanceWorldCFrame(model) or CFrame.new(0, 0, 0)

	task.spawn(function()
		local angles = {30, -30, 0}
		for _, angle in ipairs(angles) do
			if not model or not model.Parent then return end
			model:PivotTo(baseCFrame * CFrame.Angles(0, 0, math.rad(angle)))
			task.wait(0.06)
		end
	end)
end

-- 启动宠物展示旋转动画，并返回连接对象供外部停止。
function VFXController.StartPetSpinVFX(model)
	if not model or not model:IsA("PVInstance") then return nil end

	local rotationY = 0
	local spinConnection = RunService.RenderStepped:Connect(function(dt)
		if model and model.Parent then
			rotationY = rotationY + math.rad(45 * dt)
			model:PivotTo(CFrame.new(0, 0, 0) * CFrame.Angles(0, rotationY, 0))
		end
	end)

	return spinConnection
end

local currentGuideBeam = nil
local currentGuideAtt0 = nil
local currentGuideAtt1 = nil
local currentGuideLabel = nil
local currentGuideLabelAnchor = nil

-- 移动没有焊接到根节点的特效零件，避免模型特效散件留在原地。
local function translateLooseVfxParts(root, delta)
	if not root or delta == Vector3.zero then return end

	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CFrame = descendant.CFrame + delta
		end
	end
end

-- 获取特效实例的定位零件，兼容 Part 和 Model。
local function getVfxAnchorPart(instance)
	if not instance then return nil end
	if instance:IsA("BasePart") then return instance end
	if instance:IsA("Model") then
		return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	end
	return instance:FindFirstChildWhichIsA("BasePart", true)
end

-- 把特效实例摆放到指定坐标，并沿用预制体朝向。
local function placeVfxInstance(instance, prefab, position)
	if not instance or not prefab then return end

	if instance:IsA("Model") then
		instance:PivotTo(CFrame.new(position) * prefab:GetPivot().Rotation)
	else
		local cloneAnchor = getVfxAnchorPart(instance)
		local prefabAnchor = getVfxAnchorPart(prefab)
		if not cloneAnchor or not prefabAnchor then return end

		local targetCFrame = CFrame.new(position) * prefabAnchor.CFrame.Rotation
		local delta = targetCFrame.Position - cloneAnchor.Position
		cloneAnchor.CFrame = targetCFrame
		translateLooseVfxParts(instance, delta)
	end
end

-- 创建从玩家指向目标的引导光束和提示文字。
function VFXController.CreateGuide(targetPart, text, options)
	VFXController.ClearGuide()
	options = options or {}
	local showBeam = options.ShowBeam ~= false

	local character = Players.LocalPlayer.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not targetPart then return end

	if showBeam and rootPart then
		currentGuideAtt0 = Instance.new("Attachment", rootPart)
		currentGuideAtt1 = Instance.new("Attachment", targetPart)

		currentGuideBeam = Instance.new("Beam")
		currentGuideBeam.Attachment0 = currentGuideAtt1
		currentGuideBeam.Attachment1 = currentGuideAtt0
		currentGuideBeam.FaceCamera = true
		currentGuideBeam.Width0 = 2
		currentGuideBeam.Width1 = 2
		currentGuideBeam.Color = ColorSequence.new(Color3.fromRGB(255, 215, 0))
		currentGuideBeam.Texture = "rbxassetid://9006027964"
		currentGuideBeam.TextureMode = Enum.TextureMode.Wrap
		currentGuideBeam.TextureSpeed = -3
		currentGuideBeam.TextureLength = 4
		currentGuideBeam.LightEmission = 1
		currentGuideBeam.Parent = rootPart
	end

	local labelHeight = tonumber(options.LabelHeight) or 4
	local labelAnchor = Instance.new("Part")
	labelAnchor.Name = "GuideLabelAnchor"
	labelAnchor.Anchored = true
	labelAnchor.CanCollide = false
	labelAnchor.CanQuery = false
	labelAnchor.CanTouch = false
	labelAnchor.Transparency = 1
	labelAnchor.Size = Vector3.new(0.2, 0.2, 0.2)
	labelAnchor.CFrame = CFrame.new(targetPart.Position + Vector3.new(0, targetPart.Size.Y * 0.5 + labelHeight, 0))
	labelAnchor.Parent = Workspace:FindFirstChild("LocalProjectiles") or Workspace
	currentGuideLabelAnchor = labelAnchor
	currentGuideLabel = VFXController.CreateBillboard(labelAnchor, text, Color3.fromRGB(255, 255, 100), 0)
end

-- 清除当前引导光束、附件和文字。
function VFXController.ClearGuide()
	if currentGuideBeam then currentGuideBeam:Destroy(); currentGuideBeam = nil end
	if currentGuideAtt0 then currentGuideAtt0:Destroy(); currentGuideAtt0 = nil end
	if currentGuideAtt1 then currentGuideAtt1:Destroy(); currentGuideAtt1 = nil end
	if currentGuideLabelAnchor then
		currentGuideLabelAnchor:Destroy()
		currentGuideLabelAnchor = nil
		currentGuideLabel = nil
	end
	if currentGuideLabel then
		currentGuideLabel.Parent:Destroy()
		currentGuideLabel = nil
	end
end

-- 播放命中抖动反馈，兼容隐藏碰撞盒和展示模型。
function VFXController.PlayHitJitterVFX(target, baseSize)
	if not target then return end
	if target:GetAttribute("IsJittering") then return end
	target:SetAttribute("IsJittering", true)

	task.spawn(function()
		if target:IsA("BasePart") and baseSize then
			local tInfo = TweenInfo.new(0.05, Enum.EasingStyle.Sine, Enum.EasingDirection.Out, 0, true)
			local tween = TweenService:Create(target, tInfo, {Size = baseSize * 1.3})
			tween:Play()
			tween.Completed:Wait()

			if target and target.Parent then
				target.Size = baseSize
				target:SetAttribute("IsJittering", false)
			end
		elseif target:IsA("Model") then
			local originalScale = target:GetScale()
			target:ScaleTo(originalScale * 1.2)
			task.wait(0.05)

			if target and target.Parent then
				target:ScaleTo(originalScale)
				target:SetAttribute("IsJittering", false)
			end
		end
	end)
end

-- 播放子弹命中特效，按预制体 EmitCount 触发粒子。
function VFXController.PlayBulletExplosion(vfxName, position)
	local rootFolder = ReplicatedStorage:FindFirstChild("VFX")
	if not rootFolder then return end

	local prefab = nil
	if rootFolder:FindFirstChild("Weapons") and rootFolder.Weapons:FindFirstChild(vfxName) then
		prefab = rootFolder.Weapons[vfxName]
	elseif rootFolder:FindFirstChild("Pets") and rootFolder.Pets:FindFirstChild(vfxName) then
		prefab = rootFolder.Pets[vfxName]
	end

	if not prefab then return end

	local explosion = prefab:Clone()
	if explosion:IsA("BasePart") then
		explosion.CFrame = CFrame.new(position) * prefab.CFrame.Rotation
	elseif explosion:IsA("Model") then
		explosion:PivotTo(CFrame.new(position) * prefab:GetPivot().Rotation)
	end

	explosion.Parent = Workspace:FindFirstChild("LocalProjectiles") or Workspace

	for _, child in ipairs(explosion:GetDescendants()) do
		if child:IsA("ParticleEmitter") then
			child:Emit(child:GetAttribute("EmitCount") or 10)
		end
	end

	local lifetime = prefab:GetAttribute("VfxLifetime")
	if lifetime == nil then
		lifetime = (vfxName == "AngelHit") and 0.8 or 0.25
	end

	Debris:AddItem(explosion, lifetime)
end

-- 播放怪物死亡特效。
function VFXController.PlayDeathVFX(vfxName, position)
	local rootFolder = ReplicatedStorage:FindFirstChild("VFX")
	local enemiesFolder = rootFolder and rootFolder:FindFirstChild("Enemies")
	local vfxPrefab = enemiesFolder and enemiesFolder:FindFirstChild(vfxName)

	if vfxPrefab then
		local vfx = vfxPrefab:Clone()
		placeVfxInstance(vfx, vfxPrefab, position)
		vfx.Parent = Workspace:FindFirstChild("LocalProjectiles") or Workspace

		for _, emitter in ipairs(vfx:GetDescendants()) do
			if emitter:IsA("ParticleEmitter") then
				emitter.Enabled = false
				emitter:Emit(emitter:GetAttribute("EmitCount") or 10)
			end
		end

		Debris:AddItem(vfx, 1.5)
	end
end

-- 播放玩家受击屏幕红闪和镜头震动。
function VFXController.PlayPlayerDamageVFX()
	local hitCC = Lighting:FindFirstChild("PlayerHitCC")
	if not hitCC then
		hitCC = Instance.new("ColorCorrectionEffect")
		hitCC.Name = "PlayerHitCC"
		hitCC.Parent = Lighting
	end

	hitCC.TintColor = Color3.new(1, 0.2, 0.2)

	local ccTweenInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(hitCC, ccTweenInfo, {TintColor = Color3.new(1, 1, 1)}):Play()

	local shakeDuration = 0.25
	local startTime = os.clock()
	local camera = Workspace.CurrentCamera

	pcall(function()
		RunService:UnbindFromRenderStep("PlayerScreenShake")
	end)

	RunService:BindToRenderStep("PlayerScreenShake", Enum.RenderPriority.Camera.Value + 1, function()
		local elapsed = os.clock() - startTime
		if elapsed >= shakeDuration then
			RunService:UnbindFromRenderStep("PlayerScreenShake")
			return
		end

		local intensity = (1 - (elapsed / shakeDuration)) * 0.8
		local offsetX = (math.random() - 0.5) * 2 * intensity
		local offsetY = (math.random() - 0.5) * 2 * intensity
		camera.CFrame = camera.CFrame * CFrame.new(offsetX, offsetY, 0)
	end)
end

-- 播放金币/经验拾取浮动文字。
function VFXController.PlayLootText(character, amountText, color, iconId)
	local player = Players.LocalPlayer
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then return end

	local lootGui = playerGui:FindFirstChild("LootTextGui")
	if not lootGui then
		lootGui = Instance.new("ScreenGui")
		lootGui.Name = "LootTextGui"
		lootGui.Parent = playerGui
	end

	local container = Instance.new("Frame")
	container.Size = UDim2.new(0, 150, 0, 45)
	container.BackgroundTransparency = 1

local randomX = math.random(15, 85) / 100
	local randomY = math.random(10, 75) / 100

	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.Position = UDim2.new(randomX, 0, randomY, 0)
	container.Parent = lootGui

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 8)
	layout.Parent = container

	local icon = Instance.new("ImageLabel")
	icon.Size = UDim2.new(1, 0, 1, 0)
	icon.SizeConstraint = Enum.SizeConstraint.RelativeYY
	icon.BackgroundTransparency = 1
	icon.Image = iconId
	icon.Parent = container

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(0.6, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.FredokaOne
	label.TextColor3 = color
	label.Text = amountText
	label.Parent = container

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(150, 80, 0)
	stroke.Thickness = 2
	stroke.Parent = label

	local floatInfo = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local fadeInfo = TweenInfo.new(0.4, Enum.EasingStyle.Linear, Enum.EasingDirection.In, 0, false, 0.2)
	local targetPos = UDim2.new(randomX, 0, randomY - 0.1, 0)

	TweenService:Create(container, floatInfo, {Position = targetPos}):Play()
	TweenService:Create(label, fadeInfo, {TextTransparency = 1}):Play()
	TweenService:Create(stroke, fadeInfo, {Transparency = 1}):Play()
	TweenService:Create(icon, fadeInfo, {ImageTransparency = 1}):Play()

	Debris:AddItem(container, 0.7)
end

-- 播放 UI 元素弹跳反馈。
function VFXController.PlayUIBounce(uiElement)
	if not uiElement or uiElement:GetAttribute("IsBouncing") then return end

	uiElement:SetAttribute("IsBouncing", true)

	local uiScale = uiElement:FindFirstChildOfClass("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Parent = uiElement
	end

	local bounceUp = TweenService:Create(uiScale, TweenInfo.new(0.08, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {Scale = 1.3})
	local bounceDown = TweenService:Create(uiScale, TweenInfo.new(0.25, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out), {Scale = 1})

	bounceUp:Play()
	bounceUp.Completed:Connect(function()
		bounceDown:Play()
	end)

	bounceDown.Completed:Connect(function()
		uiElement:SetAttribute("IsBouncing", false)
	end)
end

-- Floating damage number feedback for local combat hits.
function VFXController.PlayDamageNumber(enemy, damage, hitPosition)
	local damageConfig = Controllers.Config and Controllers.Config.DAMAGE_NUMBER
	if not damageConfig or damageConfig.Enabled == false then
		if damageConfig and damageConfig.Debug then
			print("[DamageNumber][VFX] skipped reason=disabled")
		end
		return
	end

	local amount = math.floor(tonumber(damage) or 0)
	if amount <= 0 then
		if damageConfig.Debug then
			print("[DamageNumber][VFX] skipped reason=invalid_damage damage=", damage)
		end
		return
	end

	local enemyPart = enemy and enemy.part
	if not enemyPart or not enemyPart.Parent then
		if damageConfig.Debug then
			print("[DamageNumber][VFX] skipped reason=missing_enemy_part")
		end
		return
	end

	local localProjectiles = Workspace:FindFirstChild("LocalProjectiles")
	if not localProjectiles then
		localProjectiles = Instance.new("Folder")
		localProjectiles.Name = "LocalProjectiles"
		localProjectiles.Parent = Workspace
	end

	local duration = damageConfig.Duration or 0.55
	local headOffset = damageConfig.HeadOffset or 2
	local spread = damageConfig.RandomSpread or 1.2
	local basePosition = hitPosition or enemyPart.Position
	local randomOffset = Vector3.new((math.random() - 0.5) * spread, 0, (math.random() - 0.5) * spread)
	local startPosition = Vector3.new(
		basePosition.X,
		enemyPart.Position.Y + enemyPart.Size.Y * 0.5 + headOffset,
		basePosition.Z
	) + randomOffset

	local anchor = Instance.new("Part")
	anchor.Name = "DamageNumberAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.CFrame = CFrame.new(startPosition)
	anchor.Parent = localProjectiles

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DamageNumber"
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.MaxDistance = 250
	billboard.Size = UDim2.fromOffset(130, 54)
	billboard.Parent = anchor

	local textLabel = Instance.new("TextLabel")
	textLabel.Name = "Value"
	textLabel.BackgroundTransparency = 1
	textLabel.Size = UDim2.fromScale(1, 1)
	textLabel.Font = Enum.Font.FredokaOne
	textLabel.Text = "-" .. Controllers.Config.FormatNumber(amount)
	textLabel.TextColor3 = damageConfig.TextColor or Color3.fromRGB(255, 244, 92)
	textLabel.TextStrokeColor3 = damageConfig.StrokeColor or Color3.fromRGB(35, 20, 0)
	textLabel.TextStrokeTransparency = 0
	textLabel.TextTransparency = 0
	textLabel.TextScaled = false
	textLabel.TextSize = damageConfig.StartSize or 34
	textLabel.Parent = billboard

	local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(anchor, tweenInfo, {Position = startPosition + Vector3.new(0, 2.4, 0)}):Play()
	TweenService:Create(textLabel, tweenInfo, {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
		TextSize = damageConfig.EndSize or 42,
	}):Play()

	Debris:AddItem(anchor, duration + 0.15)

	if damageConfig.Debug then
		print("[DamageNumber][VFX] created damage=", amount, "position=", tostring(startPosition))
	end
end

return VFXController
