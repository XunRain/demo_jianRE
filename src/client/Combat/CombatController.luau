-- src/client/Combat/CombatController.luau
-- 核心战斗控制器：负责射击循环与碰撞结算(打怪、吃门、肉身撞击)
local CombatController = {}

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer

-- 精准定位到特效文件路径
local vfxFolder = ReplicatedStorage:WaitForChild("VFX", 10)
local sourceVFX = vfxFolder and vfxFolder:WaitForChild("CollisionDoorVFX", 5)

local Controllers -- 全局依赖指针

CombatController.ActiveBullets = {}

function CombatController.Init(deps)
	Controllers = deps
end

function CombatController.Start()
	-- 维持自动射击节奏
	task.spawn(function()
		while true do
			-- 只有在战斗中并且没被暂停时才开枪
			if Controllers.Game.IsCombatActive and not player:GetAttribute("IsLevelingUp") then
				local aspd = player:GetAttribute("ASPD") or Controllers.Config.BASE_ASPD
				if aspd <= 0.1 then aspd = 0.1 end -- 兜底机制，防止负数攻速引发死循环报错
				CombatController.ShootProjectile()
				task.wait(1 / aspd)
			else
				task.wait(0.1) 
			end
		end
	end)
end

-- 生成并弹射子弹模型
function CombatController.ShootProjectile()
	local character = player.Character
	if not character or not character.PrimaryPart then return end
	
	local humanoid = character:FindFirstChild("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return end
	
	local rootPart = character.PrimaryPart
	local bullet = Instance.new("Part")
	bullet.Size = Vector3.new(1, 1, 2)
	bullet.Color = Color3.fromRGB(0, 255, 255)
	bullet.Material = Enum.Material.Neon
	bullet.CanCollide = false
	bullet.CFrame = rootPart.CFrame * CFrame.new(0, 0, -2) -- 生成在胸前
	
	local bv = Instance.new("LinearVelocity")
	local attachment = Instance.new("Attachment", bullet)
	bv.Attachment0 = attachment
	
	bv.VectorVelocity = Vector3.new(0, 0, -Controllers.Config.BULLET_SPEED) 
	bv.MaxForce = math.huge
	bv.Parent = bullet
	
	local localProjectiles = Workspace:FindFirstChild("LocalProjectiles") or Instance.new("Folder", Workspace)
	localProjectiles.Name = "LocalProjectiles"
	bullet.Parent = localProjectiles

	game.Debris:AddItem(bullet, Controllers.Config.BULLET_LIFETIME) 
	-- 【修改】：记录子弹实体时，顺便带上玩家当前的攻击力！
	local playerAtk = player:GetAttribute("ATK") or Controllers.Config.BASE_ATK
	table.insert(CombatController.ActiveBullets, { part = bullet, damage = playerAtk })
end

function CombatController.ClearBullets()
	for _, bullet in ipairs(CombatController.ActiveBullets) do if bullet.part then bullet.part:Destroy() end end
	CombatController.ActiveBullets = {}
end

-- 结算核心：碰撞检测 (由 PlayerController 驱动调用)
function CombatController.CheckCollisions(rootPart)
	local pPos = rootPart.Position
	local playerAtk = player:GetAttribute("ATK") or Controllers.Config.BASE_ATK
	
	local activeEnemies = Controllers.Encounter.ActiveEnemies
	local activeGateGroups = Controllers.Encounter.ActiveGateGroups

	-- 1. 子弹打怪结算
	for i = #CombatController.ActiveBullets, 1, -1 do
		local b = CombatController.ActiveBullets[i]
		if not b.part or not b.part.Parent then 
			table.remove(CombatController.ActiveBullets, i) 
			continue 
		end
		
		local bPos = b.part.Position
		for j = #activeEnemies, 1, -1 do
			local e = activeEnemies[j]
			if not e.part or not e.part.Parent then continue end
			
			local ePos = e.part.Position
			local eSize = e.part.Size
			
			-- X轴与Z轴的范围判定
			if math.abs(bPos.X - ePos.X) < (eSize.X/2 + 1) and 
			   math.abs(bPos.Z - ePos.Z) < (eSize.Z/2 + 2) then 
				
				-- 扣除的血量等于这颗子弹自身携带的伤害值，如果是 nil 兜底为玩家伤害
				local dmg = b.damage or (player:GetAttribute("ATK") or Controllers.Config.BASE_ATK)
				e.hp = e.hp - dmg
				e.label.Text = tostring(e.hp)
				
				b.part:Destroy()
				table.remove(CombatController.ActiveBullets, i)
				
				-- 怪物血条清空
				if e.hp <= 0 then
					e.part:Destroy()
					table.remove(activeEnemies, j)
					-- 呼叫 EncounterController 爆出战利品满地散落
					Controllers.Encounter.TriggerDrops(e.type, ePos)
				end
				break -- 一颗子弹只打一个怪
			end
		end
	end
	
	-- 2. 玩家吃增益门结算
	for i = #activeGateGroups, 1, -1 do
		local group = activeGateGroups[i]
		if pPos.Z <= group.z + 1 then
			-- 判断玩家中心点在左侧还是右侧 (通过 MapController 拿到跑道中心 X 坐标)
			local chosenGate = (pPos.X < Controllers.Map.TrackStartX) and group.left or group.right
			
			-- ─── 【终极焊接版：触发吃门特效反馈】 ───
			if sourceVFX and rootPart then
				Controllers.VFX.PlayGateVFX(rootPart)
			end

			-- 门的 HP 属性现在只影响“当前血量”，不再修改“生命上限”
			if chosenGate.attr == "HP" then
				local currentMax = player:GetAttribute("MaxHP") or Controllers.Config.BASE_HP
				local currentHp = player:GetAttribute("HP") or Controllers.Config.BASE_HP
				
				-- 门加血或扣血，最高不能超过当前的 MaxHP，最低为 1（避免吃扣血门直接暴毙）
				local newHp = math.clamp(currentHp + chosenGate.amount, 1, currentMax)
				player:SetAttribute("HP", newHp)
				
				-- 同步给原生的 Humanoid 人偶模型，确保底层逻辑一致
				local humanoid = player.Character and player.Character:FindFirstChild("Humanoid")
				if humanoid then
					humanoid.Health = newHp
				end
			else
				local currentVal = player:GetAttribute(chosenGate.attr) or 0
				player:SetAttribute(chosenGate.attr, currentVal + chosenGate.amount)
			end
			-- =======================================================
			
			-- 门碎裂销毁
			if group.left.part then group.left.part:Destroy() end
			if group.right.part then group.right.part:Destroy() end
			table.remove(activeGateGroups, i)
		end
	end
	
	-- 3. 肉身换血机制 (玩家没打死怪，硬撞上了)
	for i = #activeEnemies, 1, -1 do
		local e = activeEnemies[i]
		if not e.part then continue end
		
		local ePos = e.part.Position
		local eSize = e.part.Size
		
		if math.abs(pPos.X - ePos.X) < (eSize.X/2 + 1) and 
		   math.abs(pPos.Z - ePos.Z) < (eSize.Z/2 + 1) then
			
			-- 怪物还剩多少血，玩家就扣多少血
			local damage = e.hp 
			local currentHp = player:GetAttribute("HP") or Controllers.Config.BASE_HP 
			local newHp = currentHp - damage
			player:SetAttribute("HP", newHp)
			
			e.part:Destroy()
			table.remove(activeEnemies, i)
			
			-- 同步到原生的 Humanoid 进行真实死亡判定
			local humanoid = player.Character:FindFirstChild("Humanoid")
			if humanoid then
				humanoid.MaxHealth = player:GetAttribute("MaxHP") or Controllers.Config.BASE_HP
				humanoid.Health = newHp
			end
			
			-- 用肉身撞死也掉战利品
			Controllers.Encounter.TriggerDrops(e.type, ePos)
		end
	end
end

return CombatController