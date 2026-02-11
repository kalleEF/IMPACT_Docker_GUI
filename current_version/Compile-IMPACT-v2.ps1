# IMPACT_v2.exe Compilation Script
# ================================
# Compiles the IMPACT_Docker_GUI_v2.ps1 PowerShell script into IMPACT_v2.exe
# with an optional custom icon.

param(
    [switch]$Verbose,
    [switch]$Force
)

# Prefer PowerShell 7 but allow Windows PowerShell as fallback
if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "Note: Running under Windows PowerShell $($PSVersionTable.PSVersion). PowerShell 7 (pwsh) is recommended but not required." -ForegroundColor Yellow
} else {
    Write-Host "Running under PowerShell 7 ($($PSVersionTable.PSVersion))" -ForegroundColor Green
}

# Ensure Windows PowerShell path is in PATH (ps2exe needs powershell.exe internally)
$winPSPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0"
if (-not ($env:PATH -split ';' | Where-Object { $_ -eq $winPSPath })) {
    $env:PATH = "$env:PATH;$winPSPath"
}

# Detect if running from batch file and auto-enable Force mode
$runningFromBatch = $env:PROMPT -ne $null -and $MyInvocation.MyCommand.CommandType -eq "ExternalScript"
if ($runningFromBatch -and -not $Force) {
    Write-Host "Detected execution from batch file - enabling Force mode automatically" -ForegroundColor Cyan
    $Force = $true
}

# Script configuration
$ScriptName = "IMPACT_Docker_GUI_v2.ps1"
$OutputExe = "IMPACT.exe"
$IconFile = "IMPACT_icon.ico"

Write-Host ""
Write-Host "IMPACT_v2.exe Compilation Script" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host ""

# Check if ps2exe module is available
Write-Host "Checking ps2exe module..." -ForegroundColor Yellow
$ps2exeModule = Get-Module -ListAvailable -Name ps2exe
if (-not $ps2exeModule) {
    Write-Host "ps2exe module not found. Installing..." -ForegroundColor Yellow
    try {
        Install-Module -Name ps2exe -Scope CurrentUser -Force
        Write-Host "ps2exe module installed successfully." -ForegroundColor Green
    } catch {
        Write-Host "Failed to install ps2exe module: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "ps2exe module found: $($ps2exeModule.Version)" -ForegroundColor Green
}

# Check if source script exists
if (-not (Test-Path $ScriptName)) {
    Write-Host "Error: Source script '$ScriptName' not found in current directory." -ForegroundColor Red
    exit 1
}

# Check if icon file exists
if (-not (Test-Path $IconFile)) {
    Write-Host "Warning: Icon file '$IconFile' not found. Compiling without icon..." -ForegroundColor Yellow
    $IconFile = $null
}

# Check if output file exists and handle force/overwrite
if (Test-Path $OutputExe) {
    if ($Force) {
        Write-Host "Existing '$OutputExe' will be overwritten (Force mode)." -ForegroundColor Yellow
        Remove-Item $OutputExe -Force
    } else {
        $overwrite = Read-Host "Existing '$OutputExe' found. Overwrite? (y/n)"
        if ($overwrite -notmatch "^[Yy]") {
            Write-Host "Compilation cancelled." -ForegroundColor Yellow
            exit 0
        }
        Remove-Item $OutputExe -Force
    }
}

# Prepare compilation parameters
$CompileParams = @{
    InputFile = $ScriptName
    OutputFile = $OutputExe
    NoConsole = $false  # Keep console for admin elevation
    NoOutput = $false   # Allow output
    NoError = $false    # Show errors
    NoConfigFile = $true # Don't use config file
    Verbose = $Verbose
}

# Add icon if available
if ($IconFile) {
    $CompileParams.iconFile = $IconFile
    Write-Host "Using icon file: $IconFile" -ForegroundColor Green
}

# Display compilation settings
Write-Host ""
Write-Host "Compilation Settings:" -ForegroundColor Cyan
Write-Host "  Source Script: $ScriptName" -ForegroundColor White
Write-Host "  Output File: $OutputExe" -ForegroundColor White
Write-Host "  Icon File: $(if($IconFile) { $IconFile } else { 'None' })" -ForegroundColor White
Write-Host "  Console Mode: Enabled (required for admin elevation)" -ForegroundColor White
Write-Host ""

# Perform compilation
# Verify powershell.exe is reachable (ps2exe calls it internally during compilation)
$psFallback = Get-Command powershell.exe -ErrorAction SilentlyContinue
if (-not $psFallback) {
    Write-Host "Warning: powershell.exe not found in PATH. Attempting to locate it..." -ForegroundColor Yellow
    $psExePaths = @(
        "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe",
        "$env:SystemRoot\SysWOW64\WindowsPowerShell\v1.0\powershell.exe",
        "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    )
    $found = $false
    foreach ($p in $psExePaths) {
        if (Test-Path $p) {
            $env:PATH = "$env:PATH;$(Split-Path $p)"
            Write-Host "  Found at: $p - added to PATH" -ForegroundColor Green
            $found = $true
            break
        }
    }
    if (-not $found) {
        Write-Host "Error: Cannot locate powershell.exe anywhere. Windows PowerShell is required by ps2exe." -ForegroundColor Red
        Write-Host "       Please ensure Windows PowerShell 5.1 is installed (it ships with Windows 10/11)." -ForegroundColor Red
        exit 1
    }
}

Write-Host "Starting compilation..." -ForegroundColor Yellow
try {
    Invoke-PS2EXE @CompileParams
    
    if (Test-Path $OutputExe) {
        $exeInfo = Get-Item $OutputExe
        Write-Host ""
        Write-Host "Compilation successful!" -ForegroundColor Green
        Write-Host "  Output: $OutputExe" -ForegroundColor White
        Write-Host "  Size: $([math]::Round($exeInfo.Length / 1KB, 2)) KB" -ForegroundColor White
        Write-Host "  Created: $($exeInfo.CreationTime)" -ForegroundColor White
        Write-Host ""
        Write-Host "Usage: Right-click '$OutputExe' and select 'Run as Administrator'" -ForegroundColor Yellow
        Write-Host "       or double-click to start with automatic elevation prompt." -ForegroundColor Yellow
    } else {
        Write-Host "Error: Compilation completed but output file not found." -ForegroundColor Red
        exit 1
    }
    
} catch {
    Write-Host "Compilation failed: $($_.Exception.Message)" -ForegroundColor Red
    
    # Check for common issues
    if ($_.Exception.Message -like "*icon*") {
        Write-Host ""
        Write-Host "Icon-related error detected. Trying compilation without icon..." -ForegroundColor Yellow
        $CompileParams.Remove('iconFile')
        try {
            Invoke-PS2EXE @CompileParams
            if (Test-Path $OutputExe) {
                Write-Host "Compilation successful without icon." -ForegroundColor Green
            }
        } catch {
            Write-Host "Compilation failed even without icon: $($_.Exception.Message)" -ForegroundColor Red
            exit 1
        }
    } else {
        exit 1
    }
}

Write-Host ""
Write-Host "Compilation process completed." -ForegroundColor Cyan
