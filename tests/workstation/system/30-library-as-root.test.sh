#!/bin/bash
# =============================================================================
# 30-library-as-root.test.sh: tests for the library functions that need root
#
# Purpose
#   Calls the shared functions directly, as root, on a prepared workstation
#   (installed and set up). It proves: files in a home folder are written as
#   the person and a symbolic link is never followed; the repository folder
#   is created safely; the shared-folder rules are applied to one folder or
#   to given files only, give two members write access whatever their umask,
#   keep non-members out, and can add and remove the access entry of a
#   transition account; the storage safety check; the account questions that
#   need root; the model file; and the log.
#
# Who runs it
#   tests/workstation/run-tests.sh system   (root, disposable system only)
#
# Usage
#   sudo env IMPACT_TEST_DISPOSABLE=yes bash tests/workstation/run-tests.sh system --filter 30-library
#
# What it changes on the system
#   The installed commands and their settings, four test accounts, folders
#   below the storage roots /mnt/disk_a/shared and /mnt/disk_b/shared, and
#   /srv/impact-test.
#
# How to undo
#   The file removes everything it created (suite_teardown).
# =============================================================================

# Reading help: the bash constructs used here are explained at the top of
# ../lib/testlib.sh ("Reading help") and where they are first used.

# The lines for the checking tool "shellcheck" stand before the first command
# of the file and therefore count for the whole file.
# shellcheck disable=SC2016
# Reason for SC2016 (no expansion in single quotes): many texts in this file
# are test data, or lines of small scripts that a test writes. They must stay
# exactly as written.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/testlib.sh"

# alice and bob are members of the shared group, carol is a colleague outside
# it, and "oldshared" stands for the account that everybody used before.
LOG_FILE=/opt/impact/admin/log/impact-admin.log

suite_setup() {
    sys_clean_slate
    sys_storage_up
    sys_install
    sys_admin_create
    sys_setup
    sys_account_add alice "$SYS_GROUP"
    sys_account_add bob "$SYS_GROUP"
    sys_account_add carol
    sys_account_add oldshared
}

suite_teardown() {
    if mountpoint -q "$SYS_ROOT_A/mounted" 2>/dev/null; then
        umount "$SYS_ROOT_A/mounted"
    fi
    rm -rf /srv/impact-test
    sys_clean_slate
}

# setup runs before every test: load the library and the settings.
setup() {
    load_library
    assert_success impact_conf_load
}

# as_user ACCOUNT SCRIPT
#   Runs a line of shell as ACCOUNT with a strict umask (new files private
#   by default), the hardest case for shared folders.
as_user() {
    # "cd /" first: the folder the test runs in may be closed to the account.
    (cd / && runuser -u "$1" -- bash -c "umask 077; $2")
}

# facts PATH
#   Prints "owner:group mode" of PATH.
facts() {
    stat -c '%U:%G %a' -- "$1"
}

# ----------------------------------------------------------------------------
# Files in a person's home folder
# ----------------------------------------------------------------------------

# Run as uses the rights and a clean environment.
test_run_as_uses_the_rights_and_a_clean_environment() {
    assert_eq 'alice' "$(impact_run_as alice id -un)"
    assert_contains "$(impact_run_as alice id -nG)" "$SYS_GROUP"
    local environment
    environment="$(SECRET_OF_ROOT=1 impact_run_as alice env)"
    assert_contains "$environment" 'HOME=/home/alice'
    assert_contains "$environment" 'USER=alice'
    assert_contains "$environment" "PATH=$IMPACT_SAFE_PATH"
    assert_not_contains "$environment" 'SECRET_OF_ROOT'
    assert_not_contains "$environment" 'SUDO_'
    assert_eq '/' "$(impact_run_as alice pwd)"
    # Standard input is passed through, and the exit code comes back.
    assert_eq 'text' "$(printf 'text\n' | impact_run_as alice cat)"
    local status=0
    impact_run_as alice sh -c 'exit 7' || status=$?
    assert_eq 7 "$status"
    run_cmd impact_run_as no-such-account-xyz true
    assert_status 1
}

# User mkdir and write and read.
test_user_mkdir_and_write_and_read() {
    assert_success impact_user_mkdir alice /home/alice/.ssh 700
    assert_eq 'alice:alice 700' "$(facts /home/alice/.ssh)"
    printf 'first line\n' | impact_user_write_file alice /home/alice/.ssh/authorized_keys 600
    assert_eq 'alice:alice 600' "$(facts /home/alice/.ssh/authorized_keys)"
    assert_eq 'first line' "$(impact_user_read_file alice /home/alice/.ssh/authorized_keys)"
    # A second write replaces the file in one step and leaves nothing behind.
    printf 'second line\n' | impact_user_write_file alice /home/alice/.ssh/authorized_keys 600
    assert_eq 'second line' "$(cat /home/alice/.ssh/authorized_keys)"
    assert_eq 'authorized_keys' "$(ls -A /home/alice/.ssh)"
    assert_success impact_user_file_exists alice /home/alice/.ssh/authorized_keys
    local status=0
    impact_user_file_exists alice /home/alice/.ssh/missing || status=$?
    assert_eq 4 "$status" "exit code for a file that does not exist"
    status=0
    impact_user_read_file alice /home/alice/no-folder/file >/dev/null || status=$?
    assert_eq 4 "$status"
    # An existing folder is accepted as it is; nested folders are created.
    assert_success impact_user_mkdir alice /home/alice/.ssh 700
    assert_success impact_user_mkdir alice /home/alice/a/b/c 750
    assert_eq 'alice:alice 750' "$(facts /home/alice/a/b/c)"
    assert_eq 'alice:alice 750' "$(facts /home/alice/a)"
}

# User files never follow symbolic links.
test_user_files_never_follow_symbolic_links() {
    local status
    impact_user_mkdir alice /home/alice/.ssh 700
    # The file itself is a link to a file of root.
    printf 'secret of root\n' >/root/impact-test-target
    as_user alice 'ln -s /root/impact-test-target /home/alice/.ssh/linked_file'
    status=0
    printf 'hostile\n' | impact_user_write_file alice /home/alice/.ssh/linked_file 600 2>"$TEST_TMP/error" || status=$?
    assert_eq 3 "$status" "write through a linked file"
    assert_file_contains "$TEST_TMP/error" 'is a symbolic link'
    assert_eq 'secret of root' "$(cat /root/impact-test-target)"
    status=0
    impact_user_read_file alice /home/alice/.ssh/linked_file >"$TEST_TMP/read" 2>/dev/null || status=$?
    assert_eq 3 "$status" "read through a linked file"
    assert_eq '' "$(cat "$TEST_TMP/read")"
    # A folder on the way is a link to a system folder.
    as_user alice 'ln -s /etc /home/alice/linked_folder'
    status=0
    printf 'hostile\n' | impact_user_write_file alice /home/alice/linked_folder/impact-test-file 644 2>/dev/null || status=$?
    assert_eq 3 "$status" "write below a linked folder"
    assert_missing /etc/impact-test-file
    status=0
    impact_user_mkdir alice /home/alice/linked_folder/impact-test-dir 755 2>/dev/null || status=$?
    assert_eq 3 "$status" "mkdir below a linked folder"
    assert_missing /etc/impact-test-dir
    status=0
    impact_user_mkdir alice /home/alice/linked_folder 755 2>/dev/null || status=$?
    assert_eq 3 "$status" "mkdir where a link stands"
    # Removing a link removes the link, never its target.
    assert_success impact_user_remove_file alice /home/alice/.ssh/linked_file
    assert_missing /home/alice/.ssh/linked_file
    assert_eq 'secret of root' "$(cat /root/impact-test-target)"
    rm -f /root/impact-test-target /home/alice/linked_folder
}

# User files refuse foreign owners and paths outside home.
test_user_files_refuse_foreign_owners_and_paths_outside_home() {
    local status
    # A folder inside the home folder that belongs to root.
    mkdir /home/alice/owned-by-root
    status=0
    printf 'x\n' | impact_user_write_file alice /home/alice/owned-by-root/file 644 2>/dev/null || status=$?
    assert_eq 3 "$status"
    assert_missing /home/alice/owned-by-root/file
    rmdir /home/alice/owned-by-root
    # Paths that are not inside the home folder of the account.
    local path
    for path in /etc/passwd /home/bob/file /home/alice /home/alice/../bob/file '/home/alice/a b' /home/alicefile \
        'relative/file' '' '/home/alice/x;id'; do
        run_cmd_with_input 'x' impact_user_write_file alice "$path" 644
        assert_status 1
        assert_output_contains 'is no clean path inside the home folder'
    done
    run_cmd_with_input 'x' impact_user_write_file alice /home/alice/file '7777x'
    assert_status 1
    run_cmd_with_input 'x' impact_user_write_file no-such-account-xyz /home/alice/file 644
    assert_status 1
    # The person cannot use the helper to write where the person has no rights.
    assert_missing /home/bob/file
}

# impact_user_remove_file removes a file as the person, counts a missing file
# as done, and refuses paths outside the home folder.
test_user_remove_file() {
    printf 'x\n' | impact_user_write_file alice /home/alice/to-remove 600
    assert_exists /home/alice/to-remove
    assert_success impact_user_remove_file alice /home/alice/to-remove
    assert_missing /home/alice/to-remove
    # Removing what is not there counts as done.
    assert_success impact_user_remove_file alice /home/alice/to-remove
    assert_success impact_user_remove_file alice /home/alice/no-folder/file
    local status=0
    impact_user_remove_file alice /home/alice/a 2>/dev/null || status=$?
    assert_eq 3 "$status" "a folder is not removed"
}

# Locked and expired accounts.
test_locked_and_expired_accounts() {
    assert_eq 'L' "$(impact_account_password_state alice)"
    assert_eq 'P' "$(impact_account_password_state "$SYS_ADMIN")"
    assert_fails impact_account_is_expired alice
    # The way impact-remove-user closes an account: an expiry date in the past.
    usermod --expiredate 1 bob
    assert_success impact_account_is_expired bob
    # Work as that person is still possible for root (needed to clean up).
    assert_eq 'bob' "$(impact_run_as bob id -un)"
    printf 'x\n' | impact_user_write_file bob /home/bob/after-expiry 600
    assert_exists /home/bob/after-expiry
    usermod --expiredate '' bob
    assert_fails impact_account_is_expired bob
    rm -f /home/bob/after-expiry
}

# The questions about groups and accounts give the members, the memberships
# and the numbers in use.
test_group_questions() {
    assert_eq $'alice\nbob' "$(impact_group_members "$SYS_GROUP")"
    assert_success impact_account_in_group alice "$SYS_GROUP"
    assert_fails impact_account_in_group carol "$SYS_GROUP"
    assert_fails impact_account_in_group "$SYS_ADMIN" "$SYS_GROUP"
    assert_fails impact_name_is_free alice
    assert_fails impact_name_is_free "$SYS_GROUP"
    assert_fails impact_uid_is_free "$(id -u alice)"
    assert_eq 'alice' "$(impact_account_by_uid "$(id -u alice)")"
    assert_eq '/bin/bash' "$(impact_account_shell alice)"
}

# ----------------------------------------------------------------------------
# The repository folder
# ----------------------------------------------------------------------------

# Repo base inside the home folder.
test_repo_base_inside_the_home_folder() {
    assert_eq '/home/alice/Repositories' "$(impact_repo_base_for alice)"
    assert_fails impact_repo_base_is_ready alice
    assert_success impact_repo_base_create alice
    assert_success impact_repo_base_is_ready alice
    assert_eq 'alice:alice 750' "$(facts /home/alice/Repositories)"
    assert_success impact_repo_base_create alice
    # A link at that place is refused.
    as_user bob 'ln -s /etc /home/bob/Repositories'
    run_cmd impact_repo_base_create bob
    assert_status 3
    assert_fails impact_repo_base_is_ready bob
    rm -f /home/bob/Repositories
}

# Repo base outside the home folder.
test_repo_base_outside_the_home_folder() {
    IMPACT_CONF[REPO_BASE]='/srv/impact-test/repos/%u'
    assert_eq '/srv/impact-test/repos/alice' "$(impact_repo_base_for alice)"
    run_cmd impact_repo_base_create alice
    assert_status 1
    assert_output_contains 'does not exist as a real folder'
    mkdir -p /srv/impact-test/repos
    chmod 777 /srv/impact-test/repos
    run_cmd impact_repo_base_create alice
    assert_status 1
    assert_output_contains 'must belong to root and be writable by root only'
    chmod 755 /srv/impact-test/repos
    assert_success impact_repo_base_create alice
    assert_eq 'alice:alice 750' "$(facts /srv/impact-test/repos/alice)"
    assert_success impact_repo_base_is_ready alice
    assert_success impact_repo_base_create alice
    # A folder of another account at that place is refused.
    mkdir /srv/impact-test/repos/bob
    run_cmd impact_repo_base_create bob
    assert_status 1
    assert_output_contains "does not belong to 'bob'"
}

# ----------------------------------------------------------------------------
# The shared rules for one folder
# ----------------------------------------------------------------------------

# Apply dir sets group setgid and acl on the folder only.
test_apply_dir_sets_group_setgid_and_acl_on_the_folder_only() {
    local folder="$SYS_ROOT_A/Example/outputs"
    mkdir -p "$folder/existing/deeper"
    printf 'old result\n' >"$folder/existing/file.csv"
    # Existing content as on a machine in use: it belongs to the old shared
    # account, and only the owner may write.
    chown -R oldshared:oldshared "$SYS_ROOT_A/Example"
    find "$SYS_ROOT_A/Example" -type d -exec chmod u=rwx,go=rx,g-s {} +
    snapshot_take "$TEST_TMP/content-before" --content "$folder/existing"
    local above_before
    above_before="$(facts "$SYS_ROOT_A/Example")"
    assert_fails impact_shared_dir_is_ok "$folder" "$SYS_GROUP"
    assert_success impact_shared_apply_dir "$folder" "$SYS_GROUP"
    assert_eq 1 "$IMPACT_SHARED_CHANGED"
    assert_eq "oldshared:$SYS_GROUP 2775" "$(facts "$folder")" "the owner stays, the group changes"
    local acl
    acl="$(getfacl -c -p -E "$folder")"
    assert_contains "$acl" 'group::rwx'
    assert_contains "$acl" 'default:user::rwx'
    assert_contains "$acl" 'default:group::rwx'
    assert_contains "$acl" 'default:other::r-x'
    assert_success impact_shared_dir_is_ok "$folder" "$SYS_GROUP"
    # The content of the folder was not touched: no walk through subfolders.
    snapshot_take "$TEST_TMP/content-after" --content "$folder/existing"
    snapshot_assert_same "$TEST_TMP/content-before" "$TEST_TMP/content-after" "the content of the folder was touched"
    assert_eq 'oldshared:oldshared 755' "$(facts "$folder/existing")"
    # The folder above it was not touched either.
    assert_eq "$above_before" "$(facts "$SYS_ROOT_A/Example")"
}

# Apply dir a second time changes nothing.
test_apply_dir_a_second_time_changes_nothing() {
    local folder="$SYS_ROOT_A/Example/outputs"
    snapshot_take "$TEST_TMP/before" --content "$SYS_ROOT_A"
    assert_success impact_shared_apply_dir "$folder" "$SYS_GROUP"
    assert_eq 0 "$IMPACT_SHARED_CHANGED"
    snapshot_take "$TEST_TMP/after" --content "$SYS_ROOT_A"
    snapshot_assert_same "$TEST_TMP/before" "$TEST_TMP/after"
}

# Apply dir repairs single deviations.
test_apply_dir_repairs_single_deviations() {
    local folder="$SYS_ROOT_A/Example/outputs"
    chmod g-s "$folder"
    assert_fails impact_shared_dir_is_ok "$folder" "$SYS_GROUP"
    assert_success impact_shared_apply_dir "$folder" "$SYS_GROUP"
    assert_success impact_shared_dir_is_ok "$folder" "$SYS_GROUP"
    chgrp root "$folder"
    assert_fails impact_shared_dir_is_ok "$folder" "$SYS_GROUP"
    assert_success impact_shared_apply_dir "$folder" "$SYS_GROUP"
    chmod g-w "$folder"
    assert_fails impact_shared_dir_is_ok "$folder" "$SYS_GROUP"
    assert_success impact_shared_apply_dir "$folder" "$SYS_GROUP"
    # setfacl -k removes the default ACL.
    setfacl -k "$folder"
    assert_fails impact_shared_dir_is_ok "$folder" "$SYS_GROUP"
    assert_success impact_shared_apply_dir "$folder" "$SYS_GROUP"
    assert_success impact_shared_dir_is_ok "$folder" "$SYS_GROUP"
    assert_eq "oldshared:$SYS_GROUP 2775" "$(facts "$folder")"
}

# Rights of others stay as they are.
test_rights_of_others_stay_as_they_are() {
    local folder="$SYS_ROOT_A/Example/private"
    mkdir "$folder"
    chown root:root "$folder"
    chmod u=rwx,go=,g-s "$folder"
    assert_success impact_shared_apply_dir "$folder" "$SYS_GROUP"
    assert_eq "root:$SYS_GROUP 2770" "$(facts "$folder")"
    assert_contains "$(getfacl -c -p -E "$folder")" 'default:other::---'
    as_user alice "echo data >'$folder/by-alice'"
    assert_eq "alice:$SYS_GROUP 660" "$(facts "$folder/by-alice")"
}

# Two members write whatever their umask.
test_two_members_write_whatever_their_umask() {
    local folder="$SYS_ROOT_A/Example/outputs"
    # The members must be able to reach the folder.
    chmod 755 "$SYS_ROOT_A" "$SYS_ROOT_A/Example"
    as_user alice "mkdir '$folder/analysis' && echo one >'$folder/analysis/results.csv'"
    assert_eq "alice:$SYS_GROUP 2775" "$(facts "$folder/analysis")"
    assert_eq "alice:$SYS_GROUP 664" "$(facts "$folder/analysis/results.csv")"
    # bob adds to alice's file and creates a file and a folder next to it.
    as_user bob "echo two >>'$folder/analysis/results.csv' && echo x >'$folder/analysis/by-bob' && mkdir '$folder/analysis/sub'"
    assert_eq $'one\ntwo' "$(cat "$folder/analysis/results.csv")"
    assert_eq "bob:$SYS_GROUP 664" "$(facts "$folder/analysis/by-bob")"
    assert_eq "bob:$SYS_GROUP 2775" "$(facts "$folder/analysis/sub")"
    # The new folders follow the rules by inheritance, without another call.
    assert_success impact_shared_dir_is_ok "$folder/analysis" "$SYS_GROUP"
    assert_success impact_shared_dir_is_ok "$folder/analysis/sub" "$SYS_GROUP"
    assert_success impact_shared_file_is_ok "$folder/analysis/results.csv" "$SYS_GROUP"
    # alice can change and remove what bob made.
    as_user alice "echo y >>'$folder/analysis/by-bob' && rmdir '$folder/analysis/sub'"
    # A colleague outside the group can read here (others: r-x) and cannot write.
    run_cmd as_user carol "echo z >>'$folder/analysis/results.csv'"
    assert_status 1
    run_cmd as_user carol "touch '$folder/by-carol'"
    assert_status 1
    assert_missing "$folder/by-carol"
}

# Moved in file keeps its rights until repaired.
test_moved_in_file_keeps_its_rights_until_repaired() {
    local folder="$SYS_ROOT_A/Example/outputs"
    # The known limit: a file that is moved in keeps its old rights.
    as_user alice "echo private >/home/alice/moved.csv && mv /home/alice/moved.csv '$folder/moved.csv'"
    assert_eq 'alice:alice 600' "$(facts "$folder/moved.csv")"
    assert_fails impact_shared_file_is_ok "$folder/moved.csv" "$SYS_GROUP"
    assert_success impact_shared_apply_file "$folder/moved.csv" "$SYS_GROUP"
    assert_eq 1 "$IMPACT_SHARED_CHANGED"
    assert_eq "alice:$SYS_GROUP 660" "$(facts "$folder/moved.csv")"
    assert_success impact_shared_file_is_ok "$folder/moved.csv" "$SYS_GROUP"
    as_user bob "echo more >>'$folder/moved.csv'"
    assert_success impact_shared_apply_file "$folder/moved.csv" "$SYS_GROUP"
    assert_eq 0 "$IMPACT_SHARED_CHANGED"
}

# Transition account entry can be added and removed.
test_transition_account_entry_can_be_added_and_removed() {
    # The fixture folder belongs to the account oldshared. For this test it
    # gets root as owner, so that only the extra entry decides.
    local folder="$SYS_ROOT_A/Example/outputs" uid
    chown root "$folder"
    uid="$(id -u oldshared)"
    run_cmd as_user oldshared "touch '$folder/by-old-account'"
    assert_status 1
    assert_success impact_shared_dir_is_ok "$folder" "$SYS_GROUP" oldshared absent
    assert_fails impact_shared_dir_is_ok "$folder" "$SYS_GROUP" oldshared present
    assert_success impact_shared_apply_dir "$folder" "$SYS_GROUP" oldshared present
    assert_eq 1 "$IMPACT_SHARED_CHANGED"
    assert_success impact_shared_dir_is_ok "$folder" "$SYS_GROUP" oldshared present
    assert_fails impact_shared_dir_is_ok "$folder" "$SYS_GROUP" oldshared absent
    # Without the two extra words the folder still counts as following the rules.
    assert_success impact_shared_dir_is_ok "$folder" "$SYS_GROUP"
    local acl
    acl="$(getfacl -c -p -n -E "$folder")"
    assert_contains "$acl" "user:$uid:rwx"
    assert_contains "$acl" "default:user:$uid:rwx"
    # The old account can write now, and members can use what it creates.
    as_user oldshared "echo legacy >'$folder/by-old-account' && mkdir '$folder/old-run'"
    as_user alice "echo more >>'$folder/by-old-account' && touch '$folder/old-run/by-alice'"
    # A new folder made by a member inherits the entry.
    as_user alice "mkdir '$folder/new-run'"
    as_user oldshared "touch '$folder/new-run/by-old-account'"
    assert_success impact_shared_apply_dir "$folder" "$SYS_GROUP" oldshared present
    assert_eq 0 "$IMPACT_SHARED_CHANGED"
    # Remove the entry again.
    assert_success impact_shared_apply_dir "$folder" "$SYS_GROUP" oldshared absent
    assert_eq 1 "$IMPACT_SHARED_CHANGED"
    assert_success impact_shared_dir_is_ok "$folder" "$SYS_GROUP" oldshared absent
    assert_not_contains "$(getfacl -c -p -n -E "$folder")" "user:$uid:"
    run_cmd as_user oldshared "touch '$folder/again'"
    assert_status 1
    assert_eq "root:$SYS_GROUP 2775" "$(facts "$folder")"
    run_cmd impact_shared_apply_dir "$folder" "$SYS_GROUP" no-such-account-xyz present
    assert_status 1
    run_cmd impact_shared_apply_dir "$folder" "$SYS_GROUP" oldshared sometimes
    assert_status 1
}

# Apply dir refuses links and unresolved paths.
test_apply_dir_refuses_links_and_unresolved_paths() {
    local folder="$SYS_ROOT_A/Example"
    # A symbolic link to a system folder where a folder is expected.
    ln -s /etc "$folder/link-to-etc"
    local etc_before
    etc_before="$(stat -c '%U:%G %a' /etc; getfacl -c -p -n /etc)"
    run_cmd impact_shared_apply_dir "$folder/link-to-etc" "$SYS_GROUP"
    assert_status 1
    assert_output_contains 'is no real folder'
    assert_fails impact_shared_dir_is_ok "$folder/link-to-etc" "$SYS_GROUP"
    # A path that reaches a real folder through a link is not fully resolved.
    ln -s "$folder/outputs" "$folder/link-to-outputs"
    mkdir -p "$folder/outputs/inner"
    run_cmd impact_shared_apply_dir "$folder/link-to-outputs/inner" "$SYS_GROUP"
    assert_status 1
    assert_output_contains 'not a fully resolved path'
    run_cmd impact_shared_apply_dir "$folder/outputs/../outputs/inner" "$SYS_GROUP"
    assert_status 1
    run_cmd impact_shared_apply_dir "$folder/no-such-folder" "$SYS_GROUP"
    assert_status 1
    run_cmd impact_shared_apply_dir "$folder/outputs/analysis/results.csv" "$SYS_GROUP"
    assert_status 1
    # The storage root itself and folders outside are refused.
    run_cmd impact_shared_apply_dir "$SYS_ROOT_A" "$SYS_GROUP"
    assert_status 1
    run_cmd impact_shared_apply_dir /srv "$SYS_GROUP"
    assert_status 1
    assert_eq "$etc_before" "$(stat -c '%U:%G %a' /etc; getfacl -c -p -n /etc)" "/etc must be untouched"
    rm -f "$folder/link-to-etc" "$folder/link-to-outputs"
}

# ----------------------------------------------------------------------------
# The shared rules for files
# ----------------------------------------------------------------------------

# Apply files in one call.
test_apply_files_in_one_call() {
    local folder="$SYS_ROOT_B/Example"
    mkdir -p "$folder"
    printf 'a\n' >"$folder/plain.csv"
    printf '#!/bin/sh\n' >"$folder/script.sh"
    printf 'b\n' >"$folder/secret.csv"
    printf 'c\n' >"$folder/name with blank.csv"
    chmod 644 "$folder/plain.csv" "$folder/name with blank.csv"
    chmod 750 "$folder/script.sh"
    chmod 600 "$folder/secret.csv"
    assert_fails impact_shared_file_is_ok "$folder/plain.csv" "$SYS_GROUP"
    assert_success impact_shared_apply_files "$SYS_GROUP" -- "$folder/plain.csv" "$folder/script.sh" \
        "$folder/secret.csv" "$folder/name with blank.csv"
    assert_eq 1 "$IMPACT_SHARED_CHANGED"
    assert_eq "root:$SYS_GROUP 664" "$(facts "$folder/plain.csv")"
    assert_eq "root:$SYS_GROUP 770" "$(facts "$folder/script.sh")" "executable for the group where the owner may execute"
    assert_eq "root:$SYS_GROUP 660" "$(facts "$folder/secret.csv")" "the rights of others stay as they are"
    assert_eq "root:$SYS_GROUP 664" "$(facts "$folder/name with blank.csv")"
    local file
    for file in plain.csv script.sh secret.csv 'name with blank.csv'; do
        assert_success impact_shared_file_is_ok "$folder/$file" "$SYS_GROUP"
    done
    # An empty list is fine.
    assert_success impact_shared_apply_files "$SYS_GROUP" --
    run_cmd impact_shared_apply_files "$SYS_GROUP" "$folder/plain.csv"
    assert_status 1
}

# Apply files never follows links and refuses other entries.
test_apply_files_never_follows_links_and_refuses_other_entries() {
    local folder="$SYS_ROOT_B/Example"
    printf 'target\n' >"$folder/target-file"
    chmod 600 "$folder/target-file"
    ln -s /etc/hostname "$folder/link-to-system-file"
    ln -s "$folder/target-file" "$folder/link-to-file"
    mkdir "$folder/subfolder"
    printf 'inner\n' >"$folder/subfolder/inner"
    chmod 600 "$folder/subfolder/inner"
    local hostname_before target_before inner_before
    hostname_before="$(facts /etc/hostname)"
    target_before="$(facts "$folder/target-file")"
    inner_before="$(facts "$folder/subfolder/inner")"
    local entry
    for entry in "$folder/link-to-system-file" "$folder/link-to-file" "$folder/subfolder" "$folder/missing" \
        /etc/hostname "relative-name"; do
        run_cmd impact_shared_apply_files "$SYS_GROUP" -- "$folder/plain.csv" "$entry"
        assert_status 1
        assert_output_contains 'is no plain file inside a storage root'
        assert_fails impact_shared_file_is_ok "$entry" "$SYS_GROUP"
    done
    assert_eq "$hostname_before" "$(facts /etc/hostname)"
    assert_eq "$target_before" "$(facts "$folder/target-file")" "the target of a link is never changed"
    assert_eq "$inner_before" "$(facts "$folder/subfolder/inner")" "a folder is never walked through"
}

# Transition account entry on files.
test_transition_account_entry_on_files() {
    local folder="$SYS_ROOT_B/Example" uid
    uid="$(id -u oldshared)"
    assert_fails impact_shared_file_is_ok "$folder/plain.csv" "$SYS_GROUP" oldshared present
    assert_success impact_shared_apply_file "$folder/plain.csv" "$SYS_GROUP" oldshared present
    assert_success impact_shared_file_is_ok "$folder/plain.csv" "$SYS_GROUP" oldshared present
    assert_contains "$(getfacl -c -p -n -E "$folder/plain.csv")" "user:$uid:rw-"
    assert_success impact_shared_apply_files "$SYS_GROUP" oldshared present -- "$folder/script.sh"
    assert_contains "$(getfacl -c -p -n -E "$folder/script.sh")" "user:$uid:rwx"
    assert_success impact_shared_apply_files "$SYS_GROUP" oldshared absent -- "$folder/plain.csv" "$folder/script.sh"
    assert_success impact_shared_file_is_ok "$folder/plain.csv" "$SYS_GROUP" oldshared absent
    assert_not_contains "$(getfacl -c -p -n -E "$folder/script.sh")" "user:$uid:"
    assert_success impact_shared_file_is_ok "$folder/script.sh" "$SYS_GROUP"
}

# ----------------------------------------------------------------------------
# The storage safety check and the ACL test
# ----------------------------------------------------------------------------

# impact_storage_check_target accepts folders inside a storage root, in their
# resolved form, and refuses every other place.
test_storage_check_target() {
    assert_success impact_storage_check_target "$SYS_ROOT_A/Example"
    assert_eq "$SYS_ROOT_A/Example" "$IMPACT_STORAGE_PATH"
    assert_eq "$SYS_ROOT_A" "$IMPACT_STORAGE_ROOT"
    assert_success impact_storage_check_target "$SYS_ROOT_A/Example/outputs/"
    assert_eq "$SYS_ROOT_A/Example/outputs" "$IMPACT_STORAGE_PATH" "the path is returned in its resolved form"
    assert_success impact_storage_check_target "$SYS_ROOT_B/Example"
    assert_eq "$SYS_ROOT_B" "$IMPACT_STORAGE_ROOT"
    # Refusals.
    assert_fails impact_storage_check_target "$SYS_ROOT_A"
    assert_contains "$IMPACT_STORAGE_ERROR" 'is a storage root. Give the folder of one model inside it'
    assert_fails impact_storage_check_target /mnt/disk_a
    assert_fails impact_storage_check_target "$SYS_ROOT_A/Example/outputs/analysis/results.csv"
    assert_contains "$IMPACT_STORAGE_ERROR" 'is no folder'
    assert_fails impact_storage_check_target "$SYS_ROOT_A/missing"
    assert_fails impact_storage_check_target /home/alice
    assert_contains "$IMPACT_STORAGE_ERROR" 'home folder'
    assert_fails impact_storage_check_target /srv/impact/models
    assert_contains "$IMPACT_STORAGE_ERROR" 'system folder'
    # A link inside the root that leads out of it is resolved first.
    ln -s /home/alice "$SYS_ROOT_A/Example/link-out"
    assert_fails impact_storage_check_target "$SYS_ROOT_A/Example/link-out"
    assert_contains "$IMPACT_STORAGE_ERROR" 'home folder'
    rm -f "$SYS_ROOT_A/Example/link-out"
    # A folder with a blank in its name is refused with a hint.
    mkdir "$SYS_ROOT_A/Example/two words"
    assert_fails impact_storage_check_target "$SYS_ROOT_A/Example/two words"
    assert_contains "$IMPACT_STORAGE_ERROR" 'Run the command for the folder above it'
    rmdir "$SYS_ROOT_A/Example/two words"
}

# Storage check target refuses the top of a file system.
test_storage_check_target_refuses_the_top_of_a_file_system() {
    mkdir -p "$SYS_ROOT_A/mounted"
    # A "bind mount" of a folder onto itself makes it the top folder of a
    # mounted file system.
    mount --bind "$SYS_ROOT_A/mounted" "$SYS_ROOT_A/mounted"
    local status=0
    impact_storage_check_target "$SYS_ROOT_A/mounted" || status=$?
    umount "$SYS_ROOT_A/mounted"
    assert_eq 1 "$status"
    assert_contains "$IMPACT_STORAGE_ERROR" 'top folder of a file system'
    assert_success impact_storage_check_target "$SYS_ROOT_A/mounted"
    rmdir "$SYS_ROOT_A/mounted"
}

# Acl probe and file system questions.
test_acl_probe_and_file_system_questions() {
    assert_success impact_acl_probe "$SYS_ROOT_A"
    assert_eq '' "$(find "$SYS_ROOT_A" -maxdepth 1 -name '.impact*')" "the test folder was removed"
    assert_fails impact_acl_probe "$SYS_ROOT_A/no-such-folder"
    assert_success impact_fs_type_supported "$(impact_fs_type "$SYS_ROOT_A")"
    assert_success impact_fs_type_supported "$(impact_fs_type "$SYS_ROOT_A/not/yet/there")"
    assert_success impact_is_mount_point /
    assert_fails impact_is_mount_point "$SYS_ROOT_A"
    assert_matches "$(impact_fs_mount_options "$SYS_ROOT_A")" '(^|,)rw(,|$)'
}

# ----------------------------------------------------------------------------
# The model file, as root
# ----------------------------------------------------------------------------

# Model file written and loaded.
test_model_file_written_and_loaded() {
    local folder=/srv/impact/models/Example-Model
    local -A values=(
        [MODEL_CONF_VERSION]=1 [REPO_URL]='git@github.com:example-org/Example-Model.git'
        [BRANCH]='main' [STORAGE_NAME]=Example [STORAGE_ROOTS]="$SYS_ROOT_A"
    )
    impact_make_dir "$folder" 2750 root "$SYS_GROUP"
    assert_success impact_model_conf_write "$folder/model.conf" values
    assert_eq "root:$SYS_GROUP 640" "$(facts "$folder/model.conf")"
    assert_success impact_model_load Example-Model
    assert_eq 'main' "${IMPACT_MODEL[BRANCH]}"
    assert_eq "$SYS_ROOT_A" "${IMPACT_MODEL[STORAGE_ROOTS]}"
    # A member can read the model file, a colleague outside the group cannot.
    assert_contains "$(as_user alice "cat $folder/model.conf")" 'STORAGE_NAME=Example'
    run_cmd as_user carol "cat $folder/model.conf"
    assert_status 1
    # The user commands run as the person: loading works there too.
    run_cmd impact_run_as alice bash -c "source /opt/impact/lib/impact-common.sh && impact_conf_load && impact_model_load Example-Model && echo \"\${IMPACT_MODEL[REPO_URL]}\""
    assert_status 0
    assert_output_contains 'git@github.com:example-org/Example-Model.git'
    # A colleague outside the group learns the real cause: no access
    # (exit code 5), and not a model that seems to be missing.
    run_cmd impact_run_as carol bash -c "source /opt/impact/lib/impact-common.sh && impact_conf_load && impact_require_model Example-Model"
    assert_status 5
    assert_output_contains "no member of the group '$SYS_GROUP'"
}

# Model file that others can change is refused.
test_model_file_that_others_can_change_is_refused() {
    local file=/srv/impact/models/Example-Model/model.conf status=0
    chmod 664 "$file"
    impact_model_load Example-Model || status=$?
    chmod 640 "$file"
    assert_eq 2 "$status"
    assert_contains "${IMPACT_MODEL_ERRORS[*]}" 'not safe to use'
    # As root (the administrator): one message, and a next step for the
    # administrator, without "contact the administrator".
    run_cmd impact_require_model No-Such-Model
    assert_status 1
    assert_output_contains "The model 'No-Such-Model' is not set up on this workstation"
    assert_eq 1 "$(grep -c '^ERROR:' <<<"$RUN_OUTPUT")" "number of ERROR lines"
    assert_output_contains 'sudo impact-add-model --help'
    assert_output_not_contains "$SYS_ADMIN_CONTACT"
    run_cmd impact_require_model '../Example-Model'
    assert_status 1
    run_cmd impact_require_model Example-Model
    assert_status 0
}

# ----------------------------------------------------------------------------
# The log
# ----------------------------------------------------------------------------

# log_command
#   Writes a small changing command for the log tests.
log_command() {
    {
        printf '#!/bin/bash\n# log-test: a command made by a test\n'
        printf 'set -euo pipefail\n'
        printf 'IMPACT_SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"\n'
        printf 'source /opt/impact/lib/impact-common.sh\n'
        printf 'impact_init "$IMPACT_SELF"\n'
        printf 'impact_parse_args "dry-run fail-early fail-late" "name" "" "$@"\n'
        printf 'impact_require_root\n'
        printf 'impact_log_enable "$@"\n'
        printf 'if impact_opt_given fail-early; then impact_die 1 "failed before any change" ""; fi\n'
        printf 'impact_do "Pretend to enrol $(impact_opt name nobody)" true\n'
        printf 'impact_log_note "key fingerprint: SHA256:example"\n'
        printf 'if impact_opt_given fail-late; then impact_die 4 "failed after a change" ""; fi\n'
        printf 'impact_summary\n'
    } >"$TEST_SUITE_TMP/log-test"
    chmod 755 "$TEST_SUITE_TMP/log-test"
}

# last_log_block
#   Prints the last block of the log.
last_log_block() {
    tac "$LOG_FILE" | sed -e '/^==== /q' | tac
}

# Log block of a normal run.
test_log_block_of_a_normal_run() {
    log_command
    local blocks_before
    blocks_before="$(grep -c '^==== ' "$LOG_FILE")"
    run_cmd sys_as_admin "$TEST_SUITE_TMP/log-test" --name 'alice example' extra-word
    assert_status 0
    assert_eq $((blocks_before + 1)) "$(grep -c '^==== ' "$LOG_FILE")"
    local block
    block="$(last_log_block)"
    assert_matches "$block" '^==== [0-9-]+T[0-9:]+Z ===='
    assert_contains "$block" "account: $SYS_ADMIN"
    # An argument with a blank is written so that the line can be read back.
    assert_contains "$block" 'command: log-test --name alice\ example extra-word'
    assert_contains "$block" 'result:  ok'
    assert_contains "$block" '  + Pretend to enrol alice example'
    assert_contains "$block" '  key fingerprint: SHA256:example'
    assert_eq "root:root 600" "$(facts "$LOG_FILE")"
    # Started by root directly, the account is root.
    run_cmd "$TEST_SUITE_TMP/log-test"
    assert_contains "$(last_log_block)" 'account: root'
}

# Log is silent for dry runs and early failures.
test_log_is_silent_for_dry_runs_and_early_failures() {
    log_command
    local before
    before="$(sha256sum <"$LOG_FILE")"
    run_cmd sys_as_admin "$TEST_SUITE_TMP/log-test" --dry-run
    assert_status 0
    run_cmd sys_as_admin "$TEST_SUITE_TMP/log-test" --fail-early
    assert_status 1
    run_cmd sys_as_admin "$TEST_SUITE_TMP/log-test" --no-such-option
    assert_status 2
    run_cmd runuser -u "$SYS_ADMIN" -- "$TEST_SUITE_TMP/log-test"
    assert_status 2
    assert_eq "$before" "$(sha256sum <"$LOG_FILE")" "the log must be unchanged"
}

# Log records a failure after a change.
test_log_records_a_failure_after_a_change() {
    log_command
    run_cmd sys_as_admin "$TEST_SUITE_TMP/log-test" --fail-late --name bob
    assert_status 4
    assert_output_contains 'stopped before it finished (exit code 4)'
    local block
    block="$(last_log_block)"
    assert_contains "$block" 'result:  FAILED with exit code 4'
    assert_contains "$block" '  + Pretend to enrol bob'
}

# A signal while the first change runs: no step had finished before, and
# the log still gets a block that names the step as "interrupted during",
# because the change may have been made.
test_log_names_the_step_that_ran_at_a_signal() {
    {
        printf '#!/bin/bash\n# signal-test: a command made by a test\n'
        printf 'set -euo pipefail\n'
        printf 'IMPACT_SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"\n'
        printf 'source /opt/impact/lib/impact-common.sh\n'
        printf 'impact_init "$IMPACT_SELF"\n'
        printf 'impact_parse_args "" "" "" "$@"\n'
        printf 'impact_require_root\n'
        printf 'impact_log_enable "$@"\n'
        printf 'impact_do "Create the folder for the signal test" bash -c '\''kill -TERM "$PPID"; sleep 0.2'\''\n'
        printf 'impact_summary\n'
    } >"$TEST_SUITE_TMP/signal-test"
    chmod 755 "$TEST_SUITE_TMP/signal-test"
    run_cmd sys_as_admin "$TEST_SUITE_TMP/signal-test"
    assert_status 143
    local block
    block="$(last_log_block)"
    assert_contains "$block" 'command: signal-test'
    assert_contains "$block" 'result:  FAILED with exit code 143'
    assert_contains "$block" 'interrupted during (may have finished):'
    assert_contains "$block" '  ? Create the folder for the signal test'
}

# Log is never written through a link.
test_log_is_never_written_through_a_link() {
    log_command
    mv /opt/impact/admin/log /opt/impact/admin/log.aside
    mkdir "$TEST_TMP/elsewhere"
    ln -s "$TEST_TMP/elsewhere" /opt/impact/admin/log
    run_cmd "$TEST_SUITE_TMP/log-test"
    rm -f /opt/impact/admin/log
    mv /opt/impact/admin/log.aside /opt/impact/admin/log
    assert_output_contains 'The log was not written'
    assert_eq '' "$(ls -A "$TEST_TMP/elsewhere")"
}

# ----------------------------------------------------------------------------
# Questions to sshd, as root
# ----------------------------------------------------------------------------

# The questions to sshd give the effective settings of an account for a given
# address.
test_ssh_questions() {
    mkdir -p /run/sshd
    assert_success impact_ssh_include_ok
    assert_success impact_ssh_config_test
    local effective
    effective="$(impact_ssh_effective alice)"
    assert_contains "$effective" 'passwordauthentication no'
    assert_contains "$effective" 'permitopen 127.0.0.1:8787'
    effective="$(impact_ssh_effective carol 192.0.2.7)"
    assert_not_contains "$effective" 'permitopen 127.0.0.1:8787'
    assert_success impact_ssh_member_deviations alice 8787 8830
    assert_success impact_ssh_member_deviations bob 8787 8830
    local status=0 output
    output="$(impact_ssh_member_deviations alice 8787 8790)" || status=$?
    assert_eq 1 "$status" "another port range than the installed one"
    assert_contains "$output" 'permitopen'
    status=0
    impact_ssh_member_deviations 'alice,user=root' 8787 8830 >/dev/null || status=$?
    assert_eq 2 "$status"
}

# With "UsePAM no", sshd refuses the key login of an account whose password
# is locked, which is every colleague's account. The member check reports
# it although the twelve values of the rules file apply.
test_member_check_requires_use_pam() {
    mkdir -p /run/sshd
    assert_success impact_ssh_member_deviations alice 8787 8830
    # A file that sshd reads before 60-impact.conf; for UsePAM the first
    # value that sshd reads applies.
    printf 'UsePAM no\n' >/etc/ssh/sshd_config.d/10-test-usepam.conf
    local status=0 output
    output="$(impact_ssh_member_deviations alice 8787 8830)" || status=$?
    rm -f /etc/ssh/sshd_config.d/10-test-usepam.conf
    assert_eq 1 "$status" "status with UsePAM no"
    assert_contains "$output" 'usepam: expected "yes", effective "no"'
    assert_not_contains "$output" 'permitopen'
    assert_success impact_ssh_member_deviations alice 8787 8830
}

# ----------------------------------------------------------------------------
# The record of an enrolled account
# ----------------------------------------------------------------------------

# Account record write and load.
test_account_record_write_and_load() {
    local file=/opt/impact/admin/accounts/alice.conf status=0
    impact_account_record_load alice || status=$?
    assert_eq 1 "$status" "no record before the first write"
    assert_fails impact_account_github_name alice
    assert_success impact_account_record_write alice Alice-Example enrolled
    assert_eq 'root:root 600' "$(facts "$file")"
    assert_success impact_account_record_load alice
    assert_eq '1' "${IMPACT_ACCOUNT_RECORD[ACCOUNT_RECORD_VERSION]}"
    assert_eq 'alice' "${IMPACT_ACCOUNT_RECORD[ACCOUNT]}"
    assert_eq 'alice-example' "${IMPACT_ACCOUNT_RECORD[GITHUB_NAME]}" "the GitHub name is stored in lower case"
    assert_eq "$(id -u alice)" "${IMPACT_ACCOUNT_RECORD[USER_NUMBER]}"
    assert_eq 'enrolled' "${IMPACT_ACCOUNT_RECORD[STATE]}"
    assert_matches "${IMPACT_ACCOUNT_RECORD[CHANGED]}" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$'
    assert_eq 'alice-example' "$(impact_account_github_name alice)"
    # A line of another command stays when the record is updated.
    printf 'KEY_OF_ANOTHER_COMMAND=kept\n' >>"$file"
    assert_success impact_account_record_write alice alice-example removed
    assert_file_contains "$file" 'KEY_OF_ANOTHER_COMMAND=kept'
    assert_success impact_account_record_load alice
    assert_eq 'removed' "${IMPACT_ACCOUNT_RECORD[STATE]}"
    assert_success impact_account_record_write bob bob-example enrolled
    assert_eq $'alice\nbob' "$(impact_account_records)"
}

# Account records are written only for a real account with a valid name and
# state, and a damaged record is refused.
test_account_record_refusals() {
    run_cmd impact_account_record_write no-such-account-xyz some-name enrolled
    assert_status 1
    run_cmd impact_account_record_write carol '../name' enrolled
    assert_status 1
    run_cmd impact_account_record_write carol carol-example gone
    assert_status 1
    assert_missing /opt/impact/admin/accounts/carol.conf
    # A record that was damaged or that others could change is refused.
    local file=/opt/impact/admin/accounts/bob.conf status=0
    sed -i -e 's/^GITHUB_NAME=.*/GITHUB_NAME=Bob Example/' "$file"
    impact_account_record_load bob || status=$?
    assert_eq 2 "$status"
    assert_contains "${IMPACT_ACCOUNT_RECORD_ERRORS[*]}" 'GITHUB_NAME'
    assert_fails impact_account_github_name bob
    assert_success impact_account_record_write bob bob-example enrolled
    chmod 666 "$file"
    status=0
    impact_account_record_load bob || status=$?
    chmod 600 "$file"
    assert_eq 2 "$status"
    assert_contains "${IMPACT_ACCOUNT_RECORD_ERRORS[*]}" 'not safe to use'
}

# ----------------------------------------------------------------------------
# The lock
# ----------------------------------------------------------------------------

# Lock keeps a second command out.
test_lock_keeps_a_second_command_out() {
    {
        printf '#!/bin/bash\n# lock-test: a command made by a test\n'
        printf 'set -euo pipefail\n'
        printf 'IMPACT_SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"\n'
        printf 'source /opt/impact/lib/impact-common.sh\n'
        printf 'impact_init "$IMPACT_SELF"\n'
        printf 'impact_parse_args "dry-run" "name wait" "" "$@"\n'
        printf 'impact_lock "$(impact_opt name example)"\n'
        printf 'echo "lock taken"\n'
        printf 'sleep "$(impact_opt wait 0)"\n'
    } >"$TEST_SUITE_TMP/lock-test"
    chmod 755 "$TEST_SUITE_TMP/lock-test"
    "$TEST_SUITE_TMP/lock-test" --wait 6 >"$TEST_TMP/first-output" 2>&1 &
    local first=$!
    # Wait until the first command holds the lock.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        grep -q 'lock taken' "$TEST_TMP/first-output" 2>/dev/null && break
        sleep 0.3
    done
    assert_file_contains "$TEST_TMP/first-output" 'lock taken'
    assert_file_facts /run/impact 700 root root
    # The same name: refused with exit code 4.
    run_cmd "$TEST_SUITE_TMP/lock-test"
    assert_status 4
    assert_output_contains 'Another IMPACT command that changes the same things is running'
    # Another name, and a dry run, are not held up.
    run_cmd "$TEST_SUITE_TMP/lock-test" --name other
    assert_status 0
    run_cmd "$TEST_SUITE_TMP/lock-test" --dry-run
    assert_status 0
    wait "$first"
    # After the first command ended, the lock is free again.
    run_cmd "$TEST_SUITE_TMP/lock-test"
    assert_status 0
    run_cmd "$TEST_SUITE_TMP/lock-test" --name 'Bad Name'
    assert_status 1
    run_cmd runuser -u "$SYS_ADMIN" -- "$TEST_SUITE_TMP/lock-test"
    assert_status 1
    assert_output_contains 'needs root rights'
}
