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

  local pos = 1                       -- 对应原版 pos = 0
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
      pos = (i0 ~= nil) and (i0 + 1) or nil
    else
      pos = rnd(#reachable) + 1
    end
    retry = false
    tries = tries + 1
    if pos == nil then
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

  if tries < 5 and not maxed and pos ~= nil then return pos end
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