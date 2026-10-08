---@meta

--[[
=====================================================================
 《千星奇域》客户端控件 API —— LuaLS 类型桩文件
 依据《客户端控件API文档》整理生成，仅供 lua-language-server 静态检查使用。
 本文件由 ---@meta 标记，不会被游戏运行时执行，也不包含任何可执行逻辑。

 用途：让主脚本（tank_trouble.lua）在静态检查时能识别游戏内建全局
       （game / Enum / Color / script / typeof / printerr 等）
       以及全部 UI 控件类的方法与字段，从而抓出方法名/字段名拼写错误。

 约定：
   * 文档中标注了类型的参数/返回值照抄；未标注或含糊的一律使用 any
     或合理宽泛类型，并在行尾以「-- 文档未明确」标注。
   * 枚举以 Enum.<枚举名> 作为容器字段，其取值类型即同名类型，
     例如 Enum.ImageType.Stretch 的类型为 ImageType。
   * 只读 / 读写 / Tweenable 等访问属性文档已注明，此处以行尾注释保留，
     不使用 LuaLS 注解强制（避免非标准写法）。

 未在本文档中声明为全局的函数（运行时回调，由脚本自行定义）：
   OnInit() / OnStart() / OnEnable() / OnDisable() /
   OnUpdate(dt) / OnLevelUpdate(dt) / OnDestroy()
=====================================================================
]]


-- ============================================================
-- 0. 基础类型别名
-- ============================================================

---客户端控件运行时 ID
---@alias ClientControlID integer

---客户端控件运行时 ID 列表
---@alias ClientControlIDList integer[]

---颜色值。由 Color(...) / Color.FromRGB / Color.FromRGBA 构造。
---文档未定义其内部字段（tank_trouble.lua 亦注明不可直接取 .r/.g/.b），
---拆分颜色请使用 Color.ToRGBA。
---@class ColorValue


-- ============================================================
-- 1. 全局 API
-- ============================================================

---返回运行时类型名称；用于识别宿主对象
---@param value any
---@return string
function typeof(value) end

---将传入值写入错误级别日志；不抛出 Lua 错误，也不阻断运行
---@param ... any
function printerr(...) end

-- print(...)：Lua 标准库内建，将传入值写入普通级别日志，此处无需重复声明。

---判断数值是否为 NaN（运行时对 math 的补充）
---@param n number
---@return boolean
function math.isnan(n) end

---判断数值是否为正负无穷（运行时对 math 的补充）
---@param n number
---@return boolean
function math.isinf(n) end

debug = {}

---生成并返回调用栈文本；仅返回文本，不自动写入日志。
---运行时仅保留 debug.traceback（.luarc.json 已禁用 debug 库）
---@param message? string 添加在文本开头的说明
---@param level? integer 调用栈起始层级
---@return string
function debug.traceback(message, level) end


-- ============================================================
-- 2. Color
-- ============================================================

---颜色构造与拆分类（全局变量 Color）
---@class Color
---@operator call(...): ColorValue
Color = {}

---由 0-255 RGB 创建颜色
---@param r number
---@param g number
---@param b number
---@return ColorValue
function Color.FromRGB(r, g, b) end

---由 0-255 RGBA 创建颜色；a 可省略或传 nil，传 nil 时等同于 255（不透明）
---@param r number
---@param g number
---@param b number
---@param a number?
---@return ColorValue
function Color.FromRGBA(r, g, b, a) end

---将颜色拆分为 0-255 的 RGBA 四个值
---@param colorValue ColorValue
---@return number r
---@return number g
---@return number b
---@return number a
function Color.ToRGBA(colorValue) end


-- ============================================================
-- 3. Script
-- ============================================================

---脚本实例类型。运行时通过全局变量 script 提供当前脚本实例。
---@class Script
---@field alive boolean 只读：脚本实例是否存活
---@field scriptMappingId integer 只读：脚本映射 ID
---@field object any 只读：脚本所挂载的宿主对象
---@field path string 只读：脚本路径
---@field enabled boolean 读写：脚本启用状态
local Script = {}

---按变量名称读取当前脚本内对应变量的参数
---@param paramName string
---@return any
function Script:GetParam(paramName) end

---调用当前脚本中名称为 funcName 的全局方法（脚本内环境）；
---参数应使用运行时支持的可传递类型
---@param funcName string
---@param ... any
function Script:Invoke(funcName, ...) end

---控制当前脚本的逐帧更新；false 关闭，true 重新启用
---@param enabled boolean
function Script:EnableUpdate(enabled) end

---注册 signalName 对应的服务器信号监听
---@param signalName string
---@param callback fun(signalName: string, signalParams: any[])
function Script:RegisterServerSignalHandler(signalName, callback) end

---移除 signalName 对应的服务器信号监听
---@param signalName string
function Script:UnregisterServerSignalHandler(signalName) end

---监听 entityType 与 customVariableName 对应的全局自定义变量变化。
---回调仅提供实体类型与变量名称，当前值需通过
---game.GetGlobalCustomVariableValue 读取
---@param entityType CustomVariableEntityType
---@param customVariableName string
---@param callback fun(entityType: CustomVariableEntityType, customVariableName: string)
function Script:RegisterCustomVariableChangedHandler(entityType, customVariableName, callback) end

---移除 entityType 与 customVariableName 对应的自定义变量监听
---@param entityType CustomVariableEntityType
---@param customVariableName string
function Script:UnregisterCustomVariableChangedHandler(entityType, customVariableName) end

---全局变量：当前脚本
---@type Script
script = nil


-- ============================================================
-- 4. game（客户端运行时全局表，全部使用点号调用）
-- ============================================================

---客户端运行时全局表
---@class Game
game = {}

-- ---- (1) UI 与层级 ----

---根据已配置的控件模板索引，在 parent 下创建控件实例
---@param controlPrefabIndex integer
---@param parent ClientUIBaseControl
---@return ClientUIBaseControl
function game.InstantiateClientUIControl(controlPrefabIndex, parent) end

---销毁指定客户端控件实例
---@param control ClientUIBaseControl
function game.DestroyClientUIControl(control) end

---按客户端控件运行时 ID 获取控件
---@param controlId integer
---@return ClientUIBaseControl
function game.GetClientUIControl(controlId) end

---查找名称为 nodeName 的 UI 根控件
---@param nodeName string
---@return ClientUIBaseControl
function game.FindClientUIRoot(nodeName) end

---获取全部 UI 根控件
---@return ClientUIBaseControl[]
function game.GetClientUIRoots() end

---获取 UI 画布宽高
---@return number x
---@return number y
function game.GetUICanvasSize() end

---获取光标 UI 坐标
---@return number x
---@return number y
function game.GetCursorUIPos() end

-- ---- (2) 输入与聚焦 ----

---获取当前输入设备类型
---@return Device
function game.GetDevice() end

---设置手柄当前聚焦控件
---@param control ClientUIBaseControl
function game.SetControllerFocus(control) end

---获取当前聚焦控件
---@return ClientUIBaseControl
function game.GetControllerFocus() end

---获取左摇杆轴值
---@return number horizontal
---@return number vertical
function game.GetControllerLeftStickAxis() end

---获取右摇杆轴值
---@return number horizontal
---@return number vertical
function game.GetControllerRightStickAxis() end

-- ---- (3) 补间动画、服务器信号与自定义变量 ----

---按目标字段和持续时间为对象创建补间动画。
---tweenDataTable 以对象的 Tweenable 字段名为键、目标值为值
---@param object any
---@param tweenDataTable table
---@param duration number
---@return Tween
function game.Tween(object, tweenDataTable, duration) end

---创建空的补间动画序列
---@return TweenSequence
function game.TweenSequence() end

---使用服务器约定的信号名称 signalName 创建服务器信号
---@param signalName string
---@return ServerSignal
function game.ServerSignal(signalName) end

---读取 entityType 与 customVariableName 对应的全局自定义变量，
---支持复杂变量结构（列表、字典、结构体）
---@param entityType CustomVariableEntityType
---@param customVariableName string
---@return any
function game.GetGlobalCustomVariableValue(entityType, customVariableName) end

-- ---- (4) 关卡、音效与本地化 ----

---单人模式下设置关卡时停状态；true 开启，false 关闭；不暂停脚本自身
---@param pause boolean
function game.PauseLevelTime(pause) end

---查询是否处于关卡时停
---@return boolean
function game.IsLevelTimePaused() end

---按已配置的音效 ID 播放 2D 音效，并返回音效实例 ID
---@param audioId integer
---@return integer
function game.PlayAudio2D(audioId) end

---停止指定音效实例
---@param audioInstanceId integer
function game.StopAudio(audioInstanceId) end

---查询音效实例是否存活
---@param audioInstanceId integer
---@return boolean
function game.IsAudioAlive(audioInstanceId) end

---获取当前语言
---@return LanguageType
function game.GetLanguageType() end

---获取当前关卡模式
---@return StageMode
function game.GetStageMode() end

---查询当前是否处于测试游玩状态
---@return boolean
function game.IsTestPlay() end

---按已配置的文本映射 ID 获取本地化文本
---@param textMapId string
---@return string
function game.GetText(textMapId) end

-- ---- 调试（见文档 3.(2)）----

---将当前客户端控件树按父子层级写入日志
function game.PrintClientUITree() end


-- ============================================================
-- 5. Tween
-- ============================================================

---补间动画类，用于对目标对象的 Tweenable 字段进行插值
---@class Tween
local Tween = {}

---设置缓动类型并返回当前实例
---@param easeType EaseType
---@return Tween
function Tween:SetEase(easeType) end

---设置 tweenDataTable 中目标值的解释方式；
---false 表示绝对目标值，true 表示相对当前值的增量
---@param relative boolean
---@return Tween
function Tween:SetRelative(relative) end

---开始播放并返回当前实例
---@return Tween
function Tween:Play() end

---暂停并保留当前进度
function Tween:Pause() end

---从暂停处继续播放
function Tween:Resume() end

---回到初始状态并重新播放
function Tween:Restart() end

---立即切换到结束状态并完成
function Tween:Complete() end

---销毁实例；true 表示先切换到结束状态并触发完成回调，
---false 表示保持当前状态结束且不触发完成回调
---@param complete boolean
function Tween:Kill(complete) end

---设置全部循环完成后的回调并返回当前实例
---@param onComplete fun()
---@return Tween
function Tween:SetOnComplete(onComplete) end

---设置步骤完成回调并返回当前实例
---@param onStepComplete fun()
---@return Tween
function Tween:SetOnStepComplete(onStepComplete) end

---设置循环次数并返回当前实例；负数表示无限循环
---@param times integer
---@return Tween
function Tween:SetLoops(times) end


-- ============================================================
-- 6. TweenSequence
-- ============================================================

---补间动画序列，将多个补间动画、间隔与回调编排到同一时间线
---@class TweenSequence
local TweenSequence = {}

---在序列末尾接入补间动画
---@param tween Tween
---@return TweenSequence
function TweenSequence:Append(tween) end

---在序列末尾接入指定秒数的等待时间
---@param interval number
---@return TweenSequence
function TweenSequence:AppendInterval(interval) end

---在序列末尾接入回调
---@param callback fun()
---@return TweenSequence
function TweenSequence:AppendCallback(callback) end

---与当前队尾步骤同时播放；该步骤以最晚结束者为准
---@param tween Tween
---@return TweenSequence
function TweenSequence:Join(tween) end

---在指定时间点插入并行补间动画
---@param time number
---@param tween Tween
---@return TweenSequence
function TweenSequence:Insert(time, tween) end

---在指定时间点插入回调
---@param time number
---@param callback fun()
---@return TweenSequence
function TweenSequence:InsertCallback(time, callback) end

---开始播放并返回当前实例
---@return TweenSequence
function TweenSequence:Play() end

---暂停序列
function TweenSequence:Pause() end

---继续播放序列
function TweenSequence:Resume() end

---回到初始状态并重新播放
function TweenSequence:Restart() end

---立即完成整个序列
function TweenSequence:Complete() end

---销毁序列；true 表示先完成，false 表示保持当前状态结束
---@param complete boolean
function TweenSequence:Kill(complete) end

---设置整个序列完成回调并返回当前实例
---@param onComplete fun()
---@return TweenSequence
function TweenSequence:SetOnComplete(onComplete) end

---设置步骤完成回调并返回当前实例
---@param onStepComplete fun()
---@return TweenSequence
function TweenSequence:SetOnStepComplete(onStepComplete) end

---设置循环次数并返回当前实例；负数表示无限循环
---@param times integer
---@return TweenSequence
function TweenSequence:SetLoops(times) end


-- ============================================================
-- 7. ServerSignal
-- ============================================================

---服务器信号，参数按服务器约定依次添加
---@class ServerSignal
local ServerSignal = {}

---paramType 指定参数类型，paramValue 指定参数值
---@param paramType ParamType
---@param paramValue any
function ServerSignal:AddParam(paramType, paramValue) end

---发送已构建的服务器信号
function ServerSignal:SendSignal() end

---@param intValue integer
function ServerSignal:AddInt(intValue) end

---@param intListValue integer[]
function ServerSignal:AddIntList(intListValue) end

---@param floatValue number
function ServerSignal:AddFloat(floatValue) end

---@param floatListValue number[]
function ServerSignal:AddFloatList(floatListValue) end

---@param stringValue string
function ServerSignal:AddString(stringValue) end

---@param stringListValue string[]
function ServerSignal:AddStringList(stringListValue) end

---添加三维向量参数；传入以 x、y、z 为键的 table
---@param vector3Value table
function ServerSignal:AddVector3(vector3Value) end

---添加三维向量列表参数；传入以 x、y、z 为键的 table 列表
---@param vector3ListValue table[]
function ServerSignal:AddVector3List(vector3ListValue) end

---@param boolValue boolean
function ServerSignal:AddBool(boolValue) end

---@param boolListValue boolean[]
function ServerSignal:AddBoolList(boolListValue) end

---@param guidValue integer
function ServerSignal:AddGuid(guidValue) end

---@param guidListValue integer[]
function ServerSignal:AddGuidList(guidListValue) end

---@param entityValue integer
function ServerSignal:AddEntity(entityValue) end

---@param entityListValue integer[]
function ServerSignal:AddEntityList(entityListValue) end

---@param prefabIdValue integer
function ServerSignal:AddPrefabId(prefabIdValue) end

---@param prefabIdListValue integer[]
function ServerSignal:AddPrefabIdList(prefabIdListValue) end

---@param configIdValue integer
function ServerSignal:AddConfigId(configIdValue) end

---@param configIdListValue integer[]
function ServerSignal:AddConfigIdList(configIdListValue) end


-- ============================================================
-- 8. EnumItem
-- ============================================================

---枚举值对象
---@class EnumItem
---@field Name string 只读：枚举值名称
---@field FullName string 只读：枚举值完整名称
---@field EnumType string 只读：枚举类型名称


-- ============================================================
-- 9. 枚举系统
-- ============================================================

---@class EaseType
---@field Linear EaseType
---@field InSine EaseType
---@field OutSine EaseType
---@field InOutSine EaseType
---@field InQuad EaseType
---@field OutQuad EaseType
---@field InOutQuad EaseType
---@field InCubic EaseType
---@field OutCubic EaseType
---@field InOutCubic EaseType
---@field InQuart EaseType
---@field OutQuart EaseType
---@field InOutQuart EaseType
---@field InQuint EaseType
---@field OutQuint EaseType
---@field InOutQuint EaseType
---@field InExpo EaseType
---@field OutExpo EaseType
---@field InOutExpo EaseType
---@field InCirc EaseType
---@field OutCirc EaseType
---@field InOutCirc EaseType
---@field InBack EaseType
---@field OutBack EaseType
---@field InOutBack EaseType
---@field InElastic EaseType
---@field OutElastic EaseType
---@field InOutElastic EaseType
---@field InBounce EaseType
---@field OutBounce EaseType
---@field InOutBounce EaseType

---@class CustomVariableEntityType
---@field Level CustomVariableEntityType
---@field PlayerSelf CustomVariableEntityType
---@field AvatarSelf CustomVariableEntityType

---@class Device
---@field KeyboardAndMouse Device
---@field Mobile Device
---@field Controller Device
---@field MobileController Device

---@class StageMode
---@field Beyond StageMode
---@field Classic StageMode

---@class LanguageType
---@field LanguageNone LanguageType
---@field LanguageEng LanguageType
---@field LanguageChs LanguageType
---@field LanguageCht LanguageType
---@field LanguageFra LanguageType
---@field LanguageDeu LanguageType
---@field LanguageSpa LanguageType
---@field LanguagePor LanguageType
---@field LanguageRus LanguageType
---@field LanguageJpn LanguageType
---@field LanguageKor LanguageType
---@field LanguageTha LanguageType
---@field LanguageVie LanguageType
---@field LanguageInd LanguageType
---@field LanguageTur LanguageType
---@field LanguageIta LanguageType

---@class ParamType
---@field Entity ParamType
---@field EntityList ParamType
---@field Int ParamType
---@field IntList ParamType
---@field Bool ParamType
---@field BoolList ParamType
---@field Float ParamType
---@field FloatList ParamType
---@field String ParamType
---@field StringList ParamType
---@field Vector3 ParamType
---@field Vector3List ParamType
---@field Guid ParamType
---@field GuidList ParamType
---@field ConfigId ParamType
---@field PrefabId ParamType
---@field ConfigIdList ParamType
---@field PrefabIdList ParamType

---@class CursorEventType
---@field CursorDown CursorEventType
---@field CursorUp CursorEventType
---@field CursorEnter CursorEventType
---@field CursorExit CursorEventType
---@field CursorDrag CursorEventType
---@field CursorBeginDrag CursorEventType
---@field CursorEndDrag CursorEventType
---@field CursorClick CursorEventType

---@class ScrollDirection
---@field Horizontal ScrollDirection
---@field Vertical ScrollDirection

---@class ScrollLayoutConstraint
---@field AutoWrap ScrollLayoutConstraint
---@field Fixed ScrollLayoutConstraint

---@class ScrollAlignType
---@field Bottom ScrollAlignType
---@field Center ScrollAlignType
---@field Top ScrollAlignType

---@class ControllerNavigationDir
---@field Up ControllerNavigationDir
---@field Down ControllerNavigationDir
---@field Left ControllerNavigationDir
---@field Right ControllerNavigationDir

---@class ControllerNavigationEventType
---@field Confirm ControllerNavigationEventType
---@field Cancel ControllerNavigationEventType
---@field Focus ControllerNavigationEventType
---@field LostFocus ControllerNavigationEventType
---@field RightStickUp ControllerNavigationEventType
---@field RightStickDown ControllerNavigationEventType
---@field RightStickRight ControllerNavigationEventType
---@field RightStickLeft ControllerNavigationEventType
---@field LeftStickUp ControllerNavigationEventType
---@field LeftStickDown ControllerNavigationEventType
---@field LeftStickRight ControllerNavigationEventType
---@field LeftStickLeft ControllerNavigationEventType

---@class ControllerNavigationMode
---@field None ControllerNavigationMode
---@field NearestControl ControllerNavigationMode
---@field Specified ControllerNavigationMode

---@class TextHorizontalAlignment
---@field Left TextHorizontalAlignment
---@field Middle TextHorizontalAlignment
---@field Right TextHorizontalAlignment

---@class TextVerticalAlignment
---@field Top TextVerticalAlignment
---@field Middle TextVerticalAlignment
---@field Bottom TextVerticalAlignment

---@class ImageType
---@field Basic ImageType
---@field Stretch ImageType

---@class ImageSource
---@field StaticReference ImageSource
---@field Item ImageSource
---@field Equipment ImageSource
---@field Skill ImageSource
---@field UnitStatus ImageSource
---@field Faction ImageSource
---@field Currency ImageSource
---@field Prefab ImageSource

---@class ImageFillType
---@field Unused ImageFillType
---@field Horizontal ImageFillType
---@field Vertical ImageFillType
---@field Radial90 ImageFillType
---@field Radial180 ImageFillType
---@field Radial360 ImageFillType

---@class ImageFillHorizontalType
---@field Left ImageFillHorizontalType
---@field Right ImageFillHorizontalType

---@class ImageFillVerticalType
---@field Bottom ImageFillVerticalType
---@field Top ImageFillVerticalType

---@class ImageFillRadial90Type
---@field BottomLeft ImageFillRadial90Type
---@field TopLeft ImageFillRadial90Type
---@field TopRight ImageFillRadial90Type
---@field BottomRight ImageFillRadial90Type

---@class ImageFillRadialType
---@field Bottom ImageFillRadialType
---@field Left ImageFillRadialType
---@field Top ImageFillRadialType
---@field Right ImageFillRadialType

---@class ImageMaskSoftEdgeMode
---@field Percentage ImageMaskSoftEdgeMode
---@field Pixel ImageMaskSoftEdgeMode

---@class UIAnimationLayer
---@field AboveAllControls UIAnimationLayer
---@field BelowAllControls UIAnimationLayer

---@class KeyboardKeyCode
---@field CraftspersonKey1 KeyboardKeyCode
---@field CraftspersonKey2 KeyboardKeyCode
---@field CraftspersonKey3 KeyboardKeyCode
---@field CraftspersonKey4 KeyboardKeyCode
---@field CraftspersonKey5 KeyboardKeyCode
---@field CraftspersonKey6 KeyboardKeyCode
---@field CraftspersonKey7 KeyboardKeyCode
---@field CraftspersonKey8 KeyboardKeyCode
---@field CraftspersonKey9 KeyboardKeyCode
---@field CraftspersonKey10 KeyboardKeyCode
---@field CraftspersonKey11 KeyboardKeyCode
---@field CraftspersonKey12 KeyboardKeyCode
---@field CraftspersonKey13 KeyboardKeyCode
---@field CraftspersonKey14 KeyboardKeyCode
---@field CraftspersonKey15 KeyboardKeyCode
---@field CraftspersonKey16 KeyboardKeyCode
---@field CraftspersonKey17 KeyboardKeyCode
---@field CraftspersonKey18 KeyboardKeyCode
---@field CraftspersonKey19 KeyboardKeyCode
---@field CraftspersonKey20 KeyboardKeyCode
---@field CraftspersonKey21 KeyboardKeyCode
---@field CraftspersonKey22 KeyboardKeyCode
---@field CraftspersonKey23 KeyboardKeyCode
---@field CraftspersonKey24 KeyboardKeyCode
---@field CraftspersonKey25 KeyboardKeyCode
---@field CraftspersonKey26 KeyboardKeyCode
---@field CraftspersonKey27 KeyboardKeyCode
---@field CraftspersonKey28 KeyboardKeyCode
---@field CraftspersonKey29 KeyboardKeyCode
---@field CraftspersonKey30 KeyboardKeyCode
---@field CraftspersonKey31 KeyboardKeyCode
---@field CraftspersonKey32 KeyboardKeyCode
---@field CraftspersonKey33 KeyboardKeyCode
---@field CraftspersonKey34 KeyboardKeyCode
---@field CraftspersonKey35 KeyboardKeyCode
---@field CraftspersonKey36 KeyboardKeyCode
---@field CraftspersonKey37 KeyboardKeyCode
---@field CraftspersonKey38 KeyboardKeyCode
---@field CraftspersonKey39 KeyboardKeyCode
---@field CraftspersonKey40 KeyboardKeyCode
---@field CraftspersonKey41 KeyboardKeyCode
---@field CraftspersonKey42 KeyboardKeyCode
---@field CraftspersonKey43 KeyboardKeyCode
---@field MoveForwardKey KeyboardKeyCode
---@field MoveBackwardKey KeyboardKeyCode
---@field MoveLeftKey KeyboardKeyCode
---@field MoveRightKey KeyboardKeyCode
---@field SwitchToWalkOrRunKey KeyboardKeyCode
---@field SprintKey KeyboardKeyCode
---@field JumpKey KeyboardKeyCode
---@field DropKey KeyboardKeyCode
---@field OpenShortcutWheelKey KeyboardKeyCode
---@field InteractKey KeyboardKeyCode
---@field NormalAttackKey KeyboardKeyCode
---@field CharacterSkill1Key KeyboardKeyCode
---@field CharacterSkill2Key KeyboardKeyCode
---@field CharacterSkill3Key KeyboardKeyCode
---@field CharacterSkill4Key KeyboardKeyCode
---@field None KeyboardKeyCode

---@class ControllerKeyCode
---@field CraftspersonKey1 ControllerKeyCode
---@field CraftspersonKey2 ControllerKeyCode
---@field CraftspersonKey3 ControllerKeyCode
---@field CraftspersonKey4 ControllerKeyCode
---@field CraftspersonKey5 ControllerKeyCode
---@field CraftspersonKey6 ControllerKeyCode
---@field CraftspersonKey7 ControllerKeyCode
---@field CraftspersonKey8 ControllerKeyCode
---@field CraftspersonKey9 ControllerKeyCode
---@field CraftspersonKey10 ControllerKeyCode
---@field CraftspersonKey11 ControllerKeyCode
---@field CraftspersonKey12 ControllerKeyCode
---@field CraftspersonKey13 ControllerKeyCode
---@field CraftspersonKey14 ControllerKeyCode
---@field SprintKey ControllerKeyCode
---@field JumpKey ControllerKeyCode
---@field InteractKey ControllerKeyCode
---@field NormalAttackKey ControllerKeyCode
---@field CharacterSkill1Key ControllerKeyCode
---@field CharacterSkill2Key ControllerKeyCode
---@field CharacterSkill3Key ControllerKeyCode
---@field CharacterSkill4Key ControllerKeyCode
---@field MenuConfirmKey ControllerKeyCode
---@field MenuBackKey ControllerKeyCode
---@field None ControllerKeyCode

---@class KeyEventType
---@field KeyboardCraftspersonKey1Down KeyEventType
---@field KeyboardCraftspersonKey2Down KeyEventType
---@field KeyboardCraftspersonKey3Down KeyEventType
---@field KeyboardCraftspersonKey4Down KeyEventType
---@field KeyboardCraftspersonKey5Down KeyEventType
---@field KeyboardCraftspersonKey6Down KeyEventType
---@field KeyboardCraftspersonKey7Down KeyEventType
---@field KeyboardCraftspersonKey8Down KeyEventType
---@field KeyboardCraftspersonKey9Down KeyEventType
---@field KeyboardCraftspersonKey10Down KeyEventType
---@field KeyboardCraftspersonKey11Down KeyEventType
---@field KeyboardCraftspersonKey12Down KeyEventType
---@field KeyboardCraftspersonKey13Down KeyEventType
---@field KeyboardCraftspersonKey14Down KeyEventType
---@field KeyboardCraftspersonKey15Down KeyEventType
---@field KeyboardCraftspersonKey16Down KeyEventType
---@field KeyboardCraftspersonKey17Down KeyEventType
---@field KeyboardCraftspersonKey18Down KeyEventType
---@field KeyboardCraftspersonKey19Down KeyEventType
---@field KeyboardCraftspersonKey20Down KeyEventType
---@field KeyboardCraftspersonKey21Down KeyEventType
---@field KeyboardCraftspersonKey22Down KeyEventType
---@field KeyboardCraftspersonKey23Down KeyEventType
---@field KeyboardCraftspersonKey24Down KeyEventType
---@field KeyboardCraftspersonKey25Down KeyEventType
---@field KeyboardCraftspersonKey26Down KeyEventType
---@field KeyboardCraftspersonKey27Down KeyEventType
---@field KeyboardCraftspersonKey28Down KeyEventType
---@field KeyboardCraftspersonKey29Down KeyEventType
---@field KeyboardCraftspersonKey30Down KeyEventType
---@field KeyboardCraftspersonKey31Down KeyEventType
---@field KeyboardCraftspersonKey32Down KeyEventType
---@field KeyboardCraftspersonKey33Down KeyEventType
---@field KeyboardCraftspersonKey34Down KeyEventType
---@field KeyboardCraftspersonKey35Down KeyEventType
---@field KeyboardCraftspersonKey36Down KeyEventType
---@field KeyboardCraftspersonKey37Down KeyEventType
---@field KeyboardCraftspersonKey38Down KeyEventType
---@field KeyboardCraftspersonKey39Down KeyEventType
---@field KeyboardCraftspersonKey40Down KeyEventType
---@field KeyboardCraftspersonKey41Down KeyEventType
---@field KeyboardCraftspersonKey42Down KeyEventType
---@field KeyboardCraftspersonKey43Down KeyEventType
---@field KeyboardMoveForwardKeyDown KeyEventType
---@field KeyboardMoveBackwardKeyDown KeyEventType
---@field KeyboardMoveLeftKeyDown KeyEventType
---@field KeyboardMoveRightKeyDown KeyEventType
---@field KeyboardSwitchToWalkOrRunKeyDown KeyEventType
---@field KeyboardSprintKeyDown KeyEventType
---@field KeyboardJumpKeyDown KeyEventType
---@field KeyboardDropKeyDown KeyEventType
---@field KeyboardOpenShortcutWheelKeyDown KeyEventType
---@field KeyboardInteractKeyDown KeyEventType
---@field KeyboardNormalAttackKeyDown KeyEventType
---@field KeyboardCharacterSkill1KeyDown KeyEventType
---@field KeyboardCharacterSkill2KeyDown KeyEventType
---@field KeyboardCharacterSkill3KeyDown KeyEventType
---@field KeyboardCharacterSkill4KeyDown KeyEventType
---@field KeyboardCraftspersonKey1Up KeyEventType
---@field KeyboardCraftspersonKey2Up KeyEventType
---@field KeyboardCraftspersonKey3Up KeyEventType
---@field KeyboardCraftspersonKey4Up KeyEventType
---@field KeyboardCraftspersonKey5Up KeyEventType
---@field KeyboardCraftspersonKey6Up KeyEventType
---@field KeyboardCraftspersonKey7Up KeyEventType
---@field KeyboardCraftspersonKey8Up KeyEventType
---@field KeyboardCraftspersonKey9Up KeyEventType
---@field KeyboardCraftspersonKey10Up KeyEventType
---@field KeyboardCraftspersonKey11Up KeyEventType
---@field KeyboardCraftspersonKey12Up KeyEventType
---@field KeyboardCraftspersonKey13Up KeyEventType
---@field KeyboardCraftspersonKey14Up KeyEventType
---@field KeyboardCraftspersonKey15Up KeyEventType
---@field KeyboardCraftspersonKey16Up KeyEventType
---@field KeyboardCraftspersonKey17Up KeyEventType
---@field KeyboardCraftspersonKey18Up KeyEventType
---@field KeyboardCraftspersonKey19Up KeyEventType
---@field KeyboardCraftspersonKey20Up KeyEventType
---@field KeyboardCraftspersonKey21Up KeyEventType
---@field KeyboardCraftspersonKey22Up KeyEventType
---@field KeyboardCraftspersonKey23Up KeyEventType
---@field KeyboardCraftspersonKey24Up KeyEventType
---@field KeyboardCraftspersonKey25Up KeyEventType
---@field KeyboardCraftspersonKey26Up KeyEventType
---@field KeyboardCraftspersonKey27Up KeyEventType
---@field KeyboardCraftspersonKey28Up KeyEventType
---@field KeyboardCraftspersonKey29Up KeyEventType
---@field KeyboardCraftspersonKey30Up KeyEventType
---@field KeyboardCraftspersonKey31Up KeyEventType
---@field KeyboardCraftspersonKey32Up KeyEventType
---@field KeyboardCraftspersonKey33Up KeyEventType
---@field KeyboardCraftspersonKey34Up KeyEventType
---@field KeyboardCraftspersonKey35Up KeyEventType
---@field KeyboardCraftspersonKey36Up KeyEventType
---@field KeyboardCraftspersonKey37Up KeyEventType
---@field KeyboardCraftspersonKey38Up KeyEventType
---@field KeyboardCraftspersonKey39Up KeyEventType
---@field KeyboardCraftspersonKey40Up KeyEventType
---@field KeyboardCraftspersonKey41Up KeyEventType
---@field KeyboardCraftspersonKey42Up KeyEventType
---@field KeyboardCraftspersonKey43Up KeyEventType
---@field KeyboardMoveForwardKeyUp KeyEventType
---@field KeyboardMoveBackwardKeyUp KeyEventType
---@field KeyboardMoveLeftKeyUp KeyEventType
---@field KeyboardMoveRightKeyUp KeyEventType
---@field KeyboardSwitchToWalkOrRunKeyUp KeyEventType
---@field KeyboardSprintKeyUp KeyEventType
---@field KeyboardJumpKeyUp KeyEventType
---@field KeyboardDropKeyUp KeyEventType
---@field KeyboardOpenShortcutWheelKeyUp KeyEventType
---@field KeyboardInteractKeyUp KeyEventType
---@field KeyboardNormalAttackKeyUp KeyEventType
---@field KeyboardCharacterSkill1KeyUp KeyEventType
---@field KeyboardCharacterSkill2KeyUp KeyEventType
---@field KeyboardCharacterSkill3KeyUp KeyEventType
---@field KeyboardCharacterSkill4KeyUp KeyEventType
---@field ControllerCraftspersonKey1Down KeyEventType
---@field ControllerCraftspersonKey2Down KeyEventType
---@field ControllerCraftspersonKey3Down KeyEventType
---@field ControllerCraftspersonKey4Down KeyEventType
---@field ControllerCraftspersonKey5Down KeyEventType
---@field ControllerCraftspersonKey6Down KeyEventType
---@field ControllerCraftspersonKey7Down KeyEventType
---@field ControllerCraftspersonKey8Down KeyEventType
---@field ControllerCraftspersonKey9Down KeyEventType
---@field ControllerCraftspersonKey10Down KeyEventType
---@field ControllerCraftspersonKey11Down KeyEventType
---@field ControllerCraftspersonKey12Down KeyEventType
---@field ControllerCraftspersonKey13Down KeyEventType
---@field ControllerCraftspersonKey14Down KeyEventType
---@field ControllerSprintKeyDown KeyEventType
---@field ControllerJumpKeyDown KeyEventType
---@field ControllerInteractKeyDown KeyEventType
---@field ControllerNormalAttackKeyDown KeyEventType
---@field ControllerCharacterSkill1KeyDown KeyEventType
---@field ControllerCharacterSkill2KeyDown KeyEventType
---@field ControllerCharacterSkill3KeyDown KeyEventType
---@field ControllerCharacterSkill4KeyDown KeyEventType
---@field ControllerMenuConfirmKeyDown KeyEventType
---@field ControllerMenuBackKeyDown KeyEventType
---@field ControllerCraftspersonKey1Up KeyEventType
---@field ControllerCraftspersonKey2Up KeyEventType
---@field ControllerCraftspersonKey3Up KeyEventType
---@field ControllerCraftspersonKey4Up KeyEventType
---@field ControllerCraftspersonKey5Up KeyEventType
---@field ControllerCraftspersonKey6Up KeyEventType
---@field ControllerCraftspersonKey7Up KeyEventType
---@field ControllerCraftspersonKey8Up KeyEventType
---@field ControllerCraftspersonKey9Up KeyEventType
---@field ControllerCraftspersonKey10Up KeyEventType
---@field ControllerCraftspersonKey11Up KeyEventType
---@field ControllerCraftspersonKey12Up KeyEventType
---@field ControllerCraftspersonKey13Up KeyEventType
---@field ControllerCraftspersonKey14Up KeyEventType
---@field ControllerSprintKeyUp KeyEventType
---@field ControllerJumpKeyUp KeyEventType
---@field ControllerInteractKeyUp KeyEventType
---@field ControllerNormalAttackKeyUp KeyEventType
---@field ControllerCharacterSkill1KeyUp KeyEventType
---@field ControllerCharacterSkill2KeyUp KeyEventType
---@field ControllerCharacterSkill3KeyUp KeyEventType
---@field ControllerCharacterSkill4KeyUp KeyEventType
---@field ControllerMenuConfirmKeyUp KeyEventType
---@field ControllerMenuBackKeyUp KeyEventType

---枚举容器（全局变量 Enum）
---@class Enum
---@field EaseType EaseType
---@field CustomVariableEntityType CustomVariableEntityType
---@field Device Device
---@field StageMode StageMode
---@field LanguageType LanguageType
---@field ParamType ParamType
---@field CursorEventType CursorEventType
---@field ScrollDirection ScrollDirection
---@field ScrollLayoutConstraint ScrollLayoutConstraint
---@field ScrollAlignType ScrollAlignType
---@field ControllerNavigationDir ControllerNavigationDir
---@field ControllerNavigationEventType ControllerNavigationEventType
---@field ControllerNavigationMode ControllerNavigationMode
---@field TextHorizontalAlignment TextHorizontalAlignment
---@field TextVerticalAlignment TextVerticalAlignment
---@field ImageType ImageType
---@field ImageSource ImageSource
---@field ImageFillType ImageFillType
---@field ImageFillHorizontalType ImageFillHorizontalType
---@field ImageFillVerticalType ImageFillVerticalType
---@field ImageFillRadial90Type ImageFillRadial90Type
---@field ImageFillRadialType ImageFillRadialType
---@field ImageMaskSoftEdgeMode ImageMaskSoftEdgeMode
---@field UIAnimationLayer UIAnimationLayer
---@field KeyboardKeyCode KeyboardKeyCode
---@field ControllerKeyCode ControllerKeyCode
---@field KeyEventType KeyEventType
Enum = {}


-- ============================================================
-- 10. 客户端控件基类
-- ============================================================

---客户端控件基类，提供层级、布局、脚本访问、输入监听与手柄导航。
---全部具体控件类均继承本类。
---@class ClientUIBaseControl
---@field alive boolean 只读：控件是否存活
---@field id integer 只读：运行时 ID
---@field prefabIndex integer 只读：控件模板索引
---@field active boolean 只读：激活状态（true 时可见且脚本逻辑运行，默认 false）
---@field activeInHierarchy boolean 只读：计入全部父级后的实际激活状态
---@field visible boolean 只读：仅控制可见性
---@field name string 读写：控件名称
---@field parent ClientUIBaseControl 读写：父控件
---@field anchoredPositionX number 读写、Tweenable：位置
---@field anchoredPositionY number 读写、Tweenable：位置
---@field sizeDeltaX number 读写、Tweenable：大小差异
---@field sizeDeltaY number 读写、Tweenable：大小差异
---@field anchorMinX number 读写、Tweenable：最小锚点
---@field anchorMinY number 读写、Tweenable：最小锚点
---@field anchorMaxX number 读写、Tweenable：最大锚点
---@field anchorMaxY number 读写、Tweenable：最大锚点
---@field pivotX number 读写、Tweenable：中心
---@field pivotY number 读写、Tweenable：中心
---@field localScaleX number 读写、Tweenable：缩放
---@field localScaleY number 读写、Tweenable：缩放
---@field localScaleZ number 读写、Tweenable：缩放
---@field localRotationX number 读写、Tweenable：旋转
---@field localRotationY number 读写、Tweenable：旋转
---@field localRotationZ number 读写、Tweenable：旋转
---@field canControllerFocus boolean 读写：可被手柄导航摇杆聚焦
local ClientUIBaseControl = {}

-- ---- (2) 层级与可见性 ----

---获取直接子控件
---@return ClientUIBaseControl[]
function ClientUIBaseControl:GetChildren() end

---获取当前控件中名称为 name 的直接子控件
---@param name string
---@return ClientUIBaseControl
function ClientUIBaseControl:GetChild(name) end

---按路径查找子控件
---@param path string
---@return ClientUIBaseControl
function ClientUIBaseControl:FindChild(path) end

---设置激活状态；关闭后控件不可见且挂载脚本逻辑停止运行
---@param active boolean
function ClientUIBaseControl:SetActive(active) end

---仅设置可见性，不改变激活状态，也不停止脚本逻辑
---@param visible boolean
function ClientUIBaseControl:SetVisible(visible) end

---获取同级排序索引
---@return integer
function ClientUIBaseControl:GetSiblingIndex() end

---设置同级排序索引；数值越大通常越靠后、显示越靠上
---@param index integer
---@return boolean
function ClientUIBaseControl:SetSiblingIndex(index) end

---移到同级首位
---@return boolean
function ClientUIBaseControl:SetAsFirstSibling() end

---移到同级末位
---@return boolean
function ClientUIBaseControl:SetAsLastSibling() end

-- ---- (3) 布局与变换 ----

---获取位置（无父层级时以画布左下为原点；有父层级时相对父层级中心）
---@return number x
---@return number y
function ClientUIBaseControl:GetAnchoredPosition() end

---设置位置
---@param x number
---@param y number
function ClientUIBaseControl:SetAnchoredPosition(x, y) end

---获取大小
---@return number x
---@return number y
function ClientUIBaseControl:GetSizeDelta() end

---设置大小
---@param x number
---@param y number
function ClientUIBaseControl:SetSizeDelta(x, y) end

---获取最小锚点
---@return number x
---@return number y
function ClientUIBaseControl:GetAnchorMin() end

---设置最小锚点
---@param x number
---@param y number
function ClientUIBaseControl:SetAnchorMin(x, y) end

---获取最大锚点
---@return number x
---@return number y
function ClientUIBaseControl:GetAnchorMax() end

---设置最大锚点
---@param x number
---@param y number
function ClientUIBaseControl:SetAnchorMax(x, y) end

---获取中心
---@return number x
---@return number y
function ClientUIBaseControl:GetPivot() end

---设置中心
---@param x number
---@param y number
function ClientUIBaseControl:SetPivot(x, y) end

---获取缩放
---@return number x
---@return number y
---@return number z
function ClientUIBaseControl:GetLocalScale() end

---设置缩放
---@param x number
---@param y number
---@param z number
function ClientUIBaseControl:SetLocalScale(x, y, z) end

---获取旋转
---@return number x
---@return number y
---@return number z
function ClientUIBaseControl:GetLocalRotation() end

---设置旋转
---@param x number
---@param y number
---@param z number
function ClientUIBaseControl:SetLocalRotation(x, y, z) end

-- ---- (4) 脚本访问 ----

---按路径获取挂载脚本
---@param scriptPath string
---@return Script
function ClientUIBaseControl:GetScriptByPath(scriptPath) end

---按脚本映射 ID 获取脚本
---@param scriptMappingId integer
---@return Script
function ClientUIBaseControl:GetScript(scriptMappingId) end

---获取控件上全部脚本
---@return Script[]
function ClientUIBaseControl:GetScripts() end

-- ---- (5) 键鼠/手柄按键事件 ----

---注册指定按键事件监听；回调返回 boolean，标记为已处理可拦截同容器内其他按键
---@param eventType KeyEventType
---@param callback fun(...: any): boolean  -- 回调参数文档未明确
function ClientUIBaseControl:AddKeyEventListener(eventType, callback) end

---移除指定按键事件和回调的监听；回调必须与注册时的引用相同
---@param eventType KeyEventType
---@param callback fun(...: any): boolean  -- 回调参数文档未明确
function ClientUIBaseControl:RemoveKeyEventListener(eventType, callback) end

---移除指定按键事件的全部监听
---@param eventType KeyEventType
function ClientUIBaseControl:RemoveKeyEventListeners(eventType) end

---移除全部按键事件监听
function ClientUIBaseControl:RemoveAllKeyEventListeners() end

-- ---- (6) 手柄导航事件 ----

---注册指定手柄导航事件监听
---@param eventType ControllerNavigationEventType
---@param callback fun(...: any)  -- 回调参数文档未明确
function ClientUIBaseControl:AddNavigationEventListener(eventType, callback) end

---移除指定手柄导航事件和回调的监听
---@param eventType ControllerNavigationEventType
---@param callback fun(...: any)  -- 回调参数文档未明确
function ClientUIBaseControl:RemoveNavigationEventListener(eventType, callback) end

---移除指定手柄导航事件的全部监听
---@param eventType ControllerNavigationEventType
function ClientUIBaseControl:RemoveNavigationEventListeners(eventType) end

---移除全部手柄导航事件监听
function ClientUIBaseControl:RemoveAllNavigationEventListeners() end

-- ---- (7) 手柄导航配置 ----

---设置指定方向的导航模式和目标控件；目标可以为 nil
---@param navigationDir ControllerNavigationDir
---@param navigationMode ControllerNavigationMode
---@param navigationTarget ClientUIBaseControl|nil
function ClientUIBaseControl:SetControllerNavigation(navigationDir, navigationMode, navigationTarget) end

---获取指定方向的导航模式和目标控件
---@param navigationDir ControllerNavigationDir
---@return ControllerNavigationMode navigationMode
---@return ClientUIBaseControl navigationTarget
function ClientUIBaseControl:GetControllerNavigation(navigationDir) end


-- ============================================================
-- 11. ClientUIImageControl（图片）
-- ============================================================

---@class ClientUIImageControl : ClientUIBaseControl
---@field imageSource ImageSource 只读：图片来源
---@field imageId integer 只读：图片 ID
---@field imageColor ColorValue 读写、Tweenable：图片颜色
---@field imageType ImageType 读写：基础或拉伸类型
---@field enableMask boolean 读写：是否启用遮罩
---@field enableSoftEdge boolean 读写：是否启用边缘羽化
---@field softEdgeMode ImageMaskSoftEdgeMode 读写：边缘羽化模式
---@field softEdgeWidthX number 读写、Tweenable：水平边缘羽化宽度
---@field softEdgeWidthY number 读写、Tweenable：垂直边缘羽化宽度
---@field horizontalSoftRange number 读写、Tweenable：水平边缘羽化范围
---@field verticalSoftRange number 读写、Tweenable：垂直边缘羽化范围
---@field reverseMaskArea boolean 读写：是否反转遮罩区域
---@field fillType ImageFillType 读写：当前填充方式
---@field fillHorizontalType ImageFillHorizontalType 读写：水平填充方向
---@field fillVerticalType ImageFillVerticalType 读写：垂直填充方向
---@field fillRadial90Type ImageFillRadial90Type 读写：90 度环绕起点
---@field fillRadialType ImageFillRadialType 读写：180/360 度环绕起点
---@field fillAmount number 读写、Tweenable：进度
local ClientUIImageControl = {}

---设置图片来源与图片 ID
---@param imageSource ImageSource
---@param imageId integer
function ClientUIImageControl:SetImage(imageSource, imageId) end

---设置水平与垂直边缘羽化宽度
---@param widthX number
---@param widthY number
function ClientUIImageControl:SetSoftEdgeWidth(widthX, widthY) end

---设置为不使用填充
function ClientUIImageControl:SetFillUnused() end

---设置水平填充
---@param fillHorizontalType ImageFillHorizontalType
---@param fillAmount number
function ClientUIImageControl:SetFillHorizontal(fillHorizontalType, fillAmount) end

---设置垂直填充
---@param fillVerticalType ImageFillVerticalType
---@param fillAmount number
function ClientUIImageControl:SetFillVertical(fillVerticalType, fillAmount) end

---设置 90 度环绕填充
---@param fillRadial90Type ImageFillRadial90Type
---@param fillAmount number
function ClientUIImageControl:SetFillRadial90(fillRadial90Type, fillAmount) end

---设置 180 度环绕填充
---@param fillRadialType ImageFillRadialType
---@param fillAmount number
function ClientUIImageControl:SetFillRadial180(fillRadialType, fillAmount) end

---设置 360 度环绕填充
---@param fillRadialType ImageFillRadialType
---@param fillAmount number
function ClientUIImageControl:SetFillRadial360(fillRadialType, fillAmount) end


-- ============================================================
-- 12. ClientUITextBoxControl（文本框）
-- ============================================================

---@class ClientUITextBoxControl : ClientUIBaseControl
---@field text string 读写：显示文本
---@field fontSize integer 读写、Tweenable：字号
---@field fontColor ColorValue 读写、Tweenable：字色
---@field bgColor ColorValue 读写、Tweenable：背景色
---@field enableOutline boolean 读写：是否启用描边
---@field outlineColor ColorValue 读写、Tweenable：描边色
---@field horizontalAlignment TextHorizontalAlignment 读写：水平对齐
---@field verticalAlignment TextVerticalAlignment 读写：垂直对齐
---@field adaptiveFontSize boolean 读写：字号自适应
---@field minimumFontSize integer 读写、Tweenable：字号自适应的最小字号


-- ============================================================
-- 13. ClientUITextWindowControl（文本视窗）
-- ============================================================

---@class ClientUITextWindowControl : ClientUIBaseControl
---@field interactable boolean 读写：是否可交互
---@field showScrollBar boolean 读写：是否显示滚动条
---@field text string 读写：显示文本
---@field fontSize integer 读写、Tweenable：字号
---@field fontColor ColorValue 读写、Tweenable：字色
---@field bgColor ColorValue 读写、Tweenable：背景色
---@field enableOutline boolean 读写：是否启用描边
---@field outlineColor ColorValue 读写、Tweenable：描边色
---@field horizontalAlignment TextHorizontalAlignment 读写：水平对齐
---@field verticalAlignment TextVerticalAlignment 读写：垂直对齐
---@field adaptiveFontSize boolean 读写：字号自适应
---@field minimumFontSize integer 读写、Tweenable：字号自适应的最小字号


-- ============================================================
-- 14. ClientUIPresetButtonControl（预设按钮）
-- ============================================================

---@class ClientUIPresetButtonControl : ClientUIBaseControl
---@field interactable boolean 读写：是否可交互
---@field clickAudioId integer 读写：点击音效 ID
---@field raycastTarget boolean 读写：可被光标射线检测
local ClientUIPresetButtonControl = {}

---注册指定光标事件监听；回调接收 CursorEventData
---@param eventType CursorEventType
---@param callback fun(data: CursorEventData)  -- 回调参数类型文档仅说明为 CursorEventData
function ClientUIPresetButtonControl:AddCursorEventListener(eventType, callback) end

---移除指定光标事件和回调的监听
---@param eventType CursorEventType
---@param callback fun(data: CursorEventData)
function ClientUIPresetButtonControl:RemoveCursorEventListener(eventType, callback) end

---移除指定光标事件的全部监听
---@param eventType CursorEventType
function ClientUIPresetButtonControl:RemoveCursorEventListeners(eventType) end

---移除全部光标事件监听
function ClientUIPresetButtonControl:RemoveAllCursorEventListeners() end

---按顺序模拟 CursorDown、CursorUp 与 CursorClick
function ClientUIPresetButtonControl:SimulateCursorClick() end


-- ============================================================
-- 15. ClientUICursorEventAreaControl（光标检测区域）
-- ============================================================

---@class ClientUICursorEventAreaControl : ClientUIBaseControl
---@field raycastTarget boolean 读写：可被光标射线检测
local ClientUICursorEventAreaControl = {}

---注册指定光标事件监听；回调接收 CursorEventData
---@param eventType CursorEventType
---@param callback fun(data: CursorEventData)
function ClientUICursorEventAreaControl:AddCursorEventListener(eventType, callback) end

---移除指定光标事件和回调的监听
---@param eventType CursorEventType
---@param callback fun(data: CursorEventData)
function ClientUICursorEventAreaControl:RemoveCursorEventListener(eventType, callback) end

---移除指定光标事件的全部监听
---@param eventType CursorEventType
function ClientUICursorEventAreaControl:RemoveCursorEventListeners(eventType) end

---移除全部光标事件监听
function ClientUICursorEventAreaControl:RemoveAllCursorEventListeners() end

---按顺序模拟 CursorDown、CursorUp 与 CursorClick
function ClientUICursorEventAreaControl:SimulateCursorClick() end


-- ============================================================
-- 16. CursorEventData
-- ============================================================

---光标事件数据
---@class CursorEventData
---@field dragging boolean 只读：当前是否在拖拽
---@field touchId integer 只读：触点 ID
local CursorEventData = {}

---以画布左下角为原点，获取当前屏幕 UI 坐标
---@return number x
---@return number y
function CursorEventData:GetUIPos() end

---获取按下时的屏幕 UI 坐标
---@return number x
---@return number y
function CursorEventData:GetPressUIPos() end

---获取本次事件的屏幕 UI 位移
---@return number x
---@return number y
function CursorEventData:GetUIPosDelta() end


-- ============================================================
-- 17. ClientUIGridScrollerControl（网格视窗）
-- ============================================================

---@class ClientUIGridScrollerControl : ClientUIBaseControl
---@field itemCount integer 只读：列表项数量
---@field itemPrefabIndex integer 读写：列表项控件模板索引
---@field raycastTarget boolean 读写：可被光标射线检测
---@field showScrollBar boolean 读写：是否显示滚动条
---@field interactable boolean 读写：是否可交互
---@field scrollDirection ScrollDirection 只读：滚动方向
---@field layoutConstraint ScrollLayoutConstraint 只读：列表项布局约束
---@field layoutConstraintFixedCount number 只读：固定布局时每行/每列的列表项数量
---@field scrollProgress number 读写、Tweenable：滚动进度
local ClientUIGridScrollerControl = {}

---刷新列表项并逐项调用回调；
---回调形式为 fun(control: ClientUIBaseControl, index: integer)
---@param itemCount integer
---@param refreshCallback fun(control: ClientUIBaseControl, index: integer)
function ClientUIGridScrollerControl:RefreshItems(itemCount, refreshCallback) end

---获取列表项控件的索引
---@param control ClientUIBaseControl
---@return integer
function ClientUIGridScrollerControl:GetItemIndex(control) end

---获取列表项宽度与高度
---@return number x
---@return number y
function ClientUIGridScrollerControl:GetItemSize() end

---获取列表项的水平与垂直间距
---@return number x
---@return number y
function ClientUIGridScrollerControl:GetItemSpacing() end

---获取内容区域的上、下、左、右内边距
---@return number top
---@return number bottom
---@return number left
---@return number right
function ClientUIGridScrollerControl:GetPadding() end

---滚动到索引为 index 的列表项，并按 scrollAlignType 对齐
---@param index integer
---@param scrollAlignType ScrollAlignType
function ClientUIGridScrollerControl:ScrollToItemAt(index, scrollAlignType) end

---获取滚动内容在滚动方向上的长度
---@return number
function ClientUIGridScrollerControl:GetContentLength() end


-- ============================================================
-- 18. ClientUIKeyHintControl（按键提示）
-- ============================================================

---@class ClientUIKeyHintControl : ClientUIBaseControl
---@field keyboardKeyCode KeyboardKeyCode 读写：键鼠按键枚举值
---@field controllerKeyCode ControllerKeyCode 读写：手柄按键枚举值


-- ============================================================
-- 19. ClientUIAnimationControl（界面动效）
-- ============================================================

---@class ClientUIAnimationControl : ClientUIBaseControl
---@field animationId integer 读写：动效 ID
---@field playSoundEffect boolean 读写：是否播放动效音效
---@field layer UIAnimationLayer 读写：动效层级
local ClientUIAnimationControl = {}

---播放界面动效
function ClientUIAnimationControl:PlayAnimation() end

---停止界面动效
function ClientUIAnimationControl:StopAnimation() end


-- ============================================================
-- 20. ClientUIFullscreenAnimationControl（全屏动效）
-- ============================================================

---@class ClientUIFullscreenAnimationControl : ClientUIBaseControl
---@field animationId integer 读写：动效 ID
---@field playSoundEffect boolean 读写：是否播放动效音效


-- ============================================================
-- 21. ClientUIContainerControl（容器节点）
-- ============================================================

---@class ClientUIContainerControl : ClientUIBaseControl
---@field isolateNavigation boolean 读写：是否隔离手柄导航
---@field disableKeyEventPassthrough boolean 读写：是否屏蔽按键事件穿透
---@field disableCursorEventPassthrough boolean 读写：是否屏蔽区域内点击事件穿透
---@field showCursor boolean 读写：是否显示常驻光标
--（CursorEvent 相关方法需 showCursor 为真后才可正常使用）


-- ============================================================
-- 22. ClientUIReferenceControl（模板引用控件）
-- ============================================================

---@class ClientUIReferenceControl : ClientUIBaseControl
---@field referencedPrefabIndex integer 只读：引用控件模板索引