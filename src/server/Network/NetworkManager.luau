-- src/server/Network/NetworkManager.luau
local NetworkManager = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Services -- 全局服务引用指针

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

	-- 天赋价格配置 (基础价格 与 每次升级的价格乘数)
	local TALENT_COSTS = {
		Talent_HP = { base = 50, multi = 1.5 },
		Talent_ATK = { base = 100, multi = 2.0 },
		Talent_ASPD = { base = 200, multi = 2.5 }
	}

	-- 监听客户端的购买请求
	buyTalentEvent.OnServerEvent:Connect(function(player, talentName)
		local costConfig = TALENT_COSTS[talentName]
		if not costConfig then return end -- 防止发送非法天赋名

		local currentLevel = player:GetAttribute(talentName) or 0
		local currentCoins = player:GetAttribute("Coins") or 0

		-- 计算当前等级需要的真实金币：基础价格 * (乘数 ^ 当前等级)
		local cost = math.floor(costConfig.base * (costConfig.multi ^ currentLevel))

		-- 钱够就扣钱，加等级（服务端修改会自动下发给客户端）
		if currentCoins >= cost then
			player:SetAttribute("Coins", currentCoins - cost)
			player:SetAttribute(talentName, currentLevel + 1)
			print(player.Name .. " 成功购买了 " .. talentName .. " Lv." .. (currentLevel + 1))
		end
	end)
end

return NetworkManager