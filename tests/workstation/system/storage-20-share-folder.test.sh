#!/bin/bash
# =============================================================================
# storage-20-share-folder.test.sh: impact-share-folder on a real tree
#
# Purpose
#   Runs impact-share-folder on a tree that looks like the old content of
#   the shared storage (owned by an old shared account, modes 755/644, odd
#   file names, symbolic links that lead out of the tree, a second disk
#   mounted inside, files with several names, a pipe, a file whose ACL mask
#   removes group write) and proves:
#     - a dry run changes nothing and prints counts;
#     - a real run applies the rules to every entry inside, and leaves alone:
#       the targets of symbolic links, the links themselves, the mounted
#       folder, the pipe, and a file with a second name outside the tree;
#     - a second run changes nothing;
#     - the backup restores the exact previous state (owner, group, mode,
#       ACL of every entry), and a second restore changes nothing;
#     - the deviation test of the walk gives the same answer as the check
#       functions of the library for many kinds of entries;
#     - two real accounts with umask 077 create files and folders that the
#       other one can change;
#     - files moved in with their old rights (and a later "chmod g-w") are
#       found and fixed by --repair;
#     - --transition-user gives an old account access, also to new
#       entries, and --remove-transition-user takes it away again;
#     - a restore names files whose special bits (setuid, setgid, sticky)
#       it leaves to the administrator, puts back those of folders, and
#       works on a folder only when it is still the saved one.
#
# Who runs it
#   tests/workstation/run-tests.sh system   (root, disposable system only;
#   the storage must be a real ext4, xfs or btrfs file system, see
#   IMPACT_TEST_BACKING_DIR in ../lib/system.sh)
#
# Usage
#   sudo env IMPACT_TEST_DISPOSABLE=yes IMPACT_TEST_BACKING_DIR=/some/ext4/folder \
#       bash tests/workstation/run-tests.sh system --filter storage-20
#
# What it changes on the system
#   The installed commands and their settings, three test accounts (alice,
#   bob, oldshared), a bind mount below /mnt/disk_a, the storage roots below
#   /mnt/disk_a and /mnt/disk_b.
#
# How to undo
#   The file removes everything it created (suite_teardown).
#
# The tests of this file build on each other and run in the order written.
# =============================================================================

# Reading help: the bash constructs used here are explained at the top of
# ../lib/testlib.sh ("Reading help") and where they are first used.

# The lines for the checking tool "shellcheck" stand before the first command
# of the file and therefore count for the whole file.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/testlib.sh"

SHARE=/usr/local/bin/impact-share-folder
T="$SYS_ROOT_A/Example"              # the folder under test
OUTSIDE=/mnt/disk_a/outside          # same disk, outside the storage root
PRIVATE=/mnt/disk_a/private-alice    # same disk, a folder of alice only
BEFORE="before-first-run.snapshot"   # name of a file in TEST_SUITE_TMP

suite_setup() {
    sys_clean_slate
    sys_storage_up
    sys_install
    sys_admin_create
    sys_setup
    sys_account_add alice "$SYS_GROUP"
    sys_account_add bob "$SYS_GROUP"
    sys_account_add oldshared
    build_tree
    snapshot_take "$TEST_SUITE_TMP/$BEFORE" --no-accounts "$T" "$OUTSIDE"
}

suite_teardown() {
    umount -- "$T/mounted" 2>/dev/null || true
    sys_clean_slate
}

# build_tree
#   Creates the tree of old content below $T, owned by the old shared
#   account, and the places outside it that links and names point to.
build_tree() {
    mkdir -p -- "$OUTSIDE/mount-src" "$T/outputs/run1" "$T/inputs/synthpop" "$T/mounted"
    printf 'secret\n' >"$OUTSIDE/secret.txt"
    printf 'inner\n' >"$OUTSIDE/mount-src/inner.txt"
    printf 'hard\n' >"$OUTSIDE/hard-src"
    chmod 600 -- "$OUTSIDE/secret.txt" "$OUTSIDE/mount-src/inner.txt" "$OUTSIDE/hard-src"
    chmod 700 -- "$OUTSIDE/mount-src"

    printf 'a,b\n1,2\n' >"$T/outputs/run1/result.csv"
    printf '#!/bin/sh\necho hi\n' >"$T/outputs/run1/script.sh"
    printf 'x\n' >"$T/outputs/run1/name with spaces.csv"
    printf 'x\n' >"$T/outputs/run1/"$'line\nbreak.csv'
    printf 'x\n' >"$T/outputs/run1/back\\slash.csv"
    printf 'x\n' >"$T/outputs/run1/"$'tab\tname.csv'
    printf 'x\n' >"$T/outputs/run1/quote'\"and;\$(touch HOSTILE).csv"
    printf 'x\n' >"$T/outputs/run1/masked.csv"
    printf 'pop\n' >"$T/inputs/synthpop/pop.fst"
    printf 'two names\n' >"$T/hard-inside-1"
    ln -- "$T/hard-inside-1" "$T/outputs/hard-inside-2"
    ln -- "$OUTSIDE/hard-src" "$T/hard-outside"
    ln -s -- "$OUTSIDE/secret.txt" "$T/link-to-outside-file"
    ln -s -- "$OUTSIDE" "$T/link-to-outside-folder"
    ln -s -- /etc "$T/link-to-etc"
    mkfifo -- "$T/a-pipe"

    chmod 755 -- "$T" "$T/outputs" "$T/outputs/run1" "$T/inputs" "$T/mounted"
    chmod 700 -- "$T/inputs/synthpop"
    chmod 644 -- "$T/outputs/run1/result.csv" "$T/outputs/run1/back\\slash.csv" "$T/hard-inside-1"
    chmod 664 -- "$T/outputs/run1/masked.csv"
    chmod 755 -- "$T/outputs/run1/script.sh"
    chmod 600 -- "$T/outputs/run1/name with spaces.csv" "$T/inputs/synthpop/pop.fst"
    chmod 640 -- "$T/outputs/run1/"$'line\nbreak.csv' "$T/outputs/run1/"$'tab\tname.csv'
    # chown -R -h: the whole tree, links themselves, never their targets.
    chown -R -h oldshared:oldshared -- "$T"
    chown -h root:root -- "$T/hard-outside"
    # A named ACL entry, then "chmod g-w": the mask now removes the write
    # right of the group (getfacl shows "#effective:r--").
    setfacl -m u:alice:rw -- "$T/outputs/run1/masked.csv"
    chmod g-w -- "$T/outputs/run1/masked.csv"
    # Another folder of the same disk, mounted a second time inside the tree.
    mount --bind -- "$OUTSIDE/mount-src" "$T/mounted"
}

# as_person ACCOUNT SCRIPT
#   Runs a small shell script as ACCOUNT, with umask 077 (new files only for
#   the owner, unless a default ACL says otherwise).
as_person() {
    (cd / && runuser -u "$1" -- bash -c "umask 077; $2")
}

# load_settings
#   Loads the library and the site settings into the test process.
load_settings() {
    load_library
    # shellcheck source=../../../workstation/lib/impact-sharing.sh
    source "$WORKSTATION_DIR/lib/impact-sharing.sh"
    impact_conf_load || fail "the settings file cannot be read"
}

# deviating_entries FOLDER
#   Prints every folder and plain file below FOLDER that does not follow the
#   shared rules according to the check functions of the library. Mount
#   points and everything below them are left out, as the command does.
deviating_entries() {
    local path
    while IFS= read -r -d '' path; do
        if [[ -d "$path" ]]; then
            impact_shared_dir_is_ok "$path" "$SYS_GROUP" || printf '%q\n' "$path"
        elif [[ -f "$path" ]]; then
            impact_shared_file_is_ok "$path" "$SYS_GROUP" || printf '%q\n' "$path"
        fi
    done < <(find "$1" -xdev -path "$T/mounted" -prune -o \( -type d -o -type f \) -print0)
}

# backup_folders
#   Prints the backup folders of impact-share-folder, oldest first.
backup_folders() {
    find /opt/impact/admin/acl-backups -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort
}

# Dry run changes nothing and counts.
test_dry_run_changes_nothing_and_counts() {
    snapshot_unchanged_by --content /mnt/disk_a /opt/impact /etc/impact -- \
        sys_as_admin "$SHARE" "$T" --dry-run
    assert_status 0
    assert_output_contains '[dry run] Examine every folder and file below'
    assert_output_contains 'Examined: 5 folders and 12 files.'
    assert_output_contains 'Folders that deviate from the rules: 5'
    assert_output_contains 'Files that deviate from the rules: 10'
    assert_output_contains '3 symbolic links (never followed, never changed)'
    assert_output_contains '1 mount point with everything below'
    assert_output_contains '1 file with further names outside the folder'
    assert_output_contains 'A real run would do this:'
    assert_eq '' "$(backup_folders)" "backup folders after a dry run"
}

# First run applies the rules to every entry.
test_first_run_applies_the_rules_to_every_entry() {
    run_cmd sys_as_admin "$SHARE" "$T"
    assert_status 0
    assert_output_contains 'Changed: 5 folders and 10 files.'
    assert_output_contains 'What changed:'
    assert_output_contains 'sudo impact-share-folder --restore /opt/impact/admin/acl-backups/'
    assert_output_contains 'Files with further names (hard links) outside the folder: 1. They were left alone'
    load_settings
    local left
    left="$(deviating_entries "$T")"
    # The only entry left as it was: the file with a second name outside.
    assert_eq "$(printf '%q' "$T/hard-outside")" "$left" "entries that still deviate"
    # Owners and the rights of others never change; the group gets rw (and x
    # where the owner has x); folders get setgid.
    assert_file_facts "$T" 2775 oldshared "$SYS_GROUP"
    assert_file_facts "$T/inputs/synthpop" 2770 oldshared "$SYS_GROUP"
    assert_file_facts "$T/inputs/synthpop/pop.fst" 660 oldshared "$SYS_GROUP"
    assert_file_facts "$T/outputs/run1/script.sh" 775 oldshared "$SYS_GROUP"
    assert_file_facts "$T/outputs/run1/result.csv" 664 oldshared "$SYS_GROUP"
    assert_file_facts "$T/outputs/run1/"$'line\nbreak.csv' 660 oldshared "$SYS_GROUP"
    assert_file_facts "$T/outputs/hard-inside-2" 664 oldshared "$SYS_GROUP"
    # The mask no longer limits the group.
    assert_contains "$(getfacl -c -n -- "$T/outputs/run1/masked.csv")" 'mask::rw-'
    # Nothing outside the tree changed, nothing behind a link, nothing
    # below the mount point, not the links and not the pipe themselves.
    assert_file_facts "$OUTSIDE/secret.txt" 600 root root
    assert_file_facts "$OUTSIDE/hard-src" 600 root root
    assert_file_facts "$OUTSIDE/mount-src" 700 root root
    assert_file_facts "$OUTSIDE/mount-src/inner.txt" 600 root root
    assert_file_facts "$T/a-pipe" 644 oldshared oldshared
    assert_eq 'oldshared oldshared' "$(stat -c '%U %G' -- "$T/link-to-etc")" "owner of the link itself"
    assert_eq '755 root root' "$(stat -c '%a %U %G' -- /etc)" "facts of /etc"
    assert_eq "$OUTSIDE/secret.txt" "$(readlink -- "$T/link-to-outside-file")" "target of the link"
    assert_missing "$T/outputs/run1/HOSTILE"
    assert_missing /HOSTILE
    # The backup: one folder, root only, finished, parts only for root.
    local folder
    folder="$(backup_folders)"
    assert_matches "$folder" '^/opt/impact/admin/acl-backups/[0-9]{8}T[0-9]{6}Z_mnt_disk_a_shared_Example$'
    assert_file_facts /opt/impact/admin/acl-backups 700 root root
    assert_file_facts "$folder" 700 root root
    assert_file_facts "$folder/run.info" 600 root root
    assert_file_facts "$folder/part-000001.facl.gz" 600 root root
    assert_file_contains "$folder/run.info" 'STATE=finished'
    assert_file_contains "$folder/run.info" "TARGET=$T"
    # The log names the command and the backup.
    assert_file_contains /opt/impact/admin/log/impact-admin.log "impact-share-folder $T"
    assert_file_contains /opt/impact/admin/log/impact-admin.log "backup: $folder"
}

# Second run changes nothing.
test_second_run_changes_nothing() {
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log /mnt/disk_a /opt/impact /etc/impact -- \
        sys_as_admin "$SHARE" "$T"
    assert_status 0
    assert_output_contains 'Nothing to do'
    assert_output_contains 'Folders that deviate from the rules: 0.'
    assert_output_contains 'Files that deviate from the rules: 0.'
    assert_eq 1 "$(backup_folders | wc -l)" "number of backup folders"
}

# Restore dry run changes nothing.
test_restore_dry_run_changes_nothing() {
    local folder
    folder="$(backup_folders)"
    snapshot_unchanged_by --content /mnt/disk_a /opt/impact /etc/impact -- \
        sys_as_admin "$SHARE" --restore "$folder" --dry-run
    assert_status 0
    assert_output_contains 'To put back: 15.'
}

# Restore brings back the exact previous state.
test_restore_brings_back_the_exact_previous_state() {
    local folder
    folder="$(backup_folders)"
    run_cmd sys_as_admin "$SHARE" --restore "$folder"
    assert_status 0
    assert_output_contains 'Put back: 15.'
    snapshot_take "$TEST_TMP/after-restore" --no-accounts "$T" "$OUTSIDE"
    snapshot_assert_same "$TEST_SUITE_TMP/$BEFORE" "$TEST_TMP/after-restore" "the state after the restore differs from the state before the first run"
    # The short name of the backup folder works as well, and a second
    # restore finds nothing to do.
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log /mnt/disk_a /opt/impact -- \
        sys_as_admin "$SHARE" --restore "$(basename -- "$folder")"
    assert_status 0
    assert_output_contains 'Nothing to do'
    assert_output_contains 'Already in the saved state: 15.'
}

# Restore leaves alone an entry that became a link.
test_restore_leaves_alone_an_entry_that_became_a_link() {
    local folder
    folder="$(backup_folders)"
    # Apply the rules again, then replace one saved file by a link to a file
    # outside. A restore must not follow it.
    run_cmd sys_as_admin "$SHARE" "$T"
    assert_status 0
    local newest
    newest="$(backup_folders | tail -n 1)"
    mv -- "$T/outputs/run1/result.csv" "$TEST_TMP/result.csv"
    ln -s -- "$OUTSIDE/secret.txt" "$T/outputs/run1/result.csv"
    run_cmd sys_as_admin "$SHARE" --restore "$newest"
    assert_status 0
    assert_output_contains 'is a symbolic link now (left alone)'
    assert_file_facts "$OUTSIDE/secret.txt" 600 root root
    # Put the file back and apply the rules for the next tests.
    rm -f -- "$T/outputs/run1/result.csv"
    mv -- "$TEST_TMP/result.csv" "$T/outputs/run1/result.csv"
    run_cmd sys_as_admin "$SHARE" "$T"
    assert_status 0
    load_settings
    assert_eq "$(printf '%q' "$T/hard-outside")" "$(deviating_entries "$T")" "entries that still deviate"
    [[ -n "$folder" ]] || fail "no backup folder"
}

# Walk and library agree on every kind of entry.
test_walk_and_library_agree_on_every_kind_of_entry() {
    load_settings
    local base="$SYS_ROOT_A/Variants" uid index state answer expected
    uid="$(id -u oldshared)"
    mkdir -p -- "$base"
    # Folders.
    mkdir -m 755 -- "$base/d-plain"
    mkdir -m 2775 -- "$base/d-good"; chgrp "$SYS_GROUP" -- "$base/d-good"
    setfacl -d -m u::rwx,g::rwx,o::r-x -- "$base/d-good"
    mkdir -m 2775 -- "$base/d-other-differs"; chgrp "$SYS_GROUP" -- "$base/d-other-differs"
    setfacl -d -m u::rwx,g::rwx,o::--- -- "$base/d-other-differs"
    mkdir -m 2775 -- "$base/d-mask"; chgrp "$SYS_GROUP" -- "$base/d-mask"
    setfacl -m u:alice:rwx,m::r-x -- "$base/d-mask"
    setfacl -d -m u::rwx,g::rwx,o::r-x -- "$base/d-mask"
    mkdir -m 775 -- "$base/d-no-setgid"; chgrp "$SYS_GROUP" -- "$base/d-no-setgid"
    setfacl -d -m u::rwx,g::rwx,o::r-x -- "$base/d-no-setgid"
    mkdir -m 2775 -- "$base/d-old-access"; chgrp "$SYS_GROUP" -- "$base/d-old-access"
    setfacl -m "u:$uid:rwx" -- "$base/d-old-access"
    setfacl -d -m u::rwx,g::rwx,o::r-x -- "$base/d-old-access"
    mkdir -m 2775 -- "$base/d-old-both"; chgrp "$SYS_GROUP" -- "$base/d-old-both"
    setfacl -m "u:$uid:rwx" -- "$base/d-old-both"
    setfacl -d -m "u::rwx,g::rwx,o::r-x,u:$uid:rwx" -- "$base/d-old-both"
    # Files.
    local name mode
    for name in 644 664 764 775 641 660 600; do
        printf 'x\n' >"$base/f-$name"
        chmod "$name" -- "$base/f-$name"
        chgrp "$SYS_GROUP" -- "$base/f-$name"
    done
    printf 'x\n' >"$base/f-other-group"; chmod 664 -- "$base/f-other-group"
    printf 'x\n' >"$base/f-masked"; chgrp "$SYS_GROUP" -- "$base/f-masked"
    setfacl -m u:alice:rw,g::rw,m::r -- "$base/f-masked"
    printf 'x\n' >"$base/f-group-entry-r"; chgrp "$SYS_GROUP" -- "$base/f-group-entry-r"
    setfacl -m u:alice:rw,g::r,m::rw -- "$base/f-group-entry-r"
    printf 'x\n' >"$base/f-old-rw"; chgrp "$SYS_GROUP" -- "$base/f-old-rw"
    setfacl -m "u:$uid:rw,g::rw" -- "$base/f-old-rw"
    printf 'x\n' >"$base/f-old-r"; chgrp "$SYS_GROUP" -- "$base/f-old-r"
    setfacl -m "u:$uid:r,g::rw" -- "$base/f-old-r"

    local -a paths=() kinds=() ids=()
    while IFS= read -r -d '' name; do
        paths+=("$name")
        if [[ -d "$name" ]]; then kinds+=(d); else kinds+=(f); fi
        ids+=("$(stat -c '%d:%i' -- "$name")")
    done < <(find "$base" -mindepth 1 -print0)
    IMPACT_SHARING_GID="$(getent group "$SYS_GROUP" | cut -d: -f3)"
    IMPACT__SHARING_TMP="$TEST_TMP"
    local checked=0 oks=0
    for state in '' present absent; do
        IMPACT_SHARING_STATE="$state"
        IMPACT_SHARING_UID=''
        local -a extra=()
        if [[ -n "$state" ]]; then
            IMPACT_SHARING_UID="$uid"
            extra=(oldshared "$state")
        fi
        impact__sharing_examine paths kinds ids '' || fail "the walk could not examine the variants"
        for index in "${!paths[@]}"; do
            answer="${IMPACT__SHARING_WHY[index]}"
            if [[ "${kinds[index]}" == 'd' ]]; then
                if impact_shared_dir_is_ok "${paths[index]}" "$SYS_GROUP" "${extra[@]}"; then expected=ok; else expected=deviates; fi
            else
                if impact_shared_file_is_ok "${paths[index]}" "$SYS_GROUP" "${extra[@]}"; then expected=ok; else expected=deviates; fi
            fi
            if [[ "$answer" == '-' ]]; then mode=ok; else mode=deviates; fi
            assert_eq "$expected" "$mode" "walk and library for ${paths[index]} (state '${state:-none}', walk said '$answer')"
            checked=$((checked + 1))
            if [[ "$mode" == 'ok' ]]; then oks=$((oks + 1)); fi
        done
    done
    # Both answers must occur often, or the comparison proves little.
    assert_eq 57 "$checked" "number of comparisons"
    ((oks >= 10 && checked - oks >= 10)) || fail "only $oks of $checked entries follow the rules; the variants are too one-sided"
    rm -rf -- "$base"
}

# Two accounts with umask 077 can change each others entries.
test_two_accounts_with_umask_077_can_change_each_others_entries() {
    local out="$T/outputs"
    as_person alice "printf 'a\n' >'$out/alice.txt' && mkdir '$out/alice-dir' && printf 'x\n' >'$out/alice-dir/inner.txt'" ||
        fail "alice cannot create entries"
    as_person bob "printf 'b\n' >>'$out/alice.txt' && printf 'z\n' >>'$out/alice-dir/inner.txt' && printf 'y\n' >'$out/alice-dir/bob.txt' && mkdir '$out/alice-dir/bob-sub'" ||
        fail "bob cannot change or add to alice's entries"
    as_person alice "printf 'c\n' >>'$out/alice-dir/bob.txt' && printf 'w\n' >'$out/alice-dir/bob-sub/f' && mv '$out/alice-dir/bob.txt' '$out/alice-dir/bob-renamed.txt'" ||
        fail "alice cannot change or add to bob's entries"
    as_person bob "rm '$out/alice-dir/bob-sub/f' && rmdir '$out/alice-dir/bob-sub'" ||
        fail "bob cannot remove an entry of alice inside his folder"
    assert_eq $'a\nb' "$(cat -- "$out/alice.txt")" "content of alice.txt"
    assert_eq $'y\nc' "$(cat -- "$out/alice-dir/bob-renamed.txt")" "content of bob's file"
    # New entries belong to the shared group; new folders carry setgid.
    assert_eq "alice $SYS_GROUP" "$(stat -c '%U %G' -- "$out/alice.txt")" "owner and group of alice.txt"
    assert_matches "$(stat -c '%a' -- "$out/alice-dir")" '^27[0-7][0-7]$' "mode of alice-dir"
    load_settings
    assert_eq '' "$(deviating_entries "$out")" "new entries that deviate"
}

# Repair finds entries moved in with old rights.
test_repair_finds_entries_moved_in_with_old_rights() {
    local out="$T/outputs"
    mkdir -p -- "$PRIVATE"
    chown alice:alice -- "$PRIVATE"
    chmod 700 -- "$PRIVATE"
    as_person alice "printf 'm\n' >'$PRIVATE/moved.txt' && mkdir '$PRIVATE/moved-dir' && printf 'n\n' >'$PRIVATE/moved-dir/inner.txt'" ||
        fail "alice cannot write her private folder"
    # A copy with "cp -p" keeps the rights of the source; a plain "cp" gives
    # the new file at most the group rights of the source as well (here
    # none: the source has mode 600), whatever the default ACL says.
    as_person alice "printf 'h\n' >\$HOME/home-file.txt && cp -p \$HOME/home-file.txt '$out/copied-with-rights.txt' && cp \$HOME/home-file.txt '$out/copied-plain.txt'" ||
        fail "alice cannot copy from home"
    # "mv" on the same disk keeps the old owner, group and mode.
    as_person alice "mv '$PRIVATE/moved.txt' '$out/' && mv '$PRIVATE/moved-dir' '$out/' && chmod g-w '$out/alice.txt'" ||
        fail "alice cannot move her entries in"
    if as_person bob "printf 'x\n' >>'$out/moved.txt'" 2>/dev/null; then
        fail "bob can write the moved file before the repair; the test proves nothing"
    fi
    if as_person bob "printf 'x\n' >>'$out/copied-plain.txt'" 2>/dev/null; then
        fail "bob can write the plain copy before the repair; the test proves nothing"
    fi
    snapshot_unchanged_by --content /mnt/disk_a /opt/impact -- sys_as_admin "$SHARE" "$T" --repair --dry-run
    assert_status 0
    assert_output_contains 'Folders that deviate from the rules: 1 (other group: 1; setgid missing: 1; group may not read, write or enter: 1; default ACL missing or different: 1).'
    assert_output_contains 'Files that deviate from the rules: 5'
    run_cmd sys_as_admin "$SHARE" "$T" --repair
    assert_status 0
    assert_output_contains 'Changed: 1 folder and 5 files.'
    as_person bob "printf 'x\n' >>'$out/moved.txt' && printf 'x\n' >>'$out/moved-dir/inner.txt' && printf 'x\n' >'$out/moved-dir/new.txt' && printf 'x\n' >>'$out/alice.txt' && printf 'x\n' >>'$out/copied-with-rights.txt' && printf 'x\n' >>'$out/copied-plain.txt'" ||
        fail "bob cannot change the repaired entries"
    load_settings
    assert_eq "$(printf '%q' "$T/hard-outside")" "$(deviating_entries "$T")" "entries that still deviate"
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log /mnt/disk_a /opt/impact -- sys_as_admin "$SHARE" "$T" --repair
    assert_status 0
    assert_output_contains 'Nothing to do'
}

# Transition account gets access and loses it again.
test_transition_account_gets_access_and_loses_it_again() {
    local out="$T/outputs" uid
    uid="$(id -u oldshared)"
    # The storage root belongs to root and the shared group (mode 2750): the
    # old account cannot even reach the folder. The command says so.
    run_cmd sys_as_admin "$SHARE" "$T" --transition-user oldshared --dry-run
    assert_status 0
    assert_output_contains "oldshared cannot enter $SYS_ROOT_A"
    # What the administrator does after reading the warning:
    setfacl -m u:oldshared:x -- "$SYS_ROOT_A"
    run_cmd sys_as_admin "$SHARE" "$T" --transition-user oldshared
    assert_status 0
    assert_output_not_contains 'oldshared cannot enter'
    as_person oldshared "printf 'o\n' >>'$out/alice.txt' && printf 'o\n' >'$out/alice-dir/from-old.txt' && mkdir '$out/alice-dir/old-sub'" ||
        fail "the transition account cannot write"
    # A file that alice creates now is writable for the old account too, and
    # the mask of the new file does not remove the group's write right.
    as_person alice "printf 'new\n' >'$out/alice-dir/after-transition.txt'" || fail "alice cannot write"
    as_person oldshared "printf 'o\n' >>'$out/alice-dir/after-transition.txt'" ||
        fail "the transition account cannot write a new file of alice"
    local acl
    # getfacl -E leaves out the "effective rights" remarks.
    acl="$(getfacl -c -n -E -- "$out/alice-dir/after-transition.txt")"
    assert_contains "$acl" "user:$uid:rw"
    assert_contains "$acl" 'group::rw'
    assert_contains "$acl" 'mask::rw-'
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log /mnt/disk_a /opt/impact -- \
        sys_as_admin "$SHARE" "$T" --transition-user oldshared
    assert_status 0
    assert_output_contains 'Nothing to do'

    run_cmd sys_as_admin "$SHARE" "$T" --remove-transition-user oldshared
    assert_status 0
    if as_person oldshared "printf 'o\n' >>'$out/alice.txt'" 2>/dev/null; then
        fail "the transition account can still write after --remove-transition-user"
    fi
    local left
    left="$(find "$T" -xdev -path "$T/mounted" -prune -o \( -type d -o -type f \) -print0 |
        xargs -0 getfacl -P -p -n -- 2>/dev/null | grep -c -- ":$uid:" || true)"
    assert_eq 0 "$left" "access entries of the transition account that are left"
    # Members still share everything.
    as_person bob "printf 'b\n' >>'$out/alice-dir/after-transition.txt'" || fail "bob cannot write"
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log /mnt/disk_a /opt/impact -- \
        sys_as_admin "$SHARE" "$T" --remove-transition-user oldshared
    assert_status 0
    assert_output_contains 'Nothing to do'
    setfacl -x u:oldshared -- "$SYS_ROOT_A"
}

# Restore names files whose special bits it leaves.
test_restore_names_files_whose_special_bits_it_leaves() {
    local base="$SYS_ROOT_A/Special" before folder
    mkdir -p -- "$base/d-sticky"
    printf '#!/bin/sh\n' >"$base/setuid-tool"
    # The owner first: a change of owner clears the setuid bit of an
    # executable file.
    chown -R oldshared:oldshared -- "$base"
    # 4755: an executable file with setuid; 1777: a folder with the sticky
    # bit (only the owner of an entry may delete it).
    chmod 4755 -- "$base/setuid-tool"
    chmod 1777 -- "$base/d-sticky"
    chmod 755 -- "$base"
    # New folders inherit setgid from the storage root, and a mode written
    # as a number keeps it on folders; "g-s" takes it away explicitly.
    chmod g-s -- "$base/d-sticky" "$base"
    before="$TEST_TMP/special-before.snapshot"
    snapshot_take "$before" --no-accounts "$base"
    run_cmd sys_as_admin "$SHARE" "$base"
    assert_status 0
    # Changing the group of an executable file clears its setuid bit (a
    # rule of Linux); the folder keeps its sticky bit and gets setgid.
    assert_file_facts "$base/setuid-tool" 775 oldshared "$SYS_GROUP"
    assert_file_facts "$base/d-sticky" 3777 oldshared "$SYS_GROUP"
    folder="$(backup_folders | tail -n 1)"
    run_cmd sys_as_admin "$SHARE" --restore "$folder" --dry-run
    assert_status 0
    assert_output_contains "setuid-tool: special bits now '---', saved 's--'"
    run_cmd sys_as_admin "$SHARE" --restore "$folder"
    assert_status 0
    assert_output_contains 'Files whose special bits (setuid, setgid, sticky) differ from the saved ones: 1.'
    assert_output_contains "After a look at the file: sudo chmod u+s,g-s,-t -- $base/setuid-tool"
    # The folder is back exactly, the file has its owner, group and rights
    # back, without the setuid bit.
    assert_file_facts "$base/d-sticky" 1777 oldshared oldshared
    assert_file_facts "$base/setuid-tool" 755 oldshared oldshared
    # The line the command printed completes the restore.
    chmod u+s,g-s,-t -- "$base/setuid-tool"
    snapshot_take "$TEST_TMP/special-after.snapshot" --no-accounts "$base"
    snapshot_assert_same "$before" "$TEST_TMP/special-after.snapshot" "the state after the restore and the printed chmod"
    rm -rf -- "$base"
}

# Restore of a folder works only on the saved folder.
test_restore_of_a_folder_works_only_on_the_saved_folder() {
    load_settings
    local base="$SYS_ROOT_A/Swap" ident key status
    mkdir -p -- "$base/real" "$base/other"
    chown oldshared:oldshared -- "$base/real" "$base/other"
    chmod 755 -- "$base/real" "$base/other"
    chmod g-s -- "$base/real" "$base/other"
    ident="$(stat -c '%d:%i' -- "$base/real")"
    key="d|0|0|-s-|user::rwx,group::rwx,other::---"
    # The saved folder was replaced by a link to another folder: refused,
    # and neither folder changes.
    mv -- "$base/real" "$base/real-moved"
    ln -s -- "$base/other" "$base/real"
    status=0
    impact__sharing_restore_dir "$key" "$base/real" "$ident" || status=$?
    assert_eq 3 "$status" "status for a folder that became a link"
    assert_file_facts "$base/other" 755 oldshared oldshared
    assert_file_facts "$base/real-moved" 755 oldshared oldshared
    # Another folder under the saved name (other inode): refused as well.
    rm -f -- "$base/real"
    mv -- "$base/other" "$base/real"
    status=0
    impact__sharing_restore_dir "$key" "$base/real" "$ident" || status=$?
    assert_eq 3 "$status" "status for another folder under the saved name"
    assert_file_facts "$base/real" 755 oldshared oldshared
    # The saved folder itself gets the saved state.
    rm -rf -- "$base/real"
    mv -- "$base/real-moved" "$base/real"
    impact__sharing_restore_dir "$key" "$base/real" "$ident" || fail "the saved folder could not be restored"
    assert_file_facts "$base/real" 2770 root root
    rm -rf -- "$base"
}
