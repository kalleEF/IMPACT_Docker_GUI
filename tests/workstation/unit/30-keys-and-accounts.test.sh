#!/bin/bash
# =============================================================================
# 30-keys-and-accounts.test.sh: unit tests for impact-accounts.sh
#
# Purpose
#   Proves the checks for public SSH keys (exactly one ssh-ed25519 key, no
#   options, no second key, no private key), the fingerprint, and the
#   read-only questions about accounts and groups.
#
# Who runs it
#   tests/workstation/run-tests.sh unit   (no special rights needed)
#   The key tests need the tool ssh-keygen and are skipped without it.
#
# Usage
#   bash tests/workstation/run-tests.sh unit --filter 30-keys
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
}

# need_ssh_keygen
#   Skips the test on a machine without ssh-keygen.
need_ssh_keygen() {
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        skip "the tool ssh-keygen is not installed (package openssh-client)"
    fi
}

# make_key NAME [TYPE]
#   Creates a key pair in the test folder and puts the public key line into
#   the variable PUBLIC_LINE and its fingerprint into PUBLIC_FINGERPRINT.
make_key() {
    local name="$1" type="${2:-ed25519}"
    # -N '' no passphrase, -C comment, -q quiet.
    ssh-keygen -q -t "$type" -N '' -C "$name@example-pc" -f "$TEST_TMP/$name"
    PUBLIC_LINE="$(cat "$TEST_TMP/$name.pub")"
    PUBLIC_FINGERPRINT="$(ssh-keygen -l -E sha256 -f "$TEST_TMP/$name.pub" | cut -d' ' -f2)"
}

# ----------------------------------------------------------------------------
# Keys
# ----------------------------------------------------------------------------

# Valid key is accepted.
test_valid_key_is_accepted() {
    need_ssh_keygen
    make_key alice
    assert_success impact_parse_ed25519_key "$PUBLIC_LINE"
    assert_eq "$(cut -d' ' -f1,2 "$TEST_TMP/alice.pub")" "$IMPACT_KEY_LINE" "the plain key line, without comment"
    assert_eq "$(cut -d' ' -f2 "$TEST_TMP/alice.pub")" "$IMPACT_KEY_BLOB"
    assert_eq 'alice@example-pc' "$IMPACT_KEY_COMMENT"
    assert_eq "$PUBLIC_FINGERPRINT" "$IMPACT_KEY_FINGERPRINT"
    assert_eq '' "$IMPACT_KEY_ERROR"
}

# Fingerprint equals ssh keygen.
test_fingerprint_equals_ssh_keygen() {
    need_ssh_keygen
    make_key alice
    assert_eq "$PUBLIC_FINGERPRINT" "$(impact_key_fingerprint "$PUBLIC_LINE")"
    assert_matches "$PUBLIC_FINGERPRINT" '^SHA256:[A-Za-z0-9+/]{43}$'
    assert_fails impact_key_fingerprint 'ssh-ed25519 not-a-key'
    assert_fails impact_key_fingerprint ''
}

# Key without comment and with windows line end.
test_key_without_comment_and_with_windows_line_end() {
    need_ssh_keygen
    make_key alice
    local bare
    bare="$(cut -d' ' -f1,2 "$TEST_TMP/alice.pub")"
    assert_success impact_parse_ed25519_key "$bare"
    assert_eq '' "$IMPACT_KEY_COMMENT"
    # Pasted from Windows: carriage return, blanks and empty lines around it.
    assert_success impact_parse_ed25519_key $'\r\n  '"$PUBLIC_LINE"$'  \r\n\r\n'
    assert_eq "$bare" "$IMPACT_KEY_LINE"
}

# Comment is reduced to safe characters.
test_comment_is_reduced_to_safe_characters() {
    need_ssh_keygen
    make_key alice
    local bare
    bare="$(cut -d' ' -f1,2 "$TEST_TMP/alice.pub")"
    assert_success impact_parse_ed25519_key "$bare"' Alice Example; $(id) `id` <x> "q"'
    assert_eq 'Alice_Example_id_id_x_q' "$IMPACT_KEY_COMMENT"
    assert_eq "$bare" "$IMPACT_KEY_LINE" "nothing of the comment reaches the key line"
}

# Empty text is refused.
test_empty_text_is_refused() {
    assert_fails impact_parse_ed25519_key ''
    assert_contains "$IMPACT_KEY_ERROR" 'No key was given'
    assert_fails impact_parse_ed25519_key $'\n  \n'
    assert_eq '' "$IMPACT_KEY_LINE"
}

# Two keys are refused.
test_two_keys_are_refused() {
    need_ssh_keygen
    make_key alice
    local first="$PUBLIC_LINE"
    make_key bob
    assert_fails impact_parse_ed25519_key "$first"$'\n'"$PUBLIC_LINE"
    assert_contains "$IMPACT_KEY_ERROR" '2 lines'
    # Two keys on one line: the second one would hide in the comment.
    assert_fails impact_parse_ed25519_key "$first $PUBLIC_LINE"
    assert_contains "$IMPACT_KEY_ERROR" 'second key'
    assert_eq '' "$IMPACT_KEY_LINE"
}

# Key line with options is refused.
test_key_line_with_options_is_refused() {
    need_ssh_keygen
    make_key alice
    local line
    for line in \
        "command=\"/bin/sh\" $PUBLIC_LINE" \
        "no-pty,command=\"x\" $PUBLIC_LINE" \
        "from=\"192.0.2.7\" $PUBLIC_LINE" \
        "restrict $PUBLIC_LINE" \
        "environment=\"PATH=/tmp\" $PUBLIC_LINE"; do
        assert_fails impact_parse_ed25519_key "$line"
        assert_contains "$IMPACT_KEY_ERROR" 'options'
        assert_eq '' "$IMPACT_KEY_LINE"
    done
}

# Other key types are refused.
test_other_key_types_are_refused() {
    need_ssh_keygen
    make_key old rsa
    assert_fails impact_parse_ed25519_key "$PUBLIC_LINE"
    assert_contains "$IMPACT_KEY_ERROR" "type 'ssh-rsa'"
    make_key curve ecdsa
    assert_fails impact_parse_ed25519_key "$PUBLIC_LINE"
    assert_contains "$IMPACT_KEY_ERROR" 'ecdsa-sha2'
    # An rsa key that claims to be ed25519 has the wrong shape.
    make_key fake rsa
    assert_fails impact_parse_ed25519_key "ssh-ed25519 $(cut -d' ' -f2 "$TEST_TMP/fake.pub")"
    assert_contains "$IMPACT_KEY_ERROR" 'shape'
}

# Private key is refused with a clear message.
test_private_key_is_refused_with_a_clear_message() {
    need_ssh_keygen
    make_key alice
    assert_fails impact_parse_ed25519_key "$(cat "$TEST_TMP/alice")"
    assert_contains "$IMPACT_KEY_ERROR" 'PRIVATE key'
    assert_eq '' "$IMPACT_KEY_LINE"
    assert_eq '' "$IMPACT_KEY_BLOB"
}

# Damaged and hostile key texts are refused.
test_damaged_and_hostile_key_texts_are_refused() {
    need_ssh_keygen
    make_key alice
    local blob
    blob="$(cut -d' ' -f2 "$TEST_TMP/alice.pub")"
    local text
    for text in \
        "ssh-ed25519 ${blob:0:60}" \
        "ssh-ed25519 ${blob}AAAA" \
        "ssh-ed25519" \
        "ssh-ed25519 " \
        "ssh-ed25519 \$(id)" \
        "ssh-ed25519 ${blob:0:40}; rm -rf /" \
        "SSH-ED25519 $blob" \
        "ssh-ed25519	$blob" \
        "hello world" \
        "$blob"; do
        if impact_parse_ed25519_key "$text"; then
            fail "the key text was accepted: $(printf '%q' "$text")"
        fi
        assert_ne '' "$IMPACT_KEY_ERROR"
        assert_eq '' "$IMPACT_KEY_LINE"
    done
}

# Ed25519 keys in a downloaded list.
test_ed25519_keys_in_a_downloaded_list() {
    need_ssh_keygen
    make_key first
    local first_line="$PUBLIC_LINE"
    make_key old rsa
    local rsa_line="$PUBLIC_LINE"
    make_key second
    local second_line="$PUBLIC_LINE"
    local found
    # The form of https://github.com/<name>.keys: one key per line, no comment.
    found="$(impact_ed25519_keys_in_text "$(printf '%s\n%s\n%s\n' "$(cut -d' ' -f1,2 <<<"$first_line")" "$(cut -d' ' -f1,2 <<<"$rsa_line")" "$(cut -d' ' -f1,2 <<<"$second_line")")")"
    assert_eq 2 "$(printf '%s\n' "$found" | wc -l)" "two ed25519 keys, the rsa key is skipped"
    assert_contains "$found" "$(cut -d' ' -f2 <<<"$first_line")"
    assert_contains "$found" "$(cut -d' ' -f2 <<<"$second_line")"
    assert_not_contains "$found" 'ssh-rsa'
    assert_fails impact_ed25519_keys_in_text "$(cut -d' ' -f1,2 <<<"$rsa_line")"
    assert_fails impact_ed25519_keys_in_text ''
    assert_fails impact_ed25519_keys_in_text 'Not Found'
}

# ----------------------------------------------------------------------------
# Accounts and groups (read-only questions about this machine)
# ----------------------------------------------------------------------------

# Account lookups for root.
test_account_lookups_for_root() {
    assert_success impact_account_exists root
    assert_eq '0' "$(impact_account_uid root)"
    assert_eq '0' "$(impact_account_gid root)"
    assert_eq '/root' "$(impact_account_home root)"
    assert_eq 'root' "$(impact_account_by_uid 0)"
    assert_success impact_group_exists root
    assert_eq '0' "$(impact_group_gid root)"
    assert_eq 'root' "$(impact_group_by_gid 0)"
    assert_success impact_account_in_group root root
}

# Lookups for names that do not exist.
test_lookups_for_names_that_do_not_exist() {
    assert_fails impact_account_exists no-such-account-xyz
    assert_fails impact_account_uid no-such-account-xyz
    assert_fails impact_account_home no-such-account-xyz
    assert_fails impact_group_exists no-such-group-xyz
    assert_fails impact_group_gid no-such-group-xyz
    assert_fails impact_group_members no-such-group-xyz
    assert_fails impact_account_in_group no-such-account-xyz root
    assert_fails impact_account_in_group root no-such-group-xyz
    assert_success impact_name_is_free no-such-name-xyz
    assert_fails impact_name_is_free root
}

# A number is never taken as a name.
test_a_number_is_never_taken_as_a_name() {
    # "getent passwd 0" would return root. A name made of digits is refused.
    assert_fails impact_account_exists 0
    assert_fails impact_account_home 0
    assert_fails impact_group_exists 0
    assert_fails impact_account_exists ''
    assert_fails impact_account_exists 'root;id'
    assert_fails impact_account_exists 'root,daemon'
    assert_fails impact_account_exists '../root'
    assert_fails impact_account_exists '-root'
    assert_fails impact_account_by_uid root
    assert_fails impact_account_by_uid -1
    assert_fails impact_group_by_gid 'x y'
}

# impact_uid_is_free and impact_gid_is_free refuse a number in use (0) and
# accept an unused one.
test_free_numbers() {
    assert_fails impact_uid_is_free 0
    assert_fails impact_gid_is_free 0
    # 59999 is inside the allowed range and unused on a normal system.
    if getent passwd 59999 >/dev/null || getent group 59999 >/dev/null; then
        skip "the number 59999 is in use on this machine"
    fi
    assert_success impact_uid_is_free 59999
    assert_success impact_gid_is_free 59999
}

# Group members lists primary members too.
test_group_members_lists_primary_members_too() {
    local members
    members="$(impact_group_members root)"
    assert_contains "$members" 'root' "root has the group root as its primary group"
}

# Repo base for needs settings and an account.
test_repo_base_for_needs_settings_and_an_account() {
    assert_fails impact_repo_base_for root
    IMPACT_CONF[REPO_BASE]='%h/Repositories'
    assert_eq '/root/Repositories' "$(impact_repo_base_for root)"
    IMPACT_CONF[REPO_BASE]='/srv/repos/%u'
    assert_eq '/srv/repos/root' "$(impact_repo_base_for root)"
    assert_fails impact_repo_base_for no-such-account-xyz
}

# Run as needs root.
test_run_as_needs_root() {
    if ((EUID == 0)); then
        skip "this test is about a call without root rights"
    fi
    run_cmd impact_run_as root true
    assert_status 1
    assert_output_contains 'needs root rights'
}

# Key copy path and record file.
test_key_copy_path_and_record_file() {
    assert_eq '/home/alice/.ssh/id_ed25519_alice-example' "$(impact_key_copy_path /home/alice Alice-Example)"
    assert_fails impact_key_copy_path /home/alice '../x'
    assert_fails impact_key_copy_path /home/alice ''
    assert_eq '/opt/impact/admin/accounts/alice.conf' "$(impact_account_record_file alice)"
    assert_fails impact_account_record_file '../alice'
    assert_fails impact_account_record_file 'a/b'
    assert_fails impact_account_record_file ''
    local status=0
    impact_account_record_load '../../etc/passwd' || status=$?
    assert_eq 1 "$status"
    if [[ ! -e /opt/impact/admin/accounts/no-such-account-xyz.conf ]]; then
        status=0
        impact_account_record_load no-such-account-xyz || status=$?
        assert_eq 1 "$status"
        assert_contains "${IMPACT_ACCOUNT_RECORD_ERRORS[*]}" 'has no record'
    fi
}
