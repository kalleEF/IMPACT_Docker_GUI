# IMPACT Docker GUI v2 — Technical Documentation

> Engineering reference for `IMPACT_Docker_GUI_v2.ps1`: architecture, data model, function catalogue, workflow internals, security considerations, and extension points.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Data Model — `New-SessionState`](#data-model--new-sessionstate)
3. [Function Reference](#function-reference)
   - [Infrastructure & Logging](#infrastructure--logging)
   - [SSH & Remote Helpers](#ssh--remote-helpers)
   - [Docker Helpers](#docker-helpers)
   - [Path & YAML Helpers](#path--yaml-helpers)
   - [Git Integration](#git-integration)
   - [UI Theming & Layout](#ui-theming--layout)
   - [UI Dialogs (Workflow Steps)](#ui-dialogs-workflow-steps)
   - [Coordinator](#coordinator)
4. [UI Dialogs Reference](#ui-dialogs-reference)
5. [End-to-End Workflow](#end-to-end-workflow)
   - [Phase 0 — PowerShell 7 Relaunch](#phase-0--powershell-7-relaunch)
   - [Phase 1 — Prerequisites & Credentials](#phase-1--prerequisites--credentials)
   - [Phase 2 — SSH Key Setup](#phase-2--ssh-key-setup)
   - [Phase 3 — Location Selection](#phase-3--location-selection)
   - [Phase 4 — Environment Preparation](#phase-4--environment-preparation)
   - [Phase 5 — Password Bootstrap (Remote)](#phase-5--password-bootstrap-remote)
   - [Phase 6 — Container Status Detection](#phase-6--container-status-detection)
   - [Phase 7 — Container Start](#phase-7--container-start)
   - [Phase 8 — Container Stop & Data Sync](#phase-8--container-stop--data-sync)
   - [Phase 9 — Git Change Detection](#phase-9--git-change-detection)
6. [Logging Subsystem](#logging-subsystem)
7. [Security Considerations](#security-considerations)
8. [Error Handling Patterns](#error-handling-patterns)
9. [Dependency Matrix](#dependency-matrix)
10. [Compile Pipeline](#compile-pipeline)
11. [Extension Points](#extension-points)
12. [Known Limitations](#known-limitations)

---

## Architecture Overview

```
┌────────────────────────────────────────────────────────────────────┐
│                      IMPACT_Docker_GUI_v2.ps1                      │
│                         (2,443 lines, PS7)                         │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  ┌─────────────┐   ┌──────────────┐   ┌─────────────────────────┐ │
│  │  Invoke-     │──>│  Sequential  │──>│  Show-ContainerManager  │ │
│  │  ImpactGui   │   │  Setup Steps │   │  (main event loop)      │ │
│  │  (coord.)    │   │  1→2→3→4→5   │   │  Start / Stop buttons   │ │
│  └─────────────┘   └──────────────┘   └─────────────────────────┘ │
│         │                                        │                 │
│         ▼                                        ▼                 │
│  ┌─────────────┐   ┌──────────────┐   ┌─────────────────────────┐ │
│  │   Session    │   │   Docker     │   │   Git Change            │ │
│  │   State      │   │   Engine     │   │   Detection             │ │
│  │ (PSCustomObj)│   │ (local/SSH)  │   │   + Commit/Push         │ │
│  └─────────────┘   └──────────────┘   └─────────────────────────┘ │
│         │                │                                         │
│         ▼                ▼                                         │
│  ┌─────────────┐   ┌──────────────┐                               │
│  │   Write-Log  │   │   SSH / SCP  │                               │
│  │   (file +    │   │  (key mgmt,  │                               │
│  │    console)  │   │   bootstrap) │                               │
│  └─────────────┘   └──────────────┘                               │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

**Key architectural decisions:**

| Aspect | Decision |
|---|---|
| **Runtime** | PowerShell 7+ (`Core` edition); auto-relaunches under `pwsh` if started in Windows PowerShell |
| **UI framework** | System.Windows.Forms (WinForms) loaded via `Add-Type` |
| **State management** | Single `PSCustomObject` (`$state`) created by `New-SessionState`, passed to all functions |
| **Docker access** | Docker contexts (preferred) or direct `DOCKER_HOST` + `DOCKER_SSH_OPTS` environment variables (fallback) |
| **Remote execution** | OpenSSH `ssh` CLI for command execution; `Posh-SSH` module or `plink.exe` for password bootstrap |
| **Remote metadata** | JSON files at `/tmp/impactncd/<container>.json` on the remote host for session recovery |
| **Theming** | Centralized dark palette in `$script:ThemePalette` with `Style-*` helper functions |
| **Logging** | File-based with rotation at 512 KB; four levels; Debug gated by user toggle |
| **Strict mode** | `Set-StrictMode -Version Latest` enabled globally |

---

## Data Model — `New-SessionState`

The session state is a `PSCustomObject` returned by `New-SessionState` (lines 55–93). Every function receives it as its `$State` parameter.

```
SessionState
├── UserName                : [string]  — normalized (lowercase, no spaces)
├── Password                : [string]  — plaintext for RStudio PASSWORD env
├── RemoteHost              : [string]  — "php-workstation@<ip>" or $null
├── RemoteHostIp            : [string]  — raw IP address
├── RemoteUser              : [string]  — default "php-workstation"
├── RemoteRepoBase          : [string]  — "/home/php-workstation/Schreibtisch/Repositories"
├── ContainerLocation       : [string]  — "LOCAL" or "REMOTE@<ip>"
├── SelectedRepo            : [string]  — e.g. "IMPACTncdGER"
├── ContainerName           : [string]  — "<repo>_<username>"
│
├── Paths                   : [hashtable]
│   ├── LocalRepo           : [string]  — local absolute path to repo root
│   ├── RemoteRepo          : [string]  — remote absolute path
│   ├── OutputDir           : [string]  — resolved from sim_design.yaml
│   ├── SynthpopDir         : [string]  — resolved from sim_design.yaml
│   ├── SshPrivate          : [string]  — "~/.ssh/id_ed25519_<user>"
│   └── SshPublic           : [string]  — "~/.ssh/id_ed25519_<user>.pub"
│
├── Flags                   : [hashtable]
│   ├── Debug               : [bool]    — enables Debug-level log output
│   ├── UseDirectSsh        : [bool]    — true when Docker context creation fails
│   ├── UseVolumes          : [bool]    — from UI checkbox
│   ├── Rebuild             : [bool]    — force image rebuild
│   ├── HighComputeDemand   : [bool]    — adds --cpus 32 -m 384g
│   └── PS7Requested        : [bool]    — prevents infinite relaunch loop
│
├── Ports                   : [hashtable]
│   ├── Requested           : [string]  — user-specified port
│   ├── Assigned            : [string]  — actual port used
│   └── Used                : [string[]]— ports occupied by other containers
│
└── Metadata                : [hashtable]
    ├── BuildInfo           : [PSCustomObject] — {Version, Commit, Built}
    ├── PublicKey            : [string]  — SSH public key content
    ├── LocalDockerContext   : [string]  — "local"
    ├── RemoteDockerContext  : [string]  — "remote-<ip>"
    ├── ExistingContainers  : [array]   — [{Name, Status, Ports, Image}]
    ├── ContainerRunning    : [bool]    — target container is running
    ├── Recovered           : [hashtable] — {Password, Port, UseVolumes}
    ├── ActivePort          : [string]  — port of the running container
    ├── ActiveUseVolumes    : [bool]    — whether volumes were used
    ├── ActiveRepoPath      : [string]  — repo path for git detection on stop
    ├── ActiveIsRemote      : [bool]    — remote flag for git detection
    ├── GitBaseline         : [hashtable] — {Repo, Commit, Status, Timestamp}
    ├── VolumeOutput        : [string]  — volume name for outputs
    └── VolumeSynthpop      : [string]  — volume name for synthpop
```

---

## Function Reference

### Infrastructure & Logging

| Function | Lines | Signature | Purpose |
|---|---|---|---|
| `Initialize-Logging` | 17–49 | `()` | Creates `~/.impact_gui/logs/`, rotates `impact.log` if >512 KB, writes session header. Respects `$env:IMPACT_LOG_FILE` and `$env:IMPACT_LOG_DISABLE`. |
| `Get-BuildInfo` | 51–53 | `()` → `PSCustomObject{Version,Commit,Built}` | Returns version `2.0.0`, git short SHA via `git rev-parse --short HEAD`, dirty flag; ISO 8601 timestamp or `unknown`. |
| `New-SessionState` | 55–93 | `()` → `PSCustomObject` | Creates the session state object with all fields initialized to `$null`, empty strings, or default values. |
| `Write-Log` | 95–127 | `([string]$Message, [string]$Level)` | Writes to console (color-coded) and appends to log file. Debug messages suppressed unless `$script:GlobalDebugFlag` is `$true`. Levels: `Info` (Cyan), `Warn` (Yellow), `Error` (Red), `Debug` (DarkGray). |
| `Ensure-PowerShell7` | 129–196 | `([bool]$PS7RequestedFlag)` | Checks `$PSVersionTable.PSEdition`/Major; if not PS7, locates `pwsh`, determines the invoked path (handles EXE, script, and fallback scenarios), and relaunches via `Start-Process -NoNewWindow -Wait`. Adds `-PS7Requested` flag to prevent loops. Shows MessageBox and throws if pwsh not found. |

### SSH & Remote Helpers

| Function | Lines | Signature | Purpose |
|---|---|---|---|
| `Get-RemoteHostString` | 198–203 | `([PSCustomObject]$State)` → `[string]` | Returns `$State.RemoteHost` or falls back to `$State.RemoteHostIp`. |
| `Test-RemoteSSHKeyFiles` | 270–293 | `([PSCustomObject]$State)` → `[bool]` | SSH probes for existence of the user's private key and `known_hosts` on the remote host. Returns `$true` only if both exist. |
| `Write-RemoteContainerMetadata` | 295–321 | `($State, $Password, $Port, [bool]$UseVolumes)` | Writes a JSON blob (container, repo, user, password, port, useVolumes, timestamp) to `/tmp/impactncd/<container>.json` via base64-encoded SSH pipe. `umask 177` for restrictive permissions. |
| `Read-RemoteContainerMetadata` | 334–350 | `($State)` → `PSCustomObject` or `$null` | Reads and deserializes the remote JSON metadata file. Returns `$null` on any failure. |
| `Remove-RemoteContainerMetadata` | 323–332 | `($State)` | Deletes the remote metadata JSON via SSH `rm -f`. |

### Docker Helpers

| Function | Lines | Signature | Purpose |
|---|---|---|---|
| `Set-DockerSSHEnvironment` | 205–237 | `([PSCustomObject]$State)` | Sets `$env:DOCKER_SSH_OPTS` (SSH key + options) and optionally `$env:DOCKER_HOST` for direct SSH mode. Clears both in local mode. |
| `Get-DockerContextArgs` | 239–254 | `([PSCustomObject]$State)` → `[string[]]` | Returns `@('--context', <name>)` or empty array based on connection mode. Handles local context, remote context, and direct SSH (no args). |
| `Get-ContainerRuntimeInfo` | 350–381 | `([PSCustomObject]$State)` → `@{Password; Port}` | Uses `docker inspect` with Go template to extract `PASSWORD` env var and mapped port `8787/tcp`. Returns hashtable with nullable values. |
| `Test-StartupPrerequisites` | 757–782 | `([PSCustomObject]$State)` → `[bool]` | Checks `docker` on PATH, Docker daemon reachable (via `docker version`), and `ssh` on PATH. Shows MessageBox on failure. |

### Path & YAML Helpers

| Function | Lines | Signature | Purpose |
|---|---|---|---|
| `Convert-PathToDockerFormat` | 256–268 | `([string]$Path)` → `[string]` | Converts Windows paths (`C:\foo\bar`) to Docker/WSL format (`/c/foo/bar`). Passes through POSIX paths unchanged. |
| `Get-YamlPathValue` | 383–422 | `($State, $YamlPath, $Key, $BaseDir)` → `[string]` or `$null` | Reads a YAML file (locally or via SSH), extracts a single `key: value` line, resolves relative paths against `$BaseDir`. |
| `Test-AndCreateDirectory` | 424–472 | `($State, $Path, $PathKey)` → `[bool]` | Validates directory existence locally or remotely. In local mode, rejects POSIX-style absolute paths. Does NOT auto-create directories — returns `$false` if missing. |

### Git Integration

| Function | Lines | Signature | Purpose |
|---|---|---|---|
| `Get-GitRepositoryState` | 474–518 | `($State, $RepoPath, [bool]$IsRemote)` → `PSCustomObject{HasChanges, StatusText, Branch, Remote}` | Runs `git status --porcelain=v1`, `git rev-parse --abbrev-ref HEAD`, and `git remote get-url origin` locally or via SSH. |
| `Show-GitCommitDialog` | 520–577 | `([string]$ChangesText)` → `@{Message; Push}` or `$null` | WinForms dialog showing changes text, commit message input, and push checkbox. Returns `$null` on cancel/skip. |
| `Invoke-GitChangeDetection` | 579–645 | `($State, $RepoPath, [bool]$IsRemote)` | Orchestrates: get git state → show dialog → commit → optional push. Converts GitHub HTTPS remotes to SSH (`git@github.com:...`). Remote push uses `ssh-agent` with the user's key; falls back to `GIT_SSH_COMMAND`. |

### UI Theming & Layout

| Function | Lines | Signature | Purpose |
|---|---|---|---|
| `Set-FormCenterOnCurrentScreen` | 647–689 | `([Form]$Form)` | Uses P/Invoke (`user32.dll`: `GetCursorPos`, `MonitorFromPoint`, `GetMonitorInfo`) to center the form on the monitor under the cursor. Falls back to `CenterScreen` on error. Adds `Win32`, `POINT`, `RECT`, `MONITORINFO` types via `Add-Type` (guarded by `-as [type]` check). |
| `Initialize-ThemePalette` | 691–704 | `()` | Creates `$script:ThemePalette` hashtable with 9 colors: Back (dark navy), Panel (dark blue-grey), Accent (teal), AccentAlt (gold), Text (light grey), Muted (mid grey), Danger (red), Success (green), Field (dark blue). |
| `Apply-ThemeToForm` | 706–712 | `([Form]$Form)` | Applies Back/Text colors and Segoe UI 10pt font to a Form. |
| `Style-Label` | 714–723 | `($Label, [bool]$Muted, [FontStyle]$Style)` | Sets label color (Text or Muted) and font style. |
| `Style-TextBox` | 700–709 | `($TextBox)` | Applies Field background, Text foreground, border style. |
| `Style-CheckBox` | 711–717 | `($CheckBox)` | Sets foreground to Text color. |
| `Style-Button` | 719–731 | `($Button, [ValidateSet]$Variant)` | Flat button styling. Variants: `primary` (Accent), `secondary` (Panel), `danger` (Danger), `ghost` (Field). Bold Segoe UI Semibold font. |
| `Style-InfoBox` | 733–740 | `([RichTextBox]$Box)` | Styles a read-only RichTextBox with theme colors. |

### UI Dialogs (Workflow Steps)

| Function | Lines | Signature | Purpose |
|---|---|---|---|
| `Ensure-Prerequisites` | 784–820 | `($State)` | Loads WinForms assemblies, calls `Test-StartupPrerequisites`, checks admin status, sets console colors/title. |
| `Show-CredentialDialog` | 822–918 | `($State)` → `[bool]` | Username/password dialog. Normalizes username. Stores in `$State`. |
| `Ensure-GitKeySetup` | 920–1050 | `($State)` → `[bool]` | SSH key generation or reuse. Displays key in themed dialog with Copy button (timer-based feedback). Configures `ssh-agent`. |
| `Select-Location` | 1126–1218 | `($State)` → `[bool]` | Local vs Remote button dialog. Sets ContainerLocation, RemoteHost, Debug flag. IP validation in remote mode. |
| `Ensure-RemotePreparation` | 1220–1600 | `($State)` → `[bool]` | Full remote setup: key auth probe → password bootstrap (Posh-SSH / plink) → key/known_hosts sync → repo list → Docker context. |
| `Ensure-LocalPreparation` | 1610–1830 | `($State)` → `[bool]` | Folder picker → Docker Desktop startup/wait → context creation. |
| `Get-ContainerStatus` | 1832–1920 | `($State)` → `$State` | Port scan, container list, running detection, session recovery from remote metadata or `docker inspect`. |
| `Show-ContainerManager` | 1922–2420 | `($State)` | Main UI with Start/Stop event handlers. Builds image, assembles `docker run`, manages volumes, writes metadata. On stop: sync volumes, remove metadata, trigger git detection. |

### Coordinator

| Function | Lines | Signature | Purpose |
|---|---|---|---|
| `Invoke-ImpactGui` | 2422–2443 | `()` | Entry point. Calls `Ensure-PowerShell7` → `New-SessionState` → `Get-BuildInfo` → `Ensure-Prerequisites` → `Show-CredentialDialog` → `Ensure-GitKeySetup` → `Select-Location` → branch to Remote/Local preparation → `Get-ContainerStatus` → `Show-ContainerManager`. Early returns on any step failure. |

---

## UI Dialogs Reference

The application presents 7+ dialogs in sequence. All share the dark theme.

| # | Dialog | Form Size | Key Controls | Validation |
|---|---|---|---|---|
| 1 | **Credential Dialog** | 540×320 | RichTextBox (instructions), TextBox (username), TextBox (password, masked), OK/Cancel buttons | Non-empty username after normalization; non-empty password |
| 2 | **SSH Key Display** | 820×520 | TextBox (public key, Consolas monospace, select-all on shown), Copy to Clipboard button (2s timer feedback), Close button | Key file must exist after generation |
| 3 | **Location Selection** | 480×260 | Local button, Remote button, TextBox (IP, default `... ask you admin ;)`), Debug checkbox | IP format validated via regex `^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$` |
| 4 | **Remote Password** | 380×190 | Label (target user@ip), TextBox (password, masked), OK/Cancel | Non-empty password |
| 5 | **Repository Selection** | 430×340 | ListBox (repo names from remote scan), Select/Cancel buttons | Must select an item |
| 6 | **Container Manager** | 540×500 | RichTextBox (status info), Start/Stop buttons, 3 checkboxes, 2 text inputs, YAML path, status label, build info footer, Close button | Port conflict check, SSH key presence (remote), path existence |
| 7 | **Git Commit Dialog** | 640×540 | TextBox (changes, read-only, Consolas), TextBox (commit message), Push checkbox, Commit/Skip buttons | Non-empty commit message |

---

## End-to-End Workflow

### Phase 0 — PowerShell 7 Relaunch

`Ensure-PowerShell7` detects the PowerShell edition and version:

1. If already PS7+ Core → return immediately
2. Locate `pwsh` via `Get-Command`
3. Determine the invoked path using multiple fallback strategies:
   - `[System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName`
   - `$MyInvocation.MyCommand.Path`
   - `[Environment]::GetCommandLineArgs()[0]`
   - `$MyInvocation.MyCommand.Definition`
4. If the invoked path is an `.exe`, look for a co-located `.ps1` file
5. Build `pwsh` arguments: `-NoLogo -NoProfile -ExecutionPolicy Bypass -File "<script>"` (or `-Command "& '<exe>'"`)
6. Append `-PS7Requested` to prevent infinite loops
7. `Start-Process -NoNewWindow -Wait` → `exit` the parent process

### Phase 1 — Prerequisites & Credentials

1. `Ensure-Prerequisites`: Load WinForms, call `Test-StartupPrerequisites` (docker CLI, daemon, ssh)
2. `Show-CredentialDialog`: Capture and normalize username/password

### Phase 2 — SSH Key Setup

`Ensure-GitKeySetup`:
1. Check for existing key pair at `~/.ssh/id_ed25519_<user>`
2. If missing: `ssh-keygen -t ed25519 -C IMPACT_<user> -f <path> -N '' -q`
3. Display key in themed dialog with Copy button
4. Start `ssh-agent` service and `ssh-add` the key (best-effort)

### Phase 3 — Location Selection

`Select-Location`: User picks Local or Remote. Sets `ContainerLocation`, `RemoteHost`, `Debug` flag.

### Phase 4 — Environment Preparation

#### Local Path (`Ensure-LocalPreparation`)

1. `FolderBrowserDialog` → select repo root
2. Warn if no `.git` directory
3. Check Docker availability via `docker --version` and `docker version`
4. If Docker not running: attempt to start Docker Desktop from:
   - `$env:ProgramFiles\Docker\Docker\Docker Desktop.exe`
   - `$env:LOCALAPPDATA\Programs\Docker\Docker\Docker Desktop.exe`
   - `Start-Service com.docker.service`
5. Poll up to 30 times (1s interval) via background jobs
6. Create Docker context `local` with host `npipe:////./pipe/docker_engine` (Windows) or `unix:///var/run/docker.sock` (Linux)
7. `docker context use local` and verify connection

#### Remote Path (`Ensure-RemotePreparation`)

1. Validate local key files exist
2. Probe key auth: `ssh ... "echo KEY_AUTH_OK"`
3. Try direct key-based bootstrap (upload public key via SSH)
4. If key auth fails → password bootstrap (see Phase 5)
5. Sync private key to remote via base64 SSH pipe
6. Sync or create `known_hosts` on remote
7. Scan repos: `ls -1d <base>/*/ | xargs -n1 basename`
8. Show repo selection dialog
9. Create Docker context `remote-<ip>` with `host=ssh://<remoteHost>`
10. If context fails: set `Flags.UseDirectSsh = $true`, use `DOCKER_HOST` env var

### Phase 5 — Password Bootstrap (Remote)

Five-phase bootstrap when key auth fails for the first time:

```
┌──────────────────────────────────────────────────────────┐
│ 1. Prompt user for remote password (WinForms dialog)     │
│ 2. Check for Posh-SSH module                             │
│    └── If missing: prompt to install (CurrentUser scope)  │
│ 3. Posh-SSH path (primary):                              │
│    ├── Import-Module Posh-SSH                             │
│    ├── Create temp key file locally                       │
│    ├── New-SSHSession with credential                     │
│    ├── Invoke-SSHCommand: create remote temp file         │
│    ├── Invoke-SSHCommand: run install script              │
│    │   (single-quoted here-string with __TOKEN__ replace) │
│    └── Remove-SSHSession + cleanup temp file              │
│ 4. plink.exe fallback (if Posh-SSH fails):               │
│    ├── Locate plink.exe (PATH or ProgramFiles\PuTTY)     │
│    ├── Write remote script to temp file                   │
│    └── Start-Process plink -batch -ssh -pw <pw>           │
│ 5. Verify: probe SSH again with key auth                  │
└──────────────────────────────────────────────────────────┘
```

**Remote install script** (single-quoted here-string to prevent PowerShell variable expansion):
- Uses `__USERNAME__` and `__REMOTE_TEMP__` tokens replaced via `.Replace()` (avoids `-f` format conflicts with bash `${ACTUAL_USER}` braces)
- Creates `~/.ssh/`, `authorized_keys`, copies public key
- Sets ownership and permissions (700 on `.ssh`, 600 on `authorized_keys`, 644 on `.pub`)
- Outputs `SSH_KEY_COPIED` as success marker

### Phase 6 — Container Status Detection

`Get-ContainerStatus`:
1. `docker ps --format` to discover all running containers and their port mappings → `Ports.Used`
2. `docker ps -a --filter name=_<user>` to list user's containers → `Metadata.ExistingContainers`
3. Check if target container is running: `docker ps --filter name=^<name>$`
4. If running: read remote metadata JSON → fallback to `docker inspect` for password/port recovery

### Phase 7 — Container Start

Within `Show-ContainerManager` Start button click handler:

1. **Validation**: port conflict, SSH key presence (remote), other running containers warning
2. **Path resolution**: repo root, `docker_setup/` folder, `sim_design.yaml` (relative → absolute)
3. **Image build** (if image missing or rebuild requested):
   - Primary: `docker build --build-arg REPO_NAME=<repo> -f <Dockerfile.IMPACTncdGER> -t <image> --no-cache --progress=plain .`
   - Fallback: build `Dockerfile.prerequisite.IMPACTncdGER` first, then retry main build
   - Remote: wraps build command in SSH (`Start-Process ssh ...`)
4. **Git baseline capture** (best-effort): `git rev-parse HEAD` and `git status --porcelain`
5. **YAML resolution**: `Get-YamlPathValue` for `output_dir` and `synthpop_dir`; `Test-AndCreateDirectory` validates
6. **Volume setup** (if Use Docker Volumes):
   - Create named volumes: `impactncd_germany_output_<user>`, `impactncd_germany_synthpop_<user>`
   - Build `rsync-alpine` helper image if not present
   - Fix ownership: `docker run --rm alpine sh -c "chown 1000:1000 /volume"`
   - Pre-populate: copy host dir contents into volumes via `alpine cp`
7. **`docker run` assembly**:
   ```
   docker run -d --rm --name <container>
     -e PASSWORD=<pass>
     -e DISABLE_AUTH=false
     -e USERID=1000 -e GROUPID=1000
     -e GIT_SSH_COMMAND="ssh -i /keys/id_ed25519_<user> ..."
     --mount type=bind,source=<repo>,target=/host-repo
     --mount type=bind,source=<repo>,target=/home/rstudio/<repo>
     -p <port>:8787
     [volume or bind mounts for outputs/synthpop]
     [--cpus 32 -m 384g if high compute]
     --mount type=bind,source=<key>,target=/keys/...,readonly
     --mount type=bind,source=<known_hosts>,target=/etc/ssh/ssh_known_hosts,readonly
     --workdir /home/rstudio/<repo>
     <image>
   ```
8. **Metadata**: write remote metadata JSON, update UI state

### Phase 8 — Container Stop & Data Sync

Stop button click handler:

1. `docker stop <container>`
2. If volumes were used:
   - `docker run --rm rsync-alpine rsync -avc /volume/ /backup/` for output and synthpop
   - `docker volume rm <vol_out> <vol_syn> -f`
3. Clear `ContainerRunning`, remove remote metadata
4. Trigger `Invoke-GitChangeDetection`

### Phase 9 — Git Change Detection

1. `Get-GitRepositoryState`: check for uncommitted changes
2. If changes: `Show-GitCommitDialog` with diff text
3. On commit: `git add -A && git commit -m "<msg>"`
4. Convert HTTPS GitHub remote to SSH: `https://github.com/<path>` → `git@github.com:<path>`
5. Push (remote): `ssh-agent` + `ssh-add` + `GIT_SSH_COMMAND` → direct `GIT_SSH_COMMAND` fallback
6. Push (local): `git push`

---

## Logging Subsystem

### Configuration

| Setting | Source | Default |
|---|---|---|
| Log file path | `$env:IMPACT_LOG_FILE` | `~/.impact_gui/logs/impact.log` |
| Disable logging | `$env:IMPACT_LOG_DISABLE` | Not set (logging enabled) |
| Debug output | `$script:GlobalDebugFlag` | `$false` (set by Debug checkbox in location dialog) |
| Rotation threshold | Hardcoded | 512 KB |

### Log Format

```
[2025-01-15 14:30:25] [Info] Checking PowerShell version and elevation
[2025-01-15 14:30:25] [Debug] Detected PowerShell 7.4.1 (Major=7)
```

### Write-Log Behavior

- Always writes to console with color: Info=Cyan, Warn=Yellow, Error=Red, Debug=DarkGray
- Debug messages are suppressed from console AND file when `$script:GlobalDebugFlag -eq $false`
- File writes use `Out-File -Append -Encoding utf8` with `-ErrorAction SilentlyContinue`
- Rotation: on `Initialize-Logging`, if file >512 KB, renamed to `impact_<yyyyMMdd_HHmmss>.log`

---

## Security Considerations

| Area | Implementation | Notes |
|---|---|---|
| **SSH key storage** | `~/.ssh/id_ed25519_<user>` with standard permissions | Windows ACLs apply; no explicit `icacls` hardening |
| **Password handling** | Plaintext in memory (`$State.Password`); passed as `PASSWORD` env var to container; stored in remote metadata JSON | Metadata at `/tmp/impactncd/` with `umask 177` |
| **Remote password bootstrap** | Plaintext password passed to `New-SSHSession` credential or `plink -pw`; used once then discarded | Not stored in state or logs |
| **Remote metadata** | JSON at `/tmp/impactncd/<container>.json` with `umask 177` | Contains plaintext password; removed on stop |
| **SSH key on remote** | Private key base64-encoded via SSH pipe to `~/.ssh/id_ed25519_<user>` | `chmod 600`; owned by remote user |
| **Docker socket** | Local: `npipe:////./pipe/docker_engine`; Remote: SSH tunnel | No TLS for local socket |
| **Container privileges** | `--rm`, `USERID=1000`, `GROUPID=1000` | Not `--privileged`; no capabilities added |
| **Git push** | SSH key mounted read-only; `IdentitiesOnly=yes`, `StrictHostKeyChecking=yes` | HTTPS→SSH remote conversion is automatic |
| **Log file** | May contain sensitive info at Debug level | Recommend disabling Debug in production |

---

## Error Handling Patterns

The script uses several consistent error handling strategies:

1. **Early return with `$false`**: Most setup functions return `[bool]`; `Invoke-ImpactGui` chains them with `if (-not ...) { return }`
2. **MessageBox on user-facing errors**: `[System.Windows.Forms.MessageBox]::Show(...)` for Docker, SSH, path, and build failures
3. **Try/catch with logging**: Remote SSH commands, Docker operations, and git operations are wrapped in `try/catch` with `Write-Log` at `Error` or `Debug` level
4. **Best-effort operations**: Clipboard copy, ssh-agent start, git baseline capture — failures are logged but don't abort the workflow
5. **Fallback chains**: Docker context → DOCKER_HOST; Posh-SSH → plink.exe; main Dockerfile → prerequisite Dockerfile → retry main
6. **StrictMode guards**: `Metadata.Recovered` and other dynamic keys are pre-seeded before access to prevent strict mode errors on missing members

---

## Dependency Matrix

| Dependency | Required? | Used By | Install Method |
|---|---|---|---|
| **PowerShell 7** | Yes | Entire script | `winget install Microsoft.PowerShell` |
| **Docker Desktop** | Yes (local) | Build, run, stop, volume ops | [docker.com](https://www.docker.com/products/docker-desktop/) |
| **Docker CLI** | Yes | All Docker operations | Included with Docker Desktop |
| **OpenSSH (ssh)** | Yes | Remote operations, key generation | Windows Optional Feature |
| **ssh-keygen** | Yes | Key generation | Included with OpenSSH |
| **ssh-agent** | Optional | Key management | Windows service |
| **Posh-SSH** | Recommended | Password bootstrap (primary) | `Install-Module -Name Posh-SSH -Scope CurrentUser` |
| **plink.exe** | Optional | Password bootstrap (fallback) | PuTTY installer |
| **Git** | Optional | Commit/push on stop, build info | [git-scm.com](https://git-scm.com/) |
| **ps2exe** | Compile only | EXE compilation | `Install-Module -Name ps2exe -Scope CurrentUser` |
| **rsync-alpine** | Auto-built | Volume data sync | Built from `alpine` + `apk add rsync` |

---

## Compile Pipeline

The script is compiled to `IMPACT.exe` using the `ps2exe` PowerShell module.

### Files

| File | Purpose |
|---|---|
| `Compile-IMPACT-v2.ps1` | Main compilation script; enforces PS7, installs `ps2exe` if missing, handles icon |
| `Compile-IMPACT-v2.bat` | Interactive batch wrapper; tries pwsh first, falls back to `powershell.exe` |
| `Quick-Compile-v2.bat` | Silent batch wrapper; forces overwrite, suppresses output |
| `IMPACT_icon.ico` | Application icon embedded in the EXE |

### Compilation Parameters

```powershell
Invoke-PS2EXE @{
    InputFile    = "IMPACT_Docker_GUI_v2.ps1"
    OutputFile   = "IMPACT.exe"
    NoConsole    = $false    # Console needed for PS7 relaunch
    NoOutput     = $false
    NoError      = $false
    NoConfigFile = $true
    iconFile     = "IMPACT_icon.ico"  # if present
}
```

### Icon Fallback

If the icon causes a compilation error, the script retries without the icon file.

### Important Notes

- The compiler enforces PowerShell 7 (`PSEdition -eq 'Core'` and `Major -ge 7`) to produce a PS7-native EXE
- When run from a batch file, `-Force` mode is auto-enabled
- The resulting EXE includes a console window (required for `Ensure-PowerShell7` relaunch flow)

---

## Extension Points

| Area | How to Extend |
|---|---|
| **Logging** | Override `$env:IMPACT_LOG_FILE` to redirect; set `$env:IMPACT_LOG_DISABLE=1` to silence; extend `Write-Log` for custom sinks |
| **Theming** | Modify `Initialize-ThemePalette` to change the 9-color palette; all UI uses `Style-*` helpers |
| **Docker build** | Change Dockerfile paths in `Show-ContainerManager` Start handler; add build args to `--build-arg` |
| **Remote repo base** | Modify `$State.RemoteRepoBase` before calling `Ensure-RemotePreparation` |
| **Container configuration** | Add `docker run` flags via the Custom Params field or modify the `$dockerArgs` array |
| **Port range** | Currently user-chosen; could be automated by scanning `$State.Ports.Used` |
| **Additional YAML keys** | Extend `Get-YamlPathValue` calls in the Start handler to read more keys from `sim_design.yaml` |
| **Remote user** | Change `$State.RemoteUser` (default: `php-workstation`) in `New-SessionState` |
| **Volume sync tool** | Replace `rsync-alpine` with a different sync container image |
| **Git integration** | Extend `Invoke-GitChangeDetection` with branch selection, stash support, or PR creation |

---

## Known Limitations

| Limitation | Details |
|---|---|
| **Single container per repo-user pair** | Container name `<repo>_<user>` means one container per repo per user at a time |
| **No concurrent sessions** | The UI is modal; you cannot manage multiple containers simultaneously from a single instance |
| **Local port fixed to 8787** | Local mode disables port override; only one local container can run at a time |
| **No auto-port selection** | Remote port must be manually chosen; no automatic free-port detection |
| **YAML parser is simplistic** | `Get-YamlPathValue` only handles single-line `key: value` patterns; no nested YAML, arrays, or multiline values |
| **No TLS for RStudio** | RStudio Server is accessed over plain HTTP |
| **Password in remote metadata** | `/tmp/impactncd/<container>.json` contains plaintext password (cleaned on stop, but persists if stop is interrupted) |
| **No container log viewing** | No built-in way to view Docker container logs from the GUI |
| **Git push requires SSH key in GitHub** | HTTPS push is not supported; remotes are converted to SSH |
| **P/Invoke for multi-monitor** | The Win32 `Add-Type` block may conflict if loaded multiple times in the same session (guarded by `-as [type]` check) |
| **Remote Docker requires SSH access** | No support for Docker over TLS or other remote protocols |
| **Volume cleanup on crash** | If the tool crashes during volume sync, orphaned volumes remain until manually removed |

---

*Last updated: 2025 — IMPACT NCD Germany Docker GUI v2.0.0*
