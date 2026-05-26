-- src/client/init.client.luau
-- 客户端启动入口：负责加载模块、初始化依赖关系并启动主逻辑

print("Initializing Client Architecture...")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

-- 1. 定义模块路径表
local Controllers = {
    -- 配置层
    Config      = require(Shared:WaitForChild("Configs"):WaitForChild("GameConfig")),
    
    -- 核心逻辑层
    Game        = require(script.Core:WaitForChild("GameController")),
    Player      = require(script.Core:WaitForChild("PlayerController")),
    Progression = require(script.Core:WaitForChild("ProgressionController")),
	Pet 		= require(script.Core:WaitForChild("PetController")),
    
    -- 战斗与场景层
    Combat      = require(script.Combat:WaitForChild("CombatController")),
    Map         = require(script.Combat:WaitForChild("MapController")),
    Encounter   = require(script.Combat:WaitForChild("EncounterController")),
    
    -- UI与视觉表现层
    UI          = require(script.UI:WaitForChild("UIController")),
    VFX         = require(script.UI:WaitForChild("VFXController")),
}

-- 2. 第一阶段：Init 注入
-- 将整个 Controllers 表传递给每个模块，让模块之间可以互相调用，解决循环依赖问题
for name, controller in pairs(Controllers) do
    if type(controller.Init) == "function" then
        controller.Init(Controllers)
        print("Initialized Module: " .. name)
    end
end

-- 3. 第二阶段：Start 启动
-- 完成注入后，依次启动所有模块的 Start 函数，开始运行逻辑
for name, controller in pairs(Controllers) do
    if type(controller.Start) == "function" then
        task.spawn(function()
            controller.Start()
            print("Started Module: " .. name)
        end)
    end
end

print("Client Architecture Ready!")