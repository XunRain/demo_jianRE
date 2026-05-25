-- src/client/Core/ProgressionController.luau
-- 数值与养成控制器：负责局内经验获取、连续升级判定，以及未来局外养成的数据管理
local ProgressionController = {}

local Players = game:GetService("Players")
local player = Players.LocalPlayer

local Controllers -- 全局依赖指针

function ProgressionController.Init(deps)
	Controllers = deps
end

function ProgressionController.Start()
	-- 目前不需要启动循环，但未来可以在这里向服务器请求玩家的【局外养成存档】
end

-- 局内经验增加核心逻辑 (由 EncounterController 吃经验球时调用)
function ProgressionController.AddExp(gainedExp)
	local Config = Controllers.Config
	local currentExp = (player:GetAttribute("EXP") or Config.BASE_EXP) + gainedExp
	local currentLevel = player:GetAttribute("Level") or Config.BASE_LEVEL
	
	-- 【修改 1】：从配置表读取经验公式
	local requiredExp = player:GetAttribute("RequiredEXP") or (currentLevel * Config.EXP_PER_LEVEL)
	local didLevelUp = false
	
	-- 连续升级判定
	while currentExp >= requiredExp do
		currentExp = currentExp - requiredExp
		currentLevel = currentLevel + 1
		-- 【修改 2】：下一级所需经验同样读取配置表
		requiredExp = currentLevel * Config.EXP_PER_LEVEL
		didLevelUp = true
	end
	
	player:SetAttribute("Level", currentLevel)
	player:SetAttribute("EXP", currentExp)
	player:SetAttribute("RequiredEXP", requiredExp)
	
	if didLevelUp then
		player:SetAttribute("IsLevelingUp", true)
		Controllers.Player.SetMoveDirection(0) 
		print("玩家升级！当前等级: " .. tostring(currentLevel))
	end
end


-- =========================================================
-- 局外养成扩展接口 (Meta-Progression)
-- =========================================================

function ProgressionController.CalculateStartingStats()
	local Config = Controllers.Config
	
	-- 读取玩家的局外养成等级
	local lvlHP = player:GetAttribute("Talent_HP") or 0
	local lvlATK = player:GetAttribute("Talent_ATK") or 0
	local lvlASPD = player:GetAttribute("Talent_ASPD") or 0
	
	-- 转换为实际面板（比如升一级HP加20点，ATK加5点，ASPD加0.15）
	local extraHp = lvlHP * 20
	local extraAtk = lvlATK * 5
	local extraAspd = lvlASPD * 0.15
	
	return {
		MaxHP = Config.BASE_HP + extraHp,
		ATK = Config.BASE_ATK + extraAtk,
		ASPD = Config.BASE_ASPD + extraAspd, 
	}
end

return ProgressionController