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
-- 两个独立静音开关（设置面板「音效」「音乐」各一）：
--   * sfxMuted：playSfx 直接不播。
--   * bgmMuted：BGM 停掉但记住期望曲目，取消静音后自动续播同一首。
local sfxMuted = false
local bgmMuted = false
local bgmWanted = nil
-- 注意：bgm.id 记录「当前正在播的音频 ID」。同名或**不同名但解析到同一 ID**（例如临时占位时
-- menu / battle 都指向同一条曲目）都不重启，避免切页把同一首曲子从头再放一遍。
local bgmId = nil

---@param b AudioBackend
function A.bind(b)
  backend = b
  ids = {}
  sfxLast = {}
  bgm = { name = nil, handle = nil }
  bgmId = nil
end

function A.register(name, audioId)
  ids[name] = audioId
end

function A.has(name)
  return ids[name] ~= nil
end

function A.playSfx(name)
  if backend == nil or sfxMuted then return false end
  local id = ids[name]
  if id == nil then return false end
  local now = backend.now()
  local last = sfxLast[name]
  if last ~= nil and (now - last) < A.MIN_GAP then return false end
  sfxLast[name] = now
  backend.play2d(id)
  return true
end

-- 音效开关（设置面板「音效」）。关掉后 playSfx 静默，不影响 BGM。
function A.setSfxMuted(v)
  v = v and true or false
  if sfxMuted == v then return false end
  sfxMuted = v
  return true
end

function A.isSfxMuted()
  return sfxMuted
end

-- 音乐开关（设置面板「音乐」）。关掉时停掉当前 BGM（记住曲目名），开启时若之前有曲目则续播。
function A.setBgmMuted(v)
  v = v and true or false
  if bgmMuted == v then return false end
  bgmMuted = v
  if backend == nil then return true end
  if bgmMuted then
    if bgm.handle ~= nil then backend.stop(bgm.handle) end
    bgm.handle = nil
  elseif bgmWanted ~= nil and bgmWanted ~= "" then
    local id = ids[bgmWanted]
    if id ~= nil then bgm.handle = backend.play2d(id); bgmId = id end
    bgm.name = bgmWanted
  end
  return true
end

function A.isBgmMuted()
  return bgmMuted
end

function A.setBgm(name)
  if backend == nil then return false end
  bgmWanted = name
  if bgmMuted then
    if bgm.handle ~= nil then backend.stop(bgm.handle); bgm.handle = nil end
    bgm.name = nil
    bgmId = nil
    return true
  end
  if bgm.name == name then return false end
  local newId = nil
  if name ~= nil and name ~= "" then newId = ids[name] end
  -- 不同名字但解析到**同一个音频 ID**：只换名字，不停止 / 不重播（避免同一首曲子被从头重放）
  if newId ~= nil and newId == bgmId then
    bgm.name = name
    return true
  end
  if bgm.handle ~= nil then
    backend.stop(bgm.handle)
    bgm.handle = nil
  end
  bgm.name = name
  bgmId = nil
  if newId ~= nil then
    bgm.handle = backend.play2d(newId)
    bgmId = newId
  end
  return true
end

function A.stopBgm()
  if backend == nil then return false end
  if bgm.name == nil and bgm.handle == nil then return false end
  if bgm.handle ~= nil then backend.stop(bgm.handle) end
  bgm.name = nil
  bgm.handle = nil
  bgmId = nil
  return true
end

function A.currentBgm()
  return bgm.name
end

return A
