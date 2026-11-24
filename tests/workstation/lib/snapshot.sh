#!/bin/bash
# =============================================================================
# snapshot.sh: record the state of the system and compare two records
#
# Purpose
#   A "snapshot" is a text file that lists: all accounts, all groups, the
#   password state of every account, and for each given folder every entry
#   below it with type, owner, group, mode, link target and ACL (access
#   control list). Two snapshots are equal exactly when none of these facts
#   changed. Tests use this to prove "a dry run changes nothing" and "a
#   second run changes nothing".
#
# Who runs it
#   Nobody directly. testlib.sh loads it.
#
# Usage (inside a test)
#   snapshot_take "$TEST_TMP/before" /etc/impact /opt/impact
#   run_cmd impact-workstation-setup --dry-run ...
#   snapshot_take "$TEST_TMP/after" /etc/impact /opt/impact
#   snapshot_assert_same "$TEST_TMP/before" "$TEST_TMP/after"
#
#   or in one step:
#   snapshot_unchanged_by --content /etc/impact /opt/impact -- \
#       impact-workstation-setup --dry-run ...
#
# Options of snapshot_take and snapshot_unchanged_by
#   --content        also record a checksum of every plain file, so a changed
#                    file content is noticed (for example a new log block)
#   --exclude PATH   leave PATH and everything below it out (may be repeated)
#   --no-accounts    record the folders only, without accounts and groups
#                    (for a step that is expected to create a group or an
#                    account and must leave the folders alone)
#
# What it changes on the system
#   It writes the snapshot file. Everything else is only read.
#
# How to undo
#   Remove the snapshot file (the test folder is removed by the runner).
# =============================================================================

# Reading help: the bash constructs used here are explained at the top of
# testlib.sh ("Reading help") and where they are first used.

# snapshot__entries FOLDER EXCLUDE...
#   Internal: prints one line per entry below FOLDER:
#   path|type|owner name:group name|owner number:group number|mode|link target
#   The walk stays on one file system and never follows symbolic links.
snapshot__entries() {
    local folder="$1" exclude
    shift
    local -a prune=()
    for exclude in "$@"; do
        # find: "-path X -prune -o" leaves X and its content out.
        prune+=(-path "$exclude" -prune -o)
    done
    # %p path, %y type (d folder, f file, l link), %U %G names, %u %g
    # numbers, %m mode, %l target of a symbolic link.
    find "$folder" -xdev "${prune[@]}" -printf '%p|%y|%U:%G|%u:%g|%m|%l\n' 2>/dev/null | LC_ALL=C sort
}

# snapshot__acls FOLDER EXCLUDE...
#   Internal: prints one line per entry below FOLDER with its complete ACL:
#   path<TAB>entry,entry,...  Numbers are used for accounts and groups.
snapshot__acls() {
    local folder="$1" exclude
    shift
    local -a prune=()
    for exclude in "$@"; do
        prune+=(-path "$exclude" -prune -o)
    done
    # getfacl prints one block per file: a line "# file: <path>", further
    # "#" lines, the entries, and an empty line. awk joins each block into
    # one line. -P: never follow symbolic links; -n: numbers; -p: full paths.
    find "$folder" -xdev "${prune[@]}" ! -type l -print0 2>/dev/null |
        xargs -0 -r getfacl -P -p -n -- 2>/dev/null |
        awk '
            /^# file: / { if (path != "") print path "\t" entries; path = substr($0, 9); entries = ""; next }
            /^#/ { entries = entries (entries == "" ? "" : ",") $0; next }
            /^$/ { next }
            { entries = entries (entries == "" ? "" : ",") $0 }
            END { if (path != "") print path "\t" entries }
        ' | LC_ALL=C sort
}

# snapshot__contents FOLDER EXCLUDE...
#   Internal: prints a checksum line for every plain file below FOLDER.
snapshot__contents() {
    local folder="$1" exclude
    shift
    local -a prune=()
    for exclude in "$@"; do
        prune+=(-path "$exclude" -prune -o)
    done
    find "$folder" -xdev "${prune[@]}" -type f -print0 2>/dev/null |
        LC_ALL=C sort -z | xargs -0 -r sha256sum -- 2>/dev/null
}

# snapshot_take OUTPUT_FILE [--content] [--no-accounts] [--exclude PATH]... FOLDER...
#   Writes a snapshot to OUTPUT_FILE: accounts, groups, password states (as
#   root), and every entry below each FOLDER. A FOLDER that does not exist is
#   recorded as absent, so its later creation shows up as a difference.
#   Example: snapshot_take "$TEST_TMP/before" /etc/impact /mnt/disk_a/shared
snapshot_take() {
    local output="$1" with_content=0 with_accounts=1 folder
    local -a excludes=() folders=()
    shift
    while (($# > 0)); do
        case "$1" in
            --content)
                with_content=1
                shift
                ;;
            --no-accounts)
                with_accounts=0
                shift
                ;;
            --exclude)
                excludes+=("$2")
                shift 2
                ;;
            *)
                folders+=("$1")
                shift
                ;;
        esac
    done
    {
        if ((with_accounts == 1)); then
            printf '## accounts\n'
            getent passwd | LC_ALL=C sort
            printf '## groups\n'
            getent group | LC_ALL=C sort
        fi
        if ((with_accounts == 1 && EUID == 0)); then
            printf '## password state and expiry of every account\n'
            # Field 2 of the shadow file holds the password hash; only its
            # kind is recorded (locked, empty or set), never the hash. Field
            # 8 is the expiry date of the account.
            getent shadow | awk -F: '{
                state = "set"
                if ($2 == "") state = "empty"
                else if (substr($2, 1, 1) == "!" || substr($2, 1, 1) == "*") state = "locked"
                print $1 ":" state ":" $8
            }' | LC_ALL=C sort
        fi
        for folder in "${folders[@]}"; do
            if [[ ! -e "$folder" && ! -L "$folder" ]]; then
                printf '## %s: ABSENT\n' "$folder"
                continue
            fi
            printf '## entries below %s\n' "$folder"
            snapshot__entries "$folder" "${excludes[@]}"
            printf '## ACLs below %s\n' "$folder"
            snapshot__acls "$folder" "${excludes[@]}"
            if ((with_content == 1)); then
                printf '## file contents below %s\n' "$folder"
                snapshot__contents "$folder" "${excludes[@]}"
            fi
        done
    } >"$output"
}

# snapshot_assert_same BEFORE_FILE AFTER_FILE [WHAT]
#   Fails the test, showing the differing lines, unless the two snapshots
#   are equal. In the output, lines with "<" are from BEFORE, lines with ">"
#   from AFTER.
snapshot_assert_same() {
    local difference
    if difference="$(diff -- "$1" "$2")"; then
        return 0
    fi
    printf '%s\n' "$difference" | head -n 60 >&2
    fail "${3:-the state of the system changed}"
}

# snapshot_assert_differs BEFORE_FILE AFTER_FILE [WHAT]
#   Fails the test when the two snapshots are equal. Useful to prove that a
#   check is able to notice a change at all.
snapshot_assert_differs() {
    if cmp -s -- "$1" "$2"; then
        fail "${3:-the state of the system did not change, and a change was expected}"
    fi
}

# snapshot_unchanged_by [--content] [--no-accounts] [--exclude PATH]... FOLDER... -- COMMAND...
#   Takes a snapshot, runs the command with run_cmd (so RUN_STATUS and
#   RUN_OUTPUT are set), takes a second snapshot, and fails the test when
#   they differ. The exit code of the command is not judged here; check it
#   with assert_status afterwards.
#   Example:
#     snapshot_unchanged_by --content /etc/impact /opt/impact -- \
#         impact-workstation-setup --dry-run --port-max 8850
#     assert_status 0
snapshot_unchanged_by() {
    local -a snapshot_arguments=()
    while (($# > 0)) && [[ "$1" != '--' ]]; do
        snapshot_arguments+=("$1")
        shift
    done
    if [[ "${1:-}" != '--' ]]; then
        fail "snapshot_unchanged_by: the mark -- before the command is missing"
    fi
    shift
    local before after
    before="$(mktemp "${TEST_TMP:-/tmp}/snapshot-before.XXXXXXXXXX")"
    after="$(mktemp "${TEST_TMP:-/tmp}/snapshot-after.XXXXXXXXXX")"
    snapshot_take "$before" "${snapshot_arguments[@]}"
    run_cmd "$@"
    snapshot_take "$after" "${snapshot_arguments[@]}"
    if ! cmp -s -- "$before" "$after"; then
        show_run
    fi
    snapshot_assert_same "$before" "$after" "the command changed the system: $*"
}
