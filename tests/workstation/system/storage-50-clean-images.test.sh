#!/bin/bash
# =============================================================================
# storage-50-clean-images.test.sh: impact-clean-images with a real Docker daemon
#
# Purpose
#   Proves with a real Docker daemon that impact-clean-images
#     - lists by default and changes nothing;
#     - marks for removal: images of a removed account, of an account that
#       no longer exists, of a model the person has no working copy of, and
#       an old build without a name;
#     - keeps: an image whose working copy exists, an image that a container
#       uses, an image whose label is no account name, and every image
#       without the label impact.account;
#     - with --remove and --dry-run removes nothing; without a terminal and
#       without --yes removes nothing; with --yes removes exactly the marked
#       images; a second run finds nothing to remove;
#     - refuses wrong input.
#   The test images are made with "docker import" from an empty archive and
#   carry the label impact.account, as the GUI's own builds do. No image is
#   downloaded. Without a Docker daemon every test is reported as skipped.
#
# Who runs it
#   tests/workstation/run-tests.sh system   (root, disposable system only,
#   with a running Docker daemon)
#
# Usage
#   sudo env IMPACT_TEST_DISPOSABLE=yes bash tests/workstation/run-tests.sh system --filter storage-50
#
# What it changes on the system
#   The installed commands and their settings, the test accounts alice and
#   bob, Docker images named *-model:* and impact-test-*, one container
#   impact-test-user (all removed again), the storage roots.
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

CLEAN=/usr/local/bin/impact-clean-images
# Written by suite_setup when the tests cannot run here, with the reason.
NO_DOCKER_NOTE='no-docker'
TEST_IMAGES=(example-model:alice other-model:alice used-model:alice example-model:bob
    example-model:ghost impact-test-weird:tag impact-test-plain:latest)

suite_setup() {
    # A stand-in docker of another test file must not be mistaken for the
    # real one.
    if [[ -f /usr/local/sbin/docker ]] || ! timeout 20 docker version >/dev/null 2>&1; then
        printf 'no Docker daemon answers on this machine\n' >"$TEST_SUITE_TMP/$NO_DOCKER_NOTE"
        return 0
    fi
    remove_test_docker_objects
    sys_clean_slate
    sys_storage_up
    sys_install
    sys_admin_create
    sys_setup
    sys_account_add alice "$SYS_GROUP"
    sys_account_add bob "$SYS_GROUP"
    # alice has a working copy of Example-Model only.
    runuser -u alice -- mkdir -p /home/alice/Repositories/Example-Model
    # bob was removed: record "removed" and an expiry date in the past.
    load_library
    impact_conf_load || fail "the settings file cannot be read"
    impact_account_record_write bob bob-example removed || fail "the record of bob cannot be written"
    usermod --expiredate 1 -- bob
    # The images: an empty archive with a label, as "docker import" makes it.
    tar -cf "$TEST_SUITE_TMP/empty.tar" --files-from /dev/null
    make_image example-model:alice alice      # becomes an old build without a name ...
    make_image example-model:alice alice      # ... when this one takes the name
    make_image other-model:alice alice
    make_image used-model:alice alice
    make_image example-model:bob bob
    make_image example-model:ghost ghost
    make_image impact-test-weird:tag 'Not An Account'
    docker import "$TEST_SUITE_TMP/empty.tar" impact-test-plain:latest >/dev/null
    docker create --name impact-test-user used-model:alice /bin/true >/dev/null
}

suite_teardown() {
    if [[ -e "$TEST_SUITE_TMP/$NO_DOCKER_NOTE" ]]; then
        return 0
    fi
    remove_test_docker_objects
    sys_clean_slate
}

# make_image NAME ACCOUNT_LABEL
#   Creates a tiny image NAME with the label impact.account=ACCOUNT_LABEL.
make_image() {
    docker import --change "LABEL impact.account=\"$2\"" "$TEST_SUITE_TMP/empty.tar" "$1" >/dev/null
}

# remove_test_docker_objects
#   Removes the container and all images of these tests.
remove_test_docker_objects() {
    local id
    docker rm -f impact-test-user >/dev/null 2>&1 || true
    docker image rm "${TEST_IMAGES[@]}" >/dev/null 2>&1 || true
    for id in $(docker image ls --all --no-trunc --quiet --filter label=impact.account 2>/dev/null); do
        docker image rm "$id" >/dev/null 2>&1 || true
    done
}

# need_docker
#   Skips the test when suite_setup found no usable Docker daemon.
need_docker() {
    if [[ -e "$TEST_SUITE_TMP/$NO_DOCKER_NOTE" ]]; then
        skip "$(cat -- "$TEST_SUITE_TMP/$NO_DOCKER_NOTE")"
    fi
}

# docker_state FILE
#   Writes the list of all images and containers to FILE.
docker_state() {
    {
        docker image ls --all --no-trunc --format '{{.ID}} {{.Repository}}:{{.Tag}}' | LC_ALL=C sort
        docker ps --all --no-trunc --format '{{.ID}} {{.Image}} {{.Names}}' | LC_ALL=C sort
    } >"$1"
}

# docker_unchanged_by COMMAND...
#   Runs COMMAND with run_cmd and fails when the images or containers
#   changed.
docker_unchanged_by() {
    docker_state "$TEST_TMP/docker-before"
    run_cmd "$@"
    docker_state "$TEST_TMP/docker-after"
    snapshot_assert_same "$TEST_TMP/docker-before" "$TEST_TMP/docker-after" "the images or containers changed: $*"
}

test_wrong_input_is_refused() {
    need_docker
    docker_unchanged_by sys_as_admin "$CLEAN" extra
    assert_status 2
    assert_output_contains 'Too many arguments'
    docker_unchanged_by sys_as_admin "$CLEAN" --yes
    assert_status 2
    assert_output_contains '--yes answers the question of --remove'
    docker_unchanged_by sys_as_admin "$CLEAN" --force
    assert_status 2
    docker_unchanged_by runuser -u "$SYS_ADMIN" -- "$CLEAN"
    assert_status 2
}

test_the_list_changes_nothing_and_shows_each_decision() {
    need_docker
    # The list writes nothing: no log block, no file in a home folder.
    snapshot_take "$TEST_TMP/files-before" --content /opt/impact /home
    docker_unchanged_by sys_as_admin "$CLEAN"
    snapshot_take "$TEST_TMP/files-after" --content /opt/impact /home
    snapshot_assert_same "$TEST_TMP/files-before" "$TEST_TMP/files-after" "the list changed files"
    assert_status 0
    assert_output_contains 'KEEP    example-model:alice'
    assert_output_contains 'alice has a working copy of this model'
    assert_output_contains 'REMOVE  other-model:alice'
    assert_output_contains 'alice has no working copy of this model any more'
    assert_output_contains 'KEEP    used-model:alice'
    assert_output_contains 'a container uses it (impact-test-user)'
    assert_output_contains 'REMOVE  example-model:bob'
    assert_output_contains 'the account bob was removed'
    assert_output_contains 'REMOVE  example-model:ghost'
    assert_output_contains 'the account ghost was removed'
    assert_output_contains 'REMOVE  sha256:'
    assert_output_contains 'an old build without a name'
    assert_output_contains 'KEEP    impact-test-weird:tag'
    assert_output_contains 'its label impact.account is no account name'
    assert_output_not_contains 'impact-test-plain'
    assert_output_not_contains 'rocker'
    assert_output_contains 'To keep: 3. To remove: 4'
    assert_output_contains 'Nothing was removed. To remove the 4 images marked REMOVE: sudo impact-clean-images --remove'
}

test_remove_with_dry_run_removes_nothing() {
    need_docker
    docker_unchanged_by sys_as_admin "$CLEAN" --remove --dry-run
    assert_status 0
    assert_output_contains '[dry run] Remove the image other-model:alice (account alice)'
    assert_output_contains 'A real run asks here: Remove 4 images'
}

test_remove_without_terminal_and_without_yes_removes_nothing() {
    need_docker
    # setsid starts the command without a terminal, so nobody can answer.
    docker_unchanged_by timeout 60 setsid --wait runuser -u "$SYS_ADMIN" -- sudo -n -- "$CLEAN" --remove
    assert_status 1
    assert_output_contains 'no terminal is available'
    assert_output_contains 'Nothing was removed'
}

test_remove_with_yes_removes_exactly_the_marked_images() {
    need_docker
    run_cmd sys_as_admin "$CLEAN" --remove --yes
    assert_status 0
    assert_output_contains 'What changed:'
    assert_output_contains 'Remove the image example-model:bob (account bob): the account bob was removed'
    assert_output_contains 'A removed image cannot be brought back'
    local left
    left="$(docker image ls --all --format '{{.Repository}}:{{.Tag}}' | grep -E -- '-model:|impact-test-' | LC_ALL=C sort | paste -sd' ' -)"
    assert_eq 'example-model:alice impact-test-plain:latest impact-test-weird:tag used-model:alice' "$left" "images that are left"
    assert_eq '' "$(docker image ls --all --quiet --filter dangling=true --filter label=impact.account)" "old builds without a name that are left"
    assert_file_contains /opt/impact/admin/log/impact-admin.log 'impact-clean-images --remove --yes'
}

test_second_run_removes_nothing() {
    need_docker
    docker_unchanged_by sys_as_admin "$CLEAN" --remove --yes
    assert_status 0
    assert_output_contains 'To remove: 0'
    assert_output_contains 'Nothing to do'
}
