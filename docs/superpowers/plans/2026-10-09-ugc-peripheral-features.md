# 千星奇域外围系统实施计划（音频 / 成就 / 统计结算 / 服务器信号）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不破坏既有移植的前提下，把《坦克动荡2》缺失的四类外围能力（音乐音效、成就、统计与结算、服务器信号上报）以「纯逻辑模块 + 平台层接入」的方式补齐，全部可脱机单测，并能一键打包部署。

**Architecture:** 新增 4 个 `src/` 纯逻辑模块（`net` / `audio` / `ach` / `stats`），每个模块只依赖 `src.constants` 与依赖注入的适配器对象，因此在标准 Lua 解释器里可直接单测；`platform/game.lua` 只做「注入真实 API + 转发事件」，不含业务判定；`tools/bundle.ps1` 与 `tools/test.cmd` 分别登记新模块与新测试。客户端无法实现的排行榜 / 订阅 / 段位等仍由编辑器节点图承担，Lua 侧只负责通过 `game.ServerSignal` 上报与 `RegisterServerSignalHandler` 接收，并在文档中给出编辑器侧配置清单。

**Tech Stack:** Lua 5.3（受限运行期：无 `require`/`io`/`coroutine`，由 `tools/bundle.ps1` 注入 `require` 垫片）、PowerShell 构建脚本、原神千星奇域客户端 API（`game.PlayAudio2D` / `game.ServerSignal` / `Script:RegisterServerSignalHandler`）。

---

## 背景与硬约束

- 产物 `tank_trouble.lua` 由 `tools/bundle.ps1` 生成，**禁止手改**。
- `src/*.lua` 是纯逻辑层，可在桌面 Lua 直接 `require` 单测；平台层 `platform/game.lua` 不被单测直接加载，只由 `tests/test_platform.lua` 通过桩件驱动。
- 编码约定：`*.lua` / `*.md` / `*.json` = UTF-8 **无 BOM + LF**；`*.cmd` = UTF-8 **BOM + CRLF**。
- 客户端 API **没有**成就 / 排行榜 / 结算 / 段位 / 订阅接口（已在 `types/game_api.lua` 全量检索确证）。因此本计划的**代码边界**是：
  - **能在 Lua 落地**：本地音频状态机、本地成就判定与展示、本地战绩统计、结算面板 UI、把结果打包并通过服务器信号上报、接收服务器下发的文本/指令。
  - **不能只靠 Lua**：真实排行榜写入、订阅查询、竞技段位、奇域任务/礼盒 —— 这些由编辑器节点图 + 服务器脚本实现；Lua 只提供信号出入口，编辑器侧步骤见 Task 7 的配置清单文档。
- 只允许修改：`genshin_game` 仓库与千星奇域映射目录。不读取 `docs/ugc_official/` 全量内容（体积过大），需要时只定向读取单个已知文件。

## 文件结构（新增与改动清单）

| 文件 | 动作 | 职责 |
| --- | --- | --- |
| `src/net.lua` | 新增 | 服务器信号打包/发送/分发的纯逻辑层 |
| `src/audio.lua` | 新增 | 音频状态机：音效去重节流、BGM 切换 |
| `src/ach.lua` | 新增 | 成就定义与达成判定引擎 |
| `src/stats.lua` | 新增 | 战绩统计与结算载荷生成 |
| `tests/test_net.lua` | 新增 | `src/net.lua` 单测 |
| `tests/test_audio.lua` | 新增 | `src/audio.lua` 单测 |
| `tests/test_ach.lua` | 新增 | `src/ach.lua` 单测 |
| `tests/test_stats.lua` | 新增 | `src/stats.lua` 单测 |
| `platform/game.lua` | 修改 | 注入适配器、转发事件、结算面板、成就页扩展、清理探针 |
| `tests/test_platform.lua` | 修改 | 扩展断言（结算面板、成就页、信号上报） |
| `tools/bundle.ps1` | 修改 | `$modules` 追加 4 个新模块 |
| `tools/test.cmd` | 修改 | 测试列表追加 4 个新套件 |
| `docs/编辑器侧配置清单.md` | 新增 | 排行榜/订阅/结算/成就的编辑器节点图配置步骤 |
| `DEV_STATE.md` | 修改 | 记录本轮结论、改动、部署哈希、下一步 |

---

## Task 1: `src/net.lua` 服务器信号层

**Files:**
- Create: `src/net.lua`
- Test: `tests/test_net.lua`

- [ ] **Step 1: 写失败测试 `tests/test_net.lua`**

```lua
--[[ 服务器信号层自测 ]]
package.path = package.path .. ";./?.lua"

local N = require("src.net")

local function fail(msg) print("[FAIL] " .. msg); os.exit(1) end
local function ok(msg) print("[ok] " .. msg) end

-- 假信号对象：记录收到的 Add* 调用与 SendSignal
local function makeSignal()
  local s = { adds = {}, sent = 0 }
  local names = { "AddInt", "AddFloat", "AddString", "AddBool", "AddIntList" }
  for _, n in ipairs(names) do
    s[n] = function(self, v) self.adds[#self.adds + 1] = { n, v } end
  end
  s.SendSignal = function(self) self.sent = self.sent + 1 end
  return s
end

-- 1. 未绑定适配器时 emit 返回 false，不报错
if N.emit("X", {}) ~= false then fail("未绑定时 emit 应返回 false") end
ok("未绑定时安全返回 false")

-- 2. 绑定后按类型写入并发送
local last = nil
N.bind({
  server = function(name) last = makeSignal(); last.name = name; return last end,
})
local okSend = N.emit("TT2_ROUND", {
  { t = "int", v = 3 },
  { t = "string", v = "solo" },
  { t = "bool", v = true },
})
if okSend ~= true then fail("emit 应返回 true") end
if last.name ~= "TT2_ROUND" then fail("信号名未透传") end
if last.sent ~= 1 then fail("未调用 SendSignal") end
if #last.adds ~= 3 then fail("参数数量错误: " .. #last.adds) end
if last.adds[1][1] ~= "AddInt" or last.adds[1][2] ~= 3 then fail("AddInt 错误") end
if last.adds[2][1] ~= "AddString" or last.adds[2][2] ~= "solo" then fail("AddString 错误") end
if last.adds[3][1] ~= "AddBool" or last.adds[3][2] ~= true then fail("AddBool 错误") end
ok("按类型写入参数并发送")

-- 3. 未知类型 → 返回 false 且不发送
local bad = makeSignal()
N.bind({ server = function() return bad end })
if N.emit("X", { { t = "vector9", v = 1 } }) ~= false then fail("未知类型应失败") end
if bad.sent ~= 0 then fail("未知类型不应发送") end
ok("未知参数类型被拒绝")

-- 4. 服务器 → 客户端分发
local got = nil
N.bind({ server = function() return makeSignal() end })
N.on("ServerMsg", function(a, b) got = tostring(a) .. "/" .. tostring(b) end)
if N.dispatch("ServerMsg", "hi", 7) ~= true then fail("dispatch 应返回 true") end
if got ~= "hi/7" then fail("dispatch 回调参数错误: " .. tostring(got)) end
if N.dispatch("NeverRegistered") ~= false then fail("未注册应返回 false") end
ok("服务器信号分发正确")

-- 5. 便捷上报：回合 / 成就
local rec = nil
N.bind({ server = function() rec = makeSignal(); return rec end })
if N.reportRound({ rounds = 5, victories = 3, kills = 12, deaths = 4 }) ~= true then fail("reportRound 失败") end
if #rec.adds ~= 4 then fail("reportRound 参数数错误") end
if N.reportAchievement(28) ~= true then fail("reportAchievement 失败") end
if rec.adds[1][2] ~= 28 then fail("成就 id 未透传") end
ok("便捷上报接口正确")

print("\n全部通过。")
```

- [ ] **Step 2: 运行测试确认失败**

Run: `tools\test.cmd`（此时 `test_net` 尚未登记，改为直接跑单文件）
Run: `lua tests\test_net.lua`
Expected: 失败，报错含 `module 'src.net' not found`。

- [ ] **Step 3: 写最小实现 `src/net.lua`**

```lua
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
  MSG   = "TT2_MSG",     -- 服务器 → 客户端：文本/指令下发
}

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
  if not N.pack(sig, params or {}) then return false end
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
```

- [ ] **Step 4: 运行测试确认通过**

Run: `lua tests\test_net.lua`
Expected: 逐行 `[ok]` 与末尾 `全部通过。`

- [ ] **Step 5: 提交**

```powershell
git add src/net.lua tests/test_net.lua
git commit -m "feat(net): 新增服务器信号打包/发送/分发纯逻辑层"
```

---

## Task 2: `src/audio.lua` 音频状态机

**Files:**
- Create: `src/audio.lua`
- Test: `tests/test_audio.lua`

- [ ] **Step 1: 写失败测试 `tests/test_audio.lua`**

```lua
--[[ 音频状态机自测 ]]
package.path = package.path .. ";./?.lua"

local A = require("src.audio")

local function fail(msg) print("[FAIL] " .. msg); os.exit(1) end
local function ok(msg) print("[ok] " .. msg) end

-- 假后端：记录 play/stop 与一个可控时钟
local function makeBackend()
  local b = { t = 0, played = {}, stopped = {} , next = 1 }
  b.now = function() return b.t end
  b.play2d = function(id)
    b.played[#b.played + 1] = id
    local h = b.next; b.next = b.next + 1
    return h
  end
  b.stop = function(h) b.stopped[#b.stopped + 1] = h end
  return b
end

-- 1. 未绑定后端时安全返回 false
if A.playSfx("shoot") ~= false then fail("未绑定时 playSfx 应 false") end
if A.setBgm("menu") ~= false then fail("未绑定时 setBgm 应 false") end
ok("未绑定时安全返回 false")

-- 2. 未注册的名字不播放
local b = makeBackend()
A.bind(b)
if A.playSfx("shoot") ~= false then fail("未注册音效不应播放") end
A.register("shoot", 1001)
if A.has("shoot") ~= true then fail("has 应 true") end
if A.playSfx("shoot") ~= true then fail("已注册音效应播放") end
if #b.played ~= 1 or b.played[1] ~= 1001 then fail("播放 id 错误") end
ok("音效按注册表播放")

-- 3. 同名声效节流：间隔小于 MIN_GAP 时不重复播放
b.t = b.t + A.MIN_GAP * 0.5
if A.playSfx("shoot") ~= false then fail("节流期内不应重复播放") end
b.t = b.t + A.MIN_GAP * 2
if A.playSfx("shoot") ~= true then fail("超过节流期应可播放") end
ok("同名声效节流正确")

-- 4. BGM 切换：同名不重复，异名先停旧再播新
A.register("menu", 2001)
A.register("battle", 2002)
if A.setBgm("menu") ~= true then fail("首次设置 BGM 应成功") end
if A.currentBgm() ~= "menu" then fail("当前 BGM 应为 menu") end
if A.setBgm("menu") ~= false then fail("同名 BGM 不应重复") end
if A.setBgm("battle") ~= true then fail("切换 BGM 应成功") end
if #b.stopped ~= 1 then fail("切换时应停止旧 BGM") end
if A.currentBgm() ~= "battle" then fail("当前 BGM 应为 battle") end
if A.stopBgm() ~= true then fail("stopBgm 应成功") end
if A.currentBgm() ~= nil then fail("停止后当前 BGM 应为 nil") end
if A.stopBgm() ~= false then fail("重复停止应返回 false") end
ok("BGM 切换与停止正确")

-- 5. 未注册的 BGM 名：记录名字但不播放
local b2 = makeBackend()
A.bind(b2)
if A.setBgm("unknown") ~= true then fail("未注册 BGM 仍应切换状态") end
if #b2.played ~= 0 then fail("未注册 BGM 不应播放") end
if A.currentBgm() ~= "unknown" then fail("应记录当前 BGM 名") end
ok("未注册 BGM 只改状态不播放")

print("\n全部通过。")
```

- [ ] **Step 2: 运行测试确认失败**

Run: `lua tests\test_audio.lua`
Expected: 失败，报错含 `module 'src.audio' not found`。

- [ ] **Step 3: 写最小实现 `src/audio.lua`**

```lua
--[[ 坦克动荡2 —— 音频状态机（纯逻辑，可脱机单测）
     职责：① 名称 → 音频 ID 的注册表；② 同名音效节流；③ BGM 单轨切换。
     真实播放由平台层注入的后端完成：
       backend = {
         now    = function() -> number   -- 秒
         play2d = function(audioId) -> handle
         stop   = function(handle)
       }
     audioId 由编辑器「音效/音乐资源」配置后，由平台层调用
     A.register(name, id) 注入；未注册的名字一律静默。 ]]

local A = {}

A.MIN_GAP = 0.05   -- 同名声效最小间隔（秒），防止单帧内重复触发

local backend = nil
local ids = {}
local sfxLast = {}
local bgm = { name = nil, handle = nil }

function A.bind(b)
  backend = b
  ids = {}
  sfxLast = {}
  bgm = { name = nil, handle = nil }
end

function A.register(name, audioId)
  ids[name] = audioId
end

function A.has(name)
  return ids[name] ~= nil
end

function A.playSfx(name)
  if backend == nil then return false end
  local id = ids[name]
  if id == nil then return false end
  local now = backend.now()
  local last = sfxLast[name]
  if last ~= nil and (now - last) < A.MIN_GAP then return false end
  sfxLast[name] = now
  backend.play2d(id)
  return true
end

function A.setBgm(name)
  if backend == nil then return false end
  if bgm.name == name then return false end
  if bgm.handle ~= nil then
    backend.stop(bgm.handle)
    bgm.handle = nil
  end
  bgm.name = name
  if name ~= nil and name ~= "" then
    local id = ids[name]
    if id ~= nil then bgm.handle = backend.play2d(id) end
  end
  return true
end

function A.stopBgm()
  if bgm.name == nil and bgm.handle == nil then return false end
  if bgm.handle ~= nil then backend.stop(bgm.handle) end
  bgm.name = nil
  bgm.handle = nil
  return true
end

function A.currentBgm()
  return bgm.name
end

return A
```

- [ ] **Step 4: 运行测试确认通过**

Run: `lua tests\test_audio.lua`
Expected: 逐行 `[ok]` 与末尾 `全部通过。`

- [ ] **Step 5: 提交**

```powershell
git add src/audio.lua tests/test_audio.lua
git commit -m "feat(audio): 新增音效节流与 BGM 切换状态机"
```

---

## Task 3: `src/ach.lua` 成就引擎

**Files:**
- Create: `src/ach.lua`
- Test: `tests/test_ach.lua`

- [ ] **Step 1: 写失败测试 `tests/test_ach.lua`**

```lua
--[[ 成就引擎自测 ]]
package.path = package.path .. ";./?.lua"

local A = require("src.ach")

local function fail(msg) print("[FAIL] " .. msg); os.exit(1) end
local function ok(msg) print("[ok] " .. msg) end

-- 1. 初始态：无已解锁，计数为 0
local a = A.new()
if A.count(a) ~= 0 then fail("初始解锁数应为 0") end
if A.unlocked(a, 28) ~= false then fail("初始不应解锁 28") end
ok("初始状态正确")

-- 2. 连杀 10 次 → 解锁 28；连杀 25 次 → 解锁 35
local a2 = A.new()
local newly = nil
for i = 1, 10 do
  newly = A.apply(a2, { type = "kill", byPlayer = true, victimAi = true })
end
if A.unlocked(a2, 28) ~= true then fail("连杀 10 应解锁 28") end
if A.unlocked(a2, 35) ~= false then fail("连杀 10 不应解锁 35") end
if newly == nil or newly[1] ~= 28 then fail("应返回新解锁 28") end
for i = 11, 25 do
  A.apply(a2, { type = "kill", byPlayer = true, victimAi = true })
end
if A.unlocked(a2, 35) ~= true then fail("连杀 25 应解锁 35") end
ok("连杀成就按阈值解锁")

-- 3. 死亡清空连杀；已解锁不回收
A.apply(a2, { type = "death" })
if A.count(a2) ~= 2 then fail("已解锁成就不应回收") end
ok("死亡清连杀但不回收已解锁")

-- 4. AI 弹尽击杀 → 解锁 34
local a3 = A.new()
A.apply(a3, { type = "kill", byPlayer = true, victimAi = true, victimDry = true })
-- 注：kind=dryKill 的规则为 counters.dryKill>=1，无阈值，单次弹尽击杀即解锁
if A.unlocked(a3, 34) ~= true then fail("弹尽击杀应解锁 34") end
ok("弹尽击杀解锁")

-- 5. 回合与获胜
local a4 = A.new()
A.apply(a4, { type = "round" })
A.apply(a4, { type = "win" })
if A.unlocked(a4, 40) ~= true then fail("首次获胜应解锁 40") end
if A.unlocked(a4, 42) ~= false then fail("完成 1 回合不应解锁 42") end
ok("获胜成就解锁")

-- 6. 重复触发不重复返回
local a5 = A.new()
A.apply(a5, { type = "win" })
local again = A.apply(a5, { type = "win" })
if again ~= nil then fail("已解锁不应再次返回") end
if A.count(a5) ~= 1 then fail("解锁数应仍为 1") end
ok("重复触发不重复计入")

-- 7. LIST 结构完整：每条有 id/label/kind
for i = 1, #A.LIST do
  local r = A.LIST[i]
  if r.id == nil or r.label == nil or r.kind == nil then fail("成就定义缺字段 @" .. i) end
end
ok("成就定义结构完整（共 " .. #A.LIST .. " 条）")

print("\n全部通过。")
```

- [ ] **Step 2: 运行测试确认失败**

Run: `lua tests\test_ach.lua`
Expected: 失败，报错含 `module 'src.ach' not found`。

- [ ] **Step 3: 写最小实现 `src/ach.lua`**

```lua
--[[ 坦克动荡2 —— 成就引擎（纯逻辑，可脱机单测）
     原版成就为联网上报，此处给出本地判定等价物。
     平台层在事件发生时调用 A.apply(state, event)，拿到「本次新解锁的 id 列表」，
     再决定是否走 N.reportAchievement(id) 上报及刷新成就页。 ]]

local A = {}

-- 成就定义：kind 决定判定规则
--   streak  —— 连杀 AI 达到 n 次
--   dryKill —— 在 AI 弹药耗尽时将其击杀（无阈值，触发即解锁）
--   wins    —— 累计获胜 n 个回合
--   kills   —— 累计击杀 n 次
--   rounds  —— 累计完成 n 个回合
--   manual  —— 需外部提供弹道等信息，本地无法判定，始终显示未达成
A.LIST = {
  { id = 28, label = "连杀 AI 满 10 次",     kind = "streak",  n = 10 },
  { id = 35, label = "连杀 AI 满 25 次",     kind = "streak",  n = 25 },
  { id = 34, label = "在 AI 弹尽时将其击杀", kind = "dryKill" },
  { id = 36, label = "激光不反弹直接命中 AI", kind = "manual" },
  { id = 40, label = "赢得 1 个回合",        kind = "wins",    n = 1 },
  { id = 41, label = "累计击杀 50 次",       kind = "kills",   n = 50 },
  { id = 42, label = "累计完成 10 个回合",   kind = "rounds",  n = 10 },
}

local RULES = {
  streak  = function(a, r) return (a.streak or 0) >= r.n end,
  dryKill = function(a, r) return (a.counters.dryKill or 0) >= 1 end,
  wins    = function(a, r) return (a.counters.wins or 0) >= r.n end,
  kills   = function(a, r) return (a.counters.kills or 0) >= r.n end,
  rounds  = function(a, r) return (a.counters.rounds or 0) >= r.n end,
  manual  = function() return false end,
}

function A.new()
  return {
    unlocked = {},
    streak = 0,
    counters = { kills = 0, wins = 0, rounds = 0, dryKill = 0 },
  }
end

function A.unlocked(a, id)
  return a.unlocked[id] == true
end

function A.count(a)
  local n = 0
  for i = 1, #A.LIST do
    if a.unlocked[A.LIST[i].id] then n = n + 1 end
  end
  return n
end

-- 扫描全部规则，返回本次新解锁的 id 列表（无则 nil）
function A.evaluate(a)
  local newly = nil
  for i = 1, #A.LIST do
    local r = A.LIST[i]
    if not a.unlocked[r.id] then
      local f = RULES[r.kind]
      if f ~= nil and f(a, r) then
        a.unlocked[r.id] = true
        newly = newly or {}
        newly[#newly + 1] = r.id
      end
    end
  end
  return newly
end

-- 事件：
--   { type = "kill",  byPlayer = true, victimAi = true, victimDry = false }
--   { type = "death" }
--   { type = "win" }
--   { type = "round" }
function A.apply(a, ev)
  local t = ev.type
  if t == "kill" then
    if ev.byPlayer then
      a.counters.kills = a.counters.kills + 1
      if ev.victimAi then
        a.streak = a.streak + 1
        if ev.victimDry then a.counters.dryKill = a.counters.dryKill + 1 end
      else
        a.streak = 0
      end
    end
  elseif t == "death" then
    a.streak = 0
  elseif t == "win" then
    a.counters.wins = a.counters.wins + 1
  elseif t == "round" then
    a.counters.rounds = a.counters.rounds + 1
  end
  return A.evaluate(a)
end

return A
```

- [ ] **Step 4: 运行测试确认通过**

Run: `lua tests\test_ach.lua`
Expected: 逐行 `[ok]` 与末尾 `全部通过。`

- [ ] **Step 5: 提交**

```powershell
git add src/ach.lua tests/test_ach.lua
git commit -m "feat(ach): 抽出成就定义与达成判定引擎"
```

---

## Task 4: `src/stats.lua` 统计与结算载荷

**Files:**
- Create: `src/stats.lua`
- Test: `tests/test_stats.lua`

- [ ] **Step 1: 写失败测试 `tests/test_stats.lua`**

```lua
--[[ 统计与结算自测 ]]
package.path = package.path .. ";./?.lua"

local S = require("src.stats")

local function fail(msg) print("[FAIL] " .. msg); os.exit(1) end
local function ok(msg) print("[ok] " .. msg) end

-- 1. 初始态
local s = S.new()
if s.kills ~= 0 or s.deaths ~= 0 or s.victories ~= 0 or s.rounds ~= 0 then
  fail("初始统计应全 0")
end
ok("初始统计正确")

-- 2. 击杀与死亡
S.onKill(s, true)
S.onKill(s, true)
S.onKill(s, false)   -- 非玩家击杀不计
S.onDeath(s)
if s.kills ~= 2 then fail("击杀累计错误: " .. s.kills) end
if s.deaths ~= 1 then fail("死亡累计错误: " .. s.deaths) end
ok("击杀/死亡累计正确")

-- 3. 回合结算：胜/负
S.onRound(s, true)
S.onRound(s, false)
if s.rounds ~= 2 then fail("回合数错误: " .. s.rounds) end
if s.victories ~= 1 then fail("获胜数错误: " .. s.victories) end
ok("回合结算累计正确")

-- 4. summary 文本（与既有 About 页格式一致）
local txt = S.summary(s)
local expect = string.format("本地战绩：击杀 %d · 死亡 %d · 获胜 %d 回合 · 完成 %d 回合",
  s.kills, s.deaths, s.victories, s.rounds)
if txt ~= expect then fail("summary 文本错误: " .. txt) end
ok("summary 文本格式正确")

-- 5. payload（供 net.reportRound 使用）
local p = S.payload(s)
if p.rounds ~= s.rounds or p.victories ~= s.victories
   or p.kills ~= s.kills or p.deaths ~= s.deaths then
  fail("payload 字段错误")
end
ok("payload 字段正确")

print("\n全部通过。")
```

- [ ] **Step 2: 运行测试确认失败**

Run: `lua tests\test_stats.lua`
Expected: 失败，报错含 `module 'src.stats' not found`。

- [ ] **Step 3: 写最小实现 `src/stats.lua`**

```lua
--[[ 坦克动荡2 —— 战绩统计（纯逻辑，可脱机单测）
     与既有 G.stats 字段一一对应，语义完全沿用原版本地记录：
       kills    玩家击杀数
       deaths   玩家阵亡数
       victories 玩家获胜回合数
       rounds   完成的回合数
       selfKills 自杀数（预留，原版有该字段）
     平台层把 registerKill / 回合 cleanup 事件转发到此处。 ]]

local S = {}

function S.new()
  return { kills = 0, deaths = 0, victories = 0, rounds = 0, selfKills = 0 }
end

-- byPlayer = 击杀者是否玩家
function S.onKill(s, byPlayer)
  if byPlayer then s.kills = s.kills + 1 end
end

function S.onDeath(s)
  s.deaths = s.deaths + 1
end

function S.onSelfKill(s)
  s.selfKills = s.selfKills + 1
end

-- playerWon = 本回合结束时玩家是否存活
function S.onRound(s, playerWon)
  s.rounds = s.rounds + 1
  if playerWon then s.victories = s.victories + 1 end
end

-- About 页文本，格式与既有 updateAboutTexts 完全一致
function S.summary(s)
  return string.format("本地战绩：击杀 %d · 死亡 %d · 获胜 %d 回合 · 完成 %d 回合",
    s.kills, s.deaths, s.victories, s.rounds)
end

-- 上报载荷：{ rounds, victories, kills, deaths }
function S.payload(s)
  return { rounds = s.rounds, victories = s.victories, kills = s.kills, deaths = s.deaths }
end

return S
```

- [ ] **Step 4: 运行测试确认通过**

Run: `lua tests\test_stats.lua`
Expected: 逐行 `[ok]` 与末尾 `全部通过。`

- [ ] **Step 5: 提交**

```powershell
git add src/stats.lua tests/test_stats.lua
git commit -m "feat(stats): 抽出战绩统计与结算载荷生成"
```

---

### Task 5: 构建链接入 + 信号 / 音频 / 成就 / 统计接线

**Files:**
- Modify: `tools/bundle.ps1`（`$modules` 数组，约 L19–26）
- Modify: `tools/test.cmd`（测试清单，`for %%t in (...)` 行）
- Modify: `platform/game.lua`（L24–29 依赖头、L340–343 `G` 表、L903–907 `playSound`、L1273–1278 回合结算、L2066–2089 `registerKill`、L2094–2138 `OnInit`/`OnStart`、L2144+ `OnLevelUpdate`、L1960–1971 `beginMatch`）

- [ ] **Step 1: 构建链追加 4 个模块**

`tools/bundle.ps1`，把 `$modules` 数组改为（顺序即依赖顺序，新模块无相互依赖，追加在末尾）：

```powershell
$modules = @(
    'src.constants', 'src.maze', 'src.tank', 'src.weapons', 'src.ai', 'src.round',
    'src.net', 'src.audio', 'src.ach', 'src.stats'
)
```

- [ ] **Step 2: 测试清单追加 4 个套件**

`tools/test.cmd`，把 `for %%t in (...)` 那一行改为：

```bat
for %%t in (test_maze test_tank test_round test_platform test_net test_audio test_ach test_stats) do (
```

- [ ] **Step 3: 依赖头追加 require**

`platform/game.lua` L29 之后追加 4 行（`local roundApi = require("src.round")` 之后）：

```lua
local netApi   = require("src.net")     -- 服务器信号上报（客户端 → 服务器）
local audioApi = require("src.audio")   -- 音乐音效状态机
local achApi   = require("src.ach")     -- 本地成就引擎
local statsApi = require("src.stats")   -- 本地战绩统计
```

- [ ] **Step 4: `G` 表改用模块构造**

`platform/game.lua` L340–343，把两行字面量改为模块构造器（字段名随之由 `ach.consecutive` 变为 `ach.streak`，Step 7 会同步改写入点）：

```lua
  -- 本地战绩（原版为上传到 pixvi.net 的统计，此处只本地累计）
  stats = statsApi.new(),
  -- 本地成就（原版通过 achievement.php 上报，此处只本地记录）
  ach = achApi.new(),
```

- [ ] **Step 5: 音效 / 信号 / 成就上报接入块**

`platform/game.lua` L903–907（`local SOUND_IDS = {}` 至 `end`）整段替换为：

```lua
-- ============================================================
-- ⑪.5 外围系统接入：本地音频 / 服务器信号 / 成就上报
-- ============================================================
-- 音效 ID 表：键名为音效名，值为编辑器里配置的音频 ID（未配置则静默）。
-- 需与 src/audio.lua 使用同一套名称；例：SOUND_IDS = { fire = 1001, explode = 1002 }
local SOUND_IDS = {}
local audioClock = 0   -- 秒，由 OnLevelUpdate 推进，供 audio 模块做同类音效最小间隔

-- 绑定音频后端：真机走 game.PlayAudio2D / game.StopAudio；未配置音频 ID 时全程静默
local function bindAudioBackend()
  audioApi.bind({
    now    = function() return audioClock end,
    play2d = function(id) return game.PlayAudio2D(id) end,
    stop   = function(h) pcall(game.StopAudio, h) end,
  })
  for name, id in pairs(SOUND_IDS) do audioApi.register(name, id) end
end

function playSound(name)
  audioApi.playSfx(name)
end

-- 绑定服务器信号：客户端 → 服务器上报；单机（无联机服务器）时 SendSignal 无效但安全
local function bindNet()
  netApi.bind({
    -- 防御：单机 / 单测环境可能没有 ServerSignal，返回 nil 让 emit 安全失败
    server = function(name)
      if game.ServerSignal == nil then return nil end
      return game.ServerSignal(name)
    end,
  })
  -- 服务器 → 客户端：排行榜名次 / 段位等下发，本地单机不会触发
  pcall(function()
    script:RegisterServerSignalHandler(netApi.SIG.MATCH, function(sig, params)
      local n = 0
      if params ~= nil then n = #params end
      print("[坦克动荡] 收到服务器信号 " .. tostring(sig) .. "，参数数=" .. tostring(n))
    end)
  end)
end

-- 新解锁成就 → 逐个上报（原版 unlockAchievement 的本地等价）
local function reportNewAch(ids)
  if ids == nil then return end
  for i = 1, #ids do netApi.reportAchievement(ids[i]) end
end

-- 回合战绩 → 上报（原版 unsentRoundsCompleted 等字段的本地等价）
local function reportStats()
  netApi.reportRound(statsApi.payload(G.stats))
end
```

- [ ] **Step 6: 回合结算改走 stats / ach 模块**

`platform/game.lua` L1273–1278（`elseif ev == "cleanup" then` 到 `updateScoreHUD()`）整段替换为：

```lua
  elseif ev == "cleanup" then
    roundApi.assignPoints(G.tanks)
    -- 本地战绩：回合完成数 / 玩家存活获胜数（原版为 unsentRoundsCompleted 等上传字段）
    local pl = G.tanks[G.playerIndex]
    local won = (pl ~= nil and pl.alive)
    statsApi.onRound(G.stats, won)
    local newly = achApi.apply(G.ach, { type = "round" })
    if won then
      local w = achApi.apply(G.ach, { type = "win" })
      if w ~= nil then
        newly = newly or {}
        for i = 1, #w do newly[#newly + 1] = w[i] end
      end
    end
    reportNewAch(newly)
    reportStats()
    clearProjectiles()
    clearCrates()
    updateScoreHUD()
```

- [ ] **Step 7: `registerKill` 改走 stats / ach 模块**

`platform/game.lua` L2066–2089（注释行 + `registerKill = function(...)` 到 `end`）整段替换为：

```lua
-- 击杀登记 → 本地战绩 + 本地成就；并把新解锁成就上报（原版 registerHit / unlockAchievement）
registerKill = function(victim, source)
  if victim == nil or source == nil then return end
  local player = G.tanks[G.playerIndex]
  if player == nil then return end
  if source == player then
    -- dryKill 判定：目标用的是普通炮弹且已打光（bulletsFired 达上限）
    local dry = (victim.currentWeapon == "bullet")
      and ((victim.bulletsFired or 0) >= C.SETTINGS.maxBullets)
    local newly = achApi.apply(G.ach, {
      type = "kill", byPlayer = true, victimAi = victim.ai == true, victimDry = dry,
    })
    statsApi.onKill(G.stats, true)
    reportNewAch(newly)
  elseif victim == player then
    statsApi.onDeath(G.stats)
    achApi.apply(G.ach, { type = "death" })
  end
end
```

- [ ] **Step 8: `OnStart` 绑定后端 + 菜单 BGM**

`platform/game.lua` L2106（`selfCheckPrefabs()` 之后）追加 3 行：

```lua
  selfCheckPrefabs()
  bindAudioBackend()
  bindNet()
  audioApi.setBgm("menu")
```

- [ ] **Step 9: `OnLevelUpdate` 推进音频时钟**

`platform/game.lua` L2146（`dt = min(dt, 0.25)` 之后）追加 1 行：

```lua
  dt = min(dt, 0.25)
  audioClock = audioClock + dt
```

- [ ] **Step 10: 开赛切战斗 BGM**

`platform/game.lua` `beginMatch`（L1960–1971），在 `MENU.phase = "playing"` 之前追加 1 行：

```lua
  MENU.phase = "playing"
  audioApi.setBgm("battle")
  startNewRound()
```

- [ ] **Step 11: 跑全量测试确认通过**

Run: `tools\test.cmd`
Expected: `[bundle] 已生成 ...` 后依次 8 个套件全部 `全部通过。`，末尾 `结果：全部通过`。

- [ ] **Step 12: 提交**

```powershell
git add tools/bundle.ps1 tools/test.cmd platform/game.lua
git commit -m "feat(wire): 平台层接入 net/audio/ach/stats 四个模块"
```

---

### Task 6: 结算面板 + 成就页扩展 + 平台测试补桩

**Files:**
- Modify: `platform/game.lua`（L1563–1568 `ACH_LIST`；HUD 区 `hud`；`beginMatch`/回合结算；新增 `showResult` 面板）
- Modify: `tests/test_platform.lua`（桩件补齐 + 断言扩展）

- [ ] **Step 1: `ACH_LIST` 与 `src/ach.lua` 对齐为 7 条**

`platform/game.lua` L1563–1568 整段替换为：

```lua
local ACH_LIST = {
  { id = 28, label = "连杀 AI 满 10 次" },
  { id = 35, label = "连杀 AI 满 25 次" },
  { id = 34, label = "在 AI 弹尽时将其击杀" },
  { id = 36, label = "激光不反弹直接命中 AI（需弹道信息，本地暂不适用）" },
  { id = 40, label = "赢得 1 个回合" },
  { id = 41, label = "累计击杀 50 次" },
  { id = 42, label = "累计完成 10 个回合" },
}
```

（`buildMenuUI` 与 `updateAboutTexts` 均按 `#ACH_LIST` 循环，扩展后关于页自动多列 3 行，无需改这两处。）

- [ ] **Step 2: 新增本地结算面板**

`platform/game.lua` L1384–1390 的 `setupHUD` 整段替换为（结算文本控件必须**在 setupHUD 内**创建，不能写在模块顶层，否则会在 host 尚未就绪时实例化控件）：

```lua
local function setupHUD()
  -- 计分板固定在舞台底部（原版 playerScoreBoard._y = MOVIEHEIGHT - 25）
  hud.score = makeText(stageY(STAGE_H - 32), 34, "红 0   :   0 绿")
  -- 武器与操作提示放在舞台上方，避免压住迷宫
  hud.weapon = makeText(stageY(-52), 22, "武器：普通炮弹")
  hud.hint = makeText(stageY(-20), 20, "红方 S/E/F/D 移动 · Q 开火    设置：R")
  -- 本地结算面板：回合结束短暂显示一次战绩小结（原版为服务器结算/奖励发放）。
  -- 真正的奖励与段位结算在编辑器节点图完成，这里只做本地可视化反馈。
  hud.result = makeText(stageY(STAGE_H / 2), 26, "")
  hud.resultTtl = 0
end

function showResult(text, seconds)
  if hud.result == nil then return end
  hud.result.text = text
  hud.resultTtl = seconds or 2.0
  hud.result:SetVisible(true)
end

local function stepResult(dt)
  if hud.result == nil then return end
  if hud.resultTtl > 0 then
    hud.resultTtl = hud.resultTtl - dt
    if hud.resultTtl <= 0 then hud.result:SetVisible(false) end
  end
end
```

（`showResult` 用全局函数，`stepFrame` 里可直接调用；`stepResult` 是局部函数，只能被 `setupHUD` 之后的代码调用 —— Step 4 把它挂在 `OnLevelUpdate`。）

- [ ] **Step 3: 回合结算时弹出小结**

在 Task 5 Step 6 已改好的 `cleanup` 分支内、`updateScoreHUD()` 之后追加：

```lua
    updateScoreHUD()
    showResult(statsApi.summary(G.stats), 2.0)
```

- [ ] **Step 4: 每帧推进结算面板计时**

在 `OnLevelUpdate`（L2144+）里、Task 5 Step 9 加的 `audioClock = audioClock + dt` 之后追加 1 行：

```lua
  audioClock = audioClock + dt
  stepResult(dt)
```

（不放在 `stepFrame` —— `stepResult` 是 HUD 区的局部函数，定义在 `stepFrame` 之后，直接引用会解析成全局 nil。）

- [ ] **Step 5: 补齐 `tests/test_platform.lua` 桩件**

在桩件 `makeControl` 内补两个方法（真机控件有、桩件此前缺失）：

```lua
  function c:SetActive() end
  function c:SetAsLastSibling() end
```

并把 `game` 桩改为：

```lua
  game = {
    InstantiateClientUIControl = function(prefab, parent)
      assert(parent ~= nil, "父控件不能为空")
      return makeControl(prefab)
    end,
    PlayAudio2D = function() return 1 end,
    StopAudio = function() end,
    IsAudioAlive = function() return true end,
    ServerSignal = function(name)
      return {
        AddInt = function() end, AddFloat = function() end, AddString = function() end,
        AddBool = function() end, AddIntList = function() end, SendSignal = function() end,
      }
    end,
  }
```

并把 `script` 桩改为：

```lua
  script = {
    object = host,
    EnableUpdate = function() end,
    RegisterServerSignalHandler = function() end,
    UnregisterServerSignalHandler = function() end,
  }
```

- [ ] **Step 6: 追加断言**

`tests/test_platform.lua` 末尾（`OnDestroy` 断言之后、结果汇总之前）追加：

```lua
-- ── 外围系统：结算面板 / 信号桩件是否被安全调用 ──
assert(G.stats ~= nil, "本地战绩表缺失")
assert(G.stats.rounds >= 1, "完成至少 1 个回合后 rounds 应 >= 1")
assert(type(G.stats.kills) == "number", "kills 应为数字")
assert(G.ach ~= nil and type(G.ach.unlocked) == "table", "本地成就表缺失")
assert(type(G.ach.streak) == "number", "ach.streak 应为数字（由 src/ach.lua 构造）")
print("[ok] 外围系统：stats / ach 已接入且未抛错")
```

（`showResult` / `stepResult` 会在上述长跑 6000 帧里被调用；若桩件缺 `SetActive`/`SetAsLastSibling` 会直接报错，故本步同时验证了补桩正确。）

- [ ] **Step 7: 运行单测确认通过**

Run: `lua tests\test_platform.lua`
Expected: 全部既有断言通过 + 新增 `[ok] 外围系统...`，末尾 `全部通过。`

- [ ] **Step 8: 提交**

```powershell
git add platform/game.lua tests/test_platform.lua
git commit -m "feat(ui): 本地结算面板与成就页扩展，补平台测试桩件"
```

---

### Task 7: 清理诊断探针与死代码 + 编辑器侧配置清单

**Files:**
- Modify: `platform/game.lua`（L234–279 自检探针块、L2130–2134、L2147–2153、L326、L397–398）
- Create: `docs/编辑器侧配置清单.md`

- [ ] **Step 1: 移除 `selfCheckPrefabs` 的 TEXT 探针块**

`platform/game.lua` L234–279（`-- 额外探针：...` 注释起、到对应 `end` 止）整段删除。删除后 `selfCheckPrefabs` 只保留 L222–233 的模板索引自检，末尾 `print("[坦克动荡] 模板自检：" .. table.concat(seg, " | "))` 保留。

- [ ] **Step 2: 移除 `OnStart` 的探针置顶**

`platform/game.lua` L2130–2134（探针注释 + `if G.textProbe ~= nil then ... end`）整段删除。

- [ ] **Step 3: 移除 `OnLevelUpdate` 的探针倒计时**

`platform/game.lua` L2147–2153（探针注释 + `if G.textProbe ~= nil then ... end`）整段删除。

- [ ] **Step 4: 移除死代码 `wallHolder`**

`platform/game.lua` L326，把 `  wallParts = {}, wallHolder = {},` 改为：

```lua
  wallParts = {},
```

`platform/game.lua` L398（`buildMazeVisuals` 内），删掉 `  G.wallHolder = {}` 一行（确认全文件再无 `wallHolder` 引用）。

- [ ] **Step 5: 确认无残留**

Run: `Select-String -Path platform\game.lua -Pattern 'textProbe|wallHolder'`
Expected: 无输出。

- [ ] **Step 6: 新建编辑器侧配置清单**

Create `docs/编辑器侧配置清单.md`，内容为客户端无法完成、必须在「千星奇域编辑器节点图 + 服务器」侧配置的条目，供策划/关卡同学照做：

```markdown
# 坦克动荡2（千星奇域）编辑器侧配置清单

客户端 Lua 只能做本地判定与展示。以下条目必须在编辑器节点图 / 服务器完成。
客户端已通过 `game.ServerSignal` 上报、`RegisterServerSignalHandler` 接收，名称沿用 `src/net.lua`：

| 信号名 | 方向 | 载荷（Add* 顺序） | 触发时机 |
| --- | --- | --- | --- |
| `TT2_ROUND` | 客户端 → 服务器 | int×4：rounds, victories, kills, deaths | 每回合结算 |
| `TT2_ACH` | 客户端 → 服务器 | int×1：achievementId | 新解锁成就 |
| `TT2_MATCH` | 客户端 ← 服务器 | 由服务器决定（名次 / 段位） | 整场结束 |

## 1. 音乐音效
1. 在编辑器中导入音频资源，记下每个音效的「音频 ID」。
2. 把 ID 填入 `platform/game.lua` 的 `SOUND_IDS` 表（键名如 `fire` / `explode` / `menu` / `battle`）。
3. 未填写的键保持静默，不影响运行。

## 2. 成就
1. 在编辑器的「成就」面板创建与 `src/ach.lua` `A.LIST` 一致的成就 ID（28/34/35/36/40/41/42）。
2. 添加触发：收到 `TT2_ACH` 信号时，按载荷中的 achievementId 解锁对应成就。
3. 极致成就需先有 ≥5 个普通成就，注意配额。

## 3. 排行榜
1. 客户端每回合发 `TT2_ROUND`，服务器累加后写入排行榜。
2. **排行榜与竞技段位只能二选一**（同一局内）。
3. 每个榜单仅记录前 1000 名。

## 4. 奇域订阅
1. 订阅查询与礼盒发放均在编辑器侧完成，客户端无对应 API。
2. 局内存档只支持纯增量升级，不能覆盖写。

## 5. 关卡结算
1. 客户端 `showResult` 仅做本地文本反馈，真正的奖励发放走服务器。
2. 整场结束发 `TT2_MATCH`；服务器返回名次/段位，客户端 `RegisterServerSignalHandler` 收到后打印（可按需扩展为面板展示）。

## 通用注意事项
- 联机服务器下发信号最低延迟约 100ms。
- 客户端控件依附容器：容器隐藏/销毁、传送、断线重连都会销毁全部客户端控件。
- 文本超范围不显示，最小字号 ≥16。
```

- [ ] **Step 7: 跑全量测试确认通过**

Run: `tools\test.cmd`
Expected: 8 个套件全部 `全部通过。`，末尾 `结果：全部通过`。

- [ ] **Step 8: 提交**

```powershell
git add platform/game.lua docs/编辑器侧配置清单.md
git commit -m "chore: 清理自检探针与死代码，补编辑器侧配置清单"
```

---

### Task 8: 打包 / 全量测试 / 部署 + 更新 DEV_STATE

**Files:**
- Modify: `DEV_STATE.md`
- 产物: `tank_trouble.lua`（由 `tools\bundle.ps1` 生成，禁止手改）

- [ ] **Step 1: 语法检查**

Run: `tools\check.cmd`
Expected: `luac -p` 与 `lua-language-server --check` 均无错误输出。

- [ ] **Step 2: 全量测试**

Run: `tools\test.cmd`
Expected: 8 个套件全部 `全部通过。`，末尾 `结果：全部通过`；`[bundle] 已生成 ...（N 行）`，N 应大于此前的 5640（新增 4 模块）。

- [ ] **Step 3: 部署到本机游戏目录**

Run: `tools\deploy.cmd`
Expected: 输出复制目标路径与成功信息。

- [ ] **Step 4: 记录产物 MD5 与行数**

Run: `Get-FileHash -Algorithm MD5 tank_trouble.lua ; (Get-Content tank_trouble.lua | Measure-Object -Line).Lines`
Expected: 得到新的 MD5 与行数（用于 `DEV_STATE.md` §9 记录）。

- [ ] **Step 5: 更新 `DEV_STATE.md`**

在 `DEV_STATE.md`：
1. §9 部署信息：更新产物 MD5 与行数为 Step 4 的结果。
2. §10 待办：勾掉「音乐音效 / 成就 / 统计 / 结算 / 信号上报」已完成项；保留「真机验证音频 ID 与联机信号」为待办（需编辑器侧配置后才能在真机验证）。
3. 「已完成」区追加一段：

```markdown
- 外围系统（本地侧）落地：新增 src/net.lua（信号上报）、src/audio.lua（音乐音效状态机）、
  src/ach.lua（7 项本地成就）、src/stats.lua（战绩统计与结算文本）；平台层已接线，
  本地结算面板已加入；编辑器侧需按 docs/编辑器侧配置清单.md 配置音频 ID / 成就 / 排行榜 / 订阅 / 结算。
```

- [ ] **Step 6: 提交**

```powershell
git add DEV_STATE.md tank_trouble.lua
git commit -m "chore: 打包部署并更新 DEV_STATE（外围系统本地侧完成）"
```
