#!/bin/bash
# =============================================================================
# repos-20-repositories.test.sh: system tests for impact-get-repo,
# impact-give-repo, impact-update-setup and the working-copy block of
# impact-check-model
#
# Purpose
#   Local bare repositories stand in for GitHub. Each test person's own git
#   settings (~/.gitconfig) contain "url.<base>.insteadOf" lines that send
#   the GitHub addresses there; the commands themselves contain no hook for
#   the tests. Some addresses are sent to the SSH server of the tests on
#   127.0.0.1, so that the real ssh with strict host key checking and the
#   key copy is used. The tests check: refusals as root and of wrong and
#   hostile input (with the IMPACT_RESULT line in every case); a dry run
#   changes nothing; the clone with extras and their ignore list; a second
#   run changes nothing; an existing target is never touched; a leftover
#   .partial folder is removed; an extra in the way of a repository file
#   stops everything; distinct exit codes for "no access", "network
#   problem", an unknown host key, a refused key and "target exists";
#   impact-give-repo with and without a key copy; impact-update-setup
#   changes docker_setup only and refuses to overwrite own changes;
#   impact-check-model finds extras that git does not ignore.
#
# Who runs it
#   tests/workstation/run-tests.sh system   (root, disposable system only).
#   It needs an SSH server on 127.0.0.1: run it where the network is private
#   (a container or a private view).
#
# Usage
#   sudo env IMPACT_TEST_DISPOSABLE=yes bash tests/workstation/run-tests.sh system --filter repos-20
#
# What it changes on the system
#   The installed commands, the group impact, /etc/impact, /srv/impact,
#   /opt/impact/admin, the SSH rules file, the storage roots below
#   /mnt/disk_a and /mnt/disk_b, six test accounts with home folders, and an
#   SSH server process.
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

GET=/usr/local/bin/impact-get-repo
GIVE=/usr/local/bin/impact-give-repo
UPDATE=/usr/local/bin/impact-update-setup
CHECK=/usr/local/bin/impact-check-model
ADD=/usr/local/bin/impact-add-model
MODEL=Example-Model
ADDRESS=git@github.com:example-org/Example-Model.git
EXTRAS=/srv/impact/models/Example-Model/extras
KNOWN_HOSTS=/etc/impact/github_known_hosts
HOSTILE_MARK=/tmp/impact-test-hostile-repos
ALICE_COPY=/home/alice/Repositories/Example-Model

suite_setup() {
    sys_clean_slate
    rm -f -- "$HOSTILE_MARK"
    sys_storage_up
    sys_install
    sys_admin_create
    sys_sshd_start
    sys_setup
    make_github_stand_in
    # Four models: one that exists, one whose repository does not exist,
    # one whose address leads to a closed port, and one that is reached
    # over the real SSH server of the tests.
    add_model "$MODEL" "$ADDRESS" Example
    add_model Closed-Model git@github.com:example-org/Closed-Model.git Closed
    add_model Net-Model git@github.com:netfail-org/Net-Model.git Net
    add_model Ssh-Model git@github.com:sshtest-org/Example-Model.git Sshtest
    run_cmd sys_as_admin "$ADD" Dev-Model "$ADDRESS" --storage "$SYS_ROOT_A" --storage-name Dev --branch dev-example
    if [[ "$RUN_STATUS" != '0' ]]; then
        show_run
        fail "impact-add-model Dev-Model failed"
    fi
    # The extras of Example-Model: a name with a space, and a second file.
    install -d -m 2750 -o root -g "$SYS_GROUP" "$EXTRAS/inputs" "$EXTRAS/inputs/tables"
    printf 'a,b\n1,2\n' >"$EXTRAS/inputs/tables/small table.csv"
    printf 'x\n' >"$EXTRAS/inputs/extra.csv"
    chown root:"$SYS_GROUP" "$EXTRAS/inputs/tables/small table.csv" "$EXTRAS/inputs/extra.csv"
    chmod 640 "$EXTRAS/inputs/tables/small table.csv" "$EXTRAS/inputs/extra.csv"
    # The people. alice, carol and erin have a key copy; bob, dave do not.
    local person
    for person in alice bob carol dave erin; do
        sys_account_add "$person" "$SYS_GROUP"
        person_git_settings "$person"
    done
    give_key_copy alice alice-example
    give_key_copy carol carol-example
    give_key_copy erin erin-example
    # The account that serves a repository over SSH (no member).
    sys_account_add gitsrv
    install -d -m 755 -o gitsrv -g gitsrv /home/gitsrv/git
    as_person gitsrv git config --file /home/gitsrv/.gitconfig safe.directory '*'
    as_person gitsrv git clone -q --bare "file://$GIT_BASE/example-org/Example-Model.git" /home/gitsrv/git/Example-Model.git
    sys_keypair alice
    sys_install_key gitsrv alice
}

suite_teardown() {
    rm -f -- "$HOSTILE_MARK"
    sys_clean_slate
}

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

GIT_BASE="$TEST_SUITE_TMP/git"
WORK="$TEST_SUITE_TMP/work"

# root_git ARGUMENTS...
#   Runs git as root without any git settings file of this machine, so that
#   settings of the test machine (for example signed commits) play no part.
root_git() {
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"
}

# make_github_stand_in
#   Creates the bare repository example-org/Example-Model.git below
#   GIT_BASE (readable for everybody) from a work folder with three
#   branches: main (with docker_setup), dev-example (another Dockerfile),
#   no-setup (without docker_setup).
make_github_stand_in() {
    root_git init -q -b main "$WORK"
    root_git -C "$WORK" config user.name 'Test Example'
    root_git -C "$WORK" config user.email 'test@example.org'
    mkdir -p "$WORK/docker_setup" "$WORK/inputs"
    printf 'Example model\n' >"$WORK/README.md"
    printf 'FROM example:1\n' >"$WORK/docker_setup/Dockerfile"
    printf 'old\n' >"$WORK/docker_setup/old.txt"
    printf '{"setup_version": 2}\n' >"$WORK/docker_setup/impact_model.json"
    printf 'tracked\n' >"$WORK/inputs/tracked.csv"
    printf 'data\n' >"$WORK/data.txt"
    root_git -C "$WORK" add -A
    root_git -C "$WORK" commit -q -m 'first state'
    root_git -C "$WORK" checkout -q -b dev-example
    printf 'FROM example:dev\n' >"$WORK/docker_setup/Dockerfile"
    root_git -C "$WORK" commit -q -a -m 'dev state'
    root_git -C "$WORK" checkout -q -b no-setup main
    root_git -C "$WORK" rm -q -r docker_setup
    root_git -C "$WORK" commit -q -m 'no docker_setup'
    root_git -C "$WORK" checkout -q main
    mkdir -p "$GIT_BASE/example-org"
    root_git clone -q --bare "$WORK" "$GIT_BASE/example-org/Example-Model.git"
    root_git -C "$WORK" remote add origin "$GIT_BASE/example-org/Example-Model.git"
    root_git -C "$WORK" push -q origin dev-example no-setup
    chmod -R a+rX "$GIT_BASE"
}

# push_change MESSAGE
#   Commits all changes of the work folder and sends them to the stand-in.
push_change() {
    root_git -C "$WORK" add -A
    root_git -C "$WORK" commit -q -m "$1"
    root_git -C "$WORK" push -q origin main
    chmod -R a+rX "$GIT_BASE"
}

# add_model MODEL ADDRESS STORAGE_NAME
#   Registers a model with impact-add-model and fails the test on an error.
add_model() {
    run_cmd sys_as_admin "$ADD" "$1" "$2" --storage "$SYS_ROOT_A" --storage-name "$3"
    if [[ "$RUN_STATUS" != '0' ]]; then
        show_run
        fail "impact-add-model $1 failed"
    fi
}

# person_git_settings ACCOUNT
#   Writes the person's own git settings: the GitHub addresses lead to the
#   stand-ins. The longest matching "insteadOf" wins, so the two special
#   owners go to the SSH server of the tests (port 9: nothing listens).
person_git_settings() {
    local file="/home/$1/.gitconfig"
    as_person "$1" git config --file "$file" url."file://$GIT_BASE/".insteadOf 'git@github.com:'
    as_person "$1" git config --file "$file" --add url."file://$GIT_BASE/".insteadOf 'https://github.com/'
    as_person "$1" git config --file "$file" url.'ssh://git@127.0.0.1:9/'.insteadOf 'git@github.com:netfail-org/'
    as_person "$1" git config --file "$file" url.'ssh://gitsrv@127.0.0.1/home/gitsrv/git/'.insteadOf 'git@github.com:sshtest-org/'
    # The stand-in repositories belong to root. git refuses to read a
    # repository of another account unless this setting allows it; on
    # GitHub the question does not arise.
    as_person "$1" git config --file "$file" safe.directory '*'
    as_person "$1" git config --file "$file" user.name "$1"
    as_person "$1" git config --file "$file" user.email "$1@example.org"
}

# give_key_copy ACCOUNT GITHUB_NAME
#   Places a key copy in the person's home folder, as the GUI does: the
#   private key of sys_keypair ACCOUNT, mode 600.
give_key_copy() {
    sys_keypair "$1"
    install -d -m 700 -o "$1" -g "$1" "/home/$1/.ssh"
    install -m 600 -o "$1" -g "$1" "$(sys_key_path "$1")" "/home/$1/.ssh/id_ed25519_$2"
}

# as_person ACCOUNT COMMAND...
#   Runs a command as the person, with the environment of a login: HOME,
#   USER and a plain PATH. Supplementary groups (impact) are set.
as_person() {
    local account="$1"
    shift
    (cd / && runuser -u "$account" -- env -i HOME="/home/$account" USER="$account" \
        LOGNAME="$account" SHELL=/bin/bash PATH=/usr/local/bin:/usr/bin:/bin "$@")
}

# assert_result STATUS CODE REASON
#   Fails unless the exit code of the last run_cmd is CODE and the last
#   line of its output is the IMPACT_RESULT line with STATUS, CODE, REASON.
assert_result() {
    assert_status "$2"
    local last
    last="$(printf '%s\n' "$RUN_OUTPUT" | tail -n 1)"
    assert_matches "$last" "^IMPACT_RESULT status=$1 code=$2 path=[A-Za-z0-9._/-]* reason=$3\$" "last line of the output"
}

# copy_state FILE ACCOUNT FOLDER
#   Writes a snapshot of FOLDER (as seen by root, with content) to FILE.
copy_state() {
    snapshot_take "$1" --content --no-accounts "$3"
}

# ----------------------------------------------------------------------------
# impact-get-repo: refusals
# ----------------------------------------------------------------------------

# Get repo refuses root.
test_get_repo_refuses_root() {
    run_cmd "$GET" "$MODEL"
    assert_result error 2 run_as_root
    assert_output_contains 'impact-give-repo'
}

# Get repo refuses wrong and hostile input before any change.
test_get_repo_refuses_wrong_and_hostile_input_before_any_change() {
    local before="$TEST_TMP/before" after="$TEST_TMP/after" index
    snapshot_take "$before" --content /home/alice /srv/impact /mnt/disk_a
    local -a cases=(
        'bad name'
        '../Example-Model'
        "\$(touch $HOSTILE_MARK)"
        "Example-Model;touch $HOSTILE_MARK"
        'Example-Model.partial'
        '-Example'
        "$MODEL|--github-name|a b"
        "$MODEL|--github-name|../alice"
        "$MODEL|--github-name|\$(touch $HOSTILE_MARK)"
        "$MODEL|--unknown"
        "$MODEL|second"
        "$MODEL|--dry-run=yes"
    )
    local -a arguments=()
    for index in "${!cases[@]}"; do
        IFS='|' read -r -a arguments <<<"${cases[index]}"
        run_cmd as_person alice "$GET" "${arguments[@]}"
        if [[ "$RUN_STATUS" != '2' ]]; then
            show_run
            fail "case $index (${cases[index]}): expected exit code 2, got $RUN_STATUS"
        fi
        assert_result error 2 usage
    done
    run_cmd as_person alice "$GET"
    assert_result error 2 usage
    run_cmd as_person alice "$GET" Unknown-Model
    assert_result error 1 unknown_model
    snapshot_take "$after" --content /home/alice /srv/impact /mnt/disk_a
    snapshot_assert_same "$before" "$after" "refused calls changed the system"
    assert_missing "$HOSTILE_MARK"
}

# Get repo dry run changes nothing.
test_get_repo_dry_run_changes_nothing() {
    snapshot_unchanged_by --content /home/alice /srv/impact -- as_person alice "$GET" "$MODEL" --dry-run
    assert_result ok 0 dry_run
    assert_output_contains "[dry run] Clone $ADDRESS (the default branch) into $ALICE_COPY.partial with the key copy /home/alice/.ssh/id_ed25519_alice-example"
    assert_output_contains '[dry run] List the 2 extra files'
    assert_output_contains "[dry run] Rename $ALICE_COPY.partial to $ALICE_COPY"
}

# ----------------------------------------------------------------------------
# impact-get-repo: the copy
# ----------------------------------------------------------------------------

# Get repo makes the copy with extras that git ignores.
test_get_repo_makes_the_copy_with_extras_that_git_ignores() {
    run_cmd as_person alice "$GET" "$MODEL"
    assert_result ok 0 cloned
    assert_output_contains "path=$ALICE_COPY "
    assert_exists "$ALICE_COPY/README.md"
    assert_missing "$ALICE_COPY.partial"
    assert_eq '750 alice alice' "$(stat -c '%a %U %G' /home/alice/Repositories)" "repository folder"
    # Every entry of the copy belongs to alice.
    assert_eq '' "$(find "$ALICE_COPY" ! -user alice -print -quit)" "entries not owned by alice"
    assert_eq "$(cat "$EXTRAS/inputs/tables/small table.csv")" "$(cat "$ALICE_COPY/inputs/tables/small table.csv")" "extra file content"
    assert_exists "$ALICE_COPY/inputs/extra.csv"
    assert_file_contains "$ALICE_COPY/.git/info/exclude" '/inputs/tables/small table.csv'
    assert_file_contains "$ALICE_COPY/.git/info/exclude" '/inputs/extra.csv'
    # git sees no change at all: the extras are ignored.
    assert_eq '' "$(as_person alice git -C "$ALICE_COPY" status --porcelain --untracked-files=all)" "git status"
    assert_eq "$ADDRESS" "$(as_person alice git -C "$ALICE_COPY" config --get remote.origin.url)" "address of the copy"
    assert_output_contains 'git ignores all 2 extra files'
    assert_output_contains "rm -rf $ALICE_COPY"
}

# Get repo second run changes nothing and says the copy exists.
test_get_repo_second_run_changes_nothing_and_says_the_copy_exists() {
    snapshot_unchanged_by --content /home/alice /srv/impact -- as_person alice "$GET" "$MODEL"
    assert_result error 4 exists
    assert_output_contains 'You have a working copy of Example-Model already'
}

# Existing target is never touched.
test_existing_target_is_never_touched() {
    # A plain folder with the model's name, and a symbolic link.
    as_person alice mkdir /home/alice/Repositories/Closed-Model
    as_person alice touch /home/alice/Repositories/Closed-Model/notes.txt
    as_person alice ln -s /tmp /home/alice/Repositories/Net-Model
    snapshot_unchanged_by --content /home/alice -- as_person alice "$GET" Closed-Model
    assert_result error 4 target_in_use
    snapshot_unchanged_by --content /home/alice -- as_person alice "$GET" Net-Model
    assert_result error 4 target_in_use
    rm -rf /home/alice/Repositories/Closed-Model /home/alice/Repositories/Net-Model
}

# Leftover partial is removed first.
test_leftover_partial_is_removed_first() {
    rm -rf -- "$ALICE_COPY"
    as_person alice mkdir -p "$ALICE_COPY.partial/half"
    as_person alice touch "$ALICE_COPY.partial/half/file"
    run_cmd as_person alice "$GET" "$MODEL"
    assert_result ok 0 cloned
    assert_output_contains "Remove the unfinished copy $ALICE_COPY.partial left by an earlier attempt"
    assert_missing "$ALICE_COPY.partial"
    assert_exists "$ALICE_COPY/.git"
}

# Extra in the way of a repository file stops everything.
test_extra_in_the_way_of_a_repository_file_stops_everything() {
    # One extra with the path of a tracked file, one below a tracked file.
    install -m 640 -o root -g "$SYS_GROUP" /dev/null "$EXTRAS/inputs/tracked.csv"
    install -d -m 2750 -o root -g "$SYS_GROUP" "$EXTRAS/data.txt"
    install -m 640 -o root -g "$SYS_GROUP" /dev/null "$EXTRAS/data.txt/inner.csv"
    give_key_copy bob bob-example
    run_cmd as_person bob "$GET" "$MODEL"
    assert_result error 1 extras_clash
    assert_output_contains 'inputs/tracked.csv (the repository has a file of this name)'
    assert_output_contains 'data.txt (the repository has a file at data.txt)'
    assert_output_contains 'The unfinished copy /home/bob/Repositories/Example-Model.partial was removed.'
    # No copy and no .partial folder are left.
    assert_missing /home/bob/Repositories/Example-Model
    assert_missing /home/bob/Repositories/Example-Model.partial
    rm -rf -- "$EXTRAS/inputs/tracked.csv" "$EXTRAS/data.txt"
    rm -f -- /home/bob/.ssh/id_ed25519_bob-example
}

# Invalid extras are refused before the clone.
test_invalid_extras_are_refused_before_the_clone() {
    ln -s /etc/passwd "$EXTRAS/inputs/link.csv"
    run_cmd as_person carol "$GET" "$MODEL"
    assert_result error 1 extras_invalid
    assert_output_contains "'inputs/link.csv' is a symbolic link"
    assert_output_not_contains 'Clone '
    assert_missing /home/carol/Repositories/Example-Model.partial
    rm -f -- "$EXTRAS/inputs/link.csv"
}

# A repository whose own .gitignore takes an extra back in: the line
# "!inputs/extra.csv" outranks the copy's ignore list (.git/info/exclude),
# so "git add -A" would send the extra to GitHub. impact-get-repo proves
# that git ignores every extra and stops before the copy gets its name.
test_extra_that_the_repository_takes_back_in_stops_the_copy() {
    local work="$TEST_SUITE_TMP/work-ignore" extras=/srv/impact/models/Ignore-Model/extras
    root_git init -q -b main "$work"
    root_git -C "$work" config user.name 'Test Example'
    root_git -C "$work" config user.email 'test@example.org'
    printf 'Ignore model\n' >"$work/README.md"
    printf '!inputs/extra.csv\n' >"$work/.gitignore"
    root_git -C "$work" add -A
    root_git -C "$work" commit -q -m 'takes an extra back in'
    root_git clone -q --bare "$work" "$GIT_BASE/example-org/Ignore-Model.git"
    chmod -R a+rX "$GIT_BASE"
    add_model Ignore-Model git@github.com:example-org/Ignore-Model.git Ignore
    install -d -m 2750 -o root -g "$SYS_GROUP" "$extras/inputs"
    install -m 640 -o root -g "$SYS_GROUP" /dev/null "$extras/inputs/extra.csv"
    run_cmd as_person alice "$GET" Ignore-Model
    assert_result error 1 extras_not_ignored
    assert_output_contains 'git does not ignore every extra file'
    assert_missing /home/alice/Repositories/Ignore-Model
    assert_missing /home/alice/Repositories/Ignore-Model.partial
}

# ----------------------------------------------------------------------------
# impact-get-repo: the way to GitHub
# ----------------------------------------------------------------------------

# No access and network problem have their own exit codes.
test_no_access_and_network_problem_have_their_own_exit_codes() {
    run_cmd as_person alice "$GET" Closed-Model
    assert_result error 5 no_access
    assert_missing /home/alice/Repositories/Closed-Model
    assert_missing /home/alice/Repositories/Closed-Model.partial
    run_cmd as_person alice "$GET" Net-Model
    assert_result error 6 network
    assert_output_contains 'Connection refused'
    assert_missing /home/alice/Repositories/Net-Model.partial
}

# Server without a github host key is refused.
test_server_without_a_github_host_key_is_refused() {
    # The SSH server of the tests shows its own host key, which is not one
    # of GitHub's keys in /etc/impact/github_known_hosts.
    run_cmd as_person alice "$GET" Ssh-Model
    assert_result error 1 host_key
    assert_output_contains 'Host key verification failed'
    assert_missing /home/alice/Repositories/Ssh-Model
    assert_missing /home/alice/Repositories/Ssh-Model.partial
}

# Real ssh with the key copy and a refused key.
test_real_ssh_with_the_key_copy_and_a_refused_key() {
    # For this test only, the host key of the test server counts as known.
    cp -p -- "$KNOWN_HOSTS" "$TEST_TMP/known_hosts.saved"
    printf '127.0.0.1 %s\n' "$(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)" >>"$KNOWN_HOSTS"
    run_cmd as_person alice "$GET" Ssh-Model
    local alice_status="$RUN_STATUS" alice_output="$RUN_OUTPUT"
    # bob's key is not authorised at the server.
    give_key_copy bob bob-example
    run_cmd as_person bob "$GET" Ssh-Model
    local bob_status="$RUN_STATUS" bob_output="$RUN_OUTPUT"
    cp -p -- "$TEST_TMP/known_hosts.saved" "$KNOWN_HOSTS"
    rm -f -- /home/bob/.ssh/id_ed25519_bob-example
    RUN_STATUS="$alice_status" RUN_OUTPUT="$alice_output"
    assert_result ok 0 cloned
    assert_exists /home/alice/Repositories/Ssh-Model/docker_setup/Dockerfile
    assert_eq 'git@github.com:sshtest-org/Example-Model.git' \
        "$(as_person alice git -C /home/alice/Repositories/Ssh-Model config --get remote.origin.url)" "address of the copy"
    RUN_STATUS="$bob_status" RUN_OUTPUT="$bob_output"
    assert_result error 5 key_refused
    assert_output_contains 'Permission denied (publickey'
    assert_missing /home/bob/Repositories/Ssh-Model.partial
}

# impact-get-repo needs exactly one key copy, or --github-name when there are
# several.
test_key_copy_rules() {
    # No key copy at all.
    run_cmd as_person bob "$GET" "$MODEL"
    assert_result error 5 no_key
    # Two key copies: the GitHub name must be given.
    install -m 600 -o alice -g alice "$(sys_key_path alice)" /home/alice/.ssh/id_ed25519_second-name
    run_cmd as_person alice "$GET" Closed-Model
    assert_result error 2 several_keys
    run_cmd as_person alice "$GET" Closed-Model --github-name Alice-Example --dry-run
    assert_result ok 0 dry_run
    assert_output_contains 'with the key copy /home/alice/.ssh/id_ed25519_alice-example'
    rm -f /home/alice/.ssh/id_ed25519_second-name
    # A named key copy that does not exist.
    run_cmd as_person alice "$GET" Closed-Model --github-name nobody-example
    assert_result error 5 no_key
    # A key copy that others can read is refused before ssh would refuse it.
    chmod 644 /home/alice/.ssh/id_ed25519_alice-example
    run_cmd as_person alice "$GET" Closed-Model
    assert_result error 1 key_unusable
    assert_output_contains 'chmod 600 /home/alice/.ssh/id_ed25519_alice-example'
    chmod 600 /home/alice/.ssh/id_ed25519_alice-example
    # A key copy that is a symbolic link.
    ln -s /home/alice/.ssh/id_ed25519_alice-example /home/carol/.ssh/id_ed25519_link-example
    run_cmd as_person carol "$GET" Closed-Model --github-name link-example
    assert_result error 1 key_unusable
    rm -f /home/carol/.ssh/id_ed25519_link-example
}

# Model branch is cloned.
test_model_branch_is_cloned() {
    run_cmd as_person alice "$GET" Dev-Model
    assert_result ok 0 cloned
    assert_output_contains 'branch dev-example'
    assert_eq 'dev-example' "$(as_person alice git -C /home/alice/Repositories/Dev-Model rev-parse --abbrev-ref HEAD)" "branch of the copy"
    assert_eq 'FROM example:dev' "$(cat /home/alice/Repositories/Dev-Model/docker_setup/Dockerfile)" "Dockerfile of the branch"
}

# Symbolic link as repository folder is refused.
test_symbolic_link_as_repository_folder_is_refused() {
    mkdir -p "$TEST_TMP/elsewhere"
    chmod 777 "$TEST_TMP/elsewhere"
    as_person carol ln -s "$TEST_TMP/elsewhere" /home/carol/Repositories
    run_cmd as_person carol "$GET" "$MODEL"
    assert_result error 1 repo_folder
    assert_eq '' "$(ls -A "$TEST_TMP/elsewhere")" "content of the link target"
    rm -f /home/carol/Repositories
}

# ----------------------------------------------------------------------------
# impact-give-repo
# ----------------------------------------------------------------------------

# Give repo needs root and refuses wrong input.
test_give_repo_needs_root_and_refuses_wrong_input() {
    local before="$TEST_TMP/before" after="$TEST_TMP/after" index
    run_cmd runuser -u "$SYS_ADMIN" -- "$GIVE" carol "$MODEL"
    assert_status 2
    assert_output_contains 'must run with administrator rights'
    snapshot_take "$before" --content /home/carol /srv/impact /opt/impact/admin/accounts
    local -a cases=(
        "a b|$MODEL"
        "carol;touch $HOSTILE_MARK|$MODEL"
        "../carol|$MODEL"
        "\$(touch $HOSTILE_MARK)|$MODEL"
        "carol|../$MODEL"
        "carol|$MODEL;touch $HOSTILE_MARK"
        "carol|$MODEL|--github-name|a;b"
        "carol|$MODEL|--github-name|\$(touch $HOSTILE_MARK)"
        "carol"
        "carol|$MODEL|--yes"
    )
    local -a arguments=()
    for index in "${!cases[@]}"; do
        IFS='|' read -r -a arguments <<<"${cases[index]}"
        run_cmd sys_as_admin "$GIVE" "${arguments[@]}"
        if [[ "$RUN_STATUS" != '2' ]]; then
            show_run
            fail "case $index (${cases[index]}): expected exit code 2, got $RUN_STATUS"
        fi
    done
    # No record and no --github-name: wrong usage, with the hint.
    run_cmd sys_as_admin "$GIVE" carol "$MODEL"
    assert_status 2
    assert_output_contains '--github-name'
    # Accounts that may not receive a copy.
    run_cmd sys_as_admin "$GIVE" nosuchaccount "$MODEL" --github-name example
    assert_status 1
    run_cmd sys_as_admin "$GIVE" gitsrv "$MODEL" --github-name example
    assert_status 1
    assert_output_contains "is no member of the group '$SYS_GROUP'"
    run_cmd sys_as_admin "$GIVE" root "$MODEL" --github-name example
    assert_status 1
    run_cmd sys_as_admin "$GIVE" carol Unknown-Model --github-name carol-example
    assert_status 1
    snapshot_take "$after" --content /home/carol /srv/impact /opt/impact/admin/accounts
    snapshot_assert_same "$before" "$after" "refused calls changed the system"
    assert_missing "$HOSTILE_MARK"
}

# Give repo dry run changes nothing.
test_give_repo_dry_run_changes_nothing() {
    snapshot_unchanged_by --content /home/carol /srv/impact /opt/impact -- \
        sys_as_admin "$GIVE" carol "$MODEL" --github-name carol-example --dry-run
    assert_status 0
    assert_output_contains '[dry run] Make the working copy /home/carol/Repositories/Example-Model for carol with the key copy /home/carol/.ssh/id_ed25519_carol-example'
}

# Give repo with the key copy.
test_give_repo_with_the_key_copy() {
    run_cmd sys_as_admin "$GIVE" carol "$MODEL" --github-name carol-example
    assert_status 0
    assert_output_contains 'The copy is made with the key copy /home/carol/.ssh/id_ed25519_carol-example.'
    assert_output_contains 'IMPACT_RESULT status=ok code=0 path=/home/carol/Repositories/Example-Model reason=cloned'
    assert_output_contains 'What changed:'
    assert_eq '' "$(find /home/carol/Repositories -mindepth 1 ! -user carol -print -quit)" "entries not owned by carol"
    assert_exists /home/carol/Repositories/Example-Model/inputs/extra.csv
    assert_file_contains /opt/impact/admin/log/impact-admin.log "command: impact-give-repo carol $MODEL"
}

# Give repo second run changes nothing.
test_give_repo_second_run_changes_nothing() {
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log /home/carol /srv/impact /opt/impact -- \
        sys_as_admin "$GIVE" carol "$MODEL" --github-name carol-example
    assert_status 0
    assert_output_contains 'carol has a working copy of Example-Model already'
    assert_output_contains 'Nothing to do'
}

# Give repo refuses a symbolic link as key copy.
test_give_repo_refuses_a_symbolic_link_as_key_copy() {
    install -d -m 700 -o dave -g dave /home/dave/.ssh
    as_person dave ln -s /etc/hostname /home/dave/.ssh/id_ed25519_dave-example
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log /home/dave /srv/impact /opt/impact -- \
        sys_as_admin "$GIVE" dave "$MODEL" --github-name dave-example
    assert_status 1
    assert_output_contains 'Something other than a plain file of dave lies at /home/dave/.ssh/id_ed25519_dave-example'
    rm -f /home/dave/.ssh/id_ed25519_dave-example
}

# Give repo without a key copy uses anonymous https.
test_give_repo_without_a_key_copy_uses_anonymous_https() {
    run_cmd sys_as_admin "$GIVE" dave "$MODEL" --github-name dave-example
    assert_status 0
    assert_output_contains 'over anonymous HTTPS, because dave has no key copy yet'
    assert_output_contains "Set the address of the copy to $ADDRESS"
    assert_eq "$ADDRESS" "$(as_person dave git -C /home/dave/Repositories/Example-Model config --get remote.origin.url)" "address of the copy"
    assert_eq '' "$(as_person dave git -C /home/dave/Repositories/Example-Model status --porcelain --untracked-files=all)" "git status"
}

# Over anonymous HTTPS only public repositories can be copied. When GitHub
# refuses such a copy, the message names the likely cause (a private
# repository and no key copy yet) and the step for the administrator, with
# no "contact the administrator". The messages of impact-get-repo stand in
# a frame, each line marked with "|".
test_give_repo_anonymous_refusal_names_the_missing_key_copy() {
    run_cmd sys_as_admin "$GIVE" dave Closed-Model --github-name dave-example
    assert_status 5
    assert_output_contains '--- messages of impact-get-repo, run as dave ---'
    assert_output_contains '    | '
    assert_output_contains '--- end of the messages of impact-get-repo ---'
    assert_output_contains 'Over anonymous HTTPS only public repositories can be copied'
    assert_output_contains 'let the person start the GUI once (it places the key copy for git), then run this again'
    assert_output_contains 'its messages are in the frame above'
    assert_missing /home/dave/Repositories/Closed-Model
    assert_missing /home/dave/Repositories/Closed-Model.partial
}

# Give repo takes the github name from the account record.
test_give_repo_takes_the_github_name_from_the_account_record() {
    # The record that impact-add-user writes for every enrolled account.
    load_library
    impact_conf_load
    impact_account_record_write erin erin-example enrolled
    run_cmd sys_as_admin "$GIVE" erin "$MODEL"
    assert_status 0
    assert_output_contains 'GitHub name: erin-example'
    assert_output_contains 'with the key copy /home/erin/.ssh/id_ed25519_erin-example'
    assert_exists /home/erin/Repositories/Example-Model/.git
}

# Give repo passes the exit codes of get repo on.
test_give_repo_passes_the_exit_codes_of_get_repo_on() {
    run_cmd sys_as_admin "$GIVE" erin Closed-Model
    assert_status 5
    assert_output_contains 'reason=no_access'
    run_cmd sys_as_admin "$GIVE" erin Net-Model
    assert_status 6
    # Another folder with the copy's name: exit code 4, nothing touched.
    as_person erin mkdir /home/erin/Repositories/Closed-Model
    snapshot_unchanged_by --content /home/erin -- sys_as_admin "$GIVE" erin Closed-Model
    assert_status 4
    rmdir /home/erin/Repositories/Closed-Model
}

# ----------------------------------------------------------------------------
# impact-check-model: the extras rule in the working copies
# ----------------------------------------------------------------------------

# Check model checks the working copies.
test_check_model_checks_the_working_copies() {
    run_cmd sys_as_admin "$CHECK" "$MODEL"
    assert_status 0
    assert_output_contains "$ALICE_COPY (alice): no extra is a file of the repository, and git ignores all 2 extras"
    # alice's ignore list loses its lines: the extras would be committed.
    cp -p "$ALICE_COPY/.git/info/exclude" "$TEST_TMP/exclude.saved"
    as_person alice sed -i '/^\/inputs/d' "$ALICE_COPY/.git/info/exclude"
    run_cmd sys_as_admin "$CHECK" "$MODEL"
    assert_status 1
    assert_output_contains "$ALICE_COPY (alice): git does not ignore the extra 'inputs/extra.csv'"
    cp -p "$TEST_TMP/exclude.saved" "$ALICE_COPY/.git/info/exclude"
    # An extra that is a file of the repository.
    install -m 640 -o root -g "$SYS_GROUP" /dev/null "$EXTRAS/inputs/tracked.csv"
    run_cmd sys_as_admin "$CHECK" "$MODEL"
    assert_status 1
    assert_output_contains "$ALICE_COPY (alice): the extra 'inputs/tracked.csv' is a file of the repository"
    rm -f -- "$EXTRAS/inputs/tracked.csv"
    # A new extra that the existing copies do not have yet.
    install -m 640 -o root -g "$SYS_GROUP" /dev/null "$EXTRAS/inputs/later.csv"
    run_cmd sys_as_admin "$CHECK" "$MODEL"
    assert_status 0
    assert_output_contains '1 extra files are neither in this copy nor in its ignore list'
    rm -f -- "$EXTRAS/inputs/later.csv"
}

# ----------------------------------------------------------------------------
# impact-update-setup
# ----------------------------------------------------------------------------

# Update setup refuses root and wrong input.
test_update_setup_refuses_root_and_wrong_input() {
    local before="$TEST_TMP/before" after="$TEST_TMP/after"
    run_cmd "$UPDATE" "$MODEL"
    assert_result error 2 run_as_root
    snapshot_take "$before" --content /home/alice
    run_cmd as_person alice "$UPDATE" '../Example-Model'
    assert_result error 2 usage
    run_cmd as_person alice "$UPDATE" "$MODEL" --branch "\$(touch $HOSTILE_MARK)"
    assert_result error 2 usage
    run_cmd as_person alice "$UPDATE" "$MODEL" --branch 'a..b'
    assert_result error 2 usage
    run_cmd as_person alice "$UPDATE" "$MODEL" --github-name 'a b'
    assert_result error 2 usage
    run_cmd as_person alice "$UPDATE" Unknown-Model
    assert_result error 1 unknown_model
    run_cmd as_person bob "$UPDATE" "$MODEL"
    assert_result error 1 no_copy
    snapshot_take "$after" --content /home/alice
    snapshot_assert_same "$before" "$after" "refused calls changed the copy"
    assert_missing "$HOSTILE_MARK"
}

# Update setup with nothing new changes nothing.
test_update_setup_with_nothing_new_changes_nothing() {
    snapshot_unchanged_by --content "$ALICE_COPY" -- as_person alice "$UPDATE" "$MODEL"
    assert_result ok 0 up_to_date
    assert_output_contains 'docker_setup of your copy equals the state on GitHub'
}

# Update setup dry run changes nothing.
test_update_setup_dry_run_changes_nothing() {
    # A new state on GitHub: docker_setup and README.md change.
    printf 'FROM example:2\n' >"$WORK/docker_setup/Dockerfile"
    printf 'new\n' >"$WORK/docker_setup/new.sh"
    rm -f "$WORK/docker_setup/old.txt"
    printf 'Example model, second state\n' >"$WORK/README.md"
    push_change 'second state'
    snapshot_unchanged_by --content "$ALICE_COPY" -- as_person alice "$UPDATE" "$MODEL" --dry-run
    assert_result ok 0 dry_run
    assert_output_contains '[dry run] Copy docker_setup from the default branch'
}

# Update setup copies docker setup and nothing else.
test_update_setup_copies_docker_setup_and_nothing_else() {
    run_cmd as_person alice "$UPDATE" "$MODEL"
    assert_result ok 0 updated
    assert_eq 'FROM example:2' "$(cat "$ALICE_COPY/docker_setup/Dockerfile")" "new Dockerfile"
    assert_exists "$ALICE_COPY/docker_setup/new.sh"
    assert_missing "$ALICE_COPY/docker_setup/old.txt"
    # Everything outside docker_setup stays at the old state.
    assert_eq 'Example model' "$(cat "$ALICE_COPY/README.md")" "README.md"
    local status_lines
    status_lines="$(as_person alice git -C "$ALICE_COPY" status --porcelain --untracked-files=all)"
    assert_eq $'M  docker_setup/Dockerfile\nA  docker_setup/new.sh\nD  docker_setup/old.txt' "$status_lines" "git status"
    assert_output_contains '## main...origin/main'
    # The temporary name of the fetched state is gone; the branch is unchanged.
    assert_eq '' "$(as_person alice git -C "$ALICE_COPY" for-each-ref refs/impact-update-setup)" "temporary names"
    assert_missing "$ALICE_COPY/.git/refs/impact-update-setup"
    assert_output_contains "git -C $ALICE_COPY restore --source=HEAD --staged --worktree -- docker_setup"
}

# Update setup second run changes nothing.
test_update_setup_second_run_changes_nothing() {
    snapshot_unchanged_by --content "$ALICE_COPY" -- as_person alice "$UPDATE" "$MODEL"
    assert_result ok 0 up_to_date
}

# Update setup never overwrites own changes.
test_update_setup_never_overwrites_own_changes() {
    # alice commits the update, then changes the Dockerfile herself.
    as_person alice git -C "$ALICE_COPY" commit -q -m 'docker_setup update'
    printf 'FROM example:3\n' >"$WORK/docker_setup/Dockerfile"
    push_change 'third state'
    as_person alice bash -c "printf 'FROM my-own\n' >'$ALICE_COPY/docker_setup/Dockerfile'"
    # The fetch stores the new state in git's object store (.git/objects)
    # before the comparison; that is no visible change. Everything else of
    # the copy must stay as it was.
    snapshot_unchanged_by --content --exclude "$ALICE_COPY/.git/objects" "$ALICE_COPY" -- as_person alice "$UPDATE" "$MODEL"
    assert_result error 4 local_changes
    assert_output_contains 'docker_setup/Dockerfile'
    assert_eq 'FROM my-own' "$(cat "$ALICE_COPY/docker_setup/Dockerfile")" "own change kept"
    # An untracked file of her own in docker_setup counts as well.
    as_person alice git -C "$ALICE_COPY" checkout -q -- docker_setup
    as_person alice touch "$ALICE_COPY/docker_setup/mine.txt"
    run_cmd as_person alice "$UPDATE" "$MODEL"
    assert_result error 4 local_changes
    as_person alice rm "$ALICE_COPY/docker_setup/mine.txt"
    run_cmd as_person alice "$UPDATE" "$MODEL"
    assert_result ok 0 updated
    assert_eq 'FROM example:3' "$(cat "$ALICE_COPY/docker_setup/Dockerfile")" "Dockerfile"
    as_person alice git -C "$ALICE_COPY" commit -q -m 'docker_setup update'
}

# Update setup from another branch.
test_update_setup_from_another_branch() {
    run_cmd as_person alice "$UPDATE" "$MODEL" --branch dev-example
    assert_result ok 0 updated
    assert_eq 'FROM example:dev' "$(cat "$ALICE_COPY/docker_setup/Dockerfile")" "Dockerfile of dev-example"
    as_person alice git -C "$ALICE_COPY" restore --source=HEAD --staged --worktree -- docker_setup
    run_cmd as_person alice "$UPDATE" "$MODEL" --branch no-setup
    assert_result error 1 no_docker_setup
    run_cmd as_person alice "$UPDATE" "$MODEL" --branch missing-branch
    assert_result error 1 branch_missing
}

# Update setup refuses a copy of another repository.
test_update_setup_refuses_a_copy_of_another_repository() {
    as_person alice git -C "$ALICE_COPY" config remote.origin.url git@github.com:example-org/Other-Model.git
    snapshot_unchanged_by --content "$ALICE_COPY" -- as_person alice "$UPDATE" "$MODEL"
    assert_result error 4 wrong_origin
    as_person alice git -C "$ALICE_COPY" config remote.origin.url "$ADDRESS"
}

# Update setup refuses an unknown host key.
test_update_setup_refuses_an_unknown_host_key() {
    # The copy of Ssh-Model reaches the test server, whose host key is not
    # one of GitHub's keys (it was known only during an earlier test).
    run_cmd as_person alice "$UPDATE" Ssh-Model
    assert_result error 1 host_key
}
