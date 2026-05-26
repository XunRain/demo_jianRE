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
			
			-- 监听角色死亡事件，执行核心清场
			humanoid.Died:Connect(function()
				GameController.IsCombatActive = false
				player:SetAttribute("InCombat", false)
				player:SetAttribute("IsLevelingUp", false)
				camera.CameraType = Enum.CameraType.Custom
				
				-- 玩家死亡瞬间，呼叫各大模块协作：清空世界跑道、怪物实体、散落掉落物以及飞行的子弹
				Controllers.Map.ClearTracks()
				Controllers.Encounter.ClearAll()
				Controllers.Combat.ClearBullets()
				print("玩家已阵亡，世界实体已彻底卸载清空。")
			end)
		end
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

	player:SetAttribute("MaxHP", startingStats.MaxHP)
	player:SetAttribute("HP", startingStats.MaxHP)
	player:SetAttribute("ATK", startingStats.ATK)
	player:SetAttribute("ASPD", startingStats.ASPD)
	player:SetAttribute("Level", Config.BASE_LEVEL)
	player:SetAttribute("EXP", Config.BASE_EXP)
	player:SetAttribute("MagnetRadius", Config.MAGNET_RADIUS)
	
	-- 使用配置表计算开局升第 2 级所需的初始经验
	player:SetAttribute("RequiredEXP", Config.BASE_LEVEL * Config.EXP_PER_LEVEL)
	player:SetAttribute("IsLevelingUp", false)
end

-- 触发单局跑酷战斗开局
function GameController.EnterCombat()
	if GameController.IsCombatActive then return end
	
	local character = player.Character
	local startPart = Workspace:FindFirstChild("StartButton")
	local Config = Controllers.Config
	
	if character and startPart then
		-- 1. 呼叫地图模块：重置原点并铺满初始视野跑道
		Controllers.Map.ResetTrack(startPart.CFrame)
		
		-- 2. 将玩家角色安全瞬移至跑道起点
		character:PivotTo(startPart.CFrame * CFrame.new(0, 3, -5))
		
		-- 3. 开局将单局局内属性刷新至健康的初始白模状态
		GameController.ResetPlayerStats()
		
		-- 4. 强制同步原生 Humanoid 模型的血量上限与当前血量
		local humanoid = character:FindFirstChild("Humanoid")
		if humanoid then
			humanoid.MaxHealth = Config.BASE_HP
			humanoid.Health = Config.BASE_HP
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
		local startPart = Workspace:WaitForChild("StartButton", 10)
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
			prompt.Parent = startPart
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
		local npc = Workspace:WaitForChild("ShopNPC", 10)
		if npc then
			local prompt = npc:FindFirstChildOfClass("ProximityPrompt")
			if prompt then
				prompt.Triggered:Connect(function(triggeringPlayer)
					if triggeringPlayer == player and not GameController.IsCombatActive then
						-- 告诉 UI 系统：玩家打开了商店
						player:SetAttribute("IsShopOpen", true)
					end
				end)
			end
		end
	end)
end
return GameController