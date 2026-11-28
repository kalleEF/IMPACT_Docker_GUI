#!/bin/bash
# =============================================================================
# 10-text-and-versions.test.sh: unit tests for the small helpers of
# impact-common.sh (text, lists, version numbers, tools)
#
# Purpose
#   Proves that the text helpers, the version comparison and the tool lookup
#   give the documented results.
#
# Who runs it
#   tests/workstation/run-tests.sh unit   (no special rights needed)
#
# Usage
#   bash tests/workstation/run-tests.sh unit --filter 10-text
#
# What it changes on the system
#   Nothing.
#
# How to undo
#   Nothing to undo.
# =============================================================================

# Reading help: the bash constructs used here are explained at the top of
# ../lib/testlib.sh ("Reading help") and where they are first used.

# Load the test helpers that lie in ../lib. BASH_SOURCE[0] is this file.
# The lines for the checking tool "shellcheck" stand before the first command
# of the file and therefore count for the whole file.
# shellcheck disable=SC2016
# Reason for SC2016 (no expansion in single quotes): many texts in this file
# are test data, or lines of small scripts that a test writes. They must stay
# exactly as written.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/testlib.sh"

# setup runs before every test of this file.
setup() {
    load_library
}

# Library sets the fixed path.
test_library_sets_the_fixed_path() {
    assert_eq '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' "$PATH" "PATH after loading the library"
    assert_eq 'C' "$LC_ALL" "LC_ALL after loading the library"
}

# Library can be loaded twice.
test_library_can_be_loaded_twice() {
    load_library
    load_library
    assert_eq '/etc/impact/impact.conf' "$IMPACT_CONF_FILE"
}

# Trim removes blanks at both ends.
test_trim_removes_blanks_at_both_ends() {
    assert_eq 'a b' "$(impact_trim '   a b   ')"
    assert_eq 'x' "$(impact_trim $'\t x \r')" "tab and carriage return count as blanks"
    assert_eq '' "$(impact_trim '    ')"
    assert_eq 'a' "$(impact_trim 'a')"
}

# impact_lower turns upper-case letters into lower-case ones and keeps every
# other character.
test_lower() {
    assert_eq 'alice-example' "$(impact_lower 'Alice-Example')"
}

# impact_split_list splits at commas, gives an empty list for an empty text
# and keeps empty entries.
test_split_list() {
    local -a parts=()
    impact_split_list 'a,b,c' parts
    assert_eq 3 "${#parts[@]}"
    assert_eq 'b' "${parts[1]}"
    impact_split_list '' parts
    assert_eq 0 "${#parts[@]}" "an empty text gives an empty list"
    impact_split_list 'only' parts
    assert_eq 1 "${#parts[@]}"
    impact_split_list 'a,,b,' parts
    assert_eq 4 "${#parts[@]}" "empty entries are kept so that a validator can find them"
    assert_eq '' "${parts[1]}"
    assert_eq '' "${parts[3]}"
}

# impact_in_list finds only an entry that is exactly equal, never a part of
# one.
test_in_list() {
    assert_success impact_in_list b a b c
    assert_fails impact_in_list d a b c
    assert_fails impact_in_list a
    assert_fails impact_in_list 'a b' a b
}

# Display replaces control characters and cuts long text.
test_display_replaces_control_characters_and_cuts_long_text() {
    assert_eq 'a?b?c' "$(impact_display $'a\nb\tc')"
    assert_eq 'x?[31m' "$(impact_display $'x\e[31m')" "an escape sequence cannot reach the terminal"
    local long
    # printf with "%0300d" prints a number padded to 300 digits.
    long="$(printf '%0300d' 0)"
    assert_eq 203 "$(impact_display "$long" | wc -c)" "200 characters plus three dots"
    # A larger limit, as the log uses it for the command's own step texts.
    assert_eq 300 "$(impact_display "$long" 2000 | wc -c)" "a text below the given limit stays whole"
    assert_eq 13 "$(impact_display "$long" 10 | wc -c)" "10 characters plus three dots"
}

# impact_version_compare compares the parts as numbers (10 after 9) and counts
# a missing part as 0.
test_version_compare() {
    assert_eq 'lt' "$(impact_version_compare 28.3.2 28.3.3)"
    assert_eq 'eq' "$(impact_version_compare 28.3.3 28.3.3)"
    assert_eq 'gt' "$(impact_version_compare 29.10.0 28.3.3)"
    assert_eq 'gt' "$(impact_version_compare 28.10 28.9)" "numbers are compared as numbers, 10 is larger than 9"
    assert_eq 'eq' "$(impact_version_compare 28.3 28.3.0)" "a missing part counts as 0"
    assert_eq 'lt' "$(impact_version_compare 2.1.0 2.1.1)"
    assert_eq 'gt' "$(impact_version_compare 24.04 22.04)"
    assert_eq 'eq' "$(impact_version_compare 08.09 8.9)" "leading zeros are read as decimal numbers"
}

# Version compare accepts package and suffix forms.
test_version_compare_accepts_package_and_suffix_forms() {
    assert_eq 'eq' "$(impact_version_compare '5:29.1.0-1~ubuntu.22.04~jammy' 29.1.0)" "package version with epoch"
    assert_eq 'eq' "$(impact_version_compare v28.3.3 28.3.3)"
    assert_eq 'eq' "$(impact_version_compare 28.3.3-rc1 28.3.3)"
    assert_eq 'gt' "$(impact_version_compare 29.0.0+build5 28.3.3)"
}

# Version compare refuses texts without a number.
test_version_compare_refuses_texts_without_a_number() {
    assert_fails impact_version_compare abc 1.0
    assert_fails impact_version_compare 1.0 ''
    assert_fails impact_version_compare '' ''
}

# impact_version_ge accepts the same or a newer version and refuses a text
# that is no version.
test_version_ge() {
    assert_success impact_version_ge 28.3.3 28.3.3
    assert_success impact_version_ge 29.10.0 28.3.3
    assert_fails impact_version_ge 28.3.2 28.3.3
    assert_fails impact_version_ge 27.5.1 28.3.3
    # A text that is no version never counts as new enough.
    assert_fails impact_version_ge nonsense 28.3.3
    assert_fails impact_version_ge '' 28.3.3
}

# Own version reads the version file.
test_own_version_reads_the_version_file() {
    local expected
    IFS= read -r expected <"$WORKSTATION_DIR/VERSION"
    assert_eq "$expected" "$(impact_own_version)"
    assert_matches "$(impact_own_version)" '^[0-9]+\.[0-9]+\.[0-9]+$'
}

# impact_now_utc prints the UTC time in the form 2026-01-31T14:05:09Z.
test_now_utc_format() {
    assert_matches "$(impact_now_utc)" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
}

# impact_package_for_tool names the Ubuntu package of each tool, and nothing
# for an unknown one.
test_package_for_tool() {
    assert_eq 'acl' "$(impact_package_for_tool setfacl)"
    assert_eq 'acl' "$(impact_package_for_tool getfacl)"
    assert_eq 'openssh-server' "$(impact_package_for_tool sshd)"
    assert_eq 'openssh-client' "$(impact_package_for_tool ssh-keygen)"
    assert_eq 'util-linux' "$(impact_package_for_tool runuser)"
    assert_eq 'git' "$(impact_package_for_tool git)"
    assert_eq '' "$(impact_package_for_tool docker)" "docker has no simple package name"
    assert_eq '' "$(impact_package_for_tool no-such-tool)"
}

# Missing tools lists only missing ones.
test_missing_tools_lists_only_missing_ones() {
    local output status=0
    output="$(impact_missing_tools bash no-such-tool-a cat no-such-tool-b)" || status=$?
    assert_eq 1 "$status" "failure when a tool is missing"
    assert_eq $'no-such-tool-a\nno-such-tool-b' "$output"
    assert_success impact_missing_tools bash cat
}

# Install hint prints one apt get line.
test_install_hint_prints_one_apt_get_line() {
    local output
    output="$(impact_install_hint setfacl getfacl git)"
    assert_contains "$output" 'sudo apt-get install acl git' "each package is named once"
    assert_not_contains "$output" 'acl acl'
    output="$(impact_install_hint docker)"
    assert_contains "$output" 'docker-ce'
    assert_not_contains "$output" 'apt-get install'
}

# Require tools stops with exit code 1.
test_require_tools_stops_with_exit_code_1() {
    run_cmd impact_require_tools bash no-such-tool-a
    assert_status 1
    assert_output_contains 'no-such-tool-a'
    run_cmd impact_require_tools bash cat
    assert_status 0
}

# impact_contact_text names "the administrator" before the settings are read,
# then ADMIN_CONTACT, with DEPUTY_CONTACT in brackets when it is set.
test_contact_text() {
    assert_eq 'the administrator' "$(impact_contact_text)" "before the settings are loaded"
    IMPACT_CONF[ADMIN_CONTACT]='Alice Example'
    IMPACT_CONF[DEPUTY_CONTACT]=''
    assert_eq 'Alice Example' "$(impact_contact_text)"
    IMPACT_CONF[DEPUTY_CONTACT]='Bob Example'
    assert_eq 'Alice Example (or Bob Example)' "$(impact_contact_text)"
}

# Ok warn fail lines and counters.
test_ok_warn_fail_lines_and_counters() {
    local output
    output="$(impact_ok 'in order'; impact_warn 'look at this'; impact_fail 'broken')"
    assert_eq $'    OK: in order\n    WARNING: look at this\n    FAIL: broken' "$output"
    impact_warn 'one' >/dev/null
    impact_warn 'two' >/dev/null
    impact_fail 'three' >/dev/null
    assert_eq 2 "$IMPACT_WARN_COUNT"
    assert_eq 1 "$IMPACT_FAIL_COUNT"
    # An error line goes to the error channel, not to the normal output.
    assert_eq '' "$(impact_error 'to the error channel' 2>/dev/null)"
    assert_eq 'ERROR: to the error channel' "$(impact_error 'to the error channel' 2>&1)"
}
