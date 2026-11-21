# IMPACT Docker GUI v2: Technical Documentation

Engineering reference for the IMPACT Docker GUI: architecture, session state, functions, workflow internals, security, and extension points. For end-user instructions see the [User Guide](IMPACT_Docker_GUI_v2_User.md); for tests see the [Testing Guide](TESTING.md).

Line numbers are deliberately not given: they change with every edit. Search for the function name instead.

---

## Contents

1. [Architecture](#architecture)
2. [Launchers and PowerShell version](#launchers-and-powershell-version)
3. [Session state: `New-SessionState`](#session-state-new-sessionstate)
4. [Function reference](#function-reference)
5. [Workflow](#workflow)
6. [Inside the container: SSH and git setup](#inside-the-container-ssh-and-git-setup)
7. [Docker volumes and container labels](#docker-volumes-and-container-labels)
8. [Git change detection](#git-change-detection)
9. [Logging](#logging)
10. [Security considerations](#security-considerations)
11. [Error handling patterns](#error-handling-patterns)
12. [Dependencies](#dependencies)
13. [Extension points](#extension-points)
14. [Known limitations](#known-limitations)

---

## Architecture

```
IMPACT.bat  (cmd launcher: finds pwsh 7.3+, pauses on errors)
   |
   v
IMPACT_Docker_GUI_v2.ps1  (GUI script, PowerShell 7, StrictMode Latest, ErrorAction Stop)
   |  imports
   v
IMPACT_Docker_GUI.psm1    (module: logging, state, SSH/Docker/YAML/git helpers,
                           dialogs for credentials / key / location, theme)
   ^
   |  imported directly by the Pester tests (tests/*.Tests.ps1)
```

| File | Role |
|---|---|
| `current_version/IMPACT.bat` | Double-click launcher. Checks the files, finds PowerShell 7.3+, runs the GUI script, pauses on errors. |
| `current_version/Create-Shortcut.bat` | Creates `Desktop\IMPACT.lnk` pointing at `IMPACT.bat`. |
| `current_version/IMPACT_Docker_GUI_v2.ps1` | Workflow and UI that mix dialogs and side effects: `Ensure-RemotePreparation`, `Ensure-LocalPreparation`, `Get-ContainerStatus`, `Show-ContainerManager` (Start/Stop handlers), `Invoke-ImpactGui`, top-level `try/catch`. |
| `current_version/IMPACT_Docker_GUI.psm1` | Everything that can be tested headless, plus the first dialogs. Imported with `Import-Module <path>.psm1 -Force -DisableNameChecking` (the `.psd1` is not used for importing). |
| `current_version/IMPACT_Docker_GUI.psd1` | Manifest: `ModuleVersion` (shown in the footer), `PowerShellVersion = '7.3'`, `FunctionsToExport` (must match `Export-ModuleMember`; a unit test checks both directions). |

| Aspect | Decision |
|---|---|
| Runtime | PowerShell 7.3+ (`Core` edition). 7.0-7.2 drop empty native arguments (`ssh-keygen -N ''`) and mangle embedded quotes. |
| UI | WinForms via `Add-Type`; one dark palette (`Initialize-ThemePalette`) and `Style-*` helpers. |
| State | One `PSCustomObject` from `New-SessionState`, passed as `-State` everywhere. |
| Docker access | Docker contexts passed explicitly with `--context` (`Get-DockerContextArgs`); local mode also sets `$env:DOCKER_CONTEXT` for the IMPACT process only; remote fallback `DOCKER_HOST=ssh://...` (`Flags.UseDirectSsh`). The user's global Docker context (`~/.docker/config.json`) is never switched; a leftover global `remote-*` context from older versions is reset to `default`. |
| Remote execution | OpenSSH `ssh` with `BatchMode=yes`, `IdentitiesOnly=yes`, `StrictHostKeyChecking=accept-new`; Posh-SSH or plink only for the first password login. |
| Remote commands | Most remote commands print marker words (`IMPACT_KEY_OK`, `YAML_MISSING`, `__IMPACT_STATUS__`, ...) so "command ran and said no" can be told apart from "ssh failed". |
| Session recovery | Docker labels on the container (authoritative) plus a small JSON file in `/tmp/impactncd/` on the workstation. |
| Strict mode | `Set-StrictMode -Version Latest` in the module and the GUI script. Reading a missing hashtable key with dot notation throws, so optional `Metadata` keys are read with `['key']`. |
| Wizard | `Invoke-ImpactGui` runs steps 1-6 in a loop; failures or Cancel in preparation go back to step 4, Back in the manager goes to step 4, Back in step 4 goes to step 2. A failed step 1 or 3 (or no location) sets `$script:ImpactExitCode = 1`; the script then exits with 1. Cancel in a dialog and Close end with 0. |

---

## Launchers and PowerShell version

### `IMPACT.bat`

1. `cd /d "%~dp0"`; stops with an explanation if `IMPACT_Docker_GUI_v2.ps1` or `IMPACT_Docker_GUI.psm1` is not next to it.
2. Finds `pwsh.exe` with `where`, then `%ProgramFiles%\PowerShell\7\pwsh.exe` (Explorer may still have an old PATH right after installing).
3. Missing: prints install instructions (`winget install --id Microsoft.PowerShell --source winget`, <https://aka.ms/powershell-release>, Microsoft Store, ask IT), offers to open the download page, then waits for a key press (so the instructions stay readable while the user is on the download page) and exits 1. **No fallback to Windows PowerShell 5.1.**
4. Version check: `pwsh -Command` exits 3 when the version is below 7.3; the launcher then shows update instructions (`winget upgrade ...`) and pauses.
5. Sets `IMPACT_LAUNCHED_BY_BAT=1`, runs `pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File IMPACT_Docker_GUI_v2.ps1 %*`, saves `%errorlevel%` on the next line (outside any `( )` block, where cmd would expand it too early) and pauses on any non-zero code, also negative crash codes. The GUI script exits with 1 when `Ensure-Prerequisites` or `Ensure-GitKeySetup` returns `$false`, when no location is set, and on a fatal error; Cancel and Close exit with 0, so the window closes without a key press.

Both `.bat` files must have CRLF line endings; `.gitattributes` (`*.bat text eol=crlf`, `*.cmd text eol=crlf`) makes git write them that way into every checkout and into GitHub's ZIP download.

### `Create-Shortcut.bat`

Creates `IMPACT.lnk` on the Desktop with `WScript.Shell` via Windows PowerShell (always present). Target `IMPACT.bat`, working directory and icon from the tool folder. The folder path is passed through the environment variable `IMPACT_SHORTCUT_DIR`, so paths containing `&` or `'` work. `Arguments` is always set to empty: `CreateShortcut` on an existing `.lnk` keeps its old properties, and shortcuts from older versions had `-NoProfile -ExecutionPolicy Bypass -File ...` there, which `IMPACT.bat` would pass on to the `[CmdletBinding()]` script (parameter binding error, exit 1). Prints a note when PowerShell 7 is not installed yet; like `IMPACT.bat` it looks on PATH and in `%ProgramFiles%\PowerShell\7`.

### `Ensure-PowerShell7` (module)

- Supported (`Test-PowerShellVersionSupported`: Core edition and version 7.3 or newer): returns immediately.
- PowerShell 7.0-7.2: message box "PowerShell update required" and `throw` (no relaunch, which would loop).
- Windows PowerShell 5.1 with `pwsh` on PATH: relaunches `IMPACT_Docker_GUI_v2.ps1` (found next to the module via `$PSScriptRoot`) with `pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "<script>" -PS7Requested` (`Start-Process -NoNewWindow -Wait -PassThru`) and exits with its exit code. `-PS7Requested` prevents a second relaunch.
- 5.1 without `pwsh`: message box with the install hint and `throw`.

Each deliberate `throw` uses `New-ImpactNotifiedException`, which sets `Exception.Data['ImpactUserNotified'] = $true` when the explanation box was really shown. `Invoke-ImpactGui` also sets that flag on errors from `Ensure-PowerShell7` whose text matches `PowerShell 7|relaunch under pwsh` (keep the texts in sync).

Entry point of the GUI script:

- Before `Invoke-ImpactGui`, `Application.SetUnhandledExceptionMode(CatchException)` and an `Application.ThreadException` handler are installed: an error in any window event handler goes to `Show-ImpactUnexpectedError` (logs message, error record and script stack trace; shows "IMPACT - Unexpected error" with the log path from `Get-ImpactLogPathText`).
- After a normal return with `$script:ImpactExitCode -ne 0`, a red console line names the log file and the script exits with that code.
- The top-level `catch` logs the exception (message, script and .NET stack traces) and shows "IMPACT - Fatal error" with real line breaks and the real log path, unless `Data['ImpactUserNotified']` is set. It waits for Enter only when no box was shown, the user was not notified and `IMPACT_LAUNCHED_BY_BAT` is not `1` (for example an old shortcut that runs pwsh directly), then exits 1.

---

## Session state: `New-SessionState`

```
SessionState (PSCustomObject)
+-- UserName           [string]  GitHub username, lowercase (Resolve-GitHubUsernameInput)
+-- Password           [string]  RStudio password (plain text in memory; PASSWORD env of the container)
+-- RemoteHost         [string]  "php-workstation@<ip>" or $null
+-- RemoteHostIp       [string]
+-- RemoteUser         [string]  'php-workstation' (hard-coded default)
+-- RemoteRepoBase     [string]  "/home/<RemoteUser>/Schreibtisch/Repositories"
+-- ContainerLocation  [string]  'LOCAL' or 'REMOTE@<ip>'
+-- SelectedRepo       [string]  Docker-safe repo name (ConvertTo-DockerSafeRepoName, local and remote)
+-- ContainerName      [string]  "<SelectedRepo>_<UserName>"
+-- Paths    [hashtable]  LocalRepo, RemoteRepo (real folder name on the workstation), OutputDir,
|                         SynthpopDir, SshPrivate, SshPublic
+-- Flags    [hashtable]  Debug, UseDirectSsh, PS7Requested
|                         (UseVolumes, Rebuild, HighComputeDemand exist but are unused:
|                          the Start handler reads the checkboxes directly)
+-- Ports    [hashtable]  Used (ports mapped to 8787/tcp by running containers)
|                         (Requested, Assigned exist but are unused)
+-- Metadata [hashtable]  created empty; keys are added as the workflow runs:
    BuildInfo              {Version, Commit, Built}        Get-BuildInfo
    PublicKey              public key text                 Ensure-GitKeySetup
    GitHubKeyCheck         {KeyPath, Status}               Confirm-GitHubKeyRegistered (once per key)
    LocalDockerContext     'local', or 'default' if 'local' is unusable   Ensure-LocalPreparation
    DockerContextEnvSet    [bool] $env:DOCKER_CONTEXT set by local prep   Ensure-Local/RemotePreparation
    RemoteDockerContext    'remote-<ip>'                   Ensure-RemotePreparation
    RemoteSshCheckStatus   OK|KeyMissing|Unreachable|HostKeyChanged|LoginFailed   Test-RemoteSSHKeyFiles
    RemoteSshCheckMessage  text for the user or $null      Test-RemoteSSHKeyFiles
    DockerReachable        [bool] last docker ps worked    Get-ContainerStatus, Start handler
    ExistingContainers     [{Name,Status,Ports,Image}]     Get-ContainerStatus
    ContainerRunning       [bool]
    Recovered              {Password, Port, UseVolumes, OutputDir, SynthpopDir, VolumeOutput, VolumeSynthpop,
                            RepoPath}  (RepoPath only from Get-ContainerStatus; read it with ['RepoPath'])
    ActivePort / ActiveUseVolumes / ActiveRepoPath / ActiveIsRemote   used by Stop
    VolumeOutput / VolumeSynthpop   volume names of the running container
    GitBaseline            {Repo, Commit, Status, Timestamp} (captured at Start, not read yet)
    Busy / BusyButtonState  Set-ManagerBusy
```

---

## Function reference

### Module (`IMPACT_Docker_GUI.psm1`), exported

| Area | Functions |
|---|---|
| NonInteractive mode | `Enable-NonInteractiveMode`, `Disable-NonInteractiveMode`, `Test-NonInteractiveMode` |
| Logging, build info, state | `Initialize-Logging`, `Write-Log`, `Get-BuildInfo` (Version from the `.psd1`, Built = `.psm1` LastWriteTime, Commit only if the module file is tracked by the git repo it sits in, `*` when the tool folder is dirty), `New-SessionState`, `Ensure-PowerShell7` |
| SSH / Docker basics | `Get-RemoteHostString`, `Set-DockerSSHEnvironment` (rebuilds `DOCKER_SSH_OPTS` on every call; sets `DOCKER_HOST` only in direct-SSH mode; clears a leftover `ssh://` value otherwise; clears both in local mode), `Get-DockerContextArgs`, `Convert-PathToDockerFormat` (`C:\a\b` to `/c/a/b`) |
| Remote helpers | `Test-RemoteSSHKeyFiles` (one ssh call; only the private key is required; records status and message), `Get-SshFailureKind` (HostKeyChanged / Unreachable / AuthFailed / Unknown from OpenSSH and Posh-SSH texts), `ConvertTo-RemoteRepoList`, `Write-RemoteContainerMetadata` (no password; `umask 077`; path quoted with `ConvertTo-PosixShellLiteral`; also blanks passwords in older files, see [Security](#security-considerations)), `Read-RemoteContainerMetadata`, `Remove-RemoteContainerMetadata` (same clean-up), `Get-DockerCredentialsFromDotEnv` (`[string[]]` input), `Ensure-RemoteDockerLogin` (reads `<repo>/docker_setup/.env` on the workstation with a quoted `cat`; password via ssh stdin, registry passed unless Docker Hub, user/registry validated) |
| Container info, ports, errors | `Get-ContainerRuntimeInfo` (password and port from `docker inspect`, volume mode/folders/volume names/`RepoPath` from labels and mounts; `UseVolumes = $null` when unknown), `Get-NextAvailablePort` (8787-8799; returns 8787 even when every port is used, so callers check the result against the used list), `Test-PortValue` (ASCII digits only, at most 5, no leading zero, in range, `[int]::TryParse`), `Get-UsedPorts` (any host address in `:<port>->8787/tcp`), `Format-DockerError` |
| YAML and folders | `Get-YamlPathValue` (single-line `key: value`; strips `"..."`/`'...'` with their escapes; empty, `~`, `null` give `$null`; `~/` becomes `/home/<RemoteUser>` in remote mode; relative paths are joined to `-BaseDir`; remote read prints a marker when the file is missing), `Test-AndCreateDirectory` (optional `-Create`, optional `-Reason [ref]` = EmptyPath, Missing, NetworkPathInLocalMode, PosixPathInLocalMode, Unreachable, CreateFailed; never creates without `-Create`; remote paths quoted with `ConvertTo-PosixShellLiteral`; `-LiteralPath` locally), `ConvertTo-PosixShellLiteral` (single-quotes a value for sh: `'` becomes `'\''`; exported because the GUI uses it) |
| Git | `Get-GitRepositoryState` (optional `-Reason [ref]`), `Show-GitCommitDialog`, `Invoke-GitChangeDetection` (see [Git change detection](#git-change-detection)) |
| UI and theme | `Set-FormCenterOnCurrentScreen` (centres on the monitor with the mouse pointer, P/Invoke), `Initialize-ThemePalette`, `Get-ThemePalette`, `Apply-ThemeToForm`, `Style-Label`, `Style-TextBox`, `Style-CheckBox`, `Style-Button`, `Style-InfoBox` |
| Startup and dialogs | `Test-StartupPrerequisites` (docker CLI and ssh only; it does **not** check the Docker daemon), `Ensure-Prerequisites` (WinForms, UTF-8 console output, prerequisites, admin info, console title, git warning), `Show-CredentialDialog`, `Ensure-SshAgentRunning` (optional agent, never elevated), `Remove-SshConfigHostBlock` (block ends at the next `Host`, `Match` or `Include` line; blank and comment lines before it are kept), `Ensure-SshConfigEntry` (optional `-ConfigPath` for tests), `Ensure-GitKeySetup`, `Select-Location` |
| Container commands | `ConvertTo-DockerSafeRepoName`, `Build-DockerRunCommand` (pure; same arguments as the Start handler; used by tests), `Get-ImpactVolumeNames`, `Split-DockerCustomParams`, `Get-ImpactContainerLabelArgs` (optional `-RepoPath`), `Get-ImpactVolumeInfo`, `Initialize-RsyncHelperImage`, `Sync-ImpactVolumeToHost` (`-KeepNewerOnHost`), `Get-ContainerGitSshCommand`, `Get-ContainerSshSetupCommand` |
| Docker Desktop, GitHub API | `Test-DockerDaemonReady`, `Start-DockerDesktopIfNeeded`, `Add-GitHubSshKey`, `Remove-GitHubSshKey` (used by the E2E tests), `Test-GitHubUsername` (`-Detailed` returns Status Exists / NotFound / Organization / Unknown and a message; only HTTP 404 means NotFound; an HTTP 200 answer without a `login` field, for example a proxy or login page, is Unknown) |

### Module, private (reached from tests with `InModuleScope`)

| Area | Functions |
|---|---|
| Startup | `Test-PowerShellVersionSupported`, `New-ImpactNotifiedException`, `Resolve-GitHubUsernameInput`, `Get-RStudioPasswordProblem` |
| Remote metadata | `Get-RemoteMetadataCleanupCommand` |
| Git | `ConvertTo-GitOutputText`, `Get-GitPushFailureHint`, `Invoke-GitPushWithImpactKey` |
| SSH agent and config | `Test-SshAgentHasKey`, `Backup-SshConfigFile`, `Repair-SshConfigIdentityFileQuoting` |
| SSH key and GitHub check | `Invoke-ImpactSshKeygen`, `Initialize-ImpactSshKeyPair`, `Get-GitHubSshAuthStatus`, `Test-GitHubSshKeyAuth`, `Show-GitHubKeyRegistrationDialog`, `Confirm-GitHubKeyRegistered` |
| Location dialog | `Test-WorkstationIpAddress`, `Get-DotEnvValue` |

### GUI script (`IMPACT_Docker_GUI_v2.ps1`)

| Function | Purpose |
|---|---|
| `Ensure-RemotePreparation` | Key login probe, password bootstrap, key copy, known_hosts, repo list and folder checks, Docker context, remote Docker checks. |
| `Ensure-LocalPreparation` | Folder picker and checks, Docker Desktop start/wait, `local` context, `DOCKER_CONTEXT`. |
| `Get-ContainerStatus` | Port scan, own containers, running check, leftover stopped container, recovery of password/port/volume details and the repository folder. |
| `Show-ContainerManager` | Main window. Nested: `Get-DifferentLabelRepoPath`, `Set-ManagerBusy`, `Update-InfoBox`, `Invoke-ManagerButtonAction`; the Start and Stop code are the script blocks `$startClickBody` and `$stopClickBody`; inside Start: `Confirm-YamlFolder`, `ConvertTo-QuotedArgument`, `Invoke-StartImageBuild`. |
| `Get-ImpactLogPathText` | The log path as text for messages (`IMPACT_LOG_FILE`, else `~/.impact_gui/logs/impact.log`, or a note when logging is off). |
| `Show-ImpactUnexpectedError` | Logs an unexpected error with details and shows a plain message with the log path. |
| `Invoke-ImpactGui` | The wizard loop. |

---

## Workflow

### Step 1: prerequisites (`Ensure-Prerequisites`)

Loads WinForms, sets `[Console]::OutputEncoding` to UTF-8 (no BOM) so docker/ssh/git output with umlauts is decoded correctly, then `Test-StartupPrerequisites`:

- `docker` missing: "Docker missing" (Docker Desktop for local; `docker.exe` on PATH is enough for remote).
- `ssh` missing: first `%WINDIR%\System32\OpenSSH\ssh.exe` is added to PATH if present; otherwise the user is **asked**, then `Get-WindowsCapability ... | Add-WindowsCapability` runs in an elevated Windows PowerShell via `-EncodedCommand`. After a successful install PATH is rebuilt from the Machine and User values; if `ssh` is still not found, `%WINDIR%\System32\OpenSSH` is put in front of PATH. A cancelled UAC prompt is logged; "SSH missing" explains the manual install.

After `Clear-Host`, a console warning appears if `git` is not on PATH (commit offer unavailable in local mode). A `$false` result ends the wizard with exit code 1.

### Step 2: credentials (`Show-CredentialDialog`)

All checks run inside the Continue handler while the form is open:

1. `Resolve-GitHubUsernameInput`: removes whitespace, lowercases, accepts `github.com/<name>` links and `@name`, rejects e-mail addresses (own hint) and anything not matching `^[a-z0-9][a-z0-9_-]{0,38}$`.
2. `Get-RStudioPasswordProblem`: at least 8 characters, not equal to the username (case-insensitive), not in a short list of common passwords.
3. `Test-GitHubUsername -Detailed` with a 15 s timeout: NotFound/Organization keep the dialog open; Unknown (no status, 403/429 rate limit, 407 proxy, other HTTP errors, a 200 answer without `login`) asks "Continue anyway?".

Fields are pre-filled from `$State`; when the user came back with Back, Cancel returns `'next'` and keeps the previous values. NonInteractive mode validates the pre-set values and only warns about a weak password.

### Step 3: SSH key (`Ensure-GitKeySetup`)

- Path: `Join-Path $HOME '.ssh'` + `id_ed25519_<user>`.
- `Initialize-ImpactSshKeyPair` makes the pair complete and usable without a passphrase. All `ssh-keygen` calls go through `Invoke-ImpactSshKeygen`, which runs with `$PSNativeCommandArgumentPassing = 'Standard'` (so the empty passphrase `''` really reaches ssh-keygen), sends an empty line on stdin (a hidden "Overwrite (y/n)?" gets "no") and captures all output. Status values:
  - private key present: `ssh-keygen -y -P "" -f <key>` checks it. On a passphrase error it first tries `ssh-keygen -p -P -q -N "" -f <key>`, which removes the accidental `-q` passphrase of keys made under PowerShell 7.0-7.2 (status `PassphraseRemoved`; same public key). Any other passphrase gives `Encrypted` with instructions (`ssh-keygen -p -f "<key>"`, or rename both files). Another `-y` failure with both files present is only logged (`Unverified`).
  - `.pub` missing: rebuilt from the private key with `-y` (comment `IMPACT_<user>` added if missing), status `PublicKeyRebuilt`; never a new key, so the key on GitHub and the workstation stays valid. Not rebuildable: `Unreadable`.
  - no private key: a stray `.pub` is deleted, then `ssh-keygen -t ed25519 -C IMPACT_<user> -f <path> -N '' -q` and a `-y` check (`Generated`, or `GenerateFailed`).
- A failed result shows the message in the box "SSH key problem" (not in NonInteractive mode) and returns `$false` (exit code 1).
- `Repair-SshConfigIdentityFileQuoting` (see step 5b) runs next, so a broken `~/.ssh/config` is also repaired in local mode, before the GitHub check.
- Existing pair: public key printed, `Ensure-SshAgentRunning`, `Confirm-GitHubKeyRegistered`.
- New pair: public key to the clipboard, message box and key window (Copy to Clipboard), then `Ensure-SshAgentRunning` and `Confirm-GitHubKeyRegistered`.
- `Ensure-SshAgentRunning` (optional, never elevated): returns when `Get-Service` or the `ssh-agent` service does not exist; tries one normal `Start-Service` and, if that fails (the service is `Disabled` by default), logs at Info that the agent is not needed, with the admin command. Removes agent entries whose key file was deleted (only entries whose comment is a path; IMPACT keys are listed as `IMPACT_<user>`). Adds the key with `ssh-add` (empty stdin, exit code checked) unless `Test-SshAgentHasKey` finds its fingerprint (`ssh-keygen -l -f <key>.pub`) in `ssh-add -l`. IMPACT's own ssh and git calls pass `-i <key>`; Docker over ssh gets the key from the `~/.ssh/config` entry.
- `Confirm-GitHubKeyRegistered` (skipped in NonInteractive mode): `Test-GitHubSshKeyAuth` runs `ssh -T -n -i <key> -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 git@github.com`; `Get-GitHubSshAuthStatus` classifies the output:
  - `Authenticated` (exit 0 or 1 plus "successfully authenticated"; a key of another account than the entered user name gives a Warn line);
  - `KeyUnusable` (`Load key "<file>": ...` or `Permissions ... for '<file>' are too open`, only when `<file>` is the IMPACT key): Warn with an `icacls <key> /inheritance:r /grant:r <user>:F` hint or "rename both files", no dialog;
  - `NotRegistered` ("Permission denied (publickey"): `Show-GitHubKeyRegistrationDialog` with the public key (also put on the clipboard), <https://github.com/settings/keys> and the buttons Copy key, Open GitHub, Check again (repeats the check), Continue anyway;
  - `HostKeyProblem`, `Unreachable`, `Unknown`: Warn line only.

  The final status is stored in `Metadata['GitHubKeyCheck'] = @{ KeyPath; Status }`; a second call for the same key path (Back from the location dialog runs step 3 again) returns it without ssh or dialog. The result never stops the wizard.

### Step 4: location (`Select-Location`)

Local/Remote buttons, IP text box, Debug checkbox (sets `$script:GlobalDebugFlag`), Back. The IP box is pre-filled from `WORKSTATION_IP` in `.env` in the module folder or its parent, read with `Get-DotEnvValue` (`export NAME=`, `"..."` or `'...'` values, and a trailing `# comment` after a space are understood; `-LiteralPath`). `Test-WorkstationIpAddress` accepts only four ASCII numbers 0-255 without leading zeros ("Invalid IP Format" otherwise; ssh would read `010` as octal); NonInteractive mode skips this check, because CI may use host names. The instruction text is styled with `Style-InfoBox` first, then its bold and regular parts get Segoe UI 9. Sets `ContainerLocation`, `RemoteHost`, `RemoteRepoBase`.

### Step 5a: local preparation (`Ensure-LocalPreparation`)

1. `FolderBrowserDialog` (starts in Documents).
2. Rejects UNC paths and drives whose `DriveInfo.DriveType` is `Network`; requires `docker_setup` (`Test-Path -LiteralPath`); `ConvertTo-DockerSafeRepoName` (unchanged if valid; otherwise accents removed, `ss` for sharp s, runs of other characters to `_`; empty result is rejected); OneDrive warning (Yes/No); `.git` check (Yes/No).
3. Clears `DOCKER_HOST`, `DOCKER_SSH_OPTS` and `DOCKER_CONTEXT`; creates the `local` context (`npipe:////./pipe/docker_engine` on Windows) if missing. If `docker context inspect local` then fails (for example `~/.docker` not writable), Docker's built-in `default` context is used for every later call.
4. Quick check `docker --context <ctx> version` (stderr kept). "access is denied / Zugriff verweigert / permission denied" together with not-confirmed `docker-users` membership (SID-based, language independent) shows the docker-users help and returns `$false`.
5. Not running: starts Docker Desktop (`Program Files`, then `LocalAppData`, then service `com.docker.service`), polls `docker info` up to 30 times in background jobs with a 5 s limit each. Then the Yes/No/Cancel loop (Yes = check again 10 times; No = continue knowingly; Cancel = back).
6. While `DOCKER_CONTEXT` is still empty, `docker context show` reads the global context; a `remote-*` value (left by older versions) is reset with `docker context use default`. Then `$env:DOCKER_CONTEXT = <ctx>` for this process only and `Metadata['DockerContextEnvSet'] = $true`. Every docker command IMPACT starts, including children of `Start-Process`, inherits it; `~/.docker/config.json` is not changed.
7. Final `docker --context <ctx> version`; failure shows "Docker Not Reachable" and returns `$false` unless the user chose to continue anyway. `Metadata.LocalDockerContext = <ctx>`.

### Step 5b: remote preparation (`Ensure-RemotePreparation`)

1. `Ensure-SshConfigEntry` for the IP:
   - First `Repair-SshConfigIdentityFileQuoting` over the whole file: every unquoted `IdentityFile` value with whitespace gets double quotes, in every section. Values containing a quote, `#` or a backslash before a space are left alone. A section is IMPACT's when the marker comment `# IMPACT Docker GUI` is the last non-empty line above its `Host` line. Before a user-written line changes, `Backup-SshConfigFile` saves `config.impact-backup-<yyyyMMdd-HHmmss>[-N]` next to the file, or in `~/.impact_gui/ssh-config-backups`; without a copy only IMPACT's lines are repaired and an Error line gives the exact manual fix. Never throws.
   - The workstation block (`Host <ip>`; `IdentityFile=value` is also understood; `~` and `%d` are expanded before comparing) is replaced when its key path is unquoted with a space, points to a missing file or a different key, contains backslashes, or is missing. A user-written block is replaced only after a backup; without one it is kept and an Error line says that remote Docker may fail and names the lines to put there (`User`, quoted `IdentityFile`, `IdentitiesOnly yes`).
   - `Remove-SshConfigHostBlock` ends the block at the next `Host`, `Match` or `Include` line and keeps blank and comment lines in front of it. The new entry writes `IdentityFile "<path with forward slashes>"`. The function returns no output.
2. Probe `ssh -n -i <key> -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 <host> echo KEY_AUTH_OK`. On failure `Get-SshFailureKind`: Unreachable and HostKeyChanged stop **before** any password prompt (no password is sent to a host whose key changed). The HostKeyChanged box names `ssh-keygen -R <ip>` and, for Posh-SSH's own trust store, `Remove-SSHTrustedHost -HostName <ip>` (Posh-SSH 3.x) and `-SSHHost <ip>` (2.x).
3. Password bootstrap (only when the key is refused):
   - Password dialog, then **Posh-SSH** (offers `Install-Module Posh-SSH -Scope CurrentUser`): `New-SSHSession -AcceptKey`, upload of the public key to a temp file, install script (single-quoted here-string with `%%USERNAME%%` / `%%REMOTE_TEMP%%` replaced by `.Replace()`, line endings converted to LF; `set -eu` and `exec 2>&1`; `umask 077`; `chmod go-w` on the home folder; `.ssh` 700; `authorized_keys` 600; `chown "$ACTUAL_USER": ... || true`; removes old lines ending in `IMPACT_<user>` with an anchored `sed`; prints `SSH_KEY_COPIED`). Errors are classified by exception type (also of the inner exception):
     - `SshAuthenticationException` with "No suitable authentication method": "Password login not allowed" (asks the user to send `<key>.pub` to the admin), no retry;
     - other `SshAuthenticationException`: "Wrong password" and the preparation is re-run, so the dialog returns;
     - `SshConnectionException` matching `Key exchange negotiation failed|HostKeyNotVerifiable|fingerprint|host key`: "Workstation identity changed" with both `Remove-SSHTrustedHost` forms;
     - anything else: "SSH key setup failed" with the details. plink is not tried after a real Posh-SSH attempt (no second password send).
   - **plink** only when Posh-SSH is not available: script converted to LF and piped to `plink -batch -ssh -pwfile <temp file> -hostkey <fp> ... <host> bash -s` (PuTTY 0.77+ for `-pwfile`). The `-hostkey` values are the SHA256 fingerprints of `ssh-keyscan -T 10 -t ed25519,ecdsa,rsa <ip> | ssh-keygen -l -f -` when at least one of them equals a fingerprint OpenSSH already trusts (`ssh-keygen -l -F <ip>`); otherwise only the trusted ones. Success needs exit 0 and `SSH_KEY_COPIED`.
   - Afterwards the key login is verified once more ("SSH key setup failed" otherwise).
4. Private key copy: the key text is piped to `ssh` on **stdin** (not on the command line): `umask 077 && mkdir -p ~/.ssh && chmod 700 ~/.ssh && tr -d '\r' > <key>.tmp && chmod 600 ... && mv -f ... && echo PRIVATE_KEY_COPIED`. Without the marker the workstation runs `ssh-keygen -y -f <key> 2>/dev/null || echo KEY_UNREADABLE`; the first public-key line is compared with this PC's `.pub` (type and key, comment ignored). A match continues (Info); otherwise "SSH key copy failed" (last 3 lines of ssh output, an extra sentence when an older, different key is there) and `$false`.
5. known_hosts on the workstation, one joined shell line: `touch ~/.ssh/known_hosts`; if `ssh-keygen -l -F github.com` shows one of GitHub's three published SHA256 fingerprints (`$ghFpArgs` in `Ensure-RemotePreparation`; **update them if GitHub rotates its keys**), nothing changes. Otherwise `ssh-keyscan -T 10 -t ed25519,ecdsa,rsa github.com` runs, each line is kept only if `ssh-keygen -l -f -` gives one of those fingerprints, and only if at least one line survived are all github.com lines (hashed ones too) removed with `ssh-keygen -R github.com` and the verified lines appended. Other hosts' lines are never touched; a failed or tampered scan leaves the file unchanged. Prints `KNOWN_HOSTS_OK` (Warn if missing). This PC's known_hosts is not copied there.
6. Repo list: `find '<base>' -mindepth 1 -maxdepth 1 -xtype d ! -name '.*' -printf '%f\n'`; `ConvertTo-RemoteRepoList` drops ErrorRecords and blank lines. Empty list: "No repositories found" (or "lost the connection" on exit 255 / Unreachable). After the selection:
   - `ConvertTo-DockerSafeRepoName` gives `SelectedRepo` and `ContainerName` (a changed name is logged at Warn); `Paths.RemoteRepo` keeps the real folder name. An empty safe name: "Unsupported Folder Name", `$false`.
   - `test -d '<repo>/docker_setup' && echo DOCKER_SETUP_OK || echo DOCKER_SETUP_MISSING`: MISSING gives "Not a Model Repository" and `$false`; no marker only logs a Warn.
7. If `Metadata['DockerContextEnvSet']` is set (local prep ran earlier in the session), `$env:DOCKER_CONTEXT` is cleared first. Docker context `remote-<ip>` (`host=ssh://<host>`) is created if missing; failure sets `Flags.UseDirectSsh`. The global context is **not** switched; if it still points at `remote-<ip>` (older versions), it is reset to `default`.
8. Remote `docker version` over ssh: permission denied on the socket ("ask the admin to run `sudo usermod -aG docker <user>`"), CLI missing ("Docker Engine Missing"), daemon down (offer `sudo systemctl start docker` in the console via `Start-Process ssh -t`), `groups` check.

### Step 6: status (`Get-ContainerStatus`)

1. `docker ps --format '{{.Names}}\t{{.Ports}}'` with stderr kept. Failure: "Docker Not Reachable" Retry/Cancel; `Metadata.DockerReachable = $false` and the next calls are skipped.
2. `Ports.Used` from every `:<port>->8787/tcp` match.
3. Own containers: `docker ps -a --filter name=_<escaped user>$`.
4. Running check: `--filter name=^<ContainerName>$`.
5. A stopped same-named container (can only come from outside the app because of `--rm`): "Old Container Found", `docker rm` on Yes.
6. `Metadata.Recovered` is reset (with `RepoPath = $null`), then filled for a running container from the remote metadata (port, useVolumes; never the password) and from `Get-ContainerRuntimeInfo` (authoritative; the only password source; `RepoPath` from the `impact.repo_path` label).

When `Show-ContainerManager` opens:

- Resume (container running): "Container already running" (masked password), `Active*` restored. `Get-DifferentLabelRepoPath` compares `Recovered['RepoPath']` (or a fresh `Get-ContainerRuntimeInfo` when the key is missing) with the selected folder: LOCAL case-insensitive with `/` and `\` treated alike, and only if the label folder exists; REMOTE exact. A difference shows "Different repository folder" and sets `ActiveRepoPath` to the container's folder. Containers without the label keep the selected folder.
- `Metadata['DockerReachable'] -eq $false`: info box `UNKNOWN (Docker not reachable)`, status line "click Back and continue again".
- Nothing running: one `docker volume ls`; if either volume name of `Get-ImpactVolumeNames` exists, "Use Docker Volumes" is ticked and the status line mentions the earlier results. If the suggested port is itself in `Ports.Used` (all ports taken), the status line says so.
- `FormClosing`: refuses while `Metadata['Busy']`; with a running container asks "Close without stopping?", adding the volume hint when `Metadata['ActiveUseVolumes']`.

### Step 7: Start (`$startClickBody` in `Show-ContainerManager`)

The Start and Stop bodies are script blocks run by `Invoke-ManagerButtonAction` (try/catch, then `Show-ImpactUnexpectedError`); `return` inside them ends the click. Order of checks and actions:

1. `Set-DockerSSHEnvironment`; `Metadata.ContainerRunning` ("Already running"); `Test-PortValue` ("Invalid port").
2. Remote: `Test-RemoteSSHKeyFiles` **before any docker call** (docker over ssh would otherwise fail first with a generic message); the box shows `Metadata['RemoteSshCheckMessage']`.
3. Fresh `docker <ctx> ps --format '{{.Names}}\t{{.Ports}}'`. Non-zero exit: `DockerReachable = $false`, info box UNKNOWN, "Docker not reachable" (LOCAL: start Docker Desktop; REMOTE: IMPACT could log in, but Docker did not answer; retry, then ask the admin), return. Own container listed: "Already running" (click Back and continue). `Ports.Used` is replaced by the fresh ports; an UNKNOWN info box switches back to STOPPED.
4. `Get-NextAvailablePort` on the fresh ports: if the result is itself used, "No free port"; if the chosen port is used, the free port is written into the Port box, "Port conflict", return.
5. Other own containers running (names ending in `_<user>` from the fresh list; Yes/No).
6. `docker_setup` (local, `Test-Path -LiteralPath`); YAML file: local `Resolve-Path`/`Test-Path -LiteralPath`, remote `test -f <quoted> && echo YAML_OK || echo YAML_MISSING` ("Connection problem" without a marker).
7. `Get-YamlPathValue` for `output_dir` and `synthpop_dir`, then `Confirm-YamlFolder` with `Test-AndCreateDirectory -Reason`: separate messages per reason ("Network Folder Not Supported" for `NetworkPathInLocalMode`, "Path error", "Connection problem", "Setting missing in YAML" with `./outputs` or `./inputs/synthpop` as example); a missing folder can be created (Yes/No) locally, or on the workstation only inside the repository.
8. Shared repository warning: bind sources of all running containers (`docker ps -q` + one `docker inspect`) compared with the repo path (remote exact, local by path ending). Default No.
9. Leftover volumes, in **both** modes: `Get-ImpactVolumeInfo` per volume name; unknown ("Volume check failed") or in use ("Volume in use") stops. Leftovers: "Earlier results found" Yes/No/Cancel. Yes: busy mode, `Sync-ImpactVolumeToHost -KeepNewerOnHost` to the recorded folder (label `impact.target_dir`, else the current one); a failed copy stops without deleting. No: second confirmation (default No). Then `docker volume rm` of the leftovers. In bind mode the start continues without volumes.
10. Volume mode: `Initialize-RsyncHelperImage` ("Volume helper missing").
11. Image name `SelectedRepo.ToLowerInvariant()`. Unless Rebuild: `docker <ctx> images --format '{{.Repository}}'`; a non-zero exit shows "Docker not reachable" and returns (no build).
12. Build (if missing or Rebuild), in busy mode with a `finally`, through `Invoke-StartImageBuild` (`-NoCache` defaults to `$true`):
    - local: `docker --context <ctx> build --build-arg REPO_NAME=<repo> -f docker_setup/Dockerfile.IMPACTncdGER -t <image> [--no-cache] --progress=plain .` in the repo folder (`Push-Location -LiteralPath`), via `Start-Process -NoNewWindow -Wait` with every argument quoted by `ConvertTo-QuotedArgument`, so the log streams to the console;
    - remote: `ssh ... "cd <q> && docker build --build-arg <q REPO_NAME=...> -f <q> -t <q> [--no-cache] ."`, every value quoted with `ConvertTo-PosixShellLiteral`;
    - fallbacks: remote `Ensure-RemoteDockerLogin` + one retry with `-NoCache $false`; then "Image build failed" Yes/No (default Yes; No gives "Build failed"): `Dockerfile.prerequisite.IMPACTncdGER` (tag `<image>-prerequisite`, context `docker_setup`, `--no-cache`) and the main build again with `-NoCache $false`. Each phase updates the busy text. The first main build and the prerequisite build use `--no-cache` (see [KNOWN_BUGS](KNOWN_BUGS.md)).
13. Busy mode "Starting the container. Please wait..." with a `finally` around steps 14-22.
14. Git baseline (best effort, `git -C` locally, quoted `cd` remotely; not used later).
15. uid/gid: `1000:1000` locally; `id -u` / `id -g` of the SSH user remotely.
16. Volume mode: `docker volume create --label impact.target_dir=<host dir> --label impact.container=<container>`, ownership with `alpine chown`, pre-population with one checked `cp -r` ("Volume copy problem": Yes/No, default No).
17. `docker run -d --rm --name <container> -e PASSWORD=... -e DISABLE_AUTH=false -e USERID -e GROUPID -e CONTAINER_REPO_NAME -e SYNC_ENABLED=false -e GIT_SSH_COMMAND=<Get-ContainerGitSshCommand> --mount type=bind,source=<repo>,target=/home/rstudio/<repo> -p <publish> [custom params] [volume or bind mounts for outputs and synthpop] [--cpus 32 -m 384g] [labels] --mount type=bind,source=<key>,target=/keys/id_ed25519_<user>,readonly --workdir /home/rstudio/<repo> <image>`
    - `<publish>` = `127.0.0.1:<port>:8787` for LOCAL (only this PC), `<port>:8787` for REMOTE.
    - `<key>` = the local key path, or `/home/<RemoteUser>/.ssh/id_ed25519_<user>` on the workstation.
    - Custom params are split by `Split-DockerCustomParams` (quotes respected, no empty arguments).
    - Labels from `Get-ImpactContainerLabelArgs ... -RepoPath <project root>`.
    - The host's `known_hosts` is **not** mounted.
    - The ports are scanned again right before `docker run`; errors go through `Format-DockerError`. The password is masked (`PASSWORD=***`) in the debug log line.
18. In-container setup (see the next section), each step retried 3 times, 2 s apart.
19. `docker ps` check that the container still exists ("Container stopped" with the log path otherwise; fresh volumes removed).
20. "Container setup incomplete" warning if `KEY_FIXED` or `GIT_CONFIGURED` is missing.
21. Remote metadata JSON (`container, repo, user, port, useVolumes, timestamp`; no password).
22. After the `finally`: `Recovered` reset, `Active*` set, info box RUNNING; the console prints the URL but never the password.

### Step 8: Stop (`$stopClickBody`)

1. Busy "Checking the container...": `docker ps --filter name=^<container>$`. A non-zero exit means "unknown" ("Docker not reachable", state unchanged). Not listed means it already ended: no confirmation, no `docker stop`, but full clean-up.
2. "Stop container?" Yes/No with **No as default button**.
3. Busy "Stopping the container. Please wait..." (with a `finally`):
   - running container: `Get-ContainerRuntimeInfo` again; a known `UseVolumes` refreshes `ActiveUseVolumes`, the volume names (mounted, then known, then computed) and the result folders (only when labelled). `Get-DifferentLabelRepoPath` re-checks `impact.repo_path` and may switch `ActiveRepoPath`. Then `docker stop`.
   - volume mode (`ActiveUseVolumes`): refuses to copy when volume names or target folders are unknown; otherwise `Sync-ImpactVolumeToHost` for both. The decision is made **per volume**: a copied volume is removed (`volume rm -f`, retried 5 times; a missing volume needs nothing), a volume whose copy failed is kept.
   - `ContainerRunning = $false`, remote metadata removed, `Recovered` reset, `Ports.Used` refreshed (so the freed port can be used again).
4. Info box STOPPED; "Results still in Docker volumes" lists only the kept volumes and says what happens on the next Start.
5. Busy "Checking your repository for changes to commit...": `Invoke-GitChangeDetection` for `ActiveRepoPath` / `ActiveIsRemote`; the result is filtered to the object that has a `Success` property.
6. Status line: a volume problem gives "Stopped. Results are still in Docker volumes (see the message)."; a git result with `Success = $false` or Outcome `Unavailable` gives "Container stopped. <Message>"; otherwise "All done. You can close this window or start another container."

### Busy mode (`Set-ManagerBusy`)

Saves and disables Start/Stop/Back/Close, sets `Metadata.Busy`, shows a status text and the wait cursor and calls `$form.Refresh()` (no `DoEvents`, so no other click can run in the middle). A second call while busy only changes the text. `Set-ManagerBusy -Busy $false` sits in a `finally` and restores the saved button states, so the Start/Stop switches are made after it. Busy mode covers the leftover-volume copy, the image build (with a text per phase), the rest of Start (volumes, `docker run`, in-container setup, metadata), the first `docker ps` of Stop, the stop/copy/removal part and the git check.

`FormClosing` refuses to close while `Metadata['Busy']` is set ("Please wait"). This does not protect the build itself: `Start-Process -Wait` blocks the UI thread, so `FormClosing` cannot run, Windows marks the window as not responding, and its "Close the program" choice kills pwsh in the middle of the build (the user guide tells users to choose **Wait**; see [KNOWN_BUGS](KNOWN_BUGS.md)).

---

## Inside the container: SSH and git setup

`Get-ContainerGitSshCommand -UserName <u>` (the `GIT_SSH_COMMAND` environment variable of the container):

```
ssh -i /home/rstudio/.ssh/id_ed25519_<u> -o IdentitiesOnly=yes -o UserKnownHostsFile=/home/rstudio/.ssh/known_hosts -o StrictHostKeyChecking=accept-new
```

`Get-ContainerSshSetupCommand -UserName <u> -ContainerUid <uid> -ContainerGid <gid>`, run with `docker exec --user root <container> sh -c`:

```
mkdir -p /home/rstudio/.ssh && chmod 700 /home/rstudio/.ssh
&& tr -d '\r' < /keys/id_ed25519_<u> > /home/rstudio/.ssh/id_ed25519_<u> && chmod 600 ...
&& touch /home/rstudio/.ssh/known_hosts
&& { grep -v '^github.com ' known_hosts; ssh-keyscan -T 10 -t ed25519,ecdsa,rsa github.com 2>/dev/null || true; } > known_hosts.tmp
&& mv known_hosts.tmp known_hosts && chmod 644 known_hosts
&& chown -R <uid>:<gid> /home/rstudio/.ssh && echo KEY_FIXED
```

- The key is copied out of the read-only bind mount (which keeps host ownership) and CR characters from Windows are stripped.
- GitHub's host keys are scanned **inside the container** at every start; older github.com lines are replaced, other lines kept. The host's known_hosts plays no role, so `git pull` works even if the host never connected to github.com. A failed scan does not abort the chain (`|| true`); `accept-new` then records github.com on the first connection.

Git configuration (`docker exec --user rstudio`, `git config --global`, so it lands in `/home/rstudio/.gitconfig` only): `user.name <u>`, `user.email <u>@users.noreply.github.com`, `pull.ff true`, `pull.rebase false`, `safe.directory '*'`, `url.git@github.com:.insteadOf https://github.com/`, `core.sshCommand '<Get-ContainerGitSshCommand>'`; prints `GIT_CONFIGURED`.

- `url...insteadOf` makes git inside the container use SSH (and the IMPACT key) for every `https://github.com/` URL, for clone, fetch, pull and push. The container has no HTTPS credentials, so repositories cloned with an HTTPS origin (GitHub Desktop) could otherwise not push from RStudio. The repository's `.git/config` and the git settings on the PC or the workstation are not changed.
- `core.sshCommand` has the same value as `GIT_SSH_COMMAND`. RStudio starts R sessions and the Git pane through its own server process, and `docker run -e` variables reach them only if the image copies them into `Renviron.site`; git reads `core.sshCommand` from `~/.gitconfig` itself, so the Git pane and the RStudio Terminal use the IMPACT key either way. When `GIT_SSH_COMMAND` is also set, git uses it (same value). The command contains no single quotes (validated user name), so the `'...'` wrapping is safe. This path has not been tested with the real image yet (see [KNOWN_BUGS](KNOWN_BUGS.md)); the ImageValidation suite checks `GIT_SSH_COMMAND` in an R process started from a clean login shell.

---

## Docker volumes and container labels

- Names (`Get-ImpactVolumeNames`): `impactncd_output_<container>` and `impactncd_synthpop_<container>` (characters outside `[a-zA-Z0-9_.-]` become `_`). Older versions used per-user names; those volumes are never deleted automatically.
- At Start, before the image check and build:
  1. Leftovers, in both modes: `Get-ImpactVolumeInfo` per volume: Exists true/false/`$null` (unknown), `TargetDir` from the label `impact.target_dir`, `UsedBy` (`docker ps -a --filter volume=`). In use: refused. Leftovers: Yes = `Sync-ImpactVolumeToHost -KeepNewerOnHost` to the recorded folder (else the current one), No = second confirmation (default No), Cancel. Removal only after a successful copy or an explicit discard.
  2. Volume mode: `Initialize-RsyncHelperImage`: `docker image inspect rsync-alpine`, otherwise `docker build -t rsync-alpine -` with the Dockerfile on stdin (`FROM alpine:latest`, `RUN apk add --no-cache rsync`; no build context is uploaded), then inspected again.
- At Start, after the build (volume mode): `docker volume create --label impact.target_dir=<host dir> --label impact.container=<container>`; ownership with `alpine chown <uid>:<gid>`; pre-population with one checked `cp -r /source/. /volume/` (errors: Yes/No, default No).
- `Sync-ImpactVolumeToHost` runs `rsync -ac --no-owner --no-group --no-times --no-perms --chmod=ugo=rwX [--update] /volume/ /backup/` in `rsync-alpine` and checks the exit code. `--update` (switch `-KeepNewerOnHost`, used for leftovers) keeps files that are newer on the host. The target is mounted with `--mount type=bind,source=<dir>,target=/backup`, so Docker refuses a missing folder (with `-v` it would create an empty one); Docker's "bind source path does not exist" becomes a plain message. It returns `{Success, Missing, Message}` and never deletes anything; an empty target is refused. At Stop the caller removes each volume only after its own copy succeeded.
- Container labels (`Get-ImpactContainerLabelArgs`): `impact.use_volumes`, `impact.repo_path`, `impact.output_dir`, `impact.synthpop_dir`, `impact.volume_output`, `impact.volume_synthpop`. `Get-ContainerRuntimeInfo` reads labels and mounts in one `docker inspect` (`{{json .Config.Labels}}<TAB>{{json .Mounts}}`); mounted volume names win over labels, so containers of older versions (no labels) are still recognised. `RepoPath` stays `$null` for containers without `impact.repo_path`.

---

## Git change detection

`Get-GitRepositoryState` returns `HasChanges, StatusText, Branch, Remote, Ahead, HasUpstream, Detached, Conflicts, OperationInProgress`, or `$null` when the status could not be read. With `-Reason ([ref]$why)` the caller also learns why: `GitMissing` (LOCAL only: `Get-Command git` fails; Warn line with what to do), `Unreachable` (no marker and ssh exit 255) or `ReadFailed` (everything else, also exceptions, logged at Warn).

- Remote: one ssh command with marker sections (`__IMPACT_STATUS__`, `__IMPACT_BRANCH__`, `__IMPACT_SYMREF__`, `__IMPACT_REMOTE__`, `__IMPACT_AHEAD__`, `__IMPACT_LOCALAHEAD__`, `__IMPACT_OP__`, `__IMPACT_GITFAIL__`); the path is quoted with `ConvertTo-PosixShellLiteral`. No markers or GITFAIL give `$null` (Warn).
- Local: `Push-Location -LiteralPath` with `try/finally`; a failing `git status` gives `$null`.
- Status: `git -c core.quotePath=false status --porcelain=v1`, so file names with umlauts appear as they are (the module sets the console output encoding to UTF-8). Every non-empty porcelain line is a change. Conflicts are `DD AU UD UA DU AA UU`. Operations are detected from `MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `rebase-merge`, `rebase-apply`.
- Branch: `git rev-parse --abbrev-ref HEAD`. When it prints `HEAD`, `git symbolic-ref -q --short HEAD` decides: a name means a new repository without commits (that name is used), nothing means `Detached = $true`.
- Ahead: `git rev-list --count '@{u}..HEAD'` (`HasUpstream = $true` when it parses). For a branch without upstream, with a branch name and an `origin`, Ahead is `git rev-list --count HEAD --not --remotes` (commits on no remote branch). Detached HEAD: Ahead 0.

`Invoke-GitChangeDetection` returns `[pscustomobject]@{ Success; Outcome; Message }`, Outcome one of NoChanges, Unavailable, Blocked, Skipped, Committed, Pushed, CommitFailed, PushFailed, Error:

1. `$null` state: Unavailable with Success = `$false` and a message per reason ("Your changes were NOT checked or committed: ..." for GitMissing, Unreachable, ReadFailed); no message box, the Stop status line shows it.
2. Unfinished operation or conflicts: message with the files and how to continue/abort; Blocked.
3. Detached HEAD with changes: "Git: not on a branch" (advice: RStudio's New Branch); Blocked, Success = `$false`.
4. Clean tree with Ahead > 0: "Unpushed commits" Yes/No, push only.
5. Changes: `Show-GitCommitDialog` (CRLF-normalised list, no word wrap, both scroll bars; message required; Push ticked by default). Skip with Ahead > 0: a second "Unpushed commits" box offers to push the earlier commits only (NonInteractive: Skipped).
6. Commit: `git add -A`, then `git diff --cached --quiet` decides "nothing to commit" (independent of git's language). Identity `-c user.name=<u> -c user.email=<u>@users.noreply.github.com` (only if the username matches `^[A-Za-z0-9][A-Za-z0-9-]*$`). Remote: the message travels base64-encoded (`printf '%s' '<b64>' | base64 -d | git commit -F -`).
7. Push (`Invoke-GitPushWithImpactKey`): one attempt, only the IMPACT key (`-i <key> -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15`), `GIT_TERMINAL_PROMPT=0`, `git -c url.git@github.com:.pushInsteadOf=https://github.com/ push` (origin is **not** rewritten), `push -u origin HEAD` without upstream, refused on detached HEAD. Local: `GIT_SSH_COMMAND` set only for that push (POSIX-quoted, forward slashes) and restored in `finally`. Remote: the key is `~/.ssh/id_ed25519_<u>` in the shared account. There is no fallback to other keys or ssh-agent.
8. Failures show the last 15 lines of git output; push failures add a hint from `Get-GitPushFailureHint` (detached HEAD: create a branch with RStudio's New Branch or `git switch -c`) and state that the commit is saved but not on GitHub.

---

## Logging

| Setting | Source | Default |
|---|---|---|
| Log file | `$env:IMPACT_LOG_FILE` | `$HOME/.impact_gui/logs/impact.log` |
| Disable file logging | `$env:IMPACT_LOG_DISABLE` = `1`, `true` or `yes` | enabled |
| Debug on the console | `$script:GlobalDebugFlag` (Debug checkbox in the location dialog) | off |
| Rotation | `Initialize-Logging`, once per session | file > 512 KB is renamed to `impact.log.1` (overwriting the previous `.1`) |

`Write-Log -Message -Level Info|Warn|Error|Debug` writes the console line (`[INFO]` cyan, `[WARN]` yellow, `[ERROR]` red, `[DEBUG]` dark grey; Debug only with the flag) and **always** appends `[<timestamp>] [<Level>] <message>` to the file, Debug included. Avoid putting secrets into Debug messages: the RStudio password is masked in the `docker run` log line and only variable names are logged from `docker inspect`.

---

## Security considerations

| Area | Implementation | Notes |
|---|---|---|
| **GitHub key on the workstation** | In remote mode the private key (no passphrase) is copied to `/home/php-workstation/.ssh/id_ed25519_<user>` and kept there; it is bind-mounted into the container and used for host-side pushes. | Everyone who can use the shared account, and root/docker-group users, can read every colleague's key and act as that person on GitHub (all repositories the account can access) until the key is deleted on GitHub. Documented for users in the [User Guide](IMPACT_Docker_GUI_v2_User.md#your-github-key-on-the-shared-workstation). A per-user account or a different credential model needs a maintainer decision. |
| **RStudio password** | Plain text in memory and in the container's `PASSWORD` environment variable. | Readable with `docker inspect` by anyone with Docker access to that engine. Not stored in the remote metadata, and never read from it; masked in logs; hidden in the info box; never printed to the console. The dialog requires a new password of at least 8 characters and warns against reusing the GitHub password. |
| **RStudio network exposure** | LOCAL: `127.0.0.1:<port>`; REMOTE: all interfaces. | Plain HTTP. On the workstation the login page is reachable from the network. |
| **Key transfer** | Private key over ssh **stdin**; plink password in a temp file (`-pwfile`, deleted in `finally`); docker login password over ssh stdin. | Not visible in process command lines. |
| **Host keys** | `StrictHostKeyChecking=accept-new` everywhere: unknown hosts are trusted on first contact, changed keys are refused. A changed workstation key stops before any password is sent (OpenSSH probe and Posh-SSH). plink gets `-hostkey` fingerprints only from keys that come with one OpenSSH already trusts. The workstation's github.com entries are checked against GitHub's three published SHA256 fingerprints (hard-coded in `Ensure-RemotePreparation`; update them if GitHub rotates its keys). | Posh-SSH's `-AcceptKey` keeps its own trust store. No pinning of the workstation's own host key; for key types OpenSSH has not seen yet, the plink fallback trusts like `accept-new`. |
| **Remote metadata** | `/tmp/impactncd/<container>.json`, `umask 077`. Each write and removal also runs `Get-RemoteMetadataCleanupCommand`: `grep -lZE` finds `/tmp/impactncd/*.json` files with a non-empty `"password"` value, and `sed -i -E` replaces only that value with `""` (JSON escapes handled; wrapped so it never fails). | Same shared account, so readable by colleagues; contains no password. Files of older versions are **kept** (older versions read port and volume mode from them on resume); only the password value is blanked, so the older code still finds the `password` key under StrictMode. Files written by this code have no `password` key at all (see KNOWN_BUGS: mixed versions). |
| **authorized_keys clean-up** | Removes lines ending in `IMPACT_<user>` (anchored). | The same user on two PCs removes the other PC's key. |
| **Remote shell quoting** | Paths in remote commands (YAML, folders, build, git, metadata, `.env`) are quoted with `ConvertTo-PosixShellLiteral`, the repo list and `docker_setup` checks with the same `'\''` escaping; commit messages travel base64-encoded; `.env` user/registry are validated. | Paths built only from the validated GitHub user name (key files) are not quoted. |
| **Docker socket** | Local: named pipe; remote: Docker over SSH. Docker group on Linux is root-equivalent. | |
| **Container privileges** | `--rm`, `USERID/GROUPID` of the account, no `--privileged`. | |
| **SSH config** | `~/.ssh/config` lines the user wrote are changed only after `Backup-SshConfigFile` saved a copy. | See [step 5b](#step-5b-remote-preparation-ensure-remotepreparation). |
| **ssh-agent** | Never started elevated (no UAC prompt); optional. | |
| **Log file** | Debug lines are always written to the file. | Contains paths and command lines, not the RStudio password. |

---

## Error handling patterns

1. **Return values instead of exceptions** for workflow steps: `$true`/`$false` or `'next'`/`'back'`/`'cancel'`; `Invoke-ImpactGui` decides where to go.
2. **Message boxes with the real cause**: Docker's or ssh's own error text is kept (`2>&1`) and shown or logged, so the user learns the cause.
3. **Marker words in remote commands** distinguish "the remote command answered" from "ssh failed".
4. **Exit codes are checked** (`$LASTEXITCODE`, reset before the call where a mock could leave an old value).
5. **StrictMode guards**: optional `Metadata` keys are read with `['key']` or created before use; `PSObject.Properties['x']` before reading JSON properties.
6. **Nothing destructive without confirmation or success**: volumes only after a successful copy, leftover volumes only after an explicit choice, Stop only after Yes, folders only after Yes.
7. **Busy mode** for long blocking steps, always ended in `finally`.
8. **Fallback chains**: Docker context, then `DOCKER_HOST`; Posh-SSH, then plink; main Dockerfile, then remote login retry, then prerequisite Dockerfile.
9. **Safety nets for unexpected errors**: `Invoke-ManagerButtonAction` around the Start and Stop code and an `Application.ThreadException` handler for every other window handler call `Show-ImpactUnexpectedError` (full details in the log, a plain message with the log path on screen). The entry point's `catch` handles everything else ("IMPACT - Fatal error").
10. **Exit codes**: 0 for a normal end or Cancel, 1 for a failed wizard step or a fatal error, so `IMPACT.bat` pauses only when something went wrong.

---

## Dependencies

| Dependency | Required? | Used for | How to get it |
|---|---|---|---|
| PowerShell 7.3+ | Yes | Everything | `winget install --id Microsoft.PowerShell --source winget` |
| Docker Desktop | Local mode | Build, run, volumes on the PC | docker.com |
| Docker CLI | Yes | All Docker calls (remote via SSH) | Docker Desktop, or `docker.exe` on PATH |
| Docker Engine | Remote mode | On the workstation | `apt-get install docker-ce ...` |
| OpenSSH client | Yes | `ssh`, `ssh-keygen`, `ssh-add`, `ssh-agent` | Windows feature "OpenSSH Client" |
| Posh-SSH | First remote login | Password bootstrap | `Install-Module Posh-SSH -Scope CurrentUser` |
| plink.exe 0.77+ | Fallback | Password bootstrap without Posh-SSH | PuTTY |
| Git for Windows | Optional | Local commit/push, footer commit | git-scm.com |
| `rsync-alpine` | Volume mode | Copying volumes back | Built automatically from `alpine:latest` |
| `alpine` | Volume mode | Volume ownership and pre-population | Pulled automatically |

---

## Extension points

| Area | How |
|---|---|
| Logging | `IMPACT_LOG_FILE`, `IMPACT_LOG_DISABLE`; extend `Write-Log` for other sinks. |
| Theme | `Initialize-ThemePalette` (Back, Panel, Accent, AccentAlt, Text, Muted, Danger, Success, Field); all UI uses the `Style-*` helpers. |
| Docker build | `Invoke-StartImageBuild` in the Start handler (`-NoCache`); Dockerfile names `docker_setup/Dockerfile.IMPACTncdGER` and `Dockerfile.prerequisite.IMPACTncdGER`. |
| `docker run` | The `$dockerArgs` array in the Start handler; keep `Build-DockerRunCommand` (used by tests) in sync. |
| Remote user / repo base | `RemoteUser` in `New-SessionState`; `RemoteRepoBase` is derived from it in `Select-Location`. Many paths assume `/home/<RemoteUser>`. |
| Port range | `Get-NextAvailablePort`, `Test-PortValue` (8787-8799) and the label in the manager. |
| YAML keys | More `Get-YamlPathValue` calls in the Start handler (single-line `key: value` only). |
| Container SSH/git setup | `Get-ContainerGitSshCommand`, `Get-ContainerSshSetupCommand`, `$gitCfgCmd` in the Start handler. |
| GitHub host key fingerprints | `$ghFpArgs` in `Ensure-RemotePreparation` (three SHA256 values from GitHub's documentation). |
| GitHub key check | `Get-GitHubSshAuthStatus` (patterns), `Confirm-GitHubKeyRegistered` (dialog and session memory). |
| Git flow | `Invoke-GitChangeDetection`, `Invoke-GitPushWithImpactKey`, `Get-GitPushFailureHint`. |

---

## Known limitations

See [KNOWN_BUGS.md](KNOWN_BUGS.md) for open bugs. Design limitations:

| Limitation | Details |
|---|---|
| Shared workstation account | Keys and RStudio passwords of all colleagues are readable within `php-workstation` (see Security). |
| One container per repository and user | Name `<repo>_<user>`; two clones with the same folder name cannot run at the same time. |
| One window per IMPACT instance | The UI is modal; long steps block the window (busy mode). |
| Shared repository checkout on the workstation | All colleagues use the same folders; only a warning protects against two containers on one folder. |
| Simple YAML parser | Single-line `key: value` only. |
| No TLS for RStudio | Plain HTTP. |
| Docker over SSH only | No TCP/TLS Docker endpoints. |
| Remote Docker start needs sudo | Typed in the console. |
| First builds use `--no-cache` | The first main build, the prerequisite build and Rebuild start from scratch; only the retries reuse the cache (maintainer decision, see KNOWN_BUGS). |
| No container log viewer | Use `docker logs <container>`. |
