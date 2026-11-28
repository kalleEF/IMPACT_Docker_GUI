# IMPACT workstation commands

These bash commands prepare and run the shared Linux workstation on which IMPACT Docker GUI
starts RStudio containers in REMOTE mode. They are for the administrator of that machine. Two
of them (`impact-get-repo` and `impact-update-setup`) are for every colleague; the GUI calls
them.

With version 2.1 of the GUI every colleague has a personal account on the workstation. The
account has no password: the person logs in with the SSH key of the GUI only (SSH is the
encrypted connection that the GUI uses). The browser reaches RStudio through an SSH tunnel, a
forwarded connection inside that login, so no container is reachable from the network directly.
The commands set this up with checks before every change and with a way back after it.

Every command:

- explains itself: `impact-<command> --help` shows its purpose, examples, what it changes and
  how to undo it;
- shows every step without changing anything when you add `--dry-run` (commands that only read
  have no `--dry-run`);
- can be run again safely: a second run with the same input changes nothing and says so;
- ends with the lists "What changed" and "How to undo", whose lines work when you follow them
  from top to bottom;
- writes one block to the log `/opt/impact/admin/log/impact-admin.log` when it changes
  something (time in UTC, who ran `sudo`, the command, the result; public keys appear as their
  fingerprint, private keys and passwords never). The two commands for colleagues
  (`impact-get-repo`, `impact-update-setup`) run without root rights and write no log block:
  the log folder is readable by root only. `impact-give-repo`, which the administrator runs,
  logs the copies it makes, and `impact-check` (block 9) shows the working copies of everyone.

The repository is public. It holds no values of a real installation: the settings of a site
reach the machine as command options and through the settings file `/etc/impact/impact.conf`.

## What lives where on the workstation

```
/opt/impact/                       the installed commands (owner root)
    bin/impact-*                   the commands
    lib/impact-*.sh                their shared functions
    etc/                           example settings file, GitHub's host keys
    uninstall.sh  VERSION
    admin/                         root only (mode 700)
        log/impact-admin.log       one block per changing command
        accounts/<account>.conf    who is enrolled, with which GitHub name
        keys/<account>/            received and removed public keys
        acl-backups/               saved access rights (impact-share-folder)
        state/                     backup archives (impact-export-state)
/usr/local/bin/impact-*            links to /opt/impact/bin, so "sudo impact-check" works

/etc/impact/impact.conf            site settings, readable by all (the GUI reads them too)
/etc/impact/github_known_hosts     GitHub's published SSH host keys
/etc/ssh/sshd_config.d/60-impact.conf   SSH rules for the members of the shared group

MODEL_DIR/<model>/                 per model (default MODEL_DIR: /srv/impact/models)
    model.conf                     GitHub address, branch, storage name, storage roots
    extras/                        files that are not on GitHub, at their repository paths

/home/<account>/                   each colleague
    .ssh/authorized_keys           the login keys of the person's PCs
    .ssh/id_ed25519_<GitHub name>  key copy for git (the GUI places it)
    Repositories/<model>/          the person's own working copy (REPO_BASE)

<storage root>/<storage name>/     per model on each storage disk (SHARED_ROOTS)
    outputs/                       results; the model creates one folder per analysis
    inputs/synthpop/               synthetic populations
```

Two groups matter:

- the shared group (default `impact`): every enrolled colleague. It may read the model folders
  and write the shared storage, and the SSH rules apply to it: key login only, tunnels only to
  the container ports on `127.0.0.1`. The administration account is no member.
- `docker`: needed to use Docker. Membership in `docker` gives the same power as root over the
  machine. Every enrolled colleague is a member; personal accounts give order and protection
  against mistakes, and they are no barrier between colleagues.

The storage folders carry the "setgid" bit (new entries inherit the group) and a default access
control list (ACL: extra access entries next to owner, group and mode), so a file that one
colleague creates can be changed by every other member.

## Installation

You need: Ubuntu 22.04 or 24.04, Docker Engine 28.3.3 or newer from Docker's own apt source
(package `docker-ce`), the packages `acl`, `git` and `curl`, an administration account with
`sudo`, and storage disks with ext4, xfs or btrfs.

1. Build the archive on any Linux computer from a copy of this repository:

   ```
   bash workstation/build-archive.sh
   ```

   It writes `impact-workstation-2.1.0.tar.gz` and a file with its SHA-256 checksum (a code that
   changes when one byte of the archive changes), and prints the checksum.

2. Copy both files to the administration account of the workstation, for example with `scp`,
   and check the copy there:

   ```
   sha256sum -c impact-workstation-2.1.0.tar.gz.sha256
   tar -xzf impact-workstation-2.1.0.tar.gz
   cd impact-workstation-2.1.0
   ```

3. Install. `install.sh` copies the commands to `/opt/impact`, creates the links in
   `/usr/local/bin` and the folder `/opt/impact/admin`, and checks that every tool is present
   (for a missing one it prints the `apt-get install` line and stops; it installs no
   packages). It creates no account, group or setting.

   ```
   sudo ./install.sh --dry-run
   sudo ./install.sh
   ```

To remove the commands again: `sudo /opt/impact/uninstall.sh`. It removes the commands and
their links only, and lists everything that stays (accounts, group, settings, SSH rules,
models, storage) with the command that removes each part by hand. When the SSH rules should go
as well, remove them first, while the commands are still installed:
`sudo impact-workstation-setup --remove-ssh-rules`, then `sudo /opt/impact/uninstall.sh`.
After the removal, `/opt/impact/uninstall.sh` is gone; a later run starts from the unpacked
folder: `sudo ./uninstall.sh`.

## A worked example: from the first setup to a colleague's first repository

The values are examples: storage roots `/mnt/disk_a/shared` and `/mnt/disk_b/shared`, the
model `Example-Model` on GitHub at `example-org/Example-Model`, and the colleague Alice with the
GitHub name `alice-example` and the Linux account `alice`. Start every command that changes
something with `--dry-run` first, read its steps, then run it again without `--dry-run`.

**1. Look at the untouched machine.** Run the health check from the unpacked folder, before
anything is installed. It reads only and prints numbered blocks that end in OK, WARN or FAIL;
on an untouched machine block 4 (settings file) is FAIL, which is expected. Its lines "What to
do" name IMPACT commands such as `sudo impact-workstation-setup`: these work after the
installation (step 2), so install first, then follow them.

```
sudo ./bin/impact-check
```

**2. Install** as described above.

**3. Set the workstation up.** The first run needs the storage roots and the contact that
colleagues see in messages. The command checks Ubuntu, the tools, Docker and the file system of
the storage roots, then creates the shared group, the folders, the settings file and the SSH
rules.

```
sudo impact-workstation-setup --dry-run \
     --shared-roots /mnt/disk_a/shared,/mnt/disk_b/shared \
     --admin-contact "Workstation Admin (admin@example.org)"
sudo impact-workstation-setup \
     --shared-roots /mnt/disk_a/shared,/mnt/disk_b/shared \
     --admin-contact "Workstation Admin (admin@example.org)"
```

Before the SSH rules take effect, the command proves that the administration account and root
keep exactly their SSH settings, and it puts the previous state back if a check fails. At the
end it asks you to keep this session open and to log in from a second window: do that before
you close anything. Note the number of the group it prints: a rebuilt workstation needs it
(`--gid`). A later run changes only the values you give, for example
`sudo impact-workstation-setup --port-max 8850`; its "How to undo" is the one command that sets
the previous values again (`sudo impact-workstation-setup --port-max 8830`), which also writes
the SSH rules for them. When there were no SSH rules before the run (an earlier run removed them
with `--remove-ssh-rules`), the line that removes them again follows after that command. If a
run is ended by force during the SSH step, the next run puts the previous rules back first and
repeats the change with all checks.

**4. Register the model.** This writes `/srv/impact/models/Example-Model/model.conf`, an empty
`extras/` folder, and the folders `outputs` and `inputs/synthpop` on the storage root with the
group rules.

```
sudo impact-add-model Example-Model git@github.com:example-org/Example-Model.git \
     --storage /mnt/disk_a/shared --storage-name Example --dry-run
sudo impact-add-model Example-Model git@github.com:example-org/Example-Model.git \
     --storage /mnt/disk_a/shared --storage-name Example
```

Files that the model needs and that are not on GitHub go into `extras/`, at their path inside
the repository, owned by root and readable for the group: folders with mode 2750, files with
mode 640. Create each folder first, then put the file in it, then check the model:

```
sudo install -d -m 2750 -o root -g impact /srv/impact/models/Example-Model/extras/inputs
sudo install -m 640 -o root -g impact table.csv /srv/impact/models/Example-Model/extras/inputs/table.csv
sudo impact-check-model Example-Model
```

When the storage folder of the model holds files from before these rules, give them the group
rules once (`--dry-run` prints counts; a large tree takes long, see `--help` for a run that
continues after you log out). The command is safe to stop and to start again: the run that
completes the work names in its "How to undo" the backups of every stopped run, newest first.

```
sudo impact-share-folder /mnt/disk_a/shared/Example --dry-run
sudo impact-share-folder /mnt/disk_a/shared/Example
```

**5. Enrol the colleague.** At the first REMOTE start the GUI shows Alice her public key and
its fingerprint (a short code such as `SHA256:...` that identifies the key). She sends both to
you. The GitHub name `alice-example` would also work as a Linux name; this example chooses the
account `alice` with `--account`.

```
sudo impact-add-user alice-example --account alice --key-file /tmp/alice.pub \
     --fingerprint SHA256:<the fingerprint Alice sent> --dry-run
sudo impact-add-user alice-example --account alice --key-file /tmp/alice.pub \
     --fingerprint SHA256:<the fingerprint Alice sent>
```

The command creates the account with a locked password, adds it to the shared group and to
`docker`, confirms with the SSH server that the rules of the group apply, and only then
installs the key; it creates `~/Repositories`, notes the GitHub name, and at the end prints the
text to send to Alice. One key pair belongs to one person: a key that is already a login key of
another account is refused. The key login of an account with a locked password needs
`UsePAM yes` in `/etc/ssh/sshd_config` (the setting of Ubuntu); `impact-add-user` and
`impact-check` report it when it is off. Without `--fingerprint` it shows the fingerprint and asks you to
compare it with the one Alice sent. With `--github` the command takes the key from
`https://github.com/alice-example.keys`, the list of public keys that GitHub shows for an
account.

If the command stops after it has created the account (an error, Ctrl+C, a closed window), the
account record says "enrolment not finished"; `impact-list-users` and `impact-check` show it,
and `impact-key` refuses the account until then. Run the same `impact-add-user` command again:
it checks every part and does the missing steps. Or close the account with
`sudo impact-remove-user alice`. A Ctrl+C that comes while the account is being created takes
effect right after the account and its record are written, so the one never exists without the
other.

**6. Give Alice her first working copy.** Alice presses "Add repository" in the GUI, which runs
`impact-get-repo Example-Model` in her account. You can do the same for her:

```
sudo impact-give-repo alice Example-Model --dry-run
sudo impact-give-repo alice Example-Model
```

The copy is a fresh clone from GitHub in `/home/alice/Repositories/Example-Model`, made with
Alice's own key copy (or over anonymous HTTPS for a public repository while she has none). The
extra files are added and listed in the copy's own ignore list, so git never commits them. The
messages of `impact-get-repo` appear inside a frame of lines marked `|`; after Ctrl+C the frame
still shows everything `impact-get-repo` reports about its own stop before
`impact-give-repo` reports its own.

**7. Check the whole setup again.**

```
sudo impact-check
```

## The commands

| Command | Run by | What it does |
|---|---|---|
| `install.sh`, `uninstall.sh` | administrator | Install the commands to `/opt/impact`, or remove them again. |
| `impact-workstation-setup` | administrator | Creates the shared group, the folders, the settings file and the SSH rules after checking Ubuntu, Docker and the storage; later runs change single settings; `--remove-ssh-rules`. |
| `impact-check` | administrator | Health check in 15 numbered blocks with a summary; reads only, prints no secret, runs also before the installation; `--mask` hides addresses and host names. |
| `impact-add-user <GitHub name>` | administrator | Enrols a colleague: account with locked password, groups, login key, repository folder, SSH rules confirmed. |
| `impact-key list\|add\|replace\|remove <account>` | administrator | Shows and manages the login keys of a person with their fingerprints. |
| `impact-list-users` | administrator | Lists the enrolled people with numbers, groups, keys and last login. |
| `impact-remove-user <account>` | administrator | Closes the account of a person who leaves (expired, keys moved away, groups, sessions, containers, lingering, cron and at jobs) and keeps its number; `--delete` deletes it. |
| `impact-add-model <model> <GitHub address>` | administrator | Registers a model with its `model.conf`, `extras/` and storage folders. |
| `impact-check-model <model>` | administrator | Checks the model file, the extras (names, rights, files over 50 MB) and the extras rule in every working copy. |
| `impact-share-folder <folder>` | administrator | Gives existing content on the shared storage the group rules, with a backup of the previous rights; `--repair`, `--restore`. |
| `impact-give-repo <account> <model>` | administrator | Makes a working copy of a model for a person (runs `impact-get-repo` as that person). |
| `impact-export-state` | administrator | Writes the backup archive for a rebuild (settings, accounts with numbers, keys, host keys, models with extras). The archive is secret. |
| `impact-clean-images` | administrator | Lists the Docker images of the GUI that nobody needs any more; `--remove` removes them after a question. |
| `impact-get-repo <model>` | each colleague, through the GUI | Makes the person's own working copy of a model. |
| `impact-update-setup <model>` | each colleague, through the GUI | Brings the folder `docker_setup` of the person's copy up to the state on GitHub. |

`build-archive.sh` is no command of the workstation: it builds the delivery archive on a
developer's computer.

Exit codes of all commands: 0 done or nothing to do; 1 a check or step failed; 2 wrong usage;
3 the workstation is not prepared (settings file missing or invalid); 4 the target exists or the
request conflicts with the current state; 5 no access (for example GitHub refused the key);
6 network problem; 129, 130 and 143 the command was stopped by a signal (a closed session,
Ctrl+C, a request to end). `impact-check` uses 0 for all OK, 1 for at least one WARN and 2 for
at least one FAIL. The two commands for colleagues end with one line for the GUI:
`IMPACT_RESULT status=<ok|error> code=<exit code> path=<path> reason=<one word>`.

## The settings file

`/etc/impact/impact.conf` holds one `KEY=value` per line; `impact-workstation-setup` writes it,
and the GUI reads it too. It is read as text and never executed. The exact rules, the same for
the commands and for the GUI: UTF-8 text (a byte order mark at the start is allowed); each line
ends with LF or CR LF, and no other carriage return or zero byte may appear; spaces and tabs
around key and value are removed (they are the only blanks); a line whose first character
after blanks is `#` is a comment; each key may appear only once. Numbers have no sign and no
leading zero; a contact text has 1 to 80 characters (an emoji counts as one) without control
characters, invisible format characters or spaces at its ends. The file
`workstation/etc/impact.conf.example` explains every key, and
`tests/workstation/vectors/` holds the test cases that both readers share.

## Tests

The tests are plain bash and need no test framework. `tests/workstation/README.md` explains
them for a reader new to bash testing.

```
bash tests/workstation/run-tests.sh unit
```

runs the unit tests: the pure functions (settings parser, name rules, key checks, version
comparison, masking and more). They need no root rights and change nothing.

The system tests and the end-to-end scenario run the real commands as root and change the
machine (accounts, groups, SSH rules). Run them only on a disposable machine, for example a
fresh virtual machine or a GitHub runner, and confirm that with `IMPACT_TEST_DISPOSABLE=yes`:

```
sudo env IMPACT_TEST_DISPOSABLE=yes bash tests/workstation/run-tests.sh system
sudo env IMPACT_TEST_DISPOSABLE=yes bash tests/workstation/scenario.sh
```

The scenario walks through the life of a workstation once: installation, setup, a model, two
colleagues, key login and tunnels through a real SSH server, working copies from a local
repository that stands in for GitHub, shared storage, the health check, the removal of a
colleague, the backup archive and the removal of the commands. Docker parts run when a Docker
daemon answers and are reported as skipped otherwise.

The scripts are checked with `shellcheck` (version 0.9):

```
shellcheck -x -s bash workstation/bin/* workstation/*.sh workstation/lib/*.sh \
    tests/workstation/*.sh tests/workstation/lib/*.sh tests/workstation/unit/*.sh tests/workstation/system/*.sh
```
