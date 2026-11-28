#!/bin/bash
# =============================================================================
# impact-users.sh: shared code of the commands that manage people
#
# Purpose
#   impact-add-user, impact-key, impact-list-users and impact-remove-user load
#   this file directly after impact-common.sh. It holds what these four
#   commands share:
#   1. checks that protect accounts these commands must never change (root,
#      system accounts, the administration account, accounts with sudo);
#   2. getting a public key from one of three sources (the person's GitHub
#      account, a file, or standard input) and confirming its fingerprint;
#   3. reading and changing the login keys of a person, the file
#      ~/.ssh/authorized_keys, always with the rights of the person;
#   4. the archive of received and removed keys in /opt/impact/admin/keys;
#   5. processes, SSH sessions, tunnels and containers of a person;
#   6. texts: the last login, the message for a new colleague, and the
#      commands that bring a removed person back.
#   A "public key" is the half of a key pair that may be shown to anyone; the
#   person's PC keeps the private half. A "fingerprint" is a short code
#   computed from a public key (SHA256:...); two people compare it to make
#   sure they talk about the same key.
#
# Who runs it
#   Nobody directly. The four commands above load it with "source".
#
# Usage (inside a command, after loading impact-common.sh)
#   source "$IMPACT_LIB_DIR/impact-users.sh"
#   impact_users_collect_keys "$github_name"
#   impact_users_choose_key "$github_name"
#   impact_users_read_authorized_keys alice || status=$?
#
# What it changes on the system
#   Loading changes nothing. The functions change files of one person, the
#   key archive in /opt/impact/admin/keys, or end processes and containers of
#   one person, when a command calls them inside impact_do.
#
# How to undo
#   Nothing to undo for the file itself. Each command prints its own
#   "How to undo" list.
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
#   IFS=: read -r A B    split one line at the character after "IFS=" (here
#                        ":") into the variables A and B; with -a LIST into a list
#   while IFS= read -r line   read input line by line, exactly as written:
#                        "IFS=" keeps blanks at both ends, -r keeps backslashes
#   command || true      accept a failure of this command ("set -e" would
#                        otherwise stop the script there)
#   "${!LIST[@]}"        the positions (or the names) of the entries of a list
#   "${NAME,,}"          the text in lower case
#   shopt -s nullglob    a file pattern (*.conf) without a match gives an empty
#                        list; "shopt -u" switches this off again
# Constructs beyond these are explained where they are first used.
# -----------------------------------------------------------------------------

# The line for the checking tool "shellcheck" stands before the first command
# of the file and therefore counts for the whole file.
# shellcheck disable=SC2034
# Reason for SC2034 (variable appears unused): the variables set here are
# read by the commands that load this file.

# Load this file once per script.
if [[ -n "${IMPACT_USERS_LOADED:-}" ]]; then
    return 0
fi
IMPACT_USERS_LOADED=1

# Results of impact_users_collect_keys: the keys found in the source, their
# fingerprints in the same order, and a few words that name the source.
IMPACT_USERS_CANDIDATES=()
IMPACT_USERS_CANDIDATE_PRINTS=()
IMPACT_USERS_KEY_SOURCE=''
# The text read from a key file or from standard input.
IMPACT_USERS_TEXT=''
# 1 when the chosen key was confirmed with --fingerprint.
IMPACT_USERS_FINGERPRINT_GIVEN=0
# The number of keys of other types that GitHub listed (for the message).
IMPACT_USERS_OTHER_KEY_COUNT=0
# Why impact_users_check_changeable refused an account.
IMPACT_USERS_REASON=''
# The content of ~/.ssh/authorized_keys after impact_users_read_authorized_keys.
IMPACT_USERS_AK_TEXT=''
# A key file or a pasted key may have at most this many bytes. A public key
# line has about 100; the limit only stops a wrong file (for example an image)
# from being read in full.
readonly IMPACT_USERS_KEY_TEXT_LIMIT=65536
# Groups whose members can become root with sudo. An account in one of them
# is an administration account and is never changed by these commands.
readonly -a IMPACT_USERS_ADMIN_GROUPS=(sudo admin wheel)

# =============================================================================
# Accounts that must never be changed
# =============================================================================

# impact_users_check_changeable ACCOUNT
#   Decides whether the commands may change ACCOUNT (add it to the groups,
#   lock its password, expire it). Refused are: an account that does not
#   exist; a user number outside 1000 to 60000 (root has 0, system accounts
#   have numbers below 1000, the account "nobody" has 65534); the account
#   that runs the command (its own login would be locked); and members of
#   the groups sudo, admin or wheel (administration accounts: a locked
#   password would end their use of sudo).
#   Result: success when ACCOUNT may be changed; otherwise failure, and the
#   reason in IMPACT_USERS_REASON.
#   Example: impact_users_check_changeable alice || impact_die 4 "$IMPACT_USERS_REASON" ""
impact_users_check_changeable() {
    local account="$1" uid group invoker
    IMPACT_USERS_REASON=''
    if ! impact_account_exists "$account"; then
        IMPACT_USERS_REASON="The account '$(impact_display "$account")' does not exist."
        return 1
    fi
    uid="$(impact_account_uid "$account")" || uid=''
    if ! impact_valid_user_number "$uid"; then
        IMPACT_USERS_REASON="The account '$account' has the user number ${uid:-unknown}. Accounts of people have numbers from 1000 to 60000; root and the system accounts are never changed by this command."
        return 1
    fi
    invoker="$(impact_invoking_account)"
    if [[ "$account" == "$invoker" ]]; then
        IMPACT_USERS_REASON="'$account' is the account that runs this command. Changing it could lock you out of the workstation."
        return 1
    fi
    for group in "${IMPACT_USERS_ADMIN_GROUPS[@]}"; do
        if impact_group_exists "$group" && impact_account_in_group "$account" "$group"; then
            IMPACT_USERS_REASON="The account '$account' is a member of the group '$group', so it is an administration account. The IMPACT commands change accounts of colleagues only."
            return 1
        fi
    done
    return 0
}

# impact_users_default_home ACCOUNT
#   Prints the home folder that "useradd" gives a new account: the folder
#   named by its setting HOME (normally /home) plus the account name.
#   Example: impact_users_default_home alice   prints /home/alice
impact_users_default_home() {
    local base
    # "useradd -D" prints the defaults as KEY=value lines; sed keeps the
    # value of the line that starts with HOME=.
    base="$(useradd -D 2>/dev/null | sed -n -e 's/^HOME=//p' | head -n 1)" || base=''
    if ! impact_valid_abs_path "$base"; then
        base='/home'
    fi
    printf '%s/%s\n' "$base" "$1"
}

# impact_users_record_state ACCOUNT
#   Prints the state noted in the account record: "enrolled" or "removed".
#   Prints "none" when the account has no record, "invalid" when the record
#   cannot be used. Needs root rights.
#   Result: 0 enrolled or removed; 1 no record; 2 invalid record (the causes
#   are in IMPACT_ACCOUNT_RECORD_ERRORS).
impact_users_record_state() {
    local status=0
    impact_account_record_load "$1" || status=$?
    case "$status" in
        0) printf '%s\n' "${IMPACT_ACCOUNT_RECORD[STATE]}" ;;
        1) printf 'none\n' ;;
        *) printf 'invalid\n' ;;
    esac
    return "$status"
}

# =============================================================================
# Getting a public key and confirming its fingerprint
# =============================================================================

# impact__users_add_candidate LINE
#   Internal: checks one key line and adds it with its fingerprint to the
#   candidates. A key that is already in the list is not added twice.
#   Result: failure when the line is no plain ssh-ed25519 key.
impact__users_add_candidate() {
    local print
    impact_parse_ed25519_key "$1" || return 1
    for print in "${IMPACT_USERS_CANDIDATE_PRINTS[@]}"; do
        if [[ "$print" == "$IMPACT_KEY_FINGERPRINT" ]]; then
            return 0
        fi
    done
    if [[ -n "$IMPACT_KEY_COMMENT" ]]; then
        IMPACT_USERS_CANDIDATES+=("$IMPACT_KEY_LINE $IMPACT_KEY_COMMENT")
    else
        IMPACT_USERS_CANDIDATES+=("$IMPACT_KEY_LINE")
    fi
    IMPACT_USERS_CANDIDATE_PRINTS+=("$IMPACT_KEY_FINGERPRINT")
}

# impact__users_keys_from_github GITHUB_NAME
#   Internal: downloads https://github.com/<name>.keys, the list of public
#   keys that GitHub shows for every account, and keeps the ssh-ed25519 keys.
#   Ends the command when GitHub cannot be reached, has no such account, or
#   lists no ssh-ed25519 key.
impact__users_keys_from_github() {
    local name="$1" status=0 text line file
    local -a keys=()
    impact_require_tools curl
    impact_mktemp_file || impact_die "$IMPACT_EXIT_FAILED" "A temporary file could not be created." ""
    file="$IMPACT_TMP"
    impact_info "Download the public keys of the GitHub account '$name' from https://github.com/$name.keys"
    impact_https_get "https://github.com/$name.keys" "$file" || status=$?
    case "$status" in
        0) ;;
        "$IMPACT_EXIT_NO_ACCESS")
            # 404 means "not found". Other answers of the 400 group mean that
            # the request was refused, for example after too many requests,
            # or by a proxy between the workstation and GitHub.
            if [[ "$IMPACT_HTTP_STATUS" == '404' ]]; then
                impact_die "$IMPACT_EXIT_NO_ACCESS" "GitHub answered with the status 404: it has no account named '$name', or the account is closed." \
                    "Check the spelling of the GitHub name with the person, or ask for the public key that the GUI shows and give it with --key-file."
            fi
            impact_die "$IMPACT_EXIT_NO_ACCESS" "The request for the keys of '$name' was refused with the status $IMPACT_HTTP_STATUS (for example after too many requests, or by a proxy on the way to GitHub)." \
                "Try again later, or ask for the public key that the GUI shows and give it with --key-file."
            ;;
        "$IMPACT_EXIT_NETWORK")
            impact_die "$IMPACT_EXIT_NETWORK" "GitHub could not be reached (status ${IMPACT_HTTP_STATUS:-000}). This is a network problem." \
                "Check the internet connection of the workstation (curl -sI https://github.com), or give the key with --key-file."
            ;;
        *)
            impact_die "$IMPACT_EXIT_FAILED" "The address of the GitHub key list was not accepted." ""
            ;;
    esac
    text="$(head -c 1048576 -- "$file")"
    # "|| true": no ed25519 key is a normal answer that is handled below.
    mapfile -t keys < <(impact_ed25519_keys_in_text "$text" || true)
    IMPACT_USERS_OTHER_KEY_COUNT=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(impact_trim "$line")"
        if [[ -n "$line" && "$line" != 'ssh-ed25519 '* ]]; then
            IMPACT_USERS_OTHER_KEY_COUNT=$((IMPACT_USERS_OTHER_KEY_COUNT + 1))
        fi
    done <<<"$text"
    for line in "${keys[@]}"; do
        impact__users_add_candidate "$line" || true
    done
    if ((${#IMPACT_USERS_CANDIDATES[@]} == 0)); then
        impact_die "$IMPACT_EXIT_FAILED" "The GitHub account '$name' lists no key of the type ssh-ed25519 (keys of other types: $IMPACT_USERS_OTHER_KEY_COUNT). Only ssh-ed25519 keys are accepted; the GUI creates this type." \
            "Ask the person to send the public key that the GUI shows, and give it with --key-file or on standard input."
    fi
    IMPACT_USERS_KEY_SOURCE="GitHub (https://github.com/$name.keys)"
}

# impact__users_key_text_from_file PATH
#   Internal: reads a key file given with --key-file into IMPACT_USERS_TEXT.
#   The path may be relative to the current folder; after resolving it, it
#   must consist of letters, digits and . _ - / only, and name a plain file
#   of at most 64 KB. Ends the command otherwise.
impact__users_key_text_from_file() {
    local given="$1" real size
    if [[ -z "$given" ]]; then
        impact_die_usage "--key-file needs the path of a file that holds the public key."
    fi
    # "realpath -e" prints the full path with all symbolic links resolved and
    # fails when nothing exists there.
    if ! real="$(realpath -e -- "$given" 2>/dev/null)"; then
        impact_die "$IMPACT_EXIT_FAILED" "The key file '$(impact_display "$given")' does not exist." \
            "Check the path. The person's public key is the file whose name ends in .pub."
    fi
    if ! impact_valid_abs_path "$real"; then
        impact_die_usage "The path of the key file, '$(impact_display "$real")', contains characters other than letters, digits and . _ - /. Copy the file to a simple name, for example: cp '<file>' /tmp/alice.pub"
    fi
    if [[ ! -f "$real" ]]; then
        impact_die_usage "The key file $real is no plain file."
    fi
    size="$(stat -c '%s' -- "$real" 2>/dev/null)" || size=0
    if ((size > IMPACT_USERS_KEY_TEXT_LIMIT)); then
        impact_die_usage "The key file $real has $size bytes. A public key line has about 100 bytes; this is not a public key file."
    fi
    IMPACT_USERS_TEXT="$(head -c "$IMPACT_USERS_KEY_TEXT_LIMIT" -- "$real")"
    IMPACT_USERS_KEY_SOURCE="the file $real"
}

# impact__users_key_text_from_input WHO
#   Internal: reads the key from standard input into IMPACT_USERS_TEXT. When
#   standard input is a terminal, it asks for one pasted line; otherwise it
#   reads everything (at most 64 KB).
impact__users_key_text_from_input() {
    local who="$1" line=''
    # "[[ -t 0 ]]" is true when standard input (channel 0) is a terminal.
    if [[ -t 0 ]]; then
        impact_say "Paste the public key line of $who (it starts with ssh-ed25519) and press Enter:"
        IFS= read -r line || line=''
        IMPACT_USERS_TEXT="$line"
        IMPACT_USERS_KEY_SOURCE='the pasted line'
        return 0
    fi
    IMPACT_USERS_TEXT="$(head -c "$((IMPACT_USERS_KEY_TEXT_LIMIT + 1))")"
    if ((${#IMPACT_USERS_TEXT} > IMPACT_USERS_KEY_TEXT_LIMIT)); then
        impact_die_usage "Standard input holds more than $IMPACT_USERS_KEY_TEXT_LIMIT bytes. A public key line has about 100 bytes."
    fi
    IMPACT_USERS_KEY_SOURCE='standard input'
}

# impact_users_collect_keys GITHUB_NAME
#   Reads the candidate key or keys from the source the options name:
#     --github           the keys GitHub lists for GITHUB_NAME (one or more)
#     --key-file PATH    a file with exactly one key line
#     neither            standard input, exactly one key line
#   Only plain ssh-ed25519 lines are accepted. Refused, each with its own
#   explanation: a private key, another key type, a line with options in
#   front of the key, two keys, a damaged line.
#   Result: IMPACT_USERS_CANDIDATES (the key lines), IMPACT_USERS_CANDIDATE_PRINTS
#   (their fingerprints) and IMPACT_USERS_KEY_SOURCE. Ends the command when
#   no usable key was found. Call it from the main flow of a command, never
#   inside "$( ... )".
impact_users_collect_keys() {
    local name="$1"
    IMPACT_USERS_CANDIDATES=()
    IMPACT_USERS_CANDIDATE_PRINTS=()
    IMPACT_USERS_KEY_SOURCE=''
    IMPACT_USERS_TEXT=''
    if impact_opt_given github && impact_opt_given key-file; then
        impact_die_usage "Give the key in one way only: --github or --key-file (or on standard input)."
    fi
    if impact_opt_given github; then
        impact__users_keys_from_github "$name"
        return 0
    fi
    if impact_opt_given key-file; then
        impact__users_key_text_from_file "$(impact_opt key-file)"
    else
        impact__users_key_text_from_input "$name"
    fi
    if [[ -z "$(impact_trim "$IMPACT_USERS_TEXT")" ]]; then
        impact_die_usage "No key was given. Give it in one of three ways: --github (the keys of the GitHub account), --key-file <file>, or the key line on standard input."
    fi
    if ! impact_parse_ed25519_key "$IMPACT_USERS_TEXT"; then
        impact_die_usage "The key from $IMPACT_USERS_KEY_SOURCE is not accepted. $IMPACT_KEY_ERROR"
    fi
    impact__users_add_candidate "$IMPACT_USERS_TEXT"
}

# impact_users_choose_key WHO
#   Chooses the key to work with among IMPACT_USERS_CANDIDATES:
#     --fingerprint given    the candidate with exactly this fingerprint;
#                            the command ends when none has it;
#     one candidate          that one;
#     several candidates     the command lists them and ends: it needs
#                            --fingerprint to know which one.
#   Result: IMPACT_KEY_LINE, IMPACT_KEY_BLOB, IMPACT_KEY_COMMENT and
#   IMPACT_KEY_FINGERPRINT describe the chosen key (see
#   impact_parse_ed25519_key). IMPACT_USERS_FINGERPRINT_GIVEN is 1 when the
#   choice was confirmed with --fingerprint.
impact_users_choose_key() {
    local who="$1" wanted='' index chosen=-1
    IMPACT_USERS_FINGERPRINT_GIVEN=0
    if impact_opt_given fingerprint; then
        wanted="$(impact_opt fingerprint)"
        if ! impact_valid_fingerprint "$wanted"; then
            impact_die_usage "'$(impact_display "$wanted")' is no fingerprint. A fingerprint looks like SHA256: followed by 43 letters, digits, + and /."
        fi
        for index in "${!IMPACT_USERS_CANDIDATE_PRINTS[@]}"; do
            if [[ "${IMPACT_USERS_CANDIDATE_PRINTS[index]}" == "$wanted" ]]; then
                chosen="$index"
            fi
        done
        if ((chosen < 0)); then
            impact_error "The key(s) from $IMPACT_USERS_KEY_SOURCE:"
            for index in "${!IMPACT_USERS_CANDIDATE_PRINTS[@]}"; do
                impact_error "  ${IMPACT_USERS_CANDIDATE_PRINTS[index]}"
            done
            impact_die "$IMPACT_EXIT_FAILED" "No key from $IMPACT_USERS_KEY_SOURCE has the fingerprint $wanted. Nothing was changed." \
                "Ask $who which key the GUI shows (the fingerprint on its screen), and give that key."
        fi
        IMPACT_USERS_FINGERPRINT_GIVEN=1
    elif ((${#IMPACT_USERS_CANDIDATES[@]} == 1)); then
        chosen=0
    else
        impact_say ''
        impact_say "$IMPACT_USERS_KEY_SOURCE lists ${#IMPACT_USERS_CANDIDATES[@]} keys of the type ssh-ed25519:"
        for index in "${!IMPACT_USERS_CANDIDATE_PRINTS[@]}"; do
            impact_say "  $((index + 1)). ${IMPACT_USERS_CANDIDATE_PRINTS[index]}"
        done
        impact_die_usage "It is not clear which of these keys belongs to the PC of $who. Choose the one whose fingerprint $who sent you and run the command again with --fingerprint <that fingerprint>."
    fi
    impact_parse_ed25519_key "${IMPACT_USERS_CANDIDATES[chosen]}" ||
        impact_die "$IMPACT_EXIT_FAILED" "The chosen key could not be read again: $IMPACT_KEY_ERROR" ""
}

# impact_users_confirm_key WHO
#   Asks the administrator to confirm that the fingerprint of the chosen key
#   equals the one the person sent. This protects against a wrong or a
#   foreign key, for example an old key on GitHub or a key that someone else
#   sent. The option --yes does not answer this question; --fingerprint
#   does (the administrator typed the fingerprint the person sent). In a dry
#   run the question is shown and nothing is asked.
#   Result: returns when the key is confirmed; ends the command otherwise.
impact_users_confirm_key() {
    local who="$1"
    impact_info "Key from $IMPACT_USERS_KEY_SOURCE:"
    impact_info "  fingerprint: $IMPACT_KEY_FINGERPRINT"
    impact_info "  comment:     ${IMPACT_KEY_COMMENT:-(none)}"
    if ((IMPACT_USERS_FINGERPRINT_GIVEN == 1)); then
        impact_ok "The fingerprint equals the one given with --fingerprint."
        return 0
    fi
    # "local" gives this function its own IMPACT_ASSUME_YES with the value 0.
    # impact_confirm reads that one, so --yes cannot answer this question.
    local IMPACT_ASSUME_YES=0
    if ! impact_confirm "Compare this fingerprint with the one $who sent you (the GUI shows it at the first REMOTE start): $IMPACT_KEY_FINGERPRINT  Is it exactly the same?" yes \
        "Run the command in a terminal, or add --fingerprint <the fingerprint the person sent> after comparing it (the option --yes does not answer this question)."; then
        impact_die "$IMPACT_EXIT_FAILED" "Stopped: the fingerprint of the key was not confirmed. Nothing was changed." \
            "Compare the fingerprint with the person, then run the command again in a terminal, or add --fingerprint <the fingerprint the person sent>."
    fi
    impact_ok "The fingerprint was confirmed."
}

# =============================================================================
# The login keys of a person: ~/.ssh/authorized_keys
# =============================================================================
# The SSH server lets a person log in with every key listed in this file.
# The commands read and write it with the rights of the person (functions
# impact_user_* of impact-accounts.sh), so a symbolic link that the person
# placed there can never make root read or write another file.

# impact_users_authorized_keys_path HOME_FOLDER
#   Prints <home>/.ssh/authorized_keys.
impact_users_authorized_keys_path() {
    printf '%s/.ssh/authorized_keys\n' "$1"
}

# impact_users_read_authorized_keys ACCOUNT
#   Reads the person's authorized_keys into IMPACT_USERS_AK_TEXT, with the
#   rights of the person. A missing file (or a missing ~/.ssh) gives an
#   empty text.
#   Result: 0 read (or missing); 3 refused: a symbolic link or a foreign
#   owner on the way (the reason was printed); 1 other failure.
impact_users_read_authorized_keys() {
    local account="$1" home status=0
    IMPACT_USERS_AK_TEXT=''
    home="$(impact_account_home "$account")" || return 1
    IMPACT_USERS_AK_TEXT="$(impact_user_read_file "$account" "$(impact_users_authorized_keys_path "$home")")" || status=$?
    if ((status == 4)); then
        IMPACT_USERS_AK_TEXT=''
        return 0
    fi
    return "$status"
}

# impact_users_line_fingerprint LINE
#   Prints the fingerprint of one line of an authorized_keys file, also of a
#   line with options in front or of another key type.
#   Result: failure when the line holds no key that ssh-keygen understands.
impact_users_line_fingerprint() {
    local output fingerprint
    output="$(ssh-keygen -l -E sha256 -f /dev/stdin <<<"$1" 2>/dev/null)" || return 1
    read -r _ fingerprint _ <<<"$output"
    impact_valid_fingerprint "$fingerprint" || return 1
    printf '%s\n' "$fingerprint"
}

# impact__users_is_key_line LINE
#   Internal: yes for a line that is neither empty nor a comment ("#").
impact__users_is_key_line() {
    local line
    line="$(impact_trim "$1")"
    [[ -n "$line" && "$line" != '#'* ]]
}

# impact_users_key_entries TEXT
#   Prints one line per key of an authorized_keys text, in this form:
#     <number>|<fingerprint>|<kind>|<description>
#   kind "plain": a plain ssh-ed25519 line, as these commands write it; the
#   description is its comment. kind "other": a line with options in front
#   of the key, or a key of another type; the description says which.
#   A line without a readable key gets "?" as fingerprint.
#   Example: impact_users_key_entries "$IMPACT_USERS_AK_TEXT"
impact_users_key_entries() {
    local line number=0 print kind description word
    while IFS= read -r line || [[ -n "$line" ]]; do
        impact__users_is_key_line "$line" || continue
        number=$((number + 1))
        line="$(impact_trim "$line")"
        if impact_parse_ed25519_key "$line"; then
            print="$IMPACT_KEY_FINGERPRINT"
            kind='plain'
            description="${IMPACT_KEY_COMMENT:-(no comment)}"
        else
            print="$(impact_users_line_fingerprint "$line")" || print='?'
            kind='other'
            # The first word is the key type, or the options when the line
            # starts with options.
            read -r word _ <<<"$line"
            if [[ "$print" == '?' ]]; then
                description='no readable key'
            else
                case "$word" in
                    ssh-* | ecdsa-* | sk-*) description="type $(impact_display "$word")" ;;
                    *) description='a line with options in front of the key' ;;
                esac
            fi
        fi
        printf '%s|%s|%s|%s\n' "$number" "$print" "$kind" "$description"
    done <<<"$1"
}

# impact_users_count_keys TEXT
#   Prints the number of key lines in an authorized_keys text.
impact_users_count_keys() {
    local line count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if impact__users_is_key_line "$line"; then
            count=$((count + 1))
        fi
    done <<<"$1"
    printf '%s\n' "$count"
}

# impact_users_text_has_blob TEXT BLOB
#   Result: success when a line of the authorized_keys TEXT holds the key
#   data BLOB, as the plain key or after options.
impact_users_text_has_blob() {
    local line word
    local -a words=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        impact__users_is_key_line "$line" || continue
        read -r -a words <<<"$line"
        for word in "${words[@]}"; do
            if [[ "$word" == "$2" ]]; then
                return 0
            fi
        done
    done <<<"$1"
    return 1
}

# impact_users_text_has_fingerprint TEXT FINGERPRINT
#   Result: success when a key line of TEXT has this fingerprint.
impact_users_text_has_fingerprint() {
    local entry
    while IFS= read -r entry; do
        if [[ "$(cut -d'|' -f2 <<<"$entry")" == "$2" ]]; then
            return 0
        fi
    done < <(impact_users_key_entries "$1")
    return 1
}

# impact_users_fingerprint_owners FINGERPRINT [EXCEPT_ACCOUNT]
#   Prints every account with an IMPACT record (any state) whose login keys
#   contain the key with FINGERPRINT, one per line, leaving out
#   EXCEPT_ACCOUNT. One key pair belongs to one person: a key that is a
#   login key of another account already usually means that the .pub file
#   of the wrong colleague was taken. The keys are read with the rights of
#   each person; an account whose keys cannot be read is left out. Root.
#   The login keys of the caller (IMPACT_USERS_AK_TEXT) stay as they were.
#   Example: impact_users_fingerprint_owners SHA256:abc... alice
impact_users_fingerprint_owners() {
    local print="$1" except="${2:-}" other saved_text="$IMPACT_USERS_AK_TEXT"
    while IFS= read -r other; do
        [[ -n "$other" && "$other" != "$except" ]] || continue
        impact_account_exists "$other" || continue
        if impact_users_read_authorized_keys "$other" 2>/dev/null &&
            impact_users_text_has_fingerprint "$IMPACT_USERS_AK_TEXT" "$print"; then
            printf '%s\n' "$other"
        fi
    done < <(impact_account_records)
    IMPACT_USERS_AK_TEXT="$saved_text"
}

# impact_users_text_with_line TEXT LINE
#   Prints TEXT with LINE added at its end. Empty lines at the end of TEXT
#   are dropped, so the file never grows by blank lines.
impact_users_text_with_line() {
    local text="$1"
    # Remove trailing line ends and blanks: "%%" with a pattern removes the
    # longest match at the end; [![:space:]] is "not a blank".
    text="${text%"${text##*[![:space:]]}"}"
    if [[ -n "$text" ]]; then
        printf '%s\n' "$text"
    fi
    printf '%s\n' "$2"
}

# impact_users_text_without_fingerprint TEXT FINGERPRINT
#   Prints TEXT without the key lines that have this fingerprint. Comment
#   lines and all other keys stay as they are.
impact_users_text_without_fingerprint() {
    local line print
    while IFS= read -r line || [[ -n "$line" ]]; do
        if impact__users_is_key_line "$line"; then
            print="$(impact_users_line_fingerprint "$(impact_trim "$line")")" || print='?'
            if [[ "$print" == "$2" ]]; then
                continue
            fi
        fi
        printf '%s\n' "$line"
    done <<<"$1"
}

# impact_users_lines_with_fingerprint TEXT FINGERPRINT
#   Prints only the key lines of TEXT that have this fingerprint.
impact_users_lines_with_fingerprint() {
    local line print
    while IFS= read -r line || [[ -n "$line" ]]; do
        impact__users_is_key_line "$line" || continue
        line="$(impact_trim "$line")"
        print="$(impact_users_line_fingerprint "$line")" || print='?'
        if [[ "$print" == "$2" ]]; then
            printf '%s\n' "$line"
        fi
    done <<<"$1"
}

# impact_users_write_authorized_keys ACCOUNT CONTENT_FILE
#   Writes the content of CONTENT_FILE as the person's authorized_keys
#   (mode 600), with the rights of the person: ~/.ssh is created with mode
#   700 when it is missing, and the file is replaced in one step. A symbolic
#   link or a foreign owner on the way is refused.
#   Result: 0 done; 3 refused (the reason was printed); 1 other failure.
#   Call it inside impact_do.
impact_users_write_authorized_keys() {
    local account="$1" content="$2" home status=0
    home="$(impact_account_home "$account")" || return 1
    impact_user_mkdir "$account" "$home/.ssh" 700 || return $?
    impact_user_write_file "$account" "$(impact_users_authorized_keys_path "$home")" 600 <"$content" || status=$?
    return "$status"
}

# impact_users_remove_authorized_keys ACCOUNT
#   Removes the person's authorized_keys, with the rights of the person.
#   Result: 0 done or nothing there; 3 refused; 1 other failure.
impact_users_remove_authorized_keys() {
    local home
    home="$(impact_account_home "$1")" || return 1
    impact_user_remove_file "$1" "$(impact_users_authorized_keys_path "$home")"
}

# =============================================================================
# The archive of keys in /opt/impact/admin/keys (root only)
# =============================================================================
# Layout, one folder per account:
#   <account>/received/SHA256_<code>.pub        every key that was enrolled
#   <account>/account-removed-<time>/key-N.pub  login keys moved away by
#                                               impact-remove-user
#   <account>/key-removed-<time>/key-N.pub      keys taken away by impact-key
# Each .pub file holds one plain key line, so it can be given to
# impact-add-user or impact-key with --key-file. A line that is no plain
# ssh-ed25519 key is saved as key-N.line.

# impact_users_fingerprint_file_name FINGERPRINT
#   Prints a file name made from a fingerprint: "SHA256:" becomes "SHA256_",
#   "/" becomes "_" and "+" becomes "-" (letters that are safe in a name).
#   Example: impact_users_fingerprint_file_name SHA256:ab/c+d   prints SHA256_ab_c-d
impact_users_fingerprint_file_name() {
    local name="$1"
    name="${name/#SHA256:/SHA256_}"
    name="${name//\//_}"
    name="${name//+/-}"
    printf '%s\n' "$name"
}

# impact_users_keys_dir ACCOUNT
#   Prints the archive folder of ACCOUNT: /opt/impact/admin/keys/<account>.
impact_users_keys_dir() {
    printf '%s/%s\n' "$IMPACT_KEYS_DIR" "$1"
}

# impact_users_received_path ACCOUNT FINGERPRINT
#   Prints the path of the archived copy of a received key.
impact_users_received_path() {
    printf '%s/received/%s.pub\n' "$(impact_users_keys_dir "$1")" "$(impact_users_fingerprint_file_name "$2")"
}

# impact__users_archive_dir FOLDER
#   Internal: creates FOLDER and the folders above it up to
#   /opt/impact/admin/keys with mode 700 for root. A symbolic link on the
#   way is refused.
impact__users_archive_dir() {
    local folder="$1" part current
    if [[ "$folder" != "$IMPACT_KEYS_DIR"/* ]]; then
        impact_error "$folder lies outside $IMPACT_KEYS_DIR."
        return 1
    fi
    current="$IMPACT_KEYS_DIR"
    if ! impact_dir_is "$current" 700 root root; then
        impact_make_dir "$current" 700 root root || return 1
    fi
    # Walk down from the archive folder, one name at a time. "IFS=/" makes
    # "read -a" split the rest of the path at each "/".
    local -a parts=()
    IFS=/ read -r -a parts <<<"${folder#"$IMPACT_KEYS_DIR"/}"
    for part in "${parts[@]}"; do
        current="$current/$part"
        if ! impact_dir_is "$current" 700 root root; then
            impact_make_dir "$current" 700 root root || return 1
        fi
    done
}

# impact_users_save_received ACCOUNT KEY_LINE FINGERPRINT
#   Saves a copy of an enrolled public key in the archive, unless a copy
#   with this fingerprint is there already. Needs root rights.
#   Call it inside impact_do.
impact_users_save_received() {
    local file
    file="$(impact_users_received_path "$1" "$3")"
    if [[ -f "$file" && ! -L "$file" ]]; then
        return 0
    fi
    impact__users_archive_dir "$(dirname -- "$file")" || return 1
    printf '%s\n' "$2" | impact_write_file_atomic "$file" 600 root root
}

# impact_users_save_key_lines FOLDER TEXT
#   Creates FOLDER in the archive (mode 700) and saves each key line of the
#   authorized_keys TEXT in its own file: key-1.pub, key-2.pub, ... for
#   plain ssh-ed25519 lines, key-N.line for other lines. Needs root rights.
#   Call it inside impact_do.
impact_users_save_key_lines() {
    local folder="$1" line number=0 file
    impact__users_archive_dir "$folder" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        impact__users_is_key_line "$line" || continue
        number=$((number + 1))
        line="$(impact_trim "$line")"
        if impact_parse_ed25519_key "$line"; then
            file="$folder/key-$number.pub"
        else
            file="$folder/key-$number.line"
        fi
        printf '%s\n' "$line" | impact_write_file_atomic "$file" 600 root root || return 1
    done <<<"$2"
}

# impact_users_new_archive_name ACCOUNT KIND
#   Prints the path of a new archive folder for keys that are taken away
#   now: <archive>/<KIND>-removed-<UTC time>, for example
#   /opt/impact/admin/keys/alice/account-removed-20260131T140509Z.
#   KIND is "account" (impact-remove-user), "key" (impact-key), "jobs" (the
#   scheduled jobs that impact-remove-user takes away) or the name of a
#   further login key file such as "authorized_keys2".
impact_users_new_archive_name() {
    printf '%s/%s-removed-%s\n' "$(impact_users_keys_dir "$1")" "$2" "$(date -u '+%Y%m%dT%H%M%SZ')"
}

# impact_users_latest_account_archive ACCOUNT
#   Prints the newest folder of the form account-removed-<time> of ACCOUNT.
#   The time in the name sorts like text, so the last name is the newest.
#   Result: failure when there is none.
impact_users_latest_account_archive() {
    local folder latest=''
    local -a folders=()
    folder="$(impact_users_keys_dir "$1")"
    [[ -d "$folder" && ! -L "$folder" ]] || return 1
    # "nullglob": a pattern without any match expands to nothing.
    shopt -s nullglob
    folders=("$folder"/account-removed-*)
    shopt -u nullglob
    for folder in "${folders[@]}"; do
        if [[ -d "$folder" && ! -L "$folder" ]]; then
            latest="$folder"
        fi
    done
    [[ -n "$latest" ]] || return 1
    printf '%s\n' "$latest"
}

# impact_users_archived_keys FOLDER
#   Prints one line "<file>|<fingerprint>" per key-N.pub file of an archive
#   folder, in the order of the numbers.
impact_users_archived_keys() {
    local file line=''
    local -a files=()
    shopt -s nullglob
    files=("$1"/key-*.pub)
    shopt -u nullglob
    ((${#files[@]} > 0)) || return 0
    # "sort -V" sorts numbers inside names by their value, so key-10 comes
    # after key-9.
    while IFS= read -r file; do
        [[ -n "$file" && -f "$file" && ! -L "$file" ]] || continue
        IFS= read -r line <"$file" || true
        if impact_parse_ed25519_key "$line"; then
            printf '%s|%s\n' "$file" "$IMPACT_KEY_FINGERPRINT"
        fi
    done < <(printf '%s\n' "${files[@]}" | sort -V)
}

# =============================================================================
# Texts for the administrator and for the colleague
# =============================================================================

# impact_users_docker_statement
#   Prints the plain statement about the group docker, which every command
#   that gives the group to a person shows once.
impact_users_docker_statement() {
    printf '%s\n' "Membership in the group docker gives the same power as root over this machine: a member can start a container that reads and changes every file, including the key copies of colleagues. Enrol only people you trust that far."
}

# impact_users_colleague_text ACCOUNT GITHUB_NAME FINGERPRINT
#   Prints the message for a newly enrolled colleague. The settings must be
#   loaded (the message names ADMIN_CONTACT).
impact_users_colleague_text() {
    local account="$1" github="$2" print="$3"
    printf '%s\n' '----- text for the colleague, begin -----'
    printf '%s\n' "Hello $github,"
    printf '%s\n' ''
    printf '%s\n' 'your account on the IMPACT workstation is ready.'
    printf '%s\n' "  Workstation account: $account"
    printf '%s\n' "  Enrolled key:        $print"
    printf '%s\n' '  Workstation address: <add the address here>'
    printf '%s\n' ''
    printf '%s\n' 'What to do: start IMPACT.bat, choose REMOTE and enter the workstation address.'
    if [[ "$account" != "${github,,}" ]]; then
        printf '%s\n' "Your account name differs from your GitHub name: enter $account in the field \"workstation account\"."
    fi
    printf '%s\n' 'The GUI logs in with the key of your PC; no password is needed. The list of'
    printf '%s\n' 'repositories is empty at first: press "Add repository" to fetch a model.'
    printf '%s\n' "If the fingerprint above differs from the one your GUI shows, do not continue and contact $(impact_contact_text)."
    printf '%s\n' "Questions: $(impact_contact_text)"
    printf '%s\n' '----- text for the colleague, end -----'
}

# impact_users_bring_back_text ACCOUNT GITHUB_NAME USER_NUMBER DELETED ARCHIVE_FOLDER
#   Prints the commands that bring a removed person back, one per line,
#   each to be typed exactly as printed. DELETED is 1 after --delete (the
#   account must then be created again with its old user number). The first
#   saved key goes to impact-add-user, every further one to impact-key add.
#   ARCHIVE_FOLDER may be empty when no key was saved.
impact_users_bring_back_text() {
    local account="$1" github="$2" uid="$3" deleted="$4" folder="${5:-}" entry file print
    local -a entries=() options=()
    if [[ -n "$folder" ]]; then
        mapfile -t entries < <(impact_users_archived_keys "$folder")
    fi
    if ((deleted == 1)); then
        options=(--account "$account" --uid "$uid")
    else
        options=(--account "$account" --existing)
    fi
    if ((${#entries[@]} == 0)); then
        printf '  sudo impact-add-user %s %s --github\n' "$github" "${options[*]}"
        printf '  %s\n' "(No login key was saved. --github takes the key from the person's GitHub account; --key-file <file> takes a key the person sends.)"
        return 0
    fi
    entry="${entries[0]}"
    file="${entry%%|*}"
    print="${entry#*|}"
    printf '  sudo impact-add-user %s %s --key-file %s --fingerprint %s\n' "$github" "${options[*]}" "$file" "$print"
    for entry in "${entries[@]:1}"; do
        file="${entry%%|*}"
        print="${entry#*|}"
        printf '  sudo impact-key add %s --key-file %s --fingerprint %s\n' "$account" "$file" "$print"
    done
}

# impact_users_parse_lastlog TEXT
#   Reads the output of "lastlog -u <account>" and prints the last terminal
#   login as "<time> from <address>", or "never" when there was none.
#   Pure text work.
#   Example output of lastlog (second line):
#     alice  pts/0  192.0.2.10   Tue Nov 24 10:00:00 +0000 2026
impact_users_parse_lastlog() {
    local line count=0 from=''
    local -a words=()
    while IFS= read -r line; do
        count=$((count + 1))
        if ((count == 2)); then
            break
        fi
    done <<<"$1"
    if ((count < 2)) || [[ -z "$line" || "$line" == *'**Never logged in**'* ]]; then
        printf 'never\n'
        return 0
    fi
    read -r -a words <<<"$line"
    # The time is always the last six words: day, month, date, time, zone,
    # year. Before them: name, terminal and, for a network login, the address.
    if ((${#words[@]} < 7)); then
        printf 'never\n'
        return 0
    fi
    if ((${#words[@]} >= 9)); then
        from=" from ${words[2]}"
    fi
    printf '%s%s\n' "${words[*]: -6}" "$from"
}

# impact_users_parse_auth_line LINE
#   Reads one line of the SSH server's log ("Accepted publickey for alice
#   from 192.0.2.10 port 50000 ssh2: ED25519 SHA256:...") and prints
#   "<time> from <address>". Two time formats exist: Ubuntu 24.04 writes
#   2026-11-24T10:00:00.123456+00:00, Ubuntu 22.04 writes Nov 24 10:00:00.
#   Pure text work. Result: failure for a line of another shape.
impact_users_parse_auth_line() {
    local line="$1" when from
    local -a words=()
    read -r -a words <<<"$line"
    ((${#words[@]} >= 3)) || return 1
    if [[ "${words[0]}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
        # Keep the time up to the seconds: "%%.*" cuts at the first dot,
        # and a time zone "+00:00" without a dot is cut as well.
        when="${words[0]%%.*}"
        when="${when%%+*}"
    else
        when="${words[0]} ${words[1]} ${words[2]}"
    fi
    # "sed -n s/.../p" prints the address that follows " from ".
    from="$(sed -n -e 's/.* from \([0-9A-Fa-f:.]*\) port .*/\1/p' <<<"$line")"
    [[ -n "$from" ]] || return 1
    printf '%s from %s\n' "$when" "$from"
}

# impact_users_last_login ACCOUNT
#   Prints the last login of ACCOUNT that this machine recorded:
#   first the SSH server's log /var/log/auth.log (and its previous file),
#   which also records logins without a terminal such as those of the GUI;
#   then the login record of lastlog, which records terminal logins only.
#   Prints "none recorded" when neither knows a login. Needs root rights.
impact_users_last_login() {
    local account="$1" line text file
    local -a files=()
    for file in /var/log/auth.log.1 /var/log/auth.log; do
        if [[ -f "$file" && -r "$file" ]]; then
            files+=("$file")
        fi
    done
    if ((${#files[@]} > 0)); then
        # The account name has been checked (letters, digits, - and _), so
        # it is safe inside the search pattern. "tail -n 1" keeps the last
        # (newest) match; the older file comes first in the list. Newer
        # versions of OpenSSH write "sshd-session" in front of the message.
        line="$(grep -h -E -- "sshd(-session)?\[[0-9]+\]: Accepted [a-z-]+ for $account from " "${files[@]}" 2>/dev/null | tail -n 1)" || line=''
        if [[ -n "$line" ]] && text="$(impact_users_parse_auth_line "$line")"; then
            printf '%s (SSH log)\n' "$text"
            return 0
        fi
    fi
    if impact_have_tool lastlog; then
        text="$(impact_users_parse_lastlog "$(lastlog -u "$account" 2>/dev/null)")"
        if [[ "$text" != 'never' ]]; then
            printf '%s (terminal login)\n' "$text"
            return 0
        fi
    fi
    printf 'none recorded\n'
}

# =============================================================================
# Processes, sessions, tunnels and containers of a person
# =============================================================================

# impact_users_filter_processes USER_NUMBER
#   A filter: reads lines "<pid> <effective uid> <real uid> <command line>"
#   (the output of "ps -A -o pid=,euid=,ruid=,args=") and prints
#   "<pid> <command line>" for every process of USER_NUMBER. Pure text work.
impact_users_filter_processes() {
    # awk compares fields 2 and 3 with the number; it then removes the first
    # three fields and prints the number of the process and the rest.
    awk -v uid="$1" '$2 == uid || $3 == uid {
        pid = $1
        $1 = ""; $2 = ""; $3 = ""
        sub(/^ +/, "")
        print pid " " $0
    }'
}

# impact_users_processes USER_NUMBER
#   Prints "<pid> <command line>" for every running process of the user
#   number: login sessions, SSH tunnels (they appear as "sshd: <account>"),
#   and every other program of the person. Read-only.
impact_users_processes() {
    impact_valid_user_number "$1" || return 1
    ps -A -o pid=,euid=,ruid=,args= 2>/dev/null | impact_users_filter_processes "$1"
}

# impact_users_end_processes USER_NUMBER
#   Ends every process of the user number: first politely (signal TERM),
#   after up to 10 seconds by force (signal KILL). An open SSH session or
#   tunnel of the person ends with its process. Needs root rights.
#   Result: success when no process of the number is left.
#   Call it inside impact_do.
impact_users_end_processes() {
    local uid="$1"
    impact_valid_user_number "$uid" || return 1
    # pkill -U matches the real user number, -u the effective one. It ends
    # with 1 when nothing matched, which is no failure here.
    pkill -TERM -U "$uid" 2>/dev/null
    pkill -TERM -u "$uid" 2>/dev/null
    local _
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if [[ -z "$(impact_users_processes "$uid")" ]]; then
            return 0
        fi
        sleep 0.5
    done
    pkill -KILL -U "$uid" 2>/dev/null
    pkill -KILL -u "$uid" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if [[ -z "$(impact_users_processes "$uid")" ]]; then
            return 0
        fi
        sleep 0.5
    done
    impact_error "Some processes of the user number $uid are still running:"
    impact_users_processes "$uid" | head -n 10 >&2
    return 1
}

# =============================================================================
# Work of a person that runs without a login: lingering, cron, at
# =============================================================================
# Three ways let programs of a person run while the person is not logged in.
# An expired account cannot log in, and pkill ends what runs now; these ways
# could start programs again later, so impact-remove-user switches them off.
#   Lingering: systemd starts the person's own service manager
#     ("systemd --user", the unit user@<number>.service) at boot and keeps
#     it running, with every service the person set up in
#     ~/.config/systemd/user. The mark is the file
#     /var/lib/systemd/linger/<account> ("loginctl enable-linger").
#   cron: a table of commands that run at set times ("crontab").
#   at: commands that run once at a set time ("at", listed by "atq").

# impact_users_linger_file ACCOUNT
#   Prints the path of the lingering mark of ACCOUNT.
impact_users_linger_file() {
    printf '/var/lib/systemd/linger/%s\n' "$1"
}

# impact_users_is_lingering ACCOUNT
#   Result: success when lingering is switched on for ACCOUNT. Read-only.
impact_users_is_lingering() {
    [[ -e "$(impact_users_linger_file "$1")" ]]
}

# impact_users_disable_linger ACCOUNT
#   Switches lingering off: with "loginctl disable-linger" where systemd
#   runs; elsewhere (no systemd, for example in a container) the mark file
#   is removed, which is what loginctl does. Call it inside impact_do.
impact_users_disable_linger() {
    if [[ -d /run/systemd/system ]] && impact_have_tool loginctl; then
        loginctl disable-linger -- "$1" || return 1
    fi
    rm -f -- "$(impact_users_linger_file "$1")"
}

# impact_users_user_manager_active USER_NUMBER
#   Result: success when systemd runs and the person's own service manager
#   (user@<number>.service) is active. Read-only.
impact_users_user_manager_active() {
    impact_valid_user_number "$1" || return 1
    [[ -d /run/systemd/system ]] && impact_have_tool systemctl &&
        systemctl is-active --quiet "user@$1.service" 2>/dev/null
}

# impact_users_crontab ACCOUNT
#   Prints the cron table of ACCOUNT. Read-only; root.
#   Result: failure when the account has none or cron is not installed.
impact_users_crontab() {
    impact_have_tool crontab || return 1
    crontab -u "$1" -l 2>/dev/null
}

# impact_users_at_jobs ACCOUNT
#   Prints the numbers of the waiting "at" jobs of ACCOUNT, one per line.
#   atq, run by root, lists the jobs of all accounts; the owner is the last
#   word of each line. Read-only; nothing is printed when "at" is not
#   installed.
impact_users_at_jobs() {
    impact_have_tool atq || return 0
    atq 2>/dev/null | awk -v owner="$1" '$NF == owner && $1 ~ /^[0-9]+$/ { print $1 }' || true
}

# impact_users_save_and_remove_jobs FOLDER ACCOUNT
#   Saves the cron table of ACCOUNT as FOLDER/crontab and each "at" job as
#   FOLDER/at-<number>.job (FOLDER is created in the archive, mode 700),
#   then removes them, so they cannot start programs any more. Root; call
#   it inside impact_do.
impact_users_save_and_remove_jobs() {
    local folder="$1" account="$2" table job
    impact__users_archive_dir "$folder" || return 1
    if table="$(impact_users_crontab "$account")"; then
        printf '%s\n' "$table" | impact_write_file_atomic "$folder/crontab" 600 root root || return 1
        crontab -u "$account" -r || return 1
    fi
    while IFS= read -r job; do
        [[ -n "$job" ]] || continue
        # "at -c" prints the whole job: the environment and the commands.
        at -c "$job" 2>/dev/null | impact_write_file_atomic "$folder/at-$job.job" 600 root root || return 1
        atrm "$job" || return 1
    done < <(impact_users_at_jobs "$account")
}

# impact_users_further_key_files ACCOUNT HOME
#   Prints every file other than <home>/.ssh/authorized_keys from which sshd
#   reads login keys for ACCOUNT ("AuthorizedKeysFile"; Ubuntu also reads
#   ~/.ssh/authorized_keys2), as absolute paths, one per line. The tokens
#   %h (home folder), %u (account name) and %% are replaced; a path without
#   "/" in front is inside the home folder. Read-only; root.
impact_users_further_key_files() {
    local account="$1" home="$2" settings value path
    local -a paths=()
    settings="$(impact_ssh_effective "$account" 2>/dev/null)" || return 0
    value="$(awk '$1 == "authorizedkeysfile" { $1 = ""; print }' <<<"$settings")"
    # "read -a" splits the value at blanks into the list "paths".
    read -r -a paths <<<"$value" || true
    for path in "${paths[@]}"; do
        path="${path//%h/$home}"
        path="${path//%u/$account}"
        path="${path//%%/%}"
        if [[ "$path" != /* ]]; then
            path="$home/$path"
        fi
        if [[ "$path" != "$home/.ssh/authorized_keys" ]]; then
            printf '%s\n' "$path"
        fi
    done
}

# impact_users_containers ACCOUNT
#   Prints "<id> <name> <state>" for every container that carries the label
#   impact.account=<ACCOUNT> and has not stopped (running, paused or
#   restarting). The GUI gives this label to every container it starts.
#   Read-only.
#   Result: 0 the list is complete (it may be empty); 1 Docker does not
#   answer; 2 Docker is not installed.
impact_users_containers() {
    local output status=0
    impact_docker_installed || return 2
    output="$(impact_docker_ro ps --no-trunc --filter "label=impact.account=$1" --format '{{.ID}} {{.Names}} {{.State}}' 2>/dev/null)" || status=$?
    if ((status != 0)); then
        return 1
    fi
    if [[ -n "$output" ]]; then
        printf '%s\n' "$output"
    fi
}

# impact_users_stop_container ID
#   Stops one container (signal TERM, after 30 seconds KILL) and waits for
#   it. ID must be the long hexadecimal number of the container.
#   Call it inside impact_do.
impact_users_stop_container() {
    if ! [[ "$1" =~ ^[0-9a-f]{12,64}$ ]]; then
        impact_error "'$(impact_display "$1")' is no container number."
        return 1
    fi
    timeout 90 docker stop -t 30 -- "$1" >/dev/null </dev/null
}

# impact_users_key_copies ACCOUNT
#   Prints the names of the private key copies in the person's ~/.ssh: the
#   entries named id_ed25519_<name> (and their .pub files) that the GUI
#   places there for git. The folder is listed with the rights of the
#   person. Read-only.
impact_users_key_copies() {
    local account="$1" home name
    home="$(impact_account_home "$account")" || return 1
    # The small script runs as the person: when ~/.ssh is a real folder it
    # lists the names that start with id_ed25519_. "-mindepth 1 -maxdepth 1"
    # keeps find inside the folder itself.
    # shellcheck disable=SC2016
    # Reason for SC2016 (no expansion in single quotes): the inner bash
    # expands "$1" itself; the folder is handed over as an argument.
    impact_run_as "$account" /bin/bash -c '[ -d "$1" ] && [ ! -L "$1" ] || exit 0; find "$1" -mindepth 1 -maxdepth 1 -name "id_ed25519_*" -printf "%f\n"' \
        impact-key-copies "$home/.ssh" 2>/dev/null |
        while IFS= read -r name; do
            # Only plain names; anything else is shown by impact-check.
            if [[ "$name" =~ ^id_ed25519_[A-Za-z0-9_.-]{1,80}$ ]]; then
                printf '%s\n' "$name"
            fi
        done | sort
}

# impact_users_key_copy_blob ACCOUNT PATH
#   Prints the key data of the public half of a private key copy. ssh-keygen
#   computes it from the private key; it runs with the rights of the person.
#   Result: failure when the copy cannot be read (missing, protected by a
#   passphrase, damaged).
impact_users_key_copy_blob() {
    local output type blob
    output="$(impact_run_as "$1" ssh-keygen -y -P '' -f "$2" 2>/dev/null </dev/null)" || return 1
    read -r type blob _ <<<"$output"
    [[ -n "$type" && -n "$blob" ]] || return 1
    printf '%s\n' "$blob"
}

# impact_users_storage_files USER_NUMBER OUTPUT_FILE ROOT...
#   Writes the path of every entry below the storage ROOTs that belongs to
#   the user number into OUTPUT_FILE, one per line (a line end inside a name
#   becomes "?"). The walk stays on each root's file system and never
#   follows symbolic links. It can take long on a large disk.
impact_users_storage_files() {
    local uid="$1" output="$2" root
    shift 2
    : >"$output"
    for root in "$@"; do
        [[ -d "$root" ]] || continue
        # -print0 ends each name with a zero byte; "tr" then turns line ends
        # inside names into "?" and the zero bytes into line ends.
        find "$root" -xdev -user "$uid" -print0 2>/dev/null | tr '\n\0' '?\n' >>"$output"
    done
}
