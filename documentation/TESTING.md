# Testing Guide — IMPACT Docker GUI

This document explains the testing architecture, how to run tests locally, and how CI works.

> **Key design constraint:** The IMPACT Docker GUI script runs **only on Windows** (WinForms UI, Docker Desktop contexts). The Docker images it manages are **Linux containers**. Tests are split accordingly: Unit & Integration run on Windows, while Docker-dependent tests run on Ubuntu (Linux) with PowerShell (`pwsh`).

---

## Architecture

The codebase is split into two layers to enable headless testing:

| File | Purpose |
|---|---|
| `current_version/IMPACT_Docker_GUI.psm1` | PowerShell module — all core functions (logic, SSH, Docker, UI helpers). Importable by both the launcher and by tests. |
| `current_version/IMPACT_Docker_GUI.psd1` | Module manifest (metadata, version, exports). |
| `current_version/IMPACT_Docker_GUI_v2.ps1` | Thin launcher — imports the module, runs the top-level orchestration flow with WinForms UI. |

### NonInteractive Mode

The module exposes a `$script:NonInteractive` flag controlled by:

```powershell
Enable-NonInteractiveMode    # sets flag to $true
Disable-NonInteractiveMode   # sets flag to $false
Test-NonInteractiveMode      # returns current value
```

When enabled, every dialog function (e.g. `Show-CredentialDialog`, `Select-Location`, `Ensure-GitKeySetup`) reads its inputs from the `$State` hashtable instead of showing WinForms dialogs, making the script fully automatable.

---

## Test Framework

We use **[Pester 5](https://pester.dev/)** (PowerShell-native, xUnit-style).

### Install Pester

```powershell
Install-Module Pester -Force -Scope CurrentUser -MinimumVersion 5.0.0 -SkipPublisherCheck
```

---

## Test Suites

There are five test suites arranged in cumulative levels:

| Level | File | Tag | Tests | What it covers | CI Runner | External deps |
|---|---|---|---|---|---|---|
| 1 | `tests/Unit.Tests.ps1` | `Unit` | 65 | Pure-logic functions: path conversion, `New-SessionState`, `Get-RemoteHostString`, `Get-DockerContextArgs`, `Get-YamlPathValue`, `Build-DockerRunCommand`, SSH config, theme palette, NonInteractive mode | **Windows** | None |
| 2 | `tests/Integration.Tests.ps1` | `Integration` | 25 | Mocked multi-function flows: credential dialogs, Docker daemon checks, SSH agent, logging, GitHub API key management, remote container flow (YAML → path → `docker run`) | **Windows** | None (all mocked) |
| 3 | `tests/DockerSsh.Tests.ps1` | `DockerSsh` | 6 | Live SSH connectivity against SSHD container: remote command execution, metadata read/write, directory creation | **Ubuntu** | Docker, SSHD container |
| 4 | `tests/ImageValidation.Tests.ps1` | `ImageValidation` | ~14 | Docker image validation: build IMPACT image, start container, check RStudio, R environment, `global.R`, Git/SSH config, GitHub SSH auth | **Ubuntu** | Docker, Internet |
| 5 | `tests/RemoteE2E.Tests.ps1` | `RemoteE2E` | ~11 | Full SSH→Docker flow: SSH into workstation container → clone repo → build image → start IMPACT container → validate RStudio + `global.R` + `git pull` through SSH tunnel | **Ubuntu** | Docker, Internet, DooD socket |

### LOCAL vs REMOTE coverage

The GUI supports two modes:

- **LOCAL** — Docker runs on the user's own machine; the repo and storage directories are local.
- **REMOTE** — Docker runs on a remote workstation (e.g. `10.152.14.124`) via an SSH-based Docker context; paths like `/mnt/Storage_1/…` live on that machine.

| Test layer | LOCAL | REMOTE |
|---|---|---|
| Unit | Yes — relative-path YAML, local `Build-DockerRunCommand` | Yes — absolute-path YAML, `Get-RemoteHostString`, `Get-DockerContextArgs`, remote `Build-DockerRunCommand` |
| Integration | Yes — local credential flow, Docker daemon checks | Yes — full mocked remote flow (YAML → path → `docker run` with SSH context args) |
| DockerSsh | — | Yes — live SSH commands against SSHD container with remote-like directory layout |
| ImageValidation | **Yes** — validates the Docker image independently (RStudio, R packages, `global.R`, Git/SSH) | — |
| RemoteE2E | — | **Yes** — full SSH→Docker lifecycle via DooD workstation container |

### Docker-out-of-Docker (DooD) Pattern

The RemoteE2E tests use the **DooD** pattern to simulate a real workstation with Docker capabilities:

```
┌─── CI Host (Ubuntu runner) ──────────────────────────────────────────┐
│  Docker daemon (host)                                                 │
│  ┌─── workstation-test container ──────────────────────────────────┐  │
│  │  Ubuntu 22.04 + SSHD + Docker CLI (no daemon)                   │  │
│  │  /var/run/docker.sock → mounted from host (DooD)                │  │
│  │  SSH on port 22 → mapped to host:2223                           │  │
│  │                                                                  │  │
│  │  testuser runs: docker build / docker run                       │  │
│  │   └── talks to HOST daemon via mounted socket                   │  │
│  │       └── creates SIBLING containers on the host                │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│  ┌─── impact-e2e container (sibling) ──────────────────────────────┐  │
│  │  RStudio Server on port 18787                                    │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────────┘
```

Key properties:
- **No nested Docker daemon** — the workstation container has only the Docker CLI, not a daemon.
- **No `--privileged`** — only the socket mount is needed (`-v /var/run/docker.sock:/var/run/docker.sock`).
- **Sibling containers** — containers created from inside workstation-test appear as peers on the host.
- **GID matching** — the entrypoint script detects the socket's GID and adjusts the `docker` group inside the container to match.

---

## Running Tests Locally

### Unified test runner

The recommended way to run tests is through `Run-AllTests.ps1`:

| Command | What runs | Time |
|---|---|---|
| `pwsh Run-AllTests.ps1` | Unit + Integration (default) | ~10 s |
| `pwsh Run-AllTests.ps1 -Level DockerSsh` | + DockerSsh | ~30 s |
| `pwsh Run-AllTests.ps1 -Level ImageValidation` | + ImageValidation | ~15–25 min |
| `pwsh Run-AllTests.ps1 -Level RemoteE2E` | + RemoteE2E (full E2E) | ~20–40 min |
| `pwsh Run-AllTests.ps1 -Level All` | Everything | ~30–50 min |
| `pwsh Run-AllTests.ps1 -Level RemoteE2E -GitHubToken ghp_xxx` | Full with SSH auth tests | ~30–50 min |

The runner automatically:
- Builds/starts required containers (SSHD, Workstation)
- Generates SSH keys and configures connectivity
- Sets up all environment variables
- Runs suites in order with cumulative pass/fail tracking
- Cleans up containers when done

### Direct Pester invocation

```powershell
Import-Module Pester -MinimumVersion 5.0.0
Invoke-Pester ./tests/Unit.Tests.ps1 -Output Detailed
Invoke-Pester ./tests/Integration.Tests.ps1 -Output Detailed
```

### Running DockerSsh tests manually

If you prefer manual setup:

1. Build and start the SSHD container:

   ```bash
   docker build -t impact-sshd-test -f tests/Helpers/SshdContainer.Dockerfile .
   ssh-keygen -t ed25519 -f /tmp/id_test -N "" -q
   docker run -d -p 2222:22 --name sshd-test impact-sshd-test
   docker cp /tmp/id_test.pub sshd-test:/home/testuser/.ssh/authorized_keys
   docker exec sshd-test chown testuser:testuser /home/testuser/.ssh/authorized_keys
   docker exec sshd-test chmod 600 /home/testuser/.ssh/authorized_keys
   ```

2. Run:

   ```powershell
   $env:IMPACT_TEST_SSH_HOST = 'localhost'
   $env:IMPACT_TEST_SSH_PORT = '2222'
   $env:IMPACT_TEST_SSH_USER = 'testuser'
   $env:IMPACT_TEST_SSH_KEY  = '/tmp/id_test'
   Invoke-Pester ./tests/DockerSsh.Tests.ps1 -Output Detailed
   ```

3. Cleanup: `docker stop sshd-test && docker rm sshd-test`

### Running RemoteE2E tests manually

1. Build and start the workstation container with DooD:

   ```bash
   docker build -t impact-workstation-test -f tests/Helpers/WorkstationContainer.Dockerfile .
   ssh-keygen -t ed25519 -f /tmp/id_ws_test -N "" -q
   docker run -d -p 2223:22 -v /var/run/docker.sock:/var/run/docker.sock --name workstation-test impact-workstation-test
   docker cp /tmp/id_ws_test.pub workstation-test:/home/testuser/.ssh/authorized_keys
   docker exec workstation-test chown testuser:testuser /home/testuser/.ssh/authorized_keys
   docker exec workstation-test chmod 600 /home/testuser/.ssh/authorized_keys
   ```

2. Verify DooD works:

   ```bash
   ssh -p 2223 -i /tmp/id_ws_test -o StrictHostKeyChecking=no testuser@localhost "docker info --format '{{.ServerVersion}}'"
   ```

3. Run:

   ```powershell
   $env:IMPACT_REMOTE_E2E_SSH_HOST = 'localhost'
   $env:IMPACT_REMOTE_E2E_SSH_PORT = '2223'
   $env:IMPACT_REMOTE_E2E_SSH_USER = 'testuser'
   $env:IMPACT_REMOTE_E2E_SSH_KEY  = '/tmp/id_ws_test'
   # Optional: $env:IMPACT_E2E_GITHUB_TOKEN = 'ghp_...'
   Invoke-Pester ./tests/RemoteE2E.Tests.ps1 -Output Detailed
   ```

4. Cleanup: `docker stop workstation-test && docker rm workstation-test`

---

## Environment Variables

| Variable | Used by | Required | Purpose |
|---|---|---|---|
| `IMPACT_TEST_SSH_HOST` | DockerSsh | Yes | SSH host for SSHD container (typically `localhost`) |
| `IMPACT_TEST_SSH_PORT` | DockerSsh | Yes | SSH port (typically `2222`) |
| `IMPACT_TEST_SSH_USER` | DockerSsh | Yes | SSH username (typically `testuser`) |
| `IMPACT_TEST_SSH_KEY` | DockerSsh | Yes | Path to SSH private key |
| `IMPACT_REMOTE_E2E_SSH_HOST` | RemoteE2E | Yes | SSH host for workstation container |
| `IMPACT_REMOTE_E2E_SSH_PORT` | RemoteE2E | Yes | SSH port (typically `2223`) |
| `IMPACT_REMOTE_E2E_SSH_USER` | RemoteE2E | Yes | SSH username (typically `testuser`) |
| `IMPACT_REMOTE_E2E_SSH_KEY` | RemoteE2E | Yes | Path to SSH private key |
| `IMPACT_E2E_GITHUB_TOKEN` | ImageValidation, RemoteE2E | No | Fine-grained PAT with SSH keys Read/Write. Enables Git SSH auth + pull tests. If absent, those tests are skipped. |
| `IMPACT_E2E_SKIP_BUILD` | ImageValidation, RemoteE2E | No | Set to `1` to skip Docker image build and reuse existing images. |
| `IMPACT_E2E_KEEP_ARTIFACTS` | ImageValidation, RemoteE2E | No | Set to `1` to keep cloned repos + Docker images after tests. |

---

## Typical Workflow After Making Changes

1. **Edit** the module (`IMPACT_Docker_GUI.psm1`) or the launcher (`.ps1`).
2. **Run unit tests** (~5 s):

   ```powershell
   pwsh Run-AllTests.ps1 -Level Unit
   ```

3. **Run unit + integration** (~10 s) if integration-level logic changed:

   ```powershell
   pwsh Run-AllTests.ps1
   ```

4. **Run up to DockerSsh** (~30 s) if SSH/remote logic changed:

   ```powershell
   pwsh Run-AllTests.ps1 -Level DockerSsh
   ```

5. **Run full E2E** (~30 min) if container lifecycle, image build, or `global.R` logic changed:

   ```powershell
   pwsh Run-AllTests.ps1 -Level RemoteE2E -GitHubToken ghp_xxx
   ```

6. **Push** — CI runs Unit + Integration + DockerSsh on every push. ImageValidation + RemoteE2E run on weekly schedule or manual dispatch.

---

## CI — GitHub Actions

The workflow file lives at `.github/workflows/test.yml`.

**Triggers:**
- **Push** to `main` or `develop` → Unit (Windows) + Integration (Windows) + DockerSsh (Ubuntu)
- **Pull request** → Same as push
- **Manual dispatch** (`workflow_dispatch`) with `run_e2e` checkbox → all jobs including ImageValidation + RemoteE2E
- **Weekly schedule** (Sunday 03:00 UTC) → all jobs including ImageValidation + RemoteE2E

### Why Windows + Ubuntu?

| Runner | Why |
|---|---|
| **Windows** for Unit & Integration | The script only runs on Windows (WinForms). These tests validate the script's own logic on its target platform. No Docker needed (everything mocked). |
| **Ubuntu** for DockerSsh, ImageValidation, RemoteE2E | The Docker images are Linux containers. GitHub's `windows-latest` runners only support Windows containers (no Docker Desktop / WSL2). Linux container tests must run on Ubuntu. |

### Jobs

| Job | Runner | Trigger | What it does |
|---|---|---|---|
| `unit-tests` | `windows-latest` | push, PR | Installs Pester, runs `Unit` tag (65 tests) |
| `integration-tests` | `windows-latest` | push, PR | Runs `Integration` tag (25 tests, all mocked). Needs unit-tests. |
| `docker-ssh-tests` | `ubuntu-latest` | push, PR | Builds SSHD container, generates SSH key, runs `DockerSsh` tag (6 tests). Needs unit-tests. |
| `image-validation` | `ubuntu-latest` | dispatch, schedule | Builds IMPACT Docker image, starts container, validates RStudio + R + Git config (~14 tests). 45 min timeout. Needs docker-ssh-tests. |
| `remote-e2e` | `ubuntu-latest` | dispatch, schedule | Full DooD: builds workstation, SSH in, clone repo, build image, start container, validate via SSH tunnel (~11 tests). 60 min timeout. Needs docker-ssh-tests. |

### Adding the GitHub token (optional)

To enable SSH authentication + `git pull` tests in CI:

1. Create a **fine-grained Personal Access Token** on GitHub with **SSH keys: Read and Write** permission.
2. Add it as a repository secret named `IMPACT_E2E_GITHUB_TOKEN`.
3. ImageValidation and RemoteE2E jobs automatically pick it up. Without it, the relevant tests are skipped (not failed).

---

## Test Helpers

| File | Contents |
|---|---|
| `tests/Helpers/TestSessionState.ps1` | `New-TestSessionState` — creates a pre-populated `$State` hashtable for testing (supports `-Location 'LOCAL'` and `-Location 'REMOTE@<ip>'`); `New-DummySshKeyPair` — generates a throwaway ed25519 key pair; `Remove-TestArtifacts` — cleans up temp files |
| `tests/Helpers/SshdContainer.Dockerfile` | Ubuntu 22.04 SSHD image with `testuser` and a fake `IMPACTncd_Germany` git repo (directory layout mirrors the real remote workstation). Used by DockerSsh tests. |
| `tests/Helpers/WorkstationContainer.Dockerfile` | Extends SSHD container with Docker CE CLI (no daemon). Supports DooD via socket mount. Used by RemoteE2E tests. |
| `tests/Helpers/workstation-entrypoint.sh` | Entrypoint script for WorkstationContainer — detects mounted Docker socket GID, adjusts `docker` group to match, starts SSHD. |
| `tests/.pesterconfig.psd1` | Default Pester 5 configuration |
| `tests/Invoke-Tests.ps1` | Convenience test runner with `-Tag`, `-ExcludeTag`, `-CodeCoverage` switches |
| `Run-AllTests.ps1` | Unified runner — handles container lifecycle, SSH keys, env vars, cumulative suite execution, cleanup, and summary |

---

## Writing New Tests

1. Add tests to the appropriate `.Tests.ps1` file (or create a new one).
2. Tag every `Describe` block with `Unit`, `Integration`, `DockerSsh`, `ImageValidation`, or `RemoteE2E`.
3. Import the module in `BeforeAll`:

   ```powershell
   BeforeAll {
       Import-Module (Join-Path $PSScriptRoot '..' 'current_version' 'IMPACT_Docker_GUI.psm1') -Force
   }
   ```

4. **Pester 5 scoping rule**: All constants and variables must be defined **inside `BeforeAll`** within the `Describe` block. Do NOT define `$script:` variables between `BeforeDiscovery` and `Describe` — they will be empty at runtime due to Pester 5's discovery/run phase separation.
5. Use `Mock -ModuleName IMPACT_Docker_GUI` when mocking functions called inside the module.
6. Use `New-TestSessionState` from the helper for a ready-made state object.
7. For REMOTE-specific tests, use `New-TestSessionState -Location 'REMOTE@<ip>'` and mock SSH calls.
