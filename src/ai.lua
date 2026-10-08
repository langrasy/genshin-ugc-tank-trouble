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
local function checkBulletPath(ai, angle, maxClosestDistance)
  local ctx, tank = ai.ctx, ai.tank
  local scale = ctx.scale
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
      local r = checkBulletPath(ai, tank.rot, ai.MAXCLOSESTDISTANCE)
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
  return ai
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
        local r = checkBulletPath(self, self.MAXCLOSESTDISTANCE)
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
      local r = checkBulletPath(self, self.MAXCLOSESTDISTANCE)
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