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
	-- 经验倍率卡按百分比提高本次获得的经验，最终加到局内经验池。
	local expGainBonus = player:GetAttribute("EXP_Gain_Bonus") or 0
	local actualGainedExp = math.floor(gainedExp * (1 + (expGainBonus / 100)))
	local currentExp = (player:GetAttribute("EXP") or Config.BASE_EXP) + actualGainedExp
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

	return actualGainedExp
end


-- =========================================================
-- 局外养成扩展接口 (Meta-Progression)
-- =========================================================

function ProgressionController.CalculateStartingStats()
	local Config = Controllers.Config
	
	-- 从 Config 读取每级的成长加成系数
	local extraHp = (player:GetAttribute("Talent_HP") or 0) * Config.TALENTS.Talent_HP.StatIncrease
	-- 【修改】：局外的天赋也转化为加成百分比 (例如每级天赋加 5% 攻击)
	local atkBonus = (player:GetAttribute("Talent_ATK") or 0) * Config.TALENTS.Talent_ATK.StatIncrease 
	local aspdBonus = (player:GetAttribute("Talent_ASPD") or 0) * Config.TALENTS.Talent_ASPD.StatIncrease
	
	-- 基础值 + 局外天赋加成 = 本局开局最终属性
	return {
		MaxHP = Config.BASE_HP + extraHp,
		ATK_Bonus = atkBonus,
		ASPD_Bonus = aspdBonus, 
	}
end

return ProgressionController
