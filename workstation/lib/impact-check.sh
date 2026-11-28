#!/bin/bash
# =============================================================================
# impact-check.sh: the blocks of the health check impact-check
#
# Purpose
#   impact-check prints the state of the whole IMPACT setup of the
#   workstation in numbered blocks. This file holds the code of those blocks
#   and the small helpers they share: the bookkeeping of the result of each
#   block (OK, WARN or FAIL, with the lines "What to do"), the reading of
#   tool output (disk space, network listeners, Docker containers, git
#   status), and the rules that decide what is in order.
#   Every function here only reads. Nothing in this file changes the system.
#
# Who runs it
#   Nobody directly. The command impact-check loads it directly after
#   impact-common.sh. The unit tests load it to test the pure functions.
#
# Usage (inside impact-check, after loading impact-common.sh)
#   source "$IMPACT_LIB_DIR/impact-check.sh"
#   impact_check_load_settings || true
#   impact_check_run_block 'System' impact_check_block_system
#   impact_check_print_summary
#   exit "$IMPACT_CHECK_EXIT"
#
# What it changes on the system
#   Nothing. The blocks read files, ask tools (sshd -T, docker, git, ss, df,
#   du, getfacl) and print what they find. Commands inside a person's home
#   folder run with the rights of that person (impact_run_as). The only file
#   that is written is a private temporary file in /tmp for one question to
#   sshd (block "SSH rules"); the command removes it at its end.
#
# How to undo
#   Nothing to undo.
#
# Rules for a block
#   A block function prints lines with impact_check_info, impact_check_ok,
#   impact_check_warn and impact_check_fail. impact_check_warn and
#   impact_check_fail take a second text: what to do. The block runner
#   (impact_check_run_block) runs each block function in a copy of the
#   command (a "subshell"), so a block that stops unexpectedly cannot end
#   the whole check. At the end of the block it prints the collected lines
#   "What to do" and exactly one result line:
#       Result of block <n>: OK | WARN | FAIL
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
#   mapfile -t LIST <FILE     read the lines of FILE into the list LIST, one
#                        entry per line (-t drops the line ends)
#   < <(command)  <(command)   hand the output of a command to a loop, to
#                        mapfile or to another program as if it were a file
#                        ("process substitution")
#   <<<"$text"           hand a text to a command as its input ("here-string")
#   declare -A NAME  local -A NAME   a list whose entries are found by a name
#                        (an "associative array"): NAME[key]=value, "${NAME[key]}"
#   IFS=: read -r A B    split one line at the character after "IFS=" (here
#                        ":") into the variables A and B; with -a LIST into a list
#   while IFS= read -r line   read input line by line, exactly as written:
#                        "IFS=" keeps blanks at both ends, -r keeps backslashes
#   $'\t'  $'\r'  $'\n'   a text with a special character: tab, carriage return,
#                        new line (\xNN is the byte NN)
#   command || true      accept a failure of this command ("set -e" would
#                        otherwise stop the script there)
#   2>&1                 send the error channel to the same place as the output
#   "${NAME:+text}"      "text" when NAME has content, otherwise nothing
#   "${!LIST[@]}"        the positions (or the names) of the entries of a list
#   "${NAME:0:10}"       a part of the text: from position 0, 10 characters
#   "${NAME,,}"          the text in lower case
#   shopt -s nullglob    a file pattern (*.conf) without a match gives an empty
#                        list; "shopt -u" switches this off again
# Constructs beyond these are explained where they are first used.
# -----------------------------------------------------------------------------

# The two lines for the checking tool "shellcheck" stand before the first
# command of the file and therefore count for the whole file.
# shellcheck disable=SC2034
# Reason for SC2034 (variable appears unused): the command impact-check and
# the tests read the variables that this file sets; shellcheck checks one
# file at a time and cannot see those uses.

# Load this file once per script.
if [[ -n "${IMPACT_CHECK_LOADED:-}" ]]; then
    return 0
fi
IMPACT_CHECK_LOADED=1

# =============================================================================
# State
# =============================================================================

# State of the whole check, kept by the command itself.
IMPACT_CHECK_BLOCK_NO=0        # number of the block that runs now
IMPACT_CHECK_TITLES=()         # title of every block that ran
IMPACT_CHECK_RESULTS=()        # its result word: OK, WARN or FAIL
IMPACT_CHECK_EXIT=0            # exit code after impact_check_print_summary
IMPACT_CHECK_TMP_DIR=''        # private temporary folder (set by the command)
IMPACT_CHECK_EXTRA_ROOTS=()    # storage roots given with --shared-roots

# State of the settings file (impact_check_load_settings).
#   ok         the file was read and is valid
#   missing    there is no settings file
#   untrusted  the file can be changed by accounts other than root
#   invalid    the file breaks a rule of its format
IMPACT_CHECK_CONF_STATE='missing'
IMPACT_CHECK_CONF_ERRORS=()    # why the file could not be used
IMPACT_CHECK_CONF_NOTES=()     # warnings about unknown keys

# State of one block. Each block runs in its own copy of the command, so
# these variables start fresh for every block.
IMPACT_CHECK_STATE=0           # 0 OK, 1 WARN, 2 FAIL
IMPACT_CHECK_TODO=()           # the lines "What to do" of the block
IMPACT_CHECK_GUESS_NOTED=0     # 1 after the note about default values

# The tools that the IMPACT commands and this check use: the list
# IMPACT_NEEDED_TOOLS of the library, the same that install.sh checks.
# Block "System" names the missing ones with the line that installs them.
readonly -a IMPACT_CHECK_TOOLS=("${IMPACT_NEEDED_TOOLS[@]}")

# The subfolders of /opt/impact/admin that impact-workstation-setup creates.
readonly -a IMPACT_CHECK_ADMIN_SUBDIRS=(log keys accounts acl-backups state)

# How many entries the bounded samples look at. A sample never walks a
# whole folder tree: the shared storage holds terabytes.
readonly IMPACT_CHECK_SAMPLE_SIZE=50       # entries per storage folder
readonly IMPACT_CHECK_LIST_LIMIT=200       # entries of a folder listing
readonly IMPACT_CHECK_DU_SECONDS=60        # time limit for one home folder size

# =============================================================================
# Bookkeeping of a block
# =============================================================================

# impact_check__raise LEVEL
#   Internal: raises the state of the running block to LEVEL (1 WARN,
#   2 FAIL). The state never goes down again within a block.
impact_check__raise() {
    if (($1 > IMPACT_CHECK_STATE)); then
        IMPACT_CHECK_STATE="$1"
    fi
}

# impact_check__todo TEXT
#   Internal: adds TEXT to the lines "What to do" of the running block,
#   unless the same text is there already.
impact_check__todo() {
    local text="${1:-}" item
    if [[ -z "$text" ]]; then
        text='Read the line above and correct what it names.'
    fi
    for item in "${IMPACT_CHECK_TODO[@]}"; do
        if [[ "$item" == "$text" ]]; then
            return 0
        fi
    done
    IMPACT_CHECK_TODO+=("$text")
}

# impact_check_info TEXT
#   Prints a line with a fact. It does not change the result of the block.
impact_check_info() {
    impact_info "$1"
}

# impact_check_ok TEXT
#   Prints a line for something that is in order.
impact_check_ok() {
    impact_ok "$1"
}

# impact_check_warn TEXT WHAT_TO_DO
#   Prints a warning (the setup works, but something needs attention) and
#   raises the result of the block to at least WARN. WHAT_TO_DO is added to
#   the lines "What to do" at the end of the block.
#   Example: impact_check_warn "Docker starts at its first use only." "Let Docker start with the machine: sudo systemctl enable docker.service"
impact_check_warn() {
    impact_warn "$1"
    impact_check__raise 1
    impact_check__todo "${2:-}"
}

# impact_check_fail TEXT WHAT_TO_DO
#   Prints a failed check (something does not work, or a protection is
#   missing) and sets the result of the block to FAIL.
impact_check_fail() {
    impact_fail "$1"
    impact_check__raise 2
    impact_check__todo "${2:-}"
}

# impact_check_note_guess
#   For blocks that need the settings file: when it could not be used, the
#   block works with the default values of impact-workstation-setup. This
#   prints one warning about that per block, so no result looks better than
#   the facts allow.
impact_check_note_guess() {
    if [[ "$IMPACT_CHECK_CONF_STATE" == 'ok' ]] || ((IMPACT_CHECK_GUESS_NOTED == 1)); then
        return 0
    fi
    IMPACT_CHECK_GUESS_NOTED=1
    impact_check_warn "Without a usable settings file (block 4) this block works with default values (group ${IMPACT_CONF[SHARED_GROUP]}, ports ${IMPACT_CONF[PORT_MIN]} to ${IMPACT_CONF[PORT_MAX]})." \
        "Set the workstation up or correct the settings file (see block 4), then run sudo impact-check again."
}

# impact_check_result_word STATE
#   Prints the result word for a state number: 0 OK, 1 WARN, 2 FAIL.
impact_check_result_word() {
    case "$1" in
        0) printf 'OK' ;;
        1) printf 'WARN' ;;
        *) printf 'FAIL' ;;
    esac
}

# impact_check__block_end
#   Internal: the end of a block. Prints the lines "What to do" (for WARN
#   and FAIL) and the result line, then ends the copy of the command that
#   runs the block with the code 10 (OK), 11 (WARN) or 12 (FAIL). The runner
#   reads that code.
impact_check__block_end() {
    local item
    if ((IMPACT_CHECK_STATE > 0)); then
        printf '  What to do:\n'
        for item in "${IMPACT_CHECK_TODO[@]}"; do
            printf '    - %s\n' "$item"
        done
    fi
    printf '  Result of block %d: %s\n' "$IMPACT_CHECK_BLOCK_NO" "$(impact_check_result_word "$IMPACT_CHECK_STATE")"
    exit $((10 + IMPACT_CHECK_STATE))
}

# impact_check_run_block TITLE FUNCTION
#   Runs one block: prints its heading, runs FUNCTION in a copy of the
#   command, and records the result for the summary.
#   Why a copy ("( ... )", a subshell): a tool that fails in an unexpected
#   way ends only the copy. The check then reports this block as FAIL and
#   goes on with the next block, so the administrator always gets the whole
#   report.
#   Result: none; the result is in IMPACT_CHECK_RESULTS.
impact_check_run_block() {
    local title="$1" function="$2" status=0 word
    IMPACT_CHECK_BLOCK_NO=$((IMPACT_CHECK_BLOCK_NO + 1))
    printf '\nBlock %d: %s\n' "$IMPACT_CHECK_BLOCK_NO" "$title"
    # "set +e" lets the command continue when the copy ends with a code
    # other than 0, which is the normal way a block reports its result.
    # Inside the copy, "set -e" is switched on again, so an unexpected
    # failure ends the copy at once and is reported below.
    set +e
    (
        set -e
        IMPACT_CHECK_STATE=0
        IMPACT_CHECK_TODO=()
        IMPACT_CHECK_GUESS_NOTED=0
        "$function"
        impact_check__block_end
    )
    status=$?
    set -e
    case "$status" in
        10) word='OK' ;;
        11) word='WARN' ;;
        12) word='FAIL' ;;
        *)
            word='FAIL'
            impact_fail "This block stopped before it finished (exit code $status), so the lines above are incomplete."
            printf '  What to do:\n'
            printf '    - Run sudo impact-check again. If this block stops again, keep the whole output and report it.\n'
            printf '  Result of block %d: FAIL\n' "$IMPACT_CHECK_BLOCK_NO"
            ;;
    esac
    IMPACT_CHECK_TITLES+=("$title")
    IMPACT_CHECK_RESULTS+=("$word")
}

# impact_check_print_summary
#   Prints the table of all block results and sets IMPACT_CHECK_EXIT:
#   0 when every block is OK, 1 when at least one is WARN and none is FAIL,
#   2 when at least one block is FAIL.
impact_check_print_summary() {
    local index ok=0 warn=0 failed=0 word
    printf '\nSummary\n'
    for index in "${!IMPACT_CHECK_TITLES[@]}"; do
        # "${!list[@]}" gives the positions of the list: 0, 1, 2, ...
        word="${IMPACT_CHECK_RESULTS[index]}"
        # printf "%-44s" pads the title with blanks to 44 characters, so the
        # result words stand in one column.
        printf '  %2d  %-44s %s\n' $((index + 1)) "${IMPACT_CHECK_TITLES[index]}" "$word"
        case "$word" in
            OK) ok=$((ok + 1)) ;;
            WARN) warn=$((warn + 1)) ;;
            *) failed=$((failed + 1)) ;;
        esac
    done
    printf '  %d blocks: %d OK, %d WARN, %d FAIL.\n' "${#IMPACT_CHECK_TITLES[@]}" "$ok" "$warn" "$failed"
    if [[ ! -d "$IMPACT_INSTALL_DIR/bin" ]]; then
        # Before the installation (block 1 says so as well), the commands
        # that the lines "What to do" name (sudo impact-workstation-setup,
        # ...) do not exist yet.
        printf 'First step: the IMPACT commands are not installed yet (block 1). Install them from the unpacked folder: sudo ./install.sh\n'
        printf 'The lines "What to do" that name an IMPACT command (for example sudo impact-workstation-setup) work after the installation.\n'
    fi
    if ((failed > 0)); then
        IMPACT_CHECK_EXIT=2
        printf 'Overall result: FAIL (exit code 2). Work through the lines "What to do" of the blocks marked FAIL first, then of those marked WARN. Then run sudo %s again.\n' "$(impact_typed_name)"
    elif ((warn > 0)); then
        IMPACT_CHECK_EXIT=1
        printf 'Overall result: WARN (exit code 1). The setup works; read the lines "What to do" of the blocks marked WARN.\n'
    else
        IMPACT_CHECK_EXIT=0
        printf 'Overall result: OK (exit code 0). Every block is in order.\n'
    fi
}

# =============================================================================
# Small pure helpers (no system access; the unit tests cover them)
# =============================================================================

# impact_check_size_text BYTES
#   Prints a number of bytes in a short readable form: 512 bytes, 17 KB,
#   3.4 GB, 7.3 TB. One KB is 1024 bytes, one GB 1024 * 1024 * 1024 bytes,
#   the same units that the GUI on Windows uses.
#   Example: impact_check_size_text 1610612736   prints 1.5 GB
impact_check_size_text() {
    local bytes="$1" unit_index=0 scaled tenths
    local -a units=(bytes KB MB GB TB PB)
    if ! [[ "$bytes" =~ ^[0-9]{1,19}$ ]]; then
        printf 'unknown size'
        return 0
    fi
    # "10#" makes bash read the digits as a decimal number, also with a
    # leading zero (which bash would otherwise read as an octal number).
    bytes=$((10#$bytes))
    if ((bytes < 1024)); then
        printf '%d bytes' "$bytes"
        return 0
    fi
    # Count in tenths of the unit, so one decimal place can be shown with
    # whole-number arithmetic only.
    scaled=$((bytes * 10 / 1024))
    unit_index=1
    while ((scaled >= 10240 && unit_index < 5)); do
        scaled=$((scaled / 1024))
        unit_index=$((unit_index + 1))
    done
    tenths=$((scaled % 10))
    if ((scaled >= 1000 || tenths == 0)); then
        printf '%d %s' $((scaled / 10)) "${units[unit_index]}"
    else
        printf '%d.%d %s' $((scaled / 10)) "$tenths" "${units[unit_index]}"
    fi
}

# impact_check_gb_floor BYTES
#   Prints the number of whole GB (1024 * 1024 * 1024 bytes) in BYTES.
impact_check_gb_floor() {
    if [[ "$1" =~ ^[0-9]{1,19}$ ]]; then
        printf '%d' $((10#$1 / 1073741824))
    else
        printf '0'
    fi
}

# impact_check_address_kind ADDRESS
#   Says who can reach a listening address:
#     loopback   127.x.x.x or ::1: only programs on this machine
#     all        0.0.0.0, ::, * or empty: every network of the machine
#     network    any other address: the network that address belongs to
#   Example: impact_check_address_kind 127.0.0.1   prints loopback
impact_check_address_kind() {
    local address="$1"
    # Remove the brackets of an IPv6 address and a "%interface" suffix.
    address="${address#[}"
    address="${address%]}"
    address="${address%%%*}"
    case "$address" in
        127.* | ::1 | ::ffff:127.*) printf 'loopback' ;;
        '' | 0.0.0.0 | :: | '*' | ::ffff:0.0.0.0) printf 'all' ;;
        *) printf 'network' ;;
    esac
}

# impact_check_name_matches NAME PATTERNS
#   Result: success when NAME matches one of the comma-separated PATTERNS,
#   in which "*" stands for any text and "?" for any one character (the
#   form of KNOWN_DIRECT_CONTAINERS). Patterns with other special
#   characters are ignored, so a pattern can never do more than this.
#   Example: impact_check_name_matches data_preparation_1 'data_preparation_*'
impact_check_name_matches() {
    local name="$1" pattern
    local -a patterns=()
    impact_split_list "${2:-}" patterns
    for pattern in "${patterns[@]}"; do
        impact_valid_container_pattern "$pattern" || continue
        # An unquoted pattern on the right side of "==" inside [[ ]] is a
        # pattern with "*" and "?", which is the purpose here.
        # shellcheck disable=SC2053
        # Reason for SC2053: the pattern match is wanted.
        if [[ "$name" == $pattern ]]; then
            return 0
        fi
    done
    return 1
}

# impact_check_volume_like_impact NAME
#   Result: success when a Docker volume NAME looks like a volume of the
#   GUI's volume mode (the mode that keeps outputs in Docker volumes): the
#   GUI 2.0 names are
#   impactncd_output_<container> and impactncd_synthpop_<container>, older
#   versions used impactncd_<model>_output_<person> and
#   impactncd_<model>_synthpop_<person>. The rule: the name starts with
#   "impactncd_" or contains "_output_" or "_synthpop_", in any case. Such a
#   volume can hold the only copy of results.
#   Example: impact_check_volume_like_impact impactncd_output_Example_alice
impact_check_volume_like_impact() {
    # ",," turns the text into lower case.
    local name="${1,,}"
    [[ "$name" == impactncd_* || "$name" == *_output_* || "$name" == *_synthpop_* ]]
}

# impact_check_parse_listener LINE
#   Reads one line of "ss -H -l -t -n -p" (a listening TCP socket) and sets
#   IMPACT_CHECK_L_ADDRESS (without brackets and without %interface),
#   IMPACT_CHECK_L_PORT and IMPACT_CHECK_L_PROCESS (program name and process
#   number, for example "docker-proxy (process 1234)", or empty).
#   Result: failure for a line that has no address and port.
#   Example line: LISTEN 0 4096 127.0.0.1:8787 0.0.0.0:* users:(("docker-proxy",pid=1234,fd=4))
impact_check_parse_listener() {
    local line="$1" local_part process=''
    IMPACT_CHECK_L_ADDRESS=''
    IMPACT_CHECK_L_PORT=''
    IMPACT_CHECK_L_PROCESS=''
    # "read" splits the line at blanks; the last variable gets the rest.
    # "_" takes the columns that are not needed: state, the two queue
    # lengths, and the address of the other side. "<<<" hands a text to a
    # command as its input.
    read -r _ _ _ local_part _ process <<<"$line" || true
    # "${text##*:}" removes everything up to the last ":", which leaves the
    # port; "${text%:*}" keeps everything before the last ":".
    IMPACT_CHECK_L_PORT="${local_part##*:}"
    IMPACT_CHECK_L_ADDRESS="${local_part%:*}"
    [[ "$IMPACT_CHECK_L_PORT" =~ ^[0-9]{1,5}$ && "$local_part" == *:* ]] || return 1
    IMPACT_CHECK_L_ADDRESS="${IMPACT_CHECK_L_ADDRESS#[}"
    IMPACT_CHECK_L_ADDRESS="${IMPACT_CHECK_L_ADDRESS%]}"
    IMPACT_CHECK_L_ADDRESS="${IMPACT_CHECK_L_ADDRESS%%%*}"
    # BASH_REMATCH holds the parts of the text that the brackets ( ) of the
    # pattern matched.
    if [[ "$process" =~ \(\"([^\"]{1,64})\",pid=([0-9]+) ]]; then
        IMPACT_CHECK_L_PROCESS="$(impact_display "${BASH_REMATCH[1]}") (process ${BASH_REMATCH[2]})"
    fi
    return 0
}

# impact_check_unquote TEXT
#   Docker prints the free-text fields of this check in the quoted form of
#   its template language ("%q": "alice", with \" and \n for special
#   characters). This prints the text without the quotes. A label that a
#   container does not have comes out as %!q(<nil>) (Docker's way to say
#   "nothing there", seen with Docker 29); that counts as an empty text.
#   Result: failure when the text holds an escaped character (a backslash),
#   which no valid name contains; the caller then shows it as invalid.
#   Example: impact_check_unquote '"alice"'   prints alice
impact_check_unquote() {
    local text="$1"
    if [[ "$text" == '%!q(<nil>)' ]]; then
        return 0
    fi
    # "${#text}" is the length of the text; "${text:1:N}" is the part that
    # starts after the first character and is N characters long.
    [[ "$text" == \"*\" && ${#text} -ge 2 ]] || return 1
    text="${text:1:${#text}-2}"
    [[ "$text" != *\\* ]] || return 1
    printf '%s' "$text"
}

# impact_check_count_keys TEXT
#   Counts the lines of an authorized_keys file (the list of login keys of
#   an account) by kind and sets:
#     IMPACT_CHECK_KEYS_ED25519   plain ssh-ed25519 lines (the kind the IMPACT
#                                 commands write)
#     IMPACT_CHECK_KEYS_OTHER     lines with another key type or with options
#                                 in front of the key
#     IMPACT_CHECK_KEY_FPS        the fingerprints of the plain ed25519 keys
#                                 (when ssh-keygen is present)
#   Comments and empty lines do not count. No key text is printed.
impact_check_count_keys() {
    local line
    IMPACT_CHECK_KEYS_ED25519=0
    IMPACT_CHECK_KEYS_OTHER=0
    IMPACT_CHECK_KEY_FPS=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(impact_trim "$line")"
        if [[ -z "$line" || "$line" == '#'* ]]; then
            continue
        fi
        # The key parser of the library prints nothing; it fills
        # IMPACT_KEY_FINGERPRINT for a plain ed25519 line.
        if [[ "$line" == 'ssh-ed25519 '* ]] && impact_parse_ed25519_key "$line"; then
            IMPACT_CHECK_KEYS_ED25519=$((IMPACT_CHECK_KEYS_ED25519 + 1))
            IMPACT_CHECK_KEY_FPS+=("$IMPACT_KEY_FINGERPRINT")
        else
            IMPACT_CHECK_KEYS_OTHER=$((IMPACT_CHECK_KEYS_OTHER + 1))
        fi
    done <<<"$1"
}

# impact_check_porcelain_summary
#   Reads the output of "git status --porcelain=v1 -z" on standard input
#   and sets IMPACT_CHECK_UNTRACKED (number of files that git neither tracks
#   nor ignores), IMPACT_CHECK_UNTRACKED_NAMES (the first five of them) and
#   IMPACT_CHECK_CHANGED (number of tracked files with changes).
#   The format: one entry per file, "XY path", each entry ended by a zero
#   byte; "??" in XY means untracked. A renamed file is followed by one more
#   entry with its old name.
impact_check_porcelain_summary() {
    local entry skip_next=0
    IMPACT_CHECK_UNTRACKED=0
    IMPACT_CHECK_UNTRACKED_NAMES=()
    IMPACT_CHECK_CHANGED=0
    # "read -d ''" reads up to the next zero byte (git separates the names
    # with zero bytes), so file names with blanks or line breaks arrive whole.
    while IFS= read -r -d '' entry; do
        if ((skip_next == 1)); then
            skip_next=0
            continue
        fi
        case "$entry" in
            '?? '*)
                IMPACT_CHECK_UNTRACKED=$((IMPACT_CHECK_UNTRACKED + 1))
                if ((${#IMPACT_CHECK_UNTRACKED_NAMES[@]} < 5)); then
                    IMPACT_CHECK_UNTRACKED_NAMES+=("$(impact_display "${entry:3}")")
                fi
                ;;
            '!! '*) ;;
            R* | C* | ?R* | ?C*)
                IMPACT_CHECK_CHANGED=$((IMPACT_CHECK_CHANGED + 1))
                skip_next=1
                ;;
            *)
                IMPACT_CHECK_CHANGED=$((IMPACT_CHECK_CHANGED + 1))
                ;;
        esac
    done
}

# impact_check_config_without_rules MAIN_CONFIG RULES_FILE [BASE_FOLDER]
#   Prints a copy of the SSH server's main configuration file in which every
#   "Include" pattern that covers RULES_FILE is replaced by the list of the
#   other files that the pattern matches. sshd reads that copy exactly like
#   the real configuration, only without the IMPACT rules. Comparing the
#   effective settings of the administrator with and without the rules
#   proves that the rules leave the administrator's login unchanged.
#   BASE_FOLDER is the folder for relative patterns (default /etc/ssh, as
#   for sshd). Includes inside included files stay as they are.
#   Example: impact_check_config_without_rules /etc/ssh/sshd_config /etc/ssh/sshd_config.d/60-impact.conf
impact_check_config_without_rules() {
    local config="$1" rules="$2" base="${3:-/etc/ssh}"
    local line trimmed keyword word absolute match
    local -a words=() kept=() matches=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        trimmed="$(impact_trim "$line")"
        words=()
        if [[ -n "$trimmed" && "$trimmed" != '#'* ]]; then
            # sshd accepts "Keyword value" and "Keyword=value".
            read -r -a words <<<"${trimmed/=/ }"
        fi
        keyword="${words[0]:-}"
        if [[ "${keyword,,}" != 'include' ]]; then
            printf '%s\n' "$line"
            continue
        fi
        kept=()
        for word in "${words[@]:1}"; do
            word="${word//\"/}"
            absolute="$word"
            if [[ "$absolute" != /* ]]; then
                absolute="$base/$absolute"
            fi
            # Does this pattern cover the rules file? (See the note on
            # SC2053 above: the pattern match is wanted.)
            # shellcheck disable=SC2053
            if [[ "$rules" == $absolute ]]; then
                # "nullglob": a pattern without any match expands to nothing.
                # The unquoted $absolute below is expanded by bash into the
                # list of matching files, as sshd would do.
                shopt -s nullglob
                # shellcheck disable=SC2206
                # Reason for SC2206 (unquoted expansion into an array): the
                # expansion of the pattern into file names is wanted.
                matches=($absolute)
                shopt -u nullglob
                for match in "${matches[@]}"; do
                    if [[ "$match" != "$rules" ]]; then
                        kept+=("$match")
                    fi
                done
            else
                kept+=("$word")
            fi
        done
        if ((${#kept[@]} > 0)); then
            printf 'Include %s\n' "${kept[*]}"
        else
            printf '# (impact-check: the rules file is left out here)\n'
        fi
    done <"$config"
}

# impact_check_disk_facts PATH
#   Asks "df" about the file system that holds PATH (or its closest existing
#   parent) and sets IMPACT_CHECK_DISK_SIZE and IMPACT_CHECK_DISK_FREE (in
#   bytes) and IMPACT_CHECK_DISK_MOUNT (the folder where that file system is
#   mounted). "Free" is the space that a normal account may still use.
#   Result: failure when df gives no answer within 20 seconds.
impact_check_disk_facts() {
    local existing output size free mount
    IMPACT_CHECK_DISK_SIZE=''
    IMPACT_CHECK_DISK_FREE=''
    IMPACT_CHECK_DISK_MOUNT=''
    existing="$(impact_nearest_existing "$1")"
    # df --output prints the chosen columns; -B1 counts in bytes. "timeout"
    # protects against a network disk that does not answer.
    output="$(timeout 20 df -B1 --output=size,avail,target -- "$existing" 2>/dev/null | tail -n 1)" || return 1
    read -r size free mount <<<"$output" || true
    [[ "$size" =~ ^[0-9]+$ && "$free" =~ ^[0-9]+$ && -n "$mount" ]] || return 1
    IMPACT_CHECK_DISK_SIZE="$size"
    IMPACT_CHECK_DISK_FREE="$free"
    IMPACT_CHECK_DISK_MOUNT="$mount"
}

# impact_check_mode_writable_by_others MODE
#   Result: success when the octal MODE (for example 775) lets the group or
#   all others write.
impact_check_mode_writable_by_others() {
    [[ "$1" =~ ^[0-7]{3,4}$ ]] || return 0
    # "8#" reads the digits as an octal number; "& 8#022" keeps only the
    # write bits of the group and of all others.
    (((8#$1 & 8#022) != 0))
}

# =============================================================================
# Settings, accounts and other facts that several blocks need
# =============================================================================

# impact_check_load_settings
#   Reads the site settings file. On success IMPACT_CONF holds its values,
#   as for every other command. When the file is missing or cannot be used,
#   the check must still give a complete report (the administrator runs it
#   first on an untouched machine, before anything is installed). IMPACT_CONF
#   then holds the default
#   values of impact-workstation-setup; from a file that root alone can
#   change but that breaks a rule, every single value that passes its own
#   rule is taken over. A file that other accounts can change is never used:
#   its values could steer what this check, running as root, reads.
#   Result: success when the file is valid. IMPACT_CHECK_CONF_STATE says
#   what was found; IMPACT_CHECK_CONF_ERRORS holds the problems.
impact_check_load_settings() {
    local key
    local -A parsed=()
    local -a order=() errors=()
    IMPACT_CHECK_CONF_ERRORS=()
    IMPACT_CHECK_CONF_NOTES=()
    if impact_conf_load; then
        IMPACT_CHECK_CONF_STATE='ok'
        IMPACT_CHECK_CONF_NOTES=("${IMPACT_CONF_WARNINGS[@]}")
        return 0
    fi
    IMPACT_CHECK_CONF_ERRORS=("${IMPACT_CONF_ERRORS[@]}")
    IMPACT_CONF=()
    # shellcheck disable=SC2004
    # Reason for SC2004 ("$ is unnecessary"): IMPACT_CONF is an associative
    # array (declared in impact-settings.sh), whose key needs the "$".
    for key in "${IMPACT_CONF_KEYS[@]}"; do
        IMPACT_CONF[$key]="$(impact_conf_default "$key")"
    done
    if [[ ! -e "$IMPACT_CONF_FILE" && ! -L "$IMPACT_CONF_FILE" ]]; then
        IMPACT_CHECK_CONF_STATE='missing'
        return 1
    fi
    if ! impact_file_is_trusted "$IMPACT_CONF_FILE"; then
        IMPACT_CHECK_CONF_STATE='untrusted'
        return 1
    fi
    IMPACT_CHECK_CONF_STATE='invalid'
    # impact_kv_parse fills "parsed" also when some lines break a rule.
    impact_kv_parse "$IMPACT_CONF_FILE" parsed order errors || true
    for key in "${IMPACT_CONF_KEYS[@]}"; do
        if [[ -v parsed[$key] ]] && impact_conf_check_value "$key" "${parsed[$key]}"; then
            # shellcheck disable=SC2004
            # Reason for SC2004: see above, an associative array.
            IMPACT_CONF[$key]="${parsed[$key]}"
        fi
    done
    # The port range must be usable as a whole; otherwise take the defaults.
    if ((IMPACT_CONF[PORT_MIN] > IMPACT_CONF[PORT_MAX] || IMPACT_CONF[PORT_MAX] - IMPACT_CONF[PORT_MIN] + 1 > 200)); then
        IMPACT_CONF[PORT_MIN]="$(impact_conf_default PORT_MIN)"
        IMPACT_CONF[PORT_MAX]="$(impact_conf_default PORT_MAX)"
    fi
    return 1
}

# impact_check_shared_roots ARRAY_NAME
#   Fills the caller's array ARRAY_NAME with the storage roots to look at:
#   SHARED_ROOTS of the settings, then the extra roots of --shared-roots
#   that are not in that list already.
impact_check_shared_roots() {
    # "local -n" makes a second name for a variable of the caller, so this
    # function can fill an array that the caller owns.
    local -n impact__check_roots="$1"
    local root
    impact__check_roots=()
    impact_split_list "${IMPACT_CONF[SHARED_ROOTS]:-}" impact__check_roots
    for root in "${IMPACT_CHECK_EXTRA_ROOTS[@]}"; do
        if ! impact_in_list "$root" "${impact__check_roots[@]}"; then
            impact__check_roots+=("$root")
        fi
    done
}

# impact_check_root_is_configured ROOT
#   Result: success when ROOT is listed in SHARED_ROOTS of a usable
#   settings file. A root given only with --shared-roots is no such root.
impact_check_root_is_configured() {
    local -a configured=()
    [[ "$IMPACT_CHECK_CONF_STATE" == 'ok' ]] || return 1
    impact_split_list "${IMPACT_CONF[SHARED_ROOTS]:-}" configured
    impact_in_list "$1" "${configured[@]}"
}

# impact_check_uid_range
#   Sets IMPACT_CHECK_UID_MIN and IMPACT_CHECK_UID_MAX: the range of user
#   numbers for accounts of people, read from /etc/login.defs (Ubuntu's
#   defaults: 1000 and 60000).
impact_check_uid_range() {
    local key value
    IMPACT_CHECK_UID_MIN=1000
    IMPACT_CHECK_UID_MAX=60000
    [[ -r /etc/login.defs ]] || return 0
    while read -r key value _; do
        case "$key" in
            UID_MIN) [[ "$value" =~ ^[0-9]{1,9}$ ]] && IMPACT_CHECK_UID_MIN="$value" ;;
            UID_MAX) [[ "$value" =~ ^[0-9]{1,9}$ ]] && IMPACT_CHECK_UID_MAX="$value" ;;
            *) ;;
        esac
    done </etc/login.defs
}

# impact_check_people_accounts
#   Prints the accounts that block "Accounts" looks at, one per line,
#   sorted: every account with a user number in the range for people
#   (except "nobody"), every member of the shared group, and every account
#   that has an IMPACT account record.
impact_check_people_accounts() {
    local group="${IMPACT_CONF[SHARED_GROUP]}"
    impact_check_uid_range
    {
        # awk: field 3 is the user number, field 1 the name.
        getent passwd | awk -F: -v low="$IMPACT_CHECK_UID_MIN" -v high="$IMPACT_CHECK_UID_MAX" \
            '$3 >= low && $3 <= high && $1 != "nobody" { print $1 }'
        if impact_group_exists "$group"; then
            impact_group_members "$group"
        fi
        impact_account_records | while IFS= read -r name; do
            if impact_account_exists "$name"; then
                printf '%s\n' "$name"
            fi
        done
    } | sed -e '/^$/d' | sort -u
}

# impact_check_members
#   Prints the members of the shared group, one per line, sorted. Prints
#   nothing when the group does not exist.
impact_check_members() {
    if impact_group_exists "${IMPACT_CONF[SHARED_GROUP]}"; then
        impact_group_members "${IMPACT_CONF[SHARED_GROUP]}" || true
    fi
}

# impact_check__enrolment_unfinished ACCOUNT
#   Internal: success when the account record of ACCOUNT says that its
#   enrolment is not finished (STATE=enrolling: impact-add-user created the
#   account and stopped before its end). Block 7 reports such an account
#   once, with the way to continue; the other blocks leave out advice that
#   does not fit it (adding a key, creating folders, adding a group by
#   hand). Needs root rights to read the record; without them the answer
#   is no.
impact_check__enrolment_unfinished() {
    impact_account_record_load "$1" >/dev/null 2>&1 && [[ "${IMPACT_ACCOUNT_RECORD[STATE]}" == 'enrolling' ]]
}

# impact_check_entry_facts PATH
#   Looks at PATH itself (a symbolic link is not followed) and sets
#   IMPACT_CHECK_E_TYPE (folder, file, link, other or missing),
#   IMPACT_CHECK_E_OWNER, IMPACT_CHECK_E_GROUP (names) and IMPACT_CHECK_E_MODE
#   (octal, for example 2750).
impact_check_entry_facts() {
    local facts kind
    IMPACT_CHECK_E_TYPE='missing'
    IMPACT_CHECK_E_OWNER=''
    IMPACT_CHECK_E_GROUP=''
    IMPACT_CHECK_E_MODE=''
    if [[ ! -e "$1" && ! -L "$1" ]]; then
        return 0
    fi
    # stat without -L describes the entry itself. %F is the kind of entry,
    # %U and %G the names of owner and group, %a the mode.
    facts="$(stat -c '%U|%G|%a|%F' -- "$1" 2>/dev/null)" || {
        IMPACT_CHECK_E_TYPE='other'
        return 0
    }
    IFS='|' read -r IMPACT_CHECK_E_OWNER IMPACT_CHECK_E_GROUP IMPACT_CHECK_E_MODE kind <<<"$facts"
    case "$kind" in
        directory) IMPACT_CHECK_E_TYPE='folder' ;;
        'regular file' | 'regular empty file') IMPACT_CHECK_E_TYPE='file' ;;
        'symbolic link') IMPACT_CHECK_E_TYPE='link' ;;
        *) IMPACT_CHECK_E_TYPE='other' ;;
    esac
}

# =============================================================================
# Docker facts that several blocks need
# =============================================================================

# The template for "docker container inspect". It prints one line per
# container with fields separated by tab characters:
#   name, state, image, account label, keys of all labels, published ports.
# Texts that people can choose (image name, label values) are printed with
# "%q" in quotes, so a tab or line break inside them cannot break the line
# apart. The last two fields start with "L:" and "P:", so no field is ever
# empty: "read" would join two tabs with nothing between them into one. Each published port is "address|host port|container port"; a
# running container shows what Docker really opened, a stopped one what it
# would open at its next start.
# shellcheck disable=SC2016
# Reason for SC2016 (no expansion in single quotes): "$key", "$port" and
# the like are variables of Docker's template language, not of bash.
readonly IMPACT_CHECK_CONTAINER_FORMAT='{{.Name}}{{"\t"}}{{.State.Status}}{{"\t"}}{{printf "%q" .Config.Image}}{{"\t"}}{{printf "%q" (index .Config.Labels "impact.account")}}{{"\t"}}L:{{range $key, $value := .Config.Labels}}{{printf "%q" $key}} {{end}}{{"\t"}}P:{{if .State.Running}}{{range $port, $list := .NetworkSettings.Ports}}{{range $list}}{{.HostIp}}|{{.HostPort}}|{{$port}} {{end}}{{end}}{{else}}{{range $port, $list := .HostConfig.PortBindings}}{{range $list}}{{.HostIp}}|{{.HostPort}}|{{$port}} {{end}}{{end}}{{end}}'

# impact_check_docker_answers
#   Result: success when the Docker program exists and its daemon answers.
#   The answer is remembered for the rest of the block.
impact_check_docker_answers() {
    if [[ -z "${IMPACT_CHECK_DOCKER_STATE:-}" ]]; then
        if ! impact_docker_installed; then
            IMPACT_CHECK_DOCKER_STATE='missing'
        elif impact_docker_daemon_reachable; then
            IMPACT_CHECK_DOCKER_STATE='answers'
        else
            IMPACT_CHECK_DOCKER_STATE='silent'
        fi
    fi
    [[ "$IMPACT_CHECK_DOCKER_STATE" == 'answers' ]]
}

# impact_check_docker_unavailable
#   For the blocks about containers and volumes when Docker cannot be
#   asked: prints the reason as a warning (these blocks then cannot tell
#   whether everything is in order).
impact_check_docker_unavailable() {
    if [[ "${IMPACT_CHECK_DOCKER_STATE:-}" == 'missing' ]]; then
        impact_check_warn "Docker is not installed, so this block has nothing to look at." \
            "Install Docker first (see block 2), then run sudo impact-check again."
    else
        impact_check_warn "The Docker daemon does not answer, so this block cannot look at containers and volumes." \
            "Start Docker (sudo systemctl start docker) and run sudo impact-check again."
    fi
}

# impact_check_load_containers
#   Asks Docker for all containers (running and stopped) and fills the
#   lists IMPACT_CHECK_C_NAME, IMPACT_CHECK_C_STATE, IMPACT_CHECK_C_IMAGE,
#   IMPACT_CHECK_C_ACCOUNT (the label impact.account; empty without it;
#   "(invalid)" for a value that is no account name), IMPACT_CHECK_C_OLDLABEL
#   (1 when the container has the labels that GUI 2.0 sets, for example
#   impact.use_volumes)
#   and IMPACT_CHECK_C_PORTS (published ports, "address|host port|container
#   port" separated by blanks).
#   Result: failure when Docker does not answer.
impact_check_load_containers() {
    local line name state image account keys ports key
    local -a ids=() key_list=()
    IMPACT_CHECK_C_NAME=()
    IMPACT_CHECK_C_STATE=()
    IMPACT_CHECK_C_IMAGE=()
    IMPACT_CHECK_C_ACCOUNT=()
    IMPACT_CHECK_C_OLDLABEL=()
    IMPACT_CHECK_C_PORTS=()
    impact_check_docker_answers || return 1
    # "mapfile -t" reads lines into a list. "< <( ... )" feeds the output of
    # a command into it while mapfile runs in this script.
    mapfile -t ids < <(impact_docker_ro ps --all --quiet --no-trunc 2>/dev/null || true)
    ((${#ids[@]} > 0)) || return 0
    while IFS= read -r line; do
        # Split the line at the tab characters into its six fields.
        IFS=$'\t' read -r name state image account keys ports <<<"$line" || true
        name="${name#/}"
        keys="${keys#L:}"
        ports="${ports#P:}"
        [[ -n "$name" ]] || continue
        IMPACT_CHECK_C_NAME+=("$(impact_display "$name")")
        IMPACT_CHECK_C_STATE+=("$(impact_display "$state")")
        image="$(impact_check_unquote "$image")" || image='(unreadable name)'
        IMPACT_CHECK_C_IMAGE+=("$(impact_display "$image")")
        if account="$(impact_check_unquote "$account")"; then
            if [[ -n "$account" ]] && ! impact_valid_account_name "$account"; then
                account='(invalid)'
            fi
        else
            account='(invalid)'
        fi
        IMPACT_CHECK_C_ACCOUNT+=("$account")
        # GUI 2.0 marks its containers with these labels (and never with
        # impact.account).
        local old=0
        read -r -a key_list <<<"$keys" || true
        for key in "${key_list[@]}"; do
            case "$key" in
                '"impact.use_volumes"' | '"impact.repo_path"' | '"impact.output_dir"' | '"impact.synthpop_dir"') old=1 ;;
                *) ;;
            esac
        done
        IMPACT_CHECK_C_OLDLABEL+=("$old")
        IMPACT_CHECK_C_PORTS+=("$ports")
    done < <(impact_docker_ro container inspect --format "$IMPACT_CHECK_CONTAINER_FORMAT" "${ids[@]}" 2>/dev/null || true)
}

# impact_check_ports_text PORTS
#   Prints the published ports of a container (the form of
#   IMPACT_CHECK_C_PORTS) in readable form, for example
#   "127.0.0.1:8787 -> 8787/tcp, all addresses:8788 -> 8787/tcp".
impact_check_ports_text() {
    local entry address host_port container_port text=''
    local -a entries=()
    # "read -a" splits the text at blanks into the list "entries".
    read -r -a entries <<<"$1" || true
    for entry in "${entries[@]}"; do
        IFS='|' read -r address host_port container_port <<<"$entry" || true
        if [[ "$(impact_check_address_kind "$address")" == 'all' ]]; then
            address='all addresses'
        elif [[ "$address" == *:* ]]; then
            address="[$address]"
        fi
        # The same port on all IPv4 and all IPv6 addresses reads the same:
        # name it once. "${text:+, }" is ", " when text is not empty, and
        # nothing when it is.
        if [[ ", $text, " != *", $address:$host_port -> $container_port, "* ]]; then
            text+="${text:+, }$address:$host_port -> $container_port"
        fi
    done
    printf '%s' "${text:-no published port}"
}

# impact_check_ports_reach PORTS
#   Prints "network" when one of the published ports (the form of
#   IMPACT_CHECK_C_PORTS) can be reached from other computers, "loopback"
#   when all are on 127.0.0.1 or ::1, and "none" without published ports.
impact_check_ports_reach() {
    local entry address reach='none'
    local -a entries=()
    read -r -a entries <<<"$1" || true
    for entry in "${entries[@]}"; do
        address="${entry%%|*}"
        if [[ "$(impact_check_address_kind "$address")" == 'loopback' ]]; then
            [[ "$reach" == 'none' ]] && reach='loopback'
        else
            reach='network'
        fi
    done
    printf '%s' "$reach"
}

# impact_check_docker_data_dir
#   Prints Docker's data folder: from the running daemon, else from
#   /etc/docker/daemon.json ("data-root"), else Docker's default
#   /var/lib/docker.
impact_check_docker_data_dir() {
    local folder=''
    if impact_check_docker_answers; then
        folder="$(impact_docker_ro info --format '{{.DockerRootDir}}' 2>/dev/null)" || folder=''
    fi
    if [[ -z "$folder" && -r /etc/docker/daemon.json ]]; then
        # Read the value of "data-root" as text (there is no JSON tool on a
        # default Ubuntu server, and this is the only value needed).
        folder="$(grep -o -E '"data-root"[[:space:]]*:[[:space:]]*"[^"]*"' /etc/docker/daemon.json 2>/dev/null |
            head -n 1 | sed -E 's/.*"([^"]*)"$/\1/')" || folder=''
    fi
    if ! impact_valid_abs_path "$folder"; then
        folder='/var/lib/docker'
    fi
    printf '%s\n' "$folder"
}

# =============================================================================
# Block 1: System
# =============================================================================

# impact_check_block_system
#   Operating system, hardware, tools, and the installation of the IMPACT
#   commands themselves.
impact_check_block_system() {
    local line id='' version='' pretty='' memory_kb='' cpus kernel
    if [[ -r /etc/os-release ]]; then
        while IFS= read -r line; do
            case "$line" in
                ID=*) id="${line#ID=}" ;;
                VERSION_ID=*) version="${line#VERSION_ID=}" ;;
                PRETTY_NAME=*) pretty="${line#PRETTY_NAME=}" ;;
                *) ;;
            esac
        done </etc/os-release
    fi
    # Remove the quotes around the values.
    id="${id//\"/}"
    version="${version//\"/}"
    pretty="${pretty//\"/}"
    kernel="$(uname -r 2>/dev/null)" || kernel='unknown'
    cpus="$(nproc 2>/dev/null)" || cpus='?'
    memory_kb="$(awk '$1 == "MemTotal:" { print $2; exit }' /proc/meminfo 2>/dev/null)" || memory_kb=''
    impact_check_info "System: $(impact_display "${pretty:-unknown}"), kernel $(impact_display "$kernel"), $cpus CPUs, memory $(impact_check_size_text "$((${memory_kb:-0} * 1024))")."
    impact_check_info "Host name: $(impact_display "$(hostname 2>/dev/null || printf 'unknown')"). Running since: $(uptime -s 2>/dev/null || printf 'unknown')."
    impact_check_info "bash $BASH_VERSION. This check runs as $(id -un) for $(impact_invoking_account)."

    if [[ "$id" == 'ubuntu' && ("$version" == '22.04' || "$version" == '24.04') ]]; then
        impact_check_ok "Ubuntu $version is a supported system."
    elif [[ "$id" == 'ubuntu' ]] && impact_version_ge "$version" 22.04; then
        impact_check_warn "Ubuntu $(impact_display "$version") was not tested; the commands were written for 22.04 and 24.04." \
            "Read the output of every IMPACT command with care on this system."
    else
        impact_check_fail "This system is $(impact_display "${id:-unknown} ${version}"). The IMPACT commands are written for Ubuntu 22.04 and 24.04." \
            "Run the IMPACT commands on an Ubuntu 22.04 or 24.04 workstation."
    fi
    if [[ -e /run/reboot-required ]]; then
        impact_check_info "The system asks for a restart (updated packages wait for it). Plan one at a quiet moment: running containers end at a restart."
    fi

    local -a missing=() packages=()
    local tool package
    mapfile -t missing < <(impact_missing_tools "${IMPACT_CHECK_TOOLS[@]}" || true)
    if ((${#missing[@]} == 0)); then
        impact_check_ok "All tools that the IMPACT commands use are present."
    else
        # The Ubuntu package of each missing tool, each package once.
        for tool in "${missing[@]}"; do
            package="$(impact_package_for_tool "$tool")"
            if [[ -n "$package" ]] && ! impact_in_list "$package" "${packages[@]}"; then
                packages+=("$package")
            fi
        done
        if ((${#packages[@]} > 0)); then
            impact_check_warn "These tools are missing: ${missing[*]}." \
                "Install the missing tools: sudo apt-get install ${packages[*]}"
        else
            impact_check_warn "These tools are missing: ${missing[*]}." \
                "Install the Ubuntu packages that provide these tools (apt-cache search <tool> names them)."
        fi
    fi

    impact_check__installation
}

# impact_check__installation
#   Internal part of block 1: are the commands installed in /opt/impact,
#   with the links in /usr/local/bin, and safe from changes by other
#   accounts?
impact_check__installation() {
    local own installed='' file name link folder sub
    own="$(impact_own_version)"
    impact_check_info "This command: version $own, started from $(impact_display "$IMPACT_SELF")."
    if [[ ! -d "$IMPACT_INSTALL_DIR/bin" ]]; then
        impact_check_warn "The IMPACT commands are not installed in $IMPACT_INSTALL_DIR yet." \
            "Install the commands from the unpacked archive folder: sudo ./install.sh (try sudo ./install.sh --dry-run first)."
        return 0
    fi
    if [[ -r "$IMPACT_INSTALL_DIR/VERSION" ]]; then
        IFS= read -r installed <"$IMPACT_INSTALL_DIR/VERSION" || true
    fi
    installed="$(impact_display "${installed:-unknown}")"
    if [[ "$IMPACT_BASE_DIR" != "$IMPACT_INSTALL_DIR" && "$installed" != "$own" ]]; then
        impact_check_warn "The installed commands have version $installed; this command has version $own." \
            "Install the version you want to use: sudo ./install.sh in its unpacked folder."
    else
        impact_check_ok "The IMPACT commands version $installed are installed in $IMPACT_INSTALL_DIR."
    fi
    # Every file of the commands must belong to root and be writable by
    # root only: otherwise another account could change what root runs.
    for folder in "$IMPACT_INSTALL_DIR" "$IMPACT_INSTALL_DIR/bin" "$IMPACT_INSTALL_DIR/lib"; do
        impact_check_entry_facts "$folder"
        if [[ "$IMPACT_CHECK_E_TYPE" != 'folder' || "$IMPACT_CHECK_E_OWNER" != 'root' ]] ||
            impact_check_mode_writable_by_others "$IMPACT_CHECK_E_MODE"; then
            impact_check_fail "$folder is no folder of root that only root can change (found: $IMPACT_CHECK_E_TYPE, owner $IMPACT_CHECK_E_OWNER, mode $IMPACT_CHECK_E_MODE)." \
                "Install the commands again: sudo ./install.sh in the unpacked archive folder."
        fi
    done
    local unsafe=0
    shopt -s nullglob
    for file in "$IMPACT_INSTALL_DIR"/bin/impact-* "$IMPACT_INSTALL_DIR"/lib/impact-*.sh; do
        impact_check_entry_facts "$file"
        if [[ "$IMPACT_CHECK_E_TYPE" != 'file' || "$IMPACT_CHECK_E_OWNER" != 'root' ]] ||
            impact_check_mode_writable_by_others "$IMPACT_CHECK_E_MODE"; then
            unsafe=$((unsafe + 1))
        fi
    done
    shopt -u nullglob
    if ((unsafe > 0)); then
        impact_check_fail "$unsafe files of the installed commands do not belong to root or can be changed by other accounts." \
            "Install the commands again: sudo ./install.sh in the unpacked archive folder."
    fi
    local missing_links=()
    shopt -s nullglob
    for file in "$IMPACT_INSTALL_DIR"/bin/impact-*; do
        name="$(basename -- "$file")"
        link="$IMPACT_LINK_DIR/$name"
        if [[ ! -L "$link" || "$(readlink -- "$link" 2>/dev/null)" != "$file" ]]; then
            missing_links+=("$name")
        fi
    done
    shopt -u nullglob
    if ((${#missing_links[@]} > 0)); then
        impact_check_warn "These commands have no link in $IMPACT_LINK_DIR, so 'sudo <command>' does not find them: ${missing_links[*]}." \
            "Install the commands again: sudo ./install.sh in the unpacked archive folder."
    else
        impact_check_ok "Every command has its link in $IMPACT_LINK_DIR."
    fi
    # The folder of the administrator: logs, keys, account records, backups.
    impact_check_entry_facts "$IMPACT_ADMIN_DIR"
    if [[ "$IMPACT_CHECK_E_TYPE" == 'missing' ]]; then
        impact_check_warn "$IMPACT_ADMIN_DIR does not exist yet." \
            "impact-workstation-setup creates it: sudo impact-workstation-setup --help"
        return 0
    fi
    for sub in '' "${IMPACT_CHECK_ADMIN_SUBDIRS[@]}"; do
        folder="$IMPACT_ADMIN_DIR${sub:+/$sub}"
        if ! impact_dir_is "$folder" 700 root root; then
            impact_check_entry_facts "$folder"
            if [[ "$IMPACT_CHECK_E_TYPE" == 'missing' ]]; then
                impact_check_warn "$folder does not exist." \
                    "Run sudo impact-workstation-setup once more; it creates the missing folders and changes nothing else that is in order."
            else
                impact_check_fail "$folder must be a folder of root with mode 700 (found: $IMPACT_CHECK_E_TYPE, owner $IMPACT_CHECK_E_OWNER, group $IMPACT_CHECK_E_GROUP, mode $IMPACT_CHECK_E_MODE). It holds keys and records that only the administrator may read." \
                    "Correct the rights: sudo chown root:root $folder && sudo chmod 700 $folder"
            fi
        fi
    done
}

# =============================================================================
# Block 2: Docker
# =============================================================================

# impact_check_block_docker
#   Docker's version, package source, start at boot, data folder and its
#   disk, and the size of the images per account.
impact_check_block_docker() {
    local origin engine='' server='' version boot mode="${IMPACT_CONF[ACCESS_MODE]}"
    origin="$(impact_docker_install_source)"
    case "$origin" in
        none)
            impact_check_fail "Docker Engine is not installed." \
                "Install the package docker-ce from Docker's own apt source: https://docs.docker.com/engine/install/ubuntu/"
            return 0
            ;;
        snap)
            impact_check_fail "Docker is installed as a snap package. That variant runs in a closed environment and cannot use all folders of the machine, for example the storage disks." \
                "Remove the snap package (sudo snap remove docker) and install the package docker-ce from Docker's own apt source: https://docs.docker.com/engine/install/ubuntu/"
            ;;
        docker-ce)
            impact_check_ok "Docker comes from Docker's own apt source (package docker-ce)."
            ;;
        *)
            impact_check_warn "Docker does not come from the package docker-ce (found: $origin). The IMPACT commands were written for docker-ce from Docker's own apt source." \
                "Install docker-ce from Docker's own apt source at a quiet moment: https://docs.docker.com/engine/install/ubuntu/"
            ;;
    esac
    if [[ "$origin" != 'snap' ]] && impact_docker_snap_present; then
        impact_check_warn "The snap package of Docker is installed in addition." \
            "Remove the snap package to avoid confusion: sudo snap remove docker"
    fi

    engine="$(impact_docker_engine_version)" || engine=''
    if impact_check_docker_answers; then
        server="$(impact_docker_server_version)" || server=''
    fi
    for version in "$engine" "$server"; do
        [[ -n "$version" ]] || continue
        if ! impact_version_ge "$version" "$IMPACT_DOCKER_MIN_VERSION"; then
            if [[ "$mode" == 'tunnel' ]]; then
                impact_check_fail "Docker Engine $version is older than $IMPACT_DOCKER_MIN_VERSION. Older versions can let neighbouring computers reach ports that are published on 127.0.0.1, and ACCESS_MODE is tunnel." \
                    "Update Docker: sudo apt-get update && sudo apt-get install docker-ce docker-ce-cli containerd.io"
            else
                impact_check_warn "Docker Engine $version is older than $IMPACT_DOCKER_MIN_VERSION. This matters as soon as ACCESS_MODE is set to tunnel." \
                    "Update Docker: sudo apt-get update && sudo apt-get install docker-ce docker-ce-cli containerd.io"
            fi
        fi
    done
    if [[ -n "$engine" ]]; then
        impact_check_info "Installed Docker Engine: $engine (tunnel mode needs $IMPACT_DOCKER_MIN_VERSION or newer)."
    else
        impact_check_warn "The version of the installed Docker Engine cannot be read ('dockerd --version' gives no answer)." \
            "Look at the installation: sudo systemctl status docker; dockerd --version"
    fi
    if [[ -n "$server" ]]; then
        impact_check_ok "The Docker daemon answers (version $server)."
        if [[ -n "$engine" && "$engine" != "$server" ]]; then
            impact_check_warn "The running daemon has version $server, the installed program version $engine: Docker was updated and not restarted." \
                "Restart Docker at a quiet moment (running containers stop): sudo systemctl restart docker"
        fi
    else
        impact_check_fail "The Docker daemon does not answer." \
            "Start Docker and look at its state: sudo systemctl start docker; sudo systemctl status docker"
    fi

    boot="$(impact_docker_boot_state)"
    case "$boot" in
        enabled) impact_check_ok "Docker starts with the machine." ;;
        socket)
            impact_check_warn "Docker starts at its first use only (docker.socket), so containers that should restart after a reboot stay stopped until then." \
                "Let Docker start with the machine: sudo systemctl enable docker.service"
            ;;
        disabled)
            impact_check_fail "Docker does not start with the machine. After a restart no colleague can start a container until the administrator starts Docker." \
                "Let Docker start with the machine: sudo systemctl enable --now docker.service docker.socket"
            ;;
        *)
            impact_check_warn "Whether Docker starts with the machine cannot be told, because systemd does not run here." \
                "Check by hand on the machine: systemctl is-enabled docker.service"
            ;;
    esac
    if ! impact_group_exists docker; then
        impact_check_warn "The group 'docker' does not exist. impact-add-user needs it." \
            "The package docker-ce creates it; install or repair docker-ce."
    fi

    impact_check__docker_storage
    impact_check__images_per_account
}

# impact_check__docker_storage
#   Internal part of block 2: where Docker keeps its data, on which disk,
#   and which storage method it uses.
impact_check__docker_storage() {
    local folder driver='' status='' line
    folder="$(impact_check_docker_data_dir)"
    if impact_check_docker_answers; then
        line="$(impact_docker_ro info --format '{{.Driver}}|{{range .DriverStatus}}{{index . 0}}={{index . 1}};{{end}}' 2>/dev/null)" || line=''
        driver="${line%%|*}"
        status="${line#*|}"
        impact_check_info "Storage driver: $(impact_display "${driver:-unknown}")."
        if [[ "$status" == *io.containerd.snapshotter* ]]; then
            impact_check_info "Docker keeps its images in the image store of containerd (with the package containerd.io usually below /var/lib/containerd)."
        fi
    fi
    if impact_check_disk_facts "$folder"; then
        impact_check_info "Docker's data folder $(impact_display "$folder") lies on the disk mounted at $(impact_display "$IMPACT_CHECK_DISK_MOUNT"): $(impact_check_size_text "$IMPACT_CHECK_DISK_FREE") free of $(impact_check_size_text "$IMPACT_CHECK_DISK_SIZE")."
        if [[ "$IMPACT_CHECK_DISK_MOUNT" == '/' ]]; then
            impact_check_info "That is the system disk, which also holds the home folders and the repository copies. Block 3 compares its free space with MIN_FREE_GB."
        fi
    fi
    if [[ -d /var/lib/containerd ]] && impact_check_disk_facts /var/lib/containerd; then
        impact_check_info "The folder of containerd, /var/lib/containerd, lies on the disk mounted at $(impact_display "$IMPACT_CHECK_DISK_MOUNT")."
    fi
}

# impact_check__images_per_account
#   Internal part of block 2: the images that carry the label
#   impact.account, added up per account. The sizes of images share their
#   common base layers, so the sum per account is larger than the disk space
#   these images use together; "docker system df" gives the real use.
impact_check__images_per_account() {
    local line account size total_known=0 count_unlabelled=0 size_unlabelled=0
    local -a ids=()
    # "local -A" makes associative lists: entries found by a name (here the
    # account), not by a position.
    local -A sizes=() counts=()
    if ! impact_check_docker_answers; then
        return 0
    fi
    mapfile -t ids < <(impact_docker_ro image ls --quiet --no-trunc 2>/dev/null | LC_ALL=C sort -u || true)
    if ((${#ids[@]} == 0)); then
        impact_check_ok "Docker holds no image yet."
        return 0
    fi
    while IFS=' ' read -r account size; do
        [[ "$size" =~ ^[0-9]+$ ]] || continue
        if ! account="$(impact_check_unquote "$account")"; then
            account='(invalid label)'
        elif [[ -z "$account" ]]; then
            count_unlabelled=$((count_unlabelled + 1))
            size_unlabelled=$((size_unlabelled + size))
            continue
        elif ! impact_valid_account_name "$account"; then
            account='(invalid label)'
        fi
        sizes[$account]=$((${sizes[$account]:-0} + size))
        counts[$account]=$((${counts[$account]:-0} + 1))
        total_known=$((total_known + size))
    done < <(impact_docker_ro image inspect --format '{{printf "%q" (index .Config.Labels "impact.account")}} {{.Size}}' "${ids[@]}" 2>/dev/null || true)
    impact_check_info "Images: ${#ids[@]} in total. Without the label impact.account (base images and images made outside the GUI): $count_unlabelled, $(impact_check_size_text "$size_unlabelled")."
    line="$(impact_docker_ro system df --format '{{.Type}}: {{.Size}} ({{.Reclaimable}} reclaimable)' 2>/dev/null | head -n 1)" || line=''
    if [[ -n "$line" ]]; then
        impact_check_info "Disk use reported by Docker: $(impact_display "$line")."
    fi
    if ((${#sizes[@]} == 0)); then
        impact_check_ok "No image carries the label impact.account yet (the GUI 2.1 builds one image per person and model)."
        return 0
    fi
    local -a stale=()
    # "${!sizes[@]}" lists the keys of the associative array; sort orders them.
    while IFS= read -r account; do
        [[ -n "$account" ]] || continue
        impact_check_info "Images of $account: ${counts[$account]}, $(impact_check_size_text "${sizes[$account]}") (shared layers counted for each image)."
        if [[ "$account" == '(invalid label)' ]] || ! impact_account_exists "$account" ||
            ! impact_account_in_group "$account" "${IMPACT_CONF[SHARED_GROUP]}"; then
            stale+=("$account")
        fi
    done < <(printf '%s\n' "${!sizes[@]}" | LC_ALL=C sort)
    if ((${#stale[@]} > 0)); then
        impact_check_warn "Images belong to accounts that are no members of '${IMPACT_CONF[SHARED_GROUP]}' (removed or unknown): ${stale[*]}." \
            "List the images that can go, and remove them after a look: sudo impact-clean-images"
    fi
}

# =============================================================================
# Block 3: Free disk space
# =============================================================================

# impact_check__mount_of PATH
#   Internal: prints the mount point of the disk that holds PATH (or its
#   closest existing parent), or nothing.
impact_check__mount_of() {
    local place
    place="$(impact_nearest_existing "$1")" || return 0
    findmnt -n -o TARGET -T "$place" 2>/dev/null | head -n 1 || true
}

# impact_check__free_space_hint MOUNT
#   Internal: prints what can be removed to free space on the disk mounted
#   at MOUNT, naming only what lies on that disk: old images when Docker's
#   data folder is there, files in home folders when /home is there, old
#   outputs and synthetic populations when a storage root is there.
impact_check__free_space_hint() {
    local mount="$1" root
    local -a parts=() roots=()
    if [[ "$(impact_check__mount_of "$(impact_check_docker_data_dir)")" == "$mount" ]]; then
        parts+=('old images (sudo impact-clean-images)')
    fi
    if [[ "$(impact_check__mount_of /home)" == "$mount" ]]; then
        parts+=('files in home folders')
    fi
    impact_check_shared_roots roots
    for root in "${roots[@]}"; do
        if [[ -e "$root" && "$(impact_check__mount_of "$root")" == "$mount" ]]; then
            parts+=("old outputs and synthetic populations in the model folders of $root")
        fi
    done
    if ((${#parts[@]} == 0)); then
        parts+=('files that are no longer needed (sudo du -xh --max-depth=2 '"$mount"' | sort -h | tail -n 20 shows the largest folders)')
    fi
    # Join the parts with ", ": "${parts[*]}" joins with the first
    # character of IFS, which is set to "," for this one line.
    local IFS=','
    printf '%s' "${parts[*]}" | sed -e 's/,/, /g'
}

# impact_check__free_space LABEL PATH
#   Internal part of block 3: free space of the disk that holds PATH,
#   compared with MIN_FREE_GB.
impact_check__free_space() {
    local label="$1" path="$2" limit="${IMPACT_CONF[MIN_FREE_GB]}" free_gb
    if ! impact_check_disk_facts "$path"; then
        impact_check_warn "The free space of $label ($(impact_display "$path")) cannot be read: df gives no answer." \
            "Look at the disk by hand: df -h $(impact_display "$path")"
        return 0
    fi
    free_gb="$(impact_check_gb_floor "$IMPACT_CHECK_DISK_FREE")"
    local text hint
    text="$label ($(impact_display "$path"), disk mounted at $(impact_display "$IMPACT_CHECK_DISK_MOUNT")): $(impact_check_size_text "$IMPACT_CHECK_DISK_FREE") free of $(impact_check_size_text "$IMPACT_CHECK_DISK_SIZE")"
    if ((IMPACT_CHECK_DISK_FREE < 1073741824 || free_gb < limit)); then
        hint="$(impact_check__free_space_hint "$IMPACT_CHECK_DISK_MOUNT")"
    fi
    if ((IMPACT_CHECK_DISK_FREE < 1073741824)); then
        impact_check_fail "$text. The disk is full." \
            "Free space on the disk mounted at $(impact_display "$IMPACT_CHECK_DISK_MOUNT") now: $hint."
    elif ((free_gb < limit)); then
        impact_check_warn "$text: less than MIN_FREE_GB=$limit GB." \
            "Free space on the disk mounted at $(impact_display "$IMPACT_CHECK_DISK_MOUNT"): $hint."
    else
        impact_check_ok "$text (limit MIN_FREE_GB=$limit GB)."
    fi
}

# impact_check_block_free_space
#   The system disk (and the disks of the home folders and of Docker's data
#   when they are separate), and the disk of every storage root.
impact_check_block_free_space() {
    local root docker_folder
    local -a roots=() seen=()
    impact_check_note_guess
    impact_check__free_space 'The system disk' /
    seen+=("$IMPACT_CHECK_DISK_MOUNT")
    if impact_check_disk_facts /home && ! impact_in_list "$IMPACT_CHECK_DISK_MOUNT" "${seen[@]}"; then
        impact_check__free_space 'The disk of the home folders' /home
        seen+=("$IMPACT_CHECK_DISK_MOUNT")
    fi
    docker_folder="$(impact_check_docker_data_dir)"
    if [[ -e "$docker_folder" ]] && impact_check_disk_facts "$docker_folder" && ! impact_in_list "$IMPACT_CHECK_DISK_MOUNT" "${seen[@]}"; then
        impact_check__free_space "The disk of Docker's data" "$docker_folder"
    fi
    impact_check_shared_roots roots
    if ((${#roots[@]} == 0)); then
        impact_check_info "No storage root is known yet (SHARED_ROOTS). To look at a disk before the setup: sudo impact-check --shared-roots /mnt/disk_a/shared"
        return 0
    fi
    for root in "${roots[@]}"; do
        if [[ ! -e "$root" ]]; then
            if impact_check_root_is_configured "$root"; then
                impact_check_fail "The storage root $root does not exist." \
                    "Mount the disk that holds it, or create the folder with: sudo impact-workstation-setup (it creates missing storage roots)."
            else
                impact_check_warn "The storage root $root (given with --shared-roots) does not exist." \
                    "Check the path, or mount the disk that should hold it."
            fi
            continue
        fi
        impact_check__free_space "The storage root $root" "$root"
    done
}

# =============================================================================
# Block 4: Settings file
# =============================================================================

# impact_check_block_settings
#   The site settings file /etc/impact/impact.conf: present, safe, valid;
#   its values; the GitHub host keys for impact-get-repo.
impact_check_block_settings() {
    local text key
    case "$IMPACT_CHECK_CONF_STATE" in
        missing)
            impact_check_fail "The settings file $IMPACT_CONF_FILE does not exist: the workstation is not set up for IMPACT Docker GUI 2.1." \
                "Set it up: sudo impact-workstation-setup --dry-run --shared-roots <paths> --admin-contact <text> (then the same without --dry-run). Before that, this check uses default values."
            ;;
        untrusted)
            impact_check_fail "The settings file cannot be used: ${IMPACT_CHECK_CONF_ERRORS[*]}" \
                "Give the settings file back to root: sudo chown root:root $IMPACT_CONF_FILE && sudo chmod 644 $IMPACT_CONF_FILE (and the same with mode 755 for its folder $IMPACT_CONF_DIR)."
            ;;
        invalid)
            for text in "${IMPACT_CHECK_CONF_ERRORS[@]}"; do
                impact_check_fail "$IMPACT_CONF_FILE: $text" \
                    "Correct the lines named above with an editor (sudo nano $IMPACT_CONF_FILE) or set the value again: sudo impact-workstation-setup --<option> <value>"
            done
            ;;
        *)
            impact_check_ok "The settings file $IMPACT_CONF_FILE is valid."
            ;;
    esac
    for text in "${IMPACT_CHECK_CONF_NOTES[@]}"; do
        impact_check_warn "$IMPACT_CONF_FILE: $text" \
            "Remove the unknown line with an editor (sudo nano $IMPACT_CONF_FILE); check its spelling first."
    done
    if [[ "$IMPACT_CHECK_CONF_STATE" == 'ok' ]]; then
        for key in "${IMPACT_CONF_KEYS[@]}"; do
            impact_check_info "$key=$(impact_display "${IMPACT_CONF[$key]}")"
        done
        if [[ "${IMPACT_CONF[REPO_BASE]}" != *%h* && "${IMPACT_CONF[REPO_BASE]}" != *%u* ]]; then
            impact_check_warn "REPO_BASE contains neither %h nor %u, so all people would share one repository folder." \
                "Set a folder per person: sudo impact-workstation-setup --repo-base %h/Repositories"
        fi
        if [[ "${IMPACT_CONF[ACCESS_MODE]}" == 'direct' ]]; then
            impact_check_info "ACCESS_MODE is direct: new containers are published to the network as in version 2.0 (the way back of the migration)."
        fi
        # The GUI reads this file as the person, so everybody must be able to
        # read it; only root may change it (checked above).
        impact_check_entry_facts "$IMPACT_CONF_FILE"
        if [[ "$IMPACT_CHECK_E_MODE" =~ ^[0-7]+$ ]] && (((8#$IMPACT_CHECK_E_MODE & 8#004) == 0)); then
            impact_check_fail "$IMPACT_CONF_FILE has mode $IMPACT_CHECK_E_MODE: colleagues cannot read it, so the GUI stops its remote preparation." \
                "Make the settings file readable: sudo chmod 644 $IMPACT_CONF_FILE"
        fi
    fi
    impact_check__known_hosts
}

# impact_check__known_hosts
#   Internal part of block 4: /etc/impact/github_known_hosts, which
#   impact-get-repo uses to recognise github.com.
impact_check__known_hosts() {
    local file="$IMPACT_KNOWN_HOSTS_FILE" delivered="$IMPACT_BASE_DIR/etc/github_known_hosts" count
    impact_check_entry_facts "$file"
    if [[ "$IMPACT_CHECK_E_TYPE" == 'missing' ]]; then
        if [[ "$IMPACT_CHECK_CONF_STATE" == 'missing' ]]; then
            impact_check_info "$file does not exist yet; impact-workstation-setup writes it."
        else
            impact_check_fail "$file does not exist, so impact-get-repo cannot recognise github.com." \
                "Run sudo impact-workstation-setup once more; it writes the file and changes nothing else that is in order."
        fi
        return 0
    fi
    if [[ "$IMPACT_CHECK_E_TYPE" != 'file' || "$IMPACT_CHECK_E_OWNER" != 'root' ]] ||
        impact_check_mode_writable_by_others "$IMPACT_CHECK_E_MODE"; then
        impact_check_fail "$file is no file of root that only root can change (found: $IMPACT_CHECK_E_TYPE, owner $IMPACT_CHECK_E_OWNER, mode $IMPACT_CHECK_E_MODE)." \
            "Write the host key file again: sudo rm $file && sudo impact-workstation-setup"
        return 0
    fi
    count="$(grep -c -E '^github\.com (ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) ' -- "$file" 2>/dev/null)" || count=0
    if [[ -f "$delivered" ]] && ! cmp -s -- "$file" "$delivered"; then
        impact_check_warn "$file differs from the copy delivered with the commands ($delivered)." \
            "If GitHub has not announced new keys, write the delivered copy again: sudo install -m 644 -o root -g root $delivered $file"
    elif ((count != 3)); then
        impact_check_warn "$file holds $count of GitHub's three host keys." \
            "Write the delivered copy again: sudo impact-workstation-setup"
    else
        impact_check_ok "$file holds GitHub's three host keys."
    fi
}

# =============================================================================
# Block 5: SSH rules
# =============================================================================

# impact_check__sshd_settings ACCOUNT ADDRESS [CONFIG_FILE]
#   Internal: prints the effective SSH settings of ACCOUNT for a login from
#   ADDRESS, sorted, as "sshd -T" reports them. With CONFIG_FILE sshd reads
#   that file as its main configuration file. Read-only. The question
#   itself is impact_ssh_effective of the library (30 seconds at most).
#   Result: failure when sshd reports an error.
impact_check__sshd_settings() {
    impact_ssh_effective "$1" "$2" "${3:-}"
}

# impact_check__admin_unchanged ACCOUNT ADDRESS
#   Internal part of block 5: compares the effective SSH settings of
#   ACCOUNT with and without the IMPACT rules file. The rules must apply to
#   members of the shared group only; an administrator who is no member
#   must get exactly the same settings either way.
impact_check__admin_unchanged() {
    local account="$1" address="$2" config="$IMPACT_CHECK_TMP_DIR/sshd_config.without-impact"
    local with without line shown=0
    if [[ -z "$IMPACT_CHECK_TMP_DIR" || ! -d "$IMPACT_CHECK_TMP_DIR" ]]; then
        impact_check_warn "No temporary folder is available, so the settings of '$account' cannot be compared with and without the rules." \
            "Run sudo impact-check again; if this stays, check that /tmp is writable for root."
        return 0
    fi
    if ! impact_check_config_without_rules "$IMPACT_SSHD_CONFIG" "$IMPACT_SSH_RULES_FILE" >"$config"; then
        impact_check_warn "The copy of $IMPACT_SSHD_CONFIG without the rules could not be made." \
            "Compare by hand: sudo sshd -T -C user=$account,host=$address,addr=$address"
        return 0
    fi
    if ! with="$(impact_check__sshd_settings "$account" "$address")" ||
        ! without="$(impact_check__sshd_settings "$account" "$address" "$config")"; then
        impact_check_warn "sshd could not be asked for the settings of '$account'." \
            "Ask sshd by hand: sudo sshd -T -C user=$account,host=$address,addr=$address"
        return 0
    fi
    if [[ "$with" == "$without" ]]; then
        impact_check_ok "The SSH rules leave the login of '$account' unchanged (sshd -T gives the same settings with and without the rules file)."
        return 0
    fi
    impact_check_fail "The SSH rules change the login of '$account'. They must apply to the members of '${IMPACT_CONF[SHARED_GROUP]}' only." \
        "Keep your session open and remove the rules now: sudo impact-workstation-setup --remove-ssh-rules. Then look at $IMPACT_SSH_RULES_FILE and at the group membership of '$account'."
    # diff prints "<" for lines without the rules and ">" for lines with them.
    while IFS= read -r line; do
        case "$line" in
            # "${line:2:100}" is the line from its third character on, at
            # most 100 characters (the list of ports can be very long).
            '<'*) impact_check_info "without the rules: ${line:2:100}" ;;
            '>'*) impact_check_info "with the rules:    ${line:2:100}" ;;
            *) continue ;;
        esac
        shown=$((shown + 1))
        ((shown < 12)) || break
    done < <(diff <(printf '%s\n' "$without") <(printf '%s\n' "$with") || true)
}

# impact_check_block_ssh
#   The SSH rules file: present, read by sshd, as impact-workstation-setup
#   writes it; effective for every member; no change for the administrator
#   and root.
impact_check_block_ssh() {
    local group="${IMPACT_CONF[SHARED_GROUP]}" min="${IMPACT_CONF[PORT_MIN]}" max="${IMPACT_CONF[PORT_MAX]}"
    local admin address member status deviations file rules_present=0 good=0
    local -a members=() others=()
    impact_check_note_guess
    if [[ ! -x "$IMPACT_SSHD" ]]; then
        impact_check_fail "The SSH server program $IMPACT_SSHD is not installed." \
            "Install the SSH server: sudo apt-get install openssh-server"
        return 0
    fi
    if impact_ssh_listening; then
        impact_check_ok "An SSH server answers on this machine."
    else
        impact_check_warn "No SSH server answers on this machine (the ports of sshd -T were tried on 127.0.0.1 and ::1)." \
            "Look at the SSH service: sudo systemctl status ssh"
    fi
    # A change of the rules file that an interrupted run left unconfirmed:
    # the running SSH server may still use the old rules, while sshd -T
    # (and so every check below) already reads the new file.
    if [[ -e "$IMPACT_SSH_PENDING_FILE" || -L "$IMPACT_SSH_PENDING_FILE" ]]; then
        impact_check_warn "A change of the SSH rules was interrupted before the SSH service had read it (note $IMPACT_SSH_PENDING_FILE). The running SSH server may still use the rules from before; the checks below read the files." \
            "Run the interrupted command again; it puts the previous file back and repeats the change with all checks: sudo impact-workstation-setup (or sudo impact-workstation-setup --remove-ssh-rules when the rules were being removed)"
    fi
    if impact_ssh_include_ok; then
        impact_check_ok "$IMPACT_SSHD_CONFIG reads the files in $IMPACT_SSH_RULES_DIR before any Match line."
    else
        impact_check_fail "$IMPACT_SSHD_CONFIG does not read $IMPACT_SSH_RULES_FILE before its first Match line, so the IMPACT rules have no effect." \
            "Add this line near the top of $IMPACT_SSHD_CONFIG, above any line that starts with Match:  Include $IMPACT_SSH_RULES_DIR/*.conf"
    fi

    impact_check_entry_facts "$IMPACT_SSH_RULES_FILE"
    case "$IMPACT_CHECK_E_TYPE" in
        missing)
            if [[ "$IMPACT_CHECK_CONF_STATE" == 'ok' ]]; then
                impact_check_fail "The SSH rules file $IMPACT_SSH_RULES_FILE does not exist: members of '$group' can log in with a password and forward to any port." \
                    "Write it with its safety checks: sudo impact-workstation-setup"
            else
                impact_check_info "The SSH rules file $IMPACT_SSH_RULES_FILE does not exist yet; impact-workstation-setup writes it."
            fi
            ;;
        file)
            rules_present=1
            if [[ "$IMPACT_CHECK_E_OWNER" != 'root' ]] || impact_check_mode_writable_by_others "$IMPACT_CHECK_E_MODE"; then
                impact_check_fail "$IMPACT_SSH_RULES_FILE can be changed by an account other than root (owner $IMPACT_CHECK_E_OWNER, mode $IMPACT_CHECK_E_MODE)." \
                    "Give the rules file back to root: sudo chown root:root $IMPACT_SSH_RULES_FILE && sudo chmod 644 $IMPACT_SSH_RULES_FILE"
            fi
            # cmp compares the file with the text that the setup writes; the
            # text arrives through "<( ... )", a temporary name for the
            # output of a command ("process substitution").
            if cmp -s -- "$IMPACT_SSH_RULES_FILE" <(impact_ssh_rules_content "$group" "$min" "$max" 2>/dev/null); then
                impact_check_ok "$IMPACT_SSH_RULES_FILE is exactly what impact-workstation-setup writes for the group '$group' and the ports $min to $max."
            else
                impact_check_warn "$IMPACT_SSH_RULES_FILE differs from what impact-workstation-setup writes for the group '$group' and the ports $min to $max (changed by hand, or the settings changed since)." \
                    "Write the rules file again with its safety checks: sudo impact-workstation-setup"
            fi
            ;;
        *)
            impact_check_fail "$IMPACT_SSH_RULES_FILE is a $IMPACT_CHECK_E_TYPE, not a plain file." \
                "Look at it (ls -l $IMPACT_SSH_RULES_FILE), move it away, and write the rules again: sudo impact-workstation-setup"
            ;;
    esac
    shopt -s nullglob
    for file in "$IMPACT_SSH_RULES_DIR"/*.conf; do
        if [[ "$file" != "$IMPACT_SSH_RULES_FILE" ]]; then
            others+=("$(basename -- "$file")")
        fi
    done
    shopt -u nullglob
    if ((${#others[@]} > 0)); then
        impact_check_info "Further rule files in $IMPACT_SSH_RULES_DIR: ${others[*]}."
    fi

    if ! impact_ssh_runtime_dir_ready; then
        impact_check_warn "The folder /run/sshd is missing, so sshd cannot be asked which settings apply to whom." \
            "Start the SSH service once (sudo systemctl start ssh); it creates the folder. Then run sudo impact-check again."
        return 0
    fi
    if ! impact_ssh_config_test; then
        impact_check_fail "sshd -t reports an error in the SSH configuration: $(impact_display "$(printf '%s' "$IMPACT_SSH_OUTPUT" | head -n 1)")" \
            "Look at the whole message (sudo sshd -t) and correct the file it names. If it is $IMPACT_SSH_RULES_FILE: sudo impact-workstation-setup --remove-ssh-rules"
        return 0
    fi
    impact_check_ok "sshd -t: the SSH configuration is free of errors."

    mapfile -t members < <(impact_check_members)
    if ((rules_present == 1)); then
        if ((${#members[@]} == 0)); then
            impact_check_info "The group '$group' has no member yet; the rules are checked for each member once there is one."
        fi
        for member in "${members[@]}"; do
            status=0
            deviations="$(impact_ssh_member_deviations "$member" "$min" "$max")" || status=$?
            case "$status" in
                0) good=$((good + 1)) ;;
                1)
                    impact_check_fail "The member '$member' does not get the restricted SSH settings:" \
                        "Look at the rule files in $IMPACT_SSH_RULES_DIR and in $IMPACT_SSHD_CONFIG for lines that apply to '$member' first; then write the rules again: sudo impact-workstation-setup"
                    printf '%s\n' "$deviations"
                    ;;
                *)
                    impact_check_warn "sshd could not be asked for the settings of the member '$member'." \
                        "Ask sshd by hand: sudo sshd -T -C user=$member,host=127.0.0.1,addr=127.0.0.1"
                    ;;
            esac
        done
        if ((good > 0)); then
            impact_check_ok "$good of ${#members[@]} members get the restricted SSH settings (key only, forwarding to the ports $min to $max only)."
        fi
    fi

    admin="$(impact_invoking_account)"
    address="$(impact_ssh_client_address)"
    if ((rules_present == 1)); then
        impact_check__admin_unchanged "$admin" "$address"
        if [[ "$admin" != 'root' ]]; then
            impact_check__admin_unchanged root 127.0.0.1
        fi
    fi
    local settings
    if settings="$(impact_check__sshd_settings "$admin" "$address")"; then
        impact_check_info "Effective settings of '$admin' for a login from $address: $(printf '%s\n' "$settings" |
            awk '$1 == "passwordauthentication" || $1 == "pubkeyauthentication" || $1 == "authenticationmethods" || $1 == "allowtcpforwarding" { printf "%s%s %s", sep, $1, $2; sep = ", " }')."
    fi
}

# =============================================================================
# Block 6: Groups
# =============================================================================

# impact_check_block_groups
#   The shared group, the group docker and the administrators' groups, and
#   who is a member of which.
impact_check_block_groups() {
    local group="${IMPACT_CONF[SHARED_GROUP]}" admin gid member name
    local -a members=() docker_members=() admins=() no_docker=() with_sudo=() docker_only=()
    impact_check_note_guess
    admin="$(impact_invoking_account)"
    mapfile -t members < <(impact_check_members)
    if impact_group_exists "$group"; then
        gid="$(impact_group_gid "$group")"
        if ((gid < 1000)); then
            impact_check_fail "The group '$group' has the number $gid. Numbers below 1000 belong to the system; a system group must not be the shared group." \
                "Choose another group: sudo impact-workstation-setup --shared-group <name> (only while it has no members)."
        elif impact_account_exists "$group"; then
            impact_check_fail "'$group' is also the name of an account, so the shared group is that account's personal group." \
                "Choose another group: sudo impact-workstation-setup --shared-group <name> (only while it has no members)."
        else
            impact_check_ok "The group '$group' exists (number $gid) with ${#members[@]} members${members[0]:+: ${members[*]}}."
        fi
    elif [[ "$IMPACT_CHECK_CONF_STATE" == 'ok' ]]; then
        impact_check_fail "The shared group '$group' does not exist." \
            "impact-workstation-setup creates it: sudo impact-workstation-setup"
    else
        impact_check_info "The group '$group' does not exist yet; impact-workstation-setup creates it."
    fi
    for member in "${members[@]}"; do
        if [[ "$member" == "$admin" || "$member" == 'root' ]]; then
            impact_check_fail "The account '$member' that administers the workstation is a member of '$group'. The SSH rules restrict its own login (key only, no password)." \
                "Take $member out of the group, and keep a second session open while you do it: sudo gpasswd -d $member $group"
        fi
    done

    if impact_group_exists docker; then
        mapfile -t docker_members < <(impact_group_members docker || true)
        impact_check_info "Members of the group docker: ${docker_members[*]:-none}. Membership in docker equals root rights on this machine."
        for member in "${members[@]}"; do
            # An unfinished enrolment is reported in block 7; the command
            # that continues it adds the group docker.
            if ! impact_in_list "$member" "${docker_members[@]}" && ! impact_check__enrolment_unfinished "$member"; then
                no_docker+=("$member")
            fi
        done
        for member in "${docker_members[@]}"; do
            if ! impact_in_list "$member" "${members[@]}" && [[ "$member" != "$admin" && "$member" != 'root' ]]; then
                docker_only+=("$member")
            fi
        done
        if ((${#docker_only[@]} > 0)); then
            impact_check_info "In docker but not in '$group': ${docker_only[*]}."
        fi
    else
        no_docker=("${members[@]}")
    fi
    if ((${#no_docker[@]} > 0)); then
        impact_check_warn "These members of '$group' are no members of docker and cannot start containers: ${no_docker[*]}." \
            "Add each of these members to docker: sudo usermod --append --groups docker <account>"
    fi

    for name in sudo admin wheel; do
        if impact_group_exists "$name"; then
            mapfile -t admins < <(impact_group_members "$name" || true)
            if ((${#admins[@]} > 0)); then
                impact_check_info "Members of the group $name (may use sudo): ${admins[*]}."
            fi
            for member in "${members[@]}"; do
                if impact_in_list "$member" "${admins[@]}"; then
                    with_sudo+=("$member ($name)")
                fi
            done
        fi
    done
    if ((${#with_sudo[@]} > 0)); then
        impact_check_warn "Members of '$group' may use sudo: ${with_sudo[*]}. Colleagues get no sudo." \
            "Take each of these members out of the sudo group: sudo gpasswd -d <account> <group>"
    fi
}

# =============================================================================
# Block 7: Accounts
# =============================================================================

# impact_check__expiry ACCOUNT
#   Internal: prints the expiry date of the account (YYYY-MM-DD) or "never".
#   Needs root rights (it reads the shadow database, but only field 8, the
#   expiry day; the password hash in field 2 is never read into a variable).
impact_check__expiry() {
    local days
    days="$(getent shadow -- "$1" 2>/dev/null | cut -d: -f8)" || days=''
    if [[ "$days" =~ ^[0-9]{1,6}$ ]]; then
        date -u -d "@$((days * 86400))" '+%Y-%m-%d' 2>/dev/null || printf 'day %s' "$days"
    else
        printf 'never'
    fi
}

# impact_check_block_accounts
#   Every account of a person: numbers, groups, password state, expiry,
#   rights of the home folder and of .ssh, login keys, key copy, size of the
#   home folder. Also accounts with root's number, user numbers used twice,
#   records of deleted accounts, and enrolments that impact-add-user did not
#   finish (one warning each, with the way to continue).
impact_check_block_accounts() {
    local name number other
    local -a accounts=() records=() duplicates=() root_like=()
    impact_check_note_guess
    mapfile -t root_like < <(getent passwd | awk -F: '$3 == 0 && $1 != "root" { print $1 }')
    if ((${#root_like[@]} > 0)); then
        impact_check_fail "Accounts other than root have the user number 0 and therefore root rights: ${root_like[*]}." \
            "Look at each of them at once: sudo getent passwd <account>"
    fi
    mapfile -t duplicates < <(getent passwd | awk -F: '{ print $3 }' | LC_ALL=C sort | uniq -d)
    if ((${#duplicates[@]} > 0)); then
        impact_check_warn "These user numbers belong to more than one account: ${duplicates[*]}. Files on the storage cannot tell such accounts apart." \
            "Look at them: getent passwd | awk -F: '\$3 == <number>'"
    fi
    mapfile -t records < <(impact_account_records)
    for name in "${records[@]}"; do
        if impact_account_exists "$name"; then
            continue
        fi
        number=''
        if impact_account_record_load "$name" >/dev/null 2>&1; then
            number="${IMPACT_ACCOUNT_RECORD[USER_NUMBER]}"
        fi
        impact_check_info "Account record without account: '$name' (deleted; user number ${number:-unknown})."
        if [[ -n "$number" ]] && other="$(impact_account_by_uid "$number")"; then
            impact_check_warn "The user number $number of the deleted account '$name' now belongs to '$other'. Files of '$name' on the storage belong to '$other' now." \
                "Look at the files on the storage that belong to $number before '$other' uses them: sudo find <storage root> -xdev -uid $number"
        fi
    done
    # The range is read here, in this copy of the script: the list below is
    # made in a further copy ("< <( ... )"), whose variables are lost.
    impact_check_uid_range
    mapfile -t accounts < <(impact_check_people_accounts)
    if ((${#accounts[@]} == 0)); then
        impact_check_ok "There is no account of a person yet."
        return 0
    fi
    impact_check_info "Accounts of people (user numbers $IMPACT_CHECK_UID_MIN to $IMPACT_CHECK_UID_MAX, members of '${IMPACT_CONF[SHARED_GROUP]}', enrolled accounts): ${#accounts[@]}."
    local -a service=()
    for name in "${accounts[@]}"; do
        # An account without a login shell that has nothing to do with
        # IMPACT is a service account (for example of a build tool); one
        # summary line is enough for those.
        if impact_check__is_service_account "$name"; then
            service+=("$name")
            continue
        fi
        impact_check__account "$name"
    done
    impact_check__shared_keys "${accounts[@]}"
    if ((${#service[@]} > 0)); then
        impact_check_info "Further accounts in that range without a login shell (service accounts, not looked at further): ${#service[@]}: ${service[*]:0:12}${service[12]:+ ...}."
    fi
}

# impact_check__shared_keys ACCOUNT...
#   Internal: one key pair belongs to one person. Warns for every login key
#   (by its fingerprint) that more than one of the accounts has: whoever
#   holds the private key can log in to each of them. The keys are read
#   with the rights of each person.
impact_check__shared_keys() {
    local account home text print
    local -A owners=()
    for account in "$@"; do
        home="$(impact_account_home "$account" 2>/dev/null)" || continue
        impact_valid_abs_path "$home" || continue
        text="$(impact_user_read_file "$account" "$home/.ssh/authorized_keys" 2>/dev/null)" || continue
        [[ -n "$text" ]] || continue
        # ssh-keygen -l lists the fingerprint of every key line of the text
        # (the second word of each line).
        while IFS= read -r print; do
            [[ "$print" == SHA256:* ]] || continue
            if [[ " ${owners[$print]:-} " != *" $account "* ]]; then
                owners[$print]="${owners[$print]:+${owners[$print]} }$account"
            fi
        done < <(ssh-keygen -l -E sha256 -f /dev/stdin <<<"$text" 2>/dev/null | awk '{ print $2 }')
    done
    for print in "${!owners[@]}"; do
        if [[ "${owners[$print]}" == *' '* ]]; then
            impact_check_warn "The login key $print belongs to more than one account: ${owners[$print]}. One key pair belongs to one person; whoever holds this key can log in to each of these accounts." \
                "Ask whose key it is, and remove it from the other accounts: sudo impact-key remove <account> --fingerprint $print"
        fi
    done
}

# impact_check__is_service_account ACCOUNT
#   Internal: success when ACCOUNT has no login shell, is no member of the
#   shared group and has no IMPACT account record.
impact_check__is_service_account() {
    local shell
    shell="$(impact_account_shell "$1")" || return 1
    case "$shell" in
        */nologin | */false | '') ;;
        *) return 1 ;;
    esac
    ! impact_account_in_group "$1" "${IMPACT_CONF[SHARED_GROUP]}" && [[ ! -e "$(impact_account_record_file "$1")" ]]
}

# impact_check__account ACCOUNT
#   Internal part of block 7: the facts and checks of one account.
impact_check__account() {
    local account="$1" group="${IMPACT_CONF[SHARED_GROUP]}" admin
    local uid gid home shell groups password expiry role record_state=0 github=''
    admin="$(impact_invoking_account)"
    uid="$(impact_account_uid "$account")" || return 0
    gid="$(impact_account_gid "$account")" || gid='?'
    home="$(impact_account_home "$account")" || home=''
    shell="$(impact_account_shell "$account")" || shell=''
    groups="$(impact_account_groups "$account" | tr '\n' ' ')" || groups=''
    password="$(impact_account_password_state "$account")" || password='?'
    expiry="$(impact_check__expiry "$account")"
    impact_account_record_load "$account" >/dev/null 2>&1 || record_state=$?
    if ((record_state == 0)); then
        github="${IMPACT_ACCOUNT_RECORD[GITHUB_NAME]}"
    fi
    if ((record_state == 0)) && [[ "${IMPACT_ACCOUNT_RECORD[STATE]}" == 'enrolling' ]]; then
        # impact-add-user created the account and stopped before its end.
        role='enrolling'
    elif impact_account_in_group "$account" "$group"; then
        role='member'
    elif ((record_state == 0)) && [[ "${IMPACT_ACCOUNT_RECORD[STATE]}" == 'removed' ]]; then
        role='removed'
    elif [[ "$account" == "$admin" ]]; then
        role='administrator'
    else
        role='other'
    fi
    case "$password" in
        L) password='locked' ;;
        P) password='usable' ;;
        NP) password='none needed' ;;
        *) password='unknown' ;;
    esac
    local role_text
    case "$role" in
        member) role_text="member of '$group'" ;;
        removed) role_text='removed with impact-remove-user' ;;
        enrolling) role_text='enrolment not finished (impact-add-user stopped early)' ;;
        administrator) role_text='the account that runs this check' ;;
        *) role_text="no member of '$group'" ;;
    esac
    impact_check_info "Account $account: user number $uid, group number $gid, $role_text${github:+, GitHub name $github}."
    impact_check_info "  groups: ${groups% }; shell: $(impact_display "$shell"); password: $password; expiry: $expiry."

    # The password and shell rules of a member apply as well to an account
    # whose enrolment is not finished.
    if [[ "$role" == 'member' || "$role" == 'enrolling' ]]; then
        if ((record_state == 1)); then
            impact_check_warn "$account is a member of '$group' without an IMPACT account record, so the commands do not know its GitHub name." \
                "Enrol $account with its GitHub name: sudo impact-add-user <github-name> --account $account --existing"
        elif ((record_state == 2)); then
            impact_check_warn "The account record of $account is invalid: ${IMPACT_ACCOUNT_RECORD_ERRORS[*]}" \
                "Enrol $account again: sudo impact-add-user <github-name> --account $account --existing"
        fi
        if [[ "$password" != 'locked' ]]; then
            impact_check_warn "$account has a password that is not locked ($password). Colleagues log in with their key only." \
                "Lock the password of $account: sudo passwd --lock $account"
        fi
        if [[ "$role" == 'member' ]] && impact_account_is_expired "$account"; then
            impact_check_warn "$account is expired but still a member of '$group'." \
                "Finish the removal (sudo impact-remove-user $account) or bring the person back (see the help of impact-remove-user)."
        fi
        case "$shell" in
            */nologin | */false | '')
                impact_check_warn "$account has no login shell ($(impact_display "${shell:-none}")); the GUI needs one." \
                    "Give $account the shell bash: sudo usermod --shell /bin/bash $account"
                ;;
            *) ;;
        esac
    elif [[ "$role" == 'removed' ]]; then
        if impact_account_is_expired "$account"; then
            impact_check_ok "$account is closed (expired) and kept, so its user number is never used again."
        else
            impact_check_warn "$account was removed but is not expired, so it could still log in." \
                "Run the removal again: sudo impact-remove-user $account"
        fi
        if [[ " $groups " == *" docker "* ]]; then
            impact_check_warn "The removed account $account is still a member of docker." \
                "Run the removal again: sudo impact-remove-user $account"
        fi
    fi
    # The counts of login keys are set by impact_check__account_home when
    # it can read them; 0 when it cannot.
    IMPACT_CHECK_KEYS_ED25519=0
    IMPACT_CHECK_KEYS_OTHER=0
    impact_check__account_home "$account" "$role" "$home" "$github"
    if [[ "$role" == 'enrolling' ]]; then
        impact_check__enrolment_warning "$account" "$groups"
    fi
}

# impact_check__enrolment_warning ACCOUNT GROUPS
#   Internal part of block 7: the one warning for an account whose
#   enrolment is not finished. It says what the account has already (the
#   groups, login keys) and names the two ways on: run the same
#   impact-add-user command again, or close the account. The advice for a
#   finished member (add a key with impact-key, create folders by hand)
#   does not fit: impact-key refuses such an account, and impact-add-user
#   does these steps itself when it continues. GROUPS is the list of the
#   account's groups, separated by blanks.
impact_check__enrolment_warning() {
    local account="$1" groups=" $2 " group="${IMPACT_CONF[SHARED_GROUP]}" text
    text="The enrolment of $account is not finished (impact-add-user stopped early)."
    if [[ "$groups" == *" docker "* ]]; then
        text+=" The account is a member of docker (root rights on this machine) and has no confirmed SSH restriction."
    elif [[ "$groups" == *" $group "* ]]; then
        text+=" The account is a member of '$group' and has no confirmed SSH restriction."
    fi
    if ((IMPACT_CHECK_KEYS_ED25519 + IMPACT_CHECK_KEYS_OTHER > 0)); then
        text+=" It has login keys, so it can log in."
    else
        text+=" It has no login key, so it cannot log in yet."
    fi
    impact_check_warn "$text" \
        "Run the same impact-add-user command again (it checks every part and does the missing steps), or close the account: sudo impact-remove-user $account"
}

# impact_check__account_home ACCOUNT ROLE HOME GITHUB_NAME
#   Internal part of block 7: home folder, .ssh, login keys, key copy and
#   the size of the home folder. Files inside the home folder are read with
#   the rights of the person (impact_user_read_file, impact_run_as), so a
#   symbolic link that the person placed there can never make root read
#   another file.
impact_check__account_home() {
    local account="$1" role="$2" home="$3" github="$4" status keys_text size copy fingerprint public
    local strict=0
    # For members the SSH server's strict checks matter: it refuses key
    # logins when the home folder or .ssh can be changed by others.
    if [[ "$role" == 'member' ]]; then
        strict=1
    fi
    if [[ -z "$home" ]] || ! impact_valid_abs_path "$home" || [[ "$home" == '/' ]]; then
        impact_check_info "  home folder: $(impact_display "${home:-none}") (no usable path)."
        return 0
    fi
    impact_check_entry_facts "$home"
    if [[ "$IMPACT_CHECK_E_TYPE" != 'folder' ]]; then
        if ((strict == 1)); then
            impact_check_fail "The home folder $home of $account is a $IMPACT_CHECK_E_TYPE, not a real folder." \
                "Create the home folder for the person (sudo mkhomedir_helper $account), or look at it: ls -ld $home"
        else
            impact_check_info "  home folder: $home ($IMPACT_CHECK_E_TYPE)."
        fi
        return 0
    fi
    local home_text="home folder $home: owner $IMPACT_CHECK_E_OWNER, group $IMPACT_CHECK_E_GROUP, mode $IMPACT_CHECK_E_MODE"
    if [[ "$IMPACT_CHECK_E_OWNER" != "$account" ]] || impact_check_mode_writable_by_others "$IMPACT_CHECK_E_MODE"; then
        if ((strict == 1)); then
            impact_check_fail "The $home_text. It must belong to $account and only $account may write in it; otherwise the SSH server refuses the key login." \
                "Correct the rights: sudo chown $account $home && sudo chmod go-w $home"
        else
            impact_check_info "  $home_text."
        fi
        return 0
    fi
    impact_check_info "  $home_text."

    impact_check_entry_facts "$home/.ssh"
    case "$IMPACT_CHECK_E_TYPE" in
        missing)
            if ((strict == 1)); then
                impact_check_warn "$account has no folder $home/.ssh, so no login key." \
                    "Add the person's key: sudo impact-key add $account"
            else
                impact_check_info "  no folder .ssh."
            fi
            impact_check__home_size "$account" "$home"
            return 0
            ;;
        folder)
            if [[ "$IMPACT_CHECK_E_OWNER" != "$account" ]] || impact_check_mode_writable_by_others "$IMPACT_CHECK_E_MODE"; then
                impact_check_fail "$home/.ssh belongs to $IMPACT_CHECK_E_OWNER with mode $IMPACT_CHECK_E_MODE. It must belong to $account, and only $account may write in it." \
                    "Correct the rights: sudo chown $account $home/.ssh && sudo chmod 700 $home/.ssh"
                impact_check__home_size "$account" "$home"
                return 0
            fi
            impact_check_info "  .ssh: owner $IMPACT_CHECK_E_OWNER, mode $IMPACT_CHECK_E_MODE."
            ;;
        *)
            impact_check_fail "$home/.ssh of $account is a $IMPACT_CHECK_E_TYPE, not a real folder." \
                "Look at it (ls -l $home/.ssh) and replace it by a folder of the person."
            impact_check__home_size "$account" "$home"
            return 0
            ;;
    esac

    status=0
    keys_text="$(impact_user_read_file "$account" "$home/.ssh/authorized_keys" 2>/dev/null)" || status=$?
    case "$status" in
        0)
            impact_check_count_keys "$keys_text"
            keys_text=''
            impact_check_entry_facts "$home/.ssh/authorized_keys"
            if impact_check_mode_writable_by_others "$IMPACT_CHECK_E_MODE"; then
                impact_check_fail "$home/.ssh/authorized_keys has mode $IMPACT_CHECK_E_MODE: others can change the login keys of $account." \
                    "Correct the rights: sudo chmod 600 $home/.ssh/authorized_keys"
            fi
            ;;
        4)
            IMPACT_CHECK_KEYS_ED25519=0
            IMPACT_CHECK_KEYS_OTHER=0
            IMPACT_CHECK_KEY_FPS=()
            ;;
        *)
            IMPACT_CHECK_KEYS_ED25519=0
            IMPACT_CHECK_KEYS_OTHER=0
            IMPACT_CHECK_KEY_FPS=()
            if ((strict == 1)); then
                impact_check_fail "$home/.ssh/authorized_keys of $account cannot be read as $account (a symbolic link, or a file of another account)." \
                    "Look at the file: sudo ls -l $home/.ssh/authorized_keys"
            fi
            ;;
    esac
    if ((IMPACT_CHECK_KEYS_OTHER > 0)); then
        impact_check_info "  login keys: $IMPACT_CHECK_KEYS_ED25519 of the type ed25519, and $IMPACT_CHECK_KEYS_OTHER other lines."
    else
        impact_check_info "  login keys: $IMPACT_CHECK_KEYS_ED25519 of the type ed25519."
    fi
    case "$role" in
        member)
            if ((IMPACT_CHECK_KEYS_ED25519 == 0)); then
                impact_check_warn "$account has no ed25519 login key and cannot log in." \
                    "Add the person's key: sudo impact-key add $account"
            fi
            if ((IMPACT_CHECK_KEYS_OTHER > 0)); then
                impact_check_warn "$home/.ssh/authorized_keys of $account has $IMPACT_CHECK_KEYS_OTHER lines that are no plain ed25519 key (another key type, or options in front of the key)." \
                    "Look at the keys: sudo impact-key list $account"
            fi
            ;;
        removed)
            if ((IMPACT_CHECK_KEYS_ED25519 + IMPACT_CHECK_KEYS_OTHER > 0)); then
                impact_check_warn "The removed account $account still has login keys." \
                    "Run the removal again: sudo impact-remove-user $account"
            fi
            ;;
        *) ;;
    esac

    # The key copy: the private key that the GUI copies to the workstation
    # for git. It is never read by root; ssh-keygen runs as the person and
    # derives the public key, whose fingerprint is compared with the login
    # keys.
    if [[ -n "$github" ]]; then
        copy="$(impact_key_copy_path "$home" "$github")"
        status=0
        impact_user_file_exists "$account" "$copy" 2>/dev/null || status=$?
        case "$status" in
            0)
                if [[ "$role" == 'removed' ]]; then
                    impact_check_warn "The private key copy $copy of the removed account $account still exists." \
                        "Run the removal again: sudo impact-remove-user $account"
                else
                    impact_check_entry_facts "$copy"
                    if [[ "$IMPACT_CHECK_E_MODE" != '600' && "$IMPACT_CHECK_E_MODE" != '400' ]]; then
                        impact_check_warn "The key copy $copy has mode $IMPACT_CHECK_E_MODE; git refuses a private key that others can read." \
                            "Correct the rights: sudo chmod 600 $copy"
                    fi
                    public="$(impact_run_as "$account" timeout 20 ssh-keygen -y -P '' -f "$copy" </dev/null 2>/dev/null)" || public=''
                    # Only the first two words (type and key data) count.
                    read -r public fingerprint _ <<<"$public" || true
                    fingerprint="$(impact_key_fingerprint "$public $fingerprint" 2>/dev/null)" || fingerprint=''
                    public=''
                    if [[ -z "$fingerprint" ]]; then
                        impact_check_warn "The key copy $copy cannot be read without a passphrase (or is damaged), so git in the container cannot use it." \
                            "The GUI copies the key again at the next remote start; the person can also use \"Renew key\"."
                    elif impact_in_list "$fingerprint" "${IMPACT_CHECK_KEY_FPS[@]}"; then
                        impact_check_ok "$account: the key copy $copy belongs to a login key ($fingerprint)."
                    else
                        impact_check_warn "The key copy $copy of $account ($fingerprint) belongs to none of its login keys (an old key?)." \
                            "The GUI replaces the copy at the next remote start from the PC in use; check the keys with: sudo impact-key list $account"
                    fi
                fi
                ;;
            4)
                if [[ "$role" == 'member' ]]; then
                    impact_check_info "  key copy $copy: not there yet (the GUI copies it at the first remote start)."
                fi
                ;;
            *)
                impact_check_fail "$copy of $account is no plain file of $account (a symbolic link or a file of another account)." \
                    "Look at it (sudo ls -l $copy) and remove it; the GUI copies the key again at the next remote start."
                ;;
        esac
    fi
    if [[ "$role" != 'member' && "$role" != 'removed' ]]; then
        local -a copies=()
        mapfile -t copies < <(impact_run_as "$account" find "$home/.ssh" -maxdepth 1 -type f -name 'id_ed25519_*' ! -name '*.pub' -printf '%f\n' 2>/dev/null | head -n 50 || true)
        if ((${#copies[@]} > 0)); then
            impact_check_info "  private key files id_ed25519_* in .ssh: ${#copies[@]}."
        fi
    fi
    impact_check__home_size "$account" "$home"
}

# impact_check__home_size ACCOUNT HOME
#   Internal part of block 7: the size of a home folder. "du" adds up the
#   sizes of all files; -s one total, -x stay on this file system, -k in
#   KB. It runs as root (it reads folder listings only, never file
#   contents, and follows no symbolic link) with a time limit.
impact_check__home_size() {
    local size
    # "|| true": du reports a failure when it could not read one folder; the
    # total it printed is still useful.
    size="$(timeout "$IMPACT_CHECK_DU_SECONDS" du -sxk -- "$2" 2>/dev/null | cut -f1)" || true
    if [[ "$size" =~ ^[0-9]+$ ]]; then
        impact_check_info "  size of the home folder: $(impact_check_size_text "$((size * 1024))")."
    else
        impact_check_info "  size of the home folder: not measured within $IMPACT_CHECK_DU_SECONDS seconds. Measure it by hand at a quiet moment: sudo du -sxh $2"
    fi
}

# =============================================================================
# Block 8: Models and extras
# =============================================================================

# impact_check__list_names FOLDER [AS_ACCOUNT]
#   Internal: prints the names of the entries directly inside FOLDER, each
#   ended by a zero byte, at most IMPACT_CHECK_LIST_LIMIT of them. With
#   AS_ACCOUNT the listing runs with the rights of that person (for folders
#   inside a home folder). The names are never followed by a walk.
impact_check__list_names() {
    local -a runner=()
    if [[ -n "${2:-}" ]]; then
        runner=(impact_run_as "$2")
    fi
    # find -mindepth 1 -maxdepth 1 lists the entries of one folder only;
    # "%f" is the name without the path, "\0" ends it with a zero byte.
    # "head -z" keeps the first entries of such a list.
    "${runner[@]}" timeout 60 find "$1" -mindepth 1 -maxdepth 1 -printf '%f\0' 2>/dev/null |
        head -z -n "$IMPACT_CHECK_LIST_LIMIT" || true
}

# impact_check_block_models
#   MODEL_DIR, every model folder with its model.conf, and the extras.
impact_check_block_models() {
    local dir="${IMPACT_CONF[MODEL_DIR]}" group="${IMPACT_CONF[SHARED_GROUP]}" name
    local -a names=()
    impact_check_note_guess
    impact_check_entry_facts "$dir"
    case "$IMPACT_CHECK_E_TYPE" in
        missing)
            if [[ "$IMPACT_CHECK_CONF_STATE" == 'ok' ]]; then
                impact_check_fail "The model folder MODEL_DIR=$dir does not exist." \
                    "impact-workstation-setup creates it: sudo impact-workstation-setup"
            else
                impact_check_info "The model folder $dir does not exist yet; impact-workstation-setup creates it."
            fi
            return 0
            ;;
        folder)
            if impact_dir_is "$dir" 2750 root "$group"; then
                impact_check_ok "The model folder $dir belongs to root and the group '$group' (mode 2750)."
            else
                impact_check_warn "The model folder $dir has owner $IMPACT_CHECK_E_OWNER, group $IMPACT_CHECK_E_GROUP, mode $IMPACT_CHECK_E_MODE; expected root, '$group', 2750." \
                    "Correct the rights: sudo chown root:$group $dir && sudo chmod 2750 $dir"
            fi
            ;;
        *)
            impact_check_fail "MODEL_DIR=$dir is a $IMPACT_CHECK_E_TYPE, not a real folder." \
                "Look at it (ls -ld $dir), move it away, and run sudo impact-workstation-setup."
            return 0
            ;;
    esac
    # "mapfile -d ''" reads entries ended by zero bytes into a list.
    mapfile -d '' -t names < <(impact_check__list_names "$dir")
    if ((${#names[@]} == 0)); then
        impact_check_ok "No model is registered yet. Register one with: sudo impact-add-model <model> <GitHub address> --storage <root> --storage-name <name>"
        return 0
    fi
    for name in "${names[@]}"; do
        impact_check__model "$name"
    done
}

# impact_check__model NAME
#   Internal part of block 8: one entry of MODEL_DIR.
impact_check__model() {
    local name="$1" dir="${IMPACT_CONF[MODEL_DIR]}" group="${IMPACT_CONF[SHARED_GROUP]}" path status=0 text
    path="$dir/$name"
    if ! impact_valid_model_name "$name"; then
        impact_check_warn "'$(impact_display "$name")' in $dir is no valid model name; the commands ignore it." \
            "Look at it (sudo ls -la $dir) and rename or remove it."
        return 0
    fi
    impact_check_entry_facts "$path"
    if [[ "$IMPACT_CHECK_E_TYPE" != 'folder' ]]; then
        impact_check_warn "$path is a $IMPACT_CHECK_E_TYPE, not a model folder; the commands refuse it." \
            "Look at it (sudo ls -la $dir) and remove it, or register the model again: sudo impact-add-model $name ..."
        return 0
    fi
    impact_model_load "$name" || status=$?
    case "$status" in
        0)
            impact_check_ok "Model $name: repository ${IMPACT_MODEL[REPO_URL]}, branch ${IMPACT_MODEL[BRANCH]:-(the default branch)}, storage folder ${IMPACT_MODEL[STORAGE_NAME]} on ${IMPACT_MODEL[STORAGE_ROOTS]}."
            ;;
        1)
            impact_check_warn "The folder $path has no model.conf, so it is no registered model." \
                "Register it: sudo impact-add-model $name <GitHub address> --storage <root> --storage-name <name>, or remove the folder."
            return 0
            ;;
        *)
            for text in "${IMPACT_MODEL_ERRORS[@]}"; do
                impact_check_fail "$path/model.conf: $text" \
                    "Correct the file named above (sudo nano $path/model.conf) or register the model again with sudo impact-add-model."
            done
            ;;
    esac
    for text in "${IMPACT_MODEL_WARNINGS[@]}"; do
        impact_check_warn "$path/model.conf: $text" \
            "Remove the unknown line with an editor (sudo nano $path/model.conf)."
    done
    if ! impact_dir_is "$path" 2750 root "$group"; then
        impact_check_warn "$path has owner $IMPACT_CHECK_E_OWNER, group $IMPACT_CHECK_E_GROUP, mode $IMPACT_CHECK_E_MODE; expected root, '$group', 2750." \
            "Correct the rights: sudo chown root:$group $path && sudo chmod 2750 $path"
    fi
    if [[ -e "$path/model.conf" ]] && ! impact_file_is "$path/model.conf" 640 root "$group"; then
        impact_check_entry_facts "$path/model.conf"
        impact_check_warn "$path/model.conf has owner $IMPACT_CHECK_E_OWNER, group $IMPACT_CHECK_E_GROUP, mode $IMPACT_CHECK_E_MODE; expected root, '$group', 640." \
            "Correct the rights: sudo chown root:$group $path/model.conf && sudo chmod 640 $path/model.conf"
    fi
    impact_check__extras "$name" "$path/extras"
}

# impact_check__extras MODEL EXTRAS_FOLDER
#   Internal part of block 8: the extras of a model (files that are not on
#   GitHub, copied into every working copy). Folders 2750, files 640, owner
#   root, group = shared group; only plain files and folders.
impact_check__extras() {
    local model="$1" extras="$2" group="${IMPACT_CONF[SHARED_GROUP]}" entry kind owner grp mode size relative
    local files=0 bytes=0 wrong=0 odd=0 large=0
    local -a odd_names=()
    impact_check_entry_facts "$extras"
    case "$IMPACT_CHECK_E_TYPE" in
        missing)
            impact_check_warn "The model $model has no folder extras/." \
                "Create the extras folder empty: sudo install -d -m 2750 -o root -g $group $extras"
            return 0
            ;;
        folder) ;;
        *)
            impact_check_warn "$extras is a $IMPACT_CHECK_E_TYPE, not a folder; impact-get-repo refuses it." \
                "Replace it by a real folder: sudo install -d -m 2750 -o root -g $group <folder>"
            return 0
            ;;
    esac
    if ! impact_dir_is "$extras" 2750 root "$group"; then
        wrong=$((wrong + 1))
    fi
    # One line per entry below the extras folder: kind (%y: d folder, f
    # file, l link), owner, group, mode, size in bytes, path below the
    # folder. -xdev stays on one file system; symbolic links are listed,
    # never followed.
    while IFS= read -r -d '' entry; do
        IFS='|' read -r kind owner grp mode size relative <<<"$entry" || true
        case "$kind" in
            f)
                files=$((files + 1))
                [[ "$size" =~ ^[0-9]+$ ]] && bytes=$((bytes + size))
                if ((size > 52428800)); then
                    large=$((large + 1))
                fi
                if [[ "$owner|$grp|$mode" != "root|$group|640" ]]; then
                    wrong=$((wrong + 1))
                fi
                ;;
            d)
                if [[ "$owner|$grp|$mode" != "root|$group|2750" ]]; then
                    wrong=$((wrong + 1))
                fi
                ;;
            *)
                odd=$((odd + 1))
                if ((${#odd_names[@]} < 3)); then
                    odd_names+=("$(impact_display "$relative")")
                fi
                ;;
        esac
    done < <(timeout 60 find "$extras" -xdev -mindepth 1 -printf '%y|%u|%g|%m|%s|%P\0' 2>/dev/null | head -z -n 10000 || true)
    impact_check_info "  extras of $model: $files files, $(impact_check_size_text "$bytes")."
    if ((large > 0)); then
        impact_check_info "  $large extras are larger than 50 MB; impact-check-model $model lists them."
    fi
    if ((odd > 0)); then
        impact_check_warn "The extras of $model contain $odd entries that are neither plain files nor folders (for example symbolic links): ${odd_names[*]}." \
            "Replace such entries by plain files; list them with: sudo ls -laR $extras"
    fi
    if ((wrong > 0)); then
        impact_check_warn "$wrong entries in $extras deviate from the rules (owner root, group '$group', folders 2750, files 640)." \
            "Correct the rights: sudo chown -R root:$group $extras && sudo find $extras -type d -exec chmod 2750 {} + && sudo find $extras -type f -exec chmod 640 {} +"
    fi
}

# =============================================================================
# Block 9: Working copies
# =============================================================================

# The script below runs with the rights of the person, inside one working
# copy ($1). It reads the paths of the extras of the model on standard
# input, each ended by a zero byte, and prints for each extra that exists in
# the working copy and breaks the rule a pair "state" and "path", each ended
# by a zero byte: "tracked" (the extra replaces a file that git tracks) or
# "not_ignored" (git would commit it). ":(literal)" makes git read the path
# as it is, without pattern characters.
# shellcheck disable=SC2016
# Reason for SC2016 (no expansion in single quotes): the inner bash expands
# the variables itself.
readonly IMPACT_CHECK_EXTRAS_SCRIPT='
set -u
cd -- "$1" || exit 3
while IFS= read -r -d "" path; do
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        continue
    fi
    if git ls-files --error-unmatch -- ":(literal)$path" >/dev/null 2>&1; then
        printf "tracked\0%s\0" "$path"
    elif ! git check-ignore -q -- "$path" 2>/dev/null; then
        printf "not_ignored\0%s\0" "$path"
    fi
done
'

# impact_check_block_working_copies
#   For every member: the repository folder and each working copy in it:
#   files that git neither tracks nor ignores, and the extras rule.
impact_check_block_working_copies() {
    local member
    local -a members=()
    impact_check_note_guess
    mapfile -t members < <(impact_check_members)
    if ((${#members[@]} == 0)); then
        impact_check_ok "The group '${IMPACT_CONF[SHARED_GROUP]}' has no member yet, so there is no working copy to look at."
        return 0
    fi
    if ! impact_have_tool git; then
        impact_check_warn "git is not installed, so the working copies cannot be examined." \
            "Install git: sudo apt-get install git"
        return 0
    fi
    for member in "${members[@]}"; do
        impact_check__working_copies "$member"
    done
}

# impact_check__working_copies ACCOUNT
#   Internal part of block 9: the repository folder of one person.
impact_check__working_copies() {
    local account="$1" base name copy inside count=0
    local -a names=()
    if impact_check__enrolment_unfinished "$account"; then
        impact_check_info "$account: the enrolment is not finished (see block 7); impact-add-user creates the repository folder when it continues."
        return 0
    fi
    if ! base="$(impact_repo_base_for "$account")"; then
        impact_check_warn "The repository folder of $account cannot be worked out from REPO_BASE=${IMPACT_CONF[REPO_BASE]}." \
            "Look at the home folder of the account (getent passwd $account) and at REPO_BASE."
        return 0
    fi
    impact_check_entry_facts "$base"
    case "$IMPACT_CHECK_E_TYPE" in
        folder) ;;
        missing)
            impact_check_warn "$account has no repository folder $base, so the GUI lists no repository." \
                "Create the folder as the person: sudo -u $account mkdir -p -m 750 $base"
            return 0
            ;;
        *)
            impact_check_warn "The repository folder $base of $account is a $IMPACT_CHECK_E_TYPE, not a real folder; the GUI and the commands refuse it." \
                "Ask the person to replace it by a real folder, or look at it: sudo ls -ld $base"
            return 0
            ;;
    esac
    if [[ "$IMPACT_CHECK_E_OWNER" != "$account" ]] || impact_check_mode_writable_by_others "$IMPACT_CHECK_E_MODE"; then
        impact_check_warn "The repository folder $base has owner $IMPACT_CHECK_E_OWNER and mode $IMPACT_CHECK_E_MODE; it must belong to $account and be writable by $account only." \
            "Correct the rights: sudo chown $account $base && sudo chmod 750 $base"
        return 0
    fi
    mapfile -d '' -t names < <(impact_check__list_names "$base" "$account")
    for name in "${names[@]}"; do
        copy="$base/$name"
        if [[ "$name" == *.partial ]]; then
            impact_check_info "$(impact_display "$copy"): left over from an interrupted impact-get-repo; its next run removes it."
            continue
        fi
        inside="$(impact_run_as "$account" timeout 30 git -C "$copy" rev-parse --is-inside-work-tree 2>/dev/null)" || inside=''
        if [[ "$inside" != 'true' ]]; then
            continue
        fi
        count=$((count + 1))
        impact_check__one_copy "$account" "$name" "$copy"
    done
    if ((count == 0)); then
        impact_check_info "$account: no working copy in $base yet."
    fi
}

# impact_check__one_copy ACCOUNT NAME PATH
#   Internal part of block 9: one working copy. git runs as the person with
#   --no-optional-locks, so it never rewrites the copy's index file: the
#   check stays read-only also inside the working copies.
impact_check__one_copy() {
    local account="$1" name="$2" copy="$3" shown origin state path extras_dir
    local -a extras=() bad=()
    impact_check_porcelain_summary < <(impact_run_as "$account" timeout 120 git -c core.fsmonitor=false --no-optional-locks \
        -C "$copy" status --porcelain=v1 -z --untracked-files=normal --ignore-submodules=all 2>/dev/null || true)
    shown="$(impact_display "$copy")"
    impact_check_info "$shown: $IMPACT_CHECK_CHANGED changed tracked files, $IMPACT_CHECK_UNTRACKED untracked files."
    if ((IMPACT_CHECK_UNTRACKED > 0)); then
        impact_check_warn "$shown has $IMPACT_CHECK_UNTRACKED files that git neither tracks nor ignores (for example: ${IMPACT_CHECK_UNTRACKED_NAMES[*]}). The Stop step of the GUI commits everything, so they would go to GitHub." \
            "Ask the person to commit, delete or ignore (.gitignore) such files. For extras of a model: sudo impact-check-model <model>"
    fi
    # Only a folder named like a registered model is that model's copy.
    impact_valid_model_name "$name" || return 0
    impact_model_load "$name" >/dev/null 2>&1 || return 0
    origin="$(impact_run_as "$account" timeout 30 git -C "$copy" config --get remote.origin.url 2>/dev/null)" || origin=''
    if impact_parse_github_address "$origin" && [[ "$IMPACT_GH_SSH_URL" == "${IMPACT_MODEL[REPO_URL]}" ]]; then
        :
    else
        impact_check_warn "$shown is named like the model $name, but its origin is $(impact_display "${origin:-not set}") and not ${IMPACT_MODEL[REPO_URL]}." \
            "Ask the person whether the copy is still needed; a fresh copy comes with: sudo impact-give-repo $account $name (after the old folder was renamed)."
    fi
    extras_dir="$(impact_model_dir "$name")/extras"
    [[ -d "$extras_dir" && ! -L "$extras_dir" ]] || return 0
    mapfile -d '' -t extras < <(timeout 60 find "$extras_dir" -xdev -mindepth 1 -type f -printf '%P\0' 2>/dev/null | head -z -n 10000 || true)
    ((${#extras[@]} > 0)) || return 0
    while IFS= read -r -d '' state && IFS= read -r -d '' path; do
        bad+=("$(impact_display "$path") ($state)")
    done < <(printf '%s\0' "${extras[@]}" |
        impact_run_as "$account" timeout 300 /bin/bash -c "$IMPACT_CHECK_EXTRAS_SCRIPT" impact-check-extras "$copy" 2>/dev/null || true)
    if ((${#bad[@]} > 0)); then
        impact_check_fail "In $shown, ${#bad[@]} extras of the model $name are not ignored by git or replace a tracked file: ${bad[*]:0:5}. The next Stop would commit them to GitHub." \
            "Look at the copy with: sudo impact-check-model $name. Then add the extras to .git/info/exclude of the copy, or hand out a fresh copy with impact-give-repo."
    else
        impact_check_ok "$shown: git ignores every extra of the model $name."
    fi
}

# =============================================================================
# Block 10: Shared storage
# =============================================================================

# impact_check_block_storage
#   Every storage root: file system, access control lists, place; the
#   storage folders of each model with the shared rules; a bounded sample
#   of the entries inside them.
impact_check_block_storage() {
    local root
    local -a roots=()
    impact_check_note_guess
    impact_check_shared_roots roots
    if ((${#roots[@]} == 0)); then
        impact_check_info "No storage root is known yet (SHARED_ROOTS). To look at a disk before the setup: sudo impact-check --shared-roots /mnt/disk_a/shared"
        return 0
    fi
    if ! impact_have_tool getfacl; then
        impact_check_warn "The tool getfacl is missing, so the access control lists (ACLs) of the storage cannot be read." \
            "Install the ACL tools: sudo apt-get install acl"
    fi
    for root in "${roots[@]}"; do
        impact_check__storage_root "$root"
    done
}

# impact_check__storage_root ROOT
#   Internal part of block 10: one storage root.
impact_check__storage_root() {
    local root="$1" real type options mount name model_name
    local is_configured=0
    local -a names=() used=() unused=()
    if impact_check_root_is_configured "$root"; then
        is_configured=1
    fi
    if [[ ! -e "$root" ]]; then
        if ((is_configured == 1)); then
            impact_check_fail "The storage root $root does not exist." \
                "Mount the disk that holds it, or let impact-workstation-setup create the folder: sudo impact-workstation-setup"
        else
            impact_check_warn "The storage root $root (given with --shared-roots) does not exist." \
                "Check the path, or mount the disk that should hold it."
        fi
        return 0
    fi
    real="$(realpath -e -- "$root" 2>/dev/null)" || real=''
    if [[ -z "$real" || ! -d "$real" ]]; then
        impact_check_fail "The storage root $root is no folder." \
            "Look at the storage root: ls -ld $root"
        return 0
    fi
    if [[ "$real" != "$root" ]]; then
        impact_check_info "The storage root $root is a symbolic link or lies below one; its real place is $(impact_display "$real")."
    fi
    type="$(impact_fs_type "$real")"
    options="$(impact_fs_mount_options "$real")"
    mount="$(findmnt -n -o TARGET -T "$real" 2>/dev/null | head -n 1)" || mount=''
    if ! impact_fs_type_supported "$type"; then
        impact_check_fail "The storage root $root lies on a file system of the type '$(impact_display "${type:-unknown}")'. The shared storage needs ext4, xfs or btrfs, which keep owners, groups and ACLs." \
            "Use a disk with one of these file systems for the storage root."
    elif [[ ",$options," == *,noacl,* ]]; then
        # The commas around both texts make "noacl" match as a whole word.
        impact_check_fail "The file system of $root is mounted with the option noacl, so it refuses access control lists." \
            "Remove noacl from its line in /etc/fstab and mount the disk again."
    else
        impact_check_ok "Storage root $root: file system $type, mounted at $(impact_display "$mount")."
    fi
    if [[ "$mount" == '/' ]]; then
        impact_check_warn "The storage root $root lies on the system disk, which also holds the accounts and the images." \
            "If a storage disk belongs there, mount it first; then look at the content of $root."
    fi
    impact_check_entry_facts "$real"
    impact_check_info "  $root itself: owner $IMPACT_CHECK_E_OWNER, group $IMPACT_CHECK_E_GROUP, mode $IMPACT_CHECK_E_MODE."
    if ((is_configured == 0)); then
        impact_check_info "  $root is not in SHARED_ROOTS; only its file system and its free space were checked."
        return 0
    fi

    # Can the members reach the storage at all? Every folder above the root
    # must let them enter, and the root itself must let them enter and list.
    # (A storage root that already existed, for example with the old shared
    # account as its owner, is left as it is by impact-workstation-setup.)
    local gid folder fix group_name="${IMPACT_CONF[SHARED_GROUP]}"
    gid="$(impact_group_gid "$group_name" 2>/dev/null)" || gid=''
    if [[ -n "$gid" ]]; then
        # "IFS=$'\t' read -r A B" splits each line at its tab into A and B.
        while IFS=$'\t' read -r folder fix; do
            [[ -n "$folder" ]] || continue
            impact_check_warn "Members of '$group_name' cannot enter $folder (see: ls -ld $folder), so they cannot reach the model folders in $root." \
                "If they should: $fix"
        done < <(impact_member_blocked_folders "$real" "$gid")
    fi

    # The storage folders of every model that may use this root.
    local model_dir="${IMPACT_CONF[MODEL_DIR]}"
    local -a models=() model_roots=()
    if [[ -d "$model_dir" && ! -L "$model_dir" ]]; then
        mapfile -d '' -t models < <(impact_check__list_names "$model_dir")
    fi
    for model_name in "${models[@]}"; do
        impact_valid_model_name "$model_name" || continue
        impact_model_load "$model_name" >/dev/null 2>&1 || continue
        impact_split_list "${IMPACT_MODEL[STORAGE_ROOTS]}" model_roots
        impact_in_list "$root" "${model_roots[@]}" || continue
        used+=("${IMPACT_MODEL[STORAGE_NAME]}")
        impact_check__model_storage "$model_name" "$root" "$real" "${IMPACT_MODEL[STORAGE_NAME]}"
    done
    if ((${#used[@]} == 0)); then
        impact_check_info "  No registered model uses $root yet."
    fi
    # The top folders of the root that no model uses: on a machine in
    # transition these are the folders of models that are not registered yet.
    mapfile -d '' -t names < <(impact_check__list_names "$real")
    for name in "${names[@]}"; do
        if ! impact_in_list "$name" "${used[@]}"; then
            unused+=("$(impact_display "$name")")
        fi
    done
    if ((${#unused[@]} > 0)); then
        impact_check_info "  Entries in $root that no registered model uses (${#unused[@]}): ${unused[*]:0:20}."
    fi
}

# impact_check__model_storage MODEL ROOT REAL_ROOT STORAGE_NAME
#   Internal part of block 10: the four folders of one model on one root
#   (<name>, <name>/outputs, <name>/inputs, <name>/inputs/synthpop) and a
#   sample of the entries inside outputs and inputs/synthpop.
impact_check__model_storage() {
    local model="$1" root="$2" real="$3" storage_name="$4" group="${IMPACT_CONF[SHARED_GROUP]}"
    local sub path absent=0 deviating=0
    for sub in '' /outputs /inputs /inputs/synthpop; do
        path="$real/$storage_name$sub"
        impact_check_entry_facts "$path"
        if [[ "$IMPACT_CHECK_E_TYPE" != 'folder' ]]; then
            absent=1
            impact_check_fail "The storage folder $path of the model $model is $([[ "$IMPACT_CHECK_E_TYPE" == 'missing' ]] && printf 'missing' || printf 'a %s, not a folder' "$IMPACT_CHECK_E_TYPE")." \
                "Create the folders with their rules: sudo impact-add-model $model ${IMPACT_MODEL[REPO_URL]} --storage $root --storage-name $storage_name"
            continue
        fi
        if ! impact_shared_dir_is_ok "$path" "$group" 2>/dev/null; then
            deviating=1
            impact_check_warn "The folder $path does not follow the shared rules (group '$group', group may write, setgid, default ACL)." \
                "Repair the model folder: sudo impact-share-folder --repair $real/$storage_name (its --help shows how to run a long repair in the background)."
        fi
    done
    if ((absent == 0 && deviating == 0)); then
        impact_check_ok "The storage folders of $model on $root follow the shared rules."
    fi
    if ((absent == 0)); then
        impact_check__sample "$model" "$real/$storage_name/outputs"
        impact_check__sample "$model" "$real/$storage_name/inputs/synthpop"
    fi
}

# impact_check__sample MODEL FOLDER
#   Internal part of block 10: looks at the first IMPACT_CHECK_SAMPLE_SIZE
#   folders and files that "find" meets inside FOLDER (at most three levels
#   deep) and counts those that deviate from the shared rules. This is a
#   sample: "find" stops as soon as enough entries were seen, so a folder
#   with millions of files costs no more than a small one.
impact_check__sample() {
    local model="$1" folder="$2" group="${IMPACT_CONF[SHARED_GROUP]}" entry deviations=0
    local -a entries=() examples=()
    mapfile -d '' -t entries < <(timeout 60 find "$folder" -xdev -mindepth 1 -maxdepth 3 \( -type d -o -type f \) -print0 2>/dev/null |
        head -z -n "$IMPACT_CHECK_SAMPLE_SIZE" || true)
    if ((${#entries[@]} == 0)); then
        impact_check_info "  $folder: empty."
        return 0
    fi
    for entry in "${entries[@]}"; do
        if [[ -d "$entry" && ! -L "$entry" ]]; then
            impact_shared_dir_is_ok "$entry" "$group" 2>/dev/null && continue
        elif [[ -f "$entry" && ! -L "$entry" ]]; then
            impact_shared_file_is_ok "$entry" "$group" 2>/dev/null && continue
        else
            continue
        fi
        deviations=$((deviations + 1))
        if ((${#examples[@]} < 3)); then
            examples+=("$(impact_display "${entry#"$folder"/}")")
        fi
    done
    if ((deviations == 0)); then
        impact_check_ok "A sample of ${#entries[@]} entries in $folder follows the shared rules."
    else
        impact_check_warn "In a sample of ${#entries[@]} entries in $folder, $deviations deviate from the shared rules (for example: ${examples[*]}). Files moved in with their old rights cause this." \
            "Repair the folder: sudo impact-share-folder --repair $folder (its --help shows how to run a long repair in the background)."
    fi
}

# =============================================================================
# Block 11: Containers and ports per person
# =============================================================================

# impact_check_block_containers
#   The containers that carry the label impact.account (the containers of
#   the GUI 2.1), grouped by person, with their state and published ports.
impact_check_block_containers() {
    local min="${IMPACT_CONF[PORT_MIN]}" max="${IMPACT_CONF[PORT_MAX]}" group="${IMPACT_CONF[SHARED_GROUP]}"
    local index account entry host_port running=0 total=0
    local -a accounts=() entries=()
    impact_check_note_guess
    if ! impact_check_load_containers; then
        impact_check_docker_unavailable
        return 0
    fi
    mapfile -t accounts < <(printf '%s\n' "${IMPACT_CHECK_C_ACCOUNT[@]}" | sed -e '/^$/d' | LC_ALL=C sort -u)
    if ((${#accounts[@]} == 0)); then
        impact_check_ok "No container carries the label impact.account: no container of the GUI 2.1 exists (${#IMPACT_CHECK_C_NAME[@]} containers in total)."
        return 0
    fi
    for account in "${accounts[@]}"; do
        impact_check_info "Containers of $account:"
        for index in "${!IMPACT_CHECK_C_NAME[@]}"; do
            [[ "${IMPACT_CHECK_C_ACCOUNT[index]}" == "$account" ]] || continue
            total=$((total + 1))
            if [[ "${IMPACT_CHECK_C_STATE[index]}" == 'running' ]]; then
                running=$((running + 1))
            fi
            impact_check_info "  ${IMPACT_CHECK_C_NAME[index]}: ${IMPACT_CHECK_C_STATE[index]}, image ${IMPACT_CHECK_C_IMAGE[index]}, ports $(impact_check_ports_text "${IMPACT_CHECK_C_PORTS[index]}")."
            read -r -a entries <<<"${IMPACT_CHECK_C_PORTS[index]}" || true
            for entry in "${entries[@]}"; do
                host_port="${entry#*|}"
                host_port="${host_port%%|*}"
                if [[ "$host_port" =~ ^[0-9]+$ ]] && ((host_port < min || host_port > max)); then
                    impact_check_warn "The container ${IMPACT_CHECK_C_NAME[index]} uses the port $host_port outside the range $min to $max; the tunnel of the GUI cannot reach it." \
                        "Ask the person to stop it and start it again with the GUI 2.1."
                fi
            done
            if [[ "$account" == '(invalid)' ]]; then
                impact_check_warn "The container ${IMPACT_CHECK_C_NAME[index]} has a label impact.account that is no account name." \
                    "Look at the container: sudo docker inspect ${IMPACT_CHECK_C_NAME[index]}"
            elif ! impact_account_exists "$account"; then
                impact_check_warn "The container ${IMPACT_CHECK_C_NAME[index]} belongs to '$account', which is no account on this machine." \
                    "Look at the container (sudo docker inspect ${IMPACT_CHECK_C_NAME[index]}), then stop it: sudo docker stop ${IMPACT_CHECK_C_NAME[index]}"
            elif [[ "${IMPACT_CHECK_C_STATE[index]}" == 'running' ]] && ! impact_account_in_group "$account" "$group"; then
                impact_check_warn "The container ${IMPACT_CHECK_C_NAME[index]} of '$account' runs although '$account' is no member of '$group' (removed?)." \
                    "Stop the container: sudo docker stop ${IMPACT_CHECK_C_NAME[index]} (or run sudo impact-remove-user $account again)."
            fi
        done
    done
    impact_check_ok "$total containers carry the label impact.account (${#accounts[@]} different accounts); $running of them run."
}

# =============================================================================
# Block 12: Listeners on the port range
# =============================================================================

# impact_check_block_listeners
#   Every program that listens on a TCP port of the range PORT_MIN to
#   PORT_MAX, and which container it belongs to. The GUI treats such ports
#   as busy. Counts the free ports.
impact_check_block_listeners() {
    local min="${IMPACT_CONF[PORT_MIN]}" max="${IMPACT_CONF[PORT_MAX]}" line port kind owner index entry host_port
    local docker_ok=0 free=0 total
    local -A busy=() port_owner=()
    local -a entries=()
    impact_check_note_guess
    if ! impact_have_tool ss; then
        impact_check_warn "The tool ss is missing, so the listening programs cannot be listed." \
            "Install ss: sudo apt-get install iproute2"
        return 0
    fi
    if impact_check_load_containers; then
        docker_ok=1
        for index in "${!IMPACT_CHECK_C_NAME[@]}"; do
            [[ "${IMPACT_CHECK_C_STATE[index]}" == 'running' ]] || continue
            read -r -a entries <<<"${IMPACT_CHECK_C_PORTS[index]}" || true
            for entry in "${entries[@]}"; do
                host_port="${entry#*|}"
                host_port="${host_port%%|*}"
                [[ "$host_port" =~ ^[0-9]+$ ]] || continue
                owner="container ${IMPACT_CHECK_C_NAME[index]}"
                if [[ -n "${IMPACT_CHECK_C_ACCOUNT[index]}" ]]; then
                    owner+=" of ${IMPACT_CHECK_C_ACCOUNT[index]}"
                fi
                port_owner[$host_port]="$owner"
                if ((host_port >= min && host_port <= max)); then
                    busy[$host_port]=1
                fi
            done
        done
    elif impact_docker_installed; then
        impact_check_info "Docker does not answer: ports that containers hold without a listening program are not counted here (block 2)."
    fi
    # ss lists sockets: -H without heading, -l listening, -t TCP, -n numbers
    # (no name lookups), -p with the program (needs root).
    while IFS= read -r line; do
        impact_check_parse_listener "$line" || continue
        port="$IMPACT_CHECK_L_PORT"
        ((port >= min && port <= max)) || continue
        busy[$port]=1
        kind="$(impact_check_address_kind "$IMPACT_CHECK_L_ADDRESS")"
        case "$kind" in
            loopback) kind='this machine only' ;;
            all) kind='all addresses' ;;
            *) kind='a network address' ;;
        esac
        if [[ -n "${port_owner[$port]:-}" ]]; then
            impact_check_info "Port $port on $IMPACT_CHECK_L_ADDRESS ($kind): ${port_owner[$port]}."
        elif [[ "$IMPACT_CHECK_L_PROCESS" == docker-proxy* && "$docker_ok" == 0 ]]; then
            impact_check_info "Port $port on $IMPACT_CHECK_L_ADDRESS ($kind): a Docker container (Docker does not answer, so which one is unknown)."
        else
            impact_check_warn "Port $port on $IMPACT_CHECK_L_ADDRESS ($kind): ${IMPACT_CHECK_L_PROCESS:-a program} outside Docker listens there, so the GUI cannot use this port." \
                "If the program does not belong on this port, stop it or move it to a port outside $min to $max. Look at it with: sudo ss -ltnp 'sport = :<port>'"
        fi
    done < <(ss -H -l -t -n -p 2>/dev/null || true)
    total=$((max - min + 1))
    for ((port = min; port <= max; port++)); do
        if [[ -z "${busy[$port]:-}" ]]; then
            free=$((free + 1))
        fi
    done
    if ((free == 0)); then
        impact_check_fail "No port of the range $min to $max is free: the GUI cannot start another container." \
            "Stop containers that are no longer needed, or widen the range: sudo impact-workstation-setup --port-max <number>"
    elif ((free < 3)); then
        impact_check_warn "Only $free of the $total ports of the range $min to $max are free." \
            "Stop containers that are no longer needed, or widen the range: sudo impact-workstation-setup --port-max <number>"
    else
        impact_check_ok "$free of the $total ports of the range $min to $max are free."
    fi
}

# =============================================================================
# Block 13: Containers that publish ports to the network
# =============================================================================

# impact_check_block_published
#   Containers whose ports can be reached from other computers (published
#   on all addresses or on a network address). In tunnel mode only the
#   containers named in KNOWN_DIRECT_CONTAINERS may do that.
impact_check_block_published() {
    local mode="${IMPACT_CONF[ACCESS_MODE]}" known="${IMPACT_CONF[KNOWN_DIRECT_CONTAINERS]}" index name ports count=0
    impact_check_note_guess
    if ! impact_check_load_containers; then
        impact_check_docker_unavailable
        return 0
    fi
    impact_check_info "ACCESS_MODE=$mode. Accepted containers (KNOWN_DIRECT_CONTAINERS): ${known:-none}. Docker opens published ports past the firewall rules of ufw."
    for index in "${!IMPACT_CHECK_C_NAME[@]}"; do
        [[ "$(impact_check_ports_reach "${IMPACT_CHECK_C_PORTS[index]}")" == 'network' ]] || continue
        count=$((count + 1))
        name="${IMPACT_CHECK_C_NAME[index]}"
        ports="$(impact_check_ports_text "${IMPACT_CHECK_C_PORTS[index]}")"
        if impact_check_name_matches "$name" "$known"; then
            impact_check_ok "$name (${IMPACT_CHECK_C_STATE[index]}) publishes to the network and is accepted (KNOWN_DIRECT_CONTAINERS): $ports."
        elif [[ "$mode" == 'direct' ]]; then
            impact_check_info "$name (${IMPACT_CHECK_C_STATE[index]}) publishes to the network (allowed with ACCESS_MODE=direct): $ports."
        elif [[ -n "${IMPACT_CHECK_C_ACCOUNT[index]}" ]]; then
            impact_check_warn "The GUI container $name of ${IMPACT_CHECK_C_ACCOUNT[index]} (${IMPACT_CHECK_C_STATE[index]}) publishes to the network: $ports. In tunnel mode the GUI publishes on 127.0.0.1 only." \
                "Ask the person to stop the container and start it again with the GUI 2.1 (sudo docker stop <name> stops it now)."
        else
            impact_check_warn "$name (${IMPACT_CHECK_C_STATE[index]}) publishes to the network and is not accepted in KNOWN_DIRECT_CONTAINERS: $ports." \
                "If such a container is meant to be reachable from the network, accept it with the complete list of patterns: sudo impact-workstation-setup --known-direct-containers '<patterns>'. Otherwise publish it on 127.0.0.1 only."
        fi
    done
    if ((count == 0)); then
        impact_check_ok "No container publishes a port to the network (${#IMPACT_CHECK_C_NAME[@]} containers in total)."
    fi
}

# =============================================================================
# Block 14: Volumes named like IMPACT volumes
# =============================================================================

# impact_check_block_volumes
#   Docker volumes whose names look like volumes of the volume mode of
#   earlier GUI versions. They can hold the only copy of results.
impact_check_block_volumes() {
    local name users
    local -a names=() found=()
    if ! impact_check_docker_answers; then
        impact_check_docker_unavailable
        return 0
    fi
    mapfile -t names < <(impact_docker_ro volume ls --format '{{.Name}}' 2>/dev/null || true)
    for name in "${names[@]}"; do
        impact_check_volume_like_impact "$name" || continue
        users=''
        # Only a name of the characters Docker allows is handed back to
        # Docker as a filter.
        if [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
            users="$(impact_docker_ro ps --all --filter "volume=$name" --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')" || users=''
            users="$(impact_trim "$users")"
        fi
        found+=("$name")
        impact_check_info "Volume $(impact_display "$name"): used by ${users:-no container}."
    done
    if ((${#found[@]} == 0)); then
        impact_check_ok "No volume is named like an IMPACT volume (${#names[@]} volumes in total)."
        return 0
    fi
    impact_check_warn "${#found[@]} volumes are named like volumes of the GUI's volume mode. Such a volume can hold the only copy of results." \
        "Before the switch-over: copy the results of each volume to the model's outputs folder on the storage and write down a decision for each volume. Remove a volume only after a successful copy: sudo docker volume rm <name>"
}

# =============================================================================
# Block 15: Containers without IMPACT labels
# =============================================================================

# impact_check_block_unlabelled
#   Containers without the label impact.account: containers of GUI 2.0,
#   started by hand, or permanent containers outside the GUI. Those that
#   match KNOWN_DIRECT_CONTAINERS are named as accepted.
impact_check_block_unlabelled() {
    local known="${IMPACT_CONF[KNOWN_DIRECT_CONTAINERS]}" index name text count=0 open=0
    impact_check_note_guess
    if ! impact_check_load_containers; then
        impact_check_docker_unavailable
        return 0
    fi
    for index in "${!IMPACT_CHECK_C_NAME[@]}"; do
        [[ -z "${IMPACT_CHECK_C_ACCOUNT[index]}" ]] || continue
        count=$((count + 1))
        name="${IMPACT_CHECK_C_NAME[index]}"
        text="$name (${IMPACT_CHECK_C_STATE[index]}, image ${IMPACT_CHECK_C_IMAGE[index]}, ports $(impact_check_ports_text "${IMPACT_CHECK_C_PORTS[index]}"))"
        if impact_check_name_matches "$name" "$known"; then
            impact_check_ok "$text: accepted (KNOWN_DIRECT_CONTAINERS)."
        elif [[ "${IMPACT_CHECK_C_OLDLABEL[index]}" == '1' ]]; then
            open=$((open + 1))
            impact_check_warn "$text: started by GUI 2.0 (labels impact.* without impact.account)." \
                "Decide for each container named above: ask its owner to save the work and stop it with the GUI 2.0, or stop it (sudo docker stop <name>), or accept it with the complete list of patterns: sudo impact-workstation-setup --known-direct-containers '<patterns>'."
        else
            open=$((open + 1))
            impact_check_warn "$text: no IMPACT label." \
                "Decide for each container named above: ask its owner to save the work and stop it with the GUI 2.0, or stop it (sudo docker stop <name>), or accept it with the complete list of patterns: sudo impact-workstation-setup --known-direct-containers '<patterns>'."
        fi
    done
    if ((count == 0)); then
        impact_check_ok "Every container carries the label impact.account (${#IMPACT_CHECK_C_NAME[@]} containers in total)."
    elif ((open == 0)); then
        impact_check_ok "All $count containers without IMPACT label are accepted."
    fi
}
