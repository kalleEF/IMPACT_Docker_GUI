#!/bin/bash
# =============================================================================
# repos-30-signals.test.sh: impact-get-repo stopped by a signal during the
# clone
#
# Purpose
#   The GUI starts impact-get-repo over SSH. When the session closes (signal
#   HUP) or the process is asked to end (signal TERM) while git is copying,
#   the whole process group gets the signal. This file proves that the
#   command then still prints "was interrupted (signal ...)" on its error
#   channel, removes the unfinished copy, and ends with exit code 128 plus
#   the signal number and the result line "reason=interrupted". (git's
#   error channel goes into a file during the clone; the messages of the
#   end of the command must not land there.)
#   The copy goes to a listener on 127.0.0.1 that accepts the connection
#   and never answers, so git is sure to be waiting when the signal comes.
#   The last test types Ctrl+C on a pseudo terminal (a terminal made by a
#   program, here python3) while impact-give-repo runs impact-get-repo for
#   the person: every message of impact-get-repo must still reach the
#   administrator inside the frame, the frame is closed, and then
#   impact-give-repo reports its own interruption.
#
# Who runs it
#   tests/workstation/run-tests.sh system   (root, disposable system only)
#
# Usage
#   sudo env IMPACT_TEST_DISPOSABLE=yes bash tests/workstation/run-tests.sh system --filter repos-30
#
# What it changes on the system
#   The installed commands and their settings, the model Hang-Model, the
#   test account alice with a key copy, a listener on 127.0.0.1:2299 while
#   the file runs, one log block of impact-give-repo.
#
# How to undo
#   The file removes everything it created (suite_teardown).
# =============================================================================

# Reading help: the bash constructs used here are explained at the top of
# ../lib/testlib.sh ("Reading help") and where they are first used.

# The lines for the checking tool "shellcheck" stand before the first command
# of the file and therefore count for the whole file.
# shellcheck disable=SC2016
# Reason for SC2016 (no expansion in single quotes): the small scripts that
# start the commands must expand $$ and their arguments themselves.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/testlib.sh"

GET=/usr/local/bin/impact-get-repo
GIVE=/usr/local/bin/impact-give-repo
MODEL=Hang-Model
PORT=2299
COPY=/home/alice/Repositories/Hang-Model

suite_setup() {
    sys_clean_slate
    sys_storage_up
    sys_install
    sys_admin_create
    sys_setup
    run_cmd sys_as_admin impact-add-model "$MODEL" git@github.com:hang-org/Hang-Model.git \
        --storage "$SYS_ROOT_A" --storage-name Hang
    if [[ "$RUN_STATUS" != '0' ]]; then
        show_run
        fail "impact-add-model failed"
    fi
    sys_account_add alice "$SYS_GROUP"
    # A key copy, so the command takes the way over SSH.
    sys_keypair alice
    install -d -m 700 -o alice -g alice /home/alice/.ssh
    install -m 600 -o alice -g alice "$(sys_key_path alice)" /home/alice/.ssh/id_ed25519_alice-example
    # alice's own git settings lead the address to the silent listener.
    # "cd /" first: git needs a current folder that alice may enter.
    (cd / && runuser -u alice -- git config --file /home/alice/.gitconfig \
        url."ssh://git@127.0.0.1:$PORT/".insteadOf 'git@github.com:hang-org/')
    # The listener: it accepts connections (the kernel does that for the
    # waiting list of "listen") and never sends a byte.
    python3 -c '
import socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(16)
time.sleep(1800)
' "$PORT" >/dev/null 2>&1 &
    printf '%s\n' "$!" >"$TEST_SUITE_TMP/listener.pid"
}

suite_teardown() {
    if [[ -f "$TEST_SUITE_TMP/listener.pid" ]]; then
        kill "$(cat -- "$TEST_SUITE_TMP/listener.pid")" 2>/dev/null || true
    fi
    sys_clean_slate
}

# run_and_signal SIGNAL
#   Starts impact-get-repo as alice in a session of its own (setsid), as a
#   login over SSH has one, waits until git has started and the unfinished
#   copy exists, then sends SIGNAL to the whole process group (the command,
#   git and ssh), as a closed session does. Waits for the end and sets
#   RUN_STATUS and RUN_OUTPUT like run_cmd. The output of the error channel
#   is kept apart in ERROR_OUTPUT.
run_and_signal() {
    local signal="$1" waited=0 group='' note="$TEST_SUITE_TMP/alice/group"
    # A folder that alice may write, for the number of the process group.
    install -d -m 700 -o alice -g alice "$TEST_SUITE_TMP/alice"
    rm -f -- "$note" "$TEST_SUITE_TMP/out" "$TEST_SUITE_TMP/err"
    # The inner bash notes its own process number ($$), which is the number
    # of the new process group, and becomes the command itself ("exec").
    # The command starts in "/", a folder that alice may enter; "exec"
    # makes the background shell runuser itself, so $! is its number.
    (cd / && exec runuser -u alice -- env -i HOME=/home/alice USER=alice LOGNAME=alice SHELL=/bin/bash \
        PATH=/usr/local/bin:/usr/bin:/bin setsid --wait bash -c 'echo "$$" >"$1"; exec "$2" "$3"' \
        _ "$note" "$GET" "$MODEL") >"$TEST_SUITE_TMP/out" 2>"$TEST_SUITE_TMP/err" &
    local pid=$!
    until [[ -s "$note" ]] && pgrep -g "$(cat -- "$note")" -x ssh >/dev/null 2>&1 &&
        [[ -e "$COPY.partial" ]]; do
        sleep 0.1
        waited=$((waited + 1))
        if ((waited > 150)) || ! kill -0 "$pid" 2>/dev/null; then
            cat -- "$TEST_SUITE_TMP/out" "$TEST_SUITE_TMP/err" >&2
            fail "git did not start its connection in time"
        fi
    done
    group="$(cat -- "$note")"
    # "kill -s SIGNAL -- -N" sends the signal to every process of group N.
    kill -s "$signal" -- "-$group"
    RUN_STATUS=0
    wait "$pid" || RUN_STATUS=$?
    RUN_OUTPUT="$(cat -- "$TEST_SUITE_TMP/out" "$TEST_SUITE_TMP/err")"
    ERROR_OUTPUT="$(cat -- "$TEST_SUITE_TMP/err")"
    LAST_LINE="$(tail -n 1 -- "$TEST_SUITE_TMP/out")"
}

# A closed session (HUP) during the clone: the message reaches the error
# channel, the unfinished copy is removed, and the result line says
# "interrupted" with exit code 129.
test_closed_session_during_the_clone_is_reported() {
    run_and_signal HUP
    assert_status 129
    assert_contains "$ERROR_OUTPUT" 'ERROR: impact-get-repo was interrupted (signal HUP).'
    assert_matches "$LAST_LINE" '^IMPACT_RESULT status=error code=129 path=[A-Za-z0-9._/-]* reason=interrupted$' "last line"
    assert_missing "$COPY.partial"
    assert_missing "$COPY"
}

# A request to end (TERM) during the clone: the same, with exit code 143.
test_request_to_end_during_the_clone_is_reported() {
    run_and_signal TERM
    assert_status 143
    assert_contains "$ERROR_OUTPUT" 'ERROR: impact-get-repo was interrupted (signal TERM).'
    assert_matches "$LAST_LINE" '^IMPACT_RESULT status=error code=143 path=[A-Za-z0-9._/-]* reason=interrupted$' "last line"
    assert_missing "$COPY.partial"
    assert_missing "$COPY"
}

# write_pty_driver FILE
#   Writes a small python3 program to FILE. It starts a command on a new
#   pseudo terminal, waits until the unfinished copy exists and git's ssh
#   of the person runs, waits one more second, and types Ctrl+C (the byte
#   3). The terminal then sends INT to every program of the command, as a
#   real terminal does. It prints all output of the command (both channels
#   arrive through the terminal, in the order written) and ends with the
#   command's exit code. Arguments: the path of the unfinished copy, the
#   account, the command and its arguments.
write_pty_driver() {
    cat >"$1" <<'END'
import os, pty, select, subprocess, sys, time
partial, account, command = sys.argv[1], sys.argv[2], sys.argv[3:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(command[0], command)
output = b''
started = time.time()
ready_since = None
typed = False
while True:
    readable, _, _ = select.select([fd], [], [], 0.2)
    if readable:
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        output += data
    if not typed:
        ready = os.path.exists(partial) and subprocess.run(
            ['pgrep', '-u', account, '-x', 'ssh'], stdout=subprocess.DEVNULL).returncode == 0
        if ready and ready_since is None:
            ready_since = time.time()
        if ready_since is not None and time.time() - ready_since > 1.0:
            os.write(fd, b'\x03')
            typed = True
    if time.time() - started > 120:
        os.kill(pid, 9)
_, status = os.waitpid(pid, 0)
sys.stdout.write(output.decode(errors='replace').replace('\r\n', '\n'))
sys.stdout.write('\n' if typed else '\nCTRL-C WAS NEVER TYPED\n')
code = os.waitstatus_to_exitcode(status)
sys.exit(code if code >= 0 else 128 - code)
END
}

# line_number TEXT PART
#   Prints the number of the first line of TEXT that contains PART, or 0.
line_number() {
    local number
    number="$(printf '%s\n' "$1" | grep -n -F -m 1 -- "$2" | cut -d: -f1 || true)"
    printf '%s\n' "${number:-0}"
}

# Ctrl+C on the administrator's terminal while impact-give-repo runs
# impact-get-repo for alice: the terminal sends INT to both commands, git
# and ssh. The frame of impact-give-repo passes on everything that
# impact-get-repo prints after the signal (its message "was interrupted",
# and its result line), then closes the frame; only after that does
# impact-give-repo print its own interruption and report. Nothing is left
# behind: no unfinished copy, no copy, no process of alice.
test_ctrl_c_during_give_repo_keeps_the_messages_of_get_repo() {
    local driver="$TEST_SUITE_TMP/pty-ctrl-c.py" result_line end_line give_line
    write_pty_driver "$driver"
    rm -rf -- "$COPY.partial" "$COPY"
    # "cd /" first: the commands run in a folder that every account may enter.
    run_cmd bash -c 'cd / && exec "$@"' _ python3 "$driver" "$COPY.partial" alice \
        env SUDO_USER="$SYS_ADMIN" "$GIVE" alice "$MODEL" --github-name alice-example
    assert_output_not_contains 'CTRL-C WAS NEVER TYPED'
    assert_status 130
    assert_output_contains '    | ERROR: impact-get-repo was interrupted (signal INT).'
    assert_output_contains "    | IMPACT_RESULT status=error code=130 path=$COPY reason=interrupted"
    assert_output_contains '    --- end of the messages of impact-get-repo ---'
    assert_output_contains 'ERROR: impact-give-repo was interrupted (signal INT).'
    result_line="$(line_number "$RUN_OUTPUT" '    | IMPACT_RESULT status=error code=130')"
    end_line="$(line_number "$RUN_OUTPUT" '    --- end of the messages of impact-get-repo ---')"
    give_line="$(line_number "$RUN_OUTPUT" 'ERROR: impact-give-repo was interrupted (signal INT).')"
    if ! ((result_line > 0 && result_line < end_line && end_line < give_line)); then
        show_run
        fail "expected order: result line of impact-get-repo ($result_line), end of the frame ($end_line), interruption of impact-give-repo ($give_line)"
    fi
    assert_missing "$COPY.partial"
    assert_missing "$COPY"
    assert_fails pgrep -u alice
}
