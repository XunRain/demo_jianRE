-- src/server/Core/DataManager.luau
local DataManager = {}
local DataStoreService = game:GetService("DataStoreService")

-- 申请云端存储空间
local PlayerDataStore = DataStoreService:GetDataStore("GameData_V1")

local _Services -- 全局服务引用指针，当前模块暂不直接使用
local DEFAULT_STATS = {
	Coins = 0, -- 局外永久金币底模
    Talent_HP = 0,   -- 血量强化等级
	Talent_ATK = 0,  -- 攻击强化等级
	Talent_ASPD = 0, -- 攻速强化等级

    -- 宠物相关存档
	OwnedPets_JSON = "[]", -- 用 JSON 字符串格式存储拥有的宠物数组
	EquippedPet = "",      -- 当前上阵的宠物 ID

    -- 记录玩家是否已经看过第二关的引导
	HasSeenStage2Guide = false,

    -- 默认装备的武器 ID
	EquippedWeapon = "DefaultWeapon",

	-- 排行榜相关数据：个人存档保存历史最高米数，全服榜单由 LeaderboardManager 另写 OrderedDataStore。
	BestDistance = 0,
}

function DataManager.Init(deps)
	_Services = deps
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

	local playerData = {}
	for statName, statValue in pairs(DEFAULT_STATS) do
		playerData[statName] = statValue
	end
	if success and data then
		for statName, statValue in pairs(data) do
			playerData[statName] = statValue
		end
		print("✅ " .. player.Name .. " 的云端数据读取成功！")
	else
		print("⚠️ " .. player.Name .. " 读取失败或属首次游玩，使用默认 0 资产。")
	end

	-- 服务器端修改属性，会自动下发给客户端同步更新 UI
	for statName, statValue in pairs(playerData) do
		player:SetAttribute(statName, statValue)
	end

	-- 旧数据渐进迁移：已有个人最高米数的玩家进入游戏后，补写到全服排行榜。
	if _Services and _Services.LeaderboardManager and _Services.LeaderboardManager.SubmitPlayerBestDistance then
		task.spawn(function()
			_Services.LeaderboardManager.SubmitPlayerBestDistance(player)
		end)
	end
end

-- ==========================================
-- 业务接口 2：将数据推向云端
-- ==========================================
function DataManager.SavePlayerData(player)
	local dataToSave = {
		Coins = player:GetAttribute("Coins") or 0,
		Talent_HP = player:GetAttribute("Talent_HP") or 0,
		Talent_ATK = player:GetAttribute("Talent_ATK") or 0,
		Talent_ASPD = player:GetAttribute("Talent_ASPD") or 0,
        OwnedPets_JSON = player:GetAttribute("OwnedPets_JSON") or "[]",
		EquippedPet = player:GetAttribute("EquippedPet") or "",

        -- 将第二关引导标记一起存入云端
		HasSeenStage2Guide = player:GetAttribute("HasSeenStage2Guide") or false,
		EquippedWeapon = player:GetAttribute("EquippedWeapon") or "DefaultWeapon",
		BestDistance = player:GetAttribute("BestDistance") or 0,
	}

	local success, err = pcall(function()
		PlayerDataStore:SetAsync("Player_" .. player.UserId, dataToSave)
	end)

	if success then
		print("💾 云端同步完毕！安全保存了玩家 " .. player.Name .. " 的资产。金币:", dataToSave.Coins)
		-- 保存个人数据成功后，同步刷新全服排行榜最高米数。
		if _Services and _Services.LeaderboardManager and _Services.LeaderboardManager.SubmitPlayerBestDistance then
			task.spawn(function()
				_Services.LeaderboardManager.SubmitPlayerBestDistance(player)
			end)
		end
	else
		warn("❌ 云端同步灾难！玩家 " .. player.Name .. " 存档失败:", err)
	end
end

return DataManager
