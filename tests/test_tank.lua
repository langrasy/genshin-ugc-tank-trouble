--[[ 坦克物理与操控自测
     逐项对照 GameTank.swf → DefineSprite_69_gameTank/frame_1/DoAction.as 的行为。 ]]
package.path = package.path .. ";./?.lua"

local T = require("src.tank")

---@noreturn
local function fail(msg) print("[FAIL] " .. msg); os.exit(1) end
local function ok(msg) print("[ok] " .. msg) end
local function approx(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end
local function assertApprox(a, b, eps, msg)
  if not approx(a, b, eps) then
    fail(string.format("%s（期望 %.6f，实际 %.6f）", msg, b, a))
  end
end

local noWall = function() return false end

-- ============================================================
-- 1. 碰撞点尺寸（对照第 382-406 行）
-- ============================================================
do
  local hp = T.makeHitPoints()
  assertApprox(hp.front[1][1], -T.BASE_W / 2, 1e-9, "front[1].x")
  assertApprox(hp.front[1][2], -T.BASE_H / 2, 1e-9, "front[1].y")
  assertApprox(hp.front[5][2], -T.TURRET_H / 16 * 11, 1e-9, "front[5].y（炮塔前缘）")
  if #hp.front ~= 6 then fail("front 应有 6 点，实际 " .. #hp.front) end
  if #hp.rear ~= 5 then fail("rear 应有 5 点，实际 " .. #hp.rear) end
  if #hp.left ~= 5 or #hp.right ~= 5 then fail("left/right 各应有 5 点") end
  ok("碰撞点组尺寸/坐标正确（front6/rear5/left5/right5）")
end

-- ============================================================
-- 2. 自由移动（无墙）：方向与位移
-- ============================================================
do
  local t = T.new{ x = 100, y = 100, rot = 0, cellScale = 50, wallHit = noWall }
  if not T.stepKeyboard(t, { forward = true }) then fail("无墙前进不应报告碰撞") end
  assertApprox(t.x, 100, 1e-9, "rot=0 前进 x 不变")
  assertApprox(t.y, 96, 1e-9, "rot=0 前进 y-4")
  ok("前进方向 = 局部前方（rot=0 → 屏幕上方，位移 4px）")
end

do
  local t = T.new{ x = 100, y = 100, rot = 0, cellScale = 50, wallHit = noWall }
  T.stepKeyboard(t, { backup = true })
  assertApprox(t.y, 102.5, 1e-9, "rot=0 后退 y+2.5")
  ok("后退位移 = 2.5px（forwardSpeed:backUpSpeed = 4:2.5）")
end

do
  local t = T.new{ x = 100, y = 100, rot = 90, cellScale = 50, wallHit = noWall }
  T.stepKeyboard(t, { forward = true })
  assertApprox(t.x, 104, 1e-9, "rot=90 前进 x+4")
  assertApprox(t.y, 100, 1e-9, "rot=90 前进 y 不变")
  ok("rot=90 前进方向 = 屏幕右方（+x），与 0° 朝上约定自洽")
end

do
  -- 前进 + 后退叠加：moveSize = 4/5 − 2.5/5 = 0.3/子步 → 合计 1.5
  local t = T.new{ x = 100, y = 100, rot = 0, cellScale = 50, wallHit = noWall }
  T.stepKeyboard(t, { forward = true, backup = true })
  assertApprox(t.y, 98.5, 1e-9, "前进+后退净位移 -1.5")
  ok("前进/后退可叠加抵消（非互斥）")
end

do
  -- 速度随 SCALE 等比缩放：cellScale=100 → forwardSpeed=8
  local t = T.new{ x = 100, y = 100, rot = 0, cellScale = 100, wallHit = noWall }
  T.stepKeyboard(t, { forward = true })
  assertApprox(t.y, 92, 1e-9, "SCALE=100 前进位移 8")
  ok("移动速度随 SCALE 等比缩放")
end

-- ============================================================
-- 3. 转向（turnSpeed = 10°/帧）
-- ============================================================
do
  local t = T.new{ x = 100, y = 100, rot = 0, cellScale = 50, wallHit = noWall }
  T.stepKeyboard(t, { turnLeft = true })
  assertApprox(t.rot, -10, 1e-9, "左转 -10°")
  ok("原地左转 10°/帧")
end
do
  local t = T.new{ x = 100, y = 100, rot = 0, cellScale = 50, wallHit = noWall }
  T.stepKeyboard(t, { turnRight = true })
  assertApprox(t.rot, 10, 1e-9, "右转 +10°")
  ok("原地右转 10°/帧")
end
do
  local t = T.new{ x = 100, y = 100, rot = 0, cellScale = 50, wallHit = noWall }
  T.stepKeyboard(t, { turnLeft = true, turnRight = true })
  assertApprox(t.rot, 0, 1e-9, "左右同时按 rot 不变")
  ok("左右转相互抵消")
end

-- ============================================================
-- 4. 朝向吸附（第 171-190 行）
-- ============================================================
do
  local t = T.new{ x = 100, y = 100, rot = 3, cellScale = 50, wallHit = noWall }
  T.stepKeyboard(t, { forward = true })
  assertApprox(t.rot, 0, 1e-9, "rot=3 应吸附到 0")
  ok("偏移 3°（< turnSpeed/2）吸附到 0°")
end
do
  local t = T.new{ x = 100, y = 100, rot = 7, cellScale = 50, wallHit = noWall }
  T.stepKeyboard(t, { forward = true })
  assertApprox(t.rot, 10, 1e-9, "rot=7 应吸附到 10")
  ok("偏移 7°（≥ turnSpeed/2）吸附到 10°")
end

-- ============================================================
-- 5. 碰撞回退（关闭平滑脱困以隔离核心逻辑）
-- ============================================================
do
  -- 墙占据 py ≤ 50 的半平面。
  -- 注意：最前的碰撞点不是车体前缘（−bh/2 = −40.5），而是炮塔前缘
  --   front[5/6].y = −turret._height/16·11 = −53.28125，×0.275 ≈ −14.65。
  -- 故中心 y 必须 > 50 + 14.65 ≈ 64.65 才算起始不碰，取 y = 66。
  local wall = function(_, py) return py <= 50 end
  local t = T.new{ x = 100, y = 66, rot = 0, cellScale = 50, wallHit = wall,
                   settingsUseSmoothCollision = false }
  local moved = T.stepKeyboard(t, { forward = true })
  if moved then fail("撞墙时 attemptToMove 应返回 false") end
  assertApprox(t.rot, 0, 1e-9, "撞墙后朝向回退")
  -- 子步推进到刚接触前的最后一个合法位置：66 − 0.8 = 65.2
  assertApprox(t.y, 65.2, 1e-6, "撞墙后停在接触前一位")
  assertApprox(t.x, 100, 1e-6, "撞墙后 x 未漂移")
  ok("撞墙回退：只推进到接触前，绝不穿入")
end

-- ============================================================
-- 6. 连续撞击 60 帧不穿透（含默认平滑脱困）
-- ============================================================
do
  local wall = function(_, py) return py <= 50 end
  local t = T.new{ x = 100, y = 66, rot = 0, cellScale = 50, wallHit = wall }
  local minY = t.y
  for _ = 1, 60 do
    T.stepKeyboard(t, { forward = true })
    if t.y < minY then minY = t.y end
  end
  -- 任一碰撞点到中心的距离上限 = 炮塔前缘半径 √(7.5²+53.28²)·0.275 ≈ 14.8，
  -- 因此中心只要 > 50 + 14.8 ≈ 64.8 就不可能穿墙；取宽松阈值 60。
  if minY < 60 then fail("坦克压入墙体，minY=" .. minY) end
  ok(string.format("连续顶墙 60 帧未穿透（minY=%.3f）", minY))
end

-- ============================================================
-- 7. hitCheck 局部→全局变换（localToGlobal 等价性）
-- ============================================================
do
  local pts = {}
  local rec = function(px, py) pts[#pts + 1] = { px, py }; return false end
  local t = T.new{ x = 200, y = 200, rot = 90, cellScale = 50, wallHit = rec }
  T.hitCheck(t, t.hitPoints.front)
  local s = t.s  -- 0.275
  -- θ=90°：gx = x − ly·s，gy = y + lx·s
  assertApprox(pts[1][1], 200 - (-40.5) * s, 1e-6, "rot=90 front[1].gx")
  assertApprox(pts[1][2], 200 + (-30.5) * s, 1e-6, "rot=90 front[1].gy")
  ok("hitCheck 局部→全局变换正确（rot=90 顺时针旋转）")
end

-- ============================================================
-- 8. expandedHitCheck 按倍数放大局部坐标
-- ============================================================
do
  local base, exp = {}, {}
  local function mk(store) return function(px, py) store[#store + 1] = { px, py }; return false end end
  local t1 = T.new{ x = 0, y = 0, rot = 0, cellScale = 50, wallHit = mk(base) }
  T.hitCheck(t1, t1.hitPoints.front)
  local t2 = T.new{ x = 0, y = 0, rot = 0, cellScale = 50, wallHit = mk(exp) }
  T.expandedHitCheck(t2, t2.hitPoints.front, 2)
  for i = 1, #base do
    assertApprox(exp[i][1], base[i][1] * 2, 1e-6, "expanded x 应为 2 倍")
    assertApprox(exp[i][2], base[i][2] * 2, 1e-6, "expanded y 应为 2 倍")
  end
  ok("expandedHitCheck 按倍数放大局部坐标（脱困判定基础）")
end

-- ============================================================
-- 9. 鼠标操控：旧方案（瞬时对准鼠标）
-- ============================================================
do
  local t = T.new{ x = 0, y = 0, rot = 0, cellScale = 50, wallHit = noWall, mouseTank = true }
  -- 鼠标在正右方 (200,0)：aimAngle = 0 → rot = 90
  T.stepMouse(t, 200, 0)
  assertApprox(t.rot, 90, 1e-6, "鼠标正右方 → rot=90")
  ok("旧鼠标操控：坦克瞬时对准鼠标（正右 → 90°）")
end

-- ============================================================
-- 9b. 鼠标操控：新方案（限速转向 / 近距倒车）
-- ============================================================
do
  -- 朝向未对齐：只限速转向（每帧 10°），不前进
  local t = T.new{ x = 0, y = 0, rot = 0, cellScale = 50, wallHit = noWall,
                   mouseTank = true, settingsUseNewMouseControl = true }
  T.stepMouse(t, 200, 0)
  assertApprox(t.rot, 10, 1e-6, "朝向偏差 90° 时每帧只转 10°")
  assertApprox(t.x, 0, 1e-9, "未对齐时不前进（x）")
  assertApprox(t.y, 0, 1e-9, "未对齐时不前进（y）")
  ok("新鼠标操控：转向受 turnSpeed 限制（不瞬时对准）")

  -- 朝向已对齐：前进
  local t2 = T.new{ x = 0, y = 0, rot = 0, cellScale = 50, wallHit = noWall,
                    mouseTank = true, settingsUseNewMouseControl = true }
  T.stepMouse(t2, 0, -200)
  assertApprox(t2.rot, 0, 1e-9, "朝向已对齐 → 不转向")
  assertApprox(t2.y, -4, 1e-6, "朝向对齐且距离足够 → 前进 4px")
  ok("新鼠标操控：朝向对齐后前进")

  -- 鼠标在背后且很近（<120）：倒车
  local t3 = T.new{ x = 0, y = 0, rot = 0, cellScale = 50, wallHit = noWall,
                    mouseTank = true, settingsUseNewMouseControl = true }
  T.stepMouse(t3, 0, 80)
  assertApprox(t3.rot, 0, 1e-9, "倒车时不额外转向")
  assertApprox(t3.y, 2.5, 1e-6, "鼠标近距在背后 → 倒车 2.5px")
  ok("新鼠标操控：近距背向鼠标时倒车")
end

-- ============================================================
-- 10. 朝向归一化（Flash `_rotation` 行为）
--     Flash 播放器会把 `_rotation` 自动归一化到 (-180,180]；我们必须在每帧移动结束后同样归一化，
--     否则 |rot| 无限累加，会让原版 AI 的「按角度差判断转向」全部失效（原地打转 / 撞墙）。
-- ============================================================
do
  local t = T.new{ x = 0, y = 0, rot = 0, cellScale = 50, wallHit = noWall }
  local maxAbs = 0
  for _ = 1, 200 do
    T.stepKeyboard(t, { turnRight = true })   -- 每帧 +10°，200 帧 = +2000°
    if math.abs(t.rot) > maxAbs then maxAbs = math.abs(t.rot) end
  end
  if maxAbs > 180 then
    fail(string.format("连续转向 200 帧后 |rot| 仍应 ≤180，实际最大 %.6f", maxAbs))
  end
  ok("连续转向 200 帧（累计 2000°）rot 仍归一化在 (-180,180]")
end

do
  local t = T.new{ x = 0, y = 0, rot = 0, cellScale = 50, wallHit = noWall }
  T.stepKeyboard(t, { turnLeft = true })
  assertApprox(t.rot, -10, 1e-9, "从 0 左转一帧 → -10（不因取模变 350）")
  local t2 = T.new{ x = 0, y = 0, rot = 0, cellScale = 50, wallHit = noWall }
  for _ = 1, 18 do T.stepKeyboard(t2, { turnLeft = true }) end   -- -180
  assertApprox(t2.rot, 180, 1e-9, "-180 归一化为 180（与 Flash 一致）")
  local t3 = T.new{ x = 0, y = 0, rot = 350, cellScale = 50, wallHit = noWall }
  assertApprox(t3.rot, -10, 1e-9, "初始 350 归一化为 -10")
  ok("归一化边界正确（-180→180、350→-10）")
end

do
  local bad = false
  for _ = 1, 2000 do
    local r = T.randomRotation()
    if r <= -180 or r > 180 then bad = true; break end
  end
  if bad then fail("randomRotation 未归一化到 (-180,180]") end
  ok("随机初始朝向也已归一化（原版 0..350 → Flash 读回 (-180,180]）")
end

print("\n全部通过。")