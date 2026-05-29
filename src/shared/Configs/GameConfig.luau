-- src/client/Configs/GameConfig.luau
-- 全局游戏数值配置中心
-- 方便后续添加局外养成系统时，统一修改初始属性

local GameConfig = {
    -- 1. 物理与移动控制
    RUN_SPEED = 30,           -- 跑酷基础速度
    RUN_SPEED_INCREMENT = 4,  -- 每过一关，移速增加 2 点
    LATERAL_SPEED = 25,       -- 左右移动速度
    RUNWAY_LIMIT = 20,        -- 跑道左右边界宽度限制

    -- 2. 镜头配置
	-- 正常镜头
    -- CAMERA_OFFSET = Vector3.new(0, 6, 15),
    -- CAMERA_LOOK_OFFSET = Vector3.new(0, 2, -15),

	-- 高空无人机镜头
    CAMERA_OFFSET = Vector3.new(0, 20, 10),
    CAMERA_LOOK_OFFSET = Vector3.new(0, 4, -10),

    -- 3. 地图与跑道生成配置
    TRACK_LENGTH = 120,       -- 单块跑道长度
    TRACK_THICKNESS = 2,      -- 跑道厚度
    SPAWN_AHEAD = 600,        -- 提前生成距离
    CLEANUP_BEHIND = 100,     -- 销毁距离
    BANK_WIDTH = 15,          -- 侧墙宽度
    BANK_HEIGHT = 20,         -- 侧墙高度

    -- 4. 初始角色状态 (未来可在此处对接局外养成数据)
    BASE_HP = 100,
    BASE_ATK = 10,
    BASE_ASPD = 1.5,            -- 每秒发射次数
    BASE_LEVEL = 1,
    BASE_EXP = 0,
    EXP_PER_LEVEL = 20,       -- 升级经验倍率 (每一级所需经验 = 当前等级 * EXP_PER_LEVEL)
    BASE_SPD = 80,           -- 初始子弹飞行速度
    BASE_RNG = 100,           -- 初始子弹射程(存活时间)
    BASE_MULTISHOT = 1,       -- 初始弹道数量 (默认1发)

    -- 5. 关卡(Stage)与遭遇配置中心 (前5关爽感割草期)
    STAGES = {
        [1] = {
            Length = 1000,
            GateInterval = 150,      
            MobInterval = 100,       
            MobsPerGroup = {2, 3},
            EliteCount = 1,          
            HasBoss = true,          
            
            BasicHP = 20,
            EliteHP = 40,
            BossHP = 80,

            -- 将原本的固定数值，改为百分比加成数值 (5~15 代表 5% ~ 15%)
            GATE_ATK_BONUS_MIN = 5,  GATE_ATK_BONUS_MAX = 15,
            GATE_ASPD_BONUS_MIN = 5, GATE_ASPD_BONUS_MAX = 15,
            GATE_HP_BONUS_MIN = 10,  GATE_HP_BONUS_MAX = 30,    -- 恢复或扣除 10%~30% 最大生命
            GATE_MAXHP_BONUS_MIN = 5, GATE_MAXHP_BONUS_MAX = 15, -- 提升或降低 5%~15% 最大生命上限
            GATE_SPD_BONUS_MIN = 5,  GATE_SPD_BONUS_MAX = 20,   -- 弹速加成 %
            GATE_RNG_BONUS_MIN = 5,  GATE_RNG_BONUS_MAX = 20,   -- 射程加成 %

            GateBuffChance = 0.9,
        },
        [2] = {
            Length = 1000,          
            GateInterval = 120,     
            MobInterval = 80,       
            MobsPerGroup = {3, 4},  
            EliteCount = 2,         
            HasBoss = true,          
            
            BasicHP = 40,            
            EliteHP = 120,          
            BossHP = 240,          

            GATE_ATK_BONUS_MIN = 5,  GATE_ATK_BONUS_MAX = 15,
            GATE_ASPD_BONUS_MIN = 5, GATE_ASPD_BONUS_MAX = 15,
            GATE_HP_BONUS_MIN = 10,  GATE_HP_BONUS_MAX = 30,    -- 恢复或扣除 10%~30% 最大生命
            GATE_MAXHP_BONUS_MIN = 5, GATE_MAXHP_BONUS_MAX = 15, -- 提升或降低 5%~15% 最大生命上限
            GATE_SPD_BONUS_MIN = 5,  GATE_SPD_BONUS_MAX = 20,   -- 弹速加成 %
            GATE_RNG_BONUS_MIN = 5,  GATE_RNG_BONUS_MAX = 20,   -- 射程加成 %
            

            GateBuffChance = 0.6,
        },
        [3] = {
            Length = 1000,          
            GateInterval = 100,     
            MobInterval = 70,       
            MobsPerGroup = {4, 5},  
            EliteCount = 2,         
            HasBoss = true,          
            
            BasicHP = 50,          
            EliteHP = 100,          
            BossHP = 200,          

            GATE_ATK_BONUS_MIN = 10,  GATE_ATK_BONUS_MAX = 15,
            GATE_ASPD_BONUS_MIN = 10, GATE_ASPD_BONUS_MAX = 15,
            GATE_HP_BONUS_MIN = 10,  GATE_HP_BONUS_MAX = 30,    -- 恢复或扣除 10%~30% 最大生命
            GATE_MAXHP_BONUS_MIN = 10, GATE_MAXHP_BONUS_MAX = 15, -- 提升或降低 5%~15% 最大生命上限
            GATE_SPD_BONUS_MIN = 5,  GATE_SPD_BONUS_MAX = 20,   -- 弹速加成 %
            GATE_RNG_BONUS_MIN = 5,  GATE_RNG_BONUS_MAX = 20,   -- 射程加成 %

            GateBuffChance = 0.6,
        },
        [4] = {
            Length = 1000,          
            GateInterval = 100,     
            MobInterval = 60,       
            MobsPerGroup = {4, 6},  
            EliteCount = 3,         
            HasBoss = true,          
            
            BasicHP = 60,          
            EliteHP = 120,          
            BossHP = 240,          

           GATE_ATK_BONUS_MIN = 10,  GATE_ATK_BONUS_MAX = 15,
            GATE_ASPD_BONUS_MIN = 10, GATE_ASPD_BONUS_MAX = 15,
            GATE_HP_BONUS_MIN = 10,  GATE_HP_BONUS_MAX = 30,    -- 恢复或扣除 10%~30% 最大生命
            GATE_MAXHP_BONUS_MIN = 10, GATE_MAXHP_BONUS_MAX = 15, -- 提升或降低 5%~15% 最大生命上限
            GATE_SPD_BONUS_MIN = 5,  GATE_SPD_BONUS_MAX = 20,   -- 弹速加成 %
            GATE_RNG_BONUS_MIN = 5,  GATE_RNG_BONUS_MAX = 20,   -- 射程加成 %

            GateBuffChance = 0.6,
        },
        [5] = {
            Length = 1000,
            GateInterval = 90,     
            MobInterval = 50,       
            MobsPerGroup = {5, 7},  
            EliteCount = 3,         
            HasBoss = true,          
            
            -- 第 5 关作为无尽模式的基底，怪群非常密集
            BasicHP = 70,          
            EliteHP = 140,          
            BossHP = 280,          

            GATE_ATK_BONUS_MIN = 10,  GATE_ATK_BONUS_MAX = 15,
            GATE_ASPD_BONUS_MIN = 10, GATE_ASPD_BONUS_MAX = 15,
            GATE_HP_BONUS_MIN = 10,  GATE_HP_BONUS_MAX = 30,    -- 恢复或扣除 10%~30% 最大生命
            GATE_MAXHP_BONUS_MIN = 10, GATE_MAXHP_BONUS_MAX = 15, -- 提升或降低 5%~15% 最大生命上限
            GATE_SPD_BONUS_MIN = 5,  GATE_SPD_BONUS_MAX = 20,   -- 弹速加成 %
            GATE_RNG_BONUS_MIN = 5,  GATE_RNG_BONUS_MAX = 20,   -- 射程加成 %

            GateBuffChance = 0.5,
        }
    },

    -- 6. 无尽模式难度动态成长配置
    ENEMY_HP_SCALE_DIST = 1000, -- 玩家每跑 1000 米
    ENEMY_HP_SCALE_RATE = 0.5,  -- 怪物血量额外增加 30%（乘区） 

    -- 8. 属性门全局配置池 (可以随时在这里增删门里能刷出的属性)
    GATE_ATTRIBUTE_POOL = {"ATK_Bonus", "ASPD_Bonus", "HP_Bonus", "MaxHP_Bonus", "SPD_Bonus", "RNG_Bonus"},

    -- 属性中文化映射表 (用于 3D 文字、UI 界面显示等)
    ATTRIBUTE_NAMES_CN = {
        HP_Bonus = "当前生命",
        MaxHP_Bonus = "最大生命",
        ATK_Bonus = "攻击加成",
        ASPD_Bonus = "攻速加成",
        SPD_Bonus = "弹速加成",
        RNG_Bonus = "射程加成",
    },

    -- 7. 掉落物与磁吸机制
    MAGNET_RADIUS = 15,       
    COLLECT_RADIUS = 5,       
    MAGNET_SPEED = 75,        

    -- 8. 局外天赋商店配置 (清理测试数据，回归正式数值)
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

    -- 9. 宠物与抽卡系统配置
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
	},

    -- 10. 武器与特效配置表
    WEAPONS = {
        ["DefaultWeapon"] = {
            Name = "新手短剑",
            BulletVFX = "DefaultBullet", 
            HitVFX = "DefaultHit",       
            FirePattern = "Parallel",    
            MaxMultiShot = 5,
            
            -- 【新增限制】：短剑射程短，但后期攻速可以叠得比较快
            MaxASPD = 5,    -- 极速上限：每秒 5 发 (即间隔 0.2秒)
            MaxRNG = 120,   -- 射程上限：最多飞出 120 Studs
        },
        ["FireWand"] = {
            Name = "火焰法杖",
            BulletVFX = "Fireball",
            HitVFX = "FireExplosion",
            FirePattern = "Spread",      
            MaxMultiShot = 7,
            
            -- 【新增限制】：法杖范围中等，但施法速度较慢
            MaxASPD = 3,    -- 极速上限：每秒 3 发
            MaxRNG = 180,   -- 射程上限：最多飞出 180 Studs
        },
        ["LaserGun"] = {                 
            Name = "激光枪",
            BulletVFX = "Laser",
            HitVFX = "LaserHit",
            FirePattern = "Pierce",      
            MaxMultiShot = 3,
            
            -- 【新增限制】：激光射程极远，射速极快
            MaxASPD = 10,   -- 极速上限：每秒 10 发
            MaxRNG = 400,   -- 射程上限：最多飞出 400 Studs (几乎满屏)
        }
    },

    -- 11. 怪物特效配置表
    ENEMY_VFX = {
        Basic = "BasicDeath", -- 普通怪死亡特效名称
        Elite = "EliteDeath", -- 精英怪死亡特效名称
        Boss = "BossDeath"    -- Boss 死亡特效名称
    },

    -- 15. 局内升级可选增益池
    LEVEL_UP_BUFF_POOL = {
        { Name = "攻击加成", Attr = "ATK_Bonus", Amount = 15, Color = Color3.fromRGB(255, 100, 100) },
        { Name = "攻速加成", Attr = "ASPD_Bonus", Amount = 15, Color = Color3.fromRGB(100, 255, 100) },
        { Name = "最大生命", Attr = "MaxHP_Bonus", Amount = 15, Color = Color3.fromRGB(100, 255, 255) },
        { Name = "弹速加成", Attr = "SPD_Bonus", Amount = 15, Color = Color3.fromRGB(255, 150, 100) },
        { Name = "射程加成", Attr = "RNG_Bonus", Amount = 15, Color = Color3.fromRGB(200, 200, 100) },
        { Name = "磁力范围", Attr = "MagnetRadius", Amount = 5, Color = Color3.fromRGB(180, 100, 255) }, -- 这个保留绝对值
        { Name = "小幅全能", Attr = "ALL", Amount = 0, Color = Color3.fromRGB(255, 215, 0) },

        -- 将弹道增加的权重压低（只有基础属性的一半概率）
        { Name = "弹道增加", Attr = "MultiShot", Amount = 1, Color = Color3.fromRGB(255, 100, 200), Weight = 20 }
    },
    
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