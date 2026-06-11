-- src/client/Core/GameController.luau
-- 核心流程控制器：管理游戏整体生命周期（大厅状态、单局进入战斗、死亡重置结算、状态安全复原）
local GameController = {}

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera 

local Controllers -- 全局模块依赖依赖指针
GameController.IsCombatActive = false -- 核心全局开关：当前是否在跑道上处于战斗状态

local lobbyLightingSnapshot = nil
local lightingTween = nil

-- 依赖注入：在系统启动时建立与其他模块的调用关系
function GameController.Init(deps)
	Controllers = deps
end

-- 记录 Studio 中配置好的大厅光照；回到大厅时恢复这份快照。
local function captureLobbyLighting()
	if lobbyLightingSnapshot then return end

	lobbyLightingSnapshot = {
		ClockTime = Lighting.ClockTime,
		GeographicLatitude = Lighting.GeographicLatitude,
		Brightness = Lighting.Brightness,
	}
end

-- 平滑切换 Lighting 属性；只改配置里声明的字段，避免覆盖美术的其他后处理。
local function tweenLightingTo(targetProps, transitionTime)
	if lightingTween then
		lightingTween:Cancel()
		lightingTween = nil
	end

	local tweenInfo = TweenInfo.new(
		transitionTime or 0.75,
		Enum.EasingStyle.Sine,
		Enum.EasingDirection.InOut
	)
	lightingTween = TweenService:Create(Lighting, tweenInfo, targetProps)
	lightingTween:Play()
end

-- 根据当前玩法状态切换客户端光照：大厅用默认光照，战斗用跑道专用阴影方向。
local function applyLightingMode(inCombat)
	if not Controllers or not Controllers.Config then return end

	local combatLighting = Controllers.Config.COMBAT_LIGHTING
	if not combatLighting or combatLighting.Enabled == false then return end

	captureLobbyLighting()

	local targetProps
	if inCombat then
		targetProps = {}
		for _, propName in ipairs({"ClockTime", "GeographicLatitude", "Brightness"}) do
			local value = combatLighting[propName]
			if value ~= nil then
				targetProps[propName] = value
			end
		end
	else
		targetProps = lobbyLightingSnapshot
	end

	if not targetProps or next(targetProps) == nil then return end
	tweenLightingTo(targetProps, combatLighting.TransitionTime)
end

-- 在 Workspace 中查找大厅物件；兼容物件直接放在 Workspace 或放在 paodao/其他 Model 下面。
local function findLobbyObject(objectName)
	return Workspace:FindFirstChild(objectName) or Workspace:FindFirstChild(objectName, true)
end

-- 等待大厅物件加载完成；用于处理 Streaming 或角色重生后物件还没到客户端的情况。
local function waitForLobbyObject(objectName, timeout)
	local object = findLobbyObject(objectName)
	if object then return object end

	local deadline = os.clock() + (timeout or 10)
	while os.clock() < deadline do
		object = findLobbyObject(objectName)
		if object then return object end
		task.wait(0.1)
	end

	return nil
end

-- 查找开始区域；新版本优先使用 StartZone，兼容旧大厅里的 StartButton。
local function findStartObject()
	return findLobbyObject("StartZone") or findLobbyObject("StartButton")
end

-- 等待开始区域加载；Streaming 开启时客户端可能稍晚才能看到大厅对象。
local function waitForStartObject(timeout)
	local object = findStartObject()
	if object then return object end

	local deadline = os.clock() + (timeout or 10)
	while os.clock() < deadline do
		object = findStartObject()
		if object then return object end
		task.wait(0.1)
	end

	return nil
end

-- 获取可挂 ProximityPrompt/引导光束的部件；Studio 里目标做成 Part 或 Model 都可以兼容。
local function getInteractBasePart(target)
	if not target then return nil end
	if target:IsA("BasePart") then
		return target
	end
	if target:IsA("Model") and target.PrimaryPart then
		return target.PrimaryPart
	end
	return target:FindFirstChildWhichIsA("BasePart", true)
end

-- 模块生命周期启动入口：绑定事件及全局生命周期监听
function GameController.Start()
	-- 初始化挂载大厅交互触发器
	GameController.SetupStartButton()
	GameController.SetupNPC()
	captureLobbyLighting()
	applyLightingMode(false)
	player:GetAttributeChangedSignal("InCombat"):Connect(function()
		applyLightingMode(player:GetAttribute("InCombat") == true)
	end)
	
	-- 统一的角色重生/复活处理核心函数（彻底收拢生命周期，防止属性回厅变负数）
	local function onCharacterAdded(newCharacter)
		GameController.IsCombatActive = false
		player:SetAttribute("InCombat", false)
		applyLightingMode(false)
		
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
				applyLightingMode(false)

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
					target = getInteractBasePart(findLobbyObject("PetEgg"))
					text = "去抽取宠物增强火力！"
				else
					local npc = findLobbyObject("ShopNPC")
					target = npc and (npc:FindFirstChild("HumanoidRootPart") or getInteractBasePart(npc))
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
	player:SetAttribute("RequiredEXP", Config.GetRequiredExp(Config.BASE_LEVEL))
	player:SetAttribute("IsLevelingUp", false)
	player:SetAttribute("LevelUpRewardMode", "Normal")
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
	local startPart = getInteractBasePart(waitForStartObject(10))
	
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

		-- 通知服务端开始记录本局跑酷距离；排行榜只需要起点 Z，后续由服务端按角色位置更新。
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 5)
		local runStartedEvent = remotes and remotes:WaitForChild("RunStarted", 5)
		local rootPart = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
		if runStartedEvent and rootPart then
			runStartedEvent:FireServer(rootPart.Position.Z)
		end
	end
	
	-- 呼叫输入模块：重置玩家键盘水平输入方向，防止带大厅惯性斜着飘进跑道
	Controllers.Player.SetMoveDirection(0)
	
	-- 正式激活状态机核心开关
	GameController.IsCombatActive = true
	player:SetAttribute("InCombat", true) 
	applyLightingMode(true)
	
	print("进入跑道，单局游戏正式开始！整个模块化流水线协同驱动运转！")
end

-- 挂载大厅开始区域；玩家走进 StartZone/StartButton 后自动进入跑道。
function GameController.SetupStartButton()
	task.spawn(function()
		local lastStartAt = 0

		-- 禁用旧版开始交互提示；开始方式已经改为走进区域自动触发。
		local function disableStartPrompt(startPart)
			if not startPart or not startPart:IsA("BasePart") then return end
			local prompt = startPart:FindFirstChildOfClass("ProximityPrompt")
			if prompt then
				prompt.Enabled = false
			end
		end

		-- 判断玩家根节点是否在开始区域盒体内；给 Y 轴留出较大容差，避免角色跳动漏判。
		local function isRootInsideStartZone(startPart, rootPart)
			if not startPart or not rootPart then return false end

			local localPos = startPart.CFrame:PointToObjectSpace(rootPart.Position)
			local halfSize = startPart.Size * 0.5
			local yPadding = 6
			return math.abs(localPos.X) <= halfSize.X
				and math.abs(localPos.Z) <= halfSize.Z
				and math.abs(localPos.Y) <= (halfSize.Y + yPadding)
		end

		-- 尝试触发开始；带冷却和状态检查，避免 Touched/轮询同一瞬间重复触发。
		local function tryEnterFromStartZone(startPart)
			if GameController.IsCombatActive then return end
			if os.clock() - lastStartAt < 1 then return end

			local character = player.Character
			local humanoid = character and character:FindFirstChild("Humanoid")
			local rootPart = character and (character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart)
			if not humanoid or humanoid.Health <= 0 or not rootPart then return end
			if not isRootInsideStartZone(startPart, rootPart) then return end

			lastStartAt = os.clock()
			GameController.EnterCombat()
		end

		-- 绑定开始区域触碰事件；同时配合轮询兜底，兼容 CanTouch/Streaming 差异。
		local function bindStartZone(startPart)
			if not startPart or not startPart:IsA("BasePart") then return end
			disableStartPrompt(startPart)

			if startPart:GetAttribute("ClientStartZoneBound") then return end
			startPart:SetAttribute("ClientStartZoneBound", true)
			startPart.Touched:Connect(function(hit)
				local character = player.Character
				if character and hit and hit:IsDescendantOf(character) then
					tryEnterFromStartZone(startPart)
				end
			end)
		end

		Workspace.DescendantAdded:Connect(function(descendant)
			if descendant.Name == "StartZone" or descendant.Name == "StartButton" then
				task.defer(function()
					bindStartZone(getInteractBasePart(descendant))
				end)
			end
		end)

		while true do
			local startPart = getInteractBasePart(findStartObject())
			if startPart then
				bindStartZone(startPart)
				tryEnterFromStartZone(startPart)
			end
			task.wait(0.2)
		end
	end)
end

-- NPC 绑定逻辑
function GameController.SetupNPC()
	task.spawn(function()
		local npc = waitForLobbyObject("ShopNPC", 10)
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
