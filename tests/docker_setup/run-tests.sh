#!/usr/bin/env bash
# =============================================================================
# run-tests.sh: tests of the docker_setup folder with real containers
# =============================================================================
#
# PURPOSE
#   Proves that the start-up scripts in docker_setup/ do what they promise:
#     - the user "rstudio" gets the requested user and group numbers;
#     - nothing in a mounted folder is touched while that happens;
#     - RStudio Server starts, its sign-in works, and its R sessions create files with
#       the requested numbers;
#     - the ready marker appears after all other start-up scripts;
#     - git inside the container knows GitHub's host keys without any network.
#
# HOW IT WORKS
#   The script builds a small test image and starts real containers from it:
#     1. a stand-in for the model's large prerequisite image (the same Rocker image
#        plus a few packages; see Dockerfile.test-prerequisite);
#     2. the test image: the real docker_setup/Dockerfile.IMPACTncdGER, built on that
#        stand-in, with the tiny repository in standin/repository as build context.
#        The start-up scripts are therefore installed exactly as in a model image.
#   Each test starts a container with the options the IMPACT Docker GUI uses, looks at
#   the result with "docker exec", "docker logs" and "docker inspect", and prints one
#   line: "ok" or "FAIL" with the reason. A summary follows at the end.
#
# HOW TO RUN IT
#   bash tests/docker_setup/run-tests.sh                 all tests
#   bash tests/docker_setup/run-tests.sh --list          the names of the test groups
#   bash tests/docker_setup/run-tests.sh --only session  only groups whose name matches
#   bash tests/docker_setup/run-tests.sh --keep          keep containers and files of
#                                                        failed tests for a closer look
#
# WHAT IT NEEDS
#   Docker and bash on a Linux computer, and the right to run "docker".
#   The first run downloads the Rocker image (about 760 MB) and installs three packages
#   with apt-get, so it needs the internet once. Later runs need no network.
#
# SETTINGS (environment variables, all optional)
#   IMPACT_DOCKER_SETUP_DIR   the docker_setup folder to test (default: ../../docker_setup)
#   IMPACT_TEST_TMP           where the work folder is created (default: $TMPDIR or /tmp).
#                             Docker must be able to mount folders from there.
#   IMPACT_TEST_BUILD_OPTS    extra options for "docker build", for example "--network host"
#   IMPACT_TEST_PREFIX        first part of all image, container and network names
#                             (default: impact-setup-test)
#   IMPACT_TEST_PREREQ_IMAGE  name of the stand-in prerequisite image to use or build
#
# WHAT IT CHANGES ON THE COMPUTER
#   - Docker images named <prefix>*:local. They stay, so the next run is fast.
#   - Containers and one network with the label impact.test=<prefix>. They are removed
#     at the end (kept with --keep when a test failed).
#   - One work folder below IMPACT_TEST_TMP with the mounted test folders. It is removed
#     at the end. Files in it belong to several user numbers; they are created and
#     removed inside helper containers, so this script needs no root rights itself.
#
# WHAT IT NEVER TOUCHES
#   The repository itself, other containers and images, and anything outside the work
#   folder.
#
# EXIT CODE
#   0 when every test passed, 1 when at least one failed, 2 when the tests could not run
#   (Docker missing, image build failed).
# =============================================================================

# "set -u" stops the script when it reads a variable that was never set.
set -u

# ---------------------------------------------------------------------------
# Places and names
# ---------------------------------------------------------------------------
# The folder of this script. "${BASH_SOURCE[0]}" is the path of the script file;
# "cd ... && pwd" turns it into a full path.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# "${NAME:-default}" gives the value of NAME, or the default when NAME is empty or not set.
SETUP_DIR="${IMPACT_DOCKER_SETUP_DIR:-$REPO_ROOT/docker_setup}"
PREFIX="${IMPACT_TEST_PREFIX:-impact-setup-test}"
IMG_PREREQ="${IMPACT_TEST_PREREQ_IMAGE:-impact-setup-test-prereq:local}"
IMG="$PREFIX:local"
IMG_CLASH="$PREFIX-clash:local"
IMG_PROBE="$PREFIX-probe:local"
NETWORK="$PREFIX-net"

# The stand-in repository and where things appear inside the container.
REPO_NAME="IMPACT_Standin_Model"
REPO_IN_CONTAINER="/home/rstudio/$REPO_NAME"
STORAGE_IN_CONTAINER="/srv/impact-test-storage/StandinModel"
MARKER="/run/impact-ready"

# The numbers used by the tests.
PERSON_UID=2001      # a person's user number on a shared computer
SHARED_GID=3001      # the number of the shared group there
THIRD="4242:4343"    # the "third account" of the fixture (see lib/make-fixture.sh)

# The value the GUI passes as GIT_SSH_COMMAND (function Get-ContainerGitSshCommand of
# current_version/IMPACT_Docker_GUI.psm1), for the test user "testuser".
GUI_SSH_COMMAND="ssh -i /home/rstudio/.ssh/id_ed25519_testuser -o IdentitiesOnly=yes -o UserKnownHostsFile=/home/rstudio/.ssh/known_hosts -o StrictHostKeyChecking=accept-new"

# Extra options for "docker build". The text is split at spaces into a list.
# shellcheck disable=SC2206
BUILD_OPTS=(${IMPACT_TEST_BUILD_OPTS:-})

# ---------------------------------------------------------------------------
# Options of this script
# ---------------------------------------------------------------------------
ONLY=""      # run only groups whose name matches this pattern
KEEP=0       # 1: keep containers and files of failed tests
LIST=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --only) ONLY="${2:-}"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --list) LIST=1; shift ;;
        -h|--help) sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Counting and printing results
# ---------------------------------------------------------------------------
PASSED=0
FAILED=0
SKIPPED=0
FAILED_NAMES=()
GROUP=""         # name of the group that runs at the moment; printed in every line

# ok NAME: one passed test.
ok() {
    PASSED=$((PASSED + 1))
    printf 'ok    [%s] %s\n' "$GROUP" "$1"
}

# bad NAME [DETAIL...]: one failed test, with lines that explain what was found.
bad() {
    FAILED=$((FAILED + 1))
    FAILED_NAMES+=("[$GROUP] $1")
    printf 'FAIL  [%s] %s\n' "$GROUP" "$1"
    shift
    local line
    for line in "$@"; do
        # A detail can have several lines; each is indented.
        while IFS= read -r line; do printf '        %s\n' "$line"; done <<< "$line"
    done
}

# skip NAME REASON: a test that could not run here.
skip() {
    SKIPPED=$((SKIPPED + 1))
    printf 'skip  [%s] %s (%s)\n' "$GROUP" "$1" "$2"
}

# expect_equal NAME EXPECTED ACTUAL: passes when the two texts are the same.
expect_equal() {
    if [[ "$2" == "$3" ]]; then
        ok "$1"
    else
        bad "$1" "expected: $2" "found:    $3"
    fi
}

# expect_contains NAME TEXT PART: passes when PART occurs in TEXT.
expect_contains() {
    if [[ "$2" == *"$3"* ]]; then
        ok "$1"
    else
        bad "$1" "this text was expected somewhere in the output: $3" "output (last lines):" "$(tail -n 15 <<< "$2")"
    fi
}

# expect_lacks NAME TEXT PART: passes when PART does not occur in TEXT.
expect_lacks() {
    if [[ "$2" != *"$3"* ]]; then
        ok "$1"
    else
        bad "$1" "this text must not occur: $3"
    fi
}

# ---------------------------------------------------------------------------
# Helpers around Docker
# ---------------------------------------------------------------------------

# cname SHORT: the full container name for a short name.
cname() { echo "$PREFIX-$1"; }

# helper CODE: runs shell code as root in a throw-away container that sees the work
# folder at /work and this tests folder at /tests. Used to create, inspect and remove
# files that belong to other user numbers.
helper() {
    docker run --rm --network none --label "impact.test=$PREFIX" --entrypoint /bin/bash \
        -v "$WORK:/work" -v "$HERE:/tests:ro" "$IMG_PREREQ" -c "$1"
}

# make_fixture NAME UID GID: creates the folders to mount in $WORK/NAME (see
# lib/make-fixture.sh). UID and GID are the numbers of the person who owns the
# repository copy.
make_fixture() {
    mkdir -p "$WORK/$1"
    helper "bash /tests/lib/make-fixture.sh /work/$1 $2 $3 /tests/standin/repository" > /dev/null
}

# record NAME LABEL: writes the state of every entry of the fixture NAME to the file
# $WORK/records/NAME.LABEL (see lib/record-tree.sh). The folders are mounted read-only
# for this, so the recording itself changes nothing.
record() {
    mkdir -p "$WORK/records"
    docker run --rm --network none --label "impact.test=$PREFIX" --entrypoint /bin/bash \
        -v "$WORK/$1:/fx:ro" -v "$HERE:/tests:ro" "$IMG_PREREQ" \
        /tests/lib/record-tree.sh repo /fx/repo outputs /fx/outputs synthpop /fx/synthpop \
        storage /fx/storage keys /fx/keys settings /fx/settings > "$WORK/records/$1.$2"
}

# expect_untouched NAME FIXTURE LABEL_BEFORE LABEL_AFTER: the central test. Passes when
# the two records are identical, line by line: same entries, same owner, group, mode,
# size and times. On a difference the first differing lines are shown ("<" before,
# ">" after).
expect_untouched() {
    local before="$WORK/records/$2.$3" after="$WORK/records/$2.$4" count
    count=$(wc -l < "$before")
    if [[ "$count" -lt 100 ]]; then
        bad "$1" "the record before the start has only $count entries; the fixture was not created properly"
    elif cmp -s "$before" "$after"; then
        ok "$1 ($count entries compared)"
    else
        bad "$1" "entries differ (line format: tree|path|type|owner:group|mode|size|modified|changed|link):" \
            "$(diff "$before" "$after" | grep '^[<>]' | head -n 12)" \
            "number of differing lines: $(diff "$before" "$after" | grep -c '^[<>]')"
    fi
}

# start SHORT IMAGE [OPTION...]: starts a container in the background ("-d").
# The label lets the clean-up find every container of these tests.
start() {
    local name image
    name="$(cname "$1")"
    image="$2"
    shift 2
    docker rm -f "$name" > /dev/null 2>&1
    docker run -d --name "$name" --label "impact.test=$PREFIX" "$@" "$image" > /dev/null
}

# wait_ready SHORT [SECONDS]: waits for the ready marker.
#   returns 0 when the marker is there, 1 when the container ended, 2 when time ran out.
wait_ready() {
    local name seconds deadline
    name="$(cname "$1")"
    seconds="${2:-90}"
    # SECONDS is a bash counter: the number of seconds since the script started.
    deadline=$((SECONDS + seconds))
    while (( SECONDS < deadline )); do
        if [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" != "true" ]]; then
            return 1
        fi
        if docker exec "$name" test -f "$MARKER" 2>/dev/null; then
            return 0
        fi
        sleep 0.5
    done
    return 2
}

# wait_exit SHORT [SECONDS]: waits until the container has ended and prints its exit
# code. Prints "running" when it still runs after the time.
wait_exit() {
    local name seconds deadline
    name="$(cname "$1")"
    seconds="${2:-60}"
    deadline=$((SECONDS + seconds))
    while (( SECONDS < deadline )); do
        if [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == "false" ]]; then
            docker inspect -f '{{.State.ExitCode}}' "$name"
            return 0
        fi
        sleep 0.5
    done
    echo running
}

# logs SHORT: the container log without colour codes (Rocker prints its password note
# in colour).
logs() {
    docker logs "$(cname "$1")" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
}

# host_port SHORT: the port on this computer that leads to RStudio in the container.
# "docker port" prints for example 127.0.0.1:32768; the part after the last colon is the port.
host_port() {
    docker port "$(cname "$1")" 8787/tcp 2>/dev/null | head -n 1 | sed 's/.*://'
}

# http_status PORT PATH: asks http://127.0.0.1:PORT/PATH and prints the first line of
# the answer, for example "HTTP/1.1 200 OK". It uses a feature of bash itself: opening
# /dev/tcp/HOST/PORT gives a network connection. No extra program is needed.
http_status() {
    local port="$1" path="$2"
    (
        exec 9<> "/dev/tcp/127.0.0.1/$port" || exit 1
        printf 'GET %s HTTP/1.0\r\nHost: localhost\r\n\r\n' "$path" >&9
        IFS= read -r -t 10 line <&9 || exit 1
        printf '%s\n' "${line%$'\r'}"
    ) 2>/dev/null
}

# wait_rstudio SHORT [SECONDS]: waits until RStudio's sign-in page answers with 200 on
# the published port. Prints the status line it saw last.
wait_rstudio() {
    local seconds deadline port status=""
    seconds="${2:-60}"
    deadline=$((SECONDS + seconds))
    while (( SECONDS < deadline )); do
        port="$(host_port "$1")"
        if [[ -n "$port" ]]; then
            status="$(http_status "$port" /auth-sign-in)"
            if [[ "$status" == HTTP/*" 200"* ]]; then
                echo "$status"
                return 0
            fi
        fi
        sleep 1
    done
    echo "${status:-no answer}"
    return 1
}

# in_container SHORT COMMAND...: runs a command as root inside the container.
in_container() {
    local name
    name="$(cname "$1")"
    shift
    docker exec "$name" "$@"
}

# as_rstudio SHORT COMMAND...: runs a command as the user "rstudio" inside the
# container, the way the GUI does it ("docker exec --user rstudio").
as_rstudio() {
    local name
    name="$(cname "$1")"
    shift
    docker exec --user rstudio "$name" "$@"
}

# owner_of SHORT PATH: prints "UID:GID" of a path inside the container.
owner_of() {
    in_container "$1" stat -c '%u:%g' "$2" 2>&1
}

# The mounts of a session, as lists of options for "docker run".
#   set_mounts FIXTURE [ro]
# fills GUI_MOUNTS (repository, the two result folders inside it, the key) and
# STORAGE_MOUNT (the storage folder outside the home folder). With "ro" the folders are
# mounted read-only. The key is always read-only, as in the GUI.
GUI_MOUNTS=()
STORAGE_MOUNT=()
set_mounts() {
    local f="$WORK/$1" suffix=""
    [[ "${2:-}" == "ro" ]] && suffix=",readonly"
    GUI_MOUNTS=(
        --mount "type=bind,source=$f/repo,target=$REPO_IN_CONTAINER$suffix"
        --mount "type=bind,source=$f/outputs,target=$REPO_IN_CONTAINER/outputs$suffix"
        --mount "type=bind,source=$f/synthpop,target=$REPO_IN_CONTAINER/inputs/synthpop$suffix"
        --mount "type=bind,source=$f/keys/id_ed25519_testuser,target=/keys/id_ed25519_testuser,readonly"
    )
    STORAGE_MOUNT=(
        --mount "type=bind,source=$f/storage,target=$STORAGE_IN_CONTAINER$suffix"
    )
}

# Options every test container gets:
#   --add-host github.com:127.0.0.1   the name github.com leads back into the container
#       itself, where no SSH server runs. git-identity.sh asks GitHub for the user name
#       of the key; this way the question is answered at once with "connection refused"
#       and the tests never depend on the internet. The git tests use another set-up.
#   -p 127.0.0.1::8787                publish RStudio on a free port of this computer,
#       on the loopback address only.
COMMON_OPTS=(--add-host github.com:127.0.0.1 -p 127.0.0.1::8787 --workdir "$REPO_IN_CONTAINER")

# remote_env UID GID: the variables of a REMOTE start in version 2.1 (no password, no
# Rocker user variables). Fills the list ENV_OPTS.
ENV_OPTS=()
remote_env() {
    ENV_OPTS=(
        -e DISABLE_AUTH=false
        -e "IMPACT_UID=$1" -e "IMPACT_GID=$2"
        -e "CONTAINER_REPO_NAME=$REPO_NAME"
        -e SYNC_ENABLED=false
        -e "GIT_SSH_COMMAND=$GUI_SSH_COMMAND"
    )
}

# local_env: the variables of a LOCAL start, in the order of Build-DockerRunCommand.
LOCAL_PASSWORD="local-test-password-1"
local_env() {
    ENV_OPTS=(
        -e "PASSWORD=$LOCAL_PASSWORD"
        -e DISABLE_AUTH=false
        -e USERID=1000 -e GROUPID=1000
        -e "CONTAINER_REPO_NAME=$REPO_NAME"
        -e SYNC_ENABLED=false
        -e "GIT_SSH_COMMAND=$GUI_SSH_COMMAND"
    )
}

# finish_case SHORT FIXTURE: removes the container and the fixture of a test, unless
# --keep was given and something failed.
finish_case() {
    if [[ "$KEEP" == 1 && "$FAILED" -gt 0 ]]; then
        return 0
    fi
    docker rm -f "$(cname "$1")" > /dev/null 2>&1
    if [[ -n "${2:-}" ]]; then
        helper "rm -rf /work/$2" > /dev/null 2>&1
    fi
}

# ---------------------------------------------------------------------------
# Group "build": the images
# ---------------------------------------------------------------------------
group_build() {
    # The Rocker image the model uses: the first word after FROM in the prerequisite
    # Dockerfile. sed prints (p) only lines where the replacement (s) worked.
    local rocker_image
    rocker_image="$(sed -n 's/^FROM[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p' "$SETUP_DIR/Dockerfile.prerequisite.IMPACTncdGER" | head -n 1)"
    if [[ -z "$rocker_image" ]]; then
        bad "the prerequisite Dockerfile names its Rocker image" "no FROM line found in $SETUP_DIR/Dockerfile.prerequisite.IMPACTncdGER"
        return 2
    fi
    ok "the prerequisite Dockerfile names its Rocker image: $rocker_image"

    # The stand-in prerequisite image is reused when it was built for the same Rocker
    # image. A label on the image remembers which one that was.
    local have
    have="$(docker image inspect -f '{{index .Config.Labels "impact.test.rocker"}}' "$IMG_PREREQ" 2>/dev/null)"
    if [[ "$have" != "$rocker_image" ]]; then
        echo "      building the stand-in prerequisite image $IMG_PREREQ from $rocker_image (needs the internet once) ..."
        if ! docker build "${BUILD_OPTS[@]}" --build-arg "ROCKER_IMAGE=$rocker_image" \
                --label "impact.test.rocker=$rocker_image" \
                -f "$HERE/Dockerfile.test-prerequisite" -t "$IMG_PREREQ" "$HERE" > "$WORK/build-prereq.log" 2>&1; then
            bad "the stand-in prerequisite image builds" "$(tail -n 25 "$WORK/build-prereq.log")"
            return 2
        fi
    fi
    ok "the stand-in prerequisite image is ready: $IMG_PREREQ"

    # The build context of the test image: the stand-in repository with the docker_setup
    # folder under test inside it, as in a model repository.
    local context="$WORK/context"
    mkdir -p "$context/docker_setup"
    cp -r "$HERE/standin/repository/." "$context/"
    cp -r "$SETUP_DIR/." "$context/docker_setup/"
    # The real Dockerfile with one change: its first FROM line names the stand-in image.
    awk -v image="$IMG_PREREQ" '!done && /^FROM[ \t]/ {print "FROM " image; done = 1; next} {print}' \
        "$SETUP_DIR/Dockerfile.IMPACTncdGER" > "$WORK/Dockerfile.generated"
    if ! docker build "${BUILD_OPTS[@]}" -f "$WORK/Dockerfile.generated" --build-arg "REPO_NAME=$REPO_NAME" \
            -t "$IMG" "$context" > "$WORK/build-image.log" 2>&1; then
        bad "the test image builds from docker_setup/Dockerfile.IMPACTncdGER" "$(tail -n 25 "$WORK/build-image.log")"
        return 2
    fi
    ok "the test image builds from docker_setup/Dockerfile.IMPACTncdGER"

    expect_equal "the image carries the label impact.setup_version=2" "2" \
        "$(docker image inspect -f '{{index .Config.Labels "impact.setup_version"}}' "$IMG")"
    expect_equal "the entry point of the image is entrypoint.sh" '["/usr/local/bin/entrypoint.sh"]' \
        "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$IMG")"

    # The three scripts inside the image are the files of docker_setup, byte for byte
    # (after removing Windows line ends, as the Dockerfile does). sha256sum prints a
    # checksum; equal checksums mean equal content.
    local pair source target sum_source sum_target
    for pair in "entrypoint.sh:/usr/local/bin/entrypoint.sh" "git-identity.sh:/etc/cont-init.d/git-identity" "impact-ready.sh:/etc/cont-init.d/zz-impact-ready"; do
        source="${pair%%:*}"      # the part before the colon
        target="${pair#*:}"       # the part after the colon
        sum_source="$(tr -d '\r' < "$SETUP_DIR/$source" | sha256sum | cut -d' ' -f1)"
        sum_target="$(docker run --rm --entrypoint /bin/bash "$IMG" -c "test -x $target && sha256sum < $target" | cut -d' ' -f1)"
        expect_equal "$source is installed as $target and can be executed" "$sum_source" "$sum_target"
    done

    # The order of the start-up scripts. The init system sorts the names byte by byte;
    # "LC_ALL=C sort" sorts the same way.
    expect_equal "the ready marker script is the last name in /etc/cont-init.d" "zz-impact-ready" \
        "$(docker run --rm --entrypoint /bin/bash "$IMG" -c 'ls /etc/cont-init.d | LC_ALL=C sort | tail -n 1')"
    expect_equal "the start-up scripts are 01_set_env, 02_userconf, git-identity, zz-impact-ready" \
        "01_set_env 02_userconf git-identity zz-impact-ready" \
        "$(docker run --rm --entrypoint /bin/bash "$IMG" -c 'ls /etc/cont-init.d | LC_ALL=C sort | tr "\n" " " | sed "s/ $//"')"

    # The two variants (see Dockerfile.test-variants).
    local target
    for target in clash probe; do
        if docker build "${BUILD_OPTS[@]}" -f "$HERE/Dockerfile.test-variants" --target "$target" \
                --build-arg "TEST_IMAGE=$IMG" -t "$PREFIX-$target:local" "$HERE" > "$WORK/build-$target.log" 2>&1; then
            ok "the image variant '$target' builds"
        else
            bad "the image variant '$target' builds" "$(tail -n 15 "$WORK/build-$target.log")"
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# Group "static": checks of the script text, without a container
# ---------------------------------------------------------------------------
group_static() {
    local file code
    for file in entrypoint.sh git-identity.sh impact-ready.sh; do
        # "bash -n" reads a script and reports syntax errors; nothing is executed.
        if bash -n "$SETUP_DIR/$file" 2> "$WORK/syntax.log"; then
            ok "$file has no syntax error"
        else
            bad "$file has no syntax error" "$(cat "$WORK/syntax.log")"
        fi
        # The text without comment lines. grep -v drops lines that match: optional
        # spaces, then "#".
        code="$(grep -v '^[[:space:]]*#' "$SETUP_DIR/$file")"

        # Commands that walk through the home folder and its mounts must not occur:
        #   usermod, userdel, useradd, groupmod and the Debian tools deluser, adduser;
        #   chown or chmod with -R (recursive).
        if grep -n -E '(^|[^A-Za-z_])(usermod|userdel|useradd|groupmod|deluser|adduser)([^A-Za-z_]|$)' <<< "$code" > "$WORK/static.log"; then
            bad "$file calls no tool that rewrites accounts and their files" "$(cat "$WORK/static.log")"
        else
            ok "$file calls no tool that rewrites accounts and their files"
        fi
        if grep -n -E '(^|[^A-Za-z_])(chown|chmod|chgrp)[[:space:]]+(-[A-Za-z-]*[[:space:]]+)*-[A-Za-z]*R' <<< "$code" > "$WORK/static.log"; then
            bad "$file has no recursive chown, chmod or chgrp" "$(cat "$WORK/static.log")"
        else
            ok "$file has no recursive chown, chmod or chgrp"
        fi
        # Every "find" must stay on one file system (-xdev) and must not follow links (-P).
        if grep -E '(^|[^A-Za-z_"])find[[:space:]]' <<< "$code" | grep -v -E 'find[[:space:]]+-P[[:space:]].*-xdev' > "$WORK/static.log"; then
            bad "every 'find' in $file uses -P and -xdev" "$(cat "$WORK/static.log")"
        else
            ok "every 'find' in $file uses -P and -xdev"
        fi
    done

    # GitHub's host keys in git-identity.sh are the published ones: each expected line
    # occurs exactly once, and no other line names a github.com key.
    local expected_line count all_good=1
    while IFS= read -r expected_line; do
        count="$(grep -c -x -F -- "$expected_line" "$SETUP_DIR/git-identity.sh" || true)"
        # The first key line starts after GITHUB_HOST_KEYS=' on the same line, the last one
        # ends with the closing quote, so those two are counted without -x.
        [[ "$count" == 1 ]] || count="$(grep -c -F -- "$expected_line" "$SETUP_DIR/git-identity.sh" || true)"
        [[ "$count" == 1 ]] || all_good=0
    done < "$HERE/expected/github_known_hosts"
    local key_lines
    key_lines="$(grep -c -E 'github\.com (ssh-|ecdsa-)' "$SETUP_DIR/git-identity.sh" || true)"
    if [[ "$all_good" == 1 && "$key_lines" == 3 ]]; then
        ok "git-identity.sh holds GitHub's three published host keys and no other key for github.com"
    else
        bad "git-identity.sh holds GitHub's three published host keys and no other key for github.com" \
            "lines that name a github.com key: $key_lines (expected 3); all three published lines found: $all_good"
    fi

    code="$(grep -v '^[[:space:]]*#' "$SETUP_DIR/git-identity.sh")"
    expect_lacks "git-identity.sh fetches no host key from the network (no ssh-keyscan)" "$code" "ssh-keyscan"
    expect_lacks "git-identity.sh never switches the host key check off (StrictHostKeyChecking=no)" "$code" "StrictHostKeyChecking=no"
    expect_lacks "git-identity.sh never throws host keys away (UserKnownHostsFile=/dev/null)" "$code" "UserKnownHostsFile=/dev/null"

    # The GUI and the script must write the same SSH command for git. The GUI code is
    # only there when these tests run inside the GUI repository.
    local module="$REPO_ROOT/current_version/IMPACT_Docker_GUI.psm1"
    if [[ -f "$module" ]]; then
        # grep -F looks for the text exactly as written; the single quotes keep the
        # dollar signs of the PowerShell text away from bash.
        # shellcheck disable=SC2016
        if grep -q -F 'return "ssh -i $keyPath -o IdentitiesOnly=yes -o UserKnownHostsFile=$knownHost -o StrictHostKeyChecking=accept-new"' "$module" \
           && grep -q -F '$keyPath   = "/home/rstudio/.ssh/id_ed25519_$UserName"' "$module" \
           && grep -q -F "\$knownHost = '/home/rstudio/.ssh/known_hosts'" "$module" \
           && grep -q -F 'SSH_OPTIONS="-o IdentitiesOnly=yes -o UserKnownHostsFile=$USER_KNOWN_HOSTS -o StrictHostKeyChecking=accept-new"' "$SETUP_DIR/git-identity.sh" \
           && grep -q -F 'USER_KNOWN_HOSTS="$SSH_DIR/known_hosts"' "$SETUP_DIR/git-identity.sh"; then
            ok "git-identity.sh and the GUI (Get-ContainerGitSshCommand) use the same SSH options, key path and known hosts file"
        else
            bad "git-identity.sh and the GUI (Get-ContainerGitSshCommand) use the same SSH options, key path and known hosts file" \
                "the expected lines were not found in $module or in git-identity.sh; one of the two was changed"
        fi
    else
        skip "git-identity.sh and the GUI use the same SSH options" "the GUI code is not next to these tests"
    fi
}

# ---------------------------------------------------------------------------
# Group "valid": starts that must work, each with the full fixture
# ---------------------------------------------------------------------------

# valid_case ID TITLE IMAGE WANT_UID WANT_GID STORAGE [OPTION...]
#   ID        short name of the case (also the container and fixture name)
#   TITLE     what the case is about, for the output
#   IMAGE     the image to start
#   WANT_UID, WANT_GID   the numbers "rstudio" must have afterwards
#   STORAGE   "storage" to mount the storage folder as well, "nostorage" otherwise
#   OPTION    the "docker run" options of the case; ENV_OPTS must be set before the call
valid_case() {
    local id="$1" title="$2" image="$3" want_uid="$4" want_gid="$5" storage="$6"
    shift 6
    local t="$id: $title:"

    # The person who owns the repository copy has the numbers the case asks for.
    make_fixture "$id" "$want_uid" "$want_gid"
    set_mounts "$id"
    local storage_opts=()
    [[ "$storage" == "storage" ]] && storage_opts=("${STORAGE_MOUNT[@]}")
    record "$id" before

    local started=$SECONDS state
    start "$id" "$image" "${ENV_OPTS[@]}" "${COMMON_OPTS[@]}" "${GUI_MOUNTS[@]}" "${storage_opts[@]}" "$@"
    wait_ready "$id" 90
    state=$?
    if [[ "$state" != 0 ]]; then
        bad "$t the container reaches the ready marker" "result: $([[ $state == 1 ]] && echo 'the container ended' || echo 'no marker after 90 seconds')" "$(logs "$id" | tail -n 20)"
        finish_case "$id" "$id"
        return
    fi
    ok "$t the container reaches the ready marker (after $((SECONDS - started)) s)"

    local status
    if status="$(wait_rstudio "$id" 60)"; then
        ok "$t RStudio Server answers on the published port ($status)"
    else
        bad "$t RStudio Server answers on the published port" "last answer: $status"
    fi

    # The central claim. Everything the start-up does has happened by now.
    record "$id" after-start
    expect_untouched "$t mounted trees unchanged after the start: owner, group, mode and times" "$id" before after-start

    expect_equal "$t 'id rstudio' shows the numbers $want_uid:$want_gid" "$want_uid:$want_gid" \
        "$(in_container "$id" id -u rstudio):$(in_container "$id" id -g rstudio)"
    # "id -Gn" lists the names of all groups of the user. The group "staff" owns the
    # shared R library; "rstudio" must stay a member to install packages.
    expect_contains "$t rstudio is still a member of the group 'staff' (R library)" " $(in_container "$id" id -Gn rstudio) " " staff "
    expect_equal "$t the home folder entry belongs to $want_uid:$want_gid" "$want_uid:$want_gid" "$(owner_of "$id" /home/rstudio)"

    # Nothing in the home folder that belongs to the image is left with another owner.
    # The search stays on the container's own file system (-xdev), so mounts are not entered.
    local strays
    strays="$(in_container "$id" find -P /home/rstudio -xdev -mindepth 1 \( ! -uid "$want_uid" -o ! -gid "$want_gid" \) -not -path "$REPO_IN_CONTAINER" -not -path "$REPO_IN_CONTAINER/*" -printf '%U:%G %p\n' 2>&1 | head -n 10)"
    expect_equal "$t every entry of the image in the home folder belongs to $want_uid:$want_gid" "" "$strays"

    # The marker and the order of the start-up scripts, read from the container log.
    # The init system prints "[cont-init.d] NAME: executing..." before each script and
    # "[cont-init.d] NAME: exited N." after it.
    local log last_script
    log="$(logs "$id")"
    expect_contains "$t the marker file holds the word 'ready'" "$(in_container "$id" cat "$MARKER" 2>&1)" "ready "
    last_script="$(grep -o '^\[cont-init.d\] [^:]*: executing' <<< "$log" | tail -n 1)"
    expect_equal "$t the marker script ran as the last start-up script" "[cont-init.d] zz-impact-ready: executing" "$last_script"
    # Line numbers in the log: git-identity must have ended before the marker script began.
    local line_git line_ready
    line_git="$(grep -n '^\[cont-init.d\] git-identity: exited' <<< "$log" | head -n 1 | cut -d: -f1)"
    line_ready="$(grep -n '^\[cont-init.d\] zz-impact-ready: executing' <<< "$log" | head -n 1 | cut -d: -f1)"
    if [[ -n "$line_git" && -n "$line_ready" && "$line_git" -lt "$line_ready" ]]; then
        ok "$t git-identity had ended before the marker script started (log lines $line_git and $line_ready)"
    else
        bad "$t git-identity had ended before the marker script started" "log line of 'git-identity: exited': ${line_git:-missing}; of 'zz-impact-ready: executing': ${line_ready:-missing}"
    fi
    expect_contains "$t all start-up scripts ended with exit code 0" \
        "$(grep -c '^\[cont-init.d\] .*: exited 0\.' <<< "$log") scripts" "4 scripts"

    # Files created by rstudio carry the numbers. This writes into the mounts, so it
    # comes after the comparison above. "writable" is the one folder of the fixture
    # where every user may create files.
    as_rstudio "$id" touch "$REPO_IN_CONTAINER/mixed/writable/made-by-rstudio" > "$WORK/touch.log" 2>&1
    expect_equal "$t a file created by rstudio in the repository mount belongs to $want_uid:$want_gid" "$want_uid:$want_gid" \
        "$(owner_of "$id" "$REPO_IN_CONTAINER/mixed/writable/made-by-rstudio")$(cat "$WORK/touch.log")"
    as_rstudio "$id" touch "$REPO_IN_CONTAINER/outputs/writable/made-by-rstudio" > "$WORK/touch.log" 2>&1
    expect_equal "$t a file created by rstudio in the outputs mount belongs to $want_uid:$want_gid" "$want_uid:$want_gid" \
        "$(owner_of "$id" "$REPO_IN_CONTAINER/outputs/writable/made-by-rstudio")$(cat "$WORK/touch.log")"
    if [[ "$storage" == "storage" ]]; then
        as_rstudio "$id" touch "$STORAGE_IN_CONTAINER/outputs/made-by-rstudio" > "$WORK/touch.log" 2>&1
        expect_equal "$t a file created by rstudio in the storage mount belongs to $want_uid:$want_gid" "$want_uid:$want_gid" \
            "$(owner_of "$id" "$STORAGE_IN_CONTAINER/outputs/made-by-rstudio")$(cat "$WORK/touch.log")"
    fi

    # After these writes, every entry that existed before still has its owner, group
    # and mode. The times of the "writable" folders changed, so times are left out here:
    # cut keeps the fields tree, path, type, owner:group and mode.
    record "$id" after-writes
    local lost
    lost="$(LC_ALL=C comm -23 <(cut -d'|' -f1-5 "$WORK/records/$id.before" | LC_ALL=C sort) <(cut -d'|' -f1-5 "$WORK/records/$id.after-writes" | LC_ALL=C sort) | head -n 10)"
    expect_equal "$t after rstudio created files, all earlier entries keep owner, group and mode" "" "$lost"

    finish_case "$id" "$id"
}

group_valid() {
    # 1. REMOTE in version 2.1: another user number and another group number.
    remote_env "$PERSON_UID" "$SHARED_GID"
    valid_case remote "other UID and GID ($PERSON_UID:$SHARED_GID)" "$IMG" "$PERSON_UID" "$SHARED_GID" storage

    # 2. The user number the image already has, with another group number.
    remote_env 1000 "$SHARED_GID"
    valid_case uid1000 "UID 1000 with another GID (1000:$SHARED_GID)" "$IMG" 1000 "$SHARED_GID" storage

    # 3. Neither variable, and no Rocker variable: an image started by hand.
    ENV_OPTS=(-e "PASSWORD=$LOCAL_PASSWORD" -e "CONTAINER_REPO_NAME=$REPO_NAME")
    valid_case plain "neither IMPACT variable" "$IMG" 1000 1000 nostorage

    # 4. LOCAL: exactly the variables the GUI passes there (USERID and GROUPID are 1000).
    local_env
    valid_case local "the LOCAL start of the GUI (USERID=1000, GROUPID=1000)" "$IMG" 1000 1000 nostorage

    # 5. Both sets of variables. IMPACT_UID and IMPACT_GID win; Rocker must not see
    #    USERID and GROUPID, or it would walk through the mounts.
    remote_env "$PERSON_UID" "$SHARED_GID"
    ENV_OPTS+=(-e USERID=2002 -e GROUPID=3002)
    valid_case both "IMPACT variables and Rocker variables together" "$IMG" "$PERSON_UID" "$SHARED_GID" storage

    # 6. A group number that a group of the image already has (variant image "clash":
    #    its group "imagegroup" has the number 1234).
    remote_env "$PERSON_UID" 1234
    valid_case gidused "a GID that a group of the image already uses ($PERSON_UID:1234)" "$IMG_CLASH" "$PERSON_UID" 1234 storage
}

# ---------------------------------------------------------------------------
# Group "rocker-env": what the Rocker start-up sees of USERID and GROUPID
# ---------------------------------------------------------------------------
group_rocker_env() {
    # The init system stores the container's variables as files in
    # /var/run/s6/container_environment, one file per variable. Rocker's scripts read
    # them from there. With IMPACT_UID set, the files USERID and GROUPID must be missing.
    make_fixture rockerenv "$PERSON_UID" "$SHARED_GID"
    set_mounts rockerenv
    remote_env "$PERSON_UID" "$SHARED_GID"
    start rockerenv "$IMG" "${ENV_OPTS[@]}" -e USERID=2002 -e GROUPID=3002 "${COMMON_OPTS[@]}" "${GUI_MOUNTS[@]}"
    if wait_ready rockerenv 90; then
        local seen log
        seen="$(in_container rockerenv /bin/bash -c 'ls /var/run/s6/container_environment | grep -E "^(USERID|GROUPID|IMPACT_UID|IMPACT_GID)$" | tr "\n" " "')"
        expect_equal "with both sets of variables, the Rocker start-up sees IMPACT_UID and IMPACT_GID only" "IMPACT_GID IMPACT_UID " "$seen"
        log="$(logs rockerenv)"
        expect_lacks "the Rocker start-up did not delete and recreate the user" "$log" "deleting the default user"
        expect_lacks "the Rocker start-up did not change the group" "$log" "Modifying primary group"
        expect_contains "the log says that USERID and GROUPID are ignored" "$log" "USERID=2002 and GROUPID=3002 are ignored"
    else
        bad "the container with both sets of variables reaches the ready marker" "$(logs rockerenv | tail -n 20)"
    fi
    finish_case rockerenv rockerenv

    # Without the IMPACT variables the Rocker variables pass through unchanged, so an
    # older GUI keeps working with the new image.
    make_fixture rockerenv2 1000 1000
    set_mounts rockerenv2
    local_env
    start rockerenv2 "$IMG" "${ENV_OPTS[@]}" "${COMMON_OPTS[@]}" "${GUI_MOUNTS[@]}"
    if wait_ready rockerenv2 90; then
        expect_equal "without the IMPACT variables, USERID and GROUPID reach the Rocker start-up" "GROUPID USERID " \
            "$(in_container rockerenv2 /bin/bash -c 'ls /var/run/s6/container_environment | grep -E "^(USERID|GROUPID|IMPACT_UID|IMPACT_GID)$" | tr "\n" " "')"
    else
        bad "the LOCAL container reaches the ready marker" "$(logs rockerenv2 | tail -n 20)"
    fi
    finish_case rockerenv2 rockerenv2
}

# ---------------------------------------------------------------------------
# Group "invalid": values that must end the container
# ---------------------------------------------------------------------------

# invalid_case TITLE WANT_EXIT WANT_TEXT IMAGE [OPTION...]: starts a container that must
# end by itself with the exit code WANT_EXIT and a log line that holds "ERROR" and
# WANT_TEXT.
INVALID_COUNT=0
invalid_case() {
    local title="$1" want_exit="$2" want_text="$3" image="$4"
    shift 4
    INVALID_COUNT=$((INVALID_COUNT + 1))
    local id="invalid$INVALID_COUNT" code log
    start "$id" "$image" -e "CONTAINER_REPO_NAME=$REPO_NAME" "${COMMON_OPTS[@]}" "${GUI_MOUNTS[@]}" "${STORAGE_MOUNT[@]}" "$@"
    code="$(wait_exit "$id" 60)"
    log="$(logs "$id")"
    if [[ "$code" == "$want_exit" && "$log" == *"ERROR"* && "$log" == *"$want_text"* && "$log" != *"[s6-init]"* ]]; then
        ok "$title: the container ends with exit code $want_exit and a clear log line"
    else
        bad "$title: the container ends with exit code $want_exit and a clear log line" \
            "exit code: $code (expected $want_exit)" \
            "the log must hold 'ERROR' and '$want_text', and the Rocker start-up ('[s6-init]') must not have begun" \
            "log:" "$(tail -n 8 <<< "$log")"
    fi
    docker rm -f "$(cname "$id")" > /dev/null 2>&1
}

group_invalid() {
    # One fixture for all cases: none of them may touch it.
    make_fixture invalid "$PERSON_UID" "$SHARED_GID"
    set_mounts invalid
    record invalid before

    local value
    # Each kind of invalid user number. The quotes keep empty text and spaces intact.
    for value in "abc" "999" "60001" "0" "" "2001 " " 2001" "2e3" "-2001" "+2001" "02001" "2001.5" "0x7d1" "2001;id" "99999999999999999999"; do
        invalid_case "IMPACT_UID='$value'" 64 "IMPACT_UID" "$IMG" -e "IMPACT_UID=$value" -e "IMPACT_GID=$SHARED_GID"
    done
    # Each kind of invalid group number.
    for value in "abc" "999" "60001" "0" "" "3001 " "3e3" "-3001" "03001"; do
        invalid_case "IMPACT_GID='$value'" 64 "IMPACT_GID" "$IMG" -e "IMPACT_UID=$PERSON_UID" -e "IMPACT_GID=$value"
    done
    # Only one of the two.
    invalid_case "IMPACT_UID without IMPACT_GID" 64 "IMPACT_GID is missing" "$IMG" -e "IMPACT_UID=$PERSON_UID"
    invalid_case "IMPACT_GID without IMPACT_UID" 64 "IMPACT_UID is missing" "$IMG" -e "IMPACT_GID=$SHARED_GID"
    # Invalid values stay invalid when the Rocker variables are valid.
    invalid_case "IMPACT_UID='abc' with valid USERID and GROUPID" 64 "IMPACT_UID" "$IMG" -e IMPACT_UID=abc -e "IMPACT_GID=$SHARED_GID" -e USERID=2001 -e GROUPID=3001
    # A user number that another account of the image has (variant image "clash": its
    # account "otheraccount" has the number 1777).
    invalid_case "IMPACT_UID=1777, the number of another account of the image" 65 "otheraccount" "$IMG_CLASH" -e IMPACT_UID=1777 -e "IMPACT_GID=$SHARED_GID"

    record invalid after
    expect_untouched "mounted trees unchanged after all invalid starts: owner, group, mode and times" invalid before after
    finish_case invalid1 invalid
}

# ---------------------------------------------------------------------------
# Group "restart": the same container stopped and started again; the marker order
# ---------------------------------------------------------------------------
group_restart() {
    make_fixture restart "$PERSON_UID" "$SHARED_GID"
    set_mounts restart
    remote_env "$PERSON_UID" "$SHARED_GID"
    record restart before

    # The variant image "probe" has one more start-up script, directly before the marker
    # script. It notes whether the marker exists when it starts, then waits 3 seconds.
    start restart "$IMG_PROBE" "${ENV_OPTS[@]}" "${COMMON_OPTS[@]}" "${GUI_MOUNTS[@]}" "${STORAGE_MOUNT[@]}"

    # While the probe script runs, the marker must not be there. Look every 0.2 seconds
    # until the probe has ended.
    local name seen_early=0 looks=0 deadline=$((SECONDS + 60))
    name="$(cname restart)"
    while (( SECONDS < deadline )); do
        if docker exec "$name" test -f /run/impact-test-probe-end 2>/dev/null; then
            break
        fi
        if docker exec "$name" test -f /run/impact-test-probe 2>/dev/null; then
            looks=$((looks + 1))
            docker exec "$name" test -f "$MARKER" 2>/dev/null && seen_early=1
        fi
        sleep 0.2
    done
    if [[ "$looks" -ge 3 && "$seen_early" == 0 ]]; then
        ok "first start: no marker while an earlier start-up script still runs (looked $looks times)"
    else
        bad "first start: no marker while an earlier start-up script still runs" "looks while the probe ran: $looks (at least 3 needed); marker seen too early: $seen_early"
    fi
    if wait_ready restart 60; then
        ok "first start: the marker appears after the probe script"
    else
        bad "first start: the marker appears after the probe script" "$(logs restart | tail -n 15)"
        finish_case restart restart
        return
    fi
    expect_equal "first start: the probe found no marker" "absent" "$(in_container restart cat /run/impact-test-probe)"
    # The marker file was written after the probe ended. "stat -c %Y" prints the time of
    # the last change of a file in whole seconds; the probe's time is cut to whole seconds.
    local marker_time probe_end
    marker_time="$(in_container restart stat -c %Y "$MARKER")"
    probe_end="$(in_container restart cut -d. -f1 /run/impact-test-probe-end)"
    if [[ "$marker_time" -ge "$probe_end" ]]; then
        ok "first start: the marker was written after the probe ended"
    else
        bad "first start: the marker was written after the probe ended" "marker written at $marker_time, probe ended at $probe_end (seconds)"
    fi
    wait_rstudio restart 60 > /dev/null
    local first_marker
    first_marker="$(in_container restart cat "$MARKER")"
    record restart after-first-start
    expect_untouched "first start: mounted trees unchanged" restart before after-first-start

    # Stop and start the same container. Its files, the old marker included, are kept
    # by Docker, and the entry point runs a second time.
    sleep 1
    docker stop -t 10 "$name" > /dev/null
    record restart after-stop
    expect_untouched "after 'docker stop': mounted trees unchanged" restart before after-stop
    docker start "$name" > /dev/null
    if wait_ready restart 90; then
        ok "second start of the same container: the ready marker appears again"
    else
        bad "second start of the same container: the ready marker appears again" "$(logs restart | tail -n 15)"
        finish_case restart restart
        return
    fi
    expect_equal "second start: the marker of the first start was gone before the start-up scripts ran" "absent" \
        "$(in_container restart cat /run/impact-test-probe)"
    local second_marker
    second_marker="$(in_container restart cat "$MARKER")"
    if [[ "$second_marker" != "$first_marker" ]]; then
        ok "second start: the marker is new ($second_marker)"
    else
        bad "second start: the marker is new" "both starts wrote: $first_marker"
    fi
    expect_equal "second start: 'id rstudio' still shows $PERSON_UID:$SHARED_GID" "$PERSON_UID:$SHARED_GID" \
        "$(in_container restart id -u rstudio):$(in_container restart id -g rstudio)"
    expect_contains "second start: the log says the account files needed no change" "$(logs restart)" "already has the user number $PERSON_UID and the group number $SHARED_GID"
    expect_equal "second start: exactly one line for rstudio in /etc/passwd and one in /etc/group" "1 1" \
        "$(in_container restart grep -c '^rstudio:' /etc/passwd) $(in_container restart grep -c '^rstudio:' /etc/group)"
    local status
    if status="$(wait_rstudio restart 60)"; then
        ok "second start: RStudio Server answers again ($status)"
    else
        bad "second start: RStudio Server answers again" "last answer: $status"
    fi
    record restart after-second-start
    expect_untouched "second start: mounted trees unchanged" restart before after-second-start
    finish_case restart restart
}

# ---------------------------------------------------------------------------
# Group "readonly": every folder mounted read-only
# ---------------------------------------------------------------------------
group_readonly() {
    make_fixture readonly "$PERSON_UID" "$SHARED_GID"
    set_mounts readonly ro
    remote_env "$PERSON_UID" "$SHARED_GID"
    record readonly before
    start readonly "$IMG" "${ENV_OPTS[@]}" "${COMMON_OPTS[@]}" "${GUI_MOUNTS[@]}" "${STORAGE_MOUNT[@]}"
    if wait_ready readonly 90; then
        ok "read-only mounts: the container reaches the ready marker"
        expect_equal "read-only mounts: 'id rstudio' shows $PERSON_UID:$SHARED_GID" "$PERSON_UID:$SHARED_GID" \
            "$(in_container readonly id -u rstudio):$(in_container readonly id -g rstudio)"
        local status log
        if status="$(wait_rstudio readonly 60)"; then
            ok "read-only mounts: RStudio Server answers ($status)"
        else
            bad "read-only mounts: RStudio Server answers" "last answer: $status"
        fi
        log="$(logs readonly)"
        expect_lacks "read-only mounts: the start-up tried to write nothing there (no 'Read-only file system' in the log)" "$log" "Read-only file system"
        expect_contains "read-only mounts: all start-up scripts ended with exit code 0" \
            "$(grep -c '^\[cont-init.d\] .*: exited 0\.' <<< "$log") scripts" "4 scripts"
        # The mounts really are read-only: rstudio cannot create a file there.
        if as_rstudio readonly touch "$REPO_IN_CONTAINER/mixed/writable/x" 2>/dev/null; then
            bad "read-only mounts: the test set-up mounts the folders read-only" "a file could be created in the repository mount"
        else
            ok "read-only mounts: the test set-up mounts the folders read-only"
        fi
    else
        bad "read-only mounts: the container reaches the ready marker" "$(logs readonly | tail -n 20)"
    fi
    record readonly after
    expect_untouched "read-only mounts: mounted trees unchanged" readonly before after
    finish_case readonly readonly
}

# ---------------------------------------------------------------------------
# Group "settings-mount": RStudio's settings folders are themselves mounts
# ---------------------------------------------------------------------------
group_settings_mount() {
    make_fixture setmount "$PERSON_UID" "$SHARED_GID"
    set_mounts setmount
    remote_env "$PERSON_UID" "$SHARED_GID"
    record setmount before
    local s="$WORK/setmount/settings"
    # Four mounts over places the start-up scripts normally write to:
    #   .config/rstudio  a mount inside an entry of the home folder
    #   .ssh, .local     entries of the home folder that are mounts themselves
    #   .gitconfig       a single mounted file
    # Their content belongs to the third account and must stay exactly as it is.
    start setmount "$IMG" "${ENV_OPTS[@]}" "${COMMON_OPTS[@]}" "${GUI_MOUNTS[@]}" "${STORAGE_MOUNT[@]}" \
        --mount "type=bind,source=$s/config-rstudio,target=/home/rstudio/.config/rstudio" \
        --mount "type=bind,source=$s/ssh,target=/home/rstudio/.ssh" \
        --mount "type=bind,source=$s/local,target=/home/rstudio/.local" \
        --mount "type=bind,source=$s/gitconfig,target=/home/rstudio/.gitconfig"
    if wait_ready setmount 90; then
        ok "settings folders as mounts: the container reaches the ready marker"
        local status log
        if status="$(wait_rstudio setmount 60)"; then
            ok "settings folders as mounts: RStudio Server answers ($status)"
        else
            bad "settings folders as mounts: RStudio Server answers" "last answer: $status"
        fi
        record setmount after
        expect_untouched "settings folders as mounts: all mounted trees unchanged, the settings mounts included" setmount before after
        expect_equal "settings folders as mounts: 'id rstudio' shows $PERSON_UID:$SHARED_GID" "$PERSON_UID:$SHARED_GID" \
            "$(in_container setmount id -u rstudio):$(in_container setmount id -g rstudio)"
        expect_equal "settings folders as mounts: the mounted .ssh keeps its owner" "$THIRD" "$(owner_of setmount /home/rstudio/.ssh)"
        expect_equal "settings folders as mounts: the mounted .gitconfig keeps its content" "Name From Outside" \
            "$(in_container setmount git config --file /home/rstudio/.gitconfig user.name 2>&1)"
        log="$(logs setmount)"
        expect_contains "settings folders as mounts: the log names the skipped entry .config" "$log" "Owner of /home/rstudio/.config left unchanged: a mount is at or inside it"
        expect_contains "settings folders as mounts: the log names the skipped entry .ssh" "$log" "Owner of /home/rstudio/.ssh left unchanged: a mount is at or inside it"
        expect_contains "settings folders as mounts: the log says the preferences file was not written" "$log" "Settings file /home/rstudio/.config/rstudio/rstudio-prefs.json not written"
        expect_contains "settings folders as mounts: git-identity says it writes nothing into .ssh" "$log" "/home/rstudio/.ssh is a mount"
        # GitHub's keys are still known through the system-wide file.
        expect_equal "settings folders as mounts: GitHub's keys are in the system-wide known hosts file" \
            "$(cat "$HERE/expected/github_known_hosts")" "$(in_container setmount cat /etc/ssh/ssh_known_hosts 2>&1)"
        # Entries of the image that hold no mount were still handed over.
        expect_equal "settings folders as mounts: .rstudio (no mount) belongs to $PERSON_UID:$SHARED_GID" "$PERSON_UID:$SHARED_GID" "$(owner_of setmount /home/rstudio/.rstudio)"
    else
        bad "settings folders as mounts: the container reaches the ready marker" "$(logs setmount | tail -n 20)"
    fi
    finish_case setmount setmount
}

# ---------------------------------------------------------------------------
# Group "symlink": symbolic links in the home folder that point into a mount
# ---------------------------------------------------------------------------
group_symlink() {
    make_fixture symlink "$PERSON_UID" "$SHARED_GID"
    set_mounts symlink
    remote_env "$PERSON_UID" "$SHARED_GID"
    start symlink "$IMG" "${ENV_OPTS[@]}" "${COMMON_OPTS[@]}" "${GUI_MOUNTS[@]}" "${STORAGE_MOUNT[@]}"
    if ! wait_ready symlink 90; then
        bad "symbolic links: the container reaches the ready marker" "$(logs symlink | tail -n 20)"
        finish_case symlink symlink
        return
    fi
    # Replace entries of the home folder by links into the repository mount. The link
    # targets belong to root and to the third account. Then start the container again:
    # the entry point finds the links where it normally finds its own folders.
    local m="$REPO_IN_CONTAINER/mixed"
    in_container symlink /bin/bash -c "
        cd /home/rstudio &&
        rm -rf .config .rstudio .ssh .cache .gitconfig .local &&
        ln -s '$m/owned-by-third'          .config &&
        ln -s '$m/owned-by-root'           .rstudio &&
        ln -s '$m/nested/level2'           .ssh &&
        ln -s '$m/owned-by-root/closed-700' .cache &&
        ln -s '$m/owned-by-third/file-640' .gitconfig &&
        ln -s '$STORAGE_IN_CONTAINER/owned-by-third' .local"
    docker stop -t 10 "$(cname symlink)" > /dev/null
    record symlink before
    docker start "$(cname symlink)" > /dev/null
    if wait_ready symlink 90; then
        ok "symbolic links into mounts: the container starts again and reaches the ready marker"
        wait_rstudio symlink 60 > /dev/null
        record symlink after
        expect_untouched "symbolic links into mounts: mounted trees unchanged (no owner changed and no file written through a link)" symlink before after
        local log
        log="$(logs symlink)"
        expect_contains "symbolic links into mounts: the log names a skipped link" "$log" "Owner of /home/rstudio/.cache left unchanged: it is a symbolic link"
        expect_contains "symbolic links into mounts: the settings file behind a link was not written" "$log" "Settings file /home/rstudio/.config/rstudio/rstudio-prefs.json not written"
        expect_contains "symbolic links into mounts: git-identity writes nothing through the .ssh link" "$log" "/home/rstudio/.ssh is a mount, has a mount inside it, or is reached through a symbolic link"
        expect_equal "symbolic links into mounts: the links themselves are still links" "6" \
            "$(in_container symlink /bin/bash -c 'cd /home/rstudio && for e in .config .rstudio .ssh .cache .gitconfig .local; do test -L $e && echo x; done | wc -l')"
    else
        bad "symbolic links into mounts: the container starts again and reaches the ready marker" "$(logs symlink | tail -n 20)"
    fi
    finish_case symlink symlink
}

# ---------------------------------------------------------------------------
# Group "session": password, RStudio sign-in, R session, R library
# ---------------------------------------------------------------------------

# signin SHORT PASSWORD: tries RStudio's real sign-in inside the container and prints
# ACCEPTED, REFUSED or the client's error text. The password travels through standard
# input ("docker exec -i"), never through a command line.
signin() {
    printf '%s\n' "$2" | docker exec -i "$(cname "$1")" python3 /tmp/impact-test/rstudio_client.py signin http://127.0.0.1:8787 rstudio 2>&1 | tail -n 1
}

# run_in_session SHORT PASSWORD R_CODE: lets the RStudio session of rstudio run R code.
# The code is stored as a file in the container and the session runs source(file).
run_in_session() {
    local name
    name="$(cname "$1")"
    printf '%s\n' "$3" | docker exec -i "$name" /bin/bash -c 'cat > /tmp/impact-test/code.R && chmod 644 /tmp/impact-test/code.R'
    printf '%s\n' "$2" | docker exec -i "$name" python3 /tmp/impact-test/rstudio_client.py run http://127.0.0.1:8787 rstudio /tmp/impact-test/code.R 2>&1
}

group_session() {
    make_fixture session "$PERSON_UID" "$SHARED_GID"
    set_mounts session
    remote_env "$PERSON_UID" "$SHARED_GID"
    # A REMOTE start: no PASSWORD variable.
    start session "$IMG" "${ENV_OPTS[@]}" "${COMMON_OPTS[@]}" "${GUI_MOUNTS[@]}" "${STORAGE_MOUNT[@]}"
    if ! wait_ready session 90 || ! wait_rstudio session 60 > /dev/null; then
        bad "session: the container starts and RStudio answers" "$(logs session | tail -n 20)"
        finish_case session session
        return
    fi
    local name
    name="$(cname session)"
    # The test client goes into the container with "docker cp" (no mount needed).
    docker exec "$name" mkdir -p /tmp/impact-test
    docker cp "$HERE/lib/rstudio_client.py" "$name:/tmp/impact-test/rstudio_client.py" > /dev/null

    # --- Password ---------------------------------------------------------------------
    # Rocker printed a random password into the log, because no PASSWORD was given.
    local start_password new_password
    start_password="$(logs session | sed -n 's/^The password is set to \(.*\)$/\1/p' | head -n 1)"
    if [[ -n "$start_password" ]]; then
        ok "without PASSWORD, the Rocker start-up sets a random password (found in the log)"
    else
        bad "without PASSWORD, the Rocker start-up sets a random password (found in the log)" "no line 'The password is set to ...' in the log"
    fi
    expect_equal "RStudio's sign-in accepts the start password before the change" "ACCEPTED" "$(signin session "$start_password")"

    # The GUI's step: chpasswd reads "user:password" from standard input. $RANDOM is a
    # random number of bash; four of them make the password different in every run.
    new_password="Pw-$RANDOM-$RANDOM-$RANDOM-$RANDOM-ok"
    if printf 'rstudio:%s\n' "$new_password" | docker exec -i "$name" chpasswd 2> "$WORK/chpasswd.log"; then
        ok "the password can be set with 'chpasswd' through standard input"
    else
        bad "the password can be set with 'chpasswd' through standard input" "$(cat "$WORK/chpasswd.log")"
    fi
    expect_equal "RStudio's sign-in accepts the new password" "ACCEPTED" "$(signin session "$new_password")"
    expect_equal "RStudio's sign-in refuses a wrong password" "REFUSED" "$(signin session "wrong-$new_password")"
    expect_equal "RStudio's sign-in refuses the start password after the change" "REFUSED" "$(signin session "$start_password")"
    expect_equal "RStudio's sign-in refuses an empty password" "REFUSED" "$(signin session "")"
    expect_lacks "the new password is not in 'docker inspect'" "$(docker inspect "$name")" "$new_password"
    expect_lacks "the new password is not in the container log" "$(docker logs "$name" 2>&1)" "$new_password"
    expect_lacks "the new password is not in the environment the R sessions get (Renviron.site)" \
        "$(in_container session cat /usr/local/lib/R/etc/Renviron.site)" "$new_password"

    # --- R session through RStudio Server -------------------------------------------------
    local out
    out="$(run_in_session session "$new_password" "
        # R code that the RStudio session of rstudio runs.
        dir.create('/tmp/impact-test/session', showWarnings = FALSE)
        writeLines('made by the R session', '$REPO_IN_CONTAINER/mixed/writable/from-session.txt')
        dir.create('$REPO_IN_CONTAINER/mixed/writable/dir-from-session')
        writeLines('made by the R session', '$REPO_IN_CONTAINER/outputs/writable/from-session.txt')
        writeLines('made by the R session', '$STORAGE_IN_CONTAINER/outputs/from-session.txt')
        writeLines('made by the R session', path.expand('~/from-session.txt'))
        project <- tryCatch(.rs.getProjectDirectory(), error = function(e) NA)
        info <- c(uid = system('id -u', intern = TRUE), gid = system('id -g', intern = TRUE),
                  groups = system('id -Gn', intern = TRUE), wd = getwd(),
                  project = if (is.null(project)) NA else project,
                  library = .libPaths()[1],
                  impact_uid = Sys.getenv('IMPACT_UID'), git_ssh = Sys.getenv('GIT_SSH_COMMAND'))
        writeLines(paste0(names(info), '=', info), '/tmp/impact-test/session/info.txt')
    ")"
    if [[ "$out" == *"SESSION-RAN-FILE"* ]]; then
        ok "an R session starts through RStudio Server for rstudio and runs code"
    else
        bad "an R session starts through RStudio Server for rstudio and runs code" "$out"
    fi
    local info
    info="$(in_container session cat /tmp/impact-test/session/info.txt 2>&1)"
    expect_contains "the R session runs with the user number $PERSON_UID" "$info" "uid=$PERSON_UID"
    expect_contains "the R session runs with the group number $SHARED_GID" "$info" "gid=$SHARED_GID"
    expect_contains "the R session is a member of the group 'staff'" "$(grep '^groups=' <<< "$info") " " staff "
    expect_contains "RStudio opened the project of the repository" "$info" "project=$REPO_IN_CONTAINER"
    expect_contains "the R session sees the GUI's GIT_SSH_COMMAND" "$info" "git_ssh=$GUI_SSH_COMMAND"
    local path
    for path in "$REPO_IN_CONTAINER/mixed/writable/from-session.txt" "$REPO_IN_CONTAINER/mixed/writable/dir-from-session" \
                "$REPO_IN_CONTAINER/outputs/writable/from-session.txt" "$STORAGE_IN_CONTAINER/outputs/from-session.txt" \
                "/home/rstudio/from-session.txt"; do
        expect_equal "created by the R session, belongs to $PERSON_UID:$SHARED_GID: $path" "$PERSON_UID:$SHARED_GID" "$(owner_of session "$path")"
    done
    # RStudio itself creates the folder .Rproj.user in the project when it opens it.
    expect_equal "created by RStudio itself, belongs to $PERSON_UID:$SHARED_GID: .Rproj.user in the repository" "$PERSON_UID:$SHARED_GID" \
        "$(owner_of session "$REPO_IN_CONTAINER/.Rproj.user")"

    # --- The R library: install the model's package again from the session ------------------
    # The model recompiles its R package when it is loaded and its source has changed.
    # Here: change the number in the C source, install from the source folder inside the
    # session, and ask a fresh R process for the number.
    expect_equal "the stand-in package from the image build answers 1" "1" \
        "$(as_rstudio session Rscript -e 'cat(impactstandin::standin_answer())' 2>&1)"
    out="$(run_in_session session "$new_password" "
        pkg <- '$REPO_IN_CONTAINER/Rpackage/IMPACTncd_Ger_model_pkg'
        src <- file.path(pkg, 'src', 'standin.c')
        txt <- readLines(src)
        writeLines(sub('^#define STANDIN_ANSWER .*', '#define STANDIN_ANSWER 42', txt), src)
        result <- tryCatch({
            install.packages(pkg, repos = NULL, type = 'source', quiet = TRUE)
            'installed'
        }, warning = function(w) paste('warning:', conditionMessage(w)),
           error = function(e) paste('error:', conditionMessage(e)))
        writeLines(result, '/tmp/impact-test/session/install.txt')
    ")"
    expect_contains "the session ran the installation" "$out" "SESSION-RAN-FILE"
    expect_equal "install.packages() from the session reports no warning and no error" "installed" \
        "$(in_container session cat /tmp/impact-test/session/install.txt 2>&1)"
    expect_equal "after the installation from the session, the package answers 42" "42" \
        "$(as_rstudio session Rscript -e 'cat(impactstandin::standin_answer())' 2>&1)"
    expect_equal "the installed package files belong to the user $PERSON_UID" "$PERSON_UID" \
        "$(in_container session stat -c '%u' /usr/local/lib/R/site-library/impactstandin/libs/impactstandin.so 2>&1)"
    # The same with the command line tool, a second time (the files now belong to rstudio).
    as_rstudio session /bin/bash -c "sed -i 's/^#define STANDIN_ANSWER .*/#define STANDIN_ANSWER 43/' '$REPO_IN_CONTAINER/Rpackage/IMPACTncd_Ger_model_pkg/src/standin.c' && R CMD INSTALL '$REPO_IN_CONTAINER/Rpackage/IMPACTncd_Ger_model_pkg'" > "$WORK/rcmd.log" 2>&1
    expect_equal "'R CMD INSTALL' as rstudio works as well: the package answers 43" "43" \
        "$(as_rstudio session Rscript -e 'cat(impactstandin::standin_answer())' 2>&1)"

    finish_case session session
}

# ---------------------------------------------------------------------------
# Group "git": known hosts without network, and git against a stand-in SSH server
# ---------------------------------------------------------------------------
group_git() {
    make_fixture git "$PERSON_UID" "$SHARED_GID"
    set_mounts git
    remote_env "$PERSON_UID" "$SHARED_GID"
    local expected_keys expected_prints
    expected_keys="$(cat "$HERE/expected/github_known_hosts")"
    expected_prints="$(LC_ALL=C sort "$HERE/expected/github_fingerprints")"

    # --- A start without any network ---------------------------------------------------
    # "--network none" gives the container no network at all, so nothing can be fetched.
    local started=$SECONDS
    start nonet "$IMG" "${ENV_OPTS[@]}" --network none --workdir "$REPO_IN_CONTAINER" "${GUI_MOUNTS[@]}"
    if wait_ready nonet 90; then
        ok "no network: the container reaches the ready marker (after $((SECONDS - started)) s)"
        expect_equal "no network: /etc/ssh/ssh_known_hosts holds exactly GitHub's three published keys" "$expected_keys" \
            "$(in_container nonet cat /etc/ssh/ssh_known_hosts 2>&1)"
        expect_equal "no network: /home/rstudio/.ssh/known_hosts holds exactly GitHub's three published keys" "$expected_keys" \
            "$(in_container nonet cat /home/rstudio/.ssh/known_hosts 2>&1)"
        # ssh-keygen -l prints the fingerprint of every key in a file; awk takes the
        # fingerprint and the key type from each line.
        expect_equal "no network: the fingerprints of the stored keys are the ones GitHub publishes" "$expected_prints" \
            "$(in_container nonet ssh-keygen -l -f /home/rstudio/.ssh/known_hosts 2>&1 | awk '{print $2 " " $NF}' | LC_ALL=C sort)"
        expect_equal "no network: SSH finds all three key types for github.com in the user's file" "3" \
            "$(as_rstudio nonet ssh-keygen -F github.com -f /home/rstudio/.ssh/known_hosts 2>/dev/null | grep -c '^github.com ')"
        expect_equal "no network: known_hosts belongs to rstudio and is readable (mode 644)" "$PERSON_UID:$SHARED_GID 644" \
            "$(in_container nonet stat -c '%u:%g %a' /home/rstudio/.ssh/known_hosts 2>&1)"
        expect_equal "no network: the key copy belongs to rstudio and is private (mode 600)" "$PERSON_UID:$SHARED_GID 600" \
            "$(in_container nonet stat -c '%u:%g %a' /home/rstudio/.ssh/id_ed25519_testuser 2>&1)"
        expect_equal "no network: .ssh belongs to rstudio and is private (mode 700)" "$PERSON_UID:$SHARED_GID 700" \
            "$(in_container nonet stat -c '%u:%g %a' /home/rstudio/.ssh 2>&1)"
        # The key copy is usable: ssh-keygen -y derives the public key from a private key.
        expect_equal "no network: the key copy is a valid private key" "$(cut -d' ' -f1-2 "$WORK/git/keys/id_ed25519_testuser.pub" 2>/dev/null || helper "cut -d' ' -f1-2 /work/git/keys/id_ed25519_testuser.pub")" \
            "$(as_rstudio nonet ssh-keygen -y -f /home/rstudio/.ssh/id_ed25519_testuser 2>&1 | cut -d' ' -f1-2)"
        expect_equal "no network: git uses the same SSH command as the GUI (core.sshCommand)" "$GUI_SSH_COMMAND" \
            "$(as_rstudio nonet git config --global core.sshCommand 2>&1)"
        expect_equal "no network: the git user name comes from the key file name" "testuser testuser@users.noreply.github.com" \
            "$(as_rstudio nonet git config --global user.name 2>&1) $(as_rstudio nonet git config --global user.email 2>&1)"
        expect_contains "no network: git-identity ended with exit code 0" "$(logs nonet)" "[cont-init.d] git-identity: exited 0."

        # The GUI's own set-up (Get-ContainerSshSetupCommand and the git settings of the
        # Start button), run after the script as in REMOTE. Without network its key scan
        # finds nothing, and it removes the github.com lines from the user's file.
        in_container nonet sh -c "mkdir -p /home/rstudio/.ssh && chmod 700 /home/rstudio/.ssh && tr -d '\r' < /keys/id_ed25519_testuser > /home/rstudio/.ssh/id_ed25519_testuser && chmod 600 /home/rstudio/.ssh/id_ed25519_testuser && touch /home/rstudio/.ssh/known_hosts && { grep -v '^github.com ' /home/rstudio/.ssh/known_hosts 2>/dev/null; ssh-keyscan -T 3 -t ed25519,ecdsa,rsa github.com 2>/dev/null || true; } > /home/rstudio/.ssh/known_hosts.tmp && mv /home/rstudio/.ssh/known_hosts.tmp /home/rstudio/.ssh/known_hosts && chmod 644 /home/rstudio/.ssh/known_hosts && chown -R $PERSON_UID:$SHARED_GID /home/rstudio/.ssh && echo KEY_FIXED" > "$WORK/gui-setup.log" 2>&1
        as_rstudio nonet sh -c "git config --global user.name 'testuser' && git config --global user.email 'testuser@users.noreply.github.com' && git config --global core.sshCommand '$GUI_SSH_COMMAND' && echo GIT_CONFIGURED" >> "$WORK/gui-setup.log" 2>&1
        expect_contains "no network: the GUI's own key and git set-up runs after the script" "$(cat "$WORK/gui-setup.log")" "GIT_CONFIGURED"
        expect_equal "no network: after the GUI's set-up, core.sshCommand is unchanged" "$GUI_SSH_COMMAND" \
            "$(as_rstudio nonet git config --global core.sshCommand 2>&1)"
        # "ssh -G host" prints the settings SSH would use, without connecting. The
        # system-wide file must still be consulted, and it still knows GitHub.
        expect_contains "no network: after the GUI's set-up, SSH still reads the system-wide known hosts file" \
            "$(as_rstudio nonet ssh -G -i /home/rstudio/.ssh/id_ed25519_testuser -o IdentitiesOnly=yes -o UserKnownHostsFile=/home/rstudio/.ssh/known_hosts -o StrictHostKeyChecking=accept-new github.com 2>&1 | grep -i '^globalknownhostsfile')" "/etc/ssh/ssh_known_hosts"
        # The script run again after the GUI (the other order): same settings, keys back.
        in_container nonet /etc/cont-init.d/git-identity > "$WORK/second-run.log" 2>&1
        expect_equal "no network: the script run again after the GUI leaves core.sshCommand as it is" "$GUI_SSH_COMMAND" \
            "$(as_rstudio nonet git config --global core.sshCommand 2>&1)"
        expect_equal "no network: the script run again restores the three keys in the user's file" "$expected_keys" \
            "$(in_container nonet cat /home/rstudio/.ssh/known_hosts 2>&1)"
    else
        bad "no network: the container reaches the ready marker" "$(logs nonet | tail -n 20)"
    fi
    docker rm -f "$(cname nonet)" > /dev/null 2>&1

    # --- A stand-in SSH server -------------------------------------------------------------
    # One container plays an SSH server with a git repository. On a private Docker
    # network it answers to two names:
    #   github.com        its host key is NOT GitHub's key, so every connection to this
    #                     name must be refused by the client;
    #   git.example.test  an unknown server, which "accept-new" lets git reach.
    docker network rm "$NETWORK" > /dev/null 2>&1
    docker network create --label "impact.test=$PREFIX" "$NETWORK" > /dev/null
    docker rm -f "$(cname gitserver)" > /dev/null 2>&1
    docker run -d --name "$(cname gitserver)" --label "impact.test=$PREFIX" \
        --network "$NETWORK" --network-alias github.com --network-alias git.example.test \
        --entrypoint /bin/bash -v "$WORK/git/keys/id_ed25519_testuser.pub:/authorized-key.pub:ro" "$IMG_PREREQ" -c '
            # Runs inside the stand-in server container, as root.
            set -e
            useradd --create-home --shell /bin/bash git
            usermod -p "*" git                       # no password; key sign-in stays possible
            install -d -o git -g git -m 700 /home/git/.ssh
            install -o git -g git -m 600 /authorized-key.pub /home/git/.ssh/authorized_keys
            runuser -u git -- git init --quiet --bare --initial-branch=main /home/git/standin/repo.git
            runuser -u git -- git init --quiet /home/git/work
            runuser -u git -- git -C /home/git/work -c user.name=standin -c user.email=standin@example.test commit --quiet --allow-empty -m "first commit"
            runuser -u git -- git -C /home/git/work push --quiet /home/git/standin/repo.git HEAD:refs/heads/main
            mkdir -p /run/sshd
            ssh-keygen -A > /dev/null                 # host keys of this server, made now
            echo SERVER-READY
            exec /usr/sbin/sshd -D -e
        ' > /dev/null
    local tries=0
    while (( tries < 60 )) && ! docker logs "$(cname gitserver)" 2>&1 | grep -q 'Server listening'; do
        sleep 0.5
        tries=$((tries + 1))
    done

    # The container under test, on the same network, without the --add-host line: the
    # name github.com now leads to the stand-in server.
    start git "$IMG" "${ENV_OPTS[@]}" --network "$NETWORK" --workdir "$REPO_IN_CONTAINER" "${GUI_MOUNTS[@]}"
    if wait_ready git 90; then
        ok "stand-in server: the container reaches the ready marker"
        local out code
        expect_contains "stand-in server: git-identity did not accept the false github.com (name taken from the key file)" \
            "$(logs git)" "user name taken from the key file name: testuser"

        # git as the GUI's "docker exec" runs it: GIT_SSH_COMMAND from the container's
        # variables is in force.
        out="$(as_rstudio git git ls-remote git@github.com:standin/repo.git 2>&1)"
        code=$?
        if [[ "$code" != 0 && "$out" == *"Host key verification failed"* ]]; then
            ok "stand-in server: git refuses a server that calls itself github.com with another host key (GIT_SSH_COMMAND)"
        else
            bad "stand-in server: git refuses a server that calls itself github.com with another host key (GIT_SSH_COMMAND)" "exit code $code" "$out"
        fi
        # git with core.sshCommand alone, the setting the script wrote. "env -u NAME"
        # runs a command without the variable NAME.
        out="$(as_rstudio git env -u GIT_SSH_COMMAND git ls-remote git@github.com:standin/repo.git 2>&1)"
        code=$?
        if [[ "$code" != 0 && "$out" == *"Host key verification failed"* ]]; then
            ok "stand-in server: the same refusal with core.sshCommand alone"
        else
            bad "stand-in server: the same refusal with core.sshCommand alone" "exit code $code" "$out"
        fi
        # Plain ssh without any option of ours: the system-wide file protects it as well.
        out="$(as_rstudio git ssh -o BatchMode=yes -i /home/rstudio/.ssh/id_ed25519_testuser git@github.com true 2>&1)"
        code=$?
        if [[ "$code" != 0 && "$out" == *"Host key verification failed"* ]]; then
            ok "stand-in server: plain ssh refuses the false github.com as well (system-wide known hosts file)"
        else
            bad "stand-in server: plain ssh refuses the false github.com as well (system-wide known hosts file)" "exit code $code" "$out"
        fi
        expect_equal "stand-in server: the refused connections added no key for github.com" "$(cat "$HERE/expected/github_known_hosts")" \
            "$(in_container git grep '^github.com ' /home/rstudio/.ssh/known_hosts 2>&1)"

        # The same server under a name SSH has never seen: git must get through. This
        # shows that git is not blocked by a strict check against a file that has no
        # entry for the server.
        out="$(as_rstudio git git ls-remote git@git.example.test:standin/repo.git 2>&1)"
        code=$?
        if [[ "$code" == 0 && "$out" == *"refs/heads/main"* ]]; then
            ok "stand-in server: git reaches a server with a new name and reads its branches (accept-new, key sign-in works)"
        else
            bad "stand-in server: git reaches a server with a new name and reads its branches (accept-new, key sign-in works)" "exit code $code" "$out"
        fi
        out="$(as_rstudio git env -u GIT_SSH_COMMAND git ls-remote git@git.example.test:standin/repo.git 2>&1)"
        code=$?
        if [[ "$code" == 0 && "$out" == *"refs/heads/main"* ]]; then
            ok "stand-in server: the same with core.sshCommand alone"
        else
            bad "stand-in server: the same with core.sshCommand alone" "exit code $code" "$out"
        fi
        expect_equal "stand-in server: the new server was remembered in the user's known hosts file" "found" \
            "$(as_rstudio git ssh-keygen -F git.example.test -f /home/rstudio/.ssh/known_hosts > /dev/null 2>&1 && echo found || echo missing)"
        # A clone and a push, as a person would do them from the RStudio terminal.
        out="$(as_rstudio git /bin/bash -c 'cd /tmp && rm -rf clone && git clone --quiet git@git.example.test:standin/repo.git clone && cd clone && git commit --quiet --allow-empty -m "from the test" && git push --quiet origin HEAD:main && git log --format=%an -1' 2>&1)"
        expect_equal "stand-in server: clone, commit and push work; the commit carries the git user name" "testuser" "$out"
    else
        bad "stand-in server: the container reaches the ready marker" "$(logs git | tail -n 20)"
    fi
    docker rm -f "$(cname gitserver)" > /dev/null 2>&1
    finish_case git git
    docker network rm "$NETWORK" > /dev/null 2>&1

    # --- The real GitHub, when it can be reached ---------------------------------------------
    # With internet access the stored keys can be checked against the real server: a
    # strict connection must get as far as GitHub's answer to the unknown test key,
    # "Permission denied (publickey)". Without internet this test is skipped.
    make_fixture online "$PERSON_UID" "$SHARED_GID"
    set_mounts online
    start online "$IMG" "${ENV_OPTS[@]}" --workdir "$REPO_IN_CONTAINER" "${GUI_MOUNTS[@]}"
    if wait_ready online 120; then
        local out
        out="$(as_rstudio online timeout 30 ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -i /home/rstudio/.ssh/id_ed25519_testuser git@github.com 2>&1)"
        if [[ "$out" == *"Permission denied (publickey)"* ]]; then
            ok "real GitHub: a strict SSH connection accepts GitHub's host key (the server then refuses the unknown test key, as expected)"
        elif [[ "$out" == *"Host key verification failed"* ]]; then
            bad "real GitHub: a strict SSH connection accepts GitHub's host key" "GitHub's host key differs from the stored keys:" "$out"
        else
            skip "real GitHub: a strict SSH connection accepts GitHub's host key" "github.com cannot be reached from here: $(head -n 1 <<< "$out")"
        fi
    else
        bad "real GitHub: the container reaches the ready marker" "$(logs online | tail -n 20)"
    fi
    finish_case online online
}

# ---------------------------------------------------------------------------
# Group "local": a LOCAL start compared with the stored expectation
# ---------------------------------------------------------------------------
group_local() {
    make_fixture localref 1000 1000
    set_mounts localref
    local_env
    start localref "$IMG" "${ENV_OPTS[@]}" "${COMMON_OPTS[@]}" "${GUI_MOUNTS[@]}"
    if ! wait_ready localref 90 || ! wait_rstudio localref 60 > /dev/null; then
        bad "LOCAL: the container starts and RStudio answers" "$(logs localref | tail -n 20)"
        finish_case localref localref
        return
    fi
    ok "LOCAL: the container starts and RStudio answers"

    # The account files are the ones of the image: the identity step did nothing.
    expect_equal "LOCAL: /etc/passwd and /etc/group are identical to the image's" \
        "$(docker run --rm --entrypoint /bin/bash "$IMG" -c 'cat /etc/passwd /etc/group | sha256sum')" \
        "$(in_container localref /bin/bash -c 'cat /etc/passwd /etc/group | sha256sum')"
    expect_contains "LOCAL: the log says that the numbers are left alone" "$(logs localref)" "IMPACT_UID and IMPACT_GID are not set"

    # Owner, group and access mode of everything the image and its start-up put into the
    # home folder, compared with expected/local-start.txt. The repository mount is left
    # out. Lines of that file that start with "#" are comments.
    local actual expected
    actual="$(in_container localref find -P /home/rstudio -xdev -not -path "$REPO_IN_CONTAINER" -not -path "$REPO_IN_CONTAINER/*" -printf '%p|%y|%U:%G|%m\n' | LC_ALL=C sort)"
    expected="$(grep -v '^#' "$HERE/expected/local-start.txt" | grep -v '^$' | LC_ALL=C sort)"
    if [[ "$actual" == "$expected" ]]; then
        ok "LOCAL: the entries in the home folder have the expected owner, group and mode ($(wc -l <<< "$expected") entries)"
    else
        bad "LOCAL: the entries in the home folder have the expected owner, group and mode" \
            "difference ('<' expected, '>' found):" "$(diff <(echo "$expected") <(echo "$actual") | grep '^[<>]')"
    fi

    # The content of the four settings files, as the start-up script has always written them.
    local file
    for file in ".rstudio/monitored/user-settings/user-settings" ".config/rstudio/rstudio-prefs.json" \
                ".rstudio/projects_settings/last-project-path" ".rstudio/projects_settings/project-settings"; do
        expect_equal "LOCAL: content of ~/$file" "$(cat "$HERE/expected/local-settings/${file##*/}")" "$(in_container localref cat "/home/rstudio/$file" 2>&1)"
    done

    # Sign-in with the password the GUI passed as PASSWORD.
    docker exec "$(cname localref)" mkdir -p /tmp/impact-test
    docker cp "$HERE/lib/rstudio_client.py" "$(cname localref):/tmp/impact-test/rstudio_client.py" > /dev/null
    expect_equal "LOCAL: RStudio's sign-in accepts the password given as PASSWORD" "ACCEPTED" "$(signin localref "$LOCAL_PASSWORD")"
    expect_equal "LOCAL: RStudio's sign-in refuses a wrong password" "REFUSED" "$(signin localref "not-$LOCAL_PASSWORD")"
    expect_equal "LOCAL: the working folder of the container is the repository" "$REPO_IN_CONTAINER" "$(in_container localref pwd)"
    finish_case localref localref
}

# ---------------------------------------------------------------------------
# The list of groups: name, function, what it covers
# ---------------------------------------------------------------------------
GROUPS_LIST=(
    "static|group_static|checks of the script text (forbidden commands, GitHub's keys)"
    "valid|group_valid|six valid starts, each with the full fixture comparison"
    "rocker-env|group_rocker_env|what the Rocker start-up sees of USERID and GROUPID"
    "invalid|group_invalid|invalid values must end the container"
    "restart|group_restart|stop and start of the same container; order of the ready marker"
    "readonly|group_readonly|all folders mounted read-only"
    "settings-mount|group_settings_mount|RStudio's settings folders are mounts themselves"
    "symlink|group_symlink|symbolic links in the home folder that point into a mount"
    "session|group_session|password, RStudio sign-in, R session, R library"
    "git|group_git|known hosts without network; git against a stand-in SSH server"
    "local|group_local|a LOCAL start compared with the stored expectation"
)

if [[ "$LIST" == 1 ]]; then
    echo "build            builds the test images (always runs first)"
    for entry in "${GROUPS_LIST[@]}"; do
        # IFS='|' splits the entry at the bars into three variables.
        IFS='|' read -r group_name _ group_text <<< "$entry"
        printf '%-16s %s\n' "$group_name" "$group_text"
    done
    exit 0
fi

# ---------------------------------------------------------------------------
# Start: checks, work folder, clean-up
# ---------------------------------------------------------------------------
if ! docker version > /dev/null 2>&1; then
    echo "run-tests.sh: Docker does not answer ('docker version' failed). Is Docker installed and running, and may this user use it?" >&2
    exit 2
fi
for needed in Dockerfile.IMPACTncdGER Dockerfile.prerequisite.IMPACTncdGER entrypoint.sh git-identity.sh impact-ready.sh; do
    if [[ ! -f "$SETUP_DIR/$needed" ]]; then
        echo "run-tests.sh: $SETUP_DIR/$needed is missing." >&2
        exit 2
    fi
done

# mktemp -d creates a new, empty folder with a name nobody else uses.
WORK="$(mktemp -d "${IMPACT_TEST_TMP:-${TMPDIR:-/tmp}}/impact-setup-test.XXXXXX")" || exit 2
# Docker's helper containers run as root and must be able to enter the folder.
chmod 755 "$WORK"

# cleanup runs when the script ends, also after Ctrl+C ("trap ... EXIT").
cleanup() {
    if [[ "$KEEP" == 1 && "$FAILED" -gt 0 ]]; then
        echo
        echo "--keep: containers and files of the failed tests were kept."
        echo "  containers:  docker ps -a --filter label=impact.test=$PREFIX"
        echo "  work folder: $WORK"
        return
    fi
    # Remove every container and network with our label. "xargs -r" runs the command
    # only when there is something to remove.
    docker ps -aq --filter "label=impact.test=$PREFIX" | xargs -r docker rm -f > /dev/null 2>&1
    docker network ls -q --filter "label=impact.test=$PREFIX" | xargs -r docker network rm > /dev/null 2>&1
    # The work folder holds files of other user numbers; a helper container removes them.
    if docker image inspect "$IMG_PREREQ" > /dev/null 2>&1; then
        docker run --rm --network none --entrypoint /bin/bash -v "$WORK:/work" "$IMG_PREREQ" \
            -c 'find /work -mindepth 1 -delete' > /dev/null 2>&1
    fi
    rm -rf "$WORK" 2>/dev/null
}
trap cleanup EXIT

echo "docker_setup tests"
echo "  folder under test: $SETUP_DIR"
echo "  work folder:       $WORK"
echo

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
GROUP="build"
group_build
build_result=$?
if [[ "$build_result" == 2 ]]; then
    echo
    echo "The test images could not be built, so no further test can run."
    exit 2
fi

for entry in "${GROUPS_LIST[@]}"; do
    IFS='|' read -r group_name group_function _ <<< "$entry"
    # "=~" compares with a pattern; an empty ONLY runs every group.
    if [[ -n "$ONLY" && ! "$group_name" =~ $ONLY ]]; then
        continue
    fi
    GROUP="$group_name"
    echo
    "$group_function"
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "Summary: $((PASSED + FAILED + SKIPPED)) tests, $PASSED passed, $FAILED failed, $SKIPPED skipped"
if [[ "$FAILED" -gt 0 ]]; then
    echo "Failed tests:"
    for name in "${FAILED_NAMES[@]}"; do
        echo "  $name"
    done
    exit 1
fi
exit 0
