local AnalyticsManager = {}

local AnalyticsService = game:GetService("AnalyticsService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("Configs"):WaitForChild("GameConfig"))

local Services
local states = {}
local clientThrottle = {}

local DEFAULT_ALLOWED_CLIENT_EVENTS = {
	level_up_triggered = true,
	level_up_cards_shown = true,
	level_up_card_selected = true,
	gate_chosen = true,
	enemy_killed = true,
	elite_killed = true,
	boss_killed = true,
	shop_open = true,
	shop_close = true,
	pet_hatch_open = true,
	stage_reached = true,
}

local function getConfig()
	return GameConfig.ANALYTICS or {}
end

local function isEnabled()
	return getConfig().Enabled ~= false
end

local function ensureState(player)
	local state = states[player]
	if not state then
		state = {
			JoinClock = os.clock(),
			JoinUnix = os.time(),
			RunIndex = 0,
			DeathCount = 0,
			HasStartedRun = false,
			InRun = false,
			RunStartClock = nil,
			RunStartBestDistance = 0,
			RunStartCoins = 0,
			CurrentStage = 1,
			RunMaxStage = 1,
			RunMaxDistance = 0,
			RunMaxLevel = 1,
			SeenStages = {},
			DistanceMilestonesHit = {},
			FirstRunStageReported = false,
			LastRunDistance = 0,
			LastRunStage = 1,
			LastDeathClock = nil,
			TalentBoughtAfterDeath = false,
			ShopOpenedAt = nil,
			ShopBoughtAnything = false,
			LastKnownState = "lobby",
		}
		states[player] = state
	end

	return state
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
		warn("[AnalyticsManager] Rebuilding remote with unexpected type:", name, className)
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

local function safeNumber(value, fallback)
	local numberValue = tonumber(value)
	if numberValue ~= nil then
		return numberValue
	end
	return fallback or 0
end

local function safeInteger(value, fallback)
	return math.floor(safeNumber(value, fallback or 0))
end

local function countJsonArray(rawValue)
	if type(rawValue) ~= "string" or rawValue == "" then
		return 0
	end

	local success, decoded = pcall(function()
		return HttpService:JSONDecode(rawValue)
	end)
	if success and type(decoded) == "table" then
		local count = 0
		for _ in pairs(decoded) do
			count += 1
		end
		return count
	end

	return 0
end

local function copyFields(fields)
	local result = {}
	if type(fields) ~= "table" then
		return result
	end

	for key, value in pairs(fields) do
		result[key] = value
	end
	return result
end

local function addCommonContext(player, fields)
	local state = ensureState(player)
	fields.run_index = fields.run_index or state.RunIndex
	fields.death_count = fields.death_count or state.DeathCount
	fields.distance = fields.distance or safeInteger(player:GetAttribute("CurrentDistance"), state.RunMaxDistance)
	fields.stage = fields.stage or state.CurrentStage or 1
	fields.level = fields.level or safeInteger(player:GetAttribute("CurrentRunLevel"), 1)
	fields.coins = fields.coins or safeInteger(player:GetAttribute("Coins"), 0)
	return fields
end

local function normalizeValue(value)
	local valueType = typeof(value)
	if valueType == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return nil
		end
		return value
	elseif valueType == "string" then
		if #value > 240 then
			return string.sub(value, 1, 240)
		end
		return value
	elseif valueType == "boolean" then
		return value
	elseif valueType == "table" then
		local success, encoded = pcall(function()
			return HttpService:JSONEncode(value)
		end)
		if success then
			if #encoded > 240 then
				return string.sub(encoded, 1, 240)
			end
			return encoded
		end
	end

	return nil
end

local function sanitizeFields(fields)
	local sanitized = {}
	local count = 0
	local maxFields = getConfig().MaxCustomFields or 20

	for key, value in pairs(fields or {}) do
		if count >= maxFields then
			break
		end

		local safeKey = tostring(key)
		if safeKey ~= "" then
			local normalized = normalizeValue(value)
			if normalized ~= nil then
				sanitized[safeKey] = normalized
				count += 1
			end
		end
	end

	return sanitized
end

local function getUtcDateString()
	return os.date("!%Y-%m-%d")
end

local function parseDateToDays(dateString)
	if type(dateString) ~= "string" then
		return nil
	end

	local year, month, day = string.match(dateString, "^(%d+)%-(%d+)%-(%d+)$")
	year = tonumber(year)
	month = tonumber(month)
	day = tonumber(day)
	if not year or not month or not day then
		return nil
	end

	local timestamp = os.time({
		year = year,
		month = month,
		day = day,
		hour = 0,
		min = 0,
		sec = 0,
	})
	return math.floor(timestamp / 86400)
end

local function getLeaveState(player)
	local state = ensureState(player)
	if state.LastKnownState and state.LastKnownState ~= "" then
		return state.LastKnownState
	end
	if state.InRun or player:GetAttribute("RunInCombat") == true then
		return "combat"
	end
	return "lobby"
end

local function isClientEventAllowed(eventName)
	local config = getConfig()
	local whitelist = config.ClientEventWhitelist
	if type(whitelist) == "table" then
		return whitelist[eventName] == true
	end

	return DEFAULT_ALLOWED_CLIENT_EVENTS[eventName] == true
end

local function allowClientEvent(player, eventName)
	local config = getConfig()
	local windowSeconds = math.max(1, safeNumber(config.ClientThrottleWindow, 10))
	local defaultMax = math.max(1, safeInteger(config.ClientEventMaxPerWindow, 80))
	local highFrequencyMax = math.max(1, safeInteger(config.HighFrequencyEventMaxPerWindow, 50))
	local maxEvents = eventName == "enemy_killed" and highFrequencyMax or defaultMax

	local now = os.clock()
	local playerBuckets = clientThrottle[player]
	if not playerBuckets then
		playerBuckets = {}
		clientThrottle[player] = playerBuckets
	end

	local bucket = playerBuckets[eventName]
	if not bucket or (now - bucket.StartClock) > windowSeconds then
		bucket = {
			StartClock = now,
			Count = 0,
		}
		playerBuckets[eventName] = bucket
	end

	if bucket.Count >= maxEvents then
		return false
	end

	bucket.Count += 1
	return true
end

function AnalyticsManager.Track(player, eventName, fields, value)
	if not isEnabled() or not player or not player.Parent or type(eventName) ~= "string" or eventName == "" then
		return false
	end

	local customFields = sanitizeFields(fields or {})
	local eventValue = tonumber(value)
	if eventValue == nil then
		eventValue = tonumber((fields or {}).value) or 1
	end

	if getConfig().DebugPrint == true then
		local encodedFields = "{}"
		pcall(function()
			encodedFields = HttpService:JSONEncode(customFields)
		end)
		print("[Analytics]", player.Name, eventName, eventValue, encodedFields)
	end

	local success, err = pcall(function()
		AnalyticsService:LogCustomEvent(player, eventName, eventValue, customFields)
	end)
	if not success then
		warn("[AnalyticsManager] LogCustomEvent failed:", eventName, err)
		return false
	end

	return true
end

function AnalyticsManager.HandlePlayerDataLoaded(player, loadSuccess, isNewPlayer, previousLastLoginDate)
	local fields = {
		load_success = loadSuccess == true,
		is_new_player = isNewPlayer == true,
		coins = safeInteger(player:GetAttribute("Coins"), 0),
		best_distance = safeInteger(player:GetAttribute("BestDistance"), 0),
		best_level = safeInteger(player:GetAttribute("BestLevel"), 1),
		owned_pet_count = countJsonArray(player:GetAttribute("OwnedPets_JSON")),
	}
	AnalyticsManager.Track(player, "player_data_loaded", fields)

	local today = getUtcDateString()
	if type(previousLastLoginDate) == "string" and previousLastLoginDate ~= "" and previousLastLoginDate ~= today then
		local previousDays = parseDateToDays(previousLastLoginDate)
		local currentDays = parseDateToDays(today)
		AnalyticsManager.Track(player, "return_next_day", {
			last_login_date = previousLastLoginDate,
			current_login_date = today,
			days_since_last_login = (previousDays and currentDays) and math.max(1, currentDays - previousDays) or 1,
			previous_best_distance = safeInteger(player:GetAttribute("BestDistance"), 0),
			previous_best_level = safeInteger(player:GetAttribute("BestLevel"), 1),
		})
	end
end

function AnalyticsManager.HandleRunStarted(player)
	local state = ensureState(player)
	local now = os.clock()
	state.RunIndex += 1
	state.HasStartedRun = true
	state.InRun = true
	state.RunStartClock = now
	state.RunStartBestDistance = safeInteger(player:GetAttribute("BestDistance"), 0)
	state.RunStartCoins = safeInteger(player:GetAttribute("Coins"), 0)
	state.CurrentStage = 1
	state.RunMaxStage = 1
	state.RunMaxDistance = 0
	state.RunMaxLevel = safeInteger(player:GetAttribute("CurrentRunLevel"), 1)
	state.DistanceMilestonesHit = {}
	state.SeenStages = {}
	state.ShopOpenedAt = nil
	state.ShopBoughtAnything = false
	state.LastKnownState = "combat"
	player:SetAttribute("AnalyticsRunIndex", state.RunIndex)
	player:SetAttribute("AnalyticsDeathCount", state.DeathCount)

	local baseFields = {
		run_index = state.RunIndex,
		time_since_join = math.floor(now - state.JoinClock),
		coins = safeInteger(player:GetAttribute("Coins"), 0),
		best_distance = state.RunStartBestDistance,
		equipped_pet = tostring(player:GetAttribute("EquippedPet") or ""),
		equipped_weapon = tostring(player:GetAttribute("EquippedWeapon") or "DefaultWeapon"),
	}

	if state.RunIndex == 1 then
		AnalyticsManager.Track(player, "first_run_entered", baseFields)
	end

	AnalyticsManager.Track(player, "run_start", {
		run_index = state.RunIndex,
		coins = baseFields.coins,
		best_distance = baseFields.best_distance,
		best_level = safeInteger(player:GetAttribute("BestLevel"), 1),
	})

	if state.RunIndex == 2 then
		AnalyticsManager.Track(player, "second_run_start", {
			run_index = state.RunIndex,
			time_after_first_death = state.LastDeathClock and math.floor(now - state.LastDeathClock) or 0,
			last_run_distance = state.LastRunDistance or 0,
			last_run_stage = state.LastRunStage or 1,
			talent_bought_after_death = state.TalentBoughtAfterDeath == true,
		})
	end

	state.TalentBoughtAfterDeath = false
end

function AnalyticsManager.HandleDistanceUpdated(player, distance)
	local state = ensureState(player)
	if not state.InRun then
		return
	end

	local safeDistance = math.max(0, safeInteger(distance, 0))
	state.RunMaxDistance = math.max(state.RunMaxDistance or 0, safeDistance)
	state.RunMaxLevel = math.max(state.RunMaxLevel or 1, safeInteger(player:GetAttribute("CurrentRunLevel"), 1))

	for _, milestone in ipairs(getConfig().DistanceMilestones or { 50, 100, 200, 500 }) do
		local milestoneDistance = safeInteger(milestone, 0)
		if milestoneDistance > 0 and safeDistance >= milestoneDistance and not state.DistanceMilestonesHit[milestoneDistance] then
			state.DistanceMilestonesHit[milestoneDistance] = true
			AnalyticsManager.Track(player, "distance_milestone_reached", addCommonContext(player, {
				milestone_distance = milestoneDistance,
				current_distance = safeDistance,
			}), milestoneDistance)
		end
	end
end

function AnalyticsManager.HandleRunEnded(player, endReason)
	local state = ensureState(player)
	if not state.InRun and endReason ~= "leave" then
		return
	end

	local distance = safeInteger(player:GetAttribute("CurrentDistance"), state.RunMaxDistance or 0)
	state.RunMaxDistance = math.max(state.RunMaxDistance or 0, distance)
	state.RunMaxLevel = math.max(state.RunMaxLevel or 1, safeInteger(player:GetAttribute("CurrentRunLevel"), 1))
	local stage = state.RunMaxStage or state.CurrentStage or 1
	local level = state.RunMaxLevel or safeInteger(player:GetAttribute("CurrentRunLevel"), 1)
	local duration = state.RunStartClock and math.floor(os.clock() - state.RunStartClock) or 0
	local bestBefore = state.RunStartBestDistance or 0
	local bestAfter = safeInteger(player:GetAttribute("BestDistance"), bestBefore)

	if state.RunIndex == 1 and not state.FirstRunStageReported then
		state.FirstRunStageReported = true
		AnalyticsManager.Track(player, "first_run_reached_stage", {
			stage = stage,
			distance = state.RunMaxDistance,
			level = level,
			run_index = state.RunIndex,
		}, stage)
	end

	if endReason == "death" then
		state.DeathCount += 1
		state.LastDeathClock = os.clock()
		player:SetAttribute("AnalyticsDeathCount", state.DeathCount)
		AnalyticsManager.Track(player, "player_died_stage", {
			stage = stage,
			distance = distance,
			level = level,
			coins = safeInteger(player:GetAttribute("Coins"), 0),
			run_index = state.RunIndex,
			current_hp = safeInteger(player:GetAttribute("HP"), 0),
			max_hp = safeInteger(player:GetAttribute("MaxHP"), 0),
			best_distance_before = bestBefore,
			death_count = state.DeathCount,
		}, stage)
	end

	AnalyticsManager.Track(player, "run_end", {
		end_reason = endReason or "unknown",
		stage = stage,
		distance = distance,
		level = level,
		coins = safeInteger(player:GetAttribute("Coins"), 0),
		run_index = state.RunIndex,
		duration = duration,
		best_distance_before = bestBefore,
		best_distance_after = bestAfter,
		best_level_after = safeInteger(player:GetAttribute("BestLevel"), 1),
	})

	if endReason == "death" then
		AnalyticsManager.Track(player, "death_count_after_run", {
			death_count = state.DeathCount,
			run_index = state.RunIndex,
			stage = stage,
			distance = distance,
		}, state.DeathCount)
	end

	state.InRun = false
	state.LastRunDistance = distance
	state.LastRunStage = stage
	state.LastKnownState = "lobby"
end

function AnalyticsManager.MarkShopBought(player)
	local state = ensureState(player)
	state.ShopBoughtAnything = true
	if state.DeathCount > 0 and not state.InRun then
		state.TalentBoughtAfterDeath = true
	end
end

function AnalyticsManager.GetTimeSinceJoin(player)
	local state = ensureState(player)
	return math.floor(os.clock() - state.JoinClock)
end

function AnalyticsManager.HandleClientEvent(player, eventName, fields)
	if type(eventName) ~= "string" or not isClientEventAllowed(eventName) then
		return
	end
	if not allowClientEvent(player, eventName) then
		return
	end

	local state = ensureState(player)
	local eventFields = addCommonContext(player, copyFields(fields))

	if eventName == "stage_reached" then
		local stage = safeInteger(eventFields.stage, state.CurrentStage or 1)
		eventFields.stage = stage
		eventFields.is_first_time_stage = state.SeenStages[stage] ~= true
		state.SeenStages[stage] = true
		state.CurrentStage = stage
		state.RunMaxStage = math.max(state.RunMaxStage or 1, stage)
		state.RunMaxDistance = math.max(state.RunMaxDistance or 0, safeInteger(eventFields.distance, 0))
	elseif eventName == "shop_open" then
		state.ShopOpenedAt = os.clock()
		state.ShopBoughtAnything = false
		state.LastKnownState = "shop"
	elseif eventName == "shop_close" then
		eventFields.duration_in_shop = state.ShopOpenedAt and math.floor(os.clock() - state.ShopOpenedAt) or safeInteger(eventFields.duration_in_shop, 0)
		eventFields.bought_anything = state.ShopBoughtAnything == true
		state.ShopOpenedAt = nil
		state.LastKnownState = state.InRun and "combat" or "lobby"
	elseif eventName == "pet_hatch_open" then
		state.LastKnownState = "pet_hatch"
	elseif eventName == "level_up_cards_shown" then
		state.LastKnownState = "level_up"
	elseif eventName == "level_up_card_selected" then
		state.LastKnownState = state.InRun and "combat" or "lobby"
	end

	AnalyticsManager.Track(player, eventName, eventFields, eventFields.value)
end

local function handlePlayerAdded(player)
	local state = ensureState(player)
	if state.JoinTracked then
		return
	end
	state.JoinTracked = true
	AnalyticsManager.Track(player, "player_join", {
		is_new_session = true,
	})
end

local function handlePlayerRemoving(player)
	local state = ensureState(player)
	if state.InRun then
		AnalyticsManager.HandleRunEnded(player, "leave")
	end

	local sessionDuration = math.floor(os.clock() - state.JoinClock)
	local leaveFields = {
		leave_state = getLeaveState(player),
		session_duration = sessionDuration,
		run_count = state.RunIndex,
		has_started_run = state.HasStartedRun == true,
		last_run_distance = state.LastRunDistance or state.RunMaxDistance or 0,
		last_run_stage = state.LastRunStage or state.RunMaxStage or 1,
		best_distance = safeInteger(player:GetAttribute("BestDistance"), 0),
		best_level = safeInteger(player:GetAttribute("BestLevel"), 1),
		coins = safeInteger(player:GetAttribute("Coins"), 0),
		death_count = state.DeathCount,
		owned_pet_count = countJsonArray(player:GetAttribute("OwnedPets_JSON")),
	}

	AnalyticsManager.Track(player, "player_leave", leaveFields)
	AnalyticsManager.Track(player, "session_duration", {
		duration_seconds = sessionDuration,
		leave_state = leaveFields.leave_state,
		run_count = state.RunIndex,
		best_distance = leaveFields.best_distance,
		death_count = state.DeathCount,
	}, sessionDuration)

	states[player] = nil
	clientThrottle[player] = nil
end

function AnalyticsManager.Init(deps)
	Services = deps
end

function AnalyticsManager.Start()
	local reportRemote = getOrCreateRemote("ReportAnalyticsEvent", "RemoteEvent")
	reportRemote.OnServerEvent:Connect(function(player, eventName, fields)
		AnalyticsManager.HandleClientEvent(player, eventName, fields)
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		handlePlayerAdded(player)
	end
	Players.PlayerAdded:Connect(handlePlayerAdded)
	Players.PlayerRemoving:Connect(handlePlayerRemoving)
end

return AnalyticsManager
