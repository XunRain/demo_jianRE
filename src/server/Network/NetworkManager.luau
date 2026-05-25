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

	-- ==========================================
	-- 网络监听协议族
	-- ==========================================
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
end

return NetworkManager