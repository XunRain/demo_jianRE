local AchievementManager = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("Configs"):WaitForChild("GameConfig"))

local Services
local pendingSavePlayers = {}

local function getOrCreateRemote(name, className)
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end

	local remote = remotes:FindFirstChild(name)
	if remote and not remote:IsA(className) then
		remote:Destroy()
		remote = nil
	end

	if not remote then
		remote = Instance.new(className)
		remote.Name = name
		remote.Parent = remotes
	end

	return remote
end

local function decodeClaimedAchievements(player)
	local rawValue = player:GetAttribute("ClaimedAchievements_JSON")
	if type(rawValue) ~= "string" or rawValue == "" then
		return {}
	end

	local success, decoded = pcall(function()
		return HttpService:JSONDecode(rawValue)
	end)

	if not success or type(decoded) ~= "table" then
		return {}
	end

	return decoded
end

local function encodeClaimedAchievements(claimed)
	local success, encoded = pcall(function()
		return HttpService:JSONEncode(claimed)
	end)

	return success and encoded or "{}"
end

local function getSortedAchievements()
	local achievements = {}
	for _, achievement in ipairs(GameConfig.ACHIEVEMENTS or {}) do
		if type(achievement) == "table" and type(achievement.Id) == "string" then
			table.insert(achievements, achievement)
		end
	end

	table.sort(achievements, function(a, b)
		local orderA = a.SortOrder or math.huge
		local orderB = b.SortOrder or math.huge
		if orderA ~= orderB then
			return orderA < orderB
		end

		return a.Id < b.Id
	end)

	return achievements
end

local function getAchievementById(achievementId)
	for _, achievement in ipairs(GameConfig.ACHIEVEMENTS or {}) do
		if achievement.Id == achievementId then
			return achievement
		end
	end

	return nil
end

local function getStageStartDistance(stageNumber)
	local targetStage = math.max(1, math.floor(tonumber(stageNumber) or 1))
	if targetStage <= 1 then
		return 1
	end

	local totalDistance = 0
	local stages = GameConfig.STAGES or {}
	local lastStageConfig = stages[#stages] or stages[1]
	local fallbackLength = (lastStageConfig and lastStageConfig.Length) or 1000

	for stageIndex = 1, targetStage - 1 do
		local stageConfig = stages[stageIndex] or lastStageConfig
		totalDistance += math.max(1, (stageConfig and stageConfig.Length) or fallbackLength)
	end

	return math.max(1, math.floor(totalDistance))
end

local function getBestStageFromDistance(bestDistance)
	local distance = math.max(0, math.floor(tonumber(bestDistance) or 0))
	if distance <= 0 then
		return 0
	end

	local stage = 1
	local remainingDistance = distance
	local stages = GameConfig.STAGES or {}
	local lastStageConfig = stages[#stages] or stages[1]
	local fallbackLength = (lastStageConfig and lastStageConfig.Length) or 1000

	while true do
		local stageConfig = stages[stage] or lastStageConfig
		local length = math.max(1, (stageConfig and stageConfig.Length) or fallbackLength)
		if remainingDistance < length then
			return stage
		end

		remainingDistance -= length
		stage += 1
	end
end

local function getProgress(player, achievement)
	local bestDistance = math.max(0, math.floor(player:GetAttribute("BestDistance") or 0))

	if achievement.Type == "Stage" then
		local targetStage = math.max(1, math.floor(achievement.Target or 1))
		local currentStage = getBestStageFromDistance(bestDistance)
		local requiredDistance = getStageStartDistance(targetStage)
		local progress = math.clamp(bestDistance / requiredDistance, 0, 1)
		local canClaim = bestDistance >= requiredDistance

		return {
			Current = currentStage,
			Target = targetStage,
			Progress = progress,
			CanClaim = canClaim,
			ProgressText = string.format("%d/%d", math.min(currentStage, targetStage), targetStage),
		}
	end

	local targetDistance = math.max(1, math.floor(achievement.Target or 1))
	return {
		Current = math.min(bestDistance, targetDistance),
		Target = targetDistance,
		Progress = math.clamp(bestDistance / targetDistance, 0, 1),
		CanClaim = bestDistance >= targetDistance,
		ProgressText = string.format("%d/%d", math.min(bestDistance, targetDistance), targetDistance),
	}
end

local function buildAchievementEntry(player, achievement, claimed)
	local progress = getProgress(player, achievement)
	local isClaimed = claimed[achievement.Id] == true

	return {
		Id = achievement.Id,
		Type = achievement.Type or "Distance",
		Title = achievement.Title or achievement.Id,
		Details = achievement.Details or "",
		Current = progress.Current,
		Target = progress.Target,
		Progress = progress.Progress,
		ProgressText = progress.ProgressText,
		RewardTickets = math.max(0, math.floor(achievement.RewardTickets or 0)),
		RewardCoins = math.max(0, math.floor(achievement.RewardCoins or 0)),
		CanClaim = progress.CanClaim and not isClaimed,
		Claimed = isClaimed,
		SortOrder = achievement.SortOrder or 0,
	}
end

local function schedulePlayerSave(player)
	if not player or pendingSavePlayers[player] then return end
	pendingSavePlayers[player] = true

	task.delay(2, function()
		pendingSavePlayers[player] = nil
		if not player.Parent then return end
		if Services and Services.DataManager and Services.DataManager.SavePlayerData then
			Services.DataManager.SavePlayerData(player)
		end
	end)
end

local function getAchievementsSnapshot(player)
	local claimed = decodeClaimedAchievements(player)
	local entries = {}

	for _, achievement in ipairs(getSortedAchievements()) do
		table.insert(entries, buildAchievementEntry(player, achievement, claimed))
	end

	table.sort(entries, function(a, b)
		if a.CanClaim ~= b.CanClaim then
			return a.CanClaim == true
		end

		if a.Claimed ~= b.Claimed then
			return a.Claimed ~= true
		end

		if a.SortOrder ~= b.SortOrder then
			return a.SortOrder < b.SortOrder
		end

		return a.Id < b.Id
	end)

	return {
		Achievements = entries,
		PetDrawTickets = player:GetAttribute("PetDrawTickets") or 0,
		Coins = player:GetAttribute("Coins") or 0,
		UpdatedAt = os.time(),
	}
end

local function claimAchievement(player, achievementId)
	if type(achievementId) ~= "string" then
		return {
			Success = false,
			Message = "Invalid achievement.",
			Snapshot = getAchievementsSnapshot(player),
		}
	end

	local achievement = getAchievementById(achievementId)
	if not achievement then
		return {
			Success = false,
			Message = "Achievement not found.",
			Snapshot = getAchievementsSnapshot(player),
		}
	end

	local claimed = decodeClaimedAchievements(player)
	if claimed[achievement.Id] == true then
		return {
			Success = false,
			Message = "Already claimed.",
			Snapshot = getAchievementsSnapshot(player),
		}
	end

	local progress = getProgress(player, achievement)
	if not progress.CanClaim then
		return {
			Success = false,
			Message = "Not completed.",
			Snapshot = getAchievementsSnapshot(player),
		}
	end

	local rewardTickets = math.max(0, math.floor(achievement.RewardTickets or 0))
	local rewardCoins = math.max(0, math.floor(achievement.RewardCoins or 0))

	player:SetAttribute("PetDrawTickets", (player:GetAttribute("PetDrawTickets") or 0) + rewardTickets)
	player:SetAttribute("Coins", (player:GetAttribute("Coins") or 0) + rewardCoins)

	claimed[achievement.Id] = true
	player:SetAttribute("ClaimedAchievements_JSON", encodeClaimedAchievements(claimed))

	schedulePlayerSave(player)

	return {
		Success = true,
		Message = "Claimed.",
		Achievement = buildAchievementEntry(player, achievement, claimed),
		Snapshot = getAchievementsSnapshot(player),
	}
end

local function initPlayer(player)
	if player:GetAttribute("PetDrawTickets") == nil then
		player:SetAttribute("PetDrawTickets", 0)
	end
	if player:GetAttribute("ClaimedAchievements_JSON") == nil then
		player:SetAttribute("ClaimedAchievements_JSON", "{}")
	end
end

function AchievementManager.Init(deps)
	Services = deps
end

function AchievementManager.Start()
	local getAchievements = getOrCreateRemote("GetAchievements", "RemoteFunction")
	getAchievements.OnServerInvoke = getAchievementsSnapshot

	local claimAchievementRemote = getOrCreateRemote("ClaimAchievement", "RemoteFunction")
	claimAchievementRemote.OnServerInvoke = claimAchievement

	for _, player in ipairs(Players:GetPlayers()) do
		initPlayer(player)
	end

	Players.PlayerAdded:Connect(initPlayer)
	Players.PlayerRemoving:Connect(function(player)
		pendingSavePlayers[player] = nil
	end)
end

return AchievementManager
