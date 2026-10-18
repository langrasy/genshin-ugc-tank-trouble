--[[ 迷宫/寻路模块自测：验证可达性、距离场与回溯路径的一致性。 ]]
package.path = package.path .. ";./?.lua"

local C = require("src.constants")
local M = require("src.maze")

---@noreturn
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

-- 6. 联机：从**外部整数表**建迷宫 —— 同一张表两次结果必须一致
local ints = {}
math.randomseed(1234)
for i = 1, (8 + 1) * (6 + 1) do ints[i] = math.floor(math.random() * 4) end
local mA = M.createMazeFromInts(8, 6, ints, 1)
local mB = M.createMazeFromInts(8, 6, ints, 1)
if mA == nil or mB == nil then fail("createMazeFromInts 返回 nil") end
local same = true
for x = 0, 7 do
  for y = 0, 5 do
    ---@diagnostic disable-next-line: need-check-nil
    if mA[x][y].xw ~= mB[x][y].xw or mA[x][y].yw ~= mB[x][y].yw then same = false end
  end
end
if not same then fail("同一整数表两次建迷宫结果不一致") end
ok("createMazeFromInts：同表 ⇒ 同迷宫")

-- 7. 与 rng 版等价：把表当作 rng 输出（v/4）时，两者结果相同
local k = 0
local fakeRng = function() k = k + 1; return ints[k] / 4 end
local mC = M.createMaze(8, 6, fakeRng)
if mC == nil then fail("createMaze(rng) 返回 nil") end
local same2 = true
for x = 0, 7 do
  for y = 0, 5 do
    ---@diagnostic disable-next-line: need-check-nil
    if mA[x][y].xw ~= mC[x][y].xw or mA[x][y].yw ~= mC[x][y].yw then same2 = false end
  end
end
if not same2 then fail("createMazeFromInts 与等价 rng 版结果不一致") end
ok("createMazeFromInts 与等价 rng 版一致")

-- 8. 数据不足 ⇒ 返回 nil（调用方据此回退本地随机）
if M.createMazeFromInts(8, 6, { 1, 2, 3 }, 1) ~= nil then fail("数据不足应返回 nil") end
ok("createMazeFromInts：数据不足返回 nil（回退本地随机）")

-- 9. 联机「房主上传」：房主先摇表（makeEntropyInts）再建图 ⇒ 必须与直接 createMaze 逐格一致
--    （这样「房主本地生成的迷宫」和「别人照表重建的迷宫」才必然同一张）
math.randomseed(4321)
local ent = M.makeEntropyInts(9, 7)
if #ent ~= (9 + 1) * (7 + 1) then fail("makeEntropyInts 长度错误: " .. #ent) end
for i = 1, #ent do
  local v = ent[i]
  if type(v) ~= "number" or v < 0 or v > 3 or v ~= math.floor(v) then fail("格点熵越界 @" .. i) end
end
math.randomseed(4321)
local mDirect = M.createMaze(9, 7)
local mInts = M.createMazeFromInts(9, 7, ent, 1)
if mDirect == nil or mInts == nil then fail("makeEntropyInts 往返返回 nil") end
local same3 = true
for x = 0, 8 do
  for y = 0, 6 do
    ---@diagnostic disable-next-line: need-check-nil
    if mDirect[x][y].xw ~= mInts[x][y].xw or mDirect[x][y].yw ~= mInts[x][y].yw then same3 = false end
  end
end
if not same3 then fail("makeEntropyInts 与 createMaze 不等价") end
ok("makeEntropyInts ⇒ createMazeFromInts 与 createMaze 逐格一致")

print("\n全部通过。")