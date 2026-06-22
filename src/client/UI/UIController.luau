-- src/client/UI/UIController.luau
-- 屏幕 2D UI 与 角色常驻 3D 头顶 UI 控制器
local UIController = {}

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local MarketplaceService = game:GetService("MarketplaceService")
local SocialService = game:GetService("SocialService")
local GroupService = game:GetService("GroupService")
local player = Players.LocalPlayer
local HttpService = game:GetService("HttpService")

local function reportAnalyticsEvent(eventName, fields)
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local event = remotes and remotes:FindFirstChild("ReportAnalyticsEvent")
	if event and event:IsA("RemoteEvent") then
		event:FireServer(eventName, fields or {})
	end
end

local Controllers -- 全局依赖指针

-- 判断当前设备是否按纯手机端处理；PC 上接了触屏时仍保留桌面 UI 尺寸。
local function isMobileOnlyDevice()
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

-- 底部大厅按钮固定放在 MainUI.MainUI_1 下。
local function getMainButtonRoot(mainUI)
	if not mainUI then return nil end
	return mainUI:FindFirstChild("MainUI_1")
end

local function getMainButtonRoots(mainUI)
	if not mainUI then return {} end

	local roots = {}
	local seen = {}
	for _, name in ipairs({ "MainUI_1", "MainUI_2" }) do
		local root = mainUI:FindFirstChild(name)
		if root and root:IsA("GuiObject") and not seen[root] then
			seen[root] = true
			table.insert(roots, root)
		end
	end

	return roots
end

-- 查找 Studio 模板里可能存在的文字节点，兼容不同命名，避免代码强制重建 UI。
local function updateMainButtonRootVisibility(mainUI)
	for _, buttonRoot in ipairs(getMainButtonRoots(mainUI)) do
		local hiddenByPanel = buttonRoot:GetAttribute("HiddenByShopPanel") == true
			or buttonRoot:GetAttribute("HiddenByHatchPanel") == true
		buttonRoot.Visible = player:GetAttribute("InCombat") ~= true and not hiddenByPanel
	end
end

local function setMainButtonRootHiddenByPanel(mainUI, panelKey, isHidden)
	for _, buttonRoot in ipairs(getMainButtonRoots(mainUI)) do
		buttonRoot:SetAttribute("HiddenBy" .. panelKey .. "Panel", isHidden == true)
	end

	updateMainButtonRootVisibility(mainUI)
end

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

-- 覆盖 Studio 模板中常见的静态文本；只改 Text 内容，不改美术布局和图片。
local function applyEnglishStaticTexts(mainUI)
	if not mainUI then return end

	local textByName = {
		PetBagTitle = "Pet Inventory",
		PetInventoryTitle = "Pet Inventory",
		EquippedTitle = "Equipped Pets",
		EquippedPetsTitle = "Equipped Pets",
		StandbyTitle = "Standby Pets",
		StandbyPetsTitle = "Standby Pets",
		ShopTitle = "Shop",
		HatchTitle = "Pet Egg",
		TipText = "Tap quickly to crack the egg!",
	}

	for _, node in ipairs(mainUI:GetDescendants()) do
		local text = textByName[node.Name]
		if text and (node:IsA("TextLabel") or node:IsA("TextButton")) then
			node.Text = text
		end
	end
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

local bossProgressState = {
	AvatarUserId = nil,
	AvatarImage = nil,
	AvatarLoading = false,
	LayoutRetryScheduled = false,
	LastIconKey = nil,
	MissingModelWarned = {},
	MissingUiWarned = false,
}

local function findBossProgressBar(mainUI)
	if not mainUI then return nil end
	local progressBar = mainUI:FindFirstChild("BossProgressBar", true)
	if progressBar and progressBar:IsA("GuiObject") then
		return progressBar
	end
	return nil
end

local function findBossProgressViewport(root)
	if not root then return nil end
	local viewport = root:FindFirstChild("PetViewport", true)
	if viewport and viewport:IsA("ViewportFrame") then
		return viewport
	end

	return root:FindFirstChildWhichIsA("ViewportFrame", true)
end

local function clearBossProgressViewport(viewport)
	if not viewport then return end
	for _, child in ipairs(viewport:GetChildren()) do
		if child:GetAttribute("BossProgressGenerated") == true then
			child:Destroy()
		end
	end
	viewport.CurrentCamera = nil
end

local function getBossProgressEnemyTemplate(modelName)
	local modelFolder = ReplicatedStorage:FindFirstChild("Model")
	local enemiesFolder = modelFolder and modelFolder:FindFirstChild("Enemies")
	if not enemiesFolder then
		return nil, modelName
	end

	local template = enemiesFolder:FindFirstChild(modelName)
	if template then
		return template, modelName
	end

	local fallbackName = (Controllers.Config.ENEMY_MODELS and Controllers.Config.ENEMY_MODELS.Boss) or "Boss"
	if modelName ~= fallbackName and not bossProgressState.MissingModelWarned[modelName] then
		bossProgressState.MissingModelWarned[modelName] = true
		warn("[UIController][BossProgress] Boss model missing:", modelName, "fallback:", fallbackName)
	end

	return enemiesFolder:FindFirstChild(fallbackName), fallbackName
end

local function getBossProgressOverride(modelName)
	local config = Controllers.Config.BOSS_PROGRESS or {}
	local overrides = config.ViewportModelOverrides
	if type(overrides) ~= "table" then
		return {}
	end

	local override = overrides[modelName]
	if type(override) ~= "table" then
		return {}
	end

	return override
end

local function getBossProgressNumber(override, configKey, fallback)
	if type(override) == "table" and override[configKey] ~= nil then
		return tonumber(override[configKey]) or fallback
	end

	local config = Controllers.Config.BOSS_PROGRESS or {}
	if config[configKey] ~= nil then
		return tonumber(config[configKey]) or fallback
	end

	return fallback
end

local function renderBossProgressModel(viewport, template, modelName)
	clearBossProgressViewport(viewport)
	if not viewport or not template then
		return false
	end

	local clone = template:Clone()
	local worldModel = Instance.new("WorldModel")
	worldModel.Name = "BossProgressWorld"
	worldModel:SetAttribute("BossProgressGenerated", true)
	worldModel.Parent = viewport
	clone.Parent = worldModel

	for _, obj in ipairs(clone:GetDescendants()) do
		if obj:IsA("BasePart") then
			obj.Anchored = true
			obj.CanCollide = false
			obj.CanTouch = false
			obj.CanQuery = false
		end
	end

	local boundsCFrame
	local boundsSize
	if clone:IsA("Model") then
		if not clone.PrimaryPart then
			clone.PrimaryPart = clone:FindFirstChildWhichIsA("BasePart", true)
		end
		if not clone.PrimaryPart then
			worldModel:Destroy()
			return false
		end

		local originalPivot = clone:GetPivot()
		clone:PivotTo(CFrame.new(0, 0, 0) * originalPivot.Rotation)
		boundsCFrame, boundsSize = clone:GetBoundingBox()
		clone:PivotTo(clone:GetPivot() + (-boundsCFrame.Position))
		boundsCFrame, boundsSize = clone:GetBoundingBox()
	elseif clone:IsA("BasePart") then
		clone.Anchored = true
		clone.CanCollide = false
		clone.CanTouch = false
		clone.CanQuery = false
		clone.CFrame = CFrame.new(0, 0, 0) * clone.CFrame.Rotation
		boundsCFrame = clone.CFrame
		boundsSize = clone.Size
	else
		worldModel:Destroy()
		return false
	end

	local override = getBossProgressOverride(modelName)
	local pitchDegrees = getBossProgressNumber(override, "ViewportPitchDegrees", 0)
	local yawDegrees = getBossProgressNumber(override, "ViewportYawDegrees", 0)
	local rollDegrees = getBossProgressNumber(override, "ViewportRollDegrees", 0)
	local previewRotation = CFrame.Angles(math.rad(pitchDegrees), math.rad(yawDegrees), math.rad(rollDegrees))
	if clone:IsA("Model") then
		clone:PivotTo(previewRotation * clone:GetPivot())
		boundsCFrame, boundsSize = clone:GetBoundingBox()
		clone:PivotTo(clone:GetPivot() + (-boundsCFrame.Position))
		boundsCFrame, boundsSize = clone:GetBoundingBox()
	elseif clone:IsA("BasePart") then
		clone.CFrame = previewRotation * clone.CFrame
		clone.CFrame = clone.CFrame + (-clone.Position)
		boundsCFrame = clone.CFrame
		boundsSize = clone.Size
	end

	local offset = Vector3.new(
		tonumber(override.OffsetX) or 0,
		tonumber(override.OffsetY) or 0,
		tonumber(override.OffsetZ) or 0
	)
	if offset.Magnitude > 0 then
		if clone:IsA("Model") then
			clone:PivotTo(clone:GetPivot() + offset)
			boundsCFrame, boundsSize = clone:GetBoundingBox()
		elseif clone:IsA("BasePart") then
			clone.CFrame = clone.CFrame + offset
			boundsCFrame = clone.CFrame
			boundsSize = clone.Size
		end
	end

	local maxSize = math.max(boundsSize.X, boundsSize.Y, boundsSize.Z, 1)
	local cameraDistanceScale = math.max(0.1, getBossProgressNumber(override, "ViewportCameraDistanceScale", 1.35))
	local cameraDistance = maxSize * cameraDistanceScale
	local lookAt = Vector3.new(0, boundsSize.Y * getBossProgressNumber(override, "ViewportLookAtHeightScale", 0.05), 0)
	local camera = Instance.new("Camera")
	camera.Name = "BossProgressCamera"
	camera:SetAttribute("BossProgressGenerated", true)
	camera.FieldOfView = math.clamp(getBossProgressNumber(override, "ViewportFieldOfView", 30), 1, 120)
	camera.CFrame = CFrame.lookAt(
		Vector3.new(
			cameraDistance * getBossProgressNumber(override, "ViewportCameraXScale", 0.12),
			boundsSize.Y * getBossProgressNumber(override, "ViewportCameraHeightScale", 0.08),
			cameraDistance
		),
		lookAt
	)
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	viewport.Visible = true

	return true
end

local function getBossProgressSlots(progressBar, strip, visibleSlots)
	local slots = {}
	for slotIndex = 1, visibleSlots do
		local slot = strip:FindFirstChild("Boss-" .. tostring(slotIndex)) or progressBar:FindFirstChild("Boss-" .. tostring(slotIndex), true)
		if slot and slot:IsA("GuiObject") then
			table.insert(slots, {
				Index = slotIndex,
				Slot = slot,
				CenterY = slot.AbsolutePosition.Y + slot.AbsoluteSize.Y * 0.5,
			})
		end
	end

	table.sort(slots, function(a, b)
		if math.abs(a.CenterY - b.CenterY) > 0.5 then
			return a.CenterY > b.CenterY
		end

		return a.Index < b.Index
	end)

	return slots
end

local function isBossProgressLayoutReady(slots)
	if #slots <= 1 then
		return true
	end

	return math.abs(slots[1].CenterY - slots[#slots].CenterY) > 0.5
end

local function updateBossProgressIcons(progressBar, visibleSlots, currentStage)
	local strip = progressBar:FindFirstChild("Strip", true)
	if not strip then
		return nil, true
	end

	local iconKeyParts = {}
	local slots = getBossProgressSlots(progressBar, strip, visibleSlots)
	if not isBossProgressLayoutReady(slots) then
		return strip, false
	end

	local cycleStart = Controllers.Config.GetBossProgressCycleStart and Controllers.Config.GetBossProgressCycleStart(currentStage) or 1
	for visualIndex, slotInfo in ipairs(slots) do
		local slot = slotInfo.Slot
		local bossIndex = cycleStart + visualIndex - 1
		local modelName = Controllers.Config.GetBossModelName and Controllers.Config.GetBossModelName(bossIndex) or "Boss"
		table.insert(iconKeyParts, tostring(modelName))

		local viewport = findBossProgressViewport(slot)
		if viewport and viewport:GetAttribute("BossProgressModelName") ~= modelName then
			local template, resolvedModelName = getBossProgressEnemyTemplate(modelName)
			local ok = renderBossProgressModel(viewport, template, resolvedModelName or modelName)
			viewport:SetAttribute("BossProgressModelName", modelName)
			viewport:SetAttribute("BossProgressResolvedModelName", resolvedModelName)
			viewport.Visible = ok
		end
	end

	bossProgressState.LastIconKey = table.concat(iconKeyParts, "|")
	return strip, true
end

local function updateBossProgressAvatar(playerIcon)
	if not playerIcon or not (playerIcon:IsA("ImageLabel") or playerIcon:IsA("ImageButton")) then
		return
	end

	if bossProgressState.AvatarUserId == player.UserId and bossProgressState.AvatarImage then
		playerIcon.Image = bossProgressState.AvatarImage
		return
	end

	if bossProgressState.AvatarLoading then
		return
	end

	bossProgressState.AvatarLoading = true
	task.spawn(function()
		local ok, image = pcall(function()
			return Players:GetUserThumbnailAsync(player.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
		end)

		bossProgressState.AvatarLoading = false
		if ok and image then
			bossProgressState.AvatarUserId = player.UserId
			bossProgressState.AvatarImage = image
			if playerIcon and playerIcon.Parent then
				playerIcon.Image = image
			end
		end
	end)
end

local function updateBossProgressPlayer(progressBar, strip, ratio)
	local playerFrame = progressBar:FindFirstChild("Player", true)
	if not playerFrame or not playerFrame:IsA("GuiObject") then
		return
	end

	local playerIcon = playerFrame:IsA("ImageLabel") and playerFrame or playerFrame:FindFirstChild("ImageLabel", true)
	if playerIcon then
		updateBossProgressAvatar(playerIcon)
	end

	local visibleSlots = Controllers.Config.GetBossProgressVisibleSlots and Controllers.Config.GetBossProgressVisibleSlots() or 5
	local slots = strip and getBossProgressSlots(progressBar, strip, visibleSlots) or {}
	local bottomSlotInfo = slots[1]
	local topSlotInfo = slots[#slots]
	if bottomSlotInfo and topSlotInfo and progressBar.AbsoluteSize.Y > 0 then
		local bottomY = bottomSlotInfo.CenterY
		local topY = topSlotInfo.CenterY
		local bossSegmentCount = math.max(#slots - 1, 1)
		local visualRatio = math.clamp(ratio, -1 / bossSegmentCount, 1)
		local targetY = bottomY + (topY - bottomY) * visualRatio
		local relativeY = targetY - progressBar.AbsolutePosition.Y - playerFrame.AbsoluteSize.Y * 0.5
		playerFrame.Position = UDim2.new(playerFrame.Position.X.Scale, playerFrame.Position.X.Offset, 0, math.floor(relativeY + 0.5))
	else
		local visibleSlots = Controllers.Config.GetBossProgressVisibleSlots and Controllers.Config.GetBossProgressVisibleSlots() or 5
		local bossSegmentCount = math.max(visibleSlots - 1, 1)
		local visualRatio = math.clamp(ratio, -1 / bossSegmentCount, 1)
		local fallbackScale = 1 - visualRatio
		playerFrame.Position = UDim2.new(playerFrame.Position.X.Scale, playerFrame.Position.X.Offset, math.clamp(fallbackScale, 0, 1), playerFrame.Position.Y.Offset)
	end
end

local function updateBossProgressBar(mainUI, inCombat, currentStage, currentDistance)
	local progressBar = findBossProgressBar(mainUI)
	if not progressBar then
		return
	end

	local config = Controllers.Config.BOSS_PROGRESS or {}
	local enabled = config.Enabled ~= false
	progressBar.Visible = enabled and inCombat
	if not progressBar.Visible then
		return
	end

	local visibleSlots = Controllers.Config.GetBossProgressVisibleSlots and Controllers.Config.GetBossProgressVisibleSlots() or 5
	local strip, layoutReady = updateBossProgressIcons(progressBar, visibleSlots, currentStage)
	if not strip then
		if not bossProgressState.MissingUiWarned then
			bossProgressState.MissingUiWarned = true
			warn("[UIController][BossProgress] Missing BossProgressBar.Strip.")
		end
		return
	end
	if layoutReady == false then
		if not bossProgressState.LayoutRetryScheduled then
			bossProgressState.LayoutRetryScheduled = true
			task.delay(0.1, function()
				bossProgressState.LayoutRetryScheduled = false
				local playerGui = player:FindFirstChild("PlayerGui")
				local latestMainUI = playerGui and playerGui:FindFirstChild("MainUI")
				if latestMainUI then
					updateBossProgressBar(
						latestMainUI,
						player:GetAttribute("InCombat") == true,
						player:GetAttribute("CurrentStage") or 1,
						player:GetAttribute("CurrentDistance") or 0
					)
				end
			end)
		end
		return
	end

	local ratio = Controllers.Config.GetBossProgressRatio and Controllers.Config.GetBossProgressRatio(currentStage, currentDistance) or 0
	updateBossProgressPlayer(progressBar, strip, ratio)
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
		if mainUI then
			applyEnglishStaticTexts(mainUI)
		end

		-- 获取当前最新数值
		local coins = player:GetAttribute("Coins") or 0
		local hp = player:GetAttribute("HP") or 0
      	local maxHp = player:GetAttribute("MaxHP") or Controllers.Config.BASE_HP
		local lvl = player:GetAttribute("Level") or 1
		local exp = player:GetAttribute("EXP") or 0
		local requiredExp = player:GetAttribute("RequiredEXP") or Controllers.Config.GetRequiredExp(lvl)
		local inCombat = player:GetAttribute("InCombat") == true
		local isCombatPaused = player:GetAttribute("IsLevelingUp") == true
			or player:GetAttribute("IsRevivePending") == true
			or player:GetAttribute("IsQuickHealPurchasing") == true
      	local currentStage = player:GetAttribute("CurrentStage") or 1
		local currentDistance = player:GetAttribute("CurrentDistance") or 0
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
			local coinBonusUI = mainUI:FindFirstChild("CoinBonusUI", true)
			if coinBonusUI and coinBonusUI:IsA("GuiObject") then
				coinBonusUI.Visible = true
				local bonusText = findTextNode(coinBonusUI, { "TextLabel", "BonusText", "CoinBonusText" })
					or coinBonusUI:FindFirstChildWhichIsA("TextLabel", true)
					or coinBonusUI:FindFirstChildWhichIsA("TextButton", true)
				if bonusText then
					local rebirthBonus = math.max(0, tonumber(player:GetAttribute("CoinGainBonus")) or 0)
					local runInviteBonus = math.max(0, tonumber(player:GetAttribute("RunInviteCoinBonus")) or 0)
					local pendingInviteBonus = math.max(0, tonumber(player:GetAttribute("PendingInviteCoinBonus")) or 0)
					local inviteBonus = inCombat and runInviteBonus or math.max(runInviteBonus, pendingInviteBonus)
					local multiplier = 1 + rebirthBonus + inviteBonus
					local multiplierText = string.format("%.1f", multiplier)
					multiplierText = string.gsub(multiplierText, "%.0$", "")
					bonusText.Text = "Coin Bonus: x" .. multiplierText
				end
			end

			local exitButton = mainUI:FindFirstChild("ExitButton")
			if exitButton and exitButton:IsA("GuiButton") then
				applyExitButtonHoverScale(exitButton)
				exitButton.Visible = inCombat and not isCombatPaused
			end

			-- 手机端滑动控制提示层：UI 由 Studio 设计，代码只负责按设备和战斗状态控制显隐。
			local mobileControls = mainUI:FindFirstChild("MobileControls", true)
			if mobileControls and mobileControls:IsA("GuiObject") then
				local useNativeJoystick = Controllers.Config.MOBILE_USE_NATIVE_JOYSTICK ~= false
				mobileControls.Visible = (not useNativeJoystick) and isMobileOnlyDevice() and inCombat and not isCombatPaused
			end

			-- 大厅底部按钮整体容器：正式开始游戏后隐藏 MainUI_1，回大厅后显示。
			updateMainButtonRootVisibility(mainUI)
			
			-- 2. 如果玩家开着背包直接冲进了跑道门，强制关掉面板
			local petBagPanel = mainUI:FindFirstChild("PetBagPanel")
			if petBagPanel and inCombat then
				petBagPanel.Visible = false
			end

			local achievePanel = mainUI:FindFirstChild("Achieve")
			if achievePanel and inCombat then
				achievePanel.Visible = false
			end

			-- 关卡 HUD 使用 Studio 里的图片容器；代码只控制显隐并填充关卡文本。
			local rebirthPanel = mainUI:FindFirstChild("RebirthPanel")
			if rebirthPanel and inCombat then
				rebirthPanel.Visible = false
			end

			local starterPackPanel = mainUI:FindFirstChild("StarterPackPanel")
			if starterPackPanel and inCombat then
				starterPackPanel.Visible = false
			end

			local starterPackRewardPanel = mainUI:FindFirstChild("StarterPackRewardPanel")
			if starterPackRewardPanel and inCombat then
				starterPackRewardPanel.Visible = false
			end

			local freeRewardPanel = mainUI:FindFirstChild("FreeRewardPanel")
			if freeRewardPanel and inCombat then
				freeRewardPanel.Visible = false
			end

			local stageHud = findStageHud(mainUI)
			if stageHud then
				local showStage = inCombat and not isCombatPaused
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
			updateBossProgressBar(mainUI, inCombat, currentStage, currentDistance)

			local combatHub = mainUI:FindFirstChild("CombatHub")
			if combatHub and combatHub:IsA("Frame") then
				-- 只有进入战斗且不在升级选择时，显示底部状态条
				combatHub.Visible = inCombat and not isCombatPaused
				
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

		-- 2. 旧版本地头顶 UI 已改由服务端统一创建；这里关闭本地副本，避免自己看到两套文字。
		if statsUI and statsUI:IsA("BillboardGui") then
			statsUI.Enabled = false
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
				amountText = "All +" .. tostring(buff.Amount) .. "%"
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
				CategoryName = "Player Stats",
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
					if player:GetAttribute("IsRevivePending") then return end
					
					local attr = card:GetAttribute("BuffAttr")
					local amount = card:GetAttribute("BuffAmount")
					local buffId = card:GetAttribute("BuffId") or attr
					local buffMaxLevel = card:GetAttribute("BuffMaxLevel")
					if not attr then return end
					local cardIds = {}
					local cardAttrs = {}
					for _, currentCard in ipairs(cards) do
						if currentCard and currentCard:IsA("GuiButton") then
							table.insert(cardIds, tostring(currentCard:GetAttribute("BuffId") or currentCard:GetAttribute("BuffAttr") or ""))
							table.insert(cardAttrs, tostring(currentCard:GetAttribute("BuffAttr") or ""))
						end
					end
					reportAnalyticsEvent("level_up_card_selected", {
						level = player:GetAttribute("Level") or 1,
						selected_buff_id = tostring(buffId),
						selected_attr = tostring(attr),
						selected_amount = tonumber(amount) or 0,
						card_ids = cardIds,
						card_attrs = cardAttrs,
						reward_mode = player:GetAttribute("LevelUpRewardMode") or "Normal",
					})
					if Controllers.Sound then
						Controllers.Sound.PlaySelect()
					end

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
				local shouldShowLevelUp = player:GetAttribute("IsRevivePending") ~= true
				levelUpPanel.Visible = shouldShowLevelUp
				if shouldShowLevelUp and Controllers.Sound then
					Controllers.Sound.PlayUpgrade()
				end
				
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

				local shownCardIds = {}
				local shownCardAttrs = {}
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
						table.insert(shownCardIds, tostring(getBuffId(buff)))
						table.insert(shownCardAttrs, tostring(buff.Attr))
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
				reportAnalyticsEvent("level_up_cards_shown", {
					level = player:GetAttribute("Level") or 1,
					reward_mode = rewardMode,
					card_ids = shownCardIds,
					card_attrs = shownCardAttrs,
				})
			else
				levelUpPanel.Visible = false
				player:SetAttribute("LevelUpRewardMode", "Normal")
			end
		end)

		player:GetAttributeChangedSignal("IsRevivePending"):Connect(function()
			if player:GetAttribute("IsRevivePending") then
				levelUpPanel.Visible = false
			elseif player:GetAttribute("IsLevelingUp") then
				levelUpPanel.Visible = true
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
		local shopConfig = Config.SHOP_UI or {}
		local petBagConfig = Config.PET_BAG_UI or {}
		local shopBlurTween = nil
		local shopCameraTween = nil
		local shopSavedFOV = nil
		local isApplyingShopVisible = false
		local shopOpenClock = nil
		
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

		-- 获取或创建商店专用毛玻璃；作为本地后处理，只模糊世界背景，不模糊商店 UI。
		local function showShopNotice(text, seconds)
			local noticeUI = mainUI:FindFirstChild("Notice_UI", true)
			local noticeButton = noticeUI and noticeUI:FindFirstChild("Notice_button", true)
			if noticeButton and (noticeButton:IsA("TextLabel") or noticeButton:IsA("TextButton")) then
				noticeButton.Text = tostring(text or "")
			end
			if noticeUI and noticeUI:IsA("GuiObject") then
				noticeUI.Visible = true
				task.delay(seconds or 3, function()
					if noticeUI then
						noticeUI.Visible = false
					end
				end)
			else
				warn("[UIController][Shop] Notice_UI missing. Notice:", text)
			end
		end

		local function getShopBlur()
			local blur = Lighting:FindFirstChild("ShopBlur")
			if blur and not blur:IsA("BlurEffect") then
				blur = nil
			end

			if not blur then
				blur = Instance.new("BlurEffect")
				blur.Name = "ShopBlur"
				blur.Size = 0
				blur.Parent = Lighting
			end

			return blur
		end

		-- 播放商店打开/关闭时的背景毛玻璃效果。
		local function tweenShopBlur(isOpen)
			local blur = getShopBlur()
			if shopBlurTween then
				shopBlurTween:Cancel()
				shopBlurTween = nil
			end

			local targetSize = isOpen and (shopConfig.OpenBlurSize or petBagConfig.OpenBlurSize or 14) or 0
			local tweenTime = shopConfig.OpenBlurTweenTime or petBagConfig.OpenBlurTweenTime or 0.18
			shopBlurTween = TweenService:Create(
				blur,
				TweenInfo.new(tweenTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Size = targetSize }
			)
			shopBlurTween:Play()
		end

		-- 商店打开时调整 FOV，关闭时恢复；只改 FieldOfView，不接管相机模式。
		local function tweenShopCamera(isOpen)
			local currentCamera = Workspace.CurrentCamera
			if not currentCamera then return end

			if shopCameraTween then
				shopCameraTween:Cancel()
				shopCameraTween = nil
			end

			if isOpen then
				if not shopSavedFOV then
					shopSavedFOV = currentCamera.FieldOfView
				end
			elseif not shopSavedFOV then
				return
			end

			local targetFOV = isOpen and (shopConfig.OpenCameraFOV or petBagConfig.OpenCameraFOV or 58) or shopSavedFOV
			local tweenTime = shopConfig.OpenCameraTweenTime or petBagConfig.OpenCameraTweenTime or 0.2
			shopCameraTween = TweenService:Create(
				currentCamera,
				TweenInfo.new(tweenTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ FieldOfView = targetFOV }
			)
			shopCameraTween:Play()

			if not isOpen then
				local savedTween = shopCameraTween
				task.delay(tweenTime, function()
					if shopCameraTween == savedTween then
						shopSavedFOV = nil
					end
				end)
			end
		end

		-- 给商店按钮/卡片添加悬浮缩放；只添加 UIScale，不覆盖美术做好的图片和布局。
		local function applyShopHoverScale(guiObject, attrName, scaleName, targetScale)
			if not guiObject or not guiObject:IsA("GuiObject") then return end

			local existingScale = guiObject:FindFirstChild(scaleName)
			if existingScale and not existingScale:IsA("UIScale") then
				existingScale = nil
			end
			if not existingScale then
				for _, child in ipairs(guiObject:GetChildren()) do
					if child:IsA("UIScale") then
						existingScale = child
						break
					end
				end
			end
			if guiObject:GetAttribute(attrName) and existingScale and existingScale:IsA("UIScale") then return end
			guiObject:SetAttribute(attrName, true)

			local hoverScale = existingScale
			if not hoverScale then
				hoverScale = Instance.new("UIScale")
				hoverScale.Name = scaleName
				hoverScale.Parent = guiObject
			end
			guiObject:SetAttribute("ShopHoverScaleNameDebug", hoverScale.Name)
			guiObject:SetAttribute("ShopHoverScaleParentDebug", hoverScale.Parent and hoverScale.Parent:GetFullName() or "")

			local normalScale = hoverScale.Scale
			local hoverTargetScale = normalScale * targetScale
			local tweenInfo = TweenInfo.new(
				shopConfig.HoverTweenTime or petBagConfig.HoverTweenTime or 0.12,
				Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out
			)

			local function playScaleTween(scale)
				TweenService:Create(hoverScale, tweenInfo, { Scale = scale }):Play()
			end

			if attrName == "ShopCardHoverBoundV2" then
				local isHovered = false
				local connection
				connection = RunService.RenderStepped:Connect(function()
					if not guiObject.Parent then
						connection:Disconnect()
						return
					end

					local inset = GuiService:GetGuiInset()
					local mousePos = UserInputService:GetMouseLocation() - inset
					local pos = guiObject.AbsolutePosition
					local size = guiObject.AbsoluteSize
					local inside = mousePos.X >= pos.X
						and mousePos.X <= pos.X + size.X
						and mousePos.Y >= pos.Y
						and mousePos.Y <= pos.Y + size.Y
					guiObject:SetAttribute(
						"ShopHoverBoundsDebug",
						string.format(
							"inside=%s mouse=(%.0f,%.0f) pos=(%.0f,%.0f) size=(%.0f,%.0f)",
							tostring(inside),
							mousePos.X,
							mousePos.Y,
							pos.X,
							pos.Y,
							size.X,
							size.Y
						)
					)

					if inside == isHovered then
						return
					end

					isHovered = inside
					playScaleTween(isHovered and hoverTargetScale or normalScale)
				end)
				return
			end

			guiObject.MouseEnter:Connect(function()
				playScaleTween(hoverTargetScale)
			end)

			guiObject.MouseLeave:Connect(function()
				playScaleTween(normalScale)
			end)

			if guiObject:IsA("GuiButton") then
				guiObject.Activated:Connect(function()
					playScaleTween(normalScale)
				end)
			end
		end

		local function bindShopCardInteraction(card, talentId)
			if not card or not card:IsA("GuiButton") then
				warn("[UIController][Shop] Shop item root must be a GuiButton/ImageButton for click binding:", card and card:GetFullName())
				return
			end

			card:SetAttribute("TalentId", talentId)
			applyShopHoverScale(
				card,
				"ShopCardHoverBoundV2",
				"ShopCardHoverScale",
				shopConfig.CardHoverScale or petBagConfig.OpenButtonHoverScale or 1.06
			)

			if card:GetAttribute("ShopCardPurchaseBound") then
				return
			end
			card:SetAttribute("ShopCardPurchaseBound", true)

			card.Activated:Connect(function()
				local currentTalentId = card:GetAttribute("TalentId") or talentId
				local currentCost = tonumber(card:GetAttribute("TalentCost")) or 0
				local currentCoins = math.max(0, math.floor(tonumber(player:GetAttribute("Coins")) or 0))
				if currentCost < 0 then
					showShopNotice("Already max level.")
					return
				end
				if currentCost > currentCoins then
					showShopNotice("Not enough coins.")
					return
				end

				local remotes = game:GetService("ReplicatedStorage"):WaitForChild("Remotes")
				remotes:WaitForChild("BuyTalent"):FireServer(currentTalentId)
			end)
		end

		local shopRemotes = ReplicatedStorage:WaitForChild("Remotes", 5)
		local talentPurchaseFailedEvent = shopRemotes and shopRemotes:WaitForChild("TalentPurchaseFailed", 5)
		if talentPurchaseFailedEvent and talentPurchaseFailedEvent:IsA("RemoteEvent") then
			talentPurchaseFailedEvent.OnClientEvent:Connect(function(payload)
				payload = type(payload) == "table" and payload or {}
				local reason = tostring(payload.Reason or "")
				if reason == "NotEnoughCoins" then
					showShopNotice("Not enough coins.")
				elseif reason == "MaxLevel" then
					showShopNotice("Already max level.")
				end
			end)
		elseif shopRemotes then
			warn("[UIController][Shop] TalentPurchaseFailed RemoteEvent missing.")
		end

		local refreshShopUI

		-- 统一控制商店打开/关闭，确保 Visible、模糊、FOV 和刷新逻辑同步。
		local function setShopPanelOpen(isOpen)
			if isOpen == shopPanel.Visible then
				return
			end

			isApplyingShopVisible = true
			shopPanel.Visible = isOpen
			isApplyingShopVisible = false
			tweenShopBlur(isOpen)
			tweenShopCamera(isOpen)
			setMainButtonRootHiddenByPanel(mainUI, "Shop", isOpen)

			if isOpen then
				shopOpenClock = os.clock()
				reportAnalyticsEvent("shop_open", {
					source = "shop_panel",
					coins = player:GetAttribute("Coins") or 0,
					best_distance = player:GetAttribute("BestDistance") or 0,
					best_level = player:GetAttribute("BestLevel") or 1,
				})
				if refreshShopUI then
					refreshShopUI()
				end
			else
				local durationInShop = shopOpenClock and math.floor(os.clock() - shopOpenClock) or 0
				shopOpenClock = nil
				reportAnalyticsEvent("shop_close", {
					duration_in_shop = durationInShop,
					close_reason = "panel_closed",
					coins = player:GetAttribute("Coins") or 0,
				})
			end
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
				CategoryName = "Player Stats",
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

			local layerCandidates = {}
			local layerCandidateMap = {}
			local hasActiveLayer = false
			local function addLayerCandidate(node, layerKey)
				local isActive = isShopLayerActive(layerKey, activeCategory)
				if layerCandidateMap[node] == nil then
					table.insert(layerCandidates, node)
					layerCandidateMap[node] = isActive
				else
					layerCandidateMap[node] = layerCandidateMap[node] or isActive
				end
				hasActiveLayer = hasActiveLayer or isActive
			end

			for _, node in ipairs(card:GetDescendants()) do
				if node:IsA("GuiObject") then
					local attrCategory = node:GetAttribute("CardArtCategory") or node:GetAttribute("ShopCardCategory")
					if attrCategory then
						addLayerCandidate(node, tostring(attrCategory))
					end

					for category, aliases in pairs(layerAliases) do
						if node.Name == "CategoryLayer_" .. category or node.Name == "CardArt_" .. category then
							addLayerCandidate(node, category)
						end

						for _, alias in ipairs(aliases) do
							if node.Name == "CategoryLayer_" .. alias or node.Name == "CardArt_" .. alias then
								addLayerCandidate(node, alias)
							end
						end
					end
				end
			end

			card:SetAttribute("ShopCardCategoryLayerFound", hasActiveLayer)
			if not hasActiveLayer then
				return
			end

			for _, node in ipairs(layerCandidates) do
				local isActive = layerCandidateMap[node] == true
				node.Visible = isActive
				node:SetAttribute("ShopCardLayerActive", isActive)
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
			local isMaxLevel = talentData.MaxLevel and currentLevel >= talentData.MaxLevel
			local priceDisplay = isMaxLevel and "Max" or Config.FormatNumber(cost)
			local displayText = talentData.Name .. " Lv." .. currentLevel .. "\nCoins: " .. priceDisplay
			local effectText = (Config.GetTalentEffectText and Config.GetTalentEffectText(talentId)) or ("Effect: +" .. tostring(talentData.StatIncrease or 0))
			local titleText = findTextNode(btn, {"TitleText", "NameText", "TalentNameText"})
			local levelText = findTextNode(btn, {"LevelText", "LevelLabel"})
			local priceText = findTextNode(btn, {"PriceText", "CostText", "CoinText", "AmountText"})
			local effectLabel = findTextNode(btn, {"EffectText", "DescText", "DescriptionText", "NoteText"})
			local productIdText = findTextNode(btn, {"ProductIdText", "IdText", "GoodsIdText"})
			local hasSplitLabels = titleText or levelText or priceText or effectLabel or productIdText
			local coins = player:GetAttribute("Coins") or 0
			local productId = talentData.ProductId

			btn:SetAttribute("TalentId", talentId)
			if productId then
				btn:SetAttribute("ProductId", productId)
			else
				btn:SetAttribute("ProductId", nil)
			end
			btn:SetAttribute("TalentLevel", currentLevel)
			btn:SetAttribute("TalentCost", cost == math.huge and -1 or cost)
			btn:SetAttribute("CanAfford", (not isMaxLevel) and cost ~= math.huge and coins >= cost)

			applyShopCardArt(btn, talentId, talentData)

			if titleText then titleText.Text = talentData.Name end
			if levelText then levelText.Text = "Lv." .. tostring(currentLevel) end
			if priceText then priceText.Text = priceDisplay end
			if effectLabel then effectLabel.Text = effectText end
			if productIdText and productId then productIdText.Text = "ID: " .. tostring(productId) end

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
		function refreshShopUI()
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
				end

				if btn:IsA("GuiObject") then
					btn.LayoutOrder = layoutOrder
					bindShopCardInteraction(btn, talentId)
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
			setShopPanelOpen(player:GetAttribute("IsShopOpen") == true)
		end)

		-- 兜底处理其他代码直接修改 ShopPanel.Visible 的情况，避免模糊和 FOV 残留。
		shopPanel:GetPropertyChangedSignal("Visible"):Connect(function()
			if isApplyingShopVisible then return end

			tweenShopBlur(shopPanel.Visible)
			tweenShopCamera(shopPanel.Visible)
			setMainButtonRootHiddenByPanel(mainUI, "Shop", shopPanel.Visible)
			if shopPanel.Visible then
				shopOpenClock = os.clock()
				reportAnalyticsEvent("shop_open", {
					source = "shop_visible",
					coins = player:GetAttribute("Coins") or 0,
					best_distance = player:GetAttribute("BestDistance") or 0,
					best_level = player:GetAttribute("BestLevel") or 1,
				})
				refreshShopUI()
			else
				local durationInShop = shopOpenClock and math.floor(os.clock() - shopOpenClock) or 0
				shopOpenClock = nil
				reportAnalyticsEvent("shop_close", {
					duration_in_shop = durationInShop,
					close_reason = "visible_changed",
					coins = player:GetAttribute("Coins") or 0,
				})
			end
		end)

		-- 绑定关闭面板按钮
		local closeBtn = findShopButton(shopPanel, {"CloseButton", "BtnClose", "ShopCloseButton"})
		if closeBtn then
			applyShopHoverScale(
				closeBtn,
				"ShopCloseHoverBound",
				"ShopCloseHoverScale",
				shopConfig.CloseButtonHoverScale or petBagConfig.CloseButtonHoverScale or 1.06
			)
			closeBtn.Activated:Connect(function()
				player:SetAttribute("IsShopOpen", false)
			end)
		end

		setMainButtonRootHiddenByPanel(mainUI, "Shop", shopPanel.Visible)
	end


	-- =======================================================
	-- 【双区重构版】：宠物背包 UI (对接 Studio 栅格布局)
	-- =======================================================
	local function setupPetBagUI()
		local playerGui = player:WaitForChild("PlayerGui")
		local mainUI = playerGui:WaitForChild("MainUI")
		local buttonRoot = getMainButtonRoot(mainUI)
		
		local openBagBtn = buttonRoot and buttonRoot:WaitForChild("BtnOpenPetBag", 5)
		local bagPanel = mainUI:WaitForChild("PetBagPanel", 5)
		if not openBagBtn or not bagPanel then return end
		
		local closeBtn = bagPanel:FindFirstChild("BtnClose", true)
			or bagPanel:FindFirstChild("CloseButton", true)
			or bagPanel:FindFirstChild("BtnClosePetBag", true)
		player:SetAttribute("IsPetBagOpen", bagPanel.Visible)
		
		-- 当前宠物界面已改为 Studio 直接摆放；按钮只负责开关 PetBagPanel。
		-- 不再等待旧版 EquippedContainer / StandbyContainer / PetItemTemplate，避免初始化卡死导致 BtnOpenPetBag 无法绑定。
		local petBagConfig = Controllers.Config.PET_BAG_UI or {}
		local petBagBlurTween = nil
		local petBagCameraTween = nil
		local petBagSavedFOV = nil
		-- print("[UIController][PetBag] setup start. Panel visible:", bagPanel.Visible, "Close button found:", closeBtn ~= nil)

		-- 获取或创建背包专用毛玻璃；只在本地客户端生效，不影响服务器和其他玩家。
		local function getPetBagBlur()
			local blur = Lighting:FindFirstChild("PetBagBlur")
			if blur and not blur:IsA("BlurEffect") then
				blur = nil
			end

			if not blur then
				blur = Instance.new("BlurEffect")
				blur.Name = "PetBagBlur"
				blur.Size = 0
				blur.Parent = Lighting
			end

			return blur
		end

		-- 播放背包打开/关闭时的屏幕毛玻璃效果。
		local function tweenPetBagBlur(isOpen)
			local blur = getPetBagBlur()
			if petBagBlurTween then
				petBagBlurTween:Cancel()
				petBagBlurTween = nil
			end

			local targetSize = isOpen and (petBagConfig.OpenBlurSize or 14) or 0
			local tweenTime = petBagConfig.OpenBlurTweenTime or 0.18
			petBagBlurTween = TweenService:Create(
				blur,
				TweenInfo.new(tweenTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Size = targetSize }
			)
			petBagBlurTween:Play()
		end

		-- 打开背包时轻微拉近玩家视野；关闭时只恢复 FieldOfView，不接管相机类型和跟随目标。
		local function tweenPetBagCamera(isOpen)
			local currentCamera = Workspace.CurrentCamera
			if not currentCamera then return end

			if petBagCameraTween then
				petBagCameraTween:Cancel()
				petBagCameraTween = nil
			end

			if isOpen then
				if not petBagSavedFOV then
					petBagSavedFOV = currentCamera.FieldOfView
				end
			elseif not petBagSavedFOV then
				return
			end

			local targetFOV = isOpen and (petBagConfig.OpenCameraFOV or 58) or petBagSavedFOV
			local tweenTime = petBagConfig.OpenCameraTweenTime or 0.2
			petBagCameraTween = TweenService:Create(
				currentCamera,
				TweenInfo.new(tweenTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ FieldOfView = targetFOV }
			)
			petBagCameraTween:Play()

			if not isOpen then
				local savedTween = petBagCameraTween
				task.delay(tweenTime, function()
					if petBagCameraTween == savedTween then
						petBagSavedFOV = nil
					end
				end)
			end
		end

		-- 关闭按钮悬浮反馈：轻微放大并旋转，移出或点击后恢复美术原始角度。
		local function applyCloseButtonHover()
			if not closeBtn or not closeBtn:IsA("GuiButton") then return end
			if closeBtn:GetAttribute("PetBagCloseHoverBound") then return end
			closeBtn:SetAttribute("PetBagCloseHoverBound", true)

			local hoverScale = closeBtn:FindFirstChild("PetBagCloseHoverScale")
			if not hoverScale then
				hoverScale = Instance.new("UIScale")
				hoverScale.Name = "PetBagCloseHoverScale"
				hoverScale.Parent = closeBtn
			end

			local normalScale = hoverScale.Scale
			local normalRotation = closeBtn.Rotation
			local targetScale = petBagConfig.CloseButtonHoverScale or 1.06
			local targetRotation = normalRotation + (petBagConfig.CloseButtonHoverRotation or 8)
			local tweenTime = petBagConfig.HoverTweenTime or 0.12
			local tweenInfo = TweenInfo.new(tweenTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

			local function playHoverTween(scale, rotation)
				TweenService:Create(hoverScale, tweenInfo, { Scale = scale }):Play()
				TweenService:Create(closeBtn, tweenInfo, { Rotation = rotation }):Play()
			end

			closeBtn.MouseEnter:Connect(function()
				playHoverTween(targetScale, targetRotation)
			end)

			closeBtn.MouseLeave:Connect(function()
				playHoverTween(normalScale, normalRotation)
			end)

			closeBtn.Activated:Connect(function()
				playHoverTween(normalScale, normalRotation)
			end)
		end

		-- 背包入口按钮悬浮反馈：只做缩放，不覆盖美术给的图片和位置。
		local function applyOpenBagButtonHover()
			if not openBagBtn or not openBagBtn:IsA("GuiButton") then return end
			if openBagBtn:GetAttribute("PetBagOpenHoverBound") then return end
			openBagBtn:SetAttribute("PetBagOpenHoverBound", true)

			local hoverScale = openBagBtn:FindFirstChild("PetBagOpenHoverScale")
			if not hoverScale then
				hoverScale = Instance.new("UIScale")
				hoverScale.Name = "PetBagOpenHoverScale"
				hoverScale.Parent = openBagBtn
			end

			local normalScale = hoverScale.Scale
			local targetScale = petBagConfig.OpenButtonHoverScale or petBagConfig.CloseButtonHoverScale or 1.06
			local tweenInfo = TweenInfo.new(
				petBagConfig.HoverTweenTime or 0.12,
				Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out
			)

			local function playScaleTween(scale)
				TweenService:Create(hoverScale, tweenInfo, { Scale = scale }):Play()
			end

			openBagBtn.MouseEnter:Connect(function()
				playScaleTween(targetScale)
			end)

			openBagBtn.MouseLeave:Connect(function()
				playScaleTween(normalScale)
			end)

			openBagBtn.Activated:Connect(function()
				playScaleTween(normalScale)
			end)
		end

		local petList = bagPanel:FindFirstChild("PetList", true)
		local equippedContainer = bagPanel:FindFirstChild("EquippedContainer", true)
		local detailButton = equippedContainer and equippedContainer:FindFirstChild("PetButton_1", true)
		local bagHeader = bagPanel:FindFirstChild("Header", true)
		local equippedCountText = bagHeader and bagHeader:FindFirstChild("Count", true)
		local selectedPetUid = nil
		local pendingSelectedPetUidAfterRemove = nil
		local petTemplateByQuality = {}

		if petList then
			for quality = 1, 3 do
				local template = petList:FindFirstChild("pet_farme_quality" .. quality, true)
				if template and template:IsA("GuiObject") then
					petTemplateByQuality[quality] = template
					template.Visible = false
				end
			end
		end

		-- 安全解析宠物背包；新结构为 {Uid, Id, Level}，同时兼容旧存档里的字符串宠物 ID。
		local function decodeOwnedPets()
			local success, decoded = pcall(function()
				return HttpService:JSONDecode(player:GetAttribute("OwnedPets_JSON") or "[]")
			end)

			if not success or type(decoded) ~= "table" then
				return {}
			end

			local owned = {}
			for index, petEntry in ipairs(decoded) do
				if type(petEntry) == "string" and Controllers.Config.PETS[petEntry] then
					table.insert(owned, {
						Uid = "legacy_client_" .. tostring(index) .. "_" .. petEntry,
						Id = petEntry,
						Level = Controllers.Config.PET_LEVEL_MIN or 1,
					})
				elseif type(petEntry) == "table" and type(petEntry.Id) == "string" and Controllers.Config.PETS[petEntry.Id] then
					local normalizeLevel = Controllers.Config.NormalizePetLevel
					local level = normalizeLevel and normalizeLevel(petEntry.Level) or math.max(1, math.floor(tonumber(petEntry.Level) or 1))
					table.insert(owned, {
						Uid = type(petEntry.Uid) == "string" and petEntry.Uid or ("pet_client_" .. tostring(index) .. "_" .. petEntry.Id),
						Id = petEntry.Id,
						Level = level,
					})
				end
			end

			return owned
		end

		local function decodeEquippedPetUids()
			local success, decoded = pcall(function()
				return HttpService:JSONDecode(player:GetAttribute("EquippedPets_JSON") or "[]")
			end)

			local equippedUids = {}
			local equippedMap = {}
			if success and type(decoded) == "table" then
				for _, uid in ipairs(decoded) do
					if type(uid) == "string" and uid ~= "" and not equippedMap[uid] then
						equippedMap[uid] = true
						table.insert(equippedUids, uid)
					end
				end
			end

			local legacyUid = player:GetAttribute("EquippedPetUid") or ""
			if #equippedUids == 0 and legacyUid ~= "" then
				equippedMap[legacyUid] = true
				table.insert(equippedUids, legacyUid)
			end

			local legacyPetId = player:GetAttribute("EquippedPet") or ""
			if #equippedUids == 0 and legacyPetId ~= "" then
				equippedMap[legacyPetId] = true
				table.insert(equippedUids, legacyPetId)
			end

			return equippedUids, equippedMap
		end

		local function getMaxEquipSlots()
			local slotUpgradeLevel = math.max(0, math.floor(tonumber(player:GetAttribute("Talent_PET_SLOT")) or 0))
			return 1 + slotUpgradeLevel
		end

		local function showPetBagNotice(text, seconds)
			local noticeUI = mainUI:FindFirstChild("Notice_UI", true)
			local noticeButton = noticeUI and noticeUI:FindFirstChild("Notice_button", true)
			if noticeButton and (noticeButton:IsA("TextLabel") or noticeButton:IsA("TextButton")) then
				noticeButton.Text = tostring(text or "")
			end
			if noticeUI and noticeUI:IsA("GuiObject") then
				noticeUI.Visible = true
				task.delay(seconds or 3, function()
					if noticeUI then
						noticeUI.Visible = false
					end
				end)
			else
				warn("[UIController][PetBag] Notice_UI missing. Notice:", text)
			end
		end

		local petBagRemotes = ReplicatedStorage:WaitForChild("Remotes", 5)
		local equipPetFailedEvent = petBagRemotes and petBagRemotes:WaitForChild("EquipPetFailed", 5)
		if equipPetFailedEvent and equipPetFailedEvent:IsA("RemoteEvent") then
			equipPetFailedEvent.OnClientEvent:Connect(function(payload)
				payload = type(payload) == "table" and payload or {}
				local message = tostring(payload.Message or "")
				if message == "" and payload.Reason == "EquippedSlotsFull" then
					message = "Equipped pet slots are full. Please unequip a pet first."
				end
				if message ~= "" then
					showPetBagNotice(message)
				end
			end)
		elseif petBagRemotes then
			warn("[UIController][PetBag] EquipPetFailed RemoteEvent missing.")
		end

		-- 将宠物实例按配置 SortOrder、等级、名称排序，保证背包每次刷新顺序稳定。
		local function updateEquippedCountText()
			if not equippedCountText or not equippedCountText:IsA("TextLabel") then
				return
			end

			local equippedUids = decodeEquippedPetUids()
			local maxEquipSlots = getMaxEquipSlots()
			equippedCountText.Text = tostring(#equippedUids) .. "/" .. tostring(maxEquipSlots)
		end

		local function getSortedPetEntries(ownedPets)
			table.sort(ownedPets, function(a, b)
				local sortA = Controllers.Config.GetPetSortValue and Controllers.Config.GetPetSortValue(a.Id) or math.huge
				local sortB = Controllers.Config.GetPetSortValue and Controllers.Config.GetPetSortValue(b.Id) or math.huge
				if sortA ~= sortB then
					return sortA < sortB
				end

				if a.Level ~= b.Level then
					return a.Level > b.Level
				end

				local nameA = Controllers.Config.PETS[a.Id].Name or a.Id
				local nameB = Controllers.Config.PETS[b.Id].Name or b.Id
				if nameA ~= nameB then
					return nameA < nameB
				end

				return tostring(a.Uid) < tostring(b.Uid)
			end)

			return ownedPets
		end

		-- 清理代码动态生成的格子；保留 Studio 中的背景、标题、分隔线和 UIGridLayout。
		local function clearGeneratedBagItems(container)
			for _, child in ipairs(container:GetChildren()) do
				if child:GetAttribute("PetBagGenerated") == true then
					child:Destroy()
				end
			end
		end

		-- 动态克隆进列表的格子保留 Studio 模板自身尺寸与内部节点布局；代码只补 LayoutOrder 和滚动配置。
		local function normalizeBagItemLayout(item, parent, layoutOrder)
			if not item or not item:IsA("GuiObject") then return end

			item.LayoutOrder = layoutOrder or 0

			-- ScrollingFrame 里由 Studio 的 UIGridLayout/UIListLayout 负责排列；代码只补齐滚动画布配置。
			if parent and parent:IsA("ScrollingFrame") then
				parent.AutomaticCanvasSize = Enum.AutomaticSize.Y
				parent.ScrollingDirection = Enum.ScrollingDirection.Y
			end
		end

		-- 克隆宠物格模板；按三档品质选择 pet_farme_quality1-3。
		local function createPetButton(parent, layoutOrder, quality)
			local template = petTemplateByQuality[quality] or petTemplateByQuality[1] or petTemplateByQuality[2] or petTemplateByQuality[3]
			if not template then return nil end
			local btn = template:Clone()
			btn:SetAttribute("PetBagGenerated", true)
			btn.Visible = true
			btn.Parent = parent
			normalizeBagItemLayout(btn, parent, layoutOrder)
			return btn
		end

		-- 宠物格悬浮反馈：已装备和待机宠物都可响应，空槽不绑定。
		local function applyPetItemHover(btn)
			if not btn or not btn:IsA("GuiObject") then return end
			if btn:GetAttribute("PetBagItemHoverBound") then return end
			btn:SetAttribute("PetBagItemHoverBound", true)

			local hoverScale = btn:FindFirstChild("PetBagItemHoverScale")
			if not hoverScale then
				hoverScale = Instance.new("UIScale")
				hoverScale.Name = "PetBagItemHoverScale"
				hoverScale.Parent = btn
			end

			local normalScale = hoverScale.Scale
			local targetScale = petBagConfig.PetStandbyHoverScale or 0.94
			local tweenInfo = TweenInfo.new(
				petBagConfig.HoverTweenTime or 0.12,
				Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out
			)

			local function playScaleTween(scale)
				TweenService:Create(hoverScale, tweenInfo, { Scale = scale }):Play()
			end

			btn.MouseEnter:Connect(function()
				playScaleTween(targetScale)
			end)

			btn.MouseLeave:Connect(function()
				playScaleTween(normalScale)
			end)

			if btn:IsA("GuiButton") then
				btn.Activated:Connect(function()
					playScaleTween(normalScale)
				end)
			end
		end

		-- 查找宠物格里的 ViewportFrame；用于直接展示 ReplicatedStorage/Model/Pets 下的宠物模型。
		local function findPetViewport(root)
			for _, name in ipairs({"ViewportFrame", "PetViewport", "PetIconViewport", "IconViewport", "Viewport"}) do
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
			if not viewport then
				warn("[UIController][PetBag] ViewportFrame not found for pet button:", btn and btn:GetFullName(), "petId:", petId)
				return false
			end

			clearPetViewport(viewport)
			viewport.BackgroundTransparency = 1

			local modelFolder = ReplicatedStorage:FindFirstChild("Model")
			local petModels = modelFolder and modelFolder:FindFirstChild("Pets")
			local petTemplateModel = petModels and petModels:FindFirstChild(petId)
			if not petTemplateModel then
				viewport.Visible = false
				btn:SetAttribute("PetViewportModelFound", false)
				warn("[UIController][PetBag] Pet viewport model missing:", petId, "button:", btn and btn:GetFullName())
				return false
			end

			local petClone = petTemplateModel:Clone()
			local ok = fitPetModelInViewport(viewport, petClone)
			viewport.Visible = ok
			btn:SetAttribute("PetViewportModelFound", ok)
			btn:SetAttribute("PetViewportModelNameDebug", petTemplateModel.Name)
			if not ok then
				petClone:Destroy()
				warn("[UIController][PetBag] Failed to render pet in ViewportFrame:", petId, "viewport:", viewport:GetFullName())
			end

			return ok
		end

		local function setGradientEnabled(root, gradientName, enabled)
			if not root then return end
			for _, node in ipairs(root:GetDescendants()) do
				if node.Name == gradientName and node:IsA("UIGradient") then
					node.Enabled = enabled
				end
			end
		end

		local function applyQualityGradients(root, quality)
			for i = 1, 3 do
				setGradientEnabled(root, "UIGradient_" .. i, i == quality)
			end
		end

		local function setSelectedStroke(root, isSelected)
			if not root then return end
			local stroke = root:FindFirstChild("SelectedStroke", true)
			if not stroke then return end
			if stroke:IsA("UIStroke") then
				stroke.Enabled = isSelected
			elseif stroke:IsA("GuiObject") then
				stroke.Visible = isSelected
			end
		end

		local function findGuiButton(root, names)
			if not root then return nil end
			for _, name in ipairs(names) do
				local node = root:FindFirstChild(name, true)
				if node and node:IsA("GuiButton") then
					return node
				end
				if node then
					local button = node:FindFirstChildWhichIsA("GuiButton", true)
					if button then return button end
				end
			end
			return root:FindFirstChildWhichIsA("GuiButton", true)
		end

		-- 生成宠物卡展示数据，便于美术把宠物名称、等级、攻击力、稀有度等拆成独立 TextLabel。
		local function getPetDisplayData(petId, level, statusText)
			local petConfig = Controllers.Config.PETS[petId]
			local hasStatus = type(statusText) == "string" and statusText ~= ""
			level = Controllers.Config.NormalizePetLevel and Controllers.Config.NormalizePetLevel(level) or math.max(1, math.floor(tonumber(level) or 1))
			if not petConfig then
				return {
					Name = petId,
					Level = level,
					LevelText = "Lv." .. tostring(level),
					Rarity = "Unknown",
					Quality = 1,
					Status = hasStatus and statusText or "",
					Attack = "0",
					Description = "",
					FullText = petId,
				}
			end

			local rarityText = petConfig.Rarity or "Unknown"
			local description = petConfig.Description or "No description"
			local statusLine = hasStatus and ("\n" .. statusText) or ""
			local finalAtk = Controllers.Config.GetPetAttack and Controllers.Config.GetPetAttack(petId, level) or (petConfig.ATK or 0)
			local attackText = Controllers.Config.FormatNumber(finalAtk)
			local quality = Controllers.Config.GetPetQuality and Controllers.Config.GetPetQuality(petId) or 1
			local fullText = string.format(
				"%s [%s] Lv.%d%s\nATK:%s\n%s",
				petConfig.Name or petId,
				rarityText,
				level,
				statusLine,
				attackText,
				description
			)

			return {
				Name = petConfig.Name or petId,
				Level = level,
				LevelText = "Lv." .. tostring(level),
				Rarity = rarityText,
				Quality = quality,
				Status = hasStatus and statusText or "",
				Attack = attackText,
				Description = description,
				Icon = normalizeImageAssetId(petConfig.Icon, false),
				FullText = fullText,
			}
		end

		-- 给宠物卡填充显示内容；优先写入美术拆好的标签，没有拆分时回退到按钮文本。
		-- textRoot 用于兼容右侧详情区：宠物模型按钮 PetButton_1 与文字标签是 EquippedContainer 下的同级节点。
		local function applyPetButtonDisplay(btn, petEntry, statusText, textRoot)
			local display = getPetDisplayData(petEntry.Id, petEntry.Level, statusText)
			local labelRoot = textRoot or btn
			local nameText = findTextNode(labelRoot, {"TextLabel-name", "PetNameText", "NameText", "TitleText"})
			local levelLabel = findTextNode(labelRoot, {"TextLabel-ABC", "LevelText", "LevelLabel", "ABCText"})
			local rarityText = findTextNode(labelRoot, {"RarityText", "RarityLabel"})
			local statusLabel = findTextNode(labelRoot, {"StatusText", "StateText", "EquippedText"})
			local attackText = findTextNode(labelRoot, {"TextLabel-ATK", "AttackText", "ATKText", "AtkText"})
			local descText = findTextNode(labelRoot, {"DescriptionText", "DescText", "NoteText"})
			local petIcon = findNamedImageNode(btn, {"PetIcon", "IconImage", "PetImage", "Avatar"})
			local hasSplitLabels = nameText or levelLabel or rarityText or statusLabel or attackText or descText

			btn:SetAttribute("PetUid", petEntry.Uid)
			btn:SetAttribute("PetId", petEntry.Id)
			btn:SetAttribute("PetLevel", display.Level)
			btn:SetAttribute("PetRarity", display.Rarity)
			btn:SetAttribute("PetQuality", display.Quality)
			btn:SetAttribute("PetState", (type(statusText) == "string" and statusText ~= "") and "Equipped" or "Standby")
			btn:SetAttribute("PetIconAssetDebug", display.Icon or "")

			if nameText then nameText.Text = display.Name end
			if levelLabel then levelLabel.Text = display.LevelText end
			if rarityText then rarityText.Text = display.Rarity end
			if statusLabel then
				statusLabel.Text = display.Status
				statusLabel.Visible = display.Status ~= ""
			end
			if attackText then attackText.Text = "ATK:" .. display.Attack end
			if descText then descText.Text = display.Description end
			applyQualityGradients(btn, display.Quality)
			local viewportRendered = applyPetViewport(btn, petEntry.Id)
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

		local function setEquipButtonVisual(isEquipped)
			if not detailButton then return end
			local equipRoot = equippedContainer and equippedContainer:FindFirstChild("Equip_1", true) or detailButton:FindFirstChild("Equip_1", true)
			local equipText = equipRoot and findTextNode(equipRoot, {"Equip"}) or findTextNode(detailButton, {"Equip"})
			if equipText then
				equipText.Text = isEquipped and "卸载" or "装备"
			end

			local gradientRoot = equipRoot or detailButton
			setGradientEnabled(gradientRoot, "UIGradient-x", not isEquipped)
			setGradientEnabled(gradientRoot, "UIGradient-y", isEquipped)
		end

		local function applyPetDetail(petEntry)
			if not detailButton then return end
			if not petEntry then
				detailButton:SetAttribute("PetUid", "")
				setEquipButtonVisual(false)
				return
			end

			local _, equippedMap = decodeEquippedPetUids()
			local isEquipped = equippedMap[petEntry.Uid] == true or equippedMap[petEntry.Id] == true
			applyPetButtonDisplay(detailButton, petEntry, isEquipped and "Equipped" or "", equippedContainer)
			setEquipButtonVisual(isEquipped)
		end

		local function bindEquipButton()
			if not detailButton or detailButton:GetAttribute("PetBagEquipBound") then return end

			local equipButton = findGuiButton(equippedContainer or detailButton, {"Equip_1"})
			if not equipButton then
				warn("[UIController][PetBag] Equip_1 button not found; detail display works but equip action is disabled. equippedContainer:", equippedContainer and equippedContainer:GetFullName(), "detailButton:", detailButton:GetFullName())
				return
			end
			detailButton:SetAttribute("PetBagEquipBound", true)
			-- print("[UIController][PetBag] Equip button bound:", equipButton:GetFullName())

			equipButton.Activated:Connect(function()
				local petUid = detailButton:GetAttribute("PetUid")
				if type(petUid) ~= "string" or petUid == "" then
					warn("[UIController][PetBag] Equip clicked but detail PetUid is empty.")
					return
				end

				local remotes = ReplicatedStorage:WaitForChild("Remotes", 5)
				local equipPetEvent = remotes and remotes:WaitForChild("EquipPet", 5)
				if not equipPetEvent then
					warn("[UIController][PetBag] EquipPet RemoteEvent missing.")
					return
				end

				local petId = detailButton:GetAttribute("PetId")
				local equippedUids, equippedMap = decodeEquippedPetUids()
				local isEquipped = equippedMap[petUid] == true or (type(petId) == "string" and equippedMap[petId] == true)
				if not isEquipped and #equippedUids >= getMaxEquipSlots() then
					showPetBagNotice("Equipped pet slots are full. Please unequip a pet first.")
					return
				end

				print("[UIController][PetBag] Toggle equip pet request:", petUid, detailButton:GetAttribute("PetId"))
				equipPetEvent:FireServer(petUid)
			end)
		end

		local function findNamedGuiButton(root, names)
			if not root then return nil end
			for _, name in ipairs(names) do
				local node = root:FindFirstChild(name, true)
				if node and node:IsA("GuiButton") then
					return node
				end
				if node then
					local button = node:FindFirstChildWhichIsA("GuiButton", true)
					if button then return button end
				end
			end
			return nil
		end

		local function getPreviousSelectionUidAfterRemove(ownedPets, removedPetUid)
			for index, petEntry in ipairs(ownedPets) do
				if petEntry.Uid == removedPetUid then
					if index > 1 then
						return ownedPets[index - 1].Uid
					end
					local nextEntry = ownedPets[index + 1]
					return nextEntry and nextEntry.Uid or nil
				end
			end

			return nil
		end

		local function bindRemoveButton()
			if not detailButton or detailButton:GetAttribute("PetBagRemoveBound") then return end

			local removeButton = findNamedGuiButton(equippedContainer or detailButton, {"Remove-pet", "RemovePet", "Remove_1", "BtnRemovePet"})
			if not removeButton then
				warn("[UIController][PetBag] Remove-pet button not found; detail display works but remove action is disabled. equippedContainer:", equippedContainer and equippedContainer:GetFullName(), "detailButton:", detailButton:GetFullName())
				return
			end

			detailButton:SetAttribute("PetBagRemoveBound", true)
			-- print("[UIController][PetBag] Remove-pet button bound:", removeButton:GetFullName())

			removeButton.Activated:Connect(function()
				local petUid = detailButton:GetAttribute("PetUid")
				if type(petUid) ~= "string" or petUid == "" then
					warn("[UIController][PetBag] Remove clicked but detail PetUid is empty.")
					return
				end

				local remotes = ReplicatedStorage:WaitForChild("Remotes", 5)
				local removePetEvent = remotes and remotes:WaitForChild("RemovePet", 5)
				if not removePetEvent then
					warn("[UIController][PetBag] RemovePet RemoteEvent missing.")
					return
				end

				local ownedPets = getSortedPetEntries(decodeOwnedPets())
				pendingSelectedPetUidAfterRemove = getPreviousSelectionUidAfterRemove(ownedPets, petUid)
				selectedPetUid = pendingSelectedPetUidAfterRemove
				print("[UIController][PetBag] Remove pet request:", petUid, "next selected:", pendingSelectedPetUidAfterRemove)
				removePetEvent:FireServer(petUid)
			end)
		end

		local function refreshBag()
			if not petList or not detailButton then
				warn("[UIController][PetBag] PetList or EquippedContainer.PetButton_1 missing; cannot refresh redesigned pet bag.")
				return
			end

			clearGeneratedBagItems(petList)
			local ownedPets = getSortedPetEntries(decodeOwnedPets())
			local _, equippedMap = decodeEquippedPetUids()
			updateEquippedCountText()
			if pendingSelectedPetUidAfterRemove then
				selectedPetUid = pendingSelectedPetUidAfterRemove
				pendingSelectedPetUidAfterRemove = nil
			end

			local selectedEntry = nil
			for _, petEntry in ipairs(ownedPets) do
				if selectedPetUid and petEntry.Uid == selectedPetUid then
					selectedEntry = petEntry
					break
				end
			end

			if not selectedEntry then
				for _, petEntry in ipairs(ownedPets) do
					if equippedMap[petEntry.Uid] or equippedMap[petEntry.Id] then
						selectedEntry = petEntry
						break
					end
				end
			end

			selectedEntry = selectedEntry or ownedPets[1]
			selectedPetUid = selectedEntry and selectedEntry.Uid or nil

			for index, petEntry in ipairs(ownedPets) do
				local quality = Controllers.Config.GetPetQuality and Controllers.Config.GetPetQuality(petEntry.Id) or 1
				local item = createPetButton(petList, index, quality)
				if item then
					local isEquipped = equippedMap[petEntry.Uid] == true or equippedMap[petEntry.Id] == true
					applyPetButtonDisplay(item, petEntry, isEquipped and "Equipped" or "")
					setSelectedStroke(item, isEquipped)
					applyPetItemHover(item)

					local clickButton = item:IsA("GuiButton") and item or item:FindFirstChildWhichIsA("GuiButton", true)
					if clickButton then
						clickButton.Activated:Connect(function()
							selectedPetUid = petEntry.Uid
							refreshBag()
						end)
					elseif item:IsA("GuiObject") then
						item.Active = true
						item.InputBegan:Connect(function(input)
							if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
								return
							end

							selectedPetUid = petEntry.Uid
							refreshBag()
						end)
					else
						warn("[UIController][PetBag] Pet list item is not clickable:", item:GetFullName(), petEntry.Uid, petEntry.Id)
					end
				end
			end

			applyPetDetail(selectedEntry)
		end

		local isApplyingPetBagVisible = false

		-- 统一控制背包开关；所有入口都走这里，避免 Visible、毛玻璃和相机 FOV 状态不同步。
		local function setPetBagOpen(isOpen)
			if isOpen == bagPanel.Visible then
				return
			end

			player:SetAttribute("IsPetBagOpen", isOpen)
			isApplyingPetBagVisible = true
			bagPanel.Visible = isOpen
			isApplyingPetBagVisible = false
			tweenPetBagBlur(isOpen)
			tweenPetBagCamera(isOpen)

			if isOpen then
				refreshBag()
			end
		end

		applyCloseButtonHover()
		applyOpenBagButtonHover()
		bindEquipButton()
		bindRemoveButton()

		-- 兜底处理外部代码直接改 Visible 的情况，例如进入战斗时主 UI 循环会强制关闭背包。
		bagPanel:GetPropertyChangedSignal("Visible"):Connect(function()
			if isApplyingPetBagVisible then return end

			player:SetAttribute("IsPetBagOpen", bagPanel.Visible)
			tweenPetBagBlur(bagPanel.Visible)
			tweenPetBagCamera(bagPanel.Visible)
			if bagPanel.Visible then
				refreshBag()
			end
		end)

		openBagBtn.Activated:Connect(function()
			setPetBagOpen(not bagPanel.Visible)
		end)
		if closeBtn and closeBtn:IsA("GuiButton") then
			closeBtn.Activated:Connect(function()
				setPetBagOpen(false)
			end)
		else
			warn("[UIController][PetBag] Close button not found; BtnOpenPetBag can still toggle PetBagPanel.")
		end
		-- print("[UIController][PetBag] BtnOpenPetBag bound successfully.")
		
		-- 装备发生变动、或者刚好抽到新宠物时，实时刷新面板
		player:GetAttributeChangedSignal("EquippedPet"):Connect(function()
			if bagPanel.Visible then refreshBag() end
		end)
		player:GetAttributeChangedSignal("EquippedPetUid"):Connect(function()
			if bagPanel.Visible then refreshBag() end
		end)
		player:GetAttributeChangedSignal("EquippedPetLevel"):Connect(function()
			if bagPanel.Visible then refreshBag() end
		end)
		player:GetAttributeChangedSignal("EquippedPets_JSON"):Connect(function()
			if bagPanel.Visible then refreshBag() end
		end)
		player:GetAttributeChangedSignal("Talent_PET_SLOT"):Connect(function()
			if bagPanel.Visible then refreshBag() end
		end)
		player:GetAttributeChangedSignal("OwnedPets_JSON"):Connect(function()
			if bagPanel.Visible then refreshBag() end
		end)
	end


	-- =======================================================
	-- 【重构版】：3D ViewportFrame 宠物蛋破壳动画 (对接 Studio)
	-- =======================================================
	local function setupAchievementUI()
		local playerGui = player:WaitForChild("PlayerGui")
		local mainUI = playerGui:WaitForChild("MainUI", 5)
		if not mainUI then return end
		local buttonRoot = getMainButtonRoot(mainUI)

		local openButton = buttonRoot and buttonRoot:FindFirstChild("BtnOpenAchieve")
		local achievePanel = mainUI:FindFirstChild("Achieve")
		if not openButton or not achievePanel or not achievePanel:IsA("GuiObject") then
			warn("[UIController] Achievement UI missing: MainUI/MainUI_1/BtnOpenAchieve or MainUI/Achieve.")
			return
		end

		local achievePage = achievePanel:FindFirstChild("AchievePage", true)
		local closeButton = achievePanel:FindFirstChild("CloseButton", true)
		local uiTemplates = ReplicatedStorage:FindFirstChild("UITemplates")
		local itemTemplate = uiTemplates and uiTemplates:FindFirstChild("AchieveItem")
		if not achievePage or not achievePage:IsA("GuiObject") or not itemTemplate or not itemTemplate:IsA("GuiObject") then
			warn("[UIController] Achievement UI missing: AchievePage or ReplicatedStorage/UITemplates/AchieveItem.")
			return
		end

		itemTemplate.Visible = false
		player:SetAttribute("IsAchieveOpen", achievePanel.Visible)

		local remotes = ReplicatedStorage:WaitForChild("Remotes", 5)
		local getAchievements = remotes and remotes:WaitForChild("GetAchievements", 5)
		local claimAchievement = remotes and remotes:WaitForChild("ClaimAchievement", 5)
		if not getAchievements or not claimAchievement then
			warn("[UIController] Achievement remotes are not ready.")
			return
		end

		if achievePage:IsA("ScrollingFrame") then
			achievePage.AutomaticCanvasSize = Enum.AutomaticSize.Y
			achievePage.ScrollingDirection = Enum.ScrollingDirection.Y
		end

		local petBagConfig = Controllers.Config.PET_BAG_UI or {}
		local achievementBlurTween = nil
		local achievementCameraTween = nil
		local achievementSavedFOV = nil
		local renderAchievementSnapshot
		local refreshAchievements

		local function applySimpleHover(guiObject, attributeName, scaleName, targetScale)
			if not guiObject or not guiObject:IsA("GuiObject") then return end
			if guiObject:GetAttribute(attributeName) then return end
			guiObject:SetAttribute(attributeName, true)

			local hoverScale = guiObject:FindFirstChild(scaleName)
			if not hoverScale then
				hoverScale = Instance.new("UIScale")
				hoverScale.Name = scaleName
				hoverScale.Parent = guiObject
			end

			local normalScale = hoverScale.Scale
			local tweenInfo = TweenInfo.new(
				petBagConfig.HoverTweenTime or 0.12,
				Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out
			)
			local function playScale(scale)
				TweenService:Create(hoverScale, tweenInfo, { Scale = scale }):Play()
			end

			guiObject.MouseEnter:Connect(function()
				playScale(targetScale or 1.06)
			end)
			guiObject.MouseLeave:Connect(function()
				playScale(normalScale)
			end)
			if guiObject:IsA("GuiButton") then
				guiObject.Activated:Connect(function()
					playScale(normalScale)
				end)
			end
		end

		-- 获取或创建成就面板专用毛玻璃；只影响本地世界背景，不会模糊 UI 本身。
		local function getAchievementBlur()
			local blur = Lighting:FindFirstChild("AchievementBlur")
			if blur and not blur:IsA("BlurEffect") then
				blur = nil
			end

			if not blur then
				blur = Instance.new("BlurEffect")
				blur.Name = "AchievementBlur"
				blur.Size = 0
				blur.Parent = Lighting
			end

			return blur
		end

		-- 成就面板打开/关闭时复用背包同款背景毛玻璃表现。
		local function tweenAchievementBlur(isOpen)
			local blur = getAchievementBlur()
			if achievementBlurTween then
				achievementBlurTween:Cancel()
				achievementBlurTween = nil
			end

			local targetSize = isOpen and (petBagConfig.OpenBlurSize or 14) or 0
			local tweenTime = petBagConfig.OpenBlurTweenTime or 0.18
			achievementBlurTween = TweenService:Create(
				blur,
				TweenInfo.new(tweenTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Size = targetSize }
			)
			achievementBlurTween:Play()
		end

		-- 成就面板打开时调整 FOV 做视野缩放；关闭时恢复打开前的 FOV。
		local function tweenAchievementCamera(isOpen)
			local currentCamera = Workspace.CurrentCamera
			if not currentCamera then return end

			if achievementCameraTween then
				achievementCameraTween:Cancel()
				achievementCameraTween = nil
			end

			if isOpen then
				if not achievementSavedFOV then
					achievementSavedFOV = currentCamera.FieldOfView
				end
			elseif not achievementSavedFOV then
				return
			end

			local targetFOV = isOpen and (petBagConfig.OpenCameraFOV or 58) or achievementSavedFOV
			local tweenTime = petBagConfig.OpenCameraTweenTime or 0.2
			achievementCameraTween = TweenService:Create(
				currentCamera,
				TweenInfo.new(tweenTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ FieldOfView = targetFOV }
			)
			achievementCameraTween:Play()

			if not isOpen then
				local savedTween = achievementCameraTween
				task.delay(tweenTime, function()
					if achievementCameraTween == savedTween then
						achievementSavedFOV = nil
					end
				end)
			end
		end

		local function clearGeneratedAchievementItems()
			for _, child in ipairs(achievePage:GetChildren()) do
				if child:GetAttribute("AchievementGenerated") == true then
					child:Destroy()
				end
			end
		end

		local function clearViewport(viewport)
			if not viewport then return end
			for _, child in ipairs(viewport:GetChildren()) do
				if child:GetAttribute("AchievementViewportGenerated") == true then
					child:Destroy()
				end
			end
			viewport.CurrentCamera = nil
		end

		local function renderEggReward(viewport)
			if not viewport or not viewport:IsA("ViewportFrame") then return end
			clearViewport(viewport)
			viewport.BackgroundTransparency = 1

			local modelFolder = ReplicatedStorage:FindFirstChild("Model")
			local petModels = modelFolder and modelFolder:FindFirstChild("Pets")
			local eggTemplate = petModels and petModels:FindFirstChild("Egg")
			if not eggTemplate then return end

			local worldModel = Instance.new("WorldModel")
			worldModel.Name = "AchievementRewardWorld"
			worldModel:SetAttribute("AchievementViewportGenerated", true)
			worldModel.Parent = viewport

			local egg = eggTemplate:Clone()
			egg:SetAttribute("AchievementViewportGenerated", true)
			egg.Parent = worldModel

			for _, obj in ipairs(egg:GetDescendants()) do
				if obj:IsA("BasePart") then
					obj.Anchored = true
					obj.CanCollide = false
				end
			end

			local boundsSize = Vector3.new(2, 2, 2)
			if egg:IsA("Model") then
				if not egg.PrimaryPart then
					egg.PrimaryPart = egg:FindFirstChildWhichIsA("BasePart", true)
				end
				egg:PivotTo(CFrame.new(0, 0, 0))
				local boundsCFrame
				boundsCFrame, boundsSize = egg:GetBoundingBox()
				egg:PivotTo(egg:GetPivot() + (-boundsCFrame.Position))
			elseif egg:IsA("BasePart") then
				egg.CFrame = CFrame.new(0, 0, 0)
				boundsSize = egg.Size
			else
				worldModel:Destroy()
				return
			end

			local maxSize = math.max(boundsSize.X, boundsSize.Y, boundsSize.Z, 1)
			local cameraDistance = maxSize * 2.2
			local camera = Instance.new("Camera")
			camera.Name = "AchievementRewardCamera"
			camera:SetAttribute("AchievementViewportGenerated", true)
			camera.FieldOfView = 35
			camera.CFrame = CFrame.lookAt(Vector3.new(0, boundsSize.Y * 0.15, cameraDistance), Vector3.new(0, 0, 0))
			camera.Parent = viewport
			viewport.CurrentCamera = camera
		end

		local function setButtonText(button, text)
			if not button then return end
			if button:IsA("TextButton") then
				button.Text = text
			end

			local label = button:FindFirstChildWhichIsA("TextLabel", true)
			if label then
				label.Text = text
			end
		end

		local function setClaimButtonState(button, entry)
			if not button or not button:IsA("GuiButton") then return end

			local stateText = "Locked"
			if entry.Claimed then
				stateText = "Claimed"
			elseif entry.CanClaim then
				stateText = "Claim"
			end

			setButtonText(button, stateText)
			button.Active = entry.CanClaim == true
			button.AutoButtonColor = entry.CanClaim == true
			button:SetAttribute("AchievementId", entry.Id)
			button:SetAttribute("AchievementCanClaim", entry.CanClaim == true)
			button:SetAttribute("AchievementClaimed", entry.Claimed == true)
		end

		local function getMaxDescendantZIndex(root)
			local maxZIndex = root.ZIndex
			for _, node in ipairs(root:GetDescendants()) do
				if node:IsA("GuiObject") then
					maxZIndex = math.max(maxZIndex, node.ZIndex)
				end
			end
			return maxZIndex
		end

		local function applyAchievementUnavailableMask(item, entry)
			if not item or not item:IsA("GuiObject") then return end

			local shouldMask = entry.CanClaim ~= true
			local mask = item:FindFirstChild("LockedOverlay")
			if not mask then
				mask = Instance.new("Frame")
				mask.Name = "LockedOverlay"
				mask.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
				mask.BorderSizePixel = 0
				mask.AnchorPoint = Vector2.new(0.5, 0.5)
				mask.Position = UDim2.fromScale(0.5, 0.5)
				mask.Size = UDim2.fromScale(1, 1)
				mask.Active = false
				mask.Parent = item
			end

			mask.Visible = shouldMask
			mask.BackgroundTransparency = entry.Claimed and 0.42 or 0.5
			mask.ZIndex = getMaxDescendantZIndex(item) + 1
		end

		local function fillAchievementItem(item, entry, layoutOrder)
			item:SetAttribute("AchievementGenerated", true)
			item:SetAttribute("AchievementId", entry.Id)
			item.LayoutOrder = layoutOrder or entry.SortOrder or 0
			item.Visible = true

			local descriptionText = item:FindFirstChild("DescriptionText", true)
			if descriptionText and descriptionText:IsA("TextLabel") then
				descriptionText.Text = entry.Title or ""
			end

			local detailsText = item:FindFirstChild("DetailsText", true)
			if detailsText and detailsText:IsA("TextLabel") then
				detailsText.Text = entry.Details or ""
			end

			local progressBarImage = item:FindFirstChild("ProgressBarImage", true)
			local fill = progressBarImage and progressBarImage:FindFirstChild("Fill", true)
			if fill and fill:IsA("GuiObject") then
				local progress = math.clamp(tonumber(entry.Progress) or 0, 0, 1)
				fill.Size = UDim2.new(progress, 0, fill.Size.Y.Scale, fill.Size.Y.Offset)
			end

			local progressText = progressBarImage and progressBarImage:FindFirstChild("TextLabel", true)
			if progressText and progressText:IsA("TextLabel") then
				progressText.Text = entry.ProgressText or ""
			end

			local reward1 = item:FindFirstChild("Reward_1", true)
			if reward1 then
				local viewport = reward1:FindFirstChildWhichIsA("ViewportFrame", true)
				renderEggReward(viewport)

				local amountText = reward1:FindFirstChild("TextLabel", true)
				if amountText and amountText:IsA("TextLabel") then
					amountText.Text = "x" .. tostring(entry.RewardTickets or 0)
				end
			end

			local reward2 = item:FindFirstChild("Reward_2", true)
			if reward2 then
				local amountText = reward2:FindFirstChild("TextLabel", true)
				if amountText and amountText:IsA("TextLabel") then
					local formatNumber = Controllers.Config.FormatNumber or tostring
					amountText.Text = "x" .. formatNumber(entry.RewardCoins or 0)
				end
			end

			local claimButton = item:FindFirstChild("ClaimBattle", true)
			if claimButton and claimButton:IsA("GuiButton") then
				setClaimButtonState(claimButton, entry)
				applySimpleHover(claimButton, "AchievementClaimHoverBound", "AchievementClaimHoverScale", 1.06)

				claimButton.Activated:Connect(function()
					if claimButton:GetAttribute("AchievementCanClaim") ~= true then return end
					claimButton:SetAttribute("AchievementCanClaim", false)
					claimButton.Active = false

					local result = claimAchievement:InvokeServer(entry.Id)
					if result and result.Snapshot then
						renderAchievementSnapshot(result.Snapshot)
					else
						refreshAchievements()
					end
				end)
			end

			applyAchievementUnavailableMask(item, entry)
		end

		renderAchievementSnapshot = function(snapshot)
			clearGeneratedAchievementItems()
			local entries = snapshot and snapshot.Achievements
			if type(entries) ~= "table" then
				return
			end

			for index, entry in ipairs(entries) do
				local item = itemTemplate:Clone()
				item.Parent = achievePage
				fillAchievementItem(item, entry, index)
			end

			if achievePage:IsA("ScrollingFrame") then
				achievePage.CanvasPosition = Vector2.zero
			end
		end

		refreshAchievements = function()
			local success, snapshot = pcall(function()
				return getAchievements:InvokeServer()
			end)

			if not success then
				warn("[UIController] Failed to refresh achievements:", snapshot)
				return
			end

			renderAchievementSnapshot(snapshot)
		end

		local isApplyingAchieveVisible = false
		local function setAchievementOpen(isOpen)
			if isOpen == achievePanel.Visible then
				player:SetAttribute("IsAchieveOpen", isOpen)
				tweenAchievementBlur(isOpen)
				tweenAchievementCamera(isOpen)
				return
			end

			player:SetAttribute("IsAchieveOpen", isOpen)
			isApplyingAchieveVisible = true
			achievePanel.Visible = isOpen
			tweenAchievementBlur(isOpen)
			tweenAchievementCamera(isOpen)
			isApplyingAchieveVisible = false

			if isOpen then
				refreshAchievements()
			end
		end

		if closeButton and closeButton:IsA("GuiButton") then
			applySimpleHover(closeButton, "AchievementCloseHoverBound", "AchievementCloseHoverScale", petBagConfig.CloseButtonHoverScale or 1.06)
			closeButton.Activated:Connect(function()
				setAchievementOpen(false)
			end)
		end

		if openButton:IsA("GuiButton") then
			applySimpleHover(
				openButton,
				"AchievementOpenHoverBound",
				"AchievementOpenHoverScale",
				petBagConfig.OpenButtonHoverScale or petBagConfig.CloseButtonHoverScale or 1.06
			)
			openButton.Activated:Connect(function()
				setAchievementOpen(not achievePanel.Visible)
			end)
		end

		achievePanel:GetPropertyChangedSignal("Visible"):Connect(function()
			if isApplyingAchieveVisible then return end
			player:SetAttribute("IsAchieveOpen", achievePanel.Visible)
			tweenAchievementBlur(achievePanel.Visible)
			tweenAchievementCamera(achievePanel.Visible)
			if achievePanel.Visible then
				refreshAchievements()
			end
		end)

		for _, attrName in ipairs({ "BestDistance", "PetDrawTickets", "Coins", "ClaimedAchievements_JSON" }) do
			player:GetAttributeChangedSignal(attrName):Connect(function()
				if achievePanel.Visible then
					refreshAchievements()
				end
			end)
		end
	end

	local function setupRebirthUI()
		local playerGui = player:WaitForChild("PlayerGui")
		local mainUI = playerGui:WaitForChild("MainUI", 5)
		if not mainUI then return end

		local buttonRoot = getMainButtonRoot(mainUI)
		local openButton = buttonRoot and buttonRoot:FindFirstChild("BtnRebirth")
		local rebirthPanel = mainUI:FindFirstChild("RebirthPanel")
		if not openButton or not openButton:IsA("GuiButton") or not rebirthPanel or not rebirthPanel:IsA("GuiObject") then
			warn("[UIController] Rebirth UI missing: MainUI/MainUI_1/BtnRebirth or MainUI/RebirthPanel.")
			return
		end

		local remotes = ReplicatedStorage:WaitForChild("Remotes", 5)
		local rebirthRemote = remotes and remotes:WaitForChild("Rebirth", 5)
		if not rebirthRemote or not rebirthRemote:IsA("RemoteFunction") then
			warn("[UIController] Rebirth RemoteFunction is not ready.")
			return
		end

		local petBagConfig = Controllers.Config.PET_BAG_UI or {}
		local closeButton = rebirthPanel:FindFirstChild("BtnClose", true)
		local confirmButton = rebirthPanel:FindFirstChild("BtnConfirm", true)
		local cancelButton = rebirthPanel:FindFirstChild("BtnCancel", true)
		local paidRebirthButton = nil

		local function applySimpleHover(guiObject, attributeName, scaleName, targetScale)
			if not guiObject or not guiObject:IsA("GuiObject") then return end
			if guiObject:GetAttribute(attributeName) then return end
			guiObject:SetAttribute(attributeName, true)

			local hoverScale = guiObject:FindFirstChild(scaleName)
			if not hoverScale then
				hoverScale = Instance.new("UIScale")
				hoverScale.Name = scaleName
				hoverScale.Parent = guiObject
			end

			local normalScale = hoverScale.Scale
			local tweenInfo = TweenInfo.new(
				petBagConfig.HoverTweenTime or 0.12,
				Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out
			)
			local function playScale(scale)
				TweenService:Create(hoverScale, tweenInfo, { Scale = scale }):Play()
			end

			guiObject.MouseEnter:Connect(function()
				playScale(targetScale or 1.06)
			end)
			guiObject.MouseLeave:Connect(function()
				playScale(normalScale)
			end)
			if guiObject:IsA("GuiButton") then
				guiObject.Activated:Connect(function()
					playScale(normalScale)
				end)
			end
		end

		local function setText(labelName, text)
			local label = findTextNode(rebirthPanel, { labelName })
			if label then
				label.Text = text
			end
		end

		local function setButtonText(button, text)
			if not button then return end
			if button:IsA("TextButton") then
				button.Text = text
			end

			local label = button:FindFirstChildWhichIsA("TextLabel", true)
			if label then
				label.Text = text
			end
		end

		local function findRebirthRobuxButton()
			local function hasRobuxText(button)
				if not button or not button:IsA("GuiButton") then
					return false
				end

				local directText = button:IsA("TextButton") and button.Text or ""
				if string.find(string.upper(tostring(directText)), "R") then
					return true
				end

				local label = button:FindFirstChildWhichIsA("TextLabel", true)
				return label ~= nil and string.find(string.upper(tostring(label.Text)), "R") ~= nil
			end

			for _, name in ipairs({
				"BtnRobuxRebirth",
				"BtnPaidRebirth",
				"BtnRebirthRobux",
				"BtnRobux",
				"BtnRRebirth",
				"RobuxRebirthButton",
			}) do
				local button = rebirthPanel:FindFirstChild(name, true)
				if button and button:IsA("GuiButton") then
					return button
				end
			end

			if hasRobuxText(cancelButton) then
				local button = cancelButton
				cancelButton = nil
				return button
			end

			for _, descendant in ipairs(rebirthPanel:GetDescendants()) do
				if descendant:IsA("GuiButton") and descendant ~= confirmButton and descendant ~= closeButton and descendant ~= cancelButton then
					if hasRobuxText(descendant) then
						return descendant
					end
				end
			end

			return nil
		end

		local function formatPercent(value)
			return string.format("+%d%%", math.floor((tonumber(value) or 0) * 100 + 0.5))
		end

		local warnedMissingRebirthProgress = false
		local function updateRebirthProgressBar(coins, cost, formatNumber)
			local progressBar = rebirthPanel:FindFirstChild("ProgressBar", true)
			local fill = progressBar and progressBar:FindFirstChild("Fill", true)
			local ratioText = progressBar and findTextNode(progressBar, { "CurrencyRatio" })

			if not progressBar or not fill then
				if not warnedMissingRebirthProgress then
					warn("[UIController] Rebirth progress UI missing: RebirthPanel/Content/ProgressBar/Fill.")
					warnedMissingRebirthProgress = true
				end
				return
			end

			local safeCost = math.max(1, math.floor(tonumber(cost) or 0))
			local progress = math.clamp((tonumber(coins) or 0) / safeCost, 0, 1)
			if fill:IsA("GuiObject") then
				fill.Size = UDim2.new(progress, 0, fill.Size.Y.Scale, fill.Size.Y.Offset)
			end

			if ratioText then
				ratioText.Text = formatNumber(coins) .. "$/" .. formatNumber(safeCost) .. "$"
			end
		end

		local function getRebirthSnapshot()
			local rebirthCount = math.max(0, math.floor(tonumber(player:GetAttribute("RebirthCount")) or 0))
			local coinGainBonus = tonumber(player:GetAttribute("CoinGainBonus"))
				or Controllers.Config.GetRebirthCoinGainBonus(rebirthCount)
			local cost = Controllers.Config.GetRebirthCost(rebirthCount)
			local nextCoinGainBonus = Controllers.Config.GetRebirthCoinGainBonus(rebirthCount + 1)
			return rebirthCount, cost, coinGainBonus, nextCoinGainBonus
		end

		local function refreshRebirthUI()
			local rebirthCount, cost, coinGainBonus, nextCoinGainBonus = getRebirthSnapshot()
			local coins = math.max(0, math.floor(tonumber(player:GetAttribute("Coins")) or 0))
			local formatNumber = Controllers.Config.FormatNumber or tostring
			local canRebirth = coins >= cost
			local paidRebirthConfig = ((Controllers.Config.MONETIZATION or {}).Rebirth or {})
			local paidRebirthProductId = math.max(0, math.floor(tonumber(paidRebirthConfig.ProductId) or 0))
			local paidRebirthPrice = math.max(0, math.floor(tonumber(paidRebirthConfig.PriceRobux) or 299))

			setText("TitleText", "Rebirth")
			setText("RebirthCountText", "Rebirths: " .. tostring(rebirthCount))
			local oldCostText = findTextNode(rebirthPanel, { "CostText" })
			if oldCostText then
				oldCostText.Text = ""
				oldCostText.Visible = false
			end
			setText("CurrentMultiplierText", "Current Coin Bonus: " .. formatPercent(coinGainBonus))
			setText("NextMultiplierText", "After Rebirth: " .. formatPercent(nextCoinGainBonus))
			setText("ResetNoticeText", "Resets shop upgrades except Pet Slots.")
			updateRebirthProgressBar(coins, cost, formatNumber)

			if confirmButton and confirmButton:IsA("GuiButton") then
				confirmButton:SetAttribute("CanRebirth", canRebirth)
				confirmButton.AutoButtonColor = canRebirth
				setButtonText(confirmButton, canRebirth and "Rebirth" or "Need Coins")
			end
			if cancelButton then
				setButtonText(cancelButton, "Cancel")
			end
			if paidRebirthButton and paidRebirthButton:IsA("GuiButton") then
				paidRebirthButton:SetAttribute("ProductId", paidRebirthProductId)
				paidRebirthButton.AutoButtonColor = paidRebirthProductId > 0
				setButtonText(paidRebirthButton, tostring(paidRebirthPrice) .. "R")
			end
			if closeButton and closeButton:IsA("TextButton") then
				closeButton.Text = "X"
			end
		end

		local isApplyingRebirthVisible = false
		local function setRebirthOpen(isOpen)
			if isOpen == rebirthPanel.Visible then
				if isOpen then
					refreshRebirthUI()
				end
				return
			end

			isApplyingRebirthVisible = true
			rebirthPanel.Visible = isOpen
			isApplyingRebirthVisible = false

			if isOpen then
				refreshRebirthUI()
			end
		end

		rebirthPanel.Visible = false
		paidRebirthButton = findRebirthRobuxButton()
		if not paidRebirthButton then
			warn("[UIController] Paid rebirth button not found. Recommended names: BtnRobuxRebirth / BtnPaidRebirth / BtnRebirthRobux / BtnRobux, or a button with text like 299R.")
		end
		refreshRebirthUI()

		applySimpleHover(openButton, "RebirthOpenHoverBound", "RebirthOpenHoverScale", petBagConfig.OpenButtonHoverScale or 1.06)
		openButton.Activated:Connect(function()
			setRebirthOpen(true)
		end)

		if closeButton and closeButton:IsA("GuiButton") then
			applySimpleHover(closeButton, "RebirthCloseHoverBound", "RebirthCloseHoverScale", petBagConfig.CloseButtonHoverScale or 1.06)
			closeButton.Activated:Connect(function()
				setRebirthOpen(false)
			end)
		end

		if cancelButton and cancelButton:IsA("GuiButton") then
			applySimpleHover(cancelButton, "RebirthCancelHoverBound", "RebirthCancelHoverScale", petBagConfig.CloseButtonHoverScale or 1.06)
			cancelButton.Activated:Connect(function()
				setRebirthOpen(false)
			end)
		end

		local paidRebirthPromptInProgress = false
		if paidRebirthButton and paidRebirthButton:IsA("GuiButton") then
			applySimpleHover(paidRebirthButton, "PaidRebirthHoverBound", "PaidRebirthHoverScale", 1.06)
			paidRebirthButton.Activated:Connect(function()
				if paidRebirthPromptInProgress then return end

				local productId = math.max(0, math.floor(tonumber(paidRebirthButton:GetAttribute("ProductId")) or 0))
				if productId <= 0 then
					warn("[UIController] Paid rebirth ProductId is not configured. Set GameConfig.MONETIZATION.Rebirth.ProductId.")
					refreshRebirthUI()
					return
				end

				paidRebirthPromptInProgress = true
				MarketplaceService:PromptProductPurchase(player, productId)
				task.delay(1, function()
					paidRebirthPromptInProgress = false
				end)
			end)

			MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId)
				if userId ~= player.UserId then return end
				local paidProductId = math.max(0, math.floor(tonumber(paidRebirthButton:GetAttribute("ProductId")) or 0))
				if paidProductId > 0 and productId ~= paidProductId then
					return
				end

				paidRebirthPromptInProgress = false
				task.delay(0.5, refreshRebirthUI)
			end)
		end

		if confirmButton and confirmButton:IsA("GuiButton") then
			applySimpleHover(confirmButton, "RebirthConfirmHoverBound", "RebirthConfirmHoverScale", 1.06)
			confirmButton.Activated:Connect(function()
				if confirmButton:GetAttribute("CanRebirth") ~= true then
					refreshRebirthUI()
					return
				end

				confirmButton:SetAttribute("CanRebirth", false)
				setButtonText(confirmButton, "Working...")
				local success, result = pcall(function()
					return rebirthRemote:InvokeServer()
				end)

				if not success then
					warn("[UIController] Rebirth request failed:", result)
					setButtonText(confirmButton, "Failed")
					task.delay(0.8, refreshRebirthUI)
					return
				end

				if type(result) == "table" and result.Success == true then
					refreshRebirthUI()
				else
					setButtonText(confirmButton, "Need Coins")
					task.delay(0.8, refreshRebirthUI)
				end
			end)
		end

		rebirthPanel:GetPropertyChangedSignal("Visible"):Connect(function()
			if isApplyingRebirthVisible then return end
			if rebirthPanel.Visible then
				refreshRebirthUI()
			end
		end)

		for _, attrName in ipairs({ "Coins", "RebirthCount", "CoinGainBonus" }) do
			player:GetAttributeChangedSignal(attrName):Connect(function()
				if rebirthPanel.Visible then
					refreshRebirthUI()
				end
			end)
		end
	end

	local function setupInstantCoinsUI()
		local playerGui = player:WaitForChild("PlayerGui")
		local mainUI = playerGui:WaitForChild("MainUI", 5)
		if not mainUI then return end

		local instantCoins = mainUI:FindFirstChild("InstantCoins")
		if not instantCoins or not instantCoins:IsA("GuiObject") then
			warn("[UIController] Instant coin UI missing: MainUI/InstantCoins.")
			return
		end

		local remotes = ReplicatedStorage:WaitForChild("Remotes", 5)
		local getInstantCoinProducts = remotes and remotes:WaitForChild("GetInstantCoinProducts", 5)
		if not getInstantCoinProducts or not getInstantCoinProducts:IsA("RemoteFunction") then
			warn("[UIController] GetInstantCoinProducts RemoteFunction is not ready.")
			return
		end

		local petBagConfig = Controllers.Config.PET_BAG_UI or {}
		local productsByUiName = {}
		local promptInProgress = false

		local function applyHover(guiObject)
			if not guiObject or not guiObject:IsA("GuiObject") then return end
			if guiObject:GetAttribute("InstantCoinHoverBound") then return end
			guiObject:SetAttribute("InstantCoinHoverBound", true)

			local hoverScale = guiObject:FindFirstChild("InstantCoinHoverScale")
			if not hoverScale then
				hoverScale = Instance.new("UIScale")
				hoverScale.Name = "InstantCoinHoverScale"
				hoverScale.Parent = guiObject
			end

			local normalScale = hoverScale.Scale
			local targetScale = petBagConfig.OpenButtonHoverScale or 1.06
			local tweenInfo = TweenInfo.new(
				petBagConfig.HoverTweenTime or 0.12,
				Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out
			)

			local function play(scale)
				TweenService:Create(hoverScale, tweenInfo, { Scale = scale }):Play()
			end

			guiObject.MouseEnter:Connect(function()
				play(targetScale)
			end)
			guiObject.MouseLeave:Connect(function()
				play(normalScale)
			end)
			if guiObject:IsA("GuiButton") then
				guiObject.Activated:Connect(function()
					play(normalScale)
				end)
			end
		end

		local function setInstantCoinsVisible()
			instantCoins.Visible = player:GetAttribute("InCombat") ~= true
		end

		local function refreshInstantCoinProducts()
			local ok, snapshot = pcall(function()
				return getInstantCoinProducts:InvokeServer()
			end)
			if not ok or type(snapshot) ~= "table" or type(snapshot.Products) ~= "table" then
				warn("[UIController] Failed to load instant coin products:", snapshot)
				return
			end

			productsByUiName = {}
			for _, product in ipairs(snapshot.Products) do
				if type(product) == "table" and type(product.UiName) == "string" then
					productsByUiName[product.UiName] = product
				end
			end

			local formatNumber = Controllers.Config.FormatNumber or tostring
			for index = 1, 3 do
				local item = instantCoins:FindFirstChild("Instant-" .. tostring(index))
				if item and item:IsA("GuiObject") then
					local product = productsByUiName[item.Name]
					local buyButton = item:FindFirstChild("Buy", true)
					local priceText = findTextNode(item, { "Price" })
					local amount = product and math.max(0, math.floor(tonumber(product.Amount) or 0)) or 0
					local productId = product and math.floor(tonumber(product.ProductId) or 0) or 0

					item:SetAttribute("ProductId", productId)
					item:SetAttribute("CoinAmount", amount)
					if buyButton then
						buyButton:SetAttribute("ProductId", productId)
						buyButton:SetAttribute("CoinAmount", amount)
					end
					if priceText then
						priceText.Text = "+$" .. formatNumber(amount)
					end
					if buyButton and buyButton:IsA("GuiButton") then
						buyButton.AutoButtonColor = productId > 0
						applyHover(buyButton)
					end
				end
			end
		end

		for index = 1, 3 do
			local item = instantCoins:FindFirstChild("Instant-" .. tostring(index))
			local buyButton = item and item:FindFirstChild("Buy", true)
			if buyButton and buyButton:IsA("GuiButton") then
				buyButton.Activated:Connect(function()
					if promptInProgress then return end

					local productId = math.floor(tonumber(buyButton:GetAttribute("ProductId")) or 0)
					if productId <= 0 then
						warn("[UIController] Instant coin ProductId is not configured for", item and item.Name or "unknown")
						return
					end

					promptInProgress = true
					MarketplaceService:PromptProductPurchase(player, productId)
					task.delay(1, function()
						promptInProgress = false
					end)
				end)
			end
		end

		MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId)
			if userId ~= player.UserId then return end
			promptInProgress = false
			task.delay(0.5, refreshInstantCoinProducts)
		end)

		setInstantCoinsVisible()
		refreshInstantCoinProducts()

		player:GetAttributeChangedSignal("InCombat"):Connect(setInstantCoinsVisible)
		for _, attrName in ipairs({ "Coins", "MaxCoinsHeld" }) do
			player:GetAttributeChangedSignal(attrName):Connect(function()
				refreshInstantCoinProducts()
			end)
		end
	end

	local function setupStarterPackUI()
		local playerGui = player:WaitForChild("PlayerGui")
		local mainUI = playerGui:WaitForChild("MainUI", 5)
		if not mainUI then return end

		local function waitForNamedDescendant(root, name, timeoutSeconds)
			if not root then return nil end

			local function normalizeName(value)
				if type(value) ~= "string" then
					return ""
				end
				return string.match(value, "^%s*(.-)%s*$") or value
			end

			local function findByTrimmedName()
				for _, descendant in ipairs(root:GetDescendants()) do
					if normalizeName(descendant.Name) == name then
						return descendant
					end
				end
				return nil
			end

			local existing = root:FindFirstChild(name, true)
			if existing then
				return existing
			end
			existing = findByTrimmedName()
			if existing then
				return existing
			end

			local found = nil
			local connection = root.DescendantAdded:Connect(function(descendant)
				if descendant.Name == name or normalizeName(descendant.Name) == name then
					found = descendant
				end
			end)

			local expiresAt = os.clock() + (timeoutSeconds or 5)
			while not found and os.clock() < expiresAt do
				task.wait(0.1)
				found = root:FindFirstChild(name, true)
				if not found then
					found = findByTrimmedName()
				end
			end

			connection:Disconnect()
			return found
		end

		local function listChildNames(root)
			if not root then
				return "none"
			end

			local names = {}
			for _, child in ipairs(root:GetChildren()) do
				table.insert(names, child.Name .. ":" .. child.ClassName)
				if #names >= 12 then
					table.insert(names, "...")
					break
				end
			end

			if #names == 0 then
				return "none"
			end
			return table.concat(names, ", ")
		end

		local buttonRoot = waitForNamedDescendant(mainUI, "MainUI_2", 8)
		local openButton = buttonRoot and waitForNamedDescendant(buttonRoot, "BtnStarterPack", 8)
		if not openButton then
			openButton = waitForNamedDescendant(mainUI, "BtnStarterPack", 2)
		end
		local starterPackPanel = waitForNamedDescendant(mainUI, "StarterPackPanel", 8)
		if not openButton or not openButton:IsA("GuiButton") or not starterPackPanel or not starterPackPanel:IsA("GuiObject") then
			local issues = {}
			if not buttonRoot then
				table.insert(issues, "MainUI_2 not found under " .. mainUI:GetFullName())
			elseif not openButton then
				table.insert(issues, "BtnStarterPack not found under " .. buttonRoot:GetFullName() .. "; children=[" .. listChildNames(buttonRoot) .. "]")
			elseif not openButton:IsA("GuiButton") then
				table.insert(issues, "BtnStarterPack must be ImageButton/TextButton, got " .. openButton.ClassName .. " at " .. openButton:GetFullName())
			end

			if not starterPackPanel then
				table.insert(issues, "StarterPackPanel not found under " .. mainUI:GetFullName())
			elseif not starterPackPanel:IsA("GuiObject") then
				table.insert(issues, "StarterPackPanel must be a GuiObject, got " .. starterPackPanel.ClassName .. " at " .. starterPackPanel:GetFullName())
			end

			warn("[UIController] Starter Pack UI missing/invalid:", table.concat(issues, "; "))
			return
		end

		local purchaseButton = waitForNamedDescendant(starterPackPanel, "BtnClaim", 2)
		if not purchaseButton or not purchaseButton:IsA("GuiButton") then
			local found = waitForNamedDescendant(starterPackPanel, "BtnClaim", 0)
			local detail = found and (found.ClassName .. " at " .. found:GetFullName()) or ("not found under " .. starterPackPanel:GetFullName())
			warn("[UIController] Starter Pack UI missing/invalid: StarterPackPanel/BtnClaim must be ImageButton/TextButton, got " .. detail)
			return
		end

		local remotes = ReplicatedStorage:WaitForChild("Remotes", 5)
		local getStarterPackStatus = remotes and remotes:WaitForChild("GetStarterPackStatus", 5)
		if not getStarterPackStatus or not getStarterPackStatus:IsA("RemoteFunction") then
			warn("[UIController] GetStarterPackStatus RemoteFunction is not ready.")
			return
		end
		local claimStarterPackGamePass = remotes and remotes:WaitForChild("ClaimStarterPackGamePass", 5)
		if claimStarterPackGamePass and not claimStarterPackGamePass:IsA("RemoteFunction") then
			warn("[UIController] ClaimStarterPackGamePass exists but is not a RemoteFunction.")
			claimStarterPackGamePass = nil
		end
		local starterPackGranted = remotes and remotes:WaitForChild("StarterPackGranted", 5)
		if starterPackGranted and not starterPackGranted:IsA("RemoteEvent") then
			warn("[UIController] StarterPackGranted exists but is not a RemoteEvent.")
			starterPackGranted = nil
		end

		local petBagConfig = Controllers.Config.PET_BAG_UI or {}
		local promptInProgress = false
		local lastStatus = nil
		local shownStarterPackPurchaseIds = {}

		local function applyHover(guiObject, attributeName, scaleName, targetScale)
			if not guiObject or not guiObject:IsA("GuiObject") then return end
			if guiObject:GetAttribute(attributeName) then return end
			guiObject:SetAttribute(attributeName, true)

			local hoverScale = guiObject:FindFirstChild(scaleName)
			if not hoverScale then
				hoverScale = Instance.new("UIScale")
				hoverScale.Name = scaleName
				hoverScale.Parent = guiObject
			end

			local normalScale = hoverScale.Scale
			local tweenInfo = TweenInfo.new(
				petBagConfig.HoverTweenTime or 0.12,
				Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out
			)

			local function play(scale)
				TweenService:Create(hoverScale, tweenInfo, { Scale = scale }):Play()
			end

			guiObject.MouseEnter:Connect(function()
				play(targetScale or 1.06)
			end)
			guiObject.MouseLeave:Connect(function()
				play(normalScale)
			end)
			if guiObject:IsA("GuiButton") then
				guiObject.Activated:Connect(function()
					play(normalScale)
				end)
			end
		end

		local function isStarterPackPurchased()
			return player:GetAttribute("StarterPackPurchased") == true
				or (type(lastStatus) == "table" and lastStatus.Purchased == true)
		end

		local function setStarterPackVisible()
			local shouldShowButton = player:GetAttribute("InCombat") ~= true and not isStarterPackPurchased()
			openButton.Visible = shouldShowButton
			if not shouldShowButton then
				starterPackPanel.Visible = false
			end
		end

		local closeButton = waitForNamedDescendant(starterPackPanel, "BtnClose", 0)
		local rewardPanel = waitForNamedDescendant(mainUI, "StarterPackRewardPanel", 0)
		local refreshStarterPackStatus

		local function showStarterPackReward(payload)
			payload = type(payload) == "table" and payload or {}
			local purchaseId = tostring(payload.PurchaseId or "")
			if purchaseId ~= "" and shownStarterPackPurchaseIds[purchaseId] then
				return
			end
			if purchaseId ~= "" then
				shownStarterPackPurchaseIds[purchaseId] = true
			end

			openButton.Visible = false
			starterPackPanel.Visible = false
			if rewardPanel and rewardPanel:IsA("GuiObject") then
				rewardPanel.Visible = false
			end
		end

		local function claimStarterPackGamePassReward()
			if not claimStarterPackGamePass then
				warn("[UIController] ClaimStarterPackGamePass RemoteFunction is not ready.")
				return false
			end

			local success, result = pcall(function()
				return claimStarterPackGamePass:InvokeServer()
			end)
			if not success or type(result) ~= "table" then
				warn("[UIController] Failed to claim starter pack game pass:", result)
				return false
			end

			if result.Success == true or result.Purchased == true then
				showStarterPackReward({
					PurchaseId = "gamepass-claim",
				})
				task.delay(0.2, refreshStarterPackStatus)
				return true
			end

			warn("[UIController] Starter pack game pass claim rejected:", result.Reason or "Unknown")
			task.delay(0.2, refreshStarterPackStatus)
			return false
		end

		refreshStarterPackStatus = function()
			local success, status = pcall(function()
				return getStarterPackStatus:InvokeServer()
			end)
			if not success or type(status) ~= "table" then
				warn("[UIController] Failed to load starter pack status:", status)
				return
			end

			lastStatus = status
			local productId = math.max(0, math.floor(tonumber(status.ProductId) or 0))
			local purchaseType = tostring(status.PurchaseType or (status.IsGamePass and "GamePass" or "DeveloperProduct"))
			local dataLoaded = status.DataLoaded == true
			local purchased = status.Purchased == true
			local canBuy = dataLoaded and productId > 0 and not purchased

			purchaseButton:SetAttribute("ProductId", productId)
			purchaseButton:SetAttribute("StarterPackPurchaseType", purchaseType)
			purchaseButton:SetAttribute("StarterPackOwnsGamePass", status.OwnsGamePass == true)
			purchaseButton:SetAttribute("StarterPackCanBuy", canBuy)
			purchaseButton:SetAttribute("StarterPackPurchased", purchased)

			if purchased then
				openButton.Visible = false
				starterPackPanel.Visible = false
				if rewardPanel and rewardPanel:IsA("GuiObject") then
					rewardPanel.Visible = false
				end
			else
				setStarterPackVisible()
			end
		end

		local function setStarterPackOpen(isOpen)
			starterPackPanel.Visible = isOpen
			if isOpen then
				refreshStarterPackStatus()
			end
		end

		starterPackPanel.Visible = false
		setStarterPackVisible()
		refreshStarterPackStatus()

		applyHover(openButton, "StarterPackOpenHoverBound", "StarterPackOpenHoverScale", petBagConfig.OpenButtonHoverScale or 1.06)
		openButton.Activated:Connect(function()
			if isStarterPackPurchased() then
				setStarterPackVisible()
				return
			end
			setStarterPackOpen(true)
		end)

		if closeButton and closeButton:IsA("GuiButton") then
			applyHover(closeButton, "StarterPackCloseHoverBound", "StarterPackCloseHoverScale", petBagConfig.CloseButtonHoverScale or 1.06)
			closeButton.Activated:Connect(function()
				setStarterPackOpen(false)
			end)
		else
			warn("[UIController] Starter Pack UI missing/invalid: StarterPackPanel/BtnClose must be ImageButton/TextButton.")
		end

		if rewardPanel and rewardPanel:IsA("GuiObject") then
			rewardPanel.Visible = false
		end

		purchaseButton.Activated:Connect(function()
			if promptInProgress then return end
			if not lastStatus then
				refreshStarterPackStatus()
			end

			local productId = math.max(0, math.floor(tonumber(purchaseButton:GetAttribute("ProductId")) or 0))
			if purchaseButton:GetAttribute("StarterPackCanBuy") ~= true or productId <= 0 then
				refreshStarterPackStatus()
				return
			end

			promptInProgress = true
			local purchaseType = tostring(purchaseButton:GetAttribute("StarterPackPurchaseType") or "DeveloperProduct")
			if purchaseType == "GamePass" then
				if purchaseButton:GetAttribute("StarterPackOwnsGamePass") == true then
					promptInProgress = false
					claimStarterPackGamePassReward()
					return
				end

				print("[UIController][StarterPack] PromptGamePassPurchase GamePassId:", productId)
				MarketplaceService:PromptGamePassPurchase(player, productId)
			else
				print("[UIController][StarterPack] PromptProductPurchase ProductId:", productId)
				MarketplaceService:PromptProductPurchase(player, productId)
			end
			task.delay(1, function()
				promptInProgress = false
			end)
		end)

		MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId)
			if userId ~= player.UserId then return end
			local starterProductId = math.max(0, math.floor(tonumber(purchaseButton:GetAttribute("ProductId")) or 0))
			if starterProductId > 0 and productId ~= starterProductId then
				return
			end

			promptInProgress = false
			task.delay(0.6, function()
				refreshStarterPackStatus()
			end)
		end)

		MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(promptPlayerOrGamePassId, gamePassIdOrPurchased, wasPurchasedOrNil)
			local promptUserId = nil
			local finishedGamePassId = nil
			local wasPurchased = nil
			if typeof(promptPlayerOrGamePassId) == "Instance" and promptPlayerOrGamePassId:IsA("Player") then
				promptUserId = promptPlayerOrGamePassId.UserId
				finishedGamePassId = gamePassIdOrPurchased
				wasPurchased = wasPurchasedOrNil
			elseif wasPurchasedOrNil == nil then
				finishedGamePassId = promptPlayerOrGamePassId
				wasPurchased = gamePassIdOrPurchased
			else
				promptUserId = tonumber(promptPlayerOrGamePassId)
				finishedGamePassId = gamePassIdOrPurchased
				wasPurchased = wasPurchasedOrNil
			end
			if promptUserId and promptUserId ~= player.UserId then return end

			local starterGamePassId = math.max(0, math.floor(tonumber(purchaseButton:GetAttribute("ProductId")) or 0))
			if starterGamePassId > 0 and tonumber(finishedGamePassId) ~= starterGamePassId then
				return
			end

			promptInProgress = false
			if wasPurchased == true then
				task.delay(0.6, function()
					if not claimStarterPackGamePassReward() then
						task.delay(2, claimStarterPackGamePassReward)
					end
				end)
			else
				task.delay(0.2, refreshStarterPackStatus)
			end
		end)

		if starterPackGranted then
			starterPackGranted.OnClientEvent:Connect(function(payload)
				showStarterPackReward(payload)
				task.delay(0.2, refreshStarterPackStatus)
			end)
		end

		player:GetAttributeChangedSignal("InCombat"):Connect(setStarterPackVisible)
		for _, attrName in ipairs({ "PlayerDataLoaded", "StarterPackPurchased", "Coins", "OwnedPets_JSON", "RebirthCount", "CoinGainBonus" }) do
			player:GetAttributeChangedSignal(attrName):Connect(function()
				if attrName == "StarterPackPurchased" and player:GetAttribute("StarterPackPurchased") == true then
					openButton.Visible = false
					starterPackPanel.Visible = false
					if rewardPanel and rewardPanel:IsA("GuiObject") then
						rewardPanel.Visible = false
					end
					return
				end
				setStarterPackVisible()
				if starterPackPanel.Visible then
					refreshStarterPackStatus()
				end
			end)
		end
	end

	local function setupInviteUI()
		local playerGui = player:WaitForChild("PlayerGui")
		local mainUI = playerGui:WaitForChild("MainUI", 5)
		if not mainUI then return end

		local buttonRoot = mainUI:FindFirstChild("MainUI_2")
		local inviteButton = buttonRoot and buttonRoot:FindFirstChild("BtnInvite")
		if not inviteButton then
			inviteButton = mainUI:FindFirstChild("BtnInvite", true)
		end
		if not inviteButton or not inviteButton:IsA("GuiButton") then
			warn("[UIController] Invite UI missing: MainUI/MainUI_2/BtnInvite.")
			return
		end

		local remotes = ReplicatedStorage:WaitForChild("Remotes", 5)
		local getInviteLaunchData = remotes and remotes:WaitForChild("GetInviteLaunchData", 5)
		if not getInviteLaunchData or not getInviteLaunchData:IsA("RemoteFunction") then
			warn("[UIController] GetInviteLaunchData RemoteFunction is not ready.")
			return
		end

		local promptInProgress = false
		local promptCooldownUntil = 0
		local INVITE_PROMPT_COOLDOWN = 5
		local petBagConfig = Controllers.Config.PET_BAG_UI or {}

		local function setInviteButtonBusy(isBusy)
			inviteButton:SetAttribute("InvitePromptBusy", isBusy == true)
			inviteButton.AutoButtonColor = isBusy ~= true
		end

		local function applyHover(guiObject)
			if not guiObject or not guiObject:IsA("GuiObject") then return end
			if guiObject:GetAttribute("InviteHoverBound") then return end
			guiObject:SetAttribute("InviteHoverBound", true)

			local hoverScale = guiObject:FindFirstChild("InviteHoverScale")
			if not hoverScale then
				hoverScale = Instance.new("UIScale")
				hoverScale.Name = "InviteHoverScale"
				hoverScale.Parent = guiObject
			end

			local normalScale = hoverScale.Scale
			local tweenInfo = TweenInfo.new(
				petBagConfig.HoverTweenTime or 0.12,
				Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out
			)

			local function play(scale)
				TweenService:Create(hoverScale, tweenInfo, { Scale = scale }):Play()
			end

			guiObject.MouseEnter:Connect(function()
				play(petBagConfig.OpenButtonHoverScale or 1.06)
			end)
			guiObject.MouseLeave:Connect(function()
				play(normalScale)
			end)
			guiObject.Activated:Connect(function()
				play(normalScale)
			end)
		end

		local function showNotice(text)
			local noticeUI = mainUI:FindFirstChild("Notice_UI", true)
			local noticeButton = noticeUI and noticeUI:FindFirstChild("Notice_button", true)
			if noticeButton and (noticeButton:IsA("TextLabel") or noticeButton:IsA("TextButton")) then
				noticeButton.Text = tostring(text or "")
			end

			if noticeUI and noticeUI:IsA("GuiObject") then
				noticeUI.Visible = true
				task.delay(3, function()
					if noticeUI then
						noticeUI.Visible = false
					end
				end)
			else
				warn("[UIController][Invite]", text)
			end
		end

		applyHover(inviteButton)

		inviteButton.Activated:Connect(function()
			if promptInProgress or os.clock() < promptCooldownUntil then return end

			promptInProgress = true
			promptCooldownUntil = os.clock() + INVITE_PROMPT_COOLDOWN
			setInviteButtonBusy(true)

			task.delay(INVITE_PROMPT_COOLDOWN, function()
				if os.clock() >= promptCooldownUntil then
					promptInProgress = false
					setInviteButtonBusy(false)
				end
			end)

			local success, invitePayload = pcall(function()
				return getInviteLaunchData:InvokeServer()
			end)

			if not success or type(invitePayload) ~= "table" or invitePayload.Success ~= true then
				promptInProgress = false
				promptCooldownUntil = 0
				setInviteButtonBusy(false)
				warn("[UIController] Failed to get invite launch data:", invitePayload)
				showNotice("Invite is unavailable.")
				return
			end

			local canPrompt = true
			local canSuccess, canResult = pcall(function()
				return SocialService:CanSendGameInviteAsync(player)
			end)
			if canSuccess then
				canPrompt = canResult == true
			end
			if not canPrompt then
				promptInProgress = false
				promptCooldownUntil = 0
				setInviteButtonBusy(false)
				showNotice("Invite is unavailable.")
				return
			end

			local options = nil
			local optionSuccess, optionResult = pcall(function()
				local inviteOptions = Instance.new("ExperienceInviteOptions")
				inviteOptions.LaunchData = tostring(invitePayload.LaunchData or "")
				if type(invitePayload.PromptMessage) == "string" and invitePayload.PromptMessage ~= "" then
					pcall(function()
						inviteOptions.PromptMessage = invitePayload.PromptMessage
					end)
				end
				return inviteOptions
			end)
			if optionSuccess then
				options = optionResult
			end

			local promptSuccess, promptError = pcall(function()
				SocialService:PromptGameInvite(player, options)
			end)

			if not promptSuccess then
				promptInProgress = false
				promptCooldownUntil = 0
				setInviteButtonBusy(false)
				warn("[UIController] PromptGameInvite failed:", promptError)
				showNotice("Invite is unavailable.")
			end
		end)

		local inviteRewardGranted = remotes:FindFirstChild("InviteRewardGranted")
		if inviteRewardGranted and inviteRewardGranted:IsA("RemoteEvent") then
			inviteRewardGranted.OnClientEvent:Connect(function(payload)
				local bonus = type(payload) == "table" and tonumber(payload.Bonus) or nil
				local bonusPercent = bonus and math.floor(bonus * 100 + 0.5) or 50
				showNotice("Invite reward received! Coin Bonus +" .. tostring(bonusPercent) .. "% next run.")
			end)
		end
	end

	local function setupSocialRewardUI()
		local playerGui = player:WaitForChild("PlayerGui")
		local mainUI = playerGui:WaitForChild("MainUI", 5)
		if not mainUI then return end

		local function normalizeName(value)
			if type(value) ~= "string" then
				return ""
			end
			return string.match(value, "^%s*(.-)%s*$") or value
		end

		local function findNamedDescendant(root, name, timeoutSeconds)
			if not root then return nil end

			local function findOnce()
				if normalizeName(root.Name) == name then
					return root
				end

				local direct = root:FindFirstChild(name, true)
				if direct then
					return direct
				end

				for _, descendant in ipairs(root:GetDescendants()) do
					if normalizeName(descendant.Name) == name then
						return descendant
					end
				end

				return nil
			end

			local found = findOnce()
			local expiresAt = os.clock() + math.max(0, tonumber(timeoutSeconds) or 0)
			while not found and os.clock() < expiresAt do
				task.wait(0.1)
				found = findOnce()
			end

			return found
		end

		local function listChildNames(root)
			if not root then
				return "none"
			end

			local names = {}
			for _, child in ipairs(root:GetChildren()) do
				table.insert(names, child.Name .. ":" .. child.ClassName)
				if #names >= 12 then
					table.insert(names, "...")
					break
				end
			end

			if #names == 0 then
				return "none"
			end

			return table.concat(names, ", ")
		end

		local function describeNode(node)
			if not node then
				return "not found"
			end

			return node.ClassName .. " at " .. node:GetFullName()
		end

		local function showNotice(text)
			local noticeUI = mainUI:FindFirstChild("Notice_UI", true)
			local noticeButton = noticeUI and noticeUI:FindFirstChild("Notice_button", true)
			if noticeButton and (noticeButton:IsA("TextLabel") or noticeButton:IsA("TextButton")) then
				noticeButton.Text = tostring(text or "")
			end

			if noticeUI and noticeUI:IsA("GuiObject") then
				noticeUI.Visible = true
				task.delay(3, function()
					if noticeUI then
						noticeUI.Visible = false
					end
				end)
			else
				warn("[UIController][SocialReward]", text)
			end
		end

		local function applyHover(guiObject, attributeName, scaleName, targetScale)
			if not guiObject or not guiObject:IsA("GuiObject") then return end
			if guiObject:GetAttribute(attributeName) then return end
			guiObject:SetAttribute(attributeName, true)

			local hoverScale = guiObject:FindFirstChild(scaleName)
			if not hoverScale then
				hoverScale = Instance.new("UIScale")
				hoverScale.Name = scaleName
				hoverScale.Parent = guiObject
			end

			local normalScale = hoverScale.Scale
			local petBagConfig = Controllers.Config.PET_BAG_UI or {}
			local tweenInfo = TweenInfo.new(
				petBagConfig.HoverTweenTime or 0.12,
				Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out
			)

			local function play(scale)
				TweenService:Create(hoverScale, tweenInfo, { Scale = scale }):Play()
			end

			guiObject.MouseEnter:Connect(function()
				play(targetScale or 1.06)
			end)
			guiObject.MouseLeave:Connect(function()
				play(normalScale)
			end)
			if guiObject:IsA("GuiButton") then
				guiObject.Activated:Connect(function()
					play(normalScale)
				end)
			end
		end

		local buttonRoot = findNamedDescendant(mainUI, "MainUI_2", 8)
		local openButton = buttonRoot and findNamedDescendant(buttonRoot, "BtnFreeReward", 8)
		if not openButton then
			openButton = findNamedDescendant(mainUI, "BtnFreeReward", 2)
		end

		local freeRewardPanel = findNamedDescendant(mainUI, "FreeRewardPanel", 0)
		local claimButton = freeRewardPanel and findNamedDescendant(freeRewardPanel, "BtnClaim", 0)
		local closeButton = freeRewardPanel and findNamedDescendant(freeRewardPanel, "BtnClose", 0)

		if not openButton or not openButton:IsA("GuiButton") then
			local issues = {}
			if not buttonRoot then
				table.insert(issues, "MainUI_2 not found under " .. mainUI:GetFullName() .. "; children=[" .. listChildNames(mainUI) .. "]")
			end
			if not openButton then
				table.insert(issues, "BtnFreeReward not found; MainUI_2 children=[" .. listChildNames(buttonRoot) .. "]")
			elseif not openButton:IsA("GuiButton") then
				table.insert(issues, "BtnFreeReward must be ImageButton/TextButton, got " .. describeNode(openButton))
			end

			warn("[UIController] Free Reward UI missing/invalid:", table.concat(issues, "; "))
			return
		end

		if freeRewardPanel and not freeRewardPanel:IsA("GuiObject") then
			warn("[UIController] FreeRewardPanel ignored because it is not a GuiObject:", describeNode(freeRewardPanel))
			freeRewardPanel = nil
			claimButton = nil
			closeButton = nil
		end
		if claimButton and not claimButton:IsA("GuiButton") then
			warn("[UIController] FreeRewardPanel/BtnClaim ignored because it is not a GuiButton:", describeNode(claimButton))
			claimButton = nil
		end
		if closeButton and not closeButton:IsA("GuiButton") then
			warn("[UIController] FreeRewardPanel/BtnClose ignored because it is not a GuiButton:", describeNode(closeButton))
			closeButton = nil
		end

		local remotes = ReplicatedStorage:WaitForChild("Remotes", 5)
		local getSocialRewardStatus = remotes and remotes:WaitForChild("GetSocialRewardStatus", 5)
		local claimSocialReward = remotes and remotes:WaitForChild("ClaimSocialReward", 5)
		if not getSocialRewardStatus or not getSocialRewardStatus:IsA("RemoteFunction") then
			warn("[UIController] GetSocialRewardStatus RemoteFunction is not ready.")
			return
		end
		if not claimSocialReward or not claimSocialReward:IsA("RemoteFunction") then
			warn("[UIController] ClaimSocialReward RemoteFunction is not ready.")
			return
		end

		local lastStatus = nil
		local claimInProgress = false
		local autoJoinPromptShown = false
		local autoJoinPromptInProgress = false
		local lobbyJoinPromptToken = 0

		local function isClaimed()
			return player:GetAttribute("SocialRewardClaimed") == true
				or (type(lastStatus) == "table" and lastStatus.Claimed == true)
		end

		local function setSocialRewardVisible()
			local shouldShow = player:GetAttribute("InCombat") ~= true and not isClaimed()
			openButton.Visible = shouldShow
			if freeRewardPanel and not shouldShow then
				freeRewardPanel.Visible = false
			end
		end

		local function refreshStatus()
			local success, status = pcall(function()
				return getSocialRewardStatus:InvokeServer()
			end)
			if not success or type(status) ~= "table" then
				warn("[UIController] Failed to load social reward status:", status)
				return nil
			end

			lastStatus = status
			setSocialRewardVisible()
			return status
		end

		local function isJoinedMembershipStatus(status)
			return status == Enum.GroupMembershipStatus.Joined
				or status == Enum.GroupMembershipStatus.AlreadyMember
		end

		local function promptJoinCommunityIfNeeded(forcePrompt, knownStatus)
			forcePrompt = forcePrompt == true
			if autoJoinPromptInProgress then
				return nil
			end
			if not forcePrompt and autoJoinPromptShown then
				return nil
			end
			if player:GetAttribute("InCombat") == true then
				return nil
			end

			local status = knownStatus
			if type(status) ~= "table" then
				status = refreshStatus()
			end
			if type(status) ~= "table" then
				return nil
			end
			if status.Claimed == true or status.RequireCommunity ~= true then
				return nil
			end
			if status.GroupConfigured ~= true then
				warn("[UIController][SocialReward] CommunityGroupId is not configured; auto join prompt skipped.")
				return nil
			end
			if status.IsInCommunity == true then
				return Enum.GroupMembershipStatus.AlreadyMember
			end

			local groupId = math.max(0, math.floor(tonumber(status.CommunityGroupId) or 0))
			if groupId <= 0 then
				return nil
			end

			if not forcePrompt then
				autoJoinPromptShown = true
			end
			autoJoinPromptInProgress = true

			local success, promptResult = pcall(function()
				return GroupService:PromptJoinAsync(groupId)
			end)

			autoJoinPromptInProgress = false
			if not success then
				if not forcePrompt then
					autoJoinPromptShown = false
				end
				warn("[UIController][SocialReward] PromptJoinAsync failed:", promptResult)
				showNotice("Join the community first.")
				return nil
			end

			if isJoinedMembershipStatus(promptResult) then
				task.delay(0.5, refreshStatus)
			elseif promptResult == Enum.GroupMembershipStatus.JoinRequestPending then
				showNotice("Join request sent. Tap the reward again after approval.")
				task.delay(2, refreshStatus)
			else
				showNotice("Join the community first.")
				task.delay(2, refreshStatus)
			end

			return promptResult
		end

		local function scheduleLobbyJoinPrompt()
			lobbyJoinPromptToken += 1
			local token = lobbyJoinPromptToken

			task.delay(5, function()
				if token ~= lobbyJoinPromptToken then
					return
				end
				if player:GetAttribute("InCombat") == true then
					return
				end

				promptJoinCommunityIfNeeded(false)
			end)
		end

		local function getMessageForReason(reason)
			if reason == "NotConfigured" then
				return "Community reward is not ready yet."
			elseif reason == "NotInCommunity" then
				return "Join the community first."
			elseif reason == "AlreadyClaimed" then
				return "Already claimed."
			elseif reason == "DataNotLoaded" then
				return "Data is still loading."
			elseif reason == "Disabled" then
				return "Reward is unavailable."
			end

			return "Cannot claim yet."
		end

		if freeRewardPanel then
			freeRewardPanel.Visible = false
		end
		setSocialRewardVisible()
		refreshStatus()

		applyHover(openButton, "FreeRewardOpenHoverBound", "FreeRewardOpenHoverScale", 1.06)
		applyHover(claimButton, "FreeRewardClaimHoverBound", "FreeRewardClaimHoverScale", 1.04)
		applyHover(closeButton, "FreeRewardCloseHoverBound", "FreeRewardCloseHoverScale", 1.06)

		local function handleClaimResult(result)
			if result.Success == true then
				lastStatus = result.Snapshot
				showNotice("Reward claimed!")
				openButton.Visible = false
				if freeRewardPanel then
					freeRewardPanel.Visible = false
				end
				return true
			end

			lastStatus = result.Snapshot
			if result.Reason == "NotInCommunity" then
				showNotice("Membership is updating. Tap the reward again.")
			else
				showNotice(getMessageForReason(result.Reason))
			end
			setSocialRewardVisible()
			return false
		end

		local function requestClaim()
			local success, result = pcall(function()
				return claimSocialReward:InvokeServer()
			end)

			if not success or type(result) ~= "table" then
				warn("[UIController] ClaimSocialReward failed:", result)
				showNotice("Cannot claim yet.")
				return nil
			end

			return result
		end

		local function handleSocialRewardButtonActivated()
			if claimInProgress then return end
			claimInProgress = true
			if freeRewardPanel then
				freeRewardPanel.Visible = false
			end

			if isClaimed() then
				claimInProgress = false
				setSocialRewardVisible()
				return
			end

			local status = refreshStatus()
			if type(status) ~= "table" then
				claimInProgress = false
				showNotice("Cannot claim yet.")
				return
			end

			if status.CanClaim == true or status.IsInCommunity == true or status.RequireCommunity ~= true then
				local result = requestClaim()
				claimInProgress = false
				if result then
					handleClaimResult(result)
				end
				return
			end

			if status.Reason == "NotInCommunity" then
				local promptResult = promptJoinCommunityIfNeeded(true, status)
				if isJoinedMembershipStatus(promptResult) then
					task.wait(0.5)
					local result = requestClaim()
					if result then
						handleClaimResult(result)
					end
				end
				claimInProgress = false
				return
			end

			claimInProgress = false
			showNotice(getMessageForReason(status.Reason))
			setSocialRewardVisible()
		end

		openButton.Activated:Connect(handleSocialRewardButtonActivated)
		if claimButton then
			claimButton.Activated:Connect(handleSocialRewardButtonActivated)
		end
		if closeButton and freeRewardPanel then
			closeButton.Activated:Connect(function()
				freeRewardPanel.Visible = false
			end)
		end

		player:GetAttributeChangedSignal("InCombat"):Connect(function()
			setSocialRewardVisible()
			if player:GetAttribute("InCombat") == true then
				lobbyJoinPromptToken += 1
			else
				scheduleLobbyJoinPrompt()
			end
		end)
		for _, attrName in ipairs({ "PlayerDataLoaded", "SocialRewardClaimed", "PetDrawTickets", "Coins" }) do
			player:GetAttributeChangedSignal(attrName):Connect(function()
				if attrName == "SocialRewardClaimed" and player:GetAttribute("SocialRewardClaimed") == true then
					openButton.Visible = false
					if freeRewardPanel then
						freeRewardPanel.Visible = false
					end
					return
				end

				setSocialRewardVisible()
				if freeRewardPanel and freeRewardPanel.Visible then
					refreshStatus()
				end
			end)
		end

		if player:GetAttribute("InCombat") ~= true then
			scheduleLobbyJoinPrompt()
		end
	end

	local function setupPetHatching()
		local playerGui = player:WaitForChild("PlayerGui")
		local mainUI = playerGui:WaitForChild("MainUI")
		
		-- 新抽蛋 UI 结构：MainUI.Hatch_Pet_Egg.HatchScreen
		local hatchPetEgg = mainUI:WaitForChild("Hatch_Pet_Egg", 5)
		if not hatchPetEgg then return end

		local hatchScreen = hatchPetEgg:WaitForChild("HatchScreen", 5)
		if not hatchScreen then return end

		local viewport = hatchScreen:WaitForChild("PetViewport")
		local clickArea = hatchScreen:WaitForChild("BtnClickArea")
		local tipText = hatchScreen:WaitForChild("TipText")
		local noticeUI = mainUI:FindFirstChild("Notice_UI", true)
		local noticeButton = noticeUI and noticeUI:FindFirstChild("Notice_button", true)
		
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		local petModels = ReplicatedStorage:WaitForChild("Model"):WaitForChild("Pets")
		local hatchBlurTween = nil
		local isApplyingHatchVisible = false
		local noticeSerial = 0
		local hatchHeader = hatchPetEgg:FindFirstChild("Header", true)
		local hatchEquippedCountText = hatchHeader and hatchHeader:FindFirstChild("Count", true)

		local function showNotice(text, seconds)
			seconds = seconds or 3
			if not noticeUI or not noticeUI:IsA("GuiObject") then
				warn("[UIController] Notice_UI 不存在，提示内容:", text)
				return
			end

			if noticeButton and (noticeButton:IsA("TextLabel") or noticeButton:IsA("TextButton")) then
				noticeButton.Text = tostring(text or "")
			end

			noticeSerial += 1
			local currentSerial = noticeSerial
			noticeUI.Visible = true
			task.delay(seconds, function()
				if currentSerial == noticeSerial and noticeUI then
					noticeUI.Visible = false
				end
			end)
		end

		local function updateHatchPetEggCards()
			if not hatchPetEgg then return end
			local equip1 = hatchPetEgg:FindFirstChild("Equip_1", true)
			local cards = equip1 and equip1:FindFirstChild("Cards", true)
			if cards and (cards:IsA("TextLabel") or cards:IsA("TextButton")) then
				cards.Text = "x" .. tostring(math.max(0, math.floor(player:GetAttribute("PetDrawTickets") or 0)))
			end
		end

		local function decodeHatchEquippedPetUids()
			local success, decoded = pcall(function()
				return HttpService:JSONDecode(player:GetAttribute("EquippedPets_JSON") or "[]")
			end)

			local equippedUids = {}
			local equippedMap = {}
			if success and type(decoded) == "table" then
				for _, uid in ipairs(decoded) do
					if type(uid) == "string" and uid ~= "" and not equippedMap[uid] then
						equippedMap[uid] = true
						table.insert(equippedUids, uid)
					end
				end
			end

			local legacyUid = player:GetAttribute("EquippedPetUid") or ""
			if #equippedUids == 0 and legacyUid ~= "" then
				equippedMap[legacyUid] = true
				table.insert(equippedUids, legacyUid)
			end

			local legacyPetId = player:GetAttribute("EquippedPet") or ""
			if #equippedUids == 0 and legacyPetId ~= "" then
				equippedMap[legacyPetId] = true
				table.insert(equippedUids, legacyPetId)
			end

			return equippedUids
		end

		local function updateHatchEquippedCountText()
			if not hatchEquippedCountText or not hatchEquippedCountText:IsA("TextLabel") then
				return
			end

			local equippedUids = decodeHatchEquippedPetUids()
			local slotUpgradeLevel = math.max(0, math.floor(tonumber(player:GetAttribute("Talent_PET_SLOT")) or 0))
			local maxEquipSlots = 1 + slotUpgradeLevel
			hatchEquippedCountText.Text = tostring(#equippedUids) .. "/" .. tostring(maxEquipSlots)
		end

		local renderIdleEgg
		local setHatchPetEggOpen
		local closeHatchScreen

		local function findFirstGuiButton(root, names)
			if not root then return nil end
			for _, name in ipairs(names) do
				local node = root:FindFirstChild(name, true)
				if node and node:IsA("GuiButton") then
					return node
				end
				if node then
					local nestedButton = node:FindFirstChildWhichIsA("GuiButton", true)
					if nestedButton then
						return nestedButton
					end
				end
			end
			return nil
		end

		-- 获取或创建抽宠专用毛玻璃；放在 Lighting 下作为本地后处理，不会模糊 HatchScreen 本身。
		local function getHatchBlur()
			local blur = Lighting:FindFirstChild("HatchBlur")
			if blur and not blur:IsA("BlurEffect") then
				blur = nil
			end

			if not blur then
				blur = Instance.new("BlurEffect")
				blur.Name = "HatchBlur"
				blur.Size = 0
				blur.Parent = Lighting
			end

			return blur
		end

		-- 抽宠界面复用宠物背包同款背景模糊手感：打开淡入，关闭淡出。
		local function tweenHatchBlur(isOpen)
			local blur = getHatchBlur()
			if hatchBlurTween then
				hatchBlurTween:Cancel()
				hatchBlurTween = nil
			end

			local petBagConfig = Controllers.Config.PET_BAG_UI or {}
			local targetSize = isOpen and (petBagConfig.OpenBlurSize or 14) or 0
			local tweenTime = petBagConfig.OpenBlurTweenTime or 0.18
			hatchBlurTween = TweenService:Create(
				blur,
				TweenInfo.new(tweenTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Size = targetSize }
			)
			hatchBlurTween:Play()
		end
		
		-- ViewportFrame 的摄像机必须用代码动态创建并绑定，不然容易出 Bug
		local camera = Instance.new("Camera")
		camera.FieldOfView = 60
		viewport.CurrentCamera = camera
		
		local clickCount = 0
		local isHatching = false
		local isShowingResult = false
		local current3DModel = nil
		local spinConnection = nil 
		local currentResultPetId = nil
		local currentResultPetLevel = nil
		
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

		local function renderEggModel()
			local eggTemplate = petModels:FindFirstChild("Egg")
			if not eggTemplate then
				warn("[UIController] ReplicatedStorage.Model.Pets 中没有找到 Egg 模型。")
				return false
			end

			current3DModel = eggTemplate:Clone()
			if placeViewportModel(current3DModel, CFrame.new(0, 0, 0)) then
				current3DModel.Parent = viewport
				camera.CFrame = CFrame.lookAt(Vector3.new(0, 2, -6), Vector3.new(0, 0, 0))
				return true
			end

			current3DModel:Destroy()
			current3DModel = nil
			return false
		end

		renderIdleEgg = function()
			clearViewport()
			clickCount = 0
			isShowingResult = false
			currentResultPetId = nil
			currentResultPetLevel = nil
			renderEggModel()
			tipText.Text = "Tap BtnClickArea to hatch the egg!"
			tipText.TextColor3 = Color3.new(1, 1, 1)
		end

		-- 结束抽宠展示并恢复交互状态；任何异常路径都走这里，避免界面卡住。
		closeHatchScreen = function()
			isApplyingHatchVisible = true
			hatchScreen.Visible = false
			isApplyingHatchVisible = false
			tweenHatchBlur(false)
			setMainButtonRootHiddenByPanel(mainUI, "Hatch", false)
			isHatching = false
			isShowingResult = false
			clearViewport()
		end

		setHatchPetEggOpen = function(isOpen)
			if hatchPetEgg and hatchPetEgg:IsA("GuiObject") then
				hatchPetEgg.Visible = isOpen
				if isOpen then
					reportAnalyticsEvent("pet_hatch_open", {
						source = "pet_egg",
						coins = player:GetAttribute("Coins") or 0,
						tickets = player:GetAttribute("PetDrawTickets") or 0,
					})
					updateHatchPetEggCards()
					updateHatchEquippedCountText()
					isApplyingHatchVisible = true
					hatchScreen.Visible = true
					isApplyingHatchVisible = false
					tweenHatchBlur(true)
					setMainButtonRootHiddenByPanel(mainUI, "Hatch", true)
					if not isHatching then
						renderIdleEgg()
					end
				else
					closeHatchScreen()
				end
			end
		end

		-- 兜底处理其他代码直接改 HatchScreen.Visible 的情况，避免毛玻璃残留。
		hatchScreen:GetPropertyChangedSignal("Visible"):Connect(function()
			if isApplyingHatchVisible then return end
			tweenHatchBlur(hatchScreen.Visible)
			setMainButtonRootHiddenByPanel(mainUI, "Hatch", hatchScreen.Visible)
		end)

		-- 真正开始抽宠展示；入口由 Hatch_Pet_Egg.HatchScreen.BtnClickArea 触发。
		local function beginPetDraw()
			if isHatching or isShowingResult then return end

         -- 玩家响应了引导点击抽卡，清除光束！
			player:SetAttribute("NeedsGuide", false)
			Controllers.VFX.ClearGuide("PetGuide")

			local tickets = player:GetAttribute("PetDrawTickets") or 0
			local ticketCost = math.max(1, math.floor(Controllers.Config.PET_DRAW_TICKET_COST or 1))
			if tickets < ticketCost then
				showNotice("缺少抽奖次数", 3)
				return
			end
			
			isHatching = true
			isShowingResult = false
			clearViewport()
			
			local remotes = ReplicatedStorage:WaitForChild("Remotes")
			local ok, resultPet = pcall(function()
				return remotes:WaitForChild("RollPet"):InvokeServer()
			end)
			if not ok then
				warn("[UIController] 宠物抽取 RemoteFunction 调用失败:", resultPet)
				showNotice("抽奖失败，请稍后再试", 3)
				isHatching = false
				renderIdleEgg()
				return
			end

			if not resultPet then
				warn("[UIController] 宠物抽取失败，未收到有效宠物 ID。")
				showNotice("缺少抽奖次数", 3)
				isHatching = false
				renderIdleEgg()
				return
			end
			currentResultPetId = type(resultPet) == "table" and resultPet.Id or resultPet
			currentResultPetLevel = type(resultPet) == "table" and resultPet.Level or (Controllers.Config.PET_LEVEL_MIN or 1)
			if type(currentResultPetId) ~= "string" then
				warn("[UIController] 宠物抽取失败，返回数据缺少 Id。")
				showNotice("抽奖失败，请稍后再试", 3)
				isHatching = false
				renderIdleEgg()
				return
			end
			
			-- 挂载 3D 蛋模型
			renderEggModel()
			
			isApplyingHatchVisible = true
			hatchScreen.Visible = true
			isApplyingHatchVisible = false
			tweenHatchBlur(true)
			setMainButtonRootHiddenByPanel(mainUI, "Hatch", true)
			clickCount = 0
			tipText.Text = "Tap quickly to crack the egg!"
			tipText.TextColor3 = Color3.new(1,1,1)
		end

		local function revealPetResult()
			if isShowingResult then return end
			isShowingResult = true
			isHatching = false
			clearViewport()

			if currentResultPetId then
				local petTemplate = petModels:FindFirstChild(currentResultPetId)
				local petData = Controllers.Config.PETS[currentResultPetId]
				if petTemplate and petData then
					current3DModel = petTemplate:Clone()
					if placeViewportModel(current3DModel, CFrame.new(0, 0, 0)) then
						current3DModel.Parent = viewport
					else
						current3DModel:Destroy()
						current3DModel = nil
					end

					local finalAtk = Controllers.Config.GetPetAttack and Controllers.Config.GetPetAttack(currentResultPetId, currentResultPetLevel) or (petData.ATK or 0)
					tipText.Text = string.format("You got %s Lv.%d (%s) ATK:%s", petData.Name, currentResultPetLevel, petData.Rarity, Controllers.Config.FormatNumber(finalAtk))
					tipText.TextColor3 = petData.Color

					if current3DModel then
						spinConnection = Controllers.VFX.StartPetSpinVFX(current3DModel)
					end
				end
			end

			updateHatchPetEggCards()
			task.delay(3, function()
				if hatchPetEgg.Visible and hatchScreen.Visible then
					renderIdleEgg()
				else
					closeHatchScreen()
				end
			end)
		end

		local function handleHatchClick()
			if isShowingResult then return end
			if not isHatching then
				beginPetDraw()
				return
			end

			clickCount += 1
			Controllers.VFX.PlayEggShakeVFX(current3DModel)
			if clickCount >= 5 then
				revealPetResult()
			end
		end

		-- 宠物蛋 ProximityPrompt 只负责打开 Hatch_Pet_Egg，不直接抽卡。
		local function markPetGuideSeen()
			player:SetAttribute("NeedsPetGuide", false)
			player:SetAttribute("PetGuideUseArrow", false)
			if Controllers and Controllers.VFX then
				Controllers.VFX.ClearGuide("PetGuide")
			end
		end

		local function handlePetEggTriggered(triggeringPlayer)
			if triggeringPlayer ~= player or isHatching then return end
			markPetGuideSeen()
			setHatchPetEggOpen(true)
		end

		local function bindPetEggPrompt(target)
			if not target then return end
			local prompt = target:IsA("ProximityPrompt") and target or target:FindFirstChildWhichIsA("ProximityPrompt", true)
			if not prompt then return end

			if prompt:GetAttribute("ClientPetEggPromptBound") then return end
			prompt:SetAttribute("ClientPetEggPromptBound", true)
			prompt.Triggered:Connect(handlePetEggTriggered)
		end

		player:GetAttributeChangedSignal("PetDrawTickets"):Connect(function()
			updateHatchPetEggCards()
		end)
		for _, attrName in ipairs({ "EquippedPet", "EquippedPetUid", "EquippedPets_JSON", "Talent_PET_SLOT" }) do
			player:GetAttributeChangedSignal(attrName):Connect(function()
				updateHatchEquippedCountText()
			end)
		end

		if hatchPetEgg then
			updateHatchPetEggCards()
			updateHatchEquippedCountText()
			if hatchPetEgg:IsA("GuiObject") and hatchPetEgg.Visible and not isHatching then
				hatchScreen.Visible = true
				setMainButtonRootHiddenByPanel(mainUI, "Hatch", true)
				renderIdleEgg()
			end

			local equip1 = findFirstGuiButton(hatchPetEgg, {"Equip_1"})
			if equip1 and equip1:IsA("GuiButton") and not equip1:GetAttribute("BuyPetDrawTicketBound") then
				equip1:SetAttribute("BuyPetDrawTicketBound", true)
				equip1.Activated:Connect(function()
					local remotes = ReplicatedStorage:WaitForChild("Remotes")
					local buyPetDrawTicket = remotes:WaitForChild("BuyPetDrawTicket")
					local ok, result = pcall(function()
						return buyPetDrawTicket:InvokeServer()
					end)
					if not ok then
						warn("[UIController] 购买抽奖次数失败:", result)
						showNotice("购买失败，请稍后再试", 3)
						return
					end

					if type(result) == "table" and result.Success then
						updateHatchPetEggCards()
						showNotice("购买成功，抽奖次数+1", 3)
					else
						showNotice("钱币不足", 3)
					end
				end)
			end

			if clickArea:IsA("GuiButton") and not clickArea:GetAttribute("PetDrawClickAreaBound") then
				clickArea:SetAttribute("PetDrawClickAreaBound", true)
				clickArea.Activated:Connect(function()
					local ok, err = pcall(handleHatchClick)
					if not ok then
						warn("[UIController] 抽宠点击流程异常:", err)
						showNotice("抽奖失败，请稍后再试", 3)
						isHatching = false
						isShowingResult = false
						renderIdleEgg()
					end
				end)
			end

			local closeButton = findFirstGuiButton(hatchPetEgg, {"CloseButton", "Close", "ExitButton", "BtnClose"})
			if closeButton and not closeButton:GetAttribute("HatchPetEggCloseBound") then
				closeButton:SetAttribute("HatchPetEggCloseBound", true)
				closeButton.Activated:Connect(function()
					setHatchPetEggOpen(false)
				end)
			end
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
      setupAchievementUI()
      setupRebirthUI()
      setupInstantCoinsUI()
      setupStarterPackUI()
      setupInviteUI()
      setupSocialRewardUI()
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
