# Testing Guide — IMPACT Docker GUI

This document explains the testing architecture, how to run tests locally, and how CI works.

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

There are four test suites, each targeting a different level of the stack:

| File | Tag | Tests | What it covers | LOCAL / REMOTE | External deps |
|---|---|---|---|---|---|
| `tests/Unit.Tests.ps1` | `Unit` | 65 | Pure-logic functions: path conversion, `New-SessionState` defaults, `Get-RemoteHostString`, `Get-DockerContextArgs`, `Get-YamlPathValue`, `Build-DockerRunCommand`, SSH config, theme palette, NonInteractive mode | **Both** — tests LOCAL relative-path resolution *and* REMOTE absolute-path resolution (`/mnt/Storage_1/…`), Docker context args for SSH hosts | None |
| `tests/Integration.Tests.ps1` | `Integration` | 25 | Mocked multi-function flows: credential dialogs in NonInteractive mode, Docker daemon checks, SSH agent, logging, GitHub API add/remove key, remote container flow (YAML → path resolution → `docker run` command) | **Both** — includes a dedicated `Remote container flow` test group that mocks SSH calls and verifies the full REMOTE command with real workstation paths (`10.152.14.124`, `/mnt/Storage_1/…`) | None (all mocked) |
| `tests/DockerSsh.Tests.ps1` | `DockerSsh` | ~8 | Live SSH connectivity against an SSHD container: remote command execution, metadata read/write, directory creation | **REMOTE simulation** — the SSHD container mimics a remote workstation directory layout | Running SSHD container |
| `tests/E2E.Tests.ps1` | `E2E` | 16 | Full container lifecycle with the real IMPACT-NCD-Germany_Base repo: clone, image build, container start, RStudio Server, `global.R`, Git/SSH config, GitHub SSH auth | **LOCAL only** — runs Docker on the local daemon; does not exercise the SSH-based remote Docker context | Docker, Internet; optional `IMPACT_E2E_GITHUB_TOKEN` for SSH auth tests |

### LOCAL vs REMOTE coverage summary

The GUI supports two modes:

- **LOCAL** — Docker runs on the user's own machine; the repo and storage directories are local.
- **REMOTE** — Docker runs on a remote workstation (e.g. `10.152.14.124`) via an SSH-based Docker context; paths like `/mnt/Storage_1/…` live on that machine.

| Test layer | LOCAL | REMOTE |
|---|---|---|
| Unit tests | Yes — relative-path YAML resolution, local `Build-DockerRunCommand` | Yes — absolute-path YAML resolution, `Get-RemoteHostString`, `Get-DockerContextArgs`, remote `Build-DockerRunCommand` |
| Integration tests | Yes — local credential flow, Docker daemon checks | Yes — full mocked remote flow (YAML → path → `docker run` with SSH context args) |
| DockerSsh tests | — | Yes — live SSH commands against SSHD container with remote-like directory layout |
| E2E tests | **Yes — full real container lifecycle** | **No** — would require the actual remote workstation or a comparable SSH-accessible host |

> **Why no REMOTE E2E?** A true remote E2E test would require a real (or simulated) workstation reachable via SSH with Docker installed, the repository already cloned, and storage mounts at `/mnt/Storage_1/…`. This is impractical in automated CI. Instead, the REMOTE path is validated through mocked integration tests and the live DockerSsh tests, which together cover the SSH connectivity, path resolution, and command construction.

---

## Running Tests Locally

### Quick reference

| Command | What runs | Time |
|---|---|---|
| `pwsh tests/Invoke-Tests.ps1 -Tag Unit` | 65 unit tests | ~5 s |
| `pwsh tests/Invoke-Tests.ps1` | 65 unit + 25 integration (default) | ~10 s |
| `pwsh tests/Invoke-Tests.ps1 -Tag E2E` | 16 E2E tests (LOCAL container lifecycle) | ~15–25 min (first build) |

### All tests (unit + integration)

```powershell
cd <repo-root>
pwsh tests/Invoke-Tests.ps1
```

### By tag

```powershell
pwsh tests/Invoke-Tests.ps1 -Tag Unit
pwsh tests/Invoke-Tests.ps1 -Tag Integration
```

### Direct Pester invocation

```powershell
Import-Module Pester -MinimumVersion 5.0.0
Invoke-Pester ./tests/Unit.Tests.ps1 -Output Detailed
Invoke-Pester ./tests/Integration.Tests.ps1 -Output Detailed
```

### Running Docker SSH tests locally

These tests spin up an SSHD container that simulates a remote workstation, then connect to it via SSH — the closest automated approximation of the REMOTE flow.

1. Build the SSHD test container:

   ```bash
   docker build -t impact-sshd-test -f tests/Helpers/SshdContainer.Dockerfile .
   ```

2. Generate a throwaway key pair and start the container:

   ```bash
   ssh-keygen -t ed25519 -f /tmp/id_test -N "" -q
   docker run -d -p 2222:22 --name sshd-test impact-sshd-test
   docker cp /tmp/id_test.pub sshd-test:/home/testuser/.ssh/authorized_keys
   docker exec sshd-test chown testuser:testuser /home/testuser/.ssh/authorized_keys
   docker exec sshd-test chmod 600 /home/testuser/.ssh/authorized_keys
   ```

3. Run the tests:

   ```powershell
   $env:IMPACT_TEST_SSH_HOST = 'localhost'
   $env:IMPACT_TEST_SSH_PORT = '2222'
   $env:IMPACT_TEST_SSH_USER = 'testuser'
   $env:IMPACT_TEST_SSH_KEY  = '/tmp/id_test'
   Invoke-Pester ./tests/DockerSsh.Tests.ps1 -Output Detailed
   ```

4. Cleanup:

   ```bash
   docker stop sshd-test && docker rm sshd-test
   ```

### Running E2E tests locally

The E2E suite tests the **LOCAL container flow** end-to-end. It clones the real [IMPACT-NCD-Germany_Base](https://github.com/IMPACT-NCD-Modeling-Germany/IMPACT-NCD-Germany_Base) repository, builds the Docker image from the repo's `Dockerfile.IMPACTncdGER` (~10–20 min first time), starts a container with the same arguments the GUI would use, and validates:

- RStudio Server is accessible on port 18787
- Repository is bind-mounted correctly inside the container
- Output and synthpop directories are mounted and writable
- R environment works (correct R version, `IMPACTncdGer` and `CKutils` packages installed)
- `global.R` can be sourced without errors
- Git is configured to use SSH for github.com
- SSH key is placed with correct permissions (mode 600)
- `known_hosts` contains github.com
- `GIT_SSH_COMMAND` environment variable is set correctly
- GitHub SSH authentication works from inside the container (requires token)
- `git pull` succeeds inside the container (requires token)

```powershell
# Basic E2E run (skips the 2 SSH auth tests)
pwsh tests/Invoke-Tests.ps1 -Tag E2E

# With GitHub SSH auth test (needs a PAT with admin:public_key scope)
$env:IMPACT_E2E_GITHUB_TOKEN = 'ghp_...'
pwsh tests/Invoke-Tests.ps1 -Tag E2E

# Skip image build (reuse from previous run — saves ~15 min)
$env:IMPACT_E2E_SKIP_BUILD = '1'
pwsh tests/Invoke-Tests.ps1 -Tag E2E

# Keep artifacts after test (cloned repo + Docker image, useful for debugging)
$env:IMPACT_E2E_KEEP_ARTIFACTS = '1'
pwsh tests/Invoke-Tests.ps1 -Tag E2E
```

**Environment variables:**

| Variable | Required | Purpose |
|---|---|---|
| `IMPACT_E2E_GITHUB_TOKEN` | No | PAT with `admin:public_key` scope. Enables the 2 SSH auth + `git pull` tests inside the container. If absent, those tests are skipped. |
| `IMPACT_E2E_SKIP_BUILD` | No | Set to `1` to skip the Docker image build and reuse an existing `impactncd_germany_e2e_test` image. Saves ~15 min on repeat runs. |
| `IMPACT_E2E_KEEP_ARTIFACTS` | No | Set to `1` to keep the cloned repo and Docker image after tests complete instead of cleaning them up. |

---

## Typical Workflow After Making Changes

1. **Edit** the module (`IMPACT_Docker_GUI.psm1`) or the launcher (`.ps1`).
2. **Run unit tests** to catch regressions quickly:

   ```powershell
   pwsh tests/Invoke-Tests.ps1 -Tag Unit
   ```

3. **Run all quick tests** (unit + integration) if any integration-level logic was touched:

   ```powershell
   pwsh tests/Invoke-Tests.ps1
   ```

4. **Run E2E** if Docker command building, container startup, or SSH key logic changed:

   ```powershell
   pwsh tests/Invoke-Tests.ps1 -Tag E2E
   ```

5. **Push** — CI will automatically run unit + integration on every push and E2E on weekly schedule / manual dispatch.

---

## CI — GitHub Actions

The workflow file lives at `.github/workflows/test.yml`.

**Triggers:**
- **Push** to `main` or `develop` → unit + integration + DockerSsh jobs
- **Pull request** → unit + integration + DockerSsh jobs
- **Manual dispatch** (`workflow_dispatch`) → all jobs including E2E
- **Weekly schedule** (Sunday 03:00 UTC) → all jobs including E2E

### Jobs

| Job | Runner | Trigger | What it does |
|---|---|---|---|
| `unit-tests-ubuntu` | `ubuntu-latest` | push, PR | Installs Pester, runs `Unit` tag (65 tests) |
| `unit-tests-windows` | `windows-latest` | push, PR | Installs Pester, runs `Unit` tag (65 tests) |
| `integration-tests-windows` | `windows-latest` | push, PR | Runs `Integration` tag (25 tests, all mocked) |
| `docker-ssh-tests` | `ubuntu-latest` | push, PR | Builds SSHD container, generates SSH key, runs `DockerSsh` tag |
| `e2e-tests` | `ubuntu-latest` | dispatch, schedule | Clones real IMPACT repo, builds Docker image, starts container, validates full LOCAL flow. 45 min timeout. Requires `IMPACT_E2E_GITHUB_TOKEN` repo secret for SSH auth tests. |

### Adding the E2E GitHub token (optional)

To enable the 2 SSH authentication tests in CI:

1. Create a **Personal Access Token** (classic) on GitHub with `admin:public_key` scope.
2. Add it as a repository secret named `IMPACT_E2E_GITHUB_TOKEN`.
3. The E2E job will automatically pick it up and register/remove a temporary SSH key during the test run.

---

## Test Helpers

| File | Contents |
|---|---|
| `tests/Helpers/TestSessionState.ps1` | `New-TestSessionState` — creates a pre-populated `$State` hashtable for testing (supports `-Location 'LOCAL'` and `-Location 'REMOTE@<ip>'`); `New-DummySshKeyPair` — generates a throwaway ed25519 key pair; `Remove-TestArtifacts` — cleans up temp files |
| `tests/Helpers/SshdContainer.Dockerfile` | Ubuntu 22.04 SSHD image with `testuser` and a fake `IMPACTncd_Germany` git repo (directory layout mirrors the real remote workstation) |
| `tests/.pesterconfig.psd1` | Default Pester 5 configuration |
| `tests/Invoke-Tests.ps1` | Convenience test runner with `-Tag`, `-ExcludeTag`, `-CodeCoverage` switches |

---

## Writing New Tests

1. Add tests to the appropriate `.Tests.ps1` file (or create a new one).
2. Tag every `Describe` block with `Unit`, `Integration`, `DockerSsh`, or `E2E`.
3. Import the module in `BeforeAll`:

   ```powershell
   BeforeAll {
       Import-Module (Join-Path $PSScriptRoot '..' 'current_version' 'IMPACT_Docker_GUI.psm1') -Force
   }
   ```

4. Use `Mock -ModuleName IMPACT_Docker_GUI` when mocking functions called inside the module.
5. Use `New-TestSessionState` from the helper for a ready-made state object.
6. For REMOTE-specific tests, use `New-TestSessionState -Location 'REMOTE@<ip>'` and mock SSH calls.
