-- src/client/Core/GameController.luau
-- 核心流程控制器：管理游戏整体生命周期（大厅状态、单局进入战斗、死亡重置结算、状态安全复原）
local GameController = {}

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera 

local Controllers -- 全局模块依赖依赖指针
GameController.IsCombatActive = false -- 核心全局开关：当前是否在跑道上处于战斗状态

-- 依赖注入：在系统启动时建立与其他模块的调用关系
function GameController.Init(deps)
	Controllers = deps
end

-- 模块生命周期启动入口：绑定事件及全局生命周期监听
function GameController.Start()
	-- 初始化挂载大厅交互触发器
	GameController.SetupStartButton()
	GameController.SetupNPC()
	
	-- 统一的角色重生/复活处理核心函数（彻底收拢生命周期，防止属性回厅变负数）
	local function onCharacterAdded(newCharacter)
		GameController.IsCombatActive = false
		player:SetAttribute("InCombat", false)
		
		-- 核心修复：复活重生回到大厅时，瞬间同步初始化基础数值
		GameController.ResetPlayerStats()
		
		local humanoid = newCharacter:WaitForChild("Humanoid", 5)
		if humanoid then
			-- 交还相机控制权给 Roblox 默认的自由跟拍系统
			camera.CameraType = Enum.CameraType.Custom
			camera.CameraSubject = humanoid
			camera.FieldOfView = 70
			
			-- 监听角色死亡事件，执行核心清场
			humanoid.Died:Connect(function()
				-- 如果玩家死在了第二关及以上，打上“需要引导”的思想钢印
				-- 【修改】：增加了对 HasSeenStage2Guide 的判断
				if (player:GetAttribute("CurrentStage") or 1) >= 2 and not player:GetAttribute("HasSeenStage2Guide") then
					player:SetAttribute("NeedsGuide", true)
					
					-- 触发引导的同时，立刻呼叫服务器打上永久标记，以后再死就不会触发了
					local remotes = game:GetService("ReplicatedStorage"):WaitForChild("Remotes")
					local markGuideEvent = remotes:FindFirstChild("MarkGuideSeen")
					if markGuideEvent then
						markGuideEvent:FireServer()
					end
				end

				GameController.IsCombatActive = false
				player:SetAttribute("InCombat", false)
				player:SetAttribute("IsLevelingUp", false)

				-- 1. 剥夺相机跟随，让相机以 Scriptable 模式永远定格在死亡瞬间的坐标！
				camera.CameraType = Enum.CameraType.Scriptable 
				
				-- 【终极安全版】：纯视觉替身布娃娃
				-- ==========================================
				newCharacter.Archivable = true
				local fakeCorpse = newCharacter:Clone()
				fakeCorpse.Name = "LocalCorpse"
				
				-- 2. 仅仅隐藏真实的物理角色，绝对不要去修改它的 Anchored 和 CanCollide！
				-- 让它自然穿过本地跑道掉进虚空，这样 Roblox 服务器就能完美判定死亡并触发正常的重生
				for _, obj in ipairs(newCharacter:GetDescendants()) do
					if obj:IsA("BasePart") then
						obj.Transparency = 1
					elseif obj:IsA("Decal") or obj:IsA("Texture") then
						obj.Transparency = 1
					end
				end
				
				-- 3. 把替身放到本地世界里
				fakeCorpse.Parent = Workspace
				local fakeHum = fakeCorpse:FindFirstChild("Humanoid")
				if fakeHum then
					fakeHum:ChangeState(Enum.HumanoidStateType.Physics)
					fakeHum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None -- 隐藏假尸体头顶的名字和血条
				end
				
				-- 4. 继承死亡瞬间的物理速度，让假尸体在跑道上翻滚
				for _, p in ipairs(newCharacter:GetDescendants()) do
					if p:IsA("BasePart") then
						local fakeP = fakeCorpse:FindFirstChild(p.Name, true)
						if fakeP and fakeP:IsA("BasePart") then
							fakeP.AssemblyLinearVelocity = p.AssemblyLinearVelocity
							fakeP.AssemblyAngularVelocity = p.AssemblyAngularVelocity
						end
					end
				end
				
				-- 5. 对替身执行布娃娃关节改造
				for _, desc in ipairs(fakeCorpse:GetDescendants()) do
					if desc:IsA("Motor6D") then
						if desc.Name == "Root" or desc.Name == "RootJoint" then
							desc:Destroy()
						else
							local part0 = desc.Part0
							local part1 = desc.Part1
							if part0 and part1 then
								local a0 = Instance.new("Attachment", part0)
								a0.CFrame = desc.C0
								local a1 = Instance.new("Attachment", part1)
								a1.CFrame = desc.C1
								
								local socket = Instance.new("BallSocketConstraint", desc.Parent)
								socket.Attachment0 = a0
								socket.Attachment1 = a1
								socket.LimitsEnabled = true
								socket.TwistLimitsEnabled = true
								
								desc:Destroy()
							end
						end
					end
				end

				-- 6. 仅开启替身核心躯干的碰撞，稳稳落在本地跑道上
				local coreParts = {"Head", "UpperTorso", "LowerTorso", "Torso"}
				for _, partName in ipairs(coreParts) do
					local part = fakeCorpse:FindFirstChild(partName)
					if part and part:IsA("BasePart") then
						part.CanCollide = true
					end
				end
				
				-- 2. 延迟 4 秒后再进行清场
				task.delay(4, function()
					-- 清理世界
					Controllers.Map.ClearTracks()
					Controllers.Encounter.ClearAll()
					Controllers.Combat.ClearBullets()
					if fakeCorpse then fakeCorpse:Destroy() end -- 记得销毁假尸体
					-- 恢复相机控制权，准备迎接大厅的新生肉体
					-- 重置回大厅时，确保相机的目标对准新生健康的玩家
					if player.Character and player.Character:FindFirstChild("Humanoid") then
						camera.CameraType = Enum.CameraType.Custom
						camera.CameraSubject = player.Character:FindFirstChild("Humanoid")
						camera.FieldOfView = 70
					end
					
					print("画面定格结束，世界实体已彻底卸载清空。")
				end)
			end)
		end

		-- 玩家重生回大厅后，延迟 1 秒弹出智能引导
		task.delay(1, function()
			if player:GetAttribute("NeedsGuide") and not GameController.IsCombatActive then
				local coins = player:GetAttribute("Coins") or 0
				local target = nil
				local text = ""
				
				-- 智能引导算法：有钱抽卡就指引去抽宠物，没钱就指引去商店点小天赋
				if coins >= Controllers.Config.PET_GACHA_COST then
					target = Workspace:FindFirstChild("paodao"):FindFirstChild("PetEgg")
					text = "去抽取宠物增强火力！"
				else
					local npc = Workspace:FindFirstChild("paodao"):FindFirstChild("ShopNPC")
					target = npc and (npc:FindFirstChild("HumanoidRootPart") or npc:FindFirstChildWhichIsA("BasePart"))
					text = "去商店升级天赋！"
				end
				
				if target then
					Controllers.VFX.CreateGuide(target, text)
				end
			end
		end)
	end
	
	-- 绑定角色加载与后续重生
	player.CharacterAdded:Connect(onCharacterAdded)
	if player.Character then 
		onCharacterAdded(player.Character) 
	end
end

-- 重置玩家属性至配置的基础安全数值
function GameController.ResetPlayerStats()
	local Config = Controllers.Config
	local startingStats = Controllers.Progression.CalculateStartingStats()

	-- 【补充兜底】：彻底清空上一局吃门积累的百分比加成
	player:SetAttribute("SPD_Bonus", 0)
	player:SetAttribute("RNG_Bonus", 0)
	player:SetAttribute("LateralSpeed_Bonus", 0)
	player:SetAttribute("EXP_Gain_Bonus", 0)
	player:SetAttribute("MaxHP_Bonus", 0)
	player:SetAttribute("MultiShot", Config.BASE_MULTISHOT or 1)
	player:SetAttribute("MaxHP", startingStats.MaxHP)
	player:SetAttribute("HP", startingStats.MaxHP)
	player:SetAttribute("ATK_Bonus", startingStats.ATK_Bonus)
	player:SetAttribute("ASPD_Bonus", startingStats.ASPD_Bonus)
	player:SetAttribute("Level", Config.BASE_LEVEL)
	player:SetAttribute("EXP", Config.BASE_EXP)
	player:SetAttribute("MagnetRadius_Bonus", 0)
	player:SetAttribute("RequiredEXP", Config.BASE_LEVEL * Config.EXP_PER_LEVEL)
	player:SetAttribute("IsLevelingUp", false)
	player:SetAttribute("EquippedWeapon", player:GetAttribute("EquippedWeapon") or "DefaultWeapon")
	-- 清理上一局累积的宠物 Buff
	player:SetAttribute("Pet_Count", 1)
	player:SetAttribute("Pet_ATK_Bonus", 0)
	player:SetAttribute("Pet_ASPD_Bonus", 0)
	player:SetAttribute("WindBlade_Range_Bonus", 0)
	-- 清理上一局累积的御剑 Buff
	player:SetAttribute("Sword_Unlocked", 0)
	player:SetAttribute("Sword_Count", 0)
	player:SetAttribute("Sword_ATK_Bonus", 0)
	player:SetAttribute("Sword_CD_Reduction", 0)
	-- 清理所有升级卡的局内选择等级，保证每局都从 Lv.0 开始显示
	for _, buff in ipairs(Config.LEVEL_UP_BUFF_POOL) do
		local buffId = buff.BuffId or buff.Attr or buff.Name
		if buffId then
			player:SetAttribute("BuffLevel_" .. tostring(buffId), 0)
		end
	end

	-- 不仅改属性，同时强制同步给当前存在的肉身
	if player.Character then
		local humanoid = player.Character:FindFirstChild("Humanoid")
		if humanoid then
			humanoid.MaxHealth = startingStats.MaxHP
			humanoid.Health = startingStats.MaxHP
		end
	end
end

-- 触发单局跑酷战斗开局
function GameController.EnterCombat()
	if GameController.IsCombatActive then return end
	-- 进入跑道自动清除引导
	player:SetAttribute("NeedsGuide", false)
	Controllers.VFX.ClearGuide()
	
	local character = player.Character
	local startPart = Workspace:WaitForChild("paodao"):WaitForChild("StartButton", 10)
	local Config = Controllers.Config
	
	if character and startPart then
		-- 1. 呼叫地图模块：重置原点并铺满初始视野跑道
		Controllers.Map.ResetTrack(startPart.CFrame)
		
		-- 2. 将玩家角色安全瞬移至跑道起点
		character:PivotTo(startPart.CFrame * CFrame.new(0, 3, -5))
		
		-- 3. 开局将单局局内属性刷新至健康的初始白模状态
		GameController.ResetPlayerStats()
		
		-- 4. 同步真实的最大生命值，而不是写死的 BASE_HP
		local humanoid = character:FindFirstChild("Humanoid")
		if humanoid then
			-- 读取刚刚在 ResetPlayerStats() 里算好的带有天赋加成的真实血量
			humanoid.MaxHealth = player:GetAttribute("MaxHP")
			humanoid.Health = player:GetAttribute("HP")
		end
	end
	
	-- 呼叫输入模块：重置玩家键盘水平输入方向，防止带大厅惯性斜着飘进跑道
	Controllers.Player.SetMoveDirection(0)
	
	-- 正式激活状态机核心开关
	GameController.IsCombatActive = true
	player:SetAttribute("InCombat", true) 
	
	print("进入跑道，单局游戏正式开始！整个模块化流水线协同驱动运转！")
end

-- 挂载大厅触发器的交互事件
function GameController.SetupStartButton()
	task.spawn(function()
		local startPart = Workspace:WaitForChild("paodao"):WaitForChild("StartButton", 10)
		if not startPart then 
			warn("GameController 警告: 未能在世界中找到名为 'StartButton' 的大厅出生 Part！")
			return 
		end
		
		local prompt = startPart:FindFirstChildOfClass("ProximityPrompt")
		if not prompt then
			prompt = Instance.new("ProximityPrompt")
			prompt.ObjectText = "跑道入口"
			prompt.ActionText = "开始挑战"
			prompt.HoldDuration = 0.2
			prompt.RequiresLineOfSight = false -- 防止视线判定 Bug
			prompt.Parent = startPart
		else
			prompt.RequiresLineOfSight = false -- 如果是 Studio 里建好的，也强行关掉
		end
		
		prompt.Triggered:Connect(function(triggeringPlayer)
			if triggeringPlayer == player and not GameController.IsCombatActive then
				GameController.EnterCombat()
			end
		end)
	end)
end

-- NPC 绑定逻辑
function GameController.SetupNPC()
	task.spawn(function()
		local npc = Workspace:WaitForChild("paodao"):WaitForChild("ShopNPC", 10)
		if npc then
			local prompt = npc:FindFirstChildOfClass("ProximityPrompt")
			if prompt then
				prompt.Triggered:Connect(function(triggeringPlayer)
					if triggeringPlayer == player and not GameController.IsCombatActive then
						-- 告诉 UI 系统：玩家打开了商店
						player:SetAttribute("IsShopOpen", true)
						-- 成功打开商店，使命完成，清除光束！
						player:SetAttribute("NeedsGuide", false)
						Controllers.VFX.ClearGuide()
					end
				end)
			end
		end
	end)
end
return GameController
