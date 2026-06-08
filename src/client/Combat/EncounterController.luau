-- 遭遇实体生成与管理模块：负责刷怪、属性门、掉落物生成和磁吸拾取。
local EncounterController = {}

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local player = Players.LocalPlayer

local Controllers

EncounterController.ActiveEnemies = {}
EncounterController.ActiveGateGroups = {}
EncounterController.ActiveDrops = {}

local currentStage = 1
local stageConfig = nil
local stageEndZ = 0
local elitePositions = {}
local bossZ = nil
local nextGateZ = 0
local nextMobZ = 0
local DROP_MODEL_CANDIDATES = {
	Coin = {"Coin", "Gold", "CoinDrop", "GoldDrop"},
	Exp = {"Exp", "Experience", "ExpDrop", "ExperienceDrop", "ExpOrb", "ExperienceOrb"},
}
local gateZones = {}
local enemyZones = {}
local activeStageZones = {}

-- 清理已经远离玩家的门/怪占位区，避免占位表无限增长。
local function CleanupZones(currentStartZ)
	local function cleanupZoneList(zoneList)
		for i = #zoneList, 1, -1 do
			if zoneList[i].z > currentStartZ + 200 then
				table.remove(zoneList, i)
			end
		end
	end

	cleanupZoneList(gateZones)
	cleanupZoneList(enemyZones)
end

-- 判断目标 Z 坐标是否和指定占位区冲突。
local function hasZoneConflict(zPos, requiredGap, zoneList, extraBuffer)
	local buffer = extraBuffer or 0
	for _, zone in ipairs(zoneList) do
		if math.abs(zPos - zone.z) < (requiredGap + zone.gap + buffer) then
			return true
		end
	end

	return false
end

-- 判断目标 Z 坐标是否落入 Boss 安全区，门和普通怪都需要避让。
local function isBlockedByBoss(zPos)
	local Config = Controllers.Config
	local bossBlockGap = Config.BOSS_GATE_BLOCK_GAP or 60
	if bossZ ~= nil and math.abs(zPos - bossZ) < bossBlockGap then
		return true
	end

	return stageConfig ~= nil and stageConfig.HasBoss and zPos <= stageEndZ + bossBlockGap
end

-- 记录一组属性门的安全区，后续怪物生成会避开它。
local function registerGateZone(zPos)
	local Config = Controllers.Config
	table.insert(gateZones, {
		z = zPos,
		gap = Config.GATE_SAFE_GAP or 28,
	})
end

-- 记录怪物占位区，防止同一段跑道内怪物互相重叠。
local function registerEnemyZone(zPos, requiredGap)
	table.insert(enemyZones, {
		z = zPos,
		gap = requiredGap,
	})
end

-- 在当前生成区间内为怪物寻找可用 Z 坐标；撞到门或 Boss 时尝试有限次数偏移。
local function FindEnemyZInGateGap(desiredZ, requiredGap, blockStartZ, blockEndZ)
	local Config = Controllers.Config
	local maxTries = Config.ENCOUNTER_MAX_REPOSITION_TRIES or 6
	local gateBuffer = Config.MOB_GATE_BUFFER or 8
	local gateInterval = (stageConfig and stageConfig.GateInterval) or 90
	local step = math.max(6, math.floor(gateInterval / math.max(maxTries, 1)))

	local function canUseZ(candidateZ)
		if candidateZ > blockStartZ or candidateZ <= blockEndZ then
			return false
		end

		if isBlockedByBoss(candidateZ) then
			return false
		end

		if hasZoneConflict(candidateZ, requiredGap, gateZones, gateBuffer) then
			return false
		end

		if hasZoneConflict(candidateZ, requiredGap, enemyZones, 0) then
			return false
		end

		return true
	end

	if canUseZ(desiredZ) then
		registerEnemyZone(desiredZ, requiredGap)
		return desiredZ
	end

	for i = 1, maxTries do
		local forwardZ = desiredZ - (step * i)
		if canUseZ(forwardZ) then
			registerEnemyZone(forwardZ, requiredGap)
			return forwardZ
		end

		local backwardZ = desiredZ + (step * i)
		if canUseZ(backwardZ) then
			registerEnemyZone(backwardZ, requiredGap)
			return backwardZ
		end
	end

	return nil
end

-- 读取并初始化当前关卡配置，包括关卡长度、门/怪刷新指针、精英怪和 Boss 位置。
local function LoadStageConfig(stageNum, startZ)
	local Config = Controllers.Config

	stageConfig = Config.STAGES[stageNum] or Config.STAGES[#Config.STAGES]

	stageEndZ = startZ - stageConfig.Length

	nextGateZ = startZ - 50 - stageConfig.GateInterval
	nextMobZ = startZ - 50 - stageConfig.MobInterval

	elitePositions = {}
	if stageConfig.EliteCount > 0 then
		local step = stageConfig.Length / (stageConfig.EliteCount + 1)
		for i = 1, stageConfig.EliteCount do
			table.insert(elitePositions, startZ - step * i)
		end
	end

	bossZ = stageConfig.HasBoss and stageEndZ or nil

	table.insert(activeStageZones, {
		stage = stageNum,
		endZ = stageEndZ
	})
	print(string.format(">>> 已加载第 %d 关：起点 %d，终点 %d <<<", stageNum, math.floor(startZ), math.floor(stageEndZ)))
end

-- 根据玩家当前位置更新真实关卡编号，供 UI 和属性同步使用。
function EncounterController.UpdatePlayerStage(playerZ)
	while #activeStageZones > 1 and playerZ < activeStageZones[1].endZ do
		table.remove(activeStageZones, 1)
	end

	if #activeStageZones > 0 then
		local realStage = activeStageZones[1].stage

		if player:GetAttribute("CurrentStage") ~= realStage then
			player:SetAttribute("CurrentStage", realStage)
			print(">>> 玩家进入第 " .. tostring(realStage) .. " 关 <<<")
		end
	end
end

-- 初始化遭遇模块依赖。
function EncounterController.Init(deps)
	Controllers = deps
end

-- 重置遭遇生成指针，通常在新一局跑酷开始时调用。
function EncounterController.ResetPointers(startZ)
	gateZones = {}
	enemyZones = {}
	activeStageZones = {}
	currentStage = 1
	LoadStageConfig(currentStage, startZ)
end

-- 创建单个属性门 Part，并挂载 3D 数值文字。
local function CreateGate(xOffset, gateWidth, zPos, trackStartX, trackSurfaceY, isBuff)
	local Config = Controllers.Config
	local currentStageConfig = stageConfig or Config.STAGES[1]

	local attributes = Config.GATE_ATTRIBUTE_POOL
	local attr = attributes[math.random(1, #attributes)]

	local amount = 0
	if attr == "HP_Bonus" then
		amount = math.random(currentStageConfig.GATE_HP_BONUS_MIN or 10, currentStageConfig.GATE_HP_BONUS_MAX or 30)
	elseif attr == "MaxHP_Bonus" then
		amount = math.random(currentStageConfig.GATE_MAXHP_BONUS_MIN or 5, currentStageConfig.GATE_MAXHP_BONUS_MAX or 15)
	elseif attr == "ATK_Bonus" then
		amount = math.random(currentStageConfig.GATE_ATK_BONUS_MIN or 5, currentStageConfig.GATE_ATK_BONUS_MAX or 15)
	elseif attr == "ASPD_Bonus" then
		amount = math.random(currentStageConfig.GATE_ASPD_BONUS_MIN or 5, currentStageConfig.GATE_ASPD_BONUS_MAX or 15)
	elseif attr == "SPD_Bonus" then
		amount = math.random(currentStageConfig.GATE_SPD_BONUS_MIN or 5, currentStageConfig.GATE_SPD_BONUS_MAX or 20)
	elseif attr == "RNG_Bonus" then
		amount = math.random(currentStageConfig.GATE_RNG_BONUS_MIN or 5, currentStageConfig.GATE_RNG_BONUS_MAX or 20)
	elseif attr == "LateralSpeed_Bonus" then
		amount = math.random(Config.GATE_LATERAL_SPEED_BONUS_MIN or 12, Config.GATE_LATERAL_SPEED_BONUS_MAX or 12)
	end

	if not isBuff then amount = -amount end

	local gate = Instance.new("Part")
	gate.Size = Vector3.new(gateWidth, 10, 2)
	gate.Position = Vector3.new(trackStartX + xOffset, trackSurfaceY + (gate.Size.Y / 2), zPos)
	gate.Anchored = true
	gate.CanCollide = false
	gate.Transparency = 0.6
	gate.Material = Enum.Material.Neon
	gate.Color = isBuff and Color3.fromRGB(0, 255, 0) or Color3.fromRGB(255, 0, 0)

	local sign = amount > 0 and "+" or ""
	local displayName = (Config.ATTRIBUTE_NAMES_CN and Config.ATTRIBUTE_NAMES_CN[attr]) or attr

	local percentageSuffix = string.find(attr, "Bonus") and "%" or ""

	local text = string.format("%s\n%s%s%s", displayName, sign, tostring(amount), percentageSuffix)

	Controllers.VFX.CreateBillboard(gate, text, Color3.new(1,1,1), -(gate.Size.Y / 2))

	local folder = Workspace:FindFirstChild("LocalEncounters") or Instance.new("Folder", Workspace)
	folder.Name = "LocalEncounters"
	gate.Parent = folder

	return { part = gate, attr = attr, amount = amount }
end

-- 根据怪物类型返回用于战斗判定的碰撞盒尺寸。
local function getEnemyHitboxSize(enemyType, Config)
	if enemyType == "Basic" then
		return Vector3.new(4, 4, 4)
	elseif enemyType == "Elite" then
		return Vector3.new(Config.RUNWAY_LIMIT * 2, 8, 8)
	elseif enemyType == "Boss" then
		return Vector3.new(Config.RUNWAY_LIMIT * 2, 16, 16)
	end

	return Vector3.new(4, 4, 4)
end

-- 当 Studio 模型缺失时，返回白模怪物的兜底颜色。
local function getEnemyFallbackColor(enemyType)
	if enemyType == "Elite" then
		return Color3.fromRGB(128, 0, 128)
	elseif enemyType == "Boss" then
		return Color3.fromRGB(255, 0, 0)
	end

	return Color3.fromRGB(0, 0, 255)
end

-- 从 ReplicatedStorage 中查找怪物模型模板。
local function getEnemyModelTemplate(enemyType, Config)
	local modelFolder = ReplicatedStorage:FindFirstChild("Model")
	local enemiesFolder = modelFolder and modelFolder:FindFirstChild("Enemies")
	if not enemiesFolder then return nil end

	local modelName = (Config.ENEMY_MODELS and Config.ENEMY_MODELS[enemyType]) or enemyType
	return enemiesFolder:FindFirstChild(modelName)
end

-- 准备怪物展示模型，统一关闭碰撞并补齐 PrimaryPart。
local function prepareEnemyVisual(visual)
	if not visual then return nil end

	if visual:IsA("Model") then
		if not visual.PrimaryPart then
			visual.PrimaryPart = visual:FindFirstChildWhichIsA("BasePart", true)
		end

		for _, obj in ipairs(visual:GetDescendants()) do
			if obj:IsA("BasePart") then
				obj.Anchored = true
				obj.CanCollide = false
				obj.CanTouch = false
				obj.CanQuery = false
			end
		end

		return visual.PrimaryPart and visual or nil
	elseif visual:IsA("BasePart") then
		visual.Anchored = true
		visual.CanCollide = false
		visual.CanTouch = false
		visual.CanQuery = false
		return visual
	end

	return nil
end

-- 查找美术模型中的贴地标记，用于让模型底部对齐跑道表面。
local function findEnemyGroundMarker(visual)
	if not visual or not visual:IsA("Model") then return nil end

	local partNames = {"GroundPart", "FakeRootPart", "RootPart"}
	for _, name in ipairs(partNames) do
		local marker = visual:FindFirstChild(name, true)
		if marker and marker:IsA("BasePart") then
			return marker
		end
	end

	return nil
end

-- 计算怪物模型当前用于贴地的 Y 坐标。
local function getEnemyGroundY(visual)
	if not visual then return 0 end

	if visual:IsA("Model") then
		local marker = findEnemyGroundMarker(visual)
		if marker then
if marker.Name == "GroundPart" then
				return marker.Position.Y - (marker.Size.Y / 2)
			end

			return marker.Position.Y
		end

		local boundsCFrame, boundsSize = visual:GetBoundingBox()
		return boundsCFrame.Position.Y - (boundsSize.Y / 2)
	elseif visual:IsA("BasePart") then
		return visual.Position.Y - (visual.Size.Y / 2)
	end

	return 0
end

-- 将怪物展示模型移动到隐藏碰撞盒位置，并按跑道表面对齐高度。
local function pivotEnemyVisualToHitbox(visual, hitbox, trackSurfaceY)
	if not visual or not hitbox then return end

	if visual:IsA("Model") then
		local templateRotation = visual:GetPivot().Rotation
		visual:PivotTo(CFrame.new(hitbox.Position) * templateRotation)
		local groundY = getEnemyGroundY(visual)
		visual:PivotTo(visual:GetPivot() + Vector3.new(0, trackSurfaceY - groundY, 0))
	elseif visual:IsA("BasePart") then
		local templateRotation = visual.CFrame.Rotation
		visual.CFrame = CFrame.new(hitbox.Position) * templateRotation
		local groundY = getEnemyGroundY(visual)
		visual.CFrame = visual.CFrame + Vector3.new(0, trackSurfaceY - groundY, 0)
	end
end

-- 创建怪物展示模型；模型缺失时返回 nil，由隐藏碰撞盒兜底表现。
local function createEnemyVisual(enemyType, hitbox, trackSurfaceY, Config)
	local template = getEnemyModelTemplate(enemyType, Config)
	if not template then return nil end

	local visual = prepareEnemyVisual(template:Clone())
	if not visual then
		warn("[EncounterController] 怪物模型 " .. tostring(enemyType) .. " 缺少可用 BasePart，将使用兜底表现。")
		return nil
	end

	visual.Name = enemyType .. "Visual"
	visual.Parent = hitbox
	pivotEnemyVisualToHitbox(visual, hitbox, trackSurfaceY)
	return visual
end

-- 创建怪物战斗实体，包含碰撞盒、属性、展示模型和血条文字。
local function CreateEnemy(enemyType, xOffset, zPos, trackStartX, trackSurfaceY)
	local Config = Controllers.Config
	local enemy = Instance.new("Part")
	enemy.Name = enemyType .. "Hitbox"
	enemy.Anchored = true
	enemy.CanCollide = false
	enemy.CanTouch = false
	enemy.CanQuery = false
	enemy.Size = getEnemyHitboxSize(enemyType, Config)
	enemy.Color = getEnemyFallbackColor(enemyType)
	enemy.Material = Enum.Material.SmoothPlastic
	enemy.CastShadow = false

local currentStageConfig = stageConfig or Config.STAGES[#Config.STAGES]

	local hpMultiplier = 1
	if currentStage > 5 then
		local safeZoneLength = 0
		for i = 1, 5 do
			if Config.STAGES[i] then
				safeZoneLength = safeZoneLength + Config.STAGES[i].Length
			end
		end

		local effectiveDistance = math.abs(zPos) - safeZoneLength
		if effectiveDistance > 0 then
			hpMultiplier = 1 + math.floor(effectiveDistance / Config.ENEMY_HP_SCALE_DIST) * Config.ENEMY_HP_SCALE_RATE
		end
	end

	local hp = 0
	if enemyType == "Basic" then
local baseHP = currentStageConfig.BasicHP or 30
		hp = math.floor(baseHP * hpMultiplier)

	elseif enemyType == "Elite" then
		local baseHP = currentStageConfig.EliteHP or 150
		hp = math.floor(baseHP * hpMultiplier)
		xOffset = 0

	elseif enemyType == "Boss" then
		local baseHP = currentStageConfig.BossHP or 1000
		hp = math.floor(baseHP * hpMultiplier)
		xOffset = 0
	end

	enemy.Position = Vector3.new(trackStartX + xOffset, trackSurfaceY + (enemy.Size.Y / 2), zPos)

	local folder = Workspace:FindFirstChild("LocalEncounters") or Instance.new("Folder", Workspace)
	folder.Name = "LocalEncounters"
	enemy.Parent = folder

	local enemyVisual = createEnemyVisual(enemyType, enemy, trackSurfaceY, Config)
	if enemyVisual then
		enemy.Transparency = 1
	else
		enemy.Transparency = 0
	end

	local hpLabel = Controllers.VFX.CreateBillboard(enemy, Controllers.Config.FormatNumber(hp), Color3.new(1,1,1), -enemy.Size.Y + 1)

	table.insert(EncounterController.ActiveEnemies, {
		part = enemy,
		hp = hp,
		maxHp = hp,
		label = hpLabel,
		type = enemyType,
		baseSize = enemy.Size,
		visual = enemyVisual
	})
end

-- 在指定跑道区间内生成 Boss、属性门、精英怪和普通怪。
function EncounterController.SpawnEncountersInBlock(startZ, endZ, trackStartX, trackSurfaceY)
	local Config = Controllers.Config

	CleanupZones(startZ)

if bossZ and bossZ <= startZ and bossZ > endZ then
		local finalZ = bossZ
		CreateEnemy("Boss", 0, finalZ, trackStartX, trackSurfaceY)
		registerEnemyZone(finalZ, 40)
		bossZ = nil
	end

while nextGateZ <= startZ and nextGateZ > endZ do
		if not isBlockedByBoss(nextGateZ) then
			local finalZ = nextGateZ

local currentStageConfig = stageConfig
			local buffChance = currentStageConfig.GateBuffChance or 0.5

			local leftIsBuff = math.random() <= buffChance
			local rightIsBuff = math.random() <= buffChance

			if not leftIsBuff and not rightIsBuff then
				if math.random() > 0.5 then
					leftIsBuff = true
				else
					rightIsBuff = true
				end
			end

			local gateGap = 2
			local gateWidth = Config.RUNWAY_LIMIT - (gateGap / 2)

			local leftOffset = -(gateGap / 2 + gateWidth / 2)
			local rightOffset = (gateGap / 2 + gateWidth / 2)

			local leftGate = CreateGate(leftOffset, gateWidth, finalZ, trackStartX, trackSurfaceY, leftIsBuff)
			local rightGate = CreateGate(rightOffset, gateWidth, finalZ, trackStartX, trackSurfaceY, rightIsBuff)

			table.insert(EncounterController.ActiveGateGroups, { left = leftGate, right = rightGate, z = finalZ })
			registerGateZone(finalZ)
		end
		nextGateZ = nextGateZ - stageConfig.GateInterval
	end

for i = #elitePositions, 1, -1 do
		local ez = elitePositions[i]
		if ez <= startZ and ez > endZ then
			local finalZ = FindEnemyZInGateGap(ez, 30, startZ, endZ)
			if finalZ then
				CreateEnemy("Elite", 0, finalZ, trackStartX, trackSurfaceY)
			end
			table.remove(elitePositions, i)
		end
	end

while nextMobZ <= startZ and nextMobZ > endZ do
		if not isBlockedByBoss(nextMobZ) then
			local finalZ = FindEnemyZInGateGap(nextMobZ, 15, startZ, endZ)
			local numMobs = math.random(stageConfig.MobsPerGroup[1], stageConfig.MobsPerGroup[2])

			if finalZ then
				local margin = 4
				local usableWidth = (Config.RUNWAY_LIMIT * 2) - (margin * 2)

				for i = 1, numMobs do
					local offsetX = 0

					if numMobs > 1 then
						local fraction = (i - 1) / (numMobs - 1)
						offsetX = -Config.RUNWAY_LIMIT + margin + (usableWidth * fraction)
					else
						offsetX = math.random(-Config.RUNWAY_LIMIT + margin, Config.RUNWAY_LIMIT - margin)
					end

					local jitterX = (numMobs > 1) and (math.random() * 2 - 1) or 0
					local jitterZ = math.random(-2, 2)

					CreateEnemy("Basic", offsetX + jitterX, finalZ + jitterZ, trackStartX, trackSurfaceY)
				end
			end
		end
		nextMobZ = nextMobZ - stageConfig.MobInterval
	end

	if endZ < stageEndZ then
		currentStage = currentStage + 1
		local nextStageStartZ = stageEndZ - 100
		LoadStageConfig(currentStage, nextStageStartZ)

		if endZ < nextStageStartZ then
			EncounterController.SpawnEncountersInBlock(nextStageStartZ, endZ, trackStartX, trackSurfaceY)
		end
	end
end

-- 获取掉落物模型模板；优先查找 Drops，其次兼容 Loot/Pickups 文件夹。
local function getDropModelTemplate(dropType)
    local modelFolder = ReplicatedStorage:FindFirstChild("Model")
    if not modelFolder then return nil end

    local candidateFolders = {
        modelFolder:FindFirstChild("Drops"),
        modelFolder:FindFirstChild("Loot"),
        modelFolder:FindFirstChild("Pickups"),
    }
    local candidateNames = DROP_MODEL_CANDIDATES[dropType] or {dropType}

    for _, folder in ipairs(candidateFolders) do
        if folder then
            for _, name in ipairs(candidateNames) do
                local template = folder:FindFirstChild(name)
                if template then
                    return template
                end
            end
        end
    end

    return nil
end

-- 准备掉落物实例，统一关闭碰撞并补齐模型 PrimaryPart。
local function prepareDropInstance(instance)
    if not instance then return nil, nil end

    local rootPart = instance:IsA("BasePart") and instance or instance:FindFirstChildWhichIsA("BasePart", true)
    if instance:IsA("Model") and not instance.PrimaryPart and rootPart then
        instance.PrimaryPart = rootPart
    end
    if not rootPart then return nil, nil end

    if instance:IsA("BasePart") then
        instance.Anchored = true
        instance.CanCollide = false
        instance.CanTouch = false
        instance.CanQuery = false
    end

    for _, obj in ipairs(instance:GetDescendants()) do
        if obj:IsA("BasePart") then
            obj.Anchored = true
            obj.CanCollide = false
            obj.CanTouch = false
            obj.CanQuery = false
        end
    end

    return instance, rootPart
end

-- 设置掉落物世界位置，并保留模型原始朝向。
local function setDropInstancePosition(instance, rootPart, position)
    if instance:IsA("Model") then
        instance:PivotTo(CFrame.new(position) * instance:GetPivot().Rotation)
    else
        rootPart.Position = position
    end
end

-- 销毁掉落物实例；模型掉落物会整体删除。
local function destroyDrop(drop)
    local instance = drop and (drop.instance or drop.part)
    if instance then
        instance:Destroy()
    end
end

-- 按位移移动掉落物，兼容 BasePart 和 Model。
local function moveDropBy(drop, delta)
    if not drop or not drop.part then return end

    if drop.instance and drop.instance:IsA("Model") then
        drop.instance:PivotTo(drop.instance:GetPivot() + delta)
    else
        drop.part.Position = drop.part.Position + delta
    end
end

-- 生成单个金币或经验掉落物，模型缺失时使用白模兜底。
local function SpawnSingleDrop(dropType, value, startPos)
    local dropTemplate = getDropModelTemplate(dropType)
    local dropInstance, rootPart

    if dropTemplate then
        dropInstance, rootPart = prepareDropInstance(dropTemplate:Clone())
        if not dropInstance or not rootPart then
            warn("[EncounterController] 掉落物模型 " .. tostring(dropType) .. " 缺少可用的 BasePart，已回退到白模。")
            dropTemplate = nil
        end
    end

    if not dropTemplate then
        local fallbackPart = Instance.new("Part")
        fallbackPart.Size = Vector3.new(1.5, 1.5, 1.5)
        fallbackPart.Anchored = true
        fallbackPart.CanCollide = false
        fallbackPart.CanTouch = false
        fallbackPart.CanQuery = false
        fallbackPart.Material = Enum.Material.Neon

        if dropType == "Coin" then
            fallbackPart.Color = Color3.fromRGB(255, 215, 0)
        else
            fallbackPart.Color = Color3.fromRGB(0, 255, 100)
        end

        dropInstance = fallbackPart
        rootPart = fallbackPart
    end

    setDropInstancePosition(dropInstance, rootPart, startPos)
    local localFolder = Workspace:FindFirstChild("LocalEncounters") or Instance.new("Folder", Workspace)
    localFolder.Name = "LocalEncounters"
    dropInstance.Parent = localFolder

    table.insert(EncounterController.ActiveDrops, {
        instance = dropInstance,
        part = rootPart,
        type = dropType,
        value = value,
        spawnTime = os.clock(),
    })

    Controllers.VFX.PlayDropExplosion(dropInstance, startPos)
end

-- 根据被击杀怪物类型生成金币和经验掉落物。
function EncounterController.TriggerDrops(enemyType, enemyPos)
    local Config = Controllers.Config
    local dropConfig = Config.ENEMY_DROPS[enemyType] or Config.ENEMY_DROPS["Basic"]
    local numDrops = dropConfig.NumDrops
    local totalExp = dropConfig.Exp
    local totalCoins = dropConfig.Coins

    local expPerDrop = math.ceil(totalExp / numDrops)
    local coinPerDrop = math.ceil(totalCoins / numDrops)

    for i = 1, numDrops do
        SpawnSingleDrop("Coin", coinPerDrop, enemyPos)
        SpawnSingleDrop("Exp", expPerDrop, enemyPos)
    end
end
-- 更新掉落物磁吸和拾取逻辑。
function EncounterController.UpdateMagnetism(dt, rootPart)
	local pPos = rootPart.Position
	local Config = Controllers.Config
	local magnetBonus = player:GetAttribute("MagnetRadius_Bonus") or 0
	local currentMagnetRadius = math.min(Config.MAGNET_RADIUS * (1 + (magnetBonus / 100)), Config.MAX_MAGNET_RADIUS or math.huge)

	for i = #EncounterController.ActiveDrops, 1, -1 do
		local drop = EncounterController.ActiveDrops[i]
		if not drop.part or not drop.part.Parent or (drop.instance and not drop.instance.Parent) then
			table.remove(EncounterController.ActiveDrops, i)
			continue
		end

		local dPos = drop.part.Position
		local dist = (pPos - dPos).Magnitude

		if dist < Config.COLLECT_RADIUS then
			if drop.type == "Coin" then
				local remotes = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
				if remotes and remotes:FindFirstChild("AddCoin") then
					remotes.AddCoin:FireServer(drop.value)
				end

				local coinIconId = "rbxassetid://127099213486402"
				local cleanText = "+" .. Config.FormatNumber(drop.value)
				Controllers.VFX.PlayLootText(player.Character, cleanText, Color3.fromRGB(255, 215, 0), coinIconId)
			elseif drop.type == "Exp" then
				local actualExp = Controllers.Progression.AddExp(drop.value) or drop.value

				local expIconId = "rbxassetid://83939430689931"
				local cleanText = "+" .. Config.FormatNumber(actualExp)
				Controllers.VFX.PlayLootText(player.Character, cleanText, Color3.fromRGB(100, 255, 100), expIconId)
			end

			destroyDrop(drop)
			table.remove(EncounterController.ActiveDrops, i)

		else
			if (os.clock() - drop.spawnTime) > Config.DROP_MAGNET_DELAY then
				if dist < currentMagnetRadius then
					local dir = (pPos - dPos).Unit
					moveDropBy(drop, dir * (Config.MAGNET_SPEED * dt))
				elseif dPos.Z > pPos.Z + Config.CLEANUP_BEHIND then
					destroyDrop(drop)
					table.remove(EncounterController.ActiveDrops, i)
				end
			end
		end
	end
end

-- 清理当前局内所有怪物、属性门和掉落物。
function EncounterController.ClearAll()
	for _, enemy in ipairs(EncounterController.ActiveEnemies) do if enemy.part then enemy.part:Destroy() end end
	for _, group in ipairs(EncounterController.ActiveGateGroups) do
		if group.left.part then group.left.part:Destroy() end
		if group.right.part then group.right.part:Destroy() end
	end
	for _, drop in ipairs(EncounterController.ActiveDrops) do destroyDrop(drop) end

	EncounterController.ActiveEnemies = {}
	EncounterController.ActiveGateGroups = {}
	EncounterController.ActiveDrops = {}
end

return EncounterController
