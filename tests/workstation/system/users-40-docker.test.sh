#!/bin/bash
# =============================================================================
# users-40-docker.test.sh: impact-remove-user with a real Docker daemon
#
# Purpose
#   Proves with a real Docker daemon that impact-remove-user stops exactly
#   the running containers that carry the label impact.account=<account>:
#   a container of another person, a container without the label and a
#   container that was never started are left alone; a dry run stops
#   nothing; a second run changes nothing.
#   The tests are reported as skipped when no Docker daemon answers, or when
#   the daemon has no image to start a container from (the tests never
#   download an image).
#
# Who runs it
#   tests/workstation/run-tests.sh system   (root, disposable system only,
#   with a running Docker daemon)
#
# Usage
#   sudo env IMPACT_TEST_DISPOSABLE=yes bash tests/workstation/run-tests.sh system --filter users-40
#
# What it changes on the system
#   The installed commands and their settings, two test accounts, four
#   containers named impact-test-* (removed again), and the storage roots
#   below /mnt/disk_a and /mnt/disk_b.
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

REMOVE=/usr/local/bin/impact-remove-user
ACC='alice-example'
OTHER='olga-example'
# Written by suite_setup when the tests cannot run here, with the reason.
NO_DOCKER_NOTE='no-docker'

suite_setup() {
    local image
    # A stand-in docker of another test file must not be mistaken for the
    # real one.
    if [[ -f /usr/local/sbin/docker ]] || ! timeout 20 docker version >/dev/null 2>&1; then
        printf 'no Docker daemon answers on this machine\n' >"$TEST_SUITE_TMP/$NO_DOCKER_NOTE"
        return 0
    fi
    image="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>' | head -n 1)" || image=''
    if [[ -z "$image" ]]; then
        printf 'the Docker daemon has no image to start a test container from\n' >"$TEST_SUITE_TMP/$NO_DOCKER_NOTE"
        return 0
    fi
    printf '%s\n' "$image" >"$TEST_SUITE_TMP/image"
    remove_test_containers
    sys_clean_slate
    sys_storage_up
    sys_install
    sys_admin_create
    sys_setup
    local name
    for name in "$ACC" "$OTHER"; do
        sys_register_account "$name"
        sys_keypair "$name"
        run_cmd sys_as_admin /usr/local/bin/impact-add-user "$name" --key-file "$(sys_key_path "$name").pub" \
            --fingerprint "$(ssh-keygen -l -E sha256 -f "$(sys_key_path "$name").pub" | awk '{ print $2 }')"
        [[ "$RUN_STATUS" == '0' ]] || fail "impact-add-user $name failed: $RUN_OUTPUT"
    done
    # The containers: one per person with the label, as the GUI starts
    # them; one without any IMPACT label; one of the person that was
    # created and never started.
    docker run -d --name impact-test-alice --label "impact.account=$ACC" "$image" sleep 100000 >/dev/null
    docker run -d --name impact-test-olga --label "impact.account=$OTHER" "$image" sleep 100000 >/dev/null
    docker run -d --name impact-test-nolabel "$image" sleep 100000 >/dev/null
    docker create --name impact-test-created --label "impact.account=$ACC" "$image" sleep 100000 >/dev/null
}

suite_teardown() {
    if [[ -e "$TEST_SUITE_TMP/$NO_DOCKER_NOTE" ]]; then
        return 0
    fi
    remove_test_containers
    sys_clean_slate
}

# remove_test_containers
#   Removes the containers of these tests.
remove_test_containers() {
    local name
    for name in alice olga nolabel created; do
        docker rm -f "impact-test-$name" >/dev/null 2>&1 || true
    done
}

# need_docker
#   Skips the test when suite_setup found no usable Docker daemon.
need_docker() {
    if [[ -e "$TEST_SUITE_TMP/$NO_DOCKER_NOTE" ]]; then
        skip "$(cat -- "$TEST_SUITE_TMP/$NO_DOCKER_NOTE")"
    fi
}

# state_of NAME
#   Prints the state of a container: running, exited, created, ...
state_of() {
    docker inspect --format '{{.State.Status}}' "impact-test-$1"
}

test_dry_run_stops_nothing() {
    need_docker
    run_cmd sys_as_admin "$REMOVE" "$ACC" --dry-run
    assert_status 0
    assert_output_contains '[dry run] Stop the container impact-test-alice'
    assert_output_not_contains 'impact-test-olga'
    assert_output_not_contains 'impact-test-nolabel'
    assert_output_not_contains 'impact-test-created'
    assert_eq running "$(state_of alice)" "container of the person after the dry run"
}

test_the_removal_stops_exactly_the_containers_of_the_person() {
    need_docker
    run_cmd sys_as_admin "$REMOVE" "$ACC" --yes
    assert_status 0
    assert_output_contains '+ Stop the container impact-test-alice'
    assert_eq exited "$(state_of alice)" "container of the person"
    assert_eq running "$(state_of olga)" "container of another person"
    assert_eq running "$(state_of nolabel)" "container without IMPACT label"
    assert_eq created "$(state_of created)" "container of the person that never ran"
}

test_second_run_changes_nothing() {
    need_docker
    run_cmd sys_as_admin "$REMOVE" "$ACC" --yes
    assert_status 0
    assert_output_contains 'Nothing to do'
    assert_eq running "$(state_of olga)" "container of another person"
}
