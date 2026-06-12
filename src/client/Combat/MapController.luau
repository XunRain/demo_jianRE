-- src/client/Combat/MapController.luau
-- 地图与跑道控制模块：负责跑道的无限拼接、地形生成以及内存清理
local MapController = {}

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- 引入服务
local Controllers -- 全局依赖指针
-- 获取美术做好的跑道模型模板
local roadTemplate = ReplicatedStorage:WaitForChild("Model", 10):WaitForChild("Road", 10)
-- 跑道坐标系状态
MapController.TrackStartX = 0          -- 跑道中心线的 X 坐标 (暴漏给其它模块用于限制玩家移动范围)
local trackStartY = 0                  -- 跑道模型 Pivot 的 Y 坐标；真实路面高度会用标记或配置偏移单独计算
local nextTrackZ = 0                   -- 下一块跑道需要拼接的 Z 坐标
local activeTracks = {}                -- 存储当前地图上存活的跑道板块 (包含地面和两侧墙壁的 Model/Part)

function MapController.Init(deps)
	Controllers = deps
end

-- 计算当前跑道块的真实路面高度；优先读取 Studio 标记，找不到时使用配置偏移兜底。
local function getTrackSurfaceY(block)
	local Config = Controllers.Config
	local yOffset = Config.RUNWAY_SURFACE_Y_OFFSET or 0
	local surfaceMarker = block:FindFirstChild("RunwaySurface", true) or block:FindFirstChild("RunwayBounds", true)

	if surfaceMarker then
		if surfaceMarker:IsA("Attachment") then
			return surfaceMarker.WorldPosition.Y + yOffset
		end

		if surfaceMarker:IsA("BasePart") then
			-- 如果标记是薄片 Part，就用上表面当作可站立路面高度。
			return surfaceMarker.Position.Y + (surfaceMarker.Size.Y / 2) + yOffset
		end
	end

	return trackStartY + yOffset
end

-- 【核心重构】：生成单块完整跑道 (直接使用美术模型)
function MapController.SpawnTrackBlock()
	local Config = Controllers.Config
	
	if not roadTemplate then
		warn("找不到跑道模型！请确认 ReplicatedStorage/Model/Road 是否存在。")
		return
	end
	
	-- 1. 直接克隆完整的场景模型
	local block = roadTemplate:Clone()
	
	-- 2. 设置模型位置 
	-- 假设美术将 Pivot (原点) 设置在了路面中心，我们将其对齐到当前的拼接坐标
	local targetCFrame = CFrame.new(
		MapController.TrackStartX, 
		trackStartY, 
		nextTrackZ - (Config.TRACK_LENGTH / 2)
	)
	block:PivotTo(targetCFrame)
	
	local trackFolder = Workspace:FindFirstChild("LocalTrack") or Instance.new("Folder", Workspace)
	trackFolder.Name = "LocalTrack"
	block.Parent = trackFolder
	
	-- 3. 记录到活跃数组中，用于后续的销毁判定
	table.insert(activeTracks, block)
	
	-- 4. 联动生成：通知 EncounterController 在上面撒怪和门
	local blockStartZ = nextTrackZ
	local blockEndZ = nextTrackZ - Config.TRACK_LENGTH
	local trackSurfaceY = getTrackSurfaceY(block)
	Controllers.Encounter.SpawnEncountersInBlock(blockStartZ, blockEndZ, MapController.TrackStartX, trackSurfaceY)
	
	-- 5. 推进指针，为下一块地板做准备
	nextTrackZ = blockEndZ
end

-- 清空场上所有的跑道 (用于玩家死亡后重置游戏环境)
function MapController.ClearTracks()
	for _, track in ipairs(activeTracks) do
		if track then track:Destroy() end
	end
	activeTracks = {}
end

-- 游戏开局初始化：计算跑道原点，并瞬间铺满视野
function MapController.ResetTrack(startPartCFrame)
	local Config = Controllers.Config
	
	-- 先清理上一局的遗留跑道
	MapController.ClearTracks()
	
	-- 玩家从 StartButton 往前 5 格处作为起跑基准点
	local startPos = (startPartCFrame * CFrame.new(0, 0, -1)).Position
	MapController.TrackStartX = startPos.X
	trackStartY = startPos.Y
	nextTrackZ = startPos.Z
	
	-- 必须先通知 EncounterController 初始化它自己的刷怪指针，否则怪的位置会错乱
	Controllers.Encounter.ResetPointers(startPos.Z)
	
	-- 开局瞬间生成足够的跑道铺满前方视野，防止玩家看到虚空
	local initialBlocksNeeded = math.ceil(Config.SPAWN_AHEAD / Config.TRACK_LENGTH) + 1
	for i = 1, initialBlocksNeeded do
		MapController.SpawnTrackBlock()
		-- 初始铺路包含模型克隆和遭遇生成，分帧执行可以避免踩 START 后客户端明显卡住。
		if i < initialBlocksNeeded then
			task.wait()
		end
	end
end

-- 玩家奔跑时，动态拼接前方跑道，并销毁身后的过期跑道
function MapController.UpdateTrack(playerZ)
	local Config = Controllers.Config
	
	-- 1. 生成判定：如果前方跑道不足，则拼一块新的
	if playerZ - Config.SPAWN_AHEAD < nextTrackZ then
		MapController.SpawnTrackBlock()
	end
	
	-- 2. 销毁判定：倒序遍历销毁
	for i = #activeTracks, 1, -1 do
		local track = activeTracks[i]
		if track then
			-- =======================================================
			-- 【核心修复】：判断 track 是 Model 还是 Part，安全获取它的中心 Z 坐标
			-- =======================================================
			local trackZ = track:IsA("Model") and track:GetPivot().Position.Z or track.Position.Z
			local frontEdgeZ = trackZ - (Config.TRACK_LENGTH / 2)
			
			-- 如果这块跑道的最前端 都已经被玩家甩在身后超过 CLEANUP_BEHIND 的距离，说明玩家彻底看不见它了
			if frontEdgeZ > playerZ + Config.CLEANUP_BEHIND then
				track:Destroy()
				table.remove(activeTracks, i)
			end
		end
	end
end

return MapController
