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
#   Always:
#     - /run/impact-ready is removed. The script impact-ready.sh writes it again when
#       the start-up has finished.
#     - The RStudio settings files in /home/rstudio/.rstudio and
#       /home/rstudio/.config/rstudio (which project to open).
#   Only when IMPACT_UID and IMPACT_GID are given:
#     - the line of the user "rstudio" in /etc/passwd and the line of the group
#       "rstudio" in /etc/group;
#     - the owner of the folder entry /home/rstudio itself (nothing inside it);
#     - the owner of the entries listed in HOME_ENTRIES below. These are small settings
#       and key folders that belong to the image.
#
# WHAT IT NEVER TOUCHES
#   - Mounts. The script changes no owner, no access mode and no file inside a mount,
#     and it never walks through one. An entry of the home folder that is a mount point,
#     that contains a mount point, or that is a symbolic link stays exactly as it is.
#   - The repository folder /home/rstudio/<repository>.
#   - The password of "rstudio". The Rocker base image sets it during its own start-up.
#
# ENVIRONMENT VARIABLES
#   IMPACT_UID, IMPACT_GID   The user number and the group number for "rstudio". Give both
#                            or neither. Each must be a whole number from 1000 to 60000.
#                            With neither, the numbers stay as the image has them.
#   USERID, GROUPID          The Rocker base image's own variables for the same purpose.
#                            Rocker applies them by changing the owner of everything in
#                            /home/rstudio, mounts included. When IMPACT_UID and IMPACT_GID
#                            are given, this script removes USERID and GROUPID before the
#                            Rocker start-up runs, so that walk never happens.
#   CONTAINER_REPO_NAME      The folder name of the repository in /home/rstudio. The value
#                            stored in /etc/environment when the image was built is used
#                            first, then this variable, then a built-in default.
#   SYNC_ENABLED, REPO_SYNC_PATH   Accepted and ignored. The repository is used directly
#                            where Docker mounts it.
#
# EXIT CODES
#   The script normally never returns: its last line replaces it with /init.
#   It ends the container early, with a line that starts with "ERROR", in three cases:
#     64   IMPACT_UID or IMPACT_GID is missing or is no whole number from 1000 to 60000.
#     65   Another account of the image already has the user number IMPACT_UID.
#     70   The account files could not be changed, or the check afterwards failed.
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
# and never at anything else in the home folder.
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
log() {
    echo "[ENTRYPOINT] $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

# fail CODE TEXT: writes an error line and ends the container with the exit code CODE.
# ">&2" sends the line to the error channel; Docker shows both channels in its log.
fail() {
    local code="$1"
    shift
    log "ERROR: $*" >&2
    log "ERROR: The container stops now (exit code $code). Nothing in a mounted folder was changed." >&2
    exit "$code"
}

# is_valid_id TEXT: succeeds when TEXT is a whole number from ID_MIN to ID_MAX.
# The pattern accepts four or five digits that do not start with 0. That excludes empty
# text, signs, spaces, decimal points and letters before any arithmetic is done.
is_valid_id() {
    local text="$1"
    [[ "$text" =~ ^[1-9][0-9]{3,4}$ ]] || return 1
    (( text >= ID_MIN && text <= ID_MAX ))
}

# ---------------------------------------------------------------------------
# Mounts: how the script knows where they are
# ---------------------------------------------------------------------------
# The kernel lists every mount of this container in the file /proc/self/mountinfo, one
# line per mount. The fifth word of a line is the mount point. The kernel writes a space,
# a tab, a line break and a backslash inside a path as \040, \011, \012 and \134; the
# loop below turns them back.

MOUNT_POINTS=()      # filled by read_mount_points
MOUNTS_KNOWN=0       # 1 when the list could be read
FOUND_MOUNT=""       # set by mount_at_or_below: the mount point it found

read_mount_points() {
    MOUNT_POINTS=()
    MOUNTS_KNOWN=0
    [[ -r /proc/self/mountinfo ]] || return 1
    local raw_points mount_point
    # "mapfile -t NAME" reads lines into the list NAME. "< <(command)" feeds it the
    # output of the command. awk prints the fifth word of every line.
    mapfile -t raw_points < <(awk '{print $5}' /proc/self/mountinfo)
    for mount_point in "${raw_points[@]}"; do
        # "${text//old/new}" replaces every "old" in text. The backslash comes last,
        # because the other three codes start with one.
        mount_point="${mount_point//\\040/ }"
        mount_point="${mount_point//\\011/$'\t'}"
        mount_point="${mount_point//\\012/$'\n'}"
        mount_point="${mount_point//\\134/\\}"
        MOUNT_POINTS+=("$mount_point")
    done
    # A container always has mounts (at least its own root). An empty list means the
    # file could not be understood, and then nothing is treated as safe.
    (( ${#MOUNT_POINTS[@]} > 0 )) || return 1
    MOUNTS_KNOWN=1
}

# mount_at_or_below PATH: succeeds when PATH is a mount point or a mount point lies
# anywhere inside PATH. The mount point found is stored in FOUND_MOUNT.
mount_at_or_below() {
    local path="$1" mount_point
    FOUND_MOUNT=""
    for mount_point in "${MOUNT_POINTS[@]}"; do
        # Inside [[ ]], the right side of == is a pattern: "$path"/* means "starts with
        # PATH and a slash".
        if [[ "$mount_point" == "$path" || "$mount_point" == "$path"/* ]]; then
            FOUND_MOUNT="$mount_point"
            return 0
        fi
    done
    return 1
}

# home_is_plain: succeeds when /home/rstudio is a real folder reached without any
# symbolic link on the way. "realpath" prints the path with all links followed; when it
# prints the same text, there is no link.
home_is_plain() {
    [[ -d "$RSTUDIO_HOME" && ! -L "$RSTUDIO_HOME" ]] || return 1
    [[ "$(realpath -e -- "$RSTUDIO_HOME" 2>/dev/null)" == "$RSTUDIO_HOME" ]]
}

# own_home_entry NAME UID GID
#   Gives one entry directly inside /home/rstudio, with everything in it, to UID:GID.
#   Nothing happens when the entry does not exist, is a symbolic link, is a mount point
#   or contains a mount point. The reason is written to the log.
own_home_entry() {
    local name="$1" uid="$2" gid="$3"
    local path="$RSTUDIO_HOME/$name"

    # -e is true for anything that exists; -L is true for a symbolic link, also for one
    # that points to nothing.
    [[ -e "$path" || -L "$path" ]] || return 0

    if [[ "$MOUNTS_KNOWN" != 1 ]]; then
        log "Owner of $path left unchanged: the list of mounts could not be read."
        return 0
    fi
    if [[ -L "$path" ]]; then
        log "Owner of $path left unchanged: it is a symbolic link, and the script follows no links."
        return 0
    fi
    if mount_at_or_below "$path"; then
        log "Owner of $path left unchanged: a mount is at or inside it ($FOUND_MOUNT)."
        return 0
    fi

    # The entry belongs to the container itself and holds no mount. "find" lists it and
    # everything inside it:
    #   -P      never follows a symbolic link;
    #   -xdev   stays on one file system, a second barrier against entering a mount;
    #   \( ! -uid U -o ! -gid G \)   keeps only entries whose owner still differs, so a
    #           second start changes nothing;
    #   -exec chown -h U:G {} +      runs chown on what was found. "-h" changes a symbolic
    #           link itself and leaves the file it points to alone.
    if ! find -P "$path" -xdev \( ! -uid "$uid" -o ! -gid "$gid" \) -exec chown -h "$uid:$gid" {} +; then
        log "WARNING: the owner of some entries in $path could not be changed."
    fi
}

# own_home_folder UID GID: gives the folder entry /home/rstudio itself to UID:GID.
# Only this one entry changes. Nothing inside the folder is looked at.
own_home_folder() {
    local uid="$1" gid="$2"
    if [[ "$MOUNTS_KNOWN" != 1 ]]; then
        log "WARNING: owner of $RSTUDIO_HOME left unchanged: the list of mounts could not be read."
        return 0
    fi
    if ! home_is_plain; then
        log "WARNING: owner of $RSTUDIO_HOME left unchanged: it is missing, or a symbolic link is on its path."
        return 0
    fi
    # The home folder normally contains mounts (the repository). That is fine here,
    # because only the folder entry itself changes. A home folder that is itself a
    # mount point belongs to whoever mounted it and stays as it is.
    local mount_point
    for mount_point in "${MOUNT_POINTS[@]}"; do
        if [[ "$mount_point" == "$RSTUDIO_HOME" ]]; then
            log "WARNING: owner of $RSTUDIO_HOME left unchanged: the home folder itself is a mount."
            return 0
        fi
    done
    chown -h "$uid:$gid" "$RSTUDIO_HOME" || log "WARNING: the owner of $RSTUDIO_HOME could not be changed."
}

# safe_to_write FILE: succeeds when the script may create or replace FILE, a settings
# file somewhere below /home/rstudio. Three conditions:
#   1. the list of mounts is known;
#   2. no symbolic link is on the path ("realpath -m" follows links and also accepts
#      parts that do not exist yet);
#   3. the entry of the home folder that holds FILE (for example .config) is no mount
#      point and contains none.
safe_to_write() {
    local file="$1"
    [[ "$MOUNTS_KNOWN" == 1 ]] || return 1
    [[ "$(realpath -m -- "$file" 2>/dev/null)" == "$file" ]] || return 1
    # "${file#prefix}" removes the prefix; "${text%%/*}" keeps what stands before the
    # first slash. Together they give the name of the entry directly in the home folder.
    local inside="${file#"$RSTUDIO_HOME"/}"
    local top="${inside%%/*}"
    ! mount_at_or_below "$RSTUDIO_HOME/$top"
}

# ---------------------------------------------------------------------------
# Changing the numbers of "rstudio" in the account files
# ---------------------------------------------------------------------------

# replace_file FILE NEW_FILE
#   Puts NEW_FILE in the place of FILE in one step ("mv" inside one folder is a rename,
#   so no program ever sees half a file). NEW_FILE first gets the owner and the access
#   mode of FILE. A new file with another number of lines is refused: the edits in this
#   script change fields inside lines and never add or remove a line.
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

# apply_identity: the five steps for IMPACT_UID and IMPACT_GID. It either completes all
# of them or ends the container with an error line.
apply_identity() {
    # --- Step 1: read and check the two values ------------------------------------
    # "${NAME+x}" gives "x" when the variable NAME exists, also when it is empty, and
    # gives nothing when it does not exist. "${NAME-}" gives the value, or nothing.
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
    if [[ "$now_uid" != "$want_uid" || "$now_gid" != "$want_gid" ]]; then
        fail "$EXIT_IDENTITY_FAILED" "After the change, 'id $RSTUDIO_USER' reports ${now_uid:-nothing}:${now_gid:-nothing}; $want_uid:$want_gid was requested."
    fi

    # --- Step 4: owner of the home folder entry and of the image's own entries ------
    if ! read_mount_points; then
        log "WARNING: /proc/self/mountinfo could not be read. No owner is changed, because mounts cannot be told apart from the container's own folders."
    fi
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
        log "Settings file $file not written: its folder is a mount, contains a mount, or a symbolic link is on the path."
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
        local rproj_name="${RPROJ_FILE##*/}"     # the file name without its folder
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
    # point, contains one or is a symbolic link.
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

# --- User and group numbers --------------------------------------------------------
if [[ -z "${IMPACT_UID+x}" && -z "${IMPACT_GID+x}" ]]; then
    log "IMPACT_UID and IMPACT_GID are not set: the user and group numbers of '$RSTUDIO_USER' are left to the image and to the Rocker start-up."
else
    apply_identity
fi

# --- Mounts, for the settings step --------------------------------------------------
# Read again here, so the list is also there when apply_identity did not run.
if ! read_mount_points; then
    log "WARNING: /proc/self/mountinfo could not be read. RStudio settings are not written."
fi

# --- Repository name ------------------------------------------------------------------
# The image build wrote a line CONTAINER_REPO_NAME=<name> into /etc/environment.
# "source" reads that file as shell text, which sets the variable. "2>/dev/null || true"
# hides the message and the error when the file is missing.
source /etc/environment 2>/dev/null || true
CONTAINER_REPO_NAME="${CONTAINER_REPO_NAME:-IMPACT-NCD-Germany_Base}"
CONTAINER_REPO_PATH="$RSTUDIO_HOME/$CONTAINER_REPO_NAME"

# --- The sync routine of earlier versions ------------------------------------------------
# Earlier versions copied the repository between a second mount and the image. The
# repository is now used directly where Docker mounts it. The two variables are still
# accepted, so an old start command keeps working.
if [[ "${SYNC_ENABLED:-false}" == "true" ]]; then
    log "Note: SYNC_ENABLED=true has no effect. This image has no sync routine; the repository is used where it is mounted ($CONTAINER_REPO_PATH)."
fi

# --- Working folder ----------------------------------------------------------------------
# "cd folder || { ... }" runs the part in braces when the folder cannot be entered.
cd "$CONTAINER_REPO_PATH" || {
    log "Warning: Could not change to $CONTAINER_REPO_PATH"
}

# --- RStudio settings --------------------------------------------------------------------
log "Configuring RStudio to load R project automatically..."
configure_rstudio "$CONTAINER_REPO_PATH"

log "Starting original entrypoint..."

# "exec" replaces this script with /init, the start program of the Rocker base image.
# /init keeps the process number 1 and receives the environment of this script. It runs
# the scripts in /etc/cont-init.d in name order (01_set_env, 02_userconf, git-identity,
# zz-impact-ready) and then starts RStudio Server.
exec /init
