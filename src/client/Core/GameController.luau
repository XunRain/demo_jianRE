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

local isStartingCombat = false -- 进入战斗的过渡锁，避免 Start 区域轮询和 Touched 同时重复触发
local lobbyLightingSnapshot = nil
local lightingTween = nil

-- 同步本地跑酷状态给服务端头顶进度 UI；服务端展示给所有玩家看。
local function reportRunStats(isInCombat)
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local reportEvent = remotes and remotes:FindFirstChild("ReportRunStats")
	if reportEvent then
		reportEvent:FireServer(isInCombat == true, player:GetAttribute("Level") or 1)
	end
end

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

-- 查找所有开始区域；用于兼容大厅里同时存在新版 StartZone 和旧版 StartButton 的情况。
local function findStartObjects()
	local results = {}
	local seen = {}

	for _, objectName in ipairs({ "StartZone", "StartButton" }) do
		for _, node in ipairs(Workspace:GetDescendants()) do
			if node.Name == objectName and not seen[node] then
				seen[node] = true
				table.insert(results, node)
			end
		end
	end

	return results
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

-- 获取大厅触发物的基准 CFrame；Model 使用整体 Pivot，Part 使用自身 CFrame。
local function getInteractCFrame(target)
	if not target then return nil end
	if target:IsA("BasePart") then
		return target.CFrame
	end
	if target:IsA("Model") then
		return target:GetPivot()
	end

	local part = getInteractBasePart(target)
	return part and part.CFrame or nil
end

-- 获取开始区域的检测盒；Model 使用整体包围盒，Part 使用自身大小。
local function getStartZoneBounds(startObject)
	if not startObject then return nil, nil end
	if startObject:IsA("BasePart") then
		return startObject.CFrame, startObject.Size
	end
	if startObject:IsA("Model") then
		return startObject:GetBoundingBox()
	end

	local part = getInteractBasePart(startObject)
	if part then
		return part.CFrame, part.Size
	end

	return nil, nil
end

-- 大厅弹窗打开时禁止自动开始；避免玩家操作背包/商店/抽卡时被 Start 区域轮询误触发。
local function isLobbyModalOpen()
	if player:GetAttribute("IsPetBagOpen") == true
		or player:GetAttribute("IsShopOpen") == true
		or player:GetAttribute("IsLevelingUp") == true
	then
		return true
	end

	local playerGui = player:FindFirstChild("PlayerGui")
	local mainUI = playerGui and playerGui:FindFirstChild("MainUI")
	if not mainUI then return false end

	for _, panelName in ipairs({ "PetBagPanel", "ShopPanel", "HatchScreen", "LevelUpPanel" }) do
		local panel = mainUI:FindFirstChild(panelName, true)
		if panel and panel:IsA("GuiObject") and panel.Visible then
			return true
		end
	end

	return false
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
		reportRunStats(false)
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
				reportRunStats(false)
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
					text = "Draw a pet to boost your firepower!"
				else
					local npc = findLobbyObject("ShopNPC")
					target = npc and (npc:FindFirstChild("HumanoidRootPart") or getInteractBasePart(npc))
					text = "Upgrade talents in the shop!"
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

-- 触发单局跑酷战斗开局；先传送玩家，再初始化跑道，减少踩 START 后的卡顿观感。
function GameController.EnterCombat(startObjectOverride)
	if GameController.IsCombatActive or isStartingCombat then return false end
	if isLobbyModalOpen() then return false end

	isStartingCombat = true
	local started = false
	local anchoredRoot = nil
	local anchoredWas = false

	local ok, err = xpcall(function()
		-- 关键对象缺失时直接退出，不切换 InCombat，避免玩家仍在大厅但状态已经进入战斗。
		local character = player.Character
		if not character then
			warn("[GameController] 进入战斗失败：未找到玩家角色。")
			return
		end

		local humanoid = character:FindFirstChild("Humanoid")
		local rootPart = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
		if not humanoid or humanoid.Health <= 0 or not rootPart then
			warn("[GameController] 进入战斗失败：角色 Humanoid 或 HumanoidRootPart 不可用。")
			return
		end

		local startObject = startObjectOverride or waitForStartObject(3)
		local startCFrame = getInteractCFrame(startObject)
		if not startCFrame then
			warn("[GameController] 进入战斗失败：未找到可用的 StartZone/StartButton。")
			return
		end

		-- 清掉大厅移动惯性，防止瞬移到跑道时继续横向滑动。
		Controllers.Player.SetMoveDirection(0)
		rootPart.AssemblyLinearVelocity = Vector3.zero
		rootPart.AssemblyAngularVelocity = Vector3.zero

		-- 先把玩家送到起跑点并短暂锚定，再铺设跑道；这样即使铺设较重，也不会看起来卡在大厅。
		local spawnCFrame = startCFrame * CFrame.new(0, 3, -5)
		anchoredRoot = rootPart
		anchoredWas = rootPart.Anchored
		rootPart.Anchored = true
		character:PivotTo(spawnCFrame)
		task.wait()

		-- 开局刷新单局属性，并同步到当前 Humanoid。
		GameController.ResetPlayerStats()
		humanoid.MaxHealth = player:GetAttribute("MaxHP")
		humanoid.Health = player:GetAttribute("HP")

		-- 重置跑道后再校准一次角色位置，避免模型生成或物理抖动影响起跑点。
		Controllers.Map.ResetTrack(startCFrame)
		character:PivotTo(spawnCFrame)
		rootPart.AssemblyLinearVelocity = Vector3.zero
		rootPart.AssemblyAngularVelocity = Vector3.zero
		rootPart.Anchored = anchoredWas
		anchoredRoot = nil

		player:SetAttribute("NeedsGuide", false)
		Controllers.VFX.ClearGuide()

		GameController.IsCombatActive = true
		player:SetAttribute("InCombat", true)
		reportRunStats(true)
		applyLightingMode(true)

		local remotes = ReplicatedStorage:WaitForChild("Remotes", 5)
		local runStartedEvent = remotes and remotes:WaitForChild("RunStarted", 5)
		if runStartedEvent then
			runStartedEvent:FireServer(rootPart.Position.Z)
		end

		started = true
		print("[GameController] 进入跑道，单局游戏正式开始。")
	end, debug.traceback)

	if not ok then
		warn("[GameController] 进入战斗流程异常：", err)
		if anchoredRoot then
			anchoredRoot.Anchored = anchoredWas
			anchoredRoot = nil
		end
		GameController.IsCombatActive = false
		player:SetAttribute("InCombat", false)
		reportRunStats(false)
		applyLightingMode(false)
	end

	isStartingCombat = false
	return started
end

-- 挂载大厅开始区域；玩家走进 StartZone/StartButton 后自动进入跑道。
function GameController.SetupStartButton()
	task.spawn(function()
		local lastStartAt = 0
		local knownStartObjects = {}

		-- 记录所有可能的开始区域，避免只绑定到 FindFirstChild 找到的第一个旧对象。
		local function rememberStartObject(startObject)
			if not startObject then return end
			for _, existing in ipairs(knownStartObjects) do
				if existing == startObject then
					return
				end
			end
			table.insert(knownStartObjects, startObject)
		end

		-- 禁用旧版开始交互提示；开始方式已经改为走进区域自动触发。
		local function disableStartPrompt(startObject)
			if not startObject then return end
			for _, node in ipairs(startObject:GetDescendants()) do
				if node:IsA("ProximityPrompt") then
					node.Enabled = false
				end
			end
			if startObject:IsA("ProximityPrompt") then
				startObject.Enabled = false
			end
		end

		-- 判断玩家根节点是否在开始区域盒体内；给 Y 轴留出较大容差，避免角色跳动漏判。
		local function isRootInsideStartZone(startObject, rootPart)
			if not startObject or not rootPart then return false end

			local zoneCFrame, zoneSize = getStartZoneBounds(startObject)
			if not zoneCFrame or not zoneSize then return false end

			local localPos = zoneCFrame:PointToObjectSpace(rootPart.Position)
			local halfSize = zoneSize * 0.5
			local xzPadding = 3
			local yPadding = 12
			return math.abs(localPos.X) <= (halfSize.X + xzPadding)
				and math.abs(localPos.Z) <= (halfSize.Z + xzPadding)
				and math.abs(localPos.Y) <= (halfSize.Y + yPadding)
		end

		-- 轮询兜底：即使 Start 部件 CanTouch 关闭，也能通过空间重叠识别玩家已经进入开始区。
		local function isCharacterOverlappingStartZone(startObject, character)
			if not startObject or not character then return false end

			local zoneCFrame, zoneSize = getStartZoneBounds(startObject)
			if not zoneCFrame or not zoneSize then return false end

			local overlapParams = OverlapParams.new()
			overlapParams.FilterType = Enum.RaycastFilterType.Include
			overlapParams.FilterDescendantsInstances = { character }

			local expandedSize = zoneSize + Vector3.new(6, 12, 6)
			local parts = Workspace:GetPartBoundsInBox(zoneCFrame, expandedSize, overlapParams)
			return #parts > 0
		end

		-- 尝试触发开始；带冷却和状态检查，避免 Touched/轮询同一瞬间重复触发。
		local function tryEnterFromStartZone(startObject, fromTouch)
			if GameController.IsCombatActive or isStartingCombat then return end
			if isLobbyModalOpen() then return end
			if os.clock() - lastStartAt < 1 then return end

			local character = player.Character
			local humanoid = character and character:FindFirstChild("Humanoid")
			local rootPart = character and (character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart)
			if not humanoid or humanoid.Health <= 0 or not rootPart then return end
			if not fromTouch
				and not isRootInsideStartZone(startObject, rootPart)
				and not isCharacterOverlappingStartZone(startObject, character)
			then
				return
			end

			if GameController.EnterCombat(startObject) then
				lastStartAt = os.clock()
			end
		end

		-- 绑定开始区域触碰事件；同时配合轮询兜底，兼容 CanTouch/Streaming 差异。
		local function bindStartZone(startObject)
			if not startObject then return end
			disableStartPrompt(startObject)

			startObject:SetAttribute("ClientStartZoneBound", true)

			-- 模型型开始区会有多个子 Part；每个 Part 都绑定触碰，但统一用整体区域做最终判定。
			local touchParts = {}
			if startObject:IsA("BasePart") then
				table.insert(touchParts, startObject)
			else
				for _, node in ipairs(startObject:GetDescendants()) do
					if node:IsA("BasePart") then
						table.insert(touchParts, node)
					end
				end
			end

			for _, part in ipairs(touchParts) do
				if part:GetAttribute("ClientStartZoneTouchBound") then
					continue
				end
				part:SetAttribute("ClientStartZoneTouchBound", true)
				part.Touched:Connect(function(hit)
					local character = player.Character
					if character and hit and hit:IsDescendantOf(character) then
						tryEnterFromStartZone(startObject, true)
					end
				end)
			end
		end

		Workspace.DescendantAdded:Connect(function(descendant)
			if descendant.Name == "StartZone" or descendant.Name == "StartButton" then
				rememberStartObject(descendant)
				task.defer(function()
					bindStartZone(descendant)
				end)
			end
		end)

		for _, startObject in ipairs(findStartObjects()) do
			rememberStartObject(startObject)
		end

		while true do
			for i = #knownStartObjects, 1, -1 do
				local startObject = knownStartObjects[i]
				if not startObject or not startObject.Parent then
					table.remove(knownStartObjects, i)
				else
					bindStartZone(startObject)
					tryEnterFromStartZone(startObject)
					if GameController.IsCombatActive or isStartingCombat then
						break
					end
				end
			end
			task.wait(0.2)
		end
	end)
end

-- NPC 绑定逻辑
function GameController.SetupNPC()
	task.spawn(function()
		-- 关闭旧商人身上遗留的 Prompt，避免玩家看到旧模型仍然可以交互。
		local function disableOldShopPrompts()
			for _, node in ipairs(Workspace:GetDescendants()) do
				if node.Name == "ShopNPC_OLD" then
					for _, prompt in ipairs(node:GetDescendants()) do
						if prompt:IsA("ProximityPrompt") then
							prompt.Enabled = false
						end
					end
				end
			end
		end

		-- 绑定新的 ShopNPC；新商人是 Model 时，Prompt 会挂到 HumanoidRootPart 或第一个 BasePart 上。
		local function bindShopNPC()
			disableOldShopPrompts()

			local npc = findLobbyObject("ShopNPC")
			if not npc then return end

			local promptParent = npc:FindFirstChild("HumanoidRootPart") or getInteractBasePart(npc)
			if not promptParent then return end

			local prompt = promptParent:FindFirstChildOfClass("ProximityPrompt")
			if not prompt then
				prompt = Instance.new("ProximityPrompt")
				prompt.Name = "ShopPrompt"
				prompt.Parent = promptParent
			end

			prompt.ActionText = "Open Shop"
			prompt.ObjectText = "Merchant"
			prompt.HoldDuration = 0.2
			prompt.RequiresLineOfSight = false
			prompt.MaxActivationDistance = 12
			prompt.Enabled = true

			if not prompt:GetAttribute("ClientShopPromptBound") then
				prompt:SetAttribute("ClientShopPromptBound", true)
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

		Workspace.DescendantAdded:Connect(function(descendant)
			if descendant.Name == "ShopNPC" or descendant.Name == "ShopNPC_OLD" then
				task.defer(bindShopNPC)
			end
		end)

		while true do
			bindShopNPC()
			task.wait(2)
		end
	end)
end
return GameController
