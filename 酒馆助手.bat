@echo off
chcp 65001 > nul

powershell -ExecutionPolicy Bypass -File "%~dp0pc-st.ps1"

echo.
echo 助手已关闭。
pause
