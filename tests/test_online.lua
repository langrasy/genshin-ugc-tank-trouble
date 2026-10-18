--[[ 联机同步（src/online.lua）自测：快照编解码 / 插值采样 / 事件编解码 ]]
package.path = package.path .. ";./?.lua"

local O = require("src.online")

---@noreturn
local function fail(msg) print("[FAIL] " .. msg); os.exit(1) end
local function ok(msg) print("[ok] " .. msg) end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

-- 1. 武器 id 映射（未知名退回 bullet）
if O.weaponId("laser") ~= O.weaponId("laser") then fail("weaponId 不稳定") end
if O.weaponName(O.weaponId("mine")) ~= "mine" then fail("武器名往返失败") end
if O.weaponName(O.weaponId("不存在")) ~= "bullet" then fail("未知武器应退回 bullet") end
ok("武器 id 映射正确（未知退回 bullet）")

-- 2. 快照编解码（定点 ×10 往返 + 四舍五入）
local l = O.encodeSnap(2, 123.46, -7.12, 350.04, O.weaponId("remote"), true)
if #l ~= O.SNAP_N then fail("快照长度应为 " .. O.SNAP_N) end
local s = O.decodeSnaps(l)[1]
if s.slot ~= 2 then fail("slot 丢失") end
if not near(s.x, 123.5, 0.06) then fail("x 往返误差过大: " .. tostring(s.x)) end
if not near(s.y, -7.1, 0.06) then fail("y 往返误差过大: " .. tostring(s.y)) end
if s.weaponId ~= O.weaponId("remote") then fail("武器 id 丢失") end
if s.alive ~= true then fail("alive 丢失") end
ok("快照编解码往返正确（0.1 精度）")

-- 3. 多条快照拼接解码；尾部长出的零头忽略
local both = {}
for i = 1, #l do both[i] = l[i] end
local l2 = O.encodeSnap(1, 10, 20, 0, O.weaponId("bullet"), false)
for i = 1, #l2 do both[#both + 1] = l2[i] end
both[#both + 1] = 999   -- 零头
local ds = O.decodeSnaps(both)
if #ds ~= 2 then fail("应解出 2 条快照，实为 " .. #ds) end
if ds[2].slot ~= 1 or ds[2].alive ~= false then fail("第 2 条快照字段错误") end
if #O.decodeSnaps("x") ~= 0 then fail("非表输入应返回空") end
ok("多条快照拼接解码正确（忽略零头）")

-- 4. 角度最短差
if O.shortestDelta(350, 10) ~= 20 then fail("350→10 应为 +20") end
if O.shortestDelta(10, 350) ~= -20 then fail("10→350 应为 -20") end
if O.shortestDelta(0, 180) ~= 180 then fail("0→180 应为 180") end
ok("角度最短差正确")

-- 5. lerp：位置线性 + 角度走最短弧
local a = { slot = 1, x = 0, y = 0, rot = 350, weaponId = 1, alive = true }
local b = { slot = 1, x = 10, y = -10, rot = 10, weaponId = 2, alive = true }
local m = O.lerp(a, b, 0.5)
if not near(m.x, 5) or not near(m.y, -5) then fail("位置插值错误") end
if not near(m.rot, 0) then fail("角度应走最短弧并归一化（350→10 中点 = 0），实为 " .. tostring(m.rot)) end
if O.lerp(a, b, 0.25).weaponId ~= 1 or O.lerp(a, b, 0.75).weaponId ~= 2 then
  fail("武器应取较近的一端")
end
ok("lerp 位置插值 + 角度最短弧正确")

-- 6. 插值采样：单样本 / 越界取端 / 中点插值
local buf = O.newBuffer()
O.push(buf, 10.0, O.decodeSnaps(O.encodeSnap(1, 0, 0, 0, 1, true)))
if O.sample(buf, 2, 10.5, 0) ~= nil then fail("未收到的 slot 不应有样本") end
local only = O.sample(buf, 1, 10.5, 1.0)
if only == nil then fail("单样本应可采样") end
O.push(buf, 10.2, O.decodeSnaps(O.encodeSnap(1, 100, 0, 0, 1, true)))
-- 渲染时间 = now − delay；取 now=10.2 delay=0 ⇒ 落在 10.2（最新）
local latest = O.sample(buf, 1, 10.2, 0) or { x = -999 }
if not near(latest.x, 100) then fail("最新样本应取 x=100，实为 " .. tostring(latest.x)) end
-- delay=0.1 ⇒ 渲染时间 10.1 ⇒ 介于 10.0(0) 与 10.2(100) 之间 ⇒ x=50
local mid = O.sample(buf, 1, 10.2, 0.1) or { x = -999 }
if not near(mid.x, 50, 0.01) then fail("中点插值应 ~50，实为 " .. tostring(mid.x)) end
-- 越界（很晚）⇒ 取最后一个
local last = O.sample(buf, 1, 99, 0) or { x = -999 }
if not near(last.x, 100) then fail("越界应取最后样本") end
ok("插值采样（单样本 / 中点 / 越界）正确")

-- 7. 缓冲上限：只保留最近 KEEP 个样本
local buf2 = O.newBuffer()
for i = 1, O.KEEP + 5 do
  O.push(buf2, i * 0.1, O.decodeSnaps(O.encodeSnap(3, i, 0, 0, 1, true)))
end
if #buf2.st[3].t > O.KEEP then fail("缓冲未按上限裁剪（" .. #buf2.st[3].t .. "）") end
ok("插值缓冲按上限裁剪")

-- 8. 事件编解码
local e = O.decodeEvent(O.encodeEvent(O.EV.HIT, 1, 2, 0, 0))
if e == nil or e.kind ~= O.EV.HIT or e.slot ~= 1 or e.a ~= 2 then fail("事件往返错误") end
if O.decodeEvent({ 1 }) ~= nil then fail("过短事件应返回 nil") end
if O.decodeEvent(nil) ~= nil then fail("nil 事件应返回 nil") end
ok("事件编解码正确")

-- 快照变量名**按槽位区分**（共用一个变量会被两端互相覆盖）
if O.snapVar(1) ~= "TT2_SNAP_1" then fail("槽位 1 的快照变量应为 TT2_SNAP_1") end
if O.snapVar(2) ~= "TT2_SNAP_2" then fail("槽位 2 的快照变量应为 TT2_SNAP_2") end
ok("快照变量按槽位区分（TT2_SNAP_1 / TT2_SNAP_2）")

-- 迷宫表：表首项 = 回合号 seq；下标口径必须与 game.lua 一致
--   [seq, W, H, sx, sy, <(W+1)*(H+1) 个熵>, <每辆坦克 1 个朝向档>]
local mt = { 7, 2, 3, 1, 0 }              -- seq=7, W=2, H=3, sx=1, sy=0
for i = 1, (2 + 1) * (3 + 1) do mt[#mt + 1] = i % 4 end
for i = 1, 2 do mt[#mt + 1] = 10 * i end
if O.mazeSeq(mt) ~= 7 then fail("mazeSeq 读错：" .. tostring(O.mazeSeq(mt))) end
local w, h, sx, sy = O.mazeHead(mt)
if w ~= 2 or h ~= 3 or sx ~= 1 or sy ~= 0 then fail("mazeHead 读错") end
if O.MAZE_HEAD ~= 5 or O.MAZE_I0 ~= 6 then fail("MAZE_HEAD/MAZE_I0 常量错") end
if O.mazeRotBase(mt) ~= 6 + 12 then fail("mazeRotBase 错：" .. tostring(O.mazeRotBase(mt))) end
if O.mazeSeq(mt) ~= 0 and O.mazeSeq({ 1, 2 }) ~= 0 then fail("非法表应返回 seq=0") end
if O.mazeHead({ 1, 2 }) ~= nil then fail("非法表 mazeHead 应返回 nil") end
ok("迷宫表：seq 表头 / 下标口径 / 朝向基址一致")

-- 补给箱表：每 4 个一组 [crateId, cellX, cellY, weaponId]
local raw = O.encodeCrates({
  { id = 1, cx = 3, cy = 4, weaponId = 2 },
  { id = 2, cx = 5, cy = 6, weaponId = 5 },
})
if #raw ~= 8 or raw[1] ~= 1 or raw[6] ~= 5 or raw[8] ~= 5 then fail("encodeCrates 打包错") end
local back = O.decodeCrates(raw)
if #back ~= 2 or back[2].id ~= 2 or back[2].cx ~= 5 or back[2].cy ~= 6 or back[2].weaponId ~= 5 then
  fail("decodeCrates 解包错")
end
if #O.decodeCrates({}) ~= 0 then fail("空表应解出 0 个箱子") end
if #O.encodeCrates(nil) ~= 0 then fail("nil 应编成空表") end
ok("补给箱表编解码正确（格子坐标 + 武器 id）")

-- 准备档：4 个一组 [ready, colorIdx, ctrlKind, endBeat]
--   endBeat = 房主发布的「强制准备时刻」= 届时 TT2_BEAT 的值（两端据此算同一个倒计时）
local rd = O.encodeReady(true, 3, O.CTRL_PAD, 130)
if #rd ~= O.READY_N or rd[1] ~= 1 or rd[2] ~= 3 or rd[3] ~= 2 or rd[4] ~= 130 then
  fail("encodeReady 打包错：" .. table.concat(rd, ","))
end
local rb = O.decodeReady(rd)
if rb == nil or rb.ready ~= true or rb.color ~= 3 or rb.ctrl ~= O.CTRL_PAD or rb.endBeat ~= 130 then
  fail("decodeReady 解包错")
end
if O.decodeReady({ 0, 0 }) ~= nil then fail("长度不足应返回 nil") end
local rd0 = O.decodeReady(O.encodeReady(false, 0, O.CTRL_TOUCH, 0))
if rd0 == nil or rd0.ready ~= false or rd0.color ~= 0 or rd0.ctrl ~= O.CTRL_TOUCH or rd0.endBeat ~= 0 then
  fail("未准备档解包错（endBeat 应为 0）")
end
if O.readyVar(1) ~= "TT2_READY_1" or O.readyVar(2) ~= "TT2_READY_2" then fail("readyVar 槽位映射错") end
ok("准备档编解码正确（ready / 颜色 / 控制方式 / 强制准备时刻 endBeat）")

print("\n全部通过。")
