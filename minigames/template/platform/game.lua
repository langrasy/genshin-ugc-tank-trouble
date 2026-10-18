--[[ 小游戏骨架 —— 千星奇域「纯客户端」工程脚手架

  ⚠️ 本文件**只有脚手架，没有任何玩法**：
     OnInit 拿宿主 → OnStart 打印环境信息并开启逐帧 → OnLevelUpdate 供你写循环 → OnDestroy 收尾。

  分工（与主工程一致）：
     src/*.lua          纯逻辑：不碰 game.*，可直接单测
     platform/game.lua  平台层：把状态画出来 / 把输入变成动作（本文件）
     打包产物            由 tools/bundle.ps1 生成（禁止手改）

  控件 / 输入 / 坐标 / 自适应 / 踩坑：见仓库根目录 `技术总结.md`（§2 控件、§3 坐标、§4 输入）。
]]

local C = require("src.constants")

local host = nil
local running = false
local elapsed = 0

function OnInit()
  pcall(function() math.randomseed(os.time()) end)
  host = script.object
  print("[小游戏] OnInit，宿主类型=" .. tostring(typeof(host)))
  if host == nil then
    printerr("[小游戏] script.object 为空：请把脚本挂在客户端容器控件上")
    return
  end
  local dev = "?"
  pcall(function() dev = tostring(game.GetDevice()) end)
  print("[小游戏] 设备=" .. tostring(dev))
end

function OnStart()
  if host == nil then return end
  pcall(function() host.disableKeyEventPassthrough = true end)
  pcall(function() host.showCursor = true end)

  local vw, vh = 0, 0
  pcall(function() vw, vh = game.GetUICanvasSize() end)
  print("[小游戏] 画布=" .. tostring(vw) .. "×" .. tostring(vh)
    .. "（自适应缩放做法见 技术总结.md §3）")

  running = true
  print("[小游戏] OnStart 完成：骨架就绪（尚未实现玩法）")
  script:EnableUpdate(true)
end

function OnLevelUpdate(dt)
  if not running then return end
  dt = math.min(dt, 0.25)
  elapsed = elapsed + dt
  -- 玩法实现处：按 elapsed / dt 推进你的逻辑；渲染放这里（避免每帧重建控件）
end

function OnDestroy()
  running = false
  print("[小游戏] OnDestroy")
end
