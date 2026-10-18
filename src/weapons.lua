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
    ctx.turnInput(owner)       该 owner 当前的左右转键状态（遥控弹转向用；随玩家控制方式）
    ctx.mousePos()             mazemc 局部鼠标坐标
    以及纯视觉回调：ctx.smoke / ctx.particles / ctx.spark / ctx.sound

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
    turnInput = o.turnInput or function() return false, false end,
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
-- 返回**命中坦克数**（bullet 用它归还弹药槽；原版 DefineSprite_212_bullet:103 每命中一辆 `owner.bulletsFired--`）
local function hitTanks(p, ctx, enabled)
  if not enabled then return 0 end
  local n = 0
  local tanks = ctx.tanks
  for i = 1, #tanks do
    local t = tanks[i]
    if t.alive and ctx.tankContains(t, p.x, p.y) then
      ctx.onHit(p.owner, t)
      p.remove = true
      n = n + 1
    end
  end
  return n
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
      -- 原版：撞墙反弹播 pingpong / pingpong2（随机二选一）
      ctx.sound(random() > 0.5 and "soundBounce0" or "soundBounce1")
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
  ctx.sound("soundBullet")   -- 原版：开火播 soundBullet
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
  ctx.sound("soundLaser")   -- 原版：激光发射
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
  -- 原版 fireFrag：若上一发仍在飞行（fragFired），再按开火键 = 引爆那一发，不再发射新弹。
  if owner.fragFired and owner.alive and owner.lastFrag ~= nil then
    M.detonateFrag(owner.lastFrag, ctx)
    return nil
  end
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
  ctx.sound("soundFragment")   -- 原版：破片弹发射
  owner.lastFrag = p
  owner.fragFired = true
  return p
end

function M.fireGatling(owner, ctx)
  owner.gatlingReady = false
  ctx.sound("soundGatlingMotorStart")   -- 原版：马达启动
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
  -- 原版：按下即开始播「充能」音（frame_53:1408 soundDeathRayCharge.start(1)），发射时再换 Fire
  ctx.sound("soundDeathRayCharge")
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
  ctx.sound("soundHomingFire")   -- 原版：追踪弹发射
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
  local hits = hitTanks(p, ctx, p.deadly == 0)
  if p.remove then
    -- 命中坦克也要归还弹药槽（原版 DefineSprite_212_bullet:100-113；每命中一辆扣 1）
    if p.owner then p.owner.bulletsFired = (p.owner.bulletsFired or 0) - hits end
    return false
  end
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
  if p.remove then return false end        -- 已被引爆（引爆发生在开火逻辑里）则不再步进
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
    if p.spinSpeed == C.GATLINGSPINSPEED and not p.motorPlayed then
      p.motorPlayed = true
      -- 原版 soundGatlingMotor.start(0,999) 为**循环**；平台无循环播放 API → 满转时播一次作代表
      ctx.sound("soundGatlingMotor")
    end
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
      ctx.sound("soundGatlingMotorStop")   -- 原版：马达停止
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
      -- 原版：锁定后按「到目标的距离」周期性地发信号 ping（(dist+1)*4 帧一次，越近越频）
      if p.soundCounter > ((cur or 0) + 1) * 4 then
        p.soundCounter = 0
        ctx.sound("soundHoming2")
      end
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
  -- 原版：deadly==1（切换为「待命」帧）时启动地雷警示音 soundMineActivate
  if p.deadly == 1 then ctx.sound("soundMineActivate") end
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
      local turnLeft, turnRight = ctx.turnInput(p.owner)
      local turnSize = 0
      if turnLeft then turnSize = -p.turnSpeed end
      if turnRight then turnSize = turnSize + p.turnSpeed end
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
  -- 原版：遥控导弹飞行期间由 rCSignal 周期性地播遥控信号音
  p.signalCounter = (p.signalCounter or 0) + 1
  if p.signalCounter >= 20 and p.owner.alive then
    p.signalCounter = 0
    ctx.sound("soundRemoteSignal")
  end
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
    if not p.firedSound then
      p.firedSound = true
      ctx.sound("soundDeathRayFire")   -- 原版：蓄力结束、射线成形时播发射音
    end
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