#!/bin/bash
# =============================================================================
# check-20-docker.test.sh: impact-check with a real Docker daemon
#
# Purpose
#   Proves with a real Docker daemon that the Docker blocks of impact-check
#   read what Docker really prints: image sizes per account (block 2),
#   containers and ports per person (11), ports held by containers (12),
#   containers that publish to the network, with KNOWN_DIRECT_CONTAINERS
#   named as accepted (13), volumes named like IMPACT volumes (14) and
#   containers without IMPACT labels (15). It also proves that the check
#   changes nothing in Docker (containers, their states, volumes, images)
#   and nothing in the watched folders.
#   The tests are reported as skipped when no Docker daemon answers, or when
#   the daemon has no image to start a container from (the tests never
#   download an image).
#
# Who runs it
#   tests/workstation/run-tests.sh system   (root, disposable system only,
#   with a running Docker daemon and a private network)
#
# Usage
#   sudo env IMPACT_TEST_DISPOSABLE=yes IMPACT_TEST_BACKING_DIR=<folder on ext4> \
#       bash tests/workstation/run-tests.sh system --filter check-20
#
# What it changes on the system
#   The installed commands and their settings, one test account, seven
#   containers, four volumes and one small image named for these tests
#   (removed again), and the storage roots below /mnt/disk_a and /mnt/disk_b.
#
# How to undo
#   The file removes everything it created (suite_teardown).
#
# The tests of this file build on each other and run in the order written.
# =============================================================================

# Reading help: the bash constructs used here are explained at the top of
# ../lib/testlib.sh ("Reading help") and where they are first used.

# The lines for the checking tool "shellcheck" stand before the first command
# of the file and therefore count for the whole file.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/testlib.sh"

CHECK=/usr/local/bin/impact-check
ALICE='alice-example'
CONTAINERS=(Example-Model_alice-example Example-Model_alice-wide data_preparation_1 impact-test-plain
    impact-test-old impact-test-hostile impact-test-gone)
VOLUMES=(impactncd_output_Example-Model_alice-example impactncd_germany_synthpop_bob-example
    results_output_2024 impact-test-plainvolume)
LABELLED_IMAGE='impact-test-model:alice-example'
WATCHED=(/etc/impact /opt/impact /srv /usr/local/bin /usr/local/sbin /home /mnt/disk_a /mnt/disk_b)
EXCLUDES=(--exclude /home/user --exclude /home/ubuntu)

suite_setup() {
    local image
    # A stand-in docker of another test file must not be mistaken for the
    # real one.
    if [[ -f /usr/local/sbin/docker ]] || ! timeout 20 docker version >/dev/null 2>&1; then
        skip 'no Docker daemon answers on this machine'
    fi
    image="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>' | head -n 1)" || image=''
    if [[ -z "$image" ]]; then
        skip 'the Docker daemon has no image to start a test container from'
    fi
    remove_docker_objects
    sys_clean_slate
    sys_storage_up
    sys_install
    sys_admin_create
    sys_setup --min-free-gb 1 --known-direct-containers 'data_preparation_*,other_tool'
    sys_account_add "$ALICE" impact docker
    load_library
    impact_account_record_write "$ALICE" "$ALICE" enrolled || fail "record of $ALICE"

    # Containers as the GUI 2.1 starts them (label impact.account, port on
    # 127.0.0.1), one of them published on all addresses; a permanent
    # container outside the GUI that is accepted; one that is not; one of
    # GUI 2.0 (its labels, never started); one with a label value that is
    # no account name; one of an account that does not exist.
    docker run -d --name Example-Model_alice-example --label "impact.account=$ALICE" --label impact.access=tunnel \
        -p 127.0.0.1:8790:8787 "$image" sleep 100000 >/dev/null
    docker run -d --name Example-Model_alice-wide --label "impact.account=$ALICE" -p 8791:8787 "$image" sleep 100000 >/dev/null
    docker run -d --name data_preparation_1 -p 8792:8787 "$image" sleep 100000 >/dev/null
    docker run -d --name impact-test-plain -p 8793:8787 "$image" sleep 100000 >/dev/null
    docker volume create impactncd_output_Example-Model_alice-example >/dev/null
    docker volume create impactncd_germany_synthpop_bob-example >/dev/null
    docker volume create results_output_2024 >/dev/null
    docker volume create impact-test-plainvolume >/dev/null
    docker create --name impact-test-old --label impact.use_volumes=true --label impact.repo_path=/home/shared/Example \
        -v impactncd_output_Example-Model_alice-example:/data -p 8794:8787 "$image" sleep 1 >/dev/null
    docker create --name impact-test-hostile --label $'impact.account=bad\nname; $(touch /tmp/impact-check-pwned)' "$image" sleep 1 >/dev/null
    docker create --name impact-test-gone --label impact.account=gone-account -p 127.0.0.1:8899:8787 "$image" sleep 1 >/dev/null
    # A tiny image with the label of a person: an empty file system.
    tar -cf "$TEST_SUITE_TMP/empty.tar" --files-from /dev/null
    docker import --change "LABEL impact.account=$ALICE" "$TEST_SUITE_TMP/empty.tar" "$LABELLED_IMAGE" >/dev/null
}

suite_teardown() {
    remove_docker_objects
    sys_clean_slate
}

# remove_docker_objects
#   Removes the containers, volumes and the image of these tests.
remove_docker_objects() {
    local name
    for name in "${CONTAINERS[@]}"; do
        docker rm -f "$name" >/dev/null 2>&1 || true
    done
    for name in "${VOLUMES[@]}"; do
        docker volume rm "$name" >/dev/null 2>&1 || true
    done
    docker image rm "$LABELLED_IMAGE" >/dev/null 2>&1 || true
}

# docker_state
#   Prints what the check must not change in Docker: every container with
#   its state and start time, every volume, every image.
docker_state() {
    docker ps --all --no-trunc --format '{{.ID}} {{.Names}} {{.State}} {{.Image}}' | LC_ALL=C sort
    docker ps --all --quiet --no-trunc | xargs -r docker inspect --format '{{.Name}} {{.State.StartedAt}} {{.RestartCount}}' | LC_ALL=C sort
    docker volume ls --format '{{.Name}}' | LC_ALL=C sort
    docker images --all --no-trunc --format '{{.ID}} {{.Repository}}:{{.Tag}}' | LC_ALL=C sort
}

# block_of NUMBER
#   Prints the lines of block NUMBER of the last report.
block_of() {
    printf '%s\n' "$RUN_OUTPUT" | awk -v n="$1" '
        index($0, "Block " n ": ") == 1 { inside = 1 }
        inside { print }
        inside && index($0, "  Result of block " n ": ") == 1 { exit }'
}

# assert_block_contains NUMBER PART
assert_block_contains() {
    local text
    text="$(block_of "$1")"
    if [[ "$text" != *"$2"* ]]; then
        printf '%s\n' "$text" >&2
        fail "block $1 should contain: $2"
    fi
}

# assert_block_not_contains NUMBER PART
assert_block_not_contains() {
    local text
    text="$(block_of "$1")"
    if [[ "$text" == *"$2"* ]]; then
        printf '%s\n' "$text" >&2
        fail "block $1 should not contain: $2"
    fi
}

# assert_block NUMBER WORD
assert_block() {
    assert_block_contains "$1" "  Result of block $1: $2"
}

# The docker blocks read the real daemon.
test_the_docker_blocks_read_the_real_daemon() {
    docker_state >"$TEST_TMP/docker-before"
    snapshot_unchanged_by --content "${EXCLUDES[@]}" "${WATCHED[@]}" -- sys_as_admin "$CHECK"
    docker_state >"$TEST_TMP/docker-after"
    snapshot_assert_same "$TEST_TMP/docker-before" "$TEST_TMP/docker-after" "the check changed something in Docker"
    assert_missing /tmp/impact-check-pwned
    # Every block has its one result line.
    assert_eq 15 "$(printf '%s\n' "$RUN_OUTPUT" | grep -c -E '^  Result of block [0-9]+: (OK|WARN|FAIL)$')"

    # Block 2: the daemon, the containerd image store, images per account.
    assert_block_contains 2 'OK: The Docker daemon answers (version '
    assert_block_contains 2 "Images of $ALICE: 1, "
    assert_block_not_contains 2 'gone-account'

    # Block 11: the containers of the GUI 2.1, by person.
    assert_block 11 WARN
    assert_block_contains 11 "Containers of $ALICE:"
    assert_block_contains 11 'Example-Model_alice-example: running, image '
    assert_block_contains 11 'ports 127.0.0.1:8790 -> 8787/tcp.'
    assert_block_contains 11 'Example-Model_alice-wide: running, image '
    assert_block_contains 11 'ports all addresses:8791 -> 8787/tcp'
    assert_block_contains 11 'The container impact-test-hostile has a label impact.account that is no account name.'
    assert_block_contains 11 "The container impact-test-gone belongs to 'gone-account', which is no account on this machine."
    assert_block_contains 11 'uses the port 8899 outside the range 8787 to 8830'
    # Containers without the label are not counted as somebody's.
    assert_block_not_contains 11 'data_preparation_1'
    assert_block_not_contains 11 'impact-test-plain'

    # Block 12: the four running containers hold four ports of the range.
    assert_block_contains 12 '40 of the 44 ports of the range 8787 to 8830 are free.'
    assert_block_not_contains 12 'outside Docker listens there'

    # Block 13: publishing to the network.
    assert_block 13 WARN
    assert_block_contains 13 'OK: data_preparation_1 (running) publishes to the network and is accepted (KNOWN_DIRECT_CONTAINERS): all addresses:8792 -> 8787/tcp.'
    assert_block_contains 13 "The GUI container Example-Model_alice-wide of $ALICE (running) publishes to the network: all addresses:8791 -> 8787/tcp."
    assert_block_contains 13 'impact-test-plain (running) publishes to the network and is not accepted in KNOWN_DIRECT_CONTAINERS: all addresses:8793 -> 8787/tcp.'
    assert_block_contains 13 'impact-test-old (created) publishes to the network and is not accepted'
    assert_block_not_contains 13 'Example-Model_alice-example (running)'

    # Block 14: the three volumes named like IMPACT volumes.
    assert_block 14 WARN
    assert_block_contains 14 'Volume impactncd_output_Example-Model_alice-example: used by impact-test-old.'
    assert_block_contains 14 'Volume impactncd_germany_synthpop_bob-example: used by no container.'
    assert_block_contains 14 'Volume results_output_2024: used by no container.'
    assert_block_not_contains 14 'impact-test-plainvolume'

    # Block 15: containers without IMPACT labels.
    assert_block 15 WARN
    assert_block_contains 15 'OK: data_preparation_1 (running, image '
    assert_block_contains 15 '): accepted (KNOWN_DIRECT_CONTAINERS).'
    assert_block_contains 15 'impact-test-old (created, image '
    assert_block_contains 15 'started by GUI 2.0 (labels impact.* without impact.account).'
    assert_block_contains 15 'impact-test-plain (running, image '
    assert_block_contains 15 '): no IMPACT label.'
    assert_block_not_contains 15 'Example-Model_alice'
    assert_block_not_contains 15 'impact-test-hostile'
}

# Second run and mask change nothing in docker.
test_second_run_and_mask_change_nothing_in_docker() {
    docker_state >"$TEST_TMP/docker-before"
    run_cmd sys_as_admin "$CHECK" --mask
    run_cmd sys_as_admin "$CHECK"
    docker_state >"$TEST_TMP/docker-after"
    snapshot_assert_same "$TEST_TMP/docker-before" "$TEST_TMP/docker-after" "the check changed something in Docker"
    assert_block_contains 13 'data_preparation_1 (running) publishes to the network and is accepted'
}
