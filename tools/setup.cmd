@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul
rem ============================================================
rem  坦克动荡 - 环境安装 / 自检（幂等，可反复运行）
rem  依赖：Lua 5.4（提供 luac，做语法检查）
rem        lua-language-server（做静态检查）
rem  两者均为“用户级”安装，不需要管理员权限
rem ============================================================
echo ============================================================
echo   坦克动荡 开发环境 安装 / 自检
echo ============================================================
echo.

rem ---- 检查 winget 是否可用 ----
set "WINGET=1"
where winget >nul 2>nul || set "WINGET="
if not defined WINGET (
  echo [WARN] 未检测到 winget，只做“检测”不自动安装。
  echo        如需自动安装，请先从 Microsoft Store 安装 “应用安装程序 App Installer”。
  echo.
)

rem ---- Lua / luac ----
set "LUAC="
for /f "delims=" %%i in ('where luac 2^>nul') do if not defined LUAC set "LUAC=%%i"
if not defined LUAC if exist "%LOCALAPPDATA%\Programs\Lua\bin\luac.exe" set "LUAC=%LOCALAPPDATA%\Programs\Lua\bin\luac.exe"
if not defined LUAC if defined WINGET (
  echo [..] 未找到 luac，正在安装 Lua（DEVCOM.Lua）...
  winget install --id DEVCOM.Lua -e --accept-source-agreements --accept-package-agreements
  if exist "%LOCALAPPDATA%\Programs\Lua\bin\luac.exe" set "LUAC=%LOCALAPPDATA%\Programs\Lua\bin\luac.exe"
)
if defined LUAC (
  echo [OK] luac : !LUAC!
  "!LUAC!" -v
) else (
  echo [MISS] luac 未就绪
)
echo.

rem ---- lua-language-server ----
set "LUALS="
for /f "delims=" %%i in ('where lua-language-server 2^>nul') do if not defined LUALS set "LUALS=%%i"
if not defined LUALS for /d %%d in ("%LOCALAPPDATA%\Microsoft\WinGet\Packages\LuaLS.lua-language-server_*") do set "LUALS=%%d\bin\lua-language-server.exe"
if not defined LUALS if defined WINGET (
  echo [..] 未找到 lua-language-server，正在安装（LuaLS.lua-language-server）...
  winget install --id LuaLS.lua-language-server -e --accept-source-agreements --accept-package-agreements
  for /d %%d in ("%LOCALAPPDATA%\Microsoft\WinGet\Packages\LuaLS.lua-language-server_*") do set "LUALS=%%d\bin\lua-language-server.exe"
)
if defined LUALS (
  echo [OK] lua-language-server : !LUALS!
  "!LUALS!" --version
) else (
  echo [MISS] lua-language-server 未就绪
)
echo.

rem ---- 部署映射目录 ----
set "REL=BeyondLocal\100267668\Beyond_Local_Save_Level\1073741827\external_lua_file"
set "DSTDIR="
for /d %%d in ("%USERPROFILE%\AppData\LocalLow\miHoYo\*") do if exist "%%d\%REL%" set "DSTDIR=%%d\%REL%"
if defined DSTDIR (
  echo [OK] 部署映射目录 : !DSTDIR!
) else (
  echo [MISS] 未找到部署映射目录，请先在千星奇域中创建并映射 external_lua_file
)
echo.

echo 提示：若想在任意终端直接敲 luac / lua-language-server，
echo       可把 %LOCALAPPDATA%\Programs\Lua\bin 加入用户 PATH。
echo       （本仓库的 tools\*.cmd 已内置自动定位，无需配置 PATH 也能用）
echo.
echo 自检完成。
exit /b 0