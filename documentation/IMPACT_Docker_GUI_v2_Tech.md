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
| Docker access | Docker contexts passed explicitly with `--context` (`Get-DockerContextArgs`); remote fallback `DOCKER_HOST=ssh://...` (`Flags.UseDirectSsh`). |
| Remote execution | OpenSSH `ssh` with `BatchMode=yes`, `IdentitiesOnly=yes`, `StrictHostKeyChecking=accept-new`; Posh-SSH or plink only for the first password login. |
| Remote commands | Most remote commands print marker words (`IMPACT_KEY_OK`, `YAML_MISSING`, `__IMPACT_STATUS__`, ...) so "command ran and said no" can be told apart from "ssh failed". |
| Session recovery | Docker labels on the container (authoritative) plus a small JSON file in `/tmp/impactncd/` on the workstation. |
| Strict mode | `Set-StrictMode -Version Latest` in the module and the GUI script. Reading a missing hashtable key with dot notation throws, so optional `Metadata` keys are read with `['key']`. |
| Wizard | `Invoke-ImpactGui` runs steps 1-6 in a loop; failures or Cancel in preparation go back to step 4, Back in the manager goes to step 4, Back in step 4 goes to step 2. |

---

## Launchers and PowerShell version

### `IMPACT.bat`

1. `cd /d "%~dp0"`; stops with an explanation if `IMPACT_Docker_GUI_v2.ps1` or `IMPACT_Docker_GUI.psm1` is not next to it.
2. Finds `pwsh.exe` with `where`, then `%ProgramFiles%\PowerShell\7\pwsh.exe` (Explorer may still have an old PATH right after installing).
3. Missing: prints install instructions (`winget install --id Microsoft.PowerShell --source winget`, <https://aka.ms/powershell-release>, Microsoft Store, ask IT), offers to open the download page, exits 1. **No fallback to Windows PowerShell 5.1.**
4. Version check: `pwsh -Command` exits 3 when the version is below 7.3; the launcher then shows update instructions (`winget upgrade ...`) and pauses.
5. Runs `pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File IMPACT_Docker_GUI_v2.ps1 %*`, saves `%errorlevel%` on the next line (outside any `( )` block, where cmd would expand it too early) and pauses on any non-zero code, also negative crash codes.

Both `.bat` files must have CRLF line endings; `.gitattributes` (`*.bat text eol=crlf`, `*.cmd text eol=crlf`) makes git write them that way into every checkout and into GitHub's ZIP download.

### `Create-Shortcut.bat`

Creates `IMPACT.lnk` on the Desktop with `WScript.Shell` via Windows PowerShell (always present). Target `IMPACT.bat`, working directory and icon from the tool folder. The folder path is passed through the environment variable `IMPACT_SHORTCUT_DIR`, so paths containing `&` or `'` work. Prints a note when PowerShell 7 is not installed yet.

### `Ensure-PowerShell7` (module)

- Supported (`Test-PowerShellVersionSupported`: Core edition and version 7.3 or newer): returns immediately.
- PowerShell 7.0-7.2: message box "PowerShell update required" and `throw` (no relaunch, which would loop).
- Windows PowerShell 5.1 with `pwsh` on PATH: relaunches `IMPACT_Docker_GUI_v2.ps1` (found next to the module via `$PSScriptRoot`) with `pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "<script>" -PS7Requested` (`Start-Process -NoNewWindow -Wait -PassThru`) and exits with its exit code. `-PS7Requested` prevents a second relaunch.
- 5.1 without `pwsh`: message box with the install hint and `throw`.

The top-level `catch` in the GUI script logs the exception, shows "IMPACT - Fatal error", waits for Enter and exits 1 (so `IMPACT.bat` also pauses).

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
+-- SelectedRepo       [string]  Docker-safe repo name (local: ConvertTo-DockerSafeRepoName; remote: folder name as listed)
+-- ContainerName      [string]  "<SelectedRepo>_<UserName>"
+-- Paths    [hashtable]  LocalRepo, RemoteRepo, OutputDir, SynthpopDir, SshPrivate, SshPublic
+-- Flags    [hashtable]  Debug, UseDirectSsh, PS7Requested
|                         (UseVolumes, Rebuild, HighComputeDemand exist but are unused:
|                          the Start handler reads the checkboxes directly)
+-- Ports    [hashtable]  Used (ports mapped to 8787/tcp by running containers)
|                         (Requested, Assigned exist but are unused)
+-- Metadata [hashtable]  created empty; keys are added as the workflow runs:
    BuildInfo              {Version, Commit, Built}        Get-BuildInfo
    PublicKey              public key text                 Ensure-GitKeySetup
    LocalDockerContext     'local'                         Ensure-LocalPreparation
    RemoteDockerContext    'remote-<ip>'                   Ensure-RemotePreparation
    RemoteSshCheckStatus   OK|KeyMissing|Unreachable|HostKeyChanged|LoginFailed   Test-RemoteSSHKeyFiles
    RemoteSshCheckMessage  text for the user or $null      Test-RemoteSSHKeyFiles
    DockerReachable        [bool] first docker ps worked   Get-ContainerStatus
    ExistingContainers     [{Name,Status,Ports,Image}]     Get-ContainerStatus
    ContainerRunning       [bool]
    Recovered              {Password, Port, UseVolumes, OutputDir, SynthpopDir, VolumeOutput, VolumeSynthpop}
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
| Remote helpers | `Test-RemoteSSHKeyFiles` (one ssh call; only the private key is required; records status and message), `Get-SshFailureKind` (HostKeyChanged / Unreachable / AuthFailed / Unknown from OpenSSH and Posh-SSH texts), `ConvertTo-RemoteRepoList`, `Write-RemoteContainerMetadata` (no password; `umask 077`), `Read-RemoteContainerMetadata`, `Remove-RemoteContainerMetadata`, `Get-DockerCredentialsFromDotEnv` (`[string[]]` input), `Ensure-RemoteDockerLogin` (password via ssh stdin, registry passed unless Docker Hub, user/registry validated) |
| Container info, ports, errors | `Get-ContainerRuntimeInfo` (password and port from `docker inspect`, volume mode/folders/volume names from labels and mounts; `UseVolumes = $null` when unknown), `Get-NextAvailablePort` (8787-8799), `Test-PortValue` (digits only, at most 5, no leading zero, in range), `Get-UsedPorts` (any host address in `:<port>->8787/tcp`), `Format-DockerError` |
| YAML and folders | `Get-YamlPathValue` (single-line `key: value`; strips `"..."`/`'...'` with their escapes; empty, `~`, `null` give `$null`; `~/` becomes `/home/<RemoteUser>` in remote mode; relative paths are joined to `-BaseDir`; remote read prints a marker when the file is missing), `Test-AndCreateDirectory` (optional `-Create`, optional `-Reason [ref]` = EmptyPath, Missing, PosixPathInLocalMode, Unreachable, CreateFailed; never creates without `-Create`) |
| Git | `Get-GitRepositoryState`, `Show-GitCommitDialog`, `Invoke-GitChangeDetection` (see [Git change detection](#git-change-detection)) |
| UI and theme | `Set-FormCenterOnCurrentScreen` (centres on the monitor with the mouse pointer, P/Invoke), `Initialize-ThemePalette`, `Get-ThemePalette`, `Apply-ThemeToForm`, `Style-Label`, `Style-TextBox`, `Style-CheckBox`, `Style-Button`, `Style-InfoBox` |
| Startup and dialogs | `Test-StartupPrerequisites` (docker CLI and ssh only; it does **not** check the Docker daemon), `Ensure-Prerequisites` (WinForms, UTF-8 console output, prerequisites, admin info, console title, git warning), `Show-CredentialDialog`, `Ensure-SshAgentRunning`, `Remove-SshConfigHostBlock`, `Ensure-SshConfigEntry`, `Ensure-GitKeySetup`, `Select-Location` |
| Container commands | `ConvertTo-DockerSafeRepoName`, `Build-DockerRunCommand` (pure; same arguments as the Start handler; used by tests), `Get-ImpactVolumeNames`, `Split-DockerCustomParams`, `Get-ImpactContainerLabelArgs`, `Get-ImpactVolumeInfo`, `Initialize-RsyncHelperImage`, `Sync-ImpactVolumeToHost`, `Get-ContainerGitSshCommand`, `Get-ContainerSshSetupCommand` |
| Docker Desktop, GitHub API | `Test-DockerDaemonReady`, `Start-DockerDesktopIfNeeded`, `Add-GitHubSshKey`, `Remove-GitHubSshKey` (used by the E2E tests), `Test-GitHubUsername` (`-Detailed` returns Status Exists / NotFound / Organization / Unknown and a message; only HTTP 404 means NotFound) |

### Module, private (reached from tests with `InModuleScope`)

`Test-PowerShellVersionSupported`, `Resolve-GitHubUsernameInput`, `Get-RStudioPasswordProblem`, `ConvertTo-PosixShellLiteral` (single-quotes a value for sh: `'` becomes `'\''`), `ConvertTo-GitOutputText`, `Get-GitPushFailureHint`, `Invoke-GitPushWithImpactKey`.

### GUI script (`IMPACT_Docker_GUI_v2.ps1`)

| Function | Purpose |
|---|---|
| `Ensure-RemotePreparation` | Key login probe, password bootstrap, key copy, known_hosts, repo list, Docker context, remote Docker checks. |
| `Ensure-LocalPreparation` | Folder picker and checks, Docker Desktop start/wait, `local` context. |
| `Get-ContainerStatus` | Port scan, own containers, running check, leftover stopped container, recovery of password/port/volume details. |
| `Show-ContainerManager` | Main window. Nested: `Set-ManagerBusy`, `Update-InfoBox`; in the Start handler `Confirm-YamlFolder`, `ConvertTo-QuotedArgument`, `Invoke-StartImageBuild`. |
| `Invoke-ImpactGui` | The wizard loop. |

---

## Workflow

### Step 1: prerequisites (`Ensure-Prerequisites`)

Loads WinForms, sets `[Console]::OutputEncoding` to UTF-8 (no BOM) so docker/ssh/git output with umlauts is decoded correctly, then `Test-StartupPrerequisites`:

- `docker` missing: "Docker missing" (Docker Desktop for local; `docker.exe` on PATH is enough for remote).
- `ssh` missing: first `%WINDIR%\System32\OpenSSH\ssh.exe` is added to PATH if present; otherwise the user is **asked**, then `Get-WindowsCapability ... | Add-WindowsCapability` runs in an elevated Windows PowerShell via `-EncodedCommand`. A cancelled UAC prompt is logged; "SSH missing" explains the manual install.

After `Clear-Host`, a console warning appears if `git` is not on PATH (commit offer unavailable in local mode).

### Step 2: credentials (`Show-CredentialDialog`)

All checks run inside the Continue handler while the form is open:

1. `Resolve-GitHubUsernameInput`: removes whitespace, lowercases, accepts `github.com/<name>` links and `@name`, rejects e-mail addresses (own hint) and anything not matching `^[a-z0-9][a-z0-9_-]{0,38}$`.
2. `Get-RStudioPasswordProblem`: at least 8 characters, not equal to the username (case-insensitive), not in a short list of common passwords.
3. `Test-GitHubUsername -Detailed` with a 15 s timeout: NotFound/Organization keep the dialog open; Unknown (no status, 403/429 rate limit, 407 proxy, other HTTP errors) asks "Continue anyway?".

Fields are pre-filled from `$State`; when the user came back with Back, Cancel returns `'next'` and keeps the previous values. NonInteractive mode validates the pre-set values and only warns about a weak password.

### Step 3: SSH key (`Ensure-GitKeySetup`)

- Path: `Join-Path $HOME '.ssh'` + `id_ed25519_<user>`.
- Existing pair: reused; public key printed; `Ensure-SshAgentRunning`.
- Missing: `ssh-keygen -t ed25519 -C IMPACT_<user> -f <path> -N '' -q`, run inside `& { $PSNativeCommandArgumentPassing = 'Standard'; ... }` so the empty passphrase is passed even if a profile set Legacy mode. Public key to clipboard, message box and key window (Copy to Clipboard). Then `Ensure-SshAgentRunning`.
- `Ensure-SshAgentRunning`: starts the `ssh-agent` service (elevated `Set-Service ... -StartupType Automatic; Start-Service` if needed), removes agent keys whose file was deleted (when the `.pub` still exists), `ssh-add`s the key unless already loaded.

### Step 4: location (`Select-Location`)

Local/Remote buttons, IP text box (pre-filled from `WORKSTATION_IP=` in `.env` in the module folder or its parent), Debug checkbox (sets `$script:GlobalDebugFlag`), Back. The IP must match `^\d{1,3}(\.\d{1,3}){3}$` (octets above 255 are not rejected). Sets `ContainerLocation`, `RemoteHost`, `RemoteRepoBase`.

### Step 5a: local preparation (`Ensure-LocalPreparation`)

1. `FolderBrowserDialog` (starts in Documents).
2. Rejects UNC paths and drives whose `DriveInfo.DriveType` is `Network`; requires `docker_setup` (`Test-Path -LiteralPath`); `ConvertTo-DockerSafeRepoName` (unchanged if valid; otherwise accents removed, `ss` for sharp s, runs of other characters to `_`; empty result is rejected); OneDrive warning (Yes/No); `.git` check (Yes/No).
3. Clears `DOCKER_HOST`/`DOCKER_SSH_OPTS`; creates the `local` context (`npipe:////./pipe/docker_engine` on Windows) if missing.
4. Quick check `docker --context local version` (stderr kept). "access is denied / Zugriff verweigert / permission denied" together with not-confirmed `docker-users` membership (SID-based, language independent) shows the docker-users help and returns `$false`.
5. Not running: starts Docker Desktop (`Program Files`, then `LocalAppData`, then service `com.docker.service`), polls `docker info` up to 30 times in background jobs with a 5 s limit each. Then the Yes/No/Cancel loop (Yes = check again 10 times; No = continue knowingly; Cancel = back).
6. `docker context use local` (**changes the user's global Docker context**; kept because the local image build does not pass `--context` yet).
7. Final `docker --context local version`; failure returns `$false` unless the user chose to continue anyway.

### Step 5b: remote preparation (`Ensure-RemotePreparation`)

1. `Ensure-SshConfigEntry` for the IP (see the [User Guide](IMPACT_Docker_GUI_v2_User.md#the-ssh-config-entry) for when the block is replaced).
2. Probe `ssh -n -i <key> -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 <host> echo KEY_AUTH_OK`. On failure `Get-SshFailureKind`: Unreachable and HostKeyChanged stop **before** any password prompt (no password is sent to a host whose key changed).
3. Password bootstrap (only when the key is refused):
   - Password dialog, then **Posh-SSH** (offers `Install-Module Posh-SSH -Scope CurrentUser`): `New-SSHSession -AcceptKey`, upload of the public key to a temp file, install script (single-quoted here-string with `%%USERNAME%%` / `%%REMOTE_TEMP%%` replaced by `.Replace()`, line endings converted to LF; `umask 077`; `chmod go-w` on the home folder; `.ssh` 700; `authorized_keys` 600; removes old lines ending in `IMPACT_<user>` with an anchored `sed`; prints `SSH_KEY_COPIED`). A wrong password (Permission denied) shows "Wrong password" and the preparation is re-run, so the dialog returns.
   - **plink** only when Posh-SSH is not available: script converted to LF and piped to `plink -batch -ssh -pwfile <temp file> -hostkey <SHA256 fingerprints from ssh-keygen -l -F <ip>> <host> bash -s` (PuTTY 0.77+ for `-pwfile`); success needs exit 0 and `SSH_KEY_COPIED`.
   - Afterwards the key login is verified once more ("SSH key setup failed" otherwise).
4. Private key copy: the key text is piped to `ssh` on **stdin** (not on the command line): `umask 077 && mkdir -p ~/.ssh && chmod 700 ~/.ssh && tr -d '\r' > <key>.tmp && chmod 600 ... && mv -f ... && echo PRIVATE_KEY_COPIED`. A missing marker is only logged (Warn).
5. known_hosts on the workstation: `touch ~/.ssh/known_hosts`; github.com keys are appended with `ssh-keyscan -t ed25519,ecdsa,rsa` only when `ssh-keygen -F github.com` finds none. This PC's known_hosts is no longer copied there, and existing lines are never changed.
6. Repo list: `find '<base>' -mindepth 1 -maxdepth 1 -xtype d ! -name '.*' -printf '%f\n'`; `ConvertTo-RemoteRepoList` drops ErrorRecords and blank lines. Empty list: "No repositories found" (or "lost the connection" on exit 255 / Unreachable). The selected name is used **unchanged** for `SelectedRepo` and `ContainerName`.
7. Docker context `remote-<ip>` (`host=ssh://<host>`) is created if missing; failure sets `Flags.UseDirectSsh`. The global context is **not** switched; if it still points at `remote-<ip>` (older versions), it is reset to `default`.
8. Remote `docker version` over ssh: permission denied on the socket ("ask the admin to run `sudo usermod -aG docker <user>`"), CLI missing ("Docker Engine Missing"), daemon down (offer `sudo systemctl start docker` in the console via `Start-Process ssh -t`), `groups` check.

### Step 6: status (`Get-ContainerStatus`)

1. `docker ps --format '{{.Names}}\t{{.Ports}}'` with stderr kept. Failure: "Docker Not Reachable" Retry/Cancel; `Metadata.DockerReachable = $false` and the next calls are skipped.
2. `Ports.Used` from every `:<port>->8787/tcp` match.
3. Own containers: `docker ps -a --filter name=_<escaped user>$`.
4. Running check: `--filter name=^<ContainerName>$`.
5. A stopped same-named container (can only come from outside the app because of `--rm`): "Old Container Found", `docker rm` on Yes.
6. `Metadata.Recovered` is reset, then filled for a running container from the remote metadata (port, useVolumes; a password only from files written by old versions) and from `Get-ContainerRuntimeInfo` (authoritative).

### Step 7: Start (Start handler in `Show-ContainerManager`)

Order of checks and actions:

1. `Set-DockerSSHEnvironment`; already running; `Test-PortValue`; port in `Ports.Used`.
2. Remote: `Test-RemoteSSHKeyFiles`; the message box shows `Metadata['RemoteSshCheckMessage']`.
3. Other own containers running (Yes/No).
4. `docker_setup` (local); YAML file: local `Test-Path`, remote `test -f ... && echo YAML_OK || echo YAML_MISSING`.
5. `Get-YamlPathValue` for `output_dir` and `synthpop_dir`, then `Confirm-YamlFolder` with `Test-AndCreateDirectory -Reason`: separate messages per reason; a missing folder can be created (Yes/No) locally, or on the workstation only inside the repository.
6. Image check: `docker <ctx> images --format '{{.Repository}}'` against `SelectedRepo.ToLower()`.
7. Build (if missing or Rebuild): busy mode (`Set-ManagerBusy`), `Invoke-StartImageBuild`:
   - local: `docker build --build-arg REPO_NAME=<repo> -f docker_setup/Dockerfile.IMPACTncdGER -t <image> --no-cache --progress=plain .` in the repo folder (no `--context`), via `Start-Process -NoNewWindow` with every argument quoted by `ConvertTo-QuotedArgument`, so the log streams to the console;
   - remote: `ssh ... "cd '<repo>' && docker build --build-arg REPO_NAME=<repo> -f '<dockerfile>' -t '<image>' --no-cache ."`;
   - fallbacks, all automatic: remote `Ensure-RemoteDockerLogin` + retry; then `Dockerfile.prerequisite.IMPACTncdGER` (tag `<image>-prerequisite`, context `docker_setup`) and the main build again. Every attempt uses `--no-cache`.
   - `finally { Set-ManagerBusy -Busy $false }`.
8. Git baseline (best effort, `git -C`; not used later).
9. Shared repository warning: bind sources of all running containers (`docker ps -q` + one `docker inspect`) compared with the repo path (remote exact, local by path ending). Default No.
10. uid/gid: `1000:1000` locally; `id -u` / `id -g` of the SSH user remotely.
11. `docker run -d --rm --name <container> -e PASSWORD=... -e DISABLE_AUTH=false -e USERID -e GROUPID -e CONTAINER_REPO_NAME -e SYNC_ENABLED=false -e GIT_SSH_COMMAND=<Get-ContainerGitSshCommand> --mount type=bind,source=<repo>,target=/home/rstudio/<repo> -p <publish> [custom params] [volume or bind mounts for outputs and synthpop] [--cpus 32 -m 384g] [labels] --mount type=bind,source=<key>,target=/keys/id_ed25519_<user>,readonly --workdir /home/rstudio/<repo> <image>`
    - `<publish>` = `127.0.0.1:<port>:8787` for LOCAL (only this PC), `<port>:8787` for REMOTE.
    - `<key>` = the local key path, or `/home/<RemoteUser>/.ssh/id_ed25519_<user>` on the workstation.
    - Custom params are split by `Split-DockerCustomParams` (quotes respected, no empty arguments).
    - The host's `known_hosts` is **not** mounted.
    - The ports are scanned again right before `docker run`; errors go through `Format-DockerError`. The password is masked (`PASSWORD=***`) in the debug log line.
12. In-container setup (see the next section), each step retried 3 times, 2 s apart.
13. `docker ps` check that the container still exists ("Container stopped" otherwise; fresh volumes removed).
14. "Container setup incomplete" warning if `KEY_FIXED` or `GIT_CONFIGURED` is missing.
15. Remote metadata JSON (`container, repo, user, port, useVolumes, timestamp`; no password).
16. `Recovered` reset, `Active*` set, info box RUNNING; the console prints the URL but never the password.

### Step 8: Stop (Stop handler)

1. `docker ps --filter name=^<container>$`: a non-zero exit means "unknown" ("Docker not reachable", state unchanged). Not listed means it already ended: no confirmation, no `docker stop`, but full clean-up.
2. "Stop container?" Yes/No with **No as default button**; `docker stop`.
3. Volume mode (`ActiveUseVolumes`): refuses to copy when volume names or target folders are unknown; otherwise `Sync-ImpactVolumeToHost` for both. Volumes are removed (`volume rm -f`, retried 5 times) only when both copies succeeded; otherwise "Results still in Docker volumes" names them and says what happens on the next Start.
4. `ContainerRunning = $false`, remote metadata removed, `Recovered` reset, `Ports.Used` refreshed (so the freed port can be used again), info box STOPPED.
5. `Invoke-GitChangeDetection` for `ActiveRepoPath` / `ActiveIsRemote`. Its return value is currently not used: the status line says "All done" unless a volume problem occurred.

### Busy mode (`Set-ManagerBusy`)

Saves and disables Start/Stop/Back/Close, sets `Metadata.Busy`, shows a status text and the wait cursor and calls `$form.Refresh()` (no `DoEvents`, so no other click can run in the middle). `FormClosing` refuses to close while `Metadata['Busy']` is set ("Please wait"). Currently only the image build uses it; volume copies and `docker run` still block without busy mode.

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

Git configuration (`docker exec --user rstudio`): `user.name <u>`, `user.email <u>@users.noreply.github.com`, `pull.ff true`, `pull.rebase false`, `safe.directory '*'`; prints `GIT_CONFIGURED`.

Whether RStudio's own R sessions (rsession) see `GIT_SSH_COMMAND` depends on the image copying container variables into `Renviron.site`; the ImageValidation suite checks this with an R process started from a clean login shell.

---

## Docker volumes and container labels

- Names (`Get-ImpactVolumeNames`): `impactncd_output_<container>` and `impactncd_synthpop_<container>` (characters outside `[a-zA-Z0-9_.-]` become `_`). Older versions used per-user names; those volumes are never deleted automatically.
- At Start (volume mode):
  1. `Initialize-RsyncHelperImage`: `docker image inspect rsync-alpine`, otherwise `docker build -t rsync-alpine -` with the Dockerfile on stdin (`FROM alpine:latest`, `RUN apk add --no-cache rsync`; no build context is uploaded), then inspected again.
  2. `Get-ImpactVolumeInfo` per volume: Exists true/false/`$null` (unknown), `TargetDir` from the label `impact.target_dir`, `UsedBy` (`docker ps -a --filter volume=`). In use: refused. Leftovers: Yes = `Sync-ImpactVolumeToHost` to the recorded folder (else the current one), No = second confirmation (default No), Cancel. Removal only after a successful copy or an explicit discard.
  3. `docker volume create --label impact.target_dir=<host dir> --label impact.container=<container>`; ownership with `alpine chown <uid>:<gid>`; pre-population with one checked `cp -r /source/. /volume/` (errors: Continue/Cancel, default No).
- At Stop: `Sync-ImpactVolumeToHost` runs `rsync -ac --no-owner --no-group --no-times --no-perms --chmod=ugo=rwX /volume/ /backup/` in `rsync-alpine` and checks the exit code. It returns `{Success, Missing, Message}` and never deletes anything; an empty target is refused.
- Container labels (`Get-ImpactContainerLabelArgs`): `impact.use_volumes`, `impact.output_dir`, `impact.synthpop_dir`, `impact.volume_output`, `impact.volume_synthpop`. `Get-ContainerRuntimeInfo` reads labels and mounts in one `docker inspect` (`{{json .Config.Labels}}<TAB>{{json .Mounts}}`); mounted volume names win over labels, so containers of older versions (no labels) are still recognised.

---

## Git change detection

`Get-GitRepositoryState` returns `HasChanges, StatusText, Branch, Remote, Ahead, HasUpstream, Conflicts, OperationInProgress`, or `$null` when the status could not be read.

- Remote: one ssh command with marker sections (`__IMPACT_STATUS__`, `__IMPACT_BRANCH__`, `__IMPACT_REMOTE__`, `__IMPACT_AHEAD__`, `__IMPACT_OP__`, `__IMPACT_GITFAIL__`); the path is quoted with `ConvertTo-PosixShellLiteral`. No markers or GITFAIL give `$null` (Warn).
- Local: `Push-Location -LiteralPath` with `try/finally`; a failing `git status` gives `$null`.
- Every non-empty porcelain line is a change. Conflicts are `DD AU UD UA DU AA UU`. Ahead is `git rev-list --count '@{u}..HEAD'` (0 without upstream). Operations are detected from `MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `rebase-merge`, `rebase-apply`.

`Invoke-GitChangeDetection` returns `[pscustomobject]@{ Success; Outcome; Message }`, Outcome one of NoChanges, Unavailable, Blocked, Skipped, Committed, Pushed, CommitFailed, PushFailed, Error:

1. `$null` state: Unavailable (Success = `$true`, no message box).
2. Unfinished operation or conflicts: message with the files and how to continue/abort; Blocked.
3. Clean tree with Ahead > 0: "Unpushed commits" Yes/No, push only.
4. Changes: `Show-GitCommitDialog` (CRLF-normalised list, no word wrap, both scroll bars; message required; Push ticked by default).
5. Commit: `git add -A`, then `git diff --cached --quiet` decides "nothing to commit" (independent of git's language). Identity `-c user.name=<u> -c user.email=<u>@users.noreply.github.com` (only if the username matches `^[A-Za-z0-9][A-Za-z0-9-]*$`). Remote: the message travels base64-encoded (`printf '%s' '<b64>' | base64 -d | git commit -F -`).
6. Push (`Invoke-GitPushWithImpactKey`): one attempt, only the IMPACT key (`-i <key> -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15`), `GIT_TERMINAL_PROMPT=0`, `git -c url.git@github.com:.pushInsteadOf=https://github.com/ push` (origin is **not** rewritten), `push -u origin HEAD` without upstream, refused on detached HEAD. Local: `GIT_SSH_COMMAND` set only for that push (POSIX-quoted, forward slashes) and restored in `finally`. Remote: the key is `~/.ssh/id_ed25519_<u>` in the shared account. There is no fallback to other keys or ssh-agent.
7. Failures show the last 15 lines of git output; push failures add a hint from `Get-GitPushFailureHint` and state that the commit is saved but not on GitHub.

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
| **RStudio password** | Plain text in memory and in the container's `PASSWORD` environment variable. | Readable with `docker inspect` by anyone with Docker access to that engine. Not stored in the remote metadata any more; masked in logs; hidden in the info box; never printed to the console. The dialog requires a new password of at least 8 characters and warns against reusing the GitHub password. |
| **RStudio network exposure** | LOCAL: `127.0.0.1:<port>`; REMOTE: all interfaces. | Plain HTTP. On the workstation the login page is reachable from the network. |
| **Key transfer** | Private key over ssh **stdin**; plink password in a temp file (`-pwfile`, deleted in `finally`); docker login password over ssh stdin. | Not visible in process command lines. |
| **Host keys** | `StrictHostKeyChecking=accept-new` everywhere: unknown hosts are trusted on first contact, changed keys are refused. A changed workstation key stops before any password is sent. | Posh-SSH's `-AcceptKey` keeps its own trust store. No fingerprint pinning. |
| **Remote metadata** | `/tmp/impactncd/<container>.json`, `umask 077`. | Same shared account, so readable by colleagues; contains no password. Files written by older versions may still contain one until that container is stopped. |
| **authorized_keys clean-up** | Removes lines ending in `IMPACT_<user>` (anchored). | The same user on two PCs removes the other PC's key. |
| **Remote shell quoting** | Git commands use `ConvertTo-PosixShellLiteral`; commit messages travel base64-encoded; `.env` user/registry are validated. | Several other remote commands still wrap paths in plain `'...'`. |
| **Docker socket** | Local: named pipe; remote: Docker over SSH. Docker group on Linux is root-equivalent. | |
| **Container privileges** | `--rm`, `USERID/GROUPID` of the account, no `--privileged`. | |
| **Log file** | Debug lines are always written to the file. | Contains paths and command lines, not the RStudio password. |

---

## Error handling patterns

1. **Return values instead of exceptions** for workflow steps: `$true`/`$false` or `'next'`/`'back'`/`'cancel'`; `Invoke-ImpactGui` decides where to go.
2. **Message boxes with the real cause**: Docker's or ssh's own error text is kept (`2>&1`) and shown or logged, rather than a generic "failed".
3. **Marker words in remote commands** distinguish "the remote command answered" from "ssh failed".
4. **Exit codes are checked** (`$LASTEXITCODE`, reset before the call where a mock could leave an old value).
5. **StrictMode guards**: optional `Metadata` keys are read with `['key']` or created before use; `PSObject.Properties['x']` before reading JSON properties.
6. **Nothing destructive without confirmation or success**: volumes only after a successful copy, leftover volumes only after an explicit choice, Stop only after Yes, folders only after Yes.
7. **Busy mode** for long blocking steps.
8. **Fallback chains**: Docker context, then `DOCKER_HOST`; Posh-SSH, then plink; main Dockerfile, then remote login retry, then prerequisite Dockerfile.

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
| Docker build | `Invoke-StartImageBuild` in the Start handler; Dockerfile names `docker_setup/Dockerfile.IMPACTncdGER` and `Dockerfile.prerequisite.IMPACTncdGER`. |
| `docker run` | The `$dockerArgs` array in the Start handler; keep `Build-DockerRunCommand` (used by tests) in sync. |
| Remote user / repo base | `RemoteUser` in `New-SessionState`; `RemoteRepoBase` is derived from it in `Select-Location`. Many paths assume `/home/<RemoteUser>`. |
| Port range | `Get-NextAvailablePort`, `Test-PortValue` (8787-8799) and the label in the manager. |
| YAML keys | More `Get-YamlPathValue` calls in the Start handler (single-line `key: value` only). |
| Container SSH/git setup | `Get-ContainerGitSshCommand`, `Get-ContainerSshSetupCommand`, `$gitCfgCmd` in the Start handler. |
| Git flow | `Invoke-GitChangeDetection`, `Invoke-GitPushWithImpactKey`, `Get-GitPushFailureHint`. |

---

## Known limitations

See [KNOWN_BUGS.md](KNOWN_BUGS.md) for open bugs. Design limitations:

| Limitation | Details |
|---|---|
| Shared workstation account | Keys and RStudio passwords of all colleagues are readable within `php-workstation` (see Security). |
| One container per repository and user | Name `<repo>_<user>`. |
| One window per IMPACT instance | The UI is modal; long steps block the window (busy mode). |
| Shared repository checkout on the workstation | All colleagues use the same folders; only a warning protects against two containers on one folder. |
| Simple YAML parser | Single-line `key: value` only. |
| No TLS for RStudio | Plain HTTP. |
| Docker over SSH only | No TCP/TLS Docker endpoints. |
| Remote Docker start needs sudo | Typed in the console. |
| Builds always use `--no-cache` | Every build, including the automatic retries, starts from scratch. |
| No container log viewer | Use `docker logs <container>`. |
