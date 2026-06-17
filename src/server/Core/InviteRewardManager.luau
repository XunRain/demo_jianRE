local InviteRewardManager = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local MemoryStoreService = game:GetService("MemoryStoreService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("Configs"):WaitForChild("GameConfig"))

local Services
local localInviteTokens = {}
local deliveredRewards = {}
local memoryTokenMap = nil

local function getConfig()
	return GameConfig.INVITE_REWARD or {}
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
		warn("[InviteRewardManager] Rebuilding remote with unexpected type:", name, className)
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

local function getMemoryTokenMap()
	if memoryTokenMap then
		return memoryTokenMap
	end

	local success, result = pcall(function()
		return MemoryStoreService:GetHashMap("InviteRewardTokens_v1")
	end)

	if success then
		memoryTokenMap = result
		return memoryTokenMap
	end

	warn("[InviteRewardManager] MemoryStore unavailable; cross-server invite token lookup may fail:", result)
	return nil
end

local function initPlayer(player)
	if player:GetAttribute("PendingInviteCoinBonus") == nil then
		player:SetAttribute("PendingInviteCoinBonus", 0)
	end
	if player:GetAttribute("RunInviteCoinBonus") == nil then
		player:SetAttribute("RunInviteCoinBonus", 0)
	end
end

local function getMaxRunBonus()
	local config = getConfig()
	return math.max(0, tonumber(config.MaxRunBonus) or tonumber(config.CoinBonus) or 0.5)
end

local function getRewardBonus()
	local config = getConfig()
	return math.min(getMaxRunBonus(), math.max(0, tonumber(config.CoinBonus) or 0.5))
end

local function markDelivered(inviterUserId, token, invitedUserId)
	local key = tostring(inviterUserId) .. ":" .. tostring(token) .. ":" .. tostring(invitedUserId)
	if deliveredRewards[key] then
		return false
	end

	deliveredRewards[key] = true
	return true
end

local function grantPendingInviteBonus(inviterUserId, token, invitedUserId)
	local inviter = Players:GetPlayerByUserId(inviterUserId)
	if not inviter then
		return false
	end
	if not markDelivered(inviterUserId, token, invitedUserId) then
		return true
	end

	initPlayer(inviter)

	local currentPending = math.max(0, tonumber(inviter:GetAttribute("PendingInviteCoinBonus")) or 0)
	local nextPending = math.min(getMaxRunBonus(), math.max(currentPending, getRewardBonus()))
	inviter:SetAttribute("PendingInviteCoinBonus", nextPending)

	local grantedEvent = getOrCreateRemote("InviteRewardGranted", "RemoteEvent")
	grantedEvent:FireClient(inviter, {
		Bonus = nextPending,
		InvitedUserId = invitedUserId,
	})

	return true
end

local function publishInviteReward(inviterUserId, token, invitedUserId)
	local config = getConfig()
	local topic = tostring(config.MessageTopic or "InviteReward_v1")
	local payload = {
		InviterUserId = inviterUserId,
		InvitedUserId = invitedUserId,
		Token = token,
	}

	local success, err = pcall(function()
		MessagingService:PublishAsync(topic, payload)
	end)

	if not success then
		warn("[InviteRewardManager] Failed to publish invite reward:", err)
	end
end

local function buildInviteLaunchData(player)
	local config = getConfig()
	if config.Enabled == false then
		return {
			Success = false,
			Reason = "Disabled",
		}
	end

	local token = HttpService:GenerateGUID(false)
	local lifetime = math.max(60, math.floor(tonumber(config.TokenLifetimeSeconds) or 3600))
	local payload = {
		InviterUserId = player.UserId,
		CreatedAt = os.time(),
		ExpiresAt = os.time() + lifetime,
	}

	localInviteTokens[token] = payload

	local map = getMemoryTokenMap()
	if map then
		local success, err = pcall(function()
			map:SetAsync(token, payload, lifetime)
		end)
		if not success then
			warn("[InviteRewardManager] Failed to store invite token:", err)
		end
	end

	local launchData = HttpService:JSONEncode({
		Type = config.LaunchDataType or "InviteReward",
		Token = token,
		InviterUserId = player.UserId,
	})

	return {
		Success = true,
		LaunchData = launchData,
		PromptMessage = config.PromptMessage or "",
		TokenLifetimeSeconds = lifetime,
	}
end

local function decodeLaunchData(rawLaunchData)
	if type(rawLaunchData) ~= "string" or rawLaunchData == "" then
		return nil
	end

	local success, decoded = pcall(function()
		return HttpService:JSONDecode(rawLaunchData)
	end)
	if not success or type(decoded) ~= "table" then
		return nil
	end

	local config = getConfig()
	if decoded.Type ~= (config.LaunchDataType or "InviteReward") then
		return nil
	end

	return decoded
end

local function resolveInviteToken(token)
	if type(token) ~= "string" or token == "" then
		return nil
	end

	local localPayload = localInviteTokens[token]
	if localPayload and (tonumber(localPayload.ExpiresAt) or 0) >= os.time() then
		return localPayload
	end

	local map = getMemoryTokenMap()
	if map then
		local success, payload = pcall(function()
			return map:GetAsync(token)
		end)
		if success and type(payload) == "table" then
			return payload
		end
	end

	return nil
end

local function processJoinInvite(player)
	if getConfig().Enabled == false then
		return
	end

	local success, joinData = pcall(function()
		return player:GetJoinData()
	end)
	if not success or type(joinData) ~= "table" then
		return
	end

	local decoded = decodeLaunchData(joinData.LaunchData)
	if not decoded then
		return
	end

	local token = tostring(decoded.Token or "")
	local invitePayload = resolveInviteToken(token)
	local inviterUserId = invitePayload and tonumber(invitePayload.InviterUserId) or tonumber(decoded.InviterUserId)
	if not inviterUserId or inviterUserId <= 0 or inviterUserId == player.UserId then
		return
	end

	grantPendingInviteBonus(inviterUserId, token, player.UserId)
	publishInviteReward(inviterUserId, token, player.UserId)
end

function InviteRewardManager.HandleRunStateChanged(player, wasInCombat, isInCombat)
	if not player then
		return
	end

	initPlayer(player)

	if wasInCombat ~= true and isInCombat == true then
		local pending = math.max(0, tonumber(player:GetAttribute("PendingInviteCoinBonus")) or 0)
		local runBonus = math.min(getMaxRunBonus(), pending)
		player:SetAttribute("RunInviteCoinBonus", runBonus)
		player:SetAttribute("PendingInviteCoinBonus", 0)
	elseif wasInCombat == true and isInCombat ~= true then
		player:SetAttribute("RunInviteCoinBonus", 0)
	end
end

function InviteRewardManager.Init(deps)
	Services = deps
end

function InviteRewardManager.Start()
	local getInviteLaunchData = getOrCreateRemote("GetInviteLaunchData", "RemoteFunction")
	getInviteLaunchData.OnServerInvoke = buildInviteLaunchData
	getOrCreateRemote("InviteRewardGranted", "RemoteEvent")

	local topic = tostring((getConfig()).MessageTopic or "InviteReward_v1")
	local success, err = pcall(function()
		MessagingService:SubscribeAsync(topic, function(message)
			local data = message and message.Data
			if type(data) ~= "table" then
				return
			end

			local inviterUserId = tonumber(data.InviterUserId)
			local invitedUserId = tonumber(data.InvitedUserId)
			local token = tostring(data.Token or "")
			if inviterUserId and invitedUserId then
				grantPendingInviteBonus(inviterUserId, token, invitedUserId)
			end
		end)
	end)
	if not success then
		warn("[InviteRewardManager] Failed to subscribe invite rewards:", err)
	end

	for _, player in ipairs(Players:GetPlayers()) do
		initPlayer(player)
		task.defer(processJoinInvite, player)
	end

	Players.PlayerAdded:Connect(function(player)
		initPlayer(player)
		task.defer(processJoinInvite, player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		player:SetAttribute("PendingInviteCoinBonus", 0)
		player:SetAttribute("RunInviteCoinBonus", 0)
	end)
end

return InviteRewardManager
