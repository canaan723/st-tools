@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_PATH=%SCRIPT_DIR%pc-st.ps1"

if not exist "%SCRIPT_PATH%" goto err_missing_script

where powershell.exe >nul 2>nul
if errorlevel 1 goto err_missing_powershell

powershell.exe -NoProfile -Command "exit 0" >nul 2>nul
if errorlevel 1 goto err_powershell_start

set "GUGU_SCRIPT_DIR=%SCRIPT_DIR%"
powershell.exe -NoProfile -Command "$dir=$env:GUGU_SCRIPT_DIR; try { $cfg=Join-Path $dir '.config'; if (-not (Test-Path -LiteralPath $cfg)) { New-Item -Path $cfg -ItemType Directory -Force -ErrorAction Stop | Out-Null }; $probe=Join-Path $cfg '.launcher_probe'; Set-Content -LiteralPath $probe -Value 'ok' -Encoding UTF8 -ErrorAction Stop; Remove-Item -LiteralPath $probe -Force -ErrorAction Stop; exit 0 } catch { exit 21 }" >nul 2>nul
if errorlevel 1 goto err_script_dir_write

powershell.exe -NoProfile -Command "try { $probe=Join-Path ([System.IO.Path]::GetTempPath()) '.gugu_launcher_temp_probe'; Set-Content -LiteralPath $probe -Value 'ok' -Encoding UTF8 -ErrorAction Stop; Remove-Item -LiteralPath $probe -Force -ErrorAction Stop; $job=Start-Job -ScriptBlock { 1 }; Wait-Job $job -Timeout 3 | Out-Null; Remove-Job $job -Force -ErrorAction SilentlyContinue; exit 0 } catch { exit 22 }" >nul 2>nul
if errorlevel 1 goto err_temp_or_job

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%"
set "RC=%ERRORLEVEL%"
if "%RC%"=="0" goto normal_exit
if "%RC%"=="2" exit /b
goto err_script_launch

:normal_exit
echo.
echo 助手已退出
echo 按任意键关闭窗口...
pause >nul
exit /b

:err_missing_script
echo.
echo [Launcher] E01
echo pc-st.ps1 was not found next to this bat file.
echo Keep 咕咕助手.bat and pc-st.ps1 in the same folder.
echo 按任意键退出...
pause >nul
exit /b 1

:err_missing_powershell
echo.
echo [Launcher] E02
echo powershell.exe was not found in PATH.
echo Install or restore Windows PowerShell, then try again.
echo 按任意键退出...
pause >nul
exit /b 2

:err_powershell_start
echo.
echo [Launcher] E03
echo powershell.exe could not start with -NoProfile.
echo Likely causes:
echo 1. PowerShell is blocked by antivirus, AppLocker, WDAC, or enterprise policy.
echo 2. PowerShell itself is damaged or disabled on this machine.
echo Try running this bat as Administrator once.
echo 按任意键退出...
pause >nul
exit /b 3

:err_script_dir_write
echo.
echo [Launcher] E04
echo The current folder is not writable.
echo Move the whole folder to a normal writable path, for example D:\jiuguan
echo Do not run it directly from a zip file, system folder, or protected sync folder.
echo 按任意键退出...
pause >nul
exit /b 4

:err_temp_or_job
echo.
echo [Launcher] E05
echo TEMP folder or PowerShell background jobs are unavailable.
echo Check temp folder permissions and system security software, then try again.
echo 按任意键退出...
pause >nul
exit /b 5

:err_script_launch
echo.
echo [Launcher] E06
echo PowerShell started, but pc-st.ps1 exited early.
echo Likely causes:
echo 1. The script file was blocked by antivirus or system policy.
echo 2. Some files in this folder were locked by security or sync software.
echo 3. There is a machine-specific environment issue.
echo Try moving the whole folder to D:\jiuguan and run it as Administrator once.
echo 按任意键退出...
pause >nul
exit /b %RC%
