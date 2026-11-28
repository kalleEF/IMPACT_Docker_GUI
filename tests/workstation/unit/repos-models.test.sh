#!/bin/bash
# =============================================================================
# repos-models.test.sh: unit tests for lib/impact-models.sh and the start of
# the five model commands
#
# Purpose
#   Tests the functions of impact-models.sh that need no root: the name rule
#   for extras, the scan of an extras folder, the lines for git's ignore
#   list, the list of storage roots, the meaning of git's error messages,
#   the ssh command line for GitHub, the key copy rules, the clean-up of
#   git's environment variables and the folder lock. It also starts the five
#   commands with --help and with wrong usage, and checks that the two user
#   commands end with the IMPACT_RESULT line in every case.
#
# Who runs it
#   tests/workstation/run-tests.sh unit   (no special rights needed)
#
# Usage
#   bash tests/workstation/run-tests.sh unit --filter repos-models
#
# What it changes on the system
#   Nothing outside the temporary folder of the tests.
#
# How to undo
#   Nothing to undo.
# =============================================================================

# Reading help: the bash constructs used here are explained at the top of
# ../lib/testlib.sh ("Reading help") and where they are first used.

# The lines for the checking tool "shellcheck" stand before the first command
# of the file and therefore count for the whole file.
# shellcheck disable=SC2016
# Reason for SC2016 (no expansion in single quotes): many texts in this file
# are test data such as '$(id)'. They must stay exactly as written.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/testlib.sh"

setup() {
    load_library
    # shellcheck source=../../../workstation/lib/impact-models.sh
    source "$WORKSTATION_DIR/lib/impact-models.sh"
}

# assert_last_line_is_result STATUS CODE REASON
#   Fails unless the last run_cmd ended with CODE and its last output line
#   is the IMPACT_RESULT line with STATUS and REASON.
assert_last_line_is_result() {
    assert_status "$2"
    local last
    last="$(printf '%s\n' "$RUN_OUTPUT" | tail -n 1)"
    assert_matches "$last" "^IMPACT_RESULT status=$1 code=$2 path=[A-Za-z0-9._/-]* reason=$3\$" "last line"
}

# ----------------------------------------------------------------------------
# Names of extras
# ----------------------------------------------------------------------------

# These extra paths are accepted: blanks inside names, dots in front of names,
# several folder levels.
test_valid_extra_paths() {
    local path
    for path in a.csv 'inputs/tables/small table.csv' .Renviron 'x/y_z-1+2@(3),=.txt' \
        'Data 2020/a b c.csv' 'a/b/c/d/e/f.rds' '_x' '1.csv'; do
        assert_success impact_extras_valid_path "$path"
    done
}

# Extra paths that leave the copy, touch git's own files or have unsafe names
# are refused.
test_invalid_extra_paths() {
    local path long_part long_path
    long_part="$(printf 'a%.0s' {1..256})"
    long_path="$(printf 'abcdefghi/%.0s' {1..103})x"
    local -a refused=(
        '' '/abs' 'a/' 'a//b' '..' '../x' 'a/../b' './a' 'a/./b' '.'
        '.git' '.git/hooks/post-checkout' '.GIT/config' 'x/.Git/y' '.gitignore'
        'x/.gitattributes' '.gitmodules' '.github/workflows/x.yml'
        '-x' 'a/-b' ' lead' 'trail ' 'a/ b' 'a /b' $'a\nb' $'a\tb'
        'a;b' 'a*b' 'a?b' 'a[b]' 'a\b' '#x' '!x' 'a$b' '$(id)' 'a`b' "a'b" 'a"b'
        'a:b' 'a|b' 'a&b' 'a<b' 'a>b' 'a~b' 'a%b' $'\xc3\xa9.csv'
        "$long_part" "$long_path"
    )
    for path in "${refused[@]}"; do
        if impact_extras_valid_path "$path"; then
            fail "the extra path '$path' was accepted"
        fi
    done
}

# The lines for .git/info/exclude start with the mark and name each extra from
# the top of the copy.
test_exclude_lines() {
    local text
    text="$(impact_extras_exclude_lines 'inputs/tables/small table.csv' a.csv)"
    assert_eq "$IMPACT_EXCLUDE_MARK"$'\n/inputs/tables/small table.csv\n/a.csv' "$text"
    text="$(impact_extras_exclude_lines)"
    assert_eq "$IMPACT_EXCLUDE_MARK" "$text" "no files"
}

# Extras scan lists files and folders and names problems.
test_extras_scan_lists_files_and_folders_and_names_problems() {
    local extras="$TEST_TMP/extras"
    mkdir -p "$extras/inputs/tables" "$extras/empty"
    printf 'a\n' >"$extras/inputs/tables/small table.csv"
    printf 'b\n' >"$extras/top.csv"
    ln -s /etc/passwd "$extras/inputs/link.csv"
    printf 'c\n' >"$extras/.gitignore"
    printf 'd\n' >"$extras/inputs/bad;name.csv"
    mkfifo "$extras/inputs/pipe"
    impact_extras_scan "$extras" || true
    assert_eq 'inputs/tables/small table.csv|top.csv' "$(IFS='|'; printf '%s' "${IMPACT_EXTRAS_FILES[*]}")" "files"
    assert_eq 'empty|inputs|inputs/tables' "$(IFS='|'; printf '%s' "${IMPACT_EXTRAS_DIRS[*]}")" "folders"
    local problems
    problems="$(printf '%s\n' "${IMPACT_EXTRAS_PROBLEMS[@]}")"
    assert_contains "$problems" "'inputs/link.csv' is a symbolic link"
    assert_contains "$problems" "'.gitignore' has a name that is not allowed"
    assert_contains "$problems" "'inputs/bad;name.csv' has a name that is not allowed"
    assert_contains "$problems" "'inputs/pipe' is neither a plain file nor a folder"
    assert_eq 4 "${#IMPACT_EXTRAS_PROBLEMS[@]}" "number of problems"
    # The scan reports failure while problems exist.
    assert_fails impact_extras_scan "$extras"
}

# Extras scan of a missing or linked folder.
test_extras_scan_of_a_missing_or_linked_folder() {
    assert_success impact_extras_scan "$TEST_TMP/none"
    assert_eq 0 "${#IMPACT_EXTRAS_FILES[@]}" "files of a missing folder"
    mkdir "$TEST_TMP/real"
    ln -s "$TEST_TMP/real" "$TEST_TMP/linked"
    assert_fails impact_extras_scan "$TEST_TMP/linked"
    assert_contains "${IMPACT_EXTRAS_PROBLEMS[0]}" 'is no real folder'
}

# Extras scan reports unreadable entries.
test_extras_scan_reports_unreadable_entries() {
    if ((EUID == 0)); then
        skip "root can read every file; this case needs a normal account"
    fi
    mkdir -p "$TEST_TMP/extras/closed"
    printf 'x\n' >"$TEST_TMP/extras/secret.csv"
    chmod 000 "$TEST_TMP/extras/secret.csv" "$TEST_TMP/extras/closed"
    assert_fails impact_extras_scan "$TEST_TMP/extras"
    local problems
    problems="$(printf '%s\n' "${IMPACT_EXTRAS_PROBLEMS[@]}")"
    assert_contains "$problems" "The file 'secret.csv' cannot be read"
    assert_contains "$problems" "The folder 'closed' cannot be read"
    chmod 700 "$TEST_TMP/extras/closed"
}

# Large extras are listed.
test_large_extras_are_listed() {
    mkdir -p "$TEST_TMP/extras/inputs"
    truncate -s 51M "$TEST_TMP/extras/inputs/large.bin"
    truncate -s 1M "$TEST_TMP/extras/small.bin"
    assert_eq '51 inputs/large.bin' "$(impact_extras_large_files "$TEST_TMP/extras")"
}

# ----------------------------------------------------------------------------
# Storage roots and folders
# ----------------------------------------------------------------------------

# Storage folders and roots union.
test_storage_folders_and_roots_union() {
    assert_eq $'/r/E\n/r/E/outputs\n/r/E/inputs\n/r/E/inputs/synthpop' "$(impact_models_storage_folders /r/E)"
    assert_eq '/a' "$(impact_models_roots_union '' /a)"
    assert_eq '/a,/b' "$(impact_models_roots_union '/a' /b)"
    assert_eq '/a,/b' "$(impact_models_roots_union '/a,/b' /b /a)" "nothing new"
    assert_eq '/b,/a' "$(impact_models_roots_union '/b' /a /a)" "existing order first, no doubles"
    assert_eq '/a' "$(impact_models_roots_union '/a')" "no new root"
}

# ----------------------------------------------------------------------------
# git and GitHub
# ----------------------------------------------------------------------------

# classify TEXT
#   Prints "<code> <reason>" for an error text.
classify() {
    impact_git_classify_error "$1"
    printf '%s %s' "$IMPACT_GIT_ERROR_CODE" "$IMPACT_GIT_ERROR_REASON"
}

# Each typical git error is mapped to its exit code and reason word (host key,
# key refused, no access, network).
test_git_error_classification() {
    assert_eq '1 host_key' "$(classify 'Host key verification failed.
fatal: Could not read from remote repository.')"
    assert_eq '1 host_key' "$(classify '@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@')"
    assert_eq '1 host_key' "$(classify 'No ED25519 host key is known for github.com and you have requested strict checking.')"
    assert_eq '5 key_refused' "$(classify 'git@github.com: Permission denied (publickey).
fatal: Could not read from remote repository.')"
    assert_eq '5 no_access' "$(classify 'ERROR: Repository not found.
fatal: Could not read from remote repository.
fatal: The remote end hung up unexpectedly')"
    assert_eq '5 no_access' "$(classify "fatal: could not read Username for 'https://github.com': terminal prompts disabled")"
    assert_eq '5 no_access' "$(classify "remote: Repository not found.
fatal: repository 'https://github.com/o/r.git/' not found")"
    assert_eq '5 no_access' "$(classify "fatal: '/srv/git/o/r.git' does not appear to be a git repository")"
    assert_eq '6 network' "$(classify 'ssh: Could not resolve hostname github.com: Temporary failure in name resolution')"
    assert_eq '6 network' "$(classify "fatal: unable to access 'https://github.com/o/r.git/': Could not resolve host: github.com")"
    assert_eq '6 network' "$(classify 'ssh: connect to host github.com port 22: Connection timed out')"
    assert_eq '6 network' "$(classify 'ssh: connect to host 127.0.0.1 port 9: Connection refused')"
    assert_eq '6 network' "$(classify 'ssh: connect to host github.com port 22: Network is unreachable')"
    assert_eq '6 network' "$(classify 'kex_exchange_identification: read: Connection reset by peer')"
    assert_eq '6 network' "$(classify 'fetch-pack: unexpected disconnect while reading sideband packet
fatal: early EOF')"
    assert_eq '1 branch_missing' "$(classify 'warning: Could not find remote branch dev to clone.
fatal: Remote branch dev not found in upstream origin')"
    assert_eq '1 branch_missing' "$(classify "fatal: couldn't find remote ref refs/heads/dev")"
    assert_eq '1 key_unusable' "$(classify 'WARNING: UNPROTECTED PRIVATE KEY FILE!')"
    assert_eq '1 git_failed' "$(classify 'fatal: something unexpected')"
    assert_eq '1 git_failed' "$(classify '')"
    # Every class has a cause text for the person.
    impact_git_classify_error 'Connection refused'
    assert_contains "$IMPACT_GIT_ERROR_CAUSE" 'could not reach GitHub'
}

# Same repository in both address forms.
test_same_repository_in_both_address_forms() {
    assert_success impact_git_same_repo git@github.com:o/r.git https://github.com/o/r
    assert_success impact_git_same_repo git@github.com:Example-Org/Repo.git git@github.com:example-org/repo.git
    assert_success impact_git_same_repo https://github.com/o/r.git/ git@github.com:o/r
    assert_fails impact_git_same_repo git@github.com:o/r.git git@github.com:o/other.git
    assert_fails impact_git_same_repo git@github.com:o/r.git git@gitlab.example:o/r.git
    assert_fails impact_git_same_repo '' git@github.com:o/r.git
    assert_fails impact_git_same_repo 'git@github.com:o/r.git;id' git@github.com:o/r.git
}

# Ssh command for github.
test_ssh_command_for_github() {
    local text
    text="$(impact_git_ssh_command /home/alice/.ssh/id_ed25519_alice-example)"
    assert_contains "$text" "-i '/home/alice/.ssh/id_ed25519_alice-example'"
    assert_contains "$text" '-F none'
    assert_contains "$text" 'StrictHostKeyChecking=yes'
    assert_contains "$text" "'UserKnownHostsFile=/etc/impact/github_known_hosts'"
    assert_contains "$text" 'GlobalKnownHostsFile=/dev/null'
    assert_contains "$text" 'IdentitiesOnly=yes'
    assert_contains "$text" 'BatchMode=yes'
    assert_contains "$text" 'IdentityAgent=none'
    assert_not_contains "$text" 'accept-new'
    # A path that could break the command line is refused.
    assert_fails impact_git_ssh_command "/home/alice/.ssh/id_ed25519_a b"
    assert_fails impact_git_ssh_command "/home/alice/.ssh/id_ed25519_a'b"
    assert_fails impact_git_ssh_command 'relative/key'
}

# Git environment is cleaned.
test_git_environment_is_cleaned() {
    export GIT_DIR=/tmp/elsewhere GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no' \
        GIT_CONFIG_PARAMETERS="'core.sshCommand=x'" SSH_AUTH_SOCK=/tmp/agent GIT_WORK_TREE=/tmp OTHER_VALUE=kept
    impact_git_clean_env
    assert_eq '' "$(printenv GIT_DIR || true)" GIT_DIR
    assert_eq '' "$(printenv GIT_SSH_COMMAND || true)" GIT_SSH_COMMAND
    assert_eq '' "$(printenv GIT_CONFIG_PARAMETERS || true)" GIT_CONFIG_PARAMETERS
    assert_eq '' "$(printenv GIT_WORK_TREE || true)" GIT_WORK_TREE
    assert_eq '' "$(printenv SSH_AUTH_SOCK || true)" SSH_AUTH_SOCK
    assert_eq 'kept' "$(printenv OTHER_VALUE)" OTHER_VALUE
}

# ----------------------------------------------------------------------------
# Key copies and the folder lock
# ----------------------------------------------------------------------------

# Only key copies with a valid GitHub name in the file name are found, in
# lower case.
test_key_copy_names() {
    local home="$TEST_TMP/home"
    mkdir -p "$home/.ssh"
    touch "$home/.ssh/id_ed25519_alice-example" "$home/.ssh/id_ed25519_alice-example.pub" \
        "$home/.ssh/id_ed25519_Second_Name" "$home/.ssh/id_ed25519_bad name" \
        "$home/.ssh/id_ed25519_-x" "$home/.ssh/id_rsa" "$home/.ssh/authorized_keys"
    assert_eq $'alice-example\nsecond_name' "$(impact_key_copy_names "$home")"
    assert_eq '' "$(impact_key_copy_names "$TEST_TMP/nobody")" "no .ssh folder"
}

# A key copy is usable only when no other account may read it (mode 600 or
# 400).
test_key_copy_usable() {
    local key="$TEST_TMP/id_ed25519_alice-example"
    printf 'key\n' >"$key"
    chmod 600 "$key"
    assert_success impact_key_copy_usable "$key"
    chmod 400 "$key"
    assert_success impact_key_copy_usable "$key"
    chmod 640 "$key"
    assert_fails impact_key_copy_usable "$key"
    assert_contains "$IMPACT_KEY_COPY_PROBLEM" "chmod 600 $key"
    chmod 600 "$key"
    ln -s "$key" "$TEST_TMP/link"
    assert_fails impact_key_copy_usable "$TEST_TMP/link"
    assert_contains "$IMPACT_KEY_COPY_PROBLEM" 'symbolic link'
    assert_fails impact_key_copy_usable "$TEST_TMP/missing"
    assert_contains "$IMPACT_KEY_COPY_PROBLEM" 'does not exist'
    mkdir "$TEST_TMP/folder"
    assert_fails impact_key_copy_usable "$TEST_TMP/folder"
}

# Folder lock allows one command at a time.
test_folder_lock_allows_one_command_at_a_time() {
    mkdir "$TEST_TMP/repositories"
    assert_success impact_models_lock_dir "$TEST_TMP/repositories"
    # A second process cannot take the lock while this one holds it.
    run_cmd flock -n "$TEST_TMP/repositories" true
    assert_status 1
    assert_fails impact_models_lock_dir "$TEST_TMP/missing-folder"
}

# ----------------------------------------------------------------------------
# The commands: help, wrong usage, the result line
# ----------------------------------------------------------------------------

# Every command shows its help.
test_every_command_shows_its_help() {
    local command
    for command in impact-add-model impact-check-model impact-get-repo impact-give-repo impact-update-setup; do
        run_cmd "$WORKSTATION_DIR/bin/$command" --help
        assert_status 0
        assert_output_contains 'Usage'
        assert_output_contains 'What it changes on the system'
        assert_output_contains 'How to undo'
        assert_output_not_contains 'Reading help'
    done
}

# Administrator commands refuse wrong usage.
test_administrator_commands_refuse_wrong_usage() {
    run_cmd "$WORKSTATION_DIR/bin/impact-add-model" Example-Model --unknown
    assert_status 2
    assert_output_contains "Unknown option '--unknown'"
    run_cmd "$WORKSTATION_DIR/bin/impact-give-repo" alice
    assert_status 2
    run_cmd "$WORKSTATION_DIR/bin/impact-check-model" Example-Model --dry-run
    assert_status 2
    run_cmd "$WORKSTATION_DIR/bin/impact-add-model" Example-Model git@github.com:o/r.git --storage-name a --storage-name b
    assert_status 2
    assert_output_contains 'was given twice'
}

# Administrator commands need root.
test_administrator_commands_need_root() {
    if ((EUID == 0)); then
        skip "this test needs a normal account"
    fi
    run_cmd "$WORKSTATION_DIR/bin/impact-add-model" Example-Model git@github.com:o/r.git --storage /mnt/disk_a/shared --storage-name Example
    assert_status 2
    assert_output_contains 'must run with administrator rights'
    run_cmd "$WORKSTATION_DIR/bin/impact-check-model" Example-Model
    assert_status 2
    assert_output_contains 'must run with administrator rights'
    run_cmd "$WORKSTATION_DIR/bin/impact-give-repo" alice Example-Model
    assert_status 2
    assert_output_contains 'must run with administrator rights'
}

# User commands end with the result line in every case.
test_user_commands_end_with_the_result_line_in_every_case() {
    local command
    for command in impact-get-repo impact-update-setup; do
        run_cmd "$WORKSTATION_DIR/bin/$command" --help
        assert_last_line_is_result ok 0 ok
        run_cmd "$WORKSTATION_DIR/bin/$command"
        assert_last_line_is_result error 2 usage
        run_cmd "$WORKSTATION_DIR/bin/$command" Example-Model --unknown
        assert_last_line_is_result error 2 usage
        run_cmd "$WORKSTATION_DIR/bin/$command" Example-Model $'line\nbreak'
        assert_last_line_is_result error 2 usage
        if ((EUID == 0)); then
            run_cmd "$WORKSTATION_DIR/bin/$command" Example-Model
            assert_last_line_is_result error 2 run_as_root
        elif [[ ! -e /etc/impact/impact.conf ]]; then
            run_cmd "$WORKSTATION_DIR/bin/$command" Example-Model
            assert_last_line_is_result error 3 not_prepared
        fi
    done
}
