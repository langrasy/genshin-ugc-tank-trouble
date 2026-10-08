--[[
  坦克动荡（千星奇域小游戏）—— 单文件产物
  本文件由 tools\bundle.ps1 自动生成，请勿手改。
  修改逻辑请改 src/*.lua；修改平台层请改 platform/game.lua；然后重新打包。
]]

-- ==================== 模块注册表 / require 垫片 ====================
local __defs, __cache = {}, {}
local function require(name)
  local cached = __cache[name]
  if cached ~= nil then return cached end
  local loader = __defs[name]
  if loader == nil then error("模块未找到: " .. tostring(name)) end
  local mod = loader()
  __cache[name] = mod
  return mod
end

-- ==================== 模块 src.constants ====================
__defs["src.constants"] = function()
--[[
  坦克动荡2 —— 权威常量表
  来源：反编译源码 frame_53/DoAction.as 尾部常量区（第 2297-2393 行）与 frame_1/DoAction.as 设置区。
  说明：所有数值照抄原版，未做任何"平衡性"改动。
        原版中随迷宫格子大小等比缩放的量（如 *_xscale）在移植层按 SCALE 换算，此处只保留基准常量。
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
C.REMOTESIGNALSIZE         = 70

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
C.NUMBEROFFRAGMENTS        = 8
C.NUMBEROFSMOKECLOUDS      = 10
C.NUMBEROFPUFFCLOUDS       = 0
C.NUMBEROFDUSTCLOUDS       = 20
C.NUMBEROFFRAMESBEFOREEND  = 125
C.NUMBEROFFRAMESFROZEN     = 50
C.NUMBEROFFRAMESBEFORERESET = 5

C.FRAGFRAGMENTS            = 40
C.FRAGSMOKECLOUDS          = 10
C.FRAGLEVELS               = 1

-- ============================================================
-- 6. El Toro（蛮牛冲刺装备）
-- ============================================================
C.ELTOROCHARGETIME         = 10
C.ELTOROSNORTTIME          = 5
C.ELTORONUMBEROFSNORTS     = 15
C.ELTORORUNTIME            = 15
C.ELTOROSIZE               = 5

-- ============================================================
-- 7. 护盾 / 震屏 / 死胡同
-- ============================================================
C.SHIELDSIZE               = 70
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
  playRandomMazes    = true,
  playMyCustomMazes  = true,
  playOtherCustomMazes = false,
  useNewMouseControl = false,
  useSmoothCollision = true,
}

-- ============================================================
-- 9. 键位（frame_53 deployTank：controlNum 0/1/2 三套）
--    Flash keyCode：W83 A65 S83? 原版为 D68 F70 E69 Q81 等，见下
-- ============================================================
-- 注意：原版直接写 keyCode 数字。此处保留原始键码，供平台层映射。
C.CONTROL_SCHEMES = {
  -- controlNum 0：方向键组（左 S83? 见原文：LEFT=83 FORWARD=69 TURNRIGHT=70 BACKUP=68 FIRE=81）
  { turnLeft = 83, forward = 69, turnRight = 70, backup = 68, fire = 81, mouse = false },
  -- controlNum 1：WASD 组（LEFT=37 FORWARD=38 TURNRIGHT=39 BACKUP=40 FIRE=77）
  { turnLeft = 37, forward = 38, turnRight = 39, backup = 40, fire = 77, mouse = false },
  -- controlNum 2：鼠标操控
  { mouse = true },
}

-- ============================================================
-- 10. 武器 / 装备名称集合（供逻辑分支复用）
-- ============================================================
C.WEAPONS = {
  "bullet", "laser", "frag", "gatling", "homing",
  "mine", "remote", "deathRay", "elToro", "electric",
}
C.EQUIPMENTS = { "none", "aimer", "shield", "elToro" }

return C
end

-- ==================== 模块 src.maze ====================
__defs["src.maze"] = function()
--[[
  坦克动荡2 —— 迷宫生成与寻路（纯逻辑，可脱离游戏运行时单测）
  逐行对照 frame_53/DoAction.as 第 1-594 行移植，算法与常量保持原样。

  数据结构（与原版一致，0 基索引）：
    maze.W, maze.H            迷宫宽/高（格子数）
    maze[x][y]                x∈[0,W-1], y∈[0,H-1]
    maze[x][y].s              通路标记，恒为 1（对应原 Array 第 0 元素）
    maze[x][y].yw             y 方向墙：0=可上下通行，1=有墙（对应原 Array 第 1 元素）
    maze[x][y].xw             x 方向墙：0=可左右通行，1=有墙（对应原 Array 第 2 元素）

  原版用 new Array(1, a, b) 构造，元素落在下标 0/1/2，故此处用命名键避免索引错位。
]]

local C = require("src.constants")

local M = {}

local floor, min, max, sqrt, abs = math.floor, math.min, math.max, math.sqrt, math.abs

-- 原版 ActionScript 中 0 为"假"，undefined 也为"假"；Lua 中 0 为"真"。
-- findDeadEnds 依赖该语义，故统一用此判定。
local function falsy(v)
  return v == nil or v == 0
end

local function new2d(w, h)
  local t = {}
  for x = 0, w - 1 do
    local col = {}
    for y = 0, h - 1 do
      col[y] = nil
    end
    t[x] = col
  end
  return t
end

-- ActionScript 2.0 中越界访问（如 maze[W] 或 maze[x][-1]）返回 undefined，
-- 后续 `.xw == 0` 比较为 false 而不报错。原版大量依赖该行为（先取墙再判边界）。
-- Lua 索引 nil 会报错，故为迷宫挂"安全索引"：越界一律返回一个无字段的单元格，
-- 使 `.xw`/`.yw` 为 nil（≠0），语义与原版完全一致。
local NIL_CELL = {}
local SAFE_COL = setmetatable({}, { __index = function() return NIL_CELL end })

function M.wrap(maze)
  for x = 0, maze.W - 1 do
    setmetatable(maze[x], { __index = function() return NIL_CELL end })
  end
  setmetatable(maze, { __index = function() return SAFE_COL end })
  return maze
end

-- 迷宫像素缩放：SCALE = min((MOVIEHEIGHT-HEIGHTTOBOTTOM)/(H+0.125), MOVIEWIDTH/(W+0.125))
function M.computeScale(w, h)
  return min((C.MOVIEHEIGHT - C.HEIGHTTOBOTTOM) / (h + 0.125), C.MOVIEWIDTH / (w + 0.125))
end

-- ============================================================
-- createMaze(xsize, ysize)  —— frame_53 第 1-45 行
-- rng：可选，返回 [0,1) 的函数；默认 math.random
-- ============================================================
function M.createMaze(xsize, ysize, rng)
  rng = rng or math.random

  -- tempmaze[x][y]，x∈[0,xsize]，y∈[0,ysize]，随机 0..3
  local tempmaze = {}
  for x = 0, xsize do
    local col = {}
    for y = 0, ysize do
      col[y] = floor(rng() * 4)
    end
    tempmaze[x] = col
  end

  local maze = { W = xsize, H = ysize }
  for x = 0, xsize - 1 do
    local col = {}
    for y = 0, ysize - 1 do
      local a = (tempmaze[x][y + 1] == 2) or (tempmaze[x + 1][y + 1] == 0)  -- y 方向隔断
      local b = (tempmaze[x][y] == 1) or (tempmaze[x][y + 1] == 3)          -- x 方向隔断
      col[y] = { s = 1, yw = (not a) and 0 or 1, xw = (not b) and 0 or 1 }
    end
    maze[x] = col
  end
  return M.wrap(maze)
end

-- ============================================================
-- calcReachable(maze, startx, starty) —— frame_53 第 46-100 行
-- 返回 reachable（可达格坐标列表，含 .used 字段）与 reachableIndex[x][y]
-- ============================================================
function M.calcReachable(maze, startx, starty)
  local W, H = maze.W, maze.H
  local reachableIndex = new2d(W, H)
  local visited = {}   -- 以 x + y*W 为键
  local reachable = {}
  local stack = { { x = startx, y = starty } }

  while #stack > 0 do
    local p = table.remove(stack)          -- pop
    local x, y = p.x, p.y
    reachableIndex[x][y] = #reachable      -- 先记序号，再入列表
    reachable[#reachable + 1] = p
    visited[x + y * W] = true

    if maze[x][y].xw == 0 and x > 0 then
      if visited[x - 1 + y * W] == nil then
        visited[x - 1 + y * W] = true
        stack[#stack + 1] = { x = x - 1, y = y }
      end
    end
    if maze[x + 1][y].xw == 0 and x < W - 1 then
      if visited[x + 1 + y * W] == nil then
        visited[x + 1 + y * W] = true
        stack[#stack + 1] = { x = x + 1, y = y }
      end
    end
    if maze[x][y - 1].yw == 0 and y > 0 then
      if visited[x + (y - 1) * W] == nil then
        visited[x + (y - 1) * W] = true
        stack[#stack + 1] = { x = x, y = y - 1 }
      end
    end
    if maze[x][y].yw == 0 and y < H - 1 then
      if visited[x + (y + 1) * W] == nil then
        visited[x + (y + 1) * W] = true
        stack[#stack + 1] = { x = x, y = y + 1 }
      end
    end
  end

  return reachable, reachableIndex
end

-- ============================================================
-- findDeadEnds(maze, reachable) —— frame_53 第 101-177 行
-- 返回 deadEnds[x][y]：死胡同惩罚值（≥1），非死胡同为 0 / nil
-- ============================================================
function M.findDeadEnds(maze, reachable)
  local W, H = maze.W, maze.H
  local res = new2d(W, H)
  local queue = {}
  for i = 1, #reachable do
    queue[#queue + 1] = reachable[i]
    res[reachable[i].x][reachable[i].y] = 0
  end

  local MAXP = C.MAXDEADENDPENALTY
  while #queue > 0 do
    local p = table.remove(queue)          -- pop
    local x, y = p.x, p.y
    if falsy(res[x][y]) then
      local exits = 0
      local penalty = MAXP
      local target = nil

      if maze[x][y].xw == 0 and x > 0 and falsy(res[x - 1][y]) then
        target = { x = x - 1, y = y }; exits = exits + 1
      elseif maze[x][y].xw == 0 and x > 0 then
        penalty = max(1, min(res[x - 1][y] - 1, penalty))
      end
      if maze[x + 1][y].xw == 0 and x < W - 1 and falsy(res[x + 1][y]) then
        target = { x = x + 1, y = y }; exits = exits + 1
      elseif maze[x + 1][y].xw == 0 and x < W - 1 then
        penalty = max(1, min(res[x + 1][y] - 1, penalty))
      end
      if maze[x][y - 1].yw == 0 and y > 0 and falsy(res[x][y - 1]) then
        target = { x = x, y = y - 1 }; exits = exits + 1
      elseif maze[x][y - 1].yw == 0 and y > 0 then
        penalty = max(1, min(res[x][y - 1] - 1, penalty))
      end
      if maze[x][y].yw == 0 and y < H - 1 and falsy(res[x][y + 1]) then
        target = { x = x, y = y + 1 }; exits = exits + 1
      elseif maze[x][y].yw == 0 and y < H - 1 then
        penalty = max(1, min(res[x][y + 1] - 1, penalty))
      end

      if exits == 1 then
        res[x][y] = penalty
        queue[#queue + 1] = target
      end
      if exits == 0 then
        res[x][y] = penalty
      end
    end
  end
  return res
end

-- ============================================================
-- calcDistances(maze, startx, starty) —— frame_53 第 178-272 行
-- 8 方向 BFS 距离场，对角代价 1.414214；未达格为 nil
-- ============================================================
local DIAG = 1.414214
function M.calcDistances(maze, startx, starty)
  local W, H = maze.W, maze.H
  local dist = new2d(W, H)
  local visited = {}
  local queue = { { x = startx, y = starty } }
  local head = 1
  dist[startx][starty] = 0

  while head <= #queue do
    local p = queue[head]; head = head + 1
    local x, y = p.x, p.y
    visited[x + y * W] = true

    if maze[x][y].xw == 0 and x > 0 then
      if visited[x - 1 + y * W] == nil then
        visited[x - 1 + y * W] = true
        dist[x - 1][y] = dist[x][y] + 1
        queue[#queue + 1] = { x = x - 1, y = y }
      end
    end
    if maze[x + 1][y].xw == 0 and x < W - 1 then
      if visited[x + 1 + y * W] == nil then
        visited[x + 1 + y * W] = true
        dist[x + 1][y] = dist[x][y] + 1
        queue[#queue + 1] = { x = x + 1, y = y }
      end
    end
    if maze[x][y - 1].yw == 0 and y > 0 then
      if visited[x + (y - 1) * W] == nil then
        visited[x + (y - 1) * W] = true
        dist[x][y - 1] = dist[x][y] + 1
        queue[#queue + 1] = { x = x, y = y - 1 }
      end
    end
    if maze[x][y].yw == 0 and y < H - 1 then
      if visited[x + (y + 1) * W] == nil then
        visited[x + (y + 1) * W] = true
        dist[x][y + 1] = dist[x][y] + 1
        queue[#queue + 1] = { x = x, y = y + 1 }
      end
    end
    -- 四个对角方向：需相邻两格均可通行，避免穿墙角
    if maze[x][y].yw == 0 and maze[x][y].xw == 0 and maze[x - 1][y].yw == 0 and maze[x][y + 1].xw == 0
       and x > 0 and y < H - 1 then
      if visited[x - 1 + (y + 1) * W] == nil then
        visited[x - 1 + (y + 1) * W] = true
        dist[x - 1][y + 1] = dist[x][y] + DIAG
        queue[#queue + 1] = { x = x - 1, y = y + 1 }
      end
    end
    if maze[x][y].yw == 0 and maze[x + 1][y].xw == 0 and maze[x + 1][y].yw == 0 and maze[x + 1][y + 1].xw == 0
       and x < W - 1 and y < H - 1 then
      if visited[x + 1 + (y + 1) * W] == nil then
        visited[x + 1 + (y + 1) * W] = true
        dist[x + 1][y + 1] = dist[x][y] + DIAG
        queue[#queue + 1] = { x = x + 1, y = y + 1 }
      end
    end
    if maze[x][y].xw == 0 and maze[x][y - 1].yw == 0 and maze[x][y - 1].xw == 0 and maze[x - 1][y - 1].yw == 0
       and x > 0 and y > 0 then
      if visited[x - 1 + (y - 1) * W] == nil then
        visited[x - 1 + (y - 1) * W] = true
        dist[x - 1][y - 1] = dist[x][y] + DIAG
        queue[#queue + 1] = { x = x - 1, y = y - 1 }
      end
    end
    if maze[x + 1][y].xw == 0 and maze[x][y - 1].yw == 0 and maze[x + 1][y - 1].yw == 0 and maze[x + 1][y - 1].xw == 0
       and x < W - 1 and y > 0 then
      if visited[x + 1 + (y - 1) * W] == nil then
        visited[x + 1 + (y - 1) * W] = true
        dist[x + 1][y - 1] = dist[x][y] + DIAG
        queue[#queue + 1] = { x = x + 1, y = y - 1 }
      end
    end
  end
  return dist
end

-- ============================================================
-- getShortestPathWithDistances(maze, distances, sx, sy, ex, ey) —— 第 278-345 行
-- 由终点沿距离场回溯至起点
-- ============================================================
function M.getShortestPathWithDistances(maze, distances, startx, starty, endx, endy)
  local W, H = maze.W, maze.H
  local path = {}
  local x, y = endx, endy
  local best = distances[x][y]
  local nx, ny = endx, endy

  repeat
    path[#path + 1] = { x = x, y = y }
    if maze[x][y].yw == 0 and maze[x][y].xw == 0 and maze[x - 1][y].yw == 0 and maze[x][y + 1].xw == 0
       and x > 0 and y < H - 1 and distances[x - 1][y + 1] < best then
      best = distances[x - 1][y + 1]; nx = x - 1; ny = y + 1
    end
    if maze[x][y].yw == 0 and maze[x + 1][y].xw == 0 and maze[x + 1][y].yw == 0 and maze[x + 1][y + 1].xw == 0
       and x < W - 1 and y < H - 1 and distances[x + 1][y + 1] < best then
      best = distances[x + 1][y + 1]; nx = x + 1; ny = y + 1
    end
    if maze[x][y].xw == 0 and maze[x][y - 1].yw == 0 and maze[x][y - 1].xw == 0 and maze[x - 1][y - 1].yw == 0
       and x > 0 and y > 0 and distances[x - 1][y - 1] < best then
      best = distances[x - 1][y - 1]; nx = x - 1; ny = y - 1
    end
    if maze[x + 1][y].xw == 0 and maze[x][y - 1].yw == 0 and maze[x + 1][y - 1].yw == 0 and maze[x + 1][y - 1].xw == 0
       and x < W - 1 and y > 0 and distances[x + 1][y - 1] < best then
      best = distances[x + 1][y - 1]; nx = x + 1; ny = y - 1
    end
    if maze[x][y].xw == 0 and x > 0 and distances[x - 1][y] < best then
      best = distances[x - 1][y]; nx = x - 1; ny = y
    end
    if maze[x + 1][y].xw == 0 and x < W - 1 and distances[x + 1][y] < best then
      best = distances[x + 1][y]; nx = x + 1; ny = y
    end
    if maze[x][y - 1].yw == 0 and y > 0 and distances[x][y - 1] < best then
      best = distances[x][y - 1]; nx = x; ny = y - 1
    end
    if maze[x][y].yw == 0 and y < H - 1 and distances[x][y + 1] < best then
      best = distances[x][y + 1]; nx = x; ny = y + 1
    end
    x, y = nx, ny
  until x == startx and y == starty

  -- reverse
  local out = {}
  for i = #path, 1, -1 do out[#out + 1] = path[i] end
  return out
end

function M.getShortestPath(maze, startx, starty, endx, endy)
  local d = M.calcDistances(maze, startx, starty)
  return M.getShortestPathWithDistances(maze, d, startx, starty, endx, endy)
end

-- ============================================================
-- 像素级墙体判定 —— 等价原版 _root.game.mazemc.hitTest(px,py,true)
-- frame_53 第 601、646-699 行：
--   lineThickness = floor(scale/16)，mazemc 线宽 = 2*lineThickness，线帽 "square"。
--   mazemc 只描边、无填充，故每段墙 = 以格线为中心、厚 2*lt 的矩形带（端点各外扩 lt）。
-- 坐标：mazemc 局部像素。格 (x,y) 覆盖 [x*scale,(x+1)*scale] × [y*scale,(y+1)*scale]。
--   竖线索引 x∈[0,W]：x=0/W 为左右外框（判 maze[0][y].s / maze[W-1][y].s），
--                     x∈[1,W-1] 为内部隔断（判 maze[x][y].xw）。
--   横线索引 k∈[0,H]：k=0/H 为上下外框（判 maze[x][0].s / maze[x][H-1].s），
--                     k∈[1,H-1] 为内部隔断（判 maze[x][k-1].yw）。
-- ============================================================
function M.makeWallTester(maze, scale)
  local W, H = maze.W, maze.H
  local lt = floor(scale / 16)

  local function vwall(x, y)
    if y < 0 or y >= H then return false end
    if x == 0 then return not falsy(maze[0][y].s) end
    if x == W then return not falsy(maze[W - 1][y].s) end
    if x < 0 or x > W then return false end
    return not falsy(maze[x][y].xw)
  end
  local function hwall(x, k)
    if x < 0 or x >= W then return false end
    if k == 0 then return not falsy(maze[x][0].s) end
    if k == H then return not falsy(maze[x][H - 1].s) end
    if k < 0 or k > H then return false end
    return not falsy(maze[x][k - 1].yw)
  end

  return function(px, py)
    -- 竖墙：候选列 x（|px − x*scale| ≤ lt）
    local xc = floor(px / scale + 0.5)
    for x = xc - 1, xc + 1 do
      if abs(px - x * scale) <= lt then
        local y0 = floor((py - lt) / scale)
        local y1 = floor((py + lt) / scale)
        for y = y0, y1 do
          if py >= y * scale - lt and py <= (y + 1) * scale + lt and vwall(x, y) then
            return true
          end
        end
      end
    end
    -- 横墙：候选线 k（|py − k*scale| ≤ lt）
    local kc = floor(py / scale + 0.5)
    for k = kc - 1, kc + 1 do
      if abs(py - k * scale) <= lt then
        local x0 = floor((px - lt) / scale)
        local x1 = floor((px + lt) / scale)
        for x = x0, x1 do
          if px >= x * scale - lt and px <= (x + 1) * scale + lt and hwall(x, k) then
            return true
          end
        end
      end
    end
    return false
  end
end

-- ============================================================
-- optimizeShortestPath(maze, path) —— 第 346-360 行（原地修改）
-- ============================================================
function M.optimizeShortestPath(maze, path)
  local p2 = table.remove(path)   -- path.pop()
  local p3 = table.remove(path)   -- path.pop()
  local p4 = path[#path]          -- path[path.length-1]
  if M.checkClearPath(maze, p4, p2) then
    path[#path + 1] = p2
  else
    path[#path + 1] = p3
    path[#path + 1] = p2
  end
end

-- ============================================================
-- checkClearPath(maze, start, end) —— 第 361-434 行
-- 射线步进判断两点间是否直线可达
-- ============================================================
function M.checkClearPath(maze, startP, endP)
  local W, H = maze.W, maze.H
  local dx = endP.x - startP.x
  local dy = endP.y - startP.y
  local len = sqrt(dx * dx + dy * dy)
  local ux = dx / len
  local uy = dy / len
  local fx = startP.x + 0.5
  local fy = startP.y + 0.5
  local cx = floor(fx)
  local cy = floor(fy)

  while cx ~= endP.x or cy ~= endP.y do
    if ux < 0 and uy > 0 and cx > endP.x and cy < endP.y then
      if not (maze[cx][cy].yw == 0 and maze[cx][cy].xw == 0 and maze[cx - 1][cy].yw == 0 and maze[cx][cy + 1].xw == 0
              and cx > 0 and cy < H - 1) then
        return false
      end
    end
    if ux > 0 and uy > 0 and cx < endP.x and cy < endP.y then
      if not (maze[cx][cy].yw == 0 and maze[cx + 1][cy].xw == 0 and maze[cx + 1][cy].yw == 0 and maze[cx + 1][cy + 1].xw == 0
              and cx < W - 1 and cy < H - 1) then
        return false
      end
    end
    if ux < 0 and uy < 0 and cx > endP.x and cy > endP.y then
      if not (maze[cx][cy].xw == 0 and maze[cx][cy - 1].yw == 0 and maze[cx][cy - 1].xw == 0 and maze[cx - 1][cy - 1].yw == 0
              and cx > 0 and cy > 0) then
        return false
      end
    end
    if ux > 0 and uy < 0 and cx < endP.x and cy > endP.y then
      if not (maze[cx + 1][cy].xw == 0 and maze[cx][cy - 1].yw == 0 and maze[cx + 1][cy - 1].yw == 0 and maze[cx + 1][cy - 1].xw == 0
              and cx < W - 1 and cy > 0) then
        return false
      end
    end
    if ux < 0 and uy == 0 then
      if not (maze[cx][cy].xw == 0 and cx > 0) then return false end
    end
    if ux > 0 and uy == 0 then
      if not (maze[cx + 1][cy].xw == 0 and cx < W - 1) then return false end
    end
    if ux == 0 and uy < 0 then
      if not (maze[cx][cy - 1].yw == 0 and cy > 0) then return false end
    end
    if ux == 0 and uy > 0 then
      if not (maze[cx][cy].yw == 0 and cy < H - 1) then return false end
    end
    fx = fx + ux
    fy = fy + uy
    cx = floor(fx)
    cy = floor(fy)
  end
  return true
end

-- ============================================================
-- followGradientPathWithDistances(maze, distances, sx, sy, maxLength) —— 第 435-511 行
-- 沿距离场"上坡"前进（远离源点）
-- ============================================================
function M.followGradientPathWithDistances(maze, distances, startx, starty, maxLength)
  local W, H = maze.W, maze.H
  local out = {}
  local x, y = startx, starty
  local nx, ny = startx, starty
  local best = distances[x][y]
  local foundPlace

  repeat
    foundPlace = false
    if maze[x][y].yw == 0 and maze[x][y].xw == 0 and maze[x - 1][y].yw == 0 and maze[x][y + 1].xw == 0
       and x > 0 and y < H - 1 and distances[x - 1][y + 1] > best then
      best = distances[x - 1][y + 1]; nx = x - 1; ny = y + 1; foundPlace = true
    end
    if maze[x][y].yw == 0 and maze[x + 1][y].xw == 0 and maze[x + 1][y].yw == 0 and maze[x + 1][y + 1].xw == 0
       and x < W - 1 and y < H - 1 and distances[x + 1][y + 1] > best then
      best = distances[x + 1][y + 1]; nx = x + 1; ny = y + 1; foundPlace = true
    end
    if maze[x][y].xw == 0 and maze[x][y - 1].yw == 0 and maze[x][y - 1].xw == 0 and maze[x - 1][y - 1].yw == 0
       and x > 0 and y > 0 and distances[x - 1][y - 1] > best then
      best = distances[x - 1][y - 1]; nx = x - 1; ny = y - 1; foundPlace = true
    end
    if maze[x + 1][y].xw == 0 and maze[x][y - 1].yw == 0 and maze[x + 1][y - 1].yw == 0 and maze[x + 1][y - 1].xw == 0
       and x < W - 1 and y > 0 and distances[x + 1][y - 1] > best then
      best = distances[x + 1][y - 1]; nx = x + 1; ny = y - 1; foundPlace = true
    end
    if maze[x][y].xw == 0 and x > 0 and distances[x - 1][y] > best then
      best = distances[x - 1][y]; nx = x - 1; ny = y; foundPlace = true
    end
    if maze[x + 1][y].xw == 0 and x < W - 1 and distances[x + 1][y] > best then
      best = distances[x + 1][y]; nx = x + 1; ny = y; foundPlace = true
    end
    if maze[x][y - 1].yw == 0 and y > 0 and distances[x][y - 1] > best then
      best = distances[x][y - 1]; nx = x; ny = y - 1; foundPlace = true
    end
    if maze[x][y].yw == 0 and y < H - 1 and distances[x][y + 1] > best then
      best = distances[x][y + 1]; nx = x; ny = y + 1; foundPlace = true
    end
    x, y = nx, ny
    out[#out + 1] = { x = x, y = y }
    maxLength = maxLength - 1
  until (not foundPlace) or maxLength <= 0

  return out
end

-- ============================================================
-- followGradientPathWithDistancesAndDeadEnds(...) —— 第 512-594 行
-- 距离 − 死胡同惩罚 的梯度跟随（AI 逃跑用）
-- ============================================================
function M.followGradientPathWithDistancesAndDeadEnds(maze, distances, deadEnds, startx, starty, maxLength)
  local W, H = maze.W, maze.H
  local function score(cx, cy)
    return distances[cx][cy] - (deadEnds[cx][cy] or 0)
  end

  local out = {}
  local x, y = startx, starty
  local nx, ny = startx, starty
  local best = score(x, y)
  local foundPlace

  repeat
    foundPlace = false
    if maze[x][y].yw == 0 and maze[x][y].xw == 0 and maze[x - 1][y].yw == 0 and maze[x][y + 1].xw == 0
       and x > 0 and y < H - 1 and score(x - 1, y + 1) > best then
      best = score(x - 1, y + 1); nx = x - 1; ny = y + 1; foundPlace = true
    end
    if maze[x][y].yw == 0 and maze[x + 1][y].xw == 0 and maze[x + 1][y].yw == 0 and maze[x + 1][y + 1].xw == 0
       and x < W - 1 and y < H - 1 and score(x + 1, y + 1) > best then
      best = score(x + 1, y + 1); nx = x + 1; ny = y + 1; foundPlace = true
    end
    if maze[x][y].xw == 0 and maze[x][y - 1].yw == 0 and maze[x][y - 1].xw == 0 and maze[x - 1][y - 1].yw == 0
       and x > 0 and y > 0 and score(x - 1, y - 1) > best then
      best = score(x - 1, y - 1); nx = x - 1; ny = y - 1; foundPlace = true
    end
    if maze[x + 1][y].xw == 0 and maze[x][y - 1].yw == 0 and maze[x + 1][y - 1].yw == 0 and maze[x + 1][y - 1].xw == 0
       and x < W - 1 and y > 0 and score(x + 1, y - 1) > best then
      best = score(x + 1, y - 1); nx = x + 1; ny = y - 1; foundPlace = true
    end
    if maze[x][y].xw == 0 and x > 0 and score(x - 1, y) > best then
      best = score(x - 1, y); nx = x - 1; ny = y; foundPlace = true
    end
    if maze[x + 1][y].xw == 0 and x < W - 1 and score(x + 1, y) > best then
      best = score(x + 1, y); nx = x + 1; ny = y; foundPlace = true
    end
    if maze[x][y - 1].yw == 0 and y > 0 and score(x, y - 1) > best then
      best = score(x, y - 1); nx = x; ny = y - 1; foundPlace = true
    end
    if maze[x][y].yw == 0 and y < H - 1 and score(x, y + 1) > best then
      best = score(x, y + 1); nx = x; ny = y + 1; foundPlace = true
    end
    x, y = nx, ny
    out[#out + 1] = { x = x, y = y }
    maxLength = maxLength - 1
  until (not foundPlace) or maxLength <= 0

  return out
end

return M
end

-- ==================== 模块 src.tank ====================
__defs["src.tank"] = function()
--[[
  坦克动荡2 —— 坦克物理与操控（纯逻辑，可脱离游戏运行时单测）
  逐行对照 GameTank.swf → DefineSprite_69_gameTank/frame_1/DoAction.as 移植。

  坐标系与朝向（与原版 Flash 完全一致）：
    角度 rot 为 Flash 的 _rotation：0° 朝上（屏幕 −y），顺时针为正。
    前进方向 = (cos(rot−90°), sin(rot−90°))。
    碰撞点定义在坦克局部坐标（前方 = 局部 −y），经 localToGlobal 变换到场景像素：
      gx = x + (lx·cosθ − ly·sinθ)·s
      gy = y + (lx·sinθ + ly·cosθ)·s      （θ = rot 弧度，s = 坦克缩放）
    其中 s = 0.55 × SCALE / 100（原版 _xscale = _yscale = 0.55 × SCALE，单位为百分比）。

  坐标空间为 mazemc 局部像素（即 _root.game 场景中迷宫所在坐标系）：
    格 (x,y) 覆盖 [x·SCALE,(x+1)·SCALE] × [y·SCALE,(y+1)·SCALE]，坦克初始位于格中心。

  本模块不涉及任何渲染 / 输入设备，平台层负责：
    · 提供 wallHit(px,py)->bool（见 maze.makeWallTester）
    · 读取按键 / 鼠标后调用 stepKeyboard / stepMouse
]]

local M = {}

local cos, sin, sqrt, abs, floor, random = math.cos, math.sin, math.sqrt, math.abs, math.floor, math.random
local PI, RAD = math.pi, math.pi / 180

-- ============================================================
-- 1. 权威尺寸（GameTank.swf 符号边界，单位：符号局部像素）
-- ============================================================
M.BASE_W   = 61     -- base 宽（左右）
M.BASE_H   = 81     -- base 长（前后）
M.TURRET_W = 45     -- 默认炮塔宽（turret frame 1）
M.TURRET_H = 77.5   -- 默认炮塔长（turret frame 1）

M.TANK_SCALE = 0.55 -- _xscale = _yscale = 0.55 × SCALE
M.STEPS      = 5    -- 每帧把移动拆成 5 个子步做碰撞检测

-- ============================================================
-- 2. 碰撞点组（原版 frame_1 第 382-406 行）
--    前方 = 局部 −y；含炮塔前缘 2 点，共 6 点（武器不同会重算，见 setTurretSize）
-- ============================================================
function M.makeHitPoints(bw, bh, tw, th)
  bw, bh = bw or M.BASE_W, bh or M.BASE_H
  tw, th = tw or M.TURRET_W, th or M.TURRET_H
  return {
    front = {
      { -bw / 2, -bh / 2 }, { -bw / 4, -bh / 2 }, { bw / 4, -bh / 2 }, { bw / 2, -bh / 2 },
      { -tw / 6, -th / 16 * 11 }, { tw / 6, -th / 16 * 11 },
    },
    rear = {
      { -bw / 2, bh / 2 }, { -bw / 4, bh / 2 }, { 0, bh / 2 }, { bw / 4, bh / 2 }, { bw / 2, bh / 2 },
    },
    right = {
      { bw / 2, -bh / 6 * 2 }, { bw / 2, -bh / 6 }, { bw / 2, 0 }, { bw / 2, bh / 6 }, { bw / 2, bh / 6 * 2 },
    },
    left = {
      { -bw / 2, -bh / 6 * 2 }, { -bw / 2, -bh / 6 }, { -bw / 2, 0 }, { -bw / 2, bh / 6 }, { -bw / 2, bh / 6 * 2 },
    },
  }
end

-- ============================================================
-- 3. 构造（对应 deployTank 的部署 + frame_1 第 365-406 行）
--    opts:
--      x, y     初始位置（mazemc 局部像素）
--      rot      初始角度（度；原版为 random*36*10）
--      cellScale SCALE（格像素），用于速度与坦克缩放
--      wallHit  function(px,py)->bool，像素级墙体判定
--      mouseTank / settingsUseNewMouseControl / settingsUseSmoothCollision
--      baseW/baseH/turretW/turretH  可选覆盖
-- ============================================================

-- 与 SCALE 相关的量（新回合迷宫尺寸变化时需重新同步，见平台层 assignTanksToCells）
function M.setScale(t, scale)
  t.cellScale = scale
  t.s = M.TANK_SCALE * scale / 100          -- localToGlobal 的缩放系数
  t.forwardSpeed = 4 * (scale / 50)         -- 第 365 行
  t.backUpSpeed = 2.5 * (scale / 50)        -- 第 366 行
end

function M.new(opts)
  opts = opts or {}
  local scale = opts.cellScale or 50
  local t = {
    x = opts.x or 0,
    y = opts.y or 0,
    rot = opts.rot or 0,
    turnSpeed = 10,                          -- 第 367 行
    wallHit = opts.wallHit,
    mouseTank = opts.mouseTank or false,
    settingsUseNewMouseControl = opts.settingsUseNewMouseControl or false,
    settingsUseSmoothCollision = opts.settingsUseSmoothCollision ~= false,
    hitPoints = M.makeHitPoints(opts.baseW, opts.baseH, opts.turretW, opts.turretH),
    alive = true,
  }
  M.setScale(t, scale)
  t.oldX, t.oldY, t.oldRot = t.x, t.y, t.rot
  return t
end

-- 武器切换导致炮塔尺寸变化时重算碰撞点（原版在 setWeapon 中重算）
function M.setTurretSize(t, tw, th)
  t.hitPoints = M.makeHitPoints(M.BASE_W, M.BASE_H, tw, th)
end

-- ============================================================
-- 4. 碰撞检测（第 1-43 行）
-- ============================================================
function M.hitCheck(t, points)
  local th = t.rot * RAD
  local c, sn, s = cos(th), sin(th), t.s
  for i = 1, #points do
    local p = points[i]
    local gx = t.x + (p[1] * c - p[2] * sn) * s
    local gy = t.y + (p[1] * sn + p[2] * c) * s
    if t.wallHit(gx, gy) then return true end
  end
  return false
end

-- 放大 k 倍的碰撞点检测（第 28-43 行）
function M.expandedHitCheck(t, points, k)
  local th = t.rot * RAD
  local c, sn, s = cos(th), sin(th), t.s
  for i = 1, #points do
    local p = points[i]
    local lx, ly = p[1] * k, p[2] * k
    local gx = t.x + (lx * c - ly * sn) * s
    local gy = t.y + (lx * sn + ly * c) * s
    if t.wallHit(gx, gy) then return true end
  end
  return false
end

local function anyHit(t)
  local hp = t.hitPoints
  return M.hitCheck(t, hp.front) or M.hitCheck(t, hp.rear)
      or M.hitCheck(t, hp.left) or M.hitCheck(t, hp.right)
end
M.anyHit = anyHit

-- ============================================================
-- 5. 脱困辅助（第 193-274 行）
-- ============================================================
local function preventGettingStuckOnCorner(t)
  local hp = t.hitPoints
  if M.hitCheck(t, hp.left) and not M.expandedHitCheck(t, hp.right, 1.1) then
    t.x = t.x + cos(t.rot * RAD) * t.backUpSpeed / M.STEPS
    t.y = t.y + sin(t.rot * RAD) * t.backUpSpeed / M.STEPS
  elseif M.hitCheck(t, hp.right) and not M.expandedHitCheck(t, hp.left, 1.1) then
    t.x = t.x + cos((t.rot - 180) * RAD) * t.backUpSpeed / M.STEPS
    t.y = t.y + sin((t.rot - 180) * RAD) * t.backUpSpeed / M.STEPS
  end
end

local function attemptToClearLeftAndRight(t, moveSize)
  local hp = t.hitPoints
  if M.expandedHitCheck(t, hp.left, 1.4000000000000001) then
    if moveSize == 0 then
      t.x = t.x + cos(t.rot * RAD) * t.backUpSpeed / M.STEPS
      t.y = t.y + sin(t.rot * RAD) * t.backUpSpeed / M.STEPS
    end
    t.rot = t.rot + (moveSize < 0 and -1 or 1) * t.turnSpeed / M.STEPS
  elseif M.expandedHitCheck(t, hp.right, 1.4000000000000001) then
    if moveSize == 0 then
      t.x = t.x + cos((t.rot - 180) * RAD) * t.backUpSpeed / M.STEPS
      t.y = t.y + sin((t.rot - 180) * RAD) * t.backUpSpeed / M.STEPS
    end
    t.rot = t.rot - (moveSize < 0 and -1 or 1) * t.turnSpeed / M.STEPS
  else
    t.rot = t.rot + (random() <= 0.5 and 0.5 or -0.5) * t.turnSpeed / M.STEPS
  end
end

local function attemptToClearFrontAndBack(t)
  local hp = t.hitPoints
  local f = M.expandedHitCheck(t, hp.front, 1.1)
  local r = M.expandedHitCheck(t, hp.rear, 1.1)
  if f and not r then
    t.x = t.x + cos((t.rot - 90) * RAD) * (-t.backUpSpeed) / M.STEPS
    t.y = t.y + sin((t.rot - 90) * RAD) * (-t.backUpSpeed) / M.STEPS
  elseif r and not f then
    t.x = t.x + cos((t.rot - 90) * RAD) * t.forwardSpeed / M.STEPS
    t.y = t.y + sin((t.rot - 90) * RAD) * t.forwardSpeed / M.STEPS
  elseif r and f then
    if M.expandedHitCheck(t, hp.left, 1.4000000000000001) then
      t.x = t.x + cos(t.rot * RAD) * t.backUpSpeed / M.STEPS
      t.y = t.y + sin(t.rot * RAD) * t.backUpSpeed / M.STEPS
    else
      t.x = t.x + cos((t.rot - 180) * RAD) * t.backUpSpeed / M.STEPS
      t.y = t.y + sin((t.rot - 180) * RAD) * t.backUpSpeed / M.STEPS
    end
  end
end

-- ============================================================
-- 6. 主移动（第 44-192 行）
--    前置条件：调用方需先执行 beginFrame(t)（记录 oldX/oldY/oldRot）
--    返回 !hitSomething
-- ============================================================
function M.beginFrame(t)
  t.oldX, t.oldY, t.oldRot = t.x, t.y, t.rot
end

function M.attemptToMove(t, forward, backup, turnLeft, turnRight)
  local STEPS = M.STEPS
  local moveSize, turnSize = 0, 0
  if forward then moveSize = t.forwardSpeed / STEPS end
  if backup then moveSize = moveSize - t.backUpSpeed / STEPS end
  if turnLeft then turnSize = (-t.turnSpeed) / STEPS end
  if turnRight then turnSize = turnSize + t.turnSpeed / STEPS end

  local hitSomething = false
  for _ = 1, STEPS do
    t.rot = t.rot + turnSize
    t.x = t.x + cos((t.rot - 90) * RAD) * moveSize
    t.y = t.y + sin((t.rot - 90) * RAD) * moveSize
  end

  local hp = t.hitPoints
  if anyHit(t) then
    t.x, t.y = t.oldX, t.oldY
    if not t.mouseTank or t.settingsUseNewMouseControl then
      t.rot = t.oldRot
    end
    for _ = 1, STEPS do
      if not t.mouseTank or t.settingsUseNewMouseControl then
        t.oldRot = t.rot
        t.rot = t.rot + turnSize
        if anyHit(t) then
          t.rot = t.oldRot
          hitSomething = true
        end
      elseif t.mouseTank and not t.settingsUseNewMouseControl then
        if anyHit(t) then
          if not t.settingsUseSmoothCollision then t.rot = t.oldRot end
          hitSomething = true
        end
      end
      t.oldX, t.oldY = t.x, t.y
      t.x = t.x + cos((t.rot - 90) * RAD) * moveSize
      t.y = t.y + sin((t.rot - 90) * RAD) * moveSize
      if moveSize > 0 and M.hitCheck(t, hp.front) then
        t.x, t.y = t.oldX, t.oldY
        hitSomething = true
      elseif moveSize < 0 and M.hitCheck(t, hp.rear) then
        t.x, t.y = t.oldX, t.oldY
        hitSomething = true
      end
    end
    if t.settingsUseSmoothCollision and hitSomething then
      for _ = 1, 2 do
        if t.mouseTank and not t.settingsUseNewMouseControl then
          attemptToClearFrontAndBack(t)
        elseif t.rot == t.oldRot then
          attemptToClearLeftAndRight(t, moveSize)
          attemptToClearFrontAndBack(t)
          if anyHit(t) then
            t.rot = t.oldRot
            if anyHit(t) then
              t.x, t.y = t.oldX, t.oldY
            end
          end
        end
        preventGettingStuckOnCorner(t)
      end
      -- 原版此处生成烟雾 / 碎屑拖痕（纯视觉），交由平台层处理
      if t.onSkidMarks then t.onSkidMarks(moveSize) end
    end
  end

  -- 朝向吸附到 turnSpeed 的整数倍（第 171-190 行）
  local offset = math.fmod(360 + t.rot, t.turnSpeed)
  if not hitSomething and offset ~= 0 and (not t.mouseTank or t.settingsUseNewMouseControl) then
    if offset < t.turnSpeed / 2 then
      t.rot = t.rot - offset
      if anyHit(t) then t.rot = t.rot + offset end
    else
      t.rot = t.rot + (t.turnSpeed - offset)
      if anyHit(t) then t.rot = t.rot - (t.turnSpeed - offset) end
    end
  end
  t.hitSomething = hitSomething   -- AI 决策树读取（gameTank 第 67/98/109 行）
  return not hitSomething
end

-- ============================================================
-- 7. 输入（onEnterFrame 第 421-683 行的输入段）
-- ============================================================

-- 键盘操控：keys = { forward, backup, turnLeft, turnRight }
function M.stepKeyboard(t, keys)
  M.beginFrame(t)
  return M.attemptToMove(t, keys.forward, keys.backup, keys.turnLeft, keys.turnRight)
end

-- 鼠标操控：mx,my 为鼠标在 mazemc 局部坐标中的位置
function M.stepMouse(t, mx, my)
  M.beginFrame(t)
  local deltaX, deltaY = mx - t.x, my - t.y
  local deltaLength = sqrt(deltaX * deltaX + deltaY * deltaY)
  local turnLeft, turnRight, forward, backup = false, false, false, false

  if t.settingsUseNewMouseControl then
    local cur = t.rot
    local reverse = false
    local nearMouse = deltaLength < 120
    local target
    if deltaX ~= 0 then
      if deltaX > 0 then
        target = 90 + math.atan(deltaY / deltaX) * 180 / PI
      else
        target = -90 + math.atan(deltaY / deltaX) * 180 / PI
      end
    elseif deltaY > 0 then
      target = 180
    elseif deltaY < 0 then
      target = 0
    else
      target = cur
    end
    target = math.floor(target / t.turnSpeed + 0.5) * t.turnSpeed
    if nearMouse and abs(target - cur) > 90 and abs(target - cur) < 270 then
      reverse = true
      target = target + 180
      if target > 180 then target = target - 360 end
    end
    if (target == 180 and cur < 0) or (target == -180 and cur > 0) then
      target = target * -1
    end
    if target > cur + (t.turnSpeed - 1) then
      if abs(target - cur) > 180 then turnLeft, turnRight = true, false
      else turnLeft, turnRight = false, true end
    elseif target < cur - (t.turnSpeed - 1) then
      if abs(target - cur) > 180 then turnLeft, turnRight = false, true
      else turnLeft, turnRight = true, false end
    end
    if deltaLength > 60 and (abs(target - cur) < 45 or abs(target - cur) > 315) then
      forward, backup = not reverse, reverse
    end
  else
    -- 旧鼠标操控：坦克瞬时对准鼠标
    local aimAngle
    if deltaX < 0 then
      if deltaY < 0 then aimAngle = -PI + math.atan(deltaY / deltaX)
      else aimAngle = PI + math.atan(deltaY / deltaX) end
    elseif deltaX > 0 then
      aimAngle = math.atan(deltaY / deltaX)
    elseif deltaY < 0 then
      aimAngle = -PI / 2
    else
      aimAngle = PI / 2
    end
    t.rot = (aimAngle + PI / 2) * 180 / PI
    if deltaLength > 60 then forward, backup = true, false end
  end

  return M.attemptToMove(t, forward, backup, turnLeft, turnRight)
end

-- ============================================================
-- 8. 部署辅助（deployTank 第 801-806 行）
--    原版 _rotation = floor(random*36)*10
-- ============================================================
function M.randomRotation()
  return floor(random() * 36) * 10
end

return M
end

-- ==================== 模块 src.weapons ====================
__defs["src.weapons"] = function()
--[[
  坦克动荡2 —— 武器 / 投射物（纯逻辑，可脱离游戏运行时单测）

  逐行对照以下反编译源码移植（AS2）：
    bullet        DefineSprite_212_bullet/frame_1
    laser         DefineSprite_226_laser/frame_1
    fragbomb      DefineSprite_217_fragbomb/frame_1
    fragbombfragment DefineSprite_219_fragbombfragment/frame_1
    gatling       DefineSprite_220_gatling/frame_1
    gatlingBullet DefineSprite_221_gatlingBullet/frame_1
    homingbullet  DefineSprite_225_homingbullet/frame_1
    mine          DefineSprite_234_mine/frame_1
    rCMissile     DefineSprite_237_rCMissile/frame_1
    deathRay      DefineSprite_215_deathRay/frame_1
    electricbullet DefineSprite_216_electricbullet/frame_1
  发射参数与就绪/锁控判定对照 frame_53/DoAction.as：
    setWeapon(1142) / weaponReady(1114) / lockedControl(1098)
    fireWeapon(1267) / fireBullet(1304) / fireLaser(1328) / fireFrag(1353)
    fireGatling(1386) / fireDeathRay(1403) / fireHoming(1423) / layMine(1500)
    fireRemote(1533) / fireElectric(1626)

  坐标系（与 tank.lua / maze.lua 一致）：
    所有位置均为 mazemc 局部像素。格 (x,y) 覆盖 [x·SCALE,(x+1)·SCALE]²。
    速度中反复出现的 (SCALE/50) 记为 k；实际每帧位移 = SPEED/INTERVALS·k。

  本模块不渲染、不读输入设备。运行环境（ctx）由平台层提供：
    ctx.scale                  SCALE
    ctx.wallHit(px,py)         mazemc 墙体判定（见 maze.makeWallTester）
    ctx.insideMaze(px,py)      点是否在迷宫区域内（等价原版 mazebg.hitTest，deathRay 用）
    ctx.tanks                  坦克数组，元素含 .alive/.x/.y/.rot/.s/.hitPoints
    ctx.tankContains(t,px,py)  点是否在坦克贴图形状内（等价 t.hitTest(px,py,true)）
    ctx.tankBaseContains(t,px,py) 点是否在坦克底座形状内（等价 t.base.hitTest(...)）
    ctx.spawn(proj)            把一个新投射物加入世界
    ctx.onHit(owner,victim)    registerHit + destroyTank
    ctx.setWeapon(owner,kind)  setWeapon
    ctx.shake(v)               _root.shake 累计
    ctx.keyDown(keyCode)       Key.isDown
    ctx.mousePos()             mazemc 局部鼠标坐标
    以及纯视觉回调：ctx.smoke / ctx.fragments / ctx.trail / ctx.particles / ctx.spark / ctx.sound

  说明：原版 electricbullet 自身不含对坦克的命中判定（两个弹丸只弹跳 + 画电弧），
        故此处同样不产生伤害，保持与原版一致，不做"修正"。
]]

local C = require("src.constants")

local M = {}

local cos, sin, sqrt, abs, floor, min, max, random, atan =
  math.cos, math.sin, math.sqrt, math.abs, math.floor, math.min, math.max, math.random, math.atan
local PI, RAD = math.pi, math.pi / 180

local function rnd(n) return floor(random() * n) end   -- 等价 AS random(n)：[0,n)

-- ============================================================
-- 0. 运行环境（缺省全部为无害空实现，便于单测）
-- ============================================================
local function noop() end

function M.makeCtx(o)
  o = o or {}
  return {
    scale = o.scale or 50,
    wallHit = o.wallHit or function() return false end,
    insideMaze = o.insideMaze or function() return true end,
    tanks = o.tanks or {},
    tankContains = o.tankContains or function() return false end,
    tankBaseContains = o.tankBaseContains or function() return false end,
    spawn = o.spawn or noop,
    onHit = o.onHit or noop,
    setWeapon = o.setWeapon or noop,
    shake = o.shake or noop,
    keyDown = o.keyDown or function() return false end,
    mousePos = o.mousePos or function() return 0, 0 end,
    smoke = o.smoke or noop,
    fragments = o.fragments or noop,
    trail = o.trail or noop,
    particles = o.particles or noop,
    spark = o.spark or noop,
    sound = o.sound or noop,
    -- 寻路（homing 用）；由平台层预计算
    distancesForMaze = o.distancesForMaze,
    getShortestPathWithDistances = o.getShortestPathWithDistances,
    -- 坦克前进（elToro 用）
    attemptForward = o.attemptForward,
  }
end

-- ============================================================
-- 1. 通用几何 / 碰撞辅助
-- ============================================================

-- 坦克局部点 → 全局像素（等价 tank.localToGlobal）
-- 变换：gx = x + (lx·cosθ − ly·sinθ)·s，gy = y + (lx·sinθ + ly·cosθ)·s
local function tankPointGlobal(t, lx, ly)
  local th = t.rot * RAD
  local c, sn, s = cos(th), sin(th), t.s
  return t.x + (lx * c - ly * sn) * s, t.y + (lx * sn + ly * c) * s
end
M.tankPointGlobal = tankPointGlobal

-- 命中坦克判定：弹丸自身位置点是否落在某坦克贴图内（原版 hitCheck(tank,{0,0})）
-- 命中后置 p.remove；遍历全部坦克（原版命中后仍继续循环）
local function hitTanks(p, ctx, enabled)
  if not enabled then return end
  local tanks = ctx.tanks
  for i = 1, #tanks do
    local t = tanks[i]
    if t.alive and ctx.tankContains(t, p.x, p.y) then
      ctx.onHit(p.owner, t)
      p.remove = true
    end
  end
end

-- 撞墙后的反弹：把位置回退到 prev，按 X/Y 单轴试探决定反射轴，再重新推进。
-- 与 bullet/laser/gatling/homing/frag/mine/electric 的原始写法逐字一致。
local function resolveBounce(p, ctx, prevX, prevY)
  local hitX = ctx.wallHit(prevX - p.xSpeed, prevY + p.ySpeed)
  local hitY = ctx.wallHit(prevX + p.xSpeed, prevY - p.ySpeed)
  if hitX and not hitY then
    p.ySpeed = -p.ySpeed
  elseif hitY and not hitX then
    p.xSpeed = -p.xSpeed
  else
    p.xSpeed = -p.xSpeed
    p.ySpeed = -p.ySpeed
  end
  p.x = prevX + p.xSpeed
  p.y = prevY + p.ySpeed
end

-- n 个子步的"前进 + 撞墙反弹"（原版 while(i < HITCHECKINTERVALS) 主体）
local function bounceSubsteps(p, ctx, n)
  for _ = 1, n do
    local prevX, prevY = p.x, p.y
    p.x = p.x + p.xSpeed
    p.y = p.y + p.ySpeed
    if ctx.wallHit(p.x, p.y) then
      p.x, p.y = prevX, prevY
      resolveBounce(p, ctx, prevX, prevY)
    end
  end
end

-- 点到折线的最短距离（deathRay 的 hitCheck2 近似：ray 描边命中坦克碰撞点）
local function distToSegment(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local l2 = dx * dx + dy * dy
  if l2 == 0 then return sqrt((px - ax) ^ 2 + (py - ay) ^ 2) end
  local t = ((px - ax) * dx + (py - ay) * dy) / l2
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  local cx, cy = ax + dx * t, ay + dy * t
  return sqrt((px - cx) ^ 2 + (py - cy) ^ 2)
end

local function distToPolyline(px, py, pts)
  local best = math.huge
  for i = 1, #pts - 1 do
    local d = distToSegment(px, py, pts[i].x, pts[i].y, pts[i + 1].x, pts[i + 1].y)
    if d < best then best = d end
  end
  return best
end

-- 坦克贴图"包含点"近似（等价 t.hitTest(px,py,true)）：
-- 原版为矢量形状命中，此处用 base/turret 两个矩形并集近似（中心对齐）。
-- 平台层可用真实渲染形状覆盖。
function M.makeTankContains(t)
  local s = t.s
  local th = t.rot * RAD
  local c, sn = cos(th), sin(th)
  local function inRect(px, py, hw, hh)
    local dx, dy = px - t.x, py - t.y
    local lx = (dx * c + dy * sn) / s
    local ly = (-dx * sn + dy * c) / s
    return abs(lx) <= hw and abs(ly) <= hh
  end
  return function(px, py)
    return inRect(px, py, M.BASE_W / 2, M.BASE_H / 2)
        or inRect(px, py, M.TURRET_W / 2, M.TURRET_H / 2)
  end
end

-- 底座形状近似（mine 邻近判定用，等价 t.base.hitTest(...)）
function M.makeTankBaseContains(t)
  local s = t.s
  local th = t.rot * RAD
  local c, sn = cos(th), sin(th)
  return function(px, py)
    local dx, dy = px - t.x, py - t.y
    local lx = (dx * c + dy * sn) / s
    local ly = (-dx * sn + dy * c) / s
    return abs(lx) <= M.BASE_W / 2 and abs(ly) <= M.BASE_H / 2
  end
end

M.BASE_W, M.BASE_H = 61, 81
M.TURRET_W, M.TURRET_H = 45, 77.5

-- 炮口位置（原版 owner.pos + (cos,sin)·SCALE·4.5/16）
local function muzzle(owner, ctx)
  local ang = (owner.rot - 90) * RAD
  return owner.x + cos(ang) * ctx.scale * 4.5 / 16,
         owner.y + sin(ang) * ctx.scale * 4.5 / 16
end

-- ============================================================
-- 2. 就绪 / 锁控（frame_53 第 1098-1141 行）
-- ============================================================
function M.weaponReady(owner, weapon, maxBullets)
  if weapon == "bullet" then return (owner.bulletsFired or 0) < (maxBullets or C.SETTINGS.maxBullets)
  elseif weapon == "laser" then return owner.laserReady
  elseif weapon == "frag" then return true
  elseif weapon == "gatling" then return owner.gatlingReady
  elseif weapon == "homing" then return owner.homingReady
  elseif weapon == "mine" then return true
  elseif weapon == "remote" then return not owner.remoteControlling
  elseif weapon == "electric" then return owner.electricReady
  elseif weapon == "deathRay" then return owner.deathRayReady
  elseif weapon == "elToro" then return owner.elToroReady
  end
end

function M.lockedControl(owner, weapon)
  if weapon == "laser" then return not owner.laserReady
  elseif weapon == "deathRay" then return not owner.deathRayReady
  elseif weapon == "remote" then return owner.remoteControlling
  elseif weapon == "elToro" then return not owner.elToroReady
  end
  return false
end

-- ============================================================
-- 3. 发射（返回待加入世界的投射物/控制器对象）
-- ============================================================

function M.fireBullet(owner, ctx)
  local k = ctx.scale / 50
  local ang = (owner.rot - 90) * RAD
  local x, y = muzzle(owner, ctx)
  owner.bulletsFired = (owner.bulletsFired or 0) + 1
  return {
    kind = "bullet", owner = owner, color = owner.turretColor,
    x = x, y = y,
    xSpeed = cos(ang) * C.BULLETSPEED / C.BULLETHITCHECKINTERVALS * k,
    ySpeed = sin(ang) * C.BULLETSPEED / C.BULLETHITCHECKINTERVALS * k,
    lifetime = C.BULLETLIFETIME, deadly = C.BULLETDEADLY,
    intervals = C.BULLETHITCHECKINTERVALS,
  }
end

function M.fireLaser(owner, ctx)
  local k = ctx.scale / 50
  local ang = (owner.rot - 90) * RAD
  local x, y = muzzle(owner, ctx)
  owner.laserReady = false
  ctx.setEquipment(owner, "none")
  return {
    kind = "laser", owner = owner, color = owner.turretColor,
    originX = x, originY = y, x = x, y = y,
    xSpeed = cos(ang) * C.LASERSPEED / C.LASERHITCHECKINTERVALS * k,
    ySpeed = sin(ang) * C.LASERSPEED / C.LASERHITCHECKINTERVALS * k,
    lifetime = C.LASERLIFETIME, deadly = C.LASERDEADLY,
    intervals = C.LASERHITCHECKINTERVALS, active = true, bounces = 0,
    linePoints = {},
  }
end

function M.fireFrag(owner, ctx)
  local k = ctx.scale / 50
  local ang = (owner.rot - 90) * RAD
  local x, y = muzzle(owner, ctx)
  local p = {
    kind = "frag", owner = owner, color = owner.turretColor,
    x = x, y = y,
    xSpeed = cos(ang) * C.FRAGSPEED / C.FRAGHITCHECKINTERVALS * k,
    ySpeed = sin(ang) * C.FRAGSPEED / C.FRAGHITCHECKINTERVALS * k,
    lifetime = C.FRAGLIFETIME, deadly = C.FRAGDEADLY,
    intervals = C.FRAGHITCHECKINTERVALS, level = C.FRAGLEVELS,
  }
  owner.lastFrag = p
  owner.fragFired = true
  return p
end

function M.fireGatling(owner, ctx)
  owner.gatlingReady = false
  return {
    kind = "gatling", owner = owner,
    active = true, spinSpeed = 0, fireCounter = 0, bulletsLeft = C.GATLINGBULLETS,
  }
end

function M.fireDeathRay(owner, ctx)
  local k = ctx.scale / 50
  local ang = (owner.rot - 90) * RAD
  local x, y = muzzle(owner, ctx)
  owner.deathRayReady = false
  return {
    kind = "deathRay", owner = owner, color = owner.turretColor,
    originX = x, originY = y, x = x, y = y,
    xSpeed = cos(ang) * (ctx.scale / 16), ySpeed = sin(ang) * (ctx.scale / 16),
    active = false, warmup = C.DEATHRAYWARMUPTIME, lifetime = C.DEATHRAYLIFETIME,
    curvePoints = {}, collisionPoints = {}, circleCounter = 0,
    rayThickness = 0, ballSize = 0, lengthCounter = 0,
    targetPosition = nil, straightLine = true, leftSide = false,
    targetCircleCenter = nil, targetCircleRadius = 1, targetCircleStartAngle = 0,
    _k = k,
  }
end

function M.fireHoming(owner, ctx)
  local k = ctx.scale / 50
  local ang = (owner.rot - 90) * RAD
  local x, y = muzzle(owner, ctx)
  owner.homingReady = false
  return {
    kind = "homing", owner = owner, color = owner.turretColor,
    x = x, y = y, rotation = owner.rot,
    xSpeed = cos(ang) * C.HOMINGSPEED / C.HOMINGHITCHECKINTERVALS * k,
    ySpeed = sin(ang) * C.HOMINGSPEED / C.HOMINGHITCHECKINTERVALS * k,
    lifetime = C.HOMINGLIFETIME, deadly = C.HOMINGDEADLY,
    intervals = C.HOMINGHITCHECKINTERVALS,
    homing = false, startuptime = C.HOMINGSTARTUPTIME, soundCounter = 0,
    target = nil, oldTarget = nil, targetColor = owner.baseColor,
  }
end

function M.layMine(owner, ctx)
  local k = ctx.scale / 50
  local ang = (owner.rot - 90) * RAD
  owner.minesLayed = (owner.minesLayed or 0) + 1
  local p = {
    kind = "mine", owner = owner, color = owner.turretColor,
    x = owner.x, y = owner.y, rotation = 180 + owner.rot,
    xSpeed = -cos(ang) * C.MINESPEED / C.MINEHITCHECKINTERVALS * k,
    ySpeed = -sin(ang) * C.MINESPEED / C.MINEHITCHECKINTERVALS * k,
    deadly = C.MINEDEADLY, intervals = C.MINEHITCHECKINTERVALS,
    hideCounter = C.MINEHIDETIME, landed = false, armed = false,
    detonating = false, detonateCounter = C.MINEDETONATETIME,
    alpha = 100, scaleFactor = 25 * k / 100,
  }
  if owner.minesLayed >= C.MINENUMBER then
    ctx.setWeapon(owner, "bullet")
  end
  return p
end

function M.fireRemote(owner, ctx)
  local k = ctx.scale / 50
  local ang = (owner.rot - 90) * RAD
  local x, y = muzzle(owner, ctx)
  owner.remoteControlling = true
  return {
    kind = "remote", owner = owner, color = owner.turretColor,
    x = x, y = y, rotation = owner.rot, turnSpeed = C.REMOTETURNSPEED,
    xSpeed = cos(ang) * C.REMOTESPEED / C.REMOTEHITCHECKINTERVALS * k,
    ySpeed = sin(ang) * C.REMOTESPEED / C.REMOTEHITCHECKINTERVALS * k,
    lifetime = C.REMOTELIFETIME, deadly = C.REMOTEDEADLY,
    intervals = C.REMOTEHITCHECKINTERVALS,
    targetColor = owner.baseColor,
  }
end

function M.fireElectric(owner, ctx)
  local k = ctx.scale / 50
  local ang = (owner.rot - 90) * RAD
  local x, y = muzzle(owner, ctx)
  owner.electricReady = false
  local function mk(degOff)
    local a = (owner.rot - 90 + degOff) * RAD
    return {
      kind = "electric", owner = owner, color = owner.turretColor,
      x = x, y = y,
      xSpeed = cos(a) * C.BULLETSPEED / C.BULLETHITCHECKINTERVALS * k,
      ySpeed = sin(a) * C.BULLETSPEED / C.BULLETHITCHECKINTERVALS * k,
      lifetime = C.BULLETLIFETIME, deadly = C.BULLETDEADLY,
      intervals = C.BULLETHITCHECKINTERVALS,
    }
  end
  local b1, b2 = mk(-5), mk(5)
  b1.isFirst, b1.partner, b2.partner = true, b2, b1
  return b1, b2
end

-- 发射总入口：返回对象列表（electric 返回 2 个）
function M.fire(owner, weapon, ctx)
  if weapon == "bullet" then return { M.fireBullet(owner, ctx) }
  elseif weapon == "laser" then return { M.fireLaser(owner, ctx) }
  elseif weapon == "frag" then return { M.fireFrag(owner, ctx) }
  elseif weapon == "gatling" then return { M.fireGatling(owner, ctx) }
  elseif weapon == "deathRay" then return { M.fireDeathRay(owner, ctx) }
  elseif weapon == "homing" then return { M.fireHoming(owner, ctx) }
  elseif weapon == "mine" then return { M.layMine(owner, ctx) }
  elseif weapon == "remote" then return { M.fireRemote(owner, ctx) }
  elseif weapon == "electric" then
    local b1, b2 = M.fireElectric(owner, ctx)
    return { b1, b2 }
  end
  return {}
end

-- ============================================================
-- 4. 弹片（fragbombfragment）
-- ============================================================
function M.spawnFragments(p, ctx, count)
  local k = ctx.scale / 50
  for _ = 1, count do
    local ang = rnd(360)
    local speed = (C.FRAGSPEED - random() * C.FRAGSPEED + 4) / C.FRAGHITCHECKINTERVALS * k
    local rs = 25 + rnd(25)
    ctx.spawn({
      kind = "fragment", owner = p.owner, color = p.color,
      x = p.x, y = p.y, rotation = rnd(360),
      xSpeed = cos((ang - 90) * RAD) * speed,
      ySpeed = sin((ang - 90) * RAD) * speed,
      rotSpeed = (random() <= 0.5) and -rs or rs,
      active = true, alpha = 100, intervals = C.FRAGHITCHECKINTERVALS,
    })
  end
end

local steppers = {}

steppers.fragment = function(p, ctx)
  if p.active then
    for _ = 1, p.intervals do
      p.x = p.x + p.xSpeed
      p.y = p.y + p.ySpeed
      if ctx.wallHit(p.x, p.y) then
        ctx.sound(random() > 0.5 and "soundFragmentHit" or "soundFragmentHit2")
        p.active = false
        break
      end
    end
    p.rotation = p.rotation + p.rotSpeed
    hitTanks(p, ctx, true)
    if p.remove then return false end
  else
    p.alpha = p.alpha - 5
    if p.alpha <= 0 then return false end
  end
  return true
end

-- ============================================================
-- 5. 各武器逐帧逻辑
-- ============================================================

-- bullet：弹跳 → 命中 → 生命周期耗尽冒烟
steppers.bullet = function(p, ctx)
  bounceSubsteps(p, ctx, p.intervals)
  hitTanks(p, ctx, p.deadly == 0)
  if p.remove then return false end
  if p.deadly > 0 then p.deadly = p.deadly - 1 end
  p.lifetime = p.lifetime - 1
  if p.lifetime <= 0 then
    if p.owner then p.owner.bulletsFired = (p.owner.bulletsFired or 0) - 1 end
    ctx.sound("soundPoof")
    ctx.smoke("bullet", p, C.NUMBEROFSMOKECLOUDS * 2)
    return false
  end
  return true
end

-- gatlingBullet：与 bullet 同构，参数不同
steppers.gatlingBullet = function(p, ctx)
  bounceSubsteps(p, ctx, p.intervals)
  hitTanks(p, ctx, p.deadly == 0)
  if p.remove then return false end
  if p.deadly > 0 then p.deadly = p.deadly - 1 end
  p.lifetime = p.lifetime - 1
  if p.lifetime <= 0 then
    ctx.smoke("gatlingBullet", p, C.NUMBEROFSMOKECLOUDS)
    return false
  end
  return true
end

-- laser：射线推进 70 子步/帧，撞墙反弹，命中即 lifetime=1；lifetime=0 后逐帧回缩
steppers.laser = function(p, ctx)
  if p.active then
    for j = 1, p.intervals do
      local prevX, prevY = p.x, p.y
      p.x = p.x + p.xSpeed
      p.y = p.y + p.ySpeed
      if ctx.wallHit(p.x, p.y) then
        p.bounces = p.bounces + 1
        p.x, p.y = prevX, prevY
        resolveBounce(p, ctx, prevX, prevY)
      end
      if p.deadly > 0 then p.deadly = p.deadly - 1 end
      if p.deadly == 0 then
        local tanks = ctx.tanks
        for i = 1, #tanks do
          local t = tanks[i]
          if t.alive and ctx.tankContains(t, p.x, p.y) then
            ctx.onHit(p.owner, t)
            p.lifetime = 1
            j = p.intervals   -- 跳出子步循环（原版 j = LASERHITCHECKINTERVALS）
            break
          end
        end
      end
      p.linePoints[#p.linePoints + 1] = { x = p.x, y = p.y }
    end
  else
    for _ = 1, p.intervals do
      if #p.linePoints == 0 then break end
      table.remove(p.linePoints, 1)
    end
    if #p.linePoints == 0 then return false end
  end
  p.lifetime = p.lifetime - 1
  if p.lifetime == 0 then
    p.owner.laserReady = true
    p.active = false
    ctx.setWeapon(p.owner, "bullet")
  end
  return true
end

-- fragbomb：弹跳 → 命中/寿命尽 → 引爆
steppers.frag = function(p, ctx)
  if p.owner and not p.owner.alive then
    M.detonateFrag(p, ctx)
    return false
  end
  bounceSubsteps(p, ctx, p.intervals)
  if p.deadly == 0 then
    local tanks = ctx.tanks
    for i = 1, #tanks do
      local t = tanks[i]
      if t.alive and ctx.tankContains(t, p.x, p.y) then
        ctx.onHit(p.owner, t)
        M.detonateFrag(p, ctx)
        return false
      end
    end
  end
  if p.deadly > 0 then p.deadly = p.deadly - 1 end
  p.lifetime = p.lifetime - 1
  if p.lifetime <= 0 then
    M.detonateFrag(p, ctx)
    return false
  end
  return true
end

function M.detonateFrag(p, ctx)
  ctx.shake(max(C.MAXSHAKE, 7))          -- _root.shake = max(MAXSHAKE, shake+7)
  if p.owner then
    p.owner.fragFired = false
    p.owner.lastFrag = nil
  end
  ctx.setWeapon(p.owner, "bullet")
  if (p.level or 0) > 0 then
    M.spawnFragments(p, ctx, C.FRAGFRAGMENTS)
  end
  ctx.smoke("frag", p, C.FRAGSMOKECLOUDS)
  p.remove = true
end

-- gatling：转管控制器（不移动），转速到顶后每 3 帧吐一发
steppers.gatling = function(p, ctx)
  if not p.owner.alive then return false end
  if p.active and p.owner.triggerReleased then
    p.active = false
    p.spinSpeed = p.spinSpeed + 35
  end
  if p.active then
    if p.spinSpeed < C.GATLINGSPINSPEED then p.spinSpeed = p.spinSpeed + 1 end
    if p.spinSpeed == C.GATLINGSPINSPEED then
      p.fireCounter = p.fireCounter + 1
      if p.fireCounter % 3 == 0 then
        if p.bulletsLeft > 0 then
          p.bulletsLeft = p.bulletsLeft - 1
          local k = ctx.scale / 50
          local ang = (p.owner.rot - 90) * RAD
          local x, y = muzzle(p.owner, ctx)
          local a = (p.owner.rot - 90 + random() * 11 - 5.5) * RAD
          ctx.spawn({
            kind = "gatlingBullet", owner = p.owner, color = p.owner.turretColor,
            x = x, y = y,
            xSpeed = cos(a) * C.GATLINGSPEED / C.GATLINGHITCHECKINTERVALS * k,
            ySpeed = sin(a) * C.GATLINGSPEED / C.GATLINGHITCHECKINTERVALS * k,
            lifetime = C.GATLINGLIFETIME, deadly = C.GATLINGDEADLY,
            intervals = C.GATLINGHITCHECKINTERVALS,
          })
          ctx.sound("soundGatlingShot")
        else
          ctx.sound("soundExposion")
        end
      end
    end
  else
    if p.spinSpeed > 0 then p.spinSpeed = p.spinSpeed - 1 end
    if p.spinSpeed == 0 then
      p.owner.gatlingReady = true
      ctx.setWeapon(p.owner, "bullet")
      if p.spinSpeed == 0 and p.owner.gatlingReady then return false end
    end
  end
  return true
end

-- homing：起飞 50 帧后锁定最近坦克，沿距离场逼近
steppers.homing = function(p, ctx)
  local k = ctx.scale / 50
  if p.homing then
    local d = ctx.distancesForMaze
    local sx, sy = floor(p.x / ctx.scale), floor(p.y / ctx.scale)
    local col = d and d[sx] and d[sx][sy]
    local best = 1000
    local tx, ty
    local tanks = ctx.tanks
    for i = 1, #tanks do
      local t = tanks[i]
      if t.alive then
        local cx, cy = floor(t.x / ctx.scale), floor(t.y / ctx.scale)
        local dd = col and col[cx] and col[cx][cy]
        if dd ~= nil and (dd < best or (dd == best and t ~= p.owner)) then
          best = dd; tx, ty = cx, cy
          p.target = t; p.targetColor = t.baseColor
        end
      end
    end
    if not (p.target and p.target.alive) then
      p.homing = false
    else
      if p.target ~= p.oldTarget then ctx.sound("soundHoming") end
      p.oldTarget = p.target
      local path = ctx.getShortestPathWithDistances
        and ctx.getShortestPathWithDistances(sx, sy, tx, ty) or nil
      local gx, gy
      local cur = col and col[tx] and col[tx][ty]
      if cur ~= nil and cur + 1 <= 1 then
        gx, gy = p.target.x, p.target.y
      elseif path and path[1] then
        gx = (path[1].x + 0.5) * ctx.scale
        gy = (path[1].y + 0.5) * ctx.scale
      else
        gx, gy = p.target.x, p.target.y
      end
      p.soundCounter = p.soundCounter + 1
      local step = 0.12 / p.intervals
      for _ = 1, p.intervals do
        local prevX, prevY = p.x, p.y
        p.x = p.x + p.xSpeed
        p.y = p.y + p.ySpeed
        if ctx.wallHit(p.x, p.y) then
          p.x, p.y = prevX, prevY
          resolveBounce(p, ctx, prevX, prevY)
        end
        if gx - p.x < 0 then p.xSpeed = p.xSpeed - step else p.xSpeed = p.xSpeed + step end
        if gy - p.y < 0 then p.ySpeed = p.ySpeed - step else p.ySpeed = p.ySpeed + step end
        local len = sqrt(p.xSpeed * p.xSpeed + p.ySpeed * p.ySpeed)
        local maxSpeed = C.HOMINGSPEED / p.intervals * k
        if len > maxSpeed then
          p.xSpeed = p.xSpeed / len * maxSpeed
          p.ySpeed = p.ySpeed / len * maxSpeed
        end
      end
    end
  else
    bounceSubsteps(p, ctx, p.intervals)
  end

  -- 朝向 = 速度方向（原版由 aimAngle 计算 _rotation）
  if p.xSpeed < 0 then
    if p.ySpeed < 0 then p.rotation = (-PI + atan(p.ySpeed / p.xSpeed)) * 180 / PI
    else p.rotation = (PI + atan(p.ySpeed / p.xSpeed)) * 180 / PI end
  elseif p.xSpeed > 0 then
    p.rotation = atan(p.ySpeed / p.xSpeed) * 180 / PI
  elseif p.ySpeed < 0 then
    p.rotation = -90
  else
    p.rotation = 90
  end
  p.rotation = p.rotation + 90

  ctx.smoke("homing", p, C.HOMINGSMOKECLOUDS)

  if p.deadly == 0 then
    local tanks = ctx.tanks
    for i = 1, #tanks do
      local t = tanks[i]
      if t.alive and ctx.tankContains(t, p.x, p.y) then
        ctx.onHit(p.owner, t)
        p.owner.homingReady = true
        ctx.setWeapon(p.owner, "bullet")
        return false
      end
    end
  end
  if p.startuptime >= 0 then p.startuptime = p.startuptime - 1 end
  if p.startuptime == 0 then p.homing = true end
  if p.deadly > 0 then p.deadly = p.deadly - 1 end
  p.lifetime = p.lifetime - 1
  if p.lifetime <= 0 then
    p.owner.homingReady = true
    ctx.setWeapon(p.owner, "bullet")
    ctx.sound("soundPoof")
    ctx.smoke("bullet", p, C.NUMBEROFSMOKECLOUDS * 2)
    return false
  end
  return true
end

-- mine：减速落地 → 邻近坦克激活 → 坦克离开后延时引爆
local function mineNearTank(p, ctx)
  local r = 25 * p.scaleFactor          -- mine 局部半径 25 换算到全局像素
  local a = 0
  while a < 6.283185 do
    local gx = p.x + cos(a) * r
    local gy = p.y + sin(a) * r
    local tanks = ctx.tanks
    for i = 1, #tanks do
      local t = tanks[i]
      if t.alive and ctx.tankBaseContains(t, gx, gy) then return true end
    end
    a = a + 0.5
  end
  return false
end

steppers.mine = function(p, ctx)
  bounceSubsteps(p, ctx, p.intervals)
  p.xSpeed = p.xSpeed * 0.75
  p.ySpeed = p.ySpeed * 0.75
  if not p.landed then
    if abs(p.xSpeed) < 0.15 and abs(p.ySpeed) < 0.15 then
      p.landed = true
      p.xSpeed, p.ySpeed = 0, 0
      ctx.sound("soundMineLand")
      ctx.smoke("minedust", p, C.NUMBEROFDUSTCLOUDS / 2)
    end
  end
  if p.deadly == 0 and not p.armed then
    if mineNearTank(p, ctx) then
      p.armed = true
      ctx.sound("soundMineArm")
    end
  end
  if p.armed and not p.detonating then
    if not mineNearTank(p, ctx) then
      p.detonating = true
      ctx.sound("soundMineDetonate")
    end
  end
  if p.detonating then
    if p.detonateCounter > 0 then p.detonateCounter = p.detonateCounter - 1 end
    if p.detonateCounter == 0 then
      M.detonateMine(p, ctx)
      return false
    end
  end
  if p.deadly > 0 then p.deadly = p.deadly - 1 end
  if p.deadly == 0 and not p.armed then
    if p.hideCounter > 0 then p.hideCounter = p.hideCounter - 1 end
    if p.hideCounter == 0 and p.alpha > 0 then p.alpha = p.alpha - 10 end
  elseif p.armed then
    if p.alpha < 100 then p.alpha = p.alpha + 10 end
  end
  return true
end

function M.detonateMine(p, ctx)
  ctx.shake(min(C.MAXSHAKE, 7))
  ctx.sound("soundExplosion3")
  M.spawnFragments(p, ctx, C.MINEFRAGMENTS)
  ctx.smoke("mine", p, C.MINESMOKECLOUDS)
  p.remove = true
end

-- remote：遥控导弹（鼠标或左右键转向），撞墙同时改朝向
steppers.remote = function(p, ctx)
  local k = ctx.scale / 50
  if p.owner.alive then
    if p.owner.mouseTank then
      local mx, my = ctx.mousePos()
      local dx, dy = mx - p.x, my - p.y
      local aimAngle
      if dx < 0 then
        if dy < 0 then aimAngle = -PI + atan(dy / dx) else aimAngle = PI + atan(dy / dx) end
      elseif dx > 0 then
        aimAngle = atan(dy / dx)
      elseif dy < 0 then
        aimAngle = -PI / 2
      else
        aimAngle = PI / 2
      end
      p.rotation = (aimAngle + PI / 2) * 180 / PI
    else
      local turnSize = 0
      if ctx.keyDown(p.owner.KEYTURNLEFT) then turnSize = -p.turnSpeed end
      if ctx.keyDown(p.owner.KEYTURNRIGHT) then turnSize = turnSize + p.turnSpeed end
      p.rotation = p.rotation + turnSize
    end
  end
  local accel = 0.35 * C.REMOTESPEED / p.intervals * k
  p.xSpeed = p.xSpeed + accel * cos((p.rotation - 90) * RAD)
  p.ySpeed = p.ySpeed + accel * sin((p.rotation - 90) * RAD)
  local len = sqrt(p.xSpeed * p.xSpeed + p.ySpeed * p.ySpeed)
  local maxSpeed = C.REMOTESPEED / p.intervals * k
  if len > maxSpeed then
    p.xSpeed = p.xSpeed * maxSpeed / len
    p.ySpeed = p.ySpeed * maxSpeed / len
  end

  for _ = 1, p.intervals do
    local prevX, prevY = p.x, p.y
    p.x = p.x + p.xSpeed
    p.y = p.y + p.ySpeed
    if ctx.wallHit(p.x, p.y) then
      p.x, p.y = prevX, prevY
      local hitX = ctx.wallHit(prevX - p.xSpeed, prevY + p.ySpeed)
      local hitY = ctx.wallHit(prevX + p.xSpeed, prevY - p.ySpeed)
      if hitX and not hitY then
        p.ySpeed = -p.ySpeed
        p.rotation = 180 - p.rotation
      elseif hitY and not hitX then
        p.xSpeed = -p.xSpeed
        p.rotation = -p.rotation
      else
        p.xSpeed = -p.xSpeed
        p.ySpeed = -p.ySpeed
        p.rotation = p.rotation + 180
      end
      p.x = prevX + p.xSpeed
      p.y = prevY + p.ySpeed
    end
  end

  ctx.smoke("remote", p, C.REMOTESMOKECLOUDS)

  if p.deadly == 0 then
    local tanks = ctx.tanks
    for i = 1, #tanks do
      local t = tanks[i]
      if t.alive and ctx.tankContains(t, p.x, p.y) then
        ctx.onHit(p.owner, t)
        p.owner.remoteControlling = false
        ctx.setWeapon(p.owner, "bullet")
        return false
      end
    end
  end
  if p.deadly > 0 then p.deadly = p.deadly - 1 end
  p.lifetime = p.lifetime - 1
  if p.lifetime <= 0 then
    p.owner.remoteControlling = false
    ctx.setWeapon(p.owner, "bullet")
    ctx.sound("soundPoof")
    ctx.smoke("bullet", p, C.NUMBEROFSMOKECLOUDS * 2)
    return false
  end
  return true
end

-- electric：两发弹丸 + 电弧（原版无对坦克伤害判定，保持一致）
steppers.electric = function(p, ctx)
  bounceSubsteps(p, ctx, p.intervals)
  if p.isFirst and p.partner then
    ctx.spark(p, p.partner)
  end
  if p.deadly > 0 then p.deadly = p.deadly - 1 end
  p.lifetime = p.lifetime - 1
  if p.lifetime <= 0 then
    p.owner.electricReady = true
    ctx.setWeapon(p.owner, "bullet")
    ctx.sound("soundPoof")
    ctx.smoke("bullet", p, C.NUMBEROFSMOKECLOUDS * 2)
    return false
  end
  return true
end

-- deathRay：蓄力 → 沿"朝最近坦克弯曲"的路径推进成一条射线 → 命中 → 回缩
local function deathRayTargetClosest(dr, ctx, absX, absY, dirX, dirY)
  local k = dr._k
  dr.circleCounter = 0
  dr.straightLine = true
  dr.targetPosition = nil
  local bestDist = 1.0e33
  local tanks = ctx.tanks
  for i = 1, #tanks do
    local t = tanks[i]
    if t ~= dr.owner and t.alive then
      local lx, ly = t.x - absX, t.y - absY
      local perpX, perpY = dirY, -dirX
      if dirX * lx + dirY * ly > 0 then
        local d2 = lx * lx + ly * ly
        if d2 <= bestDist then
          bestDist = d2
          dr.targetPosition = { x = t.x - dr.originX, y = t.y - dr.originY }
          dr.straightLine = abs(perpX * lx + perpY * ly) <= 0.00001
          if not dr.straightLine then
            local n = sqrt(perpX * perpX + perpY * perpY)
            perpX, perpY = perpX / n, perpY / n
            local tt = (lx * lx + ly * ly) / (2 * perpX * lx + 2 * perpY * ly)
            if tt > 0 then
              tt = max(650 * k, tt); dr.leftSide = true
            else
              tt = min(-650 * k, tt); dr.leftSide = false
            end
            local cx, cy = absX + perpX * tt, absY + perpY * tt
            dr.targetCircleCenter = { x = cx, y = cy }
            dr.targetCircleRadius = sqrt((cx - absX) ^ 2 + (cy - absY) ^ 2)
            local vx, vy = -(cx - absX), -(cy - absY)
            local ang
            if vx ~= 0 then
              if vx > 0 then ang = 1.570796 + atan(vy / vx)
              else ang = -1.570796 + atan(vy / vx) end
            elseif vy > 0 then ang = 3.141593
            elseif vy < 0 then ang = 0
            else ang = 0 end
            dr.targetCircleStartAngle = ang - 1.570796
          end
        end
      end
    end
  end
end

steppers.deathRay = function(p, ctx)
  if not p.owner.alive then return false end
  local k = p._k

  if p.warmup > 0 then
    p.ballSize = p.ballSize + 0.75
    p.warmup = p.warmup - 1
  end

  if p.warmup == 0 then
    p.x, p.y = p.originX, p.originY
    deathRayTargetClosest(p, ctx, p.x, p.y, p.xSpeed, p.ySpeed)
    local guard = 0
    while ctx.insideMaze(p.x, p.y) do
      guard = guard + 1
      if guard > 20000 then break end
      local toTargetX, toTargetY
      if p.targetPosition then
        toTargetX = p.targetPosition.x - (p.x - p.originX)
        toTargetY = p.targetPosition.y - (p.y - p.originY)
      end
      local dx, dy
      if p.straightLine then
        dx, dy = p.xSpeed, p.ySpeed
      else
        local len = sqrt(p.xSpeed * p.xSpeed + p.ySpeed * p.ySpeed)
        local sgn = p.leftSide and -1 or 1
        local aa = p.targetCircleStartAngle + p.circleCounter * sgn * len / p.targetCircleRadius
        dx = sin(aa) * len
        dy = -cos(aa) * len
        if not p.leftSide then dx, dy = -dx, -dy end
      end
      p.xSpeed, p.ySpeed = dx, dy
      p.x = p.x + p.xSpeed
      p.y = p.y + p.ySpeed
      p.lengthCounter = p.lengthCounter + 1
      p.circleCounter = p.circleCounter + 1
      p.curvePoints[#p.curvePoints + 1] = { x = p.x, y = p.y }
      if p.targetPosition and dx * toTargetX + dy * toTargetY <= 0 then
        deathRayTargetClosest(p, ctx, p.x, p.y, dx, dy)
      end
      if ctx.wallHit(p.x, p.y) then
        p.collisionPoints[#p.collisionPoints + 1] = { x = p.x, y = p.y }
      end
    end
    -- 尾部回退：直到端点四向探测都在迷宫内
    local guard2 = 0
    while #p.curvePoints > 0 do
      guard2 = guard2 + 1
      if guard2 > 20000 then break end
      local last = p.curvePoints[#p.curvePoints]
      local inside = ctx.insideMaze(last.x + 3 * k, last.y)
        and ctx.insideMaze(last.x - 3 * k, last.y)
        and ctx.insideMaze(last.x, last.y + 3 * k)
        and ctx.insideMaze(last.x, last.y - 3 * k)
      if inside then break end
      table.remove(p.curvePoints)
      p.lengthCounter = p.lengthCounter - 1
    end
    p.active = true
    p.warmup = p.warmup - 1
  end

  if p.active then
    p.ballSize = max(0, p.ballSize - 5)
    p.rayThickness = min(5, p.rayThickness + 1)
    ctx.particles("deathRay", p)
    -- 命中：射线描边扫过坦克碰撞点（front/left/rear，与原版一致）
    local half = p.rayThickness * k / 2
    local tanks = ctx.tanks
    for i = 1, #tanks do
      local t = tanks[i]
      if t ~= p.owner and t.alive then
        local groups = t.hitPoints
        local pts = {}
        if groups then
          for _, g in ipairs({ "front", "left", "rear" }) do
            local gp = groups[g]
            if gp then for _, q in ipairs(gp) do pts[#pts + 1] = q end end
          end
        end
        for _, q in ipairs(pts) do
          local gx, gy = tankPointGlobal(t, q[1], q[2])
          if distToPolyline(gx, gy, p.curvePoints) <= half then
            ctx.onHit(p.owner, t)
            break
          end
        end
      end
    end
    p.lifetime = p.lifetime - 1
    if p.lifetime == 0 then p.active = false end
  end

  if not p.active and p.warmup < 0 then
    p.rayThickness = p.rayThickness - 3
    if p.rayThickness <= 0 then
      p.owner.deathRayReady = true
      ctx.setWeapon(p.owner, "bullet")
      return false
    end
  end
  return true
end

-- ============================================================
-- 6. 统一驱动入口
-- ============================================================
function M.step(p, ctx)
  local f = steppers[p.kind]
  if not f then return true end
  return f(p, ctx)
end

-- 对指定坦克调用所有装备的 repulseBullet（原版 bullet 每个子步都做）
function M.repulseAll(p, ctx, equipments)
  for i = 1, #equipments do
    local eq = equipments[i]
    if eq.repulseBullet then eq:repulseBullet(p, ctx) end
  end
end

return M
end

-- ==================== 模块 src.ai ====================
__defs["src.ai"] = function()
--[[
  坦克动荡2 —— AI 决策树（纯逻辑，可脱离游戏运行时单测）

  逐行对照 DefineSprite_272_tankTroubleAI/frame_1/DoAction.as 移植（共 1499 行）。
  由 gameTank 每帧驱动（asset_scripts/GameTank/.../frame_1 第 644-651 行）：
      if ai:makeDecisionsAndUpdateGoal() then ai:decideActionsToAchieveGoal() end
      ai:setInputToDoActions()
  随后 attemptToMove(t, forward, backup, turnLeft, turnRight) 消费 AI 写入的输入。

  每个坦克持有一个 AI 实例（原版挂在坦克下的 "AI" 子 clip 上），实例状态独立：
      myGoal / myActionsForGoal / goalId / stuckTime / currentAggresiveness

  坐标系与 maze.lua / tank.lua 一致（mazemc 局部像素）。
  原版中 _root.game 与 mazemc 均在 (0,0)，故 `_root.game.mazemc.hitTest(gx,gy)`
  等价于本模块的 ctx.wallHit(gx,gy)；`tank.hitTest(gx,gy,true/false)` 等价于
  ctx.tankShapeContains / ctx.tankBBoxContains。

  运行环境（ctx）由平台层提供：
    ctx.scale                          SCALE
    ctx.maze                           迷宫（maze.lua 结构）
    ctx.deadEnds                       死胡同惩罚场（maze.findDeadEnds）
    ctx.fieldOf(cx,cy)                 以格 (cx,cy) 为源的距离场（原 distancesForMaze[cx][cy]）
    ctx.distAt(fx,fy,cx,cy)            距离场取值（原 distancesForMaze[fx][fy][cx][cy]）
    ctx.wallHit(px,py)                 像素级墙体判定
    ctx.tankShapeContains(t,px,py)     等价 t.hitTest(px,py,true)
    ctx.tankBBoxContains(t,px,py)      等价 t.hitTest(px,py,false)
    ctx.tanks / ctx.tankCount          坦克数组（元素含 AI 所需字段，见下）
    ctx.tankFields[i]                  {x,y} 第 i 辆坦克所在格
    ctx.aliveCount                     存活坦克数
    ctx.settingsMaxBullets             普通弹同时在场上限
    ctx.bullets / ctx.frags / ctx.fragFragments / ctx.gatlingBullets / ctx.crates
                                       各类投射物 / 补给箱数组
    ctx.pathApi                        寻路三函数（maze.lua 导出）
    ctx.log(msg)                       调试输出（可选）

  坦克需具备字段（tank.lua 提供 + 平台层补充）：
    x, y, rot(=原 _rotation), turnSpeed, hitSomething,
    currentWeapon, bulletsFired, fragFired, lastFrag, gatlingReady,
    currentEquipment, equipment, hitPoints
  并需 ctx.tankExpandedHit(t, part, k)（等价 t.expandedHitCheck(t.hitPointsXxx, k)）
]]

local C = require("src.constants")

local M = {}

local cos, sin, sqrt, abs, floor, ceil, min, max, atan, random =
  math.cos, math.sin, math.sqrt, math.abs, math.floor, math.ceil, math.min, math.max,
  math.atan, math.random
local PI, RAD = math.pi, math.pi / 180

local function round(v) return floor(v + 0.5) end          -- AS Math.round（半值向 +∞）
local function rnd(n) return floor(random() * n) end       -- AS random(n)：[0,n)

-- ============================================================
-- 1. 权威常量（DoAction.as 第 1472-1499 行）
--    与 SCALE 无关的量在此固定；随 SCALE 变化的量在 new() 内计算。
-- ============================================================
local AGGRESIVENESS               = 0.5
local COWARDNESS                  = 0.7
local GREEDY                      = 1
local LONGESTPATHTOSHOOT          = 7
local LONGESTPATHTONOTHESITATETOSHOOT = 2
local LONGESTPATHTORUN            = 10
local MAXSTUCKTIME                = 1
local IDLEDRIVETOWARDENEMYPRIORITY = 0.1
local IDLEDRIVEPRIORITY           = 0.1
local MAXCLOSESTCELLDISTANCE      = 2
local MAXTIMETODODGEBULLET        = 75
local MAXTIMETODODGEFRAGBOMBFRAGMENT = 50
local MAXTIMETODODGEGATLINGBULLET = 75
local MAXCELLDISTTODODGEFRAGBOMB  = 5
local MAXCELLDISTTODODGELASER     = 2
local MAXCELLDISTTOGOFORCRATE     = 10
-- 第 1493 行：MAXTIMETODODGEFRAGBOMBFRAGMENT * (FRAGSPEED + 4) / 50
local MAXCELLDISTTODODGEFRAGBOMBFRAGMENT =
  MAXTIMETODODGEFRAGBOMBFRAGMENT * (C.FRAGSPEED + 4) / 50

M.AGGRESIVENESS = AGGRESIVENESS
M.COWARDNESS    = COWARDNESS

-- ============================================================
-- 2. 内部工具
-- ============================================================

-- 朝 (dx,dy) 的角度（Flash 角度：0° 朝上）；与 DoAction.as 中反复出现的公式一致
local function angleToward(dx, dy, fallback)
  if dx ~= 0 then
    if dx > 0 then
      return 90 + atan(dy / dx) * 180 / PI
    else
      return -90 + atan(dy / dx) * 180 / PI
    end
  elseif dy > 0 then
    return 180
  elseif dy < 0 then
    return 0
  else
    return fallback
  end
end

-- 把角度归一化到 (-180,180]
local function normalizeAngle(a)
  if a < -180 then a = 360 + a end
  if a > 180 then a = a - 360 end
  return a
end

-- 依据当前角 cur 与目标角 target 决定转向（gameTank/AI 通用段）
local function turnDecision(cur, target)
  local turnLeft, turnRight = false, false
  if target > cur then
    if abs(target - cur) > 180 then turnLeft = true else turnRight = true end
  elseif target < cur then
    if abs(target - cur) > 180 then turnRight = true else turnLeft = true end
  end
  return turnLeft, turnRight
end

local function push(ai, action)
  local a = ai.actions
  a[#a + 1] = action
end

-- ============================================================
-- 3. checkPathForCollision —— 第 197-268 行
--    沿速度步进，遇墙解算反弹，返回 {x,y,xSpeed,ySpeed,t}；未遇墙返回 nil
-- ============================================================
local function checkPathForCollision(ctx, x, y, xSpeed, ySpeed, hitCheckInterval, maxtime, lifetime)
  lifetime = min(maxtime, lifetime)
  local t = 0
  while lifetime > 0 do
    local i = 0
    local prevX, prevY
    local hitWall = false
    while i < hitCheckInterval do
      prevX, prevY = x, y
      x = x + xSpeed
      y = y + ySpeed
      if ctx.wallHit(x, y) then hitWall = true; break end
      i = i + 1
    end
    if hitWall then
      -- 反弹：分别试探仅反转 x / 仅反转 y 是否脱离墙体
      local xInv = ctx.wallHit(prevX - xSpeed, prevY + ySpeed)
      local yInv = ctx.wallHit(prevX + xSpeed, prevY - ySpeed)
      if xInv and not yInv then
        ySpeed = -ySpeed
      elseif yInv and not xInv then
        xSpeed = -xSpeed
      else
        xSpeed, ySpeed = -xSpeed, -ySpeed
      end
      return { x = prevX + xSpeed, y = prevY + ySpeed,
               xSpeed = xSpeed, ySpeed = ySpeed, t = t }
    end
    lifetime = lifetime - 1
    t = t + 1
  end
  return nil
end

-- ============================================================
-- 4. checkBulletPath —— 第 269-383 行
--    以当前朝向模拟普通弹弹道（1/3 寿命），判断命中/自杀/最近距离
-- ============================================================
local function checkBulletPath(ai, angle)
  local ctx, tank = ai.ctx, ai.tank
  local scale = ctx.scale
  -- 原版此处直接读全局 MAXCLOSESTDISTANCE（= SCALE × MAXCLOSESTCELLDISTANCE）
  local maxClosestDistance = ai.MAXCLOSESTDISTANCE
  local x = tank.x + cos((angle - 90) * RAD) * scale * 4.5 / 16
  local y = tank.y + sin((angle - 90) * RAD) * scale * 4.5 / 16
  local xs = cos((angle - 90) * RAD) * C.BULLETSPEED * (scale / 50)
  local ys = sin((angle - 90) * RAD) * C.BULLETSPEED * (scale / 50)
  local life = C.BULLETLIFETIME / 3
  local deadly = C.BULLETDEADLY
  local closest = C.MOVIEWIDTH + C.MOVIEHEIGHT

  while life > 0 do
    -- 单子步前进
    local prevX, prevY = x, y
    x, y = x + xs, y + ys
    if ctx.wallHit(x, y) then
      local xInv = ctx.wallHit(prevX - xs, prevY + ys)
      local yInv = ctx.wallHit(prevX + xs, prevY - ys)
      if xInv and not yInv then
        ys = -ys
      elseif yInv and not xInv then
        xs = -xs
      else
        xs, ys = -xs, -ys
      end
      x, y = prevX + xs, prevY + ys
    end

    if deadly == 0 then
      -- 命中坦克判定（先包围盒后精确形状）
      local hitIdx
      for i = 1, ctx.tankCount do
        local tk = ctx.tanks[i]
        if tk and tk.alive then
          if ctx.tankBBoxContains(tk, x, y) then
            if ctx.tankShapeContains(tk, x, y) then hitIdx = i; break end
          elseif tk ~= tank then
            local d = abs(tk.x - x) + abs(tk.y - y)
            if d < maxClosestDistance then
              local cx, cy = floor(x / scale), floor(y / scale)
              local tf = ctx.tankFields[i]
              if tf and ctx.distAt(tf.x, tf.y, cx, cy) <= MAXCLOSESTCELLDISTANCE then
                if d < closest then closest = d end
              end
            end
          end
        end
      end
      if hitIdx then
        if ctx.tanks[hitIdx] == tank then
          return { result = "SUICIDE", time = C.BULLETLIFETIME / 3 - life }
        end
        return { result = "HIT", time = C.BULLETLIFETIME / 3 - life }
      end
    end

    if deadly > 0 then deadly = deadly - 1 end
    life = life - 1
  end

  return { result = "NOTHING", time = C.BULLETLIFETIME / 3, closest = closest }
end

-- ============================================================
-- 5. updateGoal —— 第 1-7 行
-- ============================================================
local function updateGoal(ai, temp)
  if ai.myGoal.priority < temp.priority then
    ai.myGoal = temp
  end
end

-- ============================================================
-- 6. dodgeTrajectories —— 第 8-107 行
--    在给定距离场筛选范围内，寻找可安全躲避的最近点，返回 dodgeBullet 目标
-- ============================================================
local function dodgeTrajectories(ai, fieldx, fieldy, bullets, maxTimeToDodge,
                                 maxDistToDodge, maxCellDistToDodge, hitCheckInterval, checkBounce)
  local ctx, tank = ai.ctx, ai.tank
  local scale = ctx.scale
  local best = { priority = 0 }
  local maxDist = maxDistToDodge

  for bi = 1, #bullets do
    local b = bullets[bi]
    local bx, by = b.x, b.y
    local cellx, celly = floor(bx / scale), floor(by / scale)
    if ctx.distAt(fieldx, fieldy, cellx, celly) <= maxCellDistToDodge then
      local nx = bx + b.xSpeed * hitCheckInterval
      local ny = by + b.ySpeed * hitCheckInterval
      local tx, ty = tank.x, tank.y
      local len2 = (nx - bx) * (nx - bx) + (ny - by) * (ny - by)
      local t = ((tx - bx) * (nx - bx) + (ty - by) * (ny - by)) / len2

      if t > -1 and t < maxTimeToDodge then
        local px = bx + t * (nx - bx)
        local py = by + t * (ny - by)
        local dx, dy = tx - px, ty - py
        local d = sqrt(dx * dx + dy * dy)
        local hit = checkPathForCollision(ctx, px, py, dx / d, dy / d, 1, ceil(d), ceil(d))
        if hit == nil and d < maxDist then
          local ex, ey = nx - px, ny - py
          local el = sqrt(ex * ex + ey * ey)
          local hit2 = checkPathForCollision(ctx, px, py, ex / el, ey / el, 1, ceil(el), ceil(el))
          if hit2 == nil then
            maxDist = min(maxDist, d)
            best = { goal = "dodgeBullet", x = b.x, y = b.y,
                     closest = { x = px, y = py }, dist = d, t = t,
                     dir = { x = nx - bx, y = ny - by },
                     maxTime = maxTimeToDodge, maxDist = maxDistToDodge,
                     period = 10, priority = 1, updateContinuously = false, id = ai.goalId }
            ai.goalId = ai.goalId + 1
          end
        end
      end

      -- 弹道反弹后仍可能命中：预测反弹点后再判定一次
      if maxDist > scale / 4 and checkBounce then
        local bounce = checkPathForCollision(ctx, bx, by, b.xSpeed, b.ySpeed,
                                             hitCheckInterval, 12, b.lifetime)
        if bounce then
          bx, by = bounce.x, bounce.y
          nx = bounce.x + bounce.xSpeed * hitCheckInterval
          ny = bounce.y + bounce.ySpeed * hitCheckInterval
          len2 = (nx - bx) * (nx - bx) + (ny - by) * (ny - by)
          t = ((tx - bx) * (nx - bx) + (ty - by) * (ny - by)) / len2
          if t > 0 and t < maxTimeToDodge - bounce.t then
            local px = bx + t * (nx - bx)
            local py = by + t * (ny - by)
            local dx, dy = tx - px, ty - py
            local d = sqrt(dx * dx + dy * dy)
            local hit = checkPathForCollision(ctx, px, py, dx / d, dy / d, 1, ceil(d), ceil(d))
            if hit == nil and d < maxDist then
              local ex, ey = px - bx, py - by
              local el = sqrt(ex * ex + ey * ey)
              local hit2 = checkPathForCollision(ctx, bx, by, ex / el, ey / el, 1, ceil(el), ceil(el))
              if hit2 == nil then
                maxDist = min(maxDist, d)
                best = { goal = "dodgeBullet", x = b.x, y = b.y,
                         closest = { x = px, y = py }, dist = d, t = t + bounce.t,
                         dir = { x = nx - bx, y = ny - by },
                         maxTime = maxTimeToDodge, maxDist = maxDistToDodge,
                         period = 10, priority = 1, updateContinuously = false, id = ai.goalId }
                ai.goalId = ai.goalId + 1
              end
            end
          end
        end
      end
    end
  end

  return best
end

-- ============================================================
-- 7. tryToRetaliate —— 第 108-196 行
--    被追杀时尝试反击（仅 bullet/laser/frag 有对应逻辑）
-- ============================================================
local function tryToRetaliate(ai)
  local ctx, tank = ai.ctx, ai.tank
  if ai.aggr < AGGRESIVENESS / 2 then return end

  local weapon = tank.currentWeapon
  if weapon == "bullet" or weapon == "laser" then
    if tank.bulletsFired < ctx.settingsMaxBullets then
      local found = false
      local bestTime = C.BULLETLIFETIME
      local closest = C.MOVIEWIDTH + C.MOVIEHEIGHT
      local r = checkBulletPath(ai, tank.rot)
      if r.result == "HIT" then
        found = true
        if r.time < bestTime then bestTime = r.time; closest = 0 end
      elseif r.result == "NOTHING" and not found then
        if r.closest < closest then closest = r.closest end
      end
      if found or closest < ai.MAXCLOSESTDISTANCE / 2 then
        push(ai, { action = "fireWeapon", delay = 1 })
        ai.aggr = max(0, ai.aggr - 0.2)
      end
    end
  elseif weapon == "frag" then
    if tank.fragFired then
      local lf = tank.lastFrag
      local dx, dy = tank.x - lf.x, tank.y - lf.y
      local d = sqrt(dx * dx + dy * dy)
      local hit = checkPathForCollision(ctx, lf.x, lf.y, dx / d, dy / d, 1, ceil(d), ceil(d))
      if hit ~= nil or d >= ai.FRAGBOMBSAFETYDIST then
        for i = 1, ctx.tankCount do
          local tk = ctx.tanks[i]
          if tk and tk.alive and tk ~= tank then
            dx, dy = tk.x - lf.x, tk.y - lf.y
            d = sqrt(dx * dx + dy * dy)
            if d <= ai.FRAGBOMBDETONATEDIST then
              hit = checkPathForCollision(ctx, lf.x, lf.y, dx / d, dy / d, 1, ceil(d), ceil(d))
              if hit == nil then push(ai, { action = "fireWeapon", delay = 1 }) end
            end
          end
        end
      end
    end
  end
end

-- ============================================================
-- 8. pushActionsToFollowPath —— 第 384-424 行
--    把路径压栈：先压 driveToField（末格→第 2 格），再压 driveToPos（第 1 格）
-- ============================================================
local function pushActionsToFollowPath(ai, path)
  local scale = ai.ctx.scale
  local n = #path
  if n == 0 then return end   -- 原版此处会读 path[0] 报错；此处守卫为安全处理
  for i = n, 2, -1 do
    push(ai, { action = "driveToField", x = path[i].x, y = path[i].y })
  end
  push(ai, { action = "driveToPos",
             x = (path[1].x + 0.5) * scale,
             y = (path[1].y + 0.5) * scale,
             canReverse = n <= 2 })
end

-- ============================================================
-- 9. 实例构造
-- ============================================================
function M.new(tank, ctx)
  local scale = ctx.scale
  local ai = {
    tank = tank,
    ctx = ctx,
    myGoal = { goal = "idle", priority = 0, period = 15, id = 0, updateContinuously = true },
    actions = {},
    goalId = 1,
    stuckTime = 0,
    aggr = AGGRESIVENESS,

    -- 随 SCALE 变化的派生常量
    MAXCLOSESTDISTANCE              = scale * MAXCLOSESTCELLDISTANCE,
    FRAGBOMBSAFETYDIST              = 3 * scale,
    FRAGBOMBDETONATEDIST            = 3 * scale,
    MAXDISTTODODGEBULLET            = 4 * scale,
    MAXDISTTODODGEFRAGBOMBFRAGMENT  = 3 * scale,
    MAXDISTTODODGEGATLINGBULLET     = 3 * scale,
    MAXCELLDISTTODODGEBULLET        = MAXTIMETODODGEBULLET * C.BULLETSPEED / 50,
    MAXCELLDISTTODODGEGATLINGBULLET = MAXTIMETODODGEGATLINGBULLET * C.GATLINGSPEED / 50,
  }
  -- 决策树方法定义在模块表 M 上（M:xxx），实例经 __index 取用
  return setmetatable(ai, { __index = M })
end

-- ============================================================
-- 10. makeDecisionsAndUpdateGoal —— 第 425-802 行
--     返回 true 表示需要重算行动（goal 变化或需持续更新）
-- ============================================================
function M:makeDecisionsAndUpdateGoal()
  local ctx, tank = self.ctx, self.tank
  local scale = ctx.scale
  local g = self.myGoal

  if g.period > 0 then
    g.period = g.period - 1
    return g.updateContinuously
  end

  g.priority = g.priority * 0.9
  local oldId = g.id
  local fx, fy = floor(tank.x / scale), floor(tank.y / scale)
  local goal

  -- (a) 找补给箱（第 444-471 行）
  if ctx.aliveCount > 1 and tank.currentWeapon == "bullet" then
    local bestCell = MAXCELLDISTTOGOFORCRATE
    goal = { priority = 0 }
    for i = 1, #ctx.crates do
      local c = ctx.crates[i]
      local cx, cy = floor(c.x / scale), floor(c.y / scale)
      local d = ctx.distAt(fx, fy, cx, cy)
      if d <= bestCell then
        bestCell = d
        goal = { goal = "goForCrate", x = cx, y = cy, period = 10,
                 priority = (MAXCELLDISTTOGOFORCRATE - d) / MAXCELLDISTTOGOFORCRATE * GREEDY
                            * (ctx.settingsMaxBullets - tank.bulletsFired) / ctx.settingsMaxBullets,
                 updateContinuously = false, id = self.goalId }
        self.goalId = self.goalId + 1
      end
    end
    updateGoal(self, goal)
  end

  -- (b) 躲普通弹（第 472-481 行）
  goal = dodgeTrajectories(self, fx, fy, ctx.bullets, MAXTIMETODODGEBULLET,
                           self.MAXDISTTODODGEBULLET, self.MAXCELLDISTTODODGEBULLET,
                           C.BULLETHITCHECKINTERVALS, true)
  updateGoal(self, goal)

  -- (c) 躲破片弹（第 482-519 行）
  local bestFragCell = MAXCELLDISTTODODGEFRAGBOMB
  for i = 1, #ctx.frags do
    local f = ctx.frags[i]
    local cx, cy = floor(f.x / scale), floor(f.y / scale)
    local d = ctx.distAt(fx, fy, cx, cy)
    if d < bestFragCell then
      bestFragCell = d
      goal = { goal = "dodgeFragbomb", frag = f, period = 10, priority = 1,
               updateContinuously = false, id = self.goalId }
      self.goalId = self.goalId + 1
    end
  end
  updateGoal(self, goal)
  goal = dodgeTrajectories(self, fx, fy, ctx.fragFragments, MAXTIMETODODGEFRAGBOMBFRAGMENT,
                           self.MAXDISTTODODGEFRAGBOMBFRAGMENT,
                           MAXCELLDISTTODODGEFRAGBOMBFRAGMENT,
                           C.FRAGHITCHECKINTERVALS, false)
  updateGoal(self, goal)

  -- (d) 躲加特林弹（第 520-529 行）
  goal = dodgeTrajectories(self, fx, fy, ctx.gatlingBullets, MAXTIMETODODGEGATLINGBULLET,
                           self.MAXDISTTODODGEGATLINGBULLET,
                           self.MAXCELLDISTTODODGEGATLINGBULLET,
                           C.GATLINGHITCHECKINTERVALS, true)
  updateGoal(self, goal)

  -- (e) 躲瞄准器激光（第 530-597 行）
  local bestLaserCell = MAXCELLDISTTODODGELASER
  goal = { priority = 0 }
  for i = 1, ctx.tankCount do
    local tk = ctx.tanks[i]
    if tk and tk.alive and tk.currentEquipment == "aimer" and tk ~= tank then
      local eq = tk.equipment
      if eq and eq.hit == tank then
        bestLaserCell = 0
        goal = { goal = "dodgeLaser", dir = { x = eq.hitXSpeed, y = eq.hitYSpeed },
                 owner = tk, period = 10, priority = 1,
                 updateContinuously = false, id = self.goalId }
        self.goalId = self.goalId + 1
      elseif eq and eq.hit == nil then
        local cx, cy = floor(eq.x / scale), floor(eq.y / scale)
        local d = ctx.distAt(fx, fy, cx, cy)
        if d <= bestLaserCell then
          local bounce = checkPathForCollision(ctx, eq.x, eq.y, eq.xSpeed, eq.ySpeed,
                                               C.AIMERHITCHECKINTERVALS, 12, 12)
          if bounce then
            local ax, ay = eq.x, eq.y
            local bx, by = bounce.x, bounce.y
            local len2 = (bx - ax) * (bx - ax) + (by - ay) * (by - ay)
            local t = ((tank.x - ax) * (bx - ax) + (tank.y - ay) * (by - ay)) / len2
            if t > 0 and t < 1 then
              local mx = ax + t * (bx - ax)
              local my = ay + t * (by - ay)
              local d2 = ctx.distAt(fx, fy, floor(mx / scale), floor(my / scale))
              if d2 <= bestLaserCell then
                bestLaserCell = d2
                goal = { goal = "dodgeLaser", dir = { x = bounce.xSpeed, y = bounce.ySpeed },
                         owner = tk, period = 10, priority = 1,
                         updateContinuously = false, id = self.goalId }
                self.goalId = self.goalId + 1
              end
            end
          else
            bestLaserCell = d
            goal = { goal = "dodgeLaser", dir = { x = eq.xSpeed, y = eq.ySpeed },
                     owner = tk, period = 10, priority = 1,
                     updateContinuously = false, id = self.goalId }
            self.goalId = self.goalId + 1
          end
        end
      end
    end
  end
  updateGoal(self, goal)

  -- (f) 攻击类目标（第 598-692 行）
  local weapon = tank.currentWeapon
  if weapon == "bullet" or weapon == "laser" then
    if tank.bulletsFired < ctx.settingsMaxBullets or weapon == "laser" then
      goal = self:scanShootableEnemies(goal, "shootAfter", 10)
    end
  elseif weapon == "frag" then
    if not tank.fragFired then
      goal = self:scanShootableEnemies(goal, "shootAfter", 10)
    else
      local lf = tank.lastFrag
      local dx, dy = tank.x - lf.x, tank.y - lf.y
      local d = sqrt(dx * dx + dy * dy)
      local hit = checkPathForCollision(ctx, lf.x, lf.y, dx / d, dy / d, 1, ceil(d), ceil(d))
      if hit ~= nil or d >= self.FRAGBOMBSAFETYDIST then
        for i = 1, ctx.tankCount do
          local tk = ctx.tanks[i]
          if tk and tk.alive and tk ~= tank then
            dx, dy = tk.x - lf.x, tk.y - lf.y
            d = sqrt(dx * dx + dy * dy)
            if d <= self.FRAGBOMBDETONATEDIST then
              hit = checkPathForCollision(ctx, lf.x, lf.y, dx / d, dy / d, 1, ceil(d), ceil(d))
              if hit == nil then
                goal = { goal = "detonate", period = 1, priority = 1,
                         updateContinuously = false, id = self.goalId }
                self.goalId = self.goalId + 1
                updateGoal(self, goal)
              end
            end
          end
        end
      end
    end
  elseif weapon == "gatling" then
    if tank.gatlingReady then
      goal = self:scanShootableEnemies(goal, "sprayBullets", 15)
    end
  end

  -- (g) 弹药打空时逃跑（第 697-742 行）
  if ctx.aliveCount > 1 and tank.currentWeapon == "bullet"
     and tank.bulletsFired == ctx.settingsMaxBullets then
    local W, H = ctx.maze.W, ctx.maze.H
    -- 原版用 new Array(maze.length-1) → 仅覆盖 0..W-2 / 0..H-2（照抄边界）
    local sumW, sumH = W - 1, H - 1
    local sum = {}
    for x = 0, W - 1 do
      sum[x] = {}
      for y = 0, H - 1 do sum[x][y] = 0 end
    end
    for i = 1, ctx.tankCount do
      local tk = ctx.tanks[i]
      if tk and tk.alive and tk ~= tank and tk.bulletsFired ~= ctx.settingsMaxBullets then
        local tf = ctx.tankFields[i]
        local fld = tf and ctx.fieldOf(tf.x, tf.y)
        if fld then
          for x = 0, sumW - 1 do
            local row = fld[x]
            if row then
              for y = 0, sumH - 1 do
                if row[y] then sum[x][y] = sum[x][y] + row[y] end
              end
            end
          end
        end
      end
    end
    local sumAt = (sum[fx] and sum[fx][fy]) or 0
    if sumAt < LONGESTPATHTORUN then
      goal = { goal = "runAway", dist = sum, period = 10,
               priority = (LONGESTPATHTORUN - sumAt) / LONGESTPATHTORUN * COWARDNESS
                          * (tank.bulletsFired / ctx.settingsMaxBullets),
               updateContinuously = false, id = self.goalId }
      self.goalId = self.goalId + 1
      updateGoal(self, goal)
    end
  end

  -- (h) 卡墙后退（第 743-752 行）
  if tank.hitSomething then
    self.stuckTime = min(self.stuckTime + 1, MAXSTUCKTIME)
  else
    self.stuckTime = 0
  end
  goal = { goal = "backAway", period = 5, priority = self.stuckTime / (MAXSTUCKTIME - 0.1),
           updateContinuously = false, id = self.goalId }
  self.goalId = self.goalId + 1
  updateGoal(self, goal)

  -- (i) 随机朝某个敌人开（第 753-766 行）
  if ctx.aliveCount > 1 then
    local idx
    for _ = 1, ctx.tankCount * 10 do
      idx = rnd(ctx.tankCount) + 1
      local tk = ctx.tanks[idx]
      if tk and tk ~= tank and tk.alive then break end
      idx = nil
    end
    if idx then
      local tk = ctx.tanks[idx]
      if tk ~= tank then
        local tf = ctx.tankFields[idx]
        goal = { goal = "driveTo", period = 10, priority = IDLEDRIVETOWARDENEMYPRIORITY,
                 x = tf.x, y = tf.y, updateContinuously = false, id = self.goalId }
        self.goalId = self.goalId + 1
        updateGoal(self, goal)
      end
    end
  end

  -- 目标变化时的收尾（第 767-801 行）
  if oldId ~= self.myGoal.id then
    local gg = self.myGoal.goal
    if gg == "shootAfter" then
      self.aggr = max(0, self.aggr - 0.2)
    elseif gg == "sprayBullets" then
      self.aggr = max(0, self.aggr - 0.1)
    elseif gg == "detonate" then
      self.aggr = max(0, self.aggr - 0.1)
    end
    return true
  end

  self.aggr = min(AGGRESIVENESS, self.aggr + AGGRESIVENESS / 50)
  return self.myGoal.updateContinuously
end

-- 扫描所有敌人，若最短路径短于阈值则生成 shootAfter / sprayBullets 目标
-- （第 604-691 行的两个 while 循环，逻辑一致，仅目标名/周期不同）
function M:scanShootableEnemies(goal, goalName, period)
  local ctx, tank = self.ctx, self.tank
  local scale = ctx.scale
  local fx, fy = floor(tank.x / scale), floor(tank.y / scale)
  local fld = ctx.fieldOf(fx, fy)
  if not fld then return goal end
  for i = 1, ctx.tankCount do
    local tk = ctx.tanks[i]
    if tk and tk.alive and tk ~= tank then
      local tf = ctx.tankFields[i]
      local path = ctx.pathApi.getShortestPathWithDistances(ctx.maze, fld, fx, fy, tf.x, tf.y)
      if #path < LONGESTPATHTOSHOOT then
        local pr = 1
        if #path > LONGESTPATHTONOTHESITATETOSHOOT then
          pr = (LONGESTPATHTOSHOOT - #path) / LONGESTPATHTOSHOOT * self.aggr
        end
        goal = { goal = goalName, target = tk, period = period, priority = pr,
                 updateContinuously = false, id = self.goalId }
        self.goalId = self.goalId + 1
        updateGoal(self, goal)
      end
    end
  end
  return goal
end

-- ============================================================
-- 11. decideActionsToAchieveGoal —— 第 803-1161 行
-- ============================================================
function M:decideActionsToAchieveGoal()
  local ctx, tank = self.ctx, self.tank
  local scale = ctx.scale
  self.actions = {}
  local fx, fy = floor(tank.x / scale), floor(tank.y / scale)
  local goal = self.myGoal

  if goal.goal == "shootAfter" then
    local chosen = tank.rot
    local found = false
    local bestTime = C.BULLETLIFETIME
    local closest = C.MOVIEWIDTH + C.MOVIEHEIGHT
    local candidate = tank.rot

    local tgt = goal.target
    local dx, dy = tgt.x - tank.x, tgt.y - tank.y
    local d = sqrt(dx * dx + dy * dy)
    local hit = checkPathForCollision(ctx, tank.x, tank.y, dx / d, dy / d, 1, ceil(d), ceil(d))
    if hit == nil then
      found = true
      closest = 0
      chosen = angleToward(dx, dy, candidate)
    end

    if not found then
      for k = 1, 3 do
        local r = checkBulletPath(self, candidate)
        if r.result == "HIT" then
          found = true
          if r.time < bestTime then bestTime = r.time; closest = 0; chosen = candidate end
        elseif r.result == "NOTHING" and not found then
          if r.closest < closest then closest = r.closest; chosen = candidate end
        end
        if random() < 0.5 then
          candidate = candidate + tank.turnSpeed * k * k
        else
          candidate = candidate - tank.turnSpeed * k * k
        end
        candidate = normalizeAngle(candidate)
      end
    end

    local divisor = (tank.currentWeapon ~= "laser") and 1 or 2
    if found or closest < self.MAXCLOSESTDISTANCE / divisor then
      push(self, { action = "fireWeapon", delay = 5 })
      push(self, { action = "turnTo", angle = chosen })
    elseif chosen ~= tank.rot then
      push(self, { action = "turnTo", angle = chosen })
    else
      push(self, { action = "turnTo", angle = normalizeAngle(tank.rot + 180) })
    end

  elseif goal.goal == "sprayBullets" then
    local chosen = tank.rot
    local found = false
    local bestTime = C.GATLINGLIFETIME
    local closest = C.MOVIEWIDTH + C.MOVIEHEIGHT
    local candidate = tank.rot
    for k = 1, 3 do
      local r = checkBulletPath(self, candidate)
      if r.result == "HIT" then
        found = true
        if r.time < bestTime then bestTime = r.time; closest = 0; chosen = candidate end
      elseif r.result == "NOTHING" then
        -- 原版此处误写为 !foundGoodShot（未定义变量，恒真），照抄其等价行为
        if r.closest < closest then closest = r.closest; chosen = candidate end
      end
      if random() < 0.5 then
        candidate = candidate + tank.turnSpeed * k * k
      else
        candidate = candidate - tank.turnSpeed * k * k
      end
      candidate = normalizeAngle(candidate)
    end
    if found or closest < self.MAXCLOSESTDISTANCE then
      push(self, { action = "fireWeapon", delay = 75 })
      push(self, { action = "turnTo", angle = chosen })
    elseif chosen ~= tank.rot then
      push(self, { action = "turnTo", angle = chosen })
    else
      push(self, { action = "turnTo", angle = normalizeAngle(tank.rot + 180) })
    end

  elseif goal.goal == "detonate" then
    push(self, { action = "fireWeapon", delay = 1 })

  elseif goal.goal == "driveTo" then
    local fld = ctx.fieldOf(fx, fy)
    if fld then
      local path = ctx.pathApi.getShortestPathWithDistances(ctx.maze, fld, fx, fy, goal.x, goal.y)
      pushActionsToFollowPath(self, path)
    end

  elseif goal.goal == "runAway" then
    local path = ctx.pathApi.followGradientPathWithDistancesAndDeadEnds(
      ctx.maze, goal.dist, ctx.deadEnds, fx, fy, 5)
    pushActionsToFollowPath(self, path)

  elseif goal.goal == "backAway" then
    push(self, { action = "driveToPos", x = (fx + 0.5) * scale, y = (fy + 0.5) * scale,
                 canReverse = false })
    local front = ctx.tankExpandedHit(tank, "front", 1.1)
    local rear = ctx.tankExpandedHit(tank, "rear", 1.1)
    if front then
      if rear then
        if ctx.tankExpandedHit(tank, "left", 1.3) then
          push(self, { action = "backupAndTurn", dist = 5, dir = "left" })
        else
          push(self, { action = "backupAndTurn", dist = 5, dir = "right" })
        end
      else
        push(self, { action = "backup", dist = 3 })
      end
    elseif rear then
      push(self, { action = "forward", dist = 3 })
    else
      push(self, { action = "backup", dist = 3 })
    end

  elseif goal.goal == "dodgeBullet" then
    local fld = ctx.fieldOf(floor(goal.x / scale), floor(goal.y / scale))
    local path = fld and ctx.pathApi.followGradientPathWithDistancesAndDeadEnds(
      ctx.maze, fld, ctx.deadEnds, fx, fy, 5) or {}
    local panic = goal.t < goal.maxTime / 3 and goal.dist < goal.maxDist / 5
    if panic or #path <= 1 then
      local cur = tank.rot
      local a = angleToward(goal.dir.x, goal.dir.y, cur)
      if abs(a - cur) > 90 and abs(a - cur) < 270 then a = normalizeAngle(a + 180) end
      a = round(a / tank.turnSpeed) * tank.turnSpeed
      push(self, { action = "turnTo", angle = a })
      if goal.dist < scale / 4 then
        local l = sqrt(goal.dir.x * goal.dir.x + goal.dir.y * goal.dir.y)
        local px, py = -goal.dir.y / l, goal.dir.x / l
        local p1x, p1y = goal.closest.x + px * scale / 2, goal.closest.y + py * scale / 2
        local p2x, p2y = goal.closest.x - px * scale / 2, goal.closest.y - py * scale / 2
        local d1 = sqrt((tank.x - p1x) * (tank.x - p1x) + (tank.y - p1y) * (tank.y - p1y))
        local d2 = sqrt((tank.x - p2x) * (tank.x - p2x) + (tank.y - p2y) * (tank.y - p2y))
        if d1 < d2 then
          push(self, { action = "driveToPos", x = p1x, y = p1y, canReverse = true })
        else
          push(self, { action = "driveToPos", x = p2x, y = p2y, canReverse = true })
        end
      end
    else
      pushActionsToFollowPath(self, path)
    end
    tryToRetaliate(self)

  elseif goal.goal == "dodgeFragbomb" then
    local fld = ctx.fieldOf(floor(goal.frag.x / scale), floor(goal.frag.y / scale))
    if fld then
      local path = ctx.pathApi.followGradientPathWithDistancesAndDeadEnds(
        ctx.maze, fld, ctx.deadEnds, fx, fy, 5)
      if #path > 1 then
        pushActionsToFollowPath(self, path)
      else
        path = ctx.pathApi.followGradientPathWithDistances(ctx.maze, fld, fx, fy, 5)
        pushActionsToFollowPath(self, path)
      end
    end
    tryToRetaliate(self)

  elseif goal.goal == "dodgeLaser" then
    local fld = ctx.fieldOf(floor(goal.owner.x / scale), floor(goal.owner.y / scale))
    if fld then
      local path = ctx.pathApi.followGradientPathWithDistancesAndDeadEnds(
        ctx.maze, fld, ctx.deadEnds, fx, fy, 2)
      pushActionsToFollowPath(self, path)
    end
    tryToRetaliate(self)

  elseif goal.goal == "goForCrate" then
    local fld = ctx.fieldOf(fx, fy)
    if fld then
      local path = ctx.pathApi.getShortestPathWithDistances(ctx.maze, fld, fx, fy, goal.x, goal.y)
      if #path > 0 then
        local last = path[#path]
        push(self, { action = "driveToPos", x = (last.x + 0.5) * scale, y = (last.y + 0.5) * scale,
                     canReverse = true })
      end
      pushActionsToFollowPath(self, path)
    end

  elseif goal.goal == "idle" then
    push(self, { action = "idle" })
  end
end

-- ============================================================
-- 12. setInputToDoActions —— 第 1162-1468 行
--     消费行动栈并把结果写入坦克输入
-- ============================================================
function M:setInputToDoActions()
  local ctx, tank = self.ctx, self.tank
  local scale = ctx.scale
  local fx, fy = floor(tank.x / scale), floor(tank.y / scale)
  local actions = self.actions

  -- 弹出一个行动；未达成的条件则重新压回（实现"窥视 + 条件消费"）
  local action = table.remove(actions)
  if action then
    local a = action.action
    if a == "driveToField" then
      if abs(tank.x - (action.x + 0.5) * scale) > scale / 3
         or abs(tank.y - (action.y + 0.5) * scale) > scale / 3 then
        actions[#actions + 1] = action
      end
    elseif a == "turnTo" then
      if abs(tank.rot - action.angle) >= tank.turnSpeed then
        actions[#actions + 1] = action
      end
    elseif a == "fireWeapon" then
      if action.delay ~= 0 then
        action.delay = action.delay - 1
        actions[#actions + 1] = action
      end
    elseif a == "driveToPos" then
      if abs(tank.x - action.x) > scale / 4 or abs(tank.y - action.y) > scale / 4 then
        actions[#actions + 1] = action
      end
    elseif a == "forward" or a == "forwardAndTurn"
        or a == "backup" or a == "backupAndTurn" then
      if action.dist ~= 0 then
        action.dist = action.dist - 1
        actions[#actions + 1] = action
      end
    elseif a == "idle" then
      actions[#actions + 1] = action
    end
  end

  local top = actions[#actions]
  if not top then
    tank.turnLeft, tank.turnRight, tank.forward, tank.backup, tank.fire =
      false, false, false, false, false
    self.myGoal.period = 0
    return
  end

  local a = top.action
  if a == "driveToField" then
    local cur = tank.rot
    local target
    if fx > top.x then target = -90
    elseif fx < top.x then target = 90
    elseif fy > top.y then target = 0
    elseif fy < top.y then target = 180
    else target = cur end
    tank.turnLeft, tank.turnRight = turnDecision(cur, target)
    if abs(target - cur) > 90 and abs(target - cur) < 270 then
      tank.forward, tank.backup = false, false
    else
      tank.forward, tank.backup = true, false
    end
    tank.fire = false

  elseif a == "turnTo" then
    tank.turnLeft, tank.turnRight = turnDecision(tank.rot, top.angle)
    tank.forward, tank.backup, tank.fire = false, false, false

  elseif a == "fireWeapon" then
    tank.turnLeft, tank.turnRight, tank.forward, tank.backup = false, false, false, false
    tank.fire = true

  elseif a == "driveToPos" then
    local cur = tank.rot
    local reverse = false
    local target = angleToward(top.x - tank.x, top.y - tank.y, cur)
    target = tank.turnSpeed * round(target / tank.turnSpeed)
    if top.canReverse then
      if abs(target - cur) > 90 and abs(target - cur) < 270 then
        reverse = true
        target = normalizeAngle(target + 180)
      end
    end
    if target > cur then
      if abs(target - cur) > 180 then
        tank.turnLeft = abs(target - cur) < 360 - tank.turnSpeed
        tank.turnRight = false
      else
        tank.turnLeft = false
        tank.turnRight = abs(target - cur) > tank.turnSpeed
      end
    elseif target < cur then
      if abs(target - cur) > 180 then
        tank.turnLeft = false
        tank.turnRight = abs(target - cur) < 360 - tank.turnSpeed
      else
        tank.turnLeft = abs(target - cur) > tank.turnSpeed
        tank.turnRight = false
      end
    else
      tank.turnLeft, tank.turnRight = false, false
    end
    if abs(target - cur) > 45 and abs(target - cur) < 315 then
      tank.forward, tank.backup = false, false
    else
      tank.forward, tank.backup = not reverse, reverse
    end
    tank.fire = false

  elseif a == "forward" then
    tank.turnLeft, tank.turnRight, tank.backup, tank.fire = false, false, false, false
    tank.forward = true

  elseif a == "forwardAndTurn" then
    tank.turnLeft = top.dir == "left"
    tank.turnRight = top.dir == "right"
    tank.forward, tank.backup, tank.fire = true, false, false

  elseif a == "backup" then
    tank.turnLeft, tank.turnRight, tank.forward, tank.fire = false, false, false, false
    tank.backup = true

  elseif a == "backupAndTurn" then
    tank.turnLeft = top.dir == "left"
    tank.turnRight = top.dir == "right"
    tank.forward, tank.backup, tank.fire = false, true, false

  elseif a == "idle" then
    tank.turnLeft, tank.turnRight, tank.forward, tank.backup, tank.fire =
      false, false, false, false, false

  else
    tank.turnLeft, tank.turnRight, tank.forward, tank.backup, tank.fire =
      false, false, false, false, false
    self.myGoal.period = 0
  end
end

return M
end

-- ==================== 模块 src.round ====================
__defs["src.round"] = function()
--[[
  坦克动荡2 —— 补给箱 / 回合流程 / 计分 / 震屏（纯逻辑，可脱离游戏运行时单测）

  逐行对照反编译源码移植：
    补给箱刷新/选点   frame_53/DoAction.as 第 2567-2614 行
    spawnCrate        frame_53/DoAction.as 第 1678-1740 行
    拾取判定          Crate.swf → DefineSprite_13_crate/frame_1/DoAction.as
    回合流程          frame_53/DoAction.as 第 2615-2659 行
    destroyTank       frame_53/DoAction.as 第 921-931 行（aliveCount/endCount/shake 部分）
    assignPoints      frame_53/DoAction.as 第 2129-2179 行

  本模块不渲染、不读输入设备。所有视觉（烟雾/残骸/尘土/箱子外观与落地动画）
  与音效由平台层处理；此处只产出"规则"与"参数"。

  坐标 / 索引约定（与 maze.lua 一致）：
    reachable            1 基列表，元素为 { x, y, used }（.used 由生成/拾取维护）
    reachableIndex[x][y] 0 基序号（maze.calcReachable 产出），需 +1 才是 reachable 下标
    原版 0 基索引 pos 在本层一律换算为 1 基。
]]

local C = require("src.constants")

local M = {}

local floor, random, min, max, abs = math.floor, math.random, math.min, math.max, math.abs

local function rnd(n) return floor(random() * n) end   -- 等价 AS random(n)：[0,n)

-- ============================================================
-- 1. 补给箱刷新计时（第 2569 行）
--    crateTimer = (350 + random(200) + 2000 / reachable.length) × modifier
-- ============================================================
function M.nextCrateTimer(reachableLen, modifier, rng)
  rng = rng or random
  return (C.CRATESPAWNTIMEBASE + floor(rng() * C.CRATESPAWNTIMERANDOM)
          + C.CRATESPAWNMAZESIZESCALE / reachableLen) * modifier
end

-- ============================================================
-- 2. 选点（第 2570-2613 行）
--    ctx:
--      reachable           1 基列表（元素含 .used）
--      reachableIndex      0 基序号表
--      crateSpawnPoints    自定义迷宫出生点列表（可为空）
--      tanks               坦克数组（含 .x/.y/.alive）
--      scale               SCALE
--      numberOfCrates      场上现有箱子数
--      settings.maxCrates  箱子上限
--    返回 reachable 的 1 基下标，或 nil（不生成）
-- ============================================================
function M.pickCratePos(ctx)
  local reachable = ctx.reachable
  if #reachable == 0 then return nil end

  local pos = 1                       -- 对应原版 pos = 0；0 视为"取不到"
  local retry = true                  -- 对应 _loc5_
  local tries = -1                    -- 对应 _loc9_
  local maxed = ctx.numberOfCrates >= ctx.settings.maxCrates

  local function cellUsed(i)
    local c = reachable[i]
    return c ~= nil and c.used == true
  end

  while (cellUsed(pos) or retry) and tries < 5 and not maxed do
    if #ctx.crateSpawnPoints > 0 then
      local sp = ctx.crateSpawnPoints[rnd(#ctx.crateSpawnPoints) + 1]
      local i0 = ctx.reachableIndex[sp.x][sp.y]
      pos = (i0 ~= nil) and (i0 + 1) or 0
    else
      pos = rnd(#reachable) + 1
    end
    retry = false
    tries = tries + 1
    if pos == 0 then
      retry = true
    else
      for i = 1, #ctx.tanks do
        local t = ctx.tanks[i]
        local cx, cy = floor(t.x / ctx.scale), floor(t.y / ctx.scale)
        if abs(reachable[pos].x - cx) + abs(reachable[pos].y - cy) <= 1 and t.alive then
          retry = true
        end
      end
    end
  end

  if tries < 5 and not maxed and pos ~= 0 then return pos end
  return nil
end

-- ============================================================
-- 3. 生成规则（第 1735-1739 行 + 第 1689-1698 行落地动画参数）
-- ============================================================
-- 从 settingsActiveWeapons 随机抽取武器；池为空则不生成
function M.pickCrateWeapon(activeWeapons, rng)
  rng = rng or random
  if #activeWeapons == 0 then return nil end
  return activeWeapons[rnd(#activeWeapons) + 1]
end

-- 落地动画参数（视觉由平台层按这些值推进）
function M.crateLanding(scale, rng)
  rng = rng or random
  return {
    targetScale   = scale * 1.5,
    rot           = rng() * 90 - 45,
    scaleSpeed    = scale / 5,
    scaleSpeedDiff = scale / 20,
  }
end

-- ============================================================
-- 4. 拾取判定（Crate/DefineSprite_13_crate/frame_1）
--    条件：任一存活坦克的包围盒包含箱子四角(±10,±10)中至少一个，
--          且该坦克当前武器为 bullet。
--    opts.boxContains(tank, px, py) -> bool   （等价 tank.hitTest(px,py,false)）
--    opts.corners(tank, crate) -> 4 个全局点   （把箱子局部角点变换到全局）
--    返回被拾取的坦克（首个命中者），或 nil
-- ============================================================
function M.tryPickup(crate, tanks, opts)
  for i = 1, #tanks do
    local t = tanks[i]
    if t.alive and t.currentWeapon == "bullet" then
      local pts = opts.corners(t, crate)
      local hit = false
      for k = 1, #pts do
        if opts.boxContains(t, pts[k][1], pts[k][2]) then hit = true; break end
      end
      if hit then return t end
    end
  end
  return nil
end

-- ============================================================
-- 5. 回合流程（第 2615-2659 行）
-- ============================================================
function M.newBattle(tankCount, crateTimer)
  return {
    aliveCount = tankCount,
    endCount   = C.NUMBEROFFRAMESBEFOREEND + C.NUMBEROFFRAMESFROZEN,
    resetCount = -1,
    frozen     = false,
    crateTimer = crateTimer,
    shake      = 0,
  }
end

-- destroyTank 中的计数部分（第 928-932 行）
function M.onTankKilled(r)
  r.aliveCount = r.aliveCount - 1
  r.endCount = C.NUMBEROFFRAMESBEFOREEND
  r.shake = min(C.MAXSHAKE, r.shake + 7)
end

-- 每帧推进。返回：shakeOffX, shakeOffY, event
--   event = nil | "freeze"（进入冻结并结算）| "cleanup"（清理战场）| "reset"（开下一回合）
function M.step(r, rng)
  rng = rng or random

  -- 震屏：先取偏移再衰减（第 2615-2620 行）
  local offX, offY = 0, 0
  if r.shake >= 0 then
    offX = floor(rng() * r.shake) - r.shake / 2
    offY = floor(rng() * r.shake) - r.shake / 2
    r.shake = r.shake - 0.5
  end

  local event = nil
  if r.aliveCount <= 1 then
    if r.endCount >= 0 then r.endCount = r.endCount - 1 end
    if r.endCount == C.NUMBEROFFRAMESFROZEN then
      r.frozen = true
      event = "freeze"
    end
    if r.endCount == 0 then
      r.resetCount = C.NUMBEROFFRAMESBEFORERESET
      event = "cleanup"
    end
  end
  if r.resetCount >= 0 then r.resetCount = r.resetCount - 1 end
  if r.resetCount == 0 then
    r.endCount = C.NUMBEROFFRAMESBEFOREEND + C.NUMBEROFFRAMESFROZEN
    r.frozen = false
    event = "reset"
  end

  return offX, offY, event
end

-- 补给箱计时推进：未冻结时递减，到点重算（第 2557-2569 行）
-- 返回 true 表示本帧该尝试刷箱
function M.tickCrateTimer(r, reachableLen, modifier, rng)
  if r.frozen then return false end
  r.crateTimer = r.crateTimer - 1
  if r.crateTimer <= 0 then
    r.crateTimer = M.nextCrateTimer(reachableLen, modifier, rng)
    return true
  end
  return false
end

-- ============================================================
-- 6. 计分（第 2129-2179 行）
--    exp 字段：t.exp；分数：t.score
--    经验值 = round(min(20, max(1, 10 + (败者经验之和 − 胜者经验)/100)))
--    存活坦克 score += 1、exp += 经验值
--    返回本回合经验值
-- ============================================================
function M.assignPoints(tanks)
  local loserSum, winnerExp = 0, 0
  for i = 1, #tanks do
    local t = tanks[i]
    if not t.alive then
      loserSum = loserSum + max(1, t.exp or 0)
    else
      winnerExp = max(1, t.exp or 0)
    end
  end
  local points = floor(min(20, max(1, 10 + (loserSum - winnerExp) / 100)) + 0.5)

  for i = 1, #tanks do
    local t = tanks[i]
    if t.alive then
      t.score = (t.score or 0) + 1
      t.exp = (t.exp or 0) + points
    end
  end
  return points
end

-- ============================================================
-- 7. 震屏辅助（供平台层直接使用）
-- ============================================================
M.MAXSHAKE = C.MAXSHAKE

function M.addShake(shake, v)
  return min(C.MAXSHAKE, shake + (v or 7))
end

return M
end

-- ==================== 平台层 platform/game.lua ====================
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
