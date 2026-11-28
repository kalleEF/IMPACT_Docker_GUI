# Tests of the workstation commands

This folder tests the bash commands in `workstation/`. The tests are plain bash scripts: there
is no test framework to install. This page explains how they work, for a reader who has not
written tests in bash before.

## The idea in short

A test runs a piece of the real code and compares what happens with what should happen. When
the two differ, the test fails and prints both. A test that cannot run on a machine (because a
tool or a Docker daemon is missing) is reported as skipped, with the reason.

There are three levels:

| Level | What it tests | Where it may run | Command |
|---|---|---|---|
| unit | single functions of the library, for example the parser of the settings file, the name rules, the key checks | anywhere, as any account; it changes nothing | `bash tests/workstation/run-tests.sh unit` |
| system | each command as a whole, at its real place, as root: normal run, `--dry-run`, second run, wrong and hostile input | only on a disposable machine | `sudo env IMPACT_TEST_DISPOSABLE=yes bash tests/workstation/run-tests.sh system` |
| scenario | one walk through the life of a workstation, from the health check of the untouched machine to the removal of the commands | only on a disposable machine | `sudo env IMPACT_TEST_DISPOSABLE=yes bash tests/workstation/scenario.sh` |

"Disposable" means a machine that may be changed and thrown away afterwards: a fresh virtual
machine, a container, or a runner of GitHub Actions. The system tests and the scenario create
accounts and groups, write SSH rules and start an SSH server. They refuse to start unless
`IMPACT_TEST_DISPOSABLE=yes` is set, they need root, and they refuse a machine that has a
settings file `/etc/impact/impact.conf` (that file marks a workstation in use). Never run them
on the real workstation.

## What you see

Each test prints one line, and each level ends with a summary line:

```
PASS  unit/20-name-rules.test.sh :: test_account_names
FAIL  unit/21-settings-file.test.sh :: test_duplicate_key_is_an_error
      | ASSERTION FAILED: expected: 1
      |   actual:   0
      |   in test_duplicate_key_is_an_error, line 88
SKIP  system/users-40-docker.test.sh :: test_dry_run_stops_nothing (no Docker daemon answers on this machine)
SUMMARY unit: 236 tests, 235 passed, 1 failed, 0 skipped
```

A failed test shows its output below its line, indented with `|`. The line `in ..., line N`
names the place in the test file. The runner ends with exit code 0 when no test failed
(skipped tests are allowed) and 1 otherwise, so an automatic check can tell the two apart.

Useful options of the runner:

```
bash tests/workstation/run-tests.sh unit --filter settings   # only files or tests with "settings" in the name
bash tests/workstation/run-tests.sh unit --verbose           # print the output of passing tests too
bash tests/workstation/run-tests.sh all                      # unit, then system
```

## How a test file looks

A test file is a bash file in `unit/` or `system/` whose name ends in `.test.sh`. Every
function whose name starts with `test_` is one test. The runner starts each test in its own
bash process, so one test cannot disturb another, and it runs the tests of a file in the order
in which they are written.

```bash
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/testlib.sh"

setup() {
    load_library                      # loads workstation/lib/impact-common.sh
}

test_port_rule() {
    assert_success impact_valid_port 8787
    assert_fails impact_valid_port 80
}

test_command_refuses_a_bad_name() {
    run_cmd "$WORKSTATION_DIR/bin/impact-add-user" 'bad name'
    assert_status 2
    assert_output_contains 'is no valid GitHub name'
}
```

- `setup` and `teardown` (optional) run before and after every test of the file.
- `suite_setup` and `suite_teardown` (optional) run once per file, before the first and after
  the last test. The system tests use them to install the commands and to clean up. When
  `suite_setup` calls `skip "reason"`, every test of the file is reported as skipped.
- `run_cmd COMMAND...` runs a command and never ends the test, whatever happens. Afterwards
  `RUN_STATUS` holds its exit code and `RUN_OUTPUT` everything it printed.
- The assertions end the test with a clear message when the check is not met: `assert_eq`,
  `assert_status`, `assert_output_contains`, `assert_output_not_contains`, `assert_exists`,
  `assert_missing`, `assert_file_facts PATH MODE OWNER GROUP`, `assert_success`, `assert_fails`
  and a few more; `lib/testlib.sh` lists them with a comment each.
- `skip "reason"` ends a test as skipped, for example when a tool is missing.
- Every test function has a comment directly above it that states the behaviour it proves, for
  example `# impact_lower turns upper-case letters into lower-case ones and keeps every other
  character.` Where the name of the function already says it in full, the comment is the name
  written as a sentence.

The helper files in `lib/`:

| File | Content |
|---|---|
| `testlib.sh` | the assertions, `run_cmd`, `skip`, `fail`; it loads the next two |
| `snapshot.sh` | records the state of the machine and compares two records |
| `system.sh` | helpers for the system tests: test accounts, the stand-in administrator `tadmin`, test disks, the SSH server, logins with key and password |
| `run-one.sh` | used by the runner to start one test function in its own process |

## How "changes nothing" is proven

The commands promise that `--dry-run` changes nothing and that a second run changes nothing.
The tests prove it with a snapshot: a list of every account, group and password state, and of
every entry below the named folders with its type, owner, group, mode, link target and access
control list (and, with `--content`, a checksum of every file). The test takes a snapshot,
runs the command, takes a second snapshot, and fails when the two differ; the differing lines
are printed.

```bash
snapshot_unchanged_by --content /etc/impact /opt/impact /home -- \
    sys_as_admin impact-add-user alice-example --key-file "$(sys_key_path alice-example).pub" --dry-run
assert_status 0
```

The home folders that exist before the system tests start (for example the one of the account
that runs the tests) belong to the machine, and other programs may write inside them at any
time. The runner lists them in `IMPACT_TEST_FOREIGN_HOMES`, and a snapshot records only these
folders themselves (owner, mode, access control list), without their content. Otherwise a file
that another program changes there would make a test fail that has nothing to do with it.
Likewise, a test that compares two reports of `impact-check` leaves out the free space of the
disks, which changes by itself.

## Stand-in programs and signals

Some cases cannot be made with the real programs alone. The commands search programs first in
`/usr/local/sbin`, then in `/usr/local/bin`, so a system test may put a small stand-in there
and removes it again at its end: `curl` answers the questions to GitHub from local files
(users-10), `useradd` runs the real `/usr/sbin/useradd` and then sends a signal while the
command still waits for it (users-10), and `docker` and `dockerd` answer with fixed lists or
versions (check-10, users-30, 20-setup).
A stand-in proves how a command treats an answer; it proves nothing about the real program.

A signal is sent to the whole process group of a command (`kill -s TERM -- -<group>`), as a
closed SSH session does, after `setsid` gave the command a group of its own. Ctrl+C itself
comes from a terminal: repos-30 starts `impact-give-repo` on a pseudo terminal (a terminal
made by a small `python3` program) and types the byte that Ctrl+C sends, so the terminal
signals every program of the command at once, as it does for a person.

## Shared test cases of the settings file

The GUI reads the settings file `/etc/impact/impact.conf` as well. So that both readers keep
exactly the same rules, the cases live in two plain text files that the tests of both read:

- `vectors/settings-lines.vectors`: whole files for the reader of `KEY=value` lines (line ends,
  blanks, zero bytes, encoding, comments, duplicate keys), each marked `ACCEPT` or `REFUSE`,
  with the pairs an accepted file must give;
- `vectors/settings-values.vectors`: single values per key (numbers, versions, paths, storage
  roots, container patterns, contact texts), each marked `ACCEPT` or `REFUSE`.

The header of each file explains its format. `unit/22-settings-vectors.test.sh` runs every
case. A new rule gets a new case in these files first.

## The check for values of a real installation

The repository is public and must not hold values of a real installation (account and host
names, paths of the storage disks). `unit/90-delivery.test.sh` searches every file for them.
The values themselves are kept outside the repository: the variable `IMPACT_SITE_VALUES_FILE`
names a file with one value per line. Without that variable the test is reported as skipped.

```
IMPACT_SITE_VALUES_FILE=/path/outside/the/repository/site-values.txt bash tests/workstation/run-tests.sh unit --filter 90-delivery
```

## Running the system tests and the scenario

On a disposable Ubuntu machine with `sudo`:

```
sudo apt-get install acl git curl openssh-server shellcheck
sudo env IMPACT_TEST_DISPOSABLE=yes bash tests/workstation/run-tests.sh system
sudo env IMPACT_TEST_DISPOSABLE=yes bash tests/workstation/scenario.sh
```

- The storage tests need `/mnt` on ext4, xfs or btrfs. Where `/mnt` lies on another kind of
  file system (for example inside a container), set `IMPACT_TEST_BACKING_DIR` to a folder on
  ext4: the tests then mount two folders of it at `/mnt/disk_a` and `/mnt/disk_b`.
- The tests use an SSH server that runs already; otherwise they start one on `127.0.0.1`.
- Docker: Docker must be installed (`impact-workstation-setup` checks its version). The tests
  that need a running Docker daemon are skipped where none answers.
- Every system test file and the scenario remove what they created at their end. After an
  aborted run, use a fresh machine.

The scenario takes about a minute. Its steps build on each other: when a step that later steps
need fails (for example the installation), the later steps are reported as failed with the
note "not run". `scenario.sh --from <folder>` installs from an unpacked delivery archive; this
tests the archive that `workstation/build-archive.sh` builds.
`scenario.sh --keep` leaves the state in place at the end, to look at it.

## Adding a test

1. Choose the level: a function that only works on text or on files in a temporary folder
   belongs to `unit/`; anything that needs root, accounts or the real paths to `system/`.
2. Add a function `test_<what it proves>` to the file of the topic, or start a new file by
   copying the header of an existing one. System test files run in the order of their names.
3. Run the file alone: `bash tests/workstation/run-tests.sh unit --filter <part of its name>`.
4. Check it with shellcheck (below), and make sure the test fails when the code is wrong: break
   the code on purpose for a moment and watch the test fail.

For every command that changes something, the system tests cover at least: a normal run;
`--dry-run` changes nothing; a second run changes nothing; wrong input is refused before any
change; hostile input is refused (names with spaces, quotes, `;`, `$(...)`, `../`, a symbolic
link where a folder is expected, a key line with options or with two keys).

## shellcheck

shellcheck reads bash scripts and reports mistakes that bash itself accepts, for example a
variable without quotes. All scripts of the commands and of the tests pass it without a
finding:

```
shellcheck -x -s bash workstation/bin/* workstation/*.sh workstation/lib/*.sh \
    tests/workstation/*.sh tests/workstation/lib/*.sh tests/workstation/unit/*.sh tests/workstation/system/*.sh
```

Where a check is switched off for one line, a comment above it gives the reason.
