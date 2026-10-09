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
