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
		local formatNumber = Controllers.Config.FormatNumber

		-- 1. 刷新屏幕 UI 控制
		if mainUI then
			-- 金币常驻常显
			local coinContainer = mainUI:FindFirstChild("CoinContainer")
			if coinContainer then
				local coinText = coinContainer:FindFirstChild("CoinText")
				if coinText and coinText:IsA("TextLabel") then
					coinText.Text = formatNumber(coins)
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
						healthText.Text = formatNumber(hp) .. " / " .. formatNumber(maxHp)
					end

					-- 经验条比例并更新 Size
					local expBar = combatHub:FindFirstChild("ExpBar", true)
					if expBar then
						local expPercent = math.clamp(exp / requiredExp, 0, 1)
						expBar.Size = UDim2.new(expPercent, 0, 1, 0)
					end
					
					local expText = combatHub:FindFirstChild("ExpText", true)
					if expText and expText:IsA("TextLabel") then
						expText.Text = formatNumber(exp) .. " / " .. formatNumber(requiredExp)
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
				statsLabel.Text = string.format("Lv.%d | ATK: %s", lvl, formatNumber(displayAtk))
			end
		end

      
	end

	-- 升级卡片 UI 控制模块
	local function setupLevelUpUI()
		local playerGui = player:WaitForChild("PlayerGui")
		local mainUI = playerGui:WaitForChild("MainUI")
		local levelUpPanel = mainUI:WaitForChild("LevelUpPanel", 5)
		
		if not levelUpPanel then return end

		-- 收集 Studio 里已经设计好的升级卡；不要直接构造含 nil 的数组，否则 ipairs 会在缺失卡片处提前停止
		local cards = {}
		for i = 1, 3 do
			local card = levelUpPanel:FindFirstChild("Card" .. tostring(i))
			if card and card:IsA("GuiButton") then
				table.insert(cards, card)
			else
				warn("升级卡 UI 缺失或类型不正确: Card" .. tostring(i))
			end
		end

		local cardBaseRotations = {}
		for _, card in ipairs(cards) do
			if card and card:IsA("GuiButton") then
				cardBaseRotations[card] = card.Rotation
			end
		end

		-- 获取升级卡稳定 ID，用于记录“这张卡已经选过几次”
		local function getBuffId(buff)
			return buff.BuffId or buff.Attr or buff.Name
		end

		-- 获取升级卡等级 Attribute 名；每局开始会由 GameController 统一清零
		local function getBuffLevelKey(buffOrId)
			local buffId = type(buffOrId) == "table" and getBuffId(buffOrId) or buffOrId
			return "BuffLevel_" .. tostring(buffId)
		end

		-- 读取玩家当前局内某张升级卡的选择次数
		local function getBuffLevel(buff)
			return player:GetAttribute(getBuffLevelKey(buff)) or 0
		end

		-- 根据当前武器/宠物配置计算升级卡最大等级；没有上限时返回 nil
		local function getBuffMaxLevel(buff)
			if buff.MaxLevel then
				return buff.MaxLevel
			end

			if buff.Attr == "MultiShot" then
				local equippedWeapon = player:GetAttribute("EquippedWeapon") or "DefaultWeapon"
				local weaponConfig = Controllers.Config.WEAPONS[equippedWeapon] or Controllers.Config.WEAPONS["DefaultWeapon"]
				local baseMultiShot = Controllers.Config.BASE_MULTISHOT or 1
				return math.max(0, (weaponConfig.MaxMultiShot or baseMultiShot) - baseMultiShot)
			elseif buff.Attr == "Pet_Count" then
				local petConf = Controllers.Config.PETS[player:GetAttribute("EquippedPet")]
				return math.max(0, ((petConf and petConf.MaxCount) or 1) - 1)
			elseif buff.Attr == "WindBlade_Range_Bonus" then
				local petConf = Controllers.Config.PETS[player:GetAttribute("EquippedPet")]
				local baseWidth = (petConf and petConf.WindBladeBaseWidth) or 20
				local maxWidth = (petConf and petConf.WindBladeMaxWidth) or 40
				local maxBonus = math.max(0, ((maxWidth / baseWidth) - 1) * 100)
				return math.max(0, math.ceil(maxBonus / math.max(buff.Amount or 1, 1)))
			elseif buff.Attr == "MagnetRadius_Bonus" then
				-- 磁力范围按百分比成长，最大等级由基础半径和最大半径自动推导。
				local baseRadius = Controllers.Config.MAGNET_RADIUS or 15
				local maxRadius = Controllers.Config.MAX_MAGNET_RADIUS or baseRadius
				local maxBonus = math.max(0, ((maxRadius / baseRadius) - 1) * 100)
				return math.max(0, math.ceil(maxBonus / math.max(buff.Amount or 1, 1)))
			end

			return nil
		end

		-- 判断升级卡是否已经达到上限，用于发牌前过滤
		local function isBuffAtMax(buff)
			local maxLevel = getBuffMaxLevel(buff)
			return maxLevel ~= nil and getBuffLevel(buff) >= maxLevel
		end

		-- 点击卡片后记录选择次数；有上限的卡片不会超过最大等级
		local function increaseBuffLevel(buffId, maxLevel)
			local levelKey = getBuffLevelKey(buffId)
			local currentLevel = player:GetAttribute(levelKey) or 0
			local nextLevel = currentLevel + 1
			if maxLevel then
				nextLevel = math.min(nextLevel, maxLevel)
			end
			player:SetAttribute(levelKey, nextLevel)
		end

		-- 生成升级卡显示文本：增益数值 + 当前等级 -> 选择后等级 + 可选最大等级
		local function buildBuffCardText(buff)
			local currentLevel = getBuffLevel(buff)
			local maxLevel = getBuffMaxLevel(buff)
			local nextLevel = maxLevel and math.min(currentLevel + 1, maxLevel) or (currentLevel + 1)
			-- 智能识别百分比与加减号符号
			-- 判断是否需要加 % 符号 (带有 Bonus 或 Reduction 都算是百分比加成)
			local isPercent = (buff.Attr == "ALL") or string.find(buff.Attr or "", "Bonus") or string.find(buff.Attr or "", "Reduction")
			local suffix = isPercent and "%" or ""
			
			local amountText
			if buff.Attr == "ALL" then
				amountText = "各项 +" .. tostring(buff.Amount) .. "%"
			elseif string.find(buff.Attr or "", "Reduction") then
				-- 如果是“缩减”类属性（如 CD 缩减），前面显示减号 "-"
				amountText = "-" .. tostring(buff.Amount) .. suffix
			else
				-- 其他常规增益显示加号 "+"
				amountText = "+" .. tostring(buff.Amount) .. suffix
			end

			if buff.CardNote then
				amountText = amountText .. "\n" .. buff.CardNote
			end

			local levelText = string.format("Lv.%d -> Lv.%d", currentLevel, nextLevel)
			if maxLevel then
				levelText = levelText .. " / Max Lv." .. tostring(maxLevel)
			end

			return string.format("%s\n%s\n%s", buff.Name, amountText, levelText)
		end

		-- 事件绑定剥离，全局只绑定一次
		for _, card in ipairs(cards) do
			if card and card:IsA("GuiButton") then
				card.Activated:Connect(function()
					if not player:GetAttribute("IsLevelingUp") then return end
					
					local attr = card:GetAttribute("BuffAttr")
					local amount = card:GetAttribute("BuffAmount")
					local buffId = card:GetAttribute("BuffId") or attr
					local buffMaxLevel = card:GetAttribute("BuffMaxLevel")
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

					-- 玩家真正点击卡片后，给予属性
					if attr == "ALL" then
						player:SetAttribute("ATK_Bonus", (player:GetAttribute("ATK_Bonus") or 0) + amount)
						player:SetAttribute("ASPD_Bonus", (player:GetAttribute("ASPD_Bonus") or 0) + amount)
						applyMaxHpBonus(amount) 
					elseif attr == "MaxHP_Bonus" then
						applyMaxHpBonus(amount)
					elseif attr == "Pet_Count" then
						-- 【核心修改】：处理增加宠物数量，确保不超过当前宠物的最大上限
						local currentCount = player:GetAttribute("Pet_Count") or 1
						local petConf = Controllers.Config.PETS[player:GetAttribute("EquippedPet")]
						local maxLimit = (petConf and petConf.MaxCount) or 3
						
						-- 取 (当前数量+增量) 与 (最大上限) 中的最小值
						local finalCount = math.min(currentCount + amount, maxLimit)
						player:SetAttribute("Pet_Count", finalCount)
						
						if Controllers.Pet and Controllers.Pet.UpdatePetClones then
							Controllers.Pet.UpdatePetClones()
						end
					elseif attr == "WindBlade_Range_Bonus" then
						-- 风刃范围按百分比成长，但最终宽度不能超过宠物配置里的 WindBladeMaxWidth
						local petConf = Controllers.Config.PETS[player:GetAttribute("EquippedPet")]
						local baseWidth = (petConf and petConf.WindBladeBaseWidth) or 20
						local maxWidth = (petConf and petConf.WindBladeMaxWidth) or 40
						local currentBonus = player:GetAttribute("WindBlade_Range_Bonus") or 0
						local maxBonus = math.max(0, math.floor(((maxWidth / baseWidth) - 1) * 100))
						player:SetAttribute("WindBlade_Range_Bonus", math.min(currentBonus + amount, maxBonus))
					elseif attr == "MagnetRadius_Bonus" then
						-- 磁力范围按百分比成长，但最终吸附半径不能超过配置表里的 MAX_MAGNET_RADIUS。
						local baseRadius = Controllers.Config.MAGNET_RADIUS or 15
						local maxRadius = Controllers.Config.MAX_MAGNET_RADIUS or baseRadius
						local currentBonus = player:GetAttribute("MagnetRadius_Bonus") or 0
						local maxBonus = math.max(0, math.floor(((maxRadius / baseRadius) - 1) * 100))
						player:SetAttribute("MagnetRadius_Bonus", math.min(currentBonus + amount, maxBonus))
					else
						-- 其他所有属性（包括攻速、攻击、宠物攻速、宠物攻击等）自动在这里叠加
						player:SetAttribute(attr, (player:GetAttribute(attr) or 0) + amount)
					end
					
					-- 同步实际血量给原生的人偶模型
					local humanoid = player.Character and player.Character:FindFirstChild("Humanoid")
					if humanoid then
						humanoid.MaxHealth = player:GetAttribute("MaxHP")
						humanoid.Health = player:GetAttribute("HP")
					end

					increaseBuffLevel(buffId, buffMaxLevel)

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
				local availablePool = {}
				local equippedPet = player:GetAttribute("EquippedPet")
				local hasPet = (equippedPet and equippedPet ~= "")
				local currentPetCount = player:GetAttribute("Pet_Count") or 1
				local validPool = {}
				local totalWeight = 0

				-- 获取当前佩戴宠物的专属上限 (如果没有配，兜底为 3)
				local petConfig = hasPet and Controllers.Config.PETS[equippedPet]
				local maxPetLimit = (petConfig and petConfig.MaxCount) or 3
				
				-- 智能过滤卡池
				for _, buff in ipairs(Controllers.Config.LEVEL_UP_BUFF_POOL) do
					-- 如果卡片需要宠物，但玩家没带，则跳过
					if buff.RequiresPet and not hasPet then continue end
					-- 如果卡片绑定特定宠物技能，只有当前装备宠物技能匹配时才进入卡池
					if buff.RequiresPetSkill then
						if not petConfig or petConfig.SkillType ~= buff.RequiresPetSkill then
							continue
						end

						-- 风刃范围已经达到上限后，不再继续发“增加范围”卡
						if buff.Attr == "WindBlade_Range_Bonus" then
							local baseWidth = petConfig.WindBladeBaseWidth or 20
							local maxWidth = petConfig.WindBladeMaxWidth or 40
							local currentBonus = player:GetAttribute("WindBlade_Range_Bonus") or 0
							local currentWidth = baseWidth * (1 + (currentBonus / 100))
							if currentWidth >= maxWidth then
								continue
							end
						end
					end
					-- 如果是增加宠物数量，且场上已经有 3 只了 (1本体+2分身)，就不再发这张卡
					if buff.Attr == "Pet_Count" and currentPetCount >= maxPetLimit then continue end
					-- 前置条件过滤 (如果卡片配置了 Prereq，但玩家没有该前置属性，则跳过)
					if buff.Prereq and (player:GetAttribute(buff.Prereq) or 0) <= 0 then continue end
					-- 已经达到上限的卡片不再进入卡池，同时 UI 上会在未满时显示 Max Lv
					if isBuffAtMax(buff) then continue end
					table.insert(availablePool, buff)
				end

				-- 获取玩家当前的弹道数量和当前武器的上限
				local currentMultiShot = player:GetAttribute("MultiShot") or 1
				local equippedWeapon = player:GetAttribute("EquippedWeapon") or "DefaultWeapon"
				local weaponConfig = Controllers.Config.WEAPONS[equippedWeapon] or Controllers.Config.WEAPONS["DefaultWeapon"]
				local maxMultiShot = weaponConfig.MaxMultiShot or 3
				
				-- 遍历智能过滤后的池子，生成合法的抽卡池
				for _, buff in ipairs(availablePool) do
					-- 如果弹道数已经达到了当前武器的上限，这辈子都不会再把它放入抽卡池！
					if buff.Attr == "MultiShot" and currentMultiShot >= maxMultiShot then
						continue
					end
					
					table.insert(validPool, buff)
					totalWeight = totalWeight + (buff.Weight or 100) -- 没配权重兜底为 100
				end

				if totalWeight <= 0 then
					warn("升级卡池为空：没有可用的升级选项。")
					levelUpPanel.Visible = false
					player:SetAttribute("IsLevelingUp", false)
					return
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
						card:SetAttribute("BuffId", getBuffId(buff))
						card:SetAttribute("BuffMaxLevel", getBuffMaxLevel(buff))
						card.Text = buildBuffCardText(buff)
						card.BackgroundColor3 = buff.Color
						
						local targetRotation = cardBaseRotations[card] or 0
						card.Rotation = targetRotation - 180
						
						local tweenInfo = TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
						local tween = TweenService:Create(card, tweenInfo, {
							Rotation = targetRotation
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
				local displayText = talentData.Name .. " Lv." .. currentLevel .. "\n金币: " .. Config.FormatNumber(cost)
				
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

		-- 安全解析宠物背包；存档字段异常时返回空表，避免 UI 打不开
		local function decodeOwnedPets()
			local success, decoded = pcall(function()
				return HttpService:JSONDecode(player:GetAttribute("OwnedPets_JSON") or "[]")
			end)

			if not success or type(decoded) ~= "table" then
				return {}
			end

			local owned = {}
			for _, petId in ipairs(decoded) do
				if type(petId) == "string" and Controllers.Config.PETS[petId] then
					table.insert(owned, petId)
				end
			end

			return owned
		end

		-- 将宠物 ID 按配置里的 SortOrder/名称排序，保证背包每次刷新顺序稳定
		local function getSortedPetIds(petCounts)
			local petIds = {}
			for petId, count in pairs(petCounts) do
				if count > 0 and Controllers.Config.PETS[petId] then
					table.insert(petIds, petId)
				end
			end

			table.sort(petIds, function(a, b)
				local sortA = Controllers.Config.GetPetSortValue and Controllers.Config.GetPetSortValue(a) or math.huge
				local sortB = Controllers.Config.GetPetSortValue and Controllers.Config.GetPetSortValue(b) or math.huge
				if sortA ~= sortB then
					return sortA < sortB
				end

				local nameA = Controllers.Config.PETS[a].Name or a
				local nameB = Controllers.Config.PETS[b].Name or b
				return nameA < nameB
			end)

			return petIds
		end

		-- 生成宠物按钮上的展示文本，集中处理名称、数量、稀有度、状态和描述
		local function getPetButtonText(petId, count, statusText)
			local petConfig = Controllers.Config.PETS[petId]
			if not petConfig then return petId end

			local countText = (count and count > 1) and (" x" .. count) or ""
			local rarityText = petConfig.Rarity or "Unknown"
			local description = petConfig.Description or "暂无描述"
			local statusLine = statusText and ("\n" .. statusText) or ""

			return string.format(
				"%s%s [%s]%s\nATK:%s\n%s",
				petConfig.Name or petId,
				countText,
				rarityText,
				statusLine,
				Controllers.Config.FormatNumber(petConfig.ATK or 0),
				description
			)
		end

		-- 给宠物按钮应用文本，并开启自动缩放/换行，适配多行描述
		local function applyPetButtonText(btn, text)
			btn.Text = text
			if btn:IsA("TextButton") then
				btn.TextWrapped = true
				btn.TextScaled = true
			end
		end

		local function refreshBag()
			-- 安全清理两个容器内的旧 UI (千万别把 UIGridLayout 删了)
			for _, child in ipairs(equippedContainer:GetChildren()) do
				if not child:IsA("UIGridLayout") then child:Destroy() end
			end
			for _, child in ipairs(standbyContainer:GetChildren()) do
				if not child:IsA("UIGridLayout") then child:Destroy() end
			end
			
			local owned = decodeOwnedPets()
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
				
				applyPetButtonText(btn, getPetButtonText(equipped, 1, "出战中"))
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
			for _, petId in ipairs(getSortedPetIds(petCounts)) do
				local count = petCounts[petId]
				if count > 0 then -- 如果还有剩余宠物在待机
					local petConfig = Controllers.Config.PETS[petId]
					if petConfig then
						local btn = petTemplate:Clone()
						btn.Visible = true 
						btn.Parent = standbyContainer
						
						applyPetButtonText(btn, getPetButtonText(petId, count))
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
		local eggPart = Workspace:WaitForChild("paodao"):WaitForChild("PetEgg", 10)
		if not eggPart then return end
		local prompt = eggPart:FindFirstChildOfClass("ProximityPrompt") or Instance.new("ProximityPrompt", eggPart)
		prompt.ActionText = "花费 " .. Controllers.Config.FormatNumber(Controllers.Config.PET_GACHA_COST) .. " 抽宠"
		
		local playerGui = player:WaitForChild("PlayerGui")
		local mainUI = playerGui:WaitForChild("MainUI")
		
		-- 等待美术做好的全屏抽卡界面
		local hatchScreen = mainUI:WaitForChild("HatchScreen", 5)
		if not hatchScreen then return end
		
		local viewport = hatchScreen:WaitForChild("PetViewport")
		local clickArea = hatchScreen:WaitForChild("BtnClickArea")
		local tipText = hatchScreen:WaitForChild("TipText")
		
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		local petModels = ReplicatedStorage:WaitForChild("Model"):WaitForChild("Pets")
		
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
							
							tipText.Text = string.format("恭喜获得 %s (%s)", petData.Name, petData.Rarity)
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
