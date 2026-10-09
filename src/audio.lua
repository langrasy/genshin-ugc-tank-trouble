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

---@class AudioBackend
---@field now fun(): number
---@field play2d fun(audioId: integer): any
---@field stop fun(handle: any)

---@type AudioBackend|nil
local backend = nil
local ids = {}
local sfxLast = {}
local bgm = { name = nil, handle = nil }

---@param b AudioBackend
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
  if backend == nil then return false end
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
