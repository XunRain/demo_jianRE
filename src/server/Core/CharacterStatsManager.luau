-- 角色头顶进度显示服务：由服务端创建 BillboardGui，让所有玩家都能看到彼此的等级进度。
local CharacterStatsManager = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local _Services

local HEAD_OFFSET = Vector3.new(0, 3.5, 0)
local MAX_REPORT_LEVEL = 300

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

local function getDisplayLevel(player)
	if player:GetAttribute("RunInCombat") == true then
		return math.max(1, math.floor(player:GetAttribute("CurrentRunLevel") or 1))
	end

	return math.max(1, math.floor(player:GetAttribute("BestLevel") or 1))
end

local function buildDisplayText(player)
	local level = getDisplayLevel(player)
	if player:GetAttribute("RunInCombat") == true then
		return "Lv." .. tostring(level)
	end

	return "Best Lv." .. tostring(level)
end

local function getStatsLabel(character)
	local billboard = character and character:FindFirstChild("CharacterStatsUI")
	if not billboard then return nil end

	local label = billboard:FindFirstChild("StatsLabel")
	if label and label:IsA("TextLabel") then
		return label
	end

	return nil
end

local function updateCharacterStatsText(player)
	local character = player.Character
	local label = getStatsLabel(character)
	if label then
		label.Text = buildDisplayText(player)
	end
end

local function createCharacterStatsUI(player, character)
	local rootPart = character:WaitForChild("HumanoidRootPart", 5)
	if not rootPart then return end

	local oldBillboard = character:FindFirstChild("CharacterStatsUI")
	if oldBillboard then
		oldBillboard:Destroy()
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "CharacterStatsUI"
	billboard.Adornee = rootPart
	billboard.AlwaysOnTop = true
	billboard.Size = UDim2.new(0, 220, 0, 54)
	billboard.StudsOffset = HEAD_OFFSET
	billboard.MaxDistance = 120
	billboard.Parent = character

	local label = Instance.new("TextLabel")
	label.Name = "StatsLabel"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.TextStrokeTransparency = 0
	label.Text = buildDisplayText(player)
	label.Parent = billboard
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

	player.CharacterAdded:Connect(function(character)
		createCharacterStatsUI(player, character)
	end)

	for _, attrName in ipairs({"BestLevel", "CurrentRunLevel", "RunInCombat"}) do
		player:GetAttributeChangedSignal(attrName):Connect(function()
			updateCharacterStatsText(player)
		end)
	end

	if player.Character then
		task.spawn(createCharacterStatsUI, player, player.Character)
	end
end

local function handleReportRunStats(player, isInCombat, level)
	local safeLevel = math.clamp(math.floor(tonumber(level) or 1), 1, MAX_REPORT_LEVEL)
	player:SetAttribute("RunInCombat", isInCombat == true)
	player:SetAttribute("CurrentRunLevel", safeLevel)

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
