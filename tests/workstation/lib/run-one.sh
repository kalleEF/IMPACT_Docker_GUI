#!/bin/bash
# =============================================================================
# run-one.sh: runs one function of a test file in its own bash process
#
# Purpose
#   run-tests.sh starts this file once per test. A fresh process per test
#   means that variables, the current folder and "exit" of one test never
#   reach another test.
#
# Who runs it
#   Only run-tests.sh. To run one test by hand, use
#   run-tests.sh unit --filter <name>.
#
# Usage
#   bash run-one.sh <test file> <function name> test|suite
#
# Examples
#   bash run-one.sh ../unit/20-settings.test.sh test_port_rule test
#   bash run-one.sh ../system/20-setup.test.sh suite_setup suite
#
# What it changes on the system
#   What the test function changes. For "test" it creates a fresh folder
#   TEST_TMP inside TEST_SUITE_TMP.
#
# How to undo
#   run-tests.sh removes TEST_SUITE_TMP when the test file is finished.
#
# Exit codes
#   0 the function passed; 77 the test asked to be skipped; any other code
#   means failure.
# =============================================================================

# Reading help: the bash constructs used here are explained at the top of
# testlib.sh ("Reading help") and where they are first used.

# "set -e" stops at the first failing command, so a test fails as soon as one
# of its steps fails unexpectedly; "-u" stops on a variable that was never
# set; "-o pipefail" makes a chain joined with "|" fail when any part fails.
set -euo pipefail

TEST_FILE="$1"
TEST_FUNCTION="$2"
TEST_KIND="$3"

# The helper functions (assertions, snapshots, system helpers).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/testlib.sh"

# The test file defines the test functions. Its path changes from call to
# call, so the checking tool cannot follow it.
# shellcheck source=/dev/null
source "$TEST_FILE"

if [[ "$TEST_KIND" == 'test' ]]; then
    # A fresh folder for this test alone.
    TEST_TMP="$(mktemp -d "$TEST_SUITE_TMP/test.XXXXXXXXXX")"
    chmod 755 "$TEST_TMP"
    export TEST_TMP
    # "declare -F name" succeeds when a function of that name exists.
    if declare -F teardown >/dev/null; then
        # "trap ... EXIT" runs the teardown when this process ends, also
        # after a failed assertion.
        trap 'teardown' EXIT
    fi
    if declare -F setup >/dev/null; then
        setup
    fi
fi

"$TEST_FUNCTION"
