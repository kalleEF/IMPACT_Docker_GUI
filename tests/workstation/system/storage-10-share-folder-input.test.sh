#!/bin/bash
# =============================================================================
# storage-10-share-folder-input.test.sh: what impact-share-folder refuses
#
# Purpose
#   Proves that impact-share-folder refuses wrong and hostile input before
#   it changes anything: missing or extra arguments, relative paths, the
#   storage root itself, folders outside the storage roots, system and home
#   folders, mount points, symbolic links that lead out of a storage root
#   (to a home folder, to /etc, into the other storage root), "..", names
#   with blanks, quotes, ";" and "$(...)", wrong option combinations, bad
#   transition accounts, bad backup folders, a run without root rights, a
#   second run while one is busy, and a machine without settings.
#   For each refusal it checks the exit code, the message, and that the
#   state of the system (accounts, groups, storage, /opt/impact, /etc/impact)
#   did not change. It also proves that a path that enters a storage root
#   through a symbolic link from outside is accepted and shown resolved.
#
# Who runs it
#   tests/workstation/run-tests.sh system   (root, disposable system only)
#
# Usage
#   sudo env IMPACT_TEST_DISPOSABLE=yes IMPACT_TEST_BACKING_DIR=/some/ext4/folder \
#       bash tests/workstation/run-tests.sh system --filter storage-10
#
# What it changes on the system
#   The installed commands and their settings, the test accounts alice and
#   oldshared, a bind mount and some links below /mnt, the storage roots.
#
# How to undo
#   The file removes everything it created (suite_teardown).
# =============================================================================

# Reading help: the bash constructs used here are explained at the top of
# ../lib/testlib.sh ("Reading help") and where they are first used.

# The lines for the checking tool "shellcheck" stand before the first command
# of the file and therefore count for the whole file.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/testlib.sh"

SHARE=/usr/local/bin/impact-share-folder
T="$SYS_ROOT_A/Example"
OUTER_LINK=/mnt/link-to-example
HOSTILE_MARK=/tmp/impact-test-hostile-mark

suite_setup() {
    sys_clean_slate
    sys_storage_up
    sys_install
    sys_admin_create
    sys_setup
    sys_account_add alice "$SYS_GROUP"
    sys_account_add oldshared
    mkdir -p -- "$T/outputs" "$SYS_ROOT_B/Other" /mnt/disk_a/not-shared /mnt/disk_a/elsewhere \
        "$SYS_ROOT_A/mp" "$SYS_ROOT_A/with space"
    ln -s -- /home/alice "$SYS_ROOT_A/to-home"
    ln -s -- /etc "$SYS_ROOT_A/to-etc"
    ln -s -- "$SYS_ROOT_B/Other" "$SYS_ROOT_A/to-other-root"
    ln -s -- "$T" "$SYS_ROOT_A/to-inside"
    ln -s -- "$T" "$OUTER_LINK"
    mount --bind -- /mnt/disk_a/elsewhere "$SYS_ROOT_A/mp"
    rm -f -- "$HOSTILE_MARK"
}

suite_teardown() {
    umount -- "$SYS_ROOT_A/mp" 2>/dev/null || true
    rm -f -- "$OUTER_LINK" "$HOSTILE_MARK"
    sys_clean_slate
}

# refused CODE TEXT ARGUMENTS...
#   Runs impact-share-folder as the administrator with ARGUMENTS and checks:
#   exit code CODE, TEXT in the output, and no change of the system.
refused() {
    local code="$1" text="$2"
    shift 2
    snapshot_unchanged_by --content /mnt/disk_a /mnt/disk_b /opt/impact /etc/impact -- \
        sys_as_admin "$SHARE" "$@"
    assert_status "$code"
    assert_output_contains "$text"
    assert_missing "$HOSTILE_MARK"
}

# Wrong number of arguments is refused.
test_wrong_number_of_arguments_is_refused() {
    refused 2 'An argument is missing'
    refused 2 'Too many arguments' "$T" "$SYS_ROOT_B/Other"
}

# Unknown and short options are refused.
test_unknown_and_short_options_are_refused() {
    refused 2 "Unknown option '--force'" "$T" --force
    refused 2 'start with two dashes' "$T" -r
}

# Paths outside the storage roots are refused.
test_paths_outside_the_storage_roots_are_refused() {
    refused 2 'is no absolute path' shared/Example
    refused 2 'does not exist' "$SYS_ROOT_A/Missing"
    refused 2 "$SYS_ROOT_A is a storage root. Give the folder of one model inside it" "$SYS_ROOT_A"
    refused 2 "$SYS_ROOT_A is a storage root. Give the folder of one model inside it" "$SYS_ROOT_A/"
    refused 2 'lies inside none of the storage roots' /mnt/disk_a/not-shared
    refused 2 'lies inside none of the storage roots' /mnt/disk_a
    refused 2 'is a system folder' /etc
    refused 2 'is a system folder' /tmp
    refused 2 'is the top folder of the whole system' /
    refused 2 'is the top folder of the whole system' /mnt/disk_a/..//..
    refused 2 'is a home folder' /home/alice
}

# A mount point inside a root is refused.
test_a_mount_point_inside_a_root_is_refused() {
    refused 2 'is the top folder of a file system' "$SYS_ROOT_A/mp"
}

# Links and dots that lead out of a root are refused.
test_links_and_dots_that_lead_out_of_a_root_are_refused() {
    refused 2 'a symbolic link (or' "$SYS_ROOT_A/to-home"
    refused 2 'leads out of it, to /home/alice' "$SYS_ROOT_A/to-home"
    refused 2 'leads out of it, to /etc' "$SYS_ROOT_A/to-etc"
    refused 2 "leads out of it, to $SYS_ROOT_B/Other" "$SYS_ROOT_A/to-other-root"
    refused 2 'leads out of it, to /mnt/disk_a/not-shared' "$SYS_ROOT_A/../not-shared"
}

# Hostile names are refused.
test_hostile_names_are_refused() {
    refused 2 'contains characters other than' "$SYS_ROOT_A/with space"
    refused 2 'does not exist' "$T; touch $HOSTILE_MARK"
    # shellcheck disable=SC2016
    # Reason for SC2016 (no expansion in single quotes): the text "$(...)"
    # must reach the command unexpanded; that is the attack.
    refused 2 'does not exist' "$T"'$(touch /tmp/impact-test-hostile-mark)'
    refused 2 'does not exist' "$T\"'"
    refused 2 'control character' "$T"$'\n'"$SYS_ROOT_B/Other"
    refused 2 'no valid account name' "$T" --transition-user 'alice; touch /tmp/impact-test-hostile-mark'
}

# Wrong option combinations are refused.
test_wrong_option_combinations_are_refused() {
    refused 2 '--repair cannot be combined with a transition option' "$T" --repair --transition-user oldshared
    refused 2 'not both' "$T" --transition-user oldshared --remove-transition-user oldshared
    refused 2 '--restore cannot be combined with --repair' --restore x --repair
    refused 2 'Too many arguments' --restore x "$T"
}

# Bad transition accounts are refused.
test_bad_transition_accounts_are_refused() {
    refused 2 'no valid account name' "$T" --transition-user 'Old Shared'
    refused 2 "The account 'nosuchaccount' does not exist" "$T" --transition-user nosuchaccount
    refused 2 'is a system account' "$T" --transition-user daemon
    refused 2 'is a system account' "$T" --remove-transition-user root
}

# Bad backup folders are refused.
test_bad_backup_folders_are_refused() {
    refused 2 'is no backup folder of this command' --restore ../../etc
    refused 2 'is no backup folder of this command' --restore /etc
    refused 2 'is no backup folder of this command' --restore /opt/impact/admin/acl-backups/../log
    refused 2 'does not exist' --restore 20261124T201500Z_mnt_disk_a_shared_Example
    # A folder of the right name whose run.info anyone may change.
    local folder=/opt/impact/admin/acl-backups/20261124T201500Z_mnt_disk_a_shared_Example
    mkdir -m 700 -- "$folder"
    printf 'BACKUP_FORMAT=1\nKIND=share-folder\nTARGET=%s\nGROUP_NUMBER=1\nSTATE=finished\n' "$T" >"$folder/run.info"
    chmod 666 -- "$folder/run.info"
    refused 1 'can be changed by accounts other than root' --restore "$folder"
    # A safe run.info that names a folder outside the storage roots.
    chmod 600 -- "$folder/run.info"
    printf 'BACKUP_FORMAT=1\nKIND=share-folder\nTARGET=/etc\nGROUP_NUMBER=1\nSTATE=finished\n' >"$folder/run.info"
    refused 2 'is a system folder' --restore "$folder"
    # The backup folder itself replaced by a link.
    rm -rf -- "$folder"
    ln -s -- /etc "$folder"
    refused 2 'does not exist (or is a symbolic link)' --restore "$folder"
    rm -f -- "$folder"
}

# A run without root rights is refused.
test_a_run_without_root_rights_is_refused() {
    snapshot_unchanged_by --content /mnt/disk_a /opt/impact /etc/impact -- \
        runuser -u "$SYS_ADMIN" -- "$SHARE" "$T"
    assert_status 2
    assert_output_contains 'must run with administrator rights'
}

# Help works for everyone.
test_help_works_for_everyone() {
    run_cmd runuser -u alice -- "$SHARE" --help
    assert_status 0
    assert_output_contains 'systemd-run --unit=impact-share-folder'
    assert_output_contains 'How to undo'
}

# A path that enters a root through a link is accepted.
test_a_path_that_enters_a_root_through_a_link_is_accepted() {
    snapshot_unchanged_by --content /mnt/disk_a /opt/impact /etc/impact -- \
        sys_as_admin "$SHARE" "$OUTER_LINK" --dry-run
    assert_status 0
    assert_output_contains "OK: Folder: $T (inside the storage root $SYS_ROOT_A"
    assert_output_contains "The path you gave, $OUTER_LINK, leads there through a symbolic link."
    snapshot_unchanged_by --content /mnt/disk_a /opt/impact /etc/impact -- \
        sys_as_admin "$SHARE" "$SYS_ROOT_A/to-inside/" --dry-run
    assert_status 0
    assert_output_contains "OK: Folder: $T (inside"
}

# A second run while one is busy is refused.
test_a_second_run_while_one_is_busy_is_refused() {
    mkdir -p /run/impact
    # A process in the background holds the lock of impact-share-folder, as
    # a running walk would: "( ... ) &" starts a copy of the shell, which
    # opens the lock file as handle 9, takes the lock, and then becomes
    # "sleep" ("exec"), so that stopping that one process frees the lock.
    (exec 9>>/run/impact/share-folder.lock && flock 9 && exec sleep 60) &
    local holder=$!
    sleep 1
    refused 4 'Another IMPACT command that changes the same things is running' "$T"
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
}

# A machine without settings is refused.
test_a_machine_without_settings_is_refused() {
    mv -- /etc/impact/impact.conf "$TEST_TMP/impact.conf"
    run_cmd sys_as_admin "$SHARE" "$T"
    mv -- "$TEST_TMP/impact.conf" /etc/impact/impact.conf
    assert_status 3
}
