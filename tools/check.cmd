@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul
rem ============================================================
rem  坦克动荡 - 本地检查脚本
rem  1) luac -p   语法检查（最快，先跑）
rem  2) lua-language-server --check   静态检查（能抓方法名/字段名错误）
rem ============================================================
for %%i in ("%~dp0..") do set "ROOT=%%~fi"
set "SRC=%ROOT%\tank_trouble.lua"
set "RC=0"

rem ---- 定位 luac ----
set "LUAC="
for /f "delims=" %%i in ('where luac 2^>nul') do if not defined LUAC set "LUAC=%%i"
if not defined LUAC if exist "%LOCALAPPDATA%\Programs\Lua\bin\luac.exe" set "LUAC=%LOCALAPPDATA%\Programs\Lua\bin\luac.exe"

rem ---- 定位 lua-language-server ----
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
  echo [SKIP] 未找到 luac，请先运行 winget install DEVCOM.Lua
)

echo.
echo ============================================================
echo  [2/2] 静态检查  lua-language-server --check
echo ============================================================
if defined LUALS (
  "%LUALS%" --check "%ROOT%" --checklevel=Warning --configpath="%ROOT%\.luarc.json" --logpath="%TEMP%\luals_check"
  if errorlevel 1 ( echo [WARN] 见上方诊断 & set "RC=1" ) else ( echo [PASS] 无诊断信息 )
) else (
  echo [SKIP] 未找到 lua-language-server，请先运行 winget install LuaLS.lua-language-server
)

echo.
if "!RC!"=="0" ( echo 结果：全部通过 ) else ( echo 结果：存在问题，见上方输出 )
exit /b !RC!