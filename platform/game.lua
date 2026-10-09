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

  美术：仅用编辑器自带的 6 个形状控件模板（正方形 / 圆形 / 三角形 / 四芒星 / 五角星 / 同心圆）
        + 文本框模板，运行时靠拉伸 / 旋转 / 上色 / 多控件拼接画出全部对象（不依赖任何外部贴图）。
]]

local C        = require("src.constants")
local mazeApi  = require("src.maze")
local tankApi  = require("src.tank")
local weaponsApi = require("src.weapons")
local aiApi    = require("src.ai")
local roundApi = require("src.round")
local netApi   = require("src.net")
local audioApi = require("src.audio")
local achApi   = require("src.ach")
local statsApi = require("src.stats")

local cos, sin, sqrt, abs, floor, min, max, deg =
  math.cos, math.sin, math.sqrt, math.abs, math.floor, math.min, math.max, math.deg
local PI, RAD = math.pi, math.pi / 180

-- 前向声明：下方多个函数在定义处即引用它们。
-- Lua 局部变量必须先声明后使用，否则会被解析成全局变量（运行期为 nil）。
---@type table<string, any>
local G
---@type fun(px: number, py: number): number, number
local toUI
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
local PREFAB = {
  TEXT   = 1073741884,   -- 文本框：HUD 文字
  SQUARE = 1073741886,   -- 正方形（Stretch）：墙 / 地板 / 车体 / 履带 / 炮管 / 补给箱 / 遮罩
  CIRCLE = 1073741888,   -- 圆形（Stretch）：炮弹 / 炮塔 / 导弹头 / 高光
  TRI    = 1073741890,   -- 三角形：碎片 / 残骸
  STAR4  = 1073741892,   -- 四芒星：炮口闪光 / 火花
  STAR5  = 1073741894,   -- 五角星：爆炸星芒
  RINGS  = 1073741896,   -- 同心圆：地雷
}

-- 形状名 → 控件模板索引（部件池按形状名分桶）
local SHAPE_PREFAB = {
  square = PREFAB.SQUARE,
  circle = PREFAB.CIRCLE,
  tri    = PREFAB.TRI,
  star4  = PREFAB.STAR4,
  star5  = PREFAB.STAR5,
  rings  = PREFAB.RINGS,
}

local CFG = {
  FRAME_DT   = 1 / 25,   -- 原版帧率 25 FPS
  MAX_STEPS  = 6,        -- 每帧最多补几个逻辑步，防卡顿雪崩
  TARGET_W   = 900,      -- 舞台渲染目标宽（UI 单位）
  TARGET_H   = 600,      -- 舞台渲染目标高
  MAZE_W_MIN = 4, MAZE_W_MAX = 12,
  MAZE_H_MIN = 4, MAZE_H_MAX = 10,
  TANK_COUNT = 2,
  PLAYER     = 1,
  WALL_T     = 1 / 8,    -- 墙厚 = SCALE/8（= 2×floor(SCALE/16)，与碰撞一致）
  -- 补给箱半边长（单位=格）。原版 Crate 剪辑 20×20 局部单位，生成时 _xscale = SCALE*1.5，
  -- 显示尺寸 = 20 * SCALE*1.5/100 = 0.3 格；实机截图 8 倍放大实测约 0.32 格。
  -- 拾取判定用的也是同一半边长（原版 ±10 局部像素 × 1.5*SCALE/100 = 0.15 格）。
  CRATE_R    = 0.16,     -- 边长 = 2*CRATE_R*SCALE ≈ 0.32 格（≈ 原版 0.3 格）
}

-- 原版舞台 692×480：迷宫像素即舞台像素。整块舞台等比缩放到 UI 目标区，
-- 迷宫在舞台内按原版 setupStandardMaze 末尾公式摆位（水平居中、顶部留白 10px），
-- 计分板固定在舞台底部。因 VS 只由舞台尺寸决定、与单局迷宫尺寸无关，
-- 4~12 × 4~10 各种宽高比的迷宫都按真实比例显示，不被拉伸。
local STAGE_W = C.MOVIEWIDTH      -- 692
local STAGE_H = C.MOVIEHEIGHT     -- 480
local STAGE_SCALE = min(CFG.TARGET_W / STAGE_W, CFG.TARGET_H / STAGE_H)

local function col(r, g, b, a)
  return Color(floor(r), floor(g), floor(b), a or 255)
end

local COLOR = {
  SCREEN   = col(20, 22, 28),
  -- 原版 drawMaze（frame_53 595-664）：地板是舞台底色（近白），墙块填充浅灰 0xE6E6E6，
  -- 墙内边线用深灰 0x4D4D4D、最外圈纯黑，整体读作「浅地板 + 深墙」。
  -- 移植版此前正好相反（深地板 + 浅墙），这里按原版关系翻转；
  -- 顺带让「敌我皆黑」的普通炮弹在浅地板上清晰可见。
  FLOOR    = col(232, 234, 238),
  FLOOR_LN = col(216, 219, 224),
  WALL     = col(112, 118, 128),
  WALL_TOP = col(150, 157, 168),
  WALL_DIP = col(72, 77, 86),
  P1       = col(224, 82, 70),
  P2       = col(87, 184, 88),
  P3       = col(86, 140, 224),
  P4       = col(226, 180, 70),
  -- 莱卡（AI）：原版 p2trac 0x262626（深灰）/ p2turc 0x666666（中灰）。
  -- 车体色略提亮，避免在深色菜单面板上完全不可辨。
  AI       = col(60, 62, 68),
  SHOT     = col(255, 214, 140),
  -- 原版投射物贴图原生色（贴图不与坦克颜色相乘）：
  -- bullet / electricbullet 5×5 纯黑，gatlingBullet 3×3 纯黑，
  -- fragbombfragment 3×3 纯黑，homingbullet 8×11 灰白。
  BULLET   = col(0, 0, 0),
  HOMING   = col(224, 228, 234),
  TEXT     = col(245, 245, 245),
  OUTLINE  = col(18, 18, 22),
  -- 原版补给箱（raw/Crate.swf 矢量剪辑，生成时 gotoAndStop(武器名) 切到逐武器帧）：
  -- 实机截图 8 倍放大实测 = 中灰方块 + 稍亮内框 + 中央深色武器字形（字形实测 RGB≈(47,47,47)）。
  -- game_export 里没有任何补给箱位图/精灵，故只能用 7 个图元手绘。
  CRATE     = col(150, 154, 162),  -- 箱体（中灰）
  CRATE_IN  = col(232, 234, 238),  -- 内框（亮灰）
  CRATE_B   = col(48, 50, 56),     -- 武器字形（深色）
  CRATE_DUST = col(170, 170, 170), -- 落地扬尘（原版 dust 色 0xAAAAAA）
  SMOKE    = col(180, 180, 180),
  FLAME    = col(255, 168, 60),
  -- 菜单
  PANEL    = col(24, 28, 36),
  SEL      = col(58, 70, 92),
  ACCENT   = col(240, 196, 88),
  DIM      = col(150, 158, 172),
  OK       = col(120, 220, 140),
  NO       = col(210, 120, 120),
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
  -- 注意：imageType 是「图片类控件」的字段（API 721），文本框控件没有这个属性；
  -- 对它赋值会抛错，而这一批设置写在同一处，报错会连带跳过后面所有语句。
  if prefabIndex ~= PREFAB.TEXT then
    pcall(function() ctl.imageType = Enum.ImageType.Stretch end)
  end
  return ctl --[[@as ClientUIControl]]
end

local function acquire(shape)
  local list = pool[shape]
  if list == nil then
    list = {}
    pool[shape] = list
  end
  local ctl = table.remove(list)
  if ctl == nil then
    ctl = createControl(SHAPE_PREFAB[shape] or PREFAB.SQUARE)
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

-- 模板自检：逐个实例化 7 个控件模板并立刻销毁，结果打到正常日志，便于排查"编辑器里没配模板 / 索引写错"
local function selfCheckPrefabs()
  local order = { "TEXT", "SQUARE", "CIRCLE", "TRI", "STAR4", "STAR5", "RINGS" }
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
  -- 额外探针：确认 TEXT 索引确实指向「文本框」，并把真机实际生效的情况打出来。
  -- 注意：上一版只在单测桩件上验证过（桩未实现 SetActive / SetAsLastSibling），
  -- 结论不可信。这里改成「真机自检」：把控件摆到屏幕上方并存活约 1 秒，
  -- 日志打印每一项的实际读回值，失败点会直接暴露。
  do
    local ok, ctl = pcall(game.InstantiateClientUIControl, PREFAB.TEXT, host)
    if ok and ctl ~= nil then
      local function try(f)
        local o, a, b, c, d = pcall(f)
        if not o then return "<err>" end
        return a, b, c, d
      end
      try(function()
        ctl:SetAnchorMin(0.5, 0.5); ctl:SetAnchorMax(0.5, 0.5); ctl:SetPivot(0.5, 0.5)
      end)
      try(function() ctl:SetActive(true) end)
      try(function() ctl:SetVisible(true) end)
      try(function() ctl:SetSizeDelta(864, 102) end)
      try(function() ctl.adaptiveFontSize = false end)
      try(function() ctl.fontSize = 36 end)
      try(function() ctl.text = "自检文本 OK" end)
      try(function() ctl.fontColor = COLOR.TEXT end)
      try(function() ctl.enableOutline = false end)
      try(function() ctl:SetAnchoredPosition(0, 300) end)

      local pp = tostring(try(function() return ctl.prefabIndex end))
      local gsx, gsy = try(function() return ctl:GetSizeDelta() end)
      local fsz = tostring(try(function() return ctl.fontSize end))
      local back = tostring(try(function() return ctl.text end))
      local ai = tostring(try(function() return ctl.activeInHierarchy end))
      local vis = tostring(try(function() return ctl.visible end))
      local fcr, fcg, fcb, fca = try(function() return Color.ToRGBA(ctl.fontColor) end)
      seg[#seg + 1] = "TEXT探针 prefab=" .. pp
        .. " size读回=" .. tostring(gsx) .. "x" .. tostring(gsy)
        .. " fontSize=" .. fsz .. " text读回=" .. back
        .. " activeInHierarchy=" .. ai .. " visible=" .. vis
        .. " fontColor=" .. tostring(fcr) .. "," .. tostring(fcg) .. ","
        .. tostring(fcb) .. "," .. tostring(fca)
      -- 不立刻销毁：存活约 1 秒（见 OnLevelUpdate），供肉眼确认「文本框到底能不能显示」。
      -- 在 OnStart 末尾会被抬到最上层，避免被后建的菜单面板压住。
      G.textProbe = ctl
      G.textProbeTtl = 1.0
    else
      seg[#seg + 1] = "TEXT探针 实例化失败"
    end
  end
  print("[坦克动荡] 模板自检：" .. table.concat(seg, " | "))
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
  maze = nil, reachable = {}, reachableIndex = nil, deadEnds = nil,
  tanks = {}, projectiles = {}, crates = {}, effects = {},
  wallParts = {}, wallHolder = {},
  battle = nil,
  shakeX = 0, shakeY = 0,
  fieldCache = {}, distProxy = nil,
  playerIndex = CFG.PLAYER,
  -- 菜单导航输入（W/S/A/D + 方向键 + 确认键）
  input = { fwd = false, back = false, left = false, right = false, fire = false },
  -- 各控制方案（1=红/1P，2=绿/2P）的坦克输入。见 SCHEME_KEY。
  pinputs = {
    { fwd = false, back = false, left = false, right = false, fire = false },
    { fwd = false, back = false, left = false, right = false, fire = false },
  },
  mode = "solo",   -- solo | duo
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
  return (sx - STAGE_W / 2) * G.VS + G.shakeX, (STAGE_H / 2 - sy) * G.VS + G.shakeY
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
  G.wallHolder = {}
  -- 地板控件随回合重建，先把旧的还回池子，避免每回合泄漏一个控件
  if G.floorCtl ~= nil then
    release("square", G.floorCtl)
    G.floorCtl = nil
  end
  local s = G.scale
  local t = s * CFG.WALL_T
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

  -- 地板
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
end

-- ============================================================
-- ⑥ 坦克：美术 / 构造 / 炮塔
-- ============================================================
local TANK_BASE_ART = {
  -- 履带 ×2（沿前后方向铺开）
  { "sq", 13, 81, 0.42, -24, 0, 0 },
  { "sq", 13, 81, 0.42, 24, 0, 0 },
  -- 履带节纹
  { "sq", 13, 5, 0.62, -24, -27, 0 },
  { "sq", 13, 5, 0.62, -24, 0, 0 },
  { "sq", 13, 5, 0.62, -24, 27, 0 },
  { "sq", 13, 5, 0.62, 24, -27, 0 },
  { "sq", 13, 5, 0.62, 24, 0, 0 },
  { "sq", 13, 5, 0.62, 24, 27, 0 },
  -- 车体
  { "sq", 46, 70, 1.0, 0, 0, 0 },
  -- 前装甲斜面（前方 = 局部 -y）
  { "sq", 46, 9, 0.82, 0, -36, 0 },
  -- 车身高光
  { "sq", 38, 4, 1.30, 0, -18, 0 },
}

local TURRET_BARREL = {
  bullet = 26, laser = 34, frag = 28, gatling = 32, homing = 28,
  mine = 26, remote = 28, deathRay = 40, electric = 26, elToro = 26,
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

local function buildTurretArt(t)
  vfree(t.turretArt)
  local s = t.s
  local parts = {}
  local len = TURRET_BARREL[t.currentWeapon or "bullet"] or 26
  -- 炮塔圆盘 + 塔心
  parts[#parts + 1] = vpart("circle", 45 * s, 45 * s, shade(t.baseColor, 1.10), 0, 0, 0)
  parts[#parts + 1] = vpart("circle", 16 * s, 16 * s, shade(t.baseColor, 0.70), 0, 0, 0)
  -- 炮管 + 炮口（指向局部 -y）
  parts[#parts + 1] = vpart("square", 8 * s, len * s, shade(t.baseColor, 0.55),
    0, -(len / 2 + 5) * s, 0)
  parts[#parts + 1] = vpart("square", 11 * s, 6 * s, shade(t.baseColor, 0.38),
    0, -(len + 7) * s, 0)
  t.turretArt = parts
end

local PALETTE = { COLOR.P1, COLOR.P2, COLOR.P3, COLOR.P4 }

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
    settingsUseNewMouseControl = false,
    settingsUseSmoothCollision = C.SETTINGS.useSmoothCollision,
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
  t.KEYTURNLEFT = 37
  t.KEYTURNRIGHT = 39
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
  local c = p.color or COLOR.SHOT   -- 仅激光 / 死亡射线 / 地雷等有色武器使用
  -- 绘制尺寸 = 贴图原生像素 × (SCALE/50)，与原版一致（此前用了近两倍的尺寸，显得过大）。
  if p.kind == "bullet" or p.kind == "electric" then
    -- 原版 bullet / electricbullet 贴图 5×5 纯黑（与 owner 颜色无关）
    parts[#parts + 1] = vpart("circle", 5 * k, 5 * k, COLOR.BULLET, 0, 0, 0)
  elseif p.kind == "gatlingBullet" then
    -- 原版 gatlingBullet 贴图 3×3 纯黑
    parts[#parts + 1] = vpart("circle", 3 * k, 3 * k, COLOR.BULLET, 0, 0, 0)
  elseif p.kind == "frag" then
    -- 原版 fragbomb 贴图 7×7 纯黑圆弹（与破片 fragment 是不同贴图）
    parts[#parts + 1] = vpart("circle", 7 * k, 7 * k, COLOR.BULLET, 0, 0, 0)
  elseif p.kind == "fragment" then
    -- 原版 fragbombfragment 贴图 3×3 纯黑（略放大到 4 以免亚像素完全看不见）
    parts[#parts + 1] = vpart("tri", 4 * k, 4 * k, COLOR.BULLET, 0, 0, 0)
  elseif p.kind == "homing" or p.kind == "remote" then
    -- 原版 homingbullet 贴图 8×11 灰白（不与坦克颜色相乘）
    parts[#parts + 1] = vpart("square", 8 * k, 11 * k, COLOR.HOMING, 0, 0, 0)
    parts[#parts + 1] = vpart("circle", 6 * k, 6 * k, shade(COLOR.HOMING, 0.72), 0, -7 * k, 0)
    parts[#parts + 1] = vpart("square", 6 * k, 3 * k, shade(COLOR.HOMING, 0.6), 0, 8 * k, 0)
  elseif p.kind == "mine" then
    local d = 50 * (p.scaleFactor or 0.2)
    parts[#parts + 1] = vpart("rings", d, d, c, 0, 0, 0)
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
    polyRender(holder, pts, p.color or COLOR.SHOT, 5 * (G.scale / 50), stride)
    return
  end
  if p.kind == "deathRay" then
    local holder = p.visHolder
    if holder == nil then
      holder = { segs = {} }
      p.visHolder = holder
    end
    local pts = p.curvePoints or {}
    local stride = max(1, floor(#pts / 120))
    local wid = max(1, (p.rayThickness or 0)) * (G.scale / 50)
    polyRender(holder, pts, p.color or COLOR.SHOT, wid, stride)
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
  end
end

-- 折线渲染：holder.segs 为段控件池
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

local function spawnEffect(kind, x, y, color, size, life, vx, vy)
  local e = {
    kind = kind, x = x, y = y, vx = vx or 0, vy = vy or 0,
    life = life, lifeMax = life, color = color, size = size, rot = 0,
    spin = (kind == "frag" or kind == "burst") and (math.random() * 24 - 12) or 0,
  }
  e.vis = { vpart(EFFECT_SHAPE[kind] or "square", size, size, color, 0, 0, 0) }
  G.effects[#G.effects + 1] = e
  return e
end

local function freeEffect(e)
  if e.vis ~= nil then vfree(e.vis); e.vis = nil end
end

local function stepEffects()
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
      local a = floor(255 * (e.life / e.lifeMax))
      local p = e.vis[1]
      if p ~= nil then
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
    settingsMaxBullets = C.SETTINGS.maxBullets,
    -- round.pickCratePos 需要的上下文
    settings = C.SETTINGS,
    crateSpawnPoints = {},   -- 无自定义迷宫，恒为空
    reachable = G.reachable,
    reachableIndex = G.reachableIndex,
    numberOfCrates = 0,
    log = function(m) print("[坦克动荡][AI] " .. tostring(m)) end,
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
    -- 震屏统一走 battle.shake（round.step 每帧据此产生偏移并衰减）
    shake = function(v)
      if G.battle ~= nil then
        G.battle.shake = roundApi.addShake(G.battle.shake, v)
      end
    end,
    keyDown = function(code)
      if code == 37 then return G.input.left end
      if code == 39 then return G.input.right end
      return false
    end,
    mousePos = function() return -99999, -99999 end,
    attemptForward = function(t)
      return tankApi.attemptToMove(t, true, false, false, false)
    end,
    -- 纯视觉回调
    smoke = function(kind, p, n) visualSmoke(kind, p, n) end,
    fragments = function(p, n) visualFragments(p, n) end,
    trail = function() end,
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
  for _ = 1, n do
    local ang = math.random() * 2 * PI
    local sp = (0.3 + math.random() * 0.7) * k
    spawnEffect("smoke", p.x, p.y, COLOR.SMOKE,
      (6 + math.random() * 6) * k, 12 + floor(math.random() * 8),
      cos(ang) * sp, sin(ang) * sp)
  end
end

function visualFragments(p, n)
  local k = G.scale / 50
  for _ = 1, n do
    local ang = math.random() * 2 * PI
    local sp = (1.5 + math.random() * 2) * k
    spawnEffect("frag", p.x, p.y, shade(p.color or COLOR.SHOT, 0.8),
      8 * k, 10 + floor(math.random() * 8), cos(ang) * sp, sin(ang) * sp)
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
local SOUND_IDS = {}
local audioClock = 0   -- 秒，由 OnLevelUpdate 推进，供 audio 模块做同类音效最小间隔

-- 绑定音频后端：真机走 game.PlayAudio2D / game.StopAudio；未配置音频 ID 时全程静默
local function bindAudioBackend()
  audioApi.bind({
    now    = function() return audioClock end,
    play2d = function(id) return game.PlayAudio2D(id) end,
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
      return game.ServerSignal(name)
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
  updateWeaponHUD()
end

function onHit(owner, victim)
  if victim == nil or not victim.alive then return end
  killTank(victim, owner)
end

function killTank(victim, source)
  victim.alive = false
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

-- 逐武器字形（原版补给箱每个武器一帧，字形各不相同）。
-- 每项 = { 控件形状, 宽, 高, 局部旋转 }，宽高是「字形基准框 gb」的倍数。
local CRATE_GLYPH = {
  laser    = { { "tri",    1.0, 1.0, 0 } },              -- 三角
  frag     = { { "circle", 1.0, 1.0, 0 } },              -- 实心圆
  gatling  = { { "star4",  1.0, 1.0, 0 } },              -- 四芒星
  homing   = { { "star5",  1.0, 1.0, 0 } },              -- 五角星
  deathRay = { { "rings",  1.0, 1.0, 0 } },              -- 同心圆
  mine     = { { "square", 0.9, 0.9, 45 } },             -- 菱形（箱体是正的，菱形一眼可辨）
  remote   = { { "square", 1.0, 0.32, 0 },               -- 十字
               { "square", 0.32, 1.0, 0 } },
}

-- 建一套补给箱图元：中灰箱体 + 亮灰内框 + 深色武器字形。
-- r = 半边长（世界像素）。每个部件记下基准尺寸 bw/bh，供弹入缩放动画逐帧重设。
local function buildCrateVisual(weapon, r)
  local specs = {
    { "square", r * 2.0, r * 2.0, COLOR.CRATE,    0 },
    { "square", r * 1.6, r * 1.6, COLOR.CRATE_IN, 0 },
  }
  local gb = r * 1.1   -- 字形基准框（约箱子边长的 55%，与实机截图字形占比一致）
  local glyph = CRATE_GLYPH[weapon] or { { "square", 1.0, 1.0, 0 } }
  for i = 1, #glyph do
    local it = glyph[i]
    specs[#specs + 1] = { it[1], gb * it[2], gb * it[3], COLOR.CRATE_B, it[4] or 0 }
  end
  local vis = {}
  for i = 1, #specs do
    local s = specs[i]
    local p = vpart(s[1], s[2], s[3], s[4], 0, 0, s[5])
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

local function trySpawnCrate()
  local pos = roundApi.pickCratePos(ctx)
  if pos == nil then return end
  local cell = G.reachable[pos]
  if cell == nil then return end
  cell.used = true
  local weapon = roundApi.pickCrateWeapon(C.SETTINGS.activeWeapons)
  if weapon == nil then cell.used = false; return end
  local s = G.scale
  -- 弹入参数取自原版 spawnCrate：targetScale = SCALE*1.5、_rotation = rot(随机)、
  -- scaleSpeed = SCALE/5、scaleSpeedDiff = SCALE/20（src/round.lua M.crateLanding）。
  local land = roundApi.crateLanding(s)
  local crate = {
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
  G.crates[#G.crates + 1] = crate
  cratePuff(crate.x, crate.y, 3)
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
      setWeapon(picked, c.weapon)
      if c.cell ~= nil then c.cell.used = false end
      vfree(c.vis)
      table.remove(G.crates, i)
    else
      -- 弹入动画（原版：_xscale 每帧 +scaleSpeed，越过 targetScale 后减去 scaleSpeedDiff 回弹，
      -- 再降到 targetScale 以下时 snap 到 targetScale 并喷落地扬尘；无「旋转归位」动画）。
      if not c.landed then
        c.k = c.k + c.kSpeed
        if c.k > 1 then c.kSpeed = c.kSpeed - c.kDiff end
        if c.k < 1 and c.kSpeed < 0 then
          c.k, c.kSpeed, c.landed = 1, 0, true
          cratePuff(c.x, c.y, 3)
        end
      end
      local vs = G.VS
      local ux, uy = toUI(c.x, c.y)
      for j = 1, #c.vis do
        local p = c.vis[j]
        p.ctl:SetSizeDelta(p.bw * c.k * vs, p.bh * c.k * vs)
        p.ctl:SetAnchoredPosition(ux, uy)
        p.ctl:SetLocalRotation(0, 0, -(c.rot + p.lrot))
      end
    end
  end
end

local function assignTanksToCells()
  -- 从可达格中为每辆坦克挑一个互不相同的起点
  local n = #G.reachable
  local used = {}
  for i = 1, #G.tanks do
    local t = G.tanks[i]
    local cell
    for _ = 1, 40 do
      local idx = floor(math.random() * n) + 1
      local c = G.reachable[idx]
      if c ~= nil and not used[idx] then
        used[idx] = true
        cell = c
        break
      end
    end
    cell = cell or G.reachable[1] or { x = 0, y = 0 }
    -- 新回合的迷宫尺寸决定了 SCALE，速度 / 缩放 / 碰撞盒随 SCALE 变化，必须重新同步
    tankApi.setScale(t, G.scale)
    t.x = (cell.x + 0.5) * G.scale
    t.y = (cell.y + 0.5) * G.scale
    t.rot = tankApi.randomRotation()
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

local function startNewRound()
  -- 原版 setupStandardMaze（frame_53 第 1950-1960 行）：
  --   随机尺寸 + 随机起点算连通分量，可达格不足 2*TANKS 就整局重掷。
  local tankCount = max(2, #G.tanks)
  local minReachable = 2 * tankCount
  local W, H, maze, reachable, reachableIndex
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
  clearEffects()
  assignTanksToCells()

  G.battle = roundApi.newBattle(#G.tanks,
    roundApi.nextCrateTimer(#reachable, C.SETTINGS.crateSpawnModifier))
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
  if weaponsApi.lockedControl(t, t.currentWeapon) then return end

  local fire
  if t.controlIndex ~= nil then
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

  tankApi.beginFrame(t)
  tankApi.attemptToMove(t, t.forward, t.backup, t.turnLeft, t.turnRight)

  if fire and t.triggerReleased and weaponsApi.weaponReady(t, t.currentWeapon, C.SETTINGS.maxBullets) then
    t.triggerReleased = false
    local list = weaponsApi.fire(t, t.currentWeapon, ctx)
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

local function stepFrame()
  rebuildCtxLists()

  local offX, offY, ev = roundApi.step(G.battle)
  G.shakeX = offX * G.VS
  G.shakeY = -offY * G.VS

  if ev == "freeze" then
    G.battle.frozen = true
  elseif ev == "cleanup" then
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
    showResult("【回合结算】" .. statsApi.summary(G.stats), 2.0)
  elseif ev == "reset" then
    startNewRound()
    return
  end

  if not G.battle.frozen then
    for i = 1, #G.tanks do tankFrame(G.tanks[i]) end
    stepProjectiles()
    if roundApi.tickCrateTimer(G.battle, #G.reachable, C.SETTINGS.crateSpawnModifier) then
      trySpawnCrate()
    end
  end

  syncCrates()
  stepEffects()
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
  -- 对局中会不断新建炮弹 / 补给箱 / 特效，每帧末重排一次，保证坦克永远在最上层
  applyZOrder()
end

-- ============================================================
-- ⑭ HUD
-- ============================================================
local hud = {}

-- 文本框属性逐项设置：每条属性单独一个 pcall。
-- 原先所有赋值写在同一个 pcall 里，任何一条抛错（当前引擎不认识的枚举、
-- 或对文本框不适用的调用）都会连带跳过后面的语句 —— 包括最关键的
-- ctl.text = ...，结果就是「有框但没字」。现在先写文字，再写排版，
-- 后写的失败也不会影响已经写进去的文字。
--
-- 字体与字号策略（本轮修正，针对「菜单/HUD 文字不显示」）：
--   ① 文字第一条写入（保持不变）；
--   ② 关闭字号自适应（adaptiveFontSize=false），直接用固定 fontSize。
--      自适应字号会依据「当时的控件尺寸」估算，而尺寸在本函数之后才设置，
--      存在被估算成极小值（甚至被 minimumFontSize 兜底到 14 后仍不显示）的风险。
--   ③ 关闭描边（enableOutline=false）。描边依赖模板材质，若模板未配描边材质，
--      开启后可能整段文字不渲染。先关掉以排除这条路径，确认能显示后再考虑恢复。
local function styleText(ctl, text, size, align)
  pcall(function() ctl.text = text end)
  pcall(function() ctl.adaptiveFontSize = false end)
  pcall(function() ctl.fontSize = size end)
  pcall(function() ctl.minimumFontSize = max(size, 16) end)
  pcall(function() ctl.fontColor = COLOR.TEXT end)
  -- 官方文档：文本框背景「支持配置透明、黑色半透明底色」；显式置为全透明
  pcall(function() ctl.bgColor = Color.FromRGBA(0, 0, 0, 0) end)
  pcall(function() ctl.enableOutline = false end)
  pcall(function() ctl.horizontalAlignment = align or Enum.TextHorizontalAlignment.Middle end)
  pcall(function() ctl.verticalAlignment = Enum.TextVerticalAlignment.Middle end)
end

local function makeText(y, size, text)
  local ctl = createControl(PREFAB.TEXT)
  if ctl == nil then return nil end
  -- 先定尺寸、再写属性：字号自适应若（被模板默认值）打开，会按「当前尺寸」估算，
  -- 因此必须在设置字号之前就把最终尺寸给足。
  -- 尺寸给足：官方建议文本框长度远大于实际文本宽度；高度取 3 倍字号留出余量
  pcall(function() ctl:SetSizeDelta(864, size * 3) end)
  styleText(ctl, text, size, nil)
  pcall(function() ctl:SetAnchoredPosition(0, y) end)
  return ctl
end

function updateScoreHUD()
  if hud.score ~= nil then
    local a = G.tanks[1]
    local b = G.tanks[2]
    local sa = a and a.score or 0
    local sb = b and b.score or 0
    -- solo：红 vs 莱卡（深灰）；duo：红 vs 绿
    local nb = (G.mode == "duo") and "绿" or "莱卡"
    pcall(function() hud.score.text = "红 " .. sa .. "   :   " .. sb .. " " .. nb end)
  end
end

function updateWeaponHUD()
  if hud.weapon == nil then return end
  local t = G.tanks[G.playerIndex]
  if t == nil then return end
  local names = {
    bullet = "普通炮弹", laser = "激光", frag = "破片弹", gatling = "加特林",
    homing = "追踪导弹", mine = "地雷", remote = "遥控导弹",
    deathRay = "死亡射线", electric = "电击弹", elToro = "蛮牛冲撞",
  }
  pcall(function()
    hud.weapon.text = "武器：" .. (names[t.currentWeapon] or t.currentWeapon)
  end)
end

-- 舞台 y（0=顶，480=底）→ UI y（以舞台中心为原点）
local function stageY(sy) return (STAGE_H / 2 - sy) * STAGE_SCALE end

local function setupHUD()
  -- 计分板固定在舞台底部（原版 playerScoreBoard._y = MOVIEHEIGHT - 25）
  hud.score = makeText(stageY(STAGE_H - 32), 34, "红 0   :   0 绿")
  -- 武器与操作提示放在舞台上方，避免压住迷宫
  hud.weapon = makeText(stageY(-52), 22, "武器：普通炮弹")
  hud.hint = makeText(stageY(-20), 20, "红方 S/E/F/D 移动 · Q 开火    设置：R")
  -- 本地结算面板：回合结束短暂显示一次战绩小结（原版为服务器结算/奖励发放）。
  -- 真正的奖励与段位结算在编辑器节点图完成，这里只做本地可视化反馈。
  hud.result = makeText(stageY(STAGE_H / 2), 26, "")
  hud.resultTtl = 0
end

function showResult(text, seconds)
  if hud.result == nil then return end
  hud.result.text = text
  hud.resultTtl = seconds or 2.0
  hud.result:SetVisible(true)
end

local function stepResult(dt)
  if hud.result == nil then return end
  if hud.resultTtl > 0 then
    hud.resultTtl = hud.resultTtl - dt
    if hud.resultTtl <= 0 then hud.result:SetVisible(false) end
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

-- 原版三套操控（frame_58 setupControls / constants.CONTROL_SCHEMES）对应的平台按键事件名。
--   方案 0（原版键码 83/69/70/68/81 = S/E/F/D + Q）：红方 / 1P。
--   方案 1（原版键码 37/38/39/40/77 = ←↑→↓ + M）：绿方 / 2P。
-- 平台 Enum.KeyboardKeyCode 表无字母 M（见《客户端控件API文档》），改用「.」(CraftspersonKey34) 替代。
local SCHEME_KEY = {
  [1] = {
    left = "KeyboardMoveBackwardKey",      -- S
    fwd  = "KeyboardCharacterSkill1Key",   -- E
    right = "KeyboardInteractKey",         -- F
    back = "KeyboardMoveRightKey",         -- D
    fire = "KeyboardCharacterSkill2Key",   -- Q
    fireLabel = "Q", hint = "S/E/F/D 移动 · Q 开火",
  },
  [2] = {
    left = "KeyboardCraftspersonKey38",    -- ←
    fwd  = "KeyboardCraftspersonKey36",    -- ↑
    right = "KeyboardCraftspersonKey39",   -- →
    back = "KeyboardCraftspersonKey37",    -- ↓
    fire = "KeyboardCraftspersonKey34",    -- .（替代原版 M）
    fireLabel = ".", hint = "方向键移动 · . 开火",
  },
}

local function setupInput()
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
  local function tankBind(ev, p, key)
    add(ev, true,  function() local pi = G.pinputs[p]; if pi ~= nil then pi[key] = true end end)
    add(ev, false, function() local pi = G.pinputs[p]; if pi ~= nil then pi[key] = false end end)
  end

  -- 菜单导航：W/S/A/D + 方向键
  menuBind("KeyboardMoveForwardKey",    "fwd")
  menuBind("KeyboardMoveBackwardKey",   "back")
  menuBind("KeyboardMoveLeftKey",       "left")
  menuBind("KeyboardMoveRightKey",      "right")
  menuBind("KeyboardCraftspersonKey36", "fwd")
  menuBind("KeyboardCraftspersonKey37", "back")
  menuBind("KeyboardCraftspersonKey38", "left")
  menuBind("KeyboardCraftspersonKey39", "right")
  -- 菜单确认：Q（红方开火键）/ 空格 / 鼠标左键
  menuBind("KeyboardCharacterSkill2Key", "fire")
  menuBind("KeyboardJumpKey",            "fire")
  menuBind("KeyboardNormalAttackKey",    "fire")

  -- 玩家坦克：按控制方案绑定（方案号与玩家号 1:1）
  for scheme = 1, #SCHEME_KEY do
    local sk = SCHEME_KEY[scheme]
    tankBind(sk.left,  scheme, "left")
    tankBind(sk.fwd,   scheme, "fwd")
    tankBind(sk.right, scheme, "right")
    tankBind(sk.back,  scheme, "back")
    tankBind(sk.fire,  scheme, "fire")
  end

  local okAny = false
  for ev, r in pairs(reg) do
    if eventType(ev .. "Down") ~= nil then
      okAny = true
      bindKey(ev .. "Down", function() for i = 1, #r.down do r.down[i]() end; return true end, ev)
      bindKey(ev .. "Up",   function() for i = 1, #r.up   do r.up[i]()   end; return true end, ev)
    else
      print("[坦克动荡] 运行时无此按键事件：" .. ev .. "（输入）")
    end
  end
  if not okAny then print("[坦克动荡] 未找到可用按键，请检查 Enum.KeyEventType") end
end

-- ============================================================
-- ⑯ 菜单 / 设置 / 关于
--   本地化说明（原版 → 本移植）：
--     联机对战   原版走 XMLSocket 连 5 台 .tanktrouble.com 服务器；
--                千星奇域内无法连外部服务器，改为本地单人对战 AI。
--     成就/统计  原版 Base64 混淆后 POST 到 pixvi.net；
--                改为本地累计与本地成就记录，不联网、不上传。
--     自定义迷宫 原版从外部迷宫数据源拉取；本地暂无数据源，仅「随机迷宫」生效。
--   以上三处均在界面与「关于」页明确标注，不做静默替代。
-- ============================================================
local MENU = {
  phase = "menu",           -- menu | ready | countdown | settings | about | playing
  lastPhase = nil,          -- 用于切页时清空输入边沿缓存
  back = "menu",            -- 从设置 / 关于返回的目标页
  sel = 1,                  -- 主菜单选中项
  setSel = 1,               -- 设置页选中行
  prev = { fwd = false, back = false, left = false, right = false, fire = false },
  panel = nil, hl = nil,
  menuTexts = {}, setTexts = {}, setLabels = {}, setValues = {},
  aboutTexts = {}, achTexts = {}, aboutStats = nil, aboutAch = nil,
  -- 准备页（原版 controls1Player / controls2Player / controls3Player / mode2）
  mode = "solo",            -- 本次对局的模式
  joined = {},              -- [n] = 该参战位是否已加入
  joinPrev = {},            -- [scheme] = 上一帧的开火状态（边沿检测）
  cdTick = 0, cdTimer = 0,  -- 倒计时：每 0.5s 一格，0→3、1→2、2→1、3→GO!
  readyTexts = {},          -- {1=标题, 2=副标题, 3=底部提示, 4=倒计时数字}
  readyRows = {},           -- { {swatch=, name=, act=}, ... }
}

local MENU_ITEMS = { "单人游戏（VS 莱卡）", "双人游戏", "设置", "关于 / 说明" }

-- 各模式参战位。scheme = 控制方案号（见 SCHEME_KEY），ai = 电脑接管。
-- 对应原版：frame_7（单人 = 红 vs 莱卡）、frame_19（双人 = 红 + 绿）。
local MODE_SLOTS = {
  solo = {
    { name = "玩家 1（红）", scheme = 1, color = COLOR.P1, ai = false },
    { name = "莱卡（电脑）",  scheme = nil, color = COLOR.AI, ai = true },
  },
  duo = {
    { name = "玩家 1（红）", scheme = 1, color = COLOR.P1, ai = false },
    { name = "玩家 2（绿）", scheme = 2, color = COLOR.P2, ai = false },
  },
}

-- 设置页行：迷宫来源 3 项 + 武器池 7 项 + 平滑碰撞，对应原版 settingsPanel 的滑块
local SET_ROWS = {
  { key = "playRandomMazes",      label = "迷宫来源 · 随机迷宫" },
  { key = "playMyCustomMazes",    label = "迷宫来源 · 我的自定义迷宫（无数据源）" },
  { key = "playOtherCustomMazes", label = "迷宫来源 · 他人迷宫（无数据源）" },
  { weapon = "laser",    label = "武器池 · 激光" },
  { weapon = "frag",     label = "武器池 · 破片弹" },
  { weapon = "gatling",  label = "武器池 · 加特林" },
  { weapon = "homing",   label = "武器池 · 追踪导弹" },
  { weapon = "deathRay", label = "武器池 · 死亡射线" },
  { weapon = "mine",     label = "武器池 · 地雷" },
  { weapon = "remote",   label = "武器池 · 遥控导弹" },
  { key = "useSmoothCollision",   label = "平滑碰撞（settingsUseSmoothCollision）" },
}

local ABOUT_LINES = {
  "坦克动荡 2 · 千星奇域还原版",
  "迷宫生成 / 坦克物理 / 9 种武器 / 敌方 AI / 回合结算",
  "均逐行对照 4399 Flash 版反编译源码移植，数值未改动。",
  "【本地化说明】",
  "· 原版「联机对战」依赖外部服务器，此处改为本地单人对战 AI。",
  "· 原版「成就与统计上传」依赖 pixvi.net，此处改为本地记录，不联网、不上传。",
  "· 原版「我的 / 他人自定义迷宫」依赖外部数据源，本地暂无，仅随机迷宫生效。",
  "【操作】红方（1P）：S/E/F/D 移动 · Q 开火；绿方（2P）：方向键移动 · . 开火；设置：R",
  "【准备流程】选模式 → 每位玩家按自己的开火键加入 → 3-2-1-GO 开始",
}

-- 本地成就（与 src/ach.lua 的 A.LIST 对齐为 7 条）
local ACH_LIST = {
  { id = 28, label = "连杀 AI 满 10 次" },
  { id = 35, label = "连杀 AI 满 25 次" },
  { id = 34, label = "在 AI 弹尽时将其击杀" },
  { id = 36, label = "激光不反弹直接命中 AI（需弹道信息，本地暂不适用）" },
  { id = 40, label = "赢得 1 个回合" },
  { id = 41, label = "累计击杀 50 次" },
  { id = 42, label = "累计完成 10 个回合" },
}

local function makeTextAt(x, y, w, size, text, align)
  local ctl = createControl(PREFAB.TEXT)
  if ctl == nil then return nil end
  -- 同上：先定尺寸，再写属性（自适应字号按当前尺寸估算）
  pcall(function() ctl:SetSizeDelta(w, size * 3) end)
  styleText(ctl, text, size, align)
  pcall(function() ctl:SetAnchoredPosition(x, y) end)
  return ctl
end

local function makeBar(x, y, w, h, color)
  local ctl = createControl(PREFAB.SQUARE)
  if ctl == nil then return nil end
  pcall(function()
    ctl:SetSizeDelta(w, h)
    ctl:SetAnchoredPosition(x, y)
    ctl.imageColor = color
  end)
  return ctl
end

local function buildMenuUI()
  MENU.panel = makeBar(0, 0, 900, 640, COLOR.PANEL)
  MENU.hl    = makeBar(0, 0, 460, 46, COLOR.SEL)

  -- 主菜单页
  MENU.menuTexts[1] = makeTextAt(0, 250, 860, 64, "坦克动荡")
  MENU.menuTexts[2] = makeTextAt(0, 186, 860, 22, "千星奇域还原版 · 单人 / 双人")
  MENU.menuTexts[3] = makeTextAt(0, 150, 860, 18, "原版「联机对战 / 成就上传」已本地化，详见「关于」", Enum.TextHorizontalAlignment.Middle)
  for i = 1, #MENU_ITEMS do
    MENU.menuTexts[3 + i] = makeTextAt(0, 74 - (i - 1) * 52, 460, 30, MENU_ITEMS[i])
  end
  MENU.menuTexts[3 + #MENU_ITEMS + 1] =
    makeTextAt(0, -244, 860, 20, "W / S 选择      空格 · Q · 左键 确认", Enum.TextHorizontalAlignment.Middle)

  -- 准备页（原版 controlsNPlayer）：标题 + 每个参战位一行（色块 / 名称 / 状态）
  MENU.readyTexts[1] = makeTextAt(0, 236, 860, 48, "准备")
  MENU.readyTexts[2] = makeTextAt(0, 176, 860, 20, "每位玩家按下自己的开火键加入", Enum.TextHorizontalAlignment.Middle)
  for i = 1, 2 do
    local y = 90 - (i - 1) * 120
    MENU.readyRows[i] = {
      swatch = makeBar(-390, y, 76, 76, COLOR.SEL),
      name   = makeTextAt(-210, y, 280, 26, "", Enum.TextHorizontalAlignment.Left),
      act    = makeTextAt(200, y, 480, 20, "", Enum.TextHorizontalAlignment.Left),
    }
  end
  MENU.readyTexts[3] = makeTextAt(0, -200, 860, 20, "全部加入后 3-2-1 开始      R 返回菜单", Enum.TextHorizontalAlignment.Middle)
  MENU.readyTexts[4] = makeTextAt(0, 0, 700, 130, "", Enum.TextHorizontalAlignment.Middle)

  -- 设置页
  MENU.setTexts[1] = makeTextAt(0, 262, 860, 40, "设置")
  for i = 1, #SET_ROWS do
    local y = 204 - (i - 1) * 34
    MENU.setLabels[i] = makeTextAt(-150, y, 560, 22, SET_ROWS[i].label, Enum.TextHorizontalAlignment.Left)
    MENU.setValues[i] = makeTextAt(340, y, 140, 22, "开", Enum.TextHorizontalAlignment.Right)
  end
  MENU.setTexts[2] = makeTextAt(0, -252, 860, 20, "W / S 选择      A / D 切换      R 返回", Enum.TextHorizontalAlignment.Middle)

  -- 关于页
  MENU.aboutTexts[1] = makeTextAt(0, 262, 860, 36, "关于 / 说明")
  for i = 1, #ABOUT_LINES do
    MENU.aboutTexts[1 + i] = makeTextAt(-320, 204 - (i - 1) * 30, 700, 18,
      ABOUT_LINES[i], Enum.TextHorizontalAlignment.Left)
  end
  MENU.aboutStats = makeTextAt(-320, -64, 700, 20, "", Enum.TextHorizontalAlignment.Left)
  MENU.aboutAch   = makeTextAt(-320, -98, 700, 20, "", Enum.TextHorizontalAlignment.Left)
  for i = 1, #ACH_LIST do
    MENU.achTexts[i] = makeTextAt(-320, -132 - (i - 1) * 28, 700, 18, "", Enum.TextHorizontalAlignment.Left)
  end
  MENU.aboutTexts[#ABOUT_LINES + 2] =
    makeTextAt(0, -266, 860, 18, "空格 / R 返回", Enum.TextHorizontalAlignment.Middle)
end

-- ---- 设置项读写 ----
local function weaponInPool(w)
  for i = 1, #C.SETTINGS.activeWeapons do
    if C.SETTINGS.activeWeapons[i] == w then return true end
  end
  return false
end

local function setRowValue(row)
  if row.weapon ~= nil then return weaponInPool(row.weapon) end
  return C.SETTINGS[row.key] == true
end

local function applySettings()
  -- 平滑碰撞对已存在的坦克立即生效（原版为构造时读取）
  for i = 1, #G.tanks do
    G.tanks[i].settingsUseSmoothCollision = C.SETTINGS.useSmoothCollision
  end
end

local function toggleRow(row)
  if row.weapon ~= nil then
    local list = C.SETTINGS.activeWeapons
    for i = 1, #list do
      if list[i] == row.weapon then table.remove(list, i); return end
    end
    list[#list + 1] = row.weapon
  else
    C.SETTINGS[row.key] = not C.SETTINGS[row.key]
  end
  applySettings()
end

local function updateAboutTexts()
  if MENU.aboutStats ~= nil then
    pcall(function()
      MENU.aboutStats.text = string.format(
        "本地战绩：击杀 %d · 死亡 %d · 获胜 %d 回合 · 完成 %d 回合",
        G.stats.kills, G.stats.deaths, G.stats.victories, G.stats.rounds)
    end)
  end
  if MENU.aboutAch ~= nil then
    local n = 0
    for i = 1, #ACH_LIST do
      if G.ach.unlocked[ACH_LIST[i].id] then n = n + 1 end
    end
    pcall(function()
      MENU.aboutAch.text = "本地成就（原版为联网上报，此处仅本地记录）：已达成 " .. n .. " / " .. #ACH_LIST
    end)
  end
  for i = 1, #ACH_LIST do
    local ctl = MENU.achTexts[i]
    if ctl ~= nil then
      local ok = G.ach.unlocked[ACH_LIST[i].id] == true
      pcall(function()
        ctl.text = (ok and "[已达成] " or "[未达成] ") .. ACH_LIST[i].id .. "  " .. ACH_LIST[i].label
        ctl.fontColor = ok and COLOR.OK or COLOR.DIM
      end)
    end
  end
end

-- 层级重排：本项目所有部件都实例化在同一个宿主控件下（同级），
-- 而引擎规则是「同级控件按创建顺序叠放，后创建的在上」（见官方文档 界面控件.md §四）。
-- 由于控件池复用，坦克部件可能比后建的墙 / 补给箱"资历更浅"而被压住 → 表现为隐形。
-- 这里在关键时机把各组控件自下而上 SetAsLastSibling()，固定最终叠放：
--   菜单 / HUD > 坦克 > 炮弹 / 特效 > 补给箱 > 墙 > 地板
local zorderBroken = false
applyZOrder = function()
  if zorderBroken then return end
  local ok = pcall(function()
    local function up(ctl)
      if ctl ~= nil then ctl:SetAsLastSibling() end
    end
    -- 抬起一组控件。列表元素有两种形态，必须区分：
    --   ①「部件表」{ ctl=控件, shape=…, lx=… }（vpart 产出，如 vis / baseArt / segs）→ 取 .ctl；
    --   ②「控件本身」（makeTextAt / makeText 直接返回的控件，如 MENU.menuTexts）→ 用它自身。
    -- 之前一律写 up(part.ctl)，对形态②恒为 nil → up(nil) 静默跳过，
    -- 导致菜单文字从未被抬起，而随后 up(MENU.panel) 把面板抬到最上层，
    -- 深色面板正好盖住所有菜单文字（主界面「有面板无字」的真根因）。
    local function upList(list)
      if list == nil then return end
      for i = 1, #list do
        local part = list[i]
        if part ~= nil then up(part.ctl or part) end
      end
    end

    -- ① 地板 → ② 墙（每步都抬到最上，故调用顺序即最终叠放顺序）
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
    -- ⑧ HUD
    up(hud.score); up(hud.weapon); up(hud.hint)
    -- ⑨ 菜单（面板 → 选中条 → 文字）
    up(MENU.panel); up(MENU.hl)
    upList(MENU.menuTexts); upList(MENU.setTexts)
    upList(MENU.setLabels); upList(MENU.setValues)
    upList(MENU.aboutTexts); upList(MENU.achTexts)
    up(MENU.aboutStats); up(MENU.aboutAch)
    -- 准备页 / 倒计时
    upList(MENU.readyTexts)
    for i = 1, #MENU.readyRows do
      local r = MENU.readyRows[i]
      up(r.swatch); up(r.name); up(r.act)
    end
  end)
  if not ok then
    zorderBroken = true
    printerr("[坦克动荡] SetAsLastSibling 不可用，层级重排已停用；"
      .. "请在编辑器「界面控件组管理」把本关卡改为【层级渲染(新)】并给模板配置层级")
  end
end

-- 准备页各行文本 / 色块刷新（前向声明，供 refreshMenu 引用）
local updateReadyRows

local function refreshMenu()
  local p = MENU.phase
  -- 切页时清空输入边沿缓存，避免上一页残留的按键状态造成误触发
  if MENU.lastPhase ~= p then
    MENU.lastPhase = p
    MENU.prev.fwd, MENU.prev.back, MENU.prev.left, MENU.prev.right, MENU.prev.fire =
      false, false, false, false, false
  end
  local function vis(ctl, v) if ctl ~= nil then pcall(function() ctl:SetVisible(v) end) end end

  vis(MENU.panel, p ~= "playing")
  -- HUD 仅对战期显示
  vis(hud.score, p == "playing")
  vis(hud.weapon, p == "playing")
  vis(hud.hint, p == "playing")

  local onMenu, onSet, onAbout = p == "menu", p == "settings", p == "about"
  for i = 1, #MENU.menuTexts do vis(MENU.menuTexts[i], onMenu) end
  for i = 1, #MENU.setTexts do vis(MENU.setTexts[i], onSet) end
  for i = 1, #SET_ROWS do vis(MENU.setLabels[i], onSet); vis(MENU.setValues[i], onSet) end
  for i = 1, #MENU.aboutTexts do vis(MENU.aboutTexts[i], onAbout) end
  vis(MENU.aboutStats, onAbout)
  vis(MENU.aboutAch, onAbout)
  for i = 1, #MENU.achTexts do vis(MENU.achTexts[i], onAbout) end

  -- 准备页 / 倒计时页
  local onReady, onCd = (p == "ready"), (p == "countdown")
  for i = 1, #MENU.readyTexts do
    local ctl = MENU.readyTexts[i]
    if i == 4 then vis(ctl, onCd) else vis(ctl, onReady) end
  end
  for i = 1, #MENU.readyRows do
    local r = MENU.readyRows[i]
    vis(r.swatch, onReady); vis(r.name, onReady); vis(r.act, onReady)
  end
  if onReady then updateReadyRows() end
  if onCd then
    local ctl = MENU.readyTexts[4]
    if ctl ~= nil then
      pcall(function() ctl.text = (MENU.cdTick >= 3) and "GO!" or tostring(3 - MENU.cdTick) end)
    end
  end

  vis(MENU.hl, onMenu or onSet)
  if onMenu then
    pcall(function()
      MENU.hl:SetSizeDelta(460, 46)
      MENU.hl:SetAnchoredPosition(0, 74 - (MENU.sel - 1) * 52)
    end)
    for i = 1, #MENU_ITEMS do
      local ctl = MENU.menuTexts[3 + i]
      if ctl ~= nil then
        pcall(function() ctl.fontColor = (i == MENU.sel) and COLOR.ACCENT or COLOR.TEXT end)
      end
    end
  end
  if onSet then
    pcall(function()
      MENU.hl:SetSizeDelta(790, 30)
      MENU.hl:SetAnchoredPosition(0, 204 - (MENU.setSel - 1) * 34)
    end)
    for i = 1, #SET_ROWS do
      local on = setRowValue(SET_ROWS[i])
      local ctl = MENU.setValues[i]
      if ctl ~= nil then
        pcall(function()
          ctl.text = on and "开" or "关"
          ctl.fontColor = on and COLOR.OK or COLOR.NO
        end)
      end
    end
  end
  if onAbout then updateAboutTexts() end
  -- 切页后把菜单控件重新抬到最上层（菜单控件创建最早，否则会被后建的坦克压住）
  applyZOrder()
end

-- 刷新准备页每一行：名称 / 操控说明 / 加入状态 / 色块。
-- 加入后该行的色块变成对应玩家色（对应原版 playerNControls.background.setRGB）。
updateReadyRows = function()
  local slots = MODE_SLOTS[MENU.mode] or MODE_SLOTS.solo
  for i = 1, #MENU.readyRows do
    local r = MENU.readyRows[i]
    local sl = slots[i]
    if sl == nil then
      pcall(function() r.name.text = "" end)
      pcall(function() r.act.text = "" end)
    else
      local sk = sl.scheme and SCHEME_KEY[sl.scheme] or nil
      local joined = (sl.ai == true) or (MENU.joined[i] == true)
      local ctlHint = sl.ai and "电脑操控" or ((sk and sk.hint) or "")
      local status
      if sl.ai then status = "已加入"
      elseif joined then status = "已加入"
      else status = "按 " .. ((sk and sk.fireLabel) or "?") .. " 加入" end
      pcall(function() r.name.text = sl.name end)
      pcall(function()
        r.act.text = status .. "    " .. ctlHint
        r.act.fontColor = joined and COLOR.OK or COLOR.ACCENT
        r.swatch.imageColor = joined and sl.color or COLOR.SEL
      end)
    end
  end
end

local function openPage(name, back)
  MENU.back = back or MENU.phase
  MENU.phase = name
  refreshMenu()
end

-- 按模式配置每辆坦克：控制方案 / 是否人类 / 车体色 / 是否 AI（莱卡）。
-- 对应原版 frame_7（单人：红 vs 莱卡）、frame_19（双人：红 vs 绿）。
local function applyMode(mode)
  G.mode = mode
  local slots = MODE_SLOTS[mode] or MODE_SLOTS.solo
  for i = 1, #G.tanks do
    local t = G.tanks[i]
    local sl = slots[i]
    if sl == nil then
      t.baseColor, t.turretColor = COLOR.AI, COLOR.AI
      t.controlIndex, t.isPlayer, t.ai = nil, false, true
    else
      t.baseColor, t.turretColor = sl.color, sl.color
      t.controlIndex = sl.scheme
      t.isPlayer = (sl.scheme ~= nil)
      t.ai = sl.ai and true or nil
      t.aiName = sl.name
    end
    -- 颜色变了，重建车体 / 炮塔美术
    buildBaseArt(t)
    buildTurretArt(t)
  end
  if hud.hint ~= nil then
    local s = (mode == "duo")
      and "红方 S/E/F/D + Q    绿方 方向键 + .    设置：R"
      or  "S/E/F/D 移动 · Q 开火    设置：R"
    pcall(function() hud.hint.text = s end)
  end
end

-- 进入准备页（原版 controlsNPlayer）。快照各玩家开火状态，避免「按着开火键进页」被判定为已加入。
local function beginReady(mode)
  MENU.mode = mode
  MENU.back = "menu"
  MENU.phase = "ready"
  MENU.joined, MENU.joinPrev = {}, {}
  local slots = MODE_SLOTS[mode] or MODE_SLOTS.solo
  for n = 1, #slots do
    local sl = slots[n]
    MENU.joined[n] = (sl.ai == true)
    if sl.scheme ~= nil then
      local pin = G.pinputs[sl.scheme]
      MENU.joinPrev[sl.scheme] = (pin ~= nil and pin.fire) or false
    end
  end
  MENU.prev.fire = G.input.fire
  updateReadyRows()
  refreshMenu()
end

-- 3-2-1-GO 倒计时（原版 generateMasterMazeAndStartCountdown：500ms 一格）
local function beginCountdown()
  MENU.phase = "countdown"
  MENU.cdTick = 0
  MENU.cdTimer = 0
  refreshMenu()
end

-- 倒计时结束 → 应用模式并开始首回合
local function beginMatch()
  applyMode(MENU.mode)
  G.accum = 0
  -- 进入对局前清空所有开火状态：开火键同时是「加入/确认」键，
  -- 若不清除，首帧会立刻开炮。记录为「按下」使对局中必须重新抬手再按。
  G.input.fire = false
  for i = 1, #G.pinputs do G.pinputs[i].fire = false end
  MENU.prev.fire = true
  MENU.phase = "playing"
  audioApi.setBgm("battle")
  startNewRound()
  refreshMenu()
end

local function stepMenuInput(dt)
  local i, pv = G.input, MENU.prev
  local up      = i.fwd   and not pv.fwd
  local down    = i.back  and not pv.back
  local left    = i.left  and not pv.left
  local right   = i.right and not pv.right
  local confirm = i.fire  and not pv.fire
  pv.fwd, pv.back, pv.left, pv.right, pv.fire = i.fwd, i.back, i.left, i.right, i.fire

  local ph = MENU.phase
  if ph == "menu" then
    if up then MENU.sel = MENU.sel - 1; if MENU.sel < 1 then MENU.sel = #MENU_ITEMS end end
    if down then MENU.sel = MENU.sel + 1; if MENU.sel > #MENU_ITEMS then MENU.sel = 1 end end
    if up or down then refreshMenu() end
    if confirm then
      if MENU.sel == 1 then beginReady("solo")
      elseif MENU.sel == 2 then beginReady("duo")
      elseif MENU.sel == 3 then openPage("settings", "menu")
      else openPage("about", "menu") end
    end
  elseif ph == "ready" then
    -- 每位玩家按自己的开火键加入（原版：P1 按 Q、P2 按 M）；AI 位视为已加入
    local slots = MODE_SLOTS[MENU.mode] or MODE_SLOTS.solo
    local allJoined = true
    for n = 1, #slots do
      local sl = slots[n]
      if sl.scheme ~= nil then
        local pin = G.pinputs[sl.scheme]
        local now = (pin ~= nil and pin.fire) or false
        if now and not MENU.joinPrev[sl.scheme] then
          MENU.joined[n] = true
          updateReadyRows()
        end
        MENU.joinPrev[sl.scheme] = now
      end
      if MENU.joined[n] ~= true then allJoined = false end
    end
    if allJoined then beginCountdown() end
  elseif ph == "countdown" then
    MENU.cdTimer = MENU.cdTimer + (dt or 0)
    while MENU.cdTimer >= 0.5 do
      MENU.cdTimer = MENU.cdTimer - 0.5
      MENU.cdTick = MENU.cdTick + 1
      if MENU.cdTick >= 4 then beginMatch(); return end
    end
    local ctl = MENU.readyTexts[4]
    if ctl ~= nil then
      pcall(function() ctl.text = (MENU.cdTick >= 3) and "GO!" or tostring(3 - MENU.cdTick) end)
    end
  elseif ph == "settings" then
    if up then MENU.setSel = MENU.setSel - 1; if MENU.setSel < 1 then MENU.setSel = #SET_ROWS end end
    if down then MENU.setSel = MENU.setSel + 1; if MENU.setSel > #SET_ROWS then MENU.setSel = 1 end end
    if left or right then toggleRow(SET_ROWS[MENU.setSel]) end
    if up or down or left or right then refreshMenu() end
  elseif ph == "about" then
    if confirm then openPage(MENU.back or "menu") end
  end
end

-- 设置键：对战期打开设置（暂停），设置/关于/准备页返回。多候选键，取运行时第一个可用的。
local function onMenuKey()
  local ph = MENU.phase
  if ph == "playing" then
    MENU.back = "playing"
    MENU.phase = "settings"
  elseif ph == "settings" or ph == "about" then
    MENU.phase = MENU.back or "menu"
  elseif ph == "ready" or ph == "countdown" then
    MENU.phase = "menu"
  else
    MENU.back = "menu"
    MENU.phase = "settings"
  end
  refreshMenu()
end

local function bindMenuKey()
  local candidates = {
    "KeyboardCharacterSkill3KeyDown",   -- R
    "KeyboardCraftspersonKey14Down",    -- G
    "KeyboardCraftspersonKey29Down",    -- \
  }
  for i = 1, #candidates do
    if eventType(candidates[i]) ~= nil then
      if bindKey(candidates[i], onMenuKey, "设置") then
        print("[坦克动荡] 设置键：" .. candidates[i])
        return
      end
    end
  end
  print("[坦克动荡] 未找到可用的设置键")
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
-- ⑰ 生命周期
-- ============================================================
function OnInit()
  pcall(function() math.randomseed(os.time()) end)
  host = script.object
  print("[坦克动荡] OnInit，宿主类型=" .. typeof(host))
  if host == nil then
    printerr("[坦克动荡] script.object 为空，请确认脚本挂在容器控件上")
  end
end

function OnStart()
  if host == nil then return end
  pcall(function() host.disableKeyEventPassthrough = true end)
  selfCheckPrefabs()
  bindAudioBackend()
  bindNet()
  audioApi.setBgm("menu")

  -- 全屏遮罩（盖住场景草地）
  local cover = createControl(PREFAB.SQUARE)
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
  -- 默认单人（红 vs 莱卡）；真正开赛时由 beginMatch 调用 applyMode 按所选模式重配
  setupHUD()
  applyMode("solo")
  setupInput()
  buildMenuUI()
  bindMenuKey()
  refreshMenu()
  -- 把自检探针抬到最上层：它在本函数最开头创建，会被后建的菜单面板/文字压住而看不见。
  -- 探针存活约 1 秒（见 OnLevelUpdate），用于肉眼确认「文本框能否显示」。
  if G.textProbe ~= nil then
    pcall(function() G.textProbe:SetAsLastSibling() end)
  end
  G.running = true
  print("[坦克动荡] OnStart 完成：进入主菜单（W/S 选择，空格/Q/左键 确认）")
  script:EnableUpdate(true)
end

function OnEnable() print("[坦克动荡] OnEnable") end
function OnDisable() print("[坦克动荡] OnDisable") end
function OnUpdate() end

function OnLevelUpdate(dt)
  if not G.running or host == nil then return end
  dt = min(dt, 0.25)
  audioClock = audioClock + dt
  stepResult(dt)
  -- 自检探针：存活约 1 秒供肉眼确认，到时销毁
  if G.textProbe ~= nil then
    G.textProbeTtl = (G.textProbeTtl or 0) - dt
    if G.textProbeTtl <= 0 then
      pcall(function() game.DestroyClientUIControl(G.textProbe) end)
      G.textProbe = nil
    end
  end
  if MENU.phase == "playing" then
    G.accum = G.accum + dt
    local steps = 0
    while G.accum >= CFG.FRAME_DT and steps < CFG.MAX_STEPS do
      G.accum = G.accum - CFG.FRAME_DT
      steps = steps + 1
      stepFrame()
    end
    if steps >= CFG.MAX_STEPS then G.accum = 0 end
  else
    -- 菜单 / 准备 / 倒计时 / 设置 / 关于：只处理导航，不推进世界（等价于原版的暂停）
    stepMenuInput(dt)
  end
end

function OnDestroy()
  print("[坦克动荡] OnDestroy")
  G.running = false
  for i = 1, #G.tanks do disposeTank(G.tanks[i]) end
  clearProjectiles()
  clearCrates()
  clearEffects()
  vfree(G.wallParts)
  G.wallParts = {}
end