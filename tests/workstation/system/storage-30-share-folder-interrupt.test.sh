#!/bin/bash
# =============================================================================
# storage-30-share-folder-interrupt.test.sh: an interrupted impact-share-folder
#
# Purpose
#   Stops real runs of impact-share-folder in the middle and proves:
#     - a run stopped with the signal TERM (as "systemctl stop" or a closed
#       terminal sends) ends with exit code 143, marks its backup as
#       interrupted and reports what it had changed;
#     - every entry that the run had changed is saved in its backup: the
#       backup is written before the change;
#     - a second stopped run names the backup of the first one in its
#       "How to undo", and a run stopped by force ("kill -9", which no
#       program can catch) leaves its backup behind as well;
#     - the same command, run again, finishes the work; afterwards every
#       entry follows the rules, its "How to undo" names all four backups,
#       newest first, and later runs no longer call the earlier ones
#       unfinished;
#     - following that "How to undo" line by line gives back the exact
#       state from before the first run; a second restore of the oldest
#       backup finds nothing to do;
#     - a run that finds nothing left to change after an unfinished run
#       still names the way back.
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
#   about 6000 entries below /mnt/disk_a/shared/Big and a few below
#   /mnt/disk_a/shared/Small.
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
FOLDERS=1200           # number of folders in the tree, each with four files

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

# start_and_stop_run SIGNAL OUTPUT_FILE
#   Starts impact-share-folder on the tree as root (what sudo does) in the
#   background, waits until its own backup folder holds two parts (two
#   groups of 500 entries were saved), and sends SIGNAL (TERM or KILL).
#   Waits until the command and the programs it started have ended. Sets
#   RUN_STATUS and RUN_OUTPUT like run_cmd, and STOPPED_BACKUP to the backup
#   folder of the stopped run.
start_and_stop_run() {
    local signal="$1" output="$2" pid status=0 waited=0 before_count folder
    before_count="$(backup_folders | wc -l)"
    "$SHARE" "$T" >"$output" 2>&1 &
    pid=$!
    folder=''
    until [[ -n "$folder" && -e "$folder/part-000002.facl.gz" ]]; do
        sleep 0.05
        waited=$((waited + 1))
        if ((waited > 1200)) || ! kill -0 "$pid" 2>/dev/null; then
            cat -- "$output" >&2
            fail "the run did not reach its second group of entries in time, or ended before it could be stopped"
        fi
        # The newest backup folder, once this run has made its own.
        if (($(backup_folders | wc -l) > before_count)); then
            folder="$(backup_folders | tail -n 1)"
        fi
    done
    kill "-$signal" "$pid"
    wait "$pid" || status=$?
    # After "kill -9" the programs that the command had started (find,
    # setfacl, gzip) may still finish their part; wait for them.
    waited=0
    while pgrep -f -- "$T" >/dev/null 2>&1 && ((waited < 200)); do
        sleep 0.05
        waited=$((waited + 1))
    done
    RUN_OUTPUT="$(cat -- "$output")"
    RUN_STATUS="$status"
    STOPPED_BACKUP="$folder"
}

# undo_lines OUTPUT
#   Prints the lines of the list "How to undo" (or "How to undo them") of an
#   output, without the mark "  - " in front.
undo_lines() {
    awk '/^How to undo/ { inside = 1; next } inside && /^  - / { sub(/^  - /, ""); print; next } inside { inside = 0 }' <<<"$1"
}

# An interrupted run saved every entry it changed.
test_an_interrupted_run_saved_every_entry_it_changed() {
    local folder
    start_and_stop_run TERM "$TEST_SUITE_TMP/first-run.out"
    assert_status 143
    assert_output_contains 'was interrupted (signal TERM)'
    assert_output_contains 'the run stopped early; previous rights saved in'
    assert_output_contains 'impact-share-folder --restore'
    folder="$STOPPED_BACKUP"
    printf '%s\n' "$folder" >"$TEST_SUITE_TMP/backup-1"
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

# The second stopped run continues the work of the first one. Its partial
# report names its own backup first and then the backup of the first run:
# both are needed to go back.
test_a_second_stopped_run_names_the_earlier_backup_in_its_undo() {
    local first second lines
    first="$(cat -- "$TEST_SUITE_TMP/backup-1")"
    start_and_stop_run TERM "$TEST_SUITE_TMP/second-run.out"
    assert_status 143
    second="$STOPPED_BACKUP"
    printf '%s\n' "$second" >"$TEST_SUITE_TMP/backup-2"
    assert_output_contains "An earlier run on this folder did not finish; its backup stays in $first"
    lines="$(undo_lines "$RUN_OUTPUT")"
    assert_eq "Put the previous rights back: sudo impact-share-folder --restore $second
Then put back the rights saved by an earlier run on this folder that did not finish: sudo impact-share-folder --restore $first
Or finish the work: run the same impact-share-folder command again." "$lines" "the lines of How to undo"
}

# "kill -9" ends the command at once: no handler runs, so the backup keeps
# the state "running". The next run counts it as unfinished as well.
test_a_run_killed_by_force_leaves_its_backup() {
    start_and_stop_run KILL "$TEST_SUITE_TMP/third-run.out"
    assert_status 137
    printf '%s\n' "$STOPPED_BACKUP" >"$TEST_SUITE_TMP/backup-3"
    assert_file_contains "$STOPPED_BACKUP/run.info" 'STATE=running'
}

# The same command finishes the work.
test_the_same_command_finishes_the_work() {
    local first second third fourth lines folder
    first="$(cat -- "$TEST_SUITE_TMP/backup-1")"
    second="$(cat -- "$TEST_SUITE_TMP/backup-2")"
    third="$(cat -- "$TEST_SUITE_TMP/backup-3")"
    run_cmd sys_as_admin "$SHARE" "$T"
    assert_status 0
    for folder in "$first" "$second" "$third"; do
        assert_output_contains "An earlier run on this folder did not finish; its backup stays in $folder"
    done
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
    assert_eq 4 "$(backup_folders | wc -l)" "number of backup folders"
    fourth="$(backup_folders | tail -n 1)"
    assert_file_contains "$fourth/run.info" 'STATE=finished'
    # Its "How to undo" names all four backups, newest first.
    lines="$(undo_lines "$RUN_OUTPUT")"
    assert_eq "Put the previous rights back: sudo impact-share-folder --restore $fourth
Then put back the rights saved by an earlier run on this folder that did not finish: sudo impact-share-folder --restore $third
Then put back the rights saved by an earlier run on this folder that did not finish: sudo impact-share-folder --restore $second
Then put back the rights saved by an earlier run on this folder that did not finish: sudo impact-share-folder --restore $first" "$lines" "the lines of How to undo"
    printf '%s\n' "$lines" >"$TEST_SUITE_TMP/undo-lines"
    # The earlier backups are marked as continued by this run.
    for folder in "$first" "$second" "$third"; do
        assert_file_contains "$folder/run.info" "CONTINUED_BY=$fourth"
    done
    # A later run finds nothing to do and no unfinished run any more.
    run_cmd sys_as_admin "$SHARE" "$T"
    assert_status 0
    assert_output_contains 'Nothing to do'
    assert_output_not_contains 'did not finish'
}

# The administrator follows the printed "How to undo" from top to bottom.
test_following_the_printed_undo_gives_back_the_first_state() {
    local newest oldest line command
    newest="$(backup_folders | tail -n 1)"
    oldest="$(backup_folders | head -n 1)"
    # The command warns when a newer backup of the same folder exists.
    run_cmd sys_as_admin "$SHARE" --restore "$oldest" --dry-run
    assert_status 0
    assert_output_contains "A newer backup of the same folder exists: $newest"
    while IFS= read -r line; do
        # The command is the text after "sudo " in the line.
        command="${line#*sudo }"
        [[ "$command" == impact-share-folder\ --restore\ * ]] || fail "unexpected undo line: $line"
        run_cmd sys_as_admin "$SHARE" --restore "${command#impact-share-folder --restore }"
        assert_status 0
    done <"$TEST_SUITE_TMP/undo-lines"
    state_of "$T" >"$TEST_TMP/restored.state"
    snapshot_assert_same "$TEST_SUITE_TMP/before.state" "$TEST_TMP/restored.state" "the state after following the undo lines differs from the first state"
    # The oldest backup holds the first state of every entry it saved, so a
    # second restore of it finds nothing to do. (A newer backup can hold a
    # state in between: "kill -9" may stop a run between the group, setgid
    # and ACL changes of one folder, and the next run saves that half-done
    # state. Restoring such a backup again, out of order, puts it back.)
    run_cmd sys_as_admin "$SHARE" --restore "$oldest"
    assert_status 0
    assert_output_contains 'Nothing to do'
}

# An unfinished run that had done all its work (stopped just before it
# could write "finished"): the next run changes nothing, still names the
# backup of that run as the way back, and marks it as continued.
test_nothing_left_to_change_still_names_the_earlier_backup() {
    local small="$SYS_ROOT_A/Small" folder
    mkdir -p -- "$small/sub"
    printf 'x\n' >"$small/sub/x.csv"
    chown -R oldshared:oldshared -- "$small"
    run_cmd sys_as_admin "$SHARE" "$small"
    assert_status 0
    folder="$(grep -lxF -- "TARGET=$small" /opt/impact/admin/acl-backups/*/run.info)"
    folder="${folder%/run.info}"
    # Make it look like a run that was killed before its last write.
    sed -i -e 's/^STATE=finished$/STATE=running/' -- "$folder/run.info"
    run_cmd sys_as_admin "$SHARE" "$small"
    assert_status 0
    assert_output_contains "An earlier run on this folder did not finish; its backup stays in $folder"
    assert_output_contains 'had already applied the rules to every entry'
    assert_output_contains "  sudo impact-share-folder --restore $folder"
    assert_output_contains 'Nothing to do'
    assert_file_contains "$folder/run.info" 'CONTINUED_BY=the run of '
    run_cmd sys_as_admin "$SHARE" "$small"
    assert_status 0
    assert_output_not_contains 'did not finish'
}
