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
function M.new(opts)
  opts = opts or {}
  local scale = opts.cellScale or 50
  local t = {
    x = opts.x or 0,
    y = opts.y or 0,
    rot = opts.rot or 0,
    cellScale = scale,
    s = M.TANK_SCALE * scale / 100,          -- localToGlobal 的缩放系数
    forwardSpeed = 4 * (scale / 50),         -- 第 365 行
    backUpSpeed = 2.5 * (scale / 50),        -- 第 366 行
    turnSpeed = 10,                          -- 第 367 行
    wallHit = opts.wallHit,
    mouseTank = opts.mouseTank or false,
    settingsUseNewMouseControl = opts.settingsUseNewMouseControl or false,
    settingsUseSmoothCollision = opts.settingsUseSmoothCollision ~= false,
    hitPoints = M.makeHitPoints(opts.baseW, opts.baseH, opts.turretW, opts.turretH),
    alive = true,
  }
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