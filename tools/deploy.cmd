@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul
rem ============================================================
rem  坦克动荡 - 部署脚本
rem  把源码 tank_trouble.lua 同步到千星奇域的映射目录 tt2.lua
rem  步骤：定位映射目录 -> 语法检查 -> 复制 -> 校验哈希一致
rem ============================================================
for %%i in ("%~dp0..") do set "ROOT=%%~fi"
set "SRC=%ROOT%\tank_trouble.lua"
set "REL=BeyondLocal\100267668\Beyond_Local_Save_Level\1073741827\external_lua_file"

rem ---- 定位映射目录：遍历 miHoYo 下各游戏目录，取真正包含目标路径的那个 ----
rem      （不硬编码“原神”等中文名，避免多游戏目录时抓错游戏）
set "DSTDIR="
for /d %%d in ("%USERPROFILE%\AppData\LocalLow\miHoYo\*") do (
  if exist "%%d\%REL%\tt2.lua" set "DSTDIR=%%d\%REL%"
)
if not defined DSTDIR (
  for /d %%d in ("%USERPROFILE%\AppData\LocalLow\miHoYo\*") do (
    if exist "%%d\%REL%" set "DSTDIR=%%d\%REL%"
  )
)
if not defined DSTDIR ( echo [FAIL] 未找到映射目录（external_lua_file），请确认千星奇域已生成该目录 & exit /b 1 )
set "DST=%DSTDIR%\tt2.lua"

echo 源文件：%SRC%
echo 目标  ：%DST%
echo.

rem ---- 定位 luac，部署前先做语法检查（防止把坏文件推上去）----
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

rem ---- 校验两份文件哈希一致 ----
set "H1="
set "H2="
for /f "delims=" %%h in ('powershell -NoProfile -Command "(Get-FileHash -Algorithm MD5 -LiteralPath '%SRC%').Hash"') do set "H1=%%h"
for /f "delims=" %%h in ('powershell -NoProfile -Command "(Get-FileHash -Algorithm MD5 -LiteralPath '%DST%').Hash"') do set "H2=%%h"
echo 源文件 MD5：%H1%
echo 映射 MD5：%H2%
if /i "%H1%"=="%H2%" ( echo [OK] 部署完成，两份文件一致 ) else ( echo [WARN] 哈希不一致，请检查 & exit /b 1 )
exit /b 0