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

-- 本文件经由 __TT_DEBUG 句柄直接读写平台层内部状态（动态结构、无类型声明），静态检查的
-- need-check-nil / undefined-field 对它纯属噪音（上百条）⇒ 整文件关闭这两条；
-- 运行期正确性由下面的断言与「全程不报错」检查保证（任何 nil 索引都会立刻炸出来）。
---@diagnostic disable: need-check-nil, undefined-field

-- ============================================================
-- 固定随机种子（保证测试可复现）
--   平台层 OnInit 会用 os.time() 播种 math.random（见 platform/game.lua ⑰）。
--   真机需要每局不同，但测试必须可重复：把 os.time 固定成常量，
--   使 AI 对战、迷宫生成、补给箱选点在每次运行中完全一致。
-- ============================================================
---@diagnostic disable-next-line: duplicate-set-field
os.time = function() return 20261009 end

-- ============================================================
-- 桩件：千星奇域运行时
-- ============================================================
local created = 0
local allCtl = {}   -- 全部控件（按创建顺序）—— 供「可见控件数」回归断言用（残留控件=色块）
--- 当前可见控件数（桩件里 visible 默认 true，SetVisible(false) 后不再计入）
local function visibleCount()
  local n = 0
  for i = 1, #allCtl do if allCtl[i].visible ~= false then n = n + 1 end end
  return n
end
-- 光标检测区域（CursorEventArea）桩件记录：触屏输入层实例化后登记在此，供末尾断言。
local cursorAreas = {}

local function makeControl(prefab)
  local c = {
    prefab = prefab,
    sizeDeltaX = 0, sizeDeltaY = 0,
    visible = true,
    imageType = nil, imageColor = nil,
    text = nil, fontSize = nil, fontColor = nil,
    enableOutline = nil, outlineColor = nil, horizontalAlignment = nil,
    raycastTarget = true, showCursor = false,
    cursorListeners = {},   -- eventType -> { callback, ... }（桩件版 CursorEventArea）
  }
  function c:SetAnchorMin() end
  function c:SetAnchorMax() end
  function c:SetPivot() end
  function c:SetSizeDelta(w, h) self.sizeDeltaX, self.sizeDeltaY = w, h end
  function c:SetAnchoredPosition() end
  function c:SetLocalRotation() end
  function c:SetLocalScale() end
  function c:SetVisible(v) self.visible = v end
  function c:SetActive() end
  function c:SetAsLastSibling() end
  -- ClientUICursorEventAreaControl 方法（官方文档 §18，L826-830）
  function c:AddCursorEventListener(ev, cb)
    local t = self.cursorListeners[ev]
    if t == nil then t = {}; self.cursorListeners[ev] = t end
    t[#t + 1] = cb
  end
  function c:RemoveCursorEventListener(ev, cb)
    local t = self.cursorListeners[ev]
    if t == nil then return end
    for i = #t, 1, -1 do if t[i] == cb then table.remove(t, i) end end
  end
  function c:RemoveCursorEventListeners(ev) self.cursorListeners[ev] = nil end
  function c:RemoveAllCursorEventListeners() self.cursorListeners = {} end
  function c:SimulateCursorClick() end
  -- ClientUIImageControl:SetImage（官方文档 §14）：记录调用，供「单图片模板 + SetImage」断言
  function c:SetImage(src, id) self.lastSetImage = { src = src, id = id } end
  if prefab == 1073741914 then cursorAreas[#cursorAreas + 1] = c end   -- PREFAB.CURSOR_AREA
  created = created + 1
  allCtl[#allCtl + 1] = c
  return c
end

local listeners = {}   -- eventName -> callback
--
-- 联机相关桩件：关卡/玩家自定义变量值（测试注入）+ 变量变化回调登记表
local customVars = {}
local customVarHandlers = {}
local signalLog = {}   -- 记录 ServerSignal 调用：{ {name=, args={{方法,值},...}, sent=}, ... }
local cursorPos = nil  -- 桩件光标（画布坐标）；nil = 无光标（readCursor 会安全回退）

game = {
  InstantiateClientUIControl = function(prefab, parent)
    assert(parent ~= nil, "InstantiateClientUIControl 的 parent 为空")
    return makeControl(prefab)
  end,
  PrintClientUITree = function() end,
  PlayAudio2D = function() return 1 end,
  StopAudio = function() end,
  IsAudioAlive = function() return true end,
  -- 设备 / 画布 / 摇杆（触屏采集探针会读取；官方文档 L186/L195/L2298 附近）
  GetDevice = function() return "Mobile" end,
  GetUICanvasSize = function() return 1920, 1080 end,
  GetControllerLeftStickAxis = function() return 0, 0 end,
  -- 全局自定义变量（联机：TT2_PLAYERS / TT2_MAZE 由测试注入 customVars）
  GetGlobalCustomVariableValue = function(entityType, name) return customVars[name] end,
  -- 光标位置（画布坐标，原点左下）：供「点 ◀▶ 三角」的回归测试
  GetCursorUIPos = function()
    if cursorPos == nil then return nil, nil end
    return cursorPos.x, cursorPos.y
  end,
  ServerSignal = function(name)
    local rec = { name = name, args = {} }
    signalLog[#signalLog + 1] = rec
    local sig = {}
    for _, m in ipairs({ "AddInt", "AddFloat", "AddString", "AddBool", "AddIntList" }) do
      sig[m] = function(self, v) rec.args[#rec.args + 1] = { m, v } end
    end
    sig.SendSignal = function() rec.sent = true end
    return sig
  end,
}

Enum = {
  ImageType = { Basic = "Basic", Stretch = "Stretch" },
  TextHorizontalAlignment = { Left = "Left", Middle = "Middle", Right = "Right" },
  TextVerticalAlignment = { Top = "Top", Middle = "Middle", Bottom = "Bottom" },
  Device = {
    KeyboardAndMouse = "KeyboardAndMouse", Mobile = "Mobile",
    Controller = "Controller", MobileController = "MobileController",
  },
  CursorEventType = {
    CursorDown = "CursorDown", CursorUp = "CursorUp",
    CursorEnter = "CursorEnter", CursorExit = "CursorExit",
    CursorDrag = "CursorDrag", CursorBeginDrag = "CursorBeginDrag",
    CursorEndDrag = "CursorEndDrag", CursorClick = "CursorClick",
  },
  -- 任意名字都返回自身，等价于"运行时存在该按键事件"
  KeyEventType = setmetatable({}, { __index = function(_, k) return k end }),
  -- 自定义变量实体类型（Level / PlayerSelf / AvatarSelf）
  CustomVariableEntityType = setmetatable({}, { __index = function(_, k) return k end }),
  -- 图片来源（图片控件 SetImage 用；StaticReference = 静态引用）
  ImageSource = setmetatable({}, { __index = function(_, k) return k end }),
  -- 按键提示控件（KeyHintControl）用到的两个枚举（官方 API §26）
  KeyboardKeyCode = setmetatable({}, { __index = function(_, k) return k end }),
  ControllerKeyCode = setmetatable({}, { __index = function(_, k) return k end }),
}

Color = setmetatable({}, {
  __call = function(_, r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
  __index = {
    ToRGBA = function(c) return c.r, c.g, c.b, c.a end,
    FromRGB = function(r, g, b) return { r = r, g = g, b = b, a = 255 } end,
    -- 官方文档 139-148 行：Color.FromRGBA 与 Color(r,g,b,a) 并存，桩件必须一并实现，
    -- 否则被 pcall 包住的赋值会静默失败，测试无法反映真实行为。
    FromRGBA = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
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
  RegisterServerSignalHandler = function() end,
  UnregisterServerSignalHandler = function() end,
  RegisterCustomVariableChangedHandler = function(entityType, name, cb)
    customVarHandlers[#customVarHandlers + 1] = { name = name, cb = cb }
  end,
  UnregisterCustomVariableChangedHandler = function() end,
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
-- 菜单确认已统一为 **F（KeyboardInteractKey）** + 鼠标左键；F 为首选。
local FIRE_DOWN = { "KeyboardInteractKeyDown", "KeyboardNormalAttackKeyDown" }
local FIRE_UP   = { "KeyboardInteractKeyUp", "KeyboardNormalAttackKeyUp" }
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

-- 触屏输入层（移动端）：应实例化 1 个 CursorEventArea 并注册 3 个触点事件，
-- 且用假 CursorEventData 驱动回调不报错（仅验证桩件通路）。
-- ⚠️ 取**最后一个**：模板自检（selfCheckPrefabs）也会实例化一次 CURSOR_AREA 探针并立刻销毁。
local probeArea = cursorAreas[#cursorAreas]
check("触屏输入：CursorEventArea 已实例化", probeArea ~= nil, "共 " .. #cursorAreas .. " 个")
if probeArea ~= nil then
  local nEv = 0
  for _ in pairs(probeArea.cursorListeners) do nEv = nEv + 1 end
  check("触屏输入：已注册 3 个触点事件", nEv == 3, "实际 " .. nEv)
  check("触屏输入：raycastTarget 已置真", probeArea.raycastTarget == true)
  local fakeData = {
    dragging = false, touchId = 3,
    GetUIPos = function() return 100.5, 200.5 end,
    GetPressUIPos = function() return 90.0, 190.0 end,
    GetUIPosDelta = function() return 1.5, 2.5 end,
  }
  local okCb = pcall(function()
    -- 按固定顺序触发（确保最后是 Up，结束时不残留「按下」状态）
    local order = { "CursorDown", "CursorDrag", "CursorUp" }
    for i = 1, #order do
      local cbs = probeArea.cursorListeners[order[i]]
      if cbs ~= nil then for j = 1, #cbs do cbs[j](fakeData) end end
    end
  end)
  check("触屏输入：回调可安全执行（含 UIPos 读取）", okCb)
end


-- 开局应停在主菜单，不自动开局
check("开局停在主菜单（未自动开局）", roundLogs == 0, "新回合次数=" .. roundLogs)

-- 文字已改用「线段拼字」（见 platform/game.lua makeLabel），控件上不再有 .text 可供扫描。
-- 平台层通过全局 __TT_DEBUG 暴露承载语义文本的 Label 组，测试直接回读其 .text / .visible。
-- 下句：调试句柄内部结构随实现变化，这里按 any 用（静态类型对测试无价值）。
---@type any
local DBG = __TT_DEBUG or {}
-- 触屏输入层断言已过：后续流程改按「桌面端」跑 —— 触屏端「三人对战」不可用、且设置面板的行不同
-- （控制方式 / 按键设置 → 控制模式），桩件只覆盖一条设备分支；移动端差异需真机验证。
if DBG.G ~= nil then DBG.G.touchMode = false end
local MENU_L, HUD_L = DBG.MENU, DBG.hud
local titleLabel = MENU_L and MENU_L.menuTexts and MENU_L.menuTexts[1]
check("主菜单标题可见",
  titleLabel ~= nil and titleLabel.text == "坦克动荡" and titleLabel.visible == true)

-- 「菜单」按钮 + 按键提示控件（KeyHintControl）应已创建；主菜单页不显示（进入子页才出现）。
--   标签文案照原版 frame_53 = 「菜单」（原为「返回」）。
check("返回按钮 + 按键提示已创建",
  MENU_L ~= nil and MENU_L.back ~= nil and MENU_L.back.hint ~= nil
    and #MENU_L.back.parts > 0 and MENU_L.back.label.text == "菜单")
check("主菜单页不显示返回按钮",
  MENU_L ~= nil and MENU_L.back ~= nil and MENU_L.back.parts[1].ctl.visible == false)

-- 按键设置页（2026-10-11 二次重构）：7 行 = 鼠标操控 + **6 个可自定义按键**
--   （方案 1 的 前进/后退/左转/右转/开火 + 方案 2 的开火）+ 底部「不可绑定的按键」清单。
--   已取消「预设键位」行；空格不可绑定（被游戏内「暂停」占用）。
check("按键设置页结构（7 行 = 鼠标操控 + 6 个可调键 + 不可绑定清单）",
  MENU_L ~= nil and #MENU_L.keyRows == 7 and #MENU_L.keyListTexts >= 2)
local okKeyRows = true
if MENU_L ~= nil then
  local want = { { 1, "fwd" }, { 1, "back" }, { 1, "left" }, { 1, "right" }, { 1, "fire" }, { 2, "fire" } }
  for i = 1, #want do
    local r = MENU_L.keyRows[i + 1]
    if r == nil or r.kind ~= "action" or r.scheme ~= want[i][1] or r.action ~= want[i][2] then
      okKeyRows = false
    end
  end
end
check("按键设置页 6 个可调按键（含方向键玩家开火）顺序正确", okKeyRows)

-- 主菜单导航：**按条目实际位置**做二维方向移动（左/右/上/下各走该方向上最近的条目）。
-- 横幅站位：1 单人(-230,20) / 2 双人(0,20) / 3 三人(230,20) / 4 双人+电脑(0,-112)；5 齿轮 / 6 音效在右上。
local function navRight() press("KeyboardMoveRightKeyDown"); frame(1); press("KeyboardMoveRightKeyUp"); frame(1) end
local function navLeft()  press("KeyboardMoveLeftKeyDown");  frame(1); press("KeyboardMoveLeftKeyUp");  frame(1) end

local okMenu, errMenu = pcall(function()
  navRight()                                                                                    -- sel 1→2「双人对战」
  navLeft()                                                                                     -- sel 2→1「单人玩家」
  tapConfirm()                                                                                  -- 进入准备页（原版 controls1Player）
  -- 单机准备页**不该**显示「按键设置 / 其他设置」（用户 2026-10-12：这两个入口专属联机）
  assert(DBG.G == nil or DBG.G.online ~= true, "前置：此处应为单机")
  assert(MENU_L.readyBtns[1].bar.visible == false, "单机准备页不该显示「按键设置」按钮")
  assert(MENU_L.readyBtns[2].bar.visible == false, "单机准备页不该显示「其他设置」按钮")
  -- 准备页：红方（1P）按 Q 加入；莱卡为 AI 自动加入 → 加入齐直接开局（原版无 3-2-1-GO）
  press("KeyboardCharacterSkill2KeyDown"); frame(1)
  press("KeyboardCharacterSkill2KeyUp");   frame(1)
end)

check("主菜单导航 / 开局 不报错", okMenu, okMenu and nil or tostring(errMenu))
check("确认「单人游戏」并加入后开局", roundLogs >= 1, "新回合次数=" .. roundLogs)

-- 结算状态预置（用户 2026-10-15 规则；官方《关卡结算》二：状态可动态改、结算取当时值）：
--   **单机**：任意玩一局、无论模式与输赢，退出都算「已完成」⇒ 开赛即上报 TT2_SET_WIN（预置「胜利」）。
--   放在 beginMatch 里 ⇒ 只有真正开了一局才上报（在主菜单转悠就退出不算已游玩）。
local nSetWin = 0
for i = 1, #signalLog do
  if signalLog[i].name == "TT2_SET_WIN" and signalLog[i].sent then nSetWin = nSetWin + 1 end
end
check("单机开赛上报 TT2_SET_WIN（预置「胜利」⇒ 何时退出都算已完成）", nSetWin >= 1, "次数=" .. nSetWin)
check("开局后主菜单已隐藏", titleLabel ~= nil and titleLabel.visible == false)

-- 进入对战期后的控件累计创建基线：用于判断"长跑是否泄漏"（对比增量，而非绝对值）。
local createdPlayBaseline = created

-- 按住"前进"跑一段
local okRun, errRun = pcall(function()
  press("KeyboardMoveForwardKeyDown")
  frame(120)
  press("KeyboardMoveForwardKeyUp")
end)

check("按住前进 120 帧不报错", okRun, okRun and nil or tostring(errRun))

-- 对战期：应显示「返回」按钮（位置切到 PLAY 位、且控件可见；点击 = 返回主菜单）
--   注：留白足够时会被"挪到竞技场外的左侧"（见 refreshMenu 的 playing 分支），故比较坐标而非表身份。
local bp = MENU_L.backPos
local okBack = bp ~= nil and bp.y == MENU_L.BACK_POS_PLAY.y
  and bp.x <= MENU_L.BACK_POS_PLAY.x
  and MENU_L.back ~= nil and MENU_L.back.parts[1] ~= nil
  and MENU_L.back.parts[1].ctl.visible == true
check("对战期返回按钮显示在左上角", okBack,
  okBack and ("位置=" .. tostring(bp.x) .. "," .. tostring(bp.y)) or "位置异常")

-- 局内按 R 返回主菜单（原版 leaveGame 的本地等价：千星奇域 ESC 不可用）
local okBack, errBack = pcall(function()
  press("KeyboardCharacterSkill3KeyDown"); frame(1)                                             -- R：返回主菜单
end)

check("局内按 R 返回主菜单 不报错", okBack, okBack and nil or tostring(errBack))
check("返回主菜单后主菜单重新可见", titleLabel ~= nil and titleLabel.visible == true)
-- 返回主菜单后：计分板（数字 Label + 迷你坦克图标）全部隐藏
local scoreHidden = true
if HUD_L and HUD_L.scoreLabels then
  for i = 1, #HUD_L.scoreLabels do
    local lab = HUD_L.scoreLabels[i]
    if lab ~= nil and lab.visible ~= false then scoreHidden = false end
  end
end
check("返回主菜单后计分 HUD 已隐藏", scoreHidden)

-- 三人模式冒烟：验证第 3 台「鼠标坦克」路径（MODE_SLOTS.trio / 3 行准备页 / 鼠标左键加入 / 鼠标坦克帧驱动）。
-- 平台桩件无 GetCursorUIPos，mousePos 会安全回退 -99999，故此处只验证「不报错 + 槽位配置正确」。
local okTrio, errTrio = pcall(function()
  navRight()                                         -- sel 1→2「双人对战」
  navRight()                                         -- sel 2→3「三人对战」
  tapConfirm()                                       -- 进入三人准备页
  press("KeyboardCharacterSkill2KeyDown"); frame(1)  -- P1 按 Q 加入
  press("KeyboardCharacterSkill2KeyUp");   frame(1)
  press("KeyboardCraftspersonKey33Down");  frame(1)  -- P2 按 , 加入（方向键方案开火默认 = ","）
  press("KeyboardCraftspersonKey33Up");    frame(1)
  press("KeyboardNormalAttackKeyDown");    frame(1)  -- P3 按鼠标左键加入
  press("KeyboardNormalAttackKeyUp");      frame(1)
  frame(60)                                          -- 三人对局跑 60 帧（覆盖鼠标坦克帧驱动 + 准星）
end)
check("三人模式：三人加入后开局 不报错", okTrio, okTrio and nil or tostring(errTrio))

local G_T = DBG.G
check("三人模式：部署了第 3 台鼠标坦克",
  okTrio and G_T ~= nil and G_T.tanks ~= nil and #G_T.tanks == 3
    and G_T.tanks[3] ~= nil and G_T.tanks[3].mouseTank == true,
  okTrio and ("坦克数=" .. tostring(G_T and G_T.tanks and #G_T.tanks)) or nil)

-- 三人 HUD 应为 3 个计分 Label（布局镜像）
check("三人模式：计分 HUD 为 3 个数字",
  okTrio and HUD_L ~= nil and HUD_L.scoreLabels ~= nil and #HUD_L.scoreLabels == 3,
  okTrio and ("HUD 数字=" .. tostring(HUD_L and HUD_L.scoreLabels and #HUD_L.scoreLabels)) or nil)

local okTrioBack, errTrioBack = pcall(function()
  press("KeyboardCharacterSkill3KeyDown"); frame(1)  -- R：返回主菜单
end)
check("三人模式：局内按 R 返回主菜单 不报错", okTrioBack, okTrioBack and nil or tostring(errTrioBack))

-- 返回主菜单后可再次开局（供长跑测试）
local roundsBeforeReenter = roundLogs
local okReenter, errReenter = pcall(function()
  tapConfirm()                                                                                  -- 进入准备页
  press("KeyboardCharacterSkill2KeyDown"); frame(1)
  press("KeyboardCharacterSkill2KeyUp");   frame(1)
end)

check("返回主菜单后可再次开局", okReenter and roundLogs > roundsBeforeReenter,
  okReenter and ("新回合次数=" .. roundLogs) or tostring(errReenter))

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

-- 计分 HUD：每个玩家一个数字 Label（原版 playerScoreBoard = 迷你坦克图标 + 数字）
local labels = (HUD_L and HUD_L.scoreLabels) or {}
local scoreA = tonumber((labels[1] and labels[1].text) or "")
local scoreB = tonumber((labels[2] and labels[2].text) or "")
check("计分 HUD 已刷新", scoreA ~= nil and scoreB ~= nil,
  tostring(labels[1] and labels[1].text) .. " / " .. tostring(labels[2] and labels[2].text))
check("分数已增长（回合结算生效）",
  (scoreA or 0) + (scoreB or 0) > 0,
  "红=" .. tostring(scoreA) .. " 对手=" .. tostring(scoreB))

-- 单机「完成关卡」：**无胜利条件、无计时器**；完成一次回合结算即置 `match.completed`
check("单机：无计时器且完成一场即置 completed",
  DBG.G ~= nil and DBG.G.match ~= nil and DBG.G.match.timer == nil and DBG.G.match.completed == true,
  DBG.G ~= nil and DBG.G.match ~= nil
    and ("timer=" .. tostring(DBG.G.match.timer) .. " completed=" .. tostring(DBG.G.match.completed)) or nil)

-- 计分板三件套：每辆坦克旁都有 名字 / 分数 / 延迟 标签（单机下延迟显示 --）
check("计分板 名字/分数/延迟 标签齐备",
  HUD_L ~= nil and #HUD_L.nameLabels >= 2 and #HUD_L.pingLabels >= 2
    and (HUD_L.nameLabels[1].text or "") ~= "" and HUD_L.pingLabels[1].text == "--",
  HUD_L ~= nil and ("名字=" .. tostring(HUD_L.nameLabels[1] and HUD_L.nameLabels[1].text)
    .. " 延迟=" .. tostring(HUD_L.pingLabels[1] and HUD_L.pingLabels[1].text)) or nil)

-- 控件池：对战期长跑后累计创建数不应随回合线性增长（形空控件全部走池复用）。
-- 实测 9 回合增量约 38（HUD 文字重建的峰值差），真泄漏会按回合线性累加，故阈值取 1000。
local grown = created - createdPlayBaseline
check("控件池未无限增长", grown < 1000,
  "对战期新增=" .. grown .. "（累计 " .. created .. "）")

-- 回归（§6.22）：切页时输入边沿缓存必须同步为「当前仍按住」，否则按住确认键进入新页时
--   新页首行会被当成一次新按下而自动确认（曾表现为：按住齿轮进设置页 → 自动点开「控制方式」）。
local okHold, errHold = pcall(function()
  -- 先释放长跑时按住的方向 / 开火键，否则「按住确认键」没有新的按下边沿
  press("KeyboardMoveForwardKeyUp")
  pressFirst(FIRE_UP); frame(2)
  press("KeyboardCharacterSkill3KeyDown"); frame(1)   -- R 返回主菜单
  press("KeyboardCharacterSkill3KeyUp");   frame(1)
  MENU_L.sel = #MENU_L.MODES + 1                      -- 选中齿轮（设置入口）
  press("KeyboardInteractKeyDown")                    -- 按住确认键不放
  frame(2)
  press("KeyboardInteractKeyUp"); frame(1)
end)
check("按住确认键进设置页不误触首行", okHold and MENU_L.phase == "settings",
  okHold and ("phase=" .. tostring(MENU_L.phase)) or tostring(errHold))

-- 右下角按钮文案 + 「回到主界面」行（用户 2026-10-12）：
--   设置界面（非战斗打开）=「返回」，且**不显示**末行「回到主界面」。
local okBackLbl, errBackLbl = pcall(function()
  assert(MENU_L.phase == "settings", "前置：应处于设置页，实为 " .. tostring(MENU_L.phase))
  assert(MENU_L.back.label.text == "返回", "设置界面按钮应为「返回」，实为 " .. tostring(MENU_L.back.label.text))
  assert(MENU_L.setRowCount() == #MENU_L.setRows - 1, "非战斗打开时不应计入「回到主界面」行")
  local quitRow = MENU_L.setRows[#MENU_L.setRows]
  assert(quitRow.kind == "quitToMenu" and quitRow.name.visible == false, "「回到主界面」行应隐藏")
end)
check("设置界面按钮=「返回」且不显示「回到主界面」行", okBackLbl, okBackLbl and "ok" or tostring(errBackLbl))

-- 回归（显示设置）：设置面板改为子页入口（…/对战设置/其他设置）；显示大小 / 抗锯齿 移入
--   「其他设置」页；左右切换必须真正改变整体缩放（G.uiScale）与抗锯齿数值（G.aaWidth）。
local okDisp, errDisp = pcall(function()
  local kinds = {}
  for i = 1, #MENU_L.setRows do kinds[#kinds + 1] = MENU_L.setRows[i].kind end
  local joined = table.concat(kinds, ",")
  -- 桌面/触屏两套行不同（触屏把「控制方式/按键设置」换成「控制模式」），只断言子页入口存在且有序
  assert(joined:find("rules,other", 1, true) ~= nil, "setRows=" .. joined)
  -- 「其他设置」页必须是 显示大小 / 抗锯齿 / 音乐 / 音效 四行有序
  local ok2 = {}
  for i = 1, #MENU_L.otherRows do ok2[#ok2 + 1] = MENU_L.otherRows[i].kind end
  local joinedOther = table.concat(ok2, ",")
  assert(joinedOther:find("uiScale,aa,music,sound", 1, true) ~= nil, "otherRows=" .. joinedOther)
  -- 「对战设置」页：7 个出箱武器开关 + 平滑碰撞 + 恢复默认 = 9 行
  assert(MENU_L.rulesRows ~= nil and #MENU_L.rulesRows == 9,
    "rulesRows=" .. tostring(MENU_L.rulesRows ~= nil and #MENU_L.rulesRows or -1))
  local k0 = G_T.uiScale
  MENU_L.phase = "other"
  MENU_L.stepUiScale(1)                     -- 自适应 → 0.8×
  assert(G_T.uiScale ~= k0, "缩放未变化 " .. tostring(k0))
  MENU_L.stepUiScale(-1)                    -- 回自适应
  assert(math.abs(G_T.uiScale - (G_T.uiFitScale or 1)) < 1e-6, "未回到自适应")
  local a0 = G_T.aaWidth
  MENU_L.stepAA(1)
  assert(G_T.aaWidth ~= a0, "抗锯齿未变化 " .. tostring(a0))
end)
check("设置子页：对战设置 / 其他设置 行可调", okDisp, okDisp and "ok" or tostring(errDisp))

-- 对战设置页行内容：7 个出箱武器开关 + 平滑碰撞 + 恢复默认（= 9 行）
local rr = MENU_L.rulesRows
check("对战设置页行内容正确（7 武器 + 平滑碰撞 + 恢复默认）",
  rr ~= nil and rr[1] ~= nil and rr[1].kind == "weapon"
    and rr[8] ~= nil and rr[8].kind == "smooth"
    and rr[9] ~= nil and rr[9].kind == "reset",
  rr ~= nil and (tostring(rr[1] and rr[1].kind) .. "/" .. tostring(rr[8] and rr[8].kind)
    .. "/" .. tostring(rr[9] and rr[9].kind)) or nil)

-- 准备页下方两个按钮：按键设置 / 其他设置
check("准备页下方按钮（按键设置 / 其他设置）",
  #MENU_L.readyBtns == 2 and MENU_L.readyBtns[1].kind == "keys" and MENU_L.readyBtns[2].kind == "other",
  "按钮数=" .. tostring(#MENU_L.readyBtns))

-- 「1 个图片模板 + SetImage」（官方文档 §14 ClientUIImageControl:SetImage(imageSource,imageId)）：
--   2026-10-16 起**全部形状都走这条路**（不再有 6 个形状模板，旧索引作废）。
local okShape, errShape = pcall(function()
  assert(DBG.createShape ~= nil and DBG.SHAPE_IMAGE_ID ~= nil, "未暴露 SHAPE_IMAGE_ID / createShape")
  local ids = DBG.SHAPE_IMAGE_ID
  assert(ids.square == 100001 and ids.circle == 100002 and ids.tri == 100003
    and ids.star4 == 100004 and ids.star5 == 100005 and ids.rings == 100006,
    "形状图片 ID 应为 100001~100006")
  assert(ids.gear == 100161, "齿轮图片 ID 应为 100161")
  local byImage = DBG.createShape("circle")
  assert(byImage ~= nil and byImage.lastSetImage ~= nil
    and byImage.lastSetImage.id == 100002 and byImage.lastSetImage.src == "StaticReference",
    "任何形状都应走「图片控件 + SetImage(StaticReference, id)」")
  local bySquare = DBG.createShape("square")
  assert(bySquare ~= nil and bySquare.lastSetImage ~= nil and bySquare.lastSetImage.id == 100001,
    "square 应 SetImage(…, 100001)")
end)
check("1 个图片模板 + SetImage（100001~100006 / 齿轮 100161）", okShape,
  okShape and "ok" or tostring(errShape))

-- ◀▶ 三角的**方向**语义（用户 2026-10-11 反馈）：点「◀」= 减小、点「▶」= 增大；
--   点行内其他位置不应改动；方向键 ←→ / ↑↓ 也能调整与选行。
--   实现要点：① rules/other 页必须刷新光标（否则用上一页的陈旧坐标 ⇒ 点哪都往一个方向走）；
--             ② 方向取自**命中的那个三角**，不能只判「是否点了箭头」。
local function setCursorUI(uiX, uiY)
  local k = (DBG.G and DBG.G.uiScale) or 1
  cursorPos = { x = uiX * k + 1920 / 2, y = uiY * k + 1080 / 2 }
end

local okArrow, errArrow = pcall(function()
  MENU_L.phase = "other"
  local aaIdx = nil
  for i = 1, #MENU_L.otherRows do if MENU_L.otherRows[i].kind == "aa" then aaIdx = i end end
  assert(aaIdx ~= nil, "「其他设置」页缺「抗锯齿」行")
  MENU_L.otherSel = aaIdx
  local row = MENU_L.otherRows[aaIdx]
  local function clickAt(x, y)
    setCursorUI(x, y)
    MENU_L.mousePrev = false
    press("KeyboardNormalAttackKeyDown"); frame(1)
    press("KeyboardNormalAttackKeyUp");   frame(1)
  end
  G_T.aaWidth = 2                        -- AA_OPTS = {0,1,2,3}
  clickAt(MENU_L.SET_ARROW_L, row.y)
  assert(G_T.aaWidth == 1, "点「◀」应减小，实为 " .. tostring(G_T.aaWidth))
  clickAt(MENU_L.SET_ARROW_R, row.y)
  assert(G_T.aaWidth == 2, "点「▶」应增大，实为 " .. tostring(G_T.aaWidth))
  clickAt(0, row.y)                      -- 行内非三角处
  assert(G_T.aaWidth == 2, "点行内非三角处不应改动，实为 " .. tostring(G_T.aaWidth))

  -- 方向键：← 减小 / → 增大 / ↑ 上移一行
  cursorPos = nil
  MENU_L.mousePrev = true                -- 排除鼠标边沿干扰
  press("KeyboardCraftspersonKey38Down"); frame(1); press("KeyboardCraftspersonKey38Up"); frame(1)
  assert(G_T.aaWidth == 1, "按「←」应减小，实为 " .. tostring(G_T.aaWidth))
  press("KeyboardCraftspersonKey39Down"); frame(1); press("KeyboardCraftspersonKey39Up"); frame(1)
  assert(G_T.aaWidth == 2, "按「→」应增大，实为 " .. tostring(G_T.aaWidth))
  MENU_L.otherSel = 2
  press("KeyboardCraftspersonKey36Down"); frame(1); press("KeyboardCraftspersonKey36Up"); frame(1)
  assert(MENU_L.otherSel == 1, "按「↑」应上移一行，实为 " .. tostring(MENU_L.otherSel))

  -- 到尽头：对应三角形**消失**，且不再往前走（不循环）
  MENU_L.otherSel = aaIdx
  G_T.aaWidth = 0                        -- AA_OPTS 首项
  MENU_L.refreshOtherRows()
  assert(row.arrows.left.visible == false, "已在最小值 ⇒ 左三角应隐藏")
  assert(row.arrows.right.visible == true, "右三角应仍显示")
  clickAt(MENU_L.SET_ARROW_L, row.y)     -- 尽头再点也不越界
  assert(G_T.aaWidth == 0, "首项再点「◀」不应循环，实为 " .. tostring(G_T.aaWidth))
  G_T.aaWidth = 3                        -- AA_OPTS 末项
  MENU_L.refreshOtherRows()
  assert(row.arrows.right.visible == false, "已在最大值 ⇒ 右三角应隐藏")
  clickAt(MENU_L.SET_ARROW_R, row.y)
  assert(G_T.aaWidth == 3, "末项再点「▶」不应循环，实为 " .. tostring(G_T.aaWidth))
end)
check("◀▶ 三角方向语义（左减右增 / 到尽头消失）+ 方向键导航", okArrow, okArrow and "ok" or tostring(errArrow))

-- 底部按键提示条（用户 2026-10-11）：三组文字 = 滚动 / 切换 / 确认（W/S 滚动、A/D 切换、F 确认）。
--   显示范围 = 设置面板 + 对战设置页 + 其他设置页（这三页都要用 W/S A/D F）；隐藏时整条收起。
local okHint, errHint = pcall(function()
  assert(MENU_L.placeSetHints ~= nil and MENU_L.setHintLabels ~= nil and #MENU_L.setHintLabels == 3,
    "提示条应有 3 组文字 + placeSetHints")
  local L = MENU_L.setHintLabels
  MENU_L.placeSetHints(true)
  assert(L[1].text == "滚动" and L[1].visible == true, "组 1 应为「滚动」：" .. tostring(L[1].text))
  assert(L[2].text == "切换" and L[2].visible == true, "组 2 应为「切换」：" .. tostring(L[2].text))
  assert(L[3].text == "确认" and L[3].visible == true, "组 3 应为「确认」：" .. tostring(L[3].text))
  assert(MENU_L.setHints[5] ~= nil and MENU_L.setHints[5].visible == true, "F 图标应一并显示")
  -- 隐藏时三组文字与 5 个按键图标都收起
  MENU_L.placeSetHints(false)
  assert(L[1].visible == false and L[2].visible == false and L[3].visible == false, "隐藏时文字应收起")
  assert(MENU_L.setHints[5].visible == false, "隐藏时 F 图标应收起")
  -- 集成：走真实入口（beginRules 内部会 refreshMenu ⇒ 提示条应自动重新显示）
  MENU_L.beginRules()
  assert(MENU_L.setHintLabels[1].text == "滚动" and MENU_L.setHintLabels[3].text == "确认"
    and MENU_L.setHintLabels[3].visible == true, "beginRules 后提示条未按预期显示")
end)
check("按键提示条：滚动 / 切换 / 确认（显隐 + 真实入口集成）", okHint,
  okHint and "ok" or tostring(errHint))

-- 从战斗界面用菜单键打开设置时（MENU.fromBattle = true）：多出末行「回到主界面」，
--   且激活它会**完全退回主菜单**（区别于「返回」= 继续对局）。用户 2026-10-12。
local okQuit, errQuit = pcall(function()
  MENU_L.openBattleSettings()               -- 模拟「战斗中点菜单」：fromBattle=true + phase=settings + refreshMenu
  assert(MENU_L.phase == "settings" and MENU_L.fromBattle == true, "openBattleSettings 前置失败")
  assert(MENU_L.setRowCount() == #MENU_L.setRows, "从战斗打开时应计入「回到主界面」行")
  assert(MENU_L.setRows[#MENU_L.setRows].name.visible == true, "从战斗打开时「回到主界面」行应可见")
  assert(MENU_L.back.label.text == "返回", "设置界面按钮仍应为「返回」")
  MENU_L.quitToMenu()                       -- 激活末行 → 完全退出对局回主菜单
  assert(MENU_L.phase == "menu" and MENU_L.fromBattle == false, "「回到主界面」未退回主菜单")
end)
check("从战斗打开设置：多出「回到主界面」行且可退回主菜单", okQuit, okQuit and "ok" or tostring(errQuit))

-- 回归（用户 2026-10-15）：战斗内「设置」改过的项必须**立即**作用于在场坦克，不必回主菜单重开一局。
--   根因：控制方式 / 「鼠标操控」/「平滑碰撞」都只在 applyMode（开赛时）拷进坦克，改完没人同步。
--   这里用「鼠标操控」行（瞬时 ⇄ 限速转向）验证：改完 → 回对局 ⇒ 坦克的
--   `settingsUseNewMouseControl` 必须当帧就跟着变。
local okLive, errLive = pcall(function()
  local before = G_T.tanks[1].settingsUseNewMouseControl
  MENU_L.openBattleSettings()                  -- 从战斗打开设置（fromBattle = true）
  assert(MENU_L.fromBattle == true, "前置：应从战斗打开设置")
  -- 进「按键设置」页第 1 行「鼠标操控」，按 → 切换（瞬时 / 限速转向）
  MENU_L.phase, MENU_L.keySel = "keys", 1
  press("KeyboardCraftspersonKey39Down")       -- →
  frame(1)
  press("KeyboardCraftspersonKey39Up")
  frame(1)
  assert(G_T.tanks[1].settingsUseNewMouseControl == before,
    "尚未返回对局时坦克不应改变（改的是菜单里的全局开关）")
  MENU_L.leaveBattleSettings()                 -- 返回对局
  assert(MENU_L.phase == "playing" and MENU_L.fromBattle == false, "未回到对局")
  assert(G_T.tanks[1].settingsUseNewMouseControl == (not before),
    "返回对局后「鼠标操控」应立即生效到在场坦克")
  -- 还原该开关，避免污染后续用例
  MENU_L.openBattleSettings()
  MENU_L.phase, MENU_L.keySel = "keys", 1
  press("KeyboardCraftspersonKey39Down")       -- →
  frame(1)
  press("KeyboardCraftspersonKey39Up")
  frame(1)
  MENU_L.leaveBattleSettings()
  assert(G_T.tanks[1].settingsUseNewMouseControl == before, "未能还原「鼠标操控」开关")
end)
check("战斗内改设置立即生效（鼠标操控 → 在场坦克）", okLive, okLive and "ok" or tostring(errLive))

--- 回归（用户 2026-10-15 报）：**对战中的「菜单 → 关闭菜单」必须让世界完整恢复** ——
---   症状「坦克们变成一堆色块 / 游戏无法正常运行」（根因：中途重跑完整 applyMode 会重建
---   车体/炮塔美术 + 计分 HUD，打乱控件池与叠放次序）。
---   判据：① 坦克美术**一个控件都不许重建**（对象同一）；② 关菜单后可见控件数不得变多。
local okRt, errRt = pcall(function()
  local function artList()
    local out = {}
    for i = 1, #G_T.tanks do
      local t = G_T.tanks[i]
      for _, grp in ipairs({ t.baseArt, t.turretArt }) do
        if grp ~= nil then for k = 1, #grp do out[#out + 1] = grp[k].ctl end end
      end
    end
    return out
  end
  local beforeVis = {}
  local v0, c0 = visibleCount(), #allCtl
  for i = 1, #allCtl do if allCtl[i].visible ~= false then beforeVis[allCtl[i]] = true end end
  local art0 = artList()

  MENU_L.openBattleSettings()
  frame(3)
  assert(MENU_L.phase == "settings", "前置：应从战斗打开设置")
  MENU_L.leaveBattleSettings()
  frame(3)
  assert(MENU_L.phase == "playing", "关闭菜单后应回到对局")

  -- ① 坦克美术不得重建（重建=从控件池取件 ⇒ 层级/池被搅乱 ⇒ 画面变一堆色块）
  local art1 = artList()
  assert(#art0 == #art1, "坦克美术部件数变了：" .. #art0 .. " → " .. #art1)
  for i = 1, #art0 do
    assert(art0[i] == art1[i], "第 " .. i .. " 个坦克美术部件被重建了（键鼠/鼠标操控/平滑碰撞只需改标量）")
  end

  -- ② 可见控件数不得变多（多出来的就是残留色块）
  local v1, c1 = visibleCount(), #allCtl
  local extra = {}
  for i = 1, #allCtl do
    local c = allCtl[i]
    if c.visible ~= false and beforeVis[c] ~= true then
      extra[#extra + 1] = string.format("prefab=%s size=%sx%s color=%s",
        tostring(c.prefab), tostring(c.sizeDeltaX), tostring(c.sizeDeltaY), tostring(c.imageColor))
    end
  end
  if #extra > 0 then
    print("[DIAG] 关菜单后新增可见控件 " .. #extra .. " 个：")
    for i = 1, math.min(#extra, 20) do print("  " .. extra[i]) end
  end
  assert(c1 - c0 <= 4, "开/关设置泄漏控件数：" .. (c1 - c0))
  assert(v1 <= v0, "关菜单后可见控件变多了：" .. v0 .. " → " .. v1
    .. "（多出的 " .. #extra .. " 个就是残留色块）")
end)
check("战斗内开/关菜单：坦克美术不重建 / 可见控件数不增（无残留色块）", okRt, okRt and "ok" or tostring(errRt))

-- ============================================================
-- 联机：方案 4（服务器随机表 → 迷宫）+ 计分板名字/分数/延迟 + 逃跑判负 + 颜色
--   ⚠️ 放在最后：这里会把 G.online 打开，之后不再跑单机流程。
-- ============================================================
local okOnline, errOnline = pcall(function()
  -- 服务器把「在场玩家数」写进关卡变量 TT2_PLAYERS = 2 ⇒ 客户端应切联机并直接进准备界面
  customVars.TT2_PLAYERS = 2
  MENU_L.phase = "menu"
  MENU_L.syncOnline(true)
  assert(G_T.online == true, "未进入联机模式")
  assert(MENU_L.phase == "ready", "联机应直接进准备界面，实为 " .. tostring(MENU_L.phase))
  -- 联机准备页**才**显示「按键设置 / 其他设置」两个按钮（与单机的隐藏相对）
  assert(MENU_L.readyBtns[1].bar.visible == true and MENU_L.readyBtns[2].bar.visible == true,
    "联机准备页应显示「按键设置 / 其他设置」按钮")

  -- 联机设置精简（用户 2026-10-12）：设置面板只留「按键设置 / 其他设置」；
  --   按键设置页隐藏「鼠标操控」行；鼠标固定「限速转向」。
  --   （健壮写法：桌面 4 行 / 触屏 3 行，只断言「隐藏了规则类入口、可见的只剩按键/其他」。）
  local hiddenKinds, visibleKinds = {}, {}
  for i = 1, #MENU_L.setRows do
    local row = MENU_L.setRows[i]
    if MENU_L.rowHidden(row) then hiddenKinds[#hiddenKinds + 1] = row.kind
    else visibleKinds[#visibleKinds + 1] = row.kind end
  end
  local hk = table.concat(hiddenKinds, ",")
  assert(hk:find("rules", 1, true) ~= nil, "联机应隐藏「对战设置」，实际隐藏：" .. hk)
  assert(hk:find("devices", 1, true) ~= nil or hk:find("touchMode", 1, true) ~= nil,
    "联机应隐藏「控制方式/控制模式」，实际隐藏：" .. hk)
  for i = 1, #visibleKinds do
    local k = visibleKinds[i]
    assert(k == "keys" or k == "other", "联机不该显示该设置入口：" .. k)
  end
  assert(MENU_L.setRowCount() == #visibleKinds, "可见行数应与 setRowCount 一致")
  assert(MENU_L.keyRowHidden(MENU_L.keyRows[1]) == true, "联机时「鼠标操控」行应隐藏")
  assert(MENU_L.keyRowHidden(MENU_L.keyRows[2]) == false, "动作行不应被隐藏")

  -- 30 秒准备倒计时在推进；顶部状态行含倒计时 / 颜色
  assert(MENU_L.readyTimer > 0, "联机准备应有 30 秒倒计时")
  local t0 = MENU_L.readyTimer
  frame(2)
  assert(MENU_L.readyTimer < t0, "准备倒计时未推进")
  local status = MENU_L.readyTexts[2].text or ""
  assert(status:find("准备倒计时", 1, true) ~= nil, "状态行缺倒计时：" .. status)
  assert(status:find("颜色", 1, true) ~= nil, "状态行缺颜色信息")

  -- 房主下发的迷宫表（v4：表首项 = **seq 回合号**）
  --   W=6 H=5 ⇒ 熵 (6+1)*(5+1)=42；其后每辆坦克 1 个朝向档
  local data = { 1, 6, 5, 0, 0 }          -- [seq=1, W=6, H=5, sx=0, sy=0]
  for i = 1, 42 do data[#data + 1] = i % 4 end
  data[#data + 1] = 7
  data[#data + 1] = 11
  customVars.TT2_MAZE = data
  assert(MENU_L.loadMazeData() == data, "loadMazeData 未读到数据")
  assert(G_T.mazeInts == data, "非房主应把房主最新表记进 G.mazeInts")
  assert(G_T.mazeSeqSeen == 1, "非房主应记录 seq（实为 " .. tostring(G_T.mazeSeqSeen) .. "）")
  assert(MENU_L.setMazeData({ 1, 2 }) == false, "数据不足应被拒绝")

  -- 选颜色（第 3 色） + 服务器下发的玩家名
  MENU_L.colorPick = 3
  G_T.playerName = "测试玩家"

  -- 归属（用户 2026-10-15）：本端按**自己的开火键**只点亮自己那格；
  --   对方那格**不受本地输入影响**（谁按了自己的开火键，谁的框才亮）。
  local meSlot, oppSlot = G_T.playerIndex, MENU_L.oppSlot()
  -- 统计某信号「实际发出去」的次数（signalLog 里同名且 sent=true 的条数）
  local function sent(name)
    local n = 0
    for i = 1, #signalLog do
      if signalLog[i].name == name and signalLog[i].sent then n = n + 1 end
    end
    return n
  end
  local nReady1 = sent("TT2_READY_1")
  press("KeyboardCharacterSkill2KeyDown")   -- 方案 1（字母键位）的开火键 = Q
  frame(1)
  press("KeyboardCharacterSkill2KeyUp")
  frame(1)
  assert(MENU_L.joined[meSlot] == true, "按自己的开火键应点亮自己的准备框")
  assert(MENU_L.joined[oppSlot] ~= true, "按一个键不该点亮对方的准备框（谁按自己的谁亮）")
  assert(sent("TT2_READY_1") > nReady1, "本端准备后应上传准备档（TT2_READY_1）")
  MENU_L.joined[meSlot] = nil   -- 复位（下面要继续验证「到点强制准备」这条路径）

  -- **同步倒计时**（用户 2026-10-15）：30 秒倒计时两端同步 —— 用共享时钟 TT2_BEAT 计算：
  --   剩余 = endBeat（房主在 TT2_READY_1 第 4 位发布）− 当前 TT2_BEAT ⇒ 两端读同一份心跳报文，逐秒一致。
  --   注入「心跳 = 100、房主截止刻 = 130」⇒ 剩余应为 30（而不是本地递减出来的值）。
  customVars.TT2_BEAT = 100
  customVars.TT2_READY_1 = { 1, 3, 1, 130 }
  frame(1)
  assert(G_T.beatSeen == 100, "应读到服务器心跳 TT2_BEAT（实为 " .. tostring(G_T.beatSeen) .. "）")
  assert(MENU_L.readyTimer == 30, "准备倒计时应由共享时钟算出 30（实为 " .. tostring(MENU_L.readyTimer) .. "）")
  assert(MENU_L.startTimer == 0, "准备阶段不应起 3 秒倒计时")
  customVars.TT2_BEAT = 128     -- 心跳推进 28 格 ⇒ 剩余 2
  frame(1)
  assert(MENU_L.readyTimer == 2, "剩余应随心跳同步递减（实为 " .. tostring(MENU_L.readyTimer) .. "）")

  -- 时间到（心跳到达截止刻）⇒ **所有人**强制准备（各端强制自己）⇒ 立即进 3 秒开始倒计时
  customVars.TT2_BEAT = 130
  frame(1)
  assert(MENU_L.readyTimer == 0, "到点后准备倒计时应归零")
  assert(MENU_L.joined[G_T.playerIndex] == true, "到点应强制准备好本端")
  assert(MENU_L.startTimer == 3, "到点应立即进 3 秒开始倒计时（实为 " .. tostring(MENU_L.startTimer) .. "）")
  customVars.TT2_BEAT = 133     -- 心跳再走 3 格 ⇒ 开赛
  local nEsc0 = sent("TT2_SET_ESCAPE")
  frame(1)
  assert(MENU_L.phase == "playing", "3 秒到后应开赛，实为 " .. tostring(MENU_L.phase))
  -- 用户 2026-10-16 修订：**联机**开赛只预置「逃跑合法性 = 否」⇒ 中途离开判「逃跑」；
  --   正常打完由 finishMatch 走 SET_WIN / SET_LOSE（那两条链含「合法性 = 是」+ 胜负）。
  assert(sent("TT2_SET_ESCAPE") > nEsc0, "联机开赛应预置上报 TT2_SET_ESCAPE")

  -- 非房主：开局时「还没用过任何 seq」⇒ 随后几帧就领用 seq=1 开第 1 回合（**回合由房主驱动**）
  frame(5)
  assert(G_T.mazeSeqUsed == 1, "非房主应消费 seq=1 开第 1 回合（实为 " .. tostring(G_T.mazeSeqUsed) .. "）")

  -- 对局中新表**不当场换图**（v4：只更新「最新表 + seq」，等本回合结束、seq 变化才重开）
  local data2 = { 2, 8, 8, 0, 0 }          -- [seq=2, W=8, H=8, sx=0, sy=0]
  for i = 1, 81 do data2[#data2 + 1] = i % 4 end
  assert(MENU_L.setMazeData(data2) == true, "非房主应接受新表")
  assert(G_T.mazeInts == data2, "最新表应被记录进 G.mazeInts")
  assert(G_T.mazeSeqSeen == 2, "应记录新 seq")
  assert(G_T.W == 6 and G_T.H == 5, "对局中不应当场换图（W/H 应仍是 6×5）")

  -- 非房主：补给箱是**房主权威**的镜像（走关卡变量 TT2_CRATE，不是一次性事件）——
  --   注入一张表 ⇒ 本地生成；清空 ⇒ 本地移除。
  local cell0 = G_T.reachable[1]
  customVars.TT2_CRATE = { 9, cell0.x, cell0.y, 2 }
  frame(2)
  assert(#G_T.crates == 1 and G_T.crates[1].id == 9, "非房主未按房主表生成补给箱")
  customVars.TT2_CRATE = {}
  frame(2)
  assert(#G_T.crates == 0, "非房主未按房主表移除补给箱（被捡走的箱子应消失）")

  -- 对局：迷宫必须用**下发数据**重建；联机有 10 分钟计时器；本地玩家用选定颜色
  assert(G_T.W == 6 and G_T.H == 5, "迷宫尺寸未按下发数据：" .. tostring(G_T.W) .. "×" .. tostring(G_T.H))
  assert(#G_T.reachable > 0, "按数据重建后无可达格")
  assert(G_T.match ~= nil and G_T.match.timer ~= nil, "联机对局缺少 10 分钟计时器")
  assert(G_T.tanks[1].baseColor == MENU_L.PICK_COLORS[3], "本地玩家坦克未使用选定颜色")
  -- 联机固定「限速转向」：坦克创建时应带上 settingsUseNewMouseControl = true
  assert(G_T.tanks[1].settingsUseNewMouseControl == true, "联机坦克应固定使用限速转向")

  -- 计分板三件套：名字 / 分数 / 延迟
  local HUD2 = DBG.hud
  assert(HUD2.nameLabels[1] ~= nil and HUD2.nameLabels[1].text == "测试玩家",
    "计分板名字错误：" .. tostring(HUD2.nameLabels[1] and HUD2.nameLabels[1].text))
  assert(HUD2.scoreLabels[1] ~= nil, "计分板分数标签缺失")
  assert(HUD2.pingLabels[1] ~= nil and HUD2.pingLabels[1].text == "--", "未测得延迟时应显示 --")

  -- 延迟探测：发 PING → 服务器把**时间戳原样回发** → 本端算出 ms 并刷新计分板
  MENU_L.pingSend()
  MENU_L.onPong(G_T.pingAt)
  assert(type(G_T.pingMs) == "number" and G_T.pingMs >= 0, "延迟未算出")
  -- 服务器是「广播回发」：收到**别人**的 echo（时间戳不同）必须忽略，否则延迟会乱跳
  local pingKeep = G_T.pingMs
  MENU_L.onPong((G_T.pingAt or 0) - 7)
  assert(G_T.pingMs == pingKeep, "不该拿别人的 echo 算延迟")
  MENU_L.onPong(G_T.pingAt)
  assert(HUD2.pingLabels[1].text:find("ms", 1, true) ~= nil,
    "本机延迟未显示 ms：" .. tostring(HUD2.pingLabels[1].text))
  assert(HUD2.pingLabels[2].text == "--", "非本机不应显示延迟")

  -- P1：房间结构（我的槽位 / 对手槽位 / 插值缓冲）+ 对手坦克标 remote
  assert(G_T.room ~= nil and G_T.room.mySlot == G_T.playerIndex and #G_T.room.oppSlots == 1,
    "房间结构缺失")
  assert(G_T.snapBuf ~= nil, "插值缓冲未建")
  assert(G_T.tanks[2].remote == true and G_T.tanks[1].remote == nil, "remote 标记错误")

  -- P1：服务器**逐个**告知槽位（信号 TT2_SLOT，参数 = 玩家序号）
  --   —— 玩家实体上的自定义变量要开「局内存档」才会生成，所以改用信号定向下发。
  MENU_L.onSlot(2)
  assert(G_T.playerIndex == 2, "onSlot 未更新本机槽位")
  MENU_L.onSlot(2)
  assert(G_T.playerIndex == 2, "重复下发不应改变槽位")
  MENU_L.onSlot(1)
  assert(G_T.playerIndex == 1, "还原槽位失败")

  -- P4：进场请求过全量（TT2_HELLO）
  assert(sent("TT2_HELLO") >= 1, "未发送 TT2_HELLO（重连/进场全量请求）")

  -- v4：房主不再「拿到槽位就上传」，而是在**开新回合时**上传（表首项 seq = 回合号）。
  assert(MENU_L.isMazeHost() == true, "槽位 1 应被判为房主")
  -- 打死对手（走正规阵亡路径：DIED 事件 → killTank → round.aliveCount-1）⇒ 回合结束
  MENU_L.onEvent({ 4, 2 })          -- onlineApi.EV.DIED, slot=2
  frame(200)                        -- 冻结 125 + 冻结帧 50 + 重开 5 ⇒ 足够
  assert(sent("TT2_MAZE_UP") >= 1, "房主开新回合时未上传迷宫表 TT2_MAZE_UP")
  assert(G_T.roundId >= 1, "房主回合号应递增（实为 " .. tostring(G_T.roundId) .. "）")
  -- 房主：新回合场上无箱 ⇒ 也应把「空表」上传一次（否则非房主那边旧箱子会残留）
  assert(sent("TT2_CRATE_UP") >= 1, "房主开新回合时应上传空补给箱表 TT2_CRATE_UP")

  -- P2：上行本机快照（**按槽位分信号** TT2_SNAP_1 / TT2_SNAP_2）；
  --   下行走**对方槽位**的关卡变量 → 插值驱动对手坦克
  --   注入一条 slot=2 的快照：x=111, y=222, rot=0, weaponId=5(homing), alive=1
  customVars.TT2_SNAP_2 = { 2, 1110, 2220, 0, 5, 1 }
  frame(4)
  assert(sent("TT2_SNAP_1") >= 1, "未上传本机快照（槽位 1 应发 TT2_SNAP_1）")
  local foe = G_T.tanks[2]
  assert(math.abs(foe.x - 111) <= 1 and math.abs(foe.y - 222) <= 1,
    "对手坦克未按快照插值到位：" .. tostring(foe.x) .. "," .. tostring(foe.y))
  assert(foe.currentWeapon == "homing", "对手武器未按快照更新：" .. tostring(foe.currentWeapon))

  -- P3：本机开火应上报 TT2_EVENT（方案 1 的开火键 = Q，见 DEFAULT_BINDS）
  local evBefore = sent("TT2_EVENT")
  press("KeyboardCharacterSkill2KeyDown")
  frame(1)
  press("KeyboardCharacterSkill2KeyUp")
  frame(1)
  assert(sent("TT2_EVENT") > evBefore, "开火未上报 TT2_EVENT")

  -- 用户 2026-10-15 规则：**对方逃跑 ⇒ 他失败、本机胜利**。
  --   官方没有「玩家离开」事件节点 ⇒ 客户端靠「在场人数掉到 1」推断（MENU.syncOnline 里判）
  local nWin0 = sent("TT2_SET_WIN")
  customVars.TT2_PLAYERS = 1
  MENU_L.syncOnline(true)
  frame(1)
  assert(G_T.match.over == true and G_T.match.winner == G_T.playerIndex,
    "人数掉到 1 应判本机胜（winner=" .. tostring(G_T.match.winner) .. "）")
  assert(sent("TT2_SET_WIN") > nWin0, "判胜后应上报 TT2_SET_WIN（服务器据此把本机置「胜利」）")
  customVars.TT2_PLAYERS = 2            -- 还原（不影响后续断言）

  -- 用户 2026-10-16 规则：**分出胜负 ⇒ 立刻结算关卡** ——
  --   本端先报自己的最终状态（上面已发），倒数 40 帧等对端报文，再由房主发 TT2_SETTLE。
  assert(G_T.match.settleIn ~= nil, "分出胜负后应进入结算倒数（settleIn）")
  local nSettle0 = sent("TT2_SETTLE")
  frame(45)
  assert(sent("TT2_SETTLE") > nSettle0, "40 帧后应上报 TT2_SETTLE（服务器据此【结算关卡】）")
  assert(G_T.match.settleIn == nil, "TT2_SETTLE 只应发一次（settleIn 已清空）")

  -- 逃跑判负：对方(2)逃跑 ⇒ 本机(1)胜，且显示结算提示
  MENU_L.onPlayerEscaped(2)
  assert(G_T.match.over == true and G_T.match.winner == 1, "逃跑判负错误")
  assert(HUD2.resultLabel.text:find("胜利", 1, true) ~= nil,
    "结算提示未显示胜利：" .. tostring(HUD2.resultLabel.text))
  -- 已结束的对局不应被再次结算
  MENU_L.finishMatch(2)
  assert(G_T.match.winner == 1, "已结束的对局不应被再次改动")
end)
check("联机：方案 4 迷宫 / 3 秒倒计时 / 颜色 / 计分板 / 延迟 / 逃跑判负", okOnline,
  okOnline and "ok" or tostring(errOnline))

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