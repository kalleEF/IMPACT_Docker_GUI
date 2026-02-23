@echo off
REM IMPACT Desktop Shortcut Creator
REM ================================
REM Double-click this file once to create an IMPACT shortcut on your Desktop.

cd /d "%~dp0"

echo.
echo Creating IMPACT desktop shortcut...
echo.

REM Determine which PowerShell to use for the shortcut target
set "PS_EXE="
where pwsh.exe >nul 2>&1
if %errorlevel% equ 0 (
    for /f "delims=" %%i in ('where pwsh.exe') do set "PS_EXE=%%i"
) else (
    where powershell.exe >nul 2>&1
    if %errorlevel% equ 0 (
        for /f "delims=" %%i in ('where powershell.exe') do set "PS_EXE=%%i"
    )
)

if "%PS_EXE%"=="" (
    echo ERROR: PowerShell not found.
    echo Please install PowerShell 7 from https://aka.ms/powershell-release
    pause
    exit /b 1
)

REM Use PowerShell to create the shortcut via WScript.Shell COM object
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "$ws = New-Object -ComObject WScript.Shell; " ^
    "$desktop = $ws.SpecialFolders('Desktop'); " ^
    "$lnk = $ws.CreateShortcut([IO.Path]::Combine($desktop, 'IMPACT.lnk')); " ^
    "$lnk.TargetPath = '%PS_EXE%'; " ^
    "$lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0IMPACT_Docker_GUI_v2.ps1\"'; " ^
    "$lnk.WorkingDirectory = '%~dp0'; " ^
    "$icon = '%~dp0IMPACT_icon.ico'; " ^
    "if (Test-Path $icon) { $lnk.IconLocation = $icon }; " ^
    "$lnk.Description = 'IMPACT Docker GUI'; " ^
    "$lnk.Save(); " ^
    "Write-Host 'Shortcut created on Desktop: IMPACT.lnk' -ForegroundColor Green"

if %errorlevel% neq 0 (
    echo.
    echo ERROR: Failed to create shortcut.
    pause
    exit /b 1
)

echo.
echo Done! You can now launch IMPACT from the shortcut on your Desktop.
echo.
timeout /t 5
