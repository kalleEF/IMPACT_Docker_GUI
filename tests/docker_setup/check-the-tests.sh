#!/usr/bin/env bash
# =============================================================================
# check-the-tests.sh: proves that run-tests.sh notices the mistakes it exists to catch
# =============================================================================
#
# PURPOSE
#   A test that never fails proves nothing. This script makes copies of the docker_setup
#   folder, each with one deliberate mistake in entrypoint.sh (a "mutant"), runs
#   run-tests.sh against each copy, and checks that the tests named below FAIL.
#   The mistakes are the ones that would re-own other people's files on a shared computer:
#
#     usermod      the account is changed with "groupmod -g" and "usermod -u -g", the
#                  usual tools. They change the owner of every file in the home folder
#                  that has the old numbers, and the mounts lie inside the home folder.
#     chown-home   one extra line "chown -R <numbers> /home/rstudio": a recursive change of
#                  owner of the home folder, which walks through every mount inside it.
#     to-rocker    the numbers are handed to the Rocker base image as USERID and GROUPID,
#                  as the GUI does up to version 2.0. Rocker then deletes and recreates the
#                  user and runs "chown -R" on the home folder.
#     no-mount-check   the check "is a mount at or inside this settings folder?" is
#                  switched off. A settings folder that is itself a mount (for example
#                  /home/rstudio/.ssh) is then handed to the user, with everything in it.
#
#   For each mutant the script reports "caught" (the expected tests failed) or "NOT
#   caught" (they passed, so the tests have a gap).
#
# WHEN TO RUN IT
#   By hand, after a change to run-tests.sh, lib/make-fixture.sh or lib/record-tree.sh.
#   It takes about 15 minutes. run-tests.sh must have run once before on this computer
#   (it builds the stand-in prerequisite image, which needs the internet once).
#
# HOW TO RUN IT
#   bash tests/docker_setup/check-the-tests.sh              all four mutants
#   bash tests/docker_setup/check-the-tests.sh usermod      only the named mutant(s)
#
# WHAT IT CHANGES
#   A temporary folder with the mutated copies (removed at the end), and Docker images
#   named impact-setup-mutant-<name>*:local, which it removes at the end. The
#   docker_setup folder itself is only read.
#
# SETTINGS
#   IMPACT_TEST_TMP   as for run-tests.sh: where the temporary folders are created.
#
# EXIT CODE
#   0 when every mutant was caught, 1 when at least one was not, 2 when a mutant could
#   not be made (the line it changes was not found in entrypoint.sh).
# =============================================================================

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="${IMPACT_DOCKER_SETUP_DIR:-$(cd "$HERE/../.." && pwd)/docker_setup}"
TMP_BASE="${IMPACT_TEST_TMP:-${TMPDIR:-/tmp}}"

# The mutants, in the order they run. "$@" holds the names given on the command line.
ALL_MUTANTS=(usermod chown-home to-rocker no-mount-check)
if [[ $# -gt 0 ]]; then
    MUTANTS=("$@")
else
    MUTANTS=("${ALL_MUTANTS[@]}")
fi

# mktemp -d creates a new, empty folder with a name nobody else uses.
WORK="$(mktemp -d "$TMP_BASE/impact-setup-mutants.XXXXXX")" || exit 2
cleanup() {
    rm -rf "$WORK"
    # "docker images --format" prints one image name per line; grep keeps the names of
    # the mutants, and "xargs -r" removes them when there are any.
    docker images --format '{{.Repository}}:{{.Tag}}' | grep '^impact-setup-mutant-' | xargs -r docker rmi -f > /dev/null 2>&1
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Making the mutants
# -----------------------------------------------------------------------------
# make_mutant NAME: copies docker_setup to $WORK/NAME and changes its entrypoint.sh.
# Every change is made with awk, a small text-processing language: it reads the file
# line by line, and the program between the quotes decides what is printed.
# Returns 1 when the line to change was not found.
make_mutant() {
    local name="$1" dir="$WORK/$1"
    mkdir -p "$dir"
    cp -r "$SETUP_DIR/." "$dir/"
    local file="$dir/entrypoint.sh" new="$dir/entrypoint.sh.new"
    case "$name" in
        usermod)
            # Replaces the whole block that edits /etc/passwd and /etc/group (from the
            # line 'if [[ "$old_uid" == "$want_uid" ...' to the next line '    fi')
            # by the two usual commands. "-o" lets groupmod take a number in use.
            awk '
                /^    if \[\[ "\$old_uid" == "\$want_uid"/ {
                    print "    groupmod -o -g \"$want_gid\" \"$RSTUDIO_GROUP\""
                    print "    usermod -u \"$want_uid\" -g \"$want_gid\" \"$RSTUDIO_USER\""
                    skipping = 1; done = 1; next
                }
                skipping && /^    fi$/ { skipping = 0; next }
                skipping { next }
                { print }
                END { exit !done }' "$file" > "$new" || return 1
            ;;
        chown-home)
            # One extra line at the beginning of step 4.
            awk '
                { print }
                /^    # --- Step 4:/ { print "    chown -R \"$want_uid:$want_gid\" \"$RSTUDIO_HOME\""; done = 1 }
                END { exit !done }' "$file" > "$new" || return 1
            ;;
        to-rocker)
            # The identity step is replaced by handing the numbers to Rocker.
            awk '
                /^    apply_identity$/ { print "    export USERID=\"$IMPACT_UID\" GROUPID=\"$IMPACT_GID\""; done = 1; next }
                { print }
                END { exit !done }' "$file" > "$new" || return 1
            ;;
        no-mount-check)
            # In own_home_entry the mount check becomes "if false", which never applies.
            awk '
                !done && /^    if mount_at_or_below "\$path"; then$/ { print "    if false; then"; done = 1; next }
                { print }
                END { exit !done }' "$file" > "$new" || return 1
            ;;
        *)
            echo "unknown mutant: $name (known: ${ALL_MUTANTS[*]})" >&2
            return 1
            ;;
    esac
    mv "$new" "$file"
    # The mutant must differ from the original; "cmp -s" is silent and succeeds when
    # two files are identical.
    if cmp -s "$file" "$SETUP_DIR/entrypoint.sh"; then
        return 1
    fi
}

# -----------------------------------------------------------------------------
# What each mutant must break
# -----------------------------------------------------------------------------
# groups_for NAME: the test groups of run-tests.sh to run (a pattern for --only).
# expected_failures NAME: the test lines that must fail, one per line. Each line is
# compared with the start of a "FAIL" line of run-tests.sh.
groups_for() {
    case "$1" in
        no-mount-check) echo '^settings-mount$' ;;
        *)              echo '^valid$' ;;
    esac
}
expected_failures() {
    case "$1" in
        usermod|chown-home|to-rocker)
            echo "[valid] remote: other UID and GID (2001:3001): mounted trees unchanged after the start"
            echo "[valid] both: IMPACT variables and Rocker variables together: mounted trees unchanged after the start"
            ;;
        no-mount-check)
            echo "[settings-mount] settings folders as mounts: all mounted trees unchanged, the settings mounts included"
            echo "[settings-mount] settings folders as mounts: the mounted .ssh keeps its owner"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------
CAUGHT=0
MISSED=0
BROKEN=0
for name in "${MUTANTS[@]}"; do
    echo "=== mutant '$name'"
    if ! make_mutant "$name"; then
        echo "    could not make the mutant: the line to change was not found in entrypoint.sh"
        BROKEN=$((BROKEN + 1))
        continue
    fi
    # The change itself, for the record ("diff" prints the changed lines).
    diff "$SETUP_DIR/entrypoint.sh" "$WORK/$name/entrypoint.sh" | grep '^[<>]' | sed 's/^/    change: /'

    log="$WORK/$name.log"
    IMPACT_DOCKER_SETUP_DIR="$WORK/$name" IMPACT_TEST_PREFIX="impact-setup-mutant-$name" \
        IMPACT_TEST_TMP="$TMP_BASE" bash "$HERE/run-tests.sh" --only "$(groups_for "$name")" > "$log" 2>&1
    # The summary line of run-tests.sh, for example "Summary: 92 tests, 80 passed, ...".
    grep '^Summary:' "$log" | sed 's/^/    run-tests.sh: /'
    # Every test that failed against this mutant, for the record.
    grep '^FAIL  ' "$log" | sed 's/^FAIL  /    failed: /'

    all_failed=1
    while IFS= read -r wanted; do
        # grep -F looks for the text as written; "^FAIL  " anchors it to a FAIL line.
        if grep -q -F -- "FAIL  $wanted" "$log"; then
            echo "    fails as it must: $wanted"
        else
            echo "    PASSES although it must fail: $wanted"
            all_failed=0
        fi
    done < <(expected_failures "$name")
    # Show what the fixture saw: the first lines of the first difference report.
    grep -A 4 -m 1 'entries differ' "$log" | sed 's/^/    /'

    if [[ "$all_failed" == 1 ]]; then
        echo "    result: caught"
        CAUGHT=$((CAUGHT + 1))
    else
        echo "    result: NOT caught (the full output is kept in $TMP_BASE/check-the-tests.$name.log)"
        cp "$log" "$TMP_BASE/check-the-tests.$name.log"
        MISSED=$((MISSED + 1))
    fi
done

echo
echo "Summary: ${#MUTANTS[@]} mutants, $CAUGHT caught, $MISSED not caught, $BROKEN could not be made"
if [[ "$BROKEN" -gt 0 ]]; then
    exit 2
fi
[[ "$MISSED" -eq 0 ]]
