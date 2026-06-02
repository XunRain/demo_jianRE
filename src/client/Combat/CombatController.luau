-- src/client/Combat/CombatController.luau
-- 核心战斗控制器：负责射击循环与碰撞结算(打怪、吃门、肉身撞击)
local CombatController = {}

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
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
	-- 拉起御剑系统
	CombatController.StartSwordSystem()
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

		-- 判定体积自适应 (大天使的光柱倒下来了，Z轴判定极大幅度增强)
		local hitBoxX = b.part.Size.X / 2 + 1
		local hitBoxZ = b.part.Size.Z / 2 + 2
		if b.isPet and b.part.Shape == Enum.PartType.Cylinder then
			hitBoxX, hitBoxZ = 8, 8
		end

		for j = #activeEnemies, 1, -1 do
			local e = activeEnemies[j]
			-- 自动清理死亡的怪物，防止内存泄漏和报错
			if not e.part or not e.part.Parent then
				table.remove(activeEnemies, j)
				continue
			end
			if b.hitTargets[e.part] then continue end

			local ePos = e.part.Position
			local eSize = e.part.Size

			-- 发生触碰！
			if math.abs(bPos.X - ePos.X) < (hitBoxX + eSize.X/2) and
			   math.abs(bPos.Z - ePos.Z) < (hitBoxZ + eSize.Z/2) then

				b.hitTargets[e.part] = true
				local dmg = b.damage or (player:GetAttribute("ATK") or Controllers.Config.BASE_ATK)

				-- 【修改 1】：优先读取子弹独立特效，没有再去找武器的特效
				local finalHitVFX = b.hitVFX or (Controllers.Config.WEAPONS[b.weaponId] and Controllers.Config.WEAPONS[b.weaponId].HitVFX) or "DefaultHit"
				Controllers.VFX.PlayBulletExplosion(finalHitVFX, bPos)

				-- 【修改 2】：AOE 爆炸结算 vs 单体结算
				if b.aoeRadius then
					-- [火球/神罚] 范围爆炸逻辑
					-- 搜集爆炸范围内所有怪物
					local targetsToDamage = {}
					for _, otherE in ipairs(activeEnemies) do
						if otherE.part and (otherE.part.Position - bPos).Magnitude <= b.aoeRadius then
							table.insert(targetsToDamage, otherE)
						end
					end

					-- 对范围内全体造成伤害
					for _, targetE in ipairs(targetsToDamage) do
						targetE.hp = targetE.hp - dmg
						targetE.label.Text = Controllers.Config.FormatNumber(math.max(0, targetE.hp))
						Controllers.VFX.PlayHitJitterVFX(targetE.part, targetE.baseSize)

						if targetE.hp <= 0 then
							local deathVfxName = Controllers.Config.ENEMY_VFX[targetE.type] or "BasicDeath"
							Controllers.VFX.PlayDeathVFX(deathVfxName, targetE.part.Position)

							-- 处理死亡与掉落
							Controllers.Encounter.TriggerDrops(targetE.type, targetE.part.Position)
							targetE.part:Destroy()

							-- -- 安全清理数组
							-- local deadIdx = table.find(activeEnemies, targetE)
							-- if deadIdx then
							-- 	table.remove(activeEnemies, deadIdx)
							-- 	if deadIdx <= j then j = j - 1 end
							-- end
						end
					end

					-- 炸完之后，无论穿透次数剩多少，强制销毁弹体
					b.hitsLeft = 0
				else
					-- [风刃/玩家子弹] 单体穿透伤害结算
					e.hp = e.hp - dmg
					e.label.Text = Controllers.Config.FormatNumber(math.max(0, e.hp))
					Controllers.VFX.PlayHitJitterVFX(e.part, e.baseSize)

					if e.hp <= 0 then
						local deathVfxName = Controllers.Config.ENEMY_VFX[e.type] or "BasicDeath"
						Controllers.VFX.PlayDeathVFX(deathVfxName, ePos)

						e.part:Destroy()
						table.remove(activeEnemies, j)
						Controllers.Encounter.TriggerDrops(e.type, ePos)
					end

					b.hitsLeft = b.hitsLeft - 1
				end

				-- 如果子弹销毁，跳出对当前怪物的遍历
				if b.hitsLeft <= 0 then
					-- 免死标记
					if not b.persistAfterHit then
						if b.part then b.part:Destroy() end
					end

					table.remove(CombatController.ActiveBullets, i)
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

-- 御剑系统 (环绕视觉 + 自动出鞘制导)
function CombatController.StartSwordSystem()
	local orbitingSwords = {} -- 存放当前环绕在身边的飞剑 { model, primary, state }
	local globalOrbitAngle = 0

	-- 获取飞剑当前 CFrame；Model 和 Part 统一从这里读取，避免 PrimaryPart 缺失时重复写分支。
	local function getSwordCFrame(swordData)
		if not swordData or not swordData.model or not swordData.primary then return nil end
		if swordData.model:IsA("Model") then
			return swordData.model:GetPivot()
		end
		return swordData.primary.CFrame
	end

	-- 移动飞剑到指定 CFrame；Model 使用 PivotTo，普通 Part 直接设置 CFrame。
	local function pivotSwordTo(swordData, targetCFrame)
		if not swordData or not swordData.model or not swordData.primary then return end
		if swordData.model:IsA("Model") then
			swordData.model:PivotTo(targetCFrame)
		else
			swordData.primary.CFrame = targetCFrame
		end
	end

	-- 控制飞剑可见性；如果 Studio 里是多部件模型，也能一起隐藏/显示。
	local function setSwordTransparency(swordData, transparency)
		if not swordData or not swordData.model then return end
		if swordData.model:IsA("Model") then
			for _, obj in ipairs(swordData.model:GetDescendants()) do
				if obj:IsA("BasePart") then
					obj.Transparency = transparency
				end
			end
		elseif swordData.primary then
			swordData.primary.Transparency = transparency
		end
	end

	-- 生成安全的朝向 CFrame；当目标点和当前位置重合时，用默认方向兜底，避免 Unit 产生 NaN。
	local function getLookCFrame(position, targetPosition)
		local delta = targetPosition - position
		local lookDir = delta.Magnitude > 0.01 and delta.Unit or Vector3.new(0, 0, -1)
		return CFrame.lookAt(position, position + lookDir)
	end

	-- 判断御剑当前目标是否仍然有效；目标死亡、被销毁或 hp 归零时都不再结算伤害。
	local function isSwordTargetAlive(enemy)
		return enemy and enemy.part and enemy.part.Parent and (enemy.hp or 0) > 0
	end

	-- 从 Encounter.ActiveEnemies 移除指定怪物，防止御剑击杀后怪物残留在碰撞/索敌列表里。
	local function removeEnemyFromActiveList(enemy)
		local activeEnemies = Controllers.Encounter.ActiveEnemies
		for i = #activeEnemies, 1, -1 do
			if activeEnemies[i] == enemy then
				table.remove(activeEnemies, i)
				return
			end
		end
	end

	-- 处理御剑击杀怪物的统一结算：播放死亡特效、掉落、销毁模型，并清理 ActiveEnemies。
	local function killEnemyBySword(enemy, hitPos, Config)
		local deathVfx = Config.ENEMY_VFX[enemy.type] or "BasicDeath"
		Controllers.VFX.PlayDeathVFX(deathVfx, hitPos)
		Controllers.Encounter.TriggerDrops(enemy.type, hitPos)
		removeEnemyFromActiveList(enemy)
		if enemy.part then
			enemy.part:Destroy()
		end
	end

	-- 清理飞剑本轮攻击缓存，避免归位后沿用旧目标或旧伤害。
	local function clearSwordAttackData(swordData)
		swordData.targetEnemy = nil
		swordData.damage = nil
		swordData.attackStartPos = nil
		swordData.attackTargetPos = nil
		swordData.attackProgress = nil
		swordData.attackDuration = nil
	end

	-- 下达飞剑出击命令；真正的飞行动画和命中结算交给 RenderStepped 状态机执行。
	local function setSwordAttack(swordData, targetEnemy, swordDmg, sc)
		if not swordData or swordData.state ~= "Orbiting" or not isSwordTargetAlive(targetEnemy) then return false end

		local currentCFrame = getSwordCFrame(swordData)
		if not currentCFrame then return false end

		local targetPos = targetEnemy.part.Position
		local distance = (targetPos - currentCFrame.Position).Magnitude
		swordData.state = "Attacking"
		swordData.targetEnemy = targetEnemy
		swordData.damage = swordDmg
		swordData.attackStartPos = currentCFrame.Position
		swordData.attackTargetPos = targetPos
		swordData.attackProgress = 0
		swordData.attackDuration = math.max(distance / sc.FlySpeed, 0.05)
		return true
	end

	-- 1. 视觉层：飞剑动态状态机 (每帧更新)
	RunService.RenderStepped:Connect(function(dt)
		if not Controllers.Game.IsCombatActive then
			-- 非战斗状态强制隐藏
			for _, s in ipairs(orbitingSwords) do
				setSwordTransparency(s, 1)
				if s.state == "Attacking" then
					clearSwordAttackData(s)
					s.state = "Returning"
				end
			end
			return
		end

		-- 玩家没解锁技能或者死亡时，清空飞剑
		local unlocked = (player:GetAttribute("Sword_Unlocked") or 0) > 0
		if not unlocked then
			for _, s in ipairs(orbitingSwords) do if s.model then s.model:Destroy() end end
			table.clear(orbitingSwords)
			return
		end

		local character = player.Character
		if not character or not character.PrimaryPart then return end
		local playerPos = character.PrimaryPart.Position
		local sc = Controllers.Config.SWORD_SKILL
		local count = math.min((player:GetAttribute("Sword_Count") or 0) + 1, sc.MaxCount)

		-- 动态增删视觉飞剑 (对接 Studio 模型)
		while #orbitingSwords < count do
			local rs = game:GetService("ReplicatedStorage")
			local prefab = rs:FindFirstChild("Model") and rs.Model:FindFirstChild("Skills") and rs.Model.Skills:FindFirstChild("FlyingSword")
			local swordPart

			if prefab then
				swordPart = prefab:Clone()
				if swordPart:IsA("Model") and not swordPart.PrimaryPart then
					swordPart.PrimaryPart = swordPart:FindFirstChildWhichIsA("BasePart", true)
				end
			else
				swordPart = Instance.new("Part")
				swordPart.Size = Vector3.new(0.5, 0.5, 3)
				swordPart.Color = Color3.fromRGB(0, 255, 255)
				swordPart.Material = Enum.Material.Neon
			end

			local targetPart = swordPart:IsA("Model") and swordPart.PrimaryPart or swordPart
			if not targetPart or not targetPart:IsA("BasePart") then
				warn("[CombatController] FlyingSword 模型缺少 BasePart，已使用白模飞剑兜底")
				if swordPart then swordPart:Destroy() end
				swordPart = Instance.new("Part")
				swordPart.Size = Vector3.new(0.5, 0.5, 3)
				swordPart.Color = Color3.fromRGB(0, 255, 255)
				swordPart.Material = Enum.Material.Neon
				targetPart = swordPart
			end
			targetPart.Anchored = true
			targetPart.CanCollide = false
			swordPart.Parent = Workspace:FindFirstChild("LocalProjectiles") or Workspace

			table.insert(orbitingSwords, { model = swordPart, primary = targetPart, state = "Orbiting" })
		end
		while #orbitingSwords > count do
			local removed = table.remove(orbitingSwords)
			if removed.model then removed.model:Destroy() end
		end

		-- 计算基础环绕角度
		globalOrbitAngle = (globalOrbitAngle + dt * 3) % (math.pi * 2)

		-- 驱动每个飞剑的状态机
		for i, swordData in ipairs(orbitingSwords) do
			local offsetAngle = globalOrbitAngle + (i / count) * (math.pi * 2)
			local orbitPos = playerPos + Vector3.new(math.cos(offsetAngle) * sc.OrbitRadius, 2, math.sin(offsetAngle) * sc.OrbitRadius)
			local currentCFrame = getSwordCFrame(swordData)
			if not currentCFrame then continue end
			local currentPos = currentCFrame.Position

			if swordData.state == "Orbiting" then
				-- 环绕状态：围绕玩家平滑飞行，剑尖顺着圆弧切线方向
				local lookDir = Vector3.new(math.cos(offsetAngle + math.pi/2), 0, math.sin(offsetAngle + math.pi/2))
				local targetCFrame = CFrame.lookAt(orbitPos, orbitPos + lookDir)

				pivotSwordTo(swordData, currentCFrame:Lerp(targetCFrame, dt * 10))
				setSwordTransparency(swordData, 0)

			elseif swordData.state == "Returning" then
				-- 归位状态：剑打完人后，暴力 Lerp 追赶自己应当所处的圆弧位置
				local newPos = currentPos:Lerp(orbitPos, dt * 18) -- 18 是极快的归位速度
				pivotSwordTo(swordData, getLookCFrame(newPos, orbitPos))

				-- 归位距离小于 1 Stud 时，解除归位状态，平滑融入环绕
				if (newPos - orbitPos).Magnitude < 1.5 then
					clearSwordAttackData(swordData)
					swordData.state = "Orbiting"
				end
			elseif swordData.state == "Attacking" then
				-- 攻击状态：每帧推进飞剑到目标点；升级选卡或战斗暂停时立刻停止结算并归位
				if player:GetAttribute("IsLevelingUp") or not Controllers.Game.IsCombatActive then
					clearSwordAttackData(swordData)
					swordData.state = "Returning"
					continue
				end

				local targetEnemy = swordData.targetEnemy
				if not isSwordTargetAlive(targetEnemy) then
					clearSwordAttackData(swordData)
					swordData.state = "Returning"
					continue
				end

				local targetPos = targetEnemy.part.Position
				swordData.attackTargetPos = targetPos
				swordData.attackProgress = math.min((swordData.attackProgress or 0) + dt / (swordData.attackDuration or 0.05), 1)

				local startPos = swordData.attackStartPos or currentPos
				local newPos = startPos:Lerp(targetPos, swordData.attackProgress)
				pivotSwordTo(swordData, getLookCFrame(newPos, targetPos))

				if swordData.attackProgress >= 1 then
					-- 命中前再次确认战斗状态，避免选卡暂停瞬间仍然扣血或击杀怪物
					if Controllers.Game.IsCombatActive and not player:GetAttribute("IsLevelingUp") and isSwordTargetAlive(targetEnemy) then
						local hitPos = targetEnemy.part.Position
						targetEnemy.hp = targetEnemy.hp - (swordData.damage or 0)
						targetEnemy.label.Text = Controllers.Config.FormatNumber(math.max(0, targetEnemy.hp))
						Controllers.VFX.PlayHitJitterVFX(targetEnemy.part, targetEnemy.baseSize)
						Controllers.VFX.PlayBulletExplosion("DefaultHit", hitPos)

						if targetEnemy.hp <= 0 then
							killEnemyBySword(targetEnemy, hitPos, Controllers.Config)
						end
					end

					clearSwordAttackData(swordData)
					swordData.state = "Returning"
				end
			end
		end
	end)

	-- 2. 逻辑层：飞剑出鞘索敌制导 (独立协程)
	task.spawn(function()
		local Config = Controllers.Config
		while true do
			if not Controllers.Game.IsCombatActive or player:GetAttribute("IsLevelingUp") or (player:GetAttribute("Sword_Unlocked") or 0) <= 0 then
				task.wait(player:GetAttribute("IsLevelingUp") and 0.1 or 0.5)
				continue
			end

			local sc = Config.SWORD_SKILL
			local cdReduction = math.min(player:GetAttribute("Sword_CD_Reduction") or 0, sc.MaxCooldownReduction)
			local actualCd = math.max(sc.MinAttackInterval, sc.BaseAttackInterval * (1 - (cdReduction / 100)))

			local character = player.Character
			if character and character.PrimaryPart then
				local playerPos = character.PrimaryPart.Position
				local enemies = Controllers.Encounter.ActiveEnemies
				local validTargets = {}

				-- 寻找前方且在射程内的敌人
				for _, e in ipairs(enemies) do
					if e and e.part and e.part.Parent and e.hp > 0 then
						local ePos = e.part.Position
						if ePos.Z < playerPos.Z then -- 游戏向负Z方向跑，小于代表在前方
							local dist = (ePos - playerPos).Magnitude
							if dist <= sc.TargetRange then table.insert(validTargets, {enemy = e, dist = dist}) end
						end
					end
				end

				if #validTargets > 0 then
					-- 排序：优先最近
					table.sort(validTargets, function(a, b) return a.dist < b.dist end)
					local atkBonus = player:GetAttribute("Sword_ATK_Bonus") or 0
					local swordDmg = math.floor(sc.BaseDamage * (1 + (atkBonus / 100)))

					-- 安排空闲飞剑依次出鞘；这里只下达攻击状态，飞行动画和命中结算由 RenderStepped 统一执行
					for _, swordData in ipairs(orbitingSwords) do
						if swordData.state == "Orbiting" then
							if not Controllers.Game.IsCombatActive or player:GetAttribute("IsLevelingUp") then
								break
							end

							local targetEnemy
							for _, targetInfo in ipairs(validTargets) do
								if isSwordTargetAlive(targetInfo.enemy) then
									targetEnemy = targetInfo.enemy
									break
								end
							end

							if targetEnemy and setSwordAttack(swordData, targetEnemy, swordDmg, sc) then
								-- 错峰打击：每把剑出击间隔 0.08 ~ 0.15 秒
								task.wait(math.random(8, 15) / 100)
							end
						end
					end
				end
			end
			-- 等待实际的攻击间隔(CD)
			task.wait(actualCd)
		end
	end)
end

return CombatController
