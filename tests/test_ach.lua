--[[ 成就引擎自测 ]]
package.path = package.path .. ";./?.lua"

local A = require("src.ach")

---@noreturn
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
