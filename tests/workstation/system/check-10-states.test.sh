#!/bin/bash
# =============================================================================
# check-10-states.test.sh: system tests for impact-check on an untouched, a
# half set-up and a fully set-up machine
#
# Purpose
#   Runs the real impact-check as root and through the sudo of the stand-in
#   administrator, and checks:
#     - every report is complete: 15 blocks, each with exactly one result
#       (OK, WARN or FAIL) that matches its lines, "What to do" for every
#       WARN and FAIL, a summary, and the exit code 0, 1 or 2 that belongs
#       to the results;
#     - the check changes nothing: a snapshot of accounts, groups and the
#       folders /etc, /opt, /srv, /usr/local, /home and the storage, with
#       owners, modes, ACLs and file contents, is the same before and after
#       (also the index files of the git working copies);
#     - a second run gives the same report;
#     - wrong and hostile input is refused before anything is looked at;
#     - on an untouched machine (nothing installed, no settings), a half
#       set-up one (installed and set up, no people, no models) and a fully
#       set-up one (members, a removed account, a model with extras and
#       storage folders, a working copy, listeners on the port range), each
#       block reports what the fixture holds;
#     - hostile state (names with blanks, quotes, "$( )" and line breaks;
#       symbolic links where folders are expected) is reported and never
#       followed;
#     - no secret appears in the output (no key material, no password
#       hash), and --mask hides addresses and host names.
#   Docker: a stand-in program "docker" answers with fixed container,
#   image and volume lists in the form of the check's own Docker templates.
#   It proves the parsing and the rules of blocks 2 and 11 to 15. The real
#   Docker daemon is covered by check-20-docker.test.sh.
#
# Who runs it
#   tests/workstation/run-tests.sh system   (root, disposable system only,
#   in a private network: it starts an SSH server and listeners on
#   127.0.0.1, and gives the loopback device one example address).
#
# Usage
#   sudo env IMPACT_TEST_DISPOSABLE=yes IMPACT_TEST_BACKING_DIR=<folder on ext4> \
#       bash tests/workstation/run-tests.sh system --filter check-10
#
# What it changes on the system
#   The installed commands, the group impact, /etc/impact, /srv/impact,
#   /opt/impact, the SSH rules file, four test accounts, the storage roots
#   below /mnt/disk_a and /mnt/disk_b, an SSH server and two listening test
#   programs, a stand-in docker in /usr/local/sbin, the host name and the
#   address 192.0.2.10 on the loopback device (of a private view).
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
# Reason for SC2016 (no expansion in single quotes): many texts in this file
# are test data or lines of small scripts that must stay exactly as written.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/testlib.sh"

CHECK=/usr/local/bin/impact-check
CONF=/etc/impact/impact.conf
RULES=/etc/ssh/sshd_config.d/60-impact.conf
MODEL='Example-Model'
MODEL_URL='git@github.com:alice-example/Example-Model.git'
ALICE='alice-example'
BOB='bob-example'
CAROL='carol-example'
DAVE='dave-example'
BOB_PASSWORD='Bob-Test-Pass-58'
FAKE_DOCKER=/usr/local/sbin/docker
FAKE_MARK='# impact-test stand-in for docker (check-10)'
TEST_HOST='ws-check-host'
# The folders whose state must not change: the places of brief section 5.2
# and the storage. /home/user and /home/ubuntu belong to the sandbox around
# the private view and are left out.
WATCHED=(/etc /opt/impact /srv /usr/local/bin /usr/local/sbin /home /mnt/disk_a /mnt/disk_b)
EXCLUDES=(--exclude /home/user --exclude /home/ubuntu --exclude /etc/ld.so.cache)

suite_setup() {
    sys_clean_slate
    remove_test_programs
    sys_storage_up
}

suite_teardown() {
    remove_test_programs
    sys_clean_slate
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# remove_test_programs
#   Ends the listening test programs and removes the stand-in docker, the
#   example address and the changed host name.
remove_test_programs() {
    local file pid
    for file in "$TEST_SUITE_TMP"/listener-*.pid; do
        [[ -f "$file" ]] || continue
        pid="$(cat -- "$file")"
        kill "$pid" 2>/dev/null || true
        rm -f -- "$file"
    done
    if [[ -f "$FAKE_DOCKER" ]] && grep -q -F -- "$FAKE_MARK" "$FAKE_DOCKER"; then
        rm -f -- "$FAKE_DOCKER"
    fi
    ip address del 192.0.2.10/32 dev lo 2>/dev/null || true
    if [[ -f "$TEST_SUITE_TMP/old-hostname" ]]; then
        hostname "$(cat -- "$TEST_SUITE_TMP/old-hostname")" 2>/dev/null || true
        rm -f -- "$TEST_SUITE_TMP/old-hostname"
    fi
    if [[ -f "$TEST_SUITE_TMP/hosts-saved" ]]; then
        cp -p -- "$TEST_SUITE_TMP/hosts-saved" /etc/hosts
        rm -f -- "$TEST_SUITE_TMP/hosts-saved"
    fi
}

# block_of NUMBER
#   Prints the lines of block NUMBER of the last report (RUN_OUTPUT), from
#   its heading to its result line.
block_of() {
    printf '%s\n' "$RUN_OUTPUT" | awk -v n="$1" '
        $0 == "Block " n ":" || index($0, "Block " n ": ") == 1 { inside = 1 }
        inside { print }
        inside && index($0, "  Result of block " n ": ") == 1 { exit }'
}

# assert_block NUMBER WORD
#   Fails unless block NUMBER of the last report ended with WORD.
assert_block() {
    local text
    text="$(block_of "$1")"
    if [[ "$text" != *"  Result of block $1: $2"* ]]; then
        show_run
        fail "block $1 should end with $2"
    fi
}

# assert_block_contains NUMBER PART
#   Fails unless block NUMBER of the last report contains PART.
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

# assert_complete_report
#   The rules every report must follow: 15 blocks; each ends with exactly
#   one result line; the result is FAIL when the block has a FAIL line, WARN
#   when it has a warning and no FAIL line, OK otherwise; WARN and FAIL come
#   with "What to do"; the summary lists the 15 results; the exit code is 2
#   with a FAIL, 1 with a WARN and no FAIL, 0 otherwise.
assert_complete_report() {
    local n count text expected worst=0 summary_line
    for n in $(seq 1 15); do
        count="$(printf '%s\n' "$RUN_OUTPUT" | grep -c -E "^  Result of block $n: (OK|WARN|FAIL)\$" || true)"
        if [[ "$count" != '1' ]]; then
            show_run
            fail "block $n has $count result lines; exactly one is expected"
        fi
        text="$(block_of "$n")"
        expected='OK'
        if printf '%s\n' "$text" | grep -q '^    FAIL: '; then
            expected='FAIL'
        elif printf '%s\n' "$text" | grep -q '^    WARNING: '; then
            expected='WARN'
        fi
        # The last line of the block is its result line.
        assert_eq "  Result of block $n: $expected" "$(printf '%s\n' "$text" | tail -n 1)" "result line of block $n"
        if [[ "$expected" != 'OK' ]]; then
            assert_contains "$text" $'\n  What to do:\n    - ' "what to do in block $n"
        else
            assert_not_contains "$text" '  What to do:' "block $n is OK"
        fi
        case "$expected" in
            FAIL) worst=2 ;;
            WARN) ((worst == 2)) || worst=1 ;;
            *) ;;
        esac
        summary_line="$(printf '%s\n' "$RUN_OUTPUT" | sed -n '/^Summary$/,$p' | grep -E "^ +$n  " || true)"
        assert_matches "$summary_line" " $expected\$" "summary line of block $n"
    done
    assert_output_contains '  15 blocks: '
    assert_status "$worst"
}

# run_check_unchanged [OPTIONS...]
#   Runs the installed impact-check through the stand-in administrator's
#   sudo, and fails when the snapshot of the watched folders, accounts and
#   groups (with file contents) differs before and after.
run_check_unchanged() {
    snapshot_unchanged_by --content "${EXCLUDES[@]}" "${WATCHED[@]}" -- sys_as_admin "$CHECK" "$@"
}

# start_listener ADDRESS PORT NAME
#   Starts a small program that listens on ADDRESS:PORT (python3, only for
#   the tests), and notes its process number.
start_listener() {
    python3 -c '
import socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((sys.argv[1], int(sys.argv[2])))
s.listen(5)
time.sleep(1800)
' "$1" "$2" >/dev/null 2>&1 &
    printf '%s\n' "$!" >"$TEST_SUITE_TMP/listener-$3.pid"
    local _
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        # The answer goes into a text first: "ss | grep -q" can fail under
        # "pipefail" when grep stops reading before ss has written everything.
        if [[ -n "$(ss -H -l -t -n "sport = :$2")" ]]; then
            return 0
        fi
        sleep 0.3
    done
    fail "the test listener on $1:$2 did not start"
}

# install_fake_docker
#   Puts the stand-in docker in front of the real one. It answers the
#   read-only questions of impact-check with fixed lists, in exactly the
#   form that the check's templates produce (one line per container with
#   tab-separated fields; see IMPACT_CHECK_CONTAINER_FORMAT).
install_fake_docker() {
    cat >"$FAKE_DOCKER" <<END
#!/bin/bash
$FAKE_MARK
END
    cat >>"$FAKE_DOCKER" <<'END'
tab=$'\t'
case "$1 ${2:-}" in
    'version --format')
        echo '29.10.0'
        ;;
    'info --format')
        case "$3" in
            *DockerRootDir*) echo '/var/lib/docker' ;;
            *) echo 'overlayfs|driver-type=io.containerd.snapshotter.v1;' ;;
        esac
        ;;
    'ps --all')
        if [[ "$3" == --quiet ]]; then
            printf '%s\n' c1 c2 c3 c4 c5 c6 c7
        elif [[ "$3" == --filter && "$4" == volume=impactncd_output_Example-Model_alice-example ]]; then
            echo 'impact-test-old'
        fi
        ;;
    'container inspect')
        # name, state, image, account label, L: label keys, P: ports.
        # Docker 29 prints a label that a container lacks as %!q(<nil>).
        printf '/Example-Model_alice-example\trunning\t"example-model:alice-example"\t"alice-example"\tL:"impact.access" "impact.account" \tP:127.0.0.1|8791|8787/tcp \n'
        printf '/Example-Model_bob-wide\trunning\t"example-model:bob-example"\t"bob-example"\tL:"impact.account" \tP:0.0.0.0|8792|8787/tcp ::|8792|8787/tcp \n'
        printf '/old-of-gone\texited\t"example-model:gone"\t"gone-account"\tL:"impact.account" \tP:127.0.0.1|8899|8787/tcp \n'
        printf '/data_preparation_1\trunning\t"prep:latest"\t%%!q(<nil>)\tL:\tP:0.0.0.0|8793|8787/tcp \n'
        printf '/impact-test-old\texited\t"example-model"\t%%!q(<nil>)\tL:"impact.repo_path" "impact.use_volumes" \tP:\n'
        printf '/impact-test-plain\trunning\t"some/tool"\t""\tL:"impact.test.other" \tP:192.0.2.10|8794|80/tcp \n'
        printf '/impact-test-hostile\tcreated\t"x\\"y"\t"bad\\nname; $(touch /tmp/pwned)"\tL:"impact.account" \tP:\n'
        ;;
    'image ls')
        printf '%s\n' sha256:aaa sha256:bbb sha256:ccc
        ;;
    'image inspect')
        printf '%s\n' '"alice-example" 1610612736' '"" 734003200' '"gone-account" 1073741824'
        ;;
    'system df')
        echo 'Images: 3.4GB (1.2GB reclaimable)'
        ;;
    'volume ls')
        printf '%s\n' impactncd_output_Example-Model_alice-example impactncd_germany_synthpop_bob_example results_output_2024 plainvolume
        ;;
    *)
        echo "stand-in docker: not answered: $*" >&2
        exit 1
        ;;
esac
END
    chmod 755 "$FAKE_DOCKER"
}

# make_member ACCOUNT GITHUB_NAME
#   An account as impact-add-user leaves it (brief section 6 and the notes
#   of the agent "users"): member of impact and docker, a locked password,
#   one ed25519 login key, an account record, the repository folder (750).
make_member() {
    local account="$1" github="$2"
    sys_account_add "$account" impact docker
    sys_keypair "$account"
    sys_install_key "$account" "$account"
    load_library
    impact_account_record_write "$account" "$github" enrolled || fail "record of $account"
    runuser -u "$account" -- mkdir -m 750 "/home/$account/Repositories"
}

# as_person ACCOUNT COMMAND...
#   Runs a command as the test person with a clean environment (git of the
#   person must not read root's settings).
as_person() {
    local account="$1"
    shift
    (cd / && runuser -u "$account" -- env -i HOME="/home/$account" PATH=/usr/bin:/bin LC_ALL=C \
        GIT_CONFIG_NOSYSTEM=1 "$@")
}

# -----------------------------------------------------------------------------
# Wrong input and the untouched machine
# -----------------------------------------------------------------------------

test_help_works_and_names_the_blocks() {
    run_cmd bash "$WORKSTATION_DIR/bin/impact-check" --help
    assert_status 0
    assert_output_contains 'impact-check: health check of the IMPACT workstation'
    assert_output_contains '15 Containers without IMPACT labels'
    assert_output_not_contains 'Reading help'
}

test_wrong_input_is_refused_before_anything_is_looked_at() {
    local value
    snapshot_unchanged_by --content "${EXCLUDES[@]}" "${WATCHED[@]}" -- bash "$WORKSTATION_DIR/bin/impact-check" --dry-run
    assert_status 2
    assert_output_contains "Unknown option '--dry-run'"
    assert_output_not_contains 'Block 1'
    run_cmd bash "$WORKSTATION_DIR/bin/impact-check" extra-argument
    assert_status 2
    assert_output_contains 'Too many arguments'
    run_cmd bash "$WORKSTATION_DIR/bin/impact-check" -m
    assert_status 2
    run_cmd bash "$WORKSTATION_DIR/bin/impact-check" --mask=yes
    assert_status 2
    assert_output_contains 'takes no value'
    run_cmd bash "$WORKSTATION_DIR/bin/impact-check" --shared-roots
    assert_status 2
    # Hostile values: blanks, ";", "$( )", quotes, "..", relative paths,
    # empty entries, a line break.
    for value in '/mnt/disk a' '/mnt/x;touch /tmp/impact-check-pwned' '$(touch /tmp/impact-check-pwned)' \
        "/mnt/it's" '/mnt/disk_a/../../etc' '../etc' 'mnt/disk_a' '/mnt/disk_a,' '' $'/mnt/a\n/mnt/b' '/mnt/disk_a/'; do
        run_cmd bash "$WORKSTATION_DIR/bin/impact-check" --shared-roots "$value"
        assert_status 2
        assert_output_not_contains 'Block 1'
    done
    assert_missing /tmp/impact-check-pwned
}

test_untouched_machine_gives_a_complete_report_and_changes_nothing() {
    # Nothing is installed or set up: the administrator runs the check from
    # the unpacked folder, as root.
    snapshot_unchanged_by --content "${EXCLUDES[@]}" "${WATCHED[@]}" -- bash "$WORKSTATION_DIR/bin/impact-check"
    assert_complete_report
    assert_status 2
    assert_block 1 WARN
    assert_block_contains 1 'The IMPACT commands are not installed in /opt/impact yet.'
    assert_block_contains 1 'sudo ./install.sh'
    assert_block 4 FAIL
    assert_block_contains 4 'The settings file /etc/impact/impact.conf does not exist'
    assert_block_contains 5 'does not exist yet; impact-workstation-setup writes it'
    assert_block_contains 6 "The group 'impact' does not exist yet"
    assert_block_contains 8 'The model folder /srv/impact/models does not exist yet'
    assert_block_contains 9 'no member yet'
    # The blocks that need the settings say that they use default values.
    assert_block_contains 6 'Without a usable settings file (block 4) this block works with default values'
    assert_output_contains 'Overall result: FAIL (exit code 2).'
}

test_candidate_storage_roots_are_looked_at_before_the_setup() {
    mkdir -p /mnt/disk_a/shared
    run_cmd bash "$WORKSTATION_DIR/bin/impact-check" --shared-roots /mnt/disk_a/shared,/mnt/disk_b/missing
    assert_complete_report
    assert_block_contains 3 'The storage root /mnt/disk_a/shared (/mnt/disk_a/shared, disk mounted at'
    assert_block_contains 3 'The storage root /mnt/disk_b/missing (given with --shared-roots) does not exist.'
    assert_block_contains 10 'Storage root /mnt/disk_a/shared: file system'
    assert_block_contains 10 'is not in SHARED_ROOTS; only its file system and its free space were checked'
    rmdir /mnt/disk_a/shared
}

# -----------------------------------------------------------------------------
# The half set-up machine: installed and set up, no people, no models
# -----------------------------------------------------------------------------

test_half_set_up_machine() {
    sys_install
    sys_admin_create
    sys_sshd_start
    # A small limit, so the free space of the test disks is in order.
    sys_setup --min-free-gb 1 --known-direct-containers 'data_preparation_*'
    run_check_unchanged
    assert_complete_report
    assert_block 1 OK
    assert_block_contains 1 'The IMPACT commands version 2.1.0 are installed in /opt/impact.'
    assert_block 3 OK
    assert_block 4 OK
    assert_block_contains 4 'SHARED_ROOTS=/mnt/disk_a/shared,/mnt/disk_b/shared'
    assert_block_contains 4 'holds GitHub'"'"'s three host keys'
    assert_block 5 OK
    assert_block_contains 5 'is exactly what impact-workstation-setup writes'
    assert_block_contains 5 "The SSH rules leave the login of 'tadmin' unchanged"
    assert_block_contains 5 "The SSH rules leave the login of 'root' unchanged"
    assert_block_contains 5 "The group 'impact' has no member yet"
    assert_block 6 OK
    assert_block 8 OK
    assert_block_contains 8 'No model is registered yet.'
    assert_block 9 OK
    assert_block 10 OK
    assert_block_contains 10 'No registered model uses /mnt/disk_a/shared yet.'
    if timeout 20 docker version >/dev/null 2>&1; then
        # Where a real daemon runs (check-20-docker.test.sh covers it).
        assert_block_contains 2 'OK: The Docker daemon answers'
    else
        # Without a Docker daemon the Docker blocks say so.
        assert_block 2 FAIL
        assert_block_contains 2 'The Docker daemon does not answer.'
        assert_block_contains 14 'The Docker daemon does not answer'
    fi
}

test_not_root_is_refused() {
    run_cmd runuser -u "$SYS_ADMIN" -- "$CHECK"
    assert_status 2
    assert_output_contains 'impact-check must run with administrator rights.'
    assert_output_not_contains 'Block 1'
}

# -----------------------------------------------------------------------------
# The fully set-up machine
# -----------------------------------------------------------------------------

test_build_the_full_fixture() {
    local dir="/srv/impact/models/$MODEL" real copy="/home/$ALICE/Repositories/$MODEL"
    load_library
    impact_conf_load || fail "the settings file of the setup should be valid"
    # Three people: a member as impact-add-user leaves it, a member with a
    # password and without record, and an account removed with
    # impact-remove-user that still has a login key.
    make_member "$ALICE" "$ALICE"
    sys_account_add "$BOB" impact docker
    sys_set_password "$BOB" "$BOB_PASSWORD"
    sys_keypair "$BOB"
    sys_install_key "$BOB" "$BOB"
    sys_account_add "$CAROL"
    sys_keypair "$CAROL"
    sys_install_key "$CAROL" "$CAROL"
    impact_account_record_write "$CAROL" "$CAROL" removed || fail "record of $CAROL"
    usermod --expiredate 1 -- "$CAROL"
    # The key copy of alice, as the GUI places it.
    install -m 600 -o "$ALICE" -g "$ALICE" -- "$(sys_key_path "$ALICE")" "/home/$ALICE/.ssh/id_ed25519_$ALICE"

    # A model with one extra and its storage folders with the shared rules.
    install -d -m 2750 -o root -g impact -- "$dir" "$dir/extras" "$dir/extras/data"
    declare -A values=([MODEL_CONF_VERSION]=1 [REPO_URL]="$MODEL_URL" [BRANCH]=''
        [STORAGE_NAME]=Example [STORAGE_ROOTS]="$SYS_ROOT_A")
    impact_model_conf_write "$dir/model.conf" values || fail "model.conf"
    printf 'a,b\n1,2\n' >"$dir/extras/data/table.csv"
    chown root:impact "$dir/extras/data/table.csv"
    chmod 640 "$dir/extras/data/table.csv"
    real="$(impact_storage_real_root "$SYS_ROOT_A")" || fail "storage root A"
    local sub
    for sub in Example Example/outputs Example/inputs Example/inputs/synthpop; do
        mkdir -p -- "$real/$sub"
        impact_shared_apply_dir "$real/$sub" impact || fail "shared rules on $sub"
    done
    # Entries inside outputs: one that follows the rules (created as a
    # member, so the default ACL applies) and one moved in with old rights.
    as_person "$ALICE" bash -c "mkdir '$real/Example/outputs/run1' && printf 'x\n' >'$real/Example/outputs/run1/ok.csv'"
    printf 'y\n' >"$real/Example/outputs/run1/moved in.csv"
    chown root:root "$real/Example/outputs/run1/moved in.csv"
    chmod 644 "$real/Example/outputs/run1/moved in.csv"
    # A folder of a model that is not registered yet.
    mkdir -p -- "$real/Other_Model_2024"

    # alice's working copy: the extra is copied and ignored through
    # .git/info/exclude; one untracked file of her own.
    as_person "$ALICE" bash -c "
        set -e
        git init -q '$copy'
        cd '$copy'
        git config user.name 'Alice Example'
        git config user.email alice@example.org
        git config commit.gpgsign false
        printf 'model\n' >README.md
        git add README.md
        git commit -q -m init
        git remote add origin '$MODEL_URL'
        mkdir data
        cp '$dir/extras/data/table.csv' data/table.csv
        printf 'data/table.csv\n' >>.git/info/exclude
        printf 'notes\n' >notes.txt
    "
    assert_exists "$copy/.git/index"
    # A tracked file whose time stamp changed and whose content did not (as
    # after an editor saved it unchanged). A plain "git status" would now
    # rewrite the index file of the copy to note the new time stamp; the
    # check must leave it alone (the snapshots of /home prove it).
    sleep 1.1
    as_person "$ALICE" touch "$copy/README.md"
    # A program outside Docker on a port of the range (on 127.0.0.1).
    start_listener 127.0.0.1 8795 local
}

test_full_set_up_machine_report() {
    run_check_unchanged
    assert_complete_report
    assert_block 1 OK
    assert_block 4 OK
    # SSH: both members get the restricted values; the administrator and
    # root are unchanged.
    assert_block 5 OK
    assert_block_contains 5 '2 of 2 members get the restricted SSH settings'
    # Groups: alice and bob are members; the administrator is not.
    assert_block 6 OK
    assert_block_contains 6 "The group 'impact' exists"
    assert_block_contains 6 "members: $ALICE $BOB"
    # Accounts.
    assert_block 7 WARN
    assert_block_contains 7 "Account $ALICE: user number"
    assert_block_contains 7 "GitHub name $ALICE"
    assert_block_contains 7 'login keys: 1 of the type ed25519.'
    assert_block_contains 7 "$ALICE: the key copy /home/$ALICE/.ssh/id_ed25519_$ALICE belongs to a login key (SHA256:"
    assert_block_contains 7 'size of the home folder:'
    assert_block_contains 7 "$BOB is a member of 'impact' without an IMPACT account record"
    assert_block_contains 7 "$BOB has a password that is not locked (usable)"
    assert_block_contains 7 "sudo passwd --lock $BOB"
    assert_block_contains 7 "$CAROL is closed (expired) and kept"
    assert_block_contains 7 "The removed account $CAROL still has login keys."
    assert_block_contains 7 "Account $SYS_ADMIN: user number"
    # Models and extras.
    assert_block 8 OK
    assert_block_contains 8 "Model $MODEL: repository $MODEL_URL, branch (the default branch), storage folder Example on $SYS_ROOT_A."
    assert_block_contains 8 "extras of $MODEL: 1 files, 8 bytes."
    # Working copies: the untracked file is named; the extra is ignored.
    assert_block 9 WARN
    assert_block_contains 9 "/home/$ALICE/Repositories/$MODEL has 1 files that git neither tracks nor ignores (for example: notes.txt)"
    assert_block_contains 9 "git ignores every extra of the model $MODEL"
    assert_block_contains 9 "$BOB has no repository folder /home/$BOB/Repositories"
    # Storage: the four folders follow the rules; the sample finds the file
    # that was moved in; the unregistered model folder is named.
    assert_block 10 WARN
    assert_block_contains 10 "The storage folders of $MODEL on $SYS_ROOT_A follow the shared rules."
    assert_block_contains 10 'deviate from the shared rules (for example: run1/moved in.csv)'
    assert_block_contains 10 'sudo impact-share-folder --repair /mnt/disk_a/shared/Example/outputs'
    assert_block_contains 10 'Entries in /mnt/disk_a/shared that no registered model uses (1): Other_Model_2024.'
    # Listeners: the program on 8795 is named; 43 ports stay free.
    assert_block 12 WARN
    assert_block_contains 12 'Port 8795 on 127.0.0.1 (this machine only): python3'
    assert_block_contains 12 '43 of the 44 ports of the range 8787 to 8830 are free.'
}

test_second_run_gives_the_same_report() {
    local first second
    run_cmd sys_as_admin "$CHECK"
    # The time line and the uptime line are the only lines that may differ.
    first="$(printf '%s\n' "$RUN_OUTPUT" | grep -v -e '^Time (UTC): ' -e 'Running since: ')"
    run_check_unchanged
    second="$(printf '%s\n' "$RUN_OUTPUT" | grep -v -e '^Time (UTC): ' -e 'Running since: ')"
    assert_eq "$first" "$second" "the report of the second run"
}

test_no_secret_appears_in_the_output() {
    local blob hash line
    run_cmd sys_as_admin "$CHECK"
    # The key data of the login keys and of the private key copy.
    for line in "$ALICE" "$BOB" "$CAROL"; do
        read -r _ blob _ <"$(sys_key_path "$line").pub"
        assert_output_not_contains "$blob"
        assert_output_not_contains "${blob:20:30}"
    done
    while IFS= read -r line; do
        [[ "$line" == -----* ]] && continue
        assert_output_not_contains "$line"
    done <"$(sys_key_path "$ALICE")"
    assert_output_not_contains 'PRIVATE KEY'
    # The password hash of bob, and any shadow hash marker.
    hash="$(getent shadow "$BOB" | cut -d: -f2)"
    [[ ${#hash} -gt 20 ]] || fail "bob should have a password hash"
    assert_output_not_contains "$hash"
    assert_output_not_contains "${hash:0:20}"
    assert_output_not_contains "$BOB_PASSWORD"
    assert_output_not_contains '$y$'
    assert_output_not_contains '$6$'
}

test_mask_hides_addresses_and_host_names() {
    hostname >"$TEST_SUITE_TMP/old-hostname"
    hostname "$TEST_HOST"
    # sudo looks the host name up; without this line it complains about it
    # (in its own words, before impact-check starts).
    cp -p /etc/hosts "$TEST_SUITE_TMP/hosts-saved"
    printf '127.0.1.1 %s.example.org %s\n' "$TEST_HOST" "$TEST_HOST" >>/etc/hosts
    ip address add 192.0.2.10/32 dev lo
    start_listener 192.0.2.10 8796 network
    run_cmd sys_as_admin "$CHECK"
    assert_output_contains "$TEST_HOST"
    assert_output_contains '192.0.2.10'
    run_check_unchanged --mask
    assert_complete_report
    assert_output_contains 'Addresses and host names are masked.'
    assert_output_not_contains "$TEST_HOST"
    assert_output_not_contains 'example.org.'
    assert_output_not_contains '192.0.2.10'
    assert_block_contains 1 'Host name: <host>.'
    assert_block_contains 12 'Port 8796 on <address> (a network address)'
    # The loopback address and the port numbers stay readable.
    assert_block_contains 12 'Port 8795 on 127.0.0.1 (this machine only)'
    kill "$(cat "$TEST_SUITE_TMP/listener-network.pid")" 2>/dev/null || true
    rm -f -- "$TEST_SUITE_TMP/listener-network.pid"
    ip address del 192.0.2.10/32 dev lo
    hostname "$(cat "$TEST_SUITE_TMP/old-hostname")"
    rm -f -- "$TEST_SUITE_TMP/old-hostname"
    cp -p -- "$TEST_SUITE_TMP/hosts-saved" /etc/hosts
    rm -f -- "$TEST_SUITE_TMP/hosts-saved"
}

test_extra_that_git_would_commit_is_a_fail() {
    local copy="/home/$ALICE/Repositories/$MODEL"
    # The extra is no longer listed as ignored.
    as_person "$ALICE" bash -c "cd '$copy' && : >.git/info/exclude"
    run_check_unchanged
    assert_complete_report
    assert_block 9 FAIL
    assert_block_contains 9 "1 extras of the model $MODEL are not ignored by git or replace a tracked file: data/table.csv (not_ignored)"
    # The extra replaces a tracked file.
    as_person "$ALICE" bash -c "cd '$copy' && git add data/table.csv && git commit -q -m 'add table'"
    run_check_unchanged
    assert_block 9 FAIL
    assert_block_contains 9 'data/table.csv (tracked)'
    # Back to the rule: the extra is not tracked and is ignored.
    as_person "$ALICE" bash -c "cd '$copy' && git rm -q --cached data/table.csv && git commit -q -m 'drop table' && printf 'data/table.csv\n' >.git/info/exclude"
    run_cmd sys_as_admin "$CHECK"
    assert_block_contains 9 "git ignores every extra of the model $MODEL"
}

test_docker_blocks_with_the_stand_in() {
    install_fake_docker
    sys_fake_systemd_install ssh.service
    run_check_unchanged
    sys_fake_systemd_remove
    assert_complete_report
    assert_output_not_contains 'stand-in docker: not answered'
    # Block 2: version, source, start at boot, data folder, images.
    assert_block 2 WARN
    assert_block_contains 2 "OK: Docker comes from Docker's own apt source (package docker-ce)."
    assert_block_contains 2 'OK: The Docker daemon answers (version 29.10.0).'
    assert_block_contains 2 'OK: Docker starts with the machine.'
    assert_block_contains 2 'image store of containerd'
    assert_block_contains 2 'Images of alice-example: 1, 1.5 GB'
    assert_block_contains 2 'Images of gone-account: 1, 1 GB'
    assert_block_contains 2 'no members of '"'"'impact'"'"' (removed or unknown): gone-account.'
    assert_block_contains 2 'Without the label impact.account (base images and images made outside the GUI): 1, 700 MB.'
    # Block 11: containers per person.
    assert_block 11 WARN
    assert_block_contains 11 'Containers of alice-example:'
    assert_block_contains 11 'Example-Model_alice-example: running, image example-model:alice-example, ports 127.0.0.1:8791 -> 8787/tcp.'
    assert_block_contains 11 "The container old-of-gone belongs to 'gone-account', which is no account on this machine."
    assert_block_contains 11 'uses the port 8899 outside the range 8787 to 8830'
    assert_block_contains 11 'The container impact-test-hostile has a label impact.account that is no account name.'
    # Block 12: ports held by containers are named.
    assert_block_contains 12 'Port 8795 on 127.0.0.1 (this machine only): python3'
    # Block 13: publishing to the network.
    assert_block 13 WARN
    assert_block_contains 13 'OK: data_preparation_1 (running) publishes to the network and is accepted (KNOWN_DIRECT_CONTAINERS): all addresses:8793 -> 8787/tcp.'
    assert_block_contains 13 'The GUI container Example-Model_bob-wide of bob-example (running) publishes to the network: all addresses:8792 -> 8787/tcp.'
    assert_block_contains 13 'impact-test-plain (running) publishes to the network and is not accepted in KNOWN_DIRECT_CONTAINERS: 192.0.2.10:8794 -> 80/tcp.'
    assert_block_not_contains 13 'Example-Model_alice-example'
    # Block 14: the three volumes named like IMPACT volumes.
    assert_block 14 WARN
    assert_block_contains 14 'Volume impactncd_output_Example-Model_alice-example: used by impact-test-old'
    assert_block_contains 14 'Volume impactncd_germany_synthpop_bob_example: used by no container.'
    assert_block_contains 14 'Volume results_output_2024: used by no container.'
    assert_block_contains 14 '3 volumes are named like volumes of the GUI'"'"'s volume mode.'
    assert_block_not_contains 14 'plainvolume'
    # Block 15: containers without IMPACT labels.
    assert_block 15 WARN
    assert_block_contains 15 'OK: data_preparation_1 (running, image prep:latest, ports all addresses:8793 -> 8787/tcp): accepted (KNOWN_DIRECT_CONTAINERS).'
    assert_block_contains 15 'impact-test-old (exited, image example-model, ports no published port): started by GUI 2.0'
    assert_block_contains 15 'impact-test-plain (running, image some/tool, ports 192.0.2.10:8794 -> 80/tcp): no IMPACT label.'
    assert_block_not_contains 15 'Example-Model_alice-example'
    # The hostile label value was never run as a command.
    assert_missing /tmp/pwned
    rm -f -- "$FAKE_DOCKER"
}

# -----------------------------------------------------------------------------
# Hostile and broken state
# -----------------------------------------------------------------------------

test_hostile_names_and_links_are_reported_and_not_followed() {
    local dir=/srv/impact/models
    # Model folder entries with hostile names, and a link.
    mkdir -p -- "$dir/bad name" "$dir/\$(touch \$HOME-pwned)" "$dir/semi;colon"
    ln -s /root "$dir/Linked-Model"
    # dave: a member whose repository folder and .ssh are symbolic links to
    # root's folders. The check must not read root's files through them.
    make_member "$DAVE" "$DAVE"
    rm -rf -- "/home/$DAVE/Repositories"
    ln -s /root "/home/$DAVE/Repositories"
    mv "/home/$DAVE/.ssh" "/home/$DAVE/ssh-saved"
    ln -s /root/.ssh "/home/$DAVE/.ssh"
    chown -h "$DAVE:$DAVE" "/home/$DAVE/Repositories" "/home/$DAVE/.ssh"
    mkdir -p /root/.ssh
    printf '#check-secret-marker\n' >/root/.ssh/impact-check-marker
    # A file with a line break and "$( )" in its name inside outputs.
    printf 'z\n' >"/mnt/disk_a/shared/Example/outputs/run1/odd"$'\n''name $(touch x).csv'
    chown root:root "/mnt/disk_a/shared/Example/outputs/run1/odd"$'\n''name $(touch x).csv'
    run_check_unchanged
    assert_complete_report
    assert_block_contains 8 "'bad name' in /srv/impact/models is no valid model name"
    assert_block_contains 8 "'\$(touch \$HOME-pwned)' in /srv/impact/models is no valid model name"
    assert_block_contains 8 "'semi;colon' in /srv/impact/models is no valid model name"
    assert_block_contains 8 '/srv/impact/models/Linked-Model is a link, not a model folder'
    assert_block_contains 7 "/home/$DAVE/.ssh of $DAVE is a link, not a real folder."
    assert_block_contains 9 "The repository folder /home/$DAVE/Repositories of $DAVE is a link, not a real folder"
    assert_block_contains 10 'odd?name $(touch x).csv'
    assert_output_not_contains 'check-secret-marker'
    assert_output_not_contains 'impact-check-marker'
    assert_missing "/root-pwned"
    assert_missing "/home/$DAVE-pwned"
    # Clean up the hostile state.
    rm -rf -- "$dir/bad name" "$dir/\$(touch \$HOME-pwned)" "$dir/semi;colon" "$dir/Linked-Model"
    rm -f -- /root/.ssh/impact-check-marker "/home/$DAVE/Repositories" "/home/$DAVE/.ssh"
    rm -f -- "/mnt/disk_a/shared/Example/outputs/run1/odd"$'\n''name $(touch x).csv'
    mv "/home/$DAVE/ssh-saved" "/home/$DAVE/.ssh"
}

test_changed_ssh_rules_are_reported() {
    cp -p -- "$RULES" "$TEST_SUITE_TMP/rules-saved"
    # A comment changes the content but not the effect.
    printf '# a note added by hand\n' >>"$RULES"
    run_check_unchanged
    assert_block 5 WARN
    assert_block_contains 5 'differs from what impact-workstation-setup writes'
    assert_block_contains 5 "The SSH rules leave the login of 'tadmin' unchanged"
    # A line before the Match block changes the settings of everybody.
    {
        printf 'PermitTunnel yes\n'
        cat -- "$TEST_SUITE_TMP/rules-saved"
    } >"$RULES"
    run_check_unchanged
    assert_complete_report
    assert_block 5 FAIL
    assert_block_contains 5 "The SSH rules change the login of 'tadmin'."
    assert_block_contains 5 'without the rules: permittunnel no'
    assert_block_contains 5 'with the rules:    permittunnel yes'
    assert_block_contains 5 'sudo impact-workstation-setup --remove-ssh-rules'
    cp -p -- "$TEST_SUITE_TMP/rules-saved" "$RULES"
    # A member that the rules do not reach: a rule file that sshd reads
    # before 60-impact.conf and that matches the member wins (a later file
    # would have no effect, because sshd keeps the first value it reads).
    printf 'Match User %s\n    PasswordAuthentication yes\n' "$ALICE" >/etc/ssh/sshd_config.d/10-impact-test.conf
    run_check_unchanged
    rm -f /etc/ssh/sshd_config.d/10-impact-test.conf
    assert_block 5 FAIL
    assert_block_contains 5 "The member '$ALICE' does not get the restricted SSH settings:"
    assert_block_contains 5 'passwordauthentication: expected "no", effective "yes"'
    assert_block_contains 5 'Further rule files in /etc/ssh/sshd_config.d: 10-impact-test.conf.'
}

test_invalid_and_unsafe_settings_files() {
    cp -p -- "$CONF" "$TEST_SUITE_TMP/conf-saved"
    # One invalid value: the block names it; the other values are used.
    sed -i -e 's/^PORT_MIN=.*/PORT_MIN=80/' -e 's/^MIN_FREE_GB=.*/MIN_FREE_GB=lots/' "$CONF"
    printf 'UNKNOWN_KEY=1\n' >>"$CONF"
    run_check_unchanged
    assert_complete_report
    assert_block 4 FAIL
    assert_block_contains 4 "PORT_MIN has the value '80'"
    assert_block_contains 4 "MIN_FREE_GB has the value 'lots'"
    assert_block_contains 5 'Without a usable settings file (block 4) this block works with default values (group impact, ports 8787 to 8830).'
    cp -p -- "$TEST_SUITE_TMP/conf-saved" "$CONF"
    # A file that another account can change is never used.
    chmod 666 "$CONF"
    run_check_unchanged
    assert_block 4 FAIL
    assert_block_contains 4 'The settings file cannot be used'
    assert_block_contains 4 "sudo chown root:root $CONF && sudo chmod 644 $CONF"
    chmod 644 "$CONF"
    # Unknown key in a valid file: a warning.
    printf 'UNKNOWN_KEY=1\n' >>"$CONF"
    run_check_unchanged
    assert_block 4 WARN
    assert_block_contains 4 'The key UNKNOWN_KEY is unknown and is ignored.'
    cp -p -- "$TEST_SUITE_TMP/conf-saved" "$CONF"
}

test_broken_installation_and_groups() {
    # The administrator in the shared group: the SSH rules would restrict
    # its own login.
    usermod --append --groups impact -- "$SYS_ADMIN"
    run_cmd sys_as_admin "$CHECK"
    gpasswd -d "$SYS_ADMIN" impact >/dev/null
    assert_complete_report
    assert_block 6 FAIL
    assert_block_contains 6 "The account '$SYS_ADMIN' that administers the workstation is a member of 'impact'."
    # A member without docker, and a member with sudo.
    gpasswd -d "$BOB" docker >/dev/null
    usermod --append --groups sudo -- "$BOB"
    run_check_unchanged
    usermod --append --groups docker -- "$BOB"
    gpasswd -d "$BOB" sudo >/dev/null
    assert_block 6 WARN
    assert_block_contains 6 "no members of docker and cannot start containers: $BOB"
    assert_block_contains 6 "Members of 'impact' may use sudo: $BOB (sudo)."
    # A file of the commands that others can change.
    chmod 666 /opt/impact/lib/impact-check.sh
    run_check_unchanged
    chmod 644 /opt/impact/lib/impact-check.sh
    assert_block 1 FAIL
    assert_block_contains 1 '1 files of the installed commands do not belong to root or can be changed by other accounts.'
    # A missing link and a missing admin subfolder. The command is started
    # at its installed place while its link is away.
    mv /usr/local/bin/impact-check "$TEST_SUITE_TMP/link-saved"
    rmdir /opt/impact/admin/state
    run_cmd sys_as_admin /opt/impact/bin/impact-check
    mv "$TEST_SUITE_TMP/link-saved" /usr/local/bin/impact-check
    install -d -m 700 -o root -g root /opt/impact/admin/state
    assert_block 1 WARN
    assert_block_contains 1 "These commands have no link in /usr/local/bin, so 'sudo <command>' does not find them: impact-check."
    assert_block_contains 1 '/opt/impact/admin/state does not exist.'
}
