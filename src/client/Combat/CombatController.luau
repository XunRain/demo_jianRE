-- src/client/Combat/CombatController.luau
-- 核心战斗控制器：负责射击循环与碰撞结算(打怪、吃门、肉身撞击)
local CombatController = {}

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer

-- 精准定位到特效文件路径
local vfxFolder = ReplicatedStorage:WaitForChild("VFX", 10)
local sourceVFX = vfxFolder and vfxFolder:WaitForChild("CollisionDoorVFX", 5)

local Controllers -- 全局依赖指针

CombatController.ActiveBullets = {}

function CombatController.Init(deps)
	Controllers = deps
end

function CombatController.Start()
	task.spawn(function()
		while true do
			if Controllers.Game.IsCombatActive and not player:GetAttribute("IsLevelingUp") then
				
				-- 拿到当前装备的武器配置
				local equippedWeapon = player:GetAttribute("EquippedWeapon") or "DefaultWeapon"
				local weaponConfig = Controllers.Config.WEAPONS[equippedWeapon] or Controllers.Config.WEAPONS["DefaultWeapon"]
				
				-- 计算理论上的每秒攻击次数 (基础值 * 百分比)
				local baseAspd = Controllers.Config.BASE_ASPD
				local aspdBonus = player:GetAttribute("ASPD_Bonus") or 0
				local theoreticalAspd = baseAspd * (1 + (aspdBonus / 100))
				
				-- 【核心限制】：实际攻速 = 理论攻速 与 武器上限 之间较小的值 (兜底上限20防崩溃)
				local finalAspd = math.min(theoreticalAspd, weaponConfig.MaxASPD or 20)
				
				-- 将每秒攻击次数转换为等待间隔
				local actualInterval = 1 / finalAspd
				
				CombatController.ShootProjectile()
				task.wait(actualInterval)
			else
				task.wait(0.1) 
			end
		end
	end)
end

-- 生成并弹射子弹模型 (支持多重弹道)
function CombatController.ShootProjectile()
	local character = player.Character
	if not character or not character.PrimaryPart then return end
	
	local humanoid = character:FindFirstChild("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return end
	local rootPart = character.PrimaryPart
	
	-- 1. 查找武器配置
	local equippedWeapon = player:GetAttribute("EquippedWeapon") or "DefaultWeapon"
	local weaponConfig = Controllers.Config.WEAPONS[equippedWeapon] or Controllers.Config.WEAPONS["DefaultWeapon"]
	
	-- 2. 准备子弹预制体与射击原点
	local vfxFolder = game:GetService("ReplicatedStorage"):FindFirstChild("VFX")
	local weaponsFolder = vfxFolder and vfxFolder:FindFirstChild("Weapons")
	local bulletPrefab = weaponsFolder and weaponsFolder:FindFirstChild(weaponConfig.BulletVFX)

	-- 核心起点
	local spawnCenter = rootPart.Position + Vector3.new(0, 0, -2)
	
	-- 【修改】：落实弹速与射程的百分比加成公式
	local baseSpd = Controllers.Config.BASE_SPD
	local spdBonus = player:GetAttribute("SPD_Bonus") or 0
	local currentSpd = baseSpd * (1 + (spdBonus / 100))
	
	local baseRng = Controllers.Config.BASE_RNG
	local rngBonus = player:GetAttribute("RNG_Bonus") or 0
	local theoreticalRng = baseRng * (1 + (rngBonus / 100))
	
	-- 实际射程 = 理论射程 与 武器上限 之间较小的值 (兜底上限500)
	local finalRng = math.min(theoreticalRng, weaponConfig.MaxRNG or 500)
	
	-- 利用最终截断的射程，重新计算子弹应该存活多长时间
	local actualLifetime = finalRng / currentSpd

	-- 【落实公式】：实际伤害 = 基础伤害 x (1 + 攻击力加成) x 暴击倍率
	local baseAtk = Controllers.Config.BASE_ATK
	local atkBonus = player:GetAttribute("ATK_Bonus") or 0
	local critMultiplier = 1 -- 预留暴击倍率
	-- 计算最终面板伤害 (向下取整保证视觉干净)
	local finalDmg = math.floor(baseAtk * (1 + (atkBonus / 100)) * critMultiplier)
	
	local multiShot = player:GetAttribute("MultiShot") or 1
	
	-- 【核心】：读取武器的弹道模式，兜底为并排
	local firePattern = weaponConfig.FirePattern or "Parallel"

	local localProjectiles = Workspace:FindFirstChild("LocalProjectiles") or Instance.new("Folder", Workspace)
	localProjectiles.Name = "LocalProjectiles"

	for i = 1, multiShot do
		-- 默认飞行方向 (正前方) 与坐标偏移
		local dirX, dirZ = 0, -1
		local angleRad = 0
		local spawnOffset = Vector3.new(0, 0, 0)
		
		-- 当前这根弹道的相对索引 (例如 3发子弹时，索引分别是 -1, 0, 1)
		local offsetIndex = i - (multiShot + 1) / 2
		
		-- 【弹道模式分支接口】
		if firePattern == "Spread" then
			-- 1. 扇形散射
			local spreadAngle = 15 
			angleRad = math.rad(offsetIndex * spreadAngle)
			dirX = math.sin(angleRad)
			dirZ = -math.cos(angleRad)
			
		elseif firePattern == "Parallel" or firePattern == "Pierce" then
			-- 2. 并排射击 (穿透也默认使用并排弹道)
			local spacing = 3.5 -- 子弹之间的左右间距
			spawnOffset = Vector3.new(offsetIndex * spacing, 0, 0)
		end
		
		-- 计算这颗子弹最终的生成坐标
		local finalSpawnPos = spawnCenter + spawnOffset
		
		local bullet
		if bulletPrefab then
			bullet = bulletPrefab:Clone()
			if bullet:IsA("Model") then
				bullet:PivotTo(CFrame.new(finalSpawnPos) * CFrame.Angles(0, -angleRad, 0) * bulletPrefab:GetPivot().Rotation)
			else
				bullet.CFrame = CFrame.new(finalSpawnPos) * CFrame.Angles(0, -angleRad, 0) * bulletPrefab.CFrame.Rotation
			end
		else
			bullet = Instance.new("Part")
			bullet.Size = Vector3.new(1, 1, 2)
			bullet.Color = Color3.fromRGB(0, 255, 255)
			bullet.Material = Enum.Material.Neon
			bullet.CFrame = CFrame.new(finalSpawnPos) * CFrame.Angles(0, -angleRad, 0)
		end
		
		local targetPart = bullet:IsA("Model") and bullet.PrimaryPart or bullet
		if bullet:IsA("Model") and not targetPart then
			targetPart = bullet:FindFirstChildWhichIsA("BasePart", true)
			bullet.PrimaryPart = targetPart
		end
		
		if targetPart and targetPart:IsA("BasePart") then
			local partsToProcess = bullet:IsA("Model") and bullet:GetDescendants() or {}
			table.insert(partsToProcess, bullet) 
			for _, obj in ipairs(partsToProcess) do
				if obj:IsA("BasePart") then obj.CanCollide = false; obj.Anchored = false end
			end
			
			local bv = Instance.new("LinearVelocity")
			bv.Attachment0 = Instance.new("Attachment", targetPart)
			bv.RelativeTo = Enum.ActuatorRelativeTo.World 
			bv.VectorVelocity = Vector3.new(dirX * currentSpd, 0, dirZ * currentSpd)
			bv.MaxForce = math.huge
			bv.Parent = targetPart
		end
		
		bullet.Parent = localProjectiles
		game.Debris:AddItem(bullet, actualLifetime) 
		
		-- 【核心】：为穿透留好接口！记录该子弹剩余的穿透次数，以及打过哪些怪的黑名单
		local maxHits = (firePattern == "Pierce") and 3 or 1 -- 激光默认穿透3个怪，其他1个
		table.insert(CombatController.ActiveBullets, { 
			part = bullet, 
			damage = finalDmg, 
			weaponId = equippedWeapon,
			hitsLeft = maxHits,   -- 剩余命中次数
			hitTargets = {}       -- 已命中目标的黑名单，防止一帧内穿透时重复扣血
		})
	end
end

function CombatController.ClearBullets()
	for _, bullet in ipairs(CombatController.ActiveBullets) do if bullet.part then bullet.part:Destroy() end end
	CombatController.ActiveBullets = {}
end

-- 结算核心：碰撞检测 (由 PlayerController 驱动调用)
function CombatController.CheckCollisions(rootPart)
	local pPos = rootPart.Position
	local playerAtk = player:GetAttribute("ATK") or Controllers.Config.BASE_ATK
	
	local activeEnemies = Controllers.Encounter.ActiveEnemies
	local activeGateGroups = Controllers.Encounter.ActiveGateGroups

	-- 1. 子弹打怪结算
	for i = #CombatController.ActiveBullets, 1, -1 do
		local b = CombatController.ActiveBullets[i]
		if not b.part or not b.part.Parent then 
			table.remove(CombatController.ActiveBullets, i) 
			continue 
		end
		
		local bPos = b.part.Position
		for j = #activeEnemies, 1, -1 do
			local e = activeEnemies[j]
			if not e.part or not e.part.Parent then continue end
			
			-- 【新增】：如果这颗穿透子弹已经打过这个怪了，直接无视，防止被激光瞬间烫死
			if b.hitTargets[e.part] then continue end
			
			local ePos = e.part.Position
			local eSize = e.part.Size
			
			if math.abs(bPos.X - ePos.X) < (eSize.X/2 + 1) and 
			   math.abs(bPos.Z - ePos.Z) < (eSize.Z/2 + 2) then 
				
				-- 标记这颗子弹已经碰过这个怪
				b.hitTargets[e.part] = true
				
				local dmg = b.damage or (player:GetAttribute("ATK") or Controllers.Config.BASE_ATK)
				e.hp = e.hp - dmg
				e.label.Text = tostring(e.hp)

				Controllers.VFX.PlayHitJitterVFX(e.part, e.baseSize)
				
				local weaponConfig = Controllers.Config.WEAPONS[b.weaponId] or Controllers.Config.WEAPONS["DefaultWeapon"]
				Controllers.VFX.PlayBulletExplosion(weaponConfig.HitVFX, bPos)
				
				-- 【修改】：穿透次数判断
				b.hitsLeft = b.hitsLeft - 1
				if b.hitsLeft <= 0 then
					b.part:Destroy()
					table.remove(CombatController.ActiveBullets, i)
				end
				
				if e.hp <= 0 then
					local deathVfxName = Controllers.Config.ENEMY_VFX[e.type] or "BasicDeath"
					Controllers.VFX.PlayDeathVFX(deathVfxName, ePos)

					e.part:Destroy()
					table.remove(activeEnemies, j)
					Controllers.Encounter.TriggerDrops(e.type, ePos)
				end
				
				-- 如果子弹销毁了（非穿透子弹，或者穿透次数耗尽），跳出当前怪物判断循环
				if b.hitsLeft <= 0 then
					break 
				end
			end
		end
	end
	
	-- 2. 玩家吃增益门结算
	for i = #activeGateGroups, 1, -1 do
		local group = activeGateGroups[i]
		if pPos.Z <= group.z + 1 then
			-- 判断玩家中心点在左侧还是右侧 (通过 MapController 拿到跑道中心 X 坐标)
			local chosenGate = (pPos.X < Controllers.Map.TrackStartX) and group.left or group.right
			
			-- ─── 【终极焊接版：触发吃门特效反馈】 ───
			if sourceVFX and rootPart then Controllers.VFX.PlayGateVFX(rootPart) end

			if chosenGate.attr == "HP_Bonus" then
				local currentMax = player:GetAttribute("MaxHP") or Controllers.Config.BASE_HP
				local currentHp = player:GetAttribute("HP") or Controllers.Config.BASE_HP
				
				-- 按照当前最大生命值的百分比来回血或扣血
				local changeAmount = math.floor(currentMax * (chosenGate.amount / 100))
				-- 保证最低血量为 1 (吃扣血门不死)，最高不超过上限
				local newHp = math.clamp(currentHp + changeAmount, 1, currentMax)
				player:SetAttribute("HP", newHp)
				
				local humanoid = player.Character and player.Character:FindFirstChild("Humanoid")
				if humanoid then humanoid.Health = newHp end
				
			elseif chosenGate.attr == "MaxHP_Bonus" then
				local currentBonus = player:GetAttribute("MaxHP_Bonus") or 0
				player:SetAttribute("MaxHP_Bonus", currentBonus + chosenGate.amount)
				
				-- 重新计算实际的最大生命值 (天赋提供带来的开局基础血量 * (1 + 局内百分比))
				local startingStats = Controllers.Progression.CalculateStartingStats()
				local baseMaxHp = startingStats.MaxHP
				local newMaxHp = math.floor(baseMaxHp * (1 + ((currentBonus + chosenGate.amount) / 100)))
				
				local oldMaxHp = player:GetAttribute("MaxHP") or baseMaxHp
				player:SetAttribute("MaxHP", newMaxHp)
				
				-- 同步当前血量逻辑：如果血量上限增加了，把撑高的这部分白送给当前血量；如果是扣上限，防止当前血量溢出
				local diff = newMaxHp - oldMaxHp
				if diff > 0 then
					player:SetAttribute("HP", (player:GetAttribute("HP") or oldMaxHp) + diff)
				elseif diff < 0 then
					local currentHp = player:GetAttribute("HP") or oldMaxHp
					if currentHp > newMaxHp then player:SetAttribute("HP", newMaxHp) end
				end
				
				local humanoid = player.Character and player.Character:FindFirstChild("Humanoid")
				if humanoid then
					humanoid.MaxHealth = newMaxHp
					humanoid.Health = player:GetAttribute("HP")
				end
			else
				-- 其他 Bonus 属性直接在池子里相加 (如 ATK_Bonus, SPD_Bonus)
				local currentVal = player:GetAttribute(chosenGate.attr) or 0
				player:SetAttribute(chosenGate.attr, currentVal + chosenGate.amount)
			end
			
			-- 门碎裂销毁
			if group.left.part then group.left.part:Destroy() end
			if group.right.part then group.right.part:Destroy() end
			table.remove(activeGateGroups, i)
		end
	end
	
	-- 3. 肉身换血机制 (玩家没打死怪，硬撞上了)
	for i = #activeEnemies, 1, -1 do
		local e = activeEnemies[i]
		if not e.part then continue end
		
		local ePos = e.part.Position
		local eSize = e.part.Size
		
		if math.abs(pPos.X - ePos.X) < (eSize.X/2 + 1) and 
		   math.abs(pPos.Z - ePos.Z) < (eSize.Z/2 + 1) then
			
			-- 怪物还剩多少血，玩家就扣多少血
			local damage = e.hp 
			local currentHp = player:GetAttribute("HP") or Controllers.Config.BASE_HP 
			local newHp = currentHp - damage
			player:SetAttribute("HP", newHp)
			
			-- 玩家撞怪受伤时，全屏红光+屏幕摇晃
			Controllers.VFX.PlayPlayerDamageVFX()

			e.part:Destroy()
			table.remove(activeEnemies, i)
			
			-- 同步到原生的 Humanoid 进行真实死亡判定
			local humanoid = player.Character:FindFirstChild("Humanoid")
			if humanoid then
				humanoid.MaxHealth = player:GetAttribute("MaxHP") or Controllers.Config.BASE_HP
				humanoid.Health = newHp
			end
			
			-- 播放怪物死亡特效，根据怪物类型 (Basic/Elite/Boss) 去配置表拿对应的特效名字
			local deathVfxName = Controllers.Config.ENEMY_VFX[e.type] or "BasicDeath"
			Controllers.VFX.PlayDeathVFX(deathVfxName, ePos)
			-- 用肉身撞死也掉战利品
			Controllers.Encounter.TriggerDrops(e.type, ePos)
		end
	end
end

return CombatController