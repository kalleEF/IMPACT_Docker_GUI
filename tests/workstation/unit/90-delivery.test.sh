#!/bin/bash
# =============================================================================
# 90-delivery.test.sh: unit tests for the delivered files as a whole
#
# Purpose
#   Checks rules that hold for every file below workstation/ and
#   tests/workstation/: scripts start with "#!/bin/bash", pass a syntax
#   check and carry the standard header; commands are executable; the texts
#   contain no long dashes, no values of a real site, and never execute a
#   settings file. It also checks VERSION and GitHub's host keys.
#
# Who runs it
#   tests/workstation/run-tests.sh unit   (no special rights needed)
#
# Usage
#   bash tests/workstation/run-tests.sh unit --filter 90-delivery
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
# shellcheck disable=SC2016
# Reason for SC2016 (no expansion in single quotes): many texts in this file
# are test data, or lines of small scripts that a test writes. They must stay
# exactly as written.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/testlib.sh"

# all_files
#   Prints every plain file of the two delivered folders, one per line.
all_files() {
    find "$WORKSTATION_DIR" "$TESTS_DIR" -type f | LC_ALL=C sort
}

# script_files
#   Prints every bash script of the two folders: files named *.sh and the
#   commands in workstation/bin.
script_files() {
    {
        find "$WORKSTATION_DIR" "$TESTS_DIR" -type f -name '*.sh'
        find "$WORKSTATION_DIR/bin" -type f
    } | LC_ALL=C sort -u
}

test_version_file() {
    local version
    IFS= read -r version <"$WORKSTATION_DIR/VERSION"
    assert_matches "$version" '^[0-9]+\.[0-9]+\.[0-9]+$' "content of VERSION"
    assert_eq 1 "$(wc -l <"$WORKSTATION_DIR/VERSION")" "VERSION has exactly one line"
}

test_scripts_start_with_bash_and_pass_the_syntax_check() {
    local file first_line
    while IFS= read -r file; do
        IFS= read -r first_line <"$file" || true
        assert_eq '#!/bin/bash' "$first_line" "first line of $file"
        # "bash -n" reads a script and reports syntax errors; it runs nothing.
        if ! bash -n "$file"; then
            fail "syntax error in $file"
        fi
    done < <(script_files)
}

test_scripts_have_unix_line_ends() {
    local file
    while IFS= read -r file; do
        # A carriage return in a script makes bash fail in confusing ways.
        if grep -q $'\r' "$file"; then
            fail "$file contains Windows line ends"
        fi
    done < <(script_files)
}

test_scripts_carry_the_standard_header() {
    local file header part
    while IFS= read -r file; do
        # The header is the block of comment lines at the top of the file.
        header="$(sed -n -e '2,${/^#/!q;p}' "$file")"
        for part in 'Purpose' 'Who runs it' 'Usage' 'What it changes on the system' 'How to undo'; do
            if [[ "$header" != *"$part"* ]]; then
                fail "the header of $file has no part '$part'"
            fi
        done
    done < <(script_files)
}

test_commands_are_executable_and_have_no_extension() {
    local file name
    for file in "$WORKSTATION_DIR"/bin/*; do
        name="$(basename "$file")"
        assert_matches "$name" '^impact-[a-z][a-z-]*$' "name of the command $name"
        if [[ ! -x "$file" ]]; then
            fail "$file is not executable"
        fi
        assert_file_contains "$file" 'set -euo pipefail'
        assert_file_contains "$file" 'impact_init'
        assert_file_contains "$file" 'impact_parse_args'
    done
    for file in "$WORKSTATION_DIR/install.sh" "$WORKSTATION_DIR/uninstall.sh" "$TESTS_DIR/run-tests.sh"; do
        if [[ ! -x "$file" ]]; then
            fail "$file is not executable"
        fi
    done
}

test_no_long_dashes_in_any_file() {
    # The two dash characters are built from their byte values, so this
    # file does not contain them itself.
    local em_dash=$'\xe2\x80\x94' en_dash=$'\xe2\x80\x93' file
    while IFS= read -r file; do
        if grep -q -e "$em_dash" -e "$en_dash" "$file"; then
            grep -n -e "$em_dash" -e "$en_dash" "$file" | head -n 5 >&2
            fail "$file contains a long dash; use a colon, a comma, brackets or two sentences"
        fi
    done < <(all_files)
}

test_no_site_values_in_any_file() {
    # The forbidden texts are put together from two halves, so this file
    # does not contain them itself.
    local -a forbidden=(
        'php-work''station'
        '/mnt/Stor''age_'
        'IMPACT_Stor''age'
    )
    local file text
    while IFS= read -r file; do
        for text in "${forbidden[@]}"; do
            if grep -q -F -- "$text" "$file"; then
                grep -n -F -- "$text" "$file" | head -n 5 >&2
                fail "$file contains the site value '$text'; the repository is public"
            fi
        done
    done < <(all_files)
}

test_only_example_addresses_appear() {
    # Network addresses in examples and tests come from 192.0.2.x (reserved
    # for documentation), 10.0.0.x or 192.168.1.x; 127.x and 0.0.0.0 are
    # always allowed. Version-like numbers with four parts are listed here
    # when a file needs one.
    local file line address
    while IFS= read -r file; do
        while IFS= read -r address; do
            case "$address" in
                127.* | 0.0.0.0 | 192.0.2.* | 10.0.0.* | 192.168.1.* | 255.255.255.0 | 1.2.3.4) ;;
                *) fail "$file contains the address $address; use an example address from 192.0.2.x" ;;
            esac
        done < <(grep -o -E '(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9.]|$)' "$file" | grep -o -E '([0-9]{1,3}\.){3}[0-9]{1,3}' || true)
    done < <(all_files)
}

test_settings_files_are_never_executed() {
    local file
    while IFS= read -r file; do
        # The word eval and the loading of a settings file as a script are
        # the two ways in which a value could become a command.
        if grep -n -E '(^|[^A-Za-z_])eval[[:space:]]' "$file" | grep -v -E '^[0-9]+:[[:space:]]*#' >&2; then
            fail "$file uses eval"
        fi
        if grep -n -E '(source|^[[:space:]]*\.)[[:space:]].*(impact\.conf|model\.conf)' "$file" | grep -v -E '^[0-9]+:[[:space:]]*#' >&2; then
            fail "$file loads a settings file as a script"
        fi
    done < <(find "$WORKSTATION_DIR" -type f \( -name '*.sh' -o -path '*/bin/*' \))
}

test_github_host_keys() {
    local file="$WORKSTATION_DIR/etc/github_known_hosts"
    local -a lines=()
    mapfile -t lines < <(grep -v -e '^#' -e '^$' "$file")
    assert_eq 3 "${#lines[@]}" "number of key lines"
    assert_matches "${lines[0]}" '^github\.com ssh-ed25519 AAAA[A-Za-z0-9+/=]+$'
    assert_matches "${lines[1]}" '^github\.com ecdsa-sha2-nistp256 AAAA[A-Za-z0-9+/=]+$'
    assert_matches "${lines[2]}" '^github\.com ssh-rsa AAAA[A-Za-z0-9+/=]+$'
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        skip "the form of the three lines is checked; the fingerprints need ssh-keygen"
    fi
    # The fingerprints that GitHub publishes in its documentation
    # ("GitHub's SSH key fingerprints").
    local prints
    prints="$(ssh-keygen -l -E sha256 -f "$file")"
    assert_contains "$prints" 'SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU' "ED25519 fingerprint"
    assert_contains "$prints" 'SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM' "ECDSA fingerprint"
    assert_contains "$prints" 'SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s' "RSA fingerprint"
    assert_eq 3 "$(printf '%s\n' "$prints" | wc -l)"
}

test_every_library_function_has_a_comment() {
    # Every function of the library must have a comment block directly
    # above it that starts with the name of the function.
    local file line previous name number
    # shellcheck disable=SC2094
    # Reason for SC2094 (same file read and written): the file is only read,
    # once by the loop and once by grep.
    for file in "$WORKSTATION_DIR"/lib/*.sh; do
        previous=''
        number=0
        while IFS= read -r line; do
            number=$((number + 1))
            if [[ "$line" =~ ^(impact_[A-Za-z0-9_]+)\(\)[[:space:]]*\{ ]]; then
                name="${BASH_REMATCH[1]}"
                if [[ "$previous" != '#'* ]]; then
                    fail "$file line $number: the function $name has no comment above it"
                fi
                if ! grep -q -E "^# $name( |\$)" "$file"; then
                    fail "$file: the comment of $name does not start with '# $name'"
                fi
            fi
            previous="$line"
        done <"$file"
    done
}
