@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul
rem ============================================================
rem  小游戏骨架 - 部署脚本
rem  把打包产物复制到千星奇域映射目录
rem    关卡 ID：config.json 的 "levelId"
rem    产物名  ：config.json 的 "output"（缺省 game.lua）
rem  步骤：读配置 -> 定位映射目录 -> 语法检查 -> 复制 -> 校验哈希
rem ============================================================
for %%i in ("%~dp0..") do set "ROOT=%%~fi"
set "CFG=%ROOT%\config.json"

set "LEVELID="
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "try { (ConvertFrom-Json (Get-Content -Raw '%CFG%')).levelId } catch { '' }"`) do set "LEVELID=%%i"
if not defined LEVELID goto :nolevel
set "LEVELID=%LEVELID: =%"
if "%LEVELID%"=="" goto :nolevel

set "OUTNAME="
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "try { (ConvertFrom-Json (Get-Content -Raw '%CFG%')).output } catch { '' }"`) do set "OUTNAME=%%i"
if not defined OUTNAME set "OUTNAME=game.lua"

set "SRC=%ROOT%\%OUTNAME%"
set "REL=BeyondLocal\100267668\Beyond_Local_Save_Level\%LEVELID%\external_lua_file"
set "DSTDIR="
for /d %%g in ("%USERPROFILE%\AppData\LocalLow\miHoYo\*") do (
  if exist "%%g\%REL%" set "DSTDIR=%%g\%REL%"
)
if not defined DSTDIR (
  echo [FAIL] 未找到映射目录：
  echo        %REL%
  echo        请先在千星奇域里创建该关卡并进入一次（让目录生成），或核对 config.json 的 levelId
  echo.
  call :listlevels
  exit /b 1
)
set "DST=%DSTDIR%\%OUTNAME%"

if not exist "%SRC%" (
  echo [FAIL] 产物不存在：%SRC%
  echo        请先运行 tools\bundle.cmd
  exit /b 1
)

echo 源文件：%SRC%
echo 目标  ：%DST%
echo.

set "LUAC="
for /f "delims=" %%i in ('where luac 2^>nul') do if not defined LUAC set "LUAC=%%i"
if not defined LUAC if exist "%LOCALAPPDATA%\Programs\Lua\bin\luac.exe" set "LUAC=%LOCALAPPDATA%\Programs\Lua\bin\luac.exe"
if defined LUAC (
  "%LUAC%" -p "%SRC%"
  if errorlevel 1 ( echo [FAIL] 语法有误，已中止部署 & exit /b 1 )
  echo [PASS] 语法检查通过
) else (
  echo [SKIP] 未找到 luac，跳过语法检查
)

copy /Y "%SRC%" "%DST%" >nul
if errorlevel 1 ( echo [FAIL] 复制失败 & exit /b 1 )

set "H1="
set "H2="
for /f "delims=" %%h in ('powershell -NoProfile -Command "(Get-FileHash -Algorithm MD5 -LiteralPath '%SRC%').Hash"') do set "H1=%%h"
for /f "delims=" %%h in ('powershell -NoProfile -Command "(Get-FileHash -Algorithm MD5 -LiteralPath '%DST%').Hash"') do set "H2=%%h"
echo 源文件 MD5：%H1%
echo 映射 MD5：%H2%
if /i "%H1%"=="%H2%" ( echo [OK] 部署完成，两份文件一致 ) else ( echo [WARN] 哈希不一致，请检查 & exit /b 1 )
exit /b 0

:nolevel
echo [FAIL] config.json 里还没有填 levelId
echo.
echo 现有关卡目录（把目标关卡的 ID 填进 config.json 的 "levelId"）：
call :listlevels
exit /b 1

:listlevels
for /d %%g in ("%USERPROFILE%\AppData\LocalLow\miHoYo\*") do (
  if exist "%%g\BeyondLocal\100267668\Beyond_Local_Save_Level" (
    for /d %%d in ("%%g\BeyondLocal\100267668\Beyond_Local_Save_Level\*") do echo   %%~nxd
  )
)
exit /b 0
