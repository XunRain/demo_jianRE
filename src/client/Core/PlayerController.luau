-- src/client/Core/PlayerController.luau
-- 玩家控制器：负责键盘输入处理、每帧的物理移动、相机跟随，以及驱动整个局内世界的运转循环
local PlayerController = {}

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera 
local keyboardMoveDirection = 0 -- Keyboard input direction
local touchMoveDirection = 0 -- Mobile touch input direction
local activeTouchInput = nil -- 当前正在控制横移的触控输入对象
local touchStartX = 0 -- 本次滑动的起点 X 坐标

local Controllers -- 全局依赖指针
local moveDirection = 0 -- 玩家当前的键盘输入方向 (-1左, 0不动, 1右)

function PlayerController.Init(deps)
	Controllers = deps
end

-- 合并键盘和触控方向；触控有输入时优先使用触控，避免手机滑动和键盘状态互相干扰。
local function refreshMoveDirection()
	if touchMoveDirection ~= 0 then
		moveDirection = touchMoveDirection
	else
		moveDirection = keyboardMoveDirection
	end
end

-- 清理手机端触控输入状态；用于松手、升级暂停、非战斗等场景。
local function clearTouchInput()
	activeTouchInput = nil
	touchStartX = 0
	touchMoveDirection = 0
	refreshMoveDirection()
end

-- 清理全部横向输入；外部强制暂停或退出战斗时调用。
local function clearAllMoveInput()
	keyboardMoveDirection = 0
	clearTouchInput()
end

-- 判断当前是否允许战斗输入；升级选卡和非战斗状态下不响应键盘/触控。
local function canUseCombatInput()
	return Controllers and Controllers.Game and Controllers.Game.IsCombatActive and not player:GetAttribute("IsLevelingUp")
end

-- 判断触控点是否位于屏幕下半区，避免点击升级卡、背包、商店等 UI 时误触横移。
local function isTouchInActiveArea(input)
	local currentCamera = Workspace.CurrentCamera or camera
	if not currentCamera then return false end

	local activeRatio = Controllers.Config.MOBILE_TOUCH_ACTIVE_Y_RATIO or 0.5
	return input.Position.Y >= currentCamera.ViewportSize.Y * activeRatio
end

-- 根据手指相对起点的横向偏移刷新移动方向，死区内保持停止。
local function updateTouchDirection(input)
	local deadzone = Controllers.Config.MOBILE_TOUCH_DEADZONE or 20
	local deltaX = input.Position.X - touchStartX

	if math.abs(deltaX) < deadzone then
		touchMoveDirection = 0
	elseif deltaX < 0 then
		touchMoveDirection = -1
	else
		touchMoveDirection = 1
	end

	refreshMoveDirection()
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
	keyboardMoveDirection = dir
	if dir == 0 then
		clearTouchInput()
	else
		refreshMoveDirection()
	end
end

-- 绑定玩家的键盘按键输入
function PlayerController.SetupInput()
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		-- 如果在打字、非战斗状态、或者正在升级选卡时，剥夺玩家输入权
		if gameProcessed or not canUseCombatInput() then return end
		
		if input.KeyCode == Enum.KeyCode.A or input.KeyCode == Enum.KeyCode.Left then
			keyboardMoveDirection = -1
			refreshMoveDirection()
		elseif input.KeyCode == Enum.KeyCode.D or input.KeyCode == Enum.KeyCode.Right then
			keyboardMoveDirection = 1
			refreshMoveDirection()
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.A or input.KeyCode == Enum.KeyCode.Left then
			if keyboardMoveDirection == -1 then
				keyboardMoveDirection = 0
				refreshMoveDirection()
			end
		elseif input.KeyCode == Enum.KeyCode.D or input.KeyCode == Enum.KeyCode.Right then
			if keyboardMoveDirection == 1 then
				keyboardMoveDirection = 0
				refreshMoveDirection()
			end
		end
	end)

	UserInputService.TouchStarted:Connect(function(input, gameProcessed)
		if gameProcessed or activeTouchInput or not canUseCombatInput() or not isTouchInActiveArea(input) then return end

		activeTouchInput = input
		touchStartX = input.Position.X
		touchMoveDirection = 0
		refreshMoveDirection()
	end)

	UserInputService.TouchMoved:Connect(function(input, gameProcessed)
		if input ~= activeTouchInput then return end
		if gameProcessed or not canUseCombatInput() then
			clearTouchInput()
			return
		end

		updateTouchDirection(input)
	end)

	UserInputService.TouchEnded:Connect(function(input, gameProcessed)
		if input == activeTouchInput then
			clearTouchInput()
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
	if not rootPart or not humanoid or humanoid.Health <= 0 then
		clearAllMoveInput()
		return
	end

	-- ─── 阶段 A: 大厅状态 ───
	if not Controllers.Game.IsCombatActive then
		clearAllMoveInput()
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		humanoid.AutoRotate = true
		return 
	end

	-- ─── 阶段 B: 升级暂停状态 ───
	if player:GetAttribute("IsLevelingUp") then
		clearAllMoveInput()
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
	-- 横向移动速度支持局内属性门百分比加成，并用配置表的最大横移速度封顶。
	local lateralSpeedBonus = player:GetAttribute("LateralSpeed_Bonus") or 0
	local currentLateralSpeed = math.min(Config.LATERAL_SPEED * (1 + (lateralSpeedBonus / 100)), Config.MAX_LATERAL_SPEED or Config.LATERAL_SPEED)
	
	-- 计算最终想要移动的速度向量 (侧向移动 + 动态向前奔跑速度)
	local desiredVelocity = Vector3.new(effectiveMoveDirection * currentLateralSpeed, 0, -currentRunSpeed)
	humanoid.WalkSpeed = desiredVelocity.Magnitude
	humanoid:Move(desiredVelocity.Unit, false)
	
	-- 【核心修改】：相机接管，强制锁定 FOV 打造扁平化透视
	camera.CameraType = Enum.CameraType.Scriptable
	-- 强制应用配置表里的 FOV，屏蔽 Roblox 系统的默认 70
	camera.FieldOfView = Config.CAMERA_FOV or 35 
	local targetPos = rootPart.Position
	local camPos = targetPos + Config.CAMERA_OFFSET
	local lookAtPos = targetPos + Config.CAMERA_LOOK_OFFSET
	camera.CFrame = CFrame.lookAt(camPos, lookAtPos)
end

return PlayerController
