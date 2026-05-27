-- src/client/UI/VFXController.luau
-- 3D 视觉表现控制器：负责处理近大远小文本、粒子特效、以及物理动画
local VFXController = {}

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService") -- 引入 RunService 用于处理自转动画
local Players = game:GetService("Players") -- 引入 Players 服务
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting") -- 引入光照服务，用于屏幕滤镜

-- 预加载吃门的粒子特效
local vfxFolder = ReplicatedStorage:WaitForChild("VFX", 10)
local sourceVFX = vfxFolder and vfxFolder:WaitForChild("CollisionDoorVFX", 5)

-- 3D悬浮 UI 模板（用于门和怪物血量）
local guiFolder = ReplicatedStorage:WaitForChild("GUI", 10)
local suspensionTextTemplate = guiFolder and guiFolder:WaitForChild("SuspensionText", 5)

local Controllers -- 全局依赖指针

function VFXController.Init(deps)
	Controllers = deps
end

function VFXController.Start()
	-- 纯工具类模块，不需要常驻循环监听
end

-- ==========================================
-- 接口 1：统一的 3D 悬浮文本生成 (从 ReplicatedStorage 克隆模板)
-- ==========================================
function VFXController.CreateBillboard(part, text, textColor, yOffset)
	if not suspensionTextTemplate then
		warn("VFXController 警告: 未能在 ReplicatedStorage/GUI/ 中找到 SuspensionText 模板！")
		return nil
	end

	local billboard = suspensionTextTemplate:Clone()
	
	-- =======================================================
	-- 【核心优化】：使用 WorldSpace 代替普通 Offset
	-- =======================================================
	-- 1. 清空原有的相对偏移，防止你在 Studio 里误调了参数产生叠加
	billboard.StudsOffset = Vector3.new(0, 0, 0) 
	
	-- 2. 赋予世界绝对偏移，让 UI 像钉子一样钉在怪物的正上方！
	billboard.StudsOffsetWorldSpace = Vector3.new(0, (part.Size.Y / 2) + yOffset, 0)
	-- =======================================================
	
	local label = billboard:FindFirstChild("Text")
	if label and label:IsA("TextLabel") then
		label.Text = text
		label.TextColor3 = textColor
	else
		warn("VFXController 警告: SuspensionText 内部没有找到名为 'Text' 的 TextLabel！")
	end
	
	billboard.Parent = part
	
	return label
end

-- 接口 2：掉落物爆破散开动画 (带精准落地修复)
function VFXController.PlayDropExplosion(part, startPos)
	local angle = math.random() * math.pi * 2
	local radius = math.random(3, 10)
	
	-- 【核心修复】：向下打一条射线，精准寻找跑道地面的 Y 坐标
	local groundY = startPos.Y - 2 -- 默认兜底高度
	
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Include
	
	-- 为了性能和精准度，只允许射线检测我们存跑道的文件夹（LocalTrack）
	local trackFolder = game.Workspace:FindFirstChild("LocalTrack")
	if trackFolder then
		rayParams.FilterDescendantsInstances = {trackFolder}
		-- 从怪物中心点垂直向下发射一条 50 米长的射线找地板
		local hit = game.Workspace:Raycast(startPos, Vector3.new(0, -50, 0), rayParams)
		if hit then
			groundY = hit.Position.Y
		end
	end

	-- 目标的 Y 坐标 = 真正的地板高度 + 掉落物自身高度的一半（确保完美贴合，不陷进地里）
	local targetPos = Vector3.new(
		startPos.X + math.cos(angle) * radius, 
		groundY + (part.Size.Y / 2), 
		startPos.Z + math.sin(angle) * radius
	)
	
	-- 使用缓动引擎实现炸开并落地的完美抛物线过渡
	local tInfo = TweenInfo.new(0.5, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out)
	local tween = TweenService:Create(part, tInfo, {Position = targetPos})
	tween:Play()
end

-- ==========================================
-- 接口 3：玩家吃门时的动态特效 (焊接与粒子释放)
-- ==========================================
function VFXController.PlayGateVFX(rootPart)
	if not sourceVFX or not rootPart then return end
	
	local vfxClone = sourceVFX:Clone()
	
	if vfxClone:IsA("PVInstance") then
		vfxClone:PivotTo(rootPart.CFrame)
	end
	vfxClone.Parent = rootPart 
	
	if vfxClone:IsA("BasePart") then
		vfxClone.Anchored = false   
		vfxClone.CanCollide = false 
		
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = rootPart       
		weld.Part1 = vfxClone       
		weld.Parent = vfxClone
	elseif vfxClone:IsA("Model") then
		local primary = vfxClone.PrimaryPart or vfxClone:FindFirstChildWhichIsA("BasePart", true)
		if primary then
			primary.Anchored = false
			primary.CanCollide = false
			
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = rootPart
			weld.Part1 = primary
			weld.Parent = vfxClone
			
			for _, p in ipairs(vfxClone:GetDescendants()) do
				if p:IsA("BasePart") then
					p.Anchored = false
					p.CanCollide = false
				end
			end
		end
	end
	
	for _, descendant in ipairs(vfxClone:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = true
			descendant.LockedToPart = true
			descendant:Emit(25) 
		end
	end
	
	Debris:AddItem(vfxClone, 0.5)
end

-- 接口 4：宠物蛋晃动动画 (左晃 -> 右晃 -> 回正)
function VFXController.PlayEggShakeVFX(model)
	if not model or not model.PrimaryPart then return end
	local part = model.PrimaryPart
	local baseCFrame = CFrame.new(0, 0, 0) -- 蛋的基础原点位置
	
	-- 开启独立线程，不阻塞玩家连点
	task.spawn(function()
		-- 极短的动画时间 (0.06秒)，确保手感清脆
		local tInfo = TweenInfo.new(0.06, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
		
		local t1 = TweenService:Create(part, tInfo, {CFrame = baseCFrame * CFrame.Angles(0, 0, math.rad(30))})
		local t2 = TweenService:Create(part, tInfo, {CFrame = baseCFrame * CFrame.Angles(0, 0, math.rad(-30))})
		local t3 = TweenService:Create(part, tInfo, {CFrame = baseCFrame})
		
		-- 第一段：向左偏
		t1:Play()
		t1.Completed:Wait()
		
		-- 安全网：如果被销毁了立刻中止后续动画
		if not part or not part.Parent then return end 
		
		-- 第二段：向右偏
		t2:Play()
		t2.Completed:Wait()
		
		if not part or not part.Parent then return end
		
		-- 第三段：完美回正
		t3:Play()
	end)
end

-- 接口 5：宠物破壳后的自转展示动画
function VFXController.StartPetSpinVFX(model)
	if not model or not model.PrimaryPart then return nil end
	
	local rotationY = 0
	local spinConnection = RunService.RenderStepped:Connect(function(dt)
		if model and model.PrimaryPart then
			rotationY = rotationY + math.rad(45 * dt)
			model:SetPrimaryPartCFrame(CFrame.new(0, 0, 0) * CFrame.Angles(0, rotationY, 0))
		end
	end)
	
	-- 返回这个事件连接，以便 UIController 能够在关闭界面时把它清理掉
	return spinConnection
end



local currentGuideBeam = nil
local currentGuideAtt0 = nil
local currentGuideAtt1 = nil
local currentGuideLabel = nil

-- 接口 6：创建大厅 3D 光束引导与悬浮文字
function VFXController.CreateGuide(targetPart, text)
	VFXController.ClearGuide() -- 先清理旧的，防止重叠
	
	local character = Players.LocalPlayer.Character
	if not character then return end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not targetPart then return end

	-- 1. 创建起点(玩家)和终点(目标)的挂载点
	currentGuideAtt0 = Instance.new("Attachment", rootPart)
	currentGuideAtt1 = Instance.new("Attachment", targetPart)

	-- 2. 创建流动光束
	currentGuideBeam = Instance.new("Beam")
	currentGuideBeam.Attachment0 = currentGuideAtt1 -- 起点设为 NPC
	currentGuideBeam.Attachment1 = currentGuideAtt0 -- 终点设为 玩家
	currentGuideBeam.FaceCamera = true -- 永远正对屏幕
	currentGuideBeam.Width0 = 2
	currentGuideBeam.Width1 = 2
	currentGuideBeam.Color = ColorSequence.new(Color3.fromRGB(255, 215, 0)) -- 金黄色光束
	-- 使用经典的 Roblox 流动箭头贴图
	currentGuideBeam.Texture = "rbxassetid://9006027964" 
	currentGuideBeam.TextureMode = Enum.TextureMode.Wrap
	currentGuideBeam.TextureSpeed = -3  -- 箭头流动速度，负数为反向流动
	currentGuideBeam.TextureLength = 4 -- 箭头密集度
	currentGuideBeam.LightEmission = 1 -- 光束自带发光效果
	currentGuideBeam.Parent = rootPart

	-- 3. 创建目标头顶的悬浮提示文字（复用接口1）
	currentGuideLabel = VFXController.CreateBillboard(targetPart, "⭐ " .. text, Color3.fromRGB(255, 255, 100), 4)
end

-- 接口 7：清理引导光束
function VFXController.ClearGuide()
	if currentGuideBeam then currentGuideBeam:Destroy();currentGuideBeam = nil end
	if currentGuideAtt0 then currentGuideAtt0:Destroy();currentGuideAtt0 = nil end
	if currentGuideAtt1 then currentGuideAtt1:Destroy();currentGuideAtt1 = nil end
	if currentGuideLabel then 
		currentGuideLabel.Parent:Destroy() -- Label 的 Parent 是 BillboardGui，直接销毁 Gui
		currentGuideLabel = nil 
	end
end

-- ==========================================
-- 接口 8：实体受击抖动特效 (一大一小快速回弹)
-- 支持敌方 Part 和 我方 Model！
-- ==========================================
function VFXController.PlayHitJitterVFX(target, baseSize)
	if not target then return end
	
	-- 增加动画锁，防止密集子弹不断打断缩回动画
	if target:GetAttribute("IsJittering") then return end
	target:SetAttribute("IsJittering", true)
	
	task.spawn(function()
		if target:IsA("BasePart") and baseSize then
			-- 针对单体 Part（现在的怪物）
			local tInfo = TweenInfo.new(0.05, Enum.EasingStyle.Sine, Enum.EasingDirection.Out, 0, true)
			local tween = TweenService:Create(target, tInfo, {Size = baseSize * 1.3})
			tween:Play()
			
			-- 等待这段动画彻底播完 (0.05 * 2 = 0.1秒)
			tween.Completed:Wait()
			
			if target and target.Parent then
				-- 兜底强行恢复初始尺寸，防止引擎卡顿丢帧
				target.Size = baseSize 
				-- 播完后，解开动画锁，允许下一次受击动画
				target:SetAttribute("IsJittering", false)
			end
			
		elseif target:IsA("Model") then
			-- 针对完整的模型（玩家肉身）
			local originalScale = target:GetScale()
			target:ScaleTo(originalScale * 1.2)
			task.wait(0.05)
			
			if target and target.Parent then
				target:ScaleTo(originalScale)
				target:SetAttribute("IsJittering", false)
			end
		end
	end)
end

-- ==========================================
-- 接口 9：播放子弹命中爆炸特效 (完全数据驱动)
-- ==========================================
function VFXController.PlayBulletExplosion(hitVfxName, position)
	local vfxFolder = ReplicatedStorage:FindFirstChild("VFX")
	local weaponsFolder = vfxFolder and vfxFolder:FindFirstChild("Weapons")
	local vfxPrefab = weaponsFolder and weaponsFolder:FindFirstChild(hitVfxName)
	
	if vfxPrefab then
		local vfx = vfxPrefab:Clone()
		
		-- 自动适配你放的是 Part 还是 Model
		if vfx:IsA("BasePart") then
			-- CFrame = 新位置 * 预制体原本的旋转角度
			vfx.CFrame = CFrame.new(position) * vfxPrefab.CFrame.Rotation
		elseif vfx:IsA("Model") then
			-- 保留 Model 在 Studio 中打包时的初始朝向
			vfx:PivotTo(CFrame.new(position) * vfxPrefab:GetPivot().Rotation)
		end
		
		vfx.Parent = Workspace:FindFirstChild("LocalProjectiles") or Workspace
		
		-- 自动遍历寻找粒子特效并瞬间爆发
		for _, emitter in ipairs(vfx:GetDescendants()) do
			if emitter:IsA("ParticleEmitter") then
				emitter.Enabled = false -- 关闭持续喷发
				-- 读取你在 Studio 里配置的爆发数量，默认 15 个粒子
				emitter:Emit(emitter:GetAttribute("EmitCount") or 10) 
			end
		end
		
		Debris:AddItem(vfx, 0.25) -- 特效 1 秒后自动销毁，防内存泄漏
	end
end

-- 接口 10：播放怪物死亡爆浆/爆炸特效
function VFXController.PlayDeathVFX(vfxName, position)
	local vfxFolder = ReplicatedStorage:FindFirstChild("VFX")
	-- 去专属的 Enemies 文件夹下找死亡特效
	local enemiesFolder = vfxFolder and vfxFolder:FindFirstChild("Enemies") 
	local vfxPrefab = enemiesFolder and enemiesFolder:FindFirstChild(vfxName)
	
	if vfxPrefab then
		local vfx = vfxPrefab:Clone()
		
		if vfx:IsA("BasePart") then
			vfx.CFrame = CFrame.new(position) * vfxPrefab.CFrame.Rotation
		elseif vfx:IsA("Model") then
			vfx:PivotTo(CFrame.new(position) * vfxPrefab:GetPivot().Rotation)
		end
		
		vfx.Parent = Workspace:FindFirstChild("LocalProjectiles") or Workspace
		
		-- 瞬间爆发所有粒子
		for _, emitter in ipairs(vfx:GetDescendants()) do
			if emitter:IsA("ParticleEmitter") then
				emitter.Enabled = false 
				-- 死亡爆发通常比子弹击中更剧烈，默认给 30 个粒子
				emitter:Emit(emitter:GetAttribute("EmitCount") or 10) 
			end
		end
		
		-- 留出 1.5 秒让粒子慢慢消散再销毁载体
		Debris:AddItem(vfx, 1.5)
	end
end

-- 接口 11：玩家专属受击反馈 (全屏闪红 + 屏幕震动)
function VFXController.PlayPlayerDamageVFX()
	-- 1. 全屏闪红效果 (利用 Lighting 的 ColorCorrectionEffect)
	local hitCC = Lighting:FindFirstChild("PlayerHitCC")
	if not hitCC then
		hitCC = Instance.new("ColorCorrectionEffect")
		hitCC.Name = "PlayerHitCC"
		hitCC.Parent = Lighting
	end
	
	-- 每次受击，瞬间变成刺眼的血红色
	hitCC.TintColor = Color3.new(1, 0.2, 0.2) 
	
	-- 平滑褪色回正常白光，即使被连续攻击也会无缝重置动画
	local ccTweenInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(hitCC, ccTweenInfo, {TintColor = Color3.new(1, 1, 1)}):Play()
	
	-- 2. 屏幕震动 (利用 RenderStepped 优先级机制)
	local shakeDuration = 0.25
	local startTime = os.clock()
	local camera = game.Workspace.CurrentCamera
	
	-- 【核心机制】：绑定在 Camera.Value + 1 优先级，确保在 PlayerController 锁死相机之后强行叠加偏移！
	RunService:BindToRenderStep("PlayerScreenShake", Enum.RenderPriority.Camera.Value + 1, function()
		local elapsed = os.clock() - startTime
		if elapsed >= shakeDuration then
			-- 震动时间结束，解绑事件
			RunService:UnbindFromRenderStep("PlayerScreenShake")
			return
		end
		
		-- 震动强度随时间平滑衰减 (最大偏移 0.8 距离)
		local intensity = (1 - (elapsed / shakeDuration)) * 0.8
		local offsetX = (math.random() - 0.5) * 2 * intensity
		local offsetY = (math.random() - 0.5) * 2 * intensity
		
		-- 在原有相机的坐标基础上，强行揉进去随机位移，实现暴力晃动
		camera.CFrame = camera.CFrame * CFrame.new(offsetX, offsetY, 0)
	end)
end

-- 接口 12：玩家死亡表现 (碎尸爆开散落)
function VFXController.PlayPlayerDeathExplosion(character)
	if not character then return end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	-- 获取爆炸中心点，如果找不到 rootPart 就取模型中心
	local centerPos = rootPart and rootPart.Position or character:GetPivot().Position
	
	-- 1. 瞬间粉碎所有骨骼关节，让身体散架
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("Motor6D") then
			descendant:Destroy()
		end
	end
	
	-- 2. 给每个身体零件施加物理爆炸冲击力
	for _, part in ipairs(character:GetChildren()) do
		if part:IsA("BasePart") then
			part.CanCollide = true -- 确保零件能掉在地上弹跳，而不是穿透地板
			
			-- 计算从中心向外炸开的向量
			local dir = (part.Position - centerPos).Unit
			-- 稍微加一点向上的力 (Y 轴)，并加入随机散布偏移
			local burstVector = (dir + Vector3.new(math.random()-0.5, 1.5, math.random()-0.5)).Unit
			
			-- ApplyImpulse 需要乘以零件的质量 (Mass) 才能获得一致的炸开速度
			local impulseForce = burstVector * math.random(60, 120) * part.Mass
			part:ApplyImpulse(impulseForce)
			
			-- 加上随机的旋转力，让零件在空中翻滚
			local angularForce = Vector3.new(math.random(-50, 50), math.random(-50, 50), math.random(-50, 50)) * part.Mass
			part:ApplyAngularImpulse(angularForce)
		end
	end
end
return VFXController