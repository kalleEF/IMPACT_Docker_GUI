@echo off
REM IMPACT_v2.exe Quick Compilation Batch File
REM ========================================
REM Double-click this file to quickly recompile IMPACT_v2.exe

REM Change to the directory where the batch file is located
cd /d "%~dp0"

echo.
echo IMPACT_v2.exe Quick Compilation
echo ============================
echo Current directory: %CD%
echo.

REM Check if Compile-IMPACT-v2.ps1 exists
if not exist "Compile-IMPACT-v2.ps1" (
    echo ERROR: Compile-IMPACT-v2.ps1 not found in current directory
    echo Please ensure this batch file is in the same folder as the PowerShell script
    echo.
    goto :error
)

REM Try PowerShell 7 first (if available), then fallback to Windows PowerShell
echo Checking for PowerShell 7...
pwsh.exe -Command "Write-Host 'PowerShell 7 found'" >nul 2>&1
if %errorlevel% equ 0 (
    echo Using PowerShell 7 for compilation...
    pwsh.exe -ExecutionPolicy Bypass -File ".\Compile-IMPACT-v2.ps1" -Force
) else (
    echo PowerShell 7 not found, using Windows PowerShell...
    powershell.exe -ExecutionPolicy Bypass -File ".\Compile-IMPACT-v2.ps1" -Force
)

REM Check if compilation was successful
if %errorlevel% equ 0 (
    echo.
    echo ============================
    echo Compilation completed successfully!
    echo ============================
) else (
    echo.
    echo ============================
    echo Compilation failed with error code: %errorlevel%
    echo ============================
    goto :error
)

echo.
echo Press any key to close this window...
pause >nul
exit /b 0

:error
echo.
echo Press any key to close this window...
pause >nul
exit /b 1
