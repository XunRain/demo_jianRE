-- src/server/Core/DataManager.luau
local DataManager = {}
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

-- 申请云端存储空间
local PlayerDataStore = DataStoreService:GetDataStore("GameData_V1")

local _Services -- 全局服务引用指针，当前模块暂不直接使用
local DEFAULT_STATS = {
	Talent_EXP = 0,
	Talent_LUCK = 0,
	Talent_MOVE = 0,
	Talent_PET_SLOT = 0,
	EquippedPets_JSON = "[]",
	Coins = 0, -- 局外永久金币底模
    Talent_HP = 0,   -- 血量强化等级
	Talent_ATK = 0,  -- 攻击强化等级
	Talent_ASPD = 0, -- 攻速强化等级

    -- 宠物相关存档
	OwnedPets_JSON = "[]", -- 用 JSON 字符串格式存储拥有的宠物数组
	EquippedPet = "",      -- 当前上阵的宠物 ID
	EquippedPetUid = "",   -- 当前上阵的宠物唯一实例 ID
	EquippedPetLevel = 1,  -- 当前上阵宠物等级
	RebirthCount = 0,
	CoinGainBonus = 0,
	PetDrawTickets = 0,
	ClaimedAchievements_JSON = "{}",

    -- 记录玩家是否已经看过第二关的引导
	HasSeenStage2Guide = false,

    -- 默认装备的武器 ID
	EquippedWeapon = "DefaultWeapon",

	-- 排行榜相关数据：个人存档保存历史最高米数，全服榜单由 LeaderboardManager 另写 OrderedDataStore。
	BestDistance = 0,
	BestLevel = 1, -- 玩家历史最高局内等级，用于大厅头顶进度展示
}

-- 测试白名单：命中的玩家进入游戏时会清空存档，并发放指定金币。
-- 适合测试号快速重置进度；该逻辑每次进游戏都会生效。
local RESET_REWARD_WHITELIST = {
	[10162193146] = {
		Coins = 10,
	},
	[10761954496] = {
		Coins = 10000000000000000,
	},
	[10972923838] = {
		Coins = 20000,
	},
}

local function buildDefaultPlayerData()
	local playerData = {}
	for statName, statValue in pairs(DEFAULT_STATS) do
		playerData[statName] = statValue
	end
	return playerData
end

local function buildResetRewardData(userId)
	local rewardConfig = RESET_REWARD_WHITELIST[userId]
	if not rewardConfig then
		return nil
	end

	local playerData = buildDefaultPlayerData()
	playerData.Coins = rewardConfig.Coins or 0
	return playerData
end

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

	local playerData = buildDefaultPlayerData()
	if success and data then
		for statName, statValue in pairs(data) do
			playerData[statName] = statValue
		end
		print("✅ " .. player.Name .. " 的云端数据读取成功！")
	else
		print("⚠️ " .. player.Name .. " 读取失败或属首次游玩，使用默认 0 资产。")
	end

	local resetRewardData = buildResetRewardData(player.UserId)
	if resetRewardData then
		playerData = resetRewardData
		print("🧪 测试白名单生效：已清空玩家 " .. player.Name .. " 的记录，并发放金币:", playerData.Coins)
	end

	-- 服务器端修改属性，会自动下发给客户端同步更新 UI
	for statName, statValue in pairs(playerData) do
		player:SetAttribute(statName, statValue)
	end

	local equippedPetsJson = player:GetAttribute("EquippedPets_JSON") or "[]"
	local legacyEquippedPetUid = player:GetAttribute("EquippedPetUid") or ""
	local legacyEquippedPetId = player:GetAttribute("EquippedPet") or ""
	if equippedPetsJson == "[]" then
		if legacyEquippedPetUid ~= "" then
			player:SetAttribute("EquippedPets_JSON", HttpService:JSONEncode({ legacyEquippedPetUid }))
		elseif legacyEquippedPetId ~= "" then
			player:SetAttribute("EquippedPets_JSON", HttpService:JSONEncode({ legacyEquippedPetId }))
		end
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
		Talent_EXP = player:GetAttribute("Talent_EXP") or 0,
		Talent_LUCK = player:GetAttribute("Talent_LUCK") or 0,
		Talent_MOVE = player:GetAttribute("Talent_MOVE") or 0,
		Talent_PET_SLOT = player:GetAttribute("Talent_PET_SLOT") or 0,
		EquippedPets_JSON = player:GetAttribute("EquippedPets_JSON") or "[]",
		Coins = player:GetAttribute("Coins") or 0,
		RebirthCount = player:GetAttribute("RebirthCount") or 0,
		CoinGainBonus = player:GetAttribute("CoinGainBonus") or 0,
		Talent_HP = player:GetAttribute("Talent_HP") or 0,
		Talent_ATK = player:GetAttribute("Talent_ATK") or 0,
		Talent_ASPD = player:GetAttribute("Talent_ASPD") or 0,
        OwnedPets_JSON = player:GetAttribute("OwnedPets_JSON") or "[]",
		EquippedPet = player:GetAttribute("EquippedPet") or "",
		EquippedPetUid = player:GetAttribute("EquippedPetUid") or "",
		EquippedPetLevel = player:GetAttribute("EquippedPetLevel") or 1,
		PetDrawTickets = player:GetAttribute("PetDrawTickets") or 0,
		ClaimedAchievements_JSON = player:GetAttribute("ClaimedAchievements_JSON") or "{}",

        -- 将第二关引导标记一起存入云端
		HasSeenStage2Guide = player:GetAttribute("HasSeenStage2Guide") or false,
		EquippedWeapon = player:GetAttribute("EquippedWeapon") or "DefaultWeapon",
		BestDistance = player:GetAttribute("BestDistance") or 0,
		BestLevel = player:GetAttribute("BestLevel") or 1,
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
