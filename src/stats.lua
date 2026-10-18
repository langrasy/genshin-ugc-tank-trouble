--[[ 坦克动荡2 —— 战绩统计（纯逻辑，可脱机单测）
     与既有 G.stats 字段一一对应，语义完全沿用原版本地记录：
       kills    玩家击杀数
       deaths   玩家阵亡数
       victories 玩家获胜回合数
       rounds   完成的回合数
     平台层把 registerKill / 回合 cleanup 事件转发到此处。 ]]

local S = {}

function S.new()
  return { kills = 0, deaths = 0, victories = 0, rounds = 0 }
end

-- byPlayer = 击杀者是否玩家
function S.onKill(s, byPlayer)
  if byPlayer then s.kills = s.kills + 1 end
end

function S.onDeath(s)
  s.deaths = s.deaths + 1
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
