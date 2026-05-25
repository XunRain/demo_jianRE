-- src/client/Combat/MapController.luau
-- 地图与跑道控制模块：负责跑道的无限拼接、地形生成以及内存清理
local MapController = {}

local Workspace = game:GetService("Workspace")
local Controllers -- 全局依赖指针

-- 跑道坐标系状态
MapController.TrackStartX = 0          -- 跑道中心线的 X 坐标 (暴漏给其它模块用于限制玩家移动范围)
local trackStartY = 0                  -- 跑道地面的 Y 坐标
local nextTrackZ = 0                   -- 下一块跑道需要拼接的 Z 坐标
local activeTracks = {}                -- 存储当前地图上存活的跑道板块 (包含地面和两侧墙壁的 Model/Part)

function MapController.Init(deps)
	Controllers = deps
end

-- 生成单块完整跑道 (包含地面和两侧防穿帮的墙壁)
function MapController.SpawnTrackBlock()
	local Config = Controllers.Config
	
	-- 1. 生成地面
	local block = Instance.new("Part")
	local floorWidth = Config.RUNWAY_LIMIT * 2 + 10 -- 跑道宽度比实际移动限制稍微宽一点
	block.Size = Vector3.new(floorWidth, Config.TRACK_THICKNESS, Config.TRACK_LENGTH)
	block.Anchored = true
	block.CanCollide = true
	block.Color = Color3.fromRGB(230, 230, 230)
	block.Material = Enum.Material.SmoothPlastic 
	block.CFrame = CFrame.new(MapController.TrackStartX, trackStartY - (Config.TRACK_THICKNESS / 2), nextTrackZ - (Config.TRACK_LENGTH / 2))
	
	local trackFolder = Workspace:FindFirstChild("LocalTrack") or Instance.new("Folder", Workspace)
	trackFolder.Name = "LocalTrack"
	block.Parent = trackFolder
	
	-- 2. 生成左侧护墙 (河岸)
	local floorHalfWidth = floorWidth / 2
	local leftBank = Instance.new("Part")
	leftBank.Size = Vector3.new(Config.BANK_WIDTH, Config.BANK_HEIGHT, Config.TRACK_LENGTH)
	leftBank.Anchored = true
	leftBank.CanCollide = true
	leftBank.Color = Color3.fromRGB(150, 150, 150) 
	leftBank.Material = Enum.Material.SmoothPlastic
	leftBank.CFrame = block.CFrame * CFrame.new(-floorHalfWidth - (Config.BANK_WIDTH / 2), Config.BANK_HEIGHT / 2, 0)
	leftBank.Parent = block -- 作为地面的子节点，方便一起销毁

	-- 3. 生成右侧护墙 (河岸)
	local rightBank = Instance.new("Part")
	rightBank.Size = Vector3.new(Config.BANK_WIDTH, Config.BANK_HEIGHT, Config.TRACK_LENGTH)
	rightBank.Anchored = true
	rightBank.CanCollide = true
	rightBank.Color = Color3.fromRGB(150, 150, 150)
	rightBank.Material = Enum.Material.SmoothPlastic
	rightBank.CFrame = block.CFrame * CFrame.new(floorHalfWidth + (Config.BANK_WIDTH / 2), Config.BANK_HEIGHT / 2, 0)
	rightBank.Parent = block
	
	-- 记录到活跃数组中，用于后续的销毁判定
	table.insert(activeTracks, block)
	
	-- 4. 联动生成：计算出这块新地板在世界坐标里的 Z 轴范围，并通知 EncounterController 在上面撒怪和门
	local blockStartZ = nextTrackZ
	local blockEndZ = nextTrackZ - Config.TRACK_LENGTH
	Controllers.Encounter.SpawnEncountersInBlock(blockStartZ, blockEndZ, MapController.TrackStartX, trackStartY)
	
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
	local startPos = (startPartCFrame * CFrame.new(0, 0, -5)).Position
	MapController.TrackStartX = startPos.X
	trackStartY = startPos.Y
	nextTrackZ = startPos.Z
	
	-- 必须先通知 EncounterController 初始化它自己的刷怪指针，否则怪的位置会错乱
	Controllers.Encounter.ResetPointers(startPos.Z)
	
	-- 开局瞬间生成足够的跑道铺满前方视野，防止玩家看到虚空
	local initialBlocksNeeded = math.ceil(Config.SPAWN_AHEAD / Config.TRACK_LENGTH) + 1
	for i = 1, initialBlocksNeeded do
		MapController.SpawnTrackBlock()
	end
end

-- 玩家奔跑时，动态拼接前方跑道，并销毁身后的过期跑道 (由 PlayerController 的主循环调用)
function MapController.UpdateTrack(playerZ)
	local Config = Controllers.Config
	
	-- 1. 生成判定：如果前方跑道不足，则拼一块新的
	if playerZ - Config.SPAWN_AHEAD < nextTrackZ then
		MapController.SpawnTrackBlock()
	end
	
	-- 2. 销毁判定：倒序遍历销毁，防止 table 索引错乱
	for i = #activeTracks, 1, -1 do
		local track = activeTracks[i]
		if track then
			-- 获取跑道板块最前端的 Z 坐标 (因为 Z 轴是负向延伸的)
			local frontEdgeZ = track.Position.Z - (Config.TRACK_LENGTH / 2)
			
			-- 如果这块跑道的最前端 都已经被玩家甩在身后超过 CLEANUP_BEHIND 的距离，说明玩家彻底看不见它了
			if frontEdgeZ > playerZ + Config.CLEANUP_BEHIND then
				track:Destroy()
				table.remove(activeTracks, i)
			end
		end
	end
end

return MapController