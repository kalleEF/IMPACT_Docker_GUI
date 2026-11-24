#!/bin/bash
# =============================================================================
# 21-setup-variants.test.sh: system tests for first runs of
# impact-workstation-setup with other values and other starting states
#
# Purpose
#   Each test starts from a machine without settings and checks one variant:
#   every option with a value of its own (group name, group number, model
#   folder, port range, access mode); a group that exists already; a system
#   group, an account name and a used group number, which are refused; a
#   storage root that exists already and is left as it is; a run without a
#   running SSH server; a run from the unpacked folder.
#
# Who runs it
#   tests/workstation/run-tests.sh system   (root, disposable system only)
#
# Usage
#   sudo env IMPACT_TEST_DISPOSABLE=yes bash tests/workstation/run-tests.sh system --filter 21-setup
#
# What it changes on the system
#   The installed commands, test groups, /etc/impact, /srv/impact,
#   /srv/impact-test, the SSH rules file, the storage roots below
#   /mnt/disk_a and /mnt/disk_b.
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

SETUP=/usr/local/bin/impact-workstation-setup
CONF=/etc/impact/impact.conf
RULES=/etc/ssh/sshd_config.d/60-impact.conf

suite_setup() {
    sys_clean_slate
    sys_storage_up
    sys_install
    sys_admin_create
    sys_register_group research-team
}

suite_teardown() {
    rm -rf /srv/impact-test
    sys_clean_slate
}

# setup runs before every test of this file: back to a machine without
# settings, groups, rules and storage content.
setup() {
    rm -f "$RULES"
    rm -rf /etc/impact /srv/impact /srv/impact-test
    local group
    for group in "$SYS_GROUP" research-team; do
        if getent group "$group" >/dev/null; then
            groupdel "$group"
        fi
    done
    find /mnt/disk_a /mnt/disk_b -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

# conf_value KEY
#   Prints the value of KEY in the settings file.
conf_value() {
    sed -n -e "s/^$1=//p" "$CONF"
}

test_every_option_with_its_own_value() {
    mkdir -p /srv/impact-test
    run_cmd sys_as_admin "$SETUP" \
        --shared-roots "$SYS_ROOT_A" --admin-contact 'Zoë Example, room 1.01' --deputy-contact 'Bob Example' \
        --shared-group research-team --gid 23456 --model-dir /srv/impact-test/models \
        --repo-base '/srv/impact-test/repos/%u' --access-mode direct --min-free-gb 0 \
        --port-min 9000 --port-max=9003 --known-direct-containers 'data_preparation_*,other-?' \
        --min-gui-version 2.2.0
    assert_status 0
    assert_eq 'research-team:x:23456:' "$(getent group research-team)"
    assert_fails getent group "$SYS_GROUP"
    assert_eq '1' "$(conf_value IMPACT_CONF_VERSION)"
    assert_eq '2.2.0' "$(conf_value MIN_GUI_VERSION)"
    assert_eq 'direct' "$(conf_value ACCESS_MODE)"
    assert_eq '/srv/impact-test/repos/%u' "$(conf_value REPO_BASE)"
    assert_eq '/srv/impact-test/models' "$(conf_value MODEL_DIR)"
    assert_eq 'research-team' "$(conf_value SHARED_GROUP)"
    assert_eq "$SYS_ROOT_A" "$(conf_value SHARED_ROOTS)"
    assert_eq '0' "$(conf_value MIN_FREE_GB)"
    assert_eq '9000' "$(conf_value PORT_MIN)"
    assert_eq '9003' "$(conf_value PORT_MAX)"
    assert_eq 'data_preparation_*,other-?' "$(conf_value KNOWN_DIRECT_CONTAINERS)"
    assert_eq 'Zoë Example, room 1.01' "$(conf_value ADMIN_CONTACT)"
    assert_eq 'Bob Example' "$(conf_value DEPUTY_CONTACT)"
    assert_file_facts /srv/impact-test/models 2750 root research-team
    assert_file_facts "$SYS_ROOT_A" 2750 root research-team
    assert_missing "$SYS_ROOT_B"
    assert_file_contains "$RULES" 'Match Group research-team'
    assert_file_contains "$RULES" '    PermitOpen 127.0.0.1:9000 127.0.0.1:9001 127.0.0.1:9002 127.0.0.1:9003'
    assert_file_not_contains "$RULES" '127.0.0.1:8787'
    # The settings file reads back as valid, and a second run has nothing
    # to do.
    load_library
    assert_success impact_conf_load
    run_cmd sys_as_admin "$SETUP"
    assert_status 0
    assert_output_contains 'Nothing to do'
    # The contact text can be removed again with an empty value.
    run_cmd sys_as_admin "$SETUP" --deputy-contact ''
    assert_status 0
    assert_eq '' "$(conf_value DEPUTY_CONTACT)"
    assert_eq 'Zoë Example, room 1.01' "$(conf_value ADMIN_CONTACT)"
}

test_existing_group_is_used_as_it_is() {
    groupadd --gid 34567 "$SYS_GROUP"
    sys_setup
    assert_output_contains "The group 'impact' exists (number 34567)."
    assert_output_not_contains "Create the group"
    assert_eq 'impact:x:34567:' "$(getent group "$SYS_GROUP")"
    assert_file_facts /srv/impact/models 2750 root "$SYS_GROUP"
    # The matching number is accepted; another one is a conflict.
    setup
    groupadd --gid 34567 "$SYS_GROUP"
    sys_setup --gid 34567
    setup
    groupadd --gid 34567 "$SYS_GROUP"
    snapshot_unchanged_by --content /etc/impact /srv /etc/ssh/sshd_config.d /mnt/disk_a /mnt/disk_b -- \
        sys_as_admin "$SETUP" --shared-roots "$SYS_ROOT_A" --admin-contact "$SYS_ADMIN_CONTACT" --gid 34568
    assert_status 4
}

test_system_group_is_never_used() {
    groupadd --system "$SYS_GROUP"
    local gid
    gid="$(getent group "$SYS_GROUP" | cut -d: -f3)"
    snapshot_unchanged_by --content /etc/impact /srv /etc/ssh/sshd_config.d /mnt/disk_a /mnt/disk_b -- \
        sys_as_admin "$SETUP" --shared-roots "$SYS_ROOT_A" --admin-contact "$SYS_ADMIN_CONTACT"
    assert_status 4
    assert_output_contains "exists with the number $gid"
    assert_output_contains 'a system group is never used as the shared group'
    assert_missing "$CONF"
    assert_missing "$RULES"
}

test_account_name_and_used_number_are_refused() {
    local before="$TEST_TMP/before" after="$TEST_TMP/after" admin_gid
    snapshot_take "$before" --content /etc/impact /srv /etc/ssh/sshd_config.d /mnt/disk_a /mnt/disk_b
    # The name of an account: its group is that account's personal group.
    run_cmd sys_as_admin "$SETUP" --shared-roots "$SYS_ROOT_A" --admin-contact "$SYS_ADMIN_CONTACT" --shared-group "$SYS_ADMIN"
    assert_status 4
    assert_output_contains "also the name of an account"
    run_cmd sys_as_admin "$SETUP" --shared-roots "$SYS_ROOT_A" --admin-contact "$SYS_ADMIN_CONTACT" --shared-group root
    assert_status 4
    # A group number that another group has.
    admin_gid="$(id -g "$SYS_ADMIN")"
    if ((admin_gid >= 1000 && admin_gid <= 60000)); then
        run_cmd sys_as_admin "$SETUP" --shared-roots "$SYS_ROOT_A" --admin-contact "$SYS_ADMIN_CONTACT" --gid "$admin_gid"
        assert_status 4
        assert_output_contains "The group number $admin_gid is in use by the group '$SYS_ADMIN'"
    fi
    snapshot_take "$after" --content /etc/impact /srv /etc/ssh/sshd_config.d /mnt/disk_a /mnt/disk_b
    snapshot_assert_same "$before" "$after" "a refused call changed the system"
    assert_fails getent group "$SYS_GROUP"
}

test_existing_storage_root_is_left_as_it_is() {
    # A root with content that belongs to another account, as on a machine
    # that is already in use.
    mkdir -p "$SYS_ROOT_A/Example/outputs"
    printf 'result\n' >"$SYS_ROOT_A/Example/outputs/file.csv"
    chown -R "$SYS_ADMIN:$SYS_ADMIN" "$SYS_ROOT_A"
    chmod 755 "$SYS_ROOT_A" "$SYS_ROOT_A/Example"
    chmod 700 "$SYS_ROOT_A/Example/outputs"
    # The run creates the group, so the comparison looks at the folder only.
    snapshot_take "$TEST_TMP/before" --content --no-accounts "$SYS_ROOT_A"
    sys_setup
    snapshot_take "$TEST_TMP/after" --content --no-accounts "$SYS_ROOT_A"
    snapshot_assert_same "$TEST_TMP/before" "$TEST_TMP/after" "setup changed an existing storage root"
    assert_output_contains "The storage root $SYS_ROOT_A exists. It is left as it is."
    assert_output_contains "Test that $SYS_ROOT_A accepts access control lists"
    assert_output_not_contains "Create the storage root $SYS_ROOT_A"
    assert_file_facts "$SYS_ROOT_B" 2750 root "$SYS_GROUP"
}

test_root_that_members_cannot_enter_gives_a_warning() {
    mkdir -p "$SYS_ROOT_A"
    chown root:root "$SYS_ROOT_A"
    chmod 700 "$SYS_ROOT_A"
    sys_setup
    assert_output_contains "WARNING: Members of 'impact' cannot enter $SYS_ROOT_A"
    assert_output_contains "sudo chgrp impact $SYS_ROOT_A"
    assert_file_facts "$SYS_ROOT_A" 700 root root
}

test_storage_root_behind_a_symbolic_link_gives_a_warning() {
    mkdir -p /mnt/disk_a/real-shared
    ln -s /mnt/disk_a/real-shared /mnt/disk_a/link-to-shared
    run_cmd sys_as_admin "$SETUP" --shared-roots /mnt/disk_a/link-to-shared --admin-contact "$SYS_ADMIN_CONTACT"
    assert_status 0
    assert_output_contains 'is a symbolic link or contains one; its real place is /mnt/disk_a/real-shared'
    # The storage check works with the real place.
    load_library
    assert_success impact_conf_load
    mkdir /mnt/disk_a/real-shared/Example
    assert_success impact_storage_check_target /mnt/disk_a/link-to-shared/Example
    assert_eq '/mnt/disk_a/real-shared/Example' "$IMPACT_STORAGE_PATH"
    assert_eq '/mnt/disk_a/real-shared' "$IMPACT_STORAGE_ROOT"
    assert_eq '/mnt/disk_a/real-shared' "$(impact_storage_real_root /mnt/disk_a/link-to-shared)"
    assert_fails impact_storage_real_root /mnt/disk_a/real-shared
}

test_run_without_a_running_ssh_server() {
    if sys_ssh_answers; then
        skip "an SSH server runs on this machine"
    fi
    # Without the folder /run/sshd the self-test of sshd cannot run; the
    # command creates the folder for it.
    rm -rf /run/sshd
    sys_setup
    assert_output_contains 'Create the folder /run/sshd'
    assert_output_contains 'WARNING: No running SSH server was found on this machine.'
    assert_output_not_contains 'The SSH server answers new connections.'
    assert_exists "$RULES"
    assert_success /usr/sbin/sshd -t
    # In a dry run the folder is not created.
    setup
    rm -rf /run/sshd
    run_cmd sys_as_admin "$SETUP" --dry-run --shared-roots "$SYS_ROOT_A" --admin-contact "$SYS_ADMIN_CONTACT"
    assert_status 0
    assert_missing /run/sshd
    mkdir -p /run/sshd
}

test_run_from_the_unpacked_folder() {
    # The first look at a machine happens before the installation: the
    # command must work from the unpacked folder as well.
    run_cmd sys_as_admin "$WORKSTATION_DIR/bin/impact-workstation-setup" --dry-run \
        --shared-roots "$SYS_ROOT_A" --admin-contact "$SYS_ADMIN_CONTACT"
    assert_status 0
    assert_output_contains '[dry run] Write /etc/impact/github_known_hosts'
    run_cmd bash "$WORKSTATION_DIR/bin/impact-workstation-setup" --help
    assert_status 0
}

test_link_at_the_place_of_the_rules_file_is_refused_before_any_change() {
    # A symbolic link where the rules file belongs was made by hand. The
    # command could not put it back after a failed check, so it must stop
    # before it changes anything.
    : >"$TEST_TMP/rules-elsewhere"
    ln -s "$TEST_TMP/rules-elsewhere" "$RULES"
    snapshot_unchanged_by --content /etc/impact /srv /etc/ssh/sshd_config.d /mnt/disk_a /mnt/disk_b -- \
        sys_as_admin "$SETUP" --shared-roots "$SYS_ROOT_A" --admin-contact "$SYS_ADMIN_CONTACT"
    assert_status 4
    assert_output_contains 'exists and is no plain file'
    assert_eq "$TEST_TMP/rules-elsewhere" "$(readlink "$RULES")" "the link is still there"
    assert_eq 0 "$(wc -c <"$TEST_TMP/rules-elsewhere")" "nothing was written through the link"
    assert_fails getent group "$SYS_GROUP"
    # The removal refuses it as well.
    run_cmd sys_as_admin "$SETUP" --remove-ssh-rules
    assert_status 4
    assert_exists "$RULES"
    rm -f "$RULES"
}

test_existing_folders_with_other_rights_are_corrected() {
    mkdir -p /srv/impact/models/Existing-Model /etc/impact
    chmod 755 /srv/impact/models
    chmod 700 /etc/impact
    : >/srv/impact/models/Existing-Model/keep-me
    sys_setup
    assert_output_contains 'Correct the folder /srv/impact/models'
    assert_output_contains 'Correct the folder /etc/impact'
    assert_file_facts /srv/impact/models 2750 root "$SYS_GROUP"
    assert_file_facts /etc/impact 755 root root
    # The content of the folder is not touched.
    assert_file_facts /srv/impact/models/Existing-Model 755 root root
    assert_exists /srv/impact/models/Existing-Model/keep-me
}
