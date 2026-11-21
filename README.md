# IMPACT Docker GUI

A Windows tool for building, starting and stopping **IMPACT NCD Germany** RStudio Server containers, either locally with Docker Desktop or on the shared Linux workstation over SSH.

## What it does

- Creates a personal SSH key for GitHub and for logging in to the workstation
- Builds the Docker image from the model repository's `docker_setup` folder and starts an RStudio Server container
- Works **locally** (Docker Desktop, RStudio reachable only from your PC) or **remotely** (Docker Engine on the workstation, account `php-workstation`)
- Mounts the repository into the container, so you edit the real files in RStudio in your browser
- Optional Docker volumes for outputs and synthpop, copied back to your folders when you stop (volumes are deleted only after a successful copy)
- When you stop, offers to commit and push your changes with your own GitHub identity and key

## Quick start

1. Install **PowerShell 7.3 or newer** once: `winget install --id Microsoft.PowerShell --source winget` (or the `.msi` from <https://aka.ms/powershell-release>).
2. Double-click `current_version\IMPACT.bat` (or create a Desktop shortcut with `Create-Shortcut.bat`). **Updating from an older version?** Run `Create-Shortcut.bat` once, because older shortcuts start PowerShell directly and skip the checks in `IMPACT.bat`.
3. Enter your **GitHub username** and choose a **new RStudio password** (at least 8 characters, **not** your GitHub password).
4. If a new SSH key was created, add the public key to GitHub (Settings, SSH and GPG keys).
5. Choose **Local** or **Remote** and select your repository.
6. Click **Start Container**, open the URL shown, log in as `rstudio`.
7. Click **Stop Container** when you are done (it asks for confirmation).

> **Remote mode:** your private GitHub SSH key (no passphrase) is copied into the shared workstation account, where everyone using that account can read it. Read [Your GitHub key on the shared workstation](documentation/IMPACT_Docker_GUI_v2_User.md#your-github-key-on-the-shared-workstation) before using remote mode.

## Requirements

- **Windows 10 or 11** with **PowerShell 7.3+** (`pwsh`). It is not part of Windows; `IMPACT.bat` explains how to install it if it is missing and does not fall back to Windows PowerShell 5.1. If the GUI script is started from Windows PowerShell, it restarts itself in PowerShell 7.
- **Docker Desktop** for local mode. For remote-only use, the `docker` command-line program on PATH is enough.
- **OpenSSH client** (`ssh`, `ssh-keygen`); the tool offers to install it if it is missing.
- **Network access to the workstation** (institute network or VPN) for remote mode.
- Optional: **Git for Windows** (commit/push offer in local mode), **Posh-SSH** (first password login to the workstation; the tool offers to install it).

## Repository structure

| Path | Contents |
|---|---|
| `current_version/` | The tool: `IMPACT.bat` (launcher), `Create-Shortcut.bat`, `IMPACT_Docker_GUI_v2.ps1` (GUI and workflow), `IMPACT_Docker_GUI.psm1` (module with the core functions), `IMPACT_Docker_GUI.psd1` (manifest), `IMPACT_icon.ico` |
| `tests/` | Pester 5 suites (Unit, Integration, DockerSsh, ImageValidation, RemoteE2E, Preflight), the test runner `Invoke-Tests.ps1`, helpers and test container Dockerfiles |
| `documentation/` | User guide, technical documentation, testing guide, known bugs |
| `.github/workflows/test.yml` | GitHub Actions CI |
| `.gitattributes` | Keeps the `.bat` files with Windows (CRLF) line endings |

## Documentation

- **[User Guide](documentation/IMPACT_Docker_GUI_v2_User.md)**: step-by-step instructions, every dialog and message, options, troubleshooting
- **[Technical Documentation](documentation/IMPACT_Docker_GUI_v2_Tech.md)**: architecture, session state, functions, workflow internals, security
- **[Testing Guide](documentation/TESTING.md)**: test suites, running tests, CI
- **[Known Bugs](documentation/KNOWN_BUGS.md)**: known problems and design limitations

## Testing

```powershell
# Unit + Integration (default)
pwsh tests/Invoke-Tests.ps1

# One suite
pwsh tests/Invoke-Tests.ps1 -Tag Unit
pwsh tests/Invoke-Tests.ps1 -Tag DockerSsh

# Cumulative: Unit -> Integration -> ... -> the given level
pwsh tests/Invoke-Tests.ps1 -Level All
pwsh tests/Invoke-Tests.ps1 -Level RemoteE2E -GitHubToken ghp_xxx
```

Exit code 0 = everything requested ran and passed, 1 = failures, 2 = some suites could not run (for example Docker is not running; add `-AllowSkip` to accept that). See the **[Testing Guide](documentation/TESTING.md)**.

## License

Internal tool under the MIT License.
