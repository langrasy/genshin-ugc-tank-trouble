@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul
rem ============================================================
rem  坦克动荡 - 单元测试
rem  1) 先打包，保证平台层冒烟测试跑的是最新产物
rem  2) 逐个运行 tests 下的用例，任一失败即返回非零
rem  注：测试用 ./?.lua 解析 src 模块，必须在仓库根目录下运行
rem ============================================================
for %%i in ("%~dp0..") do set "ROOT=%%~fi"

rem ---- 定位 lua ----
set "LUA="
for /f "delims=" %%i in ('where lua 2^>nul') do if not defined LUA set "LUA=%%i"
if not defined LUA if exist "%LOCALAPPDATA%\Programs\Lua\bin\lua.exe" set "LUA=%LOCALAPPDATA%\Programs\Lua\bin\lua.exe"
if not defined LUA ( echo [FAIL] 未找到 lua，请先运行 tools\setup.cmd & exit /b 1 )

rem ---- 先打包，保证产物与 src 一致 ----
call "%~dp0bundle.cmd"
if errorlevel 1 ( echo [FAIL] 打包失败 & exit /b 1 )

set "RC=0"
pushd "%ROOT%"
for %%t in (test_maze test_tank test_round test_platform) do (
  echo ============================================================
  echo  %%t
  echo ============================================================
  "%LUA%" "tests\%%t.lua"
  if errorlevel 1 set "RC=1"
)
popd

echo.
if "!RC!"=="0" ( echo 结果：全部通过 ) else ( echo 结果：存在失败用例 )
exit /b !RC!