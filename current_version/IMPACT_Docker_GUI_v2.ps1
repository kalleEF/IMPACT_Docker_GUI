<# IMPACT Docker GUI v2 #>
<# This is the launcher script. Core functions live in IMPACT_Docker_GUI.psm1 #>

[CmdletBinding()]
param(
    [switch]$ElevatedRestart,
    [switch]$PS7Requested
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Determine the directory where this script (or compiled EXE) lives.
# $PSScriptRoot works when running as .ps1 but is empty/wrong in a ps2exe EXE.
if ($PSScriptRoot -and (Test-Path $PSScriptRoot)) {
    $script:ScriptDir = $PSScriptRoot
} else {
    # Fallback for ps2exe-compiled EXE: use the process executable's directory
    $script:ScriptDir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}

# Import the companion module (same directory as script/EXE)
$modulePath = Join-Path $script:ScriptDir 'IMPACT_Docker_GUI.psm1'
if (Test-Path $modulePath) {
    Import-Module $modulePath -Force -DisableNameChecking
} else {
    Write-Host "ERROR: Module not found at $modulePath" -ForegroundColor Red
    Write-Host "The file 'IMPACT_Docker_GUI.psm1' must be in the same folder as this script/EXE." -ForegroundColor Red
    Write-Host ""
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
    try {
        $probeOut = & ssh @sshArgs "echo KEY_AUTH_OK" 2>&1
        if ($LASTEXITCODE -eq 0 -and $probeOut -match 'KEY_AUTH_OK') { $keyAuthorized = $true }
        Write-Log "Key auth probe output: $probeOut (exit=$LASTEXITCODE)" 'Debug'
    } catch { $keyAuthorized = $false }

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

mkdir -p "$HOME_DIR" && chmod 755 "$HOME_DIR"
mkdir -p "$USER_SSH_DIR" && chmod 700 "$USER_SSH_DIR"
touch "$AUTH_KEYS" && chmod 600 "$AUTH_KEYS"

echo "{2}" > "$KEY_TARGET_PUB"
chown {0}:{0} "$KEY_TARGET_PUB"
chmod 644 "$KEY_TARGET_PUB"

# Remove any previous keys for this IMPACT user (comment marker: IMPACT_{1})
sed -i '/IMPACT_{1}/d' "$AUTH_KEYS" 2>/dev/null || true

if ! grep -qxF "{2}" "$AUTH_KEYS"; then
    echo "{2}" >> "$AUTH_KEYS"
fi
chown {0}:{0} "$AUTH_KEYS"
echo 'SSH_KEY_COPIED'
'@ -f $remoteUser, $State.UserName, $publicKeyContent

    if (-not $keyAuthorized) {
        try {
            # Escape single quotes for safe bash -lc wrapping (turn ' into '\'' )
            $escaped = $remoteScript.Replace("'", "'\\''")
            $cmdOut = & ssh @sshArgs "bash -lc '$escaped'" 2>&1
            if ($LASTEXITCODE -eq 0 -and $cmdOut -match 'SSH_KEY_COPIED') { $keyAuthorized = $true }
        } catch { $keyAuthorized = $false }
    }

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
KEY_TARGET_PUB="$USER_SSH_DIR/id_ed25519___USERNAME___.pub"
REMOTE_TEMP="__REMOTE_TEMP__"

mkdir -p "$HOME_DIR" && chmod 755 "$HOME_DIR"
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

# Remove any previous keys for this IMPACT user (comment marker: IMPACT___USERNAME__)
sed -i '/IMPACT___USERNAME__/d' "$AUTH_KEYS" 2>/dev/null || true

if ! grep -qxF "$NEW_KEY" "$AUTH_KEYS"; then
    echo "$NEW_KEY" >> "$AUTH_KEYS"
    echo KEY_ADDED
else
    echo KEY_ALREADY_EXISTS
fi

chmod 755 "$HOME_DIR"
chmod 700 "$USER_SSH_DIR"
chmod 600 "$AUTH_KEYS"
chmod 644 "$KEY_TARGET_PUB"
chown ${ACTUAL_USER}:${ACTUAL_USER} "$HOME_DIR"
chown -R ${ACTUAL_USER}:${ACTUAL_USER} "$USER_SSH_DIR"

rm -f "$REMOTE_TEMP"
echo SSH_KEY_COPIED
'@
                                $remoteInstallScript = $remoteInstallScript.Replace('__USERNAME__', $State.UserName).Replace('__REMOTE_TEMP__', $remoteTemp)
                                $remoteInstallScript = $remoteInstallScript -replace "`r`n","`n" -replace "`r","`n"
                $cmdResult = Invoke-SSHCommand -SessionId $sshSession.SessionId -Command $remoteInstallScript -TimeOut 60 -ErrorAction Stop
                Write-Log "Posh-SSH install exit=$($cmdResult.ExitStatus); output length=$($cmdResult.Output.Length)" 'Debug'
                if ($cmdResult.Output -match 'SSH_KEY_COPIED') { $keyAuthorized = $true }
            }
        } catch {
            Write-Log "Posh-SSH bootstrap failed: $($_.Exception.Message)" 'Warn'
        } finally {
            if ($sshSession) { try { Remove-SSHSession -SessionId $sshSession.SessionId -ErrorAction SilentlyContinue | Out-Null } catch { } }
            if (Get-Variable tempKeyFile -Scope 0 -ErrorAction SilentlyContinue) { try { Remove-Item $tempKeyFile -Force -ErrorAction SilentlyContinue; Write-Log 'Removed temporary key file.' 'Debug' } catch { } }
        }

        if (-not $keyAuthorized) {
            $plink = Get-Command plink.exe -ErrorAction SilentlyContinue
            if (-not $plink) {
                $puttyPath = "${env:ProgramFiles}\PuTTY\plink.exe"
                if (Test-Path $puttyPath) { $plink = Get-Command $puttyPath -ErrorAction SilentlyContinue }
            }

            if ($plink) {
                $tmpScript = New-TemporaryFile
                Set-Content -Path $tmpScript -Value $remoteScript -NoNewline
                $plinkArgs = @('-batch','-ssh','-pw',$plainPw,$remoteHost,'bash -s')
                $p = Start-Process -FilePath $plink.Source -ArgumentList $plinkArgs -RedirectStandardInput $tmpScript -NoNewWindow -PassThru -Wait
                Remove-Item $tmpScript -Force -ErrorAction SilentlyContinue
                Write-Log "plink bootstrap exit=$($p.ExitCode)" 'Debug'
                if ($p.ExitCode -eq 0) { $keyAuthorized = $true }
            } else {
                $msg = 'Password bootstrap failed because plink.exe is not available. Install PuTTY (plink) or ensure the Posh-SSH module is installed so password-based key setup can proceed.'
                [System.Windows.Forms.MessageBox]::Show($msg,'Password bootstrap unavailable','OK','Error') | Out-Null
                Write-Log $msg 'Error'
                return $false
            }
        }

        if (-not $keyAuthorized) {
            Write-Log 'Password-based bootstrap did not succeed.' 'Error'
            return $false
        }
    }

    Write-Log "SSH key authorized on remote host for user $($State.UserName)." 'Info'

    # SSH config was already validated/created at the top of this function.

    # Sync SSH private key and known_hosts onto remote for Git inside container
    Write-Log 'Syncing SSH private key and known_hosts to remote host.' 'Info'

    if (Test-Path $sshKeyPath) {
        $pkContent = Get-Content $sshKeyPath -Raw
        $pkB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pkContent))
        $copyPrivateCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && rm -f ~/.ssh/id_ed25519_$($State.UserName) && echo '$pkB64' | base64 -d > ~/.ssh/id_ed25519_$($State.UserName) && chmod 600 ~/.ssh/id_ed25519_$($State.UserName) && chown ${remoteUser}:${remoteUser} ~/.ssh/id_ed25519_$($State.UserName) && echo PRIVATE_KEY_COPIED"
        $pkOut = & ssh @sshArgs $copyPrivateCmd 2>&1
        if ($pkOut -notmatch 'PRIVATE_KEY_COPIED') { Write-Log "Remote private key copy may have failed: $pkOut" 'Warn' }
    } else {
        Write-Log "Local private key not found at $sshKeyPath; skipping remote copy." 'Warn'
    }

    $knownHostsPath = Join-Path $HOME '.ssh/known_hosts'
    if (Test-Path $knownHostsPath) {
        $khContent = Get-Content $knownHostsPath -Raw
        $khB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($khContent))
        $copyKhCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && rm -f ~/.ssh/known_hosts && echo '$khB64' | base64 -d > ~/.ssh/known_hosts && chmod 644 ~/.ssh/known_hosts && chown ${remoteUser}:${remoteUser} ~/.ssh/known_hosts && echo KNOWN_HOSTS_COPIED"
        $khOut = & ssh @sshArgs $copyKhCmd 2>&1
        if ($khOut -notmatch 'KNOWN_HOSTS_COPIED') { Write-Log "Remote known_hosts copy may have failed: $khOut" 'Warn' }
    } else {
        $createKhCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && rm -f ~/.ssh/known_hosts && touch ~/.ssh/known_hosts && chmod 644 ~/.ssh/known_hosts && chown ${remoteUser}:${remoteUser} ~/.ssh/known_hosts && echo KNOWN_HOSTS_EMPTY"
        & ssh @sshArgs $createKhCmd 2>&1 | Out-Null
        Write-Log 'Created empty known_hosts on remote host.' 'Debug'
    }

    # 4.1.2: Scan remote repo list
    Write-Log "Scanning remote repositories at $remoteRepoBase" 'Info'
    $listScript = "ls -1d $remoteRepoBase/*/ 2>/dev/null | xargs -n1 basename"
    try {
        $repoList = (& ssh @sshArgs $listScript 2>&1) -split "`n" | Where-Object { $_ -and ($_ -notmatch 'No such file') }
    } catch {
        Write-Log "Repo scan failed: $($_.Exception.Message)" 'Error'
        return $false
    }

    Write-Log "Remote repo count discovered: $($repoList.Count)" 'Debug'

    if (-not $repoList -or $repoList.Count -eq 0) {
        Write-Log "No repositories found under $remoteRepoBase" 'Error'
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
    $listBox.Items.AddRange($repoList)
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
        try {
            & docker context create $contextName --docker "host=ssh://$remoteHost" | Out-Null
            Write-Log "Docker context $contextName created." 'Debug'
        } catch {
            Write-Log "Failed to create docker context, will attempt direct DOCKER_HOST fallback." 'Warn'
        }
    }

    $contextActive = $false
    if ((& docker context ls --format '{{.Name}}' 2>$null) -contains $contextName) {
        try { & docker context use $contextName | Out-Null; $contextActive = $true } catch { $contextActive = $false }
    }

    if (-not $contextActive) {
        Write-Log 'Falling back to direct SSH via DOCKER_HOST.' 'Warn'
        $State.Flags.UseDirectSsh = $true
        Set-DockerSSHEnvironment -State $State
    } else {
        $State.Flags.UseDirectSsh = $false
        Write-Log "Docker context set to $contextName" 'Info'
    }

    # 4.1.5: Verify Docker Engine is installed and running on the remote host
    Write-Log 'Checking remote Docker Engine availability...' 'Info'
    $remoteDockerOk = $false
    $remoteDockerCliExists = $false
    try {
        $sshCheckArgs = @('-i', $State.Paths.SshPrivate, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', $remoteHost)
        $dockerVer = & ssh @sshCheckArgs 'docker version --format "{{.Server.Version}}"' 2>&1
        if ($LASTEXITCODE -eq 0 -and $dockerVer -and $dockerVer -notmatch 'Cannot connect') {
            $remoteDockerOk = $true
            $remoteDockerCliExists = $true
            Write-Log "Remote Docker Engine running (Server version: $dockerVer)" 'Info'
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
    } catch {
        Write-Log "Remote Docker check failed: $($_.Exception.Message)" 'Warn'
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
                $startArgs = @('-i', $State.Paths.SshPrivate, '-o', 'IdentitiesOnly=yes', '-o', 'ConnectTimeout=30', '-t', $remoteHost, 'sudo systemctl start docker')
                $p = Start-Process -FilePath 'ssh' -ArgumentList $startArgs -Wait -PassThru -NoNewWindow
                if ($p.ExitCode -eq 0) {
                    Write-Log 'sudo systemctl start docker completed.' 'Info'
                    # Wait briefly for the daemon socket to become available
                    Start-Sleep -Seconds 3
                    # Re-check
                    $sshCheckArgs2 = @('-i', $State.Paths.SshPrivate, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', $remoteHost)
                    $dockerVer2 = & ssh @sshCheckArgs2 'docker version --format "{{.Server.Version}}"' 2>&1
                    if ($LASTEXITCODE -eq 0 -and $dockerVer2 -and $dockerVer2 -notmatch 'Cannot connect') {
                        $remoteDockerOk = $true
                        Write-Log "Remote Docker Engine started successfully (Server version: $dockerVer2)" 'Info'
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
            [System.Windows.Forms.MessageBox]::Show(
                "Docker daemon could not be started on the remote workstation ($remoteIp).`n`nStart it manually on the remote host:`n  sudo systemctl start docker`n  sudo systemctl enable docker",
                'Docker Daemon Start Failed', 'OK', 'Error') | Out-Null
            return $false
        }
    }

    # 4.1.7: Check docker group membership for the remote user
    Write-Log 'Checking remote user docker group membership...' 'Info'
    try {
        $sshGroupArgs = @('-i', $State.Paths.SshPrivate, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', $remoteHost)
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
    if (Test-Path $documentsPath) {
        $folderBrowser.SelectedPath = $documentsPath
    }

    $folderResult = $folderBrowser.ShowDialog()
    if ($folderResult -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-Log 'Folder selection cancelled.' 'Warn'
        [System.Windows.Forms.MessageBox]::Show('Folder selection is required to continue.', 'Selection Cancelled', 'OK', 'Warning') | Out-Null
        return $false
    }

    $selectedPath = $folderBrowser.SelectedPath
    if ([string]::IsNullOrWhiteSpace($selectedPath) -or -not (Test-Path $selectedPath)) {
        Write-Log 'Invalid folder selection.' 'Error'
        [System.Windows.Forms.MessageBox]::Show('Please select a valid folder containing your repository.', 'Invalid Selection', 'OK', 'Error') | Out-Null
        return $false
    }

    $State.Paths.LocalRepo = $selectedPath
    $State.SelectedRepo = Split-Path $selectedPath -Leaf
    $State.ContainerName = "$($State.SelectedRepo)_$($State.UserName)"
    Write-Log "Local repository path: $($State.Paths.LocalRepo)" 'Info'
    Write-Log "Repository name: $($State.SelectedRepo)" 'Info'

    $gitPath = Join-Path $selectedPath '.git'
    if (-not (Test-Path $gitPath)) {
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
            [System.Windows.Forms.MessageBox]::Show('Docker is not available on this system.`n`nPlease ensure Docker Desktop is installed and running on your Windows machine.', 'Docker Not Available', 'OK', 'Error') | Out-Null
            return $false
        }
        Write-Log "Docker detected: $dockerVersion" 'Info'
    } catch {
        Write-Log "Could not check Docker availability: $($_.Exception.Message)" 'Error'
        [System.Windows.Forms.MessageBox]::Show('Could not verify Docker availability.`n`nPlease ensure Docker Desktop is installed and running on your Windows machine.', 'Docker Check Failed', 'OK', 'Error') | Out-Null
        return $false
    }

    $dockerRunning = $false
    try {
        $quickCheck = & docker version --format "{{.Server.Version}}" 2>$null
        if ($LASTEXITCODE -eq 0 -and $quickCheck) {
            $dockerRunning = $true
            Write-Log "Docker engine is running (Server version: $quickCheck)" 'Info'
        }
    } catch {
        Write-Log "Quick Docker version check failed: $($_.Exception.Message)" 'Debug'
    }

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

            $maxAttempts = 30
            $attempt = 0
            do {
                Start-Sleep -Seconds 1
                $attempt++
                $checkJob = Start-Job -ScriptBlock { & docker info 2>&1 | Out-Null; $LASTEXITCODE }
                $checkResult = Wait-Job $checkJob -Timeout 5
                if ($checkResult) {
                    $checkExitCode = Receive-Job $checkJob
                    Remove-Job $checkJob
                    Write-Log "Docker start check attempt $attempt exit=$checkExitCode" 'Debug'
                    if ($checkExitCode -eq 0) { $dockerRunning = $true; break }
                } else {
                    Stop-Job $checkJob -ErrorAction SilentlyContinue
                    Remove-Job $checkJob -ErrorAction SilentlyContinue
                }
                if ($attempt -eq 10 -or $attempt -eq 20) {
                    Write-Log 'Docker is still starting up...' 'Info'
                }
            } while ($attempt -lt $maxAttempts)

            $finalJob = Start-Job -ScriptBlock { & docker info 2>&1 | Out-Null; $LASTEXITCODE }
            $finalResult = Wait-Job $finalJob -Timeout 5
            if ($finalResult) {
                $finalExitCode = Receive-Job $finalJob
                Remove-Job $finalJob
                $dockerRunning = ($finalExitCode -eq 0)
                Write-Log "Final docker start check exit=$finalExitCode" 'Debug'
            } else {
                Stop-Job $finalJob -ErrorAction SilentlyContinue
                Remove-Job $finalJob -ErrorAction SilentlyContinue
            }

            if (-not $dockerRunning) {
                Write-Log 'Docker engine did not start within the expected time.' 'Warn'
                $choice = [System.Windows.Forms.MessageBox]::Show(
                    "Docker engine could not be started automatically.`n`nWould you like to:`n- Click 'Yes' to wait and try again`n- Click 'No' to continue anyway (may cause errors)`n- Click 'Cancel' to exit",
                    'Docker Startup Issue',
                    'YesNoCancel',
                    'Warning'
                )

                if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
                    [System.Windows.Forms.MessageBox]::Show(
                        'Please start Docker Desktop manually and wait for it to be ready, then click OK to continue.`n`nOr click Cancel to skip Docker checks and continue anyway.',
                        'Manual Start Required',
                        'OKCancel',
                        'Information'
                    ) | Out-Null
                } elseif ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) {
                    Write-Log 'User chose to exit after Docker startup failure.' 'Warn'
                    return $false
                }
            }
        } catch {
            Write-Log "Failed to start Docker Desktop: $($_.Exception.Message)" 'Error'
        }
    }

    if (-not $dockerRunning) {
        Write-Log 'Docker engine may still be unavailable; continuing with caution.' 'Warn'
    } else {
        Write-Log "Docker engine is running (version: $quickCheck)." 'Info'
    }

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

    & docker context use $LocalContextName *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Switched to Docker context '$LocalContextName'." 'Info'
    } else {
        Write-Log "Failed to switch to Docker context '$LocalContextName'." 'Warn'
    }

    & docker --context $LocalContextName version 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Log 'Docker connection test passed.' 'Info'
    } else {
        Write-Log 'Docker connection test failed.' 'Warn'
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

    $portUsers = @()
    try {
        $psCmd = $ctxArgs + @('ps','--format','{{.Names}}\t{{.Ports}}')
        $all = & docker @psCmd 2>$null
        if ($LASTEXITCODE -eq 0 -and $all) {
            foreach ($line in ($all -split "`n")) {
                if ($line -match '0\.0\.0\.0:(\d{4})->8787/tcp') {
                    $port = $matches[1]
                    if ($portUsers -notcontains $port) { $portUsers += $port }
                }
            }
        }
    } catch {
        Write-Log "Port scan failed: $($_.Exception.Message)" 'Warn'
    }
    Write-Log "Discovered in-use ports: $([string]::Join(',', $portUsers))" 'Debug'
    $State.Ports.Used = $portUsers

    # Collect containers for this user
    $pattern = "_$($State.UserName)"
    # Use raw format (no table header/padding) so parsing stays reliable
    $psAll = $ctxArgs + @('ps','-a','--filter',"name=$pattern",'--format','{{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}')

    $State.Metadata.ExistingContainers = @()
    try {
        $out = & docker @psAll 2>$null
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
        $name = & docker @psRunning 2>$null
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

    # If running, attempt to recover connection details
    if ($isRunning) {
        # Pre-seed recovered fields so strict mode does not throw on missing properties
        $State.Metadata.Recovered = @{ Password = $null; Port = $null; UseVolumes = $false }
        if ($State.ContainerLocation -like 'REMOTE@*') {
            $meta = Read-RemoteContainerMetadata -State $State
            if ($meta) {
                $State.Metadata.Recovered.Password = $meta.password
                $State.Metadata.Recovered.Port = $meta.port
                $State.Metadata.Recovered.UseVolumes = $meta.useVolumes
            }
        }
        if (-not $State.Metadata.Recovered.Password -or -not $State.Metadata.Recovered.Port) {
            $runtime = Get-ContainerRuntimeInfo -State $State
            if ($runtime.Password) { $State.Metadata.Recovered.Password = $runtime.Password }
            if ($runtime.Port) { $State.Metadata.Recovered.Port = $runtime.Port }
        }
    }
    return $State
}

# 6. Container management UI
function Show-ContainerManager {
    param([pscustomobject]$State)
    if (-not $State.Metadata.ContainsKey('Recovered') -or -not $State.Metadata.Recovered) {
        $State.Metadata.Recovered = @{ UseVolumes = $false; Password = $null; Port = $null }
    }
    if (-not $State.Metadata.ContainsKey('ActivePort')) { $State.Metadata.ActivePort = $null }
    if (-not $State.Metadata.ContainsKey('ActiveUseVolumes')) { $State.Metadata.ActiveUseVolumes = $false }
    if (-not $State.Metadata.ContainsKey('ActiveRepoPath')) { $State.Metadata.ActiveRepoPath = $null }
    if (-not $State.Metadata.ContainsKey('ActiveIsRemote')) { $State.Metadata.ActiveIsRemote = $false }
    Write-Log 'Opening container manager UI.' 'Info'
    $isRunning = $State.Metadata.ContainerRunning
    if ($isRunning) {
        $portDisplay = if ($State.Metadata.Recovered.Port) { ($State.Metadata.Recovered.Port -split '\s+')[0] } else { '8787' }
        $passDisplay = if ($State.Metadata.Recovered.Password) { $State.Metadata.Recovered.Password } else { $State.Password }
        $hostDisplay = if ($State.ContainerLocation -eq 'LOCAL') { "http://localhost:$portDisplay" } else { "http://$($State.RemoteHostIp):$portDisplay" }
        [System.Windows.Forms.MessageBox]::Show("Container '$($State.ContainerName)' already running.`n`nURL: $hostDisplay`nUser: rstudio`nPassword: $passDisplay","Container already running",'OK','Information') | Out-Null
        Write-Log "Resumed existing container $($State.ContainerName) at $hostDisplay" 'Info'
        $State.Metadata.ActiveRepoPath = if ($State.ContainerLocation -eq 'LOCAL') { $State.Paths.LocalRepo } else { $State.Paths.RemoteRepo }
        $State.Metadata.ActiveIsRemote = ($State.ContainerLocation -like 'REMOTE@*')
        $State.Metadata.ActiveUseVolumes = $State.Metadata.Recovered.UseVolumes
        $State.Metadata.ActivePort = $portDisplay
        if ($State.Metadata.Recovered.UseVolumes) {
            # Ensure expected volume names are populated for recovered sessions
            $State.Metadata.VolumeOutput = "impactncd_germany_output_$($State.UserName)" -replace '[^a-zA-Z0-9_]','_'
            $State.Metadata.VolumeSynthpop = "impactncd_germany_synthpop_$($State.UserName)" -replace '[^a-zA-Z0-9_]','_'
        }
    }

    $form = New-Object System.Windows.Forms.Form -Property @{
        Text = 'Container Management - IMPACT NCD Germany'
        Size = New-Object System.Drawing.Size(540,500)
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

    $lblPort = New-Object System.Windows.Forms.Label -Property @{ Text='Port Override'; Location=New-Object System.Drawing.Point(20,304); Size=New-Object System.Drawing.Size(110,22) }
    $defaultPort = if ($State.Metadata.Recovered.Port) { $State.Metadata.Recovered.Port } else { '8787' }
    $txtPort = New-Object System.Windows.Forms.TextBox -Property @{ Location=New-Object System.Drawing.Point(136,302); Size=New-Object System.Drawing.Size(90,24); Text=$defaultPort }
    Style-Label -Label $lblPort
    Style-TextBox -TextBox $txtPort
    $form.Controls.Add($lblPort); $form.Controls.Add($txtPort)

    $isLocal = ($State.ContainerLocation -eq 'LOCAL')
    if ($isLocal) {
        $txtPort.Enabled = $false
        $chkHigh.Enabled = $false
    }

    $lblParams = New-Object System.Windows.Forms.Label -Property @{ Text='Custom Params'; Location=New-Object System.Drawing.Point(238,304); Size=New-Object System.Drawing.Size(110,22) }
    $txtParams = New-Object System.Windows.Forms.TextBox -Property @{ Location=New-Object System.Drawing.Point(354,302); Size=New-Object System.Drawing.Size(150,24) }
    Style-Label -Label $lblParams
    Style-TextBox -TextBox $txtParams
    $form.Controls.Add($lblParams); $form.Controls.Add($txtParams)

    $defaultYaml = if ($isLocal) { '.\inputs\sim_design_local.yaml' } else { '.\inputs\sim_design.yaml' }
    $lblYaml = New-Object System.Windows.Forms.Label -Property @{ Text='sim_design.yaml'; Location=New-Object System.Drawing.Point(20,336); Size=New-Object System.Drawing.Size(130,22) }
    $txtYaml = New-Object System.Windows.Forms.TextBox -Property @{ Location=New-Object System.Drawing.Point(152,334); Size=New-Object System.Drawing.Size(352,24); Text=$defaultYaml }
    Style-Label -Label $lblYaml
    Style-TextBox -TextBox $txtYaml
    $form.Controls.Add($lblYaml); $form.Controls.Add($txtYaml)

    $lblStatus = New-Object System.Windows.Forms.Label -Property @{ Text=''; Location=New-Object System.Drawing.Point(20,410); Size=New-Object System.Drawing.Size(460,26) }
    Style-Label -Label $lblStatus
    $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
    $form.Controls.Add($lblStatus)

    $buildInfo = $State.Metadata.BuildInfo
    $footerText = if ($buildInfo) { "Build: $($buildInfo.Version) | Commit: $($buildInfo.Commit) | Built: $($buildInfo.Built)" } else { 'Build: unknown' }
    $lblFooter = New-Object System.Windows.Forms.Label -Property @{ Text=$footerText; Location=New-Object System.Drawing.Point(20,440); Size=New-Object System.Drawing.Size(460,22) }
    Style-Label -Label $lblFooter -Muted:$true
    $form.Controls.Add($lblFooter)

    $btnClose = New-Object System.Windows.Forms.Button -Property @{ Text='Close'; Location=New-Object System.Drawing.Point(414,374); Size=New-Object System.Drawing.Size(90,34) }
    Style-Button -Button $btnClose -Variant 'secondary'
    $form.Controls.Add($btnClose)
    $form.AcceptButton = $btnClose
    $form.CancelButton = $btnClose

    $form.Add_FormClosing({
        if ($State.Metadata.ContainerRunning) {
            $answer = [System.Windows.Forms.MessageBox]::Show('A container is still running. Close without stopping?','Container running','YesNo','Warning')
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { $_.Cancel = $true }
        }
    })

    function Update-InfoBox {
        param($Status)
        $info.Clear()
        $info.SelectionFont = New-Object System.Drawing.Font('Segoe UI Semibold',10,[System.Drawing.FontStyle]::Bold)

        $passDisplay = if ($State.Metadata.Recovered.Password) { $State.Metadata.Recovered.Password } else { $State.Password }
        $portDisplay = if ($State.Metadata.ActivePort) { $State.Metadata.ActivePort } elseif ($State.Metadata.Recovered.Port) { ($State.Metadata.Recovered.Port -split '\s+')[0] } else { '8787' }
        $hostDisplay = if ($State.ContainerLocation -eq 'LOCAL') { "http://localhost:$portDisplay" } else { "http://$($State.RemoteHostIp):$portDisplay" }

        # Status line with emphasis
        $info.SelectionColor = if ($Status -eq 'RUNNING') { [System.Drawing.Color]::LightGreen } else { [System.Drawing.Color]::Orange }
        $info.AppendText("Status: $Status`n")

        $info.SelectionColor = $form.ForeColor
        $info.SelectionFont = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Regular)
        $info.AppendText("URL: $hostDisplay`n")
        $info.AppendText("RStudio login: rstudio (Password: $passDisplay)`n")
        $info.AppendText("Repo: $($State.SelectedRepo)`n")
        $info.AppendText("Container: $($State.ContainerName)`n")
        $info.AppendText("Location: $($State.ContainerLocation)`n")
    }
    Update-InfoBox -Status ($(if($isRunning){'RUNNING'}else{'STOPPED'}))
    $lblStatus.Text = ''

    $btnStart.Add_Click({
        $useVolumes = $chkVolumes.Checked
        $rebuild    = $chkRebuild.Checked
        $highComp   = $chkHigh.Checked
        $portOverride = $txtPort.Text.Trim()
        if ($State.ContainerLocation -eq 'LOCAL') { $portOverride = '8787' }
        $customParams = $txtParams.Text.Trim()
        $simDesign = $txtYaml.Text.Trim()

        Write-Log ("Start clicked with options -> volumes={0} rebuild={1} highComp={2} port={3} params='{4}' yaml='{5}'" -f $useVolumes,$rebuild,$highComp,$portOverride,$customParams,$simDesign) 'Debug'

        Set-DockerSSHEnvironment -State $State

        if ($State.Metadata.ContainerRunning) {
            [System.Windows.Forms.MessageBox]::Show('Container already running; stop it first or close to reuse.','Already running','OK','Information') | Out-Null
            return
        }

        if ($portOverride -and $State.Ports.Used -contains $portOverride) {
            [System.Windows.Forms.MessageBox]::Show("Port $portOverride is already in use. Choose another.", 'Port conflict', 'OK', 'Error') | Out-Null
            return
        }

        if ($State.ContainerLocation -like 'REMOTE@*') {
            if (-not (Test-RemoteSSHKeyFiles -State $State)) {
                [System.Windows.Forms.MessageBox]::Show('Remote SSH key or known_hosts missing. Re-run key setup.', 'SSH missing', 'OK', 'Error') | Out-Null
                return
            }
        }

        $otherRunning = $State.Metadata.ExistingContainers | Where-Object { $_.Name -ne $State.ContainerName -and $_.Status -match '^Up' }
        if ($otherRunning -and $otherRunning.Count -gt 0) {
            $names = ($otherRunning | ForEach-Object { $_.Name }) -join ', '
            $choice = [System.Windows.Forms.MessageBox]::Show("Other containers are running: $names`nContinue starting another?",'Other containers running','YesNo','Warning')
            if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        $projectRoot = if ($State.ContainerLocation -eq 'LOCAL') { $State.Paths.LocalRepo } else { $State.Paths.RemoteRepo }
        if (-not $projectRoot) { [System.Windows.Forms.MessageBox]::Show('Repository path missing; restart and select again.','Missing path','OK','Error') | Out-Null; return }
        $dockerSetup = if ($State.ContainerLocation -eq 'LOCAL') { Join-Path $projectRoot 'docker_setup' } else { "$projectRoot/docker_setup" }
        if ($State.ContainerLocation -eq 'LOCAL' -and -not (Test-Path $dockerSetup)) {
            [System.Windows.Forms.MessageBox]::Show("docker_setup folder not found at $dockerSetup","Missing docker_setup",'OK','Error') | Out-Null; return
        }

        # resolve sim_design.yaml
        if (-not [System.IO.Path]::IsPathRooted($simDesign)) {
            $simDesign = ($projectRoot.TrimEnd('/','\') + '/' + ($simDesign -replace '\\','/')) -replace '/+','/'
            if ($State.ContainerLocation -eq 'LOCAL') {
                $resolved = Resolve-Path -Path $simDesign -ErrorAction SilentlyContinue
                if ($resolved) { $simDesign = $resolved.Path }
            }
        }
        if ($State.ContainerLocation -eq 'LOCAL' -and -not (Test-Path $simDesign)) {
            [System.Windows.Forms.MessageBox]::Show("YAML file not found at $simDesign",'Missing YAML','OK','Error') | Out-Null; return
        }

        # Build image name
        $imageName = $State.SelectedRepo.ToLower()

        # Check image exists unless rebuild
        $imageExists = $false
        if (-not $rebuild) {
            $imgCmd = (Get-DockerContextArgs -State $State) + @('images','--format','{{.Repository}}')
            try {
                $imgs = & docker @imgCmd 2>$null | Where-Object { $_ -eq $imageName }
                $imageExists = [bool]$imgs
            } catch { $imageExists = $false }
        }

        $dockerfileMain = if ($State.ContainerLocation -eq 'LOCAL') { Join-Path $dockerSetup 'Dockerfile.IMPACTncdGER' } else { "$dockerSetup/Dockerfile.IMPACTncdGER" }
        $dockerContext  = $projectRoot
        if (-not $dockerContext) {
            [System.Windows.Forms.MessageBox]::Show('Repository path missing; cannot build image.','Missing path','OK','Error') | Out-Null
            return
        }

        if (-not $imageExists) {
            Write-Log "Building image $imageName (streaming output)..." 'Info'
            # Build args as single string with quoted paths to survive spaces (parity with v1 streaming)
            $buildArgsString = "build --build-arg REPO_NAME=$($State.SelectedRepo) -f `"$dockerfileMain`" -t $imageName --no-cache --progress=plain `".`""
            $buildSucceeded = $false
            $buildStart = Get-Date
            try {
                if ($State.ContainerLocation -eq 'LOCAL') {
                    # Stream docker build output directly to console (parity with v1)
                    Push-Location $dockerContext
                    try {
                        $p = Start-Process -FilePath 'docker' -ArgumentList $buildArgsString -Wait -PassThru -NoNewWindow
                        $buildSucceeded = ($p.ExitCode -eq 0)
                    } finally { Pop-Location }
                } else {
                    $remoteHost = Get-RemoteHostString -State $State
                    $sshKey = $State.Paths.SshPrivate
                    $cmd = "cd '$dockerContext' && docker build --build-arg REPO_NAME=$($State.SelectedRepo) -f '$dockerfileMain' -t '$imageName' --no-cache ."
                    $sshArgs = @('-o','ConnectTimeout=30','-o','BatchMode=yes','-o','PasswordAuthentication=no','-o','PubkeyAuthentication=yes','-o','IdentitiesOnly=yes','-i',"$sshKey",$remoteHost,$cmd)
                    $p = Start-Process -FilePath 'ssh' -ArgumentList $sshArgs -Wait -NoNewWindow -PassThru
                    $buildSucceeded = ($p.ExitCode -eq 0)
                }
            } catch {
                $buildSucceeded = $false
            }

            if (-not $buildSucceeded) {
                Write-Log 'Main image build failed; attempting prerequisite build fallback.' 'Warn'
                $prereqDockerfile = if ($State.ContainerLocation -eq 'LOCAL') { Join-Path $dockerSetup 'Dockerfile.prerequisite.IMPACTncdGER' } else { "$dockerSetup/Dockerfile.prerequisite.IMPACTncdGER" }
                $prereqContext = if ($State.ContainerLocation -eq 'LOCAL') { Join-Path $dockerSetup '.' } else { "$dockerSetup" }
                $prereqArgsString = "build -f `"$prereqDockerfile`" -t $imageName-prerequisite --no-cache --progress=plain `".`""
                $preSuccess = $false
                try {
                    if ($State.ContainerLocation -eq 'LOCAL') {
                        Push-Location $prereqContext
                        try {
                            $p2 = Start-Process -FilePath 'docker' -ArgumentList $prereqArgsString -Wait -PassThru -NoNewWindow
                            $preSuccess = ($p2.ExitCode -eq 0)
                        } finally { Pop-Location }
                    } else {
                        $remoteHost = Get-RemoteHostString -State $State
                        $sshKey = $State.Paths.SshPrivate
                        $cmd2 = "cd '$prereqContext' && docker build -f '$prereqDockerfile' -t '$imageName-prerequisite' --no-cache ."
                        $sshArgs2 = @('-o','ConnectTimeout=30','-o','BatchMode=yes','-o','PasswordAuthentication=no','-o','PubkeyAuthentication=yes','-o','IdentitiesOnly=yes','-i',"$sshKey",$remoteHost,$cmd2)
                        $p2 = Start-Process -FilePath 'ssh' -ArgumentList $sshArgs2 -Wait -NoNewWindow -PassThru
                        $preSuccess = ($p2.ExitCode -eq 0)
                    }
                } catch { $preSuccess = $false }

                if (-not $preSuccess) {
                    [System.Windows.Forms.MessageBox]::Show('Docker build failed (including prerequisite fallback).','Build failed','OK','Error') | Out-Null
                    return
                }

                # Retry main build after prerequisite
                try {
                    if ($State.ContainerLocation -eq 'LOCAL') {
                        Push-Location $dockerContext
                        try {
                            $p3 = Start-Process -FilePath 'docker' -ArgumentList $buildArgsString -Wait -PassThru -NoNewWindow
                            $buildSucceeded = ($p3.ExitCode -eq 0)
                        } finally { Pop-Location }
                    } else {
                        $remoteHost = Get-RemoteHostString -State $State
                        $sshKey = $State.Paths.SshPrivate
                        $cmd3 = "cd '$dockerContext' && docker build --build-arg REPO_NAME=$($State.SelectedRepo) -f '$dockerfileMain' -t '$imageName' --no-cache ."
                        $sshArgs3 = @('-o','ConnectTimeout=30','-o','BatchMode=yes','-o','PasswordAuthentication=no','-o','PubkeyAuthentication=yes','-o','IdentitiesOnly=yes','-i',"$sshKey",$remoteHost,$cmd3)
                        $p3 = Start-Process -FilePath 'ssh' -ArgumentList $sshArgs3 -Wait -NoNewWindow -PassThru
                        $buildSucceeded = ($p3.ExitCode -eq 0)
                    }
                } catch { $buildSucceeded = $false }
            }

            $elapsed = (Get-Date) - $buildStart
            Write-Log "Docker build duration: $([int]$elapsed.TotalSeconds)s" 'Info'
            Write-Log "Docker build success=$buildSucceeded" 'Debug'
            if (-not $buildSucceeded) {
                [System.Windows.Forms.MessageBox]::Show('Docker build failed. See console output for details.','Build failed','OK','Error') | Out-Null
                return
            }
        }

        # Capture git baseline best-effort
        $State.Metadata.GitBaseline = $null
        try {
            if ($State.ContainerLocation -eq 'LOCAL') {
                Push-Location $projectRoot
                $hash = git rev-parse HEAD 2>$null
                $status = git status --porcelain 2>$null
                Pop-Location
                $State.Metadata.GitBaseline = @{ Repo=$projectRoot; Commit=$hash; Status=$status; Timestamp=Get-Date }
            } else {
                $remoteHost = Get-RemoteHostString -State $State
                $keyPath = $State.Paths.SshPrivate
                $hash = & ssh -i $keyPath -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes $remoteHost "cd '$projectRoot' && git rev-parse HEAD" 2>$null
                $status = & ssh -i $keyPath -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes $remoteHost "cd '$projectRoot' && git status --porcelain" 2>$null
                $State.Metadata.GitBaseline = @{ Repo=$projectRoot; Commit=$hash; Status=$status; Timestamp=Get-Date }
            }
            Write-Log "Captured git baseline: commit=$hash" 'Debug'
        } catch {
            Write-Log "Git baseline capture failed: $($_.Exception.Message)" 'Debug'
            $State.Metadata.GitBaseline = $null
        }

        # Resolve output/synthpop from sim_design
        $baseDirForYaml = ($projectRoot -replace '\\','/')
        $outputDir = Get-YamlPathValue -State $State -YamlPath $simDesign -Key 'output_dir' -BaseDir $baseDirForYaml
        $synthDir  = Get-YamlPathValue -State $State -YamlPath $simDesign -Key 'synthpop_dir' -BaseDir $baseDirForYaml
        if (-not (Test-AndCreateDirectory -State $State -Path $outputDir -PathKey 'output_dir')) { [System.Windows.Forms.MessageBox]::Show('Failed to ensure output_dir.','Path error','OK','Error') | Out-Null; return }
        if (-not (Test-AndCreateDirectory -State $State -Path $synthDir -PathKey 'synthpop_dir')) { [System.Windows.Forms.MessageBox]::Show('Failed to ensure synthpop_dir.','Path error','OK','Error') | Out-Null; return }

        $State.Paths.OutputDir = $outputDir
        $State.Paths.SynthpopDir = $synthDir

        $repoMountSource = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $projectRoot } else { $projectRoot }

        # Use a writable path for the SSH key inside the container so permissions can be fixed for the rstudio user (uid 1000)
        $containerKeyPath = "/home/rstudio/.ssh/id_ed25519_$($State.UserName)"
        $dockerArgs = @('run','-d','--rm','--name',$State.ContainerName,
            '-e',"PASSWORD=$($State.Password)",
            '-e','DISABLE_AUTH=false',
            '-e','USERID=1000','-e','GROUPID=1000',
            '-e',"GIT_SSH_COMMAND=ssh -i $containerKeyPath -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts -o StrictHostKeyChecking=yes",
            '--mount',"type=bind,source=$repoMountSource,target=/host-repo",
            '--mount',"type=bind,source=$repoMountSource,target=/home/rstudio/$($State.SelectedRepo)",
            '-e','REPO_SYNC_PATH=/host-repo','-e','SYNC_ENABLED=true',
            '-p',($(if($portOverride){$portOverride}else{'8787'}) + ':8787')
        )

        if ($customParams) {
            $dockerArgs += ($customParams -split '\s+')
        }

        if ($State.ContainerLocation -eq 'LOCAL') {
            $sshKeyPath = $State.Paths.SshPrivate
            $knownHostsPath = "$HOME/.ssh/known_hosts"
        } else {
            $sshKeyPath = "/home/$($State.RemoteUser)/.ssh/id_ed25519_$($State.UserName)"
            $knownHostsPath = "/home/$($State.RemoteUser)/.ssh/known_hosts"
        }

        if ($useVolumes) {
            $volOut = "impactncd_germany_output_$($State.UserName)" -replace '[^a-zA-Z0-9_]','_'
            $volSyn = "impactncd_germany_synthpop_$($State.UserName)" -replace '[^a-zA-Z0-9_]','_'
            $State.Metadata.VolumeOutput = $volOut
            $State.Metadata.VolumeSynthpop = $volSyn

            $ctxPrefix = Get-DockerContextArgs -State $State

            # Ensure rsync-alpine exists (for later sync)
            Write-Log 'Checking/building rsync-alpine helper image.' 'Debug'
            & docker @ctxPrefix @('image','inspect','rsync-alpine') 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Log 'rsync-alpine image not found; building inline.' 'Debug'
                $dockerfileInline = "FROM alpine:latest`nRUN apk add --no-cache rsync"
                if ($State.ContainerLocation -like 'REMOTE@*') {
                    $dockerfileInline | & docker @ctxPrefix @('build','-t','rsync-alpine','-f','-','.')
                } else {
                    $dockerfileInline | & docker build -t rsync-alpine -f - .
                }
            }

            Write-Log "Creating Docker volumes: $volOut, $volSyn" 'Debug'
            & docker @ctxPrefix @('volume','rm',$volOut,'-f') 2>$null
            & docker @ctxPrefix @('volume','rm',$volSyn,'-f') 2>$null
            & docker @ctxPrefix @('volume','create',$volOut) | Out-Null
            & docker @ctxPrefix @('volume','create',$volSyn) | Out-Null

            # Fix ownership
            Write-Log 'Setting volume ownership (chown 1000:1000).' 'Debug'
            & docker @ctxPrefix @('run','--rm','-v',"${volOut}:/volume",'alpine','sh','-c',"chown 1000:1000 /volume") 2>$null
            & docker @ctxPrefix @('run','--rm','-v',"${volSyn}:/volume",'alpine','sh','-c',"chown 1000:1000 /volume") 2>$null

            # Pre-populate volumes from host dirs
            Write-Log 'Pre-populating volumes from host directories.' 'Debug'
            $dockerOutputSource = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $outputDir } else { $outputDir }
            $dockerSynthSource  = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $synthDir } else { $synthDir }
            & docker @ctxPrefix @('run','--rm','--user','1000:1000','-v',"${dockerOutputSource}:/source",'-v',"${volOut}:/volume",'alpine','sh','-c','cp -r /source/. /volume/ 2>/dev/null || cp -a /source/. /volume/ 2>/dev/null || true') 2>$null
            & docker @ctxPrefix @('run','--rm','--user','1000:1000','-v',"${dockerSynthSource}:/source",'-v',"${volSyn}:/volume",'alpine','sh','-c','cp -r /source/. /volume/ 2>/dev/null || cp -a /source/. /volume/ 2>/dev/null || true') 2>$null

            $dockerArgs += @('-v',"$($volOut):/home/rstudio/$($State.SelectedRepo)/outputs",
                             '-v',"$($volSyn):/home/rstudio/$($State.SelectedRepo)/inputs/synthpop")
        } else {
            $outDocker = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $outputDir } else { $outputDir }
            $synDocker = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $synthDir } else { $synthDir }
            # repo already mounted above; only bind outputs and synthpop to avoid duplicate mount targets
            $dockerArgs += @('--mount',"type=bind,source=$outDocker,target=/home/rstudio/$($State.SelectedRepo)/outputs",
                             '--mount',"type=bind,source=$synDocker,target=/home/rstudio/$($State.SelectedRepo)/inputs/synthpop")
        }

        if ($highComp -and $State.ContainerLocation -like 'REMOTE@*') {
            $dockerArgs += @('--cpus','32','-m','384g')
        }

        $dockerArgs += @('--mount',"type=bind,source=$sshKeyPath,target=/keys/id_ed25519_$($State.UserName),readonly",
                         '--mount',"type=bind,source=$knownHostsPath,target=/etc/ssh/ssh_known_hosts,readonly",
                         '--workdir',"/home/rstudio/$($State.SelectedRepo)",
                         $imageName)

        $runCmd = (Get-DockerContextArgs -State $State) + $dockerArgs
        Write-Log "Starting container with: docker $($runCmd -join ' ')" 'Debug'

        $rc = & docker $runCmd 2>&1
        if ($LASTEXITCODE -ne 0) {
            [System.Windows.Forms.MessageBox]::Show("Failed to start container: $rc",'Container start failed','OK','Error') | Out-Null
            return
        }

        # Copy the SSH key from the readonly bind mount to a writable location with correct ownership.
        # The bind mount preserves host-side ownership (e.g. php-workstation), but inside the container
        # the rstudio user (uid 1000) needs to own the private key for SSH to accept it.
        $fixKeyCmd = "mkdir -p /home/rstudio/.ssh && cp /keys/id_ed25519_$($State.UserName) $containerKeyPath && chmod 600 $containerKeyPath && chown 1000:1000 $containerKeyPath && cp /etc/ssh/ssh_known_hosts /home/rstudio/.ssh/known_hosts 2>/dev/null; chmod 644 /home/rstudio/.ssh/known_hosts 2>/dev/null; chown 1000:1000 /home/rstudio/.ssh/known_hosts 2>/dev/null; echo KEY_FIXED"
        $fixCtx = (Get-DockerContextArgs -State $State) + @('exec', $State.ContainerName, 'sh', '-c', $fixKeyCmd)
        try {
            $fixOut = & docker $fixCtx 2>&1
            if ($fixOut -match 'KEY_FIXED') {
                Write-Log 'SSH key permissions fixed inside container.' 'Info'
            } else {
                Write-Log "SSH key permission fix may have failed: $fixOut" 'Warn'
            }
        } catch {
            Write-Log "SSH key permission fix failed: $($_.Exception.Message)" 'Warn'
        }

        # Configure git inside the container for the rstudio user.
        # - pull.rebase=false  → use merge strategy (same as GitKraken default), avoids
        #   the "divergent branches" error on git pull with newer git (2.27+).
        # - safe.directory='*' → allows rstudio to operate on bind-mounted repos
        #   even if the directory ownership doesn't match.
        $gitCfgCmd = "git config --global pull.rebase false && git config --global --add safe.directory '*' && echo GIT_CONFIGURED"
        $gitCfgCtx = (Get-DockerContextArgs -State $State) + @('exec', '--user', 'rstudio', $State.ContainerName, 'sh', '-c', $gitCfgCmd)
        try {
            $gitCfgOut = & docker $gitCfgCtx 2>&1
            if ($gitCfgOut -match 'GIT_CONFIGURED') {
                Write-Log 'Git pull strategy (merge) configured inside container.' 'Info'
            } else {
                Write-Log "Git config inside container may have failed: $gitCfgOut" 'Warn'
            }
        } catch {
            Write-Log "Git config inside container failed: $($_.Exception.Message)" 'Warn'
        }

        if ($State.ContainerLocation -like 'REMOTE@*') {
            $portStore = if ($portOverride) { $portOverride } else { '8787' }
            Write-RemoteContainerMetadata -State $State -Password $State.Password -Port $portStore -UseVolumes $useVolumes
        }

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
        Write-Host "Container ready: $hostDisplay (user: rstudio, password: $($State.Password))" -ForegroundColor Green
    })

    $btnStop.Add_Click({
        $ctxArgs = Get-DockerContextArgs -State $State
        $runCmd = $ctxArgs + @('ps','--filter',"name=^$($State.ContainerName)$",'--format','{{.Names}}')
        $exists = & docker $runCmd 2>$null
        if (-not $exists) { Update-InfoBox -Status 'STOPPED'; $btnStart.Enabled=$true; $btnStop.Enabled=$false; return }

        $stopCmd = $ctxArgs + @('stop',$State.ContainerName)
        Write-Log "Stopping container $($State.ContainerName)" 'Info'
        & docker $stopCmd 2>$null
        Write-Log "docker stop exit=$LASTEXITCODE" 'Debug'
        if ($LASTEXITCODE -ne 0) {
            [System.Windows.Forms.MessageBox]::Show('Failed to stop container; check Docker.','Stop failed','OK','Error') | Out-Null
            return
        }

        # Sync volumes back if used
        $useVolumesForStop = if ($State.Metadata.ActiveUseVolumes -ne $null) { $State.Metadata.ActiveUseVolumes } else { $chkVolumes.Checked }
        Write-Log "Stop clicked; volumesUsed=$useVolumesForStop" 'Debug'
        if ($useVolumesForStop) {
            $ctxPrefix = Get-DockerContextArgs -State $State
            if (-not $State.Metadata.VolumeOutput) {
                $State.Metadata.VolumeOutput = "impactncd_germany_output_$($State.UserName)" -replace '[^a-zA-Z0-9_]','_'
            }
            if (-not $State.Metadata.VolumeSynthpop) {
                $State.Metadata.VolumeSynthpop = "impactncd_germany_synthpop_$($State.UserName)" -replace '[^a-zA-Z0-9_]','_'
            }

            $volOut = $State.Metadata.VolumeOutput
            $volSyn = $State.Metadata.VolumeSynthpop
            if ($volOut -and $volSyn) {
                $outBackup = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $State.Paths.OutputDir } else { $State.Paths.OutputDir }
                $synBackup = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $State.Paths.SynthpopDir } else { $State.Paths.SynthpopDir }
                Write-Log "Syncing volumes back -> outVol=$volOut to $outBackup; synVol=$volSyn to $synBackup" 'Debug'
                Write-Log "Syncing volume $volOut back to $outBackup" 'Debug'
                & docker @ctxPrefix @('run','--rm','-v',"$($volOut):/volume",'-v',"$($outBackup):/backup",'rsync-alpine','rsync','-avc','--no-owner','--no-group','--no-times','--no-perms','--chmod=ugo=rwX','/volume/','/backup/') 2>$null
                Write-Log "Syncing volume $volSyn back to $synBackup" 'Debug'
                & docker @ctxPrefix @('run','--rm','-v',"$($volSyn):/volume",'-v',"$($synBackup):/backup",'rsync-alpine','rsync','-avc','--no-owner','--no-group','--no-times','--no-perms','--chmod=ugo=rwX','/volume/','/backup/') 2>$null
                & docker @ctxPrefix @('volume','rm',$volOut,$volSyn,'-f') 2>$null
                Write-Log "Removed volumes $volOut, $volSyn after sync." 'Debug'
            }
        }

        $State.Metadata.ContainerRunning = $false

        if ($State.ContainerLocation -like 'REMOTE@*') { Remove-RemoteContainerMetadata -State $State }

        Update-InfoBox -Status 'STOPPED'
        $btnStart.Enabled = $true
        $btnStop.Enabled  = $false
        Write-Log "Container $($State.ContainerName) stopped." 'Info'

        if ($State.Metadata.ActiveRepoPath) {
            Invoke-GitChangeDetection -State $State -RepoPath $State.Metadata.ActiveRepoPath -IsRemote $State.Metadata.ActiveIsRemote
        }

        $lblStatus.Text = 'All done. You can close this window or start another container.'
        Write-Host "All done. You can close this window or start another container." -ForegroundColor Green
    })

    $btnClose.Add_Click({ $form.Close() })

    $null = $form.ShowDialog()
}

# Coordinator: orchestrates all steps with clear sequencing and early validation.
function Invoke-ImpactGui {
    Write-Log 'Starting IMPACT Docker GUI workflow.' 'Info'
    Ensure-PowerShell7 -PS7RequestedFlag:$PS7Requested.IsPresent
    $state = New-SessionState

    $state.Metadata.BuildInfo = Get-BuildInfo
    $bi = $state.Metadata.BuildInfo
    Write-Log ("Build info -> Version={0} Commit={1} Built={2}" -f $bi.Version, $bi.Commit, $bi.Built) 'Info'

    if (-not (Ensure-Prerequisites -State $state)) { return }
    if (-not (Show-CredentialDialog -State $state)) { return }
    if (-not (Ensure-GitKeySetup -State $state)) { return }
    if (-not (Select-Location -State $state)) { return }

    if ($state.ContainerLocation -like 'REMOTE@*') {
           if (-not (Ensure-RemotePreparation -State $state)) { return }
    } elseif ($state.ContainerLocation -eq 'LOCAL') {
        if (-not (Ensure-LocalPreparation -State $state)) { return }
    } else {
        Write-Log "No container location selected; exiting." 'Warn'
        return
    }

    Get-ContainerStatus -State $state
    Show-ContainerManager -State $state
}

Invoke-ImpactGui
