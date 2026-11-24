#!/bin/bash
# =============================================================================
# users-10-library.test.sh: unit tests for impact-users.sh
#
# Purpose
#   Proves the pure functions of the shared code of impact-add-user,
#   impact-key, impact-list-users and impact-remove-user: the handling of an
#   authorized_keys text (count, find, add, remove by fingerprint, describe
#   lines with options), file names made from fingerprints, the archive of
#   removed keys and the printed way back, reading lastlog and the SSH log,
#   the filter for processes, the texts for the colleague, and the choice
#   and refusal of keys from the three sources (through small commands).
#
# Who runs it
#   tests/workstation/run-tests.sh unit   (no special rights needed)
#   Tests that need the tool ssh-keygen are skipped without it.
#
# Usage
#   bash tests/workstation/run-tests.sh unit --filter users-10
#
# What it changes on the system
#   Nothing outside the temporary folder of the test.
#
# How to undo
#   Nothing to undo.
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

setup() {
    load_library
    # shellcheck source=../../../workstation/lib/impact-users.sh
    source "$WORKSTATION_DIR/lib/impact-users.sh"
}

# need_ssh_keygen
#   Skips the test on a machine without ssh-keygen.
need_ssh_keygen() {
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        skip "the tool ssh-keygen is not installed (package openssh-client)"
    fi
}

# make_key NAME [TYPE]
#   Creates a key pair in the test folder. Prints nothing; the public key is
#   "$TEST_TMP/NAME.pub".
make_key() {
    ssh-keygen -q -t "${2:-ed25519}" -N '' -C "$1@example-pc" -f "$TEST_TMP/$1"
}

# line_of NAME / print_of NAME / blob_of NAME
#   The public key line, its fingerprint and its key data.
line_of() {
    cat -- "$TEST_TMP/$1.pub"
}
print_of() {
    ssh-keygen -l -E sha256 -f "$TEST_TMP/$1.pub" | cut -d' ' -f2
}
blob_of() {
    cut -d' ' -f2 "$TEST_TMP/$1.pub"
}

# make_command NAME
#   Writes a small command into the test folder: the standard start of a
#   command, the loading of impact-users.sh, and the lines given on standard
#   input. (The same pattern as in 70-command-flow.test.sh.)
make_command() {
    local file="$TEST_TMP/$1"
    {
        printf '#!/bin/bash\n'
        printf '# %s: a command made by a test\n' "$1"
        printf '#\n# Usage\n#   %s [options]\n' "$1"
        printf '# ==========================================\n'
        printf 'set -euo pipefail\n'
        printf 'IMPACT_SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"\n'
        printf 'source %q\n' "$WORKSTATION_DIR/lib/impact-common.sh"
        printf 'source %q\n' "$WORKSTATION_DIR/lib/impact-users.sh"
        printf 'impact_init "$IMPACT_SELF"\n'
        cat
    } >"$file"
    chmod 755 "$file"
}

# key_command
#   A command that collects and chooses a key like impact-add-user and
#   prints the chosen fingerprint.
key_command() {
    make_command choose-key <<'END'
impact_parse_args 'dry-run yes github' 'key-file fingerprint' '' "$@"
impact_users_collect_keys alice-example
impact_users_choose_key alice-example
printf 'chosen=%s given=%s source=%s\n' "$IMPACT_KEY_FINGERPRINT" "$IMPACT_USERS_FINGERPRINT_GIVEN" "$IMPACT_USERS_KEY_SOURCE"
END
}

# ----------------------------------------------------------------------------
# Texts of authorized_keys
# ----------------------------------------------------------------------------

test_count_keys_ignores_comments_and_blank_lines() {
    assert_eq 0 "$(impact_users_count_keys '')"
    assert_eq 0 "$(impact_users_count_keys $'# a comment\n\n   \n')"
    assert_eq 2 "$(impact_users_count_keys $'ssh-ed25519 AAAA x\n# note\n\nno-pty ssh-rsa AAAA y\n')"
}

test_text_with_line_adds_one_line_and_drops_trailing_blank_lines() {
    assert_eq 'new' "$(impact_users_text_with_line '' 'new')"
    assert_eq $'old\nnew' "$(impact_users_text_with_line $'old\n\n\n' 'new')"
    assert_eq $'# c\nold\nnew' "$(impact_users_text_with_line $'# c\nold' 'new')"
    # The output always ends with exactly one line end.
    impact_users_text_with_line $'old\n' 'new' >"$TEST_TMP/out"
    assert_eq 2 "$(wc -l <"$TEST_TMP/out")" "number of lines"
}

test_text_has_blob_finds_the_key_also_after_options() {
    local blob='AAAAC3NzaC1lZDI1NTE5AAAAIOnly-for-a-text-test'
    assert_success impact_users_text_has_blob "ssh-ed25519 $blob a@pc" "$blob"
    assert_success impact_users_text_has_blob $'# x\nno-pty,restrict ssh-ed25519 '"$blob" "$blob"
    assert_fails impact_users_text_has_blob "# ssh-ed25519 $blob" "$blob"
    assert_fails impact_users_text_has_blob "ssh-ed25519 ${blob}X" "$blob"
    assert_fails impact_users_text_has_blob '' "$blob"
}

test_key_entries_describe_every_line() {
    need_ssh_keygen
    make_key alice
    make_key bob
    make_key rsa rsa
    local text entries
    text="# managed by hand"$'\n'"$(line_of alice)"$'\n\n'"no-pty,command=\"/bin/true\" $(line_of bob)"$'\n'"$(line_of rsa)"$'\n'"not a key at all"
    entries="$(impact_users_key_entries "$text")"
    assert_eq 4 "$(printf '%s\n' "$entries" | wc -l)" "number of entries"
    assert_contains "$entries" "1|$(print_of alice)|plain|alice@example-pc"
    assert_contains "$entries" "2|$(print_of bob)|other|a line with options in front of the key"
    assert_contains "$entries" "3|$(print_of rsa)|other|type ssh-rsa"
    assert_contains "$entries" "4|?|other|no readable key"
    assert_success impact_users_text_has_fingerprint "$text" "$(print_of bob)"
    assert_fails impact_users_text_has_fingerprint "$(line_of alice)" "$(print_of bob)"
}

test_removing_by_fingerprint_keeps_everything_else() {
    need_ssh_keygen
    make_key alice
    make_key bob
    local text result
    text="# comment"$'\n'"$(line_of alice)"$'\n'"no-pty $(line_of bob)"$'\n'"$(line_of alice)"
    # Both lines of alice go (a key listed twice), the comment and bob stay.
    result="$(impact_users_text_without_fingerprint "$text" "$(print_of alice)")"
    assert_eq "# comment"$'\n'"no-pty $(line_of bob)" "$result"
    # A line with options goes by its fingerprint as well.
    result="$(impact_users_text_without_fingerprint "$text" "$(print_of bob)")"
    assert_not_contains "$result" "$(blob_of bob)"
    assert_eq 2 "$(impact_users_count_keys "$result")"
    # The lines with a fingerprint.
    assert_eq "no-pty $(line_of bob)" "$(impact_users_lines_with_fingerprint "$text" "$(print_of bob)")"
    assert_eq '' "$(impact_users_lines_with_fingerprint "$text" 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')"
}

# ----------------------------------------------------------------------------
# The key archive and the way back
# ----------------------------------------------------------------------------

test_fingerprint_file_name_uses_safe_letters_only() {
    assert_eq 'SHA256_ab_cd-ef' "$(impact_users_fingerprint_file_name 'SHA256:ab/cd+ef')"
    assert_eq '/opt/impact/admin/keys/alice/received/SHA256_x_y-z.pub' "$(impact_users_received_path alice 'SHA256:x/y+z')"
    assert_matches "$(impact_users_new_archive_name alice account)" '^/opt/impact/admin/keys/alice/account-removed-[0-9]{8}T[0-9]{6}Z$'
    assert_matches "$(impact_users_new_archive_name alice key)" '^/opt/impact/admin/keys/alice/key-removed-[0-9]{8}T[0-9]{6}Z$'
}

test_archived_keys_are_listed_in_the_order_of_their_numbers() {
    need_ssh_keygen
    local number
    mkdir "$TEST_TMP/archive"
    for number in 1 2 3 4 5 6 7 8 9 10; do
        make_key "k$number"
        cp -- "$TEST_TMP/k$number.pub" "$TEST_TMP/archive/key-$number.pub"
    done
    printf 'no-pty %s\n' "$(line_of k1)" >"$TEST_TMP/archive/key-11.line"
    local -a entries=()
    mapfile -t entries < <(impact_users_archived_keys "$TEST_TMP/archive")
    assert_eq 10 "${#entries[@]}" "number of listed keys (the .line file is left out)"
    assert_eq "$TEST_TMP/archive/key-1.pub|$(print_of k1)" "${entries[0]}"
    assert_eq "$TEST_TMP/archive/key-9.pub|$(print_of k9)" "${entries[8]}"
    assert_eq "$TEST_TMP/archive/key-10.pub|$(print_of k10)" "${entries[9]}"
    assert_eq '' "$(impact_users_archived_keys "$TEST_TMP/nothing-here")"
}

test_way_back_text() {
    need_ssh_keygen
    make_key k1
    make_key k2
    mkdir "$TEST_TMP/archive"
    cp -- "$TEST_TMP/k1.pub" "$TEST_TMP/archive/key-1.pub"
    cp -- "$TEST_TMP/k2.pub" "$TEST_TMP/archive/key-2.pub"
    local text
    text="$(impact_users_bring_back_text alice alice-example 1005 0 "$TEST_TMP/archive")"
    assert_eq "  sudo impact-add-user alice-example --account alice --existing --key-file $TEST_TMP/archive/key-1.pub --fingerprint $(print_of k1)"$'\n'"  sudo impact-key add alice --key-file $TEST_TMP/archive/key-2.pub --fingerprint $(print_of k2)" "$text"
    # After --delete the account is made again with its old number.
    text="$(impact_users_bring_back_text alice alice-example 1005 1 "$TEST_TMP/archive")"
    assert_contains "$text" "sudo impact-add-user alice-example --account alice --uid 1005 --key-file $TEST_TMP/archive/key-1.pub"
    # Without a saved key the way back takes the key from GitHub.
    text="$(impact_users_bring_back_text alice alice-example 1005 0 '')"
    assert_contains "$text" 'sudo impact-add-user alice-example --account alice --existing --github'
    assert_contains "$text" 'No login key was saved'
}

# ----------------------------------------------------------------------------
# Last login, processes, texts
# ----------------------------------------------------------------------------

test_lastlog_output_is_read() {
    local header='Username         Port     From                                       Latest'
    assert_eq 'never' "$(impact_users_parse_lastlog "$header"$'\n''alice                                                              **Never logged in**')"
    assert_eq 'Tue Nov 24 20:00:01 +0000 2026 from 192.0.2.10' \
        "$(impact_users_parse_lastlog "$header"$'\n''alice            pts/0    192.0.2.10                                Tue Nov 24 20:00:01 +0000 2026')"
    # A login at the machine itself has no address.
    assert_eq 'Mon Nov 23 08:15:00 +0000 2026' \
        "$(impact_users_parse_lastlog "$header"$'\n''alice            tty1                                               Mon Nov 23 08:15:00 +0000 2026')"
    assert_eq 'never' "$(impact_users_parse_lastlog '')"
}

test_ssh_log_lines_are_read_in_both_formats() {
    # Ubuntu 24.04 writes the time in ISO form, Ubuntu 22.04 the classic form.
    assert_eq '2026-11-24T10:00:00 from 192.0.2.10' \
        "$(impact_users_parse_auth_line '2026-11-24T10:00:00.123456+00:00 workstation sshd[4242]: Accepted publickey for alice from 192.0.2.10 port 50000 ssh2: ED25519 SHA256:abc')"
    assert_eq 'Nov 24 10:00:00 from 192.0.2.10' \
        "$(impact_users_parse_auth_line 'Nov 24 10:00:00 workstation sshd[4242]: Accepted publickey for alice from 192.0.2.10 port 50000 ssh2: ED25519 SHA256:abc')"
    assert_eq '2026-11-24T10:00:00 from ::1' \
        "$(impact_users_parse_auth_line '2026-11-24T10:00:00+00:00 workstation sshd[1]: Accepted publickey for alice from ::1 port 2 ssh2')"
    assert_fails impact_users_parse_auth_line 'garbage'
    assert_fails impact_users_parse_auth_line 'Nov 24 10:00:00 workstation sshd[1]: Connection closed by 192.0.2.10'
}

test_processes_of_one_user_number_are_found() {
    local ps_output
    ps_output="$(printf '%s\n' \
        '    1     0     0 /sbin/init' \
        '  100  1005  1005 sshd: alice@notty' \
        '  101     0     0 sshd: alice [priv]' \
        '  102  1005  1005 sleep 600' \
        '  103  1006  1006 sshd: bob' \
        '  104     0  1005 sudo -u root id' \
        '  105 10050 10050 a process of number 10050')"
    assert_eq $'100 sshd: alice@notty\n102 sleep 600\n104 sudo -u root id' "$(impact_users_filter_processes 1005 <<<"$ps_output")"
    assert_eq '' "$(impact_users_filter_processes 2000 <<<"$ps_output")"
    assert_fails impact_users_processes 0
    assert_fails impact_users_processes 'abc'
}

test_texts_for_the_colleague_and_the_administrator() {
    declare -gA IMPACT_CONF=([ADMIN_CONTACT]='Alice Example (alice@example.org)' [DEPUTY_CONTACT]='')
    local text
    text="$(impact_users_colleague_text alice alice-example 'SHA256:abc')"
    assert_contains "$text" 'Workstation account: alice'
    assert_contains "$text" 'Enrolled key:        SHA256:abc'
    assert_contains "$text" 'enter alice in the field "workstation account"'
    assert_contains "$text" 'Questions: Alice Example (alice@example.org)'
    text="$(impact_users_colleague_text alice-example Alice-Example 'SHA256:abc')"
    assert_not_contains "$text" 'workstation account"'
    assert_contains "$(impact_users_docker_statement)" 'same power as root'
}

test_default_home_and_protected_accounts() {
    assert_matches "$(impact_users_default_home alice)" '^/[A-Za-z0-9._/-]+/alice$'
    assert_fails impact_users_check_changeable root
    assert_contains "$IMPACT_USERS_REASON" 'user number 0'
    assert_fails impact_users_check_changeable no-such-account-example
    assert_contains "$IMPACT_USERS_REASON" 'does not exist'
}

# ----------------------------------------------------------------------------
# Getting and choosing a key (small commands)
# ----------------------------------------------------------------------------

test_one_key_from_a_file_or_from_standard_input() {
    need_ssh_keygen
    make_key alice
    key_command
    run_cmd "$TEST_TMP/choose-key" --key-file "$TEST_TMP/alice.pub"
    assert_status 0
    assert_output_contains "chosen=$(print_of alice) given=0 source=the file $TEST_TMP/alice.pub"
    run_cmd_with_input "$(line_of alice)" "$TEST_TMP/choose-key" --fingerprint "$(print_of alice)"
    assert_status 0
    assert_output_contains "chosen=$(print_of alice) given=1 source=standard input"
    # A fingerprint of another key.
    make_key bob
    run_cmd_with_input "$(line_of alice)" "$TEST_TMP/choose-key" --fingerprint "$(print_of bob)"
    assert_status 1
    assert_output_contains 'Nothing was changed'
}

test_unaccepted_keys_end_with_exit_code_2() {
    need_ssh_keygen
    make_key alice
    make_key bob
    make_key rsa rsa
    key_command
    local input
    for input in "no-pty $(line_of alice)" "$(line_of alice)"$'\n'"$(line_of bob)" "$(line_of alice) $(line_of bob)" \
        "$(line_of rsa)" "$(cat -- "$TEST_TMP/alice")" '' 'ssh-ed25519 AAAAbroken'; do
        run_cmd_with_input "$input" "$TEST_TMP/choose-key"
        assert_status 2
    done
    run_cmd "$TEST_TMP/choose-key" --key-file "$TEST_TMP/alice.pub" --github
    assert_status 2
}

test_several_keys_need_the_fingerprint() {
    need_ssh_keygen
    make_key k1
    make_key k2
    # The small command replaces the download function of the library by one
    # that copies a prepared answer, so no network is needed.
    make_command github-keys <<END
impact_parse_args 'github' 'fingerprint' '' "\$@"
impact_https_get() { cp -- $(printf '%q' "$TEST_TMP/answer") "\$2"; IMPACT_HTTP_STATUS=200; return 0; }
impact_users_collect_keys alice-example
impact_users_choose_key alice-example
printf 'chosen=%s count=%s\n' "\$IMPACT_KEY_FINGERPRINT" "\${#IMPACT_USERS_CANDIDATES[@]}"
END
    {
        printf 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ-not-checked\n'
        cut -d' ' -f1,2 "$TEST_TMP/k1.pub"
        cut -d' ' -f1,2 "$TEST_TMP/k2.pub"
        cut -d' ' -f1,2 "$TEST_TMP/k2.pub"
    } >"$TEST_TMP/answer"
    run_cmd "$TEST_TMP/github-keys" --github
    assert_status 2
    assert_output_contains "1. $(print_of k1)"
    assert_output_contains "2. $(print_of k2)"
    assert_output_not_contains '3. '
    run_cmd "$TEST_TMP/github-keys" --github --fingerprint "$(print_of k2)"
    assert_status 0
    assert_output_contains "chosen=$(print_of k2) count=2"
    # An answer without an ed25519 key.
    printf 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ-not-checked\n' >"$TEST_TMP/answer"
    run_cmd "$TEST_TMP/github-keys" --github
    assert_status 1
    assert_output_contains 'keys of other types: 1'
}
