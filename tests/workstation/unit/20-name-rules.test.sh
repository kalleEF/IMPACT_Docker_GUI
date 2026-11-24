#!/bin/bash
# =============================================================================
# 20-name-rules.test.sh: unit tests for the validators of impact-settings.sh
#
# Purpose
#   Proves that every rule for names, paths, numbers and GitHub addresses
#   accepts the valid forms and refuses the invalid and the hostile ones
#   (blanks, quotes, ";", "$(...)", "../").
#
# Who runs it
#   tests/workstation/run-tests.sh unit   (no special rights needed)
#
# Usage
#   bash tests/workstation/run-tests.sh unit --filter 20-name
#
# What it changes on the system
#   Nothing.
#
# How to undo
#   Nothing to undo.
# =============================================================================

# Reading help: the bash constructs used here are explained at the top of
# ../lib/testlib.sh ("Reading help") and where they are first used.

# The lines for the checking tool "shellcheck" stand before the first command
# of the file and therefore count for the whole file.
# shellcheck disable=SC2016,SC2088
# Reason for SC2016 (no expansion in single quotes) and SC2088 (no expansion
# of "~" in quotes): many texts in this file are test data and must stay
# exactly as written.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/testlib.sh"

setup() {
    load_library
}

# Texts that no validator may accept. The single quotes keep every character
# as written: nothing here is ever executed.
HOSTILE_TEXTS=(
    '' ' ' 'a b' 'a;b' 'a;rm -rf /' '$(id)' '`id`' 'a$(id)' "a'b" 'a"b' '../etc' 'a/../b'
    'a|b' 'a&b' 'a>b' 'a*b' 'a\b' $'a\nb' $'a\tb' '-rf' '--help' 'a,b' 'ä'
)

# all_hostile_refused VALIDATOR
#   Fails when the validator accepts one of the hostile texts.
all_hostile_refused() {
    local text
    for text in "${HOSTILE_TEXTS[@]}"; do
        if "$1" "$text"; then
            fail "$1 accepted the hostile text: $(printf '%q' "$text")"
        fi
    done
}

test_account_name() {
    local name
    for name in alice a alice-example alice_example a1 user-2_x abcdefghijklmnopqrstuvwxyz012345; do
        assert_success impact_valid_account_name "$name"
    done
    # 33 characters, a leading digit, upper case, a dot: all refused.
    for name in abcdefghijklmnopqrstuvwxyz0123456 1alice Alice alice.example _alice -alice root/x; do
        assert_fails impact_valid_account_name "$name"
    done
    all_hostile_refused impact_valid_account_name
}

test_group_name() {
    assert_success impact_valid_group_name impact
    assert_success impact_valid_group_name impact-test_2
    assert_fails impact_valid_group_name Impact
    assert_fails impact_valid_group_name 9group
    all_hostile_refused impact_valid_group_name
}

test_github_name() {
    local name
    for name in alice alice-example Alice-Example a 1alice alice_corp a-b-c abcdefghijklmnopqrstuvwxyz0123456789abc; do
        assert_success impact_valid_github_name "$name"
    done
    # 40 characters, a hyphen at an end, a dot: all refused.
    for name in abcdefghijklmnopqrstuvwxyz0123456789abcd -alice alice- alice.example _alice alice_; do
        assert_fails impact_valid_github_name "$name"
    done
    all_hostile_refused impact_valid_github_name
}

test_model_name() {
    local name
    for name in Example-Model IMPACTncd_Germany model.v2 1model a; do
        assert_success impact_valid_model_name "$name"
    done
    for name in .hidden -model _model . .. Example.partial 'a/b'; do
        assert_fails impact_valid_model_name "$name"
    done
    # 80 characters are accepted, 81 are refused.
    assert_success impact_valid_model_name "$(printf 'a%.0s' {1..80})"
    assert_fails impact_valid_model_name "$(printf 'a%.0s' {1..81})"
    all_hostile_refused impact_valid_model_name
}

test_storage_name() {
    assert_success impact_valid_storage_name Example
    assert_success impact_valid_storage_name Model_1.b-c
    assert_fails impact_valid_storage_name .x
    assert_success impact_valid_storage_name "$(printf 'a%.0s' {1..40})"
    assert_fails impact_valid_storage_name "$(printf 'a%.0s' {1..41})"
    all_hostile_refused impact_valid_storage_name
}

test_abs_path() {
    local path
    for path in /mnt/disk_a/shared /srv/impact/models /a /a.b/c-d/e_f /home/alice/Repositories; do
        assert_success impact_valid_abs_path "$path"
    done
    for path in / relative/path mnt/disk /mnt/disk_a/ /mnt//disk /mnt/../etc /mnt/./x /mnt/x/.. /mnt/x/. \
        '/mnt/my disk' '/mnt/a;b' '/mnt/$(id)' '/mnt/%h' '~/x' '/mnt/a,b'; do
        assert_fails impact_valid_abs_path "$path"
    done
    all_hostile_refused impact_valid_abs_path
    # A part that only starts with dots is a normal name.
    assert_success impact_valid_abs_path /mnt/..data
    assert_success impact_valid_abs_path /mnt/.hidden
}

test_repo_base() {
    local value
    for value in '%h/Repositories' '%h/work/%u' '/srv/repos/%u' '/srv/repos' '%h'; do
        assert_success impact_valid_repo_base "$value"
    done
    for value in 'Repositories' '%u/Repositories' '%x/Repositories' '%h/../x' '%h/Repo sitories' '%h/' '%' '%h/%' \
        '%h/$(id)' '%h;id'; do
        assert_fails impact_valid_repo_base "$value"
    done
}

test_repo_base_template_expansion() {
    assert_eq '/home/alice/Repositories' "$(impact_expand_repo_base_template '%h/Repositories' /home/alice alice)"
    assert_eq '/srv/repos/alice' "$(impact_expand_repo_base_template '/srv/repos/%u' /home/alice alice)"
    assert_eq '/home/alice/x/alice/alice' "$(impact_expand_repo_base_template '%h/x/%u/%u' /home/alice alice)"
    # A character that is special in bash replacements stays as it is.
    assert_eq '/home/a&b/R' "$(impact_expand_repo_base_template '%h/R' '/home/a&b' x)"
}

test_branch_name() {
    local name
    for name in main dev-v2.1 feature/new-inputs release_1 a 1.x; do
        assert_success impact_valid_branch_name "$name"
    done
    for name in -main .hidden a..b a//b a/ a. a.lock x/.y x.lock/y HEAD 'a b' 'a~1' 'a^' 'a:b' 'a@{1}' 'a?'; do
        assert_fails impact_valid_branch_name "$name"
    done
    all_hostile_refused impact_valid_branch_name
}

test_whole_number_and_port() {
    assert_success impact_valid_whole_number 0 0 10
    assert_success impact_valid_whole_number 10 0 10
    assert_fails impact_valid_whole_number 11 0 10
    assert_fails impact_valid_whole_number 007 0 10
    assert_fails impact_valid_whole_number -1 0 10
    assert_fails impact_valid_whole_number 1.5 0 10
    assert_fails impact_valid_whole_number '' 0 10
    assert_fails impact_valid_whole_number 1e3 0 100000
    assert_fails impact_valid_whole_number 12345678901234567890 0 100000
    assert_success impact_valid_port 1024
    assert_success impact_valid_port 65535
    assert_fails impact_valid_port 1023
    assert_fails impact_valid_port 65536
    assert_fails impact_valid_port 08787
    all_hostile_refused impact_valid_port
}

test_user_number() {
    assert_success impact_valid_user_number 1000
    assert_success impact_valid_user_number 60000
    assert_fails impact_valid_user_number 999
    assert_fails impact_valid_user_number 0
    assert_fails impact_valid_user_number 60001
    all_hostile_refused impact_valid_user_number
}

test_gui_version() {
    assert_success impact_valid_gui_version 2.1.0
    assert_success impact_valid_gui_version 10.20.30
    assert_fails impact_valid_gui_version 2.1
    assert_fails impact_valid_gui_version 1.2.3.4
    assert_fails impact_valid_gui_version v2.1.0
    assert_fails impact_valid_gui_version 2.1.x
    all_hostile_refused impact_valid_gui_version
}

test_container_pattern() {
    assert_success impact_valid_container_pattern 'data_preparation_*'
    assert_success impact_valid_container_pattern 'prep-?.x'
    assert_fails impact_valid_container_pattern 'a b'
    assert_fails impact_valid_container_pattern 'a[1]'
    assert_fails impact_valid_container_pattern ''
}

test_contact() {
    assert_success impact_valid_contact 'Alice Example (alice@example.org)'
    assert_success impact_valid_contact 'A'
    # Letters with accents are valid and count as one character each.
    assert_success impact_valid_contact 'Zoë Müller-Example, room 1.01'
    assert_success impact_valid_contact "$(printf 'ä%.0s' {1..80})"
    assert_fails impact_valid_contact "$(printf 'ä%.0s' {1..81})"
    assert_fails impact_valid_contact ''
    assert_fails impact_valid_contact $'two\nlines'
    assert_fails impact_valid_contact $'tab\there'
    assert_fails impact_valid_contact $'bell\a'
    # Bytes that are no valid UTF-8 are refused.
    assert_fails impact_valid_contact $'broken \xff\xfe text'
    # The language setting of the caller is back in place afterwards.
    assert_eq 'C' "$LC_ALL"
}

test_fingerprint_form() {
    assert_success impact_valid_fingerprint 'SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU'
    assert_fails impact_valid_fingerprint '+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU'
    assert_fails impact_valid_fingerprint 'SHA256:short'
    assert_fails impact_valid_fingerprint 'MD5:16:27:ac:a5:76:28:2d:36:63:1b:56:4d:eb:df:a6:48'
    all_hostile_refused impact_valid_fingerprint
}

test_github_address_ssh_form() {
    assert_success impact_parse_github_address 'git@github.com:example-org/Example-Model.git'
    assert_eq 'example-org' "$IMPACT_GH_OWNER"
    assert_eq 'Example-Model' "$IMPACT_GH_REPO"
    assert_eq 'git@github.com:example-org/Example-Model.git' "$IMPACT_GH_SSH_URL"
    assert_eq 'https://github.com/example-org/Example-Model.git' "$IMPACT_GH_HTTPS_URL"
    # The ".git" at the end may be missing.
    assert_success impact_parse_github_address 'git@github.com:example-org/Example-Model'
    assert_eq 'git@github.com:example-org/Example-Model.git' "$IMPACT_GH_SSH_URL"
}

test_github_address_https_form() {
    local address
    for address in 'https://github.com/example-org/Example-Model' 'https://github.com/example-org/Example-Model.git' \
        'https://github.com/example-org/Example-Model/'; do
        assert_success impact_parse_github_address "$address"
        assert_eq 'git@github.com:example-org/Example-Model.git' "$IMPACT_GH_SSH_URL" "stored form of $address"
    done
    assert_success impact_parse_github_address 'https://github.com/example-org/.github'
    assert_eq '.github' "$IMPACT_GH_REPO"
    assert_success impact_parse_github_address 'https://github.com/a/model_1.2'
    assert_eq 'model_1.2' "$IMPACT_GH_REPO"
}

test_github_address_refusals() {
    local address
    for address in \
        '' 'example-org/Example-Model' 'github.com/example-org/Example-Model' \
        'http://github.com/example-org/Example-Model' \
        'https://gitlab.com/example-org/Example-Model' \
        'https://github.com.evil.example/example-org/Example-Model' \
        'https://evil.example/github.com/example-org/Example-Model' \
        'https://user@github.com/example-org/Example-Model' \
        'https://github.com/example-org' 'https://github.com/example-org/' \
        'https://github.com/example-org/a/b' 'https://github.com/../x' 'https://github.com/a/..' \
        'https://github.com/a/.git' 'git@github.com:a/.git' \
        'git@github.com:-oProxyCommand=id/x.git' 'git@github.com:a/-x.git' \
        'git@github.com/example-org/Example-Model.git' \
        'git@evil.example:example-org/Example-Model.git' \
        'ssh://git@github.com/example-org/Example-Model.git' \
        'git@github.com:example org/Example-Model.git' \
        'git@github.com:example-org/Example-Model.git;id' \
        'git@github.com:example-org/$(id).git' \
        'https://github.com/example-org/Example-Model?x=1' \
        'https://github.com/example-org/Example-Model#frag' \
        '--upload-pack=id' 'file:///etc/passwd' '/srv/git/model.git'; do
        if impact_parse_github_address "$address"; then
            fail "the address was accepted: $address"
        fi
        assert_eq '' "$IMPACT_GH_SSH_URL" "no result may be left after a refusal"
    done
}

test_repo_url_stored_form() {
    assert_success impact_valid_repo_url 'git@github.com:example-org/Example-Model.git'
    # Only the exact stored form is valid in a model file.
    assert_fails impact_valid_repo_url 'git@github.com:example-org/Example-Model'
    assert_fails impact_valid_repo_url 'https://github.com/example-org/Example-Model'
    assert_fails impact_valid_repo_url ''
}
