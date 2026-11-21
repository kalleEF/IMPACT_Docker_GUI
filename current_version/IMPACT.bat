@echo off
REM IMPACT Docker GUI launcher
REM ==========================
REM Double-click this file to start the IMPACT Docker GUI.
REM
REM IMPACT needs PowerShell 7.3 or newer (pwsh.exe). Windows itself only ships
REM the older "Windows PowerShell 5.1" (powershell.exe), which cannot run IMPACT.
REM This launcher therefore does NOT fall back to Windows PowerShell. When
REM PowerShell 7 is missing it explains how to install it and waits for a key
REM press, so the window does not just flash and close.
REM
REM Notes for maintainers:
REM - This file must keep Windows (CRLF) line endings. The .gitattributes file in
REM   the repository root makes git deliver it that way. With Unix (LF) line
REM   endings cmd.exe can fail to find the :labels used by "goto" below.
REM - There are deliberately no "( ... )" blocks around commands whose exit code
REM   is checked: inside such a block cmd reads %errorlevel% when the block starts,
REM   so the check always saw 0 and the error pause never ran (finding F69).

setlocal
cd /d "%~dp0"

REM The GUI script and its module must be in the same folder as this launcher.
REM A copy of IMPACT.bat on the Desktop cannot find them, so stop with a clear
REM message instead of a window that flashes and closes.
if not exist "%~dp0IMPACT_Docker_GUI_v2.ps1" goto :missing_files
if not exist "%~dp0IMPACT_Docker_GUI.psm1" goto :missing_files

REM Find PowerShell 7. First look on PATH, then in the standard install folder:
REM right after installing PowerShell 7, Windows Explorer may still use the old
REM PATH until the user signs out and back in.
set "PWSH_EXE="
for /f "delims=" %%P in ('where pwsh.exe 2^>nul') do if not defined PWSH_EXE set "PWSH_EXE=%%P"
if not defined PWSH_EXE if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH_EXE=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH_EXE goto :no_pwsh

REM PowerShell 7.0 - 7.2 is too old (it drops empty arguments such as the empty
REM SSH key passphrase). Check the version here, so the user gets one clear
REM message instead of two error boxes from inside the GUI. Exit code 3 means
REM "too old"; any other failure of this quick check is ignored and the GUI
REM itself checks the version again.
"%PWSH_EXE%" -NoLogo -NoProfile -NonInteractive -Command "if (($PSVersionTable.PSVersion.Major * 100 + $PSVersionTable.PSVersion.Minor) -lt 703) { exit 3 } else { exit 0 }" >nul 2>&1
set "PWSH_CHECK=%errorlevel%"
if "%PWSH_CHECK%"=="3" goto :pwsh_too_old

REM Start the GUI. The exit code is saved on the next line. That line is read by
REM cmd only when it runs, so it really sees the exit code of pwsh. Any value
REM other than 0 (also negative crash codes) counts as an error.
"%PWSH_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0IMPACT_Docker_GUI_v2.ps1" %*
set "IMPACT_EXIT=%errorlevel%"
if not "%IMPACT_EXIT%"=="0" goto :failed
exit /b 0

:no_pwsh
echo.
echo  ERROR: PowerShell 7 was not found on this computer.
echo.
echo  IMPACT needs PowerShell 7.3 or newer. Windows only includes the older
echo  "Windows PowerShell 5.1", which cannot run IMPACT.
echo.
echo  How to install PowerShell 7 (you only have to do this once):
echo.
echo    1. Open the Start menu, type  cmd  and open "Command Prompt".
echo    2. Type this command and press Enter:
echo.
echo         winget install --id Microsoft.PowerShell --source winget
echo.
echo    3. If "winget" is not found or is blocked on your computer, download the
echo       installer from  https://aka.ms/powershell-release
echo       (choose the file whose name ends in  -win-x64.msi ) and run it.
echo       You can also install "PowerShell" from the Microsoft Store.
echo    4. If the installation asks for administrator rights that you do not
echo       have, please ask your IT support to install PowerShell 7 for you.
echo.
echo  Then close this window and double-click IMPACT.bat again.
echo  If you still see this message, sign out of Windows and back in once.
echo.
choice /c OC /n /m "Press O to open the download page in your web browser, or C to close: "
if errorlevel 2 exit /b 1
start "" "https://aka.ms/powershell-release"
REM Do not exit straight away. When IMPACT.bat was started by double-click or
REM from the Desktop shortcut, exiting closes this window, and the install steps
REM above (which file to choose, the winget command, signing out and back in)
REM would disappear while the user is on the download page.
echo.
echo  The download page is opening in your web browser. Keep this window open
echo  while you install PowerShell 7, so that you can follow the steps above.
goto :pause_and_fail

:pwsh_too_old
echo.
echo  ERROR: Your PowerShell 7 is too old.
echo.
echo  IMPACT needs PowerShell 7.3 or newer. To update it, open "Command Prompt"
echo  and run:
echo.
echo         winget upgrade --id Microsoft.PowerShell --source winget
echo.
echo  or install the latest version from  https://aka.ms/powershell-release
echo  (choose the file whose name ends in  -win-x64.msi ).
echo  If you do not have administrator rights, please ask your IT support.
echo.
echo  Then double-click IMPACT.bat again.
goto :pause_and_fail

:missing_files
echo.
echo  ERROR: IMPACT_Docker_GUI_v2.ps1 or IMPACT_Docker_GUI.psm1 was not found
echo  next to this launcher, in this folder:
REM The quotes keep a folder name that contains "&" from breaking the echo.
echo     "%~dp0"
echo.
echo  IMPACT.bat must stay in the IMPACT folder (current_version) together with
echo  those files. Do not copy IMPACT.bat to the Desktop. To get a Desktop icon,
echo  double-click Create-Shortcut.bat in the IMPACT folder instead.
goto :pause_and_fail

:failed
echo.
echo  IMPACT stopped with an error (exit code %IMPACT_EXIT%).
echo  The details are in the console messages above and in the log file
echo  (normally %USERPROFILE%\.impact_gui\logs\impact.log).
goto :pause_and_fail

:pause_and_fail
echo.
echo  Press any key to close this window...
pause >nul
exit /b 1
