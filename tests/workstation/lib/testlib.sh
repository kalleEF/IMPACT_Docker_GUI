#!/bin/bash
# =============================================================================
# testlib.sh: helper functions for the tests of the workstation commands
#
# Purpose
#   Assertions (checks that end a test with a clear message when something is
#   not as expected), a way to run a command and keep its output and exit
#   code, and the paths every test needs. It also loads snapshot.sh (record
#   and compare the state of the system) and system.sh (helpers for tests
#   that run as root on a disposable system).
#
# Who runs it
#   Nobody directly. run-one.sh loads it before the test file, and every
#   test file loads it in its first lines (loading twice does no harm).
#
# Usage (inside a test file)
#   source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/testlib.sh"
#   test_port_rule() {
#       load_library
#       assert_success impact_valid_port 8787
#       assert_fails impact_valid_port 80
#   }
#
# What it changes on the system
#   Nothing by itself.
#
# How to undo
#   Nothing to undo.
#
# Variables for tests
#   TESTS_DIR        the folder tests/workstation
#   REPO_ROOT        the top folder of the repository
#   WORKSTATION_DIR  the folder workstation of the repository
#   TEST_SUITE_TMP   temporary folder shared by the tests of one file
#   TEST_TMP         temporary folder of the running test
#   RUN_STATUS, RUN_OUTPUT   exit code and output of the last run_cmd
# =============================================================================

# -----------------------------------------------------------------------------
# Reading help: bash constructs that appear in this file
#   NAME=text            store a text in the variable NAME; "$NAME" reads it
#   local NAME           a variable that exists only inside one function
#   "$1" "$2" "$@" "$#"  first parameter, second parameter, all parameters,
#                        number of parameters
#   "${NAME:-text}"      the value of NAME, or "text" when NAME is unset or empty
#   $( command )         the text that the command prints
#   [[ ... ]]            a test: -f plain file, -d folder, -L symbolic link,
#                        -e exists, -r readable, -x executable, -z empty text,
#                        -n text with content, == equal, != different,
#                        =~ matches a pattern
#   (( ... ))            arithmetic: true when the result is not zero
#   A && B               run B only when A succeeded
#   A || B               run B only when A failed
#   ! command            true when the command fails
#   if / case / for / while   branches and loops; "case" compares one value
#                        with several patterns
#   >file >>file <file   write to a file (replace it / add to its end), read
#                        from a file
#   2>/dev/null  >&2     throw error messages away / write to the error channel
#   command1 | command2  hand the output of command1 to command2
#   return N / exit N    end the function / the script with status N; 0 means
#                        success
#   list=(a b)  "${list[@]}"  "${#list[@]}"   a list, all its entries, their number
# Constructs beyond these are explained where they are first used.
# -----------------------------------------------------------------------------

# The line for the checking tool "shellcheck" stands before the first command
# and therefore counts for the whole file: files named in "source=" lines are
# looked up relative to the folder of this file.
# shellcheck source-path=SCRIPTDIR

# Load this file once per process. "${VAR:-}" is the value of VAR, or an
# empty text when VAR was never set.
if [[ -n "${IMPACT_TESTLIB_LOADED:-}" ]]; then
    return 0
fi
IMPACT_TESTLIB_LOADED=1

# The folder tests/workstation is one level above this file.
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
REPO_ROOT="$(cd -- "$TESTS_DIR/../.." && pwd -P)"
WORKSTATION_DIR="$REPO_ROOT/workstation"
export TESTS_DIR REPO_ROOT WORKSTATION_DIR

RUN_STATUS=0
RUN_OUTPUT=''

# load_library
#   Loads the shared functions of the commands (impact-common.sh and its
#   topic files) into the test, so that a test can call them directly.
#   Do not call impact_init inside a test: it installs end-of-script handlers
#   that belong to a command. Test impact_init through a small script that
#   run_cmd starts (see unit/70-command-flow.test.sh).
load_library() {
    # shellcheck source=../../../workstation/lib/impact-common.sh
    source "$WORKSTATION_DIR/lib/impact-common.sh"
}

# -----------------------------------------------------------------------------
# Ending a test
# -----------------------------------------------------------------------------

# fail MESSAGE
#   Ends the test as failed. Prints the message and the place in the test
#   file that called the assertion.
fail() {
    # BASH_LINENO and FUNCNAME are lists that bash keeps about the chain of
    # function calls. Entry 1 is the caller of the assertion.
    printf 'ASSERTION FAILED: %s\n' "$*" >&2
    local depth
    for ((depth = 1; depth < ${#FUNCNAME[@]}; depth++)); do
        if [[ "${FUNCNAME[depth]}" == test_* || "${FUNCNAME[depth]}" == suite_* ]]; then
            printf '  in %s, line %s\n' "${FUNCNAME[depth]}" "${BASH_LINENO[depth - 1]}" >&2
            break
        fi
    done
    exit 1
}

# skip REASON
#   Ends the test as skipped (exit code 77), for example when a tool that the
#   test needs is missing on this machine.
skip() {
    printf 'SKIP: %s\n' "$*"
    exit 77
}

# -----------------------------------------------------------------------------
# Running commands
# -----------------------------------------------------------------------------

# run_cmd COMMAND [ARGUMENTS...]
#   Runs a command or function and never ends the test, whatever the result.
#   Afterwards RUN_STATUS holds the exit code and RUN_OUTPUT everything the
#   command printed (normal and error output together).
#   The command runs in a copy of the test process: a function that calls
#   "exit" ends only that copy, and variables it sets are not visible later.
#   Use assert_success or a plain call when the test needs those variables.
run_cmd() {
    local output_file
    output_file="$(mktemp "${TEST_TMP:-/tmp}/run.XXXXXXXXXX")"
    RUN_STATUS=0
    # "( ... )" is the copy; "|| RUN_STATUS=$?" keeps a failure code and
    # stops "set -e" from ending the test.
    ("$@") >"$output_file" 2>&1 </dev/null || RUN_STATUS=$?
    RUN_OUTPUT="$(cat -- "$output_file")"
    rm -f -- "$output_file"
    return 0
}

# run_cmd_with_input TEXT COMMAND [ARGUMENTS...]
#   As run_cmd, with TEXT handed to the command as its standard input (for
#   example a key line that a command reads from standard input).
run_cmd_with_input() {
    local input="$1" output_file
    shift
    output_file="$(mktemp "${TEST_TMP:-/tmp}/run.XXXXXXXXXX")"
    RUN_STATUS=0
    # "<<<" hands a text to a command as its input.
    ("$@") >"$output_file" 2>&1 <<<"$input" || RUN_STATUS=$?
    RUN_OUTPUT="$(cat -- "$output_file")"
    rm -f -- "$output_file"
    return 0
}

# show_run
#   Prints exit code and output of the last run_cmd; used by assertions.
show_run() {
    printf '  exit code: %s\n  output:\n' "$RUN_STATUS" >&2
    printf '%s\n' "$RUN_OUTPUT" | sed -e 's/^/    > /' >&2
}

# -----------------------------------------------------------------------------
# Assertions about values
# -----------------------------------------------------------------------------

# assert_eq EXPECTED ACTUAL [WHAT]
#   Fails unless the two texts are equal.
assert_eq() {
    if [[ "$1" != "$2" ]]; then
        printf '  expected: %s\n  actual:   %s\n' "$1" "$2" >&2
        fail "${3:-the values differ}"
    fi
}

# assert_ne UNEXPECTED ACTUAL [WHAT]
#   Fails when the two texts are equal.
assert_ne() {
    if [[ "$1" == "$2" ]]; then
        printf '  both are: %s\n' "$1" >&2
        fail "${3:-the values are equal and should differ}"
    fi
}

# assert_contains TEXT PART [WHAT]
#   Fails unless TEXT contains PART.
assert_contains() {
    if [[ "$1" != *"$2"* ]]; then
        printf '  text:     %s\n  expected to contain: %s\n' "$1" "$2" >&2
        fail "${3:-the text does not contain the expected part}"
    fi
}

# assert_not_contains TEXT PART [WHAT]
#   Fails when TEXT contains PART.
assert_not_contains() {
    if [[ "$1" == *"$2"* ]]; then
        printf '  text:     %s\n  must not contain: %s\n' "$1" "$2" >&2
        fail "${3:-the text contains a part that must be absent}"
    fi
}

# assert_matches TEXT PATTERN [WHAT]
#   Fails unless TEXT matches the regular expression PATTERN.
assert_matches() {
    if ! [[ "$1" =~ $2 ]]; then
        printf '  text:    %s\n  pattern: %s\n' "$1" "$2" >&2
        fail "${3:-the text does not match the pattern}"
    fi
}

# -----------------------------------------------------------------------------
# Assertions about commands
# -----------------------------------------------------------------------------

# assert_success COMMAND [ARGUMENTS...]
#   Runs the command inside the test process and fails unless it succeeds.
#   Variables that the command sets stay visible to the test.
assert_success() {
    local status=0
    "$@" || status=$?
    if ((status != 0)); then
        fail "expected success, got exit code $status from: $*"
    fi
}

# assert_fails COMMAND [ARGUMENTS...]
#   Runs the command inside the test process and fails when it succeeds.
assert_fails() {
    local status=0
    "$@" || status=$?
    if ((status == 0)); then
        fail "expected a failure, and this succeeded: $*"
    fi
}

# assert_status EXPECTED_CODE
#   Fails unless the last run_cmd ended with EXPECTED_CODE.
assert_status() {
    if [[ "$RUN_STATUS" != "$1" ]]; then
        show_run
        fail "expected exit code $1, got $RUN_STATUS"
    fi
}

# assert_output_contains PART
#   Fails unless the output of the last run_cmd contains PART.
assert_output_contains() {
    if [[ "$RUN_OUTPUT" != *"$1"* ]]; then
        show_run
        fail "the output does not contain: $1"
    fi
}

# assert_output_not_contains PART
#   Fails when the output of the last run_cmd contains PART.
assert_output_not_contains() {
    if [[ "$RUN_OUTPUT" == *"$1"* ]]; then
        show_run
        fail "the output contains, and must not: $1"
    fi
}

# -----------------------------------------------------------------------------
# Assertions about files
# -----------------------------------------------------------------------------

# assert_exists PATH
#   Fails unless something exists at PATH (a symbolic link counts).
assert_exists() {
    if [[ ! -e "$1" && ! -L "$1" ]]; then
        fail "expected to exist: $1"
    fi
}

# assert_missing PATH
#   Fails when anything exists at PATH.
assert_missing() {
    if [[ -e "$1" || -L "$1" ]]; then
        fail "expected to be absent: $1 ($(ls -ld -- "$1" 2>&1))"
    fi
}

# assert_file_facts PATH MODE OWNER GROUP
#   Fails unless PATH has this mode (for example 644), owner and group.
assert_file_facts() {
    local facts
    facts="$(stat -c '%a %U %G' -- "$1" 2>&1)" || fail "cannot examine $1: $facts"
    assert_eq "$2 $3 $4" "$facts" "mode, owner and group of $1"
}

# assert_file_contains PATH PART
#   Fails unless the file contains the line part PART (fixed text).
assert_file_contains() {
    if ! grep -q -F -- "$2" "$1" 2>/dev/null; then
        printf '  file %s:\n' "$1" >&2
        sed -e 's/^/    > /' "$1" >&2 || true
        fail "the file does not contain: $2"
    fi
}

# assert_file_not_contains PATH PART
#   Fails when the file contains PART (fixed text).
assert_file_not_contains() {
    if grep -q -F -- "$2" "$1" 2>/dev/null; then
        fail "the file $1 contains, and must not: $2"
    fi
}

# The two further helper files lie next to this one.
# shellcheck source=snapshot.sh
source "$TESTS_DIR/lib/snapshot.sh"
# shellcheck source=system.sh
source "$TESTS_DIR/lib/system.sh"
