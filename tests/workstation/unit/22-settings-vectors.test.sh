#!/bin/bash
# =============================================================================
# 22-settings-vectors.test.sh: the shared test cases of the settings format
#
# Purpose
#   Runs every case of tests/workstation/vectors/settings-lines.vectors
#   against the reader of KEY=value files (impact_kv_parse), and every case
#   of tests/workstation/vectors/settings-values.vectors against the value
#   rules (impact_conf_check_value). The GUI reads the same settings file;
#   its tests read the same two files, so both readers keep exactly the same
#   rules (line ends, blanks, zero bytes, encoding, numbers, lengths,
#   refused characters, duplicate keys, storage roots).
#
# Who runs it
#   tests/workstation/run-tests.sh unit   (no special rights needed)
#
# Usage
#   bash tests/workstation/run-tests.sh unit --filter 22-settings
#
# Examples
#   bash tests/workstation/run-tests.sh unit --filter vectors
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
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/testlib.sh"

VECTORS="$TESTS_DIR/vectors"

setup() {
    load_library
}

# decode TEXT
#   Prints TEXT with its escapes replaced (\n \r \t \\ \xHH), as the header
#   of the vector files describes. printf '%b' understands exactly these
#   escapes (and a few more, which the vector files never use). The result
#   goes to standard output, so a zero byte (\x00) reaches a file intact.
decode() {
    printf '%b' "$1"
}

# A case line has the form "<ACCEPT|REFUSE> <name or KEY> <text>"; the text
# is everything after the second space. split_case fills CASE_EXPECT,
# CASE_NAME and CASE_TEXT from one such line.
split_case() {
    local line="$1" rest
    CASE_EXPECT="${line%% *}"
    rest="${line#* }"
    CASE_NAME="${rest%% *}"
    if [[ "$rest" == *' '* ]]; then
        CASE_TEXT="${rest#* }"
    else
        CASE_TEXT=''
    fi
}

# The reader of KEY=value files accepts exactly the ACCEPT cases, finds the
# listed pairs in the order of the file, and refuses every REFUSE case.
test_every_line_case() {
    local line problems='' count=0 name='' expect='' file="$TEST_TMP/case.conf"
    local -a wanted=()
    # check_line_case: runs the case collected so far (name, expect, file,
    # wanted pairs) and adds a text to "problems" when it does not behave
    # as the vector file says.
    check_line_case() {
        [[ -n "$name" ]] || return 0
        count=$((count + 1))
        local -A values=()
        local -a order=() errors=() found=()
        local status=0 key
        impact_kv_parse "$file" values order errors || status=$?
        if [[ "$expect" == 'ACCEPT' ]]; then
            if ((status != 0)); then
                problems+="  $name: refused (${errors[*]})"$'\n'
                return 0
            fi
            for key in "${order[@]}"; do
                found+=("$key=${values[$key]}")
            done
            if [[ "$(printf '%s\n' "${found[@]}")" != "$(printf '%s\n' "${wanted[@]}")" ]]; then
                problems+="  $name: found $(printf '[%s] ' "${found[@]}"), expected $(printf '[%s] ' "${wanted[@]}")"$'\n'
            fi
        elif ((status == 0)); then
            problems+="  $name: accepted, but the case says REFUSE"$'\n'
        fi
    }
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == '=> '* ]]; then
            local pair
            printf -v pair '%b' "${line#=> }"
            wanted+=("$pair")
            continue
        fi
        if [[ "$line" == ACCEPT\ * || "$line" == REFUSE\ * ]]; then
            check_line_case
            split_case "$line"
            name="$CASE_NAME"
            expect="$CASE_EXPECT"
            wanted=()
            decode "$CASE_TEXT" >"$file"
        fi
    done <"$VECTORS/settings-lines.vectors"
    check_line_case
    ((count >= 40)) || fail "only $count cases were found in settings-lines.vectors"
    assert_eq '' "$problems" "cases that behave differently from the vector file"
}

# The value rules accept exactly the ACCEPT cases and refuse the REFUSE
# cases, key by key.
test_every_value_case() {
    local line problems='' count=0 value
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == ACCEPT\ * || "$line" == REFUSE\ * ]] || continue
        split_case "$line"
        count=$((count + 1))
        printf -v value '%b' "$CASE_TEXT"
        if impact_conf_check_value "$CASE_NAME" "$value"; then
            [[ "$CASE_EXPECT" == 'ACCEPT' ]] || problems+="  REFUSE $CASE_NAME $CASE_TEXT: accepted"$'\n'
        else
            [[ "$CASE_EXPECT" == 'REFUSE' ]] || problems+="  ACCEPT $CASE_NAME $CASE_TEXT: refused ($IMPACT_CHECK_REASON)"$'\n'
        fi
    done <"$VECTORS/settings-values.vectors"
    ((count >= 100)) || fail "only $count cases were found in settings-values.vectors"
    assert_eq '' "$problems" "cases that behave differently from the vector file"
}

# A whole settings file goes through the same reader: a valid file with
# CR LF line ends is accepted; the same file with one zero byte, or with a
# lone CR, is refused with a message that names the cause.
test_whole_file_with_crlf_zero_byte_and_lone_cr() {
    local conf="$TEST_TMP/impact.conf"
    printf '%s\r\n' 'IMPACT_CONF_VERSION=1' 'MIN_GUI_VERSION=2.1.0' 'ACCESS_MODE=tunnel' \
        'REPO_BASE=%h/Repositories' 'MODEL_DIR=/srv/impact/models' 'SHARED_GROUP=impact' \
        'SHARED_ROOTS=/mnt/disk_a/shared' 'MIN_FREE_GB=200' 'PORT_MIN=8787' 'PORT_MAX=8830' \
        'ADMIN_CONTACT=Alice Example' >"$conf"
    assert_success impact_conf_parse_file "$conf"
    assert_eq 'Alice Example' "${IMPACT_CONF[ADMIN_CONTACT]}"
    printf 'ACCESS_\0MODE=tunnel\n' >>"$conf"
    assert_fails impact_conf_parse_file "$conf"
    assert_contains "${IMPACT_CONF_ERRORS[*]}" 'zero byte (NUL)'
    sed -i -e 's/ACCESS_MODE=tunnel\r$/ACCESS_MODE=tunnel\rPORT_MIN=8788/' -e '$d' -- "$conf"
    assert_fails impact_conf_parse_file "$conf"
    assert_contains "${IMPACT_CONF_ERRORS[*]}" 'carriage return (CR) inside the line'
}

# MODEL_DIR on the shared storage is refused by the format itself, so the
# GUI and every command refuse such a file, as the setup does.
test_model_dir_inside_a_storage_root_is_refused() {
    local -A values=([IMPACT_CONF_VERSION]=1 [MIN_GUI_VERSION]=2.1.0 [ACCESS_MODE]=tunnel
        [REPO_BASE]=%h/Repositories [MODEL_DIR]=/mnt/disk_a/shared/models [SHARED_GROUP]=impact
        [SHARED_ROOTS]=/mnt/disk_a/shared [MIN_FREE_GB]=200 [PORT_MIN]=8787 [PORT_MAX]=8830
        [ADMIN_CONTACT]='Alice Example')
    assert_fails impact_conf_validate values
    assert_contains "${IMPACT_CONF_ERRORS[*]}" 'lies inside the storage root /mnt/disk_a/shared'
    values[MODEL_DIR]=/srv/impact/models
    assert_success impact_conf_validate values
}
