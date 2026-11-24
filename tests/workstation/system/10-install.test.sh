#!/bin/bash
# =============================================================================
# 10-install.test.sh: system tests for install.sh and uninstall.sh
#
# Purpose
#   Runs the real install.sh and uninstall.sh as root and checks: a dry run
#   changes nothing; a normal run creates exactly the agreed files, links and
#   rights; a second run changes nothing; wrong or hostile input and a file
#   of another origin are refused before any change; an update removes
#   leftovers of an older installation; uninstall removes the commands and
#   keeps everything else.
#
# Who runs it
#   tests/workstation/run-tests.sh system   (root, disposable system only)
#
# Usage
#   sudo env IMPACT_TEST_DISPOSABLE=yes bash tests/workstation/run-tests.sh system --filter 10-install
#
# What it changes on the system
#   /opt/impact, /usr/local/bin/impact-*, the stand-in administration account.
#   For one test it moves the tool getfacl aside and puts it back.
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

# The folders whose state the tests compare before and after a run.
WATCHED=(/opt/impact /usr/local/bin /etc/impact /srv/impact /etc/ssh/sshd_config.d)
LOG_FILE=/opt/impact/admin/log/impact-admin.log

suite_setup() {
    sys_clean_slate
    sys_admin_create
}

suite_teardown() {
    # Put the tool back, should the test that moves it have been aborted.
    if [[ -e /usr/bin/getfacl.impact-test-aside ]]; then
        mv -f /usr/bin/getfacl.impact-test-aside /usr/bin/getfacl
    fi
    sys_clean_slate
}

test_help_works_and_changes_nothing() {
    snapshot_unchanged_by "${WATCHED[@]}" -- bash "$WORKSTATION_DIR/install.sh" --help
    assert_status 0
    assert_output_contains 'install the IMPACT workstation commands'
    assert_output_contains 'How to undo'
    snapshot_unchanged_by "${WATCHED[@]}" -- bash "$WORKSTATION_DIR/uninstall.sh" --help
    assert_status 0
    assert_output_contains 'What it changes on the system'
}

test_wrong_and_hostile_input_is_refused_before_any_change() {
    local before="$TEST_TMP/before" after="$TEST_TMP/after" call
    snapshot_take "$before" --content "${WATCHED[@]}"
    local -a calls=(
        '--unknown'
        '--dry-run=yes'
        'extra-argument'
        '-n'
        '; touch /tmp/impact-test-hostile'
        '$(touch /tmp/impact-test-hostile)'
        '--prefix /tmp/elsewhere'
        '../../etc'
    )
    for call in "${calls[@]}"; do
        run_cmd bash "$WORKSTATION_DIR/install.sh" "$call"
        assert_status 2
        run_cmd bash "$WORKSTATION_DIR/uninstall.sh" "$call"
        assert_status 2
    done
    run_cmd bash "$WORKSTATION_DIR/install.sh" $'line\nbreak'
    assert_status 2
    snapshot_take "$after" --content "${WATCHED[@]}"
    snapshot_assert_same "$before" "$after" "a refused call changed the system"
    assert_missing /tmp/impact-test-hostile
}

test_dry_run_changes_nothing() {
    snapshot_unchanged_by --content "${WATCHED[@]}" -- bash "$WORKSTATION_DIR/install.sh" --dry-run
    assert_status 0
    assert_output_contains 'DRY RUN'
    assert_output_contains '[dry run] Create the folder /opt/impact'
    assert_output_contains 'Dry run: nothing was changed. A real run would do this:'
    assert_missing /opt/impact
    assert_missing /usr/local/bin/impact-workstation-setup
}

test_file_of_another_origin_is_refused_before_any_change() {
    # A plain file with the name of a command.
    printf '#!/bin/sh\necho other\n' >/usr/local/bin/impact-workstation-setup
    snapshot_unchanged_by --content "${WATCHED[@]}" -- bash "$WORKSTATION_DIR/install.sh"
    assert_status 4
    assert_output_contains 'is no link of an IMPACT installation'
    rm -f /usr/local/bin/impact-workstation-setup
    # A link that points to another place.
    ln -s /bin/true /usr/local/bin/impact-workstation-setup
    snapshot_unchanged_by --content "${WATCHED[@]}" -- bash "$WORKSTATION_DIR/install.sh"
    assert_status 4
    rm -f /usr/local/bin/impact-workstation-setup
    # A symbolic link where the folder of the installation belongs.
    mkdir -p "$TEST_TMP/elsewhere"
    ln -s "$TEST_TMP/elsewhere" /opt/impact
    run_cmd bash "$WORKSTATION_DIR/install.sh"
    assert_status 4
    assert_output_contains 'is no real folder'
    assert_eq '' "$(ls -A "$TEST_TMP/elsewhere")" "nothing was written through the link"
    rm -f /opt/impact
}

test_missing_tool_stops_with_the_apt_get_line() {
    local before="$TEST_TMP/before" after="$TEST_TMP/after"
    snapshot_take "$before" "${WATCHED[@]}"
    # Move one tool aside for the one call of install.sh. run_cmd never ends
    # the test, so the tool is put back in every case.
    mv /usr/bin/getfacl /usr/bin/getfacl.impact-test-aside
    run_cmd bash "$WORKSTATION_DIR/install.sh"
    mv /usr/bin/getfacl.impact-test-aside /usr/bin/getfacl
    snapshot_take "$after" "${WATCHED[@]}"
    snapshot_assert_same "$before" "$after"
    assert_status 1
    assert_output_contains 'These tools are missing on this machine: getfacl'
    assert_output_contains 'sudo apt-get install acl'
    assert_output_contains 'Nothing was installed'
    assert_missing /opt/impact
}

test_incomplete_or_damaged_folder_is_refused() {
    local copy="$TEST_TMP/unpacked"
    cp -a "$WORKSTATION_DIR" "$copy"
    rm -f "$copy/lib/impact-ssh.sh"
    snapshot_unchanged_by "${WATCHED[@]}" -- bash "$copy/install.sh"
    assert_status 1
    assert_output_contains 'impact-ssh.sh is missing'
    # A command that is cut off in the middle (a damaged archive).
    rm -rf "$copy"
    cp -a "$WORKSTATION_DIR" "$copy"
    printf 'if then fi (\n' >>"$copy/bin/impact-workstation-setup"
    snapshot_unchanged_by "${WATCHED[@]}" -- bash "$copy/install.sh"
    assert_status 1
    assert_output_contains 'syntax error'
    rm -rf "$copy"
    cp -a "$WORKSTATION_DIR" "$copy"
    printf 'latest\n' >"$copy/VERSION"
    run_cmd bash "$copy/install.sh"
    assert_status 1
    assert_missing /opt/impact
}

test_install_creates_the_agreed_files() {
    run_cmd sys_as_admin bash "$WORKSTATION_DIR/install.sh"
    assert_status 0
    assert_output_contains 'What changed:'
    assert_output_contains 'How to undo:'
    assert_output_contains 'sudo /opt/impact/uninstall.sh'
    assert_file_facts /opt/impact 755 root root
    assert_file_facts /opt/impact/bin 755 root root
    assert_file_facts /opt/impact/lib 755 root root
    assert_file_facts /opt/impact/etc 755 root root
    assert_file_facts /opt/impact/admin 700 root root
    assert_file_facts /opt/impact/VERSION 644 root root
    assert_file_facts /opt/impact/uninstall.sh 755 root root
    local file name
    for file in "$WORKSTATION_DIR"/bin/impact-*; do
        name="$(basename "$file")"
        assert_file_facts "/opt/impact/bin/$name" 755 root root
        assert_success cmp -s "$file" "/opt/impact/bin/$name"
        assert_eq "/opt/impact/bin/$name" "$(readlink "/usr/local/bin/$name")" "link of $name"
    done
    for file in "$WORKSTATION_DIR"/lib/impact-*.sh; do
        name="$(basename "$file")"
        assert_file_facts "/opt/impact/lib/$name" 644 root root
        assert_success cmp -s "$file" "/opt/impact/lib/$name"
    done
    assert_file_facts /opt/impact/etc/github_known_hosts 644 root root
    assert_file_facts /opt/impact/etc/impact.conf.example 644 root root
    assert_eq "$(cat "$WORKSTATION_DIR/VERSION")" "$(cat /opt/impact/VERSION)"
    # install.sh creates no settings, no group and no SSH rules.
    assert_missing /etc/impact
    assert_missing /etc/ssh/sshd_config.d/60-impact.conf
}

test_install_writes_one_log_block() {
    assert_file_facts /opt/impact/admin/log 700 root root
    assert_file_facts "$LOG_FILE" 600 root root
    assert_eq 1 "$(grep -c '^==== ' "$LOG_FILE")" "number of log blocks"
    assert_matches "$(sed -n '1p' "$LOG_FILE")" '^==== [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ====$'
    assert_file_contains "$LOG_FILE" "account: $SYS_ADMIN"
    assert_file_contains "$LOG_FILE" 'command: install.sh'
    assert_file_contains "$LOG_FILE" 'result:  ok'
    assert_file_contains "$LOG_FILE" '  + Create the folder /opt/impact/admin'
}

test_installed_command_runs_through_its_link() {
    run_cmd /usr/local/bin/impact-workstation-setup --help
    assert_status 0
    assert_output_contains 'impact-workstation-setup: prepare the workstation'
    # The fixed PATH of the commands contains /usr/local/bin, so the plain
    # name works as well.
    run_cmd impact-workstation-setup --help
    assert_status 0
}

test_second_run_changes_nothing() {
    # The log gets one block per real run; everything else must be identical.
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log "${WATCHED[@]}" -- bash "$WORKSTATION_DIR/install.sh"
    assert_status 0
    assert_output_contains 'Nothing to do: everything is already in the requested state.'
    assert_output_not_contains '  + '
    assert_eq 2 "$(grep -c '^==== ' "$LOG_FILE")" "the second run has its own log block"
    assert_file_contains "$LOG_FILE" 'result:  ok, nothing had to be changed'
}

test_dry_run_after_install_writes_no_log_block() {
    snapshot_unchanged_by --content "${WATCHED[@]}" -- bash "$WORKSTATION_DIR/install.sh" --dry-run
    assert_status 0
    assert_output_contains 'A real run would change nothing either'
}

test_update_repairs_changes_and_removes_leftovers() {
    # Leftovers of an older version: a command that no longer exists, with
    # its link; and a file that was changed by hand.
    printf '#!/bin/bash\n' >/opt/impact/bin/impact-old-command
    chmod 755 /opt/impact/bin/impact-old-command
    ln -s /opt/impact/bin/impact-old-command /usr/local/bin/impact-old-command
    printf '# changed by hand\n' >>/opt/impact/lib/impact-common.sh
    chmod 600 /opt/impact/VERSION
    : >/opt/impact/admin/keep-me
    run_cmd bash "$WORKSTATION_DIR/install.sh"
    assert_status 0
    assert_missing /opt/impact/bin/impact-old-command
    assert_missing /usr/local/bin/impact-old-command
    assert_success cmp -s "$WORKSTATION_DIR/lib/impact-common.sh" /opt/impact/lib/impact-common.sh
    assert_file_facts /opt/impact/VERSION 644 root root
    assert_exists /opt/impact/admin/keep-me
    assert_missing /opt/impact/.new-bin
    assert_missing /opt/impact/.old-bin
    run_cmd bash "$WORKSTATION_DIR/install.sh"
    assert_output_contains 'Nothing to do'
}

test_uninstall_dry_run_changes_nothing() {
    snapshot_unchanged_by --content "${WATCHED[@]}" -- /opt/impact/uninstall.sh --dry-run
    assert_status 0
    assert_output_contains '[dry run] Remove the links'
    assert_output_contains 'What stays on this machine'
}

test_uninstall_removes_the_commands_and_keeps_the_rest() {
    # An entry of another origin with a similar name must stay.
    printf '#!/bin/sh\n' >/usr/local/bin/impact-foreign-tool
    mkdir -p /etc/impact
    : >/etc/impact/keep-me-too
    run_cmd sys_as_admin /opt/impact/uninstall.sh
    assert_status 0
    assert_missing /opt/impact/bin
    assert_missing /opt/impact/lib
    assert_missing /opt/impact/etc
    assert_missing /opt/impact/VERSION
    assert_missing /opt/impact/uninstall.sh
    assert_missing /usr/local/bin/impact-workstation-setup
    assert_exists /usr/local/bin/impact-foreign-tool
    assert_exists /opt/impact/admin/keep-me
    assert_exists /etc/impact/keep-me-too
    assert_file_facts /opt/impact/admin 700 root root
    assert_output_contains 'impact-foreign-tool'
    assert_output_contains 'What stays on this machine, and how to remove each part by hand'
    local part
    for part in 'Personal accounts' 'Group:' 'Settings: /etc/impact (exists)' 'SSH rules:' 'Model folders:' \
        'Shared storage:' 'Administrator folder: /opt/impact/admin (exists)' 'sudo groupdel' 'sudo userdel'; do
        assert_output_contains "$part"
    done
    assert_file_contains "$LOG_FILE" 'command: uninstall.sh'
    rm -f /usr/local/bin/impact-foreign-tool /etc/impact/keep-me-too
    rmdir /etc/impact
}

test_uninstall_second_run_changes_nothing() {
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log "${WATCHED[@]}" -- bash "$WORKSTATION_DIR/uninstall.sh"
    assert_status 0
    assert_output_contains 'Nothing to do'
}

test_install_again_and_uninstall_from_the_unpacked_folder() {
    run_cmd bash "$WORKSTATION_DIR/install.sh"
    assert_status 0
    assert_exists /usr/local/bin/impact-workstation-setup
    assert_exists /opt/impact/admin/keep-me
    run_cmd bash "$WORKSTATION_DIR/uninstall.sh"
    assert_status 0
    assert_missing /opt/impact/bin
    assert_missing /usr/local/bin/impact-workstation-setup
    # The administrator folder with the log stays in every case.
    assert_exists /opt/impact/admin/keep-me
    assert_file_contains "$LOG_FILE" 'command: uninstall.sh'
}
