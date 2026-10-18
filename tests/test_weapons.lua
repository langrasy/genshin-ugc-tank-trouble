--[[ 武器 / 投射物 自测（src/weapons.lua） ]]
package.path = package.path .. ";./?.lua"

local C = require("src.constants")
local W = require("src.weapons")

---@noreturn
local function fail(msg) print("[FAIL] " .. msg); os.exit(1) end
local function ok(msg) print("[ok] " .. msg) end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end

-- fireLaser 需要 ctx.setEquipment；其余字段 makeCtx 已给缺省空实现
local function ctxWith(o)
  local ctx = W.makeCtx(o)
  ctx.setEquipment = function() end
  return ctx
end

-- 1. 就绪 / 锁控判定
do
  if not W.weaponReady({}, "bullet") then fail("bullet 缺省应就绪") end
  if W.weaponReady({ bulletsFired = 5 }, "bullet", 5) then fail("bullet 5/5 应不就绪") end
  if not W.weaponReady({ bulletsFired = 4 }, "bullet", 5) then fail("bullet 4/5 应就绪") end

  if W.weaponReady({ laserReady = false }, "laser") then fail("laser 未就绪") end
  if not W.lockedControl({ laserReady = false }, "laser") then fail("laser 应锁控") end
  if not W.weaponReady({}, "frag") then fail("frag 恒就绪") end
  if not W.weaponReady({}, "mine") then fail("mine 恒就绪") end

  if not W.weaponReady({ remoteControlling = false }, "remote") then fail("remote 未控制应就绪") end
  if W.weaponReady({ remoteControlling = true }, "remote") then fail("remote 控制中应不就绪") end
  if not W.lockedControl({ remoteControlling = true }, "remote") then fail("remote 控制中应锁控") end

  if W.weaponReady({}, "gatling") then fail("gatling 未就绪") end
  if not W.weaponReady({ gatlingReady = true }, "gatling") then fail("gatling 应就绪") end
  if W.weaponReady({}, "homing") then fail("homing 未就绪") end
  if W.weaponReady({}, "electric") then fail("electric 未就绪") end
  if W.weaponReady({}, "deathRay") then fail("deathRay 未就绪") end
  if W.weaponReady({}, "elToro") then fail("elToro 未就绪") end

  if W.lockedControl({}, "bullet") then fail("bullet 不应锁控") end
  if not W.lockedControl({ elToroReady = false }, "elToro") then fail("elToro 应锁控") end
  if not W.lockedControl({ deathRayReady = false }, "deathRay") then fail("deathRay 应锁控") end
  ok("weaponReady / lockedControl 分支正确")
end

-- 2. 坐标变换
do
  local t = { x = 10, y = 20, s = 1, rot = 0 }
  local gx, gy = W.tankPointGlobal(t, 5, 3)
  if not (near(gx, 15) and near(gy, 23)) then fail("tankPointGlobal rot=0 错误: " .. gx .. "," .. gy) end
  local t2 = { x = 0, y = 0, s = 2, rot = 90 }
  gx, gy = W.tankPointGlobal(t2, 1, 0)   -- rot=90 → 局部 x 轴指向全局 +y
  if not (near(gx, 0) and near(gy, 2)) then fail("tankPointGlobal rot=90 错误: " .. gx .. "," .. gy) end
  ok("tankPointGlobal 变换正确")
end

-- 3. 坦克包含 / 底座包含 近似形状
do
  local t = { x = 100, y = 100, s = 1, rot = 0 }
  local contains = W.makeTankContains(t)
  local base = W.makeTankBaseContains(t)
  if not contains(100, 100) then fail("中心应被包含") end
  if not base(100, 100) then fail("底座中心应被包含") end
  if contains(100, 100 + W.BASE_H / 2 + 1) then fail("底座外应不包含") end
  if base(100 + W.BASE_W / 2 + 1, 100) then fail("底座横向外应不包含") end
  if not base(100, 100 + W.BASE_H / 2 - 0.5) then fail("底座边缘内应包含") end
  ok("makeTankContains / makeTankBaseContains 正确")
end

-- 4. fireBullet：计数、炮口、速度公式（scale=50 与 scale=100）
do
  local ctx = ctxWith({ scale = 50 })
  local owner = { rot = 90, x = 0, y = 0, s = 1, bulletsFired = 0, turretColor = "c" }
  local b = W.fireBullet(owner, ctx)
  if owner.bulletsFired ~= 1 then fail("bulletsFired 未递增") end
  if b.kind ~= "bullet" then fail("kind 错误") end
  if not near(b.x, 50 * 4.5 / 16) then fail("炮口 x 错误: " .. b.x) end
  if not near(b.y, 0) then fail("炮口 y 错误") end
  if not near(b.xSpeed, C.BULLETSPEED / C.BULLETHITCHECKINTERVALS) then fail("xSpeed 错误") end
  if not near(b.ySpeed, 0) then fail("ySpeed 错误") end
  if b.lifetime ~= C.BULLETLIFETIME or b.deadly ~= C.BULLETDEADLY then fail("弹参数错误") end

  local ctx2 = ctxWith({ scale = 100 })
  local owner2 = { rot = 90, x = 0, y = 0, s = 1, bulletsFired = 0, turretColor = "c" }
  local b2 = W.fireBullet(owner2, ctx2)
  if not near(b2.x, 100 * 4.5 / 16) then fail("scale=100 炮口错误") end
  if not near(b2.xSpeed, C.BULLETSPEED / C.BULLETHITCHECKINTERVALS * 2) then fail("scale=100 速度错误") end
  ok("fireBullet 初值与速度公式正确")
end

-- 5. 各武器发射初值
do
  local ctx = ctxWith({ scale = 50 })

  local o = { rot = 90, x = 0, y = 0, s = 1, turretColor = "c", laserReady = true }
  local l = W.fireLaser(o, ctx)
  if o.laserReady ~= false then fail("laser 应置未就绪") end
  if l.kind ~= "laser" or not l.active or l.lifetime ~= C.LASERLIFETIME then fail("laser 初值错误") end
  if l.deadly ~= C.LASERDEADLY then fail("laser deadly 错误") end

  local fo = { rot = 90, x = 0, y = 0, s = 1, turretColor = "c" }
  ---@type any
  local fr = W.fireFrag(fo, ctx)
  if fo.fragFired ~= true or fo.lastFrag ~= fr then fail("frag 未记录 lastFrag") end
  if fr.level ~= C.FRAGLEVELS then fail("frag level 错误") end

  local go = { rot = 90, x = 0, y = 0, s = 1, turretColor = "c", gatlingReady = true }
  local ga = W.fireGatling(go, ctx)
  if go.gatlingReady ~= false or not ga.active or ga.bulletsLeft ~= C.GATLINGBULLETS then
    fail("gatling 初值错误")
  end
  if ga.kind ~= "gatling" then fail("gatling kind 错误") end

  local dctx = ctxWith({ scale = 50 })
  local do_ = { rot = 90, x = 0, y = 0, s = 1, turretColor = "c", deathRayReady = true }
  local dr = W.fireDeathRay(do_, dctx)
  if do_.deathRayReady ~= false then fail("deathRay 应置未就绪") end
  if dr.warmup ~= C.DEATHRAYWARMUPTIME or dr.lifetime ~= C.DEATHRAYLIFETIME then fail("deathRay 初值错误") end

  local ho = { rot = 90, x = 0, y = 0, s = 1, turretColor = "c", baseColor = "b", homingReady = true }
  local hm = W.fireHoming(ho, ctx)
  if ho.homingReady ~= false then fail("homing 应置未就绪") end
  if hm.startuptime ~= C.HOMINGSTARTUPTIME or hm.homing ~= false then fail("homing 初值错误") end

  local mo = { rot = 90, x = 0, y = 0, s = 1, turretColor = "c", minesLayed = 0 }
  local mn = W.layMine(mo, ctx)
  if mn.xSpeed ~= -C.MINESPEED / C.MINEHITCHECKINTERVALS or mn.ySpeed ~= 0 then fail("mine 速度错误") end
  if mn.rotation ~= 270 then fail("mine 朝向错误: " .. mn.rotation) end
  if mn.deadly ~= C.MINEDEADLY then fail("mine deadly 错误") end

  local ro = { rot = 90, x = 0, y = 0, s = 1, turretColor = "c", baseColor = "b" }
  local rm = W.fireRemote(ro, ctx)
  if ro.remoteControlling ~= true then fail("remote 应置控制中") end
  if rm.turnSpeed ~= C.REMOTETURNSPEED or rm.lifetime ~= C.REMOTELIFETIME then fail("remote 初值错误") end
  ok("fire* 各武器初值正确")
end

-- 6. fireElectric：成对弹丸
do
  local ctx = ctxWith({ scale = 50 })
  local owner = { rot = 90, x = 0, y = 0, s = 1, turretColor = "c", electricReady = true }
  local list = W.fire(owner, "electric", ctx)
  if #list ~= 2 then fail("electric 应返回 2 发") end
  ---@type any, any
  local b1, b2 = list[1], list[2]
  if owner.electricReady ~= false then fail("electric 应置未就绪") end
  if b1.isFirst ~= true or b2.isFirst ~= nil then fail("isFirst 标记错误") end
  if b1.partner ~= b2 or b2.partner ~= b1 then fail("partner 互指错误") end
  if not (b1.ySpeed < 0 and b2.ySpeed > 0) then fail("±5° 夹角方向错误") end
  ok("fireElectric 成对弹丸正确")
end

-- 7. fire 派发：单发武器返回 1 个，未知武器返回空
do
  local ctx = ctxWith({ scale = 50 })
  for _, name in ipairs({ "bullet", "laser", "frag", "gatling", "deathRay", "homing", "mine", "remote" }) do
    local owner = {
      rot = 90, x = 0, y = 0, s = 1, turretColor = "c", baseColor = "b",
      laserReady = true, deathRayReady = true, homingReady = true, gatlingReady = true,
    }
    if #W.fire(owner, name, ctx) ~= 1 then fail("fire(" .. name .. ") 应返回 1 个") end
  end
  if #W.fire({}, "nope", ctx) ~= 0 then fail("未知武器应返回空") end
  ok("fire 派发正确")
end

-- 8. M.step 未知 kind 视为存活
do
  local ctx = ctxWith({ scale = 50 })
  if W.step({ kind = "wat" }, ctx) ~= true then fail("未知 kind 应返回 true") end
  ok("M.step 未知 kind 返回 true")
end

-- 9. bullet 撞墙反弹（单轴反射）
do
  local ctx = ctxWith({ scale = 50, wallHit = function(x) return x > 5 end })
  local p = {
    kind = "bullet", owner = nil, x = 0, y = 0, xSpeed = 1, ySpeed = 0,
    lifetime = 1000, deadly = 0, intervals = 1,
  }
  for _ = 1, 6 do W.step(p, ctx) end
  if not near(p.xSpeed, -1) then fail("X 轴应反射: " .. p.xSpeed) end
  if not near(p.x, 4) then fail("反射后位置错误: " .. p.x) end
  ok("bullet 撞墙单轴反射正确")
end

-- 10. bullet 生命周期耗尽：递减归属计数 + 冒烟 + 结束
do
  local sounds = {}
  local ctx = ctxWith({ scale = 50, sound = function(s) sounds[#sounds + 1] = s end })
  local owner = { rot = 90, x = 0, y = 0, s = 1, bulletsFired = 1, turretColor = "c" }
  local p = W.fireBullet(owner, ctx)      -- bulletsFired → 2
  p.lifetime = 1
  local cont = W.step(p, ctx)
  if cont then fail("寿命尽应结束") end
  if owner.bulletsFired ~= 1 then fail("应归还 1 发计数: " .. owner.bulletsFired) end
  if sounds[#sounds] ~= "soundPoof" then fail("应播放 soundPoof") end
  ok("bullet 寿命耗尽处理正确")
end

-- 11. bullet 命中坦克：onHit + 结束
do
  local hits = {}
  local tank = { alive = true }
  local ctx = ctxWith({
    scale = 50, tanks = { tank },
    tankContains = function() return true end,
    onHit = function(o, v) hits[#hits + 1] = v end,
  })
  local owner = { rot = 90, x = 0, y = 0, s = 1, bulletsFired = 1, turretColor = "c" }
  local p = W.fireBullet(owner, ctx)
  if W.step(p, ctx) then fail("命中应结束") end
  if hits[1] ~= tank then fail("onHit 目标错误") end
  ok("bullet 命中坦克正确")
end

-- 11b. bullet 命中坦克也要归还弹药槽（原版 DefineSprite_212_bullet:100-113）
do
  local nHit = 0
  local ctx = ctxWith({
    scale = 50, tanks = { { alive = true } },
    tankContains = function() return true end,
    onHit = function() nHit = nHit + 1 end,
  })
  local owner = { rot = 90, x = 0, y = 0, s = 1, bulletsFired = 1, turretColor = "c" }
  local p = W.fireBullet(owner, ctx)      -- bulletsFired → 2
  if W.step(p, ctx) then fail("命中应结束") end
  if nHit ~= 1 then fail("onHit 次数错误") end
  if owner.bulletsFired ~= 1 then fail("命中应归还 1 发计数: " .. owner.bulletsFired) end
  ok("bullet 命中坦克归还弹药槽正确")
end

-- 11c. 一发子弹同时压住两辆坦克 ⇒ 归还 2（原版命中循环不 break）
do
  local ctx = ctxWith({
    scale = 50, tanks = { { alive = true }, { alive = true } },
    tankContains = function() return true end,
    onHit = function() end,
  })
  local owner = { rot = 90, x = 0, y = 0, s = 1, bulletsFired = 0, turretColor = "c" }
  local p = W.fireBullet(owner, ctx)      -- bulletsFired → 1
  if W.step(p, ctx) then fail("命中应结束") end
  -- 原版 while 循环不 break ⇒ 命中 n 辆就扣 n（极小概率下可为负；weaponReady 只判 "< 上限"，不受影响）
  if owner.bulletsFired ~= 1 - 2 then fail("两辆命中应各扣 1: " .. owner.bulletsFired) end
  ok("bullet 命中多辆坦克逐辆归还计数正确")
end

-- 12. laser：推进产生描边点，寿命递减
do
  local ctx = ctxWith({ scale = 50 })
  local owner = { rot = 90, x = 0, y = 0, s = 1, turretColor = "c", laserReady = true }
  local p = W.fireLaser(owner, ctx)
  W.step(p, ctx)
  if #p.linePoints ~= C.LASERHITCHECKINTERVALS then fail("laser 描边点数错误: " .. #p.linePoints) end
  if p.lifetime ~= C.LASERLIFETIME - 1 then fail("laser 寿命递减错误") end
  ok("laser 推进与寿命正确")
end

-- 13. laser 命中：lifetime 归零 → 复位就绪并换回 bullet
do
  local ctx = ctxWith({
    scale = 50, tanks = { { alive = true } },
    tankContains = function() return true end,
    onHit = function() end,
  })
  local owner = { rot = 90, x = 0, y = 0, s = 1, turretColor = "c", laserReady = true }
  local p = W.fireLaser(owner, ctx)
  W.step(p, ctx)
  if p.lifetime ~= 0 then fail("命中后寿命应为 0: " .. p.lifetime) end
  if p.active then fail("命中后应失活") end
  if owner.laserReady ~= true then fail("命中后应恢复就绪") end
  ok("laser 命中处理正确")
end

-- 14. frag：寿命尽 → 引爆（清标记 + 生成弹片）
do
  local spawned = {}
  local ctx = ctxWith({
    scale = 50, shake = function() end, setWeapon = function() end,
    spawn = function(f) spawned[#spawned + 1] = f end,
  })
  local owner = { rot = 90, x = 0, y = 0, s = 1, turretColor = "c", alive = true,
                  fragFired = false, lastFrag = nil }
  ---@type any
  local p = W.fireFrag(owner, ctx)
  if p == nil then fail("frag 应发射新弹") end
  if owner.fragFired ~= true or owner.lastFrag ~= p then fail("发射后未登记在飞弹") end
  p.lifetime = 1
  local cont = W.step(p, ctx)
  if cont then fail("frag 寿命尽应结束") end
  if p.remove ~= true then fail("引爆应标记 remove") end
  if owner.fragFired ~= false or owner.lastFrag ~= nil then fail("引爆未清标记") end
  if #spawned ~= C.FRAGFRAGMENTS then fail("弹片数量错误: " .. #spawned) end
  ok("frag 引爆处理正确")
end

-- 14b. frag：在飞弹未爆时再开火 → 引爆该弹，不发射新弹
do
  local ctx = ctxWith({
    scale = 50, shake = function() end, setWeapon = function() end, spawn = function() end,
  })
  local owner = { rot = 90, x = 0, y = 0, s = 1, turretColor = "c", alive = true,
                  fragFired = false, lastFrag = nil }
  ---@type any
  local p = W.fireFrag(owner, ctx)
  local q = W.fireFrag(owner, ctx)
  if q ~= nil then fail("在飞弹未爆时再开火不应发射新弹") end
  if p.remove ~= true then fail("再开火应引爆在飞弹") end
  if owner.fragFired ~= false or owner.lastFrag ~= nil then fail("引爆未清标记") end
  ok("frag 再开火引爆在飞弹正确")
end

-- 15. detonateMine：震屏 + 音效 + 弹片 + remove
do
  local spawned, sounds = {}, {}
  local ctx = ctxWith({
    scale = 50,
    shake = function() end,
    sound = function(s) sounds[#sounds + 1] = s end,
    spawn = function(f) spawned[#spawned + 1] = f end,
  })
  local p = { kind = "mine", owner = {}, x = 0, y = 0, color = "c" }
  W.detonateMine(p, ctx)
  if p.remove ~= true then fail("地雷引爆应 remove") end
  if #spawned ~= C.MINEFRAGMENTS then fail("地雷弹片数量错误: " .. #spawned) end
  if sounds[#sounds] ~= "soundExplosion3" then fail("地雷音效错误") end
  ok("detonateMine 正确")
end

-- 16. mine 流程：落地 → 邻近坦克激活 → 坦克离开 → 延时引爆
do
  local near_ = true
  local ctx = ctxWith({
    scale = 50,
    tanks = { { alive = true } },
    tankBaseContains = function() return near_ end,
    shake = function() end, sound = function() end, smoke = function() end, spawn = function() end,
  })
  local p = {
    kind = "mine", owner = {}, x = 0, y = 0, xSpeed = 0, ySpeed = 0,
    deadly = C.MINEDEADLY, intervals = 1, hideCounter = C.MINEHIDETIME,
    landed = false, armed = false, detonating = false,
    detonateCounter = C.MINEDETONATETIME, alpha = 100, scaleFactor = 25 / 100, color = "c",
  }
  for _ = 1, 60 do W.step(p, ctx) end
  if not p.landed then fail("地雷应落地") end
  if not p.armed then fail("地雷应被邻近坦克激活") end

  near_ = false
  local cont, steps = true, 0
  while cont and steps < 60 do steps = steps + 1; cont = W.step(p, ctx) end
  if cont then fail("地雷应延时引爆并结束") end
  if p.remove ~= true then fail("地雷引爆应 remove") end
  ok("mine 落地 / 激活 / 引爆流程正确（" .. steps .. " 帧）")
end

-- 17. homing：寿命耗尽 → 恢复就绪并结束
do
  local ctx = ctxWith({ scale = 50 })
  local owner = { rot = 90, x = 0, y = 0, s = 1, turretColor = "c", baseColor = "b",
                  homingReady = true, alive = true }
  local p = W.fireHoming(owner, ctx)
  p.lifetime = 1
  if W.step(p, ctx) then fail("homing 寿命尽应结束") end
  if owner.homingReady ~= true then fail("homing 应恢复就绪") end
  ok("homing 寿命耗尽处理正确")
end

-- 18. remote：寿命耗尽 → 解除控制并结束
do
  local ctx = ctxWith({ scale = 50 })
  local owner = { rot = 90, x = 0, y = 0, s = 1, turretColor = "c", baseColor = "b",
                  remoteControlling = true, alive = true, mouseTank = false }
  local p = W.fireRemote(owner, ctx)
  p.lifetime = 1
  if W.step(p, ctx) then fail("remote 寿命尽应结束") end
  if owner.remoteControlling ~= false then fail("remote 应解除控制") end
  ok("remote 寿命耗尽处理正确")
end

-- 19. gatling：转速到顶后吐弹 → 松开扳机 → 停转复位
do
  local spawned = {}
  local ctx = ctxWith({
    scale = 50,
    spawn = function(f) spawned[#spawned + 1] = f end,
    sound = function() end, setWeapon = function() end,
  })
  local owner = { rot = 90, x = 0, y = 0, s = 1, turretColor = "c",
                  gatlingReady = false, alive = true, triggerReleased = false }
  local p = W.fireGatling(owner, ctx)
  for _ = 1, 18 do W.step(p, ctx) end
  if p.spinSpeed ~= C.GATLINGSPINSPEED then fail("gatling 转速应到顶: " .. p.spinSpeed) end
  if #spawned ~= 3 then fail("gatling 吐弹数量错误: " .. #spawned) end
  if p.bulletsLeft ~= C.GATLINGBULLETS - 3 then fail("gatling 余弹错误: " .. p.bulletsLeft) end
  if spawned[1].kind ~= "gatlingBullet" then fail("gatling 弹种错误") end

  owner.triggerReleased = true
  local cont, steps = true, 0
  while cont and steps < 100 do steps = steps + 1; cont = W.step(p, ctx) end
  if cont then fail("gatling 停转后应结束") end
  if owner.gatlingReady ~= true then fail("gatling 应恢复就绪") end
  ok("gatling 转管 / 吐弹 / 复位正确")
end

-- 20. fragment：撞墙失活 → alpha 衰减到 0 结束
do
  local sounds = {}
  local ctx = ctxWith({
    scale = 50, wallHit = function(x) return x > 3 end,
    sound = function(s) sounds[#sounds + 1] = s end,
  })
  local p = {
    kind = "fragment", owner = {}, color = "c", x = 0, y = 0,
    xSpeed = 1, ySpeed = 0, rotation = 0, rotSpeed = 5,
    active = true, alpha = 100, intervals = 1,
  }
  local cont, steps = true, 0
  while cont and steps < 300 do steps = steps + 1; cont = W.step(p, ctx) end
  if cont then fail("fragment 应结束") end
  if p.active then fail("fragment 撞墙后应失活") end
  if #sounds == 0 then fail("fragment 撞墙应有音效") end
  ok("fragment 撞墙失活 / 淡出正确（" .. steps .. " 帧）")
end

-- 21. spawnFragments 数量与种类
do
  local spawned = {}
  local ctx = ctxWith({ scale = 50, spawn = function(f) spawned[#spawned + 1] = f end })
  W.spawnFragments({ owner = {}, color = "c", x = 1, y = 2 }, ctx, 7)
  if #spawned ~= 7 then fail("弹片数量错误: " .. #spawned) end
  if spawned[1].kind ~= "fragment" then fail("弹片 kind 错误") end
  ok("spawnFragments 正确")
end

-- 22. layMine 达标自动换回 bullet
do
  local setW = {}
  local ctx = ctxWith({ scale = 50, setWeapon = function(o, k) setW[#setW + 1] = { o, k } end })
  local owner = { rot = 90, x = 0, y = 0, s = 1, turretColor = "c", minesLayed = 0 }
  W.layMine(owner, ctx)
  W.layMine(owner, ctx)
  if owner.minesLayed ~= 2 then fail("minesLayed 计数错误") end
  if #setW ~= 0 then fail("未满不应换武器") end
  W.layMine(owner, ctx)
  if owner.minesLayed ~= C.MINENUMBER then fail("minesLayed 未达上限") end
  if setW[1] == nil or setW[1][2] ~= "bullet" then fail("埋满应换回 bullet") end
  ok("layMine 计数与自动换武器正确")
end

-- 23. repulseAll：仅调用带方法的装备
do
  local called = 0
  local ctx = ctxWith({ scale = 50 })
  W.repulseAll({}, ctx, {
    { repulseBullet = function() called = called + 1 end },
    {},
    { repulseBullet = function() called = called + 1 end },
  })
  if called ~= 2 then fail("repulseAll 调用次数错误: " .. called) end
  ok("repulseAll 正确")
end

print("\n全部通过。")
