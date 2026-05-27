-- src/client/Configs/GameConfig.luau
-- 全局游戏数值配置中心
-- 方便后续添加局外养成系统时，统一修改初始属性

local GameConfig = {
    -- 1. 物理与移动控制
    RUN_SPEED = 20,           -- 跑酷基础速度
    RUN_SPEED_INCREMENT = 2,  -- 每过一关，移速增加 2 点
    LATERAL_SPEED = 20,       -- 左右移动速度
    RUNWAY_LIMIT = 20,        -- 跑道左右边界宽度限制

    -- 2. 战斗参数
    BULLET_SPEED = 100,       -- 子弹飞行速度
    BULLET_LIFETIME = 1,    -- 子弹存活时间

    -- 3. 镜头配置
	-- 正常镜头
    -- CAMERA_OFFSET = Vector3.new(0, 6, 15),
    -- CAMERA_LOOK_OFFSET = Vector3.new(0, 2, -15),

	-- 高空无人机镜头
	-- CAMERA_OFFSET = Vector3.new(0, 48, 10),
    -- CAMERA_LOOK_OFFSET = Vector3.new(0, 10, -20),

    CAMERA_OFFSET = Vector3.new(0, 20, 10),
    CAMERA_LOOK_OFFSET = Vector3.new(0, 4, -10),

    -- 4. 地图与跑道生成配置
    TRACK_LENGTH = 120,       -- 单块跑道长度
    TRACK_THICKNESS = 2,      -- 跑道厚度
    SPAWN_AHEAD = 600,        -- 提前生成距离
    CLEANUP_BEHIND = 100,     -- 销毁距离
    BANK_WIDTH = 15,          -- 侧墙宽度
    BANK_HEIGHT = 20,         -- 侧墙高度

    -- 5. 初始角色状态 (未来可在此处对接局外养成数据)
    BASE_HP = 100,
    BASE_ATK = 10,
    BASE_ASPD = 2,            -- 每秒发射次数
    BASE_LEVEL = 1,
    BASE_EXP = 0,
    EXP_PER_LEVEL = 20,       -- 升级经验倍率 (每一级所需经验 = 当前等级 * EXP_PER_LEVEL)

-- 6. 关卡(Stage)与遭遇配置中心 (前5关爽感割草期)
    STAGES = {
        [1] = {
            Length = 1200,           
            GateInterval = 150,      
            MobInterval = 100,       
            MobsPerGroup = {2, 3},   
            EliteCount = 1,          
            HasBoss = true,          
            
            BasicHP = 20,            
            EliteHP = 100,           
            BossHP = 300,            

            GATE_HP_MIN = 10,  GATE_HP_MAX = 20,
            GATE_ATK_MIN = 1,  GATE_ATK_MAX = 3,
            GATE_ASPD_MIN = 0.1, GATE_ASPD_MAX = 0.3,

            GateBuffChance = 1.0, -- 100% 绿门，绝对不卡关
        },
        [2] = {
            Length = 1400,          
            GateInterval = 120,     
            MobInterval = 80,       
            MobsPerGroup = {3, 4},  
            EliteCount = 2,         
            HasBoss = true,          
            
            BasicHP = 35,            
            EliteHP = 200,          
            BossHP = 600,          

            GATE_HP_MIN = 15,  GATE_HP_MAX = 30,
            GATE_ATK_MIN = 2,  GATE_ATK_MAX = 4,
            GATE_ASPD_MIN = 0.2, GATE_ASPD_MAX = 0.4,

            GateBuffChance = 1.0, -- 100% 绿门
        },
        [3] = {
            Length = 1600,          
            GateInterval = 100,     
            MobInterval = 70,       
            MobsPerGroup = {4, 5},  
            EliteCount = 2,         
            HasBoss = true,          
            
            BasicHP = 60,          
            EliteHP = 300,          
            BossHP = 900,          

            GATE_HP_MIN = 20,  GATE_HP_MAX = 40,
            GATE_ATK_MIN = 3,  GATE_ATK_MAX = 5,
            GATE_ASPD_MIN = 0.2, GATE_ASPD_MAX = 0.5,

            GateBuffChance = 1.0, -- 100% 绿门
        },
        [4] = {
            Length = 1800,          
            GateInterval = 100,     
            MobInterval = 60,       
            MobsPerGroup = {4, 6},  
            EliteCount = 3,         
            HasBoss = true,          
            
            BasicHP = 100,          
            EliteHP = 600,          
            BossHP = 1800,          

            GATE_HP_MIN = 30,  GATE_HP_MAX = 50,
            GATE_ATK_MIN = 4,  GATE_ATK_MAX = 7,
            GATE_ASPD_MIN = 0.3, GATE_ASPD_MAX = 0.6,

            GateBuffChance = 1.0, -- 100% 绿门
        },
        [5] = {
            Length = 2000,          
            GateInterval = 90,     
            MobInterval = 50,       
            MobsPerGroup = {5, 7},  
            EliteCount = 3,         
            HasBoss = true,          
            
            -- 第 5 关作为无尽模式的基底，怪群非常密集
            BasicHP = 160,          
            EliteHP = 900,          
            BossHP = 4000,          

            GATE_HP_MIN = 40,  GATE_HP_MAX = 60,
            GATE_ATK_MIN = 5,  GATE_ATK_MAX = 8,
            GATE_ASPD_MIN = 0.3, GATE_ASPD_MAX = 0.8,

            GateBuffChance = 0.5, -- 50% 绿门
        }
    },

    -- 7. 无尽模式难度动态成长配置
    ENEMY_HP_SCALE_DIST = 1000, -- 玩家每跑 1000 米
    ENEMY_HP_SCALE_RATE = 0.5,  -- 怪物血量额外增加 30%（乘区） 

    -- 8. 属性门数值范围 (已废弃，可删可留)
    -- GATE_HP_MIN = 10, GATE_HP_MAX = 50,
    -- GATE_ATK_MIN = 1, GATE_ATK_MAX = 5,
    -- GATE_ASPD_MIN = 1, GATE_ASPD_MAX = 2,

    -- 9. 掉落物与磁吸机制
    MAGNET_RADIUS = 15,       
    COLLECT_RADIUS = 5,       
    MAGNET_SPEED = 75,        

    -- ==========================================
    -- 10. 局外天赋商店配置 (清理测试数据，回归正式数值)
    -- ==========================================
	TALENTS = {
		Talent_HP = {
			Name = "血量强化",
			BaseCost = 50,       
			CostMulti = 1.5,     
			StatIncrease = 20,   
		},
		Talent_ATK = {
			Name = "攻击强化",
			BaseCost = 100,
			CostMulti = 2.0,
			StatIncrease = 5,    
		},
		Talent_ASPD = {
			Name = "攻速强化",
			BaseCost = 150,
			CostMulti = 2.5,
			StatIncrease = 0.15, 
		}
	},

    -- ==========================================
    -- 11. 宠物与抽卡系统配置
    -- ==========================================
    -- 一局第一关打通大概能获得 150~200 金币。
    -- 定价 200 保证玩家死一两次后，必定能抽第一只宠物！
	PET_GACHA_COST = 200, 
	
	PETS = {
		["Slime"] = { 
			Name = "风精灵", 
			Rarity = "普通", 
			ATK = 10,      -- 增强普通宠物，让玩家抽到就能质变度过前期
			ASPD = 1.2,   
			Color = Color3.fromRGB(150, 255, 150) 
		},
		["Dragon"] = { 
			Name = "小火龙", 
			Rarity = "稀有", 
			ATK = 25, 
			ASPD = 1.5, 
			Color = Color3.fromRGB(255, 100, 100) 
		},
		["Angel"] = { 
			Name = "大天使", 
			Rarity = "史诗", 
			ATK = 60, 
			ASPD = 2.5, 
			Color = Color3.fromRGB(255, 215, 0) 
		}
	},
	
	-- 简易抽卡权重池 (普通概率高，史诗概率低)
	PET_POOL = {
		"Slime", "Slime", "Slime", "Slime", "Slime",
		"Dragon", "Dragon", "Dragon",
		"Angel"
	}
    
}

-- 商品计算价格方法，全局共享
function GameConfig.GetTalentCost(talentId, currentLevel)
	local talent = GameConfig.TALENTS[talentId]
	if not talent then return math.huge end -- 如果查不到配置，返回无限大价格防止被刷
	
	-- 计算公式：基础价格 * (乘数 ^ 当前等级)
	return math.floor(talent.BaseCost * (talent.CostMulti ^ currentLevel))
end

-- 动态获取指定关卡的前进速度 (基础速度 + 随关卡递增)
function GameConfig.GetRunSpeed(stageNum)
	-- 公式：基础速度 25 + (当前关卡数 - 1) * 每关增加的速度 2
	local currentSpeed = GameConfig.RUN_SPEED + (stageNum - 1) * GameConfig.RUN_SPEED_INCREMENT
	
	-- 可选：加上一个绝对速度上限，防止玩家跑到 20 关时速度达到 60 直接瞬移穿墙
	-- 如果不需要上限，直接 return currentSpeed 即可
	local MAX_SPEED = 45 
	if currentSpeed > MAX_SPEED then currentSpeed = MAX_SPEED end
	
	return currentSpeed
end

return GameConfig