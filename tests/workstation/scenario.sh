#!/bin/bash
# =============================================================================
# scenario.sh: the end-to-end test of the workstation commands
#
# Purpose
#   Walks once through the life of a workstation, in the order in which the
#   administrator works, with the real commands at their real places:
#   health check on the untouched machine, installation, setup with the SSH
#   rules, one model, two colleagues, logins and tunnels through a real SSH
#   server on 127.0.0.1, working copies from a local repository that stands
#   in for GitHub, the shared storage with two accounts writing, the health
#   check on the set-up machine, the removal of a colleague, the backup
#   archive, and the removal of the commands. The Docker parts run when a
#   Docker daemon answers and are reported as skipped otherwise.
#   It complements the system tests (tests/workstation/system), which test
#   each command on its own in depth.
#
# Who runs it
#   Developers and the automatic checks (GitHub Actions), as root on a
#   disposable machine: a private test view, a container, or a fresh GitHub
#   runner. It changes the machine (accounts, groups, SSH rules) and refuses
#   to start unless IMPACT_TEST_DISPOSABLE=yes is set.
#
# Usage
#   sudo env IMPACT_TEST_DISPOSABLE=yes bash tests/workstation/scenario.sh [options]
#
# Examples
#   sudo env IMPACT_TEST_DISPOSABLE=yes bash tests/workstation/scenario.sh
#   Install from an unpacked delivery archive in place of the working copy:
#     sudo env IMPACT_TEST_DISPOSABLE=yes bash tests/workstation/scenario.sh \
#          --from /root/impact-workstation-2.1.0
#   Keep the state at the end, to look at it:
#     sudo env IMPACT_TEST_DISPOSABLE=yes bash tests/workstation/scenario.sh --keep
#
# Options
#   --from <folder>   the unpacked folder to install from (default: the
#                     folder workstation of this working copy)
#   --keep            leave the accounts, the settings and the test storage
#                     in place at the end (the next run cleans up first)
#   --verbose         print the output of every step, also of those that pass
#   --help            show this text
#
# Environment
#   IMPACT_TEST_DISPOSABLE=yes   required: confirms that this machine may be
#                                changed and thrown away afterwards
#   IMPACT_TEST_BACKING_DIR=DIR  a folder on ext4, xfs or btrfs; needed when
#                                /mnt lies on another kind of file system
#                                (for example in a copy-on-write test view)
#
# What it changes on the system
#   Everything the commands change (see their --help), plus: the stand-in
#   administrator "tadmin" with a sudo rule, the accounts alice-example and
#   bob-example, the test disks /mnt/disk_a and /mnt/disk_b, an SSH server on
#   127.0.0.1 when none runs, two small web servers during the tunnel step,
#   and, with Docker, one container named impact-scenario-bob.
#
# How to undo
#   At its end (without --keep) the scenario removes all of it again with
#   the clean-up of the system tests. After an aborted run, run the scenario
#   again (it cleans up first) or throw the disposable machine away.
#
# Exit codes
#   0 every step passed (skipped steps are allowed); 1 at least one step
#   failed, or the preconditions are not met; 2 wrong usage.
#
# Output
#   PASS  scenario :: <step>
#   FAIL  scenario :: <step>    followed by the output of the step
#   SKIP  scenario :: <step>    with the reason
#   SUMMARY scenario: <n> steps, <n> passed, <n> failed, <n> skipped
#   When a step that later steps build on fails, the later steps are
#   reported as FAIL with the note "not run".
# =============================================================================

# -----------------------------------------------------------------------------
# Reading help: bash constructs that appear in this file
#   NAME=text            store a text in the variable NAME; "$NAME" reads it
#   local NAME           a variable that exists only inside one function
#   "$1" "$2" "$@" "$#"  first parameter, second parameter, all parameters,
#                        number of parameters
#   "${NAME:-text}"      the value of NAME, or "text" when NAME is unset or empty
#   $( command )         the text that the command prints
#   [[ ... ]]            a test: -f plain file, -d folder, -L symbolic link,
#                        -e exists, -r readable, -x executable, -z empty text,
#                        -n text with content, == equal, != different,
#                        =~ matches a pattern
#   (( ... ))            arithmetic: true when the result is not zero
#   A && B               run B only when A succeeded
#   A || B               run B only when A failed
#   ! command            true when the command fails
#   if / case / for / while   branches and loops; "case" compares one value
#                        with several patterns
#   >file >>file <file   write to a file (replace it / add to its end), read
#                        from a file
#   2>/dev/null  >&2     throw error messages away / write to the error channel
#   command1 | command2  hand the output of command1 to command2
#   return N / exit N    end the function / the script with status N; 0 means
#                        success
#   list=(a b)  "${list[@]}"  "${#list[@]}"   a list, all its entries, their number
#   command &            start a command in the background; "$!" is its
#                        process number
#   ( ... )              run the commands inside in a copy of the script: a
#                        step that fails ends only its copy
#   $'\t'  $'\r'  $'\n'   a text with a special character: tab, carriage return,
#                        new line (\xNN is the byte NN)
#   command || true      accept a failure of this command ("set -e" would
#                        otherwise stop the script there)
#   2>&1                 send the error channel to the same place as the output
# Constructs beyond these are explained where they are first used.
# -----------------------------------------------------------------------------

# The lines for the checking tool "shellcheck" stand before the first
# command of the file and therefore count for the whole file.
# shellcheck disable=SC2317
# Reason for SC2317 (command appears unreachable): the steps test_* are
# started by their names from the list STEPS at the end of the file, and the
# helpers are used by those steps. shellcheck cannot follow such calls.

# "set -e" stops the script at the first command that fails, "-u" stops it
# when a variable is read that was never set, and "-o pipefail" makes a chain
# of commands joined with "|" fail when any part of it fails.
set -euo pipefail

# The helpers of the system tests: assertions, run_cmd, snapshots, test
# accounts, the SSH server and logins.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/testlib.sh"

# -----------------------------------------------------------------------------
# Options
# -----------------------------------------------------------------------------

# show_help
#   Prints the comment block at the top of this file.
show_help() {
    sed -n '2,/^# =\{10,\}$/p' -- "${BASH_SOURCE[0]}" | sed -e '1d' -e '$d' -e 's/^# \{0,1\}//'
}

SOURCE_FOLDER="$WORKSTATION_DIR"
KEEP=0
VERBOSE=0
while (($# > 0)); do
    case "$1" in
        --help)
            show_help
            exit 0
            ;;
        --from)
            if (($# < 2)); then
                echo "ERROR: --from needs a folder." >&2
                exit 2
            fi
            SOURCE_FOLDER="$(cd -- "$2" 2>/dev/null && pwd -P)" || {
                echo "ERROR: the folder '$2' does not exist." >&2
                exit 2
            }
            shift 2
            ;;
        --keep)
            KEEP=1
            shift
            ;;
        --verbose)
            VERBOSE=1
            shift
            ;;
        *)
            echo "ERROR: unknown argument '$1'. See: bash $0 --help" >&2
            exit 2
            ;;
    esac
done
if [[ ! -f "$SOURCE_FOLDER/install.sh" || ! -f "$SOURCE_FOLDER/bin/impact-check" ]]; then
    echo "ERROR: $SOURCE_FOLDER holds no unpacked IMPACT commands (install.sh, bin/impact-check)." >&2
    exit 2
fi

# -----------------------------------------------------------------------------
# Preconditions: the same as for the system tests
# -----------------------------------------------------------------------------
if [[ "${IMPACT_TEST_DISPOSABLE:-}" != 'yes' ]]; then
    echo "REFUSED: the scenario creates accounts, groups and SSH rules on this machine." >&2
    echo "         Run it on a disposable system only, and confirm that with IMPACT_TEST_DISPOSABLE=yes." >&2
    exit 1
fi
if ((EUID != 0)); then
    echo "REFUSED: the scenario needs root rights (on a disposable system)." >&2
    exit 1
fi
if [[ -e /etc/impact/impact.conf || -L /etc/impact/impact.conf ]]; then
    echo "REFUSED: /etc/impact/impact.conf exists. This machine is in use, or an earlier run was kept (--keep)." >&2
    echo "         Use a fresh disposable system, or remove the state of the kept run first." >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Names of the scenario (neutral examples)
# -----------------------------------------------------------------------------
ALICE='alice-example'                     # GitHub name and account of the first colleague
BOB='bob-example'                         # the second colleague
MODEL='Example-Model'
MODEL_URL='git@github.com:example-org/Example-Model.git'
STORAGE_NAME='Example'
STORAGE="$SYS_ROOT_A/$STORAGE_NAME"       # the model's folder on the first storage root
EXTRAS="/srv/impact/models/$MODEL/extras"
EXTRA_FILE='inputs/small_table.csv'       # one extra file that is not on GitHub
CONTAINER='impact-scenario-bob'           # the Docker container of the second colleague
BIN=/usr/local/bin
# The places that impact-check must leave unchanged. Large folders of the
# machine itself (for example /opt on a GitHub runner) stay out, because a
# snapshot of them would take long.
WATCHED=(/etc/impact /etc/ssh /opt/impact /srv /usr/local/bin /mnt/disk_a /mnt/disk_b)

# Files that the steps hand to each other lie in one folder (the steps run
# in copies of the script, so a variable set in one step is lost).
TEST_SUITE_TMP="$(mktemp -d /tmp/impact-scenario.XXXXXXXXXX)"
# The test accounts must be able to enter it (their key copies come from
# here, the stand-in for GitHub lies here).
chmod 755 "$TEST_SUITE_TMP"
export TEST_SUITE_TMP
GIT_BASE="$TEST_SUITE_TMP/git"

# -----------------------------------------------------------------------------
# Small helpers
# -----------------------------------------------------------------------------

# admin COMMAND...
#   Runs a command the way the administrator does, with sudo from the
#   stand-in administration account.
admin() {
    sys_as_admin "$@"
}

# as_person ACCOUNT COMMAND...
#   Runs a command as a colleague, with the environment of a login: HOME,
#   USER and a plain PATH. The groups of the account apply.
as_person() {
    local account="$1"
    shift
    (cd / && runuser -u "$account" -- env -i HOME="/home/$account" USER="$account" \
        LOGNAME="$account" SHELL=/bin/bash PATH=/usr/local/bin:/usr/bin:/bin "$@")
}

# fingerprint_of NAME
#   Prints the fingerprint (SHA256:...) of the test key NAME.
fingerprint_of() {
    ssh-keygen -l -E sha256 -f "$(sys_key_path "$1").pub" | awk '{ print $2 }'
}

# docker_answers
#   Result: success when a real Docker daemon answers. A stand-in docker of
#   the system tests in /usr/local/sbin does not count.
docker_answers() {
    [[ ! -f /usr/local/sbin/docker ]] && command -v docker >/dev/null 2>&1 &&
        timeout 20 docker version >/dev/null 2>&1
}

# assert_check_block NUMBER RESULT...
#   Fails unless the result line of block NUMBER in the last impact-check
#   output (RUN_OUTPUT) names one of the given results.
assert_check_block() {
    local number="$1" line
    shift
    line="$(printf '%s\n' "$RUN_OUTPUT" | grep -E "^  Result of block $number: " || true)"
    local result
    for result in "$@"; do
        if [[ "$line" == "  Result of block $number: $result" ]]; then
            return 0
        fi
    done
    show_run
    fail "block $number of impact-check: expected $*, found '${line:-no result line}'"
}

# -----------------------------------------------------------------------------
# The steps, in the order of the administrator's walk-through
# -----------------------------------------------------------------------------

# Step: a clean machine with a stand-in administrator, test disks and an SSH
# server. The effective SSH settings of the administrator and of root are
# recorded before anything of IMPACT exists.
test_prepare_the_machine() {
    sys_clean_slate
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    sys_storage_up
    sys_admin_create
    sys_sshd_start
    sys_effective_ssh "$SYS_ADMIN" >"$TEST_SUITE_TMP/admin-ssh-before"
    sys_effective_ssh root >"$TEST_SUITE_TMP/root-ssh-before"
    assert_success test -s "$TEST_SUITE_TMP/admin-ssh-before"
}

# Step: the first step of the walk-through. The health check runs from the
# unpacked folder on the untouched machine, reports all 15 blocks, ends with
# FAIL (nothing is set up) and changes nothing.
test_health_check_on_the_untouched_machine() {
    snapshot_unchanged_by "${WATCHED[@]}" -- admin "$SOURCE_FOLDER/bin/impact-check"
    assert_status 2
    assert_eq 15 "$(printf '%s\n' "$RUN_OUTPUT" | grep -c -E '^  Result of block [0-9]+: (OK|WARN|FAIL)$')" "number of block results"
    assert_check_block 4 FAIL
    assert_output_contains 'The settings file /etc/impact/impact.conf does not exist'
    assert_output_contains 'Overall result: FAIL (exit code 2).'
}

# Step: installation. The dry run changes nothing; the real run installs the
# commands and the links; a second run has nothing to do.
test_install_the_commands() {
    snapshot_unchanged_by /opt/impact /usr/local/bin -- admin "$SOURCE_FOLDER/install.sh" --dry-run
    assert_status 0
    run_cmd admin "$SOURCE_FOLDER/install.sh"
    assert_status 0
    assert_output_contains 'What changed:'
    assert_file_facts /opt/impact/admin 700 root root
    assert_eq "/opt/impact/bin/impact-check" "$(readlink -- "$BIN/impact-check")" "link of impact-check"
    local command_count
    command_count="$(find "$SOURCE_FOLDER/bin" -maxdepth 1 -type f -name 'impact-*' | wc -l)"
    assert_eq "$command_count" "$(find "$BIN" -maxdepth 1 -type l -name 'impact-*' | wc -l)" "number of command links"
    run_cmd admin "$SOURCE_FOLDER/install.sh"
    assert_status 0
    assert_output_contains 'Nothing to do'
}

# Step: impact-workstation-setup, first as a dry run (nothing changes), then
# for real; a second run has nothing to do.
test_set_up_the_workstation() {
    local -a options=(--shared-roots "$SYS_ROOT_A,$SYS_ROOT_B" --admin-contact "$SYS_ADMIN_CONTACT" --min-free-gb 1)
    snapshot_unchanged_by /etc/impact /etc/ssh /opt/impact /srv /mnt/disk_a /mnt/disk_b -- \
        admin "$BIN/impact-workstation-setup" "${options[@]}" --dry-run
    assert_status 0
    assert_missing /etc/impact/impact.conf
    run_cmd admin "$BIN/impact-workstation-setup" "${options[@]}"
    assert_status 0
    assert_output_contains 'keep this session open'
    assert_file_facts /etc/impact/impact.conf 644 root root
    assert_file_facts /etc/ssh/sshd_config.d/60-impact.conf 644 root root
    assert_file_contains /etc/ssh/sshd_config.d/60-impact.conf 'PermitOpen 127.0.0.1:8787 '
    run_cmd admin "$BIN/impact-workstation-setup"
    assert_status 0
    assert_output_contains 'Nothing to do'
}

# Step: the SSH rules apply to the group only. The administrator and root
# get exactly the effective settings they had before the setup.
test_administrator_ssh_settings_are_unchanged() {
    sys_effective_ssh "$SYS_ADMIN" >"$TEST_TMP/admin-after"
    sys_effective_ssh root >"$TEST_TMP/root-after"
    if ! cmp -s "$TEST_SUITE_TMP/admin-ssh-before" "$TEST_TMP/admin-after"; then
        diff -- "$TEST_SUITE_TMP/admin-ssh-before" "$TEST_TMP/admin-after" >&2 || true
        fail "the effective SSH settings of the administrator changed"
    fi
    if ! cmp -s "$TEST_SUITE_TMP/root-ssh-before" "$TEST_TMP/root-after"; then
        diff -- "$TEST_SUITE_TMP/root-ssh-before" "$TEST_TMP/root-after" >&2 || true
        fail "the effective SSH settings of root changed"
    fi
}

# Step: one model. A local repository stands in for GitHub; the model is
# registered with its GitHub address, gets one extra file, and
# impact-check-model finds nothing wrong.
test_register_a_model() {
    local work="$TEST_SUITE_TMP/work"
    # root's git must not read settings of the machine or of root.
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git init -q -b main "$work"
    mkdir -p "$work/docker_setup" "$work/inputs"
    printf 'Example model\n' >"$work/README.md"
    printf 'FROM example:1\n' >"$work/docker_setup/Dockerfile"
    printf 'tracked\n' >"$work/inputs/tracked.csv"
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$work" add -A
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$work" \
        -c user.name='Test Example' -c user.email='test@example.org' commit -q -m 'first state'
    mkdir -p "$GIT_BASE/example-org"
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git clone -q --bare "$work" "$GIT_BASE/example-org/Example-Model.git"
    chmod -R a+rX "$GIT_BASE"

    run_cmd admin "$BIN/impact-add-model" "$MODEL" "$MODEL_URL" --storage "$SYS_ROOT_A" --storage-name "$STORAGE_NAME"
    assert_status 0
    assert_file_facts "/srv/impact/models/$MODEL/model.conf" 640 root "$SYS_GROUP"
    assert_exists "$STORAGE/outputs"
    assert_exists "$STORAGE/inputs/synthpop"
    # The extra file: root owns it, the group may read it.
    install -d -m 2750 -o root -g "$SYS_GROUP" "$EXTRAS/inputs"
    printf 'a,b\n1,2\n' >"$EXTRAS/$EXTRA_FILE"
    chown root:"$SYS_GROUP" "$EXTRAS/$EXTRA_FILE"
    chmod 640 "$EXTRAS/$EXTRA_FILE"
    run_cmd admin "$BIN/impact-check-model" "$MODEL"
    assert_status 0
    assert_output_contains 'Failed checks: 0.'
}

# Step: two colleagues, each with the key of the PC and the fingerprint they
# sent. impact-add-user confirms the restricted SSH values itself.
test_enrol_two_colleagues() {
    local person
    for person in "$ALICE" "$BOB"; do
        sys_register_account "$person"
        sys_keypair "$person"
        run_cmd admin "$BIN/impact-add-user" "$person" --key-file "$(sys_key_path "$person").pub" \
            --fingerprint "$(fingerprint_of "$person")"
        assert_status 0
        assert_output_contains "'$person' gets the restricted values of the group '$SYS_GROUP'"
        assert_eq L "$(passwd -S "$person" | awk '{ print $2 }')" "password state of $person"
    done
}

# Step: both colleagues log in with their key.
test_key_login_works() {
    local person
    for person in "$ALICE" "$BOB"; do
        run_cmd sys_ssh_key "$person" "$person" id -un
        assert_status 0
        assert_eq "$person" "$RUN_OUTPUT" "key login of $person"
    done
}

# Step: a member cannot log in with a password, even when the account has
# one: the server offers only key login.
test_password_login_is_refused_for_a_member() {
    sys_set_password "$ALICE" 'Scenario-Pass-47'
    assert_eq 'publickey' "$(sys_ssh_offered_methods "$ALICE")" "login methods offered to a member"
    run_cmd sys_ssh_password "$ALICE" 'Scenario-Pass-47' id -un
    local status="$RUN_STATUS" output="$RUN_OUTPUT"
    # Lock the password again, as impact-add-user left it.
    passwd --lock -- "$ALICE" >/dev/null
    RUN_STATUS="$status"
    RUN_OUTPUT="$output"
    assert_status 255
    assert_output_contains 'Permission denied'
}

# Step: a tunnel to a port of the range answers; a tunnel to a port outside
# the range gets nothing.
test_tunnel_to_the_port_range_only() {
    if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        skip "python3 and curl are needed for the small web servers of this step"
    fi
    mkdir -p "$TEST_TMP/www"
    printf 'inside the range\n' >"$TEST_TMP/www/index.html"
    python3 -m http.server 8787 --bind 127.0.0.1 --directory "$TEST_TMP/www" >/dev/null 2>&1 &
    local inside_pid=$!
    python3 -m http.server 8999 --bind 127.0.0.1 --directory "$TEST_TMP/www" >/dev/null 2>&1 &
    local outside_pid=$!
    local -a SYS_SSH_OPTIONS=()
    sys__ssh_options
    # -N: no command, forwarding only. -L: a port on this side that leads to
    # an address and port on the workstation.
    ssh "${SYS_SSH_OPTIONS[@]}" -N -T -o BatchMode=yes -o IdentitiesOnly=yes \
        -i "$(sys_key_path "$ALICE")" -L 127.0.0.1:18787:127.0.0.1:8787 -L 127.0.0.1:18999:127.0.0.1:8999 \
        "$ALICE@127.0.0.1" </dev/null >/dev/null 2>&1 &
    local tunnel_pid=$!
    sleep 2
    local allowed refused
    allowed="$(curl --noproxy '*' --silent --max-time 5 http://127.0.0.1:18787/ || true)"
    refused="$(curl --noproxy '*' --silent --max-time 5 http://127.0.0.1:18999/ || true)"
    kill "$tunnel_pid" "$inside_pid" "$outside_pid" 2>/dev/null || true
    assert_eq 'inside the range' "$allowed" "answer through the tunnel to a port of the range"
    assert_eq '' "$refused" "a tunnel to a port outside the range must be refused"
}

# Step: the first colleague makes a working copy with impact-get-repo. git's
# setting url.<base>.insteadOf (in the person's own git settings, a part of
# the test only) leads the GitHub address to the local stand-in. The extra
# file arrives and git ignores it.
test_first_colleague_gets_a_working_copy() {
    local person home copy
    for person in "$ALICE" "$BOB"; do
        home="/home/$person"
        as_person "$person" git config --file "$home/.gitconfig" url."file://$GIT_BASE/".insteadOf 'git@github.com:'
        as_person "$person" git config --file "$home/.gitconfig" --add url."file://$GIT_BASE/".insteadOf 'https://github.com/'
        # The stand-in repository belongs to root; git reads a repository of
        # another account only with this setting. On GitHub it is not needed.
        as_person "$person" git config --file "$home/.gitconfig" safe.directory '*'
    done
    # The key copy that the GUI places for git at the first REMOTE start.
    install -m 600 -o "$ALICE" -g "$ALICE" "$(sys_key_path "$ALICE")" "/home/$ALICE/.ssh/id_ed25519_$ALICE"
    copy="/home/$ALICE/Repositories/$MODEL"
    run_cmd as_person "$ALICE" "$BIN/impact-get-repo" "$MODEL"
    assert_status 0
    assert_eq "IMPACT_RESULT status=ok code=0 path=$copy reason=cloned" "$(printf '%s\n' "$RUN_OUTPUT" | tail -n 1)" "last line"
    assert_exists "$copy/$EXTRA_FILE"
    assert_eq "$copy/$EXTRA_FILE" "$(as_person "$ALICE" git -C "$copy" check-ignore -- "$copy/$EXTRA_FILE")" "git ignores the extra"
    assert_eq '' "$(as_person "$ALICE" git -C "$copy" status --porcelain)" "git status of the new copy"
    assert_eq "$ALICE" "$(stat -c '%U' -- "$copy")" "owner of the copy"
    # A second attempt never touches the copy.
    run_cmd as_person "$ALICE" "$BIN/impact-get-repo" "$MODEL"
    assert_status 4
    assert_output_contains 'reason=exists'
}

# Step: the administrator makes the copy for the second colleague, who has
# no key copy yet: impact-give-repo takes anonymous HTTPS and sets the SSH
# address afterwards.
test_administrator_gives_a_working_copy() {
    local copy="/home/$BOB/Repositories/$MODEL"
    run_cmd admin "$BIN/impact-give-repo" "$BOB" "$MODEL"
    assert_status 0
    assert_output_contains 'over anonymous HTTPS'
    assert_eq "$MODEL_URL" "$(as_person "$BOB" git -C "$copy" config --get remote.origin.url)" "address of the copy"
    assert_eq "$BOB" "$(stat -c '%U' -- "$copy")" "owner of the copy"
}

# Step: shared storage. Two colleagues with the strict umask 077 work in the
# same output folder. Old content from before the shared rules is converted
# with impact-share-folder (dry run first), after which both can write it.
test_shared_storage_with_two_colleagues() {
    local run="$STORAGE/outputs/run1"
    # "umask 077" gives new files no rights for the group or others, the
    # strictest default an account can have.
    as_person "$ALICE" bash -c "umask 077 && mkdir -- '$run' && printf 'alice\n' >'$run/result.csv'"
    as_person "$BOB" bash -c "umask 077 && printf 'bob\n' >>'$run/result.csv' && printf 'x\n' >'$run/bob.csv'"
    as_person "$ALICE" rm -- "$run/bob.csv"
    assert_eq $'alice\nbob' "$(cat -- "$run/result.csv")" "content written by both"
    assert_missing "$run/bob.csv"

    # Old content: a folder and a file of another account with ordinary
    # rights, as files of the shared account of version 2.0 are.
    local old="$STORAGE/inputs/synthpop/old"
    install -d -m 755 -o "$SYS_ADMIN" -g "$SYS_ADMIN" "$old"
    printf 'old\n' >"$old/part.csv"
    chown "$SYS_ADMIN:$SYS_ADMIN" "$old/part.csv"
    # No access lists and no setgid, as on a disk from before the rules.
    # "setfacl -b" removes every extra access entry.
    setfacl -b -- "$old" "$old/part.csv"
    chmod g-s -- "$old"
    chmod 644 -- "$old/part.csv"
    run_cmd as_person "$BOB" bash -c "printf 'new\n' >>'$old/part.csv'"
    assert_status 1
    snapshot_unchanged_by /mnt/disk_a /opt/impact/admin/acl-backups -- admin "$BIN/impact-share-folder" "$STORAGE/inputs/synthpop" --dry-run
    assert_status 0
    run_cmd admin "$BIN/impact-share-folder" "$STORAGE/inputs/synthpop"
    assert_status 0
    assert_output_contains 'sudo impact-share-folder --restore'
    as_person "$BOB" bash -c "umask 077 && printf 'new\n' >>'$old/part.csv' && printf 'y\n' >'$old/bob.csv'"
    as_person "$ALICE" bash -c "printf 'more\n' >>'$old/bob.csv'"
    assert_eq $'old\nnew' "$(cat -- "$old/part.csv")" "the converted file is group-writable"
    run_cmd admin "$BIN/impact-share-folder" "$STORAGE/inputs/synthpop"
    assert_status 0
    assert_output_contains 'Nothing to do'
}

# Step (Docker): a colleague uses Docker through the SSH login, as the GUI
# does, and has a running container with the label of the account.
test_docker_through_the_ssh_login() {
    if ! docker_answers; then
        skip "no Docker daemon answers on this machine"
    fi
    run_cmd sys_ssh_key "$ALICE" "$ALICE" docker version --format '{{.Server.Version}}'
    assert_status 0
    assert_matches "$RUN_OUTPUT" '^[0-9]+\.[0-9]+' "Docker version through the login of $ALICE"
    local image
    image="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>' | head -n 1)" || image=''
    if [[ -z "$image" ]]; then
        # A fresh machine with internet access: a small public image, from
        # the public mirror of Docker's official images (it has no limit
        # for pulls without an account).
        if timeout 180 docker pull --quiet public.ecr.aws/docker/library/busybox:1.36 >/dev/null 2>&1; then
            image='public.ecr.aws/docker/library/busybox:1.36'
        fi
    fi
    if [[ -z "$image" ]]; then
        skip "the Docker daemon has no image to start a test container from"
    fi
    docker run -d --name "$CONTAINER" --label "impact.account=$BOB" -p 127.0.0.1:8790:8787 "$image" sleep 100000 >/dev/null
    assert_eq running "$(docker inspect --format '{{.State.Status}}' "$CONTAINER")" "state of the container"
    : >"$TEST_SUITE_TMP/container-started"
}

# Step: the health check on the set-up machine: a complete report, the
# blocks about settings, SSH rules and groups are OK, and no block about the
# setup itself fails. No key material appears.
test_health_check_on_the_set_up_machine() {
    snapshot_unchanged_by --content "${WATCHED[@]}" -- admin "$BIN/impact-check"
    assert_eq 15 "$(printf '%s\n' "$RUN_OUTPUT" | grep -c -E '^  Result of block [0-9]+: (OK|WARN|FAIL)$')" "number of block results"
    assert_check_block 4 OK
    assert_check_block 5 OK
    assert_output_contains '2 of 2 members get the restricted SSH settings'
    assert_check_block 6 OK
    local block
    for block in 7 8 9 10; do
        assert_check_block "$block" OK WARN
    done
    if [[ -e "$TEST_SUITE_TMP/container-started" ]]; then
        assert_output_contains "$CONTAINER"
    fi
    assert_output_not_contains 'PRIVATE KEY'
    # The exit code follows the worst block: 0, 1 or 2.
    if ((RUN_STATUS > 2)); then
        show_run
        fail "impact-check ended with exit code $RUN_STATUS"
    fi
}

# Step: the second colleague leaves. The login is refused afterwards, the
# container of the person is stopped, and the first colleague still logs in.
test_remove_a_colleague() {
    # With Docker installed and its daemon silent, the command does every
    # other step and ends with exit code 1, so that it is run again later
    # for the containers.
    local expected=0
    if ! docker_answers && command -v docker >/dev/null 2>&1; then
        expected=1
    fi
    run_cmd admin "$BIN/impact-remove-user" "$BOB" --yes
    assert_status "$expected"
    if ((expected == 1)); then
        assert_output_contains 'Docker does not answer'
    fi
    assert_output_contains 'How to bring the person back'
    run_cmd sys_ssh_key "$BOB" "$BOB" id -un
    assert_status 255
    run_cmd sys_ssh_key "$ALICE" "$ALICE" id -un
    assert_status 0
    if [[ -e "$TEST_SUITE_TMP/container-started" ]]; then
        assert_eq exited "$(docker inspect --format '{{.State.Status}}' "$CONTAINER")" "state of the container of $BOB"
    fi
    # The account stays, closed, with its number.
    assert_success getent passwd "$BOB"
    run_cmd admin "$BIN/impact-remove-user" "$BOB" --yes
    assert_status "$expected"
    assert_output_contains 'Nothing to do'
}

# Step: the backup archive. It is secret (mode 600) and the output says so.
test_export_the_state() {
    run_cmd admin "$BIN/impact-export-state"
    assert_status 0
    assert_output_contains 'the archive is secret'
    local archive
    archive="$(find /opt/impact/admin/state -maxdepth 1 -name 'impact-state-*.tar.gz' | head -n 1)"
    [[ -n "$archive" ]] || fail "no archive in /opt/impact/admin/state"
    assert_file_facts "$archive" 600 root root
    assert_contains "$(tar --list --gzip --file="$archive")" 'CONTENTS.txt' "content of the archive"
    run_cmd admin "$BIN/impact-export-state"
    assert_status 0
    assert_output_contains 'already holds exactly this content'
}

# Step: removing the commands. The commands and their links go; the
# settings, the SSH rules and the accounts stay, and the output names them.
test_uninstall_the_commands() {
    snapshot_unchanged_by /opt/impact /usr/local/bin -- admin /opt/impact/uninstall.sh --dry-run
    assert_status 0
    run_cmd admin /opt/impact/uninstall.sh
    assert_status 0
    assert_missing /opt/impact/bin
    assert_missing "$BIN/impact-check"
    assert_exists /etc/impact/impact.conf
    assert_exists /etc/ssh/sshd_config.d/60-impact.conf
    assert_output_contains 'sudo impact-workstation-setup --remove-ssh-rules'
    assert_success getent passwd "$ALICE"
}

# The steps in their order. A step marked with "!" prepares what all later
# steps need: when it fails, the later steps are not run.
STEPS=(
    '!test_prepare_the_machine'
    'test_health_check_on_the_untouched_machine'
    '!test_install_the_commands'
    '!test_set_up_the_workstation'
    'test_administrator_ssh_settings_are_unchanged'
    '!test_register_a_model'
    '!test_enrol_two_colleagues'
    'test_key_login_works'
    'test_password_login_is_refused_for_a_member'
    'test_tunnel_to_the_port_range_only'
    'test_first_colleague_gets_a_working_copy'
    'test_administrator_gives_a_working_copy'
    'test_shared_storage_with_two_colleagues'
    'test_docker_through_the_ssh_login'
    'test_health_check_on_the_set_up_machine'
    'test_remove_a_colleague'
    'test_export_the_state'
    'test_uninstall_the_commands'
)

# -----------------------------------------------------------------------------
# Running the steps
# -----------------------------------------------------------------------------

# clean_up
#   Removes everything the scenario created (not with --keep). Runs at the
#   end, also after Ctrl+C.
clean_up() {
    if ((KEEP == 0)); then
        docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
        (sys_clean_slate) >/dev/null 2>&1 || echo "WARNING: the clean-up did not finish; throw the machine away." >&2
    else
        echo "The state was kept (--keep). The next run of the scenario cleans up first."
    fi
    rm -rf -- "$TEST_SUITE_TMP"
}
# "trap" runs clean_up when the script ends, for whatever reason.
trap clean_up EXIT

PASSED=0
FAILED=0
SKIPPED=0
BLOCKED=''          # the essential step that failed, if any
OUTPUT_FILE="$TEST_SUITE_TMP/.output"
echo "Scenario: installing from $SOURCE_FOLDER"
for entry in "${STEPS[@]}"; do
    name="${entry#!}"
    if [[ -n "$BLOCKED" ]]; then
        FAILED=$((FAILED + 1))
        printf 'FAIL  scenario :: %s (not run, because %s failed)\n' "$name" "$BLOCKED"
        continue
    fi
    TEST_TMP="$(mktemp -d "$TEST_SUITE_TMP/step.XXXXXXXXXX")"
    chmod 755 "$TEST_TMP"
    export TEST_TMP
    status=0
    # Each step runs in a copy of the script with "set -e" switched on, so
    # a failed check ends only that step.
    (
        set -euo pipefail
        "$name"
    ) >"$OUTPUT_FILE" 2>&1 </dev/null || status=$?
    case "$status" in
        0)
            PASSED=$((PASSED + 1))
            printf 'PASS  scenario :: %s\n' "$name"
            if ((VERBOSE == 1)); then
                sed -e 's/^/      | /' -- "$OUTPUT_FILE"
            fi
            ;;
        77)
            SKIPPED=$((SKIPPED + 1))
            printf 'SKIP  scenario :: %s (%s)\n' "$name" "$(grep -m 1 '^SKIP: ' "$OUTPUT_FILE" | cut -c7-)"
            ;;
        *)
            FAILED=$((FAILED + 1))
            printf 'FAIL  scenario :: %s\n' "$name"
            sed -e 's/^/      | /' -- "$OUTPUT_FILE"
            if [[ "$entry" == '!'* ]]; then
                BLOCKED="$name"
            fi
            ;;
    esac
done

printf 'SUMMARY scenario: %d steps, %d passed, %d failed, %d skipped\n' \
    "$((PASSED + FAILED + SKIPPED))" "$PASSED" "$FAILED" "$SKIPPED"
if ((FAILED > 0)); then
    exit 1
fi
exit 0
