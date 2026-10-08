--[[ 补给箱 / 回合流程 / 计分 / 震屏 自测 ]]
package.path = package.path .. ";./?.lua"

local C = require("src.constants")
local R = require("src.round")

local function fail(msg) print("[FAIL] " .. msg); os.exit(1) end
local function ok(msg) print("[ok] " .. msg) end

-- 1. 刷新计时公式：rng()=0 时 = (350 + 0 + 2000/len) * modifier
local zero = function() return 0 end
local t1 = R.nextCrateTimer(40, 1, zero)
if math.abs(t1 - (350 + 2000 / 40)) > 1e-9 then fail("nextCrateTimer 公式错误: " .. t1) end
local t2 = R.nextCrateTimer(40, 2, zero)
if math.abs(t2 - (350 + 2000 / 40) * 2) > 1e-9 then fail("nextCrateTimer modifier 错误") end
-- rng()=0.5 → +floor(0.5*200)=100
local half = function() return 0.5 end
local t3 = R.nextCrateTimer(40, 1, half)
if math.abs(t3 - (350 + 100 + 50)) > 1e-9 then fail("nextCrateTimer 随机项错误: " .. t3) end
ok("nextCrateTimer 公式正确")

-- 2. 选点：箱子上限已满 → 不生成
local ctxMaxed = {
  reachable = { { x = 0, y = 0, used = false } },
  reachableIndex = { [0] = { [0] = 0 } },
  crateSpawnPoints = {}, tanks = {}, scale = 50,
  numberOfCrates = 3, settings = { maxCrates = 3 },
}
if R.pickCratePos(ctxMaxed) ~= nil then fail("上限已满仍生成") end
ok("箱子上限已满时不生成")

-- 3. 选点：唯一可达格被存活坦克占据（曼哈顿距离 ≤ 1）→ 5 次尝试后放弃
local ctxNear = {
  reachable = { { x = 0, y = 0, used = false } },
  reachableIndex = { [0] = { [0] = 0 } },
  crateSpawnPoints = {}, scale = 50,
  tanks = { { x = 0, y = 0, alive = true } },
  numberOfCrates = 0, settings = { maxCrates = 3 },
}
if R.pickCratePos(ctxNear) ~= nil then fail("坦克旁仍生成") end
ok("靠近存活坦克时不生成")

-- 4. 选点：正常随机 → 落在 1..#reachable
math.randomseed(20261008)
local ctxOk = {
  reachable = { { x = 0, y = 0, used = false }, { x = 1, y = 0, used = false }, { x = 2, y = 0, used = false } },
  reachableIndex = { [0] = { [0] = 0 }, [1] = { [0] = 1 }, [2] = { [0] = 2 } },
  crateSpawnPoints = {}, tanks = {}, scale = 50,
  numberOfCrates = 0, settings = { maxCrates = 3 },
}
local p = R.pickCratePos(ctxOk)
if p == nil or p < 1 or p > 3 then fail("正常选点越界") end
ok("正常选点返回 1..#reachable（得到 " .. p .. "）")

-- 5. 选点：自定义出生点限定 → 只能落在该点
local ctxSpawn = {
  reachable = { { x = 0, y = 0, used = false }, { x = 1, y = 0, used = false }, { x = 2, y = 0, used = false } },
  reachableIndex = { [0] = { [0] = 0 }, [1] = { [0] = 1 }, [2] = { [0] = 2 } },
  crateSpawnPoints = { { x = 2, y = 0 } }, tanks = {}, scale = 50,
  numberOfCrates = 0, settings = { maxCrates = 3 },
}
for _ = 1, 20 do
  local q = R.pickCratePos(ctxSpawn)
  if q ~= 3 then fail("自定义出生点未生效: " .. tostring(q)) end
end
ok("自定义出生点限定生效")

-- 6. 武器抽取
local w = R.pickCrateWeapon({ "laser" }, function() return 0 end)
if w ~= "laser" then fail("pickCrateWeapon 错误") end
if R.pickCrateWeapon({}) ~= nil then fail("空武器池应返回 nil") end
ok("pickCrateWeapon 正确")

-- 7. 拾取：仅 bullet 且四角命中
local crate = { x = 100, y = 100 }
local opts = {
  corners = function() return { { 90, 90 }, { 90, 110 }, { 110, 110 }, { 110, 90 } } end,
  boxContains = function(t, px, py) return px == 90 and py == 90 end,
}
local bulletTank = { alive = true, currentWeapon = "bullet" }
local laserTank = { alive = true, currentWeapon = "laser" }
if R.tryPickup(crate, { laserTank }, opts) ~= nil then fail("非 bullet 也拾取") end
if R.tryPickup(crate, { bulletTank }, opts) ~= bulletTank then fail("bullet 未拾取") end
if R.tryPickup(crate, { { alive = false, currentWeapon = "bullet" } }, opts) ~= nil then fail("死亡坦克拾取") end
ok("拾取判定：仅存活且 bullet 且四角命中")

-- 8. 回合流程：击杀 → 冻结(50) → 清理(0) → 重置
local r = R.newBattle(3, 100)
if r.aliveCount ~= 3 or r.endCount ~= C.NUMBEROFFRAMESBEFOREEND + C.NUMBEROFFRAMESFROZEN then
  fail("newBattle 初值错误")
end
R.onTankKilled(r)
if r.aliveCount ~= 2 or r.endCount ~= C.NUMBEROFFRAMESBEFOREEND or r.shake ~= 7 then
  fail("onTankKilled 错误")
end
R.onTankKilled(r)   -- aliveCount = 1
if r.aliveCount ~= 1 then fail("aliveCount 错误") end
r.shake = R.addShake(r.shake, 7)
if r.shake ~= C.MAXSHAKE then fail("shake 上限错误: " .. r.shake) end

local events, freezeAt, cleanupAt, resetAt, step = {}, nil, nil, nil, 0
while step < 300 do
  step = step + 1
  local ox, oy, ev = R.step(r)
  if math.abs(ox) > r.shake / 2 + 0.5 then fail("震屏偏移越界") end
  if ev then
    events[ev] = step
    if ev == "freeze" then freezeAt = step end
    if ev == "cleanup" then cleanupAt = step end
    if ev == "reset" then resetAt = step; break end
  end
end
if freezeAt == nil or cleanupAt == nil or resetAt == nil then fail("回合事件缺失") end
if cleanupAt - freezeAt ~= C.NUMBEROFFRAMESFROZEN then fail("冻结时长错误") end
if resetAt - cleanupAt ~= C.NUMBEROFFRAMESBEFORERESET - 1 then fail("重置间隔错误") end
if r.frozen ~= false then fail("重置后应解冻") end
if r.endCount ~= C.NUMBEROFFRAMESBEFOREEND + C.NUMBEROFFRAMESFROZEN then fail("重置后 endCount 错误") end
ok("回合流程：freeze@" .. freezeAt .. " cleanup@" .. cleanupAt .. " reset@" .. resetAt)

-- 9. 计分公式
local tanks = { { alive = true, exp = 0, score = 0 }, { alive = false, exp = 0, score = 2 } }
local pts = R.assignPoints(tanks)
if pts ~= 10 then fail("assignPoints 基础值错误: " .. pts) end
if tanks[1].score ~= 1 or tanks[1].exp ~= 10 then fail("胜者计分错误") end
if tanks[2].score ~= 2 then fail("败者不应加分") end

local tanks2 = {
  { alive = true, exp = 0, score = 0 },
  { alive = false, exp = 500, score = 0 },
  { alive = false, exp = 500, score = 0 },
}
local pts2 = R.assignPoints(tanks2)
-- 10 + (1000 - 1)/100 = 19.99 → round = 20
if pts2 ~= 20 then fail("assignPoints 上限错误: " .. pts2) end
ok("assignPoints 公式正确")

-- 10. 补给箱计时推进
local r2 = R.newBattle(2, 3)
local rng0 = function() return 0 end
if R.tickCrateTimer(r2, 40, 1, rng0) ~= false then fail("未到点不应触发") end
if R.tickCrateTimer(r2, 40, 1, rng0) ~= false then fail("未到点不应触发(2)") end
if R.tickCrateTimer(r2, 40, 1, rng0) ~= true then fail("到点应触发") end
if math.abs(r2.crateTimer - (350 + 50)) > 1e-9 then fail("到点后未重算计时") end
r2.frozen = true
local before = r2.crateTimer
if R.tickCrateTimer(r2, 40, 1, rng0) ~= false or r2.crateTimer ~= before then
  fail("冻结时不应递减")
end
ok("补给箱计时推进正确")

print("\n全部通过。")