# Testing Guide: IMPACT Docker GUI

How the tests are organised, how to run them locally, and what CI runs.

> **Platform note.** The GUI runs **only on Windows** (WinForms, Docker Desktop). The Docker images it manages are **Linux** containers. Unit and Integration tests therefore run on Windows in CI, and the Docker-based suites run on Ubuntu with PowerShell 7 (`pwsh`). On Linux or macOS some Unit tests and many Integration tests fail or are skipped because Windows path rules, WinForms/System.Drawing, the Windows service cmdlets or OpenSSH (`ssh`, `ssh-keygen`) are missing; that is expected.

---

## Architecture

| File | Purpose |
|---|---|
| `current_version/IMPACT_Docker_GUI.psm1` | Module with the core functions (logic, SSH, Docker, git, dialogs). Imported by the GUI script and by the tests. |
| `current_version/IMPACT_Docker_GUI.psd1` | Manifest. `FunctionsToExport` must list exactly the functions in the `.psm1`'s `Export-ModuleMember` (a unit test checks this). |
| `current_version/IMPACT_Docker_GUI_v2.ps1` | GUI script: imports the module and runs the workflow (remote/local preparation, Container Manager with the Start/Stop handlers). Not imported by the tests; one unit test parses it to check that every module function it calls is exported. |

### NonInteractive mode

```powershell
Enable-NonInteractiveMode    # dialogs are skipped; values come from the session state
Disable-NonInteractiveMode
Test-NonInteractiveMode
```

In NonInteractive mode the dialog functions (`Show-CredentialDialog`, `Select-Location`, `Ensure-GitKeySetup`, `Show-GitCommitDialog`, message boxes in the git flow, ...) read their input from `$State` instead of showing a window. `Show-CredentialDialog` then only warns about a weak RStudio password, so fixed test passwords keep working. The GitHub key check (`Confirm-GitHubKeyRegistered`, `ssh -T git@github.com`) is skipped in NonInteractive mode.

---

## Test framework

[Pester 5](https://pester.dev/). The runner installs it if needed:

```powershell
Install-Module Pester -Force -Scope CurrentUser -MinimumVersion 5.0.0 -SkipPublisherCheck
```

---

## Test suites

| Level | File | Tag | What it covers | CI runner | Needs |
|---|---|---|---|---|---|
| 1 | `tests/Unit.Tests.ps1` | `Unit` | Pure logic: session state, path conversion, Docker context args, YAML parsing (quotes, `~`, empty values), `docker run` arguments (127.0.0.1 binding, labels, custom params), volume names, SSH config entries and the `IdentityFile` quoting repair (in a temp folder), SSH key repair, the GitHub key check (classifier, dialog flow with mocks, session memory), ssh-agent key detection, workstation IP and `.env` parsing, container SSH/git setup commands, port checks, Docker error messages, `.env` credentials, logging, PowerShell version guard, GitHub username/password rules, shell quoting, git push hints, manifest/export consistency | Windows | Nothing (`ssh-keygen` for one test, which is skipped without it) |
| 2 | `tests/Integration.Tests.ps1` | `Integration` | Mocked multi-step flows: NonInteractive dialogs, SSH key setup (existing key and new key, in a temp folder), Docker daemon checks, ssh-agent, Write-Log output, remote container flow, git status/commit/push flow (local and remote), remote metadata, remote key check, Docker Desktop start, remote docker login, volume helpers | Windows | Nothing (everything mocked) |
| 3 | `tests/DockerSsh.Tests.ps1` | `DockerSsh` | Live SSH against an SSHD container; plus the production in-container SSH setup command (`Get-ContainerSshSetupCommand`) run in a real container, with a strict host-key check against github.com (no token needed) | Ubuntu | Docker, SSHD image, internet for the github.com checks; with `Invoke-Tests.ps1` also github.com for Preflight (without it the suite is NOT RUN) |
| 4 | `tests/ImageValidation.Tests.ps1` | `ImageValidation` | Builds the real IMPACT image, starts it, checks RStudio, R packages, `global.R`, the production SSH setup, known_hosts, a strict host-key check, `GIT_SSH_COMMAND` in a clean R session (as RStudio starts them), and with a token GitHub auth and `git pull` | Ubuntu | Docker, internet |
| 5 | `tests/RemoteE2E.Tests.ps1` | `RemoteE2E` | Full SSH to workstation to Docker flow (Docker-out-of-Docker): clone, build, start, RStudio, `global.R`, the production SSH setup and `GIT_SSH_COMMAND`, and with a token GitHub auth and `git pull` over SSH | Ubuntu | Docker, internet, Docker socket |
| - | `tests/Preflight.Tests.ps1` | `Preflight` | Quick checks run by `Invoke-Tests.ps1` before suites 3 to 5; in CI only before ImageValidation and RemoteE2E: Docker reachable, git and GitHub reachable, `ssh-keygen` present, test keys usable, temp folder writable | Ubuntu | Docker, git, `ssh-keygen`, access to github.com |

The number of tests changes often; the runner prints the counts per suite.

### LOCAL vs REMOTE coverage

| Layer | LOCAL | REMOTE |
|---|---|---|
| Unit | Relative YAML paths, local `docker run` arguments | Absolute YAML paths, remote host string, context args, remote `docker run` arguments |
| Integration | Local credential/git flows, Docker checks | Mocked remote flow (YAML, folders, `docker run`), remote git commit/push, metadata, key checks |
| DockerSsh | - | Live SSH commands against an SSHD container; in-container SSH setup |
| ImageValidation | The image itself, started like a local container | - |
| RemoteE2E | - | Full SSH to Docker lifecycle via a workstation container |

### Docker-out-of-Docker (DooD) for RemoteE2E

```
+--- CI host / your PC ---------------------------------------------------+
|  Docker daemon (host)                                                   |
|  +--- workstation-test container -----------------------------------+   |
|  |  Ubuntu 22.04 + SSHD + Docker CLI (no daemon)                     |   |
|  |  /var/run/docker.sock mounted from the host                       |   |
|  |  SSH port 22 -> host 2223 (Invoke-Tests.ps1) or 2222 (CI)         |   |
|  |  testuser runs docker build / docker run                          |   |
|  |    -> talks to the HOST daemon -> creates SIBLING containers      |   |
|  +-------------------------------------------------------------------+   |
|  +--- impact_remote_e2e_inner (sibling) ------------------------------+  |
|  |  RStudio Server (reached from the workstation via its container IP)|  |
|  +--------------------------------------------------------------------+  |
+-------------------------------------------------------------------------+
```

- No nested Docker daemon and no `--privileged`: only the socket is mounted.
- Bind mounts would refer to the HOST's file system, so the repository and the key are copied into the inner container with `docker cp`. The key goes to `/keys/id_ed25519_e2e`, the same place the GUI bind-mounts it, and then the **production** `Get-ContainerSshSetupCommand` runs (sent base64-encoded because it contains quotes). `USERID`/`GROUPID` are the workstation account's `id -u`/`id -g`, as in the GUI.
- If the socket's group is not root, the entrypoint gives the container's `docker` group the socket's GID. If the socket belongs to group 0 (root), the entrypoint changes the socket's group to GID 999 and makes it group-writable. This changes the Docker socket of the machine that runs the tests until the Docker engine restarts.

---

## Running tests locally

### The test runner: `tests/Invoke-Tests.ps1`

| Command | What runs |
|---|---|
| `pwsh tests/Invoke-Tests.ps1` | Unit + Integration (default) |
| `pwsh tests/Invoke-Tests.ps1 -Tag Unit` | One suite (also `Integration`, `DockerSsh`, `ImageValidation`, `RemoteE2E`) |
| `pwsh tests/Invoke-Tests.ps1 -Level DockerSsh` | Unit, Integration and DockerSsh |
| `pwsh tests/Invoke-Tests.ps1 -Level ImageValidation` | ... plus ImageValidation (15-25 min) |
| `pwsh tests/Invoke-Tests.ps1 -Level RemoteE2E` | ... plus RemoteE2E (20-40 min) |
| `pwsh tests/Invoke-Tests.ps1 -Level All` | Everything |
| `pwsh tests/Invoke-Tests.ps1 -Level All -GitHubToken ghp_xxx` | Everything, including the GitHub SSH auth tests |
| `-ExcludeTag <tag>` | Skip tests with that tag |
| `-SkipBuild` / `-KeepArtifacts` | Reuse an existing image / keep clone and image after the E2E suites |
| `-AllowSkip` | Exit 0 even if some suites could not run |
| `-CodeCoverage` | Measures coverage of the module and writes `tests/coverage-<suite>.xml` |

`-Tag` and `-Level` cannot be combined.

The runner:

- loads `KEY=value` lines from a `.env` file in the repository root into environment variables (tokens are shown masked); `IMPACT_E2E_SKIP_BUILD` and `IMPACT_E2E_KEEP_ARTIFACTS` are then set from `-SkipBuild` and `-KeepArtifacts` (see [Environment variables](#environment-variables)),
- builds and starts the SSHD container (`sshd-test`, port **2222**) and the workstation container (`workstation-test`, port **2223**) when those suites are requested, creates throw-away test keys in `<temp>/impact_test_ssh` and sets the `IMPACT_TEST_SSH_*` / `IMPACT_REMOTE_E2E_SSH_*` variables,
- runs the Preflight checks before DockerSsh, ImageValidation and RemoteE2E,
- runs the suites in order and removes the containers it created,
- saves artifacts (result XML, container logs, environment info) to `tests/artifacts/<suite>/<timestamp>/` **only when a suite failed or tests were skipped** (the folder is git-ignored), then deletes the `tests/TestResults-*.xml` files,
- prints a summary table with a **Status** per suite: `PASS`, `FAIL` or `NOT RUN` with the reason.

**A suite that could not run is never silently left out.** If Docker is not running, a container could not be set up, the Preflight checks failed, the file is missing or the suite name is unknown, it is listed as `NOT RUN` with the reason, and the summary says the run is INCOMPLETE. A test file that cannot be loaded, or a failing `BeforeAll`/`AfterAll`, counts as `FAIL` even though no single test failed.

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | Every requested suite ran and passed. |
| 1 | A test failed, a test file / `BeforeAll` / `AfterAll` failed, or the parameters are invalid (for example `-Tag` with `-Level`, or an unknown `-Level`). |
| 2 | Nothing failed, but at least one requested suite was NOT RUN. Use `-AllowSkip` to get 0 in that case (for example on a PC without Docker). |

### Direct Pester invocation

```powershell
Import-Module Pester -MinimumVersion 5.0.0
Invoke-Pester ./tests/Unit.Tests.ps1 -Output Detailed
Invoke-Pester ./tests/Integration.Tests.ps1 -Output Detailed
```

There is no shared Pester configuration file; the runner and CI build their configuration in code.

### DockerSsh tests by hand

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

   The "Container SSH setup command in a real container" tests reuse the `impact-sshd-test` image. They are skipped (with the reason) when the image, `docker` or `ssh-keygen` is missing, and their github.com checks are skipped when github.com cannot be reached.

3. Clean up: `docker stop sshd-test && docker rm sshd-test`

### RemoteE2E tests by hand

1. Build and start the workstation container:

   ```bash
   docker build -t impact-workstation-test -f tests/Helpers/WorkstationContainer.Dockerfile .
   ssh-keygen -t ed25519 -f /tmp/id_ws_test -N "" -q
   docker run -d -p 2223:22 -v /var/run/docker.sock:/var/run/docker.sock --name workstation-test impact-workstation-test
   docker cp /tmp/id_ws_test.pub workstation-test:/home/testuser/.ssh/authorized_keys
   docker exec workstation-test chown testuser:testuser /home/testuser/.ssh/authorized_keys
   docker exec workstation-test chmod 600 /home/testuser/.ssh/authorized_keys
   ```

2. Check that Docker works through SSH:

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

4. Clean up: `docker stop workstation-test && docker rm workstation-test`

---

## Environment variables

| Variable | Used by | Purpose |
|---|---|---|
| `IMPACT_TEST_SSH_HOST` | DockerSsh | SSH host of the SSHD container (`localhost`). The suite is skipped if it or the key is not set. |
| `IMPACT_TEST_SSH_PORT` | DockerSsh | SSH port (default `2222`). |
| `IMPACT_TEST_SSH_USER` | DockerSsh | SSH user (default `testuser`). |
| `IMPACT_TEST_SSH_KEY` | DockerSsh, Preflight | Private key for the SSHD container. Preflight checks that it has no passphrase. |
| `IMPACT_REMOTE_E2E_SSH_HOST` | RemoteE2E | SSH host of the workstation container (default `localhost`). |
| `IMPACT_REMOTE_E2E_SSH_PORT` | RemoteE2E | SSH port (default `2222`; the runner uses `2223`). |
| `IMPACT_REMOTE_E2E_SSH_USER` | RemoteE2E | SSH user (default `testuser`). |
| `IMPACT_REMOTE_E2E_SSH_KEY` | RemoteE2E, Preflight | Private key for the workstation container. |
| `IMPACT_E2E_GITHUB_TOKEN` | ImageValidation, RemoteE2E | Fine-grained token with **SSH keys: Read and Write**. Enables the GitHub SSH auth and `git pull` tests; they are skipped without it. |
| `IMPACT_E2E_SKIP_BUILD` | ImageValidation, RemoteE2E | `1` = reuse the existing image. `Invoke-Tests.ps1` sets this from `-SkipBuild` and ignores a value from `.env` or the shell; set it yourself only for direct Invoke-Pester runs. |
| `IMPACT_E2E_KEEP_ARTIFACTS` | ImageValidation, RemoteE2E | `1` = keep the clone and the image after the tests. `Invoke-Tests.ps1` sets this from `-KeepArtifacts` and ignores a value from `.env` or the shell; set it yourself only for direct Invoke-Pester runs. |

---

## Typical workflow after a change

1. Edit the module (`IMPACT_Docker_GUI.psm1`) or the GUI script (`IMPACT_Docker_GUI_v2.ps1`).
2. Run the unit tests: `pwsh tests/Invoke-Tests.ps1 -Tag Unit`.
3. Run Unit + Integration: `pwsh tests/Invoke-Tests.ps1`.
4. If SSH/remote logic or the container SSH setup changed: `pwsh tests/Invoke-Tests.ps1 -Level DockerSsh`.
5. If the image, the container start or `global.R` handling changed: `pwsh tests/Invoke-Tests.ps1 -Level RemoteE2E -GitHubToken ghp_xxx`.
6. Push. CI runs Unit, Integration and DockerSsh (see below); start the E2E jobs by hand when needed.

---

## CI: GitHub Actions

Workflow: `.github/workflows/test.yml`.

**Triggers:**

- **Push** to `main` or `develop`, but **only when** files under `current_version/`, `tests/` or the workflow file change (documentation-only pushes do not run CI): Unit, Integration, DockerSsh.
- **Pull request** to `main` (any change): the same three jobs.
- **Manual run** (`workflow_dispatch`): the same three jobs; ImageValidation and RemoteE2E only when **run_e2e** is ticked.
- **Weekly** (Sunday 03:00 UTC): all five jobs.

| Job | Runner | Runs on | What it does |
|---|---|---|---|
| `unit-tests` | `windows-latest` | push, PR, manual, weekly | Installs Pester, runs the `Unit` tag. |
| `integration-tests` | `windows-latest` | same; after `unit-tests` | Checks that the docker CLI exists, runs the `Integration` tag (everything mocked). |
| `docker-ssh-tests` | `ubuntu-latest` | same; after `unit-tests` | Builds the SSHD image, starts it with a fresh key, runs the `DockerSsh` tag, including the production in-container SSH setup in a real container and the strict github.com host-key check (no token). |
| `image-validation` | `ubuntu-latest` | manual with run_e2e, weekly; after `docker-ssh-tests` | Preflight, then builds the real image and validates the container. 45 min timeout. |
| `remote-e2e` | `ubuntu-latest` | manual with run_e2e, weekly; after `docker-ssh-tests` | Builds the workstation container (SSH port 2222), Preflight (the key path is set for the whole job, so Preflight checks it), then the full DooD flow. 60 min timeout. |

Failed jobs upload their result XML; the E2E jobs also upload container logs and `docker inspect` output.

### Why Windows and Ubuntu

| Runner | Why |
|---|---|
| Windows for Unit and Integration | The GUI only runs on Windows; WinForms-dependent code can only be tested there. |
| Ubuntu for the Docker suites | The images are Linux containers; GitHub's Windows runners cannot run Linux containers. |

### Adding the GitHub token (optional)

1. Create a **fine-grained personal access token** with **SSH keys: Read and Write**.
2. Add it as the repository secret `IMPACT_E2E_GITHUB_TOKEN`.
3. ImageValidation and RemoteE2E use it to register a temporary key (removed afterwards). Without it, only the token tests are skipped; the token-free host-key checks still run.

---

## Test helpers

| File | Contents |
|---|---|
| `tests/Helpers/TestSessionState.ps1` | `New-TestSessionState` (state for `LOCAL` or `REMOTE@<ip>`, key paths in the temp folder), `New-DummySshKeyPair`, `Test-IsSshKeyUsable`, `Save-TestArtifacts`, `Remove-TestArtifacts`, `Assert-PreflightPassed`, `Wait-ForRStudioReady` (treats HTTP 200/302/401/403 as "ready", also for PowerShell 7's `HttpResponseException`), `Invoke-DockerExecSafe`, `ConvertTo-Base64Script` |
| `tests/Helpers/SshdContainer.Dockerfile` | Ubuntu 22.04 with SSHD, `testuser` and a fake `IMPACTncd_Germany` repository with the workstation's folder layout. Also used for the in-container SSH setup tests. |
| `tests/Helpers/WorkstationContainer.Dockerfile` | Built from `ubuntu:22.04` with the same SSH set-up as the SSHD image (a separate copy: change both files), plus the Docker CLI (no daemon) for DooD. The entrypoint matches the `docker` group to the socket's GID, or changes the socket's group (see [DooD](#docker-out-of-docker-dood-for-remotee2e)). |
| `tests/Invoke-Tests.ps1` | The runner described above. |

---

## Test hygiene: what the tests may touch

- **The tests never write to your real `~/.ssh`.** PowerShell's `$HOME` cannot be changed, so the tests of `Ensure-SshConfigEntry` and `Ensure-GitKeySetup` mock `Join-Path` for the `Join-Path $HOME '.ssh'` calls inside the module (also the one the ssh config repair uses) and work in a temp folder. Guard mocks make any write below the real `~/.ssh` throw an error, so such a write fails loudly: `Add-Content`, `Set-Content` and `Remove-Item` (with `-Path` or `-LiteralPath`), `New-Item` (`-Path`) and `Copy-Item` (`-Destination`). `ssh-keygen`, `Set-Clipboard` and `ssh-agent` (`Get-Service`, `Start-Service`, `ssh-add`) are mocked, and a `Start-Process` mock fails if the code ever tries to start an elevated process, so no key is created, nothing is copied to the clipboard and no UAC prompt appears. Tests of the ssh config backup fallback folder mock it, so nothing is written to the real `~/.impact_gui/ssh-config-backups`.
- **Older versions of the tests did write there.** If you ran them before, you may want to remove, by hand: the `Host 198.51.100.99` block in `~/.ssh/config`, and the files `~/.ssh/id_ed25519_gitsetup` and `~/.ssh/id_ed25519_gitsetup.pub` (and `ssh-add -d ~/.ssh/id_ed25519_gitsetup` if it was loaded into ssh-agent).
- The Unit and Integration files point the IMPACT log at a temp file (`IMPACT_LOG_FILE`, set in their top-level `BeforeAll` and restored in `AfterAll`), so the real `~/.impact_gui/logs/impact.log` is not touched. The `Write-Log` tests use their own temp file and restore the setting afterwards. The DockerSsh, ImageValidation and RemoteE2E files do not redirect the log.
- If the socket of the Docker engine that runs the tests belongs to group 0 (root), the workstation container used by RemoteE2E changes the socket's group to GID 999 and makes it group-writable (see [DooD](#docker-out-of-docker-dood-for-remotee2e)). This lasts until the Docker engine restarts.
- Temp paths: on Linux `$env:TEMP` is empty, so the Unit and Integration files set it to the system temp folder when it is missing.

---

## Writing new tests

1. Add new `Describe` blocks at the **end** of the right `.Tests.ps1` file, tagged `Unit`, `Integration`, `DockerSsh`, `ImageValidation` or `RemoteE2E`.
2. Import the module in `BeforeAll`:

   ```powershell
   BeforeAll {
       Import-Module (Join-Path $PSScriptRoot '..' 'current_version' 'IMPACT_Docker_GUI.psm1') -Force
   }
   ```

3. **Pester 5 scoping:** define variables inside `BeforeAll`/`BeforeEach`/`It`. Values set in `BeforeDiscovery` (or between it and `Describe`) are only available while `-Skip:` is evaluated, not while the tests run.
4. Mock functions that the module calls with `Mock <name> -ModuleName IMPACT_Docker_GUI`, and check them with `Should -Invoke ... -ModuleName IMPACT_Docker_GUI`.
5. Pester can only mock commands that exist. For `ssh`, `ssh-keygen`, `ssh-add`, `docker`, `Get-Service` or `Start-Service` on a machine without them, define a temporary global stub that throws when called without a mock (`function global:ssh { throw 'ssh stub called without a mock' }`), and remove it in `AfterAll` with `Remove-Item Function:\ssh`.
6. Native commands (and stubs without a `param()` block) receive their arguments in `$args`, also in mock bodies and `-ParameterFilter`. Set `$global:LASTEXITCODE` in a mock when the code checks it.
7. The module runs under `Set-StrictMode -Version Latest`: reading a missing hashtable key with dot notation throws, so use `$h['key']` or `ContainsKey` in test helpers that touch the session state.
8. Use `New-TestSessionState` for a ready-made state, and `-Location 'REMOTE@<ip>'` plus mocked `ssh` for remote tests.
9. Code that uses WinForms or System.Drawing cannot even be compiled on Linux; mark such tests `-Skip:(-not $IsWindows)` with a comment.
10. If you add or export a module function, update **both** `Export-ModuleMember` in the `.psm1` and `FunctionsToExport` in the `.psd1`.
