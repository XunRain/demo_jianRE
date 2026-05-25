-- src/client/Combat/EncounterController.luau
-- 遭遇实体生成与管理模块 (刷怪、属性门、掉落物及磁吸)
local EncounterController = {}

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local player = Players.LocalPlayer

local Controllers -- 全局依赖指针

-- 存放场上的实体
EncounterController.ActiveEnemies = {}
EncounterController.ActiveGateGroups = {}
EncounterController.ActiveDrops = {}

-- ==========================================
-- 关卡系统生成器核心状态
-- ==========================================
local currentStage = 1
local stageConfig = nil
local stageEndZ = 0
local elitePositions = {} -- 精英怪的具体 Z 坐标数组
local bossZ = nil         -- 关底 Boss 的 Z 坐标
local nextGateZ = 0
local nextMobZ = 0
local occupiedZones = {} -- 用于记录跑道上已经被占用的空间
local activeStageZones = {} -- 用于记录每个关卡的终点坐标，核对玩家进度


-- 空间分配与清理
local function CleanupZones(currentStartZ)
	for i = #occupiedZones, 1, -1 do
		-- 如果占位区已经被玩家远远甩在身后，则清理掉以防内存泄漏
		if occupiedZones[i].z > currentStartZ + 200 then
			table.remove(occupiedZones, i)
		end
	end
end

local function GetSafeZ(desiredZ, requiredGap)
	local safeZ = desiredZ
	local conflict = true
	
	-- 不断尝试，直到找到一块没有任何人占用的空地
	while conflict do
		conflict = false
		for _, zone in ipairs(occupiedZones) do
			-- 如果想生成的坐标跟已存在的区域发生了重叠
			if math.abs(safeZ - zone.z) < (requiredGap + zone.gap) then
				conflict = true
				-- 强行把这个实体往跑道的前方 (更负的 Z 轴) 推移，让出位置
				safeZ = zone.z - zone.gap - requiredGap - 1
				break
			end
		end
	end
	
	-- 找到安全坐标后，立刻插旗占领这块地盘！
	table.insert(occupiedZones, {z = safeZ, gap = requiredGap})
	return safeZ
end

-- 【新增核心】：加载指定关卡的配置，并预计算本关所有实体的坐标
local function LoadStageConfig(stageNum, startZ)
	local Config = Controllers.Config
	
	-- 兜底逻辑：如果玩家打到了配置表外（比如打了第 4 关但表里只有 3 关），则无限循环最后一关的配置
	stageConfig = Config.STAGES[stageNum] or Config.STAGES[#Config.STAGES]
	
	stageEndZ = startZ - stageConfig.Length
	
	-- 预留 50 米开局安全区
	nextGateZ = startZ - 50 - stageConfig.GateInterval
	nextMobZ = startZ - 50 - stageConfig.MobInterval
	
	-- 预计算精英怪的绝对坐标 (均匀分布在本关中)
	elitePositions = {}
	if stageConfig.EliteCount > 0 then
		local step = stageConfig.Length / (stageConfig.EliteCount + 1)
		for i = 1, stageConfig.EliteCount do
			table.insert(elitePositions, startZ - step * i)
		end
	end
	
	-- 预计算关底 Boss
	bossZ = stageConfig.HasBoss and stageEndZ or nil
	
	-- 将本关的边界线登记到记录本中
	table.insert(activeStageZones, {
		stage = stageNum,
		endZ = stageEndZ
	})
	print(string.format(">>> 加载第 %d 关配置！关卡起点: %d，关底坐标: %d <<<", stageNum, math.floor(startZ), math.floor(stageEndZ)))
end

-- 实时更新玩家所在的真实关卡
function EncounterController.UpdatePlayerStage(playerZ)
	-- 如果玩家的肉身越过了当前记录的最早一关的终点线 (Z轴向负方向延伸，所以是小于号)
	-- 就把打完的这一关从记录本里撕掉
	while #activeStageZones > 1 and playerZ < activeStageZones[1].endZ do
		table.remove(activeStageZones, 1)
	end
	
	-- 此时排在第一页的，绝对是玩家正在经历的关卡！
	if #activeStageZones > 0 then
		local realStage = activeStageZones[1].stage
		
		-- 如果发现 UI 没同步，就更新 UI
		if player:GetAttribute("CurrentStage") ~= realStage then
			player:SetAttribute("CurrentStage", realStage)
			print(">>> 玩家已正式突入 第 " .. tostring(realStage) .. " 关！ <<<")
		end
	end
end

function EncounterController.Init(deps)
	Controllers = deps
end

-- 开局时重置关卡（由 MapController 第一帧调用）
function EncounterController.ResetPointers(startZ)
	occupiedZones = {} -- 开局清空全部占领区
	activeStageZones = {} -- 开局清空关卡记录
	currentStage = 1
	LoadStageConfig(currentStage, startZ)
end

-- 生成单扇属性门 (随机决定是红门减益还是绿门增益)
local function CreateGate(xOffset, zPos, trackStartX, trackStartY)
	local Config = Controllers.Config
	local isBuff = math.random() > 0.3 -- 70%概率是增益
	local attributes = {"ATK", "ASPD", "HP"}
	local attr = attributes[math.random(1, #attributes)]
	
	-- 根据不同属性，使用不同的随机逻辑
	local amount = 0
	if attr == "HP" then
		amount = math.random(Config.GATE_HP_MIN, Config.GATE_HP_MAX)
	elseif attr == "ATK" then
		amount = math.random(Config.GATE_ATK_MIN, Config.GATE_ATK_MAX)
	elseif attr == "ASPD" then
		local rawVal = Config.GATE_ASPD_MIN + math.random() * (Config.GATE_ASPD_MAX - Config.GATE_ASPD_MIN)
		amount = math.floor(rawVal * 10) / 10 
		if amount == 0 then amount = Config.GATE_ASPD_MIN end 
	end

	if not isBuff then amount = -amount end

	local gate = Instance.new("Part")
	gate.Size = Vector3.new(Config.RUNWAY_LIMIT, 10, 2) 
	gate.Position = Vector3.new(trackStartX + xOffset, trackStartY + 5, zPos)
	gate.Anchored = true
	gate.CanCollide = false 
	gate.Transparency = 0.6
	gate.Material = Enum.Material.Neon
	gate.Color = isBuff and Color3.fromRGB(0, 255, 0) or Color3.fromRGB(255, 0, 0) 
	
	local sign = amount > 0 and "+" or ""
	local text = string.format("%s %s%s", attr, sign, tostring(amount))
	
	-- 呼叫 VFX 模块生成近大远小的 3D 文本
	Controllers.VFX.CreateBillboard(gate, text, Color3.new(1,1,1), 1)

	local folder = Workspace:FindFirstChild("LocalEncounters") or Instance.new("Folder", Workspace)
	folder.Name = "LocalEncounters"
	gate.Parent = folder

	return { part = gate, attr = attr, amount = amount }
end

-- 根据类型生成怪物 (蓝方块小怪 / 紫方块精英 / 红方块Boss)
-- 根据类型生成怪物 (血量完全由当前关卡配置决定)
local function CreateEnemy(enemyType, xOffset, zPos, trackStartX, trackStartY)
	local Config = Controllers.Config
	local enemy = Instance.new("Part")
	enemy.Anchored = true
	enemy.CanCollide = false 
	
	-- 1. 获取成长系数（保留原本随距离微幅膨胀的机制，如果不需要也可以在下面把 hpMultiplier 删掉）
	-- local distance = math.abs(zPos) 
	-- local hpMultiplier = 1 + math.floor(distance / Config.ENEMY_HP_SCALE_DIST) * Config.ENEMY_HP_SCALE_RATE
	
	-- 安全保护：获取当前关卡的配置，如果没加载完则默认用第一关兜底
	local currentStageConfig = stageConfig or Config.STAGES[1]
	
	-- 2. 核心修改：动态匹配血量变量
	local hp = 0
	if enemyType == "Basic" then
		enemy.Size = Vector3.new(4, 4, 4)
		enemy.Color = Color3.fromRGB(0, 0, 255) 
		
		-- 【修改】读取当前关卡的普通怪血量
		local baseHP = currentStageConfig.BasicHP or 30
		hp = math.floor(baseHP) 
		
	elseif enemyType == "Elite" then
		enemy.Size = Vector3.new(Config.RUNWAY_LIMIT * 2, 8, 8) 
		enemy.Color = Color3.fromRGB(128, 0, 128) 
		
		-- 【修改】读取当前关卡的精英怪血量
		local baseHP = currentStageConfig.EliteHP or 150
		hp = math.floor(baseHP) 
		xOffset = 0 -- 强制居中
		
	elseif enemyType == "Boss" then
		enemy.Size = Vector3.new(Config.RUNWAY_LIMIT * 2, 16, 16) 
		enemy.Color = Color3.fromRGB(255, 0, 0) 
		
		-- 【修改】读取当前关卡的Boss血量
		local baseHP = currentStageConfig.BossHP or 1000
		hp = math.floor(baseHP) 
		xOffset = 0 -- 强制居中
	end
	
	enemy.Position = Vector3.new(trackStartX + xOffset, trackStartY + (enemy.Size.Y / 2), zPos)
	enemy.Material = Enum.Material.SmoothPlastic
	
	local folder = Workspace:FindFirstChild("LocalEncounters") or Instance.new("Folder", Workspace)
	folder.Name = "LocalEncounters"
	enemy.Parent = folder
	
	-- 呼叫 VFX 模块生成 3D 文本
	local hpLabel = Controllers.VFX.CreateBillboard(enemy, tostring(hp), Color3.new(1,1,1), 1)
	
	table.insert(EncounterController.ActiveEnemies, { part = enemy, hp = hp, maxHp = hp, label = hpLabel, type = enemyType })
end

-- 无缝跨关卡处理，带避让机制与跨关卡处理
function EncounterController.SpawnEncountersInBlock(startZ, endZ, trackStartX, trackStartY)
	local Config = Controllers.Config
	
	CleanupZones(startZ) -- 随时清理身后的废弃领地，保持计算轻量

	-- 1. 生成关底 Boss (最高优先级，霸占前后 40 米的空间)
	if bossZ and bossZ <= startZ and bossZ > endZ then
		local finalZ = GetSafeZ(bossZ, 40)
		CreateEnemy("Boss", 0, finalZ, trackStartX, trackStartY)
		bossZ = nil 
	end
	
	-- 2. 生成精英怪 (优先级 2，霸占前后 30 米的空间)
	for i = #elitePositions, 1, -1 do
		local ez = elitePositions[i]
		if ez <= startZ and ez > endZ then
			local finalZ = GetSafeZ(ez, 30)
			CreateEnemy("Elite", 0, finalZ, trackStartX, trackStartY)
			table.remove(elitePositions, i)
		end
	end

	-- 3. 生成属性门 (优先级 3，霸占前后 20 米的空间)
	while nextGateZ <= startZ and nextGateZ > endZ do
		-- 额外保护：哪怕算上避让，门也不能刷在 Boss 脸上。给关底留出 60 米的绝对空场！
		if nextGateZ > stageEndZ + 60 then
			local finalZ = GetSafeZ(nextGateZ, 20)
			local leftGate = CreateGate(-Config.RUNWAY_LIMIT/2, finalZ, trackStartX, trackStartY)
			local rightGate = CreateGate(Config.RUNWAY_LIMIT/2, finalZ, trackStartX, trackStartY)
			table.insert(EncounterController.ActiveGateGroups, { left = leftGate, right = rightGate, z = finalZ })
		end
		nextGateZ = nextGateZ - stageConfig.GateInterval
	end
	
	-- 4. 生成普通小怪 (最低优先级)
	while nextMobZ <= startZ and nextMobZ > endZ do
		if nextMobZ > stageEndZ + 60 then
			local finalZ = GetSafeZ(nextMobZ, 15)
			local numMobs = math.random(stageConfig.MobsPerGroup[1], stageConfig.MobsPerGroup[2])
			
			-- =======================================================
			-- 【核心修复】：均匀列阵算法
			-- =======================================================
			local margin = 4 -- 距离跑道左右边缘留出安全距离，防止怪掉下去
			local usableWidth = (Config.RUNWAY_LIMIT * 2) - (margin * 2)
			
			for i = 1, numMobs do
				local offsetX = 0
				
				if numMobs > 1 then
					-- 将这群怪均匀地平铺在跑道上 (i=1在最左，i=numMobs在最右)
					local fraction = (i - 1) / (numMobs - 1)
					offsetX = -Config.RUNWAY_LIMIT + margin + (usableWidth * fraction)
				else
					-- 如果这波只有1只怪，直接在有效范围内随机生成
					offsetX = math.random(-Config.RUNWAY_LIMIT + margin, Config.RUNWAY_LIMIT - margin)
				end
				
				-- 引入“微小扰动 (Jitter)”：
				-- 均匀排布看起来会有点呆板，我们在 X 和 Z 轴上加一点点错落感
				-- 保证错落感不会大到让它们重叠
				local jitterX = (numMobs > 1) and (math.random() * 2 - 1) or 0 
				local jitterZ = math.random(-2, 2)
				
				CreateEnemy("Basic", offsetX + jitterX, finalZ + jitterZ, trackStartX, trackStartY)
			end
			-- =======================================================
		end
		nextMobZ = nextMobZ - stageConfig.MobInterval
	end
	
	-- 5. 跨关卡无缝衔接判定 (不变)
	if endZ < stageEndZ then
		currentStage = currentStage + 1
		local nextStageStartZ = stageEndZ - 100 
		LoadStageConfig(currentStage, nextStageStartZ)
		
		if endZ < nextStageStartZ then
			EncounterController.SpawnEncountersInBlock(nextStageStartZ, endZ, trackStartX, trackStartY)
		end
	end
end

-- 生成单个掉落物实体
local function SpawnSingleDrop(dropType, value, startPos)
	local drop = Instance.new("Part")
	drop.Size = Vector3.new(1.5, 1.5, 1.5)
	drop.Anchored = true
	drop.CanCollide = false
	drop.Material = Enum.Material.Neon

	-- 白模区分：黄色代表金币，绿色代表经验
	if dropType == "Coin" then
		drop.Color = Color3.fromRGB(255, 215, 0)
	else
		drop.Color = Color3.fromRGB(0, 255, 100)
	end

	drop.Position = startPos
	local localFolder = Workspace:FindFirstChild("LocalEncounters")
	drop.Parent = localFolder

	-- 注册到活跃池
	table.insert(EncounterController.ActiveDrops, {
		part = drop,
		type = dropType,
		value = value,
		spawnTime = os.clock() -- 记录出生时间，用于无敌帧判断
	})

	-- 呼叫 VFX 模块播放爆破散落动画
	Controllers.VFX.PlayDropExplosion(drop, startPos)
end

-- 根据击杀怪物类型，决定爆多少数量、多少数值的战利品
function EncounterController.TriggerDrops(enemyType, enemyPos)
	local numDrops = 2
	local totalExp = 10
	local totalCoins = 10

	if enemyType == "Elite" then
		numDrops = 5
		totalExp = 50
		totalCoins = 50
	elseif enemyType == "Boss" then
		numDrops = 15
		totalExp = 200
		totalCoins = 100
	end

	-- 平均分配到每个球上的数值
	local expPerDrop = math.ceil(totalExp / numDrops)
	local coinPerDrop = math.ceil(totalCoins / numDrops)

	for i = 1, numDrops do
		SpawnSingleDrop("Coin", coinPerDrop, enemyPos)
		SpawnSingleDrop("Exp", expPerDrop, enemyPos)
	end
end

-- 实时更新所有掉落物的磁吸状态 (由 PlayerController 每帧调用)
function EncounterController.UpdateMagnetism(dt, rootPart)
	local pPos = rootPart.Position
	local Config = Controllers.Config
	local currentMagnetRadius = player:GetAttribute("MagnetRadius") or Config.MAGNET_RADIUS

	for i = #EncounterController.ActiveDrops, 1, -1 do
		local drop = EncounterController.ActiveDrops[i]
		if not drop.part or not drop.part.Parent then
			table.remove(EncounterController.ActiveDrops, i)
			continue
		end

		local dPos = drop.part.Position
		local dist = (pPos - dPos).Magnitude

		if dist < Config.COLLECT_RADIUS then
			-- 1. 距离极近，玩家拾取！
			if drop.type == "Coin" then
				-- 不再在客户端自己改，而是用信道通知服务器
				local remotes = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
				if remotes and remotes:FindFirstChild("AddCoin") then
					remotes.AddCoin:FireServer(drop.value)
				end
			elseif drop.type == "Exp" then
				-- 【核心修复】改为调用 ProgressionController 里的经验管理函数
				Controllers.Progression.AddExp(drop.value)
			end
			
			drop.part:Destroy()
			table.remove(EncounterController.ActiveDrops, i)
			
		else
			-- 2. 磁吸牵引逻辑 (爆破散开的前 0.5 秒处于无敌飞行状态，不产生磁吸)
			if (os.clock() - drop.spawnTime) > 0.5 then
				if dist < currentMagnetRadius then
					-- 计算从掉落物指向玩家的方向向量
					local dir = (pPos - dPos).Unit 
					drop.part.Position = drop.part.Position + dir * (Config.MAGNET_SPEED * dt)
				elseif dPos.Z > pPos.Z + Config.CLEANUP_BEHIND then
					-- 太远没捡到，被甩在身后彻底错过了
					drop.part:Destroy()
					table.remove(EncounterController.ActiveDrops, i)
				end
			end
		end
	end
end

-- 清理场上所有的怪物、子弹、门、掉落物 (用于重置游戏)
function EncounterController.ClearAll()
	for _, enemy in ipairs(EncounterController.ActiveEnemies) do if enemy.part then enemy.part:Destroy() end end
	for _, group in ipairs(EncounterController.ActiveGateGroups) do 
		if group.left.part then group.left.part:Destroy() end
		if group.right.part then group.right.part:Destroy() end
	end
	for _, drop in ipairs(EncounterController.ActiveDrops) do if drop.part then drop.part:Destroy() end end
	
	EncounterController.ActiveEnemies = {}
	EncounterController.ActiveGateGroups = {}
	EncounterController.ActiveDrops = {} 
end

return EncounterController