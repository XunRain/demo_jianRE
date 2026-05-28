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
	-- 维持自动射击节奏
	task.spawn(function()
		while true do
			-- 只有在战斗中并且没被暂停时才开枪
			if Controllers.Game.IsCombatActive and not player:GetAttribute("IsLevelingUp") then
				local aspd = player:GetAttribute("ASPD") or Controllers.Config.BASE_ASPD
				if aspd <= 0.1 then aspd = 0.1 end -- 兜底机制，防止负数攻速引发死循环报错
				CombatController.ShootProjectile()
				task.wait(1 / aspd)
			else
				task.wait(0.1) 
			end
		end
	end)
end

-- 生成并弹射子弹模型
function CombatController.ShootProjectile()
	local character = player.Character
	if not character or not character.PrimaryPart then return end
	
	local humanoid = character:FindFirstChild("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return end
	local rootPart = character.PrimaryPart
	
	-- 1. 查找武器配置
	local equippedWeapon = player:GetAttribute("EquippedWeapon") or "DefaultWeapon"
	local weaponConfig = Controllers.Config.WEAPONS[equippedWeapon] or Controllers.Config.WEAPONS["DefaultWeapon"]
	
	-- 2. 尝试从 ReplicatedStorage 提取子弹预制体
	local bullet = nil
	local vfxFolder = ReplicatedStorage:FindFirstChild("VFX")
	local weaponsFolder = vfxFolder and vfxFolder:FindFirstChild("Weapons")
	local bulletPrefab = weaponsFolder and weaponsFolder:FindFirstChild(weaponConfig.BulletVFX)
	-- 只取玩家的绝对位置，抛弃身体的扭转角度
	local spawnPos = rootPart.Position + Vector3.new(0, 0, -2)
	
	if bulletPrefab then
		bullet = bulletPrefab:Clone()
		if bullet:IsA("Model") then
			-- 纯净位置 + 预制体在 Studio 里的完美原始朝向
			bullet:PivotTo(CFrame.new(spawnPos) * bulletPrefab:GetPivot().Rotation)
		else
			bullet.CFrame = CFrame.new(spawnPos) * bulletPrefab.CFrame.Rotation
		end
	else
		-- 【兜底保护】：如果你还没在 Studio 里建好对应特效，自动降级为默认白模！
		bullet = Instance.new("Part")
		bullet.Size = Vector3.new(1, 1, 2)
		bullet.Color = Color3.fromRGB(0, 255, 255)
		bullet.Material = Enum.Material.Neon
		bullet.CFrame = rootPart.CFrame * CFrame.new(0, 0, -2)
	end
	
	-- 3. 施加物理推动力
	local targetPart = bullet:IsA("Model") and bullet.PrimaryPart or bullet
	-- 如果是 Model 但没设置 PrimaryPart，自动找一个 Part 顶替
	if bullet:IsA("Model") and not targetPart then
		targetPart = bullet:FindFirstChildWhichIsA("BasePart", true)
		bullet.PrimaryPart = targetPart
	end
	if targetPart and targetPart:IsA("BasePart") then
		-- 遍历子弹的所有部件，强制取消碰撞并解除锚定！
		-- 这样物理引擎的 LinearVelocity 才能真正推动它飞行
		local partsToProcess = bullet:IsA("Model") and bullet:GetDescendants() or {}
		table.insert(partsToProcess, bullet) -- 把本体也塞进去一起处理
		
		for _, obj in ipairs(partsToProcess) do
			if obj:IsA("BasePart") then
				obj.CanCollide = false
				obj.Anchored = false  -- 彻底解开物理封印！
			end
		end
		
		local bv = Instance.new("LinearVelocity")
		local attachment = Instance.new("Attachment", targetPart)
		bv.Attachment0 = attachment

		-- 强制参照世界坐标系飞行
		-- 无论剑的模型怎么转，它都必须死死贴着 Z轴 的负方向直线飞驰
		bv.RelativeTo = Enum.ActuatorRelativeTo.World 
		-- 读取动态弹速 (找不到时用配置表兜底)
		local currentSpd = player:GetAttribute("SPD") or Controllers.Config.BASE_SPD
		bv.VectorVelocity = Vector3.new(0, 0, -currentSpd)

		bv.MaxForce = math.huge
		bv.Parent = targetPart
	end
	
	local localProjectiles = Workspace:FindFirstChild("LocalProjectiles") or Instance.new("Folder", Workspace)
	localProjectiles.Name = "LocalProjectiles"
	bullet.Parent = localProjectiles

	-- 获取玩家的动态弹速和动态射程距离
	local currentSpd = player:GetAttribute("SPD") or Controllers.Config.BASE_SPD
	local currentRng = player:GetAttribute("RNG") or Controllers.Config.BASE_RNG
	
	-- 【核心修改】：通过 距离/速度 计算出子弹真正应该存活的时间
	local actualLifetime = currentRng / currentSpd
	
	-- 按照计算出的精准时间销毁子弹
	game.Debris:AddItem(bullet, actualLifetime)
	
	-- 【核心】：记录子弹时，把它是哪把武器射出来的标记带上！
	local playerAtk = player:GetAttribute("ATK") or Controllers.Config.BASE_ATK
	table.insert(CombatController.ActiveBullets, { part = bullet, damage = playerAtk, weaponId = equippedWeapon })
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
			
			local ePos = e.part.Position
			local eSize = e.part.Size
			
			-- X轴与Z轴的范围判定
			if math.abs(bPos.X - ePos.X) < (eSize.X/2 + 1) and 
			   math.abs(bPos.Z - ePos.Z) < (eSize.Z/2 + 2) then 
				
				-- 扣除的血量等于这颗子弹自身携带的伤害值，如果是 nil 兜底为玩家伤害
				local dmg = b.damage or (player:GetAttribute("ATK") or Controllers.Config.BASE_ATK)
				e.hp = e.hp - dmg
				e.label.Text = tostring(e.hp)

				-- 播放怪物受击“一大一小”抖动！
				Controllers.VFX.PlayHitJitterVFX(e.part, e.baseSize)
				
				-- 读取子弹身份，播放专属爆炸特效！
				local weaponConfig = Controllers.Config.WEAPONS[b.weaponId] or Controllers.Config.WEAPONS["DefaultWeapon"]
				Controllers.VFX.PlayBulletExplosion(weaponConfig.HitVFX, bPos)
				
				b.part:Destroy()
				table.remove(CombatController.ActiveBullets, i)
				
				-- 怪物血条清空
				if e.hp <= 0 then
					-- 播放怪物死亡特效
					-- 根据怪物类型 (Basic/Elite/Boss) 去配置表拿对应的特效名字
					local deathVfxName = Controllers.Config.ENEMY_VFX[e.type] or "BasicDeath"
					Controllers.VFX.PlayDeathVFX(deathVfxName, ePos)

					e.part:Destroy()
					table.remove(activeEnemies, j)
					-- 呼叫 EncounterController 爆出战利品满地散落
					Controllers.Encounter.TriggerDrops(e.type, ePos)
				end
				break -- 一颗子弹只打一个怪
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
			if sourceVFX and rootPart then
				Controllers.VFX.PlayGateVFX(rootPart)
			end

			-- 门的 HP 属性现在只影响“当前血量”，不再修改“生命上限”
			if chosenGate.attr == "HP" then
				local currentMax = player:GetAttribute("MaxHP") or Controllers.Config.BASE_HP
				local currentHp = player:GetAttribute("HP") or Controllers.Config.BASE_HP
				
				-- 门加血或扣血，最高不能超过当前的 MaxHP，最低为 1（避免吃扣血门直接暴毙）
				local newHp = math.clamp(currentHp + chosenGate.amount, 1, currentMax)
				player:SetAttribute("HP", newHp)
				
				-- 同步给原生的 Humanoid 人偶模型，确保底层逻辑一致
				local humanoid = player.Character and player.Character:FindFirstChild("Humanoid")
				if humanoid then
					humanoid.Health = newHp
				end
			else
				local currentVal = player:GetAttribute(chosenGate.attr) or 0
				player:SetAttribute(chosenGate.attr, currentVal + chosenGate.amount)
			end
			-- =======================================================
			
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