#!/bin/bash
# =============================================================================
# impact-common.sh: shared functions for the IMPACT workstation commands
#
# Purpose
#   Every command in ../bin (for example impact-workstation-setup) loads this
#   file first. It gives all commands the same behaviour for: messages,
#   --dry-run, option parsing, the log, temporary files, the confirmation
#   prompt and the final summary. At its end it loads the topic files that
#   lie next to it:
#     impact-settings.sh   the settings file and the model file
#     impact-accounts.sh   accounts, groups, SSH keys, files in a home folder
#     impact-storage.sh    shared storage folders and their access rules
#     impact-ssh.sh        the SSH rules for the group and the SSH service
#     impact-docker.sh     read-only questions to Docker
#
# Who runs it
#   Nobody runs this file directly. A command loads it with "source", which
#   means: read the file and define everything in it inside the running
#   script.
#
# Usage (inside a command)
#   IMPACT_SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
#   source "$(dirname -- "$IMPACT_SELF")/../lib/impact-common.sh"
#   impact_init "$IMPACT_SELF"
#   impact_parse_args 'dry-run yes' 'account' '' "$@"
#
# What it changes on the system
#   Loading the file changes nothing on the system. Inside the running script
#   it sets a fixed search path for programs (PATH) and the language of tool
#   output (LC_ALL=C). The functions change the system only when a command
#   calls them.
#
# How to undo
#   Nothing to undo for the file itself. Each command prints its own
#   "How to undo" list.
#
# Naming
#   impact_name     a function that commands may call
#   impact__name    (two underscores) an internal helper of the library
#   IMPACT_NAME     a variable that commands may read
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

# The two lines for the checking tool "shellcheck" must stand before the first
# command of the file to count for the whole file.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034
# Reason for SC2034 (variable appears unused): this file defines variables
# that the commands and the topic files read after loading it. shellcheck
# checks one file at a time and cannot see those uses.

# This file is loaded once per script. "${VAR:-}" means: the value of VAR, or
# an empty text when VAR was never set. Without the ":-" part, bash would stop
# with an error for an unset variable once "set -u" is active.
if [[ -n "${IMPACT_COMMON_LOADED:-}" ]]; then
    return 0
fi
IMPACT_COMMON_LOADED=1

# The commands need bash 4.4 or newer (Ubuntu 22.04 has 5.1). BASH_VERSINFO
# is a list that bash fills with its own version: entry 0 is the major
# number, entry 1 the minor number. "((...))" is arithmetic: it is true when
# the result is not zero.
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
    printf 'ERROR: these commands need bash 4.4 or newer. This is bash %s.\n' "$BASH_VERSION" >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# A fixed, safe environment for every command
# -----------------------------------------------------------------------------

# PATH is the list of folders in which the shell looks for programs. A fixed
# list of system folders makes sure that "git", "docker" and all other tools
# are the ones installed by the system, whatever the calling account has in
# its own PATH. All six folders belong to root.
readonly IMPACT_SAFE_PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
PATH="$IMPACT_SAFE_PATH"
export PATH

# LC_ALL=C makes every tool print in its fixed, English form. The commands
# read the output of tools such as "getent" and "stat", and a translated or
# differently sorted output would break that.
LC_ALL=C
export LC_ALL

# IFS lists the characters at which bash splits words: space, tab, new line.
# Setting it here protects against a changed value in the calling environment.
IFS=$' \t\n'

# CDPATH changes how "cd" finds folders. The commands must never depend on it.
unset -v CDPATH

# -----------------------------------------------------------------------------
# Fixed places on the workstation (the same on every installation)
# -----------------------------------------------------------------------------
readonly IMPACT_CONF_DIR='/etc/impact'
readonly IMPACT_CONF_FILE='/etc/impact/impact.conf'
readonly IMPACT_KNOWN_HOSTS_FILE='/etc/impact/github_known_hosts'
readonly IMPACT_INSTALL_DIR='/opt/impact'
readonly IMPACT_BIN_DIR='/opt/impact/bin'
readonly IMPACT_LINK_DIR='/usr/local/bin'
readonly IMPACT_ADMIN_DIR='/opt/impact/admin'
readonly IMPACT_LOG_DIR='/opt/impact/admin/log'
readonly IMPACT_LOG_FILE='/opt/impact/admin/log/impact-admin.log'
readonly IMPACT_KEYS_DIR='/opt/impact/admin/keys'
readonly IMPACT_ACCOUNTS_DIR='/opt/impact/admin/accounts'
readonly IMPACT_ACL_BACKUP_DIR='/opt/impact/admin/acl-backups'
readonly IMPACT_STATE_DIR='/opt/impact/admin/state'
readonly IMPACT_SSHD_CONFIG='/etc/ssh/sshd_config'
readonly IMPACT_SSH_RULES_DIR='/etc/ssh/sshd_config.d'
readonly IMPACT_SSH_RULES_FILE='/etc/ssh/sshd_config.d/60-impact.conf'
readonly IMPACT_LOCK_DIR='/run/impact'

# The tools that the IMPACT commands use, in one list. install.sh refuses to
# install while one of them is missing (it prints the apt-get line), and
# impact-check names missing ones. All of them come with a default Ubuntu
# server installation plus the packages acl, git and curl. Docker is checked
# separately, because it does not come from Ubuntu's own package source.
# "readonly -a" makes a list that cannot be changed later.
readonly -a IMPACT_NEEDED_TOOLS=(
    sshd ssh-keygen ssh getfacl setfacl git curl runuser findmnt flock mountpoint
    getent iconv useradd usermod userdel groupadd gpasswd chage passwd realpath
    stat install mktemp sha256sum timeout tar gzip awk sed grep diff cmp find
    xargs ps pkill hostname dpkg-query ss df du sync chgrp chown chmod head
    tail cut sort uniq tr date id uname nproc uptime
)

# Exit codes. A command ends with one of these numbers; 0 means success.
readonly IMPACT_EXIT_OK=0            # success, also "nothing to do"
readonly IMPACT_EXIT_FAILED=1        # a check failed or the operation failed
readonly IMPACT_EXIT_USAGE=2         # wrong usage (options, arguments, account)
readonly IMPACT_EXIT_NOT_PREPARED=3  # settings file missing or invalid
readonly IMPACT_EXIT_CONFLICT=4      # target exists or request conflicts
readonly IMPACT_EXIT_NO_ACCESS=5     # no access, for example GitHub refused
readonly IMPACT_EXIT_NETWORK=6       # network problem

# The folder of this library, and the folder one level above it (in an
# installation that is /opt/impact). BASH_SOURCE[0] is the path of the file
# that bash is reading right now.
IMPACT_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly IMPACT_LIB_DIR
IMPACT_BASE_DIR="$(dirname -- "$IMPACT_LIB_DIR")"
readonly IMPACT_BASE_DIR

# -----------------------------------------------------------------------------
# State of the running command
# -----------------------------------------------------------------------------
IMPACT_SELF="${IMPACT_SELF:-$0}"   # path of the running command
IMPACT_CMD="$(basename -- "$IMPACT_SELF")"   # its name, for messages
IMPACT_DRY_RUN=0                   # 1 after --dry-run
IMPACT_ASSUME_YES=0                # 1 after --yes
IMPACT_STEP_NO=0                   # counter for the numbered steps
IMPACT_WARN_COUNT=0                # number of warnings printed so far
IMPACT_FAIL_COUNT=0                # number of failed checks printed so far
IMPACT_HTTP_STATUS=''              # HTTP status code of the last impact_https_get
IMPACT_CHANGES=()                  # texts of the changing steps that ran
IMPACT_UNDO=()                     # texts for the "How to undo" list
IMPACT_SUMMARY_DONE=0              # 1 once the final summary was printed
IMPACT_LOG_ENABLED=0               # 1 after impact_log_enable
IMPACT_LOG_ARGS=()                 # the arguments of the command, for the log
IMPACT_LOG_NOTES=()                # extra lines for the log block
IMPACT_TMP_ITEMS=()                # temporary files and folders to remove
IMPACT_EXIT_HANDLERS=()            # functions to call when the command ends
IMPACT_RESULT_ENABLED=0            # 1 = print the IMPACT_RESULT line at the end
IMPACT_RESULT_PATH=''              # the path reported in that line
IMPACT_RESULT_REASON=''            # the one-word reason reported in that line
IMPACT_EXITING=0                   # 1 while the end-of-command work runs
IMPACT_MASK_NAMES=()               # extra host names for impact_mask_text
IMPACT__LOCK_FD=''                 # open handle of the lock file (impact_lock)
IMPACT__MASK_PID=''                # process number of the masking filter (impact_mask_output_start)

# "declare -A" creates an associative array: a list whose entries are found
# by a name. "-g" makes it global even though the line may be read inside a
# function (when a function loads this file).
declare -gA IMPACT_OPT=()          # options given on the command line
IMPACT_ARGS=()                     # the other (positional) arguments

# =============================================================================
# Start-up
# =============================================================================

# impact_init SCRIPT_PATH
#   Prepares a command: remembers its path and name, sets a predictable file
#   mode mask, and installs the handlers that run when the command ends or is
#   interrupted.
#   Parameter: the full path of the running command.
#   Result: none. Call it once, directly after loading this file.
impact_init() {
    IMPACT_SELF="${1:-$0}"
    IMPACT_CMD="$(basename -- "$IMPACT_SELF")"

    # umask removes rights from every file the command creates. 022 means:
    # new files are readable by everybody and writable by the owner only.
    # Places that need tighter rights get them explicitly.
    umask 022

    # Docker must always talk to the daemon of this machine. These variables
    # could point the "docker" program to another machine.
    unset -v DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH

    # "trap" tells bash to run a function at a certain event. EXIT is the end
    # of the script for whatever reason. INT is Ctrl+C, TERM a polite request
    # to end, HUP a closed terminal. After a signal the command ends with the
    # usual code 128 plus the signal number, and the EXIT handler still runs.
    trap 'impact__on_exit' EXIT
    trap 'impact__on_signal INT 130' INT
    trap 'impact__on_signal TERM 143' TERM
    trap 'impact__on_signal HUP 129' HUP
}

# impact__on_signal NAME EXIT_CODE
#   Internal: reacts to Ctrl+C and similar signals. It prints one line and
#   ends the command; the EXIT handler then cleans up and reports what was
#   changed up to that moment.
impact__on_signal() {
    printf '\nERROR: %s was interrupted (signal %s).\n' "$IMPACT_CMD" "$1" >&2
    exit "$2"
}

# impact_on_exit FUNCTION_NAME
#   Registers a function that runs when the command ends, also after an error
#   or Ctrl+C. Use it for work that must never be skipped, for example putting
#   back a file that was changed halfway. The function receives the exit code
#   as its first parameter. Functions run in reverse order of registration.
#   Result: none.
impact_on_exit() {
    IMPACT_EXIT_HANDLERS+=("$1")
}

# impact__on_exit
#   Internal: the end-of-command work. Order: registered handlers, the report
#   for a command that stopped early, the log block, release of the lock,
#   removal of temporary files, and the machine-readable result line (only
#   for the two commands that the GUI calls).
impact__on_exit() {
    # "$?" is the exit code of the last command; it must be read first.
    local code=$?
    # Remove the handlers so that nothing here can start them a second time.
    trap - EXIT INT TERM HUP
    # "set +e" switches off "stop at the first error": the clean-up must
    # continue even when one of its steps fails.
    set +e
    IMPACT_EXITING=1

    local index
    # Walk through the registered handlers backwards (last registered first).
    for ((index = ${#IMPACT_EXIT_HANDLERS[@]} - 1; index >= 0; index--)); do
        "${IMPACT_EXIT_HANDLERS[index]}" "$code"
    done

    if ((code != 0 && IMPACT_SUMMARY_DONE == 0 && ${#IMPACT_CHANGES[@]} > 0)); then
        impact__print_partial_summary "$code"
    fi

    impact__write_log "$code"

    if [[ -n "$IMPACT__LOCK_FD" ]]; then
        # Give the lock back now. A program that this command started and
        # that still runs holds the same open file; "flock -u" releases the
        # lock for all of them.
        flock -u "$IMPACT__LOCK_FD" 2>/dev/null
    fi

    local item
    for item in "${IMPACT_TMP_ITEMS[@]}"; do
        # "rm -rf --" removes a file or a whole folder; "--" ends the options
        # so that a name starting with "-" is never read as an option.
        [[ -n "$item" ]] && rm -rf -- "$item"
    done

    if ((IMPACT_RESULT_ENABLED)); then
        impact__print_result_line "$code"
    fi
    impact__mask_output_end
    exit "$code"
}

# =============================================================================
# Messages
# =============================================================================

# impact_display TEXT [MAXIMUM]
#   Prints TEXT in a form that is safe to show on a terminal and in the log:
#   control characters (for example escape sequences or line breaks) become
#   "?", and a very long text is cut after MAXIMUM characters (default 200).
#   Use it for every value that comes from input before it appears in a
#   message.
#   Result: the cleaned text on standard output.
impact_display() {
    local text="${1:-}" maximum="${2:-200}"
    # "${text//pattern/replacement}" replaces every match. [[:cntrl:]] is the
    # class of control characters.
    text="${text//[[:cntrl:]]/?}"
    # "${#text}" is the length; "${text:0:N}" the first N characters.
    if ((${#text} > maximum)); then
        text="${text:0:maximum}..."
    fi
    printf '%s' "$text"
}

# impact_say TEXT
#   Prints one plain line.
impact_say() {
    printf '%s\n' "$*"
}

# impact_step TITLE
#   Prints the heading of the next numbered step, for example "Step 2: Group".
impact_step() {
    IMPACT_STEP_NO=$((IMPACT_STEP_NO + 1))
    printf '\nStep %d: %s\n' "$IMPACT_STEP_NO" "$*"
}

# impact_info TEXT
#   Prints a detail line below a step heading.
impact_info() {
    printf '    %s\n' "$*"
}

# impact_ok TEXT
#   Prints a line for a check that passed or a state that is already right.
impact_ok() {
    printf '    OK: %s\n' "$*"
}

# impact_warn TEXT
#   Prints a warning and counts it. The command continues. The final summary
#   mentions the number of warnings.
impact_warn() {
    IMPACT_WARN_COUNT=$((IMPACT_WARN_COUNT + 1))
    printf '    WARNING: %s\n' "$*"
}

# impact_fail TEXT
#   Prints a line for a check that failed, counts it, and continues. For
#   commands that report several checks and go on, such as impact-check; the
#   counters IMPACT_FAIL_COUNT and IMPACT_WARN_COUNT then decide the exit
#   code. Use impact_die when the command must stop.
impact_fail() {
    IMPACT_FAIL_COUNT=$((IMPACT_FAIL_COUNT + 1))
    printf '    FAIL: %s\n' "$*"
}

# impact_error TEXT
#   Prints an error line on the error channel (">&2") and continues. Use
#   impact_die when the command must stop.
impact_error() {
    printf 'ERROR: %s\n' "$*" >&2
}

# impact_die EXIT_CODE CAUSE [NEXT_STEP]
#   Stops the command. Prints the cause and what to do next.
#   Parameters: one of the IMPACT_EXIT_ numbers, the cause in plain words, and
#   the next step for the reader. Without a next step a general one is
#   printed: read the messages above (a tool usually names the details there)
#   and run the command again after the cause is fixed.
#   Result: never returns. Inside "$( ... )" it ends only that inner shell, so
#   call it from the main flow of a command.
impact_die() {
    local code="$1" cause="$2" next="${3:-}"
    if [[ -z "$next" ]]; then
        next="Read the messages above for the details. Fix the cause, then run $IMPACT_CMD again; steps that are done already are not repeated."
    fi
    printf '\nERROR: %s\n' "$cause" >&2
    printf 'What to do: %s\n' "$next" >&2
    exit "$code"
}

# impact_die_usage CAUSE
#   Stops the command with exit code 2 (wrong usage) and points to --help.
impact_die_usage() {
    impact_die "$IMPACT_EXIT_USAGE" "$1" "Run '$IMPACT_CMD --help' to see the usage."
}

# impact_die_reason EXIT_CODE REASON_WORD CAUSE [NEXT_STEP]
#   As impact_die, and it sets the one-word reason of the IMPACT_RESULT line.
#   For the two commands that the GUI calls (see impact_result_enable).
impact_die_reason() {
    IMPACT_RESULT_REASON="$2"
    impact_die "$1" "$3" "${4:-}"
}

# =============================================================================
# The machine-readable result line (impact-get-repo, impact-update-setup)
# =============================================================================

# impact_result_enable
#   Switches on the result line. From then on the very last line of output is
#     IMPACT_RESULT status=<ok|error> code=<exit code> path=<path> reason=<word>
#   whatever way the command ends. The GUI reads this line.
impact_result_enable() {
    IMPACT_RESULT_ENABLED=1
}

# impact_result_set PATH [REASON_WORD]
#   Sets the path and, optionally, the reason for the result line. The reason
#   is one word of lower-case letters, digits and "_", for example "cloned".
impact_result_set() {
    IMPACT_RESULT_PATH="$1"
    if [[ -n "${2:-}" ]]; then
        IMPACT_RESULT_REASON="$2"
    fi
}

# impact__print_result_line EXIT_CODE
#   Internal: prints the result line. A missing reason is derived from the
#   exit code. Unsafe characters are removed so the line always has the same
#   shape.
impact__print_result_line() {
    local code="$1" status='ok' reason="$IMPACT_RESULT_REASON" path="$IMPACT_RESULT_PATH"
    if ((code != 0)); then
        status='error'
    fi
    if [[ -z "$reason" ]]; then
        # "case" compares one value with several patterns.
        case "$code" in
            0) reason='ok' ;;
            1) reason='failed' ;;
            2) reason='usage' ;;
            3) reason='not_prepared' ;;
            4) reason='exists' ;;
            5) reason='no_access' ;;
            6) reason='network' ;;
            130 | 143 | 129) reason='interrupted' ;;
            *) reason='failed' ;;
        esac
    fi
    # Keep only harmless characters. "[^...]" matches every character that is
    # not in the list.
    reason="${reason//[^a-z0-9_]/}"
    path="${path//[^A-Za-z0-9._\/-]/}"
    printf 'IMPACT_RESULT status=%s code=%s path=%s reason=%s\n' "$status" "$code" "$path" "$reason"
}

# =============================================================================
# Dry run, steps that change something, and the final summary
# =============================================================================

# impact_is_dry_run
#   Result: success (exit status 0) when the command runs with --dry-run.
#   Example: if impact_is_dry_run; then ... fi
impact_is_dry_run() {
    ((IMPACT_DRY_RUN == 1))
}

# impact_do [--transient] TEXT COMMAND [ARGUMENTS...]
#   The one way to change something. It prints TEXT, and
#     in a real run: runs COMMAND and remembers TEXT for "What changed";
#     in a dry run:  runs nothing and remembers TEXT for the preview.
#   The printed words are the same in both cases; a dry run adds the mark
#   "[dry run]".
#   Parameters:
#     --transient  the step leaves nothing behind (for example a write test
#                  that removes its own file); it is printed, and it is left
#                  out of "What changed".
#     TEXT         the step in plain words, starting with a verb.
#     COMMAND...   the program or function to run, with its arguments.
#   Result: 0 on success and in a dry run; the exit code of COMMAND when it
#   failed (an error line is printed).
#   Important: never call impact_do inside "$( ... )" or after a "|", because
#   bash runs those parts in a copy of the script and the list of changes
#   would be lost. Inside a function that impact_do starts, "stop at the first
#   error" is switched off by bash, so such a function must check its own
#   steps (join them with "&&" or use "|| return 1").
impact_do() {
    local record=1
    if [[ "${1:-}" == '--transient' ]]; then
        record=0
        shift
    fi
    local text="$1"
    shift
    if ((IMPACT_DRY_RUN == 1)); then
        printf '  + [dry run] %s\n' "$text"
        if ((record == 1)); then
            IMPACT_CHANGES+=("$text")
        fi
        return 0
    fi
    printf '  + %s\n' "$text"
    local status=0
    # "$@" is the command with all its arguments, each kept as one word.
    # "|| status=$?" stores a failure code and keeps the script running.
    "$@" || status=$?
    if ((status != 0)); then
        impact_error "This step failed (exit code $status): $text"
        return "$status"
    fi
    if ((record == 1)); then
        IMPACT_CHANGES+=("$text")
    fi
    return 0
}

# impact_changed TEXT
#   Adds a line to "What changed" for a change that was made without
#   impact_do. In a dry run it adds the line to the preview.
impact_changed() {
    IMPACT_CHANGES+=("$1")
}

# impact_undo TEXT
#   Adds a line to the "How to undo" list. Call it next to the impact_do that
#   it belongs to, so the hint appears only when the step really ran.
impact_undo() {
    IMPACT_UNDO+=("$1")
}

# impact__print_list MARK ITEM...
#   Internal: prints each item on its own line after the given mark.
impact__print_list() {
    local mark="$1" item
    shift
    for item in "$@"; do
        printf '  %s %s\n' "$mark" "$item"
    done
}

# impact_summary
#   Prints the end of a command: "What changed" and "How to undo", or the
#   statement that nothing had to be changed. Call it as the last step.
#   Result: none.
impact_summary() {
    IMPACT_SUMMARY_DONE=1
    printf '\n'
    if ((${#IMPACT_CHANGES[@]} == 0)); then
        if ((IMPACT_DRY_RUN == 1)); then
            impact_say 'Dry run: nothing was changed. A real run would change nothing either: everything is already in the requested state.'
        else
            impact_say 'Nothing to do: everything is already in the requested state. Nothing was changed.'
        fi
    else
        if ((IMPACT_DRY_RUN == 1)); then
            impact_say 'Dry run: nothing was changed. A real run would do this:'
        else
            impact_say 'What changed:'
        fi
        impact__print_list '+' "${IMPACT_CHANGES[@]}"
        if ((${#IMPACT_UNDO[@]} > 0)); then
            if ((IMPACT_DRY_RUN == 1)); then
                impact_say 'How to undo it afterwards:'
            else
                impact_say 'How to undo:'
            fi
            impact__print_list '-' "${IMPACT_UNDO[@]}"
        fi
    fi
    if ((IMPACT_WARN_COUNT > 0)); then
        impact_say "Warnings printed above: $IMPACT_WARN_COUNT. Please read them."
    fi
}

# impact__print_partial_summary EXIT_CODE
#   Internal: for a command that stopped early. It lists the steps that had
#   already run, so the administrator knows the state of the machine.
impact__print_partial_summary() {
    {
        printf '\n%s stopped before it finished (exit code %s).\n' "$IMPACT_CMD" "$1"
        if ((IMPACT_DRY_RUN == 1)); then
            printf 'This was a dry run: nothing was changed.\n'
        else
            printf 'These steps had already run:\n'
            impact__print_list '+' "${IMPACT_CHANGES[@]}"
            if ((${#IMPACT_UNDO[@]} > 0)); then
                printf 'How to undo them:\n'
                impact__print_list '-' "${IMPACT_UNDO[@]}"
            fi
            printf 'The command is safe to run again after the cause is fixed.\n'
        fi
    } >&2
}

# =============================================================================
# Who runs the command
# =============================================================================

# impact_require_root
#   Stops the command (exit code 2) unless it runs as root. Administrator
#   commands call it after the options were read, so --help works for anyone.
impact_require_root() {
    # EUID is the number of the account whose rights the script has; 0 is root.
    if ((EUID != 0)); then
        impact_die "$IMPACT_EXIT_USAGE" \
            "$IMPACT_CMD must run with administrator rights." \
            "Run it again with sudo in front: sudo $IMPACT_CMD ..."
    fi
}

# impact_require_not_root [NEXT_STEP]
#   Stops the command (exit code 2) when it runs as root. The two user
#   commands call it: a working copy must belong to the person.
#   Parameter: optionally the text "What to do" for this command. Without it
#   the text names the person's own account and impact-give-repo, the way
#   the administrator makes a working copy for a person.
impact_require_not_root() {
    local next="${1:-}"
    if [[ -z "$next" ]]; then
        next="Run it without sudo from the person's own account, or use: sudo impact-give-repo <account> <model>"
    fi
    if ((EUID == 0)); then
        IMPACT_RESULT_REASON='run_as_root'
        impact_die "$IMPACT_EXIT_USAGE" \
            "$IMPACT_CMD must run as the person who will own the files, and it was started as root." \
            "$next"
    fi
}

# impact_lock NAME
#   Makes sure that only one command works on the same things at a time.
#   The command takes the lock NAME; a second command that asks for the same
#   NAME while the first one runs ends with exit code 4 and a message. The
#   lock is a file in /run/impact (a folder in memory that only root can
#   use) and is released by the system when the command ends, however it
#   ends. In a dry run no lock is taken, because nothing is changed.
#   Parameter: a short name of lower-case letters, digits and "-", for
#   example "setup" or "accounts". Commands that must never run side by
#   side use the same name.
#   Result: returns when the lock was taken (or in a dry run). Ends the
#   command when another command holds it. Needs root rights.
#   The lock is given back at the end of the command, also when a program
#   that the command started is still running.
#   Example: impact_lock accounts
impact_lock() {
    local name="$1" file
    if ! [[ "$name" =~ ^[a-z][a-z0-9-]{0,40}$ ]]; then
        impact_die "$IMPACT_EXIT_FAILED" "impact_lock: '$(impact_display "$name")' is no valid lock name." ""
    fi
    if ((IMPACT_DRY_RUN == 1)); then
        return 0
    fi
    if ((EUID != 0)); then
        impact_die "$IMPACT_EXIT_FAILED" "impact_lock needs root rights." ""
    fi
    if [[ -L "$IMPACT_LOCK_DIR" ]]; then
        impact_die "$IMPACT_EXIT_FAILED" "$IMPACT_LOCK_DIR is a symbolic link; a real folder is expected." "Look at it: ls -ld $IMPACT_LOCK_DIR"
    fi
    install -d -m 700 -o root -g root -- "$IMPACT_LOCK_DIR" ||
        impact_die "$IMPACT_EXIT_FAILED" "The folder $IMPACT_LOCK_DIR could not be created." ""
    file="$IMPACT_LOCK_DIR/$name.lock"
    # "exec {NAME}>>file" opens the file and stores the number of the open
    # handle in the variable NAME. ">>" never empties an existing file.
    if ! { exec {IMPACT__LOCK_FD}>>"$file"; } 2>/dev/null; then
        IMPACT__LOCK_FD=''
        impact_die "$IMPACT_EXIT_FAILED" "The lock file $file could not be opened." ""
    fi
    # flock -n takes the lock on the open file, or fails at once when
    # another process holds it.
    if ! flock -n "$IMPACT__LOCK_FD"; then
        impact_die "$IMPACT_EXIT_CONFLICT" "Another IMPACT command that changes the same things is running at this moment." \
            "Wait until it has finished, then run this command again. (Lock: $file)"
    fi
}

# impact_invoking_account
#   Prints the name of the account that started the command: with sudo that
#   is the account that typed "sudo" (sudo stores it in SUDO_USER), otherwise
#   the current account. The log and the SSH safety check use it.
#   Result: one account name on standard output.
impact_invoking_account() {
    local name="${SUDO_USER:-}"
    # "=~" compares with a regular expression (a text pattern). The pattern is
    # the rule for Linux account names; anything else in SUDO_USER is ignored.
    if [[ -n "$name" && "$name" =~ ^[a-z_][-a-z0-9_.]{0,63}\$?$ ]] && getent passwd -- "$name" >/dev/null 2>&1; then
        printf '%s\n' "$name"
        return 0
    fi
    id -un
}

# =============================================================================
# Options and arguments
# =============================================================================

# impact_show_help
#   Prints the help text of the running command: the comment block at the top
#   of its file, without the leading "# ". Every command therefore documents
#   itself in one place.
impact_show_help() {
    local line started=0
    # "while IFS= read -r line" reads a file line by line, exactly as written.
    while IFS= read -r line; do
        if [[ "$line" == '#!'* ]]; then
            continue
        fi
        if [[ "$line" == '#'* ]]; then
            started=1
            # Skip the decoration lines made of "=" or "-".
            if [[ "$line" =~ ^#[[:space:]]*[=-]{10,}[[:space:]]*$ ]]; then
                continue
            fi
            line="${line#\#}"      # remove the leading "#"
            line="${line# }"       # and one space after it
            printf '%s\n' "$line"
        elif ((started == 1)); then
            break
        fi
    done <"$IMPACT_SELF"
}

# impact_parse_args FLAGS VALUE_OPTIONS LIST_OPTIONS ARGUMENTS...
#   Reads the command line. All options are long options ("--name").
#   Parameters:
#     FLAGS          names of options without a value, separated by spaces,
#                    for example 'dry-run yes existing'
#     VALUE_OPTIONS  names of options with one value ("--uid 1005" or
#                    "--uid=1005"); giving one twice is an error
#     LIST_OPTIONS   names of options that may be given several times
#     ARGUMENTS      the arguments of the command: "$@"
#   Result:
#     IMPACT_OPT[name]  "1" for a given flag, the value for a value option,
#                       the values separated by line breaks for a list option
#     IMPACT_ARGS       the remaining arguments in order
#     IMPACT_DRY_RUN=1 after --dry-run, IMPACT_ASSUME_YES=1 after --yes
#   --help prints the help text and ends the command with exit code 0.
#   An unknown option, a missing value or a control character in any argument
#   ends the command with exit code 2.
#   Example: impact_parse_args 'dry-run yes' 'account uid' 'storage' "$@"
impact_parse_args() {
    local flags=" $1 " values=" $2 " lists=" $3 "
    shift 3
    IMPACT_OPT=()
    IMPACT_ARGS=()
    local arg name value has_value

    # First pass: --help wins over everything else, and no argument may
    # contain control characters (they could forge lines in the log).
    for arg in "$@"; do
        if [[ "$arg" == '--' ]]; then
            break
        fi
        if [[ "$arg" == '--help' ]]; then
            impact_show_help
            exit "$IMPACT_EXIT_OK"
        fi
    done
    for arg in "$@"; do
        if [[ "$arg" =~ [[:cntrl:]] ]]; then
            impact_die_usage "An argument contains a control character (for example a line break or a tab): '$(impact_display "$arg")'."
        fi
    done

    # "(($# > 0))": "$#" is the number of arguments that are left.
    while (($# > 0)); do
        arg="$1"
        shift
        case "$arg" in
            --)
                # Everything after "--" is an argument, never an option.
                IMPACT_ARGS+=("$@")
                break
                ;;
            --*=*)
                name="${arg%%=*}"   # the part before the first "="
                name="${name#--}"   # without the leading "--"
                value="${arg#*=}"   # the part after the first "="
                has_value=1
                ;;
            --*)
                name="${arg#--}"
                value=''
                has_value=0
                ;;
            -?*)
                impact_die_usage "Unknown option '$(impact_display "$arg")'. The options of this command start with two dashes, for example --help."
                ;;
            *)
                IMPACT_ARGS+=("$arg")
                continue
                ;;
        esac

        if ! [[ "$name" =~ ^[a-z][a-z0-9-]*$ ]]; then
            impact_die_usage "Unknown option '$(impact_display "$arg")'."
        fi

        # The lists carry a space at both ends, so " name " matches whole
        # names only.
        if [[ "$flags" == *" $name "* ]]; then
            if ((has_value == 1)); then
                impact_die_usage "The option --$name takes no value."
            fi
            IMPACT_OPT[$name]=1
            case "$name" in
                dry-run) IMPACT_DRY_RUN=1 ;;
                yes) IMPACT_ASSUME_YES=1 ;;
                *) ;;
            esac
        elif [[ "$values" == *" $name "* || "$lists" == *" $name "* ]]; then
            if ((has_value == 0)); then
                if (($# == 0)); then
                    impact_die_usage "The option --$name needs a value."
                fi
                value="$1"
                shift
                if [[ "$value" == --* ]]; then
                    impact_die_usage "The option --$name needs a value, and the next word is the option '$(impact_display "$value")'."
                fi
            fi
            if [[ "$values" == *" $name "* ]]; then
                # "-v" asks whether the entry exists at all.
                if [[ -v IMPACT_OPT[$name] ]]; then
                    impact_die_usage "The option --$name was given twice."
                fi
                IMPACT_OPT[$name]="$value"
            elif [[ -v IMPACT_OPT[$name] ]]; then
                IMPACT_OPT[$name]+=$'\n'"$value"
            else
                IMPACT_OPT[$name]="$value"
            fi
        else
            impact_die_usage "Unknown option '--$name'."
        fi
    done

    if ((IMPACT_DRY_RUN == 1)); then
        impact_say "DRY RUN: $IMPACT_CMD only shows what it would do. Nothing is changed."
    fi
}

# impact_opt_given NAME
#   Result: success when the option --NAME was given.
#   Example: if impact_opt_given existing; then ... fi
impact_opt_given() {
    [[ -v IMPACT_OPT[$1] ]]
}

# impact_opt NAME [DEFAULT]
#   Prints the value of the option --NAME, or DEFAULT when it was not given.
#   Example: uid="$(impact_opt uid '')"
impact_opt() {
    if [[ -v IMPACT_OPT[$1] ]]; then
        printf '%s' "${IMPACT_OPT[$1]}"
    else
        printf '%s' "${2:-}"
    fi
}

# impact_opt_list NAME ARRAY_NAME
#   Copies the values of a list option into the array ARRAY_NAME (empty when
#   the option was not given).
#   Example: impact_opt_list storage roots; for root in "${roots[@]}"; do ...
impact_opt_list() {
    # "local -n" makes a second name for a variable of the caller, so this
    # function can fill an array that the caller owns.
    local -n impact__list_target="$2"
    impact__list_target=()
    if [[ -v IMPACT_OPT[$1] ]]; then
        # "mapfile -t" reads lines into an array. "<<<" hands a text to a
        # command as its input.
        mapfile -t impact__list_target <<<"${IMPACT_OPT[$1]}"
    fi
}

# impact_require_arg_count MINIMUM MAXIMUM
#   Stops with exit code 2 unless the number of arguments (IMPACT_ARGS) lies
#   between MINIMUM and MAXIMUM.
impact_require_arg_count() {
    local count="${#IMPACT_ARGS[@]}"
    if ((count < $1)); then
        impact_die_usage "An argument is missing: $IMPACT_CMD needs $1 and got $count."
    fi
    if ((count > $2)); then
        impact_die_usage "Too many arguments: $IMPACT_CMD takes at most $2 and got $count. The first extra one is '$(impact_display "${IMPACT_ARGS[$2]}")'."
    fi
}

# =============================================================================
# Small text helpers
# =============================================================================

# impact_trim TEXT
#   Prints TEXT without spaces, tabs and line-end characters at both ends.
impact_trim() {
    local text="$1"
    # Remove the longest run of blanks at the start, then at the end.
    text="${text#"${text%%[![:space:]]*}"}"
    text="${text%"${text##*[![:space:]]}"}"
    printf '%s' "$text"
}

# impact_lower TEXT
#   Prints TEXT in lower-case letters. "${text,,}" is bash's own conversion.
impact_lower() {
    printf '%s' "${1,,}"
}

# impact_split_list TEXT ARRAY_NAME
#   Splits a comma-separated TEXT into the array ARRAY_NAME. An empty TEXT
#   gives an empty array. Empty entries are kept, so a validator can find
#   them.
#   Example: impact_split_list "${IMPACT_CONF[SHARED_ROOTS]}" roots
impact_split_list() {
    local -n impact__split_target="$2"
    impact__split_target=()
    local rest="$1"
    if [[ -z "$rest" ]]; then
        return 0
    fi
    # Cut at each comma. "${rest%%,*}" is the part before the first comma.
    while [[ "$rest" == *,* ]]; do
        impact__split_target+=("${rest%%,*}")
        rest="${rest#*,}"
    done
    impact__split_target+=("$rest")
}

# impact_in_list NEEDLE ITEM...
#   Result: success when NEEDLE equals one of the items.
#   Example: if impact_in_list "$root" "${roots[@]}"; then ...
impact_in_list() {
    local needle="$1" item
    shift
    for item in "$@"; do
        if [[ "$item" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

# impact_now_utc
#   Prints the current time in UTC, for example 2026-01-31T14:05:09Z.
impact_now_utc() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# impact_own_version
#   Prints the version of the installed commands (the content of the file
#   VERSION), or "unknown".
impact_own_version() {
    local version='unknown'
    if [[ -r "$IMPACT_BASE_DIR/VERSION" ]]; then
        IFS= read -r version <"$IMPACT_BASE_DIR/VERSION" || true
    fi
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        version='unknown'
    fi
    printf '%s\n' "$version"
}

# =============================================================================
# Version numbers
# =============================================================================

# impact__version_numbers TEXT ARRAY_NAME
#   Internal: extracts the leading number part of a version text into an
#   array. Accepted forms: "28.3.3", "v29.1", "5:29.1.0-1~ubuntu" (a package
#   version with an "epoch" before the colon), "28.3.3-rc1".
#   Result: failure when TEXT has no leading number.
impact__version_numbers() {
    local text="$1"
    local -n impact__version_target="$2"
    impact__version_target=()
    text="${text#v}"
    if [[ "$text" =~ ^[0-9]+:(.*)$ ]]; then
        # BASH_REMATCH[1] is the text that matched the first "( )" group.
        text="${BASH_REMATCH[1]}"
    fi
    if ! [[ "$text" =~ ^([0-9]+(\.[0-9]+)*) ]]; then
        return 1
    fi
    text="${BASH_REMATCH[1]}"
    # Split at the dots: IFS is changed for this one "read" only.
    IFS='.' read -r -a impact__version_target <<<"$text"
}

# impact_version_compare A B
#   Compares two version texts number by number.
#   Result: prints "lt" (A is older), "eq" or "gt" (A is newer). Failure
#   (exit status 2) when one of them is no version.
#   Example: impact_version_compare 28.3.3 29.1.0   prints lt
impact_version_compare() {
    local -a first second
    impact__version_numbers "$1" first || return 2
    impact__version_numbers "$2" second || return 2
    local index count="${#first[@]}" x y
    if ((${#second[@]} > count)); then
        count="${#second[@]}"
    fi
    for ((index = 0; index < count; index++)); do
        # A missing part counts as 0. "10#" forces decimal reading, so "08"
        # is eight and no invalid octal number.
        x=$((10#${first[index]:-0}))
        y=$((10#${second[index]:-0}))
        if ((x < y)); then
            printf 'lt\n'
            return 0
        fi
        if ((x > y)); then
            printf 'gt\n'
            return 0
        fi
    done
    printf 'eq\n'
}

# impact_version_ge A B
#   Result: success when version A is the same as B or newer. Failure when it
#   is older or when one of the texts is no version.
#   Example: if impact_version_ge "$docker_version" 28.3.3; then ...
impact_version_ge() {
    local result
    result="$(impact_version_compare "$1" "$2")" || return 1
    [[ "$result" == 'eq' || "$result" == 'gt' ]]
}

# =============================================================================
# Tools
# =============================================================================

# impact_package_for_tool TOOL
#   Prints the name of the Ubuntu package that contains TOOL, or nothing when
#   the tool has no simple package (Docker).
impact_package_for_tool() {
    case "$1" in
        sshd) printf 'openssh-server' ;;
        ssh | ssh-keygen | ssh-keyscan | scp | sftp) printf 'openssh-client' ;;
        getfacl | setfacl) printf 'acl' ;;
        git) printf 'git' ;;
        curl) printf 'curl' ;;
        runuser | findmnt | flock | setsid | mountpoint | namei | lsblk | lslogins | nsenter | unshare) printf 'util-linux' ;;
        script | logger | renice) printf 'bsdutils' ;;
        column) printf 'bsdextrautils' ;;
        getent | iconv | locale) printf 'libc-bin' ;;
        useradd | usermod | userdel | groupadd | groupdel | groupmod | gpasswd | chage | passwd | chpasswd) printf 'passwd' ;;
        lastlog | faillog | newgrp | login) printf 'login' ;;
        realpath | stat | install | mktemp | sha256sum | timeout | readlink | date | id | chown | chmod | chgrp | du | df | \
            sort | tr | cut | head | tail | wc | mv | cp | rm | mkdir | rmdir | ln | cat | tee | touch | nohup | numfmt | nproc | \
            basename | dirname | comm | uniq | seq | env | tac | paste | join | split | truncate | sync | who | logname | ls | uname)
            printf 'coreutils'
            ;;
        tar) printf 'tar' ;;
        gzip | gunzip | zcat) printf 'gzip' ;;
        ps | pkill | pgrep | free | uptime) printf 'procps' ;;
        ss | ip) printf 'iproute2' ;;
        systemctl | loginctl | journalctl | timedatectl | hostnamectl | systemd-detect-virt) printf 'systemd' ;;
        awk) printf 'mawk' ;;
        sed) printf 'sed' ;;
        grep) printf 'grep' ;;
        diff | cmp) printf 'diffutils' ;;
        find | xargs) printf 'findutils' ;;
        hostname) printf 'hostname' ;;
        dpkg-query | dpkg) printf 'dpkg' ;;
        apt-get | apt-cache) printf 'apt' ;;
        rsync) printf 'rsync' ;;
        sudo) printf 'sudo' ;;
        file) printf 'file' ;;
        less) printf 'less' ;;
        openssl) printf 'openssl' ;;
        ufw) printf 'ufw' ;;
        lsb_release) printf 'lsb-release' ;;
        *) ;;
    esac
}

# impact_have_tool TOOL
#   Result: success when the program TOOL is found in the fixed PATH.
impact_have_tool() {
    # "command -v" prints where a program is; here only the status matters.
    command -v -- "$1" >/dev/null 2>&1
}

# impact_missing_tools TOOL...
#   Prints the tools of the list that are missing, one per line.
#   Result: success when none is missing.
impact_missing_tools() {
    local tool missing=0
    for tool in "$@"; do
        if ! impact_have_tool "$tool"; then
            printf '%s\n' "$tool"
            missing=1
        fi
    done
    ((missing == 0))
}

# impact_install_hint TOOL...
#   Prints the exact "apt-get install" line for the given missing tools, and
#   a pointer to Docker's own instructions when docker is among them. Nothing
#   is installed.
impact_install_hint() {
    local tool package
    local -a packages=()
    local need_docker=0
    for tool in "$@"; do
        if [[ "$tool" == 'docker' || "$tool" == 'dockerd' ]]; then
            need_docker=1
            continue
        fi
        package="$(impact_package_for_tool "$tool")"
        if [[ -n "$package" ]] && ! impact_in_list "$package" "${packages[@]}"; then
            packages+=("$package")
        fi
    done
    if ((${#packages[@]} > 0)); then
        # "${packages[*]}" joins the entries with spaces.
        impact_say "    Install the missing tools with:  sudo apt-get install ${packages[*]}"
    fi
    if ((need_docker == 1)); then
        impact_say "    Docker Engine is missing. Install the package docker-ce from Docker's own apt source:"
        impact_say "    https://docs.docker.com/engine/install/ubuntu/"
    fi
}

# impact_require_tools TOOL...
#   Stops the command (exit code 1) when one of the tools is missing, after
#   printing which ones and the apt-get line that installs them.
#   Example: impact_require_tools getent runuser ssh-keygen
impact_require_tools() {
    local -a missing=()
    mapfile -t missing < <(impact_missing_tools "$@" || true)
    if ((${#missing[@]} == 0)); then
        return 0
    fi
    impact_error "These tools are missing on this machine: ${missing[*]}"
    impact_install_hint "${missing[@]}"
    impact_die "$IMPACT_EXIT_FAILED" "$IMPACT_CMD cannot work without these tools." \
        "Install them, then run the command again."
}

# =============================================================================
# Temporary files
# =============================================================================

# impact_mktemp_file
#   Creates an empty temporary file in /tmp that only the current account can
#   read, and sets IMPACT_TMP to its path. The file is removed when the
#   command ends.
#   Result: IMPACT_TMP. Failure when the file cannot be created.
#   The path is returned in a variable because a call inside "$( ... )" would
#   run in a copy of the script, and the clean-up list would not learn about
#   the file.
#   Example: impact_mktemp_file; list_file="$IMPACT_TMP"
impact_mktemp_file() {
    impact_mktemp_file_in /tmp
}

# impact_mktemp_file_in FOLDER
#   As impact_mktemp_file, with the temporary file created in FOLDER. Use it
#   when the file is later renamed to a place in the same folder.
#   Result: IMPACT_TMP.
impact_mktemp_file_in() {
    # mktemp replaces the X characters by random letters and creates the
    # file in one step, so no other account can guess or take the name.
    IMPACT_TMP="$(mktemp -- "$1/.impact-tmp.XXXXXXXXXX")" || return 1
    IMPACT_TMP_ITEMS+=("$IMPACT_TMP")
}

# impact_mktemp_dir
#   Creates a temporary folder in /tmp (mode 700) and sets IMPACT_TMP to its
#   path. The folder and everything in it are removed when the command ends.
#   Result: IMPACT_TMP.
#   Example: impact_mktemp_dir; work_dir="$IMPACT_TMP"
impact_mktemp_dir() {
    impact_mktemp_dir_in /tmp
}

# impact_mktemp_dir_in FOLDER
#   As impact_mktemp_dir, with the temporary folder created in FOLDER.
#   Result: IMPACT_TMP.
impact_mktemp_dir_in() {
    IMPACT_TMP="$(mktemp -d -- "$1/.impact-tmp.XXXXXXXXXX")" || return 1
    IMPACT_TMP_ITEMS+=("$IMPACT_TMP")
}

# =============================================================================
# Files and folders owned by root
# =============================================================================

# impact_dir_is PATH MODE OWNER GROUP
#   Result: success when PATH is a real folder (no symbolic link) with exactly
#   this mode, owner and group. A symbolic link is a pointer to another path.
#   Example: if ! impact_dir_is /etc/impact 755 root root; then ...
impact_dir_is() {
    local path="$1" facts
    [[ -d "$path" && ! -L "$path" ]] || return 1
    # stat prints facts about a file: %a mode, %U owner, %G group.
    facts="$(stat -c '%a %U %G' -- "$path" 2>/dev/null)" || return 1
    [[ "$facts" == "$2 $3 $4" ]]
}

# impact_make_dir PATH MODE OWNER GROUP
#   Creates the folder PATH, or corrects mode, owner and group of an existing
#   one. Missing parent folders are created with mode 755 for root. A symbolic
#   link or a plain file at PATH is refused.
#   Result: failure with an error line when PATH cannot be used.
#   Example: impact_do "Create the folder /etc/impact" impact_make_dir /etc/impact 755 root root
impact_make_dir() {
    local path="$1" mode="$2" owner="$3" group="$4"
    if [[ -L "$path" ]]; then
        impact_error "$path is a symbolic link. A real folder is expected here."
        return 1
    fi
    if [[ -e "$path" && ! -d "$path" ]]; then
        impact_error "$path exists and is no folder."
        return 1
    fi
    if [[ ! -d "$path" ]]; then
        mkdir -p -- "$(dirname -- "$path")" || return 1
        mkdir -- "$path" || return 1
    fi
    # Owner first: changing the owner can clear special mode bits.
    chown -- "$owner:$group" "$path" || return 1
    chmod -- "$mode" "$path" || return 1
}

# impact_file_is PATH MODE OWNER GROUP
#   Result: success when PATH is a plain file (no symbolic link) with exactly
#   this mode, owner and group.
impact_file_is() {
    local path="$1" facts
    [[ -f "$path" && ! -L "$path" ]] || return 1
    facts="$(stat -c '%a %U %G' -- "$path" 2>/dev/null)" || return 1
    [[ "$facts" == "$2 $3 $4" ]]
}

# impact_file_has_content PATH OTHER_FILE
#   Result: success when PATH is a plain file with the same content as
#   OTHER_FILE.
impact_file_has_content() {
    [[ -f "$1" && ! -L "$1" ]] || return 1
    cmp -s -- "$1" "$2"
}

# impact_write_file_atomic TARGET MODE [OWNER GROUP]
#   Writes standard input to the file TARGET in one step: the content goes to
#   a temporary file in the same folder, which is then renamed to TARGET. A
#   reader therefore sees the old file or the new file, never half of one,
#   and a failure leaves the old file untouched. The temporary name starts
#   with a dot and ends in random letters, so a service that reads "*.conf"
#   in that folder ignores it.
#   Parameters: the target path, the file mode (for example 644), and
#   optionally owner and group (default: unchanged, the current account).
#   Result: failure with an error line when TARGET is a symbolic link or a
#   folder, or when the folder of TARGET does not exist.
#   Example: impact_write_file_atomic /etc/impact/impact.conf 644 root root <"$new_file"
impact_write_file_atomic() {
    local target="$1" mode="$2" owner="${3:-}" group="${4:-}"
    local folder temporary
    folder="$(dirname -- "$target")"
    if [[ ! -d "$folder" ]]; then
        impact_error "The folder $folder does not exist, so $target cannot be written."
        return 1
    fi
    if [[ -L "$target" ]]; then
        impact_error "$target is a symbolic link. The command does not write through links. Replace the link by a plain file first."
        return 1
    fi
    if [[ -d "$target" ]]; then
        impact_error "$target is a folder; a file is expected here."
        return 1
    fi
    temporary="$(mktemp -- "$folder/.impact-tmp.XXXXXXXXXX")" || return 1
    IMPACT_TMP_ITEMS+=("$temporary")
    # "cat" copies standard input into the temporary file. Each further step
    # runs only when the one before it worked ("&&").
    if ! { cat >"$temporary" && chmod -- "$mode" "$temporary"; }; then
        rm -f -- "$temporary"
        return 1
    fi
    if [[ -n "$owner" ]]; then
        if ! chown -- "$owner:$group" "$temporary"; then
            rm -f -- "$temporary"
            return 1
        fi
    fi
    # "mv -T" treats the target as a file name in every case. The rename
    # happens inside one folder, which the system does as a single step.
    if ! mv -f -T -- "$temporary" "$target"; then
        rm -f -- "$temporary"
        return 1
    fi
}

# =============================================================================
# The administrator log
# =============================================================================

# impact_log_enable ARGUMENTS...
#   Switches on the log for this run. Every changing command calls it once,
#   after its options were read, with its own arguments ("$@"). When the
#   command ends, one block is added to /opt/impact/admin/log/impact-admin.log
#   with: the time in UTC, the account that ran sudo, the command with its
#   arguments, the result, and the steps that changed something.
#   No block is written in a dry run, and none for a run that failed before
#   it changed anything.
#   Never put a private key or a password into an argument or a step text.
#   A public key appears in the log as its fingerprint only.
impact_log_enable() {
    IMPACT_LOG_ENABLED=1
    IMPACT_LOG_ARGS=("$@")
}

# impact_log_note TEXT
#   Adds one line to the log block of this run, for a fact that is no step,
#   for example the fingerprint of an installed key.
impact_log_note() {
    IMPACT_LOG_NOTES+=("$(impact_display "$1")")
}

# impact__log_word TEXT
#   Internal: prints one command-line word for the log. A word with spaces or
#   special characters is shown in quotes so the line can be read back
#   exactly ("%q" is bash's own quoting).
impact__log_word() {
    local word
    word="$(impact_display "$1")"
    if [[ "$word" =~ ^[A-Za-z0-9_@%+=:,./-]+$ ]]; then
        printf '%s' "$word"
    else
        printf '%q' "$word"
    fi
}

# impact__write_log EXIT_CODE
#   Internal: appends the log block. Called once from the EXIT handler.
impact__write_log() {
    local code="$1"
    ((IMPACT_LOG_ENABLED == 1)) || return 0
    ((IMPACT_DRY_RUN == 0)) || return 0
    ((EUID == 0)) || return 0
    if ((code != 0 && ${#IMPACT_CHANGES[@]} == 0)); then
        return 0
    fi

    # The log folder is readable by root only (mode 700).
    if [[ -L "$IMPACT_ADMIN_DIR" || -L "$IMPACT_LOG_DIR" || -L "$IMPACT_LOG_FILE" ]]; then
        impact_error "The log was not written: $IMPACT_LOG_FILE or one of its folders is a symbolic link."
        return 1
    fi
    if [[ ! -d "$IMPACT_LOG_DIR" ]]; then
        install -d -m 700 -o root -g root -- "$IMPACT_ADMIN_DIR" "$IMPACT_LOG_DIR" || {
            impact_error "The log folder $IMPACT_LOG_DIR could not be created."
            return 1
        }
    fi

    local result invoker command_line word
    if ((code == 0)); then
        if ((${#IMPACT_CHANGES[@]} > 0)); then
            result='ok'
        else
            result='ok, nothing had to be changed'
        fi
    else
        result="FAILED with exit code $code; the steps listed below ran before it stopped"
    fi
    invoker="$(impact_invoking_account 2>/dev/null)" || invoker='unknown'
    command_line="$IMPACT_CMD"
    for word in "${IMPACT_LOG_ARGS[@]}"; do
        command_line+=" $(impact__log_word "$word")"
    done

    # "{ ...; } >>file" sends the output of all lines in the braces to the
    # end of the file (">>" appends). The whole block is written in one go.
    {
        printf '==== %s ====\n' "$(impact_now_utc)"
        printf 'account: %s\n' "$invoker"
        printf 'command: %s\n' "$command_line"
        printf 'result:  %s\n' "$result"
        if ((${#IMPACT_CHANGES[@]} > 0)); then
            printf 'changes:\n'
            # The step texts are the command's own words: they may be
            # longer than a value from input (up to 2000 characters).
            for word in "${IMPACT_CHANGES[@]}"; do
                printf '  + %s\n' "$(impact_display "$word" 2000)"
            done
        fi
        if ((${#IMPACT_LOG_NOTES[@]} > 0)); then
            printf 'notes:\n'
            for word in "${IMPACT_LOG_NOTES[@]}"; do
                printf '  %s\n' "$word"
            done
        fi
        printf '\n'
    } >>"$IMPACT_LOG_FILE" || {
        impact_error "The log block could not be written to $IMPACT_LOG_FILE."
        return 1
    }
    chmod 600 -- "$IMPACT_LOG_FILE"
}

# =============================================================================
# Confirmation
# =============================================================================

# impact_confirm QUESTION [EXPECTED_ANSWER]
#   Asks the administrator to confirm before a step that is hard to undo.
#   The answer is read from the terminal itself (/dev/tty), so the question
#   also works when standard input carries data, for example a key.
#   Parameters: the question, and the exact word to type (default "yes").
#   Result: success when the answer matches, when --yes was given, or in a
#   dry run (which changes nothing and therefore asks nothing). Failure for
#   any other answer and when no terminal is available.
#   Example: impact_confirm "Remove the account alice?" || impact_die 1 "Stopped: no confirmation." ""
impact_confirm() {
    local question="$1" expected="${2:-yes}" answer=''
    if ((IMPACT_DRY_RUN == 1)); then
        impact_info "[dry run] A real run asks here: $question"
        return 0
    fi
    if ((IMPACT_ASSUME_YES == 1)); then
        impact_info "$question"
        impact_info "Answered by the option --yes."
        return 0
    fi
    # Try to open the terminal inside "( ... )", a copy of the script, so a
    # failure cannot end the command itself.
    if ! (: </dev/tty) 2>/dev/null; then
        impact_error "This step needs a confirmation and no terminal is available to ask on."
        impact_error "Run the command in a terminal, or add the option --yes after checking the request."
        return 1
    fi
    printf '\n%s\nType %s and press Enter to continue. Anything else stops here: ' "$question" "$expected" >/dev/tty
    IFS= read -r answer </dev/tty || answer=''
    [[ "$answer" == "$expected" ]]
}

# =============================================================================
# Downloads
# =============================================================================

# impact_https_get URL OUTPUT_FILE
#   Downloads a small public text over HTTPS into OUTPUT_FILE, for example
#   the public keys of a GitHub account (https://github.com/<name>.keys).
#   Safety limits: only "https://" addresses made of letters, digits and
#   . _ ~ / - (no "?" and no blanks); redirects only to HTTPS; at most 30
#   seconds; at most 1 MB.
#   Result: 0 when the text was downloaded; 5 when the server answered that
#   the address does not exist or is closed (status 4xx); 6 for a network
#   problem or any other answer; 2 for an address that is not accepted.
#   IMPACT_HTTP_STATUS holds the status code of the server, or 000.
#   Example: impact_https_get "https://github.com/alice-example.keys" "$IMPACT_TMP" || status=$?
impact_https_get() {
    local url="$1" output="$2" status=0
    IMPACT_HTTP_STATUS='000'
    if ! [[ "$url" =~ ^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(/[A-Za-z0-9._~/-]*)?$ ]]; then
        impact_error "The address '$(impact_display "$url")' is not accepted for a download (only plain https:// addresses)."
        return 2
    fi
    # curl options: --proto and --proto-redir allow HTTPS only, also after a
    # redirect; --fail turns an error answer of the server into a failure;
    # --write-out prints the status code after the transfer.
    IMPACT_HTTP_STATUS="$(curl --proto '=https' --proto-redir '=https' --location --max-redirs 3 \
        --silent --fail --max-time 30 --max-filesize 1048576 \
        --output "$output" --write-out '%{http_code}' -- "$url" 2>/dev/null)" || status=$?
    if ! [[ "$IMPACT_HTTP_STATUS" =~ ^[0-9]{3}$ ]]; then
        IMPACT_HTTP_STATUS='000'
    fi
    if ((status == 0)) && [[ "$IMPACT_HTTP_STATUS" == 2* ]]; then
        return 0
    fi
    if [[ "$IMPACT_HTTP_STATUS" == 4* ]]; then
        return "$IMPACT_EXIT_NO_ACCESS"
    fi
    return "$IMPACT_EXIT_NETWORK"
}

# =============================================================================
# Masking addresses and host names in output
# =============================================================================

# impact__sed_escape TEXT
#   Internal: prints TEXT with every character that has a special meaning in
#   a sed pattern protected by a backslash.
impact__sed_escape() {
    printf '%s' "$1" | sed -e 's/[][\\.*^$+?(){}|/]/\\&/g'
}

# impact_own_host_names
#   Prints the names of this machine (short and full form), one per line,
#   longest first. Names shorter than two characters and "localhost" are left
#   out.
impact_own_host_names() {
    local name
    {
        hostname 2>/dev/null || true
        hostname -s 2>/dev/null || true
        hostname -f 2>/dev/null || true
        if [[ -r /etc/hostname ]]; then
            cat /etc/hostname
        fi
    } | while IFS= read -r name; do
        name="${name//[[:space:]]/}"
        if [[ "${#name}" -ge 2 && "$name" != 'localhost' && "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
            # Print the length first so that "sort" can order by it.
            printf '%d %s\n' "${#name}" "$name"
        fi
    done | sort -u -k1,1nr -k2,2 | cut -d' ' -f2-
}

# impact_mask_text
#   A filter: reads text on standard input and prints it with network
#   addresses and host names replaced, so the output can be shared.
#     IPv4 and IPv6 addresses  become  <address>
#     hardware (MAC) addresses become  <hardware address>
#     this machine's names, and every further name that the command put into
#     the list IMPACT_MASK_NAMES,  become  <host>
#   Kept as they are, because they name no particular machine and carry the
#   meaning of many lines: 127.x.x.x and ::1 (this computer itself), 0.0.0.0
#   and :: (all addresses).
#   A text of four numbers with dots is treated as an address even where it
#   is a version number: hiding too much is the safe direction.
#   Example: docker ps | impact_mask_text
#   Example: IMPACT_MASK_NAMES+=("fileserver.example.org")
#   To mask everything a command prints from a certain point on, use
#   impact_mask_output_start (it also waits for the last lines at the end).
impact_mask_text() {
    local -a program=()
    local name escaped
    local -a names=()
    mapfile -t names < <(impact_own_host_names)
    for name in "${IMPACT_MASK_NAMES[@]}"; do
        if [[ "${#name}" -ge 2 && "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
            names+=("$name")
        fi
    done

    # The sed program works in three phases. Phase 1 protects the addresses
    # that stay: their dots become the invisible character \x02 and "::1"
    # becomes \x03, so the patterns of phase 2 cannot match them. Phase 2
    # replaces addresses and names. Phase 3 turns the protected texts back.
    # Each replacement sits in a small loop (":label ... t label") that
    # repeats it until nothing matches any more; a single pass would miss the
    # second of two addresses that share the character between them.
    program+=(-e ':a' -e 's/(^|[^0-9.])127\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(\.?[^0-9.]|\.?$)/\1127\x02\2\x02\3\x02\4\5/' -e 'ta')
    program+=(-e ':b' -e 's/(^|[^0-9.])0\.0\.0\.0(\.?[^0-9.]|\.?$)/\10\x020\x020\x020\2/' -e 'tb')
    program+=(-e ':c' -e 's/(^|[^0-9A-Za-z:.])::1([^0-9A-Za-z:]|$)/\1\x03\2/' -e 'tc')
    # IPv4: four numbers of one to three digits with dots between them.
    program+=(-e ':d' -e 's/(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}(\.?[^0-9.]|\.?$)/\1<address>\3/' -e 'td')
    # Hardware address: six pairs of hexadecimal digits with colons.
    program+=(-e ':e' -e 's/(^|[^0-9A-Fa-f:])([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}([^0-9A-Fa-f:]|$)/\1<hardware address>\3/' -e 'te')
    # IPv6: groups of hexadecimal digits with colons. Four shapes: groups on
    # both sides of "::", groups before "::", groups after "::", and the full
    # form with eight groups.
    program+=(-e ':f' -e 's/(^|[^0-9A-Za-z:.])(([0-9A-Fa-f]{1,4}:){1,7}(:[0-9A-Fa-f]{1,4}){1,7}|([0-9A-Fa-f]{1,4}:){1,7}:|:(:[0-9A-Fa-f]{1,4}){1,7}|([0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4})([^0-9A-Za-z:]|$)/\1<address>\8/' -e 'tf')
    local label_number=0
    for name in "${names[@]}"; do
        escaped="$(impact__sed_escape "$name")"
        label_number=$((label_number + 1))
        # "I" at the end makes the comparison ignore upper and lower case.
        program+=(-e ":h$label_number" -e "s/(^|[^A-Za-z0-9_.-])${escaped}([^A-Za-z0-9_-]|\$)/\\1<host>\\2/I" -e "th$label_number")
    done
    program+=(-e 's/\x02/./g' -e 's/\x03/::1/g')
    sed -E "${program[@]}"
}

# impact_mask_output_start
#   From now on, everything the command prints (normal output and error
#   messages) passes through impact_mask_text. Set IMPACT_MASK_NAMES before
#   the call. At the end of the command the library gives the original
#   channels back and waits until the filter has printed its last line, so
#   no line is lost or comes after the command has ended.
#   Result: none. Call it once, from the main flow of the command.
#   Example: impact_mask_output_start
impact_mask_output_start() {
    if [[ -n "$IMPACT__MASK_PID" ]]; then
        return 0
    fi
    # Keep the original channels as the handles 3 (output) and 4 (errors).
    exec 3>&1 4>&2
    # "> >(command)" is process substitution: the output goes into a
    # command that runs next to the script. "$!" is the process number of
    # that command.
    exec > >(impact_mask_text) 2>&1
    IMPACT__MASK_PID=$!
}

# impact__mask_output_end
#   Internal: the end of impact_mask_output_start. Closes the way into the
#   filter (so it sees the end of its input), gives the original channels
#   back and waits for the filter. Called from the end-of-command handler.
impact__mask_output_end() {
    if [[ -z "$IMPACT__MASK_PID" ]]; then
        return 0
    fi
    exec 1>&3 2>&4 3>&- 4>&-
    wait "$IMPACT__MASK_PID" 2>/dev/null || true
    IMPACT__MASK_PID=''
}

# =============================================================================
# Contact text
# =============================================================================

# impact_contact_text
#   Prints who to contact, for messages to a colleague: the ADMIN_CONTACT of
#   the settings file and, when set, the DEPUTY_CONTACT. Before the settings
#   file was read it prints "the administrator".
#   Example: impact_die 5 "GitHub refused the key." "Contact $(impact_contact_text)."
impact_contact_text() {
    local admin='' deputy=''
    if [[ -v IMPACT_CONF[ADMIN_CONTACT] ]]; then
        admin="${IMPACT_CONF[ADMIN_CONTACT]}"
        deputy="${IMPACT_CONF[DEPUTY_CONTACT]:-}"
    fi
    if [[ -z "$admin" ]]; then
        printf 'the administrator'
    elif [[ -n "$deputy" ]]; then
        printf '%s (or %s)' "$admin" "$deputy"
    else
        printf '%s' "$admin"
    fi
}

# =============================================================================
# The topic files
# =============================================================================
# "source" reads another file into the running script. The comment lines that
# start with "shellcheck source=" tell the checking tool where the file is
# (relative to the folder of this file).

# First make sure that all of them are there: a half-copied installation
# must end with a clear message.
for impact__topic in settings accounts storage ssh docker; do
    if [[ ! -r "$IMPACT_LIB_DIR/impact-$impact__topic.sh" ]]; then
        printf 'ERROR: The file %s/impact-%s.sh is missing, so the IMPACT commands are incomplete.\n' "$IMPACT_LIB_DIR" "$impact__topic" >&2
        printf 'What to do: unpack the complete archive again and run install.sh.\n' >&2
        exit 1
    fi
done
unset -v impact__topic

# shellcheck source=impact-settings.sh
source "$IMPACT_LIB_DIR/impact-settings.sh"
# shellcheck source=impact-accounts.sh
source "$IMPACT_LIB_DIR/impact-accounts.sh"
# shellcheck source=impact-storage.sh
source "$IMPACT_LIB_DIR/impact-storage.sh"
# shellcheck source=impact-ssh.sh
source "$IMPACT_LIB_DIR/impact-ssh.sh"
# shellcheck source=impact-docker.sh
source "$IMPACT_LIB_DIR/impact-docker.sh"
