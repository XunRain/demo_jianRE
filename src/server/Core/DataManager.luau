-- src/server/Core/DataManager.luau
local DataManager = {}
local DataStoreService = game:GetService("DataStoreService")

-- 申请云端存储空间
local PlayerDataStore = DataStoreService:GetDataStore("GameData_V1")

local Services -- 全局服务引用指针
local DEFAULT_STATS = {
	Coins = 0, -- 局外永久金币底模
}

function DataManager.Init(deps)
	Services = deps
end

function DataManager.Start()
	-- 纯数据读写模块，不需要常驻循环
end

-- ==========================================
-- 业务接口 1：从云端拉取存档
-- ==========================================
function DataManager.LoadPlayerData(player)
	print("正在连接云端，读取玩家数据:", player.Name)
	
	local success, data = pcall(function()
		return PlayerDataStore:GetAsync("Player_" .. player.UserId)
	end)

	local playerData = DEFAULT_STATS
	if success and data then
		playerData = data
		print("✅ " .. player.Name .. " 的云端数据读取成功！")
	else
		print("⚠️ " .. player.Name .. " 读取失败或属首次游玩，使用默认 0 资产。")
	end

	-- 服务器端修改属性，会自动下发给客户端同步更新 UI
	for statName, statValue in pairs(playerData) do
		player:SetAttribute(statName, statValue)
	end
end

-- ==========================================
-- 业务接口 2：将数据推向云端
-- ==========================================
function DataManager.SavePlayerData(player)
	local dataToSave = {
		Coins = player:GetAttribute("Coins") or 0
	}

	local success, err = pcall(function()
		PlayerDataStore:SetAsync("Player_" .. player.UserId, dataToSave)
	end)

	if success then
		print("💾 云端同步完毕！安全保存了玩家 " .. player.Name .. " 的资产。金币:", dataToSave.Coins)
	else
		warn("❌ 云端同步灾难！玩家 " .. player.Name .. " 存档失败:", err)
	end
end

return DataManager