-- src/client/Configs/GameConfig.luau
-- 全局游戏数值配置中心
-- 方便后续添加局外养成系统时，统一修改初始属性

local GameConfig = {
    -- 1. 物理与移动控制
    RUN_SPEED = 30,           -- 跑酷基础速度
    RUN_SPEED_INCREMENT = 4,  -- 每过一关，移速增加 4 点
    MAX_RUN_SPEED = 45,       -- 最大跑酷速度
    LATERAL_SPEED = 25,       -- 左右移动速度
    MAX_LATERAL_SPEED = 43,   -- 最大横向移动速度；约等于基础横移速度 +72%
    RUNWAY_LIMIT = 13,        -- 跑道左右边界宽度限制
    RUNWAY_SURFACE_Y_OFFSET = -1.5, -- 跑道真实表面高度微调；门、怪物、掉落物生成过高时填负数

    -- 2. 镜头配置
	-- 正常镜头
    -- CAMERA_OFFSET = Vector3.new(0, 6, 15),
    -- CAMERA_LOOK_OFFSET = Vector3.new(0, 2, -15),

    -- 高空俯视镜头
    -- FOV：降低 FOV (默认70)，数值越小，透视畸变越弱，越接近 2.5D 质感
    CAMERA_FOV = 40,
    -- 相机位置：因为 FOV 变小了，所以必须把相机往后、往上拉得非常远
    CAMERA_OFFSET = Vector3.new(0, 28, 40),
    -- 相机视线：让相机视线看向玩家前方更远的地方，给上方留出足够的视野看清前方的门和怪
    CAMERA_LOOK_OFFSET = Vector3.new(0, 7, -4),

    -- 3. 地图与跑道生成配置
    TRACK_LENGTH = 360,       -- 单块跑道长度
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
    MULTISHOT_EXTRA_DAMAGE_RATIO = 0.7, -- 增加弹道的额外子弹伤害系数；主弹道仍然是100%伤害
    MULTISHOT_SPREAD_DISTANCE = 3.5, -- 增加弹道最终横向分散间距
    MOBILE_TOUCH_DEADZONE = 20, -- 手机端滑动控制死区，避免轻微抖动触发横移
    MOBILE_TOUCH_ACTIVE_Y_RATIO = 0.5, -- 手机端只响应屏幕下半区触控，避免误点 UI
    MOBILE_TOUCH_SMOOTHING = 0, -- 预留触控平滑参数；当前使用即时方向切换

    -- 客户端光照切换配置：大厅使用 Studio 默认光照，进入战斗后切到跑道专用光照方向。
    -- 不需要该功能时，把 Enabled 改成 false 即可完全关闭光照切换。
    COMBAT_LIGHTING = {
        Enabled = false, -- 战斗光照切换总开关
        TransitionTime = 0.75, -- 光照切换过渡时间，避免进入/退出战斗时画面突然闪烁
        ClockTime = 9.5, -- 战斗太阳时间；用于改变阴影朝向，后续按跑道画面继续微调
        GeographicLatitude = -35, -- 战斗太阳纬度；与 ClockTime 配合控制影子方向
        Brightness = 2, -- 战斗亮度；设置为 nil 则沿用大厅默认亮度
    },

    -- 全服持久排行榜配置；展示板在 Studio 中命名为 LeaderboardBoard 即可被客户端自动绑定。
    LEADERBOARD = {
        Mode = "Global",
        BoardName = "LeaderboardBoard",
        TopCount = 10,
        RefreshInterval = 5,
        ServerUpdateInterval = 0.5,
        OrderedStoreName = "BestDistanceLeaderboard_V1",
        GlobalRefreshInterval = 60,
        SelfRankScanLimit = 200,
        MissingWarnDelay = 10,
    },

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


            GateBuffChance = 0.7,
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

            GateBuffChance = 0.7,
        },
        [4] = {
            Length = 1000,
            GateInterval = 100,
            MobInterval = 60,
            MobsPerGroup = {4, 5},
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

            GateBuffChance = 0.7,
        },
        [5] = {
            Length = 1000,
            GateInterval = 90,
            MobInterval = 50,
            MobsPerGroup = {4, 5},
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
    ENEMY_HP_SCALE_RATE = 0.5,  -- 怪物血量额外增加 50%（乘区）
    GATE_SAFE_GAP = 14, -- 属性门前后安全区；普通怪和精英怪会避开，防止门扎堆或被遮挡
    GATE_CENTER_GAP = 8, -- 左右属性门中间的可通行空隙，玩家可选择不吃门直接通过
    BOSS_GATE_BLOCK_GAP = 60, -- Boss 前后门禁区；门撞到 Boss 安全区时直接跳过
    MOB_GATE_BUFFER = 8, -- 怪物避让属性门时额外保留的操作缓冲距离
    ENCOUNTER_MAX_REPOSITION_TRIES = 6, -- 怪物寻找门间空位的最大尝试次数，失败则跳过该波

    -- 属性门全局配置池 (可以随时在这里增删门里能刷出的属性)
    GATE_ATTRIBUTE_POOL = {"ATK_Bonus", "ASPD_Bonus", "HP_Bonus", "MaxHP_Bonus", "SPD_Bonus", "RNG_Bonus", "LateralSpeed_Bonus"},
    GATE_LATERAL_SPEED_BONUS_MIN = 12, -- 横向移动速度属性门最小加成
    GATE_LATERAL_SPEED_BONUS_MAX = 12, -- 横向移动速度属性门最大加成

    -- 属性中文化映射表 (用于 3D 文字、UI 界面显示等)
    ATTRIBUTE_NAMES_CN = {
        HP_Bonus = "当前生命",
        MaxHP_Bonus = "最大生命",
        ATK_Bonus = "攻击加成",
        ASPD_Bonus = "攻速加成",
        SPD_Bonus = "弹速加成",
        RNG_Bonus = "射程加成",
        LateralSpeed_Bonus = "横移速度",
    },

    -- 7. 掉落物与磁吸机制
    MAGNET_RADIUS = 15,
    MAX_MAGNET_RADIUS = 75,
    COLLECT_RADIUS = 5,
    MAGNET_SPEED = 75,
    -- 掉落物爆散配置：生成时先抛散一段时间，再开始磁吸
    DROP_MAGNET_DELAY = 0.6, -- 掉落物烟花抛散期间不立刻磁吸，避免动画被拉断
    DROP_BURST_DURATION = 0.6,
    DROP_BURST_MIN_RADIUS = 4,
    DROP_BURST_MAX_RADIUS = 11,
    DROP_BURST_MIN_HEIGHT = 7,
    DROP_BURST_MAX_HEIGHT = 14,
    DROP_TRAIL_LIFETIME = 0.28,

    -- 8. 局外天赋商店配置
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

	-- 商店天赋显示顺序；不要用 pairs 遍历，避免每次刷新时卡片顺序不稳定。
	SHOP_TALENT_ORDER = {
		"Talent_ATK",
		"Talent_ASPD",
		"Talent_HP",
	},

	-- 商店卡片复用升级卡美术分类；代码只切换 Studio 里对应的 CategoryLayer_* 图层。
	SHOP_TALENT_CARD_ART = {
		Talent_ATK = { Category = "PlayerStats", CategoryName = "玩家属性", Badge = "攻击", BadgeSource = "ATK_Bonus" },
		Talent_ASPD = { Category = "PlayerStats", CategoryName = "玩家属性", Badge = "攻速", BadgeSource = "ASPD_Bonus" },
		Talent_HP = { Category = "PlayerStats", CategoryName = "玩家属性", Badge = "生命", BadgeSource = "MaxHP_Bonus" },
	},

    -- 9. 宠物与抽卡系统配置
	PET_GACHA_COST = 2000,

	PET_BAG_UI = {
		MaxEquipSlots = 1, -- 出战区显示的槽位数量；当前玩法只支持 1 个出战宠物
		ViewportYawDegrees = 180, -- 背包 ViewportFrame 中宠物模型朝向微调，模型背对玩家时改这里
		SyncTemplateSizeToGrid = true, -- 克隆格子时同步 UIGridLayout.CellSize，避免宠物格和空槽大小不一致
	},

	PETS = {
		["Slime"] = {
			Name = "Slime",
			Rarity = "Common",
			Weight = 45,
			SortOrder = 100,
			Description = "WindBlade",
			ATK = 10,
			Cooldown = 4,     -- 技能冷却间隔 (1.5秒一次)
			CastCount = 1,      -- 每次施法连续释放 1 次
			SkillType = "WindBlade", -- 技能形态：穿透风刃
            BulletVFX = "SlimeBullet", -- 独立的子弹特效 (填在 Studio 里做的预制体名)
			HitVFX = "SlimeHit",   -- 独立的命中特效 (填在 Studio 里做的预制体名)
			PierceCount = 99,   -- 风刃可以无限穿透
			WindBladeBaseWidth = 13, -- 风刃初始横向范围；Studio 子弹模型的初始 X 尺寸也按 20 做
			WindBladeMaxWidth = 26, -- 风刃横向范围上限；升级卡片最多把范围推到这里
			MaxCount = 5, -- 宠物最大数量
			Color = Color3.fromRGB(150, 255, 150)
		},
		["Dragon"] = {
			Name = "Dragon",
			Rarity = "Rare",
			Weight = 22,
			SortOrder = 200,
			Description = "Fireball",
			ATK = 25,
			Cooldown = 4,
			CastCount = 1,      -- 蓄力吐出一发大火球
			SkillType = "Fireball",  -- 技能形态：触碰爆炸 AOE
			BulletVFX = "DragonBullet",
			HitVFX = "DragonHit",
			PierceCount = 1,    -- 碰到第一只怪就爆炸
			AOERadius = 12,     -- 【新增】：爆炸波及半径 12
            MaxCount = 3,
			Color = Color3.fromRGB(45, 101, 223)
		},
		["Angel"] = {
			Name = "Angel",
			Rarity = "Epic",
			Weight = 8,
			SortOrder = 300,
			Description = "AngelSmite",
			ATK = 60,
			Cooldown = 6,
			CastCount = 1,
			SkillType = "Smite",     -- 技能形态：锁定目标，天降神罚
            BulletVFX = "AngelSmite",
			HitVFX = "AngelHit",
			PierceCount = 1,
			AOERadius = 22,     -- 神罚拥有超大范围的毁灭打击
            MaxCount = 1,
			Color = Color3.fromRGB(240, 245, 40)
		}
	},

	-- 兼容旧逻辑的简易抽卡权重池；正式抽卡请使用 GameConfig.RollPetId()
	PET_POOL = {
		"Slime", "Slime", "Slime", "Slime", "Slime",
		"Dragon", "Dragon", "Dragon",
		"Angel"
	},

	PET_FIRE_STAGGER_DELAY = 0.8, -- 多个宠物/分身开火时的错峰间隔，让玩家能看清每只宠物的贡献
	PET_CAST_STAGGER_DELAY = 0.15, -- 单只宠物连续施法时的间隔，保留技能连发的节奏感
	SMITE_WARNING_TIME = 0.5, -- 天使圣光预警持续时间：先展示光柱和法阵，再结算伤害
	SMITE_HIT_WINDOW = 0.08, -- 圣光预警结束后的短命中窗口，给碰撞检测保留一两帧时间

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
    ENEMY_MODELS = {
        Basic = "Basic", -- 普通怪模型：ReplicatedStorage/Model/Enemies/Basic
        Elite = "Elite", -- 精英怪模型：ReplicatedStorage/Model/Enemies/Elite
        Boss = "Boss", -- Boss 模型：ReplicatedStorage/Model/Enemies/Boss
    },

    -- 12. 飞剑系统 (御剑流) 初始配置
    SWORD_SKILL = {
        BaseDamage = 20,          -- 飞剑初始伤害
        BaseAttackInterval = 3,   -- 飞剑初始攻击间隔(CD)
        MinAttackInterval = 0.35, -- 最低攻击间隔
        OrbitRadius = 5,          -- 兼容旧字段：飞剑返回/索敌仍可参考该范围
        HoverSideOffset = 3.2,    -- 飞剑待机时距离玩家左右两侧的偏移
        HoverSideSpacing = 0.85,  -- 同一侧多把飞剑继续向外错开，避免在镜头里叠成一条线
        HoverBackOffset = 1.2,    -- 飞剑待机时相对玩家身后的基础偏移
        HoverDepthSpacing = 1.4,  -- 多把飞剑在前后方向的错位间距
        HoverHeight = 2.8,        -- 飞剑待机悬浮高度
        HoverHeightSpacing = 0.42,-- 多把飞剑之间的高度错位，避免视觉重叠
        HoverHeightPattern = {0, 0.65, -0.45, 1.05, -0.75, 0.3}, -- 1-6 把飞剑的高低节奏
        HoverBobAmplitude = 0.28, -- 待机上下轻微浮动幅度
        HoverBobSpeed = 2.5,      -- 待机上下轻微浮动速度
        HoverBobPhaseSpacing = 1.15, -- 每把飞剑浮动相位错开，避免一起上下移动
        TargetRange = 90,         -- 索敌范围
        FlySpeed = 140,           -- 飞剑出鞘飞行速度
        MaxCount = 6,             -- 飞剑最大数量
        MaxCooldownReduction = 60,-- 最大冷却缩减 (%)
    },

    -- 13. 升级卡图标配置表；先留空占位，后续把 "" 替换成 "rbxassetid://资源ID" 即可。
    -- 代码会按 BuffId/Attr 查找图标；没有配置或资源为空时自动隐藏图标，不影响发牌和升级。
    -- 如果填的是 Creator Store/Decal/Asset 页面 ID，缩略图模式通常比直接 rbxassetid 更稳定。
    LEVEL_UP_BUFF_ICON_USE_THUMBNAIL = true,
    LEVEL_UP_BUFF_ICONS = {
        ATK_Bonus = "rbxassetid://15403007921",
        ASPD_Bonus = "rbxassetid://17368087730",
        MaxHP_Bonus = "rbxassetid://17368075795",
        SPD_Bonus = "",
        RNG_Bonus = "",
        MagnetRadius_Bonus = "",
        EXP_Gain_Bonus = "",
        ALL = "",
        MultiShot = "",
        Pet_Count = "",
        Pet_ASPD_Bonus = "",
        Pet_ATK_Bonus = "",
        WindBlade_Range_Bonus = "",
        Sword_Unlocked = "",
        Sword_Count = "",
        Sword_ATK_Bonus = "",
        Sword_CD_Reduction = "",
    },

    -- 升级卡右上角标图标配置；上传 PNG 后把对应资源 ID 填到这里。
    -- 图标文件建议对应：攻击力、攻速、最大生命、弹速、射程、磁力、经验、弹道、宠物、御剑、稀有卡。
    LEVEL_UP_CARD_BADGE_ICON_USE_THUMBNAIL = true,
    LEVEL_UP_CARD_BADGE_ICONS = {
        ATK_Bonus = "rbxassetid://83843411342786", -- 攻击力.png
        ASPD_Bonus = "rbxassetid://89158683195024", -- 攻速.png
        MaxHP_Bonus = "rbxassetid://111122879940468", -- 最大生命.png
        SPD_Bonus = "rbxassetid://88743848478283", -- 弹速.png
        RNG_Bonus = "rbxassetid://114496329613617", -- 射程.png
        MagnetRadius_Bonus = "rbxassetid://111822385402148", -- 磁力.png
        EXP_Gain_Bonus = "rbxassetid://131151921339029", -- 经验.png
        MultiShot = "rbxassetid://86684340290458", -- 弹道.png
        Pet_Count = "rbxassetid://85923690685775", -- 宠物.png
        Pet_ASPD_Bonus = "rbxassetid://85923690685775", -- 宠物.png
        Pet_ATK_Bonus = "rbxassetid://85923690685775", -- 宠物.png
        WindBlade_Range_Bonus = "rbxassetid://85923690685775", -- 宠物.png
        Sword_Unlocked = "rbxassetid://74531224517277", -- 御剑.png
        Sword_Count = "rbxassetid://74531224517277", -- 御剑.png
        Sword_ATK_Bonus = "rbxassetid://74531224517277", -- 御剑.png
        Sword_CD_Reduction = "rbxassetid://74531224517277", -- 御剑.png
        ALL = "rbxassetid://75710132785084", -- 稀有卡.png
    },

    -- 14. 升级卡美术分类配置；美术可以按 Category 做预制卡片，代码只负责填角标/切换分类层。
    LEVEL_UP_CARD_ART = {
        ATK_Bonus = { Category = "PlayerStats", CategoryName = "玩家属性", Badge = "攻击" },
        ASPD_Bonus = { Category = "PlayerStats", CategoryName = "玩家属性", Badge = "攻速" },
        MaxHP_Bonus = { Category = "PlayerStats", CategoryName = "玩家属性", Badge = "生命" },
        SPD_Bonus = { Category = "PlayerStats", CategoryName = "玩家属性", Badge = "弹速" },
        RNG_Bonus = { Category = "PlayerStats", CategoryName = "玩家属性", Badge = "射程" },
        MagnetRadius_Bonus = { Category = "PlayerStats", CategoryName = "玩家属性", Badge = "磁力" },
        EXP_Gain_Bonus = { Category = "Rare", CategoryName = "玩家属性", Badge = "经验" },
        ALL = { Category = "Rare", CategoryName = "稀有通用", Badge = "全能" },
        MultiShot = { Category = "WeaponProjectile", CategoryName = "武器弹道", Badge = "弹道" },
        Pet_Count = { Category = "Pet", CategoryName = "宠物强化", Badge = "宠物" },
        Pet_ASPD_Bonus = { Category = "Pet", CategoryName = "宠物强化", Badge = "宠速" },
        Pet_ATK_Bonus = { Category = "Pet", CategoryName = "宠物强化", Badge = "宠攻" },
        WindBlade_Range_Bonus = { Category = "Pet", CategoryName = "宠物强化", Badge = "风刃" },
        Sword_Unlocked = { Category = "Sword", CategoryName = "御剑技能", Badge = "御剑" },
        Sword_Count = { Category = "Sword", CategoryName = "御剑技能", Badge = "剑数" },
        Sword_ATK_Bonus = { Category = "Sword", CategoryName = "御剑技能", Badge = "剑伤" },
        Sword_CD_Reduction = { Category = "Sword", CategoryName = "御剑技能", Badge = "冷却" },
    },

    -- 升级卡美术层别名配置；用于支持“四类颜色图”和“五类功能分类”同时存在。
    -- Studio 中既可以使用 CategoryLayer_PlayerStats 这类功能名，也可以使用 CategoryLayer_Purple 这类颜色名。
    LEVEL_UP_CARD_LAYER_ALIASES = {
        PlayerStats = { "PlayerStats", "Purple" },
        Pet = { "Pet", "Green" },
        Sword = { "Sword", "Blue" },
        WeaponProjectile = { "WeaponProjectile", "Projectile", "Gold", "Yellow" },
        Rare = { "Rare", "All", "Gold", "Yellow" },
    },

    -- 15. 局内升级可选增益池
    LEVEL_UP_BUFF_POOL = {
        -- 角色属性增益
        { BuffId = "ATK_Bonus", Name = "攻击加成", Attr = "ATK_Bonus", Amount = 15, Color = Color3.fromRGB(255, 100, 100) },
        { BuffId = "ASPD_Bonus", Name = "攻速加成", Attr = "ASPD_Bonus", Amount = 15, Color = Color3.fromRGB(100, 255, 100) },
        { BuffId = "MaxHP_Bonus", Name = "最大生命", Attr = "MaxHP_Bonus", Amount = 15, Color = Color3.fromRGB(100, 255, 255) },
        { BuffId = "SPD_Bonus", Name = "弹速加成", Attr = "SPD_Bonus", Amount = 15, Color = Color3.fromRGB(255, 150, 100) },
        { BuffId = "RNG_Bonus", Name = "射程加成", Attr = "RNG_Bonus", Amount = 15, Color = Color3.fromRGB(200, 200, 100) },
        { BuffId = "MagnetRadius_Bonus", Name = "磁力范围", Attr = "MagnetRadius_Bonus", Amount = 40, Color = Color3.fromRGB(180, 100, 255) },
        { BuffId = "EXP_Gain_Bonus", Name = "经验倍率", Attr = "EXP_Gain_Bonus", Amount = 100, Color = Color3.fromRGB(100, 255, 160), MaxLevel = 3, Weight = 30 },
        { BuffId = "ALL", Name = "小幅全能", Attr = "ALL", Amount = 20, Color = Color3.fromRGB(255, 215, 0) },
        -- 将弹道增加的权重压低（只有基础属性的40%概率）
        { BuffId = "MultiShot", Name = "弹道增加", Attr = "MultiShot", Amount = 1, Color = Color3.fromRGB(255, 100, 200), Weight = 40, CardNote = "额外弹道 70%伤害" },

        -- 宠物增益
        { BuffId = "Pet_Count", Name = "增加宠物", Attr = "Pet_Count", Amount = 1, Color = Color3.fromRGB(255, 150, 200), RequiresPet = true },
        { BuffId = "Pet_ASPD_Bonus", Name = "宠物攻速", Attr = "Pet_ASPD_Bonus", Amount = 15, Color = Color3.fromRGB(255, 150, 200), RequiresPet = true },
        { BuffId = "Pet_ATK_Bonus", Name = "宠物攻击", Attr = "Pet_ATK_Bonus", Amount = 20, Color = Color3.fromRGB(255, 150, 200), RequiresPet = true },
        { BuffId = "WindBlade_Range_Bonus", Name = "风刃范围", Attr = "WindBlade_Range_Bonus", Amount = 20, Color = Color3.fromRGB(120, 220, 255), RequiresPetSkill = "WindBlade" },

        -- 御剑流技能树 (利用 MaxLevel 控制上限，利用 Prereq 控制前置)
        { BuffId = "Sword_Unlocked", Name = "御剑启动", Attr = "Sword_Unlocked", Amount = 1, Color = Color3.fromRGB(0, 255, 255), MaxLevel = 1, Weight = 40 },
        { BuffId = "Sword_Count", Name = "飞剑数量", Attr = "Sword_Count", Amount = 1, Color = Color3.fromRGB(0, 200, 255), Prereq = "Sword_Unlocked", MaxLevel = 5 }, -- 最多升5级，加上初始1把共6把
        { BuffId = "Sword_ATK_Bonus", Name = "飞剑伤害", Attr = "Sword_ATK_Bonus", Amount = 20, Color = Color3.fromRGB(0, 200, 255), Prereq = "Sword_Unlocked" }, -- 每次提升 20%
        { BuffId = "Sword_CD_Reduction", Name = "飞剑冷却", Attr = "Sword_CD_Reduction", Amount = 15, Color = Color3.fromRGB(0, 200, 255), Prereq = "Sword_Unlocked", MaxLevel = 4 }, -- 最多升4级，4*15=60%上限
    },

    -- 16. 怪物击杀掉落配置
    ENEMY_DROPS = {
        Basic = { NumDrops = 2, Exp = 20, Coins = 10 },
        Elite = { NumDrops = 5, Exp = 50, Coins = 50 },
        Boss  = { NumDrops = 15, Exp = 200, Coins = 100 }
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

	-- 加上一个绝对速度上限，防止玩家跑到 20 关时速度达到 60 直接瞬移穿墙
	if currentSpeed > GameConfig.MAX_RUN_SPEED then
		currentSpeed = GameConfig.MAX_RUN_SPEED
	end

	return currentSpeed
end

-- 统一格式化大数字展示；例如 1000 -> 1K，1500000 -> 1.5M
function GameConfig.FormatNumber(value)
	local number = tonumber(value) or 0
	local sign = number < 0 and "-" or ""
	local absNumber = math.abs(number)

	if absNumber < 1000 then
		return sign .. tostring(math.floor(absNumber + 0.5))
	end

	local suffixes = {
		{ Value = 1000000000000, Suffix = "T" },
		{ Value = 1000000000, Suffix = "B" },
		{ Value = 1000000, Suffix = "M" },
		{ Value = 1000, Suffix = "K" },
	}

	for i, unit in ipairs(suffixes) do
		if absNumber >= unit.Value then
			local scaled = absNumber / unit.Value
			local decimals = scaled < 10 and 1 or 0
			local multiplier = 10 ^ decimals
			local rounded = math.floor(scaled * multiplier + 0.5) / multiplier

			-- 999.9K 四舍五入到 1000K 时，自动进位成 1M，避免显示别扭
			if rounded >= 1000 and i > 1 then
				unit = suffixes[i - 1]
				scaled = absNumber / unit.Value
				decimals = scaled < 10 and 1 or 0
				multiplier = 10 ^ decimals
				rounded = math.floor(scaled * multiplier + 0.5) / multiplier
			end

			local text
			if decimals > 0 then
				text = string.gsub(string.format("%.1f", rounded), "%.0$", "")
			else
				text = tostring(math.floor(rounded))
			end

			return sign .. text .. unit.Suffix
		end
	end

	return sign .. tostring(math.floor(absNumber + 0.5))
end

-- 按宠物配置表里的 Weight 权重抽取一个宠物 ID，供服务端抽卡使用
function GameConfig.RollPetId()
	local totalWeight = 0
	for _, petConfig in pairs(GameConfig.PETS) do
		local weight = petConfig.Weight or 1
		if weight > 0 then
			totalWeight += weight
		end
	end

	if totalWeight <= 0 then
		for petId in pairs(GameConfig.PETS) do
			return petId
		end
	end

	local roll = math.random(1, totalWeight)
	local cursor = 0
	for petId, petConfig in pairs(GameConfig.PETS) do
		local weight = petConfig.Weight or 1
		if weight > 0 then
			cursor += weight
			if roll <= cursor then
				return petId
			end
		end
	end

	for petId in pairs(GameConfig.PETS) do
		return petId
	end
	return nil
end

-- 获取宠物背包排序值；优先使用 SortOrder，未配置时按稀有度兜底
function GameConfig.GetPetSortValue(petId)
	local petConfig = GameConfig.PETS[petId]
	if not petConfig then return math.huge end
	if petConfig.SortOrder then return petConfig.SortOrder end

	local rarityOrder = {
		Common = 100,
		Rare = 200,
		Epic = 300,
		Legendary = 400,
	}

	return rarityOrder[petConfig.Rarity] or 999
end

return GameConfig
