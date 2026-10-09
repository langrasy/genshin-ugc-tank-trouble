# 坦克动荡 —— 单文件打包器
# 把 src/*.lua（纯逻辑模块）与 platform/game.lua（千星奇域平台层）内联成一份
# 可被千星奇域运行时直接加载的 tank_trouble.lua。
#
# 运行时没有 require：本脚本在产物顶部注入一个 local require 垫片，
# 各模块体被包进 function() ... end 注册到 __defs，模块内的 require 调用
# 会通过词法作用域解析到这个垫片（不会污染全局）。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tools\bundle.ps1

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $root 'src'
$platDir = Join-Path $root 'platform'
$outFile = Join-Path $root 'tank_trouble.lua'

# 顺序即依赖顺序（constants 无依赖，其余依赖 constants）
$modules = @(
    'src.constants',
    'src.maze',
    'src.tank',
    'src.weapons',
    'src.ai',
    'src.round',
    'src.net',
    'src.audio',
    'src.ach',
    'src.stats'
)

function Read-Source([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "找不到源文件：$path"
    }
    $text = [System.IO.File]::ReadAllText($path)
    # 去掉 UTF-8 BOM
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
        $text = $text.Substring(1)
    }
    # 统一 LF
    $text = $text -replace "`r`n", "`n"
    return $text
}

$sb = New-Object System.Text.StringBuilder

[void]$sb.AppendLine('--[[')
[void]$sb.AppendLine('  坦克动荡（千星奇域小游戏）—— 单文件产物')
[void]$sb.AppendLine('  本文件由 tools\bundle.ps1 自动生成，请勿手改。')
[void]$sb.AppendLine('  修改逻辑请改 src/*.lua；修改平台层请改 platform/game.lua；然后重新打包。')
[void]$sb.AppendLine(']]')
[void]$sb.AppendLine()
[void]$sb.AppendLine('-- ==================== 模块注册表 / require 垫片 ====================')
[void]$sb.AppendLine('local __defs, __cache = {}, {}')
[void]$sb.AppendLine('local function require(name)')
[void]$sb.AppendLine('  local cached = __cache[name]')
[void]$sb.AppendLine('  if cached ~= nil then return cached end')
[void]$sb.AppendLine('  local loader = __defs[name]')
[void]$sb.AppendLine('  if loader == nil then error("模块未找到: " .. tostring(name)) end')
[void]$sb.AppendLine('  local mod = loader()')
[void]$sb.AppendLine('  __cache[name] = mod')
[void]$sb.AppendLine('  return mod')
[void]$sb.AppendLine('end')
[void]$sb.AppendLine()

foreach ($name in $modules) {
    $rel = $name -replace '\.', '\'
    $path = Join-Path $root ($rel + '.lua')
    $body = Read-Source $path
    [void]$sb.AppendLine("-- ==================== 模块 $name ====================")
    [void]$sb.AppendLine("__defs[""$name""] = function()")
    [void]$sb.AppendLine($body)
    [void]$sb.AppendLine("end")
    [void]$sb.AppendLine()
}

$platPath = Join-Path $platDir 'game.lua'
$platBody = Read-Source $platPath
[void]$sb.AppendLine('-- ==================== 平台层 platform/game.lua ====================')
[void]$sb.AppendLine($platBody)

# 以 UTF-8 无 BOM + LF 写出
$outText = $sb.ToString() -replace "`r`n", "`n"
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($outFile, $outText, $enc)

$lines = ($outText -split "`n").Count
Write-Host "[bundle] 已生成 $outFile（$lines 行）"