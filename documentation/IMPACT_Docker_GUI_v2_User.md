# 📘 IMPACT Docker GUI v2 — User Guide

> A friendly, step-by-step guide to launching and managing your **IMPACT NCD Germany** RStudio containers — locally for testing or remotely on the workstation for heavy simulation runs.

---

## 📋 Table of Contents

1. [What This Tool Does](#-what-this-tool-does)
2. [System Requirements](#-system-requirements)
3. [First-Time Machine Setup](#-first-time-machine-setup)
4. [Quick Start (Happy Path)](#-quick-start-happy-path)
5. [Step-by-Step Workflow](#-step-by-step-workflow)
   - [Step 1 — Launch the Tool](#step-1--launch-the-tool-)
   - [Step 2 — Enter Your Credentials](#step-2--enter-your-credentials-)
   - [Step 3 — SSH Key Setup](#step-3--ssh-key-setup-)
   - [Step 4 — Choose Where to Run](#step-4--choose-where-to-run-)
   - [Step 5 — Repository Setup](#step-5--repository-setup)
   - [Step 6 — Container Manager](#step-6--container-manager-)
   - [Step 7 — Connect to RStudio](#step-7--connect-to-rstudio-)
   - [Step 8 — Stopping & Data Sync](#step-8--stopping--data-sync-)
6. [Options Reference](#-options-reference)
7. [Connecting to RStudio](#-connecting-to-rstudio)
8. [Frequently Asked Questions & Troubleshooting](#-frequently-asked-questions--troubleshooting)
9. [Logs & Diagnostics](#-logs--diagnostics)
10. [Multiple Users on the Same Workstation](#-multiple-users-on-the-same-workstation)
11. [Building the EXE](#-building-the-exe)
12. [Glossary](#-glossary)
13. [Remote Workstation Setup](#-remote-workstation-setup)

---

## 🎯 What This Tool Does

The **IMPACT Docker GUI** is a Windows application that lets you:

- 🏗️ **Build** a Docker image containing the IMPACT NCD Germany simulation environment (RStudio Server + R packages)
- 🚀 **Start** an RStudio Server container — either on your local machine or on a remote workstation
- 🔑 **Manage SSH keys** for secure GitHub access and remote connectivity
- 📂 **Mount your project files** so you can edit code in your browser through RStudio
- 🔄 **Sync data** between Docker volumes and your host folders when using volume mode
- 📝 **Commit & push** your changes to GitHub when you stop the container

All of this is done through a series of simple, dark-themed dialog windows — no command-line expertise needed.

---

## 💻 System Requirements

| Requirement | Details |
|---|---|
| **Operating System** | Windows 10 or later |
| **PowerShell** | PowerShell 7+ (pwsh) — the tool auto-relaunches under pwsh if started in Windows PowerShell |
| **Docker** | Docker Desktop installed and running (for local/Windows mode); Docker Engine installed on the remote Linux workstation (for remote mode) |
| **OpenSSH Client** | `ssh`, `ssh-keygen`, and `ssh-agent` on PATH — the tool offers to install this automatically if missing (one-time UAC prompt) |
| **Network** | Access to the remote workstation IP (for remote mode) |
| **Posh-SSH Module** | *(Recommended)* For first-time remote password bootstrap; the tool will offer to install it (no admin required) |
| **PuTTY / plink.exe** | *(Fallback)* Used if Posh-SSH is unavailable for initial remote key setup |
| **Git** | *(Optional)* Required for commit/push on stop |

> 💡 **Tip:** The tool checks for Docker, SSH, and PowerShell 7 on startup and shows clear error messages if anything is missing. On a fresh machine, several prerequisites are installed automatically — see [First-Time Machine Setup](#-first-time-machine-setup).

> 🐧 **Remote workstation prerequisites:** The Linux workstation must have **Docker Engine** (not Docker Desktop) installed, and the remote user (default: `php-workstation`) must be a member of the `docker` group. See [Remote Workstation Setup](#-remote-workstation-setup) below.

---

## 🔧 First-Time Machine Setup

When running the tool on a **new Windows machine** for the first time, a few one-time setup steps happen automatically. You may see one or two **UAC (User Account Control) prompts** asking for Administrator permission — these are expected and only happen once.

### What the tool does automatically

| Component | What happens | Admin required? |
|---|---|---|
| **OpenSSH Client** | If `ssh` is not found on PATH, the tool detects this and offers to install the Windows OpenSSH Client capability. A UAC prompt appears for the installation. | Yes (one-time UAC prompt) |
| **ssh-agent service** | The tool starts the Windows `ssh-agent` service and sets it to start automatically on boot. If the service is disabled, a UAC prompt appears to change the startup type. | Yes (one-time UAC prompt) |
| **SSH key in agent** | Your generated/existing SSH key (`~/.ssh/id_ed25519_<username>`) is automatically loaded into `ssh-agent` on every run, so you don't get repeated passphrase or credential prompts. | No |
| **SSH config file** | When you connect to a remote workstation, the tool creates/updates `~/.ssh/config` with the correct connection settings for that host (identity file, user, timeouts). This avoids repeated password checks. | No |
| **Posh-SSH module** | When you first use remote mode and key-based auth isn't set up yet, the tool offers to install the Posh-SSH PowerShell module for password-based key bootstrap. This installs to your user profile only. | No |

### Manual fallback commands

If you prefer to set things up manually (or if the automatic install fails), run these commands in an **Administrator PowerShell**:

```powershell
# 1. Install OpenSSH Client (if missing)
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0

# 2. Enable and start ssh-agent
Set-Service ssh-agent -StartupType Automatic
Start-Service ssh-agent

# 3. Add your key to the agent (run as your normal user, not admin)
ssh-add $HOME\.ssh\id_ed25519_<username>
```

To install the Posh-SSH module (no admin needed):

```powershell
Install-Module -Name Posh-SSH -Scope CurrentUser -Force
```

### SSH config file details

The tool creates a `~/.ssh/config` file (typically `C:\Users\<you>\.ssh\config`) with an entry like:

```
Host <workstation-ip>
    User <remote-user>
    IdentityFile ~/.ssh/id_ed25519_<username>
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ConnectTimeout 10
```

This ensures that all SSH connections to the workstation use the correct key automatically, without repeated authentication prompts. The file is only created if no entry for that host exists yet — existing entries are never overwritten.

> 💡 After the first-time setup, subsequent launches will not require any admin prompts.

---

## ⚡ Quick Start (Happy Path)

For experienced users — the fastest way from zero to RStudio:

1. ▶️ Double-click `IMPACT.bat` (or run `IMPACT_Docker_GUI_v2.ps1` directly)
2. 👤 Enter your **GitHub username** and a **password**
3. 🔑 Let it create your SSH key; copy the public key to **GitHub → Settings → SSH and GPG keys** if needed
4. 🌐 Choose **Local** or **Remote** (enter the workstation IP if remote)
5. 📁 Pick your repository (Local: folder picker; Remote: list from the workstation)
6. ▶️ In the Container Manager, review options and click **Start Container**
7. 🖥️ Open the URL shown in the dialog; log in as `rstudio` with the password you entered
8. ⏹️ Click **Stop Container** when you're done — data syncs back and you can commit changes

---

## 🚶 Step-by-Step Workflow

### Step 1 — Launch the Tool 🚀

You have two ways to start:

| Method | How |
|---|---|
| **Batch launcher** | Double-click `IMPACT.bat` — auto-detects PowerShell 7 with a fallback to Windows PowerShell |
| **PowerShell script** | Right-click `IMPACT_Docker_GUI_v2.ps1` → *Run with PowerShell*, or open a terminal and run `pwsh .\IMPACT_Docker_GUI_v2.ps1` |
| **Desktop shortcut** | Double-click `Create-Shortcut.bat` once to create an `IMPACT` shortcut on your Desktop with the application icon |

On launch, the tool:
- Checks if PowerShell 7 is available and re-launches under `pwsh` if needed (you may see a brief console flash)
- Starts logging to a file in your home directory (see [Logs & Diagnostics](#-logs--diagnostics))
- Verifies that Docker and SSH are available

> ⚠️ **If you see "PowerShell 7 required":** Install PowerShell 7 from [https://aka.ms/powershell](https://aka.ms/powershell)

---

### Step 2 — Enter Your Credentials 🔐

A dialog asks for:

| Field | Purpose | Rules |
|---|---|---|
| **Username** | Must be your **GitHub username**. Used for SSH key generation, git identity inside the container, and container/volume naming. | Validated against GitHub's API, normalized to lowercase |
| **Password** | Used to log in to RStudio Server inside the container | Any non-empty string |

> 💡 **Why your GitHub username?** The tool uses your GitHub username to: (1) generate SSH keys named `id_ed25519_<username>`, (2) set your git identity inside the container (`user.name` and `user.email`), and (3) name your container and volumes. Using your real GitHub username ensures that git commits are correctly attributed to your account.

> ⚠️ The username is validated against GitHub when you click Continue. If you enter a username that doesn't exist on GitHub, you'll be asked to correct it.

---

### Step 3 — SSH Key Setup 🔑

The tool looks for an SSH key pair at:
```
~/.ssh/id_ed25519_<username>
~/.ssh/id_ed25519_<username>.pub
```

- **If keys exist:** The public key is displayed so you can verify it's in GitHub.
- **If keys are missing:** A new Ed25519 key pair is generated. The public key is:
  - Shown in a dialog with a **Copy to Clipboard** button
  - Also printed to the console

**Add the public key to GitHub** if you need Git access inside the container:
1. Go to **GitHub → Settings → SSH and GPG keys → New SSH key**
2. Paste the public key and save

> 🔒 The private key never leaves your machine (it is bind-mounted into the container as read-only).

---

### Step 4 — Choose Where to Run 🌍

A dialog presents two buttons:

| Option | When to Use |
|---|---|
| 🖥️ **Local Container** | Testing on your own machine; uses Docker Desktop (Windows) |
| 🖧 **Remote Container** | Running heavy simulations on the shared workstation; uses Docker Engine (Linux) |

**Remote mode** requires:
- The workstation IP address (a default is pre-filled: `... ask you admin ;)`)
- Network connectivity to that IP

**Optional:**
- ☑️ **Enable Debug Mode** — shows detailed progress messages in the console (useful for troubleshooting)

---

### Step 5 — Repository Setup

What happens next depends on which location you chose:

#### 5a. Local Preparation 🖥️

1. A folder picker dialog opens — select the root of your project repository (the folder containing `docker_setup/` and `inputs/sim_design.yaml`)
2. The tool warns if no `.git` directory is found but lets you continue
3. Docker Desktop is checked; if not running, the tool tries to start it and waits up to 30 seconds
4. A Docker context named `local` is created pointing to the Docker Desktop socket

#### 5b. Remote Preparation 🖧

1. **SSH key authorization** — the tool tries to connect with your key. If it fails (first time), a password prompt appears:
   - Enter the remote user's password once
   - The tool uses **Posh-SSH** (preferred) or **plink.exe** (fallback) to install your public key in the remote `~/.ssh/authorized_keys`
   - Subsequent connections use key-based auth (no password needed)
2. **Key sync** — your private key and `known_hosts` are securely copied to the remote host for Git access inside containers
3. **Repository selection** — the tool lists folders under `/home/php-workstation/Schreibtisch/Repositories/` on the remote machine; select one
4. **Docker context** — a context named `remote-<ip>` is created. If that fails, the tool falls back to direct `DOCKER_HOST=ssh://...`

> 💡 **First-time remote setup**: you'll need the remote password once. After that, key-based auth is automatic.  
> If prompted to install **Posh-SSH**, click **Yes** — it's a one-time install that enables password-based key bootstrap without PuTTY.

---

### Step 6 — Container Manager 🎛️

This is the main control panel. It shows:

```
┌──────────────────────────────────────────────┐
│  Status: RUNNING / STOPPED                   │
│  URL: http://localhost:8787                   │
│  RStudio login: rstudio (Password: *****)    │
│  Repo: IMPACTncdGER                          │
│  Container: IMPACTncdGER_johndoe             │
│  Location: LOCAL / REMOTE@ INTERNAL_IP_REMOVED     │
│                                              │
│  [Start Container]     [Stop Container]      │
│                                              │
│  ── Advanced Options ──                      │
│  ☐ Use Docker Volumes  ☐ Rebuild image       │
│  ☐ High computational demand                 │
│  Port Override: [8787]  Custom Params: [   ]  │
│  sim_design.yaml: [.\inputs\sim_design.yaml] │
│                                              │
│  Build: 2.0.0 | Commit: abc1234 | Built: ...│
│                                        [Close]│
└──────────────────────────────────────────────┘
```

**If the container is already running** (from a previous session), the tool detects it, recovers your password and port, and shows connection info immediately.

See [Options Reference](#-options-reference) for details on each option.

---

### Step 7 — Connect to RStudio 🖥️

After clicking **Start Container**, open the displayed URL in your browser:

| Mode | URL |
|---|---|
| **Local** | `http://localhost:8787` |
| **Remote** | `http://<remote-ip>:<port>` (e.g., `http://12.345.678.90:8787`) |

Log in with:
- **Username:** `rstudio`
- **Password:** the password you entered in Step 2

Your project files are mounted at `/home/rstudio/<repo-name>/` inside the container. Any changes you make in RStudio are reflected on the host.

---

### Step 8 — Stopping & Data Sync 🔄

Click **Stop Container** in the Container Manager. The tool:

1. ⏹️ **Stops** the Docker container
2. 📦 **Syncs volumes back** (if Docker Volumes were enabled):
   - `outputs/` → your host `output_dir` (from `sim_design.yaml`)
   - `inputs/synthpop/` → your host `synthpop_dir` (from `sim_design.yaml`)
   - Uses `rsync-alpine` helper image for reliable sync
   - Removes the volumes after sync
3. 🗑️ **Cleans** remote metadata (remote mode)
4. 📝 **Offers a Git commit/push dialog** if changes are detected in the repo:
   - Shows a diff summary
   - Enter a commit message
   - Optionally push to origin (converts GitHub HTTPS remotes to SSH automatically)

> 💡 You can close the dialog and start a new container without stopping — but a warning appears.

---

## ⚙️ Options Reference

| Option | Scope | Default | Description |
|---|---|---|---|
| **Use Docker Volumes** | Local & Remote | Off | Creates per-user named volumes for `outputs/` and `inputs/synthpop/`. Data is pre-populated from host on start and rsynced back on stop. Recommended for remote or to avoid bind-mount permission issues. |
| **Rebuild image** | Local & Remote | Off | Forces a fresh `docker build` even if the image already exists. Use after Dockerfile changes. |
| **High computational demand** | Remote only | Off | Adds `--cpus 32 -m 384g` to the container. Disabled in local mode. |
| **Port Override** | Remote only | `8787` | Choose a different port if `8787` is taken by another user. Local mode is locked to `8787`. |
| **Custom Params** | Local & Remote | *(empty)* | Extra `docker run` flags (space-separated). For advanced users, e.g., `--shm-size 4g`. |
| **sim_design.yaml** | Local & Remote | `.\inputs\sim_design.yaml` | Path to the YAML file containing `output_dir` and `synthpop_dir` keys. Relative paths resolve against the repo root. |

---

## 🖥️ Connecting to RStudio

| Detail | Value |
|---|---|
| **URL (local)** | `http://localhost:8787` |
| **URL (remote)** | `http://<remote-ip>:<port>` |
| **Username** | `rstudio` |
| **Password** | The password you entered at startup |
| **Working directory** | `/home/rstudio/<repo-name>/` |

> 💡 If you need to access RStudio from a different machine (e.g., via SSH tunnel), see the `access_rstudio_gui.ps1` script in the repository root.

---

## ❓ Frequently Asked Questions & Troubleshooting

### Docker Issues

| Problem | Solution |
|---|---|
| **"Docker CLI not found"** | Install [Docker Desktop](https://www.docker.com/products/docker-desktop/) on your **local Windows machine** and ensure `docker` is on PATH. The Docker CLI is needed locally even when running containers remotely. |
| **"Docker daemon is not reachable"** | Start Docker Desktop (local/Windows). The tool tries to start it automatically but may time out after ~30 seconds. |
| **"Docker Engine Missing (Remote)"** | Install Docker Engine on the remote Linux workstation: `sudo apt-get install docker-ce docker-ce-cli containerd.io`. See [docs.docker.com/engine/install](https://docs.docker.com/engine/install/). |
| **"Docker Daemon Not Running (Remote)"** | The tool offers to start it via `sudo systemctl start docker` (you will be prompted for the sudo password in the console). You can also start it manually on the workstation. |
| **"Docker Group Warning"** | The remote user needs `docker` group membership: `sudo usermod -aG docker <user>` then re-login. Without this, Docker commands require sudo and may fail. |
| **Docker build fails** | Check the console output. The tool automatically retries with a prerequisite Dockerfile (`Dockerfile.prerequisite.IMPACTncdGER`) then retries the main build. |
| **Port already in use** | Choose a different port in the Port Override field (remote mode). In local mode, stop any other container using port 8787. |

### SSH / Remote Issues

| Problem | Solution |
|---|---|
| **"SSH missing"** on startup | The tool offers to install the OpenSSH Client automatically (UAC prompt). If that fails, install manually: `Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0` in an admin PowerShell. |
| **ssh-agent won't start** | The tool tries to start it automatically with a UAC prompt. If that fails, run in an admin PowerShell: `Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent` |
| **Repeated password/key prompts** | Ensure ssh-agent is running (`Get-Service ssh-agent`) and your key is loaded (`ssh-add -l`). Check that `~/.ssh/config` has an entry for the workstation (see [First-Time Machine Setup](#-first-time-machine-setup)). |
| **Password bootstrap fails** | Ensure you typed the correct password for the `php-workstation` user on the remote machine. If Posh-SSH is unavailable, install PuTTY (`plink.exe`). |
| **"Posh-SSH not found" prompt** | Click **Yes** to install it (`Install-Module -Name Posh-SSH -Scope CurrentUser`). No admin required. It's needed for first-time password-based key setup. |
| **Remote key auth stops working** | Re-run the tool and go through the password bootstrap again. Check that `~/.ssh/id_ed25519_<username>` and `~/.ssh/known_hosts` still exist locally. |
| **Docker context fails on remote** | The tool falls back to `DOCKER_HOST=ssh://...`. If both fail, check network/firewall and SSH access to the workstation. |

### File & Path Issues

| Problem | Solution |
|---|---|
| **"docker_setup folder not found"** | Ensure your repository root contains a `docker_setup/` folder with `Dockerfile.IMPACTncdGER`. |
| **"YAML file not found"** | Verify the `sim_design.yaml` path (default: `.\inputs\sim_design.yaml`) exists in your repo. |
| **"Failed to ensure output_dir / synthpop_dir"** | Check that the directories referenced by `output_dir` and `synthpop_dir` in `sim_design.yaml` exist and are accessible. POSIX-style paths (starting with `/`) are rejected in local mode. |
| **Volume sync issues** | Ensure the `rsync-alpine` helper image can be built. Check console logs for rsync errors. Verify output/synthpop folders are writable. |

### Git Issues

| Problem | Solution |
|---|---|
| **Git dialog on stop** | This appears when the repo has uncommitted changes. Enter a commit message and optionally push, or click **Skip** to ignore. |
| **Push fails** | Ensure your SSH key is added to GitHub. The tool automatically converts HTTPS remotes to SSH for push. |

### UI Issues

| Problem | Solution |
|---|---|
| **Dialogs appear off-screen** | Move your mouse cursor to the desired monitor *before* the dialog opens. Forms center on the monitor where the cursor is. |
| **"PowerShell 7 required"** | Install PowerShell 7: `winget install Microsoft.PowerShell` or download from [https://aka.ms/powershell](https://aka.ms/powershell). |

---

## 📊 Logs & Diagnostics

The tool writes a detailed log file at:

```
~/.impact_gui/logs/impact.log
```

(Typically `C:\Users\<you>\.impact_gui\logs\impact.log`)

**Log features:**
- 📁 Auto-created on first run
- 🔄 Automatically rotated when the file exceeds **512 KB** (old logs renamed to `impact_<timestamp>.log`)
- 📊 Four log levels: `Info`, `Warn`, `Error`, `Debug`
- 🔍 `Debug` messages only appear when **Debug Mode** is enabled in the location selection dialog

**Environment variable overrides:**

| Variable | Purpose |
|---|---|
| `IMPACT_LOG_FILE` | Override the log file path |
| `IMPACT_LOG_DISABLE` | Set to `1` to disable file logging entirely |

> 💡 **Enable Debug Mode** during setup if things aren't working — it captures detailed information about every step.

---

## 👥 Multiple Users on the Same Workstation

The tool is designed for multi-user remote workstations:

- **Unique containers**: Each user gets a container named `<repo>_<username>`, so containers don't collide
- **Unique volumes**: Docker volumes include the username (e.g., `impactncd_germany_output_johndoe`)
- **Unique SSH keys**: Keys are stored as `id_ed25519_<username>`, avoiding conflicts
- **Port selection**: Remote users can choose different ports to avoid conflicts (check which ports are in use — the tool detects occupied ports)
- **Remote metadata**: Session info is stored at `/tmp/impactncd/<container>.json` on the workstation, enabling session recovery

> ⚠️ **Port coordination**: When working remotely with colleagues, communicate which ports you're using. The tool warns if a port is already taken but relies on users choosing non-conflicting ports.

---

## 📦 Launcher & Desktop Shortcut

### Starting the Tool

Double-click `IMPACT.bat` in the `current_version/` folder. It auto-detects PowerShell 7 (`pwsh`) and falls back to Windows PowerShell if needed.

### Desktop Shortcut

To create a desktop shortcut with the IMPACT icon, double-click `Create-Shortcut.bat` once. This creates an `IMPACT.lnk` on your Desktop that launches the tool directly.

> 💡 Distribute the `current_version/` folder (containing `IMPACT.bat`, `IMPACT_Docker_GUI_v2.ps1`, and `IMPACT_Docker_GUI.psm1`) together with the `docker_setup/` folder and `sim_design.yaml` in the project repository.

---

## 📖 Glossary

| Term | Meaning |
|---|---|
| 🐳 **Docker** | A platform that runs applications in isolated *containers*. Think of it as a lightweight virtual machine for your simulation environment. |
| �️ **Docker Desktop** | The GUI-based Docker distribution for Windows and macOS. Used for **local** containers on your Windows machine. |
| ⚙️ **Docker Engine** | The native Linux Docker daemon (`dockerd`). Used on the **remote** workstation for running containers directly on the host without a VM, giving full access to system RAM. |
| �📦 **Container** | A running instance of a Docker *image* — in this case, an RStudio Server with R and your project files. |
| 🖼️ **Image** | A blueprint for containers. Built from a `Dockerfile`, it contains the OS, R, RStudio Server, and dependencies. |
| 💾 **Docker Volume** | A managed storage area that Docker controls. Faster and safer than bind-mounting host folders, especially over SSH. |
| 🔗 **Bind Mount** | Directly connecting a host folder into the container so files are shared in real time. |
| 🔑 **SSH (Secure Shell)** | A protocol for secure remote access. Used to connect to the workstation and for Git authentication with GitHub. |
| 🔑 **SSH Key (Ed25519)** | A cryptographic key pair. The *private key* stays on your machine; the *public key* goes to GitHub and the remote workstation. |
| 🌐 **Docker Context** | A named configuration telling Docker where to run commands — locally or on a remote host via SSH. |
| 📋 **sim_design.yaml** | A YAML configuration file in your project that tells the tool where your output and synthpop directories are. |
| 🔄 **rsync** | A file synchronization tool used to copy data between Docker volumes and host folders efficiently. |
| 🧰 **Posh-SSH** | A PowerShell module for SSH connections. Used as the primary method for first-time password-based key setup on the remote workstation. |
| 🧰 **plink.exe** | A PuTTY command-line SSH tool. Used as a fallback for password-based key setup if Posh-SSH is unavailable. |
| 📄 **IMPACT.bat** | Batch launcher — double-click to start the IMPACT GUI without needing to open PowerShell manually. |
| 🖥️ **RStudio Server** | A web-based IDE for R that runs inside the Docker container. You access it through your browser. |
| 🏷️ **Container Name** | Follows the pattern `<repo>_<username>`, e.g., `IMPACTncdGER_johndoe`. |
| 🏷️ **Remote User** | The shared Linux account on the workstation (default: `php-workstation`). |

---

## 🐧 Remote Workstation Setup

The remote Linux workstation uses **Docker Engine** (native Docker daemon) instead of Docker Desktop. This gives containers direct access to system RAM without VM overhead.

### One-Time Admin Setup

These steps must be performed **once** by an administrator on the remote workstation:

1. **Install Docker Engine:**
   ```bash
   sudo apt-get update
   sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin
   ```
   See [docs.docker.com/engine/install](https://docs.docker.com/engine/install/) for distribution-specific instructions.

2. **Enable Docker to start on boot:**
   ```bash
   sudo systemctl enable docker
   ```

3. **Add each user to the `docker` group** (so they can run Docker commands without `sudo`):
   ```bash
   sudo usermod -aG docker php-workstation
   ```
   The user must log out and back in for this to take effect.

4. **Verify** (as the remote user):
   ```bash
   docker version
   docker run --rm hello-world
   ```

### What the Tool Checks Automatically

When you select remote mode, the tool:
- Verifies the Docker CLI exists on the remote host
- Checks that the Docker daemon is running
- Offers to start the daemon via `sudo systemctl start docker` if it is not running (you will be prompted for the sudo password)
- Warns if the remote user is not in the `docker` group

---

*Last updated: 2025 — IMPACT NCD Germany Docker GUI v2.0.0*
