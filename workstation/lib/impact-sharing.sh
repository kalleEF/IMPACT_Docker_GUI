#!/bin/bash
# =============================================================================
# impact-sharing.sh: shared code of impact-share-folder, impact-export-state
# and impact-clean-images
#
# Purpose
#   1. The walk of impact-share-folder: it goes once through a folder tree on
#      the shared storage, finds every folder and file that does not follow
#      the shared rules, saves the previous owner, group, mode and access
#      list (ACL) of each such entry, and only then changes it. The rules
#      themselves live in impact-storage.sh (impact_shared_apply_dir and
#      impact_shared_apply_files); this file decides WHICH entries need them.
#   2. Putting saved rights back from such a backup (--restore).
#   3. Small helpers for impact-export-state (content code of an archive)
#      and impact-clean-images (image names, the keep-or-remove decision).
#
# Words used in this file
#   ACL (access control list): extra access entries that Linux stores next
#     to the usual owner, group and mode of a file. "getfacl" shows them,
#     "setfacl" changes them.
#   default ACL: the ACL of a folder that every new entry in it inherits.
#   mask: the upper limit of the rights of the owning group and of all named
#     entries of an ACL.
#   setgid on a folder: new entries in it get the folder's group.
#   hard link: a second name of the same file; changing the rights under one
#     name changes them under every name.
#   inode: the number under which the file system keeps one file or folder.
#
# Who runs it
#   Nobody directly. The three commands load it after impact-common.sh.
#
# Usage (inside a command, after loading impact-common.sh and the settings)
#   impact_sharing_check_target "$path" || impact_die_usage "$IMPACT_STORAGE_ERROR"
#   IMPACT_SHARING_TARGET="$IMPACT_STORAGE_PATH" ...; impact_sharing_walk
#
# What it changes on the system
#   Loading changes nothing. impact_sharing_walk with IMPACT_SHARING_APPLY=1
#   writes a backup folder below /opt/impact/admin/acl-backups and changes
#   group, mode and ACL of the entries that deviate from the shared rules.
#   impact_sharing_restore with IMPACT_SHARING_APPLY=1 puts saved rights
#   back. Everything else only reads.
#
# How to undo
#   A change made by the walk: impact-share-folder --restore <backup folder>.
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
# Constructs beyond these are explained where they are first used.
# -----------------------------------------------------------------------------

# shellcheck disable=SC2034
# Reason for SC2034 (variable appears unused): the commands read the result
# variables set here; shellcheck checks one file at a time.

# "declare -gA" creates an associative array (entries found by a name) that
# is global even when this file is loaded inside a function.

# -----------------------------------------------------------------------------
# Settings of the walk
# -----------------------------------------------------------------------------
# Entries per group ("batch") for getfacl, the backup and the changes. A
# group of 500 keeps every tool call well below the system's limit for the
# length of a command line, and an interruption loses at most one group of
# work (the group is repeated by the next run).
IMPACT_SHARING_BATCH_SIZE=500
# The same limit in bytes of path names per group.
IMPACT_SHARING_BATCH_BYTES=262144
# Free space that the backup folder needs before a run starts, in KiB (1 GiB).
IMPACT_SHARING_MIN_FREE_KIB=1048576
# How often a long walk prints a progress line, in seconds.
IMPACT_SHARING_PROGRESS_SECONDS=60
# How many problem entries are named in the output (all are in the backup
# folder's problems.txt).
IMPACT_SHARING_SHOW_MAX=20

# -----------------------------------------------------------------------------
# Input of the walk and of the restore (set by impact-share-folder)
# -----------------------------------------------------------------------------
IMPACT_SHARING_TARGET=''     # the folder to walk, fully resolved
IMPACT_SHARING_ROOT=''       # the storage root that holds it, resolved
IMPACT_SHARING_GROUP=''      # name of the shared group
IMPACT_SHARING_GID=''        # its number
IMPACT_SHARING_ACCOUNT=''    # transition account, or empty
IMPACT_SHARING_UID=''        # its user number, or empty
IMPACT_SHARING_STATE=''      # "present", "absent" or empty
IMPACT_SHARING_QUICK=0       # 1 = --repair: files only after the quick test
IMPACT_SHARING_APPLY=0       # 1 = change; 0 = only count (dry run)
IMPACT_SHARING_MODE_WORD='full'   # "full" or "repair", for run.info

# -----------------------------------------------------------------------------
# Results
# -----------------------------------------------------------------------------
IMPACT_SHARING_TEXT=''       # result of impact_sharing_unescape
IMPACT_SHARING_BACKUP=''     # the backup folder of this run, once created
IMPACT_SHARING_RUNNING=0     # 1 while a changing walk or restore runs
declare -gA IMPACT_SHARING_COUNT=()     # counters, see impact__sharing_reset
declare -gA IMPACT_SHARING_DIR_WHY=()   # folders that deviate, per reason
declare -gA IMPACT_SHARING_FILE_WHY=()  # files that deviate, per reason
IMPACT_SHARING_PROBLEMS=()   # "path: reason" of entries that failed
IMPACT_SHARING_HARDLINKS=()  # files left alone because of outside names

# Internal state of one walk.
IMPACT__SHARING_PATHS=()     # the current group: paths
IMPACT__SHARING_KINDS=()     #                    d or f
IMPACT__SHARING_IDS=()       #                    device:inode
IMPACT__SHARING_BYTES=0      # sum of the path lengths of the group
IMPACT__SHARING_PART=0       # number of the last backup part
IMPACT__SHARING_TMP=''       # private temporary folder of the walk
IMPACT__SHARING_STARTED=''   # start time of the run (UTC)
declare -gA IMPACT__SHARING_LINK_SEEN=()   # hard links: names seen per inode
declare -gA IMPACT__SHARING_LINK_TOTAL=()  # hard links: names in total
declare -gA IMPACT__SHARING_LINK_PATH=()   # hard links: one path per inode

# =============================================================================
# Pure helpers (no access to the system; the unit tests call them directly)
# =============================================================================

# impact_sharing_unescape TEXT
#   Turns a path as getfacl or /proc/self/mountinfo print it back into the
#   real name: "\\" stands for one backslash and "\NNN" (three octal digits)
#   for one character, for example "\012" for a line break.
#   Result: the name in IMPACT_SHARING_TEXT (a variable, because "$( ... )"
#   would remove a line break at the end of a name).
#   Example: impact_sharing_unescape 'a\040b'   gives "a b"
impact_sharing_unescape() {
    local rest="$1" out='' char
    # The fast way for the common case: no backslash at all.
    if [[ "$rest" != *\\* ]]; then
        IMPACT_SHARING_TEXT="$rest"
        return 0
    fi
    # The pattern: any text without a backslash (group 1), a backslash, then
    # either a second backslash or three octal digits (group 2), then the
    # rest (group 3). Inside [ ] a backslash stands for itself.
    local pattern='^([^\]*)\\(\\|[0-7][0-7][0-7])(.*)$'
    while [[ "$rest" =~ $pattern ]]; do
        out+="${BASH_REMATCH[1]}"
        if [[ "${BASH_REMATCH[2]}" == "\\" ]]; then
            out+="\\"
        else
            # printf turns "\NNN" in its format text into that character;
            # "-v char" stores the result in the variable char.
            # shellcheck disable=SC2059
            # Reason for SC2059 (variable in the format): the format is
            # exactly the escape sequence to translate, three octal digits.
            printf -v char "\\${BASH_REMATCH[2]}"
            out+="$char"
        fi
        rest="${BASH_REMATCH[3]}"
    done
    IMPACT_SHARING_TEXT="$out$rest"
}

# impact_sharing_glob_quote TEXT
#   Prints TEXT with a backslash before each character that has a special
#   meaning in a pattern of "find -path" (\ * ? [), so the pattern matches
#   exactly this one path.
impact_sharing_glob_quote() {
    local text="$1" out='' char index
    for ((index = 0; index < ${#text}; index++)); do
        char="${text:index:1}"
        case "$char" in
            "\\" | '*' | '?' | '[') out+="\\$char" ;;
            *) out+="$char" ;;
        esac
    done
    printf '%s' "$out"
}

# impact_sharing_backup_name TARGET TIME
#   Prints the name of the backup folder for a run on TARGET that started at
#   TIME (form 20261124T201500Z): the time, "_", and the path with every "/"
#   turned into "_", cut to 200 characters.
#   Example: impact_sharing_backup_name /mnt/disk_a/shared/Example 20261124T201500Z
#            prints 20261124T201500Z_mnt_disk_a_shared_Example
impact_sharing_backup_name() {
    local target="${1//\//_}"
    printf '%s_%s' "$2" "${target:1:200}"
}

# impact_sharing_valid_backup_name NAME
#   Result: success when NAME has the form of a backup folder name.
impact_sharing_valid_backup_name() {
    [[ "$1" =~ ^[0-9]{8}T[0-9]{6}Z_[A-Za-z0-9._-]{1,210}$ ]]
}

# impact_sharing_flags_chmod FLAGS
#   Turns the "flags" of getfacl (three characters for setuid, setgid and
#   sticky, for example "-s-") into a chmod instruction that sets exactly
#   these three bits and leaves read, write and execute alone.
#   Example: impact_sharing_flags_chmod -s-   prints u-s,g+s,-t
impact_sharing_flags_chmod() {
    local flags="${1:----}" spec
    [[ "${flags:0:1}" == 's' ]] && spec='u+s' || spec='u-s'
    [[ "${flags:1:1}" == 's' ]] && spec+=',g+s' || spec+=',g-s'
    [[ "${flags:2:1}" == 't' ]] && spec+=',+t' || spec+=',-t'
    printf '%s' "$spec"
}

# impact_sharing_number TEXT
#   Prints a whole number with a comma every three digits, for reading:
#   1234567 becomes 1,234,567.
impact_sharing_number() {
    local text="$1" out=''
    while ((${#text} > 3)); do
        # "${text: -3}" is the last three characters (the space before the
        # minus sign is needed).
        out=",${text: -3}$out"
        text="${text:0:${#text}-3}"
    done
    printf '%s%s' "$text" "$out"
}

# impact_sharing_count NUMBER ONE MANY
#   Prints the number (with commas) and the right form of the word:
#   "1 file", "2 files", "1,000 files".
#   Example: impact_sharing_count "$n" folder folders
impact_sharing_count() {
    if [[ "$1" == '1' ]]; then
        printf '1 %s' "$2"
    else
        printf '%s %s' "$(impact_sharing_number "$1")" "$3"
    fi
}

# impact_sharing_bytes NUMBER
#   Prints a size in bytes in a readable unit (B, KiB, MiB, GiB, TiB), with
#   one decimal.
impact_sharing_bytes() {
    local value="$1" unit=0 tenths
    local -a units=(B KiB MiB GiB TiB PiB)
    tenths=$((value * 10))
    while ((tenths >= 10240 && unit < 5)); do
        tenths=$((tenths / 1024))
        unit=$((unit + 1))
    done
    if ((unit == 0)); then
        printf '%s B' "$value"
    else
        printf '%s.%s %s' "$((tenths / 10))" "$((tenths % 10))" "${units[unit]}"
    fi
}

# impact__sharing_classify_program
#   Internal: prints the awk program that compares entries with the shared
#   rules. awk is a small language for reading text line by line; the
#   program below reads the output of "getfacl -P -p -n -E" for a group of
#   entries and a second file ("info") with one line "<d|f> <device>
#   <inode>" per entry in the same order.
#   For each entry it prints "<number> <reasons>", where <number> counts the
#   entries from 0 and <reasons> is "-" for an entry that follows the rules,
#   or a list of words joined by ",":
#     group    the group is not the shared group
#     setgid   (folder) setgid is missing
#     access   the owning group may not read and write (folders: and
#              enter), or the mask limits it; for a file that its owner may
#              execute: the group may not execute
#     default  (folder) the default ACL does not give owner and group read,
#              write and enter, limits them by a mask, or gives all others
#              other rights than the folder itself
#     user     the entry of the transition account is missing or wrong
#              ("present"), or exists ("absent")
#   The last line is "COUNT <number of entries>". With bk set, the complete
#   getfacl record of every deviating entry is added to the file bk, with
#   two extra lines "# impact-type:" and "# impact-inode:".
#   These rules are the same as in impact__shared_dir_deviations and
#   impact_shared_file_is_ok of impact-storage.sh; a test compares both.
impact__sharing_classify_program() {
    cat <<'AWK_PROGRAM'
function get(key) { return (key in acl) ? acl[key] : "" }
function add(list, word) { return (list == "") ? word : list "," word }
function finish(    line, parts, kind, words, g, m, i) {
    if (open == 0) return
    open = 0
    if ((getline line < info) <= 0) { broken = 1; return }
    split(line, parts, " ")
    kind = parts[1]
    words = ""
    if (grp != gid) words = add(words, "group")
    if (kind == "d") {
        if (substr(flags, 2, 1) != "s") words = add(words, "setgid")
        if (get("group:") != "rwx" || (("mask:" in acl) && acl["mask:"] != "rwx")) words = add(words, "access")
        if (get("default:user:") != "rwx" || get("default:group:") != "rwx" ||
            (("default:mask:" in acl) && acl["default:mask:"] != "rwx") ||
            get("default:other:") != get("other:")) words = add(words, "default")
        if (state == "present" && (get("user:" uid) != "rwx" || get("default:user:" uid) != "rwx")) words = add(words, "user")
        if (state == "absent" && ((("user:" uid) in acl) || (("default:user:" uid) in acl))) words = add(words, "user")
    } else {
        g = get("group:")
        m = ("mask:" in acl) ? acl["mask:"] : "rwx"
        if (substr(g, 1, 2) != "rw" || substr(m, 1, 2) != "rw") words = add(words, "access")
        else if (substr(get("user:"), 3, 1) == "x" && (substr(g, 3, 1) != "x" || substr(m, 3, 1) != "x")) words = add(words, "access")
        if (state == "present" && substr(get("user:" uid), 1, 2) != "rw") words = add(words, "user")
        if (state == "absent" && (("user:" uid) in acl)) words = add(words, "user")
    }
    if (words == "") {
        words = "-"
    } else if (bk != "") {
        print lines[1] > bk
        print "# impact-type: " kind > bk
        print "# impact-inode: " parts[2] ":" parts[3] > bk
        for (i = 2; i <= n; i++) print lines[i] > bk
        print "" > bk
    }
    print count " " words
    count++
}
BEGIN { count = 0; open = 0; broken = 0 }
/^# file: / {
    finish()
    open = 1; n = 0; grp = ""; flags = "---"
    split("", acl)
    lines[++n] = $0
    next
}
open == 0 { next }
/^# group: / { grp = substr($0, 10); lines[++n] = $0; next }
/^# flags: / { flags = substr($0, 10); lines[++n] = $0; next }
/^#/ { lines[++n] = $0; next }
/^$/ { next }
{
    lines[++n] = $0
    line = $0
    sub(/[ \t]*#.*$/, "", line)
    if (match(line, /:[^:]*$/)) acl[substr(line, 1, RSTART - 1)] = substr(line, RSTART + 1)
}
END {
    finish()
    if (bk != "") close(bk)
    if (broken) print "BROKEN"
    print "COUNT " count
}
AWK_PROGRAM
}

# impact_sharing_classify INFO_FILE GID UID STATE BACKUP_FILE
#   Runs the program above: getfacl output on standard input, results on
#   standard output. UID and STATE may be empty (no transition account);
#   BACKUP_FILE may be empty (nothing is saved, for a dry run).
#   Example: getfacl -P -p -n -E -- "${paths[@]}" | impact_sharing_classify "$info" 1005 '' '' ''
impact_sharing_classify() {
    awk -v info="$1" -v gid="$2" -v uid="$3" -v state="$4" -v bk="$5" \
        "$(impact__sharing_classify_program)"
}

# impact__sharing_normalize_program
#   Internal: prints the awk program that turns getfacl records (from a
#   backup part or from getfacl itself) into one line per entry, fields
#   separated by a TAB:
#     number, type (d, f or "?"), device:inode (or "?"), owner, group,
#     flags, the ACL entries joined by ",", the path as getfacl wrote it
#     (a TAB in the name becomes \011, so the line stays readable)
impact__sharing_normalize_program() {
    cat <<'AWK_PROGRAM'
function finish() {
    if (open == 0) return
    open = 0
    print count "\t" kind "\t" ident "\t" owner "\t" grp "\t" flags "\t" entries "\t" path
    count++
}
BEGIN { count = 0; open = 0 }
/^# file: / {
    finish()
    open = 1; kind = "?"; ident = "?"; owner = ""; grp = ""; flags = "---"; entries = ""
    path = substr($0, 9)
    gsub(/\t/, "\\011", path)
    next
}
open == 0 { next }
/^# owner: / { owner = substr($0, 10); next }
/^# group: / { grp = substr($0, 10); next }
/^# flags: / { flags = substr($0, 10); next }
/^# impact-type: / { kind = substr($0, 16); next }
/^# impact-inode: / { ident = substr($0, 17); next }
/^#/ { next }
/^$/ { next }
{
    line = $0
    # Remarks after an entry (such as "#effective:r--") are no part of it.
    sub(/[ \t]*#.*$/, "", line)
    entries = (entries == "") ? line : entries "," line
}
END { finish() }
AWK_PROGRAM
}

# impact_sharing_normalize
#   Filter: getfacl records on standard input, one line per entry on
#   standard output (see above).
impact_sharing_normalize() {
    awk "$(impact__sharing_normalize_program)"
}

# =============================================================================
# The folder to work on
# =============================================================================

# impact_sharing_check_target PATH
#   The full safety check for impact-share-folder. It adds three checks to
#   impact_storage_check_target of impact-storage.sh (existing folder,
#   clean characters, inside a storage root and not the root itself, no top
#   folder of a file system, no system or home folder):
#     - a path that is written below a storage root must also lead to a
#       place below that root; a symbolic link (or "..") on the way that
#       leads out of it, also into another storage root, is refused;
#     - the folder lies on ext4, xfs or btrfs (file systems that keep
#       groups, modes and ACLs);
#     - the folder lies on the same file system as its storage root.
#   Result: success with IMPACT_STORAGE_PATH and IMPACT_STORAGE_ROOT (both
#   resolved), or failure with the reason in IMPACT_STORAGE_ERROR.
#   Example: impact_sharing_check_target /mnt/disk_a/shared/Example
impact_sharing_check_target() {
    local given="$1" real='' root resolved type
    local -a roots=()
    IMPACT_STORAGE_PATH=''
    IMPACT_STORAGE_ROOT=''
    IMPACT_STORAGE_ERROR=''
    impact_split_list "${IMPACT_CONF[SHARED_ROOTS]:-}" roots
    if [[ "$given" == /* ]] && real="$(realpath -e -- "$given" 2>/dev/null)"; then
        for root in "${roots[@]}"; do
            resolved="$(realpath -e -- "$root" 2>/dev/null)" || continue
            # "$root"/* is the text of the root, a slash, then anything.
            if [[ "$given" == "$root"/* || "$given" == "$resolved"/* ]] &&
                [[ "$real" != "$resolved" ]] && ! impact_path_is_below "$real" "$resolved"; then
                IMPACT_STORAGE_ERROR="'$(impact_display "$given")' is written below the storage root $root, and a symbolic link (or '..') on the way leads out of it, to $(impact_display "$real"). Give a folder that really lies inside the storage root."
                return 1
            fi
        done
    fi
    if [[ "${real:-}" == '/' ]]; then
        IMPACT_STORAGE_ERROR="'$(impact_display "$given")' is the top folder of the whole system (/). Give a folder inside a storage root."
        return 1
    fi
    impact_storage_check_target "$given" || return 1
    type="$(impact_fs_type "$IMPACT_STORAGE_PATH")"
    if ! impact_fs_type_supported "$type"; then
        IMPACT_STORAGE_ERROR="$IMPACT_STORAGE_PATH lies on a file system of type '${type:-unknown}'. The shared rules need ext4, xfs or btrfs."
        IMPACT_STORAGE_PATH=''
        return 1
    fi
    if [[ "$(stat -c '%d' -- "$IMPACT_STORAGE_PATH" 2>/dev/null)" != "$(stat -c '%d' -- "$IMPACT_STORAGE_ROOT" 2>/dev/null)" ]]; then
        IMPACT_STORAGE_ERROR="$IMPACT_STORAGE_PATH lies on another file system than its storage root $IMPACT_STORAGE_ROOT (another disk is mounted on the way). The command works on the file system of the storage root only."
        IMPACT_STORAGE_PATH=''
        return 1
    fi
    return 0
}

# impact_sharing_mounts_below PATH ARRAY_NAME
#   Fills the array ARRAY_NAME with every mount point that lies inside PATH
#   (other disks, and folders mounted a second time with "mount --bind").
#   The walk leaves them out together with everything below them.
#   Source: /proc/self/mountinfo, the system's list of mounted file
#   systems; its fifth field is the mount point.
impact_sharing_mounts_below() {
    local path="$1" line point
    # "local -n" gives this function a second name for the caller's array.
    local -n impact__mounts_target="$2"
    impact__mounts_target=()
    while IFS= read -r line; do
        # "read" splits the line at spaces; "_" takes fields that are not
        # needed. Spaces inside a mount point are written as \040.
        read -r _ _ _ _ point _ <<<"$line"
        impact_sharing_unescape "$point"
        point="$IMPACT_SHARING_TEXT"
        if [[ "$point" == "$path"/* ]] && ! impact_in_list "$point" "${impact__mounts_target[@]}"; then
            impact__mounts_target+=("$point")
        fi
    done </proc/self/mountinfo
}

# impact_sharing_blocking_parents PATH GID
#   Prints every folder above PATH (from / down to the folder that holds
#   PATH) that members of the shared group cannot enter: neither all others
#   nor (when it is the folder's group) the group may enter it. Members then
#   cannot reach PATH, whatever its own rights are.
impact_sharing_blocking_parents() {
    local path="$1" gid="$2" current='' part facts mode group
    local -a parts=()
    # Split the path at "/" into its parts.
    IFS='/' read -r -a parts <<<"${path#/}"
    unset 'parts[${#parts[@]}-1]'
    for part in '' "${parts[@]}"; do
        if [[ -n "$part" ]]; then
            current="$current/$part"
        fi
        facts="$(stat -c '%a %g' -- "${current:-/}" 2>/dev/null)" || continue
        mode="${facts%% *}"
        group="${facts##* }"
        # 8#1 is the "enter" right of all others, 8#10 that of the group.
        if (((8#$mode & 8#1) != 0)); then
            continue
        fi
        if [[ "$group" == "$gid" ]] && (((8#$mode & 8#10) != 0)); then
            continue
        fi
        printf '%s\n' "${current:-/}"
    done
}

# impact_sharing_blocking_parents_for PATH ACCOUNT
#   Prints every folder above PATH (from / down to the folder that holds
#   PATH) that ACCOUNT may not enter. The system itself answers the
#   question: "test -x" runs with the rights of the account, so access
#   lists count too. Needs root rights.
impact_sharing_blocking_parents_for() {
    local path="$1" account="$2" current='' part
    local -a parts=()
    IFS='/' read -r -a parts <<<"${path#/}"
    unset 'parts[${#parts[@]}-1]'
    for part in '' "${parts[@]}"; do
        if [[ -n "$part" ]]; then
            current="$current/$part"
        fi
        if ! impact_run_as "$account" test -x "${current:-/}"; then
            printf '%s\n' "${current:-/}"
        fi
    done
}

# impact_sharing_free_kib FOLDER
#   Prints the free space of the file system that holds FOLDER, in KiB.
impact_sharing_free_kib() {
    local line
    # df -P prints a fixed format; -k counts in KiB. The last line, fourth
    # field, is the free space.
    line="$(df -P -k -- "$(impact_nearest_existing "$1")" 2>/dev/null | tail -n 1)" || return 1
    read -r _ _ _ line _ <<<"$line"
    [[ "$line" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$line"
}

# =============================================================================
# The walk
# =============================================================================

# impact__sharing_reset
#   Internal: sets all counters of a run to zero.
impact__sharing_reset() {
    local key
    IMPACT_SHARING_COUNT=()
    for key in folders files links other other_fs mounts vanished changed_folders \
        changed_files deviating_folders deviating_files failed hardlinks_left examined; do
        IMPACT_SHARING_COUNT[$key]=0
    done
    IMPACT_SHARING_DIR_WHY=()
    IMPACT_SHARING_FILE_WHY=()
    IMPACT_SHARING_PROBLEMS=()
    IMPACT_SHARING_HARDLINKS=()
    IMPACT__SHARING_PATHS=()
    IMPACT__SHARING_KINDS=()
    IMPACT__SHARING_IDS=()
    IMPACT__SHARING_BYTES=0
    IMPACT__SHARING_PART=0
    IMPACT__SHARING_LINK_SEEN=()
    IMPACT__SHARING_LINK_TOTAL=()
    IMPACT__SHARING_LINK_PATH=()
}

# impact__sharing_problem PATH REASON
#   Internal: notes an entry that could not be handled.
impact__sharing_problem() {
    IMPACT_SHARING_COUNT[failed]=$((IMPACT_SHARING_COUNT[failed] + 1))
    IMPACT_SHARING_PROBLEMS+=("$(impact_display "$1"): $2")
}

# impact__sharing_run_info STATE
#   Internal: writes the file run.info of the backup folder: what this run
#   did, as KEY=value lines (read later by --restore, never executed).
impact__sharing_run_info() {
    local state="$1" file="$IMPACT_SHARING_BACKUP/run.info"
    {
        printf '# Backup of impact-share-folder. Restore with:\n'
        printf '#   sudo impact-share-folder --restore %s\n' "$IMPACT_SHARING_BACKUP"
        printf 'BACKUP_FORMAT=1\n'
        printf 'KIND=share-folder\n'
        printf 'TARGET=%s\n' "$IMPACT_SHARING_TARGET"
        printf 'STORAGE_ROOT=%s\n' "$IMPACT_SHARING_ROOT"
        printf 'GROUP=%s\n' "$IMPACT_SHARING_GROUP"
        printf 'GROUP_NUMBER=%s\n' "$IMPACT_SHARING_GID"
        printf 'TRANSITION_ACCOUNT=%s\n' "$IMPACT_SHARING_ACCOUNT"
        printf 'TRANSITION_STATE=%s\n' "$IMPACT_SHARING_STATE"
        printf 'MODE=%s\n' "$IMPACT_SHARING_MODE_WORD"
        printf 'STARTED=%s\n' "$IMPACT__SHARING_STARTED"
        printf 'STATE=%s\n' "$state"
        printf 'UPDATED=%s\n' "$(impact_now_utc)"
        printf 'PARTS=%s\n' "$IMPACT__SHARING_PART"
        printf 'FOLDERS_CHANGED=%s\n' "${IMPACT_SHARING_COUNT[changed_folders]:-0}"
        printf 'FILES_CHANGED=%s\n' "${IMPACT_SHARING_COUNT[changed_files]:-0}"
        printf 'COMMANDS_VERSION=%s\n' "$(impact_own_version)"
    } | impact_write_file_atomic "$file" 600 root root
}

# impact__sharing_open_backup
#   Internal: creates the backup folder of this run (once), mode 700, and
#   writes run.info with STATE=running.
impact__sharing_open_backup() {
    local name base suffix=1
    if [[ -n "$IMPACT_SHARING_BACKUP" ]]; then
        return 0
    fi
    if [[ -L "$IMPACT_ACL_BACKUP_DIR" ]]; then
        impact_error "$IMPACT_ACL_BACKUP_DIR is a symbolic link; a real folder is expected."
        return 1
    fi
    if [[ ! -d "$IMPACT_ACL_BACKUP_DIR" ]]; then
        impact_make_dir "$IMPACT_ACL_BACKUP_DIR" 700 root root || return 1
    fi
    base="$IMPACT_ACL_BACKUP_DIR/$(impact_sharing_backup_name "$IMPACT_SHARING_TARGET" "$(date -u '+%Y%m%dT%H%M%SZ')")"
    name="$base"
    # mkdir without -p fails when the folder exists, so a second run in the
    # same second gets its own folder ("-2", "-3", ...).
    while ! mkdir -m 700 -- "$name" 2>/dev/null; do
        suffix=$((suffix + 1))
        if ((suffix > 50)); then
            impact_error "No backup folder could be created below $IMPACT_ACL_BACKUP_DIR."
            return 1
        fi
        name="$base-$suffix"
    done
    IMPACT_SHARING_BACKUP="$name"
    impact__sharing_run_info running || return 1
    impact_info "Backup folder for the previous rights: $IMPACT_SHARING_BACKUP"
}

# impact__sharing_save_part PLAIN_FILE
#   Internal: stores the getfacl records of one group (PLAIN_FILE) as the
#   next part of the backup: compressed with gzip, written to disk ("sync"),
#   and only then given its final name. A part with its final name is
#   therefore always complete.
impact__sharing_save_part() {
    local plain="$1" part temporary
    impact__sharing_open_backup || return 1
    IMPACT__SHARING_PART=$((IMPACT__SHARING_PART + 1))
    # printf '%06d' writes the number with six digits: 000001.
    printf -v part '%s/part-%06d.facl.gz' "$IMPACT_SHARING_BACKUP" "$IMPACT__SHARING_PART"
    temporary="$part.tmp"
    IMPACT_TMP_ITEMS+=("$temporary")
    if ! gzip -c -- "$plain" >"$temporary"; then
        impact_error "The backup part $part could not be written."
        return 1
    fi
    chmod 600 -- "$temporary" || return 1
    sync -- "$temporary" || return 1
    mv -f -T -- "$temporary" "$part" || return 1
    sync -- "$IMPACT_SHARING_BACKUP" 2>/dev/null || true
}

# impact__sharing_read_results RESULT_FILE EXPECTED
#   Internal: checks the output of impact_sharing_classify for a group of
#   EXPECTED entries and fills IMPACT__SHARING_WHY (reasons per entry).
#   Result: failure when the output does not cover exactly EXPECTED entries
#   (for example because an entry disappeared and getfacl skipped it).
impact__sharing_read_results() {
    local file="$1" expected="$2" number words count=-1
    IMPACT__SHARING_WHY=()
    while read -r number words; do
        if [[ "$number" == 'BROKEN' ]]; then
            return 1
        fi
        if [[ "$number" == 'COUNT' ]]; then
            count="$words"
            continue
        fi
        IMPACT__SHARING_WHY+=("$words")
    done <"$file"
    [[ "$count" == "$expected" && "${#IMPACT__SHARING_WHY[@]}" == "$expected" ]]
}

# impact__sharing_examine PATHS_ARRAY KINDS_ARRAY IDS_ARRAY BACKUP_FILE
#   Internal: reads the ACLs of a group of entries and compares them with
#   the rules. Fills IMPACT__SHARING_WHY. With BACKUP_FILE, the records of
#   deviating entries are written there.
#   Result: failure when getfacl or the comparison did not cover every entry.
impact__sharing_examine() {
    local -n impact__ex_paths="$1" impact__ex_kinds="$2" impact__ex_ids="$3"
    local backup="$4" index status=0
    local info="$IMPACT__SHARING_TMP/info" result="$IMPACT__SHARING_TMP/result"
    # "${!array[@]}" lists the numbers (indexes) of the entries. The
    # redirection after "done" writes the output of the whole loop at once.
    for index in "${!impact__ex_paths[@]}"; do
        printf '%s %s\n' "${impact__ex_kinds[index]}" "${impact__ex_ids[index]//:/ }"
    done >"$info"
    if [[ -n "$backup" ]]; then
        : >"$backup"
    fi
    # getfacl options: -P never follow a symbolic link, -p keep the leading
    # "/", -n numbers for accounts and groups, -E no "#effective" remarks. "PIPESTATUS" holds the exit
    # codes of all commands of the last chain joined with "|".
    getfacl -P -p -n -E -- "${impact__ex_paths[@]}" 2>"$IMPACT__SHARING_TMP/getfacl.err" |
        impact_sharing_classify "$info" "$IMPACT_SHARING_GID" "$IMPACT_SHARING_UID" \
            "$IMPACT_SHARING_STATE" "$backup" >"$result" || status=1
    if [[ "${PIPESTATUS[0]}" != '0' ]]; then
        status=1
    fi
    impact__sharing_read_results "$result" "${#impact__ex_paths[@]}" || status=1
    return "$status"
}

# impact__sharing_note_reasons KIND WORDS
#   Internal: counts a deviating entry per reason.
impact__sharing_note_reasons() {
    local kind="$1" word
    local -a words=()
    IFS=',' read -r -a words <<<"$2"
    for word in "${words[@]}"; do
        if [[ "$kind" == 'd' ]]; then
            IMPACT_SHARING_DIR_WHY[$word]=$((${IMPACT_SHARING_DIR_WHY[$word]:-0} + 1))
        else
            IMPACT_SHARING_FILE_WHY[$word]=$((${IMPACT_SHARING_FILE_WHY[$word]:-0} + 1))
        fi
    done
}

# A note on error output: the library functions called below are never
# given "2>/dev/null". A redirection on a function call stays active while
# the function runs, and when the command is stopped at that moment (Ctrl+C,
# "systemctl stop"), its own stop message and summary would vanish with it.

# impact__sharing_apply_files FILE...
#   Internal: applies the shared rules to plain files with the one
#   implementation of impact-storage.sh. When the group call fails (for
#   example because one file disappeared, which makes the library refuse
#   the whole group before it changes anything), each file is tried alone.
#   Result: IMPACT__SHARING_DONE holds the number of files that were changed.
impact__sharing_apply_files() {
    local file
    local -a extra=()
    IMPACT__SHARING_DONE=0
    if [[ -n "$IMPACT_SHARING_ACCOUNT" ]]; then
        extra=("$IMPACT_SHARING_ACCOUNT" "$IMPACT_SHARING_STATE")
    fi
    if impact_shared_apply_files "$IMPACT_SHARING_GROUP" "${extra[@]}" -- "$@"; then
        IMPACT__SHARING_DONE=$#
        return 0
    fi
    for file in "$@"; do
        if impact_shared_apply_files "$IMPACT_SHARING_GROUP" "${extra[@]}" -- "$file"; then
            IMPACT__SHARING_DONE=$((IMPACT__SHARING_DONE + 1))
        elif [[ ! -e "$file" && ! -L "$file" ]]; then
            IMPACT_SHARING_COUNT[vanished]=$((IMPACT_SHARING_COUNT[vanished] + 1))
        else
            impact__sharing_problem "$file" "the shared rules could not be applied"
        fi
    done
}

# impact__sharing_flush
#   Internal: handles the current group of entries: examine them, and in a
#   real run save the records of the deviating ones, then change them, then
#   check the changed files again.
#   Result: 0 done (problems with single entries are counted); 2 the backup
#   could not be written (the walk must stop: nothing of this group was
#   changed).
impact__sharing_flush() {
    local count="${#IMPACT__SHARING_PATHS[@]}" index words backup=''
    local -a dirs=() files=() file_kinds=() file_ids=() paths=() kinds=() ids=()
    ((count > 0)) || return 0
    # Copy the group and empty it, so a failure below cannot repeat it.
    paths=("${IMPACT__SHARING_PATHS[@]}")
    kinds=("${IMPACT__SHARING_KINDS[@]}")
    ids=("${IMPACT__SHARING_IDS[@]}")
    IMPACT__SHARING_PATHS=()
    IMPACT__SHARING_KINDS=()
    IMPACT__SHARING_IDS=()
    IMPACT__SHARING_BYTES=0
    if ((IMPACT_SHARING_APPLY == 1)); then
        backup="$IMPACT__SHARING_TMP/part"
    fi
    if ! impact__sharing_examine paths kinds ids "$backup"; then
        # Something in the group changed while the walk ran. Examine each
        # entry alone; one that is gone is counted as such.
        if ((count == 1)); then
            if [[ ! -e "${paths[0]}" || -L "${paths[0]}" ]]; then
                IMPACT_SHARING_COUNT[vanished]=$((IMPACT_SHARING_COUNT[vanished] + 1))
            else
                impact__sharing_problem "${paths[0]}" "its access list could not be read"
            fi
            return 0
        fi
        for index in "${!paths[@]}"; do
            IMPACT__SHARING_PATHS=("${paths[index]}")
            IMPACT__SHARING_KINDS=("${kinds[index]}")
            IMPACT__SHARING_IDS=("${ids[index]}")
            impact__sharing_flush || return 2
        done
        return 0
    fi
    for index in "${!paths[@]}"; do
        words="${IMPACT__SHARING_WHY[index]}"
        [[ "$words" != '-' ]] || continue
        impact__sharing_note_reasons "${kinds[index]}" "$words"
        if [[ "${kinds[index]}" == 'd' ]]; then
            IMPACT_SHARING_COUNT[deviating_folders]=$((IMPACT_SHARING_COUNT[deviating_folders] + 1))
            dirs+=("${paths[index]}")
        else
            IMPACT_SHARING_COUNT[deviating_files]=$((IMPACT_SHARING_COUNT[deviating_files] + 1))
            files+=("${paths[index]}")
            file_kinds+=(f)
            file_ids+=("${ids[index]}")
        fi
    done
    if ((IMPACT_SHARING_APPLY == 0 || ${#dirs[@]} + ${#files[@]} == 0)); then
        return 0
    fi

    # The previous rights of every entry that is about to change are saved
    # first. Without a complete backup nothing is changed.
    if ! impact__sharing_save_part "$backup"; then
        return 2
    fi

    # Folders: one at a time, through the library (it works through an open
    # handle and checks the result itself).
    local -a extra=()
    if [[ -n "$IMPACT_SHARING_ACCOUNT" ]]; then
        extra=("$IMPACT_SHARING_ACCOUNT" "$IMPACT_SHARING_STATE")
    fi
    for index in "${!dirs[@]}"; do
        if impact_shared_apply_dir "${dirs[index]}" "$IMPACT_SHARING_GROUP" "${extra[@]}"; then
            IMPACT_SHARING_COUNT[changed_folders]=$((IMPACT_SHARING_COUNT[changed_folders] + 1))
        elif [[ ! -e "${dirs[index]}" && ! -L "${dirs[index]}" ]]; then
            IMPACT_SHARING_COUNT[vanished]=$((IMPACT_SHARING_COUNT[vanished] + 1))
        else
            impact__sharing_problem "${dirs[index]}" "the shared rules could not be applied to this folder"
        fi
    done

    # Files: the whole group in a few tool calls, then a second look.
    if ((${#files[@]} > 0)); then
        impact__sharing_apply_files "${files[@]}"
        if impact__sharing_examine files file_kinds file_ids ''; then
            for index in "${!files[@]}"; do
                if [[ "${IMPACT__SHARING_WHY[index]}" == '-' ]]; then
                    IMPACT_SHARING_COUNT[changed_files]=$((IMPACT_SHARING_COUNT[changed_files] + 1))
                elif [[ -e "${files[index]}" ]]; then
                    impact__sharing_problem "${files[index]}" "still deviates after the change (${IMPACT__SHARING_WHY[index]})"
                fi
            done
        else
            # The second look itself failed (an entry vanished): count what
            # the change step reported.
            IMPACT_SHARING_COUNT[changed_files]=$((IMPACT_SHARING_COUNT[changed_files] + IMPACT__SHARING_DONE))
        fi
    fi
    if ((IMPACT__SHARING_PART % 20 == 0)); then
        impact__sharing_run_info running || true
    fi
    return 0
}

# impact__sharing_add ENTRY_KIND DEVICE INODE PATH
#   Internal: adds one entry to the current group; handles the group when
#   it is full. Result: as impact__sharing_flush.
impact__sharing_add() {
    IMPACT__SHARING_KINDS+=("$1")
    IMPACT__SHARING_IDS+=("$2:$3")
    IMPACT__SHARING_PATHS+=("$4")
    IMPACT__SHARING_BYTES=$((IMPACT__SHARING_BYTES + ${#4} + 1))
    if ((${#IMPACT__SHARING_PATHS[@]} >= IMPACT_SHARING_BATCH_SIZE || IMPACT__SHARING_BYTES >= IMPACT_SHARING_BATCH_BYTES)); then
        impact__sharing_flush
        return
    fi
    return 0
}

# impact__sharing_progress
#   Internal: prints one progress line.
impact__sharing_progress() {
    if ((IMPACT_SHARING_APPLY == 1)); then
        impact_info "... $(impact_now_utc): $(impact_sharing_number "${IMPACT_SHARING_COUNT[examined]}") entries examined, $(impact_sharing_number "$((IMPACT_SHARING_COUNT[changed_folders] + IMPACT_SHARING_COUNT[changed_files]))") changed so far"
    else
        impact_info "... $(impact_now_utc): $(impact_sharing_number "${IMPACT_SHARING_COUNT[examined]}") entries examined, $(impact_sharing_number "$((IMPACT_SHARING_COUNT[deviating_folders] + IMPACT_SHARING_COUNT[deviating_files]))") deviate so far"
    fi
}

# impact__sharing_on_exit EXIT_CODE
#   Internal: registered with impact_on_exit. When a changing run stops
#   early (Ctrl+C, a closed terminal, an error), it marks the backup as
#   interrupted and adds what was changed so far to "What changed" and to
#   the log.
impact__sharing_on_exit() {
    if ((IMPACT_SHARING_RUNNING == 0)); then
        return 0
    fi
    IMPACT_SHARING_RUNNING=0
    if [[ -n "$IMPACT_SHARING_BACKUP" && -d "$IMPACT_SHARING_BACKUP" ]]; then
        impact__sharing_run_info interrupted 2>/dev/null || true
        impact_changed "Apply the shared rules to $(impact_sharing_count "${IMPACT_SHARING_COUNT[changed_folders]:-0}" folder folders) and $(impact_sharing_count "${IMPACT_SHARING_COUNT[changed_files]:-0}" file files) below $IMPACT_SHARING_TARGET (the run stopped early; previous rights saved in $IMPACT_SHARING_BACKUP)"
        impact_undo "Put the previous rights back: sudo impact-share-folder --restore $IMPACT_SHARING_BACKUP"
        impact_undo "Or finish the work: run the same impact-share-folder command again."
    fi
}

# impact_sharing_walk
#   The walk of impact-share-folder. Input: the IMPACT_SHARING_* variables
#   at the top of this file. With IMPACT_SHARING_APPLY=0 it only counts.
#   Cost: one pass through the tree with "find" (one directory read per
#   folder and one status read per entry), getfacl for every entry it
#   examines (in groups of 500), and for each entry that deviates: about
#   ten short program starts per folder and three per group of up to 500
#   files, plus gzip for the backup.
#   Result: 0 when every entry follows the rules at the end (or, in a dry
#   run, when everything could be examined); 1 when single entries failed
#   (listed in IMPACT_SHARING_PROBLEMS); 2 when the walk had to stop.
impact_sharing_walk() {
    local record kind device inode links path target_device mount key status=0 walk_status=0
    local next_progress
    local -a mounts=() find_args=()
    impact__sharing_reset
    IMPACT__SHARING_STARTED="$(impact_now_utc)"
    if [[ -z "$IMPACT__SHARING_TMP" ]]; then
        impact_mktemp_dir || return 2
        IMPACT__SHARING_TMP="$IMPACT_TMP"
    fi
    target_device="$(stat -c '%d' -- "$IMPACT_SHARING_TARGET")" || return 2

    # The find command: start at the resolved folder; -xdev stays on its
    # file system; every mount point inside is left out with "-prune"
    # (find -xdev alone would still list the mount point itself).
    find_args=("$IMPACT_SHARING_TARGET" -xdev)
    impact_sharing_mounts_below "$IMPACT_SHARING_TARGET" mounts
    for mount in "${mounts[@]}"; do
        find_args+=(-path "$(impact_sharing_glob_quote "$mount")" -prune -o)
        IMPACT_SHARING_COUNT[mounts]=$((IMPACT_SHARING_COUNT[mounts] + 1))
    done
    if ((IMPACT_SHARING_QUICK == 1)); then
        # The quick test of --repair: all folders, and only the files whose
        # group, group rights or link count (hard links) already show a
        # deviation in their plain mode. "\(" and "\)" group find tests;
        # "!" means "not"; -perm -g=rw means "the group has at least rw".
        find_args+=(\( -type d -o -type f \( ! -group "$IMPACT_SHARING_GID" -o ! -perm -g=rw
            -o \( -perm -u=x ! -perm -g=x \) -o -links +1 \) \))
    fi
    # -printf writes for each entry: type (d folder, f file, l link, ...),
    # device, inode, number of names (hard links), path; "\0" ends each
    # entry with a zero byte, the one character that no path can contain.
    find_args+=(-printf '%y %D %i %n %p\0')

    if ((IMPACT_SHARING_APPLY == 1)); then
        IMPACT_SHARING_RUNNING=1
    fi
    next_progress=$((SECONDS + IMPACT_SHARING_PROGRESS_SECONDS))
    # "read -d ''" reads up to the next zero byte. "< <( ... )" feeds the
    # output of find into the loop ("process substitution"), so the loop
    # runs in this shell and its counters stay visible afterwards.
    while IFS= read -r -d '' record; do
        # Cut the record into its five parts. "${record%% *}" is the text
        # before the first space, "${record#* }" the text after it.
        kind="${record%% *}"; record="${record#* }"
        device="${record%% *}"; record="${record#* }"
        inode="${record%% *}"; record="${record#* }"
        links="${record%% *}"; path="${record#* }"
        IMPACT_SHARING_COUNT[examined]=$((IMPACT_SHARING_COUNT[examined] + 1))
        case "$kind" in
            d | f)
                if [[ "$device" != "$target_device" ]]; then
                    IMPACT_SHARING_COUNT[other_fs]=$((IMPACT_SHARING_COUNT[other_fs] + 1))
                    continue
                fi
                if [[ "$kind" == 'd' ]]; then
                    IMPACT_SHARING_COUNT[folders]=$((IMPACT_SHARING_COUNT[folders] + 1))
                else
                    IMPACT_SHARING_COUNT[files]=$((IMPACT_SHARING_COUNT[files] + 1))
                    if ((links > 1)); then
                        # A file with several names: decided at the end,
                        # when it is known whether all names lie inside.
                        key="$device:$inode"
                        IMPACT__SHARING_LINK_SEEN[$key]=$((${IMPACT__SHARING_LINK_SEEN[$key]:-0} + 1))
                        IMPACT__SHARING_LINK_TOTAL[$key]="$links"
                        if [[ ! -v IMPACT__SHARING_LINK_PATH[$key] ]]; then
                            IMPACT__SHARING_LINK_PATH[$key]="$path"
                        fi
                        continue
                    fi
                fi
                impact__sharing_add "$kind" "$device" "$inode" "$path" || status=$?
                if ((status == 2)); then
                    break
                fi
                ;;
            l) IMPACT_SHARING_COUNT[links]=$((IMPACT_SHARING_COUNT[links] + 1)) ;;
            *) IMPACT_SHARING_COUNT[other]=$((IMPACT_SHARING_COUNT[other] + 1)) ;;
        esac
        if ((SECONDS >= next_progress)); then
            impact__sharing_progress
            next_progress=$((SECONDS + IMPACT_SHARING_PROGRESS_SECONDS))
        fi
    done < <(find "${find_args[@]}" 2>"$IMPACT__SHARING_TMP/find.err")
    # "wait $!" collects the exit code of find ($! is its process number).
    wait "$!" || walk_status=$?

    if ((status != 2)); then
        impact__sharing_flush || status=$?
    fi
    if ((status != 2)); then
        # Files with several names: changed only when every name lies inside
        # the folder; otherwise a change would also reach a place outside.
        for key in "${!IMPACT__SHARING_LINK_TOTAL[@]}"; do
            if ((IMPACT__SHARING_LINK_SEEN[$key] >= IMPACT__SHARING_LINK_TOTAL[$key])); then
                impact__sharing_add f "${key%%:*}" "${key#*:}" "${IMPACT__SHARING_LINK_PATH[$key]}" || status=$?
                ((status != 2)) || break
            else
                IMPACT_SHARING_COUNT[hardlinks_left]=$((IMPACT_SHARING_COUNT[hardlinks_left] + 1))
                IMPACT_SHARING_HARDLINKS+=("$(impact_display "${IMPACT__SHARING_LINK_PATH[$key]}")")
            fi
        done
    fi
    if ((status != 2)); then
        impact__sharing_flush || status=$?
    fi
    if [[ -s "$IMPACT__SHARING_TMP/find.err" ]]; then
        IMPACT_SHARING_FIND_ERRORS="$(head -n 5 -- "$IMPACT__SHARING_TMP/find.err" | cut -c1-300)"
    else
        IMPACT_SHARING_FIND_ERRORS=''
    fi
    if ((walk_status != 0)) && [[ -z "$IMPACT_SHARING_FIND_ERRORS" ]]; then
        IMPACT_SHARING_FIND_ERRORS="find ended with exit code $walk_status"
    fi

    if ((IMPACT_SHARING_APPLY == 1)); then
        IMPACT_SHARING_RUNNING=0
        if [[ -n "$IMPACT_SHARING_BACKUP" ]]; then
            if ((status == 2)); then
                impact__sharing_run_info failed || true
            else
                impact__sharing_run_info finished || status=1
            fi
            if ((${#IMPACT_SHARING_PROBLEMS[@]} > 0 || ${#IMPACT_SHARING_HARDLINKS[@]} > 0)); then
                {
                    printf 'Entries that could not be changed:\n'
                    printf '  %s\n' "${IMPACT_SHARING_PROBLEMS[@]}"
                    printf 'Files left alone because they have further names outside the folder:\n'
                    printf '  %s\n' "${IMPACT_SHARING_HARDLINKS[@]}"
                } | impact_write_file_atomic "$IMPACT_SHARING_BACKUP/problems.txt" 600 root root || true
            fi
        fi
    fi
    if ((status == 2)); then
        return 2
    fi
    if ((IMPACT_SHARING_COUNT[failed] > 0)) || [[ -n "$IMPACT_SHARING_FIND_ERRORS" ]]; then
        return 1
    fi
    return 0
}

# impact__sharing_why_text ARRAY_NAME
#   Internal: prints the reasons of one kind as plain words with counts.
impact__sharing_why_text() {
    local -n impact__why="$1"
    local word text='' label
    for word in group setgid access default user; do
        [[ -v impact__why[$word] ]] || continue
        case "$word" in
            group) label='other group' ;;
            setgid) label='setgid missing' ;;
            access) label='group may not read, write or enter' ;;
            default) label='default ACL missing or different' ;;
            user) label='transition entry to change' ;;
        esac
        text+="${text:+; }$label: $(impact_sharing_number "${impact__why[$word]}")"
    done
    printf '%s' "$text"
}

# impact_sharing_report
#   Prints the counts of the last walk below the current step, in the same
#   words for a dry run and a real run.
impact_sharing_report() {
    local text item
        if ((IMPACT_SHARING_QUICK == 1)); then
        impact_info "Examined: $(impact_sharing_count "${IMPACT_SHARING_COUNT[folders]}" folder folders), and $(impact_sharing_count "${IMPACT_SHARING_COUNT[files]}" file files) that the quick test of --repair picked out."
    else
        impact_info "Examined: $(impact_sharing_count "${IMPACT_SHARING_COUNT[folders]}" folder folders) and $(impact_sharing_count "${IMPACT_SHARING_COUNT[files]}" file files)."
    fi
    text=''
    if ((IMPACT_SHARING_COUNT[links] > 0)); then text+="${text:+, }$(impact_sharing_count "${IMPACT_SHARING_COUNT[links]}" 'symbolic link' 'symbolic links') (never followed, never changed)"; fi
    if ((IMPACT_SHARING_COUNT[other] > 0)); then text+="${text:+, }$(impact_sharing_count "${IMPACT_SHARING_COUNT[other]}" 'special entry' 'special entries') (devices, pipes, sockets)"; fi
    if ((IMPACT_SHARING_COUNT[mounts] > 0)); then text+="${text:+, }$(impact_sharing_count "${IMPACT_SHARING_COUNT[mounts]}" 'mount point' 'mount points') with everything below"; fi
    if ((IMPACT_SHARING_COUNT[other_fs] > 0)); then text+="${text:+, }$(impact_sharing_count "${IMPACT_SHARING_COUNT[other_fs]}" entry entries) on another file system"; fi
    if ((IMPACT_SHARING_COUNT[hardlinks_left] > 0)); then text+="${text:+, }$(impact_sharing_count "${IMPACT_SHARING_COUNT[hardlinks_left]}" file files) with further names outside the folder"; fi
    if [[ -n "$text" ]]; then
        impact_info "Left alone: $text."
    fi
    text="$(impact__sharing_why_text IMPACT_SHARING_DIR_WHY)"
    impact_info "Folders that deviate from the rules: $(impact_sharing_number "${IMPACT_SHARING_COUNT[deviating_folders]}")${text:+ ($text)}."
    text="$(impact__sharing_why_text IMPACT_SHARING_FILE_WHY)"
    impact_info "Files that deviate from the rules: $(impact_sharing_number "${IMPACT_SHARING_COUNT[deviating_files]}")${text:+ ($text)}."
    if ((IMPACT_SHARING_APPLY == 1)); then
        impact_info "Changed: $(impact_sharing_count "${IMPACT_SHARING_COUNT[changed_folders]}" folder folders) and $(impact_sharing_count "${IMPACT_SHARING_COUNT[changed_files]}" file files)."
    fi
    if ((IMPACT_SHARING_COUNT[vanished] > 0)); then
        impact_info "Entries that disappeared while the command ran (left alone): $(impact_sharing_number "${IMPACT_SHARING_COUNT[vanished]}")."
    fi
    if ((${#IMPACT_SHARING_HARDLINKS[@]} > 0)); then
        impact_warn "Files with further names (hard links) outside the folder: $(impact_sharing_number "${#IMPACT_SHARING_HARDLINKS[@]}"). They were left alone, because a change would reach those places too. Check them by hand; the first ones:"
        for item in "${IMPACT_SHARING_HARDLINKS[@]:0:IMPACT_SHARING_SHOW_MAX}"; do
            impact_info "  $item"
        done
    fi
    if ((${#IMPACT_SHARING_PROBLEMS[@]} > 0)); then
        impact_warn "Entries that could not be handled: $(impact_sharing_number "${#IMPACT_SHARING_PROBLEMS[@]}"). The first ones:"
        for item in "${IMPACT_SHARING_PROBLEMS[@]:0:IMPACT_SHARING_SHOW_MAX}"; do
            impact_info "  $item"
        done
    fi
    if [[ -n "${IMPACT_SHARING_FIND_ERRORS:-}" ]]; then
        impact_warn "The walk through the folder reported problems (the first lines follow). Entries behind them were not examined:"
        while IFS= read -r item; do
            impact_info "  $(impact_display "$item")"
        done <<<"$IMPACT_SHARING_FIND_ERRORS"
    fi
}

# =============================================================================
# Putting saved rights back (--restore)
# =============================================================================

# impact_sharing_read_run_info FOLDER
#   Reads FOLDER/run.info into the associative array IMPACT_SHARING_RUN.
#   Result: failure with the reason in IMPACT_STORAGE_ERROR when the file is
#   missing, not safe (not root's, writable by others) or incomplete.
impact_sharing_read_run_info() {
    local file="$1/run.info" key
    local -a order=() errors=()
    declare -gA IMPACT_SHARING_RUN=()
    IMPACT_STORAGE_ERROR=''
    if ! impact_file_is_trusted "$file"; then
        IMPACT_STORAGE_ERROR="The backup folder $1 has no usable run.info: $IMPACT_CHECK_REASON"
        return 1
    fi
    if ! impact_kv_parse "$file" IMPACT_SHARING_RUN order errors; then
        IMPACT_STORAGE_ERROR="$file cannot be read: ${errors[0]:-unknown problem}"
        return 1
    fi
    for key in BACKUP_FORMAT KIND TARGET GROUP_NUMBER STATE; do
        if [[ ! -v IMPACT_SHARING_RUN[$key] ]]; then
            IMPACT_STORAGE_ERROR="$file lacks the key $key."
            return 1
        fi
    done
    if [[ "${IMPACT_SHARING_RUN[BACKUP_FORMAT]}" != '1' || "${IMPACT_SHARING_RUN[KIND]}" != 'share-folder' ]]; then
        IMPACT_STORAGE_ERROR="$file has an unknown format."
        return 1
    fi
    if ! impact_valid_abs_path "${IMPACT_SHARING_RUN[TARGET]}"; then
        IMPACT_STORAGE_ERROR="The folder named in $file is no clean path."
        return 1
    fi
    return 0
}

# impact__sharing_restore_apply KEY PATH...
#   Internal: gives all PATHs the saved state KEY ("type|owner|group|flags|
#   entries"). Order: owner and group first (this clears setuid and setgid
#   of executable files), then the ACL with the rights, then the three
#   special bits. Symbolic links are never followed: chown -h changes a
#   link itself, setfacl -P skips links, and the caller checked just before
#   that no PATH is a link.
impact__sharing_restore_apply() {
    local key="$1" kind owner group flags entries
    shift
    IFS='|' read -r kind owner group flags entries <<<"$key"
    # "+NUMBER" makes chown read a number, never an account name.
    chown -h -- "+$owner:+$group" "$@" || return 1
    # The entries are separated by ","; tr turns them into lines for
    # setfacl, which reads them from standard input ("-").
    printf '%s\n' "$entries" | tr ',' '\n' | setfacl -P --set-file=- -- "$@" || return 1
    if [[ "$kind" == 'd' && "$entries" != *default:* ]]; then
        # --set-file keeps an existing default ACL; -k removes it.
        setfacl -P -k -- "$@" || return 1
    fi
    chmod "$(impact_sharing_flags_chmod "$flags")" -- "$@"
}

# impact__sharing_restore_flush
#   Internal: handles the current group of the restore: checks that every
#   entry is still the same file (same inode), reads its present state,
#   and puts the saved state back where it differs.
impact__sharing_restore_flush() {
    local count="${#IMPACT__SHARING_PATHS[@]}" index line number kind ident owner group flags entries rest key
    local -a paths=() saved=() ids=() current=() keep=() idents=()
    local -A groups=()
    ((count > 0)) || return 0
    paths=("${IMPACT__SHARING_PATHS[@]}")
    saved=("${IMPACT__SHARING_KINDS[@]}")
    ids=("${IMPACT__SHARING_IDS[@]}")
    IMPACT__SHARING_PATHS=()
    IMPACT__SHARING_KINDS=()
    IMPACT__SHARING_IDS=()
    IMPACT__SHARING_BYTES=0

    # Device and inode now. stat -c '%d:%i' prints one line per path; a path
    # that vanished was already sorted out by the caller.
    mapfile -t idents < <(stat -c '%d:%i' -- "${paths[@]}" 2>/dev/null)
    if ((${#idents[@]} != count)); then
        # Fall back to one call per entry.
        idents=()
        for index in "${!paths[@]}"; do
            idents+=("$(stat -c '%d:%i' -- "${paths[index]}" 2>/dev/null || printf 'gone')")
        done
    fi
    for index in "${!paths[@]}"; do
        if [[ "${idents[index]}" != "${ids[index]}" ]]; then
            IMPACT_SHARING_COUNT[skipped]=$((IMPACT_SHARING_COUNT[skipped] + 1))
            IMPACT_SHARING_PROBLEMS+=("$(impact_display "${paths[index]}"): is another file now (left alone)")
        else
            keep+=("$index")
        fi
    done
    ((${#keep[@]} > 0)) || return 0
    local -a check_paths=()
    for index in "${keep[@]}"; do
        check_paths+=("${paths[index]}")
    done
    # The present state, in the same normalized form as the saved one.
    mapfile -t current < <(getfacl -P -p -n -E -- "${check_paths[@]}" 2>/dev/null | impact_sharing_normalize)
    if ((${#current[@]} != ${#check_paths[@]})); then
        impact_error "The present rights of a group of entries could not be read; this group is left alone."
        IMPACT_SHARING_COUNT[failed]=$((IMPACT_SHARING_COUNT[failed] + ${#check_paths[@]}))
        return 0
    fi
    for number in "${!keep[@]}"; do
        index="${keep[number]}"
        IFS=$'\t' read -r _ _ _ owner group flags entries _ <<<"${current[number]}"
        # saved[index] holds "type|owner|group|flags|entries".
        if [[ "${saved[index]#*|}" == "$owner|$group|$flags|$entries" ]]; then
            IMPACT_SHARING_COUNT[already]=$((IMPACT_SHARING_COUNT[already] + 1))
            continue
        fi
        IMPACT_SHARING_COUNT[to_restore]=$((IMPACT_SHARING_COUNT[to_restore] + 1))
        if ((IMPACT_SHARING_APPLY == 1)); then
            # Group the entries by their saved state, so one tool call
            # handles all entries with the same state. The list holds the
            # numbers of the entries, separated by spaces.
            key="${saved[index]}"
            groups[$key]+="$index "
        fi
    done
    ((IMPACT_SHARING_APPLY == 1)) || return 0
    local -a members=() numbers=()
    for key in "${!groups[@]}"; do
        members=()
        read -r -a numbers <<<"${groups[$key]}"
        for index in "${numbers[@]}"; do
            # Last look just before the change: still no symbolic link.
            if [[ -L "${paths[index]}" ]]; then
                IMPACT_SHARING_PROBLEMS+=("$(impact_display "${paths[index]}"): became a symbolic link (left alone)")
                IMPACT_SHARING_COUNT[skipped]=$((IMPACT_SHARING_COUNT[skipped] + 1))
                continue
            fi
            members+=("${paths[index]}")
        done
        ((${#members[@]} > 0)) || continue
        if impact__sharing_restore_apply "$key" "${members[@]}"; then
            IMPACT_SHARING_COUNT[restored]=$((IMPACT_SHARING_COUNT[restored] + ${#members[@]}))
        else
            IMPACT_SHARING_COUNT[failed]=$((IMPACT_SHARING_COUNT[failed] + ${#members[@]}))
            IMPACT_SHARING_PROBLEMS+=("$(impact_display "${members[0]}") and $((${#members[@]} - 1)) more: the saved rights could not be put back")
        fi
    done
}

# impact__sharing_restore_entry_ok PATH TYPE TARGET
#   Internal: the checks for one saved entry before it is restored: the
#   path lies inside TARGET, contains no "." or ".." part, no folder on the
#   way (and not the entry itself) is a symbolic link, and the entry is
#   still a folder (d) or a plain file (f). Sets IMPACT__SHARING_REASON.
impact__sharing_restore_entry_ok() {
    local path="$1" kind="$2" target="$3" current
    IMPACT__SHARING_REASON=''
    if [[ "$path" != "$target" && "$path" != "$target"/* ]]; then
        IMPACT__SHARING_REASON='lies outside the folder of the backup'
        return 1
    fi
    if [[ "$path/" == */./* || "$path/" == */../* ]]; then
        IMPACT__SHARING_REASON='has a . or .. part'
        return 1
    fi
    if [[ -L "$path" ]]; then
        IMPACT__SHARING_REASON='is a symbolic link now'
        return 1
    fi
    if [[ "$kind" == 'd' && ! -d "$path" ]] || [[ "$kind" == 'f' && ! -f "$path" ]]; then
        if [[ -e "$path" ]]; then
            IMPACT__SHARING_REASON='is another kind of entry now'
        else
            IMPACT__SHARING_REASON='does not exist any more'
        fi
        return 1
    fi
    # Every folder between TARGET and the entry must be a real folder.
    current="$(dirname -- "$path")"
    while [[ "$current" == "$target"/* ]]; do
        if [[ -L "$current" ]]; then
            IMPACT__SHARING_REASON="a folder on the way is a symbolic link now"
            return 1
        fi
        current="${current%/*}"
    done
    return 0
}

# impact_sharing_restore FOLDER
#   Puts back the rights saved in the backup folder FOLDER (one run of
#   impact-share-folder). Only entries whose present state differs from the
#   saved one are changed; entries that were replaced, removed, turned into
#   a link, or moved outside are left alone and counted. The target folder
#   must still pass impact_sharing_check_target.
#   With IMPACT_SHARING_APPLY=0 it only counts.
#   Result: 0 done; 1 single entries failed; 2 the backup cannot be used.
impact_sharing_restore() {
    local folder="$1" target part number kind ident owner group flags entries epath path
    local -a parts=()
    impact__sharing_reset
    local key
    for key in already to_restore restored skipped saved; do
        IMPACT_SHARING_COUNT[$key]=0
    done
    target="${IMPACT_SHARING_RUN[TARGET]}"
    if [[ -z "$IMPACT__SHARING_TMP" ]]; then
        impact_mktemp_dir || return 2
        IMPACT__SHARING_TMP="$IMPACT_TMP"
    fi
    # "nullglob": a pattern without a match gives an empty list.
    shopt -s nullglob
    parts=("$folder"/part-*.facl.gz)
    shopt -u nullglob
    for part in "${parts[@]}"; do
        if [[ -L "$part" || ! -f "$part" ]]; then
            impact_error "$part is no plain file; it is left out."
            IMPACT_SHARING_COUNT[failed]=$((IMPACT_SHARING_COUNT[failed] + 1))
            continue
        fi
        if ! gzip -dc -- "$part" 2>/dev/null | impact_sharing_normalize >"$IMPACT__SHARING_TMP/records"; then
            impact_error "The backup part $part cannot be read completely; it is left out."
            IMPACT_SHARING_COUNT[failed]=$((IMPACT_SHARING_COUNT[failed] + 1))
            continue
        fi
        while IFS=$'\t' read -r number kind ident owner group flags entries epath; do
            IMPACT_SHARING_COUNT[saved]=$((IMPACT_SHARING_COUNT[saved] + 1))
            impact_sharing_unescape "$epath"
            path="$IMPACT_SHARING_TEXT"
            if [[ "$kind" != 'd' && "$kind" != 'f' ]] || ! [[ "$ident" =~ ^[0-9]+:[0-9]+$ ]] ||
                ! [[ "$owner" =~ ^[0-9]+$ && "$group" =~ ^[0-9]+$ && "$flags" =~ ^[-s][-s][-t]$ ]]; then
                IMPACT_SHARING_COUNT[skipped]=$((IMPACT_SHARING_COUNT[skipped] + 1))
                IMPACT_SHARING_PROBLEMS+=("record $number of $(basename -- "$part"): damaged (left alone)")
                continue
            fi
            if ! impact__sharing_restore_entry_ok "$path" "$kind" "$target"; then
                IMPACT_SHARING_COUNT[skipped]=$((IMPACT_SHARING_COUNT[skipped] + 1))
                IMPACT_SHARING_PROBLEMS+=("$(impact_display "$path"): $IMPACT__SHARING_REASON (left alone)")
                continue
            fi
            IMPACT__SHARING_PATHS+=("$path")
            IMPACT__SHARING_KINDS+=("$kind|$owner|$group|$flags|$entries")
            IMPACT__SHARING_IDS+=("$ident")
            IMPACT__SHARING_BYTES=$((IMPACT__SHARING_BYTES + ${#path} + 1))
            if ((${#IMPACT__SHARING_PATHS[@]} >= IMPACT_SHARING_BATCH_SIZE || IMPACT__SHARING_BYTES >= IMPACT_SHARING_BATCH_BYTES)); then
                impact__sharing_restore_flush
            fi
        done <"$IMPACT__SHARING_TMP/records"
        impact__sharing_restore_flush
    done
    if ((IMPACT_SHARING_COUNT[failed] > 0)); then
        return 1
    fi
    return 0
}

# impact_sharing_restore_report
#   Prints the counts of the last restore.
impact_sharing_restore_report() {
    local item
        impact_info "Entries saved in the backup: $(impact_sharing_number "${IMPACT_SHARING_COUNT[saved]}")."
    impact_info "Already in the saved state: $(impact_sharing_number "${IMPACT_SHARING_COUNT[already]}")."
    impact_info "To put back: $(impact_sharing_number "${IMPACT_SHARING_COUNT[to_restore]}")."
    if ((IMPACT_SHARING_APPLY == 1)); then
        impact_info "Put back: $(impact_sharing_number "${IMPACT_SHARING_COUNT[restored]}")."
    fi
    if ((IMPACT_SHARING_COUNT[skipped] > 0)); then
        impact_warn "Saved entries left alone because they changed in another way since the backup: $(impact_sharing_number "${IMPACT_SHARING_COUNT[skipped]}"). The first ones:"
        for item in "${IMPACT_SHARING_PROBLEMS[@]:0:IMPACT_SHARING_SHOW_MAX}"; do
            impact_info "  $item"
        done
    elif ((${#IMPACT_SHARING_PROBLEMS[@]} > 0)); then
        for item in "${IMPACT_SHARING_PROBLEMS[@]:0:IMPACT_SHARING_SHOW_MAX}"; do
            impact_info "  $item"
        done
    fi
    if ((IMPACT_SHARING_COUNT[failed] > 0)); then
        impact_warn "Entries or backup parts that failed: $(impact_sharing_number "${IMPACT_SHARING_COUNT[failed]}") (see the error lines above)."
    fi
}

# =============================================================================
# Helpers for impact-export-state
# =============================================================================

# impact_sharing_manifest_code PATHS_NAME SOURCES_NAME
#   Prints one code (a SHA-256 checksum) for the content of an archive that
#   is described by two lists of the same length (given by their NAMES):
#   the path inside the archive, and the file it comes from. The code covers
#   each path, the mode, owner and group of the file, and the checksum of
#   its content; times are left out. Two runs with the same state give the
#   same code, so impact-export-state can tell that nothing changed.
#   Example: code="$(impact_sharing_manifest_code ITEM_PATHS ITEM_SOURCES)"
impact_sharing_manifest_code() {
    local -n impact__code_paths="$1" impact__code_sources="$2"
    local index
    for index in "${!impact__code_paths[@]}"; do
        printf '%s\t%s\t%s\n' "${impact__code_paths[index]}" \
            "$(stat -c '%a %u %g' -- "${impact__code_sources[index]}")" \
            "$(sha256sum -- "${impact__code_sources[index]}" | cut -d' ' -f1)"
    done | LC_ALL=C sort | sha256sum | cut -d' ' -f1
}

# =============================================================================
# Helpers for impact-clean-images
# =============================================================================

# impact_sharing_valid_image_name TEXT
#   Result: success when TEXT is an image name "<repository>:<tag>" of the
#   form that the GUI builds: repository in lower case (letters, digits,
#   ".", "_", "-", parts joined by "/"), tag of letters, digits, "_", "."
#   and "-". Only such names are ever given to "docker image rm".
impact_sharing_valid_image_name() {
    [[ "$1" =~ ^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]
}

# impact_sharing_valid_image_id TEXT
#   Result: success when TEXT is a full image number: "sha256:" and 64
#   hexadecimal digits.
impact_sharing_valid_image_id() {
    [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]]
}

# impact_sharing_image_decision IN_USE ACCOUNT_STATE NAME COPIES
#   The rule of impact-clean-images for one image name, as a pure function.
#   Parameters:
#     IN_USE         "yes" when a container (running or stopped) uses the
#                    image
#     ACCOUNT_STATE  "active", "removed" (record says removed, or the
#                    account is expired), "gone" (the account does not
#                    exist), "invalid" (the label is no account name) or
#                    "unknown" (the person's working copies could not be
#                    listed)
#     NAME           "<repository>:<tag>", or "" for an image without name
#     COPIES         the names of the person's repository folders in lower
#                    case, separated by spaces
#   Prints "keep <reason>" or "remove <reason>"; the reason is one word:
#   in_use, not_impact, account_removed, no_repository_copy, unnamed,
#   repository_copy, copies_unknown.
impact_sharing_image_decision() {
    local in_use="$1" state="$2" name="$3" copies=" $4 " repository
    if [[ "$in_use" == 'yes' ]]; then
        printf 'keep in_use\n'
    elif [[ "$state" == 'invalid' ]]; then
        printf 'keep not_impact\n'
    elif [[ "$state" == 'removed' || "$state" == 'gone' ]]; then
        printf 'remove account_removed\n'
    elif [[ "$state" == 'unknown' ]]; then
        printf 'keep copies_unknown\n'
    elif [[ -z "$name" ]]; then
        printf 'remove unnamed\n'
    else
        repository="${name%:*}"
        if [[ "$copies" == *" $repository "* ]]; then
            printf 'keep repository_copy\n'
        else
            printf 'remove no_repository_copy\n'
        fi
    fi
}
