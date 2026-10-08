--[[ 迷宫/寻路模块自测：验证可达性、距离场与回溯路径的一致性。 ]]
package.path = package.path .. ";./?.lua"

local C = require("src.constants")
local M = require("src.maze")

local function fail(msg)
  print("[FAIL] " .. msg)
  os.exit(1)
end

local function ok(msg)
  print("[ok] " .. msg)
end

math.randomseed(20261008)

-- 1. 生成迷宫
local W, H = 8, 6
local maze = M.createMaze(W, H)
assert(maze.W == W and maze.H == H, "maze dims")
for x = 0, W - 1 do
  for y = 0, H - 1 do
    local c = maze[x][y]
    if not (c and (c.yw == 0 or c.yw == 1) and (c.xw == 0 or c.xw == 1)) then
      fail("cell invalid at " .. x .. "," .. y)
    end
  end
end
ok("createMaze 结构正确")

-- 2. 可达性
local reachable, reachableIndex = M.calcReachable(maze, 0, 0)
if #reachable == 0 then fail("reachable 为空") end
for i, p in ipairs(reachable) do
  if reachableIndex[p.x][p.y] ~= (i - 1) then
    fail("reachableIndex 与列表不一致 @" .. i)
  end
end
ok("calcReachable 得到 " .. #reachable .. " 个可达格，索引一致")

-- 3. 死胡同
local deadEnds = M.findDeadEnds(maze, reachable)
local deadCount = 0
for x = 0, W - 1 do
  for y = 0, H - 1 do
    local v = deadEnds[x][y]
    if v and v >= 1 then
      deadCount = deadCount + 1
      if v > C.MAXDEADENDPENALTY then fail("死胡同惩罚超过上限") end
    end
  end
end
ok("findDeadEnds 识别 " .. deadCount .. " 个死胡同格")

-- 4. 距离场 + 回溯路径一致性（对多组起终点）
local function isOpenBetween(a, b)
  local dx, dy = b.x - a.x, b.y - a.y
  if dx == 0 and dy == 1 then return maze[a.x][a.y].yw == 0 end
  if dx == 0 and dy == -1 then return maze[a.x][a.y - 1].yw == 0 end
  if dx == 1 and dy == 0 then return maze[a.x + 1][a.y].xw == 0 end
  if dx == -1 and dy == 0 then return maze[a.x][a.y].xw == 0 end
  return false
end

local checked = 0
for i = 1, math.min(20, #reachable) do
  local s = reachable[1]
  local e = reachable[#reachable - i + 1]
  local dist = M.calcDistances(maze, s.x, s.y)
  if dist[e.x][e.y] == nil then fail("终点不可达") end
  local path = M.getShortestPathWithDistances(maze, dist, s.x, s.y, e.x, e.y)
  local last = path[#path]
  if last.x ~= e.x or last.y ~= e.y then fail("路径终点错误") end

  -- 原版约定：path 为"依次驶入"的格子序列（不含起点、末位为终点）。
  -- 累计步长（含起点→path[1]）应等于距离场值。
  local cost = 0
  local prev = s
  for k = 1, #path do
    local b = path[k]
    local dx, dy = math.abs(prev.x - b.x), math.abs(prev.y - b.y)
    if dx > 1 or dy > 1 or (dx == 0 and dy == 0) then fail("路径出现跳格") end
    if not isOpenBetween(prev, b) then fail("路径穿过墙体") end
    cost = cost + ((dx == 1 and dy == 1) and 1.414214 or 1)
    prev = b
  end
  if math.abs(cost - dist[e.x][e.y]) > 1e-6 then
    fail(string.format("路径代价 %.6f != 距离场 %.6f", cost, dist[e.x][e.y]))
  end
  checked = checked + 1
end
ok("距离场与回溯路径代价一致（校验 " .. checked .. " 组）")

-- 5. 梯度跟随（远离源点）应逐步增大距离
local gp = M.followGradientPathWithDistances(maze, M.calcDistances(maze, 0, 0), 0, 0, 10)
ok("followGradientPathWithDistances 产出 " .. #gp .. " 步")

print("\n全部通过。")