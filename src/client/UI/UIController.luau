-- src/client/UI/UIController.luau
-- 屏幕 2D UI 与 角色常驻 3D 头顶 UI 控制器
local UIController = {}

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local player = Players.LocalPlayer
local HttpService = game:GetService("HttpService")

local Controllers -- 全局依赖指针

-- 3D 属性 UI 常驻玩家头顶上方 3.5 格（所有人可见）
local HEAD_OFFSET = Vector3.new(0, 3.5, 0)   

function UIController.Init(deps)
	Controllers = deps
end

function UIController.Start()
	-- 强制关闭 Roblox 自带的右上角默认血条
	task.spawn(function()
		local success = false
		repeat
			success = pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
			end)
			task.wait(0.1)
		until success
		print("原生血条已成功隐藏！")
	end)

	-- 动态获取并更新所有 UI 的核心函数
	local function updateUI()
		local playerGui = player:FindFirstChild("PlayerGui")
		if not playerGui then return end
		
		local mainUI = playerGui:FindFirstChild("MainUI")
		local statsUI = playerGui:FindFirstChild("CharacterStatsUI") 

		-- 获取当前最新数值
		local coins = player:GetAttribute("Coins") or 0
		local hp = player:GetAttribute("HP") or 0
      	local maxHp = player:GetAttribute("MaxHP") or Controllers.Config.BASE_HP
		local atkBonus = player:GetAttribute("ATK_Bonus") or 0
		-- 根据公式逆推当前的实际攻击面板展示给玩家看
		local displayAtk = math.floor(Controllers.Config.BASE_ATK * (1 + (atkBonus / 100)))
		local lvl = player:GetAttribute("Level") or 1
		local exp = player:GetAttribute("EXP") or 0
		local requiredExp = player:GetAttribute("RequiredEXP") or (lvl * Controllers.Config.EXP_PER_LEVEL) 
		local inCombat = player:GetAttribute("InCombat") == true
      	local currentStage = player:GetAttribute("CurrentStage") or 1

		-- 1. 刷新屏幕 UI 控制
		if mainUI then
			-- 金币常驻常显
			local coinContainer = mainUI:FindFirstChild("CoinContainer")
			if coinContainer then
				local coinText = coinContainer:FindFirstChild("CoinText")
				if coinText and coinText:IsA("TextLabel") then
					coinText.Text = tostring(coins) -- 只显示纯数字！
				end
			end
			-- 退出按钮
			local exitButton = mainUI:FindFirstChild("ExitButton")
			if exitButton and exitButton:IsA("GuiButton") then
				exitButton.Visible = inCombat and not player:GetAttribute("IsLevelingUp")
			end

         -- 大厅专属 UI 的战斗隔离控制
			-- 1. 进战斗后隐藏“打开宠物背包”按钮
			local openBagBtn = mainUI:FindFirstChild("BtnOpenPetBag")
			if openBagBtn then
				openBagBtn.Visible = not inCombat -- 只有不在战斗中（大厅状态）才显示
			end
			
			-- 2. 如果玩家开着背包直接冲进了跑道门，强制关掉面板
			local petBagPanel = mainUI:FindFirstChild("PetBagPanel")
			if petBagPanel and inCombat then
				petBagPanel.Visible = false
			end

         -- 关卡文本 UI 动态控制与自动兜底
			local stageLabel = mainUI:FindFirstChild("StageLabel")
			
			-- 应急机制：如果策划/美术还没在 Studio 里做 StageLabel 控件，且正处于战斗状态
			if not stageLabel and inCombat then
				stageLabel = Instance.new("TextLabel")
				stageLabel.Name = "StageLabel"
				stageLabel.Size = UDim2.new(0, 300, 0, 60)
				stageLabel.Position = UDim2.new(0.5, -150, 0, 30) -- 屏幕顶端正中间
				stageLabel.BackgroundTransparency = 1
				stageLabel.Font = Enum.Font.FredokaOne
				stageLabel.TextSize = 36
				stageLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
				
				-- 加上一层厚重的黑边描边，更有街机感
				local stroke = Instance.new("UIStroke")
				stroke.Thickness = 3
				stroke.Color = Color3.fromRGB(0, 0, 0)
				stroke.Parent = stageLabel
				
				stageLabel.Parent = mainUI
			end
			
			-- 状态渲染驱动
			if stageLabel then
				-- 只有进入战斗（跑酷状态下）且不在升级选卡面板阻挡时才显示关卡数；回到大厅自动隐藏
				stageLabel.Visible = inCombat and not player:GetAttribute("IsLevelingUp")
				stageLabel.Text = "第 " .. tostring(currentStage) .. " 关"
			end

			-- Minecraft 风格底部血条/经验条群组控制
			local combatHub = mainUI:FindFirstChild("CombatHub")
			if combatHub and combatHub:IsA("Frame") then
				-- 只有进入战斗且不在升级选择时，显示底部状态条
				combatHub.Visible = inCombat and not player:GetAttribute("IsLevelingUp")
				
				if combatHub.Visible then
					-- 血条比例并更新 Size
					local healthBar = combatHub:FindFirstChild("HealthBar", true)
					if healthBar then
						local hpPercent = math.clamp(hp / maxHp, 0, 1)
						healthBar.Size = UDim2.new(hpPercent, 0, 1, 0)
					end
					
					local healthText = combatHub:FindFirstChild("HealthText", true)
					if healthText and healthText:IsA("TextLabel") then
						healthText.Text = math.floor(hp) .. " / " .. math.floor(maxHp)
					end

					-- 经验条比例并更新 Size
					local expBar = combatHub:FindFirstChild("ExpBar", true)
					if expBar then
						local expPercent = math.clamp(exp / requiredExp, 0, 1)
						expBar.Size = UDim2.new(expPercent, 0, 1, 0)
					end
					
					local expText = combatHub:FindFirstChild("ExpText", true)
					if expText and expText:IsA("TextLabel") then
						expText.Text = math.floor(exp) .. " / " .. math.floor(requiredExp)
					end
				end
			end
		end

		-- 2. 处理 3D 头顶数值 UI（常驻玩家头顶的等级与攻击力）
		if statsUI and statsUI:IsA("BillboardGui") then
			local character = player.Character
			if character then
				local rootPart = character:FindFirstChild("HumanoidRootPart")
				if rootPart then
					-- 将 3D UI 牢牢挂载在身体部件上，始终跟随
					statsUI.Adornee = rootPart 
				end
			end

			statsUI.StudsOffset = HEAD_OFFSET  

			-- 刷新 3D UI 内部的文本
			local statsLabel = statsUI:FindFirstChild("StatsLabel")
			if statsLabel and statsLabel:IsA("TextLabel") then
				statsLabel.Text = string.format("Lv.%d | ATK: %d", lvl, displayAtk)
			end
		end

      
	end

	-- 升级卡片 UI 控制模块
	local function setupLevelUpUI()
		local playerGui = player:WaitForChild("PlayerGui")
		local mainUI = playerGui:WaitForChild("MainUI")
		local levelUpPanel = mainUI:WaitForChild("LevelUpPanel", 5)
		
		if not levelUpPanel then return end

		local cards = {
			levelUpPanel:FindFirstChild("Card1"),
			levelUpPanel:FindFirstChild("Card2"),
			levelUpPanel:FindFirstChild("Card3")
		}

		-- 事件绑定剥离，全局只绑定一次
		for _, card in ipairs(cards) do
			if card and card:IsA("GuiButton") then
				card.Activated:Connect(function()
					if not player:GetAttribute("IsLevelingUp") then return end
					
					local attr = card:GetAttribute("BuffAttr")
					local amount = card:GetAttribute("BuffAmount")
					if not attr then return end

					-- 【核心逻辑】：专门处理最大生命值百分比提升的辅助函数
					local function applyMaxHpBonus(bonusAmount)
						local currentBonus = player:GetAttribute("MaxHP_Bonus") or 0
						player:SetAttribute("MaxHP_Bonus", currentBonus + bonusAmount)
						
						local startingStats = Controllers.Progression.CalculateStartingStats()
						local baseMaxHp = startingStats.MaxHP
						local newMaxHp = math.floor(baseMaxHp * (1 + ((currentBonus + bonusAmount) / 100)))
						
						local oldMaxHp = player:GetAttribute("MaxHP") or baseMaxHp
						player:SetAttribute("MaxHP", newMaxHp)
						
						local diff = newMaxHp - oldMaxHp
						if diff > 0 then
							player:SetAttribute("HP", (player:GetAttribute("HP") or oldMaxHp) + diff)
						elseif diff < 0 then
							local currentHp = player:GetAttribute("HP") or oldMaxHp
							if currentHp > newMaxHp then player:SetAttribute("HP", newMaxHp) end
						end
					end

					-- 应用玩家选择的增益
					if attr == "ALL" then
						player:SetAttribute("ATK_Bonus", (player:GetAttribute("ATK_Bonus") or 0) + amount)
						player:SetAttribute("ASPD_Bonus", (player:GetAttribute("ASPD_Bonus") or 0) + amount)
						applyMaxHpBonus(amount) -- 全能增益：生命上限 + amount%
					elseif attr == "MaxHP_Bonus" then
						applyMaxHpBonus(amount)
					else
						-- 其他属性 (ATK_Bonus, SPD_Bonus, MultiShot 等直接数值相加)
						player:SetAttribute(attr, (player:GetAttribute(attr) or 0) + amount)
					end
					
					-- 同步实际血量给原生的人偶模型
					local humanoid = player.Character and player.Character:FindFirstChild("Humanoid")
					if humanoid then
						humanoid.MaxHealth = player:GetAttribute("MaxHP")
						humanoid.Health = player:GetAttribute("HP")
					end

					-- 关闭面板，解除暂停
					levelUpPanel.Visible = false
					player:SetAttribute("IsLevelingUp", false)
				end)
			end
		end

		-- 监听升级状态，负责动画与发牌
		player:GetAttributeChangedSignal("IsLevelingUp"):Connect(function()
			local isLeveling = player:GetAttribute("IsLevelingUp")
			
			if isLeveling then
				levelUpPanel.Visible = true
				
				-- =======================================================
				-- 【核心修改】：引入权重与弹道上限的卡池过滤机制
				-- =======================================================
				local originalPool = Controllers.Config.LEVEL_UP_BUFF_POOL
				local validPool = {}
				local totalWeight = 0
				
				-- 获取玩家当前的弹道数量和当前武器的上限
				local currentMultiShot = player:GetAttribute("MultiShot") or 1
				local equippedWeapon = player:GetAttribute("EquippedWeapon") or "DefaultWeapon"
				local weaponConfig = Controllers.Config.WEAPONS[equippedWeapon] or Controllers.Config.WEAPONS["DefaultWeapon"]
				local maxMultiShot = weaponConfig.MaxMultiShot or 3
				
				-- 遍历原始池子，生成合法的抽卡池
				for _, buff in ipairs(originalPool) do
					-- 如果弹道数已经达到了当前武器的上限，这辈子都不会再把它放入抽卡池！
					if buff.Attr == "MultiShot" and currentMultiShot >= maxMultiShot then
						continue
					end
					
					table.insert(validPool, buff)
					totalWeight = totalWeight + (buff.Weight or 100) -- 没配权重兜底为 100
				end

				for i, card in ipairs(cards) do
					if card and card:IsA("GuiButton") then
						-- 按照权重随机抽取卡片
						local rand = math.random(1, totalWeight)
						local currentWeight = 0
						local buff = validPool[1] 
						
						for _, b in ipairs(validPool) do
							currentWeight = currentWeight + (b.Weight or 100)
							if rand <= currentWeight then
								buff = b
								break
							end
						end
						
						card:SetAttribute("BuffAttr", buff.Attr)
						card:SetAttribute("BuffAmount", buff.Amount)
						
						-- 智能添加 % 符号
						if buff.Attr == "ALL" then
							card.Text = "全能提升\n各项 +" .. tostring(buff.Amount) .. "%"
						else
							local suffix = string.find(buff.Attr, "Bonus") and "%" or ""
							card.Text = buff.Name .. "\n+" .. tostring(buff.Amount) .. suffix
						end
						
						card.BackgroundColor3 = buff.Color
						
						card.Rotation = -180
						card.Size = UDim2.new(0, 0, 0, 0) 
						
						local tweenInfo = TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
						local tween = TweenService:Create(card, tweenInfo, {
							Rotation = 0,
							Size = UDim2.new(0.25, 0, 0.5, 0) 
						})
						
						task.delay((i - 1) * 0.15, function()
							tween:Play()
						end)
					end
				end
			else
				levelUpPanel.Visible = false
			end
		end)
	end

   -- 商店 UI 初始化函数
	local function setupShopUI()
		local playerGui = player:WaitForChild("PlayerGui")
		local mainUI = playerGui:WaitForChild("MainUI")
		local shopPanel = mainUI:WaitForChild("ShopPanel", 5)
		if not shopPanel then return end

		local Config = Controllers.Config -- 拿到全局配置
		
		-- 等待美术做好的滑动列表和模板
		local shopList = shopPanel:WaitForChild("ShopList")
		local itemTemplate = shopPanel:WaitForChild("ShopItemTemplate")

		-- 刷新商店文本显示 (支持滑动列表的智能增量更新)
		local function refreshShopUI()
			for talentId, talentData in pairs(Config.TALENTS) do
				local btnName = "Btn_" .. talentId
				local btn = shopList:FindFirstChild(btnName)
				
				local currentLevel = player:GetAttribute(talentId) or 0
				local cost = Config.GetTalentCost(talentId, currentLevel)

				-- 如果这个商品的按钮还不存在，就克隆模板并绑定购买事件
				if not btn then
					btn = itemTemplate:Clone()
					btn.Name = btnName
					btn.Visible = true 
					btn.Parent = shopList
					
					-- 绑定购买事件
					btn.Activated:Connect(function()
						local remotes = game:GetService("ReplicatedStorage"):WaitForChild("Remotes")
						remotes:WaitForChild("BuyTalent"):FireServer(talentId)
					end)
				end
				
				-- 刷新价格与等级文本 (兼容模板内部有 TextLabel 或直接使用 Button 的 Text)
				local textLabel = btn:FindFirstChild("TextLabel")
				local displayText = talentData.Name .. " Lv." .. currentLevel .. "\n金币: " .. cost
				
				if textLabel and textLabel:IsA("TextLabel") then
					textLabel.Text = displayText
				else
					btn.Text = displayText
				end
			end
		end

		-- 当玩家金币或者局外天赋等级变动时，实时计算并刷新商店界面价格
		player.AttributeChanged:Connect(function(attr)
			if attr == "Coins" or string.match(attr, "Talent_") then
				if shopPanel.Visible then refreshShopUI() end
			end
		end)

		-- 监听商店开关状态
		player:GetAttributeChangedSignal("IsShopOpen"):Connect(function()
			shopPanel.Visible = player:GetAttribute("IsShopOpen") == true
			if shopPanel.Visible then refreshShopUI() end
		end)

		-- 绑定关闭面板按钮
		local closeBtn = shopPanel:FindFirstChild("CloseButton")
		if closeBtn then
			closeBtn.Activated:Connect(function()
				player:SetAttribute("IsShopOpen", false)
			end)
		end
	end


	-- =======================================================
	-- 【双区重构版】：宠物背包 UI (对接 Studio 栅格布局)
	-- =======================================================
	local function setupPetBagUI()
		local playerGui = player:WaitForChild("PlayerGui")
		local mainUI = playerGui:WaitForChild("MainUI")
		
		local openBagBtn = mainUI:WaitForChild("BtnOpenPetBag", 5)
		local bagPanel = mainUI:WaitForChild("PetBagPanel", 5)
		if not openBagBtn or not bagPanel then return end
		
		local closeBtn = bagPanel:WaitForChild("BtnClose")
		local petList = bagPanel:WaitForChild("PetList")
		
		-- 获取刚才新建的两个独立栅格容器
		local equippedContainer = petList:WaitForChild("EquippedContainer")
		local standbyContainer = petList:WaitForChild("StandbyContainer")
		
		-- 获取放在 Panel 根目录的两个模板
		local petTemplate = bagPanel:WaitForChild("PetItemTemplate") 
		local emptySlotTemplate = bagPanel:WaitForChild("EmptySlotTemplate")

		local MAX_EQUIP_SLOTS = 1 -- 目前只开放1个槽位，以后如果要拓展改这里就行

		local function refreshBag()
			-- 安全清理两个容器内的旧 UI (千万别把 UIGridLayout 删了)
			for _, child in ipairs(equippedContainer:GetChildren()) do
				if not child:IsA("UIGridLayout") then child:Destroy() end
			end
			for _, child in ipairs(standbyContainer:GetChildren()) do
				if not child:IsA("UIGridLayout") then child:Destroy() end
			end
			
			local owned = HttpService:JSONDecode(player:GetAttribute("OwnedPets_JSON") or "[]")
			local equipped = player:GetAttribute("EquippedPet") or ""

			-- 统计同种宠物
			local petCounts = {}
			for _, petId in ipairs(owned) do
				petCounts[petId] = (petCounts[petId] or 0) + 1
			end

			-- ==========================================
			-- 1. 渲染【出战区】
			-- ==========================================
			local equippedCount = 0
			if equipped ~= "" and petCounts[equipped] and petCounts[equipped] > 0 then
				equippedCount = 1
				petCounts[equipped] = petCounts[equipped] - 1 -- 从待机区扣除1个
				
				local petConfig = Controllers.Config.PETS[equipped]
				local btn = petTemplate:Clone()
				btn.Visible = true 
				btn.Parent = equippedContainer
				
				btn.Text = petConfig.Name .. "\n(出战中)"
				btn.BackgroundColor3 = Color3.fromRGB(100, 255, 100)
				
				-- 点击出战区的宠物：向服务器发送空字符串进行【卸下】
				btn.Activated:Connect(function()
					local remotes = game:GetService("ReplicatedStorage"):WaitForChild("Remotes")
					remotes:WaitForChild("EquipPet"):FireServer("")
				end)
			end

			-- 补齐空槽位 (让 UI 显示出明显的虚线空槽感)
			for i = equippedCount + 1, MAX_EQUIP_SLOTS do
				local emptySlot = emptySlotTemplate:Clone()
				emptySlot.Visible = true
				emptySlot.Parent = equippedContainer
			end

			-- ==========================================
			-- 2. 渲染【待机区】
			-- ==========================================
			for petId, count in pairs(petCounts) do
				if count > 0 then -- 如果还有剩余宠物在待机
					local petConfig = Controllers.Config.PETS[petId]
					if petConfig then
						local btn = petTemplate:Clone()
						btn.Visible = true 
						btn.Parent = standbyContainer
						
						local countText = (count > 1) and (" x" .. count) or "" 
						btn.Text = petConfig.Name .. countText .. "\nATK:" .. petConfig.ATK
						btn.BackgroundColor3 = petTemplate.BackgroundColor3
						
						-- 点击待机区的宠物：向服务器发送 petId 进行【替换出战】
						btn.Activated:Connect(function()
							local remotes = game:GetService("ReplicatedStorage"):WaitForChild("Remotes")
							remotes:WaitForChild("EquipPet"):FireServer(petId)
						end)
					end
				end
			end
		end

		openBagBtn.Activated:Connect(function()
			bagPanel.Visible = not bagPanel.Visible
			if bagPanel.Visible then refreshBag() end
		end)
		closeBtn.Activated:Connect(function() bagPanel.Visible = false end)
		
		-- 装备发生变动、或者刚好抽到新宠物时，实时刷新面板
		player:GetAttributeChangedSignal("EquippedPet"):Connect(function()
			if bagPanel.Visible then refreshBag() end
		end)
		player:GetAttributeChangedSignal("OwnedPets_JSON"):Connect(function()
			if bagPanel.Visible then refreshBag() end
		end)
	end


	-- =======================================================
	-- 【重构版】：3D ViewportFrame 宠物蛋破壳动画 (对接 Studio)
	-- =======================================================
	local function setupPetHatching()
		local eggPart = Workspace:WaitForChild("PetEgg", 10)
		if not eggPart then return end
		local prompt = eggPart:FindFirstChildOfClass("ProximityPrompt") or Instance.new("ProximityPrompt", eggPart)
      prompt.ActionText = "花费 " .. tostring(Controllers.Config.PET_GACHA_COST) .. " 抽宠"
		
		local playerGui = player:WaitForChild("PlayerGui")
		local mainUI = playerGui:WaitForChild("MainUI")
		
		-- 等待美术做好的全屏抽卡界面
		local hatchScreen = mainUI:WaitForChild("HatchScreen", 5)
		if not hatchScreen then return end
		
		local viewport = hatchScreen:WaitForChild("PetViewport")
		local clickArea = hatchScreen:WaitForChild("BtnClickArea")
		local tipText = hatchScreen:WaitForChild("TipText")
		
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		local petModels = ReplicatedStorage:WaitForChild("Pets") 
		
		-- ViewportFrame 的摄像机必须用代码动态创建并绑定，不然容易出 Bug
		local camera = Instance.new("Camera")
		camera.FieldOfView = 60
		viewport.CurrentCamera = camera
		
		local clickCount = 0
		local isHatching = false
		local current3DModel = nil
		local spinConnection = nil 
		
		local function clearViewport()
			if current3DModel then current3DModel:Destroy() end
			if spinConnection then spinConnection:Disconnect() end
		end
		
		prompt.Triggered:Connect(function(triggeringPlayer)
			if triggeringPlayer ~= player or isHatching then return end

         -- 玩家响应了引导点击抽卡，清除光束！
			player:SetAttribute("NeedsGuide", false)
			Controllers.VFX.ClearGuide()

			local coins = player:GetAttribute("Coins") or 0
			if coins < Controllers.Config.PET_GACHA_COST then
				print("金币不足！"); return
			end
			
			isHatching = true
			clearViewport()
			
			local remotes = ReplicatedStorage:WaitForChild("Remotes")
			local resultPetId = remotes:WaitForChild("RollPet"):InvokeServer()
			
			-- 挂载 3D 蛋模型
			local eggTemplate = petModels:FindFirstChild("Egg")
			if eggTemplate then
				current3DModel = eggTemplate:Clone()
				current3DModel:SetPrimaryPartCFrame(CFrame.new(0, 0, 0))
				current3DModel.Parent = viewport
				camera.CFrame = CFrame.lookAt(Vector3.new(0, 2, -6), Vector3.new(0, 0, 0))
			end
			
			hatchScreen.Visible = true
			clickCount = 0
			tipText.Text = "疯狂点击蛋壳使其破裂！"
			tipText.TextColor3 = Color3.new(1,1,1)
			
			local clickConn
			clickConn = clickArea.Activated:Connect(function()
				clickCount = clickCount + 1
				
				-- 1. 呼叫 VFX 模块处理物理晃动反馈
				Controllers.VFX.PlayEggShakeVFX(current3DModel)
				
				-- 2. 破壳！
				if clickCount >= 5 then
					clickConn:Disconnect() 
					clearViewport()
					
					if resultPetId then
						local petTemplate = petModels:FindFirstChild(resultPetId)
						local petData = Controllers.Config.PETS[resultPetId]
						
						if petTemplate and petData then
							current3DModel = petTemplate:Clone()
							current3DModel:SetPrimaryPartCFrame(CFrame.new(0, 0, 0))
							current3DModel.Parent = viewport
							
							tipText.Text = string.format("恭喜获得 %s (%s)\nATK: %d | ASPD: %s", petData.Name, petData.Rarity, petData.ATK, tostring(petData.ASPD))
							tipText.TextColor3 = petData.Color
							
							-- 3. 呼叫 VFX 模块接管匀速自转动画，并把循环指针存起来以便清理
							spinConnection = Controllers.VFX.StartPetSpinVFX(current3DModel)
						end
					end
					
					task.wait(3) 
					hatchScreen.Visible = false
					isHatching = false
					clearViewport()
				end
			end)
		end)
	end

	local function bindExitButton()
		local playerGui = player:FindFirstChild("PlayerGui")
		if not playerGui then return end
		local mainUI = playerGui:FindFirstChild("MainUI")
		if not mainUI then return end
		
		local exitButton = mainUI:FindFirstChild("ExitButton")
		if exitButton and exitButton:IsA("GuiButton") then
			if not exitButton:GetAttribute("IsBound") then
				exitButton:SetAttribute("IsBound", true)
				
				exitButton.Activated:Connect(function()
					local char = player.Character
					if char then
						local hum = char:FindFirstChild("Humanoid")
						if hum then
							hum.Health = 0 
						end
					end
				end)
			end
		end
	end

	task.spawn(function()
		local playerGui = player:WaitForChild("PlayerGui")
		playerGui:WaitForChild("MainUI", 5)
		playerGui:WaitForChild("CharacterStatsUI", 5) 
		-- 1. 铺设开局初始数据渲染面
		updateUI()
		-- 2. 依次加载且仅加载一次各个独立的交互面板初始化，完成安全的底层网络绑定
		setupLevelUpUI() 
		setupShopUI() 
      setupPetBagUI()
      setupPetHatching()
	end)

	-- 全局属性改变触发器
	player.AttributeChanged:Connect(function(attributeName)
		updateUI() -- 属性一变，只驱动轻量级的渲染，绝不重复绑定事件

		-- 将 UI 动画表现移交给特效模块处理
		if attributeName == "Coins" then
			local playerGui = player:FindFirstChild("PlayerGui")
			local mainUI = playerGui and playerGui:FindFirstChild("MainUI")
			
			-- 寻找并弹跳整个 CoinContainer
			local coinContainer = mainUI and mainUI:FindFirstChild("CoinContainer")
			
			if coinContainer then
				-- 呼叫 VFX 模块，传入需要跳动的 UI 控件
				Controllers.VFX.PlayUIBounce(coinContainer)
			end
		end
	end)
	
	player.CharacterAdded:Connect(function(newCharacter)
		newCharacter:WaitForChild("HumanoidRootPart", 5)
		task.defer(function()
			updateUI()
			bindExitButton()
		end)
	end)
	
	if player.Character then
		task.spawn(function()
			player.Character:WaitForChild("HumanoidRootPart", 5)
			updateUI()
		end)
	end


end

return UIController