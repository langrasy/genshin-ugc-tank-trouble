@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul
rem ============================================================
rem  小游戏骨架 - 本地检查（luac -p 语法 + LuaLS 静态检查）
rem ============================================================
for %%i in ("%~dp0..") do set "ROOT=%%~fi"
set "CFG=%ROOT%\config.json"
set "RC=0"

rem 产物名取自 config.json
set "OUTNAME="
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "try { (ConvertFrom-Json (Get-Content -Raw '%CFG%')).output } catch { '' }"`) do set "OUTNAME=%%i"
if not defined OUTNAME set "OUTNAME=game.lua"
set "SRC=%ROOT%\%OUTNAME%"

set "LUAC="
for /f "delims=" %%i in ('where luac 2^>nul') do if not defined LUAC set "LUAC=%%i"
if not defined LUAC if exist "%LOCALAPPDATA%\Programs\Lua\bin\luac.exe" set "LUAC=%LOCALAPPDATA%\Programs\Lua\bin\luac.exe"

set "LUALS="
for /f "delims=" %%i in ('where lua-language-server 2^>nul') do if not defined LUALS set "LUALS=%%i"
if not defined LUALS for /d %%d in ("%LOCALAPPDATA%\Microsoft\WinGet\Packages\LuaLS.lua-language-server_*") do set "LUALS=%%d\bin\lua-language-server.exe"

echo ============================================================
echo  [1/2] 语法检查  luac -p
echo ============================================================
if defined LUAC (
  "%LUAC%" -p "%SRC%"
  if errorlevel 1 ( echo [FAIL] 语法有误 & set "RC=1" ) else ( echo [PASS] 语法无误 )
) else (
  echo [SKIP] 未找到 luac
)

echo.
echo ============================================================
echo  [2/2] 静态检查  lua-language-server --check
echo ============================================================
if defined LUALS (
  rem 只查源码目录：产物是打包结果（内含 src 副本），一起查会报重复定义
  set "CHK=0"
  for %%d in (src platform tests) do (
    "%LUALS%" --check "%ROOT%\%%d" --checklevel=Warning --configpath="%ROOT%\.luarc.json" --logpath="%TEMP%\luals_minigame"
    if errorlevel 1 set "CHK=1"
  )
  if "!CHK!"=="1" ( echo [WARN] 见上方诊断 & set "RC=1" ) else ( echo [PASS] 无诊断信息 )
) else (
  echo [SKIP] 未找到 lua-language-server
)

echo.
if "!RC!"=="0" ( echo 结果：全部通过 ) else ( echo 结果：存在问题，见上方输出 )
exit /b !RC!
