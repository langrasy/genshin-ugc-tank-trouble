--[[ 坦克动荡2 —— 服务器信号层（纯逻辑，可脱机单测）
     职责：把 game.ServerSignal / Script:RegisterServerSignalHandler 包装成
           与具体 API 解耦的打包/发送/分发层。
     平台层在 OnStart 时调用 N.bind(adapter) 注入真实实现。
     adapter = {
       server = function(name) -> signal对象 end,  -- signal 需具备 Add*/SendSignal
     }
     信号名需与编辑器「发送客户端脚本信号 / 服务器脚本信号」节点约定一致。 ]]

local N = {}

-- 信号名常量（编辑器节点图必须使用同名）
N.SIG = {
  ROUND = "TT2_ROUND",   -- 客户端 → 服务器：回合累计上报
  ACH   = "TT2_ACH",     -- 客户端 → 服务器：成就达成上报
  MATCH = "TT2_MATCH",   -- 客户端 → 服务器：整场结束上报
  LEAVE = "TT2_LEAVE",   -- 服务器 → 客户端：某玩家逃跑/离开战场（→ 该玩家判负，对方胜利）
  DONE  = "TT2_DONE",    -- 客户端 → 服务器：单机完成一场（编辑器侧据「结算关卡」结算）
  -- 客户端 → 服务器：**把「发信号的那个玩家」的结算状态设为 胜利 / 失败**（都**无参数**、都**不结束游戏**）
  --   为什么需要（用户 2026-10-15 定的结算规则）：
  --     · **单机**：任意玩一局，无论模式 / 无论输赢，退出都算「已完成」⇒ 进局时发 SET_WIN（预置「胜利」）；
  --     · **联机**：一方**逃跑** ⇒ 他判**失败**、另一方**胜利**；双方都没逃 ⇒ 按比赛规则判胜负。
  --       故进局时**预置「失败」**（SET_LOSE）；等分出胜负时，**各端各自**把自己的最终状态报上去：
  --       赢的一方发 SET_WIN、输的一方发 SET_LOSE ⇒ 服务器只需「监听信号 → 设置(信号来源实体, 状态)」，
  --       **不需要按槽位去找玩家**（逃跑者已离场、且列表索引不可靠）。
  --   官方依据：《关卡结算》二「结算状态在游玩过程中**动态修改**，调用结算关卡后按各玩家**当前**状态结算」、
  --   「**未定**」是默认状态（不预置 ⇒ 中途退出按"未定"结算 ⇒ 拿不到奖励）；
  --   《试玩》§3「玩家可通过完成挑战**或者主动退出**来触发关卡结算」。
  --   ⚠️ 这两条流程里**不要**接【结算关卡】（那会立刻结束游戏）——只有 `TT2_DONE` 才结束单机本局。
  SET_WIN  = "TT2_SET_WIN",   -- 上行「胜利」：**1 个整数参数 = 本机玩家序号**（单机进局预置 / 联机我赢时）
  SET_LOSE = "TT2_SET_LOSE",  -- 上行「失败」：**1 个整数参数 = 本机玩家序号**（联机我输时）
  -- 把**逃跑合法性设为「否」**：**1 个整数参数 = 本机玩家序号**（联机进局预置）⇒ 我若中途离开，平台判我「逃跑状态」。
  --   ⚠️ 与 SET_WIN / SET_LOSE 的关系：那两条链会把合法性设回「是」并给胜负 ⇒ 正常打完仍是胜负，
  --      只有「还没分出胜负就离开」才会落到「逃跑」。
  --   ⚠️ 为什么要带序号：信号是**全局广播**，官方「信号来源实体」只对【发送信号】**节点**成立；
  --      Lua 客户端发的信号没有发送实体 ⇒ 服务器只能靠参数里的序号定位玩家（见 联机节点图连法.html 图 13）。
  ESCAPE   = "TT2_SET_ESCAPE",
  -- 请求服务器**立刻结算关卡**（联机分出胜负后由房主发；各端已先把自己的最终状态报上去）。
  SETTLE   = "TT2_SETTLE",
  PING  = "TT2_PING",    -- 客户端 → 服务器 → 客户端：延迟探测（服务器须把参数**原样回发**）
  -- ⚠️ 快照**按槽位分成两个信号/两个变量**：单变量会被两端**互相覆盖**（各端只能拿到对方一半样本）。
  SNAP1 = "TT2_SNAP_1",  -- 客户端(槽位1) → 服务器：本机快照（整数列表）；下行走**同名关卡变量** TT2_SNAP_1
  SNAP2 = "TT2_SNAP_2",  -- 客户端(槽位2) → 服务器：本机快照（整数列表）；下行走**同名关卡变量** TT2_SNAP_2
  EVENT = "TT2_EVENT",   -- 客户端 ⇄ 服务器：离散事件（开火/命中/拾取/阵亡/布雷，整数列表）
  HELLO = "TT2_HELLO",   -- 客户端 → 服务器：进场/重连，请求下发全量（快照变量 + 比分）
  SLOT  = "TT2_SLOT",    -- 服务器 → 客户端：逐个告诉每个玩家「你是几号」（参数 = 玩家序号，1 基）
  MAZE_UP = "TT2_MAZE_UP", -- 客户端(房主) → 服务器：**整张迷宫表**（整数列表）；服务器原样写进关卡变量 TT2_MAZE
  CRATE_UP = "TT2_CRATE_UP", -- 客户端(房主) → 服务器：**整张补给箱表**（整数列表）；服务器原样写进关卡变量 TT2_CRATE
  MATCH_UP = "TT2_MATCH_UP", -- 客户端(房主) → 服务器：**本局胜者槽位**（整数，0=未结束）；服务器原样写进关卡变量 TT2_WINNER
  -- ⚠️ 准备档也**按槽位分成两个信号/两个变量**（同 SNAP 理由：共用一个变量会被两端互相覆盖）。
  --   表结构 = [ready(0/1), colorIdx(0=未选), ctrlKind(1键盘/2手柄/3触屏), started(0/1，仅房主写)]
  READY1 = "TT2_READY_1", -- 客户端(槽位1) → 服务器：本机准备档（整数列表）；下行走**同名关卡变量** TT2_READY_1
  READY2 = "TT2_READY_2", -- 客户端(槽位2) → 服务器：同上
}

-- 延迟探测：上报一个时间戳，服务器原样回发后由客户端算往返时间
function N.reportPing(t)
  return N.emit(N.SIG.PING, { { t = "float", v = t or 0 } })
end

-- 上行：本机快照（整数列表，见 src/online.lua 的 wire 格式）
--   ⚠️ **按槽位选信号**：槽位 1 发 TT2_SNAP_1、槽位 2 发 TT2_SNAP_2
--   （若共用一个信号，服务端只能写同一个变量 ⇒ 两端互相覆盖，各端只能拿到对方一半样本）。
function N.reportSnap(slot, list)
  local name = (tonumber(slot) == 2) and N.SIG.SNAP2 or N.SIG.SNAP1
  return N.emit(name, { { t = "intlist", v = list or {} } })
end

-- 上行：本机「准备档」（整数列表，见 src/online.lua 的 wire 格式）
--   ⚠️ **按槽位选信号**：槽位 1 发 TT2_READY_1、槽位 2 发 TT2_READY_2
--   （共用一个信号会被两端互相覆盖；服务端只需「监听 → 原样写真名关卡变量」）。
function N.reportReady(slot, list)
  local name = (tonumber(slot) == 2) and N.SIG.READY2 or N.SIG.READY1
  return N.emit(name, { { t = "intlist", v = list or {} } })
end

-- 上行/下行：离散事件（整数列表）
function N.reportEvent(list)
  return N.emit(N.SIG.EVENT, { { t = "intlist", v = list or {} } })
end

-- 进场 / 重连：请求服务器下发全量
function N.reportHello()
  return N.emit(N.SIG.HELLO, {})
end

-- 上行（**联机房主**）：上传整张迷宫表（整数列表）
--   表结构 = [seq, W, H, sx, sy, <(W+1)*(H+1) 个 0..3 格点熵>, <每辆坦克 1 个朝向档 0..35>]
--   `seq` = 该表所属的**回合号**（房主自增）⇒ 回合号与该回合的表**装在同一个原子单元里**，
--   不会出现「号到了表没到」⇒ 非房主据此判定「该重开一回合了」。
--   服务器侧只需「监听信号 TT2_MAZE_UP → 设置自定义变量 TT2_MAZE ← 参数_1」原样落地。
function N.reportMazeUp(list)
  return N.emit(N.SIG.MAZE_UP, { { t = "intlist", v = list or {} } })
end

-- 上行（**联机房主**）：上传整张补给箱表（整数列表）
--   表结构 = [crateId, cellX, cellY, weaponId] × N（N=0 = 场上无箱）
--   服务器侧只需「监听信号 TT2_CRATE_UP → 设置自定义变量 TT2_CRATE ← 参数_1」原样落地。
--   ⚠️ 补给箱是**持续状态**（一直在场上直到被捡）⇒ 必须走变量（丢包自愈 / 重连恢复），不能走一次性事件。
function N.reportCrates(list)
  return N.emit(N.SIG.CRATE_UP, { { t = "intlist", v = list or {} } })
end

-- 上行（**联机房主**）：上报本局胜者槽位（0 = 本局尚未结束）
--   服务器侧只需「监听信号 TT2_MATCH_UP → 设置自定义变量 TT2_WINNER ← 参数_1」原样落地。
function N.reportWinner(slot)
  return N.emit(N.SIG.MATCH_UP, { { t = "int", v = tonumber(slot) or 0 } })
end

-- 单机完成一场：上报，供编辑器侧节点图接「设置玩家结算成功状态」+「结算关卡」
function N.reportDone()
  return N.emit(N.SIG.DONE, {})
end

-- 上行：把**本机玩家**的结算状态设为「胜利」（单机进局预置 / 联机自己赢时）
--   ⚠️ 必须带**本机玩家序号（1 基）**：信号是全局广播、**没有「信号来源实体」**
--   （官方：该出参只对【发送信号】**节点**成立，Lua `game.ServerSignal()` 发的信号没有发送实体）
--   ⇒ 服务器只能靠这个参数去定位「是谁」。
function N.reportSetWin(idx)
  return N.emit(N.SIG.SET_WIN, { { t = "int", v = idx or 1 } })
end

-- 上行：把**本机玩家**的结算状态设为「失败」（联机自己输时）
function N.reportSetLose(idx)
  return N.emit(N.SIG.SET_LOSE, { { t = "int", v = idx or 1 } })
end

-- 上行：把**本机玩家**的「逃跑合法性」设为**否**（联机进局预置）。
--   语义：此后该玩家若**中途离开关卡**，平台按《关卡结算》二「逃跑合法性为否 ⇒ 结算状态一律为逃跑状态」
--   判「逃跑」；正常打完时由 reportSetWin / reportSetLose 把合法性改回「是」并给出胜负。
function N.reportSetEscape(idx)
  return N.emit(N.SIG.ESCAPE, { { t = "int", v = idx or 1 } })
end

-- 上行：请求服务器**立刻结算关卡**（联机分出胜负后由房主发；见 platform/game.lua 的 settleIn）。
function N.reportSettle()
  return N.emit(N.SIG.SETTLE, {})
end

local ADD = {
  int    = "AddInt",
  float  = "AddFloat",
  string = "AddString",
  bool   = "AddBool",
  intlist = "AddIntList",
}

local adapter = nil
local handlers = {}

function N.bind(a)
  adapter = a
  handlers = {}
end

-- 把 { {t=,v=}, ... } 写入信号对象；返回成功与否
function N.pack(sig, params)
  for i = 1, #params do
    local p = params[i]
    local m = ADD[p.t]
    if m == nil then return false end
    sig[m](sig, p.v)
  end
  return true
end

function N.emit(name, params)
  if adapter == nil then return false end
  local sig = adapter.server(name)
  if sig == nil then return false end
  -- 参数数量/类型与「信号管理器」里声明的对不上时，Add* 可能抛错 ⇒ 包一层，让它安全失败而不是炸整个帧
  local ok, packed = pcall(N.pack, sig, params or {})
  if not ok or packed ~= true then return false end
  sig:SendSignal()
  return true
end

function N.on(name, cb)
  handlers[name] = cb
end

function N.dispatch(name, ...)
  local cb = handlers[name]
  if cb == nil then return false end
  cb(...)
  return true
end

-- 便捷上报：回合累计
function N.reportRound(s)
  return N.emit(N.SIG.ROUND, {
    { t = "int", v = s.rounds or 0 },
    { t = "int", v = s.victories or 0 },
    { t = "int", v = s.kills or 0 },
    { t = "int", v = s.deaths or 0 },
  })
end

-- 便捷上报：单条成就
function N.reportAchievement(id)
  return N.emit(N.SIG.ACH, { { t = "int", v = id } })
end

-- 便捷上报：整场结束
function N.reportMatch(s)
  return N.emit(N.SIG.MATCH, {
    { t = "int", v = s.rounds or 0 },
    { t = "int", v = s.victories or 0 },
    { t = "int", v = s.kills or 0 },
    { t = "int", v = s.deaths or 0 },
    { t = "int", v = s.score or 0 },
  })
end

return N
