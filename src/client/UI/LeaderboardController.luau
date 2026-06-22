-- src/client/UI/LeaderboardController.luau
-- 全服排行榜展示控制器：寻找 Studio 展示板，把全服历史最高米数榜单渲染到 SurfaceGui。
local LeaderboardController = {}

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local Controllers
local thumbnailCache = {}
local lastLeaderboardSnapshot = nil

local function applyRankStyle(row, rank)
	if not row or not row:IsA("GuiObject") then return end

	local backgroundNode = nil
	for _, name in ipairs({
		"Background",
		"RowBackground",
		"Bg",
		"BG",
		"BackgroundImage",
	}) do
		backgroundNode = row:FindFirstChild(name, true)
		if backgroundNode then break end
	end

	local gradientRoot = (backgroundNode and backgroundNode:IsA("GuiObject")) and backgroundNode or row
	for index = 1, 3 do
		local gradient = gradientRoot:FindFirstChild("UIGradient" .. tostring(index), true)
		if gradient and gradient:IsA("UIGradient") then
			gradient.Enabled = rank == index
		end
	end

	if rank and rank <= 3 then
		if backgroundNode and backgroundNode:IsA("GuiObject") then
			row.BackgroundTransparency = 1
			backgroundNode.BackgroundTransparency = 0
			backgroundNode.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			if backgroundNode:IsA("ImageLabel") or backgroundNode:IsA("ImageButton") then
				backgroundNode.ImageColor3 = Color3.fromRGB(255, 255, 255)
			end
		else
			row.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			row.BackgroundTransparency = 0
		end
	elseif backgroundNode and backgroundNode:IsA("GuiObject") then
		row.BackgroundTransparency = 1
		backgroundNode.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		backgroundNode.BackgroundTransparency = 0
	else
		row.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		row.BackgroundTransparency = 0
	end
end

function LeaderboardController.Init(deps)
	Controllers = deps
end

-- 获取排行榜配置；展示板名称、刷新频率、显示人数都从配置表读取。
local function getLeaderboardConfig()
	return Controllers.Config.LEADERBOARD or {
		BoardName = "LeaderboardBoard",
		TopCount = 10,
		RefreshInterval = 5,
	}
end

-- 在展示板或 SurfaceGui 内递归寻找指定名字的 UI 节点。
local function findDescendantByNames(root, names)
	if not root then return nil end
	for _, name in ipairs(names) do
		local found = root:FindFirstChild(name, true)
		if found then return found end
	end
	return nil
end

-- 查找 Studio 中放置的排行榜展示板，默认名称是 LeaderboardBoard。
local function findBoard()
	local config = getLeaderboardConfig()
	local boardName = config.BoardName or "LeaderboardBoard"

	local directBoard = Workspace:FindFirstChild(boardName)
	if directBoard then
		return directBoard
	end

	local nestedBoard = Workspace:FindFirstChild(boardName, true)
	if nestedBoard then
		return nestedBoard
	end

	-- 如果模型名暂时没找到，但 SurfaceGui 已经复制到客户端，也可以直接绑定这个 SurfaceGui。
	return Workspace:FindFirstChild("LeaderboardSurfaceGui", true)
end

-- 确保展示板上有 SurfaceGui；如果 Studio 已经放好，就直接复用。
local function getOrCreateSurfaceGui(board)
	if not board then return nil end
	if board:IsA("SurfaceGui") then return board end

	local surfaceGui = board:FindFirstChildWhichIsA("SurfaceGui", true)
	if surfaceGui then return surfaceGui end

	local targetPart = board:IsA("BasePart") and board or board:FindFirstChildWhichIsA("BasePart", true)
	if not targetPart then return nil end

	surfaceGui = Instance.new("SurfaceGui")
	surfaceGui.Name = "LeaderboardSurfaceGui"
	surfaceGui.Face = Enum.NormalId.Front
	surfaceGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surfaceGui.PixelsPerStud = 50
	surfaceGui.Parent = targetPart
	return surfaceGui
end

-- 创建一个简单的兜底 TextLabel，只有展示板没有 Studio 模板时才会用到。
local function createText(parent, name, text, size, position, color, align)
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = color or Color3.fromRGB(255, 255, 255)
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.TextXAlignment = align or Enum.TextXAlignment.Left
	label.Size = size
	label.Position = position
	label.Parent = parent
	return label
end

-- 创建一个简单的兜底排行榜行模板；你在 Studio 做 RowTemplate 后，代码会优先使用 Studio 模板。
local function createFallbackRow(parent, name, visible)
	local row = Instance.new("Frame")
	row.Name = name
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 42)
	row.Visible = visible
	row.Parent = parent

	local avatar = Instance.new("ImageLabel")
	avatar.Name = "Avatar"
	avatar.BackgroundTransparency = 1
	avatar.Size = UDim2.new(0, 34, 0, 34)
	avatar.Position = UDim2.new(0, 6, 0.5, -17)
	avatar.Parent = row

	createText(row, "RankText", "1.", UDim2.new(0, 42, 1, 0), UDim2.new(0, 44, 0, 0), Color3.fromRGB(255, 238, 120), Enum.TextXAlignment.Left)
	createText(row, "NameText", "Player", UDim2.new(0.48, 0, 1, 0), UDim2.new(0, 88, 0, 0), Color3.fromRGB(255, 255, 255), Enum.TextXAlignment.Left)
	createText(row, "DistanceText", "0 METERS", UDim2.new(0.32, -8, 1, 0), UDim2.new(0.68, 0, 0, 0), Color3.fromRGB(110, 255, 255), Enum.TextXAlignment.Right)

	return row
end

-- 展示板没有完整 UI 时，自动创建一个可用兜底布局，方便先跑通功能。
local function ensureFallbackLayout(surfaceGui)
	local root = surfaceGui:FindFirstChild("Root")
	if root then return root end

	local hasStudioLayout = findDescendantByNames(surfaceGui, {"List", "Rows", "Content", "RankList"})
		or findDescendantByNames(surfaceGui, {"RowTemplate", "ItemTemplate", "PlayerRowTemplate"})
		or findDescendantByNames(surfaceGui, {"SelfRow", "MyRow", "PlayerSelfRow"})
	if hasStudioLayout then
		return surfaceGui
	end

	root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundColor3 = Color3.fromRGB(18, 26, 34)
	root.BackgroundTransparency = 0.15
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = surfaceGui

	createText(root, "Title", "Global Leaderboard", UDim2.new(1, -24, 0, 52), UDim2.new(0, 12, 0, 8), Color3.fromRGB(255, 255, 255), Enum.TextXAlignment.Center)

	local list = Instance.new("Frame")
	list.Name = "List"
	list.BackgroundTransparency = 1
	list.Size = UDim2.new(1, -24, 1, -132)
	list.Position = UDim2.new(0, 12, 0, 64)
	list.Parent = root

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = list

	createFallbackRow(list, "RowTemplate", false)

	local selfRow = createFallbackRow(root, "SelfRow", true)
	selfRow.BackgroundTransparency = 0.25
	selfRow.BackgroundColor3 = Color3.fromRGB(70, 92, 88)
	selfRow.Size = UDim2.new(1, -24, 0, 48)
	selfRow.Position = UDim2.new(0, 12, 1, -56)

	return root
end

-- 获取玩家头像 URL，并做本地缓存，避免每次刷新都重复请求头像。
local function getThumbnail(userId)
	if not userId then return "" end
	if thumbnailCache[userId] then
		return thumbnailCache[userId]
	end

	local success, content = pcall(function()
		return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
	end)
	if success and content then
		thumbnailCache[userId] = content
		return content
	end
	return ""
end

-- 设置排行榜行内某个文字节点；兼容不同 Studio 命名。
local function setText(row, names, text)
	local label = findDescendantByNames(row, names)
	if label and (label:IsA("TextLabel") or label:IsA("TextButton")) then
		label.Text = text
	end
end

-- 设置排行榜行内头像节点；兼容 Avatar、HeadIcon、Icon 等常见命名。
local function setAvatar(row, userId)
	local image = findDescendantByNames(row, {"Avatar", "HeadIcon", "Icon", "AvatarImage", "PlayerIcon"})
	if image and image:IsA("ImageLabel") then
		image.Image = getThumbnail(userId)
	end
end

-- 填充单行排行榜数据：排名、头像、名字、最高米数。
local function fillRow(row, entry)
	local rankText = entry.RankText or tostring(entry.Rank or "-")
	local distance = tonumber(entry.Distance) or 0
	local rankDisplay = entry.Rank and (rankText .. ".") or rankText

	applyRankStyle(row, tonumber(entry.Rank))
	setText(row, {"RankText", "Rank", "RankLabel"}, rankDisplay)
	setText(row, {"NameText", "PlayerName", "NameLabel", "Name"}, entry.Name or "Player")
	setText(row, {"DistanceText", "BestDistance", "DistanceLabel", "ScoreText", "Score"}, Controllers.Config.FormatNumber(distance) .. " METERS")
	setAvatar(row, entry.UserId or player.UserId)
end

-- 从服务端请求全服排行榜快照；失败时沿用上一份快照或显示自己的本地数据。
local function getLeaderboardSnapshot()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local getGlobalLeaderboard = remotes and remotes:FindFirstChild("GetGlobalLeaderboard")
	if getGlobalLeaderboard and getGlobalLeaderboard:IsA("RemoteFunction") then
		local success, snapshot = pcall(function()
			return getGlobalLeaderboard:InvokeServer()
		end)

		if success and type(snapshot) == "table" then
			lastLeaderboardSnapshot = snapshot
			return snapshot
		end

		warn("[LeaderboardController] Failed to fetch global leaderboard:", snapshot)
	end

	if lastLeaderboardSnapshot then
		return lastLeaderboardSnapshot
	end

	local localBest = math.max(player:GetAttribute("BestDistance") or 0, player:GetAttribute("CurrentDistance") or 0)
	return {
		Top = {},
		Self = {
			Rank = nil,
			RankText = "-",
			UserId = player.UserId,
			Name = player.Name,
			Distance = localBest,
		},
		Mode = "Global",
		UpdatedAt = os.time(),
	}
end

-- 获取或创建指定名次的排行行；刷新时复用旧行，避免 Destroy/Clone 导致展示板闪烁。
local function getOrCreateRow(list, rowTemplate, rank)
	local rowName = "LeaderboardRow_" .. tostring(rank)
	local row = list:FindFirstChild(rowName)
	if row then
		return row
	end

	row = rowTemplate:Clone()
	row.Name = rowName
	row:SetAttribute("LeaderboardGenerated", true)
	row.Parent = list
	return row
end

-- 隐藏本轮没有用到的旧排行行，保留实例以便下次复用。
local function hideUnusedRows(list, usedCount)
	for _, child in ipairs(list:GetChildren()) do
		if child:GetAttribute("LeaderboardGenerated") then
			local rank = tonumber(string.match(child.Name, "^LeaderboardRow_(%d+)$"))
			if rank and rank > usedCount then
				child.Visible = false
			end
		end
	end
end

-- 刷新展示板排行列表与底部自己的数据。
local function renderLeaderboard(surfaceGui)
	local root = ensureFallbackLayout(surfaceGui)
	local list = findDescendantByNames(root, {"List", "Rows", "Content", "RankList"})
	local rowTemplate = findDescendantByNames(root, {"RowTemplate", "ItemTemplate", "PlayerRowTemplate"})
	local selfRow = findDescendantByNames(root, {"SelfRow", "MyRow", "PlayerSelfRow"})
	if not list or not rowTemplate then return end

	rowTemplate.Visible = false

	local config = getLeaderboardConfig()
	local topCount = config.TopCount or 10
	local snapshot = getLeaderboardSnapshot()
	local entries = snapshot.Top or {}
	local usedCount = math.min(topCount, #entries)

	for rank, entry in ipairs(entries) do
		if rank > topCount then break end
		local row = getOrCreateRow(list, rowTemplate, rank)
		row.LayoutOrder = rank
		row.Visible = true
		fillRow(row, entry)
	end
	hideUnusedRows(list, usedCount)

	if selfRow then
		selfRow.Visible = true
		fillRow(selfRow, snapshot.Self or {
			RankText = "-",
			UserId = player.UserId,
			Name = player.Name,
			Distance = player:GetAttribute("BestDistance") or 0,
		})
	end
end

function LeaderboardController.Start()
	task.spawn(function()
		local warnedMissingBoard = false
		local missingSince = nil
		while true do
			local config = getLeaderboardConfig()
			local board = findBoard()
			local surfaceGui = getOrCreateSurfaceGui(board)
			if surfaceGui then
				warnedMissingBoard = false
				missingSince = nil
				renderLeaderboard(surfaceGui)
			else
				-- 展示板可能因为 Streaming/复制时序稍晚才出现在客户端，延迟一段时间后仍找不到才提示。
				missingSince = missingSince or os.clock()
				local warnDelay = config.MissingWarnDelay or 5
				if not warnedMissingBoard and (os.clock() - missingSince) >= warnDelay then
					warn("[LeaderboardController] Leaderboard board not found. Confirm LeaderboardBoard is in Workspace, or that a LeaderboardSurfaceGui exists; if Streaming is enabled, make sure the board is client-visible.")
					warnedMissingBoard = true
				end
			end

			task.wait(config.RefreshInterval or 5)
		end
	end)
end

return LeaderboardController
