#Requires -Version 7.0
<#
.SYNOPSIS
    TEMPORARY FEASIBILITY PROBE (work package 0 of the remote-mode redesign):
    can a GitHub Windows runner test the SSH tunnel that the IMPACT Docker GUI
    will start?

.DESCRIPTION
    This file is not a test of the IMPACT Docker GUI. Delete it, together with
    the job "probe-tunnel-windows" in .github/workflows/test.yml, once the
    question below is answered.

    THE QUESTION
      In the redesign the GUI starts an SSH tunnel on the Windows PC. It runs
      the Windows program ssh.exe as a hidden process:
          ssh -N -L 127.0.0.1:<PC port>:127.0.0.1:<workstation port> ...
      The browser on the PC then opens http://127.0.0.1:<PC port>/ and reaches
      RStudio on the workstation through the tunnel. We want to test this
      automatically on GitHub. A tunnel needs an SSH server to connect to, so
      the probe finds out whether a GitHub Windows runner can be its own SSH
      server, and how ssh.exe behaves when it is started the way the GUI will
      start it.

    WHAT THE PROBE DOES (the letters match the work package description)
      a. Lists which ssh.exe and sshd.exe exist (Windows OpenSSH, Git for
         Windows), their versions, and whether ssh.exe accepts "-F none".
      b. Starts an SSH server for the current user without a reboot. First
         way: the Windows OpenSSH Server (Add-WindowsCapability, Start-Service
         sshd). Second way, used when the first fails: sshd.exe from Git for
         Windows on port 2222 with a temporary configuration.
      c. Creates a key pair in a folder whose name contains a space and logs
         in with it: ssh -o BatchMode=yes ... whoami
      d. Starts a small web server on 127.0.0.1:8787. It stands in for RStudio.
      e. Starts the tunnel exactly as the GUI will start it (Start-Process with
         -WindowStyle Hidden and one argument string).
      f. Requests http://127.0.0.1:18787/ through the tunnel.
      g. Looks up who listens on port 18787 and what Windows knows about the
         tunnel process (start time, path, command line).
      h. Starts a second tunnel on the same port: does the second ssh.exe end
         by itself, with which exit code and which log text?
      i. Ends the first tunnel and checks that the port is free again.

    HOW TO READ THE OUTPUT
      Every check prints one line that starts with PASS, FAIL, SKIP or INFO:
        PASS  the check worked
        FAIL  the check did not work (the lines above it show the details)
        SKIP  the check could not be tried because an earlier step failed
        INFO  a fact for the report, with no right or wrong
      A summary table with all these lines is printed at the end. Everything
      is also saved in <OutputDirectory>\probe-output.txt, next to the log
      files of the tunnels.

    EXIT CODE
      0  the probe ran to the end. This is also the exit code when checks
         FAILED: the purpose of the probe is to report, not to stop the
         workflow.
      2  the probe could not run at all (not Windows, not a GitHub runner and
         no -Force, or the output folder cannot be created).

    WARNING: THIS SCRIPT CHANGES THE COMPUTER IT RUNS ON
      It may install and start the Windows OpenSSH Server, and it adds a login
      key for the current user. It undoes the key and stops the server at the
      end (an installed OpenSSH Server stays installed). It is written for a
      throw-away GitHub runner. On any other computer it refuses to start
      unless you add -Force.

.PARAMETER OutputDirectory
    Folder for the output file and the tunnel log files. It is created when it
    does not exist. Default: tests/artifacts/probes/windows-tunnel (git
    ignores the folder tests/artifacts).

.PARAMETER ServerMethod
    Which SSH server to try. Auto (default): Windows OpenSSH Server first, then
    sshd.exe from Git for Windows. WindowsOpenSsh or GitSshd: only that one.

.PARAMETER Force
    Run although this is not a GitHub runner. Read the warning above first.

.EXAMPLE
    pwsh -File tests/Probes/Probe-WindowsTunnel.ps1 -OutputDirectory out
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..' 'artifacts' 'probes' 'windows-tunnel'),

    [ValidateSet('Auto', 'WindowsOpenSsh', 'GitSshd')]
    [string]$ServerMethod = 'Auto',

    [switch]$Force
)

# 'Continue' means: after an error, go on with the next command. A probe must
# not stop at the first problem. Where an error has to be caught, the code uses
# try { } catch { } with "-ErrorAction Stop".
$ErrorActionPreference = 'Continue'

# No progress bars: in a log file they only produce unreadable lines.
$ProgressPreference = 'SilentlyContinue'

# Strict mode turns a typing mistake in a variable or property name into an
# error. Without it PowerShell would silently use an empty value, and the probe
# could report nonsense.
Set-StrictMode -Version 3.0

# The port numbers the probe uses.
$TargetPort  = 8787     # "workstation side": the small web server that stands in for RStudio
$TunnelPort  = 18787    # "PC side": the port that ssh.exe opens on 127.0.0.1
$GitSshdPort = 2222     # port of the second-way SSH server (sshd.exe from Git for Windows)

# ==============================================================================
#  Helper functions: output
# ==============================================================================

function Write-ProbeLine {
    <#
    .SYNOPSIS
        Prints one line and also appends it to the output file.
    .DESCRIPTION
        Every line of the probe goes through this function. That is how the
        complete output ends up in probe-output.txt, which the workflow uploads.
    #>
    param([AllowEmptyString()][string]$Text = '')

    Write-Host $Text
    if ($Probe.OutputFile) {
        try {
            Add-Content -LiteralPath $Probe.OutputFile -Value $Text -Encoding utf8 -ErrorAction Stop
        } catch {
            # The line was printed already. A problem with the file must not stop the probe.
            $null = $_
        }
    }
}

function Write-ProbeBlock {
    <#
    .SYNOPSIS
        Prints the output of a tool, or the content of a file, with a prefix on
        every line, so that it is easy to tell apart from the probe's own lines.
    #>
    param(
        [AllowNull()][object]$Text,
        [string]$Prefix = '      | '
    )

    if ($null -eq $Text) { return }
    # $Text may be one string with several lines, or a list of lines. Turn it
    # into one string, then cut it into lines.
    $joined = (@($Text) | ForEach-Object { "$_" }) -join "`n"
    $joined = $joined.TrimEnd()
    if ($joined -eq '') {
        Write-ProbeLine ($Prefix + '(nothing)')
        return
    }
    foreach ($line in ($joined -split "`r?`n")) {
        Write-ProbeLine ($Prefix + $line)
    }
}

function Write-ProbeSection {
    <# .SYNOPSIS Prints a headline between the steps. #>
    param([string]$Title)
    Write-ProbeLine ''
    Write-ProbeLine "==== $Title ===="
}

function Add-ProbeResult {
    <#
    .SYNOPSIS
        Stores one result (PASS, FAIL, SKIP or INFO) for the summary table and
        prints it at once.
    #>
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'SKIP', 'INFO')][string]$State,
        [Parameter(Mandatory)][string]$Text
    )

    $Probe.Results.Add([pscustomobject]@{ Result = $State; Step = $Step; What = $Text })
    Write-ProbeLine ('{0,-4}  [{1}] {2}' -f $State, $Step, $Text)
}

function Show-ProbeFile {
    <# .SYNOPSIS Prints the content of a text file (for example an ssh log). #>
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-ProbeLine "      (the file does not exist: $Path)"
        return
    }
    try {
        $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    } catch {
        Write-ProbeLine "      (the file cannot be read: $($_.Exception.Message))"
        return
    }
    if ([string]::IsNullOrWhiteSpace($content)) {
        Write-ProbeLine '      (the file is empty)'
    } else {
        Write-ProbeBlock $content
    }
}

function ConvertTo-ProbeOneLine {
    <#
    .SYNOPSIS
        Turns a text with several lines into ONE line, for a PASS / FAIL line.
    .DESCRIPTION
        Empty lines are dropped, the others are joined with " / ". An empty
        text becomes "(nothing)".
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)

    $lines = @("$Text" -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($lines.Count -eq 0) { return '(nothing)' }
    return ($lines -join ' / ')
}

function Get-ProbeFileText {
    <# .SYNOPSIS Returns the content of a text file, or an empty text when it cannot be read. #>
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $content = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ($null -eq $content) { return '' }
    return $content
}

function Get-ProbeFileTextShared {
    <#
    .SYNOPSIS
        Reads a text file that another program may still have open for writing.
    .DESCRIPTION
        Get-Content can fail on a file that a running program holds open. This
        function asks Windows for the file with the widest sharing: other
        programs may read, write and delete it at the same time.
        It returns a table with three entries: Ok (true or false), Text (the
        content) and Error (the message when reading failed).
    #>
    param([string]$Path)

    $result = @{ Ok = $false; Text = ''; Error = '' }
    $stream = $null
    $reader = $null
    try {
        # "-bor" combines the two sharing rights into one value.
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        $reader = [System.IO.StreamReader]::new($stream)
        $result.Text = $reader.ReadToEnd()
        $result.Ok = $true
    } catch {
        $result.Error = $_.Exception.Message
    } finally {
        # Close the file again in every case. Closing the reader closes the stream too.
        if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() }
    }
    return $result
}

# ==============================================================================
#  Helper functions: running programs, ports, HTTP
# ==============================================================================

function Invoke-ProbeTool {
    <#
    .SYNOPSIS
        Runs a program, waits for it (with a time limit) and returns its output
        and exit code.
    .DESCRIPTION
        The probe starts ssh.exe, ssh-keygen.exe, icacls.exe and others through
        this function, for three reasons:
          1. A time limit. If the program hangs, it is stopped and the probe
             goes on.
          2. An empty input. The program can never wait for somebody to type.
          3. Every argument is passed on exactly as given, also an empty one
             (ssh-keygen needs -N "" for "no passphrase") and one with spaces.
        One program gets special care: powershell.exe (Windows PowerShell 5.1).
        It is started with the module search path it expects, see the comment
        in the code below.
    .OUTPUTS
        An object with: Started, TimedOut, ExitCode, StdOut, StdErr, Text
        (StdOut and StdErr together).
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 60,
        # -Quiet: do not print the command and its output.
        [switch]$Quiet
    )

    $result = [pscustomobject]@{
        Started  = $false
        TimedOut = $false
        ExitCode = $null
        StdOut   = ''
        StdErr   = ''
        Text     = ''
    }
    if (-not $Quiet) {
        # Print the command. An empty argument is shown as "" and an argument
        # with a space in quotes, so that the printed line can be read correctly.
        $shown = foreach ($argument in $Arguments) {
            if ($argument -eq '') { '""' } elseif ($argument -match '\s') { '"' + $argument + '"' } else { $argument }
        }
        Write-ProbeLine ('    > "{0}" {1}' -f $FilePath, (@($shown) -join ' '))
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false          # needed to capture the output
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    # Special care for powershell.exe (Windows PowerShell 5.1).
    # A started program inherits the environment variables of this script. This
    # script runs in PowerShell 7, whose variable PSModulePath (the list of
    # folders in which PowerShell looks for modules) has the module folders of
    # PowerShell 7 in front. With that list Windows PowerShell can pick up the
    # PowerShell 7 copies of its own built-in modules, fail to load them, and
    # report an error that has nothing to do with the runner. PowerShell 7
    # corrects the list by itself only when it starts powershell.exe as a
    # command. It does not do so for a program started through the .NET class
    # used here. So the list is corrected here: powershell.exe gets the value
    # that Windows stores for the whole computer ("Machine"), which contains
    # the module folders of Windows PowerShell and none of PowerShell 7.
    if ([System.IO.Path]::GetFileName($FilePath) -ieq 'powershell.exe') {
        $machineModulePath = [System.Environment]::GetEnvironmentVariable('PSModulePath', [System.EnvironmentVariableTarget]::Machine)
        if ($machineModulePath) {
            $startInfo.Environment['PSModulePath'] = $machineModulePath
        } else {
            # Nothing is stored for the computer: start powershell.exe without
            # the variable. Windows PowerShell then builds its standard list.
            [void]$startInfo.Environment.Remove('PSModulePath')
        }
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
    } catch {
        $result.Text = "could not start the program: $($_.Exception.Message)"
        if (-not $Quiet) { Write-ProbeBlock $result.Text }
        return $result
    }
    $result.Started = $true

    # Close the input at once: the program sees "end of input".
    $process.StandardInput.Close()
    # Read both outputs in the background while the program runs. Reading only
    # after the end can block when a program writes a lot.
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $result.TimedOut = $true
        try { $process.Kill($true) } catch { $null = $_ }   # $true = also end child processes
        [void]$process.WaitForExit(5000)
    }
    try { if ($stdoutTask.Wait(5000)) { $result.StdOut = $stdoutTask.Result } } catch { $null = $_ }
    try { if ($stderrTask.Wait(5000)) { $result.StdErr = $stderrTask.Result } } catch { $null = $_ }
    if ($process.HasExited) { $result.ExitCode = $process.ExitCode }
    $process.Dispose()

    $parts = @($result.StdOut, $result.StdErr) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd() }
    $result.Text = @($parts) -join "`n"

    if (-not $Quiet) {
        if ($result.Text) { Write-ProbeBlock $result.Text }
        $limitNote = if ($result.TimedOut) { " (stopped after the time limit of $TimeoutSeconds seconds)" } else { '' }
        Write-ProbeLine ("      exit code: {0}{1}" -f $result.ExitCode, $limitNote)
    }
    return $result
}

function Get-ProbeToolVersion {
    <#
    .SYNOPSIS
        Returns the version line of an OpenSSH program ("OpenSSH_9.5p1, ...").
    .DESCRIPTION
        "-V" makes ssh.exe print its version. Older sshd.exe versions do not
        know "-V", but they print the version line together with their error
        message, so the same call works for them too.
    #>
    param([string]$FilePath)

    $run = Invoke-ProbeTool -FilePath $FilePath -Arguments @('-V') -TimeoutSeconds 20 -Quiet
    $line = ($run.Text -split "`r?`n") | Where-Object { $_ -match 'OpenSSH' } | Select-Object -First 1
    if ($line) { return $line.Trim() }
    return 'version unknown'
}

function Test-TcpPort {
    <# .SYNOPSIS True when something accepts connections on the address and port. #>
    param(
        [Parameter(Mandatory)][int]$Port,
        [string]$Address = '127.0.0.1',
        [int]$TimeoutMilliseconds = 1000
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($Address, $Port)
        return ($task.Wait($TimeoutMilliseconds) -and $client.Connected)
    } catch {
        # "Connection refused" arrives here as an error: nothing listens.
        return $false
    } finally {
        $client.Dispose()
    }
}

function Wait-TcpPort {
    <#
    .SYNOPSIS
        Waits until the port accepts connections. Returns $false when the time
        is over, or when the process that was expected to open the port has ended.
    #>
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$Seconds = 20,
        [System.Diagnostics.Process]$Process
    )

    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPort -Port $Port) { return $true }
        if ($Process -and $Process.HasExited) { return $false }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

function Test-ProbePortFree {
    <#
    .SYNOPSIS
        True when a new program could open the port on 127.0.0.1 right now.
    .DESCRIPTION
        The function opens the port itself for a moment. ExclusiveAddressUse
        makes Windows refuse this when any other program has the port open.
    #>
    param([Parameter(Mandatory)][int]$Port)

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    try {
        try { $listener.ExclusiveAddressUse = $true } catch { $null = $_ }
        $listener.Start()
        $listener.Stop()
        return $true
    } catch {
        return $false
    }
}

function Invoke-ProbeHttpRequest {
    <#
    .SYNOPSIS
        Requests a page and returns the HTTP status code. Tries again until it
        gets an answer or the total time is over.
    .DESCRIPTION
        UseProxy = $false: the request goes directly to the address, never
        through a web proxy configured on the computer. Each single try waits
        at most 3 seconds.
    .OUTPUTS
        An object with: StatusCode (0 = no answer), Body, Attempts, Seconds, Error.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$TotalSeconds = 30
    )

    $result = [pscustomobject]@{ StatusCode = 0; Body = ''; Attempts = 0; Seconds = 0.0; Error = '' }
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(3)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        do {
            $result.Attempts++
            try {
                $response = $client.GetAsync($Url).GetAwaiter().GetResult()
                $result.StatusCode = [int]$response.StatusCode
                $result.Body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                $result.Error = ''
                $response.Dispose()
                break
            } catch {
                $result.Error = $_.Exception.GetBaseException().Message
                Start-Sleep -Milliseconds 500
            }
        } while ($watch.Elapsed.TotalSeconds -lt $TotalSeconds)
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
    $result.Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
    return $result
}

# ==============================================================================
#  Helper functions: files, access rights, user
# ==============================================================================

function Get-ProbeUserInfo {
    <#
    .SYNOPSIS
        Returns facts about the Windows user that runs the probe.
    .OUTPUTS
        An object with: Name (login name), FullName (COMPUTER\name), Sid (the
        unique number of the account), IsElevatedAdmin (true when the process
        has administrator rights).
    #>
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
    return [pscustomobject]@{
        Name            = [System.Environment]::UserName
        FullName        = $identity.Name
        Sid             = $identity.User.Value
        IsElevatedAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
}

function Backup-ProbeFile {
    <#
    .SYNOPSIS
        Remembers the present state of a file that the probe is about to
        change, so that the clean-up can put it back.
    .DESCRIPTION
        When the file exists, a copy is saved. When it does not exist, the
        clean-up deletes the file the probe created.
    #>
    param([Parameter(Mandatory)][string]$Path)

    # Remember each file only once: a second copy would already contain the probe's change.
    foreach ($known in $Probe.Backups) {
        if ($known.Path -eq $Path) { return }
    }
    $entry = [pscustomobject]@{ Path = $Path; Existed = (Test-Path -LiteralPath $Path); Copy = '' }
    if ($entry.Existed) {
        $name = 'backup-{0}-{1}' -f $Probe.Backups.Count, (Split-Path -Leaf $Path)
        $entry.Copy = Join-Path $Probe.WorkDirectory $name
        Copy-Item -LiteralPath $Path -Destination $entry.Copy -Force -ErrorAction Stop
    }
    $Probe.Backups.Add($entry)
}

function Set-ProbeFileAccess {
    <#
    .SYNOPSIS
        Limits the access rights of a file to the given accounts and prints the
        result.
    .DESCRIPTION
        OpenSSH on Windows refuses a private key and an authorized_keys file
        when other accounts may read or change them. icacls.exe is the Windows
        tool for access rights:
          /inheritance:r   drop the rights the file inherits from its folder
          /grant:r X:F     give account X full access, replacing older entries
        An account is given as its SID with a star in front. "S-1-5-18" is the
        system account and "S-1-5-32-544" the Administrators group. The numbers
        are the same on every Windows, whatever its language.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$AllowedSids
    )

    $arguments = @($Path, '/inheritance:r')
    foreach ($sid in $AllowedSids) {
        $arguments += '/grant:r'
        $arguments += ('*{0}:F' -f $sid)
    }
    $run = Invoke-ProbeTool -FilePath $Probe.Icacls -Arguments $arguments -TimeoutSeconds 30
    return ($run.ExitCode -eq 0)
}

function Show-ProbeFileAccess {
    <# .SYNOPSIS Prints who may access a file (the output of icacls.exe). #>
    param([Parameter(Mandatory)][string]$Path)
    $null = Invoke-ProbeTool -FilePath $Probe.Icacls -Arguments @($Path) -TimeoutSeconds 30
}

function ConvertTo-MsysPath {
    <#
    .SYNOPSIS
        Turns a Windows path into the form the programs of Git for Windows
        expect: C:\Users\me\file becomes /c/Users/me/file.
    .DESCRIPTION
        sshd.exe from Git for Windows treats a path in its configuration as
        "absolute" only when it starts with a slash. A path that starts with
        "C:" would be looked up inside the user's home folder.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if ($Path -match '^([A-Za-z]):[\\/](.*)$') {
        return '/' + $Matches[1].ToLower() + '/' + ($Matches[2] -replace '\\', '/')
    }
    return ($Path -replace '\\', '/')
}

function Format-ProbeConfigValue {
    <# .SYNOPSIS Puts a value in double quotes when it contains a space (for sshd_config). #>
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -match '\s') { return '"' + $Value + '"' }
    return $Value
}

function Find-ProbeGitRoot {
    <#
    .SYNOPSIS
        Returns the installation folder of Git for Windows (the folder that
        contains usr\bin\ssh.exe), or $null when it is not found.
    #>
    $candidates = [System.Collections.Generic.List[string]]::new()

    # git.exe is in <root>\cmd, <root>\bin or <root>\mingw64\bin. So the root
    # is one of the next three folders above git.exe.
    $git = Get-Command -Name 'git.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($git) {
        $folder = Split-Path -Parent $git.Source
        for ($level = 0; $level -lt 3 -and $folder; $level++) {
            $candidates.Add($folder)
            $folder = Split-Path -Parent $folder
        }
    }
    # The usual installation folders.
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) { $candidates.Add((Join-Path $base 'Git')) }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'usr' 'bin' 'ssh.exe')) { return $candidate }
    }
    return $null
}

# ==============================================================================
#  Step a: which ssh.exe and sshd.exe exist
# ==============================================================================

function Invoke-ProbeInventory {
    Write-ProbeSection 'a. Which ssh.exe and sshd.exe exist on this computer'

    # --- a1: the computer and the user ---------------------------------------
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        Write-ProbeLine "    Windows: $($os.Caption), version $($os.Version)"
    } catch {
        Write-ProbeLine "    Windows version unknown: $($_.Exception.Message)"
    }
    Write-ProbeLine "    PowerShell: $($PSVersionTable.PSVersion)"
    Add-ProbeResult -Step 'a1' -State INFO -Text ("the probe runs as '{0}'; administrator rights: {1}" -f $Probe.User.FullName, $Probe.User.IsElevatedAdmin)

    # --- a2: the OpenSSH folder of Windows -------------------------------------
    # Windows keeps its own OpenSSH programs in C:\Windows\System32\OpenSSH.
    # This ssh.exe is the one the GUI will use for the tunnel.
    $windowsFolder = Join-Path $env:SystemRoot 'System32' 'OpenSSH'
    Write-ProbeLine "    programs in ${windowsFolder}:"
    if (Test-Path -LiteralPath $windowsFolder) {
        $programs = @(Get-ChildItem -LiteralPath $windowsFolder -Filter '*.exe' -ErrorAction SilentlyContinue)
        foreach ($program in $programs) {
            Write-ProbeLine ("      | {0,-22} file version {1}" -f $program.Name, $program.VersionInfo.FileVersion)
        }
        if ($programs.Count -eq 0) { Write-ProbeLine '      | (no programs)' }
    } else {
        Write-ProbeLine '      | (the folder does not exist)'
    }

    $windowsSsh = Join-Path $windowsFolder 'ssh.exe'
    if (Test-Path -LiteralPath $windowsSsh) {
        $Probe.ClientSsh = $windowsSsh
        $keygen = Join-Path $windowsFolder 'ssh-keygen.exe'
        if (Test-Path -LiteralPath $keygen) { $Probe.ClientKeygen = $keygen }
        Add-ProbeResult -Step 'a2' -State PASS -Text ("Windows OpenSSH client found: {0} ({1})" -f $windowsSsh, (Get-ProbeToolVersion $windowsSsh))
    } else {
        Add-ProbeResult -Step 'a2' -State FAIL -Text "Windows OpenSSH client NOT found: $windowsSsh does not exist"
    }

    # --- a3: the OpenSSH Server of Windows -------------------------------------
    # The server is an optional part of Windows (a "capability"). Three facts:
    # is sshd.exe on the disk, what does Windows say about the capability, and
    # is the Windows service "sshd" registered.
    $windowsSshd = Join-Path $windowsFolder 'sshd.exe'
    $sshdText = if (Test-Path -LiteralPath $windowsSshd) { "present ($(Get-ProbeToolVersion $windowsSshd))" } else { 'not present' }

    # Get-WindowsCapability belongs to Windows PowerShell 5.1 (powershell.exe).
    # PowerShell 7 can often load it as well, but not always. So the probe
    # calls powershell.exe itself, which also allows a time limit.
    # Invoke-ProbeTool starts powershell.exe with the module search path of
    # Windows PowerShell (see the comment there).
    $capabilityText = 'unknown'
    $capabilityRun = Invoke-ProbeTool -FilePath $Probe.WindowsPowerShell -TimeoutSeconds 300 -Arguments @(
        '-NoProfile', '-NonInteractive', '-Command',
        "Get-WindowsCapability -Online -Name 'OpenSSH*' | ForEach-Object { `$_.Name + ' = ' + `$_.State }"
    )
    if ($capabilityRun.StdOut -match '(?m)^OpenSSH\.Server\S*\s*=\s*(\S+)') {
        $capabilityText = $Matches[1]
    } else {
        # No state in the answer: say what powershell.exe reported, so that the
        # word "unknown" does not stand alone in the summary.
        $capabilityText = "unknown (powershell.exe ended with exit code $($capabilityRun.ExitCode) and reported: $(ConvertTo-ProbeOneLine $capabilityRun.StdErr))"
    }

    $service = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
    $serviceText = if ($service) { "$($service.Status), start type $($service.StartType)" } else { 'not registered' }
    Add-ProbeResult -Step 'a3' -State INFO -Text "Windows OpenSSH Server: sshd.exe $sshdText; capability state: $capabilityText; service 'sshd': $serviceText"

    # A second place where OpenSSH for Windows can be installed by hand.
    $manualFolder = if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'OpenSSH' } else { '' }
    if ($manualFolder -and (Test-Path -LiteralPath (Join-Path $manualFolder 'ssh.exe'))) {
        Write-ProbeLine "    there is also an OpenSSH in $manualFolder ($(Get-ProbeToolVersion (Join-Path $manualFolder 'ssh.exe')))"
    }

    # --- a4, a5: Git for Windows -------------------------------------------------
    # Git for Windows ships its own ssh.exe and often sshd.exe (in usr\bin).
    $Probe.GitRoot = Find-ProbeGitRoot
    if ($Probe.GitRoot) {
        $gitSsh = Join-Path $Probe.GitRoot 'usr' 'bin' 'ssh.exe'
        $gitSshd = Join-Path $Probe.GitRoot 'usr' 'bin' 'sshd.exe'
        Add-ProbeResult -Step 'a4' -State INFO -Text ("Git for Windows ssh.exe: {0} ({1})" -f $gitSsh, (Get-ProbeToolVersion $gitSsh))
        if (Test-Path -LiteralPath $gitSshd) {
            # Newer OpenSSH versions split the server into several programs. sshd.exe
            # cannot work when Git for Windows ships it without these helpers.
            $helpers = foreach ($name in @('sshd-session.exe', 'sshd-auth.exe', 'sftp-server.exe')) {
                $helperPath = Join-Path $Probe.GitRoot 'usr' 'lib' 'ssh' $name
                '{0}: {1}' -f $name, $(if (Test-Path -LiteralPath $helperPath) { 'present' } else { 'missing' })
            }
            Add-ProbeResult -Step 'a5' -State INFO -Text ("Git for Windows sshd.exe: {0} ({1}); helper programs in usr\lib\ssh: {2}" -f $gitSshd, (Get-ProbeToolVersion $gitSshd), ($helpers -join ', '))
        } else {
            Add-ProbeResult -Step 'a5' -State INFO -Text "Git for Windows has no sshd.exe ($gitSshd does not exist)"
        }
        if (-not $Probe.ClientKeygen) {
            $gitKeygen = Join-Path $Probe.GitRoot 'usr' 'bin' 'ssh-keygen.exe'
            if (Test-Path -LiteralPath $gitKeygen) { $Probe.ClientKeygen = $gitKeygen }
        }
        if (-not $Probe.ClientSsh) {
            # Without the Windows ssh.exe the rest of the probe uses the one of Git,
            # so that it can still report something. The summary says so.
            $Probe.ClientSsh = $gitSsh
            Write-ProbeLine '    NOTE: the remaining steps use the ssh.exe of Git for Windows, because Windows has none'
        }
    } else {
        Add-ProbeResult -Step 'a4' -State INFO -Text 'Git for Windows was not found'
        Add-ProbeResult -Step 'a5' -State INFO -Text 'Git for Windows was not found, so there is no sshd.exe from Git'
    }

    # --- a6: which ssh.exe does a plain "ssh" start? -----------------------------
    # PATH is the list of folders Windows searches for a program name. The
    # first hit wins. The GUI will not rely on it and use the full path.
    $onPath = @(Get-Command -Name 'ssh.exe' -All -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
    if ($onPath.Count -gt 0) {
        Add-ProbeResult -Step 'a6' -State INFO -Text ("a plain 'ssh' starts: {0} (all on PATH, in order: {1})" -f $onPath[0], ($onPath -join ' ; '))
    } else {
        Add-ProbeResult -Step 'a6' -State INFO -Text "no ssh.exe is on PATH"
    }

    # --- a7: does ssh.exe accept "-F none"? --------------------------------------
    # "-F none" tells ssh to read no configuration file at all. The GUI wants
    # this, so that an entry in the user's own ~/.ssh/config cannot change the
    # tunnel. "-G" makes ssh print the settings it would use and end, without
    # connecting anywhere: a safe way to see whether ssh.exe accepts "-F none".
    if ($Probe.ClientSsh) {
        $configRun = Invoke-ProbeTool -FilePath $Probe.ClientSsh -Arguments @('-F', 'none', '-G', '127.0.0.1') -TimeoutSeconds 20 -Quiet
        Write-ProbeLine ("    > {0} -F none -G 127.0.0.1   (exit code {1}, {2} lines of settings)" -f $Probe.ClientSsh, $configRun.ExitCode, @($configRun.StdOut -split "`r?`n" | Where-Object { $_ }).Count)
        if ($configRun.StdErr) { Write-ProbeBlock $configRun.StdErr }
        if ($configRun.ExitCode -eq 0) {
            $Probe.ConfigNoneAccepted = $true
            Add-ProbeResult -Step 'a7' -State PASS -Text "'-F none' is accepted by $($Probe.ClientSsh)"
        } else {
            $Probe.ConfigNoneAccepted = $false
            Add-ProbeResult -Step 'a7' -State FAIL -Text ("'-F none' is NOT accepted by {0}: {1}" -f $Probe.ClientSsh, ($configRun.Text -split "`r?`n" | Select-Object -First 1))
        }
    } else {
        Add-ProbeResult -Step 'a7' -State SKIP -Text "not tried: there is no ssh.exe"
    }
}

# ==============================================================================
#  Step c, first part: the key pair
# ==============================================================================

function New-ProbeKeyPair {
    Write-ProbeSection 'c (first part). A key pair in a folder whose name contains a space'

    if (-not $Probe.ClientKeygen) {
        Add-ProbeResult -Step 'c1' -State FAIL -Text 'no ssh-keygen.exe was found, so no key pair can be created'
        return
    }
    $keyFile = Join-Path $Probe.KeyDirectory 'id_ed25519_impact_probe'
    # -t ed25519: the key type; -N "": no passphrase; -C: a comment; -f: the file; -q: quiet.
    $run = Invoke-ProbeTool -FilePath $Probe.ClientKeygen -Arguments @('-q', '-t', 'ed25519', '-N', '', '-C', 'impact-probe', '-f', $keyFile)
    if ($run.ExitCode -eq 0 -and (Test-Path -LiteralPath $keyFile) -and (Test-Path -LiteralPath "$keyFile.pub")) {
        $Probe.KeyFile = $keyFile
        Add-ProbeResult -Step 'c1' -State PASS -Text "key pair created with $($Probe.ClientKeygen): $keyFile"
        # ssh.exe refuses a private key that other accounts may read. The key
        # lies below the user's own temporary folder, which only the user, the
        # system and the administrators may enter. Print the rights for the record.
        Write-ProbeLine '    access rights of the private key (inherited from the folder, not changed by the probe):'
        Show-ProbeFileAccess -Path $keyFile
    } else {
        Add-ProbeResult -Step 'c1' -State FAIL -Text 'ssh-keygen.exe did not create the key pair'
    }
}

# ==============================================================================
#  Step b: the SSH server (two ways)
# ==============================================================================

function Show-ProbeWindowsSshdEvents {
    <#
    .SYNOPSIS
        Prints the newest messages of the Windows OpenSSH Server. It writes
        them into the Windows event log "OpenSSH/Operational".
    #>
    param([int]$Count = 25)

    Write-ProbeLine "    newest messages of the Windows OpenSSH Server (event log OpenSSH/Operational):"
    try {
        $logEntries = @(Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents $Count -ErrorAction Stop | Sort-Object TimeCreated)
        foreach ($logEntry in $logEntries) {
            Write-ProbeLine ('      | {0:HH:mm:ss} {1}' -f $logEntry.TimeCreated, ("$($logEntry.Message)" -replace '\s+', ' '))
        }
    } catch {
        Write-ProbeLine "      | (cannot read the event log: $($_.Exception.Message))"
    }
}

function Add-ProbeKeyLine {
    <#
    .SYNOPSIS
        Appends one public key as a new line to an authorized_keys file
        (the file is created when it does not exist).
    .DESCRIPTION
        Each key must stand on a line of its own. When the file exists and its
        last line has no line end, a line end is written first, so that the new
        key is not glued to the key before it.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PublicKey
    )

    $existing = Get-ProbeFileText $Path
    $prefix = if ($existing -and -not $existing.EndsWith("`n")) { "`n" } else { '' }
    # ASCII without a byte order mark: sshd expects a plain text file.
    [System.IO.File]::AppendAllText($Path, $prefix + $PublicKey + "`n", [System.Text.Encoding]::ASCII)
}

function Install-ProbeKeyForWindowsOpenSsh {
    <#
    .SYNOPSIS
        Makes the Windows OpenSSH Server accept the probe's key for the current user.
    .DESCRIPTION
        Where the server looks for the allowed keys depends on the account:
          - a member of the Administrators group:
              C:\ProgramData\ssh\administrators_authorized_keys
            (the standard sshd_config ends with "Match Group administrators"
            and this file name). Only the system and the administrators may
            have access to it, or the server ignores the file.
          - any other account:
              <user folder>\.ssh\authorized_keys
        The probe writes the key to both places, so that the login works
        whichever rule the server applies. Both files are saved first and put
        back by the clean-up.
    #>
    $publicKey = (Get-ProbeFileText "$($Probe.KeyFile).pub").Trim()

    $configFile = Join-Path $env:ProgramData 'ssh' 'sshd_config'
    $hasAdminRule = (Get-ProbeFileText $configFile) -match '(?im)^\s*Match\s+Group\s+administrators'
    Write-ProbeLine "    sshd_config has the rule 'Match Group administrators': $hasAdminRule"

    # Place 1: the file for administrators.
    $adminFile = Join-Path $env:ProgramData 'ssh' 'administrators_authorized_keys'
    try {
        Backup-ProbeFile -Path $adminFile
        Add-ProbeKeyLine -Path $adminFile -PublicKey $publicKey
        # S-1-5-32-544 = the Administrators group, S-1-5-18 = the system account.
        $null = Set-ProbeFileAccess -Path $adminFile -AllowedSids @('S-1-5-32-544', 'S-1-5-18')
        Show-ProbeFileAccess -Path $adminFile
    } catch {
        Write-ProbeLine "    could not write ${adminFile}: $($_.Exception.Message)"
    }

    # Place 2: the user's own file.
    $userFolder = Join-Path $HOME '.ssh'
    $userFile = Join-Path $userFolder 'authorized_keys'
    try {
        if (-not (Test-Path -LiteralPath $userFolder)) {
            $null = New-Item -ItemType Directory -Path $userFolder -Force -ErrorAction Stop
        }
        Backup-ProbeFile -Path $userFile
        Add-ProbeKeyLine -Path $userFile -PublicKey $publicKey
        Show-ProbeFileAccess -Path $userFile
    } catch {
        Write-ProbeLine "    could not write ${userFile}: $($_.Exception.Message)"
    }
}

function Start-ProbeWindowsOpenSsh {
    <#
    .SYNOPSIS
        First way: the Windows OpenSSH Server as the Windows service "sshd".
    .OUTPUTS
        A description of the running server (a hashtable), or $null when this
        way does not work.
    #>
    Write-ProbeSection 'b (first way). Windows OpenSSH Server as the Windows service "sshd"'

    # --- b1: is the server installed? If not, install it. ----------------------
    $service = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
    if ($service) {
        Add-ProbeResult -Step 'b1' -State INFO -Text "the service 'sshd' is registered already ($($service.Status), start type $($service.StartType)); nothing to install"
    } else {
        Write-ProbeLine "    the service 'sshd' is not registered: adding the Windows capability OpenSSH.Server (this can take minutes)"
        # Add-WindowsCapability downloads the server from Windows Update and
        # installs it. The answer contains "RestartNeeded"; the probe wants to
        # know whether the server works WITHOUT a restart of Windows.
        $command = "`$ProgressPreference = 'SilentlyContinue'; " +
                   "`$found = Get-WindowsCapability -Online -Name 'OpenSSH.Server*'; " +
                   "`$answer = `$found | Add-WindowsCapability -Online -ErrorAction Stop; " +
                   "'RestartNeeded = ' + `$answer.RestartNeeded"
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $run = Invoke-ProbeTool -FilePath $Probe.WindowsPowerShell -TimeoutSeconds 900 -Arguments @('-NoProfile', '-NonInteractive', '-Command', $command)
        $seconds = [math]::Round($watch.Elapsed.TotalSeconds)
        $service = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
        if ($run.ExitCode -eq 0 -and $service) {
            $Probe.CapabilityAddedByProbe = $true
            $restart = if ($run.StdOut -match 'RestartNeeded\s*=\s*(\S+)') { $Matches[1] } else { 'unknown' }
            Add-ProbeResult -Step 'b1' -State PASS -Text "Add-WindowsCapability installed the OpenSSH Server in $seconds seconds; RestartNeeded = $restart"
        } else {
            # The FAIL line carries the complete error text of powershell.exe, so
            # that the reason can be read in the summary table without a search
            # in the log. (An error of Windows PowerShell itself, such as a
            # module that could not be loaded, would show up here as well.)
            Add-ProbeResult -Step 'b1' -State FAIL -Text "Add-WindowsCapability did not install the OpenSSH Server ($seconds seconds, exit code $($run.ExitCode), time limit reached: $($run.TimedOut)); error text of powershell.exe: $(ConvertTo-ProbeOneLine $run.StdErr); other output: $(ConvertTo-ProbeOneLine $run.StdOut)"
            # The installation log of Windows often names the reason.
            $dismLog = Join-Path $env:SystemRoot 'Logs' 'DISM' 'dism.log'
            if (Test-Path -LiteralPath $dismLog) {
                $tail = Get-Content -LiteralPath $dismLog -Tail 60 -ErrorAction SilentlyContinue
                $tail | Set-Content -LiteralPath (Join-Path $Probe.OutputDirectory 'dism-log-tail.txt') -Encoding utf8
                Write-ProbeLine "    the last 60 lines of $dismLog were saved as dism-log-tail.txt"
            }
            return $null
        }
    }

    # --- b2: start the service ----------------------------------------------------
    $Probe.SshdStatusBefore = "$($service.Status)"
    $Probe.SshdStartTypeBefore = "$($service.StartType)"
    try {
        if ($Probe.SshdStartTypeBefore -eq 'Disabled') {
            # A disabled service cannot be started. "Manual" allows a start
            # without making the service start with Windows.
            Set-Service -Name 'sshd' -StartupType Manual -ErrorAction Stop
            $Probe.SshdStartTypeChanged = $true
        }
        if ($Probe.SshdStatusBefore -ne 'Running') {
            Start-Service -Name 'sshd' -ErrorAction Stop
            $Probe.SshdStartedByProbe = $true
        }
    } catch {
        Add-ProbeResult -Step 'b2' -State FAIL -Text "Start-Service sshd failed: $($_.Exception.Message)"
        Show-ProbeWindowsSshdEvents
        return $null
    }

    # The first start creates C:\ProgramData\ssh with the configuration and the
    # host keys (the keys that identify the server). Read the port from it.
    $port = 22
    $configFile = Join-Path $env:ProgramData 'ssh' 'sshd_config'
    $configText = Get-ProbeFileText $configFile
    if ($configText -match '(?im)^\s*Port\s+(\d+)') { $port = [int]$Matches[1] }
    Write-ProbeLine "    active lines of ${configFile}:"
    Write-ProbeBlock (($configText -split "`r?`n") | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') })

    if (-not (Wait-TcpPort -Port $port -Seconds 20)) {
        Add-ProbeResult -Step 'b2' -State FAIL -Text "the service 'sshd' was started but nothing listens on port $port"
        Show-ProbeWindowsSshdEvents
        return $null
    }
    Add-ProbeResult -Step 'b2' -State PASS -Text "the Windows OpenSSH Server runs as the service 'sshd' and listens on port $port, without a restart of Windows"

    Install-ProbeKeyForWindowsOpenSsh
    # Both server ways return a table with the same five entries.
    return @{
        Method  = 'WindowsOpenSsh'
        Title   = "Windows OpenSSH Server (service 'sshd')"
        Port    = $port
        User    = $Probe.User.Name
        LogFile = ''       # this server writes into the Windows event log, not into a file
    }
}

function Start-ProbeGitSshd {
    <#
    .SYNOPSIS
        Second way: sshd.exe from Git for Windows as a normal process on port
        2222, with a temporary configuration, host key and authorized_keys file.
    .OUTPUTS
        A description of the running server (a hashtable), or $null when this
        way does not work.
    #>
    Write-ProbeSection "b (second way). sshd.exe from Git for Windows on port $GitSshdPort"

    $sshd = if ($Probe.GitRoot) { Join-Path $Probe.GitRoot 'usr' 'bin' 'sshd.exe' } else { '' }
    $keygen = if ($Probe.GitRoot) { Join-Path $Probe.GitRoot 'usr' 'bin' 'ssh-keygen.exe' } else { '' }
    if (-not $sshd -or -not (Test-Path -LiteralPath $sshd) -or -not (Test-Path -LiteralPath $keygen)) {
        Add-ProbeResult -Step 'b3' -State FAIL -Text 'Git for Windows has no sshd.exe (or no ssh-keygen.exe), so the second way cannot be tried'
        return $null
    }

    $folder = Join-Path $Probe.WorkDirectory 'git-sshd'
    $null = New-Item -ItemType Directory -Path $folder -Force
    $hostKey = Join-Path $folder 'ssh_host_ed25519_key'
    $authorizedKeys = Join-Path $folder 'authorized_keys'
    $configFile = Join-Path $folder 'sshd_config'
    $pidFile = Join-Path $folder 'sshd.pid'
    $logFile = Join-Path $Probe.OutputDirectory 'git-sshd.log'

    # The host key identifies the server. It is created with the ssh-keygen of
    # Git for Windows, because the sshd of Git will read it.
    $run = Invoke-ProbeTool -FilePath $keygen -Arguments @('-q', '-t', 'ed25519', '-N', '', '-f', $hostKey)
    if ($run.ExitCode -ne 0) {
        Add-ProbeResult -Step 'b3' -State FAIL -Text 'the host key for the sshd of Git for Windows could not be created'
        return $null
    }
    Copy-Item -LiteralPath "$($Probe.KeyFile).pub" -Destination $authorizedKeys -Force

    # The temporary configuration. The paths are written in the form of Git for
    # Windows (/c/Users/...), see ConvertTo-MsysPath.
    #   ListenAddress 127.0.0.1   reachable from this computer only
    #   StrictModes no            do not check owner and rights of the user's
    #                             folder and of authorized_keys. The programs of
    #                             Git for Windows cannot read Windows access
    #                             rights properly, so this check could fail
    #                             although the files are safe.
    #   PasswordAuthentication no key login only
    #   LogLevel DEBUG            a detailed log, to explain a failed login
    $configLines = @(
        '# Temporary sshd configuration written by tests/Probes/Probe-WindowsTunnel.ps1'
        "Port $GitSshdPort"
        'ListenAddress 127.0.0.1'
        'HostKey ' + (Format-ProbeConfigValue (ConvertTo-MsysPath $hostKey))
        'PidFile ' + (Format-ProbeConfigValue (ConvertTo-MsysPath $pidFile))
        'AuthorizedKeysFile ' + (Format-ProbeConfigValue (ConvertTo-MsysPath $authorizedKeys))
        'PubkeyAuthentication yes'
        'PasswordAuthentication no'
        'KbdInteractiveAuthentication no'
        'StrictModes no'
        'AllowTcpForwarding yes'
        'LogLevel DEBUG'
    )
    # Unix line ends ("`n") and no byte order mark: sshd expects a plain text file.
    [System.IO.File]::WriteAllText($configFile, ($configLines -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
    Write-ProbeLine "    temporary configuration ${configFile}:"
    Write-ProbeBlock $configLines

    # -D: stay in the foreground as one process (so that the probe can end it)
    # -f: the configuration file     -E: write the log into this file
    # sshd must be started with its full path, otherwise it refuses to run.
    $argumentString = '-D -f "{0}" -E "{1}"' -f (ConvertTo-MsysPath $configFile), (ConvertTo-MsysPath $logFile)
    Write-ProbeLine "    > Start-Process -FilePath `"$sshd`" -WindowStyle Hidden -PassThru -ArgumentList '$argumentString'"
    try {
        $process = Start-Process -FilePath $sshd -ArgumentList $argumentString -WindowStyle Hidden -PassThru -ErrorAction Stop
        $null = $process.Handle      # see Start-ProbeTunnelProcess for the reason
    } catch {
        Add-ProbeResult -Step 'b3' -State FAIL -Text "sshd.exe of Git for Windows could not be started: $($_.Exception.Message)"
        return $null
    }
    $Probe.GitSshdProcess = $process

    if (Wait-TcpPort -Port $GitSshdPort -Seconds 20 -Process $process) {
        Add-ProbeResult -Step 'b3' -State PASS -Text "sshd.exe of Git for Windows runs (process $($process.Id)) and listens on 127.0.0.1:$GitSshdPort"
        return @{
            Method  = 'GitSshd'
            Title   = 'sshd.exe of Git for Windows'
            Port    = $GitSshdPort
            User    = $Probe.User.Name
            LogFile = $logFile
        }
    }
    $state = if ($process.HasExited) { "it ended with exit code $($process.ExitCode)" } else { 'it runs but does not listen' }
    Add-ProbeResult -Step 'b3' -State FAIL -Text "sshd.exe of Git for Windows does not listen on port ${GitSshdPort}: $state"
    Write-ProbeLine "    log of the server (${logFile}):"
    Show-ProbeFile $logFile
    return $null
}

function Stop-ProbeServer {
    <# .SYNOPSIS Stops an SSH server that the probe started (used when its login test failed, and by the clean-up). #>
    param([Parameter(Mandatory)][hashtable]$Server)

    if ($Server.Method -eq 'GitSshd') {
        if ($Probe.GitSshdProcess -and -not $Probe.GitSshdProcess.HasExited) {
            try { $Probe.GitSshdProcess.Kill($true) } catch { $null = $_ }
            [void]$Probe.GitSshdProcess.WaitForExit(5000)
        }
    } elseif ($Probe.SshdStartedByProbe) {
        try {
            Stop-Service -Name 'sshd' -Force -ErrorAction Stop
            $Probe.SshdStartedByProbe = $false
            Write-ProbeLine "    the service 'sshd' was stopped again"
        } catch {
            Write-ProbeLine "    could not stop the service 'sshd': $($_.Exception.Message)"
        }
    }
}

# ==============================================================================
#  Step c, second part: the key login
# ==============================================================================

function Test-ProbeKeyLogin {
    <#
    .SYNOPSIS
        Logs in to the server with the probe's key and runs "whoami" there.
        Returns $true when the login worked.
    .DESCRIPTION
        The options:
          -n                      give ssh an empty input
          BatchMode=yes           never ask a question (password, yes/no)
          IdentitiesOnly=yes      offer only the key given with -i
          StrictHostKeyChecking=accept-new   trust the server key on first contact
          UserKnownHostsFile=...  remember that key in the probe's own file.
                                  The tunnel in step e does NOT get this option:
                                  it is started exactly as the GUI will start it.
          ConnectTimeout=10       give up after 10 seconds without a connection
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Server,
        [Parameter(Mandatory)][string]$Step
    )

    Write-ProbeSection "c (second part). Key login to: $($Server.Title)"
    # The value of an -o option is read like a line of an ssh configuration
    # file, where a backslash can have a special meaning. Forward slashes are
    # safe, and ssh.exe on Windows accepts them in paths.
    $knownHosts = (Join-Path $Probe.WorkDirectory ('known_hosts_{0}' -f $Server.Method)) -replace '\\', '/'
    $arguments = @()
    if ($Probe.ConfigNoneAccepted) { $arguments += @('-F', 'none') }
    $arguments += @(
        '-n'
        '-o', 'BatchMode=yes'
        '-o', 'IdentitiesOnly=yes'
        '-o', 'StrictHostKeyChecking=accept-new'
        '-o', "UserKnownHostsFile=$knownHosts"
        '-o', 'ConnectTimeout=10'
        '-i', $Probe.KeyFile
        '-p', "$($Server.Port)"
        "$($Server.User)@127.0.0.1"
        'whoami'
    )
    $run = Invoke-ProbeTool -FilePath $Probe.ClientSsh -Arguments $arguments -TimeoutSeconds 60

    if ($run.ExitCode -ne 0 -and $run.Text -match 'UNPROTECTED PRIVATE KEY|bad permissions|too open') {
        # ssh.exe refused the key file because other accounts may read it.
        # Limit the file to the current user and try once more.
        Write-ProbeLine '    ssh.exe refused the key file because of its access rights: limiting it to the current user and trying again'
        $null = Set-ProbeFileAccess -Path $Probe.KeyFile -AllowedSids @($Probe.User.Sid)
        $Probe.KeyAccessRepaired = $true
        $run = Invoke-ProbeTool -FilePath $Probe.ClientSsh -Arguments $arguments -TimeoutSeconds 60
    }

    $answer = ($run.StdOut -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
    if ($run.ExitCode -eq 0 -and $answer -and $answer -match [regex]::Escape($Server.User)) {
        $repairNote = if ($Probe.KeyAccessRepaired) { ' (after the access rights of the key file were limited to the user)' } else { '' }
        Add-ProbeResult -Step $Step -State PASS -Text "key login to $($Server.Title) on port $($Server.Port) works; whoami answered '$($answer.Trim())'$repairNote"
        return $true
    }
    Add-ProbeResult -Step $Step -State FAIL -Text "key login to $($Server.Title) on port $($Server.Port) failed (exit code $($run.ExitCode)): $(($run.StdErr -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1))"

    # Why? The server side knows more than the client.
    if ($Server.Method -eq 'GitSshd') {
        Write-ProbeLine "    log of the server ($($Server.LogFile)):"
        Show-ProbeFile $Server.LogFile
    } else {
        Show-ProbeWindowsSshdEvents
    }
    return $false
}

function Start-ProbeServerWithLogin {
    <#
    .SYNOPSIS
        Steps b and c together: tries the server ways in order and keeps the
        first one to which the key login works. The result is left in
        $Probe.Server ($null when no way works).
    #>
    if (-not $Probe.ClientSsh) {
        Add-ProbeResult -Step 'b5' -State SKIP -Text 'not tried: there is no ssh.exe to connect with'
        return
    }
    New-ProbeKeyPair
    if (-not $Probe.KeyFile) {
        Add-ProbeResult -Step 'b5' -State SKIP -Text 'not tried: there is no key pair'
        return
    }

    $ways = if ($ServerMethod -eq 'Auto') { @('WindowsOpenSsh', 'GitSshd') } else { @($ServerMethod) }
    foreach ($way in $ways) {
        if ($way -eq 'WindowsOpenSsh') {
            $server = Start-ProbeWindowsOpenSsh
            $loginStep = 'c2'
        } else {
            $server = Start-ProbeGitSshd
            $loginStep = 'c3'
        }
        if (-not $server) { continue }
        if (Test-ProbeKeyLogin -Server $server -Step $loginStep) {
            $Probe.Server = $server
            break
        }
        # The server runs but the login failed: stop it and try the next way.
        Stop-ProbeServer -Server $server
    }

    if ($Probe.Server) {
        Add-ProbeResult -Step 'b5' -State PASS -Text "SSH server for the tunnel steps: $($Probe.Server.Title), port $($Probe.Server.Port), user '$($Probe.Server.User)'"
    } else {
        Add-ProbeResult -Step 'b5' -State FAIL -Text "no SSH server with a working key login could be started (ways tried: $($ways -join ', '))"
    }
}

# ==============================================================================
#  Step d: a small web server on 127.0.0.1:8787
# ==============================================================================

function Start-ProbeWebServer {
    Write-ProbeSection "d. A small web server on 127.0.0.1:$TargetPort (stands in for RStudio)"

    if (Test-TcpPort -Port $TargetPort) {
        Write-ProbeLine "    WARNING: something already listens on 127.0.0.1:$TargetPort"
    }

    # The web server runs as a PowerShell background job, which is a second
    # PowerShell process. It answers every request with the text
    # "impact-probe-ok". It uses a plain TcpListener: that needs no
    # administrator rights and no extra Windows component.
    $Probe.WebJob = Start-Job -Name 'impact-probe-web' -ArgumentList $TargetPort -ScriptBlock {
        param([int]$Port)
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        $body = [System.Text.Encoding]::ASCII.GetBytes('impact-probe-ok')
        $head = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/plain`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
        while ($true) {
            # Pending() is true when a client waits to be accepted. Asking first
            # and sleeping a moment keeps the job stoppable: AcceptTcpClient()
            # alone would wait for a client without end, and Stop-Job would
            # then hang for minutes at the end of the probe.
            if (-not $listener.Pending()) {
                Start-Sleep -Milliseconds 50
                continue
            }
            $client = $listener.AcceptTcpClient()
            try {
                # A client that connects but sends nothing must not block the
                # server for longer than 3 seconds.
                $client.ReceiveTimeout = 3000
                $stream = $client.GetStream()
                $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::ASCII)
                # An HTTP request is a few lines of text followed by an empty line.
                $sawRequest = $false
                while ($true) {
                    $line = $reader.ReadLine()
                    if ($null -eq $line) { break }
                    if ($line -eq '') { $sawRequest = $true; break }
                }
                if ($sawRequest) {
                    $stream.Write($head, 0, $head.Length)
                    $stream.Write($body, 0, $body.Length)
                    $stream.Flush()
                }
            } catch {
                # A broken connection must not end the server.
                $null = $_
            } finally {
                $client.Close()
            }
        }
    }

    if (-not (Wait-TcpPort -Port $TargetPort -Seconds 30)) {
        Add-ProbeResult -Step 'd1' -State FAIL -Text "the web server job did not open 127.0.0.1:$TargetPort"
        Write-ProbeBlock (Receive-Job -Job $Probe.WebJob -Keep -ErrorAction SilentlyContinue 2>&1)
        return
    }
    $answer = Invoke-ProbeHttpRequest -Url "http://127.0.0.1:$TargetPort/" -TotalSeconds 15
    if ($answer.StatusCode -eq 200 -and $answer.Body -eq 'impact-probe-ok') {
        $Probe.WebServerOk = $true
        Add-ProbeResult -Step 'd1' -State PASS -Text "the web server answers directly on http://127.0.0.1:$TargetPort/ with HTTP 200"
    } else {
        Add-ProbeResult -Step 'd1' -State FAIL -Text "the web server on 127.0.0.1:$TargetPort answered with status $($answer.StatusCode), error '$($answer.Error)'"
    }
}

# ==============================================================================
#  Steps e to i: the tunnel
# ==============================================================================

function Get-ProbeTunnelArgumentString {
    <#
    .SYNOPSIS
        Builds the ONE argument string for ssh.exe, exactly as the GUI will build it.
    .DESCRIPTION
          -N    run no command on the server, only forward the port
          -T    ask for no terminal
          -F none                    read no ssh configuration file
          ExitOnForwardFailure=yes   end at once when the port on the PC cannot be opened
          GatewayPorts=no            other computers cannot use the port on the PC
          BatchMode=yes              never ask a question (a hidden process cannot)
          IdentitiesOnly=yes         offer only the key given with -i
          StrictHostKeyChecking=accept-new   trust the server key on first contact
          ConnectTimeout=10          give up after 10 seconds without a connection
          ServerAliveInterval=15, ServerAliveCountMax=3
                                     notice a dead connection after about 45 seconds
          -i "<key>"                 the private key (in quotes: the path has a space)
          -E "<log file>"            write messages into this file
          -L 127.0.0.1:18787:127.0.0.1:8787
                                     port 18787 on this PC leads to port 8787 on the server
    #>
    param([Parameter(Mandatory)][string]$LogFile)

    $parts = @('-N', '-T')
    if ($Probe.ConfigNoneAccepted) { $parts += '-F none' }
    $parts += '-o ExitOnForwardFailure=yes -o GatewayPorts=no -o BatchMode=yes -o IdentitiesOnly=yes'
    $parts += '-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3'
    $parts += '-i "{0}"' -f $Probe.KeyFile
    $parts += '-E "{0}"' -f $LogFile
    # -p is needed only when the server does not use the standard port 22.
    if ($Probe.Server.Port -ne 22) { $parts += '-p {0}' -f $Probe.Server.Port }
    $parts += '-L 127.0.0.1:{0}:127.0.0.1:{1}' -f $TunnelPort, $TargetPort
    $parts += '{0}@127.0.0.1' -f $Probe.Server.User
    return ($parts -join ' ')
}

function Start-ProbeTunnelProcess {
    <#
    .SYNOPSIS
        Starts ssh.exe as a hidden process, exactly as the GUI will start it,
        and returns the process object.
    #>
    param([Parameter(Mandatory)][string]$LogFile)

    $argumentString = Get-ProbeTunnelArgumentString -LogFile $LogFile
    Write-ProbeLine "    > Start-Process -FilePath `"$($Probe.ClientSsh)`" -WindowStyle Hidden -PassThru -ArgumentList '$argumentString'"
    $process = Start-Process -FilePath $Probe.ClientSsh -ArgumentList $argumentString -WindowStyle Hidden -PassThru -ErrorAction Stop
    # Reading the property Handle once makes PowerShell keep the connection to
    # the process. Without this, ExitCode can be empty after the process has
    # ended. The GUI needs the same line when it wants the exit code of ssh.exe.
    $null = $process.Handle
    $Probe.StartedProcesses.Add($process)
    return $process
}

function Get-ProbePortListeners {
    <#
    .SYNOPSIS
        Returns one text line per program that listens on the port
        ("127.0.0.1:18787 process 1234 (ssh)").
    #>
    param([Parameter(Mandatory)][int]$Port)

    $connections = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    foreach ($connection in $connections) {
        $owner = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
        $name = if ($owner) { $owner.ProcessName } else { 'unknown' }
        '{0}:{1} process {2} ({3})' -f $connection.LocalAddress, $connection.LocalPort, $connection.OwningProcess, $name
    }
}

function Invoke-ProbeTunnelSteps {
    $skipSteps = @('e1', 'e2', 'f1', 'g1', 'g2', 'h1', 'h2', 'i1')
    if (-not $Probe.Server) {
        foreach ($step in $skipSteps) { Add-ProbeResult -Step $step -State SKIP -Text 'not tried: there is no SSH server with a working key login' }
        return
    }
    if (-not $Probe.WebServerOk) {
        Write-ProbeLine '    NOTE: the web server of step d does not answer; the tunnel is started anyway, but the request through it will fail'
    }

    # ---------------------------------------------------------------- step e ---
    Write-ProbeSection 'e. Start the tunnel exactly as the GUI will start it'

    # The tunnel uses the user's real known_hosts file (the GUI will, too).
    # Save it first, so that the clean-up can put it back.
    $knownHosts = Join-Path $HOME '.ssh' 'known_hosts'
    try { Backup-ProbeFile -Path $knownHosts } catch { Write-ProbeLine "    could not save ${knownHosts}: $($_.Exception.Message)" }
    $knownHostsBefore = Get-ProbeFileText $knownHosts

    if (Test-TcpPort -Port $TunnelPort) {
        Write-ProbeLine "    WARNING: something already listens on 127.0.0.1:$TunnelPort before the tunnel starts"
    }
    $log1 = Join-Path $Probe.LogDirectory 'tunnel-1.log'
    $tunnel = $null
    try {
        $tunnel = Start-ProbeTunnelProcess -LogFile $log1
    } catch {
        Add-ProbeResult -Step 'e1' -State FAIL -Text "Start-Process could not start ssh.exe: $($_.Exception.Message)"
    }
    if (-not $tunnel) {
        foreach ($step in $skipSteps | Where-Object { $_ -ne 'e1' }) { Add-ProbeResult -Step $step -State SKIP -Text 'not tried: the tunnel process could not be started' }
        return
    }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $listening = Wait-TcpPort -Port $TunnelPort -Seconds 30 -Process $tunnel
    $noneNote = if ($Probe.ConfigNoneAccepted) { "with '-F none'" } else { "WITHOUT '-F none' (this ssh.exe does not accept it)" }
    if ($listening -and -not $tunnel.HasExited) {
        Add-ProbeResult -Step 'e1' -State PASS -Text ("the hidden ssh.exe (process {0}) opened 127.0.0.1:{1} after {2:N1} seconds; started {3}, log file in a folder with a space" -f $tunnel.Id, $TunnelPort, $watch.Elapsed.TotalSeconds, $noneNote)
    } else {
        $state = if ($tunnel.HasExited) { "ssh.exe ended with exit code $($tunnel.ExitCode)" } else { 'ssh.exe runs but the port is closed' }
        Add-ProbeResult -Step 'e1' -State FAIL -Text "the tunnel did not open 127.0.0.1:${TunnelPort}: $state (started $noneNote)"
    }
    Write-ProbeLine "    log of the tunnel (${log1}):"
    Show-ProbeFile $log1

    # Can the log of a RUNNING ssh.exe be read? The GUI wants to show the last
    # lines of this file when a tunnel does not work. Two ways are tried: the
    # plain way (Get-Content) and reading with shared access.
    if (-not $tunnel.HasExited) {
        $plainNote = 'works'
        try { $null = Get-Content -LiteralPath $log1 -Raw -ErrorAction Stop } catch { $plainNote = "fails ($($_.Exception.Message))" }
        $shared = Get-ProbeFileTextShared -Path $log1
        $sharedNote = if ($shared.Ok) { 'works' } else { "fails ($($shared.Error))" }
        Add-ProbeResult -Step 'e3' -State INFO -Text "the log file of the RUNNING ssh.exe: plain reading $plainNote; reading with shared access $sharedNote"
    }

    # Did "accept-new" store the server key in the user's known_hosts file?
    $knownHostsAfter = Get-ProbeFileText $knownHosts
    if ($knownHostsAfter -ne $knownHostsBefore) {
        Add-ProbeResult -Step 'e2' -State INFO -Text "StrictHostKeyChecking=accept-new added the server key to $knownHosts without asking (the probe puts the file back at the end)"
    } else {
        Add-ProbeResult -Step 'e2' -State INFO -Text "$knownHosts was not changed by the tunnel start"
    }

    if (-not $listening -or $tunnel.HasExited) {
        foreach ($step in @('f1', 'g1', 'g2', 'h1', 'h2', 'i1')) { Add-ProbeResult -Step $step -State SKIP -Text 'not tried: the tunnel is not running' }
        return
    }

    # ---------------------------------------------------------------- step f ---
    Write-ProbeSection "f. Request http://127.0.0.1:$TunnelPort/ through the tunnel"
    $answer = Invoke-ProbeHttpRequest -Url "http://127.0.0.1:$TunnelPort/" -TotalSeconds 30
    Write-ProbeLine ("    status code: {0}; body: '{1}'; tries: {2}; seconds: {3}; last error: '{4}'" -f $answer.StatusCode, $answer.Body, $answer.Attempts, $answer.Seconds, $answer.Error)
    if ($answer.StatusCode -eq 200 -and $answer.Body -eq 'impact-probe-ok') {
        Add-ProbeResult -Step 'f1' -State PASS -Text "HTTP 200 through the tunnel (try $($answer.Attempts), after $($answer.Seconds) seconds); the answer came from the web server of step d"
    } else {
        Add-ProbeResult -Step 'f1' -State FAIL -Text "no correct answer through the tunnel: status $($answer.StatusCode), error '$($answer.Error)'"
        Show-ProbeFile $log1
    }

    # ---------------------------------------------------------------- step g ---
    Write-ProbeSection "g. Who listens on port $TunnelPort, and what Windows knows about the tunnel process"
    $listeners = @(Get-ProbePortListeners -Port $TunnelPort)
    Write-ProbeLine "    Get-NetTCPConnection -State Listen -LocalPort ${TunnelPort}:"
    Write-ProbeBlock $listeners
    $expected = '127.0.0.1:{0} process {1} ' -f $TunnelPort, $tunnel.Id
    if ($listeners.Count -eq 1 -and $listeners[0].StartsWith($expected)) {
        Add-ProbeResult -Step 'g1' -State PASS -Text "exactly one listener on port ${TunnelPort}: $($listeners[0]); it is the tunnel process, and it listens on 127.0.0.1 only"
    } else {
        Add-ProbeResult -Step 'g1' -State FAIL -Text "expected one listener '$expected...', found: $(if ($listeners.Count) { $listeners -join ' ; ' } else { 'none' })"
    }

    # Win32_Process is the Windows list of running processes with details.
    $details = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($tunnel.Id)" -ErrorAction SilentlyContinue
    if ($details) {
        Write-ProbeLine "    Win32_Process for process $($tunnel.Id):"
        Write-ProbeLine "      | Name            $($details.Name)"
        Write-ProbeLine "      | ParentProcessId $($details.ParentProcessId) (this PowerShell is process $PID)"
        Write-ProbeLine ("      | CreationDate    {0:yyyy-MM-dd HH:mm:ss.fff}" -f $details.CreationDate)
        Write-ProbeLine ("      | StartTime       {0:yyyy-MM-dd HH:mm:ss.fff} (from the process object of Start-Process)" -f $tunnel.StartTime)
        Write-ProbeLine "      | ExecutablePath  $($details.ExecutablePath)"
        Write-ProbeLine "      | CommandLine     $($details.CommandLine)"
        $forward = '-L 127.0.0.1:{0}:127.0.0.1:{1}' -f $TunnelPort, $TargetPort
        if ("$($details.CommandLine)".Contains($forward) -and "$($details.ExecutablePath)" -eq $Probe.ClientSsh) {
            Add-ProbeResult -Step 'g2' -State PASS -Text ("Win32_Process shows start time ({0:HH:mm:ss}), path and the complete command line of the tunnel process; the command line contains '{1}'" -f $details.CreationDate, $forward)
        } else {
            Add-ProbeResult -Step 'g2' -State FAIL -Text "Win32_Process was read, but the path or the command line is not as expected (path '$($details.ExecutablePath)')"
        }
    } else {
        Add-ProbeResult -Step 'g2' -State FAIL -Text "Get-CimInstance Win32_Process returned nothing for process $($tunnel.Id)"
    }

    # ---------------------------------------------------------------- step h ---
    Write-ProbeSection "h. A second tunnel on the same port $TunnelPort"
    $log2 = Join-Path $Probe.LogDirectory 'tunnel-2.log'
    $second = $null
    try {
        $second = Start-ProbeTunnelProcess -LogFile $log2
    } catch {
        Add-ProbeResult -Step 'h1' -State FAIL -Text "Start-Process could not start the second ssh.exe: $($_.Exception.Message)"
    }
    if ($second) {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $ended = $second.WaitForExit(20000)
        $logText = Get-ProbeFileText $log2
        Write-ProbeLine "    log of the second ssh.exe (${log2}):"
        Show-ProbeFile $log2
        # The lines that explain the end, for the summary. They are also the
        # proof that the taken port was the reason: ssh.exe writes a line with
        # "bind", "in use", "cannot listen" or "forwarding" when it cannot open
        # the port on this PC. An ssh.exe that ended without such a line may
        # have ended for another reason (for example a failed login), and that
        # would say nothing about the question of this step.
        $reason = ($logText -split "`r?`n" | Where-Object { $_ -match 'bind|in use|cannot listen|forward' } | ForEach-Object { $_.Trim() }) -join ' / '
        if ($ended -and $reason) {
            Add-ProbeResult -Step 'h1' -State PASS -Text ("the second ssh.exe ended by itself after {0:N1} seconds with exit code {1}; log text: '{2}'" -f $watch.Elapsed.TotalSeconds, $second.ExitCode, $reason)
        } elseif ($ended) {
            Add-ProbeResult -Step 'h1' -State FAIL -Text ("could not be tested whether a second tunnel on the taken port ends by itself: the second ssh.exe ended after {0:N1} seconds with exit code {1}, but its log has no line about the port (bind, in use, cannot listen, forwarding); complete log: '{2}'" -f $watch.Elapsed.TotalSeconds, $second.ExitCode, (ConvertTo-ProbeOneLine $logText))
        } else {
            $listenersThen = @(Get-ProbePortListeners -Port $TunnelPort) -join ' ; '
            try { $second.Kill($true) } catch { $null = $_ }
            [void]$second.WaitForExit(5000)
            # The log of a running ssh.exe can be locked. The process has ended
            # now, so the file is read again: it tells what the second ssh.exe
            # did with the taken port. An empty log means that it reported no
            # problem with the port.
            $logAfter = Get-ProbeFileText $log2
            Write-ProbeLine '    log of the second ssh.exe, read after the probe ended the process:'
            Show-ProbeFile $log2
            Add-ProbeResult -Step 'h1' -State FAIL -Text ("the second ssh.exe did NOT end within 20 seconds, although port $TunnelPort was taken; listeners at that moment: $listenersThen; its log, read after the probe ended it: '" + (ConvertTo-ProbeOneLine $logAfter) + "'")
        }
        # The first tunnel must not be disturbed by the second start.
        $again = Invoke-ProbeHttpRequest -Url "http://127.0.0.1:$TunnelPort/" -TotalSeconds 10
        if (-not $tunnel.HasExited -and $again.StatusCode -eq 200) {
            Add-ProbeResult -Step 'h2' -State PASS -Text 'the first tunnel still works after the second start (HTTP 200)'
        } else {
            Add-ProbeResult -Step 'h2' -State FAIL -Text "the first tunnel does not work any more after the second start (status $($again.StatusCode), process ended: $($tunnel.HasExited))"
        }
    } else {
        Add-ProbeResult -Step 'h2' -State SKIP -Text 'not tried: the second ssh.exe could not be started'
    }

    # ---------------------------------------------------------------- step i ---
    Write-ProbeSection 'i. End the first tunnel and check that the port is free'
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Stop-Process -Id $tunnel.Id -Force -ErrorAction Stop
    } catch {
        Write-ProbeLine "    Stop-Process reported: $($_.Exception.Message)"
    }
    $ended = $tunnel.WaitForExit(10000)
    # Wait (at most 10 seconds) until Windows lists no listener and the port can be opened again.
    $free = $false
    while ($watch.Elapsed.TotalSeconds -lt 10) {
        if (@(Get-ProbePortListeners -Port $TunnelPort).Count -eq 0 -and (Test-ProbePortFree -Port $TunnelPort)) {
            $free = $true
            break
        }
        Start-Sleep -Milliseconds 200
    }
    $after = Invoke-ProbeHttpRequest -Url "http://127.0.0.1:$TunnelPort/" -TotalSeconds 1
    Write-ProbeLine "    a request after the end of the tunnel: status $($after.StatusCode), error '$($after.Error)'"
    if ($ended -and $free) {
        Add-ProbeResult -Step 'i1' -State PASS -Text ("Stop-Process ended the tunnel (exit code {0}); port {1} was free again after {2:N1} seconds" -f $tunnel.ExitCode, $TunnelPort, $watch.Elapsed.TotalSeconds)
    } else {
        Add-ProbeResult -Step 'i1' -State FAIL -Text "after Stop-Process: process ended = $ended, port free = $free; listeners: $(@(Get-ProbePortListeners -Port $TunnelPort) -join ' ; ')"
    }
}

# ==============================================================================
#  Clean-up and summary
# ==============================================================================

function Invoke-ProbeCleanup {
    Write-ProbeSection 'Clean-up'

    # 1. Processes the probe started and that may still run (tunnels).
    foreach ($process in $Probe.StartedProcesses) {
        try {
            if (-not $process.HasExited) {
                $process.Kill($true)
                [void]$process.WaitForExit(5000)
                Write-ProbeLine "    ended leftover process $($process.Id)"
            }
        } catch { $null = $_ }
    }

    # 2. The web server job.
    if ($Probe.WebJob) {
        try {
            Stop-Job -Job $Probe.WebJob -ErrorAction SilentlyContinue
            Remove-Job -Job $Probe.WebJob -Force -ErrorAction SilentlyContinue
            Write-ProbeLine '    web server job stopped'
        } catch { $null = $_ }
    }

    # 3. The SSH server.
    if ($Probe.GitSshdProcess) {
        Stop-ProbeServer -Server @{ Method = 'GitSshd' }
        Write-ProbeLine '    sshd.exe of Git for Windows stopped'
    }
    if ($Probe.SshdStatusBefore -or $Probe.CapabilityAddedByProbe) {
        # The probe worked with the Windows OpenSSH Server (SshdStatusBefore is
        # filled in when its start was tried): save its messages for the artifact.
        try {
            Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 200 -ErrorAction Stop |
                Sort-Object TimeCreated |
                ForEach-Object { '{0:yyyy-MM-dd HH:mm:ss} {1}' -f $_.TimeCreated, ("$($_.Message)" -replace '\s+', ' ') } |
                Set-Content -LiteralPath (Join-Path $Probe.OutputDirectory 'windows-sshd-events.txt') -Encoding utf8
        } catch { $null = $_ }
    }
    if ($Probe.SshdStartedByProbe) {
        Stop-ProbeServer -Server @{ Method = 'WindowsOpenSsh' }
    }
    if ($Probe.SshdStartTypeChanged) {
        try {
            Set-Service -Name 'sshd' -StartupType $Probe.SshdStartTypeBefore -ErrorAction Stop
            Write-ProbeLine "    start type of the service 'sshd' set back to $($Probe.SshdStartTypeBefore)"
        } catch { Write-ProbeLine "    could not set back the start type of 'sshd': $($_.Exception.Message)" }
    }
    if ($Probe.CapabilityAddedByProbe) {
        Write-ProbeLine '    NOTE: the Windows capability OpenSSH.Server stays installed (removing it takes minutes; the runner is thrown away)'
    }

    # 4. Files the probe changed: put the saved copies back, newest change first.
    for ($index = $Probe.Backups.Count - 1; $index -ge 0; $index--) {
        $entry = $Probe.Backups[$index]
        try {
            if ($entry.Existed) {
                Copy-Item -LiteralPath $entry.Copy -Destination $entry.Path -Force -ErrorAction Stop
                Write-ProbeLine "    put back: $($entry.Path)"
            } elseif (Test-Path -LiteralPath $entry.Path) {
                Remove-Item -LiteralPath $entry.Path -Force -ErrorAction Stop
                Write-ProbeLine "    removed: $($entry.Path)"
            }
        } catch {
            Write-ProbeLine "    could not put back $($entry.Path): $($_.Exception.Message)"
        }
    }
    if (-not $Probe.SshFolderExisted) {
        # The folder .ssh did not exist before the probe (the probe or ssh.exe
        # created it). Remove it, but only when it is empty again.
        $sshFolder = Join-Path $HOME '.ssh'
        if ((Test-Path -LiteralPath $sshFolder) -and @(Get-ChildItem -LiteralPath $sshFolder -Force).Count -eq 0) {
            Remove-Item -LiteralPath $sshFolder -Force -ErrorAction SilentlyContinue
            Write-ProbeLine "    removed the empty folder $sshFolder"
        }
    }

    # 5. The temporary folder with the keys.
    if ($Probe.WorkDirectory -and (Test-Path -LiteralPath $Probe.WorkDirectory)) {
        Remove-Item -LiteralPath $Probe.WorkDirectory -Recurse -Force -ErrorAction SilentlyContinue
        Write-ProbeLine "    removed the temporary folder $($Probe.WorkDirectory)"
    }

    # 6. Are the ports free again?
    $busy = @(@($TunnelPort, $TargetPort, $GitSshdPort) | Where-Object { Test-TcpPort -Port $_ })
    if ($busy.Count -eq 0) {
        Add-ProbeResult -Step 'z1' -State PASS -Text "clean-up done; the ports $TunnelPort, $TargetPort and $GitSshdPort are closed"
    } else {
        Add-ProbeResult -Step 'z1' -State FAIL -Text "after the clean-up these ports still accept connections: $($busy -join ', ')"
    }
}

function Write-ProbeSummary {
    $counts = @{ PASS = 0; FAIL = 0; SKIP = 0; INFO = 0 }
    foreach ($result in $Probe.Results) { $counts[$result.Result]++ }
    $countLine = '{0} PASS, {1} FAIL, {2} SKIP, {3} INFO' -f $counts.PASS, $counts.FAIL, $counts.SKIP, $counts.INFO

    Write-ProbeLine ''
    Write-ProbeLine '==================== SUMMARY ===================='
    Write-ProbeLine ('{0,-6}  {1,-4}  {2}' -f 'RESULT', 'STEP', 'WHAT')
    foreach ($result in $Probe.Results) {
        Write-ProbeLine ('{0,-6}  {1,-4}  {2}' -f $result.Result, $result.Step, $result.What)
    }
    Write-ProbeLine '-------------------------------------------------'
    Write-ProbeLine $countLine
    Write-ProbeLine 'A FAIL line does not fail the job: this probe only reports.'

    # GitHub shows the text written to the file named in GITHUB_STEP_SUMMARY on
    # the page of the workflow run. Write the same table there, so the result
    # can be read without opening the log.
    if ($env:GITHUB_STEP_SUMMARY) {
        try {
            $lines = @('### Probe: SSH tunnel on a Windows runner', '', $countLine, '', '| Result | Step | What |', '|---|---|---|')
            foreach ($result in $Probe.Results) {
                # A "|" inside the text would break the table, so it is written as "\|".
                $lines += '| {0} | {1} | {2} |' -f $result.Result, $result.Step, ($result.What -replace '\|', '\|')
            }
            Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $lines -Encoding utf8 -ErrorAction Stop
        } catch { $null = $_ }
    }
}

function Invoke-ProbeStep {
    <#
    .SYNOPSIS
        Runs one step. An unexpected error inside the step becomes a FAIL line
        and the probe goes on with the next step.
    #>
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    try {
        # "$null =" throws away anything the step returns, so that it does not
        # show up as a stray line in the output.
        $null = & $Action
    } catch {
        Add-ProbeResult -Step $Step -State FAIL -Text "unexpected error in the probe script: $($_.Exception.Message)"
        Write-ProbeBlock $_.ScriptStackTrace
    }
}

# ==============================================================================
#  MAIN PART: the steps run from here
# ==============================================================================

# $Probe holds everything the steps share: the results, the paths that were
# found, and what the probe changed (the clean-up reads that). The functions
# above read and change the entries of this one table.
$Probe = @{
    Results                = [System.Collections.Generic.List[object]]::new()
    Backups                = [System.Collections.Generic.List[object]]::new()
    StartedProcesses       = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
    OutputDirectory        = ''
    OutputFile             = ''
    LogDirectory           = ''       # <OutputDirectory>\tunnel logs  (a space on purpose)
    WorkDirectory          = ''       # temporary folder, removed at the end
    KeyDirectory           = ''       # <WorkDirectory>\client key folder  (spaces on purpose)
    User                   = $null
    Icacls                 = ''
    WindowsPowerShell      = ''
    ClientSsh              = ''       # full path of the ssh.exe used for the login and the tunnel
    ClientKeygen           = ''
    GitRoot                = $null
    ConfigNoneAccepted     = $false   # does ssh.exe accept "-F none"?
    KeyFile                = ''
    KeyAccessRepaired      = $false
    Server                 = $null    # the SSH server the tunnel connects to
    GitSshdProcess         = $null
    CapabilityAddedByProbe = $false
    SshdStatusBefore       = ''
    SshdStartTypeBefore    = ''
    SshdStartTypeChanged   = $false
    SshdStartedByProbe     = $false
    SshFolderExisted       = $true    # did <user folder>\.ssh exist before the probe?
    WebJob                 = $null
    WebServerOk            = $false
}

# --- Can the probe run here at all? -------------------------------------------
if (-not $IsWindows) {
    Write-Host 'ERROR: this probe needs Windows (it tests the Windows ssh.exe).'
    exit 2
}
# GitHub sets the variable GITHUB_ACTIONS to "true" inside every workflow job.
if ($env:GITHUB_ACTIONS -ne 'true' -and -not $Force) {
    Write-Host 'ERROR: this probe changes the computer (SSH server, login key).'
    Write-Host '       It is meant for a throw-away GitHub runner. Add -Force to run it here.'
    exit 2
}

try {
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force -ErrorAction Stop
    $Probe.OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
    $Probe.OutputFile = Join-Path $Probe.OutputDirectory 'probe-output.txt'
    Set-Content -LiteralPath $Probe.OutputFile -Value $null -Encoding utf8 -ErrorAction Stop
    # The tunnel log files go into a folder with a space in its name: on a real
    # PC the path of the log file can contain one (C:\Users\Max Mustermann\...).
    $Probe.LogDirectory = Join-Path $Probe.OutputDirectory 'tunnel logs'
    $null = New-Item -ItemType Directory -Path $Probe.LogDirectory -Force -ErrorAction Stop
    # The temporary folder lies below the user's own temp folder, which only
    # the user, the system and the administrators may enter. $PID (the number
    # of this PowerShell process) makes its name unique.
    # The variable TEMP can hold the old short form of the path
    # (C:\Users\RUNNER~1\...). The same folder reached through LOCALAPPDATA
    # has its full name, which is easier to read in the logs.
    $tempRoot = [System.IO.Path]::GetTempPath()
    if ($env:LOCALAPPDATA -and (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Temp'))) {
        $tempRoot = Join-Path $env:LOCALAPPDATA 'Temp'
    }
    $Probe.WorkDirectory = Join-Path $tempRoot "impact-probe-$PID"
    $Probe.KeyDirectory = Join-Path $Probe.WorkDirectory 'client key folder'
    $null = New-Item -ItemType Directory -Path $Probe.KeyDirectory -Force -ErrorAction Stop
} catch {
    Write-Host "ERROR: cannot create the output or the temporary folder: $($_.Exception.Message)"
    exit 2
}

$Probe.Icacls = Join-Path $env:SystemRoot 'System32' 'icacls.exe'
$Probe.WindowsPowerShell = Join-Path $env:SystemRoot 'System32' 'WindowsPowerShell' 'v1.0' 'powershell.exe'
$Probe.User = Get-ProbeUserInfo
$Probe.SshFolderExisted = Test-Path -LiteralPath (Join-Path $HOME '.ssh')

Write-ProbeLine 'IMPACT Docker GUI: Windows tunnel feasibility probe (temporary)'
Write-ProbeLine ("started: {0:yyyy-MM-dd HH:mm:ss} UTC   output folder: {1}" -f (Get-Date).ToUniversalTime(), $Probe.OutputDirectory)
Write-ProbeLine "server way: $ServerMethod"

# "finally" runs also when something unexpected ends the steps early, so the
# clean-up and the summary always happen.
try {
    Invoke-ProbeStep -Step 'a'  -Action { Invoke-ProbeInventory }
    Invoke-ProbeStep -Step 'bc' -Action { Start-ProbeServerWithLogin }
    Invoke-ProbeStep -Step 'd'  -Action { Start-ProbeWebServer }
    Invoke-ProbeStep -Step 'e-i' -Action { Invoke-ProbeTunnelSteps }
} finally {
    Invoke-ProbeStep -Step 'z' -Action { Invoke-ProbeCleanup }
    Write-ProbeSummary
}

# Always end with an explicit exit code. Without it, GitHub would use the exit
# code of the last program the probe started, for example a failed ssh.exe.
exit 0
