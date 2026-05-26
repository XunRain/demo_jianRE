-- src/server/Network/NetworkManager.luau
local NetworkManager = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Services -- 全局服务引用指针

-- 引入公共配置
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("Configs"):WaitForChild("GameConfig"))

function NetworkManager.Init(deps)
	Services = deps
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

	-- 1. 抽卡请求 (使用 RemoteFunction，因为需要向客户端返回抽到了什么)
	local rollPetRF = remotes:FindFirstChild("RollPet") or Instance.new("RemoteFunction", remotes)
	rollPetRF.Name = "RollPet"
	
	rollPetRF.OnServerInvoke = function(player)
		local coins = player:GetAttribute("Coins") or 0
		if coins >= GameConfig.PET_GACHA_COST then
			-- 扣钱
			player:SetAttribute("Coins", coins - GameConfig.PET_GACHA_COST)
			
			-- 随机出货
			local pool = GameConfig.PET_POOL
			local resultId = pool[math.random(1, #pool)]
			
			-- 解析 JSON 背包 -> 塞入新宠物 -> 重新压成 JSON 存入玩家属性
			local owned = HttpService:JSONDecode(player:GetAttribute("OwnedPets_JSON") or "[]")
			table.insert(owned, resultId)
			player:SetAttribute("OwnedPets_JSON", HttpService:JSONEncode(owned))
			
			print(player.Name .. " 抽中了宠物: " .. resultId)
			return resultId -- 将抽奖结果返回给客户端用于展示特效
		end
		return nil
	end

	-- 2. 装备/卸下宠物请求
	local equipPetEvent = remotes:FindFirstChild("EquipPet") or Instance.new("RemoteEvent", remotes)
	equipPetEvent.Name = "EquipPet"
	
	equipPetEvent.OnServerEvent:Connect(function(player, petId)
		-- 如果传过来的是空字符串，说明玩家点击了卸下宠物
		if petId == "" then
			player:SetAttribute("EquippedPet", "")
			return
		end

		local owned = HttpService:JSONDecode(player:GetAttribute("OwnedPets_JSON") or "[]")
		-- 校验是否真的拥有该宠物
		if table.find(owned, petId) then
			player:SetAttribute("EquippedPet", petId)
		end
	end)
end

return NetworkManager