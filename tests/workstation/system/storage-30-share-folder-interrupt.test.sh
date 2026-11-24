#!/bin/bash
# =============================================================================
# storage-30-share-folder-interrupt.test.sh: an interrupted impact-share-folder
#
# Purpose
#   Stops a real run of impact-share-folder in the middle (signal TERM, as
#   "systemctl stop" or a closed terminal sends) and proves:
#     - the run ends with exit code 143, marks its backup as interrupted and
#       reports what it had changed;
#     - every entry that the run had changed is saved in its backup: the
#       backup is written before the change;
#     - the same command, run again, finishes the work, and afterwards every
#       entry follows the rules;
#     - restoring the two backups, newest first, gives back the exact state
#       from before the first run; a second restore finds nothing to do.
#
# Who runs it
#   tests/workstation/run-tests.sh system   (root, disposable system only)
#
# Usage
#   sudo env IMPACT_TEST_DISPOSABLE=yes IMPACT_TEST_BACKING_DIR=/some/ext4/folder \
#       bash tests/workstation/run-tests.sh system --filter storage-30
#
# What it changes on the system
#   The installed commands and their settings, the test account oldshared,
#   about 3000 entries below /mnt/disk_a/shared/Big.
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
T="$SYS_ROOT_A/Big"
FOLDERS=600            # number of folders in the tree, each with four files

suite_setup() {
    sys_clean_slate
    sys_storage_up
    sys_install
    sys_admin_create
    sys_setup
    sys_account_add oldshared
    local index
    mkdir -p -- "$T"
    for ((index = 1; index <= FOLDERS; index++)); do
        mkdir -- "$T/d$index"
        printf 'a\n' >"$T/d$index/a.csv"
        printf 'b\n' >"$T/d$index/b.csv"
        printf 'c\n' >"$T/d$index/c with space.csv"
        printf '#!/bin/sh\n' >"$T/d$index/run.sh"
        chmod 755 -- "$T/d$index/run.sh"
    done
    chown -R oldshared:oldshared -- "$T"
    state_of "$T" >"$TEST_SUITE_TMP/before.state"
}

suite_teardown() {
    sys_clean_slate
}

# load_settings
#   Loads the library (with impact-sharing.sh) and the settings.
load_settings() {
    load_library
    # shellcheck source=../../../workstation/lib/impact-sharing.sh
    source "$WORKSTATION_DIR/lib/impact-sharing.sh"
    impact_conf_load || fail "the settings file cannot be read"
}

# state_of FOLDER
#   Prints one line per entry below FOLDER: owner, group, flags, the whole
#   ACL (which includes the rights of owner, group and others) and the path,
#   sorted. Symbolic links are not followed.
state_of() {
    load_settings
    getfacl -R -P -p -n -E -- "$1" 2>/dev/null | impact_sharing_normalize | cut -f4- | LC_ALL=C sort
}

# saved_paths BACKUP_FOLDER
#   Prints the paths saved in a backup folder, sorted.
saved_paths() {
    load_settings
    local part
    for part in "$1"/part-*.facl.gz; do
        gzip -dc -- "$part" | impact_sharing_normalize | cut -f8
    done | LC_ALL=C sort
}

# backup_folders
#   Prints the backup folders, oldest first.
backup_folders() {
    find /opt/impact/admin/acl-backups -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort
}

test_an_interrupted_run_saved_every_entry_it_changed() {
    local output="$TEST_SUITE_TMP/first-run.out" pid status=0 waited=0 folder
    # Run the command directly as root (what sudo does), in the background.
    "$SHARE" "$T" >"$output" 2>&1 &
    pid=$!
    # Wait until the second group of entries has been saved, then stop it.
    until compgen -G '/opt/impact/admin/acl-backups/*/part-000002.facl.gz' >/dev/null; do
        sleep 0.05
        waited=$((waited + 1))
        if ((waited > 1200)) || ! kill -0 "$pid" 2>/dev/null; then
            cat -- "$output" >&2
            fail "the run did not reach its second group of entries in time, or ended before it could be stopped"
        fi
    done
    kill -TERM "$pid"
    wait "$pid" || status=$?
    RUN_OUTPUT="$(cat -- "$output")"
    RUN_STATUS="$status"
    assert_status 143
    assert_output_contains 'was interrupted (signal TERM)'
    assert_output_contains 'the run stopped early; previous rights saved in'
    assert_output_contains 'impact-share-folder --restore'
    folder="$(backup_folders)"
    assert_file_contains "$folder/run.info" 'STATE=interrupted'
    assert_file_contains /opt/impact/admin/log/impact-admin.log 'result:  FAILED with exit code 143'

    # Every entry whose state differs now from the state before the run
    # must be saved in the backup.
    local changed
    state_of "$T" >"$TEST_TMP/now.state"
    changed="$(LC_ALL=C comm -13 "$TEST_SUITE_TMP/before.state" "$TEST_TMP/now.state" | awk -F '\t' '{ print $NF }' | LC_ALL=C sort)"
    [[ -n "$changed" ]] || fail "the run changed nothing before it was stopped; the test proves nothing"
    [[ "$(printf '%s\n' "$changed" | wc -l)" -lt "$((FOLDERS * 5 + 1))" ]] ||
        fail "the run changed every entry before it was stopped; the test proves nothing"
    saved_paths "$folder" >"$TEST_TMP/saved"
    local missing
    missing="$(printf '%s\n' "$changed" | LC_ALL=C comm -23 - "$TEST_TMP/saved")"
    assert_eq '' "$missing" "changed entries that are missing in the backup"
}

test_the_same_command_finishes_the_work() {
    run_cmd sys_as_admin "$SHARE" "$T"
    assert_status 0
    assert_output_contains 'An earlier run on this folder did not finish'
    load_settings
    local path left=''
    while IFS= read -r -d '' path; do
        if [[ -d "$path" ]]; then
            impact_shared_dir_is_ok "$path" "$SYS_GROUP" || left+="$path "
        else
            impact_shared_file_is_ok "$path" "$SYS_GROUP" || left+="$path "
        fi
    done < <(find "$T" -print0)
    assert_eq '' "$left" "entries that still deviate"
    assert_eq 2 "$(backup_folders | wc -l)" "number of backup folders"
    assert_file_contains "$(backup_folders | tail -n 1)/run.info" 'STATE=finished'
    run_cmd sys_as_admin "$SHARE" "$T"
    assert_status 0
    assert_output_contains 'Nothing to do'
}

test_restoring_both_backups_gives_back_the_first_state() {
    local newest oldest
    newest="$(backup_folders | tail -n 1)"
    oldest="$(backup_folders | head -n 1)"
    # The command warns when a newer backup of the same folder exists.
    run_cmd sys_as_admin "$SHARE" --restore "$oldest" --dry-run
    assert_status 0
    assert_output_contains "A newer backup of the same folder exists: $newest"
    # Newest first: the second run saved entries in the state that the
    # stopped run had left them in.
    run_cmd sys_as_admin "$SHARE" --restore "$newest"
    assert_status 0
    run_cmd sys_as_admin "$SHARE" --restore "$oldest"
    assert_status 0
    state_of "$T" >"$TEST_TMP/restored.state"
    snapshot_assert_same "$TEST_SUITE_TMP/before.state" "$TEST_TMP/restored.state" "the state after both restores differs from the first state"
    for folder in "$newest" "$oldest"; do
        run_cmd sys_as_admin "$SHARE" --restore "$folder"
        assert_status 0
        assert_output_contains 'Nothing to do'
    done
}
