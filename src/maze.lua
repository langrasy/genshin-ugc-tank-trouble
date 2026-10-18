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
-- 共用构建：cellAt(x,y) 返回该**格点**的 0..3 取值（tempmaze）。
local function buildMaze(xsize, ysize, cellAt)
  local tempmaze = {}
  for x = 0, xsize do
    local col = {}
    for y = 0, ysize do
      col[y] = (cellAt(x, y) or 0) % 4
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

function M.createMaze(xsize, ysize, rng)
  rng = rng or math.random
  return buildMaze(xsize, ysize, function() return floor(rng() * 4) end)
end

-- makeEntropyInts(xsize, ysize, rng) —— 摇出 (xsize+1)*(ysize+1) 个 0..3 的格点熵。
--   取用顺序与 createMaze/buildMaze **完全一致**（x 外层、y 内层）⇒
--   `createMazeFromInts(W, H, makeEntropyInts(W, H, rng), 1)` 与 `createMaze(W, H, rng)` 逐格等价。
--   用途（联机「房主上传」方案）：房主先摇出整数表（可原样发给其他玩家），再用它建同一张图。
function M.makeEntropyInts(xsize, ysize, rng)
  rng = rng or math.random
  local ints = {}
  local i = 0
  for x = 0, xsize do
    for y = 0, ysize do
      i = i + 1
      ints[i] = floor(rng() * 4)
    end
  end
  return ints
end

-- createMazeFromInts(xsize, ysize, ints, i0)  —— 联机：从**外部下发的整数表**建迷宫。
--   ints[i0 .. i0 + (xsize+1)*(ysize+1) - 1] 为每个格点的 0..3 取值。
--   现行方案（「房主上传」）：表由**联机房主**摇好后经服务器下发；旧方案（服务器摇）已被弃用。
--   纯整数、**按下标顺序取用** ⇒ 两端结果必然一致（无 PRNG 状态 / 无消耗漂移）。
--   返回 maze, 消耗的元素个数；数据不足返回 nil, 0。
function M.createMazeFromInts(xsize, ysize, ints, i0)
  local i = i0 or 1
  local need = (xsize + 1) * (ysize + 1)
  if type(ints) ~= "table" or #ints < i - 1 + need then return nil, 0 end
  local maze = buildMaze(xsize, ysize, function()
    local v = ints[i] or 0
    i = i + 1
    return v
  end)
  return maze, need
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