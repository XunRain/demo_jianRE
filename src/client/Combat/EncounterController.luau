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
local function CreateGate(xOffset, gateWidth, zPos, trackStartX, trackStartY, isBuff)
	local Config = Controllers.Config
	-- 安全锁定当前正在跑的关卡配置，若处于开局未加载状态则拿第 1 关兜底
	local currentStageConfig = stageConfig or Config.STAGES[1]

	local attributes = Config.GATE_ATTRIBUTE_POOL
	local attr = attributes[math.random(1, #attributes)]
	
	-- 根据不同属性，使用对应关卡的随机范围逻辑
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
		-- 横向移动速度门使用全局固定范围，方便统一控制手感上限。
		amount = math.random(Config.GATE_LATERAL_SPEED_BONUS_MIN or 12, Config.GATE_LATERAL_SPEED_BONUS_MAX or 12)
	end

	if not isBuff then amount = -amount end

	local gate = Instance.new("Part")
	-- 把原本的 Config.RUNWAY_LIMIT 替换为我们传进来的 gateWidth
	gate.Size = Vector3.new(gateWidth, 10, 2) 
	gate.Position = Vector3.new(trackStartX + xOffset, trackStartY + 5, zPos)
	gate.Anchored = true
	gate.CanCollide = false 
	gate.Transparency = 0.6
	gate.Material = Enum.Material.Neon
	gate.Color = isBuff and Color3.fromRGB(0, 255, 0) or Color3.fromRGB(255, 0, 0) 
	
	local sign = amount > 0 and "+" or ""
	local displayName = (Config.ATTRIBUTE_NAMES_CN and Config.ATTRIBUTE_NAMES_CN[attr]) or attr
	
	-- =======================================================
	-- 【核心修改】：动态百分号与换行排版
	-- =======================================================
	-- 如果底层的属性名包含 "Bonus" (如 ATK_Bonus)，就在数值末尾加个 "%"
	local percentageSuffix = string.find(attr, "Bonus") and "%" or ""
	
	-- 使用 \n 进行强制换行。格式变更为：名字 \n 符号 数值 后缀
	-- 最终效果例如: "攻击加成\n+13%" 或 "子弹弹速\n+15"
	local text = string.format("%s\n%s%s%s", displayName, sign, tostring(amount), percentageSuffix)
	
	-- 呼叫 VFX 模块生成近大远小的 3D 文本
	Controllers.VFX.CreateBillboard(gate, text, Color3.new(1,1,1), -(gate.Size.Y / 2))

	local folder = Workspace:FindFirstChild("LocalEncounters") or Instance.new("Folder", Workspace)
	folder.Name = "LocalEncounters"
	gate.Parent = folder

	return { part = gate, attr = attr, amount = amount }
end

-- 根据类型生成怪物 (血量 = 关卡基础血量 * 距离动态倍率)
local function CreateEnemy(enemyType, xOffset, zPos, trackStartX, trackStartY)
	local Config = Controllers.Config
	local enemy = Instance.new("Part")
	enemy.Anchored = true
	enemy.CanCollide = false 
	
	-- 安全保护：如果超越了第 5 关，自动沿用最后一关 (第 5 关) 的环境配置
	local currentStageConfig = stageConfig or Config.STAGES[#Config.STAGES]
	
	-- 前 5 关福利期免检，第 6 关起启用动态难度膨胀
	local hpMultiplier = 1
	if currentStage > 5 then
		-- 动态计算前 5 关的新手保护总长度 (免维护设计)
		local safeZoneLength = 0
		for i = 1, 5 do
			if Config.STAGES[i] then
				safeZoneLength = safeZoneLength + Config.STAGES[i].Length
			end
		end
		
		-- 减去前 5 关的距离，让第 6 关的倍率从 1.0 开始平滑起步
		local effectiveDistance = math.abs(zPos) - safeZoneLength
		if effectiveDistance > 0 then
			hpMultiplier = 1 + math.floor(effectiveDistance / Config.ENEMY_HP_SCALE_DIST) * Config.ENEMY_HP_SCALE_RATE
		end
	end
	
	local hp = 0
	if enemyType == "Basic" then
		enemy.Size = Vector3.new(4, 4, 4)
		enemy.Color = Color3.fromRGB(0, 0, 255) 
		
		-- 关卡基础血量 × 距离膨胀倍率
		local baseHP = currentStageConfig.BasicHP or 30
		hp = math.floor(baseHP * hpMultiplier) 
		
	elseif enemyType == "Elite" then
		enemy.Size = Vector3.new(Config.RUNWAY_LIMIT * 2, 8, 8) 
		enemy.Color = Color3.fromRGB(128, 0, 128) 
		
		local baseHP = currentStageConfig.EliteHP or 150
		hp = math.floor(baseHP * hpMultiplier) 
		xOffset = 0 
		
	elseif enemyType == "Boss" then
		enemy.Size = Vector3.new(Config.RUNWAY_LIMIT * 2, 16, 16) 
		enemy.Color = Color3.fromRGB(255, 0, 0) 
		
		local baseHP = currentStageConfig.BossHP or 1000
		hp = math.floor(baseHP * hpMultiplier) 
		xOffset = 0 
	end
	
	enemy.Position = Vector3.new(trackStartX + xOffset, trackStartY + (enemy.Size.Y / 2), zPos)
	enemy.Material = Enum.Material.SmoothPlastic
	
	local folder = Workspace:FindFirstChild("LocalEncounters") or Instance.new("Folder", Workspace)
	folder.Name = "LocalEncounters"
	enemy.Parent = folder
	
	-- 呼叫 VFX 模块生成 3D 文本
	-- 减去怪物的完整高度 (-enemy.Size.Y) 将其拉到脚底，
	-- 并加上 1 Stud 的安全抬升 (+ 1)，防止血量文字穿透嵌进地板里
	local hpLabel = Controllers.VFX.CreateBillboard(enemy, Controllers.Config.FormatNumber(hp), Color3.new(1,1,1), -enemy.Size.Y + 1)
	
	table.insert(EncounterController.ActiveEnemies, { 
		part = enemy, 
		hp = hp, 
		maxHp = hp, 
		label = hpLabel, 
		type = enemyType,
		baseSize = enemy.Size -- 记录初始尺寸，用于受击物理反馈！
	})
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
			
			-- 安全锁定当前关卡配置，拿第一关配置或 0.5 兜底
			local currentStageConfig = stageConfig
			local buffChance = currentStageConfig.GateBuffChance or 0.5
			
			-- 【数据驱动】：根据当前关卡的 GateBuffChance 动态决定红绿门
			local leftIsBuff = math.random() <= buffChance
			local rightIsBuff = math.random() <= buffChance
			
			-- 强力防双红保底机制依然生效：如果运气极差双双随出红门，强制洗白一扇
			if not leftIsBuff and not rightIsBuff then
				if math.random() > 0.5 then
					leftIsBuff = true
				else
					rightIsBuff = true
				end
			end
			
			-- 计算门之间的缝隙与新的位置偏移
			local gateGap = 2 -- 两个门中间留出的空隙宽度
			local gateWidth = Config.RUNWAY_LIMIT - (gateGap / 2)
			
			-- 计算门的中心点偏移量：缝隙的一半 + 门自身宽度的一半
			local leftOffset = -(gateGap / 2 + gateWidth / 2)
			local rightOffset = (gateGap / 2 + gateWidth / 2)
			
			-- 将算好的位置偏移和宽度传给生成函数
			local leftGate = CreateGate(leftOffset, gateWidth, finalZ, trackStartX, trackStartY, leftIsBuff)
			local rightGate = CreateGate(rightOffset, gateWidth, finalZ, trackStartX, trackStartY, rightIsBuff)
			
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
	local Config = Controllers.Config
	
	-- 直接从配置表读取掉落数据，找不到就拿 Basic 兜底
	local dropConfig = Config.ENEMY_DROPS[enemyType] or Config.ENEMY_DROPS["Basic"]
	local numDrops = dropConfig.NumDrops
	local totalExp = dropConfig.Exp
	local totalCoins = dropConfig.Coins

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
	-- 磁力范围改为百分比成长，并用最大磁力半径封顶。
	local magnetBonus = player:GetAttribute("MagnetRadius_Bonus") or 0
	local currentMagnetRadius = math.min(Config.MAGNET_RADIUS * (1 + (magnetBonus / 100)), Config.MAX_MAGNET_RADIUS or math.huge)

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

				-- 触发金币飘字特效
				local coinIconId = "rbxassetid://127099213486402" -- 金币图片 ID
				local cleanText = "+" .. Config.FormatNumber(drop.value)
				Controllers.VFX.PlayLootText(player.Character, cleanText, Color3.fromRGB(255, 215, 0), coinIconId)
			elseif drop.type == "Exp" then
				-- 【核心修复】改为调用 ProgressionController 里的经验管理函数
				local actualExp = Controllers.Progression.AddExp(drop.value) or drop.value

				-- 触发经验飘字特效
				local expIconId = "rbxassetid://83939430689931" -- 经验图片 ID
				local cleanText = "+" .. Config.FormatNumber(actualExp)
				Controllers.VFX.PlayLootText(player.Character, cleanText, Color3.fromRGB(100, 255, 100), expIconId)
			end
			
			drop.part:Destroy()
			table.remove(EncounterController.ActiveDrops, i)
			
		else
			-- 2. 磁吸牵引逻辑 (爆破散开的前置时间处于无敌飞行状态，不产生磁吸)
			if (os.clock() - drop.spawnTime) > Config.DROP_MAGNET_DELAY then
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
