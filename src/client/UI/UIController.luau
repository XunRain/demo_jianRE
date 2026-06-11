-- src/client/UI/UIController.luau
-- 屏幕 2D UI 与 角色常驻 3D 头顶 UI 控制器
local UIController = {}

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer
local HttpService = game:GetService("HttpService")

local Controllers -- 全局依赖指针

-- 3D 属性 UI 常驻玩家头顶上方 3.5 格（所有人可见）
local HEAD_OFFSET = Vector3.new(0, 3.5, 0)   

-- 判断当前设备是否按纯手机端处理；PC 上接了触屏时仍保留桌面 UI 尺寸。
local function isMobileOnlyDevice()
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

-- 查找 Studio 模板里可能存在的文字节点，兼容不同命名，避免代码强制重建 UI。
local function findTextNode(root, names)
	for _, name in ipairs(names) do
		local node = root:FindFirstChild(name, true)
		if node and (node:IsA("TextLabel") or node:IsA("TextButton")) then
			return node
		end
	end
	return nil
end

-- 查找 Studio 模板里可能存在的图标节点；只负责绑定图片，不修改图标位置和样式。
-- 只按指定名称查找图片节点；用于角标等精确绑定，避免误拿到主图标节点。
local function findNamedImageNode(root, names)
	for _, name in ipairs(names) do
		local node = root:FindFirstChild(name, true)
		if node and (node:IsA("ImageLabel") or node:IsA("ImageButton")) then
			return node
		end
	end

	return nil
end

local function findImageNode(root, names)
	local namedNode = findNamedImageNode(root, names)
	if namedNode then
		return namedNode
	end

	local iconBadge = root:FindFirstChild("IconBadge", true)
	if iconBadge then
		local imageNode = iconBadge:FindFirstChildWhichIsA("ImageLabel", true) or iconBadge:FindFirstChildWhichIsA("ImageButton", true)
		if imageNode then
			return imageNode
		end
	end

	return nil
end

-- 从数字、纯数字字符串或 rbxassetid:// 写法中提取资源数字 ID；用于缩略图模式。
local function extractAssetIdNumber(assetId)
	if type(assetId) == "number" then
		return tostring(assetId)
	end

	if type(assetId) ~= "string" then
		return nil
	end

	if string.find(assetId, "^%d+$") then
		return assetId
	end

	return string.match(assetId, "^rbxassetid://(%d+)$")
end

-- 统一整理 Roblox 图片资源 ID；缩略图模式可兼容 Creator Store/Decal/Asset 页面 ID。
local function normalizeImageAssetId(assetId, useThumbnail)
	if type(assetId) ~= "number" and (type(assetId) ~= "string" or assetId == "") then
		return nil
	end

	local assetNumber = extractAssetIdNumber(assetId)
	if useThumbnail and assetNumber then
		return "rbxthumb://type=Asset&id=" .. assetNumber .. "&w=420&h=420"
	end

	if assetNumber then
		return "rbxassetid://" .. assetNumber
	end

	return assetId
end

-- 退出按钮使用美术图片本体；代码只绑定鼠标悬浮缩放，不再额外添加渐变、描边、投影等装饰。
local function applyExitButtonHoverScale(exitButton)
	if not exitButton or not exitButton:IsA("GuiButton") then return end

	-- 清理旧版代码动态添加的装饰层，避免覆盖美术给的退出按钮图片。
	for _, child in ipairs(exitButton:GetChildren()) do
		if string.sub(child.Name, 1, 9) == "ExitDepth" then
			child:Destroy()
		end
	end

	local hoverScale = exitButton:FindFirstChild("ExitHoverScale")
	if not hoverScale then
		hoverScale = Instance.new("UIScale")
		hoverScale.Name = "ExitHoverScale"
		hoverScale.Parent = exitButton
	end

	if exitButton:GetAttribute("ExitHoverScaleBound") then return end
	exitButton:SetAttribute("ExitHoverScaleBound", true)

	local normalScale = hoverScale.Scale
	local targetScale = 1.08
	local tweenInfo = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	exitButton.MouseEnter:Connect(function()
		TweenService:Create(hoverScale, tweenInfo, { Scale = targetScale }):Play()
	end)

	exitButton.MouseLeave:Connect(function()
		TweenService:Create(hoverScale, tweenInfo, { Scale = normalScale }):Play()
	end)

	exitButton.Activated:Connect(function()
		TweenService:Create(hoverScale, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 0.96 }):Play()
		task.delay(0.08, function()
			if hoverScale and hoverScale.Parent then
				TweenService:Create(hoverScale, tweenInfo, { Scale = normalScale }):Play()
			end
		end)
	end)
end

-- 查找关卡 HUD：优先使用美术做好的图片容器，兼容旧版纯文字 StageLabel。
local function findStageHud(mainUI)
	for _, name in ipairs({"StageHUD", "StagePanel", "StageContainer", "StageFrame", "StageLabel"}) do
		local node = mainUI:FindFirstChild(name, true)
		if node and node:IsA("GuiObject") then
			return node
		end
	end

	return nil
end

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
		local requiredExp = player:GetAttribute("RequiredEXP") or Controllers.Config.GetRequiredExp(lvl)
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
				applyExitButtonHoverScale(exitButton)
				exitButton.Visible = inCombat and not player:GetAttribute("IsLevelingUp")
			end

			-- 手机端滑动控制提示层：UI 由 Studio 设计，代码只负责按设备和战斗状态控制显隐。
			local mobileControls = mainUI:FindFirstChild("MobileControls", true)
			if mobileControls and mobileControls:IsA("GuiObject") then
				mobileControls.Visible = isMobileOnlyDevice() and inCombat and not player:GetAttribute("IsLevelingUp")
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

			-- 关卡 HUD 使用 Studio 里的图片容器；代码只控制显隐并填充关卡文本。
			local stageHud = findStageHud(mainUI)
			if stageHud then
				local showStage = inCombat and not player:GetAttribute("IsLevelingUp")
				stageHud.Visible = showStage

				local stageText = nil
				if stageHud:IsA("TextLabel") or stageHud:IsA("TextButton") then
					stageText = stageHud
				else
					stageText = findTextNode(stageHud, {"StageText", "StageLabel", "LevelText", "TextLabel"})
				end

				if stageText then
					stageText.Text = tostring(currentStage)
				end
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

		-- 根据 BuffId 快速找到完整卡片配置；Boss 金色奖励池只配置 BuffId，实际发牌仍复用 LEVEL_UP_BUFF_POOL 里的完整数据。
		local function findBuffById(buffId)
			for _, buff in ipairs(Controllers.Config.LEVEL_UP_BUFF_POOL or {}) do
				if getBuffId(buff) == buffId then
					return buff
				end
			end
			return nil
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

		-- 生成升级卡显示数据：标题、数值、补充说明、等级分开返回，方便 Studio 拆分多个 TextLabel。
		local function buildBuffCardDisplay(buff)
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

			local levelText = string.format("Lv.%d -> Lv.%d", currentLevel, nextLevel)
			if maxLevel then
				levelText = levelText .. " / Max Lv." .. tostring(maxLevel)
			end

			local fullText = string.format("%s\n%s\n%s", buff.Name, amountText, levelText)
			if buff.CardNote then
				fullText = string.format("%s\n%s\n%s\n%s", buff.Name, amountText, buff.CardNote, levelText)
			end

			return {
				Title = buff.Name,
				Amount = amountText,
				Note = buff.CardNote,
				Level = levelText,
				FullText = fullText,
			}
		end

		-- 获取升级卡图标资源；优先使用单张卡配置，其次按 BuffId/Attr 查共享图标表。
		local function getBuffIconAssetId(buff)
			local iconMap = Controllers.Config.LEVEL_UP_BUFF_ICONS or {}
			local buffId = getBuffId(buff)
			local iconAssetId = buff.Icon or iconMap[buffId] or iconMap[buff.Attr]
			return normalizeImageAssetId(iconAssetId, Controllers.Config.LEVEL_UP_BUFF_ICON_USE_THUMBNAIL == true)
		end

		-- 获取升级卡右上角标图标；角标和卡片主图标分开配置，避免互相覆盖。
		local function getBuffBadgeIconAssetId(buff, art)
			local badgeIconMap = Controllers.Config.LEVEL_UP_CARD_BADGE_ICONS or {}
			local buffId = getBuffId(buff)
			local iconAssetId = buff.BadgeIcon
				or art.BadgeIcon
				or badgeIconMap[buffId]
				or badgeIconMap[buff.Attr]
				or badgeIconMap[art.Category]

			local useThumbnail = Controllers.Config.LEVEL_UP_CARD_BADGE_ICON_USE_THUMBNAIL
			if useThumbnail == nil then
				useThumbnail = Controllers.Config.LEVEL_UP_BUFF_ICON_USE_THUMBNAIL == true
			end

			return normalizeImageAssetId(iconAssetId, useThumbnail == true)
		end

		-- 获取升级卡美术分类；分类用于切换 Studio 预制层和填右上角角标。
		local function getBuffCardArt(buff)
			local artMap = Controllers.Config.LEVEL_UP_CARD_ART or {}
			local buffId = getBuffId(buff)
			return artMap[buffId] or artMap[buff.Attr] or {
				Category = "PlayerStats",
				CategoryName = "玩家属性",
				Badge = buff.Name or buffId,
			}
		end

		-- 按分类切换美术预制层；美术可使用 CategoryLayer_PlayerStats 或给层设置 CardArtCategory 属性。
		local function applyCardCategoryLayers(card, activeCategory)
			-- 根据升级卡功能分类切换 Studio 预制美术层；支持功能名层和颜色名层两种命名。
			local layerAliases = Controllers.Config.LEVEL_UP_CARD_LAYER_ALIASES or {
				PlayerStats = {"PlayerStats", "Purple"},
				Pet = {"Pet", "Green"},
				Sword = {"Sword", "Blue"},
				WeaponProjectile = {"WeaponProjectile", "Projectile", "Gold", "Yellow"},
				Rare = {"Rare", "All", "Gold", "Yellow"},
			}

			-- 判断某个图层标记是否属于当前要显示的功能分类。
			local function isActiveLayer(layerKey)
				if layerKey == activeCategory then
					return true
				end

				for _, alias in ipairs(layerAliases[activeCategory] or {}) do
					if layerKey == alias then
						return true
					end
				end

				return false
			end

			-- 识别并切换所有分类图层；只改 Visible，不改美术设置好的颜色、尺寸和图片。
			local function applyLayerVisibility(node, layerKey)
				node.Visible = isActiveLayer(layerKey)
				node:SetAttribute("CardArtLayerActive", node.Visible)
			end

			for _, node in ipairs(card:GetDescendants()) do
				if node:IsA("GuiObject") then
					local attrCategory = node:GetAttribute("CardArtCategory")
					if attrCategory then
						applyLayerVisibility(node, tostring(attrCategory))
					end

					for category, aliases in pairs(layerAliases) do
						if node.Name == "CategoryLayer_" .. category or node.Name == "CardArt_" .. category then
							applyLayerVisibility(node, category)
						end

						for _, alias in ipairs(aliases) do
							if node.Name == "CategoryLayer_" .. alias or node.Name == "CardArt_" .. alias then
								applyLayerVisibility(node, alias)
							end
						end
					end
				end
			end
		end

		-- 填充升级卡美术元信息；只写可选文本和属性，不修改颜色、尺寸、边框等美术样式。
		local function applyBuffCardArt(card, buff)
			local art = getBuffCardArt(buff)
			local category = art.Category or "PlayerStats"
			local categoryName = art.CategoryName or category
			local badge = art.Badge or buff.Name or getBuffId(buff)

			card:SetAttribute("CardArtCategory", category)
			card:SetAttribute("CardArtCategoryName", categoryName)
			card:SetAttribute("CardArtBadge", badge)
			local layerAliases = Controllers.Config.LEVEL_UP_CARD_LAYER_ALIASES or {}
			card:SetAttribute("CardArtLayerAliases", table.concat(layerAliases[category] or {category}, ","))
			applyCardCategoryLayers(card, category)

			local badgeText = findTextNode(card, {"BadgeText", "CornerBadgeText", "TypeBadgeText"})
			if badgeText then
				badgeText.Text = badge
				badgeText.Visible = true
			end

			local categoryText = findTextNode(card, {"CategoryText", "CategoryNameText", "CardTypeText"})
			if categoryText then
				categoryText.Text = categoryName
				categoryText.Visible = true
			end

			-- 填充右上角标图片；没有图片节点或资源未配置时自动隐藏，不影响文字角标。
			local badgeIconAssetId = getBuffBadgeIconAssetId(buff, art)
			card:SetAttribute("BadgeIconAssetDebug", badgeIconAssetId or "")

			local badgeIconNode = findNamedImageNode(card, {
				"BadgeIcon",
				"CornerBadgeIcon",
				"TypeBadgeIcon",
				"AttributeIcon",
				"AttrIcon",
			})
			if not badgeIconNode then
				for _, containerName in ipairs({"CornerBadge", "TypeBadge", "AttributeBadge", "BadgeFrame"}) do
					local container = card:FindFirstChild(containerName, true)
					if container then
						badgeIconNode = container:FindFirstChildWhichIsA("ImageLabel", true)
							or container:FindFirstChildWhichIsA("ImageButton", true)
						if badgeIconNode then
							break
						end
					end
				end
			end

			card:SetAttribute("BadgeIconNodeFound", badgeIconNode ~= nil)
			if badgeIconNode then
				badgeIconNode:SetAttribute("BadgeBuffDebug", getBuffId(buff))
				badgeIconNode:SetAttribute("BadgeIconAssetDebug", badgeIconAssetId or "")
				if badgeIconAssetId then
					badgeIconNode.Image = badgeIconAssetId
					badgeIconNode.Visible = true
				else
					badgeIconNode.Image = ""
					badgeIconNode.Visible = false
				end
			end
		end

		-- 填充升级卡图标；Studio 没有放图标节点时自动跳过，资源为空时隐藏图标。
		local function applyBuffCardIcon(card, buff)
			local buffId = getBuffId(buff)
			local iconAssetId = getBuffIconAssetId(buff)
			card:SetAttribute("IconBuffDebug", buffId)
			card:SetAttribute("IconAssetDebug", iconAssetId or "")

			local iconNode = findImageNode(card, {"IconImage", "CardIcon", "Icon"})
			local iconBadge = card:FindFirstChild("IconBadge", true)
			if iconBadge then
				iconBadge:SetAttribute("IconBuffDebug", buffId)
				iconBadge:SetAttribute("IconAssetDebug", iconAssetId or "")
			end

			if not iconNode then
				card:SetAttribute("IconNodeFound", false)
				if iconBadge then
					iconBadge:SetAttribute("IconNodeFound", false)
				end
				return
			end

			card:SetAttribute("IconNodeFound", true)
			card:SetAttribute("IconNodeNameDebug", iconNode.Name)
			if iconBadge then
				iconBadge:SetAttribute("IconNodeFound", true)
				iconBadge:SetAttribute("IconNodeNameDebug", iconNode.Name)
			end

			if iconAssetId then
				iconNode.Image = iconAssetId
				iconNode:SetAttribute("IconBuffDebug", buffId)
				iconNode:SetAttribute("IconAssetDebug", iconAssetId)
				iconNode:SetAttribute("IconNodeFound", true)
				iconNode.Visible = true
			else
				iconNode.Image = ""
				iconNode:SetAttribute("IconBuffDebug", buffId)
				iconNode:SetAttribute("IconAssetDebug", "")
				iconNode:SetAttribute("IconNodeFound", true)
				iconNode.Visible = false
			end
		end

		-- 填充升级卡显示内容；优先写入 Studio 子标签，没有子标签时回退到 TextButton.Text。
		local function applyBuffCardDisplay(card, buff)
			local display = buildBuffCardDisplay(buff)
			local titleText = findTextNode(card, {"TitleText", "NameText", "BuffName"})
			local amountText = findTextNode(card, {"AmountText", "EffectText", "ValueText"})
			local noteText = findTextNode(card, {"NoteText", "DescText", "DescriptionText"})
			local levelText = findTextNode(card, {"LevelText", "LevelLabel"})
			local hasSplitLabels = titleText or amountText or noteText or levelText

			if titleText then titleText.Text = display.Title end
			if amountText then amountText.Text = display.Amount end
			if levelText then levelText.Text = display.Level end
			if noteText then
				noteText.Text = display.Note or ""
				noteText.Visible = display.Note ~= nil and display.Note ~= ""
			end

			if card:IsA("TextButton") then
				card.Text = hasSplitLabels and "" or display.FullText
			end

			applyBuffCardIcon(card, buff)
			applyBuffCardArt(card, buff)
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
				local rewardMode = player:GetAttribute("LevelUpRewardMode") or "Normal"
				local bossGoldConfig = Controllers.Config.BOSS_GOLD_REWARD or {}
				local eliteGoldConfig = Controllers.Config.ELITE_GOLD_REWARD or {}
				local useBossGoldPool = rewardMode == "BossGold" and bossGoldConfig.Enabled ~= false
				local useEliteGoldGuarantee = rewardMode == "EliteGoldGuarantee" and eliteGoldConfig.Enabled ~= false

				-- 获取当前佩戴宠物的专属上限 (如果没有配，兜底为 3)
				local petConfig = hasPet and Controllers.Config.PETS[equippedPet]
				local maxPetLimit = (petConfig and petConfig.MaxCount) or 3

				local sourcePool = Controllers.Config.LEVEL_UP_BUFF_POOL
				if useBossGoldPool then
					sourcePool = {}
					for _, buffId in ipairs(bossGoldConfig.Pool or {}) do
						local buff = findBuffById(buffId)
						if buff then
							table.insert(sourcePool, buff)
						else
							warn("Boss 金色奖励池里找不到 BuffId:", buffId)
						end
					end
				end
				
				-- 智能过滤卡池
				for _, buff in ipairs(sourcePool) do
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
					warn((useBossGoldPool and "Boss 金色奖励池为空：没有可用的金色升级选项。") or (useEliteGoldGuarantee and "精英怪升级奖励池为空：没有可用的升级选项。") or "升级卡池为空：没有可用的升级选项。")
					levelUpPanel.Visible = false
					player:SetAttribute("IsLevelingUp", false)
					player:SetAttribute("LevelUpRewardMode", "Normal")
					return
				end

				local function removeBuffIdFromPool(pool, buffId)
					local removedWeight = 0
					for poolIndex = #pool, 1, -1 do
						local poolBuff = pool[poolIndex]
						if getBuffId(poolBuff) == buffId then
							removedWeight = removedWeight + (poolBuff.Weight or 100)
							table.remove(pool, poolIndex)
						end
					end
					return removedWeight
				end

				local eliteGoldPool = {}
				local eliteGoldTotalWeight = 0
				if useEliteGoldGuarantee then
					local eliteGoldIds = {}
					for _, buffId in ipairs(eliteGoldConfig.Pool or {}) do
						eliteGoldIds[tostring(buffId)] = true
					end

					for _, buff in ipairs(validPool) do
						if eliteGoldIds[tostring(getBuffId(buff))] then
							table.insert(eliteGoldPool, buff)
							eliteGoldTotalWeight = eliteGoldTotalWeight + (buff.Weight or 100)
						end
					end
				end

				-- Boss 金色奖励要求三张展示不同卡；精英怪奖励要求至少 1 张从金色池抽取。
				local drawPool = table.clone(validPool)
				local drawTotalWeight = totalWeight
				local guaranteedGoldCardIndex = nil
				if useEliteGoldGuarantee and eliteGoldTotalWeight > 0 and #cards > 0 then
					guaranteedGoldCardIndex = math.random(1, #cards)
				end

				for i, card in ipairs(cards) do
					if card and card:IsA("GuiButton") then
						if drawTotalWeight <= 0 then
							-- 极端兜底：如果可用金卡少于卡位数量，为避免 UI 空白，允许重新使用原池。
							drawPool = table.clone(validPool)
							drawTotalWeight = totalWeight
						end

						local currentDrawPool = drawPool
						local currentDrawTotalWeight = drawTotalWeight
						if useEliteGoldGuarantee and i == guaranteedGoldCardIndex and eliteGoldTotalWeight > 0 then
							currentDrawPool = eliteGoldPool
							currentDrawTotalWeight = eliteGoldTotalWeight
						end

						-- 按照权重随机抽取卡片
						local rand = math.random(1, currentDrawTotalWeight)
						local currentWeight = 0
						local buff = currentDrawPool[1]
						
						for _, b in ipairs(currentDrawPool) do
							currentWeight = currentWeight + (b.Weight or 100)
							if rand <= currentWeight then
								buff = b
								break
							end
						end

						if useBossGoldPool or useEliteGoldGuarantee then
							local selectedBuffId = getBuffId(buff)
							drawTotalWeight = drawTotalWeight - removeBuffIdFromPool(drawPool, selectedBuffId)
							if useEliteGoldGuarantee then
								eliteGoldTotalWeight = eliteGoldTotalWeight - removeBuffIdFromPool(eliteGoldPool, selectedBuffId)
							end
						end
						
						card:SetAttribute("BuffAttr", buff.Attr)
						card:SetAttribute("BuffAmount", buff.Amount)
						card:SetAttribute("BuffId", getBuffId(buff))
						card:SetAttribute("BuffMaxLevel", getBuffMaxLevel(buff))
						applyBuffCardDisplay(card, buff)
						
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
				player:SetAttribute("LevelUpRewardMode", "Normal")
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
		if shopList:IsA("ScrollingFrame") then
			shopList.ScrollingDirection = Enum.ScrollingDirection.X
			shopList.AutomaticCanvasSize = Enum.AutomaticSize.X
		end

		-- 查找可点击按钮；关闭按钮可能是 ImageButton/TextButton，装饰 ImageLabel 不参与绑定。
		local function findShopButton(root, names)
			for _, name in ipairs(names) do
				local node = root:FindFirstChild(name, true)
				if node and node:IsA("GuiButton") then
					return node
				end
			end

			return nil
		end

		-- 获取商店卡片美术分类；商店天赋第一版复用升级卡的玩家属性卡面和角标素材。
		local function getShopTalentArt(talentId, talentData)
			local artMap = Config.SHOP_TALENT_CARD_ART or {}
			local art = artMap[talentId]
			if art then
				return art
			end

			return {
				Category = "PlayerStats",
				CategoryName = "玩家属性",
				Badge = talentData.Name or talentId,
				BadgeSource = talentId,
			}
		end

		-- 判断某个 CategoryLayer 是否属于当前商品分类，兼容功能名和颜色名两种 Studio 命名方式。
		local function isShopLayerActive(layerKey, activeCategory)
			if layerKey == activeCategory then
				return true
			end

			local layerAliases = Config.LEVEL_UP_CARD_LAYER_ALIASES or {}
			for _, alias in ipairs(layerAliases[activeCategory] or {}) do
				if layerKey == alias then
					return true
				end
			end

			return false
		end

		-- 切换商店卡片的预制美术图层；只改 Visible，不覆盖美术做好的图片、颜色、尺寸和布局。
		local function applyShopCategoryLayers(card, activeCategory)
			local layerAliases = Config.LEVEL_UP_CARD_LAYER_ALIASES or {
				PlayerStats = {"PlayerStats", "Purple"},
				Pet = {"Pet", "Green"},
				Sword = {"Sword", "Blue"},
				WeaponProjectile = {"WeaponProjectile", "Projectile", "Gold", "Yellow"},
				Rare = {"Rare", "All", "Gold", "Yellow"},
			}

			local function applyLayerVisibility(node, layerKey)
				node.Visible = isShopLayerActive(layerKey, activeCategory)
				node:SetAttribute("ShopCardLayerActive", node.Visible)
			end

			for _, node in ipairs(card:GetDescendants()) do
				if node:IsA("GuiObject") then
					local attrCategory = node:GetAttribute("CardArtCategory") or node:GetAttribute("ShopCardCategory")
					if attrCategory then
						applyLayerVisibility(node, tostring(attrCategory))
					end

					for category, aliases in pairs(layerAliases) do
						if node.Name == "CategoryLayer_" .. category or node.Name == "CardArt_" .. category then
							applyLayerVisibility(node, category)
						end

						for _, alias in ipairs(aliases) do
							if node.Name == "CategoryLayer_" .. alias or node.Name == "CardArt_" .. alias then
								applyLayerVisibility(node, alias)
							end
						end
					end
				end
			end
		end

		-- 给商店卡片填充分类、角标和图标；图标复用升级卡角标配置，没有图标时自动隐藏。
		local function applyShopCardArt(card, talentId, talentData)
			local art = getShopTalentArt(talentId, talentData)
			local category = art.Category or "PlayerStats"
			local categoryName = art.CategoryName or category
			local badge = art.Badge or talentData.Name or talentId
			local badgeSource = art.BadgeSource or talentId

			card:SetAttribute("ShopCardCategory", category)
			card:SetAttribute("ShopCardCategoryName", categoryName)
			card:SetAttribute("ShopCardBadge", badge)
			card:SetAttribute("ShopCardBadgeSource", badgeSource)
			applyShopCategoryLayers(card, category)

			local badgeText = findTextNode(card, {"BadgeText", "CornerBadgeText", "TypeBadgeText"})
			if badgeText then
				badgeText.Text = badge
				badgeText.Visible = true
			end

			local categoryText = findTextNode(card, {"CategoryText", "CategoryNameText", "CardTypeText"})
			if categoryText then
				categoryText.Text = categoryName
				categoryText.Visible = true
			end

			local badgeIconMap = Config.LEVEL_UP_CARD_BADGE_ICONS or {}
			local iconAssetId = art.BadgeIcon or badgeIconMap[badgeSource] or badgeIconMap[category]
			local useThumbnail = Config.LEVEL_UP_CARD_BADGE_ICON_USE_THUMBNAIL == true
			local normalizedIcon = normalizeImageAssetId(iconAssetId, useThumbnail)
			local badgeIconNode = findNamedImageNode(card, {
				"BadgeIcon",
				"CornerBadgeIcon",
				"TypeBadgeIcon",
				"AttributeIcon",
				"AttrIcon",
				"IconImage",
				"CardIcon",
				"Icon",
			})

			card:SetAttribute("ShopBadgeIconAssetDebug", normalizedIcon or "")
			card:SetAttribute("ShopBadgeIconNodeFound", badgeIconNode ~= nil)
			if badgeIconNode then
				badgeIconNode:SetAttribute("ShopBadgeSourceDebug", badgeSource)
				badgeIconNode:SetAttribute("ShopBadgeIconAssetDebug", normalizedIcon or "")
				if normalizedIcon then
					badgeIconNode.Image = normalizedIcon
					badgeIconNode.Visible = true
				else
					badgeIconNode.Image = ""
					badgeIconNode.Visible = false
				end
			end
		end

		-- 填充商店天赋卡；优先写入美术拆好的 TextLabel，没有拆分时回退到模板原文本。
		local function applyShopItemDisplay(btn, talentId, talentData, currentLevel, cost)
			local displayText = talentData.Name .. " Lv." .. currentLevel .. "\n金币: " .. Config.FormatNumber(cost)
			local effectText = "效果: +" .. tostring(talentData.StatIncrease or 0)
			local titleText = findTextNode(btn, {"TitleText", "NameText", "TalentNameText"})
			local levelText = findTextNode(btn, {"LevelText", "LevelLabel"})
			local priceText = findTextNode(btn, {"PriceText", "CostText", "CoinText", "AmountText"})
			local effectLabel = findTextNode(btn, {"EffectText", "DescText", "DescriptionText", "NoteText"})
			local hasSplitLabels = titleText or levelText or priceText or effectLabel
			local coins = player:GetAttribute("Coins") or 0

			btn:SetAttribute("TalentId", talentId)
			btn:SetAttribute("TalentLevel", currentLevel)
			btn:SetAttribute("TalentCost", cost)
			btn:SetAttribute("CanAfford", coins >= cost)

			applyShopCardArt(btn, talentId, talentData)

			if titleText then titleText.Text = talentData.Name end
			if levelText then levelText.Text = "Lv." .. tostring(currentLevel) end
			if priceText then priceText.Text = Config.FormatNumber(cost) end
			if effectLabel then effectLabel.Text = effectText end

			if btn:IsA("TextButton") then
				btn.Text = hasSplitLabels and "" or displayText
			else
				local textLabel = btn:FindFirstChild("TextLabel")
				if textLabel and textLabel:IsA("TextLabel") and not hasSplitLabels then
					textLabel.Text = displayText
				end
			end
		end

		-- 刷新商店文本显示 (支持滑动列表的智能增量更新)
		local function refreshShopUI()
			local orderedTalentIds = Config.SHOP_TALENT_ORDER or {}
			local renderedTalentIds = {}

			local function renderTalent(talentId, layoutOrder)
				local talentData = Config.TALENTS[talentId]
				if not talentData then return end

				renderedTalentIds[talentId] = true
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
					btn:SetAttribute("ShopGenerated", true)
					
					-- 绑定购买事件
					btn.Activated:Connect(function()
						local remotes = game:GetService("ReplicatedStorage"):WaitForChild("Remotes")
						remotes:WaitForChild("BuyTalent"):FireServer(talentId)
					end)
				end

				if btn:IsA("GuiObject") then
					btn.LayoutOrder = layoutOrder
				end
				
				applyShopItemDisplay(btn, talentId, talentData, currentLevel, cost)
			end

			for orderIndex, talentId in ipairs(orderedTalentIds) do
				renderTalent(talentId, orderIndex)
			end

			-- 兼容后续临时新增但忘记放进 SHOP_TALENT_ORDER 的商品，避免配置遗漏导致商品不显示。
			local fallbackOrder = #orderedTalentIds
			for talentId in pairs(Config.TALENTS) do
				if not renderedTalentIds[talentId] then
					fallbackOrder += 1
					renderTalent(talentId, fallbackOrder)
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
		local closeBtn = findShopButton(shopPanel, {"CloseButton", "BtnClose", "ShopCloseButton"})
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
		
		-- 获取放在 Panel 根目录的宠物格和空槽模板；空槽只用于出战区补足可装备槽位。
		local petTemplate = bagPanel:WaitForChild("PetItemTemplate") 
		local emptySlotTemplate = bagPanel:WaitForChild("EmptySlotTemplate")
		local petBagConfig = Controllers.Config.PET_BAG_UI or {}
		local MAX_EQUIP_SLOTS = petBagConfig.MaxEquipSlots or 1

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

		-- 清理代码动态生成的格子；保留 Studio 中的背景、标题、分隔线和 UIGridLayout。
		local function clearGeneratedBagItems(container)
			for _, child in ipairs(container:GetChildren()) do
				if child:GetAttribute("PetBagGenerated") == true then
					child:Destroy()
				end
			end
		end

		-- 统一克隆格子的外层尺寸；避免 PetItemTemplate 和 EmptySlotTemplate 在 Studio 中尺寸不同导致显示一大一小。
		local function syncBagItemSizeToGrid(item, parent)
			if not item or not parent then return end
			if Controllers.Config.PET_BAG_UI and Controllers.Config.PET_BAG_UI.SyncTemplateSizeToGrid == false then
				return
			end

			local gridLayout = parent:FindFirstChildWhichIsA("UIGridLayout")
			if gridLayout then
				item.Size = gridLayout.CellSize
			end

			for _, node in ipairs(item:GetDescendants()) do
				if node:IsA("ImageLabel") or node:IsA("ImageButton") or node:IsA("ViewportFrame") then
					if node.Name == "PetViewport"
						or node.Name == "PetIconViewport"
						or node.Name == "IconViewport"
						or node.Name == "Viewport"
						or node.Name == "SlotImage"
						or node.Name == "Background"
						or node.Name == "Bg"
					then
						node.AnchorPoint = Vector2.new(0.5, 0.5)
						node.Position = UDim2.fromScale(0.5, 0.5)
						node.Size = UDim2.fromScale(1, 1)
					end
				end
			end
		end

		-- 克隆宠物格模板；只打生成标记，具体文字/图片由后续函数填充。
		local function createPetButton(parent)
			local btn = petTemplate:Clone()
			btn:SetAttribute("PetBagGenerated", true)
			btn.Visible = true
			btn.Parent = parent
			syncBagItemSizeToGrid(btn, parent)
			return btn
		end

		-- 克隆出战区空槽；只表达可装备槽位，不参与点击交互。
		local function createEmptyEquipSlot(parent)
			local emptySlot = emptySlotTemplate:Clone()
			emptySlot:SetAttribute("PetBagGenerated", true)
			emptySlot:SetAttribute("PetBagSlotType", "Equipped")
			emptySlot.Visible = true
			emptySlot.Parent = parent
			syncBagItemSizeToGrid(emptySlot, parent)
			return emptySlot
		end

		-- 查找宠物格里的 ViewportFrame；用于直接展示 ReplicatedStorage/Model/Pets 下的宠物模型。
		local function findPetViewport(root)
			for _, name in ipairs({"PetViewport", "PetIconViewport", "IconViewport", "Viewport"}) do
				local node = root:FindFirstChild(name, true)
				if node and node:IsA("ViewportFrame") then
					return node
				end
			end

			return root:FindFirstChildWhichIsA("ViewportFrame", true)
		end

		-- 清理上一次渲染到 ViewportFrame 的模型和相机；保留 Studio 里做好的圆角、描边等 UI 子节点。
		local function clearPetViewport(viewport)
			for _, child in ipairs(viewport:GetChildren()) do
				if child:GetAttribute("PetBagViewportGenerated") == true then
					child:Destroy()
				end
			end
			viewport.CurrentCamera = nil
		end

		-- 让模型在 ViewportFrame 中稳定显示；兼容 Model、MeshPart、Part。
		local function fitPetModelInViewport(viewport, petInstance)
			if not viewport or not petInstance then return false end

			local worldModel = Instance.new("WorldModel")
			worldModel.Name = "PetViewportWorld"
			worldModel:SetAttribute("PetBagViewportGenerated", true)
			worldModel.Parent = viewport

			petInstance.Parent = worldModel

			for _, obj in ipairs(petInstance:GetDescendants()) do
				if obj:IsA("BasePart") then
					obj.Anchored = true
					obj.CanCollide = false
				end
			end
			if petInstance:IsA("BasePart") then
				petInstance.Anchored = true
				petInstance.CanCollide = false
				petInstance.CFrame = CFrame.new(0, 0, 0)
			elseif petInstance:IsA("Model") then
				if not petInstance.PrimaryPart then
					petInstance.PrimaryPart = petInstance:FindFirstChildWhichIsA("BasePart", true)
				end
				petInstance:PivotTo(CFrame.new(0, 0, 0))
			else
				return false
			end

			local boundsCFrame
			local boundsSize
			if petInstance:IsA("Model") then
				boundsCFrame, boundsSize = petInstance:GetBoundingBox()
				petInstance:PivotTo(petInstance:GetPivot() + (-boundsCFrame.Position))
				local yawDegrees = (Controllers.Config.PET_BAG_UI and Controllers.Config.PET_BAG_UI.ViewportYawDegrees) or 180
				petInstance:PivotTo(CFrame.Angles(0, math.rad(yawDegrees), 0) * petInstance:GetPivot())
				boundsCFrame, boundsSize = petInstance:GetBoundingBox()
			elseif petInstance:IsA("BasePart") then
				local yawDegrees = (Controllers.Config.PET_BAG_UI and Controllers.Config.PET_BAG_UI.ViewportYawDegrees) or 180
				petInstance.CFrame = CFrame.Angles(0, math.rad(yawDegrees), 0) * petInstance.CFrame
				boundsCFrame = petInstance.CFrame
				boundsSize = petInstance.Size
			end

			local maxSize = math.max(boundsSize.X, boundsSize.Y, boundsSize.Z, 1)
			local cameraDistance = maxSize * 2.15
			local lookAt = Vector3.new(0, boundsSize.Y * 0.05, 0)

			local camera = Instance.new("Camera")
			camera.Name = "PetViewportCamera"
			camera:SetAttribute("PetBagViewportGenerated", true)
			camera.FieldOfView = 35
			camera.CFrame = CFrame.lookAt(
				Vector3.new(cameraDistance * 0.18, boundsSize.Y * 0.18, cameraDistance),
				lookAt
			)
			camera.Parent = viewport
			viewport.CurrentCamera = camera

			return true
		end

		-- 将宠物模型渲染到背包格子的 ViewportFrame；模型缺失时安静失败，交给文本兜底。
		local function applyPetViewport(btn, petId)
			local viewport = findPetViewport(btn)
			if not viewport then return false end

			clearPetViewport(viewport)
			viewport.BackgroundTransparency = 1

			local modelFolder = ReplicatedStorage:FindFirstChild("Model")
			local petModels = modelFolder and modelFolder:FindFirstChild("Pets")
			local petTemplateModel = petModels and petModels:FindFirstChild(petId)
			if not petTemplateModel then
				viewport.Visible = false
				btn:SetAttribute("PetViewportModelFound", false)
				return false
			end

			local petClone = petTemplateModel:Clone()
			local ok = fitPetModelInViewport(viewport, petClone)
			viewport.Visible = ok
			btn:SetAttribute("PetViewportModelFound", ok)
			btn:SetAttribute("PetViewportModelNameDebug", petTemplateModel.Name)
			if not ok then
				petClone:Destroy()
			end

			return ok
		end

		-- 生成宠物卡展示数据，便于美术把宠物名称、数量、稀有度等拆成独立 TextLabel。
		local function getPetDisplayData(petId, count, statusText)
			local petConfig = Controllers.Config.PETS[petId]
			if not petConfig then
				return {
					Name = petId,
					Count = count or 1,
					CountText = "",
					Rarity = "Unknown",
					Status = statusText or "",
					Attack = "0",
					Description = "",
					FullText = petId,
				}
			end

			local countText = (count and count > 1) and (" x" .. count) or ""
			local rarityText = petConfig.Rarity or "Unknown"
			local description = petConfig.Description or "暂无描述"
			local statusLine = statusText and ("\n" .. statusText) or ""
			local attackText = Controllers.Config.FormatNumber(petConfig.ATK or 0)
			local fullText = string.format(
				"%s%s [%s]%s\nATK:%s\n%s",
				petConfig.Name or petId,
				countText,
				rarityText,
				statusLine,
				attackText,
				description
			)

			return {
				Name = petConfig.Name or petId,
				Count = count or 1,
				CountText = countText,
				Rarity = rarityText,
				Status = statusText or "",
				Attack = attackText,
				Description = description,
				Icon = normalizeImageAssetId(petConfig.Icon, false),
				FullText = fullText,
			}
		end

		-- 给宠物卡填充显示内容；优先写入美术拆好的标签，没有拆分时回退到按钮文本。
		local function applyPetButtonDisplay(btn, petId, count, statusText)
			local display = getPetDisplayData(petId, count, statusText)
			local nameText = findTextNode(btn, {"PetNameText", "NameText", "TitleText"})
			local countLabel = findTextNode(btn, {"CountText", "CountLabel"})
			local rarityText = findTextNode(btn, {"RarityText", "RarityLabel"})
			local statusLabel = findTextNode(btn, {"StatusText", "StateText", "EquippedText"})
			local attackText = findTextNode(btn, {"AttackText", "ATKText", "AtkText"})
			local descText = findTextNode(btn, {"DescriptionText", "DescText", "NoteText"})
			local petIcon = findNamedImageNode(btn, {"PetIcon", "IconImage", "PetImage", "Avatar"})
			local hasSplitLabels = nameText or countLabel or rarityText or statusLabel or attackText or descText

			btn:SetAttribute("PetId", petId)
			btn:SetAttribute("PetCount", display.Count)
			btn:SetAttribute("PetRarity", display.Rarity)
			btn:SetAttribute("PetState", statusText and "Equipped" or "Standby")
			btn:SetAttribute("PetIconAssetDebug", display.Icon or "")

			if nameText then nameText.Text = display.Name end
			if countLabel then
				countLabel.Text = display.CountText
				countLabel.Visible = display.CountText ~= ""
			end
			if rarityText then rarityText.Text = display.Rarity end
			if statusLabel then
				statusLabel.Text = display.Status
				statusLabel.Visible = display.Status ~= ""
			end
			if attackText then attackText.Text = "ATK:" .. display.Attack end
			if descText then descText.Text = display.Description end
			local viewportRendered = applyPetViewport(btn, petId)
			if petIcon then
				petIcon.Image = viewportRendered and "" or (display.Icon or "")
				petIcon.Visible = not viewportRendered and display.Icon ~= nil
			end

			if btn:IsA("TextButton") then
				btn.Text = hasSplitLabels and "" or display.FullText
				if not hasSplitLabels then
					btn.TextWrapped = true
					btn.TextScaled = true
				end
			end
		end

		local function refreshBag()
			clearGeneratedBagItems(equippedContainer)
			clearGeneratedBagItems(standbyContainer)
			
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
				
				local btn = createPetButton(equippedContainer)
				
				applyPetButtonDisplay(btn, equipped, 1, "出战中")
				
				-- 点击出战区的宠物：向服务器发送空字符串进行【卸下】
				btn.Activated:Connect(function()
					local remotes = game:GetService("ReplicatedStorage"):WaitForChild("Remotes")
					remotes:WaitForChild("EquipPet"):FireServer("")
				end)
			end

			-- 出战区显示“当前可装备宠物数”个槽位；未装备的位置用空槽补齐，不额外 +1。
			for _ = equippedCount + 1, MAX_EQUIP_SLOTS do
				createEmptyEquipSlot(equippedContainer)
			end

			-- ==========================================
			-- 2. 渲染【待机区】
			-- ==========================================
			local standbyPetIds = getSortedPetIds(petCounts)
			for _, petId in ipairs(standbyPetIds) do
				local count = petCounts[petId]
				if count > 0 then -- 如果还有剩余宠物在待机
					local petConfig = Controllers.Config.PETS[petId]
					if petConfig then
						local btn = createPetButton(standbyContainer)
						
						applyPetButtonDisplay(btn, petId, count)
						
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
			current3DModel = nil
			spinConnection = nil
		end

		-- 将抽宠展示资源放进 ViewportFrame；兼容 Model、MeshPart、Part，避免 MeshPart 调 Model 专用 API 报错。
		local function placeViewportModel(instance, targetCFrame)
			if not instance then return false end
			targetCFrame = targetCFrame or CFrame.new(0, 0, 0)

			if instance:IsA("Model") then
				local primary = instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
				if primary and not instance.PrimaryPart then
					instance.PrimaryPart = primary
				end
				instance:PivotTo(targetCFrame)
				return true
			end

			if instance:IsA("BasePart") then
				instance.CFrame = targetCFrame
				return true
			end

			return false
		end

		-- 结束抽宠展示并恢复交互状态；任何异常路径都走这里，避免界面卡住。
		local function closeHatchScreen()
			hatchScreen.Visible = false
			isHatching = false
			clearViewport()
		end

		-- 获取可以承载 ProximityPrompt 的部件；宠物蛋如果是 Model，就挂到其中一个 BasePart 上。
		local function getPromptParent(target)
			if target:IsA("BasePart") then
				return target
			end
			return target:FindFirstChildWhichIsA("BasePart", true)
		end

		-- 宠物蛋交互逻辑；Prompt 可能因 Streaming/重生时序重新出现，所以绑定函数要可重复安全调用。
		local function handlePetEggTriggered(triggeringPlayer)
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
			if not resultPetId then
				warn("[UIController] 宠物抽取失败，未收到有效宠物 ID。")
				closeHatchScreen()
				return
			end
			
			-- 挂载 3D 蛋模型
			local eggTemplate = petModels:FindFirstChild("Egg")
			if eggTemplate then
				current3DModel = eggTemplate:Clone()
				if placeViewportModel(current3DModel, CFrame.new(0, 0, 0)) then
					current3DModel.Parent = viewport
					camera.CFrame = CFrame.lookAt(Vector3.new(0, 2, -6), Vector3.new(0, 0, 0))
				else
					current3DModel:Destroy()
					current3DModel = nil
				end
			end
			
			hatchScreen.Visible = true
			clickCount = 0
			tipText.Text = "疯狂点击蛋壳使其破裂！"
			tipText.TextColor3 = Color3.new(1,1,1)
			
			local clickConn
			clickConn = clickArea.Activated:Connect(function()
				local ok, err = pcall(function()
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
							if placeViewportModel(current3DModel, CFrame.new(0, 0, 0)) then
								current3DModel.Parent = viewport
							else
								current3DModel:Destroy()
								current3DModel = nil
							end
							
							tipText.Text = string.format("恭喜获得 %s (%s)", petData.Name, petData.Rarity)
							tipText.TextColor3 = petData.Color
							
							-- 3. 呼叫 VFX 模块接管匀速自转动画，并把循环指针存起来以便清理
							if current3DModel then
								spinConnection = Controllers.VFX.StartPetSpinVFX(current3DModel)
							end
						end
					end
					
					task.wait(3) 
					closeHatchScreen()
				end
				end)

				if not ok then
					warn("[UIController] 抽宠展示流程异常，已关闭抽取界面:", err)
					if clickConn then clickConn:Disconnect() end
					closeHatchScreen()
				end
			end)
		end

		-- 持续补绑宠物蛋 Prompt；目标重新加载或 Prompt 被清掉时会自动恢复。
		local function bindPetEggPrompt(target)
			if not target then return end
			local promptParent = getPromptParent(target)
			if not promptParent then return end

			local prompt = promptParent:FindFirstChildOfClass("ProximityPrompt")
			if not prompt then
				prompt = Instance.new("ProximityPrompt")
				prompt.Parent = promptParent
			end

			prompt.ObjectText = "宠物蛋"
			prompt.ActionText = "花费 " .. Controllers.Config.FormatNumber(Controllers.Config.PET_GACHA_COST) .. " 抽宠"
			prompt.HoldDuration = 0.2
			prompt.RequiresLineOfSight = false
			prompt.MaxActivationDistance = 12
			prompt.Enabled = true

			if prompt:GetAttribute("ClientPetEggPromptBound") then return end
			prompt:SetAttribute("ClientPetEggPromptBound", true)
			prompt.Triggered:Connect(handlePetEggTriggered)
		end

		Workspace.DescendantAdded:Connect(function(descendant)
			if descendant.Name == "PetEgg" then
				task.defer(bindPetEggPrompt, descendant)
			end
		end)

		task.spawn(function()
			while true do
				local eggTarget = Workspace:FindFirstChild("PetEgg", true)
				if eggTarget then
					bindPetEggPrompt(eggTarget)
				end
				task.wait(2)
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
			applyExitButtonHoverScale(exitButton)
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
