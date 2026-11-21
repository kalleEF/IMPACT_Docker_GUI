@echo off
REM IMPACT desktop shortcut creator
REM ===============================
REM Double-click this file once to create an "IMPACT" shortcut on your Desktop.
REM
REM The shortcut starts IMPACT.bat (in this folder), not PowerShell directly.
REM IMPACT.bat checks that PowerShell 7 is installed, explains how to install
REM it if not, and keeps the window open when something goes wrong. A shortcut
REM straight to pwsh.exe would skip all of that (finding F105).
REM
REM Notes for maintainers:
REM - This file must keep Windows (CRLF) line endings (see .gitattributes).
REM - The folder path is handed to PowerShell through an environment variable
REM   instead of being pasted into the command text. A folder name containing
REM   "&" or an apostrophe (for example "F&E\IMPACT") used to break the command.
REM - Exit codes are saved right after the command, outside any "( ... )"
REM   block, because inside a block cmd reads %errorlevel% too early.

setlocal
cd /d "%~dp0"

echo.
echo Creating the IMPACT shortcut on your Desktop...
echo.

if not exist "%~dp0IMPACT.bat" goto :missing_files

set "IMPACT_SHORTCUT_DIR=%~dp0"

REM Windows PowerShell (powershell.exe) is part of every Windows 10/11 and is
REM enough for this small job; PowerShell 7 is not needed to create the shortcut.
REM
REM CreateShortcut opens an IMPACT.lnk that already exists and keeps all of its
REM old settings. Older versions of this file made a shortcut that started
REM PowerShell directly, with the arguments "-NoProfile -ExecutionPolicy Bypass
REM -File ...". If those arguments stayed, the new shortcut would hand them to
REM IMPACT.bat, which passes them on to the GUI script, and IMPACT would stop at
REM once ("A parameter cannot be found that matches parameter name 'NoProfile'").
REM That is why the arguments are always cleared below.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "$dir = $env:IMPACT_SHORTCUT_DIR; " ^
    "$ws = New-Object -ComObject WScript.Shell; " ^
    "$desktop = $ws.SpecialFolders('Desktop'); " ^
    "$lnk = $ws.CreateShortcut([IO.Path]::Combine($desktop, 'IMPACT.lnk')); " ^
    "$lnk.TargetPath = [IO.Path]::Combine($dir, 'IMPACT.bat'); " ^
    "$lnk.Arguments = ''; " ^
    "$lnk.WorkingDirectory = $dir; " ^
    "$icon = [IO.Path]::Combine($dir, 'IMPACT_icon.ico'); " ^
    "if (Test-Path -LiteralPath $icon) { $lnk.IconLocation = $icon }; " ^
    "$lnk.Description = 'IMPACT Docker GUI'; " ^
    "$lnk.Save(); " ^
    "Write-Host 'Shortcut created on your Desktop: IMPACT.lnk' -ForegroundColor Green"
set "SHORTCUT_EXIT=%errorlevel%"
if not "%SHORTCUT_EXIT%"=="0" goto :failed

REM Friendly hint only: the shortcut works, but IMPACT itself needs PowerShell 7.
REM Look in the same two places as IMPACT.bat: on PATH and in the standard
REM install folder. Right after installing PowerShell 7, Windows Explorer may
REM still use the old PATH, so "where" alone would wrongly say it is missing.
set "PWSH_FOUND="
where pwsh.exe >nul 2>&1
if not errorlevel 1 set "PWSH_FOUND=1"
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH_FOUND=1"
if not defined PWSH_FOUND echo Note: PowerShell 7 is not installed yet. When you start IMPACT, it explains how to install it.

echo.
echo Done! You can now start IMPACT with the IMPACT shortcut on your Desktop.
echo (Keep the IMPACT folder where it is: the shortcut points to this folder.)
echo.
timeout /t 10
exit /b 0

:missing_files
echo ERROR: IMPACT.bat was not found next to this file. Please run
echo Create-Shortcut.bat from inside the IMPACT folder (current_version).
goto :pause_and_fail

:failed
echo.
echo ERROR: The shortcut could not be created (exit code %SHORTCUT_EXIT%).
echo You can still start IMPACT by double-clicking IMPACT.bat in this folder.
goto :pause_and_fail

:pause_and_fail
echo.
echo Press any key to close this window...
pause >nul
exit /b 1
