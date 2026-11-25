#!/bin/bash
# =============================================================================
# 95-build-archive.test.sh: unit tests of workstation/build-archive.sh
#
# Purpose
#   Builds the delivery archive into a temporary folder and checks it: the
#   archive holds exactly the files that install.sh needs plus README.md,
#   inside one folder impact-workstation-<version>/, with root as owner and
#   the right modes; the checksum file matches; two builds give the same
#   archive; wrong usage is refused.
#
# Who runs it
#   tests/workstation/run-tests.sh unit (any account, no root needed).
#
# Usage
#   bash tests/workstation/run-tests.sh unit --filter build-archive
#
# What it changes on the system
#   Nothing outside the temporary folder of the test.
#
# How to undo
#   Nothing to undo.
# =============================================================================

# The lines for the checking tool "shellcheck" stand before the first command
# of the file and therefore count for the whole file.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/testlib.sh"

BUILD="$WORKSTATION_DIR/build-archive.sh"

# version
#   Prints the version of the working copy.
version() {
    local text
    IFS= read -r text <"$WORKSTATION_DIR/VERSION"
    printf '%s\n' "$text"
}

# expected_entries
#   Prints the paths that the archive must hold, sorted: the folder, its
#   three subfolders, and every file that install.sh uses plus README.md.
expected_entries() {
    local name file
    name="impact-workstation-$(version)"
    {
        printf '%s/\n' "$name" "$name/bin" "$name/lib" "$name/etc"
        for file in README.md VERSION install.sh uninstall.sh etc/impact.conf.example etc/github_known_hosts; do
            printf '%s/%s\n' "$name" "$file"
        done
        for file in "$WORKSTATION_DIR"/bin/impact-* "$WORKSTATION_DIR"/lib/impact-*.sh; do
            printf '%s/%s/%s\n' "$name" "$(basename -- "$(dirname -- "$file")")" "$(basename -- "$file")"
        done
    } | LC_ALL=C sort
}

test_the_archive_holds_exactly_the_delivered_files() {
    run_cmd bash "$BUILD" --output-dir "$TEST_TMP"
    assert_status 0
    local archive
    archive="$TEST_TMP/impact-workstation-$(version).tar.gz"
    assert_exists "$archive"
    assert_output_contains 'SHA-256:'
    # "tar --list" prints the paths inside the archive.
    assert_eq "$(expected_entries)" "$(tar --list --gzip --file="$archive" | LC_ALL=C sort)" "entries of the archive"
    # build-archive.sh itself and the tests are no part of the delivery.
    assert_not_contains "$(tar --list --gzip --file="$archive")" 'build-archive.sh'
}

test_owner_and_modes_inside_the_archive() {
    run_cmd bash "$BUILD" --output-dir "$TEST_TMP"
    assert_status 0
    local archive line mode owner path
    archive="$TEST_TMP/impact-workstation-$(version).tar.gz"
    # "tar --list --verbose --numeric-owner" prints mode, owner/group
    # numbers, size, time and path of each entry.
    while read -r mode owner _ _ _ path; do
        assert_eq '0/0' "$owner" "owner of $path"
        case "$path" in
            */ | */bin/* | */install.sh | */uninstall.sh) assert_matches "$mode" '^[d-]rwxr-xr-x$' "mode of $path" ;;
            *) assert_eq '-rw-r--r--' "$mode" "mode of $path" ;;
        esac
    done < <(tar --list --verbose --numeric-owner --gzip --file="$archive")
    line="$(tar --list --verbose --gzip --file="$archive" | grep -c 'impact-workstation' || true)"
    assert_ne 0 "$line" "the archive is not empty"
}

test_checksum_file_matches_and_two_builds_are_equal() {
    mkdir -p "$TEST_TMP/first" "$TEST_TMP/second"
    run_cmd bash "$BUILD" --output-dir "$TEST_TMP/first"
    assert_status 0
    run_cmd bash "$BUILD" --output-dir "$TEST_TMP/second"
    assert_status 0
    local name
    name="impact-workstation-$(version).tar.gz"
    # "sha256sum -c" reads the checksum file and checks the archive.
    run_cmd bash -c "cd '$TEST_TMP/first' && sha256sum -c '$name.sha256'"
    assert_status 0
    assert_output_contains "$name: OK"
    assert_success cmp -s "$TEST_TMP/first/$name" "$TEST_TMP/second/$name"
    # The printed checksum is the one in the file.
    assert_contains "$(bash "$BUILD" --output-dir "$TEST_TMP/first")" "$(cut -d' ' -f1 "$TEST_TMP/first/$name.sha256")"
}

test_the_unpacked_archive_passes_the_checks_of_install() {
    run_cmd bash "$BUILD" --output-dir "$TEST_TMP"
    assert_status 0
    tar --extract --gzip --file="$TEST_TMP/impact-workstation-$(version).tar.gz" --directory="$TEST_TMP"
    local folder
    folder="$TEST_TMP/impact-workstation-$(version)"
    # --help of install.sh and of a command work from the unpacked folder
    # and need no root rights.
    run_cmd bash "$folder/install.sh" --help
    assert_status 0
    assert_output_contains 'install the IMPACT workstation commands'
    run_cmd "$folder/bin/impact-check" --help
    assert_status 0
    assert_success cmp -s "$WORKSTATION_DIR/lib/impact-common.sh" "$folder/lib/impact-common.sh"
}

test_wrong_usage_is_refused() {
    run_cmd bash "$BUILD" --no-such-option
    assert_status 2
    assert_output_contains 'Unknown argument'
    run_cmd bash "$BUILD" --output-dir "$TEST_TMP/missing-folder"
    assert_status 2
    assert_output_contains 'does not exist'
    run_cmd bash "$BUILD" --help
    assert_status 0
    assert_output_contains 'build the delivery archive'
}
