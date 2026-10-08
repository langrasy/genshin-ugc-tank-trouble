@echo off
chcp 65001 >nul
setlocal
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File "
%PS%"%~dp0bundle.ps1"
if errorlevel 1 (
    echo [bundle] 打包失败
    exit /b 1
)
endlocal
