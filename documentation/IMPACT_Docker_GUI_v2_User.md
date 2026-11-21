# IMPACT Docker GUI v2: User Guide

A step-by-step guide to starting and stopping your **IMPACT NCD Germany** RStudio containers, either on your own Windows PC (for testing) or on the shared Linux workstation (for heavy simulation runs).

You do not need to know Docker or the command line. Where a command is needed, this guide shows it exactly.

> **Before you use remote mode, please read [Your GitHub key on the shared workstation](#your-github-key-on-the-shared-workstation).** It explains a security trade-off you should know about.

---

## Contents

1. [What this tool does](#what-this-tool-does)
2. [What you need](#what-you-need)
3. [One-time setup on a new PC](#one-time-setup-on-a-new-pc)
4. [Quick start](#quick-start)
5. [Step by step](#step-by-step)
   - [Step 1: Start the tool](#step-1-start-the-tool)
   - [Step 2: GitHub username and RStudio password](#step-2-github-username-and-rstudio-password)
   - [Step 3: Your SSH key](#step-3-your-ssh-key)
   - [Step 4: Local or remote](#step-4-local-or-remote)
   - [Step 5: Choose the repository](#step-5-choose-the-repository)
   - [Step 6: The Container Manager](#step-6-the-container-manager)
   - [Step 7: Open RStudio](#step-7-open-rstudio)
   - [Step 8: Stop the container](#step-8-stop-the-container)
6. [Your GitHub key on the shared workstation](#your-github-key-on-the-shared-workstation)
7. [Options reference](#options-reference)
8. [Docker volumes: how results get back to your folders](#docker-volumes-how-results-get-back-to-your-folders)
9. [Git: commit and push when you stop](#git-commit-and-push-when-you-stop)
10. [Troubleshooting](#troubleshooting)
11. [Logs and diagnostics](#logs-and-diagnostics)
12. [Several users on the same workstation](#several-users-on-the-same-workstation)
13. [Launcher and desktop shortcut](#launcher-and-desktop-shortcut)
14. [Remote workstation setup (for the admin)](#remote-workstation-setup-for-the-admin)
15. [Glossary](#glossary)

---

## What this tool does

The IMPACT Docker GUI is a small Windows program that:

- **builds** the Docker image with the IMPACT simulation environment (RStudio Server, R and all packages),
- **starts** an RStudio Server container on your PC or on the shared workstation,
- **connects your project folder** to that container, so you edit the real files in RStudio in your web browser,
- **creates and manages your SSH key** for GitHub and for logging in to the workstation,
- **copies results back** from Docker volumes when you stop (only if you use volume mode),
- **offers to commit and push** your changes to GitHub when you stop the container.

Everything happens in a few dialog windows. A console window stays open behind them and shows progress messages.

---

## What you need

| What | Details |
|---|---|
| **Windows** | Windows 10 or 11. |
| **PowerShell 7.3 or newer** | Must be installed once (see [One-time setup](#one-time-setup-on-a-new-pc)). Windows only includes the older "Windows PowerShell 5.1", which cannot run IMPACT. |
| **Docker Desktop** | Only for **local** mode. For remote-only use, the Docker command-line program (`docker.exe`) on your PATH is enough. |
| **OpenSSH client** | `ssh` and `ssh-keygen`. Part of Windows 10/11; IMPACT offers to install it if it is missing. |
| **Network access to the workstation** | Only for **remote** mode: institute network or VPN. |
| **Posh-SSH PowerShell module** | Only for the **first** remote login with the workstation password. IMPACT offers to install it (no admin rights needed). |
| **Git for Windows** | Optional. Needed in **local** mode for the commit/push offer when you stop. Without it, commit from the Git tab in RStudio. |
| **A GitHub account** | Your GitHub **username** is used for your key, your git identity and your container name. |

---

## One-time setup on a new PC

### 1. Install PowerShell 7

1. Open the Start menu, type `cmd` and open **Command Prompt**.
2. Run:
   ```
   winget install --id Microsoft.PowerShell --source winget
   ```
3. If `winget` is missing or blocked, download the installer from <https://aka.ms/powershell-release> (the file whose name ends in `-win-x64.msi`) and run it, or install **PowerShell** from the Microsoft Store.
4. If the installer asks for administrator rights that you do not have, ask your IT support to install PowerShell 7.

If PowerShell 7 is missing, `IMPACT.bat` shows these instructions itself and waits for a key press. If your PowerShell 7 is older than 7.3, it tells you to update it with `winget upgrade --id Microsoft.PowerShell --source winget`.

### 2. What IMPACT sets up by itself

A Windows permission (UAC) prompt appears only if IMPACT has to install the OpenSSH client, and only after you agreed to the install.

| Component | What happens | Admin rights? |
|---|---|---|
| **OpenSSH client** | If `ssh` is not on PATH, IMPACT first looks in `C:\Windows\System32\OpenSSH` and uses it from there (no admin needed). If it is really missing, IMPACT **asks you first** and then installs the Windows feature "OpenSSH Client" in a separate administrator window. | Yes, for the install only |
| **ssh-agent service** | Optional: IMPACT works without it. If the Windows `ssh-agent` service is running, or can be started without admin rights, IMPACT loads your key into it. If the service is disabled (the Windows default), IMPACT simply goes on without it; no permission prompt appears. | No |
| **SSH config file** | In remote mode IMPACT adds an entry for the workstation to `C:\Users\<you>\.ssh\config`. At every start it also repairs key paths in that file that contain a space but have no quotes (see below). | No |
| **Posh-SSH module** | On the first remote login IMPACT offers to install it for your user. | No |

### 3. Manual commands (only if the automatic setup fails)

In an **administrator** PowerShell:

```powershell
# OpenSSH client
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0

# ssh-agent service (optional, IMPACT works without it)
Set-Service ssh-agent -StartupType Automatic
Start-Service ssh-agent
```

As your normal user (no admin), in any PowerShell window:

```powershell
ssh-add $HOME\.ssh\id_ed25519_<username>
```

In **PowerShell 7** (not as admin; Start menu: **PowerShell 7 (x64)**, or type `pwsh` in a Command Prompt window):

```powershell
Install-Module -Name Posh-SSH -Scope CurrentUser -Force
```

IMPACT runs in PowerShell 7 and only finds Posh-SSH when it was installed from PowerShell 7. The older "Windows PowerShell", which opens when you type "PowerShell" in the Start menu, keeps its modules in a different folder.

### The SSH config entry

In remote mode IMPACT writes this block to `C:\Users\<you>\.ssh\config` so that every SSH connection to the workstation uses your key. Docker also finds your key through this block when it talks to the workstation.

```
# IMPACT Docker GUI - auto-generated entry for remote workstation
Host <workstation-ip>
    User php-workstation
    IdentityFile "C:/Users/<you>/.ssh/id_ed25519_<username>"
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ConnectTimeout 10
```

The key path is in double quotes, so a Windows user folder with a space (for example `C:\Users\Max Mustermann`) works. IMPACT changes this file only in these cases:

- **The block for the workstation is replaced** when it points to a key file that does not exist, to a different key, uses backslashes in the key path, has a key path with a space but without quotes, or has no `IdentityFile` line. Everything after the block (other `Host`, `Match` and `Include` sections) stays as it is.
- **Missing quotes are added everywhere in the file.** An `IdentityFile` path with a space but without quotes makes ssh reject the whole file, so every ssh connection fails. IMPACT therefore adds the quotes in every section of the file, not only in its own block. This check runs at every start, also if you only use local mode.

Before IMPACT changes a line or a block that you (or an admin) wrote, that is, one without the `# IMPACT Docker GUI` comment above it, it saves a copy of the whole file as `config.impact-backup-<date>-<time>` next to it (or, if that is not possible, in `C:\Users\<you>\.impact_gui\ssh-config-backups`). If no copy can be saved, IMPACT does not change your lines. It then writes an error to the console and the log file that explains the exact change to make by hand. (Until then, remote Docker may fail if your own block points to another key.)

---

## Quick start

1. Double-click **`IMPACT.bat`** (or your Desktop shortcut, see [Launcher](#launcher-and-desktop-shortcut)).
2. Enter your **GitHub username** and choose a **new RStudio password** (at least 8 characters, not your GitHub password).
3. If IMPACT shows your public key (a new key, or a key that GitHub does not accept yet), add it to **GitHub: Settings, SSH and GPG keys, New SSH key**.
4. Choose **Local Container** or **Remote Container** (for remote, enter the workstation IP address).
5. Pick your repository (local: folder picker; remote: list from the workstation).
6. In the Container Manager, click **Start Container**. The first start builds the image and can take 30 minutes or more.
7. Open the URL shown (for example `http://localhost:8787`), log in as **`rstudio`** with your RStudio password.
8. When you are done, save your files in RStudio and click **Stop Container**. Confirm with **Yes**. IMPACT copies results back (volume mode) and offers to commit and push your changes.

---

## Step by step

### Step 1: Start the tool

| Method | How |
|---|---|
| **Launcher (recommended)** | Double-click `IMPACT.bat` in the IMPACT folder (`current_version`). |
| **Desktop shortcut** | Double-click `Create-Shortcut.bat` once. It creates an `IMPACT` shortcut on your Desktop that starts `IMPACT.bat`. |
| **From a PowerShell 7 terminal** | `pwsh -File .\IMPACT_Docker_GUI_v2.ps1` in the IMPACT folder. |

`IMPACT.bat`:

- checks that the IMPACT files are next to it (`IMPACT.bat` must stay in the IMPACT folder; for a Desktop icon use the shortcut made by `Create-Shortcut.bat`),
- looks for PowerShell 7 (on PATH, then in `C:\Program Files\PowerShell\7`),
- explains how to install or update PowerShell 7 if it is missing or older than 7.3,
- starts the GUI,
- keeps the window open with "Press any key to close this window..." when IMPACT stops because of an error (for example a setup step that failed) or crashes, so you can read the messages.

When you click **Cancel** in one of the first dialogs, or **Close** in the Container Manager, IMPACT ends normally and the window closes. If the window ever closes without a message, look at the end of the log file (see [Logs](#logs-and-diagnostics)).

On start, IMPACT checks that the `docker` and `ssh` programs exist, starts its log file and switches the console to UTF-8 (so umlauts display correctly). If Git for Windows is missing, a yellow warning in the console says that the commit offer is not available in local mode.

### Step 2: GitHub username and RStudio password

The dialog **Remote Access - IMPACT NCD Germany** asks for two things:

| Field | What to enter | Rules |
|---|---|---|
| **GitHub username** | Your GitHub **username** (the name on your github.com profile; an e-mail address does not work). | Spaces are removed and it is changed to lowercase. You may also paste your profile link (`https://github.com/<name>`) or `@name`. Only letters, digits, `-` and `_` (up to 39 characters). |
| **RStudio password** | A **new** password, used to log in to RStudio in your browser. | At least 8 characters, not the same as your username, and not a very common password such as `12345678` or `password`. |

> **Do not use your GitHub password, or any password you use elsewhere.** On the shared workstation, colleagues who use the same account can read the RStudio password of a running container.

When you click **Continue**, IMPACT checks the username on github.com while the dialog stays open:

- **Not found**: a message explains how to find your username (click your profile picture on github.com: the name shown there is your username). Correct it and click Continue again.
- **An organisation name** or **an e-mail address**: a message explains that a personal username is needed.
- **GitHub could not be reached** (no internet, proxy, or "too many checks" from your network), or the answer did not come from GitHub (for example a proxy or a Wi-Fi login page answered): the box **GitHub check not possible** asks whether to continue anyway. Choose **No** to correct the name or try again.

If you come back to this dialog with **Back** later, your earlier entries are filled in, and **Cancel** keeps them. The first time, Cancel closes IMPACT.

### Step 3: Your SSH key

IMPACT uses one key pair per GitHub username:

```
C:\Users\<you>\.ssh\id_ed25519_<username>       (private key, keep it secret)
C:\Users\<you>\.ssh\id_ed25519_<username>.pub   (public key, safe to share)
```

- **If the key already exists**, it is reused and the public key is printed in the console.
- **If it does not exist**, IMPACT creates it (an Ed25519 key **without a passphrase**, comment `IMPACT_<username>`), copies the public key to the clipboard and shows it in a window with a **Copy to Clipboard** button.

IMPACT also makes sure that the key can be used:

- If the public key file (`.pub`) is missing, IMPACT rebuilds it from the private key. The key itself stays the same, so nothing changes on GitHub or on the workstation.
- Keys made by old IMPACT versions under PowerShell 7.0-7.2 may have the accidental passphrase `-q`. IMPACT removes it by itself; the key stays the same.
- If the key has any other passphrase, or cannot be created or read, the box **SSH key problem** explains what to do (for example: remove the passphrase with `ssh-keygen -p -f "<key file>"`, or rename both key files and start IMPACT again to get a new key). IMPACT then stops and the window stays open.

**Add the public key to GitHub** (needed for git pull and push):

1. On github.com click your profile picture, then **Settings**, then **SSH and GPG keys**, then **New SSH key** (or open <https://github.com/settings/keys>).
2. Give it a title you will recognise (for example `IMPACT laptop`), paste the key and click **Add SSH key**.

**GitHub key check.** Each time you start IMPACT, it asks GitHub whether it accepts your key (with your IMPACT key only). This usually takes about a second, and up to about 10 seconds if your network blocks GitHub's SSH port 22. The check runs once per key in each session; going **Back** does not repeat it.

- If GitHub does **not** accept the key yet, the window **Add your SSH key to GitHub** shows your public key (already copied to the clipboard) with four buttons: **Copy key**, **Open GitHub** (opens <https://github.com/settings/keys>), **Check again** (after you added the key) and **Continue anyway** (git pull and push will not work until the key is on GitHub).
- If GitHub cannot be reached (offline, VPN, firewall), or the GitHub host key stored on this PC does not match, the window does not appear; a warning in the console and the log says so.
- If ssh cannot use the key file itself (on Windows usually because other users may read the file), the window does not appear either, because adding the key to GitHub would not help. The warning in the console and the log gives the fix (an `icacls` command, or rename both key files and start IMPACT again).

What happens with the private key:

- **Local mode:** it is mounted read-only into your container on your own PC, so git in RStudio can use it.
- **Remote mode:** it is **copied into the shared workstation account**. Please read [Your GitHub key on the shared workstation](#your-github-key-on-the-shared-workstation).

If the Windows `ssh-agent` service runs, IMPACT also loads the key into it. IMPACT does not need the agent.

### Step 4: Local or remote

The dialog **Container Location - IMPACT NCD Germany** has two buttons:

| Button | When to use it |
|---|---|
| **Local Container** | Testing on your own PC with Docker Desktop. |
| **Remote Container** | Heavy simulation runs on the shared workstation. Enter the workstation address in **Remote IP Address** first. |

- The IP address must be four numbers from 0 to 255, separated by dots and without leading zeros, for example `192.168.1.100` (**Invalid IP Format** otherwise). Ask the admin for the right one. The box is pre-filled only if a file named `.env` next to the IMPACT files (or one folder above) contains a line `WORKSTATION_IP=<address>`. The address may be in quotes, the line may start with `export `, and a comment after the address (`# ...`) is ignored.
- **Enable Debug Mode** shows detailed progress messages in the console. Turn it on when something does not work.
- **Back** returns to the username/password dialog.

### Step 5: Choose the repository

If anything in this step fails or you cancel, IMPACT returns to **Step 4**.

#### 5a. Local

1. A folder picker opens (it starts in your Documents folder). Select the **main folder of the model repository**: the folder that contains `docker_setup`.
2. IMPACT checks the folder:
   - **Network Folder Not Supported**: the folder is on a network drive or share (`\\server\...` or a mapped drive). Docker Desktop cannot use it. Clone the repository to a folder on your PC, for example `C:\Users\<you>\Repositories`.
   - **Not a Model Repository**: there is no `docker_setup` folder. You probably selected the parent folder.
   - **Unsupported Folder Name**: the folder name cannot be turned into a Docker name. Rename it using only letters, digits, `-` or `_`.
   - Folder names with spaces, brackets or umlauts (for example `IMPACTncd_Germany - Kopie`) are accepted: IMPACT uses a cleaned-up name (`IMPACTncd_Germany_Kopie`) for the container and image. The folder itself is not renamed.
   - **Folder Inside OneDrive**: works, but OneDrive keeps syncing Git data and large outputs. A folder outside OneDrive is recommended. Choose **Yes** to continue anyway.
   - **No Git Repository Found**: the folder has no `.git`. You can continue, but the commit offer at Stop will not work.
3. IMPACT checks Docker Desktop:
   - If it is not running, IMPACT tries to start it and checks about 30 times whether the engine is up (at least half a minute).
   - **Docker Startup Issue**: **Yes** = start Docker Desktop yourself, wait until it says the engine is running, then click OK to check again; **No** = continue anyway (starting a container will fail until Docker runs); **Cancel** = go back.
   - **Docker Access Denied**: your Windows account may not use Docker Desktop. Ask IT to add you to the local `docker-users` group (an administrator runs `net localgroup docker-users "DOMAIN\you" /add`), then sign out of Windows and back in.
   - **Docker Not Reachable**: Docker stopped answering; start it and try again.

#### 5b. Remote

1. **Key login test.** IMPACT tries to log in to the workstation account `php-workstation` with your key.
   - **Workstation not reachable**: check the network or VPN, that the workstation is on and that the IP is right. No password is asked in this case.
   - **Workstation identity changed**: the workstation presented a different SSH host key than last time. This is normal after a reinstall, but could also mean someone is intercepting the connection, so IMPACT will not send your password. Ask the admin. If the workstation was reinstalled, run `ssh-keygen -R <ip>` in PowerShell and start IMPACT again. If you logged in with the workstation password before, also run `Remove-SSHTrustedHost -HostName <ip>` in **PowerShell 7** (Start menu: **PowerShell 7 (x64)**, or type `pwsh` in a Command Prompt window); older Posh-SSH versions use `Remove-SSHTrustedHost -SSHHost <ip>`. The message shows both commands with the right address.
2. **First time only: password.** If your key is not yet accepted, the window **Enter remote password** asks for the password of `php-workstation@<ip>` (ask the admin). IMPACT uses it once to install your public key on the workstation:
   - It uses the **Posh-SSH** module and offers to install it if it is missing (click **Yes**).
   - **Wrong password**: the message appears and the password window comes back. Cancel stops.
   - **Password login not allowed**: the workstation does not accept password logins at all (the admin switched them off), so typing the password again will not help. Send your **public** key file `C:\Users\<you>\.ssh\id_ed25519_<username>.pub` (safe to share) to the admin and ask them to add it to the `php-workstation` account. Then start IMPACT again.
   - **Workstation identity changed** can also appear here: Posh-SSH keeps its own list of trusted workstations and refused the workstation's key. The message shows the `Remove-SSHTrustedHost` command to run in PowerShell 7 if the workstation was reinstalled.
   - PuTTY's `plink.exe` (version 0.77 or newer) is used only if Posh-SSH is not available.
   - Afterwards IMPACT checks that the key login works. If not: **SSH key setup failed** with details; contact the admin.
3. **Key copy.** IMPACT copies your private key to `~/.ssh/id_ed25519_<username>` in the shared account (needed by git inside the container and for pushing at Stop). See [Your GitHub key on the shared workstation](#your-github-key-on-the-shared-workstation).
   - **SSH key copy failed**: the copy did not work. If the workstation still has the **same** key from an earlier session, IMPACT notices this and simply continues. Otherwise this box shows the details (and says so when an older, different copy of your key is still there, which GitHub would refuse). Check the network or VPN and try again; if it keeps happening, ask the admin whether the workstation's disk is full or the folder `~/.ssh` is not writable.
   - IMPACT also makes sure the account's `~/.ssh/known_hosts` file exists and contains a current host key of GitHub (needed when IMPACT pushes from the workstation at Stop). It compares the stored github.com keys with the fingerprints that GitHub publishes. Only if none of them matches does it replace the github.com lines, and only with freshly downloaded keys that match those fingerprints. Lines for other servers are never changed.
4. **Repository list.** IMPACT lists the folders in `/home/php-workstation/Schreibtisch/Repositories`. Choose one and click **Select**.
   - **No repositories found**: the folder is empty; ask the admin to clone the repository there. If the message says the connection was lost, check the network.
   - Folder names with spaces, brackets or umlauts are accepted: IMPACT uses a cleaned-up name for the container and image (as in local mode). The folder on the workstation is not renamed.
   - **Unsupported Folder Name**: the folder name cannot be turned into a Docker name. Ask the admin to rename it using only letters, digits, `-` or `_`.
   - **Not a Model Repository**: the folder has no `docker_setup` folder. Choose the model repository (for example `IMPACTncd_Germany`).
5. **Docker on the workstation.** IMPACT checks that Docker works there:
   - **Docker Permission Denied (Remote)**: the admin must run `sudo usermod -aG docker php-workstation`.
   - **Docker Engine Missing (Remote)**: Docker is not installed on the workstation (admin task).
   - Docker installed but not running: IMPACT offers to start it with `sudo systemctl start docker`. Type the sudo password **in the console window** when asked.
   - A warning if `php-workstation` is not in the `docker` group.

> IMPACT adds the Docker contexts `local` and `remote-<ip>` and uses them only for its own commands, so your own `docker` commands and other Docker tools keep using your active context. One exception: if your active context points at a workstation (its name starts with `remote-`), IMPACT sets it back to `default`. In remote mode it does this only for the context of the selected workstation.

### Step 6: The Container Manager

Before the window opens, IMPACT asks Docker which containers exist:

- **Docker Not Reachable** (Retry/Cancel): Docker Desktop is still starting, or the workstation connection dropped. **Retry** checks again. With **Cancel** the window opens anyway; the status then shows **UNKNOWN (Docker not reachable)**, and the status line asks you to click **Back** and continue again so IMPACT can check once more.
- **Old Container Found**: a stopped container with your container's name exists (made outside IMPACT). Choose **Yes** to remove it; your files are not affected. Otherwise Start will fail.

The Container Manager window shows:

```
+-----------------------------------------------------------+
|  o  STOPPED          (or  *  RUNNING, or  o  UNKNOWN)     |
|     URL          http://localhost:8787                    |
|     Login        rstudio                                  |
|     Password     ********  (tick 'Show password' to see it)|
|     Repository   IMPACTncd_Germany                        |
|     Container    IMPACTncd_Germany_jdoe                   |
|     Location     LOCAL   (or REMOTE@<ip>)                 |
|                                                           |
|     [Start Container]        [Stop Container]             |
|                                                           |
|  Advanced Options                                         |
|  [ ] Use Docker Volumes     [ ] Rebuild image             |
|  [ ] High computational demand   [ ] Show password        |
|  Port (8787-8799) [8787]    Custom Params [            ]  |
|  sim_design.yaml  [.\inputs\sim_design_local.yaml     ]   |
|  [<- Back]                                    [Close]     |
|  (status line)                                            |
|  Build: 2.0.0 | Commit: abc1234 | Built: 2026-...         |
+-----------------------------------------------------------+
```

- The password is hidden; tick **Show password** to see it (handy, but not while you share your screen).
- **If your container is already running** (for example you closed IMPACT without stopping), IMPACT shows **Container already running** with the URL, reads the password and port from the container and enables only **Stop Container**. In volume mode it also restores where the results must be copied back to.
- **Different repository folder**: the running container was started from another folder with the same name (for example a second clone of the repository). The message shows both folders. When you click Stop, IMPACT copies results and checks git changes in the folder the container really uses.
- **Results from an earlier session are still in Docker volumes**: if volumes from an earlier session still exist (for example after a crash), IMPACT ticks **Use Docker Volumes** and says so in the status line. Click **Start Container** to copy them back (see [Docker volumes](#docker-volumes-how-results-get-back-to-your-folders)).
- If all RStudio ports (8787-8799) are already used by other containers, the status line says so. Stop another container (or ask a colleague) before you click Start.
- **Back** returns to Step 4 (only when no container is running). **Close** closes IMPACT; if a container is running it asks **Close without stopping?** The container keeps running and you can reconnect later by starting IMPACT again. In volume mode the question also reminds you that your results stay inside the Docker volumes until you reopen IMPACT and click **Stop Container**.
- If something unexpected goes wrong in the window, **IMPACT - Unexpected error** explains it in plain words and names the log file. You can try again; if it keeps happening, send the log file to the maintainer.
- The footer shows the tool version, the git commit of the tool folder (or `unknown`) and when the tool files were last changed. Include it when you report a problem.

#### What happens when you click Start Container

IMPACT checks everything that can be checked quickly **before** the long image build:

1. **Port**: must be a number from 8787 to 8799 without a leading zero (**Invalid port**).
2. **Remote only:** your key must be on the workstation and the login must work. **SSH problem** explains the cause (key missing, workstation not reachable, workstation identity changed, login refused) and what to do.
3. **Docker check**: IMPACT asks Docker which containers are running right now.
   - **Docker not reachable**: nothing is built or started, and the status shows UNKNOWN. In local mode, start Docker Desktop, wait until it says the engine is running, and click Start again. In remote mode the message says that IMPACT could log in to the workstation, but Docker there did not answer: check your network or VPN connection and click Start again in a minute; if it keeps failing, ask the admin to check that Docker runs on the workstation.
   - **Already running**: your container is running after all (for example started from another IMPACT window or another PC). Click **Back** and continue again; IMPACT then connects to it.
4. **Port in use**: if another container already uses the port in the Port box, **Port conflict** appears and IMPACT enters a free port in the box; click Start again to use it. If all ports from 8787 to 8799 are in use, **No free port** asks you to stop a container first (or ask a colleague to stop theirs).
5. If you already have other IMPACT containers running, IMPACT asks whether to start another.
6. **Local only:** the `docker_setup` folder must exist (**Missing docker_setup**).
7. The **YAML file** in the `sim_design.yaml` box must exist, also on the workstation (**Missing YAML**; **Connection problem** if the workstation could not be asked).
8. `output_dir` and `synthpop_dir` are read from the YAML file and both folders are checked:
   - **Setting missing in YAML**: add the line (for example `output_dir: ./outputs` or `synthpop_dir: ./inputs/synthpop`) to the file.
   - **Network Folder Not Supported** (local mode): the folder is on a network share (`\\server\...`) or a mapped network drive, which Docker Desktop cannot use. Use a folder on your PC, for example one inside the repository.
   - **Path error**: a Linux-style path (`/mnt/...` or `~/...`) in local mode. Use `sim_design_local.yaml` with Windows or relative paths for local runs.
   - **Folder missing**: IMPACT offers to create it (on your PC, or inside the repository on the workstation). Folders outside the repository on the workstation (for example `/mnt/...`) are never created; ask the admin.
9. **Repository already in use**: another running container (perhaps a colleague's) uses the same repository folder. If you both work in it, edits, git pulls and results mix. The default answer is **No**.
10. **Earlier results found**: Docker volumes from an earlier session still exist (for example after a crash). This check runs whether **Use Docker Volumes** is ticked or not; see [Docker volumes](#docker-volumes-how-results-get-back-to-your-folders). If you choose to copy them, the status line shows the progress.
11. **Volume mode only:** the helper image `rsync-alpine` is prepared (**Volume helper missing** if it cannot be downloaded).
12. **Image build** (only if the image does not exist yet, or **Rebuild image** is ticked). The window switches to "busy": the buttons are greyed out, the status line says `Building the Docker image (30+ min). Progress: see the console window.`, and you should not close the IMPACT window. Follow the progress in the console window. Because the build runs on the window's own thread, Windows may show the window as "Not Responding". If Windows asks whether to close IMPACT because it is not responding, choose **Wait**. Closing it stops IMPACT in the middle of the build. If the build fails:
    - remote only: IMPACT logs in to Docker with the credentials from `docker_setup/.env` in the repository (if present) and tries once more;
    - then **Image build failed** asks whether to try a fallback: build the prerequisite image (`Dockerfile.prerequisite.IMPACTncdGER`) and then the main image again. This can take another 30 to 60 minutes. **Yes** (the default) starts it, **No** stops.
    The login retry and the second build of the main image can reuse parts that were already built. The prerequisite build always starts from scratch, so the fallback still takes a long time. **Build failed** means all attempts failed (or you chose No); see the console output.
13. **Start**: the window stays "busy" (status line `Starting the container. Please wait...`) until the container runs. In volume mode the volumes are created and your existing files are copied into them (**Volume copy problem** if that reports errors). If the container cannot start, **Container start failed** explains why in plain words, for example "Port 8790 is already in use" or "Port ... is blocked or reserved by Windows. Choose a different port."
14. **Setup inside the container**: your SSH key is copied to `/home/rstudio/.ssh` (mode 600), GitHub's host keys are stored in `/home/rstudio/.ssh/known_hosts`, and git gets your name, your e-mail and your IMPACT key (see [Step 7](#step-7-open-rstudio)). If part of this fails, **Container setup incomplete** says what will not work (for example git pull from RStudio). If the container stopped right after starting, **Container stopped** appears with the path of the log file; ticking **Rebuild image** often helps.
15. The status changes to **RUNNING** and the console prints the URL.

### Step 7: Open RStudio

| Mode | URL |
|---|---|
| **Local** | `http://localhost:<port>`, for example `http://localhost:8787`. In local mode RStudio is reachable **only from your own PC**. |
| **Remote** | `http://<workstation-ip>:<port>`, for example `http://192.168.1.50:8788`. Reachable from the institute network. |

Log in with username **`rstudio`** and your RStudio password from Step 2.

Your repository is at `/home/rstudio/<repository>` inside RStudio. Changes there are changes to the real files (on your PC in local mode, on the workstation in remote mode). The output and synthpop folders from your YAML file appear as `outputs` and `inputs/synthpop` inside the repository folder.

Git inside RStudio is prepared for you:

- your name and the e-mail `<username>@users.noreply.github.com` are set, and `git pull` merges when needed;
- git uses your IMPACT key for GitHub. This is stored in git's own settings inside the container, so the Git pane in RStudio and the RStudio Terminal both use the key;
- if your repository's address is `https://github.com/...` (typical for repositories cloned with GitHub Desktop), git inside the container still talks to GitHub over SSH with your key, so pull and push work. This setting exists only inside the container; the settings of your repository on your PC or on the workstation are not changed;
- GitHub's host key was stored when the container started, so the first pull does not ask "Are you sure you want to continue connecting?".

### Step 8: Stop the container

**Save your files in RStudio and let running simulations finish first.** Then click **Stop Container**.

1. **Stop container?** asks for confirmation. Running simulations are killed and unsaved editor tabs are lost; saved files and output folders are kept. The default answer is **No**, so pressing Enter by accident does nothing.
2. If Docker cannot be reached, **Docker not reachable** says so and nothing changes; check Docker Desktop or the VPN and click Stop again.
3. If the container already ended by itself (crash, reboot), IMPACT skips the confirmation and still tidies up (and copies results back in volume mode).
4. **Volume mode:** results are copied back to your folders. Each volume is deleted only after its own copy worked. If a copy fails (for example because the target folder was renamed or moved), **Results still in Docker volumes** lists the volumes that were kept; nothing is lost. See [Docker volumes](#docker-volumes-how-results-get-back-to-your-folders).
5. **Git:** IMPACT checks the repository and offers to commit and push. See [Git](#git-commit-and-push-when-you-stop).
6. The status line tells you the result:
   - **All done. You can close this window or start another container.** when everything worked, there was nothing to commit, or you chose **Skip**;
   - **Container stopped.** followed by what was not done, for example `Committed, but the push to GitHub failed.` or `Your changes were NOT checked or committed: git is not installed on this computer. ...`;
   - **Stopped. Results are still in Docker volumes (see the message).** when a copy failed.

While IMPACT stops the container, copies the results and checks git, the window is "busy": the buttons are greyed out and the status line says what IMPACT is doing.

---

## Your GitHub key on the shared workstation

**Please read this before using remote mode.**

All colleagues use the **same** Linux account on the workstation (`php-workstation`). In remote mode IMPACT copies your **private** GitHub SSH key into that account, to `/home/php-workstation/.ssh/id_ed25519_<username>`. It is needed there so that git inside your container, and the push when you stop, can reach GitHub as you. The key has **no passphrase**, and it **stays there** after you stop the container.

**What this means:**

- Everyone who can use the `php-workstation` account (every colleague who uses IMPACT in remote mode, and anyone else who has that account's password), and anyone with administrator (root) or Docker rights on the workstation, **can read your key file**. The file permissions (only the account may read it) do not help, because they all *are* that account.
- With a copy of the key, someone can **act as you on GitHub over SSH**: read, push to and delete branches in **every repository your GitHub account can access**, not only IMPACT. GitHub shows such actions as yours. This works until you delete the key on GitHub.
- The same applies to your **RStudio password**: colleagues using the account can read it from a running container. That is why you must choose a new password for RStudio.
- In **local** mode your key stays on your PC (it is mounted read-only into your own container, which is reachable only from your PC).

If that is not acceptable for you, use local mode, or talk to the maintainer.

**How to remove the key from GitHub** (for example when you stop working with the workstation, or if you think someone misused it):

1. In PowerShell, show your key's fingerprint:
   ```powershell
   ssh-keygen -lf $HOME\.ssh\id_ed25519_<username>.pub
   ```
   It prints something like `256 SHA256:AbCd... IMPACT_<username> (ED25519)`.
2. On github.com click your profile picture, then **Settings**, then **SSH and GPG keys**.
3. Find the key whose fingerprint (`SHA256:...`) matches, and click **Delete**.
4. If you suspect misuse, also look at **Settings, Security log** on GitHub and tell the maintainer.

After deleting the key on GitHub, the copy on the workstation is useless for GitHub. git pull/push from IMPACT and RStudio stops working until you add a key to GitHub again (the same public key, or a new one: delete both `id_ed25519_<username>` files on your PC and IMPACT creates a new pair at the next start; you then need the workstation password once more).

**How to delete the copy on the workstation** (optional; IMPACT copies it again the next time you use remote mode):

```powershell
ssh <workstation-ip> "rm -f ~/.ssh/id_ed25519_<username>"
```

---

## Options reference

| Option | Mode | Default | What it does |
|---|---|---|---|
| **Use Docker Volumes** | Local and remote | Off (ticked when you resume a container that uses volumes, or when volumes from an earlier session still exist) | Keeps `outputs` and `inputs/synthpop` in Docker volumes while the container runs. Your existing files are copied in at Start and the results are copied back at Stop. See [Docker volumes](#docker-volumes-how-results-get-back-to-your-folders). |
| **Rebuild image** | Local and remote | Off | Builds the image again even if it exists. Use after changes to the Dockerfile. The build starts from scratch (without Docker's build cache), so this takes a long time. |
| **High computational demand** | Remote only | Off | Adds `--cpus 32 -m 384g` (32 CPU cores, 384 GB RAM limit). Greyed out in local mode. |
| **Show password** | Both | Off | Shows the RStudio password in the info box. |
| **Port (8787-8799)** | Both | The next free port | The port RStudio is published on. Each running container needs its own port, so on the workstation colleagues use different ports. A red text below the box explains invalid values. When you click Start, IMPACT checks the port again; if it is taken, IMPACT enters a free one in the box. It checks once more right before the container starts. |
| **Custom Params** | Both | Empty | Extra `docker run` options for advanced users, for example `--shm-size 4g`. Values in quotes stay together: `-e "MY_VAR=a b"`. |
| **sim_design.yaml** | Both | Local: `.\inputs\sim_design_local.yaml`; remote: `.\inputs\sim_design.yaml` | The YAML file with `output_dir` and `synthpop_dir`. A relative path is relative to the repository folder. |

### The YAML file

IMPACT reads only two lines of the file: `output_dir:` and `synthpop_dir:`.

- **Local mode** needs Windows paths or paths relative to the repository: `output_dir: ./outputs` or `output_dir: C:\IMPACT\outputs`. That is why local mode uses `sim_design_local.yaml` by default.
- **Remote mode** uses Linux paths on the workstation, for example `/mnt/Storage_1/IMPACT_Storage/Base/outputs`, or relative ones. `~/...` means `/home/php-workstation/...`.
- Values may be in quotes (`"..."` or `'...'`). An empty value, `~` or `null` counts as "not set".
- Network folders (`\\server\...`, mapped network drives) do not work in local mode. IMPACT refuses them with **Network Folder Not Supported** before the image build.

---

## Docker volumes: how results get back to your folders

With **Use Docker Volumes** ticked, the container writes `outputs` and `inputs/synthpop` into two Docker volumes. This avoids permission problems with folders shared from the host.

- The volumes are named `impactncd_output_<container>` and `impactncd_synthpop_<container>`, for example `impactncd_output_IMPACTncd_Germany_jdoe`. Every repository and user has its own pair.
- **At Start**, your existing files are copied into new volumes. If that reports errors, **Volume copy problem** asks whether to start anyway.
- **At Stop**, the results are copied back to the folders from your YAML file with `rsync`. Each volume is deleted **only after its own copy succeeded**. If a copy fails (for example because the target folder is missing: it was renamed or moved, or it is on a drive that is not connected), or the target folders are unknown, that volume is kept and **Results still in Docker volumes** shows its name. The next Start offers to copy it.
- **Earlier results found** appears at Start when volumes from an earlier session still exist, for example after a crash, a reboot or a failed copy. It appears whether **Use Docker Volumes** is ticked or not; when the Container Manager opens, IMPACT already ticks the box and says so in the status line.
  - **Yes** (recommended): copy their contents into the folders shown, then start. Files on disk that are **newer** than the copy in the volume are kept (for example results of a later run without volumes); the other files get the volume's version.
  - **No**: delete them **without copying** (a second question asks you to confirm; default No).
  - **Cancel**: do nothing.

  After Yes or No the old volumes are removed. If **Use Docker Volumes** is not ticked, the container then starts without volumes.
- **Volume in use**: another container still uses the volume; stop it first.
- If you close IMPACT without stopping, the results stay in the volumes until you start IMPACT again and click **Stop Container**. The **Close without stopping?** question reminds you of this.

---

## Git: commit and push when you stop

After the container is stopped, IMPACT looks at the repository (on your PC in local mode, on the workstation in remote mode):

| Situation | What happens |
|---|---|
| Nothing changed and nothing waiting to be pushed | Nothing. |
| A merge, rebase, cherry-pick or revert is unfinished, or files have conflicts | **Git: unfinished merge** (or rebase, ...) lists the conflicted files and explains how to finish or cancel it in RStudio. Nothing is committed. |
| Files changed | The window **Git Changes Detected** opens (see below). |
| Files changed, but no branch is checked out (git calls this a "detached HEAD") | **Git: not on a branch**: nothing is committed, because such a commit would belong to no branch and would be easy to lose. Start the container again, click **New Branch** in the RStudio Git pane, then commit and push there. |
| No changed files, but commits that are not on GitHub yet (also on a branch that was never pushed) | **Unpushed commits** asks: "Push them to GitHub now?" |
| The changes could not be checked: Git for Windows is not installed on your PC (local mode), the workstation could not be reached, or git could not read the repository | Nothing is committed, and no git window opens. The status line says `Container stopped. Your changes were NOT checked or committed: ...` with the reason and what to do (usually: commit in the RStudio Git pane next time). If Git for Windows is missing, the console also warns about that when IMPACT starts. |

**The Git Changes Detected window**

- The list shows every changed file, one per row (scroll sideways for long paths). File names with umlauts are shown as they are. **All of these changes are committed** (`git add -A`): new, changed and deleted files. Check the list.
- Type a **commit message** (required).
- **Push to origin after commit** is ticked by default.
- **Commit** commits (and pushes); **Skip** commits nothing. If you also have earlier commits that are not on GitHub yet, IMPACT then asks whether to push those earlier commits only (your new changes stay uncommitted on disk).

**How the commit and push work**

- The commit is made as **your GitHub username** with the e-mail `<username>@users.noreply.github.com`, in local mode too, the same identity as commits made in RStudio.
- The push uses **only your IMPACT key** (`id_ed25519_<username>`). If your repository's `origin` is an `https://github.com/...` address, only this one push goes over SSH; the `origin` setting is not changed, so GitHub Desktop keeps working.
- A branch that is not on GitHub yet is pushed as a new branch with the same name, also when there are no new changes to commit.
- **Git commit failed** shows git's message; nothing was committed or pushed.
- **Git push failed** says clearly that the commit is saved but **not** on GitHub, with the likely reason, for example: your key is not added to GitHub, your account has no write access, the branch is protected, someone else pushed first (pull in RStudio, then push), GitHub could not be reached, or you are not on a branch.

---

## Troubleshooting

### Starting the tool

| Problem | What to do |
|---|---|
| **"PowerShell 7 was not found"** (in the black window) | Install PowerShell 7 as shown in the window or in [One-time setup](#one-time-setup-on-a-new-pc). Then double-click `IMPACT.bat` again; if the message stays, sign out of Windows and back in once. |
| **"Your PowerShell 7 is too old"** / **PowerShell update required** | Run `winget upgrade --id Microsoft.PowerShell --source winget`, or install the latest version from <https://aka.ms/powershell-release>. |
| **"IMPACT_Docker_GUI_v2.ps1 or IMPACT_Docker_GUI.psm1 was not found"** | `IMPACT.bat` was copied away from the IMPACT folder. Use the one in the IMPACT folder, or create a Desktop shortcut with `Create-Shortcut.bat`. |
| A window flashes and closes | Start `IMPACT.bat` from the IMPACT folder or with the Desktop shortcut. When IMPACT stops because of an error or crashes, the window stays open until you press a key. If the window still closes without a message, look at the end of the log file (see [Logs](#logs-and-diagnostics)). If your Desktop shortcut was made by an older IMPACT version, run `Create-Shortcut.bat` once to renew it. |
| **Docker missing** | For local mode install Docker Desktop. For remote-only use, the `docker.exe` command-line program on your PATH is enough. |
| **Install OpenSSH Client?** / **SSH missing** | Click Yes and accept the Windows permission prompt. Without admin rights, ask IT to install the Windows feature "OpenSSH Client". |
| **IMPACT encountered a fatal error** | Note the message, look at the log file named in the message (see [Logs](#logs-and-diagnostics)) and contact the maintainer. |
| **IMPACT - Unexpected error** | Something unexpected went wrong in a window. Try again; if it keeps happening, send the log file named in the message to the maintainer. |
| **SSH key problem** | Your IMPACT key has a passphrase, or could not be created or read. Follow the steps in the message, then start IMPACT again. |
| **Add your SSH key to GitHub** | GitHub does not accept your IMPACT key yet. Click **Open GitHub**, add the key (it is already copied), then click **Check again**. See [Step 3](#step-3-your-ssh-key). |
| **Copy failed** (in a key window) | The key could not be copied to the clipboard. Select the key text in the window and press Ctrl+C. |
| Console warning that ssh could not use the key file | The key file's permissions are too open. Run the `icacls` command from the warning, or rename both `id_ed25519_<username>` files and start IMPACT again (then add the new key to GitHub). |

### Username and password

| Problem | What to do |
|---|---|
| **Check your GitHub username** | The name was not found, is an e-mail address or an organisation. Use the name shown when you click your profile picture on github.com. |
| **Choose another RStudio password** | At least 8 characters, not your username, not a very common password. |
| **GitHub check not possible** | No connection to github.com, or an unexpected answer (proxy, firewall, Wi-Fi login page, offline, too many checks). Choose Yes only if you are sure the username is right. |

### Local mode and Docker Desktop

| Problem | What to do |
|---|---|
| **Network Folder Not Supported** | Clone the repository to a local folder such as `C:\Users\<you>\Repositories`. |
| **Not a Model Repository** | Select the folder that contains `docker_setup`. |
| **Docker Startup Issue** | Start Docker Desktop from the Start menu, wait until it shows that the engine is running, then click Yes and OK. |
| **Docker Access Denied** | Your account is not in the `docker-users` group. Ask IT to add it, then sign out and back in. |
| **Docker Not Reachable** | Docker Desktop stopped or is restarting. Wait until it runs and try again. |
| **Docker Not Available** / **Docker Check Failed** | IMPACT could not run the `docker` program on this PC. Install Docker Desktop, or start it and wait until it shows that the engine is running. Then choose **Local Container** again. |

### Remote mode and the workstation

| Problem | What to do |
|---|---|
| **Workstation not reachable** | Check the VPN/institute network, that the workstation is on and the IP address. |
| **Workstation identity changed** | Ask the admin whether the workstation was reinstalled. If yes, run the commands shown in the message: `ssh-keygen -R <ip>` in PowerShell and, if you logged in with the password before, `Remove-SSHTrustedHost -HostName <ip>` in **PowerShell 7** (Start menu: **PowerShell 7 (x64)**, or type `pwsh` in a Command Prompt window). Then start IMPACT again. |
| **Wrong password** | Check the workstation password (Caps Lock?). |
| **Password login not allowed** | The workstation does not accept passwords. Send your public key file `C:\Users\<you>\.ssh\id_ed25519_<username>.pub` to the admin and ask them to add it to the `php-workstation` account. Then start IMPACT again. |
| **Password bootstrap unavailable** | Posh-SSH could not be installed. Start IMPACT again and click Yes when it offers Posh-SSH; if the PowerShell Gallery is blocked, ask IT to install Posh-SSH or PuTTY 0.77 or newer. |
| **SSH key setup failed** | The key could not be installed or still does not work. The message shows details; contact the admin. |
| **SSH key copy failed** | Check the network or VPN and start IMPACT again. If it keeps happening, ask the admin whether the workstation's disk is full or `~/.ssh` is not writable. |
| **No repositories found** | Ask the admin to clone the repository into `/home/php-workstation/Schreibtisch/Repositories`. |
| **Unsupported Folder Name** / **Not a Model Repository** (remote) | Ask the admin to rename the folder (letters, digits, `-`, `_`), or choose the model repository (the folder that contains `docker_setup`). |
| **Docker Permission Denied (Remote)** | The admin must run `sudo usermod -aG docker php-workstation`. |
| **Docker Daemon Start Failed** | Docker on the workstation could not be started. Ask the admin to run `sudo systemctl start docker` on the workstation, then choose **Remote Container** again. |
| **SSH problem** (when clicking Start) | Follow the text: usually "check the VPN", or "close IMPACT and start it again" so the remote setup copies your key again. |
| **Docker not reachable** (when clicking Start, remote) | IMPACT could log in to the workstation, but Docker there did not answer. Check the network or VPN, wait a minute and click Start again. If it keeps failing, ask the admin to check that Docker runs on the workstation. |

### Starting a container

| Problem | What to do |
|---|---|
| **Invalid port** | Enter a number between 8787 and 8799 without a leading zero. |
| **Port conflict** | Another container uses that port. IMPACT has entered a free port in the Port box; click Start again. |
| **No free port** | All ports 8787-8799 are in use. Stop one of your containers, or ask a colleague to stop theirs. |
| "Port ... is already in use" (in **Container start failed**) | Choose another port between 8787 and 8799. |
| "Port ... is blocked or reserved by Windows" | Windows (Hyper-V/WSL) reserved it. Choose another port. |
| **Missing YAML** | Check the file name in the `sim_design.yaml` box. Local mode expects `inputs\sim_design_local.yaml`. |
| **Setting missing in YAML** / **Path error** / **Folder missing** / **Network Folder Not Supported** | See [The YAML file](#the-yaml-file). |
| **Docker not reachable** (when clicking Start, local) | Start Docker Desktop, wait until it says the engine is running, then click Start again. |
| **Already running** | Your container already runs (perhaps started from another window or PC). Click **Back** and continue again to connect to it. |
| **Image build failed** | Read the console output. **Yes** tries the fallback build (another 30 to 60 minutes), **No** stops. |
| **Build failed** | Read the console output. Common causes: no internet, Docker Hub download limit, disk full. Try again later or contact the maintainer. |
| **Volume check failed** / **Volume error** | Docker could not check, create, prepare or remove a Docker volume. Check that Docker runs (in remote mode also the network or VPN) and that the disk is not full, then click Start again. |
| **Copy failed** (at Start) | The results from an earlier session could not be copied out of the Docker volumes, so the container was not started. Nothing was deleted. Do the same as for **Results still in Docker volumes** below: recreate or reconnect the folder named in the message, then click Start and choose Yes in **Earlier results found**. |
| **Volume helper missing** | Docker could not download the small Alpine Linux image. Untick **Use Docker Volumes** or check the network. |
| **Container stopped** right after starting | Tick **Rebuild image** and start again; check the log. |
| **Container setup incomplete** | Stop and start the container again. If git still does not work in RStudio, check that your key is on GitHub. |
| A stopped container with the same name exists | Answer Yes in **Old Container Found**. Local mode: you can also remove it in Docker Desktop (Containers). Remote mode: ask the admin to run `docker rm <container name>` on the workstation (or run `docker --context remote-<ip> rm <container name>` in PowerShell on your PC). |
| **Remove Failed** | The old container could not be removed. Local mode: remove it in Docker Desktop (Containers), then click Start. Remote mode: ask the admin to run `docker rm <container name>` on the workstation, then click Start. |

### Stopping and git

| Problem | What to do |
|---|---|
| **Results still in Docker volumes** | Nothing is lost. If the message says that a folder does not exist, create it again (or reconnect its drive). Then click Start and choose Yes in **Earlier results found**, or ask the maintainer and quote the volume names. |
| **Stop failed** | Docker did not stop the container. Local mode: check that Docker Desktop runs. Remote mode: check the network or VPN. Then click Stop again. |
| **Git error** | The commit or push stopped with an unexpected error. Read the message and the log file. Your files stay in the repository folder; next time, check the Git pane in RStudio and commit or push what is left. |
| **Git push failed** | Your commit is saved but not on GitHub. Follow the hint in the message, then push from the Git pane in RStudio. |
| **Git: unfinished merge** | Start the container, resolve the conflicts in RStudio and commit there. |
| **Git: not on a branch** | Start the container, click **New Branch** in the RStudio Git pane, then commit and push there. |
| Status line: "Your changes were NOT checked or committed" | The reason follows in the same line. Without Git for Windows on your PC (local mode), commit in the RStudio Git pane or install Git for Windows. If the workstation could not be reached, your changes are still saved there; commit them in RStudio next time. |

### Windows and dialogs

| Problem | What to do |
|---|---|
| Dialogs open on the wrong monitor | Move the mouse to the monitor you want before the dialog opens; windows open on the monitor with the mouse pointer. |
| The window says "Not Responding" during a build or another long step | Normal: the build, the rest of Start, Stop (with copying results back from Docker volumes) and the git check run on the window's thread. Watch the console window; the window comes back when the step is done. If Windows asks whether to close IMPACT because it is not responding, choose **Wait**. Closing it stops IMPACT in the middle of that step. |

---

## Logs and diagnostics

IMPACT writes a log file:

```
C:\Users\<you>\.impact_gui\logs\impact.log
```

- It is created automatically. When it is larger than 512 KB at start, it is renamed to `impact.log.1` (replacing an older `impact.log.1`) and a new log starts.
- Levels: `Info`, `Warn`, `Error`, `Debug`.
- **All levels, including Debug, are always written to the file.** The console shows Debug lines only when **Enable Debug Mode** is ticked in Step 4. The RStudio password is not written to the log.
- Environment variables:

| Variable | Effect |
|---|---|
| `IMPACT_LOG_FILE` | Path of the log file (default: `C:\Users\<you>\.impact_gui\logs\impact.log`). |
| `IMPACT_LOG_DISABLE` | `1`, `true` or `yes` switches the log file off. |

When you report a problem, send the log file and the footer line of the Container Manager (Build / Commit / Built).

---

## Several users on the same workstation

- **Containers** are named `<repository>_<username>`, so colleagues never share a container.
- **Volumes** are named `impactncd_output_<repository>_<username>` and `impactncd_synthpop_<repository>_<username>`.
- **Ports**: every running container needs its own port from 8787 to 8799. IMPACT suggests the next free one, checks again when you click Start (and enters a free port if yours was taken) and once more right before starting. If all are taken, the status line says so and Start shows **No free port**.
- **Repository folders** in `/home/php-workstation/Schreibtisch/Repositories` are shared by everyone. If someone else's container uses the same folder, **Repository already in use** warns you. Agree with your colleagues who works where.
- **Session details** (container, repository, user, port, volume mode; no password) are stored in `/tmp/impactncd/<container>.json` on the workstation and removed at Stop. The container itself also carries this information, so you can reconnect after closing IMPACT. Files written by older IMPACT versions may still contain an RStudio password: whenever IMPACT writes or removes its own file, it blanks the password in those older files. The files themselves are kept, because colleagues who still use an older version need their port and volume mode.
- **Update together**: do not stop a running container with an older IMPACT version than the one that started it. Older versions use other names for the Docker volumes, so with **Use Docker Volumes** they do not copy your results back; the results stay in the volumes until the current version offers to copy them at the next Start (**Earlier results found**). Everyone should switch to a new IMPACT version at the same time (see [Known bugs](KNOWN_BUGS.md)).
- **Keys and passwords**: see [Your GitHub key on the shared workstation](#your-github-key-on-the-shared-workstation).

---

## Launcher and desktop shortcut

- **`IMPACT.bat`** starts the tool. It needs PowerShell 7.3 or newer and explains how to install it if it is missing. It never falls back to the old Windows PowerShell. When IMPACT stops because of an error or crashes, the window waits for a key press, so you can read the messages. When you cancel or close IMPACT normally, the window closes.
- **`Create-Shortcut.bat`** creates `IMPACT.lnk` on your Desktop with the IMPACT icon. The shortcut starts `IMPACT.bat` in the IMPACT folder, so keep the folder where it is (run `Create-Shortcut.bat` again if you move it).
- **Updating from an older IMPACT version:** run `Create-Shortcut.bat` once after updating, even if you already have an IMPACT shortcut. Older shortcuts start PowerShell directly, so they skip the checks in `IMPACT.bat`.
- **To give the tool to a colleague**, copy the whole `current_version` folder: `IMPACT.bat`, `Create-Shortcut.bat`, `IMPACT_Docker_GUI_v2.ps1`, `IMPACT_Docker_GUI.psm1`, `IMPACT_Docker_GUI.psd1` and `IMPACT_icon.ico`. The Dockerfiles (`docker_setup`) and the YAML files are part of the model repository, not of the tool.

---

## Remote workstation setup (for the admin)

The workstation uses **Docker Engine**, so containers can use all of the machine's memory.

### One-time setup

1. **Install Docker Engine** (see <https://docs.docker.com/engine/install/> for your distribution):
   ```bash
   sudo apt-get update
   sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin
   sudo systemctl enable docker
   ```
2. **Allow the shared account to use Docker:**
   ```bash
   sudo usermod -aG docker php-workstation
   ```
   The account must log out and back in. Note that Docker access on Linux is equivalent to root access.
3. **Check** as `php-workstation`:
   ```bash
   docker version
   docker run --rm hello-world
   ```
4. **Repositories**: clone each model repository into `/home/php-workstation/Schreibtisch/Repositories/<name>`. Simple folder names (letters, digits, `-`, `_`) are best. IMPACT turns other names into a Docker-safe name for the container and image; a name with nothing usable left is refused (**Unsupported Folder Name**).
5. **SSH**: the first login of each colleague uses the `php-workstation` password, so password login must be allowed for that account. Afterwards their keys are in `~/.ssh/authorized_keys` (comment `IMPACT_<username>`). If password login is switched off, colleagues see **Password login not allowed** and send you their public key file (`id_ed25519_<username>.pub`); add it to `~/.ssh/authorized_keys` of `php-workstation`.
6. **Ports 8787-8799** must be reachable from the colleagues' PCs.
7. Optional: `docker_setup/.env` in a repository may contain Docker registry credentials (for example `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`). When a remote build fails, IMPACT logs in with them and retries. The login is stored in the shared account's `~/.docker/config.json`.

### What IMPACT changes in the shared account

- `~/.ssh/authorized_keys`: one public key per colleague (replaced when that colleague's key changes).
- `~/.ssh/id_ed25519_<username>`: each colleague's **private** key (see [Your GitHub key on the shared workstation](#your-github-key-on-the-shared-workstation)).
- `~/.ssh/id_ed25519_<username>.pub`: each colleague's public key.
- Permissions: the home folder is made not writable by others (`chmod go-w`), `~/.ssh` is set to 700 and `~/.ssh/authorized_keys` to 600.
- `~/.ssh/known_hosts`: created if missing. The github.com entries are compared with GitHub's published key fingerprints; if none of them matches (for example only GitHub's old RSA key is stored), the github.com lines are replaced by freshly scanned keys that match those fingerprints. Other lines are never changed. If host-side pushes still fail with "REMOTE HOST IDENTIFICATION HAS CHANGED" for github.com, run `ssh-keygen -R github.com` once as `php-workstation` and tell the maintainer (GitHub may have changed its keys, and IMPACT then needs the new fingerprints).
- `/tmp/impactncd/*.json`: session details of running containers (no passwords). In files written by older IMPACT versions, IMPACT blanks the RStudio password but keeps the file.
- `~/.docker/config.json`: the registry login from `docker_setup/.env`, if a remote build needed one (see step 7).

---

## Glossary

| Term | Meaning |
|---|---|
| **Docker** | Runs programs in isolated *containers*, a bit like a light virtual machine. |
| **Docker Desktop** | Docker for Windows. Used for **local** containers. |
| **Docker Engine** | Docker on Linux. Used on the **workstation**. |
| **Image** | The blueprint of a container (Linux, R, RStudio Server, packages). Built from the Dockerfile in `docker_setup`. |
| **Container** | A running copy of the image: your RStudio Server. |
| **Bind mount** | A host folder that appears inside the container; changes are visible on both sides immediately. |
| **Docker volume** | A storage area managed by Docker. Used in volume mode for outputs and synthpop. |
| **SSH** | Secure remote login. Used for the workstation and for git with GitHub. |
| **SSH key** | A key pair: the private key stays secret, the public key goes to GitHub and the workstation. |
| **known_hosts** | A file with the host keys of servers you have connected to, so SSH can tell if a server suddenly changes. |
| **Docker context** | A named setting that tells Docker which engine to talk to (your PC or the workstation). IMPACT chooses it only for its own commands; it only switches an active `remote-...` context back to `default`. |
| **sim_design.yaml** | The model's settings file; IMPACT reads `output_dir` and `synthpop_dir` from it. |
| **rsync** | A file copy program; used to copy results out of the volumes. |
| **Posh-SSH** | A PowerShell module used for the first password login to the workstation. |
| **plink.exe** | PuTTY's command-line SSH program; a fallback when Posh-SSH is not available. |
| **Remote user** | The shared Linux account on the workstation: `php-workstation`. |
| **Container name** | `<repository>_<username>`, for example `IMPACTncd_Germany_jdoe`. |

---

*IMPACT NCD Germany Docker GUI v2.0.0*
