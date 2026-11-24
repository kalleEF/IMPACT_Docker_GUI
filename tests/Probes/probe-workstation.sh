#!/usr/bin/env bash
# ==============================================================================
#  probe-workstation.sh
#
#  TEMPORARY FEASIBILITY PROBE (work package 0 of the remote-mode redesign).
#  This file is not a test of the IMPACT Docker GUI. Delete it, together with
#  the job "probe-workstation-ubuntu" in .github/workflows/test.yml, once the
#  question below is answered.
#
#  THE QUESTION
#    The redesign will add bash commands for the shared Linux workstation. They
#    create one personal Linux account per researcher. Each account may log in
#    with an SSH key only, and may open an SSH tunnel only to the RStudio ports
#    on the workstation itself. We want to test these commands automatically on
#    GitHub. This probe finds out whether a GitHub Ubuntu runner can play the
#    role of the workstation: SSH server, new accounts, key login, the sshd
#    rules, Docker through SSH, and a tunnel to a container.
#
#  WHAT THE PROBE DOES (the letters match the work package description)
#    a. Makes sure an SSH server runs on this machine (port 22, or port 2222 as
#       the fallback) and reports the job user, the Docker version and the
#       Docker storage driver.
#    b. Creates the group "impact" and two accounts with locked passwords, gives
#       each account its own key, and logs in as each account with that key.
#    c. Writes the sshd rules for the group into
#       /etc/ssh/sshd_config.d/60-impact.conf, checks the syntax (sshd -t),
#       prints the values that sshd really applies to a group member and to the
#       job user (sshd -T -C ...), and reloads sshd.
#    d. Under these rules: "docker ps" through ssh, Docker over SSH
#       (docker -H ssh://...) and "git --version" through ssh.
#    e. Starts a container that is published on 127.0.0.1:8787 only, opens an
#       SSH tunnel to it and requests a page through the tunnel. Then it checks
#       that a tunnel to a port the rules do not list is refused, and that the
#       container cannot be reached on the non-loopback address of the machine.
#    f. Removes everything it created and checks that it is gone.
#
#  HOW TO READ THE OUTPUT
#    Every check prints one line that starts with PASS, FAIL, SKIP or INFO:
#      PASS  the check worked
#      FAIL  the check did not work (the lines above it show the details)
#      SKIP  the check could not be tried because an earlier step failed
#      INFO  a fact for the report, with no right or wrong
#    A summary table with all these lines is printed at the end.
#
#  EXIT CODE
#    0  the probe ran to the end. This is also the exit code when checks FAILED:
#       the purpose of the probe is to report, not to stop the workflow.
#    2  the probe could not run at all (wrong machine, no root rights, wrong
#       parameters).
#
#  WARNING: THIS SCRIPT CHANGES THE MACHINE IT RUNS ON
#    It installs and starts an SSH server, creates Linux accounts and a group,
#    writes a file into /etc/ssh/sshd_config.d and into ~/.ssh/config, and
#    starts a container. It undoes all of this at the end. It is written for a
#    throw-away GitHub runner. On any other machine it refuses to start unless
#    you add --force.
#
#  HOW TO RUN IT
#    bash tests/Probes/probe-workstation.sh [--output-dir DIR] [--force]
#    The output is printed and also saved in DIR/probe-output.txt
#    (default DIR: tests/artifacts/probes/workstation, a folder git ignores).
# ==============================================================================

# "set -u" stops the script when it reads a variable that was never set. That
# catches typing mistakes in variable names. The script does NOT use "set -e"
# (stop at the first failing command), because a probe must go on after a
# failed check and report it.
set -u

# ------------------------------------------------------------------------------
#  Settings: every name and port number the probe uses, in one place
# ------------------------------------------------------------------------------
GROUP_NAME='impact'                 # the group whose members get the sshd rules
ACCOUNT_1='impact_probe1'           # two test accounts; the underscore is on purpose,
ACCOUNT_2='impact_probe2'           # because real user names may contain one
DROPIN_FILE='/etc/ssh/sshd_config.d/60-impact.conf'
CONTAINER_NAME='impact-probe-web'   # stands in for an RStudio Server container
CONTAINER_IMAGE='nginx:alpine'      # a very small web server image (from Docker Hub)
# The same image from a second source, tried when Docker Hub does not deliver it.
FALLBACK_IMAGE='public.ecr.aws/docker/library/nginx:alpine'
RSTUDIO_PORT=8787                   # container port on the workstation (listed in PermitOpen)
UNLISTED_PORT=8799                  # a port that PermitOpen does NOT list
TUNNEL_PORT=18787                   # "PC end" of the allowed tunnel
UNLISTED_TUNNEL_PORT=18799          # "PC end" of the tunnel that must be refused
NAME_TUNNEL_PORT=18788              # "PC end" of the tunnel that uses the name "localhost"
REVERSE_PORT=18800                  # port for the reverse tunnel that must be refused
FALLBACK_SSH_PORT=2222              # used when the system SSH service cannot be started
OWN_PID_FILE='/run/impact-probe-sshd.pid'

# Folder of this script, and from it the default output folder.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/../artifacts/probes/workstation"
FORCE=0

# ------------------------------------------------------------------------------
#  Read the command line
# ------------------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output-dir)
            if [ "$#" -lt 2 ]; then
                echo "ERROR: --output-dir needs a folder name." >&2
                exit 2
            fi
            OUT_DIR="$2"
            shift 2
            ;;
        --force)
            FORCE=1
            shift
            ;;
        -h|--help)
            # Print the comment block at the top of this file as the help text.
            sed -n '2,/^# =====.*$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "ERROR: unknown parameter '$1'. Use --help." >&2
            exit 2
            ;;
    esac
done

# ------------------------------------------------------------------------------
#  Safety check: only run on a GitHub runner, unless --force was given
# ------------------------------------------------------------------------------
# GitHub sets the variable GITHUB_ACTIONS to "true" inside every workflow job.
if [ "${GITHUB_ACTIONS:-}" != "true" ] && [ "$FORCE" -ne 1 ]; then
    echo "ERROR: this probe changes the machine (SSH server, accounts, sshd rules)." >&2
    echo "       It is meant for a throw-away GitHub runner. Add --force to run it here." >&2
    exit 2
fi

if ! mkdir -p "$OUT_DIR"; then
    echo "ERROR: cannot create the output folder '$OUT_DIR'." >&2
    exit 2
fi
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# ------------------------------------------------------------------------------
#  Variables that remember what the probe did (the clean-up reads them)
# ------------------------------------------------------------------------------
RESULT_STEPS=()        # one entry per PASS/FAIL/SKIP/INFO line: the step label,
RESULT_STATES=()       # the state,
RESULT_TEXTS=()        # and the text
BACKGROUND_PIDS=()     # tunnels and helpers started in the background
CLEANUP_DONE=0
WORK_DIR=''            # temporary folder for the keys
SERVER_MODE=''         # "system" (the normal SSH service) or "own" (our own sshd on port 2222)
SSH_PORT=''
SSH_UNIT='ssh'         # name of the systemd service (ssh on Ubuntu and Debian)
SSH_OPTIONS=()         # ssh client options shared by all calls
INSTALLED_SSHD=0       # 1 = the probe installed the package openssh-server
SYSTEMD_RUNNING=0      # 1 = systemd manages the services of this machine
UNITS_TO_STOP=()       # systemd units that were not running before the probe
SSH_SOCKET_BEFORE='not active'    # state of the unit "<name>.socket" before the probe
SSH_SERVICE_BEFORE='not active'   # state of the unit "<name>.service" before the probe
GROUP_CREATED=0
ACCOUNT_1_CREATED=0
ACCOUNT_2_CREATED=0
LOGIN_1_OK=0           # 1 = the key login as account 1 works (steps d and e need it)
DROPIN_WRITTEN=0
RULES_ACTIVE=0         # 1 = the running SSH server has read the drop-in file of step c
DROPIN_BACKUP=''       # copy of a drop-in file that existed before (normally there is none)
SSH_CONFIG_CHANGED=0
SSH_CONFIG_EXISTED=0
CONTAINER_STARTED=0
IMAGE_PULLED=0
DOCKER_OK=0
FORWARD_PID=''
LAST_HTTP_CODE='000'
CANNOT_RUN=0           # 1 = the probe could not do its work at all (no root rights)
START_EPOCH="$(date +%s)"

# ------------------------------------------------------------------------------
#  Small helper functions
# ------------------------------------------------------------------------------

# record STEP STATE TEXT
# Stores one result for the summary table and prints it at once.
record() {
    RESULT_STEPS+=("$1")
    RESULT_STATES+=("$2")
    RESULT_TEXTS+=("$3")
    printf '%-4s  [%s] %s\n' "$2" "$1" "$3"
}
pass() { record "$1" 'PASS' "$2"; }
fail() { record "$1" 'FAIL' "$2"; }
skip() { record "$1" 'SKIP' "$2"; }
info() { record "$1" 'INFO' "$2"; }

# section TITLE: prints a headline between the steps.
section() { printf '\n==== %s ====\n' "$1"; }

# note TEXT: prints an indented remark.
note() { printf '    %s\n' "$*"; }

# show_file FILE: prints a file, indented, so that it is easy to tell apart
# from the probe's own lines.
show_file() {
    if [ ! -r "$1" ]; then
        note "  (cannot read $1)"
    elif [ ! -s "$1" ]; then
        # "-s" is true for a file with content, so this branch is the empty file.
        note "  (the file is empty)"
    else
        sed 's/^/      | /' "$1"
    fi
}

# run COMMAND...
# Prints the command, runs it, prints its output indented, and returns the exit
# code of the command (0 = it worked).
run() {
    printf '    $ %s\n' "$*"
    "$@" 2>&1 | sed 's/^/      | /'
    # PIPESTATUS[0] is the exit code of the command itself; without it we would
    # get the exit code of "sed", which is always 0.
    return "${PIPESTATUS[0]}"
}

# as_root COMMAND...
# Runs a command with root rights. On a GitHub runner the job user may use
# "sudo" without a password. "-n" makes sudo fail at once when it would have to
# ask for a password, so the probe can never hang on a password prompt.
as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo -n "$@"
    fi
}

# port_open PORT: true when something accepts connections on 127.0.0.1:PORT.
# "/dev/tcp/..." is a bash feature: opening it makes a TCP connection.
port_open() {
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# wait_for_port PORT SECONDS: waits until the port accepts connections.
wait_for_port() {
    local port="$1" seconds="$2" tries
    tries=$((seconds * 2))
    while [ "$tries" -gt 0 ]; do
        if port_open "$port"; then
            return 0
        fi
        sleep 0.5
        tries=$((tries - 1))
    done
    return 1
}

# wait_for_port_closed PORT SECONDS: waits until nothing listens on the port.
wait_for_port_closed() {
    local port="$1" seconds="$2" tries
    tries=$((seconds * 2))
    while [ "$tries" -gt 0 ]; do
        if ! port_open "$port"; then
            return 0
        fi
        sleep 0.5
        tries=$((tries - 1))
    done
    return 1
}

# http_code URL: prints the HTTP status code of the answer (200 = OK), or 000
# when there was no answer within 3 seconds. --noproxy '*' makes sure the
# request goes directly to the address and never through a web proxy.
http_code() {
    local code
    code="$(curl --noproxy '*' --silent --output /dev/null --write-out '%{http_code}' --max-time 3 "$1" 2>/dev/null)"
    printf '%s' "${code:-000}"
}

# http_error_text URL: prints the error message of curl for a request that fails.
http_error_text() {
    curl --noproxy '*' --silent --show-error --output /dev/null --max-time 3 "$1" 2>&1 | head -n 1
}

# wait_for_http_200 URL SECONDS: asks again once per second until the answer is
# 200 or the time is over. The last status code is left in LAST_HTTP_CODE.
wait_for_http_200() {
    local url="$1" seconds="$2" deadline
    deadline=$(( $(date +%s) + seconds ))
    while :; do
        LAST_HTTP_CODE="$(http_code "$url")"
        if [ "$LAST_HTTP_CODE" = "200" ]; then
            return 0
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            return 1
        fi
        sleep 1
    done
}

# ssh_as ACCOUNT COMMAND...
# Runs a command on this machine through SSH, logged in as the account with the
# account's own key. "timeout 60" ends the call if it hangs, and "</dev/null"
# gives ssh an empty input so that it never waits for typing.
ssh_as() {
    local account="$1"
    shift
    timeout 60 ssh "${SSH_OPTIONS[@]}" -i "$WORK_DIR/${account}_ed25519" "${account}@127.0.0.1" "$@" </dev/null
}

# start_forward ACCOUNT LOGFILE KIND SPEC
# Starts an ssh process in the background that only forwards a port (-N: no
# remote command). KIND is -L (the port on our side leads to the server side)
# or -R (the other direction). The process id is left in FORWARD_PID.
start_forward() {
    local account="$1" log="$2" kind="$3" spec="$4"
    : > "$log"
    # The redirections at the end (</dev/null >/dev/null 2>&1) cut the
    # background process off from the output of this script. ssh writes its
    # messages into the log file given with -E.
    ssh "${SSH_OPTIONS[@]}" -N -T \
        -o ExitOnForwardFailure=yes -o GatewayPorts=no \
        -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
        -i "$WORK_DIR/${account}_ed25519" -E "$log" \
        "$kind" "$spec" "${account}@127.0.0.1" </dev/null >/dev/null 2>&1 &
    FORWARD_PID=$!
    BACKGROUND_PIDS+=("$FORWARD_PID")
}

# stop_pid PID: ends a background process and waits until it is gone.
stop_pid() {
    if [ -n "$1" ] && kill -0 "$1" 2>/dev/null; then
        kill "$1" 2>/dev/null
        wait "$1" 2>/dev/null
    fi
    return 0
}

# unit_state UNIT: prints "active" when systemd reports the unit as active, and
# "not active" in every other case (also for a unit that does not exist).
unit_state() {
    if systemctl is-active --quiet "$1" 2>/dev/null; then
        echo 'active'
    else
        echo 'not active'
    fi
}

# list_global_ipv4: prints the IPv4 addresses of this machine that are not
# loopback addresses (127.x.x.x), one per line.
list_global_ipv4() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1
    else
        hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -v '^127\.'
    fi
}

# sshd_effective USER: prints the settings that sshd applies to a connection of
# this user from 127.0.0.1, reduced to the settings the drop-in file sets.
# "sshd -T" prints the complete configuration; "-C user=...,host=...,addr=..."
# tells it for which connection the "Match" rules are to be evaluated.
sshd_effective() {
    as_root /usr/sbin/sshd -T -C "user=$1,host=localhost,addr=127.0.0.1" 2>&1 |
        grep -E '^(authenticationmethods|passwordauthentication|kbdinteractiveauthentication|allowtcpforwarding|permitopen|allowstreamlocalforwarding|gatewayports|x11forwarding|allowagentforwarding|permittunnel|clientaliveinterval|clientalivecountmax) ' |
        sort
}

# reload_sshd: makes the running SSH server read its configuration again.
reload_sshd() {
    if [ "$SERVER_MODE" = "own" ]; then
        # Our own sshd: the signal HUP ("hang up") tells it to read the files again.
        as_root kill -HUP "$(cat "$OWN_PID_FILE" 2>/dev/null)"
    elif as_root systemctl reload "$SSH_UNIT"; then
        note "systemctl reload $SSH_UNIT worked"
    elif as_root systemctl restart "$SSH_UNIT"; then
        note "systemctl reload failed, systemctl restart $SSH_UNIT worked"
    else
        return 1
    fi
}

# sshd_log: prints what the SSH server logged since the probe started. Our own
# sshd writes into a file in the output folder; the system service writes into
# the system journal, which "journalctl" reads.
sshd_log() {
    if [ "$SERVER_MODE" = "own" ]; then
        cat "$OUT_DIR/sshd-own-instance.log" 2>/dev/null
    elif [ "$SERVER_MODE" = "system" ] && command -v journalctl >/dev/null 2>&1; then
        as_root journalctl -u "$SSH_UNIT" --since "@$START_EPOCH" --no-pager 2>&1
    fi
    return 0
}

# collect_sshd_log: saves the journal of the system SSH service into the output
# folder. It helps to explain a failed login. (The log of our own sshd is in
# the output folder already.)
collect_sshd_log() {
    if [ "$SERVER_MODE" = "system" ]; then
        sshd_log > "$OUT_DIR/sshd-journal.log"
    fi
    return 0
}

# show_sshd_log_tail: prints the last lines of the SSH server log.
show_sshd_log_tail() {
    note "last lines of the SSH server log:"
    sshd_log | tail -n 15 | sed 's/^/      | /'
    return 0
}

# ------------------------------------------------------------------------------
#  Step a: SSH server, job user, Docker
# ------------------------------------------------------------------------------
step_a_server_and_docker() {
    section 'a. SSH server on this machine, job user, Docker'

    # --- a1: who runs this job, and do we have root rights? -------------------
    run id
    if [ -r /etc/os-release ]; then
        note "operating system: $(grep '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')"
    fi
    info a1 "the job runs as user '$(id -un)' (uid $(id -u)); groups: $(id -Gn)"

    if as_root true 2>/dev/null; then
        pass a2 "root rights are available without a password prompt"
    else
        fail a2 "no root rights (sudo -n failed); the probe cannot continue"
        CANNOT_RUN=1
        return 1
    fi

    # --- a3: is the SSH server program installed? ----------------------------
    # The server program is /usr/sbin/sshd. It belongs to the package
    # openssh-server, which is not part of every Ubuntu image.
    if [ -x /usr/sbin/sshd ]; then
        pass a3 "openssh-server was already installed (/usr/sbin/sshd exists)"
    else
        note "/usr/sbin/sshd is missing, installing the package openssh-server"
        local install_start
        install_start="$(date +%s)"
        # DEBIAN_FRONTEND=noninteractive: never ask a question during the
        # installation. -q and Dpkg::Use-Pty=0 keep progress bars out of the log.
        if ! run as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -q -o Dpkg::Use-Pty=0 openssh-server; then
            # The package lists on the machine can be out of date. Refresh them
            # and try once more.
            run as_root apt-get update -q
            run as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -q -o Dpkg::Use-Pty=0 openssh-server
        fi
        if [ -x /usr/sbin/sshd ]; then
            INSTALLED_SSHD=1
            pass a3 "openssh-server was installed in $(( $(date +%s) - install_start )) seconds"
        else
            fail a3 "openssh-server could not be installed"
            return 1
        fi
    fi
    note "client version: $(ssh -V 2>&1)"
    note "server package: $(dpkg-query -W -f='${Package} ${Version}' openssh-server 2>/dev/null || echo unknown)"

    # sshd needs its host keys (the keys that identify the server) and the
    # folder /run/sshd. The package normally creates both; these two commands
    # make sure, and do nothing when the keys and the folder already exist.
    as_root ssh-keygen -A >/dev/null 2>&1
    as_root mkdir -p /run/sshd

    # --- a4: start the server ------------------------------------------------
    # First choice: the normal SSH service of the system on port 22, managed by
    # systemd, because the real workstation works the same way.
    # The folder /run/systemd/system exists exactly when systemd is running.
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        SYSTEMD_RUNNING=1
        # The service is called "ssh" on Ubuntu and Debian, "sshd" elsewhere.
        if ! systemctl cat ssh.service >/dev/null 2>&1 && systemctl cat sshd.service >/dev/null 2>&1; then
            SSH_UNIT='sshd'
        fi
    fi
    info a4 "systemd is $([ "$SYSTEMD_RUNNING" -eq 1 ] && echo 'running' || echo 'NOT running') on this machine (it decides whether 'systemctl reload $SSH_UNIT' can be used)"

    if [ "$SYSTEMD_RUNNING" -eq 1 ]; then
        # Remember the state of each unit before the probe. The clean-up stops
        # exactly the units that were not active before, and check f5 compares
        # the states at the end with the states remembered here. On new Ubuntu
        # versions "ssh.socket" listens on port 22 and starts "ssh.service" on
        # the first connection. So one unit can be active while the other is
        # not, and port 22 is open in both of these cases.
        local unit state_before
        for unit in "$SSH_UNIT.socket" "$SSH_UNIT.service"; do
            if systemctl cat "$unit" >/dev/null 2>&1; then
                # When the probe installed the package itself, the unit did not
                # exist before, whatever the installation has started since.
                state_before='not active'
                if [ "$INSTALLED_SSHD" -ne 1 ]; then
                    state_before="$(unit_state "$unit")"
                fi
                case "$unit" in
                    *.socket) SSH_SOCKET_BEFORE="$state_before" ;;
                    *)        SSH_SERVICE_BEFORE="$state_before" ;;
                esac
                if [ "$state_before" = 'not active' ]; then
                    UNITS_TO_STOP+=("$unit")
                fi
            fi
        done
        note "before the probe: $SSH_UNIT.socket is $SSH_SOCKET_BEFORE, $SSH_UNIT.service is $SSH_SERVICE_BEFORE"
        run as_root systemctl start "$SSH_UNIT"
        if wait_for_port 22 10; then
            SERVER_MODE='system'
            SSH_PORT=22
        else
            note "the service did not open port 22; state of the service:"
            run as_root systemctl status "$SSH_UNIT" --no-pager --lines 20
        fi
    elif port_open 22; then
        note "port 22 already answers, but systemd does not manage it; using our own sshd on port $FALLBACK_SSH_PORT"
    fi

    # Fallback: our own sshd process on port 2222. It reads the same
    # configuration files as the system service (so the drop-in file of step c
    # applies to it as well), only the port differs.
    if [ -z "$SERVER_MODE" ]; then
        # Create the log file as the job user first: sshd would create it for
        # root only, and then the workflow could not upload it.
        : > "$OUT_DIR/sshd-own-instance.log"
        run as_root /usr/sbin/sshd -f /etc/ssh/sshd_config -p "$FALLBACK_SSH_PORT" \
            -o "PidFile=$OWN_PID_FILE" -E "$OUT_DIR/sshd-own-instance.log"
        if wait_for_port "$FALLBACK_SSH_PORT" 10; then
            SERVER_MODE='own'
            SSH_PORT="$FALLBACK_SSH_PORT"
        else
            show_file "$OUT_DIR/sshd-own-instance.log"
        fi
    fi

    if [ -z "$SERVER_MODE" ]; then
        fail a5 "no SSH server could be started (neither the system service on port 22 nor an own sshd on port $FALLBACK_SSH_PORT)"
        return 1
    fi
    if [ "$SERVER_MODE" = "system" ]; then
        pass a5 "the SSH server runs as the system service '$SSH_UNIT' on port 22"
    else
        pass a5 "the SSH server runs as an own sshd process on port $FALLBACK_SSH_PORT (the system service could not be used)"
    fi
    if command -v ss >/dev/null 2>&1; then
        note "who listens on the SSH port:"
        as_root ss -ltnp 2>/dev/null | grep -E ":$SSH_PORT\b" | sed 's/^/      | /'
    fi
    note "global sshd settings that matter for the logins:"
    as_root /usr/sbin/sshd -T 2>/dev/null |
        grep -E '^(port|listenaddress|usepam|passwordauthentication|pubkeyauthentication|authorizedkeysfile|allowusers|allowgroups|denyusers|denygroups|strictmodes|loglevel) ' |
        sed 's/^/      | /'

    # Now that the port is known, build the ssh client options used by every
    # call below:
    #   -F none                 read no ssh config file, only these options
    #   BatchMode=yes           never ask a question (password, yes/no)
    #   IdentitiesOnly=yes      offer only the key given with -i
    #   StrictHostKeyChecking=accept-new   trust the server key on first contact
    #   UserKnownHostsFile=...  remember that key in our temporary folder,
    #                           not in the real ~/.ssh/known_hosts
    #   ConnectTimeout=10       give up after 10 seconds without a connection
    SSH_OPTIONS=(-F none -o BatchMode=yes -o IdentitiesOnly=yes
                 -o StrictHostKeyChecking=accept-new
                 -o "UserKnownHostsFile=$WORK_DIR/known_hosts"
                 -o ConnectTimeout=10 -p "$SSH_PORT")
    note "in the lines below, 'ssh_as ACCOUNT COMMAND' stands for:"
    note "  ssh ${SSH_OPTIONS[*]} -i $WORK_DIR/ACCOUNT_ed25519 ACCOUNT@127.0.0.1 COMMAND"

    # --- a6: Docker ----------------------------------------------------------
    if run docker version --format 'client {{.Client.Version}}, server {{.Server.Version}}'; then
        DOCKER_OK=1
        local docker_version storage_driver
        docker_version="$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
        storage_driver="$(docker info --format '{{.Driver}}' 2>/dev/null)"
        pass a6 "the Docker daemon answers; server version $docker_version"
        info a7 "Docker storage driver: $storage_driver"
        note "more Docker facts:"
        docker info 2>/dev/null |
            grep -E '^ *(Server Version|Storage Driver|driver-type|Backing Filesystem|Cgroup Driver|Cgroup Version|Kernel Version|Operating System|Docker Root Dir):' |
            sed 's/^ */      | /'
    else
        fail a6 "the Docker daemon does not answer (docker version failed)"
    fi
    return 0
}

# ------------------------------------------------------------------------------
#  Step b: group, two accounts with locked passwords, one key each, key login
# ------------------------------------------------------------------------------

# create_account ACCOUNT: returns 0 when the account exists afterwards and was
# created by this probe.
create_account() {
    local account="$1"
    if getent passwd "$account" >/dev/null 2>&1; then
        note "the account '$account' exists already; the probe does not touch accounts it did not create"
        return 1
    fi
    # --create-home  make /home/<account>
    # --shell        the login shell
    # --user-group   make a group with the same name as the account
    # useradd sets no password, so the account's password is "locked": nobody
    # can log in with a password, only with a key.
    run as_root useradd --create-home --shell /bin/bash --user-group "$account" || return 1

    # Add the account to the group with the sshd rules, and to the group
    # "docker" so that it may use Docker. -a means "add, keep the other groups".
    if getent group docker >/dev/null 2>&1; then
        run as_root usermod -aG "$GROUP_NAME,docker" "$account" || return 1
    else
        note "there is no group 'docker' on this machine"
        run as_root usermod -aG "$GROUP_NAME" "$account" || return 1
    fi
    return 0
}

# install_key ACCOUNT: makes a new key pair for the account and puts the public
# half into the account's authorized_keys file.
install_key() {
    local account="$1" key="$WORK_DIR/${1}_ed25519" home
    # -t ed25519: the key type; -N '': no passphrase; -C: a comment; -q: quiet.
    ssh-keygen -q -t ed25519 -N '' -C "impact-probe-$account" -f "$key" || return 1
    # The home folder of the account is the sixth field of its line in the
    # account list (normally /home/<account>).
    home="$(getent passwd "$account" | cut -d: -f6)"
    [ -n "$home" ] || return 1
    # sshd accepts the file only when the folder and the file belong to the
    # account and nobody else may write to them. "install" creates the folder
    # and copies the file with the right owner (-o), group (-g) and rights (-m).
    as_root install -d -m 700 -o "$account" -g "$account" "$home/.ssh" || return 1
    as_root install -m 600 -o "$account" -g "$account" "$key.pub" "$home/.ssh/authorized_keys" || return 1
    return 0
}

# check_login STEP ACCOUNT: logs in with the account's key and checks who we are
# on the other side. Returns 0 when the login worked.
check_login() {
    local step="$1" account="$2" answer
    printf '    $ ssh ... -i %s %s@127.0.0.1 id -un\n' "$WORK_DIR/${account}_ed25519" "$account"
    answer="$(ssh_as "$account" id -un 2>&1)"
    printf '%s\n' "$answer" | sed 's/^/      | /'
    if [ "$(printf '%s\n' "$answer" | tail -n 1)" = "$account" ]; then
        pass "$step" "key login as '$account' works"
        return 0
    fi
    fail "$step" "key login as '$account' failed"
    show_sshd_log_tail
    return 1
}

step_b_accounts() {
    section 'b. Group, two accounts with locked passwords, key login'

    # --- b1: the group ---------------------------------------------------------
    if getent group "$GROUP_NAME" >/dev/null 2>&1; then
        info b1 "the group '$GROUP_NAME' existed already (the probe will not delete it)"
    elif run as_root groupadd "$GROUP_NAME"; then
        GROUP_CREATED=1
        pass b1 "group '$GROUP_NAME' created"
    else
        fail b1 "group '$GROUP_NAME' could not be created"
        return 1
    fi

    # --- b2, b3: the accounts ----------------------------------------------------
    if create_account "$ACCOUNT_1"; then
        ACCOUNT_1_CREATED=1
        pass b2 "account '$ACCOUNT_1' created: $(id "$ACCOUNT_1" 2>&1)"
    else
        fail b2 "account '$ACCOUNT_1' could not be created"
    fi
    if create_account "$ACCOUNT_2"; then
        ACCOUNT_2_CREATED=1
        pass b3 "account '$ACCOUNT_2' created: $(id "$ACCOUNT_2" 2>&1)"
    else
        fail b3 "account '$ACCOUNT_2' could not be created"
    fi
    if [ "$ACCOUNT_1_CREATED" -ne 1 ] || [ "$ACCOUNT_2_CREATED" -ne 1 ]; then
        return 1
    fi

    # --- b4: are the passwords locked? ---------------------------------------
    # "passwd -S" prints the state of the password; the second word is L for
    # "locked", P for "has a password", NP for "no password needed".
    local state_1 state_2
    state_1="$(as_root passwd -S "$ACCOUNT_1" 2>/dev/null | awk '{print $2}')"
    state_2="$(as_root passwd -S "$ACCOUNT_2" 2>/dev/null | awk '{print $2}')"
    if [ "$state_1" = "L" ] && [ "$state_2" = "L" ]; then
        pass b4 "both passwords are locked (passwd -S shows L)"
    else
        fail b4 "password state is '$state_1' and '$state_2', expected L (locked) for both"
    fi

    # --- b5: one key per account ---------------------------------------------
    if install_key "$ACCOUNT_1" && install_key "$ACCOUNT_2"; then
        pass b5 "one new ed25519 key per account, public half written to ~/.ssh/authorized_keys"
    else
        fail b5 "the keys could not be created or installed"
        return 1
    fi

    # --- b6, b7: key login ---------------------------------------------------
    # This also answers an open question: does sshd let an account log in with
    # a key although its password is locked?
    check_login b6 "$ACCOUNT_1" && LOGIN_1_OK=1
    check_login b7 "$ACCOUNT_2"

    # --- b8: the wrong key must be refused -----------------------------------
    # A check that can only succeed proves little. So also try the key of
    # account 1 for account 2: this login must fail.
    local answer
    if answer="$(timeout 60 ssh "${SSH_OPTIONS[@]}" -i "$WORK_DIR/${ACCOUNT_1}_ed25519" "${ACCOUNT_2}@127.0.0.1" id -un </dev/null 2>&1)"; then
        fail b8 "the key of '$ACCOUNT_1' was accepted for '$ACCOUNT_2'"
    else
        pass b8 "the key of '$ACCOUNT_1' is refused for '$ACCOUNT_2': $(printf '%s' "$answer" | tail -n 1)"
    fi
    return 0
}

# ------------------------------------------------------------------------------
#  Step c: the sshd rules for the group (drop-in file), syntax check, reload
# ------------------------------------------------------------------------------
step_c_sshd_rules() {
    section 'c. sshd rules for the group (drop-in file)'

    # --- c1: does sshd read the drop-in folder at all? -----------------------
    # A "drop-in" is an extra configuration file in /etc/ssh/sshd_config.d.
    # sshd reads it only when the main file contains an "Include" line for it.
    if grep -Eiq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null; then
        pass c1 "sshd_config includes the folder: $(grep -Ei '^[[:space:]]*Include[[:space:]]' /etc/ssh/sshd_config | head -n 1)"
    else
        fail c1 "/etc/ssh/sshd_config has no Include line for /etc/ssh/sshd_config.d, so a drop-in file has no effect"
    fi
    note "files in /etc/ssh/sshd_config.d before the probe adds its own:"
    ls -l /etc/ssh/sshd_config.d 2>&1 | sed 's/^/      | /'

    # --- c2: write the drop-in file --------------------------------------------
    if as_root test -e "$DROPIN_FILE"; then
        DROPIN_BACKUP="$WORK_DIR/60-impact.conf.before-probe"
        as_root cat "$DROPIN_FILE" > "$DROPIN_BACKUP"
        note "$DROPIN_FILE existed already; a copy was saved and will be put back"
    fi
    # "Match Group impact" means: the lines below apply only to members of the
    # group. The block ends at the end of this file.
    #   AuthenticationMethods publickey     log in with a key, nothing else
    #   PasswordAuthentication no           no password login
    #   KbdInteractiveAuthentication no     no question-and-answer login
    #   AllowTcpForwarding local            tunnels only from the PC to here (-L)
    #   PermitOpen ...                      and only to these two addresses
    #   AllowStreamLocalForwarding no       no forwarding of Unix sockets
    #   GatewayPorts no                     forwarded ports stay on loopback
    #   X11Forwarding / AllowAgentForwarding / PermitTunnel no   switched off
    #   ClientAliveInterval / CountMax      end dead connections after 3 minutes
    if as_root tee "$DROPIN_FILE" >/dev/null <<EOF
# Written by tests/Probes/probe-workstation.sh (temporary feasibility probe).
# The probe removes this file again at its end.
Match Group $GROUP_NAME
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding local
    PermitOpen 127.0.0.1:8787 127.0.0.1:8788
    AllowStreamLocalForwarding no
    GatewayPorts no
    X11Forwarding no
    AllowAgentForwarding no
    PermitTunnel no
    ClientAliveInterval 60
    ClientAliveCountMax 3
EOF
    then
        DROPIN_WRITTEN=1
        as_root chmod 644 "$DROPIN_FILE"
        pass c2 "drop-in file $DROPIN_FILE written"
        show_file "$DROPIN_FILE"
    else
        fail c2 "drop-in file $DROPIN_FILE could not be written"
        return 1
    fi

    # --- c3: syntax check ------------------------------------------------------
    # "sshd -t" reads the whole configuration and reports mistakes without
    # touching the running server.
    if run as_root /usr/sbin/sshd -t; then
        pass c3 "sshd -t accepts the configuration with the drop-in file"
    else
        fail c3 "sshd -t reports a mistake; the drop-in file is removed again at once"
        if [ -n "$DROPIN_BACKUP" ]; then
            as_root cp "$DROPIN_BACKUP" "$DROPIN_FILE"
        else
            as_root rm -f "$DROPIN_FILE"
        fi
        DROPIN_WRITTEN=0
        return 1
    fi

    # --- c4, c5: which values does sshd really apply? -------------------------
    local member_file="$OUT_DIR/sshd-effective-member.txt"
    local own_file="$OUT_DIR/sshd-effective-job-user.txt"
    sshd_effective "$ACCOUNT_1" > "$member_file"
    sshd_effective "$(id -un)" > "$own_file"
    note "effective values for the group member '$ACCOUNT_1' (left) and for the job user '$(id -un)' (right):"
    paste -d '|' "$member_file" "$own_file" | awk -F'|' '{printf "      | %-58s | %s\n", $1, $2}'

    # Every line the drop-in file sets must appear in the member's values.
    local expected missing=''
    while IFS= read -r expected; do
        if ! grep -Fxq "$expected" "$member_file"; then
            missing="$missing [$expected]"
        fi
    done <<'EOF'
authenticationmethods publickey
passwordauthentication no
kbdinteractiveauthentication no
allowtcpforwarding local
permitopen 127.0.0.1:8787 127.0.0.1:8788
allowstreamlocalforwarding no
gatewayports no
x11forwarding no
allowagentforwarding no
permittunnel no
clientaliveinterval 60
clientalivecountmax 3
EOF
    if [ -z "$missing" ]; then
        pass c4 "sshd -T shows all 12 rules as effective for the group member '$ACCOUNT_1'"
    else
        fail c4 "these rules are NOT effective for '$ACCOUNT_1':$missing"
    fi

    # The rules must not leak to users outside the group. The job user is not a
    # member, so for the job user the list of allowed tunnel targets must not
    # be the restricted one.
    if grep -Fxq 'permitopen 127.0.0.1:8787 127.0.0.1:8788' "$own_file"; then
        fail c5 "the rules also apply to the job user '$(id -un)', who is not in the group"
    else
        pass c5 "the rules do not apply to the job user '$(id -un)': $(grep -E '^(permitopen|allowtcpforwarding) ' "$own_file" | tr '\n' ';')"
    fi

    # --- c6: reload ------------------------------------------------------------
    if reload_sshd && wait_for_port "$SSH_PORT" 15; then
        RULES_ACTIVE=1
        pass c6 "sshd read the new configuration (reload) and listens again on port $SSH_PORT"
    else
        fail c6 "sshd could not be reloaded"
        show_sshd_log_tail
        return 1
    fi

    # --- c7, c8: the key logins must still work under the rules ---------------
    LOGIN_1_OK=0
    check_login c7 "$ACCOUNT_1" && LOGIN_1_OK=1
    check_login c8 "$ACCOUNT_2"

    # --- c9: which login methods does the server offer to a member? -----------
    # We forbid the key on purpose (PubkeyAuthentication=no). The login then
    # fails, and the error message of ssh lists in brackets the methods the
    # server would accept. For a group member it must be "publickey" alone.
    local answer methods
    answer="$(timeout 60 ssh -F none -o BatchMode=yes -o PubkeyAuthentication=no \
        -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$WORK_DIR/known_hosts" \
        -o ConnectTimeout=10 -p "$SSH_PORT" "${ACCOUNT_1}@127.0.0.1" true </dev/null 2>&1)"
    note "answer of ssh without a key: $(printf '%s' "$answer" | tail -n 1)"
    methods="$(printf '%s' "$answer" | sed -n 's/.*Permission denied (\(.*\))\..*/\1/p' | tail -n 1)"
    if [ "$methods" = "publickey" ]; then
        pass c9 "the server offers a group member the login method 'publickey' and no other"
    else
        fail c9 "the server offers a group member these login methods: '${methods:-unknown}' (expected: publickey)"
    fi
    return 0
}

# ------------------------------------------------------------------------------
#  Step d: Docker and git through SSH, under the rules of step c
# ------------------------------------------------------------------------------

# warn_if_rules_inactive: steps d and e are meant to run while the sshd rules of
# step c are in force. When step c did not get that far, say so clearly, because
# the results of d and e then describe a server WITHOUT the rules.
warn_if_rules_inactive() {
    if [ "$RULES_ACTIVE" -ne 1 ]; then
        note "WARNING: the sshd rules of step c are NOT active. The checks below run without them;"
        note "         the checks that expect a refusal (e3, e5) will then report FAIL."
    fi
}
step_d_docker_and_git() {
    section 'd. Docker and git through SSH as a group member'
    warn_if_rules_inactive

    if [ "$LOGIN_1_OK" -ne 1 ]; then
        skip d1 "not tried: the key login as '$ACCOUNT_1' does not work"
        skip d2 "not tried: the key login as '$ACCOUNT_1' does not work"
        skip d3 "not tried: the key login as '$ACCOUNT_1' does not work"
        return 1
    fi

    # --- d1: docker ps through ssh -------------------------------------------
    # Works only when the account is in the group "docker".
    if [ "$DOCKER_OK" -ne 1 ]; then
        skip d1 "not tried: the Docker daemon does not answer"
    elif run ssh_as "$ACCOUNT_1" docker ps; then
        pass d1 "'ssh $ACCOUNT_1@127.0.0.1 docker ps' works"
    else
        fail d1 "'ssh $ACCOUNT_1@127.0.0.1 docker ps' failed"
    fi

    # --- d2: Docker over SSH --------------------------------------------------
    # "docker -H ssh://user@host" makes the docker program on OUR side start
    # "ssh user@host docker system dial-stdio" and talk to the daemon through
    # it. Docker starts plain "ssh" without our options, so the key and the
    # port must come from ~/.ssh/config. The GUI writes such an entry too. The
    # probe puts its entry at the top of the file and removes it at the end.
    if [ "$DOCKER_OK" -ne 1 ]; then
        skip d2 "not tried: the Docker daemon does not answer"
    else
        local ssh_dir="$HOME/.ssh"
        mkdir -p "$ssh_dir" && chmod 700 "$ssh_dir"
        if [ -e "$ssh_dir/config" ]; then
            SSH_CONFIG_EXISTED=1
            cp -p "$ssh_dir/config" "$WORK_DIR/ssh-config.before-probe"
        fi
        {
            echo "# BEGIN impact-probe (temporary, written by tests/Probes/probe-workstation.sh)"
            echo "Host 127.0.0.1"
            echo "    Port $SSH_PORT"
            echo "    IdentityFile \"$WORK_DIR/${ACCOUNT_1}_ed25519\""
            echo "    IdentityFile \"$WORK_DIR/${ACCOUNT_2}_ed25519\""
            echo "    IdentitiesOnly yes"
            echo "    BatchMode yes"
            echo "    StrictHostKeyChecking accept-new"
            echo "    UserKnownHostsFile \"$WORK_DIR/known_hosts\""
            echo "    ConnectTimeout 10"
            echo "# END impact-probe"
            if [ "$SSH_CONFIG_EXISTED" -eq 1 ]; then
                cat "$WORK_DIR/ssh-config.before-probe"
            fi
        } > "$ssh_dir/config.impact-probe-new"
        chmod 600 "$ssh_dir/config.impact-probe-new"
        mv "$ssh_dir/config.impact-probe-new" "$ssh_dir/config"
        SSH_CONFIG_CHANGED=1
        note "temporary entry in $ssh_dir/config:"
        sed -n '/^# BEGIN impact-probe/,/^# END impact-probe/p' "$ssh_dir/config" | sed 's/^/      | /'

        if run timeout 90 docker -H "ssh://${ACCOUNT_1}@127.0.0.1:${SSH_PORT}" ps; then
            pass d2 "Docker over SSH works: 'docker -H ssh://$ACCOUNT_1@127.0.0.1:$SSH_PORT ps'"
        else
            fail d2 "Docker over SSH failed: 'docker -H ssh://$ACCOUNT_1@127.0.0.1:$SSH_PORT ps'"
            show_sshd_log_tail
        fi
    fi

    # --- d3: git through ssh ----------------------------------------------------
    if run ssh_as "$ACCOUNT_1" git --version; then
        pass d3 "'ssh $ACCOUNT_1@127.0.0.1 git --version' works"
    else
        fail d3 "'ssh $ACCOUNT_1@127.0.0.1 git --version' failed"
    fi
    return 0
}

# ------------------------------------------------------------------------------
#  Step e: container on 127.0.0.1:8787, tunnel, refused tunnel, outside address
# ------------------------------------------------------------------------------

# try_refused_forward LOCALPORT TARGETHOST TARGETPORT LOGFILE
# Opens a tunnel to a target that the rules may not allow and requests a page
# through it. Prints what the client reported. A failed request alone proves
# nothing: it also fails when the tunnel never started (for example because the
# login did not work). So the result has three values, left in REFUSAL_STATE:
#   refused   the tunnel started, the request through it failed, and the ssh
#             client logged "administratively prohibited". These are the words
#             ssh uses when the SERVER says no to the target.
#   accepted  the request went through the tunnel (HTTP 200).
#   unclear   neither of the two: the tunnel did not start, or the request
#             failed for another reason. This says nothing about the rules.
# The details for the summary line are left in REFUSAL_TEXT.
# Returns 0 only for "refused".
REFUSAL_STATE=''
REFUSAL_TEXT=''
try_refused_forward() {
    local local_port="$1" target_host="$2" target_port="$3" log="$4"
    local code curl_text client_text other_text port_opened=0
    REFUSAL_STATE='unclear'
    REFUSAL_TEXT=''
    start_forward "$ACCOUNT_1" "$log" -L "127.0.0.1:${local_port}:${target_host}:${target_port}"
    local pid="$FORWARD_PID"
    # ssh opens the port on our side as soon as the login has worked. The server
    # checks the target only when a connection is really made through the
    # tunnel. That is why the refusal shows up at the request, not at the start
    # of the tunnel.
    if wait_for_port "$local_port" 10; then
        port_opened=1
    fi
    code="$(http_code "http://127.0.0.1:${local_port}/")"
    curl_text="$(http_error_text "http://127.0.0.1:${local_port}/")"
    sleep 1
    client_text="$(grep -F 'administratively prohibited' "$log" | head -n 1)"
    # The first line of the log, shown when the refusal message is missing.
    other_text="$(head -n 1 "$log")"
    note "tunnel 127.0.0.1:${local_port} -> ${target_host}:${target_port}: HTTP status $code"
    note "curl said: ${curl_text:-nothing}"
    note "ssh client log ($log):"
    show_file "$log"
    stop_pid "$pid"
    if [ "$port_opened" -ne 1 ]; then
        REFUSAL_TEXT="the tunnel did not start (ssh did not open 127.0.0.1:${local_port}); first line of the ssh client log: '${other_text:-none}'"
    elif [ "$code" = "200" ]; then
        REFUSAL_STATE='accepted'
        REFUSAL_TEXT="HTTP status 200 through the tunnel"
    elif [ -n "$client_text" ]; then
        REFUSAL_STATE='refused'
        REFUSAL_TEXT="HTTP status $code; ssh client message: '$client_text'"
    else
        REFUSAL_TEXT="the tunnel started and the request failed (HTTP status $code), but the ssh client did not log 'administratively prohibited'; first line of the ssh client log: '${other_text:-none}'"
    fi
    [ "$REFUSAL_STATE" = 'refused' ]
}

step_e_container_and_tunnel() {
    section 'e. Container on 127.0.0.1:8787, tunnel, refused tunnel, outside address'
    warn_if_rules_inactive

    if [ "$DOCKER_OK" -ne 1 ] || [ "$LOGIN_1_OK" -ne 1 ]; then
        local why="the Docker daemon does not answer"
        [ "$LOGIN_1_OK" -ne 1 ] && why="the key login as '$ACCOUNT_1' does not work"
        local step
        for step in e1 e2 e3 e4 e5 e6 e7 e8; do
            skip "$step" "not tried: $why"
        done
        return 1
    fi

    # --- e1: start the container as the group member, through ssh --------------
    if port_open "$RSTUDIO_PORT"; then
        note "WARNING: something already listens on 127.0.0.1:$RSTUDIO_PORT before the container starts"
    fi
    # Fetch the image first, with a generous time limit. Remember whether the
    # probe fetched it, so that the clean-up removes only what the probe added.
    if ! docker image inspect "$CONTAINER_IMAGE" >/dev/null 2>&1; then
        if run timeout 300 docker pull --quiet "$CONTAINER_IMAGE"; then
            IMAGE_PULLED=1
        elif run timeout 300 docker pull --quiet "$FALLBACK_IMAGE"; then
            # Docker Hub limits how many images a computer may fetch per hour.
            # A failed download there must not make the tunnel checks impossible.
            note "Docker Hub did not deliver the image; using the copy from $FALLBACK_IMAGE"
            CONTAINER_IMAGE="$FALLBACK_IMAGE"
            IMAGE_PULLED=1
        fi
    fi
    # "-p 127.0.0.1:8787:80" publishes port 80 of the container on port 8787 of
    # this machine, but ONLY on the loopback address 127.0.0.1. Other computers
    # cannot reach it. This is how the workstation will publish RStudio.
    if run ssh_as "$ACCOUNT_1" docker run -d --rm --name "$CONTAINER_NAME" \
            -p "127.0.0.1:${RSTUDIO_PORT}:80" "$CONTAINER_IMAGE"; then
        CONTAINER_STARTED=1
    fi
    if [ "$CONTAINER_STARTED" -eq 1 ] && wait_for_http_200 "http://127.0.0.1:${RSTUDIO_PORT}/" 30; then
        pass e1 "'$ACCOUNT_1' started a container through ssh; it answers on 127.0.0.1:$RSTUDIO_PORT (HTTP 200)"
    else
        fail e1 "the container does not answer on 127.0.0.1:$RSTUDIO_PORT (last HTTP status: $LAST_HTTP_CODE)"
        run docker ps -a --filter "name=$CONTAINER_NAME"
        local later_step
        for later_step in e2 e3 e4 e5 e6 e7 e8; do
            skip "$later_step" "not tried: the container does not answer"
        done
        return 1
    fi
    run docker port "$CONTAINER_NAME"
    if command -v ss >/dev/null 2>&1; then
        note "listening sockets on port $RSTUDIO_PORT:"
        as_root ss -ltnp 2>/dev/null | grep -E ":$RSTUDIO_PORT\b" | sed 's/^/      | /'
    fi

    # --- e2: the allowed tunnel ------------------------------------------------
    # The same kind of tunnel the GUI will open from the Windows PC:
    # 127.0.0.1:18787 on "our" side leads to 127.0.0.1:8787 on the server side.
    local tunnel_log="$OUT_DIR/tunnel-allowed.log"
    start_forward "$ACCOUNT_1" "$tunnel_log" -L "127.0.0.1:${TUNNEL_PORT}:127.0.0.1:${RSTUDIO_PORT}"
    local tunnel_pid="$FORWARD_PID"
    note "tunnel process id: $tunnel_pid"
    if wait_for_port "$TUNNEL_PORT" 15 && wait_for_http_200 "http://127.0.0.1:${TUNNEL_PORT}/" 30; then
        pass e2 "the tunnel 127.0.0.1:$TUNNEL_PORT -> 127.0.0.1:$RSTUDIO_PORT works: curl through the tunnel returns HTTP 200"
    else
        fail e2 "no HTTP 200 through the tunnel on 127.0.0.1:$TUNNEL_PORT (last HTTP status: $LAST_HTTP_CODE)"
        show_sshd_log_tail
    fi
    note "ssh client log of the tunnel ($tunnel_log):"
    show_file "$tunnel_log"

    # --- e3: a target port that PermitOpen does not list -----------------------
    # Start a second small web server on the unlisted port. Without it a failed
    # request would prove nothing: it could fail simply because nothing listens.
    local listener_pid=''
    if command -v python3 >/dev/null 2>&1; then
        mkdir -p "$WORK_DIR/www"
        echo 'impact probe: unlisted port' > "$WORK_DIR/www/index.html"
        python3 -m http.server "$UNLISTED_PORT" --bind 127.0.0.1 --directory "$WORK_DIR/www" \
            </dev/null >"$OUT_DIR/unlisted-port-listener.log" 2>&1 &
        listener_pid=$!
        BACKGROUND_PIDS+=("$listener_pid")
        if wait_for_http_200 "http://127.0.0.1:${UNLISTED_PORT}/" 15; then
            note "a web server answers directly on 127.0.0.1:$UNLISTED_PORT (HTTP 200), so only the sshd rule can block the tunnel"
        else
            note "WARNING: the helper web server on 127.0.0.1:$UNLISTED_PORT does not answer; the next check is weaker"
        fi
    else
        note "WARNING: python3 is missing, no web server on 127.0.0.1:$UNLISTED_PORT; the next check is weaker"
    fi
    try_refused_forward "$UNLISTED_TUNNEL_PORT" 127.0.0.1 "$UNLISTED_PORT" "$OUT_DIR/tunnel-unlisted-port.log"
    case "$REFUSAL_STATE" in
        refused)
            pass e3 "a tunnel to the unlisted port 127.0.0.1:$UNLISTED_PORT is refused when used. $REFUSAL_TEXT"
            ;;
        accepted)
            fail e3 "a tunnel to the unlisted port 127.0.0.1:$UNLISTED_PORT was NOT refused. $REFUSAL_TEXT"
            ;;
        *)
            # No PASS without proof: a request that failed for another reason
            # says nothing about the rule.
            fail e3 "could not be tested whether a tunnel to the unlisted port 127.0.0.1:$UNLISTED_PORT is refused: $REFUSAL_TEXT"
            ;;
    esac
    stop_pid "$listener_pid"
    note "what the SSH server logged about it: $(sshd_log | grep -i 'request was denied' | tail -n 1)"

    # --- e4: the same listed port, but written as the name "localhost" -----------
    # PermitOpen compares the text of the target. The rule lists "127.0.0.1",
    # so a tunnel that asks for "localhost:8787" may be refused although it
    # leads to the same place. This is a fact for the design (INFO), not an error.
    try_refused_forward "$NAME_TUNNEL_PORT" localhost "$RSTUDIO_PORT" "$OUT_DIR/tunnel-localhost-name.log"
    case "$REFUSAL_STATE" in
        refused)
            info e4 "a tunnel to 'localhost:$RSTUDIO_PORT' (the name, not the number) is refused: the tunnel must name 127.0.0.1. $REFUSAL_TEXT"
            ;;
        accepted)
            info e4 "a tunnel to 'localhost:$RSTUDIO_PORT' (the name, not the number) is accepted. $REFUSAL_TEXT"
            ;;
        *)
            info e4 "could not be found out whether a tunnel to 'localhost:$RSTUDIO_PORT' (the name, not the number) is refused or accepted: $REFUSAL_TEXT"
            ;;
    esac

    # --- e5: a reverse tunnel must be refused ----------------------------------
    # "AllowTcpForwarding local" allows -L only. A reverse tunnel (-R, a port on
    # the server that leads back to the PC) must fail. With
    # ExitOnForwardFailure=yes the ssh process ends by itself in that case.
    # An ssh process that ended is not proof yet: it also ends when the login
    # fails. The proof is the message of the ssh client, "remote port
    # forwarding failed", which it writes when the SERVER says no.
    local reverse_log="$OUT_DIR/tunnel-reverse.log"
    start_forward "$ACCOUNT_1" "$reverse_log" -R "127.0.0.1:${REVERSE_PORT}:127.0.0.1:${RSTUDIO_PORT}"
    local reverse_pid="$FORWARD_PID" waited=0 reverse_exit reverse_text
    while kill -0 "$reverse_pid" 2>/dev/null && [ "$waited" -lt 20 ]; do
        sleep 0.5
        waited=$((waited + 1))
    done
    if kill -0 "$reverse_pid" 2>/dev/null; then
        fail e5 "a reverse tunnel (-R) was NOT refused: the ssh process kept running"
        stop_pid "$reverse_pid"
    else
        # "wait" returns the exit code of the ssh process that has ended.
        wait "$reverse_pid" 2>/dev/null
        reverse_exit=$?
        reverse_text="$(grep -Fi 'remote port forwarding failed' "$reverse_log" | head -n 1)"
        if [ -n "$reverse_text" ]; then
            pass e5 "a reverse tunnel (-R) is refused: ssh ended with exit code $reverse_exit; message: '$reverse_text'"
        else
            fail e5 "could not be tested whether a reverse tunnel (-R) is refused: ssh ended with exit code $reverse_exit, but it did not log 'remote port forwarding failed'; first line of its log: '$(head -n 1 "$reverse_log")'"
        fi
    fi
    show_file "$reverse_log"

    # --- e6: the allowed tunnel must have survived all of this ------------------
    if wait_for_http_200 "http://127.0.0.1:${TUNNEL_PORT}/" 10; then
        pass e6 "the allowed tunnel still works after the refused attempts (HTTP 200)"
    else
        fail e6 "the allowed tunnel stopped working after the refused attempts (HTTP status $LAST_HTTP_CODE)"
    fi

    # --- e7: the container must not answer on the outside address ---------------
    local addresses address code reachable='' tested=''
    addresses="$(list_global_ipv4)"
    if [ -z "$addresses" ]; then
        skip e7 "not tried: this machine has no IPv4 address besides loopback"
    else
        for address in $addresses; do
            tested="$tested $address"
            code="$(http_code "http://${address}:${RSTUDIO_PORT}/")"
            note "http://${address}:${RSTUDIO_PORT}/ -> HTTP status $code; curl said: $(http_error_text "http://${address}:${RSTUDIO_PORT}/")"
            if [ "$code" != "000" ]; then
                reachable="$reachable $address"
            fi
        done
        if [ -z "$reachable" ]; then
            pass e7 "the container does not answer on the non-loopback address(es):$tested"
        else
            fail e7 "the container ANSWERS on:$reachable (it must be reachable on 127.0.0.1 only)"
        fi
    fi

    # --- e8: end the tunnel, the port must be free again -----------------------
    stop_pid "$tunnel_pid"
    if wait_for_port_closed "$TUNNEL_PORT" 10; then
        pass e8 "after the tunnel process ended, port $TUNNEL_PORT is free again"
    else
        fail e8 "port $TUNNEL_PORT still accepts connections after the tunnel process ended"
    fi
    return 0
}

# ------------------------------------------------------------------------------
#  Step f: clean-up
# ------------------------------------------------------------------------------
cleanup() {
    # The clean-up runs once: either at the normal end of the probe, or from
    # the "trap" below when the script ends early.
    if [ "$CLEANUP_DONE" -eq 1 ]; then
        return 0
    fi
    CLEANUP_DONE=1
    section 'f. Clean-up'

    # 1. Tunnels and helper processes that may still run.
    local pid
    if [ "${#BACKGROUND_PIDS[@]}" -gt 0 ]; then
        for pid in "${BACKGROUND_PIDS[@]}"; do
            stop_pid "$pid"
        done
    fi

    # 2. The container, and the image when the probe fetched it.
    if [ "$CONTAINER_STARTED" -eq 1 ]; then
        run docker rm -f "$CONTAINER_NAME"
    fi
    if [ "$IMAGE_PULLED" -eq 1 ]; then
        run docker rmi "$CONTAINER_IMAGE"
    fi

    # 3. Our entry in ~/.ssh/config.
    if [ "$SSH_CONFIG_CHANGED" -eq 1 ]; then
        if [ "$SSH_CONFIG_EXISTED" -eq 1 ]; then
            cp -p "$WORK_DIR/ssh-config.before-probe" "$HOME/.ssh/config"
        else
            rm -f "$HOME/.ssh/config"
        fi
        note "$HOME/.ssh/config is as it was before the probe"
    fi

    # 4. Save the server log before the server is changed again.
    collect_sshd_log

    # 5. The drop-in file; then sshd must read its configuration again.
    if [ "$DROPIN_WRITTEN" -eq 1 ]; then
        if [ -n "$DROPIN_BACKUP" ]; then
            as_root cp "$DROPIN_BACKUP" "$DROPIN_FILE"
        else
            as_root rm -f "$DROPIN_FILE"
        fi
        if [ -n "$SERVER_MODE" ]; then
            reload_sshd
        fi
    fi

    # 6. The accounts. Their processes (for example a leftover ssh session)
    #    must end first, otherwise userdel refuses to delete the account.
    local account created
    for account in "$ACCOUNT_1" "$ACCOUNT_2"; do
        created=0
        [ "$account" = "$ACCOUNT_1" ] && created="$ACCOUNT_1_CREATED"
        [ "$account" = "$ACCOUNT_2" ] && created="$ACCOUNT_2_CREATED"
        if [ "$created" -eq 1 ]; then
            as_root pkill -KILL -u "$account" 2>/dev/null
            sleep 1
            # --remove also deletes the home folder of the account.
            run as_root userdel --remove "$account"
        fi
    done
    if [ "$GROUP_CREATED" -eq 1 ]; then
        run as_root groupdel "$GROUP_NAME"
    fi

    # 7. The SSH server: stop what the probe started.
    if [ "$SERVER_MODE" = "own" ] && [ -r "$OWN_PID_FILE" ]; then
        as_root kill "$(cat "$OWN_PID_FILE")" 2>/dev/null
        note "own sshd process stopped"
    fi
    if [ "${#UNITS_TO_STOP[@]}" -gt 0 ]; then
        # Stop the service first, then the socket that would start it again.
        local unit
        for unit in "$SSH_UNIT.service" "$SSH_UNIT.socket"; do
            case " ${UNITS_TO_STOP[*]} " in
                *" $unit "*) run as_root systemctl stop "$unit" ;;
            esac
        done
    fi
    if [ "$INSTALLED_SSHD" -eq 1 ]; then
        run as_root env DEBIAN_FRONTEND=noninteractive apt-get remove -y -q -o Dpkg::Use-Pty=0 openssh-server
    fi

    # 8. The temporary folder with the keys.
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi

    # 9. Make every file in the output folder readable for the job user, so
    #    that the workflow can upload it.
    as_root chown -R "$(id -u):$(id -g)" "$OUT_DIR" 2>/dev/null
    chmod -R u+rwX,go+rX "$OUT_DIR" 2>/dev/null

    # --- f1 to f5: check that everything is gone -------------------------------
    local left=''
    getent passwd "$ACCOUNT_1" >/dev/null 2>&1 && [ "$ACCOUNT_1_CREATED" -eq 1 ] && left="$left account:$ACCOUNT_1"
    getent passwd "$ACCOUNT_2" >/dev/null 2>&1 && [ "$ACCOUNT_2_CREATED" -eq 1 ] && left="$left account:$ACCOUNT_2"
    getent group "$GROUP_NAME" >/dev/null 2>&1 && [ "$GROUP_CREATED" -eq 1 ] && left="$left group:$GROUP_NAME"
    [ -d "/home/$ACCOUNT_1" ] && [ "$ACCOUNT_1_CREATED" -eq 1 ] && left="$left /home/$ACCOUNT_1"
    [ -d "/home/$ACCOUNT_2" ] && [ "$ACCOUNT_2_CREATED" -eq 1 ] && left="$left /home/$ACCOUNT_2"
    if [ -z "$left" ]; then
        pass f1 "the accounts, their home folders and the group are removed"
    else
        fail f1 "left behind:$left"
    fi

    if [ -z "$DROPIN_BACKUP" ] && as_root test -e "$DROPIN_FILE"; then
        fail f2 "$DROPIN_FILE still exists"
    elif [ -x /usr/sbin/sshd ] && ! as_root /usr/sbin/sshd -t 2>/dev/null; then
        fail f2 "the drop-in file is removed, but sshd -t now reports a mistake"
    elif [ -n "$DROPIN_BACKUP" ]; then
        pass f2 "the drop-in file that existed before the probe is back in place and the sshd configuration is valid"
    else
        pass f2 "the drop-in file is removed and the sshd configuration is valid"
    fi

    if [ "$CONTAINER_STARTED" -ne 1 ]; then
        info f3 "no container was started, so there is none to remove"
    elif [ -n "$(docker ps -aq --filter "name=^${CONTAINER_NAME}\$" 2>/dev/null)" ]; then
        fail f3 "the container '$CONTAINER_NAME' still exists"
    else
        pass f3 "the container '$CONTAINER_NAME' is removed"
    fi

    local busy='' port
    for port in "$TUNNEL_PORT" "$UNLISTED_TUNNEL_PORT" "$NAME_TUNNEL_PORT" "$RSTUDIO_PORT" "$UNLISTED_PORT"; do
        port_open "$port" && busy="$busy $port"
    done
    if [ -z "$busy" ]; then
        pass f4 "the ports used by the probe are free again"
    else
        fail f4 "these ports still accept connections:$busy"
    fi

    if [ -z "$SERVER_MODE" ]; then
        info f5 "no SSH server was started, so there is none to stop"
    elif [ "$SERVER_MODE" = "own" ] ||
         { [ "$SSH_SOCKET_BEFORE" = 'not active' ] && [ "$SSH_SERVICE_BEFORE" = 'not active' ]; }; then
        # Nothing listened on this port before the probe: the probe ran its own
        # sshd on port 2222, or neither unit of the system service was active.
        # So the port must be closed now.
        if wait_for_port_closed "$SSH_PORT" 10; then
            pass f5 "the SSH server started by the probe is stopped (port $SSH_PORT is closed)"
        else
            fail f5 "port $SSH_PORT still accepts connections after the SSH server was stopped"
        fi
    else
        # At least one of the two units was active before the probe. Then the SSH
        # server was listening on port 22 before the probe, and it is left
        # listening: a closed port would be wrong here. So this check compares
        # the state of each unit with its state before the probe. It does not
        # connect to port 22, because where "ssh.socket" listens, a connection
        # would start "ssh.service" again.
        local unit before now states='' changed=''
        for unit in "$SSH_UNIT.socket" "$SSH_UNIT.service"; do
            # A unit this system does not have cannot have changed.
            systemctl cat "$unit" >/dev/null 2>&1 || continue
            before="$SSH_SERVICE_BEFORE"
            [ "$unit" = "$SSH_UNIT.socket" ] && before="$SSH_SOCKET_BEFORE"
            now="$(unit_state "$unit")"
            states="$states $unit is $now;"
            if [ "$now" != "$before" ]; then
                changed="$changed $unit was $before and is now $now;"
            fi
        done
        if [ -z "$changed" ]; then
            pass f5 "the SSH server was listening before the probe and is left listening; its units are in the same state as before:$states"
        else
            fail f5 "the units of the SSH server are not in the state they had before the probe:$changed"
        fi
    fi
    return 0
}

# ------------------------------------------------------------------------------
#  Summary
# ------------------------------------------------------------------------------
print_summary() {
    local count="${#RESULT_STEPS[@]}" i passed=0 failed=0 skipped=0 infos=0
    printf '\n==================== SUMMARY ====================\n'
    printf '%-6s  %-4s  %s\n' 'RESULT' 'STEP' 'WHAT'
    i=0
    while [ "$i" -lt "$count" ]; do
        printf '%-6s  %-4s  %s\n' "${RESULT_STATES[$i]}" "${RESULT_STEPS[$i]}" "${RESULT_TEXTS[$i]}"
        case "${RESULT_STATES[$i]}" in
            PASS) passed=$((passed + 1)) ;;
            FAIL) failed=$((failed + 1)) ;;
            SKIP) skipped=$((skipped + 1)) ;;
            *)    infos=$((infos + 1)) ;;
        esac
        i=$((i + 1))
    done
    printf '%s\n' '-------------------------------------------------'
    printf '%d PASS, %d FAIL, %d SKIP, %d INFO\n' "$passed" "$failed" "$skipped" "$infos"
    printf 'A FAIL line does not fail the job: this probe only reports.\n'

    # GitHub shows the text written to the file named in GITHUB_STEP_SUMMARY on
    # the page of the workflow run. Write the same table there, so the result
    # can be read without opening the log.
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        {
            echo "### Probe: workstation on an Ubuntu runner"
            echo ""
            echo "$passed PASS, $failed FAIL, $skipped SKIP, $infos INFO"
            echo ""
            echo "| Result | Step | What |"
            echo "|---|---|---|"
            i=0
            while [ "$i" -lt "$count" ]; do
                # A "|" inside the text would break the table, so it is written as "\|".
                echo "| ${RESULT_STATES[$i]} | ${RESULT_STEPS[$i]} | ${RESULT_TEXTS[$i]//|/\\|} |"
                i=$((i + 1))
            done
        } >> "$GITHUB_STEP_SUMMARY" 2>/dev/null
    fi
    return 0
}

# ------------------------------------------------------------------------------
#  Main part
# ------------------------------------------------------------------------------
main() {
    echo "IMPACT Docker GUI: workstation feasibility probe (temporary)"
    echo "started: $(date -u '+%Y-%m-%d %H:%M:%S') UTC   output folder: $OUT_DIR"

    # A private temporary folder for the keys, in /tmp (or in the folder named
    # by the variable TMPDIR, when it is set). "chmod 700" = only we may enter.
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/impact-probe.XXXXXX")" || { echo "ERROR: cannot create a temporary folder." >&2; exit 2; }
    chmod 700 "$WORK_DIR"

    # "trap ... EXIT" runs the given commands whenever the script ends, also
    # when it ends early. This makes sure the clean-up and the summary happen.
    trap 'cleanup; print_summary' EXIT
    # When the job is cancelled, end through "exit" so that the EXIT trap runs.
    trap 'exit 130' INT TERM

    # Each step returns 1 when the steps after it make no sense. The later
    # steps then print SKIP lines for their checks.
    if step_a_server_and_docker; then
        if step_b_accounts; then
            step_c_sshd_rules
        else
            skip c1 "not tried: the accounts of step b are missing"
        fi
        step_d_docker_and_git
        step_e_container_and_tunnel
    else
        skip b1 "not tried: step a failed"
        skip c1 "not tried: step a failed"
        skip d1 "not tried: step a failed"
        skip e1 "not tried: step a failed"
    fi

    cleanup
    print_summary
    # The summary is printed; switch the trap off so that it is not printed twice.
    trap - EXIT
    if [ "$CANNOT_RUN" -eq 1 ]; then
        exit 2
    fi
    exit 0
}

# Run the main part and write everything it prints (normal output and error
# messages, "2>&1") both to the screen and into a file ("tee"). The exit code
# of the script is the exit code of main, not the one of tee.
main 2>&1 | tee "$OUT_DIR/probe-output.txt"
exit "${PIPESTATUS[0]}"
