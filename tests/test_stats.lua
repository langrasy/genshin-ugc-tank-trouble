--[[ 统计与结算自测 ]]
package.path = package.path .. ";./?.lua"

local S = require("src.stats")

---@noreturn
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
