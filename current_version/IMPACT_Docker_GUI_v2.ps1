<# IMPACT Docker GUI v2 #>
<# This is the launcher script. Core functions live in IMPACT_Docker_GUI.psm1 #>

[CmdletBinding()]
param(
    [switch]$ElevatedRestart,
    [switch]$PS7Requested
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Determine the directory where this script lives.
if ($PSScriptRoot -and (Test-Path $PSScriptRoot)) {
    $script:ScriptDir = $PSScriptRoot
} else {
    # Fallback: use the process executable's directory
    $script:ScriptDir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}

# Import the companion module (same directory as this script)
$modulePath = Join-Path $script:ScriptDir 'IMPACT_Docker_GUI.psm1'
if (Test-Path $modulePath) {
    Import-Module $modulePath -Force -DisableNameChecking
} else {
    Write-Host "ERROR: Module not found at $modulePath" -ForegroundColor Red
    Write-Host "The file 'IMPACT_Docker_GUI.psm1' must be in the same folder as this script." -ForegroundColor Red
    Write-Host ""
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue; [System.Windows.Forms.MessageBox]::Show("IMPACT cannot start because 'IMPACT_Docker_GUI.psm1' is missing from the application folder.`nPlease place the module next to the script and retry.", 'IMPACT - Module missing', 'OK', 'Error') | Out-Null } catch {}
    Write-Host "Press any key to exit..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 1
} 

# 4a. Remote prep: ensure SSH user, authorized_keys, repo list, docker context
function Ensure-RemotePreparation {
    param([pscustomobject]$State)
    Write-Log 'Remote flow: authorize key, pick repo, configure Docker context' 'Info'

    if (-not $State.RemoteHost -or -not $State.RemoteHostIp) {
        Write-Log 'Remote host not set; cannot continue remote preparation.' 'Error'
        return $false
    }
    if (-not (Test-Path $State.Paths.SshPrivate)) {
        Write-Log "SSH private key missing at $($State.Paths.SshPrivate)" 'Error'
        return $false
    }
    if (-not (Test-Path $State.Paths.SshPublic)) {
        Write-Log "SSH public key missing at $($State.Paths.SshPublic)" 'Error'
        return $false
    }

    $remoteUser = $State.RemoteUser
    $remoteHost = $State.RemoteHost
    $remoteIp   = $State.RemoteHostIp
    $remoteRepoBase = if ($State.RemoteRepoBase) { $State.RemoteRepoBase } else { "/home/$remoteUser/Schreibtisch/Repositories" }
    $State.RemoteRepoBase = $remoteRepoBase

    $sshArgs = @(
        '-n',
        '-i', $State.Paths.SshPrivate,
        '-o', 'IdentitiesOnly=yes',
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'ConnectTimeout=10',
        $remoteHost
    )

    $sshKeyPath = $State.Paths.SshPrivate

    # Validate/repair SSH config entry BEFORE any SSH operations.
    # If a previous session wrote a config entry pointing to a key that was later deleted,
    # SSH (and Docker over SSH) will fail because IdentitiesOnly=yes prevents fallback.
    Ensure-SshConfigEntry -RemoteHostIp $remoteIp -RemoteUser $remoteUser -IdentityFile $sshKeyPath

    # Quick probe to see if key auth already works to avoid prompting for password unnecessarily
    $keyAuthorized = $false
    $probeOut = $null   # set before the try, so StrictMode is happy even if ssh cannot start at all
    try {
        $probeOut = & ssh @sshArgs "echo KEY_AUTH_OK" 2>&1
        if ($LASTEXITCODE -eq 0 -and $probeOut -match 'KEY_AUTH_OK') { $keyAuthorized = $true }
        Write-Log "Key auth probe output: $probeOut (exit=$LASTEXITCODE)" 'Debug'
    } catch { $keyAuthorized = $false; $probeOut = $_.Exception.Message }

    # If the key login failed, find out WHY before asking for a password.
    # A password only helps when the workstation answered and refused the key
    # (or when the reason is unclear). If the workstation cannot be reached at
    # all (VPN off, wrong IP, machine off), or it presents a different host key
    # than last time, a password cannot help: we stop with a clear message
    # instead of a misleading password prompt. Not sending the password to a
    # host whose identity changed also protects the shared workstation password.
    if (-not $keyAuthorized) {
        $probeFailure = Get-SshFailureKind -Output $probeOut
        Write-Log "Key auth probe failed; reason category: $probeFailure" 'Debug'
        if ($probeFailure -eq 'Unreachable') {
            $msg = "IMPACT cannot reach the workstation at $remoteIp.`n`nPlease check that:`n  - you are connected to the institute network (or the VPN when working from home)`n  - the workstation is switched on`n  - the IP address $remoteIp is correct`n`nThen try again."
            Write-Log "Workstation $remoteIp is not reachable over SSH: $probeOut" 'Error'
            [System.Windows.Forms.MessageBox]::Show($msg, 'Workstation not reachable', 'OK', 'Error') | Out-Null
            return $false
        }
        if ($probeFailure -eq 'HostKeyChanged') {
            $msg = "The workstation at $remoteIp identified itself with a different SSH host key than the one this PC remembers.`n`nThis is expected after the workstation was reinstalled, but it can also mean that the connection is being intercepted. For your safety IMPACT will not send your password.`n`nAsk the workstation admin whether the workstation was reinstalled. If it was, run this command in PowerShell and then start IMPACT again:`n  ssh-keygen -R $remoteIp"
            Write-Log "Host key of $remoteIp has changed; stopping before any password is sent: $probeOut" 'Error'
            [System.Windows.Forms.MessageBox]::Show($msg, 'Workstation identity changed', 'OK', 'Warning') | Out-Null
            return $false
        }
    }

    # 4.1.1: Ensure authorized_keys contains our public key and permissions are set
    Write-Log 'Authorizing SSH key on remote host...' 'Info'
        $publicKeyContent = (Get-Content $State.Paths.SshPublic -Raw).Trim()

        # Build the remote bootstrap script using format placeholders to avoid PowerShell $(...) expansion
        $remoteScript = @'
set -eu
umask 077
ACTUAL_USER="$(whoami)"
HOME_DIR="$(eval echo ~{0})"
USER_SSH_DIR="$HOME_DIR/.ssh"
AUTH_KEYS="$USER_SSH_DIR/authorized_keys"
KEY_TARGET_PUB="$USER_SSH_DIR/id_ed25519_{1}.pub"

# go-w (not 755): sshd only needs the home folder to be not writable by others.
# 755 would make a private home folder readable by every account on the machine.
mkdir -p "$HOME_DIR" && chmod go-w "$HOME_DIR"
mkdir -p "$USER_SSH_DIR" && chmod 700 "$USER_SSH_DIR"
touch "$AUTH_KEYS" && chmod 600 "$AUTH_KEYS"

echo "{2}" > "$KEY_TARGET_PUB"
chown {0}:{0} "$KEY_TARGET_PUB"
chmod 644 "$KEY_TARGET_PUB"

# Clean up stale pub files left by previous bug (extra underscore before .pub)
STALE_PUB="$USER_SSH_DIR/id_ed25519_{1}_.pub"
[ -f "$STALE_PUB" ] && rm -f "$STALE_PUB"

# Remove any previous keys for this IMPACT user (comment marker: IMPACT_{1}).
# The match is anchored to the END of the line (the key comment is the last
# word), so IMPACT_jan does not also delete IMPACT_jane or IMPACT_jan-m of
# other colleagues. The optional _ also removes markers from an old bug.
sed -i -E '/[[:space:]]IMPACT_{1}_?[[:space:]]*$/d' "$AUTH_KEYS" 2>/dev/null || true

if ! grep -qxF "{2}" "$AUTH_KEYS"; then
    echo "{2}" >> "$AUTH_KEYS"
fi
chown {0}:{0} "$AUTH_KEYS"
echo 'SSH_KEY_COPIED'
'@ -f $remoteUser, $State.UserName, $publicKeyContent

    # (A second "install the key using the key" attempt used to run here. It was
    # removed: it logged in with the same key that had just been refused, so it
    # could never succeed, and it added up to 10 more seconds of waiting.
    # $remoteScript above is still used by the plink fallback further down.)

    if (-not $keyAuthorized) {
        Write-Log 'Key-based auth failed; prompting for password bootstrap (one-time).' 'Warn'

        $pwForm = New-Object System.Windows.Forms.Form -Property @{ Text='Enter remote password'; Size=New-Object System.Drawing.Size(380,190); FormBorderStyle='FixedDialog'; MaximizeBox=$false }
        Set-FormCenterOnCurrentScreen -Form $pwForm
        Apply-ThemeToForm -Form $pwForm
        $lbl = New-Object System.Windows.Forms.Label -Property @{ Text="Password for $($remoteUser)@$($remoteIp):"; Location=New-Object System.Drawing.Point(18,22); Size=New-Object System.Drawing.Size(330,24) }
        Style-Label -Label $lbl
        $pwForm.Controls.Add($lbl)
        $txt = New-Object System.Windows.Forms.TextBox -Property @{ Location=New-Object System.Drawing.Point(18,52); Size=New-Object System.Drawing.Size(330,26); UseSystemPasswordChar=$true }
        Style-TextBox -TextBox $txt
        $pwForm.Controls.Add($txt)
        $btnOk = New-Object System.Windows.Forms.Button -Property @{ Text='OK'; Location=New-Object System.Drawing.Point(178,100); Size=New-Object System.Drawing.Size(80,32) }
        $btnCancel = New-Object System.Windows.Forms.Button -Property @{ Text='Cancel'; Location=New-Object System.Drawing.Point(268,100); Size=New-Object System.Drawing.Size(80,32); DialogResult=[System.Windows.Forms.DialogResult]::Cancel }
        Style-Button -Button $btnOk -Variant 'primary'
        Style-Button -Button $btnCancel -Variant 'secondary'
        $btnOk.Add_Click({ if (-not $txt.Text) { return } $pwForm.DialogResult=[System.Windows.Forms.DialogResult]::OK; $pwForm.Close() })
        $pwForm.AcceptButton=$btnOk; $pwForm.CancelButton=$btnCancel; $pwForm.Controls.Add($btnOk); $pwForm.Controls.Add($btnCancel)
        $pwForm.Add_Shown({ $txt.Focus() })
        $pwResult = $pwForm.ShowDialog()
        if ($pwResult -ne [System.Windows.Forms.DialogResult]::OK) {
            Write-Log 'Password bootstrap cancelled.' 'Error'
            return $false
        }
        $plainPw = $txt.Text

        # Try Posh-SSH first (mirrors the legacy flow: create temp file remotely, then run install script)
        $poshSshUsed = $false
        $poshSshErrorText = $null   # why Posh-SSH failed, so we can show the real reason to the user
        $sshSession = $null
        $remoteTemp = "/tmp/ssh_key_temp_$($State.UserName)_$(Get-Date -Format 'HHmmss').pub"
        try {
            $poshSsh = Get-Module -ListAvailable -Name 'Posh-SSH' | Select-Object -First 1
            if (-not $poshSsh) {
                Write-Log 'Posh-SSH not found; prompting user to install (CurrentUser scope).' 'Info'
                try {
                    $installChoice = [System.Windows.Forms.MessageBox]::Show(
                        'The Posh-SSH module is required to copy your key using password auth. Install it now (CurrentUser scope)?',
                        'Install Posh-SSH?',
                        [System.Windows.Forms.MessageBoxButtons]::YesNo,
                        [System.Windows.Forms.MessageBoxIcon]::Question
                    )
                    if ($installChoice -eq [System.Windows.Forms.DialogResult]::Yes) {
                        try {
                            Install-Module -Name Posh-SSH -Scope CurrentUser -Force -AllowClobber -Confirm:$false -ErrorAction Stop | Out-Null
                            Write-Log 'Posh-SSH installed successfully (CurrentUser).' 'Info'
                        } catch {
                            Write-Log "Posh-SSH install failed: $($_.Exception.Message)" 'Error'
                        }
                    } else {
                        Write-Log 'User declined Posh-SSH installation.' 'Warn'
                    }
                } catch {
                    Write-Log "Posh-SSH install prompt failed: $($_.Exception.Message)" 'Warn'
                }
                $poshSsh = Get-Module -ListAvailable -Name 'Posh-SSH' | Select-Object -First 1
            }

            if ($poshSsh) {
                Import-Module Posh-SSH -ErrorAction Stop
                $poshSshUsed = $true

                $tempKeyFile = New-TemporaryFile
                Set-Content -Path $tempKeyFile -Value $publicKeyContent -NoNewline -Encoding ASCII
                $size = (Get-Item $tempKeyFile).Length
                Write-Log "Temp key file created ($size bytes) at $tempKeyFile" 'Debug'

                $secPw = ConvertTo-SecureString $plainPw -AsPlainText -Force
                $cred = New-Object System.Management.Automation.PSCredential ($remoteUser, $secPw)
                # Note: if the workstation's host key had changed, the OpenSSH probe at the top
                # of this function has already stopped, so the password is not sent in that case.
                $sshSession = New-SSHSession -ComputerName $remoteIp -Credential $cred -AcceptKey -ConnectionTimeout 15 -ErrorAction Stop

                $keyEscaped = (Get-Content $tempKeyFile -Raw) -replace "'", "'\''"
                $createFileCmd = "echo '$keyEscaped' > $remoteTemp && chmod 600 $remoteTemp && echo FILE_CREATED"
                $createResult = Invoke-SSHCommand -SessionId $sshSession.SessionId -Command $createFileCmd -TimeOut 30 -ErrorAction Stop
                Write-Log "Posh-SSH create temp exit=$($createResult.ExitStatus); output=$($createResult.Output)" 'Debug'
                if ($createResult.Output -notmatch 'FILE_CREATED') { throw "Remote temp file creation failed: $($createResult.Output)" }

                                $remoteInstallScript = @'
set -eu
umask 077
ACTUAL_USER="$(whoami)"
HOME_DIR="$(eval echo ~${ACTUAL_USER})"
USER_SSH_DIR="$HOME_DIR/.ssh"
AUTH_KEYS="$USER_SSH_DIR/authorized_keys"
KEY_TARGET_PUB="$USER_SSH_DIR/id_ed25519_%%USERNAME%%.pub"
REMOTE_TEMP="%%REMOTE_TEMP%%"

# go-w (not 755): sshd only needs the home folder to be not writable by others.
mkdir -p "$HOME_DIR" && chmod go-w "$HOME_DIR"
mkdir -p "$USER_SSH_DIR" && chmod 700 "$USER_SSH_DIR"
touch "$AUTH_KEYS" && chmod 600 "$AUTH_KEYS"

if [ ! -f "$REMOTE_TEMP" ]; then
    echo "Temp file missing: $REMOTE_TEMP"
    exit 1
fi

cp "$REMOTE_TEMP" "$KEY_TARGET_PUB"
chown ${ACTUAL_USER}:${ACTUAL_USER} "$KEY_TARGET_PUB"
chmod 644 "$KEY_TARGET_PUB"

NEW_KEY=$(cat "$KEY_TARGET_PUB")

# Remove any previous keys for this IMPACT user (comment marker: IMPACT_%%USERNAME%%).
# Anchored to the end of the line so other colleagues whose names merely start
# the same way (IMPACT_jan vs IMPACT_jane) keep their keys.
sed -i -E '/[[:space:]]IMPACT_%%USERNAME%%_?[[:space:]]*$/d' "$AUTH_KEYS" 2>/dev/null || true

if ! grep -qxF "$NEW_KEY" "$AUTH_KEYS"; then
    echo "$NEW_KEY" >> "$AUTH_KEYS"
    echo KEY_ADDED
else
    echo KEY_ALREADY_EXISTS
fi

chmod go-w "$HOME_DIR"
chmod 700 "$USER_SSH_DIR"
chmod 600 "$AUTH_KEYS"
chmod 644 "$KEY_TARGET_PUB"
# (No chown of the home folder: it already belongs to this user, and a chown
# could fail and abort the script if the group name differs from the user name.)
chown -R ${ACTUAL_USER}:${ACTUAL_USER} "$USER_SSH_DIR"

# Clean up stale pub files left by previous bug (extra underscore before .pub)
STALE_PUB="$USER_SSH_DIR/id_ed25519_%%USERNAME%%_.pub"
[ -f "$STALE_PUB" ] && rm -f "$STALE_PUB"

rm -f "$REMOTE_TEMP"
echo SSH_KEY_COPIED
'@
                                $remoteInstallScript = $remoteInstallScript.Replace('%%USERNAME%%', $State.UserName).Replace('%%REMOTE_TEMP%%', $remoteTemp)
                                $remoteInstallScript = $remoteInstallScript -replace "`r`n","`n" -replace "`r","`n"
                $cmdResult = Invoke-SSHCommand -SessionId $sshSession.SessionId -Command $remoteInstallScript -TimeOut 60 -ErrorAction Stop
                Write-Log "Posh-SSH install exit=$($cmdResult.ExitStatus); output length=$($cmdResult.Output.Length)" 'Debug'
                if ($cmdResult.Output -match 'SSH_KEY_COPIED') { $keyAuthorized = $true }
                else { $poshSshErrorText = "The key setup script on the workstation did not finish (exit status $($cmdResult.ExitStatus)): $($cmdResult.Output -join ' ')" }
            }
        } catch {
            # Keep the exception type and message (also of an inner exception): they tell us
            # whether the password was wrong or the workstation could not be reached.
            $ex = $_.Exception
            $poshSshErrorText = "$($ex.GetType().FullName): $($ex.Message)"
            if ($ex.InnerException) { $poshSshErrorText += " | $($ex.InnerException.GetType().FullName): $($ex.InnerException.Message)" }
            Write-Log "Posh-SSH bootstrap failed: $poshSshErrorText" 'Warn'
        } finally {
            if ($sshSession) { try { Remove-SSHSession -SessionId $sshSession.SessionId -ErrorAction SilentlyContinue | Out-Null } catch { } }
            if (Get-Variable tempKeyFile -Scope 0 -ErrorAction SilentlyContinue) { try { Remove-Item $tempKeyFile -Force -ErrorAction SilentlyContinue; Write-Log 'Removed temporary key file.' 'Debug' } catch { } }
        }

        # Posh-SSH was available and really tried, but did not succeed: tell the user the
        # real reason. (Before, this fell through to "install PuTTY", even when the only
        # problem was a mistyped password.) We do NOT then also try plink with the same
        # password: a wrong password would be sent twice, which can get this PC blocked
        # by the workstation's brute-force protection.
        if (-not $keyAuthorized -and $poshSshUsed) {
            $poshFailure = Get-SshFailureKind -Output $poshSshErrorText
            if ($poshFailure -eq 'AuthFailed' -and $poshSshErrorText -match 'Permission denied') {
                Write-Log "Password for $remoteUser@$remoteIp was not accepted." 'Warn'
                [System.Windows.Forms.MessageBox]::Show("The password for $remoteUser@$remoteIp was not accepted.`n`nPlease check it (is Caps Lock on?) and try again.", 'Wrong password', 'OK', 'Warning') | Out-Null
                # Run the remote preparation again, so the password dialog appears again.
                # This repeats only while the user keeps entering a password: pressing
                # Cancel in the password dialog ends it.
                return (Ensure-RemotePreparation -State $State)
            }
            $detail = if ($poshFailure -eq 'Unreachable') {
                "The connection to the workstation failed or timed out. Please check that you are connected to the institute network (or the VPN) and that the workstation is switched on."
            } else {
                "Details: $poshSshErrorText"
            }
            $msg = "IMPACT could not copy your SSH key to the workstation ($remoteIp).`n`n$detail"
            Write-Log $msg 'Error'
            [System.Windows.Forms.MessageBox]::Show($msg, 'SSH key setup failed', 'OK', 'Error') | Out-Null
            return $false
        }

        # Only reached when Posh-SSH is not available: fall back to PuTTY's plink.exe.
        if (-not $keyAuthorized) {
            $plink = Get-Command plink.exe -ErrorAction SilentlyContinue
            if (-not $plink) {
                $puttyPath = "${env:ProgramFiles}\PuTTY\plink.exe"
                if (Test-Path $puttyPath) { $plink = Get-Command $puttyPath -ErrorAction SilentlyContinue }
            }

            if ($plink) {
                # How plink is called, and why:
                # - The password goes into a temporary file (-pwfile) instead of onto the
                #   command line, where security logging and other programs could read it.
                #   -pwfile needs PuTTY 0.77 or newer; an older plink stops with an
                #   "unknown option" error, which is shown to the user below.
                # - plink keeps its own list of trusted host keys, separate from OpenSSH,
                #   and with -batch it refuses any host it has not seen before. So we pass
                #   the host key that OpenSSH stored during the probe above (-hostkey).
                # - The script gets Unix line endings: a Windows checkout of this file can
                #   have CRLF, and bash cannot run lines that end in a carriage return.
                # - plink is called directly (not via Start-Process) so that PowerShell
                #   quotes every argument correctly, even when it contains spaces.
                $pwFile = $null
                $plinkOut = $null
                $plinkExit = -1
                try {
                    $pwFile = New-TemporaryFile
                    [System.IO.File]::WriteAllText($pwFile.FullName, $plainPw)
                    $plinkArgs = @('-batch', '-ssh', '-pwfile', $pwFile.FullName)
                    $hostKeyLines = @()
                    try { $hostKeyLines = @(& ssh-keygen -l -F $remoteIp 2>$null) } catch { $hostKeyLines = @() }
                    foreach ($fp in @($hostKeyLines | ForEach-Object { [regex]::Matches("$_", 'SHA256:[A-Za-z0-9+/=]+') } | ForEach-Object { $_.Value })) {
                        $plinkArgs += @('-hostkey', $fp)
                    }
                    $plinkArgs += @($remoteHost, 'bash -s')
                    $scriptLf = $remoteScript -replace "`r`n", "`n" -replace "`r", "`n"
                    $plinkOut = $scriptLf | & $plink.Source @plinkArgs 2>&1
                    $plinkExit = $LASTEXITCODE
                } catch {
                    $plinkOut = $_.Exception.Message
                } finally {
                    if ($pwFile) { Remove-Item $pwFile.FullName -Force -ErrorAction SilentlyContinue }
                }
                Write-Log "plink bootstrap exit=$plinkExit output=$plinkOut" 'Debug'
                # Success needs both: exit code 0 AND the marker printed by the last line of
                # the script (the exit code alone does not prove the script ran to the end).
                if ($plinkExit -eq 0 -and ($plinkOut -match 'SSH_KEY_COPIED')) {
                    $keyAuthorized = $true
                } else {
                    $plinkDetail = (@($plinkOut) | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Last 3) -join ' '
                    $msg = "IMPACT could not copy your SSH key to the workstation ($remoteIp) using PuTTY (plink).`n`nDetails: $plinkDetail`n`nThe easiest fix is the Posh-SSH PowerShell module: start IMPACT again and click 'Yes' when it offers to install Posh-SSH."
                    Write-Log $msg 'Error'
                    [System.Windows.Forms.MessageBox]::Show($msg, 'SSH key setup failed', 'OK', 'Error') | Out-Null
                    return $false
                }
            } else {
                $msg = "IMPACT needs the Posh-SSH PowerShell module to copy your SSH key to the workstation with your password, but the module is not available on this PC."
                if ($poshSshErrorText) { $msg += "`n`nDetails: $poshSshErrorText" }
                $msg += "`n`nStart IMPACT again and click 'Yes' when it offers to install Posh-SSH. If the installation fails (for example because the PowerShell Gallery is blocked on this PC), ask your IT support to install the Posh-SSH module, or install PuTTY 0.77 or newer."
                [System.Windows.Forms.MessageBox]::Show($msg,'Password bootstrap unavailable','OK','Error') | Out-Null
                Write-Log $msg 'Error'
                return $false
            }
        }

        if (-not $keyAuthorized) {
            Write-Log 'Password-based bootstrap did not succeed.' 'Error'
            return $false
        }

        # Whatever the setup step reported, the real test is whether the workstation now
        # accepts our key. Check once more, so that a half-finished setup (for example
        # wrong folder permissions on the workstation) is reported here clearly, instead
        # of causing confusing errors in every later step.
        $verifyOk = $false
        $verifyOut = $null
        try {
            $verifyOut = & ssh @sshArgs "echo KEY_AUTH_OK" 2>&1
            $verifyOk = ($LASTEXITCODE -eq 0 -and ($verifyOut -match 'KEY_AUTH_OK'))
        } catch { $verifyOut = $_.Exception.Message }
        if (-not $verifyOk) {
            $msg = "Your SSH key was copied to the workstation ($remoteIp), but logging in with it still does not work.`n`nPlease contact the workstation admin. Details: $verifyOut"
            Write-Log $msg 'Error'
            [System.Windows.Forms.MessageBox]::Show($msg, 'SSH key setup failed', 'OK', 'Error') | Out-Null
            return $false
        }
    }

    Write-Log "SSH key authorized on remote host for user $($State.UserName)." 'Info'

    # SSH config was already validated/created at the top of this function.

    # Copy the SSH private key onto the remote host for Git inside the container,
    # and make sure the remote known_hosts file exists (see below).
    Write-Log 'Copying SSH private key to remote host.' 'Info'

    if (Test-Path $sshKeyPath) {
        # The key is sent through ssh's standard input, NOT as part of the command line.
        # Command lines are visible to other programs and are often recorded by security
        # logging (for example Defender for Endpoint), which would keep a copy of the key.
        # $sshArgs starts with '-n' (= "do not read input"), so this call uses a copy of
        # the arguments without it; otherwise the key would never reach the workstation.
        $sshArgsWithInput = @($sshArgs | Where-Object { $_ -ne '-n' })
        # TrimEnd: PowerShell adds one line break itself when piping text to a program.
        $pkContent = (Get-Content $sshKeyPath -Raw).TrimEnd()
        $remoteKeyFile = "~/.ssh/id_ed25519_$($State.UserName)"
        # umask 077 keeps the file private from the moment it exists; tr removes Windows
        # line endings; writing to .tmp and renaming means a broken transfer can never
        # leave a half-written key in place of a working one.
        $copyPrivateCmd = "umask 077 && mkdir -p ~/.ssh && chmod 700 ~/.ssh && tr -d '\r' > $remoteKeyFile.tmp && chmod 600 $remoteKeyFile.tmp && mv -f $remoteKeyFile.tmp $remoteKeyFile && echo PRIVATE_KEY_COPIED"
        $pkOut = $null
        try { $pkOut = $pkContent | & ssh @sshArgsWithInput $copyPrivateCmd 2>&1 } catch { $pkOut = $_.Exception.Message }
        if (-not ($pkOut -match 'PRIVATE_KEY_COPIED')) { Write-Log "Remote private key copy may have failed: $pkOut" 'Warn' }
    } else {
        Write-Log "Local private key not found at $sshKeyPath; skipping remote copy." 'Warn'
    }

    # known_hosts on the workstation: this PC's known_hosts is no longer copied over the
    # shared account's file. Doing that replaced every colleague's entries on each start,
    # could bring in an outdated github.com key that then broke everyone's git push, and a
    # large file could exceed the Windows command-line length limit. Now we only make sure
    # the file exists (older container setups mount it) and add github.com's host keys if
    # the file has none yet. Existing lines are never changed or removed.
    $khCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/known_hosts && { ssh-keygen -F github.com -f ~/.ssh/known_hosts >/dev/null 2>&1 || ssh-keyscan -T 10 -t ed25519,ecdsa,rsa github.com >> ~/.ssh/known_hosts 2>/dev/null || true; } && echo KNOWN_HOSTS_OK"
    $khOut = $null
    try { $khOut = & ssh @sshArgs $khCmd 2>&1 } catch { $khOut = $_.Exception.Message }
    if (-not ($khOut -match 'KNOWN_HOSTS_OK')) { Write-Log "Remote known_hosts check may have failed: $khOut" 'Warn' }

    # 4.1.2: Scan remote repo list
    Write-Log "Scanning remote repositories at $remoteRepoBase" 'Info'
    # 'find' prints one folder name per line and nothing at all for an empty folder.
    # (The old 'ls | xargs basename' printed "basename: missing operand" for an empty
    # folder, and split folder names that contain spaces.) Hidden folders are skipped,
    # -xtype d also accepts links to folders, and the base path is single-quoted so
    # spaces in it are safe.
    $quotedRepoBase = "'" + $remoteRepoBase.Replace("'", "'\''") + "'"
    $listScript = "find $quotedRepoBase -mindepth 1 -maxdepth 1 -xtype d ! -name '.*' -printf '%f\n'"
    $repoScanOut = $null
    try {
        $repoScanOut = & ssh @sshArgs $listScript 2>&1
    } catch {
        # Keep the error as an ErrorRecord (not a plain string), so it is reported
        # below but can never be mistaken for a repository name.
        $repoScanOut = $_
    }
    $repoScanExit = $LASTEXITCODE
    # @(...) so that $repoList is ALWAYS an array: with exactly one repository it would
    # otherwise be a plain string, and .Count on it crashes the app under StrictMode.
    # ConvertTo-RemoteRepoList also drops ssh/find error lines, so they never appear
    # in the list as if they were repositories.
    $repoList = @(ConvertTo-RemoteRepoList -Output $repoScanOut)
    $repoScanErrors = (@($repoScanOut) | Where-Object { $_ -isnot [string] } | ForEach-Object { "$_" }) -join ' | '
    if ($repoScanErrors) { Write-Log "Repo scan messages (exit=$repoScanExit): $repoScanErrors" 'Warn' }

    Write-Log "Remote repo count discovered: $($repoList.Count)" 'Debug'

    if ($repoList.Count -eq 0) {
        # Tell the user what happened instead of silently going back to the location dialog.
        if ((Get-SshFailureKind -Output $repoScanOut) -eq 'Unreachable' -or $repoScanExit -eq 255) {
            $msg = "IMPACT lost the connection to the workstation ($remoteIp) while looking for repositories.`n`nPlease check the network or VPN connection and try again."
        } else {
            $msg = "No repositories were found in $remoteRepoBase on the workstation ($remoteIp).`n`nAsk the workstation admin to clone the IMPACT repository (for example IMPACTncd_Germany) into that folder, then try again."
        }
        Write-Log "No repositories found under $remoteRepoBase (exit=$repoScanExit): $repoScanErrors" 'Error'
        [System.Windows.Forms.MessageBox]::Show($msg, 'No repositories found', 'OK', 'Error') | Out-Null
        return $false
    }

    # 4.1.3: Repo selection dialog
    $formRepo = New-Object System.Windows.Forms.Form -Property @{
        Text = 'Select Remote Repository'
        Size = New-Object System.Drawing.Size(430,340)
        FormBorderStyle = 'FixedDialog'
        MaximizeBox = $false
    }
    Set-FormCenterOnCurrentScreen -Form $formRepo
    Apply-ThemeToForm -Form $formRepo

    $labelRepo = New-Object System.Windows.Forms.Label -Property @{
        Text = "Choose a repository to work with (remote: $remoteHost)"
        Location = New-Object System.Drawing.Point(14,14)
        Size = New-Object System.Drawing.Size(390,30)
    }
    Style-Label -Label $labelRepo
    $formRepo.Controls.Add($labelRepo)

    $listBox = New-Object System.Windows.Forms.ListBox -Property @{
        Location = New-Object System.Drawing.Point(14,50)
        Size = New-Object System.Drawing.Size(390,190)
        SelectionMode = 'One'
        BorderStyle = 'FixedSingle'
    }
    $palette = Get-ThemePalette
    $listBox.BackColor = $palette.Panel
    $listBox.ForeColor = $palette.Text
    $listBox.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Regular)
    $listBox.Items.AddRange([object[]]$repoList)
    $formRepo.Controls.Add($listBox)

    $buttonOk = New-Object System.Windows.Forms.Button -Property @{
        Text = 'Select'
        Location = New-Object System.Drawing.Point(216,260)
        Size = New-Object System.Drawing.Size(90,32)
    }
    Style-Button -Button $buttonOk -Variant 'primary'
    $formRepo.Controls.Add($buttonOk)

    $buttonCancel = New-Object System.Windows.Forms.Button -Property @{
        Text = 'Cancel'
        Location = New-Object System.Drawing.Point(320,260)
        Size = New-Object System.Drawing.Size(90,32)
        DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    }
    Style-Button -Button $buttonCancel -Variant 'secondary'
    $formRepo.Controls.Add($buttonCancel)

    $buttonOk.Add_Click({
        if (-not $listBox.SelectedItem) {
            [System.Windows.Forms.MessageBox]::Show('Please select a repository.', 'Repo required', 'OK', 'Warning') | Out-Null
            return
        }
        $formRepo.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $formRepo.Close()
    })
    $formRepo.AcceptButton = $buttonOk
    $formRepo.CancelButton = $buttonCancel

    $repoResult = $formRepo.ShowDialog()
    if ($repoResult -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-Log 'Repository selection cancelled.' 'Warn'
        return $false
    }

    $selectedRepo = $listBox.SelectedItem
    $State.SelectedRepo = $selectedRepo
    $State.Paths.RemoteRepo = "$remoteRepoBase/$selectedRepo"
    $State.ContainerName = "${selectedRepo}_$($State.UserName)"
    Write-Log "Selected remote repo: $($State.Paths.RemoteRepo)" 'Info'

    # 4.1.4: Configure Docker context over SSH (primary path) with direct-SSH fallback
    $contextName = "remote-$remoteIp"
    $State.Metadata.RemoteDockerContext = $contextName

    Write-Log "Ensuring Docker context $contextName exists (ssh://$remoteHost)" 'Info'
    $ctxExists = (& docker context ls --format '{{.Name}}' 2>$null) -contains $contextName
    if (-not $ctxExists) {
        # A failing native command such as docker does NOT throw in PowerShell, so a
        # try/catch never noticed a failure here. Check the exit code instead.
        & docker context create $contextName --docker "host=ssh://$remoteHost" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Docker context $contextName created." 'Debug'
        } else {
            Write-Log "Failed to create docker context, will attempt direct DOCKER_HOST fallback." 'Warn'
        }
    }

    # We deliberately do NOT run 'docker context use' here. That command changes the
    # user's GLOBAL Docker setting (saved in ~/.docker/config.json) and it stayed changed
    # after the app closed: later "Local" checks, and the user's own docker commands,
    # then silently talked to the shared workstation (or hung for minutes off the VPN).
    # It is not needed: every remote docker call in this app passes
    # '--context remote-<ip>' explicitly (see Get-DockerContextArgs).
    $contextActive = ((& docker context ls --format '{{.Name}}' 2>$null) -contains $contextName)

    # Older versions of this app DID switch the global context. If it still points at
    # this workstation, switch it back to Docker's built-in 'default' context so the
    # user's own docker commands talk to this computer again. ('docker context show'
    # does not exist in very old Docker versions; then the exit code is non-zero and
    # we simply skip this repair.)
    $currentGlobalContext = & docker context show 2>$null
    if ($LASTEXITCODE -eq 0 -and "$currentGlobalContext".Trim() -eq $contextName) {
        & docker context use default *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Reset the global Docker context from '$contextName' back to 'default' (left over from an older version of this app)." 'Info'
        }
    }

    if (-not $contextActive) {
        Write-Log 'Falling back to direct SSH via DOCKER_HOST.' 'Warn'
        $State.Flags.UseDirectSsh = $true
        Set-DockerSSHEnvironment -State $State
    } else {
        $State.Flags.UseDirectSsh = $false
        Write-Log "Using Docker context $contextName (passed with --context on each call)." 'Info'
    }

    # 4.1.5: Verify Docker Engine is installed and running on the remote host
    Write-Log 'Checking remote Docker Engine availability...' 'Info'
    $remoteDockerOk = $false
    $remoteDockerCliExists = $false
    # "permission denied" on the Docker socket means Docker IS running, but the workstation
    # account is not allowed to use it (usually: not in the 'docker' group). That needs an
    # admin, not a daemon restart, so it gets its own message instead of the sudo prompt.
    $remoteDockerPermissionDenied = $false
    $dockerPermissionMsg = "The workstation account '$remoteUser' is not allowed to use Docker on the workstation ($remoteIp): permission denied on the Docker socket.`n`nAsk the workstation admin to run:`n  sudo usermod -aG docker $remoteUser`n`nThen start IMPACT again."
    try {
        $sshCheckArgs = @('-n', '-i', $State.Paths.SshPrivate, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=15', $remoteHost)
        $dockerVer = & ssh @sshCheckArgs 'docker version --format "{{.Server.Version}}"' 2>&1
        if ($LASTEXITCODE -eq 0 -and $dockerVer -and $dockerVer -notmatch 'Cannot connect') {
            $remoteDockerOk = $true
            $remoteDockerCliExists = $true
            Write-Log "Remote Docker Engine running (Server version: $dockerVer)" 'Info'
        } else {
            # Join the output into one text: with 2>&1 it is a list of lines and error records.
            $dockerVerText = (@($dockerVer) | ForEach-Object { "$_" }) -join ' '
            Write-Log "Remote 'docker version' failed (exit=$LASTEXITCODE): $dockerVerText" 'Warn'
            if ($dockerVerText -match 'docker\.sock' -and $dockerVerText -match 'permission denied') {
                $remoteDockerCliExists = $true
                $remoteDockerPermissionDenied = $true
                Write-Log "Remote user '$remoteUser' may not access the Docker socket (not in the docker group?)." 'Error'
            } else {
                # Check if CLI exists but daemon is not running
                $whichDocker = & ssh @sshCheckArgs 'which docker 2>/dev/null || echo NOT_FOUND' 2>&1
                if ($whichDocker -and $whichDocker -notmatch 'NOT_FOUND') {
                    $remoteDockerCliExists = $true
                    Write-Log 'Remote Docker CLI found but daemon is not running.' 'Warn'
                } else {
                    Write-Log 'Remote Docker CLI not found.' 'Error'
                }
            }
        }
    } catch {
        Write-Log "Remote Docker check failed: $($_.Exception.Message)" 'Warn'
    }

    if ($remoteDockerPermissionDenied) {
        [System.Windows.Forms.MessageBox]::Show($dockerPermissionMsg, 'Docker Permission Denied (Remote)', 'OK', 'Error') | Out-Null
        return $false
    }

    if (-not $remoteDockerCliExists) {
        [System.Windows.Forms.MessageBox]::Show(
            "Docker Engine is not installed on the remote workstation ($remoteIp).`n`nInstall it on the remote host with:`n  sudo apt-get update`n  sudo apt-get install docker-ce docker-ce-cli containerd.io`n`nSee https://docs.docker.com/engine/install/ for details.",
            'Docker Engine Missing (Remote)', 'OK', 'Error') | Out-Null
        return $false
    }

    # 4.1.6: Attempt to start Docker daemon if not running
    if (-not $remoteDockerOk) {
        $startChoice = [System.Windows.Forms.MessageBox]::Show(
            "Docker daemon is not running on the remote workstation ($remoteIp).`n`nAttempt to start it? You will be prompted for the sudo password in the console.",
            'Docker Daemon Not Running (Remote)', 'YesNo', 'Warning')

        if ($startChoice -eq [System.Windows.Forms.DialogResult]::Yes) {
            Write-Log 'Attempting to start remote Docker daemon via sudo systemctl...' 'Info'
            Write-Host ''
            Write-Host '--- Enter the sudo password on the remote host when prompted ---' -ForegroundColor Yellow
            try {
                # Start-Process joins its arguments with plain spaces and quotes nothing, so a
                # key path with a space (C:\Users\Max Mustermann\...) would be split in two and
                # ssh would treat the second half as the host name. So we put double quotes
                # around the path ourselves. Start-Process is kept on purpose: it gives ssh the
                # real console, which the sudo password prompt (-t) needs.
                $startArgs = @('-i', "`"$($State.Paths.SshPrivate)`"", '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=30', '-t', $remoteHost, 'sudo systemctl start docker')
                $p = Start-Process -FilePath 'ssh' -ArgumentList $startArgs -Wait -PassThru -NoNewWindow
                if ($p.ExitCode -eq 0) {
                    Write-Log 'sudo systemctl start docker completed.' 'Info'
                    # Wait briefly for the daemon socket to become available
                    Start-Sleep -Seconds 3
                    # Re-check
                    $sshCheckArgs2 = @('-n', '-i', $State.Paths.SshPrivate, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=15', $remoteHost)
                    $dockerVer2 = & ssh @sshCheckArgs2 'docker version --format "{{.Server.Version}}"' 2>&1
                    if ($LASTEXITCODE -eq 0 -and $dockerVer2 -and $dockerVer2 -notmatch 'Cannot connect') {
                        $remoteDockerOk = $true
                        Write-Log "Remote Docker Engine started successfully (Server version: $dockerVer2)" 'Info'
                    } else {
                        # The daemon may now be running while the account still may not use it.
                        $dockerVer2Text = (@($dockerVer2) | ForEach-Object { "$_" }) -join ' '
                        Write-Log "Remote 'docker version' after start failed: $dockerVer2Text" 'Warn'
                        if ($dockerVer2Text -match 'docker\.sock' -and $dockerVer2Text -match 'permission denied') { $remoteDockerPermissionDenied = $true }
                    }
                } else {
                    Write-Log "sudo systemctl start docker exited with code $($p.ExitCode)" 'Warn'
                }
            } catch {
                Write-Log "Failed to start remote Docker: $($_.Exception.Message)" 'Warn'
            }
            Write-Host '--- End of remote sudo session ---' -ForegroundColor Yellow
            Write-Host ''
        }

        if (-not $remoteDockerOk) {
            if ($remoteDockerPermissionDenied) {
                [System.Windows.Forms.MessageBox]::Show($dockerPermissionMsg, 'Docker Permission Denied (Remote)', 'OK', 'Error') | Out-Null
                return $false
            }
            [System.Windows.Forms.MessageBox]::Show(
                "Docker daemon could not be started on the remote workstation ($remoteIp).`n`nStart it manually on the remote host:`n  sudo systemctl start docker`n  sudo systemctl enable docker",
                'Docker Daemon Start Failed', 'OK', 'Error') | Out-Null
            return $false
        }
    }

    # 4.1.7: Check docker group membership for the remote user
    Write-Log 'Checking remote user docker group membership...' 'Info'
    try {
        $sshGroupArgs = @('-n', '-i', $State.Paths.SshPrivate, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=15', $remoteHost)
        $groupsOutput = & ssh @sshGroupArgs 'groups' 2>&1
        if ($LASTEXITCODE -eq 0 -and $groupsOutput) {
            $groupList = $groupsOutput -split '\s+'
            if ($groupList -contains 'docker') {
                Write-Log "Remote user '$remoteUser' is in the docker group." 'Info'
            } else {
                Write-Log "Remote user '$remoteUser' is NOT in the docker group. Groups: $groupsOutput" 'Warn'
                [System.Windows.Forms.MessageBox]::Show(
                    "The remote user '$remoteUser' is not in the 'docker' group.`n`nDocker commands may fail with permission errors.`n`nFix this on the remote host:`n  sudo usermod -aG docker $remoteUser`n`nThen log out and back in (or reboot) for it to take effect.",
                    'Docker Group Warning', 'OK', 'Warning') | Out-Null
            }
        }
    } catch {
        Write-Log "Could not check docker group membership: $($_.Exception.Message)" 'Debug'
    }

    return $true
}

# 4b. Local prep: folder selection and docker context
function Ensure-LocalPreparation {
    param([pscustomobject]$State)
    Write-Log 'Local flow: selecting repository folder' 'Info'

    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog -Property @{
        Description = 'Select the local folder containing your simulation model and its GitHub repository:'
        RootFolder = [System.Environment+SpecialFolder]::MyComputer
        ShowNewFolderButton = $false
    }

    $documentsPath = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::MyDocuments)
    # -LiteralPath: treat the path as plain text. Without it, PowerShell reads '[' and ']'
    # in a folder name as wildcard characters and the test can wrongly fail.
    if ($documentsPath -and (Test-Path -LiteralPath $documentsPath)) {
        $folderBrowser.SelectedPath = $documentsPath
    }

    $folderResult = $folderBrowser.ShowDialog()
    if ($folderResult -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-Log 'Folder selection cancelled.' 'Warn'
        [System.Windows.Forms.MessageBox]::Show('Folder selection is required to continue.', 'Selection Cancelled', 'OK', 'Warning') | Out-Null
        return $false
    }

    $selectedPath = $folderBrowser.SelectedPath
    if ([string]::IsNullOrWhiteSpace($selectedPath) -or -not (Test-Path -LiteralPath $selectedPath)) {
        Write-Log 'Invalid folder selection.' 'Error'
        [System.Windows.Forms.MessageBox]::Show('Please select a valid folder containing your repository.', 'Invalid Selection', 'OK', 'Error') | Out-Null
        return $false
    }

    # Docker Desktop can only share folders that are on a disk of THIS computer with a
    # container. A network share (\\server\share\...) or a mapped network drive (for
    # example H:\ when "Documents" is redirected to a file server) is accepted by the
    # folder picker, but 'docker run' then fails with a confusing mount error, and only
    # after the long image build. So we stop here with a clear explanation instead.
    $isNetworkFolder = $false
    if ($selectedPath -match '^(\\\\|//)') {
        # Starts with \\ or // : a UNC network path (also covers \\wsl.localhost\...).
        $isNetworkFolder = $true
    } else {
        try {
            $driveRoot = [System.IO.Path]::GetPathRoot($selectedPath)
            if ($driveRoot -and ([System.IO.DriveInfo]::new($driveRoot)).DriveType -eq [System.IO.DriveType]::Network) {
                $isNetworkFolder = $true
            }
        } catch {
            # If Windows cannot tell us the drive type, do not block the user.
            Write-Log "Could not determine the drive type of '$selectedPath': $($_.Exception.Message)" 'Debug'
        }
    }
    if ($isNetworkFolder) {
        Write-Log "Selected folder is on a network drive or share: $selectedPath" 'Error'
        [System.Windows.Forms.MessageBox]::Show(
            "The selected folder is on a network drive or network share:`n$selectedPath`n`nDocker Desktop cannot share network folders with containers, so the model could not start from here.`n`nPlease copy or clone the repository to a folder on this computer (for example C:\Users\<your name>\Repositories) and select that folder.",
            'Network Folder Not Supported', 'OK', 'Error') | Out-Null
        return $false
    }

    # The model repository must contain a 'docker_setup' folder (the image is built from
    # it). Checking now catches a wrong folder choice (for example the parent folder
    # 'Repositories') right away instead of only when the user clicks Start.
    if (-not (Test-Path -LiteralPath (Join-Path $selectedPath 'docker_setup') -PathType Container)) {
        Write-Log "No docker_setup folder found in selected folder: $selectedPath" 'Error'
        [System.Windows.Forms.MessageBox]::Show(
            "The selected folder does not contain a 'docker_setup' folder:`n$selectedPath`n`nPlease select the main folder of the model repository (the folder that contains 'docker_setup').",
            'Not a Model Repository', 'OK', 'Error') | Out-Null
        return $false
    }

    # The folder name is reused as the container name, the image name and the folder name
    # inside the container. Docker rejects names with spaces, brackets or accents (for
    # example 'IMPACTncd_Germany - Kopie'), which used to make Start fail with only
    # "Docker build failed". ConvertTo-DockerSafeRepoName (module) leaves normal names
    # unchanged and turns other names into a safe form ('IMPACTncd_Germany_Kopie').
    $folderName = Split-Path $selectedPath -Leaf
    $safeRepoName = ConvertTo-DockerSafeRepoName -Name $folderName
    if (-not $safeRepoName) {
        Write-Log "Folder name '$folderName' cannot be turned into a Docker name." 'Error'
        [System.Windows.Forms.MessageBox]::Show(
            "The folder name '$folderName' cannot be used by Docker.`n`nPlease rename the folder using only letters (A-Z), digits, '-' or '_' (for example IMPACTncd_Germany) and select it again.",
            'Unsupported Folder Name', 'OK', 'Error') | Out-Null
        return $false
    }
    if ($safeRepoName -cne $folderName) {
        Write-Log "Folder name '$folderName' contains characters Docker does not accept; using '$safeRepoName' for the container and image name instead." 'Warn'
    }

    # OneDrive folders DO work with Docker, but OneDrive keeps uploading every change in
    # the Git data and in the (large) simulation outputs. This can slow the computer down,
    # fill the OneDrive quota and cause sync conflicts. Warn, but let the user continue.
    $inOneDrive = ($selectedPath -match '\\OneDrive( - [^\\]+)?(\\|$)')
    foreach ($oneDriveRoot in @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer)) {
        if ($oneDriveRoot -and $selectedPath.StartsWith($oneDriveRoot, [System.StringComparison]::OrdinalIgnoreCase)) { $inOneDrive = $true }
    }
    if ($inOneDrive) {
        Write-Log "Selected folder is inside OneDrive: $selectedPath" 'Warn'
        $oneDriveChoice = [System.Windows.Forms.MessageBox]::Show(
            "The selected folder is inside OneDrive:`n$selectedPath`n`nThis works, but OneDrive will keep syncing the model's Git data and its (possibly large) output files. That can slow down your computer, use up your OneDrive storage and cause sync conflicts.`n`nA folder outside OneDrive (for example C:\Users\<your name>\Repositories) is recommended.`n`nContinue with this folder anyway?",
            'Folder Inside OneDrive', 'YesNo', 'Warning')
        if ($oneDriveChoice -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-Log 'User chose not to use the OneDrive folder.' 'Info'
            return $false
        }
    }

    $State.Paths.LocalRepo = $selectedPath
    $State.SelectedRepo = $safeRepoName
    $State.ContainerName = "$($State.SelectedRepo)_$($State.UserName)"
    Write-Log "Local repository path: $($State.Paths.LocalRepo)" 'Info'
    Write-Log "Repository name: $($State.SelectedRepo)" 'Info'

    $gitPath = Join-Path $selectedPath '.git'
    if (-not (Test-Path -LiteralPath $gitPath)) {
        Write-Log 'No .git directory found in selected folder.' 'Warn'
        $continueResult = [System.Windows.Forms.MessageBox]::Show(
            "The selected folder does not appear to be a Git repository.`n`nDo you want to continue anyway?",
            'No Git Repository Found',
            'YesNo',
            'Question'
        )

        if ($continueResult -eq [System.Windows.Forms.DialogResult]::No) {
            Write-Log 'User chose not to continue without Git repository.' 'Warn'
            return $false
        }
        Write-Log 'User chose to continue without Git repository.' 'Info'
    } else {
        Write-Log 'Git repository detected in selected folder.' 'Info'
    }

    Write-Log 'Checking local Docker availability and context.' 'Info'

    try {
        $dockerVersion = & docker --version 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Docker CLI returned non-zero exit code (exit=$LASTEXITCODE). Output: $dockerVersion" 'Error'
            # Double quotes so that `n becomes a real line break (in single quotes it was shown as text).
            [System.Windows.Forms.MessageBox]::Show("Docker is not available on this system.`n`nPlease ensure Docker Desktop is installed and running on your Windows machine.", 'Docker Not Available', 'OK', 'Error') | Out-Null
            return $false
        }
        Write-Log "Docker detected: $dockerVersion" 'Info'
    } catch {
        Write-Log "Could not check Docker availability: $($_.Exception.Message)" 'Error'
        [System.Windows.Forms.MessageBox]::Show("Could not verify Docker availability.`n`nPlease ensure Docker Desktop is installed and running on your Windows machine.", 'Docker Check Failed', 'OK', 'Error') | Out-Null
        return $false
    }

    # If the user chose Remote earlier in this session (then clicked Back and chose Local),
    # DOCKER_HOST / DOCKER_SSH_OPTS may still point at the workstation. Clear them so the
    # checks below really test the Docker engine on THIS computer.
    $env:DOCKER_HOST = $null
    $env:DOCKER_SSH_OPTS = $null

    # Create the 'local' Docker context FIRST, so that every check below can name it
    # explicitly with '--context local'. Before, the checks used whatever context was
    # globally active. After a Remote session of an older version of this app that was the
    # shared workstation, so the checks hung for minutes off the VPN (and then wrongly said
    # Docker could not start) or tested the wrong machine.
    $LocalContextName = 'local'
    $onWindows = ($PSVersionTable.PSEdition -eq 'Desktop' -or $env:OS -like '*Windows*')
    if ($onWindows) {
        $dockerHost = 'npipe:////./pipe/docker_engine'
    } else {
        $dockerHost = 'unix:///var/run/docker.sock'
    }
    Write-Log "Configuring Docker context '$LocalContextName' for host $dockerHost" 'Info'

    $exists = (& docker context ls --format '{{.Name}}' 2>$null) -contains $LocalContextName
    if (-not $exists) {
        & docker context create $LocalContextName --description 'Local Docker engine' --docker "host=$dockerHost" | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Log 'Docker context created successfully.' 'Info'
        } else {
            Write-Log 'Failed to create Docker context.' 'Error'
        }
    } else {
        Write-Log "Context '$LocalContextName' already exists." 'Debug'
    }

    # Text Docker prints when this Windows account is not allowed to use Docker
    # ("Access is denied"; German Windows may say "Zugriff verweigert"). Starting Docker
    # Desktop or waiting cannot fix that, so we recognise it and explain the real fix.
    $accessDeniedPattern = 'access is denied|zugriff verweigert|permission denied'

    # Helper: explain how to fix "not allowed to use Docker" (the docker-users group).
    $showDockerAccessHelp = {
        Write-Log 'Docker refused access for this Windows account (probably not in the docker-users group).' 'Error'
        [System.Windows.Forms.MessageBox]::Show(
            "Docker Desktop is installed, but your Windows account is not allowed to use it.`n`nThis usually means your account is not a member of the local 'docker-users' group. This is common when IT installed Docker Desktop with an administrator account.`n`nHow to fix it:`n1. Ask IT or an administrator to add your account to the 'docker-users' group. An administrator can run:`n     net localgroup docker-users `"$($env:USERDOMAIN)\$($env:USERNAME)`" /add`n2. Sign out of Windows and sign back in (or restart the computer).`n3. Start IMPACT again.",
            'Docker Access Denied', 'OK', 'Error') | Out-Null
    }

    # Helper: $true when the 'docker-users' group exists on this computer and the current
    # Windows login is NOT in it. $null when we cannot tell (group missing, not Windows).
    # This does not depend on the Windows display language. It is only used as an extra
    # hint after Docker failed, never to block the user on its own.
    $testNotInDockerUsers = {
        try {
            $groupSid = ([System.Security.Principal.NTAccount]::new('docker-users')).Translate([System.Security.Principal.SecurityIdentifier])
            $principal = [System.Security.Principal.WindowsPrincipal]::new([System.Security.Principal.WindowsIdentity]::GetCurrent())
            return (-not $principal.IsInRole($groupSid))
        } catch {
            return $null
        }
    }

    # Helper: does this Docker error mean "this account may not use Docker"? Yes when the
    # text says "access denied" AND we cannot confirm that the account IS in docker-users.
    # If the account is confirmed to be in the group, the message is more likely a short
    # hiccup while Docker Desktop (re)starts, so we keep waiting instead of sending the
    # user to IT.
    $isDockerAccessProblem = {
        param([string]$ErrorText)
        return (($ErrorText -match $accessDeniedPattern) -and ((& $testNotInDockerUsers) -ne $false))
    }

    # Helper: ask the local engine ('docker info') up to $MaxAttempts times, about once per
    # second. Each try runs in a background job with a 5 second limit, because a
    # half-started Docker Desktop can make 'docker info' hang. Returns an object with
    # Running ($true/$false) and ErrorText (Docker's last error message, kept for the log
    # and to recognise "access denied").
    $waitForLocalDocker = {
        param([int]$MaxAttempts)
        $lastError = ''
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            Start-Sleep -Seconds 1
            $checkJob = Start-Job -ScriptBlock {
                param($ctx)
                $text = (& docker --context $ctx info 2>&1 | ForEach-Object { "$_" }) -join "`n"
                [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $text }
            } -ArgumentList $LocalContextName
            if (Wait-Job $checkJob -Timeout 5) {
                $checkResult = Receive-Job $checkJob -ErrorAction SilentlyContinue
                Remove-Job $checkJob -Force -ErrorAction SilentlyContinue
                # Under StrictMode, reading a property of $null throws, so check first.
                $checkExitCode = if ($checkResult) { $checkResult.ExitCode } else { -1 }
                Write-Log "Docker start check attempt $attempt exit=$checkExitCode" 'Debug'
                if ($checkExitCode -eq 0) { return [pscustomobject]@{ Running = $true; ErrorText = '' } }
                if ($checkResult) { $lastError = ([string]$checkResult.Output).Trim() }
                # A permission problem does not go away by waiting longer.
                if (& $isDockerAccessProblem $lastError) { break }
            } else {
                Stop-Job $checkJob -ErrorAction SilentlyContinue
                Remove-Job $checkJob -Force -ErrorAction SilentlyContinue
                $lastError = 'docker info did not answer within 5 seconds.'
            }
            if ($attempt % 10 -eq 0) {
                Write-Log 'Docker is still starting up...' 'Info'
            }
        }
        if ($lastError) { Write-Log "Last Docker error: $lastError" 'Debug' }
        return [pscustomobject]@{ Running = $false; ErrorText = $lastError }
    }

    $dockerRunning = $false
    $quickCheck = $null
    $dockerErrorText = ''
    try {
        # 2>&1 keeps Docker's error message (it used to be thrown away with 2>$null), so we
        # can tell "Docker is not running" apart from "you are not allowed to use Docker".
        $quickOutput = & docker --context $LocalContextName version --format "{{.Server.Version}}" 2>&1
        if ($LASTEXITCODE -eq 0 -and $quickOutput) {
            $quickCheck = (($quickOutput | ForEach-Object { "$_" }) -join ' ').Trim()
            $dockerRunning = $true
            Write-Log "Docker engine is running (Server version: $quickCheck)" 'Info'
        } else {
            $dockerErrorText = (($quickOutput | ForEach-Object { "$_" }) -join "`n").Trim()
            Write-Log "Quick Docker check failed: $dockerErrorText" 'Debug'
        }
    } catch {
        Write-Log "Quick Docker version check failed: $($_.Exception.Message)" 'Debug'
    }

    # Docker said "access denied": starting Docker Desktop and waiting will never help.
    if (-not $dockerRunning -and (& $isDockerAccessProblem $dockerErrorText)) {
        & $showDockerAccessHelp
        return $false
    }

    # Becomes $true only when the user explicitly chooses "continue anyway" below.
    $userSkippedDockerCheck = $false

    if (-not $dockerRunning) {
        Write-Log 'Docker engine is not running; attempting to start Docker Desktop.' 'Warn'
        try {
            $dockerDesktopPath = "${env:ProgramFiles}\Docker\Docker\Docker Desktop.exe"
            if (Test-Path $dockerDesktopPath) {
                Write-Log "Attempting to start Docker Desktop via ProgramFiles path: $dockerDesktopPath" 'Debug'
                Start-Process -FilePath $dockerDesktopPath -WindowStyle Hidden
            } else {
                $dockerDesktopAlt = "${env:LOCALAPPDATA}\Programs\Docker\Docker\Docker Desktop.exe"
                if (Test-Path $dockerDesktopAlt) {
                    Write-Log "Attempting to start Docker Desktop via LocalAppData path: $dockerDesktopAlt" 'Debug'
                    Start-Process -FilePath $dockerDesktopAlt -WindowStyle Hidden
                } else {
                    Write-Log 'Docker Desktop executable not found; trying service startup.' 'Warn'
                    Start-Service -Name 'com.docker.service' -ErrorAction SilentlyContinue
                }
            }
        } catch {
            Write-Log "Failed to start Docker Desktop: $($_.Exception.Message)" 'Error'
        }

        # Give Docker Desktop time to boot (up to about 30 checks).
        try {
            $waitResult = & $waitForLocalDocker 30
            $dockerRunning = $waitResult.Running
            $dockerErrorText = $waitResult.ErrorText
        } catch {
            Write-Log "Docker start check failed: $($_.Exception.Message)" 'Debug'
        }

        # Keep asking until Docker runs, or the user chooses "continue anyway" or "go back".
        # Before, "Yes - wait and try again" did not check again at all and the app went on
        # as if Docker was fine; that later showed up as a confusing "Docker build failed".
        while (-not $dockerRunning) {
            if (& $isDockerAccessProblem $dockerErrorText) {
                & $showDockerAccessHelp
                return $false
            }
            Write-Log 'Docker engine did not start within the expected time.' 'Warn'

            # Extra hint when this Windows account is not in the docker-users group.
            $groupHint = ''
            if ((& $testNotInDockerUsers) -eq $true) {
                Write-Log "The current Windows account is not in the 'docker-users' group." 'Warn'
                $groupHint = "`n`nNote: your Windows account is not in the 'docker-users' group. Docker Desktop usually refuses to work for such accounts. Ask IT or an administrator to add you to 'docker-users', then sign out of Windows and back in."
            }

            $choice = [System.Windows.Forms.MessageBox]::Show(
                "Docker engine could not be started automatically.$groupHint`n`nWould you like to:`n- Click 'Yes' to start Docker Desktop yourself and check again`n- Click 'No' to continue anyway (starting a container will fail until Docker runs)`n- Click 'Cancel' to go back to the previous step",
                'Docker Startup Issue',
                'YesNoCancel',
                'Warning'
            )

            if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
                $manualChoice = [System.Windows.Forms.MessageBox]::Show(
                    "Please start Docker Desktop from the Windows Start menu and wait until it shows that the engine is running.`n`nThen click OK to check again, or Cancel to go back to the previous step.",
                    'Manual Start Required',
                    'OKCancel',
                    'Information'
                )
                if ($manualChoice -ne [System.Windows.Forms.DialogResult]::OK) {
                    Write-Log 'User chose to go back while waiting for Docker.' 'Warn'
                    return $false
                }
                Write-Log 'Checking the Docker engine again...' 'Info'
                try {
                    $waitResult = & $waitForLocalDocker 10
                    $dockerRunning = $waitResult.Running
                    $dockerErrorText = $waitResult.ErrorText
                } catch {
                    Write-Log "Docker start check failed: $($_.Exception.Message)" 'Debug'
                }
            } elseif ($choice -eq [System.Windows.Forms.DialogResult]::No) {
                Write-Log 'User chose to continue without a running Docker engine.' 'Warn'
                $userSkippedDockerCheck = $true
                break
            } else {
                # Cancel (or closing the box): the wizard treats $false as "go back to the
                # location choice". The old text wrongly said Cancel would exit.
                Write-Log 'User chose to go back after Docker startup failure.' 'Warn'
                return $false
            }
        }
    }

    if (-not $dockerRunning) {
        Write-Log 'Docker engine may still be unavailable; continuing with caution.' 'Warn'
    } elseif ($quickCheck) {
        Write-Log "Docker engine is running (version: $quickCheck)." 'Info'
    } else {
        Write-Log 'Docker engine is running.' 'Info'
    }

    # NOTE: 'docker context use' changes the user's GLOBAL Docker context. It is kept for
    # now because the local image builds (Start button) still call 'docker build' without
    # '--context', and switching to 'local' here makes them use this computer. It also
    # repairs computers where an older version of this app left the global context
    # pointing at the workstation. Once every local docker call passes '--context local',
    # this line can be removed.
    & docker context use $LocalContextName *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Switched to Docker context '$LocalContextName'." 'Info'
    } else {
        Write-Log "Failed to switch to Docker context '$LocalContextName'." 'Warn'
    }

    & docker --context $LocalContextName version 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Log 'Docker connection test passed.' 'Info'
    } elseif ($userSkippedDockerCheck) {
        Write-Log 'Docker connection test failed (user chose to continue anyway).' 'Warn'
    } else {
        # Docker answered a moment ago but not now (for example it was just closed or is
        # restarting). Returning success here used to end in a misleading "build failed".
        Write-Log 'Docker connection test failed.' 'Error'
        [System.Windows.Forms.MessageBox]::Show(
            "IMPACT could not connect to Docker Desktop on this computer.`n`nPlease check that Docker Desktop is running and shows that the engine is running, then try again.",
            'Docker Not Reachable', 'OK', 'Error') | Out-Null
        return $false
    }

    $State.Metadata.LocalDockerContext = $LocalContextName
    Write-Log 'Local Docker environment is ready.' 'Info'
    return $true
}

# 5. Container status detection
function Get-ContainerStatus {
    param([pscustomobject]$State)
    Write-Log "Checking status of container '$($State.ContainerName)' on $($State.ContainerLocation)." 'Info'

    Set-DockerSSHEnvironment -State $State
    $ctxArgs = Get-DockerContextArgs -State $State

    # Remember whether Docker answered at all. Before, any error (Docker Desktop not
    # running yet, a network/SSH problem with the workstation) silently looked exactly like
    # "container STOPPED", and Start then failed later with a misleading build error.
    # The first 'docker ps' tells us; if it fails, the user can retry or continue knowingly.
    $dockerReachable = $false
    $portUsers = @()
    do {
        $retryStatusCheck = $false
        $dockerStatusError = ''
        try {
            $psCmd = $ctxArgs + @('ps','--format','{{.Names}}\t{{.Ports}}')
            # 2>&1 keeps Docker's error text; error lines arrive as ErrorRecord objects,
            # so we separate them from the normal output lines.
            $psOutput = & docker @psCmd 2>&1
            $psExitCode = $LASTEXITCODE
            $all = @($psOutput | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
            if ($psExitCode -eq 0) {
                $dockerReachable = $true
                foreach ($line in ($all -split "`n")) {
                    # Any host address (0.0.0.0, [::], or 127.0.0.1 for LOCAL containers, F13);
                    # same pattern as Get-UsedPorts in the module.
                    foreach ($m in [regex]::Matches($line, ':(\d{4,5})->8787/tcp')) {
                        $port = $m.Groups[1].Value
                        if ($portUsers -notcontains $port) { $portUsers += $port }
                    }
                }
            } else {
                $dockerStatusError = (($psOutput | ForEach-Object { "$_" }) -join "`n").Trim()
            }
        } catch {
            $dockerStatusError = $_.Exception.Message
            Write-Log "Port scan failed: $($_.Exception.Message)" 'Warn'
        }
        if (-not $dockerReachable) {
            if (-not $dockerStatusError) { $dockerStatusError = '(no error text)' }
            Write-Log "Docker is not reachable for the status check: $dockerStatusError" 'Warn'
            $statusWhere = if ($State.ContainerLocation -eq 'LOCAL') { 'Docker Desktop on this computer' } else { "Docker on the workstation ($($State.RemoteHostIp))" }
            # Keep the message box readable if Docker printed a very long error.
            $shortStatusError = if ($dockerStatusError.Length -gt 400) { $dockerStatusError.Substring(0, 400) + ' ...' } else { $dockerStatusError }
            $statusChoice = [System.Windows.Forms.MessageBox]::Show(
                "IMPACT could not get the container status from $statusWhere.`n`nDocker said:`n$shortStatusError`n`nClick 'Retry' to check again (for example once Docker Desktop has finished starting, or the network connection is back).`n`nClick 'Cancel' to open the container manager anyway. The status shown there may then be wrong: a running container can look STOPPED.",
                'Docker Not Reachable', 'RetryCancel', 'Warning')
            if ($statusChoice -eq [System.Windows.Forms.DialogResult]::Retry) { $retryStatusCheck = $true }
        }
    } while ($retryStatusCheck)
    # Other code (for example the container manager) can use this to show "unknown"
    # instead of "STOPPED" when Docker could not be asked.
    $State.Metadata.DockerReachable = $dockerReachable
    Write-Log "Discovered in-use ports: $([string]::Join(',', $portUsers))" 'Debug'
    $State.Ports.Used = $portUsers

    # Collect containers for this user.
    # Docker treats the name filter as a regular expression that matches ANYWHERE in the
    # container name, so '_jo' also matched '..._john' (a colleague's container on the
    # shared workstation) and caused a false "Other containers are running" warning.
    # The trailing '$' anchors it to the END of the name ("<repo>_<user>"); Escape makes
    # the user name match literally. GitHub user names cannot contain '_', so
    # '_<user>' at the end can only be this user's own containers.
    $pattern = "_$([regex]::Escape([string]$State.UserName))$"
    # Use raw format (no table header/padding) so parsing stays reliable
    $psAll = $ctxArgs + @('ps','-a','--filter',"name=$pattern",'--format','{{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}')

    $State.Metadata.ExistingContainers = @()
    try {
        # Skip the call when Docker did not answer above (over SSH each failing call can
        # take up to 30 seconds).
        $out = if ($dockerReachable) { & docker @psAll 2>$null } else { $null }
        if ($LASTEXITCODE -eq 0 -and $out) {
            $lines = ($out -split "`n") | Where-Object { $_ }
            foreach ($l in $lines) {
                $parts = $l -split "`t"
                if ($parts.Count -ge 2) {
                    $State.Metadata.ExistingContainers += [pscustomobject]@{
                        Name   = $parts[0]
                        Status = $parts[1]
                        Ports  = if ($parts.Count -ge 3) { $parts[2] } else { '' }
                        Image  = if ($parts.Count -ge 4) { $parts[3] } else { '' }
                    }
                }
            }
            Write-Log "Existing containers parsed: $($State.Metadata.ExistingContainers.Count)" 'Debug'
        }
    } catch {
        Write-Log "Container list failed: $($_.Exception.Message)" 'Warn'
    }

    # Detect if target container is running
    $isRunning = $false
    try {
        $psRunning = $ctxArgs + @('ps','--filter',"name=^$($State.ContainerName)$",'--format','{{.Names}}')
        $name = if ($dockerReachable) { & docker @psRunning 2>$null } else { $null }
        if ($LASTEXITCODE -eq 0 -and $name -and $name.Trim() -eq $State.ContainerName) { $isRunning = $true }
    } catch {
        Write-Log "Running check failed: $($_.Exception.Message)" 'Warn'
    }
    $State.Metadata.ContainerRunning = $isRunning
    if ($isRunning) {
        Write-Log "Container '$($State.ContainerName)' is currently running." 'Debug'
    } else {
        Write-Log "Container '$($State.ContainerName)' is not running." 'Debug'
    }

    # The app always starts containers with '--rm', so Docker deletes them when they stop.
    # A STOPPED container with our name can therefore only come from outside the app (for
    # example one created by hand in Docker Desktop). It makes 'docker run --name ...' fail
    # with "name already in use", and the Stop button cannot help because nothing is
    # running. Offer to remove it so that Start works again.
    if ($dockerReachable -and -not $isRunning) {
        # Status 'Up ...' means running (or paused); never offer to remove such a container.
        $leftoverContainer = @($State.Metadata.ExistingContainers | Where-Object { $_.Name -eq $State.ContainerName -and $_.Status -notmatch '^Up' })
        if ($leftoverContainer.Count -gt 0) {
            $leftoverStatus = $leftoverContainer[0].Status
            Write-Log "Found a stopped container named '$($State.ContainerName)' (status: $leftoverStatus)." 'Warn'
            $removeChoice = [System.Windows.Forms.MessageBox]::Show(
                "A stopped container named '$($State.ContainerName)' already exists (status: $leftoverStatus).`n`nIt prevents IMPACT from starting a new container with the same name.`n`nRemove the old container now? Files in your repository folder are not affected.",
                'Old Container Found', 'YesNo', 'Question')
            if ($removeChoice -eq [System.Windows.Forms.DialogResult]::Yes) {
                $rmCmd = $ctxArgs + @('rm', $State.ContainerName)
                $rmOutput = & docker @rmCmd 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "Removed stopped container '$($State.ContainerName)'." 'Info'
                    $State.Metadata.ExistingContainers = @($State.Metadata.ExistingContainers | Where-Object { $_.Name -ne $State.ContainerName })
                } else {
                    $rmError = (($rmOutput | ForEach-Object { "$_" }) -join "`n").Trim()
                    Write-Log "Could not remove container '$($State.ContainerName)': $rmError" 'Warn'
                    [System.Windows.Forms.MessageBox]::Show(
                        "The old container could not be removed.`n`nDocker said:`n$rmError`n`nYou can remove it in Docker Desktop (Containers list) and then click Start.",
                        'Remove Failed', 'OK', 'Warning') | Out-Null
                }
            } else {
                Write-Log 'User kept the stopped container; Start will fail until it is removed.' 'Warn'
            }
        }
    }
    # Always start from empty recovered details (F32). They used to be reset only when
    # the container was running, so after Stop + Back the old password, port and
    # volume flag of a previous container were shown again for a new one.
    $State.Metadata.Recovered = @{ Password = $null; Port = $null; UseVolumes = $false; OutputDir = $null; SynthpopDir = $null; VolumeOutput = $null; VolumeSynthpop = $null }

    # If running, attempt to recover connection details
    if ($isRunning) {
        $metaUseVolumes = $null
        if ($State.ContainerLocation -like 'REMOTE@*') {
            $meta = Read-RemoteContainerMetadata -State $State
            if ($meta) {
                # Check each property before reading it: StrictMode throws on missing
                # properties, and newer metadata files no longer contain the password (F40).
                if ($meta.PSObject.Properties['password'] -and $meta.password) { $State.Metadata.Recovered.Password = $meta.password }
                if ($meta.PSObject.Properties['port'] -and $meta.port) { $State.Metadata.Recovered.Port = $meta.port }
                if ($meta.PSObject.Properties['useVolumes'] -and $null -ne $meta.useVolumes) { $metaUseVolumes = [bool]$meta.useVolumes }
            }
        }
        # Always inspect the container itself: it is the most reliable source and, through
        # its labels and mounts, the only one that also works for LOCAL containers (F04).
        $runtime = Get-ContainerRuntimeInfo -State $State
        if ($runtime.Password) { $State.Metadata.Recovered.Password = $runtime.Password }
        if ($runtime.Port) { $State.Metadata.Recovered.Port = $runtime.Port }
        if ($null -ne $runtime.UseVolumes) {
            $State.Metadata.Recovered.UseVolumes = [bool]$runtime.UseVolumes
        } elseif ($null -ne $metaUseVolumes) {
            $State.Metadata.Recovered.UseVolumes = $metaUseVolumes
        }
        # Where results must be copied back to at Stop, and which volumes hold them.
        $State.Metadata.Recovered.OutputDir = $runtime.OutputDir
        $State.Metadata.Recovered.SynthpopDir = $runtime.SynthpopDir
        $State.Metadata.Recovered.VolumeOutput = $runtime.VolumeOutput
        $State.Metadata.Recovered.VolumeSynthpop = $runtime.VolumeSynthpop
    }
    return $State
}

# 6. Container management UI
function Show-ContainerManager {
    param([pscustomobject]$State)
    if (-not $State.Metadata.ContainsKey('Recovered') -or -not $State.Metadata.Recovered) {
        $State.Metadata.Recovered = @{ UseVolumes = $false; Password = $null; Port = $null; OutputDir = $null; SynthpopDir = $null; VolumeOutput = $null; VolumeSynthpop = $null }
    }
    if (-not $State.Metadata.ContainsKey('ActivePort')) { $State.Metadata.ActivePort = $null }
    if (-not $State.Metadata.ContainsKey('ActiveUseVolumes')) { $State.Metadata.ActiveUseVolumes = $false }
    if (-not $State.Metadata.ContainsKey('ActiveRepoPath')) { $State.Metadata.ActiveRepoPath = $null }
    if (-not $State.Metadata.ContainsKey('ActiveIsRemote')) { $State.Metadata.ActiveIsRemote = $false }
    Write-Log 'Opening container manager UI.' 'Info'

    # F84: a running container is found by its NAME only ("<repo>_<user>"), so a second
    # clone with the same folder name somewhere else looked like the same repository, and
    # Stop then copied results and checked git changes in the wrong folder. Start now
    # records the mounted folder in the container label impact.repo_path. This helper
    # returns that folder when it DIFFERS from the selected one and can really be used;
    # otherwise $null, and the selected folder is kept (also for containers started by
    # older versions, which have no such label).
    function Get-DifferentLabelRepoPath {
        param([string]$LabelPath, [string]$SelectedPath)
        if (-not $LabelPath) { return $null }
        if ($State.ContainerLocation -eq 'LOCAL') {
            # Windows paths: compare without caring about upper/lower case or / versus \.
            $labelNorm = ($LabelPath -replace '/', '\').TrimEnd('\')
            $selectedNorm = ("$SelectedPath" -replace '/', '\').TrimEnd('\')
            if ($labelNorm -ieq $selectedNorm) { return $null }
            # Only switch to a folder that exists on this PC. A drive that is not connected
            # (or a wrongly decoded name) must not send Stop to a missing folder.
            if (-not (Test-Path -LiteralPath $LabelPath -PathType Container)) {
                Write-Log "Container label names repository folder '$LabelPath', which does not exist on this PC; keeping '$SelectedPath'." 'Warn'
                return $null
            }
        } elseif ($LabelPath.TrimEnd('/') -ceq "$SelectedPath".TrimEnd('/')) {
            # Linux paths on the workstation are case-sensitive.
            return $null
        }
        return $LabelPath
    }

    $isRunning = $State.Metadata.ContainerRunning
    if (-not $isRunning) {
        # Nothing is running for this repo, so forget the port and volume mode of a
        # container from earlier in this session (for example after Stop and Back),
        # otherwise the info box would show a stale port (F32).
        $State.Metadata.ActivePort = $null
        $State.Metadata.ActiveUseVolumes = $false
    }
    if ($isRunning) {
        $portDisplay = if ($State.Metadata.Recovered.Port) { ($State.Metadata.Recovered.Port -split '\s+')[0] } else { '8787' }
        $passDisplay = if ($State.Metadata.Recovered.Password) { $State.Metadata.Recovered.Password } else { $State.Password }
        $hostDisplay = if ($State.ContainerLocation -eq 'LOCAL') { "http://localhost:$portDisplay" } else { "http://$($State.RemoteHostIp):$portDisplay" }
        $maskedPass = [string]::new([char]0x2022, [Math]::Max($passDisplay.Length, 6))
        [System.Windows.Forms.MessageBox]::Show("Container '$($State.ContainerName)' already running.`n`nURL: $hostDisplay`nUser: rstudio`nPassword: $maskedPass","Container already running",'OK','Information') | Out-Null
        Write-Log "Resumed existing container $($State.ContainerName) at $hostDisplay" 'Info'
        $State.Metadata.ActiveRepoPath = if ($State.ContainerLocation -eq 'LOCAL') { $State.Paths.LocalRepo } else { $State.Paths.RemoteRepo }
        $State.Metadata.ActiveIsRemote = ($State.ContainerLocation -like 'REMOTE@*')
        # F84: which folder does the running container really use? Get-ContainerStatus may
        # already have read the label into Recovered.RepoPath; if it did not collect that
        # key at all, ask the container directly (one extra 'docker inspect').
        $labelRepoPath = $null
        if ($State.Metadata.Recovered.ContainsKey('RepoPath')) {
            $labelRepoPath = $State.Metadata.Recovered['RepoPath']
        } else {
            try { $labelRepoPath = (Get-ContainerRuntimeInfo -State $State).RepoPath } catch { $labelRepoPath = $null }
        }
        $otherRepoPath = Get-DifferentLabelRepoPath -LabelPath $labelRepoPath -SelectedPath $State.Metadata.ActiveRepoPath
        if ($otherRepoPath) {
            Write-Log "Running container '$($State.ContainerName)' uses repository folder '$otherRepoPath', not the selected '$($State.Metadata.ActiveRepoPath)'." 'Warn'
            [System.Windows.Forms.MessageBox]::Show("The running container '$($State.ContainerName)' was started from a DIFFERENT folder than the one you selected (both folders have the same name):`n`n  Container uses:`n  $otherRepoPath`n`n  You selected:`n  $($State.Metadata.ActiveRepoPath)`n`nWhen you click Stop, IMPACT copies results and checks git changes in the folder the container really uses (the first one).",'Different repository folder','OK','Warning') | Out-Null
            $State.Metadata.ActiveRepoPath = $otherRepoPath
        }
        $State.Metadata.ActiveUseVolumes = [bool]$State.Metadata.Recovered.UseVolumes
        $State.Metadata.ActivePort = $portDisplay
        # Restore the result folders recorded on the container (labels). Without them
        # Stop cannot copy results out of the volumes (F01). They stay $null for
        # containers started by older versions; Stop then keeps the volumes and says so.
        $State.Paths.OutputDir = $State.Metadata.Recovered.OutputDir
        $State.Paths.SynthpopDir = $State.Metadata.Recovered.SynthpopDir
        if ($State.Metadata.Recovered.UseVolumes) {
            # Prefer the volume names the container really mounts (read with docker inspect),
            # so containers started by an older version (other naming) are handled too.
            # The computed names are only a fallback.
            $fallbackNames = Get-ImpactVolumeNames -ContainerName $State.ContainerName
            $State.Metadata.VolumeOutput = if ($State.Metadata.Recovered.VolumeOutput) { $State.Metadata.Recovered.VolumeOutput } else { $fallbackNames.Output }
            $State.Metadata.VolumeSynthpop = if ($State.Metadata.Recovered.VolumeSynthpop) { $State.Metadata.Recovered.VolumeSynthpop } else { $fallbackNames.Synthpop }
        }
    }

    $form = New-Object System.Windows.Forms.Form -Property @{
        Text = 'Container Management - IMPACT NCD Germany'
        Size = New-Object System.Drawing.Size(540,510)
        FormBorderStyle = 'FixedDialog'
        MaximizeBox = $false
    }
    Set-FormCenterOnCurrentScreen -Form $form
    Apply-ThemeToForm -Form $form

    $info = New-Object System.Windows.Forms.RichTextBox -Property @{
        Location = New-Object System.Drawing.Point(12,12)
        Size = New-Object System.Drawing.Size(500,148)
        ReadOnly = $true
        BorderStyle = 'None'
        BackColor = $form.BackColor
    }
    Style-InfoBox -Box $info
    $form.Controls.Add($info)

    $btnStart = New-Object System.Windows.Forms.Button -Property @{ Text='Start Container'; Location=New-Object System.Drawing.Point(90,170); Size=New-Object System.Drawing.Size(150,42); Enabled = -not $isRunning }
    $btnStop  = New-Object System.Windows.Forms.Button -Property @{ Text='Stop Container';  Location=New-Object System.Drawing.Point(280,170); Size=New-Object System.Drawing.Size(150,42); Enabled = $isRunning }
    Style-Button -Button $btnStart -Variant 'primary'
    Style-Button -Button $btnStop -Variant 'danger'
    $form.Controls.Add($btnStart)
    $form.Controls.Add($btnStop)

    $labelAdv = New-Object System.Windows.Forms.Label -Property @{ Text='Advanced Options'; Location=New-Object System.Drawing.Point(12,220); Size=New-Object System.Drawing.Size(300,22) }
    Style-Label -Label $labelAdv -Style ([System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($labelAdv)

    $chkVolumes = New-Object System.Windows.Forms.CheckBox -Property @{ Text='Use Docker Volumes'; Location=New-Object System.Drawing.Point(20,246); Size=New-Object System.Drawing.Size(200,22); Checked = [bool]$State.Metadata.Recovered.UseVolumes }
    $chkRebuild = New-Object System.Windows.Forms.CheckBox -Property @{ Text='Rebuild image'; Location=New-Object System.Drawing.Point(240,246); Size=New-Object System.Drawing.Size(150,22) }
    $chkHigh    = New-Object System.Windows.Forms.CheckBox -Property @{ Text='High computational demand'; Location=New-Object System.Drawing.Point(20,272); Size=New-Object System.Drawing.Size(240,22) }
    Style-CheckBox -CheckBox $chkVolumes
    Style-CheckBox -CheckBox $chkRebuild
    Style-CheckBox -CheckBox $chkHigh
    $form.Controls.Add($chkVolumes)
    $form.Controls.Add($chkRebuild)
    $form.Controls.Add($chkHigh)

    # F85: the password in the info box is hidden by default, so it is not exposed when
    # the screen is shared. This box reveals it when the user needs to read it.
    # $uiState is a hashtable so the event handlers below can change it (a plain
    # variable assigned inside a handler would only change a local copy).
    $uiState = @{ ShowPassword = $false; Status = 'STOPPED' }
    $chkShowPass = New-Object System.Windows.Forms.CheckBox -Property @{ Text='Show password'; Location=New-Object System.Drawing.Point(300,272); Size=New-Object System.Drawing.Size(200,22) }
    Style-CheckBox -CheckBox $chkShowPass
    $form.Controls.Add($chkShowPass)

    $lblPort = New-Object System.Windows.Forms.Label -Property @{ Text='Port (8787-8799)'; Location=New-Object System.Drawing.Point(20,304); Size=New-Object System.Drawing.Size(110,22) }
    $defaultPort = if ($State.Metadata.Recovered.Port) { $State.Metadata.Recovered.Port } else { Get-NextAvailablePort -UsedPorts $State.Ports.Used }
    $txtPort = New-Object System.Windows.Forms.TextBox -Property @{ Location=New-Object System.Drawing.Point(136,302); Size=New-Object System.Drawing.Size(90,24); Text=$defaultPort }
    Style-Label -Label $lblPort
    Style-TextBox -TextBox $txtPort
    $toolTip = New-Object System.Windows.Forms.ToolTip
    $toolTip.SetToolTip($txtPort, 'RStudio Server port. Valid range: 8787-8799.')
    $lblPortError = New-Object System.Windows.Forms.Label -Property @{ Text=''; Location=New-Object System.Drawing.Point(136,326); Size=New-Object System.Drawing.Size(200,14) }
    $lblPortError.ForeColor = [System.Drawing.Color]::FromArgb(200,70,70)
    $lblPortError.Font = New-Object System.Drawing.Font('Segoe UI',8,[System.Drawing.FontStyle]::Regular)
    $form.Controls.Add($lblPort); $form.Controls.Add($txtPort); $form.Controls.Add($lblPortError)
    $txtPort.Add_TextChanged({
        $result = Test-PortValue -Port $txtPort.Text.Trim()
        if ($result.Valid) {
            $lblPortError.Text = ''
            $txtPort.BackColor = (Get-ThemePalette).Field
        } else {
            $lblPortError.Text = $result.ErrorMessage
            $txtPort.BackColor = [System.Drawing.Color]::FromArgb(60,30,30)
        }
    })

    $isLocal = ($State.ContainerLocation -eq 'LOCAL')
    if ($isLocal) {
        $chkHigh.Enabled = $false
    }

    $lblParams = New-Object System.Windows.Forms.Label -Property @{ Text='Custom Params'; Location=New-Object System.Drawing.Point(238,304); Size=New-Object System.Drawing.Size(110,22) }
    $txtParams = New-Object System.Windows.Forms.TextBox -Property @{ Location=New-Object System.Drawing.Point(354,302); Size=New-Object System.Drawing.Size(150,24) }
    Style-Label -Label $lblParams
    Style-TextBox -TextBox $txtParams
    $form.Controls.Add($lblParams); $form.Controls.Add($txtParams)

    $defaultYaml = if ($isLocal) { '.\inputs\sim_design_local.yaml' } else { '.\inputs\sim_design.yaml' }
    $lblYaml = New-Object System.Windows.Forms.Label -Property @{ Text='sim_design.yaml'; Location=New-Object System.Drawing.Point(20,344); Size=New-Object System.Drawing.Size(130,22) }
    $txtYaml = New-Object System.Windows.Forms.TextBox -Property @{ Location=New-Object System.Drawing.Point(152,342); Size=New-Object System.Drawing.Size(352,24); Text=$defaultYaml }
    Style-Label -Label $lblYaml
    Style-TextBox -TextBox $txtYaml
    $form.Controls.Add($lblYaml); $form.Controls.Add($txtYaml)

    $lblStatus = New-Object System.Windows.Forms.Label -Property @{ Text=''; Location=New-Object System.Drawing.Point(20,418); Size=New-Object System.Drawing.Size(460,26) }
    Style-Label -Label $lblStatus
    $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
    $form.Controls.Add($lblStatus)

    $buildInfo = $State.Metadata.BuildInfo
    $footerText = if ($buildInfo) { "Build: $($buildInfo.Version) | Commit: $($buildInfo.Commit) | Built: $($buildInfo.Built)" } else { 'Build: unknown' }
    $lblFooter = New-Object System.Windows.Forms.Label -Property @{ Text=$footerText; Location=New-Object System.Drawing.Point(20,448); Size=New-Object System.Drawing.Size(460,22) }
    Style-Label -Label $lblFooter -Muted:$true
    $form.Controls.Add($lblFooter)

    $btnBack = New-Object System.Windows.Forms.Button -Property @{ Text=[char]0x2190 + ' Back'; Location=New-Object System.Drawing.Point(12,382); Size=New-Object System.Drawing.Size(100,34) }
    Style-Button -Button $btnBack -Variant 'secondary'
    $form.Controls.Add($btnBack)

    $btnClose = New-Object System.Windows.Forms.Button -Property @{ Text='Close'; Location=New-Object System.Drawing.Point(414,382); Size=New-Object System.Drawing.Size(90,34) }
    Style-Button -Button $btnClose -Variant 'secondary'
    $form.Controls.Add($btnClose)
    $form.CancelButton = $btnClose

    $btnBack.Add_Click({
        if ($State.Metadata.ContainerRunning) {
            # F18: if the container already ended on its own, Stop now detects that, copies
            # results out of any Docker volumes and resets this flag, so point the user there.
            [System.Windows.Forms.MessageBox]::Show("Please click 'Stop Container' before going back.`n`n(If the container already ended on its own, Stop tidies up and copies any results back.)",'Container running','OK','Warning') | Out-Null
            return
        }
        $form.Tag = 'back'
        $form.Close()
    })

    $form.Add_FormClosing({
        # While a long step is running (see Set-ManagerBusy below), closing the window would
        # abandon that step halfway, so we refuse and explain instead. The ['Busy'] index form
        # is used because it simply returns $null when the key was never set; reading a missing
        # key with .Busy would throw under StrictMode.
        if ($State.Metadata['Busy']) {
            [System.Windows.Forms.MessageBox]::Show("Please wait: a long task (for example building the Docker image) is still running.`n`nIts progress is shown in the console window. You can close this window once it has finished.",'Please wait','OK','Information') | Out-Null
            $_.Cancel = $true
            return
        }
        if ($State.Metadata.ContainerRunning) {
            if ($form.Tag -ne 'back') {
                $closeMsg = 'A container is still running. Close without stopping?'
                # F04: in volume mode the results live only inside the Docker volumes until
                # Stop copies them back, so say that clearly before the window goes away.
                if ($State.Metadata['ActiveUseVolumes']) {
                    $closeMsg += "`n`nYour results stay inside Docker volumes until you reopen IMPACT and click Stop."
                }
                $answer = [System.Windows.Forms.MessageBox]::Show($closeMsg,'Container running','YesNo','Warning')
                if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { $_.Cancel = $true }
            }
        }
    })

    # Busy mode for long steps such as 'docker build'. These steps run on the window's own
    # thread, so the window cannot react until they finish (Windows may even show it as
    # "Not Responding"). To make that clear and safe, busy mode:
    #   - disables the Start, Stop, Back and Close buttons,
    #   - shows a short status text and the wait cursor,
    #   - sets $State.Metadata.Busy, so FormClosing (above) refuses to close the window.
    # Usage: Set-ManagerBusy -Busy $true -Message '...' before the step, and
    #        Set-ManagerBusy -Busy $false inside a 'finally' block after it, so the buttons
    #        come back even when the step fails or returns early.
    # We deliberately do NOT call [System.Windows.Forms.Application]::DoEvents(): it would let
    # other clicks (Stop, Back, Close) run in the middle of the step.
    function Set-ManagerBusy {
        param([bool]$Busy, [string]$Message = '')
        if ($Busy) {
            if (-not $State.Metadata['Busy']) {
                # Remember which buttons were usable, so exactly that state can be restored.
                $State.Metadata.BusyButtonState = @{ Start = $btnStart.Enabled; Stop = $btnStop.Enabled; Back = $btnBack.Enabled; Close = $btnClose.Enabled }
            }
            $State.Metadata.Busy = $true
            $btnStart.Enabled = $false
            $btnStop.Enabled  = $false
            $btnBack.Enabled  = $false
            $btnClose.Enabled = $false
            $lblStatus.Text = $Message
            $form.UseWaitCursor = $true
            [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
            # Repaint right now: the thread is about to be blocked, and without this the new text
            # and the greyed-out buttons would only appear after the step is over.
            $form.Refresh()
        } else {
            $State.Metadata.Busy = $false
            $saved = $State.Metadata['BusyButtonState']
            if ($saved) {
                $btnStart.Enabled = $saved.Start
                $btnStop.Enabled  = $saved.Stop
                $btnBack.Enabled  = $saved.Back
                $btnClose.Enabled = $saved.Close
                $State.Metadata.BusyButtonState = $null
            }
            $lblStatus.Text = $Message
            $form.UseWaitCursor = $false
            [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
        }
    }

    function Update-InfoBox {
        param($Status)
        $info.Clear()
        $palette = Get-ThemePalette
        # Remember the status so the 'Show password' box can redraw the same view.
        $uiState.Status = $Status

        $passDisplay = if ($State.Metadata.Recovered.Password) { $State.Metadata.Recovered.Password } else { $State.Password }
        if (-not $uiState.ShowPassword) {
            # Fixed number of dots, so not even the password length is shown.
            $passDisplay = ([string]::new([char]0x2022, 8)) + "   (tick 'Show password' to see it)"
        }
        $portDisplay = if ($State.Metadata.ActivePort) { $State.Metadata.ActivePort } elseif ($State.Metadata.Recovered.Port) { ($State.Metadata.Recovered.Port -split '\s+')[0] } else { '8787' }
        $hostDisplay = if ($State.ContainerLocation -eq 'LOCAL') { "http://localhost:$portDisplay" } else { "http://$($State.RemoteHostIp):$portDisplay" }

        # Status indicator — large and prominent
        $info.SelectionFont = New-Object System.Drawing.Font('Segoe UI Semibold',11,[System.Drawing.FontStyle]::Bold)
        if ($Status -eq 'RUNNING') {
            $info.SelectionColor = $palette.Success
            $info.AppendText("$([char]0x25CF)  RUNNING`n")
        } elseif ($Status -eq 'UNKNOWN') {
            # F34: Docker could not be asked, so we really do not know whether the container
            # runs. Showing STOPPED here used to make a running container look stopped.
            $info.SelectionColor = $palette.Danger
            $info.AppendText("$([char]0x25CB)  UNKNOWN (Docker not reachable)`n")
        } else {
            $info.SelectionColor = $palette.AccentAlt
            $info.AppendText("$([char]0x25CB)  STOPPED`n")
        }

        # Section separator
        $info.SelectionFont = New-Object System.Drawing.Font('Segoe UI',4,[System.Drawing.FontStyle]::Regular)
        $info.AppendText("`n")

        # Reusable fonts
        $labelFont = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Regular)
        $bodyFont  = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Regular)

        # Connection info
        $info.SelectionFont = $labelFont; $info.SelectionColor = $palette.Accent
        $info.AppendText("  URL          ")
        $info.SelectionFont = $bodyFont;  $info.SelectionColor = $palette.Text
        $info.AppendText("$hostDisplay`n")

        $info.SelectionFont = $labelFont; $info.SelectionColor = $palette.Accent
        $info.AppendText("  Login        ")
        $info.SelectionFont = $bodyFont;  $info.SelectionColor = $palette.Text
        $info.AppendText("rstudio`n")

        $info.SelectionFont = $labelFont; $info.SelectionColor = $palette.Accent
        $info.AppendText("  Password     ")
        $info.SelectionFont = $bodyFont;  $info.SelectionColor = $palette.Text
        $info.AppendText("$passDisplay`n")

        # Section separator
        $info.SelectionFont = New-Object System.Drawing.Font('Segoe UI',4,[System.Drawing.FontStyle]::Regular)
        $info.AppendText("`n")

        # Project info
        $info.SelectionFont = $labelFont; $info.SelectionColor = $palette.Accent
        $info.AppendText("  Repository   ")
        $info.SelectionFont = $bodyFont;  $info.SelectionColor = $palette.Text
        $info.AppendText("$($State.SelectedRepo)`n")

        $info.SelectionFont = $labelFont; $info.SelectionColor = $palette.Muted
        $info.AppendText("  Container    ")
        $info.SelectionFont = $bodyFont;  $info.SelectionColor = $palette.Muted
        $info.AppendText("$($State.ContainerName)`n")

        $info.SelectionFont = $labelFont; $info.SelectionColor = $palette.Accent
        $info.AppendText("  Location     ")
        $info.SelectionFont = $bodyFont;  $info.SelectionColor = $palette.Text
        $info.AppendText("$($State.ContainerLocation)`n")
    }
    # Get-ContainerStatus sets DockerReachable; $false means the user clicked Cancel in its
    # 'Docker Not Reachable' box. ['DockerReachable'] returns $null (not an error under
    # StrictMode) if the key was never set.
    $dockerUnreachable = ($State.Metadata['DockerReachable'] -eq $false)
    Update-InfoBox -Status ($(if($isRunning){'RUNNING'}elseif($dockerUnreachable){'UNKNOWN'}else{'STOPPED'}))
    $lblStatus.Text = ''
    if ($dockerUnreachable -and -not $isRunning) {
        $lblStatus.Text = 'Docker could not be reached. Click Back and continue again to check again.'
    } elseif (-not $isRunning) {
        # B3-R1: results of an earlier volume-mode session may still sit in Docker volumes
        # (after a crash, a reboot or a failed Stop). Tick 'Use Docker Volumes' and say so;
        # Start then offers to copy them back. One quick 'docker volume ls' is enough for
        # this hint, Start checks the volumes properly before it changes anything.
        try {
            $hintNames = Get-ImpactVolumeNames -ContainerName $State.ContainerName
            $hintCtx = Get-DockerContextArgs -State $State
            $existingVolumes = @(& docker @hintCtx volume ls --format '{{.Name}}' 2>$null)
            if ($LASTEXITCODE -eq 0 -and ($existingVolumes -contains $hintNames.Output -or $existingVolumes -contains $hintNames.Synthpop)) {
                Write-Log "Docker volumes from an earlier session of $($State.ContainerName) still exist." 'Warn'
                $chkVolumes.Checked = $true
                $lblStatus.Text = 'Results from an earlier session are still in Docker volumes. Click Start to copy them back.'
            }
        } catch {
            Write-Log "Leftover volume check failed (continuing): $($_.Exception.Message)" 'Debug'
        }
        # F93: Get-NextAvailablePort returns the first port even when every port is taken, so
        # the Port box alone does not show that nothing is free. Say it here.
        if (@($State.Ports.Used) -contains [string]$defaultPort) {
            $lblStatus.Text = 'All RStudio ports (8787-8799) are in use. Stop another container before you click Start.'
        }
    }

    $chkShowPass.Add_CheckedChanged({
        $uiState.ShowPassword = $chkShowPass.Checked
        Update-InfoBox -Status $uiState.Status
    })

    # The code of the Start button. It is kept in a variable (instead of directly inside
    # $btnStart.Add_Click) so that Invoke-ManagerButtonAction, further below, can run it
    # inside a safety net that turns an unexpected error into a friendly message (B4-R5).
    $startClickBody = {
        $useVolumes = $chkVolumes.Checked
        $rebuild    = $chkRebuild.Checked
        $highComp   = $chkHigh.Checked
        $portOverride = $txtPort.Text.Trim()
        $customParams = $txtParams.Text.Trim()
        $simDesign = $txtYaml.Text.Trim()

        Write-Log ("Start clicked with options -> volumes={0} rebuild={1} highComp={2} port={3} params='{4}' yaml='{5}'" -f $useVolumes,$rebuild,$highComp,$portOverride,$customParams,$simDesign) 'Debug'

        Set-DockerSSHEnvironment -State $State

        if ($State.Metadata.ContainerRunning) {
            [System.Windows.Forms.MessageBox]::Show('Container already running; stop it first or close to reuse.','Already running','OK','Information') | Out-Null
            return
        }

        # Validate port format and range
        $portCheck = Test-PortValue -Port $portOverride
        if (-not $portCheck.Valid) {
            [System.Windows.Forms.MessageBox]::Show($portCheck.ErrorMessage, 'Invalid port', 'OK', 'Error') | Out-Null
            return
        }

        # Ask Docker NOW instead of trusting lists collected when this window opened, which
        # may be minutes or hours old (F18/F39/F34). This one 'docker ps' tells us:
        #  - whether Docker answers at all (Docker Desktop stopped, or the network/VPN to the
        #    workstation dropped). Before, a failing check simply looked like "image missing"
        #    and started a long image build that could only fail;
        #  - whether our container is running after all (for example started from another
        #    IMPACT window or another PC);
        #  - which ports are in use right now, and which other containers of this user run.
        $ctxStart = Get-DockerContextArgs -State $State
        $psNowRaw = & docker @ctxStart ps --format '{{.Names}}\t{{.Ports}}' 2>&1
        $psNowExit = $LASTEXITCODE
        if ($psNowExit -ne 0) {
            $psNowError = ((@($psNowRaw) | ForEach-Object { "$_" }) -join "`n").Trim()
            Write-Log "Start: Docker is not reachable (exit $psNowExit): $psNowError" 'Warn'
            $State.Metadata.DockerReachable = $false
            Update-InfoBox -Status 'UNKNOWN'
            $dockerFix = if ($State.ContainerLocation -eq 'LOCAL') { 'Start Docker Desktop and wait until it reports that the engine is running, then click Start again.' } else { "Check your network or VPN connection to the workstation ($($State.RemoteHostIp)), then click Start again." }
            [System.Windows.Forms.MessageBox]::Show("Docker is not reachable, so the container cannot be started.`n`n$dockerFix",'Docker not reachable','OK','Warning') | Out-Null
            return
        }
        $State.Metadata.DockerReachable = $true
        $runningNow = @()
        $freshUsedPorts = @()
        foreach ($psLine in @($psNowRaw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })) {
            $psParts = @($psLine -split "`t", 2)
            if ($psParts[0].Trim()) { $runningNow += $psParts[0].Trim() }
            if ($psParts.Count -ge 2) {
                # Same pattern as Get-UsedPorts in the module (any host address, F13).
                foreach ($m in [regex]::Matches($psParts[1], ':(\d{4,5})->8787/tcp')) {
                    if ($freshUsedPorts -notcontains $m.Groups[1].Value) { $freshUsedPorts += $m.Groups[1].Value }
                }
            }
        }
        $State.Ports.Used = $freshUsedPorts

        if ($runningNow -contains $State.ContainerName) {
            [System.Windows.Forms.MessageBox]::Show("A container named '$($State.ContainerName)' is already running (perhaps started from another IMPACT window or on another PC).`n`nClick Back and continue again: IMPACT then connects to the running container.",'Already running','OK','Information') | Out-Null
            return
        }
        if ($uiState.Status -eq 'UNKNOWN') {
            # Docker answers again and our container is not running, so STOPPED is now known.
            Update-InfoBox -Status 'STOPPED'
            $lblStatus.Text = ''
        }

        # F93: Get-NextAvailablePort returns the first port of the range even when every port
        # is taken, so check that case and explain it instead of a plain "port conflict".
        $freePort = Get-NextAvailablePort -UsedPorts $freshUsedPorts
        if ($freshUsedPorts -contains $freePort) {
            $portWhere = if ($State.ContainerLocation -eq 'LOCAL') { 'on this computer' } else { 'on the workstation' }
            [System.Windows.Forms.MessageBox]::Show("All RStudio ports (8787-8799) are already in use by other containers $portWhere.`n`nStop one of them (or ask a colleague to stop theirs), then click Start again.",'No free port','OK','Warning') | Out-Null
            return
        }
        if ($freshUsedPorts -contains $portOverride) {
            # Enter a free port for the user, so a second click on Start simply works.
            $txtPort.Text = $freePort
            [System.Windows.Forms.MessageBox]::Show("Port $portOverride is already in use by another container.`n`nPort $freePort is free and has been entered in the Port box. Click Start again to use it.", 'Port conflict', 'OK', 'Warning') | Out-Null
            return
        }

        if ($State.ContainerLocation -like 'REMOTE@*') {
            if (-not (Test-RemoteSSHKeyFiles -State $State)) {
                [System.Windows.Forms.MessageBox]::Show($(if ($State.Metadata['RemoteSshCheckMessage']) { $State.Metadata['RemoteSshCheckMessage'] } else { 'Your SSH key was not found on the workstation. Close IMPACT and start it again to set it up.' }), 'SSH problem', 'OK', 'Error') | Out-Null  # message explains the real cause (VPN, key missing, ...), set by Test-RemoteSSHKeyFiles
                return
            }
        }

        # This user's other running containers, from the fresh 'docker ps' above (names end
        # with "_<user>", see Get-ContainerStatus). @() keeps .Count safe under StrictMode.
        $userSuffix = "_$($State.UserName)"
        $otherRunning = @($runningNow | Where-Object { $_ -ne $State.ContainerName -and $_.EndsWith($userSuffix, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($otherRunning.Count -gt 0) {
            $names = $otherRunning -join ', '
            $choice = [System.Windows.Forms.MessageBox]::Show("Other containers are running: $names`nContinue starting another?",'Other containers running','YesNo','Warning')
            if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        $projectRoot = if ($State.ContainerLocation -eq 'LOCAL') { $State.Paths.LocalRepo } else { $State.Paths.RemoteRepo }
        if (-not $projectRoot) { [System.Windows.Forms.MessageBox]::Show('Repository path missing; restart and select again.','Missing path','OK','Error') | Out-Null; return }
        $dockerSetup = if ($State.ContainerLocation -eq 'LOCAL') { Join-Path $projectRoot 'docker_setup' } else { "$projectRoot/docker_setup" }
        # -LiteralPath (here and below): a folder name such as 'IMPACTncd_Germany [v2]'
        # contains [ ], which -Path reads as a wildcard pattern, so existing files and
        # folders were reported as missing (B2-R3).
        if ($State.ContainerLocation -eq 'LOCAL' -and -not (Test-Path -LiteralPath $dockerSetup)) {
            [System.Windows.Forms.MessageBox]::Show("docker_setup folder not found at $dockerSetup","Missing docker_setup",'OK','Error') | Out-Null; return
        }

        # resolve sim_design.yaml
        if (-not [System.IO.Path]::IsPathRooted($simDesign)) {
            $simDesign = ($projectRoot.TrimEnd('/','\') + '/' + ($simDesign -replace '\\','/')) -replace '/+','/'
            if ($State.ContainerLocation -eq 'LOCAL') {
                $resolved = Resolve-Path -LiteralPath $simDesign -ErrorAction SilentlyContinue
                if ($resolved) { $simDesign = $resolved.Path }
            }
        }
        if ($State.ContainerLocation -eq 'LOCAL' -and -not (Test-Path -LiteralPath $simDesign)) {
            [System.Windows.Forms.MessageBox]::Show("YAML file not found at $simDesign",'Missing YAML','OK','Error') | Out-Null; return
        }
        if ($State.ContainerLocation -like 'REMOTE@*') {
            # Same check for the workstation: Test-Path above cannot see files there, so we ask
            # over SSH. It runs before any image build, so a mistyped YAML name is reported in
            # seconds instead of after a long build. The two marker words let us tell
            # "file missing" apart from "connection failed" (which prints nothing at all).
            $yamlCheck = $null
            try {
                $yamlHost = Get-RemoteHostString -State $State
                # ConvertTo-PosixShellLiteral quotes the path safely for the workstation's shell
                # (a ' in the path broke the old '...' quoting, B4-R7).
                $simDesignQ = ConvertTo-PosixShellLiteral -Value $simDesign
                $yamlCheck = & ssh -n -i $State.Paths.SshPrivate -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes $yamlHost "test -f $simDesignQ && echo YAML_OK || echo YAML_MISSING" 2>$null
            } catch {
                Write-Log "Remote YAML check failed: $($_.Exception.Message)" 'Warn'
            }
            if ("$yamlCheck" -match 'YAML_MISSING') {
                [System.Windows.Forms.MessageBox]::Show("YAML file not found on the workstation at:`n$simDesign`n`nCheck the file name in the 'sim_design.yaml' box.",'Missing YAML','OK','Error') | Out-Null; return
            }
            if ("$yamlCheck" -notmatch 'YAML_OK') {
                [System.Windows.Forms.MessageBox]::Show("Could not reach the workstation to check the YAML file:`n$simDesign`n`nCheck your network or VPN connection and try again.",'Connection problem','OK','Error') | Out-Null; return
            }
        }

        # Resolve output/synthpop from sim_design and check that both folders exist.
        # This used to run after the image build; it now runs before it, so a missing folder or
        # YAML setting is reported in seconds instead of after a build that can take an hour.
        $baseDirForYaml = ($projectRoot -replace '\\','/')
        $outputDir = Get-YamlPathValue -State $State -YamlPath $simDesign -Key 'output_dir' -BaseDir $baseDirForYaml
        $synthDir  = Get-YamlPathValue -State $State -YamlPath $simDesign -Key 'synthpop_dir' -BaseDir $baseDirForYaml

        # Checks one folder from the YAML and, when something is wrong, explains exactly what
        # (instead of one generic "check your YAML" message). If the folder is simply missing,
        # which is normal for a fresh copy of the repository, it offers to create it.
        # Returns $true when the folder exists (or was just created), $false to stop Start.
        function Confirm-YamlFolder {
            param([string]$Key, [string]$Path)
            $isRemote = ($State.ContainerLocation -like 'REMOTE@*')
            if (-not $Path) {
                $hint = if ($isRemote) { "`n`n(If the workstation connection dropped, simply try again.)" } else { '' }
                # A fitting example per setting (B4-R4): suggesting ./outputs for synthpop_dir
                # would mix the synthetic population with the results.
                $example = if ($Key -eq 'synthpop_dir') { './inputs/synthpop' } else { './outputs' }
                [System.Windows.Forms.MessageBox]::Show("The setting '$Key' was not found (or is empty) in the YAML file:`n$simDesign`n`nAdd a line such as '${Key}: $example' to that file and try again.$hint",'Setting missing in YAML','OK','Error') | Out-Null
                return $false
            }
            $why = $null
            if (Test-AndCreateDirectory -State $State -Path $Path -PathKey $Key -Reason ([ref]$why)) { return $true }
            switch ($why) {
                'NetworkPathInLocalMode' {
                    # F36: Docker Desktop cannot mount network folders; without this check the
                    # start failed only at 'docker run', after the (possibly long) image build.
                    [System.Windows.Forms.MessageBox]::Show("The setting '$Key' in`n$simDesign`npoints to a network folder:`n$Path`n`nDocker Desktop cannot use network folders (\\server\... or a mapped network drive). Use a folder on a local drive of this computer, for example a folder inside the repository.",'Network Folder Not Supported','OK','Error') | Out-Null
                    return $false
                }
                'PosixPathInLocalMode' {
                    [System.Windows.Forms.MessageBox]::Show("The setting '$Key' in`n$simDesign`nuses a Linux-style path:`n$Path`n`nLocal runs need a Windows path, for example ./outputs or C:\IMPACT\outputs. Use sim_design_local.yaml for local runs.",'Path error','OK','Error') | Out-Null
                    return $false
                }
                'Unreachable' {
                    [System.Windows.Forms.MessageBox]::Show("Could not check the folder for '$Key' on the workstation (the SSH connection failed):`n$Path`n`nCheck your network or VPN connection and try again.",'Connection problem','OK','Error') | Out-Null
                    return $false
                }
            }
            # The folder does not exist. Only offer to create it where that is safe: on this PC
            # (the dialog shows the full path, so a typo is visible), or on the workstation when
            # the folder lies inside the repository. Shared storage elsewhere on the workstation
            # (for example /mnt/...) is never created from here: a wrong path there could create
            # a stray folder that other users then see.
            $repoPrefix = ($projectRoot -replace '\\','/').TrimEnd('/') + '/'
            $insideRepo = $Path.StartsWith($repoPrefix) -and $Path -notmatch '/\.\./'
            if ($isRemote -and -not $insideRepo) {
                [System.Windows.Forms.MessageBox]::Show("The folder for '$Key' does not exist on the workstation:`n$Path`n`nIt is outside the repository, so it is not created automatically. Check the path in your YAML file, or ask the workstation administrator.",'Folder missing','OK','Error') | Out-Null
                return $false
            }
            $answer = [System.Windows.Forms.MessageBox]::Show("The folder for '$Key' does not exist yet:`n$Path`n`nThis is normal for a fresh copy of the repository. Create it now?",'Folder missing','YesNo','Question')
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }
            if (Test-AndCreateDirectory -State $State -Path $Path -PathKey $Key -Create) { return $true }
            [System.Windows.Forms.MessageBox]::Show("Could not create the folder for '$Key':`n$Path`n`nCheck that the drive or parent folder exists and that you are allowed to write there.",'Path error','OK','Error') | Out-Null
            return $false
        }
        if (-not (Confirm-YamlFolder -Key 'output_dir' -Path $outputDir)) { return }
        if (-not (Confirm-YamlFolder -Key 'synthpop_dir' -Path $synthDir)) { return }

        # The checks below used to run only AFTER the image build, which can take 30+
        # minutes, so a colleague who then answered No (or was refused) had waited for
        # nothing (B3-R2). They only need the folders resolved above, so they run first now.
        $repoMountSource = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $projectRoot } else { $projectRoot }

        # F12 (partial): warn when another running container already uses this repository
        # folder. On the shared workstation all colleagues work in the SAME checkout, so two
        # containers on one folder mix their edits, git pulls and results, and a commit at
        # Stop would include the other person's changes. We only warn; the user decides.
        # (The 'Other containers are running' check above only sees this user's containers.)
        try {
            $ctxShared = Get-DockerContextArgs -State $State
            $runningIds = @(& docker @ctxShared @('ps','-q') 2>$null | Where-Object { $_ -match '\S' })
            if ($LASTEXITCODE -eq 0 -and $runningIds.Count -gt 0) {
                $mountLines = & docker @ctxShared (@('inspect','-f','{{.Name}}{{range .Mounts}}{{if eq .Type "bind"}}|{{.Source}}{{end}}{{end}}') + $runningIds) 2>$null
                $target = $repoMountSource.TrimEnd('/')
                $sharing = @()
                foreach ($ml in @($mountLines)) {
                    $parts = "$ml" -split '\|'
                    $otherName = $parts[0].Trim().TrimStart('/')
                    if (-not $otherName -or $otherName -eq $State.ContainerName) { continue }
                    foreach ($src in ($parts | Select-Object -Skip 1)) {
                        $s = $src.Trim().TrimEnd('/')
                        # Docker Desktop may report a LOCAL source with a prefix such as
                        # /run/desktop/mnt/host/c/..., so for LOCAL compare the end of the path.
                        $same = if ($State.ContainerLocation -eq 'LOCAL') { $s.EndsWith($target, [System.StringComparison]::OrdinalIgnoreCase) } else { $s -ceq $target }
                        if ($same) { $sharing += $otherName; break }
                    }
                }
                if ($sharing.Count -gt 0) {
                    $msgShared = "Another running container is already using this repository folder:`n`n  $($sharing -join ', ')`n`n$projectRoot`n`nIf you both work in it at the same time, your edits, git pulls and results will mix, and a commit at Stop may include the other person's changes.`n`nStart anyway?"
                    $answerShared = [System.Windows.Forms.MessageBox]::Show($msgShared, 'Repository already in use', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
                    if ($answerShared -ne [System.Windows.Forms.DialogResult]::Yes) { return }
                }
            }
        } catch {
            Write-Log "Shared repository check failed (continuing): $($_.Exception.Message)" 'Debug'
        }

        # F48: names include the container name (repo + user), so two repos no longer share volumes.
        $volNames = Get-ImpactVolumeNames -ContainerName $State.ContainerName
        $volOut = $volNames.Output
        $volSyn = $volNames.Synthpop
        $ctxPrefix = Get-DockerContextArgs -State $State

        # F02: volumes with these names may be left over from an earlier session that was
        # never copied back (crash, reboot, Docker restart, or a failed Stop). They may hold
        # the ONLY copy of results, so never delete them silently: copy them out first, or
        # ask the user.
        # B3-R1: this check now runs in BOTH modes. It used to run only with 'Use Docker
        # Volumes' ticked, and that box starts unticked when nothing is running, so after a
        # crash a plain Start silently ignored the old volumes and wrote new results straight
        # into the same folders. In bind mode the start simply continues without volumes
        # after the copy (or the discard).
        $volPairs = @(
            @{ Name = $volOut; HostDir = $outputDir },
            @{ Name = $volSyn; HostDir = $synthDir }
        )
        $leftovers = @()
        foreach ($vp in $volPairs) {
            $vi = Get-ImpactVolumeInfo -State $State -VolumeName $vp.Name
            if ($null -eq $vi.Exists) {
                [System.Windows.Forms.MessageBox]::Show("Could not check the Docker volume '$($vp.Name)':`n$($vi.Error)`n`nCheck that Docker is running and try again.",'Volume check failed','OK','Error') | Out-Null
                return
            }
            if ($vi.Exists) {
                if ($vi.UsedBy.Count -gt 0) {
                    [System.Windows.Forms.MessageBox]::Show("The Docker volume '$($vp.Name)' is still used by: $($vi.UsedBy -join ', ').`n`nStop or remove that container first.",'Volume in use','OK','Error') | Out-Null
                    return
                }
                # Prefer the folder recorded when the volume was created: the YAML may point
                # somewhere else now.
                $target = if ($vi.TargetDir) { $vi.TargetDir } else { $vp.HostDir }
                $leftovers += [pscustomobject]@{ Name = $vp.Name; Target = $target }
            }
        }
        if ($leftovers.Count -gt 0) {
            $leftList = ($leftovers | ForEach-Object { "  - $($_.Name)`n      -> $($_.Target)" }) -join "`n"
            $leftMsg = "Docker volumes from an earlier session of '$($State.ContainerName)' still exist:`n`n$leftList`n`nThey may contain results that were never copied back (for example after a crash, a reboot or a failed Stop).`n`nYes: copy their contents into the folders shown above, then start (recommended). Files in those folders that are newer than the copy in the volume are kept.`nNo: delete them WITHOUT copying, then start.`nCancel: do nothing."
            $leftChoice = [System.Windows.Forms.MessageBox]::Show($leftMsg, 'Earlier results found', [System.Windows.Forms.MessageBoxButtons]::YesNoCancel, [System.Windows.Forms.MessageBoxIcon]::Warning, [System.Windows.Forms.MessageBoxDefaultButton]::Button1)
            if ($leftChoice -eq [System.Windows.Forms.DialogResult]::Yes) {
                # Copying large results can take a while: busy mode (see Set-ManagerBusy).
                Set-ManagerBusy -Busy $true -Message 'Copying earlier results from the Docker volumes...'
                try {
                    foreach ($lo in $leftovers) {
                        $lblStatus.Text = "Copying earlier results from $($lo.Name)..."
                        $form.Refresh()
                        # -KeepNewerOnHost (B3-R1): files written into the folder AFTER that
                        # earlier session (for example by a run without volumes) are newer and
                        # must not be replaced by the older copy from the volume.
                        $syncLeft = Sync-ImpactVolumeToHost -State $State -VolumeName $lo.Name -HostDir $lo.Target -KeepNewerOnHost
                        if (-not $syncLeft.Success) {
                            [System.Windows.Forms.MessageBox]::Show("$($syncLeft.Message)`n`nNothing was deleted: the volume still holds the data. The container was not started.",'Copy failed','OK','Error') | Out-Null
                            return
                        }
                    }
                } finally {
                    Set-ManagerBusy -Busy $false
                }
            } elseif ($leftChoice -eq [System.Windows.Forms.DialogResult]::No) {
                $confirmDiscard = [System.Windows.Forms.MessageBox]::Show("Really delete these volumes and everything in them? This cannot be undone.`n`n$leftList", 'Delete earlier results?', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
                if ($confirmDiscard -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            } else {
                return
            }
            # Only reached when the copy succeeded or the user explicitly chose to discard.
            $rmLeftOut = & docker @ctxPrefix (@('volume','rm') + @($leftovers | ForEach-Object { $_.Name })) 2>&1
            if ($LASTEXITCODE -ne 0) {
                [System.Windows.Forms.MessageBox]::Show("Could not remove the old Docker volumes:`n$rmLeftOut",'Volume error','OK','Error') | Out-Null
                return
            }
            Write-Log "Removed earlier volumes: $(($leftovers | ForEach-Object { $_.Name }) -join ', ')" 'Info'
        }

        if ($useVolumes) {
            # F17: the rsync-alpine helper is needed to copy results back at Stop. Check that it
            # really exists BEFORE any volume is created; the old code ignored a failed build,
            # so the problem only appeared hours later when Stop could not copy the results.
            Write-Log 'Checking/building rsync-alpine helper image.' 'Debug'
            if (-not (Initialize-RsyncHelperImage -State $State)) {
                [System.Windows.Forms.MessageBox]::Show("The helper image needed for 'Use Docker Volumes' (rsync-alpine) could not be prepared. Usually Docker could not download the small Alpine Linux image (no internet access, a proxy, or a Docker Hub download limit).`n`nUntick 'Use Docker Volumes' to start without volumes, or check the network and try again.",'Volume helper missing','OK','Error') | Out-Null
                return
            }
        }

        # Build image name. ToLowerInvariant, not ToLower: with a Turkish regional format
        # ToLower() turns 'I' into a dotless i, which Docker rejects as an image name (B2-R4).
        $imageName = $State.SelectedRepo.ToLowerInvariant()

        # Check image exists unless rebuild
        $imageExists = $false
        if (-not $rebuild) {
            $imgCmd = (Get-DockerContextArgs -State $State) + @('images','--format','{{.Repository}}')
            # Check the exit code (B4-R3): when 'docker images' itself fails (Docker or the
            # connection to the workstation went away), that used to look like "image
            # missing" and started a full image build that could only fail.
            $imgOut = @(& docker @imgCmd 2>$null)
            $imgExit = $LASTEXITCODE
            if ($imgExit -ne 0) {
                Write-Log "docker images failed (exit $imgExit); not starting a build." 'Warn'
                [System.Windows.Forms.MessageBox]::Show("Docker is not reachable (Docker Desktop on this PC, or Docker on the workstation), so IMPACT cannot check whether the image already exists.`n`nCheck that Docker is running and that the network or VPN connection works, then click Start again.",'Docker not reachable','OK','Error') | Out-Null
                return
            }
            $imageExists = [bool]($imgOut | Where-Object { "$_".Trim() -eq $imageName })
        }

        $dockerfileMain = if ($State.ContainerLocation -eq 'LOCAL') { Join-Path $dockerSetup 'Dockerfile.IMPACTncdGER' } else { "$dockerSetup/Dockerfile.IMPACTncdGER" }
        $dockerContext  = $projectRoot
        if (-not $dockerContext) {
            [System.Windows.Forms.MessageBox]::Show('Repository path missing; cannot build image.','Missing path','OK','Error') | Out-Null
            return
        }

        if (-not $imageExists) {
            Write-Log "Building image $imageName (streaming output)..." 'Info'

            # Wraps one command-line argument in double quotes when needed. Start-Process joins
            # its -ArgumentList items with plain spaces and adds no quotes, so an item containing
            # a space (for example a key file under 'C:\Users\Max Mustermann\.ssh') used to reach
            # ssh as two separate arguments, and the build failed. This follows the standard
            # Windows rules: a " inside becomes \" and backslashes right before a " are doubled.
            function ConvertTo-QuotedArgument {
                param([string]$Value)
                if ($Value -and $Value -notmatch '[\s"]') { return $Value }
                $escaped = $Value -replace '(\\*)"', '$1$1\"'
                $escaped = $escaped -replace '(\\+)$', '$1$1'
                return '"' + $escaped + '"'
            }

            # Runs one 'docker build' and returns $true when it succeeded. LOCAL builds run docker
            # on this PC from inside the build context folder; REMOTE builds run docker on the
            # workstation over SSH. Start-Process -NoNewWindow is kept (instead of '& docker')
            # because it streams the build log live into the console window, which is where the
            # user can follow the progress. One helper replaces four copies of the same code.
            # -NoCache $false lets a RETRY reuse the layers that the failed attempt built a few
            # minutes earlier, instead of starting from zero again (B4-R2).
            function Invoke-StartImageBuild {
                param([string]$Dockerfile, [string]$Tag, [string]$Context, [bool]$WithRepoArg, [bool]$NoCache = $true)
                try {
                    if ($State.ContainerLocation -eq 'LOCAL') {
                        # '--context local' (from Get-DockerContextArgs) builds on the SAME Docker
                        # engine that the image check and 'docker run' use. Without it the build
                        # went to the global (or DOCKER_CONTEXT) engine, so the image could be
                        # built where it was not looked for, and every Start rebuilt it (B4-R8).
                        $buildArgs = @(Get-DockerContextArgs -State $State) + @('build')
                        if ($WithRepoArg) { $buildArgs += @('--build-arg', "REPO_NAME=$($State.SelectedRepo)") }
                        $buildArgs += @('-f', $Dockerfile, '-t', $Tag)
                        if ($NoCache) { $buildArgs += '--no-cache' }
                        $buildArgs += @('--progress=plain', '.')
                        $argString = ($buildArgs | ForEach-Object { ConvertTo-QuotedArgument $_ }) -join ' '
                        # -LiteralPath: brackets in a folder name are not wildcards (B2-R3).
                        Push-Location -LiteralPath $Context
                        try {
                            $p = Start-Process -FilePath 'docker' -ArgumentList $argString -Wait -PassThru -NoNewWindow
                            return ($p.ExitCode -eq 0)
                        } finally { Pop-Location }
                    }
                    # Every value is quoted for the workstation's shell with ConvertTo-PosixShellLiteral
                    # (B4-R7). REPO_NAME used to be unquoted, so a name with a space was split by the shell.
                    $repoArg = if ($WithRepoArg) { "--build-arg $(ConvertTo-PosixShellLiteral -Value "REPO_NAME=$($State.SelectedRepo)") " } else { '' }
                    $cacheArg = if ($NoCache) { ' --no-cache' } else { '' }
                    $cmd = "cd $(ConvertTo-PosixShellLiteral -Value $Context) && docker build $($repoArg)-f $(ConvertTo-PosixShellLiteral -Value $Dockerfile) -t $(ConvertTo-PosixShellLiteral -Value $Tag)$cacheArg ."
                    $sshArgs = @('-o','StrictHostKeyChecking=accept-new','-o','ConnectTimeout=30','-o','BatchMode=yes','-o','PasswordAuthentication=no','-o','PubkeyAuthentication=yes','-o','IdentitiesOnly=yes','-i',$State.Paths.SshPrivate,(Get-RemoteHostString -State $State),$cmd)
                    $argString = ($sshArgs | ForEach-Object { ConvertTo-QuotedArgument $_ }) -join ' '
                    $p = Start-Process -FilePath 'ssh' -ArgumentList $argString -Wait -NoNewWindow -PassThru
                    return ($p.ExitCode -eq 0)
                } catch {
                    Write-Log "Could not run docker build: $($_.Exception.Message)" 'Warn'
                    return $false
                }
            }

            $buildSucceeded = $false
            $buildStart = Get-Date
            # A build can take a long time and blocks this window meanwhile, so switch to busy
            # mode (buttons disabled, status text, wait cursor, closing refused). The 'finally'
            # below always switches it off again, also on the early 'return' paths.
            Set-ManagerBusy -Busy $true -Message 'Building the Docker image (30+ min). Progress: see the console window.'
            try {
                $buildSucceeded = Invoke-StartImageBuild -Dockerfile $dockerfileMain -Tag $imageName -Context $dockerContext -WithRepoArg $true

                if (-not $buildSucceeded -and $State.ContainerLocation -like 'REMOTE@*') {
                    # REMOTE build failed: try an automatic docker login from the repo .env and
                    # retry once. This used to be guarded by $State.Metadata.RemoteLoginAttempted,
                    # but that key was never created, and reading a missing key crashes under
                    # StrictMode, so this whole recovery path could never run. It runs at most once
                    # per Start click anyway, so no flag is needed.
                    Write-Log 'Remote build failed; attempting automatic remote docker login from repo .env and retrying build.' 'Info'
                    try {
                        if (Ensure-RemoteDockerLogin -State $State -ProjectRoot $projectRoot) {
                            Write-Log 'Remote docker login from .env succeeded; retrying build.' 'Info'
                            # While already busy this only updates the status text.
                            Set-ManagerBusy -Busy $true -Message 'Retrying the image build after docker login. Progress: see the console window.'
                            # Reuse the layers the first attempt already built (B4-R2).
                            $buildSucceeded = Invoke-StartImageBuild -Dockerfile $dockerfileMain -Tag $imageName -Context $dockerContext -WithRepoArg $true -NoCache $false
                            if ($buildSucceeded) { Write-Log 'Remote build succeeded after login; continuing.' 'Info' }
                        } else {
                            Write-Log 'Automatic remote docker login from .env did not provide credentials or failed.' 'Debug'
                        }
                    } catch { Write-Log "Remote login attempt failed: $($_.Exception.Message)" 'Warn' }
                }

                # Only fall back to the prerequisite build if the image is STILL not built. Before,
                # this ran even after the login retry had succeeded, starting two more long builds
                # and possibly reporting a failure for an image that was already built.
                if (-not $buildSucceeded) {
                    # B4-R2: the fallback runs two more long builds (prerequisite image, then the
                    # main image again), so ask first instead of silently blocking the window for
                    # another hour. 'Yes' is the default, as the fallback used to run automatically.
                    $fallbackAnswer = [System.Windows.Forms.MessageBox]::Show("Building the Docker image failed. The console window shows why.`n`nIMPACT can try a fallback: build the prerequisite image first, then the main image again. This can take another 30-60 minutes.`n`nTry the fallback build now?",'Image build failed',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning,[System.Windows.Forms.MessageBoxDefaultButton]::Button1)
                    if ($fallbackAnswer -ne [System.Windows.Forms.DialogResult]::Yes) {
                        Write-Log 'Image build failed; user declined the prerequisite fallback build.' 'Warn'
                        [System.Windows.Forms.MessageBox]::Show('Docker build failed. See console output for details.','Build failed','OK','Error') | Out-Null
                        return
                    }
                    Write-Log 'Main image build failed; attempting prerequisite build fallback.' 'Warn'
                    Set-ManagerBusy -Busy $true -Message 'Fallback: building the prerequisite image. Progress: see the console window.'
                    $prereqDockerfile = if ($State.ContainerLocation -eq 'LOCAL') { Join-Path $dockerSetup 'Dockerfile.prerequisite.IMPACTncdGER' } else { "$dockerSetup/Dockerfile.prerequisite.IMPACTncdGER" }
                    $prereqContext = if ($State.ContainerLocation -eq 'LOCAL') { Join-Path $dockerSetup '.' } else { "$dockerSetup" }
                    $preSuccess = Invoke-StartImageBuild -Dockerfile $prereqDockerfile -Tag "$imageName-prerequisite" -Context $prereqContext -WithRepoArg $false

                    if (-not $preSuccess) {
                        [System.Windows.Forms.MessageBox]::Show('Docker build failed (including prerequisite fallback).','Build failed','OK','Error') | Out-Null
                        return
                    }

                    # Retry main build after prerequisite. The cache is allowed here (B4-R2):
                    # layers based on the new prerequisite image are rebuilt anyway, the rest is reused.
                    Set-ManagerBusy -Busy $true -Message 'Fallback: building the main image again. Progress: see the console window.'
                    $buildSucceeded = Invoke-StartImageBuild -Dockerfile $dockerfileMain -Tag $imageName -Context $dockerContext -WithRepoArg $true -NoCache $false
                }

                $elapsed = (Get-Date) - $buildStart
                Write-Log "Docker build duration: $([int]$elapsed.TotalSeconds)s" 'Info'
                Write-Log "Docker build success=$buildSucceeded" 'Debug'
                if (-not $buildSucceeded) {
                    [System.Windows.Forms.MessageBox]::Show('Docker build failed. See console output for details.','Build failed','OK','Error') | Out-Null
                    return
                }
            } finally {
                Set-ManagerBusy -Busy $false
            }
        }

        # Busy mode for the rest of Start as well: creating and filling the volumes, 'docker
        # run' and the set-up steps inside the container all block this window (several ssh
        # round trips on the workstation). Same pattern as the image build above; the
        # 'finally' at the end of this part always switches busy mode off again, also on the
        # early 'return' paths. The code between 'try {' and '} finally {' is deliberately not
        # indented one level deeper, to keep this change small and easy to compare.
        Set-ManagerBusy -Busy $true -Message 'Starting the container. Please wait...'
        try {

        # Capture git baseline best-effort
        $State.Metadata.GitBaseline = $null
        try {
            if ($State.ContainerLocation -eq 'LOCAL') {
                # 'git -C <folder>' runs git in that folder without changing PowerShell's current
                # folder. The old Push-Location/Pop-Location pair skipped Pop-Location when git
                # failed (for example git not installed), which left the current folder at the
                # repository root; a later 'docker build ... .' then uploaded the whole repository
                # as build context.
                $hash = git -C $projectRoot rev-parse HEAD 2>$null
                $status = git -C $projectRoot status --porcelain 2>$null
                $State.Metadata.GitBaseline = @{ Repo=$projectRoot; Commit=$hash; Status=$status; Timestamp=Get-Date }
            } else {
                $remoteHost = Get-RemoteHostString -State $State
                $keyPath = $State.Paths.SshPrivate
                # The workstation folder name is quoted safely for its shell (B4-R7): plain '...'
                # broke on a ' in the name and let a crafted folder name run shell commands.
                $projectRootQ = ConvertTo-PosixShellLiteral -Value $projectRoot
                $hash = & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes $remoteHost "cd $projectRootQ && git rev-parse HEAD" 2>$null
                $status = & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes $remoteHost "cd $projectRootQ && git status --porcelain" 2>$null
                $State.Metadata.GitBaseline = @{ Repo=$projectRoot; Commit=$hash; Status=$status; Timestamp=Get-Date }
            }
            Write-Log "Captured git baseline: commit=$hash" 'Debug'
        } catch {
            Write-Log "Git baseline capture failed: $($_.Exception.Message)" 'Debug'
            $State.Metadata.GitBaseline = $null
        }

        # $outputDir and $synthDir were resolved and checked before the image build (see Confirm-YamlFolder above)

        $State.Paths.OutputDir = $outputDir
        $State.Paths.SynthpopDir = $synthDir

        # Resolve the actual uid/gid of the host user so the container's rstudio
        # user matches.  This prevents the container from changing ownership of
        # bind-mounted files (especially .git) to a different uid.  The Rocker
        # image remaps rstudio to the USERID/GROUPID we pass.  On Windows/local
        # Docker Desktop, 1000:1000 is fine (Linux VM layer).  On a remote Linux
        # workstation we query the real ids of the SSH user.
        $containerUid = '1000'
        $containerGid = '1000'
        if ($State.ContainerLocation -like 'REMOTE@*') {
            try {
                $remoteHost = Get-RemoteHostString -State $State
                $sshKey = $State.Paths.SshPrivate
                $idSshArgs = @('-n', '-i', $sshKey, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=15', $remoteHost)
                $uidOut = (& ssh @idSshArgs 'id -u' 2>$null)
                $gidOut = (& ssh @idSshArgs 'id -g' 2>$null)
                if ($LASTEXITCODE -eq 0 -and $uidOut -match '^\d+$') {
                    $containerUid = $uidOut.Trim()
                    $containerGid = $gidOut.Trim()
                    Write-Log "Remote host user uid=$containerUid gid=$containerGid" 'Info'
                }
            } catch {
                Write-Log "Could not detect remote uid/gid, defaulting to 1000:1000: $($_.Exception.Message)" 'Warn'
            }
        }

        # F13: in LOCAL mode publish RStudio on 127.0.0.1 only, so nobody else on the same
        # Wi-Fi or network can reach the login page (and, after a login, the GitHub key).
        # The GUI shows http://localhost:<port>, which keeps working. On the workstation the
        # colleague's PC must reach the port, so REMOTE stays on all interfaces.
        $hostPort = if ($portOverride) { $portOverride } else { '8787' }
        $publishSpec = if ($State.ContainerLocation -eq 'LOCAL') { "127.0.0.1:${hostPort}:8787" } else { "${hostPort}:8787" }

        $dockerArgs = @('run','-d','--rm','--name',$State.ContainerName,
            '-e',"PASSWORD=$($State.Password)",
            '-e','DISABLE_AUTH=false',
            '-e',"USERID=$containerUid",'-e',"GROUPID=$containerGid",
            '-e',"CONTAINER_REPO_NAME=$($State.SelectedRepo)",
            '-e','SYNC_ENABLED=false',
            '-e',"GIT_SSH_COMMAND=$(Get-ContainerGitSshCommand -UserName $State.UserName)",
            '--mount',"type=bind,source=$repoMountSource,target=/home/rstudio/$($State.SelectedRepo)",
            '-p',$publishSpec
        )

        if ($customParams) {
            # F102: split like a shell, so a quoted value with spaces stays one argument.
            $dockerArgs += @(Split-DockerCustomParams -Text $customParams)
        }

        if ($State.ContainerLocation -eq 'LOCAL') {
            $sshKeyPath = $State.Paths.SshPrivate
        } else {
            $sshKeyPath = "/home/$($State.RemoteUser)/.ssh/id_ed25519_$($State.UserName)"
        }

        # Removes the volumes created by THIS click when the start fails further down.
        # That is safe: at that point they only hold copies of host files made a moment
        # ago (volumes left over from an earlier session were dealt with before creating them).
        $removeFreshVolumes = {
            if ($useVolumes -and $State.Metadata.VolumeOutput -and $State.Metadata.VolumeSynthpop) {
                & docker @(Get-DockerContextArgs -State $State) @('volume','rm','-f',$State.Metadata.VolumeOutput,$State.Metadata.VolumeSynthpop) 2>$null | Out-Null
            }
        }

        if ($useVolumes) {
            # Not yet recorded in the state: $removeFreshVolumes must not touch these volumes
            # before they were really created by this click.
            $State.Metadata.VolumeOutput = $null
            $State.Metadata.VolumeSynthpop = $null

            # (The volume names, the rsync-alpine helper check and the check for volumes left
            # over from an earlier session now run BEFORE the image build, see above.)

            # Create the volumes. The label records the host folder each one belongs to, so a
            # later Start can copy leftovers to the right place even if the YAML changed.
            Write-Log "Creating Docker volumes: $volOut, $volSyn" 'Debug'
            foreach ($vp in $volPairs) {
                $createOut = & docker @ctxPrefix @('volume','create','--label',"impact.target_dir=$($vp.HostDir)",'--label',"impact.container=$($State.ContainerName)",$vp.Name) 2>&1
                if ($LASTEXITCODE -ne 0) {
                    & docker @ctxPrefix @('volume','rm','-f',$volOut,$volSyn) 2>$null | Out-Null
                    [System.Windows.Forms.MessageBox]::Show("Could not create the Docker volume '$($vp.Name)':`n$createOut",'Volume error','OK','Error') | Out-Null
                    return
                }
            }
            $State.Metadata.VolumeOutput = $volOut
            $State.Metadata.VolumeSynthpop = $volSyn

            # Fix ownership (checked now: a failure used to be ignored)
            Write-Log "Setting volume ownership (chown ${containerUid}:${containerGid})." 'Debug'
            foreach ($vn in @($volOut, $volSyn)) {
                $chownOut = & docker @ctxPrefix @('run','--rm','-v',"${vn}:/volume",'alpine','sh','-c',"chown ${containerUid}:${containerGid} /volume") 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Log "Setting ownership of volume $vn failed: $chownOut" 'Error'
                    & $removeFreshVolumes
                    [System.Windows.Forms.MessageBox]::Show("Preparing the Docker volume '$vn' failed (could not set its owner):`n$chownOut",'Volume error','OK','Error') | Out-Null
                    return
                }
            }

            # Pre-populate volumes from host dirs. One plain 'cp -r' whose result is checked
            # (it used to end in '|| true', which hid every error). One unreadable file should
            # not block the start, so on errors the user can still continue.
            Write-Log 'Pre-populating volumes from host directories.' 'Debug'
            $dockerOutputSource = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $outputDir } else { $outputDir }
            $dockerSynthSource  = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $synthDir } else { $synthDir }
            $prepopErrors = @()
            foreach ($pp in @(@{ Src = $dockerOutputSource; Vol = $volOut }, @{ Src = $dockerSynthSource; Vol = $volSyn })) {
                $cpOut = & docker @ctxPrefix @('run','--rm','--user',"${containerUid}:${containerGid}",'-v',"$($pp.Src):/source",'-v',"$($pp.Vol):/volume",'alpine','sh','-c','cp -r /source/. /volume/') 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $prepopErrors += "$($pp.Vol): $((@($cpOut) | ForEach-Object { "$_" } | Select-Object -Last 3) -join ' ')"
                }
            }
            if ($prepopErrors.Count -gt 0) {
                Write-Log "Pre-populating volumes reported errors: $($prepopErrors -join ' / ')" 'Warn'
                $prepopAnswer = [System.Windows.Forms.MessageBox]::Show("Copying your existing files into the Docker volumes reported errors:`n`n$($prepopErrors -join "`n")`n`nSome existing files may be missing inside the container (the files on disk are not affected).`n`nStart anyway?", 'Volume copy problem', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
                if ($prepopAnswer -ne [System.Windows.Forms.DialogResult]::Yes) {
                    & $removeFreshVolumes
                    return
                }
            }

            $dockerArgs += @('-v',"$($volOut):/home/rstudio/$($State.SelectedRepo)/outputs",
                             '-v',"$($volSyn):/home/rstudio/$($State.SelectedRepo)/inputs/synthpop")
        } else {
            # Bind mode: make sure no volume names from an earlier start linger in the state.
            $State.Metadata.VolumeOutput = $null
            $State.Metadata.VolumeSynthpop = $null
            $outDocker = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $outputDir } else { $outputDir }
            $synDocker = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $synthDir } else { $synthDir }
            # repo already mounted above; only bind outputs and synthpop to avoid duplicate mount targets
            $dockerArgs += @('--mount',"type=bind,source=$outDocker,target=/home/rstudio/$($State.SelectedRepo)/outputs",
                             '--mount',"type=bind,source=$synDocker,target=/home/rstudio/$($State.SelectedRepo)/inputs/synthpop")
        }

        if ($highComp -and $State.ContainerLocation -like 'REMOTE@*') {
            $dockerArgs += @('--cpus','32','-m','384g')
        }

        # F01/F04: record how this container is started (volume mode, result folders,
        # volume names) as Docker labels. A GUI that is closed and reopened reads them back
        # (Get-ContainerRuntimeInfo), for LOCAL and REMOTE alike, so Stop can still copy the
        # results to the right folders.
        # F84: -RepoPath also records WHICH repository folder is mounted, so a reopened GUI
        # can notice when the user selected a different clone with the same folder name.
        $dockerArgs += @(Get-ImpactContainerLabelArgs -UseVolumes $useVolumes -OutputDir $outputDir -SynthpopDir $synthDir -VolumeOutput $State.Metadata.VolumeOutput -VolumeSynthpop $State.Metadata.VolumeSynthpop -RepoPath $projectRoot)

        # Only the private key comes from the host. github.com's host key is
        # written inside the container below (Get-ContainerSshSetupCommand).
        $dockerArgs += @('--mount',"type=bind,source=$sshKeyPath,target=/keys/id_ed25519_$($State.UserName),readonly",
                         '--workdir',"/home/rstudio/$($State.SelectedRepo)",
                         $imageName)

        # Refresh port scan immediately before docker run to catch races
        $freshUsedPorts = Get-UsedPorts -ContextArgs (Get-DockerContextArgs -State $State)
        $chosenPort = if ($portOverride) { $portOverride } else { '8787' }
        if ($freshUsedPorts -contains $chosenPort) {
            & $removeFreshVolumes
            [System.Windows.Forms.MessageBox]::Show("Port $chosenPort was just taken by another container. Choose a different port.", 'Port conflict', 'OK', 'Error') | Out-Null
            return
        }

        $runCmd = (Get-DockerContextArgs -State $State) + $dockerArgs
        # Hide the password: Debug lines always go to the log file on disk (F85).
        $runCmdForLog = $runCmd | ForEach-Object { if ("$_" -like 'PASSWORD=*') { 'PASSWORD=***' } else { $_ } }
        Write-Log "Starting container with: docker $($runCmdForLog -join ' ')" 'Debug'

        $rc = & docker $runCmd 2>&1
        if ($LASTEXITCODE -ne 0) {
            $runExit = $LASTEXITCODE
            $friendlyError = Format-DockerError -RawError ([string]$rc)
            Write-Log "Docker run failed (exit=$runExit): $rc" 'Error'
            & $removeFreshVolumes
            [System.Windows.Forms.MessageBox]::Show($friendlyError, 'Container start failed', 'OK', 'Error') | Out-Null
            return
        }

        # Prepare SSH for git inside the container (Get-ContainerSshSetupCommand):
        #  - copy the key from the readonly bind mount to ~rstudio/.ssh with
        #    mode 600 and rstudio ownership (the bind mount keeps host ownership);
        #  - write github.com's host key to ~rstudio/.ssh/known_hosts with
        #    ssh-keyscan inside the container, so 'git pull' does not depend on
        #    the host's known_hosts having a github.com entry.
        # The command prints KEY_FIXED only when every key step succeeded (F49).
        $fixKeyCmd = Get-ContainerSshSetupCommand -UserName $State.UserName -ContainerUid $containerUid -ContainerGid $containerGid
        # F88: run as root explicitly. Copying into /home/rstudio and chown need root, and
        # the image's default user could change in the future.
        $fixCtx = (Get-DockerContextArgs -State $State) + @('exec', '--user', 'root', $State.ContainerName, 'sh', '-c', $fixKeyCmd)
        # Retry a few times: right after 'docker run' the container may still be setting
        # itself up (for example remapping the rstudio user to USERID/GROUPID).
        $keyFixed = $false
        for ($attempt = 1; $attempt -le 3 -and -not $keyFixed; $attempt++) {
            try {
                $fixOut = & docker $fixCtx 2>&1
                if ($fixOut -match 'KEY_FIXED') {
                    $keyFixed = $true
                    Write-Log 'SSH key permissions fixed inside container.' 'Info'
                } else {
                    Write-Log "SSH key permission fix attempt $attempt failed: $fixOut" 'Warn'
                }
            } catch {
                Write-Log "SSH key permission fix attempt $attempt failed: $($_.Exception.Message)" 'Warn'
            }
            if (-not $keyFixed -and $attempt -lt 3) { Start-Sleep -Seconds 2 }
        }

        # Configure git inside the container for the rstudio user.
        # 1. Set user.name and user.email so that git commit works out of the box.
        #    The username is the user's GitHub handle; email uses GitHub's noreply
        #    address so commits are attributed correctly without exposing real email.
        # 2. The Docker image's system gitconfig ships pull.ff=only which aborts when
        #    fast-forward isn't possible. We override at global level so git pull
        #    works like GitKraken / vanilla-git (merge when not fast-forwardable).
        # 3. safe.directory='*' is a safety net for any remaining ownership edge cases.
        # 4. url...insteadOf (B5-R2): the container only has the user's SSH key (see
        #    GIT_SSH_COMMAND), no HTTPS login. A repository cloned with an https://github.com
        #    address (typical for GitHub Desktop clones) could therefore never push, or pull a
        #    private repository, from RStudio's Git pane. This setting makes git inside the
        #    container use SSH for github.com instead. It is stored in the container's own
        #    /home/rstudio/.gitconfig only: the repository's .git/config and the settings on
        #    this PC or the workstation are not changed, so GitHub Desktop keeps working.
        $gitCfgCmd = "git config --global user.name '$($State.UserName)' && git config --global user.email '$($State.UserName)@users.noreply.github.com' && git config --global pull.ff true && git config --global pull.rebase false && git config --global --add safe.directory '*' && git config --global url.git@github.com:.insteadOf https://github.com/ && echo GIT_CONFIGURED"
        $gitCfgCtx = (Get-DockerContextArgs -State $State) + @('exec', '--user', 'rstudio', $State.ContainerName, 'sh', '-c', $gitCfgCmd)
        $gitConfigured = $false
        for ($attempt = 1; $attempt -le 3 -and -not $gitConfigured; $attempt++) {
            try {
                $gitCfgOut = & docker $gitCfgCtx 2>&1
                if ($gitCfgOut -match 'GIT_CONFIGURED') {
                    $gitConfigured = $true
                    Write-Log 'Git pull strategy (merge) configured inside container.' 'Info'
                } else {
                    Write-Log "Git config inside container attempt $attempt failed: $gitCfgOut" 'Warn'
                }
            } catch {
                Write-Log "Git config inside container attempt $attempt failed: $($_.Exception.Message)" 'Warn'
            }
            if (-not $gitConfigured -and $attempt -lt 3) { Start-Sleep -Seconds 2 }
        }

        # F49: 'docker run -d' only says the container was started, not that it is still
        # running. If its start-up script fails, it stops at once and '--rm' deletes it,
        # so check that it is still there before reporting RUNNING.
        $psAfterStart = (Get-DockerContextArgs -State $State) + @('ps','--filter',"name=^$($State.ContainerName)$",'--format','{{.Names}}')
        $psAfterOut = & docker @psAfterStart 2>$null
        $psAfterExit = $LASTEXITCODE
        if ($psAfterExit -eq 0 -and -not (@($psAfterOut) | Where-Object { "$_".Trim() -eq $State.ContainerName })) {
            Write-Log "Container $($State.ContainerName) stopped right after starting." 'Error'
            # The fresh volumes only hold copies of host files, so they can go.
            & $removeFreshVolumes
            [System.Windows.Forms.MessageBox]::Show("The container stopped right after it was started, so RStudio is not available.`n`nCheck the console window and the log file for details:`n$(Get-ImpactLogPathText)`n`nTicking 'Rebuild image' and starting again often helps.",'Container stopped','OK','Error') | Out-Null
            return
        } elseif ($psAfterExit -ne 0) {
            # Docker could not be asked (for example a short network problem); carry on as before.
            Write-Log 'Could not confirm that the container is still running (docker ps failed).' 'Warn'
        }

        if (-not $keyFixed -or -not $gitConfigured) {
            # The container runs, so do not stop it, but tell the user clearly instead of
            # only writing a console warning that nobody reads.
            $setupProblems = @()
            if (-not $keyFixed) { $setupProblems += "- Your GitHub SSH key could not be set up inside the container: git pull / push from RStudio will not work." }
            if (-not $gitConfigured) { $setupProblems += "- Your git name and e-mail could not be set inside the container: git commit in RStudio may fail ('Please tell me who you are')." }
            [System.Windows.Forms.MessageBox]::Show("The container is running, but part of its setup failed:`n`n$($setupProblems -join "`n")`n`nDetails are in the console window and the log file. Stopping and starting the container again often fixes this.",'Container setup incomplete','OK','Warning') | Out-Null
        }

        if ($State.ContainerLocation -like 'REMOTE@*') {
            $portStore = if ($portOverride) { $portOverride } else { '8787' }
            # No password in the metadata any more (F40): every colleague can read /tmp.
            Write-RemoteContainerMetadata -State $State -Port $portStore -UseVolumes $useVolumes
        }

        } finally {
            # End of busy mode for the start steps (see 'Starting the container' above). The
            # Start/Stop buttons are switched below, AFTER this, because Set-ManagerBusy
            # restores the button states it saved when busy mode began.
            Set-ManagerBusy -Busy $false
        }

        # F32: the recovered password/port/volume details belonged to the previous container.
        # Forget them so the info box shows the password this container really uses.
        $State.Metadata.Recovered = @{ Password = $null; Port = $null; UseVolumes = $false; OutputDir = $null; SynthpopDir = $null; VolumeOutput = $null; VolumeSynthpop = $null }

        $State.Metadata.ContainerRunning = $true
        $State.Metadata.ActiveUseVolumes = $useVolumes
        $State.Metadata.ActiveRepoPath = $projectRoot
        $State.Metadata.ActiveIsRemote = ($State.ContainerLocation -like 'REMOTE@*')
        $State.Metadata.ActivePort = if ($portOverride) { $portOverride } else { '8787' }

        $btnStart.Enabled = $false
        $btnStop.Enabled = $true
        $lblStatus.Text = ''
        Update-InfoBox -Status 'RUNNING'
        Write-Log "Container $($State.ContainerName) started." 'Info'

        $hostDisplay = if ($State.ContainerLocation -eq 'LOCAL') { "http://localhost:$($State.Metadata.ActivePort)" } else { "http://$($State.RemoteHostIp):$($State.Metadata.ActivePort)" }
        # F85: never print the password to the console (it stays visible during screen-sharing).
        Write-Host "Container ready: $hostDisplay (user: rstudio, password: the one you entered at login)" -ForegroundColor Green
    }

    # The code of the Stop button, kept in a variable for the same reason as $startClickBody.
    $stopClickBody = {
        $ctxArgs = Get-DockerContextArgs -State $State
        $runCmd = $ctxArgs + @('ps','--filter',"name=^$($State.ContainerName)$",'--format','{{.Names}}')
        # Busy mode while Docker is asked: over a bad connection to the workstation this can
        # take up to 30 seconds, and the window would otherwise just look frozen.
        Set-ManagerBusy -Busy $true -Message 'Checking the container...'
        try {
            $exists = & docker $runCmd 2>$null
            $psExitCode = $LASTEXITCODE
        } finally {
            Set-ManagerBusy -Busy $false
        }
        # F18: a non-zero exit code means Docker (or the ssh connection to the workstation)
        # could not be reached, so we do NOT know whether the container still runs. Say so,
        # and leave state and buttons unchanged so the user can simply try again. (Before,
        # this looked the same as "container gone" and the UI wrongly showed STOPPED.)
        if ($psExitCode -ne 0) {
            $where = if ($State.ContainerLocation -eq 'LOCAL') { 'Check that Docker Desktop is running.' } else { 'Check your network / VPN connection to the workstation.' }
            [System.Windows.Forms.MessageBox]::Show("Could not reach Docker, so it is unknown whether the container is still running.`n`n$where Then click Stop again.",'Docker not reachable','OK','Warning') | Out-Null
            return
        }
        # Docker answered but the container is not listed: it already ended on its own
        # (crash, reboot, Docker restart, or stopped outside this tool). We still run the
        # clean-up below: the Docker volumes survive the container and hold its results,
        # and the state flags must be reset so Start and Back work again (F18).
        $alreadyGone = -not (@($exists) | Where-Object { "$_".Trim() -eq $State.ContainerName })

        if ($alreadyGone) {
            Write-Log "Container $($State.ContainerName) is no longer running; cleaning up." 'Warn'
        } else {
            # F51: stopping ends every R session at once and the container is deleted
            # (--rm), so ask first. 'No' is the default button, so a stray Enter is harmless.
            $stopMsg = "Stop the container '$($State.ContainerName)' now?`n`n" +
                       "- Any simulation that is still running will be killed.`n" +
                       "- Unsaved changes in RStudio editor tabs will be lost.`n`n" +
                       "Files you saved in the repository and your output folders are kept.`n`n" +
                       "Tip: save your files in RStudio and let simulations finish first."
            $stopAnswer = [System.Windows.Forms.MessageBox]::Show($stopMsg, 'Stop container?', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
            if ($stopAnswer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        # Stopping, copying the results back and removing the volumes can take minutes, so
        # all of it runs in busy mode (buttons disabled, closing refused). The Start/Stop
        # buttons and the final status text are set AFTER the 'finally' below, because
        # Set-ManagerBusy restores the button states it saved when busy mode began. The code
        # between 'try {' and '} finally {' is deliberately not indented one level deeper,
        # to keep this change small and easy to compare.
        $volumeProblem = $null
        # The volumes that are KEPT because their results were not copied back.
        $keptVolumes = @()
        Set-ManagerBusy -Busy $true -Message 'Stopping the container. Please wait...'
        try {

        if (-not $alreadyGone) {
            # B3-R5: ask the container once more how it was started, right before it is
            # deleted. When the GUI reconnected to a running container and that first
            # 'docker inspect' failed, volume mode looked "off", and Stop skipped the copy
            # while the results stayed in the volumes without a word. Only answers that
            # really came back are used; everything else keeps what is already known.
            $rt = Get-ContainerRuntimeInfo -State $State
            if ($null -ne $rt.UseVolumes) {
                $State.Metadata.ActiveUseVolumes = [bool]$rt.UseVolumes
                if ($rt.UseVolumes) {
                    $fallbackNames = Get-ImpactVolumeNames -ContainerName $State.ContainerName
                    $State.Metadata.VolumeOutput = if ($rt.VolumeOutput) { $rt.VolumeOutput } elseif ($State.Metadata['VolumeOutput']) { $State.Metadata['VolumeOutput'] } else { $fallbackNames.Output }
                    $State.Metadata.VolumeSynthpop = if ($rt.VolumeSynthpop) { $rt.VolumeSynthpop } elseif ($State.Metadata['VolumeSynthpop']) { $State.Metadata['VolumeSynthpop'] } else { $fallbackNames.Synthpop }
                }
                if ($rt.OutputDir) { $State.Paths.OutputDir = $rt.OutputDir }
                if ($rt.SynthpopDir) { $State.Paths.SynthpopDir = $rt.SynthpopDir }
            }
            # F84: check git changes in the folder the container really mounts.
            $labelRepo = Get-DifferentLabelRepoPath -LabelPath $rt.RepoPath -SelectedPath $State.Metadata.ActiveRepoPath
            if ($labelRepo) {
                Write-Log "Container $($State.ContainerName) uses repository folder '$labelRepo'; git changes are checked there." 'Warn'
                $State.Metadata.ActiveRepoPath = $labelRepo
            }

            $stopCmd = $ctxArgs + @('stop',$State.ContainerName)
            Write-Log "Stopping container $($State.ContainerName)" 'Info'
            & docker $stopCmd 2>$null
            Write-Log "docker stop exit=$LASTEXITCODE" 'Debug'
            if ($LASTEXITCODE -ne 0) {
                [System.Windows.Forms.MessageBox]::Show('Failed to stop container; check Docker.','Stop failed','OK','Error') | Out-Null
                return
            }
        }

        # Copy results out of the volumes, if volumes were used. The checkbox is NOT used as a
        # fallback any more: it describes the next start, not the container being stopped.
        $useVolumesForStop = [bool]$State.Metadata.ActiveUseVolumes
        Write-Log "Stop clicked; volumesUsed=$useVolumesForStop" 'Debug'
        if ($useVolumesForStop) {
            # ['...'] instead of .Name: under StrictMode a missing key would throw.
            $volOut = $State.Metadata['VolumeOutput']
            $volSyn = $State.Metadata['VolumeSynthpop']
            # F01: a volume is deleted ONLY after its copy succeeded. Before, they were
            # always deleted, even when the copy failed or the target folder was unknown
            # (a resumed session), which lost all results of the run.
            if (-not $volOut -or -not $volSyn) {
                $volumeProblem = 'The names of the Docker volumes are unknown.'
                $keptVolumes = @(@($volOut, $volSyn) | Where-Object { $_ })
            } elseif (-not $State.Paths.OutputDir -or -not $State.Paths.SynthpopDir) {
                $volumeProblem = 'The folders to copy the results back to are unknown (the container was probably started by an older version of this tool).'
                $keptVolumes = @($volOut, $volSyn)
            } else {
                $lblStatus.Text = 'Copying results from the Docker volumes back to your folders...'
                $form.Refresh()
                $syncOut = Sync-ImpactVolumeToHost -State $State -VolumeName $volOut -HostDir $State.Paths.OutputDir
                $syncSyn = Sync-ImpactVolumeToHost -State $State -VolumeName $volSyn -HostDir $State.Paths.SynthpopDir
                # B3-R1 (c): decide for EACH volume on its own. Before, both volumes were kept
                # when only one copy failed, so the volume that HAD been copied was copied
                # again at a later Start, over files that may have changed since.
                $toRemove = @()
                $syncProblems = @()
                foreach ($sv in @(@{ Name = $volOut; Result = $syncOut }, @{ Name = $volSyn; Result = $syncSyn })) {
                    if ($sv.Result.Success) {
                        if (-not $sv.Result.Missing) { $toRemove += $sv.Name }
                    } else {
                        $keptVolumes += $sv.Name
                        $syncProblems += $sv.Result.Message
                    }
                }
                if ($toRemove.Count -gt 0) {
                    # Retry briefly: '--rm' may still be removing the stopped container,
                    # and a volume cannot be removed while a container uses it.
                    # '-f' only ignores volumes that are already gone.
                    $removed = $false
                    $rmOut = $null
                    for ($i = 1; $i -le 5 -and -not $removed; $i++) {
                        $rmOut = & docker @ctxArgs (@('volume','rm','-f') + $toRemove) 2>&1
                        if ($LASTEXITCODE -eq 0) { $removed = $true } else { Start-Sleep -Seconds 1 }
                    }
                    if ($removed) {
                        Write-Log "Removed volumes $($toRemove -join ', ') after a successful copy." 'Info'
                    } else {
                        # Not a data loss: everything was copied. The volumes only use disk space.
                        Write-Log "Results were copied, but volumes $($toRemove -join ', ') could not be removed: $rmOut" 'Warn'
                    }
                }
                if ($syncProblems.Count -gt 0) { $volumeProblem = $syncProblems -join "`n" }
            }
        }

        $State.Metadata.ContainerRunning = $false
        $State.Metadata.ActiveUseVolumes = $false

        if ($State.ContainerLocation -like 'REMOTE@*') { Remove-RemoteContainerMetadata -State $State }

        # F32: the recovered details belonged to the container that is now gone.
        $State.Metadata.Recovered = @{ Password = $null; Port = $null; UseVolumes = $false; OutputDir = $null; SynthpopDir = $null; VolumeOutput = $null; VolumeSynthpop = $null }
        # F39: refresh the list of used ports, so starting again on the port that was just
        # freed is not rejected as 'already in use'.
        $State.Ports.Used = @(Get-UsedPorts -ContextArgs $ctxArgs)

        } finally {
            # End of busy mode for the stop steps (see 'Stopping the container' above).
            Set-ManagerBusy -Busy $false
        }

        Update-InfoBox -Status 'STOPPED'
        $btnStart.Enabled = $true
        $btnStop.Enabled  = $false
        Write-Log "Container $($State.ContainerName) stopped." 'Info'

        if ($volumeProblem) {
            # Shown before the git dialog because it is about possible data loss.
            $volList = if ($keptVolumes.Count -gt 0) { $keptVolumes -join ', ' } else { '(names unknown)' }
            Write-Log "Results were NOT copied back; volumes kept: $volList. Reason: $volumeProblem" 'Error'
            # The next Start only recognises volumes named the current way; volumes of a
            # container started by an older version need manual help.
            $expectedNames = Get-ImpactVolumeNames -ContainerName $State.ContainerName
            $otherNamed = @($keptVolumes | Where-Object { $_ -ne $expectedNames.Output -and $_ -ne $expectedNames.Synthpop })
            $nextStep = if ($keptVolumes.Count -gt 0 -and $otherNamed.Count -eq 0) {
                "The next time you click Start, the tool offers to copy them into your folders. If that does not work, ask the maintainer for help and quote the volume names above."
            } else {
                "Please do not delete them. Ask the maintainer to copy them for you and quote the volume names above."
            }
            [System.Windows.Forms.MessageBox]::Show("Your results were NOT copied back to your folders, so these Docker volumes were kept (nothing was deleted):`n`n  $volList`n`nReason:`n$volumeProblem`n`n$nextStep",'Results still in Docker volumes','OK','Error') | Out-Null
        }

        # B5-R1 / B3-R3: Invoke-GitChangeDetection returns {Success; Outcome; Message}. The
        # result used to be thrown away, so the status line said 'All done' even after a
        # failed commit or push, and a colleague then believed the work was on GitHub. The
        # filter keeps only that result object, in case anything else was written to the
        # output as well. Busy mode again: a push can take a while.
        $gitResult = $null
        if ($State.Metadata.ActiveRepoPath) {
            Set-ManagerBusy -Busy $true -Message 'Checking your repository for changes to commit...'
            try {
                $gitResult = @(Invoke-GitChangeDetection -State $State -RepoPath $State.Metadata.ActiveRepoPath -IsRemote $State.Metadata.ActiveIsRemote) |
                    Where-Object { $_ -and $_.PSObject.Properties['Success'] } | Select-Object -Last 1
            } finally {
                Set-ManagerBusy -Busy $false
            }
        }

        if ($volumeProblem) {
            $lblStatus.Text = 'Stopped. Results are still in Docker volumes (see the message).'
            Write-Host "Stopped, but results are still in Docker volumes: $volumeProblem" -ForegroundColor Yellow
        } elseif ($gitResult -and (-not $gitResult.Success -or $gitResult.Outcome -eq 'Unavailable')) {
            # 'Unavailable' counts as Success (nothing broke), but nothing was checked or
            # committed either, so it must not be reported as 'All done'.
            $lblStatus.Text = "Container stopped. $($gitResult.Message)"
            Write-Host "Container stopped. $($gitResult.Message)" -ForegroundColor Yellow
        } else {
            $lblStatus.Text = 'All done. You can close this window or start another container.'
            Write-Host "All done. You can close this window or start another container." -ForegroundColor Green
        }
    }

    # Safety net for the Start and Stop buttons (B4-R5). Under StrictMode, with
    # $ErrorActionPreference = 'Stop', any error nobody expected (for example reading a
    # setting that does not exist) used to show the raw .NET "Unhandled exception"
    # Continue/Quit dialog, which looks like a crash, and its details were not logged.
    # Now the error is written to the log file and a plain message says where it is.
    # 'return' inside the button code still works as before.
    function Invoke-ManagerButtonAction {
        param([string]$ActionDescription, [scriptblock]$ActionCode)
        try {
            & $ActionCode
        } catch {
            Show-ImpactUnexpectedError -Action $ActionDescription -ErrorInfo $_
        }
    }
    $btnStart.Add_Click({ Invoke-ManagerButtonAction -ActionDescription 'starting the container' -ActionCode $startClickBody })
    $btnStop.Add_Click({ Invoke-ManagerButtonAction -ActionDescription 'stopping the container' -ActionCode $stopClickBody })

    $btnClose.Add_Click({ $form.Close() })

    $null = $form.ShowDialog()
    if ($form.Tag -eq 'back') {
        Write-Log 'User navigated back from container manager.' 'Info'
        return 'back'
    }
    return 'close'
}

# Where the log file is, as text for messages (F82, B6a-R2). Same rule as
# Initialize-Logging in the module: $env:IMPACT_LOG_FILE if it is set, otherwise
# ~/.impact_gui/logs/impact.log. The old messages always showed the '~' form, which was
# wrong when IMPACT_LOG_FILE was set and means nothing to most colleagues.
function Get-ImpactLogPathText {
    if ($env:IMPACT_LOG_DISABLE -and $env:IMPACT_LOG_DISABLE -match '^(1|true|yes)$') {
        return '(no log file: logging is turned off by IMPACT_LOG_DISABLE)'
    }
    $logPath = if ($env:IMPACT_LOG_FILE) { $env:IMPACT_LOG_FILE } else { Join-Path $HOME '.impact_gui/logs/impact.log' }
    # GetFullPath turns the mix of / and \ into one clean Windows path for display.
    try { $logPath = [System.IO.Path]::GetFullPath($logPath) } catch { }
    return $logPath
}

# Shows a plain-language message for an error that nobody expected, and writes the full
# details (message, where in the script it happened) to the log file (B4-R5). Used by the
# Start/Stop safety net in the container manager and by the window-wide safety net that
# is set up at the bottom of this script. -ErrorInfo takes a PowerShell error record
# (from a catch block) or a .NET exception (from the window's ThreadException event).
function Show-ImpactUnexpectedError {
    param([string]$Action, $ErrorInfo)
    try {
        $errorRecord = $null
        if ($ErrorInfo -is [System.Management.Automation.ErrorRecord]) {
            $errorRecord = $ErrorInfo
        } elseif ($ErrorInfo -is [System.Management.Automation.IContainsErrorRecord]) {
            $errorRecord = $ErrorInfo.ErrorRecord
        }
        $exception = if ($errorRecord) { $errorRecord.Exception } else { $ErrorInfo }
        $errorText = if ($exception -is [System.Exception]) { $exception.Message } else { "$ErrorInfo" }
        $details = if ($errorRecord) { (($errorRecord | Out-String).Trim() + "`n" + $errorRecord.ScriptStackTrace) } else { "$exception" }
        Write-Log "Unexpected error while ${Action}: $errorText`n$details" 'Error'
        [System.Windows.Forms.MessageBox]::Show("Something unexpected went wrong while ${Action}:`n`n$errorText`n`nThe details were written to the log file:`n$(Get-ImpactLogPathText)`n`nYou can try again. If it keeps happening, please send that log file to the IMPACT maintainer.",'IMPACT - Unexpected error','OK','Error') | Out-Null
    } catch {
        # Last resort: never let the safety net itself crash the window.
        try { Write-Host "Unexpected error while ${Action}: $ErrorInfo" -ForegroundColor Red } catch { }
    }
}

# Coordinator: orchestrates all steps with clear sequencing and early validation.
function Invoke-ImpactGui {
    Write-Log 'Starting IMPACT Docker GUI workflow.' 'Info'
    try {
        Ensure-PowerShell7 -PS7RequestedFlag:$PS7Requested.IsPresent
    } catch {
        # B6a-R2: Ensure-PowerShell7 shows its own clear message box (PowerShell too old, or
        # missing) right before each of these deliberate stops. Mark the error as "the user
        # has already been told", so the fatal-error handler at the bottom of this script
        # does not show a second, confusing box. Other, unexpected errors are not marked.
        if ($_.Exception.Message -match 'PowerShell 7|relaunch under pwsh') {
            try { $_.Exception.Data['ImpactUserNotified'] = $true } catch { }
        }
        throw
    }
    $state = New-SessionState

    $state.Metadata.BuildInfo = Get-BuildInfo
    $bi = $state.Metadata.BuildInfo
    Write-Log ("Build info -> Version={0} Commit={1} Built={2}" -f $bi.Version, $bi.Commit, $bi.Built) 'Info'

    # Step-based wizard loop: allows Back navigation between dialogs
    $step = 1
    while ($step -le 6) {
        switch ($step) {
            1 { # Prerequisites (automated — no back)
                if (-not (Ensure-Prerequisites -State $state)) { return }
                $step++
            }
            2 { # Credentials dialog
                $r = Show-CredentialDialog -State $state
                if ($r -eq 'next') { $step++ }
                else { return } # cancel or failure — exit
            }
            3 { # SSH key setup (automated — no back)
                if (-not (Ensure-GitKeySetup -State $state)) { return }
                $step++
            }
            4 { # Location selection dialog
                $r = Select-Location -State $state
                if ($r -eq 'next') { $step++ }
                elseif ($r -eq 'back') { $step = 2 } # back to credentials
                else { return } # cancel — exit
            }
            5 { # Preparation (local/remote)
                $prepOk = $false
                if ($state.ContainerLocation -like 'REMOTE@*') {
                    $prepOk = Ensure-RemotePreparation -State $state
                } elseif ($state.ContainerLocation -eq 'LOCAL') {
                    $prepOk = Ensure-LocalPreparation -State $state
                } else {
                    Write-Log "No container location selected; exiting." 'Warn'
                    return
                }
                if ($prepOk) { $step++ }
                else { $step = 4 } # cancelled/failed — back to location
            }
            6 { # Container manager
                # F83: discard the returned state object. Uncaptured, PowerShell printed the
                # whole session state to the console, including the password in plain text.
                $null = Get-ContainerStatus -State $state
                $mgr = Show-ContainerManager -State $state
                if ($mgr -eq 'back') { $step = 4 } # back to location selection
                else { $step++ } # close — exit loop
            }
        }
    }
}

# Window-wide safety net (B4-R5). An error inside ANY window event handler (a click, a
# text change, closing a dialog) that is not caught there reaches Windows Forms. Without
# a handler, Windows Forms shows its raw "Unhandled exception has occurred" dialog with
# Continue/Quit, which looks like a crash to colleagues and writes nothing to our log.
# With this handler the error is logged and explained in plain words, and the window
# keeps working. CatchException sends such errors to the handler (it can only be set
# before the first window exists; if that is too late, the default already does the same).
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    try { [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException) } catch { }
    [System.Windows.Forms.Application]::add_ThreadException([System.Threading.ThreadExceptionEventHandler]{
        param($eventSource, $threadErrorArgs)
        Show-ImpactUnexpectedError -Action 'handling an action in the IMPACT window' -ErrorInfo $threadErrorArgs.Exception
    })
} catch {
    Write-Log "Could not install the window error handler: $($_.Exception.Message)" 'Debug'
}

try {
    Invoke-ImpactGui
} catch {
    # Top-level catch to prevent the EXE from closing immediately and to surface diagnostics.
    $ex = $_.Exception
    Write-Log ("Unhandled exception: {0}`n{1}`n{2}" -f $ex.Message, $_.ScriptStackTrace, $ex.StackTrace) 'Error'
    Write-Host "A fatal error occurred: $($ex.Message)" -ForegroundColor Red
    # F82 / B6a-R2: real line breaks ("`n"; "\n" is not a line break in PowerShell) and the
    # real log file path. No second box when the user has already seen an explanation
    # (see Invoke-ImpactGui), and no extra "Press Enter" when the box was shown: IMPACT.bat
    # already waits for a key press after an error.
    $alreadyTold = $false
    try { $alreadyTold = [bool]$ex.Data['ImpactUserNotified'] } catch { }
    $boxShown = $false
    if (-not $alreadyTold) {
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
            [System.Windows.Forms.MessageBox]::Show("IMPACT encountered a fatal error and has to close:`n`n$($ex.Message)`n`nDetails are in the log file:`n$(Get-ImpactLogPathText)", 'IMPACT - Fatal error', 'OK', 'Error') | Out-Null
            $boxShown = $true
        } catch { }
    }
    if (-not $boxShown -and -not $alreadyTold) {
        # No message box could be shown, so keep the console open long enough to read it.
        Write-Host "`nPress Enter to exit..." -ForegroundColor Yellow
        Read-Host | Out-Null
    }
    exit 1
}
