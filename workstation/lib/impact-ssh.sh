#!/bin/bash
# =============================================================================
# impact-ssh.sh: the SSH rules for the shared group, and the SSH service
#
# Purpose
#   1. The content of the rules file /etc/ssh/sshd_config.d/60-impact.conf:
#      members of the shared group log in with a key only and may forward
#      ports only to the container ports on the workstation itself.
#   2. Questions to the SSH server program (sshd): which settings really
#      apply to an account ("effective settings"), is the configuration free
#      of errors, does the server answer.
#   3. The fixed procedure for every change of the rules file, built so that
#      nobody is locked out: check, write, check again, compare, reload, and
#      put the previous file back when anything goes wrong.
#
# Who runs it
#   Nobody directly. impact-common.sh loads it. impact-workstation-setup uses
#   the procedure; impact-add-user and impact-check use the questions.
#
# Usage (inside a command, after loading impact-common.sh)
#   impact_ssh_rules_content impact 8787 8830 >"$IMPACT_TMP"
#   impact_ssh_rules_install "$IMPACT_TMP" impact 8787 8830
#   impact_ssh_member_deviations alice 8787 8830 || echo "rules do not apply"
#
# What it changes on the system
#   Loading changes nothing. impact_ssh_rules_install and
#   impact_ssh_rules_remove change the rules file and reload the SSH service.
#   impact_ssh_prepare_runtime_dir creates the folder /run/sshd when missing.
#
# How to undo
#   sudo impact-workstation-setup --remove-ssh-rules removes the rules file.
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
#   < <(command)  <(command)   hand the output of a command to a loop, to
#                        mapfile or to another program as if it were a file
#                        ("process substitution")
#   <<<"$text"           hand a text to a command as its input ("here-string")
#   while IFS= read -r line   read input line by line, exactly as written:
#                        "IFS=" keeps blanks at both ends, -r keeps backslashes
#   command || true      accept a failure of this command ("set -e" would
#                        otherwise stop the script there)
#   2>&1                 send the error channel to the same place as the output
#   "${NAME:0:10}"       a part of the text: from position 0, 10 characters
#   "${NAME,,}"          the text in lower case
#   declare -A NAME  local -A NAME   a list whose entries are found by a name
#                        (an "associative array"): NAME[key]=value, "${NAME[key]}"
#   BASH_REMATCH         after [[ text =~ pattern ]]: the matched text (entry 0)
#                        and the parts in round brackets (entries 1, 2, ...)
# Constructs beyond these are explained where they are first used.
# -----------------------------------------------------------------------------

# shellcheck disable=SC2034
# Reason for SC2034 (variable appears unused): the variables set here are
# read by the commands that load this file.

# The SSH server program. The full path is fixed on Ubuntu.
readonly IMPACT_SSHD='/usr/sbin/sshd'

IMPACT_SSH_OUTPUT=''          # what sshd printed in the last test
IMPACT_SSH_RELOAD_STATE=''    # reloaded | waiting | none (see impact_ssh_reload)
IMPACT_SSH_RELOAD_TEXT=''     # the same in plain words
IMPACT_SSH_RULES_CHANGED=0    # 1 when the last procedure changed the rules file

# The "How to undo" line of a run that wrote the rules file where there was
# none. impact-workstation-setup looks for this exact text when it puts the
# lines of "How to undo" in the order that works (see order_undo_of_new_rules
# there).
readonly IMPACT_SSH_REMOVE_UNDO='Remove the SSH rules: sudo impact-workstation-setup --remove-ssh-rules'

# Internal state of the procedure.
IMPACT__SSH_PENDING=0         # 1 while a change of the rules file is unconfirmed
IMPACT__SSH_BACKUP=''         # copy of the previous rules file ('' = there was none)
IMPACT__SSH_RELOADED=0        # 1 when the service was reloaded with the new file
IMPACT__SSH_CHANGES_BEFORE=0  # length of the "What changed" list before the procedure
IMPACT__SSH_UNDO_BEFORE=0     # length of the "How to undo" list before the procedure
IMPACT__SSH_PENDING_NOTE=''   # temporary file in which the note is put together

# The note of a change of the rules file that is not confirmed yet (see
# impact__ssh_pending_write). It lies in the folder of the administrator
# files, which only root can read.
readonly IMPACT_SSH_PENDING_FILE="$IMPACT_ADMIN_DIR/ssh-rules-pending"
IMPACT_SSH_PENDING_MODE=''      # install | remove, after impact_ssh_pending_read
IMPACT_SSH_PENDING_PREVIOUS=''  # file | none, after impact_ssh_pending_read
IMPACT_SSH_PENDING_COPY=''      # temporary copy of the previous rules file

# =============================================================================
# The rules file
# =============================================================================

# impact_permitopen_line PORT_MIN PORT_MAX
#   Prints the PermitOpen line of the rules: one entry "127.0.0.1:<port>" for
#   every port of the range. PermitOpen lists the only targets a member may
#   forward to. sshd compares the text, so the entries always use 127.0.0.1
#   and never the name "localhost".
#   Result: failure when the range is invalid (see impact_valid_port; at most
#   200 ports).
#   Example: impact_permitopen_line 8787 8789
#            prints PermitOpen 127.0.0.1:8787 127.0.0.1:8788 127.0.0.1:8789
impact_permitopen_line() {
    local low="$1" high="$2" port line='PermitOpen'
    impact_valid_port "$low" && impact_valid_port "$high" || return 1
    ((low <= high && high - low + 1 <= 200)) || return 1
    for ((port = low; port <= high; port++)); do
        line+=" 127.0.0.1:$port"
    done
    printf '%s\n' "$line"
}

# impact_ssh_rules_content GROUP PORT_MIN PORT_MAX
#   Prints the complete content of the rules file for the given group and
#   port range.
#   Result: failure when the group name or the range is invalid.
#   Example: impact_ssh_rules_content impact 8787 8830 >"$IMPACT_TMP"
impact_ssh_rules_content() {
    local group="$1" permit_line
    impact_valid_group_name "$group" || return 1
    permit_line="$(impact_permitopen_line "$2" "$3")" || return 1
    # A here-document without quotes around END: "$group" and "$permit_line"
    # are replaced by their values, every other character stays.
    cat <<END
# IMPACT Docker GUI: SSH rules for the members of the group "$group".
# Written by impact-workstation-setup; the next run of that command
# overwrites changes made by hand.
#   Change the port range:  sudo impact-workstation-setup --port-min <n> --port-max <n>
#   Remove these rules:     sudo impact-workstation-setup --remove-ssh-rules
#
# Meaning: members log in with an SSH key only. They may forward ports only
# from their PC to the listed container ports on this machine. A broken
# connection is closed after about three minutes.
Match Group $group
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding local
    $permit_line
    AllowStreamLocalForwarding no
    GatewayPorts no
    X11Forwarding no
    AllowAgentForwarding no
    PermitTunnel no
    ClientAliveInterval 60
    ClientAliveCountMax 3
END
}

# impact_ssh_expected_member_values PORT_MIN PORT_MAX
#   Prints the twelve settings a member of the shared group must get, in the
#   lower-case form in which "sshd -T" prints effective settings.
impact_ssh_expected_member_values() {
    local permit_line
    permit_line="$(impact_permitopen_line "$1" "$2")" || return 1
    # sshd -T prints "permitopen" in lower case, followed by the same entries.
    permit_line="permitopen${permit_line#PermitOpen}"
    cat <<END
authenticationmethods publickey
passwordauthentication no
kbdinteractiveauthentication no
allowtcpforwarding local
$permit_line
allowstreamlocalforwarding no
gatewayports no
x11forwarding no
allowagentforwarding no
permittunnel no
clientaliveinterval 60
clientalivecountmax 3
END
}

# =============================================================================
# Questions to sshd
# =============================================================================

# impact_ssh_include_ok
#   Result: success when the main file /etc/ssh/sshd_config reads the rules
#   folder (see impact_ssh_config_includes_rules). Read-only.
impact_ssh_include_ok() {
    impact_ssh_config_includes_rules "$IMPACT_SSHD_CONFIG"
}

# impact_ssh_config_includes_rules CONFIG_FILE
#   Result: success when CONFIG_FILE, a main configuration file of sshd, has
#   an "Include" line that covers /etc/ssh/sshd_config.d/60-impact.conf,
#   placed before the first "Match" line (an Include inside a Match block
#   applies to some logins only). Read-only.
#   Example: impact_ssh_config_includes_rules /etc/ssh/sshd_config
impact_ssh_config_includes_rules() {
    local config="$1" line keyword word
    local -a words=()
    [[ -f "$config" && -r "$config" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(impact_trim "$line")"
        if [[ -z "$line" || "$line" == '#'* ]]; then
            continue
        fi
        # sshd accepts "Keyword value" and "Keyword=value".
        line="${line/=/ }"
        read -r -a words <<<"$line"
        keyword="${words[0],,}"   # ",," turns the word into lower case
        if [[ "$keyword" == 'match' ]]; then
            break
        fi
        if [[ "$keyword" != 'include' ]]; then
            continue
        fi
        for word in "${words[@]:1}"; do
            word="${word//\"/}"   # remove quotes around the pattern
            # A pattern without a leading "/" is relative to /etc/ssh.
            if [[ "$word" != /* ]]; then
                word="/etc/ssh/$word"
            fi
            # An unquoted $word on the right side is used as a pattern with
            # "*" and "?": does the rules file match it?
            # shellcheck disable=SC2053
            # Reason for SC2053: the pattern match is the purpose here.
            if [[ "$IMPACT_SSH_RULES_FILE" == $word ]]; then
                return 0
            fi
        done
    done <"$config"
    return 1
}

# impact_ssh_rules_path_usable
#   Result: success when the place of the rules file is free or holds a
#   plain file. Failure for a symbolic link, a folder or any other kind of
#   entry there. Read-only.
impact_ssh_rules_path_usable() {
    if [[ -L "$IMPACT_SSH_RULES_FILE" ]]; then
        return 1
    fi
    [[ ! -e "$IMPACT_SSH_RULES_FILE" || -f "$IMPACT_SSH_RULES_FILE" ]]
}

# impact_ssh_runtime_dir_ready
#   Result: success when the folder /run/sshd exists. sshd needs it even for
#   its self-test. The SSH service creates it at its start; on a machine
#   where the service waits for its first connection it can be missing.
impact_ssh_runtime_dir_ready() {
    [[ -d /run/sshd ]]
}

# impact_ssh_prepare_runtime_dir
#   Creates /run/sshd (owner root, mode 755). The folder lives in memory and
#   is recreated by the system at every boot.
impact_ssh_prepare_runtime_dir() {
    install -d -m 755 -o root -g root /run/sshd
}

# impact_ssh_config_test
#   Runs "sshd -t": sshd reads its whole configuration and reports mistakes,
#   without touching the running server. Read-only.
#   Result: success when the configuration is free of errors. The text sshd
#   printed is in IMPACT_SSH_OUTPUT.
impact_ssh_config_test() {
    local status=0
    # "2>&1" adds the error channel to the captured text.
    IMPACT_SSH_OUTPUT="$("$IMPACT_SSHD" -t 2>&1)" || status=$?
    return "$status"
}

# impact_ssh_client_address
#   Prints the address from which the administrator's own SSH session comes,
#   or 127.0.0.1 when it cannot be found (for example at the machine's own
#   keyboard). sshd rules can depend on the client address, so the safety
#   check asks sshd about this address.
impact_ssh_client_address() {
    local candidate
    # SSH_CONNECTION starts with the client address. sudo usually removes
    # the variable, so "who -m" (who am I, on this terminal) is the second
    # source: it prints the address in brackets at the end of the line.
    candidate="${SSH_CONNECTION:-}"
    candidate="${candidate%% *}"
    if [[ -z "$candidate" ]]; then
        candidate="$(who -m 2>/dev/null | sed -n 's/.*(\([0-9A-Fa-f:.]*\))[[:space:]]*$/\1/p' | head -n 1)" || candidate=''
    fi
    if [[ "$candidate" =~ ^[0-9A-Fa-f:.]{2,45}$ && "$candidate" == *[.:]* ]]; then
        printf '%s\n' "$candidate"
    else
        printf '127.0.0.1\n'
    fi
}

# impact_ssh_effective ACCOUNT [ADDRESS] [CONFIG_FILE]
#   Prints every setting that sshd applies to a login of ACCOUNT coming from
#   ADDRESS (default 127.0.0.1), sorted, one "name value" per line. This is
#   "sshd -T -C user=...,host=...,addr=...": sshd evaluates its Match rules
#   for exactly this connection. With CONFIG_FILE sshd reads that file in
#   place of /etc/ssh/sshd_config (impact-check uses a copy without the
#   IMPACT rules, to compare). The question has a time limit of 30 seconds.
#   Read-only; needs root rights.
#   Result: failure when the account name or address is unusable or sshd
#   reports an error (its text is then in IMPACT_SSH_OUTPUT).
#   Example: impact_ssh_effective alice | grep '^permitopen '
impact_ssh_effective() {
    local account="$1" address="${2:-127.0.0.1}" config="${3:-}" output status=0
    local -a options=()
    # The name goes into a comma-separated list for sshd; the name rule
    # allows neither commas nor blanks.
    impact__lookup_name_ok "$account" || return 1
    [[ "$address" =~ ^[0-9A-Fa-f:.]{2,45}$ ]] || return 1
    if [[ -n "$config" ]]; then
        [[ -f "$config" && ! -L "$config" ]] || return 1
        options=(-f "$config")
    fi
    output="$(timeout 30 "$IMPACT_SSHD" -T "${options[@]}" -C "user=$account,host=$address,addr=$address" 2>&1)" || status=$?
    if ((status != 0)); then
        IMPACT_SSH_OUTPUT="$output"
        return 1
    fi
    printf '%s\n' "$output" | sort
}

# impact_ssh_member_deviations ACCOUNT PORT_MIN PORT_MAX [ADDRESS]
#   Compares the effective settings of ACCOUNT with the twelve restricted
#   values of the rules, and checks "usepam yes". Prints one line per
#   setting that deviates. Read-only.
#   Why UsePAM: the accounts of colleagues have a locked password ("!" in
#   /etc/shadow). sshd lets such an account log in with a key only while
#   UsePAM is yes (the setting of Ubuntu); with UsePAM no it refuses the
#   login ("account is locked"). The rules file does not set it; it comes
#   from /etc/ssh/sshd_config.
#   Result: 0 when all apply; 1 when at least one deviates; 2 when sshd
#   could not be asked.
#   Example: if impact_ssh_member_deviations alice 8787 8830; then echo restricted; fi
impact_ssh_member_deviations() {
    local account="$1" effective expected line name found deviations=0
    effective="$(impact_ssh_effective "$account" "${4:-127.0.0.1}")" || return 2
    expected="$(impact_ssh_expected_member_values "$2" "$3")" || return 2
    while IFS= read -r line; do
        name="${line%% *}"   # the first word is the name of the setting
        # Find the line of the same setting in the effective values.
        found="$(printf '%s\n' "$effective" | grep -m 1 -E "^${name}( |\$)" || true)"
        if [[ "$found" != "$line" ]]; then
            deviations=1
            if [[ "$name" == 'permitopen' ]]; then
                # The list of ports is long; show its start only.
                printf '    %s: expected "%s...", effective "%s..."\n' "$name" "${line:11:48}" "${found:11:48}"
            else
                printf '    %s: expected "%s", effective "%s"\n' "$name" "${line#* }" "${found#* }"
            fi
        fi
    done <<<"$expected"
    found="$(printf '%s\n' "$effective" | grep -m 1 -E '^usepam( |$)' || true)"
    if [[ "$found" != 'usepam yes' ]]; then
        deviations=1
        printf '    usepam: expected "yes", effective "%s" (with UsePAM no, sshd refuses the key login of an account with a locked password; set "UsePAM yes" in %s)\n' "${found#* }" "$IMPACT_SSHD_CONFIG"
    fi
    return "$deviations"
}

# impact__sshd_T
#   Internal: runs "sshd -T" (print the effective settings and stop) with a
#   time limit of 30 seconds and prints its output. The tests of the library
#   replace this one function by a stand-in that behaves like sshd.
impact__sshd_T() {
    timeout 30 "$IMPACT_SSHD" -T 2>/dev/null
}

# impact__sshd_config_values KEYWORD
#   Internal: prints the value of every line "KEYWORD value" in the output
#   of "sshd -T", one per line, in the order sshd prints them. KEYWORD is
#   written in lower case, as sshd -T prints it (for example "port").
#   The whole output of sshd is stored first and searched afterwards. A
#   reader that stops early inside a pipe (for example awk with "exit")
#   closes the pipe while sshd is still writing; sshd 8.9 (Ubuntu 22.04)
#   then ends with the signal SIGPIPE, and "set -o pipefail" turns the whole
#   answer into a failure, so the value would be lost.
#   Result: failure when sshd could not be asked; success with no output
#   when sshd has no such line.
#   Example: impact__sshd_config_values pidfile    prints /run/sshd.pid
impact__sshd_config_values() {
    local keyword="$1" output
    output="$(impact__sshd_T)" || return 1
    # awk reads its input up to the end here: it reads the stored text, so
    # stopping early would harm nobody, and it does not stop.
    awk -v key="$keyword" '$1 == key { print $2 }' <<<"$output"
}

# impact__ssh_probe_targets
#   Internal: prints the places where the SSH server should greet, one
#   "address port" pair per line, at most eight. They come from the
#   "listenaddress" lines of sshd -T (0.0.0.0 becomes 127.0.0.1 and ::
#   becomes ::1, so the test stays on this machine) and from every "port"
#   line, tried on 127.0.0.1 and ::1. Port 22 is the last fallback.
impact__ssh_probe_targets() {
    local value host port count=0 line
    local -a ports=() addresses=() targets=()
    mapfile -t addresses < <(impact__sshd_config_values listenaddress || true)
    mapfile -t ports < <(impact__sshd_config_values port || true)
    for value in "${addresses[@]}"; do
        host=''
        port=''
        # sshd -T prints "listenaddress 192.0.2.5:22" or "[::1]:22".
        if [[ "$value" =~ ^\[([0-9A-Fa-f:.]+)\]:([0-9]{1,5})$ ]]; then
            host="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[2]}"
        elif [[ "$value" =~ ^([0-9.]+):([0-9]{1,5})$ ]]; then
            host="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[2]}"
        fi
        case "$host" in
            '') continue ;;
            0.0.0.0) host='127.0.0.1' ;;
            ::) host='::1' ;;
            *) ;;
        esac
        targets+=("$host $port")
    done
    for port in "${ports[@]}" 22; do
        [[ "$port" =~ ^[0-9]{1,5}$ ]] || continue
        targets+=("127.0.0.1 $port" "::1 $port")
    done
    # Print each pair once, keeping the order.
    local -A seen=()
    for line in "${targets[@]}"; do
        if [[ -z "${seen[$line]:-}" ]] && ((count < 8)); then
            seen[$line]=1
            count=$((count + 1))
            printf '%s\n' "$line"
        fi
    done
}

# impact_ssh_listening
#   Result: success when an SSH server answers on this machine: a connection
#   to one of its ports delivers a greeting that starts with "SSH-". The
#   ports and addresses come from sshd -T (see impact__ssh_probe_targets),
#   so a server on another port than 22 is found too. Read-only; each try
#   opens and closes one connection.
impact_ssh_listening() {
    local host port greeting
    while read -r host port; do
        # bash opens a network connection through the special path
        # /dev/tcp/<host>/<port>. "exec 3<>path" opens it for reading and
        # writing as the handle number 3; "read -u 3" reads from that
        # handle, "-t 4" waits at most four seconds. It runs in a separate
        # bash with a time limit, so a server that does not answer cannot
        # stall the command.
        # shellcheck disable=SC2016
        # Reason for SC2016 (no expansion in single quotes): the inner bash
        # must expand $1 and $2 itself; they are handed over as arguments.
        greeting="$(timeout 6 bash -c 'exec 3<>"/dev/tcp/$1/$2" && IFS= read -r -t 4 -u 3 line && printf "%s" "$line"' _ "$host" "$port" 2>/dev/null)" || greeting=''
        if [[ "$greeting" == SSH-* ]]; then
            return 0
        fi
    done < <(impact__ssh_probe_targets)
    return 1
}

# impact_ssh_reload
#   Makes the running SSH server read its configuration again. Sessions that
#   are open stay open: the server process that waits for new connections
#   restarts itself, and every session has its own process.
#   Three situations:
#     systemd runs and the SSH service is active: "systemctl reload" (Ubuntu
#       22.04, and Ubuntu 24.04 after the first connection since boot);
#     systemd runs and only ssh.socket is active (Ubuntu 24.04 before the
#       first connection): nothing runs yet, the service reads the file when
#       the next connection starts it;
#     no systemd (for example inside a container): the signal HUP is sent to
#       the server process named in sshd's PidFile.
#   systemd is the program that starts and supervises services on Ubuntu.
#   Result: success, with IMPACT_SSH_RELOAD_STATE set to "reloaded",
#   "waiting" (socket only) or "none" (no SSH server runs), and a sentence in
#   IMPACT_SSH_RELOAD_TEXT. Failure when the reload itself failed.
impact_ssh_reload() {
    local unit pid_file pid name
    IMPACT_SSH_RELOAD_STATE=''
    IMPACT_SSH_RELOAD_TEXT=''
    # The folder /run/systemd/system exists exactly when systemd runs.
    if [[ -d /run/systemd/system ]] && impact_have_tool systemctl; then
        for unit in ssh.service sshd.service; do
            if systemctl is-active --quiet "$unit" 2>/dev/null; then
                if ! systemctl reload "$unit"; then
                    IMPACT_SSH_RELOAD_TEXT="systemctl reload $unit failed."
                    return 1
                fi
                IMPACT_SSH_RELOAD_STATE='reloaded'
                IMPACT_SSH_RELOAD_TEXT="The SSH service read its configuration again (systemctl reload $unit)."
                return 0
            fi
        done
        if systemctl is-active --quiet ssh.socket 2>/dev/null; then
            IMPACT_SSH_RELOAD_STATE='waiting'
            IMPACT_SSH_RELOAD_TEXT='The SSH service is not running at this moment; ssh.socket starts it at the next connection, and it reads the current files then.'
            return 0
        fi
        IMPACT_SSH_RELOAD_STATE='none'
        IMPACT_SSH_RELOAD_TEXT='No SSH service is active on this machine. The files apply when it is started.'
        return 0
    fi

    # The first "pidfile" line of sshd -T names the file that holds the
    # process number of the running server.
    pid_file=''
    IFS= read -r pid_file < <(impact__sshd_config_values pidfile || true) || pid_file=''
    if [[ -n "$pid_file" && -r "$pid_file" ]]; then
        IFS= read -r pid <"$pid_file" || pid=''
        if [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/comm" ]]; then
            # /proc/<number>/comm holds the program name of a process. Only a
            # process that really is sshd gets the signal.
            IFS= read -r name <"/proc/$pid/comm" || name=''
            if [[ "$name" == 'sshd' ]]; then
                if ! kill -HUP "$pid"; then
                    IMPACT_SSH_RELOAD_TEXT="The signal HUP could not be sent to the SSH server (process $pid)."
                    return 1
                fi
                IMPACT_SSH_RELOAD_STATE='reloaded'
                IMPACT_SSH_RELOAD_TEXT="The SSH server (process $pid) read its configuration again (signal HUP)."
                return 0
            fi
        fi
    fi
    IMPACT_SSH_RELOAD_STATE='none'
    IMPACT_SSH_RELOAD_TEXT='No running SSH server was found on this machine. The files apply when it is started.'
    return 0
}

# =============================================================================
# The procedure for changing the rules file
# =============================================================================

# impact__ssh_record FILE ADDRESS ACCOUNT...
#   Internal: writes the effective settings of the accounts into FILE, for
#   the client address and for the loopback address.
impact__ssh_record() {
    local file="$1" address="$2" account where
    shift 2
    : >"$file"   # ":" does nothing; with ">" it empties the file
    for account in "$@"; do
        for where in "$address" 127.0.0.1; do
            printf '## account %s, connection from %s\n' "$account" "$where" >>"$file"
            impact_ssh_effective "$account" "$where" >>"$file" || return 1
            if [[ "$address" == '127.0.0.1' ]]; then
                break
            fi
        done
    done
}

# impact__ssh_pending_write MODE
#   Internal: writes the note IMPACT_SSH_PENDING_FILE before the rules file
#   changes. The note says that a change (MODE "install" or "remove") is not
#   confirmed yet, and it holds a copy of the rules file as it was before
#   (IMPACT__SSH_BACKUP), or says that there was none. The SSH procedure
#   removes the note once the SSH service has read the new file. When the
#   command is killed in between (for example with "kill -9", which no
#   command can catch), the note stays, and the next run first puts the
#   previous file back and then repeats the change with all its checks.
#   Result: failure when the note could not be written.
impact__ssh_pending_write() {
    local mode="$1"
    if [[ -L "$IMPACT_ADMIN_DIR" ]]; then
        return 1
    fi
    if [[ ! -d "$IMPACT_ADMIN_DIR" ]]; then
        install -d -m 700 -o root -g root -- "$IMPACT_ADMIN_DIR" || return 1
    fi
    {
        printf '# IMPACT: a change of %s that is not confirmed yet.\n' "$IMPACT_SSH_RULES_FILE"
        printf 'MODE=%s\n' "$mode"
        if [[ -n "$IMPACT__SSH_BACKUP" && -f "$IMPACT__SSH_BACKUP" ]]; then
            printf 'PREVIOUS=file\n'
            printf '# The rules file as it was before the change follows.\n'
            cat -- "$IMPACT__SSH_BACKUP"
        else
            printf 'PREVIOUS=none\n'
            printf '# There was no rules file before the change.\n'
        fi
    } >"$IMPACT__SSH_PENDING_NOTE" || return 1
    impact_write_file_atomic "$IMPACT_SSH_PENDING_FILE" 600 root root <"$IMPACT__SSH_PENDING_NOTE"
}

# impact_ssh_pending_read
#   Reads the note of an unconfirmed change (see impact__ssh_pending_write).
#   Sets IMPACT_SSH_PENDING_MODE ("install" or "remove") and
#   IMPACT_SSH_PENDING_PREVIOUS ("file" or "none"). With "file", the
#   previous rules file is copied to a temporary file whose path is in
#   IMPACT_SSH_PENDING_COPY. Read-only for the system.
#   Result: 0 a note was read; 1 there is no note; 2 the note is unusable
#   (reason in IMPACT_CHECK_REASON).
impact_ssh_pending_read() {
    local mode='' previous='' line number=0
    IMPACT_SSH_PENDING_MODE=''
    IMPACT_SSH_PENDING_PREVIOUS=''
    IMPACT_SSH_PENDING_COPY=''
    IMPACT_CHECK_REASON=''
    if [[ ! -e "$IMPACT_SSH_PENDING_FILE" && ! -L "$IMPACT_SSH_PENDING_FILE" ]]; then
        return 1
    fi
    impact_file_is_trusted "$IMPACT_SSH_PENDING_FILE" || return 2
    while IFS= read -r line && ((number < 3)); do
        number=$((number + 1))
        case "$line" in
            MODE=install | MODE=remove) mode="${line#MODE=}" ;;
            PREVIOUS=file | PREVIOUS=none) previous="${line#PREVIOUS=}" ;;
            *) ;;
        esac
    done <"$IMPACT_SSH_PENDING_FILE"
    if [[ -z "$mode" || -z "$previous" ]]; then
        IMPACT_CHECK_REASON="$IMPACT_SSH_PENDING_FILE does not have the expected lines MODE= and PREVIOUS=."
        return 2
    fi
    IMPACT_SSH_PENDING_MODE="$mode"
    IMPACT_SSH_PENDING_PREVIOUS="$previous"
    if [[ "$previous" == 'file' ]]; then
        impact_mktemp_file || return 2
        IMPACT_SSH_PENDING_COPY="$IMPACT_TMP"
        # "tail -n +5" prints the file from its fifth line on: the copy of
        # the previous rules file starts there.
        tail -n +5 -- "$IMPACT_SSH_PENDING_FILE" >"$IMPACT_SSH_PENDING_COPY" || return 2
    fi
    return 0
}

# impact__ssh_pending_clear
#   Internal: removes the note of an unconfirmed change. Prints a warning
#   when it cannot be removed (the next run then repeats the last checks).
impact__ssh_pending_clear() {
    if [[ -e "$IMPACT_SSH_PENDING_FILE" || -L "$IMPACT_SSH_PENDING_FILE" ]]; then
        rm -f -- "$IMPACT_SSH_PENDING_FILE" ||
            impact_warn "The note $IMPACT_SSH_PENDING_FILE could not be removed. The next run of impact-workstation-setup repeats the checks of the SSH rules."
    fi
    return 0
}

# impact__ssh_put_back_previous
#   Internal: puts the rules file that IMPACT_SSH_PENDING_COPY holds back in
#   place, or removes the rules file when there was none before
#   (IMPACT_SSH_PENDING_PREVIOUS "none"). Used for a change that an earlier
#   run left unconfirmed.
impact__ssh_put_back_previous() {
    if [[ "$IMPACT_SSH_PENDING_PREVIOUS" == 'file' ]]; then
        impact_write_file_atomic "$IMPACT_SSH_RULES_FILE" 644 root root <"$IMPACT_SSH_PENDING_COPY"
    else
        rm -f -- "$IMPACT_SSH_RULES_FILE"
    fi
}

# impact__ssh_rules_restore EXIT_CODE
#   Internal: runs when the command ends. While a change of the rules file is
#   unconfirmed, it puts the previous file back (or removes the new file when
#   there was none before), checks the result with sshd -t, and reloads the
#   service again when it may have read the new file. When all of this
#   worked, the note of the unconfirmed change is removed; otherwise it
#   stays, so the next run repeats the work.
impact__ssh_rules_restore() {
    local settled=1
    ((IMPACT__SSH_PENDING == 1)) || return 0
    IMPACT__SSH_PENDING=0
    {
        printf '\nPutting the previous SSH rules back, because the change was not confirmed:\n'
        if [[ -n "$IMPACT__SSH_BACKUP" && -f "$IMPACT__SSH_BACKUP" ]]; then
            if impact_write_file_atomic "$IMPACT_SSH_RULES_FILE" 644 root root <"$IMPACT__SSH_BACKUP"; then
                printf '  The previous file %s is back in place.\n' "$IMPACT_SSH_RULES_FILE"
            else
                settled=0
                printf '  FAILED to put the previous file back. Look at %s now.\n' "$IMPACT_SSH_RULES_FILE"
            fi
        else
            if rm -f -- "$IMPACT_SSH_RULES_FILE"; then
                printf '  The new file %s was removed (there was none before).\n' "$IMPACT_SSH_RULES_FILE"
            else
                settled=0
                printf '  FAILED to remove %s. Remove it by hand now.\n' "$IMPACT_SSH_RULES_FILE"
            fi
        fi
        if impact_ssh_config_test; then
            printf '  sshd -t: the SSH configuration is free of errors.\n'
        else
            printf '  sshd -t still reports a problem:\n%s\n' "$IMPACT_SSH_OUTPUT"
            printf '  Keep this session open and correct the SSH configuration before you log out.\n'
        fi
        if ((IMPACT__SSH_RELOADED == 1)); then
            if impact_ssh_reload; then
                printf '  %s\n' "$IMPACT_SSH_RELOAD_TEXT"
            else
                settled=0
                printf '  The SSH service could not be reloaded: %s\n' "$IMPACT_SSH_RELOAD_TEXT"
                printf '  Keep this session open and check the service: sudo systemctl status ssh\n'
            fi
        fi
        if ((settled == 1)); then
            impact__ssh_pending_clear
        else
            printf '  The note %s stays, so the next run of impact-workstation-setup repeats this work.\n' "$IMPACT_SSH_PENDING_FILE"
        fi
    } >&2
    # The steps of the procedure are no longer true: remove them from the
    # lists for "What changed" and "How to undo". "${list[@]:0:n}" is the
    # first n entries of a list.
    IMPACT_CHANGES=("${IMPACT_CHANGES[@]:0:IMPACT__SSH_CHANGES_BEFORE}")
    IMPACT_UNDO=("${IMPACT_UNDO[@]:0:IMPACT__SSH_UNDO_BEFORE}")
    # A step that was running when the command stopped (the write or the
    # reload) belongs to the procedure as well; its effect was taken back
    # above, so the report and the log do not name it as "may have
    # finished".
    IMPACT_CURRENT_STEP=''
}

# impact__ssh_rules_procedure MODE CONTENT_FILE GROUP PORT_MIN PORT_MAX
#   Internal: the shared body of impact_ssh_rules_install (MODE "install")
#   and impact_ssh_rules_remove (MODE "remove").
impact__ssh_rules_procedure() {
    local mode="$1" content_file="$2" group="$3" port_min="$4" port_max="$5"
    local invoker client_address before after member='' candidate
    local -a accounts=()
    local was_listening=0 write_text pending_status=0
    # need_write: 1 when the rules file must change. reload_needed: 1 when
    # the SSH service must read the files again although they may already
    # be in place (an earlier run stopped before its change was confirmed).
    # state_file / state_exists: the rules file as it is before this run's
    # own change (in a dry run after an interrupted run: the file that a
    # real run would put back first).
    local need_write=1 reload_needed=0 state_file="$IMPACT_SSH_RULES_FILE" state_exists=0
    IMPACT_SSH_RULES_CHANGED=0

    # A symbolic link or a folder at the place of the rules file was made by
    # hand. The command cannot put such a thing back after a failed check,
    # so it does not start.
    if ! impact_ssh_rules_path_usable; then
        impact_die "$IMPACT_EXIT_CONFLICT" "$IMPACT_SSH_RULES_FILE exists and is no plain file (a symbolic link or a folder)." \
            "Look at it (ls -l $IMPACT_SSH_RULES_FILE) and move it away. Nothing was changed by the SSH step."
    fi

    # --- 1. Does sshd read the rules folder at all? ------------------------
    if [[ "$mode" == 'install' ]]; then
        if ! impact_ssh_include_ok; then
            impact_die "$IMPACT_EXIT_FAILED" \
                "$IMPACT_SSHD_CONFIG does not read the folder $IMPACT_SSH_RULES_DIR, so a rules file there would have no effect." \
                "Add this line near the top of $IMPACT_SSHD_CONFIG, above any line that starts with Match, then run the command again:  Include $IMPACT_SSH_RULES_DIR/*.conf"
        fi
        impact_ok "$IMPACT_SSHD_CONFIG reads the files in $IMPACT_SSH_RULES_DIR."
    fi

    # --- An earlier change that was never confirmed -------------------------
    impact_ssh_pending_read || pending_status=$?
    case "$pending_status" in
        0)
            impact_warn "An earlier run stopped after it had changed $IMPACT_SSH_RULES_FILE ($IMPACT_SSH_PENDING_MODE) and before the SSH service had read the change and answered again (note: $IMPACT_SSH_PENDING_FILE). The file that was in place before is put back first; then this run makes its change with all checks and reloads the SSH service."
            if ((IMPACT_DRY_RUN == 1)); then
                impact_do "Put back the SSH rules file that was in place before the interrupted change"
                if [[ "$IMPACT_SSH_PENDING_PREVIOUS" == 'file' ]]; then
                    state_file="$IMPACT_SSH_PENDING_COPY"
                    state_exists=1
                else
                    state_file=''
                fi
            else
                impact_do "Put back the SSH rules file that was in place before the interrupted change" impact__ssh_put_back_previous ||
                    impact_die "$IMPACT_EXIT_FAILED" "The previous rules file could not be put back." \
                        "Look at $IMPACT_SSH_RULES_FILE and at the note $IMPACT_SSH_PENDING_FILE (sudo cat it: the previous file follows its fourth line)."
            fi
            reload_needed=1
            ;;
        1) ;;
        *)
            impact_die "$IMPACT_EXIT_FAILED" "The note of an unconfirmed SSH change cannot be used: $IMPACT_CHECK_REASON" \
                "Look at it (sudo cat $IMPACT_SSH_PENDING_FILE). It must belong to root with mode 600. Then run the command again."
            ;;
    esac
    if [[ "$state_file" == "$IMPACT_SSH_RULES_FILE" && -f "$IMPACT_SSH_RULES_FILE" ]]; then
        state_exists=1
    fi

    if [[ "$mode" == 'install' ]]; then
        if ((state_exists == 1)) && impact_file_has_content "$state_file" "$content_file" &&
            { [[ "$state_file" != "$IMPACT_SSH_RULES_FILE" ]] || impact_file_is "$IMPACT_SSH_RULES_FILE" 644 root root; }; then
            need_write=0
        fi
        if ((need_write == 0 && reload_needed == 0)); then
            impact_ok "The rules file $IMPACT_SSH_RULES_FILE already has the requested content."
            return 0
        fi
        write_text="Write the SSH rules file $IMPACT_SSH_RULES_FILE (under a temporary name, then renamed)"
    else
        if ((state_exists == 0)); then
            need_write=0
        fi
        if ((need_write == 0 && reload_needed == 0)); then
            impact_ok "There is no rules file $IMPACT_SSH_RULES_FILE. Nothing to remove."
            return 0
        fi
        write_text="Remove the SSH rules file $IMPACT_SSH_RULES_FILE"
    fi

    invoker="$(impact_invoking_account)"
    accounts=("$invoker")
    if [[ "$invoker" != 'root' ]]; then
        accounts+=(root)
    fi
    client_address="$(impact_ssh_client_address)"

    if ((IMPACT_DRY_RUN == 1)); then
        if ((need_write == 1)); then
            impact_info "A real run first records the effective SSH settings of: ${accounts[*]}."
            impact_do "$write_text"
            impact__ssh_add_undo "$mode" "$state_exists"
            impact_info "A real run then checks the configuration (sshd -t), confirms that the settings of ${accounts[*]} are unchanged, and puts the previous state back if any check fails."
        else
            impact_info "The rules file is then in the requested state already. A real run checks the configuration (sshd -t) and puts the previous state back if a check fails."
        fi
        impact_do "Reload the SSH service (open sessions stay open)"
        return 0
    fi

    if ! impact_ssh_runtime_dir_ready; then
        impact_do --transient "Create the folder /run/sshd, which sshd needs for its self-test" \
            impact_ssh_prepare_runtime_dir || impact_die "$IMPACT_EXIT_FAILED" "The folder /run/sshd could not be created." ""
    fi

    # The configuration must be free of errors before anything is changed.
    # When removing, an error may come from the rules file itself; then the
    # removal is the repair and the comparison of settings is skipped.
    local compare="$need_write"
    if ! impact_ssh_config_test; then
        if [[ "$mode" == 'install' ]]; then
            impact_error "sshd reports an error in the current SSH configuration:"
            printf '%s\n' "$IMPACT_SSH_OUTPUT" >&2
            impact_die "$IMPACT_EXIT_FAILED" \
                "The SSH configuration has an error before this command changed the rules. The rules file was not changed by this step." \
                "Correct the file that sshd names above. If it is $IMPACT_SSH_RULES_FILE, remove it with: sudo impact-workstation-setup --remove-ssh-rules"
        fi
        impact_warn "sshd reports an error in the current SSH configuration, so the settings before and after cannot be compared:"
        printf '%s\n' "$IMPACT_SSH_OUTPUT"
        compare=0
    fi

    # --- 2. Record the effective settings before the change -----------------
    impact_mktemp_dir || impact_die "$IMPACT_EXIT_FAILED" "No temporary folder could be created." ""
    before="$IMPACT_TMP/before"
    after="$IMPACT_TMP/after"
    IMPACT__SSH_PENDING_NOTE="$IMPACT_TMP/pending-note"
    if ((compare == 1)); then
        if ! impact__ssh_record "$before" "$client_address" "${accounts[@]}"; then
            impact_die "$IMPACT_EXIT_FAILED" "sshd could not report the effective settings: $IMPACT_SSH_OUTPUT" \
                "Nothing was changed. Check the SSH configuration with: sudo sshd -t"
        fi
        impact_ok "Recorded the effective SSH settings of: ${accounts[*]} (connection from $client_address)."
    fi
    if impact_ssh_listening; then
        was_listening=1
    fi

    # From here on, any early end of the command puts the previous file back.
    IMPACT__SSH_BACKUP=''
    if [[ -f "$IMPACT_SSH_RULES_FILE" && ! -L "$IMPACT_SSH_RULES_FILE" ]]; then
        IMPACT__SSH_BACKUP="$IMPACT_TMP/previous-rules"
        cp -p -- "$IMPACT_SSH_RULES_FILE" "$IMPACT__SSH_BACKUP" ||
            impact_die "$IMPACT_EXIT_FAILED" "The current rules file could not be copied aside. Nothing was changed." ""
    fi
    # After an interrupted run the running server may have read either file,
    # so the restore handler always reloads it.
    IMPACT__SSH_RELOADED="$reload_needed"
    # The note is written before the file changes: an end of the command
    # that no handler can catch leaves it behind for the next run.
    impact__ssh_pending_write "$mode" ||
        impact_die "$IMPACT_EXIT_FAILED" "The note $IMPACT_SSH_PENDING_FILE could not be written, so the change is not started. Nothing was changed by the SSH step." \
            "Look at the folder $IMPACT_ADMIN_DIR (it must be a folder of root, mode 700), then run the command again."
    IMPACT__SSH_CHANGES_BEFORE="${#IMPACT_CHANGES[@]}"
    IMPACT__SSH_UNDO_BEFORE="${#IMPACT_UNDO[@]}"
    IMPACT__SSH_PENDING=1
    impact_on_exit impact__ssh_rules_restore

    # --- 3. Write the new file (temporary name, then rename) ----------------
    if ((need_write == 1)); then
        if [[ "$mode" == 'install' ]]; then
            impact_do "$write_text" impact_write_file_atomic "$IMPACT_SSH_RULES_FILE" 644 root root <"$content_file" ||
                impact_die "$IMPACT_EXIT_FAILED" "The rules file could not be written." ""
        else
            impact_do "$write_text" rm -f -- "$IMPACT_SSH_RULES_FILE" ||
                impact_die "$IMPACT_EXIT_FAILED" "The rules file could not be removed." ""
        fi
        impact__ssh_add_undo "$mode" "$state_exists"
    fi

    # --- 4. sshd -t ---------------------------------------------------------
    if ! impact_ssh_config_test; then
        impact_error "sshd -t reports an error with the changed rules:"
        printf '%s\n' "$IMPACT_SSH_OUTPUT" >&2
        impact_die "$IMPACT_EXIT_FAILED" "The SSH configuration would be invalid. The previous state is put back." \
            "Read the message of sshd above. The SSH service was not reloaded by this run."
    fi
    impact_ok "sshd -t: the SSH configuration is free of errors."

    # --- 5. The settings of the administrator and of root must be unchanged --
    if ((compare == 1)); then
        if ! impact__ssh_record "$after" "$client_address" "${accounts[@]}"; then
            impact_die "$IMPACT_EXIT_FAILED" "sshd could not report the effective settings after the change. The previous state is put back." ""
        fi
        if ! cmp -s -- "$before" "$after"; then
            impact_error "The change would alter the SSH settings of ${accounts[*]}. Lines with < are the settings before, lines with > after:"
            # diff prints the lines that differ; it ends with status 1 when
            # there are differences, which is expected here.
            diff -- "$before" "$after" >&2 || true
            for candidate in "${accounts[@]}"; do
                if [[ "$mode" == 'install' ]] && impact_account_in_group "$candidate" "$group"; then
                    impact_error "The account '$candidate' is a member of the group '$group', so the rules would apply to it."
                fi
            done
            impact_die "$IMPACT_EXIT_FAILED" "The rules must leave the administrator's own login untouched. The previous state is put back." \
                "Run the command from an administration account that is no member of the group '$group'."
        fi
        impact_ok "The effective SSH settings of ${accounts[*]} are identical before and after."
    fi

    # --- 6. A member gets the restricted values -----------------------------
    if [[ "$mode" == 'install' ]]; then
        while IFS= read -r candidate; do
            if impact_account_exists "$candidate"; then
                member="$candidate"
                break
            fi
        done < <(impact_group_members "$group" 2>/dev/null || true)
        if [[ -n "$member" ]]; then
            local deviation_text status=0
            deviation_text="$(impact_ssh_member_deviations "$member" "$port_min" "$port_max")" || status=$?
            if ((status != 0)); then
                impact_error "The member '$member' of the group '$group' does not get the restricted values:"
                printf '%s\n' "$deviation_text" >&2
                impact_die "$IMPACT_EXIT_FAILED" "The rules are not effective for members. The previous state is put back." \
                    "Another file in $IMPACT_SSH_RULES_DIR or $IMPACT_SSHD_CONFIG sets these values first. Look at: sudo sshd -T -C user=$member,host=127.0.0.1,addr=127.0.0.1"
            fi
            impact_ok "The member '$member' gets the restricted values (key login only, forwarding only to 127.0.0.1 ports $port_min to $port_max)."
        else
            impact_info "The group '$group' has no member yet. impact-add-user confirms the restricted values for each new account."
        fi
    fi

    # --- 7. Reload the SSH service ------------------------------------------
    IMPACT__SSH_RELOADED=1
    impact_do "Reload the SSH service (open sessions stay open)" impact_ssh_reload ||
        impact_die "$IMPACT_EXIT_FAILED" "The SSH service could not be reloaded: $IMPACT_SSH_RELOAD_TEXT The previous state is put back." \
            "Keep this session open and look at: sudo systemctl status ssh"
    if [[ "$IMPACT_SSH_RELOAD_STATE" == 'none' ]] && ((was_listening == 1)); then
        # An SSH server answers, and the command found no way to make it
        # read the files again. It would keep its old settings while every
        # check that asks sshd -T reports the new ones, so the change is
        # treated as failed.
        impact_die "$IMPACT_EXIT_FAILED" "An SSH server answers on this machine, and no way was found to make it read the changed rules (no SSH service of systemd is active, and the PidFile of sshd names no running sshd). The previous state is put back." \
            "Find out how the SSH server is started here (sudo systemctl status ssh; ps -ef | grep sshd). Start it as the service ssh (sudo systemctl enable --now ssh), then run the command again."
    fi
    if [[ "$IMPACT_SSH_RELOAD_STATE" == 'reloaded' ]]; then
        impact_ok "$IMPACT_SSH_RELOAD_TEXT"
    else
        impact_warn "$IMPACT_SSH_RELOAD_TEXT"
    fi
    if ((was_listening == 1)); then
        # Give the server a moment to come back, then ask for its greeting.
        local attempt answered=0
        for attempt in 1 2 3 4 5; do
            if impact_ssh_listening; then
                answered=1
                break
            fi
            sleep 1
        done
        if ((answered == 0)); then
            impact_die "$IMPACT_EXIT_FAILED" "The SSH server answered before the reload and does not answer now. The previous state is put back." \
                "Keep this session open. Look at: sudo systemctl status ssh"
        fi
        impact_ok "The SSH server answers new connections."
    fi

    # The change is confirmed: the restore handler has nothing to do any
    # more, and the note of the unconfirmed change goes.
    IMPACT__SSH_PENDING=0
    impact__ssh_pending_clear
    IMPACT_SSH_RULES_CHANGED="$need_write"

    # --- 8. What the administrator does next --------------------------------
    impact_say ''
    impact_say '    IMPORTANT: keep this session open.'
    impact_say '    Open a second terminal window and log in to the workstation from there'
    impact_say '    with the administration account. Close this session only after that'
    impact_say '    login worked. If it fails, undo the change from this session:'
    if [[ "$mode" == 'install' ]]; then
        impact_say '        sudo impact-workstation-setup --remove-ssh-rules'
        impact_say '    (Members then have the normal SSH settings until the rules are written'
        impact_say '    again with sudo impact-workstation-setup.)'
    else
        impact_say '        sudo impact-workstation-setup'
    fi
    return 0
}

# impact__ssh_add_undo MODE PREVIOUS_EXISTED
#   Internal: adds the "How to undo" line of the SSH step.
#   install, no rules file before: remove the rules again.
#   install, a rules file before: no line here. The file follows from the
#     settings; impact-workstation-setup prints the one command that puts
#     the previous settings back, and that command writes the rules again.
#     Removing the rules would leave the members without any restriction.
#   remove: write the rules again.
impact__ssh_add_undo() {
    if [[ "$1" == 'install' ]]; then
        if [[ "$2" != '1' ]]; then
            impact_undo "$IMPACT_SSH_REMOVE_UNDO"
        fi
    else
        impact_undo "Write the SSH rules again: sudo impact-workstation-setup"
    fi
}

# impact_ssh_rules_install CONTENT_FILE GROUP PORT_MIN PORT_MAX
#   Installs CONTENT_FILE as /etc/ssh/sshd_config.d/60-impact.conf with the
#   fixed safety procedure:
#     1. sshd_config must read the rules folder; otherwise stop and explain.
#     2. Record the effective settings (sshd -T) of the account that ran sudo
#        and of root.
#     3. Write the new file under a temporary name, then rename it.
#     4. sshd -t must pass.
#     5. The recorded settings must be identical after the change.
#     6. When the group has a member: the member must get the restricted
#        values for the port range.
#     7. Reload the SSH service; open sessions stay open. The server must
#        answer afterwards when it answered before.
#     8. Print the instruction to test a login from a second window.
#   When any step from 3 on fails, or the command is interrupted, the
#   previous file is put back (or the new file removed) and the command ends
#   with exit code 1.
#   In a dry run the steps are printed and nothing is changed.
#   A file that already has the content is left alone (no reload).
#   Result: returns on success with IMPACT_SSH_RULES_CHANGED 1 or 0. On
#   failure it ends the command; it does not return.
#   Example: impact_ssh_rules_install "$rules_file" impact 8787 8830
impact_ssh_rules_install() {
    impact__ssh_rules_procedure install "$1" "$2" "$3" "$4"
}

# impact_ssh_rules_remove GROUP
#   Removes the rules file with the same safety procedure (steps 2 to 5, 7
#   and 8 of impact_ssh_rules_install). GROUP is used for messages only.
#   Result: as impact_ssh_rules_install.
#   Example: impact_ssh_rules_remove impact
impact_ssh_rules_remove() {
    impact__ssh_rules_procedure remove '' "${1:-}" '' ''
}
