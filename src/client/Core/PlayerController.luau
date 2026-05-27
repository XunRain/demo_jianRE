-- src/client/Core/PlayerController.luau
-- 玩家控制器：负责键盘输入处理、每帧的物理移动、相机跟随，以及驱动整个局内世界的运转循环
local PlayerController = {}

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera 

local Controllers -- 全局依赖指针
local moveDirection = 0 -- 玩家当前的键盘输入方向 (-1左, 0不动, 1右)

function PlayerController.Init(deps)
	Controllers = deps
end

-- 启动输入监听与渲染主循环
function PlayerController.Start()
	PlayerController.SetupInput()
	-- 将无优先级的 Connect 改为有优先级的 BindToRenderStep
	-- 绑定在 Camera.Value (200)。由于 200 先执行，震屏的 201 后执行，
	-- 这样震动位移就永远可以成功叠加在基础相机锁定的坐标之上了
	RunService:BindToRenderStep("PlayerCoreLoop", Enum.RenderPriority.Camera.Value, PlayerController.OnRenderStepped)
end

-- 供外部模块调用的接口 (例如：升级暂停、重置开局时，强制重置移动状态)
function PlayerController.SetMoveDirection(dir)
	moveDirection = dir
end

-- 绑定玩家的键盘按键输入
function PlayerController.SetupInput()
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		-- 如果在打字、非战斗状态、或者正在升级选卡时，剥夺玩家输入权
		if gameProcessed or not Controllers.Game.IsCombatActive or player:GetAttribute("IsLevelingUp") then return end
		
		if input.KeyCode == Enum.KeyCode.A or input.KeyCode == Enum.KeyCode.Left then
			moveDirection = -1
		elseif input.KeyCode == Enum.KeyCode.D or input.KeyCode == Enum.KeyCode.Right then
			moveDirection = 1
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.A or input.KeyCode == Enum.KeyCode.Left then
			if moveDirection == -1 then moveDirection = 0 end
		elseif input.KeyCode == Enum.KeyCode.D or input.KeyCode == Enum.KeyCode.Right then
			if moveDirection == 1 then moveDirection = 0 end
		end
	end)
end

-- 核心主循环 (每帧渲染，等同于原版的 onRenderStepped)
function PlayerController.OnRenderStepped(dt)
	local character = player.Character
	if not character then return end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChild("Humanoid")
	
	-- 没加载好或者死人不需要进行任何跑酷计算
	if not rootPart or not humanoid or humanoid.Health <= 0 then return end

	-- ─── 阶段 A: 大厅状态 ───
	if not Controllers.Game.IsCombatActive then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		humanoid.AutoRotate = true
		-- 如果相机还被脚本锁着，释放回给玩家自由控制
		if camera.CameraType == Enum.CameraType.Scriptable then
			camera.CameraType = Enum.CameraType.Custom
			camera.CameraSubject = humanoid
		end
		return 
	end

	-- ─── 阶段 B: 升级暂停状态 ───
	if player:GetAttribute("IsLevelingUp") then
		humanoid.WalkSpeed = 0 -- 刹车停住
		return
	end

	-- ─── 阶段 C: 跑酷战斗状态 ───
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false) 
	humanoid.AutoRotate = false                                    
	
	local currentPos = rootPart.Position
	local Config = Controllers.Config
	local trackStartX = Controllers.Map.TrackStartX -- 从地图控制器获取跑道的中心点 X
	
	-- 软性边界限制：防止玩家跑出跑道两侧
	local clampedX = math.clamp(currentPos.X, trackStartX - Config.RUNWAY_LIMIT, trackStartX + Config.RUNWAY_LIMIT)
	
	-- 强制玩家身体永远死死盯着正前方
	rootPart.CFrame = CFrame.lookAt(
		Vector3.new(clampedX, currentPos.Y, currentPos.Z),
		Vector3.new(clampedX, currentPos.Y, currentPos.Z - 10)
	)

	-- 驱动世界运转：呼叫各个子系统执行各自的逻辑
	Controllers.Map.UpdateTrack(currentPos.Z)           -- 动态拼地图
	Controllers.Combat.CheckCollisions(rootPart)        -- 结算撞门/打怪
	Controllers.Encounter.UpdateMagnetism(dt, rootPart) -- 驱动掉落物的物理吸附轨迹
	Controllers.Encounter.UpdatePlayerStage(currentPos.Z) -- 实时核对并更新玩家当前的物理关卡进度

	-- 向量矫正器：防止撞墙时降速，确保向前的 Z 轴分量永远等于 RUN_SPEED
	local effectiveMoveDirection = moveDirection
	if clampedX <= (trackStartX - Config.RUNWAY_LIMIT) and moveDirection == -1 then
		effectiveMoveDirection = 0
	elseif clampedX >= (trackStartX + Config.RUNWAY_LIMIT) and moveDirection == 1 then
		effectiveMoveDirection = 0
	end
	
	-- 【核心优化】：实时获取并应用当前游戏进程的配置速度
	local currentStage = player:GetAttribute("CurrentStage") or 1
	local currentRunSpeed = Config.GetRunSpeed(currentStage)
	
	-- 计算最终想要移动的速度向量 (侧向移动 + 动态向前奔跑速度)
	local desiredVelocity = Vector3.new(effectiveMoveDirection * Config.LATERAL_SPEED, 0, -currentRunSpeed)
	humanoid.WalkSpeed = desiredVelocity.Magnitude
	humanoid:Move(desiredVelocity.Unit, false)
	
	-- 相机接管：锁定到玩家背后的无人机跟拍位
	camera.CameraType = Enum.CameraType.Scriptable
	local targetPos = rootPart.Position
	local camPos = targetPos + Config.CAMERA_OFFSET
	local lookAtPos = targetPos + Config.CAMERA_LOOK_OFFSET
	camera.CFrame = CFrame.lookAt(camPos, lookAtPos)
end

return PlayerController