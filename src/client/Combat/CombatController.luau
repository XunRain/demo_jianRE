-- src/client/Combat/CombatController.luau
-- 战斗控制模块：负责玩家主武器发射、子弹管理、碰撞检测与御剑循环。
local CombatController = {}

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

local vfxFolder = ReplicatedStorage:WaitForChild("VFX", 10)
local sourceVFX = vfxFolder and vfxFolder:WaitForChild("CollisionDoorVFX", 5)

local Controllers

CombatController.ActiveBullets = {}

function CombatController.Init(deps)
	Controllers = deps
end

-- 启动战斗循环：根据当前武器和攻速持续发射主武器子弹。
function CombatController.Start()
	task.spawn(function()
		while true do
			if Controllers.Game.IsCombatActive and not player:GetAttribute("IsLevelingUp") then

				local equippedWeapon = player:GetAttribute("EquippedWeapon") or "DefaultWeapon"
				local weaponConfig = Controllers.Config.WEAPONS[equippedWeapon] or Controllers.Config.WEAPONS["DefaultWeapon"]

				local baseAspd = Controllers.Config.BASE_ASPD
				local aspdBonus = player:GetAttribute("ASPD_Bonus") or 0
				local theoreticalAspd = baseAspd * (1 + (aspdBonus / 100))

				local finalAspd = math.min(theoreticalAspd, weaponConfig.MaxASPD or 20)

				local actualInterval = 1 / finalAspd

				CombatController.ShootProjectile()
				task.wait(actualInterval)
			else
				task.wait(0.1)
			end
		end
	end)
	CombatController.StartSwordSystem()
end

-- 发射主武器子弹，并按当前弹道模式生成单发/多发投射物。
function CombatController.ShootProjectile()
	local character = player.Character
	if not character or not character.PrimaryPart then return end

	local humanoid = character:FindFirstChild("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return end
	local rootPart = character.PrimaryPart

	local equippedWeapon = player:GetAttribute("EquippedWeapon") or "DefaultWeapon"
	local weaponConfig = Controllers.Config.WEAPONS[equippedWeapon] or Controllers.Config.WEAPONS["DefaultWeapon"]

	local vfxFolder = game:GetService("ReplicatedStorage"):FindFirstChild("VFX")
	local weaponsFolder = vfxFolder and vfxFolder:FindFirstChild("Weapons")
	local bulletPrefab = weaponsFolder and weaponsFolder:FindFirstChild(weaponConfig.BulletVFX)

	local spawnCenter = rootPart.Position + Vector3.new(0, 0, -2)

	local baseSpd = Controllers.Config.BASE_SPD
	local spdBonus = player:GetAttribute("SPD_Bonus") or 0
	local currentSpd = baseSpd * (1 + (spdBonus / 100))

	local baseRng = Controllers.Config.BASE_RNG
	local rngBonus = player:GetAttribute("RNG_Bonus") or 0
	local theoreticalRng = baseRng * (1 + (rngBonus / 100))

	local finalRng = math.min(theoreticalRng, weaponConfig.MaxRNG or 500)

	local actualLifetime = finalRng / currentSpd

	local baseAtk = Controllers.Config.BASE_ATK
	local atkBonus = player:GetAttribute("ATK_Bonus") or 0
	local critMultiplier = 1
	local finalDmg = math.floor(baseAtk * (1 + (atkBonus / 100)) * critMultiplier)

	local multiShot = player:GetAttribute("MultiShot") or 1

	local firePattern = weaponConfig.FirePattern or "Parallel"

	local localProjectiles = Workspace:FindFirstChild("LocalProjectiles") or Instance.new("Folder", Workspace)
	localProjectiles.Name = "LocalProjectiles"

		-- 计算多重弹道在左右两侧的分布位置。
	local function getMultiShotLaneOffset(projectileIndex, spacing)
		if projectileIndex <= 1 then return 0 end

		local extraIndex = projectileIndex - 1
		local side = (extraIndex % 2 == 1) and 1 or -1
		local laneStep = math.ceil(extraIndex / 2)
		return side * laneStep * spacing
	end

		-- 额外弹道伤害低于主弹道，保持数值可控。
	local function getMultiShotDamage(projectileIndex, baseDamage)
		if projectileIndex <= 1 then
			return baseDamage
		end

		local extraDamageRatio = Controllers.Config.MULTISHOT_EXTRA_DAMAGE_RATIO or 0.7
		return math.max(1, math.floor(baseDamage * extraDamageRatio))
	end

	for i = 1, multiShot do
		local dirX, dirZ = 0, -1
		local angleRad = 0
		local spawnOffset = Vector3.new(0, 0, 0)

		local spacing = Controllers.Config.MULTISHOT_SPREAD_DISTANCE or 3.5
		local laneOffsetX = getMultiShotLaneOffset(i, spacing)
		local laneIndex = spacing > 0 and (laneOffsetX / spacing) or 0

		if firePattern == "Spread" then
			local spreadAngle = 15
			angleRad = math.rad(laneIndex * spreadAngle)
			dirX = math.sin(angleRad)
			dirZ = -math.cos(angleRad)

		elseif firePattern == "Parallel" or firePattern == "Pierce" then
			spawnOffset = Vector3.new(laneOffsetX, 0, 0)
		end

		local finalSpawnPos = spawnCenter + spawnOffset

		local bullet
		if bulletPrefab then
			bullet = bulletPrefab:Clone()
			if bullet:IsA("Model") then
				bullet:PivotTo(CFrame.new(finalSpawnPos) * CFrame.Angles(0, -angleRad, 0) * bulletPrefab:GetPivot().Rotation)
			else
				bullet.CFrame = CFrame.new(finalSpawnPos) * CFrame.Angles(0, -angleRad, 0) * bulletPrefab.CFrame.Rotation
			end
		else
			bullet = Instance.new("Part")
			bullet.Size = Vector3.new(1, 1, 2)
			bullet.Color = Color3.fromRGB(0, 255, 255)
			bullet.Material = Enum.Material.Neon
			bullet.CFrame = CFrame.new(finalSpawnPos) * CFrame.Angles(0, -angleRad, 0)
		end

		local targetPart = bullet:IsA("Model") and bullet.PrimaryPart or bullet
		if bullet:IsA("Model") and not targetPart then
			targetPart = bullet:FindFirstChildWhichIsA("BasePart", true)
			bullet.PrimaryPart = targetPart
		end

		if targetPart and targetPart:IsA("BasePart") then
			local partsToProcess = bullet:IsA("Model") and bullet:GetDescendants() or {}
			table.insert(partsToProcess, bullet)
			for _, obj in ipairs(partsToProcess) do
				if obj:IsA("BasePart") then obj.CanCollide = false; obj.Anchored = false end
			end

			local bv = Instance.new("LinearVelocity")
			bv.Attachment0 = Instance.new("Attachment", targetPart)
			bv.RelativeTo = Enum.ActuatorRelativeTo.World
			bv.VectorVelocity = Vector3.new(dirX * currentSpd, 0, dirZ * currentSpd)
			bv.MaxForce = math.huge
			bv.Parent = targetPart
		end

		bullet.Parent = localProjectiles
		game.Debris:AddItem(bullet, actualLifetime)

		local maxHits = (firePattern == "Pierce") and 3 or 1
		table.insert(CombatController.ActiveBullets, {
			part = bullet,
			damage = getMultiShotDamage(i, finalDmg),
			weaponId = equippedWeapon,
			hitsLeft = maxHits,
			hitTargets = {}
		})
	end
end

-- 清空当前记录的子弹，并销毁对应实例。
function CombatController.ClearBullets()
	for _, bullet in ipairs(CombatController.ActiveBullets) do if bullet.part then bullet.part:Destroy() end end
	CombatController.ActiveBullets = {}
end

-- 播放怪物受击反馈；有美术模型时抖动模型，没有模型时抖动白模碰撞盒。
local function playEnemyHitJitter(enemy)
    if not enemy then return end
    Controllers.VFX.PlayHitJitterVFX(enemy.visual or enemy.part, enemy.baseSize)
end

-- 更新怪物血量数字显示；所有怪物常驻显示，优先使用模型内 HP/SurfaceGui。
local function updateEnemyHpLabel(enemy)
	if not enemy or not enemy.label then return end

	enemy.label.Text = Controllers.Config.FormatNumber(math.max(0, enemy.hp or 0))

	local billboard = enemy.hpBillboard or enemy.label.Parent
	local surfaceGui = enemy.hpSurfaceGui

	if surfaceGui then
		surfaceGui.Enabled = true
	elseif billboard and billboard:IsA("BillboardGui") then
		billboard.Enabled = true
	end
end

-- Boss 被玩家击败后，复用升级面板发放全金色奖励卡。
local function triggerBossGoldReward(enemyType)
	if enemyType ~= "Boss" then return end
	local bossGoldReward = Controllers.Config.BOSS_GOLD_REWARD
	if bossGoldReward and bossGoldReward.Enabled == false then return end

	player:SetAttribute("LevelUpRewardMode", "BossGold")
	player:SetAttribute("IsLevelingUp", true)
	Controllers.Player.SetMoveDirection(0)
end

-- 精英怪被玩家击败后，复用升级面板发放“至少 1 张金色卡”的奖励。
local function triggerEliteGoldReward(enemyType)
	if enemyType ~= "Elite" then return end
	local eliteGoldReward = Controllers.Config.ELITE_GOLD_REWARD
	if eliteGoldReward and eliteGoldReward.Enabled == false then return end
	-- 如果当前已经在发奖励，避免同一帧多个精英怪连续覆盖；BossGold 仍由 Boss 逻辑优先覆盖。
	if player:GetAttribute("IsLevelingUp") then return end

	player:SetAttribute("LevelUpRewardMode", "EliteGoldGuarantee")
	player:SetAttribute("IsLevelingUp", true)
	Controllers.Player.SetMoveDirection(0)
end

-- 检查玩家子弹、门、怪物与玩家之间的碰撞，并处理伤害、掉落与结算逻辑。
function CombatController.CheckCollisions(rootPart)
	local pPos = rootPart.Position
	local playerAtk = player:GetAttribute("ATK") or Controllers.Config.BASE_ATK

	local activeEnemies = Controllers.Encounter.ActiveEnemies
	local activeGateGroups = Controllers.Encounter.ActiveGateGroups

	for i = #CombatController.ActiveBullets, 1, -1 do
		local b = CombatController.ActiveBullets[i]
		if not b.part or not b.part.Parent then
			table.remove(CombatController.ActiveBullets, i)
			continue
		end

		local bPos = b.part.Position

		local hitBoxX = b.part.Size.X / 2 + 1
		local hitBoxZ = b.part.Size.Z / 2 + 2
		if b.isPet and b.part:IsA("Part") and b.part.Shape == Enum.PartType.Cylinder then
			hitBoxX, hitBoxZ = 8, 8
		end

		for j = #activeEnemies, 1, -1 do
			local e = activeEnemies[j]
			if not e.part or not e.part.Parent then
				table.remove(activeEnemies, j)
				continue
			end
			if b.hitTargets[e.part] then continue end

			local ePos = e.part.Position
			local eSize = e.part.Size

			if math.abs(bPos.X - ePos.X) < (hitBoxX + eSize.X/2) and
			   math.abs(bPos.Z - ePos.Z) < (hitBoxZ + eSize.Z/2) then

				b.hitTargets[e.part] = true
				local dmg = b.damage or playerAtk

				local finalHitVFX = b.hitVFX or (Controllers.Config.WEAPONS[b.weaponId] and Controllers.Config.WEAPONS[b.weaponId].HitVFX) or "DefaultHit"
				local hitVFXPosition = b.hitVFXPosition or bPos
				Controllers.VFX.PlayBulletExplosion(finalHitVFX, hitVFXPosition)

				if b.aoeRadius then
					local targetsToDamage = {}
					for _, otherE in ipairs(activeEnemies) do
						if otherE.part and (otherE.part.Position - bPos).Magnitude <= b.aoeRadius then
							table.insert(targetsToDamage, otherE)
						end
					end

					for _, targetE in ipairs(targetsToDamage) do
						targetE.hp = targetE.hp - dmg
						updateEnemyHpLabel(targetE)
						playEnemyHitJitter(targetE)

						if targetE.hp <= 0 then
							local deathVfxName = Controllers.Config.ENEMY_VFX[targetE.type] or "BasicDeath"
							Controllers.VFX.PlayDeathVFX(deathVfxName, targetE.part.Position)

							triggerBossGoldReward(targetE.type)
							triggerEliteGoldReward(targetE.type)
							Controllers.Encounter.TriggerDrops(targetE.type, targetE.part.Position)
							targetE.part:Destroy()
						end
					end

					b.hitsLeft = 0
				else
					e.hp = e.hp - dmg
					updateEnemyHpLabel(e)
					playEnemyHitJitter(e)

					if e.hp <= 0 then
						local deathVfxName = Controllers.Config.ENEMY_VFX[e.type] or "BasicDeath"
						Controllers.VFX.PlayDeathVFX(deathVfxName, ePos)

						triggerBossGoldReward(e.type)
						triggerEliteGoldReward(e.type)
						e.part:Destroy()
						table.remove(activeEnemies, j)
						Controllers.Encounter.TriggerDrops(e.type, ePos)
					end

					b.hitsLeft = b.hitsLeft - 1
				end

				if b.hitsLeft <= 0 then
					if not b.persistAfterHit then
						if b.part then b.part:Destroy() end
					end

					table.remove(CombatController.ActiveBullets, i)
					break
				end
			end
		end
	end

	for i = #activeGateGroups, 1, -1 do
		local group = activeGateGroups[i]
		local function isTouchingGate(gate)
			local gatePart = gate and gate.part
			if not gatePart then return false end

			local gatePos = gatePart.Position
			local gateSize = gatePart.Size
			local playerHalfWidth = 1
			local playerHalfDepth = 1

			return math.abs(pPos.X - gatePos.X) < (gateSize.X / 2 + playerHalfWidth)
				and math.abs(pPos.Z - gatePos.Z) < (gateSize.Z / 2 + playerHalfDepth)
		end

		local chosenGate = nil
		if isTouchingGate(group.left) then
			chosenGate = group.left
		elseif isTouchingGate(group.right) then
			chosenGate = group.right
		end

		if chosenGate then
			if sourceVFX and rootPart then Controllers.VFX.PlayGateVFX(rootPart) end

			if chosenGate.attr == "HP_Bonus" then
				local currentMax = player:GetAttribute("MaxHP") or Controllers.Config.BASE_HP
				local currentHp = player:GetAttribute("HP") or Controllers.Config.BASE_HP

				local changeAmount = math.floor(currentMax * (chosenGate.amount / 100))
				local newHp = math.clamp(currentHp + changeAmount, 1, currentMax)
				player:SetAttribute("HP", newHp)

				local humanoid = player.Character and player.Character:FindFirstChild("Humanoid")
				if humanoid then humanoid.Health = newHp end

			elseif chosenGate.attr == "MaxHP_Bonus" then
				local currentBonus = player:GetAttribute("MaxHP_Bonus") or 0
				player:SetAttribute("MaxHP_Bonus", currentBonus + chosenGate.amount)

				local startingStats = Controllers.Progression.CalculateStartingStats()
				local baseMaxHp = startingStats.MaxHP
				local newMaxHp = math.floor(baseMaxHp * (1 + ((currentBonus + chosenGate.amount) / 100)))

				local oldMaxHp = player:GetAttribute("MaxHP") or baseMaxHp
				player:SetAttribute("MaxHP", newMaxHp)

				local diff = newMaxHp - oldMaxHp
				if diff > 0 then
					player:SetAttribute("HP", (player:GetAttribute("HP") or oldMaxHp) + diff)
				elseif diff < 0 then
					local currentHp = player:GetAttribute("HP") or oldMaxHp
					if currentHp > newMaxHp then player:SetAttribute("HP", newMaxHp) end
				end

				local humanoid = player.Character and player.Character:FindFirstChild("Humanoid")
				if humanoid then
					humanoid.MaxHealth = newMaxHp
					humanoid.Health = player:GetAttribute("HP")
				end
			else
				local currentVal = player:GetAttribute(chosenGate.attr) or 0
				local nextVal = currentVal + chosenGate.amount
				if chosenGate.attr == "LateralSpeed_Bonus" then
					local baseSpeed = Controllers.Config.LATERAL_SPEED
					local maxSpeed = Controllers.Config.MAX_LATERAL_SPEED or baseSpeed
					local maxBonus = math.max(0, ((maxSpeed / baseSpeed) - 1) * 100)
					nextVal = math.clamp(nextVal, -maxBonus, maxBonus)
				end
				player:SetAttribute(chosenGate.attr, nextVal)
			end

			if group.left.part then group.left.part:Destroy() end
			if group.right.part then group.right.part:Destroy() end
			table.remove(activeGateGroups, i)
		elseif pPos.Z < group.z - 3 then
			if group.left.part then group.left.part:Destroy() end
			if group.right.part then group.right.part:Destroy() end
			table.remove(activeGateGroups, i)
		end
	end

	for i = #activeEnemies, 1, -1 do
		local e = activeEnemies[i]
		if not e.part then continue end

		local ePos = e.part.Position
		local eSize = e.part.Size

		if math.abs(pPos.X - ePos.X) < (eSize.X/2 + 1) and
		   math.abs(pPos.Z - ePos.Z) < (eSize.Z/2 + 1) then

			local damage = e.hp
			local currentHp = player:GetAttribute("HP") or Controllers.Config.BASE_HP
			local newHp = currentHp - damage
			player:SetAttribute("HP", newHp)

			Controllers.VFX.PlayPlayerDamageVFX()

			e.part:Destroy()
			table.remove(activeEnemies, i)

			local humanoid = player.Character:FindFirstChild("Humanoid")
			if humanoid then
				humanoid.MaxHealth = player:GetAttribute("MaxHP") or Controllers.Config.BASE_HP
				humanoid.Health = newHp
			end

			local deathVfxName = Controllers.Config.ENEMY_VFX[e.type] or "BasicDeath"
			Controllers.VFX.PlayDeathVFX(deathVfxName, ePos)
			Controllers.Encounter.TriggerDrops(e.type, ePos)
		end
	end
end

function CombatController.StartSwordSystem()
	local orbitingSwords = {}

	local function getSwordCFrame(swordData)
		if not swordData or not swordData.model or not swordData.primary then return nil end
		if swordData.model:IsA("Model") then
			return swordData.model:GetPivot()
		end
		return swordData.primary.CFrame
	end

	local function pivotSwordTo(swordData, targetCFrame)
		if not swordData or not swordData.model or not swordData.primary then return end
		if swordData.model:IsA("Model") then
			swordData.model:PivotTo(targetCFrame)
		else
			swordData.primary.CFrame = targetCFrame
		end
	end

	-- 获取飞剑模型在 Studio 中保存的原始朝向；后续只移动位置，不再用代码重算朝向。
	local function getSwordStudioRotation(swordModel, primaryPart)
		if swordModel and swordModel:IsA("Model") then
			return swordModel:GetPivot().Rotation
		elseif primaryPart then
			return primaryPart.CFrame.Rotation
		end

		return CFrame.new().Rotation
	end

	-- 用 Studio 原始朝向生成飞剑 CFrame；避免 CFrame.lookAt 把美术模型转反或转上。
	local function getSwordStudioCFrame(swordData, position)
		local rotation = swordData and swordData.studioRotation or CFrame.new().Rotation
		return CFrame.new(position) * rotation
	end

	-- 记录飞剑模型每个部件在 Studio 里的原始透明度；显示时恢复原值，避免 VFX 挂载块被强行显示。
	local function cacheSwordOriginalTransparency(swordData)
		if not swordData or not swordData.model then return end
		swordData.originalTransparency = {}

		if swordData.model:IsA("Model") then
			for _, obj in ipairs(swordData.model:GetDescendants()) do
				if obj:IsA("BasePart") then
					swordData.originalTransparency[obj] = obj.Transparency
				end
			end
		elseif swordData.primary then
			swordData.originalTransparency[swordData.primary] = swordData.primary.Transparency
		end
	end

	local function setSwordTransparency(swordData, transparency)
		if not swordData or not swordData.model then return end
		local originalTransparency = swordData.originalTransparency or {}

		if swordData.model:IsA("Model") then
			for _, obj in ipairs(swordData.model:GetDescendants()) do
				if obj:IsA("BasePart") then
					if transparency >= 1 then
						obj.Transparency = 1
					else
						obj.Transparency = originalTransparency[obj] or 0
					end
				end
			end
		elseif swordData.primary then
			if transparency >= 1 then
				swordData.primary.Transparency = 1
			else
				swordData.primary.Transparency = originalTransparency[swordData.primary] or 0
			end
		end
	end

	local function getSwordHoverCFrame(rootPart, swordIndex, totalCount, sc, now, swordData)
		if not rootPart then return nil end

		-- 飞剑待机队形：左右交替排列，同一侧逐步外扩，同时叠加前后和高低错位。
		-- 这样数量增加到 3-6 把时，玩家从背后视角也能直观看出每一把飞剑。
		local pairIndex = math.ceil(swordIndex / 2)
		local side = (swordIndex % 2 == 1) and 1 or -1
		if totalCount <= 1 then
			side = 1
			pairIndex = 1
		end

		local sideOffset = sc.HoverSideOffset or sc.OrbitRadius or 5
		local sideSpacing = sc.HoverSideSpacing or 0
		local backOffset = sc.HoverBackOffset or 1.2
		local depthSpacing = sc.HoverDepthSpacing or 1.4
		local baseHeight = sc.HoverHeight or 2.8
		local heightSpacing = sc.HoverHeightSpacing or 0.25
		local bobAmplitude = sc.HoverBobAmplitude or 0.18
		local bobSpeed = sc.HoverBobSpeed or 2.5
		local bobPhaseSpacing = sc.HoverBobPhaseSpacing or 0.8
		local heightPattern = sc.HoverHeightPattern or {0, 1, -1}

		local heightKey = heightPattern[((swordIndex - 1) % #heightPattern) + 1] or 0
		local heightOffset = heightKey * heightSpacing
		local bobOffset = math.sin(now * bobSpeed + swordIndex * bobPhaseSpacing) * bobAmplitude
		local localOffset = CFrame.new(
			side * (sideOffset + (pairIndex - 1) * sideSpacing),
			baseHeight + heightOffset + bobOffset,
			backOffset + (pairIndex - 1) * depthSpacing
		)
		local hoverPos = (rootPart.CFrame * localOffset).Position

		return getSwordStudioCFrame(swordData, hoverPos)
	end

	local function isSwordTargetAlive(enemy)
		return enemy and enemy.part and enemy.part.Parent and (enemy.hp or 0) > 0
	end

	local function removeEnemyFromActiveList(enemy)
		local activeEnemies = Controllers.Encounter.ActiveEnemies
		for i = #activeEnemies, 1, -1 do
			if activeEnemies[i] == enemy then
				table.remove(activeEnemies, i)
				return
			end
		end
	end

	local function killEnemyBySword(enemy, hitPos, Config)
		local deathVfx = Config.ENEMY_VFX[enemy.type] or "BasicDeath"
		Controllers.VFX.PlayDeathVFX(deathVfx, hitPos)
		triggerBossGoldReward(enemy.type)
		triggerEliteGoldReward(enemy.type)
		Controllers.Encounter.TriggerDrops(enemy.type, hitPos)
		removeEnemyFromActiveList(enemy)
		if enemy.part then
			enemy.part:Destroy()
		end
	end

	local function clearSwordAttackData(swordData)
		swordData.targetEnemy = nil
		swordData.damage = nil
		swordData.attackStartPos = nil
		swordData.attackTargetPos = nil
		swordData.attackProgress = nil
		swordData.attackDuration = nil
	end

	local function setSwordAttack(swordData, targetEnemy, swordDmg, sc)
		if not swordData or swordData.state ~= "Orbiting" or not isSwordTargetAlive(targetEnemy) then return false end

		local currentCFrame = getSwordCFrame(swordData)
		if not currentCFrame then return false end

		local targetPos = targetEnemy.part.Position
		local distance = (targetPos - currentCFrame.Position).Magnitude
		swordData.state = "Attacking"
		swordData.targetEnemy = targetEnemy
		swordData.damage = swordDmg
		swordData.attackStartPos = currentCFrame.Position
		swordData.attackTargetPos = targetPos
		swordData.attackProgress = 0
		swordData.attackDuration = math.max(distance / sc.FlySpeed, 0.05)
		return true
	end

	RunService.RenderStepped:Connect(function(dt)
		if not Controllers.Game.IsCombatActive then
			for _, s in ipairs(orbitingSwords) do
				setSwordTransparency(s, 1)
				if s.state == "Attacking" then
					clearSwordAttackData(s)
					s.state = "Returning"
				end
			end
			return
		end

		local unlocked = (player:GetAttribute("Sword_Unlocked") or 0) > 0
		if not unlocked then
			for _, s in ipairs(orbitingSwords) do if s.model then s.model:Destroy() end end
			table.clear(orbitingSwords)
			return
		end

		local character = player.Character
		if not character or not character.PrimaryPart then return end
		local rootPart = character.PrimaryPart
		local sc = Controllers.Config.SWORD_SKILL
		local count = math.min((player:GetAttribute("Sword_Count") or 0) + 1, sc.MaxCount)

		while #orbitingSwords < count do
			local rs = game:GetService("ReplicatedStorage")
			local prefab = rs:FindFirstChild("Model") and rs.Model:FindFirstChild("Skills") and rs.Model.Skills:FindFirstChild("FlyingSword")
			local swordPart

			if prefab then
				swordPart = prefab:Clone()
				if swordPart:IsA("Model") and not swordPart.PrimaryPart then
					swordPart.PrimaryPart = swordPart:FindFirstChildWhichIsA("BasePart", true)
				end
			else
				swordPart = Instance.new("Part")
				swordPart.Size = Vector3.new(0.5, 0.5, 3)
				swordPart.Color = Color3.fromRGB(0, 255, 255)
				swordPart.Material = Enum.Material.Neon
			end

			local targetPart = swordPart:IsA("Model") and swordPart.PrimaryPart or swordPart
			if not targetPart or not targetPart:IsA("BasePart") then
				warn("[CombatController] FlyingSword 预制体缺少可用的 BasePart，已回退到白模飞剑。")
				if swordPart then swordPart:Destroy() end
				swordPart = Instance.new("Part")
				swordPart.Size = Vector3.new(0.5, 0.5, 3)
				swordPart.Color = Color3.fromRGB(0, 255, 255)
				swordPart.Material = Enum.Material.Neon
				targetPart = swordPart
			end
			targetPart.Anchored = true
			targetPart.CanCollide = false
			swordPart.Parent = Workspace:FindFirstChild("LocalProjectiles") or Workspace

			local swordData = {
				model = swordPart,
				primary = targetPart,
				state = "Orbiting",
				studioRotation = getSwordStudioRotation(swordPart, targetPart),
			}
			cacheSwordOriginalTransparency(swordData)
			table.insert(orbitingSwords, swordData)
		end
		while #orbitingSwords > count do
			local removed = table.remove(orbitingSwords)
			if removed.model then removed.model:Destroy() end
		end

		local now = os.clock()
		for i, swordData in ipairs(orbitingSwords) do
			local hoverCFrame = getSwordHoverCFrame(rootPart, i, count, sc, now, swordData)
			if not hoverCFrame then continue end
			local hoverPos = hoverCFrame.Position
			local currentCFrame = getSwordCFrame(swordData)
			if not currentCFrame then continue end
			local currentPos = currentCFrame.Position

			if swordData.state == "Orbiting" then
				pivotSwordTo(swordData, currentCFrame:Lerp(hoverCFrame, dt * 10))
				setSwordTransparency(swordData, 0)

			elseif swordData.state == "Returning" then
				local newPos = currentPos:Lerp(hoverPos, dt * 18)
				pivotSwordTo(swordData, getSwordStudioCFrame(swordData, newPos))

				if (newPos - hoverPos).Magnitude < 1.5 then
					clearSwordAttackData(swordData)
					swordData.state = "Orbiting"
				end
			elseif swordData.state == "Attacking" then
				if player:GetAttribute("IsLevelingUp") or not Controllers.Game.IsCombatActive then
					clearSwordAttackData(swordData)
					swordData.state = "Returning"
					continue
				end

				local targetEnemy = swordData.targetEnemy
				if not isSwordTargetAlive(targetEnemy) then
					clearSwordAttackData(swordData)
					swordData.state = "Returning"
					continue
				end

				local targetPos = targetEnemy.part.Position
				swordData.attackTargetPos = targetPos
				swordData.attackProgress = math.min((swordData.attackProgress or 0) + dt / (swordData.attackDuration or 0.05), 1)

				local startPos = swordData.attackStartPos or currentPos
				local newPos = startPos:Lerp(targetPos, swordData.attackProgress)
				pivotSwordTo(swordData, getSwordStudioCFrame(swordData, newPos))

				if swordData.attackProgress >= 1 then
					if Controllers.Game.IsCombatActive and not player:GetAttribute("IsLevelingUp") and isSwordTargetAlive(targetEnemy) then
						local hitPos = targetEnemy.part.Position
						targetEnemy.hp = targetEnemy.hp - (swordData.damage or 0)
						updateEnemyHpLabel(targetEnemy)
						playEnemyHitJitter(targetEnemy)
						Controllers.VFX.PlayBulletExplosion("DefaultHit", hitPos)

						if targetEnemy.hp <= 0 then
							killEnemyBySword(targetEnemy, hitPos, Controllers.Config)
						end
					end

					clearSwordAttackData(swordData)
					swordData.state = "Returning"
				end
			end
		end
	end)

	task.spawn(function()
		local Config = Controllers.Config
		while true do
			if not Controllers.Game.IsCombatActive or player:GetAttribute("IsLevelingUp") or (player:GetAttribute("Sword_Unlocked") or 0) <= 0 then
				task.wait(player:GetAttribute("IsLevelingUp") and 0.1 or 0.5)
				continue
			end

			local sc = Config.SWORD_SKILL
			local cdReduction = math.min(player:GetAttribute("Sword_CD_Reduction") or 0, sc.MaxCooldownReduction)
			local actualCd = math.max(sc.MinAttackInterval, sc.BaseAttackInterval * (1 - (cdReduction / 100)))

			local character = player.Character
			if character and character.PrimaryPart then
				local playerPos = character.PrimaryPart.Position
				local enemies = Controllers.Encounter.ActiveEnemies
				local validTargets = {}

				for _, e in ipairs(enemies) do
					if e and e.part and e.part.Parent and e.hp > 0 then
						local ePos = e.part.Position
						if ePos.Z < playerPos.Z then
							local dist = (ePos - playerPos).Magnitude
							if dist <= sc.TargetRange then table.insert(validTargets, {enemy = e, dist = dist}) end
						end
					end
				end

				if #validTargets > 0 then
					table.sort(validTargets, function(a, b) return a.dist < b.dist end)
					local atkBonus = player:GetAttribute("Sword_ATK_Bonus") or 0
					local swordDmg = math.floor(sc.BaseDamage * (1 + (atkBonus / 100)))

					for _, swordData in ipairs(orbitingSwords) do
						if swordData.state == "Orbiting" then
							if not Controllers.Game.IsCombatActive or player:GetAttribute("IsLevelingUp") then
								break
							end

							local targetEnemy
							for _, targetInfo in ipairs(validTargets) do
								if isSwordTargetAlive(targetInfo.enemy) then
									targetEnemy = targetInfo.enemy
									break
								end
							end

							if targetEnemy and setSwordAttack(swordData, targetEnemy, swordDmg, sc) then
								task.wait(math.random(8, 15) / 100)
							end
						end
					end
				end
			end
			task.wait(actualCd)
		end
	end)
end

return CombatController
