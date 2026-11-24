#!/bin/bash
# =============================================================================
# 21-settings-file.test.sh: unit tests for reading, checking and writing the
# site settings file and the model file (impact-settings.sh)
#
# Purpose
#   Proves the file format: comments, blanks, the first "=", duplicate and
#   unknown keys, missing keys, every value rule, the port range rule; that
#   the file is read as text and never executed; and that the writer keeps
#   comments and unknown lines and never writes an invalid file.
#
# Who runs it
#   tests/workstation/run-tests.sh unit   (no special rights needed)
#
# Usage
#   bash tests/workstation/run-tests.sh unit --filter 21-settings
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
    CONF="$TEST_TMP/impact.conf"
}

# write_valid_conf
#   Writes a complete, valid settings file to $CONF.
write_valid_conf() {
    # A here-document: the lines up to END become the content of the file.
    cat >"$CONF" <<'END'
# a comment
IMPACT_CONF_VERSION=1
MIN_GUI_VERSION=2.1.0
ACCESS_MODE=tunnel
REPO_BASE=%h/Repositories
MODEL_DIR=/srv/impact/models
SHARED_GROUP=impact
SHARED_ROOTS=/mnt/disk_a/shared,/mnt/disk_b/shared
MIN_FREE_GB=200
PORT_MIN=8787
PORT_MAX=8830
KNOWN_DIRECT_CONTAINERS=data_preparation_*
ADMIN_CONTACT=Alice Example (alice@example.org)
DEPUTY_CONTACT=
END
}

# replace_line KEY NEW_LINE
#   Replaces the line of KEY in $CONF by NEW_LINE (an empty NEW_LINE removes
#   the line).
replace_line() {
    local key="$1" new_line="$2" line
    local -a lines=()
    mapfile -t lines <"$CONF"
    : >"$CONF"
    for line in "${lines[@]}"; do
        if [[ "$line" == "$key="* ]]; then
            if [[ -n "$new_line" ]]; then
                printf '%s\n' "$new_line" >>"$CONF"
            fi
        else
            printf '%s\n' "$line" >>"$CONF"
        fi
    done
}

# assert_conf_invalid EXPECTED_PART
#   Fails unless $CONF is refused with an error text that contains
#   EXPECTED_PART.
assert_conf_invalid() {
    if impact_conf_parse_file "$CONF"; then
        fail "the settings file was accepted and should be refused ($1)"
    fi
    assert_contains "${IMPACT_CONF_ERRORS[*]}" "$1" "error text"
    assert_eq 0 "${#IMPACT_CONF[@]}" "IMPACT_CONF must be empty after a refusal"
}

# ----------------------------------------------------------------------------
# The line format
# ----------------------------------------------------------------------------

test_valid_file_is_read() {
    write_valid_conf
    assert_success impact_conf_parse_file "$CONF"
    assert_eq '1' "${IMPACT_CONF[IMPACT_CONF_VERSION]}"
    assert_eq 'tunnel' "${IMPACT_CONF[ACCESS_MODE]}"
    assert_eq '%h/Repositories' "${IMPACT_CONF[REPO_BASE]}"
    assert_eq '/mnt/disk_a/shared,/mnt/disk_b/shared' "${IMPACT_CONF[SHARED_ROOTS]}"
    assert_eq 'data_preparation_*' "${IMPACT_CONF[KNOWN_DIRECT_CONTAINERS]}"
    assert_eq 'Alice Example (alice@example.org)' "${IMPACT_CONF[ADMIN_CONTACT]}"
    assert_eq '' "${IMPACT_CONF[DEPUTY_CONTACT]}"
    assert_eq 13 "${#IMPACT_CONF[@]}" "number of keys"
    assert_eq 0 "${#IMPACT_CONF_WARNINGS[@]}"
}

test_blanks_comments_and_empty_lines() {
    {
        printf '\n   \n\t# indented comment\n'
        printf '  IMPACT_CONF_VERSION =  1  \n'
        printf 'MIN_GUI_VERSION=2.1.0\nACCESS_MODE\t=\tdirect\n'
        printf 'REPO_BASE=%%h/Repositories\nMODEL_DIR=/srv/impact/models\nSHARED_GROUP=impact\n'
        printf 'SHARED_ROOTS=/mnt/disk_a/shared\nMIN_FREE_GB=0\nPORT_MIN=8787\nPORT_MAX=8787\n'
        printf 'ADMIN_CONTACT=   Alice   Example   \n'
    } >"$CONF"
    assert_success impact_conf_parse_file "$CONF"
    assert_eq '1' "${IMPACT_CONF[IMPACT_CONF_VERSION]}" "blanks around key and value are removed"
    assert_eq 'direct' "${IMPACT_CONF[ACCESS_MODE]}"
    assert_eq 'Alice   Example' "${IMPACT_CONF[ADMIN_CONTACT]}" "blanks inside a value stay"
    assert_eq '' "${IMPACT_CONF[KNOWN_DIRECT_CONTAINERS]}" "a missing optional key is present and empty"
    assert_eq '' "${IMPACT_CONF[DEPUTY_CONTACT]}"
}

test_value_is_everything_after_the_first_equals_sign() {
    write_valid_conf
    replace_line ADMIN_CONTACT 'ADMIN_CONTACT=Alice = Example # no comment "here"'
    assert_success impact_conf_parse_file "$CONF"
    assert_eq 'Alice = Example # no comment "here"' "${IMPACT_CONF[ADMIN_CONTACT]}" \
        "no quotes, no comment at the end of a line"
}

test_windows_line_ends_and_missing_last_line_end() {
    write_valid_conf
    # Turn every line end into the Windows form (carriage return + new line).
    sed -i -e 's/$/\r/' "$CONF"
    assert_success impact_conf_parse_file "$CONF"
    assert_eq 'tunnel' "${IMPACT_CONF[ACCESS_MODE]}"
    write_valid_conf
    replace_line DEPUTY_CONTACT ''
    # "printf" without a line end at the end of the file.
    printf 'DEPUTY_CONTACT=Bob Example' >>"$CONF"
    assert_success impact_conf_parse_file "$CONF"
    assert_eq 'Bob Example' "${IMPACT_CONF[DEPUTY_CONTACT]}"
}

test_byte_order_mark_is_tolerated() {
    write_valid_conf
    local content
    content="$(cat "$CONF")"
    printf '\xef\xbb\xbf%s\n' "$content" >"$CONF"
    assert_success impact_conf_parse_file "$CONF"
}

test_file_is_never_executed() {
    write_valid_conf
    # A value with shell syntax is kept as plain text.
    replace_line ADMIN_CONTACT 'ADMIN_CONTACT=$(id) `id` $HOME ${PATH}; id'
    # If the file were executed or expanded, these lines would create files.
    {
        printf 'UNKNOWN_ONE=$(touch %s/executed-1)\n' "$TEST_TMP"
        printf 'UNKNOWN_TWO=`touch %s/executed-2`\n' "$TEST_TMP"
        printf 'UNKNOWN_THREE=x; touch %s/executed-3\n' "$TEST_TMP"
    } >>"$CONF"
    assert_success impact_conf_parse_file "$CONF"
    assert_eq '$(id) `id` $HOME ${PATH}; id' "${IMPACT_CONF[ADMIN_CONTACT]}" "the value is kept as plain text"
    assert_eq 3 "${#IMPACT_CONF_WARNINGS[@]}" "three unknown keys"
    assert_missing "$TEST_TMP/executed-1"
    assert_missing "$TEST_TMP/executed-2"
    assert_missing "$TEST_TMP/executed-3"
}

test_unknown_key_gives_a_warning_and_is_ignored() {
    write_valid_conf
    printf 'FUTURE_SETTING=whatever\n' >>"$CONF"
    assert_success impact_conf_parse_file "$CONF"
    assert_eq 1 "${#IMPACT_CONF_WARNINGS[@]}"
    assert_contains "${IMPACT_CONF_WARNINGS[0]}" 'FUTURE_SETTING'
    # "-v" asks whether an entry exists.
    if [[ -v IMPACT_CONF[FUTURE_SETTING] ]]; then
        fail "the unknown key reached IMPACT_CONF"
    fi
}

test_duplicate_key_is_an_error() {
    write_valid_conf
    printf 'PORT_MIN=8787\n' >>"$CONF"
    assert_conf_invalid 'PORT_MIN appears a second time'
}

test_line_without_equals_sign_is_an_error() {
    write_valid_conf
    printf 'this is no setting\n' >>"$CONF"
    assert_conf_invalid 'neither a comment nor KEY=value'
}

test_invalid_key_is_an_error() {
    local bad
    for bad in 'lower_case=1' '1KEY=1' 'KEY WITH BLANK=1' 'KEY-DASH=1' '=1' 'export PORT_MIN=1'; do
        write_valid_conf
        printf '%s\n' "$bad" >>"$CONF"
        assert_conf_invalid 'is no valid key'
    done
}

test_missing_file() {
    assert_fails impact_conf_parse_file "$TEST_TMP/does-not-exist"
    assert_contains "${IMPACT_CONF_ERRORS[*]}" 'does not exist'
}

# ----------------------------------------------------------------------------
# Required keys and value rules
# ----------------------------------------------------------------------------

test_each_required_key_must_be_present() {
    local key
    for key in IMPACT_CONF_VERSION MIN_GUI_VERSION ACCESS_MODE REPO_BASE MODEL_DIR SHARED_GROUP \
        SHARED_ROOTS MIN_FREE_GB PORT_MIN PORT_MAX ADMIN_CONTACT; do
        write_valid_conf
        replace_line "$key" ''
        assert_conf_invalid "The required key $key is missing"
    done
}

test_optional_keys_may_be_missing() {
    write_valid_conf
    replace_line KNOWN_DIRECT_CONTAINERS ''
    replace_line DEPUTY_CONTACT ''
    assert_success impact_conf_parse_file "$CONF"
}

test_unknown_format_version_is_an_error() {
    local value
    for value in 2 0 1.0 '' one; do
        write_valid_conf
        replace_line IMPACT_CONF_VERSION "IMPACT_CONF_VERSION=$value"
        assert_conf_invalid 'IMPACT_CONF_VERSION'
    done
}

test_value_rules() {
    # Each entry: KEY, then a value that must be refused.
    local -a cases=(
        'MIN_GUI_VERSION' '2.1'
        'MIN_GUI_VERSION' 'latest'
        'ACCESS_MODE' 'Tunnel'
        'ACCESS_MODE' 'vpn'
        'ACCESS_MODE' ''
        'REPO_BASE' 'Repositories'
        'REPO_BASE' '%h/../other'
        'REPO_BASE' '%x/Repositories'
        'REPO_BASE' '%h/My Repositories'
        'MODEL_DIR' 'srv/impact'
        'MODEL_DIR' '/srv/impact/'
        'MODEL_DIR' '/srv/../etc'
        'MODEL_DIR' '/srv/my models'
        'SHARED_GROUP' 'Impact'
        'SHARED_GROUP' '9impact'
        'SHARED_GROUP' 'impact group'
        'SHARED_ROOTS' ''
        'SHARED_ROOTS' 'mnt/disk_a'
        'SHARED_ROOTS' '/mnt/disk_a/shared, /mnt/disk_b/shared'
        'SHARED_ROOTS' '/mnt/disk_a/shared,'
        'SHARED_ROOTS' '/mnt/disk_a/shared,,/mnt/disk_b/shared'
        'SHARED_ROOTS' '/mnt/disk_a/../../etc'
        'SHARED_ROOTS' '/mnt/disk a/shared'
        'MIN_FREE_GB' '-1'
        'MIN_FREE_GB' '100001'
        'MIN_FREE_GB' '2.5'
        'MIN_FREE_GB' 'many'
        'MIN_FREE_GB' '0200'
        'PORT_MIN' '1023'
        'PORT_MIN' '80'
        'PORT_MAX' '65536'
        'PORT_MAX' '8830 '"'"'x'"'"
        'KNOWN_DIRECT_CONTAINERS' 'a b'
        'KNOWN_DIRECT_CONTAINERS' 'a,,b'
        'KNOWN_DIRECT_CONTAINERS' 'a;b'
        'ADMIN_CONTACT' ''
        'DEPUTY_CONTACT' 'this text is longer than eighty characters and therefore it has to be refused by the rule!'
    )
    local index key value
    # Walk through the list two entries at a time.
    for ((index = 0; index < ${#cases[@]}; index += 2)); do
        key="${cases[index]}"
        value="${cases[index + 1]}"
        write_valid_conf
        replace_line "$key" "$key=$value"
        if impact_conf_parse_file "$CONF"; then
            fail "$key='$value' was accepted and should be refused"
        fi
        assert_contains "${IMPACT_CONF_ERRORS[*]}" "$key has the value" "error text for $key='$value'"
    done
}

test_port_range_rules() {
    write_valid_conf
    replace_line PORT_MIN 'PORT_MIN=9000'
    replace_line PORT_MAX 'PORT_MAX=8999'
    assert_conf_invalid 'is larger than PORT_MAX'
    write_valid_conf
    replace_line PORT_MIN 'PORT_MIN=8000'
    replace_line PORT_MAX 'PORT_MAX=8200'
    assert_conf_invalid 'at most 200 are allowed'
    # Exactly 200 ports are allowed, and so is a single port.
    write_valid_conf
    replace_line PORT_MIN 'PORT_MIN=8000'
    replace_line PORT_MAX 'PORT_MAX=8199'
    assert_success impact_conf_parse_file "$CONF"
    replace_line PORT_MAX 'PORT_MAX=8000'
    assert_success impact_conf_parse_file "$CONF"
}

test_check_value_explains_the_rule() {
    assert_fails impact_conf_check_value PORT_MIN 80
    assert_contains "$IMPACT_CHECK_REASON" '1024 to 65535'
    assert_success impact_conf_check_value PORT_MIN 8787
    assert_eq '' "$IMPACT_CHECK_REASON"
    assert_fails impact_conf_check_value NO_SUCH_KEY x
    assert_contains "$IMPACT_CHECK_REASON" 'unknown key'
}

test_defaults_are_valid_values() {
    local key value
    for key in IMPACT_CONF_VERSION MIN_GUI_VERSION ACCESS_MODE REPO_BASE MODEL_DIR SHARED_GROUP MIN_FREE_GB PORT_MIN PORT_MAX; do
        value="$(impact_conf_default "$key")"
        assert_ne '' "$value" "default of $key"
        assert_success impact_conf_check_value "$key" "$value"
    done
    assert_eq '' "$(impact_conf_default SHARED_ROOTS)" "the storage roots have no default"
    assert_eq '' "$(impact_conf_default ADMIN_CONTACT)" "the contact has no default"
    assert_eq 'tunnel' "$(impact_conf_default ACCESS_MODE)"
    assert_eq '8787' "$(impact_conf_default PORT_MIN)"
    assert_eq '8830' "$(impact_conf_default PORT_MAX)"
}

# ----------------------------------------------------------------------------
# Trust in the file (owner and mode)
# ----------------------------------------------------------------------------

test_trust_check_refuses_files_that_others_can_change() {
    write_valid_conf
    chmod 644 "$CONF"
    if ((EUID == 0)); then
        chmod 755 "$TEST_TMP"
        assert_success impact_file_is_trusted "$CONF"
        chmod 664 "$CONF"
        assert_fails impact_file_is_trusted "$CONF"
        assert_contains "$IMPACT_CHECK_REASON" 'can be changed by accounts other than root'
        chmod 644 "$CONF"
        chmod 777 "$TEST_TMP"
        assert_fails impact_file_is_trusted "$CONF"
        chmod 755 "$TEST_TMP"
    else
        # Without root rights the file belongs to the test account.
        assert_fails impact_file_is_trusted "$CONF"
        assert_contains "$IMPACT_CHECK_REASON" 'must belong to root'
    fi
}

test_trust_check_refuses_symbolic_links_and_missing_files() {
    write_valid_conf
    ln -s "$CONF" "$TEST_TMP/link.conf"
    assert_fails impact_file_is_trusted "$TEST_TMP/link.conf"
    assert_fails impact_file_is_trusted "$TEST_TMP/missing.conf"
}

# ----------------------------------------------------------------------------
# Writing
# ----------------------------------------------------------------------------

# fill_values ARRAY_NAME
#   Fills an associative array of the caller with a complete valid set.
fill_values() {
    # "local -n" gives this function a second name for the caller's array.
    local -n target="$1"
    target=(
        [IMPACT_CONF_VERSION]=1 [MIN_GUI_VERSION]=2.1.0 [ACCESS_MODE]=tunnel
        [REPO_BASE]='%h/Repositories' [MODEL_DIR]=/srv/impact/models [SHARED_GROUP]=impact
        [SHARED_ROOTS]=/mnt/disk_a/shared [MIN_FREE_GB]=200 [PORT_MIN]=8787 [PORT_MAX]=8830
        [KNOWN_DIRECT_CONTAINERS]='' [ADMIN_CONTACT]='Alice Example' [DEPUTY_CONTACT]=''
    )
}

test_new_file_has_every_key_with_a_comment_and_reads_back() {
    local -A values=()
    fill_values values
    assert_success impact_conf_write "$CONF" values
    assert_success impact_conf_parse_file "$CONF"
    assert_eq '/mnt/disk_a/shared' "${IMPACT_CONF[SHARED_ROOTS]}"
    local key previous line
    for key in "${IMPACT_CONF_KEYS[@]}"; do
        # The line before each key must be a comment that explains it.
        previous=''
        while IFS= read -r line; do
            if [[ "$line" == "$key="* ]]; then
                break
            fi
            previous="$line"
        done <"$CONF"
        assert_matches "$previous" '^#' "the line before $key"
    done
    assert_eq '644' "$(stat -c '%a' "$CONF")"
}

test_example_file_matches_the_writer() {
    # The delivered example is exactly what the writer produces for the
    # example values, so the two can never drift apart.
    local -A values=()
    fill_values values
    values[SHARED_ROOTS]='/mnt/disk_a/shared,/mnt/disk_b/shared'
    values[ADMIN_CONTACT]='Alice Example (alice@example.org)'
    assert_success impact_conf_write "$CONF" values
    if ! diff -- "$WORKSTATION_DIR/etc/impact.conf.example" "$CONF"; then
        fail "workstation/etc/impact.conf.example differs from the output of impact_conf_write"
    fi
    assert_success impact_conf_parse_file "$WORKSTATION_DIR/etc/impact.conf.example"
}

test_update_keeps_comments_unknown_lines_and_order() {
    cat >"$CONF" <<'END'
# Site notes of the administrator: keep this line.
PORT_MAX=8830
PORT_MIN  =  8787

# A note above the group.
SHARED_GROUP=impact
FUTURE_SETTING=keep me
IMPACT_CONF_VERSION=1
MIN_GUI_VERSION=2.1.0
ACCESS_MODE=tunnel
REPO_BASE=%h/Repositories
MODEL_DIR=/srv/impact/models
SHARED_ROOTS=/mnt/disk_a/shared
MIN_FREE_GB=200
ADMIN_CONTACT=Alice Example
END
    local -A values=()
    fill_values values
    values[PORT_MAX]=8850
    values[DEPUTY_CONTACT]='Bob Example'
    assert_success impact_conf_needs_write "$CONF" values
    assert_success impact_conf_write "$CONF" values
    assert_file_contains "$CONF" '# Site notes of the administrator: keep this line.'
    assert_file_contains "$CONF" '# A note above the group.'
    assert_file_contains "$CONF" 'FUTURE_SETTING=keep me'
    assert_file_contains "$CONF" 'PORT_MAX=8850'
    assert_file_contains "$CONF" 'PORT_MIN  =  8787'
    assert_file_contains "$CONF" 'DEPUTY_CONTACT=Bob Example'
    assert_file_contains "$CONF" 'KNOWN_DIRECT_CONTAINERS='
    assert_eq 'PORT_MAX=8850' "$(sed -n '2p' "$CONF")" "the changed line stays at its place"
    assert_success impact_conf_parse_file "$CONF"
    assert_eq '8850' "${IMPACT_CONF[PORT_MAX]}"
    assert_eq 'Bob Example' "${IMPACT_CONF[DEPUTY_CONTACT]}"
}

test_second_write_changes_nothing() {
    local -A values=()
    fill_values values
    assert_success impact_conf_write "$CONF" values
    assert_fails impact_conf_needs_write "$CONF" values
    local before after
    before="$(sha256sum <"$CONF")"
    assert_success impact_conf_write "$CONF" values
    after="$(sha256sum <"$CONF")"
    assert_eq "$before" "$after" "content after a second write"
    values[MIN_FREE_GB]=300
    assert_success impact_conf_needs_write "$CONF" values
}

test_invalid_values_are_never_written() {
    local -A values=()
    fill_values values
    assert_success impact_conf_write "$CONF" values
    local before
    before="$(sha256sum <"$CONF")"
    values[PORT_MIN]=80
    run_cmd impact_conf_write "$CONF" values
    assert_status 1
    assert_output_contains 'PORT_MIN'
    assert_eq "$before" "$(sha256sum <"$CONF")" "the file must be untouched"
    unset -v 'values[ADMIN_CONTACT]'
    values[PORT_MIN]=8787
    run_cmd impact_conf_write "$CONF" values
    assert_status 1
    assert_output_contains 'ADMIN_CONTACT is missing'
}

test_write_refuses_a_symbolic_link_as_target() {
    local -A values=()
    fill_values values
    : >"$TEST_TMP/elsewhere"
    ln -s "$TEST_TMP/elsewhere" "$CONF"
    run_cmd impact_conf_write "$CONF" values
    assert_status 1
    assert_output_contains 'symbolic link'
    assert_eq 0 "$(wc -c <"$TEST_TMP/elsewhere")" "nothing was written through the link"
}

test_atomic_write_leaves_no_temporary_file() {
    printf 'new content\n' | impact_write_file_atomic "$TEST_TMP/target.txt" 600
    assert_eq 'new content' "$(cat "$TEST_TMP/target.txt")"
    assert_eq '600' "$(stat -c '%a' "$TEST_TMP/target.txt")"
    # Hidden files count as well: only the target may be in the folder.
    assert_eq "$TEST_TMP/target.txt" "$(find "$TEST_TMP" -mindepth 1 ! -name 'run.*')"
    run_cmd impact_write_file_atomic "$TEST_TMP/no-such-folder/x" 600
    assert_status 1
}

# ----------------------------------------------------------------------------
# The model file
# ----------------------------------------------------------------------------

# load_site_for_models
#   Puts the site values that the model rules need into IMPACT_CONF.
load_site_for_models() {
    IMPACT_CONF[MODEL_DIR]=/srv/impact/models
    IMPACT_CONF[SHARED_GROUP]=impact
    IMPACT_CONF[SHARED_ROOTS]=/mnt/disk_a/shared,/mnt/disk_b/shared
}

write_valid_model() {
    cat >"$TEST_TMP/model.conf" <<'END'
MODEL_CONF_VERSION=1
REPO_URL=git@github.com:example-org/Example-Model.git
BRANCH=
STORAGE_NAME=Example
STORAGE_ROOTS=/mnt/disk_a/shared
END
}

test_model_file_valid() {
    load_site_for_models
    write_valid_model
    assert_success impact_model_parse_file "$TEST_TMP/model.conf"
    assert_eq 'git@github.com:example-org/Example-Model.git' "${IMPACT_MODEL[REPO_URL]}"
    assert_eq '' "${IMPACT_MODEL[BRANCH]}"
    assert_eq 'Example' "${IMPACT_MODEL[STORAGE_NAME]}"
    assert_eq '/mnt/disk_a/shared' "${IMPACT_MODEL[STORAGE_ROOTS]}"
    # BRANCH may be missing altogether.
    sed -i -e '/^BRANCH=/d' "$TEST_TMP/model.conf"
    assert_success impact_model_parse_file "$TEST_TMP/model.conf"
    assert_eq '' "${IMPACT_MODEL[BRANCH]}"
}

test_model_file_refusals() {
    load_site_for_models
    local -a cases=(
        'MODEL_CONF_VERSION' '2'
        'REPO_URL' 'https://github.com/example-org/Example-Model'
        'REPO_URL' 'git@evil.example:example-org/Example-Model.git'
        'REPO_URL' 'git@github.com:example-org/Example-Model'
        'BRANCH' '-x'
        'BRANCH' 'a..b'
        'BRANCH' 'has blank'
        'STORAGE_NAME' '../Example'
        'STORAGE_NAME' ''
        'STORAGE_NAME' 'a/b'
        'STORAGE_ROOTS' ''
        'STORAGE_ROOTS' '/mnt/disk_c/shared'
        'STORAGE_ROOTS' '/mnt/disk_a/shared,/etc'
        'STORAGE_ROOTS' '/mnt/disk_a/shared/'
    )
    local index key value
    for ((index = 0; index < ${#cases[@]}; index += 2)); do
        key="${cases[index]}"
        value="${cases[index + 1]}"
        write_valid_model
        sed -i -e "/^$key=/d" "$TEST_TMP/model.conf"
        printf '%s=%s\n' "$key" "$value" >>"$TEST_TMP/model.conf"
        if impact_model_parse_file "$TEST_TMP/model.conf"; then
            fail "model file with $key='$value' was accepted"
        fi
        assert_contains "${IMPACT_MODEL_ERRORS[*]}" "$key has the value"
        assert_eq 0 "${#IMPACT_MODEL[@]}" "IMPACT_MODEL must be empty after a refusal"
    done
    write_valid_model
    sed -i -e '/^REPO_URL=/d' "$TEST_TMP/model.conf"
    assert_fails impact_model_parse_file "$TEST_TMP/model.conf"
    assert_contains "${IMPACT_MODEL_ERRORS[*]}" 'The required key REPO_URL is missing'
}

test_model_roots_must_be_listed_in_shared_roots() {
    load_site_for_models
    assert_success impact_model_check_value STORAGE_ROOTS /mnt/disk_a/shared,/mnt/disk_b/shared
    assert_fails impact_model_check_value STORAGE_ROOTS /mnt/disk_a/shared,/mnt/other
    # Without loaded site settings no root can be confirmed.
    IMPACT_CONF=()
    assert_fails impact_model_check_value STORAGE_ROOTS /mnt/disk_a/shared
}

test_model_dir_and_load_refuse_bad_names() {
    load_site_for_models
    assert_eq '/srv/impact/models/Example-Model' "$(impact_model_dir Example-Model)"
    assert_fails impact_model_dir '../etc'
    assert_fails impact_model_dir ''
    local status=0
    impact_model_load '../../etc/passwd' || status=$?
    assert_eq 1 "$status"
    assert_contains "${IMPACT_MODEL_ERRORS[*]}" 'no valid model name'
    status=0
    impact_model_load 'No-Such-Model' || status=$?
    assert_eq 1 "$status"
    assert_contains "${IMPACT_MODEL_ERRORS[*]}" 'is not set up'
}

test_model_file_write_and_update() {
    load_site_for_models
    local -A values=(
        [MODEL_CONF_VERSION]=1 [REPO_URL]='git@github.com:example-org/Example-Model.git'
        [BRANCH]='' [STORAGE_NAME]=Example [STORAGE_ROOTS]=/mnt/disk_a/shared
    )
    local file="$TEST_TMP/model.conf"
    if ((EUID == 0)) && ! getent group impact >/dev/null; then
        # As root the writer sets the group of the file; without the group
        # that step cannot work. The system tests cover it.
        skip "root without a group named impact; covered by the system tests"
    fi
    assert_success impact_model_conf_write "$file" values
    assert_eq '640' "$(stat -c '%a' "$file")"
    assert_success impact_model_parse_file "$file"
    assert_fails impact_model_conf_needs_write "$file" values
    printf '# note of the administrator\n' >>"$file"
    values[STORAGE_ROOTS]=/mnt/disk_a/shared,/mnt/disk_b/shared
    assert_success impact_model_conf_needs_write "$file" values
    assert_success impact_model_conf_write "$file" values
    assert_file_contains "$file" '# note of the administrator'
    assert_file_contains "$file" 'STORAGE_ROOTS=/mnt/disk_a/shared,/mnt/disk_b/shared'
    values[STORAGE_NAME]='../x'
    run_cmd impact_model_conf_write "$file" values
    assert_status 1
    assert_file_contains "$file" 'STORAGE_NAME=Example'
}
