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
		-- 安全网闸：过滤各种非法数值，防止作弊刷钱
		if type(amount) ~= "number" or amount <= 0 or amount > 500 then 
			warn("⚠️ 拦截到来自玩家 " .. player.Name .. " 的异常加钱请求！")
			return 
		end
		
		-- 验证通过，允许增值
		local currentCoins = player:GetAttribute("Coins") or 0
		player:SetAttribute("Coins", currentCoins + amount)
	end)


    -- 注册购买天赋的网络信道
	local buyTalentEvent = remotes:FindFirstChild("BuyTalent") or Instance.new("RemoteEvent", remotes)
	buyTalentEvent.Name = "BuyTalent"

	-- 监听客户端的购买请求
	buyTalentEvent.OnServerEvent:Connect(function(player, talentId)
		-- 从公共配置表校验是否有这个天赋
		local talentConfig = GameConfig.TALENTS[talentId]
		if not talentConfig then return end 

		local currentLevel = player:GetAttribute(talentId) or 0
		local currentCoins = player:GetAttribute("Coins") or 0

		-- 统一调用公共配置表里的计费公式
		local cost = GameConfig.GetTalentCost(talentId, currentLevel)

		-- 钱够就扣钱加级
		if currentCoins >= cost then
			player:SetAttribute("Coins", currentCoins - cost)
			player:SetAttribute(talentId, currentLevel + 1)
			print(string.format("%s 成功购买 %s Lv.%d (花费: %d)", player.Name, talentConfig.Name, currentLevel + 1, cost))
		end
	end)


    -- 宠物抽卡与装备宠物
    local HttpService = game:GetService("HttpService")

	-- 安全解析玩家宠物背包；坏 JSON 或未知宠物会被过滤掉，避免服务端流程报错
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

	-- 1. 抽卡请求 (使用 RemoteFunction，因为需要向客户端返回抽到了什么)
	local rollPetRF = remotes:FindFirstChild("RollPet") or Instance.new("RemoteFunction", remotes)
	rollPetRF.Name = "RollPet"
	
	rollPetRF.OnServerInvoke = function(player)
		local tickets = math.max(0, math.floor(player:GetAttribute("PetDrawTickets") or 0))
		local ticketCost = math.max(1, math.floor(GameConfig.PET_DRAW_TICKET_COST or 1))
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
		local owned = decodeOwnedPets(player)
		local petInstance = createPetInstance(player, resultId)
		table.insert(owned, petInstance)
		player:SetAttribute("OwnedPets_JSON", HttpService:JSONEncode(owned))

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
	
	equipPetEvent.OnServerEvent:Connect(function(player, petUidOrId)
		-- 如果传过来的是空字符串，说明玩家点击了卸下宠物
		if petUidOrId == "" then
			player:SetAttribute("EquippedPet", "")
			player:SetAttribute("EquippedPetUid", "")
			player:SetAttribute("EquippedPetLevel", 1)
			return
		end

		if type(petUidOrId) ~= "string" then
			return
		end

		local owned = decodeOwnedPets(player)
		-- 优先按唯一实例 ID 装备；兼容旧客户端传 petId 时选择第一只同 ID 宠物。
		for _, petEntry in ipairs(owned) do
			if petEntry.Uid == petUidOrId or petEntry.Id == petUidOrId then
				player:SetAttribute("EquippedPet", petEntry.Id)
				player:SetAttribute("EquippedPetUid", petEntry.Uid)
				player:SetAttribute("EquippedPetLevel", GameConfig.NormalizePetLevel and GameConfig.NormalizePetLevel(petEntry.Level) or petEntry.Level or 1)
				return
			end
		end
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

		-- 如果删除的是当前装备宠物，清空装备状态，避免后续战斗引用不存在的宠物实例。
		-- 新存档按 Uid 精确判断；只有旧存档没有 EquippedPetUid 时才按宠物 Id 兼容。
		local equippedUid = player:GetAttribute("EquippedPetUid") or ""
		local removedEquippedPet = equippedUid ~= "" and equippedUid == removedEntry.Uid
		if not removedEquippedPet and equippedUid == "" then
			removedEquippedPet = player:GetAttribute("EquippedPet") == removedEntry.Id
		end

		if removedEquippedPet then
			player:SetAttribute("EquippedPet", "")
			player:SetAttribute("EquippedPetUid", "")
			player:SetAttribute("EquippedPetLevel", 1)
		end
	end)

    -- 注册并监听第二关引导标记的写入请求
	local markGuideEvent = remotes:FindFirstChild("MarkGuideSeen") or Instance.new("RemoteEvent", remotes)
	markGuideEvent.Name = "MarkGuideSeen"

	markGuideEvent.OnServerEvent:Connect(function(player)
		-- 在服务端写下标记，Roblox 底层会自动将这个 Attribute 同步回客户端
		player:SetAttribute("HasSeenStage2Guide", true)
		print(player.Name .. " 已触发过第二关引导，打上永久防打扰思想钢印。")
	end)
end

return NetworkManager
