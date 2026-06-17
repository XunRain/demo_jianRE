local SocialRewardManager = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("Configs"):WaitForChild("GameConfig"))

local Services
local pendingSavePlayers = {}

local function getConfig()
	return GameConfig.SOCIAL_REWARD or {}
end

local function getOrCreateRemote(name, className)
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end

	local remote = remotes:FindFirstChild(name)
	if remote and not remote:IsA(className) then
		warn("[SocialRewardManager] Rebuilding remote with unexpected type:", name, className)
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

local function schedulePlayerSave(player, delaySeconds)
	if not player or pendingSavePlayers[player] then
		return
	end

	pendingSavePlayers[player] = true
	task.delay(math.max(0, tonumber(delaySeconds) or 2), function()
		pendingSavePlayers[player] = nil
		if not player.Parent then
			return
		end

		if Services and Services.DataManager and Services.DataManager.SavePlayerData then
			Services.DataManager.SavePlayerData(player)
		end
	end)
end

local function getCommunityGroupId(config)
	return math.max(0, math.floor(tonumber(config.CommunityGroupId) or 0))
end

local function isPlayerInCommunity(player, groupId)
	if groupId <= 0 then
		return false
	end

	local success, result = pcall(function()
		return player:IsInGroup(groupId)
	end)

	if not success then
		warn("[SocialRewardManager] IsInGroup failed:", player.Name, groupId, result)
		return false
	end

	return result == true
end

local function getRewardSnapshot(player)
	local config = getConfig()
	local enabled = config.Enabled ~= false
	local groupId = getCommunityGroupId(config)
	local requireCommunity = config.RequireCommunity ~= false
	local claimed = player:GetAttribute("SocialRewardClaimed") == true
	local dataLoaded = player:GetAttribute("PlayerDataLoaded") == true
	local groupConfigured = groupId > 0
	local isInCommunity = (not requireCommunity) or isPlayerInCommunity(player, groupId)
	local canClaim = enabled and dataLoaded and not claimed and (not requireCommunity or (groupConfigured and isInCommunity))

	local reason = nil
	if not enabled then
		reason = "Disabled"
	elseif not dataLoaded then
		reason = "DataNotLoaded"
	elseif claimed then
		reason = "AlreadyClaimed"
	elseif requireCommunity and not groupConfigured then
		reason = "NotConfigured"
	elseif requireCommunity and not isInCommunity then
		reason = "NotInCommunity"
	end

	return {
		Enabled = enabled,
		DataLoaded = dataLoaded,
		Claimed = claimed,
		CommunityGroupId = groupId,
		GroupConfigured = groupConfigured,
		RequireCommunity = requireCommunity,
		IsInCommunity = isInCommunity,
		CanClaim = canClaim,
		Reason = reason,
		RewardTickets = math.max(0, math.floor(tonumber(config.RewardTickets) or 0)),
		RewardCoins = math.max(0, math.floor(tonumber(config.RewardCoins) or 0)),
		PetDrawTickets = player:GetAttribute("PetDrawTickets") or 0,
		Coins = player:GetAttribute("Coins") or 0,
	}
end

local function claimSocialReward(player)
	local snapshot = getRewardSnapshot(player)
	if not snapshot.CanClaim then
		return {
			Success = false,
			Reason = snapshot.Reason or "CannotClaim",
			Message = snapshot.Reason or "Cannot claim.",
			Snapshot = snapshot,
		}
	end

	local rewardTickets = snapshot.RewardTickets
	local rewardCoins = snapshot.RewardCoins
	local currentTickets = math.max(0, math.floor(tonumber(player:GetAttribute("PetDrawTickets")) or 0))
	local currentCoins = math.max(0, math.floor(tonumber(player:GetAttribute("Coins")) or 0))
	local currentMaxCoinsHeld = math.max(0, math.floor(tonumber(player:GetAttribute("MaxCoinsHeld")) or 0))
	local nextCoins = currentCoins + rewardCoins

	player:SetAttribute("PetDrawTickets", currentTickets + rewardTickets)
	player:SetAttribute("Coins", nextCoins)
	player:SetAttribute("MaxCoinsHeld", math.max(currentMaxCoinsHeld, nextCoins))
	player:SetAttribute("SocialRewardClaimed", true)

	schedulePlayerSave(player, 1)

	local updatedSnapshot = getRewardSnapshot(player)
	return {
		Success = true,
		Reason = "Claimed",
		Message = "Claimed.",
		RewardTickets = rewardTickets,
		RewardCoins = rewardCoins,
		Snapshot = updatedSnapshot,
	}
end

local function initPlayer(player)
	if player:GetAttribute("SocialRewardClaimed") == nil then
		player:SetAttribute("SocialRewardClaimed", false)
	end
end

function SocialRewardManager.Init(deps)
	Services = deps
end

function SocialRewardManager.Start()
	local getStatusRemote = getOrCreateRemote("GetSocialRewardStatus", "RemoteFunction")
	getStatusRemote.OnServerInvoke = getRewardSnapshot

	local claimRemote = getOrCreateRemote("ClaimSocialReward", "RemoteFunction")
	claimRemote.OnServerInvoke = claimSocialReward

	for _, player in ipairs(Players:GetPlayers()) do
		initPlayer(player)
	end

	Players.PlayerAdded:Connect(initPlayer)
	Players.PlayerRemoving:Connect(function(player)
		pendingSavePlayers[player] = nil
	end)
end

return SocialRewardManager
