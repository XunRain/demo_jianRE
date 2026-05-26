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
			local equipped = player:GetAttribute("EquippedPet")
			if equipped and equipped ~= "" and Controllers.Game.IsCombatActive and not player:GetAttribute("IsLevelingUp") then
				local petConfig = Controllers.Config.PETS[equipped]
				if currentPetModel and petConfig then
					PetController.ShootProjectile(petConfig)
					task.wait(1 / petConfig.ASPD)
					continue
				end
			end
			task.wait(0.2)
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

function PetController.ShootProjectile(petConfig)
	if not currentPetModel then return end
	
	local bullet = Instance.new("Part")
	bullet.Size = Vector3.new(0.5, 0.5, 3)
	bullet.Color = petConfig.Color -- 子弹颜色和宠物一样
	bullet.Material = Enum.Material.Neon
	bullet.CanCollide = false
	bullet.CFrame = currentPetModel:GetPivot() * CFrame.new(0, 0, -2)
	
	local bv = Instance.new("LinearVelocity")
	local attachment = Instance.new("Attachment", bullet)
	bv.Attachment0 = attachment
	bv.VectorVelocity = Vector3.new(0, 0, -Controllers.Config.BULLET_SPEED) 
	bv.MaxForce = math.huge
	bv.Parent = bullet
	
	local folder = Workspace:FindFirstChild("LocalProjectiles")
	bullet.Parent = folder
	game.Debris:AddItem(bullet, Controllers.Config.BULLET_LIFETIME) 
	
	-- 【核心】：将宠物的子弹塞进 CombatController 的判定池里，并附带宠物的固定攻击力！
	table.insert(Controllers.Combat.ActiveBullets, { part = bullet, damage = petConfig.ATK })
end

return PetController