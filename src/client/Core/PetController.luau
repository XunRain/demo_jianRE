-- src/client/Core/PetController.luau
-- 宠物控制：物理跟随与开火
local PetController = {}

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer
local Controllers
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local currentPetModel = nil

function PetController.Init(deps)
	Controllers = deps
end

function PetController.Start()
	print("🐾 PetController.Start() 已成功被调用，循环开始运行！")
	-- 监听装备宠物变动，刷新实体模型
	player:GetAttributeChangedSignal("EquippedPet"):Connect(PetController.RefreshPetModel)
	-- 玩家每次死亡重生后，必须重新把宠物召唤出来！
	player.CharacterAdded:Connect(function()
		task.wait(0.1) -- 等待肉身加载完毕
		PetController.RefreshPetModel()
	end)
	PetController.RefreshPetModel()

	-- 渲染循环：控制宠物平滑跟随玩家
	RunService.RenderStepped:Connect(function(dt)
		if not currentPetModel or not player.Character then return end
		local rootPart = player.Character:FindFirstChild("HumanoidRootPart")
		if not rootPart then return end

		local targetCFrame
		if Controllers.Game.IsCombatActive then
			-- 战斗状态：飘在玩家右侧前方，准备战斗
			targetCFrame = rootPart.CFrame * CFrame.new(6, 2, -2)
		else
			-- 大厅状态：懒洋洋地跟在玩家左后方
			targetCFrame = rootPart.CFrame * CFrame.new(-4, 2.5, 4)
		end
		
		-- 【核心修复】：使用 GetPivot() 和 PivotTo() 替代原有的 CFrame
		-- 这样无论 currentPetModel 是一个 Part 还是一个包含了几百个零件的 Model，都能完美整体平滑移动！
		local currentPivot = currentPetModel:GetPivot()
		currentPetModel:PivotTo(currentPivot:Lerp(targetCFrame, dt * 5))
	end)



	-- 宠物独立开火循环
	task.spawn(function()
		while true do
			if Controllers.Game.IsCombatActive and not player:GetAttribute("IsLevelingUp") then
				local equippedPet = player:GetAttribute("EquippedPet") 
				if not equippedPet or equippedPet == "" then task.wait(1); continue end
				
				local petConfig = Controllers.Config.PETS and Controllers.Config.PETS[equippedPet]
				if not petConfig then task.wait(1); continue end
			
				local character = player.Character
				if not character then task.wait(1); continue end
				
				-- 【修改】：收集所有宠物 (本体 + 分身)
				local activePets = {}
				for _, child in ipairs(character:GetChildren()) do
					if child.Name == "ActivePet" or string.match(child.Name, "^ActivePet_Clone") then
						table.insert(activePets, child)
					end
				end
				
				if #activePets == 0 then task.wait(1); continue end

				-- 【修改】：计算享受加成后的攻速 (频率提升 = 冷却缩减)
				local aspdBonus = player:GetAttribute("Pet_ASPD_Bonus") or 0
				local baseCooldown = petConfig.Cooldown or 2
				local actualCooldown = baseCooldown / (1 + (aspdBonus / 100))
				
				local castCount = petConfig.CastCount or 1
				
				for i = 1, castCount do
					if not Controllers.Game.IsCombatActive then break end
					-- 让所有分身和本体同时开火！
					for _, pModel in ipairs(activePets) do
						PetController.ShootProjectile(petConfig, pModel)
					end
					if i < castCount then task.wait(0.15) end 
				end
				
				task.wait(actualCooldown) 
			else
				task.wait(0.5) 
			end
		end
	end)
end

function PetController.RefreshPetModel()
	if currentPetModel then currentPetModel:Destroy() end
	local equipped = player:GetAttribute("EquippedPet")
	if not equipped or equipped == "" then return end

	local petConfig = Controllers.Config.PETS[equipped]
	if not petConfig then return end

	-- 必须等待玩家肉身存在，才能给它挂载宠物
	local character = player.Character
	if not character then return end

	-- 【核心修复】：去 ReplicatedStorage 寻找真实的宠物模型
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local petModels = ReplicatedStorage:FindFirstChild("Model"):FindFirstChild("Pets")
	local petTemplate = petModels and petModels:FindFirstChild(equipped)

	if petTemplate then
		currentPetModel = petTemplate:Clone()
		-- 遍历模型里的所有零件，确保它们不会卡住玩家，且不会掉下虚空
		for _, part in ipairs(currentPetModel:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
				part.CanCollide = false
			end
		end
		currentPetModel.Parent = Workspace
	else
		-- 兜底：如果策划配了表，但美术还没做模型，就继续用原来的方块
		currentPetModel = Instance.new("Part")
		currentPetModel.Size = Vector3.new(2, 2, 2)
		currentPetModel.Color = petConfig.Color
		currentPetModel.Anchored = true
		currentPetModel.CanCollide = false
		currentPetModel.Material = Enum.Material.Neon
		currentPetModel.Parent = Workspace
	end

	-- 统一命名并挂载到 Character 下
	currentPetModel.Name = "ActivePet"
	currentPetModel.Parent = character

	-- 联动修复：如果在带分身的状态下换宠物，连带着分身一起刷新
	if Controllers.Pet and Controllers.Pet.UpdatePetClones then
		Controllers.Pet.UpdatePetClones()
	end
end

-- 生成并弹射宠物子弹
function PetController.ShootProjectile(petConfig, petModel)
	if not petModel then return end
	
	-- 使用 GetPivot() 强制获取美术模型的中心点
	local petPivot = petModel:GetPivot()
	local playerPos = petPivot.Position

	local spawnPos = playerPos + Vector3.new(0, 0, -2)
	local baseSpd = Controllers.Config.BASE_SPD
	local currentSpd = baseSpd * (1 + ((player:GetAttribute("SPD_Bonus") or 0) / 100))
	local currentRng = Controllers.Config.BASE_RNG * (1 + ((player:GetAttribute("RNG_Bonus") or 0) / 100))
	local actualLifetime = currentRng / currentSpd

	-- 读取百分比增益，增加宠物攻击
	local atkBonus = player:GetAttribute("Pet_ATK_Bonus") or 0
	local petDmg = (petConfig.ATK or 10) * (1 + (atkBonus / 100))
	local skillType = petConfig.SkillType or "WindBlade"
	local bulletVfxName = petConfig.BulletVFX 
	local hitVfx = petConfig.HitVFX
	local pierce = petConfig.PierceCount or 1
	local aoe = petConfig.AOERadius
	
	-- 【公用模块】：前场智能雷达 (寻找前方最近的活物)
	local enemies = Controllers.Encounter.ActiveEnemies
	local playerPos = petModel.PrimaryPart.Position
	local targetEnemy = nil
	local minDistance = math.huge
	
	for _, e in ipairs(enemies) do
		if e and e.part and e.part.Parent and e.hp > 0 then
			local ePos = e.part.Position
			-- 只扫描前方的怪物
			if ePos.Z < playerPos.Z then
				local dist = (ePos - playerPos).Magnitude
				if dist < minDistance then
					minDistance = dist
					targetEnemy = e
				end
			end
		end
	end

	-- 【特殊技能前置判定】
	local smiteTargetPos = nil
	if skillType == "Smite" then
		if not targetEnemy then return end -- 大天使：没怪就不劈，直接返回
		smiteTargetPos = targetEnemy.part.Position 
		actualLifetime = 0.5 
	end

	-- 生成与发射逻辑
	local vfxFolder = ReplicatedStorage:FindFirstChild("VFX")
	local petsVfxFolder = vfxFolder and vfxFolder:FindFirstChild("Pets")
	local bulletPrefab = petsVfxFolder and petsVfxFolder:FindFirstChild(bulletVfxName)
	
	local bullet
	
	if bulletPrefab then
		-- 情况 A：美术做好了子弹模型
		bullet = bulletPrefab:Clone()
		local mainPart = bullet:IsA("Model") and bullet.PrimaryPart or bullet
		
		if skillType == "Smite" and smiteTargetPos then
			bullet:PivotTo(CFrame.new(smiteTargetPos))
			if mainPart then mainPart.Anchored = true end
		else
			bullet:PivotTo(CFrame.new(spawnPos))
			local att = Instance.new("Attachment", mainPart)
			local bv = Instance.new("LinearVelocity")
			bv.Attachment0 = att
			bv.RelativeTo = Enum.ActuatorRelativeTo.World 
			bv.VectorVelocity = Vector3.new(0, 0, -currentSpd)
			bv.MaxForce = math.huge
			bv.Parent = mainPart
			
			-- 【核心追踪逻辑】小火龙：动态修改速度方向
			if skillType == "Fireball" and targetEnemy then
				task.spawn(function()
					-- 只要子弹还没爆，且怪物还活着，就持续导航
					while bullet and bullet.Parent and targetEnemy and targetEnemy.part and targetEnemy.part.Parent and targetEnemy.hp > 0 do
						local currentPos = mainPart.Position
						local targetPos = targetEnemy.part.Position
						local dir = (targetPos - currentPos).Unit
						-- 追踪时速度可以稍微加快一点(2倍)，体现出火球的侵略性
						bv.VectorVelocity = dir * (currentSpd * 2) 
						task.wait(0.05) -- 每 0.05 秒修正一次航向
					end
				end)
			end
		end
	else
		-- 情况 B：兜底逻辑（无模型时使用代码生成方块）
		bullet = Instance.new("Part")
		bullet.Anchored = false
		bullet.CanCollide = false
		bullet.Material = Enum.Material.Neon
		bullet.Color = petConfig.Color
		
		if skillType == "Smite" and smiteTargetPos then
			bullet.Size = Vector3.new(4, 40, 4) 
			bullet.Shape = Enum.PartType.Cylinder
			bullet.CFrame = CFrame.new(smiteTargetPos) * CFrame.Angles(0, 0, math.rad(90)) 
			bullet.Anchored = true 
		else
			if skillType == "WindBlade" then
				bullet.Size = Vector3.new(12, 1, 3) 
				bullet.Shape = Enum.PartType.Block
			elseif skillType == "Fireball" then
				bullet.Size = Vector3.new(4, 4, 4) 
				bullet.Shape = Enum.PartType.Ball
			end
			
			bullet.CFrame = CFrame.new(spawnPos)
			local att = Instance.new("Attachment", bullet)
			local bv = Instance.new("LinearVelocity")
			bv.Attachment0 = att
			bv.RelativeTo = Enum.ActuatorRelativeTo.World 
			bv.VectorVelocity = Vector3.new(0, 0, -currentSpd)
			bv.MaxForce = math.huge
			bv.Parent = bullet
			
			-- 【核心追踪逻辑】兜底版
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

	table.insert(Controllers.Combat.ActiveBullets, { 
		part = bullet:IsA("Model") and bullet.PrimaryPart or bullet, 
		damage = petDmg, 
		weaponId = "PetWeapon",
		hitsLeft = pierce,           
		hitTargets = {},         
		hitVFX = hitVfx,       
		aoeRadius = aoe,       
		isPet = true,
		persistAfterHit = (skillType == "Smite")
	})
end

-- 更新宠物分身，并使其自动跟随玩家身后
function PetController.UpdatePetClones()
	local character = player.Character
	if not character then return end
	
	local mainPet = character:FindFirstChild("ActivePet")
	if not mainPet then return end
	
	local targetCount = player:GetAttribute("Pet_Count") or 1
	
	-- 清理旧的分身
	for _, child in ipairs(character:GetChildren()) do
		if string.match(child.Name, "^ActivePet_Clone") then
			child:Destroy()
		end
	end
	
	-- 根据数量生成新分身
	for i = 2, targetCount do
		local clone = mainPet:Clone()
		clone.Name = "ActivePet_Clone_" .. i
		clone.Parent = character
		
		-- 给分身绑定独立的平滑跟随逻辑
		task.spawn(function()
			local RunService = game:GetService("RunService")
			local connection
			connection = RunService.Heartbeat:Connect(function(dt)
				-- 如果分身或玩家没了，断开循环
				if not clone or not clone.Parent or not character or not character.PrimaryPart then
					connection:Disconnect()
					return
				end
				
				-- 计算身后位置：
				-- i=2 -> 玩家左后方, i=3 -> 玩家右后方
				local xOffset = (i % 2 == 0) and -3.5 or 3.5 
				local targetCFrame = character.PrimaryPart.CFrame * CFrame.new(xOffset, 2.5, 3)
				
				-- 直接使用 PivotTo()，无视美术是否设置了主零件
				clone:PivotTo(clone:GetPivot():Lerp(targetCFrame, 8 * dt))
			end)
		end)
	end
end

return PetController