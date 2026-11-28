#!/bin/bash
# =============================================================================
# run-tests.sh: runner for the tests of the IMPACT workstation commands
#
# Purpose
#   Runs the test files in unit/ and system/ and prints one line per test,
#   then a summary line. No test framework is needed: a test file is a bash
#   file with functions whose names start with "test_".
#
# Who runs it
#   Developers and the automatic checks. "unit" needs no special rights.
#   "system" changes the machine it runs on (accounts, groups, SSH rules) and
#   therefore runs only as root on a disposable system.
#
# Usage
#   tests/workstation/run-tests.sh unit   [--filter TEXT] [--verbose]
#   tests/workstation/run-tests.sh system [--filter TEXT] [--verbose]
#   tests/workstation/run-tests.sh all    [--filter TEXT] [--verbose]
#
# Examples
#   bash tests/workstation/run-tests.sh unit
#   bash tests/workstation/run-tests.sh unit --filter settings
#   sudo env IMPACT_TEST_DISPOSABLE=yes bash tests/workstation/run-tests.sh system
#
# Options
#   --filter TEXT   run only test files whose name contains TEXT, plus tests
#                   whose function name contains TEXT
#   --verbose       print the output of every test, also of those that pass
#   --help          show this text
#
# Environment for "system"
#   IMPACT_TEST_DISPOSABLE=yes   required: confirms that this machine may be
#                                changed and thrown away afterwards
#   IMPACT_TEST_BACKING_DIR=DIR  a folder on ext4, xfs or btrfs; needed when
#                                /mnt lies on another kind of file system
#                                (for example inside a container)
#   IMPACT_TEST_TIMEOUT=SECONDS  time limit per test (default 300)
#
# What it changes on the system
#   "unit": nothing outside a temporary folder.
#   "system": installs and removes the commands, creates and removes test
#   accounts and groups, writes SSH rules, starts an SSH server. It refuses
#   to start when /etc/impact/impact.conf exists, because that file marks a
#   machine that is in use.
#
# How to undo
#   Every system test file removes what it created. After an aborted run,
#   throw the disposable system away.
#
# Exit codes
#   0 all tests passed (skipped tests are allowed); 1 at least one test
#   failed or the preconditions for "system" are not met; 2 wrong usage.
#
# Output
#   PASS  <file> :: <test>
#   FAIL  <file> :: <test>      followed by the output of the test
#   SKIP  <file> :: <test>      with the reason
#   SUMMARY <level>: <n> tests, <n> passed, <n> failed, <n> skipped
#   A file may prepare its tests once in a function suite_setup and clean up
#   in suite_teardown. When suite_setup calls "skip" (for example because no
#   Docker daemon answers), every test of the file is reported as SKIP and
#   suite_teardown does not run; such a suite_setup decides before it
#   changes anything. A file whose tests the filter leaves out is not
#   prepared at all.
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
#   mapfile -t LIST <FILE     read the lines of FILE into the list LIST, one
#                        entry per line (-t drops the line ends)
#   < <(command)  <(command)   hand the output of a command to a loop, to
#                        mapfile or to another program as if it were a file
#                        ("process substitution")
#   while IFS= read -r line   read input line by line, exactly as written:
#                        "IFS=" keeps blanks at both ends, -r keeps backslashes
#   2>&1                 send the error channel to the same place as the output
#   shopt -s nullglob    a file pattern (*.conf) without a match gives an empty
#                        list; "shopt -u" switches this off again
# Constructs beyond these are explained where they are first used.
# -----------------------------------------------------------------------------

# "set -u" stops the script when a variable is read that was never set;
# "-o pipefail" makes a chain of commands joined with "|" fail when any part
# fails. The runner does not use "set -e" (stop at the first failing command),
# because a failing test must be counted, and the run must go on.
set -uo pipefail

# The folder of this file, and the top folder of the repository two levels
# above it. BASH_SOURCE[0] is the path of this file.
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export TESTS_DIR

LEVEL=''
FILTER=''
VERBOSE=0

# print_help: prints the comment block at the top of this file.
print_help() {
    local line
    while IFS= read -r line; do
        [[ "$line" == '#!'* ]] && continue
        [[ "$line" == '#'* ]] || break
        [[ "$line" =~ ^#[[:space:]]*=+[[:space:]]*$ ]] && continue
        line="${line#\#}"
        printf '%s\n' "${line# }"
    done <"${BASH_SOURCE[0]}"
}

# Read the command line. "$#" is the number of arguments that are left.
while (($# > 0)); do
    case "$1" in
        unit | system | all)
            LEVEL="$1"
            shift
            ;;
        --filter)
            if (($# < 2)); then
                echo "ERROR: --filter needs a text." >&2
                exit 2
            fi
            FILTER="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=1
            shift
            ;;
        --help)
            print_help
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument '$1'. Use --help." >&2
            exit 2
            ;;
    esac
done
if [[ -z "$LEVEL" ]]; then
    echo "ERROR: say which tests to run: unit, system or all. Use --help." >&2
    exit 2
fi

TIMEOUT_SECONDS="${IMPACT_TEST_TIMEOUT:-300}"
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0
FAILED_NAMES=()

# list_tests FILE
#   Prints the names of the test functions of a test file, in the order in
#   which the file defines them. A test function is a line that starts with
#   "test_<name>() {".
list_tests() {
    sed -n -E 's/^(test_[A-Za-z0-9_]+)[[:space:]]*\(\)[[:space:]]*\{.*$/\1/p' "$1"
}

# has_function FILE NAME
#   Result: success when the file defines the function NAME at the start of
#   a line.
has_function() {
    grep -q -E "^$2[[:space:]]*\(\)[[:space:]]*\{" "$1"
}

# run_function FILE NAME OUTPUT_FILE KIND
#   Runs one function of a test file in its own bash process, so that no test
#   can disturb another one. KIND is "test" (with the per-test setup and
#   teardown of the file) or "suite" (the function alone). Output goes to
#   OUTPUT_FILE. Result: the exit code (0 pass, 77 skip, 124 time limit).
run_function() {
    timeout --kill-after=10 "$TIMEOUT_SECONDS" \
        bash "$TESTS_DIR/lib/run-one.sh" "$1" "$2" "$4" >"$3" 2>&1 </dev/null
}

# show_output FILE
#   Prints a captured output, indented.
show_output() {
    sed -e 's/^/      | /' "$1"
}

# run_file LEVEL FILE
#   Runs all tests of one file and counts the results.
run_file() {
    local level="$1" file="$2" short test_name status output_file suite_tmp
    local -a names=() selected=()
    short="$level/$(basename -- "$file")"
    mapfile -t names < <(list_tests "$file")
    # The tests that the filter lets through. A file without any of them is
    # left out completely, so its preparation does not run for nothing.
    for test_name in "${names[@]}"; do
        if [[ -z "$FILTER" || "$short" == *"$FILTER"* || "$test_name" == *"$FILTER"* ]]; then
            selected+=("$test_name")
        fi
    done
    if ((${#selected[@]} == 0)); then
        return 0
    fi

    # One temporary folder per test file. Tests of the file can pass files to
    # each other through it (TEST_SUITE_TMP).
    suite_tmp="$(mktemp -d /tmp/impact-test.XXXXXXXXXX)" || return 1
    # A test may run as another account; it must be able to enter the folder.
    chmod 755 "$suite_tmp"
    export TEST_SUITE_TMP="$suite_tmp"
    output_file="$suite_tmp/.output"

    # suite_ok: 1 ready; 0 the preparation failed; 2 the preparation asked
    # to skip the whole file (it called "skip", exit code 77), for example
    # because no Docker daemon answers. A preparation that skips must do so
    # before it changes anything: the clean-up of the file then does not run.
    local suite_ok=1 suite_status=0 skip_reason=''
    if has_function "$file" suite_setup; then
        run_function "$file" suite_setup "$output_file" suite || suite_status=$?
        if ((suite_status == 77)); then
            suite_ok=2
            skip_reason="$(grep -m 1 '^SKIP: ' "$output_file" | cut -c7-)"
        elif ((suite_status != 0)); then
            suite_ok=0
            printf 'FAIL  %s :: suite_setup\n' "$short"
            show_output "$output_file"
        elif ((VERBOSE == 1)); then
            show_output "$output_file"
        fi
    fi

    for test_name in "${selected[@]}"; do
        TOTAL=$((TOTAL + 1))
        if ((suite_ok == 0)); then
            FAILED=$((FAILED + 1))
            FAILED_NAMES+=("$short :: $test_name")
            printf 'FAIL  %s :: %s (the preparation of this file failed)\n' "$short" "$test_name"
            continue
        fi
        if ((suite_ok == 2)); then
            SKIPPED=$((SKIPPED + 1))
            printf 'SKIP  %s :: %s (%s)\n' "$short" "$test_name" "$skip_reason"
            continue
        fi
        status=0
        run_function "$file" "$test_name" "$output_file" test || status=$?
        case "$status" in
            0)
                PASSED=$((PASSED + 1))
                printf 'PASS  %s :: %s\n' "$short" "$test_name"
                if ((VERBOSE == 1)); then
                    show_output "$output_file"
                fi
                ;;
            77)
                SKIPPED=$((SKIPPED + 1))
                printf 'SKIP  %s :: %s (%s)\n' "$short" "$test_name" "$(grep -m 1 '^SKIP: ' "$output_file" | cut -c7-)"
                ;;
            *)
                FAILED=$((FAILED + 1))
                FAILED_NAMES+=("$short :: $test_name")
                if ((status == 124 || status == 137)); then
                    printf 'FAIL  %s :: %s (time limit of %s seconds reached)\n' "$short" "$test_name" "$TIMEOUT_SECONDS"
                else
                    printf 'FAIL  %s :: %s\n' "$short" "$test_name"
                fi
                show_output "$output_file"
                ;;
        esac
    done

    if ((suite_ok != 2)) && has_function "$file" suite_teardown; then
        if ! run_function "$file" suite_teardown "$output_file" suite; then
            printf 'FAIL  %s :: suite_teardown (the clean-up of this file failed)\n' "$short"
            show_output "$output_file"
            FAILED=$((FAILED + 1))
            FAILED_NAMES+=("$short :: suite_teardown")
            TOTAL=$((TOTAL + 1))
        fi
    fi
    rm -rf -- "$suite_tmp"
}

# system_preconditions
#   The system tests change the machine. Result: success only when the
#   caller confirmed that the machine is disposable, the runner is root, and
#   no settings file marks the machine as one that is in use.
system_preconditions() {
    if [[ "${IMPACT_TEST_DISPOSABLE:-}" != 'yes' ]]; then
        echo "REFUSED: the system tests create accounts, groups and SSH rules on this machine." >&2
        echo "         Run them on a disposable system only, and confirm that with IMPACT_TEST_DISPOSABLE=yes." >&2
        return 1
    fi
    if ((EUID != 0)); then
        echo "REFUSED: the system tests need root rights (on a disposable system)." >&2
        return 1
    fi
    if [[ -e /etc/impact/impact.conf || -L /etc/impact/impact.conf ]]; then
        echo "REFUSED: /etc/impact/impact.conf exists. This machine is in use, or an earlier test run did not clean up." >&2
        echo "         Use a fresh disposable system." >&2
        return 1
    fi
    return 0
}

# run_level LEVEL
#   Runs all test files of one level and prints its summary line.
#   Result: success when no test failed.
run_level() {
    local level="$1" file
    local before_total="$TOTAL" before_passed="$PASSED" before_failed="$FAILED" before_skipped="$SKIPPED"
    if [[ "$level" == 'system' ]] && ! system_preconditions; then
        printf 'SUMMARY %s: not run (preconditions not met)\n' "$level"
        return 1
    fi
    # "nullglob": a pattern without any match expands to nothing.
    shopt -s nullglob
    for file in "$TESTS_DIR/$level"/*.test.sh; do
        run_file "$level" "$file"
    done
    shopt -u nullglob
    printf 'SUMMARY %s: %d tests, %d passed, %d failed, %d skipped\n' "$level" \
        "$((TOTAL - before_total))" "$((PASSED - before_passed))" \
        "$((FAILED - before_failed))" "$((SKIPPED - before_skipped))"
    ((FAILED == before_failed))
}

RESULT=0
case "$LEVEL" in
    unit) run_level unit || RESULT=1 ;;
    system) run_level system || RESULT=1 ;;
    all)
        run_level unit || RESULT=1
        run_level system || RESULT=1
        ;;
    *) ;;
esac
if ((${#FAILED_NAMES[@]} > 0)); then
    printf '\nFailed tests:\n'
    printf '  %s\n' "${FAILED_NAMES[@]}"
fi
exit "$RESULT"
