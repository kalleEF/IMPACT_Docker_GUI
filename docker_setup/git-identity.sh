#!/usr/bin/env bash
# =============================================================================
# git-identity.sh: prepares git and SSH for the user "rstudio"
# =============================================================================
#
# PURPOSE
#   Makes "git pull" and "git push" to GitHub work inside the container, from the
#   RStudio Git pane and from the terminal:
#     1. stores GitHub's public host keys, so SSH can check that it really talks to
#        GitHub;
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
#   mount            A folder or file from outside the container that Docker shows
#                    inside it. Its content can belong to other people.
#   symbolic link    A small file that only points to another path.
#
# WHAT IT CHANGES
#   /etc/ssh/ssh_known_hosts          GitHub's three host keys, for every user of the
#                                     container.
#   /home/rstudio/.ssh/               created if missing, access mode 700, owner rstudio.
#   /home/rstudio/.ssh/known_hosts    GitHub's three host keys. This is the file the
#                                     IMPACT Docker GUI names in its own git settings.
#   /home/rstudio/.ssh/<key name>     a copy of the private key, access mode 600.
#   /home/rstudio/.gitconfig          core.sshCommand, and user.name and user.email when
#                                     they are missing.
#
# WHAT IT NEVER TOUCHES
#   - The mounted key file itself (it is only read).
#   - Any mount. When /home/rstudio/.ssh or /home/rstudio/.gitconfig is a mount, has a
#     mount inside it, or is reached through a symbolic link, the script writes nothing
#     there and says so in the log. The person who mounted it is in charge of it.
#   - The repository, and the network settings of the container.
#   - The network at start: the host keys are part of this file, so no connection is
#     needed to store them. One connection to github.com is tried in step 4, only to
#     read the GitHub user name, and its failure changes nothing.
#
# HOW IT FITS THE IMPACT DOCKER GUI
#   After the start the GUI copies the same key to the same path and writes the same
#   value into core.sshCommand (see SSH_OPTIONS below). The result is therefore the same
#   whichever of the two runs last.
#
# WHEN GITHUB CHANGES A HOST KEY
#   Replace the lines in GITHUB_HOST_KEYS with the ones GitHub publishes at
#   https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
#   and build the image again.
# =============================================================================

# "set -u" stops the script when it reads a variable that was never set (this catches
# typing mistakes). "set -o pipefail" makes a chain "a | b" count as failed when any
# part of it fails. The script does without "set -e" (stop at the first failing
# command) on purpose: every step below handles its own failure, so one failed step
# never hides the steps after it.
set -uo pipefail

# log TEXT: one line in the container log. ">&2" sends it to the error channel, which
# keeps it apart from the output of commands.
log() { echo "[git-init] $*" >&2; }

RSTUDIO_USER="rstudio"
RSTUDIO_HOME="/home/rstudio"
SSH_DIR="$RSTUDIO_HOME/.ssh"
USER_KNOWN_HOSTS="$SSH_DIR/known_hosts"
SYSTEM_KNOWN_HOSTS="/etc/ssh/ssh_known_hosts"
GIT_CONFIG_FILE="$RSTUDIO_HOME/.gitconfig"

# The SSH options git uses for every connection. They must stay identical to the
# function Get-ContainerGitSshCommand of the IMPACT Docker GUI.
#   IdentitiesOnly=yes                offer only the key named with -i
#   UserKnownHostsFile=...            where host keys of new servers are stored
#   StrictHostKeyChecking=accept-new  a server SSH has never seen is accepted once and
#                                     remembered; a server whose key differs from the
#                                     stored one is refused. GitHub's keys are stored
#                                     below, so github.com is always checked.
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

FAILURES=0     # counts the steps that failed; the script ends with 1 when any did

# The numbers of "rstudio" at this moment. "id -u" prints the user number, "id -g" the
# main group number. Numbers are used for "chown" so the result does not depend on how
# the group is named.
RSTUDIO_UID=$(id -u "$RSTUDIO_USER")
RSTUDIO_GID=$(id -g "$RSTUDIO_USER")

# as_rstudio COMMAND [ARGUMENT...]: runs one command as the user "rstudio".
# "runuser" lets root start a program as another user. "$@" stands for all arguments,
# each kept as one word, so no extra quoting is needed. HOME is set so that git finds
# /home/rstudio/.gitconfig.
as_rstudio() {
    HOME="$RSTUDIO_HOME" USER="$RSTUDIO_USER" LOGNAME="$RSTUDIO_USER" runuser -u "$RSTUDIO_USER" -- "$@"
}

# mount_at_or_below PATH: succeeds when PATH is a mount point or a mount lies anywhere
# inside it. The kernel lists all mounts of the container in /proc/self/mountinfo; the
# fifth word of each line is the mount point. A space inside a path is written there as
# \040, a tab as \011, a line break as \012 and a backslash as \134.
mount_at_or_below() {
    local path="$1" mount_point
    # "while read" takes one line at a time from the command after "< <(...)".
    while IFS= read -r mount_point; do
        # "${text//old/new}" replaces every "old" in text.
        mount_point="${mount_point//\\040/ }"
        mount_point="${mount_point//\\011/$'\t'}"
        mount_point="${mount_point//\\012/$'\n'}"
        mount_point="${mount_point//\\134/\\}"
        # Inside [[ ]], "$path"/* is a pattern: "starts with PATH and a slash".
        if [[ "$mount_point" == "$path" || "$mount_point" == "$path"/* ]]; then
            return 0
        fi
    done < <(awk '{print $5}' /proc/self/mountinfo)
    return 1
}

# belongs_to_container PATH: succeeds when the script may write at PATH. That is the
# case when the list of mounts can be read, no symbolic link is on the path, and no
# mount is at or inside PATH. "realpath -m" follows every link and also accepts a path
# that does not exist yet; when it prints the same text, there is no link.
belongs_to_container() {
    local path="$1"
    [[ -r /proc/self/mountinfo ]] || return 1
    [[ "$(realpath -m -- "$path" 2>/dev/null)" == "$path" ]] || return 1
    ! mount_at_or_below "$path"
}

# has_all_github_keys FILE: succeeds when FILE holds each of the three lines of
# GITHUB_HOST_KEYS exactly. "grep -qxF" looks for a whole line (-x) as plain text (-F)
# and prints nothing (-q). "<<< text" feeds the text to the loop line by line.
has_all_github_keys() {
    local file="$1" key_line
    [[ -f "$file" ]] || return 1
    while IFS= read -r key_line; do
        grep -qxF -- "$key_line" "$file" || return 1
    done <<< "$GITHUB_HOST_KEYS"
    return 0
}

# ensure_github_keys FILE [OWNER]
#   Makes sure FILE holds GitHub's three published host keys. A file that already has
#   all three stays untouched. Otherwise every line about github.com is dropped (a
#   wrong or cut-off key would stay beside the right ones otherwise), all other lines
#   are kept, and the three keys are added. OWNER, when given, is "UID:GID" for the file.
ensure_github_keys() {
    local file="$1" owner="${2:-}"
    if has_all_github_keys "$file"; then
        log "$file already holds GitHub's three host keys"
        return 0
    fi
    local new_file="$file.impact-new"
    mkdir -p "${file%/*}" || return 1     # "${file%/*}" is the folder of the file
    {
        if [[ -f "$file" ]]; then
            # The first word of a line lists the server names, separated by commas.
            # A line that starts with a marker (a word beginning with @) has the
            # names as its second word. Lines that name github.com are left out.
            awk '{
                names = ($1 ~ /^@/) ? $2 : $1
                count = split(names, name, ",")
                keep = 1
                for (i = 1; i <= count; i++) if (name[i] == "github.com") keep = 0
                if (keep) print
            }' "$file"
        fi
        printf '%s\n' "$GITHUB_HOST_KEYS"
    } > "$new_file" || { rm -f "$new_file"; return 1; }
    chmod 644 "$new_file" || { rm -f "$new_file"; return 1; }
    if [[ -n "$owner" ]]; then
        chown "$owner" "$new_file" || { rm -f "$new_file"; return 1; }
    fi
    # "mv" inside one folder is a rename: the file is replaced in one step.
    mv -f "$new_file" "$file" || { rm -f "$new_file"; return 1; }
    log "wrote GitHub's three host keys to $file"
}

log "start; $(id "$RSTUDIO_USER" 2>&1)"

# -----------------------------------------------------------------------------
# Step 1: GitHub's host keys
# -----------------------------------------------------------------------------
# The system-wide file is read by every SSH connection of every user in the container,
# whatever options the connection is started with.
if ! ensure_github_keys "$SYSTEM_KNOWN_HOSTS"; then
    log "ERROR: could not write $SYSTEM_KNOWN_HOSTS"
    FAILURES=$((FAILURES + 1))
fi

# The folder /home/rstudio/.ssh. SSH_DIR_USABLE says whether this script may write there.
SSH_DIR_USABLE=0
if belongs_to_container "$SSH_DIR"; then
    # 700 means: only the owner may read, write and enter the folder. SSH insists on it.
    if mkdir -p "$SSH_DIR" && chown "$RSTUDIO_UID:$RSTUDIO_GID" "$SSH_DIR" && chmod 700 "$SSH_DIR"; then
        SSH_DIR_USABLE=1
    else
        log "ERROR: could not prepare $SSH_DIR"
        FAILURES=$((FAILURES + 1))
    fi
else
    log "$SSH_DIR is a mount, has a mount inside it, or is reached through a symbolic link: nothing is written there. GitHub's host keys are in $SYSTEM_KNOWN_HOSTS."
fi

if [[ "$SSH_DIR_USABLE" == 1 ]]; then
    if ! ensure_github_keys "$USER_KNOWN_HOSTS" "$RSTUDIO_UID:$RSTUDIO_GID"; then
        log "ERROR: could not write $USER_KNOWN_HOSTS"
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
# The parentheses make a list. The loop takes the folders in this order and stops at
# the first one that holds a key.
for search_path in /keys /root/.ssh "$SSH_DIR" /tmp/ssh /var/ssh; do
    [[ -d "$search_path" ]] || continue     # "continue" goes on with the next folder
    log "searching for keys in: $search_path"
    valid_keys=()
    # "$search_path"/* lists the names directly in this folder. Nothing below is read.
    for candidate in "$search_path"/*; do
        # Only regular, readable files. Public keys, known hosts files and the SSH
        # settings file are no private keys.
        [[ -f "$candidate" && ! -L "$candidate" && -r "$candidate" ]] || continue
        candidate_name="${candidate##*/}"     # the name without its folder
        case "$candidate_name" in
            *.pub|known_hosts*|config|*.impact-new) continue ;;
        esac
        # A private key starts with a line such as "-----BEGIN OPENSSH PRIVATE KEY-----".
        # "head -n 1" reads the first line; "=~" compares text with a pattern. A file
        # with the GUI's key name is accepted as well. The content is never logged.
        first_line=$(head -n 1 -- "$candidate" 2>/dev/null || true)
        if [[ "$first_line" =~ BEGIN\ (RSA\ |DSA\ |EC\ |OPENSSH\ )?PRIVATE\ KEY ]] \
           || [[ "$candidate_name" =~ ^id_ed25519_[A-Za-z0-9._-]+$ ]]; then
            valid_keys+=("$candidate")
            log "found SSH key: $candidate"
        fi
    done

    # "${#valid_keys[@]}" is the number of entries in the list.
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
        # The key already lies in the right folder: only owner and mode are set.
        if chown "$RSTUDIO_UID:$RSTUDIO_GID" "$key_target" && chmod 600 "$key_target"; then
            KEY_PATH="$key_target"
        fi
    elif belongs_to_container "$key_target" \
         && ( umask 077 && tr -d '\r' < "$KEY_SOURCE" > "$key_target.impact-new" ) \
         && chown "$RSTUDIO_UID:$RSTUDIO_GID" "$key_target.impact-new" \
         && chmod 600 "$key_target.impact-new" \
         && mv -f "$key_target.impact-new" "$key_target"; then
        # "( umask 077 && ... )" runs the command in a sub-shell in which new files are
        # created readable for their owner only, so the key is never readable for others.
        KEY_PATH="$key_target"
        # The public key, if it lies next to the private one. 644: everyone may read it.
        if [[ -f "$KEY_SOURCE.pub" ]]; then
            tr -d '\r' < "$KEY_SOURCE.pub" > "$key_target.pub" \
                && chown "$RSTUDIO_UID:$RSTUDIO_GID" "$key_target.pub" \
                && chmod 644 "$key_target.pub" || true
        fi
    fi
    if [[ -n "$KEY_PATH" ]]; then
        log "SSH key ready for git: $KEY_PATH"
    else
        rm -f "$key_target.impact-new"
        log "ERROR: could not copy the SSH key to $key_target"
        FAILURES=$((FAILURES + 1))
    fi
elif [[ -n "$KEY_SOURCE" ]]; then
    log "the key $KEY_SOURCE is not copied, because nothing is written to $SSH_DIR"
fi

# -----------------------------------------------------------------------------
# Step 3: make git use the key
# -----------------------------------------------------------------------------
# "git config --global" writes into /home/rstudio/.gitconfig. core.sshCommand is the
# command git runs for every SSH connection.
GIT_CONFIG_USABLE=0
if belongs_to_container "$GIT_CONFIG_FILE"; then
    GIT_CONFIG_USABLE=1
else
    log "$GIT_CONFIG_FILE is a mount or is reached through a symbolic link: the git settings are left as they are"
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
            done <<< "$banner"
            if [[ -n "$github_user" ]]; then
                log "GitHub user of the key: $github_user"
            else
                log "GitHub gave no user name (no network at start, or the key is not registered)"
            fi
        fi

        # Second source: the file name of the key, id_<key type>_<GitHub user name>.
        if [[ -z "$github_user" && -n "$KEY_PATH" ]]; then
            if [[ "${KEY_PATH##*/}" =~ ^id_(ed25519|rsa|ecdsa|dsa)_([A-Za-z0-9._-]+)$ ]]; then
                github_user="${BASH_REMATCH[2]}"
                log "user name taken from the key file name: $github_user"
            else
                log "the key file name holds no user name (expected: id_<key type>_<user name>)"
            fi
        fi

        # "${name:-text}" gives "text" when the variable is empty.
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
