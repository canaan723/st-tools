@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0pc-st.ps1"
if %ERRORLEVEL% EQU 2 exit /b
echo.
echo 助手已退出
pause
