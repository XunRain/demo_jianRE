-- 角色头顶进度显示服务：由服务端创建 BillboardGui，让所有玩家都能看到彼此的等级进度。
local CharacterStatsManager = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local _Services

local HEAD_OFFSET = Vector3.new(0, 3.5, 0)
local MAX_REPORT_LEVEL = 300
local STATS_SECTION_NAMES = { "BEST_LV_PART_UI", "LV_ATK_PART_UI" }

function CharacterStatsManager.Init(deps)
	_Services = deps
end

local function getOrCreateRemote()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end

	local event = remotes:FindFirstChild("ReportRunStats")
	if not event then
		event = Instance.new("RemoteEvent")
		event.Name = "ReportRunStats"
		event.Parent = remotes
	end

	return event
end

local function getBestDisplayLevel(player)
	return math.max(1, math.floor(player:GetAttribute("BestLevel") or 1))
end

local function getCurrentDisplayLevel(player)
	if player:GetAttribute("RunInCombat") == true then
		return math.max(1, math.floor(player:GetAttribute("CurrentRunLevel") or 1))
	end

	return getBestDisplayLevel(player)
end

local function getCurrentDisplayAttack(player)
	return math.max(0, math.floor(tonumber(player:GetAttribute("CurrentRunAttack") or 0) or 0))
end

-- 头顶 UI 使用两个美术分组：大厅最高等级分组、战斗等级攻击分组。
local function getStatsSections(character)
	local billboard = character and character:FindFirstChild("CharacterStatsUI")
	if not billboard then return nil, nil, nil end

	return billboard,
		billboard:FindFirstChild("BEST_LV_PART_UI", true),
		billboard:FindFirstChild("LV_ATK_PART_UI", true)
end

-- 兼容 Frame/ImageLabel/BillboardGui 等容器；Studio 里可以用 BillboardGui 做分组模板。
local function setSectionVisible(section, visible)
	if not section then return end
	if section:IsA("BillboardGui") then
		section.Enabled = visible
		return
	end
	if section:IsA("GuiObject") then
		section.Visible = visible
		return
	end

	for _, node in ipairs(section:GetDescendants()) do
		if node:IsA("GuiObject") then
			node.Visible = visible
		end
	end
end

local function findTextLabel(root, names)
	if not root then return nil end
	for _, name in ipairs(names) do
		local node = root:FindFirstChild(name, true)
		if node and node:IsA("TextLabel") then
			return node
		end
	end

	return nil
end

local function findStarLevelLabel(root)
	if not root then return nil end

	local imageLabel = root:FindFirstChild("ImageLabel", true)
	local levelLabel = imageLabel and imageLabel:FindFirstChild("TextLabel", true)
	if levelLabel and levelLabel:IsA("TextLabel") then
		return levelLabel
	end

	return findTextLabel(root, { "LevelText", "LevelLabel", "LvText", "TextLabel" })
end

local function updateCharacterStatsText(player)
	local character = player.Character
	local billboard, bestSection, combatSection = getStatsSections(character)
	if not billboard then return end

	local inCombat = player:GetAttribute("RunInCombat") == true

	if bestSection or combatSection then
		setSectionVisible(bestSection, not inCombat)
		setSectionVisible(combatSection, inCombat)

		local bestStatsLabel = findTextLabel(bestSection, { "StatsLabel" })
		local bestLevelLabel = findStarLevelLabel(bestSection)
		if bestStatsLabel then
			bestStatsLabel.Text = "Best.Lv"
		end
		if bestLevelLabel then
			bestLevelLabel.Text = tostring(getBestDisplayLevel(player))
		end

		local combatStatsLabel = findTextLabel(combatSection, { "StatsLabel", "AttackText", "ATKText", "AtkText" })
		local combatLevelLabel = findStarLevelLabel(combatSection)
		if combatStatsLabel then
			combatStatsLabel.Text = "ATK:" .. tostring(getCurrentDisplayAttack(player))
		end
		if combatLevelLabel then
			combatLevelLabel.Text = tostring(getCurrentDisplayLevel(player))
		end

		return
	end

	-- 旧模板兜底：没有双分组时，继续使用单个 StatsLabel + 星星数字。
	local statsLabel = billboard:FindFirstChild("StatsLabel", true)
	if statsLabel and statsLabel:IsA("TextLabel") then
		statsLabel.Text = inCombat and ("ATK:" .. tostring(getCurrentDisplayAttack(player))) or "Best.Lv"
	end

	local levelLabel = findStarLevelLabel(billboard)
	if levelLabel then
		levelLabel.Text = tostring(getCurrentDisplayLevel(player))
	end
end

local function getCharacterStatsTemplate()
	local uiTemplates = ReplicatedStorage:FindFirstChild("UITemplates")
	local template = uiTemplates and uiTemplates:FindFirstChild("CharacterStatsUI")
	if template then
		return template
	end

	local guiFolder = ReplicatedStorage:FindFirstChild("GUI")
	template = guiFolder and guiFolder:FindFirstChild("CharacterStatsUI")
	if template then
		return template
	end

	return nil
end

local function isZeroSize(size)
	return size.X.Scale == 0 and size.X.Offset == 0 and size.Y.Scale == 0 and size.Y.Offset == 0
end

-- 将嵌套的子 BillboardGui 分组转成 Frame；Roblox 不适合用 BillboardGui 嵌套 BillboardGui 来显示。
local function flattenNestedBillboardSections(billboard)
	if not billboard then return end

	for _, sectionName in ipairs(STATS_SECTION_NAMES) do
		local section = billboard:FindFirstChild(sectionName, true)
		if section and section:IsA("BillboardGui") then
			if billboard:IsA("BillboardGui") and isZeroSize(billboard.Size) and not isZeroSize(section.Size) then
				billboard.Size = section.Size
			end

			local frame = Instance.new("Frame")
			frame.Name = section.Name
			frame.BackgroundTransparency = 1
			frame.BorderSizePixel = 0
			frame.AnchorPoint = Vector2.new(0, 0)
			frame.Position = UDim2.fromScale(0, 0)
			frame.Size = UDim2.fromScale(1, 1)
			frame.Visible = section.Enabled
			frame.Parent = section.Parent

			for _, child in ipairs(section:GetChildren()) do
				child:Clone().Parent = frame
			end

			section:Destroy()
		end
	end
end

-- Studio 模板可以是 BillboardGui，也可以只是一个装 UI 子节点的 Folder/Frame；这里统一转成 BillboardGui。
local function createBillboardFromTemplate(template)
	if template and template:IsA("BillboardGui") then
		local billboard = template:Clone()
		flattenNestedBillboardSections(billboard)
		return billboard, true
	end

	local billboard = Instance.new("BillboardGui")
	if template then
		for _, child in ipairs(template:GetChildren()) do
			child:Clone().Parent = billboard
		end
	end
	flattenNestedBillboardSections(billboard)

	return billboard, template ~= nil
end

local function createCharacterStatsUI(player, character)
	local rootPart = character:WaitForChild("HumanoidRootPart", 5)
	if not rootPart then return end

	local oldBillboard = character:FindFirstChild("CharacterStatsUI")
	if oldBillboard then
		oldBillboard:Destroy()
	end

	local template = getCharacterStatsTemplate()
	local billboard, hasTemplate = createBillboardFromTemplate(template)
	billboard.Name = "CharacterStatsUI"
	billboard.Adornee = rootPart
	billboard.Enabled = true
	billboard.AlwaysOnTop = true
	if not hasTemplate or billboard.Size == UDim2.new(0, 0, 0, 0) then
		billboard.Size = UDim2.new(0, 150, 0, 52)
	end
	billboard.StudsOffset = HEAD_OFFSET
	billboard.MaxDistance = 120
	billboard.Parent = character

	if hasTemplate then
		updateCharacterStatsText(player)
		return
	end

	local starImage = Instance.new("ImageLabel")
	starImage.Name = "ImageLabel"
	starImage.BackgroundTransparency = 1
	starImage.AnchorPoint = Vector2.new(0, 0.5)
	starImage.Position = UDim2.fromScale(0, 0.5)
	starImage.Size = UDim2.new(0, 46, 0, 46)
	starImage.Image = ""
	starImage.Parent = billboard

	local levelLabel = Instance.new("TextLabel")
	levelLabel.Name = "TextLabel"
	levelLabel.BackgroundTransparency = 1
	levelLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	levelLabel.Position = UDim2.fromScale(0.5, 0.5)
	levelLabel.Size = UDim2.fromScale(0.72, 0.72)
	levelLabel.Font = Enum.Font.FredokaOne
	levelLabel.TextScaled = true
	levelLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	levelLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	levelLabel.TextStrokeTransparency = 0
	levelLabel.Text = tostring(getBestDisplayLevel(player))
	levelLabel.Parent = starImage

	local statsLabel = Instance.new("TextLabel")
	statsLabel.Name = "StatsLabel"
	statsLabel.BackgroundTransparency = 1
	statsLabel.AnchorPoint = Vector2.new(0, 0.5)
	statsLabel.Position = UDim2.new(0, 48, 0.5, 0)
	statsLabel.Size = UDim2.new(1, -48, 0, 34)
	statsLabel.Font = Enum.Font.FredokaOne
	statsLabel.TextScaled = true
	statsLabel.TextXAlignment = Enum.TextXAlignment.Left
	statsLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	statsLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	statsLabel.TextStrokeTransparency = 0
	statsLabel.Text = "Best.Lv"
	statsLabel.Parent = billboard
end

local function initPlayer(player)
	if player:GetAttribute("BestLevel") == nil then
		player:SetAttribute("BestLevel", 1)
	end
	if player:GetAttribute("CurrentRunLevel") == nil then
		player:SetAttribute("CurrentRunLevel", 1)
	end
	if player:GetAttribute("RunInCombat") == nil then
		player:SetAttribute("RunInCombat", false)
	end
	if player:GetAttribute("CurrentRunAttack") == nil then
		player:SetAttribute("CurrentRunAttack", 0)
	end
	if player:GetAttribute("PendingInviteCoinBonus") == nil then
		player:SetAttribute("PendingInviteCoinBonus", 0)
	end
	if player:GetAttribute("RunInviteCoinBonus") == nil then
		player:SetAttribute("RunInviteCoinBonus", 0)
	end

	player.CharacterAdded:Connect(function(character)
		createCharacterStatsUI(player, character)
	end)

	for _, attrName in ipairs({"BestLevel", "CurrentRunLevel", "CurrentRunAttack", "RunInCombat"}) do
		player:GetAttributeChangedSignal(attrName):Connect(function()
			updateCharacterStatsText(player)
		end)
	end

	if player.Character then
		task.spawn(createCharacterStatsUI, player, player.Character)
	end
end

local function handleReportRunStats(player, isInCombat, level, attack)
	local safeLevel = math.clamp(math.floor(tonumber(level) or 1), 1, MAX_REPORT_LEVEL)
	local safeAttack = math.clamp(math.floor(tonumber(attack) or 0), 0, 999999999)
	local wasInCombat = player:GetAttribute("RunInCombat") == true
	local nextInCombat = isInCombat == true

	player:SetAttribute("RunInCombat", isInCombat == true)
	player:SetAttribute("CurrentRunLevel", safeLevel)
	player:SetAttribute("CurrentRunAttack", safeAttack)

	if _Services and _Services.InviteRewardManager and _Services.InviteRewardManager.HandleRunStateChanged then
		_Services.InviteRewardManager.HandleRunStateChanged(player, wasInCombat, nextInCombat)
	end

	local bestLevel = math.max(1, math.floor(player:GetAttribute("BestLevel") or 1))
	if safeLevel > bestLevel then
		player:SetAttribute("BestLevel", safeLevel)
	end
end

function CharacterStatsManager.Start()
	local reportEvent = getOrCreateRemote()
	reportEvent.OnServerEvent:Connect(handleReportRunStats)

	for _, player in ipairs(Players:GetPlayers()) do
		initPlayer(player)
	end

	Players.PlayerAdded:Connect(initPlayer)
end

return CharacterStatsManager
