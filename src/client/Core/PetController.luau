-- src/client/Core/PetController.luau
-- 宠物控制：物理跟随与开火
local PetController = {}

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer
local Controllers

local currentPetModel = nil

function PetController.Init(deps)
	Controllers = deps
end

function PetController.Start()
	print("🐾 PetController.Start() 已成功被调用，循环开始运行！")
	-- 监听装备宠物变动，刷新实体模型
	player:GetAttributeChangedSignal("EquippedPet"):Connect(PetController.RefreshPetModel)
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
			-- 1. 检查战斗与升级状态
			if Controllers.Game.IsCombatActive and not player:GetAttribute("IsLevelingUp") then
				
				-- 2. 检查玩家是否装备了宠物
				local equippedPet = player:GetAttribute("EquippedPet") 
				if not equippedPet or equippedPet == "" then
					-- print("当前没有装备宠物...") 
					task.wait(1)
					continue
				end
				
				-- 3. 检查配置表里有没有这个宠物
				local petConfig = Controllers.Config.PETS and Controllers.Config.PETS[equippedPet]
				if not petConfig then
					warn("⚠️ 宠物表里找不到这个宠物的配置: ", equippedPet)
					task.wait(1)
					continue
				end
			
				-- 寻找宠物模型
				local character = player.Character
				local petModel = Workspace:FindFirstChild("ActivePet") 
				                 or (character and character:FindFirstChild("ActivePet"))
				                 or Workspace:FindFirstChild(equippedPet)
				                 or (character and character:FindFirstChild(equippedPet))
				
				if not petModel then
					warn("⚠️ 宠物属性都有，但在 3D 场景里找不到宠物模型！请检查你生成宠物时给它命名成了什么，以及放到了哪个 Parent 下！")
					task.wait(1)
					continue
				end

				-- 4. 万事俱备，执行开火
				local petAspd = petConfig.ASPD or 1
				local actualInterval = 1 / petAspd
				
				PetController.ShootProjectile(petConfig, petModel)
				task.wait(actualInterval)
				
			else
				-- 没有进入战斗，或者正在选卡片
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

	-- 【核心修复】：去 ReplicatedStorage 寻找真实的宠物模型
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local petModels = ReplicatedStorage:FindFirstChild("Pets")
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

	-- 给宠物加上名字牌 (智能判断挂载点)
	-- local targetPart = currentPetModel:IsA("Model") and currentPetModel.PrimaryPart or currentPetModel
	-- if targetPart then
	-- 	Controllers.VFX.CreateBillboard(targetPart, "✨" .. petConfig.Name, Color3.new(1,1,1), 1.5)
	-- else
	-- 	warn("宠物模型缺少 PrimaryPart，无法挂载名字牌！")
	-- end
end

-- 生成并弹射宠物子弹
function PetController.ShootProjectile(petConfig, petModel)
	if not petModel or not petModel.PrimaryPart then return end
	
	-- 宠物的发射点在宠物模型前方
	local spawnPos = petModel.PrimaryPart.Position + Vector3.new(0, 0, -2)
	
	-- 【落实公式】：宠物继承玩家的百分比弹速与射程加成
	local baseSpd = Controllers.Config.BASE_SPD
	local spdBonus = player:GetAttribute("SPD_Bonus") or 0
	local currentSpd = baseSpd * (1 + (spdBonus / 100))
	
	local baseRng = Controllers.Config.BASE_RNG
	local rngBonus = player:GetAttribute("RNG_Bonus") or 0
	local currentRng = baseRng * (1 + (rngBonus / 100))
	
	local actualLifetime = currentRng / currentSpd

	-- 创建宠物子弹 (可以用统一的圆球或者你配置的特效)
	local bullet = Instance.new("Part")
	bullet.Size = Vector3.new(1, 1, 1)
	bullet.Shape = Enum.PartType.Ball
	bullet.Color = Color3.fromRGB(255, 255, 100) -- 宠物子弹弄个醒目的颜色
	bullet.Material = Enum.Material.Neon
	bullet.CFrame = CFrame.new(spawnPos)
	bullet.CanCollide = false
	bullet.Anchored = false
	
	local bv = Instance.new("LinearVelocity")
	local attachment = Instance.new("Attachment", bullet)
	bv.Attachment0 = attachment
	bv.RelativeTo = Enum.ActuatorRelativeTo.World 
	-- 宠物直接往正前方打
	bv.VectorVelocity = Vector3.new(0, 0, -currentSpd)
	bv.MaxForce = math.huge
	bv.Parent = bullet
	
	local localProjectiles = Workspace:FindFirstChild("LocalProjectiles") or Instance.new("Folder", Workspace)
	bullet.Parent = localProjectiles
	game.Debris:AddItem(bullet, actualLifetime) 
	
	-- 宠物伤害：读取配置表里大天使/小火龙的自带固定攻击力
	local petDmg = petConfig.ATK or 10

	-- =======================================================
	-- 【核心修复】：为宠物子弹补齐防抖字段，完美兼容穿透碰撞检测！
	-- =======================================================
	table.insert(Controllers.Combat.ActiveBullets, { 
		part = bullet, 
		damage = petDmg, 
		weaponId = "PetWeapon", -- 占位符，防止特效检测报错
		hitsLeft = 1,           -- 宠物子弹默认穿透 1 次 (即碰到就销毁)
		hitTargets = {}         -- 必须加这个空表！否则碰到怪瞬间报错卡死
	})
end

return PetController