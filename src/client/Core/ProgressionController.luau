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
	
	-- 获取当前升到下一级需要的经验，如果没有则使用默认公式
	local requiredExp = player:GetAttribute("RequiredEXP") or (currentLevel * 10)
	local didLevelUp = false
	
	-- 连续升级判定：解决一次性吃极大经验球（溢出）吞等级的问题
	while currentExp >= requiredExp do
		currentExp = currentExp - requiredExp
		currentLevel = currentLevel + 1
		requiredExp = currentLevel * 10
		didLevelUp = true
	end
	
	-- 将结算后的最新数值写入 Player 属性
	-- （注：因为你之前写的 UIController 是通过监听 AttributeChanged 来刷新的，
	-- 所以只要这里一改数值，屏幕上的经验条就会瞬间自动平滑更新，完全不需要互相耦合！）
	player:SetAttribute("Level", currentLevel)
	player:SetAttribute("EXP", currentExp)
	player:SetAttribute("RequiredEXP", requiredExp)
	
	if didLevelUp then
		player:SetAttribute("IsLevelingUp", true)
		-- 呼叫输入控制器：强制剥夺移动方向并刹车
		Controllers.Player.SetMoveDirection(0) 
		print("玩家升级！当前等级: " .. tostring(currentLevel))
	end
end


-- =========================================================
-- 局外养成扩展接口 (Meta-Progression)
-- =========================================================

-- 这个函数是为了你后续的“局外养成”准备的
function ProgressionController.CalculateStartingStats()
	local Config = Controllers.Config
	
	-- 假设未来你从服务器拿到了玩家的天赋加点存档：
	-- local playerTalents = self:GetTalentDataFromServer()
	-- local extraAtk = playerTalents.AttackLevel * 2
	-- local extraHp = playerTalents.HealthLevel * 20
	
	local extraAtk = 0
	local extraHp = 0
	
	-- 将 Config 中的“白板基础值” 加上 “局外养成增益”，返回最终的开局面板
	return {
		MaxHP = Config.BASE_HP + extraHp,
		ATK = Config.BASE_ATK + extraAtk,
		ASPD = Config.BASE_ASPD, 
		-- ...等等
	}
end
-- 未来你只需要去 GameController.ResetPlayerStats() 里面，
-- 把读取 Config.BASE_ATK 的地方，改成调用这个 CalculateStartingStats() 即可完美融合！

return ProgressionController