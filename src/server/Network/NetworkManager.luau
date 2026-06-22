-- src/server/Network/NetworkManager.luau
local NetworkManager = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local _Services -- 全局服务引用指针，当前模块暂不直接使用

-- 引入公共配置
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("Configs"):WaitForChild("GameConfig"))

function NetworkManager.Init(deps)
	_Services = deps
end

local function scheduleSave(player, delaySeconds)
	if not player or not _Services or not _Services.DataManager then
		return
	end

	if _Services.DataManager.ScheduleSavePlayerData then
		_Services.DataManager.ScheduleSavePlayerData(player, delaySeconds)
	elseif _Services.DataManager.SavePlayerData then
		task.delay(math.max(0, tonumber(delaySeconds) or 5), function()
			if player.Parent then
				_Services.DataManager.SavePlayerData(player)
			end
		end)
	end
end

local function trackAnalytics(player, eventName, fields, value)
	if _Services and _Services.AnalyticsManager and _Services.AnalyticsManager.Track then
		_Services.AnalyticsManager.Track(player, eventName, fields, value)
	end
end

local function markShopBought(player)
	if _Services and _Services.AnalyticsManager and _Services.AnalyticsManager.MarkShopBought then
		_Services.AnalyticsManager.MarkShopBought(player)
	end
end

local function getTimeSinceJoin(player)
	if _Services and _Services.AnalyticsManager and _Services.AnalyticsManager.GetTimeSinceJoin then
		return _Services.AnalyticsManager.GetTimeSinceJoin(player)
	end
	return 0
end

function NetworkManager.Start()
	-- 1. 自动化建立前后端通信文件夹
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end

	-- 2. 自动化注册并初始化加钱网络信道
	local addCoinEvent = remotes:FindFirstChild("AddCoin")
	if not addCoinEvent then
		addCoinEvent = Instance.new("RemoteEvent")
		addCoinEvent.Name = "AddCoin"
		addCoinEvent.Parent = remotes
	end

	-- 网络监听协议族
	-- 协议 A：处理客户端发来的拾取金币请求
	addCoinEvent.OnServerEvent:Connect(function(player, amount)
		if player:GetAttribute("RunInCombat") ~= true then
			warn("[NetworkManager] Blocked AddCoin outside combat from", player.Name)
			return
		end

		-- 安全网闸：过滤各种非法数值，防止作弊刷钱
		if type(amount) ~= "number" or amount <= 0 or amount > 500 then 
			warn("⚠️ 拦截到来自玩家 " .. player.Name .. " 的异常加钱请求！")
			return 
		end
		
		-- 验证通过，允许增值
		local currentCoins = player:GetAttribute("Coins") or 0
		player:SetAttribute("Coins", currentCoins + math.max(1, math.floor(amount + 0.5)))
		scheduleSave(player, 30)
	end)


    -- 注册购买天赋的网络信道
	local buyTalentEvent = remotes:FindFirstChild("BuyTalent") or Instance.new("RemoteEvent", remotes)
	buyTalentEvent.Name = "BuyTalent"
	local talentPurchaseFailedEvent = remotes:FindFirstChild("TalentPurchaseFailed") or Instance.new("RemoteEvent", remotes)
	talentPurchaseFailedEvent.Name = "TalentPurchaseFailed"

	-- 监听客户端的购买请求
	buyTalentEvent.OnServerEvent:Connect(function(player, talentId)
		local requestedTalentId = talentId
		if type(talentId) == "number" or (type(talentId) == "string" and string.match(talentId, "^%d+$")) then
			talentId = GameConfig.GetTalentIdByProductId(talentId)
		end
		if not talentId then
			trackAnalytics(player, "talent_buy_fail", {
				talent_id = tostring(requestedTalentId),
				reason = "invalid_talent",
				cost = 0,
				coins_before = player:GetAttribute("Coins") or 0,
				talent_level_before = 0,
			})
			return
		end

		local talentConfig = GameConfig.TALENTS[talentId]
		if not talentConfig then
			trackAnalytics(player, "talent_buy_fail", {
				talent_id = tostring(talentId),
				reason = "invalid_talent",
				cost = 0,
				coins_before = player:GetAttribute("Coins") or 0,
				talent_level_before = 0,
			})
			return
		end

		local currentLevel = math.max(0, math.floor(player:GetAttribute(talentId) or 0))
		local currentCoins = player:GetAttribute("Coins") or 0
		local cost = GameConfig.GetTalentCost(talentId, currentLevel)
		trackAnalytics(player, "talent_buy_attempt", {
			talent_id = tostring(talentId),
			talent_level_before = currentLevel,
			cost = cost == math.huge and -1 or cost,
			coins_before = currentCoins,
			run_index = player:GetAttribute("AnalyticsRunIndex") or 0,
			death_count = player:GetAttribute("AnalyticsDeathCount") or 0,
		})

		if talentConfig.MaxLevel and currentLevel >= talentConfig.MaxLevel then
			trackAnalytics(player, "talent_buy_fail", {
				talent_id = tostring(talentId),
				reason = "max_level",
				cost = cost == math.huge and -1 or cost,
				coins_before = currentCoins,
				talent_level_before = currentLevel,
			})
			talentPurchaseFailedEvent:FireClient(player, {
				Reason = "MaxLevel",
				TalentId = tostring(talentId),
				Cost = cost == math.huge and -1 or cost,
				Coins = currentCoins,
			})
			return
		end

		if cost ~= math.huge and currentCoins >= cost then
			player:SetAttribute("Coins", currentCoins - cost)
			player:SetAttribute(talentId, currentLevel + 1)
			scheduleSave(player, 3)
			markShopBought(player)
			trackAnalytics(player, "talent_buy_success", {
				talent_id = tostring(talentId),
				talent_level_before = currentLevel,
				talent_level_after = currentLevel + 1,
				cost = cost,
				coins_before = currentCoins,
				coins_after = currentCoins - cost,
			})
			print(string.format("[NetworkManager] %s bought %s Lv.%d for %d coins.", player.Name, talentConfig.Name, currentLevel + 1, cost))
		else
			trackAnalytics(player, "talent_buy_fail", {
				talent_id = tostring(talentId),
				reason = "not_enough_coins",
				cost = cost == math.huge and -1 or cost,
				coins_before = currentCoins,
				talent_level_before = currentLevel,
			})
			talentPurchaseFailedEvent:FireClient(player, {
				Reason = "NotEnoughCoins",
				TalentId = tostring(talentId),
				Cost = cost == math.huge and -1 or cost,
				Coins = currentCoins,
			})
		end
	end)


    -- 宠物抽卡与装备宠物
    local HttpService = game:GetService("HttpService")

	-- 安全解析玩家宠物背包；坏 JSON 或未知宠物会被过滤掉，避免服务端流程报错
	local rebirthRF = remotes:FindFirstChild("Rebirth") or Instance.new("RemoteFunction", remotes)
	rebirthRF.Name = "Rebirth"
	rebirthRF.OnServerInvoke = function(player)
		local currentRebirthCount = math.max(0, math.floor(tonumber(player:GetAttribute("RebirthCount")) or 0))
		local currentCoins = math.max(0, math.floor(tonumber(player:GetAttribute("Coins")) or 0))
		local currentCoinGainBonus = math.max(
			0,
			tonumber(player:GetAttribute("CoinGainBonus")) or GameConfig.GetRebirthCoinGainBonus(currentRebirthCount)
		)
		local cost = GameConfig.GetRebirthCost(currentRebirthCount)
		local nextRebirthCount = currentRebirthCount + 1
		local nextCoinGainBonus = GameConfig.GetRebirthCoinGainBonus(nextRebirthCount)

		if currentCoins < cost then
			return {
				Success = false,
				Reason = "NotEnoughCoins",
				Cost = cost,
				Coins = currentCoins,
				RebirthCount = currentRebirthCount,
				CoinGainBonus = currentCoinGainBonus,
				NextCoinGainBonus = nextCoinGainBonus,
			}
		end

		player:SetAttribute("Coins", currentCoins - cost)
		for _, talentId in ipairs((GameConfig.REBIRTH and GameConfig.REBIRTH.ResetTalents) or {}) do
			player:SetAttribute(talentId, 0)
		end
		player:SetAttribute("RebirthCount", nextRebirthCount)
		player:SetAttribute("CoinGainBonus", nextCoinGainBonus)
		scheduleSave(player, 1)

		return {
			Success = true,
			Cost = cost,
			Coins = currentCoins - cost,
			RebirthCount = nextRebirthCount,
			CoinGainBonus = nextCoinGainBonus,
			NextCost = GameConfig.GetRebirthCost(nextRebirthCount),
		}
	end

	local function decodeOwnedPets(player)
		local success, decoded = pcall(function()
			return HttpService:JSONDecode(player:GetAttribute("OwnedPets_JSON") or "[]")
		end)

		if not success or type(decoded) ~= "table" then
			return {}
		end

		local owned = {}
		local needsMigration = false
		for index, petEntry in ipairs(decoded) do
			if type(petEntry) == "string" and GameConfig.PETS[petEntry] then
				needsMigration = true
				table.insert(owned, {
					Uid = string.format("legacy_%d_%s_%d", player.UserId, petEntry, index),
					Id = petEntry,
					Level = GameConfig.PET_LEVEL_MIN or 1,
				})
			elseif type(petEntry) == "table" and type(petEntry.Id) == "string" and GameConfig.PETS[petEntry.Id] then
				local uid = type(petEntry.Uid) == "string" and petEntry.Uid or string.format("pet_%d_%d_%d", player.UserId, os.time(), index)
				local level = GameConfig.NormalizePetLevel and GameConfig.NormalizePetLevel(petEntry.Level) or math.max(1, math.floor(tonumber(petEntry.Level) or 1))
				if uid ~= petEntry.Uid or level ~= petEntry.Level then
					needsMigration = true
				end
				table.insert(owned, {
					Uid = uid,
					Id = petEntry.Id,
					Level = level,
				})
			end
		end

		if needsMigration then
			player:SetAttribute("OwnedPets_JSON", HttpService:JSONEncode(owned))
		end

		return owned
	end

	local function createPetInstance(player, petId)
		local minLevel = GameConfig.PET_LEVEL_MIN or 1
		local maxLevel = GameConfig.PET_LEVEL_MAX or 100
		return {
			Uid = HttpService:GenerateGUID(false),
			Id = petId,
			Level = math.random(minLevel, maxLevel),
		}
	end

	local function getMaxEquippedPetSlots(player)
		return 1 + math.max(0, math.floor(player:GetAttribute("Talent_PET_SLOT") or 0))
	end

	local function decodeEquippedPetUids(player)
		local success, decoded = pcall(function()
			return HttpService:JSONDecode(player:GetAttribute("EquippedPets_JSON") or "[]")
		end)

		local equipped = {}
		local seen = {}
		if success and type(decoded) == "table" then
			for _, uid in ipairs(decoded) do
				if type(uid) == "string" and uid ~= "" and not seen[uid] then
					seen[uid] = true
					table.insert(equipped, uid)
				end
			end
		end

		local legacyUid = player:GetAttribute("EquippedPetUid") or ""
		if #equipped == 0 and legacyUid ~= "" then
			table.insert(equipped, legacyUid)
		end

		local legacyPetId = player:GetAttribute("EquippedPet") or ""
		if #equipped == 0 and legacyPetId ~= "" then
			table.insert(equipped, legacyPetId)
		end

		return equipped
	end

	local function findOwnedPetByUidOrId(owned, petUidOrId)
		for _, petEntry in ipairs(owned) do
			if petEntry.Uid == petUidOrId or petEntry.Id == petUidOrId then
				return petEntry
			end
		end
		return nil
	end

	local function syncEquippedPetAttributes(player, owned, equippedUids)
		local validUids = {}
		local firstEntry = nil
		local maxSlots = getMaxEquippedPetSlots(player)

		for _, uid in ipairs(equippedUids) do
			if #validUids >= maxSlots then break end
			local petEntry = findOwnedPetByUidOrId(owned, uid)
			if petEntry then
				table.insert(validUids, petEntry.Uid)
				firstEntry = firstEntry or petEntry
			end
		end

		player:SetAttribute("EquippedPets_JSON", HttpService:JSONEncode(validUids))
		if firstEntry then
			player:SetAttribute("EquippedPet", firstEntry.Id)
			player:SetAttribute("EquippedPetUid", firstEntry.Uid)
			player:SetAttribute("EquippedPetLevel", GameConfig.NormalizePetLevel and GameConfig.NormalizePetLevel(firstEntry.Level) or firstEntry.Level or 1)
		else
			player:SetAttribute("EquippedPet", "")
			player:SetAttribute("EquippedPetUid", "")
			player:SetAttribute("EquippedPetLevel", 1)
		end
	end

	-- 1. 抽卡请求 (使用 RemoteFunction，因为需要向客户端返回抽到了什么)
	local rollPetRF = remotes:FindFirstChild("RollPet") or Instance.new("RemoteFunction", remotes)
	rollPetRF.Name = "RollPet"
	
	rollPetRF.OnServerInvoke = function(player)
		local tickets = math.max(0, math.floor(player:GetAttribute("PetDrawTickets") or 0))
		local ticketCost = math.max(1, math.floor(GameConfig.PET_DRAW_TICKET_COST or 1))
		local ownedBefore = decodeOwnedPets(player)
		local ownedCountBefore = #ownedBefore
		trackAnalytics(player, "pet_draw_attempt", {
			tickets_before = tickets,
			coins = player:GetAttribute("Coins") or 0,
			owned_pet_count = ownedCountBefore,
			has_equipped_pet = (player:GetAttribute("EquippedPetUid") or "") ~= "" or (player:GetAttribute("EquippedPet") or "") ~= "",
		})
		if tickets < ticketCost then
			return nil
		end

		player:SetAttribute("PetDrawTickets", tickets - ticketCost)

		-- 按宠物配置表权重随机出货
		local resultId = GameConfig.RollPetId()
		if not resultId or not GameConfig.PETS[resultId] then
			warn("宠物抽卡失败：配置表没有可用宠物。")
			player:SetAttribute("PetDrawTickets", tickets)
			return nil
		end

		-- 解析 JSON 背包 -> 塞入新宠物 -> 重新压成 JSON 存入玩家属性
		local owned = ownedBefore
		local petInstance = createPetInstance(player, resultId)
		table.insert(owned, petInstance)
		player:SetAttribute("OwnedPets_JSON", HttpService:JSONEncode(owned))
		scheduleSave(player, 1)
		trackAnalytics(player, "pet_draw_success", {
			pet_id = petInstance.Id,
			pet_uid = petInstance.Uid,
			pet_level = petInstance.Level,
			tickets_after = math.max(0, math.floor(player:GetAttribute("PetDrawTickets") or 0)),
			owned_pet_count_after = #owned,
		})
		if ownedCountBefore == 0 then
			trackAnalytics(player, "first_pet_obtained", {
				pet_id = petInstance.Id,
				pet_level = petInstance.Level,
				time_since_join = getTimeSinceJoin(player),
				run_index = player:GetAttribute("AnalyticsRunIndex") or 0,
			})
		end

		print(string.format("%s 抽中了宠物: %s Lv.%d", player.Name, resultId, petInstance.Level))
		return petInstance -- 将抽奖结果返回给客户端用于展示特效
	end

	-- 1.5 购买抽宠次数：服务端扣金币并增加 PetDrawTickets，避免客户端作弊直接改属性
	local buyPetDrawTicketRF = remotes:FindFirstChild("BuyPetDrawTicket") or Instance.new("RemoteFunction", remotes)
	buyPetDrawTicketRF.Name = "BuyPetDrawTicket"

	buyPetDrawTicketRF.OnServerInvoke = function(player)
		local cost = math.max(1, math.floor(GameConfig.PET_DRAW_BUY_COST or 10000))
		local currentCoins = math.max(0, math.floor(player:GetAttribute("Coins") or 0))
		if currentCoins < cost then
			return {
				Success = false,
				Reason = "NotEnoughCoins",
				Cost = cost,
				Coins = currentCoins,
				Tickets = math.max(0, math.floor(player:GetAttribute("PetDrawTickets") or 0)),
			}
		end

		local tickets = math.max(0, math.floor(player:GetAttribute("PetDrawTickets") or 0))
		local newTickets = tickets + 1
		player:SetAttribute("Coins", currentCoins - cost)
		player:SetAttribute("PetDrawTickets", newTickets)
		scheduleSave(player, 1)
		trackAnalytics(player, "pet_draw_ticket_buy_success", {
			cost = cost,
			coins_before = currentCoins,
			coins_after = currentCoins - cost,
			tickets_before = tickets,
			tickets_after = newTickets,
		})

		return {
			Success = true,
			Cost = cost,
			Coins = currentCoins - cost,
			Tickets = newTickets,
		}
	end

	-- 2. 装备/卸下宠物请求
	local equipPetEvent = remotes:FindFirstChild("EquipPet") or Instance.new("RemoteEvent", remotes)
	equipPetEvent.Name = "EquipPet"
	local equipPetFailedEvent = remotes:FindFirstChild("EquipPetFailed") or Instance.new("RemoteEvent", remotes)
	equipPetFailedEvent.Name = "EquipPetFailed"
	
	equipPetEvent.OnServerEvent:Connect(function(player, petUidOrId)
		if type(petUidOrId) ~= "string" then
			return
		end

		local owned = decodeOwnedPets(player)

		if petUidOrId == "" then
			syncEquippedPetAttributes(player, owned, {})
			scheduleSave(player, 3)
			return
		end

		local petEntry = findOwnedPetByUidOrId(owned, petUidOrId)
		if not petEntry then
			return
		end

		local equippedUids = decodeEquippedPetUids(player)
		for index, uid in ipairs(equippedUids) do
			if uid == petEntry.Uid then
				table.remove(equippedUids, index)
				syncEquippedPetAttributes(player, owned, equippedUids)
				scheduleSave(player, 3)
				return
			end
		end

		if #equippedUids >= getMaxEquippedPetSlots(player) then
			equipPetFailedEvent:FireClient(player, {
				Reason = "EquippedSlotsFull",
				Message = "Equipped pet slots are full. Please unequip a pet first.",
			})
			return
		end

		local previousPetId = player:GetAttribute("EquippedPet") or ""
		table.insert(equippedUids, petEntry.Uid)
		syncEquippedPetAttributes(player, owned, equippedUids)
		scheduleSave(player, 3)
		trackAnalytics(player, "pet_equip", {
			pet_id = petEntry.Id,
			pet_uid = petEntry.Uid,
			pet_level = petEntry.Level,
			owned_pet_count = #owned,
			previous_pet_id = previousPetId,
		})
	end)

	-- 2.5 删除宠物请求：只能删除玩家自己背包里存在的宠物实例。
	local removePetEvent = remotes:FindFirstChild("RemovePet") or Instance.new("RemoteEvent", remotes)
	removePetEvent.Name = "RemovePet"

	removePetEvent.OnServerEvent:Connect(function(player, petUidOrId)
		if type(petUidOrId) ~= "string" or petUidOrId == "" then
			return
		end

		local owned = decodeOwnedPets(player)
		local removedEntry = nil
		for index, petEntry in ipairs(owned) do
			-- 优先按唯一实例 ID 删除；保留 petId 兼容但只会删除第一只同 ID 宠物。
			if petEntry.Uid == petUidOrId or petEntry.Id == petUidOrId then
				removedEntry = petEntry
				table.remove(owned, index)
				break
			end
		end

		if not removedEntry then
			return
		end

		player:SetAttribute("OwnedPets_JSON", HttpService:JSONEncode(owned))
		local equippedUids = decodeEquippedPetUids(player)
		local filteredEquippedUids = {}
		for _, uid in ipairs(equippedUids) do
			if uid ~= removedEntry.Uid then
				table.insert(filteredEquippedUids, uid)
			end
		end
		syncEquippedPetAttributes(player, owned, filteredEquippedUids)
		scheduleSave(player, 3)
	end)

	local markStartGuideEvent = remotes:FindFirstChild("MarkStartGuideSeen") or Instance.new("RemoteEvent", remotes)
	markStartGuideEvent.Name = "MarkStartGuideSeen"
	markStartGuideEvent.OnServerEvent:Connect(function(player)
		local wasSeen = player:GetAttribute("HasSeenStartGuide") == true
		player:SetAttribute("HasSeenStartGuide", true)
		if not wasSeen then
			trackAnalytics(player, "tutorial_completed", {
				tutorial_id = "start_guide",
				complete_stage = player:GetAttribute("CurrentStage") or 0,
				time_since_join = getTimeSinceJoin(player),
			})
		end
		scheduleSave(player, 3)
	end)

    -- 注册并监听第二关引导标记的写入请求
	local markGuideEvent = remotes:FindFirstChild("MarkGuideSeen") or Instance.new("RemoteEvent", remotes)
	local markPetGuideEvent = remotes:FindFirstChild("MarkPetGuideSeen") or Instance.new("RemoteEvent", remotes)
	markPetGuideEvent.Name = "MarkPetGuideSeen"
	markPetGuideEvent.OnServerEvent:Connect(function(player)
		local wasSeen = player:GetAttribute("HasSeenPetGuide") == true
		player:SetAttribute("HasSeenPetGuide", true)
		if not wasSeen then
			trackAnalytics(player, "tutorial_completed", {
				tutorial_id = "pet_guide",
				complete_stage = player:GetAttribute("CurrentStage") or 0,
				time_since_join = getTimeSinceJoin(player),
			})
		end
		scheduleSave(player, 3)
	end)

	markGuideEvent.Name = "MarkGuideSeen"

	markGuideEvent.OnServerEvent:Connect(function(player)
		-- 在服务端写下标记，Roblox 底层会自动将这个 Attribute 同步回客户端
		player:SetAttribute("HasSeenStage2Guide", true)
		trackAnalytics(player, "tutorial_completed", {
			tutorial_id = "stage2_guide",
			complete_stage = player:GetAttribute("CurrentStage") or 0,
			time_since_join = getTimeSinceJoin(player),
		})
		scheduleSave(player, 3)
		print(player.Name .. " 已触发过第二关引导，打上永久防打扰思想钢印。")
	end)
end

return NetworkManager
