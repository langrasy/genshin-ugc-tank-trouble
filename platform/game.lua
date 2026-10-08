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

  美术：仅用编辑器自带的「白色方块」「白色圆形」两个模板 + 文本框模板，
        运行时靠拉伸 / 旋转 / 上色 / 多控件拼接画出全部对象（不依赖任何外部贴图）。
]]

local C        = require("src.constants")
local mazeApi  = require("src.maze")
local tankApi  = require("src.tank")
local weaponsApi = require("src.weapons")
local aiApi    = require("src.ai")
local roundApi = require("src.round")

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

-- ============================================================
-- ① 模板 / 参数 / 颜色
-- ============================================================
local PREFAB = {
  SQUARE = 1073741868,   -- 白色方块（Stretch）：墙 / 车体 / 履带 / 炮管 / 补给箱 / 遮罩
  CIRCLE = 1073741869,   -- 白色圆形（Stretch）：炮塔 / 炮弹 / 地雷 / 导弹头 / 高光
  TEXT   = 1073741871,   -- 文本框模板
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
  CRATE_R    = 0.75,     -- 补给箱世界尺寸 = SCALE*该系数
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
  FLOOR    = col(46, 50, 58),
  FLOOR_LN = col(56, 60, 70),
  WALL     = col(126, 136, 150),
  WALL_TOP = col(170, 179, 190),
  WALL_DIP = col(78, 85, 96),
  P1       = col(224, 82, 70),
  P2       = col(87, 184, 88),
  P3       = col(86, 140, 224),
  P4       = col(226, 180, 70),
  SHOT     = col(255, 214, 140),
  TEXT     = col(245, 245, 245),
  OUTLINE  = col(18, 18, 22),
  CRATE    = col(196, 150, 84),
  CRATE_B  = col(120, 86, 46),
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
local pool = { square = {}, circle = {} }

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
  return ctl --[[@as ClientUIControl]]
end

local function acquire(shape)
  local list = pool[shape]
  local ctl = table.remove(list)
  if ctl == nil then
    ctl = createControl(shape == "circle" and PREFAB.CIRCLE or PREFAB.SQUARE)
    if ctl == nil then return nil end
    pcall(function()
      ctl.imageType = Enum.ImageType.Stretch
      ctl:SetVisible(false)
    end)
  else
    pcall(function() ctl:SetVisible(true) end)
  end
  return ctl
end

local function release(shape, ctl)
  if ctl == nil then return end
  pcall(function() ctl:SetVisible(false) end)
  pool[shape][#pool[shape] + 1] = ctl
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
  input = { fwd = false, back = false, left = false, right = false, fire = false },
  accum = 0, running = false,
  -- 本地战绩（原版为上传到 pixvi.net 的统计，此处只本地累计）
  stats = { kills = 0, deaths = 0, victories = 0, rounds = 0, selfKills = 0 },
  -- 本地成就（原版通过 achievement.php 上报，此处只本地记录）
  ach = { unlocked = {}, consecutive = 0 },
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
  local c = p.color or COLOR.SHOT
  if p.kind == "bullet" or p.kind == "electric" then
    parts[#parts + 1] = vpart("circle", 10 * k, 10 * k, c, 0, 0, 0)
    parts[#parts + 1] = vpart("circle", 4 * k, 4 * k, shade(c, 1.5), 0, 0, 0)
  elseif p.kind == "gatlingBullet" then
    parts[#parts + 1] = vpart("circle", 8 * k, 8 * k, c, 0, 0, 0)
  elseif p.kind == "fragment" then
    parts[#parts + 1] = vpart("square", 5 * k, 5 * k, c, 0, 0, 0)
  elseif p.kind == "homing" or p.kind == "remote" then
    parts[#parts + 1] = vpart("square", 9 * k, 22 * k, c, 0, 0, 0)
    parts[#parts + 1] = vpart("circle", 10 * k, 10 * k, shade(c, 1.25), 0, -12 * k, 0)
    parts[#parts + 1] = vpart("square", 16 * k, 4 * k, shade(c, 0.7), 0, 11 * k, 0)
  elseif p.kind == "mine" then
    local d = 50 * (p.scaleFactor or 0.2)
    parts[#parts + 1] = vpart("circle", d, d, c, 0, 0, 0)
    parts[#parts + 1] = vpart("circle", d * 0.5, d * 0.5, shade(c, 0.6), 0, 0, 0)
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
local function spawnEffect(kind, x, y, color, size, life, vx, vy)
  local e = {
    kind = kind, x = x, y = y, vx = vx or 0, vy = vy or 0,
    life = life, lifeMax = life, color = color, size = size, rot = 0,
  }
  e.vis = { vpart(kind == "smoke" and "circle" or "square", size, size, color, 0, 0, 0) }
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
      local a = floor(255 * (e.life / e.lifeMax))
      local p = e.vis[1]
      if p ~= nil then
        p.ctl.imageColor = alphaOf(e.color, a)
        local ux, uy = toUI(e.x, e.y)
        p.ctl:SetAnchoredPosition(ux, uy)
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
      5 * k, 10 + floor(math.random() * 8), cos(ang) * sp, sin(ang) * sp)
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

local SOUND_IDS = {}   -- 音效 ID 由编辑器配置，这里按名称占位（未配置则静默）
function playSound(name)
  local id = SOUND_IDS[name]
  if id ~= nil then pcall(game.PlayAudio2D, id) end
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
  for _ = 1, 14 do
    local ang = math.random() * 2 * PI
    local sp = (1 + math.random() * 3) * k
    spawnEffect("frag", victim.x, victim.y, shade(victim.baseColor, 1.1),
      6 * k, 12 + floor(math.random() * 10), cos(ang) * sp, sin(ang) * sp)
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

local function trySpawnCrate()
  local pos = roundApi.pickCratePos(ctx)
  if pos == nil then return end
  local cell = G.reachable[pos]
  if cell == nil then return end
  cell.used = true
  local weapon = roundApi.pickCrateWeapon(C.SETTINGS.activeWeapons)
  if weapon == nil then cell.used = false; return end
  local s = G.scale
  local crate = {
    x = (cell.x + 0.5) * s, y = (cell.y + 0.5) * s,
    weapon = weapon, cell = cell,
    anim = 0,
  }
  local r = s * CFG.CRATE_R
  crate.vis = {
    vpart("square", r * 2, r * 2, COLOR.CRATE, 0, 0, 0),
    vpart("square", r * 0.28, r * 2, COLOR.CRATE_B, 0, 0, 0),
    vpart("square", r * 2, r * 0.28, COLOR.CRATE_B, 0, 0, 0),
    vpart("circle", r * 0.7, r * 0.7, shade(COLOR.CRATE, 1.3), 0, 0, 0),
  }
  G.crates[#G.crates + 1] = crate
end

local function syncCrates()
  for i = #G.crates, 1, -1 do
    local c = G.crates[i]
    -- 拾取判定
    local picked = roundApi.tryPickup(c, G.tanks, {
      boxContains = function(t, px, py) return ctx.tankBBoxContains(t, px, py) end,
      corners = function(t, cr)
        local r = G.scale * CFG.CRATE_R * 0.8
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
      if c.anim < 1 then c.anim = min(1, c.anim + 0.15) end
      local sc = 0.4 + 0.6 * c.anim
      local ux, uy = toUI(c.x, c.y)
      for j = 1, #c.vis do
        local p = c.vis[j]
        p.ctl:SetAnchoredPosition(ux, uy)
        p.ctl:SetLocalRotation(0, 0, -(1 - c.anim) * 120)
        p.ctl:SetSizeDelta(p.ctl.sizeDeltaX or 0, p.ctl.sizeDeltaY or 0)
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
  if t.isPlayer then
    t.forward = G.input.fwd
    t.backup = G.input.back
    t.turnLeft = G.input.left
    t.turnRight = G.input.right
    fire = G.input.fire
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
    G.stats.rounds = G.stats.rounds + 1
    if pl ~= nil and pl.alive then G.stats.victories = G.stats.victories + 1 end
    clearProjectiles()
    clearCrates()
    updateScoreHUD()
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
end

-- ============================================================
-- ⑭ HUD
-- ============================================================
local hud = {}

local function makeText(y, size, text)
  local ctl = createControl(PREFAB.TEXT)
  if ctl == nil then return nil end
  pcall(function()
    ctl:SetSizeDelta(600, size * 2)
    ctl:SetAnchoredPosition(0, y)
    ctl.text = text
    ctl.fontSize = size
    ctl.fontColor = COLOR.TEXT
    ctl.enableOutline = true
    ctl.outlineColor = COLOR.OUTLINE
    ctl.horizontalAlignment = Enum.TextHorizontalAlignment.Middle
  end)
  return ctl
end

function updateScoreHUD()
  if hud.score ~= nil then
    local a = G.tanks[1]
    local b = G.tanks[2]
    local sa = a and a.score or 0
    local sb = b and b.score or 0
    pcall(function() hud.score.text = "红 " .. sa .. "   :   " .. sb .. " 绿" end)
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
  hud.hint = makeText(stageY(-20), 20, "WASD / 方向键 移动    Q / 空格 开火")
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

local function setInput(key, v)
  return function() G.input[key] = v; return true end
end

local function setupInput()
  local binds = {
    { "KeyboardMoveForwardKeyDown",  "KeyboardMoveForwardKeyUp",  "fwd" },
    { "KeyboardMoveBackwardKeyDown", "KeyboardMoveBackwardKeyUp", "back" },
    { "KeyboardMoveLeftKeyDown",     "KeyboardMoveLeftKeyUp",     "left" },
    { "KeyboardMoveRightKeyDown",    "KeyboardMoveRightKeyUp",    "right" },
    { "KeyboardCraftspersonKey36Down", "KeyboardCraftspersonKey36Up", "fwd" },
    { "KeyboardCraftspersonKey37Down", "KeyboardCraftspersonKey37Up", "back" },
    { "KeyboardCraftspersonKey38Down", "KeyboardCraftspersonKey38Up", "left" },
    { "KeyboardCraftspersonKey39Down", "KeyboardCraftspersonKey39Up", "right" },
  }
  for i = 1, #binds do
    local b = binds[i]
    bindKey(b[1], setInput(b[3], true), b[3])
    bindKey(b[2], setInput(b[3], false), b[3])
  end

  local fireDown = { "KeyboardCharacterSkill2KeyDown", "KeyboardNormalAttackKeyDown",
                     "KeyboardJumpKeyDown" }
  local fireUp = { "KeyboardCharacterSkill2KeyUp", "KeyboardNormalAttackKeyUp",
                   "KeyboardJumpKeyUp" }
  local ok = false
  for i = 1, #fireDown do
    if eventType(fireDown[i]) ~= nil then
      ok = bindKey(fireDown[i], setInput("fire", true), "开火")
      if ok and eventType(fireUp[i]) ~= nil then
        bindKey(fireUp[i], setInput("fire", false), "开火抬起")
      end
      if ok then break end
    end
  end
  if not ok then print("[坦克动荡] 未找到可用开火键，请检查 Enum.KeyEventType") end
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
  phase = "menu",           -- menu | settings | about | playing
  lastPhase = nil,          -- 用于切页时清空输入边沿缓存
  back = "menu",            -- 从设置 / 关于返回的目标页
  sel = 1,                  -- 主菜单选中项
  setSel = 1,               -- 设置页选中行
  prev = { fwd = false, back = false, left = false, right = false, fire = false },
  panel = nil, hl = nil,
  menuTexts = {}, setTexts = {}, setLabels = {}, setValues = {},
  aboutTexts = {}, achTexts = {}, aboutStats = nil, aboutAch = nil,
}

local MENU_ITEMS = { "开始游戏", "设置", "关于 / 说明" }

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
  "【操作】WASD / 方向键 移动    空格 / Q / 左键 开火    R 设置",
}

-- 本地成就（对应原版 28 / 35 / 34 / 36；其余为联机或鼠标操控专属，本地不适用）
local ACH_LIST = {
  { id = 28, label = "连杀 AI 满 10 次" },
  { id = 35, label = "连杀 AI 满 25 次" },
  { id = 34, label = "在 AI 弹尽时将其击杀" },
  { id = 36, label = "激光不反弹直接命中 AI（需弹道信息，本地暂不适用）" },
}

local function makeTextAt(x, y, w, size, text, align)
  local ctl = createControl(PREFAB.TEXT)
  if ctl == nil then return nil end
  pcall(function()
    ctl:SetSizeDelta(w, size * 2)
    ctl:SetAnchoredPosition(x, y)
    ctl.text = text
    ctl.fontSize = size
    ctl.fontColor = COLOR.TEXT
    ctl.enableOutline = true
    ctl.outlineColor = COLOR.OUTLINE
    ctl.horizontalAlignment = align or Enum.TextHorizontalAlignment.Middle
  end)
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
  MENU.menuTexts[2] = makeTextAt(0, 186, 860, 22, "千星奇域还原版 · 单人对战 AI")
  MENU.menuTexts[3] = makeTextAt(0, 150, 860, 18, "原版「联机对战 / 成就上传」已本地化，详见「关于」", Enum.TextHorizontalAlignment.Middle)
  for i = 1, #MENU_ITEMS do
    MENU.menuTexts[3 + i] = makeTextAt(0, 74 - (i - 1) * 52, 460, 30, MENU_ITEMS[i])
  end
  MENU.menuTexts[3 + #MENU_ITEMS + 1] =
    makeTextAt(0, -244, 860, 20, "W / S 选择      空格 · Q · 左键 确认", Enum.TextHorizontalAlignment.Middle)

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
end

local function openPage(name, back)
  MENU.back = back or MENU.phase
  MENU.phase = name
  refreshMenu()
end

local function startPlaying()
  MENU.phase = "playing"
  G.accum = 0
  startNewRound()
  refreshMenu()
end

local function stepMenuInput()
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
      if MENU.sel == 1 then startPlaying()
      elseif MENU.sel == 2 then openPage("settings", "menu")
      else openPage("about", "menu") end
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

-- 设置键：对战期打开设置（暂停），设置/关于页返回。多候选键，取运行时第一个可用的。
local function onMenuKey()
  local ph = MENU.phase
  if ph == "playing" then
    MENU.back = "playing"
    MENU.phase = "settings"
  elseif ph == "settings" or ph == "about" then
    MENU.phase = MENU.back or "menu"
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
    "KeyboardInteractKeyDown",          -- F
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

-- 击杀登记 → 本地战绩 + 本地成就（原版 registerHit / unlockAchievement 的本地等价）
registerKill = function(victim, source)
  if victim == nil or source == nil then return end
  local player = G.tanks[G.playerIndex]
  if player == nil then return end
  if source == player then
    G.stats.kills = G.stats.kills + 1
    if victim.ai then
      G.ach.consecutive = (G.ach.consecutive or 0) + 1
      if G.ach.consecutive >= 10 then G.ach.unlocked[28] = true end
      if G.ach.consecutive >= 25 then G.ach.unlocked[35] = true end
      -- 34：AI 普通弹打光（bulletsFired 达上限）时将其击杀
      if victim.currentWeapon == "bullet"
         and (victim.bulletsFired or 0) >= C.SETTINGS.maxBullets then
        G.ach.unlocked[34] = true
      end
    else
      G.ach.consecutive = 0
    end
  elseif victim == player then
    G.stats.deaths = G.stats.deaths + 1
    G.ach.consecutive = 0
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
  for i = 1, #G.tanks do
    if not G.tanks[i].isPlayer then G.tanks[i].ai = true end
  end

  setupHUD()
  setupInput()
  buildMenuUI()
  bindMenuKey()
  refreshMenu()
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
    -- 菜单 / 设置 / 关于：只处理导航，不推进世界（等价于原版的暂停）
    stepMenuInput()
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