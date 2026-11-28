#!/usr/bin/env bash
# =============================================================================
# check-the-tests.sh: proves that run-tests.sh notices the mistakes it exists to catch
# =============================================================================
#
# PURPOSE
#   A test that never fails proves nothing. This script makes copies of the docker_setup
#   folder, each with one deliberate mistake in entrypoint.sh or git-identity.sh (a
#   "mutant"), runs run-tests.sh against each copy, and checks that the tests named below
#   FAIL.
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
#     no-mount-check   the check "is a mount inside this settings folder?" is switched
#                  off. A settings folder with a mount inside it (for example
#                  /home/rstudio/.config with a mount at .config/rstudio) is then handed
#                  to the user with everything in it, and the mount's own folder entry
#                  changes owner.
#     home-mount-check   the check "does the home folder lie on a mount?" is switched off.
#                  A mounted home folder (a mount at /home/rstudio) then changes owner.
#     git-no-covering    in git-identity.sh, the check "which mount holds this path?" is
#                  switched off. With a mounted home folder, the script then writes into
#                  the .ssh folder of the mount.
#     git-fixed-name     in git-identity.sh, new files are written under the fixed name
#                  <file>.impact-new (the script takes a new, unused name from mktemp).
#                  A symbolic link placed under that name is then written through, as root.
#     around-mounts-path-only   in a settings folder with a mount inside it, only the
#                  folders on the way to the mount change owner. The image's own files
#                  next to them (for example .config/rstudio/rstudio-prefs.json) keep
#                  the old owner, and rstudio cannot save its RStudio preferences.
#     git-host-pattern   in git-identity.sh, the SSH rule for github.com is written as
#                  "Host github.com", which compares capital letters exactly. After the
#                  GUI's key scan, git then accepts a false server under the name
#                  GitHub.com.
#     git-no-originalhost   in git-identity.sh, the part "Match originalhost" of the SSH
#                  rule is left out, and only "Match host" stays. With "Host github.com"
#                  and "HostName <address in numbers>" in ~/.ssh/config, git then accepts
#                  a false server at that address.
#     git-no-ssh-github   in git-identity.sh, ssh.github.com is left out of both parts
#                  of the SSH rule. git then accepts a false server under the name
#                  ssh.github.com, for example in ssh://git@ssh.github.com:443/...
#     git-host-no-ssh-github   in git-identity.sh, ssh.github.com is left out of the part
#                  "Match host" only. With a name of the person's own in ~/.ssh/config
#                  ("Host github-443" with "HostName ssh.github.com"), git then accepts
#                  a false server that answers as ssh.github.com on port 443.
#
#   Some checks of the scripts have a second barrier behind them (for example the device
#   number test behind the mount list test for the home folder). Switching off one of
#   them alone changes no result, so such checks have no mutant of their own here.
#
#   For each mutant the script reports "caught" (the expected tests failed) or "NOT
#   caught" (they passed, so the tests have a gap).
#
# WHEN TO RUN IT
#   After run-tests.sh, in the GitHub Actions job of these tests where that job is
#   installed, and by hand after a change to run-tests.sh, lib/make-fixture.sh,
#   lib/record-tree.sh, entrypoint.sh or git-identity.sh. It takes about 11 minutes for
#   the twelve mutants on a computer with 4 processors, once run-tests.sh has run on this
#   computer: run-tests.sh builds the stand-in prerequisite image, which needs the
#   internet once.
#
# HOW TO RUN IT
#   bash tests/docker_setup/check-the-tests.sh              all twelve mutants
#   bash tests/docker_setup/check-the-tests.sh usermod      only the named mutant(s)
#
# WHAT IT CHANGES
#   A temporary folder with the mutated copies (removed at the end), and Docker images
#   named impact-setup-mutant-<name>*:local, which it removes at the end. The
#   docker_setup folder itself is only read.
#
# WHAT IT NEVER TOUCHES
#   The docker_setup folder and the tests themselves (they are only read and copied),
#   other images and containers, and anything outside the temporary folder. The
#   containers that run-tests.sh starts for a mutant see only the test folders that
#   run-tests.sh creates.
#
# SETTINGS
#   IMPACT_TEST_TMP   as for run-tests.sh: where the temporary folders are created.
#
# EXIT CODE
#   0 when every mutant was caught, 1 when at least one was not, 2 when a mutant could
#   not be made (the line it changes was not found in the script).
# =============================================================================

# "set -u" stops the script when it reads a variable that was never set.
set -u

# "$(command)" is replaced by what the command prints. "${BASH_SOURCE[0]}" is the path of
# this script; "cd ... && pwd" turns its folder into a full path. "${NAME:-default}"
# gives the value of NAME, or the default when NAME is empty or not set.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="${IMPACT_DOCKER_SETUP_DIR:-$(cd "$HERE/../.." && pwd)/docker_setup}"
TMP_BASE="${IMPACT_TEST_TMP:-${TMPDIR:-/tmp}}"

# The mutants, in the order they run. "NAME=(a b c)" makes a list. "$#" is the number of
# words given on the command line, "$@" stands for these words, and "${NAME[@]}" for all
# entries of the list NAME, each kept as one word. "[[ A -gt B ]]" is true when the whole
# number A is greater than B.
ALL_MUTANTS=(usermod chown-home to-rocker no-mount-check home-mount-check git-no-covering git-fixed-name
             around-mounts-path-only git-host-pattern git-no-originalhost git-no-ssh-github git-host-no-ssh-github)
if [[ $# -gt 0 ]]; then
    MUTANTS=("$@")
else
    MUTANTS=("${ALL_MUTANTS[@]}")
fi

# mktemp -d creates a new, empty folder with a name nobody else uses. "a || exit 2" ends
# the script with the exit code 2 when a fails.
WORK="$(mktemp -d "$TMP_BASE/impact-setup-mutants.XXXXXX")" || exit 2
# cleanup runs when this script ends, for whatever reason: "trap cleanup EXIT" below
# tells the shell to call it at the exit.
cleanup() {
    rm -rf "$WORK"
    # "docker images --format" prints one image name per line; "|" passes the output of
    # one command to the next one. grep keeps the names of the mutants, and "xargs -r"
    # removes them when there are any. "> /dev/null 2>&1" throws away the output and the
    # error messages ("2>&1" sends the error messages where the output goes).
    docker images --format '{{.Repository}}:{{.Tag}}' | grep '^impact-setup-mutant-' | xargs -r docker rmi -f > /dev/null 2>&1
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Making the mutants
# -----------------------------------------------------------------------------
# mutant_file NAME: the script that the mutant NAME changes. "NAME() { ... }" defines a
# function, used afterwards like a command; "$1" is its first argument. "case VALUE in
# PATTERN) ... ;; esac" runs the part after the first pattern that matches VALUE; "*"
# matches any text, so "git-*" matches every name that starts with "git-".
mutant_file() {
    case "$1" in
        git-*) echo git-identity.sh ;;
        *)     echo entrypoint.sh ;;
    esac
}

# make_mutant NAME: copies docker_setup to $WORK/NAME and changes one of its scripts.
# Every change is made with awk, a small text-processing language: it reads the file
# line by line, and the program between the quotes decides what is printed. In awk,
# "/PATTERN/ { ... }" runs the part in braces for lines that match PATTERN, "next" goes
# on with the next line, "!done" is true while done is still 0, and "exit !done" ends
# awk with 1 (failure) when the line to change was never found.
# "local" makes variables that exist only inside the function. "a || return 1" ends the
# function with failure (1) when a fails.
# Returns 1 when the line to change was not found.
make_mutant() {
    local name="$1" dir="$WORK/$1"
    mkdir -p "$dir"
    cp -r "$SETUP_DIR/." "$dir/"
    local script
    script="$(mutant_file "$name")"
    local file="$dir/$script" new="$dir/$script.new"
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
        home-mount-check)
            # check_home_folder says "yes" at once, so the home folder always counts as
            # the container's own.
            awk '
                /^check_home_folder\(\) \{$/ { print; print "    HOME_OK=1; return 0"; done = 1; next }
                { print }
                END { exit !done }' "$file" > "$new" || return 1
            ;;
        git-no-covering)
            # In belongs_to_container the line with on_container_root is left out.
            awk '
                !done && /^    on_container_root "\$path" \|\| return 1$/ { done = 1; next }
                { print }
                END { exit !done }' "$file" > "$new" || return 1
            ;;
        git-fixed-name)
            # In write_file the new file gets the fixed name TARGET.impact-new, opened with
            # ">" like any other file name.
            awk '
                !done && /^    if ! new_file=\$\(mktemp/ { print "    new_file=\"$target.impact-new\"; if false; then"; done = 1; next }
                { print }
                END { exit !done }' "$file" > "$new" || return 1
            ;;
        around-mounts-path-only)
            # In own_around_mounts, both calls of own_tree for an entry without a mount
            # become ":", the command that does nothing. Only the folders on the way to a
            # mount then change owner.
            awk '
                /^            own_tree "\$child" "\$uid" "\$gid"$/ { print "            :"; done = 1; next }
                { print }
                END { exit !done }' "$file" > "$new" || return 1
            ;;
        git-host-pattern)
            # Both "Match" lines of the SSH rule ("Match originalhost github.com,..." and
            # "Match host github.com,...") become "Host github.com". In the pattern,
            # "(originalhost|host)" matches either word. "done++" counts the changed
            # lines; awk fails unless both were found.
            awk '
                /^Match (originalhost|host) github\.com,github\.com\.,ssh\.github\.com,ssh\.github\.com\.$/ { print "Host github.com"; done++; next }
                { print }
                END { exit (done != 2) }' "$file" > "$new" || return 1
            ;;
        git-no-originalhost)
            # The line "Match originalhost github.com,..." and the setting line below it
            # are left out: "getline" reads the next line, and "next" skips it as well.
            awk '
                /^Match originalhost github\.com,github\.com\.,ssh\.github\.com,ssh\.github\.com\.$/ { getline; done = 1; next }
                { print }
                END { exit !done }' "$file" > "$new" || return 1
            ;;
        git-no-ssh-github)
            # In both "Match" lines, the names ssh.github.com and ssh.github.com. are left
            # out. "sub(A, B)" replaces the first match of the pattern A in the line by B.
            awk '
                /^Match (originalhost|host) github\.com,github\.com\.,ssh\.github\.com,ssh\.github\.com\.$/ { sub(/,ssh\.github\.com,ssh\.github\.com\.$/, ""); done++ }
                { print }
                END { exit (done != 2) }' "$file" > "$new" || return 1
            ;;
        git-host-no-ssh-github)
            # The same in the line "Match host ..." only.
            awk '
                /^Match host github\.com,github\.com\.,ssh\.github\.com,ssh\.github\.com\.$/ { sub(/,ssh\.github\.com,ssh\.github\.com\.$/, ""); done = 1 }
                { print }
                END { exit !done }' "$file" > "$new" || return 1
            ;;
        *)
            # "${NAME[*]}" joins the entries of a list into one text; ">&2" sends the line
            # to the error channel.
            echo "unknown mutant: $name (known: ${ALL_MUTANTS[*]})" >&2
            return 1
            ;;
    esac
    mv "$new" "$file"
    # The mutant must differ from the original; "cmp -s" is silent and succeeds when
    # two files are identical.
    if cmp -s "$file" "$SETUP_DIR/$script"; then
        return 1
    fi
}

# -----------------------------------------------------------------------------
# What each mutant must break
# -----------------------------------------------------------------------------
# groups_for NAME: the test groups of run-tests.sh to run (a pattern for --only).
# expected_failures NAME: the test lines that must fail, one per line. Each line is
# compared with the start of a "FAIL" line of run-tests.sh.
# In a pattern of "case", "|" separates several patterns.
groups_for() {
    case "$1" in
        no-mount-check)                   echo '^settings-mount$' ;;
        home-mount-check|git-no-covering) echo '^home-mount$' ;;
        git-fixed-name)                   echo '^ssh-safety$' ;;
        around-mounts-path-only)          echo '^below-mount$' ;;
        git-host-pattern|git-no-originalhost|git-no-ssh-github|git-host-no-ssh-github) echo '^git$' ;;
        *)                                echo '^valid$' ;;
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
            ;;
        home-mount-check)
            echo "[home-mount] homer: a bind mount at /home/rstudio, REMOTE: mounted trees unchanged, the mounted home folder included"
            echo "[home-mount] volr: a Docker volume at /home/rstudio, REMOTE: the volume at /home/rstudio is unchanged"
            ;;
        git-no-covering)
            echo "[home-mount] homer: a bind mount at /home/rstudio, REMOTE: mounted trees unchanged, the mounted home folder included"
            echo "[home-mount] homel: a bind mount at /home/rstudio, LOCAL: mounted trees unchanged, the mounted home folder included"
            ;;
        git-fixed-name)
            echo "[ssh-safety] links in .ssh: mounted trees unchanged (nothing written, re-owned or changed through a link)"
            ;;
        around-mounts-path-only)
            echo "[below-mount] mounts below .local, .config and .rstudio: ~/.config/rstudio/rstudio-prefs.json belongs to 2001:3001"
            echo "[below-mount] mounts below .local, .config and .rstudio: rstudio can save its RStudio preferences"
            ;;
        git-host-pattern)
            echo "[git] no network: SSH looks up the host key of GitHub.com under the name github.com-published (HostKeyAlias)"
            echo "[git] after the GUI's set-up: the false GitHub.com is refused (git, GIT_SSH_COMMAND)"
            echo "[git] after the GUI's set-up: the false GitHub.com is refused (git, core.sshCommand)"
            ;;
        git-no-originalhost)
            echo "[git] stand-in server, before the GUI's set-up, ~/.ssh/config sends github.com to an address in numbers: SSH looks up the key under github.com-published"
            echo "[git] stand-in server, before the GUI's set-up, address set-up: the false github.com is refused (git, GIT_SSH_COMMAND)"
            echo "[git] after the GUI's set-up, address set-up: the false github.com is refused (git, core.sshCommand)"
            ;;
        git-no-ssh-github)
            echo "[git] no network: SSH looks up the host key of ssh.github.com under the name github.com-published (HostKeyAlias)"
            echo "[git] stand-in server, before the GUI's set-up: the false ssh.github.com is refused (git, GIT_SSH_COMMAND)"
            echo "[git] stand-in server, before the GUI's set-up: the false ssh.github.com on port 443 is refused (plain ssh with accept-new)"
            echo "[git] after the GUI's set-up: the false server of ssh://git@ssh.github.com:443/~/standin/repo.git is refused (git, core.sshCommand)"
            ;;
        git-host-no-ssh-github)
            echo "[git] stand-in server, before the GUI's set-up, ~/.ssh/config sends its own name github-443 to ssh.github.com port 443: SSH looks up the key under github.com-published"
            echo "[git] stand-in server, before the GUI's set-up, port 443 set-up: the false github-443 is refused (git, GIT_SSH_COMMAND)"
            echo "[git] after the script ran again, port 443 set-up: the false github-443 is refused (git, core.sshCommand)"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------
# "$((BROKEN + 1))" is arithmetic: it is replaced by the result of the sum. "continue"
# goes on with the next round of the loop. "if ! command" runs the part after "then"
# when the command fails.
CAUGHT=0
MISSED=0
BROKEN=0
for name in "${MUTANTS[@]}"; do
    echo "=== mutant '$name'"
    if ! make_mutant "$name"; then
        echo "    could not make the mutant: the line to change was not found in $(mutant_file "$name")"
        BROKEN=$((BROKEN + 1))
        continue
    fi
    # The change itself, for the record ("diff" prints the changed lines).
    diff "$SETUP_DIR/$(mutant_file "$name")" "$WORK/$name/$(mutant_file "$name")" | grep '^[<>]' | sed 's/^/    change: /'

    # "NAME=value command" sets the variable NAME for that one command only. A backslash
    # at the end of a line continues the command on the next line.
    log="$WORK/$name.log"
    IMPACT_DOCKER_SETUP_DIR="$WORK/$name" IMPACT_TEST_PREFIX="impact-setup-mutant-$name" \
        IMPACT_TEST_TMP="$TMP_BASE" bash "$HERE/run-tests.sh" --only "$(groups_for "$name")" > "$log" 2>&1
    # The summary line of run-tests.sh, for example "Summary: 92 tests, 80 passed, ...".
    grep '^Summary:' "$log" | sed 's/^/    run-tests.sh: /'
    # Every test that failed against this mutant, for the record.
    grep '^FAIL  ' "$log" | sed 's/^FAIL  /    failed: /'

    # "while IFS= read -r NAME; do ... done < <(command)" runs the loop once for every line
    # that the command prints, with the line in NAME. "IFS=" and "-r" keep spaces and
    # backslashes of the line as they are; "< <(command)" feeds the output of the command
    # to the loop.
    all_failed=1
    while IFS= read -r wanted; do
        # grep -F looks for the text as written, here a FAIL line with the test name; -q
        # prints nothing and only reports whether it found the text. "--" ends the
        # options, so a text that starts with "-" is read as text.
        if grep -q -F -- "FAIL  $wanted" "$log"; then
            echo "    fails as it must: $wanted"
        else
            echo "    PASSES although it must fail: $wanted"
            all_failed=0
        fi
    done < <(expected_failures "$name")
    # Show what the fixture saw: the first lines of the first difference report
    # ("-m 1" stops at the first match, "-A 4" adds the four lines after it).
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

# "${#NAME[@]}" is the number of entries in the list NAME. The last command decides the
# exit code of the script: "[[ A -eq B ]]" succeeds when the whole numbers A and B are equal.
echo
echo "Summary: ${#MUTANTS[@]} mutants, $CAUGHT caught, $MISSED not caught, $BROKEN could not be made"
if [[ "$BROKEN" -gt 0 ]]; then
    exit 2
fi
[[ "$MISSED" -eq 0 ]]
