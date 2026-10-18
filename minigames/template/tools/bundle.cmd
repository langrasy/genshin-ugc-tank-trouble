@echo off
setlocal
chcp 65001 >nul
rem 小游戏骨架 —— 打包（调用 bundle.ps1；产物名取自 config.json 的 output）
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bundle.ps1"
exit /b %errorlevel%
