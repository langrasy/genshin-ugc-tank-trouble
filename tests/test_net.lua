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
