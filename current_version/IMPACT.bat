@echo off
REM IMPACT Docker GUI Launcher
REM ==========================
REM Double-click this file to start the IMPACT Docker GUI.
REM Requires PowerShell 7 (pwsh) or Windows PowerShell.

cd /d "%~dp0"

REM Try PowerShell 7 first
where pwsh.exe >nul 2>&1
if %errorlevel% equ 0 (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0IMPACT_Docker_GUI_v2.ps1" %*
    if %errorlevel% neq 0 goto :error
    exit /b 0
)

REM Fallback to Windows PowerShell
where powershell.exe >nul 2>&1
if %errorlevel% equ 0 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0IMPACT_Docker_GUI_v2.ps1" %*
    if %errorlevel% neq 0 goto :error
    exit /b 0
)

echo.
echo ERROR: PowerShell not found.
echo Please install PowerShell 7 from https://aka.ms/powershell-release
echo.
goto :error

:error
echo.
echo Press any key to close...
pause >nul
exit /b 1
