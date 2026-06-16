local PurchaseManager = {}

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("Configs"):WaitForChild("GameConfig"))

local Services
local pendingReviveOffers = {}
local random = Random.new()

function PurchaseManager.Init(deps)
	Services = deps
end

local function getReviveConfig()
	local monetization = GameConfig.MONETIZATION or {}
	return monetization.Revive or {}
end

local function getInstantCoinsConfig()
	local monetization = GameConfig.MONETIZATION or {}
	return monetization.InstantCoins or {}
end

local function getStarterPackConfig()
	local monetization = GameConfig.MONETIZATION or {}
	return monetization.StarterPack or {}
end

local function getOrCreateRemote(name, className)
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end

	local remote = remotes:FindFirstChild(name)
	if remote and not remote:IsA(className) then
		warn("[PurchaseManager] Rebuilding remote with unexpected type:", name, className)
		remote:Destroy()
		remote = nil
	end

	if not remote then
		remote = Instance.new(className)
		remote.Name = name
		remote.Parent = remotes
	end

	return remote
end

local function getCreditCount(player)
	return math.max(0, math.floor(tonumber(player:GetAttribute("PaidReviveCredits")) or 0))
end

local function setCreditCount(player, count)
	player:SetAttribute("PaidReviveCredits", math.max(0, math.floor(tonumber(count) or 0)))
end

local function grantStoredReviveCredit(player)
	local previousCredits = getCreditCount(player)
	setCreditCount(player, previousCredits + 1)
	if Services and Services.DataManager and Services.DataManager.SavePlayerData then
		local saved = Services.DataManager.SavePlayerData(player)
		if not saved then
			setCreditCount(player, previousCredits)
			return false
		end
	end
	return true
end

local function schedulePlayerSave(player, delaySeconds)
	if not Services or not Services.DataManager then
		return
	end

	if Services.DataManager.ScheduleSavePlayerData then
		Services.DataManager.ScheduleSavePlayerData(player, delaySeconds)
	elseif Services.DataManager.SavePlayerData then
		task.delay(math.max(0, tonumber(delaySeconds) or 1), function()
			if player.Parent then
				Services.DataManager.SavePlayerData(player)
			end
		end)
	end
end

local function clearPendingOffer(player)
	if player then
		pendingReviveOffers[player.UserId] = nil
	end
end

local function buildReviveOfferPayload(extra)
	local reviveConfig = getReviveConfig()
	local payload = {
		Success = true,
		ProductId = tonumber(reviveConfig.ProductId) or 0,
		PriceRobux = tonumber(reviveConfig.PriceRobux) or 19,
		OfferSeconds = tonumber(reviveConfig.OfferSeconds) or 8,
	}

	if type(extra) == "table" then
		for key, value in pairs(extra) do
			payload[key] = value
		end
	end

	return payload
end

local function getInstantCoinBasis(player)
	local config = getInstantCoinsConfig()
	local minimumBasis = math.max(1, math.floor(tonumber(config.MinimumBasisCoins) or 1000))
	local maxCoinsHeld = math.max(0, math.floor(tonumber(player:GetAttribute("MaxCoinsHeld")) or 0))
	local currentCoins = math.max(0, math.floor(tonumber(player:GetAttribute("Coins")) or 0))
	return math.max(minimumBasis, maxCoinsHeld, currentCoins)
end

local function calculateInstantCoinGrant(player, tier)
	local multiplier = math.max(0, tonumber(tier and tier.Multiplier) or 0)
	return math.max(1, math.floor(getInstantCoinBasis(player) * multiplier + 0.5))
end

local function getInstantCoinTiers()
	local config = getInstantCoinsConfig()
	if config.Enabled == false or type(config.Tiers) ~= "table" then
		return {}
	end
	return config.Tiers
end

local function getInstantCoinTierByProductId(productId)
	local targetProductId = math.floor(tonumber(productId) or 0)
	if targetProductId <= 0 then
		return nil
	end

	for _, tier in ipairs(getInstantCoinTiers()) do
		if math.floor(tonumber(tier.ProductId) or 0) == targetProductId then
			return tier
		end
	end
	return nil
end

local function buildInstantCoinProducts(player)
	local products = {}
	for _, tier in ipairs(getInstantCoinTiers()) do
		local productId = math.floor(tonumber(tier.ProductId) or 0)
		table.insert(products, {
			Key = tier.Key or "",
			UiName = tier.UiName or "",
			ProductId = productId,
			Multiplier = tonumber(tier.Multiplier) or 0,
			Amount = calculateInstantCoinGrant(player, tier),
			Available = productId > 0,
		})
	end

	return {
		Success = true,
		Products = products,
		BasisCoins = getInstantCoinBasis(player),
		UpdatedAt = os.time(),
	}
end

local function decodeOwnedPets(player)
	local raw = player:GetAttribute("OwnedPets_JSON")
	if type(raw) ~= "string" or raw == "" then
		return {}
	end

	local success, decoded = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if success and type(decoded) == "table" then
		return decoded
	end

	warn("[PurchaseManager] Failed to decode OwnedPets_JSON for starter pack:", player.Name)
	return nil
end

local function getPetIdsByRarity(rarity)
	local petIds = {}
	for petId, petConfig in pairs(GameConfig.PETS or {}) do
		if type(petConfig) == "table" and petConfig.Rarity == rarity then
			table.insert(petIds, petId)
		end
	end
	table.sort(petIds)
	return petIds
end

local function chooseStarterPackPetId(config)
	local rarity = config.RewardPetRarity or "Rare"
	local petIds = getPetIdsByRarity(rarity)
	if #petIds <= 0 then
		return nil
	end

	return petIds[random:NextInteger(1, #petIds)]
end

local function buildStarterPackStatus(player)
	local config = getStarterPackConfig()
	local productId = math.floor(tonumber(config.ProductId) or 0)
	local purchased = player:GetAttribute("StarterPackPurchased") == true
	local dataLoaded = player:GetAttribute("PlayerDataLoaded") == true

	return {
		Success = true,
		DataLoaded = dataLoaded,
		Purchased = purchased,
		ProductId = productId,
		Available = dataLoaded and productId > 0 and not purchased,
		RewardCoins = math.max(0, math.floor(tonumber(config.RewardCoins) or 5000)),
		RewardPetRarity = config.RewardPetRarity or "Rare",
		RewardPetLevel = math.max(1, math.floor(tonumber(config.RewardPetLevel) or 50)),
		RewardRebirthCount = math.max(0, math.floor(tonumber(config.RewardRebirthCount) or 1)),
		OneTime = config.OneTime ~= false,
	}
end

local function snapshotAttributes(player, names)
	local snapshot = {}
	for _, name in ipairs(names) do
		snapshot[name] = player:GetAttribute(name)
	end
	return snapshot
end

local function restoreAttributes(player, snapshot)
	for name, value in pairs(snapshot) do
		player:SetAttribute(name, value)
	end
end

local function buildStarterPackSnapshotNames()
	local names = {
		"Coins",
		"MaxCoinsHeld",
		"OwnedPets_JSON",
		"StarterPackPurchased",
		"RebirthCount",
		"CoinGainBonus",
	}

	for _, talentId in ipairs((GameConfig.REBIRTH and GameConfig.REBIRTH.ResetTalents) or {}) do
		table.insert(names, talentId)
	end

	return names
end

local function applyStarterPackRebirth(player, rewardRebirthCount)
	local rebirthCount = math.max(0, math.floor(tonumber(player:GetAttribute("RebirthCount")) or 0))
	local grantedRebirths = math.max(0, math.floor(tonumber(rewardRebirthCount) or 0))
	local nextRebirthCount = rebirthCount + grantedRebirths

	for _, talentId in ipairs((GameConfig.REBIRTH and GameConfig.REBIRTH.ResetTalents) or {}) do
		player:SetAttribute(talentId, 0)
	end

	player:SetAttribute("RebirthCount", nextRebirthCount)
	player:SetAttribute("CoinGainBonus", GameConfig.GetRebirthCoinGainBonus(nextRebirthCount))
end

local function processStarterPackReceipt(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local config = getStarterPackConfig()
	if config.OneTime ~= false and player:GetAttribute("StarterPackPurchased") == true then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	if player:GetAttribute("PlayerDataLoaded") ~= true then
		warn("[PurchaseManager] Starter pack receipt delayed until player data is loaded:", player.Name)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local rewardPetId = chooseStarterPackPetId(config)
	if not rewardPetId then
		warn("[PurchaseManager] Starter pack has no available pet with rarity:", config.RewardPetRarity or "Rare")
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local ownedPets = decodeOwnedPets(player)
	if not ownedPets then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if not Services or not Services.DataManager or type(Services.DataManager.SavePlayerData) ~= "function" then
		warn("[PurchaseManager] Starter pack cannot save because DataManager is unavailable.")
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local snapshot = snapshotAttributes(player, buildStarterPackSnapshotNames())
	local rewardCoins = math.max(0, math.floor(tonumber(config.RewardCoins) or 5000))
	local rewardPetLevel = math.max(1, math.floor(tonumber(config.RewardPetLevel) or 50))
	local rewardRebirthCount = math.max(0, math.floor(tonumber(config.RewardRebirthCount) or 1))
	local previousCoins = math.max(0, math.floor(tonumber(player:GetAttribute("Coins")) or 0))
	local previousMaxCoinsHeld = math.max(0, math.floor(tonumber(player:GetAttribute("MaxCoinsHeld")) or 0))
	local nextCoins = previousCoins + rewardCoins

	table.insert(ownedPets, {
		Uid = HttpService:GenerateGUID(false),
		Id = rewardPetId,
		Level = rewardPetLevel,
	})

	player:SetAttribute("OwnedPets_JSON", HttpService:JSONEncode(ownedPets))
	player:SetAttribute("Coins", nextCoins)
	player:SetAttribute("MaxCoinsHeld", math.max(previousMaxCoinsHeld, nextCoins))
	applyStarterPackRebirth(player, rewardRebirthCount)
	player:SetAttribute("StarterPackPurchased", true)

	local saved = Services.DataManager.SavePlayerData(player)
	if not saved then
		restoreAttributes(player, snapshot)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local function startReviveOffer(player)
	local reviveConfig = getReviveConfig()
	local offerSeconds = tonumber(reviveConfig.OfferSeconds) or 8
	local productId = tonumber(reviveConfig.ProductId) or 0

	local credits = getCreditCount(player)
	if credits > 0 then
		setCreditCount(player, credits - 1)
		schedulePlayerSave(player, 1)
		return buildReviveOfferPayload({
			GrantNow = true,
			UsedStoredCredit = true,
		})
	end

	pendingReviveOffers[player.UserId] = {
		Player = player,
		ExpiresAt = os.clock() + offerSeconds + 60,
	}

	if productId <= 0 then
		warn("[PurchaseManager] Revive Developer ProductId is not configured yet.")
	end

	return buildReviveOfferPayload()
end

local function processReviveReceipt(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local reviveGranted = getOrCreateRemote("ReviveGranted", "RemoteEvent")
	local pendingOffer = pendingReviveOffers[player.UserId]
	if pendingOffer and pendingOffer.Player == player and pendingOffer.ExpiresAt >= os.clock() then
		pendingReviveOffers[player.UserId] = nil
		reviveGranted:FireClient(player, {
			ProductId = receiptInfo.ProductId,
			PurchaseId = receiptInfo.PurchaseId,
		})
	else
		if not grantStoredReviveCredit(player) then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
	end

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local function processInstantCoinReceipt(receiptInfo, tier)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local grantAmount = calculateInstantCoinGrant(player, tier)
	local previousCoins = math.max(0, math.floor(tonumber(player:GetAttribute("Coins")) or 0))
	local previousMaxCoinsHeld = math.max(0, math.floor(tonumber(player:GetAttribute("MaxCoinsHeld")) or 0))
	local newCoins = previousCoins + grantAmount

	player:SetAttribute("Coins", newCoins)
	player:SetAttribute("MaxCoinsHeld", math.max(previousMaxCoinsHeld, newCoins))

	if Services and Services.DataManager and Services.DataManager.SavePlayerData then
		local saved = Services.DataManager.SavePlayerData(player)
		if not saved then
			player:SetAttribute("Coins", previousCoins)
			player:SetAttribute("MaxCoinsHeld", previousMaxCoinsHeld)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
	end

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function PurchaseManager.Start()
	local startReviveOfferRemote = getOrCreateRemote("StartReviveOffer", "RemoteFunction")
	startReviveOfferRemote.OnServerInvoke = startReviveOffer

	local getInstantCoinProductsRemote = getOrCreateRemote("GetInstantCoinProducts", "RemoteFunction")
	getInstantCoinProductsRemote.OnServerInvoke = buildInstantCoinProducts

	local getStarterPackStatusRemote = getOrCreateRemote("GetStarterPackStatus", "RemoteFunction")
	getStarterPackStatusRemote.OnServerInvoke = buildStarterPackStatus

	local cancelReviveOfferRemote = getOrCreateRemote("CancelReviveOffer", "RemoteEvent")
	cancelReviveOfferRemote.OnServerEvent:Connect(clearPendingOffer)

	getOrCreateRemote("ReviveGranted", "RemoteEvent")

	MarketplaceService.ProcessReceipt = function(receiptInfo)
		local reviveConfig = getReviveConfig()
		local reviveProductId = tonumber(reviveConfig.ProductId) or 0

		if reviveProductId > 0 and receiptInfo.ProductId == reviveProductId then
			return processReviveReceipt(receiptInfo)
		end

		local starterPackConfig = getStarterPackConfig()
		local starterPackProductId = tonumber(starterPackConfig.ProductId) or 0
		if starterPackProductId > 0 and receiptInfo.ProductId == starterPackProductId then
			return processStarterPackReceipt(receiptInfo)
		end

		local instantCoinTier = getInstantCoinTierByProductId(receiptInfo.ProductId)
		if instantCoinTier then
			return processInstantCoinReceipt(receiptInfo, instantCoinTier)
		end

		warn("[PurchaseManager] Unhandled developer product receipt:", receiptInfo.ProductId)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	Players.PlayerRemoving:Connect(function(player)
		pendingReviveOffers[player.UserId] = nil
	end)
end

return PurchaseManager
