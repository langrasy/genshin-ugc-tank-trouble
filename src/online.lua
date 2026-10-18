--[[ 坦克动荡2 —— 联机同步（纯逻辑，可脱机单测）

  职责（不碰渲染 / 不碰网络 API —— 收发与渲染由平台层负责）：
    ① **快照**编解码：把某玩家的位置/朝向/武器/存活压成**整数列表**（wire 格式，避免浮点序列化问题）；
    ② **插值缓冲**：按到达时间建时间线，按「渲染时间 = now − delay」线性插值采样（角度走最短弧）；
    ③ **事件**编解码：开火 / 命中 / 拾取 / 阵亡 / 布雷（离散事件，即时发送不合并）。

  ── wire 格式（编辑器侧节点图必须按此实现）────────────────────────────
  · **上行**：`TT2_SNAP` 信号（客户端 → 服务器），参数 = 该客户端的 1 条快照（整数列表，长度 6）：
        [slot, x*10, y*10, rot*10, weaponId, flags]
        · x/y = 世界像素 ×10（四舍五入取整）；rot = 度 ×10；weaponId 见下表；flags bit0 = 存活
  · **下行**：`TT2_SNAP` **关卡自定义变量**（整数列表）= 服务器汇总的**所有玩家**快照，按 6 个一组拼接：
        [ slot1, x1*10, y1*10, rot1*10, w1, f1,  slot2, x2*10, ... ]
        客户端每帧读该变量 → 解码 → 推入缓冲 → 插值渲染对手。
  · **事件**：`TT2_EVENT` 信号，参数 = 整数列表 [kind, slot, a, b, c, d]，kind 见 O.EV。
  · 复用信号：`TT2_LEAVE`（逃跑）/ `TT2_MAZE`（迷宫表）/ `TT2_PING`（延迟）/ `TT2_HELLO`（重连全量请求）。

  时间基准：平台层传入自己的单调秒表（`audioClock`），本模块只做相对插值，不依赖平台时钟 API。
]]

local floor = math.floor

local O = {}

-- ============================================================
-- 武器 id 映射（快照里用整数表示当前武器）
-- ============================================================
O.WEAPONS = {
  "bullet", "laser", "frag", "gatling", "homing",
  "deathRay", "mine", "remote", "electric",
}
local WID, WNAME = {}, {}
for i = 1, #O.WEAPONS do
  WID[O.WEAPONS[i]] = i
  WNAME[i] = O.WEAPONS[i]
end

function O.weaponId(name) return WID[name] or 1 end
function O.weaponName(id) return WNAME[id] or "bullet" end

-- ============================================================
-- ① 快照
-- ============================================================
O.SNAP_N = 6            -- 每条快照的整数个数
O.K = 10                -- x/y/rot 的定点倍率（0.1 精度足够）
O.F_ALIVE = 1           -- flags bit0

-- ⚠️ 快照**按槽位分信号/变量**（TT2_SNAP_1 / TT2_SNAP_2）：共用一个变量会被两端互相覆盖。
local function snapVar(slot) return "TT2_SNAP_" .. ((tonumber(slot) == 2) and "2" or "1") end
O.snapVar = snapVar

-- 打包一条快照 → 整数列表（长度 6）
function O.encodeSnap(slot, x, y, rot, weaponId, alive)
  return {
    floor((slot or 1)),
    floor((x or 0) * O.K + 0.5),
    floor((y or 0) * O.K + 0.5),
    floor((rot or 0) * O.K + 0.5),
    floor((weaponId or 1)),
    alive and O.F_ALIVE or 0,
  }
end

-- 解包整数列表 → { {slot,x,y,rot,weaponId,alive}, ... }（每 SNAP_N 个一组）
function O.decodeSnaps(list)
  local out = {}
  if type(list) ~= "table" then return out end
  local n = floor(#list / O.SNAP_N)
  for i = 1, n do
    local b = (i - 1) * O.SNAP_N
    out[#out + 1] = {
      slot = list[b + 1],
      x = (list[b + 2] or 0) / O.K,
      y = (list[b + 3] or 0) / O.K,
      rot = (list[b + 4] or 0) / O.K,
      weaponId = list[b + 5] or 1,
      alive = (((list[b + 6] or 0) % 2) == 1),
    }
  end
  return out
end

-- ============================================================
-- ② 插值缓冲
-- ============================================================
O.KEEP = 8              -- 每个 slot 只保留最近 N 个样本

function O.newBuffer()
  return { st = {} }    -- st[slot] = { t = {...}, s = {...} }
end

-- 收到一批快照：按 nowSec 追加到各自 slot 的时间线
function O.push(buf, nowSec, snaps)
  if buf == nil or snaps == nil then return end
  for i = 1, #snaps do
    local s = snaps[i]
    local q = buf.st[s.slot]
    if q == nil then q = { t = {}, s = {} }; buf.st[s.slot] = q end
    q.t[#q.t + 1] = nowSec
    q.s[#q.s + 1] = s
    while #q.t > O.KEEP do
      table.remove(q.t, 1)
      table.remove(q.s, 1)
    end
  end
end

-- 角度最短差（from → to，落在 (-180, 180]）
function O.shortestDelta(from, to)
  local d = (to - from) % 360
  if d > 180 then d = d - 360 end
  return d
end

-- 角度归一化到 (-180, 180]（与 tank.normalizeRot 同约定；插值结果必须归一化）
function O.normalizeRot(a)
  a = a % 360
  if a > 180 then a = a - 360 end
  return a
end

-- 两条快照按系数 f∈[0,1] 线性插值（角度走最短弧并归一化；武器取较近的一端；存活取较新的）
function O.lerp(a, b, f)
  return {
    slot = a.slot,
    x = a.x + (b.x - a.x) * f,
    y = a.y + (b.y - a.y) * f,
    rot = O.normalizeRot(a.rot + O.shortestDelta(a.rot, b.rot) * f),
    weaponId = (f < 0.5) and a.weaponId or b.weaponId,
    alive = b.alive,
  }
end

-- 按「渲染时间 = nowSec − delaySec」在 slot 的时间线上采样；样本不足/越界时取最近端
function O.sample(buf, slot, nowSec, delaySec)
  if buf == nil then return nil end
  local q = buf.st[slot]
  if q == nil or #q.t == 0 then return nil end
  local rt = nowSec - (delaySec or 0)
  local n = #q.t
  if n == 1 or rt <= q.t[1] then return q.s[1] end
  if rt >= q.t[n] then return q.s[n] end
  for i = 2, n do
    if q.t[i] >= rt then
      local t0, t1 = q.t[i - 1], q.t[i]
      local f = (t1 > t0) and ((rt - t0) / (t1 - t0)) or 0
      if f < 0 then f = 0 elseif f > 1 then f = 1 end
      return O.lerp(q.s[i - 1], q.s[i], f)
    end
  end
  return q.s[n]
end

-- ============================================================
-- ③ 离散事件
-- ============================================================
O.EV = {
  FIRE = 1,   -- [FIRE, slot, rot*10, weaponId]           开火（朝向 + 武器）
  HIT  = 2,   -- [HIT,  fromSlot, toSlot]                  我命中了谁（受害者权威：先由命中方声明）
  PICK = 3,   -- [PICK, slot, crateId, weaponId]           拾取补给箱（crateId 用于让两端删掉**同一个**箱子）
  DIED = 4,   -- [DIED, slot]                              阵亡
  MINE = 5,   -- [MINE, slot, x*10, y*10]                  布雷
}

-- 打包事件 → 整数列表
function O.encodeEvent(kind, slot, a, b, c)
  return {
    floor(kind), floor(slot or 1),
    floor((a or 0)), floor((b or 0)), floor((c or 0)),
  }
end

-- 解包事件 → { kind, slot, a, b, c }（不足则 nil）
function O.decodeEvent(list)
  if type(list) ~= "table" or #list < 2 then return nil end
  return {
    kind = list[1], slot = list[2],
    a = list[3] or 0, b = list[4] or 0, c = list[5] or 0,
  }
end

-- ============================================================
-- ④ 迷宫表（房主权威，走关卡变量 TT2_MAZE）
--   表结构 = [seq, W, H, sx, sy, <(W+1)*(H+1) 个 0..3 格点熵>, <每辆坦克 1 个朝向档 0..35>]
--   `seq` = 该表所属**回合号**（房主自增）。**回合号与表装在同一个原子单元里** ⇒
--   非房主据此判断「该重开一回合了」，不会出现「号到了表没到」的错配。
-- ============================================================
O.MAZE_SEQ = 1          -- 表首项 = 回合号
O.MAZE_HEAD = 5         -- 表头长度：[seq, W, H, sx, sy]
O.MAZE_I0 = 6           -- 格点熵从第 6 项开始（createMazeFromInts 的 i0）

-- 读一张迷宫表的回合号；不是合法表则返回 0
function O.mazeSeq(list)
  if type(list) ~= "table" or #list < O.MAZE_HEAD then return 0 end
  return tonumber(list[O.MAZE_SEQ]) or 0
end

-- 读表头 W, H, sx, sy；不合法返回 nil
function O.mazeHead(list)
  if type(list) ~= "table" or #list < O.MAZE_HEAD then return nil end
  return tonumber(list[2]) or 0, tonumber(list[3]) or 0, tonumber(list[4]) or 0, tonumber(list[5]) or 0
end

-- 朝向档的起始下标（必须与 platform/game.lua 的 assignTanksToCells 一致）
function O.mazeRotBase(list)
  local W, H = O.mazeHead(list)
  if W == nil then return nil end
  return O.MAZE_HEAD + 1 + (W + 1) * (H + 1)
end

-- ============================================================
-- ⑤ 补给箱表（房主权威，走关卡变量 TT2_CRATE）
--   补给箱是**持续状态**（一直在场上直到被捡）⇒ 必须走变量（丢包自愈 / 重连恢复），
--   不能走一次性信号事件。
--   表结构 = [crateId, cellX, cellY, weaponId] × N（N=0 = 场上无箱）
--   ⚠️ 用**格子坐标**而不是像素：与 SCALE 无关 ⇒ 两端必然落在同一格。
-- ============================================================
O.CRATE_N = 4

-- crates = { { id=, cx=, cy=, weaponId= }, ... } → 整数列表
function O.encodeCrates(crates)
  local out = {}
  if type(crates) ~= "table" then return out end
  for i = 1, #crates do
    local c = crates[i]
    if c ~= nil and c.id ~= nil then
      out[#out + 1] = floor(c.id)
      out[#out + 1] = floor(c.cx or 0)
      out[#out + 1] = floor(c.cy or 0)
      out[#out + 1] = floor(c.weaponId or 1)
    end
  end
  return out
end

-- 整数列表 → { { id, cx, cy, weaponId }, ... }
function O.decodeCrates(list)
  local out = {}
  if type(list) ~= "table" then return out end
  local n = floor(#list / O.CRATE_N)
  for i = 1, n do
    local b = (i - 1) * O.CRATE_N
    out[#out + 1] = {
      id = list[b + 1],
      cx = list[b + 2],
      cy = list[b + 3],
      weaponId = list[b + 4],
    }
  end
  return out
end

-- ============================================================
-- ⑥ 准备档（联机准备界面，走同名关卡变量 TT2_READY_1 / TT2_READY_2）
--   准备是**持续状态**（一旦确认就不再变）⇒ 走变量（丢包自愈 / 重连恢复），与快照 / 补给箱同一判据。
--   表结构 = [ready, colorIdx, ctrlKind, endBeat]
--     · ready    0/1   该玩家是否已按开火键确认准备
--     · colorIdx 1..4  选定颜色（0 = 未选）
--     · ctrlKind 1/2/3 1=键盘 2=手柄 3=触屏 —— 供**对面**把这块准备框画成对应样式
--     · endBeat  整数  **仅房主（槽位 1）**写：本准备阶段的「**强制准备时刻**」= 届时 `TT2_BEAT` 的值
--                      （0 = 房主还没定）。
--   ⚠️ 为什么要 beat 而不是各自倒计时：**30 秒倒计时必须两端同步**（用户 2026-10-15）。
--      各自本地跑 30 秒 ⇒ 两端进准备页的时刻不同（`TT2_PLAYERS` 每秒才更新一次）⇒ 到点能差 ~1 秒。
--      改成「两端都用 `endBeat − 当前 TT2_BEAT`」⇒ 同一个心跳报文算出的剩余秒数**逐秒一致**，
--      到点也落在**同一个心跳刻** ⇒ **所有人同时强制准备、同时进 3 秒开始倒计时**（只差一帧 + 传播延迟）。
-- ============================================================
O.READY_N = 4
O.CTRL_KB, O.CTRL_PAD, O.CTRL_TOUCH = 1, 2, 3

-- 准备变量名（与信号同名，同快照：上行走信号、下行走关卡变量）
local function readyVar(slot) return "TT2_READY_" .. ((tonumber(slot) == 2) and "2" or "1") end
O.readyVar = readyVar

function O.encodeReady(ready, colorIdx, ctrlKind, endBeat)
  return {
    ready and 1 or 0,
    floor(colorIdx or 0),
    floor(ctrlKind or O.CTRL_KB),
    floor(endBeat or 0),
  }
end

-- 解码 → { ready=bool, color=数(0=未选), ctrl=数, endBeat=数(0=未定) }；不合法返回 nil
function O.decodeReady(list)
  if type(list) ~= "table" or #list < O.READY_N then return nil end
  return {
    ready   = (tonumber(list[1]) or 0) ~= 0,
    color   = floor(tonumber(list[2]) or 0),
    ctrl    = floor(tonumber(list[3]) or O.CTRL_KB),
    endBeat = floor(tonumber(list[4]) or 0),
  }
end

return O
