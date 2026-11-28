#!/bin/bash
# =============================================================================
# users-20-key-and-list.test.sh: system tests for impact-key and
# impact-list-users
#
# Purpose
#   Runs the installed impact-key and impact-list-users as the stand-in
#   administrator, with a real SSH server on 127.0.0.1. It proves: wrong and
#   hostile input is refused before any change; "list" and impact-list-users
#   change nothing; add, replace and remove do what they say (proved by real
#   key logins), a dry run changes nothing, a second run changes nothing;
#   replace deletes the key copy of the old key and keeps a copy of another
#   enrolled key; removed keys are kept in the archive and the printed undo
#   line works; symbolic links in the home folder are refused.
#
# Who runs it
#   tests/workstation/run-tests.sh system   (root, disposable system only)
#
# Usage
#   sudo env IMPACT_TEST_DISPOSABLE=yes bash tests/workstation/run-tests.sh system --filter users-20
#
# What it changes on the system
#   The installed commands and their settings, test accounts, an SSH server
#   process, and the storage roots below /mnt/disk_a and /mnt/disk_b.
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
# shellcheck disable=SC2016
# Reason for SC2016 (no expansion in single quotes): many texts in this file
# are test data. They must stay exactly as written.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/testlib.sh"

KEY=/usr/local/bin/impact-key
LIST=/usr/local/bin/impact-list-users
GH='alice-example'
ACC='alice-example'
COPY="/home/$ACC/.ssh/id_ed25519_$GH"
WATCHED=(/etc/impact /opt/impact /srv/impact /home /etc/ssh/sshd_config.d /mnt/disk_a /mnt/disk_b)

suite_setup() {
    sys_clean_slate
    sys_storage_up
    sys_install
    sys_admin_create
    sys_sshd_start
    sys_setup
    local name
    for name in k1 k2 k3 k4 ned z1; do
        sys_keypair "$name"
    done
    ssh-keygen -q -t rsa -b 2048 -N '' -C 'rsa@example-pc' -f "$TEST_SUITE_TMP/keys/rsa"
    for name in "$ACC" ned zed yara-example; do
        sys_register_account "$name"
    done
    run_cmd sys_as_admin /usr/local/bin/impact-add-user "$GH" --key-file "$(pub k1)" --fingerprint "$(print_of k1)"
    if [[ "$RUN_STATUS" != '0' ]]; then
        show_run
        fail "impact-add-user failed"
    fi
    # An account that was not enrolled.
    sys_account_add ned
}

suite_teardown() {
    rm -rf /srv/impact-test-target
    sys_clean_slate
}

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# pub NAME
#   Prints the path of the public key of a test key pair.
pub() {
    printf '%s.pub\n' "$(sys_key_path "$1")"
}

# print_of NAME
#   Prints the SHA256 fingerprint of a test key.
print_of() {
    ssh-keygen -l -E sha256 -f "$(pub "$1")" | awk '{ print $2 }'
}

# blob_of NAME
#   Prints the key data (second word) of a test key.
blob_of() {
    awk '{ print $2 }' "$(pub "$1")"
}

# refused_without_change EXPECTED_CODE COMMAND...
#   Runs COMMAND, fails unless it ends with EXPECTED_CODE and leaves the
#   watched folders, the accounts and the groups unchanged.
refused_without_change() {
    local code="$1"
    shift
    snapshot_unchanged_by --content "${WATCHED[@]}" -- "$@"
    assert_status "$code"
}

# login_works KEY_NAME
#   Fails unless a key login of the member with this key works.
login_works() {
    run_cmd sys_ssh_key "$ACC" "$1" id -un
    assert_status 0
    assert_eq "$ACC" "$RUN_OUTPUT" "key login with $1"
}

# login_refused KEY_NAME
#   Fails unless a key login of the member with this key is refused.
login_refused() {
    run_cmd sys_ssh_key "$ACC" "$1" id -un
    assert_status 255
}

# place_key_copy KEY_NAME
#   Puts the private key of a test pair where the GUI puts the key copy for
#   git, owned by the member, mode 600.
place_key_copy() {
    install -m 600 -o "$ACC" -g "$ACC" -- "$(sys_key_path "$1")" "$COPY"
    install -m 644 -o "$ACC" -g "$ACC" -- "$(pub "$1")" "$COPY.pub"
}

# undo_line TEXT
#   Prints the first line of TEXT that starts with "  - " and contains
#   "sudo impact-", without that start and without "... : " before sudo.
undo_line() {
    printf '%s\n' "$1" | sed -n -e 's/^  - [^:]*: sudo /sudo /p' | head -n 1
}

# run_printed_line LINE
#   Runs a line such as "sudo impact-key add alice --key-file f" exactly as
#   printed, through the stand-in administrator. The words of the line hold
#   no blanks or quotes, so splitting at blanks is exact.
run_printed_line() {
    local -a words=()
    read -r -a words <<<"$1"
    assert_eq 'sudo' "${words[0]}" "first word of the printed line"
    run_cmd sys_as_admin "/usr/local/bin/${words[1]}" "${words[@]:2}"
}

# ----------------------------------------------------------------------------
# Refusals and the read-only parts
# ----------------------------------------------------------------------------

# Help and root check.
test_help_and_root_check() {
    run_cmd runuser -u "$SYS_ADMIN" -- "$KEY" --help
    assert_status 0
    assert_output_contains 'replace'
    run_cmd runuser -u "$SYS_ADMIN" -- "$KEY" list "$ACC"
    assert_status 2
    run_cmd runuser -u "$SYS_ADMIN" -- "$LIST"
    assert_status 2
    assert_output_contains 'must run with administrator rights'
}

# Wrong and hostile input is refused before any change.
test_wrong_and_hostile_input_is_refused_before_any_change() {
    local value
    rm -f /tmp/impact-test-hostile
    for value in show 'add;id' '' '$(touch /tmp/impact-test-hostile)' ADD; do
        refused_without_change 2 sys_as_admin "$KEY" "$value" "$ACC" --key-file "$(pub k2)"
    done
    for value in 'Alice' 'a b' '../root' 'x;id' '$(touch /tmp/impact-test-hostile)' ''; do
        refused_without_change 2 sys_as_admin "$KEY" add "$value" --key-file "$(pub k2)"
    done
    refused_without_change 2 sys_as_admin "$KEY" list "$ACC" --key-file "$(pub k2)"
    refused_without_change 2 sys_as_admin "$KEY" remove "$ACC"
    refused_without_change 2 sys_as_admin "$KEY" remove "$ACC" --fingerprint 'SHA256:short'
    refused_without_change 2 sys_as_admin "$KEY" remove "$ACC" --fingerprint "$(print_of k1)" --key-file "$(pub k2)"
    refused_without_change 2 sys_as_admin "$KEY" add "$ACC" --old-fingerprint "$(print_of k1)" --key-file "$(pub k2)"
    refused_without_change 2 sys_as_admin "$KEY" add "$ACC" --github --key-file "$(pub k2)"
    refused_without_change 2 sys_as_admin "$KEY" add "$ACC" --key-file "$(pub rsa)"
    refused_without_change 2 sys_as_admin "$KEY" add "$ACC"
    refused_without_change 2 sys_as_admin "$KEY" add "$ACC" extra --key-file "$(pub k2)"
    # A key line with options, two keys.
    local before="$TEST_TMP/before" after="$TEST_TMP/after"
    snapshot_take "$before" --content "${WATCHED[@]}"
    run_cmd_with_input "no-pty,permitopen=\"0.0.0.0:22\" $(cat -- "$(pub k2)")" sys_as_admin "$KEY" add "$ACC"
    assert_status 2
    run_cmd_with_input "$(cat -- "$(pub k2)")"$'\n'"$(cat -- "$(pub k3)")" sys_as_admin "$KEY" add "$ACC"
    assert_status 2
    snapshot_take "$after" --content "${WATCHED[@]}"
    snapshot_assert_same "$before" "$after"
    # Accounts that do not exist, are not enrolled, or are protected.
    refused_without_change 1 sys_as_admin "$KEY" add nosuchuser --key-file "$(pub k2)"
    refused_without_change 4 sys_as_admin "$KEY" add ned --key-file "$(pub ned)"
    assert_output_contains 'not enrolled'
    refused_without_change 4 sys_as_admin "$KEY" add "$SYS_ADMIN" --key-file "$(pub k2)"
    refused_without_change 4 sys_as_admin "$KEY" remove root --fingerprint "$(print_of k1)" --yes
    assert_missing /tmp/impact-test-hostile
}

# List shows the keys and changes nothing.
test_list_shows_the_keys_and_changes_nothing() {
    refused_without_change 0 sys_as_admin "$KEY" list "$ACC"
    assert_output_contains "key 1: $(print_of k1)  (k1@example-pc)"
    assert_output_contains "id_ed25519_$GH: missing"
    # An account that was not enrolled can be listed as well.
    refused_without_change 0 sys_as_admin "$KEY" list ned
    assert_output_contains 'not enrolled'
}

# ----------------------------------------------------------------------------
# add
# ----------------------------------------------------------------------------

# Add dry run changes nothing.
test_add_dry_run_changes_nothing() {
    refused_without_change 0 sys_as_admin "$KEY" add "$ACC" --key-file "$(pub k2)" --fingerprint "$(print_of k2)" --dry-run
    assert_output_contains "[dry run] Add the key $(print_of k2)"
}

# Add needs a confirmed fingerprint.
test_add_needs_a_confirmed_fingerprint() {
    refused_without_change 1 sys_as_admin "$KEY" add "$ACC" --key-file "$(pub k2)" --yes
    assert_output_contains 'not confirmed'
    refused_without_change 1 sys_as_admin "$KEY" add "$ACC" --key-file "$(pub k2)" --fingerprint "$(print_of k3)"
}

# Add a second key.
test_add_a_second_key() {
    run_cmd sys_as_admin "$KEY" add "$ACC" --key-file "$(pub k2)" --fingerprint "$(print_of k2)"
    assert_status 0
    assert_output_contains "key 2: $(print_of k2)"
    assert_file_facts "/home/$ACC/.ssh/authorized_keys" 600 "$ACC" "$ACC"
    assert_eq 2 "$(grep -c '^ssh-ed25519 ' "/home/$ACC/.ssh/authorized_keys")" "number of keys"
    login_works k1
    login_works k2
    login_refused k3
}

# Add second run changes nothing.
test_add_second_run_changes_nothing() {
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log "${WATCHED[@]}" -- \
        sys_as_admin "$KEY" add "$ACC" --key-file "$(pub k2)" --fingerprint "$(print_of k2)"
    assert_status 0
    assert_output_contains 'Nothing to do'
}

# ----------------------------------------------------------------------------
# replace
# ----------------------------------------------------------------------------

# Replace needs the old key when there are several.
test_replace_needs_the_old_key_when_there_are_several() {
    refused_without_change 2 sys_as_admin "$KEY" replace "$ACC" --key-file "$(pub k3)" --fingerprint "$(print_of k3)"
    assert_output_contains '--old-fingerprint'
    refused_without_change 4 sys_as_admin "$KEY" replace "$ACC" --old-fingerprint "$(print_of k4)" --key-file "$(pub k3)" --fingerprint "$(print_of k3)"
}

# Replace dry run changes nothing.
test_replace_dry_run_changes_nothing() {
    place_key_copy k1
    refused_without_change 0 sys_as_admin "$KEY" replace "$ACC" --old-fingerprint "$(print_of k1)" --key-file "$(pub k3)" --fingerprint "$(print_of k3)" --dry-run
    assert_output_contains "[dry run] Replace the login key $(print_of k1)"
    assert_output_contains "[dry run] Delete the key copy for git $COPY"
}

# Replace swaps the key and deletes the old key copy.
test_replace_swaps_the_key_and_deletes_the_old_key_copy() {
    run_cmd sys_as_admin "$KEY" replace "$ACC" --old-fingerprint "$(print_of k1)" --key-file "$(pub k3)" --fingerprint "$(print_of k3)"
    assert_status 0
    assert_output_contains "Ask $GH to delete it on GitHub"
    assert_output_contains "$(print_of k1)"
    undo_line "$RUN_OUTPUT" >"$TEST_SUITE_TMP/replace-undo"
    assert_missing "$COPY"
    assert_missing "$COPY.pub"
    login_refused k1
    login_works k2
    login_works k3
    # The old key is kept in the archive.
    local saved
    saved="$(grep -l -r -F -- "$(blob_of k1)" "/opt/impact/admin/keys/$ACC"/key-removed-*/ | head -n 1)"
    assert_ne '' "$saved" "archived copy of the old key"
    assert_file_facts "$saved" 600 root root
}

# Replace second run changes nothing.
test_replace_second_run_changes_nothing() {
    place_key_copy k3
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log "${WATCHED[@]}" -- \
        sys_as_admin "$KEY" replace "$ACC" --old-fingerprint "$(print_of k1)" --key-file "$(pub k3)" --fingerprint "$(print_of k3)"
    assert_status 0
    assert_output_contains 'the replacement was done earlier'
    # The new key copy that the GUI placed in the meantime stays.
    assert_exists "$COPY"
}

# A replacement that was interrupted after the login key was replaced and
# before the key copy of the old key was deleted: the same command again
# finds the replacement done, deletes the copy of the old key and prints
# the reminder about GitHub, which the interrupted run never printed.
test_replace_rerun_finishes_an_interrupted_replacement() {
    place_key_copy k1
    run_cmd sys_as_admin "$KEY" replace "$ACC" --old-fingerprint "$(print_of k1)" --key-file "$(pub k3)" --fingerprint "$(print_of k3)"
    assert_status 0
    assert_output_contains 'the replacement was done earlier'
    assert_output_contains 'Delete the key copy for git'
    assert_output_contains "Ask $GH to delete it on GitHub"
    assert_output_contains "$(print_of k1)"
    assert_missing "$COPY"
    assert_missing "$COPY.pub"
    login_works k3
}

# The printed undo line of replace works.
test_the_printed_undo_line_of_replace_works() {
    # The undo line of the replacement, typed as printed: k1 comes back in
    # the place of k3. The key copy of k3 goes with its key.
    local line
    line="$(cat -- "$TEST_SUITE_TMP/replace-undo")"
    assert_contains "$line" "sudo impact-key replace $ACC --old-fingerprint $(print_of k3) --key-file /opt/impact/admin/keys/$ACC/key-removed-"
    run_printed_line "$line"
    assert_status 0
    login_works k1
    login_refused k3
    assert_missing "$COPY"
    # And forward again, for the next tests.
    run_cmd sys_as_admin "$KEY" replace "$ACC" --old-fingerprint "$(print_of k1)" --key-file "$(pub k3)" --fingerprint "$(print_of k3)"
    assert_status 0
    login_works k3
}

# A key copy of a key that stays is kept.
test_a_key_copy_of_a_key_that_stays_is_kept() {
    place_key_copy k2
    run_cmd sys_as_admin "$KEY" replace "$ACC" --old-fingerprint "$(print_of k3)" --key-file "$(pub k4)" --fingerprint "$(print_of k4)"
    assert_status 0
    assert_output_contains 'belongs to a key that stays a login key'
    assert_exists "$COPY"
    login_refused k3
    login_works k4
}

# ----------------------------------------------------------------------------
# remove
# ----------------------------------------------------------------------------

# Remove asks before it removes.
test_remove_asks_before_it_removes() {
    refused_without_change 1 sys_as_admin "$KEY" remove "$ACC" --fingerprint "$(print_of k4)"
    assert_output_contains 'not confirmed'
    refused_without_change 0 sys_as_admin "$KEY" remove "$ACC" --fingerprint "$(print_of k4)" --dry-run
    assert_output_contains "[dry run] Remove the key $(print_of k4)"
}

# Remove takes the key away and the undo line brings it back.
test_remove_takes_the_key_away_and_the_undo_line_brings_it_back() {
    local line
    run_cmd sys_as_admin "$KEY" remove "$ACC" --fingerprint "$(print_of k4)" --yes
    assert_status 0
    line="$(undo_line "$RUN_OUTPUT")"
    login_refused k4
    login_works k2
    # The key copy belongs to k2, which stays.
    assert_exists "$COPY"
    assert_contains "$line" "sudo impact-key add $ACC --key-file /opt/impact/admin/keys/$ACC/key-removed-"
    run_printed_line "$line"
    assert_status 0
    login_works k4
}

# Remove second run changes nothing.
test_remove_second_run_changes_nothing() {
    run_cmd sys_as_admin "$KEY" remove "$ACC" --fingerprint "$(print_of k4)" --yes
    assert_status 0
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log "${WATCHED[@]}" -- \
        sys_as_admin "$KEY" remove "$ACC" --fingerprint "$(print_of k4)" --yes
    assert_status 0
    assert_output_contains "No login key of '$ACC' has the fingerprint $(print_of k4)"
}

# Removing the last key warns.
test_removing_the_last_key_warns() {
    run_cmd sys_as_admin "$KEY" remove "$ACC" --fingerprint "$(print_of k2)" --yes
    assert_status 0
    assert_output_contains 'It is the last login key'
    # The key copy of k2 is deleted with its key.
    assert_missing "$COPY"
    login_refused k2
    run_cmd sys_as_admin "$KEY" list "$ACC"
    assert_output_contains 'No login key'
    # Put a key back for the next tests.
    run_cmd sys_as_admin "$KEY" add "$ACC" --key-file "$(pub k1)" --fingerprint "$(print_of k1)"
    assert_status 0
    login_works k1
}

# Links in the home folder are refused.
test_links_in_the_home_folder_are_refused() {
    mkdir -p /srv/impact-test-target
    printf 'original content\n' >/srv/impact-test-target/authorized_keys
    mv "/home/$ACC/.ssh/authorized_keys" "$TEST_TMP/saved"
    ln -s /srv/impact-test-target/authorized_keys "/home/$ACC/.ssh/authorized_keys"
    refused_without_change 1 sys_as_admin "$KEY" add "$ACC" --key-file "$(pub k2)" --fingerprint "$(print_of k2)"
    refused_without_change 1 sys_as_admin "$KEY" remove "$ACC" --fingerprint "$(print_of k1)" --yes
    refused_without_change 1 sys_as_admin "$KEY" list "$ACC"
    rm "/home/$ACC/.ssh/authorized_keys"
    mv "$TEST_TMP/saved" "/home/$ACC/.ssh/authorized_keys"
    assert_eq 'original content' "$(cat /srv/impact-test-target/authorized_keys)" "the target of the link"
    login_works k1
}

# ----------------------------------------------------------------------------
# impact-list-users
# ----------------------------------------------------------------------------

# List users shows the people and changes nothing.
test_list_users_shows_the_people_and_changes_nothing() {
    # A terminal login, which lastlog records.
    local -a SYS_SSH_OPTIONS=()
    sys__ssh_options
    timeout 30 ssh "${SYS_SSH_OPTIONS[@]}" -tt -o BatchMode=yes -o IdentitiesOnly=yes -i "$(sys_key_path k1)" \
        "$ACC@127.0.0.1" true </dev/null >/dev/null 2>&1 || true
    sys_account_add zed docker
    refused_without_change 0 sys_as_admin "$LIST"
    assert_output_contains "$ACC"
    assert_output_contains "GitHub name:         $GH"
    assert_output_contains "user number:         $(id -u "$ACC")"
    assert_output_contains 'state:               enrolled'
    assert_output_contains 'password:            locked'
    assert_output_contains "1. $(print_of k1)"
    assert_output_contains "repository folder:   /home/$ACC/Repositories"
    assert_output_contains 'from 127.0.0.1 (terminal login)'
    assert_output_contains "zed: member of 'docker', not enrolled with impact-add-user"
    assert_output_contains 'Summary: 1 enrolled, 0 removed, 0 deleted'
}

# One key pair belongs to one person: impact-key refuses a key that is a
# login key of another enrolled account (exit code 4), before any change.
test_the_key_of_another_account_is_refused() {
    run_cmd sys_as_admin /usr/local/bin/impact-add-user yara-example --key-file "$(pub z1)" --fingerprint "$(print_of z1)"
    assert_status 0
    refused_without_change 4 sys_as_admin "$KEY" add "$ACC" --key-file "$(pub z1)" --fingerprint "$(print_of z1)"
    assert_output_contains 'is a login key of the account yara-example already'
    refused_without_change 4 sys_as_admin "$KEY" replace "$ACC" --key-file "$(pub z1)" --fingerprint "$(print_of z1)"
    assert_output_contains 'is a login key of the account yara-example already'
}
