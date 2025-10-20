@echo off
%SystemRoot%\System32\chcp.exe 65001 > nul
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "%~dp0pc-st.ps1"
echo.
echo ÷˙ ÷“—πÿ±’°£
pause