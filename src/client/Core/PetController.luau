-- src/client/Core/PetController.luau
-- 宠物控制模块：负责宠物跟随、分身刷新，以及宠物技能/子弹的发射。
local PetController = {}

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera
local Controllers

local currentPetModel = nil

-- 获取 Part 或 Model 中第一个可用于定位的 BasePart。
local function getFirstBasePart(instance)
	if not instance then return nil end
	if instance:IsA("BasePart") then return instance end
	return instance:FindFirstChildWhichIsA("BasePart", true)
end

-- 预处理宠物模型：补齐 PrimaryPart，并关闭碰撞与物理下落，保证跟随时稳定。
local function prepareMovableModel(instance)
	if not instance then return nil end

	local rootPart = getFirstBasePart(instance)
	if instance:IsA("Model") and not instance.PrimaryPart and rootPart then
		instance.PrimaryPart = rootPart
	end

	if instance:IsA("BasePart") then
		instance.Anchored = true
		instance.CanCollide = false
	end

	for _, part in ipairs(instance:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
		end
	end

	return rootPart
end

-- 统一设置子弹预制体的物理状态，避免 Studio 里的 Anchored/碰撞配置影响发射。
local function setProjectilePhysics(instance, anchored)
	if not instance then return end

	if instance:IsA("BasePart") then
		instance.Anchored = anchored
		instance.CanCollide = false
	end

	for _, part in ipairs(instance:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = anchored
			part.CanCollide = false
		end
	end
end

-- 获取圣光预警的贴地锚点；优先使用美术放置的 AnchorPart，再兼容 GroundAnchor/Attachment1。
local function getSmiteGroundAnchor(instance)
	if not instance then return nil end

	local anchorPart = instance:FindFirstChild("AnchorPart", true)
	if anchorPart and anchorPart:IsA("BasePart") then
		return anchorPart
	end

	local anchor = instance:FindFirstChild("GroundAnchor", true) or instance:FindFirstChild("Attachment1", true)
	if anchor and anchor:IsA("Attachment") then
		return anchor
	end

	return nil
end

-- 平移一个特效实例；Model 用 PivotTo，Part 容器则逐个移动所有 BasePart 子孙。
local function translateVFXInstance(instance, delta)
	if not instance or not delta then return end

	if instance:IsA("Model") then
		instance:PivotTo(instance:GetPivot() + delta)
		return
	end

	if instance:IsA("BasePart") then
		instance.CFrame = instance.CFrame + delta
	end

	for _, child in ipairs(instance:GetDescendants()) do
		if child:IsA("BasePart") then
			child.CFrame = child.CFrame + delta
		end
	end
end

-- 将圣光特效放到目标位置；如果存在 AnchorPart/贴地 Attachment，就让它精准贴到怪物脚底。
local function placeSmiteVFX(instance, groundPos)
	if not instance or not groundPos then return end

	local anchor = getSmiteGroundAnchor(instance)
	if anchor then
		local anchorPos = anchor:IsA("Attachment") and anchor.WorldPosition or anchor.Position
		translateVFXInstance(instance, groundPos - anchorPos)
		return
	end

	if instance:IsA("Model") then
		instance:PivotTo(CFrame.new(groundPos) * instance:GetPivot().Rotation)
	elseif instance:IsA("BasePart") then
		instance.CFrame = CFrame.new(groundPos) * instance.CFrame.Rotation
	end
end

-- 根据当前局内增益计算风刃的实际宽度，并受配置上限约束。
local function getWindBladeWidth(petConfig)
	local baseWidth = petConfig.WindBladeBaseWidth or 20
	local maxWidth = petConfig.WindBladeMaxWidth or 40
	local rangeBonus = player:GetAttribute("WindBlade_Range_Bonus") or 0
	return math.min(baseWidth * (1 + (rangeBonus / 100)), maxWidth)
end

-- 计算屏幕中心对应的世界坐标，让风刃从玩家视野中央出现。
local function getScreenCenterSpawnPos(fallbackPos)
	local currentCamera = Workspace.CurrentCamera or camera
	if not currentCamera then
		return fallbackPos
	end

	-- 用屏幕中心射线投到当前高度平面上，让风刃看起来从画面中央飞出。
	local viewportSize = currentCamera.ViewportSize
	local centerRay = currentCamera:ViewportPointToRay(viewportSize.X / 2, viewportSize.Y / 2)
	local directionY = centerRay.Direction.Y
	if math.abs(directionY) < 0.001 then
		return fallbackPos
	end

	local t = (fallbackPos.Y - centerRay.Origin.Y) / directionY
	if t <= 0 then
		return fallbackPos
	end

	local spawnPos = centerRay.Origin + centerRay.Direction * t
	return Vector3.new(spawnPos.X, fallbackPos.Y, spawnPos.Z)
end

-- 按风刃范围缩放子弹模型的 X 尺寸，兼容 Part 和 Model 两种预制体。
local function resizeWindBladeBullet(bullet, targetWidth, baseWidth)
	local scaleX = targetWidth / math.max(baseWidth, 0.001)

	-- Studio 里的风刃模型以 X=baseWidth 为初始尺寸；这里只按 X 轴拉宽。
	if bullet:IsA("BasePart") then
		bullet.Size = Vector3.new(targetWidth, bullet.Size.Y, bullet.Size.Z)
		return
	end

	for _, part in ipairs(bullet:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Size = Vector3.new(part.Size.X * scaleX, part.Size.Y, part.Size.Z)
		end
	end
end

-- 收集当前角色身上的宠物本体和分身，并返回稳定的开火顺序。
local function getPetFireOrder(character)
	local activePets = {}

	for _, child in ipairs(character:GetChildren()) do
		if child.Name == "ActivePet" or string.match(child.Name, "^ActivePet_Clone") then
			table.insert(activePets, child)
		end
	end

	-- 固定发射顺序：本体优先，分身按编号依次开火。
	table.sort(activePets, function(a, b)
		if a.Name == "ActivePet" then return true end
		if b.Name == "ActivePet" then return false end

		local aIndex = tonumber(string.match(a.Name, "ActivePet_Clone_(%d+)")) or math.huge
		local bIndex = tonumber(string.match(b.Name, "ActivePet_Clone_(%d+)")) or math.huge
		return aIndex < bIndex
	end)

	return activePets
end

-- 根据宠物编号和总数量计算跟随阵型位置，避免 4、5 只宠物时互相重叠。
local function getPetFormationCFrame(rootPart, petIndex, totalCount, inCombat)
	local height = inCombat and 2.2 or 2.5
	local baseRadius = inCombat and 5 or 4
	local minAngle = math.rad(-65)
	local maxAngle = math.rad(65)

	if totalCount <= 1 then
		if inCombat then
			return rootPart.CFrame * CFrame.new(5, height, -2)
		end

		return rootPart.CFrame * CFrame.new(-4, height, 4)
	end

	local t = (petIndex - 1) / math.max(totalCount - 1, 1)
	local angle = minAngle + (maxAngle - minAngle) * t
	local radius = baseRadius + math.floor((petIndex - 1) / 5) * 1.5
	local xOffset = math.sin(angle) * radius
	local zOffset = math.cos(angle) * radius

	if inCombat then
		zOffset = zOffset - 1
	end

	return rootPart.CFrame * CFrame.new(xOffset, height, zOffset)
end

function PetController.Init(deps)
	Controllers = deps
end

-- 启动宠物系统：监听装备变化、驱动宠物跟随，并在战斗中按节奏触发宠物攻击。
function PetController.Start()
	player:GetAttributeChangedSignal("EquippedPet"):Connect(PetController.RefreshPetModel)
	player.CharacterAdded:Connect(function()
		-- 等角色骨架和 HumanoidRootPart 完成创建后再刷新宠物。
		task.wait(0.1)
		PetController.RefreshPetModel()
	end)
	PetController.RefreshPetModel()

	-- 每帧更新宠物位置，让宠物在战斗中跟随在玩家前侧，非战斗时回到待机位置。
	RunService.RenderStepped:Connect(function(dt)
		if not currentPetModel or not player.Character then return end
		local rootPart = player.Character:FindFirstChild("HumanoidRootPart")
		if not rootPart then return end

		local petCount = player:GetAttribute("Pet_Count") or 1
		local targetCFrame = getPetFormationCFrame(rootPart, 1, petCount, Controllers.Game.IsCombatActive)

		local currentPivot = currentPetModel:GetPivot()
		currentPetModel:PivotTo(currentPivot:Lerp(targetCFrame, dt * 5))
	end)

	-- 战斗循环：按宠物攻速与分身数量依次触发开火，并对多宠物发射做轻微错峰。
	task.spawn(function()
		while true do
			if Controllers.Game.IsCombatActive and not player:GetAttribute("IsLevelingUp") then
				local equippedPet = player:GetAttribute("EquippedPet")
				if not equippedPet or equippedPet == "" then task.wait(1); continue end

				local petConfig = Controllers.Config.PETS and Controllers.Config.PETS[equippedPet]
				if not petConfig then task.wait(1); continue end

				local character = player.Character
				if not character then task.wait(1); continue end

				local activePets = getPetFireOrder(character)
				if #activePets == 0 then task.wait(1); continue end

				local aspdBonus = player:GetAttribute("Pet_ASPD_Bonus") or 0
				local baseCooldown = petConfig.Cooldown or 2
				local actualCooldown = baseCooldown / (1 + (aspdBonus / 100))
				local castCount = petConfig.CastCount or 1
				local petStaggerDelay = Controllers.Config.PET_FIRE_STAGGER_DELAY or 0.12
				local castStaggerDelay = Controllers.Config.PET_CAST_STAGGER_DELAY or 0.15

				for i = 1, castCount do
					if not Controllers.Game.IsCombatActive then break end

					for petIndex, pModel in ipairs(activePets) do
						if not Controllers.Game.IsCombatActive or player:GetAttribute("IsLevelingUp") then break end
						PetController.ShootProjectile(petConfig, pModel)
						if petIndex < #activePets then
							task.wait(petStaggerDelay)
						end
					end

					if i < castCount then
						task.wait(castStaggerDelay)
					end
				end

				local staggerTime = math.max(0, (#activePets - 1) * petStaggerDelay)
				local remainingCooldown = math.max(0.05, actualCooldown - staggerTime)
				task.wait(remainingCooldown)
			else
				task.wait(0.5)
			end
		end
	end)
end

-- 刷新当前出战宠物模型；优先使用 Studio 资源，缺失时回退到白模 Part。
function PetController.RefreshPetModel()
	if currentPetModel then currentPetModel:Destroy() end
	local equipped = player:GetAttribute("EquippedPet")
	if not equipped or equipped == "" then return end

	local petConfig = Controllers.Config.PETS[equipped]
	if not petConfig then return end

	local character = player.Character
	if not character then return end

	local modelFolder = ReplicatedStorage:FindFirstChild("Model")
	local petModels = modelFolder and modelFolder:FindFirstChild("Pets")
	local petTemplate = petModels and petModels:FindFirstChild(equipped)

	if petTemplate then
		currentPetModel = petTemplate:Clone()
		prepareMovableModel(currentPetModel)
		currentPetModel.Parent = Workspace
	else
		currentPetModel = Instance.new("Part")
		currentPetModel.Size = Vector3.new(2, 2, 2)
		currentPetModel.Color = petConfig.Color or Color3.fromRGB(255, 255, 255)
		currentPetModel.Anchored = true
		currentPetModel.CanCollide = false
		currentPetModel.Material = Enum.Material.Neon
		currentPetModel.Parent = Workspace
	end

	currentPetModel.Name = "ActivePet"
	currentPetModel.Parent = character

	if Controllers.Pet and Controllers.Pet.UpdatePetClones then
		Controllers.Pet.UpdatePetClones()
	end
end

-- 发射宠物子弹/技能：负责索敌、生成预制体或白模，并把命中数据注册到战斗系统。
function PetController.ShootProjectile(petConfig, petModel)
	local petPos = petModel:GetPivot().Position
	local playerPos = player.Character and player.Character.PrimaryPart and player.Character.PrimaryPart.Position or petPos
	local spawnPos = playerPos + Vector3.new(0, 0, -2)
	local baseSpd = Controllers.Config.BASE_SPD
	local currentSpd = baseSpd * (1 + ((player:GetAttribute("SPD_Bonus") or 0) / 100))
	local currentRng = Controllers.Config.BASE_RNG * (1 + ((player:GetAttribute("RNG_Bonus") or 0) / 100))
	local actualLifetime = currentRng / currentSpd

	local atkBonus = player:GetAttribute("Pet_ATK_Bonus") or 0
	local petDmg = (petConfig.ATK or 10) * (1 + (atkBonus / 100))
	local skillType = petConfig.SkillType or "WindBlade"
	local bulletVfxName = petConfig.BulletVFX
	local hitVfx = petConfig.HitVFX
	local pierce = petConfig.PierceCount or 1
	local aoe = petConfig.AOERadius
	local windBladeBaseWidth = petConfig.WindBladeBaseWidth or 20
	local windBladeWidth = getWindBladeWidth(petConfig)
	local smiteWarningTime = Controllers.Config.SMITE_WARNING_TIME or 0.5
	local smiteHitWindow = Controllers.Config.SMITE_HIT_WINDOW or 0.08

	if skillType == "WindBlade" then
		local character = player.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		local fallbackPos = rootPart and (rootPart.Position + Vector3.new(0, 2, -2)) or spawnPos
		spawnPos = getScreenCenterSpawnPos(fallbackPos)
		playerPos = spawnPos
	end

	local targetReferencePos = playerPos
	if skillType == "Smite" then
		local character = player.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if rootPart then
			targetReferencePos = rootPart.Position
		end
	end

	-- 搜索前方最近的有效怪物，供火龙追踪和天使神罚使用。
	local enemies = Controllers.Encounter.ActiveEnemies
	local targetEnemy = nil
	local minDistance = math.huge

	for _, enemy in ipairs(enemies) do
		if enemy and enemy.part and enemy.part.Parent and enemy.hp > 0 then
			local enemyPos = enemy.part.Position
			if enemyPos.Z < targetReferencePos.Z then
				local dist = (enemyPos - targetReferencePos).Magnitude
				if dist < minDistance then
					minDistance = dist
					targetEnemy = enemy
				end
			end
		end
	end

	local smiteTargetPos = nil
	if skillType == "Smite" then
		if not targetEnemy then return end
		-- 圣光预警以怪物脚底为落点，便于美术法阵贴地显示。
		smiteTargetPos = targetEnemy.part.Position - Vector3.new(0, targetEnemy.part.Size.Y / 2, 0)
		actualLifetime = smiteWarningTime + smiteHitWindow
	end

	local vfxFolder = ReplicatedStorage:FindFirstChild("VFX")
	local petsVfxFolder = vfxFolder and vfxFolder:FindFirstChild("Pets")
	local bulletPrefab = (petsVfxFolder and bulletVfxName) and petsVfxFolder:FindFirstChild(bulletVfxName) or nil
	local bullet

	if bulletPrefab then
		-- 有美术资源时优先使用预制体。
		bullet = bulletPrefab:Clone()
		local mainPart = getFirstBasePart(bullet)
		if bullet:IsA("Model") and not bullet.PrimaryPart and mainPart then
			bullet.PrimaryPart = mainPart
		end

		if not mainPart then
			bullet:Destroy()
			return
		end

		setProjectilePhysics(bullet, skillType == "Smite" and smiteTargetPos ~= nil)
		if skillType == "WindBlade" then
			resizeWindBladeBullet(bullet, windBladeWidth, windBladeBaseWidth)
		end

		if skillType == "Smite" and smiteTargetPos then
			-- 天使圣光优先使用 AnchorPart 贴地，避免 Pivot 不准导致法阵看不到。
			placeSmiteVFX(bullet, smiteTargetPos)
			mainPart.Anchored = true
		else
			bullet:PivotTo(CFrame.new(spawnPos))

			local att = Instance.new("Attachment", mainPart)
			local bv = Instance.new("LinearVelocity")
			bv.Attachment0 = att
			bv.RelativeTo = Enum.ActuatorRelativeTo.World
			bv.VectorVelocity = Vector3.new(0, 0, -currentSpd)
			bv.MaxForce = math.huge
			bv.Parent = mainPart

			if skillType == "Fireball" and targetEnemy then
				-- 小火龙保留追踪逻辑，让弹体持续修正飞行方向。
				task.spawn(function()
					while bullet and bullet.Parent and targetEnemy and targetEnemy.part and targetEnemy.part.Parent and targetEnemy.hp > 0 do
						local currentPos = mainPart.Position
						local targetPos = targetEnemy.part.Position
						local dir = (targetPos - currentPos).Unit
						bv.VectorVelocity = dir * (currentSpd * 2)
						task.wait(0.05)
					end
				end)
			end
		end
	else
		-- 没有资源时使用白模兜底，确保宠物技能不会因资源缺失而失效。
		bullet = Instance.new("Part")
		bullet.Anchored = false
		bullet.CanCollide = false
		bullet.Material = Enum.Material.Neon
		bullet.Color = petConfig.Color or Color3.fromRGB(255, 255, 255)

		if skillType == "Smite" and smiteTargetPos then
			-- 神罚白模仍然使用直立光柱，方便调试和确认命中范围。
			bullet.Size = Vector3.new(4, 40, 4)
			bullet.Shape = Enum.PartType.Cylinder
			bullet.CFrame = CFrame.new(smiteTargetPos) * CFrame.Angles(0, 0, math.rad(90))
			bullet.Anchored = true
		else
			if skillType == "WindBlade" then
				bullet.Size = Vector3.new(windBladeWidth, 1, 3)
				bullet.Shape = Enum.PartType.Block
			elseif skillType == "Fireball" then
				bullet.Size = Vector3.new(4, 4, 4)
				bullet.Shape = Enum.PartType.Ball
			else
				bullet.Size = Vector3.new(3, 1, 3)
				bullet.Shape = Enum.PartType.Block
			end

			bullet.CFrame = CFrame.new(spawnPos)
			local att = Instance.new("Attachment", bullet)
			local bv = Instance.new("LinearVelocity")
			bv.Attachment0 = att
			bv.RelativeTo = Enum.ActuatorRelativeTo.World
			bv.VectorVelocity = Vector3.new(0, 0, -currentSpd)
			bv.MaxForce = math.huge
			bv.Parent = bullet

			if skillType == "Fireball" and targetEnemy then
				task.spawn(function()
					while bullet and bullet.Parent and targetEnemy and targetEnemy.part and targetEnemy.part.Parent and targetEnemy.hp > 0 do
						local currentPos = bullet.Position
						local targetPos = targetEnemy.part.Position
						local dir = (targetPos - currentPos).Unit
						bv.VectorVelocity = dir * (currentSpd * 1.2)
						task.wait(0.05)
					end
				end)
			end
		end
	end

	local localProjectiles = Workspace:FindFirstChild("LocalProjectiles") or Instance.new("Folder", Workspace)
	bullet.Parent = localProjectiles
	game.Debris:AddItem(bullet, actualLifetime)

	local bulletPart = getFirstBasePart(bullet)
	if skillType == "Smite" and smiteTargetPos then
		-- 圣光伤害使用独立透明命中盒，避免美术特效层级/Pivot/AnchorPart 影响实际判定。
		local smiteHitbox = Instance.new("Part")
		local smiteHitboxRadius = math.max(4, aoe or 8)
		smiteHitbox.Name = "SmiteHitbox"
		smiteHitbox.Size = Vector3.new(smiteHitboxRadius * 2, 1, smiteHitboxRadius * 2)
		smiteHitbox.CFrame = CFrame.new(smiteTargetPos)
		smiteHitbox.Anchored = true
		smiteHitbox.CanCollide = false
		smiteHitbox.Transparency = 1
		smiteHitbox.Parent = bullet
		bulletPart = smiteHitbox
	end

	if not bulletPart then
		bullet:Destroy()
		return
	end

	local function registerPetBulletHit()
		if not Controllers.Game.IsCombatActive then return end
		if not bulletPart or not bulletPart.Parent then return end

		table.insert(Controllers.Combat.ActiveBullets, {
			part = bulletPart,
			damage = petDmg,
			weaponId = "PetWeapon",
			hitsLeft = pierce,
			hitTargets = {},
			hitVFX = hitVfx,
			hitVFXPosition = (skillType == "Smite") and smiteTargetPos or nil,
			aoeRadius = aoe,
			isPet = true,
			persistAfterHit = (skillType == "Smite"),
		})
	end

	if skillType == "Smite" then
		-- 天使圣光先作为预警出现，0.5 秒后才注册命中，避免光柱刚出现就立刻扣血。
		task.delay(smiteWarningTime, registerPetBulletHit)
	else
		registerPetBulletHit()
	end
end

-- 根据当前宠物数量刷新分身，并让分身以固定偏移跟随玩家。
function PetController.UpdatePetClones()
	local character = player.Character
	if not character then return end

	local mainPet = character:FindFirstChild("ActivePet")
	if not mainPet then return end

	local targetCount = player:GetAttribute("Pet_Count") or 1

	-- 先清理旧分身，避免数量变化后残留。
	for _, child in ipairs(character:GetChildren()) do
		if string.match(child.Name, "^ActivePet_Clone") then
			child:Destroy()
		end
	end

	for i = 2, targetCount do
		local clone = mainPet:Clone()
		clone.Name = "ActivePet_Clone_" .. i
		clone.Parent = character

		task.spawn(function()
			local connection
			connection = RunService.Heartbeat:Connect(function(dt)
				if not clone or not clone.Parent or not character or not character.PrimaryPart then
					connection:Disconnect()
					return
				end

				local targetCountNow = player:GetAttribute("Pet_Count") or targetCount
				local targetCFrame = getPetFormationCFrame(character.PrimaryPart, i, targetCountNow, Controllers.Game.IsCombatActive)

				clone:PivotTo(clone:GetPivot():Lerp(targetCFrame, 8 * dt))
			end)
		end)
	end
end

return PetController
