#!/bin/bash
# =============================================================================
# impact-storage.sh: the shared storage folders and their access rules
#
# Purpose
#   1. Questions about paths and file systems (is a path inside another one,
#      which file system holds it, does it accept access control lists).
#   2. The safety check for a folder that is to receive the shared rules
#      (inside a storage root, no system folder, no home folder).
#   3. The shared rules themselves, applied to ONE folder or to given files,
#      never to the content of a folder. impact-add-model and
#      impact-share-folder both use these functions, so the rules exist in
#      one place only.
#
# The shared rules
#   Folder: group = the shared group; the group may read, write and enter;
#           "setgid" is set (new entries inherit the group of the folder);
#           a "default ACL" is set (new entries are writable for the group
#           whatever the creating account's own default, its umask, says).
#   File:   group = the shared group; the group may read and write; the
#           group may execute where the file is executable.
#   The rights of the owner and of all others stay as they are.
#   An ACL (access control list) is a list of extra access entries that Linux
#   stores next to the usual owner, group and mode of a file.
#
# Who runs it
#   Nobody directly. impact-common.sh loads it.
#
# Usage (inside a command, after loading impact-common.sh and the settings)
#   impact_storage_check_target "$path" || impact_die 2 "$IMPACT_STORAGE_ERROR" ""
#   if ! impact_shared_dir_is_ok "$IMPACT_STORAGE_PATH" "$group"; then
#       impact_do "Apply the shared rules to $IMPACT_STORAGE_PATH" \
#           impact_shared_apply_dir "$IMPACT_STORAGE_PATH" "$group"
#   fi
#
# What it changes on the system
#   Loading changes nothing. impact_shared_apply_dir and
#   impact_shared_apply_files change group, mode and ACL of the entries they
#   are given. impact_acl_probe creates and removes one temporary folder.
#
# How to undo
#   Nothing to undo for the file itself. impact-share-folder saves the
#   previous rights before it changes them.
# =============================================================================

# -----------------------------------------------------------------------------
# Reading help: bash constructs that appear in this file
#   NAME=text            store a text in the variable NAME; "$NAME" reads it
#   local NAME           a variable that exists only inside one function
#   "$1" "$2" "$@" "$#"  first parameter, second parameter, all parameters,
#                        number of parameters
#   "${NAME:-text}"      the value of NAME, or "text" when NAME is unset or empty
#   $( command )         the text that the command prints
#   [[ ... ]]            a test: -f plain file, -d folder, -L symbolic link,
#                        -e exists, -r readable, -x executable, -z empty text,
#                        -n text with content, == equal, != different,
#                        =~ matches a pattern
#   (( ... ))            arithmetic: true when the result is not zero
#   A && B               run B only when A succeeded
#   A || B               run B only when A failed
#   ! command            true when the command fails
#   if / case / for / while   branches and loops; "case" compares one value
#                        with several patterns
#   >file >>file <file   write to a file (replace it / add to its end), read
#                        from a file
#   2>/dev/null  >&2     throw error messages away / write to the error channel
#   command1 | command2  hand the output of command1 to command2
#   return N / exit N    end the function / the script with status N; 0 means
#                        success
#   list=(a b)  "${list[@]}"  "${#list[@]}"   a list, all its entries, their number
#   < <(command)  <(command)   hand the output of a command to a loop, to
#                        mapfile or to another program as if it were a file
#                        ("process substitution")
#   declare -A NAME  local -A NAME   a list whose entries are found by a name
#                        (an "associative array"): NAME[key]=value, "${NAME[key]}"
#   IFS=: read -r A B    split one line at the character after "IFS=" (here
#                        ":") into the variables A and B; with -a LIST into a list
#   while IFS= read -r line   read input line by line, exactly as written:
#                        "IFS=" keeps blanks at both ends, -r keeps backslashes
#   <<<"$text"           hand a text to a command as its input ("here-string")
#   "${NAME:0:10}"       a part of the text: from position 0, 10 characters
# Constructs beyond these are explained where they are first used.
# -----------------------------------------------------------------------------

# shellcheck disable=SC2034
# Reason for SC2034 (variable appears unused): the variables set here are
# read by the commands that load this file.

# Results of impact_storage_check_target.
IMPACT_STORAGE_PATH=''       # the checked folder, with all symbolic links resolved
IMPACT_STORAGE_ROOT=''       # the storage root that holds it, also resolved
IMPACT_STORAGE_ERROR=''      # why a path was refused

# Set by impact_shared_apply_dir and impact_shared_apply_files: 1 when the
# call changed something, 0 when everything was already right.
IMPACT_SHARED_CHANGED=0

# Internal state.
IMPACT__SHARED_FD=''                 # open handle of the folder being worked on
declare -gA IMPACT__ACL=()           # the ACL entries read last
IMPACT__REAL_ROOTS=()                # storage roots with symbolic links resolved
IMPACT__REAL_ROOTS_FOR=''            # the SHARED_ROOTS text they were computed from

# =============================================================================
# Paths and file systems
# =============================================================================

# impact_path_is_below CHILD PARENT
#   Result: success when the path CHILD lies inside the folder PARENT (and is
#   not PARENT itself). Pure text comparison: both must be clean absolute
#   paths (see impact_valid_abs_path), and nothing is looked up on disk.
#   Example: impact_path_is_below /mnt/disk_a/shared/Model /mnt/disk_a/shared
impact_path_is_below() {
    local child="$1" parent="$2"
    [[ "$child" == /* && "$parent" == /* ]] || return 1
    # Refuse texts with "." or ".." parts or doubled slashes: for those, the
    # text says nothing reliable about the place on disk.
    [[ "$child/" != */./* && "$child/" != */../* && "$child" != *//* ]] || return 1
    [[ "$parent/" != */./* && "$parent/" != */../* && "$parent" != *//* ]] || return 1
    if [[ "$parent" == '/' ]]; then
        [[ "$child" != '/' ]]
        return
    fi
    parent="${parent%/}"
    # "$parent"/* means: the parent text, a slash, then anything.
    [[ "$child" == "$parent"/* ]]
}

# impact_nearest_existing PATH
#   Prints PATH itself when it exists, otherwise the closest parent folder
#   that exists.
impact_nearest_existing() {
    local path="$1"
    while [[ ! -e "$path" && "$path" != '/' ]]; do
        path="$(dirname -- "$path")"
    done
    printf '%s\n' "$path"
}

# impact_fs_type PATH
#   Prints the type of the file system that holds PATH (for example ext4).
#   For a path that does not exist yet, the closest existing parent counts.
impact_fs_type() {
    local existing
    existing="$(impact_nearest_existing "$1")"
    # findmnt lists mounted file systems; "-T" finds the one that holds a
    # path, "-n" leaves out the heading, "-o FSTYPE" prints the type only.
    findmnt -n -o FSTYPE -T "$existing" 2>/dev/null | head -n 1
}

# impact_fs_type_supported TYPE
#   Result: success for the file systems the shared storage may use: ext4,
#   xfs and btrfs. They keep Linux owners, groups, modes and ACLs.
impact_fs_type_supported() {
    [[ "$1" == 'ext4' || "$1" == 'xfs' || "$1" == 'btrfs' ]]
}

# impact_fs_mount_options PATH
#   Prints the mount options of the file system that holds PATH, separated
#   by commas.
impact_fs_mount_options() {
    local existing
    existing="$(impact_nearest_existing "$1")"
    findmnt -n -o OPTIONS -T "$existing" 2>/dev/null | head -n 1
}

# impact_is_mount_point PATH
#   Result: success when PATH is the top folder of a mounted file system.
impact_is_mount_point() {
    mountpoint -q -- "$1" 2>/dev/null
}

# impact_acl_probe FOLDER
#   Tests by a real write whether FOLDER accepts ACL entries: it creates a
#   temporary folder inside FOLDER, sets one access entry and one default
#   entry on it, reads them back, and removes the temporary folder.
#   Result: success when both entries were stored.
#   Example: impact_do --transient "Test that $root accepts ACLs" impact_acl_probe "$root"
impact_acl_probe() {
    local folder="$1" probe listing status=1
    probe="$(mktemp -d -- "$folder/.impact-acl-test.XXXXXXXXXX")" || return 1
    IMPACT_TMP_ITEMS+=("$probe")
    # 65534 is the number of the account "nobody"; a numeric entry needs no
    # particular account to exist.
    if setfacl -m u:65534:r-x -- "$probe" 2>/dev/null &&
        setfacl -d -m u::rwx,g::rwx,o::--- -- "$probe" 2>/dev/null; then
        listing="$(getfacl -c -p -n -E -- "$probe" 2>/dev/null)" || listing=''
        if [[ "$listing" == *'user:65534:r-x'* && "$listing" == *'default:group::rwx'* ]]; then
            status=0
        fi
    fi
    rmdir -- "$probe" 2>/dev/null || rm -rf -- "$probe"
    return "$status"
}

# impact_is_system_path PATH
#   Result: success when PATH is a folder of the operating system or of the
#   IMPACT commands, where shared-storage rules must never be applied: the
#   top-level folders themselves (/, /etc, /home, /mnt, /srv, /var and so
#   on), everything inside the system folders (/etc, /usr, /var, /tmp and so
#   on), /opt/impact, and the model folder MODEL_DIR.
#   PATH must be a clean absolute path with symbolic links already resolved.
impact_is_system_path() {
    local path="$1" folder
    for folder in / /bin /boot /dev /etc /home /lib /lib32 /lib64 /libx32 /lost+found \
        /media /mnt /opt /proc /root /run /sbin /snap /srv /sys /tmp /usr /var; do
        if [[ "$path" == "$folder" ]]; then
            return 0
        fi
    done
    for folder in /bin /boot /dev /etc /lib /lib32 /lib64 /libx32 /proc /root /run /sbin \
        /snap /sys /tmp /usr /var "$IMPACT_INSTALL_DIR" "${IMPACT_CONF[MODEL_DIR]:-}"; do
        if [[ -z "$folder" ]]; then
            continue
        fi
        if [[ "$path" == "$folder" ]] || impact_path_is_below "$path" "$folder"; then
            return 0
        fi
    done
    return 1
}

# impact__perm_number TEXT
#   Internal: prints the number of a rights text such as "r-x" (r 4, w 2,
#   x 1; "r-x" is 5).
impact__perm_number() {
    local text="$1" number=0
    [[ "${text:0:1}" == 'r' ]] && number=$((number + 4))
    [[ "${text:1:1}" == 'w' ]] && number=$((number + 2))
    [[ "${text:2:1}" == 'x' ]] && number=$((number + 1))
    printf '%s' "$number"
}

# impact_member_can_use FOLDER GID RIGHTS
#   Read-only: success when a member of the group with the number GID has
#   RIGHTS on FOLDER (1: enter; 5: enter and list), counting the member as
#   neither the owner of FOLDER nor a member of other groups. The rule is
#   the one of the kernel: when FOLDER belongs to that group, or has an ACL
#   entry for it, the group rights decide (each entry limited by the ACL
#   "mask"), and the rights of all others count only when no group entry
#   applies. So a folder of the group with mode 705 locks members out,
#   although all others may enter it.
#   Example: impact_member_can_use /mnt/disk_a/shared 1005 5
impact_member_can_use() {
    local folder="$1" gid="$2" need="$3" facts mode group line
    local owning other named='' mask='' matched=0
    facts="$(stat -c '%a %g' -- "$folder" 2>/dev/null)" || return 1
    mode="${facts%% *}"
    group="${facts##* }"
    # From the mode alone (exact for a folder without an ACL): "8#" reads
    # the number as octal; ">> 3" moves the group rights to the last digit,
    # "& 7" keeps that digit.
    owning=$(((8#$mode >> 3) & 7))
    other=$((8#$mode & 7))
    if impact_have_tool getfacl; then
        # getfacl -n prints numbers for owners and groups; --omit-header
        # leaves out the "# file:" lines. A comment "#effective:..." after
        # an entry is cut off (the mask is applied below).
        while IFS= read -r line; do
            line="${line%%[[:space:]]*}"
            case "$line" in
                group::*) owning="$(impact__perm_number "${line#group::}")" ;;
                "group:$gid:"*) named="$(impact__perm_number "${line#group:"$gid":}")" ;;
                mask::*) mask="$(impact__perm_number "${line#mask::}")" ;;
                other::*) other="$(impact__perm_number "${line#other::}")" ;;
                *) ;;
            esac
        done < <(getfacl -n -p --omit-header -- "$folder" 2>/dev/null)
    fi
    if [[ -n "$mask" ]]; then
        owning=$((owning & mask))
        [[ -z "$named" ]] || named=$((named & mask))
    fi
    if [[ "$group" == "$gid" ]]; then
        matched=1
        (((owning & need) == need)) && return 0
    fi
    if [[ -n "$named" ]]; then
        matched=1
        (((named & need) == need)) && return 0
    fi
    ((matched == 0)) && (((other & need) == need))
}

# impact_member_blocked_folders PATH GID
#   Read-only: prints the folders from / down to PATH that a member of the
#   group with the number GID cannot pass (impact_member_can_use): the
#   folders above PATH need the right to enter, PATH itself the rights to
#   enter and to list. Each line: the folder, a tab, and the command that
#   gives members that right.
#   Example: impact_member_blocked_folders /mnt/disk_a/shared 1005
impact_member_blocked_folders() {
    local path="$1" gid="$2" current='' part need fix group_name group
    local -a parts=()
    group_name="$(impact_group_by_gid "$gid" 2>/dev/null)" || group_name="$gid"
    # Split the path at "/" into its parts.
    IFS='/' read -r -a parts <<<"${path#/}"
    for part in '' "${parts[@]}"; do
        if [[ -n "$part" ]]; then
            current="$current/$part"
        fi
        need=1
        if [[ "${current:-/}" == "$path" ]]; then
            need=5
        fi
        impact_member_can_use "${current:-/}" "$gid" "$need" && continue
        group="$(stat -c '%g' -- "${current:-/}" 2>/dev/null)" || group=''
        if ((need == 5)); then
            if [[ "$group" == "$gid" ]]; then
                fix="sudo chmod g+rx ${current:-/}"
            else
                fix="sudo chgrp $group_name ${current:-/} && sudo chmod g+rx ${current:-/}"
            fi
        elif [[ "$group" == "$gid" ]]; then
            fix="sudo chmod g+x ${current:-/}"
        else
            fix="sudo chmod o+x ${current:-/}"
        fi
        printf '%s\t%s\n' "${current:-/}" "$fix"
    done
}

# impact_is_home_path PATH
#   Result: success when PATH is /home, lies inside /home, or is or lies
#   inside the home folder of any person's account (user number 1000 or
#   higher).
#   PATH must be a clean absolute path with symbolic links already resolved.
impact_is_home_path() {
    local path="$1" name uid home
    if [[ "$path" == '/home' ]] || impact_path_is_below "$path" /home; then
        return 0
    fi
    # Read the account database line by line; the fields are separated by
    # ":" (name, password mark, user number, group number, text, home, shell).
    while IFS=: read -r name _ uid _ _ home _; do
        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        ((uid >= 1000 && uid != 65534)) || continue
        [[ "$home" == /* && "$home" != '/' ]] || continue
        if [[ "$path" == "$home" ]] || impact_path_is_below "$path" "$home"; then
            return 0
        fi
    done < <(getent passwd)
    return 1
}

# impact__real_roots
#   Internal: fills IMPACT__REAL_ROOTS with the storage roots of the loaded
#   settings, symbolic links resolved. Roots that do not exist are left out.
#   A complete list is computed once and reused until SHARED_ROOTS changes.
impact__real_roots() {
    local configured="${IMPACT_CONF[SHARED_ROOTS]:-}" root real
    local -a roots=()
    local complete=1
    if [[ "$IMPACT__REAL_ROOTS_FOR" == "$configured" && -n "$configured" ]]; then
        return 0
    fi
    IMPACT__REAL_ROOTS=()
    impact_split_list "$configured" roots
    for root in "${roots[@]}"; do
        # realpath -e prints the path with every symbolic link resolved and
        # fails when the path does not exist.
        if real="$(realpath -e -- "$root" 2>/dev/null)" && [[ -d "$real" ]]; then
            IMPACT__REAL_ROOTS+=("$real")
        else
            complete=0
        fi
    done
    # Remember the result only when every root was found; a root that is
    # created later must be noticed by the next call.
    if ((complete == 1)); then
        IMPACT__REAL_ROOTS_FOR="$configured"
    else
        IMPACT__REAL_ROOTS_FOR=''
    fi
}

# impact_storage_real_root ROOT
#   Prints the storage root ROOT with every symbolic link resolved. ROOT must
#   be listed in SHARED_ROOTS exactly as given and must exist.
#   Use the result to build the paths that go to impact_shared_apply_dir.
#   Example: real="$(impact_storage_real_root /mnt/disk_a/shared)"
impact_storage_real_root() {
    local -a roots=()
    local real
    impact_split_list "${IMPACT_CONF[SHARED_ROOTS]:-}" roots
    impact_in_list "$1" "${roots[@]}" || return 1
    real="$(realpath -e -- "$1" 2>/dev/null)" || return 1
    [[ -d "$real" ]] || return 1
    printf '%s\n' "$real"
}

# impact__root_holding PATH
#   Internal: prints the resolved storage root that PATH lies inside.
#   Result: failure when PATH is inside none of them.
impact__root_holding() {
    local root
    impact__real_roots
    for root in "${IMPACT__REAL_ROOTS[@]}"; do
        if impact_path_is_below "$1" "$root"; then
            printf '%s\n' "$root"
            return 0
        fi
    done
    return 1
}

# impact_storage_check_target PATH
#   The safety check for a folder that is to receive the shared rules. The
#   site settings must be loaded. PATH is accepted when, after resolving all
#   symbolic links, it
#     is an existing folder,
#     consists of letters, digits, ".", "_", "/" and "-" only,
#     lies inside one of the storage roots (SHARED_ROOTS), not the root itself,
#     is no top folder of a file system (mount point),
#     is no system folder and no home folder.
#   Result on success: IMPACT_STORAGE_PATH (the resolved folder) and
#   IMPACT_STORAGE_ROOT (the resolved storage root that holds it).
#   Result on failure: exit status 1 and the reason in IMPACT_STORAGE_ERROR.
#   Example: impact_storage_check_target /mnt/disk_a/shared/Example
impact_storage_check_target() {
    local path="$1" real root
    IMPACT_STORAGE_PATH=''
    IMPACT_STORAGE_ROOT=''
    IMPACT_STORAGE_ERROR=''
    if [[ "$path" != /* ]]; then
        IMPACT_STORAGE_ERROR="'$(impact_display "$path")' is no absolute path. Give the full path, starting with /."
        return 1
    fi
    if ! real="$(realpath -e -- "$path" 2>/dev/null)"; then
        IMPACT_STORAGE_ERROR="'$(impact_display "$path")' does not exist."
        return 1
    fi
    if [[ ! -d "$real" ]]; then
        IMPACT_STORAGE_ERROR="$real is no folder."
        return 1
    fi
    if ! impact_valid_abs_path "$real"; then
        IMPACT_STORAGE_ERROR="The path '$(impact_display "$real")' contains characters other than letters, digits and . _ / - . Run the command for the folder above it."
        return 1
    fi
    if impact_is_system_path "$real"; then
        IMPACT_STORAGE_ERROR="$real is a system folder. Shared rules are never applied there."
        return 1
    fi
    if impact_is_home_path "$real"; then
        IMPACT_STORAGE_ERROR="$real is a home folder or lies inside one. Shared rules are never applied there."
        return 1
    fi
    if ! root="$(impact__root_holding "$real")"; then
        # The storage root itself gets its own message: it is in the list,
        # and only the folders inside it are accepted.
        local listed roots_list=()
        impact_split_list "${IMPACT_CONF[SHARED_ROOTS]:-}" roots_list
        for listed in "${roots_list[@]}"; do
            if [[ "$(impact_storage_real_root "$listed" 2>/dev/null)" == "$real" ]]; then
                IMPACT_STORAGE_ERROR="$real is a storage root. Give the folder of one model inside it, for example $real/<storage name>."
                return 1
            fi
        done
        IMPACT_STORAGE_ERROR="$real lies inside none of the storage roots (${IMPACT_CONF[SHARED_ROOTS]:-none are set}). Give a folder inside one of them."
        return 1
    fi
    if impact_is_mount_point "$real"; then
        IMPACT_STORAGE_ERROR="$real is the top folder of a file system. Give a folder inside it."
        return 1
    fi
    IMPACT_STORAGE_PATH="$real"
    IMPACT_STORAGE_ROOT="$root"
    return 0
}

# =============================================================================
# The shared rules for one folder
# =============================================================================

# impact__acl_read PATH [EXTRA_GETFACL_OPTION...]
#   Internal: reads the ACL of PATH into IMPACT__ACL. The key is the entry
#   without its rights ("group:", "user:1001", "default:other:"), the value
#   is the rights ("rwx", "r-x").
impact__acl_read() {
    local path="$1" line
    shift
    IMPACT__ACL=()
    # getfacl options: -c no heading, -p keep the leading "/" of names,
    # -n numbers for accounts and groups, -E no "effective rights" remarks.
    while IFS= read -r line; do
        if [[ -z "$line" || "$line" == '#'* ]]; then
            continue
        fi
        # "${line%:*}" is the text before the last ":", "${line##*:}" the
        # text after it.
        IMPACT__ACL[${line%:*}]="${line##*:}"
    done < <(getfacl -c -p -n -E "$@" -- "$path" 2>/dev/null)
    ((${#IMPACT__ACL[@]} > 0))
}

# impact__shared_account_uid ACCOUNT STATE
#   Internal: checks the optional pair "ACCOUNT present|absent" of the shared
#   functions and prints the user number of ACCOUNT.
impact__shared_account_uid() {
    if [[ "$2" != 'present' && "$2" != 'absent' ]]; then
        impact_error "The state of the extra account must be 'present' or 'absent'."
        return 1
    fi
    impact_account_uid "$1" || {
        impact_error "The account '$(impact_display "$1")' does not exist."
        return 1
    }
}

# impact__shared_open_dir FOLDER
#   Internal: opens FOLDER and keeps the open handle in IMPACT__SHARED_FD.
#   All later steps go through the handle (the path /proc/self/fd/<number>),
#   so they act on exactly the folder that was checked here, even when
#   somebody replaces the path by a symbolic link in the meantime.
#   Refused: a path that is no real folder, a path that is not fully
#   resolved, and a folder outside the storage roots.
impact__shared_open_dir() {
    local folder="$1" real
    IMPACT__SHARED_FD=''
    IMPACT_STORAGE_ERROR=''
    if [[ -L "$folder" || ! -d "$folder" ]]; then
        IMPACT_STORAGE_ERROR="$(impact_display "$folder") is no real folder."
        return 1
    fi
    # "exec {NAME}<path" opens the path for reading and stores the number of
    # the new handle in the variable NAME. The braces with "2>/dev/null" hide
    # the error text of a failed open without touching the script's own
    # error channel.
    # The path ends in "/.": the system resolves that only when the entry is
    # a folder. Should the folder be swapped for a link to a device after the
    # test above, the open fails and the device is never opened (opening
    # some devices has effects of its own).
    if ! { exec {IMPACT__SHARED_FD}<"$folder/."; } 2>/dev/null; then
        IMPACT__SHARED_FD=''
        IMPACT_STORAGE_ERROR="$(impact_display "$folder") cannot be opened."
        return 1
    fi
    # The link /proc/self/fd/<number> names the real place of the opened
    # folder. It must be the path that was asked for.
    real="$(readlink -- "/proc/self/fd/$IMPACT__SHARED_FD" 2>/dev/null)" || real=''
    if [[ "$real" != "$folder" || ! -d "/proc/self/fd/$IMPACT__SHARED_FD" ]]; then
        impact__shared_close
        IMPACT_STORAGE_ERROR="$(impact_display "$folder") is not a fully resolved path of a folder (a symbolic link is on the way, or the folder changed while the command ran)."
        return 1
    fi
    if ! impact__root_holding "$real" >/dev/null; then
        impact__shared_close
        IMPACT_STORAGE_ERROR="$(impact_display "$folder") lies inside none of the storage roots."
        return 1
    fi
    return 0
}

# impact__shared_close
#   Internal: closes the handle opened by impact__shared_open_dir.
impact__shared_close() {
    if [[ -n "$IMPACT__SHARED_FD" ]]; then
        # "exec {NAME}<&-" closes the handle whose number is in NAME.
        exec {IMPACT__SHARED_FD}<&-
        IMPACT__SHARED_FD=''
    fi
}

# impact__shared_dir_deviations HANDLE_PATH GROUP_NUMBER [USER_NUMBER STATE]
#   Internal: compares one folder with the shared rules and prints one word
#   per deviation: group, setgid, access, default, user. Prints nothing when
#   the folder follows the rules.
impact__shared_dir_deviations() {
    local path="$1" gid="$2" uid="${3:-}" state="${4:-}"
    local facts mode
    # stat -L follows the /proc link to the folder itself. %g is the group
    # number, %a the mode as an octal number.
    facts="$(stat -L -c '%g %a' -- "$path" 2>/dev/null)" || {
        printf 'unreadable\n'
        return 0
    }
    mode="${facts##* }"
    if [[ "${facts%% *}" != "$gid" ]]; then
        printf 'group\n'
    fi
    # 8#2000 is the setgid bit of the mode.
    if (((8#$mode & 8#2000) == 0)); then
        printf 'setgid\n'
    fi
    if ! impact__acl_read "$path"; then
        printf 'unreadable\n'
        return 0
    fi
    # "${VAR-rwx}" (without ":") is the value of VAR, or "rwx" when the entry
    # does not exist: a missing mask limits nothing.
    if [[ "${IMPACT__ACL[group:]-}" != 'rwx' || "${IMPACT__ACL[mask:]-rwx}" != 'rwx' ]]; then
        printf 'access\n'
    fi
    if [[ "${IMPACT__ACL[default:user:]-}" != 'rwx' || "${IMPACT__ACL[default:group:]-}" != 'rwx' ||
        "${IMPACT__ACL[default:mask:]-rwx}" != 'rwx' ||
        "${IMPACT__ACL[default:other:]-}" != "${IMPACT__ACL[other:]-}" ]]; then
        printf 'default\n'
    fi
    if [[ "$state" == 'present' ]]; then
        if [[ "${IMPACT__ACL[user:$uid]-}" != 'rwx' || "${IMPACT__ACL[default:user:$uid]-}" != 'rwx' ]]; then
            printf 'user\n'
        fi
    elif [[ "$state" == 'absent' ]]; then
        if [[ -v IMPACT__ACL[user:$uid] || -v IMPACT__ACL[default:user:$uid] ]]; then
            printf 'user\n'
        fi
    fi
}

# impact_shared_dir_is_ok FOLDER GROUP [ACCOUNT STATE]
#   Read-only. Result: success when FOLDER itself follows the shared rules
#   for GROUP (see the top of this file). Failure when it deviates or cannot
#   be examined (then IMPACT_STORAGE_ERROR holds the reason).
#   Optional: ACCOUNT with STATE "present" also requires an access entry
#   (read, write, enter) for that account on the folder and in its default
#   ACL; "absent" requires that no such entry exists. This serves the
#   transition period, in which the old shared account keeps access.
#   FOLDER must be a fully resolved path inside a storage root.
#   Example: impact_shared_dir_is_ok /mnt/disk_a/shared/Example/outputs impact
impact_shared_dir_is_ok() {
    local folder="$1" group="$2" account="${3:-}" state="${4:-}"
    local gid uid='' deviations
    gid="$(impact_group_gid "$group")" || {
        IMPACT_STORAGE_ERROR="The group '$(impact_display "$group")' does not exist."
        return 1
    }
    if [[ -n "$account" ]]; then
        uid="$(impact__shared_account_uid "$account" "$state")" || return 1
    fi
    impact__shared_open_dir "$folder" || return 1
    deviations="$(impact__shared_dir_deviations "/proc/self/fd/$IMPACT__SHARED_FD" "$gid" "$uid" "$state")"
    impact__shared_close
    [[ -z "$deviations" ]]
}

# impact_shared_apply_dir FOLDER GROUP [ACCOUNT STATE]
#   Applies the shared rules to FOLDER itself. The content of the folder is
#   never touched: no walk through subfolders. Only the parts that deviate
#   are changed, so a second call changes nothing.
#   Parameters as for impact_shared_dir_is_ok. With ACCOUNT and "present" the
#   access entry for that account is added; with "absent" it is removed.
#   Result: success, and IMPACT_SHARED_CHANGED is 1 when something was
#   changed, 0 when the folder already followed the rules. Failure with an
#   error line when the folder is refused or a step fails.
#   Needs root rights.
#   Example: impact_do "Apply the shared rules to $folder" impact_shared_apply_dir "$folder" impact
impact_shared_apply_dir() {
    local folder="$1" group="$2" account="${3:-}" state="${4:-}"
    local gid uid='' deviations handle other entries status=0
    IMPACT_SHARED_CHANGED=0
    gid="$(impact_group_gid "$group")" || {
        impact_error "The group '$(impact_display "$group")' does not exist."
        return 1
    }
    if [[ -n "$account" ]]; then
        uid="$(impact__shared_account_uid "$account" "$state")" || return 1
    fi
    if ! impact__shared_open_dir "$folder"; then
        impact_error "$IMPACT_STORAGE_ERROR"
        return 1
    fi
    handle="/proc/self/fd/$IMPACT__SHARED_FD"
    deviations="$(impact__shared_dir_deviations "$handle" "$gid" "$uid" "$state")"
    if [[ -z "$deviations" ]]; then
        impact__shared_close
        return 0
    fi
    if [[ "$deviations" == *unreadable* ]]; then
        impact__shared_close
        impact_error "The rights of $folder cannot be read."
        return 1
    fi
    # The rights of "all others" stay as they are. New entries get the same
    # rights for others as the folder has.
    impact__acl_read "$handle" || status=1
    other="${IMPACT__ACL[other:]-}"
    if ((status == 0)) && ! [[ "$other" =~ ^[r-][w-][x-]$ ]]; then
        status=1
    fi

    # Each step runs only when all steps before it worked.
    if ((status == 0)) && [[ "$deviations" == *group* ]]; then
        chgrp -- "$gid" "$handle" || status=1
    fi
    if ((status == 0)) && [[ "$deviations" == *access* || "$deviations" == *user* ]]; then
        entries='g::rwx'
        if [[ "$state" == 'present' ]]; then
            entries+=",u:$uid:rwx"
        fi
        # setfacl -m changes the named entries and keeps all others. It also
        # recomputes the "mask", the upper limit for group and named entries.
        setfacl -m "$entries" -- "$handle" || status=1
        if ((status == 0)) && [[ "$state" == 'absent' ]]; then
            # -x removes one entry.
            setfacl -x "u:$uid" -- "$handle" || status=1
        fi
    fi
    if ((status == 0)) && [[ "$deviations" == *default* || "$deviations" == *user* ]]; then
        entries="u::rwx,g::rwx,o::$other"
        if [[ "$state" == 'present' ]]; then
            entries+=",u:$uid:rwx"
        fi
        # -d works on the default ACL, the template for new entries.
        setfacl -d -m "$entries" -- "$handle" || status=1
        if ((status == 0)) && [[ "$state" == 'absent' ]]; then
            setfacl -d -x "u:$uid" -- "$handle" || status=1
        fi
    fi
    if ((status == 0)) && [[ "$deviations" == *setgid* ]]; then
        chmod g+s -- "$handle" || status=1
    fi
    if ((status == 0)); then
        deviations="$(impact__shared_dir_deviations "$handle" "$gid" "$uid" "$state")"
        if [[ -n "$deviations" ]]; then
            status=1
        fi
    fi
    impact__shared_close
    if ((status != 0)); then
        impact_error "The shared rules could not be applied completely to $folder."
        return 1
    fi
    IMPACT_SHARED_CHANGED=1
    return 0
}

# =============================================================================
# The shared rules for files
# =============================================================================

# impact__shared_file_guard FILE
#   Internal: FILE must be a plain file (no symbolic link, no folder, no
#   device) at a clean absolute path inside a storage root.
impact__shared_file_guard() {
    [[ "$1" == /* && -f "$1" && ! -L "$1" ]] || return 1
    impact__root_holding "$1" >/dev/null
}

# impact_shared_file_is_ok FILE GROUP [ACCOUNT STATE]
#   Read-only. Result: success when the plain file FILE follows the shared
#   rules: group GROUP; the group may read and write; the group may execute
#   when the owner may. ACCOUNT and STATE as for impact_shared_dir_is_ok
#   (for a file, "present" means an entry with at least read and write).
#   Failure when the file deviates, is no plain file, or lies outside the
#   storage roots.
impact_shared_file_is_ok() {
    local file="$1" group="$2" account="${3:-}" state="${4:-}"
    local gid uid='' rights mask named
    gid="$(impact_group_gid "$group")" || return 1
    if [[ -n "$account" ]]; then
        uid="$(impact__shared_account_uid "$account" "$state")" || return 1
    fi
    impact__shared_file_guard "$file" || return 1
    # Without -L, stat looks at the entry itself and never follows a link.
    [[ "$(stat -c '%g' -- "$file" 2>/dev/null)" == "$gid" ]] || return 1
    # -R -P makes getfacl skip a symbolic link given as argument.
    impact__acl_read "$file" -R -P || return 1
    rights="${IMPACT__ACL[group:]-}"
    mask="${IMPACT__ACL[mask:]-rwx}"
    [[ "$rights" == rw? && "$mask" == rw? ]] || return 1
    if [[ "${IMPACT__ACL[user:]-}" == ??x ]]; then
        [[ "$rights" == ??x && "$mask" == ??x ]] || return 1
    fi
    if [[ "$state" == 'present' ]]; then
        named="${IMPACT__ACL[user:$uid]-}"
        [[ "$named" == rw? ]] || return 1
    elif [[ "$state" == 'absent' ]]; then
        [[ ! -v IMPACT__ACL[user:$uid] ]] || return 1
    fi
    return 0
}

# impact_shared_apply_files GROUP [ACCOUNT STATE] -- FILE...
#   Applies the shared rules to the given plain files, all in a few tool
#   calls (so a long list is fast). Entries that are no plain files inside a
#   storage root are refused before anything is changed. Symbolic links are
#   never followed: the tools used here change a link itself or skip it.
#   Result: success, and IMPACT_SHARED_CHANGED=1. Failure with an error line
#   when an entry is refused or a tool fails.
#   Needs root rights.
#   Example: impact_shared_apply_files impact -- "$folder/a.csv" "$folder/b.csv"
impact_shared_apply_files() {
    local group="$1" account='' state='' gid uid='' file entries
    shift
    IMPACT_SHARED_CHANGED=0
    if [[ "${1:-}" != '--' ]]; then
        account="${1:-}"
        state="${2:-}"
        shift 2 || return 1
    fi
    if [[ "${1:-}" != '--' ]]; then
        impact_error "impact_shared_apply_files: the mark -- before the file names is missing."
        return 1
    fi
    shift
    (($# > 0)) || return 0
    gid="$(impact_group_gid "$group")" || {
        impact_error "The group '$(impact_display "$group")' does not exist."
        return 1
    }
    if [[ -n "$account" ]]; then
        uid="$(impact__shared_account_uid "$account" "$state")" || return 1
    fi
    for file in "$@"; do
        if ! impact__shared_file_guard "$file"; then
            impact_error "$(impact_display "$file") is no plain file inside a storage root."
            return 1
        fi
    done
    # chgrp -h changes a symbolic link itself and never the file it points
    # to, should an entry be swapped for a link at the last moment.
    chgrp -h -- "$gid" "$@" || return 1
    # "X" means: execute right only where the file already is executable.
    entries='g::rwX'
    if [[ "$state" == 'present' ]]; then
        entries+=",u:$uid:rwX"
    fi
    # -R -P: setfacl skips symbolic links given as arguments. For a plain
    # file, -R has no further effect. The manual of acl 2.3.1 (Ubuntu 22.04)
    # says that -P acts only together with -R, so -R stays: without it, a
    # file swapped for a link at the last moment could be followed. The
    # opposite case, a file swapped for a real folder, makes setfacl give
    # that folder's content the group rules; it stays on the shared storage.
    setfacl -R -P -m "$entries" -- "$@" || return 1
    if [[ "$state" == 'absent' ]]; then
        setfacl -R -P -x "u:$uid" -- "$@" || return 1
    fi
    IMPACT_SHARED_CHANGED=1
    return 0
}

# impact_shared_apply_file FILE GROUP [ACCOUNT STATE]
#   Applies the shared rules to one plain file when it deviates.
#   Result: as impact_shared_apply_files; IMPACT_SHARED_CHANGED is 0 when the
#   file already followed the rules.
impact_shared_apply_file() {
    local file="$1" group="$2"
    shift 2
    IMPACT_SHARED_CHANGED=0
    if impact_shared_file_is_ok "$file" "$group" "$@"; then
        return 0
    fi
    impact_shared_apply_files "$group" "$@" -- "$file"
}
