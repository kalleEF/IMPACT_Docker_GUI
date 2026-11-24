#!/bin/bash
# =============================================================================
# storage-40-export-state.test.sh: the backup archive of impact-export-state
#
# Purpose
#   Proves that impact-export-state
#     - in a dry run lists the content and writes nothing;
#     - writes one archive with mode 600 for root, next to a checksum file,
#       and says clearly that it holds the SSH host keys and must be copied
#       to another machine;
#     - puts exactly the files of the system into the archive (settings,
#       SSH rules, host keys, account list with numbers, records, received
#       keys, each person's login keys, model folders with extras);
#     - reads a person's login keys with the rights of that person: a
#       symbolic link in a home folder that points to /etc/shadow gives
#       nothing of /etc/shadow;
#     - writes nothing on a second run with the same state, and a new
#       archive after a change;
#     - refuses wrong input and an unsafe state folder before any change.
#
# Who runs it
#   tests/workstation/run-tests.sh system   (root, disposable system only)
#
# Usage
#   sudo env IMPACT_TEST_DISPOSABLE=yes bash tests/workstation/run-tests.sh system --filter storage-40
#
# What it changes on the system
#   The installed commands and their settings, the test accounts alice and
#   bob, a model folder below /srv/impact/models, SSH host keys in /etc/ssh
#   when the machine has none, the storage roots.
#
# How to undo
#   The file removes everything it created (suite_teardown); host keys that
#   it created stay (a disposable system).
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

EXPORT=/usr/local/bin/impact-export-state
STATE=/opt/impact/admin/state
MODEL=/srv/impact/models/Example-Model

suite_setup() {
    sys_clean_slate
    sys_storage_up
    sys_install
    sys_admin_create
    sys_setup
    # Host keys of the SSH server; a fresh system may have none yet.
    if ! compgen -G '/etc/ssh/ssh_host_*_key' >/dev/null; then
        ssh-keygen -A >/dev/null
    fi
    sys_account_add alice "$SYS_GROUP"
    sys_account_add bob "$SYS_GROUP"
    sys_keypair alice
    sys_install_key alice alice
    # bob's login key file is a link to /etc/shadow (an attack on root).
    install -d -m 700 -o bob -g bob -- /home/bob/.ssh
    ln -s -- /etc/shadow /home/bob/.ssh/authorized_keys
    chown -h bob:bob -- /home/bob/.ssh/authorized_keys
    load_library
    impact_conf_load || fail "the settings file cannot be read"
    impact_account_record_write alice alice-example enrolled || fail "the record of alice cannot be written"
    install -d -m 700 -- /opt/impact/admin/keys/alice/received
    install -m 600 -- "$(sys_key_path alice).pub" /opt/impact/admin/keys/alice/received/key-1.pub
    install -d -m 2750 -o root -g "$SYS_GROUP" -- "$MODEL" "$MODEL/extras" "$MODEL/extras/data"
    printf 'MODEL_CONF_VERSION=1\nREPO_URL=git@github.com:example-org/Example-Model.git\nBRANCH=\nSTORAGE_NAME=Example\nSTORAGE_ROOTS=%s\n' "$SYS_ROOT_A" >"$TEST_SUITE_TMP/model.conf"
    install -m 640 -o root -g "$SYS_GROUP" -- "$TEST_SUITE_TMP/model.conf" "$MODEL/model.conf"
    printf 'id,value\n1,2\n' >"$TEST_SUITE_TMP/table.csv"
    install -m 640 -o root -g "$SYS_GROUP" -- "$TEST_SUITE_TMP/table.csv" "$MODEL/extras/data/table.csv"
}

suite_teardown() {
    sys_clean_slate
}

# archives
#   Prints the archives in the state folder, oldest first.
archives() {
    find "$STATE" -maxdepth 1 -type f -name 'impact-state-*.tar.gz' 2>/dev/null | LC_ALL=C sort
}

test_wrong_input_is_refused() {
    snapshot_unchanged_by --content /opt/impact /etc/impact /srv/impact -- sys_as_admin "$EXPORT" extra
    assert_status 2
    assert_output_contains 'Too many arguments'
    snapshot_unchanged_by --content /opt/impact /etc/impact /srv/impact -- sys_as_admin "$EXPORT" --output /tmp
    assert_status 2
    assert_output_contains "Unknown option '--output'"
    snapshot_unchanged_by --content /opt/impact /etc/impact /srv/impact -- runuser -u "$SYS_ADMIN" -- "$EXPORT"
    assert_status 2
    assert_output_contains 'must run with administrator rights'
}

test_an_unsafe_state_folder_is_refused() {
    chmod 755 -- "$STATE"
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log /opt/impact -- sys_as_admin "$EXPORT"
    assert_status 1
    assert_output_contains 'is not a folder of root with mode 700'
    chmod 700 -- "$STATE"
    mv -- "$STATE" "$STATE.real"
    ln -s -- /tmp "$STATE"
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log /opt/impact -- sys_as_admin "$EXPORT"
    rm -f -- "$STATE"
    mv -- "$STATE.real" "$STATE"
    assert_status 1
    assert_output_contains 'is no real folder'
}

test_dry_run_writes_nothing_and_lists_the_content() {
    snapshot_unchanged_by --content /opt/impact /etc/impact /etc/ssh /srv/impact /home -- sys_as_admin "$EXPORT" --dry-run
    assert_status 0
    assert_output_contains 'etc-impact/impact.conf'
    assert_output_contains 'ssh-host-keys/ssh_host_'
    assert_output_contains 'people/alice/authorized_keys'
    assert_output_contains 'admin/accounts/alice.conf'
    assert_output_contains 'admin/keys/alice/received/key-1.pub'
    assert_output_contains 'models/Example-Model/extras/data/table.csv'
    assert_output_contains 'Left out: /home/bob/.ssh/authorized_keys of bob'
    assert_output_contains '[dry run] Write the archive /opt/impact/admin/state/impact-state-'
    assert_output_contains 'IMPORTANT: the archive is secret. It contains the private SSH host keys'
    assert_eq '' "$(archives)" "archives after a dry run"
}

test_archive_has_mode_600_and_holds_the_state() {
    run_cmd sys_as_admin "$EXPORT"
    assert_status 0
    assert_output_contains 'Written: /opt/impact/admin/state/impact-state-'
    assert_output_contains 'IMPORTANT: the archive is secret. It contains the private SSH host keys'
    assert_output_contains 'Copy it to another machine now'
    assert_output_contains "sudo install -m 600 -o $SYS_ADMIN"
    assert_output_contains 'What changed:'
    local archive name
    archive="$(archives)"
    [[ -n "$archive" ]] || fail "no archive was written"
    assert_file_facts "$archive" 600 root root
    assert_file_facts "${archive%.tar.gz}.info" 600 root root
    assert_file_facts "$STATE" 700 root root
    assert_file_contains "${archive%.tar.gz}.info" "ARCHIVE_SHA256=$(sha256sum -- "$archive" | cut -d' ' -f1)"
    assert_file_contains /opt/impact/admin/log/impact-admin.log "archive: $archive"
    # Unpack and compare with the system.
    name="$(basename -- "$archive" .tar.gz)"
    tar -xzf "$archive" -C "$TEST_TMP"
    local unpacked="$TEST_TMP/$name" key
    cmp -- /etc/impact/impact.conf "$unpacked/etc-impact/impact.conf" || fail "impact.conf differs"
    cmp -- /etc/ssh/sshd_config.d/60-impact.conf "$unpacked/ssh-rules/60-impact.conf" || fail "the SSH rules differ"
    for key in /etc/ssh/ssh_host_*_key; do
        cmp -- "$key" "$unpacked/ssh-host-keys/$(basename -- "$key")" || fail "the host key $key differs"
        assert_file_facts "$unpacked/ssh-host-keys/$(basename -- "$key")" 600 root root
    done
    cmp -- /home/alice/.ssh/authorized_keys "$unpacked/people/alice/authorized_keys" || fail "the login keys of alice differ"
    cmp -- "$MODEL/extras/data/table.csv" "$unpacked/models/Example-Model/extras/data/table.csv" || fail "the extras differ"
    cmp -- "$MODEL/model.conf" "$unpacked/models/Example-Model/model.conf" || fail "model.conf differs"
    assert_file_contains "$unpacked/accounts.txt" "account alice user-number $(id -u alice) group-number $(id -g alice)"
    assert_file_contains "$unpacked/accounts.txt" "group $SYS_GROUP number $(getent group "$SYS_GROUP" | cut -d: -f3)"
    assert_file_contains "$unpacked/accounts.txt" 'github alice-example record enrolled'
    assert_file_contains "$unpacked/CONTENTS.txt" 'SECRET: this archive holds the private SSH host keys'
    # Nothing of /etc/shadow, which bob's link pointed to.
    assert_missing "$unpacked/people/bob"
    local root_line
    root_line="$(grep '^root:' /etc/shadow | cut -d: -f1-2)"
    if grep -r -q -F -- "$root_line" "$unpacked"; then
        fail "the archive contains a line of /etc/shadow"
    fi
}

test_second_run_writes_nothing() {
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log /opt/impact /etc/impact /srv/impact -- sys_as_admin "$EXPORT"
    assert_status 0
    assert_output_contains 'already holds exactly this content'
    assert_output_contains 'Nothing to do'
    assert_output_contains 'IMPORTANT: the archive is secret'
    assert_eq 1 "$(archives | wc -l)" "number of archives"
}

test_a_change_gives_a_new_archive() {
    sleep 1   # the archive name holds the time in seconds
    printf 'more\n' >"$TEST_TMP/more.csv"
    install -m 640 -o root -g "$SYS_GROUP" -- "$TEST_TMP/more.csv" "$MODEL/extras/data/more.csv"
    run_cmd sys_as_admin "$EXPORT"
    assert_status 0
    assert_output_contains 'Written:'
    assert_eq 2 "$(archives | wc -l)" "number of archives"
    tar -tzf "$(archives | tail -n 1)" | grep -q 'extras/data/more.csv$' || fail "the new archive lacks the new extra"
}
