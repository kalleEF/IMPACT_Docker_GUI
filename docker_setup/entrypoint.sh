#!/bin/bash
# =============================================================================
# entrypoint.sh: the first program of every IMPACT container
# =============================================================================
#
# PURPOSE
#   Prepares the container before RStudio Server starts:
#     1. removes the ready marker of an earlier start;
#     2. gives the user "rstudio" the user number and the group number of the person
#        who started the container (only when IMPACT_UID and IMPACT_GID are given);
#     3. tells RStudio which project to open;
#     4. hands over to /init, the start program of the Rocker base image.
#
# WHEN IT RUNS
#   Docker runs this script as the first program of the container (its "entry point"),
#   as root, at every start. A container that was stopped and is started again runs it
#   again. The script gives the same result however often it runs.
#
# WORDS USED IN THIS FILE
#   UID and GID      Linux stores the owner of a file as two numbers: the user number
#                    (UID) and the group number (GID). A name such as "rstudio" is a
#                    label for a number. The labels are kept in the account files
#                    /etc/passwd (users) and /etc/group (groups).
#   mount            A folder or file from outside the container that Docker shows
#                    inside it, for example the model repository or the storage folder.
#                    Its content can belong to several people.
#   mount point      The path inside the container where a mount appears.
#   symbolic link    A small file that only points to another path.
#   environment variable   A named value given to the container, for example with
#                    "docker run -e IMPACT_UID=1005".
#
# WHAT IT CHANGES
#   Only inside the container's own files, never inside a mount (see below):
#   Always:
#     - /run/impact-ready is removed. The script impact-ready.sh writes it again when
#       the start-up has finished.
#     - The RStudio settings files in /home/rstudio/.rstudio and
#       /home/rstudio/.config/rstudio (which project to open).
#     - The owner of /home/rstudio/.rstudio and /home/rstudio/.config, with their
#       content, is set to the numbers "rstudio" has at that moment, because this script
#       writes the settings files there as root.
#   Only when IMPACT_UID and IMPACT_GID are given:
#     - the line of the user "rstudio" in /etc/passwd and the line of the group
#       "rstudio" in /etc/group;
#     - the owner of the folder entry /home/rstudio itself (nothing inside it);
#     - the owner of the entries listed in HOME_ENTRIES below. These are small settings
#       and key folders that belong to the image.
#   Only when UMASK is set and the file /home/rstudio/.Rprofile cannot be written safely:
#     - UMASK is removed before the Rocker start-up runs (see check_rocker_umask).
#
# WHAT IT NEVER TOUCHES
#   - Mounts. The script changes no owner, no access mode and no file inside a mount,
#     and it never walks through one. An entry of the home folder that is a mount point
#     or a symbolic link stays exactly as it is, and so does a file that has a second
#     name elsewhere (a "hard link"). In an entry that contains a mount point, the
#     script changes everything except the mounts: it goes down only the folders that
#     lead to a mount point, one level at a time, and stops at the mount point.
#   - Everything in /home/rstudio when the home folder itself lies on a mount (a mount
#     at /home/rstudio or at /home). The script then changes nothing in the home folder
#     and says so in one log line.
#   - The repository folder /home/rstudio/<repository>.
#   - The password of "rstudio". The Rocker base image sets it during its own start-up.
#
# ENVIRONMENT VARIABLES
#   IMPACT_UID, IMPACT_GID   The user number and the group number for "rstudio". Give both
#                            or neither. Each must be a whole number from 1000 to 60000.
#                            With neither, the numbers stay as the image has them.
#   USERID, GROUPID          The Rocker base image's own variables for the same purpose.
#                            With a USERID other than 1000, Rocker applies them by changing
#                            the owner of everything in /home/rstudio, mounts included.
#                            When IMPACT_UID and IMPACT_GID are given, this script removes
#                            USERID and GROUPID before the Rocker start-up runs, so that
#                            walk never happens. Without IMPACT_UID and IMPACT_GID they are
#                            passed on unchanged, with a WARNING in the log when mounts lie
#                            in the home folder.
#   UMASK                    Rocker's variable for the access mode of new files. Rocker then
#                            adds a line to /home/rstudio/.Rprofile as root. The script removes
#                            UMASK when that file is a link, a mount, or lies on a mount.
#   CONTAINER_REPO_NAME      The folder name of the repository in /home/rstudio. The value
#                            stored in /etc/environment when the image was built is used
#                            first, then this variable, then a built-in default.
#   SYNC_ENABLED, REPO_SYNC_PATH   Accepted and without effect. The repository is used
#                            where Docker mounts it.
#
# EXIT CODES
#   The script normally never returns: its last line replaces it with /init.
#   It ends the container early in three cases. The log then has a line in which
#   "ERROR:" follows the time stamp, for example
#     [ENTRYPOINT] 2026-11-24 21:06:05 - ERROR: IMPACT_UID=12 is not valid. ...
#     64   IMPACT_UID or IMPACT_GID is missing or is no whole number from 1000 to 60000.
#     65   Another account of the image already has the user number IMPACT_UID.
#     70   The account files could not be changed, or the check afterwards failed.
#   "docker logs <container>" shows that line. A container started with "docker run --rm"
#   (the IMPACT Docker GUI starts its containers that way) is removed together with its
#   log the moment this script ends. To read the reason, run the same start command again
#   without "--rm", then "docker logs <container>", then "docker rm <container>".
# =============================================================================

# "set -u" makes the shell stop with an error when the script reads a variable that was
# never set. A typing mistake in a variable name is then noticed at once.
set -u

# ---------------------------------------------------------------------------
# Fixed values
# ---------------------------------------------------------------------------
RSTUDIO_USER="rstudio"           # the login name RStudio Server uses
RSTUDIO_GROUP="rstudio"          # the group with the same name, created together with the user
RSTUDIO_HOME="/home/rstudio"     # the home folder of that user
READY_MARKER="/run/impact-ready" # written by impact-ready.sh when the start-up has finished
ID_MIN=1000                      # smallest and largest number Ubuntu gives to people's
ID_MAX=60000                     # accounts (UID_MIN and UID_MAX in /etc/login.defs)

EXIT_BAD_INPUT=64
EXIT_NUMBER_IN_USE=65
EXIT_IDENTITY_FAILED=70

# Entries directly inside /home/rstudio that belong to the image and that the user
# "rstudio" must own. The list is fixed on purpose: the script looks at these names only
# and never at anything else in the home folder. "NAME=(a b c)" makes a list.
#   .bashrc .bash_logout .profile   shell settings, created together with the user
#   .config                         RStudio preferences (written by Rocker and by this script)
#   .rstudio                        RStudio state (written by this script)
#   .local .cache                   RStudio and R state and temporary files
#   .ssh .gitconfig                 key copy, known hosts and git settings (git-identity.sh)
#   .Rprofile .Renviron .Rhistory   R settings (Rocker writes .Rprofile when UMASK is set)
#   R                               the personal R package folder, if one exists
HOME_ENTRIES=(.bashrc .bash_logout .profile .config .rstudio .local .cache .ssh .gitconfig .Rprofile .Renviron .Rhistory R)

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

# log TEXT: one line in the container log ("docker logs <container>").
#   "$(command)" is replaced by what the command prints; here the date and time.
#   "$*" stands for all arguments of the function, joined into one text.
log() {
    echo "[ENTRYPOINT] $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

# fail CODE TEXT: writes an error line and ends the container with the exit code CODE.
# "local" makes a variable that exists only inside the function. "$1" is the first
# argument. "shift" drops the first argument, so "$*" is the text alone. ">&2" sends the
# line to the error channel; Docker shows both channels in its log.
fail() {
    local code="$1"
    shift
    log "ERROR: $*" >&2
    log "ERROR: The container stops now (exit code $code). Nothing in a mounted folder was changed." >&2
    exit "$code"
}

# is_valid_id TEXT: succeeds when TEXT is a whole number from ID_MIN to ID_MAX.
# "[[ TEXT =~ PATTERN ]]" compares a text with a pattern (a "regular expression"): ^ is the
# start, $ the end, [1-9] one digit from 1 to 9, [0-9]{3,4} three or four digits. The
# pattern accepts four or five digits that do not start with 0. That excludes empty text,
# signs, spaces, decimal points and letters before any arithmetic is done.
# "(( ... ))" compares whole numbers; it succeeds when the comparison is true. Inside it,
# "&&" means "and". "a || b" runs b only when a failed; "return 1" ends the function
# with failure, "return 0" with success.
is_valid_id() {
    local text="$1"
    [[ "$text" =~ ^[1-9][0-9]{3,4}$ ]] || return 1
    (( text >= ID_MIN && text <= ID_MAX ))
}

# ---------------------------------------------------------------------------
# Mounts: how the script knows where they are
# ---------------------------------------------------------------------------
# The kernel lists every mount of this container in the file /proc/self/mountinfo, one
# line per mount. The fifth word of a line is the mount point. The container's own files
# are the mount with the mount point "/" (the root). The kernel writes a space, a tab, a
# line break and a backslash inside a path as \040, \011, \012 and \134; the loop below
# turns them back.
#
# Two questions decide whether the script may change a path:
#   1. Which mount holds the path? That is the longest mount point that is the path itself
#      or a folder above it (covering_mount). It must be "/", the container's own files.
#      A mount at /home or at /home/rstudio holds every path of the home folder.
#   2. Does a mount lie at the path or anywhere inside it (mount_at_or_below)?

MOUNT_POINTS=()      # filled by read_mount_points
MOUNTS_KNOWN=0       # 1 when the list could be read
FOUND_MOUNT=""       # set by covering_mount and mount_at_or_below: the mount point found
FOUND_MOUNTS=()      # set by mounts_inside: all mount points inside a path

read_mount_points() {
    MOUNT_POINTS=()
    MOUNTS_KNOWN=0
    # "[[ -r FILE ]]" is true when FILE can be read. "a || b" runs b only when a failed.
    [[ -r /proc/self/mountinfo ]] || return 1
    local raw_points mount_point
    # "mapfile -t NAME" reads lines into the list NAME. "< <(command)" feeds it the
    # output of the command. awk prints the fifth word of every line.
    mapfile -t raw_points < <(awk '{print $5}' /proc/self/mountinfo)
    # "${NAME[@]}" stands for all entries of the list NAME, each kept as one word.
    for mount_point in "${raw_points[@]}"; do
        # "${text//old/new}" replaces every "old" in text. "$'\t'" is a tab character and
        # "$'\n'" a line break. The backslash comes last, because the other three codes
        # start with one.
        mount_point="${mount_point//\\040/ }"
        mount_point="${mount_point//\\011/$'\t'}"
        mount_point="${mount_point//\\012/$'\n'}"
        mount_point="${mount_point//\\134/\\}"
        MOUNT_POINTS+=("$mount_point")      # "+=(...)" adds an entry to the list
    done
    # A container always has mounts (at least its own root). An empty list means the
    # file could not be understood, and then nothing is treated as safe.
    # "${#NAME[@]}" is the number of entries in the list NAME.
    (( ${#MOUNT_POINTS[@]} > 0 )) || return 1
    MOUNTS_KNOWN=1
}

# covering_mount PATH: stores in FOUND_MOUNT the mount point of the mount that holds
# PATH. Succeeds when that is "/", the container's own files. When the list has no "/"
# at all, FOUND_MOUNT stays empty and the function fails, so the path counts as unsafe.
covering_mount() {
    local path="$1" mount_point
    FOUND_MOUNT=""
    for mount_point in "${MOUNT_POINTS[@]}"; do
        # Inside [[ ]], the right side of == is a pattern: "$mount_point"/* means "starts
        # with the mount point and a slash". "/" holds every path. "${#text}" is the
        # number of characters of a text: the longest match wins.
        if [[ "$mount_point" == "/" || "$path" == "$mount_point" || "$path" == "$mount_point"/* ]]; then
            if (( ${#mount_point} > ${#FOUND_MOUNT} )); then
                FOUND_MOUNT="$mount_point"
            fi
        fi
    done
    [[ "$FOUND_MOUNT" == "/" ]]
}

# mount_at_or_below PATH: succeeds when PATH is a mount point or a mount point lies
# anywhere inside PATH. The first mount point found is stored in FOUND_MOUNT.
mount_at_or_below() {
    local path="$1" mount_point
    FOUND_MOUNT=""
    for mount_point in "${MOUNT_POINTS[@]}"; do
        if [[ "$mount_point" == "$path" || "$mount_point" == "$path"/* ]]; then
            FOUND_MOUNT="$mount_point"
            return 0
        fi
    done
    return 1
}

# mounts_inside PATH: stores in FOUND_MOUNTS every mount point that lies inside PATH
# (below it, not at it).
mounts_inside() {
    local path="$1" mount_point
    FOUND_MOUNTS=()
    for mount_point in "${MOUNT_POINTS[@]}"; do
        if [[ "$mount_point" == "$path"/* ]]; then
            FOUND_MOUNTS+=("$mount_point")
        fi
    done
}

# home_is_plain: succeeds when /home/rstudio is a real folder reached without any
# symbolic link on the way. "[[ -d PATH ]]" is true for a folder, "-L" for a symbolic
# link, and "!" turns true into false. "realpath" prints the path with all links
# followed; when it prints the same text, there is no link. "--" ends the options of a
# command, so a path that starts with "-" is never read as an option. "2>/dev/null"
# throws away error messages, so a missing folder gives an empty text and no message.
home_is_plain() {
    [[ -d "$RSTUDIO_HOME" && ! -L "$RSTUDIO_HOME" ]] || return 1
    [[ "$(realpath -e -- "$RSTUDIO_HOME" 2>/dev/null)" == "$RSTUDIO_HOME" ]]
}

# check_home_folder: decides once whether the script may change anything in the home
# folder at all, and stores the answer in HOME_OK (1 yes, 0 no). The answer is no when
# the mounts are unknown, when a symbolic link is on the path, or when /home/rstudio
# lies on a mount (a mount at /home/rstudio itself or at /home). A second test compares
# device numbers: "stat -c %d PATH" prints the number of the file system that holds
# PATH, and the home folder must be on the same file system as the container's root.
HOME_OK=0
check_home_folder() {
    HOME_OK=0
    if [[ "$MOUNTS_KNOWN" != 1 ]]; then
        log "WARNING: nothing in $RSTUDIO_HOME is changed (no owner, no settings file): the list of mounts could not be read."
        return 0
    fi
    if ! home_is_plain; then
        log "WARNING: nothing in $RSTUDIO_HOME is changed (no owner, no settings file): it is missing, or a symbolic link is on its path."
        return 0
    fi
    # "${NAME:-text}" gives "text" when NAME is empty.
    if ! covering_mount "$RSTUDIO_HOME"; then
        log "WARNING: nothing in $RSTUDIO_HOME is changed (no owner, no settings file): the home folder lies on the mount ${FOUND_MOUNT:-<unknown>}, and the files there belong to whoever mounted it."
        return 0
    fi
    if [[ "$(stat -c %d -- "$RSTUDIO_HOME" 2>/dev/null)" != "$(stat -c %d / 2>/dev/null)" ]]; then
        log "WARNING: nothing in $RSTUDIO_HOME is changed (no owner, no settings file): the home folder is on another file system than the container's own files."
        return 0
    fi
    HOME_OK=1
}

# own_one_folder FOLDER UID GID: gives one folder entry (nothing inside it) to UID:GID,
# when it is a real folder (no link) that lies on the container's own files.
# "stat -c %u:%g" prints the owner as "UID:GID"; nothing is changed when it already fits.
# "chown -h" changes a symbolic link itself and never the file it points to.
own_one_folder() {
    local folder="$1" uid="$2" gid="$3"
    [[ -d "$folder" && ! -L "$folder" ]] || return 0
    covering_mount "$folder" || return 0
    [[ "$(stat -c %u:%g -- "$folder")" == "$uid:$gid" ]] && return 0
    chown -h "$uid:$gid" -- "$folder" || log "WARNING: the owner of $folder could not be changed."
}

# own_tree PATH UID GID: gives PATH and everything inside it to UID:GID. Only for a path
# that holds no mount: the callers check that with mount_at_or_below first. "find" lists
# PATH and everything inside it:
#   -P      never follows a symbolic link;
#   -xdev   stays on one file system, a second barrier against entering a mount;
#   \( ! -uid U -o ! -gid G \)   keeps only entries whose owner still differs, so a
#           second start changes nothing;
#   \( -type d -o -links 1 \)    keeps folders, and files that have only this one name.
#           A file with a second name elsewhere (a "hard link") is skipped, because
#           changing its owner would change the owner of that other file as well;
#   -exec chown -h U:G {} +      runs chown on what was found. "-h" changes a symbolic
#           link itself and leaves the file it points to alone.
own_tree() {
    local path="$1" uid="$2" gid="$3"
    if ! find -P "$path" -xdev \( ! -uid "$uid" -o ! -gid "$gid" \) \( -type d -o -links 1 \) -exec chown -h "$uid:$gid" {} +; then
        log "WARNING: the owner of some entries in $path could not be changed."
    fi
}

# own_around_mounts FOLDER UID GID
#   FOLDER is a folder of the container's own files with one or more mount points
#   somewhere inside it, for example .config with a mount at .config/extra, or .local
#   with a mount at .local/share/extra. Docker creates the folders on the way to a mount
#   point (here .local and .local/share) for root, and the image's own files next to
#   them (for example .config/rstudio) still belong to the numbers of the image. RStudio
#   can then neither keep its state there nor save its preferences. This function gives
#   everything in FOLDER to UID:GID except the mounts, and never enters a mount:
#     1. FOLDER itself, one folder entry (own_one_folder);
#     2. each entry directly inside FOLDER, in one of three ways:
#        - a mount point: left exactly as it is, with everything inside it;
#        - a folder with a mount point somewhere inside it: the same two steps for that
#          folder, one level deeper (the function calls itself);
#        - anything else holds no mount: it gets own_tree, with everything inside it.
#   So the walk goes only down the folders that lead to a mount point, one level at a
#   time, and stops at the mount point. Every "find" runs on a part that holds no mount.
own_around_mounts() {
    local folder="$1" uid="$2" gid="$3" child children
    # Only a real folder (no link) on the container's own files is entered.
    [[ -d "$folder" && ! -L "$folder" ]] || return 0
    covering_mount "$folder" || return 0
    own_one_folder "$folder" "$uid" "$gid"
    # The names directly in FOLDER. "shopt -s NAME" switches a bash option on, "shopt -u"
    # switches it off again: "dotglob" makes "*" include names that start with a dot,
    # "nullglob" makes a pattern that matches nothing give an empty list. Nothing below
    # FOLDER is read here.
    shopt -s dotglob nullglob
    children=("$folder"/*)
    shopt -u dotglob nullglob
    for child in "${children[@]}"; do
        if [[ -L "$child" ]]; then
            # A symbolic link holds no mount; own_tree changes the link itself only.
            own_tree "$child" "$uid" "$gid"
        elif ! covering_mount "$child"; then
            # The child is a mount point (or lies on a mount): left as it is. "continue"
            # goes on with the next entry of the loop.
            continue
        elif mount_at_or_below "$child"; then
            own_around_mounts "$child" "$uid" "$gid"
        else
            own_tree "$child" "$uid" "$gid"
        fi
    done
}

# own_home_entry NAME UID GID
#   Gives one entry directly inside /home/rstudio, with everything in it, to UID:GID.
#   Nothing happens when the home folder may not be changed (HOME_OK), when the entry does
#   not exist, is a symbolic link or is a mount point. An entry with a mount point inside
#   it gets the treatment of own_around_mounts: everything except the mounts. The reason
#   is written to the log.
own_home_entry() {
    local name="$1" uid="$2" gid="$3"
    local path="$RSTUDIO_HOME/$name"

    # The reason was logged once by check_home_folder.
    [[ "$HOME_OK" == 1 ]] || return 0
    # -e is true for anything that exists; -L is true for a symbolic link, also for one
    # that points to nothing.
    [[ -e "$path" || -L "$path" ]] || return 0

    if [[ -L "$path" ]]; then
        log "Owner of $path left unchanged: it is a symbolic link, and the script follows no links."
        return 0
    fi
    # A path that is itself a mount point is held by its own mount.
    if ! covering_mount "$path"; then
        if [[ "$FOUND_MOUNT" == "$path" ]]; then
            log "Owner of $path left unchanged: it is a mount."
        else
            log "Owner of $path left unchanged: it lies on the mount ${FOUND_MOUNT:-<unknown>}."
        fi
        return 0
    fi
    if mount_at_or_below "$path"; then
        # Here the mounts lie inside the entry. mounts_inside lists them for the log line;
        # "${NAME[*]}" joins all entries of the list NAME into one text, with spaces between.
        mounts_inside "$path"
        own_around_mounts "$path" "$uid" "$gid"
        log "Owner of $path: mounts lie inside it (${FOUND_MOUNTS[*]}). Everything else in $path was given to $uid:$gid; the mounts and their content were left as they are."
        return 0
    fi

    # The entry belongs to the container itself and holds no mount.
    own_tree "$path" "$uid" "$gid"
}

# warn_root_folders_on_way_to_mounts: used when IMPACT_UID and IMPACT_GID are not set
# (LOCAL). The script then changes no owner apart from .rstudio and .config. A mount
# added below another entry of the home folder, for example at .local/share/extra, makes
# Docker create the folders on the way to it (.local, .local/share) for root, and
# RStudio cannot keep its state there. This looks at each folder on the way from such an
# entry down to each mount point inside it, writes one WARNING that names the folders
# that do not belong to "rstudio", and changes nothing.
#   "stat -c %u PATH" prints the user number of the owner of PATH.
#   "${text#prefix}" removes the prefix; "${text%%/*}" keeps what stands before the first
#   slash, and "${text#*/}" what stands after it. The inner loop walks down one folder
#   per round and stops before the last part, which is the mount point.
warn_root_folders_on_way_to_mounts() {
    [[ "$HOME_OK" == 1 ]] || return 0
    # With a USERID other than 1000, Rocker's start-up changes the owner of everything in
    # the home folder itself (see warn_rocker_userid), so this warning would not fit.
    # "${NAME+x}" gives "x" when the variable NAME exists, also when it is empty, and
    # nothing when it does not exist; "[[ -n TEXT ]]" is true when TEXT is not empty.
    # "[ A -ne B ]" succeeds when the whole numbers A and B differ.
    if [[ -n "${USERID+x}" ]] && [ "$USERID" -ne 1000 ] 2>/dev/null; then
        return 0
    fi
    local name path rstudio_uid mount_point rest folder not_owned=()
    rstudio_uid=$(id -u "$RSTUDIO_USER" 2>/dev/null)
    for name in "${HOME_ENTRIES[@]}"; do
        path="$RSTUDIO_HOME/$name"
        # .rstudio and .config are handed over in configure_rstudio, in every mode.
        [[ "$name" == .rstudio || "$name" == .config ]] && continue
        [[ -d "$path" && ! -L "$path" ]] || continue
        covering_mount "$path" || continue
        mounts_inside "$path"
        for mount_point in "${FOUND_MOUNTS[@]}"; do
            rest="${mount_point#"$path"/}"
            folder="$path"
            # "while true" repeats the loop until "break" leaves it.
            while true; do
                if [[ "$(stat -c %u -- "$folder" 2>/dev/null)" != "$rstudio_uid" ]]; then
                    not_owned+=("$folder")
                fi
                [[ "$rest" == */* ]] || break
                folder="$folder/${rest%%/*}"
                rest="${rest#*/}"
            done
        done
    done
    (( ${#not_owned[@]} > 0 )) || return 0
    # "printf '%s\n' LIST | sort -u" prints each folder once; "${NAME[*]}" joins a list
    # into one text.
    mapfile -t not_owned < <(printf '%s\n' "${not_owned[@]}" | sort -u)
    log "WARNING: these folders lead to a mount and do not belong to '$RSTUDIO_USER' (user number $rstudio_uid): ${not_owned[*]}. Without IMPACT_UID and IMPACT_GID this script changes no owner there. RStudio may fail to keep its state or to start a session; leave out mounts below these folders."
}

# own_home_folder UID GID: gives the folder entry /home/rstudio itself to UID:GID.
# Only this one entry changes. Nothing inside the folder is looked at. The home folder
# normally contains mounts (the repository). That is fine here, because only the folder
# entry itself changes. A home folder that lies on a mount was refused by
# check_home_folder.
own_home_folder() {
    local uid="$1" gid="$2"
    [[ "$HOME_OK" == 1 ]] || return 0
    chown -h "$uid:$gid" -- "$RSTUDIO_HOME" || log "WARNING: the owner of $RSTUDIO_HOME could not be changed."
}

# safe_to_write FILE: succeeds when the script may create or replace FILE, a settings
# file somewhere below /home/rstudio. Three conditions:
#   1. the home folder may be changed (HOME_OK, see check_home_folder);
#   2. no symbolic link is on the path ("realpath -m" follows links and also accepts
#      parts that do not exist yet);
#   3. FILE and every folder above it lie on the container's own files: none of them is
#      a mount point (covering_mount). A mount elsewhere in the same settings folder,
#      for example at .config/extra next to .config/rstudio, does not matter, because
#      writing FILE never enters it.
safe_to_write() {
    local file="$1"
    [[ "$HOME_OK" == 1 ]] || return 1
    [[ "$(realpath -m -- "$file" 2>/dev/null)" == "$file" ]] || return 1
    covering_mount "$file"
}

# ---------------------------------------------------------------------------
# Rocker variables that change files in the home folder
# ---------------------------------------------------------------------------

# warn_rocker_userid: used when IMPACT_UID and IMPACT_GID are not set. Rocker's start-up
# script 02_userconf deletes and recreates the user "rstudio" when USERID differs from
# 1000, and then runs "chown -R" on /home/rstudio: every file in the home folder gets
# the user number USERID, the files in mounted folders included, and the special access
# bits of those files (setuid, setgid) are lost. This script leaves that decision to
# whoever started the container (version 2.0 of the GUI does this in REMOTE), and writes
# a WARNING that names the mounts concerned.
warn_rocker_userid() {
    [[ -n "${USERID+x}" ]] || return 0
    # Rocker's own test, copied: "[ A -ne B ]" succeeds when the whole numbers A and B
    # differ. For a text that is no whole number it fails with an error message, which
    # "2>/dev/null" hides; Rocker then leaves the user alone as well.
    [ "$USERID" -ne 1000 ] 2>/dev/null || return 0
    if [[ "$MOUNTS_KNOWN" != 1 ]]; then
        log "WARNING: USERID=$USERID: Rocker's start-up will now change the owner of everything in $RSTUDIO_HOME to the user number $USERID, mounted folders included. The list of mounts could not be read, so they cannot be named."
        return 0
    fi
    local affected=() mount_point
    if ! covering_mount "$RSTUDIO_HOME"; then
        affected+=("$FOUND_MOUNT")
    fi
    for mount_point in "${MOUNT_POINTS[@]}"; do
        if [[ "$mount_point" == "$RSTUDIO_HOME" || "$mount_point" == "$RSTUDIO_HOME"/* ]]; then
            affected+=("$mount_point")
        fi
    done
    (( ${#affected[@]} > 0 )) || return 0
    # "${NAME[*]}" joins all entries of the list NAME into one text, with spaces between.
    log "WARNING: USERID=$USERID is set and IMPACT_UID is not. Rocker's start-up will now delete and recreate the user '$RSTUDIO_USER' and change the owner of everything in $RSTUDIO_HOME to the user number $USERID, also in these mounts: ${affected[*]}"
    log "WARNING: to keep the owners of mounted files, start the container with IMPACT_UID and IMPACT_GID, or with USERID=1000."
}

# check_rocker_umask: Rocker's start-up script 02_userconf adds the line
# "Sys.umask(mode=<UMASK>)" to /home/rstudio/.Rprofile, as root, when UMASK is set and
# differs from 022. When that file is a symbolic link, a mount, a file with a second
# name (a "hard link"), or lies on a mounted home folder, the line would land in a file
# outside the container's own files. Then UMASK is removed before the Rocker start-up
# runs, and new files get the default access mode.
check_rocker_umask() {
    [[ -n "${UMASK+x}" ]] || return 0
    # Rocker's own test, copied (see warn_rocker_userid).
    [ "$UMASK" -ne 022 ] 2>/dev/null || return 0
    local rprofile="$RSTUDIO_HOME/.Rprofile" reason=""
    # "[[ -f FILE ]]" is true for a regular file; "elif" tests the next condition when the
    # ones before were false.
    if [[ "$HOME_OK" != 1 ]]; then
        reason="the home folder may not be changed (see the WARNING above)"
    elif [[ -L "$rprofile" ]]; then
        reason="$rprofile is a symbolic link"
    elif [[ -e "$rprofile" && ! -f "$rprofile" ]]; then
        reason="$rprofile is not a regular file"
    elif mount_at_or_below "$rprofile"; then
        reason="$rprofile is a mount"
    elif [[ -f "$rprofile" && "$(stat -c %h -- "$rprofile")" != 1 ]]; then
        # "stat -c %h" prints the number of names a file has; 1 is normal.
        reason="$rprofile has a second name elsewhere (a hard link)"
    fi
    # "unset NAME" removes the variable NAME; /init and the Rocker start-up then never see it.
    if [[ -n "$reason" ]]; then
        log "WARNING: UMASK=$UMASK is removed, because $reason. Rocker's start-up would add a line to that file as root. New files get the default access mode."
        unset UMASK
    fi
}

# ---------------------------------------------------------------------------
# Changing the numbers of "rstudio" in the account files
# ---------------------------------------------------------------------------

# replace_file FILE NEW_FILE
#   Puts NEW_FILE in the place of FILE in one step ("mv" inside one folder is a rename,
#   so no program ever sees half a file). NEW_FILE first gets the owner and the access
#   mode of FILE. A new file with another number of lines is refused: the edits in this
#   script change fields inside lines and never add or remove a line.
#   "wc -l < FILE" prints the number of lines of FILE. "a || { b; c; }" runs the commands
#   in braces only when a failed.
replace_file() {
    local file="$1" new_file="$2"
    if [[ "$(wc -l < "$new_file")" -ne "$(wc -l < "$file")" ]]; then
        rm -f "$new_file"
        return 1
    fi
    if ! chown --reference="$file" "$new_file" || ! chmod --reference="$file" "$new_file"; then
        rm -f "$new_file"
        return 1
    fi
    mv -f "$new_file" "$file" || { rm -f "$new_file"; return 1; }
}

# apply_identity: the steps for IMPACT_UID and IMPACT_GID. It either completes all of
# them or ends the container with an error line.
apply_identity() {
    # --- Step 1: read and check the two values ------------------------------------
    # "${NAME+x}" gives "x" when the variable NAME exists, also when it is empty, and
    # gives nothing when it does not exist. "${NAME-}" gives the value, or nothing.
    # "[[ -z TEXT ]]" is true when TEXT is empty.
    if [[ -z "${IMPACT_UID+x}" ]]; then
        fail "$EXIT_BAD_INPUT" "IMPACT_GID is set and IMPACT_UID is missing. Give both variables or neither."
    fi
    if [[ -z "${IMPACT_GID+x}" ]]; then
        fail "$EXIT_BAD_INPUT" "IMPACT_UID is set and IMPACT_GID is missing. Give both variables or neither."
    fi
    local want_uid="${IMPACT_UID-}" want_gid="${IMPACT_GID-}"
    # "printf %q" prints a value so that odd characters (spaces, line breaks) stay visible.
    if ! is_valid_id "$want_uid"; then
        fail "$EXIT_BAD_INPUT" "IMPACT_UID=$(printf '%q' "$want_uid") is not valid. It must be a whole number from $ID_MIN to $ID_MAX."
    fi
    if ! is_valid_id "$want_gid"; then
        fail "$EXIT_BAD_INPUT" "IMPACT_GID=$(printf '%q' "$want_gid") is not valid. It must be a whole number from $ID_MIN to $ID_MAX."
    fi

    # --- Step 2: change the account files -----------------------------------------
    # /etc/passwd has one line per user:   name:x:UID:GID:comment:home:shell
    # /etc/group  has one line per group:  name:x:GID:members
    # awk reads such a file with ":" as the separator (-F:), so $1 is the name, $3 the
    # first number and $4 the second.
    local user_lines group_lines
    user_lines=$(awk -F: -v name="$RSTUDIO_USER" '$1 == name' /etc/passwd | wc -l)
    group_lines=$(awk -F: -v name="$RSTUDIO_GROUP" '$1 == name' /etc/group | wc -l)
    if [[ "$user_lines" -ne 1 ]]; then
        fail "$EXIT_IDENTITY_FAILED" "/etc/passwd has $user_lines lines for the user '$RSTUDIO_USER'; exactly one is expected."
    fi
    if [[ "$group_lines" -ne 1 ]]; then
        fail "$EXIT_IDENTITY_FAILED" "/etc/group has $group_lines lines for the group '$RSTUDIO_GROUP'; exactly one is expected."
    fi

    local old_uid old_gid old_group_gid
    old_uid=$(awk -F: -v name="$RSTUDIO_USER" '$1 == name {print $3}' /etc/passwd)
    old_gid=$(awk -F: -v name="$RSTUDIO_USER" '$1 == name {print $4}' /etc/passwd)
    old_group_gid=$(awk -F: -v name="$RSTUDIO_GROUP" '$1 == name {print $3}' /etc/group)

    # A user number that another account of the image already has: stop. Two accounts
    # with one number make programs such as ssh pick the wrong home folder.
    local other_user
    other_user=$(awk -F: -v name="$RSTUDIO_USER" -v id="$want_uid" '$1 != name && $3 == id {print $1; exit}' /etc/passwd)
    if [[ -n "$other_user" ]]; then
        fail "$EXIT_NUMBER_IN_USE" "IMPACT_UID=$want_uid is already the user number of the account '$other_user' in this image. The image must be built without that account, or the person needs another user number."
    fi

    # A group number that another group of the image already has: go on. The group
    # "rstudio" gets the same number, and both names then stand for it. Files store the
    # number only, so files created by "rstudio" carry IMPACT_GID as requested. The
    # Rocker base image treats GROUPID in the same way.
    local other_group
    other_group=$(awk -F: -v name="$RSTUDIO_GROUP" -v id="$want_gid" '$1 != name && $3 == id {print $1; exit}' /etc/group)
    if [[ -n "$other_group" ]]; then
        log "Note: the group number $want_gid is also the number of the image's group '$other_group'. Both group names now stand for this number."
    fi

    if [[ "$old_uid" == "$want_uid" && "$old_gid" == "$want_gid" && "$old_group_gid" == "$want_gid" ]]; then
        log "The user '$RSTUDIO_USER' already has the user number $want_uid and the group number $want_gid. The account files stay as they are."
    else
        # The new content is written to a second file next to the original and then
        # moved into its place. In awk, "-v OFS=:" joins the fields of a changed line
        # with ":" again; "{print}" writes every line, changed or not.
        if ! awk -F: -v OFS=: -v name="$RSTUDIO_GROUP" -v gid="$want_gid" \
                '$1 == name {$3 = gid} {print}' /etc/group > /etc/group.impact-new \
           || ! replace_file /etc/group /etc/group.impact-new; then
            fail "$EXIT_IDENTITY_FAILED" "/etc/group could not be changed."
        fi
        if ! awk -F: -v OFS=: -v name="$RSTUDIO_USER" -v uid="$want_uid" -v gid="$want_gid" \
                '$1 == name {$3 = uid; $4 = gid} {print}' /etc/passwd > /etc/passwd.impact-new \
           || ! replace_file /etc/passwd /etc/passwd.impact-new; then
            fail "$EXIT_IDENTITY_FAILED" "/etc/passwd could not be changed."
        fi
        log "Account files changed: '$RSTUDIO_USER' had the numbers $old_uid:$old_gid and now has $want_uid:$want_gid."
    fi

    # --- Step 3: check the result before any owner is changed -----------------------
    # "id -u NAME" asks the system for the user number of NAME, "id -g NAME" for its
    # main group number. Both must now give the requested numbers. When they do not,
    # the container ends here and no owner has been changed.
    local now_uid now_gid
    now_uid=$(id -u "$RSTUDIO_USER" 2>/dev/null)
    now_gid=$(id -g "$RSTUDIO_USER" 2>/dev/null)
    # "${NAME:-text}" gives "text" when NAME is empty.
    if [[ "$now_uid" != "$want_uid" || "$now_gid" != "$want_gid" ]]; then
        fail "$EXIT_IDENTITY_FAILED" "After the change, 'id $RSTUDIO_USER' reports ${now_uid:-nothing}:${now_gid:-nothing}; $want_uid:$want_gid was requested."
    fi

    # --- Step 4: owner of the home folder entry and of the image's own entries ------
    # Both helpers change nothing when check_home_folder found that the home folder may
    # not be changed.
    own_home_folder "$want_uid" "$want_gid"
    local entry
    for entry in "${HOME_ENTRIES[@]}"; do
        own_home_entry "$entry" "$want_uid" "$want_gid"
    done

    # --- Step 5: switch off the Rocker variables ------------------------------------
    # Rocker's start-up script 02_userconf reads USERID and GROUPID. With a USERID other
    # than 1000 it deletes and recreates the user and then changes the owner of
    # everything in /home/rstudio, mounts included. "unset" removes the variables from
    # this script's environment. /init is started from this script (last line) and
    # receives exactly this environment, so Rocker finds neither variable and makes no
    # change of its own.
    if [[ -n "${USERID+x}" || -n "${GROUPID+x}" ]]; then
        log "USERID=${USERID-<not set>} and GROUPID=${GROUPID-<not set>} are ignored and removed, because IMPACT_UID and IMPACT_GID are set."
    fi
    unset USERID GROUPID

    log "Identity set: $(id "$RSTUDIO_USER")"
}

# ---------------------------------------------------------------------------
# RStudio settings: which project to open
# ---------------------------------------------------------------------------

# write_settings_file FILE
#   Writes the text it receives on its input to FILE, a settings file below
#   /home/rstudio, and creates the folder for it. When FILE is not safe to write (see
#   safe_to_write) the text is thrown away and the reason is logged.
write_settings_file() {
    local file="$1"
    if ! safe_to_write "$file"; then
        cat > /dev/null     # read the text and drop it
        log "Settings file $file not written: the home folder may not be changed, the file or a folder above it is a mount, or a symbolic link is on the path."
        return 0
    fi
    # "${file%/*}" is the path without its last part, which is the folder of the file.
    # "{ a && b; }" groups two commands; "if !" runs the warning when either one fails.
    if ! { mkdir -p "${file%/*}" && cat > "$file"; }; then
        log "WARNING: $file could not be written."
    fi
}

configure_rstudio() {
    local repo_path="$1" settings_uid settings_gid
    # The settings must belong to "rstudio" as it is at this moment: with the numbers
    # from IMPACT_UID and IMPACT_GID if they were given, otherwise with the image's.
    settings_uid=$(id -u "$RSTUDIO_USER")
    settings_gid=$(id -g "$RSTUDIO_USER")

    # The RStudio project file of the repository: the first name that ends in .Rproj,
    # in alphabetical order. The pattern "$repo_path"/*.Rproj lists names in this one
    # folder only; nothing below it is read. When no file matches, the loop sees the
    # pattern text itself, which is no file, and RPROJ_FILE stays empty.
    local candidate RPROJ_FILE=""
    for candidate in "$repo_path"/*.Rproj; do
        if [[ -f "$candidate" ]]; then
            RPROJ_FILE="$candidate"
            break
        fi
    done

    # "cat > file << EOF ... EOF" writes the lines up to EOF into the file, with
    # $VARIABLES replaced by their values. Here the lines go through write_settings_file.
    if [[ -n "$RPROJ_FILE" ]]; then
        # "${path##*/}" removes everything up to the last slash: the name without its folder.
        local rproj_name="${RPROJ_FILE##*/}"
        log "Found R project file: $rproj_name"

        # RStudio user preferences: start in the repository and reopen the last project.
        write_settings_file "$RSTUDIO_HOME/.rstudio/monitored/user-settings/user-settings" << EOF
{
    "initial_working_directory": "$repo_path",
    "default_project_location": "$repo_path",
    "restore_last_project": true,
    "restore_project_required": true
}
EOF
        write_settings_file "$RSTUDIO_HOME/.config/rstudio/rstudio-prefs.json" << EOF
{
    "initial_working_directory": "$repo_path",
    "default_project_location": "$repo_path",
    "restore_last_project": true
}
EOF
        # The project that counts as "last opened".
        write_settings_file "$RSTUDIO_HOME/.rstudio/projects_settings/last-project-path" << EOF
$RPROJ_FILE
EOF
        write_settings_file "$RSTUDIO_HOME/.rstudio/projects_settings/project-settings" << EOF
{
    "project_path": "$RPROJ_FILE"
}
EOF
        log "RStudio configured to open project: $rproj_name in $repo_path"
    else
        log "No .Rproj file found in $repo_path. RStudio will start in the repository folder."
        # At least the working directory.
        write_settings_file "$RSTUDIO_HOME/.rstudio/monitored/user-settings/user-settings" << EOF
{
    "initial_working_directory": "$repo_path"
}
EOF
    fi

    # This script runs as root, so the files it wrote belong to root. Give the two
    # settings folders to "rstudio". own_home_entry skips a folder that is a mount
    # point or a symbolic link, and in a folder with a mount inside it changes
    # everything except the mounts.
    own_home_entry .rstudio "$settings_uid" "$settings_gid"
    own_home_entry .config "$settings_uid" "$settings_gid"
}

# =============================================================================
# Main part
# =============================================================================
log "Container starting..."

# The marker of an earlier start must go first: the GUI waits for the marker, and a
# stopped container keeps its files. "rm -f" is silent when the file does not exist.
rm -f "$READY_MARKER"

# --- Mounts and the home folder --------------------------------------------------------
# The list of mounts is read once; the mounts do not change while this script runs.
if ! read_mount_points; then
    log "WARNING: /proc/self/mountinfo could not be read. No owner is changed and no settings file is written, because mounts cannot be told apart from the container's own folders."
fi
check_home_folder

# --- User and group numbers --------------------------------------------------------
if [[ -z "${IMPACT_UID+x}" && -z "${IMPACT_GID+x}" ]]; then
    log "IMPACT_UID and IMPACT_GID are not set: the user and group numbers of '$RSTUDIO_USER' are left to the image and to the Rocker start-up."
    warn_rocker_userid
    warn_root_folders_on_way_to_mounts
else
    apply_identity
fi

# --- Repository name ------------------------------------------------------------------
# The image build wrote a line CONTAINER_REPO_NAME=<name> into /etc/environment.
# "source" reads that file as shell text, which sets the variable. "|| true" makes a
# missing file count as success.
source /etc/environment 2>/dev/null || true
CONTAINER_REPO_NAME="${CONTAINER_REPO_NAME:-IMPACT-NCD-Germany_Base}"
CONTAINER_REPO_PATH="$RSTUDIO_HOME/$CONTAINER_REPO_NAME"

# --- SYNC_ENABLED and REPO_SYNC_PATH --------------------------------------------------
# Both are accepted, so that a start command which passes them keeps working, and both
# have no effect: the repository is used where Docker mounts it.
if [[ "${SYNC_ENABLED:-false}" == "true" ]]; then
    log "Note: SYNC_ENABLED=true has no effect. The repository is used where it is mounted ($CONTAINER_REPO_PATH)."
fi

# --- Working folder ----------------------------------------------------------------------
# "cd folder || { ... }" runs the part in braces when the folder cannot be entered.
cd "$CONTAINER_REPO_PATH" || {
    log "Warning: Could not change to $CONTAINER_REPO_PATH"
}

# --- RStudio settings --------------------------------------------------------------------
log "Configuring RStudio to load R project automatically..."
configure_rstudio "$CONTAINER_REPO_PATH"

# --- UMASK ------------------------------------------------------------------------------
check_rocker_umask

log "Starting /init, the start program of the Rocker image..."

# "exec" replaces this script with /init, the start program of the Rocker base image.
# /init keeps the process number 1 and receives the environment of this script. It runs
# the scripts in /etc/cont-init.d in name order (01_set_env, 02_userconf, git-identity,
# zz-impact-ready) and then starts RStudio Server.
exec /init
