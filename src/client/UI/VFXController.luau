-- src/client/UI/VFXController.luau
-- 3D 视觉表现控制器：负责处理近大远小文本、粒子特效、以及物理动画
local VFXController = {}

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService") -- 引入 RunService 用于处理自转动画

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

return VFXController