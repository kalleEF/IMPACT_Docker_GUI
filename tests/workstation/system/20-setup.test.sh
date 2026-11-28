#!/bin/bash
# =============================================================================
# 20-setup.test.sh: system tests for impact-workstation-setup, with a real
# SSH server
#
# Purpose
#   Runs the real command as the stand-in administrator (through sudo) and
#   checks: wrong and hostile input is refused before any change; a dry run
#   changes nothing; the first run creates group, folders, settings file,
#   GitHub's host keys and SSH rules; a second run changes nothing; the
#   effective SSH settings of an account outside the group are identical
#   before and after; a member gets the restricted values; a password login
#   is refused for a member and still works for an account outside the
#   group; a changed port range rewrites the PermitOpen line; a failing SSH
#   step puts the previous rules and settings back; --remove-ssh-rules
#   restores the state before.
#
# Who runs it
#   tests/workstation/run-tests.sh system   (root, disposable system only).
#   It needs an SSH server on 127.0.0.1: run it where the network is private
#   (a container or a private view), or where an SSH service already runs.
#
# Usage
#   sudo env IMPACT_TEST_DISPOSABLE=yes bash tests/workstation/run-tests.sh system --filter 20-setup
#
# What it changes on the system
#   The installed commands, the group impact, /etc/impact, /srv/impact,
#   /opt/impact/admin, the SSH rules file, two test accounts, the storage
#   roots below /mnt/disk_a and /mnt/disk_b, and an SSH server process.
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
# are test data, or lines of small scripts that a test writes. They must stay
# exactly as written.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/testlib.sh"

SETUP=/usr/local/bin/impact-workstation-setup
CONF=/etc/impact/impact.conf
RULES=/etc/ssh/sshd_config.d/60-impact.conf
LOG_FILE=/opt/impact/admin/log/impact-admin.log
MEMBER=alice
MEMBER_PASSWORD='Member-Test-Pass-37'
# The folders whose state the tests compare before and after a run.
WATCHED=(/etc/impact /opt/impact /srv/impact /etc/ssh/sshd_config.d /usr/local/bin /mnt/disk_a /mnt/disk_b)

suite_setup() {
    sys_clean_slate
    sys_storage_up
    sys_install
    sys_admin_create
    # The person who will become a member later. For now the account is in
    # no special group; its SSH settings are recorded as the state "before".
    sys_account_add "$MEMBER"
    sys_set_password "$MEMBER" "$MEMBER_PASSWORD"
    sys_keypair "$MEMBER"
    sys_install_key "$MEMBER" "$MEMBER"
    sys_sshd_start
    sys_effective_ssh "$SYS_ADMIN" >"$TEST_SUITE_TMP/admin-before"
    sys_effective_ssh root >"$TEST_SUITE_TMP/root-before"
    sys_effective_ssh "$MEMBER" >"$TEST_SUITE_TMP/member-before"
}

suite_teardown() {
    sys_clean_slate
}

# first_run_options
#   Prints nothing; fills the array FIRST_RUN with the options of a first run.
first_run_options() {
    FIRST_RUN=(--shared-roots "$SYS_ROOT_A,$SYS_ROOT_B" --admin-contact "$SYS_ADMIN_CONTACT")
}

# conf_value KEY
#   Prints the value of KEY in the settings file.
conf_value() {
    sed -n -e "s/^$1=//p" "$CONF"
}

# ----------------------------------------------------------------------------
# Before the first run
# ----------------------------------------------------------------------------

test_needs_root() {
    run_cmd runuser -u "$SYS_ADMIN" -- "$SETUP" --dry-run
    assert_status 2
    assert_output_contains 'must run with administrator rights'
    assert_output_contains 'sudo'
    run_cmd runuser -u "$SYS_ADMIN" -- "$SETUP" --help
    assert_status 0
    assert_output_contains 'Usage'
}

test_first_run_needs_roots_and_contact() {
    snapshot_unchanged_by --content "${WATCHED[@]}" -- sys_as_admin "$SETUP"
    assert_status 2
    assert_output_contains 'The first run needs --shared-roots'
    run_cmd sys_as_admin "$SETUP" --shared-roots "$SYS_ROOT_A"
    assert_status 2
    run_cmd sys_as_admin "$SETUP" --admin-contact "$SYS_ADMIN_CONTACT"
    assert_status 2
}

test_wrong_and_hostile_input_is_refused_before_any_change() {
    local before="$TEST_TMP/before" after="$TEST_TMP/after" index
    local -a FIRST_RUN=()
    first_run_options
    snapshot_take "$before" --content "${WATCHED[@]}"
    # Each entry is one extra option with its value, added to a complete
    # first-run call. Every call must end with exit code 2.
    local -a cases=(
        --port-min 80
        --port-min 08787
        --port-max 70000
        --port-min '8787; touch /tmp/impact-test-hostile'
        --port-max '$(touch /tmp/impact-test-hostile)'
        --min-free-gb -5
        --min-free-gb lots
        --access-mode vpn
        --access-mode 'tunnel direct'
        --shared-group Impact
        --shared-group 'impact; id'
        --shared-group 'impact,sudo'
        --shared-group '../impact'
        --gid 999
        --gid 0
        --gid abc
        --gid '1005 --system'
        --repo-base Repositories
        --repo-base /srv/repositories
        --repo-base '%h/../../etc'
        --repo-base '%h/$(id)'
        --model-dir models
        --model-dir /etc/impact/models
        --model-dir /srv
        --model-dir "$SYS_ROOT_A/models"
        --model-dir '/srv/impact models'
        --model-dir /home/models
        --min-gui-version 2.1
        --min-gui-version latest
        --known-direct-containers 'a b'
        --known-direct-containers 'x;id'
        --deputy-contact $'two\twords'
        --no-such-option value
    )
    for ((index = 0; index < ${#cases[@]}; index += 2)); do
        run_cmd sys_as_admin "$SETUP" "${FIRST_RUN[@]}" "${cases[index]}" "${cases[index + 1]}"
        if [[ "$RUN_STATUS" != '2' ]]; then
            show_run
            fail "expected exit code 2 for ${cases[index]} '${cases[index + 1]}'"
        fi
    done
    # Storage roots and contact: the whole call is the test.
    local -a roots=(
        'relative/path'
        '/mnt/disk_a/shared;id'
        '/mnt/disk_a/my shared'
        '/mnt/disk_a/shared/../../../etc'
        '/mnt/disk_a/shared,/mnt/disk_a/shared'
        '/mnt/disk_a/shared,/mnt/disk_a/shared/inner'
        '/mnt/disk_a/shared,'
        '/etc'
        '/etc/impact/storage'
        '/home/storage'
        '/'
        '/mnt'
        '/tmp/storage'
        ''
    )
    local root
    for root in "${roots[@]}"; do
        run_cmd sys_as_admin "$SETUP" --shared-roots "$root" --admin-contact "$SYS_ADMIN_CONTACT"
        if [[ "$RUN_STATUS" != '2' ]]; then
            show_run
            fail "expected exit code 2 for --shared-roots '$root'"
        fi
    done
    run_cmd sys_as_admin "$SETUP" --shared-roots "$SYS_ROOT_A" --admin-contact ''
    assert_status 2
    run_cmd sys_as_admin "$SETUP" "${FIRST_RUN[@]}" --port-min 8000 --port-max 8200
    assert_status 2
    assert_output_contains 'at most 200'
    run_cmd sys_as_admin "$SETUP" "${FIRST_RUN[@]}" --port-min 9000 --port-max 8999
    assert_status 2
    run_cmd sys_as_admin "$SETUP" "${FIRST_RUN[@]}" extra-argument
    assert_status 2
    run_cmd sys_as_admin "$SETUP" "${FIRST_RUN[@]}" --dry-run --remove-ssh-rules
    assert_status 2
    snapshot_take "$after" --content "${WATCHED[@]}"
    snapshot_assert_same "$before" "$after" "a refused call changed the system"
    assert_missing /tmp/impact-test-hostile
    assert_fails getent group "$SYS_GROUP"
}

test_unusable_storage_root_is_refused_before_any_change() {
    # The parent folder of a root must exist (a disk that is not mounted).
    snapshot_unchanged_by --content "${WATCHED[@]}" -- \
        sys_as_admin "$SETUP" --shared-roots /mnt/not_mounted/shared --admin-contact "$SYS_ADMIN_CONTACT"
    assert_status 1
    assert_output_contains 'its parent folder /mnt/not_mounted does not exist'
    # A root on a file system that is no ext4, xfs or btrfs.
    local type
    type="$(findmnt -n -o FSTYPE -T /srv | head -n 1)"
    if [[ "$type" == 'ext4' || "$type" == 'xfs' || "$type" == 'btrfs' ]]; then
        return 0
    fi
    mkdir -p /srv/impact-test-storage
    snapshot_unchanged_by --content "${WATCHED[@]}" -- \
        sys_as_admin "$SETUP" --shared-roots /srv/impact-test-storage/shared --admin-contact "$SYS_ADMIN_CONTACT"
    rmdir /srv/impact-test-storage
    assert_status 1
    assert_output_contains "file system of the type '$type'"
    assert_output_contains 'ext4, xfs or btrfs'
    assert_fails getent group "$SYS_GROUP"
}

test_dry_run_of_the_first_run_changes_nothing() {
    local -a FIRST_RUN=()
    first_run_options
    snapshot_unchanged_by --content "${WATCHED[@]}" -- sys_as_admin "$SETUP" --dry-run "${FIRST_RUN[@]}"
    assert_status 0
    assert_output_contains 'DRY RUN'
    assert_output_contains "[dry run] Create the group 'impact'"
    assert_output_contains '[dry run] Create the folder /etc/impact'
    assert_output_contains "[dry run] Create the storage root $SYS_ROOT_A"
    assert_output_contains '[dry run] Write the settings file /etc/impact/impact.conf'
    assert_output_contains '[dry run] Write /etc/impact/github_known_hosts'
    assert_output_contains '[dry run] Write the SSH rules file'
    assert_output_contains '[dry run] Reload the SSH service'
    assert_output_contains 'Dry run: nothing was changed. A real run would do this:'
    assert_fails getent group "$SYS_GROUP"
    assert_missing "$CONF"
    assert_missing "$RULES"
    assert_file_not_contains "$LOG_FILE" 'command: impact-workstation-setup'
}

# ----------------------------------------------------------------------------
# The first run
# ----------------------------------------------------------------------------

test_first_run_succeeds() {
    local -a FIRST_RUN=()
    first_run_options
    run_cmd sys_as_admin "$SETUP" "${FIRST_RUN[@]}"
    printf '%s\n' "$RUN_OUTPUT" >"$TEST_SUITE_TMP/first-run-output"
    assert_status 0
    assert_output_contains 'What changed:'
    assert_output_contains 'How to undo:'
    assert_output_contains 'sudo impact-workstation-setup --remove-ssh-rules'
    assert_output_contains 'sudo groupdel impact'
    assert_output_contains 'IMPORTANT: keep this session open.'
    assert_output_contains "The effective SSH settings of $SYS_ADMIN root are identical before and after."
    assert_output_contains 'sshd -t: the SSH configuration is free of errors.'
    assert_output_contains 'The SSH server answers new connections.'
}

test_first_run_created_the_group() {
    local gid
    gid="$(getent group "$SYS_GROUP" | cut -d: -f3)"
    if ((gid < 1000)); then
        fail "the group has the number $gid, which is a system number"
    fi
    assert_eq '' "$(getent group "$SYS_GROUP" | cut -d: -f4)" "the new group has no members"
    assert_file_contains "$TEST_SUITE_TMP/first-run-output" "The group 'impact' has the number $gid."
}

test_first_run_created_folders_and_files() {
    assert_file_facts /etc/impact 755 root root
    assert_file_facts "$CONF" 644 root root
    assert_file_facts /etc/impact/github_known_hosts 644 root root
    assert_success cmp -s "$WORKSTATION_DIR/etc/github_known_hosts" /etc/impact/github_known_hosts
    local folder
    for folder in /opt/impact/admin /opt/impact/admin/log /opt/impact/admin/keys /opt/impact/admin/accounts \
        /opt/impact/admin/acl-backups /opt/impact/admin/state; do
        assert_file_facts "$folder" 700 root root
    done
    assert_file_facts /srv/impact/models 2750 root "$SYS_GROUP"
    assert_file_facts /srv/impact 755 root root
    assert_file_facts "$SYS_ROOT_A" 2750 root "$SYS_GROUP"
    assert_file_facts "$SYS_ROOT_B" 2750 root "$SYS_GROUP"
    # The write test for access control lists left nothing behind.
    assert_eq '' "$(ls -A "$SYS_ROOT_A")"
    assert_eq '' "$(ls -A "$SYS_ROOT_B")"
}

test_first_run_wrote_valid_settings() {
    load_library
    assert_success impact_conf_load
    assert_eq '1' "${IMPACT_CONF[IMPACT_CONF_VERSION]}"
    assert_eq '2.1.0' "${IMPACT_CONF[MIN_GUI_VERSION]}"
    assert_eq 'tunnel' "${IMPACT_CONF[ACCESS_MODE]}"
    assert_eq '%h/Repositories' "${IMPACT_CONF[REPO_BASE]}"
    assert_eq '/srv/impact/models' "${IMPACT_CONF[MODEL_DIR]}"
    assert_eq 'impact' "${IMPACT_CONF[SHARED_GROUP]}"
    assert_eq "$SYS_ROOT_A,$SYS_ROOT_B" "${IMPACT_CONF[SHARED_ROOTS]}"
    assert_eq '200' "${IMPACT_CONF[MIN_FREE_GB]}"
    assert_eq '8787' "${IMPACT_CONF[PORT_MIN]}"
    assert_eq '8830' "${IMPACT_CONF[PORT_MAX]}"
    assert_eq '' "${IMPACT_CONF[KNOWN_DIRECT_CONTAINERS]}"
    assert_eq "$SYS_ADMIN_CONTACT" "${IMPACT_CONF[ADMIN_CONTACT]}"
    assert_eq '' "${IMPACT_CONF[DEPUTY_CONTACT]}"
    assert_eq 0 "${#IMPACT_CONF_WARNINGS[@]}"
    # A member of the group can read the settings; the storage check accepts
    # a folder inside a root now.
    mkdir "$SYS_ROOT_A/probe"
    assert_success impact_storage_check_target "$SYS_ROOT_A/probe"
    assert_eq "$SYS_ROOT_A/probe" "$IMPACT_STORAGE_PATH"
    assert_eq "$SYS_ROOT_A" "$IMPACT_STORAGE_ROOT"
    rmdir "$SYS_ROOT_A/probe"
}

test_first_run_wrote_the_ssh_rules() {
    load_library
    assert_file_facts "$RULES" 644 root root
    impact_ssh_rules_content impact 8787 8830 >"$TEST_TMP/expected-rules"
    assert_success cmp -s "$TEST_TMP/expected-rules" "$RULES"
    assert_eq 44 "$(grep -o '127\.0\.0\.1:[0-9]*' "$RULES" | wc -l)" "one PermitOpen entry per port"
    # No temporary file is left in the folder that sshd reads.
    assert_eq '/etc/ssh/sshd_config.d/60-impact.conf' "$(find /etc/ssh/sshd_config.d -mindepth 1)"
    assert_success /usr/sbin/sshd -t
}

test_first_run_wrote_one_log_block() {
    assert_file_facts "$LOG_FILE" 600 root root
    local block
    # The last block of the log: everything from the last line with "====".
    block="$(tac "$LOG_FILE" | sed -e '/^==== /q' | tac)"
    assert_contains "$block" "account: $SYS_ADMIN"
    assert_contains "$block" 'command: impact-workstation-setup --shared-roots /mnt/disk_a/shared,/mnt/disk_b/shared --admin-contact'
    assert_contains "$block" 'result:  ok'
    assert_contains "$block" "+ Create the group 'impact'"
    assert_contains "$block" '+ Write the settings file /etc/impact/impact.conf'
    assert_contains "$block" '+ Reload the SSH service'
    # The step that leaves nothing behind is no change.
    assert_not_contains "$block" 'Test that'
}

test_non_member_settings_are_identical_before_and_after() {
    sys_effective_ssh "$SYS_ADMIN" >"$TEST_TMP/admin-after"
    sys_effective_ssh root >"$TEST_TMP/root-after"
    if ! diff "$TEST_SUITE_TMP/admin-before" "$TEST_TMP/admin-after"; then
        fail "the effective SSH settings of the administrator changed"
    fi
    if ! diff "$TEST_SUITE_TMP/root-before" "$TEST_TMP/root-after"; then
        fail "the effective SSH settings of root changed"
    fi
    # The account that will become a member is still outside the group, so
    # nothing changed for it either.
    sys_effective_ssh "$MEMBER" >"$TEST_TMP/member-after"
    assert_success cmp -s "$TEST_SUITE_TMP/member-before" "$TEST_TMP/member-after"
}

test_second_run_changes_nothing() {
    local -a FIRST_RUN=()
    first_run_options
    local pid_before blocks_before hups_before
    pid_before="$(sys_sshd_pid)"
    blocks_before="$(grep -c '^==== ' "$LOG_FILE")"
    hups_before="$(grep -c 'Received SIGHUP' "$SYS_SSHD_LOG" || true)"
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log "${WATCHED[@]}" -- sys_as_admin "$SETUP" "${FIRST_RUN[@]}"
    assert_status 0
    assert_output_contains 'Nothing to do: everything is already in the requested state. Nothing was changed.'
    assert_output_not_contains '  + '
    assert_output_contains 'The rules file /etc/ssh/sshd_config.d/60-impact.conf already has the requested content.'
    # Without options the stored values are kept as well.
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log "${WATCHED[@]}" -- sys_as_admin "$SETUP"
    assert_status 0
    assert_output_contains 'Nothing to do'
    assert_eq "$pid_before" "$(sys_sshd_pid)"
    assert_eq "$hups_before" "$(grep -c 'Received SIGHUP' "$SYS_SSHD_LOG" || true)" "the SSH server was not reloaded"
    assert_eq $((blocks_before + 2)) "$(grep -c '^==== ' "$LOG_FILE")" "each real run has its own log block"
    assert_file_contains "$LOG_FILE" 'result:  ok, nothing had to be changed'
}

# ----------------------------------------------------------------------------
# A member of the group
# ----------------------------------------------------------------------------

test_member_gets_the_restricted_values() {
    load_library
    usermod --append --groups "$SYS_GROUP" "$MEMBER"
    sys_effective_ssh "$MEMBER" >"$TEST_TMP/member-effective"
    local line
    while IFS= read -r line; do
        assert_file_contains "$TEST_TMP/member-effective" "$line"
    done < <(impact_ssh_expected_member_values 8787 8830)
    assert_success impact_ssh_member_deviations "$MEMBER" 8787 8830
    # The same question for an account outside the group shows deviations.
    local output status=0
    output="$(impact_ssh_member_deviations "$SYS_ADMIN" 8787 8830)" || status=$?
    assert_eq 1 "$status"
    assert_contains "$output" 'passwordauthentication'
    assert_contains "$output" 'permitopen'
    # The administrator is still untouched.
    sys_effective_ssh "$SYS_ADMIN" >"$TEST_TMP/admin-after"
    assert_success cmp -s "$TEST_SUITE_TMP/admin-before" "$TEST_TMP/admin-after"
}

test_password_login_is_refused_for_a_member() {
    assert_eq 'publickey' "$(sys_ssh_offered_methods "$MEMBER")" "login methods offered to a member"
    run_cmd sys_ssh_password "$MEMBER" "$MEMBER_PASSWORD" id -un
    assert_status 255
    assert_output_contains 'Permission denied'
    # The key of the member works.
    run_cmd sys_ssh_key "$MEMBER" "$MEMBER" id -un
    assert_status 0
    assert_eq "$MEMBER" "$RUN_OUTPUT"
}

test_password_login_still_works_outside_the_group() {
    assert_contains "$(sys_ssh_offered_methods "$SYS_ADMIN")" 'password' "login methods offered to the administrator"
    run_cmd sys_ssh_password "$SYS_ADMIN" "$SYS_ADMIN_PASSWORD" id -un
    assert_status 0
    assert_eq "$SYS_ADMIN" "$RUN_OUTPUT"
    # A wrong password is refused, so the login above proves something.
    run_cmd sys_ssh_password "$SYS_ADMIN" 'wrong-password' id -un
    assert_status 255
}

test_member_forwarding_is_limited_to_the_port_range() {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 is needed for the small web servers of this test"
    fi
    # Two small web servers on the workstation: one on a port of the range,
    # one on a port outside it.
    mkdir -p "$TEST_TMP/www"
    printf 'inside the range\n' >"$TEST_TMP/www/index.html"
    python3 -m http.server 8787 --bind 127.0.0.1 --directory "$TEST_TMP/www" >/dev/null 2>&1 &
    local inside_pid=$!
    python3 -m http.server 8999 --bind 127.0.0.1 --directory "$TEST_TMP/www" >/dev/null 2>&1 &
    local outside_pid=$!
    local -a SYS_SSH_OPTIONS=()
    sys__ssh_options
    # -N: no command, forwarding only; -L: local port to target on the server.
    ssh "${SYS_SSH_OPTIONS[@]}" -N -T -o BatchMode=yes -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes \
        -i "$(sys_key_path "$MEMBER")" -L 127.0.0.1:18787:127.0.0.1:8787 -L 127.0.0.1:18999:127.0.0.1:8999 \
        -L 127.0.0.1:18788:localhost:8787 "$MEMBER@127.0.0.1" </dev/null >/dev/null 2>&1 &
    local tunnel_pid=$!
    sleep 2
    local allowed refused by_name
    allowed="$(curl --noproxy '*' --silent --max-time 5 http://127.0.0.1:18787/ || true)"
    refused="$(curl --noproxy '*' --silent --max-time 5 http://127.0.0.1:18999/ || true)"
    by_name="$(curl --noproxy '*' --silent --max-time 5 http://127.0.0.1:18788/ || true)"
    kill "$tunnel_pid" "$inside_pid" "$outside_pid" 2>/dev/null || true
    assert_eq 'inside the range' "$allowed" "answer through the tunnel to a port of the range"
    assert_eq '' "$refused" "a tunnel to a port outside the range must be refused"
    assert_eq '' "$by_name" "the target must be written as 127.0.0.1; the name localhost is refused"
}

# ----------------------------------------------------------------------------
# Later runs
# ----------------------------------------------------------------------------

test_dry_run_of_a_change_changes_nothing() {
    snapshot_unchanged_by --content "${WATCHED[@]}" -- sys_as_admin "$SETUP" --dry-run --port-max 8800 --min-free-gb 300
    assert_status 0
    assert_output_contains "PORT_MAX changes from '8830' to '8800'."
    assert_output_contains "MIN_FREE_GB changes from '200' to '300'."
    assert_output_contains '[dry run] Write the settings file'
    assert_output_contains '[dry run] Write the SSH rules file'
    assert_eq '8830' "$(conf_value PORT_MAX)"
}

test_changed_port_range_rewrites_the_permitopen_line() {
    load_library
    local hups_before
    hups_before="$(grep -c 'Received SIGHUP' "$SYS_SSHD_LOG" || true)"
    run_cmd sys_as_admin "$SETUP" --port-max 8790 --deputy-contact 'Bob Example'
    assert_status 0
    assert_output_contains "The member '$MEMBER' gets the restricted values"
    assert_output_contains 'IMPORTANT: keep this session open.'
    # Only the given keys changed.
    assert_eq '8790' "$(conf_value PORT_MAX)"
    assert_eq '8787' "$(conf_value PORT_MIN)"
    assert_eq 'Bob Example' "$(conf_value DEPUTY_CONTACT)"
    assert_eq "$SYS_ADMIN_CONTACT" "$(conf_value ADMIN_CONTACT)"
    assert_eq "$SYS_ROOT_A,$SYS_ROOT_B" "$(conf_value SHARED_ROOTS)"
    assert_file_contains "$RULES" '    PermitOpen 127.0.0.1:8787 127.0.0.1:8788 127.0.0.1:8789 127.0.0.1:8790'
    assert_file_not_contains "$RULES" '127.0.0.1:8791'
    assert_eq 'permitopen 127.0.0.1:8787 127.0.0.1:8788 127.0.0.1:8789 127.0.0.1:8790' \
        "$(sys_effective_ssh "$MEMBER" | grep '^permitopen ')"
    assert_success impact_ssh_member_deviations "$MEMBER" 8787 8790
    sys_effective_ssh "$SYS_ADMIN" >"$TEST_TMP/admin-after"
    assert_success cmp -s "$TEST_SUITE_TMP/admin-before" "$TEST_TMP/admin-after"
    if [[ -s "$SYS_SSHD_LOG" ]]; then
        assert_eq $((hups_before + 1)) "$(grep -c 'Received SIGHUP' "$SYS_SSHD_LOG" || true)" "the SSH server was reloaded once"
    fi
    assert_output_contains "How to undo:"
    # One command puts both previous values back; removing the rules would
    # leave the members without restrictions, so that line is not offered.
    assert_output_contains "sudo impact-workstation-setup --deputy-contact '' --port-max 8830"
    assert_not_contains "$(sed -n -e '/^How to undo:$/,$p' <<<"$RUN_OUTPUT")" '--remove-ssh-rules' "the list How to undo"
    # The member can still log in with the key after the reload.
    run_cmd sys_ssh_key "$MEMBER" "$MEMBER" id -un
    assert_status 0
    run_cmd sys_as_admin "$SETUP"
    assert_output_contains 'Nothing to do'
}

# undo_commands OUTPUT_FILE
#   Prints the commands of the "How to undo" list in OUTPUT_FILE, one per
#   line, in the printed order: the part of each line from ": sudo " on.
undo_commands() {
    local line
    sed -n -e '/^How to undo:$/,/^[^ ]/p' "$1" | while IFS= read -r line; do
        if [[ "$line" == '  - '*': sudo '* ]]; then
            printf 'sudo %s\n' "${line#*: sudo }"
        fi
    done
}

# A change of the port range, undone by following the printed lines
# literally: the rules file and the settings file are exactly as before,
# and the rules are never removed on the way.
test_undo_of_a_port_change_restores_rules_and_settings() {
    cp -p "$RULES" "$TEST_TMP/rules-before"
    cp -p "$CONF" "$TEST_TMP/conf-before"
    run_cmd sys_as_admin "$SETUP" --port-max 8800
    assert_status 0
    printf '%s\n' "$RUN_OUTPUT" >"$TEST_TMP/change-output"
    local -a commands=()
    mapfile -t commands < <(undo_commands "$TEST_TMP/change-output")
    assert_eq 1 "${#commands[@]}" "number of undo commands"
    assert_eq 'sudo impact-workstation-setup --port-max 8790' "${commands[0]}"
    # The line is typed by the administrator; here bash reads it the same way.
    run_cmd runuser -u "$SYS_ADMIN" -- bash -c "cd / && ${commands[0]}"
    assert_status 0
    assert_success cmp -s "$TEST_TMP/rules-before" "$RULES"
    assert_success cmp -s "$TEST_TMP/conf-before" "$CONF"
    assert_eq '127.0.0.1:8790' "$(sys_effective_ssh "$MEMBER" | grep '^permitopen ' | awk '{ print $NF }')"
}

test_administrator_inside_the_group_is_refused_before_any_change() {
    # If the account that runs the command were a member, the rules would
    # restrict its own login. The command must stop before it changes
    # anything.
    usermod --append --groups "$SYS_GROUP" "$SYS_ADMIN"
    snapshot_unchanged_by --content "${WATCHED[@]}" -- sys_as_admin "$SETUP" --port-max 8795
    gpasswd --delete "$SYS_ADMIN" "$SYS_GROUP" >/dev/null
    assert_status 1
    assert_output_contains "is a member of the group 'impact'"
    assert_eq '8790' "$(conf_value PORT_MAX)"
}

test_conflicts_with_the_current_state_are_refused() {
    local before="$TEST_TMP/before" after="$TEST_TMP/after"
    snapshot_take "$before" --content "${WATCHED[@]}"
    # Another group number for the existing group.
    run_cmd sys_as_admin "$SETUP" --gid 54321
    assert_status 4
    assert_output_contains '--gid asks for 54321'
    # Another group name while the group has a member.
    run_cmd sys_as_admin "$SETUP" --shared-group otherteam
    assert_status 4
    assert_output_contains 'while the old group has members'
    # A system group and the personal group of an account are never used.
    run_cmd sys_as_admin "$SETUP" --shared-group daemon
    assert_status 4
    run_cmd sys_as_admin "$SETUP" --shared-group "$SYS_ADMIN"
    assert_status 4
    snapshot_take "$after" --content "${WATCHED[@]}"
    snapshot_assert_same "$before" "$after" "a refused call changed the system"
}

test_storage_root_in_use_and_model_dir_in_use_cannot_be_dropped() {
    # A model that uses the second root.
    mkdir -p /srv/impact/models/Example-Model
    printf 'MODEL_CONF_VERSION=1\nREPO_URL=git@github.com:example-org/Example-Model.git\nSTORAGE_NAME=Example\nSTORAGE_ROOTS=%s\n' \
        "$SYS_ROOT_B" >/srv/impact/models/Example-Model/model.conf
    snapshot_unchanged_by --content "${WATCHED[@]}" -- sys_as_admin "$SETUP" --shared-roots "$SYS_ROOT_A"
    assert_status 4
    assert_output_contains 'is used by /srv/impact/models/Example-Model/model.conf'
    snapshot_unchanged_by --content "${WATCHED[@]}" -- sys_as_admin "$SETUP" --model-dir /srv/impact/other-models
    assert_status 4
    assert_output_contains 'while the old folder holds models'
    rm -rf /srv/impact/models/Example-Model
}

test_invalid_settings_file_stops_with_exit_code_3() {
    cp -p "$CONF" "$TEST_TMP/conf-copy"
    printf 'PORT_MIN=8787\n' >>"$CONF"
    run_cmd sys_as_admin "$SETUP" --port-max 8800
    cp -p "$TEST_TMP/conf-copy" "$CONF"
    assert_status 3
    assert_output_contains 'PORT_MIN appears a second time'
    # A settings file that another account could change is refused as well.
    chmod 666 "$CONF"
    run_cmd sys_as_admin "$SETUP"
    chmod 644 "$CONF"
    assert_status 3
    assert_output_contains 'can be changed by accounts other than root'
    run_cmd sys_as_admin "$SETUP"
    assert_status 0
    assert_output_contains 'Nothing to do'
}

# ----------------------------------------------------------------------------
# A failing SSH step puts the previous state back
# ----------------------------------------------------------------------------

# rules_command
#   Writes a small command that installs a given rules file through the same
#   library function as impact-workstation-setup. It lets a test hand over a
#   deliberately broken rules file.
rules_command() {
    {
        printf '#!/bin/bash\n# install-rules: a command made by a test\n'
        printf 'set -euo pipefail\n'
        printf 'IMPACT_SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"\n'
        printf 'source /opt/impact/lib/impact-common.sh\n'
        printf 'impact_init "$IMPACT_SELF"\n'
        printf 'impact_parse_args "dry-run" "content" "" "$@"\n'
        printf 'impact_require_root\n'
        printf 'impact_log_enable "$@"\n'
        printf 'impact_ssh_rules_install "$(impact_opt content)" impact 8787 8790\n'
        printf 'impact_summary\n'
    } >"$TEST_SUITE_TMP/install-rules"
    chmod 755 "$TEST_SUITE_TMP/install-rules"
}

# assert_previous_state_is_back SNAPSHOT_BEFORE
#   After a failed SSH step: the watched folders are as before, the SSH
#   configuration is valid, the settings of administrator and member are as
#   before the attempt, and the server still accepts the member's key.
assert_previous_state_is_back() {
    snapshot_take "$TEST_TMP/after" --content "${WATCHED[@]}"
    snapshot_assert_same "$1" "$TEST_TMP/after" "the previous state was not put back"
    assert_success /usr/sbin/sshd -t
    sys_effective_ssh "$SYS_ADMIN" >"$TEST_TMP/admin-after"
    assert_success cmp -s "$TEST_SUITE_TMP/admin-before" "$TEST_TMP/admin-after"
    assert_eq 'permitopen 127.0.0.1:8787 127.0.0.1:8788 127.0.0.1:8789 127.0.0.1:8790' \
        "$(sys_effective_ssh "$MEMBER" | grep '^permitopen ')"
    run_cmd sys_ssh_key "$MEMBER" "$MEMBER" id -un
    assert_status 0
    assert_eq 'publickey' "$(sys_ssh_offered_methods "$MEMBER")"
}

test_broken_rules_file_is_detected_and_the_previous_state_restored() {
    rules_command
    snapshot_take "$TEST_TMP/before" --content "${WATCHED[@]}"
    # A rules file with an option that sshd does not know.
    printf 'Match Group impact\n    PasswordAuthentication no\n    NoSuchOptionOfSshd yes\n' >"$TEST_SUITE_TMP/broken-rules"
    run_cmd sys_as_admin "$TEST_SUITE_TMP/install-rules" --content "$TEST_SUITE_TMP/broken-rules"
    assert_status 1
    assert_output_contains 'sshd -t reports an error with the changed rules'
    assert_output_contains 'NoSuchOptionOfSshd'
    assert_output_contains 'Putting the previous SSH rules back'
    assert_output_contains "The previous file $RULES is back in place."
    assert_output_not_contains 'Reload the SSH service'
    assert_output_not_contains 'What changed:'
    assert_output_not_contains 'These steps had already run'
    assert_previous_state_is_back "$TEST_TMP/before"
}

test_rules_that_touch_the_administrator_are_detected_and_restored() {
    rules_command
    snapshot_take "$TEST_TMP/before" --content "${WATCHED[@]}"
    # Valid for sshd, and it would change the login of everybody: the line
    # stands before the Match line and therefore applies to all accounts.
    printf 'PasswordAuthentication no\nMatch Group impact\n    X11Forwarding no\n' >"$TEST_SUITE_TMP/global-rules"
    run_cmd sys_as_admin "$TEST_SUITE_TMP/install-rules" --content "$TEST_SUITE_TMP/global-rules"
    assert_status 1
    assert_output_contains "The change would alter the SSH settings of $SYS_ADMIN root"
    assert_output_contains '< passwordauthentication yes'
    assert_output_contains '> passwordauthentication no'
    assert_output_contains 'Putting the previous SSH rules back'
    assert_previous_state_is_back "$TEST_TMP/before"
    # The password login of the administrator still works.
    run_cmd sys_ssh_password "$SYS_ADMIN" "$SYS_ADMIN_PASSWORD" id -un
    assert_status 0
}

test_rules_without_effect_for_members_are_detected_and_restored() {
    # Another rules file, read earlier by sshd, gives the member a value
    # first. The member would then not get the restricted values; the
    # command must notice, put the previous rules AND the previous settings
    # file back, and stop.
    printf 'Match User %s\n    X11Forwarding yes\n' "$MEMBER" >/etc/ssh/sshd_config.d/50-impact-test-override.conf
    snapshot_take "$TEST_TMP/before" --content "${WATCHED[@]}"
    run_cmd sys_as_admin "$SETUP" --port-max 8799
    snapshot_take "$TEST_TMP/after" --content "${WATCHED[@]}"
    rm -f /etc/ssh/sshd_config.d/50-impact-test-override.conf
    assert_status 1
    assert_output_contains "The member '$MEMBER' of the group 'impact' does not get the restricted values"
    assert_output_contains 'x11forwarding: expected "no", effective "yes"'
    assert_output_contains 'Putting the previous SSH rules back'
    assert_output_contains 'Putting the previous settings back'
    assert_eq '8790' "$(conf_value PORT_MAX)" "the settings file is back at its previous value"
    snapshot_assert_same "$TEST_TMP/before" "$TEST_TMP/after" "the previous state was not put back"
    assert_success /usr/sbin/sshd -t
    run_cmd sys_ssh_key "$MEMBER" "$MEMBER" id -un
    assert_status 0
}

test_already_broken_configuration_is_reported_and_nothing_changes() {
    # A broken file of another origin: the command must not touch anything.
    printf 'NoSuchOptionOfSshd yes\n' >/etc/ssh/sshd_config.d/70-impact-test-broken.conf
    snapshot_unchanged_by --content "${WATCHED[@]}" -- sys_as_admin "$SETUP" --port-max 8799
    rm -f /etc/ssh/sshd_config.d/70-impact-test-broken.conf
    assert_status 1
    assert_output_contains 'The SSH configuration has an error before this command changed anything'
    assert_output_contains '70-impact-test-broken.conf'
    assert_eq '8790' "$(conf_value PORT_MAX)"
    assert_success /usr/sbin/sshd -t
}

test_missing_include_line_is_explained() {
    cp -p /etc/ssh/sshd_config "$TEST_TMP/sshd_config-copy"
    sed -i -e 's/^Include /#Include /' /etc/ssh/sshd_config
    snapshot_unchanged_by --content "${WATCHED[@]}" -- sys_as_admin "$SETUP" --port-max 8799
    cp -p "$TEST_TMP/sshd_config-copy" /etc/ssh/sshd_config
    assert_status 1
    assert_output_contains 'does not read the folder /etc/ssh/sshd_config.d'
    assert_output_contains 'Include /etc/ssh/sshd_config.d/*.conf'
    assert_success /usr/sbin/sshd -t
}

# ----------------------------------------------------------------------------
# The reload through systemd (with a stand-in for systemctl)
# ----------------------------------------------------------------------------

test_reload_uses_systemctl_when_systemd_runs() {
    sys_fake_systemd_install ssh.service
    run_cmd sys_as_admin "$SETUP" --port-max 8791
    local calls
    calls="$(cat /run/impact-test-systemctl.log)"
    sys_fake_systemd_remove
    assert_status 0
    assert_contains "$calls" 'reload ssh.service'
    assert_output_contains 'systemctl reload ssh.service'
    assert_output_contains 'Docker starts with the machine.'
    assert_eq '8791' "$(conf_value PORT_MAX)"
    assert_file_contains "$RULES" '127.0.0.1:8791'
}

test_socket_activated_service_needs_no_reload() {
    # Ubuntu 24.04 before the first connection: only ssh.socket is active.
    sys_fake_systemd_install ssh.socket
    run_cmd sys_as_admin "$SETUP" --port-max 8792
    local calls
    calls="$(cat /run/impact-test-systemctl.log)"
    sys_fake_systemd_remove
    # The SSH server of the tests was not told about the new file by the
    # stand-in; tell it now, so that the later tests see the current rules.
    kill -HUP "$(sys_sshd_pid)"
    sleep 1
    assert_status 0
    assert_not_contains "$calls" 'reload'
    assert_contains "$calls" 'is-active --quiet ssh.socket'
    assert_output_contains 'ssh.socket starts it at the next connection'
    assert_eq '8792' "$(conf_value PORT_MAX)"
}

test_failed_reload_puts_rules_and_settings_back() {
    sys_fake_systemd_install ssh.service
    : >/run/impact-test-reload-fails
    snapshot_take "$TEST_TMP/before" --content "${WATCHED[@]}"
    run_cmd sys_as_admin "$SETUP" --port-max 8793
    # The note of the unconfirmed change stays (checked below), so the
    # comparison leaves it out.
    snapshot_take "$TEST_TMP/after" --content --exclude /opt/impact/admin/ssh-rules-pending "${WATCHED[@]}"
    sys_fake_systemd_remove
    assert_status 1
    assert_output_contains 'The SSH service could not be reloaded'
    assert_output_contains 'Putting the previous SSH rules back'
    assert_output_contains 'Putting the previous settings back'
    snapshot_assert_same "$TEST_TMP/before" "$TEST_TMP/after" "the previous state was not put back"
    assert_eq '8792' "$(conf_value PORT_MAX)"
    assert_file_contains "$RULES" '127.0.0.1:8792'
    assert_file_not_contains "$RULES" '127.0.0.1:8793'
    assert_success /usr/sbin/sshd -t
    # The reload failed also while the previous file was put back, so it is
    # unknown which file the running server uses. The note stays, and the
    # next run reloads the service although the files are in place.
    assert_output_contains 'stays, so the next run of impact-workstation-setup repeats this work'
    assert_exists /opt/impact/admin/ssh-rules-pending
    run_cmd sys_as_admin "$SETUP"
    assert_status 0
    assert_output_contains 'Put back the SSH rules file that was in place before the interrupted change'
    assert_output_contains 'Reload the SSH service'
    assert_output_not_contains 'Write the SSH rules file'
    assert_missing /opt/impact/admin/ssh-rules-pending
    assert_file_contains "$RULES" '127.0.0.1:8792'
}

# ----------------------------------------------------------------------------
# Docker checks (with stand-ins for the docker programs)
# ----------------------------------------------------------------------------

# fake_dockerd VERSION
#   Puts a stand-in "dockerd" that reports VERSION in front of the real one
#   (/usr/local/bin comes first in the fixed PATH of the commands).
fake_dockerd() {
    printf '#!/bin/sh\n# impact-test stand-in\necho "Docker version %s, build 0000000"\n' "$1" >/usr/local/bin/dockerd
    chmod 755 /usr/local/bin/dockerd
}

test_old_docker_refuses_tunnel_mode_and_warns_in_direct_mode() {
    fake_dockerd 28.3.2
    snapshot_unchanged_by --content "${WATCHED[@]}" -- sys_as_admin "$SETUP" --min-free-gb 250
    local tunnel_status="$RUN_STATUS" tunnel_output="$RUN_OUTPUT"
    run_cmd sys_as_admin "$SETUP" --dry-run --access-mode direct
    rm -f /usr/local/bin/dockerd
    assert_eq 1 "$tunnel_status"
    assert_contains "$tunnel_output" 'Docker Engine 28.3.2 is older than 28.3.3'
    assert_contains "$tunnel_output" 'ACCESS_MODE=tunnel is refused'
    assert_status 0
    assert_output_contains 'WARNING: Docker Engine 28.3.2 is older than 28.3.3'
    # The limit itself is accepted.
    fake_dockerd 28.3.3
    run_cmd sys_as_admin "$SETUP" --dry-run
    rm -f /usr/local/bin/dockerd
    assert_status 0
    assert_output_contains 'Docker Engine 28.3.3 is installed'
}

test_snap_docker_is_a_clear_fail() {
    # A docker program that lives in /snap, reached through the PATH.
    mkdir -p /snap/bin
    printf '#!/bin/sh\n# impact-test stand-in\nexit 1\n' >/snap/bin/docker
    chmod 755 /snap/bin/docker
    ln -s /snap/bin/docker /usr/local/bin/docker
    snapshot_unchanged_by --content "${WATCHED[@]}" -- sys_as_admin "$SETUP" --min-free-gb 250
    rm -f /usr/local/bin/docker /snap/bin/docker
    rmdir /snap/bin /snap 2>/dev/null || true
    assert_status 1
    assert_output_contains 'FAIL: Docker is installed as a snap package'
    assert_output_contains 'sudo snap remove docker'
}

# ----------------------------------------------------------------------------
# Removing the SSH rules
# ----------------------------------------------------------------------------

test_remove_ssh_rules_stands_alone() {
    snapshot_unchanged_by --content "${WATCHED[@]}" -- sys_as_admin "$SETUP" --remove-ssh-rules --port-max 8800
    assert_status 2
    assert_output_contains 'stands alone'
    snapshot_unchanged_by --content "${WATCHED[@]}" -- sys_as_admin "$SETUP" --remove-ssh-rules --dry-run
    assert_status 0
    assert_output_contains '[dry run] Remove the SSH rules file'
    assert_exists "$RULES"
}

test_remove_ssh_rules_restores_the_state_before() {
    run_cmd sys_as_admin "$SETUP" --remove-ssh-rules
    assert_status 0
    assert_output_contains 'Remove the SSH rules file'
    assert_output_contains "The effective SSH settings of $SYS_ADMIN root are identical before and after."
    assert_output_contains 'IMPORTANT: keep this session open.'
    assert_missing "$RULES"
    assert_eq '' "$(find /etc/ssh/sshd_config.d -mindepth 1)"
    assert_success /usr/sbin/sshd -t
    # The member has the same effective settings as before the first run,
    # and so have the administrator and root.
    sys_effective_ssh "$MEMBER" >"$TEST_TMP/member-after"
    sys_effective_ssh "$SYS_ADMIN" >"$TEST_TMP/admin-after"
    sys_effective_ssh root >"$TEST_TMP/root-after"
    if ! diff "$TEST_SUITE_TMP/member-before" "$TEST_TMP/member-after"; then
        fail "the member's SSH settings differ from the state before the rules"
    fi
    assert_success cmp -s "$TEST_SUITE_TMP/admin-before" "$TEST_TMP/admin-after"
    assert_success cmp -s "$TEST_SUITE_TMP/root-before" "$TEST_TMP/root-after"
    # The running server knows it too: the member can log in with the
    # password again.
    assert_contains "$(sys_ssh_offered_methods "$MEMBER")" 'password'
    run_cmd sys_ssh_password "$MEMBER" "$MEMBER_PASSWORD" id -un
    assert_status 0
    assert_eq "$MEMBER" "$RUN_OUTPUT"
    # The settings file, the group and the folders stay.
    assert_exists "$CONF"
    assert_success getent group "$SYS_GROUP"
    # A second removal has nothing to do.
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log "${WATCHED[@]}" -- sys_as_admin "$SETUP" --remove-ssh-rules
    assert_status 0
    assert_output_contains 'Nothing to remove'
    assert_output_contains 'Nothing to do'
}

test_plain_run_writes_the_rules_again() {
    load_library
    run_cmd sys_as_admin "$SETUP"
    assert_status 0
    assert_output_contains 'Write the SSH rules file'
    impact_ssh_rules_content impact 8787 8792 >"$TEST_TMP/expected-rules"
    assert_success cmp -s "$TEST_TMP/expected-rules" "$RULES"
    assert_eq 'publickey' "$(sys_ssh_offered_methods "$MEMBER")"
    run_cmd sys_ssh_password "$MEMBER" "$MEMBER_PASSWORD" id -un
    assert_status 255
}

test_interrupted_ssh_step_puts_the_previous_rules_back() {
    # Start a change and interrupt the command while its SSH step runs. The
    # stand-in for systemctl is made to wait during the reload, which gives
    # the test time to send the signal.
    sys_fake_systemd_install ssh.service
    sed -i -e 's|^    reload)$|    reload)\n        if [ -e /run/impact-test-reload-slow ]; then echo $$ >/run/impact-test-reload-pid; sleep 20; fi|' "$SYS_FAKE_SYSTEMCTL"
    : >/run/impact-test-reload-slow
    snapshot_take "$TEST_TMP/before" --content "${WATCHED[@]}"
    sys_as_admin "$SETUP" --port-max 8794 >"$TEST_TMP/interrupted-output" 2>&1 &
    # Wait up to a minute. "_" as the loop variable: its value is not needed.
    for _ in $(seq 1 120); do
        [[ -s /run/impact-test-reload-pid ]] && break
        sleep 0.5
    done
    assert_exists /run/impact-test-reload-pid
    # From now on the stand-in answers at once again.
    rm -f /run/impact-test-reload-slow
    # The signal goes to the command itself (the bash process that runs it).
    # bash handles it as soon as the program it waits for has ended, so the
    # waiting stand-in is ended next.
    pkill -TERM -f '^/bin/bash /usr/local/bin/impact-workstation-setup --port-max 8794' || true
    kill "$(cat /run/impact-test-reload-pid)" 2>/dev/null || true
    wait || true
    snapshot_take "$TEST_TMP/after" --content "${WATCHED[@]}"
    rm -f /run/impact-test-reload-pid
    sys_fake_systemd_remove
    assert_file_contains "$TEST_TMP/interrupted-output" 'was interrupted'
    assert_file_contains "$TEST_TMP/interrupted-output" 'Putting the previous SSH rules back'
    assert_file_contains "$TEST_TMP/interrupted-output" 'Putting the previous settings back'
    snapshot_assert_same "$TEST_TMP/before" "$TEST_TMP/after" "the previous state was not put back"
    assert_eq '8792' "$(conf_value PORT_MAX)"
    assert_success /usr/sbin/sshd -t
}

# A run killed with "kill -9" (no handler can react) after the rules file
# was renamed and before the SSH service read it: the note of the
# unconfirmed change stays, impact-check and impact-add-user warn, and the
# next run puts the previous file back, repeats the change with all checks
# and reloads the service. A rerun never says "Nothing to do" in this state.
test_killed_ssh_step_is_completed_by_the_next_run() {
    sys_fake_systemd_install ssh.service
    # "exec sleep" makes the waiting stand-in the sleep program itself, so
    # one kill ends it and no further process keeps the lock of the command.
    sed -i -e 's|^    reload)$|    reload)\n        if [ -e /run/impact-test-reload-slow ]; then echo $$ >/run/impact-test-reload-pid; exec sleep 30; fi|' "$SYS_FAKE_SYSTEMCTL"
    : >/run/impact-test-reload-slow
    cp -p "$RULES" "$TEST_TMP/rules-before"
    sys_as_admin "$SETUP" --port-max 8796 >"$TEST_TMP/killed-output" 2>&1 &
    for _ in $(seq 1 120); do
        [[ -s /run/impact-test-reload-pid ]] && break
        sleep 0.5
    done
    assert_exists /run/impact-test-reload-pid
    pkill -KILL -f '^/bin/bash /usr/local/bin/impact-workstation-setup --port-max 8796' || true
    kill "$(cat /run/impact-test-reload-pid)" 2>/dev/null || true
    wait || true
    rm -f /run/impact-test-reload-slow /run/impact-test-reload-pid
    sys_fake_systemd_remove
    # The kill left the new file and the note; the SSH server never read it.
    assert_file_contains "$RULES" '127.0.0.1:8796'
    assert_exists /opt/impact/admin/ssh-rules-pending
    assert_file_facts /opt/impact/admin/ssh-rules-pending 600 root root
    assert_file_contains /opt/impact/admin/ssh-rules-pending 'MODE=install'
    assert_file_contains /opt/impact/admin/ssh-rules-pending 'PREVIOUS=file'
    run_cmd sys_as_admin impact-check
    assert_output_contains 'A change of the SSH rules was interrupted before the SSH service had read it'
    local hups_before
    hups_before="$(grep -c 'Received SIGHUP' "$SYS_SSHD_LOG" || true)"
    run_cmd sys_as_admin "$SETUP" --port-max 8796
    assert_status 0
    assert_output_contains 'An earlier run stopped after it had changed'
    assert_output_contains 'Put back the SSH rules file that was in place before the interrupted change'
    assert_output_contains 'Write the SSH rules file'
    assert_output_contains 'Reload the SSH service'
    assert_output_not_contains 'Nothing to do: everything is already in the requested state'
    assert_missing /opt/impact/admin/ssh-rules-pending
    assert_file_contains "$RULES" '127.0.0.1:8796'
    if [[ -s "$SYS_SSHD_LOG" ]]; then
        assert_eq $((hups_before + 1)) "$(grep -c 'Received SIGHUP' "$SYS_SSHD_LOG" || true)" "the SSH server was reloaded once"
    fi
    run_cmd sys_ssh_key "$MEMBER" "$MEMBER" id -un
    assert_status 0
    # Now the change is confirmed: a further run has nothing to do.
    run_cmd sys_as_admin "$SETUP" --port-max 8796
    assert_status 0
    assert_output_contains 'Nothing to do: everything is already in the requested state'
    # Back to the range of the earlier tests.
    run_cmd sys_as_admin "$SETUP" --port-max 8792
    assert_status 0
}
