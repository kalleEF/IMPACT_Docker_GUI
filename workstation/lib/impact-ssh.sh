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

# Internal state of the procedure.
IMPACT__SSH_PENDING=0         # 1 while a change of the rules file is unconfirmed
IMPACT__SSH_BACKUP=''         # copy of the previous rules file ('' = there was none)
IMPACT__SSH_RELOADED=0        # 1 when the service was reloaded with the new file
IMPACT__SSH_CHANGES_BEFORE=0  # length of the "What changed" list before the procedure
IMPACT__SSH_UNDO_BEFORE=0     # length of the "How to undo" list before the procedure

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

# impact_ssh_effective ACCOUNT [ADDRESS]
#   Prints every setting that sshd applies to a login of ACCOUNT coming from
#   ADDRESS (default 127.0.0.1), sorted, one "name value" per line. This is
#   "sshd -T -C user=...,host=...,addr=...": sshd evaluates its Match rules
#   for exactly this connection. Read-only; needs root rights.
#   Result: failure when the account name or address is unusable or sshd
#   reports an error (its text is then in IMPACT_SSH_OUTPUT).
#   Example: impact_ssh_effective alice | grep '^permitopen '
impact_ssh_effective() {
    local account="$1" address="${2:-127.0.0.1}" output status=0
    # The name goes into a comma-separated list for sshd; the name rule
    # allows neither commas nor blanks.
    impact__lookup_name_ok "$account" || return 1
    [[ "$address" =~ ^[0-9A-Fa-f:.]{2,45}$ ]] || return 1
    output="$("$IMPACT_SSHD" -T -C "user=$account,host=$address,addr=$address" 2>&1)" || status=$?
    if ((status != 0)); then
        IMPACT_SSH_OUTPUT="$output"
        return 1
    fi
    printf '%s\n' "$output" | sort
}

# impact_ssh_member_deviations ACCOUNT PORT_MIN PORT_MAX [ADDRESS]
#   Compares the effective settings of ACCOUNT with the twelve restricted
#   values of the rules. Prints one line per setting that deviates. Read-only.
#   Result: 0 when all twelve apply; 1 when at least one deviates; 2 when
#   sshd could not be asked.
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
    return "$deviations"
}

# impact_ssh_listening
#   Result: success when an SSH server answers on this machine: a connection
#   to its port on the loopback address delivers a greeting that starts with
#   "SSH-". Read-only; one connection is opened and closed.
impact_ssh_listening() {
    local port greeting host
    port="$("$IMPACT_SSHD" -T 2>/dev/null | awk '$1 == "port" { print $2; exit }')" || port=''
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || port=22
    for host in 127.0.0.1 ::1; do
        # bash opens a network connection through the special path
        # /dev/tcp/<host>/<port>. It runs in a separate bash with a time
        # limit, so a server that does not answer cannot stall the command.
        # shellcheck disable=SC2016
        # Reason for SC2016 (no expansion in single quotes): the inner bash
        # must expand $1 and $2 itself; they are handed over as arguments.
        greeting="$(timeout 6 bash -c 'exec 3<>"/dev/tcp/$1/$2" && IFS= read -r -t 4 -u 3 line && printf "%s" "$line"' _ "$host" "$port" 2>/dev/null)" || greeting=''
        if [[ "$greeting" == SSH-* ]]; then
            return 0
        fi
    done
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

    pid_file="$("$IMPACT_SSHD" -T 2>/dev/null | awk '$1 == "pidfile" { print $2; exit }')" || pid_file=''
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

# impact__ssh_rules_restore EXIT_CODE
#   Internal: runs when the command ends. While a change of the rules file is
#   unconfirmed, it puts the previous file back (or removes the new file when
#   there was none before), checks the result with sshd -t, and reloads the
#   service again when it had already read the new file.
impact__ssh_rules_restore() {
    ((IMPACT__SSH_PENDING == 1)) || return 0
    IMPACT__SSH_PENDING=0
    {
        printf '\nPutting the previous SSH rules back, because the change was not confirmed:\n'
        if [[ -n "$IMPACT__SSH_BACKUP" && -f "$IMPACT__SSH_BACKUP" ]]; then
            if impact_write_file_atomic "$IMPACT_SSH_RULES_FILE" 644 root root <"$IMPACT__SSH_BACKUP"; then
                printf '  The previous file %s is back in place.\n' "$IMPACT_SSH_RULES_FILE"
            else
                printf '  FAILED to put the previous file back. Look at %s now.\n' "$IMPACT_SSH_RULES_FILE"
            fi
        else
            if rm -f -- "$IMPACT_SSH_RULES_FILE"; then
                printf '  The new file %s was removed (there was none before).\n' "$IMPACT_SSH_RULES_FILE"
            else
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
                printf '  The SSH service could not be reloaded: %s\n' "$IMPACT_SSH_RELOAD_TEXT"
                printf '  Keep this session open and check the service: sudo systemctl status ssh\n'
            fi
        fi
    } >&2
    # The steps of the procedure are no longer true: remove them from the
    # lists for "What changed" and "How to undo". "${list[@]:0:n}" is the
    # first n entries of a list.
    IMPACT_CHANGES=("${IMPACT_CHANGES[@]:0:IMPACT__SSH_CHANGES_BEFORE}")
    IMPACT_UNDO=("${IMPACT_UNDO[@]:0:IMPACT__SSH_UNDO_BEFORE}")
}

# impact__ssh_rules_procedure MODE CONTENT_FILE GROUP PORT_MIN PORT_MAX
#   Internal: the shared body of impact_ssh_rules_install (MODE "install")
#   and impact_ssh_rules_remove (MODE "remove").
impact__ssh_rules_procedure() {
    local mode="$1" content_file="$2" group="$3" port_min="$4" port_max="$5"
    local invoker client_address before after member='' candidate
    local -a accounts=()
    local was_listening=0 write_text
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
        if impact_file_has_content "$IMPACT_SSH_RULES_FILE" "$content_file" &&
            impact_file_is "$IMPACT_SSH_RULES_FILE" 644 root root; then
            impact_ok "The rules file $IMPACT_SSH_RULES_FILE already has the requested content."
            return 0
        fi
        write_text="Write the SSH rules file $IMPACT_SSH_RULES_FILE (under a temporary name, then renamed)"
    else
        if [[ ! -e "$IMPACT_SSH_RULES_FILE" && ! -L "$IMPACT_SSH_RULES_FILE" ]]; then
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
        impact_info "A real run first records the effective SSH settings of: ${accounts[*]}."
        impact_do "$write_text"
        if [[ "$mode" == 'install' ]]; then
            impact_undo "Remove the SSH rules: sudo impact-workstation-setup --remove-ssh-rules"
        else
            impact_undo "Write the SSH rules again: sudo impact-workstation-setup"
        fi
        impact_info "A real run then checks the configuration (sshd -t), confirms that the settings of ${accounts[*]} are unchanged, and puts the previous state back if any check fails."
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
    local compare=1
    if ! impact_ssh_config_test; then
        if [[ "$mode" == 'install' ]]; then
            impact_error "sshd reports an error in the current SSH configuration:"
            printf '%s\n' "$IMPACT_SSH_OUTPUT" >&2
            impact_die "$IMPACT_EXIT_FAILED" \
                "The SSH configuration has an error before this command changed anything. Nothing was changed." \
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
    IMPACT__SSH_CHANGES_BEFORE="${#IMPACT_CHANGES[@]}"
    IMPACT__SSH_UNDO_BEFORE="${#IMPACT_UNDO[@]}"
    IMPACT__SSH_RELOADED=0
    IMPACT__SSH_PENDING=1
    impact_on_exit impact__ssh_rules_restore

    # --- 3. Write the new file (temporary name, then rename) ----------------
    if [[ "$mode" == 'install' ]]; then
        impact_do "$write_text" impact_write_file_atomic "$IMPACT_SSH_RULES_FILE" 644 root root <"$content_file" ||
            impact_die "$IMPACT_EXIT_FAILED" "The rules file could not be written." ""
        impact_undo "Remove the SSH rules: sudo impact-workstation-setup --remove-ssh-rules"
    else
        impact_do "$write_text" rm -f -- "$IMPACT_SSH_RULES_FILE" ||
            impact_die "$IMPACT_EXIT_FAILED" "The rules file could not be removed." ""
        impact_undo "Write the SSH rules again: sudo impact-workstation-setup"
    fi

    # --- 4. sshd -t ---------------------------------------------------------
    if ! impact_ssh_config_test; then
        impact_error "sshd -t reports an error with the changed rules:"
        printf '%s\n' "$IMPACT_SSH_OUTPUT" >&2
        impact_die "$IMPACT_EXIT_FAILED" "The SSH configuration would be invalid. The previous state is put back." \
            "Read the message of sshd above. The SSH service was not reloaded, so nothing changed for logins."
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

    # The change is confirmed: the restore handler has nothing to do any more.
    IMPACT__SSH_PENDING=0
    IMPACT_SSH_RULES_CHANGED=1

    # --- 8. What the administrator does next --------------------------------
    impact_say ''
    impact_say '    IMPORTANT: keep this session open.'
    impact_say '    Open a second terminal window and log in to the workstation from there'
    impact_say '    with the administration account. Close this session only after that'
    impact_say '    login worked. If it fails, undo the change from this session:'
    if [[ "$mode" == 'install' ]]; then
        impact_say '        sudo impact-workstation-setup --remove-ssh-rules'
    else
        impact_say '        sudo impact-workstation-setup'
    fi
    return 0
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
