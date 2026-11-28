#!/bin/bash
# =============================================================================
# repos-10-add-model.test.sh: system tests for impact-add-model and the
# folder and extras checks of impact-check-model
#
# Purpose
#   Runs the real commands as the stand-in administrator (through sudo) and
#   checks: they need root; wrong and hostile input is refused before any
#   change; a symbolic link where a folder is expected is refused; a dry run
#   changes nothing; the first run creates the model folder, model.conf,
#   extras and the storage folders with the shared rules; a second run
#   changes nothing; values that differ from the model file are refused; a
#   second --storage adds a root and leaves the first one alone; an existing
#   storage folder and its content are left exactly as they are;
#   impact-check-model reports a correct model as OK and finds bad extras.
#
# Who runs it
#   tests/workstation/run-tests.sh system   (root, disposable system only).
#
# Usage
#   sudo env IMPACT_TEST_DISPOSABLE=yes bash tests/workstation/run-tests.sh system --filter repos-10
#
# What it changes on the system
#   The installed commands, the group impact, /etc/impact, /srv/impact,
#   /opt/impact/admin, the storage roots below /mnt/disk_a and /mnt/disk_b,
#   one test account.
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
# shellcheck disable=SC2016
# Reason for SC2016 (no expansion in single quotes): several texts in this
# file are hostile test input such as '$(touch ...)'. They must stay exactly
# as written.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/testlib.sh"

ADD=/usr/local/bin/impact-add-model
CHECK=/usr/local/bin/impact-check-model
MODEL=Example-Model
ADDRESS=git@github.com:example-org/Example-Model.git
MODEL_FOLDER=/srv/impact/models/Example-Model
LOG_FILE=/opt/impact/admin/log/impact-admin.log
HOSTILE_MARK=/tmp/impact-test-hostile-repos
# The folders whose state the tests compare before and after a run.
WATCHED=(/etc/impact /opt/impact /srv/impact /mnt/disk_a /mnt/disk_b)

suite_setup() {
    sys_clean_slate
    sys_storage_up
    sys_install
    sys_admin_create
    sys_setup
    rm -f -- "$HOSTILE_MARK"
}

suite_teardown() {
    rm -f -- "$HOSTILE_MARK"
    sys_clean_slate
}

# facts PATH
#   Prints mode, owner and group of PATH.
facts() {
    stat -c '%a %U %G' -- "$1"
}

# assert_shared_folder PATH
#   Fails unless PATH is a folder made by impact-add-model: owner root,
#   group impact, mode 2770, default access list for the group.
assert_shared_folder() {
    local acl
    assert_eq "2770 root $SYS_GROUP" "$(facts "$1")" "facts of $1"
    acl="$(getfacl -c -p -E -- "$1" 2>/dev/null)"
    assert_contains "$acl" 'default:group::rwx' "default access list of $1"
    assert_contains "$acl" 'default:user::rwx' "default access list of $1"
    assert_contains "$acl" 'default:other::---' "default access list of $1"
}

# ----------------------------------------------------------------------------
# Refusals before the first run
# ----------------------------------------------------------------------------

# impact-add-model and impact-check-model stop without root (exit code 2);
# --help works without root.
test_needs_root() {
    run_cmd runuser -u "$SYS_ADMIN" -- "$ADD" "$MODEL" "$ADDRESS" --storage "$SYS_ROOT_A" --storage-name Example --dry-run
    assert_status 2
    assert_output_contains 'must run with administrator rights'
    run_cmd runuser -u "$SYS_ADMIN" -- "$CHECK" "$MODEL"
    assert_status 2
    run_cmd runuser -u "$SYS_ADMIN" -- "$ADD" --help
    assert_status 0
    assert_output_contains 'Usage'
}

# Wrong and hostile input is refused before any change.
test_wrong_and_hostile_input_is_refused_before_any_change() {
    local before="$TEST_TMP/before" after="$TEST_TMP/after" index
    snapshot_take "$before" --content "${WATCHED[@]}"
    # Each case is one complete argument list, joined by the separator "|".
    # Every call must end with exit code 2 (wrong usage).
    local -a cases=(
        "bad name|$ADDRESS|--storage|$SYS_ROOT_A|--storage-name|Example"
        "x;touch $HOSTILE_MARK|$ADDRESS|--storage|$SYS_ROOT_A|--storage-name|Example"
        "\$(touch $HOSTILE_MARK)|$ADDRESS|--storage|$SYS_ROOT_A|--storage-name|Example"
        "../etc|$ADDRESS|--storage|$SYS_ROOT_A|--storage-name|Example"
        "Example.partial|$ADDRESS|--storage|$SYS_ROOT_A|--storage-name|Example"
        "-Model|$ADDRESS|--storage|$SYS_ROOT_A|--storage-name|Example"
        "$MODEL|git@gitlab.example:example-org/Example-Model.git|--storage|$SYS_ROOT_A|--storage-name|Example"
        "$MODEL|https://github.com/example-org/Example;touch $HOSTILE_MARK|--storage|$SYS_ROOT_A|--storage-name|Example"
        "$MODEL|git@github.com:../Example-Model.git|--storage|$SYS_ROOT_A|--storage-name|Example"
        "$MODEL|https://github.com/example-org/\$(touch $HOSTILE_MARK)|--storage|$SYS_ROOT_A|--storage-name|Example"
        "$MODEL|$ADDRESS|--storage|/mnt/disk_c/shared|--storage-name|Example"
        "$MODEL|$ADDRESS|--storage|$SYS_ROOT_A/../shared|--storage-name|Example"
        "$MODEL|$ADDRESS|--storage|$SYS_ROOT_A/|--storage-name|Example"
        "$MODEL|$ADDRESS|--storage|mnt/disk_a/shared|--storage-name|Example"
        "$MODEL|$ADDRESS|--storage|$SYS_ROOT_A;touch $HOSTILE_MARK|--storage-name|Example"
        "$MODEL|$ADDRESS|--storage|$SYS_ROOT_A|--storage-name|bad name"
        "$MODEL|$ADDRESS|--storage|$SYS_ROOT_A|--storage-name|../Example"
        "$MODEL|$ADDRESS|--storage|$SYS_ROOT_A|--storage-name|"
        "$MODEL|$ADDRESS|--storage|$SYS_ROOT_A|--storage-name|Example|--branch|a..b"
        "$MODEL|$ADDRESS|--storage|$SYS_ROOT_A|--storage-name|Example|--branch|-x"
        "$MODEL|$ADDRESS|--storage|$SYS_ROOT_A|--storage-name|Example|--branch|\$(touch $HOSTILE_MARK)"
        "$MODEL|$ADDRESS|--storage|$SYS_ROOT_A|--storage-name|Example|--branch|feature/.hidden"
        "$MODEL|$ADDRESS|--storage-name|Example"
        "$MODEL|$ADDRESS|--storage|$SYS_ROOT_A"
        "$MODEL|--storage|$SYS_ROOT_A|--storage-name|Example"
        "$MODEL|$ADDRESS|--storage|$SYS_ROOT_A|--storage-name|Example|--unknown"
        "$MODEL|$ADDRESS|--storage|$SYS_ROOT_A|--storage-name|Example|--storage-name|Other"
    )
    local -a arguments=()
    for index in "${!cases[@]}"; do
        # Split the case at "|" into the list "arguments".
        IFS='|' read -r -a arguments <<<"${cases[index]}"
        run_cmd sys_as_admin "$ADD" "${arguments[@]}"
        if [[ "$RUN_STATUS" != '2' ]]; then
            show_run
            fail "case $index (${cases[index]}): expected exit code 2, got $RUN_STATUS"
        fi
    done
    snapshot_take "$after" --content "${WATCHED[@]}"
    snapshot_assert_same "$before" "$after" "refused calls changed the system"
    assert_missing "$HOSTILE_MARK"
}

# Symbolic link where a folder is expected is refused.
test_symbolic_link_where_a_folder_is_expected_is_refused() {
    local before="$TEST_TMP/before" after="$TEST_TMP/after"
    # A link in the place of the model's storage folder, and one in the
    # place of the model folder.
    ln -s /etc "$SYS_ROOT_A/Linked"
    snapshot_take "$before" --content "${WATCHED[@]}"
    run_cmd sys_as_admin "$ADD" "$MODEL" "$ADDRESS" --storage "$SYS_ROOT_A" --storage-name Linked
    assert_status 4
    assert_output_contains 'is a symbolic link'
    rm -f -- "$SYS_ROOT_A/Linked"
    mkdir -p -- "$TEST_TMP/elsewhere"
    ln -s "$TEST_TMP/elsewhere" "$MODEL_FOLDER"
    run_cmd sys_as_admin "$ADD" "$MODEL" "$ADDRESS" --storage "$SYS_ROOT_A" --storage-name Example
    assert_status 4
    assert_output_contains 'is a symbolic link'
    rm -f -- "$MODEL_FOLDER"
    ln -s /etc "$SYS_ROOT_A/Linked"
    snapshot_take "$after" --content "${WATCHED[@]}"
    rm -f -- "$SYS_ROOT_A/Linked"
    snapshot_assert_same "$before" "$after" "a refused call changed the system"
    assert_missing "$TEST_TMP/elsewhere/model.conf"
    assert_missing /etc/outputs
}

# ----------------------------------------------------------------------------
# Dry run, first run, second run
# ----------------------------------------------------------------------------

# Dry run changes nothing.
test_dry_run_changes_nothing() {
    snapshot_unchanged_by --content "${WATCHED[@]}" -- \
        sys_as_admin "$ADD" "$MODEL" "$ADDRESS" --storage "$SYS_ROOT_A" --storage-name Example --dry-run
    assert_status 0
    assert_output_contains '[dry run] Create the folder /srv/impact/models/Example-Model'
    assert_output_contains "[dry run] Write $MODEL_FOLDER/model.conf"
    assert_output_contains "[dry run] Create the folder $SYS_ROOT_A/Example/inputs/synthpop"
    assert_output_contains 'Dry run: nothing was changed.'
}

# First run creates model folder file and storage folders.
test_first_run_creates_model_folder_file_and_storage_folders() {
    local before_b="$TEST_TMP/before-b" after_b="$TEST_TMP/after-b"
    snapshot_take "$before_b" --content /mnt/disk_b
    run_cmd sys_as_admin "$ADD" "$MODEL" https://github.com/example-org/Example-Model --storage "$SYS_ROOT_A" --storage-name Example
    assert_status 0
    assert_output_contains 'What changed:'
    assert_output_contains 'How to undo:'
    assert_output_contains 'sudo rmdir'
    assert_eq "2750 root $SYS_GROUP" "$(facts "$MODEL_FOLDER")" "model folder"
    assert_eq "2750 root $SYS_GROUP" "$(facts "$MODEL_FOLDER/extras")" "extras folder"
    assert_eq "640 root $SYS_GROUP" "$(facts "$MODEL_FOLDER/model.conf")" "model file"
    # The address is stored in its SSH form.
    assert_file_contains "$MODEL_FOLDER/model.conf" "REPO_URL=$ADDRESS"
    assert_file_contains "$MODEL_FOLDER/model.conf" 'STORAGE_NAME=Example'
    assert_file_contains "$MODEL_FOLDER/model.conf" "STORAGE_ROOTS=$SYS_ROOT_A"
    assert_file_contains "$MODEL_FOLDER/model.conf" 'MODEL_CONF_VERSION=1'
    local folder
    for folder in Example Example/outputs Example/inputs Example/inputs/synthpop; do
        assert_shared_folder "$SYS_ROOT_A/$folder"
    done
    # The other storage root was not named and stays as it was.
    snapshot_take "$after_b" --content /mnt/disk_b
    snapshot_assert_same "$before_b" "$after_b" "the second storage root changed"
    assert_file_contains "$LOG_FILE" "command: impact-add-model $MODEL"
    assert_file_contains "$LOG_FILE" "account: $SYS_ADMIN"
    # The new folders work as intended: a member creates a file in outputs,
    # and the file belongs to the group and is group-writable.
    sys_account_add bob "$SYS_GROUP"
    runuser -u bob -- bash -c "umask 077 && mkdir '$SYS_ROOT_A/Example/outputs/run1' && touch '$SYS_ROOT_A/Example/outputs/run1/result.csv'"
    assert_eq "$SYS_GROUP" "$(stat -c '%G' "$SYS_ROOT_A/Example/outputs/run1/result.csv")" "group of a new file"
    assert_contains "$(getfacl -c -p -E "$SYS_ROOT_A/Example/outputs/run1/result.csv")" 'group::rw-' "access of a new file"
}

# Second run changes nothing.
test_second_run_changes_nothing() {
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log "${WATCHED[@]}" -- \
        sys_as_admin "$ADD" "$MODEL" "$ADDRESS" --storage "$SYS_ROOT_A" --storage-name Example
    assert_status 0
    assert_output_contains 'Nothing to do'
    # Leaving out the storage name and the root also works for a known model.
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log "${WATCHED[@]}" -- \
        sys_as_admin "$ADD" "$MODEL" "$ADDRESS"
    assert_status 0
    assert_output_contains 'Nothing to do'
}

# Values that differ from the model file are refused.
test_values_that_differ_from_the_model_file_are_refused() {
    local before="$TEST_TMP/before" after="$TEST_TMP/after"
    snapshot_take "$before" --content --exclude /opt/impact/admin/log "${WATCHED[@]}"
    run_cmd sys_as_admin "$ADD" "$MODEL" git@github.com:example-org/Other-Model.git --storage "$SYS_ROOT_A"
    assert_status 4
    assert_output_contains 'is registered with the address'
    run_cmd sys_as_admin "$ADD" "$MODEL" "$ADDRESS" --storage "$SYS_ROOT_B" --storage-name Other
    assert_status 4
    assert_output_contains 'uses the storage name Example'
    run_cmd sys_as_admin "$ADD" "$MODEL" "$ADDRESS" --branch dev-example
    assert_status 4
    assert_output_contains 'uses the branch'
    snapshot_take "$after" --content --exclude /opt/impact/admin/log "${WATCHED[@]}"
    snapshot_assert_same "$before" "$after" "a refused call changed the system"
}

# Second storage adds a root and leaves the first alone.
test_second_storage_adds_a_root_and_leaves_the_first_alone() {
    local before_a="$TEST_TMP/before-a" after_a="$TEST_TMP/after-a" folder
    snapshot_take "$before_a" --content --no-accounts /mnt/disk_a
    # The upper-case spelling of the address names the same repository.
    run_cmd sys_as_admin "$ADD" "$MODEL" git@github.com:Example-Org/Example-Model.git --storage "$SYS_ROOT_B"
    assert_status 0
    assert_output_contains "STORAGE_ROOTS=$SYS_ROOT_A,$SYS_ROOT_B"
    assert_file_contains "$MODEL_FOLDER/model.conf" "STORAGE_ROOTS=$SYS_ROOT_A,$SYS_ROOT_B"
    assert_file_contains "$MODEL_FOLDER/model.conf" "REPO_URL=$ADDRESS"
    for folder in Example Example/outputs Example/inputs Example/inputs/synthpop; do
        assert_shared_folder "$SYS_ROOT_B/$folder"
    done
    snapshot_take "$after_a" --content --no-accounts /mnt/disk_a
    snapshot_assert_same "$before_a" "$after_a" "the first storage root changed"
    # Again: nothing to do.
    run_cmd sys_as_admin "$ADD" "$MODEL" "$ADDRESS" --storage "$SYS_ROOT_B" --storage "$SYS_ROOT_A"
    assert_status 0
    assert_output_contains 'Nothing to do'
}

# Existing storage folder and its content are left alone.
test_existing_storage_folder_and_its_content_are_left_alone() {
    local before="$TEST_TMP/before" after="$TEST_TMP/after"
    # An existing model folder on the storage from before the shared rules:
    # another owner, no shared group, content inside.
    sys_account_add oldshared
    mkdir -p -- "$SYS_ROOT_A/Old/outputs/analysis1"
    printf 'data\n' >"$SYS_ROOT_A/Old/outputs/analysis1/result.csv"
    chown -R oldshared:oldshared "$SYS_ROOT_A/Old"
    chmod -R 755 "$SYS_ROOT_A/Old"
    chmod 644 "$SYS_ROOT_A/Old/outputs/analysis1/result.csv"
    snapshot_take "$before" --content --no-accounts "$SYS_ROOT_A/Old/outputs"
    local old_base
    old_base="$(facts "$SYS_ROOT_A/Old") $(getfacl -c -p -E "$SYS_ROOT_A/Old" | tr '\n' ' ')"
    run_cmd sys_as_admin "$ADD" Old-Model git@github.com:example-org/Old-Model.git --storage "$SYS_ROOT_A" --storage-name Old
    assert_status 0
    assert_output_contains "$SYS_ROOT_A/Old exists and does not follow the shared rules"
    assert_output_contains "sudo impact-share-folder $SYS_ROOT_A/Old --dry-run"
    assert_output_contains "$SYS_ROOT_A/Old existed before this run. Its content was not examined."
    snapshot_take "$after" --content --no-accounts "$SYS_ROOT_A/Old/outputs"
    snapshot_assert_same "$before" "$after" "existing storage content changed"
    assert_eq "$old_base" "$(facts "$SYS_ROOT_A/Old") $(getfacl -c -p -E "$SYS_ROOT_A/Old" | tr '\n' ' ')" "the existing folder itself"
    # The missing folders were created with the rules.
    assert_shared_folder "$SYS_ROOT_A/Old/inputs"
    assert_shared_folder "$SYS_ROOT_A/Old/inputs/synthpop"
}

# ----------------------------------------------------------------------------
# impact-check-model: model file, folders, extras
# ----------------------------------------------------------------------------

# Check model reports a correct model as ok.
test_check_model_reports_a_correct_model_as_ok() {
    snapshot_unchanged_by --content "${WATCHED[@]}" -- sys_as_admin "$CHECK" "$MODEL"
    assert_status 0
    assert_output_contains 'Failed checks: 0. Warnings: 0.'
    assert_output_contains '  Result of block 1: OK'
    assert_output_contains '   1  Model file                                   OK'
    assert_output_contains '  Result of block 4: OK'
    assert_output_contains 'No member has a working copy'
}

# Check model refuses wrong input.
test_check_model_refuses_wrong_input() {
    run_cmd sys_as_admin "$CHECK" '../Example-Model'
    assert_status 2
    run_cmd sys_as_admin "$CHECK" "x;touch $HOSTILE_MARK"
    assert_status 2
    assert_missing "$HOSTILE_MARK"
    run_cmd sys_as_admin "$CHECK" Unknown-Model
    assert_status 1
    assert_output_contains 'is not set up on this workstation'
    run_cmd sys_as_admin "$CHECK" "$MODEL" --dry-run
    assert_status 2
}

# Check model finds bad extras.
test_check_model_finds_bad_extras() {
    local extras="$MODEL_FOLDER/extras"
    # A correct extra, then one of each kind of problem.
    install -d -m 2750 -o root -g "$SYS_GROUP" "$extras/inputs" "$extras/inputs/tables"
    install -m 640 -o root -g "$SYS_GROUP" /dev/null "$extras/inputs/tables/small table.csv"
    ln -s /etc/passwd "$extras/inputs/link.csv"
    install -m 640 -o root -g "$SYS_GROUP" /dev/null "$extras/.gitignore"
    install -m 640 -o root -g "$SYS_GROUP" /dev/null "$extras/inputs/bad;name.csv"
    install -m 666 -o root -g "$SYS_GROUP" /dev/null "$extras/inputs/open.csv"
    install -m 600 -o root -g root /dev/null "$extras/inputs/closed.csv"
    install -m 640 -o bob -g "$SYS_GROUP" /dev/null "$extras/inputs/foreign.csv"
    truncate -s 51M "$extras/inputs/large.bin"
    chown root:"$SYS_GROUP" "$extras/inputs/large.bin"
    chmod 640 "$extras/inputs/large.bin"
    run_cmd sys_as_admin "$CHECK" "$MODEL"
    assert_status 1
    assert_output_contains "'inputs/link.csv' is a symbolic link"
    assert_output_contains "'.gitignore' has a name that is not allowed"
    assert_output_contains "'inputs/bad;name.csv' has a name that is not allowed"
    assert_output_contains "'inputs/open.csv' (mode 666) can be changed by accounts other than root"
    assert_output_contains "Members of '$SYS_GROUP' cannot read 'inputs/closed.csv'"
    assert_output_contains "'inputs/foreign.csv' belongs to bob"
    assert_output_contains 'Larger than 50 MB: inputs/large.bin (51 MB)'
    assert_output_contains "sudo chown -R root:$SYS_GROUP $extras"
    assert_output_contains '  Result of block 3: FAIL'
    assert_output_not_contains "'inputs/tables/small table.csv'"
    # After removing the problems only the warning about the large file is
    # left, and the exit code is 0 again.
    rm -f -- "$extras/inputs/link.csv" "$extras/.gitignore" "$extras/inputs/bad;name.csv" \
        "$extras/inputs/open.csv" "$extras/inputs/closed.csv" "$extras/inputs/foreign.csv"
    run_cmd sys_as_admin "$CHECK" "$MODEL"
    assert_status 0
    assert_output_contains '  Result of block 3: WARN'
    assert_output_contains 'Failed checks: 0. Warnings: 1.'
    rm -f -- "$extras/inputs/large.bin"
}

# An extra put in place with "install -D": the new folder gets the mode
# 2755 (readable for all others). impact-check-model and impact-check apply
# the same rule (folders 2750, files 640) and both print the same command;
# after it both are content.
test_check_model_and_check_agree_on_the_rights_of_extras() {
    local extras="$MODEL_FOLDER/extras" fix
    install -D -m 640 -o root -g "$SYS_GROUP" /dev/null "$extras/more/table.csv"
    assert_eq '2755' "$(stat -c '%a' -- "$extras/more")" "mode of a folder made by install -D"
    fix="sudo chown -R root:$SYS_GROUP $extras && sudo find $extras -type d -exec chmod 2750 {} + && sudo find $extras -type f -exec chmod 640 {} +"
    run_cmd sys_as_admin "$CHECK" "$MODEL"
    assert_status 0
    assert_output_contains "1 entries in $extras deviate from the rules (owner root, group '$SYS_GROUP', folders 2750, files 640). Correct the rights: $fix"
    run_cmd sys_as_admin /usr/local/bin/impact-check
    assert_output_contains "1 entries in $extras deviate from the rules (owner root, group '$SYS_GROUP', folders 2750, files 640)."
    assert_output_contains "$fix"
    chmod 2750 -- "$extras/more"
    run_cmd sys_as_admin "$CHECK" "$MODEL"
    assert_status 0
    assert_output_not_contains 'deviate from the rules'
    rm -r -- "$extras/more"
}

# Check model finds missing storage folders.
test_check_model_finds_missing_storage_folders() {
    rmdir -- "$SYS_ROOT_B/Example/inputs/synthpop"
    run_cmd sys_as_admin "$CHECK" "$MODEL"
    assert_status 1
    assert_output_contains "$SYS_ROOT_B/Example/inputs/synthpop is missing"
    # impact-add-model creates the missing folder again, and only that one.
    run_cmd sys_as_admin "$ADD" "$MODEL" "$ADDRESS"
    assert_status 0
    assert_output_contains "Create the folder $SYS_ROOT_B/Example/inputs/synthpop"
    assert_output_not_contains "Create the folder $SYS_ROOT_B/Example/outputs"
    assert_shared_folder "$SYS_ROOT_B/Example/inputs/synthpop"
    run_cmd sys_as_admin "$CHECK" "$MODEL"
    assert_status 0
}

# Both storage roots in one run.
test_both_storage_roots_in_one_run() {
    run_cmd sys_as_admin "$ADD" Both-Model git@github.com:example-org/Both-Model.git \
        --storage "$SYS_ROOT_A" --storage "$SYS_ROOT_B" --storage "$SYS_ROOT_A" --storage-name Both --branch dev-example
    assert_status 0
    assert_file_contains /srv/impact/models/Both-Model/model.conf "STORAGE_ROOTS=$SYS_ROOT_A,$SYS_ROOT_B"
    assert_file_contains /srv/impact/models/Both-Model/model.conf 'BRANCH=dev-example'
    local folder
    for folder in "$SYS_ROOT_A/Both/inputs/synthpop" "$SYS_ROOT_B/Both/inputs/synthpop"; do
        assert_shared_folder "$folder"
    done
}
