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
