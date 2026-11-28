#!/usr/bin/env bash
# =============================================================================
# git-identity.sh: prepares git and SSH for the user "rstudio"
# =============================================================================
#
# PURPOSE
#   Makes "git pull" and "git push" to GitHub work inside the container, from the
#   RStudio Git pane and from the terminal:
#     1. stores GitHub's public host keys and makes SSH check github.com against them,
#        so SSH can tell that it really talks to GitHub;
#     2. finds the person's private SSH key and puts a copy with the right owner and
#        access mode into /home/rstudio/.ssh;
#     3. tells git to use that key;
#     4. sets the git user name and e-mail address when none is set yet.
#
# WHEN IT RUNS
#   At every container start, as root. The Dockerfile installs this file as
#   /etc/cont-init.d/git-identity. The base image (Rocker) runs the scripts of that
#   folder in name order: 01_set_env, 02_userconf, git-identity, zz-impact-ready.
#   The user numbers of "rstudio" are therefore final when this script starts.
#   Scripts in that folder do not receive the variables of "docker run -e". This script
#   needs none of them.
#
# WORDS USED IN THIS FILE
#   host key         Every SSH server has a key pair of its own. The public half is the
#                    "host key". A client that knows the host key notices when another
#                    computer pretends to be that server.
#   known hosts file A text file with one line per known server: name, key type, key.
#                    SSH reads two of them: the one of the user and the one of the system.
#   mount            A folder or file from outside the container that Docker shows
#                    inside it. Its content can belong to other people.
#   symbolic link    A small file that only points to another path.
#   hard link        A second name for the same file. Writing through either name
#                    changes the one file.
#
# WHAT IT CHANGES
#   /etc/ssh/ssh_known_hosts          GitHub's three host keys, for every user of the
#                                     container, once under the name github.com and once
#                                     under the name github.com-published (see below).
#   /etc/ssh/ssh_config.d/impact-github.conf
#                                     tells every SSH connection to github.com or
#                                     ssh.github.com (in any mix of capital and small
#                                     letters, also with a final dot, also when an SSH
#                                     settings file sends the name on to another server or
#                                     sends another name to one of them) to look up its
#                                     host key under the name github.com-published.
#   /home/rstudio/.ssh/               created if missing, access mode 700, owner rstudio.
#   /home/rstudio/.ssh/known_hosts    GitHub's three host keys. This is the file the
#                                     IMPACT Docker GUI names in its own git settings.
#                                     Lines that SSH would use for github.com and are not
#                                     GitHub's published keys are removed from it.
#   /home/rstudio/.ssh/<key name>     a copy of the private key, access mode 600.
#   /home/rstudio/.gitconfig          core.sshCommand, and user.name and user.email when
#                                     they are missing.
#
# WHAT IT NEVER TOUCHES
#   - The mounted key file itself (it is only read).
#   - Any mount. When /home/rstudio/.ssh or /home/rstudio/.gitconfig is a mount, has a
#     mount inside it, lies on a mount (for example a mounted home folder), or is reached
#     through a symbolic link, the script writes nothing there and says so in the log.
#     The person who mounted it is in charge of it.
#   - Any file through a symbolic link or a hard link. Each new file is first written
#     under a new, unused name in the same folder and then renamed into place. A target
#     name that is a symbolic link, a folder or another kind of entry is left as it is,
#     with an ERROR line in the log, and nothing is read through it.
#   - The repository, and the network settings of the container.
#   - The network at start: the host keys are part of this file, so no connection is
#     needed to store them. One connection to github.com is tried in step 4, only to
#     read the GitHub user name, and its failure changes nothing.
#
# HOW IT FITS THE IMPACT DOCKER GUI
#   After the start the GUI copies the same key to the same path and writes the same
#   value into core.sshCommand (see SSH_OPTIONS below). The GUI also rewrites
#   /home/rstudio/.ssh/known_hosts with the keys that "ssh-keyscan github.com" receives
#   at that moment; those keys are not checked by anyone. Therefore this script makes SSH
#   look up GitHub's key under the name github.com-published ("HostKeyAlias"), a name
#   that only this script writes, and only with GitHub's published keys. The rule covers
#   two server names: github.com, and ssh.github.com, the server that GitHub documents
#   for networks that block the usual SSH port 22 (it answers on port 443 with the same
#   published keys). It covers each name in any mix of capital and small letters
#   (GitHub.com, SSH.GitHub.com) and with a final dot (github.com.), because a remote
#   address can be written in each of these ways. It covers the name as it was typed and
#   also the name that an SSH settings file sends it to (see SSH_CONFIG_TEXT below). So
#   it also holds for a remote address such as
#   ssh://git@ssh.github.com:443/owner/repo.git, for GitHub's port 443 set-up in a
#   person's ~/.ssh/config (github.com sent to ssh.github.com on port 443), and for a
#   name of the person's own that such a file sends to ssh.github.com. With the usual
#   settings (see the three cases below), whichever of the two runs last and
#   whatever the scan received, SSH then accepts a server under such a name only with one
#   of GitHub's published keys; the tests show this for the GUI's own command, these
#   spellings and these set-ups. The content of known_hosts itself differs with the
#   order: after the GUI's step it holds the scanned lines, which SSH then does not use
#   for these names.
#   Three cases are outside this protection, because the GUI's scan runs after this
#   script and writes into the person's known hosts file:
#     - a person's ~/.ssh/config sets a HostKeyAlias of its own for github.com, for
#       example "HostKeyAlias github.com". SSH reads that file before the system-wide
#       settings and keeps the first value it finds, so it then uses the scanned lines.
#       Do not set HostKeyAlias for github.com in ~/.ssh/config.
#     - ssh is started with "-F FILE" (another settings file). SSH then reads no
#       system-wide settings, and this rule with them, and the scanned lines count.
#     - /home/rstudio/.ssh is a mount, for example a person's own .ssh folder. This
#       script writes nothing there; the GUI's command replaces GitHub's keys in its
#       known_hosts with the scanned ones and changes the owner of the folder, and an
#       SSH outside the container that reads that file then trusts the scanned keys.
#   Only a change of the GUI (no key scan) closes these cases.
#   A remote address in numbers (an IP address) is outside the rule as well; the GUI's
#   scan writes no line for it, and SSH handles it as any other server (see
#   StrictHostKeyChecking below).
#
# WHEN GITHUB CHANGES A HOST KEY
#   Replace the lines in GITHUB_HOST_KEYS with the ones GitHub publishes at
#   https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
#   and build the image again. Until then, SSH refuses github.com.
# =============================================================================

# "set -u" stops the script when it reads a variable that was never set (this catches
# typing mistakes). "set -o pipefail" makes a chain "a | b" count as failed when any
# part of it fails. The script does without "set -e" (stop at the first failing
# command) on purpose: every step below handles its own failure, so one failed step
# never hides the steps after it.
set -uo pipefail

# log TEXT: one line in the container log. "NAME() { ...; }" defines a function: a named
# group of commands, used afterwards like a command. "$*" stands for all arguments of the
# function, joined into one text. ">&2" sends the line to the error channel, which keeps
# it apart from the output of commands.
log() { echo "[git-init] $*" >&2; }

RSTUDIO_USER="rstudio"
RSTUDIO_HOME="/home/rstudio"
SSH_DIR="$RSTUDIO_HOME/.ssh"
USER_KNOWN_HOSTS="$SSH_DIR/known_hosts"
SYSTEM_KNOWN_HOSTS="/etc/ssh/ssh_known_hosts"
SSH_CONFIG_SNIPPET="/etc/ssh/ssh_config.d/impact-github.conf"
GIT_CONFIG_FILE="$RSTUDIO_HOME/.gitconfig"

# The name under which SSH looks up GitHub's host key (see HOW IT FITS THE IMPACT DOCKER
# GUI above). It is no real server name, so nothing else ever writes a key for it.
GITHUB_ALIAS="github.com-published"

# The SSH options git uses for every connection. They must stay identical to the
# function Get-ContainerGitSshCommand of the IMPACT Docker GUI.
#   IdentitiesOnly=yes                offer only the key named with -i
#   UserKnownHostsFile=...            where host keys of new servers are stored
#   StrictHostKeyChecking=accept-new  a server SSH has never seen is accepted once and
#                                     remembered; a server whose key differs from the
#                                     stored one is refused. GitHub's keys are stored
#                                     below, so github.com and ssh.github.com are always
#                                     checked.
SSH_OPTIONS="-o IdentitiesOnly=yes -o UserKnownHostsFile=$USER_KNOWN_HOSTS -o StrictHostKeyChecking=accept-new"

# GitHub's public host keys, exactly as GitHub publishes them (see the address in the
# header). Their SHA256 fingerprints, for a check by eye:
#   ED25519  SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU
#   ECDSA    SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM
#   RSA      SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s
# Text between single quotes is taken exactly as written, line breaks included.
GITHUB_HOST_KEYS='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk='
# The same three lines under the name github.com-published. "${text//old/new}" replaces
# every "old" in text; "github.com " occurs only at the start of each line.
GITHUB_ALIAS_KEYS="${GITHUB_HOST_KEYS//github.com /$GITHUB_ALIAS }"

# What impact-github.conf says. SSH reads every file of /etc/ssh/ssh_config.d (the line
# "Include /etc/ssh/ssh_config.d/*.conf" of /etc/ssh/ssh_config). A line "Match ..."
# makes the indented lines below it apply to the connections it describes. The file has
# two such parts, with the same setting, for two ways a connection can concern GitHub:
#   "Match originalhost ..."  the server name as it was typed, in the remote address of
#                             git or on the command line of ssh;
#   "Match host ..."          the server name SSH connects to in the end. It differs
#                             from the typed name when a "HostName" line of an SSH
#                             settings file sends the typed name on: "Host gh" with
#                             "HostName github.com" turns the typed name gh into
#                             github.com.
# Both parts list the same two servers: github.com, and ssh.github.com, the server that
# GitHub documents for networks that block the usual port 22 (remote addresses such as
# ssh://git@ssh.github.com:443/owner/repo.git, or "HostName ssh.github.com" with
# "Port 443" in a person's ~/.ssh/config). GitHub's servers answer there with the same
# published keys. Without ssh.github.com in the list, "accept-new" would accept any key
# for that name on first contact, and each new container makes a first contact.
# Both parts are needed:
#   - "Host gh" with "HostName ssh.github.com" (a name of the person's own) is covered
#     only by the "host" part, because the typed name gh is in neither list;
#   - "Host github.com" with "HostName" set to an address in numbers, or to any other
#     name, is covered only by the "originalhost" part, because the name connected to is
#     in neither list.
#   GitHub's own port 443 set-up ("Host github.com" with "HostName ssh.github.com") is
#   covered by both.
# Each server is listed twice, separated by commas: "github.com." with a final dot is a
# second valid way to write the same server name. Both parts compare names without
# regard to capital letters, so GitHub.com and GITHUB.COM count as well. (The shorter
# form "Host github.com" compares capital letters exactly; a remote address such as
# git@GitHub.com:... would then escape the rule, while SSH still finds the scanned keys
# for it, because the lookup in known hosts files ignores capitals.) SSH keeps the first
# value it finds for a setting, so a connection that both parts describe gets the same
# name once.
SSH_CONFIG_TEXT="# Written by git-identity.sh at every container start. SSH checks github.com
# and ssh.github.com (any capital letters, also with a final dot, as typed and
# after a HostName line) against GitHub's published host keys, stored under the
# name $GITHUB_ALIAS in $SYSTEM_KNOWN_HOSTS.
# Keys that a scan wrote under the name github.com are not used.
Match originalhost github.com,github.com.,ssh.github.com,ssh.github.com.
    HostKeyAlias $GITHUB_ALIAS
Match host github.com,github.com.,ssh.github.com,ssh.github.com.
    HostKeyAlias $GITHUB_ALIAS"

# The spellings of the server names that the check after writing the file tries. Each
# one must lead to the name github.com-published. "NAME=(a b c)" makes a list of words.
GITHUB_NAME_SPELLINGS=(github.com GitHub.com GITHUB.COM github.com. ssh.github.com SSH.GitHub.com ssh.github.com.)

FAILURES=0     # counts the steps that failed; the script ends with 1 when any did
# "$((a + 1))" is arithmetic: it is replaced by the result of the sum. It is used below
# as FAILURES=$((FAILURES + 1)).

# The numbers of "rstudio" at this moment. "$(command)" is replaced by what the command
# prints. "id -u" prints the user number, "id -g" the main group number. Numbers are
# used for "chown" so the result does not depend on how the group is named.
RSTUDIO_UID=$(id -u "$RSTUDIO_USER")
RSTUDIO_GID=$(id -g "$RSTUDIO_USER")

# as_rstudio COMMAND [ARGUMENT...]: runs one command as the user "rstudio".
# "runuser" lets root start a program as another user; "--" ends the options of runuser,
# so the words after it are the command. "$@" stands for all arguments, each kept as one
# word, so no extra quoting is needed. "NAME=value command" sets a variable for that one
# command only; HOME is set so that git finds /home/rstudio/.gitconfig.
as_rstudio() {
    HOME="$RSTUDIO_HOME" USER="$RSTUDIO_USER" LOGNAME="$RSTUDIO_USER" runuser -u "$RSTUDIO_USER" -- "$@"
}

# -----------------------------------------------------------------------------
# Mounts and links
# -----------------------------------------------------------------------------
# The kernel lists all mounts of the container in /proc/self/mountinfo; the fifth word
# of each line is the mount point. The container's own files are the mount with the
# mount point "/". A space inside a path is written there as \040, a tab as \011, a line
# break as \012 and a backslash as \134. entrypoint.sh uses the same rules.
# "NAME=()" makes an empty list. "[[ -r FILE ]]" is true when FILE can be read.
MOUNT_POINTS=()
MOUNTS_KNOWN=0
if [[ -r /proc/self/mountinfo ]]; then
    # "while read" takes one line at a time from the command after "< <(...)"; "IFS=" and
    # "-r" keep spaces and backslashes of the line as they are. The command is awk, a
    # small text-processing language: '{print $5}' prints the fifth word of every line.
    while IFS= read -r mount_point; do
        # "${text//old/new}" replaces every "old" in text. "$'\t'" is a tab character,
        # "$'\n'" a line break.
        mount_point="${mount_point//\\040/ }"
        mount_point="${mount_point//\\011/$'\t'}"
        mount_point="${mount_point//\\012/$'\n'}"
        mount_point="${mount_point//\\134/\\}"
        MOUNT_POINTS+=("$mount_point")     # "+=(...)" adds an entry to the list
    done < <(awk '{print $5}' /proc/self/mountinfo)
    # "${#NAME[@]}" is the number of entries in the list NAME; "(( ... ))" compares whole
    # numbers; "a && b" runs b only when a succeeded.
    (( ${#MOUNT_POINTS[@]} > 0 )) && MOUNTS_KNOWN=1
fi

# on_container_root PATH: succeeds when the mount that holds PATH is "/", the
# container's own files. That mount is the longest mount point that is PATH itself or a
# folder above it; a mount at /home or /home/rstudio holds the whole home folder.
# Inside [[ ]], "$mount_point"/* is a pattern: "starts with the mount point and a
# slash". Inside [[ ]], "||" means "or" and "&&" means "and". "${#text}" is the number of
# characters of a text. "local" makes variables that exist only inside the function; "$1"
# is the first argument of the function. "for NAME in "${LIST[@]}"" runs the loop once for
# each entry of the list LIST ("${LIST[@]}" stands for all entries, each kept as one
# word).
on_container_root() {
    local path="$1" mount_point best=""
    for mount_point in "${MOUNT_POINTS[@]}"; do
        if [[ "$mount_point" == "/" || "$path" == "$mount_point" || "$path" == "$mount_point"/* ]]; then
            (( ${#mount_point} > ${#best} )) && best="$mount_point"
        fi
    done
    [[ "$best" == "/" ]]
}

# mount_at_or_below PATH: succeeds when PATH is a mount point or a mount lies anywhere
# inside it. "return 0" ends a function with success, "return 1" with failure; without a
# "return", a function ends with the result of its last command.
mount_at_or_below() {
    local path="$1" mount_point
    for mount_point in "${MOUNT_POINTS[@]}"; do
        if [[ "$mount_point" == "$path" || "$mount_point" == "$path"/* ]]; then
            return 0
        fi
    done
    return 1
}

# belongs_to_container PATH: succeeds when the script may write at PATH. That is the
# case when the list of mounts is known, no symbolic link is on the path, the mount that
# holds PATH is the container's own, and no mount is at or inside PATH. "realpath -m"
# follows every link and also accepts a path that does not exist yet; when it prints the
# same text, there is no link. "--" ends the options of a command, so a path that starts
# with "-" is never read as an option. "2>/dev/null" throws away error messages.
belongs_to_container() {
    local path="$1"
    [[ "$MOUNTS_KNOWN" == 1 ]] || return 1
    [[ "$(realpath -m -- "$path" 2>/dev/null)" == "$path" ]] || return 1
    on_container_root "$path" || return 1
    ! mount_at_or_below "$path"
}

# plain_file PATH: succeeds when PATH is a regular file, no symbolic link, and has only
# this one name ("stat -c %h" prints the number of names of a file). Only such a file is
# read or replaced in a folder that the user "rstudio" can change. "[[ -f PATH ]]" is
# true for a regular file, "-L" for a symbolic link; "!" turns true into false. "a || b"
# runs b only when a failed.
plain_file() {
    [[ -f "$1" && ! -L "$1" ]] || return 1
    [[ "$(stat -c %h -- "$1" 2>/dev/null)" == 1 ]]
}

# write_file TARGET MODE OWNER: puts the text it receives on its input into TARGET, with
# the access mode MODE and the owner OWNER ("UID:GID").
#   1. TARGET must be missing or a plain file (see plain_file). Anything else stays as it
#      is: the text is thrown away, and the function fails.
#   2. "mktemp" creates a new, empty file with a random name that did not exist before
#      (".impact.XXXXXX", the X are replaced), readable for root only. A symbolic link
#      that someone placed under some fixed name can therefore never be followed.
#   3. The text goes into that new file, which then gets its mode and owner. "chown -h"
#      never follows a link.
#   4. "mv -f -T" renames the new file to TARGET in one step. A rename replaces the name
#      TARGET itself and never writes through it; "-T" makes mv fail when TARGET is a
#      folder, where it would otherwise move the file into it.
#   No program of "rstudio" runs while the start-up scripts run, so nobody can change
#   the folder between these steps.
# A backslash at the very end of a line continues the command on the next line.
write_file() {
    local target="$1" mode="$2" owner="$3" new_file
    # "-e" is true for anything that exists, "-L" for a symbolic link, also one that points
    # to nothing. "cat > /dev/null" reads the text and throws it away. Below,
    # "${target%/*}" is TARGET without its last part, which is the folder of the file.
    if [[ -e "$target" || -L "$target" ]] && ! plain_file "$target"; then
        cat > /dev/null
        log "ERROR: $target is a symbolic link, a folder, a file with a second name, or another kind of entry; it is left as it is"
        return 1
    fi
    if ! new_file=$(mktemp -- "${target%/*}/.impact.XXXXXX"); then
        cat > /dev/null
        return 1
    fi
    if ! cat > "$new_file" || ! chmod "$mode" -- "$new_file" || ! chown -h "$owner" -- "$new_file" \
       || ! mv -f -T -- "$new_file" "$target"; then
        rm -f -- "$new_file"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# GitHub's host keys in a known hosts file
# -----------------------------------------------------------------------------

# ensure_github_keys FILE OWNER WITH_ALIAS
#   Rebuilds the part of FILE that is about GitHub, at every start:
#     - every line that SSH would use for github.com or for github.com-published is
#       dropped: also lines with capital letters (GitHub.com), with several names
#       (other.example,github.com), with patterns (*.com), and lines stored in coded
#       ("hashed") form. "ssh-keygen -F NAME -f FILE" lists exactly the lines SSH finds
#       for NAME, each after a line "# Host NAME found: line N"; sed takes the numbers N.
#       An awk filter on the names catches the same lines when ssh-keygen is missing;
#     - all other lines are kept as they are;
#     - GitHub's three published keys are added (with WITH_ALIAS=1 also under the name
#       github.com-published).
#   FILE is replaced only when the result differs from it. FILE must be missing or a
#   plain file; anything else is left as it is and the function fails. OWNER is
#   "UID:GID" for a new FILE.
ensure_github_keys() {
    local file="$1" owner="$2" with_alias="$3" old="" drop="" kept wanted
    if [[ -e "$file" || -L "$file" ]]; then
        if ! plain_file "$file"; then
            log "ERROR: $file is a symbolic link, a folder, a file with a second name, or another kind of entry; it is left as it is and nothing is read through it"
            return 1
        fi
        old="$(cat -- "$file")" || return 1
    fi
    # "command -v NAME" succeeds when the program NAME exists. "> /dev/null 2>&1" hides
    # its output and its error messages.
    if command -v ssh-keygen > /dev/null 2>&1; then
        # "{ a; b; }" sends the output of both commands into one pipe. "/dev/stdin" lets
        # ssh-keygen read the text it receives on its input as if it were a file.
        # "printf '%s\n' TEXT" prints TEXT followed by a line break. sed prints (p) the
        # line number from each line where the replacement (s) worked.
        drop="$( { printf '%s\n' "$old" | ssh-keygen -F github.com -f /dev/stdin 2>/dev/null
                   printf '%s\n' "$old" | ssh-keygen -F "$GITHUB_ALIAS" -f /dev/stdin 2>/dev/null; } \
                 | sed -n 's/^# Host .* found: line \([0-9][0-9]*\).*/\1/p')"
    fi
    # awk: "drop" holds the line numbers, one per line; "split" turns them into a list.
    # "NR" is the number of the current line. The first word of a line lists the server
    # names, separated by commas; a line that starts with a marker (a word beginning with
    # @) has them as its second word. "tolower" makes the comparison ignore capitals.
    kept="$(printf '%s\n' "$old" | awk -v drop="$drop" -v alias="$GITHUB_ALIAS" '
        BEGIN { n = split(drop, d, "\n"); for (i = 1; i <= n; i++) skip[d[i]] = 1 }
        NR in skip { next }
        {
            names = ($1 ~ /^@/) ? $2 : $1
            count = split(tolower(names), name, ",")
            for (i = 1; i <= count; i++) if (name[i] == "github.com" || name[i] == alias) next
            print
        }')"
    wanted="$GITHUB_HOST_KEYS"
    if [[ "$with_alias" == 1 ]]; then
        wanted="$wanted"$'\n'"$GITHUB_ALIAS_KEYS"
    fi
    # "[[ -n TEXT ]]" is true when TEXT is not empty.
    if [[ -n "$kept" ]]; then
        wanted="$kept"$'\n'"$wanted"
    fi
    if [[ "$old" == "$wanted" ]]; then
        log "$file already holds GitHub's three host keys and no other key for github.com"
        return 0
    fi
    mkdir -p -- "${file%/*}" || return 1     # "${file%/*}" is the folder of the file
    printf '%s\n' "$wanted" | write_file "$file" 644 "$owner" || return 1
    log "wrote GitHub's three host keys to $file (other lines for github.com removed)"
}

# "2>&1" adds the error messages of a command to its normal output.
log "start; $(id "$RSTUDIO_USER" 2>&1)"

# -----------------------------------------------------------------------------
# Step 1: GitHub's host keys
# -----------------------------------------------------------------------------
# The system-wide file is read by every SSH connection of every user in the container,
# whatever options the connection is started with.
SYSTEM_KEYS_OK=0
if ! belongs_to_container "$SYSTEM_KNOWN_HOSTS"; then
    log "ERROR: $SYSTEM_KNOWN_HOSTS is a mount, lies on one, or is reached through a symbolic link: it is left as it is"
    FAILURES=$((FAILURES + 1))
elif ensure_github_keys "$SYSTEM_KNOWN_HOSTS" 0:0 1; then
    SYSTEM_KEYS_OK=1
else
    log "ERROR: could not write $SYSTEM_KNOWN_HOSTS"
    FAILURES=$((FAILURES + 1))
fi

# The setting HostKeyAlias, written only when the keys under that name are in place.
# "ssh -G NAME" prints the settings SSH would use for the server NAME, without
# connecting; "grep -q -i -x" looks for the whole line, ignoring capitals. The check
# runs once for each spelling in the list GITHUB_NAME_SPELLINGS ("${NAME[@]}" stands for
# all entries of a list, each kept as one word, and "${NAME[*]}" joins them into one
# text); "missing" collects the spellings that fail.
if [[ "$SYSTEM_KEYS_OK" == 1 ]]; then
    if ! belongs_to_container "$SSH_CONFIG_SNIPPET"; then
        log "ERROR: $SSH_CONFIG_SNIPPET is a mount, lies on one, or is reached through a symbolic link: it is left as it is"
        FAILURES=$((FAILURES + 1))
    elif [[ -f "$SSH_CONFIG_SNIPPET" && ! -L "$SSH_CONFIG_SNIPPET" && "$(cat -- "$SSH_CONFIG_SNIPPET")" == "$SSH_CONFIG_TEXT" ]]; then
        log "$SSH_CONFIG_SNIPPET is in place"
    elif mkdir -p -- "${SSH_CONFIG_SNIPPET%/*}" && printf '%s\n' "$SSH_CONFIG_TEXT" | write_file "$SSH_CONFIG_SNIPPET" 644 0:0; then
        log "wrote $SSH_CONFIG_SNIPPET: SSH checks github.com against GitHub's published keys only"
    else
        log "ERROR: could not write $SSH_CONFIG_SNIPPET"
        FAILURES=$((FAILURES + 1))
    fi
    missing=""
    for spelling in "${GITHUB_NAME_SPELLINGS[@]}"; do
        if ! ssh -G "$spelling" 2>/dev/null | grep -q -i -x "hostkeyalias $GITHUB_ALIAS"; then
            missing="$missing $spelling"
        fi
    done
    # "[[ -z TEXT ]]" is true when TEXT is empty.
    if [[ -z "$missing" ]]; then
        log "SSH uses the name $GITHUB_ALIAS for the host key of github.com and ssh.github.com (checked for: ${GITHUB_NAME_SPELLINGS[*]})"
    else
        log "WARNING: SSH does not use $SSH_CONFIG_SNIPPET for:$missing (is the Include line missing from /etc/ssh/ssh_config?). github.com is then checked against every key stored for it, also keys from a scan."
    fi
fi

# The folder /home/rstudio/.ssh. SSH_DIR_USABLE says whether this script may write there.
SSH_DIR_USABLE=0
if belongs_to_container "$SSH_DIR"; then
    # 700 means: only the owner may read, write and enter the folder. SSH insists on it.
    # "[[ -d ]]" checks that it is a folder; belongs_to_container made sure it is no link.
    if mkdir -p -- "$SSH_DIR" && [[ -d "$SSH_DIR" && ! -L "$SSH_DIR" ]] \
       && chown -h "$RSTUDIO_UID:$RSTUDIO_GID" -- "$SSH_DIR" && chmod 700 -- "$SSH_DIR"; then
        SSH_DIR_USABLE=1
    else
        log "ERROR: could not prepare $SSH_DIR"
        FAILURES=$((FAILURES + 1))
    fi
else
    log "$SSH_DIR is a mount, has a mount inside it, lies on a mount, or is reached through a symbolic link: nothing is written there. GitHub's host keys are in $SYSTEM_KNOWN_HOSTS."
fi

if [[ "$SSH_DIR_USABLE" == 1 ]]; then
    if ! ensure_github_keys "$USER_KNOWN_HOSTS" "$RSTUDIO_UID:$RSTUDIO_GID" 0; then
        log "ERROR: could not write $USER_KNOWN_HOSTS. GitHub's host keys are in $SYSTEM_KNOWN_HOSTS."
        FAILURES=$((FAILURES + 1))
    fi
fi

# -----------------------------------------------------------------------------
# Step 2: find the private key and copy it
# -----------------------------------------------------------------------------
# The GUI mounts the key as /keys/id_ed25519_<GitHub user name>, readable for root only.
# The other folders are searched for images that are started in another way.
# For the log: the mounts in or at the folders that are searched below. awk prints the
# fifth word of a line of /proc/self/mountinfo (the mount point) when it matches the
# pattern, and ends with an error when nothing matched.
log "mounts in the key folders:"
awk '$5 ~ /^\/keys(\/|$)|^\/root\/\.ssh(\/|$)|^\/home\/rstudio\/\.ssh(\/|$)|^\/(tmp|var)\/ssh(\/|$)/ {print "[git-init]   " $5; found = 1} END {exit !found}' \
    /proc/self/mountinfo >&2 || log "  none"

KEY_SOURCE=""
# "for NAME in A B C" runs the loop once for each word. The loop takes the folders in
# this order and stops at the first one that holds a key. /keys and /root/.ssh belong to
# root; the other folders can be changed by "rstudio", so a key there must be a plain
# file (see plain_file).
for search_path in /keys /root/.ssh "$SSH_DIR" /tmp/ssh /var/ssh; do
    [[ -d "$search_path" ]] || continue     # "continue" goes on with the next folder
    # A folder reached through a symbolic link could lead anywhere, for example into a
    # mounted folder with other people's keys: skip it.
    if [[ "$(realpath -e -- "$search_path" 2>/dev/null)" != "$search_path" ]]; then
        log "skipping $search_path: a symbolic link is on its path"
        continue
    fi
    log "searching for keys in: $search_path"
    valid_keys=()     # "NAME=()" makes an empty list
    # "case VALUE in PATTERN) ... ;; esac" runs the part after the first pattern that
    # matches VALUE; "|" separates several patterns, and "*" matches anything.
    # "$search_path"/* lists the names directly in this folder. Nothing below is read.
    for candidate in "$search_path"/*; do
        # Only regular, readable files. Public keys, known hosts files, the SSH settings
        # file and the script's own new files are no private keys.
        [[ -f "$candidate" && ! -L "$candidate" && -r "$candidate" ]] || continue
        case "$search_path" in
            /keys|/root/.ssh) ;;
            *) plain_file "$candidate" || continue ;;
        esac
        # "${path##*/}" removes everything up to the last slash: the name without its folder.
        candidate_name="${candidate##*/}"
        case "$candidate_name" in
            *.pub|known_hosts*|config|*.impact-new|.impact.*) continue ;;
        esac
        # A private key starts with a line such as "-----BEGIN OPENSSH PRIVATE KEY-----".
        # "head -n 1" reads the first line; "|| true" makes a failure of it count as
        # success. "=~" compares text with a pattern. A file with the GUI's key name is
        # accepted as well. The content is never logged.
        first_line=$(head -n 1 -- "$candidate" 2>/dev/null || true)
        if [[ "$first_line" =~ BEGIN\ (RSA\ |DSA\ |EC\ |OPENSSH\ )?PRIVATE\ KEY ]] \
           || [[ "$candidate_name" =~ ^id_ed25519_[A-Za-z0-9._-]+$ ]]; then
            valid_keys+=("$candidate")
            log "found SSH key: $candidate"
        fi
    done

    if (( ${#valid_keys[@]} == 0 )); then
        continue
    fi
    # Several keys in one folder: prefer the GUI's name id_ed25519_<name>, then the
    # usual names id_rsa, id_ecdsa, id_dsa, then the first one found.
    for key in "${valid_keys[@]}"; do
        if [[ "${key##*/}" =~ ^id_ed25519_[A-Za-z0-9._-]+$ ]]; then KEY_SOURCE="$key"; break; fi
    done
    if [[ -z "$KEY_SOURCE" ]]; then
        for key in "${valid_keys[@]}"; do
            if [[ "${key##*/}" =~ ^id_(rsa|dsa|ecdsa)(_.*)?$ ]]; then KEY_SOURCE="$key"; break; fi
        done
    fi
    [[ -n "$KEY_SOURCE" ]] || KEY_SOURCE="${valid_keys[0]}"
    log "using key: $KEY_SOURCE"
    break     # "break" leaves the loop over the folders
done
[[ -n "$KEY_SOURCE" ]] || log "no SSH keys found in any search location"

# The copy. The mounted file keeps the owner it has outside the container, and SSH
# refuses a private key that other users can read. The copy belongs to "rstudio" and
# has the access mode 600 (owner may read and write, nobody else may do anything).
# "tr -d '\r'" removes the carriage returns that Windows adds at line ends; a key file
# with them is refused by SSH.
KEY_PATH=""
if [[ -n "$KEY_SOURCE" && "$SSH_DIR_USABLE" == 1 ]]; then
    key_target="$SSH_DIR/${KEY_SOURCE##*/}"
    if [[ "$KEY_SOURCE" == "$key_target" ]]; then
        # The key already lies in the right folder, as a plain file (checked above):
        # only owner and mode are set.
        if chown -h "$RSTUDIO_UID:$RSTUDIO_GID" -- "$key_target" && chmod 600 -- "$key_target"; then
            KEY_PATH="$key_target"
        fi
    elif belongs_to_container "$key_target" \
         && tr -d '\r' < "$KEY_SOURCE" | write_file "$key_target" 600 "$RSTUDIO_UID:$RSTUDIO_GID"; then
        KEY_PATH="$key_target"
        # The public key, if it lies next to the private one as a plain file. 644:
        # everyone may read it. Git works without it, so a failure here is only noted.
        if plain_file "$KEY_SOURCE.pub"; then
            if ! tr -d '\r' < "$KEY_SOURCE.pub" | write_file "$key_target.pub" 644 "$RSTUDIO_UID:$RSTUDIO_GID"; then
                log "WARNING: could not copy the public key to $key_target.pub"
            fi
        fi
    fi
    if [[ -n "$KEY_PATH" ]]; then
        log "SSH key ready for git: $KEY_PATH"
    else
        log "ERROR: could not copy the SSH key to $key_target"
        FAILURES=$((FAILURES + 1))
    fi
elif [[ -n "$KEY_SOURCE" ]]; then
    log "the key $KEY_SOURCE is not copied, because nothing is written to $SSH_DIR"
fi

# -----------------------------------------------------------------------------
# Step 3: make git use the key
# -----------------------------------------------------------------------------
# "git config --global" writes into /home/rstudio/.gitconfig. git runs as "rstudio"
# here (as_rstudio), so it can only change what "rstudio" may change. core.sshCommand
# is the command git runs for every SSH connection.
GIT_CONFIG_USABLE=0
if belongs_to_container "$GIT_CONFIG_FILE"; then
    GIT_CONFIG_USABLE=1
else
    log "$GIT_CONFIG_FILE is a mount, lies on a mount, or is reached through a symbolic link: the git settings are left as they are"
fi

if [[ -n "$KEY_PATH" && "$GIT_CONFIG_USABLE" == 1 ]]; then
    if as_rstudio git config --global core.sshCommand "ssh -i $KEY_PATH $SSH_OPTIONS"; then
        log "set core.sshCommand to use $KEY_PATH"
    else
        log "ERROR: could not set core.sshCommand"
        FAILURES=$((FAILURES + 1))
    fi
else
    log "no key copy or no writable git settings; skipping core.sshCommand"
fi

# -----------------------------------------------------------------------------
# Step 4: git user name and e-mail address, only when missing
# -----------------------------------------------------------------------------
if [[ "$GIT_CONFIG_USABLE" == 1 ]]; then
    need_name=1
    need_mail=1
    # "git config --get" succeeds when the setting exists. ">/dev/null 2>&1" hides its output.
    as_rstudio git config --global --get user.name  >/dev/null 2>&1 && need_name=0
    as_rstudio git config --global --get user.email >/dev/null 2>&1 && need_mail=0

    if (( need_name == 1 || need_mail == 1 )); then
        github_user=""

        # First source: ask GitHub. "ssh -T git@github.com" answers with the line
        # "Hi <name>! You've successfully authenticated, ...". The connection checks
        # GitHub's host key strictly against the keys stored in step 1
        # (StrictHostKeyChecking=yes), never asks a question (BatchMode=yes) and gives
        # up after a few seconds. "timeout 20" ends the command after 20 seconds at the
        # latest. "2>&1" adds error messages to the answer; "|| true" keeps a failed
        # connection from counting as an error of this script.
        if [[ -n "$KEY_PATH" ]]; then
            log "asking GitHub for the user name of the key"
            banner=$(as_rstudio timeout 20 ssh -T -i "$KEY_PATH" \
                -o IdentitiesOnly=yes \
                -o BatchMode=yes \
                -o UserKnownHostsFile="$USER_KNOWN_HOSTS" \
                -o GlobalKnownHostsFile="$SYSTEM_KNOWN_HOSTS" \
                -o StrictHostKeyChecking=yes \
                -o ConnectTimeout=5 \
                git@github.com 2>&1 || true)
            # Look for a line "Hi <name>!". After a match, BASH_REMATCH[1] holds the
            # text of the first pair of parentheses in the pattern.
            while IFS= read -r banner_line; do
                if [[ "$banner_line" =~ ^Hi\ ([A-Za-z0-9._-]+)! ]]; then
                    github_user="${BASH_REMATCH[1]}"
                    break
                fi
            done <<< "$banner"     # "<<< text" feeds the text to the loop line by line
            if [[ -n "$github_user" ]]; then
                log "GitHub user of the key: $github_user"
            else
                log "GitHub gave no user name (no network at start, or the key is not registered)"
            fi
        fi

        # Second source: the file name of the key, id_<key type>_<GitHub user name>.
        # The name of the copy, or of the key found when no copy could be made (for
        # example when .ssh is a mount). "${name:-text}" gives "text" when the variable
        # is empty; "${path##*/}" is the name without its folder.
        key_name_source="${KEY_PATH:-$KEY_SOURCE}"
        if [[ -z "$github_user" && -n "$key_name_source" ]]; then
            if [[ "${key_name_source##*/}" =~ ^id_(ed25519|rsa|ecdsa|dsa)_([A-Za-z0-9._-]+)$ ]]; then
                github_user="${BASH_REMATCH[2]}"
                log "user name taken from the key file name: $github_user"
            else
                log "the key file name holds no user name (expected: id_<key type>_<user name>)"
            fi
        fi

        name_to_set="${github_user:-rstudio}"
        if [[ -n "$github_user" ]]; then
            mail_to_set="${github_user}@users.noreply.github.com"
        else
            mail_to_set="rstudio@localhost"
        fi
        if (( need_name == 1 )); then
            as_rstudio git config --global user.name "$name_to_set" || FAILURES=$((FAILURES + 1))
        fi
        if (( need_mail == 1 )); then
            as_rstudio git config --global user.email "$mail_to_set" || FAILURES=$((FAILURES + 1))
        fi
    fi

    # -------------------------------------------------------------------------
    # Step 5: show the result in the log
    # -------------------------------------------------------------------------
    log "user.name:  $(as_rstudio git config --global user.name 2>/dev/null || true)"
    log "user.email: $(as_rstudio git config --global user.email 2>/dev/null || true)"
fi

if (( FAILURES > 0 )); then
    log "done, with $FAILURES failed step(s); see the ERROR lines above"
    exit 1
fi
log "done"
