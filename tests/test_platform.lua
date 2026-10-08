--[[
  平台层冒烟测试（在标准 Lua 里模拟千星奇域运行时）

  目的：静态检查查不出"运行期 nil 索引 / 时序错误"。本测试用桩件替换
  script / game / Enum / Color / typeof / printerr，加载单文件产物
  tank_trouble.lua，按真实帧率驱动若干帧，验证：

    1. OnInit / OnStart / OnLevelUpdate 全程不报错
    2. 按键监听注册成功，且回调能改变输入状态
    3. 回合会推进（日志出现"新回合"）
    4. 计分 HUD 会被刷新，且分数会增长（回合结算生效）
    5. 控件池不会无限增长（无每回合泄漏）

  前置：先运行 tools\bundle.cmd 生成 tank_trouble.lua。
  运行：lua tests\test_platform.lua
]]

-- ============================================================
-- 桩件：千星奇域运行时
-- ============================================================
local created = 0
local allControls = {}

local function makeControl(prefab)
  local c = {
    prefab = prefab,
    sizeDeltaX = 0, sizeDeltaY = 0,
    visible = true,
    imageType = nil, imageColor = nil,
    text = nil, fontSize = nil, fontColor = nil,
    enableOutline = nil, outlineColor = nil, horizontalAlignment = nil,
  }
  function c:SetAnchorMin() end
  function c:SetAnchorMax() end
  function c:SetPivot() end
  function c:SetSizeDelta(w, h) self.sizeDeltaX, self.sizeDeltaY = w, h end
  function c:SetAnchoredPosition() end
  function c:SetLocalRotation() end
  function c:SetVisible(v) self.visible = v end
  created = created + 1
  allControls[#allControls + 1] = c
  return c
end

local listeners = {}   -- eventName -> callback

game = {
  InstantiateClientUIControl = function(prefab, parent)
    assert(parent ~= nil, "InstantiateClientUIControl 的 parent 为空")
    return makeControl(prefab)
  end,
  PlayAudio2D = function() end,
}

Enum = {
  ImageType = { Basic = "Basic", Stretch = "Stretch" },
  TextHorizontalAlignment = { Left = "Left", Middle = "Middle", Right = "Right" },
  TextVerticalAlignment = { Top = "Top", Middle = "Middle", Bottom = "Bottom" },
  -- 任意名字都返回自身，等价于"运行时存在该按键事件"
  KeyEventType = setmetatable({}, { __index = function(_, k) return k end }),
}

Color = setmetatable({}, {
  __call = function(_, r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
  __index = {
    ToRGBA = function(c) return c.r, c.g, c.b, c.a end,
    FromRGB = function(r, g, b) return { r = r, g = g, b = b, a = 255 } end,
  },
})

typeof = function(v) return type(v) end
printerr = function(...) print("[printerr]", ...) end

local host = makeControl("container")
host.disableKeyEventPassthrough = false
function host:AddKeyEventListener(ev, cb) listeners[ev] = cb end

script = {
  object = host,
  EnableUpdate = function() end,
}

-- ============================================================
-- 载入单文件产物
-- ============================================================
local path = arg and arg[1] or "tank_trouble.lua"
local chunk, loadErr = loadfile(path)
if chunk == nil then
  print("[FAIL] 无法加载 " .. path .. "：" .. tostring(loadErr))
  print("       请先运行 tools\\bundle.cmd 生成单文件产物。")
  os.exit(1)
end

local okLoad, loadRunErr = pcall(chunk)
if not okLoad then
  print("[FAIL] 执行 " .. path .. " 报错：" .. tostring(loadRunErr))
  os.exit(1)
end

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("[ok] " .. name .. (detail and ("（" .. detail .. "）") or ""))
  else
    failures = failures + 1
    print("[FAIL] " .. name .. (detail and ("（" .. detail .. "）") or ""))
  end
end

-- ============================================================
-- 日志捕获（用于统计回合数）
-- ============================================================
local roundLogs = 0
local realPrint = print
-- 边输出边计数：既保留测试输出，又能统计开局日志。
-- 只匹配游戏自身的回合日志前缀，避免把断言文案（"新回合次数="）也算进去。
local ROUND_MARK = "[坦克动荡] 新回合："
print = function(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  local line = table.concat(parts, " ")
  if line:find(ROUND_MARK, 1, true) then roundLogs = roundLogs + 1 end
  realPrint(...)
end

-- ============================================================
-- 驱动
-- ============================================================
local function frame(n)
  for _ = 1, n do OnLevelUpdate(1 / 25) end
end

local function press(name) local cb = listeners[name]; if cb then cb() end end

-- 开火 / 确认键由平台层按候选顺序挑「运行时第一个存在的事件」，测试必须按同一顺序
-- 取真正注册成功的那一个，否则 press 会落到未注册的事件名上变成空操作。
local FIRE_DOWN = { "KeyboardCharacterSkill2KeyDown", "KeyboardNormalAttackKeyDown", "KeyboardJumpKeyDown" }
local FIRE_UP   = { "KeyboardCharacterSkill2KeyUp", "KeyboardNormalAttackKeyUp", "KeyboardJumpKeyUp" }
local function pressFirst(names)
  for i = 1, #names do
    local cb = listeners[names[i]]
    if cb ~= nil then cb(); return names[i] end
  end
  return nil
end
-- 单击确认：按下 → 推进一帧 → 抬起 → 再推进一帧（与真实按键边沿一致）
local function tapConfirm()
  pressFirst(FIRE_DOWN); frame(1)
  pressFirst(FIRE_UP);   frame(1)
end

local okStart, errStart = pcall(function()
  OnInit()
  OnStart()
end)

check("OnInit / OnStart 不报错", okStart, okStart and nil or tostring(errStart))
if not okStart then os.exit(1) end

check("注册了移动 / 开火按键监听", next(listeners) ~= nil,
  "共 " .. tostring((function() local n = 0 for _ in pairs(listeners) do n = n + 1 end return n end)()) .. " 个事件")

-- 开局应停在主菜单，不自动开局
check("开局停在主菜单（未自动开局）", roundLogs == 0, "新回合次数=" .. roundLogs)

local function findText(s)
  for i = 1, #allControls do
    if allControls[i].text == s then return allControls[i] end
  end
  return nil
end
local titleCtl = findText("坦克动荡")
check("主菜单标题可见", titleCtl ~= nil and titleCtl.visible == true)

-- 主菜单导航：设置页 → 切换 → 返回 → 关于页 → 返回 → 开始游戏
local okMenu, errMenu = pcall(function()
  press("KeyboardMoveBackwardKeyDown"); frame(1); press("KeyboardMoveBackwardKeyUp"); frame(1)  -- 选中「设置」
  tapConfirm()                                                                                 -- 进入设置
  press("KeyboardMoveRightKeyDown"); frame(1); press("KeyboardMoveRightKeyUp"); frame(1)       -- 切换首行
  press("KeyboardCharacterSkill3KeyDown"); frame(1)                                            -- R 返回主菜单
  press("KeyboardMoveBackwardKeyDown"); frame(1); press("KeyboardMoveBackwardKeyUp"); frame(1) -- 选中「关于」
  tapConfirm()                                                                                 -- 进入关于
  tapConfirm()                                                                                 -- 返回主菜单
  press("KeyboardMoveForwardKeyDown"); frame(1); press("KeyboardMoveForwardKeyUp"); frame(1)   -- 上移到「设置」
  press("KeyboardMoveForwardKeyDown"); frame(1); press("KeyboardMoveForwardKeyUp"); frame(1)   -- 上移到「开始游戏」
  tapConfirm()                                                                                 -- 开始游戏
end)

check("菜单 / 设置 / 关于 导航不报错", okMenu, okMenu and nil or tostring(errMenu))
check("确认「开始游戏」后开局", roundLogs >= 1, "新回合次数=" .. roundLogs)
check("开局后主菜单已隐藏", titleCtl ~= nil and titleCtl.visible == false)

-- 按住"前进"跑一段
local okRun, errRun = pcall(function()
  press("KeyboardMoveForwardKeyDown")
  frame(120)
  press("KeyboardMoveForwardKeyUp")
end)

check("按住前进 120 帧不报错", okRun, okRun and nil or tostring(errRun))

-- 对战中打开设置（暂停）再返回
local okPause, errPause = pcall(function()
  press("KeyboardCharacterSkill3KeyDown"); frame(1)                                            -- 打开设置
  press("KeyboardMoveBackwardKeyDown"); frame(1); press("KeyboardMoveBackwardKeyUp"); frame(1)
  press("KeyboardMoveLeftKeyDown"); frame(1); press("KeyboardMoveLeftKeyUp"); frame(1)         -- 切换
  press("KeyboardCharacterSkill3KeyDown"); frame(1)                                            -- 返回对战
end)

check("对战中设置面板 暂停 / 返回 不报错", okPause, okPause and nil or tostring(errPause))

-- 持续开火 + 移动，长跑
local okLong, errLong = pcall(function()
  press("KeyboardMoveForwardKeyDown")
  pressFirst(FIRE_DOWN)
  frame(6000)
end)

check("开火 + 移动长跑 6000 帧不报错", okLong, okLong and nil or tostring(errLong))

-- ============================================================
-- 结果断言
-- ============================================================
check("回合推进（日志出现新回合）", roundLogs >= 1, "新回合次数=" .. roundLogs)

-- 计分 HUD：形如 "红 0   :   0 绿"
local scoreA, scoreB
for i = 1, #allControls do
  local t = allControls[i].text
  if type(t) == "string" then
    local a, b = t:match("红%s*(%d+)%s*:%s*(%d+)%s*绿")
    if a ~= nil then scoreA, scoreB = tonumber(a), tonumber(b) end
  end
end
check("计分 HUD 已刷新", scoreA ~= nil, "红=" .. tostring(scoreA) .. " 绿=" .. tostring(scoreB))
check("分数已增长（回合结算生效）",
  (scoreA or 0) + (scoreB or 0) > 0,
  "红=" .. tostring(scoreA) .. " 绿=" .. tostring(scoreB))

-- 控件池：长跑后总数应趋于稳定，不应随回合线性增长
local after = created
check("控件池未无限增长", after < 4000, "累计创建控件=" .. after)

local okDestroy, errDestroy = pcall(OnDestroy)

check("OnDestroy 不报错", okDestroy, okDestroy and nil or tostring(errDestroy))

print("")
if failures == 0 then
  print("全部通过。")
  os.exit(0)
else
  print("存在 " .. failures .. " 项失败。")
  os.exit(1)
end