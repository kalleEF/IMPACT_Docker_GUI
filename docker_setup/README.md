# docker_setup: the Docker image of this model

This folder holds everything that is needed to build the Docker image of this model and to
start RStudio Server from it. The IMPACT Docker GUI uses it on a person's own PC (LOCAL) and
on the shared Linux workstation (REMOTE). This file explains what the folder contains, what
happens when an image is built and when a container starts, and how to change and test it.

Words used in this file:

| Word | Meaning |
|------|---------|
| image | A packed, read-only copy of a Linux system with R, RStudio Server, the R packages and this model. It is built once from a Dockerfile. |
| container | A running copy of an image. Each person and model has its own container. Changes inside a container disappear when it is removed, except in mounted folders. |
| Dockerfile | A text file with the steps that build an image. |
| layer | Docker stores the result of every step of a Dockerfile as a layer. An image is a stack of layers. A file that a later step changes or deletes stays in full in the earlier layer. |
| build context | The set of files that Docker may copy into an image. For the model image it is the whole repository folder, minus what `.dockerignore` excludes. |
| mount | A folder of the computer that Docker shows inside the container, for example the repository folder or a folder with model results. Files in it stay on the computer and can belong to several people. |
| UID, GID | Linux stores the owner of every file as two numbers: the user number (UID) and the group number (GID). |
| start-up script | A script that the image runs once at every container start, before RStudio Server starts. |
| Rocker | The project that publishes the base image `rocker/rstudio`, on which these images are built. |
| SSH, host key | SSH is the encrypted connection git uses to reach GitHub. Every SSH server has a key of its own, its host key; a client that knows it notices when another computer pretends to be that server. |

## 1. Files in this folder

| File | Purpose |
|------|---------|
| `Dockerfile.prerequisite.IMPACTncdGER` | Builds the prerequisite image: Rocker's RStudio image plus system packages and R packages. |
| `apt-packages.txt` | The system packages of the prerequisite image, each with a fixed version (`name=version`). |
| `install_packages.sh` | Installs the packages of `apt-packages.txt` during the prerequisite build. |
| `r-packages.txt` | The R packages of the prerequisite image, and the date of the package snapshot they come from. |
| `update-apt-packages.sh`, `update-apt-packages.ps1` | Write new package versions into `apt-packages.txt` after a build (section 7). |
| `Dockerfile.IMPACTncdGER` | Builds the model image: the prerequisite image plus this repository, the model's R package and the start-up scripts. |
| `entrypoint.sh` | The first program of every container (section 3). |
| `git-identity.sh` | Start-up script: prepares SSH and git for GitHub. |
| `impact-ready.sh` | Start-up script: writes the ready marker when the start-up has finished. |
| `impact_model.json` | A short description of this model for the GUI (section 5). |
| `docker_build_push.ps1`, `bash/docker_build_push.sh` | Build an image by hand and, if wanted, upload it to Docker Hub (section 2). |
| `LICENSE` | The licence of this folder. |
| `README.md` | This file. |

One file belongs to the set-up and lies outside this folder: `.dockerignore`, directly in the
repository folder (section 6).

The repository of the IMPACT Docker GUI keeps a reference copy of this folder. There, two more
files exist: `REFERENCE.md`, which explains how the copies are kept in step, and
`dockerignore_for_repository_root`, the text of the `.dockerignore` file.

## 2. The two images

The model image is built in two stages, because the first stage takes long and changes
rarely.

### 2.1 The prerequisite image

- **Built from:** `Dockerfile.prerequisite.IMPACTncdGER`, with this folder (`docker_setup`) as
  build context.
- **Content:** `rocker/rstudio` in the version named in its `FROM` line (Ubuntu Linux, R and
  RStudio Server), plus the system packages of `apt-packages.txt`, the R packages of
  `r-packages.txt` from a fixed snapshot of the Posit package repository, and the R package
  `CKutils` from GitHub at a fixed commit.
- **When:** only when a package list or the Rocker version changes. The build takes long,
  because it compiles many R packages and their dependencies.
- **Who:** the maintainer of the model, who then uploads it to Docker Hub under the name in
  the `FROM` line of `Dockerfile.IMPACTncdGER` (today
  `kalleef/prerequisite.impactncdger:latest`). The model image is built on top of the image
  of that name. When a model image build fails, the GUI offers to build the prerequisite
  image locally under that same name and to try again.

Build it by hand, in the `docker_setup` folder:

```bash
bash bash/docker_build_push.sh --image-name prerequisite.impactncdger --image-tag latest Dockerfile.prerequisite.IMPACTncdGER
# add --push to upload it to Docker Hub
```

In PowerShell:

```powershell
.\docker_build_push.ps1 Dockerfile.prerequisite.IMPACTncdGER -ImageName prerequisite.impactncdger -ImageTag latest
# add -Push to upload it to Docker Hub
```

The image built this way is called `prerequisite.impactncdger:latest` on your computer. The
model image is built on the name in the `FROM` line of `Dockerfile.IMPACTncdGER`
(`kalleef/prerequisite.impactncdger:latest`), so a local test build needs that name as well
(section 7 shows the whole test).

### 2.2 The model image

- **Built from:** `Dockerfile.IMPACTncdGER`, with the whole repository folder as build
  context.
- **Steps:**
  1. records the repository folder name (the build value `REPO_NAME`) in `/etc/environment`
     as `CONTAINER_REPO_NAME`;
  2. copies the repository into `/home/rstudio/<repository folder name>`;
  3. joins the large files that are stored on GitHub in pieces ("chunks"), as listed in
     `simulation/large_files_indx.csv`;
  4. gives that folder to the user `rstudio` and gives everyone read, write and run access to
     it;
  5. installs `git-identity.sh` as `/etc/cont-init.d/git-identity` and `impact-ready.sh` as
     `/etc/cont-init.d/zz-impact-ready` (the start-up scripts);
  6. sets git to use SSH for GitHub addresses;
  7. builds and installs the model's R package from `Rpackage/IMPACTncd_Ger_model_pkg`;
  8. installs `entrypoint.sh` as the entry point;
  9. carries the label `impact.setup_version=2`, the version of this folder.
- **When:** the GUI builds it.
  - LOCAL: when the image does not exist yet, or when "Rebuild image" is ticked.
  - REMOTE (GUI 2.1): one image per person and model, on the workstation. The GUI rebuilds it
    when `docker_setup` changed or the setup version differs, and offers a rebuild when the R
    package folder changed. The first build of an image is always made from scratch.
- **How the GUI builds it**, in the repository folder:

  ```bash
  docker build --build-arg REPO_NAME=<repository folder name> -f docker_setup/Dockerfile.IMPACTncdGER -t <image name> .
  ```

  Use the same command for a build by hand. `REPO_NAME` must be the name of the repository
  folder, because the GUI mounts the repository under `/home/rstudio/<that name>`.
  `docker_build_push.*` passes no `REPO_NAME`, so an image built with it uses the default
  name written in the `ARG REPO_NAME` line of the Dockerfile. The comment lines at the end
  of `Dockerfile.IMPACTncdGER` give other build commands; they are out of date, so use the
  command above.

## 3. What happens when a container starts

Docker starts `entrypoint.sh` as root. It prepares the account and the RStudio settings and
then hands over to `/init`, the start program of the Rocker image. `/init` runs the start-up
scripts in `/etc/cont-init.d` one after the other, in name order, and then starts RStudio
Server.

```
docker run
  `-- entrypoint.sh                 (this folder)
       1. remove the ready marker of an earlier start
       2. user and group numbers    (only with IMPACT_UID and IMPACT_GID)
       3. RStudio settings          (which project to open)
       4. exec /init
            |-- 01_set_env           (Rocker)
            |-- 02_userconf          (Rocker: password, USERID, GROUPID)
            |-- git-identity         (this folder)
            |-- zz-impact-ready      (this folder: writes /run/impact-ready)
            `-- RStudio Server on port 8787
```

### 3.1 `entrypoint.sh`

1. **Ready marker.** It deletes `/run/impact-ready`, so a marker from an earlier start of the
   same container never counts.
2. **Mounts.** It reads the list of mounts of the container and checks the home folder.
   When `/home/rstudio` itself lies on a mount (a mount at `/home/rstudio` or at `/home`,
   for example typed into the GUI's custom parameters), the script changes nothing in the
   home folder at all, in any mode, and writes one `WARNING` line about it.
3. **User and group numbers.**
   - Neither `IMPACT_UID` nor `IMPACT_GID` is set (LOCAL, and every GUI before 2.1): the
     numbers stay as they are, and Rocker's `USERID` and `GROUPID` reach Rocker unchanged.
     When `USERID` differs from 1000 and mounts lie in the home folder, a `WARNING` line
     names them: Rocker is about to change the owner of everything in them (section 3.2).
     The entries of the home folder keep their owners as well, apart from `.rstudio` and
     `.config` (step 5). A mount added below another entry, for example at
     `.local/share/extra`, then leaves the folders that Docker creates for it (`.local`,
     `.local/share`) to root. RStudio then cannot create its state folder
     `.local/share/rstudio`, and its sessions can fail to start. A `WARNING` line names
     such folders (`WARNING: these folders lead to a mount and do not belong to 'rstudio'
     ...`); leave such mounts out in LOCAL.
   - Both are set (REMOTE with GUI 2.1), in this order:
     1. the script checks that each is a whole number from 1000 to 60000;
     2. it changes the numbers of the user `rstudio` and of its group `rstudio` in the
        account files `/etc/passwd` and `/etc/group`;
     3. it checks with `id rstudio` that the new numbers are in place. When they are not,
        the container stops here with exit code 70, before any owner has changed;
     4. it gives the new numbers to the folder entry `/home/rstudio` itself (nothing inside
        it) and to a short fixed list of small entries that belong to the image, with their
        content: `.bashrc .bash_logout .profile .config .rstudio .local .cache .ssh
        .gitconfig .Rprofile .Renviron .Rhistory R`. An entry that is a mount or a symbolic
        link stays as it is, and so does a file with a second name elsewhere (a hard
        link). In an entry with a mount inside it, everything except the mounts changes
        owner. The script goes down only the folders that lead to a mount, one level at a
        time, and stops at the mount itself. For a mount at `.local/share/extra`, that
        gives `.local` and `.local/share` (Docker creates them for root, and RStudio keeps
        its state there) to the new numbers; for a mount at `.config/extra`, also the
        image's `.config/rstudio` with RStudio's preferences file, so RStudio can still
        save its preferences. The log names the mounts in such an entry. The script never
        walks through a mount, so the repository, the results and the storage folders
        keep every owner and every access right;
     5. it removes Rocker's own variables `USERID` and `GROUPID`, so Rocker makes no change
        of its own.
   - Only one of the two is set, or a value is wrong: the container stops with exit code
     64. A user number that another account of the image already has stops it with exit
     code 65; a failed change of the account files with exit code 70. The log then has a
     line in which `ERROR:` follows the time stamp, for example
     `[ENTRYPOINT] 2026-11-24 21:06:05 - ERROR: IMPACT_UID=12 is not valid. ...`. A group
     number that another group of the image already has is accepted: both group names then
     stand for that number.
4. **Repository folder.** The name comes from `/etc/environment` (written at build time),
   else from `CONTAINER_REPO_NAME`, else the default `IMPACT-NCD-Germany_Base`.
5. **RStudio settings.** It looks for the `.Rproj` file in the repository folder and writes
   RStudio's settings so that RStudio opens that project and starts in the repository
   folder. Then it gives `.rstudio` and `.config`, with their content, to the numbers
   `rstudio` has at that moment, in every mode (the settings files were written by root).
   It writes no settings file that is a mount, lies in a mount or is reached through a
   symbolic link; a mount elsewhere in the same settings folder does not stop it. The
   change of owner follows the rules of step 3.4.
6. **`UMASK`.** When `UMASK` is set, Rocker adds a line to `/home/rstudio/.Rprofile` as
   root. When that file is a symbolic link, a mount or a file with a second name (hard
   link), or the home folder lies on a mount, the script removes `UMASK` and writes a
   `WARNING` line, so nothing is written outside the container's own files.
7. **Hand-over.** `exec /init` replaces the script with Rocker's start program.

### 3.2 The start-up scripts

The Rocker start program (the "s6-overlay" init system) runs each file in `/etc/cont-init.d`
once per start, as root, sorted by name. These scripts receive the variables of `docker run
-e` only when they ask for them explicitly; `git-identity` and `zz-impact-ready` need none.

1. `01_set_env` (Rocker) copies the container's variables into R's settings file
   `Renviron.site`, so R sessions in RStudio see them. `PASSWORD` is left out.
2. `02_userconf` (Rocker) sets the password of `rstudio`: the value of `PASSWORD`, or a
   random one that it prints to the container log. When `USERID` or `GROUPID` is set and
   differs from 1000, it renumbers the account, and for `USERID` it deletes and recreates
   the user and changes the owner of everything in `/home/rstudio`, mounted folders
   included. With GUI 2.1 in REMOTE this never happens, because `entrypoint.sh` removed both
   variables. In LOCAL the GUI passes 1000 for both, which changes nothing. GUI 2.0 passes
   the numbers of the workstation account in REMOTE, so there Rocker still changes the owners
   at every start, as before.
3. `git-identity` (from `git-identity.sh`) writes GitHub's three published host keys into
   `/etc/ssh/ssh_known_hosts` and `/home/rstudio/.ssh/known_hosts`, so SSH can check that it
   talks to the real GitHub. No network is needed for this. At every start it drops every
   other line for `github.com` from these files (also lines with capital letters, several
   names, patterns or in coded form). It also stores the three keys under the name
   `github.com-published` and writes `/etc/ssh/ssh_config.d/impact-github.conf`, which
   makes SSH look up the key of `github.com` and of `ssh.github.com` under that name
   (`HostKeyAlias`). `ssh.github.com` is the server GitHub documents for networks that
   block port 22; it answers on port 443 with the same published keys. In
   `/etc/ssh/ssh_known_hosts` the three keys are stored once more under the names
   `ssh.github.com` and `[ssh.github.com]:443` (the form a known hosts file uses for a
   port other than 22), for the case that SSH applies no rule (section 3.4); other lines
   for these two names are dropped as well. The rule applies
   to each name in any mix of capital and small letters (`GitHub.com`, `GITHUB.COM`,
   `SSH.GitHub.com`) and with a final dot (`github.com.`), so a remote address such as
   `git@GitHub.com:owner/repo.git` or `ssh://git@ssh.github.com:443/owner/repo.git` is
   checked in the same way. It applies to the name as it was typed and also to the server
   an SSH settings file sends it to. So it also holds for GitHub's port 443 set-up in a
   person's `~/.ssh/config` (`Host github.com`, `HostName ssh.github.com` and
   `Port 443`), and for a name of the person's own with `HostName ssh.github.com`. With
   the usual settings, keys that another program writes for `github.com`, for example the
   GUI's key scan, are therefore not used; section 3.4 names the cases in which they are.
   The log line that starts with
   `SSH uses the name github.com-published for the host key of github.com`
   confirms that SSH follows the rule; a `WARNING` line appears when it does not.
   `git-identity` also copies the
   person's private key from `/keys/` into `/home/rstudio/.ssh/` with access mode 600,
   sets git's `core.sshCommand` to the same SSH options the GUI uses, and sets the git
   user name and e-mail address when none is set.
   It never writes into a mount, and never writes or reads through a symbolic link: each
   new file is written under a new, unused name and then renamed into place, and a link,
   a folder or a file with a second name where it would write stays as it is, with an
   `ERROR` line in the log.
4. `zz-impact-ready` (from `impact-ready.sh`) writes the ready marker `/run/impact-ready`.
   The name starts with `zz`, so it sorts after all other scripts and runs last. A start-up
   script added later needs a name that sorts before it.

A start-up script that fails does not stop the container. The container log shows a line
with its exit code for every script, for example `[cont-init.d] git-identity: exited 0.`

### 3.3 The ready marker

The GUI (version 2.1, REMOTE) waits for `/run/impact-ready` before it sets the RStudio
password and configures git inside the container.

- **Guaranteed:** all start-up scripts before it have ended, so the GUI and the scripts never
  change the same settings at the same time.
- **Not guaranteed:** that those scripts succeeded (see the log lines above), and that
  RStudio Server already answers. RStudio Server starts after the marker is written; the GUI
  checks the port itself.

### 3.4 After the start

- **REMOTE, GUI 2.1:** the container starts without `PASSWORD`. After the marker appears, the
  GUI sends the password straight into the password program of the container (`chpasswd`).
  The password is then stored only as a one-way code, and it appears neither in the
  container's settings nor in its log. A restart of the container (`docker restart`) runs
  Rocker's start-up again and sets a new random password; set the password again with
  "Set new password" in the GUI.
- **LOCAL:** the GUI passes the password with `PASSWORD`, as in earlier versions.
- In both modes the GUI then copies the SSH key, writes the same `core.sshCommand` as
  `git-identity`, and rewrites `/home/rstudio/.ssh/known_hosts` with the keys its own key
  scan of `github.com` receives. Nobody checks those keys, and the image itself needs no
  key scan. With the usual settings,
  whichever of the two runs last, SSH accepts a server under the name `github.com` or
  `ssh.github.com` (in any spelling of section 3.2, also when `~/.ssh/config` sends
  `github.com` or a name of its own to `ssh.github.com` on port 443) only with one of
  GitHub's published keys (`HostKeyAlias`, section 3.2). The tests run the GUI's own
  command while a false `github.com` can be reached, also under `ssh.github.com` on port
  443, and git refuses it afterwards. The content of `known_hosts` differs with the order:
  after the GUI's step it holds the scanned lines, which SSH then does not use for these
  names, and the next start of the container replaces them with the published keys.
- SSH skips the rule of section 3.2 in two set-ups, and then looks up the key under the
  name it connects to:
  - `ssh` is started with `-F` and another settings file. SSH then reads no system-wide
    settings, and the rule with them.
  - a person's `~/.ssh/config` sets a `HostKeyAlias` of its own for one of GitHub's
    servers. SSH reads that file first and keeps the first value it finds.

  For `ssh.github.com` the published keys stored under `ssh.github.com` and
  `[ssh.github.com]:443` still apply, and the GUI's scan writes no line for these names.
  So a false `ssh.github.com` is refused under `-F`, on port 22 and on port 443, and with
  `HostKeyAlias ssh.github.com`. The tests show this before and after the GUI's step.
- These cases stay open. In each of them SSH accepts a false server:
  - **`github.com` under `-F`, and a person's own `HostKeyAlias github.com`, after the
    GUI's step** (also when the remote is written `GitHub.com`). The GUI's scan runs last
    and writes the keys it received under `github.com` into the person's known hosts
    file, and SSH then uses them. Before the GUI's step both are refused. The image cannot prevent this; only a GUI without the
    key scan closes it.
  - **Under `-F`, a name that is stored nowhere:** a name with a final dot
    (`github.com.`, `ssh.github.com.`) or `github.com` on port 443. SSH accepts such a
    server on first contact, and every new container makes a first contact.
  - **A person's own `HostKeyAlias` with a name nobody stores** (for example
    `HostKeyAlias my-github`): accepted on first contact, at every start, with or
    without the GUI.
  - **`/home/rstudio/.ssh` is a mount**, for example the person's own `.ssh` folder
    mounted with custom parameters. `git-identity` writes nothing there. The GUI's step
    replaces GitHub's keys in that `known_hosts` with the scanned ones and changes the
    owner of the folder and its files to `rstudio`, and an SSH outside the container that
    reads the file then trusts the scanned keys. SSH inside the container still refuses
    the false server.
  - **Remotes outside the rule:** an address in numbers (an IP address), a name of the
    person's own in `/etc/hosts`, and `gist.github.com` (GitHub's published host keys
    name `github.com` only). SSH checks them like any other server and accepts a key on
    first contact.

  **Do not set `HostKeyAlias` for GitHub's servers in `~/.ssh/config`, do not start
  `ssh` with `-F`, and do not mount a `.ssh` folder into the container.**
- Some settings of the person's own switch the check off by their own choice, and the
  image does not try to prevent them: `StrictHostKeyChecking no` in `~/.ssh/config` (SSH
  then connects also to a server whose key differs; git with the GUI's SSH command still
  refuses it, because that command sets `StrictHostKeyChecking=accept-new` first), the
  same option in a repository's own `core.sshCommand` (used by git when the variable
  `GIT_SSH_COMMAND` of the GUI is not set), and
  `GlobalKnownHostsFile` with a file of the person's own (SSH then ignores the published
  keys of `/etc/ssh/ssh_known_hosts`, accepts a false server on first contact and stores
  its key under `github.com-published` in `/home/rstudio/.ssh/known_hosts`; that key
  stays trusted, also after the setting is removed, until the next start of the
  container).

## 4. Environment variables the image understands

Pass them with `docker run -e NAME=value`. The GUI sets them; a build or start by hand needs
the same ones.

| Variable | Read by | Meaning |
|----------|---------|---------|
| `IMPACT_UID` | `entrypoint.sh` | The user number for `rstudio`, normally the number of the person's account on the workstation. Whole number from 1000 to 60000. Give it together with `IMPACT_GID`, or leave out both. |
| `IMPACT_GID` | `entrypoint.sh` | The group number for `rstudio`, normally the number of the shared group that owns the storage folders. Same rules. New files get the access mode 644 (folders 755), because R sessions and the RStudio terminal run with the umask 022. Colleagues can change them only when the storage folder has a default access list (ACL) that gives the group write access; R's `file.copy()` keeps the access mode of the source file. Repair a folder without that list with `impact-share-folder --repair`. |
| `USERID`, `GROUPID` | Rocker (`02_userconf`) | Rocker's own way to set the numbers. When `USERID` differs from 1000, Rocker deletes and recreates the user and changes the owner of everything in `/home/rstudio`, mounted folders included (special access bits such as setuid are lost). Removed by `entrypoint.sh` when `IMPACT_UID` and `IMPACT_GID` are set. Without them, they pass unchanged, and `entrypoint.sh` writes a `WARNING` that names the mounts concerned. The GUI passes 1000 in LOCAL, which changes nothing; GUI 2.0 passes the workstation account's numbers in REMOTE. |
| `PASSWORD` | Rocker (`02_userconf`) | The RStudio password of `rstudio`. Without it Rocker sets a random password and prints it to the container log. |
| `DISABLE_AUTH` | Rocker (`02_userconf`) | `true` switches off the RStudio sign-in. The GUI passes `false`. |
| `ROOT`, `UMASK`, `TZ`, `LANG` | Rocker (`02_userconf`) | Administrator rights for `rstudio`, the default access mode of new files, the time zone and the language. The GUI passes none of them. For `UMASK` other than 022, Rocker adds a line to `/home/rstudio/.Rprofile` as root; `entrypoint.sh` removes `UMASK` when that file cannot be written safely (section 3.1, step 6). |
| `CONTAINER_REPO_NAME` | `entrypoint.sh` | The repository folder name below `/home/rstudio`. The value written into the image at build time takes precedence. |
| `GIT_SSH_COMMAND` | git | The SSH command git uses. The GUI passes the same options as `git-identity.sh` writes. |
| `SYNC_ENABLED`, `REPO_SYNC_PATH` | `entrypoint.sh` | Accepted and without effect. The repository is used where Docker mounts it. |

Exit codes of `entrypoint.sh`: 64 (a missing or wrong value of `IMPACT_UID` or `IMPACT_GID`),
65 (the user number belongs to another account of the image), 70 (the account files could not
be changed, or the check afterwards failed). `docker logs <container>` shows the reason.
A container started with `docker run --rm`, as the GUI starts its containers, is removed
together with its log the moment `entrypoint.sh` ends. To read the reason, run the same start
command again without `--rm`, then `docker logs <container>`, and remove the container
afterwards with `docker rm <container>`.

## 5. `impact_model.json`

A short description of the model, read by the GUI (version 2.1) in LOCAL and REMOTE. Older
versions of the GUI ignore it. Example:

```json
{
  "setup_version": 2,
  "short_name": "base",
  "storage_name": "Base",
  "rpackage_dir": "Rpackage"
}
```

| Key | Meaning | Rules |
|-----|---------|-------|
| `setup_version` | The version of this `docker_setup` folder. The GUI requires a minimum version in REMOTE. | A whole number without quotes. `2` for this folder; the same number as the label `impact.setup_version` in `Dockerfile.IMPACTncdGER`. |
| `short_name` | The model part of the address in the browser, for example `http://base.remote.impact.localhost:18787`. | Small letters `a` to `z`, digits and hyphens, at most 30 characters, starting and ending with a letter or digit. |
| `storage_name` | The name of the model's folder on the storage disks of the workstation, the folder that holds `outputs` and `inputs/synthpop`. | Exactly the folder name, with the same capital and small letters, without any `/`. |
| `rpackage_dir` | The folder of the model's R package, relative to the repository folder. The GUI watches it to offer a rebuild. | `Rpackage` for the IMPACT models. |

The values of the three models:

| Model | `short_name` | `storage_name` |
|-------|--------------|----------------|
| GLP1 | `glp` | `GLP1` |
| Meat | `meat` | `Meat` |
| Base | `base` | `Base` |

Write the file as plain JSON: double quotes around keys and texts, a comma between entries
and none after the last one, no comments, saved as UTF-8 text.

## 6. `.dockerignore`

The file `.dockerignore` lies directly in the repository folder, next to `docker_setup`. Docker
reads it before every build of the model image and leaves the files it names out of the build
context, so they never reach the image. Each line of the file has its own explanation.

It leaves out:

- `.git`, the history of the repository;
- the content of `outputs` and of `inputs/synthpop` (the two folders themselves stay, empty);
- RStudio's project state `.Rproj.user`, and R's `.Rhistory` and `.RData`, in any folder;
- every file named `.env`, in any folder, for example `docker_setup/.env` with a Docker Hub
  token. Everyone who can use an image can read every file in it.

Inside a running container these files are still there: the GUI mounts the repository folder,
and the mounted folder shows the files on disk.

The file assumes that the results folder is `outputs` and the synthetic populations are in
`inputs/synthpop`, both directly in the repository folder, and that the image build needs no
file in them. If a model repository differs, change the two lines.

To see its effect, look for the line `transferring context` in the build output: it gives the
size of the build context. The prerequisite image uses `docker_setup` as its build context,
so the file has no effect there.

## 7. Updating the package lists

All package changes go into the prerequisite image. Test a change on your computer before
it is uploaded, because the model images of all colleagues are built on the uploaded image:

1. Build the prerequisite image (section 2.1), without `--push`.
2. Give it the name the model Dockerfile uses:
   `docker tag prerequisite.impactncdger:latest kalleef/prerequisite.impactncdger:latest`.
   This changes only the copy on your computer.
3. Build the model image on top of it (section 2.2, or "Rebuild image" in the GUI in LOCAL)
   and run the checks of section 8.
4. Only then upload it: run the build of step 1 again with `--push` (PowerShell: `-Push`).
   After the upload, colleagues rebuild their model images (GUI: "Rebuild image").

To go back on your computer after a failed test, download the uploaded image again:
`docker pull kalleef/prerequisite.impactncdger:latest`.

**System packages (`apt-packages.txt`).** One package per line as `name=version`. Lines that
start with `#` are comments. During the build, `install_packages.sh` installs each package in
the listed version. When that version is no longer offered, it installs the version that is
offered and lists every such case at the end of the build output under
`PACKAGE VERSION UPDATES DETECTED`. To write these versions into the file, save the build
output and pass it to the update script, in the `docker_setup` folder:

```bash
docker build -f Dockerfile.prerequisite.IMPACTncdGER --progress=plain --no-cache -t prereq-test . 2>&1 | tee build.log
bash update-apt-packages.sh --file build.log
```

```powershell
docker build -f Dockerfile.prerequisite.IMPACTncdGER --progress=plain --no-cache -t prereq-test . 2>&1 | Tee-Object build.log
.\update-apt-packages.ps1 -BuildLogFile build.log
```

Both scripts also have an interactive mode (`--interactive`, `-Interactive`). To add a
package, add a line `name=version`; `apt-cache policy <name>` inside the image shows the
versions on offer.

**R packages (`r-packages.txt`).** The first line gives the date of the package snapshot,
for example `# CRAN snapshot date: 2025-07-31`. All packages come from the Posit package
repository as it was on that date. To move to newer versions, change the date. To add a
package, add its name on a line of its own. `CKutils` comes from GitHub at the commit named in
`Dockerfile.prerequisite.IMPACTncdGER`; change that line to use another commit.

## 8. Testing a changed image

Test every change on a branch, before it reaches the branch that colleagues use.

**Automatic tests.** The repository of the IMPACT Docker GUI contains tests for this folder
in `tests/docker_setup/`; run them in a clone of that repository. They build a small test
image with the start-up scripts installed exactly as `Dockerfile.IMPACTncdGER` installs
them, start real containers and check the user and group numbers, that no mounted file
changes, the RStudio sign-in, the ready marker and git. They run on a Linux computer with
Docker and bash, and need the internet on the first run. On a Windows PC that is WSL 2
(the Linux part of Windows that Docker Desktop also uses) or the shared workstation; the
job `docker-setup-tests` in `.github/workflows/test.yml` of the GUI repository runs them as
well. To test the `docker_setup` folder of a model repository:

```bash
IMPACT_DOCKER_SETUP_DIR=/path/to/model-repository/docker_setup bash tests/docker_setup/run-tests.sh
```

The tests leave files named `.env` (for example `docker_setup/.env` with a Docker Hub token)
out of their test image. They use a stand-in for the model's prerequisite image and
repository; they do not build the real model image. To run them on the real prerequisite
image, download it and name it in `IMPACT_TEST_BASE_IMAGE`; the tests use that image as it
is and never change it:

```bash
docker pull kalleef/prerequisite.impactncdger:latest
IMPACT_TEST_BASE_IMAGE=kalleef/prerequisite.impactncdger:latest bash tests/docker_setup/run-tests.sh
```

**With the GUI in LOCAL.** On a PC with Docker Desktop:

1. Check out the branch with the change in the model repository.
2. Start the GUI, choose LOCAL and this repository, tick "Rebuild image" and press Start.
3. When RStudio has opened, check in a PowerShell window. The GUI names the image after the
   repository folder, in small letters, and the container `<repository folder>_<GitHub user
   name>`:
   - `docker logs <container name>` shows the lines of `entrypoint.sh` (they start with
     `[ENTRYPOINT]`), of `git-identity` (`[git-init]`) and `[impact-ready] start-up scripts
     finished`, and `exited 0.` for every start-up script;
   - `docker image inspect --format "{{json .Config.Labels}}" <image name>` shows
     `"impact.setup_version":"2"`.
4. In RStudio: the project of the repository is open; in its terminal, `git pull` works;
   a model run writes its results into the output folder.

**By hand on Linux, REMOTE style** (numbers as on the workstation, password set afterwards).
Choose a free port for `<port>`, for example 28787; on the workstation, port 8787 may belong
to someone else's container:

```bash
docker run -d --name setup-test -e IMPACT_UID=<your user number> -e IMPACT_GID=<shared group number> \
  --mount type=bind,source=<repository folder>,target=/home/rstudio/<repository folder name> \
  -p 127.0.0.1:<port>:8787 <image name>
docker logs setup-test                      # lines of entrypoint.sh and the start-up scripts
docker exec setup-test id rstudio           # shows the two numbers
# wait for the ready marker: the loop asks every second and ends when the file exists
until docker exec setup-test test -f /run/impact-ready; do sleep 1; done
printf 'rstudio:%s\n' '<a test password>' | docker exec -i setup-test chpasswd
```

Set the password only after the marker exists: Rocker's start-up sets its own random password
before that, and `chpasswd` reports success also for a password that Rocker overwrites a
moment later. Then sign in at `http://localhost:<port>` with `rstudio` and the test password,
and remove the container with `docker rm -f setup-test`. On the workstation, the browser of
your PC reaches that port through an SSH tunnel: `ssh -L <port>:localhost:<port>
<your account>@<workstation>` in a terminal of the PC, then `http://localhost:<port>` in its
browser.
