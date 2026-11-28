#!/bin/bash
# =============================================================================
# users-10-add-user.test.sh: system tests for impact-add-user
#
# Purpose
#   Runs the installed impact-add-user as the stand-in administrator on a
#   prepared workstation with a real SSH server on 127.0.0.1. It proves:
#   wrong and hostile input and unaccepted key lines are refused before any
#   change; a dry run changes nothing and shows the same steps as the real
#   run; the fingerprint must be confirmed; the first run creates the
#   account with a locked password, the two groups, the key, the repository
#   folder and the record; a second run changes nothing; the new member can
#   log in with the key, a password login is refused, a tunnel reaches a
#   port of the range and no other port; the three key sources; adopting an
#   existing account; protected accounts; symbolic links and foreign owners
#   in a home folder; the option --uid.
#
# Who runs it
#   tests/workstation/run-tests.sh system   (root, disposable system only)
#
# Usage
#   sudo env IMPACT_TEST_DISPOSABLE=yes bash tests/workstation/run-tests.sh system --filter users-10
#
# What it changes on the system
#   The installed commands and their settings, test accounts, an SSH server
#   process, stand-in programs "curl" in /usr/local/sbin for the GitHub test
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
# shellcheck disable=SC2016
# Reason for SC2016 (no expansion in single quotes): many texts in this file
# are test data, or lines of small scripts that a test writes. They must stay
# exactly as written.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/testlib.sh"

ADD=/usr/local/bin/impact-add-user
LOG_FILE=/opt/impact/admin/log/impact-admin.log
# The person of the main tests: GitHub name and account name are the same.
GH='alice-example'
ACC='alice-example'
# The folders whose state the tests compare before and after a run.
WATCHED=(/etc/impact /opt/impact /srv/impact /home /etc/ssh/sshd_config.d /mnt/disk_a /mnt/disk_b /usr/local/sbin)
# Stand-in curl for the GitHub test (first folder of the commands' PATH).
FAKE_CURL=/usr/local/sbin/curl
FAKE_MARKER='# impact-test stand-in for curl'

suite_setup() {
    sys_clean_slate
    sys_storage_up
    sys_install
    sys_admin_create
    sys_sshd_start
    sys_setup
    local name
    for name in alice alice2 carol dave erin1 erin2 bob frank gina henry ivan; do
        sys_keypair "$name"
    done
    # A key of another type, for the refusal test.
    ssh-keygen -q -t rsa -b 2048 -N '' -C 'rsa@example-pc' -f "$TEST_SUITE_TMP/keys/rsa"
    for name in "$ACC" bob carol dave erin-example frank gina hacker henry ivan julia-example u1alice; do
        sys_register_account "$name"
    done
}

suite_teardown() {
    remove_fake_curl
    rm -rf /srv/impact-test-target
    sys_clean_slate
}

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# pub NAME
#   Prints the path of the public key of a test key pair.
pub() {
    printf '%s.pub\n' "$(sys_key_path "$1")"
}

# print_of NAME
#   Prints the SHA256 fingerprint of a test key.
print_of() {
    ssh-keygen -l -E sha256 -f "$(pub "$1")" | awk '{ print $2 }'
}

# blob_of NAME
#   Prints the key data (second word) of a test key.
blob_of() {
    awk '{ print $2 }' "$(pub "$1")"
}

# step_lines TEXT
#   Prints the lines of changing steps ("  + ..."), without the mark
#   "[dry run] ", so a dry run and a real run can be compared.
step_lines() {
    printf '%s\n' "$1" | sed -n -e 's/^  + \(\[dry run\] \)\{0,1\}//p'
}

# install_fake_curl
#   Puts a stand-in "curl" first in the commands' PATH. It answers requests
#   for https://github.com/<name>.keys from files in /run/impact-test-github:
#   <name>.keys gives status 200, a missing file 404, the name
#   offline-example a network failure. It proves how the command treats
#   GitHub's answers; the real download is tested by hand.
install_fake_curl() {
    mkdir -p /run/impact-test-github
    cat >"$FAKE_CURL" <<'END'
#!/bin/bash
# impact-test stand-in for curl
output=''
url=''
while (($# > 0)); do
    case "$1" in
        --output) output="$2"; shift 2 ;;
        --) url="$2"; shift 2 ;;
        *) shift ;;
    esac
done
name="${url#https://github.com/}"
name="${name%.keys}"
if [[ "$name" == 'offline-example' ]]; then
    printf '000'
    exit 6
fi
if [[ -f "/run/impact-test-github/$name.keys" ]]; then
    cp "/run/impact-test-github/$name.keys" "$output"
    printf '200'
    exit 0
fi
printf '404'
exit 22
END
    chmod 755 "$FAKE_CURL"
}

# remove_fake_curl
#   Removes the stand-in curl, when it is there.
remove_fake_curl() {
    if [[ -f "$FAKE_CURL" ]] && grep -q -F -- "$FAKE_MARKER" "$FAKE_CURL"; then
        rm -f -- "$FAKE_CURL"
    fi
    rm -rf /run/impact-test-github
}

# refused_without_change EXPECTED_CODE COMMAND...
#   Runs COMMAND, fails unless it ends with EXPECTED_CODE and leaves the
#   watched folders, the accounts and the groups unchanged.
refused_without_change() {
    local code="$1"
    shift
    snapshot_unchanged_by --content "${WATCHED[@]}" -- "$@"
    assert_status "$code"
}

# refused_with_input_without_change EXPECTED_CODE INPUT COMMAND...
#   As refused_without_change, with INPUT as standard input of COMMAND.
refused_with_input_without_change() {
    local code="$1" input="$2" before="$TEST_TMP/before.input" after="$TEST_TMP/after.input"
    shift 2
    snapshot_take "$before" --content "${WATCHED[@]}"
    run_cmd_with_input "$input" "$@"
    snapshot_take "$after" --content "${WATCHED[@]}"
    snapshot_assert_same "$before" "$after" "a refused key line must change nothing"
    assert_status "$code"
}

# ----------------------------------------------------------------------------
# Before the first enrolment
# ----------------------------------------------------------------------------

test_help_works_for_everyone_and_the_command_needs_root() {
    run_cmd runuser -u "$SYS_ADMIN" -- "$ADD" --help
    assert_status 0
    assert_output_contains 'Usage'
    assert_output_contains '--fingerprint'
    run_cmd runuser -u "$SYS_ADMIN" -- "$ADD" "$GH" --key-file "$(pub alice)" --dry-run
    assert_status 2
    assert_output_contains 'must run with administrator rights'
}

test_wrong_and_hostile_input_is_refused_before_any_change() {
    local key
    key="$(pub alice)"
    rm -f /tmp/impact-test-hostile
    # GitHub names.
    local name
    for name in 'alice example' "alice'x" 'alice;id' '$(touch /tmp/impact-test-hostile)' '../alice' \
        'alice"' '' 'a/b' '-alice-' "$(printf 'x%.0s' {1..40})"; do
        refused_without_change 2 sys_as_admin "$ADD" --key-file "$key" -- "$name"
        assert_output_contains 'is no valid GitHub name'
    done
    # Account names.
    for name in 'Alice' 'a b' '../root' 'root;id' '$(touch /tmp/impact-test-hostile)' '1alice' ''; do
        refused_without_change 2 sys_as_admin "$ADD" "$GH" --account "$name" --key-file "$key"
    done
    # User numbers.
    for name in 0 999 60001 abc '1005;id' '' 01005; do
        refused_without_change 2 sys_as_admin "$ADD" "$GH" --uid "$name" --key-file "$key"
    done
    # Fingerprints.
    for name in 'SHA256:short' 'MD5:aa:bb' '$(id)' ''; do
        refused_without_change 2 sys_as_admin "$ADD" "$GH" --fingerprint "$name" --key-file "$key"
    done
    # Options.
    refused_without_change 2 sys_as_admin "$ADD" "$GH" --github --key-file "$key"
    refused_without_change 2 sys_as_admin "$ADD" "$GH" --key-file "$key" --unknown
    refused_without_change 2 sys_as_admin "$ADD" "$GH" -y --key-file "$key"
    refused_without_change 2 sys_as_admin "$ADD" "$GH" other --key-file "$key"
    refused_without_change 2 sys_as_admin "$ADD" --key-file "$key"
    refused_without_change 2 sys_as_admin "$ADD" "$GH" --existing=yes --key-file "$key"
    assert_missing /tmp/impact-test-hostile
}

test_unaccepted_key_lines_are_refused_before_any_change() {
    local good rsa
    good="$(cat -- "$(pub alice)")"
    rsa="$(cat -- "$(pub rsa)")"
    # A key line with options in front: such a line could run a command or
    # open forwarding for the person.
    refused_with_input_without_change 2 "command=\"/bin/sh\",no-pty $good" sys_as_admin "$ADD" "$GH"
    assert_output_contains 'options before the key type'
    run_cmd_with_input "restrict,port-forwarding $good" sys_as_admin "$ADD" "$GH"
    assert_status 2
    # Two keys on two lines, and two keys on one line.
    refused_with_input_without_change 2 "$good"$'\n'"$(cat -- "$(pub alice2)")" sys_as_admin "$ADD" "$GH"
    assert_output_contains 'Exactly one public key'
    refused_with_input_without_change 2 "$good $(cat -- "$(pub alice2)")" sys_as_admin "$ADD" "$GH"
    assert_output_contains 'second key'
    # Another key type, a private key, a damaged line, nothing.
    refused_with_input_without_change 2 "$rsa" sys_as_admin "$ADD" "$GH"
    assert_output_contains "type 'ssh-rsa'"
    refused_without_change 2 sys_as_admin "$ADD" "$GH" --key-file "$(sys_key_path alice)"
    assert_output_contains 'PRIVATE key'
    refused_with_input_without_change 2 "${good:0:60}" sys_as_admin "$ADD" "$GH"
    refused_without_change 2 sys_as_admin "$ADD" "$GH"
    assert_output_contains 'No key was given'
    # Key files: missing, a folder, a path with a blank, too large.
    refused_without_change 1 sys_as_admin "$ADD" "$GH" --key-file /nonexistent/alice.pub
    refused_without_change 2 sys_as_admin "$ADD" "$GH" --key-file "$TEST_SUITE_TMP/keys"
    cp -- "$(pub alice)" "$TEST_TMP/alice key.pub"
    refused_without_change 2 sys_as_admin "$ADD" "$GH" --key-file "$TEST_TMP/alice key.pub"
    head -c 70000 /dev/zero >"$TEST_TMP/large.pub"
    refused_without_change 2 sys_as_admin "$ADD" "$GH" --key-file "$TEST_TMP/large.pub"
    # A link to a file that is no key is followed and refused as no key.
    ln -s /etc/shadow "$TEST_TMP/shadow.pub"
    refused_without_change 2 sys_as_admin "$ADD" "$GH" --key-file "$TEST_TMP/shadow.pub"
    assert_output_not_contains 'root:'
}

test_names_that_conflict_are_refused_before_any_change() {
    # A GitHub name that is the name of an existing group.
    refused_without_change 4 sys_as_admin "$ADD" docker --key-file "$(pub alice)"
    assert_output_contains '--account'
    # A GitHub name that cannot be a Linux name. The suggested account name
    # follows the rules (a letter first, at most 32 characters).
    refused_without_change 2 sys_as_admin "$ADD" 1Alice-Example --key-file "$(pub alice)"
    assert_output_contains 'for example --account u1alice-example'
    refused_without_change 2 sys_as_admin "$ADD" 1alice --key-file "$(pub alice)"
    assert_output_contains 'for example --account u1alice.'
    refused_without_change 2 sys_as_admin "$ADD" "1$(printf 'a%.0s' {1..37})" --key-file "$(pub alice)"
    assert_output_contains "for example --account u1$(printf 'a%.0s' {1..30})."
    # The home folder of a new account exists already.
    mkdir /home/erin-example
    refused_without_change 4 sys_as_admin "$ADD" erin-example --key-file "$(pub erin1)"
    assert_output_contains 'exists already'
    rmdir /home/erin-example
    # --existing for an account that does not exist.
    refused_without_change 4 sys_as_admin "$ADD" "$GH" --existing --key-file "$(pub alice)"
    # A user number that is in use.
    refused_without_change 4 sys_as_admin "$ADD" "$GH" --uid "$(id -u "$SYS_ADMIN")" --key-file "$(pub alice)"
    assert_output_contains "in use by the account '$SYS_ADMIN'"
}

test_a_second_command_on_accounts_waits_for_the_first() {
    # Another command holds the lock "accounts" (impact-add-user, impact-key
    # and impact-remove-user share it).
    install -d -m 700 /run/impact
    exec {lock_handle}>>/run/impact/accounts.lock
    flock -n "$lock_handle"
    refused_without_change 4 sys_as_admin "$ADD" "$GH" --key-file "$(pub alice)" --fingerprint "$(print_of alice)"
    assert_output_contains 'Another IMPACT command that changes the same things is running'
    flock -u "$lock_handle"
    exec {lock_handle}>&-
}

# ----------------------------------------------------------------------------
# The first enrolment
# ----------------------------------------------------------------------------

test_dry_run_changes_nothing() {
    refused_without_change 0 sys_as_admin "$ADD" "$GH" --key-file "$(pub alice)" --fingerprint "$(print_of alice)" --dry-run
    assert_output_contains 'DRY RUN'
    assert_output_contains "[dry run] Create the account '$ACC'"
    assert_output_contains "[dry run] Add '$ACC' to the group 'impact'"
    assert_output_contains "[dry run] Add '$ACC' to the group 'docker'"
    assert_output_contains '[dry run] Install the key'
    assert_output_contains "[dry run] Create the repository folder /home/$ACC/Repositories"
    assert_output_contains 'A real run asks sshd here'
    step_lines "$RUN_OUTPUT" >"$TEST_SUITE_TMP/dry-run-steps"
    assert_missing "/home/$ACC"
}

test_the_fingerprint_must_be_confirmed() {
    # --yes does not answer the fingerprint question, and there is no
    # terminal to ask on.
    refused_without_change 1 sys_as_admin "$ADD" "$GH" --key-file "$(pub alice)" --yes
    assert_output_contains 'fingerprint of the key was not confirmed'
    # The hint names the option that answers this question, and does not
    # send the administrator to --yes, which was given.
    assert_output_contains 'or add --fingerprint <the fingerprint the person sent>'
    assert_output_not_contains 'add the option --yes after checking'
    # A fingerprint that belongs to another key.
    refused_without_change 1 sys_as_admin "$ADD" "$GH" --key-file "$(pub alice)" --fingerprint "$(print_of alice2)"
    assert_output_contains "has the fingerprint $(print_of alice2)"
    if ! command -v script >/dev/null 2>&1; then
        skip "the tool script (package bsdutils) is needed for the terminal part"
    fi
    # A terminal on which the administrator answers "no".
    local before="$TEST_TMP/before" after="$TEST_TMP/after" output
    snapshot_take "$before" --content "${WATCHED[@]}"
    output="$(printf 'no\n' | timeout 60 script -q -e -c "runuser -u $SYS_ADMIN -- sudo -n -- $ADD $GH --key-file $(pub alice)" /dev/null 2>&1)" || true
    snapshot_take "$after" --content "${WATCHED[@]}"
    snapshot_assert_same "$before" "$after" "answering no must change nothing"
    assert_contains "$output" 'Is it exactly the same?'
    assert_contains "$output" "$(print_of alice)"
    assert_contains "$output" 'not confirmed'
}

test_first_run_enrols_the_person() {
    run_cmd sys_as_admin "$ADD" "$GH" --key-file "$(pub alice)" --fingerprint "$(print_of alice)"
    assert_status 0
    assert_output_contains "+ Create the account '$ACC'"
    assert_output_contains 'Membership in the group docker gives the same power as root'
    assert_output_contains "sshd -T: '$ACC' gets the restricted values"
    assert_output_contains 'text for the colleague, begin'
    assert_output_contains "Workstation account: $ACC"
    assert_output_contains "Enrolled key:        $(print_of alice)"
    assert_output_contains "$SYS_ADMIN_CONTACT"
    # The real run shows exactly the steps of the dry run, in the same order.
    assert_eq "$(cat -- "$TEST_SUITE_TMP/dry-run-steps")" "$(step_lines "$RUN_OUTPUT")" "steps of the dry run and of the real run"
    # The account.
    local uid
    uid="$(id -u "$ACC")"
    assert_success impact_valid_user_number_test "$uid"
    assert_eq "$ACC:x:$uid:" "$(getent passwd "$ACC" | cut -d: -f1-3):" "passwd entry"
    assert_eq '/bin/bash' "$(getent passwd "$ACC" | cut -d: -f7)" "login shell"
    assert_eq 'L' "$(passwd -S "$ACC" | awk '{ print $2 }')" "password state (L = locked)"
    assert_contains " $(id -nG "$ACC") " ' impact ' "groups"
    assert_contains " $(id -nG "$ACC") " ' docker ' "groups"
    # The key, written as the person.
    assert_file_facts "/home/$ACC/.ssh" 700 "$ACC" "$ACC"
    assert_file_facts "/home/$ACC/.ssh/authorized_keys" 600 "$ACC" "$ACC"
    assert_eq "ssh-ed25519 $(blob_of alice) alice@example-pc" "$(cat "/home/$ACC/.ssh/authorized_keys")" "authorized_keys"
    # The repository folder, the record and the copy of the key.
    assert_file_facts "/home/$ACC/Repositories" 750 "$ACC" "$ACC"
    assert_file_facts "/opt/impact/admin/accounts/$ACC.conf" 600 root root
    assert_file_contains "/opt/impact/admin/accounts/$ACC.conf" "GITHUB_NAME=$GH"
    assert_file_contains "/opt/impact/admin/accounts/$ACC.conf" "USER_NUMBER=$uid"
    assert_file_contains "/opt/impact/admin/accounts/$ACC.conf" 'STATE=enrolled'
    local copy
    copy="/opt/impact/admin/keys/$ACC/received/$(print_of alice | sed -e 's/^SHA256:/SHA256_/' -e 's#/#_#g' -e 's/+/-/g').pub"
    assert_file_facts "$copy" 600 root root
    assert_file_contains "$copy" "$(blob_of alice)"
}

# impact_valid_user_number_test NUMBER
#   Yes when NUMBER is a user number of a person (1000 to 60000).
impact_valid_user_number_test() {
    [[ "$1" =~ ^[0-9]+$ ]] && (($1 >= 1000 && $1 <= 60000))
}

test_the_log_holds_the_fingerprint_and_never_the_key() {
    assert_file_contains "$LOG_FILE" "command: impact-add-user $GH --key-file"
    assert_file_contains "$LOG_FILE" "key fingerprint: $(print_of alice)"
    assert_file_contains "$LOG_FILE" "Create the account '$ACC'"
    assert_file_not_contains "$LOG_FILE" "$(blob_of alice)"
    # The dry run and the refused runs wrote no block: one block of this
    # command so far.
    assert_eq 1 "$(grep -c '^command: impact-add-user' "$LOG_FILE")" "log blocks of impact-add-user"
}

test_second_run_changes_nothing() {
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log "${WATCHED[@]}" -- \
        sys_as_admin "$ADD" "$GH" --key-file "$(pub alice)" --fingerprint "$(print_of alice)"
    assert_status 0
    assert_output_contains 'Nothing to do'
    assert_output_not_contains '  + '
    # The same without --fingerprint and without a terminal: the key is
    # installed already, so nothing has to be confirmed.
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log "${WATCHED[@]}" -- \
        sys_as_admin "$ADD" "$GH" --key-file "$(pub alice)"
    assert_status 0
    assert_output_contains 'Nothing to do'
}

# ----------------------------------------------------------------------------
# The new member on the real SSH server
# ----------------------------------------------------------------------------

test_the_member_gets_the_restricted_ssh_values() {
    local effective
    effective="$(sys_effective_ssh "$ACC")"
    assert_contains "$effective" 'authenticationmethods publickey'
    assert_contains "$effective" 'passwordauthentication no'
    assert_contains "$effective" 'kbdinteractiveauthentication no'
    assert_contains "$effective" 'allowtcpforwarding local'
    assert_contains "$effective" 'permitopen 127.0.0.1:8787 127.0.0.1:8788'
    assert_contains "$effective" '127.0.0.1:8830'
    assert_not_contains "$effective" '127.0.0.1:8831'
    assert_contains "$effective" 'x11forwarding no'
    assert_contains "$effective" 'permittunnel no'
    assert_contains "$effective" 'clientaliveinterval 60'
}

test_key_login_works_and_password_login_is_refused() {
    run_cmd sys_ssh_key "$ACC" alice id -un
    assert_status 0
    assert_eq "$ACC" "$RUN_OUTPUT" "account of the key login"
    assert_eq 'publickey' "$(sys_ssh_offered_methods "$ACC")" "login methods the server offers to the member"
    # Even with a password set (by mistake), a password login is refused.
    sys_set_password "$ACC" 'Member-Test-Pass-58'
    run_cmd sys_ssh_password "$ACC" 'Member-Test-Pass-58' id -un
    usermod --lock -- "$ACC"
    assert_status 255
    assert_output_contains 'Permission denied'
    assert_eq 'L' "$(passwd -S "$ACC" | awk '{ print $2 }')" "password state after the test"
    # A key that is not enrolled is refused.
    run_cmd sys_ssh_key "$ACC" alice2 id -un
    assert_status 255
}

test_a_tunnel_reaches_the_port_range_and_no_other_port() {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 is needed for the small web servers of this test"
    fi
    mkdir -p "$TEST_TMP/www"
    printf 'answer of the container port\n' >"$TEST_TMP/www/index.html"
    python3 -m http.server 8787 --bind 127.0.0.1 --directory "$TEST_TMP/www" >/dev/null 2>&1 &
    local inside_pid=$!
    python3 -m http.server 8999 --bind 127.0.0.1 --directory "$TEST_TMP/www" >/dev/null 2>&1 &
    local outside_pid=$!
    local -a SYS_SSH_OPTIONS=()
    sys__ssh_options
    # The tunnel as the GUI starts it: -N no command, -L a local port to a
    # port on the workstation itself.
    ssh "${SYS_SSH_OPTIONS[@]}" -N -T -o BatchMode=yes -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes \
        -i "$(sys_key_path alice)" -L 127.0.0.1:18787:127.0.0.1:8787 -L 127.0.0.1:18999:127.0.0.1:8999 \
        "$ACC@127.0.0.1" </dev/null >"$TEST_TMP/tunnel.log" 2>&1 &
    local tunnel_pid=$!
    sleep 3
    local allowed refused
    allowed="$(curl --noproxy '*' --silent --max-time 5 http://127.0.0.1:18787/ || true)"
    refused="$(curl --noproxy '*' --silent --max-time 5 http://127.0.0.1:18999/ || true)"
    kill "$tunnel_pid" "$inside_pid" "$outside_pid" 2>/dev/null || true
    wait 2>/dev/null || true
    assert_eq 'answer of the container port' "$allowed" "answer through the tunnel to port 8787 (inside the range)"
    assert_eq '' "$refused" "a tunnel to port 8999 (outside the range) must be refused"
    # The SSH server notes the refusal in its own log.
    assert_file_contains "$SYS_SSHD_LOG" 'to connect to host 127.0.0.1 port 8999, but the request was denied'
}

# ----------------------------------------------------------------------------
# Further key sources and accounts
# ----------------------------------------------------------------------------

test_the_terminal_confirmation_enrols_a_person() {
    if ! command -v script >/dev/null 2>&1; then
        skip "the tool script (package bsdutils) is not installed"
    fi
    local output
    output="$(printf 'yes\n' | timeout 120 script -q -e -c "runuser -u $SYS_ADMIN -- sudo -n -- $ADD carol --key-file $(pub carol)" /dev/null 2>&1)" || true
    assert_contains "$output" 'Is it exactly the same?'
    assert_contains "$output" 'The fingerprint was confirmed.'
    assert_eq "ssh-ed25519 $(blob_of carol) carol@example-pc" "$(cat /home/carol/.ssh/authorized_keys)" "key of carol"
}

test_the_key_on_standard_input_is_accepted() {
    # Windows line ends and blanks around the line are tolerated.
    run_cmd_with_input "  $(cat -- "$(pub dave)")"$'\r' sys_as_admin "$ADD" dave --fingerprint "$(print_of dave)"
    assert_status 0
    assert_output_contains 'Key from standard input'
    assert_eq "ssh-ed25519 $(blob_of dave) dave@example-pc" "$(cat /home/dave/.ssh/authorized_keys)" "key of dave"
}

test_keys_from_github() {
    install_fake_curl
    {
        cat -- "$(pub rsa)"
        awk '{ print $1, $2 }' "$(pub erin1)"
        awk '{ print $1, $2 }' "$(pub erin2)"
    } >/run/impact-test-github/erin-example.keys
    cat -- "$(pub rsa)" >/run/impact-test-github/rsa-only.keys
    # Two ed25519 keys: the command lists both and needs --fingerprint.
    refused_without_change 2 sys_as_admin "$ADD" erin-example --github
    assert_output_contains "$(print_of erin1)"
    assert_output_contains "$(print_of erin2)"
    assert_output_contains '--fingerprint'
    # GitHub has no such account; GitHub cannot be reached; no ed25519 key.
    refused_without_change 5 sys_as_admin "$ADD" nobody-example --github
    assert_output_contains 'status 404: it has no account named'
    refused_without_change 6 sys_as_admin "$ADD" offline-example --github
    refused_without_change 1 sys_as_admin "$ADD" rsa-only --github
    assert_output_contains 'no key of the type ssh-ed25519'
    # The fingerprint chooses the second key.
    run_cmd sys_as_admin "$ADD" erin-example --github --fingerprint "$(print_of erin2)"
    remove_fake_curl
    assert_status 0
    assert_output_contains 'Key from GitHub (https://github.com/erin-example.keys)'
    assert_eq "ssh-ed25519 $(blob_of erin2) erin-example" "$(cat /home/erin-example/.ssh/authorized_keys)" "key of erin"
}

test_an_existing_account_is_adopted() {
    sys_account_add bob
    sys_set_password bob 'Bob-Test-Pass-44'
    usermod --shell /bin/sh bob
    # Locking the password needs a confirmation: refused without a terminal.
    refused_without_change 1 sys_as_admin "$ADD" bob-example --account bob --existing --key-file "$(pub bob)" --fingerprint "$(print_of bob)"
    assert_output_contains 'password lock was not confirmed'
    # Without --existing the account is not touched.
    refused_without_change 4 sys_as_admin "$ADD" bob-example --account bob --key-file "$(pub bob)" --fingerprint "$(print_of bob)"
    assert_output_contains '--existing'
    run_cmd sys_as_admin "$ADD" bob-example --account bob --existing --key-file "$(pub bob)" --fingerprint "$(print_of bob)" --yes
    assert_status 0
    assert_output_contains "Set the login shell of 'bob' to /bin/bash (it was /bin/sh)"
    assert_output_contains "Lock the password of 'bob'"
    assert_eq 'L' "$(passwd -S bob | awk '{ print $2 }')" "password state of bob"
    assert_eq '/bin/bash' "$(getent passwd bob | cut -d: -f7)" "shell of bob"
    assert_contains " $(id -nG bob) " ' impact '
    run_cmd sys_ssh_key bob bob id -un
    assert_status 0
    run_cmd sys_ssh_password bob 'Bob-Test-Pass-44' id -un
    assert_status 255
    # A second run changes nothing.
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log "${WATCHED[@]}" -- \
        sys_as_admin "$ADD" bob-example --account bob --existing --key-file "$(pub bob)" --fingerprint "$(print_of bob)"
    assert_status 0
    assert_output_contains 'Nothing to do'
}

test_protected_accounts_are_refused() {
    local name
    # The administrator itself, root, a system account.
    for name in "$SYS_ADMIN" root daemon; do
        refused_without_change 4 sys_as_admin "$ADD" protected-example --account "$name" --existing --key-file "$(pub frank)" --yes
    done
    assert_eq '' "$(id -nG "$SYS_ADMIN" | tr ' ' '\n' | grep -x impact || true)" "the administrator is no member"
    # An account with sudo rights is an administration account.
    sys_account_add hacker sudo
    refused_without_change 4 sys_as_admin "$ADD" hacker --existing --key-file "$(pub frank)" --yes
    assert_output_contains "member of the group 'sudo'"
    # One GitHub name, one account.
    refused_without_change 4 sys_as_admin "$ADD" "$GH" --account frank --key-file "$(pub frank)"
    assert_output_contains 'enrolled already'
    # An account that belongs to another GitHub name.
    refused_without_change 4 sys_as_admin "$ADD" someone-else --account "$ACC" --key-file "$(pub frank)"
}

test_links_and_foreign_owners_in_the_home_folder_are_refused() {
    sys_account_add frank
    mkdir -p /srv/impact-test-target
    printf 'original content\n' >/srv/impact-test-target/authorized_keys
    local -a args=(frank-example --account frank --existing --key-file "$(pub frank)" --fingerprint "$(print_of frank)")
    # ~/.ssh is a symbolic link to a folder of root.
    ln -s /srv/impact-test-target /home/frank/.ssh
    refused_without_change 1 sys_as_admin "$ADD" "${args[@]}"
    assert_output_contains 'symbolic link'
    rm /home/frank/.ssh
    # ~/.ssh/authorized_keys is a symbolic link to a file of root.
    install -d -m 700 -o frank -g frank /home/frank/.ssh
    ln -s /srv/impact-test-target/authorized_keys /home/frank/.ssh/authorized_keys
    refused_without_change 1 sys_as_admin "$ADD" "${args[@]}"
    rm /home/frank/.ssh/authorized_keys
    # ~/.ssh belongs to root.
    chown root:root /home/frank/.ssh
    refused_without_change 1 sys_as_admin "$ADD" "${args[@]}"
    chown frank:frank /home/frank/.ssh
    # The repository folder is a symbolic link.
    ln -s /srv/impact-test-target /home/frank/Repositories
    refused_without_change 1 sys_as_admin "$ADD" "${args[@]}"
    assert_output_contains 'symbolic link'
    rm /home/frank/Repositories
    assert_eq 'original content' "$(cat /srv/impact-test-target/authorized_keys)" "the target of the links"
    assert_eq 'authorized_keys' "$(ls /srv/impact-test-target)" "nothing new in the target folder"
    # With the links gone, the adoption works.
    run_cmd sys_as_admin "$ADD" "${args[@]}"
    assert_status 0
    assert_file_facts /home/frank/.ssh/authorized_keys 600 frank frank
}

test_the_user_number_can_be_given() {
    local number=41234
    while getent passwd "$number" >/dev/null || getent group "$number" >/dev/null; do
        number=$((number + 1))
    done
    run_cmd sys_as_admin "$ADD" gina --uid "$number" --key-file "$(pub gina)" --fingerprint "$(print_of gina)"
    assert_status 0
    assert_eq "$number" "$(id -u gina)" "user number of gina"
    # --uid for an existing account must name its own number.
    refused_without_change 4 sys_as_admin "$ADD" gina --existing --uid "$((number + 1))" --key-file "$(pub gina)"
    assert_output_contains 'never changed'
    snapshot_unchanged_by --content --exclude /opt/impact/admin/log "${WATCHED[@]}" -- \
        sys_as_admin "$ADD" gina --uid "$number" --key-file "$(pub gina)" --fingerprint "$(print_of gina)"
    assert_status 0
}

# ----------------------------------------------------------------------------
# An SSH setting that overrides the rules, and an enrolment that continues
# ----------------------------------------------------------------------------

# A file that sshd reads before 60-impact.conf gives the new account free
# forwarding. The command must notice it (sshd -T) before the login key is
# installed, name that file, and stop: the account then has no key and
# cannot log in. The account record says "enrolling", so the same command
# continues later without --existing, and impact-remove-user accepts the
# account in the meantime.
test_ssh_rules_that_do_not_apply_stop_before_the_key() {
    printf 'Match User henry\n    AllowTcpForwarding yes\n    PermitOpen any\n' >/etc/ssh/sshd_config.d/10-test-site.conf
    run_cmd sys_as_admin "$ADD" henry --key-file "$(pub henry)" --fingerprint "$(print_of henry)"
    assert_status 1
    assert_output_contains "The SSH rules do not apply to 'henry' as expected"
    assert_output_contains 'No login key was installed, so the account cannot log in yet.'
    assert_output_contains '/etc/ssh/sshd_config.d/10-test-site.conf'
    assert_output_contains 'allowtcpforwarding: expected "local", effective "yes"'
    assert_output_not_contains 'Install the key'
    assert_missing /home/henry/.ssh/authorized_keys
    assert_file_contains /opt/impact/admin/accounts/henry.conf 'STATE=enrolling'
    # The partial summary names one undo line that works for this state.
    assert_output_contains 'sudo impact-remove-user henry'
    assert_output_not_contains 'gpasswd'
    # The list of accounts shows the unfinished enrolment; impact-key
    # refuses the account until the enrolment is finished.
    run_cmd sys_as_admin impact-list-users
    assert_output_contains 'enrolment not finished'
    run_cmd sys_as_admin impact-key add henry --key-file "$(pub henry)" --fingerprint "$(print_of henry)"
    assert_status 4
    assert_output_contains 'is not finished'
    # impact-remove-user accepts the account (dry run here; it ends with 1
    # only because no Docker daemon answers in this file).
    run_cmd sys_as_admin impact-remove-user henry --dry-run
    assert_output_contains "record state 'enrolling'"
    assert_output_contains "[dry run] Set the account 'henry' to expired"
    # After the cause is fixed, the same command continues the enrolment.
    rm -f /etc/ssh/sshd_config.d/10-test-site.conf
    run_cmd sys_as_admin "$ADD" henry --key-file "$(pub henry)" --fingerprint "$(print_of henry)"
    assert_status 0
    assert_output_contains 'this run continues the enrolment'
    assert_output_contains "sshd -T: 'henry' gets the restricted values"
    assert_output_contains 'Install the key'
    assert_file_contains /opt/impact/admin/accounts/henry.conf 'STATE=enrolled'
    run_cmd sys_ssh_key henry henry id -un
    assert_status 0
    assert_eq 'henry' "$RUN_OUTPUT"
}

# For an account that the command created, "How to undo" names one command,
# impact-remove-user, which takes the account out of the groups and moves the
# key away as well. Separate lines for these steps would fail after it.
# Followed literally (with --yes in place of the answer on the terminal),
# it closes the account.
test_undo_of_a_new_account_is_one_working_command() {
    run_cmd sys_as_admin "$ADD" ivan --key-file "$(pub ivan)" --fingerprint "$(print_of ivan)"
    assert_status 0
    local undo
    undo="$(sed -n -e '/^How to undo:$/,/^[^ ]/p' <<<"$RUN_OUTPUT" | grep '^  - ' || true)"
    assert_eq 1 "$(printf '%s\n' "$undo" | grep -c .)" "number of undo lines"
    assert_contains "$undo" ': sudo impact-remove-user ivan'
    assert_not_contains "$undo" 'gpasswd'
    assert_not_contains "$undo" 'impact-key remove'
    # (Exit code 1 only because no Docker daemon answers in this file; every
    # other step runs.)
    run_cmd sys_as_admin impact-remove-user ivan --yes
    assert_output_contains "Note the state 'removed'"
    assert_file_contains /opt/impact/admin/accounts/ivan.conf 'STATE=removed'
    run_cmd sys_ssh_key ivan ivan id -un
    assert_status 255
}

# One key pair belongs to one person: the key of an enrolled colleague is
# refused for another account (exit code 4), before anything changes.
test_the_key_of_another_account_is_refused() {
    refused_without_change 4 sys_as_admin "$ADD" julia-example --key-file "$(pub alice)" --fingerprint "$(print_of alice)"
    assert_output_contains "is a login key of the account $ACC already"
    assert_fails getent passwd julia-example
}
