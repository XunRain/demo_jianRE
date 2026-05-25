-- src/client/Configs/GameConfig.luau
-- 全局游戏数值配置中心
-- 方便后续添加局外养成系统时，统一修改初始属性

local GameConfig = {
    -- 1. 物理与移动控制
    RUN_SPEED = 25,           -- 跑酷基础速度
    LATERAL_SPEED = 30,       -- 左右移动速度
    RUNWAY_LIMIT = 20,        -- 跑道左右边界宽度限制

    -- 2. 战斗参数
    BULLET_SPEED = 100,       -- 子弹飞行速度
    BULLET_LIFETIME = 1,    -- 子弹存活时间

    -- 3. 镜头配置
	-- 正常镜头
    -- CAMERA_OFFSET = Vector3.new(0, 6, 15),
    -- CAMERA_LOOK_OFFSET = Vector3.new(0, 2, -15),

	-- 高空无人机镜头
	CAMERA_OFFSET = Vector3.new(0, 48, 10),
    CAMERA_LOOK_OFFSET = Vector3.new(0, 10, -20),

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

    -- 6. 关卡(Stage)与遭遇配置中心
    STAGES = {
        [1] = {
            Length = 1000,           -- 本关全长 1000 米
            GateInterval = 150,      -- 每 150 米生成一次属性门
            MobInterval = 100,       -- 每 100 米生成一波普通怪
            MobsPerGroup = {2, 3},   -- 普通怪每波生成 2~3 只
            EliteCount = 1,          -- 本关路途中均匀散布 1 只精英怪
            HasBoss = true,          -- 是否有关底 Boss
            
            BasicHP = 30,            -- 普通怪 30 血
            EliteHP = 150,           -- 精英怪 150 血
            BossHP = 500,           -- Boss 500 血
        },
        [2] = {
            Length = 1500,           
            GateInterval = 120,      
            MobInterval = 80,        
            MobsPerGroup = {3, 4},   
            EliteCount = 2,          
            HasBoss = true,           
            
            BasicHP = 60,            -- 数值开始膨胀
            EliteHP = 300,           
            BossHP = 2500,           
        },
        [3] = {
            Length = 2000,           
            GateInterval = 100,      
            MobInterval = 60,       
            MobsPerGroup = {3, 5},   
            EliteCount = 3,          
            HasBoss = true,           
            
            BasicHP = 120,           
            EliteHP = 600,           
            BossHP = 6000,           
        }
    },

    -- 7. 难度成长配置
    ENEMY_HP_SCALE_DIST = 500, -- 难度提升距离阈值
    ENEMY_HP_SCALE_RATE = 0.5, -- 血量增长率 (50%)

    -- 8. 属性门数值范围
    GATE_HP_MIN = 10, GATE_HP_MAX = 50,
    GATE_ATK_MIN = 1, GATE_ATK_MAX = 5,
    GATE_ASPD_MIN = 1, GATE_ASPD_MAX = 2,

    -- 9. 掉落物与磁吸机制
    MAGNET_RADIUS = 15,       -- 磁吸范围
    COLLECT_RADIUS = 5,       -- 拾取范围
    MAGNET_SPEED = 75,        -- 磁吸飞行速度
}

return GameConfig