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
