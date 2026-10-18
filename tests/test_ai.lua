--[[ AI 决策树 自测（src/ai.lua） ]]
package.path = package.path .. ";./?.lua"

local C = require("src.constants")
local A = require("src.ai")

---@noreturn
local function fail(msg) print("[FAIL] " .. msg); os.exit(1) end
local function ok(msg) print("[ok] " .. msg) end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end

math.randomseed(20261010)

-- 安静的上下文：无敌人、无投射物、不撞墙。用于 idle / period / backAway 场景
local function quietCtx(scale)
  scale = scale or 50
  local tank = {
    x = 100, y = 100, rot = 0, s = 1, turnSpeed = 10, alive = true,
    hitSomething = false, currentWeapon = "bullet", bulletsFired = 0,
    fragFired = false, lastFrag = nil, gatlingReady = false,
    currentEquipment = nil, equipment = nil, hitPoints = 100,
  }
  local ctx = {
    scale = scale, maze = { W = 3, H = 3 }, deadEnds = {},
    fieldOf = function() return {} end,
    distAt = function() return 999 end,
    wallHit = function() return false end,
    tankShapeContains = function() return false end,
    tankBBoxContains = function() return false end,
    tanks = { tank }, tankCount = 1,
    tankFields = { { x = 2, y = 2 } },
    aliveCount = 1, settingsMaxBullets = 5,
    bullets = {}, frags = {}, fragFragments = {}, gatlingBullets = {}, crates = {},
    pathApi = {
      getShortestPathWithDistances = function() return {} end,
      followGradientPathWithDistancesAndDeadEnds = function() return {} end,
      followGradientPathWithDistances = function() return {} end,
    },
    tankExpandedHit = function() return false end,
  }
  return tank, ctx
end

-- 交战上下文：存在一名敌人，路径由参数决定
local function combatCtx(path)
  path = path or {}
  local tank = {
    x = 100, y = 100, rot = 0, s = 1, turnSpeed = 10, alive = true,
    hitSomething = false, currentWeapon = "bullet", bulletsFired = 0,
    fragFired = false, lastFrag = nil, gatlingReady = false,
    currentEquipment = nil, equipment = nil, hitPoints = 100,
  }
  local enemy = {
    x = 200, y = 100, rot = 180, alive = true, currentWeapon = "bullet",
    bulletsFired = 0, currentEquipment = nil, equipment = nil,
  }
  local ctx = {
    scale = 50, maze = { W = 4, H = 4 }, deadEnds = {},
    fieldOf = function() return {} end,
    distAt = function() return 999 end,
    wallHit = function() return false end,
    tankShapeContains = function() return false end,
    tankBBoxContains = function() return false end,
    tanks = { tank, enemy }, tankCount = 2,
    tankFields = { { x = 2, y = 2 }, { x = 4, y = 2 } },
    aliveCount = 2, settingsMaxBullets = 5,
    bullets = {}, frags = {}, fragFragments = {}, gatlingBullets = {}, crates = {},
    pathApi = {
      getShortestPathWithDistances = function() return path end,
      followGradientPathWithDistancesAndDeadEnds = function() return {} end,
      followGradientPathWithDistances = function() return {} end,
    },
    tankExpandedHit = function() return false end,
  }
  return tank, enemy, ctx
end

-- 1. 导出常量
do
  if A.AGGRESIVENESS ~= 0.5 then fail("AGGRESIVENESS 导出错误") end
  if A.COWARDNESS ~= 0.7 then fail("COWARDNESS 导出错误") end
  ok("导出常量正确")
end

-- 2. M.new：派生常量与实例方法
do
  local tank, ctx = quietCtx(50)
  local ai = A.new(tank, ctx)
  if type(ai.makeDecisionsAndUpdateGoal) ~= "function" then fail("__index 未连到 M") end
  if type(ai.decideActionsToAchieveGoal) ~= "function" then fail("decideActions 缺失") end
  if type(ai.setInputToDoActions) ~= "function" then fail("setInput 缺失") end
  if type(ai.scanShootableEnemies) ~= "function" then fail("scanShootable 缺失") end
  if ai.tank ~= tank or ai.ctx ~= ctx then fail("tank/ctx 未绑定") end
  if ai.myGoal.goal ~= "idle" or ai.myGoal.period ~= 15 or ai.myGoal.id ~= 0 then
    fail("初始 myGoal 错误")
  end
  if not near(ai.aggr, 0.5) then fail("初始 aggr 错误") end
  if not near(ai.MAXCLOSESTDISTANCE, 50 * 2) then fail("MAXCLOSESTDISTANCE 错误") end
  if not near(ai.FRAGBOMBSAFETYDIST, 3 * 50) then fail("FRAGBOMBSAFETYDIST 错误") end
  if not near(ai.MAXCELLDISTTODODGEBULLET, 75 * C.BULLETSPEED / 50) then
    fail("MAXCELLDISTTODODGEBULLET 错误")
  end
  if not near(ai.MAXCELLDISTTODODGEGATLINGBULLET, 75 * C.GATLINGSPEED / 50) then
    fail("MAXCELLDISTTODODGEGATLINGBULLET 错误")
  end

  local tank100, ctx100 = quietCtx(100)
  local ai100 = A.new(tank100, ctx100)
  if not near(ai100.MAXCLOSESTDISTANCE, 200) then fail("scale=100 派生常量错误") end
  ok("M.new 派生常量与实例方法正确")
end

-- 3. period 递减 15 次后第 16 次才进入决策
do
  local tank, ctx = quietCtx(50)
  local ai = A.new(tank, ctx)
  for i = 1, 15 do
    if ai:makeDecisionsAndUpdateGoal() ~= true then fail("第 " .. i .. " 次应返回 true") end
    if ai.myGoal.period ~= 15 - i then fail("period 递减错误: " .. ai.myGoal.period) end
  end
  if ai.myGoal.goal ~= "idle" then fail("递减期间 goal 不应变化") end
  ai:makeDecisionsAndUpdateGoal()            -- 第 16 次才决策
  if ai.myGoal.goal ~= "idle" then fail("无威胁时应保持 idle: " .. ai.myGoal.goal) end
  ok("period 递减与进入决策时机正确")
end

-- 4. idle 不产生任何输入
do
  local tank, ctx = quietCtx(50)
  local ai = A.new(tank, ctx)
  for _ = 1, 16 do ai:makeDecisionsAndUpdateGoal() end
  ai:decideActionsToAchieveGoal()
  if #ai.actions ~= 1 or ai.actions[1].action ~= "idle" then fail("idle 应压入 idle 行动") end
  ai.myGoal.period = 7                         -- 便于观察 idle 是否误重置 period
  tank.forward, tank.backup, tank.turnLeft, tank.turnRight, tank.fire = true, true, true, true, true
  ai:setInputToDoActions()
  if tank.forward or tank.backup or tank.turnLeft or tank.turnRight or tank.fire then
    fail("idle 应清除全部输入")
  end
  if ai.myGoal.period ~= 7 then fail("idle 不应重置 period: " .. ai.myGoal.period) end
  ok("idle 无输入正确")
end

-- 5. hitSomething → backAway（卡墙后退）
do
  local tank, ctx = quietCtx(50)
  tank.hitSomething = true
  local ai = A.new(tank, ctx)
  for _ = 1, 16 do ai:makeDecisionsAndUpdateGoal() end
  if ai.myGoal.goal ~= "backAway" then fail("卡墙应选 backAway: " .. ai.myGoal.goal) end
  if ai.stuckTime ~= 1 then fail("stuckTime 应为 1: " .. ai.stuckTime) end
  ai:decideActionsToAchieveGoal()
  local hasBackup = false
  for _, a in ipairs(ai.actions) do if a.action == "backup" then hasBackup = true end end
  if not hasBackup then fail("backAway 应包含 backup 行动") end
  ai:setInputToDoActions()
  if tank.backup ~= true then fail("backAway 应输出 backup 输入") end
  ok("hitSomething → backAway 正确")
end

-- 6. 敌人在近处 → shootAfter，并生成 fireWeapon + turnTo
do
  local _, enemy, ctx = combatCtx({ { x = 4, y = 2 } })   -- 路径长 1 < 7
  local ai = A.new(ctx.tanks[1], ctx)
  for _ = 1, 16 do ai:makeDecisionsAndUpdateGoal() end
  if ai.myGoal.goal ~= "shootAfter" then fail("近敌应选 shootAfter: " .. ai.myGoal.goal) end
  if ai.myGoal.target ~= enemy then fail("shootAfter 目标错误") end

  ai:decideActionsToAchieveGoal()
  if #ai.actions ~= 2 then fail("shootAfter 应压 2 个行动: " .. #ai.actions) end
  if ai.actions[1].action ~= "fireWeapon" then fail("应先 fireWeapon") end
  if ai.actions[2].action ~= "turnTo" then fail("应后 turnTo") end
  if not near(ai.actions[2].angle, 90) then fail("turnTo 角度应为 90: " .. ai.actions[2].angle) end

  ai:setInputToDoActions()
  if ctx.tanks[1].turnRight ~= true then fail("应输出 turnRight") end
  if ctx.tanks[1].fire or ctx.tanks[1].forward or ctx.tanks[1].backup then
    fail("turnTo 时不应前进/开火")
  end
  ok("shootAfter 行动与输入正确")
end

-- 7. driveTo：行动栈顺序 = driveToField(末格→2) + driveToPos(首格)
do
  local _, _, ctx = combatCtx({ { x = 1, y = 0 }, { x = 2, y = 0 } })
  local ai = A.new(ctx.tanks[1], ctx)
  ai.myGoal = { goal = "driveTo", x = 2, y = 0, period = 10, priority = 0.1,
                updateContinuously = false, id = 1 }
  ai:decideActionsToAchieveGoal()
  if #ai.actions ~= 2 then fail("driveTo 应压 2 个行动: " .. #ai.actions) end
  if ai.actions[1].action ~= "driveToField" or ai.actions[1].x ~= 2 or ai.actions[1].y ~= 0 then
    fail("driveTo 首压应到格 (2,0)")
  end
  local dp = ai.actions[2]
  if dp.action ~= "driveToPos" then fail("driveTo 末压应 driveToPos") end
  if not (near(dp.x, 75) and near(dp.y, 25)) then fail("driveToPos 位置错误") end
  if dp.canReverse ~= true then fail("n<=2 时 canReverse 应为 true") end
  ok("driveTo 行动栈正确")
end

-- 8. goForCrate：先到最后一格角落，再走路径
do
  local _, _, ctx = combatCtx({ { x = 1, y = 0 }, { x = 2, y = 0 } })
  local ai = A.new(ctx.tanks[1], ctx)
  ai.myGoal = { goal = "goForCrate", x = 2, y = 0, period = 10, priority = 1,
                updateContinuously = false, id = 1 }
  ai:decideActionsToAchieveGoal()
  if #ai.actions ~= 3 then fail("goForCrate 应压 3 个行动: " .. #ai.actions) end
  local first = ai.actions[1]
  if first.action ~= "driveToPos" or not (near(first.x, 125) and near(first.y, 25)) then
    fail("goForCrate 首行动应为末格中心 (125,25)")
  end
  if ai.actions[2].action ~= "driveToField" or ai.actions[2].x ~= 2 then
    fail("goForCrate 次行动应为 driveToField(2,0)")
  end
  if ai.actions[3].action ~= "driveToPos" or not near(ai.actions[3].x, 75) then
    fail("goForCrate 末行动应为首格 (75,25)")
  end
  ok("goForCrate 行动栈正确")
end

-- 9. setInputToDoActions：行动 → 输入映射
do
  local function fresh()
    local tank, ctx = quietCtx(50)
    return tank, A.new(tank, ctx)
  end

  -- turnTo：rot 0 → 90 需右转
  do
    local tank, ai = fresh()
    ai.actions = { { action = "turnTo", angle = 90 } }
    ai:setInputToDoActions()
    if tank.turnRight ~= true or tank.turnLeft ~= false then fail("turnTo 应右转") end
    if tank.forward or tank.backup or tank.fire then fail("turnTo 不应前进/开火") end
  end

  -- forward
  do
    local tank, ai = fresh()
    ai.actions = { { action = "forward", dist = 3 } }
    ai:setInputToDoActions()
    if tank.forward ~= true then fail("forward 应输出 forward") end
    if tank.backup or tank.turnLeft or tank.turnRight or tank.fire then
      fail("forward 不应有其他输入")
    end
  end

  -- backupAndTurn：dir=left
  do
    local tank, ai = fresh()
    ai.actions = { { action = "backupAndTurn", dist = 5, dir = "left" } }
    ai:setInputToDoActions()
    if tank.backup ~= true or tank.turnLeft ~= true or tank.turnRight ~= false then
      fail("backupAndTurn(left) 输入错误")
    end
  end

  -- fireWeapon：delay 递减并开火
  do
    local tank, ai = fresh()
    ai.actions = { { action = "fireWeapon", delay = 3 } }
    ai:setInputToDoActions()
    if tank.fire ~= true then fail("fireWeapon 应开火") end
    if ai.actions[1] and ai.actions[1].delay ~= 2 then fail("fireWeapon delay 未递减") end
  end

  -- driveToPos：目标在正前方 → 直行
  do
    local tank, ai = fresh()
    ai.actions = { { action = "driveToPos", x = 200, y = 100, canReverse = false } }
    ai:setInputToDoActions()
    if tank.turnRight ~= true then fail("driveToPos 应右转对准") end
    if tank.forward or tank.backup then fail("大角度差时不应前进/后退") end
  end

  -- idle：清空输入
  do
    local tank, ai = fresh()
    ai.actions = { { action = "idle" } }
    tank.forward, tank.backup, tank.turnLeft, tank.turnRight, tank.fire =
      true, true, true, true, true
    ai:setInputToDoActions()
    if tank.forward or tank.backup or tank.turnLeft or tank.turnRight or tank.fire then
      fail("idle 应清空输入")
    end
  end

  -- 空行动栈：清空输入并重置 period
  do
    local tank, ai = fresh()
    ai.actions = {}
    ai:setInputToDoActions()
    if tank.forward or tank.backup or tank.turnLeft or tank.turnRight or tank.fire then
      fail("空栈应清空输入")
    end
    if ai.myGoal.period ~= 0 then fail("空栈应重置 period=0") end
  end

  ok("setInputToDoActions 行动→输入映射正确")
end

print("\n全部通过。")
