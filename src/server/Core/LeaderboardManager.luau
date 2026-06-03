-- src/server/Core/LeaderboardManager.luau
-- 服务器内排行榜管理器：维护当前服务器玩家的本局距离与服务器内最高距离，并通过 Attribute 同步给客户端展示板。
local LeaderboardManager = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("Configs"):WaitForChild("GameConfig"))

local Services
local runStates = {}
local accumulatedTime = 0
local updatePlayerDistance

function LeaderboardManager.Init(deps)
	Services = deps
end

-- 获取排行榜配置；没有配置时使用保守兜底值。
local function getLeaderboardConfig()
	return GameConfig.LEADERBOARD or {
		ServerUpdateInterval = 0.5,
	}
end

-- 确保 ReplicatedStorage.Remotes 和排行榜需要的 RemoteEvent 存在。
local function getRunStartedEvent()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end

	local event = remotes:FindFirstChild("RunStarted")
	if not event then
		event = Instance.new("RemoteEvent")
		event.Name = "RunStarted"
		event.Parent = remotes
	end

	return event
end

-- 获取玩家角色根节点，用于服务器端计算玩家向前跑了多少米。
local function getRootPart(player)
	local character = player.Character
	if not character then return nil end
	return character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
end

-- 初始化玩家排行榜属性，确保客户端展示板始终能读到稳定数值。
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
					updatePlayerDistance(player, state)
					state.Active = false
				end

				-- 死亡代表一局结束，及时保存个人最高米数；离开服务器时仍会再走一次总存档。
				if Services.DataManager and Services.DataManager.SavePlayerData then
					task.spawn(function()
						Services.DataManager.SavePlayerData(player)
					end)
				end
			end)
		end
	end)
end

-- 开始记录一局跑酷距离；起点由客户端进入跑道时上报，服务端会用角色当前位置做基础校验。
local function startRun(player, clientStartZ)
	local rootPart = getRootPart(player)
	local rootZ = rootPart and rootPart.Position.Z or nil
	local startZ = tonumber(clientStartZ) or rootZ or 0

	-- 防止异常起点导致距离直接暴涨；如果客户端起点和服务端位置差太多，就采用服务端当前位置。
	if rootZ and math.abs(startZ - rootZ) > 80 then
		startZ = rootZ
	end

	runStates[player] = {
		Active = true,
		StartZ = startZ,
		LastDistance = 0,
	}
	player:SetAttribute("CurrentDistance", 0)
end

-- 更新单个玩家的当前距离与服务器内最高距离。
updatePlayerDistance = function(player, state)
	if not state.Active then return end

	local rootPart = getRootPart(player)
	if not rootPart then return end

	local humanoid = player.Character and player.Character:FindFirstChild("Humanoid")
	if humanoid and humanoid.Health <= 0 then
		state.Active = false
		return
	end

	local distance = math.max(0, math.floor(state.StartZ - rootPart.Position.Z))
	if distance <= state.LastDistance then return end

	state.LastDistance = distance
	player:SetAttribute("CurrentDistance", distance)

	local bestDistance = player:GetAttribute("BestDistance") or 0
	if distance > bestDistance then
		player:SetAttribute("BestDistance", distance)
	end
end

function LeaderboardManager.Start()
	local runStartedEvent = getRunStartedEvent()
	runStartedEvent.OnServerEvent:Connect(startRun)

	for _, player in ipairs(Players:GetPlayers()) do
		initPlayer(player)
	end

	Players.PlayerAdded:Connect(initPlayer)
	Players.PlayerRemoving:Connect(function(player)
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
end

return LeaderboardManager
