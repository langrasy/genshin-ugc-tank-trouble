--[[ 服务器信号层自测 ]]
package.path = package.path .. ";./?.lua"

local N = require("src.net")

---@noreturn
local function fail(msg) print("[FAIL] " .. msg); os.exit(1) end
local function ok(msg) print("[ok] " .. msg) end

-- 假信号对象：记录收到的 Add* 调用与 SendSignal
---@return table<string, any>
local function makeSignal()
  ---@type table<string, any>
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
---@type any
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
---@type any
local rec = nil
N.bind({ server = function() rec = makeSignal(); return rec end })
if N.reportRound({ rounds = 5, victories = 3, kills = 12, deaths = 4 }) ~= true then fail("reportRound 失败") end
if #rec.adds ~= 4 then fail("reportRound 参数数错误") end
if N.reportAchievement(28) ~= true then fail("reportAchievement 失败") end
if rec.adds[1][2] ~= 28 then fail("成就 id 未透传") end
ok("便捷上报接口正确")

-- 6. 信号名常量完整（编辑器节点图必须与之一致）
for _, k in ipairs({ "ROUND", "ACH", "MATCH", "LEAVE", "DONE", "SET_WIN", "SET_LOSE", "ESCAPE", "SETTLE", "PING",
                     "SNAP1", "SNAP2", "EVENT", "HELLO", "SLOT",
                     "MAZE_UP", "CRATE_UP", "MATCH_UP", "READY1", "READY2" }) do
  if type(N.SIG[k]) ~= "string" or N.SIG[k] == "" then fail("SIG 缺 " .. k) end
end
if N.SIG.SNAP1 == N.SIG.SNAP2 then fail("SNAP1/SNAP2 不能同名（会互相覆盖）") end
if N.SIG.READY1 == N.SIG.READY2 then fail("READY1/READY2 不能同名（会互相覆盖）") end
if N.SIG.SET_WIN == N.SIG.SET_LOSE then fail("SET_WIN 与 SET_LOSE 不能同名（状态会互相覆盖）") end
if N.SIG.SET_WIN == N.SIG.DONE then fail("SET_WIN 与 TT2_DONE 不能同名（前者不结束游戏、后者要结算）") end
ok("信号名常量完整（含 SET_WIN/SET_LOSE/SNAP1/SNAP2/EVENT/SLOT/MAZE_UP/CRATE_UP/MATCH_UP/READY1/READY2）")

-- 6b. v4：房主上传整张迷宫表（整数列表，表首项 = 回合号 seq）
---@type table<string, any>
local recM
N.bind({ server = function(name) recM = makeSignal(); recM.name = name; return recM end })
if N.reportMazeUp({ 3, 6, 5, 0, 0, 1, 2, 3 }) ~= true then fail("reportMazeUp 失败") end
if recM.name ~= "TT2_MAZE_UP" then fail("reportMazeUp 信号名错误：" .. tostring(recM.name)) end
if #recM.adds ~= 1 or recM.adds[1][1] ~= "AddIntList" or recM.adds[1][2][1] ~= 3 then
  fail("reportMazeUp 未按整数列表打包（首项应为 seq）")
end
ok("reportMazeUp：整数列表 + 信号名 TT2_MAZE_UP（首项 seq）")

-- 6c. v4：快照**按槽位分信号**（TT2_SNAP_1 / TT2_SNAP_2）
---@type table<string, any>
local recS
N.bind({ server = function(name) recS = makeSignal(); recS.name = name; return recS end })
if N.reportSnap(1, { 1, 10, 20, 0, 2, 1 }) ~= true then fail("reportSnap(slot=1) 失败") end
if recS.name ~= N.SIG.SNAP1 then fail("槽位 1 应发 TT2_SNAP_1，实为 " .. tostring(recS.name)) end
if N.reportSnap(2, { 2, 10, 20, 0, 2, 1 }) ~= true then fail("reportSnap(slot=2) 失败") end
if recS.name ~= N.SIG.SNAP2 then fail("槽位 2 应发 TT2_SNAP_2，实为 " .. tostring(recS.name)) end
if recS.adds[1][1] ~= "AddIntList" then fail("快照应以整数列表发送") end
ok("reportSnap：按槽位选信号（1→TT2_SNAP_1 / 2→TT2_SNAP_2）")

-- 6d. v4：房主上传整张补给箱表（整数列表）+ 上报胜者槽位（整数）
---@type table<string, any>
local recC
N.bind({ server = function(name) recC = makeSignal(); recC.name = name; return recC end })
if N.reportCrates({ 1, 3, 4, 2 }) ~= true then fail("reportCrates 失败") end
if recC.name ~= "TT2_CRATE_UP" then fail("reportCrates 信号名错误：" .. tostring(recC.name)) end
if recC.adds[1][1] ~= "AddIntList" then fail("补给箱表应以整数列表发送") end
if N.reportWinner(2) ~= true then fail("reportWinner 失败") end
if recC.name ~= "TT2_MATCH_UP" then fail("reportWinner 信号名错误：" .. tostring(recC.name)) end
if recC.adds[1][1] ~= "AddInt" or recC.adds[1][2] ~= 2 then fail("胜者应以整数携带槽位") end
ok("reportCrates / reportWinner：信号名与参数类型正确")

-- 6e. v5：准备档**按槽位分信号**（TT2_READY_1 / TT2_READY_2）
---@type table<string, any>
local recR
N.bind({ server = function(name) recR = makeSignal(); recR.name = name; return recR end })
if N.reportReady(1, { 1, 3, 1, 0 }) ~= true then fail("reportReady(slot=1) 失败") end
if recR.name ~= N.SIG.READY1 then fail("槽位 1 应发 TT2_READY_1，实为 " .. tostring(recR.name)) end
if N.reportReady(2, { 1, 2, 2, 0 }) ~= true then fail("reportReady(slot=2) 失败") end
if recR.name ~= N.SIG.READY2 then fail("槽位 2 应发 TT2_READY_2，实为 " .. tostring(recR.name)) end
if recR.adds[1][1] ~= "AddIntList" then fail("准备档应以整数列表发送") end
ok("reportReady：按槽位选信号（1→TT2_READY_1 / 2→TT2_READY_2）")

-- 7. 整场上报 / 完成上报 / 延迟探测
---@type any
local rec2 = nil
N.bind({ server = function(name) rec2 = makeSignal(); rec2.name = name; return rec2 end })
if N.reportMatch({ rounds = 1, victories = 1, kills = 2, deaths = 0, score = 3 }) ~= true then fail("reportMatch 失败") end
if #rec2.adds ~= 5 then fail("reportMatch 应为 5 个参数，实为 " .. #rec2.adds) end
if N.reportDone() ~= true then fail("reportDone 失败") end
if rec2.name ~= N.SIG.DONE then fail("reportDone 应发 TT2_DONE") end
if N.reportPing(12.5) ~= true then fail("reportPing 失败") end
if rec2.name ~= N.SIG.PING then fail("reportPing 应发 TT2_PING") end
if rec2.adds[1][1] ~= "AddFloat" or rec2.adds[1][2] ~= 12.5 then fail("PING 应以浮点携带时间戳") end
ok("reportMatch / reportDone / reportPing 参数正确")

-- 8. 结算状态上报（用户 2026-10-15 定、2026-10-16 修订）：
--     单机进局预置「胜利」/ 联机进局预置「逃跑合法性=否」/ 联机各自报最终胜负；
--     ⚠️ 三条都带 **1 个整数参数 = 本机玩家序号**（信号无「发送实体」，服务器靠它定位玩家）。
if N.reportSetWin(2) ~= true then fail("reportSetWin 失败") end
if rec2.name ~= N.SIG.SET_WIN then fail("reportSetWin 应发 " .. N.SIG.SET_WIN .. "，实为 " .. tostring(rec2.name)) end
if #rec2.adds ~= 1 or rec2.adds[1][1] ~= "AddInt" or rec2.adds[1][2] ~= 2 then
  fail("reportSetWin 应带 1 个整数参数（玩家序号）")
end
if N.reportSetLose(2) ~= true then fail("reportSetLose 失败") end
if rec2.name ~= N.SIG.SET_LOSE then fail("reportSetLose 应发 " .. N.SIG.SET_LOSE .. "，实为 " .. tostring(rec2.name)) end
if #rec2.adds ~= 1 or rec2.adds[1][1] ~= "AddInt" then fail("reportSetLose 应带 1 个整数参数") end
ok("reportSetWin / reportSetLose：TT2_SET_WIN / TT2_SET_LOSE 各带 1 个整数（玩家序号）")

-- 9. 联机「中途离开 = 逃跑」预置 + 「立刻结算关卡」请求（用户 2026-10-16 规则）
if N.reportSetEscape(1) ~= true then fail("reportSetEscape 失败") end
if rec2.name ~= N.SIG.ESCAPE then fail("reportSetEscape 应发 " .. N.SIG.ESCAPE .. "，实为 " .. tostring(rec2.name)) end
if #rec2.adds ~= 1 or rec2.adds[1][1] ~= "AddInt" or rec2.adds[1][2] ~= 1 then
  fail("reportSetEscape 应带 1 个整数参数（玩家序号）")
end
if N.reportSettle() ~= true then fail("reportSettle 失败") end
if rec2.name ~= N.SIG.SETTLE then fail("reportSettle 应发 " .. N.SIG.SETTLE .. "，实为 " .. tostring(rec2.name)) end
if #rec2.adds ~= 0 then fail("reportSettle 不应带参数，实为 " .. #rec2.adds .. " 个") end
if N.SIG.ESCAPE == N.SIG.SETTLE then fail("ESCAPE 与 SETTLE 不能同名") end
ok("reportSetEscape（1 个整数参数）/ reportSettle（无参数）")

print("\n全部通过。")
