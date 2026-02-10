# 🐳 IMPACT Docker GUI

A Windows GUI tool for building, launching, and managing **IMPACT NCD Germany** RStudio Server containers — locally via Docker Desktop or remotely on a shared workstation over SSH.

## What It Does

- Generates and manages per-user SSH keys for GitHub and remote access
- Builds Docker images from the project's `Dockerfile` and starts RStudio Server containers
- Supports **local** (Docker Desktop) and **remote** (SSH-based) container orchestration
- Mounts project files into the container so you can work in RStudio through your browser
- Optionally uses Docker volumes with automatic data sync on stop
- Detects Git changes on container stop and offers a commit/push dialog

## Quick Start

1. Run `IMPACT_Docker_GUI_v2.ps1` (or the compiled `IMPACT.exe`)
2. Enter a username and password
3. Add the generated SSH public key to GitHub if needed
4. Choose **Local** or **Remote** and select your repository
5. Click **Start Container** → open the displayed URL → log in as `rstudio`
6. Click **Stop Container** when done

## Requirements

- **Windows 10+** with **PowerShell 7** (auto-detected and relaunched)
- **Docker Desktop** (local mode) or SSH access to the remote workstation
- **OpenSSH client** (`ssh`, `ssh-keygen`) on PATH

## Repository Structure

| Directory | Contents |
|---|---|
| `current_major_version/` | Active release — main script (`IMPACT_Docker_GUI_v2.ps1`), compile scripts (`Compile-IMPACT-v2.ps1`, `.bat`), quick-compile batch, and application icon |
| `documentation/` | User Guide and Technical Documentation (Markdown) |
| `_old/` | Previous version (v1) of the tool, legacy compile scripts, flow diagrams, and helper utilities — kept for reference |

## Documentation

- **[User Guide](documentation/IMPACT_Docker_GUI_v2_User.md)** — step-by-step instructions, options reference, troubleshooting, and glossary
- **[Technical Documentation](documentation/IMPACT_Docker_GUI_v2_Tech.md)** — architecture, data model, function reference, workflow internals, and extension points

## Building the EXE

```powershell
# Interactive (prompts before overwriting)
.\current_major_version\Compile-IMPACT-v2.bat

# Or manually with PowerShell 7
pwsh .\current_major_version\Compile-IMPACT-v2.ps1 -Force
```

Requires the `ps2exe` module (auto-installed if missing). Outputs `IMPACT.exe` in `current_major_version/`.

## License

Internal tool — IMPACT NCD Germany.
