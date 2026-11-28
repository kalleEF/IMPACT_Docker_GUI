#!/bin/bash
# =============================================================================
# users-30-remove-user.test.sh: system tests for impact-remove-user
#
# Purpose
#   Runs the installed impact-remove-user as the stand-in administrator on a
#   prepared workstation with a real SSH server on 127.0.0.1. It proves:
#   wrong and hostile input is refused before any change; a dry run changes
#   nothing and ends no session; the removal asks first; it ends a live SSH
#   session and a live tunnel of the person, closes the account, moves the
#   login keys to the archive, takes the account out of both groups, stops
#   its containers, deletes its key copies, and leaves other people alone;
#   a later login is refused, also with a key put back by hand; the user
#   number is kept; a second run changes nothing; the printed way back works
#   when it is typed exactly as printed; a Docker that does not answer is
#   reported; --delete lists the files on the shared storage first, asks
#   twice and deletes; the way back after --delete gives the old number.
#
#   Docker: the tests use a stand-in program "docker" in /usr/local/sbin
#   (first in the commands' PATH). It answers "ps" from a small list and
#   notes every "stop". It proves which containers the command finds and
#   stops; users-40-docker.test.sh does the same with a real Docker daemon
#   when one runs.
#
# Who runs it
#   tests/workstation/run-tests.sh system   (root, disposable system only)
#
# Usage
#   sudo env IMPACT_TEST_DISPOSABLE=yes bash tests/workstation/run-tests.sh system --filter users-30
#
# What it changes on the system
#   The installed commands and their settings, test accounts, an SSH server
#   process, small web servers on 127.0.0.1:8787, the stand-in docker (removed
#   again), and the storage roots below /mnt/disk_a and /mnt/disk_b.
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
# are test data, or lines of a small program that a test writes. They must
# stay exactly as written.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/testlib.sh"

REMOVE=/usr/local/bin/impact-remove-user
ADD=/usr/local/bin/impact-add-user
GH='alice-example'
ACC='alice-example'
OTHER='olga-example'
WATCHED=(/etc/impact /opt/impact /srv/impact /home /etc/ssh/sshd_config.d /mnt/disk_a /mnt/disk_b)
FAKE_DOCKER=/usr/local/sbin/docker
FAKE_MARKER='# impact-test stand-in for docker'
CONTAINERS=/run/impact-test-docker-containers
DOCKER_LOG=/run/impact-test-docker.log
# Container numbers (64 hexadecimal digits, as Docker prints them).
ID_ALICE="$(printf 'a1%.0s' {1..32})"
ID_OLGA="$(printf 'b2%.0s' {1..32})"

suite_setup() {
    sys_clean_slate
    sys_storage_up
    sys_install
    sys_admin_create
    sys_sshd_start
    sys_setup
    local name
    for name in m1 m2 o1 ned p1 p2; do
        sys_keypair "$name"
    done
    for name in "$ACC" "$OTHER" ned newcomer paula-example; do
        sys_register_account "$name"
    done
    enrol "$GH" m1
    run_cmd sys_as_admin /usr/local/bin/impact-key add "$ACC" --key-file "$(pub m2)" --fingerprint "$(print_of m2)"
    [[ "$RUN_STATUS" == '0' ]] || fail "impact-key add failed: $RUN_OUTPUT"
    enrol "$OTHER" o1
    sys_account_add ned
    install_fake_docker
    sys_effective_ssh "$SYS_ADMIN" >"$TEST_SUITE_TMP/admin-ssh-before"
}

suite_teardown() {
    pkill -f 'http.server 8787' 2>/dev/null || true
    remove_fake_docker
    remove_fake_jobs
    rm -f /var/lib/systemd/linger/paula-example
    sys_clean_slate
}

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# pub NAME / print_of NAME / blob_of NAME
#   Path, fingerprint and key data of the public key of a test key pair.
pub() {
    printf '%s.pub\n' "$(sys_key_path "$1")"
}
print_of() {
    ssh-keygen -l -E sha256 -f "$(pub "$1")" | awk '{ print $2 }'
}
blob_of() {
    awk '{ print $2 }' "$(pub "$1")"
}

# enrol GITHUB_NAME KEY_NAME
#   Enrols a person with impact-add-user and fails the test on an error.
enrol() {
    run_cmd sys_as_admin "$ADD" "$1" --key-file "$(pub "$2")" --fingerprint "$(print_of "$2")"
    if [[ "$RUN_STATUS" != '0' ]]; then
        show_run
        fail "impact-add-user $1 failed"
    fi
}

# install_fake_docker
#   Puts a stand-in "docker" first in the commands' PATH. The list
#   /run/impact-test-docker-containers holds lines "<id> <account> <name>
#   <state>"; "docker ps" prints the running containers of the account named
#   in the label filter, "docker stop" sets the state to "exited". Every call
#   is noted in /run/impact-test-docker.log. While the file
#   /run/impact-test-docker-down exists, the stand-in behaves like a daemon
#   that does not answer.
install_fake_docker() {
    cat >"$FAKE_DOCKER" <<'END'
#!/bin/bash
# impact-test stand-in for docker
list=/run/impact-test-docker-containers
printf '%s\n' "$*" >>/run/impact-test-docker.log
if [[ -e /run/impact-test-docker-down ]]; then
    echo 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock.' >&2
    exit 1
fi
case "${1:-}" in
    version) echo '29.10.0' ;;
    ps)
        account=''
        for word in "$@"; do
            case "$word" in label=impact.account=*) account="${word#label=impact.account=}" ;; esac
        done
        touch "$list"
        while read -r id owner name state; do
            if [[ "$owner" == "$account" && "$state" == 'running' ]]; then
                echo "$id $name $state"
            fi
        done <"$list"
        ;;
    stop)
        id="${*: -1}"
        sed -i -e "s/^$id \(.*\) running\$/$id \1 exited/" "$list"
        echo "$id"
        ;;
    *) exit 1 ;;
esac
END
    chmod 755 "$FAKE_DOCKER"
    printf '%s %s Model_%s running\n%s %s Model_%s running\n' \
        "$ID_ALICE" "$ACC" "$ACC" "$ID_OLGA" "$OTHER" "$OTHER" >"$CONTAINERS"
    : >"$DOCKER_LOG"
}

# remove_fake_docker
#   Removes the stand-in docker and its files.
remove_fake_docker() {
    if [[ -f "$FAKE_DOCKER" ]] && grep -q -F -- "$FAKE_MARKER" "$FAKE_DOCKER"; then
        rm -f -- "$FAKE_DOCKER"
    fi
    rm -f -- "$CONTAINERS" "$DOCKER_LOG" /run/impact-test-docker-down
}

# refused_without_change EXPECTED_CODE COMMAND...
#   Runs COMMAND, fails unless it ends with EXPECTED_CODE and leaves the
#   watched folders, the accounts, the groups and the containers unchanged.
refused_without_change() {
    local code="$1" containers_before
    shift
    containers_before="$(cat -- "$CONTAINERS")"
    snapshot_unchanged_by --content "${WATCHED[@]}" -- "$@"
    assert_status "$code"
    assert_eq "$containers_before" "$(cat -- "$CONTAINERS")" "the containers"
}

# start_session KEY_NAME
#   Opens an SSH session of the member that runs "sleep 600" in the
#   background. SESSION_PID is the process of the ssh client.
start_session() {
    local -a SYS_SSH_OPTIONS=()
    sys__ssh_options
    ssh "${SYS_SSH_OPTIONS[@]}" -o BatchMode=yes -o IdentitiesOnly=yes -i "$(sys_key_path "$1")" \
        "$ACC@127.0.0.1" sleep 600 </dev/null >/dev/null 2>&1 &
    SESSION_PID=$!
}

# start_tunnel KEY_NAME
#   Starts a small web server on 127.0.0.1:8787 (a port of the range, where
#   a container would listen) and a tunnel of the member from local port
#   18787 to it, as the GUI does. TUNNEL_PID is the ssh client, WEB_PID the
#   web server.
start_tunnel() {
    mkdir -p "$TEST_TMP/www"
    printf 'answer of the container\n' >"$TEST_TMP/www/index.html"
    python3 -m http.server 8787 --bind 127.0.0.1 --directory "$TEST_TMP/www" >/dev/null 2>&1 &
    WEB_PID=$!
    local -a SYS_SSH_OPTIONS=()
    sys__ssh_options
    ssh "${SYS_SSH_OPTIONS[@]}" -N -T -o BatchMode=yes -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes \
        -i "$(sys_key_path "$1")" -L 127.0.0.1:18787:127.0.0.1:8787 "$ACC@127.0.0.1" </dev/null >/dev/null 2>&1 &
    TUNNEL_PID=$!
}

# through_tunnel
#   Prints the answer of the web server through the tunnel (empty when the
#   tunnel does not work).
through_tunnel() {
    curl --noproxy '*' --silent --max-time 5 http://127.0.0.1:18787/ || true
}

# wait_until_gone PID
#   Waits up to 15 seconds for a process to end. Fails when it still runs.
wait_until_gone() {
    local _
    for _ in $(seq 1 30); do
        if ! kill -0 "$1" 2>/dev/null; then
            return 0
        fi
        sleep 0.5
    done
    fail "the process $1 still runs"
}

# way_back_lines TEXT
#   Prints the lines "sudo impact-..." of the section "How to bring the
#   person back".
way_back_lines() {
    printf '%s\n' "$1" | sed -n -e 's/^  \(sudo impact-.*\)$/\1/p'
}

# run_printed_line LINE
#   Runs a printed line "sudo impact-<command> ..." exactly as printed,
#   through the stand-in administrator. The words hold no blanks or quotes,
#   so splitting at blanks is exact.
run_printed_line() {
    local -a words=()
    read -r -a words <<<"$1"
    assert_eq 'sudo' "${words[0]}" "first word of the printed line"
    run_cmd sys_as_admin "/usr/local/bin/${words[1]}" "${words[@]:2}"
}

# terminal_answers ANSWERS COMMAND_LINE
#   Runs COMMAND_LINE through the stand-in administrator inside a terminal
#   made by "script", and types ANSWERS (lines) into it. Prints the output.
terminal_answers() {
    printf '%s' "$1" | timeout 180 script -q -e -c "runuser -u $SYS_ADMIN -- sudo -n -- $2" /dev/null 2>&1 || true
}

# ----------------------------------------------------------------------------
# Refusals and the dry run
# ----------------------------------------------------------------------------

test_help_and_root_check() {
    run_cmd runuser -u "$SYS_ADMIN" -- "$REMOVE" --help
    assert_status 0
    assert_output_contains 'How to undo'
    run_cmd runuser -u "$SYS_ADMIN" -- "$REMOVE" "$ACC" --dry-run
    assert_status 2
}

test_wrong_and_hostile_input_is_refused_before_any_change() {
    local name
    rm -f /tmp/impact-test-hostile
    for name in 'Alice' 'a b' '../root' 'x;id' '$(touch /tmp/impact-test-hostile)' '' "$ACC "; do
        refused_without_change 2 sys_as_admin "$REMOVE" --yes -- "$name"
        assert_output_contains 'is no valid account name'
    done
    refused_without_change 2 sys_as_admin "$REMOVE" "$ACC" --delete=yes
    refused_without_change 2 sys_as_admin "$REMOVE" "$ACC" "$OTHER" --yes
    refused_without_change 2 sys_as_admin "$REMOVE" "$ACC" --force
    refused_without_change 1 sys_as_admin "$REMOVE" nosuchuser --yes
    # Accounts that were not enrolled, or must never be changed.
    refused_without_change 4 sys_as_admin "$REMOVE" ned --yes
    refused_without_change 4 sys_as_admin "$REMOVE" "$SYS_ADMIN" --yes
    refused_without_change 4 sys_as_admin "$REMOVE" root --yes
    # root and administration accounts are never changed: the message says
    # so and does not suggest adopting them (impact-add-user refuses that).
    assert_output_contains 'never changed'
    assert_output_not_contains 'adopt it first'
    assert_missing /tmp/impact-test-hostile
}

# install_fake_jobs ACCOUNT
#   Puts stand-ins for crontab, atq, at and atrm first in the commands'
#   PATH (/usr/local/sbin), with one cron table and one "at" job of ACCOUNT
#   and one "at" job of root. They keep their state in /run/impact-test-jobs.
#   They prove how impact-remove-user treats scheduled jobs; the real cron
#   and at are not installed on every test machine.
install_fake_jobs() {
    mkdir -p /run/impact-test-jobs
    printf '0 3 * * * /home/%s/bin/nightly-tunnel\n' "$1" >"/run/impact-test-jobs/cron-$1"
    printf '41\tWed Nov 25 03:00:00 2026 a %s\n42\tWed Nov 25 04:00:00 2026 a root\n' "$1" >/run/impact-test-jobs/atq
    cat >/usr/local/sbin/crontab <<'END'
#!/bin/bash
# impact-test stand-in for crontab: crontab -u ACCOUNT -l | -r
account="$2"
case "$3" in
    -l) cat "/run/impact-test-jobs/cron-$account" 2>/dev/null || { echo "no crontab for $account" >&2; exit 1; } ;;
    -r) rm "/run/impact-test-jobs/cron-$account" ;;
esac
END
    printf '#!/bin/bash\n# impact-test stand-in for atq\ncat /run/impact-test-jobs/atq\n' >/usr/local/sbin/atq
    printf '#!/bin/bash\n# impact-test stand-in for at -c NUMBER\necho "job $2: /home/someone/bin/once"\n' >/usr/local/sbin/at
    printf '#!/bin/bash\n# impact-test stand-in for atrm NUMBER\nsed -i -e "/^$1\\t/d" /run/impact-test-jobs/atq\n' >/usr/local/sbin/atrm
    chmod 755 /usr/local/sbin/crontab /usr/local/sbin/atq /usr/local/sbin/at /usr/local/sbin/atrm
}

# remove_fake_jobs
#   Removes the stand-ins of install_fake_jobs.
remove_fake_jobs() {
    rm -f /usr/local/sbin/crontab /usr/local/sbin/atq /usr/local/sbin/at /usr/local/sbin/atrm
    rm -rf /run/impact-test-jobs
}

# Programs of a person can start again without a login: through lingering
# (systemd starts the person's own services at boot), a cron table, an "at"
# job, and through login keys in ~/.ssh/authorized_keys2, which sshd on
# Ubuntu reads as well. The removal switches all of them off and keeps
# copies of the jobs and keys in the archive; other people's jobs stay.
test_removal_switches_off_work_without_login_and_further_key_files() {
    run_cmd sys_as_admin "$ADD" paula-example --key-file "$(pub p1)" --fingerprint "$(print_of p1)"
    assert_status 0
    # Lingering, as "loginctl enable-linger" marks it (no systemd runs here).
    mkdir -p /var/lib/systemd/linger
    : >/var/lib/systemd/linger/paula-example
    # A further key in authorized_keys2, written by the person.
    install -m 600 -o paula-example -g paula-example -- "$(pub p2)" /home/paula-example/.ssh/authorized_keys2
    install_fake_jobs paula-example
    run_cmd sys_as_admin "$REMOVE" paula-example --dry-run
    assert_status 0
    assert_output_contains "[dry run] Switch off lingering for 'paula-example'"
    assert_output_contains "[dry run] Save the scheduled jobs of 'paula-example' (cron table: yes; at jobs: 1)"
    assert_output_contains '[dry run] Move the login keys of /home/paula-example/.ssh/authorized_keys2'
    assert_exists /var/lib/systemd/linger/paula-example
    run_cmd sys_as_admin "$REMOVE" paula-example --yes
    local jobs_folder keys2_folder removal_output="$RUN_OUTPUT"
    jobs_folder="$(find /opt/impact/admin/keys/paula-example -maxdepth 1 -name 'jobs-removed-*' | head -n 1)"
    keys2_folder="$(find /opt/impact/admin/keys/paula-example -maxdepth 1 -name 'authorized_keys2-removed-*' | head -n 1)"
    remove_fake_jobs
    assert_status 0
    assert_missing /var/lib/systemd/linger/paula-example
    assert_missing /home/paula-example/.ssh/authorized_keys2
    assert_file_facts "$jobs_folder/crontab" 600 root root
    assert_file_contains "$jobs_folder/crontab" 'nightly-tunnel'
    assert_file_facts "$jobs_folder/at-41.job" 600 root root
    assert_missing "$jobs_folder/at-42.job"
    assert_file_contains "$keys2_folder/key-1.pub" "$(blob_of p2)"
    # The key of authorized_keys2 no longer opens a session.
    run_cmd sys_ssh_key paula-example p2 id -un
    assert_status 255
    # The bring-back of the keys still uses the archive of authorized_keys.
    assert_contains "$removal_output" 'Scheduled jobs (cron, at) and lingering stay off.'
    assert_contains "$removal_output" 'account-removed-'
}

test_dry_run_changes_nothing_and_ends_no_session() {
    start_session m1
    start_tunnel m2
    sleep 3
    assert_eq 'answer of the container' "$(through_tunnel)" "the tunnel before the dry run"
    refused_without_change 0 sys_as_admin "$REMOVE" "$ACC" --dry-run
    assert_output_contains "[dry run] Set the account '$ACC' to expired"
    assert_output_contains "[dry run] Take '$ACC' out of the group 'impact'"
    assert_output_contains "[dry run] End the "
    assert_output_contains "[dry run] Stop the container Model_$ACC"
    assert_output_not_contains "Model_$OTHER"
    assert_output_contains "sshd: $ACC"
    # The session and the tunnel still work.
    kill -0 "$SESSION_PID"
    assert_eq 'answer of the container' "$(through_tunnel)" "the tunnel after the dry run"
    assert_eq '' "$(grep -E '^stop' "$DOCKER_LOG" || true)" "no docker stop in a dry run"
    kill "$SESSION_PID" "$TUNNEL_PID" "$WEB_PID" 2>/dev/null || true
    wait 2>/dev/null || true
}

test_the_removal_asks_first() {
    refused_without_change 1 sys_as_admin "$REMOVE" "$ACC"
    assert_output_contains 'not confirmed'
}

# ----------------------------------------------------------------------------
# The removal
# ----------------------------------------------------------------------------

test_removal_ends_session_and_tunnel_and_closes_the_account() {
    local uid
    uid="$(id -u "$ACC")"
    printf '%s\n' "$uid" >"$TEST_SUITE_TMP/uid"
    # Key copies as the GUI places them, also one under an older name.
    install -m 600 -o "$ACC" -g "$ACC" -- "$(sys_key_path m1)" "/home/$ACC/.ssh/id_ed25519_$GH"
    install -m 644 -o "$ACC" -g "$ACC" -- "$(pub m1)" "/home/$ACC/.ssh/id_ed25519_$GH.pub"
    install -m 600 -o "$ACC" -g "$ACC" -- "$(sys_key_path m2)" "/home/$ACC/.ssh/id_ed25519_old-name"
    start_session m1
    start_tunnel m2
    sleep 3
    assert_eq 'answer of the container' "$(through_tunnel)" "the tunnel before the removal"
    kill -0 "$SESSION_PID"
    run_cmd sys_as_admin "$REMOVE" "$ACC" --yes
    assert_status 0
    way_back_lines "$RUN_OUTPUT" >"$TEST_SUITE_TMP/way-back"
    # The session and the tunnel ended.
    wait_until_gone "$SESSION_PID"
    wait_until_gone "$TUNNEL_PID"
    assert_eq '' "$(through_tunnel)" "the tunnel after the removal"
    assert_eq '' "$(pgrep -u "$uid" || true)" "processes of the person"
    kill "$WEB_PID" 2>/dev/null || true
    # The account is closed and kept, with its number.
    assert_eq "$uid" "$(id -u "$ACC")" "user number"
    assert_eq '1' "$(getent shadow "$ACC" | cut -d: -f8)" "expiry date (day 1 = expired)"
    assert_not_contains " $(id -nG "$ACC") " ' impact '
    assert_not_contains " $(id -nG "$ACC") " ' docker '
    assert_exists "/home/$ACC/Repositories"
    # The login keys are in the archive, the key copies are gone.
    assert_missing "/home/$ACC/.ssh/authorized_keys"
    local folder
    folder="$(find "/opt/impact/admin/keys/$ACC" -mindepth 1 -maxdepth 1 -name 'account-removed-*' | sort | tail -n 1)"
    assert_file_facts "$folder" 700 root root
    assert_file_contains "$folder/key-1.pub" "$(blob_of m1)"
    assert_file_contains "$folder/key-2.pub" "$(blob_of m2)"
    assert_missing "/home/$ACC/.ssh/id_ed25519_$GH"
    assert_missing "/home/$ACC/.ssh/id_ed25519_$GH.pub"
    assert_missing "/home/$ACC/.ssh/id_ed25519_old-name"
    # Only the container of the person was stopped.
    assert_file_contains "$CONTAINERS" "$ID_ALICE $ACC Model_$ACC exited"
    assert_file_contains "$CONTAINERS" "$ID_OLGA $OTHER Model_$OTHER running"
    assert_eq "stop -t 30 -- $ID_ALICE" "$(grep -E '^stop' "$DOCKER_LOG")" "docker stop calls"
    # The record.
    assert_file_contains "/opt/impact/admin/accounts/$ACC.conf" 'STATE=removed'
    # Other people and the administrator are untouched.
    run_cmd sys_ssh_key "$OTHER" o1 id -un
    assert_status 0
    sys_effective_ssh "$SYS_ADMIN" >"$TEST_TMP/admin-ssh-after"
    assert_eq "$(cat "$TEST_SUITE_TMP/admin-ssh-before")" "$(cat "$TEST_TMP/admin-ssh-after")" "SSH settings of the administrator"
}

test_a_later_login_is_refused() {
    run_cmd sys_ssh_key "$ACC" m1 id -un
    assert_status 255
    # Even with a login key put back by hand, the expired account cannot
    # log in.
    install -m 600 -o "$ACC" -g "$ACC" -- "$(pub m1)" "/home/$ACC/.ssh/authorized_keys"
    run_cmd sys_ssh_key "$ACC" m1 id -un
    rm -f "/home/$ACC/.ssh/authorized_keys"
    assert_status 255
}

test_the_user_number_is_kept() {
    local uid
    uid="$(cat "$TEST_SUITE_TMP/uid")"
    assert_eq "$ACC" "$(getent passwd "$uid" | cut -d: -f1)" "owner of the number"
    useradd --create-home -- newcomer
    assert_ne "$uid" "$(id -u newcomer)" "number of a new account"
    userdel --remove newcomer 2>/dev/null || true
}

test_second_run_changes_nothing() {
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log "${WATCHED[@]}" -- \
        sys_as_admin "$REMOVE" "$ACC" --yes
    assert_status 0
    assert_output_contains 'Nothing to do'
    assert_eq "$(cat "$TEST_SUITE_TMP/way-back")" "$(way_back_lines "$RUN_OUTPUT")" "the way back printed by the second run"
}

test_list_users_shows_the_removed_person() {
    run_cmd sys_as_admin /usr/local/bin/impact-list-users
    assert_status 0
    assert_output_contains 'removed (account closed, user number kept)'
    # Removed: alice-example and paula-example (an earlier test).
    assert_output_contains 'Summary: 1 enrolled, 2 removed, 0 deleted'
}

test_a_removed_account_needs_the_way_back() {
    refused_without_change 4 sys_as_admin "$ADD" "$GH" --key-file "$(pub m1)" --fingerprint "$(print_of m1)"
    assert_output_contains '--existing'
    refused_without_change 4 sys_as_admin /usr/local/bin/impact-key add "$ACC" --key-file "$(pub m1)" --fingerprint "$(print_of m1)"
}

test_the_printed_way_back_works() {
    local line count=0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        count=$((count + 1))
        run_printed_line "$line"
        assert_status 0
    done <"$TEST_SUITE_TMP/way-back"
    assert_eq 2 "$count" "number of printed lines (one per saved key)"
    assert_eq "$(cat "$TEST_SUITE_TMP/uid")" "$(id -u "$ACC")" "user number after the way back"
    assert_contains " $(id -nG "$ACC") " ' impact '
    assert_contains " $(id -nG "$ACC") " ' docker '
    assert_eq '' "$(getent shadow "$ACC" | cut -d: -f8)" "expiry date"
    assert_file_contains "/opt/impact/admin/accounts/$ACC.conf" 'STATE=enrolled'
    run_cmd sys_ssh_key "$ACC" m1 id -un
    assert_status 0
    run_cmd sys_ssh_key "$ACC" m2 id -un
    assert_status 0
}

test_a_docker_that_does_not_answer_is_reported() {
    sed -i -e "s/^$ID_ALICE \(.*\) exited\$/$ID_ALICE \1 running/" "$CONTAINERS"
    : >/run/impact-test-docker-down
    run_cmd sys_as_admin "$REMOVE" "$ACC" --yes
    rm -f /run/impact-test-docker-down
    assert_status 1
    assert_output_contains 'Docker does not answer'
    assert_output_contains 'The removal is not complete'
    # Every other step was done.
    assert_eq '1' "$(getent shadow "$ACC" | cut -d: -f8)" "expiry date"
    assert_missing "/home/$ACC/.ssh/authorized_keys"
    # With Docker back, a second run stops the container.
    run_cmd sys_as_admin "$REMOVE" "$ACC" --yes
    assert_status 0
    assert_output_contains "+ Stop the container Model_$ACC"
    assert_file_contains "$CONTAINERS" "$ID_ALICE $ACC Model_$ACC exited"
}

# ----------------------------------------------------------------------------
# --delete
# ----------------------------------------------------------------------------

test_delete_lists_the_files_first_and_asks_twice() {
    mkdir -p "$SYS_ROOT_A/Example-Model/outputs/analysis_1"
    printf 'result\n' >"$SYS_ROOT_A/Example-Model/outputs/analysis_1/table.csv"
    printf 'note\n' >"$SYS_ROOT_A/Example-Model/outputs/notes with blank.txt"
    chown -R "$ACC" "$SYS_ROOT_A/Example-Model/outputs/analysis_1" "$SYS_ROOT_A/Example-Model/outputs/notes with blank.txt"
    # Without a terminal: --yes does not answer the two questions, and the
    # message does not tell the administrator to add --yes.
    refused_without_change 1 sys_as_admin "$REMOVE" "$ACC" --delete --yes
    assert_output_contains 'A deletion is confirmed on a terminal only'
    assert_output_not_contains 'add the option --yes after checking'
    assert_output_contains "owns 3 files and folders on the shared storage"
    assert_output_contains "$SYS_ROOT_A/Example-Model/outputs/analysis_1/table.csv"
    assert_output_contains 'notes with blank.txt'
    assert_output_contains 'not confirmed'
    # The dry run lists the files too and changes nothing.
    refused_without_change 0 sys_as_admin "$REMOVE" "$ACC" --delete --dry-run
    assert_output_contains "[dry run] Delete the account '$ACC'"
    if ! command -v script >/dev/null 2>&1; then
        skip "the tool script (package bsdutils) is needed for the questions on the terminal"
    fi
    local before="$TEST_TMP/before" after="$TEST_TMP/after" output
    snapshot_take "$before" --content "${WATCHED[@]}"
    # First question answered with no; then yes and a wrong name.
    output="$(terminal_answers $'no\n' "$REMOVE $ACC --delete")"
    assert_contains "$output" 'Question 1 of 2'
    assert_contains "$output" 'not confirmed'
    output="$(terminal_answers $'yes\nolga-example\n' "$REMOVE $ACC --delete")"
    assert_contains "$output" 'Question 2 of 2'
    assert_contains "$output" 'the account name was not typed'
    snapshot_take "$after" --content "${WATCHED[@]}"
    snapshot_assert_same "$before" "$after" "refused deletions must change nothing"
    # Both questions answered.
    output="$(terminal_answers $'yes\n'"$ACC"$'\n' "$REMOVE $ACC --delete")"
    assert_contains "$output" "Delete the account '$ACC'"
    way_back_lines "$output" | tr -d '\r' >"$TEST_SUITE_TMP/way-back-deleted"
    assert_fails getent passwd "$ACC"
    assert_fails getent group "$ACC"
    assert_missing "/home/$ACC"
    # The files on the storage and the record stay.
    assert_eq "$(cat "$TEST_SUITE_TMP/uid")" "$(stat -c '%u' "$SYS_ROOT_A/Example-Model/outputs/analysis_1/table.csv")" "owner number of a file on the storage"
    assert_file_contains "/opt/impact/admin/accounts/$ACC.conf" 'STATE=removed'
}

test_after_delete_nothing_to_do_and_the_way_back_gives_the_old_number() {
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log "${WATCHED[@]}" -- \
        sys_as_admin "$REMOVE" "$ACC" --delete --yes
    assert_status 0
    assert_output_contains 'it was deleted earlier'
    local line
    line="$(head -n 1 "$TEST_SUITE_TMP/way-back-deleted")"
    assert_contains "$line" "--uid $(cat "$TEST_SUITE_TMP/uid")"
    run_printed_line "$line"
    assert_status 0
    assert_eq "$(cat "$TEST_SUITE_TMP/uid")" "$(id -u "$ACC")" "user number of the account made again"
    assert_eq "$ACC" "$(stat -c '%U' "$SYS_ROOT_A/Example-Model/outputs/analysis_1/table.csv")" "owner of the file on the storage"
    run_cmd sys_ssh_key "$ACC" m1 id -un
    assert_status 0
}
