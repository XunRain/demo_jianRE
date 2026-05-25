-- src/client/UI/UIController.luau
-- 屏幕 2D UI 与 角色常驻 3D 头顶 UI 控制器
local UIController = {}

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local player = Players.LocalPlayer

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
		local atk = player:GetAttribute("ATK") or 0
		local lvl = player:GetAttribute("Level") or 1
		local exp = player:GetAttribute("EXP") or 0
		local requiredExp = player:GetAttribute("RequiredEXP") or (lvl * 10) 
		local inCombat = player:GetAttribute("InCombat") == true
      local currentStage = player:GetAttribute("CurrentStage") or 1

		-- 1. 刷新屏幕 UI 控制
		if mainUI then
			-- 金币常驻常显
			local coinsLabel = mainUI:FindFirstChild("CoinsLabel")
			if coinsLabel and coinsLabel:IsA("TextLabel") then
				coinsLabel.Text = "货币: " .. tostring(coins)
			end

			-- 退出按钮
			local exitButton = mainUI:FindFirstChild("ExitButton")
			if exitButton and exitButton:IsA("GuiButton") then
				exitButton.Visible = inCombat and not player:GetAttribute("IsLevelingUp")
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
				statsLabel.Text = string.format("Lv.%d | ATK: %d", lvl, atk)
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

					-- 应用玩家选择的增益
					if attr == "ALL" then
						player:SetAttribute("ATK", (player:GetAttribute("ATK") or 0) + 5)
						player:SetAttribute("ASPD", (player:GetAttribute("ASPD") or 0) + 0.2)
						
						-- 全能增益时，同步提升最大生命上限与当前生命值
                  local currentMax = player:GetAttribute("MaxHP") or Controllers.Config.BASE_HP
						player:SetAttribute("MaxHP", currentMax + 20)
                  local currentHp = player:GetAttribute("HP") or Controllers.Config.BASE_HP
						player:SetAttribute("HP", currentHp + 20)
					else
						if attr == "HP" then
							-- 单独选择生命加成卡片时，同步提升最大生命上限与当前生命值
							local currentMax = player:GetAttribute("MaxHP") or Controllers.Config.BASE_HP
							player:SetAttribute("MaxHP", currentMax + amount)
							local currentHp = player:GetAttribute("HP") or Controllers.Config.BASE_HP
							player:SetAttribute("HP", currentHp + amount)
						else
							player:SetAttribute(attr, (player:GetAttribute(attr) or 0) + amount)
						end
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
				
				-- 增益池中依然保留了攻速，玩家可以抽到，但不会在屏幕上显示文本数值，全靠子弹射速直观感知
				local buffPool = {
					{ name = "攻击力大增", attr = "ATK", amount = 10, color = Color3.fromRGB(255, 100, 100) },
					{ name = "攻速提升", attr = "ASPD", amount = 0.5, color = Color3.fromRGB(100, 255, 100) },
					{ name = "恢复生命", attr = "HP", amount = 50, color = Color3.fromRGB(100, 255, 255) },
					{ name = "小幅全能", attr = "ALL", amount = 0, color = Color3.fromRGB(255, 215, 0) },
               { name = "磁力范围", attr = "MagnetRadius", amount = 5, color = Color3.fromRGB(180, 100, 255) }
				}

				for i, card in ipairs(cards) do
					if card and card:IsA("GuiButton") then
						local buff = buffPool[math.random(1, #buffPool)]
						
						card:SetAttribute("BuffAttr", buff.attr)
						card:SetAttribute("BuffAmount", buff.amount)
						
						card.Text = buff.name .. "\n+" .. tostring(buff.amount)
						if buff.attr == "ALL" then card.Text = "攻击+5\n攻速+0.2\n最大血量+20" end
						card.BackgroundColor3 = buff.color
						
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
		updateUI()
		bindExitButton()
		setupLevelUpUI() 
	end)

	player.AttributeChanged:Connect(function(attributeName)
		updateUI()
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