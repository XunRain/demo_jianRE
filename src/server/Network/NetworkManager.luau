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
end

return NetworkManager