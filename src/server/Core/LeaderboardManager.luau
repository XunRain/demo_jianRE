-- src/server/Core/LeaderboardManager.luau
-- 全服排行榜管理器：记录玩家本局距离，写入 OrderedDataStore，并向客户端提供全服榜单快照。
local LeaderboardManager = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("Configs"):WaitForChild("GameConfig"))

local Services
local runStates = {}
local accumulatedTime = 0
local orderedStore = nil
local rankScanCache = nil
local rankScanCacheTime = 0
local selfRankCache = {}
local nameCache = {}
local lastSubmittedDistances = {}
local updatePlayerDistance

function LeaderboardManager.Init(deps)
	Services = deps
end

-- 获取排行榜配置；没有配置时使用保守兜底值。
local function getLeaderboardConfig()
	return GameConfig.LEADERBOARD or {
		TopCount = 10,
		ServerUpdateInterval = 0.5,
		GlobalRefreshInterval = 60,
		SelfRankScanLimit = 200,
		OrderedStoreName = "BestDistanceLeaderboard_V1",
	}
end

-- 确保 ReplicatedStorage.Remotes 存在，并返回指定类型的 Remote。
local function getOrCreateRemote(name, className)
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end

	local remote = remotes:FindFirstChild(name)
	if remote and not remote:IsA(className) then
		warn("[LeaderboardManager] Remote 类型不匹配，已重建:", name, className)
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

-- 初始化全服排行榜 OrderedDataStore。
local function getOrderedStore()
	if orderedStore then
		return orderedStore
	end

	local config = getLeaderboardConfig()
	orderedStore = DataStoreService:GetOrderedDataStore(config.OrderedStoreName or "BestDistanceLeaderboard_V1")
	return orderedStore
end

-- 查询并缓存玩家名；失败时用 UserId 兜底，避免排行榜渲染中断。
local function getPlayerName(userId)
	if nameCache[userId] then
		return nameCache[userId]
	end

	local onlinePlayer = Players:GetPlayerByUserId(userId)
	if onlinePlayer then
		nameCache[userId] = onlinePlayer.Name
		return onlinePlayer.Name
	end

	local success, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)

	if success and type(name) == "string" then
		nameCache[userId] = name
		return name
	end

	local fallbackName = "User" .. tostring(userId)
	nameCache[userId] = fallbackName
	return fallbackName
end

-- 把 OrderedDataStore 当前页转换成客户端可直接渲染的数据。
local function buildEntriesFromPage(page, startRank)
	local entries = {}
	for index, item in ipairs(page) do
		local userId = tonumber(item.key)
		local distance = tonumber(item.value) or 0
		if userId and distance > 0 then
			table.insert(entries, {
				Rank = startRank + index - 1,
				UserId = userId,
				Name = getPlayerName(userId),
				Distance = math.floor(distance),
			})
		end
	end
	return entries
end

-- 刷新全服排名扫描缓存；Top10 和玩家自身排名共用这份数据，避免一次刷新打多次 OrderedDataStore。
local function refreshRankScanCache(force)
	local config = getLeaderboardConfig()
	local now = os.clock()
	local refreshInterval = config.GlobalRefreshInterval or 60
	if not force and rankScanCache and (now - rankScanCacheTime) < refreshInterval then
		return rankScanCache
	end

	local scanLimit = config.SelfRankScanLimit or 200
	local pageSize = math.min(100, scanLimit)
	local entries = {}

	local success, err = pcall(function()
		local pages = getOrderedStore():GetSortedAsync(false, pageSize)
		while true do
			local page = pages:GetCurrentPage()
			local pageEntries = buildEntriesFromPage(page, #entries + 1)
			for _, entry in ipairs(pageEntries) do
				table.insert(entries, entry)
				if #entries >= scanLimit then
					break
				end
			end

			if pages.IsFinished or #entries >= scanLimit then
				break
			end
			pages:AdvanceToNextPageAsync()
		end
	end)

	if success then
		rankScanCache = entries
		rankScanCacheTime = now

	else
		warn("[LeaderboardManager] 全服排行榜扫描失败:", err)
		rankScanCache = rankScanCache or {}
	end

	return rankScanCache
end

-- 在有限范围内扫描玩家自己的全服排名；超出范围显示 200+。
local function getSelfRankInfo(player)
	local config = getLeaderboardConfig()
	local scanLimit = config.SelfRankScanLimit or 200
	local refreshInterval = config.GlobalRefreshInterval or 60
	local targetUserId = player.UserId
	local bestDistance = math.floor(player:GetAttribute("BestDistance") or 0)
	local cached = selfRankCache[targetUserId]
	if cached and (os.clock() - cached.UpdatedAt) < refreshInterval and cached.BestDistance >= bestDistance then
		return cached.Data
	end

	local selfInfo = {
		Rank = nil,
		RankText = bestDistance > 0 and (tostring(scanLimit) .. "+") or "-",
		UserId = targetUserId,
		Name = player.Name,
		Distance = bestDistance,
	}

	if bestDistance <= 0 then
		selfRankCache[targetUserId] = {
			UpdatedAt = os.clock(),
			BestDistance = bestDistance,
			Data = selfInfo,
		}
		return selfInfo
	end

	local entries = refreshRankScanCache(false)
	for _, entry in ipairs(entries) do
		if entry.UserId == targetUserId then
			selfInfo.Rank = entry.Rank
			selfInfo.RankText = tostring(entry.Rank)
			selfInfo.Distance = math.max(bestDistance, entry.Distance or 0)
			break
		end
	end

	selfRankCache[targetUserId] = {
		UpdatedAt = os.clock(),
		BestDistance = bestDistance,
		Data = selfInfo,
	}

	return selfInfo
end

-- 写入玩家历史最高米数到全服排行榜；同一个服务器内只在成绩变高时写。
function LeaderboardManager.SubmitBestDistance(userId, distance)
	local bestDistance = math.floor(tonumber(distance) or 0)
	if not userId or bestDistance <= 0 then
		return false
	end

	if (lastSubmittedDistances[userId] or 0) >= bestDistance then
		return true
	end

	local success, err = pcall(function()
		getOrderedStore():SetAsync(tostring(userId), bestDistance)
	end)

	if success then
		lastSubmittedDistances[userId] = bestDistance
		selfRankCache[userId] = nil
		rankScanCacheTime = 0
		return true
	end

	warn("[LeaderboardManager] 写入全服排行榜失败:", userId, bestDistance, err)
	return false
end

-- 便捷接口：按玩家当前 BestDistance 补写全服排行榜。
function LeaderboardManager.SubmitPlayerBestDistance(player)
	if not player then return false end
	return LeaderboardManager.SubmitBestDistance(player.UserId, player:GetAttribute("BestDistance") or 0)
end

-- 获取玩家角色根节点，用于服务端计算玩家向前跑了多少米。
local function getRootPart(player)
	local character = player.Character
	if not character then return nil end
	return character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
end

-- 初始化玩家排行榜属性，并在死亡时保存个人数据和全服排行榜。
local function initPlayer(player)
	if player:GetAttribute("BestDistance") == nil then
		player:SetAttribute("BestDistance", 0)
	end
	player:SetAttribute("CurrentDistance", 0)

	player.CharacterAdded:Connect(function(character)
		local humanoid = character:WaitForChild("Humanoid", 5)
		if humanoid then
			humanoid.Died:Connect(function()
				local state = runStates[player]
				if state then
					updatePlayerDistance(player, state, true)
					if Services and Services.AnalyticsManager and Services.AnalyticsManager.HandleRunEnded then
						Services.AnalyticsManager.HandleRunEnded(player, "death")
					end
					state.Active = false
				end

				LeaderboardManager.SubmitPlayerBestDistance(player)
				if Services.DataManager and Services.DataManager.SavePlayerData then
					task.spawn(function()
						Services.DataManager.SavePlayerData(player)
					end)
				end
			end)
		end
	end)
end

-- 开始记录一局跑酷距离；起点由客户端上报，服务端用当前位置做基础校验。
local function startRun(player, clientStartZ)
	local rootPart = getRootPart(player)
	local rootZ = rootPart and rootPart.Position.Z or nil
	local startZ = tonumber(clientStartZ) or rootZ or 0

	if rootZ and math.abs(startZ - rootZ) > 80 then
		startZ = rootZ
	end

	runStates[player] = {
		Active = true,
		StartZ = startZ,
		LastDistance = 0,
	}
	player:SetAttribute("CurrentDistance", 0)
	if Services and Services.AnalyticsManager and Services.AnalyticsManager.HandleRunStarted then
		Services.AnalyticsManager.HandleRunStarted(player)
	end
end

-- 更新单个玩家的当前距离与历史最高距离。
updatePlayerDistance = function(player, state, allowDead)
	if not state.Active then return end

	local rootPart = getRootPart(player)
	if not rootPart then return end

	local humanoid = player.Character and player.Character:FindFirstChild("Humanoid")
	if humanoid and humanoid.Health <= 0 and not allowDead then
		state.Active = false
		return
	end

	local distance = math.max(0, math.floor(state.StartZ - rootPart.Position.Z))
	if distance <= state.LastDistance then return end

	state.LastDistance = distance
	player:SetAttribute("CurrentDistance", distance)
	if Services and Services.AnalyticsManager and Services.AnalyticsManager.HandleDistanceUpdated then
		Services.AnalyticsManager.HandleDistanceUpdated(player, distance)
	end

	local bestDistance = player:GetAttribute("BestDistance") or 0
	if distance > bestDistance then
		player:SetAttribute("BestDistance", distance)
	end
end

-- 给客户端返回全服榜单快照。
local function getGlobalLeaderboardSnapshot(player)
	local scannedEntries = refreshRankScanCache(false)
	local config = getLeaderboardConfig()
	local topEntries = {}
	for index = 1, math.min(config.TopCount or 10, #scannedEntries) do
		table.insert(topEntries, scannedEntries[index])
	end
	local selfInfo = getSelfRankInfo(player)

	return {
		Top = topEntries,
		Self = selfInfo,
		UpdatedAt = os.time(),
		Mode = "Global",
	}
end

function LeaderboardManager.Start()
	local runStartedEvent = getOrCreateRemote("RunStarted", "RemoteEvent")
	runStartedEvent.OnServerEvent:Connect(startRun)

	local getGlobalLeaderboard = getOrCreateRemote("GetGlobalLeaderboard", "RemoteFunction")
	getGlobalLeaderboard.OnServerInvoke = getGlobalLeaderboardSnapshot

	for _, player in ipairs(Players:GetPlayers()) do
		initPlayer(player)
	end

	Players.PlayerAdded:Connect(initPlayer)
	Players.PlayerRemoving:Connect(function(player)
		local state = runStates[player]
		if state then
			updatePlayerDistance(player, state, true)
			if state.Active and Services and Services.AnalyticsManager and Services.AnalyticsManager.HandleRunEnded then
				Services.AnalyticsManager.HandleRunEnded(player, "leave")
			end
		end
		LeaderboardManager.SubmitPlayerBestDistance(player)
		runStates[player] = nil
	end)

	RunService.Heartbeat:Connect(function(dt)
		accumulatedTime += dt
		local config = getLeaderboardConfig()
		local updateInterval = config.ServerUpdateInterval or 0.5
		if accumulatedTime < updateInterval then return end
		accumulatedTime = 0

		for player, state in pairs(runStates) do
			updatePlayerDistance(player, state)
		end
	end)

	task.spawn(function()
		while true do
			refreshRankScanCache(false)
			task.wait((getLeaderboardConfig().GlobalRefreshInterval or 60))
		end
	end)
end

return LeaderboardManager
