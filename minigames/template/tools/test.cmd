@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul
rem ============================================================
rem  小游戏骨架 - 单元测试
rem  1) 先打包，保证产物与 src 一致
rem  2) 运行 tests 下的用例（纯逻辑，不需要千星奇域）
rem  用例清单：在下面的 for 列表里加（当前只有 test_smoke）
rem ============================================================
for %%i in ("%~dp0..") do set "ROOT=%%~fi"

set "LUA="
for /f "delims=" %%i in ('where lua 2^>nul') do if not defined LUA set "LUA=%%i"
if not defined LUA if exist "%LOCALAPPDATA%\Programs\Lua\bin\lua.exe" set "LUA=%LOCALAPPDATA%\Programs\Lua\bin\lua.exe"
if not defined LUA ( echo [FAIL] 未找到 lua，请先安装 Lua（winget install DEVCOM.Lua） & exit /b 1 )

call "%~dp0bundle.cmd"
if errorlevel 1 ( echo [FAIL] 打包失败 & exit /b 1 )

set "RC=0"
pushd "%ROOT%"
for %%t in (test_smoke) do (
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
