--[[
  坦克动荡 —— 千星奇域平台层（渲染 / 输入 / 生命周期 / ctx 组装 / 帧驱动）

  职责划分：
    src/*.lua            纯逻辑（迷宫、坦克物理、武器、AI、回合），逐行对照反编译 AS2
    platform/game.lua    本文件：把纯逻辑接到千星奇域（控件渲染、按键事件、逐帧驱动）

  坐标约定：
    逻辑坐标 = 原版 mazemc 局部像素（Flash：x 右、y 下，角度顺时针为正，0° 朝上）。
    渲染坐标 = UI 局部坐标（相对宿主控件中心，y 上，角度逆时针为正）。
    变换：
      uiX = (px - cx) * VS + shakeX
      uiY = (cy - py) * VS + shakeY
      （(cx,cy) = (W*SCALE/2, H*SCALE/2)，迷宫几何中心）
      部件 UI 旋转 = -(flashRot + partLrot)
    VS 为纯视觉缩放，全部物理/碰撞都在迷宫像素空间完成。

  帧率：原版 Flash 为 25 FPS，逻辑按固定步长 1/25 秒推进（OnLevelUpdate 内累加补步）。

  美术：**只用 1 个「图片控件」模板** + 图片 ID（官方 `SetImage(ImageSource.StaticReference, id)`）——
        正方形 100001 / 圆形 100002 / 三角形 100003 / 四角星 100004 / 五角星 100005 / 同心圆 100006 / 齿轮 100161，
        运行时靠拉伸 / 旋转 / 上色 / 多控件拼接画出全部对象（不依赖任何外部贴图）。
        文字使用原生「文本框」客户端控件（奇匠 Lv.2 解锁【自定义文本外显】后启用，模板索引见 PREFAB.TEXT_BOX）。
]]

local C        = require("src.constants")
local mazeApi  = require("src.maze")
local tankApi  = require("src.tank")
local weaponsApi = require("src.weapons")
local aiApi    = require("src.ai")
local roundApi = require("src.round")
local onlineApi = require("src.online")
local netApi   = require("src.net")
local audioApi = require("src.audio")
local achApi   = require("src.ach")
local statsApi = require("src.stats")

local cos, sin, sqrt, abs, floor, min, max, deg, atan =
  math.cos, math.sin, math.sqrt, math.abs, math.floor, math.min, math.max, math.deg, math.atan
local PI, RAD = math.pi, math.pi / 180

-- 前向声明：下方多个函数在定义处即引用它们。
-- Lua 局部变量必须先声明后使用，否则会被解析成全局变量（运行期为 nil）。
---@type table<string, any>
local G
---@type fun(px: number, py: number): number, number
local toUI
-- HUD（计分板 / 对战倒计时 / 结算提示）表：在 stepFrame 之前就要被引用，故先前向声明，
--   实际内容在 ⑭ HUD 段落赋值（避免 stepFrame 里把 hud 解析成全局 nil）。
---@type table
local hud
-- 菜单表：stepFrame 里的对局结算要调用 MENU.finishMatch，故同样先前向声明（内容在 ⑯ 菜单段落）。
local MENU
-- 沿光束铺固定长度色带的折线渲染（死亡射线条纹）；定义在渲染区，此处前向声明供 syncProjVisual 调用
---@type fun(holder: any, pts: any, color: any, widthWorld: number, color2: any, bandLen: number, phasePx: number): nil
local bandedStripes
-- 击杀登记（本地战绩 / 本地成就）；在菜单区定义，此处前向声明供 killTank 调用
---@type fun(victim: any, source: any): nil
local registerKill
-- 层级重排（自下而上对同级控件 SetAsLastSibling）；
-- 依赖 G / hud / MENU，故在菜单区定义，此处前向声明供 startNewRound / stepFrame / refreshMenu 调用
---@type fun(): nil
local applyZOrder

-- ============================================================
-- ① 模板 / 参数 / 颜色
-- ============================================================
-- ⚠️ 2026-10-16 用户重建了控件模板：**只保留 1 个「图片控件」**，所有形状 / 图标都靠
--   `SetImage(Enum.ImageSource.StaticReference, 图片ID)` 切换；不再有「正方形/圆形/…」6 个独立模板
--   （旧索引 1073741886~1073741900 已作废）。「文本视窗」也不再使用。
local PREFAB = {
  IMAGE       = 1073741910,   -- 图片控件（唯一）：形状 / 齿轮等所有图片都由它承载
  TEXT_BOX    = 1073741908,   -- 文本框（ClientUITextBoxControl）
  KEY_HINT    = 1073741912,   -- 按键提示（KeyHintControl）
  CURSOR_AREA = 1073741914,   -- 光标检测区域（CursorEventArea，触屏输入层用）
                              -- 2026-10-16 用户确认：1073741914 ✓（此前口述时与 KEY_HINT 写成同一个 1073741912）
}

-- 图片 ID（编辑器「图片」资源面板里显示的编号）
local IMG = {
  square = 100001,   -- 正方形
  circle = 100002,   -- 圆形
  tri    = 100003,   -- 三角形
  star4  = 100004,   -- 四角星
  star5  = 100005,   -- 五角星
  rings  = 100006,   -- 同心圆
  gear   = 100161,   -- 齿轮（设置入口图标）
}

-- ------------------------------------------------------------
-- 形状 / 图片统一走「1 个图片模板 + SetImage」
--   官方 §14 ClientUIImageControl：`SetImage(imageSource, imageId)`；`imageSource` 用
--   `Enum.ImageSource.StaticReference`（静态引用 = 项目的图片资产）。
--   池仍**按形状名分桶**（pool[shape]）⇒ 每个控件**只在创建时** SetImage 一次，不会每帧调用。
-- ------------------------------------------------------------

local CFG = {
  FRAME_DT   = 1 / 25,   -- 原版帧率 25 FPS
  MAX_STEPS  = 6,        -- 每帧最多补几个逻辑步，防卡顿雪崩
  TARGET_W   = 900,      -- 舞台渲染目标宽（UI 单位）
  TARGET_H   = 600,      -- 舞台渲染目标高
  MAZE_W_MIN = 4, MAZE_W_MAX = 12,
  MAZE_H_MIN = 4, MAZE_H_MAX = 10,
  TANK_COUNT = 2,
  PLAYER     = 1,
  -- 墙厚不是常数：原版 drawMaze 取 lineThickness = floor(SCALE/16)，墙用 lineStyle(2*lineThickness)
  -- 描边，故墙厚 = 2*floor(SCALE/16)（随尺度取整，见 buildMazeVisuals）。
  -- 补给箱半边长（单位=格）。原版 Crate 剪辑 20×20 局部单位，生成时 _xscale = SCALE*1.5，
  -- 显示尺寸 = 20 * SCALE*1.5/100 = 0.3 格；实机截图 8 倍放大实测约 0.32 格。
  -- 拾取判定用的也是同一半边长（原版 ±10 局部像素 × 1.5*SCALE/100 = 0.15 格）。
  CRATE_R    = 0.16,     -- 边长 = 2*CRATE_R*SCALE ≈ 0.32 格（≈ 原版 0.3 格）
  -- 抗锯齿：图片控件「边缘羽化」宽度（px，0 = 关闭）。平台图元是位图拉伸 + 旋转，
  -- 斜放时有明显锯齿；原版 Flash 是矢量渲染、自带抗锯齿（反编译源码里无任何质量设置代码，
  -- 见 reference/.../mx/managers/SystemManager.as 系框架残留、游戏并未调用）。
  -- 故统一给控件开羽化做亚像素柔边（见 createControl）。若真机觉得文字发虚可调小或设 0。
  --   ⚠️ 2026-10-11 真机回读证明「羽化 API 一直生效」（enableSoftEdge/softEdgeMode/softEdgeWidthX 均被接受），
  --   故锯齿未改善不是调用失败，而是 **1px 太弱**。先用 2px 试观感：仍不够就加大，发虚就回到 1 或 0。
  AA_WIDTH   = 2,
  -- 对局（比赛）时长与胜负规则（用户要求）：战斗页 10 分钟倒计时；先领先 10 分即胜；
  --   倒计时结束仍无人领先 10 分 → 分高者胜；同分 → 进 1 分钟加时循环（不中断当前回合），
  --   加时内任意一方领先即胜。**仅联机**套用本规则（单机无胜利条件；见 v6「单机去胜利条件」）。
  MATCH_SECONDS = 600,
  MATCH_LEAD    = 10,
  OT_SECONDS    = 60,
}

-- 原版舞台 692×480：迷宫像素即舞台像素。整块舞台等比缩放到 UI 目标区，
-- 迷宫在舞台内按原版 setupStandardMaze 末尾公式摆位（水平居中、顶部留白 10px），
-- 计分板固定在舞台底部。因 VS 只由舞台尺寸决定、与单局迷宫尺寸无关，
-- 4~12 × 4~10 各种宽高比的迷宫都按真实比例显示，不被拉伸。
local STAGE_W = C.MOVIEWIDTH      -- 692
local STAGE_H = C.MOVIEHEIGHT     -- 480
-- 「边框版式」（照原版 frame_53）：迷宫**不满屏**——四周留出边框带，下方条带放计分板、右下放「菜单」按钮。
--   ARENA_W/H = 竞技场（世界视口）尺寸（UI 单位）；ARENA_OY = 竞技场中心相对画布中心的上移量
--   ⇒ 下方留出 320-205 = 115 UI 单位给计分板条。
local ARENA_W, ARENA_H, ARENA_OY = 800, 500, 45
local STAGE_SCALE = min(ARENA_W / STAGE_W, ARENA_H / STAGE_H)

local function col(r, g, b, a)
  return Color(floor(r), floor(g), floor(b), a or 255)
end

local COLOR = {
  -- 原版舞台背景 = 纯白：_tt40.xml backgroundColor 255,255,255；MainTimeline.as #ffffff。
  -- 此控件用作全屏底色（盖住场景草地），局内为白底 + 浅灰地板 + 深灰墙线的原版观感。
  SCREEN   = col(255, 255, 255),
  -- 原版 drawMaze（frame_53 L601-648）：
  --   mazebg 第一遍 每格纯黑矩形（并集 = 整块外扩 floor(scale/16)+1 的纯黑衬底），
  --   mazebg 第二遍 每格浅灰 0xE6E6E6=(230,230,230) 地板，只在外围露出约 lt+1 px 黑边；
  --   mazemc 用深灰 0x4D4D4D=(77,77,77) 线宽 2*lt 描边画墙线。
  FLOOR    = col(230, 230, 230),
  WALL     = col(77, 77, 77),
  MAZE_EDGE = col(0, 0, 0),
  -- 玩家色 = 反编译 frame_7/19/31/43 的 loginInfo.pNtrac/pNturc 原值（**纯色**）：
  --   P1=16711680=#FF0000、P2=65280=#00FF00、P3=255=#0000FF；莱卡(AI)=2500134=#262626 车体 / 6710886=#666666 炮塔。
  P1       = col(255, 0, 0),
  P2       = col(0, 255, 0),
  P3       = col(0, 0, 255),
  P4       = col(38, 38, 38),   -- 莱卡车体深灰（原版 2500134）
  P4_TURRET = col(102, 102, 102), -- 莱卡炮塔中灰（原版 6710886）
  GRAY     = col(128, 128, 128),-- 联机准备页可选颜色「灰」
  SHOT     = col(255, 214, 140),
  -- 原版投射物贴图原生色（贴图不与坦克颜色相乘）：
  -- bullet / electricbullet 5×5、gatlingBullet 3×3、fragbombfragment 3×3 均为纯黑。
  -- （homing / remote 用 owner 的 turretColor 染色，见 buildProjVisual）
  BULLET   = col(0, 0, 0),
  -- 地雷中心 LED：原版 DefineSprite_234_mine 第 1 帧（未布防）为蓝圆、第 2 帧（armed）为绿圆。
  MINE_BLUE  = col(48, 82, 220),
  MINE_GREEN = col(70, 200, 70),
  TEXT     = col(245, 245, 245),
  -- 局内计分板文字：白底舞台上用深色（原版计分板位于底部、深色字）
  HUD_TEXT = col(40, 42, 48),
  OUTLINE  = col(18, 18, 22),
  -- 原版补给箱（raw/Crate.swf 矢量剪辑，生成时 gotoAndStop(武器名) 切到逐武器帧）。
  -- 依据反编译还原（reference/tank_trouble2_decompiled/tools/crate_dump/1.svg）：
  -- 箱体 20×20，对角线性渐变 #444444→#b7b7b7（浅色在左上、深色在右下）；
  -- 结构 = 外框(±8~±10) + 内嵌方环线 #8d8d8d(±7~±8) + 内面板(±7)，外框/内面板同一渐变；
  -- 最外轮廓 #666666 描边宽仅 0.05（几乎不可见，略去）。
  -- 平台图元不支持渐变，箱体与内面板统一用渐变均值 #7E7E7E 纯色近似。
  CRATE      = col(126, 126, 126), -- 箱体 + 内面板（渐变均值，中性灰）
  CRATE_RING = col(141, 141, 141), -- 内嵌方环线（原版 #8d8d8d）
  CRATE_B    = col(51, 51, 51),    -- 武器字形（原版 #333333）
  CRATE_DUST = col(170, 170, 170), -- 落地扬尘（原版 dust 色 0xAAAAAA）
  SMOKE    = col(180, 180, 180),
  FLAME    = col(255, 168, 60),
  -- 菜单
  SEL      = col(58, 70, 92),
  ACCENT   = col(206, 148, 26),  -- 菜单强调 / 选中色（浅底上用深琥珀；原为亮黄，压白底几乎看不清）
  DIM      = col(120, 124, 132),  -- 菜单次要文字（浅底上的中灰）
  OK       = col(120, 220, 140),
  NO       = col(210, 120, 120),
  -- 主菜单横幅（原版手绘斜切白底黑边按钮的矩形近似）：
  -- 白底 #FCFCFA（近纯白）/ 灰底副标题条 #DDDDDD / 悬停时横幅底变**浅绿**
  BANNER_BG    = col(252, 252, 250),
  BANNER_DESC  = col(221, 221, 221),
  -- 悬停底：取自原版 DefineSprite_356_2.png 的横幅填充色 RGB(147,233,153)
  BANNER_HOVER = col(147, 233, 153),
  -- 鼠标坦克准星（原版 scopeCross / scopeCircle）：
  --   深灰细十字 + 中心小方块；圆环未蓄力浅灰、蓄力（新操控下朝鼠方向够远）为红。
  SCOPE       = col(64, 64, 64),
  SCOPE_RING  = col(96, 96, 96),
  SCOPE_ARMED = col(214, 48, 48),
  -- 主菜单「浅色主题」：原版舞台背景为纯白（_tt40.xml backgroundColor 255,255,255），
  -- 主菜单直接画在白底上（**纯白底 + 黑边横幅 + 黑字**），**没有**深色面板、也没有奶油/琥珀色。
  -- 依据：原版按钮精灵 textures/04_sprites/DefineSprite_340_1.png —— 白底、粗黑边、黑字、灰底黑边说明框。
  MENU_BG      = col(255, 255, 255),  -- 菜单面板底色（原版舞台纯白）
  MENU_TEXT    = col(26, 26, 30),     -- 菜单主文字 / 横幅主标题（近黑，同原版）
  MENU_ROW     = col(38, 38, 44),     -- 设置 / 控制方式 / 按键设置 的行文字
  MENU_ICON    = col(40, 40, 44),     -- 齿轮 / 音效图标（近黑，同原版线条）
  MENU_HL      = col(219, 228, 240),  -- 行选中高亮条（浅蓝灰，衬深色行文字）
  ARROW        = col(60, 64, 72),     -- 设置行左右切换三角（未选中态）
}

-- 同色明暗 / 改透明度（ColorValue 无 .r/.g/.b，必须用 Color.ToRGBA 拆包）
local function shade(c, f)
  local r, g, b, a = Color.ToRGBA(c)
  return col(min(255, r * f), min(255, g * f), min(255, b * f), a)
end
local function alphaOf(c, a)
  local r, g, b = Color.ToRGBA(c)
  return col(r, g, b, a)
end

-- ============================================================
-- ② 控件池与部件工具
-- ============================================================
---@type ClientUIContainerControl|nil
local host = nil
local pool = { square = {}, circle = {}, tri = {}, star4 = {}, star5 = {}, rings = {} }
-- 已创建的全部控件（用于「抗锯齿」数值改变时**重新应用**羽化；控件只增不销毁，故该表有界）
local aaControls = {}

-- 给单个控件应用「边缘羽化」（= 本项目的抗锯齿）。w ≤ 0 表示关闭。
--   官方《客户端控件·图片》把「边缘羽化」列在**「遮罩功能」**之下，枚举亦名 `ImageMaskSoftEdgeMode`
--   ⇒ 一并开启 `enableMask`。2026-10-11 真机回读证明这些字段**确实被平台接受**
--   （`抗锯齿回读：enableMask=true enableSoftEdge=true softEdgeMode=… softEdgeWidthX=…`）。
local function applyAATo(ctl, w)
  if ctl == nil then return end
  -- 羽化宽度按「屏幕像素」定义 ⇒ 除以整体缩放：控件本地像素会被 host 缩放放大，
  --   不折算的话「抗锯齿 2」在 1.4× 缩放下会变成 2.8px，把坦克/补给箱的细长部件边缘削掉（接缝分离）。
  local lw = (w ~= nil and w > 0) and (w / (G.uiScale or 1)) or 0
  if lw > 0 then
    ---@diagnostic disable-next-line: inject-field
    pcall(function() ctl.enableMask = true end)
    ---@diagnostic disable-next-line: inject-field
    pcall(function() ctl.softEdgeMode = Enum.ImageMaskSoftEdgeMode.Pixel end)
    ---@diagnostic disable-next-line: inject-field
    pcall(function() ctl.enableSoftEdge = true end)
    ---@diagnostic disable-next-line: undefined-field
    pcall(function() ctl:SetSoftEdgeWidth(lw, lw) end)
    ---@diagnostic disable-next-line: inject-field
    pcall(function() ctl.softEdgeWidthX = lw end)
    ---@diagnostic disable-next-line: inject-field
    pcall(function() ctl.softEdgeWidthY = lw end)
  else
    ---@diagnostic disable-next-line: inject-field
    pcall(function() ctl.enableSoftEdge = false end)
    ---@diagnostic disable-next-line: inject-field
    pcall(function() ctl.softEdgeWidthX = 0 end)
    ---@diagnostic disable-next-line: inject-field
    pcall(function() ctl.softEdgeWidthY = 0 end)
  end
end

---@return ClientUIControl|nil
local function createControl(prefabIndex)
  local ok, ctl = pcall(game.InstantiateClientUIControl, prefabIndex, host)
  if not ok or ctl == nil then
    printerr("[坦克动荡] 创建控件失败，prefabIndex=" .. tostring(prefabIndex))
    return nil
  end
  pcall(function()
    ctl:SetAnchorMin(0.5, 0.5)
    ctl:SetAnchorMax(0.5, 0.5)
    ctl:SetPivot(0.5, 0.5)
  end)
  -- 关键：InstantiateClientUIControl 实例化出的控件 active 默认为 false，
  -- 此时控件不可见且挂载脚本不运行，SetVisible(true) 也不会让它显示，必须显式激活。
  pcall(function() ctl:SetActive(true) end)
  pcall(function() ctl:SetVisible(true) end)
  -- 形状模板默认 imageType 为 Basic（按原始像素绘制，不随控件尺寸缩放），
  -- 设为 Stretch 后 SetSizeDelta 才能真正把图形拉伸到目标大小。
  ---@diagnostic disable-next-line: inject-field
  pcall(function() ctl.imageType = Enum.ImageType.Stretch end)
  applyAATo(ctl, (G ~= nil and G.aaWidth) or CFG.AA_WIDTH)
  aaControls[#aaControls + 1] = ctl
  return ctl --[[@as ClientUIControl]]
end

-- ------------------------------------------------------------
-- 显示设置：整体缩放 + 抗锯齿（可在「设置」面板调整；见 buildMenuUI 的 setRows / refreshSetRows）
-- ------------------------------------------------------------
-- 「显示大小」：**整体等比缩放整个 UI** —— 全部控件都是 host 的子节点、坐标相对 host 中心，
--   故一条 `host:SetLocalScale(k,k,1)` 就把所有控件（含文字）一起缩放。
--   ⚠️ 缩放后「画布坐标 → 本项目 UI 坐标」的换算必须除以 k（见 readCursor / setupTouchInput / buildTouchZones）。
local function applyUIScale(k)
  if type(k) ~= "number" or k <= 0 then return end
  G.uiScale = k
  if host ~= nil then pcall(function() host:SetLocalScale(k, k, 1) end) end
  -- 羽化宽度与缩放相关 ⇒ 缩放变化后对已建控件重新应用（保持「屏幕像素」语义）
  for i = 1, #aaControls do applyAATo(aaControls[i], G.aaWidth) end
end

-- 「抗锯齿」数值改变：对**已创建的全部控件**重新应用（池中与在用的都是同一批对象）。
local function applyAAAll(w)
  G.aaWidth = w
  for i = 1, #aaControls do applyAATo(aaControls[i], w) end
end

-- 按图片 ID 建控件（唯一图片模板 + SetImage）
local function createImageCtl(imageId)
  local ctl = createControl(PREFAB.IMAGE)
  if ctl == nil then return nil end
  if type(imageId) == "number" and imageId > 0 then
    pcall(function()
      ctl:SetImage(Enum.ImageSource.StaticReference, imageId)
      ctl.imageType = Enum.ImageType.Stretch   -- 换图后重申拉伸（按实际尺寸绘制）
    end)
  end
  return ctl
end

-- 按形状名建控件（池按形状名分桶 ⇒ 每个控件只在创建时 SetImage 一次）
local function createShape(shape)
  return createImageCtl(IMG[shape] or IMG.square)
end

local function acquire(shape)
  local list = pool[shape]
  if list == nil then
    list = {}
    pool[shape] = list
  end
  local ctl = table.remove(list)
  if ctl == nil then
    ctl = createShape(shape)
    if ctl == nil then return nil end
  else
    pcall(function() ctl:SetActive(true) end)
  end
  -- 关键：池中控件可能残留上一次使用时的旋转（折线激光段 / 补给箱旋转动画 / 炮塔……
  --         都会给"正方形"写角度，而这些角度会被复用到墙上，导致"歪墙 / 不在网格线上的墙"）。
  --         取出复用时一律清零。
  pcall(function() ctl:SetLocalRotation(0, 0, 0) end)
  -- 取出即视为"已使用"：可见；回收（release）时才隐藏
  pcall(function() ctl:SetVisible(true) end)
  return ctl
end

local function release(shape, ctl)
  if ctl == nil then return end
  local list = pool[shape]
  if list == nil then
    list = {}
    pool[shape] = list
  end
  pcall(function() ctl:SetVisible(false) end)
  list[#list + 1] = ctl
end

-- 模板自检：逐个实例化 模板并立刻销毁，结果打到正常日志，便于排查"编辑器里没配模板 / 索引写错"
local function selfCheckPrefabs()
  local order = { "IMAGE", "TEXT_BOX", "KEY_HINT", "CURSOR_AREA" }
  local seg = {}
  for i = 1, #order do
    local idx = PREFAB[order[i]]
    local ok, ctl = pcall(game.InstantiateClientUIControl, idx, host)
    if ok and ctl ~= nil then
      seg[#seg + 1] = order[i] .. "=" .. tostring(idx) .. " OK"
      pcall(function() game.DestroyClientUIControl(ctl) end)
    else
      seg[#seg + 1] = order[i] .. "=" .. tostring(idx) .. " FAIL"
    end
  end
  print("[坦克动荡] 模板自检：" .. table.concat(seg, " | "))
  -- 抗锯齿回读探针：用 createControl 建一个（会应用「边缘羽化」设置）并回读，
  --   确认平台是否真的接受这些字段（"AA 一直没效果"需要先排除"API 根本没生效"）。
  if (G.aaWidth or 0) > 0 then
    local c = createShape("square")
    if c ~= nil then
      local se, sm, sw, mk = "?", "?", "?", "?"
      pcall(function() se = tostring(c.enableSoftEdge) end)
      pcall(function() sm = tostring(c.softEdgeMode) end)
      pcall(function() sw = tostring(c.softEdgeWidthX) end)
      pcall(function() mk = tostring(c.enableMask) end)
      print("[坦克动荡] 抗锯齿回读：enableMask=" .. mk .. " enableSoftEdge=" .. se
            .. " softEdgeMode=" .. sm .. " softEdgeWidthX=" .. sw
            .. "（目标 AA_WIDTH=" .. tostring(CFG.AA_WIDTH) .. "）")
      pcall(function() game.DestroyClientUIControl(c) end)
    end
  end
end

-- 部件：局部偏移(lx,ly) 已换算为世界像素；尺寸(w,h) 已换算为世界像素
local function vpart(shape, w, h, color, lx, ly, lrot)
  local ctl = acquire(shape)
  if ctl == nil then return nil end
  local vs = G.VS
  pcall(function()
    ctl:SetSizeDelta(w * vs, h * vs)
    ctl.imageColor = color
  end)
  return { shape = shape, ctl = ctl, lx = lx, ly = ly, lrot = lrot }
end

local function vfree(parts)
  if parts == nil then return end
  for i = 1, #parts do
    local p = parts[i]
    release(p.shape, p.ctl)
    parts[i] = nil
  end
end

-- 组渲染：给定 Flash 世界中心 (fx,fy)、Flash 角度 frot(度)，逐个部件摆位
local function renderGroup(parts, fx, fy, frot)
  if parts == nil then return end
  local th = frot * RAD
  local c, sn = cos(th), sin(th)
  for i = 1, #parts do
    local p = parts[i]
    local wx = fx + (p.lx * c - p.ly * sn)
    local wy = fy + (p.lx * sn + p.ly * c)
    local ux, uy = toUI(wx, wy)
    p.ctl:SetAnchoredPosition(ux, uy)
    p.ctl:SetLocalRotation(0, 0, -(frot + p.lrot))
  end
end

-- ============================================================
-- ③ 世界状态
-- ============================================================
G = {
  W = 0, H = 0, scale = 50, VS = STAGE_SCALE, gameX = 0, gameY = 0,
  -- 显示设置（「设置」面板可调；平台无存储 API ⇒ 每次进游戏回默认值：缩放=自适应、抗锯齿=CFG.AA_WIDTH）
  uiScale = 1, uiScaleMode = 1, aaWidth = CFG.AA_WIDTH,
  -- 联机标志（**联机功能落地后置 true**）：联机对局**禁止以任何形式暂停 / 打开设置面板**，
  --   也禁止中途退出（规则性设置只能在「准备阶段」改，见 DEV_STATE）。
  online = false,
  -- 对战设置（原版 _root.settingsXXX，见 reference/.../frame_1/DoAction.as L393-401）
  --   单机：设置面板 →「对战设置」可调；联机：禁止（规则性设置只能在准备阶段改）。
  rules = { maxBullets = C.SETTINGS.maxBullets, maxCrates = C.SETTINGS.maxCrates,
            crateRate = C.SETTINGS.crateSpawnModifier, smooth = C.SETTINGS.useSmoothCollision,
            weapons = {} },
  hasAI = false,   -- 本局是否有 AI（与莱卡对战时原版强制只出激光）
  -- 联机「v4 房主权威」：**房主**是这一局的唯一事实源 —— 它摇迷宫表（表首项 = 回合号 seq）、
  --   决定补给箱、判定胜负；服务器**只做搬运**（信号 → 关卡变量）。见 MENU.isMazeHost。
  --   mazeInts = 本回合正在用的表；为空 = 单机（或还没收到），走本地随机。
  mazeInts = nil,
  roundId = 0,          -- 房主：权威回合号（每次开新回合 +1，写进迷宫表首项 seq）
  mazeSeqSeen = 0,      -- 非房主：从 TT2_MAZE 读到的**最新** seq
  mazeSeqUsed = 0,      -- 非房主：**已经用过**的 seq（据此判断「该重开一回合了」）
  awaitRound = nil,     -- 非房主：本端回合已结束（或刚开局），正在等房主的下一个 seq
  awaitFrames = 0,      -- 非房主：「等表」已等了多少帧（超时则回退本地随机，避免卡死）
  slotKnown = nil,      -- 是否已收到服务器下发的槽位（未收到前不能判房主 —— playerIndex 默认就是 1）
  crateSeq = 0,         -- 房主：补给箱 id 自增
  crateDirty = false,   -- 房主：补给箱表有变化、待上传
  winnerSeen = 0,       -- 从 TT2_WINNER 读到的胜者槽位（0 = 本局未结束）
  -- 联机准备界面（v5）：准备档按槽位走两个信号 / 两个关卡变量（见 src/online.lua §⑥）
  readySeen = {},       -- [slot] = { ready=bool, color=数(0=未选), ctrl=数(1键盘/2手柄/3触屏) }
  readyDirty = false,   -- 本端准备档有变化 ⇒ 待上传（联机）
  readyPrevFire = false,-- 上一帧「本机开火」（准备页边沿检测；联机取所有控制方式的并集）
  beatSeen = 0,         -- 最近读到的 TT2_BEAT（服务器心跳值）—— 准备阶段的**两端共享时钟**
  startWait = 0,        -- 兜底计时（秒）：拿不到同步时钟时的本地回退用
  -- 联机对局（P1 房间/玩家模型 + P2 位置同步）：见 MENU.setupRoom / stepOnline
  room = nil,        -- { mySlot, oppSlots = {..}, delay = 0.15 }
  snapBuf = nil,     -- 对手快照插值缓冲（src.online）
  snapStep = 0,      -- 上行节拍计数（每 2 个定步 = 12.5Hz）
  maze = nil, reachable = {}, reachableIndex = nil, deadEnds = nil,
  tanks = {}, projectiles = {}, crates = {}, effects = {},
  wallParts = {},
  battle = nil,
  shakeX = 0, shakeY = 0,
  fieldCache = {}, distProxy = nil,
  playerIndex = CFG.PLAYER,
  -- 名称 / 实时延迟（联机）：显示在计分板每辆坦克旁（名字 + 分数 + 延迟），以及准备页自己那张卡。
  playerName = nil,     -- 服务器下发的本机玩家名（无则退回槽位默认名）
  pingMs = nil,         -- 最近一次 PING 往返（毫秒；nil = 尚未测得）
  pingAt = nil,         -- 上次发 PING 的时间戳（audioClock 秒）
  pingTimer = 0,        -- PING 发送节拍累计
  -- 菜单导航输入（W/S/A/D + 方向键 + 确认键）
  input = { fwd = false, back = false, left = false, right = false, fire = false },
  -- 各控制方案（1=红/1P，2=绿/2P）的坦克输入。键位可在按键设置页自定义，见 DEFAULT_BINDS / BINDS。
  pinputs = {
    { fwd = false, back = false, left = false, right = false, fire = false },
    { fwd = false, back = false, left = false, right = false, fire = false },
  },
  -- 鼠标坦克（原版第 3 台）输入：开火 = 鼠标左键，其余由光标位置驱动（见 tankFrame）。
  pmouse = { fire = false },
  -- 触屏（移动端）：设备判定 + 触点状态（画布中心为原点、y 向上）。见 DEV_STATE §10.5 / §6.20 / §6.23。
  touchMode = false,
  touch = { x = 0, y = 0, ok = false, down = false },   -- 指针（菜单用；取最近一次触点）
  touches = {},                                          -- [touchId] = { x, y }（多指，游戏内操作用）
  tcfg = { stickR = 130, dead = 0.22, aimLen = 220 },    -- 摇杆半径 / 死区比例 / 「朝向我」满幅映射距离
  tzone = nil,                                           -- 当前模式的触屏分区（见 buildTouchZones）
  tstick = { { active = false }, { active = false } },   -- 每玩家摇杆状态
  tfire = { false, false },                              -- 每玩家开火按钮状态
  touchHandfeel = "pad",                                 -- pad = 8 向布尔 | aim = 方向即朝向
  tviz = nil,                                            -- 触屏操控的可视控件（懒构建）
  -- 手柄：左摇杆轮询值 / 十字键与 A 键事件状态 / 每帧合成的输入结果（见 pollGamepad）。
  gpStick = { h = 0, v = 0 },
  gpKey = { fwd = false, back = false, left = false, right = false, fire = false },
  gp = { fwd = false, back = false, left = false, right = false, fire = false },
  mode = "solo",   -- solo | duo | trio
  -- 对局（比赛）状态：见 CFG.MATCH_* / beginMatch。
  match = nil,
  accum = 0, running = false,
  -- 本地战绩（原版为上传到 pixvi.net 的统计，此处只本地累计）
  stats = statsApi.new(),
  -- 本地成就（原版通过 achievement.php 上报，此处只本地记录）
  ach = achApi.new(),
}

-- ============================================================
-- ④ 坐标变换
-- ============================================================
-- 迷宫像素 → 舞台像素（+gameX/gameY）→ UI（以舞台中心为原点，y 翻转）
toUI = function(px, py)
  local sx, sy = px + G.gameX, py + G.gameY
  -- 竞技场整体上移 ARENA_OY（边框版式），世界像素 → UI 坐标
  return (sx - STAGE_W / 2) * G.VS + G.shakeX,
         (STAGE_H / 2 - sy) * G.VS + G.shakeY + ARENA_OY
end

-- ============================================================
-- ⑤ 迷宫：生成 / 渲染 / 距离场
-- ============================================================
local function fieldOf(cx, cy)
  local key = cx * 1000 + cy
  local f = G.fieldCache[key]
  if f == nil then
    f = mazeApi.calcDistances(G.maze, cx, cy)
    G.fieldCache[key] = f
  end
  return f
end

local function buildDistProxy()
  G.fieldCache = {}
  G.distProxy = setmetatable({}, {
    __index = function(_, sx)
      return setmetatable({}, {
        __index = function(_, sy) return fieldOf(sx, sy) end,
      })
    end,
  })
end

local function wallExistsV(x, y)   -- 竖墙：列 x∈[0,W]
  local m = G.maze
  if y < 0 or y >= G.H then return false end
  if x == 0 then return (m[0][y].s or 0) ~= 0 end
  if x == G.W then return (m[G.W - 1][y].s or 0) ~= 0 end
  return (m[x][y].xw or 0) ~= 0
end

local function wallExistsH(x, k)   -- 横墙：行 k∈[0,H]
  local m = G.maze
  if x < 0 or x >= G.W then return false end
  if k == 0 then return (m[x][0].s or 0) ~= 0 end
  if k == G.H then return (m[x][G.H - 1].s or 0) ~= 0 end
  return (m[x][k - 1].yw or 0) ~= 0
end

local function buildMazeVisuals()
  vfree(G.wallParts)
  G.wallParts = {}
  -- 地板 / 外圈衬底控件随回合重建，先把旧的还回池子，避免每回合泄漏
  if G.floorCtl ~= nil then
    release("square", G.floorCtl)
    G.floorCtl = nil
  end
  if G.backdropCtl ~= nil then
    release("square", G.backdropCtl)
    G.backdropCtl = nil
  end
  local s = G.scale
  -- 原版 drawMaze（frame_53 L601/L648）：lineThickness = floor(scale/16)，
  -- 墙用 lineStyle(2*lineThickness) 描边 → 墙厚恰为 2*floor(scale/16)，以格线为中心。
  local lt = floor(s / 16)
  local t = 2 * lt
  local vs = G.VS

  local function addWall(px, py, w, h)
    local ctl = acquire("square")
    if ctl == nil then return end
    pcall(function()
      ctl:SetSizeDelta(w * vs, h * vs)
      ctl.imageColor = COLOR.WALL
    end)
    G.wallParts[#G.wallParts + 1] = { shape = "square", ctl = ctl, bx = px, by = py }
  end

  -- 迷宫外圈纯黑衬底（原版 mazebg 第一遍的并集）：尺寸 = 地板 + 四周各外扩 (lt+1)
  local edge = lt + 1
  local backdrop = acquire("square")
  if backdrop ~= nil then
    pcall(function()
      backdrop:SetSizeDelta((G.W * s + 2 * edge) * vs, (G.H * s + 2 * edge) * vs)
      backdrop.imageColor = COLOR.MAZE_EDGE
    end)
    local ux, uy = toUI(G.W * s / 2, G.H * s / 2)
    backdrop:SetAnchoredPosition(ux, uy)
    G.backdropCtl = backdrop
  end

  -- 地板（原版 mazebg 第二遍：0xE6E6E6 浅灰，精确覆盖 [0,W*s]×[0,H*s]）
  local floorCtl = acquire("square")
  if floorCtl ~= nil then
    pcall(function()
      floorCtl:SetSizeDelta(G.W * s * vs, G.H * s * vs)
      floorCtl.imageColor = COLOR.FLOOR
    end)
    local ux, uy = toUI(G.W * s / 2, G.H * s / 2)
    floorCtl:SetAnchoredPosition(ux, uy)
    G.floorCtl = floorCtl
  end

  -- 竖墙
  for x = 0, G.W do
    local runStart = nil
    for y = 0, G.H do
      local has = (y < G.H) and wallExistsV(x, y)
      if has and runStart == nil then runStart = y end
      if (not has) and runStart ~= nil then
        local y0, y1 = runStart, y
        addWall(x * s, (y0 + y1) / 2 * s, t, (y1 - y0) * s + t)
        runStart = nil
      end
    end
  end
  -- 横墙
  for k = 0, G.H do
    local runStart = nil
    for x = 0, G.W do
      local has = (x < G.W) and wallExistsH(x, k)
      if has and runStart == nil then runStart = x end
      if (not has) and runStart ~= nil then
        local x0, x1 = runStart, x
        addWall((x0 + x1) / 2 * s, k * s, (x1 - x0) * s + t, t)
        runStart = nil
      end
    end
  end

  -- 首次摆位
  for i = 1, #G.wallParts do
    local wp = G.wallParts[i]
    local ux, uy = toUI(wp.bx, wp.by)
    wp.ctl:SetAnchoredPosition(ux, uy)
  end
end

local function syncWalls()
  for i = 1, #G.wallParts do
    local wp = G.wallParts[i]
    local ux, uy = toUI(wp.bx, wp.by)
    wp.ctl:SetAnchoredPosition(ux, uy)
  end
  if G.floorCtl ~= nil then
    local ux, uy = toUI(G.W * G.scale / 2, G.H * G.scale / 2)
    G.floorCtl:SetAnchoredPosition(ux, uy)
  end
  if G.backdropCtl ~= nil then
    local ux, uy = toUI(G.W * G.scale / 2, G.H * G.scale / 2)
    G.backdropCtl:SetAnchoredPosition(ux, uy)
  end
end

-- ============================================================
-- ⑥ 坦克：美术 / 构造 / 炮塔
-- ============================================================
-- 车体美术（对应原版 GameTank 的 base：可染色白底 + 黑色半透明阴影层）
-- 几何取自反编译 SVG（reference/.../tools/tank_shapes）：
--   整体 60 宽 × 80 长；左右履带带各 12.5 宽（中心 x=±23.75）；中央车体面板 35 宽。
--   原版阴影为连续竖直渐变、外描边为 1px 黑发丝线；平台不支持渐变/描边，
--   故用若干离散色阶方块（factor 值）近似「前/后缘压暗、中央最亮、履带整体偏暗」。
local TANK_BASE_ART = {
  -- 中央车体面板：**故意比 35 宽出 5（= 40）**，让它塞到左右履带之下。
  --   ⚠️ 若按原版 35 宽，面板与履带（±17.5）正好相接；平台开了「边缘羽化」后两条接缝都变半透明，
  --   会露出浅色地板 = 坦克身上两条白线（用户反馈）。加宽后被履带盖住（同为压暗色）即消失。
  { "sq", 40, 80, 1.00, 0, 0, 0 },
  { "sq", 40, 7, 0.46, 0, -36.5, 0 },   -- 前缘压暗
  { "sq", 40, 7, 0.46, 0, 36.5, 0 },    -- 后缘压暗
  -- 左右履带带（各 12.5 宽 × 80 长，原版整体偏暗）
  { "sq", 12.5, 80, 0.72, -23.75, 0, 0 },
  { "sq", 12.5, 80, 0.72, 23.75, 0, 0 },
  { "sq", 12.5, 10, 0.42, -23.75, -35, 0 },  -- 履带前/后端压暗
  { "sq", 12.5, 10, 0.42, -23.75, 35, 0 },
  { "sq", 12.5, 10, 0.42, 23.75, -35, 0 },
  { "sq", 12.5, 10, 0.42, 23.75, 35, 0 },
}

local TURRET_DIMS = {
  bullet = { 45, 77.5 }, laser = { 45, 82 }, frag = { 50, 80 },
  gatling = { 60, 80 }, homing = { 50, 80 }, mine = { 50, 80 },
  remote = { 50, 80 }, deathRay = { 56, 86 }, electric = { 45, 77.5 },
  elToro = { 50, 80 },
}

local function buildBaseArt(t)
  vfree(t.baseArt)   -- 重建前先归还旧部件，避免控件泄漏留在场上
  local parts = {}
  local s = t.s
  for i = 1, #TANK_BASE_ART do
    local a = TANK_BASE_ART[i]
    parts[#parts + 1] = vpart("square", a[2] * s, a[3] * s, shade(t.baseColor, a[4]),
      a[5] * s, a[6] * s, a[7])
  end
  t.baseArt = parts
end

-- 各武器炮塔外观（对应原版 turret 精灵逐武器帧；每帧放置不同的 DefineShape）。
-- 坐标以「炮塔圆盘中心」为原点 (0,0)、前方 = -y，单位为 Flash px（取自反编译 SVG，
-- reference/.../tools/tank_shapes，文件名为 DefineShape 的 character id）：
--   5=bullet、14=laser、17=frag、31=gatling、36=homing、42=deathRay、49=elToro、52=mine、55=remote。
-- 每项 = { 形状, 宽, 高, 偏移x, 偏移y, 局部旋转, 明暗系数 }；圆盘统一由 turretDisc 追加在最上层。
-- electric 复用 bullet（原版电弧弹用同一炮塔帧）。
local TURRET_ART = {
  bullet = {
    { "square", 15, 34, 0, -38, 0, 0.62 },
    { "square", 6.75, 34, 0, -38, 0, 0.95 },
  },
  laser = {
    { "square", 15, 12.5, 0, -27.5, 0, 0.62 },   -- 颈
    { "square", 8, 22, -14, -42, 32, 0.62 },     -- 左外张臂
    { "square", 8, 22, 14, -42, -32, 0.62 },     -- 右外张臂
    { "square", 44, 3.5, 0, -50, 0, 0.62 },      -- 顶部横杆
    { "square", 2, 15, 0, -57.5, 0, 0.95 },      -- 中心细针
  },
  frag = {
    { "square", 20, 32.5, 0, -41.2, 0, 0.62 },   -- 炮管（宽 20）
    { "square", 9, 32.5, 0, -41.2, 0, 0.95 },
    { "square", 30, 8.3, 0, -20.9, 0, 0.5 },     -- 炮口法兰
  },
  gatling = {
    { "square", 20, 32.5, 0, -41.2, 0, 0.62 },
    { "square", 9, 32.5, 0, -41.2, 0, 0.95 },
    { "square", 25, 6.3, 0, -21.9, 0, 0.5 },     -- 法兰块
    { "square", 12.5, 10.8, 0, 27.1, 0, 0.5 },   -- 后方弹药箱
  },
  homing = {
    { "tri", 15.3, 16, 0, -55, 0, 0.85 },        -- 鼻锥
    { "square", 15.3, 24.5, 0, -35, 0, 0.95 },   -- 弹身
    { "square", 33.6, 3, 0, -21.2, 0, 0.72 },    -- 尾翼
  },
  deathRay = {
    { "square", 20, 45, 0, -38, 0, 0.62 },       -- 线圈炮管
    { "square", 35, 7.5, 0, -46.5, 0, 0.5 },     -- 三道凸环
    { "square", 35, 7.5, 0, -35.3, 0, 0.5 },
    { "square", 35, 7.5, 0, -24.0, 0, 0.5 },
    { "square", 20, 3.5, 0, -55, 0, 0.5 },       -- 末端
  },
  elToro = {
    -- 原版仅一个圆顶（r=22.5），无炮管
  },
  mine = {
    { "square", 4, 13, -9.3, -21, 20, 0.5 },     -- 上部两根尖刺
    { "square", 4, 13, 9.3, -21, -20, 0.5 },
    { "square", 4.5, 26, -16, 13, 34, 0.5 },     -- 下部两片外扫犁刃
    { "square", 4.5, 26, 16, 13, -34, 0.5 },
  },
  remote = {
    { "tri", 15.3, 16.8, 0, -57.2, 0, 0.85 },    -- 鼻锥
    { "square", 15.3, 12.3, 0, -28.9, 0, 0.95 }, -- 弹身
    { "square", 33.6, 3, 0, -21.2, 0, 0.72 },    -- 尾翼
    { "square", 5, 11, 0, 28, 0, 0.6 },          -- 底部旋钮
  },
}

-- 炮塔圆盘（各武器公共）：原版 Ø45 径向渐变（中心亮→边缘暗），
-- 平台不支持渐变，用「外→内三层同心圆」近似；圆盘最后绘制，压在武器造型之上。
local function turretDisc(parts, s, base)
  parts[#parts + 1] = vpart("circle", 45 * s, 45 * s, shade(base, 0.55), 0, 0, 0)
  parts[#parts + 1] = vpart("circle", 34 * s, 34 * s, shade(base, 0.78), 0, 0, 0)
  parts[#parts + 1] = vpart("circle", 22 * s, 22 * s, shade(base, 1.00), 0, 0, 0)
end

local function buildTurretArt(t)
  vfree(t.turretArt)
  local s = t.s
  local parts = {}
  local w = t.currentWeapon or "bullet"
  if w == "electric" then w = "bullet" end
  local art = TURRET_ART[w] or TURRET_ART.bullet
  for i = 1, #art do
    local a = art[i]
    parts[#parts + 1] = vpart(a[1], a[2] * s, a[3] * s, shade(t.baseColor, a[7]),
      a[4] * s, a[5] * s, a[6])
  end
  turretDisc(parts, s, t.baseColor)
  t.turretArt = parts
end

local PALETTE = { COLOR.P1, COLOR.P2, COLOR.P3, COLOR.P4 }

-- 鼠标操控分支（原版 frame_1 设置项 settingsUseNewMouseControl）：
--   旧分支 = 坦克瞬时对准鼠标、无倒车；新分支 = 转向受 turnSpeed 限制、近距可倒车。
-- 可在「按键设置」页运行时切换，开赛时由 applyMode 写入各坦克。
local useNewMouseControl = C.SETTINGS.useNewMouseControl or false

-- ------------------------------------------------------------
-- 对战设置（原版 settingsXXX）：把 C.SETTINGS 的常量变成**运行时可调**（G.rules）
-- ------------------------------------------------------------
-- 出箱武器开关（原版 settingsActiveWeapons：默认除 bullet 外全开）
local function initRules()
  local r = G.rules
  r.weapons = {}
  for i = 1, #C.SETTINGS.activeWeapons do r.weapons[C.SETTINGS.activeWeapons[i]] = true end
end

-- 当前生效的出箱武器列表。
--   ⚠️ 原版规则：**与 AI（莱卡）对战时强制只留 laser**
--   （frame_53 L2390-2393：`settingsActiveWeapons = new Array("laser")`）。
--   另外原版面板不允许把武器全关（全关则会随机挑一个）⇒ 这里保底留第一种。
local function rulesWeaponList()
  if G.hasAI then return { "laser" } end
  local t = {}
  for i = 1, #C.SETTINGS.activeWeapons do
    local w = C.SETTINGS.activeWeapons[i]
    if G.rules.weapons[w] ~= false then t[#t + 1] = w end
  end
  if #t == 0 then t[1] = C.SETTINGS.activeWeapons[1] end
  return t
end

local function createTank(index, cellX, cellY)
  local s = G.scale
  local t = tankApi.new({
    x = (cellX + 0.5) * s,
    y = (cellY + 0.5) * s,
    rot = tankApi.randomRotation(),
    cellScale = s,
    -- 坦克在每回合开始时才被摆进迷宫，此处用转发函数延迟取当前的墙体判定
    wallHit = function(px, py) return G.wallHit(px, py) end,
    mouseTank = false,
    settingsUseNewMouseControl = useNewMouseControl,
    settingsUseSmoothCollision = G.rules.smooth,
  })
  t.index = index
  t.baseColor = PALETTE[((index - 1) % #PALETTE) + 1]
  t.turretColor = t.baseColor
  t.currentWeapon = C.STARTWEAPON
  t.currentEquipment = "none"
  t.equipment = nil
  t.triggerReleased = true
  t.minesLayed = 0
  t.score = 0
  t.exp = 0
  t.isPlayer = (index == G.playerIndex)
  buildBaseArt(t)
  buildTurretArt(t)
  return t
end

local function disposeTank(t)
  vfree(t.baseArt)
  vfree(t.turretArt)
  t.baseArt, t.turretArt = nil, nil
end

-- ============================================================
-- ⑦ 投射物视觉
-- ============================================================
local function buildProjVisual(p)
  local k = G.scale / 50
  local parts = {}
  local c = p.color or COLOR.SHOT   -- 激光 / 死亡射线 / 各类导弹与地雷用 owner 颜色
  -- 绘制尺寸 = 贴图原生像素 × (SCALE/50)，与原版一致。
  if p.kind == "bullet" or p.kind == "electric" then
    -- 原版 bullet / electricbullet 贴图 5×5 纯黑（与 owner 颜色无关）
    parts[#parts + 1] = vpart("circle", 5 * k, 5 * k, COLOR.BULLET, 0, 0, 0)
  elseif p.kind == "gatlingBullet" then
    -- 原版 gatlingBullet 贴图 3×3 纯黑
    parts[#parts + 1] = vpart("circle", 3 * k, 3 * k, COLOR.BULLET, 0, 0, 0)
  elseif p.kind == "frag" then
    -- 原版 fragbomb 贴图（DefineSprite_217）= 7×7 纯黑实心圆
    parts[#parts + 1] = vpart("circle", 7 * k, 7 * k, COLOR.BULLET, 0, 0, 0)
  elseif p.kind == "fragment" then
    -- 原版 fragbombfragment 贴图 3×3 纯黑（略放大到 4 以免亚像素完全看不见）
    parts[#parts + 1] = vpart("tri", 4 * k, 4 * k, COLOR.BULLET, 0, 0, 0)
  elseif p.kind == "homing" or p.kind == "remote" then
    -- 原版 homingbullet / rCMissile：火箭形，本体 background 用 owner.turretColor 染色
    -- （不是固定灰），尾部另有尾翼；整体显示 ≈7.7×10.5px。
    local fin = (p.kind == "remote") and 0.5 or 0.68
    parts[#parts + 1] = vpart("tri", 5.4 * k, 3.0 * k, shade(c, 0.85), 0, -4.4 * k, 0)   -- 鼻锥
    parts[#parts + 1] = vpart("square", 5.4 * k, 7.0 * k, c, 0, -0.2 * k, 0)            -- 弹身
    parts[#parts + 1] = vpart("square", 7.7 * k, 1.6 * k, shade(c, fin), 0, 3.4 * k, 0) -- 尾翼
  elseif p.kind == "mine" then
    -- 原版 mine（DefineSprite_234）：浅色球体 + 边缘尖刺 + 中心 LED 圆（未布防蓝 / armed 绿）。
    -- 显示尺寸 ≈15.4×13.3px（贴图原生 × scaleFactor，scaleFactor = 25k/100）。
    local sf = p.scaleFactor or 0.25
    local d = 60 * sf
    local cols = {}
    local function add(shape, w, h, col, ox, oy, rot)
      parts[#parts + 1] = vpart(shape, w, h, col, ox, oy, rot)
      cols[#cols + 1] = col
    end
    add("star4", d, d, shade(c, 0.35), 0, 0, 0)          -- 尖刺（两组旋转 45° 叠加）
    add("star4", d * 0.92, d * 0.92, shade(c, 0.35), 0, 0, 45)
    local b = 45 * sf
    add("circle", b, b, c, 0, 0, 0)                      -- 球体
    add("circle", b * 0.62, b * 0.62, shade(c, 1.15), 0, 0, 0)  -- 球心高光
    p.ledPart = vpart("circle", 11 * sf, 11 * sf, COLOR.MINE_BLUE, 0, 0, 0)  -- 中心 LED
    parts[#parts + 1] = p.ledPart
    p.visCol = cols
  end
  p.vis = parts
end

local function syncProjVisual(p)
  if p.kind == "laser" then
    local holder = p.visHolder
    if holder == nil then
      holder = { segs = {} }
      p.visHolder = holder
    end
    local pts = p.linePoints or {}
    local stride = max(1, floor(#pts / 100))
    -- 原版 DefineSprite_226_laser：先画 3*(SCALE/50) 黑色阴影(alpha 30)，再画
    -- 2*(SCALE/50) 的激光色实线。平台无 alpha/描边，只保留实线宽度 2。
    polyRender(holder, pts, p.color or COLOR.SHOT, 2 * (G.scale / 50), stride)
    return
  end
  if p.kind == "deathRay" then
    local holder = p.visHolder
    if holder == nil then
      holder = { segs = {} }
      p.visHolder = holder
    end
    local pts = p.curvePoints or {}
    local s = G.scale / 50
    local wid = max(1, (p.rayThickness or 0)) * s
    -- 原版 DefineSprite_215_deathRay：lineGradientStyle 沿光束方向铺 10 段「白 ↔ 车主色」交替色带
    --   （每段 = 25/255 × 1500×S ≈ **147×S 世界像素**），且每帧把整条色带前移 5/255 × 1500×S ≈ **29×S**
    --   → 观感是「长条纹沿光束快速流动」（另叠一条 0.5× 宽、梯度反向的细线，此处从略）。
    --   平台无渐变填充 → 用「固定弧长色带 + 每帧相位前移」几何近似（旧的「逐线段交替」会变成细密斜纹，已弃用）。
    local band = 147 * s
    p.stripePhase = (p.stripePhase or 0) + 29 * s
    bandedStripes(holder, pts, p.color or COLOR.SHOT, wid, COLOR.TEXT, band, p.stripePhase)
    if p.ballSize and p.ballSize > 0 then
      if p.ball == nil then
        p.ball = vpart("circle", p.ballSize * G.scale / 50, p.ballSize * G.scale / 50,
          shade(p.color or COLOR.SHOT, 1.4), 0, 0, 0)
      end
      local ux, uy = toUI(p.originX or p.x, p.originY or p.y)
      p.ball.ctl:SetAnchoredPosition(ux, uy)
      p.ball.ctl:SetVisible(true)
    end
    return
  end
  if p.vis ~= nil then
    renderGroup(p.vis, p.x, p.y, p.rotation or 0)
    if p.kind == "mine" then
      -- 原版 mine：未布防时 _alpha 渐隐、armed 后渐显；中心 LED 未布防蓝 / armed 绿并闪烁。
      local a = p.alpha or 100
      local av = floor(255 * a / 100)
      if p.visCol ~= nil then
        for i = 1, #p.visCol do
          p.vis[i].ctl.imageColor = alphaOf(p.visCol[i], av)
        end
      end
      if p.ledPart ~= nil then
        p.blinkT = (p.blinkT or 0) + 1
        local on = floor(p.blinkT / 10) % 2 == 0
        local lc = p.armed and COLOR.MINE_GREEN or COLOR.MINE_BLUE
        if not on then lc = shade(lc, 0.4) end
        p.ledPart.ctl.imageColor = alphaOf(lc, av)
      end
    end
  end
end

-- 折线渲染：holder.segs 为段控件池。（原先的 color2/phase 交替条纹参数仅供已被替换的旧死亡射线使用，已移除；
-- 死亡射线改用 bandedStripes。）
function polyRender(holder, pts, color, widthWorld, stride)
  local n = 0
  local i = 1
  local vs = G.VS
  while i < #pts do
    local j = i + stride
    local a, b = pts[i], pts[j]
    if b == nil then break end
    n = n + 1
    local seg = holder.segs[n]
    if seg == nil then
      local ctl = acquire("square")
      if ctl == nil then break end
      seg = { ctl = ctl }
      holder.segs[n] = seg
    end
    local ax, ay = toUI(a.x, a.y)
    local bx, by = toUI(b.x, b.y)
    local dx, dy = bx - ax, by - ay
    local len = sqrt(dx * dx + dy * dy)
    pcall(function()
      seg.ctl:SetSizeDelta(len + widthWorld * vs, widthWorld * vs)
      seg.ctl.imageColor = color
    end)
    seg.ctl:SetAnchoredPosition((ax + bx) / 2, (ay + by) / 2)
    seg.ctl:SetLocalRotation(0, 0, deg(math.atan(dy, dx)))
    pcall(function() seg.ctl:SetVisible(true) end)
    i = j
  end
  for k = n + 1, #holder.segs do
    pcall(function() holder.segs[k].ctl:SetVisible(false) end)
  end
end

-- 沿折线按**固定世界弧长**铺「本色 / color2」交替色带，并按 phasePx 整体滚动。
--   用途：近似原版死亡射线的 lineGradientStyle 流动条纹（平台无渐变填充）。
--   做法：把折线按 bandLen/12 的固定弧长重采样成小段；每段颜色由「该处弧长 + 相位」落在哪条色带决定。
--   bandLen = 单条色带的世界像素长度；phasePx = 相位（世界像素；每帧递增即色带向光束末端流动）。
bandedStripes = function(holder, pts, color, widthWorld, color2, bandLen, phasePx)
  local np = #pts
  if np < 2 or bandLen <= 0 then return end
  local vs = G.VS
  local step = max(3, bandLen / 12)
  -- 累计弧长（cum[i] = 折线起点到 pts[i] 的弧长）
  local cum = { 0 }
  local total = 0
  for i = 2, np do
    local a, b = pts[i - 1], pts[i]
    local dx, dy = b.x - a.x, b.y - a.y
    total = total + sqrt(dx * dx + dy * dy)
    cum[i] = total
  end
  local n = 0
  local function emit(x0, y0, x1, y1, along)
    n = n + 1
    local seg = holder.segs[n]
    if seg == nil then
      local ctl = acquire("square")
      if ctl == nil then return end
      seg = { ctl = ctl }
      holder.segs[n] = seg
    end
    local ax, ay = toUI(x0, y0)
    local bx, by = toUI(x1, y1)
    local dx, dy = bx - ax, by - ay
    local len = sqrt(dx * dx + dy * dy)
    local c = color
    -- 相位**减**：相位递增 ⇒ 色带边界向「弧长更大」的方向（光束末端）移动 = 向外发射
    --   （原版是 fractions 每帧 -5，同样是向末端流动；写成加号会变成"吸收光线"）
    if floor((along - phasePx) / bandLen) % 2 ~= 0 then c = color2 end
    pcall(function()
      seg.ctl:SetSizeDelta(len + widthWorld * vs, widthWorld * vs)
      seg.ctl.imageColor = c
    end)
    seg.ctl:SetAnchoredPosition((ax + bx) / 2, (ay + by) / 2)
    seg.ctl:SetLocalRotation(0, 0, deg(atan(dy, dx)))
    pcall(function() seg.ctl:SetVisible(true) end)
  end
  local px, py = pts[1].x, pts[1].y
  local i = 2
  local d = step
  while d < total do
    while i <= np and cum[i] < d do i = i + 1 end
    if i > np then break end
    local a, b = pts[i - 1], pts[i]
    local sl = cum[i] - cum[i - 1]
    local t = (sl > 1e-9) and ((d - cum[i - 1]) / sl) or 0
    local ex = a.x + (b.x - a.x) * t
    local ey = a.y + (b.y - a.y) * t
    emit(px, py, ex, ey, d)
    px, py = ex, ey
    d = d + step
  end
  emit(px, py, pts[np].x, pts[np].y, total)   -- 收尾到折线终点
  for k = n + 1, #holder.segs do
    pcall(function() holder.segs[k].ctl:SetVisible(false) end)
  end
end

-- 画一组「互不相连」的短线段（虚线用）：dashes[i] = { ax, ay, bx, by }。
-- polyRender 只能画连续折线（相邻段共享端点），无法表达原版 aimer 的断开虚线，
-- 故单独提供：每段独立占用一个 square 控件，多余的隐藏。
local function dashRender(holder, dashes, color, widthWorld)
  local vs = G.VS
  local n = 0
  for i = 1, #dashes do
    local d = dashes[i]
    n = n + 1
    local seg = holder.segs[n]
    if seg == nil then
      local ctl = acquire("square")
      if ctl == nil then break end
      seg = { ctl = ctl }
      holder.segs[n] = seg
    end
    local ax, ay = toUI(d.ax, d.ay)
    local bx, by = toUI(d.bx, d.by)
    local dx, dy = bx - ax, by - ay
    local len = sqrt(dx * dx + dy * dy)
    pcall(function()
      seg.ctl:SetSizeDelta(len + widthWorld * vs, widthWorld * vs)
      seg.ctl.imageColor = color
    end)
    seg.ctl:SetAnchoredPosition((ax + bx) / 2, (ay + by) / 2)
    seg.ctl:SetLocalRotation(0, 0, deg(atan(dy, dx)))
    pcall(function() seg.ctl:SetVisible(true) end)
  end
  for k = n + 1, #holder.segs do
    pcall(function() holder.segs[k].ctl:SetVisible(false) end)
  end
end

local function freeProjVisual(p)
  if p.vis ~= nil then vfree(p.vis); p.vis = nil end
  if p.visHolder ~= nil then
    for i = 1, #p.visHolder.segs do
      release("square", p.visHolder.segs[i].ctl)
    end
    p.visHolder = nil
  end
  if p.ball ~= nil then
    release("circle", p.ball.ctl)
    p.ball = nil
  end
end

-- ============================================================
-- ⑧ 特效（烟雾 / 碎片 / 闪光）
-- ============================================================
-- 效果种类 → 部件形状
local EFFECT_SHAPE = {
  smoke = "circle",   -- 烟
  frag  = "tri",      -- 碎片 / 残骸
  flash = "star4",    -- 炮口闪光 / 火花
  burst = "star5",    -- 爆炸星芒
}

local function spawnEffect(kind, x, y, color, size, life, vx, vy, grow, aMax)
  local e = {
    kind = kind, x = x, y = y, vx = vx or 0, vy = vy or 0,
    life = life, lifeMax = life, color = color, size = size, rot = 0,
    spin = (kind == "frag" or kind == "burst") and (math.random() * 24 - 12) or 0,
    grow = grow or 0, aMax = aMax or 255,
  }
  e.vis = { vpart(EFFECT_SHAPE[kind] or "square", size, size, color, 0, 0, 0) }
  G.effects[#G.effects + 1] = e
  return e
end

local function freeEffect(e)
  if e.vis ~= nil then vfree(e.vis); e.vis = nil end
end

local function stepEffects()
  local vs = G.VS
  for i = #G.effects, 1, -1 do
    local e = G.effects[i]
    e.life = e.life - 1
    if e.life <= 0 then
      freeEffect(e)
      table.remove(G.effects, i)
    else
      e.x = e.x + e.vx
      e.y = e.y + e.vy
      e.rot = e.rot + e.spin
      local t = e.life / e.lifeMax
      local a = floor(e.aMax * t)
      local p = e.vis[1]
      if p ~= nil then
        if e.grow ~= 0 then
          -- 拖尾等粒子随生命膨胀（原版逐帧 _xscale += 2）
          local sc = 1 + e.grow * (1 - t)
          p.ctl:SetSizeDelta(e.size * sc * vs, e.size * sc * vs)
        end
        p.ctl.imageColor = alphaOf(e.color, a)
        local ux, uy = toUI(e.x, e.y)
        p.ctl:SetAnchoredPosition(ux, uy)
        p.ctl:SetLocalRotation(0, 0, e.rot)
      end
    end
  end
end

-- ============================================================
-- ⑨ ctx 组装
-- ============================================================
local ctx

local function rebuildCtxLists()
  local bullets, frags, fragFrag, gatling = {}, {}, {}, {}
  for i = 1, #G.projectiles do
    local p = G.projectiles[i]
    if p.kind == "bullet" then bullets[#bullets + 1] = p
    elseif p.kind == "frag" then frags[#frags + 1] = p
    elseif p.kind == "fragment" then fragFrag[#fragFrag + 1] = p
    elseif p.kind == "gatlingBullet" then gatling[#gatling + 1] = p
    end
  end
  ctx.bullets = bullets
  ctx.frags = frags
  ctx.fragFragments = fragFrag
  ctx.gatlingBullets = gatling
  ctx.crates = G.crates
  ctx.tanks = G.tanks
  ctx.tankCount = #G.tanks
  local alive = 0
  ctx.tankFields = {}
  for i = 1, #G.tanks do
    local t = G.tanks[i]
    if t.alive then alive = alive + 1 end
    ctx.tankFields[i] = { x = floor(t.x / G.scale), y = floor(t.y / G.scale) }
  end
  ctx.aliveCount = alive
  ctx.numberOfCrates = #G.crates
  ctx.reachable = G.reachable
  ctx.reachableIndex = G.reachableIndex
end

local function makeCtx()
  ctx = {
    scale = G.scale,
    maze = G.maze,
    deadEnds = G.deadEnds,
    pathApi = mazeApi,
    settingsMaxBullets = G.rules.maxBullets,
    -- round.pickCratePos 需要的上下文
    settings = G.rules,
    crateSpawnPoints = {},   -- 无自定义迷宫，恒为空
    reachable = G.reachable,
    reachableIndex = G.reachableIndex,
    numberOfCrates = 0,
    wallHit = function(px, py) return G.wallHit(px, py) end,
    insideMaze = function(px, py)
      return px >= 0 and py >= 0 and px <= G.W * G.scale and py <= G.H * G.scale
    end,
    tankContains = function(t, px, py) return weaponsApi.makeTankContains(t)(px, py) end,
    tankShapeContains = function(t, px, py) return weaponsApi.makeTankContains(t)(px, py) end,
    tankBaseContains = function(t, px, py) return weaponsApi.makeTankBaseContains(t)(px, py) end,
    tankBBoxContains = function(t, px, py) return weaponsApi.makeTankBaseContains(t)(px, py) end,
    tankExpandedHit = function(t, part, k)
      local hp = t.hitPoints and t.hitPoints[part]
      if hp == nil then return false end
      return tankApi.expandedHitCheck(t, hp, k)
    end,
    fieldOf = function(cx, cy) return fieldOf(cx, cy) end,
    distAt = function(fx, fy, cx, cy)
      local f = fieldOf(fx, fy)
      local colT = f and f[cx]
      return colT and colT[cy]
    end,
    distancesForMaze = nil,   -- 在 setupRound 中挂 lazy 代理
    getShortestPathWithDistances = function(sx, sy, ex, ey)
      return mazeApi.getShortestPathWithDistances(G.maze, fieldOf(sx, sy), sx, sy, ex, ey)
    end,
    -- 世界写入
    spawn = function(p)
      G.projectiles[#G.projectiles + 1] = p
      buildProjVisual(p)
      muzzleFlash(p)
    end,
    onHit = function(owner, victim) onHit(owner, victim) end,
    setWeapon = function(owner, w) setWeapon(owner, w) end,
    setEquipment = function(owner, eq) owner.currentEquipment = eq end,
    -- ★ 源代码彩蛋（source-code Easter egg）：原版 `setEquipment` 的 AS2 switch **穿透（fall-through）笔误**，
    --   原样留存凭吊。原文 reference/.../game_scripts/scripts/frame_58/DoAction.as L1808-1820：
    --     function setEquipment(owner, equ) {
    --        owner.equipment.removeMovieClip();
    --        owner.currentEquipment = equ;
    --        switch(equ) {
    --           case "none":
    --           case "aimer":                       // ← "none" 少了 break，直接落进这一条
    --              owner.equipment = _root.addAimer(owner);
    --           default: return;                    // ← 赋值后还要再落进 default 才 return
    --        }
    --     }
    --   后果：出生时的 `setEquipment(owner,"none")` 也会挂一个「激光弹道预览」aimer；而全工程唯一**显式**的
    --   `setEquipment(owner,"aimer")` 在 `setWeapon` 的 `case "laser":` 分支里 → 作者本意其实是「仅激光才有预览」。
    --   我们**不重现这个副作用**（预览已按 `currentWeapon == "laser"` 门控，见 renderAimers）；
    --   下面这个函数只忠实保留「两条 case 合并」的判定结果，**没有任何调用点**，纯彩蛋、零副作用。
    originalEquipmentFallthrough = function(equ)
      -- 对应上方 `case "none":` 与 `case "aimer":` 因缺 break 而合并成同一分支：两者都会 addAimer。
      return equ == "none" or equ == "aimer"
    end,
    -- 震屏统一走 battle.shake（round.step 每帧据此产生偏移并衰减）
    shake = function(v)
      if G.battle ~= nil then
        G.battle.shake = roundApi.addShake(G.battle.shake, v)
      end
    end,
    -- 遥控导弹转向：原版用 ctx.keyDown(owner.KEYTURNLEFT/KEYTURNRIGHT)（AS2 全局键码）。
    -- 平台键码与玩家可自定义的键位解耦，故改为直接回读 owner 当前控制方式下的左右转键。
    turnInput = function(owner)
      if owner == nil then return false, false end
      if owner.touchPad then
        -- 触屏玩家：遥控弹转向读摇杆左右
        local st = G.tstick[owner.touchPlayer]
        local d = (st ~= nil) and st.dir or nil
        return (d ~= nil and d.left) == true, (d ~= nil and d.right) == true
      end
      if owner.padTank then return G.gp.left, G.gp.right end
      if owner.mouseTank then return false, false end
      local inp = G.pinputs[owner.controlIndex]
      if inp == nil then inp = G.input end
      return inp.left, inp.right
    end,
    -- 鼠标位置（原版 GameTank frame_1 用 _root.xMouse/yMouse 再 mazemc.globalToLocal）：
    -- game.GetCursorUIPos 给的是「以画布左下角为原点」的 UI 坐标（⚠️ 官方 API 文档未写明原点，
    -- 此处按真机实测；写明「左下角为原点」的是另一个 API `CursorEventData:GetUIPos`），先平移到画布中心得到
    -- 本项目 toUI 的坐标系，再做 toUI 的逆变换还原成迷宫局部像素（含镜头 gameX/gameY 与震屏）。
    mousePos = function(owner)
      -- 触屏「朝向我」手感：虚拟光标 = 坦克位置 + 摇杆方向 × 距离（世界 px，y 向下）。
      -- 摇杆越推越远 → stepMouse 的「短距仅转向、长距转向并前进」自然生效。
      if owner ~= nil and owner.touchPad == true and G.touchHandfeel == "aim" then
        local st = G.tstick[owner.touchPlayer]
        if st ~= nil and st.active and (st.ratio or 0) > G.tcfg.dead then
          local m = sqrt(st.vx * st.vx + st.vy * st.vy)
          if m > 1e-3 then
            local len = G.tcfg.aimLen * ((st.ratio - G.tcfg.dead) / (1 - G.tcfg.dead))
            return owner.x + st.vx / m * len, owner.y - st.vy / m * len
          end
        end
        return owner.x, owner.y
      end
      local ok, cx, cy = pcall(function() return game.GetCursorUIPos() end)
      if not ok or cx == nil or cy == nil then return -99999, -99999 end
      local vw, vh = 0, 0
      pcall(function() vw, vh = game.GetUICanvasSize() end)
      -- ÷ 整体缩放：host 被 SetLocalScale(k) 后，画布坐标 = 本项目 UI 坐标 × k
      local k = G.uiScale or 1
      local ux, uy = (cx - vw / 2) / k, (cy - vh / 2) / k
      local px = (ux - G.shakeX) / G.VS + STAGE_W / 2 - G.gameX
      local py = STAGE_H / 2 - ((uy - ARENA_OY) - G.shakeY) / G.VS - G.gameY   -- 与 toUI 的 ARENA_OY 对应
      return px, py
    end,
    -- 纯视觉回调
    smoke = function(kind, p, n) visualSmoke(kind, p, n) end,
    particles = function(kind, p) visualParticles(kind, p) end,
    spark = function(p1, p2) visualSpark(p1, p2) end,
    sound = function(name) playSound(name) end,
  }
  return ctx
end

-- ============================================================
-- ⑩ 视觉回调实现
-- ============================================================
-- 炮口闪光：仅在实弹类投射物出生瞬间出现一帧四芒星
local MUZZLE_KINDS = {
  bullet = true, gatlingBullet = true, frag = true,
  homing = true, remote = true,
}
function muzzleFlash(p)
  if p == nil or not MUZZLE_KINDS[p.kind] then return end
  local k = G.scale / 50
  spawnEffect("flash", p.x, p.y, COLOR.FLAME, (11 + math.random() * 4) * k, 4, 0, 0)
end

function visualSmoke(kind, p, n)
  local k = G.scale / 50
  if kind == "homing" or kind == "remote" then
    -- 原版 homingbullet / rCMissile 的拖尾（DefineSprite_225 / 237）：
    -- 每帧在「弹尾后方 8px」出烟，初速方向与导弹相反，颜色随机灰（homing 锁定后
    -- 有一半概率取目标色），粒子逐帧膨胀、淡出。宽度 lineStyle 4*(SCALE/50)。
    local iv = p.intervals or 1
    local len = sqrt(p.xSpeed * p.xSpeed + p.ySpeed * p.ySpeed)
    local ux, uy
    if len > 0.0001 then
      ux, uy = p.xSpeed / len, p.ySpeed / len
    else
      local r = (p.rotation or 0) * RAD
      ux, uy = sin(r), -cos(r)
    end
    for _ = 1, n do
      local c = COLOR.SMOKE
      if kind == "homing" and p.homing and math.random() > 0.5 then
        c = p.targetColor or COLOR.SMOKE
      end
      local jx = (math.random() - 0.5) * 4 * k
      local jy = (math.random() - 0.5) * 4 * k
      spawnEffect("smoke", p.x - ux * 8 * k + jx, p.y - uy * 8 * k + jy, c,
        4 * k, 6 + floor(math.random() * 5),
        -p.xSpeed * iv + jx * 2, -p.ySpeed * iv + jy * 2,
        1.5, 55)
    end
    return
  end
  for _ = 1, n do
    local ang = math.random() * 2 * PI
    local sp = (0.3 + math.random() * 0.7) * k
    spawnEffect("smoke", p.x, p.y, COLOR.SMOKE,
      (6 + math.random() * 6) * k, 12 + floor(math.random() * 8),
      cos(ang) * sp, sin(ang) * sp)
  end
end

function visualParticles(kind, p)
  if math.random() > 0.5 then return end
  local k = G.scale / 50
  spawnEffect("smoke", p.x, p.y, shade(p.color or COLOR.SHOT, 1.2),
    4 * k, 6, 0, 0)
end

function visualSpark(p1, p2)
  if p1 == nil or p2 == nil then return end
  if G.sparkHolder == nil then G.sparkHolder = { segs = {} } end
  polyRender(G.sparkHolder, { { x = p1.x, y = p1.y }, { x = p2.x, y = p2.y } },
    col(180, 220, 255), 2 * (G.scale / 50), 1)
  G.sparkLife = 2
end

-- ============================================================
-- ⑪.5 外围系统接入：本地音频 / 服务器信号 / 成就上报
-- ============================================================
-- 音效 ID 表：键名为音效名，值为编辑器里配置的音频 ID（未配置则静默）。
-- 需与 src/audio.lua 使用同一套名称；例：SOUND_IDS = { fire = 1001, explode = 1002 }
-- 编辑器侧的音效索引是固定的（不像控件模板那样每关各异），故可直接填数字。
-- 键名 = 原版资源名；行尾「← N」是该资源在原版解包目录里的编号（对照见 编辑器侧配置清单.md §1.4）。
-- 未列出的键名 = 用户实测「二进制文件 / 无声音」或暂未选定 → 保持静默（代码里的触发点仍在）。
local SOUND_IDS = {
  soundMineLand          = 50915,   -- ← 2
  soundHomingFire        = 40091,   -- ← 3
  soundLaser             = 40111,   -- ← 8
  soundExplosion3        = 40118,   -- ← 9  soundFragBomb
  soundMineActivate      = 50151,   -- ← 10
  soundExplosion         = 40194,   -- ← 14 explosion5（坦克摧毁·其一）
  soundRemoteSignal      = 40007,   -- ← 15
  soundBullet            = 50880,   -- ← 16
  soundFragment          = 50882,   -- ← 17
  soundMineDetonate      = 40050,   -- ← 18 soundMineDetonateCharge
  soundExplosion2        = 50865,   -- ← 20 explosion3（坦克摧毁·其二）
  soundMineArm           = 50945,   -- ← 21
  soundDeathRayCharge    = 40023,   -- ← 25
  soundDeathRayFire      = 40087,   -- ← 26
  soundGatlingMotor      = 40301,   -- ← 27（循环音，平台无循环 → 满转播一次）
  soundGatlingMotorStart = 40302,   -- ← 28
  -- BGM（**临时**：menu / battle 先共用同一条曲子；切换时不会重启，见 src/audio.lua）
  menu                   = 10104,
  battle                 = 10104,
}
local audioClock = 0   -- 秒，由 OnLevelUpdate 推进，供 audio 模块做同类音效最小间隔

-- 绑定音频后端：真机走 game.PlayAudio2D / game.StopAudio；未配置音频 ID 时全程静默
local function bindAudioBackend()
  audioApi.bind({
    now    = function() return audioClock end,
    -- 防御：万一某环境下 PlayAudio2D 不可用，也不要让音效把主循环搞崩（静默即可）
    play2d = function(id)
      local ok, h = pcall(game.PlayAudio2D, id)
      if ok then return h end
      return nil
    end,
    stop   = function(h) pcall(game.StopAudio, h) end,
  })
  for name, id in pairs(SOUND_IDS) do audioApi.register(name, id) end
end

function playSound(name)
  audioApi.playSfx(name)
end

-- 绑定服务器信号：客户端 → 服务器上报；单机（无联机服务器）时 SendSignal 无效但安全
local function bindNet()
  netApi.bind({
    -- 防御：单机 / 单测环境可能没有 ServerSignal，返回 nil 让 emit 安全失败
    server = function(name)
      if game.ServerSignal == nil then return nil end
      local h = nil
      pcall(function() h = game.ServerSignal(name) end)
      -- ⚠️ 信号句柄取不到 = 该上报**根本没发出去**（最常见原因：信号管理器里没建同名信号）。
      --   每个名字只告警一次（避免刷屏）；状态存在 G.sigWarned 上而不是新开顶层 local（主 chunk 预算）。
      if h == nil then
        G.sigWarned = G.sigWarned or {}
        if not G.sigWarned[name] then
          G.sigWarned[name] = true
          print("[坦克动荡] ⚠️ 取不到信号句柄：" .. tostring(name)
            .. " ⇒ 这次上报**没有发出去**。请到「千星沙箱 → 信号管理器」确认已建同名信号（名字一字不差）。")
        end
      end
      return h
    end,
  })
  -- 服务器 → 客户端：排行榜名次 / 段位等下发，本地单机不会触发
  pcall(function()
    script:RegisterServerSignalHandler(netApi.SIG.MATCH, function(sig, params)
      local n = 0
      if params ~= nil then n = #params end
      print("[坦克动荡] 收到服务器信号 " .. tostring(sig) .. "，参数数=" .. tostring(n))
    end)
  end)
  -- 联机：某玩家逃跑/离开战场 → 该玩家判负，对方直接胜利。
  --   ⚠️ 客户端 Lua **没有**「玩家离开关卡」事件（官方事件节点清单无此项）；
  --   故由编辑器侧节点图（平台自身的逃跑/结算流程，或用「设置玩家逃跑合法性」配合）检测后，
  --   向本端下发 TT2_LEAVE（第 1 个参数 = 逃跑玩家的玩家序号，1 基），本端据此判负。
  pcall(function()
    script:RegisterServerSignalHandler(netApi.SIG.LEAVE, function(sig, params)
      local idx = 1
      pcall(function()
        if params ~= nil and params[1] ~= nil then idx = tonumber(params[1]) or 1 end
      end)
      print("[坦克动荡] 收到逃跑信号，逃跑玩家=" .. tostring(idx))
      if MENU ~= nil and MENU.onPlayerEscaped ~= nil then MENU.onPlayerEscaped(idx) end
    end)
  end)
  -- 联机延迟探测：服务器把 TT2_PING 的参数**原样回发**，本端据此算往返时间（见 MENU.pingSend/onPong）。
  pcall(function()
    script:RegisterServerSignalHandler(netApi.SIG.PING, function(sig, params)
      local v = nil
      pcall(function() if params ~= nil then v = params[1] end end)
      if MENU ~= nil and MENU.onPong ~= nil then MENU.onPong(v) end
    end)
  end)
  -- 联机离散事件（P3）：服务器把 TT2_EVENT 转发给相关玩家（整数列表）。
  pcall(function()
    script:RegisterServerSignalHandler(netApi.SIG.EVENT, function(sig, params)
      local v = nil
      pcall(function() if params ~= nil then v = params[1] end end)
      if MENU ~= nil and MENU.onEvent ~= nil then MENU.onEvent(v) end
    end)
  end)
  -- 联机槽位（P1）：服务器**逐个**告诉每个玩家「你是几号」（参数 = 玩家序号，1 基）。
  pcall(function()
    script:RegisterServerSignalHandler(netApi.SIG.SLOT, function(sig, params)
      local v = nil
      pcall(function() if params ~= nil then v = params[1] end end)
      if MENU ~= nil and MENU.onSlot ~= nil then MENU.onSlot(v) end
    end)
  end)
end

-- 新解锁成就 → 逐个上报（原版 unlockAchievement 的本地等价）
local function reportNewAch(ids)
  if ids == nil then return end
  for i = 1, #ids do netApi.reportAchievement(ids[i]) end
end

-- 回合战绩 → 上报（原版 unsentRoundsCompleted 等字段的本地等价）
local function reportStats()
  netApi.reportRound(statsApi.payload(G.stats))
end

-- ============================================================
-- ⑪ 武器切换 / 命中 / 击杀
-- ============================================================
function setWeapon(owner, w)
  owner.currentWeapon = w
  local dim = TURRET_DIMS[w] or TURRET_DIMS.bullet
  tankApi.setTurretSize(owner, dim[1], dim[2])
  if w == "bullet" then owner.minesLayed = 0 end
  if w == "laser" then owner.currentEquipment = "aimer" end
  buildTurretArt(owner)
end

function onHit(owner, victim)
  if victim == nil or not victim.alive then return end
  killTank(victim, owner)
end

function killTank(victim, source)
  victim.alive = false
  -- 音效**最先**发出；原版 destroyTank 同时播 soundExplosion + soundExplosion2（两层叠加）
  playSound("soundExplosion")
  playSound("soundExplosion2")
  vfree(victim.turretArt)
  victim.turretArt = nil
  -- 爆炸特效
  local k = G.scale / 50
  -- 中心星芒（五角星），随生命衰减放大
  spawnEffect("burst", victim.x, victim.y, shade(COLOR.FLAME, 1.15), 34 * k, 12, 0, 0)
  for _ = 1, 14 do
    local ang = math.random() * 2 * PI
    local sp = (1 + math.random() * 3) * k
    spawnEffect("frag", victim.x, victim.y, shade(victim.baseColor, 1.1),
      8 * k, 12 + floor(math.random() * 10), cos(ang) * sp, sin(ang) * sp)
  end
  for _ = 1, 8 do
    spawnEffect("smoke", victim.x, victim.y, COLOR.SMOKE,
      (8 + math.random() * 8) * k, 16, 0, -0.5 * k)
  end
  ctx.shake(7)
  roundApi.onTankKilled(G.battle)
  registerKill(victim, source)
  -- 联机（P3）：只上报「自己」阵亡（避免事件回环）；对手阵亡由对手端自行上报
  if G.online and victim.index == G.playerIndex then
    MENU.sendEvent(onlineApi.EV.DIED, G.playerIndex)
  end
end

-- ============================================================
-- ⑫ 回合流程
-- ============================================================
local function clearProjectiles()
  for i = 1, #G.projectiles do freeProjVisual(G.projectiles[i]) end
  G.projectiles = {}
end

local function clearCrates()
  for i = 1, #G.crates do
    local c = G.crates[i]
    if c.cell ~= nil then c.cell.used = false end
    if c.vis ~= nil then vfree(c.vis) end
  end
  G.crates = {}
end

local function clearEffects()
  for i = 1, #G.effects do freeEffect(G.effects[i]) end
  G.effects = {}
end

-- 逐武器字形（原版补给箱逐帧矢量，见 reference/.../tools/crate_dump/*.svg）。
-- 平台只有 square/circle/tri/star4/star5/rings 六种图元、且不能描边，复杂折线/弧线
-- 只能用多个图元拼近似。
-- 字形几何取自原版反编译帧 SVG（`reference/.../tools/crate_dump/*.svg`），
-- 条目 = { 形状, 宽(px), 高(px), 旋转(度), 中心x(px), 中心y(px) }，
-- 单位为原生 Flash 像素（原点 = 字形中心，x 向右、y 向下），与箱体同尺度放置
-- （原版箱体外框 ±10px = ±1.0r ⇒ 1 SVG px = 0.1r 世界像素，见 buildCrateVisual）。
local CRATE_GLYPH = {
  -- 3.svg 闪电（7×17）：一条连笔折线（三段共享端点），形似「Ƨ」。
  laser = {
    { "square", 6.73, 3.0, -48.4,  0.75, -4.5 },
    { "square", 5.00, 3.0,  53.1,  0.00,  0.0 },
    { "square", 6.73, 3.0, -48.4, -0.75,  4.5 },
  },
  -- 4.svg 六芒爆裂（14.3×16.5）：原版是 6 尖星，用两枚四芒星叠 45° 近似。
  frag = {
    { "star4", 16.5, 16.5,  0, 0, 0 },
    { "star4", 16.5, 16.5, 45, 0, 0 },
  },
  -- 5.svg 六圆点（12.8×11.55）：6 个点绕正六边形排列（原为泪滴形，用圆近似）。
  gatling = {
    { "circle", 3.2, 3.2, 0,  2.41, -4.10 },
    { "circle", 3.2, 3.2, 0,  5.00,  0.05 },
    { "circle", 3.2, 3.2, 0,  2.36,  4.15 },
    { "circle", 3.2, 3.2, 0, -2.36,  4.15 },
    { "circle", 3.2, 3.2, 0, -4.75,  0.00 },
    { "circle", 3.2, 3.2, 0, -2.41, -4.10 },
  },
  -- 6.svg 火箭（9.5×13.1）：鼻锥（三角，尖朝上）+ 弹身（方）+ 尾翼（宽底三角），三件连通成整体。
  homing = {
    { "tri",    4.29, 5.25, 0, 0.00, -3.92 },
    { "square", 4.29, 3.50, 0, 0.00,  0.45 },
    { "tri",    9.50, 4.35, 0, 0.00,  4.38 },
  },
  -- 8.svg 三条横杠（13×13）：死亡射线。
  deathRay = {
    { "square", 13.0, 3.0, 0, 0, -5.0 },
    { "square", 13.0, 3.0, 0, 0,  0.0 },
    { "square", 13.0, 3.0, 0, 0,  5.0 },
  },
  -- 9.svg 地雷（13.8×11.95）：圆胖球身 + 顶部三刺 + 左右横刺 + 底部两角（≠ 破片弹的星形）。
  mine = {
    { "circle", 10.0, 10.0, 0,  0.0, -0.4 },
    { "square",  1.8,  3.2, 0, -3.0, -5.0 },
    { "square",  1.8,  4.0, 0,  0.0, -5.4 },
    { "square",  1.8,  3.2, 0,  3.0, -5.0 },
    { "square",  3.0,  1.8, 0, -5.0, -1.8 },
    { "square",  3.0,  1.8, 0,  5.0, -1.8 },
    { "square",  1.6,  2.6, 0, -2.2,  4.8 },
    { "square",  1.6,  2.6, 0,  2.2,  4.8 },
  },
  -- 10.svg wifi（14×10.8）：以底部信号点为圆心的两条同心弧（外大内小、开口朝下）+ 信号点。
  -- 弧由「沿圆弧切向摆放的短方块」拼成，见紧随本表之后的构建段（CRATE_GLYPH.remote）。
}

-- wifi 弧构建：原版 10.svg 的弧是**以底部信号点为圆心**的同心圆弧
-- （内弧 R≈4.2 扫 ±36°、外弧 R≈8.3 扫 ±45°，线宽≈2.2，均开口朝下）+ 一个信号点。
-- 平台无矢量弧 → 用短方块逐段拼：把方块当切线段摆放（长轴 = 圆弧切线、随参数角旋转），
-- 段数够多时视觉即连续圆弧。切向角恰等于参数角 t（以正上方为 0°、向右为正），
-- 位置 = (R·sin t, 3.81 − R·cos t)（SVG 坐标，ly 向下为正）。
do
  local function arcSegs(R, sweep, n, width)
    local step = 2 * sweep / n
    local len  = 2 * R * sin(0.5 * step * RAD) * 1.35   -- 单段弦长（×1.35 让相邻段略带重叠，无缝隙）
    local out  = {}
    for i = 1, n do
      local t = -sweep + (i - 0.5) * step
      out[#out + 1] = { "square", len, width, t,
                        R * sin(t * RAD), 3.81 - R * cos(t * RAD) }
    end
    return out
  end
  local arcs = {}
  local inner = arcSegs(4.2, 36, 6, 2.2)
  local outer = arcSegs(8.3, 45, 8, 2.2)
  for i = 1, #inner do arcs[#arcs + 1] = inner[i] end
  for i = 1, #outer do arcs[#arcs + 1] = outer[i] end
  arcs[#arcs + 1] = { "circle", 2.60, 2.60, 0, 0.00, 3.85 }   -- 信号点（原版弧心）
  CRATE_GLYPH.remote = arcs
end

-- 建一套补给箱图元：外框 + 内嵌方环线 + 内面板 + 深色武器字形。
-- 结构还原自原版 1.svg：外框(±8~±10) / 方环线 #8d8d8d(±7~±8) / 内面板(±7)。
-- r = 半边长（世界像素）。每个部件记下基准尺寸 bw/bh，供弹入缩放动画逐帧重设。
local function buildCrateVisual(weapon, r)
  local specs = {
    { "square", r * 2.0, r * 2.0, COLOR.CRATE,      0, 0, 0 },
    { "square", r * 1.6, r * 1.6, COLOR.CRATE_RING, 0, 0, 0 },
    { "square", r * 1.4, r * 1.4, COLOR.CRATE,      0, 0, 0 },
  }
  local gs = r * 0.1   -- 字形缩放：原版箱体外框 ±10px = ±1.0r ⇒ 1 SVG px = 0.1r 世界像素
  local glyph = CRATE_GLYPH[weapon] or { { "square", 6.0, 6.0, 0, 0, 0 } }
  for i = 1, #glyph do
    local it = glyph[i]
    specs[#specs + 1] = { it[1], gs * it[2], gs * it[3], COLOR.CRATE_B,
                          it[4] or 0, (it[5] or 0) * gs, (it[6] or 0) * gs }
  end
  local vis = {}
  for i = 1, #specs do
    local s = specs[i]
    local p = vpart(s[1], s[2], s[3], s[4], s[6], s[7], s[5])
    if p ~= nil then
      p.bw, p.bh = s[2], s[3]
      vis[#vis + 1] = p
    end
  end
  return vis
end

-- 生成时的扬尘（原版 spawnCrate 尾部的 puff clouds）
local function cratePuff(x, y, n)
  local k = G.scale / 50
  for _ = 1, n do
    spawnEffect("smoke", x, y, alphaOf(COLOR.CRATE_DUST, 200),
      (8 + math.random() * 6) * k, 10,
      (math.random() * 2 - 1) * k, (math.random() * 2 - 1) * k)
  end
end

-- ⚠️ 补给箱的三个联机辅助（`MENU.spawnCrateAt` / `MENU.uploadCrates` / `MENU.syncCrateMirror`）
--   挂在 `MENU` 表上、定义在 `MENU` 表字面量之后 —— 顶层 local 每多一个都要计入主 chunk 上限
--   （见 AGENTS.md §0），故此处不新开 local。
-- **只有房主（或单机）** 会调它：本地随机刷箱。联机时**房主是补给箱的唯一权威**。
local function trySpawnCrate()
  local pos = roundApi.pickCratePos(ctx)
  if pos == nil then return end
  local cell = G.reachable[pos]
  if cell == nil then return end
  cell.used = true
  local weapon = roundApi.pickCrateWeapon(rulesWeaponList())
  if weapon == nil then cell.used = false; return end
  G.crateSeq = (G.crateSeq or 0) + 1
  MENU.spawnCrateAt(cell, weapon, G.crateSeq, cell.x, cell.y)
  if G.online then G.crateDirty = true end        -- 房主：权威表变了 ⇒ 待上传
end

local function syncCrates()
  for i = #G.crates, 1, -1 do
    local c = G.crates[i]
    -- 拾取判定（原版 Crate/DefineSprite_13_crate/frame_1）：
    -- 箱子局部 ±10 像素的四角经 _xscale = targetScale/100 变换到舞台 ⇒ ±0.15*SCALE，
    -- 与 SCALE 成比例（不是固定 10 像素），且要求该坦克 currentWeapon == "bullet"
    -- （后半条已由 src/round.lua M.tryPickup 保证）。
    local picked = roundApi.tryPickup(c, G.tanks, {
      boxContains = function(t, px, py) return ctx.tankBBoxContains(t, px, py) end,
      corners = function(t, cr)
        local r = G.scale * 0.15
        return { { cr.x - r, cr.y - r }, { cr.x + r, cr.y - r },
                 { cr.x - r, cr.y + r }, { cr.x + r, cr.y + r } }
      end,
    })
    if picked ~= nil then
      -- 联机：拾取事件带上 **crateId** —— 两端据此删掉**同一个**箱子。
      if G.online and picked.index ~= nil then
        MENU.sendEvent(onlineApi.EV.PICK, picked.index, c.id or 0, onlineApi.weaponId(c.weapon))
      end
      setWeapon(picked, c.weapon)
      -- 房主/单机：本地就是权威 ⇒ 立刻移除并标记待上传；
      -- 非房主：**不本地删**（等房主把权威表更新下来再删，免得「本地删掉又被表加回来」）。
      if (not G.online) or MENU.isMazeHost() then
        if c.cell ~= nil then c.cell.used = false end
        vfree(c.vis)
        table.remove(G.crates, i)
        if G.online then G.crateDirty = true end
      end
    else
      -- 弹入动画（原版：_xscale 每帧 +scaleSpeed，越过 targetScale 后减去 scaleSpeedDiff 回弹，
      -- 再降到 targetScale 以下时 snap 到 targetScale 并喷落地扬尘；无「旋转归位」动画）。
      if not c.landed then
        c.k = c.k + c.kSpeed
        if c.k > 1 then c.kSpeed = c.kSpeed - c.kDiff end
        if c.k < 1 and c.kSpeed < 0 then
          c.k, c.kSpeed, c.landed = 1, 0, true
          cratePuff(c.x, c.y, 3)
          playSound("soundCrateLand")   -- 原版定义了 soundCrateLand（反编译里只见定义、未找到调用点，一并接上）
        end
      end
      local vs = G.VS
      -- 部件局部偏移随箱子整体旋转（与 renderGroup 同一约定），再叠加到世界中心。
      local th = c.rot * RAD
      local cs, sn = cos(th), sin(th)
      for j = 1, #c.vis do
        local p = c.vis[j]
        p.ctl:SetSizeDelta(p.bw * c.k * vs, p.bh * c.k * vs)
        if p.lx ~= 0 or p.ly ~= 0 then
          local ux, uy = toUI(c.x + (p.lx * cs - p.ly * sn),
                              c.y + (p.lx * sn + p.ly * cs))
          p.ctl:SetAnchoredPosition(ux, uy)
        else
          local ux, uy = toUI(c.x, c.y)
          p.ctl:SetAnchoredPosition(ux, uy)
        end
        p.ctl:SetLocalRotation(0, 0, -(c.rot + p.lrot))
      end
    end
  end
end

local function assignTanksToCells()
  -- 从可达格中为每辆坦克挑一个互不相同的起点
  local n = #G.reachable
  local used = {}
  -- 联机「方案 4」：出生格与朝向也由下发数据确定（可达格等分取点 + 表尾朝向档）⇒ 两端必然一致。
  local data = G.mazeInts
  local rotBase = nil
  if data ~= nil and #data >= onlineApi.MAZE_HEAD then
    rotBase = onlineApi.mazeRotBase(data)          -- = MAZE_HEAD + 1 + (W+1)*(H+1)
    if rotBase == nil or #data < rotBase - 1 + #G.tanks then rotBase = nil end
  end
  local tn = #G.tanks
  for i = 1, tn do
    local t = G.tanks[i]
    local cell
    if rotBase ~= nil then
      -- 等分取点：可达格按顺序等分成 tn 份、各取中点（纯确定，两端一致）
      local idx = floor(n * (i - 0.5) / tn) + 1
      if idx < 1 then idx = 1 elseif idx > n then idx = n end
      cell = G.reachable[idx]
      used[idx] = true
    else
      for _ = 1, 40 do
        local idx = floor(math.random() * n) + 1
        local c = G.reachable[idx]
        if c ~= nil and not used[idx] then
          used[idx] = true
          cell = c
          break
        end
      end
    end
    cell = cell or G.reachable[1] or { x = 0, y = 0 }
    -- 新回合的迷宫尺寸决定了 SCALE，速度 / 缩放 / 碰撞盒随 SCALE 变化，必须重新同步
    tankApi.setScale(t, G.scale)
    t.x = (cell.x + 0.5) * G.scale
    t.y = (cell.y + 0.5) * G.scale
    if rotBase ~= nil then
      t.rot = tankApi.normalizeRot(((data[rotBase + i - 1] or 0) % 36) * 10)
    else
      t.rot = tankApi.randomRotation()
    end
    t.alive = true
    t.oldX, t.oldY, t.oldRot = t.x, t.y, t.rot
    t.bulletsFired = 0
    t.triggerReleased = true
    t.minesLayed = 0
    t.remoteControlling = false
    t.laserReady = true
    t.gatlingReady = true
    t.homingReady = true
    t.electricReady = true
    t.deathRayReady = true
    t.elToroReady = true
    t.fragFired = false
    t.lastFrag = nil
    -- 车体美术尺寸依赖 t.s（随 SCALE 变），每回合重建
    vfree(t.baseArt)
    buildBaseArt(t)
    setWeapon(t, C.STARTWEAPON)
  end
end

-- 计分板碎裂特效（⑧.4）——实现见 layoutScoreHUD 之后；此处前向声明，
-- 供 startNewRound / stepFrame / returnToMenu / OnDestroy 引用。
local spawnScoreBurst, stepScoreBursts, clearScoreBursts

-- ============================================================
-- 联机「v4 房主权威」：房主端摇出一张**完整迷宫表**，经服务器原样落地给其他玩家。
--   表结构 = [seq, W, H, sx, sy, <(W+1)*(H+1) 个 0..3 格点熵>, <每辆坦克 1 个朝向档 0..35>]
--   `seq` = 该表所属**回合号**（房主自增）—— 回合号与表装在同一个原子单元里 ⇒ 非房主据此判断
--   「该重开一回合了」，不会出现「号到了表没到」的错配。
--   与 startNewRound 的本地随机分支用**同一套上限 / 同一套取用顺序**（mazeApi.makeEntropyInts）。
--   服务器侧不算任何随机数 ⇒ 绕开「获取随机整数 / 拼装列表 / 循环」那一整套节点图。
-- ============================================================
local function buildMazeTable(seq)
  local tn = max(2, #G.tanks)
  local minReachable = 2 * tn
  local W, H, sx, sy, ent
  local tries = 0
  repeat
    tries = tries + 1
    W = CFG.MAZE_W_MIN + floor(math.random() * (CFG.MAZE_W_MAX - CFG.MAZE_W_MIN + 1))
    H = CFG.MAZE_H_MIN + floor(math.random() * (CFG.MAZE_H_MAX - CFG.MAZE_H_MIN + 1))
    ent = mazeApi.makeEntropyInts(W, H)
    sx = floor(math.random() * W)
    sy = floor(math.random() * H)
    local m = mazeApi.createMazeFromInts(W, H, ent, 1)
    local reach = mazeApi.calcReachable(m, sx, sy)
    if #reach >= minReachable then break end
  until tries >= 200
  local list = { seq or 0, W, H, sx, sy }
  for i = 1, #ent do list[onlineApi.MAZE_HEAD + i] = ent[i] end
  local rotBase = onlineApi.MAZE_HEAD + 1 + #ent
  for i = 1, tn do list[rotBase + i - 1] = floor(math.random() * 36) end
  return list
end

local function startNewRound()
  -- 原版 setupStandardMaze（frame_53 第 1950-1960 行）：
  --   随机尺寸 + 随机起点算连通分量，可达格不足 2*TANKS 就整局重掷。
  local tankCount = max(2, #G.tanks)
  local minReachable = 2 * tankCount
  local W, H, maze, reachable, reachableIndex
  -- 联机「v4 房主权威」：房主**在本回合开始时**摇表（表首项 seq = 回合号）并上传。
  --   非房主**只在 stepFrame 检测到 seq 变化时才会走到这里**（见那里的 awaitRound 处理），
  --   所以这里直接用它读到的最新表即可 —— 不需要「领先一回合」那套预生成队列。
  if G.online and MENU.isMazeHost() then
    G.roundId = (G.roundId or 0) + 1
    G.mazeInts = buildMazeTable(G.roundId)
    netApi.reportMazeUp(G.mazeInts)          -- 上传「本回合」的表（含 seq）
    print("[坦克动荡] 联机房主：第 " .. tostring(G.roundId) .. " 回合的迷宫表已上传")
  elseif G.online and G.mazeInts == nil then
    print("[坦克动荡] 联机：非房主本回合没有可用迷宫表 ⇒ 回退本地随机（本回合两端可能不同图）")
  end
  -- 表结构 = [seq, W, H, sx, sy, <(W+1)*(H+1) 个 0..3 格点熵>, <每辆坦克 1 个朝向档 0..35>]
  local data = G.mazeInts
  if data ~= nil and #data >= onlineApi.MAZE_HEAD then
    local w, h, sx, sy = onlineApi.mazeHead(data)
    W, H = w, h
    G.scale = mazeApi.computeScale(W, H)
    local m = mazeApi.createMazeFromInts(W, H, data, onlineApi.MAZE_I0)
    if m ~= nil then
      maze = m
      reachable, reachableIndex = mazeApi.calcReachable(maze, sx, sy)
    end
  end
  if maze == nil then
    -- 单机（或联机数据不足）⇒ 本地随机，原版行为不变
    local tries = 0
    repeat
      tries = tries + 1
      W = CFG.MAZE_W_MIN + floor(math.random() * (CFG.MAZE_W_MAX - CFG.MAZE_W_MIN + 1))
      H = CFG.MAZE_H_MIN + floor(math.random() * (CFG.MAZE_H_MAX - CFG.MAZE_H_MIN + 1))
      G.scale = mazeApi.computeScale(W, H)
      maze = mazeApi.wrap(mazeApi.createMaze(W, H))
      -- 原版 tanks[0] 落在随机格，calcReachable 从该格出发取连通分量
      local sx = floor(math.random() * W)
      local sy = floor(math.random() * H)
      reachable, reachableIndex = mazeApi.calcReachable(maze, sx, sy)
    until #reachable >= minReachable or tries >= 200
  elseif #reachable < minReachable then
    print("[坦克动荡] 警告：服务器下发的迷宫可达格偏少（" .. #reachable .. "）")
  end

  G.W, G.H = W, H
  G.maze = maze
  G.reachable = reachable
  G.reachableIndex = reachableIndex
  G.deadEnds = mazeApi.findDeadEnds(maze, reachable)
  G.wallHit = mazeApi.makeWallTester(maze, G.scale)

  -- 迷宫在舞台内的摆位（原版 setupStandardMaze 末尾，frame_53 第 1908-1925 行）：
  --   mw/mh = 迷宫像素尺寸；lt = 墙线半宽 = floor(SCALE/16)；外扩 1px 边框；
  --   total 含墙厚与外框，夹到舞台可用区（高减去底部计分板 HEIGHTTOBOTTOM）；
  --   水平居中（+10 固定偏移，与原版一致），垂直顶部留白 10px。
  local mw, mh = W * G.scale, H * G.scale
  local lt = floor(G.scale / 16)
  local totalW = mw + 2 * lt + 2
  local totalH = mh + 2 * lt + 2
  if totalW > STAGE_W then totalW = STAGE_W end
  if totalH > STAGE_H - C.HEIGHTTOBOTTOM then totalH = STAGE_H - C.HEIGHTTOBOTTOM end
  G.gameX = 10 + lt + 1 + floor(STAGE_W / 2 - totalW / 2)
  G.gameY = 10 + lt + 1
  -- 舞台 → UI 的缩放是常量，不随迷宫尺寸变化（保证各种宽高比都按真实比例显示）
  G.VS = STAGE_SCALE
  G.shakeX, G.shakeY = 0, 0

  buildDistProxy()
  buildMazeVisuals()
  makeCtx()
  ctx.distancesForMaze = G.distProxy

  clearProjectiles()
  clearCrates()
  -- 新回合场上无补给箱 ⇒ **房主**把「空表」也上传一次（否则非房主那边旧箱子会残留）
  G.crateDirty = true
  clearEffects()
  -- 注意：**不要**在此 clearScoreBursts()。计分板碎裂特效要像原版一样跨回合播完——
  -- 原版 scoreboard 是常驻 HUD（DefineSprite_166），add() 的碎片在其自身图层继续播放；
  -- 而回合重置只隔 NUMBEROFFRAMESBEFORERESET(=5) 帧，若在此清除会把动画打断成「瞬间跳数字」。
  -- 粒子会在 stepScoreBursts 里随 alpha 归零自行释放；返回菜单 / 销毁时另有 clearScoreBursts。
  assignTanksToCells()

  G.battle = roundApi.newBattle(#G.tanks,
    roundApi.nextCrateTimer(#reachable, G.rules.crateRate))
  for i = 1, #G.tanks do
    local t = G.tanks[i]
    if t.ai ~= nil then t.ai = aiApi.new(t, ctx) end
  end
  updateScoreHUD()
  -- 本回合新建的地板 / 墙晚于坦克创建，会把坦克压住；重排一次固定叠放
  applyZOrder()
  print("[坦克动荡] 新回合：迷宫 " .. W .. "×" .. H .. "，SCALE=" .. G.scale
        .. "，可达格=" .. #reachable)
end

-- ============================================================
-- ⑬ 逐帧驱动
-- ============================================================
local function tankFrame(t)
  if not t.alive then return end
  if t.remote then return end   -- 联机：对手坦克由快照插值驱动（stepOnline），不跑本地模拟 / 输入
  if weaponsApi.lockedControl(t, t.currentWeapon) then return end

  local fire
  local movedByMouse = false
  if t.touchPad then
    -- 触屏玩家（移动端）：左/对应区摇杆 + 开火区
    local tp = t.touchPlayer
    local st = (tp ~= nil) and G.tstick[tp] or nil
    if G.touchHandfeel == "aim" then
      -- 「朝向我」（同键鼠 3P）：方向即朝向；短距仅转向、长距转向并前进 → 接 stepMouse 旧分支
      if st ~= nil and st.active and (st.ratio or 0) > G.tcfg.dead then
        local mx, my = ctx.mousePos(t)
        tankApi.stepMouse(t, mx, my)
        movedByMouse = true
      else
        t.forward, t.backup, t.turnLeft, t.turnRight = false, false, false, false
      end
    else
      -- 「8 向布尔」（同键鼠 1P/2P）
      local d = (st ~= nil) and st.dir or nil
      t.forward   = (d ~= nil and d.fwd)   == true
      t.backup    = (d ~= nil and d.back)  == true
      t.turnLeft  = (d ~= nil and d.left)  == true
      t.turnRight = (d ~= nil and d.right) == true
    end
    fire = (tp ~= nil and G.tfire[tp]) == true
  elseif t.mouseTank then
    -- 鼠标坦克（原版第 3 台）：坦克瞬时对准光标、够近即前进；开火 = 鼠标左键。
    -- stepMouse 内部已完成 beginFrame + attemptToMove，故下面不再重复调用。
    local mx, my = ctx.mousePos(t)
    tankApi.stepMouse(t, mx, my)
    -- 光标落在左上角「返回」按钮上时不开火（避免「点返回顺带朝那个方向打一炮」）
    fire = G.pmouse.fire and not MENU.backHover
    movedByMouse = true
  elseif t.padTank then
    -- 手柄玩家：左摇杆 + 十字键 + A（每帧由 pollGamepad 合成到 G.gp）
    local gp = G.gp
    t.forward   = gp.fwd
    t.backup    = gp.back
    t.turnLeft  = gp.left
    t.turnRight = gp.right
    fire = gp.fire
  elseif t.anyCtrl then
    -- 联机本机玩家：**所有控制方式同时可用**（键盘两套方案 + 手柄 + 鼠标左键开火）。
    --   鼠标只并入开火、**不抢转向** —— 否则光标一动就会把坦克往鼠标方向拽，和键盘互相打架。
    local pa, pb, gp = G.pinputs[1], G.pinputs[2], G.gp
    t.forward   = (pa ~= nil and pa.fwd)   or (pb ~= nil and pb.fwd)   or gp.fwd
    t.backup    = (pa ~= nil and pa.back)  or (pb ~= nil and pb.back)  or gp.back
    t.turnLeft  = (pa ~= nil and pa.left)  or (pb ~= nil and pb.left)  or gp.left
    t.turnRight = (pa ~= nil and pa.right) or (pb ~= nil and pb.right) or gp.right
    fire = ((pa ~= nil and pa.fire) or (pb ~= nil and pb.fire)) or gp.fire or G.pmouse.fire
  elseif t.controlIndex ~= nil then
    -- 人类玩家：按自己的控制方案取输入（红=1，绿=2）
    local inp = G.pinputs[t.controlIndex] or G.input
    t.forward = inp.fwd
    t.backup = inp.back
    t.turnLeft = inp.left
    t.turnRight = inp.right
    fire = inp.fire
  else
    local ai = t.ai
    if ai ~= nil then
      if ai:makeDecisionsAndUpdateGoal() then ai:decideActionsToAchieveGoal() end
      ai:setInputToDoActions()
    end
    fire = t.fire
  end

  if not movedByMouse then
    tankApi.beginFrame(t)
    tankApi.attemptToMove(t, t.forward, t.backup, t.turnLeft, t.turnRight)
  end

  if fire and t.triggerReleased and weaponsApi.weaponReady(t, t.currentWeapon, C.SETTINGS.maxBullets) then
    t.triggerReleased = false
    local list = weaponsApi.fire(t, t.currentWeapon, ctx)
    -- 联机（P3）：本机开火上报（对手端镜像出弹道）；仅上报「自己」这一辆
    if G.online and t == G.tanks[G.playerIndex] then
      MENU.sendEvent(onlineApi.EV.FIRE, G.playerIndex,
        floor(t.rot * 10 + 0.5), onlineApi.weaponId(t.currentWeapon))
    end
    for i = 1, #list do
      local p = list[i]
      if p ~= nil then
        G.projectiles[#G.projectiles + 1] = p
        buildProjVisual(p)
      end
    end
  elseif not fire then
    t.triggerReleased = true
  end
end

local function stepProjectiles()
  for i = #G.projectiles, 1, -1 do
    local p = G.projectiles[i]
    local keep = weaponsApi.step(p, ctx)
    if not keep or p.remove then
      freeProjVisual(p)
      table.remove(G.projectiles, i)
    else
      syncProjVisual(p)
    end
  end
end

local function renderTanks()
  for i = 1, #G.tanks do
    local t = G.tanks[i]
    if t.alive then
      renderGroup(t.baseArt, t.x, t.y, t.rot)
      renderGroup(t.turretArt, t.x, t.y, t.rot)
    end
  end
end

-- ============================================================
-- ⑫.5 瞄准路径预览（原版 aimer：对每台存活坦克常驻的虚线反弹预览）
-- ============================================================
-- 原版权威实现：reference/.../DefineSprite_32_aimer/frame_1/DoAction.as
--   从炮口沿朝向以 AIMERLENGTH/AIMERHITCHECKINTERVALS * (SCALE/50) 为步长推进
--   AIMERHITCHECKINTERVALS 个子步；撞墙按 X/Y 单轴试探反弹；前 AIMERACTIVE 步之后，
--   每逢偶数子步检测是否命中存活坦克，命中即提前结束（本步仍绘制）；
--   每子步以 30% 概率画一小段亮线（颜色 = 炮塔色），故整体呈「闪烁虚线」。
--   原版对每台存活坦克常驻绘制，颜色 = 炮塔色，绘制于坦克之下。
local aimerDashes = {}
local AIMER_EMPTY = {}

local function computeAimerDashes(t)
  local out = aimerDashes
  for i = #out, 1, -1 do out[i] = nil end
  local k = G.scale / 50
  local ang = (t.rot - 90) * RAD
  local ca, sa = cos(ang), sin(ang)
  local x = t.x + ca * G.scale * 4.5 / 16
  local y = t.y + sa * G.scale * 4.5 / 16
  local xs = ca * C.AIMERLENGTH / C.AIMERHITCHECKINTERVALS * k
  local ys = sa * C.AIMERLENGTH / C.AIMERHITCHECKINTERVALS * k
  local active = C.AIMERACTIVE
  local jumped = false
  local n = 0
  for j = 0, C.AIMERHITCHECKINTERVALS - 1 do
    local px, py = x, y
    x = x + xs
    y = y + ys
    if G.wallHit(x, y) then
      x, y = px, py
      local hx = G.wallHit(px - xs, py + ys)
      local hy = G.wallHit(px + xs, py - ys)
      if hx and not hy then
        ys = -ys
      elseif hy and not hx then
        xs = -xs
      else
        xs = -xs
        ys = -ys
      end
      x = px + xs
      y = py + ys
    end
    if active > 0 then active = active - 1 end
    if active == 0 and j % 2 == 0 then
      for ti = 1, #G.tanks do
        local tk = G.tanks[ti]
        if tk.alive and weaponsApi.makeTankContains(tk)(x, y) then
          jumped = true
          break
        end
      end
    end
    if math.random() > 0.7 then
      n = n + 1
      out[n] = { ax = px, ay = py, bx = x, by = y }
    end
    if jumped then break end
  end
  return out
end

local function renderAimers()
  if G.aimerHolders == nil then G.aimerHolders = {} end
  local holders = G.aimerHolders
  local nt = (G.tanks ~= nil) and #G.tanks or 0
  local k = (G.scale or 50) / 50
  if nt == 0 then
    for i = 1, #holders do dashRender(holders[i], AIMER_EMPTY, COLOR.SHOT, 2 * k) end
    return
  end
  if G.battle ~= nil and G.battle.frozen then return end
  -- 弹道预览只在该坦克**正持激光**时显示。
  -- 依据：原版 setEquipment 的 AS2 switch 把 `case "none": case "aimer":` 归为同一分支（缺 break，
  -- 属原版笔误 → 出生时 `setEquipment(owner,"none")` 也会挂一个 aimer），但全工程**唯一显式**
  -- `setEquipment(owner,"aimer")` 调用在 setWeapon 的 `case "laser":` 分支里 → 开发者本意是「仅激光」；
  -- 且 aimer 自身脚本含 `if(!owner.alive) this.removeMovieClip();`。故真实观感 = 只有拿激光才有预览、
  -- 激光发射后（setEquipment(owner,"none")）预览消失。此处直接按「仅激光」门控，与原版实际表现一致。
  for i = 1, nt do
    local t = G.tanks[i]
    local holder = holders[i]
    if holder == nil then holder = { segs = {} }; holders[i] = holder end
    if t.alive and t.currentWeapon == "laser" then
      dashRender(holder, computeAimerDashes(t), t.turretColor or COLOR.SHOT, 2 * k)
    else
      dashRender(holder, AIMER_EMPTY, COLOR.SHOT, 2 * k)
    end
  end
  for i = nt + 1, #holders do
    dashRender(holders[i], AIMER_EMPTY, COLOR.SHOT, 2 * k)
  end
end

-- ============================================================
-- ⑫.6 鼠标准星（原版 scopeCross + scopeCircle）
-- ============================================================
-- 原版第 3 台坦克由鼠标操控：屏幕上跟随鼠标画一个十字准星（scopeCross），
-- 并在「坦克朝鼠标方向 60px 处」画一个圆环（scopeCircle）。
-- 原版 settingsUseNewMouseControl 下，坦克离鼠标足够远（>120）时圆环变红（蓄力态）；
-- 本项目沿用旧操控，该标志恒为 false，圆环恒为浅灰。
local SCOPE = { parts = {}, ring = nil, visible = false }
-- 尺寸取自原版：scopeCross = 20×20 flash px 细十字（臂半长 10、笔画 2、中心 2×2 略深），
--                   scopeCircle = 11×11 flash px 圆环（半径 5.5）。
-- flash px × VS(=1.25) → UI 单位：臂半长 12.5 / 笔画 2.5 / 中心 2.5 / 环半径 6.9。
SCOPE.arm, SCOPE.thick, SCOPE.dotR, SCOPE.ringR = 12.5, 2.5, 2.5, 6.9

local function setScopeVisible(v)
  v = v and true or false
  if SCOPE.visible == v then return end
  SCOPE.visible = v
  for i = 1, #SCOPE.parts do pcall(function() SCOPE.parts[i]:SetVisible(v) end) end
  if SCOPE.ring ~= nil then pcall(function() SCOPE.ring:SetVisible(v) end) end
end

local function buildScope()
  local parts = SCOPE.parts
  local horiz = acquire("square")
  if horiz ~= nil then
    pcall(function()
      horiz:SetSizeDelta(SCOPE.arm * 2, SCOPE.thick)
      horiz.imageColor = COLOR.SCOPE
    end)
    parts[#parts + 1] = horiz
  end
  local vert = acquire("square")
  if vert ~= nil then
    pcall(function()
      vert:SetSizeDelta(SCOPE.thick, SCOPE.arm * 2)
      vert.imageColor = COLOR.SCOPE
    end)
    parts[#parts + 1] = vert
  end
  local dot = acquire("square")
  if dot ~= nil then
    pcall(function()
      dot:SetSizeDelta(SCOPE.dotR, SCOPE.dotR)
      dot.imageColor = COLOR.SCOPE
    end)
    parts[#parts + 1] = dot
  end
  SCOPE.ring = acquire("rings")
  if SCOPE.ring ~= nil then
    pcall(function()
      SCOPE.ring:SetSizeDelta(SCOPE.ringR * 2, SCOPE.ringR * 2)
      SCOPE.ring.imageColor = COLOR.SCOPE_RING
    end)
  end
  -- 新建 / 池化复用的控件默认可见，而 SCOPE.visible 初值即 false，直接调 setScopeVisible(false)
  -- 会因提前返回而失效，导致准星残留在屏幕中心 (0,0)，故此处逐个显式隐藏。
  SCOPE.visible = false
  for i = 1, #SCOPE.parts do pcall(function() SCOPE.parts[i]:SetVisible(false) end) end
  if SCOPE.ring ~= nil then pcall(function() SCOPE.ring:SetVisible(false) end) end
end

local function updateScope()
  -- 移动端没有真实光标：不显示准星（触屏改用摇杆 + 开火按钮）
  if G.touchMode then setScopeVisible(false); return end
  local mt = nil
  for i = 1, #G.tanks do
    local t = G.tanks[i]
    if t.mouseTank and t.alive then mt = t; break end
  end
  if mt == nil then setScopeVisible(false); return end
  local mx, my = ctx.mousePos(mt)
  if mx == nil or mx <= -90000 then setScopeVisible(false); return end
  setScopeVisible(true)
  local ux, uy = toUI(mx, my)
  for i = 1, #SCOPE.parts do
    local p = SCOPE.parts[i]
    pcall(function() p:SetAnchoredPosition(ux, uy) end)
  end
  local dx, dy = mx - mt.x, my - mt.y
  local len = sqrt(dx * dx + dy * dy)
  local rx, ry = ux, uy
  if len > 60 and len > 0.0001 then
    rx, ry = toUI(mt.x + dx / len * 60, mt.y + dy / len * 60)
  end
  local armed = mt.settingsUseNewMouseControl and (len > 120)
  if SCOPE.ring ~= nil then
    pcall(function()
      SCOPE.ring:SetAnchoredPosition(rx, ry)
      SCOPE.ring.imageColor = armed and COLOR.SCOPE_ARMED or COLOR.SCOPE_RING
    end)
  end
end

-- ============================================================
-- ⑫.5 触屏游戏内操控（移动端，见 DEV_STATE §10.5 / §6.23）
--   分区：单人 = 左半屏摇杆 + 右半屏开火；双人 = 四象限（左上 1P 摇杆 / 左下 1P 开火 /
--         右下 2P 摇杆 / 右上 2P 开火）。三人触屏不可用（见菜单）。
--   手感：pad = 8 向布尔（同键鼠 1P/2P）；aim = 方向即朝向（同键鼠 3P，接 stepMouse 旧分支）。
-- ============================================================

-- 依模式生成触屏分区（UI 坐标：画布中心为原点、y 向上）。三人返回空表（不可用）。
local function buildTouchZones(mode)
  local vw, vh = CFG.TARGET_W, CFG.TARGET_H
  pcall(function() vw, vh = game.GetUICanvasSize() end)
  if type(vw) ~= "number" or vw <= 0 then vw = CFG.TARGET_W end
  if type(vh) ~= "number" or vh <= 0 then vh = CFG.TARGET_H end
  local hw, hh = vw / 2 / (G.uiScale or 1), vh / 2 / (G.uiScale or 1)
  local z = {}
  if mode == "solo" then
    z[1] = { player = 1, kind = "stick", x0 = -hw, y0 = -hh, x1 = 0,  y1 = hh }
    z[2] = { player = 1, kind = "fire",  x0 = 0,   y0 = -hh, x1 = hw, y1 = hh }
  elseif mode == "duo" then
    z[1] = { player = 1, kind = "stick", x0 = -hw, y0 = 0,   x1 = 0,  y1 = hh }  -- 左上：1P 摇杆
    z[2] = { player = 1, kind = "fire",  x0 = -hw, y0 = -hh, x1 = 0,  y1 = 0 }   -- 左下：1P 开火
    z[3] = { player = 2, kind = "stick", x0 = 0,   y0 = -hh, x1 = hw, y1 = 0 }   -- 右下：2P 摇杆
    z[4] = { player = 2, kind = "fire",  x0 = 0,   y0 = 0,   x1 = hw, y1 = hh }  -- 右上：2P 开火
  end
  return z
end

-- 每帧把触点解析成「每玩家摇杆向量 / 8 向布尔 / 开火」。
local function stepTouchGameplay()
  local cfg = G.tcfg
  -- ① 复位 + 释放（绑定的手指已抬起）
  for p = 1, 2 do
    local st = G.tstick[p]
    if st.active and (st.id == nil or G.touches[st.id] == nil) then
      st.active, st.id = false, nil
    end
    if st.dir == nil then st.dir = {} end
    st.dir.fwd, st.dir.back, st.dir.left, st.dir.right = false, false, false, false
    st.vx, st.vy, st.ratio = 0, 0, 0
    G.tfire[p] = false
  end
  if not G.touchMode then return end
  -- ② 分配：每根手指落到哪个区（stick 认领一根；fire 置位）
  local zones = G.tzone
  if zones ~= nil then
    for id, tp in pairs(G.touches) do
      -- 对战期左上角「返回」按钮区域不参与摇杆 / 开火判定（在那里点一下就是返回，见 MENU.stepPlayBack）
      if not MENU.hitBack(tp.x, tp.y) then
        for i = 1, #zones do
          local q = zones[i]
          if tp.x >= q.x0 and tp.x <= q.x1 and tp.y >= q.y0 and tp.y <= q.y1 then
            if q.kind == "stick" then
              local st = G.tstick[q.player]
              if st.id == nil then
                st.active, st.id = true, id
                st.ox, st.oy = tp.x, tp.y
                st.x, st.y = tp.x, tp.y
              elseif st.id == id then
                st.x, st.y = tp.x, tp.y
              end
            elseif q.kind == "fire" then
              G.tfire[q.player] = true
            end
            break
          end
        end
      end
    end
  end
  -- ③ 摇杆向量 → 8 向（分量阈值 sin22.5°≈0.383；死区外才生效）
  for p = 1, 2 do
    local st = G.tstick[p]
    if st.active then
      local dx, dy = st.x - st.ox, st.y - st.oy
      local m = sqrt(dx * dx + dy * dy)
      if m > cfg.stickR then dx, dy = dx / m * cfg.stickR, dy / m * cfg.stickR; m = cfg.stickR end
      st.vx, st.vy = dx, dy
      st.ratio = m / cfg.stickR
      if m > 0 and st.ratio > cfg.dead then
        local d = st.dir
        d.fwd   = (dy >  0.383 * m)
        d.back  = (dy < -0.383 * m)
        d.left  = (dx < -0.383 * m)
        d.right = (dx >  0.383 * m)
      end
    end
  end
end

-- 触屏操控可视（摇杆外圈 + 实心圆 + 开火按钮）
local function buildTouchViz()
  if G.tviz ~= nil then return end
  G.tviz = {}
  for p = 1, 2 do
    G.tviz[p] = { ring = createShape("circle"),
                  dot  = createShape("circle"),
                  fire = createShape("circle") }
  end
end

local function hideTouchViz()
  if G.tviz == nil then return end
  for p = 1, 2 do
    local v = G.tviz[p]
    pcall(function() v.ring:SetVisible(false) end)
    pcall(function() v.dot:SetVisible(false) end)
    pcall(function() v.fire:SetVisible(false) end)
  end
end

local function syncTouchViz()
  if not G.touchMode or MENU.phase ~= "playing" then hideTouchViz(); return end
  buildTouchViz()
  local zones = G.tzone
  local fireZ = {}
  if zones ~= nil then
    for i = 1, #zones do if zones[i].kind == "fire" then fireZ[zones[i].player] = zones[i] end end
  end
  for p = 1, 2 do
    local v = G.tviz[p]
    -- 摇杆（仅按住时显示：外圈在落点、实心圆随手指）
    local st = G.tstick[p]
    if st.active then
      pcall(function()
        v.ring:SetVisible(true)
        v.ring:SetSizeDelta(G.tcfg.stickR * 2, G.tcfg.stickR * 2)
        v.ring:SetAnchoredPosition(st.ox, st.oy)
        v.ring.imageColor = alphaOf(COLOR.MENU_ICON, 70)
        v.dot:SetVisible(true)
        v.dot:SetSizeDelta(72, 72)
        v.dot:SetAnchoredPosition(st.ox + st.vx, st.oy + st.vy)
        v.dot.imageColor = alphaOf(COLOR.MENU_ICON, 190)
      end)
    else
      pcall(function() v.ring:SetVisible(false) end)
      pcall(function() v.dot:SetVisible(false) end)
    end
    -- 开火按钮（该区中心；按下变强调色）
    local fz = fireZ[p]
    if fz == nil then
      pcall(function() v.fire:SetVisible(false) end)
    else
      local cx, cy = (fz.x0 + fz.x1) / 2, (fz.y0 + fz.y1) / 2
      local r = min(fz.x1 - fz.x0, fz.y1 - fz.y0) * 0.22
      pcall(function()
        v.fire:SetVisible(true)
        v.fire:SetSizeDelta(r * 2, r * 2)
        v.fire:SetAnchoredPosition(cx, cy)
        v.fire.imageColor = (G.tfire[p] == true) and COLOR.ACCENT or alphaOf(COLOR.MENU_ICON, 110)
      end)
    end
  end
end

-- 联机同步（P2）：① 每 2 个定步（≈12.5Hz）上传一次本机快照；② 读服务器汇总的关卡变量 → 推入缓冲 →
--   按「渲染时间 = now − delay」插值，驱动对手坦克的位置 / 朝向 / 武器 / 存活（渲染层照旧）。
--   ⚠️ 需要编辑器侧节点图：把收到的 TT2_SNAP 汇总写进**关卡变量 TT2_SNAP**（见「联机节点图接线清单.md」§2.7）。
local function stepOnline()
  local m = G.room
  if not G.online or m == nil then return end
  local me = G.tanks[G.playerIndex]
  if me ~= nil then
    G.snapStep = G.snapStep + 1
    if G.snapStep >= 2 then
      G.snapStep = 0
      -- ⚠️ 按槽位选信号（TT2_SNAP_1 / TT2_SNAP_2）：共用一个信号会被两端互相覆盖。
      netApi.reportSnap(G.playerIndex, onlineApi.encodeSnap(G.playerIndex,
        me.x, me.y, me.rot, onlineApi.weaponId(me.currentWeapon), me.alive))
    end
  end
  -- 下行：读**对方槽位**那个快照变量（TT2_SNAP_1 / TT2_SNAP_2）——
  --   分槽位才不会互相覆盖；push 内部按 payload 的 slot 分桶，所以混入自己的也无妨。
  for k = 1, #m.oppSlots do
    local slot = m.oppSlots[k]
    local list = nil
    pcall(function()
      list = game.GetGlobalCustomVariableValue(Enum.CustomVariableEntityType.Level, onlineApi.snapVar(slot))
    end)
    if type(list) == "table" and #list >= onlineApi.SNAP_N then
      onlineApi.push(G.snapBuf, audioClock, onlineApi.decodeSnaps(list))
    end
  end
  -- 插值：对手各槽位
  for k = 1, #m.oppSlots do
    local slot = m.oppSlots[k]
    local t = G.tanks[slot]
    if t ~= nil then
      local s = onlineApi.sample(G.snapBuf, slot, audioClock, m.delay)
      if s ~= nil then
        t.x, t.y, t.rot = s.x, s.y, s.rot
        local w = onlineApi.weaponName(s.weaponId)
        if w ~= t.currentWeapon then setWeapon(t, w) end
        t.alive = s.alive
      end
    end
  end
  -- 胜负：读房主下发的 TT2_WINNER（0 = 本局未结束）⇒ 各端据此统一结算。
  local wv = 0
  pcall(function()
    wv = tonumber(game.GetGlobalCustomVariableValue(
      Enum.CustomVariableEntityType.Level, "TT2_WINNER")) or 0
  end)
  if wv ~= G.winnerSeen then
    G.winnerSeen = wv
    if wv ~= 0 and G.match ~= nil and not G.match.over then MENU.finishMatch(wv) end
  end
end

local function stepFrame()
  -- 联机「v4」非房主：回合已结束（或刚开局），正在等房主的**下一个 seq**。
  --   等表期间**不推进世界**（保持结算画面）；一拿到新 seq 立刻开新回合。
  --   超时（50 帧 ≈ 2 秒）则回退本地随机，避免对端掉线把整局卡死。
  if G.awaitRound then
    G.awaitFrames = G.awaitFrames + 1
    if G.mazeSeqSeen > G.mazeSeqUsed then
      G.awaitRound = false
      G.awaitFrames = 0
      G.mazeSeqUsed = G.mazeSeqSeen
      startNewRound()
    elseif G.awaitFrames >= 50 then
      G.awaitRound = false
      G.awaitFrames = 0
      print("[坦克动荡] 联机：等房主迷宫表超时 ⇒ 本回合回退本地随机（两端可能不同图）")
      startNewRound()
    end
    return
  end
  rebuildCtxLists()

  stepTouchGameplay()   -- 触屏（移动端）：把触点解析成每玩家摇杆 / 开火

  local offX, offY, ev = roundApi.step(G.battle)
  G.shakeX = offX * G.VS
  G.shakeY = -offY * G.VS

  -- 对局（比赛）计时：**仅联机**有 10 分钟倒计时与胜负判定（用户规则）；
  --   单机**没有胜利条件**，只判断「有没有完成关卡」（见 cleanup 分支）。
  local mm = G.match
  if G.online and mm ~= nil and not mm.over then
    mm.tick = mm.tick + 1
    if mm.tick % 25 == 0 then
      mm.timer = mm.timer - 1
      local secs = mm.timer > 0 and mm.timer or 0
      if hud.timerLabel ~= nil then
        pcall(function()
          hud.timerLabel.text = (mm.overtime and "加时 " or "时间 ")
            .. string.format("%d:%02d", floor(secs / 60), secs % 60)
        end)
      end
      if mm.timer <= 0 then
        local hiIdx, hi, tie = nil, -1, false
        for i = 1, #G.tanks do
          local sc = G.tanks[i].score or 0
          if sc > hi then hi = sc; hiIdx = i; tie = false
          elseif sc == hi then tie = true end
        end
        if not tie and hiIdx ~= nil then
          MENU.declareWinner(hiIdx)        -- 分高者胜（联机由房主裁定并上传）
        else
          mm.overtime = true               -- 同分：进入新的一分钟加时
          mm.timer = CFG.OT_SECONDS
        end
      end
    end
  end

  -- 联机「分出胜负 ⇒ 立刻结算关卡」（用户 2026-10-16 规则）：
  --   finishMatch 已把**本端**的最终状态报上去，并置了 mm.settleIn=40；这里倒数到 0 再发 TT2_SETTLE。
  --   谁发：**房主**（胜负由它裁定）；若房主已不在场（对方逃跑那种局面），由**唯一在场**的一方发。
  --   ⚠️ 本块放在 mm.over 之外：结算时 mm.over 已为 true，但倒数还得继续走完。
  if G.online and mm ~= nil and mm.settleIn ~= nil then
    mm.settleIn = mm.settleIn - 1
    if mm.settleIn <= 0 then
      mm.settleIn = nil
      if MENU.isMazeHost() or (MENU.onlinePlayers or 0) == 1 then
        local ok = netApi.reportSettle()
        print("[坦克动荡] 已上报 TT2_SETTLE（" .. (ok and "已发出" or "**未发出**")
          .. "）⇒ 服务器立刻【结算关卡】")
      end
    end
  end

  if ev == "freeze" then
    G.battle.frozen = true
  elseif ev == "cleanup" then
    -- 记录加分前的分数，用于挑出「本回合加分」的玩家触发计分板碎裂特效
    local prevScore = {}
    for i = 1, #G.tanks do prevScore[i] = G.tanks[i].score or 0 end
    roundApi.assignPoints(G.tanks)
    -- 本地战绩：回合完成数 / 玩家存活获胜数（原版为 unsentRoundsCompleted 等上传字段）
    local pl = G.tanks[G.playerIndex]
    local won = (pl ~= nil and pl.alive)
    statsApi.onRound(G.stats, won)
    local newly = achApi.apply(G.ach, { type = "round" })
    if won then
      local w = achApi.apply(G.ach, { type = "win" })
      if w ~= nil then
        newly = newly or {}
        for i = 1, #w do newly[#newly + 1] = w[i] end
      end
    end
    reportNewAch(newly)
    reportStats()
    clearProjectiles()
    clearCrates()
    updateScoreHUD()
    -- 计分板碎裂：仅为「本回合加分」的玩家在各自板位触发（对应原版 scoreboard.add(1)）
    for i = 1, #G.tanks do
      if (G.tanks[i].score or 0) > (prevScore[i] or 0) then spawnScoreBurst(i) end
    end
    -- 比赛胜负（加分后判定，**仅联机**）：先领先 10 分即胜；加时中任意一方领先即胜。
    if G.online and G.match ~= nil and not G.match.over then
      local hiIdx, hi, tie = nil, -1, false
      for i = 1, #G.tanks do
        local sc = G.tanks[i].score or 0
        if sc > hi then hi = sc; hiIdx = i; tie = false
        elseif sc == hi then tie = true end
      end
      local second = -1
      for i = 1, #G.tanks do
        if i ~= hiIdx then
          local sc = G.tanks[i].score or 0
          if sc > second then second = sc end
        end
      end
      if hiIdx ~= nil and (hi - second) >= CFG.MATCH_LEAD then
        MENU.declareWinner(hiIdx)                  -- 领先 10 分（联机由房主裁定并上传）
      elseif G.match.overtime and (not tie) and hiIdx ~= nil then
        MENU.declareWinner(hiIdx)                  -- 加时里任意领先
      end
    end
    -- 单机：**没有胜利条件**；只要完成一场回合结算（走到这里）即视为「已完成关卡」。
    --   上报 TT2_DONE，供编辑器侧节点图接「设置玩家结算成功状态（胜利）」+「结算关卡」。
    if not G.online and G.match ~= nil and not G.match.completed then
      G.match.completed = true
      netApi.reportDone()
      print("[坦克动荡] 单机：完成一场战斗结算 ⇒ 视为已完成关卡")
    end
  elseif ev == "reset" then
    if G.online and not MENU.isMazeHost() then
      -- 非房主：**不自己开新回合** —— 房主是回合的唯一驱动者，等它的下一个 seq（stepFrame 头部处理）
      G.awaitRound = true
      G.awaitFrames = 0
      return
    end
    startNewRound()
    return
  end

  if not G.battle.frozen then
    for i = 1, #G.tanks do tankFrame(G.tanks[i]) end
    stepProjectiles()
    stepOnline()     -- 联机：上传本机快照 / 插值驱动对手（非联机时内部直接返回）
    -- 补给箱：**房主（或单机）才是权威** —— 刷箱计时只由它跑；非房主只做镜像（见下）
    if (not G.online or MENU.isMazeHost())
       and roundApi.tickCrateTimer(G.battle, #G.reachable, G.rules.crateRate) then
      trySpawnCrate()
    end
  end

  -- 非房主：先把补给箱权威表拉齐（增/删），再做本地拾取判定
  if G.online and not MENU.isMazeHost() then MENU.syncCrateMirror() end
  syncCrates()
  -- 房主：权威表有变化 ⇒ 整张上传（服务器原样写进关卡变量 TT2_CRATE）
  if G.online and MENU.isMazeHost() and G.crateDirty then MENU.uploadCrates() end
  stepEffects()
  stepScoreBursts()
  if G.sparkLife ~= nil and G.sparkLife > 0 then
    G.sparkLife = G.sparkLife - 1
    if G.sparkLife == 0 and G.sparkHolder ~= nil then
      for i = 1, #G.sparkHolder.segs do
        G.sparkHolder.segs[i].ctl:SetVisible(false)
      end
    end
  end

  syncWalls()
  renderTanks()
  renderAimers()
  updateScope()
  syncTouchViz()      -- 触屏操控可视（摇杆外圈 + 实心圆 + 开火按钮）
  -- 对局中会不断新建炮弹 / 补给箱 / 特效，每帧末重排一次，保证坦克永远在最上层
  applyZOrder()
end

-- ============================================================
-- ⑭ HUD
-- ============================================================
-- 计分板（原版 player1/2ScoreBoard）：每个玩家 = 迷你坦克图标 + 分数数字。
-- frags：计分板加分时的「碎裂特效」粒子（屏幕固定 HUD 空间，独立于世界特效 G.effects）。
hud = { icons = {}, scoreLabels = {}, frags = {}, scoreBox = {},
        nameLabels = {}, pingLabels = {} }

-- 文字渲染：原生「文本框」客户端控件（奇匠 Lv.2 解锁【自定义文本外显】后启用）。
--   2026-10-11：奇匠等级升到 Lv.2，用户给出「文本框」模板索引（现为 1073741908，见 PREFAB.TEXT_BOX）。
--   此前 Lv.1 受等级门槛限制、无法使用文本控件，文字改由「正方形控件拼笔画」渲染（曾用 src/glyphs.lua）；
--   现改回原生文本框 —— 每个 Label = 1 个文本框控件，拼字方案退役。
--   文本框底色默认可能不透明，必须清零；框高有**绝对下限** `TEXT_MIN_H`（原因见 labelApply）。
local TEXT_BG     = col(0, 0, 0, 0)
local TEXT_MIN_H  = 48

-- 以 UTF-8 逐字符切分（不依赖 utf8 库：千星奇域运行时不保证提供该库）
local function utf8chars(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local b = string.byte(s, i)
    local len = 1
    if b >= 0xF0 then len = 4
    elseif b >= 0xE0 then len = 3
    elseif b >= 0xC0 then len = 2 end
    out[#out + 1] = string.sub(s, i, i + len - 1)
    i = i + len
  end
  return out
end

-- 对齐方式 → 关键字。调用方传的是 Enum.TextHorizontalAlignment.*（也接受直接传字符串）。
local THA = {}
pcall(function()
  THA.left  = Enum.TextHorizontalAlignment.Left
  THA.mid   = Enum.TextHorizontalAlignment.Middle
  THA.right = Enum.TextHorizontalAlignment.Right
end)
local function alignKey(align)
  if align == "left" or align == "right" then return align end
  if align ~= nil then
    if align == THA.left then return "left" end
    if align == THA.right then return "right" end
    -- 兜底：个别实现的枚举值无法用 == 比较，退而读其名称
    local s = tostring(align)
    if string.find(s, "Left") then return "left" end
    if string.find(s, "Right") then return "right" end
  end
  return "mid"
end

-- 新建一个文本框控件：清底色 / 关描边 / 垂直居中 / 初始隐藏（与旧 Label 一致，由调用方 SetVisible(true) 显示）
local function createTextBox()
  local ok, ctl = pcall(game.InstantiateClientUIControl, PREFAB.TEXT_BOX, host)
  if not ok or ctl == nil then
    printerr("[坦克动荡] 创建文本框失败，prefabIndex=" .. tostring(PREFAB.TEXT_BOX))
    return nil
  end
  -- 运行时按模板实际创建的是「文本框」子类；`InstantiateClientUIControl` 文档只声明返回基类，
  -- 故此处按项目约定用合并类型 ClientUIControl 标注，消除 inject-field 误报（见 types/project.lua）。
  local c = ctl --[[@as ClientUIControl]]
  pcall(function()
    c:SetAnchorMin(0.5, 0.5)
    c:SetAnchorMax(0.5, 0.5)
    c:SetPivot(0.5, 0.5)
  end)
  pcall(function() c:SetActive(true) end)
  pcall(function() c.bgColor = TEXT_BG end)
  pcall(function() c.enableOutline = false end)
  pcall(function() c.adaptiveFontSize = false end)
  pcall(function() c.verticalAlignment = Enum.TextVerticalAlignment.Middle end)
  pcall(function() c:SetVisible(false) end)
  return c
end

-- ------------------------------------------------------------
-- Label：单个「文本框」控件的轻量封装。对外接口与旧的拼字 Label 完全一致，
-- 故所有调用点无需改动：
--   label.text = s        —— 改文本
--   label.fontColor = c   —— 改字色
--   label:SetVisible(v)   —— 显隐
--   label:SetPos(x,y)     —— 重定位
--   label:SetTransform()  —— 主菜单逐帧 bob / 悬停放大（平移 + 旋转 + 缩放）
--   label:SetAsLastSibling() —— 抬到同层最上（供 applyZOrder 使用）
--   label.ctl             —— 底层文本框控件
-- ------------------------------------------------------------
local Label = {}
-- 读接口与文本框控件对齐：外部（含离线冒烟测试）可回读 label.text / .visible / .fontColor。
-- 其余键落到 Label 表上（方法查找），故 :SetVisible / :SetAsLastSibling 仍可用。
Label.__index = function(self, k)
  if k == "text" then return self._text end
  if k == "visible" then return self._vis end
  if k == "fontColor" then return self._color end
  if k == "ctl" then return self._ctl end
  return Label[k]
end

-- 把当前 文本 / 字号 / 颜色 / 对齐 / 几何 写入文本框。
--   平台行为：**文本内容超出文本框范围则整段不显示**（官方《概念介绍 / 功能 / 通用组件 / 铭牌》：
--   「若配置的文本内容超出文本框的范围，则不会显示」，`docs/ugc_official/概念介绍/功能/通用组件/铭牌.md` L223）。
--   实测（2026-10-11）：字号 26 的横幅标题可见，字号 14 / 12 的小字整段消失 ⇒ 平台文本布局存在一个
--   「不低于约 40」的行高下限，框太矮就会被判为溢出。故**框高给绝对下限 `TEXT_MIN_H`**（而非按字号比例）。
--   宽度按「字符数 × 字号 × 1.35 + 24」估算并取大，避免长文本溢出。
--   对齐锚边保持不变：左对齐固定左缘、右对齐固定右缘、居中固定中心（框变宽不改变文字的可见位置）。
local function labelApply(self)
  local c = self._ctl
  if c == nil then return end
  local size = self._size
  local w = self._w or 0
  local n = #utf8chars(self._text or "")
  local padW = max(w, n * size * 1.35 + 24, 60)
  local padH = max(size * 2.0, TEXT_MIN_H)
  local cx = self._x
  if self._align == "left" then
    cx = self._x - w * 0.5 + padW * 0.5
  elseif self._align == "right" then
    cx = self._x + w * 0.5 - padW * 0.5
  end
  local ok = pcall(function()
    c.text = self._text or ""
    c.fontSize = max(1, floor(size + 0.5))
    c.fontColor = self._color
    c.horizontalAlignment = self._halign
    c:SetSizeDelta(padW, padH)
    c:SetAnchoredPosition(cx, self._y)
    c:SetLocalRotation(0, 0, 0)
    c:SetLocalScale(1, 1, 1)
  end)
  if not ok then printerr("[坦克动荡] 文本框属性写入失败") end
end

function Label:SetVisible(v)
  v = v and true or false
  if self._vis == v then return end
  self._vis = v
  pcall(function() self._ctl:SetVisible(v) end)
end

function Label:SetAsLastSibling()
  pcall(function() self._ctl:SetAsLastSibling() end)
end

-- 重定位（准备页主菜单共用同一批 Label，需按实际人数居中 / 分列）
function Label:SetPos(x, y)
  self._x, self._y = x, y
  labelApply(self)
end

-- 轻量整体变换：在「基准位（self._x/self._y）」上叠加 平移 / 旋转 / 缩放。
-- 供主菜单横幅逐帧 bob（位置 + 旋转 + 缩放）与悬停放大使用，避免每帧重建。
function Label:SetTransform(dx, dy, rot, scale)
  dx, dy = dx or 0, dy or 0
  rot, scale = rot or 0, scale or 1
  pcall(function()
    self._ctl:SetAnchoredPosition(self._x + dx, self._y + dy)
    self._ctl:SetLocalRotation(0, 0, rot)
    self._ctl:SetLocalScale(scale, scale, 1)
  end)
end

-- 属性写入拦截：text / fontColor 同步到文本框；其余原样落表
--   text 变化必须重跑 labelApply：框宽是按字符数估出来的，文本变长（如计分 0→12）要跟着放大，
--   否则会触发「内容超出框范围则整段不显示」。
function Label:__newindex(k, v)
  if k == "text" then
    if self._text ~= v then
      self._text = v or ""
      labelApply(self)
    end
  elseif k == "fontColor" then
    self._color = v
    pcall(function() self._ctl.fontColor = v end)
  else
    rawset(self, k, v)
  end
end

local function makeLabel(x, y, w, size, text, align)
  local self = setmetatable({}, Label)
  rawset(self, "_x", x)
  rawset(self, "_y", y)
  rawset(self, "_w", w)
  rawset(self, "_size", size)
  local ak = alignKey(align)
  rawset(self, "_align", ak)
  rawset(self, "_halign", ak == "left" and THA.left or (ak == "right" and THA.right or THA.mid))
  rawset(self, "_text", text or "")
  rawset(self, "_color", COLOR.TEXT)
  rawset(self, "_vis", false)
  rawset(self, "_ctl", createTextBox())
  labelApply(self)
  return self
end

-- 舞台 y（0=顶，480=底）→ UI y（以舞台中心为原点）
local function stageY(sy) return (STAGE_H / 2 - sy) * STAGE_SCALE end

-- ------------------------------------------------------------
-- 计分板迷你坦克图标
-- 原版 tankIcon = main.swf chid 136（ImportAssets2 "tank"，来自 Assets/Tank.swf 的
-- DefineSprite_304），是 3/4 斜视角的装饰坦克（旗子/炮塔/配件，约 131×68px）。
-- 6 种基础形状无法忠实复刻 3/4 视角 → 用「俯视坦克等比缩小、朝右」近似；
-- p2 整体水平镜像（对应原版 tankIcon._xscale = -100）。
-- 坐标以图标中心为原点、前方 = +x（Flash px）；渲染时尺寸与偏移统一 ×STAGE_SCALE。
-- ------------------------------------------------------------
local SCORE_ICON_ART = {
  -- 左右履带（各 52×10，偏暗）
  { "square", 52, 10, 0.55, 0, -13, 0 },
  { "square", 52, 10, 0.55, 0, 13, 0 },
  -- 中央车体
  { "square", 46, 22, 1.00, 0, 0, 0 },
  -- 前伸炮管（含高光细条）
  { "square", 24, 7, 0.62, 26, 0, 0 },
  { "square", 24, 3, 0.95, 26, 0, 0 },
  -- 炮塔（外→内三层同心圆，压在车体/炮管之上）
  { "circle", 22, 22, 0.62, 2, 0, 0 },
  { "circle", 16, 16, 0.82, 2, 0, 0 },
  { "circle", 10, 10, 1.00, 2, 0, 0 },
}

-- 构建图标：返回部件表 { shape, ctl, lx, ly }（lx/ly 为 UI 偏移，已含 mirror 翻转）
local function buildScoreIcon(baseColor, mirror)
  local s = STAGE_SCALE
  local parts = {}
  for i = 1, #SCORE_ICON_ART do
    local a = SCORE_ICON_ART[i]
    local ctl = acquire(a[1])
    if ctl ~= nil then
      local lx, ly, lrot = a[5] * s, a[6] * s, a[7]
      if mirror then lx = -lx; lrot = -lrot end
      pcall(function()
        ctl:SetSizeDelta(a[2] * s, a[3] * s)
        ctl.imageColor = shade(baseColor, a[4])
        ctl:SetLocalRotation(0, 0, lrot)
      end)
      parts[#parts + 1] = { shape = a[1], ctl = ctl, lx = lx, ly = ly }
    end
  end
  return parts
end

-- 摆位：屏幕固定 HUD，直接给 UI 坐标（不经 toUI，故不随镜头/shake 移动）
local function placeScoreIcon(parts, cx, cy)
  for i = 1, #parts do
    local p = parts[i]
    pcall(function() p.ctl:SetAnchoredPosition(cx + p.lx, cy + p.ly) end)
  end
end

function updateScoreHUD()
  for i = 1, #hud.scoreLabels do
    local lab = hud.scoreLabels[i]
    if lab ~= nil then
      local t = G.tanks[i]
      pcall(function() lab.text = tostring(t and t.score or 0) end)
    end
    -- 玩家名（本机优先用服务器下发的名字）
    local nm = hud.nameLabels[i]
    if nm ~= nil then
      local t = G.tanks[i]
      local name = (t ~= nil and t.aiName) or ("玩家 " .. i)
      if i == G.playerIndex and G.playerName ~= nil then name = G.playerName end
      pcall(function() nm.text = name end)
    end
    -- 实时延迟：只有「本机玩家」这一格有意义（其余显示 --）
    local pg = hud.pingLabels[i]
    if pg ~= nil then
      local mine = (i == G.playerIndex)
      local txt = (mine and G.pingMs ~= nil) and (tostring(floor(G.pingMs + 0.5)) .. "ms") or "--"
      pcall(function()
        pg.text = txt
        pg.fontColor = (mine and G.pingMs ~= nil) and COLOR.OK or COLOR.DIM
      end)
    end
  end
end

-- 计分板布局。取自 frame_53/setupBattle（参考）：
--   2 人：p1 _x=MOVIEWIDTH/2-150=196、p2 _x=MOVIEWIDTH/2+190=536，_y=MOVIEHEIGHT-25=455；
--   3 人：p1 166、p2 346、p3 566，_y 同为 455。
-- 规律：最后一个板「水平镜像」——图标在右、数字在左，且坦克图标 _xscale=-100（左右翻转）；
--       其余板图标在左、数字在右。
-- → UI：boardX = (x - STAGE_W/2)*STAGE_SCALE、boardY = stageY(455)。
local function layoutScoreHUD()
  -- 不同模式图标镜像方向不同，须先把旧图标控件归还控件池再重建，否则残留旧排布
  for i = 1, #hud.icons do vfree(hud.icons[i]) end
  hud.icons = {}
  for i = 1, #hud.scoreLabels do
    local lab = hud.scoreLabels[i]
    if lab ~= nil then pcall(function() lab:SetVisible(false) end) end
  end
  -- 名字 / 延迟标签同理：模式切换（人数变化）时旧标签必须先隐藏再重建，否则会残留
  for i = 1, #hud.nameLabels do
    local lab = hud.nameLabels[i]
    if lab ~= nil then pcall(function() lab:SetVisible(false) end) end
  end
  for i = 1, #hud.pingLabels do
    local lab = hud.pingLabels[i]
    if lab ~= nil then pcall(function() lab:SetVisible(false) end) end
  end
  hud.scoreLabels = {}
  hud.nameLabels = {}
  hud.pingLabels = {}
  hud.scoreBox = {}

  local n = #G.tanks
  local boardX = (n <= 2) and { 196, 536 } or { 166, 346, 566 }
  local by = ARENA_OY - ARENA_H / 2 - 57   -- 下方边框带中心（竞技场下缘 -205 → 约 -262）
  local iconDX, iconDY = 15, -3.75   -- 图标中心相对板中心（UI px，朝外）
  local digDX = 38                    -- 数字外缘相对板中心（UI px，朝内）
  local digitW, digitSize = 240, 22   -- 字号 = 原版 YaHei 18 flash px × STAGE_SCALE ≈ 22

  for i = 1, n do
    local bx = (boardX[i] - STAGE_W / 2) * STAGE_SCALE
    local mirrored = (i == n)         -- 最后一个板：图标在右、数字在左、图标水平镜像
    local t = G.tanks[i]
    hud.icons[i] = buildScoreIcon((t ~= nil and t.baseColor) or COLOR.P1, mirrored)
    if mirrored then
      placeScoreIcon(hud.icons[i], bx + iconDX, by + iconDY)
      hud.scoreLabels[i] = makeLabel(bx - digDX - digitW * 0.5, by, digitW, digitSize, "0", "right")
    else
      placeScoreIcon(hud.icons[i], bx - iconDX, by + iconDY)
      hud.scoreLabels[i] = makeLabel(bx + digDX + digitW * 0.5, by, digitW, digitSize, "0", "left")
    end
    hud.scoreLabels[i].fontColor = COLOR.HUD_TEXT
    -- 玩家名（板上方）+ 实时延迟 ms（板下方）—— 与分数同列对齐（用户 2026-10-11：计分板每辆坦克旁
    --   显示 玩家名 / 分数 / 当前延迟(ms)）。
    local colX, colAlign
    if mirrored then colX = bx - digDX - digitW * 0.5; colAlign = "right"
    else colX = bx + digDX + digitW * 0.5; colAlign = "left" end
    hud.nameLabels[i] = makeLabel(colX, by + 21, digitW, 15, "", colAlign)
    hud.nameLabels[i].fontColor = COLOR.HUD_TEXT
    hud.pingLabels[i] = makeLabel(colX, by - 21, digitW, 15, "--", colAlign)
    hud.pingLabels[i].fontColor = COLOR.DIM
    -- 碎裂特效发射区（数字字形附近的包围盒，UI 坐标）：cx = 数字水平中心、half = 半宽、
    --   cy = 板中心线、h = 字高（原版碎片在 score 文本框「上半高」内散布）。
    local cx = mirrored and (bx - digDX - digitSize * 0.55) or (bx + digDX + digitSize * 0.55)
    hud.scoreBox[i] = { x = cx, half = digitSize * 0.7, y = by, h = digitSize }
  end
  -- 对战倒计时（战斗页顶部边框带中央）+ 对局结算提示（完成后居中显示）
  if hud.timerLabel == nil then
    hud.timerLabel = makeLabel(0, ARENA_OY + ARENA_H / 2 + 8, 320, 24, "", "mid")
    hud.timerLabel.fontColor = COLOR.HUD_TEXT
  end
  if hud.resultLabel == nil then
    hud.resultLabel = makeLabel(0, 0, 760, 34, "", "mid")
    hud.resultLabel.fontColor = COLOR.HUD_TEXT
  end
  updateScoreHUD()
end

-- ============================================================
-- ⑧.4 计分板碎裂特效（原版 DefineSprite_166.add）
-- ============================================================
-- 原版：某玩家加分时，在其计分板数字处爆出
--   · 8 枚碎片：lineStyle(2, 0x373737) 短线段（两随机点(random(10)-5)连成的短线，长 ≤ ~13px），
--       初速 dir∈[45°,135°]、speed∈[1.5,4.5]（向上抛射），重力 0.2、摩擦 0.97、自旋 ±60°/帧；
--       落到计分板基线下方 13px（flash y > MOVIEHEIGHT-25+13）后停住并淡出（_alpha -= 5）。
--   · 40 团烟云：8px 灰点（0x44~0x77、alpha 40~59），向上慢速飘散、逐帧 +2% 膨胀、
--       摩擦 0.93/0.95、alpha 每帧 -= (5-random*3)，归零即移除。
-- 空间：计分板是屏幕固定 HUD，故粒子在 UI 坐标（非世界坐标 toUI），随 HUD 一起显示 / 隐藏。
local SB = {
  grav     = 0.2,   -- flash px/帧²（原版 yspeed += 0.2）
  friction = 0.97,  -- 原版 xspeed *= 0.97
  spinDec  = 0.99,  -- 原版 rotspeed *= 0.99
  numFrag  = 8,     -- 原版 NUMBEROFFRAGMENTS
  numSmoke = 40,    -- 原版 NUMBEROFSMOKECLOUDS(=10) * 4
}

local function freeBurstParticle(p)
  if p.ctl ~= nil then release(p.shape, p.ctl); p.ctl = nil end
end

clearScoreBursts = function()
  for i = 1, #hud.frags do freeBurstParticle(hud.frags[i]) end
  hud.frags = {}
end

spawnScoreBurst = function(idx)
  local box = hud.scoreBox[idx]
  if box == nil then return end
  local vs = G.VS
  local rnd = math.random
  -- 碎片
  for _ = 1, SB.numFrag do
    local a = vpart("square", 1, 2, col(0x37, 0x37, 0x37), 0, 0, 0)
    if a ~= nil then
      local p1x, p1y = rnd() * 10 - 5, rnd() * 10 - 5
      local p2x, p2y = rnd() * 10 - 5, rnd() * 10 - 5
      local len = sqrt((p1x - p2x) * (p1x - p2x) + (p1y - p2y) * (p1y - p2y))
      if len < 2 then len = 2 end
      local dir = 0.785398 + rnd() * PI * 0.5          -- [45°,135°]
      local speed = rnd() * 3 + 1.5                    -- [1.5,4.5]
      hud.frags[#hud.frags + 1] = {
        kind = "frag", shape = "square", ctl = a.ctl,
        x = box.x + (rnd() * 2 - 1) * box.half,
        y = box.y + rnd() * box.h * 0.5,
        vx = cos(dir) * speed / 1.5 * vs,
        vy = sin(dir) * speed / 1.5 * vs,              -- 向上（UI y 增）
        rot = rnd() * 360, spin = rnd() * 120 - 60,
        len = len, a = 255, color = col(0x37, 0x37, 0x37),
      }
    end
  end
  -- 烟云
  for _ = 1, SB.numSmoke do
    local g = floor(rnd() * 4 + 4) * 0x11            -- 0x44~0x77
    local a = vpart("circle", 8, 8, col(g, g, g), 0, 0, 0)
    if a ~= nil then
      hud.frags[#hud.frags + 1] = {
        kind = "smoke", shape = "circle", ctl = a.ctl,
        x = box.x + (rnd() * 2 - 1) * box.half,
        y = box.y + rnd() * box.h * 0.75,
        vx = (rnd() * 1.5 - 0.75) * vs,
        vy = (2.5 - rnd()) * vs,                      -- 原版 yspeed∈[-2.5,-1.5] → 向上
        grow = 1, size = 8,
        a = (40 + rnd() * 20) / 100 * 255,
        color = col(g, g, g),
      }
    end
  end
end

stepScoreBursts = function()
  local vs = G.VS
  local groundY = stageY(STAGE_H - 25 + 13)   -- 原版落地判定：y > MOVIEHEIGHT-25+13
  for i = #hud.frags, 1, -1 do
    local p = hud.frags[i]
    if p.kind == "frag" then
      p.x = p.x + p.vx
      p.y = p.y + p.vy
      p.vx = p.vx * SB.friction
      p.vy = p.vy - SB.grav * vs
      if p.y <= groundY then p.landed = true end
      p.spin = p.spin * SB.spinDec
      p.rot = p.rot + p.spin
      if p.landed or (abs(p.vx) < 0.5 * vs and abs(p.vy) < 0.5 * vs) then
        p.a = p.a - 5 * 2.55      -- 原版 _alpha -= 5（0-100 尺度 → 0-255）
      end
    else
      p.x = p.x + p.vx
      p.y = p.y + p.vy
      p.vx = p.vx * 0.93
      p.vy = p.vy * 0.95
      p.grow = p.grow * 1.02     -- 原版 _xscale/_yscale += 2
      p.a = p.a - (5 - math.random() * 3) * 2.55
    end
    if p.a <= 0 then
      freeBurstParticle(p)
      table.remove(hud.frags, i)
    else
      local c = p.ctl
      pcall(function()
        if p.kind == "frag" then
          c:SetSizeDelta(p.len * vs, 2 * vs)
          c:SetLocalRotation(0, 0, -p.rot)
        else
          c:SetSizeDelta(p.size * p.grow * vs, p.size * p.grow * vs)
        end
        c.imageColor = alphaOf(p.color, floor(p.a))
        c:SetAnchoredPosition(p.x, p.y)
      end)
    end
  end
end

-- ============================================================
-- ⑮ 输入
-- ============================================================
local function eventType(name)
  local ok, ev = pcall(function() return Enum.KeyEventType[name] end)
  if ok then return ev end
  return nil
end

local function bindKey(name, cb, tag)
  if host == nil then return false end
  local ev = eventType(name)
  if ev == nil then
    print("[坦克动荡] 运行时无此按键事件：" .. name .. "（" .. tag .. "）")
    return false
  end
  local ok, err = pcall(function() host:AddKeyEventListener(ev, cb) end)
  if not ok then printerr("[坦克动荡] 注册按键失败：" .. name .. " - " .. tostring(err)) end
  return ok
end

-- 可绑定键位清单（来自《客户端控件API文档》Enum.KeyboardKeyCode / Enum.KeyEventType）。
--   id    = 事件名去掉「Keyboard」前缀与「Down/Up」后缀；实际事件名 = "Keyboard"..id.."Down"/"Up"。
--   label = 按键设置弹窗里的显示名（取短，且字形表须有对应字符）。
-- 平台键盘无字母 B / C / M / N，也无 Esc；F5-F10 易与系统功能冲突，故均不纳入。
local BINDABLE = {
  { id = "CraftspersonKey1",  label = "1" },  { id = "CraftspersonKey2",  label = "2" },
  { id = "CraftspersonKey3",  label = "3" },  { id = "CraftspersonKey4",  label = "4" },
  { id = "CraftspersonKey5",  label = "5" },  { id = "CraftspersonKey6",  label = "6" },
  { id = "CraftspersonKey7",  label = "7" },  { id = "CraftspersonKey8",  label = "8" },
  { id = "CraftspersonKey9",  label = "9" },  { id = "CraftspersonKey10", label = "0" },
  { id = "CraftspersonKey11", label = "U" },  { id = "CraftspersonKey12", label = "Z" },
  { id = "CraftspersonKey13", label = "Y" },  { id = "CraftspersonKey14", label = "G" },
  { id = "CraftspersonKey15", label = "H" },  { id = "CraftspersonKey16", label = "I" },
  { id = "CraftspersonKey17", label = "O" },  { id = "CraftspersonKey18", label = "P" },
  { id = "CraftspersonKey19", label = "J" },  { id = "CraftspersonKey20", label = "K" },
  { id = "CraftspersonKey21", label = "L" },  { id = "CraftspersonKey22", label = "V" },
  { id = "CraftspersonKey29", label = "`" },  { id = "CraftspersonKey30", label = "-" },
  { id = "CraftspersonKey31", label = "=" },  { id = "CraftspersonKey32", label = "[" },
  { id = "CraftspersonKey33", label = "," },  { id = "CraftspersonKey34", label = "." },
  { id = "CraftspersonKey35", label = "/" },
  { id = "CraftspersonKey36", label = "↑" },  { id = "CraftspersonKey37", label = "↓" },
  { id = "CraftspersonKey38", label = "←" },  { id = "CraftspersonKey39", label = "→" },
  { id = "CraftspersonKey40", label = "右Ctrl" }, { id = "CraftspersonKey41", label = "右Shift" },
  { id = "CraftspersonKey42", label = "退格" },   { id = "CraftspersonKey43", label = "大写锁" },
  { id = "MoveForwardKey",  label = "W" }, { id = "MoveBackwardKey", label = "S" },
  { id = "MoveLeftKey",     label = "A" }, { id = "MoveRightKey",    label = "D" },
  { id = "SwitchToWalkOrRunKey", label = "左Ctrl" },
  { id = "SprintKey",       label = "鼠右" },
  -- 空格 = **游戏内暂停**（原版 frame_53 的 settings 剪辑监听空格）⇒ **不可绑定**，故不纳入本表。
  { id = "DropKey",         label = "X" },
  { id = "OpenShortcutWheelKey", label = "Tab" },
  { id = "InteractKey",     label = "F" },
  { id = "NormalAttackKey", label = "鼠左" },
  { id = "CharacterSkill1Key", label = "E" }, { id = "CharacterSkill2Key", label = "Q" },
  { id = "CharacterSkill3Key", label = "R" }, { id = "CharacterSkill4Key", label = "T" },
}
local BIND_LABEL = {}
for i = 1, #BINDABLE do BIND_LABEL[BINDABLE[i].id] = BINDABLE[i].label end

-- 5 个操作，按键设置弹窗行序即此顺序。
local ACTIONS = {
  { key = "fwd",   label = "前进" },
  { key = "back",  label = "后退" },
  { key = "left",  label = "左转" },
  { key = "right", label = "右转" },
  { key = "fire",  label = "开火" },
}
local ACTION_LABEL = {}
for i = 1, #ACTIONS do ACTION_LABEL[ACTIONS[i].key] = ACTIONS[i].label end

-- 键位模型（2026-10-11 二次重构）：
--   * 方案 1（红 / 1P）=「字母键位」：**默认 ESDF + Q**；4 个移动键 + 开火 = **5 个键全部可自定义**。
--   * 方案 2（绿 / 2P）=「方向键」：移动键**固定** ↑↓←→（不可改），**只有开火键可自定义**（默认 ","）。
--   ⇒ 按键设置页共 **6 个可调整按键**（方案 1 的 5 个 + 方案 2 的开火）。
--   **不再提供预设键位切换**（用户 2026-10-11 决定）：因为空格已被「暂停」占用、不能作为开火键，
--   原来的 WASD+空格 预设失去意义 ⇒ 只保留"自定义"一种形态。
--   原版权威来源：reference/.../frame_53/DoAction.as L862-874（deployTank 的三套控制方案）
local DEFAULT_BINDS = {
  -- 方案 1（红 / 1P）：E S F D + Q（原版键码 69/83/70/68/81，与键盘物理布局一致）
  { fwd = "CharacterSkill1Key", back = "MoveRightKey", left = "MoveBackwardKey",
    right = "InteractKey", fire = "CharacterSkill2Key" },
  -- 方案 2（绿 / 2P）：↑ ↓ ← → + ,（原版 2P 开火为 M；平台无 M，故用 ","）
  { fwd = "CraftspersonKey36", back = "CraftspersonKey37", left = "CraftspersonKey38",
    right = "CraftspersonKey39", fire = "CraftspersonKey33" },
}

local function cloneBinds(src)
  local t = {}
  for s = 1, #src do
    t[s] = {}
    for i = 1, #ACTIONS do t[s][ACTIONS[i].key] = src[s][ACTIONS[i].key] end
  end
  return t
end

local BINDS = cloneBinds(DEFAULT_BINDS)
-- 反查表：keyId -> { {scheme=, action=}, ... }
local BIND_REV = {}
local function rebuildBinds()
  BIND_REV = {}
  for s = 1, #BINDS do
    for i = 1, #ACTIONS do
      local a = ACTIONS[i].key
      local k = BINDS[s][a]
      if k ~= nil then
        local l = BIND_REV[k]
        if l == nil then l = {}; BIND_REV[k] = l end
        l[#l + 1] = { scheme = s, action = a }
      end
    end
  end
end
rebuildBinds()

-- 按键设置页状态：捕获新键 / 各键当前是否按下（判断「新按下」）/ 已启用的返回键（保留键，不参与绑定）。
--   justEnded 用于「刚绑定完的那一帧」吞掉确认边沿：绑定键本身常与确认键同源（如 Q），
--   否则新按下会被立刻当成又一次「开始改键」。
local CAPTURE = { active = false, scheme = nil, action = nil, justEnded = false,
                  keydown = {}, returnId = nil }
local refreshKeyRows   -- 前向声明：菜单段赋值（刷新按键设置页文本）

-- 追加型 Down 回调表：某些动作（如返回键）与「玩家输入」共用同一个按键事件。
-- 千星奇域同一事件里，前一个回调返回 true（已处理）会阻止后续回调响应，
-- 因此不能再对同一事件单独 AddKeyEventListener，而要在 setupInput 的统一 Down 回调
-- 末尾统一调用本表（按事件全名 "KeyboardXXXDown" 索引；调用时才索引，保证后注册者也生效）。
local EXTRA_DOWN = {}

-- 完成一次按键捕获：把 keyId 绑到当前槽位。
-- 注意：**故意不做「冲突自动交换」**——允许改出重复键，再由页面标红并禁止返回
-- （用户要求：自定义按键冲突时不能保存退出）。
local function completeCapture(keyId)
  local s, a = CAPTURE.scheme, CAPTURE.action
  CAPTURE.active, CAPTURE.scheme, CAPTURE.action = false, nil, nil
  CAPTURE.justEnded = true
  if s == nil or a == nil then return end
  BINDS[s][a] = keyId
  rebuildBinds()
  if refreshKeyRows ~= nil then refreshKeyRows() end
end

-- 键位冲突检测：两套方案的全部动作键必须两两不同，否则对局中会互相误触。
-- 返回「重复键集合」与「第一个重复键 id」。
local function duplicateKeySet()
  local cnt = {}
  for s = 1, #BINDS do
    for i = 1, #ACTIONS do
      local k = BINDS[s][ACTIONS[i].key]
      if k ~= nil then cnt[k] = (cnt[k] or 0) + 1 end
    end
  end
  local dup, first = {}, nil
  for k, c in pairs(cnt) do
    if c > 1 then dup[k] = true; if first == nil then first = k end end
  end
  return dup, first
end

local function findBindConflict()
  local _, first = duplicateKeySet()
  return first
end

local function setupInput()
  -- 原版：**空格 = 暂停 / 继续**（frame_53 的 settings 剪辑监听空格，见 reference 源码）。
  --   空格因此**不参与游戏绑定**（已从 BINDABLE 移出）。
  --   仅单机生效：openBattleSettings 内部对 G.online 直接 return ⇒ 联机不会暂停。
  bindKey("KeyboardJumpKeyDown", function()
    ---@diagnostic disable-next-line: undefined-global
    local M = MENU   -- MENU 是后置赋值的全局，此处只在按键回调运行期取用
    if M.phase == "playing" then
      M.openBattleSettings()
    elseif M.phase == "settings" and M.fromBattle then
      M.leaveBattleSettings()
    end
  end)
  -- 同一事件名可能同时驱动菜单与某号玩家的坦克（如 S 既是菜单「下移」又是红方左转），
  -- 因此必须把动作合并成「每个事件名只注册一次监听」，否则后注册者会覆盖前者。
  local reg = {}
  local function add(ev, isDown, fn)
    local r = reg[ev]
    if r == nil then r = { down = {}, up = {} }; reg[ev] = r end
    if isDown then r.down[#r.down + 1] = fn else r.up[#r.up + 1] = fn end
  end
  local function menuBind(ev, key)
    add(ev, true,  function() G.input[key] = true end)
    add(ev, false, function() G.input[key] = false end)
  end

  -- 菜单导航：**统一写死 WASD**（与「按键设置」里给玩家自定义的键位无关——那套只作用于游戏内操作）。
  --   W/S = 上下选行，A/D = 左右切换；确认/点击 = F。手柄（十字键/左摇杆 + A）与鼠标照旧可用。
  menuBind("KeyboardMoveForwardKey",  "fwd")
  menuBind("KeyboardMoveBackwardKey", "back")
  menuBind("KeyboardMoveLeftKey",     "left")
  menuBind("KeyboardMoveRightKey",    "right")
  -- 方向键同样参与菜单导航（用户 2026-10-11）：↑↓ = 选择、←→ = 调整，与 W S A D 完全等效。
  --   与「按键设置」里方案 2 的移动键是同一批事件，二者通过 add() 合并到同一监听，互不覆盖。
  menuBind("KeyboardCraftspersonKey36", "fwd")    -- ↑
  menuBind("KeyboardCraftspersonKey37", "back")   -- ↓
  menuBind("KeyboardCraftspersonKey38", "left")   -- ←
  menuBind("KeyboardCraftspersonKey39", "right")  -- →
  -- 菜单确认：F（交互键）/ 鼠标左键
  menuBind("KeyboardInteractKey",     "fire")
  menuBind("KeyboardNormalAttackKey", "fire")
  -- 鼠标左键同时驱动鼠标坦克开火（原版第 3 台的 onMouseDown → fire）。
  -- 与上面的菜单确认共存：菜单里它仍是确认键，对局中它变成第 3 台的开火键。
  add("KeyboardNormalAttackKey", true,  function() G.pmouse.fire = true  end)
  add("KeyboardNormalAttackKey", false, function() G.pmouse.fire = false end)

  -- 手柄：十字键 + A 键，写入 G.gpKey；左摇杆由 pollGamepad 每帧轮询，
  -- 二者在 pollGamepad 里合成最终输入 G.gp（见该函数）。事件名见《客户端控件API文档》。
  local function padBind(ev, key)
    add(ev, true,  function() G.gpKey[key] = true  end)
    add(ev, false, function() G.gpKey[key] = false end)
  end
  padBind("ControllerCharacterSkill3Key", "fwd")    -- 十字键上
  padBind("ControllerCraftspersonKey2",   "back")   -- 十字键下
  padBind("ControllerCraftspersonKey1",   "left")   -- 十字键左
  padBind("ControllerCharacterSkill4Key", "right")  -- 十字键右
  padBind("ControllerJumpKey",            "fire")   -- A

  -- 玩家坦克输入：为「全部可绑定键」注册统一派发。
  -- 玩家动作绑定在运行时可改（见 BINDS），故不把事件名写死，而是让每个键都进 dispatch，
  -- 再由 BIND_REV 反查该键当前驱动哪些玩家（scheme）的哪些动作。
  -- 按键设置页捕获新键时，dispatch 把「首次按下」优先交给 completeCapture。
  local function dispatch(id, isDown)
    local was = CAPTURE.keydown[id] or false
    CAPTURE.keydown[id] = isDown
    if CAPTURE.active then
      -- 返回键留给「取消」；其余键的首次按下即完成绑定
      if isDown and not was and id ~= CAPTURE.returnId then completeCapture(id) end
      return
    end
    local lst = BIND_REV[id]
    if lst ~= nil then
      for i = 1, #lst do
        local e = lst[i]
        local pi = G.pinputs[e.scheme]
        if pi ~= nil then pi[e.action] = isDown end
      end
    end
  end
  for i = 1, #BINDABLE do
    local id = BINDABLE[i].id
    add("Keyboard" .. id, true,  function() dispatch(id, true)  end)
    add("Keyboard" .. id, false, function() dispatch(id, false) end)
  end

  local okAny = false
  for ev, r in pairs(reg) do
    if eventType(ev .. "Down") ~= nil then
      okAny = true
      bindKey(ev .. "Down", function()
        for i = 1, #r.down do r.down[i]() end
        local ex = EXTRA_DOWN[ev .. "Down"]
        if ex ~= nil then for i = 1, #ex do ex[i]() end end
        return true
      end, ev)
      bindKey(ev .. "Up",   function() for i = 1, #r.up   do r.up[i]()   end; return true end, ev)
    else
      print("[坦克动荡] 运行时无此按键事件：" .. ev .. "（输入）")
    end
  end
  if not okAny then print("[坦克动荡] 未找到可用按键，请检查 Enum.KeyEventType") end
end

-- 手柄左摇杆死区。左摇杆为手柄的主控制方式（采纳推荐方案），十字键与 A 键事件作为补充。
local GP_DEADZONE = 0.35

-- 每帧轮询手柄：左摇杆轴值 + 十字键/A 事件 → 合成最终输入 G.gp。
-- 平台可能不提供 GetControllerLeftStickAxis（如离线测试桩件），故用 pcall 包容并退化为仅事件输入。
local function pollGamepad()
  local h, v = 0, 0
  pcall(function()
    local a, b = game.GetControllerLeftStickAxis()
    if type(a) == "number" then h = a end
    if type(b) == "number" then v = b end
  end)
  G.gpStick.h, G.gpStick.v = h, v
  local k, gp, dz = G.gpKey, G.gp, GP_DEADZONE
  gp.fwd   = (v >  dz) or k.fwd
  gp.back  = (v < -dz) or k.back
  gp.left  = (h < -dz) or k.left
  gp.right = (h >  dz) or k.right
  gp.fire  = k.fire
end

-- ============================================================
-- ⑯ 菜单
--   本地化说明（原版 → 本移植）：
--     联机对战   原版走 XMLSocket 连 5 台 .tanktrouble.com 服务器；
--                千星奇域内无法连外部服务器，改为本地单人对战 AI。
--     成就/统计  原版 Base64 混淆后 POST 到 pixvi.net；
--                改为本地累计与本地成就记录，不联网、不上传。
--     自定义迷宫 原版从外部迷宫数据源拉取；本地暂无数据源，仅「随机迷宫」生效。
--   均为后端行为，不做界面暴露。
-- ============================================================
MENU = {
  phase = "menu",           -- menu | settings | keys | devices | rules | other | ready | playing
  lastPhase = nil,          -- 用于切页时清空输入边沿缓存
  sel = 1,                  -- 主菜单选中项
  prev = { fwd = false, back = false, left = false, right = false, fire = false, keyFire = false },
  panel = nil,
  menuTexts = {},           -- [1]=标题「坦克动荡」 [2]=底部操作提示（冒烟测试回读 [1]）
  -- 主菜单横幅（原版按钮岛）：4 个模式横幅 + 齿轮（设置入口）
  banners = {},             -- { {parts=, labels=, hx=, hy=, x=, y=, rot=, scale=, animTime=, hover=}, ... }
  gear = nil,               -- 齿轮图标（图片控件）= 设置入口
  -- 「返回」按钮 + 按键提示（R / 手柄返回）：所有非主菜单页（设置 / 按键设置 / 控制方式 / 准备 / 对战）显示。
  back = nil,               -- { parts=, label=, hint= }
  backHover = false,
  soundOn = true,           -- 音效开关（与 audioApi 全局静音相反）
  mousePrev = false,        -- 鼠标左键上一帧状态（菜单内边沿检测）
  lastDev = "kb",           -- 最后操作的设备："mouse" | "kb"（鼠标/键盘/手柄共存时，以最后操作的为准）
  prevMX = nil, prevMY = nil,  -- 上一帧光标位置（用于判断鼠标是否"真的动了"）
  animTime = 0,             -- 横幅 bob 动画相位（原版 animTime）
  cursor = { x = 0, y = 0, ok = false },  -- 本帧光标 UI 坐标
  -- 设置齿轮面板（主菜单第 5 项）：控制方式 / 按键设置 / 音效开关 / 返回
  setSel = 1,
  setTexts = {},
  setHints = {},            -- 设置面板底部的 WASD / F 按键提示控件
  setRows = {},             -- { {kind=, y=, name=Label, value=Label}, ... }
  setHL = nil,
  -- 准备页（原版 controls1Player / controls2Player / mode2）
  mode = "solo",            -- 本次对局的模式
  joined = {},              -- [n] = 该参战位是否已加入
  joinPrev = {},            -- [scheme] = 上一帧的开火状态（边沿检测）
  readyTexts = {},          -- 底部提示文本 / 联机倒计时与就绪状态行
  readyRows = {},           -- { {card=, art=, name=, act=}, ... }（仅真人参战位，AI 位不画）
  readyBtns = {},           -- 下方两个按钮：按键设置 / 其他设置
  readyTimer = 0,           -- 联机准备倒计时（秒；**仅 G.online 时启用**）
  startTimer = 0,           -- 联机：30 秒到点后「3 秒游戏开始」倒计时
  colorPick = nil,          -- 联机：本地玩家选定颜色下标（1..4；nil = 未选）
  colorLocked = nil,        -- 联机：对方已准备后其颜色下标（本地不可再选）
  readyEndBeat = nil,       -- 联机：**房主**专用 —— 本准备阶段的「强制准备时刻」= 届时 TT2_BEAT 的值
  started = false,          -- 联机：本端是否已进入「3 秒开始」阶段（准备阶段结束之后）
  fallbackWarned = false,   -- 联机：是否已就「拿不到同步时钟」告警过一次（避免刷屏）
  colorSquares = {},        -- 联机准备页 4 个色块 { {x=, y=, fill=, border=} }
  PICK_COLORS = { COLOR.P1, COLOR.P2, COLOR.P3, COLOR.GRAY },   -- 红 / 绿 / 蓝 / 灰
  -- 按键设置页（原版无此页；千星奇域键位可自定义，故新增）
  keySel = 1,               -- 当前选中行（1..#keyRows，跳过隐藏行）
  keyTexts = {},            -- 标题 / 说明 / 冲突提示
  keyListTexts = {},        -- 底部「不可绑定的按键」清单（多行）
  keyRows = {},             -- { {kind="mouseBranch"|"letter"|"action", y=, name=, value=, arrows=, scheme=, action=}, ... }
  keyHL = nil,              -- 选中条
  keyConflict = nil,        -- 冲突键名（非 nil 时禁止返回）
  -- 控制方式页（主菜单第 4 项）：1~3 号玩家各选 1 种控制方式，互不相同才可保存。
  devSel = 1,               -- 当前选中行
  devDraft = {},            -- 编辑中的副本（保存前不写回 PLAYER_MODES）
  devOk = nil,              -- true 已保存 / false 校验失败 / nil 无提示
  devTexts = {},            -- 标题 / 操作提示
  devRows = {},             -- { {kind="player"|"save"|"reset", n=, y=, name=Label, value=Label}, ... }
  devHL = nil,              -- 选中条
  devMsgLabel = nil,        -- 底部提示 Label
  -- 对战设置页（原版 settingsPanel 的 Weapons / Controls 段；**联机禁止**）
  rulesSel = 1,
  rulesTexts = {},
  rulesRows = {},           -- { {kind="weapon"|"smooth"|"reset", w=, y=, name=, value=, arrows=}, ... }
  rulesHL = nil,
  -- 其他设置页（不影响游戏规则）：显示大小 / 抗锯齿 / 音乐 / 音效
  otherSel = 1,
  otherTexts = {},
  otherRows = {},           -- { {kind="uiScale"|"aa"|"music"|"sound", label=, y=, name=, value=, arrows=}, ... }
  otherHL = nil,
  musicOn = true,           -- 音乐开关（与 audioApi 的 BGM 静音相反）
  returnPhase = "settings", -- 子页（keys / rules / other）返回时回到哪一页（准备页打开的返回准备页）
}

-- 主菜单 = 原版 frame_1 的「手绘横幅按钮岛」：4 个对战模式横幅 + 齿轮（设置）+ 音效开关。
-- 平台无 skew/描边/alpha，横幅改用「深色外框矩形 + 略小白底矩形」叠出黑边。
-- 版式严格对齐原版精灵（textures/04_sprites/DefineSprite_340/351/356/328_1.png）：
--   **只有「单人玩家」的横幅内有 1 行副标题**（「电脑对战」），其余 3 个横幅只有 1 行主标题；
--   每个模式下方悬挂的灰色说明框内容 = 下表 `desc`（原版是悬停才从上方滑入的 help 框）。
-- 注意：前 3 项顺序不可变（冒烟测试按序号选中单人 / 三人）。
-- 全部挂到 MENU 字段上（本文件级 local 已达 Lua 200 上限，见 DEV_STATE §7）。
MENU.MODES = {
  { id = "solo",  title = "单人玩家",      sub = "电脑对战", desc = "对战电脑控制的 机械恶犬坦克" },
  { id = "duo",   title = "双人对战",                    desc = "两个玩家之间的对抗" },
  { id = "trio",  title = "三人对战",                    desc = "三个玩家之间的对抗" },
  { id = "duoAI", title = "双人+电脑对战",               desc = "两个玩家加一个电脑的大混战" },
}
-- 键盘 / 手柄 / 触屏导航的线性条目：1..4 = 4 个模式横幅，5 = 齿轮（设置）。
MENU.ENTRY_COUNT = #MENU.MODES + 1

-- 横幅尺寸 / 站位（UI 坐标，画布中心为原点、y 向上）
MENU.BANNER_W, MENU.BANNER_H = 196, 74
MENU.BANNER_SLOTS = {
  { x = -230, y = 20 },    -- 单人玩家
  { x = 0,    y = 20 },    -- 双人对战
  { x = 230,  y = 20 },    -- 三人对战
  { x = 0,    y = -112 },  -- 双人+电脑
}
MENU.GEAR_POS  = { x = 388, y = 248 }
-- 原版 enterFrame 每帧 animTime += 0.075（SWF 25FPS）→ 每秒 1.875；bob 振幅 2.5。
MENU.ANIM_RATE = 1.875
MENU.BOB_AMP   = 2.5

-- ============================================================
-- 主界面背景美术：**山丘剪影 + 大坦克**（照原版 frame_1 的手绘构图；平台无贴图 → 形状控件拼）
--   坐标同横幅（画布中心为原点、y 向上）。层级由 applyZOrder 决定：面板 → 本美术 → 横幅 → 文字。
--   仅在主菜单页显示（设置 / 准备 / 对战页隐藏，见 refreshMenu 的 onMenu 分支）。
-- ============================================================
-- 山丘：5 块深灰「斜置长条」叠成土丘剪影（平台无曲线 → 旋转矩形近似）
MENU.ART_HILL = {
  { x =    0, y = -70, w = 1000, h = 210, rot =   0 },
  { x = -330, y = -30, w =  560, h = 130, rot =  10 },
  { x =  330, y = -30, w =  560, h = 130, rot = -10 },
  { x = -480, y = -46, w =  340, h = 110, rot = -20 },
  { x =  480, y = -46, w =  340, h = 110, rot =  20 },
}
MENU.artParts = {}

-- 造出全部美术控件（一次性；随后由 placeMenuArt 控制显示 / 隐藏）
MENU.buildMenuArt = function()
  local parts = {}
  local function add(shape, x, y, w, h, rot, color)
    local ctl = MENU.newShape(shape, w, h, color)
    if ctl ~= nil then
      pcall(function()
        ctl:SetSizeDelta(w, h)
        ctl:SetAnchoredPosition(x, y)
        ctl:SetLocalRotation(0, 0, rot or 0)
      end)
      parts[#parts + 1] = { ctl = ctl }
    end
  end
  -- ⚠️ col() 参数是 **0~255**（见 COLOR 表：SCREEN = col(255,255,255)），不是 0~1
  local HILL1, HILL2 = col(61, 61, 66), col(33, 33, 38)
  local TRACK  = col(48, 48, 54)
  local HULL   = col(153, 153, 158)
  local TURRET = col(186, 186, 191)
  local BARREL = col(128, 128, 135)
  local WHEEL  = col(217, 217, 222)
  local DARK   = col(87, 87, 92)
  -- ① 山丘：外圈略亮 + 内圈更深，做出剪影层次
  for i = 1, #MENU.ART_HILL do
    local s = MENU.ART_HILL[i]
    add("square", s.x, s.y, s.w, s.h, s.rot, HILL1)
  end
  for i = 1, #MENU.ART_HILL do
    local s = MENU.ART_HILL[i]
    add("square", s.x, s.y - 30, s.w * 0.92, s.h * 0.78, s.rot, HILL2)
  end
  -- ② 大坦克（中心 ≈ (46,122)）：从后往前叠
  local CX, CY = 46, 122
  add("square", CX + 132, CY + 48, 176, 26, 16, BARREL)               -- 炮管
  add("circle", CX + 26,  CY + 36,  98, 98,  0, TURRET)               -- 炮塔
  add("square", CX,       CY - 4,  262, 74,  0, HULL)                 -- 车体
  add("square", CX + 10,  CY + 56,  56, 22,  0, DARK)                 -- 舱盖
  add("square", CX - 6,   CY - 42, 286, 42,  0, TRACK)                -- 侧裙 / 履带
  add("square", CX - 4,   CY - 66, 296, 30,  0, TRACK)                -- 履带下缘
  for k = 0, 4 do                                                     -- 5 个负重轮
    add("circle", CX - 104 + k * 52, CY - 40, 40, 40, 0, WHEEL)
  end
  add("square", CX - 122, CY + 4, 24, 24, 45, DARK)                   -- 车头小件
  return parts
end

-- 显示 / 隐藏主菜单美术（只碰控件可见性，不重建）
MENU.placeMenuArt = function(show)
  local on = show and true or false
  for i = 1, #MENU.artParts do
    local ctl = MENU.artParts[i].ctl
    pcall(function() ctl:SetVisible(on) end)
  end
end

-- 控制方式：1~3 号玩家各自从这 4 种里选 1 种，且互不相同才可保存（见「控制方式」页）。
--   esdf  = 方案 1 键位（字母键位，见 LETTER_PRESETS）
--   arrow = 方案 2 键位（经典 = 方向键+,）
--   mouse = 鼠标操控（原版第 3 台的 onMouseDown → 光标位置驱动 + 左键开火）
--   pad   = 手柄（左摇杆移动 + A 开火 + 十字键，见 pollGamepad）
-- 对应原版：frame_7（单人 = 红 vs 莱卡）、frame_19（双人 = 红 + 绿）、frame_31/43（三人，第 3 台鼠标）。
local CONTROL_MODES = {
  { id = "esdf",  label = "ESDF" },
  { id = "arrow", label = "方向键" },
  { id = "mouse", label = "鼠标" },
  { id = "pad",   label = "手柄" },
}
local CONTROL_LABEL = {}
for i = 1, #CONTROL_MODES do CONTROL_LABEL[CONTROL_MODES[i].id] = CONTROL_MODES[i].label end

-- 控制方式页的显示名：一律用「XXXX+X」= 四个移动键 + 开火键，键名**取自「按键设置」里当前实际绑定的键**，
-- 故把 1P 改成 WASD 后这里显示「WASD+空格」、改成自定义键位也随实际键变化；鼠标 / 手柄是固定文字。
-- 读序：方案 2（方向键）按 上/下/左/右；方案 1（字母键位）按 上/左/下/右（与键盘物理布局一致：ESDF / WASD）。
local function moveKeysLabel(scheme)
  local b = BINDS[scheme]
  if b == nil then return "?" end
  local order = (scheme == 2) and { "fwd", "back", "left", "right" }
                           or  { "fwd", "left", "back", "right" }
  local s = ""
  for i = 1, #order do
    local kid = b[order[i]]
    s = s .. ((kid ~= nil and BIND_LABEL[kid]) or "?")
  end
  return s .. "+" .. ((b.fire ~= nil and BIND_LABEL[b.fire]) or "?")
end
local function modeDisplayLabel(id)
  if id == "esdf" then return moveKeysLabel(1) end
  if id == "arrow" then return moveKeysLabel(2) end
  return CONTROL_LABEL[id] or "?"
end

-- 每位玩家（1/2/3P）当前选用的控制方式。默认与旧写法对齐（方案1 / 方案2 / 鼠标），
-- 使三人模式行为与既有测试保持一致。
local DEFAULT_PLAYER_MODES = { "esdf", "arrow", "mouse" }
local PLAYER_MODES = { DEFAULT_PLAYER_MODES[1], DEFAULT_PLAYER_MODES[2], DEFAULT_PLAYER_MODES[3] }
local PLAYERS = { name = { "玩家 1", "玩家 2", "玩家 3" },
                  color = { COLOR.P1, COLOR.P2, COLOR.P3 } }

-- 位置 n 的玩家、控制方式 mode → 参战位（scheme = 控制方案号 / mouse / pad / ai）。
local function slotForPlayer(n, mode)
  local slot = { name = PLAYERS.name[n], color = PLAYERS.color[n], ai = false }
  if mode == "mouse" then slot.mouse = true
  elseif mode == "pad" then slot.pad = true
  elseif mode == "arrow" then slot.scheme = 2
  else slot.scheme = 1 end
  return slot
end

-- 按模式生成参战位：solo = 玩家1 + 莱卡 AI；duo = 玩家1/2；trio = 玩家1/2/3。
local function buildSlots(mode)
  local slots = { slotForPlayer(1, PLAYER_MODES[1]) }
  -- 莱卡(AI)：原版 loginInfo.p2trac=2500134=#262626（车体）/ p2turc=6710886=#666666（炮塔）—— **车体与炮塔是两个颜色**
  if mode == "solo" then
    slots[#slots + 1] = { name = "莱卡", scheme = nil, color = COLOR.P4, turretColor = COLOR.P4_TURRET, ai = true }
  elseif mode == "duo" then
    slots[#slots + 1] = slotForPlayer(2, PLAYER_MODES[2])
  elseif mode == "duoAI" then
    -- 原版 mode2 = 2 真人 + 1 电脑（莱卡）：第三位恒为 AI。
    slots[#slots + 1] = slotForPlayer(2, PLAYER_MODES[2])
    slots[#slots + 1] = { name = "莱卡", scheme = nil, color = COLOR.P4, turretColor = COLOR.P4_TURRET, ai = true }
  elseif mode == "trio" then
    slots[#slots + 1] = slotForPlayer(2, PLAYER_MODES[2])
    slots[#slots + 1] = slotForPlayer(3, PLAYER_MODES[3])
  end
  return slots
end

-- 控制方式是否两两不同（保存校验；3 个玩家位都必须互不相同）。
local function modesDistinct(t)
  for i = 1, #t do
    for j = i + 1, #t do
      if t[i] == t[j] then return false end
    end
  end
  return true
end

-- 在当前控制方式上循环切换（dir = +1 / -1），返回新的方式 id。
local function cycleMode(cur, dir)
  local idx = 1
  for i = 1, #CONTROL_MODES do
    if CONTROL_MODES[i].id == cur then idx = i; break end
  end
  idx = idx + (dir or 1)
  if idx < 1 then idx = #CONTROL_MODES end
  if idx > #CONTROL_MODES then idx = 1 end
  return CONTROL_MODES[idx].id
end

local function makeTextAt(x, y, w, size, text, align)
  return makeLabel(x, y, w, size, text, align)
end

local function makeBar(x, y, w, h, color)
  local ctl = createShape("square")
  if ctl == nil then return nil end
  pcall(function()
    ctl:SetSizeDelta(w, h)
    ctl:SetAnchoredPosition(x, y)
    ctl.imageColor = color
  end)
  return ctl
end

-- 手柄图标（准备页）：纯形状控件拼出，不用外部贴图。
-- 造型 = 左右握把 + 机身 + 十字键（竖/横两条）+ A 键，共 6 个部件。
-- 每个部件记录相对偏移 (lx,ly) 与 role（body / dark / accent），颜色在 updateReadyRows 里统一染。
local PAD_ICON_ART = {
  { shape = "circle", role = "body",   lx = -38, ly = -2, w = 30, h = 30 },
  { shape = "circle", role = "body",   lx =  38, ly = -2, w = 30, h = 30 },
  { shape = "square", role = "body",   lx =   0, ly =  4, w = 92, h = 30 },
  { shape = "square", role = "dark",   lx = -23, ly =  4, w =  9, h = 24 },
  { shape = "square", role = "dark",   lx = -23, ly =  4, w = 24, h =  9 },
  { shape = "circle", role = "accent", lx =  26, ly = -5, w = 14, h = 14 },
}

-- ------------------------------------------------------------
-- 准备页「控制器图示」（对应原版 playerNControls 三帧：字母键盘 / 方向键盘 / 鼠标）
--   本移植按玩家所选控制方式显示 键盘 / 鼠标 / 手柄 图元拼图；平台限制（无贴图/渐变/曲线）
--   → 一律用方形 + 圆形近似。
--   部件格式：{ ctl=, kind="shape"|"label", shape=, lx, ly, w, h, rot, role }
--   role：base=深色底板 / key=浅色键帽 / body=中灰机身 / dark=描边 / accent=强调
-- ------------------------------------------------------------
MENU.buildCtrlArt = function(kind, fireLabel, moves)
  local parts = {}
  local function sq(lx, ly, w, h, role, rot)
    local ctl = createShape("square")
    if ctl ~= nil then
      parts[#parts + 1] = { ctl = ctl, kind = "shape", shape = "square",
                            lx = lx, ly = ly, w = w, h = h, rot = rot or 0, role = role }
    end
  end
  local function ci(lx, ly, w, h, role)
    local ctl = createShape("circle")
    if ctl ~= nil then
      parts[#parts + 1] = { ctl = ctl, kind = "shape", shape = "circle",
                            lx = lx, ly = ly, w = w, h = h, rot = 0, role = role }
    end
  end
  local function tx(lx, ly, size, s)
    -- 文字标签（笔画拼字）；role 固定 dark，placeCtrlArt 里上深色
    local lab = makeTextAt(lx, ly, 110, size, s or "", Enum.TextHorizontalAlignment.Middle)
    parts[#parts + 1] = { ctl = lab, kind = "label", lx = lx, ly = ly, role = "dark" }
  end

  if kind == "keyboard" then
    -- 键盘板（深色）+ 四枚键帽按「倒 T」排布（与原版 ESDF / 方向键的物理布局一致）；
    -- 键帽上标注**该玩家实际使用的按键**。
    sq(30, 3, 96, 68, "base")
    sq(30, 18, 26, 26, "key")   -- 上：前进
    sq(0, -12, 26, 26, "key")   -- 下排左：左转
    sq(30, -12, 26, 26, "key")  -- 下排中：后退
    sq(60, -12, 26, 26, "key")  -- 下排右：右转
    if moves ~= nil then
      tx(30, 18, 14, moves.fwd)
      tx(0, -12, 14, moves.left)
      tx(30, -12, 14, moves.back)
      tx(60, -12, 14, moves.right)
    end
    -- 左侧放大的「开火键」键帽（深色底 + 浅色面 + 键名）
    local fl = fireLabel or ""
    local fs = (#utf8chars(fl) > 1) and 15 or 20
    sq(-50, 2, 52, 52, "base")
    sq(-50, 3, 42, 42, "key")
    tx(-50, 2, fs, fl)
  elseif kind == "mouse" then
    -- 鼠标：椭圆外壳（深色描边 + 浅色体）+ 中缝 + 线缆
    ci(2, 0, 64, 94, "base")
    ci(2, 0, 54, 84, "key")
    sq(2, 20, 4, 30, "dark")
    sq(-42, 44, 34, 8, "dark", -38)
  elseif kind == "touch" then
    -- 触屏（移动端）：一块屏幕（深色外框 + 浅色屏）+ 触点高亮环 + 手指
    sq(0, 0, 80, 122, "base")
    sq(0, 0, 70, 112, "key")
    ci(14, -22, 36, 36, "accent")
    ci(14, -22, 24, 24, "dark")
  else  -- pad（手柄；原版无此控制方式，形态属移植新增）
    for i = 1, #PAD_ICON_ART do
      local a = PAD_ICON_ART[i]
      local role = "body"
      if a.role == "dark" then role = "dark" elseif a.role == "accent" then role = "accent" end
      if a.shape == "circle" then ci(a.lx, a.ly, a.w, a.h, role)
      else sq(a.lx, a.ly, a.w, a.h, role) end
    end
  end
  return parts
end

-- 摆放控制器图示（整体平移到 (x,y)，按 role 上色）
MENU.placeCtrlArt = function(art, x, y)
  if art == nil then return end
  for i = 1, #art do
    local p = art[i]
    local px, py = x + p.lx, y + p.ly
    if p.kind == "label" then
      p.ctl:SetPos(px, py)
      p.ctl.fontColor = COLOR.MENU_TEXT
      p.ctl:SetVisible(true)
    else
      local c = COLOR.MENU_ICON
      if p.role == "key" then c = COLOR.BANNER_BG
      elseif p.role == "body" then c = COLOR.SEL
      elseif p.role == "accent" then c = COLOR.ACCENT end
      pcall(function()
        p.ctl:SetSizeDelta(p.w, p.h)
        p.ctl:SetAnchoredPosition(px, py)
        p.ctl:SetLocalRotation(0, 0, p.rot or 0)
        p.ctl:SetVisible(true)
        p.ctl.imageColor = c
      end)
    end
  end
end

MENU.hideCtrlArt = function(art)
  if art == nil then return end
  for i = 1, #art do
    local p = art[i]
    pcall(function() p.ctl:SetVisible(false) end)
  end
end

-- 释放控制器图示：形状控件归还池；文字标签隐藏（触发 Label:_teardown，其笔画控件一并归还）。
MENU.freeCtrlArt = function(art)
  if art == nil then return end
  for i = 1, #art do
    local p = art[i]
    if p.kind == "label" then
      pcall(function() p.ctl:SetVisible(false) end)
    else
      release(p.shape, p.ctl)
    end
  end
end

-- 准备页面板（白底 + 黑边）；加入后底色变玩家色（对应原版 background.setRGB）。
MENU.RDY_W, MENU.RDY_H = 208, 250
MENU.buildReadyCard = function()
  return { border = makeBar(0, 0, MENU.RDY_W + 8, MENU.RDY_H + 8, COLOR.OUTLINE),
           fill   = makeBar(0, 0, MENU.RDY_W, MENU.RDY_H, COLOR.BANNER_BG) }
end

MENU.placeReadyCard = function(card, x, y, joined, color)
  if card == nil then return end
  pcall(function()
    card.border:SetSizeDelta(MENU.RDY_W + 8, MENU.RDY_H + 8)
    card.border:SetAnchoredPosition(x, y)
    card.border:SetVisible(true)
    card.border.imageColor = COLOR.OUTLINE
    card.fill:SetSizeDelta(MENU.RDY_W, MENU.RDY_H)
    card.fill:SetAnchoredPosition(x, y)
    card.fill:SetVisible(true)
    card.fill.imageColor = joined and color or COLOR.BANNER_BG
  end)
end

MENU.hideReadyCard = function(card)
  if card == nil then return end
  pcall(function() card.border:SetVisible(false) end)
  pcall(function() card.fill:SetVisible(false) end)
end

-- ------------------------------------------------------------
-- 主菜单横幅 / 齿轮 / 音效图标（全部由「图片控件 + 图片 ID」拼出，无外部贴图）
-- ------------------------------------------------------------
MENU.newShape = function(shape, w, h, color)
  local ctl = createShape(shape)
  if ctl == nil then return nil end
  pcall(function()
    ctl:SetSizeDelta(w, h)
    ctl.imageColor = color
  end)
  return ctl
end

-- 横幅静态形状层：阴影（右下偏移）+ 黑边 + 白底。
-- 说明框不再随横幅走（改为共用一块浮动说明框，跟随选中项，见 MENU.descBox）。
MENU.buildBannerArt = function()
  local parts = {}
  local function add(w, h, color, lx, ly, role)
    local ctl = MENU.newShape("square", w, h, color)
    if ctl ~= nil then
      parts[#parts + 1] = { ctl = ctl, w = w, h = h, lx = lx, ly = ly, role = role }
    end
  end
  add(MENU.BANNER_W + 6, MENU.BANNER_H + 6, COLOR.OUTLINE,    4, -4, "shadow")
  add(MENU.BANNER_W,     MENU.BANNER_H,     COLOR.OUTLINE,    0,  0, "border")
  add(MENU.BANNER_W - 9, MENU.BANNER_H - 9, COLOR.BANNER_BG,  0,  0, "fill")
  return parts
end

-- 摆一个横幅：按 (x,y,rot,scale) 给形状与文字统一做 旋转/缩放/平移（以横幅中心为轴心）。
-- 文字走 Label:SetTransform 轻量变换，不重建字形。
MENU.placeBanner = function(b, x, y, rot, scale)
  local r = rot * RAD
  local cr, sr = cos(r), sin(r)
  local function orbit(lx, ly)
    local ox, oy = lx * scale, ly * scale
    return x + ox * cr - oy * sr, y + ox * sr + oy * cr
  end
  for i = 1, #b.parts do
    local p = b.parts[i]
    local px, py = orbit(p.lx, p.ly)
    pcall(function()
      p.ctl:SetVisible(true)
      p.ctl:SetSizeDelta(p.w * scale, p.h * scale)
      p.ctl:SetAnchoredPosition(px, py)
      p.ctl:SetLocalRotation(0, 0, rot)
      if p.role == "fill" then
        -- 原版悬停时横幅底变浅绿（见 DefineSprite_356_2.png）；非悬停为白底。边框恒黑。
        -- 不可用项（触屏端三人对战）恒灰。
        if b.disabled then
          p.ctl.imageColor = COLOR.SEL
        else
          p.ctl.imageColor = b.hover and COLOR.BANNER_HOVER or COLOR.BANNER_BG
        end
      elseif p.role == "border" then
        p.ctl.imageColor = COLOR.OUTLINE
      end
    end)
  end
  for i = 1, #b.labels do
    local L = b.labels[i]
    local px, py = orbit(L.lx, L.ly)
    L.label:SetVisible(true)
    L.label:SetTransform(px - (b.hx + L.lx), py - (b.hy + L.ly), rot, scale)
  end
end

MENU.hideBanner = function(b)
  if b == nil then return end
  for i = 1, #b.parts do pcall(function() b.parts[i].ctl:SetVisible(false) end) end
  for i = 1, #b.labels do pcall(function() b.labels[i].label:SetVisible(false) end) end
end

-- 浮动说明框：跟随**当前选中横幅**的实时动画坐标（故会随 bob 轻微浮动），显示该模式说明。
-- 全页共用一块，避免像以前那样固定钉在「单人玩家」下面不动。
MENU.placeDesc = function()
  local d = MENU.descBox
  if d == nil then return end
  local b = MENU.banners[MENU.sel]
  if b == nil then
    for _, c in ipairs({ d.border, d.fill, d.label }) do
      pcall(function() c:SetVisible(false) end)
    end
    return
  end
  local dx, dy = b.x, b.y - MENU.BANNER_H / 2 - 22
  local txt = (MENU.MODES[MENU.sel] ~= nil and MENU.MODES[MENU.sel].desc) or ""
  pcall(function()
    d.border:SetVisible(true)
    d.fill:SetVisible(true)
    d.label:SetVisible(true)
    d.border:SetAnchoredPosition(dx, dy)
    d.fill:SetAnchoredPosition(dx, dy)
    d.label:SetPos(dx, dy)
  end)
  if d.label.text ~= txt then d.label.text = txt end   -- 仅变化时重建字形（避免逐帧重建）
end

MENU.hideDesc = function()
  local d = MENU.descBox
  if d == nil then return end
  for _, c in ipairs({ d.border, d.fill, d.label }) do
    pcall(function() c:SetVisible(false) end)
  end
end

-- ------------------------------------------------------------
-- 「返回」按钮 + 按键提示（R / 手柄返回）
--   菜单子页：按钮右上 (352,-272)、提示在其左侧 (268,-272)；
--   **对战期：按钮左上 (-352,-272)**、提示在其右侧 (-268,-272)（避开右上角计分板）。
--   鼠标 / 触屏均可点，键盘 R / 手柄返回照旧可用。
-- ------------------------------------------------------------
MENU.BACK_POS = { x = 352, y = -272 }
MENU.HINT_POS = { x = 268, y = -272 }
-- 对战期：**右下角**（原版位置 = 迷宫下方边框带的右端，旁边写「菜单」）。
--   注意：计分板第 3 位（蓝坦克图标 ≈ x 244）在右侧 ⇒ 按钮要更靠右、按键提示放到按钮**正下方**，
--   否则会和计分板重叠（用户反馈"提示挡住蓝色坦克"）。
MENU.BACK_POS_PLAY = { x = 396, y = ARENA_OY - ARENA_H / 2 - 57 }
MENU.HINT_POS_PLAY = { x = 396, y = ARENA_OY - ARENA_H / 2 - 97 }
-- 当前生效位置（placeBack / hitBack 共用；由 refreshMenu 按当前页切换）
MENU.backPos, MENU.hintPos = MENU.BACK_POS, MENU.HINT_POS

MENU.buildBackButton = function()
  local parts = {}
  local function add(w, h, color, lx, ly, role)
    local ctl = MENU.newShape("square", w, h, color)
    if ctl ~= nil then
      parts[#parts + 1] = { ctl = ctl, w = w, h = h, lx = lx, ly = ly, role = role }
    end
  end
  add(118, 38, COLOR.OUTLINE,   3, -3, "shadow")
  add(114, 34, COLOR.OUTLINE,   0,  0, "border")
  add(106, 26, COLOR.BANNER_BG, 0,  0, "fill")
  return parts
end

-- 按键提示控件（官方 API §21 ClientUIKeyHintControl）：按当前输入设备自动显示对应按键图标。
-- 字段 keyboardKeyCode / controllerKeyCode；平台不支持时静默降级。
-- 不传参时默认显示「返回键」（R / 手柄返回）。
MENU.buildKeyHint = function(kbCode, padCode)
  local ctl = createControl(PREFAB.KEY_HINT)
  if ctl == nil then return nil end
  pcall(function()
    ---@diagnostic disable-next-line: inject-field
    ctl.keyboardKeyCode = kbCode or Enum.KeyboardKeyCode.CharacterSkill3Key   -- 默认 R
    ---@diagnostic disable-next-line: inject-field
    ctl.controllerKeyCode = padCode or Enum.ControllerKeyCode.MenuBackKey     -- 默认手柄：菜单返回
  end)
  return ctl
end

-- 设置面板底部的 WASD / F 按键提示（用「按键提示」控件显示真实按键图标 + 用途文字）
--   布局按用户的草图（2026-10-11）：
--        [W]
--        [S]  滚动      [A][D] 切换      [F] 确认
--   —— W 竖排在 S 上方（暗示上/下），「滚动」在右侧；A D 横排（暗示左/右），「切换」在右侧。
--   用途文字（用户 2026-10-11 最终定稿）：
--     W/S = 滚动（上下滚动到另一设置行）；A/D = 切换（切换当前行的取值 / 选项）；F = 确认。
--   三个文字标签的 x = **最右侧按键中心 + 50**（用户 2026-10-12：原来离按键太远，要贴紧）。
MENU.SET_HINT_Y = -150
MENU.SET_HINT_X = { -280, -280, -80, -42, 170 }   -- W S A D F 的固定 x
MENU.SET_HINT_DY = { 18, -18, 0, 0, 0 }            -- W 抬到 S 上方
MENU.SET_HINT_LABELS = {
  { x = -230, text = "滚动" },   -- 组 1（W / S）：紧贴 W/S 右侧
  { x = 8,    text = "切换" },   -- 组 2（A / D）：紧贴 D 右侧
  { x = 220,  text = "确认" },   -- 组 3（F）：紧贴 F 右侧
}
MENU.placeSetHints = function(show)
  show = show and true or false
  local list = MENU.setHints
  if list ~= nil then
    for i = 1, #list do
      local ctl = list[i]
      local x   = MENU.SET_HINT_X[i] or (i * 46 - 200)
      local dy  = MENU.SET_HINT_DY[i] or 0
      pcall(function()
        ctl:SetVisible(show)
        if show then ctl:SetAnchoredPosition(x, MENU.SET_HINT_Y + dy) end
      end)
    end
  end
  local labels = MENU.setHintLabels
  if labels ~= nil then
    for i = 1, #labels do
      local lb = labels[i]
      pcall(function()
        lb:SetVisible(show)
        if show then lb:SetPos(MENU.SET_HINT_LABELS[i].x, MENU.SET_HINT_Y) end
      end)
    end
  end
end

MENU.placeBack = function()
  if MENU.back == nil then return end
  local bx, by = MENU.backPos.x, MENU.backPos.y
  local hover = MENU.backHover
  for i = 1, #MENU.back.parts do
    local p = MENU.back.parts[i]
    pcall(function()
      p.ctl:SetVisible(true)
      p.ctl:SetSizeDelta(p.w, p.h)
      p.ctl:SetAnchoredPosition(bx + p.lx, by + p.ly)
      if p.role == "border" then p.ctl.imageColor = hover and COLOR.ACCENT or COLOR.OUTLINE
      elseif p.role == "fill" then p.ctl.imageColor = hover and COLOR.BANNER_HOVER or COLOR.BANNER_BG end
    end)
  end
  pcall(function()
    MENU.back.label:SetVisible(true)
    MENU.back.label:SetPos(bx, by)
  end)
  if MENU.back.hint ~= nil then
    pcall(function()
      MENU.back.hint:SetVisible(true)
      MENU.back.hint:SetAnchoredPosition(MENU.hintPos.x, MENU.hintPos.y)
    end)
  end
end

MENU.hideBack = function()
  if MENU.back == nil then return end
  for i = 1, #MENU.back.parts do pcall(function() MENU.back.parts[i].ctl:SetVisible(false) end) end
  pcall(function() MENU.back.label:SetVisible(false) end)
  if MENU.back.hint ~= nil then pcall(function() MENU.back.hint:SetVisible(false) end) end
end

-- 光标是否落在「返回」按钮上（轴对齐包围盒）
MENU.hitBack = function(cx, cy)
  return math.abs(cx - MENU.backPos.x) <= 60 and math.abs(cy - MENU.backPos.y) <= 22
end

-- ------------------------------------------------------------
-- 设置行「左右切换三角」◀ ▶（用 TRI 图元，+90°→尖朝左 / -90°→尖朝右）
--   供鼠标点击：点左/右三角 == 按 A/D（左/右切换）；键盘/手柄仍走 leftE/rightE。
-- ------------------------------------------------------------
MENU.ARROW_W, MENU.ARROW_H = 17, 19

MENU.makeArrows = function()
  return {
    left  = MENU.newShape("tri", MENU.ARROW_W, MENU.ARROW_H, COLOR.ARROW),
    right = MENU.newShape("tri", MENU.ARROW_W, MENU.ARROW_H, COLOR.ARROW),
  }
end

-- 摆放某行的左右三角；on=false 时隐藏。
MENU.placeArrows = function(a, lx, rx, y, on, sel)
  if a == nil then return end
  local v = on and true or false
  local c = sel and COLOR.ACCENT or COLOR.ARROW
  pcall(function()
    a.left:SetVisible(v)
    a.right:SetVisible(v)
    if v then
      a.left:SetSizeDelta(MENU.ARROW_W, MENU.ARROW_H)
      a.left:SetAnchoredPosition(lx, y)
      a.left:SetLocalRotation(0, 0, 90)     -- 尖朝左
      a.left.imageColor = c
      a.right:SetSizeDelta(MENU.ARROW_W, MENU.ARROW_H)
      a.right:SetAnchoredPosition(rx, y)
      a.right:SetLocalRotation(0, 0, -90)   -- 尖朝右
      a.right.imageColor = c
    end
  end)
end

MENU.hideArrows = function(a)
  if a == nil then return end
  pcall(function() a.left:SetVisible(false) end)
  pcall(function() a.right:SetVisible(false) end)
end

-- 点是否落在某个三角上（轴对齐包围盒）
MENU.hitArrow = function(ax, ay, cx, cy)
  return math.abs(cx - ax) <= 15 and math.abs(cy - ay) <= 16
end

-- 鼠标悬停命中某一行（返回行号或 nil）：用于让「当前行高亮条」跟随鼠标。
--   rows 里每行需有 .y；band = 该行的半高容差；halfW = 判定区半宽。
MENU.hoverRow = function(rows, cx, cy, band, halfW)
  if rows == nil or math.abs(cx) > halfW then return nil end
  for i = 1, #rows do
    local r = rows[i]
    if r.y ~= nil and math.abs(cy - r.y) <= band then return i end
  end
  return nil
end

-- 按键设置页：悬停命中可见行
MENU.hoverKeyRow = function(cx, cy)
  if math.abs(cx) > 340 then return nil end
  for i = 1, #MENU.keyRows do
    local r = MENU.keyRows[i]
    if r.y ~= nil and not MENU.keyRowHidden(r) and math.abs(cy - r.y) <= 15 then return i end
  end
  return nil
end

-- 点是否落在某一行上（轴对齐；供按键设置页「点动作行开始改键」）
MENU.hitRow = function(row, cx, cy, band, halfW)
  if row == nil or math.abs(cx) > halfW then return false end
  return math.abs(cy - row.y) <= band
end

-- 设置 / 控制方式行的三角站位（UI 坐标）
MENU.DEV_NAME_X, MENU.DEV_NAME_W   = -180, 320
MENU.DEV_VALUE_X, MENU.DEV_VALUE_W = 262, 160
MENU.DEV_ARROW_L, MENU.DEV_ARROW_R = 172, 352
MENU.SET_VALUE_X, MENU.SET_VALUE_W = 160, 120
MENU.SET_ARROW_L, MENU.SET_ARROW_R = 84, 236

-- 齿轮图标（设置入口）：走统一的「图片控件 + 图片 ID」（IMG.gear = 100161），不再用形状拼。
-- 尺寸用正方形，避免图片被非等比拉伸。
MENU.GEAR_SIZE = 56
MENU.buildGearIcon = function()
  local ctl = createImageCtl(IMG.gear)
  if ctl == nil then return nil end
  pcall(function() ctl:SetSizeDelta(MENU.GEAR_SIZE, MENU.GEAR_SIZE) end)
  return ctl
end

MENU.placeGear = function(ctl, x, y, hover)
  if ctl == nil then return end
  pcall(function()
    ctl:SetVisible(true)
    ctl:SetSizeDelta(MENU.GEAR_SIZE, MENU.GEAR_SIZE)
    ctl:SetAnchoredPosition(x, y)
    ctl.imageColor = hover and COLOR.ACCENT or COLOR.MENU_ICON
  end)
end

MENU.hideGear = function(ctl)
  if ctl == nil then return end
  pcall(function() ctl:SetVisible(false) end)
end

-- 光标命中：返回条目序号（1..4 模式 / 5 齿轮=设置）或 nil。用轴对齐包围盒近似。
MENU.hitMenuEntry = function(cx, cy)
  for i = 1, #MENU.MODES do
    local slot = MENU.BANNER_SLOTS[i]
    local top = slot.y + MENU.BANNER_H / 2 + 4
    local bot = slot.y - MENU.BANNER_H / 2 - 4
    if MENU.MODES[i].desc ~= nil then bot = slot.y - MENU.BANNER_H / 2 - 46 end
    if cx >= slot.x - MENU.BANNER_W / 2 - 4 and cx <= slot.x + MENU.BANNER_W / 2 + 4
       and cy >= bot and cy <= top then
      return i
    end
  end
  if math.abs(cx - MENU.GEAR_POS.x) <= 30 and math.abs(cy - MENU.GEAR_POS.y) <= 30 then
    return #MENU.MODES + 1
  end
  return nil
end

local refreshMenu   -- 前向声明：MENU.moveSel 定义于此函数之前，却要在选中变化时调用它
local onMenuKey     -- 前向声明：stepMenuInput 里「点返回按钮」要复用它（返回逻辑在下方定义）

-- 结束本场对局并给出结算提示（用户结算规则）。
--   winnerIdx = 胜者坦克下标；nil = 平局。
--   单机：打完任意一场（走到这里）即视为「已完成」；联机：一方胜利、另一方失败（见 DEV_STATE）。
MENU.finishMatch = function(winnerIdx)
  local m = G.match
  if m == nil or m.over then return end
  m.over = true
  m.winner = winnerIdx
  local txt
  if winnerIdx == nil then
    txt = "对局结束：平局"
  else
    local t = G.tanks[winnerIdx]
    local nm = (t ~= nil and t.aiName) or PLAYERS.name[winnerIdx] or ("玩家 " .. tostring(winnerIdx))
    txt = "对局结束：" .. nm .. " 胜利"
  end
  if hud.resultLabel ~= nil then
    pcall(function()
      hud.resultLabel.text = txt
      hud.resultLabel.fontColor = COLOR.HUD_TEXT
    end)
  end
  if G.battle ~= nil then G.battle.frozen = true end
  -- 联机：把**本机**的最终结算状态报给服务器（我赢 ⇒ 胜利；否则 ⇒ 失败）；
  --   两条链都含「设置玩家逃跑合法性 = 是」⇒ 正常打完不会被判成「逃跑」。
  --   用户 2026-10-15 定、2026-10-16 修订：双方都没逃 ⇒ 按比赛规则判胜负（各端各自上报，服务器不需按槽位找人）；
  --   中途离开者由进局预置的「逃跑合法性 = 否」判成「逃跑」，留下的一方走人数检测路径到这里上报「胜利」。
  --   单机不报：进局时已预置「胜利」。
  if G.online then
    local win = (winnerIdx == G.playerIndex)
    local ok = win and netApi.reportSetWin(G.playerIndex) or netApi.reportSetLose(G.playerIndex)
    print("[坦克动荡] 已上报 " .. (win and "TT2_SET_WIN（我赢）" or "TT2_SET_LOSE（我输）")
      .. "（" .. (ok and "已发出" or "**未发出**") .. "，玩家序号=" .. tostring(G.playerIndex) .. "）")
    -- 「分出胜负 ⇒ 立刻结算关卡」：先等 40 帧（≈1.6s）让**对端**的报文也送达，再由房主发 TT2_SETTLE
    --   （见 stepFrame 的结算块）。⚠️ 顺序不能颠倒：抢先把关卡结算掉，后到的「我赢 / 我输」会被吞掉
    --   ⇒ 对端按预置的「逃跑合法性 = 否」被判「逃跑」。
    m.settleIn = 40
  end
  netApi.reportMatch(statsApi.payload(G.stats))   -- 整场上报（原版上传 pixvi.net 的本地等价）
  refreshMenu()
end

-- 联机「v4」：**胜者由房主裁定并上传**（TT2_WINNER，服务器原样落地）；非房主自己不判、
--   只读变量后统一结算 ⇒ 不会出现「一端判胜、另一端还在打」。
--   单机没有胜负条件（只判「已完成关卡」），这里仅用于联机的提前结束。
MENU.declareWinner = function(idx)
  if not G.online then MENU.finishMatch(idx); return end
  if MENU.isMazeHost() then
    netApi.reportWinner(idx or 0)
    MENU.finishMatch(idx)
  end
  -- 非房主：等 TT2_WINNER 回来（见 stepOnline 的胜负检查）
end

-- ============================================================
-- 联机补给箱（**房主权威**，走关卡变量 TT2_CRATE）
--   补给箱是**持续状态**（一直在场上直到被捡）⇒ 必须走变量（丢包自愈 / 重连恢复），
--   不能走一次性信号。表结构 = [crateId, cellX, cellY, weaponId] × N；
--   用**格子坐标**（不是像素）⇒ 与 SCALE 无关，两端必然落在同一格。
-- ⚠️ 这三个函数挂在 `MENU` 表上而不是顶层 local：顶层 local 要计入主 chunk 上限（AGENTS.md §0）。
-- ============================================================

-- 造一个补给箱（**房主本地生成** 与 **非房主照表镜像** 共用同一段）
MENU.spawnCrateAt = function(cell, weapon, id, cx, cy)
  local s = G.scale
  -- 弹入参数取自原版 spawnCrate：targetScale = SCALE*1.5、_rotation = rot(随机)、
  -- scaleSpeed = SCALE/5、scaleSpeedDiff = SCALE/20（src/round.lua M.crateLanding）。
  local land = roundApi.crateLanding(s)
  local crate = {
    id = id or 0,
    cx = cx or cell.x, cy = cy or cell.y,
    x = (cell.x + 0.5) * s, y = (cell.y + 0.5) * s,
    weapon = weapon, cell = cell,
    rot = land.rot,                                  -- 原版 _rotation
    -- 缩放进度 k = 当前 _xscale / targetScale：0 → 1，中途过冲到约 1.33 再回弹 snap
    k = 0,
    kSpeed = land.scaleSpeed / land.targetScale,      -- = 2/15 ≈ 0.1333 每帧
    kDiff = land.scaleSpeedDiff / land.targetScale,   -- = 1/30 ≈ 0.0333 每帧
    landed = false,
  }
  crate.vis = buildCrateVisual(weapon, s * CFG.CRATE_R)
  playSound("soundCrate")   -- 原版：补给箱生成音效
  G.crates[#G.crates + 1] = crate
  cratePuff(crate.x, crate.y, 3)
  return crate
end

-- 房主：把**权威补给箱表**整张上传（服务器原样写进关卡变量 TT2_CRATE）
MENU.uploadCrates = function()
  local rows = {}
  for i = 1, #G.crates do
    local c = G.crates[i]
    rows[#rows + 1] = {
      id = c.id or 0, cx = c.cx or 0, cy = c.cy or 0,
      weaponId = onlineApi.weaponId(c.weapon),
    }
  end
  netApi.reportCrates(onlineApi.encodeCrates(rows))
  G.crateDirty = false
end

-- **非房主**：补给箱表是房主权威的**纯镜像** —— 每帧按 id 对齐：
--   表里有、本地没有 ⇒ 生成；本地有、表里没有（已被捡走）⇒ 移除。
MENU.syncCrateMirror = function()
  -- 按格子坐标找迷宫格
  local function cellAt(cx, cy)
    for i = 1, #G.reachable do
      local c = G.reachable[i]
      if c.x == cx and c.y == cy then return c end
    end
    return nil
  end
  local list = nil
  pcall(function()
    list = game.GetGlobalCustomVariableValue(Enum.CustomVariableEntityType.Level, "TT2_CRATE")
  end)
  if type(list) ~= "table" or (#list % onlineApi.CRATE_N) ~= 0 then return end
  local want = onlineApi.decodeCrates(list)
  local seen = {}
  for i = 1, #want do seen[want[i].id] = want[i] end
  -- 本地有、表里没有 ⇒ 移除
  for i = #G.crates, 1, -1 do
    local c = G.crates[i]
    if c.id ~= nil and c.id ~= 0 and seen[c.id] == nil then
      if c.cell ~= nil then c.cell.used = false end
      vfree(c.vis)
      table.remove(G.crates, i)
    end
  end
  -- 表里有、本地没有 ⇒ 生成
  for i = 1, #want do
    local w = want[i]
    local found = false
    for j = 1, #G.crates do
      if G.crates[j].id == w.id then found = true; break end
    end
    if not found then
      local cell = cellAt(w.cx, w.cy)
      if cell ~= nil then
        cell.used = true
        MENU.spawnCrateAt(cell, onlineApi.weaponName(w.weaponId), w.id, w.cx, w.cy)
      end
    end
  end
end

-- 主菜单条目的**实际屏幕位置**（用于「按方向导航」而不是上下线性轮转）：
-- 1..4 = 4 个模式横幅，5 = 齿轮（设置）。
MENU.entryPos = function(idx)
  if idx == 0 then return 0, 0 end   -- 0 = 未选中（鼠标已离开所有条目）；以此为中心做方向导航
  if idx <= #MENU.MODES then
    local s = MENU.BANNER_SLOTS[idx]
    return s.x, s.y
  end
  return MENU.GEAR_POS.x, MENU.GEAR_POS.y
end

-- 按方向 (dirX,dirY) ∈ {-1,0,1} 从 cur 选「该方向上最近的条目」；找不到则不动。
-- 评分 = 沿方向的距离 + 2×垂直偏差 → 优先正前方的邻居。
MENU.moveSel = function(cur, dirX, dirY)
  local cx, cy = MENU.entryPos(cur)
  local best, bestScore = nil, nil
  for k = 1, MENU.ENTRY_COUNT do
    if k ~= cur then
      local x, y = MENU.entryPos(k)
      local dx, dy = x - cx, y - cy
      local along = dx * dirX + dy * dirY
      if along > 1 then
        local perp = math.abs(dx * dirY) + math.abs(dy * dirX)
        local score = along + perp * 2
        if bestScore == nil or score < bestScore then best, bestScore = k, score end
      end
    end
  end
  if best ~= nil then
    MENU.sel = best
    refreshMenu()
  end
end

-- 读光标的 UI 坐标（画布中心为原点、y 向上），失败时 ok=false。
MENU.readCursor = function()
  -- 移动端：**只用触点**，绝不回落到 GetCursorUIPos（移动端它可能给 0/0，会把光标钉在画布中心）。
  -- 手指按下期间才算「有光标」（松手不占光标，选中态交回键盘 / 手柄）。
  if G.touchMode then
    if G.touch.ok and G.touch.down == true then
      MENU.cursor.x, MENU.cursor.y, MENU.cursor.ok = G.touch.x, G.touch.y, true
    else
      MENU.cursor.ok = false
    end
    return
  end
  local ok, cx, cy = pcall(function() return game.GetCursorUIPos() end)
  if not ok or type(cx) ~= "number" or type(cy) ~= "number" then
    MENU.cursor.ok = false
    return
  end
  local vw, vh = 0, 0
  pcall(function() vw, vh = game.GetUICanvasSize() end)
  MENU.cursor.x, MENU.cursor.y, MENU.cursor.ok =
    (cx - vw / 2) / (G.uiScale or 1), (cy - vh / 2) / (G.uiScale or 1), true
end

local function buildMenuUI()
  MENU.panel = makeBar(0, 0, 900, 640, COLOR.MENU_BG)
  MENU.artParts = MENU.buildMenuArt()   -- 主界面背景美术：山丘 + 大坦克（层级由 applyZOrder 排）

  -- 主菜单页 = 原版 frame_1 的「手绘横幅按钮岛」：标题 + 4 模式横幅 + 齿轮 + 音效。
  -- 原版主菜单直接画在**纯白舞台**上（无深色面板），文字为深色。
  -- 屏幕操作提示一律不画（原版没有）——导航靠鼠标悬停 / 方向键 / 手柄；返回靠「返回按钮 + 按键提示」。
  MENU.menuTexts[1] = makeTextAt(0, 250, 860, 64, "坦克动荡")
  MENU.menuTexts[1].fontColor = COLOR.MENU_TEXT
  MENU.menuTexts[2] = makeTextAt(0, -244, 860, 20, "", Enum.TextHorizontalAlignment.Middle)

  -- 4 个模式横幅（原版 DefineSprite_340/351/356/328）：静态形状层 + 主 / 副标题笔画字。
  -- 触屏端不支持三人对战：横幅变灰 + 说明「不可用」（见 DEV_STATE §10.5）。
  if G.touchMode then MENU.MODES[3].desc = "触屏端不可用" end
  for i = 1, #MENU.MODES do
    local m = MENU.MODES[i]
    local slot = MENU.BANNER_SLOTS[i]
    local b = {
      parts = MENU.buildBannerArt(),
      labels = {},
      hx = slot.x, hy = slot.y,          -- 静止基准中心（SetTransform 的参考原点）
      x = slot.x, y = slot.y, rot = 0, scale = 1,
      animTime = 0, hover = false,
      disabled = (G.touchMode and i == 3),   -- 触屏端「三人对战」不可用
    }
    -- 主标题：有副标题（仅单人玩家）时上移，给副标题留位；否则居中。
    local hasSub = (m.sub ~= nil)
    local titleLy = hasSub and 9 or 0
    b.labels[1] = { lx = 0, ly = titleLy,
      label = makeTextAt(slot.x, slot.y + titleLy, MENU.BANNER_W, 26, m.title,
        Enum.TextHorizontalAlignment.Middle) }
    b.labels[1].label.fontColor = COLOR.MENU_TEXT
    if hasSub then
      b.labels[2] = { lx = 0, ly = -17,
        label = makeTextAt(slot.x, slot.y - 17, MENU.BANNER_W, 14, m.sub,
          Enum.TextHorizontalAlignment.Middle) }
      b.labels[2].label.fontColor = COLOR.DIM
    end
    MENU.banners[i] = b
  end

  -- 浮动说明框：**跟随当前选中项移动**，显示该模式的一句话说明。
  -- （原版是 DefineSprite_340 自带的说明框；这里做成"跟选中项走"，不再固定钉在单人玩家下面。）
  MENU.descBox = {
    border = makeBar(0, 0, MENU.BANNER_W - 26, 44, COLOR.OUTLINE),
    fill   = makeBar(0, 0, MENU.BANNER_W - 34, 36, COLOR.BANNER_DESC),
    label  = makeTextAt(0, 0, MENU.BANNER_W - 42, 12, "", Enum.TextHorizontalAlignment.Middle),
    x = 0, y = 0,
  }
  MENU.descBox.label.fontColor = COLOR.MENU_TEXT

  MENU.gear = MENU.buildGearIcon()

  -- 「返回」按钮 + 按键提示（R / 手柄返回）：所有非主菜单页显示。
  MENU.back = {
    parts = MENU.buildBackButton(),
    label = makeTextAt(MENU.BACK_POS.x, MENU.BACK_POS.y, 100, 22, "菜单",
      Enum.TextHorizontalAlignment.Middle),
    hint  = MENU.buildKeyHint(),
  }
  MENU.back.label.fontColor = COLOR.MENU_TEXT

  -- 设置面板（原版 settings 面板的本地等价）：控制方式 / 按键设置 / 音效。
  -- 关闭面板用底部「返回（R）」按钮，不再单列「返回主界面」行。
  MENU.setTexts[1] = makeTextAt(0, 250, 860, 44, "设置")
  MENU.setTexts[1].fontColor = COLOR.MENU_TEXT
  MENU.setTexts[2] = makeTextAt(0, -244, 860, 18, "", Enum.TextHorizontalAlignment.Middle)
  -- 操作提示：改由底部「按键提示条」（真实按键图标 + 明确用途文字，见 placeSetHints）承担，
  --   故此处留空（原「W A S D 选择 / 切换   F 确认」措辞有歧义，且与提示条重复，用户 2026-10-11 要求去掉）。
  MENU.setTexts[3] = makeTextAt(0, -78, 860, 18, "",
    Enum.TextHorizontalAlignment.Middle)
  MENU.setTexts[3].fontColor = COLOR.MENU_ROW
  MENU.setHints = {}
  do
    -- 顺序与 SET_HINT_X 一一对应：W S（滚动）　A D（切换）　F（确认）
    local hints = {
      { Enum.KeyboardKeyCode.MoveForwardKey,  Enum.ControllerKeyCode.CharacterSkill3Key },  -- W / 十字键上
      { Enum.KeyboardKeyCode.MoveBackwardKey, Enum.ControllerKeyCode.CraftspersonKey2   },  -- S / 十字键下
      { Enum.KeyboardKeyCode.MoveLeftKey,     Enum.ControllerKeyCode.CraftspersonKey1   },  -- A / 十字键左
      { Enum.KeyboardKeyCode.MoveRightKey,    Enum.ControllerKeyCode.CharacterSkill4Key },  -- D / 十字键右
      { Enum.KeyboardKeyCode.InteractKey,     Enum.ControllerKeyCode.JumpKey            },  -- F / A
    }
    for i = 1, #hints do
      local h = MENU.buildKeyHint(hints[i][1], hints[i][2])
      -- 只追加成功的（保持下标与 SET_HINT_X 一一对应，避免出现空洞导致位置错配）
      if h ~= nil then MENU.setHints[#MENU.setHints + 1] = h end
    end
    -- 三组文字说明（滚动 / 切换 / 确认），与图标同排。
    MENU.setHintLabels = {}
    for i = 1, #MENU.SET_HINT_LABELS do
      local d = MENU.SET_HINT_LABELS[i]
      local lb = makeTextAt(d.x, MENU.SET_HINT_Y, 96, 18, d.text,
        Enum.TextHorizontalAlignment.Middle)
      lb.fontColor = COLOR.MENU_ROW
      MENU.setHintLabels[i] = lb
    end
  end
  -- 高亮底板：与「控制方式 / 按键设置」子界面同宽（680），否则设置页选项文字（-300..220）左侧盖不住。
  MENU.setHL = makeBar(0, 0, 680, 34, COLOR.MENU_HL)
  -- 设置面板行：改为**子页入口**（原版 settingsPanel 是单一滑条面板；本移植把「影响游戏规则」的
  -- 对战设置与「不影响规则」的其他设置拆成两个子页——用户要求准备界面下方两按钮 = 按键设置 / 其他设置）。
  -- 移动端控制方式固定为触屏，故用「控制模式」（两套手感）替代「控制方式 / 按键设置」中的控制方式。
  -- 其他设置页的可选项（0 倍率 = 「自适应」= 按画布 fit；抗锯齿 0 = 关）
  MENU.SCALE_OPTS = { 0, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5 }
  MENU.AA_OPTS    = { 0, 1, 2, 3 }
  local setRows
  if G.touchMode then
    setRows = {
      { kind = "touchMode", label = "控制模式" },
      { kind = "rules",     label = "对战设置" },
      { kind = "other",     label = "其他设置" },
    }
  else
    setRows = {
      { kind = "devices", label = "控制方式" },
      { kind = "keys",    label = "按键设置" },
      { kind = "rules",   label = "对战设置" },
      { kind = "other",   label = "其他设置" },
    }
  end
  local SET_TOP, SET_DY = 150, 46
  for i = 1, #setRows do
    local y = SET_TOP - (i - 1) * SET_DY
    MENU.setRows[i] = {
      kind = setRows[i].kind, label = setRows[i].label, y = y,
      name  = makeTextAt(-150, y, 300, 24, setRows[i].label, Enum.TextHorizontalAlignment.Left),
      value = makeTextAt(MENU.SET_VALUE_X, y, MENU.SET_VALUE_W, 24, "",
        Enum.TextHorizontalAlignment.Middle),
      -- 「控制模式」行：右侧 ◀ ▶ 三角（点击 = A/D 左右切换）
      arrows = MENU.makeArrows(),
    }
    MENU.setRows[i].name.fontColor = COLOR.MENU_ROW
    MENU.setRows[i].value.fontColor = COLOR.MENU_ROW
  end
  -- 追加一行「回到主界面」：**仅当设置面板是从对战界面打开时**才显示（用户 2026-10-12）——
  --   从战斗点「菜单」进设置后，除了「返回」（回对局）还能一键退回主界面。
  --   始终建控件，显隐/可选中由 MENU.setRowCount()（依赖 MENU.fromBattle）控制。
  do
    local i = #MENU.setRows + 1
    local y = SET_TOP - (i - 1) * SET_DY
    MENU.setRows[i] = {
      kind = "quitToMenu", label = "回到主界面", y = y,
      name  = makeTextAt(-150, y, 300, 24, "回到主界面", Enum.TextHorizontalAlignment.Left),
      value = makeTextAt(MENU.SET_VALUE_X, y, MENU.SET_VALUE_W, 24, "",
        Enum.TextHorizontalAlignment.Middle),
      arrows = MENU.makeArrows(),
    }
    MENU.setRows[i].name.fontColor = COLOR.MENU_ROW
    MENU.setRows[i].value.fontColor = COLOR.MENU_ROW
  end

  -- 设置面板行的**显隐规则**（用户 2026-10-12）：
  --   · 末行「回到主界面」：仅「设置是从战斗打开」时出现（否则不显示、不可选中）；
  --   · **联机模式**：只保留「按键设置」「其他设置」——隐藏「控制方式 / 控制模式」与「对战设置」。
  MENU.rowHidden = function(row)
    if row == nil then return true end
    if row.kind == "quitToMenu" then return MENU.fromBattle ~= true end
    if G.online == true and (row.kind == "devices" or row.kind == "touchMode" or row.kind == "rules") then
      return true
    end
    return false
  end
  -- 设置面板**可见（可选中）**的行数 —— W/S 换行、鼠标悬停选行都按它跳过隐藏行。
  MENU.setRowCount = function()
    local n = 0
    for i = 1, #MENU.setRows do if not MENU.rowHidden(MENU.setRows[i]) then n = n + 1 end end
    return n
  end

  -- 对战设置页（原版 settingsPanel 的 Weapons 7 项 + Controls：平滑碰撞）
  MENU.rulesTexts[1] = makeTextAt(0, 262, 860, 44, "对战设置")
  MENU.rulesTexts[1].fontColor = COLOR.MENU_TEXT
  -- 底部说明文字已删除（用户 2026-10-12）：按键用途统一由底部「按键提示条」承担，避免重复 + 残留。
  MENU.rulesHL = makeBar(0, 0, 680, 30, COLOR.MENU_HL)
  do
    -- 出箱武器中文名（对照原版 settingsPanel「Weapons」段：Laser / Frag bomb / Death ray /
    --   RC missile / Gatling gun / Homing missile / Booby traps）
    local label = {
      laser = "激光", frag = "破片弹", deathRay = "死亡射线",
      remote = "遥控导弹", gatling = "机关枪", homing = "追踪导弹", mine = "地雷",
    }
    local RULE_TOP, RULE_DY = 176, 34
    local n = 0
    for i = 1, #C.SETTINGS.activeWeapons do
      n = n + 1
      local w = C.SETTINGS.activeWeapons[i]
      local y = RULE_TOP - (n - 1) * RULE_DY
      MENU.rulesRows[n] = {
        kind = "weapon", w = w, y = y,
        name  = makeTextAt(-150, y, 300, 22, label[w] or w, Enum.TextHorizontalAlignment.Left),
        value = makeTextAt(MENU.SET_VALUE_X, y, MENU.SET_VALUE_W, 22, "",
          Enum.TextHorizontalAlignment.Middle),
        arrows = MENU.makeArrows(),
      }
    end
    n = n + 1
    local sy = RULE_TOP - (n - 1) * RULE_DY
    MENU.rulesRows[n] = {
      kind = "smooth", y = sy,
      name  = makeTextAt(-150, sy, 300, 22, "平滑碰撞", Enum.TextHorizontalAlignment.Left),
      value = makeTextAt(MENU.SET_VALUE_X, sy, MENU.SET_VALUE_W, 22, "",
        Enum.TextHorizontalAlignment.Middle),
      arrows = MENU.makeArrows(),
    }
    n = n + 1
    local ry = RULE_TOP - (n - 1) * RULE_DY - 6
    MENU.rulesRows[n] = {
      kind = "reset", y = ry,
      name  = makeTextAt(-150, ry, 300, 22, "恢复默认", Enum.TextHorizontalAlignment.Left),
      value = makeTextAt(MENU.SET_VALUE_X, ry, MENU.SET_VALUE_W, 22, "",
        Enum.TextHorizontalAlignment.Middle),
    }
    for i = 1, #MENU.rulesRows do
      MENU.rulesRows[i].name.fontColor = COLOR.MENU_ROW
      MENU.rulesRows[i].value.fontColor = COLOR.MENU_ROW
    end
  end

  -- 其他设置页（不影响游戏规则）：显示大小 / 抗锯齿 / 音乐 / 音效
  MENU.otherTexts[1] = makeTextAt(0, 262, 860, 44, "其他设置")
  MENU.otherTexts[1].fontColor = COLOR.MENU_TEXT
  -- 底部说明文字已删除（用户 2026-10-12）：同上，避免与底部「按键提示条」重复 + 残留。
  MENU.otherHL = makeBar(0, 0, 680, 34, COLOR.MENU_HL)
  do
    local defs = {
      { kind = "uiScale", label = "显示大小" },
      { kind = "aa",      label = "抗锯齿" },
      { kind = "music",   label = "音乐" },
      { kind = "sound",   label = "音效" },
    }
    local OTH_TOP, OTH_DY = 110, 50
    for i = 1, #defs do
      local y = OTH_TOP - (i - 1) * OTH_DY
      MENU.otherRows[i] = {
        kind = defs[i].kind, label = defs[i].label, y = y,
        name  = makeTextAt(-150, y, 300, 24, defs[i].label, Enum.TextHorizontalAlignment.Left),
        value = makeTextAt(MENU.SET_VALUE_X, y, MENU.SET_VALUE_W, 24, "",
          Enum.TextHorizontalAlignment.Middle),
        arrows = MENU.makeArrows(),
      }
      MENU.otherRows[i].name.fontColor = COLOR.MENU_ROW
      MENU.otherRows[i].value.fontColor = COLOR.MENU_ROW
    end
  end

  -- 准备页（原版 controlsNPlayer）：每位真人玩家一块控制面板 ——
  --   上：玩家名；中：控制器图示（键盘 / 鼠标 / 手柄）；下：加入提示。
  --   加入后底色变玩家色、提示清空（对应原版 background.setRGB + activateText=""）。
  --   AI 位（莱卡）在原版不画面板，这里同样不画。
  for i = 1, 3 do
    MENU.readyRows[i] = {
      card   = MENU.buildReadyCard(),
      art    = nil,      -- 控制器图示（懒构建：随控制方式 / 开火键变化重建）
      artKey = nil,
      name   = makeTextAt(0, 0, 340, 28, "", Enum.TextHorizontalAlignment.Middle),
      act    = makeTextAt(0, 0, 340, 19, "", Enum.TextHorizontalAlignment.Middle),
    }
    MENU.readyRows[i].name.fontColor = COLOR.MENU_TEXT
  end
  -- 底部不再画文字提示（原版无）；「返回」改为页面右下角的按钮 + 按键提示（见 buildBackButton）。
  MENU.readyTexts[1] = makeTextAt(0, -250, 860, 20, "", Enum.TextHorizontalAlignment.Middle)
  -- 联机准备：顶部状态行（倒计时 + 四类控制提示 + 对方是否准备）——**仅 G.online 时显示**
  MENU.readyTexts[2] = makeTextAt(0, 250, 860, 22, "", Enum.TextHorizontalAlignment.Middle)
  MENU.readyTexts[2].fontColor = COLOR.MENU_TEXT
  -- 准备页下方两个按钮：按键设置 / 其他设置（不影响对局规则的设置入口）
  MENU.readyBtns = {}
  do
    local defs = {
      { kind = "keys",  label = "按键设置", x = -110 },
      { kind = "other", label = "其他设置", x = 110 },
    }
    for i = 1, #defs do
      MENU.readyBtns[i] = {
        kind = defs[i].kind, x = defs[i].x, y = -206,
        bar   = makeBar(defs[i].x, -206, 180, 40, COLOR.MENU_HL),
        label = makeTextAt(defs[i].x, -206, 180, 22, defs[i].label,
          Enum.TextHorizontalAlignment.Middle),
      }
      MENU.readyBtns[i].label.fontColor = COLOR.MENU_TEXT
    end
  end
  -- 联机准备页「颜色选择」：4 个正方形（红 / 绿 / 蓝 / 灰），选中者加**描边**（大一圈的深色方块）。
  MENU.colorSquares = {}
  do
    local xs, cy = { -132, -44, 44, 132 }, -124
    for i = 1, 4 do
      MENU.colorSquares[i] = {
        x = xs[i], y = cy,
        border = makeBar(xs[i], cy, 50, 50, COLOR.OUTLINE),
        fill   = makeBar(xs[i], cy, 40, 40, MENU.PICK_COLORS[i]),
      }
    end
  end

  -- 控制方式页（主菜单第 4 项）：3 位玩家各一行（左右切换 4 选 1）+ 保存 + 恢复默认。
  MENU.devTexts[1] = makeTextAt(0, 272, 860, 44, "控制方式")
  MENU.devTexts[1].fontColor = COLOR.MENU_TEXT
  MENU.devTexts[2] = makeTextAt(0, 232, 860, 18, "", Enum.TextHorizontalAlignment.Middle)
  MENU.devHL = makeBar(0, 0, 680, 30, COLOR.MENU_HL)
  local DEV_TOP, DEV_DY = 150, 42
  local dn = 0
  for p = 1, 3 do
    dn = dn + 1
    local dy = DEV_TOP - (dn - 1) * DEV_DY
    MENU.devRows[dn] = {
      kind = "player", n = p, y = dy,
      name  = makeTextAt(MENU.DEV_NAME_X, dy, MENU.DEV_NAME_W, 22, PLAYERS.name[p],
        Enum.TextHorizontalAlignment.Left),
      value = makeTextAt(MENU.DEV_VALUE_X, dy, MENU.DEV_VALUE_W, 22, "",
        Enum.TextHorizontalAlignment.Middle),
      -- 玩家行：右侧 ◀ ▶ 三角（点击 = A/D 左右切换控制方式）
      arrows = MENU.makeArrows(),
    }
  end
  dn = dn + 1
  local sy = DEV_TOP - (dn - 1) * DEV_DY
  MENU.devRows[dn] = {
    kind = "save", y = sy,
    name  = makeTextAt(MENU.DEV_NAME_X, sy, MENU.DEV_NAME_W, 22, "保存设置",
      Enum.TextHorizontalAlignment.Left),
    value = makeTextAt(MENU.DEV_VALUE_X, sy, MENU.DEV_VALUE_W, 22, "",
      Enum.TextHorizontalAlignment.Middle),
  }
  dn = dn + 1
  local rsy = DEV_TOP - (dn - 1) * DEV_DY - 6
  MENU.devRows[dn] = {
    kind = "reset", y = rsy,
    name  = makeTextAt(MENU.DEV_NAME_X, rsy, MENU.DEV_NAME_W, 22, "恢复默认",
      Enum.TextHorizontalAlignment.Left),
    value = makeTextAt(MENU.DEV_VALUE_X, rsy, MENU.DEV_VALUE_W, 22, "",
      Enum.TextHorizontalAlignment.Middle),
  }
  MENU.devMsgLabel = makeTextAt(0, -216, 860, 18, "", Enum.TextHorizontalAlignment.Middle)

  -- 按键设置页：沿用同一块面板，进入本页时主菜单 / 准备页控件全部隐去。
  -- 按键设置页（2026-10-11 重构）：
  --   ① 鼠标操控（旧=瞬时转向 / 新=限速转向，A/D 或 ◀▶ 切换）
  --   ② 字母键位（ESDF+Q / WASD+空格，A/D 或 ◀▶ 切换；按 F 进入「自定义」）
  --   ③ 自定义时显示 5 个动作行，按 F 开始改键、再按任意可用键完成
  --   ④ 底部列出所有可用按键；键位冲突时禁止返回
  MENU.keyTexts[1] = makeTextAt(0, 272, 860, 44, "按键设置")
  MENU.keyTexts[1].fontColor = COLOR.MENU_TEXT
  MENU.keyTexts[2] = makeTextAt(0, 236, 860, 16,
    "方案 2 方向键固定为 ↑ ↓ ← →（仅开火键可改）", Enum.TextHorizontalAlignment.Middle)
  MENU.keyTexts[2].fontColor = COLOR.DIM
  MENU.keyTexts[3] = makeTextAt(0, -176, 860, 18, "", Enum.TextHorizontalAlignment.Middle)
  MENU.keyHL = makeBar(0, 0, 680, 30, COLOR.MENU_HL)
  local KR_TOP, KR_DY = 178, 30
  local kn = 0
  -- ① 鼠标操控
  kn = kn + 1
  local ky1 = KR_TOP - (kn - 1) * KR_DY
  MENU.keyRows[kn] = {
    kind = "mouseBranch", y = ky1,
    name  = makeTextAt(MENU.DEV_NAME_X, ky1, MENU.DEV_NAME_W, 22, "鼠标操控",
      Enum.TextHorizontalAlignment.Left),
    value = makeTextAt(MENU.SET_VALUE_X, ky1, MENU.SET_VALUE_W, 22, "",
      Enum.TextHorizontalAlignment.Middle),
    arrows = MENU.makeArrows(),
  }
  -- ② **6 个可自定义按键**（不再有「预设键位」行）：
  --    方案 1（字母键位）的 4 个移动键 + 开火 + 方案 2（方向键玩家）的开火。
  --    方案 2 的移动键固定为 ↑↓←→（不可改）⇒ 不列行。
  local KEY_ACTIONS = {
    { scheme = 1, action = "fwd",   label = "前进" },
    { scheme = 1, action = "back",  label = "后退" },
    { scheme = 1, action = "left",  label = "左转" },
    { scheme = 1, action = "right", label = "右转" },
    { scheme = 1, action = "fire",  label = "开火（字母键位）" },
    { scheme = 2, action = "fire",  label = "开火（方向键）" },
  }
  for a = 1, #KEY_ACTIONS do
    kn = kn + 1
    local y = KR_TOP - (kn - 1) * KR_DY
    MENU.keyRows[kn] = {
      kind = "action", scheme = KEY_ACTIONS[a].scheme, action = KEY_ACTIONS[a].action, y = y,
      name  = makeTextAt(MENU.DEV_NAME_X, y, MENU.DEV_NAME_W, 22, KEY_ACTIONS[a].label,
        Enum.TextHorizontalAlignment.Left),
      value = makeTextAt(MENU.SET_VALUE_X, y, MENU.SET_VALUE_W, 22, "",
        Enum.TextHorizontalAlignment.Middle),
    }
  end
  -- ④ 底部：**不可绑定的按键**（可绑键有 52 个太长，改列不能用的键）：
  --   · 菜单保留的返回键（改键时会被跳过，见 refreshKeyRows 动态填）
  --   · 千星奇域未开放 / 平台保留的键：字母 B C M N；系统键 Esc Enter 左Shift Alt Win 等
  MENU.keyListTexts[1] = makeTextAt(0, -44, 860, 14, "不可绑定的按键",
    Enum.TextHorizontalAlignment.Middle)
  MENU.keyListTexts[1].fontColor = COLOR.DIM
  MENU.keyListTexts[2] = makeTextAt(0, -66, 860, 14, "", Enum.TextHorizontalAlignment.Middle)
  MENU.keyListTexts[2].fontColor = COLOR.MENU_ROW
  local LOCKED = {
    "字母：B C M N（千星奇域未开放）",
    "系统键：Esc Enter 左Shift Alt Win Insert Delete",
    "Home End PgUp PgDn F1~F4 F11 F12 小键盘",
  }
  for i = 1, #LOCKED do
    MENU.keyListTexts[i + 2] = makeTextAt(0, -88 - (i - 1) * 20, 860, 13,
      LOCKED[i], Enum.TextHorizontalAlignment.Middle)
    MENU.keyListTexts[i + 2].fontColor = COLOR.MENU_ROW
  end
end

-- 层级重排：本项目所有部件都实例化在同一个宿主控件下（同级），
-- 而引擎规则是「同级控件按创建顺序叠放，后创建的在上」（见官方文档 界面控件.md §四）。
-- 由于控件池复用，坦克部件可能比后建的墙 / 补给箱"资历更浅"而被压住 → 表现为隐形。
-- 这里在关键时机把各组控件自下而上 SetAsLastSibling()，固定最终叠放：
--   菜单 / HUD > 坦克 > 炮弹 / 特效 > 补给箱 > 墙 > 地板
local ZORDER = { broken = false, reported = false }
applyZOrder = function()
  if ZORDER.broken then return end
  local ok = pcall(function()
    local function up(ctl)
      if ctl ~= nil then ctl:SetAsLastSibling() end
    end
    -- 抬起一组控件。列表元素有两种形态，必须区分：
    --   ①「部件表」{ ctl=控件, shape=…, lx=… }（vpart 产出，如 vis / baseArt / segs）→ 取 .ctl；
    --   ②「文字标签」（makeTextAt 返回的 Label，如 MENU.menuTexts / 计分板数字）→ 用它自身，
    --      其 SetAsLastSibling() 会把这组笔画控件逐个抬到同层最上。
    local function upList(list)
      if list == nil then return end
      for i = 1, #list do
        local part = list[i]
        if part ~= nil then up(part.ctl or part) end
      end
    end

    -- ① 外圈衬底 → ② 地板 → ③ 墙（每步都抬到最上，故调用顺序即最终叠放顺序）
    up(G.backdropCtl)
    up(G.floorCtl)
    if G.wallParts ~= nil then
      for i = 1, #G.wallParts do up(G.wallParts[i].ctl) end
    end
    -- ③ 补给箱
    if G.crates ~= nil then
      for i = 1, #G.crates do upList(G.crates[i].vis) end
    end
    -- ④ 炮弹（含折线激光 / 死亡射线的线段池与弹头）
    if G.projectiles ~= nil then
      for i = 1, #G.projectiles do
        local p = G.projectiles[i]
        upList(p.vis)
        if p.visHolder ~= nil then upList(p.visHolder.segs) end
        if p.ball ~= nil then up(p.ball.ctl) end
      end
    end
    -- ⑤ 炮口闪光 / 火花（线段池）
    if G.sparkHolder ~= nil then upList(G.sparkHolder.segs) end
    -- ⑥ 特效
    if G.effects ~= nil then
      for i = 1, #G.effects do upList(G.effects[i].vis) end
    end
    -- ⑥.5 瞄准路径预览（原版 aimer：绘制于坦克之下）
    if G.aimerHolders ~= nil then
      for i = 1, #G.aimerHolders do upList(G.aimerHolders[i].segs) end
    end
    -- ⑦ 坦克（车体 + 炮塔）
    if G.tanks ~= nil then
      for i = 1, #G.tanks do
        local t = G.tanks[i]
        if t.alive then
          upList(t.baseArt)
          upList(t.turretArt)
        end
      end
    end
    -- ⑧ HUD（计分板：迷你坦克图标 + 分数数字）
    for i = 1, #hud.icons do upList(hud.icons[i]) end
    for i = 1, #hud.scoreLabels do up(hud.scoreLabels[i]) end
    for i = 1, #hud.nameLabels do up(hud.nameLabels[i]) end
    for i = 1, #hud.pingLabels do up(hud.pingLabels[i]) end
    up(hud.timerLabel)
    up(hud.resultLabel)
    -- ⑧.2 计分板碎裂特效（在计分板之上）
    for i = 1, #hud.frags do up(hud.frags[i].ctl) end
    -- ⑧.5 鼠标准星（在坦克 / HUD 之上，菜单之下）
    for i = 1, #SCOPE.parts do up(SCOPE.parts[i]) end
    up(SCOPE.ring)
    -- ⑧.8 触屏操控可视（摇杆 / 开火按钮；在最上层操作区之上、菜单之下）
    if G.tviz ~= nil then
      for p = 1, #G.tviz do
        up(G.tviz[p].ring); up(G.tviz[p].dot); up(G.tviz[p].fire)
      end
    end
    -- ⑨ 菜单（面板 → 背景美术（山丘/大坦克） → 横幅 / 齿轮 → 文字）
    up(MENU.panel)
    upList(MENU.artParts)
    for i = 1, #MENU.banners do
      local b = MENU.banners[i]
      for j = 1, #b.parts do up(b.parts[j].ctl) end
    end
    up(MENU.gear)
    upList(MENU.menuTexts)
    -- 横幅文字必须压在横幅形状层之上
    for i = 1, #MENU.banners do
      local b = MENU.banners[i]
      for j = 1, #b.labels do up(b.labels[j].label) end
    end
    -- 浮动说明框压在横幅之上
    if MENU.descBox ~= nil then
      up(MENU.descBox.border); up(MENU.descBox.fill); up(MENU.descBox.label)
    end
    -- 设置面板
    up(MENU.setHL)
    upList(MENU.setTexts)
    for i = 1, #MENU.setHints do up(MENU.setHints[i]) end
    upList(MENU.setHintLabels)
    for i = 1, #MENU.setRows do
      local r = MENU.setRows[i]
      up(r.name); up(r.value)
      if r.arrows ~= nil then up(r.arrows.left); up(r.arrows.right) end
    end
    -- 准备页
    upList(MENU.readyTexts)
    for i = 1, #MENU.readyRows do
      local r = MENU.readyRows[i]
      up(r.card.border); up(r.card.fill)
      upList(r.art)
      up(r.name); up(r.act)
    end
    for i = 1, #MENU.readyBtns do
      up(MENU.readyBtns[i].bar); up(MENU.readyBtns[i].label)
    end
    for i = 1, #MENU.colorSquares do
      up(MENU.colorSquares[i].border); up(MENU.colorSquares[i].fill)   -- 描边在色块之下
    end
    -- 控制方式页
    up(MENU.devHL)
    upList(MENU.devTexts)
    up(MENU.devMsgLabel)
    for i = 1, #MENU.devRows do
      local r = MENU.devRows[i]
      up(r.name); up(r.value)
      if r.arrows ~= nil then up(r.arrows.left); up(r.arrows.right) end
    end
    -- 按键设置页
    up(MENU.keyHL)
    upList(MENU.keyTexts)
    upList(MENU.keyListTexts)
    for i = 1, #MENU.keyRows do
      local r = MENU.keyRows[i]
      up(r.name); up(r.value)
      if r.arrows ~= nil then up(r.arrows.left); up(r.arrows.right) end
    end
    -- 对战设置页
    up(MENU.rulesHL)
    upList(MENU.rulesTexts)
    for i = 1, #MENU.rulesRows do
      local r = MENU.rulesRows[i]
      up(r.name); up(r.value)
      if r.arrows ~= nil then up(r.arrows.left); up(r.arrows.right) end
    end
    -- 其他设置页
    up(MENU.otherHL)
    upList(MENU.otherTexts)
    for i = 1, #MENU.otherRows do
      local r = MENU.otherRows[i]
      up(r.name); up(r.value)
      if r.arrows ~= nil then up(r.arrows.left); up(r.arrows.right) end
    end
    -- ⑩ 「返回」按钮 + 按键提示（所有菜单子页最上层）
    if MENU.back ~= nil then
      for i = 1, #MENU.back.parts do up(MENU.back.parts[i].ctl) end
      up(MENU.back.label)
      up(MENU.back.hint)
    end
  end)
  if not ok then
    ZORDER.broken = true
    printerr("[坦克动荡] SetAsLastSibling 不可用，层级重排已停用；"
      .. "请在编辑器「界面控件组管理」把本关卡改为【层级渲染(新)】并给模板配置层级")
  elseif not ZORDER.reported then
    -- 只报一次：层级重排每帧都会调用，避免刷屏。
    -- 成功也要留痕，用于区分「层级重排正常但文字仍不出」与「层级重排没生效」。
    ZORDER.reported = true
    print("[坦克动荡] 层级重排成功（SetAsLastSibling 可用）")
  end
end

-- 准备页各行文本 / 色块刷新（前向声明，供 refreshMenu 引用）
local updateReadyRows
-- 控制方式页文本刷新（前向声明，供 refreshMenu 引用）
local refreshDevRows
-- 设置面板文本刷新（前向声明，供 refreshMenu / toggleSound 引用）
local refreshSetRows
-- 对战设置 / 其他设置页刷新挂在 MENU 上（MENU.refreshRulesRows / MENU.refreshOtherRows），
-- 以避免再增主 chunk 的顶层 local（真机 Lua 5.3 上限 200，见 AGENTS.md）

refreshMenu = function()
  local p = MENU.phase
  -- 切页时把输入边沿缓存**同步为「当前仍按住的输入」**，而不是清零。
  --   清零会让「按住不放的键」在新页首帧被当成一次新按下（曾导致：按住齿轮进设置页 → 首行被自动确认）。
  if MENU.lastPhase ~= p then
    MENU.lastPhase = p
    local i, gp = G.input, G.gp
    MENU.prev.fwd   = i.fwd   or gp.fwd
    MENU.prev.back  = i.back  or gp.back
    MENU.prev.left  = i.left  or gp.left
    MENU.prev.right = i.right or gp.right
    MENU.prev.fire  = i.fire  or gp.fire
    MENU.prev.keyFire = (i.fire and not G.pmouse.fire) or gp.fire
  end
  local function vis(ctl, v) if ctl ~= nil then pcall(function() ctl:SetVisible(v) end) end end

  vis(MENU.panel, p ~= "playing")
  -- HUD 仅对战期显示（计分板：迷你坦克图标 + 分数数字）
  local onPlaying = (p == "playing")
  for i = 1, #hud.icons do
    local parts = hud.icons[i]
    for j = 1, #parts do vis(parts[j].ctl, onPlaying) end
  end
  for i = 1, #hud.scoreLabels do vis(hud.scoreLabels[i], onPlaying) end
  for i = 1, #hud.nameLabels do vis(hud.nameLabels[i], onPlaying) end
  for i = 1, #hud.pingLabels do vis(hud.pingLabels[i], onPlaying) end
  for i = 1, #hud.frags do vis(hud.frags[i].ctl, onPlaying) end
  -- 对战倒计时（**仅联机**的战斗页显示）+ 对局结算提示（结束后显示）
  vis(hud.timerLabel, onPlaying and G.online)
  vis(hud.resultLabel, onPlaying and G.match ~= nil and G.match.over == true)
  -- 触屏操控可视：仅对战期（移动端）显示；切走时收起
  if not (onPlaying and G.touchMode) then hideTouchViz() end

  local onMenu = p == "menu"
  for i = 1, #MENU.menuTexts do vis(MENU.menuTexts[i], onMenu) end

  -- 准备页
  local onReady = (p == "ready")
  for i = 1, #MENU.readyTexts do
    -- [1] = 底部空文本（占位）；[2] = 联机状态行（倒计时 / 控制提示 / 对方就绪），仅联机显示
    vis(MENU.readyTexts[i], onReady and (i == 1 or G.online))
  end
  for i = 1, #MENU.readyRows do
    local r = MENU.readyRows[i]
    if onReady then
      vis(r.name, true); vis(r.act, true)
      -- 面板 / 图示由 updateReadyRows 按人数与加入状态摆放
    else
      MENU.hideReadyCard(r.card); MENU.hideCtrlArt(r.art)
      vis(r.name, false); vis(r.act, false)
    end
  end
  -- 准备页下方按钮（按键设置 / 其他设置）：**仅联机准备页**显示（用户 2026-10-12：
  --   这两个入口专属联机；单机 / 同机多人的准备页不显示，免得混淆）。
  local showReadyBtns = onReady and G.online == true
  -- 联机：本端**已准备** ⇒ 「按键设置」入口**灰掉**（用户 2026-10-15：准备后不可再改键；灰显不隐藏）
  local keysLocked = showReadyBtns and MENU.keysLocked()
  for i = 1, #MENU.readyBtns do
    local b = MENU.readyBtns[i]
    vis(b.bar, showReadyBtns)
    vis(b.label, showReadyBtns)
    if b.label ~= nil then
      local grey = keysLocked and b.kind == "keys"
      pcall(function() b.label.fontColor = grey and COLOR.DIM or COLOR.MENU_TEXT end)
    end
  end
  -- 联机准备页「颜色选择」：仅准备页且联机时显示；选中者显示描边
  for i = 1, #MENU.colorSquares do
    local cs = MENU.colorSquares[i]
    local show = onReady and G.online
    vis(cs.fill, show)
    vis(cs.border, show and MENU.colorPick == i)
  end
  if onReady then updateReadyRows(); MENU.updateReadyStatus() end

  -- 控制方式页
  local onDev = (p == "devices")
  for i = 1, #MENU.devTexts do vis(MENU.devTexts[i], onDev) end
  for i = 1, #MENU.devRows do
    local row = MENU.devRows[i]
    vis(row.name, onDev); vis(row.value, onDev)
    if not onDev then MENU.hideArrows(row.arrows) end
  end
  vis(MENU.devHL, onDev)
  vis(MENU.devMsgLabel, onDev)
  if onDev then refreshDevRows() end

  -- 按键设置页
  local onKeys = (p == "keys")
  for i = 1, #MENU.keyTexts do vis(MENU.keyTexts[i], onKeys) end
  for i = 1, #MENU.keyListTexts do vis(MENU.keyListTexts[i], onKeys) end
  if onKeys then
    refreshKeyRows()   -- 内部负责各行（含隐藏行）与 ◀▶ 的显隐
  else
    for i = 1, #MENU.keyRows do
      local row = MENU.keyRows[i]
      vis(row.name, false); vis(row.value, false)
      MENU.hideArrows(row.arrows)
    end
    vis(MENU.keyHL, false)
  end

  -- 设置面板（齿轮进入）
  local onSet = (p == "settings")
  for i = 1, #MENU.setTexts do vis(MENU.setTexts[i], onSet) end
  for i = 1, #MENU.setRows do
    local row = MENU.setRows[i]
    -- 隐藏规则见 MENU.rowHidden：非战斗不显示「回到主界面」；联机只留「按键设置 / 其他设置」。
    local showRow = onSet and not MENU.rowHidden(row)
    vis(row.name, showRow); vis(row.value, showRow)
    if not showRow then MENU.hideArrows(row.arrows) end
  end
  vis(MENU.setHL, onSet)
  if onSet then refreshSetRows() end

  -- 对战设置页
  local onRules = (p == "rules")
  for i = 1, #MENU.rulesTexts do vis(MENU.rulesTexts[i], onRules) end
  for i = 1, #MENU.rulesRows do
    local row = MENU.rulesRows[i]
    vis(row.name, onRules); vis(row.value, onRules)
    if not onRules then MENU.hideArrows(row.arrows) end
  end
  vis(MENU.rulesHL, onRules)
  if onRules then MENU.refreshRulesRows() end

  -- 其他设置页
  local onOther = (p == "other")
  for i = 1, #MENU.otherTexts do vis(MENU.otherTexts[i], onOther) end
  for i = 1, #MENU.otherRows do
    local row = MENU.otherRows[i]
    vis(row.name, onOther); vis(row.value, onOther)
    if not onOther then MENU.hideArrows(row.arrows) end
  end
  vis(MENU.otherHL, onOther)
  if onOther then MENU.refreshOtherRows() end
  -- 底部按键提示条（W S 滚动 / A D 切换 / F 确认）：设置面板 + 对战设置页 + 其他设置页都显示。
  --   注：必须放在 onRules/onOther 算出来之后，否则它们在此处还是未声明的全局（nil）。
  MENU.placeSetHints(onSet or onRules or onOther)

  -- 主菜单：4 模式横幅 + 齿轮（设置）；选中态由 stepMenuAnim 逐帧体现（放大 / 悬停变绿）。
  for i = 1, #MENU.banners do
    local b = MENU.banners[i]
    if onMenu then
      for j = 1, #b.labels do vis(b.labels[j].label, true) end
      MENU.placeBanner(b, b.x, b.y, b.rot, b.scale)
    else
      MENU.hideBanner(b)
    end
  end
  if onMenu then
    MENU.placeGear(MENU.gear, MENU.GEAR_POS.x, MENU.GEAR_POS.y, MENU.sel == #MENU.MODES + 1)
    MENU.placeDesc()
    MENU.placeMenuArt(true)      -- 背景美术（山丘 + 大坦克）只在主菜单显示
  else
    MENU.hideGear(MENU.gear)
    MENU.hideDesc()
    MENU.placeMenuArt(false)
  end
  -- 底部按钮 + 按键提示：主菜单不显示；
  --   **对战期 = 右下角「菜单」**（等价主界面右上角齿轮，点/空格 打开设置面板）；联机对战期不显示；
  --   设置 / 按键设置 / 控制方式 / 准备页 / 对战设置 / 其他设置 = 右上角「返回」（点 / R）。
  if p == "playing" then
    -- 对战期「菜单」按钮：单机放**右下角**（迷宫下方边框带的右端，原版位置）；
    --   按键提示显示**空格**（空格才是单机打开菜单/暂停的键，用户 2026-10-11 要求；R 仍可退出对局）。
    --   **联机：右下角没有菜单按钮**（联机不得暂停 / 开设置，见用户规则）。
    MENU.backPos, MENU.hintPos = MENU.BACK_POS_PLAY, MENU.HINT_POS_PLAY
    MENU.backHover = false
    -- 对战期这个按钮 = **「菜单」**（等价主界面右上角齿轮：暂停并打开设置面板）。
    if MENU.back ~= nil and MENU.back.label ~= nil then
      pcall(function() MENU.back.label.text = "菜单" end)
    end
    if G.online then
      MENU.hideBack()
    else
      if MENU.back ~= nil and MENU.back.hint ~= nil then
        pcall(function()
          ---@diagnostic disable-next-line: inject-field
          MENU.back.hint.keyboardKeyCode = Enum.KeyboardKeyCode.JumpKey   -- 空格
        end)
      end
      MENU.placeBack()
    end
  elseif p == "settings" or p == "keys" or p == "devices" or p == "ready"
      or p == "rules" or p == "other" then
    MENU.backPos, MENU.hintPos = MENU.BACK_POS, MENU.HINT_POS
    MENU.backHover = false
    -- 非对战期（设置 / 按键设置 / 控制方式 / 准备页 / 对战设置 / 其他设置）这个按钮 = **「返回」**。
    if MENU.back ~= nil and MENU.back.label ~= nil then
      pcall(function() MENU.back.label.text = "返回" end)
    end
    if MENU.back ~= nil and MENU.back.hint ~= nil then
      pcall(function()
        ---@diagnostic disable-next-line: inject-field
        MENU.back.hint.keyboardKeyCode = Enum.KeyboardKeyCode.CharacterSkill3Key   -- R
      end)
    end
    MENU.placeBack()
  else
    MENU.hideBack()
  end
  -- 切页后把菜单控件重新抬到最上层（菜单控件创建最早，否则会被后建的坦克压住）
  applyZOrder()
end

-- 刷新准备页（原版 controlsNPlayer）：只画真人玩家的控制面板（AI 位不画）。
--   每块面板 = 玩家名（上）+ 控制器图示（中，按该玩家控制方式：键盘 / 鼠标 / 手柄）+ 加入提示（下）。
--   加入后底色变玩家色、提示清空（对应原版 background.setRGB + activateText=""）。
updateReadyRows = function()
  local slots = buildSlots(MENU.mode)
  local humans = {}
  for n = 1, #slots do
    local sl = slots[n]
    if sl.scheme ~= nil or sl.mouse == true or sl.pad == true then humans[#humans + 1] = n end
  end
  local count = #humans
  local RW, RH, rowY = MENU.RDY_W, MENU.RDY_H, 20
  for r = 1, #MENU.readyRows do
    local row = MENU.readyRows[r]
    local n = humans[r]
    if n == nil then
      row.n = nil
      MENU.hideReadyCard(row.card); MENU.hideCtrlArt(row.art)
      pcall(function() row.name:SetVisible(false) end)
      pcall(function() row.act:SetVisible(false) end)
    else
      local sl = slots[n]
      local isMe = (n == G.playerIndex)
      -- 图示类型 / 提示：
      --   · **联机**：跟随**各自设备**的第一种控制方式（自己 = 本机设备；对手 = 同步过来的 ctrlKind）；
      --     键盘图示的键名跟随**各自按键设置**（自己 = BINDS[1]；对手改了什么键无从得知 ⇒ 用默认键位）。
      --   · 本地（同机多人）：**移动端一律用触屏图**；其余按该槽位的控制方式。
      local kind, fireLabel, moves, hint
      if G.online then
        local ck = onlineApi.CTRL_KB
        if isMe then
          ck = MENU.ctrlKind()
        else
          local d = G.readySeen[n]
          if d ~= nil and d.ctrl ~= nil then ck = d.ctrl end
        end
        if ck == onlineApi.CTRL_TOUCH then
          kind, hint = "touch", (isMe and "点你的面板准备" or "等待对方准备")
        elseif ck == onlineApi.CTRL_PAD then
          kind, hint = "pad", (isMe and "按 A 准备" or "等待对方准备")
        else
          kind = "keyboard"
          local b = (isMe and BINDS[1] or DEFAULT_BINDS[1]) or {}
          local function gl(k) return (k ~= nil and BIND_LABEL[k]) or "?" end
          fireLabel = gl(b.fire)
          moves = { fwd = gl(b.fwd), back = gl(b.back), left = gl(b.left), right = gl(b.right) }
          hint = isMe and ("按 " .. fireLabel .. " 准备") or "等待对方准备"
        end
      elseif G.touchMode then
        kind, hint = "touch", "点你的面板加入"
      elseif sl.mouse == true then
        kind, hint = "mouse", "点左键加入"
      elseif sl.pad == true then
        kind, hint = "pad", "按 A 加入"
      else
        kind = "keyboard"
        local b = BINDS[sl.scheme] or {}
        local function gl(k) return (k ~= nil and BIND_LABEL[k]) or "?" end
        fireLabel = gl(b.fire)
        moves = { fwd = gl(b.fwd), back = gl(b.back), left = gl(b.left), right = gl(b.right) }
        hint = "按 " .. fireLabel .. " 加入"
      end
      local x
      if count <= 1 then x = 0
      elseif count == 2 then x = (r == 1) and -150 or 150
      else x = (r - 1) * 230 - 230 end   -- 3 人：-230 / 0 / 230
      local joined = (MENU.joined[n] == true)
      -- 联机：卡片底色 = 该玩家**自己选定/已准备**的颜色（未选/对方未准备时用槽位默认色）
      local cardColor = sl.color
      if G.online then
        if isMe and MENU.colorPick ~= nil then
          cardColor = MENU.PICK_COLORS[MENU.colorPick] or cardColor
        elseif not isMe then
          local d = G.readySeen[n]
          if d ~= nil and d.ready and d.color >= 1 then
            cardColor = MENU.PICK_COLORS[d.color] or cardColor
          end
        end
      end
      MENU.placeReadyCard(row.card, x, rowY, joined, cardColor)
      -- 控制器图示（懒构建 + 缓存；控制方式 / 开火键 / 移动键变化时重建）
      local artKey = kind
      if kind == "keyboard" then
        artKey = kind .. "|" .. fireLabel .. "|" .. moves.fwd .. moves.back .. moves.left .. moves.right
      end
      if row.artKey ~= artKey then
        MENU.freeCtrlArt(row.art)
        row.art = MENU.buildCtrlArt(kind, fireLabel, moves)
        row.artKey = artKey
      end
      MENU.placeCtrlArt(row.art, x, rowY - 6)
      row.n, row.cx, row.cy = n, x, rowY   -- 供触屏「点自己的面板加入」命中判定
      pcall(function()
        -- 本机那张卡：名字后附实时延迟（联机）；其余卡只有名字
        local nm = sl.name
        if n == G.playerIndex and G.online and G.pingMs ~= nil then
          nm = nm .. "  " .. tostring(floor(G.pingMs + 0.5)) .. "ms"
        end
        row.name.text = nm
        row.name.fontColor = COLOR.MENU_TEXT
        row.name:SetVisible(true)
      end)
      row.name:SetPos(x, rowY + RH / 2 - 28)
      pcall(function()
        row.act.text = joined and "" or hint
        row.act.fontColor = COLOR.ACCENT
        row.act:SetVisible(true)
      end)
      row.act:SetPos(x, rowY - RH / 2 + 24)
    end
  end
end

-- 联机准备页顶部状态行（倒计时 + 准备提示 + 对方是否已准备）。
--   **仅 G.online 时显示**（本地模式不加倒计时，加入齐即开赛；对方就绪由**准备档变量**驱动）。
--   ⚠️ `me` 必须取 `G.playerIndex`（原先写死"第一个真人槽位" ⇒ 槽位 2 的玩家会看到 1 号的准备状态）。
MENU.updateReadyStatus = function()
  local lbl = MENU.readyTexts[2]
  if lbl == nil or not G.online then return end
  local me, opp = G.playerIndex, MENU.oppSlot()
  -- 本机玩家的准备提示按**本机设备**给（联机可用所有控制方式，只提示最顺手的那一种）
  local ck = MENU.ctrlKind()
  local myHint
  if ck == onlineApi.CTRL_TOUCH then
    myHint = "点你的面板准备"
  elseif ck == onlineApi.CTRL_PAD then
    myHint = "按 A 准备"
  else
    local b = BINDS[1] or {}
    myHint = "按 " .. (((b.fire ~= nil) and BIND_LABEL[b.fire]) or "开火键") .. " 准备"
  end
  local mine = (MENU.joined[me] == true) and "你已准备" or myHint
  local oppTxt = "对方 " .. (MENU.joined[opp] == true and "已准备" or "未准备")
  local cname = { "红", "绿", "蓝", "灰" }
  local colorTxt = (MENU.colorPick ~= nil) and (cname[MENU.colorPick] or "?") or "未选"
  local txt
  if MENU.startTimer > 0 then
    txt = "游戏开始： " .. tostring(max(0, floor(MENU.startTimer + 0.999))) .. " 秒后开始"
  else
    local secs = max(0, floor(MENU.readyTimer + 0.999))
    txt = "准备倒计时 " .. tostring(secs) .. " 秒    |    颜色 " .. colorTxt
      .. "    |    " .. mine .. "    |    " .. oppTxt
  end
  pcall(function() lbl.text = txt end)
end

-- 30 秒到点 → **强制准备**。
--   ⚠️ 联机时只强制**本端自己**那一位（不允许替对方准备）；颜色由 `MENU.tryReadySelf` 仲裁
--      （未选色 ⇒ 随机；选中的色已被对方占用 ⇒ 换一个可用的），效果等价于「房主先占、非房主避开」。
MENU.forceReady = function()
  if G.online then
    if MENU.joined[G.playerIndex] ~= true then
      MENU.tryReadySelf()
      print("[坦克动荡] 联机：30 秒到点 ⇒ 强制准备，颜色=" .. tostring(MENU.colorPick or 0))
    end
    return
  end
  local slots = buildSlots(MENU.mode)
  for n = 1, #slots do
    local sl = slots[n]
    if sl.scheme ~= nil or sl.mouse == true or sl.pad == true then MENU.joined[n] = true end
  end
  updateReadyRows()
  MENU.updateReadyStatus()
end

-- 联机：一方中途离开（千星奇域 ESC / 掉线等）→ 该方判「逃跑」、对方直接胜利。
--   两条可用路径（二选一或都留）：
--     ① **默认**：客户端自己看 `TT2_PLAYERS` 掉到 1 判定（见 MENU.syncOnline）—— 编辑器侧**无需**额外连线；
--     ② 备用：编辑器侧检测到离开后下发 `TT2_LEAVE`（见 bindNet）→ 走到这里。
--   离开者本身由他进局预置的「逃跑合法性 = 否」判「逃跑」（见 beginMatch / TT2_SET_ESCAPE）。
MENU.onPlayerEscaped = function(idx)
  if not G.online then return end
  local winner = nil
  for i = 1, #G.tanks do if i ~= idx then winner = i end end
  print("[坦克动荡] 联机：玩家 " .. tostring(idx) .. " 逃跑 ⇒ 判负，对方胜利")
  MENU.finishMatch(winner)
end

-- 刷新控制方式页：3 位玩家行显示草稿里的控制方式（名称为玩家色，选中为强调色）；
-- 底部提示显示上次保存结果。高亮条跟随选中行。
refreshDevRows = function()
  for i = 1, #MENU.devRows do
    local row = MENU.devRows[i]
    local sel = (MENU.devSel == i)
    local nameTxt, valTxt, c
    if row.kind == "player" then
      nameTxt = PLAYERS.name[row.n]
      valTxt = modeDisplayLabel(MENU.devDraft[row.n])
      c = sel and COLOR.ACCENT or PLAYERS.color[row.n]
    elseif row.kind == "save" then
      nameTxt, valTxt = "保存设置", ""
      c = sel and COLOR.ACCENT or COLOR.MENU_ROW
    else
      nameTxt, valTxt = "恢复默认", ""
      c = sel and COLOR.ACCENT or COLOR.DIM
    end
    pcall(function() row.name.text = nameTxt end)
    pcall(function() row.value.text = valTxt end)
    pcall(function() row.name.fontColor = c end)
    pcall(function() row.value.fontColor = c end)
    -- 玩家行的 ◀ ▶ 只在**该行被选中**时显示；保存/恢复默认行不显示
    if row.kind == "player" and sel then
      MENU.placeArrows(row.arrows, MENU.DEV_ARROW_L, MENU.DEV_ARROW_R, row.y, true, true)
    else
      MENU.hideArrows(row.arrows)
    end
  end
  if MENU.devHL ~= nil then
    local row = MENU.devRows[MENU.devSel]
    if row ~= nil then
      pcall(function()
        MENU.devHL:SetSizeDelta(680, 34)
        MENU.devHL:SetAnchoredPosition(0, row.y)
      end)
    end
  end
  if MENU.devMsgLabel ~= nil then
    local msg, col
    if MENU.devOk == true then msg, col = "已保存", COLOR.OK
    elseif MENU.devOk == false then msg, col = "3 位玩家的控制方式不能重复，无法保存", COLOR.NO
    else msg, col = "", COLOR.DIM end
    pcall(function()
      MENU.devMsgLabel.text = msg
      MENU.devMsgLabel.fontColor = col
    end)
  end
  -- 高亮条 SetAnchoredPosition/SetSizeDelta 后可能被渲染到行文字之上（复用控件不重排层级），
  -- 故重排一次层级，把行文字重新抬到高亮条上方（与主菜单 refreshMenu 行为一致）。
  applyZOrder()
end

-- 按键设置页的「鼠标操控」行：**联机模式下隐藏且不可改**（用户 2026-10-12：联机只能用限速转向）。
MENU.keyRowHidden = function(row)
  return row ~= nil and row.kind == "mouseBranch" and G.online == true
end

-- 刷新按键设置页：写各行文本 / ◀▶ 三角 / 高亮条 / 冲突提示。
refreshKeyRows = function()
  -- 选中行被隐藏（切联机）→ 落到第一个可见行
  if MENU.keyRowHidden(MENU.keyRows[MENU.keySel]) then
    for i = 1, #MENU.keyRows do
      if not MENU.keyRowHidden(MENU.keyRows[i]) then MENU.keySel = i; break end
    end
  end
  local cap = CAPTURE.active
  local dup = duplicateKeySet()
  local function vis(ctl, v) if ctl ~= nil then pcall(function() ctl:SetVisible(v) end) end end
  for i = 1, #MENU.keyRows do
    local row = MENU.keyRows[i]
    local sel = (MENU.keySel == i)
    local nameTxt, valTxt, c
    if row.kind == "mouseBranch" then
      nameTxt = "鼠标操控"
      valTxt = useNewMouseControl and "限速转向" or "瞬时转向"
    elseif row.kind == "action" then  -- 6 个可自定义按键之一
      nameTxt = ACTION_LABEL[row.action] or row.action
      local kid = BINDS[row.scheme] and BINDS[row.scheme][row.action]
      if cap and CAPTURE.scheme == row.scheme and CAPTURE.action == row.action then
        valTxt = "请按新键"
      else
        valTxt = (kid ~= nil and BIND_LABEL[kid]) or "未设置"
      end
      -- 该行的键与别的绑定重复 → 标红
      if kid ~= nil and dup[kid] then c = COLOR.NO end
    end
    if c == nil then c = sel and COLOR.ACCENT or COLOR.MENU_ROW end
    local hidden = MENU.keyRowHidden(row)
    vis(row.name, not hidden)
    vis(row.value, not hidden)
    pcall(function() row.name.text = nameTxt end)
    pcall(function() row.value.text = valTxt end)
    pcall(function() row.name.fontColor = c end)
    pcall(function() row.value.fontColor = c end)
    -- ◀ ▶ 三角：只在**鼠标操控行**被选中时显示（动作行靠 F / 点击改键，不用左右）
    if row.kind == "mouseBranch" and sel and not hidden then
      MENU.placeArrows(row.arrows, MENU.SET_ARROW_L, MENU.SET_ARROW_R, row.y, true, true)
    else
      MENU.hideArrows(row.arrows)
    end
  end
  -- 高亮条
  local cur = MENU.keyRows[MENU.keySel]
  if MENU.keyHL ~= nil then
    if cur ~= nil then
      pcall(function()
        MENU.keyHL:SetSizeDelta(680, 30)
        MENU.keyHL:SetAnchoredPosition(0, cur.y)
      end)
      vis(MENU.keyHL, true)
    else
      vis(MENU.keyHL, false)
    end
  end
  -- 冲突提示
  if MENU.keyTexts[3] ~= nil then
    local msg = ""
    if MENU.keyConflict ~= nil then
      msg = "按键冲突：" .. tostring(MENU.keyConflict) .. " —— 改成不重复的键后才能返回"
    end
    pcall(function()
      MENU.keyTexts[3].text = msg
      MENU.keyTexts[3].fontColor = COLOR.NO
    end)
  end
  -- 底部「不可绑定的按键」：返回键 + 空格（空格被「暂停」占用）
  if MENU.keyListTexts[2] ~= nil then
    local rid = CAPTURE.returnId
    local rl = (rid ~= nil and BIND_LABEL[rid]) or "R"
    pcall(function()
      MENU.keyListTexts[2].text = rl .. "（返回）  空格（暂停）—— 菜单保留，不能绑定给游戏操作"
      MENU.keyListTexts[2].fontColor = COLOR.MENU_ROW
    end)
  end
  -- 同 refreshDevRows：移动高亮条后重排层级，避免深色条盖住行文字。
  applyZOrder()
end

-- 上下导航：**跳过隐藏行**（联机时「鼠标操控」行隐藏）。
MENU.keyNav = function(dir)
  local n = #MENU.keyRows
  local i = MENU.keySel
  for _ = 1, n do
    i = i + dir
    if i < 1 then i = n elseif i > n then i = 1 end
    if not MENU.keyRowHidden(MENU.keyRows[i]) then MENU.keySel = i; break end
  end
  refreshKeyRows()
end

-- （原 MENU.cycleLetter「字母键位预设切换」已删除：用户 2026-10-11 决定不再提供预设，只留自定义）

-- 退出按键设置页（返回键）：冲突则禁止返回并提示；否则回设置面板（键位已即时生效＝自动保存）。
MENU.leaveKeys = function()
  if CAPTURE.active then
    CAPTURE.active, CAPTURE.scheme, CAPTURE.action = false, nil, nil
    refreshKeyRows()
    return
  end
  local bad = findBindConflict()
  if bad ~= nil then
    MENU.keyConflict = BIND_LABEL[bad] or bad
    refreshKeyRows()
    return
  end
  MENU.keyConflict = nil
  MENU.phase = MENU.returnPhase or "settings"
  if MENU.phase == "settings" then MENU.setSel = 1 end
  refreshMenu()
end

-- 刷新设置面板：行多为**子页入口**（无值）；「控制模式」（移动端）显示当前手感并可左右切换。
refreshSetRows = function()
  -- 选中行被隐藏（切联机 / 离开战斗）→ 落到第一个可见行（避免高亮条停在不存在的行上）。
  if MENU.rowHidden(MENU.setRows[MENU.setSel]) then
    for i = 1, #MENU.setRows do
      if not MENU.rowHidden(MENU.setRows[i]) then MENU.setSel = i; break end
    end
  end
  for i = 1, #MENU.setRows do
    local row = MENU.setRows[i]
    local sel = (MENU.setSel == i)
    local val, c = "", sel and COLOR.ACCENT or COLOR.MENU_ROW
    if row.kind == "touchMode" then
      val = (G.touchHandfeel == "aim") and "朝向我" or "摇杆 8 向"
    end
    pcall(function() row.name.text = row.label end)
    pcall(function() row.value.text = val end)
    pcall(function() row.name.fontColor = c end)
    pcall(function() row.value.fontColor = c end)
    -- 「控制模式」行右侧的 ◀ ▶ 只在**该行被选中**时显示；点击 = A/D 左右切换
    if row.kind == "touchMode" and sel then
      MENU.placeArrows(row.arrows, MENU.SET_ARROW_L, MENU.SET_ARROW_R, row.y, true, true)
    else
      MENU.hideArrows(row.arrows)
    end
  end
  if MENU.setHL ~= nil then
    local row = MENU.setRows[MENU.setSel]
    if row ~= nil then
      pcall(function()
        MENU.setHL:SetSizeDelta(680, 34)
        MENU.setHL:SetAnchoredPosition(0, row.y)
      end)
    end
  end
  applyZOrder()
end

-- 刷新对战设置页：武器开/关 + 平滑碰撞 + 恢复默认。开关行右侧 ◀ ▶ 仅选中时显示。
MENU.refreshRulesRows = function()
  for i = 1, #MENU.rulesRows do
    local row = MENU.rulesRows[i]
    local sel = (MENU.rulesSel == i)
    local val, c = "", sel and COLOR.ACCENT or COLOR.MENU_ROW
    if row.kind == "weapon" then
      local on = (G.rules.weapons[row.w] ~= false)
      val = on and "开" or "关"
      if not sel then c = on and COLOR.OK or COLOR.DIM end
    elseif row.kind == "smooth" then
      val = G.rules.smooth and "开" or "关"
      if not sel then c = G.rules.smooth and COLOR.OK or COLOR.DIM end
    end
    pcall(function() row.value.text = val end)
    pcall(function() row.name.fontColor = c end)
    pcall(function() row.value.fontColor = c end)
    if (row.kind == "weapon" or row.kind == "smooth") and sel then
      MENU.placeArrows(row.arrows, MENU.SET_ARROW_L, MENU.SET_ARROW_R, row.y, true, true)
    else
      MENU.hideArrows(row.arrows)
    end
  end
  if MENU.rulesHL ~= nil then
    local row = MENU.rulesRows[MENU.rulesSel]
    if row ~= nil then
      pcall(function()
        MENU.rulesHL:SetSizeDelta(680, 30)
        MENU.rulesHL:SetAnchoredPosition(0, row.y)
      end)
    end
  end
  applyZOrder()
end

-- 刷新其他设置页：显示大小 / 抗锯齿 / 音乐 / 音效。
MENU.refreshOtherRows = function()
  for i = 1, #MENU.otherRows do
    local row = MENU.otherRows[i]
    local sel = (MENU.otherSel == i)
    local val, c = "", sel and COLOR.ACCENT or COLOR.MENU_ROW
    -- 到尽头的方向：对应三角**消失**（用户 2026-10-11）。列表型（显示大小 / 抗锯齿）才有「尽头」；
    --   「音乐 / 音效」是开/关两态，两个三角都保留。
    local showL, showR = true, true
    if row.kind == "sound" then
      val = MENU.soundOn and "开" or "关"
      if not sel then c = MENU.soundOn and COLOR.OK or COLOR.DIM end
    elseif row.kind == "music" then
      val = MENU.musicOn and "开" or "关"
      if not sel then c = MENU.musicOn and COLOR.OK or COLOR.DIM end
    elseif row.kind == "uiScale" then
      local v = MENU.SCALE_OPTS[G.uiScaleMode] or 0
      val = (v == 0) and "自适应" or (tostring(floor(v * 100 + 0.5) / 100) .. "×")
      showL = G.uiScaleMode > 1
      showR = G.uiScaleMode < #MENU.SCALE_OPTS
    elseif row.kind == "aa" then
      val = (G.aaWidth <= 0) and "关" or tostring(G.aaWidth)
      local cur = 1
      for k = 1, #MENU.AA_OPTS do if MENU.AA_OPTS[k] == G.aaWidth then cur = k end end
      showL = cur > 1
      showR = cur < #MENU.AA_OPTS
    end
    pcall(function() row.name.text = row.label end)
    pcall(function() row.value.text = val end)
    pcall(function() row.name.fontColor = c end)
    pcall(function() row.value.fontColor = c end)
    if sel then
      MENU.placeArrows(row.arrows, MENU.SET_ARROW_L, MENU.SET_ARROW_R, row.y, true, true)
      if not showL then pcall(function() row.arrows.left:SetVisible(false) end) end
      if not showR then pcall(function() row.arrows.right:SetVisible(false) end) end
    else
      MENU.hideArrows(row.arrows)
    end
  end
  if MENU.otherHL ~= nil then
    local row = MENU.otherRows[MENU.otherSel]
    if row ~= nil then
      pcall(function()
        MENU.otherHL:SetSizeDelta(680, 34)
        MENU.otherHL:SetAnchoredPosition(0, row.y)
      end)
    end
  end
  applyZOrder()
end

-- 当前处于哪个「设置类」页面 → 刷新对应页（切换开关 / 步进时调用）
MENU.refreshCfg = function()
  if MENU.phase == "other" then MENU.refreshOtherRows()
  elseif MENU.phase == "rules" then MENU.refreshRulesRows()
  elseif MENU.phase == "settings" then refreshSetRows() end
end

-- 显示设置：左右切换「显示大小」（列表里的 0 = 自适应 = 按画布等比适配 `G.uiFitScale`）
--   **到尽头即停**（不再循环）——与「尽头方向三角消失」一致。
MENU.stepUiScale = function(dir)
  local list, n = MENU.SCALE_OPTS, #MENU.SCALE_OPTS
  local cur = G.uiScaleMode + (dir or 1)
  if cur < 1 then cur = 1 elseif cur > n then cur = n end
  G.uiScaleMode = cur
  local v = list[cur]
  applyUIScale((v == 0) and (G.uiFitScale or 1) or v)
  MENU.refreshCfg()
end

-- 显示设置：左右切换「抗锯齿」（0 = 关；>0 = 羽化像素数）。同样**到尽头即停**。
MENU.stepAA = function(dir)
  local list, n = MENU.AA_OPTS, #MENU.AA_OPTS
  local cur = 1
  for i = 1, n do if list[i] == G.aaWidth then cur = i end end
  cur = cur + (dir or 1)
  if cur < 1 then cur = 1 elseif cur > n then cur = n end
  applyAAAll(list[cur])
  MENU.refreshCfg()
end

-- 按模式配置每辆坦克：控制方案 / 是否人类 / 车体色 / 是否 AI（莱卡）。
-- 对应原版 frame_7（单人：红 vs 莱卡）、frame_19（双人：红 vs 绿）、
--        frame_31/43（三人：红 + 绿 + 鼠标操控的第 3 台）。
local function applyMode(mode)
  G.mode = mode
  local slots = buildSlots(mode)
  -- 坦克数量随模式增减：三人模式需要第 3 台；切回 solo/duo 必须销毁多余的，
  -- 否则残留坦克会被当成 AI 参战（见 tankFrame 的 else 分支）。
  while #G.tanks < #slots do
    G.tanks[#G.tanks + 1] = createTank(#G.tanks + 1, 0, 0)
  end
  while #G.tanks > #slots do
    disposeTank(G.tanks[#G.tanks])
    G.tanks[#G.tanks] = nil
  end
  for i = 1, #slots do
    local t = G.tanks[i]
    local sl = slots[i]
    t.baseColor, t.turretColor = sl.color, sl.turretColor or sl.color
    -- 联机：本地玩家使用准备界面选定的颜色（红 / 绿 / 蓝 / 灰）
    if G.online and i == G.playerIndex and MENU.colorPick ~= nil then
      local pc = MENU.PICK_COLORS[MENU.colorPick]
      if pc ~= nil then t.baseColor, t.turretColor = pc, pc end
    end
    t.mouseTank = (sl.mouse == true)
    t.padTank = (sl.pad == true)
    t.settingsUseNewMouseControl = useNewMouseControl   -- 运行时切换的鼠标分支
    t.settingsUseSmoothCollision = G.rules.smooth       -- 运行时切换的平滑碰撞
    --   ⚠️ 上面两项都必须在**每次 applyMode** 重新写入：坦克对象跨对局复用，
    --   若只在 createTank 时拷一次，就会出现「改了对战设置里的开关，重开一局也不生效」（用户 2026-10-15）。
    t.controlIndex = sl.scheme                     -- 鼠标 / 手柄槽为 nil
    -- 移动端：所有真人玩家都走触屏（忽略其配置的键鼠 / 手柄方式），并标明第几位触屏玩家
    if G.touchMode and not sl.ai then
      t.touchPad, t.touchPlayer = true, i
      t.mouseTank, t.padTank, t.controlIndex = false, false, nil
    else
      t.touchPad, t.touchPlayer = false, nil
    end
    t.isPlayer = (sl.mouse == true) or (sl.pad == true) or (sl.scheme ~= nil)
    t.ai = sl.ai and true or nil
    t.aiName = sl.name
    -- 联机（P1）：非本机真人槽位 = 对手，标 remote ⇒ 不接受本地输入、只由快照插值驱动渲染。
    t.remote = (G.online and i ~= G.playerIndex and sl.ai ~= true) and true or nil
    -- 联机（用户 2026-10-15）：**本机玩家可用所有控制方式** ⇒ 不吃"某一套方案"的限制，
    --   改为「全控制方式并集」输入（见 tankFrame 的 anyCtrl 分支）。对手仍为 remote（只由快照驱动）。
    if G.online and i == G.playerIndex then
      t.anyCtrl = true
      t.mouseTank, t.padTank, t.controlIndex = false, false, nil
    else
      t.anyCtrl = nil
    end
    -- 颜色变了，重建车体 / 炮塔美术
    buildBaseArt(t)
    buildTurretArt(t)
  end
  -- 触屏分区（按模式重建）+ 复位摇杆 / 开火 / 触点
  G.tzone = G.touchMode and buildTouchZones(mode) or {}
  -- 本局是否有 AI（与莱卡对战时原版强制只出激光，见 rulesWeaponList）
  G.hasAI = false
  for i = 1, #slots do if slots[i].ai then G.hasAI = true end end
  for p = 1, 2 do
    G.tstick[p].active, G.tstick[p].id = false, nil
  end
  G.tfire[1], G.tfire[2] = false, false
  G.touches = {}
  layoutScoreHUD()
end

-- 进入准备页（原版 controlsNPlayer）。快照各玩家开火状态，避免「按着开火键进页」被判定为已加入。
local function beginReady(mode)
  MENU.mode = mode
  MENU.phase = "ready"
  MENU.joined, MENU.joinPrev = {}, {}
  local slots = buildSlots(mode)
  for n = 1, #slots do
    local sl = slots[n]
    MENU.joined[n] = (sl.ai == true)
    -- 按槽位 n 记录加入键边沿（鼠标 / 手柄 / 键盘方案各自不同）
    if sl.mouse == true then
      MENU.joinPrev[n] = G.pmouse.fire
    elseif sl.pad == true then
      MENU.joinPrev[n] = G.gp.fire
    elseif sl.scheme ~= nil then
      local pin = G.pinputs[sl.scheme]
      MENU.joinPrev[n] = (pin ~= nil and pin.fire) or false
    end
  end
  MENU.prev.fire = G.input.fire or G.gp.fire
  MENU.touchPrev = true   -- 触屏：刚进准备页时若手指还按着（上一步点击），不算一次「点面板加入」
  MENU.readyTimer = G.online and 30 or 0   -- 联机：30 秒准备倒计时（本地模式不使用）
  MENU.startTimer = 0                       -- 联机：30 秒后的「3 秒开始」倒计时
  if not G.online then
    MENU.colorPick, MENU.colorLocked = nil, nil
  end
  -- 联机准备界面（v5）：清空准备档同步状态，并把本端**初始**准备档传上去
  --   （让对面一进准备页就能把这块框画成正确样式；此时还没准备，ready = 0）
  if G.online then
    G.readySeen = {}
    G.readyDirty = true
    G.readyPrevFire = true          -- 吃掉「按着开火键进页」那一下，避免进页即准备
    G.startWait = 0
    MENU.readyEndBeat = nil         -- 房主会在读到心跳后定「强制准备时刻」（两端倒计时由此同步）
    MENU.started = false
    MENU.fallbackWarned = false
    MENU.colorLocked = nil
    MENU.uploadReady()
    print("[坦克动荡] 联机准备页：我=" .. tostring(G.playerIndex)
      .. "，图示=" .. tostring(MENU.ctrlKind()))
  end
  updateReadyRows()
  refreshMenu()
end

-- 联机判定：由服务器节点图把「在场玩家数」写入**关卡自定义变量** TT2_PLAYERS；
--   客户端读 ≥2 ⇒ G.online = true ⇒ 进游戏直接进准备界面、启用颜色选择 / 30 秒倒计时 / 3 秒开始、
--   禁用空格暂停与右下角菜单按钮（见 DEV_STATE §6.35 与「联机节点图接线清单.md」）。
--   · **快速预览**（无需节点图）：在编辑器把 TT2_PLAYERS 初始值设为 2，即可本地预览联机界面。
--   · 真实测试：节点图在玩家进入/离开时用「获取在场玩家实体列表」+「列表迭代循环」计数后「设置自定义变量」。
--   注意：本段必须在 `beginReady` 之后（下面会调用它）。
MENU.onlinePlayers = 0
MENU.syncOnline = function(enter)
  local n = 0
  pcall(function()
    n = tonumber(game.GetGlobalCustomVariableValue(
      Enum.CustomVariableEntityType.Level, "TT2_PLAYERS")) or 0
  end)
  MENU.onlinePlayers = n
  if n >= 2 then
    local wasOff = not G.online
    G.online = true
    if wasOff then
      MENU.loadMySlot()            -- P1：确定自己的槽位
      useNewMouseControl = true    -- 联机固定「限速转向」（用户 2026-10-12；该行在联机按键设置页隐藏）
    end
    if enter and wasOff and MENU.phase == "menu" then
      print("[坦克动荡] 联机模式：在场玩家 " .. tostring(n) .. " ⇒ 进入准备界面")
      beginReady("duo")
    end
  end
  -- 联机「中途离开 = 逃跑」检测（用户 2026-10-15 定、2026-10-16 修订：离开者判「逃跑」、留下方「胜利」）：
  --   官方**没有「玩家离开」事件节点**，只能靠「在场人数」推断 ⇒ 三个条件同时满足才判：
  --   ① 已开赛（playing）② 本局尚未结束 ③ 人数**正好掉到 1**（n ≤ 0 视为「变量读不到」，不判，避免误判）。
  --   离开者自己不会走到这里（他已退出关卡）；他进局时预置的「逃跑合法性 = 否」会让平台判他「逃跑」。
  if G.online and n == 1 and MENU.phase == "playing"
     and G.match ~= nil and not G.match.over then
    print("[坦克动荡] 联机：在场玩家掉到 1 ⇒ 对方逃跑，判本机胜利（他按预置的「逃跑合法性=否」判逃跑）")
    MENU.finishMatch(G.playerIndex)
  end
  return n
end

-- 注册「TT2_PLAYERS 变化」监听（服务器更新在场人数时随时切联机），并先同步一次。
MENU.setupOnlineDetection = function()
  MENU.syncOnline(false)
  MENU.loadMazeData()
  pcall(function()
    script:RegisterCustomVariableChangedHandler(
      Enum.CustomVariableEntityType.Level, "TT2_PLAYERS",
      function() MENU.syncOnline(true) end)
  end)
  pcall(function()
    script:RegisterCustomVariableChangedHandler(
      Enum.CustomVariableEntityType.Level, "TT2_MAZE",
      function() MENU.loadMazeData() end)
  end)
end

-- 联机「v4 房主权威」：**房主**（槽位 1）是这一局的唯一事实源 —— 摇迷宫表、决定补给箱、判定胜负；
--   服务器只把它的上行原样写进关卡变量，其他玩家读变量跟随。
-- ⚠️ 房主判定必须**等服务器下发过槽位**（`G.slotKnown`）：`G.playerIndex` 的默认值就是 1，
--   若不等槽位，两端会双双自认房主（都去摇表）。
MENU.isMazeHost = function()
  return G.online and G.slotKnown == true and G.playerIndex == 1
end

-- 非房主：只**记录**最新迷宫表与它的 seq；真正的「重开一回合」由 stepFrame 按 seq 变化驱动
--   （房主是回合的唯一驱动者 ⇒ 回合边界与「用哪张图」锚在同一个源上，不会错配）。
MENU.setMazeData = function(list)
  if type(list) ~= "table" or #list < onlineApi.MAZE_HEAD then return false end
  if MENU.isMazeHost() then return false end          -- 房主自己就是源头，忽略回写值
  G.mazeInts = list
  G.mazeSeqSeen = onlineApi.mazeSeq(list)
  print("[坦克动荡] 收到房主的迷宫表：seq=" .. tostring(G.mazeSeqSeen)
        .. " W=" .. tostring(list[2]) .. " H=" .. tostring(list[3]))
  return true
end

MENU.clearMazeData = function() G.mazeInts = nil end

-- 读关卡自定义变量 TT2_MAZE 并应用（在 OnStart 与「变量变化」回调里调用）。
MENU.loadMazeData = function()
  local v = nil
  pcall(function()
    v = game.GetGlobalCustomVariableValue(Enum.CustomVariableEntityType.Level, "TT2_MAZE")
  end)
  if type(v) == "table" then MENU.setMazeData(v) end
  return v
end

-- 实时延迟（ms）：发带时间戳的 TT2_PING → 服务器原样回发 → 本端算往返。
--   ⚠️ 需要编辑器侧节点图把 TT2_PING 参数**原样回发**（见「联机节点图接线清单.md」）；
--      未接之前计分板显示 "--"。时间戳用 audioClock（OnLevelUpdate 累加的秒表），不依赖平台时钟 API。
MENU.pingSend = function()
  if not G.online then return end
  G.pingAt = audioClock
  netApi.reportPing(audioClock)
end

MENU.onPong = function(t)
  local sent = tonumber(t)
  if sent == nil then return end
  -- 服务器侧是「广播回发」：两端都会收到**对方**的 echo（对方的时间戳）。
  --   只认**自己刚发出去的**那个时间戳，否则会拿好友的 echo 去算延迟、数值乱跳。
  --   容差 0.01s：远小于两端秒表的起始差（秒级），又能容忍浮点参数往返的精度损失。
  if G.pingAt ~= nil and math.abs(sent - G.pingAt) > 0.01 then return end
  G.pingMs = max(0, (audioClock - sent) * 1000)
  updateScoreHUD()
  if MENU.phase == "ready" then updateReadyRows() end
end

-- ============================================================
-- 联机：P1 房间/玩家模型、P3 事件、P4 重连
-- ============================================================
-- P1：读**本玩家自身**的局内变量 TT2_SLOT（服务器按玩家各写一份）⇒ 确定自己与对手的槽位。
--   ⚠️ 客户端 Lua 无法查询「我是几号玩家」，必须由服务器下发（见接线清单 §2.8）。
--   ⚠️ 但「玩家实体上的自定义变量」需要启用**局内存档**才会生成（官方《局内存档》§2）——
--     当前关卡没有该功能，所以**主路径是下面的 MENU.onSlot（信号下发）**，本函数只作兜底。
MENU.loadMySlot = function()
  local v = nil
  pcall(function()
    v = game.GetGlobalCustomVariableValue(Enum.CustomVariableEntityType.PlayerSelf, "TT2_SLOT")
  end)
  local slot = tonumber(v)
  if slot == nil then return false end
  G.playerIndex = slot
  print("[坦克动荡] 联机：本机槽位=" .. tostring(slot))
  return true
end

-- P1（**主路径**）：服务器在遍历在场玩家时，用【发送客户端脚本信号】把 `TT2_SLOT`（参数 = 玩家序号）
--   **逐个定向**发给每个玩家 ⇒ 本端据此确定「我是几号」。
--   为什么不用「玩家自身的自定义变量」：玩家实体上的自定义变量要启用「局内存档」才会生成
--   （官方《局内存档》§2：「模板中每个局内存档结构体都会在每个玩家实体上生成一个同名的自定义变量」），
--   当前关卡没有该功能 ⇒ 改用信号定向下发（见接线清单 §2.8）。
MENU.onSlot = function(n)
  local slot = tonumber(n)
  if slot == nil or slot < 1 then return end
  G.slotKnown = true
  if G.playerIndex == slot then return end          -- 同一槽位重复下发 → 忽略（也防 HELLO 回环）
  G.playerIndex = slot
  print("[坦克动荡] 联机：服务器告知本机槽位=" .. tostring(slot))
  if G.online and G.room ~= nil and MENU.phase ~= "playing" then
    MENU.setupRoom()                                -- 槽位变了 ⇒ 重建房间（对手槽位/HUD 随之刷新）
  end
end

-- P1：建立本局「房间」结构（我的槽位 / 对手槽位 / 插值缓冲 / 上行节拍），并请求一次全量（P4 重连）。
MENU.setupRoom = function()
  if not G.online then G.room, G.snapBuf = nil, nil; return end
  local opps = {}
  for i = 1, #G.tanks do
    local t = G.tanks[i]
    if i ~= G.playerIndex and t ~= nil and t.ai == nil then opps[#opps + 1] = i end
  end
  G.room = { mySlot = G.playerIndex, oppSlots = opps, delay = 0.15 }
  G.snapBuf = onlineApi.newBuffer()
  G.snapStep = 0
  netApi.reportHello()   -- P4：进场/重连 → 请服务器下发全量（快照变量 + 迷宫表）
  print("[坦克动荡] 联机对局：我=" .. tostring(G.playerIndex) .. "，对手数=" .. tostring(#opps))
end

-- ============================================================
-- 联机准备界面（v5，用户 2026-10-15 定稿）
--   规则：① 本端**只能给自己**的槽位准备（谁按自己的开火键，谁的框亮）；
--         ② 本机玩家可用**所有**控制方式 ⇒ 开火取并集；
--         ③ 准备框图示跟随**各自设备**的第一种控制方式，键盘图示的键名跟随**各自按键设置**；
--         ④ 颜色：只有「对方**已准备**」的颜色算被占用；准备后不可改色；
--         ⑤ 30 秒到点强制准备（未选色 ⇒ 随机，且避开已占用色）⇒ 房主确认两端齐后**统一发布开始** ⇒ 3 秒倒计时。
--   同步通道（编辑器侧必须建，见《联机节点图接线清单.md》§C9）：
--     信号 TT2_READY_1 / TT2_READY_2（整数列表）⇒ 关卡变量 TT2_READY_1 / TT2_READY_2（整数列表）
--   表结构 = [ready, colorIdx, ctrlKind, started]（见 src/online.lua §⑥）
-- ============================================================

-- 对端槽位：联机目前只有双人 ⇒ 1⇄2（**不能**读 G.room：准备阶段还没建房间）
MENU.oppSlot = function() return (G.playerIndex == 1) and 2 or 1 end

-- 本机设备 → 准备框图示种类（跟随设备=该设备的第一种控制方式）
MENU.ctrlKind = function()
  local dev = ""
  pcall(function() dev = tostring(game.GetDevice()) end)
  if dev == "Mobile" then return onlineApi.CTRL_TOUCH end
  if dev == "MobileController" or dev == "Controller" then return onlineApi.CTRL_PAD end
  return onlineApi.CTRL_KB
end

-- 本端「开火」是否按下（联机 = 本机玩家可用**所有**控制方式 ⇒ 取并集；鼠标只并开火，不做光标转向）
MENU.localFireDown = function()
  local a, b, gp = G.pinputs[1], G.pinputs[2], G.gp
  return (a ~= nil and a.fire == true) or (b ~= nil and b.fire == true)
    or gp.fire == true or G.pmouse.fire == true
end

-- 本端准备档（wire 格式）
--   第 4 位 = **房主**发布的「强制准备时刻」（= 届时 TT2_BEAT 的值）；非房主恒写 0。
MENU.readyPayload = function()
  return onlineApi.encodeReady(
    MENU.joined[G.playerIndex] == true,
    MENU.colorPick or 0,
    MENU.ctrlKind(),
    MENU.isMazeHost() and (MENU.readyEndBeat or 0) or 0)
end

-- 上传本端准备档（联机）
MENU.uploadReady = function()
  if not G.online then return end
  netApi.reportReady(G.playerIndex, MENU.readyPayload())
  G.readyDirty = false
end

-- 读两端准备档（关卡变量）→ G.readySeen；顺带读**服务器心跳** `TT2_BEAT`（准备阶段的共享时钟）
MENU.readReady = function()
  local function readOne(slot)
    if slot == nil then return end
    local v = nil
    pcall(function()
      v = game.GetGlobalCustomVariableValue(Enum.CustomVariableEntityType.Level, onlineApi.readyVar(slot))
    end)
    local d = onlineApi.decodeReady(v)
    if d ~= nil then G.readySeen[slot] = d end
  end
  readOne(G.playerIndex)
  readOne(MENU.oppSlot())
  pcall(function()
    local b = tonumber(game.GetGlobalCustomVariableValue(
      Enum.CustomVariableEntityType.Level, "TT2_BEAT"))
    if b ~= nil and b > 0 then G.beatSeen = b end
  end)
end

-- 把读到的准备档反映到界面状态（对方是否已准备 / 对方占用色）
MENU.applyReadySeen = function()
  local me = G.playerIndex
  local d = G.readySeen[MENU.oppSlot()]
  if d ~= nil and d.ready then
    MENU.joined[MENU.oppSlot()] = true
    if d.color >= 1 then MENU.colorLocked = d.color end
  end
  local mine = G.readySeen[me]
  if mine ~= nil and mine.ready then MENU.joined[me] = true end
end

-- 对方**已准备**占用的颜色（未准备时不算占用 —— 用户 2026-10-15）
MENU.occupiedColor = function()
  local d = G.readySeen[MENU.oppSlot()]
  if d ~= nil and d.ready and d.color >= 1 then return d.color end
  return nil
end

-- 联机：本端**已准备** ⇒ 「按键设置」锁定（用户 2026-10-15：准备后不可再改键；入口**灰掉**而非隐藏）
MENU.keysLocked = function()
  return G.online == true and MENU.joined[G.playerIndex] == true
end

-- 本端按开火键确认准备：颜色仲裁（未选 / 已被占用 ⇒ 换一个可用色）后置 ready 并上传
MENU.tryReadySelf = function()
  if not G.online then return end
  local me = G.playerIndex
  if MENU.joined[me] == true then return end
  local occ = MENU.occupiedColor()
  local c = MENU.colorPick
  if c == nil or c == occ then
    local pool = {}
    for i = 1, #MENU.PICK_COLORS do if i ~= occ then pool[#pool + 1] = i end end
    if #pool == 0 then pool = { 1 } end
    c = pool[math.random(1, #pool)]
    MENU.colorPick = c
  end
  MENU.joined[me] = true
  G.readyDirty = true
  playSound("soundClick")
  updateReadyRows()
end

-- 房主：定下「强制准备时刻」= 现在 + 30 个心跳（必须已读到心跳值才定）
MENU.hostFixDeadline = function()
  if not G.online or not MENU.isMazeHost() then return end
  if (MENU.readyEndBeat or 0) > 0 then return end
  if G.beatSeen <= 0 then return end                 -- 心跳还没读到 ⇒ 下一帧再定
  MENU.readyEndBeat = G.beatSeen + 30
  G.readyDirty = true
  print("[坦克动荡] 联机：房主定下强制准备时刻 beat=" .. tostring(MENU.readyEndBeat)
    .. "（现为 " .. tostring(G.beatSeen) .. "）")
end

-- 房主：双方都准备齐 ⇒ **把截止刻拉到现在**（= 立即强制准备 + 进 3 秒开始倒计时，两端同步）
MENU.hostMaybeStart = function()
  if not G.online or not MENU.isMazeHost() then return end
  local eb = MENU.readyEndBeat or 0
  if eb <= 0 or eb <= G.beatSeen then return end      -- 还没定好 / 已经到点
  if MENU.joined[G.playerIndex] == true and MENU.joined[MENU.oppSlot()] == true then
    MENU.readyEndBeat = G.beatSeen
    G.readyDirty = true
    print("[坦克动荡] 联机：双方已准备 ⇒ 提前进入 3 秒开始倒计时")
  end
end

-- 联机准备页每帧：读准备档与心跳 → 用**共享时钟**算倒计时 → 到点**所有人**强制准备 → 3 秒 → 开赛
--   ① **同步路径**（拿到房主的截止刻 + 心跳）：`剩余 = endBeat − TT2_BEAT`
--      ⇒ 两端逐秒一致、到点落在同一个心跳刻 ⇒ 同时强制准备、同时起 3 秒（用户 2026-10-15 的要求）。
--   ② **回退路径**（心跳读不到 / 房主的档还没到）：本地 30 秒（两端可能差 ~1 秒）⇒ 打一条告警日志。
MENU.tickReady = function(dt)
  if not G.online then return end
  MENU.readReady()
  MENU.applyReadySeen()
  MENU.hostFixDeadline()
  MENU.hostMaybeStart()

  local me, opp = G.playerIndex, MENU.oppSlot()
  local eb
  if MENU.isMazeHost() then eb = MENU.readyEndBeat or 0
  else
    local d1 = G.readySeen[1]
    eb = (d1 ~= nil and d1.endBeat) or 0
  end

  local go = false
  if eb > 0 and G.beatSeen > 0 then
    -- ① 同步路径
    G.startWait = 0
    local left = eb - G.beatSeen
    if left > 0 then
      MENU.readyTimer = left                 -- 准备阶段：两端同值（30 → 1）
      MENU.startTimer = 0
      MENU.started = false
    else
      MENU.readyTimer = 0
      if MENU.joined[me] ~= true then MENU.forceReady() end   -- 到点：**所有人**强制准备（各端强制自己）
      MENU.startTimer = eb + 3 - G.beatSeen                   -- 3 秒开始倒计时（两端同值；≤0 ⇒ 开赛）
      if MENU.startTimer <= 0 then MENU.startTimer = 0; go = true end
      if not MENU.started then
        MENU.started = true
        print("[坦克动荡] 联机：准备时间到 ⇒ 立即进入 3 秒开始倒计时")
      end
    end
  else
    -- ② 回退路径（正常双端不会走到；用于心跳缺失 / 通道未通的兜底）
    G.startWait = G.startWait + (tonumber(dt) or 0)
    if G.startWait >= 3 and not MENU.fallbackWarned then
      MENU.fallbackWarned = true
      print("[坦克动荡] 联机：⚠️ 拿不到同步时钟（TT2_BEAT / 房主准备档）⇒ 回退本地 30 秒倒计时（两端可能差约 1 秒）")
    end
    if MENU.readyTimer > 0 then
      MENU.readyTimer = MENU.readyTimer - (tonumber(dt) or 0)
      if MENU.readyTimer <= 0 then
        MENU.readyTimer = 0
        MENU.forceReady()
      end
    end
    if not MENU.started and MENU.readyTimer <= 0
      and MENU.joined[me] == true and MENU.joined[opp] == true then
      MENU.started = true
      MENU.startTimer = 3
    end
    if MENU.started then
      MENU.startTimer = max(0, MENU.startTimer - (tonumber(dt) or 0))
      if MENU.startTimer <= 0 then go = true end
    end
  end

  if go then MENU.beginMatch(); return end
  if G.readyDirty then MENU.uploadReady() end
end

-- P3：上报一个离散事件（整数列表）
MENU.sendEvent = function(kind, slot, a, b, c)
  if not G.online then return end
  netApi.reportEvent(onlineApi.encodeEvent(kind, slot, a, b, c))
end

-- P3：收到服务器转发的事件。命中采用「命中方先声明 + 受害者权威」：被声明命中者自己判死。
MENU.onEvent = function(list)
  local e = onlineApi.decodeEvent(list)
  if e == nil or G.room == nil then return end
  if e.slot == G.playerIndex then return end   -- 自己发的事件（可能被广播回来）忽略
  local me = G.playerIndex
  local E = onlineApi.EV
  if e.kind == E.HIT then
    if e.a == me then                          -- 我被 slot 命中 ⇒ 受害者权威：我判死
      local mine = G.tanks[me]
      if mine ~= nil and mine.alive then killTank(mine, G.tanks[e.slot]) end
    end
  elseif e.kind == E.DIED then
    local t = G.tanks[e.slot]
    if t ~= nil and t.alive then killTank(t, nil) end
  elseif e.kind == E.PICK then
    -- 对方拾取了补给箱：给对方那辆坦克换武器（外观同步）
    --   payload = [PICK, slot, crateId, weaponId]
    local t = G.tanks[e.slot]
    if t ~= nil then setWeapon(t, onlineApi.weaponName(e.b)) end
    -- 房主：从**权威补给箱表**里删掉这个箱子（按 crateId）并标记待上传 ⇒ 两端一起消失
    if MENU.isMazeHost() and (e.a or 0) ~= 0 then
      for i = #G.crates, 1, -1 do
        if G.crates[i].id == e.a then
          local c = G.crates[i]
          if c.cell ~= nil then c.cell.used = false end
          vfree(c.vis)
          table.remove(G.crates, i)
          G.crateDirty = true
          break
        end
      end
    end
  elseif e.kind == E.FIRE then
    -- 镜像对手开火（只为可视化：以对手坦克为 owner 生成同款投射物）
    local t = G.tanks[e.slot]
    if t ~= nil and t.alive then
      pcall(function()
        t.rot = e.a / 10
        local keep = t.currentWeapon
        t.currentWeapon = onlineApi.weaponName(e.b)
        local plist = weaponsApi.fire(t, t.currentWeapon, ctx)
        t.currentWeapon = keep
        for i = 1, #plist do
          local p = plist[i]
          if p ~= nil then G.projectiles[#G.projectiles + 1] = p; buildProjVisual(p) end
        end
      end)
    end
  end
end

-- 全部玩家已加入 → 应用模式并开始首回合（原版准备页加入齐直接 play()，无倒计时）
local function beginMatch()
  applyMode(MENU.mode)
  -- 新对局 → 记分榜清零。坦克对象**跨对局复用**（applyMode 只在人数变化时增删坦克），
  --   不清零会把上一局的分数带进新对局（用户 2026-10-14 报：对战中途回主界面再开一局，记分榜没归零）。
  for i = 1, #G.tanks do G.tanks[i].score = 0 end
  -- 联机「v4」：新对局 ⇒ 补给箱编号 / 上传标记 / 已读到的胜者 一起归零
  G.crateSeq = 0
  G.crateDirty = true
  G.winnerSeen = 0
  if G.online then MENU.setupRoom() end   -- P1：建立房间结构（槽位 / 缓冲）+ P4：请求全量
  G.accum = 0
  -- 对局状态复位（见 CFG.MATCH_* / MENU.finishMatch）：
  --   联机 = 10 分钟倒计时 + 胜负判定；单机 = **无胜利条件**，只记「已完成关卡」标志。
  if G.online then
    G.match = { timer = CFG.MATCH_SECONDS, over = false, winner = nil, overtime = false,
                tick = 0, completed = false, settleIn = nil }   -- settleIn：分出胜负后倒数 40 帧再发 TT2_SETTLE
    if hud.timerLabel ~= nil then pcall(function() hud.timerLabel.text = "时间 10:00" end) end
  else
    G.match = { over = false, completed = false, tick = 0 }
  end
  if hud.resultLabel ~= nil then pcall(function() hud.resultLabel.text = "" end) end
  -- 进入对局前清空所有开火状态：开火键同时是「加入/确认」键，
  -- 若不清除，首帧会立刻开炮。记录为「按下」使对局中必须重新抬手再按。
  G.input.fire = false
  for i = 1, #G.pinputs do G.pinputs[i].fire = false end
  G.pmouse.fire = false
  G.gpKey.fire = false
  G.gp.fire = false
  MENU.prev.fire = true
  MENU.phase = "playing"
  audioApi.setBgm("battle")
  -- 结算状态预置（用户 2026-10-15 定、2026-10-16 修订；官方《关卡结算》二：状态可在游玩中动态改、结算取当时值）：
  --   · **单机**：任意玩一局，无论模式 / 无论输赢，退出都算「已完成」⇒ 预置「**胜利**」（合法性=是）；
  --   · **联机**：**中途离开算「逃跑」**、留下方「胜利」；正常打完则按比赛规则判胜负
  --     ⇒ 进局只预置「**逃跑合法性 = 否**」（谁走谁判逃跑），等分出胜负时**各端各自**报最终状态
  --       （SET_WIN / SET_LOSE 两条链会把合法性改回「是」并给出胜负，见 MENU.finishMatch）。
  -- ⚠️ 这里只"改状态"、**不结束游戏**；联机「分出胜负立刻结算」是 finishMatch + settleIn 的事。
  if G.online then
    -- 联机：**把本机玩家的「逃跑合法性」设为「否」** ⇒ 中途离开即被平台判「逃跑」（用户 2026-10-16 规则）；
    --   正常打完由 finishMatch 走 SET_WIN / SET_LOSE（那两条链含「逃跑合法性 = 是」+ 胜负）。
    local ok = netApi.reportSetEscape(G.playerIndex)
    print("[坦克动荡] 已上报 TT2_SET_ESCAPE（" .. (ok and "已发出" or "**未发出**")
      .. "，玩家序号=" .. tostring(G.playerIndex) .. "）：本机玩家预置为「逃跑合法性=否」（联机；中途离开即判逃跑）")
  else
    local ok = netApi.reportSetWin(G.playerIndex)
    print("[坦克动荡] 已上报 TT2_SET_WIN（" .. (ok and "已发出" or "**未发出**")
      .. "，玩家序号=" .. tostring(G.playerIndex) .. "）：本机玩家预置为「胜利」（单机；中途退出也算已完成）")
  end
  -- 联机「v4」：房主立刻开第 1 回合（摇表并上传）；非房主**先等房主那张表**
  --   （stepFrame 里按 seq 变化触发 startNewRound），避免两端开局各摇一张不同的图。
  -- ⚠️ `seq` / `roundId` **跨对局保持单调递增、不归零**：否则新对局开始时，关卡变量里残留的
  --   「上一局的表」会被非房主误当成新表消费掉（seen == used 才能挡住它）。
  if G.online then
    G.awaitFrames = 0
    if MENU.isMazeHost() then
      startNewRound()
    else
      G.awaitRound = true
      print("[坦克动荡] 联机：非房主开局，等房主的新迷宫表")
    end
  else
    startNewRound()
  end
  refreshMenu()
end

-- `beginMatch` 是**后置声明**的 local（6275 行），而 `MENU.tickReady`（6212 行）在它**之前**定义 ⇒
--   直接写 `beginMatch()` 会被编译成全局名 ⇒ 真机运行时 `attempt to call a nil value (global 'beginMatch')`。
--   这里挂到 MENU 上（本仓库惯用法，且**不增**主 chunk 顶层 local 计数）。
MENU.beginMatch = beginMatch

-- 进入按键设置页（原版无此页；千星奇域键位可自定义，故新增）。
-- 入口有二：设置面板「按键设置」行、准备页下方「按键设置」按钮 ⇒ 用 returnPhase 记住来源。
local function beginKeys()
  if MENU.keysLocked() then return end   -- 联机本端已准备 ⇒ 锁定改键（用户 2026-10-15）
  MENU.returnPhase = MENU.phase
  MENU.phase = "keys"
  MENU.keySel = 1
  MENU.keyConflict = nil
  CAPTURE.active, CAPTURE.scheme, CAPTURE.action = false, nil, nil
  -- 方案 2 的移动键恒为 ↑↓←→（由 DEFAULT_BINDS 保证、页面上不可改）⇒ 进入时无需强制重置
  refreshMenu()
end

-- 进入对战设置页（原版 settingsPanel 的 Weapons / Controls 段）。
-- 挂 MENU 上以避免再增主 chunk 顶层 local（真机 Lua 5.3 上限 200）。
MENU.beginRules = function()
  MENU.returnPhase = MENU.phase
  MENU.phase = "rules"
  MENU.rulesSel = 1
  refreshMenu()
end

-- 进入其他设置页（不影响游戏规则）：显示大小 / 抗锯齿 / 音乐 / 音效。
MENU.beginOther = function()
  MENU.returnPhase = MENU.phase
  MENU.phase = "other"
  MENU.otherSel = 1
  refreshMenu()
end

-- 进入控制方式页（齿轮设置面板的子页）：把当前选择拷进草稿，编辑期间不直接影响对局配置，
-- 只有「保存设置」校验通过（3 位玩家控制方式互不相同）才写回 PLAYER_MODES。
local function beginDevices()
  MENU.phase = "devices"
  MENU.devSel = 1
  MENU.devOk = nil
  for i = 1, #PLAYER_MODES do MENU.devDraft[i] = PLAYER_MODES[i] end
  refreshMenu()
end

-- 切换全局静音（设置面板 → 其他设置「音效」行）。开关状态与 audioApi 音效静音相反。
-- 记为 MENU 字段（而非文件级 local）以控制主 chunk 的「200 个 local」上限。
MENU.toggleSound = function()
  MENU.soundOn = not MENU.soundOn
  audioApi.setSfxMuted(not MENU.soundOn)
  if MENU.phase == "menu" then refreshMenu() else MENU.refreshCfg() end
end

-- 音乐开关（设置面板 → 其他设置「音乐」行）：与 audioApi 的 BGM 静音相反。
MENU.toggleMusic = function()
  MENU.musicOn = not MENU.musicOn
  audioApi.setBgmMuted(not MENU.musicOn)
  MENU.refreshCfg()
end

-- 主菜单条目激活：1..4 = 4 个模式 → 准备页；5 = 齿轮 → 设置面板。
MENU.activateMenuEntry = function(idx)
  if idx == 3 and G.touchMode then return end   -- 触屏端不支持三人对战
  playSound("soundClick")                        -- 原版：菜单操作点击音效
  if idx == 1 then beginReady("solo")
  elseif idx == 2 then beginReady("duo")
  elseif idx == 3 then beginReady("trio")
  elseif idx == 4 then beginReady("duoAI")
  elseif idx == 5 then MENU.phase = "settings"; MENU.setSel = 1; refreshMenu() end
end

-- 主菜单横幅逐帧动画（照搬原版 frame_1 PlaceObject2_*/onClipEvent(enterFrame) 公式与常量）：
--   待机 bob：X += sin(t·0.77)·2.5 / Y += cos(t·0.37)·2.5 / rot += sin(t·0.47)·2.5 / scale += cos(t·0.27)·2.5%
--   选中放大：scale 目标 = 100% + 30%（原版鼠标悬停；此处键盘 / 手柄 / 触屏选中同样放大以便反馈）
--   缓动：位置 / 旋转 += (target-·)·0.7，缩放 += (target-·)·0.9
-- 幅度换算：原版 scale 为百分数（80/110），本移植以 1.0 为基准，故 2.5% → 0.025、+30% → +0.3。
MENU.stepMenuAnim = function(dt)
  if MENU.phase ~= "menu" then return end
  MENU.animTime = MENU.animTime + dt * MENU.ANIM_RATE
  for i = 1, #MENU.banners do
    local b = MENU.banners[i]
    local slot = MENU.BANNER_SLOTS[i]
    b.animTime = b.animTime + dt * MENU.ANIM_RATE
    local hovered = (MENU.sel == i)
    b.hover = hovered
    local tx, ty, trot, tsc
    if hovered then
      tx, ty, trot, tsc = slot.x, slot.y, 0, 1.30
    else
      tx   = slot.x + sin(b.animTime * 0.77) * MENU.BOB_AMP
      ty   = slot.y + cos(b.animTime * 0.37) * MENU.BOB_AMP
      trot = sin(b.animTime * 0.47) * 2.5
      tsc  = 1.0 + cos(b.animTime * 0.27) * 0.025
    end
    b.x     = b.x     + (tx   - b.x)     * 0.7
    b.y     = b.y     + (ty   - b.y)     * 0.7
    b.rot   = b.rot   + (trot - b.rot)   * 0.7
    b.scale = b.scale + (tsc  - b.scale) * 0.9
    MENU.placeBanner(b, b.x, b.y, b.rot, b.scale)
  end
  MENU.placeDesc()
end

local function stepMenuInput()
  local i, pv, gp = G.input, MENU.prev, G.gp
  -- 键鼠与手柄同时支持：两路输入各取「或」，再做边沿检测
  -- （键鼠 W/S/A/D + 方向键；手柄左摇杆 + 十字键 + A）。
  local nUp    = i.fwd   or gp.fwd
  local nDown  = i.back  or gp.back
  local nLeft  = i.left  or gp.left
  local nRight = i.right or gp.right
  local nFire  = i.fire  or gp.fire
  local up      = nUp    and not pv.fwd
  local down    = nDown  and not pv.back
  local leftE   = nLeft  and not pv.left
  local rightE  = nRight and not pv.right
  local confirm = nFire  and not pv.fire
  pv.fwd, pv.back, pv.left, pv.right, pv.fire = nUp, nDown, nLeft, nRight, nFire

  -- 刚完成一次改键：本帧只同步边沿缓存就返回，避免「绑定用的那一下按键」被当成确认。
  if CAPTURE.justEnded then
    CAPTURE.justEnded = false
    return
  end

  local ph = MENU.phase
  -- 指针「按下」= 鼠标左键 或 触屏（移动端）；统一做边沿检测（供返回按钮 / 三角 / 菜单确认共用）
  local ptrFire = G.pmouse.fire or (G.touchMode and G.touch.down == true)
  local mouseEdge = ptrFire and not MENU.mousePrev
  MENU.mousePrev = ptrFire
  local cursorMoved = false   -- 本帧光标是否移动过（供子页「悬停选行」用）
  -- 「返回」按钮（设置 / 按键设置 / 控制方式 / 准备页 / 对战设置 / 其他设置）：
  --   鼠标悬停高亮、左键点击 = 返回（等价 R 键）。
  --   ⚠️ 必须**包含 rules / other**：否则这两个子页不刷新光标 ⇒ 用鼠标时沿用的是上一页的**陈旧坐标**
  --   （表现为「点哪个箭头都只会往一个方向走」）。
  if ph == "settings" or ph == "keys" or ph == "devices" or ph == "ready"
      or ph == "rules" or ph == "other" then
    MENU.readCursor()
    local onBack = false
    if MENU.cursor.ok then
      cursorMoved = (MENU.cursor.x ~= MENU.prevMX or MENU.cursor.y ~= MENU.prevMY)
      if cursorMoved then MENU.lastDev = "mouse" end
      MENU.prevMX, MENU.prevMY = MENU.cursor.x, MENU.cursor.y
      onBack = MENU.hitBack(MENU.cursor.x, MENU.cursor.y)
    end
    MENU.backHover = onBack
    MENU.placeBack()
    -- 点中返回按钮：立即返回并结束本帧处理——否则这一下左键会被下面的「确认」当成激活当前行。
    if mouseEdge and onBack then onMenuKey(); return end
  end
  if ph == "menu" then
    -- 鼠标（可选项）：**光标真的移动过**才把"选取权"交给鼠标——避免静止的光标抢走键盘 / 手柄的选中；
    -- 键盘 / 手柄一旦操作，lastDev 变 "kb"，鼠标不动就不再覆盖选中（"以最后操作的设备为准"）。
    MENU.readCursor()
    local hitIdx = nil
    if MENU.cursor.ok then
      hitIdx = MENU.hitMenuEntry(MENU.cursor.x, MENU.cursor.y)
      if MENU.cursor.x ~= MENU.prevMX or MENU.cursor.y ~= MENU.prevMY then
        MENU.lastDev = "mouse"
      end
      MENU.prevMX, MENU.prevMY = MENU.cursor.x, MENU.cursor.y
      if MENU.lastDev == "mouse" then
        if hitIdx ~= nil then
          if hitIdx ~= MENU.sel then MENU.sel = hitIdx; refreshMenu() end
        elseif MENU.sel ~= 0 then
          -- 鼠标离开所有条目 → 取消选中（sel=0），横幅恢复待机摇晃（不再放大 / 变绿）。
          MENU.sel = 0
          refreshMenu()
        end
      end
    end
    -- 方向键 / WASD(ESDF) / 手柄十字键：按条目**实际位置**做二维移动（左右上下各走该方向上最近的条目）。
    if up or down or leftE or rightE then MENU.lastDev = "kb" end
    if up     then MENU.moveSel(MENU.sel,  0,  1) end
    if down   then MENU.moveSel(MENU.sel,  0, -1) end
    if leftE  then MENU.moveSel(MENU.sel, -1,  0) end
    if rightE then MENU.moveSel(MENU.sel,  1,  0) end
    -- 确认分两路，避免「鼠标点空白」误触当前选中项：
    --   鼠标左键（KeyboardNormalAttackKey）→ 仅当命中条目时激活；
    --   键盘（Q / 空格）与手柄 A → 始终激活当前选中项。
    if mouseEdge then MENU.lastDev = "mouse" end
    local kbFire = ((i.fire and not G.pmouse.fire) or gp.fire)
    local kbEdge = kbFire and not pv.keyFire
    pv.keyFire = kbFire
    if kbEdge then MENU.lastDev = "kb" end
    if mouseEdge then
      if hitIdx ~= nil then MENU.activateMenuEntry(hitIdx) end
    elseif kbEdge then
      MENU.activateMenuEntry(MENU.sel)
    end
  elseif ph == "settings" then
    -- 设置面板：W/S 选行；「控制模式」（移动端）用 左/右 切换；其余行为子页入口，F / 点击进入。
    --   W/S 换行**跳过隐藏行**（联机隐藏「控制方式 / 控制模式 / 对战设置」；非战斗隐藏「回到主界面」）。
    if up or down then
      local dir = up and -1 or 1
      local n = #MENU.setRows
      local i = MENU.setSel
      for _ = 1, n do
        i = i + dir
        if i < 1 then i = n elseif i > n then i = 1 end
        if not MENU.rowHidden(MENU.setRows[i]) then MENU.setSel = i; break end
      end
      refreshSetRows()
    end
    -- 鼠标悬停选行：让高亮条跟随鼠标（此前只随键盘移动，鼠标移上去高亮不动 = bug）
    if cursorMoved then
      local hi = MENU.hoverRow(MENU.setRows, MENU.cursor.x, MENU.cursor.y, 26, 300)
      if hi ~= nil and not MENU.rowHidden(MENU.setRows[hi]) and hi ~= MENU.setSel then
        MENU.setSel = hi; refreshSetRows()
      end
    end
    local srow = MENU.setRows[MENU.setSel]
    -- 「控制模式」行：左/右（A/D、←/→、手柄左右）切换，或**点对应方向的 ◀ / ▶ 三角**切换。
    --   ⚠️ 点「◀」= 上一个、点「▶」= 下一个（不能只判「是否点了箭头」而无视方向）。
    if srow ~= nil and srow.kind == "touchMode" then
      local d = 0
      if leftE then d = -1 elseif rightE then d = 1 end
      if d == 0 and mouseEdge and MENU.cursor.ok then
        local cx, cy = MENU.cursor.x, MENU.cursor.y
        if MENU.hitArrow(MENU.SET_ARROW_L, srow.y, cx, cy) then d = -1
        elseif MENU.hitArrow(MENU.SET_ARROW_R, srow.y, cx, cy) then d = 1 end
      end
      if d ~= 0 then
        playSound("soundClick")
        G.touchHandfeel = (G.touchHandfeel == "aim") and "pad" or "aim"
        refreshSetRows()
        return
      end
    end
    -- 确认进入子页：键盘确认键（confirm）或**指针点中当前行**（ptrConfirm，供鼠标 / 触屏）。
    -- 关闭面板用底部「返回(R)」按钮。
    local ptrConfirm = mouseEdge and MENU.cursor.ok == true
      and MENU.hoverRow(MENU.setRows, MENU.cursor.x, MENU.cursor.y, 26, 300) == MENU.setSel
    if (confirm or ptrConfirm) and srow ~= nil then
      if srow.kind == "devices" then beginDevices()
      elseif srow.kind == "keys" then beginKeys()
      elseif srow.kind == "rules" then MENU.beginRules()
      elseif srow.kind == "other" then MENU.beginOther()
      elseif srow.kind == "quitToMenu" then MENU.quitToMenu() end
    end
  elseif ph == "rules" then
    -- 对战设置页：W/S 选行；开关行用 左/右 切换；「恢复默认」用 F / 点击。
    if up   then MENU.rulesSel = MENU.rulesSel - 1; if MENU.rulesSel < 1 then MENU.rulesSel = #MENU.rulesRows end; MENU.refreshRulesRows() end
    if down then MENU.rulesSel = MENU.rulesSel + 1; if MENU.rulesSel > #MENU.rulesRows then MENU.rulesSel = 1 end; MENU.refreshRulesRows() end
    if cursorMoved then
      local hi = MENU.hoverRow(MENU.rulesRows, MENU.cursor.x, MENU.cursor.y, 24, 300)
      if hi ~= nil and hi ~= MENU.rulesSel then MENU.rulesSel = hi; MENU.refreshRulesRows() end
    end
    local row = MENU.rulesRows[MENU.rulesSel]
    if row ~= nil then
      if row.kind == "weapon" or row.kind == "smooth" then
        local d = 0
        if leftE then d = -1 elseif rightE then d = 1 end
        if d == 0 and mouseEdge and MENU.cursor.ok then
          local cx, cy = MENU.cursor.x, MENU.cursor.y
          if MENU.hitArrow(MENU.SET_ARROW_L, row.y, cx, cy) then d = -1
          elseif MENU.hitArrow(MENU.SET_ARROW_R, row.y, cx, cy) then d = 1 end
        end
        if d ~= 0 then
          playSound("soundClick")
          if row.kind == "weapon" then
            G.rules.weapons[row.w] = not (G.rules.weapons[row.w] ~= false)
          else
            G.rules.smooth = not G.rules.smooth
          end
          MENU.refreshRulesRows()
        end
      else   -- 恢复默认
        local clickedRow = mouseEdge and MENU.cursor.ok
          and MENU.hitRow(row, MENU.cursor.x, MENU.cursor.y, 24, 300)
        if confirm or clickedRow then
          initRules()
          G.rules.smooth = C.SETTINGS.useSmoothCollision
          playSound("soundClick")
          MENU.refreshRulesRows()
        end
      end
    end
  elseif ph == "other" then
    -- 其他设置页：W/S 选行；全部行用 左/右 切换（显示大小 / 抗锯齿 / 音乐 / 音效）。
    if up   then MENU.otherSel = MENU.otherSel - 1; if MENU.otherSel < 1 then MENU.otherSel = #MENU.otherRows end; MENU.refreshOtherRows() end
    if down then MENU.otherSel = MENU.otherSel + 1; if MENU.otherSel > #MENU.otherRows then MENU.otherSel = 1 end; MENU.refreshOtherRows() end
    if cursorMoved then
      local hi = MENU.hoverRow(MENU.otherRows, MENU.cursor.x, MENU.cursor.y, 26, 300)
      if hi ~= nil and hi ~= MENU.otherSel then MENU.otherSel = hi; MENU.refreshOtherRows() end
    end
    local row = MENU.otherRows[MENU.otherSel]
    if row ~= nil then
      -- 左/右（A/D、←/→、手柄左右）= 减 / 增；**点 ◀ 减、点 ▶ 增**；点别处不动。
      local d = 0
      if leftE then d = -1 elseif rightE then d = 1 end
      if d == 0 and mouseEdge and MENU.cursor.ok then
        local cx, cy = MENU.cursor.x, MENU.cursor.y
        if MENU.hitArrow(MENU.SET_ARROW_L, row.y, cx, cy) then d = -1
        elseif MENU.hitArrow(MENU.SET_ARROW_R, row.y, cx, cy) then d = 1 end
      end
      if d ~= 0 then
        playSound("soundClick")
        if row.kind == "sound" then MENU.toggleSound()
        elseif row.kind == "music" then MENU.toggleMusic()
        elseif row.kind == "uiScale" then MENU.stepUiScale(d)
        else MENU.stepAA(d) end
        return
      end
    end
  elseif ph == "keys" then
    if CAPTURE.active then return end   -- 改键中：不接受导航，等待按键捕获
    -- 上下：跳过隐藏行
    if up then MENU.keyNav(-1) end
    if down then MENU.keyNav(1) end
    -- 鼠标悬停选行（跳过隐藏行）
    if cursorMoved then
      local hi = MENU.hoverKeyRow(MENU.cursor.x, MENU.cursor.y)
      if hi ~= nil and hi ~= MENU.keySel then MENU.keySel = hi; refreshKeyRows() end
    end
    local row = MENU.keyRows[MENU.keySel]
    if row ~= nil then
      if row.kind == "mouseBranch" then
        -- 左/右（A/D、←/→、手柄左右）或点 ◀▶ 三角：切换 瞬时转向/限速转向（点 ◀ 与 ▶ 方向相反）
        local d = 0
        if leftE then d = -1 elseif rightE then d = 1 end
        if d == 0 and mouseEdge and MENU.cursor.ok then
          local cx, cy = MENU.cursor.x, MENU.cursor.y
          if MENU.hitArrow(MENU.SET_ARROW_L, row.y, cx, cy) then d = -1
          elseif MENU.hitArrow(MENU.SET_ARROW_R, row.y, cx, cy) then d = 1 end
        end
        if d ~= 0 then
          useNewMouseControl = not useNewMouseControl
          refreshKeyRows()
        end
      else  -- 6 个动作行：F（或点该行）开始改键，再按任意可用键完成
        local clickedRow = mouseEdge and MENU.cursor.ok
          and MENU.hitRow(row, MENU.cursor.x, MENU.cursor.y, 16, 340)
        if confirm or clickedRow then
          CAPTURE.active, CAPTURE.scheme, CAPTURE.action = true, row.scheme, row.action
          refreshKeyRows()
        end
      end
    end
  elseif ph == "devices" then
    -- 上/下选行；玩家行用 左/右（A/D、←/→、手柄左右）循环 4 选 1，或点该行右侧 ◀ ▶ 三角。
    -- 「保存设置」校验 3 位玩家控制方式互不相同后写回；「恢复默认」还原默认组合。
    if up then MENU.devSel = MENU.devSel - 1; if MENU.devSel < 1 then MENU.devSel = #MENU.devRows end; refreshDevRows() end
    if down then MENU.devSel = MENU.devSel + 1; if MENU.devSel > #MENU.devRows then MENU.devSel = 1 end; refreshDevRows() end
    -- 鼠标悬停选行：高亮条跟随鼠标
    if cursorMoved then
      local hi = MENU.hoverRow(MENU.devRows, MENU.cursor.x, MENU.cursor.y, 21, 340)
      if hi ~= nil and hi ~= MENU.devSel then MENU.devSel = hi; refreshDevRows() end
    end
    -- 三角点击：点哪一行就选中哪一行，再按左/右切换（等价 A/D）
    if mouseEdge and MENU.cursor.ok then
      local cx, cy = MENU.cursor.x, MENU.cursor.y
      for i = 1, #MENU.devRows do
        local r = MENU.devRows[i]
        if r.kind == "player" then
          local d = nil
          if MENU.hitArrow(MENU.DEV_ARROW_L, r.y, cx, cy) then d = -1
          elseif MENU.hitArrow(MENU.DEV_ARROW_R, r.y, cx, cy) then d = 1 end
          if d ~= nil then
            MENU.devSel = i
            MENU.devDraft[r.n] = cycleMode(MENU.devDraft[r.n], d)
            MENU.devOk = nil
            refreshDevRows()
            return
          end
        end
      end
    end
    local row = MENU.devRows[MENU.devSel]
    if row ~= nil then
      if row.kind == "player" then
        local dir = 0
        if leftE then dir = -1 elseif rightE then dir = 1 end
        if dir ~= 0 then
          MENU.devDraft[row.n] = cycleMode(MENU.devDraft[row.n], dir)
          MENU.devOk = nil
          refreshDevRows()
        end
      elseif row.kind == "save" then
        if confirm then
          if modesDistinct(MENU.devDraft) then
            for p = 1, #PLAYER_MODES do PLAYER_MODES[p] = MENU.devDraft[p] end
            MENU.devOk = true
          else
            MENU.devOk = false
          end
          refreshDevRows()
        end
      else   -- 恢复默认
        if confirm then
          for p = 1, #DEFAULT_PLAYER_MODES do MENU.devDraft[p] = DEFAULT_PLAYER_MODES[p] end
          MENU.devOk = nil
          refreshDevRows()
        end
      end
    end
  elseif ph == "ready" then
    -- 每位玩家按自己的开火键加入（原版：P1 按 Q、P2 按 M）；AI 位视为已加入
    local slots = buildSlots(MENU.mode)
    -- 指针「按下」边沿（鼠标左键 / 触屏）——供下方两个按钮与「点面板加入」共用
    local tap = (G.touchMode and G.touch.down == true and not MENU.touchPrev)
    if G.touchMode then MENU.touchPrev = (G.touch.down == true) end
    -- 准备页下方两个按钮：按键设置 / 其他设置（**仅联机显示**，见 refreshMenu 的 showReadyBtns）
    if G.online and ((mouseEdge and MENU.cursor.ok) or (tap and G.touch.ok)) then
      local cx, cy
      if tap then cx, cy = G.touch.x, G.touch.y else cx, cy = MENU.cursor.x, MENU.cursor.y end
      for r = 1, #MENU.readyBtns do
        local b = MENU.readyBtns[r]
        if math.abs(cx - b.x) <= 90 and math.abs(cy - b.y) <= 20 then
          playSound("soundClick")
          -- 联机已准备 ⇒ 按键设置入口锁定（灰显 + 点不动）；其他设置不受影响
          if b.kind == "keys" then
            if MENU.keysLocked() then return end
            beginKeys()
          else MENU.beginOther() end
          return
        end
      end
      -- 联机准备页：点色块选颜色（对方已准备占用该色则不可选）
      if G.online then
        for i = 1, #MENU.colorSquares do
          local cs = MENU.colorSquares[i]
          if math.abs(cx - cs.x) <= 26 and math.abs(cy - cs.y) <= 26 then
            if i ~= MENU.colorLocked and MENU.joined[G.playerIndex] ~= true then
              MENU.colorPick = i
              playSound("soundClick")
              refreshMenu()
            end
            return
          end
        end
      end
    end
    -- 移动端：**点自己的面板**即加入（每位玩家点自己的区域）
    if G.touchMode and tap and G.touch.ok then
      for r = 1, #MENU.readyRows do
        local row = MENU.readyRows[r]
        if row.n ~= nil and MENU.joined[row.n] ~= true
           and math.abs(G.touch.x - row.cx) <= MENU.RDY_W / 2
           and math.abs(G.touch.y - row.cy) <= MENU.RDY_H / 2 then
          MENU.joined[row.n] = true
          playSound("soundClick")   -- 原版：准备页加入时播 soundClick
          updateReadyRows()
        end
      end
    end
    local allJoined = true
    if G.online then
      -- 联机：**本端只能给自己的槽位准备**（谁按自己的开火键，谁的框亮 ⇒ 不能替对方按）。
      --   本机玩家可用**所有**控制方式 ⇒ 开火检测取并集（键盘两套 + 手柄 + 鼠标左键）。
      --   对方的准备状态由「准备档变量」驱动，见 MENU.tickReady。
      local fireNow = MENU.localFireDown()
      if fireNow and not G.readyPrevFire then MENU.tryReadySelf() end
      G.readyPrevFire = fireNow
    else
      for n = 1, #slots do
        local sl = slots[n]
        local human = (sl.mouse == true) or (sl.pad == true) or (sl.scheme ~= nil)
        if human then
          local now
          if sl.mouse == true then
            now = G.pmouse.fire
          elseif sl.pad == true then
            now = G.gp.fire
          else
            local pin = G.pinputs[sl.scheme]
            now = (pin ~= nil and pin.fire) or false
          end
          if now and not MENU.joinPrev[n] then
            MENU.joined[n] = true
            playSound("soundClick")   -- 原版：准备页加入时播 soundClick
            updateReadyRows()
          end
          MENU.joinPrev[n] = now
        end
      end
    end
    for n = 1, #slots do
      if MENU.joined[n] ~= true then allJoined = false end
    end
    MENU.updateReadyStatus()
    -- 本地（同机多人）：全部加入即开赛。
    -- **联机**不在这里开赛 —— 改由 MENU.tickReady 按「房主发布的开始」统一进入 3 秒倒计时，
    --   否则两端各自判「齐了」会各自起表，开局时间错开（用户 2026-10-15：要统一发布开始时刻）。
    if allJoined and MENU.startTimer <= 0 and not G.online then
      beginMatch()
    end
  end
end

-- 战斗中「菜单」（原版 frame_53 的 settings 按钮 / 空格）：
--   **不结束对局**，而是**暂停并打开设置面板** —— phase 切到 "settings" 后 playing 分支不再推进，
--   世界状态原地冻结（无需额外的 paused 标志）；退出时回到对局继续打。
--   原版还会 Mouse.show() + 把鼠标坦克的准心 alpha 归零，我们同样隐藏准心。
MENU.fromBattle = false
MENU.openBattleSettings = function()
  -- ⚠️ 联机对局**不允许暂停 / 打开设置面板**（用户规则：联机不得以任何形式暂停或开设置界面）
  if G.online then return end
  MENU.fromBattle = true
  MENU.phase = "settings"
  MENU.setSel = 1
  setScopeVisible(false)
  refreshMenu()
end

-- 把「设置类」标量重新拷进在场坦克（**单机**对战中改设置后调用）。
--   ⚠️ 本函数**只服务于单机**：联机对局不允许暂停 / 开设置面板（`MENU.openBattleSettings` 在 `G.online`
--      时直接 return）⇒ 联机根本走不到 `leaveBattleSettings`，故这里**不含任何联机分支**。
--   ⚠️ **只改标量、绝不碰控件**：美术 / HUD / 触屏分区都不重建（理由见 leaveBattleSettings 的注释）。
--   覆盖项与 applyMode 里的对应片段保持一致：
--     · 控制方式 → `controlIndex` / `mouseTank` / `padTank`
--     · 移动端（触屏单机）→ 所有真人玩家强制走触屏（与 applyMode 同一规则）
--     · 按键设置页「鼠标操控」→ `settingsUseNewMouseControl`
--     · 对战设置「平滑碰撞」→ `settingsUseSmoothCollision`
MENU.reapplyTankSettings = function()
  local slots = buildSlots(G.mode)
  for i = 1, #G.tanks do
    local t, sl = G.tanks[i], slots[i]
    if t ~= nil and sl ~= nil then
      t.mouseTank = (sl.mouse == true)
      t.padTank = (sl.pad == true)
      t.controlIndex = sl.scheme
      t.settingsUseNewMouseControl = useNewMouseControl
      t.settingsUseSmoothCollision = G.rules.smooth
      if G.touchMode and not sl.ai then
        t.touchPad, t.touchPlayer = true, i
        t.mouseTank, t.padTank, t.controlIndex = false, false, nil
      else
        t.touchPad, t.touchPlayer = false, nil
      end
    end
  end
end

MENU.leaveBattleSettings = function()
  MENU.fromBattle = false
  MENU.phase = "playing"      -- 世界状态未被清理 ⇒ 直接继续对局
  -- （鼠标准心无需在此还原：每帧的 updateScope() 会按「当前是否有鼠标坦克」自行决定显隐）
  -- ⚠️ 重新把**设置类标量**拷进在场坦克：控制方式 / 鼠标操控 / 平滑碰撞都只在 applyMode
  --    里写进坦克 ⇒ 不重拷就会出现「回对战不生效、非得回主菜单重开一局才行」（用户 2026-10-15）。
  --    ⚠️ 这里**必须**用 reapplyTankSettings 而不是完整的 applyMode：applyMode 还会
  --    **重建车体/炮塔美术（从控件池取件）+ 重建计分 HUD + 重建触屏分区**，
  --    在对战进行中做这些会打乱控件池与叠放次序 ⇒ 实测「关掉菜单后坦克变成一堆色块、
  --    游戏无法正常运行」（用户 2026-10-15 报）。本函数只改标量、不碰任何控件，故无副作用。
  --    注：**按键**不受此影响，它走运行时反查表 BIND_REV，改完当帧即生效。
  MENU.reapplyTankSettings()
  refreshMenu()
end

-- 局内返回主菜单（原版 leaveGame 的本地等价：千星奇域 ESC 不可用，改用 R 键）。
local function returnToMenu()
  -- 若设置面板是**从战斗中**打开的，则「返回」= 回到对局（不退出、不清场）
  if MENU.fromBattle then MENU.leaveBattleSettings(); return end
  MENU.phase = "menu"
  MENU.sel = 1
  clearProjectiles()
  clearCrates()
  clearEffects()
  clearScoreBursts()
  setScopeVisible(false)
  audioApi.setBgm("menu")
  refreshMenu()
end

-- 「回到主界面」行（设置面板末行，**仅从战斗打开设置时显示**）：完全退出对局、回主菜单。
--   与「返回」的区别：返回 = 继续对局；回到主界面 = 清场退出（等价对战期按 R）。
MENU.quitToMenu = function()
  MENU.fromBattle = false     -- 先清标记，让 returnToMenu 走「真正回主菜单」分支
  returnToMenu()
end

-- 返回键：对战期 / 准备页 / 控制方式页 / 按键设置页返回上一级。键鼠与手柄各自绑定，二者可并存。
-- 键盘键为「保留键」，不参与自定义绑定；捕获态下按它即取消本次改键。
onMenuKey = function()
  local ph = MENU.phase
  playSound("soundClick")   -- 返回 / 退出操作统一给一次点击音效
  if ph == "playing" then
    -- 键盘返回键（R）在对战中 = **退出对局回主菜单**（我们自己的逃生口：千星奇域无 ESC/浏览器导航）。
    -- 而「菜单」按钮（鼠标 / 触屏点击）走原版行为 = 暂停并打开设置面板（见 MENU.stepPlayBack）。
    -- ⚠️ 联机对局：禁止退出（也不允许暂停 / 开设置）。
    if G.online then return end
    returnToMenu()
  elseif ph == "ready" then
    MENU.phase = "menu"
    refreshMenu()
  elseif ph == "settings" then
    if MENU.fromBattle then
      MENU.leaveBattleSettings()   -- 从战斗进来的：返回 = 继续对局
    else
      MENU.phase = "menu"
      MENU.sel = #MENU.MODES + 1
      refreshMenu()
    end
  elseif ph == "keys" then
    -- 按键设置页：返回 = 自动保存；键位冲突则提示并禁止返回（改键中则先取消本次改键）。
    MENU.leaveKeys()
  elseif ph == "rules" or ph == "other" then
    MENU.phase = MENU.returnPhase or "settings"
    if MENU.phase == "settings" then MENU.setSel = 1 end
    refreshMenu()
  elseif ph == "devices" then
    MENU.phase = "settings"
    MENU.setSel = 1
    refreshMenu()
  end
end

local function bindMenuKey()
  -- 键盘返回键：多候选，取运行时第一个可用的。
  local kb = {
    { ev = "KeyboardCharacterSkill3KeyDown", id = "CharacterSkill3Key" },  -- R
    { ev = "KeyboardCraftspersonKey14Down",  id = "CraftspersonKey14"  },  -- G
    { ev = "KeyboardCraftspersonKey29Down",  id = "CraftspersonKey29"  },  -- `
  }
  local bound = false
  for i = 1, #kb do
    local c = kb[i]
    -- 候选键（R / G / `）均已在 BINDABLE 中，setupInput 已为它们注册统一 Down 回调；
    -- 故此处只把 onMenuKey 追加进该事件的 EXTRA_DOWN，不能另注册监听（会被前一个回调的 return true 挡掉）。
    if eventType(c.ev) ~= nil then
      local key = "Keyboard" .. c.id .. "Down"
      local ex = EXTRA_DOWN[key]
      if ex == nil then ex = {}; EXTRA_DOWN[key] = ex end
      ex[#ex + 1] = onMenuKey
      CAPTURE.returnId = c.id   -- 记录已启用返回键的 id，供捕获态排除（不参与绑定）
      print("[坦克动荡] 返回键：" .. c.ev)
      bound = true
      break
    end
  end
  -- 手柄返回键：菜单返回键 / B 键，与键盘返回键并存，使手柄也能退出当前页。
  local pads = { "ControllerMenuBackKeyDown", "ControllerNormalAttackKeyDown" }
  for i = 1, #pads do
    if eventType(pads[i]) ~= nil and bindKey(pads[i], onMenuKey, "返回主菜单") then
      print("[坦克动荡] 手柄返回键：" .. pads[i])
      bound = true
    end
  end
  if not bound then print("[坦克动荡] 未找到可用的返回键") end
end

-- 击杀登记 → 本地战绩 + 本地成就；并把新解锁成就上报（原版 registerHit / unlockAchievement）
registerKill = function(victim, source)
  if victim == nil or source == nil then return end
  local player = G.tanks[G.playerIndex]
  if player == nil then return end
  if source == player then
    -- dryKill 判定：目标用的是普通炮弹且已打光（bulletsFired 达上限）
    local dry = (victim.currentWeapon == "bullet")
      and ((victim.bulletsFired or 0) >= C.SETTINGS.maxBullets)
    local newly = achApi.apply(G.ach, {
      type = "kill", byPlayer = true, victimAi = victim.ai == true, victimDry = dry,
    })
    statsApi.onKill(G.stats, true)
    reportNewAch(newly)
  elseif victim == player then
    statsApi.onDeath(G.stats)
    achApi.apply(G.ach, { type = "death" })
  end
end

-- ============================================================
-- ⑯.5 触屏输入层（移动端，见 DEV_STATE §10.5 / §6.20）
--   移动端没有键鼠：实例化一个全屏透明 CursorEventArea，把触点转成
--   「画布中心为原点、y 向上」的坐标写进 G.touch，并作为**指针**接入菜单逻辑
--   （菜单的悬停选中 / 左键确认 / 子页选行本就走鼠标路径，故触屏可直接复用）。
--   准备页则用「点自己的面板即加入」（见 stepMenuInput 的 ready 分支）。
--   未决前提（未真机验证，实现按最保守假设）：多指是否按 touchId 分别上报、
--   纯 Mobile 下 GetCursorUIPos 是否有效（故触屏分支不走 GetCursorUIPos）。
-- ============================================================
local function setupTouchInput()
  local dev = "?"
  pcall(function() dev = tostring(game.GetDevice()) end)
  print("[坦克动荡] 触屏输入层启动 device=" .. dev .. " touchMode=" .. tostring(G.touchMode))
  if not G.touchMode then return end

  local ok, areaRaw = pcall(game.InstantiateClientUIControl, PREFAB.CURSOR_AREA, host)
  if not ok or areaRaw == nil then
    print("[坦克动荡] 实例化 CursorEventArea 失败：" .. tostring(areaRaw))
    return
  end
  local area = areaRaw --[[@as ClientUICursorAreaControl]]
  pcall(function() area:SetSizeDelta(4000, 4000) end)   -- 全屏（与 cover 遮罩同法）
  pcall(function() area:SetAnchoredPosition(0, 0) end)
  pcall(function() area:SetActive(true) end)
  pcall(function() area:SetVisible(true) end)
  pcall(function() area.raycastTarget = true end)
  pcall(function() area.imageColor = Color(0, 0, 0, 0) end)  -- 透明，不遮挡画面

  -- 触点 → 画布中心原点的 UI 坐标（GetUIPos 以画布左下为原点）
  local function setPos(data)
    local x, y
    pcall(function()
      if data ~= nil then x, y = data:GetUIPos() end
    end)
    if type(x) ~= "number" or type(y) ~= "number" then return end
    local vw, vh = 0, 0
    pcall(function() vw, vh = game.GetUICanvasSize() end)
    G.touch.x, G.touch.y, G.touch.ok =
      (x - vw / 2) / (G.uiScale or 1), (y - vh / 2) / (G.uiScale or 1), true
  end

  -- 触点 id（平台若不提供 touchId，则统一按单指处理）
  local function tid(data)
    local id = nil
    pcall(function() if data ~= nil then id = data.touchId end end)
    if type(id) ~= "number" then id = 1 end
    return id
  end
  local function onDown(data)
    setPos(data)
    G.touch.down = true
    if G.touch.ok then G.touches[tid(data)] = { x = G.touch.x, y = G.touch.y } end
  end
  local function onDrag(data)
    setPos(data)
    if G.touch.ok then
      local id = tid(data)
      local t = G.touches[id]
      if t ~= nil then t.x, t.y = G.touch.x, G.touch.y end
    end
  end
  local function onUp(data)
    setPos(data)
    G.touches[tid(data)] = nil
    -- 「指针按下」= 仍有手指按住（多指时抬起一根不算松开）
    G.touch.down = next(G.touches) ~= nil
  end

  local regs = { { "CursorDown", onDown }, { "CursorDrag", onDrag }, { "CursorUp", onUp } }
  local n = 0
  for i = 1, #regs do
    local et = Enum.CursorEventType[regs[i][1]]
    if et ~= nil and pcall(function() area:AddCursorEventListener(et, regs[i][2]) end) then
      n = n + 1
    end
  end
  print("[坦克动荡] 触屏事件已登记 " .. n .. "/3")
end

-- ============================================================
-- ⑰ 生命周期
-- ============================================================
function OnInit()
  pcall(function() math.randomseed(os.time()) end)
  host = script.object
  print("[坦克动荡] OnInit，宿主类型=" .. typeof(host))
  if host == nil then
    printerr("[坦克动荡] script.object 为空，请确认脚本挂在容器控件上")
  end
  -- 设备判定：移动端（Mobile / MobileController）走触屏交互；其余走键鼠 / 手柄。
  local dev = "?"
  pcall(function() dev = tostring(game.GetDevice()) end)
  G.touchMode = (type(dev) == "string" and dev:find("Mobile") ~= nil) or false
  print("[坦克动荡] 设备=" .. tostring(dev) .. "，触屏模式=" .. tostring(G.touchMode))
end

function OnStart()
  if host == nil then return end
  pcall(function() host.disableKeyEventPassthrough = true end)
  -- 显示鼠标指针：**必须无条件设置**（与设备无关）。曾由一次性采集探针设置，探针删除后一度漏掉，
  -- 导致键鼠端「没有鼠标光标」，且 GetCursorUIPos 回落到画布中心（表现为正中间横幅始终高亮）。
  pcall(function() host.showCursor = true end)
  selfCheckPrefabs()
  bindAudioBackend()
  bindNet()
  audioApi.setBgm("menu")

  -- 全屏遮罩（盖住场景草地）
  local cover = createShape("square")
  if cover ~= nil then
    pcall(function()
      cover:SetSizeDelta(4000, 4000)
      cover.imageColor = COLOR.SCREEN
    end)
    cover:SetAnchoredPosition(0, 0)
  end

  -- 坦克实例（美术在每回合按武器重建）
  G.tanks = {}
  for i = 1, CFG.TANK_COUNT do
    G.tanks[i] = createTank(i, 0, 0)
  end
  initRules()   -- 对战设置初始化（G.rules ← C.SETTINGS 常量）
  -- 鼠标准星（原版第 3 台 scopeCross / scopeCircle；仅鼠标坦克参战时显示）
  buildScope()
  -- 默认单人（红 vs 莱卡）；真正开赛时由 beginMatch 调用 applyMode 按所选模式重配
  applyMode("solo")
  setupInput()
  buildMenuUI()
  bindMenuKey()
  setupTouchInput()   -- 触屏输入层（移动端；见 §6.20）
  MENU.setupOnlineDetection()   -- 联机判定（读关卡变量 TT2_PLAYERS；≥2 人 ⇒ 联机）
  if G.online then
    beginReady("duo")   -- 联机：进入游戏直接进准备界面（30 秒倒计时，见 MENU.updateReadyStatus）
  else
    refreshMenu()
  end
  -- 显示适配诊断（**只打日志，不改任何渲染**）：本项目 UI 是「固定设计尺寸」——
  --   所有坐标/尺寸单位 = 画布 UI 单位（画布中心为原点），画布有多大由设备决定，
  --   因此同一套 900×640 的设计在不同分辨率 / 长宽比的设备上，占屏比例会不同。
  --   这里打印画布尺寸与「按设计框等比适配（fit）」的候选倍率，供决定是否需要整体缩放。
  do
    local vw, vh = 0, 0
    pcall(function() vw, vh = game.GetUICanvasSize() end)
    local dw, dh = 900, 640
    local fit = 1
    if type(vw) == "number" and type(vh) == "number" and vw > 0 and vh > 0 then
      fit = min(vw / dw, vh / dh)
    end
    -- 夹在 [0.6, 2.0]：避免极端画布把 UI 缩到看不清或放到离谱
    if fit < 0.6 then fit = 0.6 elseif fit > 2 then fit = 2 end
    G.uiFitScale = fit
    local pv = "?"
    pcall(function()
      local a, b = host:GetPivot()
      pv = tostring(a) .. "," .. tostring(b)
    end)
    applyUIScale(fit)   -- 默认 = 自适应（MENU.SCALE_OPTS[1] == 0）；可在「设置 → 显示大小」改
    print("[坦克动荡] 显示适配：画布=" .. tostring(vw) .. "×" .. tostring(vh)
          .. " 设计框=" .. dw .. "×" .. dh
          .. " 自适应倍率=" .. tostring(floor(fit * 1000 + 0.5) / 1000)
          .. " hostPivot=" .. pv
          .. " 已应用=" .. tostring(floor((G.uiScale or 1) * 1000 + 0.5) / 1000))
  end
  G.running = true
  print("[坦克动荡] OnStart 完成：进入主菜单（W/S 选择，空格/Q/左键 确认）")
  script:EnableUpdate(true)
end

function OnEnable() print("[坦克动荡] OnEnable") end
function OnDisable() print("[坦克动荡] OnDisable") end
function OnUpdate() end

-- 对战期左上角「返回」按钮：悬停高亮 + 鼠标左键 / 触屏点击 = 返回主菜单（等价 R 键）。
-- 光标落在按钮上时 MENU.backHover 为真，tankFrame 据此屏蔽鼠标坦克开火（见 fire 取值处）。
MENU.stepPlayBack = function()
  -- 联机：右下角**没有菜单按钮**（联机不得暂停 / 开设置）⇒ 直接隐藏并跳过。
  if G.online then MENU.hideBack(); return end
  MENU.readCursor()
  local onBack = false
  if MENU.cursor.ok then onBack = MENU.hitBack(MENU.cursor.x, MENU.cursor.y) end
  MENU.backHover = onBack
  MENU.placeBack()
  local ptrFire = G.pmouse.fire or (G.touchMode and G.touch.down == true)
  local edge = ptrFire and not MENU.mousePrev
  MENU.mousePrev = ptrFire
  -- 原版：战斗中「菜单」= 暂停并打开设置面板（联机对局被 openBattleSettings 内部拦掉，按钮形同失效）
  if edge and onBack then MENU.openBattleSettings() end
end

function OnLevelUpdate(dt)
  if not G.running or host == nil then return end
  dt = min(dt, 0.25)
  pollGamepad()   -- 每帧轮询左摇杆/十字键/A，合成 G.gp（菜单与对局共用）
  audioClock = audioClock + dt
  -- 联机延迟探测：准备页 / 对战页每 1 秒发一次 PING（服务器回发后由 MENU.onPong 算出 ms）
  if G.online then
    G.pingTimer = G.pingTimer + dt
    if G.pingTimer >= 1 then
      G.pingTimer = 0
      if MENU.phase == "ready" or MENU.phase == "playing" then MENU.pingSend() end
    end
  end
  if MENU.phase == "playing" then
    MENU.stepPlayBack()                          -- 左上角「返回」按钮（悬停 / 点击）
    if MENU.phase ~= "playing" then return end   -- 刚点返回：本帧不再推进世界
    G.accum = G.accum + dt
    local steps = 0
    while G.accum >= CFG.FRAME_DT and steps < CFG.MAX_STEPS do
      G.accum = G.accum - CFG.FRAME_DT
      steps = steps + 1
      stepFrame()
    end
    if steps >= CFG.MAX_STEPS then G.accum = 0 end
  else
    -- 菜单 / 准备：只处理导航，不推进世界（等价于原版的暂停）
    stepMenuInput()
    MENU.stepMenuAnim(dt)
    -- 联机准备流程（**仅 G.online**）：倒计时 / 到点强制准备 / 3 秒开始 / 开赛**全部由 MENU.tickReady 驱动**，
    --   且用**共享时钟 TT2_BEAT** 计算 ⇒ 两端的倒计时逐秒一致、到点落在同一个心跳刻。
    if MENU.phase == "ready" and G.online then
      MENU.tickReady(dt)
      MENU.updateReadyStatus()
    end
  end
end

function OnDestroy()
  print("[坦克动荡] OnDestroy")
  G.running = false
  for i = 1, #G.tanks do disposeTank(G.tanks[i]) end
  clearProjectiles()
  clearCrates()
  clearEffects()
  clearScoreBursts()
  vfree(G.wallParts)
  G.wallParts = {}
end

-- ============================================================
-- ⑱ 离线冒烟测试观察口
-- ============================================================
-- 文字不再使用文本控件（改为线段拼字），控件上已无 .text 可供扫描，
-- 故把承载语义文本的 Label 组与运行时状态暴露出来，供 tests/test_platform.lua 断言。
-- 只读引用，真机运行无任何副作用。
__TT_DEBUG = { MENU = MENU, hud = hud, G = G,
  -- 供测试核查「单图片模板 + SetImage」：形状→图片 ID 表 + 按形状建控件的函数
  SHAPE_IMAGE_ID = IMG, createShape = createShape }