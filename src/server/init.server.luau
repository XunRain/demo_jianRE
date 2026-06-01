-- src/server/init.server.luau
print("Initializing Server Architecture...")

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("Configs"):WaitForChild("GameConfig"))

-- 1. 定义服务端服务映射表 (对齐客户端设计)
local Services = {
	DataManager    = require(script.Core:WaitForChild("DataManager")),
	NetworkManager = require(script.Network:WaitForChild("NetworkManager")),
}

-- 2. 第一阶段：执行 Init 依赖注入
for name, service in pairs(Services) do
	if type(service.Init) == "function" then
		service.Init(Services)
		print("Initialized Server Service: " .. name)
	end
end

-- 3. 第二阶段：执行 Start 异步拉起业务
for name, service in pairs(Services) do
	if type(service.Start) == "function" then
		task.spawn(function()
			service.Start()
			print("Started Server Service: " .. name)
		end)
	end
end

-- 4. 统一收拢玩家生命周期分发（确保时序和绝对安全 带防抖锁，防止瞬间重复存档）

-- 玩家加进服务器：呼叫数据中心读档
Players.PlayerAdded:Connect(function(player)
	Services.DataManager.LoadPlayerData(player)
	
	-- 如果有局外初始血量等非永久存储同步，也可以在服务器的这里顺手做了
	player.CharacterAdded:Connect(function(character)
		local humanoid = character:WaitForChild("Humanoid")
		humanoid.MaxHealth = player:GetAttribute("HP") or GameConfig.BASE_HP
		humanoid.Health = player:GetAttribute("HP") or GameConfig.BASE_HP
	end)
end)

-- 玩家彻底退出服务器：呼叫数据中心落盘
Players.PlayerRemoving:Connect(function(player)
	-- 如果该玩家已经在保存流程中，直接拦截，防止重复触发
	if player:GetAttribute("IsSaving") then return end
	player:SetAttribute("IsSaving", true)
	
	Services.DataManager.SavePlayerData(player)
end)

-- Studio 环境防漏人保障
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(Services.DataManager.LoadPlayerData, player)
end

-- 服务器物理关闭保护（停服/关服时强制保存现场）
game:BindToClose(function()
	print(">>> 警告: 服务器正在关闭，正在执行全体紧急数据回写！ <<<")
	for _, player in ipairs(Players:GetPlayers()) do
		-- 巡检所有玩家，只抢救那些还没来得及保存的玩家
		if not player:GetAttribute("IsSaving") then
			player:SetAttribute("IsSaving", true)
			Services.DataManager.SavePlayerData(player)
		end
	end
	task.wait(1) -- 留出 1 秒线程缓冲给云端 API 写入
end)

print("Server Architecture Pipeline Ready!")