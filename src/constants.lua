--[[
  坦克动荡2 —— 权威常量表
  来源：反编译源码 frame_53/DoAction.as 尾部常量区（第 2297-2393 行）与 frame_1/DoAction.as 设置区。
  说明：所有数值照抄原版，未做任何"平衡性"改动。
        原版中随迷宫格子大小等比缩放的量（如 *_xscale）在移植层按 SCALE 换算，此处只保留基准常量。
  约定：常量名与原版**逐字同名**，便于与 `机制与数值汇总.md` / 反编译源码逐条对照；
        其中「原版有、本项目未实现或未绘制」的条目会就地标注 `⚠️未使用`（**保留以对齐原版，勿当死代码删**）。
]]

local C = {}

-- ============================================================
-- 1. 画面 / 布局（Flash 舞台尺寸，用于 SCALE 推导）
-- ============================================================
C.MOVIEWIDTH      = 692   -- 舞台宽
C.MOVIEHEIGHT     = 480   -- 舞台高
C.HEIGHTTOBOTTOM  = 80    -- 底部计分板预留高度

-- 迷宫像素缩放：SCALE = min((MOVIEHEIGHT-HEIGHTTOBOTTOM)/(HEIGHT+0.125), MOVIEWIDTH/(WIDTH+0.125))
-- 由迷宫尺寸推导，见 maze.computeScale。

-- ============================================================
-- 2. 起始武器
-- ============================================================
C.STARTWEAPON = "bullet"

-- ============================================================
-- 3. 投射物基准速度 / 生命周期 / 命中检测间隔
--    实际每帧位移 = SPEED / HITCHECKINTERVALS * (SCALE / 50)
-- ============================================================
C.BULLETSPEED              = 4.5
C.BULLETLIFETIME           = 250
C.BULLETHITCHECKINTERVALS  = 7
C.BULLETDEADLY             = 0     -- 0 = 仅击毁坦克（非致死判定标记）

C.LASERSPEED               = 70
C.LASERLIFETIME            = 8
C.LASERHITCHECKINTERVALS   = 70
C.LASERDEADLY              = 7

C.AIMERLENGTH              = 200
C.AIMERHITCHECKINTERVALS   = 100
C.AIMERACTIVE              = 7

C.FRAGSPEED                = 4.5
C.FRAGLIFETIME             = 250
C.FRAGHITCHECKINTERVALS    = 7
C.FRAGDEADLY               = 0

C.DEATHRAYLIFETIME         = 30
C.DEATHRAYDEADLY           = 0
C.DEATHRAYWARMUPTIME       = 15

C.HOMINGSPEED              = 4.5
C.HOMINGLIFETIME           = 250
C.HOMINGHITCHECKINTERVALS  = 5
C.HOMINGDEADLY             = 0
C.HOMINGSTARTUPTIME        = 50
C.HOMINGSMOKECLOUDS        = 5

C.MINESPEED                = 5.5
C.MINEHITCHECKINTERVALS    = 4
C.MINEDEADLY               = 20
C.MINEHIDETIME             = 0
C.MINENUMBER               = 3      -- 埋满 3 颗后自动换回 bullet
C.MINEFRAGMENTS            = 40
C.MINESMOKECLOUDS          = 10
C.MINEDETONATETIME         = 6

C.REMOTESPEED              = 4.5
C.REMOTETURNSPEED          = 15
C.REMOTELIFETIME           = 250
C.REMOTEHITCHECKINTERVALS  = 5
C.REMOTEDEADLY             = 0
C.REMOTESMOKECLOUDS        = 5
C.REMOTESIGNALSIZE         = 70     -- ⚠️未使用：导弹与坦克之间的信号线长度（原版 rCSignal），本项目未绘制

C.GATLINGSPEED             = 5.5
C.GATLINGLIFETIME          = 125
C.GATLINGBULLETS           = 20
C.GATLINGHITCHECKINTERVALS = 7
C.GATLINGDEADLY            = 2
C.GATLINGSPINSPEED         = 10

-- ============================================================
-- 4. 补给箱刷新（帧计）
-- ============================================================
C.CRATESPAWNTIMEBASE       = 350
C.CRATESPAWNTIMERANDOM     = 200
C.CRATESPAWNMAZESIZESCALE  = 2000   -- 按可达格数补偿：+ 2000 / reachable.length

-- ============================================================
-- 5. 爆炸 / 残骸 / 特效数量
-- ============================================================
C.NUMBEROFFRAGMENTS        = 8      -- ⚠️未使用：坦克爆炸残骸（平台层改用近似造型 + 固定片数渲染）
C.NUMBEROFSMOKECLOUDS      = 10
C.NUMBEROFPUFFCLOUDS       = 0      -- ⚠️未使用：原版即"默认关闭"（0），本项目不绘制箱体气团
C.NUMBEROFDUSTCLOUDS       = 20
C.NUMBEROFFRAMESBEFOREEND  = 125
C.NUMBEROFFRAMESFROZEN     = 50
C.NUMBEROFFRAMESBEFORERESET = 5

C.FRAGFRAGMENTS            = 40
C.FRAGSMOKECLOUDS          = 10
C.FRAGLEVELS               = 1

-- ============================================================
-- 6. El Toro（蛮牛冲刺装备）—— ⚠️未使用：本项目未实现该装备，常量照抄原版保留
-- ============================================================
C.ELTOROCHARGETIME         = 10
C.ELTOROSNORTTIME          = 5
C.ELTORONUMBEROFSNORTS     = 15
C.ELTORORUNTIME            = 15
C.ELTOROSIZE               = 5

-- ============================================================
-- 7. 护盾 / 震屏 / 死胡同
-- ============================================================
C.SHIELDSIZE               = 70     -- ⚠️未使用：护盾装备未实现（原版 equipment "shield"）
C.MAXSHAKE                 = 8
C.MAXDEADENDPENALTY        = 5

-- ============================================================
-- 8. 设置默认值（frame_1/DoAction.as 第 393-401 行）
-- ============================================================
C.SETTINGS = {
  -- 补给箱可开出的主动武器（按此顺序，crate 帧标签同名）
  activeWeapons = { "laser", "frag", "gatling", "homing", "deathRay", "mine", "remote" },
  maxBullets    = 5,      -- 普通弹同时在场上限
  maxCrates     = 3,      -- 场上补给箱上限
  crateSpawnModifier = 1,
  -- ⚠️未使用：自定义迷宫数据源（原版 pixvi.net 拉取）未接入，本机只玩随机迷宫
  playRandomMazes    = true,
  playMyCustomMazes  = true,
  playOtherCustomMazes = false,
  useNewMouseControl = false,
  useSmoothCollision = true,
}

return C