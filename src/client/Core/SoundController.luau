-- src/client/Core/SoundController.luau
-- 客户端音效控制器：统一管理 SoundService 中由 Studio 配置好的音乐与音效。
local SoundController = {}

local SoundService = game:GetService("SoundService")

local SOUND_NAMES = {
	Background = "Background Sound",
	Battle = "Battle background music",
	Select = "Select Sound",
	Upgrade = "Upgrade Sound",
}

local warnedMissingSounds = {}
local currentMusicKey = nil

local function getSound(soundKey)
	local soundName = SOUND_NAMES[soundKey]
	if not soundName then return nil end

	local sound = SoundService:FindFirstChild(soundName)
	if sound and sound:IsA("Sound") then
		return sound
	end

	if not warnedMissingSounds[soundKey] then
		warn("[SoundController] SoundService is missing sound:", soundName)
		warnedMissingSounds[soundKey] = true
	end

	return nil
end

local function safeStop(sound)
	if not sound then return end
	pcall(function()
		sound:Stop()
	end)
end

local function safePlay(sound, restart)
	if not sound then return end
	pcall(function()
		if restart then
			sound.TimePosition = 0
		end
		if restart or not sound.IsPlaying then
			sound:Play()
		end
	end)
end

local function playMusic(musicKey)
	if currentMusicKey == musicKey then
		local currentSound = getSound(musicKey)
		safePlay(currentSound, false)
		return
	end

	for _, key in ipairs({ "Background", "Battle" }) do
		if key ~= musicKey then
			safeStop(getSound(key))
		end
	end

	currentMusicKey = musicKey
	local sound = getSound(musicKey)
	if sound then
		sound.Looped = true
		safePlay(sound, false)
	end
end

function SoundController.Init(_deps)
	-- 保留统一 Controller 生命周期接口。
end

function SoundController.Start()
	SoundController.PlayBackground()
end

function SoundController.PlayBackground()
	playMusic("Background")
end

function SoundController.PlayBattle()
	playMusic("Battle")
end

function SoundController.PlaySelect()
	safePlay(getSound("Select"), true)
end

function SoundController.PlayUpgrade()
	safePlay(getSound("Upgrade"), true)
end

return SoundController
